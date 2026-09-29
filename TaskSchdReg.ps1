## Check for administrator privileges - Not required for User execution context
# But needed for Register-ScheduledTask

Write-Host "Re-registering Task Scheduler for giipAgent3 (5-min interval, silent)..." -ForegroundColor Cyan

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Get-Location }

# "conhost.exe --headless powershell.exe ..." is used instead of
# "powershell.exe -WindowStyle Hidden": -WindowStyle Hidden still briefly flashes a
# console window on some Windows builds/logon types, while conhost --headless never
# creates one. Unlike the former wscript.exe + .vbs wrapper, both binaries are
# Microsoft-signed and there is no script-host launch that security products flag.
# LogonType stays Interactive on purpose: ps1ui/cmdui queue scripts (lib/ScriptRunner.ps1)
# must show a window on the user's desktop, which S4U (session 0) cannot do.
$targetScript = Join-Path $scriptDir "giipAgent3-launcher.ps1"

if (-not (Test-Path $targetScript)) {
    Write-Error "Target script not found: $targetScript"
    exit 1
}

$taskName = "GIIP Agent Task (v3)"
$action = New-ScheduledTaskAction -Execute "conhost.exe" -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$targetScript`""
$trigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 5)
# Run as current user (Interactive or Background depending on login)
# For specific User account execution without password, usually requires 'LogonType Interactive' or S4U.
# Assuming this is run by the user who wants to run the agent.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

# Or use S4U (Do not store password) if rights allow
# $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force

Write-Host "Task '$taskName' registered successfully to run every 5 minutes." -ForegroundColor Green

# ============================================================================
# giip #2426: Register auto-discovery task (6-hour interval)
# This populates servers.ips (LSNIFGlobal) via AgentAutoRegister API.
# Without this, Net3D cannot map external IPs to server nodes.
# ============================================================================
$autoDiscoverScript = Join-Path $scriptDir "giip-auto-discover-launcher.ps1"
if (Test-Path $autoDiscoverScript) {
    $autoDiscoverTaskName = "GIIP Auto-Discovery (v3)"
    $autoDiscoverAction = New-ScheduledTaskAction -Execute "conhost.exe" -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$autoDiscoverScript`""
    # Run once at startup, then repeat every 6 hours
    $autoDiscoverTrigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Hours 6)
    Register-ScheduledTask -TaskName $autoDiscoverTaskName -Action $autoDiscoverAction -Trigger $autoDiscoverTrigger -Principal $principal -Force
    Write-Host "Task '$autoDiscoverTaskName' registered to run every 6 hours." -ForegroundColor Green
} else {
    Write-Warning "giip-auto-discover-launcher.ps1 not found at $autoDiscoverScript. Auto-discovery task not registered."
}
