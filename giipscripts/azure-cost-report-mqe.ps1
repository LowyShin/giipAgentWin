# ============================================================================
# azure-cost-report-mqe.ps1
# Purpose : azure-cost 수집 요약 스냅샷 2개(이번/직전)를 비교해 MQE(tMQLog)에
#           일일 증감 보고서를 등록한다. 수동 재발송 · 테스트용 진입점이다.
#           정규 경로(매일 자동)는 azure-cost-put-win.ps1 이 수집 직후 같은
#           lib 함수를 호출해 처리한다 — 이 스크립트는 그 경로를 대체하지 않는다.
# 스냅샷  : azure-cost-put-win.ps1 이 매 실행마다
#           giipLogs/azure/azure_cost_summary_<factor>_<yyyyMMdd>.json 로 남긴다.
# 이슈    : giip #2604
#
# 사용 예:
#   # 전날 스냅샷과 비교해 실제로 MQE 에 등록
#   powershell -NoProfile -ExecutionPolicy Bypass -File giipscripts\azure-cost-report-mqe.ps1 `
#     -CurrentFile "..\giipLogs\azure\azure_cost_summary_azure_cost_20260916.json" `
#     -PreviousFile "..\giipLogs\azure\azure_cost_summary_azure_cost_20260915.json"
#
#   # 전날 데이터가 없는 경우(최초 실행/수집 실패)를 그대로 보고 - PreviousFile 생략
#   powershell -NoProfile -ExecutionPolicy Bypass -File giipscripts\azure-cost-report-mqe.ps1 `
#     -CurrentFile "..\giipLogs\azure\azure_cost_summary_azure_cost_20260916.json" -DryRun
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CurrentFile,
    # 생략하면 "직전 수집 레코드 없음"으로 정직하게 보고한다(0 으로 치지 않는다).
    [string]$PreviousFile,
    # -1 이면 cfg 의 azure_cost_alert_pct, 그것도 없으면 10 을 쓴다(하드코딩 금지).
    [double]$AlertThresholdPercent = -1,
    [string]$Lssn = "",
    # 비우면 cfg 의 mqe_to, 그것도 없으면 mqTo 를 아예 넣지 않는다(csn 기본 수신처 사용).
    [string]$MqeTo = "",
    [string]$MqType = "slack",
    # 비우면 cfg 의 sk. **이 SK 가 곧 보고서가 들어갈 cSn 을 결정한다.**
    [string]$Sk = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path $ScriptDir -Parent
$LibDir    = Join-Path $AgentRoot "lib"
$Global:BaseDir = $AgentRoot

. (Join-Path $LibDir "Common.ps1")
. (Join-Path $LibDir "Mqe.ps1")
. (Join-Path $LibDir "AzureCostReport.ps1")

if (-not (Test-Path $CurrentFile)) {
    Write-Host "[ERROR] CurrentFile not found: $CurrentFile"
    exit 1
}

$Config = Get-GiipConfig

$current = (Get-Content -Path $CurrentFile -Raw -Encoding UTF8) | ConvertFrom-Json
$previous = $null
if ($PreviousFile) {
    if (Test-Path $PreviousFile) {
        $previous = (Get-Content -Path $PreviousFile -Raw -Encoding UTF8) | ConvertFrom-Json
    } else {
        Write-Host "[WARN] PreviousFile not found: $PreviousFile -- '비교 불가'로 보고한다."
    }
}

$threshold = Resolve-AzureCostAlertThreshold -Config $Config -Requested $AlertThresholdPercent
$lssnValue = $Lssn
if (-not $lssnValue) { $lssnValue = [string]$Config.lssn }

if ($DryRun) {
    # 등록 없이 판정과 본문만 확인한다.
    $report = New-AzureCostDeltaReport -Current $current -Previous $previous -ThresholdPercent $threshold -Lssn $lssnValue
    Write-Host "---- SUBJECT ----"
    Write-Host $report.Subject
    Write-Host "---- BODY ----"
    Write-Host $report.Body
    Write-Host "---- META ----"
    Write-Host ("Comparable={0} IsAlert={1} Threshold={2}" -f $report.Comparable, $report.IsAlert, $threshold)
    Write-Host "[INFO] -DryRun 지정: MQE 등록을 건너뛴다."
    exit 0
}

# 수집기(azure-cost-put-win.ps1)와 **똑같은** 진입점을 쓴다 — 판정/제목/본문이 갈라지지 않도록.
$sent = Send-AzureCostDeltaReport -Config $Config -Current $current -Previous $previous `
    -ThresholdPercent $AlertThresholdPercent -Lssn $lssnValue -To $MqeTo -Type $MqType -Sk $Sk
$report = $sent.Report
$result = $sent.MqResult

Write-Host "---- SUBJECT ----"
Write-Host $report.Subject
Write-Host "---- BODY ----"
Write-Host $report.Body
Write-Host "---- META ----"
Write-Host ("Comparable={0} IsAlert={1} Threshold={2}" -f $report.Comparable, $report.IsAlert, $sent.Threshold)

Write-Host ("[INFO] MQE result: Ok={0} Skipped={1} RstVal={2} mqSn={3} RstMsg='{4}'" -f `
    $result.Ok, $result.Skipped, $result.RstVal, $result.MqSn, $result.RstMsg)

if ($result.Ok) { exit 0 }
if ($result.Skipped) { exit 2 }   # 중복방지 게이트 스킵 -- 성공 아님
exit 1
