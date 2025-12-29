# ============================================================================
# Test Script: Debug Log Function (Send-GiipDebugLog)
# Purpose: Verify that debug logging to central DB works correctly
# Usage: pwsh .\test-debug-log.ps1
# ============================================================================

$ErrorActionPreference = "Stop"

# Setup paths
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$LibDir = Join-Path $ScriptDir "lib"

# Set global BaseDir for config discovery
$Global:BaseDir = $ScriptDir

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

# Load config (with auto-search fallback and template copy)
Write-Host "[2/4] Loading configuration..." -ForegroundColor Yellow
$Config = $null

# Try default paths first
try {
    $Config = Get-GiipConfig
    Write-Host "      ✓ Config loaded (lssn: $($Config.lssn))" -ForegroundColor Green
}
catch {
    # Fallback 1: Search parent directories
    Write-Host "      ⚠ Config not found. Searching parent directories..." -ForegroundColor Yellow
    $searchDir = $ScriptDir
    $found = $false
    
    while ($searchDir) {
        $cfgPath = Join-Path $searchDir "giipAgent.cfg"
        if (Test-Path $cfgPath) {
            Write-Host "      ✓ Found at: $cfgPath" -ForegroundColor Green
            $Global:BaseDir = $searchDir
            $Config = Parse-ConfigFile -Path $cfgPath
            $found = $true
            break
        }
        $parent = Split-Path $searchDir -Parent
        if ($parent -eq $searchDir) { break }
        $searchDir = $parent
    }
    
    # Fallback 2: Offer to copy template
    if (-not $found) {
        Write-Host "      ✗ Config not found anywhere" -ForegroundColor Red
        
        $templatePath = Join-Path $ScriptDir "giipAgent.cfg"
        $targetPath = Join-Path (Split-Path $ScriptDir -Parent) "giipAgent.cfg"
        
        Write-Host ""
        Write-Host "💡 Template found: $templatePath" -ForegroundColor Cyan
        Write-Host "📋 Suggestion: Copy template to parent directory:" -ForegroundColor Yellow
        Write-Host "   Copy-Item '$templatePath' '$targetPath'" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   Then edit the file and set your actual values:" -ForegroundColor Yellow
        Write-Host "   - sk = ""your-actual-token""" -ForegroundColor Gray
        Write-Host "   - lssn = ""your-actual-lssn""" -ForegroundColor Gray
        Write-Host ""
        
        # Auto-copy for testing (commented out for safety)
        # Uncomment below to auto-create config with template values
        # Copy-Item $templatePath $targetPath -Force
        # Write-Host "   ✓ Template copied! Please edit $targetPath" -ForegroundColor Green
        
        exit 1
    }
}

# Test 1: Simple debug log
try {
    Write-Host "[3/4] Sending test debug log..." -ForegroundColor Yellow
    $eSn1 = Send-GiipDebugLog -Config $Config -Message "Test debug log from test script" -Severity "debug"
    Write-Host "      ✓ Debug log sent successfully (eSn: $eSn1)" -ForegroundColor Green
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
    
    $eSn2 = Send-GiipDebugLog -Config $Config -Message "Test log with payload (including special char ')" -RequestData $testPayload -Severity "debug"
    Write-Host "      ✓ Debug log with payload sent successfully (eSn: $eSn2)" -ForegroundColor Green
}
catch {
    Write-Host "      ✗ Failed to send debug log with payload: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== All Tests Passed ===" -ForegroundColor Green
Write-Host ""
Write-Host "📝 Verification Steps:" -ForegroundColor Cyan
Write-Host "   pwsh .\giipdb\scripts\errorlogproc\query-errorlog-detail.ps1 -ErrorId $eSn1" -ForegroundColor Yellow
Write-Host "   pwsh .\giipdb\scripts\errorlogproc\query-errorlog-detail.ps1 -ErrorId $eSn2" -ForegroundColor Yellow
Write-Host ""
