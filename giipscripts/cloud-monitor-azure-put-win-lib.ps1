# cloud-monitor-azure-put-win-lib.ps1
# Helper functions for cloud-monitor-azure-put-win.ps1
# These functions bypass EscapeDataString's internal buffer limitation for large JSON payloads
# by chunking the encoding itself, allowing a single CloudResourceBatchUpsert call.

function ConvertTo-SafeUrlEncoded {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return "" }
    $chunkSize = 8000
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Value.Length; $i += $chunkSize) {
        $len = [Math]::Min($chunkSize, $Value.Length - $i)
        [void]$sb.Append([System.Uri]::EscapeDataString($Value.Substring($i, $len)))
    }
    return $sb.ToString()
}

function Invoke-GiipApiV2Large {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$CommandText,
        [Parameter(Mandatory)][string]$JsonData
    )
    $effectiveToken = if ($Global:GiipSessionAK) { $Global:GiipSessionAK } else { $Config.sk }
    $Uri = $Config.apiaddrv2
    if (-not $Uri) { Write-GiipLog "ERROR" "apiaddrv2 missing"; return $null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $bodyString = "token=" + (ConvertTo-SafeUrlEncoded $effectiveToken) +
                  "&text="  + (ConvertTo-SafeUrlEncoded $CommandText) +
                  "&jsondata=" + (ConvertTo-SafeUrlEncoded $JsonData)
    $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyString)
    $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded; charset=utf-8' }
    try {
        $webResponse = Invoke-WebRequest -Uri $Uri -Method Post -Headers $headers -Body $utf8Bytes -TimeoutSec 60 -UseBasicParsing
        $response = $webResponse.Content | ConvertFrom-Json
        if ($response.ak) { $Global:GiipSessionAK = $response.ak }
        if ($response.data -and $response.data.Count -gt 0) { return $response.data[0] }
        return $response
    } catch {
        Write-GiipLog "DEBUG" "Invoke-GiipApiV2Large failed: $_"
        return $null
    }
}
