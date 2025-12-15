# ============================================================================
# giipAgent3.ps1 (Windows Orchestrator)
# Purpose: Main entry point. Calls independent modules sequentially.
# Architecture: Stateless, Non-Admin, JSON Communication.
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Global:BaseDir = $ScriptDir
$ModuleDir = Join-Path $ScriptDir "giipscripts\modules"
$DataDir = Join-Path $ScriptDir "data"
$QueueFile = Join-Path $DataDir "queue.json"
$LibDir = Join-Path $ScriptDir "lib"

# Load Common for logging
try {
    . (Join-Path $LibDir "Common.ps1")
}
catch { 
    Write-Host "Warning: Common lib not loaded. ($_)" 
}

if (-not (Get-Command "Write-GiipLog" -ErrorAction SilentlyContinue)) {
    function Write-GiipLog { param($Level, $Message) Write-Host "[$Level] $Message" }
}

Write-GiipLog "INFO" "=== giipAgent3.ps1 Started ==="

# 2. Clean State (Module Call)
$cleanScript = Join-Path $ModuleDir "CleanState.ps1"
if (Test-Path $cleanScript) {
    Write-GiipLog "INFO" "[Step 1] Cleaning state..."
    & $cleanScript
}
else {
    Write-GiipLog "ERROR" "CleanState module not found: $cleanScript"
    exit 1
}

# 3. CQE Get (Module Call)
$cqeScript = Join-Path $ModuleDir "CqeGet.ps1"
if (Test-Path $cqeScript) {
    Write-GiipLog "INFO" "[Step 2] Fetching CQE Queue..."
    & $cqeScript
}
else {
    Write-GiipLog "ERROR" "CqeGet module not found: $cqeScript"
    exit 1
}

# 4. Check & Execute
if (Test-Path $QueueFile) {
    Write-GiipLog "INFO" "[Step 3] Task found in $QueueFile. Processing..."
    
    try {
        $taskData = Get-Content -Path $QueueFile -Raw | ConvertFrom-Json
        $scriptBody = $taskData.ms_body
        
        if (-not [string]::IsNullOrWhiteSpace($scriptBody)) {
            Write-GiipLog "INFO" "Executing Task Script..."
            
            # Save Temp Script
            $tmpTask = Join-Path $env:TEMP "giip_task_$PID.ps1"
            $scriptBody | Set-Content -Path $tmpTask -Encoding UTF8
            
            # Execute
            & $tmpTask
            
            Write-GiipLog "INFO" "Task Execution Completed."
            
            # Cleanup Temp
            if (Test-Path $tmpTask) { Remove-Item $tmpTask -Force }
        }
        else {
            Write-GiipLog "WARN" "Queue file exists but 'ms_body' is empty."
        }
    }
    catch {
        Write-GiipLog "ERROR" "Failed to process task: $_"
    }
}
else {
    Write-GiipLog "INFO" "[Step 3] No task to execute."
}

# 5. DB Monitoring (Module Call)
# Runs as independent module, collects and sends DB stats
$dbMonitorScript = Join-Path $ModuleDir "DbMonitor.ps1"
if (Test-Path $dbMonitorScript) {
    Write-GiipLog "INFO" "[Step 4] Running DB Monitor..."
    & $dbMonitorScript
}


# 6. DB Connection Monitoring (Net3D) -> Rename/Keep logic
$dbConnScript = Join-Path $ModuleDir "DbConnectionList.ps1"
if (Test-Path $dbConnScript) {
    Write-GiipLog "INFO" "[Step 5] Running DB Connection List (Net3D)..."
    & $dbConnScript
}

# 7. Host Connection (Netstat) Monitoring (Net3D)
$hostConnScript = Join-Path $ModuleDir "HostConnectionList.ps1"
if (Test-Path $hostConnScript) {
    Write-GiipLog "INFO" "[Step 6] Running Host Connection List (Net3D)..."
    & $hostConnScript
}

Write-GiipLog "INFO" "=== giipAgent3.ps1 Completed ==="
exit 0
