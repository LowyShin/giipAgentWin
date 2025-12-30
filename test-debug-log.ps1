# test-debug-log.ps1
# Debug Log Transmission Test Script

$ErrorActionPreference = "Stop"

Write-Host "=== Debug Log Test ===" -ForegroundColor Cyan
Write-Host ""

# 1. Load Libraries
Write-Host "[1/4] Loading libraries..." -NoNewline
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Set BaseDir to script directory so config search looks in parent directory
$Global:BaseDir = $scriptDir 

$commonPath = Join-Path $scriptDir "lib\Common.ps1"
$errorLogPath = Join-Path $scriptDir "lib\ErrorLog.ps1"

if (-not (Test-Path $commonPath)) { throw "Common.ps1 not found" }
if (-not (Test-Path $errorLogPath)) { throw "ErrorLog.ps1 not found" }

. $commonPath
. $errorLogPath
Write-Host " Done." -ForegroundColor Green

# 2. Load Configuration
Write-Host "[2/4] Loading configuration..."
try {
    $Config = Get-GiipConfig
    Write-Host "      Config loaded (lssn: $($Config.lssn))" -ForegroundColor Gray
}
catch {
    Write-Host "      Failed to load config: $_" -ForegroundColor Red
    exit 1
}

# 3. Send Test Log
Write-Host "[3/4] Sending test debug log..."
$testData = @{
    source    = "giipAgent-Debug"
    severity  = "debug"
    lssn      = $Config.lssn
    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

try {
    # Send Log (Severity: debug)
    $eSn = sendErrorLog -Config $Config `
        -Message "Test debug log from test script (Re-created)" `
        -Data $testData `
        -Severity "debug"

    if ($eSn) {
        Write-Host "✅ SUCCESS: Error log created successfully! (eSn: $eSn)" -ForegroundColor Green
    }
    else {
        Write-Host "❌ FAILED: sendErrorLog returned null." -ForegroundColor Red
    }
}
catch {
    Write-Host "❌ EXCEPTION: $_" -ForegroundColor Red
}
