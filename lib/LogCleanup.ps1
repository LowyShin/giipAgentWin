# ============================================================================
# LogCleanup.ps1
# Purpose: Clean up old log files (Log Rotation/Retention)
# Usage: . (Join-Path $LibDir "LogCleanup.ps1"); Start-LogCleanup -Days 7
# ============================================================================

function Start-LogCleanup {
    param (
        [int]$Days = 7,
        [string]$LogDir
    )

    if (-not $LogDir) {
        # Try to resolve LogDir based on Common.ps1 convention or global base
        $base = if ($Global:BaseDir) { $Global:BaseDir } else { Split-Path -Parent $PSScriptRoot }
        
        # Default giipLogs location (sibling to giipAgentWin)
        $LogDir = Join-Path $base "..\giipLogs"
    }

    if (-not (Test-Path $LogDir)) {
        Write-Host "[LogCleanup] Log directory not found: $LogDir"
        return
    }

    $limitDate = (Get-Date).AddDays(-$Days)
    
    try {
        # Find files older than limitDate
        # Include *.log and *.json (payload logs)
        $filesToDelete = Get-ChildItem -Path $LogDir -Recurse -File | Where-Object { 
            $_.LastWriteTime -lt $limitDate -and ($_.Extension -eq ".log" -or $_.Extension -eq ".json" -or $_.Extension -eq ".txt")
        }

        $count = 0
        if ($filesToDelete) {
            # Count could be single object or array count
            $count = if ($filesToDelete.Count) { $filesToDelete.Count } else { 1 }
            
            foreach ($file in $filesToDelete) {
                Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        
        Write-Host "[LogCleanup] Cleaned up $count files older than $Days days in $LogDir"
    }
    catch {
        Write-Host "[LogCleanup] Error during cleanup: $_"
    }
}
