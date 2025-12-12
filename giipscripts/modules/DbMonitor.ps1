# ============================================================================
# DbMonitor.ps1
# Purpose: Fetch registered DB list and collect performance metrics
# Usage: .\DbMonitor.ps1
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"
$DataDir = Join-Path $AgentRoot "data"
$DbStatsFile = Join-Path $DataDir "db_stats.json"

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
    Write-GiipLog "ERROR" "[DbMonitor] Failed to load config: $_"
    exit 1
}

Write-GiipLog "INFO" "[DbMonitor] Starting DB Monitoring..."

# 1. Get DB List from API
try {
    # Command: MdbList (No args needed, SK is sent automatically by Invoke-GiipApiV2)
    # Note: Invoke-GiipApiV2 sends lssn/hostname/os inside JSON payload by default, 
    # but MdbList endpoint might just need 'code=MdbList'.
    # Assuming standard API call structure:
    # Debug Info
    $maskedSk = if ($Config.sk -and $Config.sk.Length -gt 4) { $Config.sk.Substring(0, 4) + "****" } else { "Invalid SK" }
    Write-GiipLog "INFO" "[DbMonitor] Requesting DB List using SK: $maskedSk"

    # Send LSSN to allow filtering by gateway_lssn on server side
    $reqData = @{ lssn = $Config.lssn }
    $reqJson = $reqData | ConvertTo-Json -Compress
    
    # Use unified SP 'pApiManagedDatabaseListForAgentbySk' which supports optional LSSN filtering
    # API Rule: text="Cmd ParamName" -> exec pApiCmdBySk @sk, @ParamValue
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson
    
    # Detailed Debug
    Write-GiipLog "DEBUG" "[DbMonitor] Raw Response Type: $($response.GetType().Name)"
    try {
        $debugJson = $response | ConvertTo-Json -Depth 2 -Compress
        Write-GiipLog "DEBUG" "[DbMonitor] Raw Response Content: $debugJson"
    }
    catch {
        Write-GiipLog "DEBUG" "[DbMonitor] Raw Response Content: (Cannot serialize)"
    }

    if ($response.RstVal) {
        Write-GiipLog "INFO" "[DbMonitor] API Result: Val=$($response.RstVal), Msg=$($response.RstMsg)"
    }
    
    $dbList = $null
    
    # Case 1: Wrapped in 'data' property
    if ($response.data) { 
        $dbList = $response.data 
    }
    # Case 2: Array of DBs (Standard list)
    elseif ($response -is [Array]) { 
        $dbList = $response 
    }
    # Case 3: Single DB Object (1 item returned) - Check for known property
    elseif ($response.mdb_id) {
        Write-GiipLog "INFO" "[DbMonitor] Single DB detected."
        $dbList = @($response)
    }

    if (-not $dbList) {
        Write-GiipLog "INFO" "[DbMonitor] No databases found to monitor (dbList is empty)."
        exit 0
    }

    # Ensure it's an array/collection for the loop
    if (-not ($dbList -is [Array] -or $dbList -is [System.Collections.IEnumerable])) {
        $dbList = @($dbList)
    }

    Write-GiipLog "INFO" "[DbMonitor] Found $($dbList.Count) databases to monitor."

}
catch {
    Write-GiipLog "ERROR" "[DbMonitor] Failed to get DB list: $_"
    exit 1
}

# 2. Collect Stats
$statsList = @()

foreach ($db in $dbList) {
    try {
        $mdb_id = $db.mdb_id
        $db_type = $db.db_type
        $dbHost = $db.db_host
        $port = $db.db_port
        $user = $db.db_user
        $pass = $db.db_password # Decrypted by SP

        Write-GiipLog "DEBUG" "[DbMonitor] Checking DB: $mdb_id ($db_type) at $dbHost"
        
        $stat = @{
            mdb_id      = $mdb_id
            uptime      = 0
            threads     = 0
            qps         = 0
            buffer_pool = 0
            cpu         = 0
            memory      = 0
        }

        if ($db_type -eq 'MSSQL') {
            # MSSQL Collection using .NET SqlClient
            try {
                $connStr = "Server=$dbHost,$port;Database=master;User Id=$user;Password=$pass;TrustServerCertificate=True;Connection Timeout=10;"
                $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
                $conn.Open()
                
                # Simple Metrics
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
                    SELECT 
                        (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'User Connections') as threads,
                        (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Batch Requests/sec') as qps, -- This is cumulative, need delta (simplified for now)
                        (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Total Server Memory (KB)') as memory_kb,
                        (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) as start_time
"@
                $reader = $cmd.ExecuteReader()
                if ($reader.Read()) {
                    $stat.threads = $reader["threads"]
                    $stat.qps = $reader["qps"]
                    
                    $mem_kb = $reader["memory_kb"]
                    $stat.memory = [math]::Round([double]$mem_kb / 1024, 0)
                    
                    $startTime = $reader["start_time"]
                    if ($startTime) {
                        $stat.uptime = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
                    }
                }
                $conn.Close()
                $statsList += $stat
            }
            catch {
                Write-GiipLog "WARN" "[DbMonitor] MSSQL Connection failed for $($dbHost): $_"
            }
        }
        elseif ($db_type -match 'MySQL|MariaDB') {
            # MySQL Collection
            # Requires MySql.Data.dll or similar.
            # Attempt to load assembly if present in lib
            $dllPath = Join-Path $LibDir "MySql.Data.dll"
            if (Test-Path $dllPath) {
                try {
                    [void][System.Reflection.Assembly]::LoadFile($dllPath)
                    $connStr = "Server=$dbHost;Port=$port;Uid=$user;Pwd=$pass;SslMode=None;Connection Timeout=10;"
                    $conn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
                    $conn.Open()
                    
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected', 'Questions', 'Innodb_buffer_pool_pages_total', 'Innodb_buffer_pool_pages_free', 'Uptime')"
                    $reader = $cmd.ExecuteReader()
                    
                    $questions = 0
                    while ($reader.Read()) {
                        $name = $reader["Variable_name"]
                        $val = $reader["Value"]
                        
                        switch ($name) {
                            'Threads_connected' { $stat.threads = [int]$val }
                            'Uptime' { $stat.uptime = [long]$val }
                            'Questions' { $stat.qps = [float]$val } # Cumulative
                            'Innodb_buffer_pool_pages_total' { $total_pages = [float]$val }
                            'Innodb_buffer_pool_pages_free' { $free_pages = [float]$val }
                        }
                    }
                    if ($total_pages -gt 0) {
                        $stat.buffer_pool = [math]::Round((($total_pages - $free_pages) / $total_pages) * 100, 2)
                    }
                    $conn.Close()
                    $statsList += $stat
                }
                catch {
                    Write-GiipLog "WARN" "[DbMonitor] MySQL Error for $($dbHost): $_"
                }
            }
            else {
                Write-GiipLog "WARN" "[DbMonitor] Skipping MySQL $($dbHost): MySql.Data.dll not found in lib."
            }
        }
        else {
            Write-GiipLog "INFO" "[DbMonitor] DB Type $db_type not supported yet."
        }
    }
    catch {
        Write-GiipLog "ERROR" "[DbMonitor] Unexpected error on DB loop: $_"
    }
}

# 3. Send Stats
if ($statsList.Count -gt 0) {
    try {
        $jsonPayload = $statsList | ConvertTo-Json -Compress
        Write-GiipLog "INFO" "[DbMonitor] Sending stats for $($statsList.Count) databases..."
        
        # Must include 'jsondata' to pass payload to SP
        $response = Invoke-GiipApiV2 -Config $Config -CommandText "MdbStatsUpdate jsondata" -JsonData $jsonPayload
        
        if ($response.RstVal -eq "200") {
            Write-GiipLog "INFO" "[DbMonitor] Success."
        }
        else {
            Write-GiipLog "WARN" "[DbMonitor] API Error: $($response.RstVal) - $($response.RstMsg)"
        }
    }
    catch {
        Write-GiipLog "ERROR" "[DbMonitor] Failed to send stats: $_"
    }
}
else {
    Write-GiipLog "INFO" "[DbMonitor] No metrics collected."
}

exit 0
