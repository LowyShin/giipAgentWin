# sendErrorLog.ps1
# Purpose: Windows Agent     
# Author: AI Agent
# Date: 2025-12-29
#
# Usage:
#   Import-Module .\lib\ErrorLog.ps1
#   sendErrorLog -Config $Config -Message "Upload failed" -Data $errorData -Severity "error"
#
# References:
#   - API : giipdb/docs/ERROR_LOG_API_SPECIFICATION.md
#   - JSON : giipdb/docs/ERRORLOG_JSON_PARSE_STANDARD.md

function sendErrorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [object]$Data = $null,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('debug', 'info', 'warn', 'error', 'critical')]
        [string]$Severity = 'error',
        
        [Parameter(Mandatory = $false)]
        [string]$ErrorType = $null
    )
    
    try {
        # JSON   (3 fallback)
        $jsonData = $null
        $isValidJson = $false
        
        if ($null -ne $Data) {
            try {
                # [V] Exception     
                if ($Data -is [System.Exception]) {
                    $Data = @{
                        Message        = $Data.Message
                        StackTrace     = $Data.StackTrace
                        Type           = $Data.GetType().FullName
                        InnerException = if ($Data.InnerException) { $Data.InnerException.Message } else { $null }
                    }
                }

                # Step 1: ConvertTo-Json 
                $jsonData = $Data | ConvertTo-Json -Depth 10 -Compress
                
                # JSON   ( )
                if ($jsonData.StartsWith('{') -or $jsonData.StartsWith('[')) {
                    $isValidJson = $true
                }
            }
            catch {
                Write-GiipLog "WARN" "JSON conversion failed: $_"
                
                # Step 2: ToString() 
                try {
                    $jsonData = $Data.ToString()
                }
                catch {
                    # Step 3:   
                    $jsonData = [string]$Data
                }
                $isValidJson = $false
            }
        }
        
        #    
        $payload = @{
            source       = "giipAgent"
            errorMessage = $Message
            severity     = $Severity
        }
        
        if ($ErrorType) {
            $payload.errorType = $ErrorType
        }
        
        # JSON  requestData,   RawData 
        if ($isValidJson) {
            $payload.requestData = $jsonData
        }
        else {
            # JSON     ( elRawData )
            $payload.requestData = $jsonData
            if (-not $ErrorType) {
                $payload.errorType = "DataSerializationError"
            }
        }
        
        # [V]   : error  critical   API  
        #   DB     .
        if ($Severity -notin @('error', 'critical')) {
            Write-GiipLog "INFO" "Logging skipped for severity '$Severity' (Local only): $Message"
            return "skipped"
        }

        # API 
        $logJson = $payload | ConvertTo-Json -Depth 5 -Compress
        # [V] API  (giipapi_rules.md L27  )
        $response = Invoke-GiipApiV2 -Config $Config `
            -CommandText "ErrorLogCreate source errorMessage" `
            -JsonData $logJson
        
        #  
        if (-not $response) {
            Write-GiipLog "ERROR" "ErrorLog API returned null response"
            return $null
        }

        # [DEBUG] Response Type Check
        # Write-GiipLog "DEBUG" "Response Type: $($response.GetType().FullName)"
        
        # Validate response structure (Structural Fix for wrapped responses)
        # Handle cases where data is wrapped in 'data' property (Array or Object)
        if ($response.PSObject.Properties['data']) {
            $responseData = $response.data
            if ($responseData -is [Array] -and $responseData.Count -gt 0) {
                $response = $responseData[0]
            }
            elseif ($responseData -isnot [Array] -and $responseData) {
                $response = $responseData
            }
        }

        $rstVal = $response.RstVal
        
        # [DEBUG] Check RstVal extraction
        # Write-GiipLog "DEBUG" "Extracted RstVal: '$rstVal'"

        if ($rstVal -ne "200" -and $rstVal -ne 200) {
            $rstMsg = if ($response.RstMsg) { $response.RstMsg } else { "Unknown error" }
            Write-GiipLog "ERROR" "ErrorLog API failed: $rstMsg (RstVal: $rstVal)"
            return $null
        }
        
        Write-GiipLog "INFO" "Error logged successfully (eSn: $($response.eSn))"
        return $response.eSn
    }
    catch {
        #       
        Write-GiipLog "ERROR" "Send-GiipErrorLog failed: $_"
        return $null
    }
}



