# tests/Test-ProcessLock.ps1 - giip #2338
#
# lib/ProcessLock.ps1의 Enter-GiipAgentLock/Exit-GiipAgentLock을 실제 프로세스
# 기동/종료를 곁들여 검증한다:
#   1) lock 없음 -> 바로 획득
#   2) lock 있고 살아있는 PID가 임계값(테스트에서는 짧게 오버라이드) 미만 ->
#      중복실행으로 보고 진행 거부
#   3) lock 있고 살아있는 PID가 임계값 이상 -> 강제 종료 후 lock 재획득
#      (실제로 무해한 하위 프로세스를 띄워 죽이고, 죽었는지까지 확인)
#   4) lock의 PID가 이미 죽어있음 -> 바로 재획득
#   5) lock 파일이 손상됨(JSON 파싱 실패) -> 바로 재획득
#   6) Exit-GiipAgentLock은 현재 PID가 소유한 lock만 지운다
#
# 스타일 참고: tests/Test-LogCollector-OffsetRotation.ps1 - 단순 assert +
# PASS/FAIL 카운트 + 종료 코드.
# 실행: powershell -NoProfile -File tests\Test-ProcessLock.ps1

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

# --- source the script under test ---------------------------------------------
. (Join-Path $RepoRoot "lib\ProcessLock.ps1")

$Sandbox = Join-Path $env:TEMP ("giipAgentWin-ProcessLock-Test-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Force -Path $Sandbox | Out-Null
$LockPath = Join-Path $Sandbox "giipAgent3.lock"

$script:HelperProcess = $null

try {
    # --- 1) no lock file -> acquired immediately ------------------------------
    $r1 = Enter-GiipAgentLock -LockPath $LockPath -StaleThresholdMinutes 30
    Assert-True "1) no lock: ShouldProceed" $r1.ShouldProceed
    Assert-Eq   "1) no lock: Status" "AcquiredNoLock" $r1.Status
    Assert-True "1) lock file now exists" (Test-Path $LockPath)
    $written = Get-Content -Path $LockPath -Raw | ConvertFrom-Json
    Assert-Eq   "1) lock file owned by current PID" $PID $written.Pid

    # --- 6a) Exit-GiipAgentLock removes a lock we own --------------------------
    Exit-GiipAgentLock -LockPath $LockPath
    Assert-True "6a) lock removed after Exit-GiipAgentLock (own PID)" (-not (Test-Path $LockPath))

    # --- 2) fresh lock owned by a live PID (< threshold) -> AlreadyRunning -----
    # Use our own process id as a stand-in "live PID" (this test process is
    # obviously alive for the duration of the test).
    $freshPayload = [ordered]@{
        Pid          = $PID
        StartTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString("o")
        Host         = $env:COMPUTERNAME
    }
    ($freshPayload | ConvertTo-Json -Compress) | Set-Content -Path $LockPath -Encoding UTF8 -Force

    $r2 = Enter-GiipAgentLock -LockPath $LockPath -StaleThresholdMinutes 30
    Assert-True "2) fresh live lock: ShouldProceed is false" (-not $r2.ShouldProceed)
    Assert-Eq   "2) fresh live lock: Status" "AlreadyRunning" $r2.Status

    # --- 3) stale lock owned by a live PID (>= threshold) -----------------------
    # Spawn a real, harmless helper process to be the "hung" instance so we can
    # confirm Enter-GiipAgentLock actually force-kills it.
    $script:HelperProcess = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 600") `
        -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    Assert-True "3) helper process is alive before test" ((Get-Process -Id $script:HelperProcess.Id -ErrorAction SilentlyContinue) -ne $null)

    $stalePayload = [ordered]@{
        Pid          = $script:HelperProcess.Id
        StartTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-31).ToString("o")
        Host         = $env:COMPUTERNAME
    }
    ($stalePayload | ConvertTo-Json -Compress) | Set-Content -Path $LockPath -Encoding UTF8 -Force

    $r3 = Enter-GiipAgentLock -LockPath $LockPath -StaleThresholdMinutes 30
    Assert-True "3) stale live lock: ShouldProceed" $r3.ShouldProceed
    Assert-Eq   "3) stale live lock: Status" "AcquiredKilledStale" $r3.Status
    Start-Sleep -Milliseconds 500
    Assert-True "3) helper (formerly-hung) process was killed" (-not (Get-Process -Id $script:HelperProcess.Id -ErrorAction SilentlyContinue))
    $afterKillLock = Get-Content -Path $LockPath -Raw | ConvertFrom-Json
    Assert-Eq   "3) lock reclaimed by current PID after kill" $PID $afterKillLock.Pid
    $script:HelperProcess = $null

    # --- 4) lock references an already-dead PID --------------------------------
    # Spawn + immediately stop a helper to get a guaranteed-dead-but-recently-
    # valid PID (avoids relying on PID reuse of some arbitrary fixed number).
    $deadHelper = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", "exit 0") `
        -WindowStyle Hidden -PassThru
    $deadHelper.WaitForExit(5000) | Out-Null
    Start-Sleep -Milliseconds 300
    $deadPayload = [ordered]@{
        Pid          = $deadHelper.Id
        StartTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString("o")
        Host         = $env:COMPUTERNAME
    }
    ($deadPayload | ConvertTo-Json -Compress) | Set-Content -Path $LockPath -Encoding UTF8 -Force

    $r4 = Enter-GiipAgentLock -LockPath $LockPath -StaleThresholdMinutes 30
    Assert-True "4) dead-PID lock: ShouldProceed" $r4.ShouldProceed
    Assert-Eq   "4) dead-PID lock: Status" "AcquiredDeadProcess" $r4.Status

    # --- 5) corrupt lock file ---------------------------------------------------
    "{ this is not valid json" | Set-Content -Path $LockPath -Encoding UTF8 -Force
    $r5 = Enter-GiipAgentLock -LockPath $LockPath -StaleThresholdMinutes 30
    Assert-True "5) corrupt lock: ShouldProceed" $r5.ShouldProceed
    Assert-Eq   "5) corrupt lock: Status" "AcquiredCorruptLock" $r5.Status

    # --- 6b) Exit-GiipAgentLock does NOT remove a lock owned by another PID ----
    $otherPayload = [ordered]@{
        Pid          = 999999
        StartTimeUtc = (Get-Date).ToUniversalTime().ToString("o")
        Host         = $env:COMPUTERNAME
    }
    ($otherPayload | ConvertTo-Json -Compress) | Set-Content -Path $LockPath -Encoding UTF8 -Force
    Exit-GiipAgentLock -LockPath $LockPath
    Assert-True "6b) lock NOT removed when owned by a different PID" (Test-Path $LockPath)

} finally {
    if ($script:HelperProcess -and (Get-Process -Id $script:HelperProcess.Id -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $script:HelperProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Results: $($script:PassCount) passed, $($script:FailCount) failed ==="
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
