# ============================================================================
# Test-DbConnectionList.ps1
# Purpose: Standalone wrapper to test DbConnectionList module
# Usage: .\Test-DbConnectionList.ps1
# ============================================================================

$ErrorActionPreference = "Stop"

# 1. Setup Environment (Mimic giipAgent3.ps1)
# Calculate paths based on script location (assumed to be in /test or root)
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

# If inside /test, go up one level to find root
if ((Split-Path -Path $ScriptDir -Leaf) -eq "test") {
    $AgentRoot = Split-Path -Path $ScriptDir -Parent
}
else {
    $AgentRoot = $ScriptDir
}

# Set Global BaseDir (Critical for Common.ps1 to find Config)
$Global:BaseDir = $AgentRoot

Write-Host "Agent Root: $AgentRoot"
Write-Host "Setting Global:BaseDir to $Global:BaseDir"

$ModulePath = Join-Path $AgentRoot "giipscripts\modules\DbConnectionList.ps1"

if (-not (Test-Path $ModulePath)) {
    Write-Error "Module not found at: $ModulePath"
    exit 1
}

# 2. Execute Module
Write-Host "Executing DbConnectionList module..."
& $ModulePath

Write-Host "Test Completed."
