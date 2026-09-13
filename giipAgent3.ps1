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

    # 4. Scheduler Agent Run history Library (giip #2390)
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
$Config = $null
$agentKey = $null
$runIdKey = $null
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
    Invoke-SchedulerAgentRunStart -Config $Config -AgentKey $agentKey -RunIdKey $runIdKey | Out-Null
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
    if ($agentKey -and $runIdKey) {
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
