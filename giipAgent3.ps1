# ============================================================================
# giipAgent3.ps1 (Windows Orchestrator - Robust UTF8 Version)
# Purpose: Main entry point for giipAgentWin.
#
# giip #6163: 이 스크립트는 이제 **슈퍼바이저**다. Step 1~8 을 직접 실행하지
# 않고, 각 Step 을 별도 프로세스(워커 = giipAgentWorker.ps1)로 띄워 실행한다.
# 한 Step 이 멈춰도 그 Step(과 자식 프로세스 트리)만 강제 종료되고 다음 Step 은
# 계속된다 - giip #5924(Step 7 한 행이 3일간 전체 사이클을 정지) 의 근본 해결.
# Step 별 타임아웃과 워커 기동(Invoke-GiipStepWorker) 은 아래를 참고.
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Global:BaseDir = $ScriptDir
# 경로 구분자는 Join-Path 로 잇는다(Windows 의 "giipscripts\modules" 를 그대로
# 쓰면 다른 OS 에서 경로가 깨진다 - Windows 동작은 완전히 동일).
$ModuleDir = Join-Path (Join-Path $ScriptDir "giipscripts") "modules"
$LibDir = Join-Path $ScriptDir "lib"

# giip #2338: stale-instance lock. See lib/ProcessLock.ps1 and
# docs/task-scheduler-multiple-instances.md -- this only takes effect once
# the Task Scheduler job's MultipleInstances policy is switched away from
# the default IgnoreNew (otherwise a hung previous run stops Task Scheduler
# from ever starting a new process, so this code doesn't even get a chance
# to run).
$LockPath = Join-Path $ScriptDir "giipAgent3.lock"
$StaleLockThresholdMinutes = 30

# Load Libraries (MANDATORY ORDER)
try {
    # 1. Base Common Functions
    . (Join-Path $LibDir "Common.ps1")

    # 2. Key-Value Store Library (REQUIRED for ProcessList)
    #    저장소 파일명의 실제 대소문자는 "Kvs.ps1" 이고 Windows 의 대소문자
    #    구분 없는 파일시스템에서는 "KVS.ps1" 로도 잡힌다. 둘 다 시도해 어떤
    #    파일시스템에서도 똑같이 로드되게 한다(워커와 동일하게 맞춘다 -
    #    워커는 giipAgent3.ps1 의 초기화를 그대로 재현해야 한다).
    $kvsPath = $null
    foreach ($kvsCandidate in @((Join-Path $LibDir "KVS.ps1"), (Join-Path $LibDir "Kvs.ps1"))) {
        if (Test-Path $kvsCandidate) { $kvsPath = $kvsCandidate; break }
    }
    if (-not $kvsPath) {
        throw "KVS library not found at: $(Join-Path $LibDir 'KVS.ps1')"
    }
    . $kvsPath

    # 3. Process Lock Library (giip #2338)
    if (Test-Path (Join-Path $LibDir "ProcessLock.ps1")) {
        . (Join-Path $LibDir "ProcessLock.ps1")
    } else {
        throw "ProcessLock library not found at: $(Join-Path $LibDir 'ProcessLock.ps1')"
    }

    # 4. Scheduler Agent 등록/백오프 Library (giip #2470)
    #    SchedulerAgentRun.ps1 이 404 자가등록에 쓰므로 반드시 먼저 로드한다.
    if (Test-Path (Join-Path $LibDir "SchedulerAgentRegister.ps1")) {
        . (Join-Path $LibDir "SchedulerAgentRegister.ps1")
    } else {
        throw "SchedulerAgentRegister library not found at: $(Join-Path $LibDir 'SchedulerAgentRegister.ps1')"
    }

    # 5. Scheduler Agent Run history Library (giip #2390)
    if (Test-Path (Join-Path $LibDir "SchedulerAgentRun.ps1")) {
        . (Join-Path $LibDir "SchedulerAgentRun.ps1")
    } else {
        throw "SchedulerAgentRun library not found at: $(Join-Path $LibDir 'SchedulerAgentRun.ps1')"
    }
} catch {
    Write-Host "FATAL: Failed to load core libraries. ($_)"
    exit 1
}

# Ensure Logging is available
if (-not (Get-Command "Write-GiipLog" -ErrorAction SilentlyContinue)) {
    function Write-GiipLog { param($Level, $Message) Write-Host "[$Level] $Message" }
}

# ============================================================================
# Invoke-GiipStepWorker (giip #6163)
#
# Step 1개를 **별도 프로세스**(워커 = giipAgentWorker.ps1)로 실행하고, 그
# 종료코드/타임아웃/소요시간을 돌려준다.
#
# 왜 프로세스 분리인가 (giip #5924):
#   예전에는 Step 1~8 이 한 프로세스 안에서 순차 실행돼서, Step 하나가 멈추면
#   전체 사이클이 멈췄다(3일간 - giip #5924). 이제는 Step 하나가 멈춰도 그
#   Step(과 그 자식 프로세스 트리)만 강제 종료하고 다음 Step 으로 진행한다.
#   워커는 모듈 스크립트를 그대로 실행하므로 수집 로직 자체는 바뀌지 않는다.
#
# 기동 방식:
#   conhost.exe --headless powershell.exe ... - TaskSchdReg.ps1 이 등록한
#   진입점과 **똑같은** 패턴이다(AGENTS.md 2번 "창 숨김 방식은 고정" 규칙).
#   vbs/LOLBin/-EncodedCommand/-WindowStyle Hidden 같은 다른 방식은 쓰지 않는다.
#
# 반환: @{ Step, Name, ExitCode, TimedOut, DurationSec, Skipped }
#   ExitCode 가 0 이 아니면 "Step 실패"로 기록만 하고 다음 Step 으로 진행한다.
# ============================================================================
function Invoke-GiipStepWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StepLabel,   # 로그에 찍히는 Step 번호 (예: "2.5")
        [Parameter(Mandatory)][string]$StepName,    # 모듈 이름 (예: "CqeRun")
        [Parameter(Mandatory)][string]$ModuleScript,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $result = [ordered]@{
        Step        = $StepLabel
        Name        = $StepName
        ExitCode    = 0
        TimedOut    = $false
        DurationSec = 0
        Skipped     = $false
    }

    # 모듈이 없으면 예전처럼 건너뛴다(배포 이상으로 전체 사이클을 죽이지 않는다).
    if (-not (Test-Path $ModuleScript)) {
        Write-GiipLog "WARN" "[Step $StepLabel] Module not found: $ModuleScript - skipped"
        $result.Skipped = $true
        return [pscustomobject]$result
    }

    $workerScript = Join-Path $ScriptDir "giipAgentWorker.ps1"
    if (-not (Test-Path $workerScript)) {
        Write-GiipLog "ERROR" "[Step $StepLabel] Worker script not found: $workerScript - step failed"
        $result.ExitCode = 127
        return [pscustomobject]$result
    }

    # 워커의 표준출력/에러는 임시 파일로 받고 워커가 끝난 뒤 컨솔로 되돌린다.
    # (모듈 로그는 Write-GiipLog 가 공용 로그 파일에 직접 남기므로, 여기서는
    #  컨솔 출력만 재현한다 - 같은 줄을 로그 파일에 두 번 쓰지 않는다.)
    $token = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $safeLabel = $StepLabel -replace '[^0-9A-Za-z_]', ''
    $tempDir = [System.IO.Path]::GetTempPath()
    $outFile = Join-Path $tempDir "giip_step_${safeLabel}_${token}.out"
    $errFile = Join-Path $tempDir "giip_step_${safeLabel}_${token}.err"
    $resultFile = Join-Path $tempDir "giip_step_${safeLabel}_${token}.json"

    # 워커 기동 명령 (AGENTS.md 2번 "진입점과 창 숨김 방식은 고정").
    # conhost.exe --headless powershell.exe ... 는 TaskSchdReg.ps1 이 등록한
    # 진입점과 **똑같은** 패턴이다. vbs/LOLBin/-EncodedCommand/-WindowStyle
    # Hidden 같은 다른 방식은 쓰지 않는다.
    $workerExe = "conhost.exe"
    $workerExeArgs = @("--headless", "powershell.exe")
    $workerPsArgs = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass")

    $arguments = @($workerExeArgs) + @($workerPsArgs) + @(
        "-File"
        "`"$workerScript`""
        "-StepName"
        "`"$StepName`""
        "-ModuleScript"
        "`"$ModuleScript`""
        "-ResultFile"
        "`"$resultFile`""
    )

    if ($TimeoutSec -lt 1) { $TimeoutSec = 1 }

    $proc = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = Start-Process -FilePath $workerExe `
            -ArgumentList $arguments `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -WorkingDirectory $ScriptDir `
            -PassThru
        # 종료 후 ExitCode 를 읽을 수 있도록 핸들을 미리 캐시한다
        # (Start-Process -PassThru 는 이 캐시가 없으면 ExitCode 가 비어 있다).
        $null = $proc.Handle
    } catch {
        $stopwatch.Stop()
        Write-GiipLog "ERROR" "[Step $StepLabel] Worker start failed: $_"
        $result.ExitCode = 126
        Remove-Item -Path $outFile, $errFile, $resultFile -Force -ErrorAction SilentlyContinue
        return [pscustomobject]$result
    }

    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    $stopwatch.Stop()
    $result.DurationSec = [int][math]::Round($stopwatch.Elapsed.TotalSeconds)

    # 워커가 직접 남긴 결과 파일(PID/종료코드)을 읽는다.
    # conhost.exe 래퍼가 자식(powershell.exe)의 종료코드를 그대로 되돌려주지
    # 않는 경우에도, 워커가 기록한 종료코드로 Step 실패를 판정할 수 있다.
    $workerInfo = $null
    if (Test-Path $resultFile) {
        try {
            $workerInfo = Get-Content -Path $resultFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $workerInfo = $null
        }
    }

    if (-not $finished) {
        # 타임아웃 - 프로세스 트리 전체를 강제 종료한다(자식 프로세스까지).
        # 주의: taskkill 의 stderr 를 2>&1 로 합치면 $ErrorActionPreference="Stop"
        # 에서 NativeCommandError 가 터져 종료 자체가 막힌다 - stderr 는 버리고
        # 종료코드만 확인한다.
        $eap = $ErrorActionPreference
        $workerPid = $null
        if ($workerInfo -and $workerInfo.pid) {
            try { $workerPid = [int]$workerInfo.pid } catch { $workerPid = $null }
        }
        try {
            $ErrorActionPreference = 'Continue'
            # 1) conhost(래퍼) 트리 - 워커와 그 자식이 여기 포함된다.
            & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
            # 2) 워커(powershell.exe)를 직접 - 래퍼가 먼저 죽어 워커가 고아
            #    (orphan)로 남는 경우까지 확실히 정리한다.
            if ($workerPid -and $workerPid -ne $proc.Id) {
                & taskkill.exe /PID $workerPid /T /F 2>$null | Out-Null
            }
        } catch {
            Write-GiipLog "WARN" "[Step $StepLabel] taskkill failed: $_"
        } finally {
            $ErrorActionPreference = $eap
        }
        try {
            if (-not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        try { $null = $proc.WaitForExit(10000) } catch {}
        $stillAlive = $false
        try { $stillAlive = -not $proc.HasExited } catch {}

        if ($workerPid -and (Get-Process -Id $workerPid -ErrorAction SilentlyContinue)) {
            Write-GiipLog "ERROR" "[Step $StepLabel] Worker timeout after ${TimeoutSec}s - worker still alive (pid=$workerPid), continuing"
        } elseif ($stillAlive) {
            Write-GiipLog "ERROR" "[Step $StepLabel] Worker timeout after ${TimeoutSec}s - kill failed (pid=$($proc.Id)), continuing"
        } else {
            Write-GiipLog "ERROR" "[Step $StepLabel] Worker timeout after ${TimeoutSec}s - killed, continuing (pid=$($proc.Id))"
        }
        $result.TimedOut = $true
        $result.ExitCode = -1
    } else {
        # 정상 종료 - 캡처한 stdout/err 가 모두 flush 되도록 잠깐 더 기다린다.
        try { $null = $proc.WaitForExit() } catch {}

        $procExitCode = $null
        try { $procExitCode = [int]$proc.ExitCode } catch { $procExitCode = $null }
        $exitCode = $procExitCode

        # 워커가 직접 기록한 종료코드가 있으면 그 값을 우선한다(래퍼가 자식의
        # 종료코드를 먹어도 Step 실패를 정확히 판정하기 위함).
        if ($workerInfo -and $null -ne $workerInfo.exitCode) {
            $workerExitCode = $null
            try { $workerExitCode = [int]$workerInfo.exitCode } catch { $workerExitCode = $null }
            if ($null -ne $workerExitCode) {
                if ($null -ne $procExitCode -and $procExitCode -ne $workerExitCode) {
                    Write-GiipLog "WARN" "[Step $StepLabel] Worker exit code mismatch (launcher=$procExitCode, worker=$workerExitCode) - using worker exit code."
                }
                $exitCode = $workerExitCode
            }
        }
        if ($null -eq $exitCode) { $exitCode = -1 }
        $result.ExitCode = $exitCode

        if ($result.ExitCode -ne 0) {
            Write-GiipLog "ERROR" "[Step $StepLabel] Worker failed (exit code $($result.ExitCode), duration=$($result.DurationSec)s) - continuing"
        } else {
            # giip #5924 재발 방지 목적의 가시성: 어떤 Step 이 얼마나 걸렸는지
            # 로그 한 줄로 남는다(행 단위 멈춤을 즉시 특정할 수 있게).
            Write-GiipLog "INFO" "[Step $StepLabel] Completed (exit=0, duration=$($result.DurationSec)s)"
        }
    }

    # 워커 콘솔 출력을 원래대로 컨솔에 되돌린다.
    # 워커는 [Console]::OutputEncoding 을 UTF-8 로 잡고 죽이므로(한글 깨짐 방지)
    # 여기서도 UTF-8 로 명시적으로 읽는다 - Windows PowerShell 5.1 의 Get-Content
    # 기본값은 ANSI 이므로 명시하지 않으면 한글이 깨진 채로 출력된다.
    foreach ($captured in @($outFile, $errFile)) {
        if (Test-Path $captured) {
            try {
                Get-Content -Path $captured -Encoding UTF8 -ErrorAction Stop | ForEach-Object { Write-Host $_ }
            } catch {}
            Remove-Item -Path $captured -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -Path $resultFile -Force -ErrorAction SilentlyContinue

    return [pscustomobject]$result
}

# giip #2338: refuse to run twice in parallel, and self-heal from a hung
# previous instance once it has been alive longer than the stale threshold.
$lockResult = Enter-GiipAgentLock -LockPath $LockPath -StaleThresholdMinutes $StaleLockThresholdMinutes
switch ($lockResult.Status) {
    "AlreadyRunning"      { Write-GiipLog "INFO"  $lockResult.Detail }
    "KillFailed"          { Write-GiipLog "ERROR" $lockResult.Detail }
    "AcquiredKilledStale" { Write-GiipLog "WARN"  $lockResult.Detail }
    "AcquiredDeadProcess" { Write-GiipLog "WARN"  $lockResult.Detail }
    default               { Write-GiipLog "INFO"  $lockResult.Detail }
}
if (-not $lockResult.ShouldProceed) {
    if ($lockResult.Status -eq "KillFailed") { exit 1 }
    # Normal duplicate-run guard: another instance is legitimately still
    # within its allowed run time. Exit quietly, Task Scheduler will retry
    # again on its next 5-minute trigger.
    exit 0
}

Write-GiipLog "INFO" "=== giipAgent3.ps1 Started ==="

# 구 등록(wscript.exe + giipAgent3-silent.vbs)을 쓰는 머신 자동 전환. vbs 는 git pull 로 지워지는데
# 옛 등록은 vbs 를 거쳐야 launcher 에 도달하므로, 전환 코드는 launcher 가 아니라 pull 이후에 실행되는
# 여기(giipAgent3.ps1)에 있어야 한다. 이미 pull 로 vbs 가 없어져 멈춘 머신은 TaskSchdReg.ps1 을 수동 실행한다.
try {
    $regTask = Get-ScheduledTask -TaskName "GIIP Agent Task (v3)" -ErrorAction Stop
    if ($regTask.Actions[0].Execute -like "*wscript*") {
        Write-GiipLog "WARN" "Task Scheduler still uses wscript/vbs. Re-registering with conhost --headless..."
        & (Join-Path $ScriptDir "TaskSchdReg.ps1") | Out-Null
        Write-GiipLog "INFO" "Task Scheduler re-registered (conhost --headless)."
    }
} catch {
    Write-GiipLog "WARN" "Task Scheduler migration check failed: $($_.Exception.Message)"
}

# giip #2390: 스케줄러 실행 이력(tSchedulerAgentRun) 부트스트랩 - 락 획득에
# 성공해 실제로 Step 1~7을 돌릴 시점(위 lockResult.ShouldProceed 체크를 이미
# 통과한 이후)에만 수행한다. AlreadyRunning/KillFailed로 위에서 이미 exit한
# 경로는 실제 실행이 아니므로 여기 도달하지 않는다 - run 기록을 만들면 안 되는
# 케이스와 정확히 분리됨.
#
# 이 블록 전체(Config 로드/agentKey 해석 포함)가 실패해도 본 실행(Step 1~7)에
# 영향을 주면 안 되므로 감싼다. Invoke-SchedulerAgentRun* 두 함수는 내부에서
# 이미 failure-tolerant 하지만, 그 앞단(Get-GiipConfig/Resolve-AgentKey)까지
# 포함해 한 번 더 감싸 완전히 안전하게 만든다.
#
# giip #2470: 예전에는 여기서 RunStart 만 부르고 tSchedulerAgent 등록(부트스트랩)은
# 하지 않았다. 그 부트스트랩은 lib/LogCollector.ps1 안에만 있었고 이 스크립트는
# LogCollector.ps1 을 dot-source 하지도 않아서, LogCollector 를 돌리지 않는
# 호스트에서는 에이전트 행이 영원히 안 생기고 5분마다 RunStart/RunEnd 가 각각
# 404 로 실패했다. 이제 RunStart 가 404 를 만나면 스스로 등록 후 재시도하고,
# 그래도 실패하면 백오프에 들어간다(-StateDir). 또 RunStart 가 실패/스킵됐으면
# 아래 finally 의 RunEnd 도 건너뛴다 - 짝이 안 맞는 호출로 404 를 두 배로
# 쌓지 않기 위함이다.
$Config = $null
$agentKey = $null
$runIdKey = $null
$runStartOk = $false
$runStatus = "FAILED"
$runExitCode = 1
# giip #6163: Step 실패/타임아웃 목록 - RunEnd 의 summary 로 넘긴다.
$runSummary = ""
try {
    $Config = Get-GiipConfig
    # Resolve-AgentKey가 쓰는 결정론적 agentKey는 Invoke-SchedulerAgentBootstrap
    # (lib/LogCollector.ps1)이 tSchedulerAgent 부트스트랩에 쓰는 것과 동일한
    # 값이어야 같은 Box = 같은 agent 행으로 묶인다 - CacheFile 경로도
    # LogCollector.ps1과 동일하게 계산한다(레포 상위 폴더의
    # .giip_logcollector_agentkey, git-auto-sync.ps1의 체크아웃 갱신에 영향받지
    # 않음).
    $InstallDir = Split-Path -Path $ScriptDir -Parent
    $AgentKeyCacheFile = Join-Path $InstallDir ".giip_logcollector_agentkey"
    $agentKey = Resolve-AgentKey -Config $Config -CacheFile $AgentKeyCacheFile
    $runIdKey = Get-Date -Format 'yyyyMMddHHmmssfff'
    # StateDir 은 AgentKeyCacheFile 과 같은 InstallDir 을 쓴다(git-auto-sync.ps1 의
    # 체크아웃 갱신에 영향받지 않는 위치).
    $runStartOk = Invoke-SchedulerAgentRunStart -Config $Config -AgentKey $agentKey -RunIdKey $runIdKey -StateDir $InstallDir
} catch {
    Write-GiipLog "WARN" "giip #2390: SchedulerAgentRun bootstrap/start failed (non-fatal): $($_.Exception.Message)"
}

try {
    # ------------------------------------------------------------------
    # Step 실행 (giip #6163) - 각 Step 은 **별도 프로세스(워커)** 로 실행한다.
    # ------------------------------------------------------------------
    # Step 간 데이터 전달은 전부 파일 기반(data\queue.json 등)이라 프로세스가
    # 나뉘어도 흐름이 그대로 유지된다 - Step 2 가 만든 큐를 Step 2.5 가 소비하고,
    # Step 2.5 는 실행 전에 큐를 data\queue_last.json 으로 옮겨 소비한다.
    #
    # Step 별 기본 타임아웃(초). giipAgent.cfg 의 'steptimeout_<stepname>' 으로
    # Step 마다 재정의할 수 있다(예: steptimeout_dbmonitor = "600").
    # CqeRun 의 기본값만 다르고(cfg 'cqetimeoutsec' 기본 600 + 120), 나머지는
    # 아래 표의 값이 그대로 쓰인다.
    $cqeTimeoutSec = 600
    if ($Config -and $Config['cqetimeoutsec']) {
        $parsedCqe = 0
        if ([int]::TryParse("$($Config['cqetimeoutsec'])".Trim(), [ref]$parsedCqe) -and $parsedCqe -gt 0) {
            $cqeTimeoutSec = $parsedCqe
        } else {
            Write-GiipLog "WARN" "Invalid cqetimeoutsec='$($Config['cqetimeoutsec'])' - using ${cqeTimeoutSec}s for the CqeRun worker timeout."
        }
    }

    $steps = @(
        @{ Label = "1";   Name = "CleanState";             Module = "CleanState.ps1";             Timeout = 60;  Message = "Cleaning state..." },
        @{ Label = "2";   Name = "CqeGet";                 Module = "CqeGet.ps1";                 Timeout = 90;  Message = "Fetching Queue..." },
        # giip #2546: Step 2 가 data\queue.json 에 저장한 큐를 **같은 실행 안에서**
        # 소비해야 유실 창이 생기지 않는다. 워커 프로세스로 분리해도 큐는 파일로
        # 이어지므로 순서/내용은 그대로다.
        @{ Label = "2.5"; Name = "CqeRun";                 Module = "CqeRun.ps1";                 Timeout = ($cqeTimeoutSec + 120); Message = "Running Queue Task..." },
        @{ Label = "3";   Name = "DbMonitor";              Module = "DbMonitor.ps1";              Timeout = 420; Message = "Running DB Monitor..." },
        @{ Label = "4";   Name = "ProcessList";            Module = "ProcessList.ps1";            Timeout = 120; Message = "Running Process List..." },
        @{ Label = "5";   Name = "DbConnectionList";       Module = "DbConnectionList.ps1";       Timeout = 180; Message = "Running DB Connection List (Net3D)..." },
        @{ Label = "6";   Name = "HostConnectionList";     Module = "HostConnectionList.ps1";     Timeout = 180; Message = "Running Host Connection List (Net3D)..." },
        @{ Label = "7";   Name = "CollectEnhancedMetrics"; Module = "CollectEnhancedMetrics.ps1"; Timeout = 240; Message = "Running Enhanced Metrics Collector..." },
        @{ Label = "8";   Name = "CollectDockerMetrics";   Module = "CollectDockerMetrics.ps1";   Timeout = 180; Message = "Running Docker Resource Metrics Collector..." }
    )

    $failedSteps = @()
    $timedOutSteps = @()

    foreach ($step in $steps) {
        $timeoutSec = [int]$step.Timeout

        # giipAgent.cfg 로 Step 별 타임아웃 재정의 (값이 있으면 기본값 대체).
        $cfgKey = "steptimeout_" + ([string]$step.Name).ToLower()
        if ($Config -and $Config[$cfgKey]) {
            $parsedStep = 0
            if ([int]::TryParse("$($Config[$cfgKey])".Trim(), [ref]$parsedStep) -and $parsedStep -gt 0) {
                $timeoutSec = $parsedStep
            } else {
                Write-GiipLog "WARN" "[Step $($step.Label)] Invalid $cfgKey='$($Config[$cfgKey])' - keeping ${timeoutSec}s."
            }
        }

        $moduleScript = Join-Path $ModuleDir $step.Module
        # 예전처럼 모듈이 없으면 "[Step N] ..." 줄을 남기지 않는다(조용한 스킵 유지).
        if (Test-Path $moduleScript) {
            Write-GiipLog "INFO" "[Step $($step.Label)] $($step.Message)"
        }
        $stepResult = Invoke-GiipStepWorker -StepLabel $step.Label -StepName $step.Name -ModuleScript $moduleScript -TimeoutSec $timeoutSec

        if ($stepResult.TimedOut) {
            $timedOutSteps += ("Step" + $stepResult.Step + ":" + $stepResult.Name)
        } elseif (-not $stepResult.Skipped -and $stepResult.ExitCode -ne 0) {
            $failedSteps += ("Step" + $stepResult.Step + ":" + $stepResult.Name + ":exit" + $stepResult.ExitCode)
        }
    }

    # ------------------------------------------------------------------
    # 실행 결과 정리 - Step 실패/타임아웃이 있으면 RunEnd(실행 이력)에 드러낸다.
    # 상태값은 tSchedulerAgentRun.status 가 실제로 받는 값만 쓴다
    # (SUCCEEDED|FAILED|TIMED_OUT|ZOMBIE_TERMINATED|SKIPPED - SP
    #  pApiSchedulerAgentRunEndBySK 의 @status 와 lib/SchedulerAgentRun.ps1 의
    #  ValidateSet 이 같은 값 목록이다). 새 값을 만들지 않는다.
    # ------------------------------------------------------------------
    $summaryParts = @()
    if ($timedOutSteps.Count -gt 0) { $summaryParts += ("timedOut=" + ($timedOutSteps -join ",")) }
    if ($failedSteps.Count -gt 0) { $summaryParts += ("failed=" + ($failedSteps -join ",")) }
    $runSummary = ($summaryParts -join ",")

    if ($timedOutSteps.Count -gt 0) {
        Write-GiipLog "ERROR" "=== giipAgent3.ps1 Completed with failures === (timedOut: $($timedOutSteps -join ', '); failed: $($failedSteps -join ', '))"
        $runStatus = "TIMED_OUT"
        $runExitCode = 1
    } elseif ($failedSteps.Count -gt 0) {
        Write-GiipLog "ERROR" "=== giipAgent3.ps1 Completed with failures === (failed: $($failedSteps -join ', '))"
        $runStatus = "FAILED"
        $runExitCode = 1
    } else {
        Write-GiipLog "INFO" "=== giipAgent3.ps1 Completed ==="
        $runStatus = "SUCCEEDED"
        $runExitCode = 0
    }
    exit $runExitCode
} catch {
    Write-GiipLog "ERROR" "giipAgent3.ps1 failed: $_"
    $runStatus = "FAILED"
    $runExitCode = 1
    exit 1
} finally {
    # giip #2390: 실행 결과(성공 exit 0 / catch로 잡힌 실패)를 그대로
    # tSchedulerAgentRun에 기록한다. 위 bootstrap 블록이 실패해 agentKey/runIdKey를
    # 못 구했으면(non-fatal, 이미 WARN 로깅됨) 여기서도 조용히 건너뛴다.
    # giip #2470: RunStart 가 실패/스킵됐으면 RunEnd 도 부르지 않는다. 짝이 없는
    # RunEnd 는 어차피 같은 404 로 실패하면서 서버 에러 로그만 두 배로 만든다
    # (실측: 576건 = RunStart 288 + RunEnd 288).
    if ($agentKey -and $runIdKey -and $runStartOk) {
        try {
            # giip #6163: summary 로 실패/타임아웃 난 Step 목록을 넘긴다.
            # (lib/SchedulerAgentRun.ps1 이 1000자로 자른다)
            Invoke-SchedulerAgentRunEnd -Config $Config -AgentKey $agentKey -RunIdKey $runIdKey -Status $runStatus -ExitCode $runExitCode -Summary $runSummary | Out-Null
        } catch {
            Write-GiipLog "WARN" "giip #2390: SchedulerAgentRunEnd failed (non-fatal): $($_.Exception.Message)"
        }
    }
    # giip #2338: always release our lock, success or failure, so the next
    # scheduled run (or a manually-restarted Task Scheduler job) doesn't
    # have to wait out the stale threshold unnecessarily.
    Exit-GiipAgentLock -LockPath $LockPath
}
