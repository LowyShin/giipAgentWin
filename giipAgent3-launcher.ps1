# ============================================================================
# giipAgent3-launcher.ps1
# Purpose: Windowless replacement for giipAgent3.bat.
#          Runs git-auto-sync.ps1 (pull latest) then giipAgent3.ps1, all inside
#          the SAME PowerShell process so no cmd.exe/console window is ever
#          spawned. Invoked via giipAgent3-silent.vbs (wscript.exe), which is
#          the actual Task Scheduler action target - see TaskSchdReg.ps1.
#          ("powershell.exe -WindowStyle Hidden" alone can still briefly
#          flash a console window on some Windows builds/logon types.)
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
Set-Location $ScriptDir

$syncScript = Join-Path $ScriptDir "git-auto-sync.ps1"
if (Test-Path $syncScript) {
    Write-Host "Starting Safe Git Sync..."
    & $syncScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Sync failed. Agent will not start."
        exit 1
    }
    Write-Host "Safe Git Sync completed successfully."
} else {
    Write-Host "WARN: git-auto-sync.ps1 not found at $syncScript. Skipping sync."
}

Write-Host "Starting giipAgent3.ps1..."
$agentScript = Join-Path $ScriptDir "giipAgent3.ps1"
& $agentScript
$exitCode = $LASTEXITCODE
Write-Host "giipAgent3.ps1 execution ended [ExitCode: $exitCode]"
exit $exitCode
