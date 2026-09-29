# ============================================================================
# ErrorLog.ps1 (Restored Pure ASCII Version)
# Purpose: Centralized error logging to Giip API
# ============================================================================

function sendErrorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][object]$Data = $null,
        [Parameter(Mandatory = $false)][ValidateSet('debug', 'info', 'warn', 'error', 'critical')][string]$Severity = 'error'
    )
    
    try {
        $jsonData = $null
        if ($null -ne $Data) {
            # Handle Exception objects
            if ($Data -is [System.Exception]) {
                $Data = @{ Message = $Data.Message; Type = $Data.GetType().FullName; StackTrace = $Data.StackTrace }
            }
            $jsonData = $Data | ConvertTo-Json -Depth 10 -Compress
        }
        
        $payload = @{
            source       = "giipAgent"
            errorMessage = $Message
            severity     = $Severity
            requestData  = $jsonData
        }
        
        if ($Severity -notin @('error', 'critical')) {
            Write-GiipLog "INFO" "[ErrorLog] Local only: $Message"
            return "skipped"
        }

        $logJson = $payload | ConvertTo-Json -Depth 5 -Compress
        $response = Invoke-GiipApiV2 -Config $Config -CommandText "ErrorLogCreate source errorMessage" -JsonData $logJson
        
        if ($response -and $response.RstVal -eq "200") {
            Write-GiipLog "INFO" "[ErrorLog] Server log success (eSn: $($response.eSn))"
            return $response.eSn
        }
        return $null
    } catch {
        Write-GiipLog "ERROR" "[ErrorLog] sendErrorLog failed: $_"
        return $null
    }
}
