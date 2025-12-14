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
$statsList = @()

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
                # Query for Active Client IPs
                $cmdConn.CommandText = @"
                    SELECT 
                        client_net_address,
                        program_name,
                        COUNT(*) as conn_count
                    FROM sys.dm_exec_sessions s
                    JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
                    GROUP BY client_net_address, program_name
"@
                $readerConn = $cmdConn.ExecuteReader()
                $connList = @()
                
                while ($readerConn.Read()) {
                    $connList += @{
                        client_net_address = $readerConn["client_net_address"]
                        program_name       = $readerConn["program_name"]
                        conn_count         = $readerConn["conn_count"]
                    }
                }
                $readerConn.Close()
                $conn.Close()

                if ($connList.Count -gt 0) {
                    $stat = @{
                        mdb_id         = $mdb_id
                        db_connections = ($connList | ConvertTo-Json -Compress -Depth 2)
                    }
                    $statsList += $stat
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

# 3. Send Data
if ($statsList.Count -gt 0) {
    try {
        $jsonPayload = $statsList | ConvertTo-Json -Compress
        Write-GiipLog "INFO" "[DbConnectionList] Sending data for $($statsList.Count) databases..."
        
        # Reuse MdbStatsUpdate API (Assuming it handles partial updates or specific fields)
        $response = Invoke-GiipApiV2 -Config $Config -CommandText "MdbStatsUpdate jsondata" -JsonData $jsonPayload
        
        if ($response.RstVal -eq "200") {
            Write-GiipLog "INFO" "[DbConnectionList] Success."
        }
        else {
            Write-GiipLog "WARN" "[DbConnectionList] API Error: $($response.RstVal) - $($response.RstMsg)"
        }
    }
    catch {
        Write-GiipLog "ERROR" "[DbConnectionList] Failed to send data: $_"
    }
}
else {
    Write-GiipLog "INFO" "[DbConnectionList] No connection data collected."
}

exit 0
