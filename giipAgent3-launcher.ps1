# ============================================================================
# giipAgent3-launcher.ps1
# Purpose: Windowless replacement for giipAgent3.bat.
#          Runs git-auto-sync.ps1 (pull latest) then giipAgent3.ps1, all inside
#          the SAME PowerShell process so no cmd.exe/console window is ever
#          spawned. Invoked by Task Scheduler as
#          "conhost.exe --headless powershell.exe -File giipAgent3-launcher.ps1"
#          - see TaskSchdReg.ps1.
#          ("powershell.exe -WindowStyle Hidden" alone can still briefly
#          flash a console window on some Windows builds/logon types.)
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
Set-Location $ScriptDir

# 구 버전 등록(wscript.exe + giipAgent3-silent.vbs)을 쓰는 머신은 git pull 로 vbs 가
# 사라지면 에이전트가 멈춘다. 이 launcher 가 한 번이라도 실행되면(vbs 경유 포함)
# 작업을 conhost --headless 방식으로 다시 등록한다.
try {
    $regTask = Get-ScheduledTask -TaskName "GIIP Agent Task (v3)" -ErrorAction Stop
    if ($regTask.Actions[0].Execute -like "*wscript*") {
        & (Join-Path $ScriptDir "TaskSchdReg.ps1") | Out-Null
    }
} catch {
    Write-Host "WARN: task migration check failed: $_"
}

# giip #3079 (사용자 지시 2026-09-26): "어떤 상태라도 독립적으로 git pull이 성공해야
# 해야, 수정된 파일을 각 머신들이 받아서 업데이트하지" - 기존 코드는 이미 sync를
# giipAgent3.ps1 실행 "이전"에 실행해서 에이전트 본 로직(API 호출 등)의 실패가 sync를
# 막을 수는 없는 구조였다. 다만 반대 방향 결합이 있었다: sync가 실패하면(exit 1)
# 이번 주기의 giipAgent3.ps1 자체를 통째로 건너뛰었다(exit 1로 launcher 종료) - 코드
# 갱신 실패와 모니터링/보고 업무 사이에는 인과관계가 없으므로 이것도 분리한다.
# 추가로 & 호출 자체가 예기치 못한 종료 예외를 던져도(-ErrorActionPreference가
# 상위 스코프에서 "Stop"인 이 launcher에서) giipAgent3.ps1 실행이 막히지 않도록
# try/catch로 감싼다.
$syncScript = Join-Path $ScriptDir "git-auto-sync.ps1"
if (Test-Path $syncScript) {
    Write-Host "Starting Safe Git Sync..."
    $syncExitCode = 1
    try {
        & $syncScript
        $syncExitCode = $LASTEXITCODE
    } catch {
        Write-Host "ERROR: git-auto-sync.ps1 threw an unexpected exception: $_"
        $syncExitCode = 1
    }
    if ($syncExitCode -ne 0) {
        Write-Host "ERROR: Sync failed (exit=$syncExitCode). Continuing to run giipAgent3.ps1 anyway - the next scheduled run (5 min) will retry the sync independently."
    } else {
        Write-Host "Safe Git Sync completed successfully."
    }
} else {
    Write-Host "WARN: git-auto-sync.ps1 not found at $syncScript. Skipping sync."
}

Write-Host "Starting giipAgent3.ps1..."
$agentScript = Join-Path $ScriptDir "giipAgent3.ps1"
& $agentScript
$exitCode = $LASTEXITCODE
Write-Host "giipAgent3.ps1 execution ended [ExitCode: $exitCode]"
exit $exitCode
