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
$ScriptPath = $MyInvocation.MyCommand.Path
# Ensure absolute path even if executed relatively (e.g., .\test\script.ps1)
if (-not [System.IO.Path]::IsPathRooted($ScriptPath)) {
    $ScriptPath = Join-Path (Get-Location) $ScriptPath
}
$ScriptDir = Split-Path -Path $ScriptPath -Parent

# Determine AgentRoot (Handle running from test dir or agent root)
if ((Split-Path -Path $ScriptDir -Leaf) -eq "test") {
    $AgentRoot = Split-Path -Path $ScriptDir -Parent
}
else {
    $AgentRoot = $ScriptDir
}

$LibDir = Join-Path $AgentRoot "lib"
$Global:BaseDir = $AgentRoot

Write-Host "DEBUG: LibDir=$LibDir" -ForegroundColor DarkGray

# Load Libraries
try { 
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "KVS.ps1")
}
catch { 
    Write-Error "Failed to load libraries: $_"
    exit 1 
}

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

        # Handle Array Response (API V2 often returns wrapped array)
        if ($response -is [Array]) { $resObj = $response[0] } else { $resObj = $response }

        if ($resObj.RstVal -eq 200) { $color = "Green" } else { $color = "Red" }
        Write-Host "RES Code: $($resObj.RstVal)" -ForegroundColor $color
        Write-Host "RES Msg : $($resObj.RstMsg)"
        
        if ($resObj.RstMsg -eq "No data found") {
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
