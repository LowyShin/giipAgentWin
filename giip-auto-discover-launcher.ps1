# ============================================================================
# giip-auto-discover-launcher.ps1
# Purpose: Windowless launcher for giip-auto-discover.ps1.
#          Runs inside the SAME PowerShell process so no cmd.exe/console window
#          is spawned. Invoked via a Task Scheduler trigger every 6 hours.
#          This replaces the manual "schtasks" approach with a proper PS script
#          launcher, consistent with the giipAgent3-launcher.ps1 pattern.
# Ref: giip #2426 - servers.ips (LSNIFGlobal) empty because auto-discover
#          was never scheduled on Windows.
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
Set-Location $ScriptDir

Write-Host "Starting giip-auto-discover.ps1..."
$discoverScript = Join-Path $ScriptDir "giip-auto-discover.ps1"
& $discoverScript
$exitCode = $LASTEXITCODE
Write-Host "giip-auto-discover.ps1 execution ended [ExitCode: $exitCode]"
exit $exitCode
