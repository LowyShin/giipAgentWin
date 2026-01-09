# ============================================================================
# giipAgentWin Library: Common Functions
# Purpose: Configuration, Logging, and Standard API V2 Interaction
# ============================================================================

#region ====== Logging & Constants ======
$LOG_DIR_REL = '../giipLogs'
$LOG_RETENTION_DAYS = 30

function Write-GiipLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')] [string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # Use -f operator to safely handle special characters in $Message
    $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
    
    # Console Output
    Write-Host $line

    # File Output
    try {
        $LogBase = $Global:BaseDir
        if (-not $LogBase) {
            # Fallback attempt
            if ($PSScriptRoot) { $LogBase = $PSScriptRoot }
            else { 
                $myPath = $MyInvocation.MyCommand.Path
                if ($myPath) { $LogBase = Split-Path -Path $myPath -Parent }
            }
        }
        
        # Final Fallback to current dir
        if (-not $LogBase) { $LogBase = Get-Location }

        $LogDir = Join-Path $LogBase $LOG_DIR_REL
        
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        
        $LogFile = Join-Path $LogDir ("giipAgentWin_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue
    }
    catch {
        # Fallback if logging fails
        # Write-Host "[ERROR] Failed to write log: $_" 
    }
}
#endregion

#region ====== Configuration ======

# ============================================================================
# ⚠️⚠️⚠️ CRITICAL WARNING - DO NOT MODIFY THIS FUNCTION ⚠️⚠️⚠️
# ============================================================================
# This function searches for giipAgent.cfg in SPECIFIC LOCATIONS ONLY.
# 
# ❌ NEVER ADD: Join-Path $BaseDir "giipAgent.cfg"
# ❌ NEVER ADD: Join-Path $PSScriptRoot "giipAgent.cfg"
# ❌ NEVER CHANGE the search order without user approval!
#
# WHY? giipAgentWin/giipAgent.cfg is a SAMPLE file with placeholder values:
#   - lssn = "YOUR_LSSN"  ← This causes varchar→int conversion errors!
#   - sk = "YOUR_KVS_TOKEN"  ← This is not a real token!
#
# REAL config location: Parent directory or %USERPROFILE%
# ============================================================================
function Get-GiipConfig {
    # Priority: 1. Workspace Root (../../giipAgent.cfg)
    #           2. Parent Dir (../giipAgent.cfg)
    #           3. User Profile
    #           4. Current Directory (fallback, but WILL BE FILTERED if it's a sample)
    
    $candidates = @()
    # Workspace Root (if BaseDir is set to giipAgentWin)
    if ($Global:BaseDir) {
        $candidates += (Join-Path $Global:BaseDir "../giipAgent.cfg")
    }
    # User Profile
    $candidates += (Join-Path $env:USERPROFILE "giipAgent.cfg")
    # Current script directory (subfolders)
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot "../giipAgent.cfg")
        $candidates += (Join-Path $PSScriptRoot "giipAgent.cfg")
    }
    # Current working directory
    $candidates += (Join-Path (Get-Location) "giipAgent.cfg")

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            try {
                $config = Parse-ConfigFile -Path $path
                # ⚠️ CRITICAL: Ignore SAMPLE files
                if ($config.lssn -eq "YOUR_LSSN" -or $config.sk -eq "YOUR_KVS_TOKEN") {
                    Write-GiipLog 'WARN' ("Skipping SAMPLE config file at: $path")
                    continue
                }
                
                $fullPath = Resolve-Path $path
                Write-GiipLog 'INFO' ('✅ Valid config loaded from: ' + $fullPath)
                return $config
            }
            catch {
                Write-GiipLog 'WARN' ("Failed to parse config at $path : $_")
            }
        }
    }
    
    throw "Valid giipAgent.cfg not found. Please ensure a real config (not a sample) exists in the parent directory or user profile."
}

function Parse-ConfigFile {
    param([string]$Path)
    $config = @{}
    $lines = Get-Content -LiteralPath $Path
    foreach ($line in $lines) {
        # Regex for 'Key = "Value"' format
        if ($line -match '^\s*(\w+)\s*=\s*"([^"]*)"') {
            $key = $Matches[1]
            $val = $Matches[2]
            $config[$key] = $val
        }
    }
    
    # Minimal Validation
    if (-not $config.ContainsKey('sk')) { throw "Config missing 'sk' (Security Token)." }
    if (-not $config.ContainsKey('lssn')) { throw "Config missing 'lssn' (Logical Server Serial Number)." }
    if (-not $config.ContainsKey('apiaddrv2')) { throw "Config missing 'apiaddrv2' (API Endpoint)." }
    
    return $config
}

function Update-ConfigLssn {
    param([string]$NewLssn)
    # Re-find the config file to update it
    $candidates = @()
    if ($Global:BaseDir) { $candidates += (Join-Path $Global:BaseDir "../giipAgent.cfg") }
    $candidates += (Join-Path $env:USERPROFILE "giipAgent.cfg")
    
    $targetFile = $null
    foreach ($path in $candidates) {
        if (Test-Path $path) { $targetFile = $path; break }
    }

    if ($targetFile) {
        $content = Get-Content $targetFile
        $newContent = $content -replace 'lssn\s*=\s*"\d+"', "lssn = `"$NewLssn`"" -replace "lssn\s*=\s*'\d+'", "lssn = `"$NewLssn`""
        Set-Content -Path $targetFile -Value $newContent -Encoding UTF8
        Write-GiipLog 'INFO' ('Updated LSSN in config file to ' + $NewLssn)
    }
}
#endregion

#region ====== API V2 Standard ======
function Invoke-GiipApiV2 {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$CommandText,
        [Parameter(Mandatory)][string]$JsonData
    )

    # 1. Setup V2 Endpoint
    $Uri = $Config.apiaddrv2
    
    # 2. Setup Payload (Rules: token, text, jsondata)
    # WARNING: Do NOT use 'sk' as parameter name.
    $Body = @{
        token    = $Config.sk
        text     = $CommandText
        jsondata = $JsonData
    }

    # 3. Setup HttpClient (Use Singleton in Main if possible, otherwise Create/Dispose)
    # For robustness in simple calls, Invoke-RestMethod is easier but HttpClient is better for timeouts/keepalive.
    # We will use Invoke-RestMethod for brevity unless advanced control needed.
    # Force TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        # DEBUG: Print Request Details as requested
        Write-Host "----------------[ API DEBUG ]----------------" -ForegroundColor Cyan
        Write-Host "URL : $Uri"
        Write-Host "CMD : $CommandText"
        
        # Limit JSON output to prevent console spam
        if ($JsonData.Length -gt 200) {
            Write-Host "JSON: $($JsonData.Substring(0, 200))... (truncated, $($JsonData.Length) bytes total)"
        }
        else {
            Write-Host "JSON: $JsonData"
        }
        
        Write-Host "---------------------------------------------" -ForegroundColor Cyan

        # ⚠️ FIX: UTF-8 인코딩 명시 (일본어/한국어/중국어 등 모든 문자 지원)
        # PowerShell의 Invoke-RestMethod는 -ContentType에 charset을 명시해야 UTF-8 사용
        # 명시하지 않으면 시스템 기본 인코딩 사용 (CP949, Shift-JIS 등) → "???" 발생
        
        # Invoke-WebRequest 사용 (Invoke-RestMethod보다 인코딩 제어가 명확함)
        $bodyString = @()
        foreach ($key in $Body.Keys) {
            $encodedKey = [System.Uri]::EscapeDataString($key)
            $encodedValue = [System.Uri]::EscapeDataString($Body[$key])
            $bodyString += "$encodedKey=$encodedValue"
        }
        $bodyString = $bodyString -join '&'
        
        # UTF-8 바이트로 변환
        $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyString)
        
        # UTF-8 명시한 헤더
        $headers = @{
            'Content-Type' = 'application/x-www-form-urlencoded; charset=utf-8'
        }
        
        $webResponse = Invoke-WebRequest -Uri $Uri `
            -Method Post `
            -Headers $headers `
            -Body $utf8Bytes `
            -TimeoutSec 30 `
            -UseBasicParsing
        
        # ========== DEBUG: 응답 상세 정보 출력 ==========
        Write-Host "----------------[ API RESPONSE DEBUG ]----------------" -ForegroundColor Magenta
        Write-Host "Status Code    : $($webResponse.StatusCode)" -ForegroundColor Yellow
        Write-Host "Content Type   : $($webResponse.Headers['Content-Type'])" -ForegroundColor Yellow
        Write-Host "Content Length : $($webResponse.Content.Length) bytes" -ForegroundColor Yellow
        
        # 응답 내용 미리보기 (처음 500자)
        $previewLen = [Math]::Min(500, $webResponse.Content.Length)
        Write-Host "Response Preview (first $previewLen chars):" -ForegroundColor Yellow
        Write-Host $webResponse.Content.Substring(0, $previewLen) -ForegroundColor Gray
        Write-Host "------------------------------------------------------" -ForegroundColor Magenta
        
        # JSON 응답 파싱 시도
        try {
            $response = $webResponse.Content | ConvertFrom-Json
            Write-Host "[DEBUG] ✅ JSON Parse SUCCESS" -ForegroundColor Green
            
            # 파싱된 JSON 구조 출력
            if ($response) {
                Write-Host "[DEBUG] Response Type: $($response.GetType().Name)" -ForegroundColor Cyan
                if ($response -is [PSCustomObject]) {
                    $props = $response.PSObject.Properties.Name
                    Write-Host "[DEBUG] Response Properties: $($props -join ', ')" -ForegroundColor Cyan
                }
            }
            
            # ========== FIX: giipApiSk2 응답 구조 자동 언래핑 ==========
            # giipApiSk2는 { "data": [{RstVal, RstMsg}], "debug": {...} } 형식으로 응답
            # 하지만 호출자는 { RstVal, RstMsg } 직접 접근을 기대함
            # → data[0]을 자동으로 추출하여 반환
            
            # ========== ERROR HANDLING: error 속성 체크 ==========
            # API 응답에 error 속성이 있으면 SP 실행 중 에러 발생
            # ========== ERROR HANDLING: error 속성 체크 ==========
            # API 응답에 error 속성이 있으면 SP 실행 중 에러 발생
            # PSCustomObject 속성 확인을 위해 Select-Object 사용 (안전성 확보)
            $hasError = $response | Select-Object -ExpandProperty error -ErrorAction SilentlyContinue
            
            if ($hasError) {
                Write-Host "[DEBUG] ❌ API returned error response (Detected via Select-Object)" -ForegroundColor Red
                try {
                    $errJson = $response.error | ConvertTo-Json -Depth 5 -Compress
                    Write-Host "[DEBUG] Error details: $errJson" -ForegroundColor Red
                    
                    # error 속성을 표준 RstVal/RstMsg 형식으로 변환
                    return @{
                        RstVal = "500"
                        RstMsg = if ($response.error.message) { $response.error.message } else { $errJson }
                    }
                }
                catch {
                    Write-Host "[DEBUG] Failed to serialize error details: $_" -ForegroundColor Red
                    return @{ RstVal = "500"; RstMsg = "Unknown API Error (Serialization Failed)" }
                }
            }
            
            
            if ($response.data -and $response.data -is [Array] -and $response.data.Count -gt 0) {
                # Check if this is a single-record response (has RstVal in data[0])
                # or a multi-record list response
                if ($response.data[0].RstVal) {
                    Write-Host "[DEBUG] 🔧 Unwrapping giipApiSk2 response structure (data[0])" -ForegroundColor Yellow
                    $unwrapped = $response.data[0]
                    Write-Host "[DEBUG] Unwrapped RstVal: $($unwrapped.RstVal)" -ForegroundColor Cyan
                    Write-Host "[DEBUG] Unwrapped RstMsg: $($unwrapped.RstMsg)" -ForegroundColor Cyan
                    return $unwrapped
                }
                else {
                    Write-Host "[DEBUG] 🔧 Returning full data array (list response)" -ForegroundColor Yellow
                    Write-Host "[DEBUG] Array Count: $($response.data.Count)" -ForegroundColor Cyan
                    return @{ data = $response.data }
                }
            }
            
            return $response
        }
        catch {
            # JSON 파싱 실패 - 상세 정보 출력
            Write-Host "[DEBUG] ❌ JSON Parse FAILED" -ForegroundColor Red
            Write-Host "[DEBUG] Parse Error: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "[DEBUG] Full Response Content:" -ForegroundColor Red
            Write-Host $webResponse.Content -ForegroundColor Gray
            
            # 파일로도 저장 (긴 응답 대비)
            try {
                $base = if ($Global:BaseDir) { $Global:BaseDir } else { Split-Path -Parent $PSScriptRoot }
                $logDir = Join-Path $base "../giipLogs/api_errors"
                if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
                
                $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                $errorFile = Join-Path $logDir "api_response_error_$timestamp.txt"
                $webResponse.Content | Out-File -FilePath $errorFile -Encoding utf8
                Write-Host "[DEBUG] Response saved to: $errorFile" -ForegroundColor Yellow
            }
            catch {
                Write-Host "[DEBUG] Failed to save response file: $_" -ForegroundColor Red
            }
            
            $errMsg = ($_.Exception.Message -replace '"', "'" -replace '`', '')
            Write-GiipLog 'ERROR' ('API Call Failed (' + $CommandText + '): ' + $errMsg)
            Write-GiipLog 'ERROR' ('Response Content Length: ' + $webResponse.Content.Length)
            return $null
        }
    }
    catch {
        # HTTP 요청 자체가 실패한 경우
        Write-Host "[DEBUG] ❌ HTTP Request FAILED" -ForegroundColor Red
        Write-Host "[DEBUG] Error Type: $($_.Exception.GetType().Name)" -ForegroundColor Red
        Write-Host "[DEBUG] Error Message: $($_.Exception.Message)" -ForegroundColor Red
        
        $errMsg = ($_.Exception.Message -replace '"', "'" -replace '`', '')
        Write-GiipLog 'ERROR' ('API Call Failed (' + $CommandText + '): ' + $errMsg)
        return $null
    }
}
#endregion

#region ====== System Info ======
function Get-SystemInfo {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return @{
            Hostname = $os.CSName
            OSName   = $os.Caption
        }
    }
    catch {
        return @{
            Hostname = $env:COMPUTERNAME
            OSName   = "Windows (Unknown)"
        }
    }
}
#endregion
