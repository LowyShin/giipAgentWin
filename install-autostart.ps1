
# ============================================================================
# install-autostart.ps1 — GIIP Windows agent auto-start registration (giip #4294)
#
# Registers the GIIP Windows agent (giipAgentWin) to start automatically
# after a reboot, by reusing the existing TaskSchdReg.ps1 registration and
# adding a logon trigger to "GIIP Agent Task (v3)".
#
# Usage (run from the giipAgentWin folder, Windows PowerShell 5.1):
#   .\install-autostart.ps1            Register / refresh auto-start (default)
#   .\install-autostart.ps1 -Status    Show registration state only (no changes)
#   .\install-autostart.ps1 -Uninstall Remove the registered tasks (reversible:
#                                      run without arguments to register again)
#
# What it does, in order:
#   1. If not elevated, relaunches itself as Administrator once (-Elevated
#      flag prevents an infinite relaunch loop) and exits.
#   2. Relaxes the execution policy for this process only (never permanently).
#   3. Calls TaskSchdReg.ps1 (never modified, never re-implemented here) to
#      register "GIIP Agent Task (v3)" (5-minute repetition) and
#      "GIIP Auto-Discovery (v3)" (6-hour repetition).
#   4. Adds a logon trigger to "GIIP Agent Task (v3)" so the agent starts
#      immediately at logon instead of waiting for the next 5-minute tick.
#      The existing 5-minute repetition trigger is preserved.
#   5. Sets MultipleInstances = Parallel (see docs/task-scheduler-multiple-
#      instances.md: IgnoreNew would block recovery when a previous instance
#      hangs; duplicate-run safety is handled by lib/ProcessLock.ps1).
#      LogonType stays Interactive (ps1ui/cmdui queue scripts must show a
#      window on the user's desktop; S4U/session 0 cannot).
#   6. Re-reads the task with Get-ScheduledTask and prints the real trigger
#      list, MultipleInstances and LogonType as verification output.
#
# Security (giipAgentWin/AGENTS.md section 1 — this script introduces none
# of the banned patterns):
#   - No wscript/cscript/.vbs/.wsf/.js wrapper, no mshta/rundll32/regsvr32/
#     certutil/bitsadmin, no -EncodedCommand, no Invoke-Expression, no
#     unverified download-and-execute.
#   - No new "hidden window + ExecutionPolicy Bypass" combination: the
#     elevated relaunch opens a normal visible PowerShell window.
#   - No antivirus/EDR exception or security-setting change is assumed.
#   - Protected files are never touched: TaskSchdReg.ps1,
#     giipAgent3-launcher.ps1, git-auto-sync.ps1, gitsync.ps1.
#
# NOTE: Task registration alone is NOT proof that the agent survives a
# reboot (rule 42). Reboot verification (REBOOT_CHECK) must be done on a
# real Windows PC: reboot with auto-logon, then confirm the server shows
# Online in the console, CQE queue polling resumes, and the agent log
# (..\giipLogs\giipAgentWin_YYYYMMDD.log) has an entry stamped after the
# reboot. This VM has no Windows PC, so that check is NOT done here.
# ============================================================================
param(
    [switch]$Status,
    [switch]$Uninstall,
    # Internal: set when the script relaunches itself elevated. Prevents an
    # infinite elevation loop. Not for manual use.
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"

$AgentTaskName = "GIIP Agent Task (v3)"
$AutoDiscoveryTaskName = "GIIP Auto-Discovery (v3)"
$LauncherFileName = "giipAgent3-launcher.ps1"

if ($Status -and $Uninstall) {
    Write-Error "-Status and -Uninstall cannot be used together."
    exit 1
}

# --- Platform guard: this script only makes sense on Windows. -------------
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-Error "This script runs on Windows only (Windows PowerShell 5.1, powershell.exe)."
    exit 1
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Warning "Could not determine administrator status: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-SelfElevated {
    # Relaunch this script as Administrator exactly once. The -Elevated flag
    # tells the new process not to relaunch again. The new window is a
    # normal visible PowerShell window (no hidden-window combination).
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
    if ($Status) { $argList += " -Status" }
    if ($Uninstall) { $argList += " -Uninstall" }
    Write-Host "Administrator rights are required to register scheduled tasks."
    Write-Host "Relaunching as Administrator (approve the UAC prompt)..."
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList -ErrorAction Stop
    } catch {
        Write-Error "Elevation was declined or failed: $($_.Exception.Message)"
        Write-Host "Manual alternative: right-click PowerShell, choose 'Run as administrator', then run:"
        Write-Host "  cd $PSScriptRoot"
        Write-Host "  .\install-autostart.ps1"
        exit 1
    }
    exit 0
}

function Set-ProcessExecutionPolicy {
    # Process scope only: no permanent or machine-wide policy change.
    try {
        $current = Get-ExecutionPolicy -Scope Process
        if ($current -eq "Restricted" -or $current -eq "Undefined") {
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
            Write-Host "Execution policy for this process set to Bypass (process scope only)."
        }
    } catch {
        Write-Warning "Could not relax the execution policy for this process: $($_.Exception.Message)"
        Write-Warning "If a later step fails with a policy error, run from an elevated PowerShell with:"
        Write-Warning "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-autostart.ps1"
    }
}

function Get-TriggerDescription {
    param($Trigger)
    $parts = @($Trigger.CimClass.CimClassName)
    if ($null -ne $Trigger.Repetition -and $null -ne $Trigger.Repetition.Interval) {
        $parts += ("repeats every " + $Trigger.Repetition.Interval)
    }
    if ($null -ne $Trigger.StartBoundary -and $Trigger.StartBoundary) {
        $parts += ("starts " + $Trigger.StartBoundary)
    }
    if ($null -ne $Trigger.UserId -and $Trigger.UserId) {
        $parts += ("user " + $Trigger.UserId)
    }
    return ($parts -join ", ")
}

function Show-TaskSummary {
    param([string]$TaskName)
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } catch {
        Write-Host "  [missing] $TaskName : not registered."
        return $null
    }
    Write-Host "  Task              : $($task.TaskName)"
    Write-Host "  State             : $($task.State)"
    Write-Host "  LogonType         : $($task.Principal.LogonType) (user: $($task.Principal.UserId))"
    Write-Host "  MultipleInstances : $($task.Settings.MultipleInstances)"
    Write-Host "  Triggers          :"
    foreach ($trigger in $task.Triggers) {
        Write-Host ("    - " + (Get-TriggerDescription -Trigger $trigger))
    }
    return $task
}

function Test-AgentTaskReady {
    param([string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $hasRepetition = $false
    $hasLogon = $false
    $repetitionInterval = ""
    foreach ($trigger in $task.Triggers) {
        if ($trigger.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger") {
            $hasLogon = $true
        }
        if ($null -ne $trigger.Repetition -and $null -ne $trigger.Repetition.Interval) {
            $hasRepetition = $true
            $repetitionInterval = $trigger.Repetition.Interval
        }
    }
    $parallel = ($task.Settings.MultipleInstances -eq "Parallel")
    $interactive = ($task.Principal.LogonType -eq "Interactive")
    Write-Host "  Verification for $TaskName :"
    Write-Host "    repetition trigger (5 min) : $hasRepetition ($repetitionInterval)"
    Write-Host "    logon trigger              : $hasLogon"
    Write-Host "    MultipleInstances=Parallel : $parallel ($($task.Settings.MultipleInstances))"
    Write-Host "    LogonType=Interactive      : $interactive ($($task.Principal.LogonType))"
    return ($hasRepetition -and $hasLogon -and $parallel -and $interactive)
}

function Show-RunAndLogGuidance {
    Write-Host ""
    Write-Host "Run the agent once right now (no reboot needed for this check):"
    Write-Host "  Start-ScheduledTask -TaskName `"$AgentTaskName`""
    Write-Host ""
    Write-Host "Agent log (look for an entry stamped after this run / after a reboot):"
    Write-Host "  $(Join-Path (Join-Path $PSScriptRoot '..\giipLogs') ('giipAgentWin_' + (Get-Date -Format 'yyyyMMdd') + '.log'))"
    Write-Host ""
    Write-Host "After a reboot (with auto-logon), confirm in the GIIP console that"
    Write-Host "the server shows Online and CQE queue polling resumes."
}

# --- -Status: read-only, no elevation, no changes. -------------------------
if ($Status) {
    Write-Host "Auto-start status (no changes made):"
    $agentTask = Show-TaskSummary -TaskName $AgentTaskName
    Show-TaskSummary -TaskName $AutoDiscoveryTaskName | Out-Null
    if ($null -eq $agentTask) {
        Write-Host ""
        Write-Host "Not registered. Run .\install-autostart.ps1 to register auto-start."
        exit 1
    }
    exit 0
}

# --- Install / Uninstall need Administrator. ------------------------------
if (-not $Elevated -and -not (Test-IsAdministrator)) {
    Invoke-SelfElevated
}

if ($Uninstall) {
    Write-Host "Removing auto-start registration (reversible: run .\install-autostart.ps1 to register again)..."
    foreach ($name in @($AgentTaskName, $AutoDiscoveryTaskName)) {
        try {
            $existing = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
            Write-Host "  Removed: $name"
        } catch {
            Write-Host "  [already absent] $name"
        }
    }
    Write-Host ""
    Write-Host "Verification (both tasks must be gone):"
    $stillThere = @()
    foreach ($name in @($AgentTaskName, $AutoDiscoveryTaskName)) {
        try {
            Get-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null
            $stillThere += $name
            Write-Host "  [STILL PRESENT] $name"
        } catch {
            Write-Host "  [gone] $name"
        }
    }
    if ($stillThere.Count -gt 0) {
        Write-Error "Uninstall incomplete: $($stillThere -join ', ') still registered."
        exit 1
    }
    Write-Host "Uninstall complete."
    exit 0
}

# --- Install (default). ----------------------------------------------------
Set-ProcessExecutionPolicy

$taskSchdRegPath = Join-Path $PSScriptRoot "TaskSchdReg.ps1"
if (-not (Test-Path $taskSchdRegPath)) {
    Write-Error "TaskSchdReg.ps1 not found at $taskSchdRegPath. Run this script from the giipAgentWin folder."
    exit 1
}

# TaskSchdReg.ps1 calls exit 1 when its target launcher is missing, and
# exit inside a &-invoked script would end this session too, so check the
# launcher first. (This is the only exit path in TaskSchdReg.ps1.)
$launcherPath = Join-Path $PSScriptRoot $LauncherFileName
if (-not (Test-Path $launcherPath)) {
    Write-Error "Launcher not found: $launcherPath. Cannot register the agent task."
    exit 1
}

Write-Host "Step 1/3: Registering scheduled tasks via TaskSchdReg.ps1 (existing script, not modified)..."
& $taskSchdRegPath

try {
    Get-ScheduledTask -TaskName $AgentTaskName -ErrorAction Stop | Out-Null
} catch {
    Write-Error "TaskSchdReg.ps1 ran, but '$AgentTaskName' is still not registered. See the output above for the cause."
    exit 1
}

Write-Host ""
Write-Host "Step 2/3: Adding a logon trigger to '$AgentTaskName' (keeping the 5-minute repetition trigger)..."
$task = Get-ScheduledTask -TaskName $AgentTaskName -ErrorAction Stop
$hasLogon = $false
foreach ($trigger in $task.Triggers) {
    if ($trigger.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger") {
        $hasLogon = $true
    }
}
if ($hasLogon) {
    Write-Host "  Logon trigger already present. Nothing to add."
} else {
    $triggers = @($task.Triggers) + (New-ScheduledTaskTrigger -AtLogOn)
    Set-ScheduledTask -TaskName $AgentTaskName -Trigger $triggers -ErrorAction Stop
    Write-Host "  Logon trigger added."
}

Write-Host ""
Write-Host "Step 3/3: Setting MultipleInstances = Parallel (keeps LogonType Interactive)..."
$task = Get-ScheduledTask -TaskName $AgentTaskName -ErrorAction Stop
if ($task.Settings.MultipleInstances -ne "Parallel") {
    $task.Settings.MultipleInstances = "Parallel"
    Set-ScheduledTask -InputObject $task -ErrorAction Stop
    Write-Host "  MultipleInstances set to Parallel."
} else {
    Write-Host "  MultipleInstances is already Parallel."
}

Write-Host ""
Write-Host "Registration result:"
Show-TaskSummary -TaskName $AgentTaskName | Out-Null
Show-TaskSummary -TaskName $AutoDiscoveryTaskName | Out-Null

Write-Host ""
$ready = Test-AgentTaskReady -TaskName $AgentTaskName
if (-not $ready) {
    Write-Error "Verification failed: the task does not have a 5-minute repetition trigger AND a logon trigger with MultipleInstances=Parallel and LogonType=Interactive. See the output above."
    exit 1
}

Write-Host ""
Write-Host "Auto-start registration complete."
Show-RunAndLogGuidance
exit 0
