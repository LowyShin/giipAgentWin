# tests/Test-SchedulerAgentRegister.ps1 - giip #2470
#
# lib/SchedulerAgentRegister.ps1 의 404 폭주 억제(백오프) 로직을 검증한다.
# 네트워크/SP 호출이 필요 없는 순수 상태 관리 부분만 대상으로 한다
# (Invoke-SchedulerAgentUpsert 자체는 라이브 API 호출이라 여기서 다루지 않는다).
#
#   1) 백오프 분(minute) 계산이 5 -> 10 -> 20 -> 40 -> 60(상한) 으로 증가하고
#      절대 0 이 되지 않는다(= 영원히 침묵하지 않는다)
#   2) 상태파일이 없으면 "실패 없음" 기본값을 돌려준다
#   3) 첫 실패가 firstSeenUtc 를 기록하고 totalCount 를 1 로 만든다
#   4) 연속 실패가 totalCount/consecutiveCount 를 누적한다
#   5) 백오프 창 안에서는 Test-SchedulerAgentBackoffActive 가 $true
#   6) 백오프 창이 지나면 $false (반드시 재시도한다)
#   7) 복구 시 백오프는 풀리지만 firstSeenUtc/totalCount 는 보존된다
#      (= 에러를 조용히 버리지 않는다)
#   8) 상태파일이 깨져 있어도 예외 없이 기본값으로 복구된다
#
# 스타일 참고: tests/Test-ProcessLock.ps1
# 실행: powershell -NoProfile -File tests\Test-SchedulerAgentRegister.ps1

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Path -Parent) -Parent

$script:PassCount = 0
$script:FailCount = 0

function Assert-Eq {
    param([string]$Desc, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        Write-Host "  [PASS] $Desc"
        $script:PassCount++
    } else {
        Write-Host "  [FAIL] $Desc (expected='$Expected' actual='$Actual')"
        $script:FailCount++
    }
}

function Assert-True {
    param([string]$Desc, [bool]$Condition)
    if ($Condition) {
        Write-Host "  [PASS] $Desc"
        $script:PassCount++
    } else {
        Write-Host "  [FAIL] $Desc"
        $script:FailCount++
    }
}

# Write-GiipLog 는 Common.ps1 에 있지만, 이 테스트는 라이브 의존성을 피하려고
# 라이브러리를 단독 dot-source 한다 - 없으면 조용한 스텁을 깔아 준다.
if (-not (Get-Command "Write-GiipLog" -ErrorAction SilentlyContinue)) {
    function Write-GiipLog { param($Level, $Message) }
}

. (Join-Path $RepoRoot "lib\SchedulerAgentRegister.ps1")

$Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("giip2470_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null

try {
    # --- 1) 백오프 증가 곡선 + 상한 -------------------------------------------
    Assert-Eq "1a) 0 failures -> 0 minutes (no backoff)"  0  (Get-SchedulerAgentBackoffMinutes -FailureCount 0)
    Assert-Eq "1b) 1 failure -> 5 minutes"                   5  (Get-SchedulerAgentBackoffMinutes -FailureCount 1)
    Assert-Eq "1c) 2 failures -> 10 minutes"                 10  (Get-SchedulerAgentBackoffMinutes -FailureCount 2)
    Assert-Eq "1d) 3 failures -> 20 minutes"                 20  (Get-SchedulerAgentBackoffMinutes -FailureCount 3)
    Assert-Eq "1e) 4 failures -> 40 minutes"                 40  (Get-SchedulerAgentBackoffMinutes -FailureCount 4)
    Assert-Eq "1f) 5 failures -> 60 minutes (cap)"           60  (Get-SchedulerAgentBackoffMinutes -FailureCount 5)
    Assert-Eq "1g) 99 failures still capped at 60 minutes"    60  (Get-SchedulerAgentBackoffMinutes -FailureCount 99)
    Assert-True "1h) never returns 0 minutes (no permanent silence)" `
        ((1..99 | ForEach-Object { Get-SchedulerAgentBackoffMinutes -FailureCount $_ } | Where-Object { $_ -le 0 }).Count -eq 0)

    # --- 2) 상태파일 없음 -----------------------------------------------------
    $StatePath = Get-SchedulerAgentStatePath -StateDir $Sandbox
    Assert-True "2a) state path resolves under StateDir" ($StatePath -like "$Sandbox*")
    $s = Read-SchedulerAgentFailState -StatePath $StatePath
    Assert-Eq "2b) missing state file -> totalCount=0" 0 $s.totalCount
    Assert-True "2c) missing state file -> firstSeenUtc is null" ($null -eq $s.firstSeenUtc)
    Assert-True "2d) missing state file -> backoff inactive" (-not (Test-SchedulerAgentBackoffActive -StatePath $StatePath))

    # --- 3) 첫 실패 -----------------------------------------------------------
    $s1 = Add-SchedulerAgentFailure -StatePath $StatePath -Reason "404|Agent not found"
    Assert-Eq "3a) first failure -> totalCount=1" 1 $s1.totalCount
    Assert-Eq "3b) first failure -> consecutiveCount=1" 1 $s1.consecutiveCount
    Assert-True "3c) first failure records firstSeenUtc" ($null -ne $s1.firstSeenUtc)
    $firstSeen = $s1.firstSeenUtc

    # --- 4) 연속 실패 누적 ----------------------------------------------------
    $s2 = Add-SchedulerAgentFailure -StatePath $StatePath -Reason "404|Agent not found"
    Assert-Eq "4a) second failure -> totalCount=2" 2 $s2.totalCount
    Assert-Eq "4b) second failure -> consecutiveCount=2" 2 $s2.consecutiveCount
    Assert-Eq "4c) firstSeenUtc is preserved across failures" $firstSeen $s2.firstSeenUtc

    # --- 5) 백오프 창 안이면 스킵 ---------------------------------------------
    Assert-True "5) backoff active right after a failure (API call skipped)" `
        (Test-SchedulerAgentBackoffActive -StatePath $StatePath)

    # --- 6) 백오프 창이 지나면 재시도 -----------------------------------------
    $expired = Read-SchedulerAgentFailState -StatePath $StatePath
    $expired.nextAttemptUtc = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString("o")
    Save-SchedulerAgentFailState -StatePath $StatePath -State $expired
    Assert-True "6) backoff expires -> retries again (not permanently suppressed)" `
        (-not (Test-SchedulerAgentBackoffActive -StatePath $StatePath))

    # --- 7) 복구 시 통계는 보존 -----------------------------------------------
    Clear-SchedulerAgentBackoff -StatePath $StatePath
    $s3 = Read-SchedulerAgentFailState -StatePath $StatePath
    Assert-Eq "7a) after recovery consecutiveCount=0" 0 $s3.consecutiveCount
    Assert-True "7b) after recovery backoff is inactive" (-not (Test-SchedulerAgentBackoffActive -StatePath $StatePath))
    Assert-Eq "7c) after recovery totalCount is preserved" 2 $s3.totalCount
    Assert-Eq "7d) after recovery firstSeenUtc is preserved" $firstSeen $s3.firstSeenUtc

    # --- 8) 손상된 상태파일 ---------------------------------------------------
    Set-Content -Path $StatePath -Value "{ this is not json" -Encoding UTF8 -Force
    $s4 = Read-SchedulerAgentFailState -StatePath $StatePath
    Assert-Eq "8a) corrupt state file -> defaults, no exception" 0 $s4.totalCount
    Assert-True "8b) corrupt state file -> backoff inactive (never blocks the agent)" `
        (-not (Test-SchedulerAgentBackoffActive -StatePath $StatePath))

} finally {
    Remove-Item -Path $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Results: $($script:PassCount) passed, $($script:FailCount) failed ==="
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
