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
    Write-GiipLog "ERROR" "[DbConnectionList] Failed to load config: $_"
    exit 1
}

Write-GiipLog "INFO" "[DbConnectionList] Starting..."

# 1. Get DB List from API
try {
    # Send LSSN to allow filtering by gateway_lssn on server side
    $reqData = @{ lssn = $Config.lssn }
    $reqJson = $reqData | ConvertTo-Json -Compress
    
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson
    
    $dbList = $null
    
    if ($response.data) { $dbList = $response.data }
    elseif ($response -is [Array]) { $dbList = $response }
    elseif ($response.mdb_id) { $dbList = @($response) }

    if (-not $dbList) {
        Write-GiipLog "INFO" "[DbConnectionList] No databases found."
        exit 0
    }

    if (-not ($dbList -is [Array] -or $dbList -is [System.Collections.IEnumerable])) {
        $dbList = @($dbList)
    }

    Write-GiipLog "INFO" "[DbConnectionList] Found $($dbList.Count) databases."
}
catch {
    Write-GiipLog "ERROR" "[DbConnectionList] Failed to get DB list: $_"
    exit 1
}

# 2. Collect Connections

foreach ($db in $dbList) {
    try {
        $mdb_id = $db.mdb_id
        $db_type = $db.db_type
        $dbHost = $db.db_host
        $port = $db.db_port
        $user = $db.db_user
        $pass = $db.db_password

        # Only MSSQL supported for now
        if ($db_type -eq 'MSSQL') {
            try {
                $connStr = "Server=$dbHost,$port;Database=master;User Id=$user;Password=$pass;TrustServerCertificate=True;Connection Timeout=10;"
                $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
                $conn.Open()
                
                $cmdConn = $conn.CreateCommand()
                # Query for Active Client IPs, Load, and Last SQL
                $cmdConn.CommandText = @"
                    SELECT 
                        c.client_net_address,
                        MAX(s.program_name) as program_name,
                        COUNT(*) as conn_count,
                        ISNULL(SUM(r.cpu_time), 0) as cpu_load,
                        MAX(SUBSTRING(t.text, 1, 200)) as last_sql  -- Limit SQL text length
                    FROM sys.dm_exec_connections c
                    JOIN sys.dm_exec_sessions s ON c.session_id = s.session_id
                    LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
                    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
                    GROUP BY c.client_net_address
"@
                $readerConn = $cmdConn.ExecuteReader()
                $connList = @()
                
                while ($readerConn.Read()) {
                    $connList += @{
                        client_net_address = $readerConn["client_net_address"]
                        program_name       = $readerConn["program_name"]
                        conn_count         = $readerConn["conn_count"]
                        cpu_load           = $readerConn["cpu_load"]
                        last_sql           = $readerConn["last_sql"]
                    }
                }
                $readerConn.Close()
                $conn.Close()

                if ($connList.Count -gt 0) {
                    Write-GiipLog "INFO" "[DbConnectionList] Sending connection data for DB: $mdb_id"
                    
                    # Use Shared Library KVS.ps1
                    $response = Invoke-GiipKvsPut -Config $Config -Type "database" -Key "$mdb_id" -Factor "db_connections" -Value $connList
                    
                    if ($response.RstVal -eq "200") {
                        Write-GiipLog "INFO" "[DbConnectionList] Success for DB $mdb_id."
                    }
                    else {
                        Write-GiipLog "WARN" "[DbConnectionList] API Error for DB $mdb_id"
                        Write-GiipLog "WARN" "RstVal: '$($response.RstVal)'"
                        Write-GiipLog "WARN" "RstMsg: '$($response.RstMsg)'"
                        # Only log full object on debug or error
                        # Write-GiipLog "DEBUG" "FullObj: $($response | ConvertTo-Json -Compress)"
                    }
                }
            }
            catch {
                Write-GiipLog "WARN" "[DbConnectionList] Failed for $($dbHost): $_"
            }
        }
    }
    catch {
        Write-GiipLog "ERROR" "[DbConnectionList] Unexpected error: $_"
    }
}

Write-GiipLog "INFO" "[DbConnectionList] Completed."
exit 0
