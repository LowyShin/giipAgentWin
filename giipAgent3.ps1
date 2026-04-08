# ============================================================================
# giipAgent3.ps1 (Windows Orchestrator - Robust UTF8 Version)
# Purpose: Main entry point for giipAgentWin.
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Global:BaseDir = $ScriptDir
$ModuleDir = Join-Path $ScriptDir "giipscripts\modules"
$LibDir = Join-Path $ScriptDir "lib"

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
} catch { 
    Write-Host "FATAL: Failed to load core libraries. ($_)"
    exit 1
}

# Ensure Logging is available
if (-not (Get-Command "Write-GiipLog" -ErrorAction SilentlyContinue)) {
    function Write-GiipLog { param($Level, $Message) Write-Host "[$Level] $Message" }
}

Write-GiipLog "INFO" "=== giipAgent3.ps1 Started ==="

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

Write-GiipLog "INFO" "=== giipAgent3.ps1 Completed ==="
exit 0
