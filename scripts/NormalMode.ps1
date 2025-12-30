
# ============================================================================
# GIIP Agent Normal Mode (PowerShell)
# Version: 1.0
# Date: 2025-01-10
# Purpose: Execute normal mode independently
# ============================================================================

$ErrorActionPreference = "Stop"

# 1. Initialize Paths
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$BaseDir = Split-Path -Path $ScriptDir -Parent
$LibDir = Join-Path $BaseDir "lib"
# ⚠️⚠️⚠️ DO NOT MODIFY THIS PATH ⚠️⚠️⚠️
# Config file is in PARENT of repository root
$ConfigFile = Join-Path $BaseDir "../giipAgent.cfg" # Parent of Repository Root

# 2. Load Modules
try {
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "Kvs.ps1")
    . (Join-Path $LibDir "Cqe.ps1")
}
catch {
    Write-Host "FATAL: Failed to load modules from $LibDir"
    exit 1
}

# 3. Load Config
try {
    # If config file is passed as arg, use it (TODO: args parsing if needed)
    $Config = Get-GiipConfig
}
catch {
    Write-Host "FATAL: Failed to load config: $_"
    exit 1
}

# 4. Initialization Logging
$lssn = $Config.lssn
$hostname = [System.Net.Dns]::GetHostName()

Write-GiipLog "INFO" "Starting Normal Mode. LSSN=$lssn"
Save-ExecutionLog -Config $Config -EventType "startup" -DetailsObj @{ mode = "normal"; pid = $PID }

# 5. Get Queue
$scriptContent = $null
try {
    $scriptContent = Get-Queue -Config $Config -Hostname $hostname
}
catch {
    Write-GiipLog "ERROR" "Queue fetch failed: $_"
    Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ context = "queue_fetch"; error = $_.Exception.Message }
}

# 6. Execute (if content)
if ($scriptContent) {
    Write-GiipLog "INFO" "Received task. Executing..."
    
    # Save to temp file to execute (for better debugging context and handling)
    $tmpFile = Join-Path $env:TEMP "giip_task_$PID.ps1"
    
    try {
        $scriptContent | Set-Content -Path $tmpFile -Encoding UTF8
        
        $startTime = Get-Date
        
        # Execute
        # Use Invoke-Expression or Call Operator &
        # & $tmpFile is safer/better for scripts
        
        & $tmpFile
        
        $exitCode = $LASTEXITCODE
        $duration = ((Get-Date) - $startTime).TotalSeconds
        
        Write-GiipLog "INFO" "Task executed. Exist Code: $exitCode. Duration: $duration s"
        
        Save-ExecutionLog -Config $Config -EventType "script_execution" -DetailsObj @{
            exit_code = $exitCode
            duration  = $duration
            type      = "powershell"
        }
        
    }
    catch {
        Write-GiipLog "ERROR" "Task execution failed: $_"
        Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ context = "script_exec"; error = $_.Exception.Message }
    }
    finally {
        if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force }
    }
}
else {
    Write-GiipLog "INFO" "No task."
    # Optional: Log check event (Linux does queue_check)
    Save-ExecutionLog -Config $Config -EventType "queue_check" -DetailsObj @{ has_queue = $false }
}

# 7. Shutdown Log
Save-ExecutionLog -Config $Config -EventType "shutdown" -DetailsObj @{ mode = "normal"; status = "ok" }
Write-GiipLog "INFO" "Normal Mode Completed."
exit 0
