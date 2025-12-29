
# Simulate the API response structure observed in the user's debug log
$mockResponse = [PSCustomObject]@{
    data  = @(
        [PSCustomObject]@{
            RstVal   = "200"
            source   = "giipAgent-Debug"
            RstMsg   = "Error log created successfully"
            eSn      = 3424
            severity = "error"
        }
    )
    debug = @{
        _debug_spName = "ErrorLogCreate"
    }
}

Write-Host "Original Response:"
$mockResponse | ConvertTo-Json -Depth 5

# --- The Logic Implemented in ErrorLog.ps1 ---
$response = $mockResponse

if ($response.PSObject.Properties['data']) {
    $responseData = $response.data
    if ($responseData -is [Array] -and $responseData.Count -gt 0) {
        Write-Host "DEBUG: Detected 'data' Array, extracting first element..."
        $response = $responseData[0]
    }
    elseif ($responseData -isnot [Array] -and $responseData) {
        Write-Host "DEBUG: Detected 'data' Object, using it..."
        $response = $responseData
    }
}

$rstVal = $response.RstVal
# ---------------------------------------------

Write-Host "`nExtracted RstVal: '$rstVal'"

if ($rstVal -eq "200") {
    Write-Host "✅ SUCCESS: RstVal correctly extracted from wrapped response." -ForegroundColor Green
}
else {
    Write-Host "❌ FAILED: RstVal was not extracted. (Got: '$rstVal')" -ForegroundColor Red
}
