# ============================================================================
# CleanState.ps1
# Purpose: Delete previous state files (JSON) to ensure a clean start.
# Usage: .\CleanState.ps1
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$DataDir = Join-Path $AgentRoot "data"

# Create data directory if not exists
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Write-Host "Created data directory: $DataDir"
}

Write-Host "Cleaning state files in $DataDir..."

# Clean target files
$targets = @("queue.json", "task_result.json", "last_run.json")

foreach ($file in $targets) {
    $path = Join-Path $DataDir $file
    if (Test-Path $path) {
        try {
            Remove-Item -Path $path -Force
            Write-Host "  Deleted: $file" -ForegroundColor Green
        }
        catch {
            Write-Host "  Failed to delete: $file ($($_.Exception.Message))" -ForegroundColor Red
        }
    }
}

Write-Host "Clean state completed."
exit 0
