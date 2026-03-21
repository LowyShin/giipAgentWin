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
$Global:UploadedHashes = @{}
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
    
    # Use direct connection string for maximum compatibility
    $connStr = "Server=$DbHost,$Port;Database=master;User Id=$User;Password=$Pass;TrustServerCertificate=True;Connection Timeout=10;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
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
                MAX(t.text) as full_sql,
                CONVERT(NVARCHAR(64), ISNULL(MAX(r.query_hash), MAX(qs.query_hash)), 1) as query_hash,
                CONVERT(NVARCHAR(130), ISNULL(MAX(r.sql_handle), MAX(c.most_recent_sql_handle)), 1) as sql_handle,
                MAX(r.start_time) as query_start_time,
                MAX(s.session_id) as query_id
            FROM sys.dm_exec_connections c
            JOIN sys.dm_exec_sessions s ON c.session_id = s.session_id
            LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
            OUTER APPLY sys.dm_exec_sql_text(ISNULL(r.sql_handle, c.most_recent_sql_handle)) t
            OUTER APPLY (SELECT TOP 1 query_hash FROM sys.dm_exec_query_stats WHERE sql_handle = ISNULL(r.sql_handle, c.most_recent_sql_handle)) qs
            GROUP BY c.client_net_address, ISNULL(r.sql_handle, c.most_recent_sql_handle)
"@
        $reader = $cmd.ExecuteReader()
        
        while ($reader.Read()) {
            $connList += @{
                client_net_address = $reader["client_net_address"]
                program_name       = $reader["program_name"]
                conn_count         = $reader["conn_count"]
                cpu_load           = $reader["cpu_load"]
                last_sql           = $reader["last_sql"]
                full_sql           = if ($reader["full_sql"] -isnot [System.DBNull]) { $reader["full_sql"] } else { "" }
                query_hash         = $reader["query_hash"]
                sql_handle         = $reader["sql_handle"]
                query_start_time   = if ($reader["query_start_time"] -isnot [System.DBNull]) { [DateTime]$reader["query_start_time"] } else { $null }
                query_id           = $reader["query_id"]
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
        Write-GiipLog "WARN" "[DbConnectionList] Skipped MySQL ${DbHost}: MySql.Data.dll not found."
        return @()
    }

    try {
        $connStr = "Server=$DbHost;Port=$Port;Uid=$User;Pwd=$Pass;SslMode=None;Connection Timeout=10;"
        $conn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
        $conn.Open()
        
        $connList = @()
        $cmd = $conn.CreateCommand()
        # information_schema.processlist is standard for session monitoring
        $cmd.CommandText = "SELECT id, host, user, db, command, time, info FROM information_schema.processlist WHERE command != 'Sleep' AND user NOT IN ('system user', 'event_scheduler')"
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
                full_sql           = $sqlText
                query_hash         = Get-StringMd5 -InputString $sqlText
                query_id           = $reader["id"]
                query_start_time   = (Get-Date).AddSeconds(-[int]$reader["time"])
            }
        }
        $reader.Close()
        $conn.Close()
        return $connList
    }
    catch {
        Write-GiipLog "WARN" "[DbConnectionList] MySQL Error for ${DbHost}: $_"
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
    
    # Strip full_sql before uploading standard db_connections payload
    $cleanList = @()
    foreach ($c in $ConnList) {
        $clone = $c.Clone()
        if ($clone.ContainsKey("full_sql")) { $clone.Remove("full_sql") }
        $cleanList += $clone
    }
    
    $response = Invoke-GiipKvsPut -Config $Config -Type "database" -Key "$MdbId" -Factor "db_connections" -Value $cleanList
    
    if ($null -eq $response -or $response.RstVal -ne "200") {
        Write-GiipLog "WARN" "[DbConnectionList] API Error for DB ${MdbId}: $($response.RstMsg)"
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
                
                # [NEW] Upload Top 20 Query Hashes for Net3D View Full Query
                $topQueries = $connections | Where-Object { -not [string]::IsNullOrWhiteSpace($_.query_hash) -and -not [string]::IsNullOrWhiteSpace($_.full_sql) } | Sort-Object -Property cpu_load -Descending | Select-Object -First 20
                
                foreach ($q in $topQueries) {
                    $qHash = $q.query_hash
                    if (-not $Global:UploadedHashes.ContainsKey($qHash)) {
                        $Global:UploadedHashes[$qHash] = $true
                        $fullText = $q.full_sql
                        $csnStr = if ($db.csn) { [string]$db.csn } else { "global" }
                        
                        Invoke-GiipKvsPut -Config $Config -Type "query" -Key $qHash -Factor $csnStr -Value $fullText | Out-Null
                        Write-GiipLog "DEBUG" "[DbConnectionList] Uploaded full text for query $qHash (CSN: $csnStr)"
                    }
                }
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
