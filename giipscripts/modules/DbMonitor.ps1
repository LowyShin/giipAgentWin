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

# New: Load DbCollector & ErrorLog Libraries
try {
    . (Join-Path $LibDir "DbCollector.ps1")
    . (Join-Path $LibDir "ErrorLog.ps1")
}
catch {
    Write-GiipLog "ERROR" "[DbMonitor] Failed to load libraries from $LibDir"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
}
catch {
    Write-GiipLog "ERROR" "[DbMonitor] Failed to load config: $_"
    # ErrorLog fallback removed for brevity, assuming standard setup
    exit 1
}

Write-GiipLog "INFO" "[DbMonitor] Starting DB Monitoring..."

# 1. Get DB List from API
try {
    $maskedSk = if ($Config.sk -and $Config.sk.Length -gt 4) { $Config.sk.Substring(0, 4) + "****" } else { "Invalid SK" }
    Write-GiipLog "INFO" "[DbMonitor] Requesting DB List using SK: $maskedSk"

    $reqData = @{ lssn = $Config.lssn }
    $reqJson = $reqData | ConvertTo-Json -Compress
    
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson
    
    if ($response.RstVal) {
        Write-GiipLog "INFO" "[DbMonitor] API Result: Val=$($response.RstVal), Msg=$($response.RstMsg)"
    }
    
    $dbList = $null
    
    if ($response.data) { $dbList = $response.data }
    elseif ($response -is [Array]) { $dbList = $response }
    elseif ($response.mdb_id) { $dbList = @($response) }

    if (-not $dbList) {
        Write-GiipLog "INFO" "[DbMonitor] No databases found to monitor."
        exit 0
    }

    if (-not ($dbList -is [Array] -or $dbList -is [System.Collections.IEnumerable])) {
        $dbList = @($dbList)
    }

    Write-GiipLog "INFO" "[DbMonitor] Found $($dbList.Count) databases to monitor."
}
catch {
    Write-GiipLog "ERROR" "[DbMonitor] Failed to get DB list: $_"
    exit 1
}

# 2. Collect Stats (Using DbCollector)
$statsList = @()

foreach ($db in $dbList) {
    try {
        $stat = Get-GiipDbMetrics -DbInfo $db -LibDir $LibDir -Config $Config
        if ($stat) {
            $statsList += $stat
        }
    }
    catch {
        Write-GiipLog "ERROR" "[DbMonitor] Unexpected error on DB loop: $_"
    }
}

# 3. Send Stats
if ($statsList.Count -gt 0) {
    Write-GiipLog "INFO" "[DbMonitor] Metrics collected successfully ($($statsList.Count)), preparing to send."

    foreach ($stat in $statsList) {
        $mdb_id = $stat.mdb_id
        
        try {
            # 🔧 Fixed: Simplified CommandText to avoid SQL type conversion errors
            # The API gateway will pass $statJson to @jsondata in pApiMdbStatsUpdatebySk
            $cmdText = "MdbStatsUpdate"
            $statJson = $stat | ConvertTo-Json -Compress
            
            $response = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $statJson
        
            if ($response -and $response.RstVal -eq "200") {
                Write-GiipLog "INFO" "[DbMonitor] ✅ MdbStatsUpdate SUCCESS for DB $mdb_id"
            }
            else {
                $rstVal = if ($response) { $response.RstVal } else { "NULL" }
                $rstMsg = if ($response) { $response.RstMsg } else { "No response" }
                Write-GiipLog "WARN" "[DbMonitor] ⚠️ MdbStatsUpdate FAILED for DB ${mdb_id}: RstVal=$rstVal, RstMsg=$rstMsg"
                
                # Use standard error logging to server
                sendErrorLog -Config $Config -Message "[DbMonitor] MdbStatsUpdate API FAILED for DB $mdb_id" -Data $stat -Severity "error"
            }
        }
        catch {
            Write-GiipLog "ERROR" "[DbMonitor] ❌ Exception sending stats for DB ${mdb_id}: $_"
            sendErrorLog -Config $Config -Message "[DbMonitor] Exception in Send Loop" -Data $_.Exception -Severity "critical"
        }
    }
    
    # Save stats to local file for reference
    $statsList | ConvertTo-Json -Depth 5 | Set-Content -Path $DbStatsFile -Encoding UTF8
}
else {
    Write-GiipLog "WARN" "[DbMonitor] No metrics collected (Count=0)"
}

exit 0