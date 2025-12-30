# test-kvs-put-debug.ps1
# Purpose: Test KVSPut API call with debug output to identify response issues

$ErrorActionPreference = "Stop"

Write-Host "=== KVSPut API Debug Test ===" -ForegroundColor Cyan
Write-Host ""

# 1. Load Libraries
Write-Host "[1/4] Loading libraries..." -NoNewline
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Global:BaseDir = $scriptDir

$commonPath = Join-Path $scriptDir "lib\Common.ps1"
$kvsPath = Join-Path $scriptDir "lib\KVS.ps1"

if (-not (Test-Path $commonPath)) { throw "Common.ps1 not found" }
if (-not (Test-Path $kvsPath)) { throw "KVS.ps1 not found" }

. $commonPath
. $kvsPath
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

# 3. Prepare Test Data (Small sample)
Write-Host "[3/4] Preparing test data..."
$testData = @(
    @{
        client_net_address = "192.168.1.100"
        program_name       = "Test Application"
        conn_count         = 5
        cpu_load           = 10
        last_sql           = "SELECT * FROM test_table WHERE id = 1"
    },
    @{
        client_net_address = "192.168.1.200" 
        program_name       = "Another App"
        conn_count         = 3
        cpu_load           = 5
        last_sql           = $null  # Test null value handling
    }
)

Write-Host "      Test data prepared ($($testData.Count) connection groups)" -ForegroundColor Gray

# 4. Send Test Data
Write-Host "[4/4] Sending test data to KVSPut API..."
Write-Host ""

try {
    $response = Invoke-GiipKvsPut `
        -Config $Config `
        -Type "database" `
        -Key "999" `
        -Factor "db_connections_test" `
        -Value $testData
    
    Write-Host ""
    Write-Host "=== FINAL RESULT ===" -ForegroundColor Cyan
    
    if ($null -eq $response) {
        Write-Host "❌ FAILED: Response is NULL" -ForegroundColor Red
    }
    elseif ($response.RstVal -eq "200") {
        Write-Host "✅ SUCCESS: Data sent successfully!" -ForegroundColor Green
        Write-Host "   RstVal: $($response.RstVal)" -ForegroundColor Green
        Write-Host "   RstMsg: $($response.RstMsg)" -ForegroundColor Green
        if ($response.ksn) {
            Write-Host "   KSN: $($response.ksn)" -ForegroundColor Green
        }
    }
    else {
        Write-Host "❌ FAILED: Non-200 response" -ForegroundColor Red
        Write-Host "   RstVal: $($response.RstVal)" -ForegroundColor Red
        Write-Host "   RstMsg: $($response.RstMsg)" -ForegroundColor Red
    }
}
catch {
    Write-Host "❌ EXCEPTION: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== Test Complete ===" -ForegroundColor Cyan
