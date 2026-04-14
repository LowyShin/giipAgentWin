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
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson
    
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
        $stat = Get-GiipDbMetrics -DbInfo $db -LibDir $LibDir -Config $Config
        if ($stat) {
            $cmdText = "MdbStatsUpdate mdb_id uptime threads qps buffer_pool cpu memory query_hash"
            $statJson = $stat | ConvertTo-Json -Compress
            $response = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $statJson
            if ($response -and $response.RstVal -eq "200") {
                Write-GiipLog "INFO" "[DbMonitor] SUCCESS: DB $($db.mdb_id) metrics sent."
            } else {
                Write-GiipLog "WARN" "[DbMonitor] FAILED: DB $($db.mdb_id) API error."
            }
        }
    } catch {
        Write-GiipLog "ERROR" "[DbMonitor] Loop error: $_"
    }
}

Write-GiipLog "INFO" "[DbMonitor] Completed."
exit 0
