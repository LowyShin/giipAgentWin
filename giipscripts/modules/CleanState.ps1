# ============================================================================
# CleanState.ps1 (Restored Pure ASCII Version)
# Purpose: Delete previous state files and old logs for a clean start.
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
            Write-Host "  Deleted: $file"
        }
        catch {
            Write-Host "  Failed to delete: $file ($($_.Exception.Message))"
        }
    }
}

# Clean old log files (keep last 7 days)
$LogDir = Join-Path $AgentRoot "giipLogs"
if (Test-Path $LogDir) {
    Write-Host "Cleaning old log files (keeping last 7 days)..."
    $cutoffDate = (Get-Date).AddDays(-7)
    
    try {
        Get-ChildItem -Path $LogDir -Filter "*.log" | Where-Object {
            $_.LastWriteTime -lt $cutoffDate
        } | ForEach-Object {
            Remove-Item $_.FullName -Force
            Write-Host "  Deleted old log: $($_.Name)"
        }
    }
    catch {
        Write-Host "  Warning: Failed to clean some log files ($($_.Exception.Message))"
    }
}

Write-Host "Clean state completed."
exit 0
