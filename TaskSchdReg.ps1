## Check for administrator privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script needs to be run as Administrator. Please restart PowerShell as Administrator and try again."
    exit
}

## Basic task information
$taskName = "GIIP Agent Task"
$taskDescription = "Executes the giipAgent.wsf file every 1 minute starting at midnight daily."

## Get the folder where this script is located and check if the `giipAgentWin.ps1` file exists
# Use $PSScriptRoot when running from a script file; fall back to the current location otherwise
if ($PSScriptRoot) {
    $scriptDir = $PSScriptRoot
} else {
    $scriptDir = Get-Location
}
$wsfFilePath = Join-Path -Path $scriptDir -ChildPath "giipAgentWin.ps1"

## Check if the `giipAgentWin.ps1` file exists
if (!(Test-Path -Path $wsfFilePath -PathType Leaf)) {
    Write-Host "giipAgentWin.ps1 file not found in the current directory ($scriptDir). Please check and try again."
    exit
}

## Define the task scheduler settings
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$wsfFilePath`""

## Set the trigger to start at 00:00 and repeat every 1 minute for 1 day (24 hours)
$trigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 1)

## Specify the account and privileges for running the task
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

## Task settings
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $taskSettings -Principal $principal -Description $taskDescription

## Register the task with Task Scheduler
Register-ScheduledTask -TaskName $taskName -InputObject $task

Write-Host "Task '$taskName' has been successfully registered to execute every 1 minute starting daily at midnight."
