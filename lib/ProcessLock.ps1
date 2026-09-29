# ============================================================================
# ProcessLock.ps1
# Purpose: giip #2338 - prevent a hung giipAgent3.ps1 instance from silently
#          blocking Net3D collection forever (2026-09-09 01:15 ~ 2026-09-11
#          incident, 57h+ outage on Lowy-DP01 / lssn 71197).
#
# IMPORTANT: this lock only has an effect once the Windows Task Scheduler job
# "GIIP Agent Task (v3)" is also switched away from its default
# MultipleInstances=IgnoreNew policy. With IgnoreNew, a hung previous
# instance stops Task Scheduler from starting a NEW giipAgent3.ps1 process at
# all (confirmed via event ID 322 "instance is already running" with no new
# process creation) -- so this code never even gets a chance to run during a
# hang. See docs/task-scheduler-multiple-instances.md for the exact command
# to change that policy; that change is NOT applied by this library or by
# giipAgent3.ps1 itself, it must be applied to the live Task Scheduler job
# separately.
#
# Usage:
#   . (Join-Path $LibDir "ProcessLock.ps1")
#   $lockResult = Enter-GiipAgentLock -LockPath $LockPath -StaleThresholdMinutes 30
#   if (-not $lockResult.ShouldProceed) { exit 0 }
#   try {
#       ... do work ...
#   } finally {
#       Exit-GiipAgentLock -LockPath $LockPath
#   }
# ============================================================================

function Enter-GiipAgentLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [int]$StaleThresholdMinutes = 30
    )

    $result = [ordered]@{
        ShouldProceed = $true
        Status        = "Acquired"
        Detail        = ""
    }

    if (Test-Path $LockPath) {
        $existing = $null
        try {
            $raw = Get-Content -Path $LockPath -Raw -Encoding UTF8 -ErrorAction Stop
            $existing = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $existing = $null
        }

        if (-not $existing -or -not $existing.Pid -or -not $existing.StartTimeUtc) {
            $result.Status = "AcquiredCorruptLock"
            $result.Detail = "Existing lock file at $LockPath was missing/unparsable fields; overwriting."
        } else {
            $existingPid = [int]$existing.Pid
            $existingProcess = Get-Process -Id $existingPid -ErrorAction SilentlyContinue

            if (-not $existingProcess) {
                $result.Status = "AcquiredDeadProcess"
                $result.Detail = "Lock PID $existingPid is not running anymore; overwriting stale lock."
            } else {
                $startTimeUtc = $null
                try {
                    $startTimeUtc = [DateTime]::Parse(
                        [string]$existing.StartTimeUtc,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind)
                } catch {
                    $startTimeUtc = $null
                }

                if (-not $startTimeUtc) {
                    $result.Status = "AcquiredUnparsableTimestamp"
                    $result.Detail = "Lock PID $existingPid had an unparsable StartTimeUtc ('$($existing.StartTimeUtc)'); overwriting."
                } else {
                    $elapsedMinutes = ((Get-Date).ToUniversalTime() - $startTimeUtc).TotalMinutes
                    if ($elapsedMinutes -ge $StaleThresholdMinutes) {
                        try {
                            Stop-Process -Id $existingPid -Force -ErrorAction Stop
                            $result.Status = "AcquiredKilledStale"
                            $result.Detail = "Previous instance (PID $existingPid) had been running for $([math]::Round($elapsedMinutes,1)) min (>= $StaleThresholdMinutes min threshold); force-killed and lock reclaimed."
                        } catch {
                            $result.ShouldProceed = $false
                            $result.Status = "KillFailed"
                            $result.Detail = "Previous instance (PID $existingPid) exceeded the $StaleThresholdMinutes min threshold ($([math]::Round($elapsedMinutes,1)) min) but Stop-Process failed: $_"
                            return [pscustomobject]$result
                        }
                    } else {
                        $result.ShouldProceed = $false
                        $result.Status = "AlreadyRunning"
                        $result.Detail = "Previous instance (PID $existingPid) still running for $([math]::Round($elapsedMinutes,1)) min (< $StaleThresholdMinutes min threshold); skipping this duplicate run."
                        return [pscustomobject]$result
                    }
                }
            }
        }
    } else {
        $result.Status = "AcquiredNoLock"
        $result.Detail = "No existing lock file at $LockPath."
    }

    # Acquire: (re)write the lock with our own PID + start time.
    $lockDir = Split-Path -Path $LockPath -Parent
    if ($lockDir -and -not (Test-Path $lockDir)) {
        New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
    }
    $payload = [ordered]@{
        Pid          = $PID
        StartTimeUtc = (Get-Date).ToUniversalTime().ToString("o")
        Host         = $env:COMPUTERNAME
    }
    ($payload | ConvertTo-Json -Compress) | Set-Content -Path $LockPath -Encoding UTF8 -Force

    return [pscustomobject]$result
}

function Exit-GiipAgentLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LockPath
    )
    if (-not (Test-Path $LockPath)) { return }
    try {
        $raw = Get-Content -Path $LockPath -Raw -Encoding UTF8 -ErrorAction Stop
        $existing = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($existing -and [int]$existing.Pid -eq $PID) {
            Remove-Item -Path $LockPath -Force -ErrorAction SilentlyContinue
        }
        # If the lock belongs to a different PID (e.g. a newer instance that
        # already reclaimed it after killing us for being stale), leave it
        # alone -- deleting it here would release a lock we no longer own.
    } catch {
        # Corrupt/unreadable lock file: leave it. Enter-GiipAgentLock treats
        # an unparsable lock as stale/corrupt and reclaims it on next run.
    }
}
