# checkAgentHealth.ps1
# GIIP Windows Agent Self-Diagnostic Checklist

# Use the built-in $PSScriptRoot
. (Join-Path $PSScriptRoot "lib\Common.ps1")

$config = Get-GiipConfig
$lssn = $config.lssn

Write-Host " Starting Windows Agent Self-Diagnostic for LSSN: $lssn..."

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
# giip #3079: Invoke-GiipApiV2는 HTTP 400/500 응답에도 예외를 던지지 않고 응답
# 객체를 그대로 반환한다(네트워크 예외일 때만 $null) - 그래서 -ErrorAction Stop과
# try/catch만으로는 "API가 실패를 응답했다"는 사실을 절대 못 잡는다(항상 heartbeat
# = "OK"). 반환값의 RstVal을 실제로 확인한다.
try {
    $diagData = @{status = "alive" } | ConvertTo-Json -Compress
    $payloadData = @{kType = "lssn"; kKey = "$lssn"; kFactor = "diag_heartbeat"; kValue = $diagData } | ConvertTo-Json -Compress
    $hbResp = Invoke-GiipApiV2 -Config $config -CommandText "KVSPut kType kKey kFactor kValue" -JsonData $payloadData
    if (-not ($hbResp -and $hbResp.RstVal -eq "200")) {
        Write-GiipApiFailure -Config $config -Context "[checkAgentHealth] heartbeat KVS put" -Response $hbResp
        $checklist.features.heartbeat = "FAIL"
        $checklist.status = "FAIL"
    }
}
catch {
    Write-GiipLog "ERROR" "[checkAgentHealth] heartbeat KVS put threw: $_"
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
# giip #3079: 반환값을 확인하지 않던 버그 - 이 업로드 자체가 실패해도 아무 신호가
# 남지 않았다.
$reportData = @{kType = "lssn"; kKey = "$lssn"; kFactor = "agent_health_checklist"; kValue = $jsonBody } | ConvertTo-Json -Compress
$reportResp = Invoke-GiipApiV2 -Config $config -CommandText "KVSPut kType kKey kFactor kValue" -JsonData $reportData
if (-not ($reportResp -and $reportResp.RstVal -eq "200")) {
    Write-GiipApiFailure -Config $config -Context "[checkAgentHealth] agent_health_checklist KVS put" -Response $reportResp
}

Write-Host " Self-diagnostic completed with status: $($checklist.status)"

