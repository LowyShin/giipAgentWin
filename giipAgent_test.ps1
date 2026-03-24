# ============================================================================
# giipAgent_test.ps1 (Minimal Test Version)
# Purpose: Verify basic library loading and API connectivity
# ============================================================================

Write-Host "--- giipAgent_test.ps1 START ---" -ForegroundColor Cyan

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
$Global:BaseDir = $ScriptDir
$LibDir = Join-Path $ScriptDir "lib"

# 1. Load Common.ps1
Write-Host "[1/3] Loading Common.ps1..."
if (-not (Test-Path (Join-Path $LibDir "Common.ps1"))) {
    Write-Host "ERROR: Common.ps1 not found in $LibDir" -ForegroundColor Red
    exit 1
}
. (Join-Path $LibDir "Common.ps1")
Write-Host "  OK: Common.ps1 loaded." -ForegroundColor Green

# 2. Load Configuration
Write-Host "[2/3] Loading Configuration..."
try {
    $config = Get-GiipConfig
    Write-Host "  OK: Config loaded." -ForegroundColor Green
    Write-Host "  LSSN: $($config.lssn)"
    Write-Host "  API : $($config.apiaddrv2)"
}
catch {
    Write-Host "  ERROR: Failed to load config: $_" -ForegroundColor Red
    exit 1
}

# 3. Test API Connectivity (Heartbeat)
Write-Host "[3/3] Testing API Connectivity..."
try {
    $info = Get-SystemInfo
    $jsonData = @{
        lssn       = $config.lssn
        hostname   = $info.Hostname
        os_name    = $info.OSName
        agent_ver  = "TEST_VER"
    } | ConvertTo-Json -Compress

    Write-Host "  Sending heartbeat (UserGasProc)..."
    $res = Invoke-GiipApiV2 -Config $config -CommandText "UserGasProc" -JsonData $jsonData
    
    if ($res -and $res.RstVal -eq "0") {
        Write-Host "  SUCCESS: API returned OK." -ForegroundColor Green
    }
    else {
        Write-Host "  FAILURE: API returned RstVal=$($res.RstVal), RstMsg=$($res.RstMsg)" -ForegroundColor Red
    }
}
catch {
    Write-Host "  CRITICAL ERROR during API call: $_" -ForegroundColor Red
}

Write-Host "--- giipAgent_test.ps1 COMPLETED ---" -ForegroundColor Cyan
pause
