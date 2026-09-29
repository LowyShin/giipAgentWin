# ============================================================================
# DbMonitor.ps1 (Pure English Version)
# Purpose: Fetch registered DB list and collect performance metrics
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"
$DataDir = Join-Path $AgentRoot "data"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "DbCollector.ps1")
    . (Join-Path $LibDir "ErrorLog.ps1")
} catch {
    Write-Host "FATAL: Failed to load libraries. ($_)"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
} catch {
    Write-GiipLog "ERROR" "[DbMonitor] Config load failed: $_"
    exit 1
}

Write-GiipLog "INFO" "[DbMonitor] Starting DB Monitoring..."

# 1. Get DB List
try {
    $reqData = @{ lssn = $Config.lssn }
    $reqJson = $reqData | ConvertTo-Json -Compress
    # -RawList: this is a list endpoint (can return >1 managed database per lssn).
    # Without it, Invoke-GiipApiV2's default single-object unwrap silently
    # truncates the result to just the FIRST database returned (giip-issue #922
    # follow-up -- found live: a customer with 2 managed databases on the same
    # gateway only ever had the first one monitored).
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson -RawList

    $dbList = $null
    if ($response.data) { $dbList = $response.data }
    elseif ($response -is [Array]) { $dbList = $response }
    elseif ($response.mdb_id) { $dbList = @($response) }

    if (-not $dbList) {
        Write-GiipLog "INFO" "[DbMonitor] No databases found."
        exit 0
    }
    Write-GiipLog "INFO" "[DbMonitor] Found $($dbList.Count) databases."
} catch {
    Write-GiipLog "ERROR" "[DbMonitor] API request failed: $_"
    exit 1
}

# 2. Collect & Send Stats
$statsList = @()
foreach ($db in $dbList) {
    try {
        Write-GiipLog "DEBUG" "[DbMonitor] DB Object: $($db | ConvertTo-Json -Compress)"

        # giip-issue #922 follow-up (root cause for #921's db_perf_diag never appearing):
        # giipscripts/dpa-put-mssql-perfdiag.ps1 (PR #26) was added as a standalone
        # script but nothing ever invoked it -- no scheduled task, no caller anywhere
        # in this repo. This loop already has the exact per-DB list (host/port/user/
        # password/database) the script needs, so this is that missing trigger.
        # Read-only diagnostics only (Query Store SELECTs + Azure Monitor reads);
        # never modifies the target DB. Failures are logged and swallowed so a perf
        # diagnostics error never blocks the existing MdbStatsUpdate flow below.
        if ($db.db_type -and ($db.db_type -match '^(mssql|azuresql)$')) {
            try {
                $diagScript = Join-Path $ScriptDir "..\dpa-put-mssql-perfdiag.ps1"
                if (Test-Path $diagScript) {
                    $diagHost = if ($db.db_host) { $db.db_host } else { $db.ip }
                    $diagPort = if ($db.db_port) { $db.db_port } else { "1433" }
                    $diagDb = if ($db.db_database) { $db.db_database } elseif ($db.db_name) { $db.db_name } else { $null }
                    $diagUser = if ($db.db_user) { $db.db_user } else { $db.user }
                    $diagPass = if ($db.db_password) { $db.db_password } else { $db.pass }
                    if ($diagHost -and $diagDb -and $diagUser) {
                        $connStr = "Server=$diagHost,$diagPort;Initial Catalog=$diagDb;User ID=$diagUser;Password=$diagPass;TrustServerCertificate=True;Connect Timeout=15;"
                        Write-GiipLog "INFO" "[DbMonitor] Running MSSQL perf diagnostics (giip-921/922) for mdb_id=$($db.mdb_id)..."
                        & $diagScript -SqlConnectionString $connStr -MdbId ([int]$db.mdb_id)
                    } else {
                        Write-GiipLog "WARN" "[DbMonitor] Skipping perf diagnostics for mdb_id=$($db.mdb_id): missing host/database/user."
                    }
                }
            } catch {
                Write-GiipLog "WARN" "[DbMonitor] Perf diagnostics collection failed for mdb_id=$($db.mdb_id): $_"
            }
        }

        $stat = Get-GiipDbMetrics -DbInfo $db -LibDir $LibDir -Config $Config
        if ($stat) {
            # Create a clean, strictly-typed payload for the API
            $payload = [PSCustomObject]@{
                mdb_id      = [int]$db.mdb_id
                uptime      = [int]$stat.uptime
                threads     = [int]$stat.threads_connected
                qps         = [double]$stat.questions_per_sec
                buffer_pool = [double]$stat.buffer_pool_usage
                cpu         = [double]$stat.cpu_usage
                memory      = [double]$stat.memory_usage
                query_hash  = ""
            }
            
            $cmdText = "MdbStatsUpdate mdb_id uptime threads qps buffer_pool cpu memory query_hash"
            $statJson = $payload | ConvertTo-Json -Compress
            $response = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $statJson
            
            if ($response -and ($response.RstVal -eq "200" -or $response.RstVal -eq 200)) {
                Write-GiipLog "INFO" "[DbMonitor] SUCCESS: DB $($db.mdb_id) metrics sent."
            } else {
                Write-GiipLog "WARN" "[DbMonitor] FAILED: DB $($db.mdb_id) API error. Response: $($response | ConvertTo-Json -Compress)"
            }
        }
    } catch {
        Write-GiipLog "ERROR" "[DbMonitor] Loop error: $_"
    }
}

Write-GiipLog "INFO" "[DbMonitor] Completed."
exit 0
