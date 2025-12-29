# ============================================================================
# Test Script: Debug Log Function (Send-GiipDebugLog)
# Purpose: Verify that debug logging to central DB works correctly
# Usage: pwsh .\test-debug-log.ps1
# ============================================================================

$ErrorActionPreference = "Stop"

# Setup paths
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$LibDir = Join-Path $ScriptDir "lib"

Write-Host "=== Debug Log Test ===" -ForegroundColor Cyan
Write-Host ""

# Load libraries
try {
    Write-Host "[1/4] Loading libraries..." -ForegroundColor Yellow
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "DebugLog.ps1")
    Write-Host "      ✓ Libraries loaded successfully" -ForegroundColor Green
}
catch {
    Write-Host "      ✗ Failed to load libraries: $_" -ForegroundColor Red
    exit 1
}

# Load config
try {
    Write-Host "[2/4] Loading configuration..." -ForegroundColor Yellow
    $Config = Get-GiipConfig
    Write-Host "      ✓ Config loaded (lssn: $($Config.lssn))" -ForegroundColor Green
}
catch {
    Write-Host "      ✗ Failed to load config: $_" -ForegroundColor Red
    exit 1
}

# Test 1: Simple debug log
try {
    Write-Host "[3/4] Sending test debug log..." -ForegroundColor Yellow
    Send-GiipDebugLog -Config $Config -Message "Test debug log from test script" -Severity "debug"
    Write-Host "      ✓ Debug log sent successfully" -ForegroundColor Green
}
catch {
    Write-Host "      ✗ Failed to send debug log: $_" -ForegroundColor Red
    exit 1
}

# Test 2: Debug log with request data
try {
    Write-Host "[4/4] Sending test debug log with payload..." -ForegroundColor Yellow
    
    $testPayload = @{
        test_field = "Test Value"
        user_name  = "Test'User"
        timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json -Compress
    
    Send-GiipDebugLog -Config $Config -Message "Test log with payload (including special char ')" -RequestData $testPayload -Severity "debug"
    Write-Host "      ✓ Debug log with payload sent successfully" -ForegroundColor Green
}
catch {
    Write-Host "      ✗ Failed to send debug log with payload: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== All Tests Passed ===" -ForegroundColor Green
Write-Host ""
Write-Host "📝 Verification Steps:" -ForegroundColor Cyan
Write-Host "   1. Run: pwsh .\giipdb\scripts\errorlogproc\query-errorlogs.ps1" -ForegroundColor Gray
Write-Host "   2. Look for logs with source='giipAgent-Debug'" -ForegroundColor Gray
Write-Host "   3. Check that requestData field contains the test payload" -ForegroundColor Gray
Write-Host ""
