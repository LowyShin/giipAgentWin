## Check for administrator privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script needs to be run as Administrator. Please restart PowerShell as Administrator and try again." -ForegroundColor Red
    exit
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "GIIP Agent Installation Script" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

## Basic task information
$taskName = "GIIP Agent Task"
$autoDiscoveryTaskName = "GIIP Auto-Discovery Task"
$taskDescription = "Executes the giipAgent.wsf file every 1 minute starting at midnight daily."
$autoDiscoveryDescription = "Executes auto-discovery every 5 minutes to collect server information."

## Check for existing tasks
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$existingAutoDiscoveryTask = Get-ScheduledTask -TaskName $autoDiscoveryTaskName -ErrorAction SilentlyContinue

if ($existingTask -or $existingAutoDiscoveryTask) {
    Write-Host "⚠ Existing GIIP Agent installation detected!" -ForegroundColor Yellow
    Write-Host ""
    
    if ($existingTask) {
        Write-Host "  • $taskName" -ForegroundColor Yellow
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        Write-Host "    Status: $($existingTask.State)" -ForegroundColor Gray
        Write-Host "    Last Run: $($taskInfo.LastRunTime)" -ForegroundColor Gray
    }
    
    if ($existingAutoDiscoveryTask) {
        Write-Host "  • $autoDiscoveryTaskName" -ForegroundColor Yellow
        $autoTaskInfo = Get-ScheduledTaskInfo -TaskName $autoDiscoveryTaskName
        Write-Host "    Status: $($existingAutoDiscoveryTask.State)" -ForegroundColor Gray
        Write-Host "    Last Run: $($autoTaskInfo.LastRunTime)" -ForegroundColor Gray
    }
    
    Write-Host ""
    $response = Read-Host "Do you want to REMOVE old tasks and reinstall? (Y/N)"
    
    if ($response -eq 'Y' -or $response -eq 'y') {
        Write-Host ""
        Write-Host "Removing old GIIP tasks..." -ForegroundColor Yellow
        
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "  ✓ Removed: $taskName" -ForegroundColor Green
        }
        
        if ($existingAutoDiscoveryTask) {
            Unregister-ScheduledTask -TaskName $autoDiscoveryTaskName -Confirm:$false
            Write-Host "  ✓ Removed: $autoDiscoveryTaskName" -ForegroundColor Green
        }
        
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "Installation cancelled. Existing tasks kept." -ForegroundColor Yellow
        exit 0
    }
}

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
Write-Host "Installing GIIP Agent task..." -ForegroundColor Cyan
Register-ScheduledTask -TaskName $taskName -InputObject $task | Out-Null
Write-Host "✓ Task '$taskName' registered successfully" -ForegroundColor Green

## ============================================================================
## Register Auto-Discovery Task (every 5 minutes)
## ============================================================================
Write-Host ""
Write-Host "Setting up Auto-Discovery task..." -ForegroundColor Cyan

$autoDiscoveryScriptPath = Join-Path -Path $scriptDir -ChildPath "giip-auto-discover.ps1"

if (!(Test-Path -Path $autoDiscoveryScriptPath -PathType Leaf)) {
    Write-Host "⚠ Warning: giip-auto-discover.ps1 file not found." -ForegroundColor Yellow
    Write-Host "  Expected location: $scriptDir" -ForegroundColor Gray
    Write-Host "  Auto-Discovery task will not be registered." -ForegroundColor Yellow
} else {
    # Create action for auto-discovery (PowerShell execution)
    $autoDiscoveryAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$autoDiscoveryScriptPath`""
    
    # Set trigger to repeat every 5 minutes
    $autoDiscoveryTrigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)
    
    # Use same principal and settings as main agent
    $autoDiscoveryTask = New-ScheduledTask -Action $autoDiscoveryAction -Trigger $autoDiscoveryTrigger -Settings $taskSettings -Principal $principal -Description $autoDiscoveryDescription
    
    # Register the auto-discovery task
    Register-ScheduledTask -TaskName $autoDiscoveryTaskName -InputObject $autoDiscoveryTask | Out-Null
    
    Write-Host "✓ Task '$autoDiscoveryTaskName' registered successfully" -ForegroundColor Green
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "✓ Installation completed successfully!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Installed components:" -ForegroundColor White
Write-Host "  • GIIP Agent (runs every 1 minute)" -ForegroundColor Gray
Write-Host "  • Auto-Discovery (runs every 5 minutes)" -ForegroundColor Gray
Write-Host ""
Write-Host "Auto-Discovery collects:" -ForegroundColor White
Write-Host "  • OS and Hardware information" -ForegroundColor Gray
Write-Host "  • Installed software inventory" -ForegroundColor Gray
Write-Host "  • Running services and processes" -ForegroundColor Gray
Write-Host "  • Network interfaces and configuration" -ForegroundColor Gray
Write-Host "  • Generates operational advice" -ForegroundColor Gray
Write-Host ""
Write-Host "Log files location:" -ForegroundColor White
Write-Host "  $LogDir" -ForegroundColor Gray
Write-Host ""
Write-Host "To verify installation:" -ForegroundColor White
Write-Host "  Get-ScheduledTask -TaskName 'GIIP*'" -ForegroundColor Gray
Write-Host ""
Write-Host "To test auto-discovery:" -ForegroundColor White
Write-Host "  .\giip-auto-discover.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
