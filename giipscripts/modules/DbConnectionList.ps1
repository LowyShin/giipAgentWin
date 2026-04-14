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
                MAX(t.text) as full_sql,
                CONVERT(NVARCHAR(64), r.query_hash, 1) as query_hash,
                CONVERT(NVARCHAR(130), r.sql_handle, 1) as sql_handle,
                MAX(r.start_time) as query_start_time,
                MAX(s.session_id) as query_id
            FROM sys.dm_exec_connections c
            JOIN sys.dm_exec_sessions s ON c.session_id = s.session_id
            LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
            OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
            GROUP BY c.client_net_address, r.query_hash, r.sql_handle
"@
        $reader = $cmd.ExecuteReader()
        
        # [HARDEN] Get Column Mapping to prevent "Property not found" Index errors
        $colMap = @{}
        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
            $colMap[$reader.GetName($i)] = $i
        }

        while ($reader.Read()) {
            $row = @{}
            foreach ($name in $colMap.Keys) {
                $val = $reader.GetValue($colMap[$name])
                $row[$name] = if ($val -is [System.DBNull]) { $null } else { $val }
            }
            
            # Ensure DateTime conversion for specific field
            if ($row.ContainsKey("query_start_time") -and $row.query_start_time -ne $null) {
                $row.query_start_time = [DateTime]$row.query_start_time
            }

            # Schema Sanity: sql_handle & query_hash should always exists in the hashtable
            if (-not $row.ContainsKey("sql_handle")) { $row["sql_handle"] = $null }
            if (-not $row.ContainsKey("query_hash")) { $row["query_hash"] = $null }

            $connList += $row
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
                # [SCHEMA] Ensure parity with MSSQL fields to prevent property-not-found errors
                sql_handle         = $null
                plan_handle        = $null
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
                        if ($fullText.Length -gt 20000) { $fullText = $fullText.Substring(0, 20000) }
                        
                        Invoke-GiipKvsPut -Config $Config -Type "query" -Key $qHash -Factor "full_text" -Value $fullText | Out-Null
                        Write-GiipLog "DEBUG" "[DbConnectionList] Uploaded full text for query $qHash"
                    }
                }
            }
        }
        catch {
            # Enhanced Logging: Capture full exception detail
            $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
            $errType = if ($_.Exception) { $_.Exception.GetType().Name } else { "UnknownException" }
            Write-GiipLog "WARN" "[DbConnectionList] Failed for $($db.db_host): [$errType] $errMsg"
        }
    }

    Write-GiipLog "INFO" "[DbConnectionList] Completed."
}
catch {
    Write-GiipLog "ERROR" "[DbConnectionList] Fatal error: $_"
    exit 1
}
exit 0

