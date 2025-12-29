# ============================================================================
# giipAgentWin Library: Debug/Error Logging to Central DB
# Purpose: Reusable function for sending debug/error logs via ErrorLogCreate API
# ============================================================================

function Send-GiipDebugLog {
    <#
    .SYNOPSIS
    Send debug or error log to central DB (tErrorLog) via ErrorLogCreate API.
    
    .DESCRIPTION
    This function sends log data to the central error logging system.
    Use this for debugging purposes to track data flow and errors.
    
    .PARAMETER Config
    Configuration hashtable (must contain 'lssn' and API settings)
    
    .PARAMETER Message
    Log message describing the event
    
    .PARAMETER RequestData
    Optional request data (JSON string or object) to include in the log
    
    .PARAMETER Severity
    Log severity level: "debug", "info", "warn", "error" (default: "debug")
    
    .EXAMPLE
    Send-GiipDebugLog -Config $Config -Message "Uploading user list" -RequestData $jsonPayload
    
    .EXAMPLE
    Send-GiipDebugLog -Config $Config -Message "Upload failed" -Severity "error" -RequestData $errorDetails
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [string]$RequestData = $null,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("debug", "info", "warn", "error")]
        [string]$Severity = "debug"
    )
    
    try {
        $logData = @{
            source       = if ($Severity -eq "debug") { "giipAgent-Debug" } else { "giipAgent" }
            errorMessage = $Message
            severity     = $Severity
            lssn         = $Config.lssn
        }
        
        if ($RequestData) {
            $logData.requestData = $RequestData
        }
        
        $logJson = $logData | ConvertTo-Json -Compress -Depth 5
        
        # Call ErrorLogCreate API
        $response = Invoke-GiipApiV2 -Config $Config -CommandText "ErrorLogCreate source errorMessage" -JsonData $logJson
        
        # Debug: Show full response
        Write-Host "[DEBUG] Full API Response:" -ForegroundColor Magenta
        Write-Host ($response | ConvertTo-Json -Depth 3) -ForegroundColor Gray
        
        # Validate response
        if (-not $response) {
            throw "API returned null response"
        }
        
        $rstVal = $response.RstVal
        if ($rstVal -ne "200") {
            $rstMsg = if ($response.RstMsg) { $response.RstMsg } else { "Unknown error" }
            throw "API error: $rstMsg (RstVal: $rstVal)"
        }
        
        # Return eSn if available
        return $response.eSn
        
    }
    catch {
        # Re-throw for caller to handle
        if (Get-Command Write-GiipLog -ErrorAction SilentlyContinue) {
            Write-GiipLog "ERROR" "Failed to send debug log: $($_.Exception.Message)"
        }
        throw
    }
}
