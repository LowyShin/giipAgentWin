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
    exit 0
} catch {
    Write-GiipLog "ERROR" "giipAgent3.ps1 failed: $_"
    exit 1
} finally {
    # giip #2338: always release our lock, success or failure, so the next
    # scheduled run (or a manually-restarted Task Scheduler job) doesn't
    # have to wait out the stale threshold unnecessarily.
    Exit-GiipAgentLock -LockPath $LockPath
}
