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
# Helper Functions
# ============================================================================

function Get-MSSQLConnections {
    param(
        [Parameter(Mandatory = $true)][string]$DbHost,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Pass
    )
    
    $connStr = "Server=$DbHost,$Port;Database=master;User Id=$User;Password=$Pass;TrustServerCertificate=True;Connection Timeout=10;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()
    
    $connList = @()
    try {
        # 1. Snapshot Query: Collect active connections and handles (No large text aggregation)
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
            SELECT 
                s.session_id,
                c.client_net_address,
                s.program_name,
                r.cpu_time,
                r.start_time as query_start_time,
                ISNULL(r.sql_handle, c.most_recent_sql_handle) as sql_handle,
                ISNULL(r.query_hash, qs.query_hash) as query_hash
            FROM sys.dm_exec_connections c
            JOIN sys.dm_exec_sessions s ON c.session_id = s.session_id
            LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
            OUTER APPLY (SELECT TOP 1 query_hash FROM sys.dm_exec_query_stats WHERE sql_handle = ISNULL(r.sql_handle, c.most_recent_sql_handle)) qs
"@
        $snapshot = @()
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $snapshot += @{
                session_id         = $reader["session_id"]
                client_net_address = $reader["client_net_address"]
                program_name       = $reader["program_name"]
                cpu_load           = if ($reader["cpu_time"] -isnot [System.DBNull]) { [int]$reader["cpu_time"] } else { 0 }
                query_start_time   = if ($reader["query_start_time"] -isnot [System.DBNull]) { [DateTime]$reader["query_start_time"] } else { $null }
                sql_handle         = if ($reader["sql_handle"] -isnot [System.DBNull]) { "0x" + [System.BitConverter]::ToString($reader["sql_handle"]).Replace("-", "") } else { $null }
                query_hash         = if ($reader["query_hash"] -isnot [System.DBNull]) { "0x" + [System.BitConverter]::ToString($reader["query_hash"]).Replace("-", "") } else { $null }
            }
        }
        $reader.Close()

        # 2. Retrieve SQL Text for Unique Handles (Lazy Loading)
        $sqlCache = @{}
        $uniqueHandles = $snapshot | Where-Object { $null -ne $_.sql_handle } | Select-Object -ExpandProperty sql_handle -Unique
        
        foreach ($handle in $uniqueHandles) {
            try {
                $tCmd = $conn.CreateCommand()
                $tCmd.CommandText = "SELECT text FROM sys.dm_exec_sql_text($handle)"
                $sqlText = $tCmd.ExecuteScalar()
                if ($null -ne $sqlText) {
                    $sqlCache[$handle] = $sqlText
                }
            } catch {}
        }

        # 3. Finalize Data with standard session_id
        foreach ($s in $snapshot) {
            $h = $s.sql_handle
            $fullSql = if ($h -and $sqlCache.ContainsKey($h)) { $sqlCache[$h] } else { "" }
            $lastSql = if ($fullSql) { $fullSql.Substring(0, [Math]::Min(1000, $fullSql.Length)).Replace("`r", " ").Replace("`n", " ") } else { "" }

            $connList += @{
                session_id         = $s.session_id
                client_net_address = $s.client_net_address
                program_name       = $s.program_name
                cpu_load           = $s.cpu_load
                last_sql           = $lastSql
                full_sql           = $fullSql
                query_hash         = $s.query_hash
                sql_handle         = $s.sql_handle
                query_start_time   = $s.query_start_time
            }
        }
    }
    finally {
        $conn.Close()
    }
    return $connList
}

function Get-MySQLConnections {
    param(
        [Parameter(Mandatory = $true)][string]$DbHost,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Pass
    )

    if (-not (Import-MySqlDll -LibDir $LibDir)) {
        Write-GiipLog "WARN" "[DbConnectionList] MySql.Data.dll not found."
        return @()
    }

    try {
        $connStr = "Server=$DbHost;Port=$Port;Uid=$User;Pwd=$Pass;SslMode=None;Connection Timeout=10;"
        $conn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
        $conn.Open()
        
        $connList = @()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT id, host, user, db, command, time, info FROM information_schema.processlist WHERE command != 'Sleep' AND user NOT IN ('system user', 'event_scheduler')"
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $hostStr = $reader["host"]
            $clientIp = if ($hostStr -match ':') { $hostStr.Split(":")[0] } else { $hostStr }
            $sqlText = if ($reader["info"] -isnot [System.DBNull]) { $reader["info"] } else { "" }
            
            $connList += @{
                session_id         = $reader["id"]
                client_net_address = $clientIp
                login_name         = $reader["user"]
                program_name       = $reader["command"]
                db_name            = $reader["db"]
                status             = "active"
                cpu_load           = [int]$reader["time"]
                last_sql           = $sqlText
                full_sql           = $sqlText
                query_hash         = Get-StringMd5 -InputString $sqlText
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

function Send-ConnectionData {
    param($Config, $MdbId, $ConnList)
    if ($ConnList.Count -eq 0) { return $false }
    
    $cleanList = @()
    foreach ($c in $ConnList) {
        $clone = $c.Clone()
        if ($clone.ContainsKey("full_sql")) { $clone.Remove("full_sql") }
        $cleanList += $clone
    }
    
    $response = Invoke-GiipKvsPut -Config $Config -Type "database" -Key "$MdbId" -Factor "db_connections" -Value $cleanList
    return ($null -ne $response -and $response.RstVal -eq "200")
}

function Upload-TopQueries {
    param($Config, $Db, $ConnList)
    
    $topQueries = $ConnList | Where-Object { -not [string]::IsNullOrWhiteSpace($_.query_hash) -and -not [string]::IsNullOrWhiteSpace($_.full_sql) } | Sort-Object -Property cpu_load -Descending | Select-Object -First 20
    
    foreach ($q in $topQueries) {
        $qHash = $q.query_hash
        if (-not $Global:UploadedHashes.ContainsKey($qHash)) {
            $Global:UploadedHashes[$qHash] = $true
            $qFullText = $q.full_sql
            $qCsnStr = if ($Db.csn) { [string]$Db.csn } else { "global" }
            
            Invoke-GiipKvsPut -Config $Config -Type "query" -Key $qHash -Factor $qCsnStr -Value $qFullText | Out-Null
            Write-GiipLog "DEBUG" "[DbConnectionList] Uploaded full text for $qHash"
        }
    }
}

function Process-SingleMdb {
    param($Config, $Db)
    try {
        $connections = @()
        if ($Db.db_type -eq 'MSSQL') {
            $connections = Get-MSSQLConnections -DbHost $Db.db_host -Port $Db.db_port -User $Db.db_user -Pass $Db.db_password
        }
        elseif ($Db.db_type -match 'MySQL|MariaDB') {
            $connections = Get-MySQLConnections -DbHost $Db.db_host -Port $Db.db_port -User $Db.db_user -Pass $Db.db_password
        }

        if ($connections.Count -gt 0) {
            # 1. Main Connection Data
            if (Send-ConnectionData -Config $Config -MdbId $Db.mdb_id -ConnList $connections) {
                # 2. Stats & Debug Logging
                $hasHashCount = ($connections | Where-Object { -not [string]::IsNullOrWhiteSpace($_.query_hash) }).Count
                $activeCount = ($connections | Where-Object { $_.cpu_load -gt 0 }).Count
                
                Write-GiipLog "INFO" "[DbConnectionList] DB ID $($Db.mdb_id): Total=$($connections.Count), Active=$activeCount, HasHash=$hasHashCount"
                
                if ($activeCount -gt 0 -and $hasHashCount -eq 0) {
                    $debugInfo = @{
                        mdb_id = $Db.mdb_id
                        active_count = $activeCount
                        total_count = $connections.Count
                        reason = "query_hash missing for active queries. Check VIEW SERVER STATE perm."
                    }
                    sendErrorLog -Config $Config -Message "query_hash collection failed" -InputValues $debugInfo -Severity "error" -ErrorType "CollectionGap"
                }

                # 3. Top Query Full Text
                Upload-TopQueries -Config $Config -Db $Db -ConnList $connections
            }
        }
    }
    catch {
        Write-GiipLog "WARN" "[DbConnectionList] Failed for $($Db.db_host): $_"
    }
}

# ============================================================================
# Entry Point
# ============================================================================
try {
    $Config = Get-GiipConfig
    Write-GiipLog "INFO" "[DbConnectionList] Starting..."

    $apiRes = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData (@{ lssn = $Config.lssn } | ConvertTo-Json -Compress)
    $dbList = if ($apiRes.data) { $apiRes.data } else { @() }
    
    foreach ($db in $dbList) {
        Process-SingleMdb -Config $Config -Db $db
    }

    Write-GiipLog "INFO" "[DbConnectionList] Completed."
}
catch {
    Write-GiipLog "ERROR" "[DbConnectionList] Fatal error: $_"
    exit 1
}
exit 0
