
# ============================================================================
# giipAgent KVS Logging Library (PowerShell)
# Version: 2.00
# Date: 2025-01-10
# Purpose: KVS (Key-Value Store) logging functions for execution tracking
# Rule: Follow giipapi_rules.md - text contains parameter names, jsondata contains actual values
# ============================================================================

# Load Common.ps1 if not already loaded (defensive)
if (-not (Get-Command Invoke-GiipApiV2 -ErrorAction SilentlyContinue)) {
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $commonPath = Join-Path $scriptDir "Common.ps1"
    if (Test-Path $commonPath) { . $commonPath }
}

# Function: Save execution log to KVS (giipagent factor)
# Event types: startup, queue_check, script_execution, error, shutdown, gateway_init, heartbeat
function Save-ExecutionLog {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)]$DetailsObj # Hashtable or Object or JSON String
    )

    $lssn = $Config.lssn
    if (-not $lssn) { Write-GiipLog "ERROR" "[KVS] Missing LSSN"; return }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $hostname = [System.Net.Dns]::GetHostName()
    
    # Determine mode
    $mode = "normal"
    if ($Config.is_gateway -eq "1" -or $Config.is_gateway -eq $true) { $mode = "gateway" }

    # Ensure details is valid JSON
    $detailsJson = if ($DetailsObj -is [string]) { 
        # Verify if string is JSON, if not treat as text value?
        # Linux version: "details_json embedded as raw data"
        # If it's a string that implies JSON, use it. If plain text, wrap it?
        # Linux kvs.sh says: "details_json이 JSON이면 JSON으로, 텍스트면 텍스트로 그대로 저장됨"
        $DetailsObj 
    }
    else { 
        $DetailsObj | ConvertTo-Json -Depth 10 -Compress 
    }

    # Build kValue Object
    # We construct a hashtable effectively validation the JSON structure
    $kValueObj = @{
        event_type = $EventType
        timestamp  = $timestamp
        lssn       = $lssn
        hostname   = $hostname
        mode       = $mode
        version    = "3.00" # Consistent with Linux V3
        details    = $DetailsObj # If this is an object, ConvertTo-Json will handle it. If string, likely treated as string.
        # However, to be raw data as-is, we should let ConvertTo-Json handle the outer wrapping.
        # But Linux constructs JSON string manually.
    }
    
    # In PowerShell, nested objects need care when double-encoding.
    # We want: kValue: { "event_type":..., "details": <RAW_DATA> }
    # If <RAW_DATA> is a JSON string, it becomes a string value in JSON? No, Linux kvs.sh treats it as raw object if possible.
    # Line 87 kvs.sh: \"details\":${details_json}
    # This implies details_json is inserted DIRECTLY into the JSON structure, not as a string.
    # So if details_json is {"a":1}, kValue is {..., "details":{"a":1}}.
    
    # So if $DetailsObj is a JSON string, we should ConvertFrom-Json it first to nest it properly as an object,
    # OR construct the JSON manually string-manipulation style.
    # To be safe and cleaner in PS, let's treat $DetailsObj as an Object.
    
    $kValueJson = $kValueObj | ConvertTo-Json -Depth 10 -Compress

    # Call Send-KVSPut
    # kFactor for Save-ExecutionLog is 'giipagent' (Line 102 kvs.sh)
    Send-KVSPut -Config $Config -kType "lssn" -kKey $lssn -kFactor "giipagent" -kValue $kValueObj
}


# Function: Save simple KVS key-value pair
# Usage: Send-KVSPut -Config $Cfg -kType "lssn" -kKey "123" -kFactor "test" -kValue @{status="ok"}
function Send-KVSPut {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$kType,
        [Parameter(Mandatory)][string]$kKey,
        [Parameter(Mandatory)][string]$kFactor,
        [Parameter(Mandatory)]$kValue # Object or Hashtable (will be converted to JSON)
    )

    # 1. Prepare Command Text
    $text = "KVSPut kType kKey kFactor"

    # 2. Prepare JSON Data
    # structure: { kType, kKey, kFactor, kValue (Raw) }
    
    $jsonDataObj = @{
        kType   = $kType
        kKey    = $kKey
        kFactor = $kFactor
        kValue  = $kValue
    }
    
    $jsonDataString = $jsonDataObj | ConvertTo-Json -Depth 10 -Compress
    
    # 3. Invoke API
    $response = Invoke-GiipApiV2 -Config $Config -CommandText $text -JsonData $jsonDataString
    
    if ($response) {
        Write-GiipLog "DEBUG" "KVS Saved: $kFactor (Key: $kKey)"
    }
    else {
        Write-GiipLog "ERROR" "KVS Failed: $kFactor (Key: $kKey)"
    }
}
