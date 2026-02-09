# ============================================================================
# DbUserList.ps1
# Purpose: Check for User List Collection requests and collect/upload data
# Usage: .\DbUserList.ps1
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
}
catch {
    Write-Host "FATAL: Failed to load libraries from $LibDir"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
}
catch {
    Write-GiipLog 'ERROR' ('[DbUserList] Failed to load config: ' + $_.Exception.Message)
    exit 1
}

Write-GiipLog "INFO" "[DbUserList] Checking for User List requests..."

# 1. Get DB List from API
try {
    $reqData = @{ lssn = $Config.lssn }
    $reqJson = $reqData | ConvertTo-Json -Compress
    
    # Use unified SP 'pApiManagedDatabaseListForAgentbySk'
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson
    
    $dbList = $null
    if ($response.data) { $dbList = $response.data }
    elseif ($response -is [Array]) { $dbList = $response }
    elseif ($response.mdb_id) { $dbList = @($response) }

    if (-not $dbList) {
        Write-GiipLog "INFO" "[DbUserList] No databases found."
        exit 0
    }

    # Ensure array
    if (-not ($dbList -is [Array] -or $dbList -is [System.Collections.IEnumerable])) {
        $dbList = @($dbList)
    }

    # Filter for requests
    $requestCount = 0
    foreach ($db in $dbList) {
        if ($db.user_list_req -eq 1 -or $db.user_list_req -eq $true) {
            $requestCount++
            $mdb_id = $db.mdb_id
            $dbHost = $db.db_host
            $user = $db.db_user
            $pass = $db.db_password
            $port = $db.db_port

            Write-GiipLog "INFO" ("[DbUserList] Processing Request for {0} ({1})..." -f $dbHost, $mdb_id)

            if ($db.db_type -eq 'MSSQL') {
                try {
                    # Use SqlConnectionStringBuilder to safely handle special characters in password
                    $connStrBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
                    $connStrBuilder["Data Source"] = "$dbHost,$port"
                    $connStrBuilder["Initial Catalog"] = "master"
                    $connStrBuilder["User ID"] = $user
                    $connStrBuilder["Password"] = $pass
                    $connStrBuilder["TrustServerCertificate"] = $true
                    $connStrBuilder["Connection Timeout"] = 10
                    
                    $userConn = New-Object System.Data.SqlClient.SqlConnection($connStrBuilder.ConnectionString)
                    $userConn.Open()
                    
                    $userCmd = $userConn.CreateCommand()
                    $userCmd.CommandText = @"
                    SET NOCOUNT ON;
                    SELECT 
                        sp.name, 
                        sp.type_desc as type, 
                        CASE WHEN sp.is_disabled = 1 THEN 'DISABLED' ELSE 'ENABLED' END as status, 
                        STUFF((SELECT ',' + r.name FROM sys.server_role_members srm JOIN sys.server_principals r ON srm.role_principal_id = r.principal_id WHERE srm.member_principal_id = sp.principal_id FOR XML PATH('')), 1, 1, '') as roles 
                    FROM sys.server_principals sp 
                    WHERE sp.type IN ('S','U','G')
                    AND sp.name NOT LIKE '##%';
"@
                    $userReader = $userCmd.ExecuteReader()
                    $userList = @()
                    while ($userReader.Read()) {
                        $userList += @{
                            name   = $userReader["name"]
                            type   = $userReader["type"]
                            status = $userReader["status"]
                            roles  = $userReader["roles"]
                        }
                    }
                    $userReader.Close()
                    $userConn.Close()

                    if ($userList.Count -gt 0) {
                        # Upload to Net3dUserListPut
                        $ulPayload = @{
                            mdb_id    = $mdb_id
                            lssn      = $Config.lssn
                            user_list = $userList
                        } | ConvertTo-Json -Depth 5 -Compress

                        Write-GiipLog "INFO" ("[DbUserList] Sending user_list for mdb_id=$mdb_id, host=$dbHost (MSSQL)")
                        Invoke-GiipApiV2 -Config $Config -CommandText "Net3dUserListPut jsondata" -JsonData $ulPayload | Out-Null
                        Write-GiipLog "INFO" ("[DbUserList] Data uploaded for {0} (Success)" -f $dbHost)
                    }
                }
                catch {
                    Write-GiipLog 'ERROR' ('[DbUserList] Failed to collect/upload for ' + $dbHost + ' (MSSQL): ' + $_.Exception.Message)
                }
            }
            elseif ($db.db_type -match 'MySQL|MariaDB') {
                try {
                    # Try to find MySql.Data.dll
                    $dllPaths = @(
                        Join-Path $LibDir "MySql.Data.dll",
                        "C:\Program Files\MySQL\MySQL Connector Net 8.0.33\Assemblies\v4\MySql.Data.dll",
                        "C:\Program Files\MySQL\MySQL Connector Net 8.0.32\Assemblies\v4\MySql.Data.dll"
                    )
                    
                    $loaded = $false
                    foreach ($path in $dllPaths) {
                        if (Test-Path $path) {
                            [void][System.Reflection.Assembly]::LoadFrom($path)
                            $loaded = $true
                            break
                        }
                    }

                    if (-not $loaded) {
                        throw "MySql.Data.dll not found in any of the search paths."
                    }

                    $connStr = "Server=$dbHost;Port=$port;Uid=$user;Pwd=$pass;SslMode=None;Connection Timeout=10;"
                    $userConn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
                    $userConn.Open()
                    
                    $userCmd = $userConn.CreateCommand()
                    $userCmd.CommandText = @"
SELECT 
    User as name,
    'USER' as type,
    CASE 
        WHEN (password_expired IS NULL OR password_expired = 'N')
        THEN 'ENABLED'
        ELSE 'DISABLED'
    END as status,
    COALESCE(
        (SELECT GROUP_CONCAT(DISTINCT db SEPARATOR ',')
         FROM mysql.db d
         WHERE d.User = u.User AND d.Host = u.Host),
        ''
    ) as grants,
    '' as roles
FROM mysql.user u
WHERE User != ''
GROUP BY User, Host, plugin, password_expired
ORDER BY User;
"@
                    $userReader = $userCmd.ExecuteReader()
                    $userList = @()
                    while ($userReader.Read()) {
                        $userList += @{
                            name   = $userReader["name"]
                            type   = $userReader["type"]
                            status = $userReader["status"]
                            grants = $userReader["grants"]
                            roles  = $userReader["roles"]
                        }
                    }
                    $userReader.Close()
                    $userConn.Close()

                    if ($userList.Count -gt 0) {
                        # Upload to Net3dUserListPut
                        $ulPayload = @{
                            mdb_id    = $mdb_id
                            lssn      = $Config.lssn
                            user_list = $userList
                        } | ConvertTo-Json -Depth 5 -Compress

                        Write-GiipLog "INFO" ("[DbUserList] Sending user_list for mdb_id=$mdb_id, host=$dbHost (MySQL)")
                        Invoke-GiipApiV2 -Config $Config -CommandText "Net3dUserListPut jsondata" -JsonData $ulPayload | Out-Null
                        Write-GiipLog "INFO" ("[DbUserList] Data uploaded for {0} (Success)" -f $dbHost)
                    }
                }
                catch {
                    Write-GiipLog 'ERROR' ('[DbUserList] Failed to collect/upload for ' + $dbHost + ' (MySQL): ' + $_.Exception.Message)
                }
            }
            else {
                $dbType = $db.db_type
                Write-GiipLog 'WARN' ('[DbUserList] DB Type ' + $dbType + ' not supported for User List yet.')
            }

        }
    }

    if ($requestCount -eq 0) {
        Write-GiipLog "INFO" "[DbUserList] No pending user list requests."
    }

}
catch {
    Write-GiipLog 'ERROR' ('[DbUserList] Error checking requests: ' + $_.Exception.Message)
    exit 1
}

exit 0
