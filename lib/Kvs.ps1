# ============================================================================
# KVS.ps1
# Purpose: Common library for Key-Value Store (KVS) operations
# Usage: . (Join-Path $LibDir "KVS.ps1")
# Dependencies: Common.ps1 (for Invoke-GiipApiV2)
# ============================================================================

function Invoke-GiipKvsPut {
    <#
    .SYNOPSIS
        Saves a Key-Value pair to the Giip KVS via API.
    
    .DESCRIPTION
        Constructs the standard KVS payload (Text + JsonData) and calls Invoke-GiipApiV2.
        Follows the Linux Agent's 'kvs.sh' standard:
        - Text: "KVSPut kType kKey kFactor"
        - JsonData: { kType, kKey, kFactor, kValue (Raw/Object) }
        
    .PARAMETER Config
        The Agent configuration object (HashTable).
        
    .PARAMETER Type
        The kType (e.g., 'lssn', 'database').
        
    .PARAMETER Key
        The kKey (e.g., LSSN, MdbId).
        
    .PARAMETER Factor
        The kFactor (e.g., 'db_connections').
        
    .PARAMETER Value
        The value to store. Can be a String, Hashtable, or Array.
        If it's an object, it will be embedded as a JSON object in the 'kValue' field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$Type,
        
        [Parameter(Mandatory = $true)]
        [string]$Key,
        
        [Parameter(Mandatory = $true)]
        [string]$Factor,
        
        [Parameter(Mandatory = $true)]
        [object]$Value
    )
    
    # Construct Payload
    # Linux standard: kValue contains the raw data (object or string)
    # We assign the object directly so ConvertTo-Json handles nested serialization properly.
    $payload = @{
        kType   = $Type
        kKey    = $Key
        kFactor = $Factor
        kValue  = $Value 
    }
    
    # Convert to JSON
    # Depth 10 to ensure complex objects are fully serialized
    $jsonPayload = $payload | ConvertTo-Json -Compress -Depth 10
    
    # [Log to File] Save JSON payload for debugging/history
    try {
        $base = if ($Global:BaseDir) { $Global:BaseDir } else { Split-Path -Parent $PSScriptRoot }
        # Consistent with Common.ps1 structure (Sibling directory)
        $logBaseDir = Join-Path $base "../giipLogs"
        $payloadLogDir = Join-Path $logBaseDir "payloads"
        
        if (-not (Test-Path $payloadLogDir)) { New-Item -Path $payloadLogDir -ItemType Directory -Force | Out-Null }
        
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
        # Sanitize Key for filename (remove invalid chars)
        $safeKey = $Key -replace '[\\/:*?"<>|]', '_'
        $fileName = "KVSPut_${Type}_${safeKey}_${timestamp}.json"
        $filePath = Join-Path $payloadLogDir $fileName
        
        $jsonPayload | Out-File -FilePath $filePath -Encoding utf8
        Write-Verbose "[KVS] Payload saved to: $filePath"
    }
    catch {
        Write-Verbose "[KVS] Failed to save payload file: $_"
    }
    
    # Standard Command Text
    $cmdText = "KVSPut kType kKey kFactor"
    
    # Debug Log (Verbose)
    Write-Verbose "[KVS] Putting $Type / $Key / $Factor"
    
    # Call API
    # Assumes Invoke-GiipApiV2 is available (from Common.ps1)
    $response = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $jsonPayload
    
    return $response
}

Export-ModuleMember -Function Invoke-GiipKvsPut
