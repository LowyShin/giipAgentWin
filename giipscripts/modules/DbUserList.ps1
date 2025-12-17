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
    Write-Host "FATAL: Failed to load Common.ps1 from $LibDir"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
}
catch {
    Write-GiipLog "ERROR" "[DbUserList] Failed to load config: $_"
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

            Write-GiipLog "INFO" "[DbUserList] 👤 Processing Request for $dbHost ($mdb_id)..."

            if ($db.db_type -eq 'MSSQL') {
                try {
                    $connStr = "Server=$dbHost,$port;Database=master;User Id=$user;Password=$pass;TrustServerCertificate=True;Connection Timeout=10;"
                    $userConn = New-Object System.Data.SqlClient.SqlConnection($connStr)
                    $userConn.Open()
                    
                    $userCmd = $userConn.CreateCommand()
                    $userCmd.CommandText = @"
                    SET NOCOUNT ON;
                    SELECT 
                        dp.name, 
                        dp.type_desc as type, 
                        'ENABLED' as status, 
                        (SELECT r.name + ',' FROM sys.database_role_members drm JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id WHERE drm.member_principal_id = dp.principal_id FOR XML PATH('')) as roles 
                    FROM sys.database_principals dp 
                    WHERE dp.type IN ('S','U','G');
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

                        $res = Invoke-GiipApiV2 -Config $Config -CommandText "Net3dUserListPut jsondata" -JsonData $ulPayload
                        
                        if ($res.RstVal -eq 200) {
                            Write-GiipLog "INFO" "[DbUserList] 📤 Data uploaded for $dbHost (Success)"
                        }
                        else {
                            $msg = if ($res.RstMsg) { $res.RstMsg } else { "Unknown Error" }
                            Write-GiipLog "ERROR" "[DbUserList] ❌ Upload failed for ${dbHost}: $msg"
                            Write-GiipLog "DEBUG" "Response: $($res | ConvertTo-Json -Compress)"
                        }
                    }
                    else {
                        Write-GiipLog "WARN" "[DbUserList] No users found for $dbHost"
                    }
                }
                catch {
                    Write-GiipLog "ERROR" "[DbUserList] Failed to collect/upload for ${dbHost}: $_"
                }
            }
            else {
                Write-GiipLog "WARN" "[DbUserList] DB Type $($db.db_type) not supported for User List yet."
            }
        }
    }

    if ($requestCount -eq 0) {
        Write-GiipLog "INFO" "[DbUserList] No pending user list requests."
    }

}
catch {
    Write-GiipLog "ERROR" "[DbUserList] Error checking requests: $_"
    exit 1
}

exit 0
