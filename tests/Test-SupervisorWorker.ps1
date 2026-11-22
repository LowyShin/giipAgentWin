# tests/Test-SupervisorWorker.ps1 - giip #6163
#
# giipAgent3.ps1(슈퍼바이저) / giipAgentWorker.ps1(워커) 분리의 핵심 성질을
# 실제 프로세스로 검증한다. 검증 대상은 "한 Step 이 멈춰도 전체 사이클이
# 멈추지 않는다"(giip #5924 - Step 7 한 행이 3일간 전체 사이클을 정지) 이다.
#
# 검증 방식: 레포를 임시 사본으로 복사한 뒤 Step 모듈을 스텁으로 교체하고,
# 사본의 giipAgent3.ps1 을 그대로 실행한다(프로덕션 코드 경로와 동일).
#
#   1) 타임아웃
#      - Step 3 모듈을 "무한 sleep" 스텁으로 교체한다.
#      - 워커가 타임아웃에 강제 종료되고, **다음 Step 이 계속 진행**되는지,
#        슈퍼바이저가 상한 안에 종료되는지, RunEnd 가 TIMED_OUT 으로 기록되는지
#        확인한다.
#   2) 종료코드 전파
#      - Step 3 모듈이 exit 7 하면 슈퍼바이저가 "Step 실패"로 기록만 하고
#        다음 Step 으로 진행하는지, RunEnd 가 FAILED 로 기록되는지 확인한다.
#   3) 래퍼가 종료코드를 먹어도
#      - conhost 래퍼가 항상 0 으로 끝나도(자식 종료코드를 되돌려주지 않는
#        경우) 워커가 직접 기록한 결과 파일로 실패를 판정하는지 확인한다.
#   4) 정상 경로
#      - 모든 Step 이 성공하면 SUCCEEDED / exit 0 으로 기록되는지 확인한다.
#
# OS 대응:
#   - Windows: 실제 conhost.exe / taskkill.exe 를 그대로 쓴다(프로덕션과 동일).
#   - 그 밖의 OS: 테스트용 shim(conhost.exe / taskkill.exe)을 만들어 PATH 에
#     붙인다. Windows 의 동작을 흉내 내되, 인자 형태는 그대로 유지한다.
#
# 실행: powershell -NoProfile -File tests/Test-SupervisorWorker.ps1
#       (pwsh -NoProfile -File ... 로도 실행 가능)

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

function Assert-Match {
    param([string]$Desc, [string]$Pattern, [string]$Text)
    if ($Text -and ($Text -match $Pattern)) {
        Write-Host "  [PASS] $Desc"
        $script:PassCount++
    } else {
        Write-Host "  [FAIL] $Desc (pattern='$Pattern')"
        $script:FailCount++
    }
}

# ---------------------------------------------------------------------------
# 테스트 대상 Step 모듈 목록 (giipAgent3.ps1 의 Step 목록과 동일)
# ---------------------------------------------------------------------------
$AllSteps = @(
    "CleanState", "CqeGet", "CqeRun", "DbMonitor", "ProcessList",
    "DbConnectionList", "HostConnectionList", "CollectEnhancedMetrics",
    "CollectDockerMetrics"
)

$IsWindowsHost = ($env:OS -eq "Windows_NT")

# ---------------------------------------------------------------------------
# 샌드박스 준비
# ---------------------------------------------------------------------------
$Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("giipAgentWin-SupervisorTest-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$SandboxRepo = Join-Path $Sandbox "repo"
$StepLog = Join-Path $Sandbox "steps.log"
$RunLog = Join-Path $Sandbox "run.log"
$ShimDir = Join-Path $Sandbox "bin"

$env:GIIP_TEST_STEPLOG = $StepLog
$env:GIIP_TEST_RUNLOG = $RunLog
# Get-GiipConfig 가 %USERPROFILE% 을 본다. 테스트에서는 빈 디렉터리를 가리켜
# "설정 못 찾기"로 모든 Step 이 조용히 스킵되는 일이 없게 한다.
$env:USERPROFILE = Join-Path $Sandbox "profile"
New-Item -ItemType Directory -Force -Path $env:USERPROFILE | Out-Null

function New-SandboxRepo {
    New-Item -ItemType Directory -Force -Path (Join-Path $SandboxRepo "lib") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $SandboxRepo "giipscripts/modules") | Out-Null
    Copy-Item (Join-Path $RepoRoot "giipAgent3.ps1") $SandboxRepo -Force
    Copy-Item (Join-Path $RepoRoot "giipAgentWorker.ps1") $SandboxRepo -Force
    Copy-Item (Join-Path $RepoRoot "lib/*.ps1") (Join-Path $SandboxRepo "lib") -Force
    Copy-Item (Join-Path $RepoRoot "giipscripts/modules/*.ps1") (Join-Path $SandboxRepo "giipscripts/modules") -Force
}

# Step 모듈 스텁: 스텁이 실행되었음을 표시하고 지정한 동작을 한다.
function New-StepStub {
    param([string]$StepName, [string]$Body)
    $path = Join-Path $SandboxRepo "giipscripts/modules/$StepName.ps1"
    $content = @"
`$ErrorActionPreference = "Continue"
Add-Content -Path `$env:GIIP_TEST_STEPLOG -Value "$StepName"
$Body
"@
    Set-Content -Path $path -Value $content -Encoding UTF8
}

# RunStart/RunEnd 스텁: 실제 API 를 호출하지 않고 기록만 남긴다.
# Status 에 ValidateSet 을 그대로 둔다 - 슈퍼바이저가 SP 가 받지 못하는 상태값을
# 넘기면(=지원하지 않는 값을 쓰면) 이 스텁이 throw 해서 테스트가 깨진다.
function New-RunStub {
    $path = Join-Path $SandboxRepo "lib/SchedulerAgentRun.ps1"
    $content = @'
function Invoke-SchedulerAgentRunStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AgentKey,
        [Parameter(Mandatory)][string]$RunIdKey,
        [string]$ExecutionMode = "scheduled",
        [string]$StateDir
    )
    $record = [ordered]@{ event = "RunStart"; runIdKey = $RunIdKey; agentKey = $AgentKey; at = (Get-Date -Format "o") }
    Add-Content -Path $env:GIIP_TEST_RUNLOG -Value ($record | ConvertTo-Json -Compress)
    return $true
}

function Invoke-SchedulerAgentRunEnd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AgentKey,
        [Parameter(Mandatory)][string]$RunIdKey,
        [Parameter(Mandatory)][ValidateSet('SUCCEEDED', 'FAILED', 'TIMED_OUT', 'ZOMBIE_TERMINATED', 'SKIPPED')][string]$Status,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$Summary
    )
    $record = [ordered]@{
        event = "RunEnd"; status = $Status; exitCode = $ExitCode; summary = $Summary; at = (Get-Date -Format "o")
    }
    Add-Content -Path $env:GIIP_TEST_RUNLOG -Value ($record | ConvertTo-Json -Compress)
    return $true
}
'@
    Set-Content -Path $path -Value $content -Encoding UTF8
}

# giipAgent.cfg (테스트용) - steptimeout_* 로 Step 별 타임아웃을 지정한다.
function New-TestConfig {
    param([int]$DbMonitorTimeout = 5)
    $lines = @(
        "# supervisor/worker split test config (giip #6163)",
        "sk = `"test-sk`"",
        "lssn = `"99999`"",
        "cqetimeoutsec = `"30`"",
        "steptimeout_cleanstate = `"20`"",
        "steptimeout_cqeget = `"20`"",
        "steptimeout_cqerun = `"20`"",
        "steptimeout_dbmonitor = `"$DbMonitorTimeout`"",
        "steptimeout_processlist = `"20`"",
        "steptimeout_dbconnectionlist = `"20`"",
        "steptimeout_hostconnectionlist = `"20`"",
        "steptimeout_collectenhancedmetrics = `"20`"",
        "steptimeout_collectdockermetrics = `"20`""
    )
    Set-Content -Path (Join-Path $SandboxRepo "giipAgent.cfg") -Value $lines -Encoding UTF8
}

# Task Scheduler 마이그레이션 확인은 테스트 대상이 아니고, 실제 PC 에서
# Task Scheduler 를 다시 등록할 수 있으므로 사본에서 무력화한다.
function Disable-TaskMigrationCheck {
    $path = Join-Path $SandboxRepo "giipAgent3.ps1"
    $raw = Get-Content -Path $path -Raw
    $patched = $raw -replace [regex]::Escape('$regTask = Get-ScheduledTask -TaskName "GIIP Agent Task (v3)" -ErrorAction Stop'), 'throw "test: task scheduler migration check disabled"'
    Set-Content -Path $path -Value $patched -Encoding UTF8 -NoNewline
    return ($raw -ne $patched)
}

# Windows 가 아닌 OS 용 shim.
function New-Shims {
    New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null

    $conhost = @'
#!/bin/bash
# 테스트용 conhost.exe shim - "conhost.exe --headless powershell.exe ..." 와
# 같은 모양으로 인자를 그대로 실행하고 자식의 종료코드를 되돌려준다.
# GIIP_TEST_SHIM_EXIT 이 있으면 그 값으로 종료한다(래퍼가 종료코드를 먹는
# 상황을 재현하기 위한 스위치).
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) shift ;;
    powershell.exe) shift; args+=(-NoProfile -NonInteractive);;
    -ExecutionPolicy) shift; shift ;;
    -NoProfile|-NonInteractive) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
pwsh "${args[@]}"
rc=$?
if [ -n "$GIIP_TEST_SHIM_EXIT" ]; then exit "$GIIP_TEST_SHIM_EXIT"; fi
exit $rc
'@
    $conhostPath = Join-Path $ShimDir "conhost.exe"
    Set-Content -Path $conhostPath -Value $conhost -Encoding UTF8 -NoNewline
    & chmod +x $conhostPath

    $taskkill = @'
#!/bin/bash
# 테스트용 taskkill.exe shim - "taskkill /PID <pid> /T /F" 지원.
pid=""
while [ $# -gt 0 ]; do
  case "$1" in
    /PID) pid="$2"; shift 2 ;;
    /T|/F) shift ;;
    *) shift ;;
  esac
done
[ -z "$pid" ] && exit 1
if command -v pgrep >/dev/null 2>&1; then
  for c in $(pgrep -P "$pid" 2>/dev/null); do kill -KILL "$c" 2>/dev/null; done
fi
kill -KILL "$pid" 2>/dev/null
exit 0
'@
    $taskkillPath = Join-Path $ShimDir "taskkill.exe"
    Set-Content -Path $taskkillPath -Value $taskkill -Encoding UTF8 -NoNewline
    & chmod +x $taskkillPath

    $env:PATH = $ShimDir + [System.IO.Path]::PathSeparator + $env:PATH
}

# 슈퍼바이저를 실제로 실행하고 결과를 모은다.
function Invoke-Supervisor {
    param([int]$TimeoutSec = 300)

    if (Test-Path $StepLog) { Remove-Item $StepLog -Force }
    if (Test-Path $RunLog) { Remove-Item $RunLog -Force }

    $outFile = Join-Path $Sandbox "supervisor.out"
    $errFile = Join-Path $Sandbox "supervisor.err"
    $psExe = if ($IsWindowsHost) { "powershell.exe" } else { "pwsh" }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $psExe `
        -ArgumentList @("-NoProfile", "-NonInteractive", "-File", "`"$(Join-Path $SandboxRepo 'giipAgent3.ps1')`"") `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError $errFile `
        -WorkingDirectory $SandboxRepo `
        -PassThru
    $null = $proc.Handle
    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    $sw.Stop()

    $stdout = ""
    if (Test-Path $outFile) { $stdout = Get-Content -Path $outFile -Raw -ErrorAction SilentlyContinue }
    $stderr = ""
    if (Test-Path $errFile) { $stderr = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue }

    $steps = @()
    if (Test-Path $StepLog) { $steps = @(Get-Content -Path $StepLog -ErrorAction SilentlyContinue) }

    $runEnd = $null
    if (Test-Path $RunLog) {
        foreach ($line in @(Get-Content -Path $RunLog -ErrorAction SilentlyContinue)) {
            try {
                $rec = $line | ConvertFrom-Json -ErrorAction Stop
                if ($rec.event -eq "RunEnd") { $runEnd = $rec }
            } catch {}
        }
    }

    $exitCode = $null
    try { $exitCode = [int]$proc.ExitCode } catch { $exitCode = $null }

    return [pscustomobject]@{
        Finished  = $finished
        ExitCode  = $exitCode
        ElapsedSec = [int][math]::Round($sw.Elapsed.TotalSeconds, 1)
        Stdout    = "$stdout`n$stderr"
        Steps     = $steps
        RunEnd    = $runEnd
    }
}

try {
    Write-Host "=== giip #6163 supervisor/worker split test ==="
    Write-Host "Repo : $RepoRoot"
    Write-Host "Sandbox: $Sandbox"

    New-SandboxRepo
    New-RunStub
    $migrationPatched = Disable-TaskMigrationCheck
    Assert-True "migration check disabled in sandbox copy" $migrationPatched

    if (-not $IsWindowsHost) {
        New-Shims
        Write-Host "(non-Windows host: using conhost/taskkill shims)"
    }

    # --- 시나리오 1: 타임아웃 -------------------------------------------------
    Write-Host ""
    Write-Host "--- Scenario 1: worker timeout (Step 3 hangs) ---"
    foreach ($s in $AllSteps) { New-StepStub -StepName $s -Body "" }
    New-StepStub -StepName "DbMonitor" -Body "Start-Sleep 9999"
    New-TestConfig -DbMonitorTimeout 5

    $r1 = Invoke-Supervisor -TimeoutSec 300
    Assert-True "1) supervisor exited within the upper bound" $r1.Finished
    Assert-Match "1) timeout logged with 'killed, continuing'" "Worker timeout .*killed, continuing" $r1.Stdout
    Assert-Match "1) Step 4 still ran after the timeout" "\[Step 4\]" $r1.Stdout
    Assert-True "1) ProcessList step executed after the timeout" ($r1.Steps -contains "ProcessList")
    Assert-Eq "1) RunEnd status" "TIMED_OUT" ($(if ($r1.RunEnd) { $r1.RunEnd.status } else { "<none>" }))
    Assert-Match "1) RunEnd summary names the timed-out step" "DbMonitor" ($(if ($r1.RunEnd) { $r1.RunEnd.summary } else { "" }))
    Assert-Eq "1) supervisor exit code" 1 $r1.ExitCode
    Assert-True "1) supervisor finished quickly (timeout=5s, elapsed=$($r1.ElapsedSec)s)" ($r1.ElapsedSec -lt 150)

    # --- 시나리오 2: 종료코드 전파 -------------------------------------------
    Write-Host ""
    Write-Host "--- Scenario 2: worker exit code propagation (Step 3 exits 7) ---"
    foreach ($s in $AllSteps) { New-StepStub -StepName $s -Body "" }
    New-StepStub -StepName "DbMonitor" -Body "exit 7"
    New-TestConfig -DbMonitorTimeout 60

    $r2 = Invoke-Supervisor -TimeoutSec 300
    Assert-True "2) supervisor exited within the upper bound" $r2.Finished
    Assert-Match "2) non-zero exit code recorded as a Step failure" "\[Step 3\] Worker failed \(exit code 7" $r2.Stdout
    Assert-True "2) ProcessList step executed after the failure" ($r2.Steps -contains "ProcessList")
    Assert-Eq "2) RunEnd status" "FAILED" ($(if ($r2.RunEnd) { $r2.RunEnd.status } else { "<none>" }))
    Assert-Match "2) RunEnd summary names the failed step" "Step3:DbMonitor:exit7" ($(if ($r2.RunEnd) { $r2.RunEnd.summary } else { "" }))
    Assert-Eq "2) supervisor exit code" 1 $r2.ExitCode

    # --- 시나리오 3: 래퍼가 종료코드를 먹는 경우 ------------------------------
    if (-not $IsWindowsHost) {
        Write-Host ""
        Write-Host "--- Scenario 3: launcher swallows the exit code ---"
        foreach ($s in $AllSteps) { New-StepStub -StepName $s -Body "" }
        New-StepStub -StepName "DbMonitor" -Body "exit 7"
        New-TestConfig -DbMonitorTimeout 60
        $env:GIIP_TEST_SHIM_EXIT = "0"

        $r3 = Invoke-Supervisor -TimeoutSec 300
        Remove-Item Env:\GIIP_TEST_SHIM_EXIT -ErrorAction SilentlyContinue

        Assert-Match "3) exit code mismatch detected" "Worker exit code mismatch" $r3.Stdout
        Assert-Match "3) failure still detected via the worker result file" "\[Step 3\] Worker failed \(exit code 7" $r3.Stdout
        Assert-Eq "3) RunEnd status" "FAILED" ($(if ($r3.RunEnd) { $r3.RunEnd.status } else { "<none>" }))
    } else {
        Write-Host ""
        Write-Host "--- Scenario 3: skipped (Windows host: real conhost.exe is used) ---"
    }

    # --- 시나리오 4: 정상 경로 ------------------------------------------------
    Write-Host ""
    Write-Host "--- Scenario 4: all steps succeed ---"
    foreach ($s in $AllSteps) { New-StepStub -StepName $s -Body "" }
    New-TestConfig -DbMonitorTimeout 60

    $r4 = Invoke-Supervisor -TimeoutSec 300
    Assert-True "4) supervisor exited within the upper bound" $r4.Finished
    Assert-Eq "4) all 9 steps executed" 9 $r4.Steps.Count
    Assert-Eq "4) RunEnd status" "SUCCEEDED" ($(if ($r4.RunEnd) { $r4.RunEnd.status } else { "<none>" }))
    Assert-Eq "4) RunEnd summary empty" "" ($(if ($r4.RunEnd) { $r4.RunEnd.summary } else { "<none>" }))
    Assert-Eq "4) supervisor exit code" 0 $r4.ExitCode

} finally {
    Remove-Item Env:\GIIP_TEST_STEPLOG -ErrorAction SilentlyContinue
    Remove-Item Env:\GIIP_TEST_RUNLOG -ErrorAction SilentlyContinue
    Remove-Item Env:\GIIP_TEST_SHIM_EXIT -ErrorAction SilentlyContinue
    if (Test-Path $Sandbox) {
        Remove-Item -Path $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "=== Results: $($script:PassCount) passed, $($script:FailCount) failed ==="
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
