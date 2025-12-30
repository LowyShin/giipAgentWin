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

# New: Load DbCollector Library
try {
    . (Join-Path $LibDir "DbCollector.ps1")
}
catch {
    Write-GiipLog "ERROR" "[DbMonitor] Failed to load DbCollector.ps1 from $LibDir"
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
            $body = @{
                text        = "MdbStatsUpdate"
                token       = $Config.sk
                mdb_id      = $mdb_id
                uptime      = $stat.uptime
                threads     = $stat.threads
                qps         = $stat.qps
                buffer_pool = $stat.buffer_pool
                cpu         = $stat.cpu
                memory      = $stat.memory
            }
        
            $apiUri = if ($Config.apiaddrv2) { $Config.apiaddrv2 } else { "https://giipfaw.azurewebsites.net/api/giipApiSk2" }
            $response = Invoke-RestMethod -Uri $apiUri -Method Post -Body ($body | ConvertTo-Json -Compress) -ContentType "application/json" -ErrorAction Stop
        
            if ($response.RstVal -eq "200") {
                Write-GiipLog "INFO" "[DbMonitor] ✅ MdbStatsUpdate SUCCESS for DB $mdb_id"
            }
            else {
                Write-GiipLog "WARN" "[DbMonitor] ⚠️ MdbStatsUpdate FAILED for DB ${mdb_id}: RstVal=$($response.RstVal), RstMsg=$($response.RstMsg)"
                
                # ErrorLog logic omitted for conciseness, preserving log file writing
                try {
                    $logDir = Join-Path $PSScriptRoot "..\\..\\logs"
                    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
                    $debugFile = Join-Path $logDir "dbmonitor_error_$mdb_id.json"
                    @{ Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); Request = $body; Response = $response } | ConvertTo-Json -Depth 5 | Set-Content -Path $debugFile -Encoding UTF8
                }
                catch {}
            }
        }
        catch {
            Write-GiipLog "ERROR" "[DbMonitor] ❌ Exception sending stats for DB ${mdb_id}: $_"
        }
    }
    
    # Save stats to local file for reference
    $statsList | ConvertTo-Json -Depth 5 | Set-Content -Path $DbStatsFile -Encoding UTF8
}
else {
    Write-GiipLog "WARN" "[DbMonitor] No metrics collected (Count=0)"
}

exit 0