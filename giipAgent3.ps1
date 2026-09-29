# ============================================================================
# giipAgent3.ps1 (Windows Orchestrator - Robust UTF8 Version)
# Purpose: Main entry point for giipAgentWin.
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Global:BaseDir = $ScriptDir
$ModuleDir = Join-Path $ScriptDir "giipscripts\modules"
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
    if (Test-Path (Join-Path $LibDir "KVS.ps1")) {
        . (Join-Path $LibDir "KVS.ps1")
    } else {
        throw "KVS library not found at: $(Join-Path $LibDir 'KVS.ps1')"
    }

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
    # 1. Clean State
    $cleanScript = Join-Path $ModuleDir "CleanState.ps1"
    if (Test-Path $cleanScript) {
        Write-GiipLog "INFO" "[Step 1] Cleaning state..."
        & $cleanScript
    }

    # 2. Cqe Get (Fetch Queue)
    $cqeScript = Join-Path $ModuleDir "CqeGet.ps1"
    if (Test-Path $cqeScript) {
        Write-GiipLog "INFO" "[Step 2] Fetching Queue..."
        & $cqeScript
    }

    # 2.5 Cqe Run (Execute the queue CqeGet just fetched)
    #
    # giip #2546: 여기가 몇 달간 비어 있던 자리다. Step 2 가 data\queue.json 에
    # 작업을 저장해 놓아도 실행하는 코드가 없었고, 다음 회차 Step 1(CleanState)이
    # 그 파일을 조용히 지웠다. 반드시 Step 2 직후에, **같은 실행 안에서** 큐를
    # 소비해야 유실 창이 생기지 않는다. 아래 Step 3~7 수집 순서는 그대로 둔다.
    #
    # CQE 작업이 실패해도(모듈이 exit 1) 수집 스텝은 계속 돌아야 하므로 여기서
    # 예외를 만들지 않는다 - PowerShell 에서 '&' 로 부른 스크립트의 exit 코드는
    # $LASTEXITCODE 에만 남고 호출자를 중단시키지 않는다(Step 2 도 동일 구조).
    $cqeRunScript = Join-Path $ModuleDir "CqeRun.ps1"
    if (Test-Path $cqeRunScript) {
        Write-GiipLog "INFO" "[Step 2.5] Running Queue Task..."
        & $cqeRunScript
    }

    # 3. DB Monitor (Database Metrics)
    $dbMonitorScript = Join-Path $ModuleDir "DbMonitor.ps1"
    if (Test-Path $dbMonitorScript) {
        Write-GiipLog "INFO" "[Step 3] Running DB Monitor..."
        & $dbMonitorScript
    }

    # 4. Process List (KVS Upload)
    $processListScript = Join-Path $ModuleDir "ProcessList.ps1"
    if (Test-Path $processListScript) {
        Write-GiipLog "INFO" "[Step 4] Running Process List..."
        & $processListScript
    }

    # 5. DB Connection Monitoring (Net3D)
    $dbConnScript = Join-Path $ModuleDir "DbConnectionList.ps1"
    if (Test-Path $dbConnScript) {
        Write-GiipLog "INFO" "[Step 5] Running DB Connection List (Net3D)..."
        & $dbConnScript
    }

    # 6. Host Connection (Netstat) Monitoring (Net3D)
    $hostConnScript = Join-Path $ModuleDir "HostConnectionList.ps1"
    if (Test-Path $hostConnScript) {
        Write-GiipLog "INFO" "[Step 6] Running Host Connection List (Net3D)..."
        & $hostConnScript
    }

    # 7. Enhanced Performance Metrics
    $enhancedMetricsScript = Join-Path $ModuleDir "CollectEnhancedMetrics.ps1"
    if (Test-Path $enhancedMetricsScript) {
        Write-GiipLog "INFO" "[Step 7] Running Enhanced Metrics Collector..."
        & $enhancedMetricsScript
    }

    # 8. Docker Resource Metrics (giip 3043, 1/4 단계)
    $dockerMetricsScript = Join-Path $ModuleDir "CollectDockerMetrics.ps1"
    if (Test-Path $dockerMetricsScript) {
        Write-GiipLog "INFO" "[Step 8] Running Docker Resource Metrics Collector..."
        & $dockerMetricsScript
    }

    Write-GiipLog "INFO" "=== giipAgent3.ps1 Completed ==="
    $runStatus = "SUCCEEDED"
    $runExitCode = 0
    exit 0
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
            Invoke-SchedulerAgentRunEnd -Config $Config -AgentKey $agentKey -RunIdKey $runIdKey -Status $runStatus -ExitCode $runExitCode | Out-Null
        } catch {
            Write-GiipLog "WARN" "giip #2390: SchedulerAgentRunEnd failed (non-fatal): $($_.Exception.Message)"
        }
    }
    # giip #2338: always release our lock, success or failure, so the next
    # scheduled run (or a manually-restarted Task Scheduler job) doesn't
    # have to wait out the stale threshold unnecessarily.
    Exit-GiipAgentLock -LockPath $LockPath
}
