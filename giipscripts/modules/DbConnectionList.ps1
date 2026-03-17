# ============================================================================
# DbConnectionList.ps1
# Purpose: Collect active client connections from managed databases (Net3D)
# Usage: .\DbConnectionList.ps1
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "KVS.ps1")
    . (Join-Path $LibDir "ErrorLog.ps1")
}
catch {
    Write-Host "FATAL: Failed to load libraries from $LibDir"
    exit 1
}

# ============================================================================
# Function: Get-MSSQLConnections
# Purpose: Collect connection info from MSSQL database
# ============================================================================
function Get-MSSQLConnections {
    param(
        [Parameter(Mandatory = $true)][string]$DbHost,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Pass
    )
    
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder.DataSource = "$DbHost,$Port"
    $builder.InitialCatalog = "master"
    $builder.UserID = $User
    $builder.Password = $Pass
    $builder.TrustServerCertificate = $true
    $builder.ConnectTimeout = 10
    
    $conn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    $conn.Open()
    
    $connList = @()
    
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
            SELECT 
                c.client_net_address,
                MAX(s.program_name) as program_name,
                COUNT(*) as conn_count,
                ISNULL(SUM(r.cpu_time), 0) as cpu_load,
                MAX(REPLACE(REPLACE(SUBSTRING(t.text, 1, 1000), CHAR(13), ' '), CHAR(10), ' ')) as last_sql,
                CONVERT(NVARCHAR(64), r.query_hash, 1) as query_hash,
                CONVERT(NVARCHAR(130), r.sql_handle, 1) as sql_handle
            FROM sys.dm_exec_connections c
            JOIN sys.dm_exec_sessions s ON c.session_id = s.session_id
            LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
            OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
            GROUP BY c.client_net_address, r.query_hash, r.sql_handle
"@
        $reader = $cmd.ExecuteReader()
        
        while ($reader.Read()) {
            $connList += @{
                client_net_address = $reader["client_net_address"]
                program_name       = $reader["program_name"]
                conn_count         = $reader["conn_count"]
                cpu_load           = $reader["cpu_load"]
                last_sql           = $reader["last_sql"]
                query_hash         = $reader["query_hash"]
                sql_handle         = $reader["sql_handle"]
            }
        }
        $reader.Close()
    }
    finally {
        $conn.Close()
    }
    
    return $connList
}

# ============================================================================
# Function: Get-MySQLConnections
# Purpose: Collect connection info from MySQL database (Aligns with Linux Agent)
# ============================================================================
function Get-MySQLConnections {
    param(
        [Parameter(Mandatory = $true)][string]$DbHost,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Pass
    )

    if (-not (Import-MySqlDll -LibDir $LibDir)) {
        Write-GiipLog "WARN" "[DbConnectionList] Skipped MySQL $DbHost: MySql.Data.dll not found."
        return @()
    }

    try {
        $connStr = "Server=$DbHost;Port=$Port;Uid=$User;Pwd=$Pass;SslMode=None;Connection Timeout=10;"
        $conn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
        $conn.Open()
        
        $connList = @()
        $cmd = $conn.CreateCommand()
        # information_schema.processlist is standard for session monitoring
        $cmd.CommandText = "SELECT host, user, db, command, time, info FROM information_schema.processlist WHERE command != 'Sleep' AND user NOT IN ('system user', 'event_scheduler')"
        $reader = $cmd.ExecuteReader()
        
        while ($reader.Read()) {
            $hostStr = $reader["host"]
            $clientIp = if ($hostStr -match ':') { $hostStr.Split(":")[0] } else { $hostStr }
            $sqlText = if ($reader["info"] -isnot [System.DBNull]) { $reader["info"] } else { "" }
            
            $connList += @{
                client_net_address = $clientIp
                login_name         = $reader["user"]
                program_name       = $reader["command"]
                db_name            = $reader["db"]
                status             = "active"
                cpu_load           = [int]$reader["time"]
                last_sql           = $sqlText
                query_hash         = Get-StringMd5 -InputString $sqlText
            }
        }
        $reader.Close()
        $conn.Close()
        return $connList
    }
    catch {
        Write-GiipLog "WARN" "[DbConnectionList] MySQL Error for $DbHost: $_"
        return @()
    }
}

# ============================================================================
# Function: Send-ConnectionData
# Purpose: Send connection data to API
# ============================================================================
function Send-ConnectionData {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][int]$MdbId,
        [Parameter(Mandatory = $true)][array]$ConnList
    )
    
    if ($ConnList.Count -eq 0) { return $false }
    
    Write-GiipLog "INFO" "[DbConnectionList] Sending $($ConnList.Count) connections for DB: $MdbId"
    $response = Invoke-GiipKvsPut -Config $Config -Type "database" -Key "$MdbId" -Factor "db_connections" -Value $ConnList
    
    if ($null -eq $response -or $response.RstVal -ne "200") {
        Write-GiipLog "WARN" "[DbConnectionList] API Error for DB $MdbId: $($response.RstMsg)"
        return $false
    }
    return $true
}

# ============================================================================
# Main Logic
# ============================================================================
try {
    $Config = Get-GiipConfig
    Write-GiipLog "INFO" "[DbConnectionList] Starting..."

    # 1. Get DB List from API
    $reqJson = @{ lssn = $Config.lssn } | ConvertTo-Json -Compress
    $apiRes = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson
    
    $dbList = if ($apiRes.data) { $apiRes.data } else { @() }
    if ($dbList.Count -eq 0) {
        Write-GiipLog "INFO" "[DbConnectionList] No databases found."
        exit 0
    }

    # 2. Process Each Database
    foreach ($db in $dbList) {
        try {
            $connections = @()
            if ($db.db_type -eq 'MSSQL') {
                $connections = Get-MSSQLConnections -DbHost $db.db_host -Port $db.db_port -User $db.db_user -Pass $db.db_password
            }
            elseif ($db.db_type -match 'MySQL|MariaDB') {
                $connections = Get-MySQLConnections -DbHost $db.db_host -Port $db.db_port -User $db.db_user -Pass $db.db_password
            }

            if ($connections.Count -gt 0) {
                Send-ConnectionData -Config $Config -MdbId $db.mdb_id -ConnList $connections | Out-Null
            }
        }
        catch {
            Write-GiipLog "WARN" "[DbConnectionList] Failed for $($db.db_host): $_"
        }
    }

    Write-GiipLog "INFO" "[DbConnectionList] Completed."
}
catch {
    Write-GiipLog "ERROR" "[DbConnectionList] Fatal error: $_"
    exit 1
}
exit 0
