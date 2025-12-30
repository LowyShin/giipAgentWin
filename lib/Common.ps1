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
function Get-GiipConfig {
    # Priority: 1. Parent Dir (../giipAgent.cfg) represented by $Global:BaseDir/../
    #           2. User Profile
    
    $candidates = @()
    if ($Global:BaseDir) {
        $candidates += (Join-Path $Global:BaseDir "../giipAgent.cfg")
    }
    $candidates += (Join-Path $env:USERPROFILE "giipAgent.cfg")

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            # Try to resolve to absolute path for clarity
            $fullPath = Resolve-Path $path
            Write-GiipLog 'INFO' ('Loading config from: ' + $fullPath)
            return (Parse-ConfigFile -Path $path)
        }
    }
    
    throw "giipAgent.cfg not found in search paths."
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
        Write-Host "JSON: $JsonData"
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
