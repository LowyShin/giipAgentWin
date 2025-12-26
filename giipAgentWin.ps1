# ============================================================================
# giipAgentWin (Main Orchestrator)
# Version: 2.0 (Modular / V2 API Standard)
# ============================================================================

# Define Global BaseDir for Modules
$Global:BaseDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

# Load Modules
try {
  . (Join-Path $Global:BaseDir "lib\Common.ps1")
  . (Join-Path $Global:BaseDir "lib\Worker.ps1")
}
catch {
  Write-Host "FATAL ERROR: Failed to load modules (lib\Common.ps1, lib\Worker.ps1)"
  exit 1
}

# Main Execution Orchestrator
function Main {
  Write-GiipLog "INFO" "Starting giipAgentWin v2.0 (Modular)"

  # 1. Load Configuration
  try {
    $Config = Get-GiipConfig
    Write-GiipLog "INFO" "Config Loaded. LSSN=$($Config.lssn)"
        
    # Validate critical loop param
    $delay = if ($Config.giipagentdelay) { [int]$Config.giipagentdelay } else { 60 }
  }
  catch {
    Write-GiipLog "ERROR" "Initialization Failed: $($_.Exception.Message)"
    exit 1
  }
    
  # 2. Infinite Loop (Poll -> Execute -> Sleep)
  while ($true) {
    try {
      # Step A: Poll
      $queueItem = Get-QueueItem -Config $Config
            
      # Step B: Execute (if any)
      if (-not [string]::IsNullOrWhiteSpace($queueItem)) {
        Invoke-AgentTask -RawQueueItem $queueItem -Config $Config
      }
            
    }
    catch {
      Write-GiipLog "ERROR" "Loop Error: $($_.Exception.Message)"
    }
        
    # Step C: Sleep
    Start-Sleep -Seconds $delay
        
    # Reload config in case lssn updated or changed
    try { $Config = Get-GiipConfig } catch {}
  }
}

# Start Main
try {
  Main
}
catch {
  Write-Host "Unhandled Exception: $($_.Exception.Message)"
  exit 1
}
