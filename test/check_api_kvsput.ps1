# ============================================================================
# check_api_kvsput.ps1
# Purpose: Verify KVSPut API functionality and supported kTypes
# Usage: .\check_api_kvsput.ps1 [MdbId]
# ============================================================================
param(
    [string]$MdbId = "8" # Default MdbId to test
)

$ErrorActionPreference = "Stop"

# 1. Setup Environment
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
if ((Split-Path -Path $ScriptDir -Leaf) -eq "test") {
    $AgentRoot = Split-Path -Path $ScriptDir -Parent
}
else {
    $AgentRoot = $ScriptDir
}
$LibDir = Join-Path $AgentRoot "lib"
$Global:BaseDir = $AgentRoot

# Load Libraries
try { 
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "KVS.ps1")
}
catch { Write-Error "Failed to load libraries"; exit 1 }

# Load Config
try { $Config = Get-GiipConfig } catch { Write-Error "Failed to load Config"; exit 1 }

Write-Host "NOTE: Using LSSN=$($Config.lssn), MdbId=$MdbId" -ForegroundColor Cyan

function Test-KVSPut {
    param($kType, $kKey, $kFactor, $kValueObj)
    
    Write-Host "`n[TEST] KVSPut with kType='$kType', kKey='$kKey', kFactor='$kFactor'" -ForegroundColor Yellow
    
    try {
        # Use Shared Library KVS.ps1
        # Verbose preference to see library logs
        $VerbosePreference = "Continue" 
        $response = Invoke-GiipKvsPut -Config $Config -Type $kType -Key $kKey -Factor $kFactor -Value $kValueObj
        $VerbosePreference = "SilentlyContinue"

        Write-Host "RES Code: $($response.RstVal)" -ForegroundColor ($response.RstVal -eq 200 ? "Green" : "Red")
        Write-Host "RES Msg : $($response.RstMsg)"
        
        if ($response.RstMsg -eq "No data found") {
            Write-Host " -> CAUSE: SP likely rejected this kType/kKey combination." -ForegroundColor Red
        }
    }
    catch {
        Write-Host "EXCEPTION: $_" -ForegroundColor Red
    }
}

# Case 1: kType = 'lssn' (Standard)
Test-KVSPut -kType "lssn" -kKey $Config.lssn -kFactor "test_lssn_factor" -kValueObj @{ msg = "Hello from lssn type" }

# Case 2: kType = 'database' (Target)
Test-KVSPut -kType "database" -kKey $MdbId -kFactor "test_db_factor" -kValueObj @{ msg = "Hello from db type" }
