# checkAgentHealth.ps1
# GIIP Windows Agent Self-Diagnostic Checklist

# Use the built-in $PSScriptRoot
. (Join-Path $PSScriptRoot "lib\Common.ps1")

$config = Get-GiipConfig
$lssn = $config.lssn

Write-Host "🔍 Starting Windows Agent Self-Diagnostic for LSSN: $lssn..."

$checklist = @{
    check_time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    status     = "PASS"
    features   = @{
        heartbeat          = "OK"
        system_info        = "OK"
        crontab_list       = "SKIP" # Windows doesn't use crontab
        db_performance     = "SKIP"
        remote_server_info = "SKIP"
    }
}

# 1. Heartbeat Check
try {
    $diagData = @{status = "alive" } | ConvertTo-Json -Compress
    $payloadData = @{kType = "lssn"; kKey = "$lssn"; kFactor = "diag_heartbeat"; kValue = $diagData } | ConvertTo-Json -Compress
    Invoke-GiipApiV2 -Config $config -CommandText "KVSPut kType kKey kFactor" -JsonData $payloadData -ErrorAction Stop | Out-Null
}
catch {
    $checklist.features.heartbeat = "FAIL"
    $checklist.status = "FAIL"
}

# 2. System Info (PowerShell commands check)
if (!(Get-Command Get-WmiObject -ErrorAction SilentlyContinue) -and !(Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
    $checklist.features.system_info = "FAIL"
    $checklist.status = "FAIL"
}

# 3. DB Performance (If it's a DB monitor)
if (Test-Path (Join-Path $PSScriptRoot "lib\DbMonitor.ps1")) {
    $checklist.features.db_performance = "OK"
}

$jsonBody = $checklist | ConvertTo-Json -Compress

# Report to KVS
$reportData = @{kType = "lssn"; kKey = "$lssn"; kFactor = "agent_health_checklist"; kValue = $jsonBody } | ConvertTo-Json -Compress
Invoke-GiipApiV2 -Config $config -CommandText "KVSPut kType kKey kFactor" -JsonData $reportData

Write-Host "✅ Self-diagnostic completed with status: $($checklist.status)"
