## Check for administrator privileges - Not required for User execution context
# But needed for Register-ScheduledTask

Write-Host "Re-registering Task Scheduler for giipAgent3.ps1 (5-min interval)..." -ForegroundColor Cyan

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Get-Location }

$targetScript = Join-Path $scriptDir "giipAgent3.ps1"

if (-not (Test-Path $targetScript)) {
    Write-Error "Target script not found: $targetScript"
    exit 1
}

$taskName = "GIIP Agent Task (v3)"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$targetScript`""
$trigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)
# Run as current user (Interactive or Background depending on login)
# For specific User account execution without password, usually requires 'LogonType Interactive' or S4U.
# Assuming this is run by the user who wants to run the agent.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

# Or use S4U (Do not store password) if rights allow
# $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U 

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force

Write-Host "Task '$taskName' registered successfully to run every 5 minutes." -ForegroundColor Green
