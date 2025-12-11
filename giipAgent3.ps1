# ============================================================================
# giipAgent3.ps1 (Windows Orchestrator)
# Purpose: Main entry point. Calls independent modules sequentially.
# Architecture: Stateless, Non-Admin, JSON Communication.
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$ModuleDir = Join-Path $ScriptDir "giipscripts\modules"
$DataDir = Join-Path $ScriptDir "data"
$QueueFile = Join-Path $DataDir "queue.json"
$LibDir = Join-Path $ScriptDir "lib"

# Load Common for logging (optional, can relay logs)
try {
    . (Join-Path $LibDir "Common.ps1")
}
catch { Write-Host "Warning: Common lib not loaded in main script." }

Write-GiipLog "INFO" "=== giipAgent3.ps1 Started ==="

# 1. Clean State (Module Call)
$cleanScript = Join-Path $ModuleDir "CleanState.ps1"
if (Test-Path $cleanScript) {
    Write-GiipLog "INFO" "[Step 1] Cleaning state..."
    & "powershell.exe" -ExecutionPolicy Bypass -File $cleanScript
}
else {
    Write-GiipLog "ERROR" "CleanState module not found: $cleanScript"
    exit 1
}

# 2. CQE Get (Module Call)
$cqeScript = Join-Path $ModuleDir "CqeGet.ps1"
if (Test-Path $cqeScript) {
    Write-GiipLog "INFO" "[Step 2] Fetching CQE Queue..."
    & "powershell.exe" -ExecutionPolicy Bypass -File $cqeScript
}
else {
    Write-GiipLog "ERROR" "CqeGet module not found: $cqeScript"
    exit 1
}

# 3. Check & Execute
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
            & "powershell.exe" -ExecutionPolicy Bypass -File $tmpTask
            
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

Write-GiipLog "INFO" "=== giipAgent3.ps1 Completed ==="
exit 0
