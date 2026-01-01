# sendErrorLog.ps1
# Purpose: Windows Agent용 에러 로그 전송 표준 함수
# Author: AI Agent
# Date: 2025-12-29
#
# Usage:
#   Import-Module .\lib\ErrorLog.ps1
#   sendErrorLog -Config $Config -Message "Upload failed" -Data $errorData -Severity "error"
#
# References:
#   - API 사양: giipdb/docs/ERROR_LOG_API_SPECIFICATION.md
#   - JSON 표준: giipdb/docs/ERRORLOG_JSON_PARSE_STANDARD.md

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
        # JSON 변환 시도 (3단계 fallback)
        $jsonData = $null
        $isValidJson = $false
        
        if ($null -ne $Data) {
            try {
                # Step 1: ConvertTo-Json 시도
                $jsonData = $Data | ConvertTo-Json -Depth 10 -Compress
                
                # JSON 유효성 검증 (간단한 체크)
                if ($jsonData.StartsWith('{') -or $jsonData.StartsWith('[')) {
                    $isValidJson = $true
                }
            }
            catch {
                Write-GiipLog "WARN" "JSON conversion failed: $_"
                
                # Step 2: ToString() 시도
                try {
                    $jsonData = $Data.ToString()
                }
                catch {
                    # Step 3: 강제 문자열 변환
                    $jsonData = [string]$Data
                }
                $isValidJson = $false
            }
        }
        
        # 에러 로그 페이로드 생성
        $payload = @{
            source       = "giipAgent"
            errorMessage = $Message
            severity     = $Severity
        }
        
        if ($ErrorType) {
            $payload.errorType = $ErrorType
        }
        
        # JSON이 유효하면 requestData에, 아니면 서버가 RawData로 처리
        if ($isValidJson) {
            $payload.requestData = $jsonData
        }
        else {
            # JSON 파싱 실패 시에도 전송 (서버가 elRawData에 저장)
            $payload.requestData = $jsonData
            if (-not $ErrorType) {
                $payload.errorType = "DataSerializationError"
            }
        }
        
        # [V] 로그 레벨 필터링: error 또는 critical인 경우에만 실제 API 호출 수행
        # 디버그성 내용이 DB 에러로그 테이블을 오염시키는 것을 방지합니다.
        if ($Severity -notin @('error', 'critical')) {
            Write-GiipLog "INFO" "Logging skipped for severity '$Severity' (Local only): $Message"
            return "skipped"
        }

        # API 호출
        $logJson = $payload | ConvertTo-Json -Depth 5 -Compress
        # [V] API 호출 (giipapi_rules.md L27 표준 준수)
        $response = Invoke-GiipApiV2 -Config $Config `
            -CommandText "ErrorLogCreate source errorMessage" `
            -JsonData $logJson
        
        # 응답 검증
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
        # 에러 로깅 자체가 실패해도 스크립트는 계속 진행
        Write-GiipLog "ERROR" "Send-GiipErrorLog failed: $_"
        return $null
    }
}


