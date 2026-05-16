# ============================================================================
# KVS.ps1 (Restored Pure ASCII Version)
# Purpose: Common library for Key-Value Store (KVS) operations
# ============================================================================

function Invoke-GiipKvsPut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Factor,
        [Parameter(Mandatory = $true)][object]$Value
    )
    
    # Construct Payload (Linux standard compatible)
    $payload = @{
        kType   = $Type
        kKey    = $Key
        kFactor = $Factor
        kValue  = $Value 
    }
    
    $jsonPayload = $payload | ConvertTo-Json -Compress -Depth 10
    
    # Save Payload Log for debugging (ASCII safe)
    try {
        $base = if ($Global:BaseDir) { $Global:BaseDir } else { Get-Location }
        $logBaseDir = Join-Path $base "../giipLogs"
        $payloadLogDir = Join-Path $logBaseDir "payloads"
        if (-not (Test-Path $payloadLogDir)) { New-Item -Path $payloadLogDir -ItemType Directory -Force | Out-Null }
        
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
        $safeKey = $Key -replace '[\\/:*?"<>|]', '_'
        $filePath = Join-Path $payloadLogDir "KVSPut_${Type}_${safeKey}_${timestamp}.json"
        
        $jsonPayload | Set-Content -Path $filePath -Encoding ASCII
    } catch {}

    # Standard Command Text
    $cmdText = "KVSPut kType kKey kFactor"
    
    # Call API (Assumes Common.ps1 is loaded)
    $response = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $jsonPayload
    return $response
}
