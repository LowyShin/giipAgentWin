# ============================================================================
# giipAgentWin Library: Common Functions (Ultra-Robust UTF8 Version)
# Purpose: Configuration, Logging, and Resilient API V2 Interaction
# ============================================================================

#region ====== Logging & Constants ======
$LOG_DIR_REL = '../giipLogs'

function Write-GiipLog {
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
    Write-Host $line
    try {
        $LogBase = if ($Global:BaseDir) { $Global:BaseDir } else { Get-Location }
        $LogDir = Join-Path $LogBase $LOG_DIR_REL
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $LogFile = Join-Path $LogDir ("giipAgentWin_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
}

function Get-StringMd5 {
    param([string]$InputString)
    if ([string]::IsNullOrWhiteSpace($InputString)) { return "" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash($bytes)
    return "0x" + ($hash | ForEach-Object { $_.ToString("x2") } | Join-String -Separator "")
}
#endregion

#region ====== Configuration ======
function Get-GiipConfig {
    $candidates = @()
    if ($Global:BaseDir) { $candidates += (Join-Path $Global:BaseDir "../giipAgent.cfg") }
    $candidates += (Join-Path $env:USERPROFILE "giipAgent.cfg")
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            $config = @{}
            $lines = Get-Content -LiteralPath $path -Encoding utf8
            foreach ($line in $lines) {
                if ($line -match '^\s*(\w+)\s*=\s*"([^"]*)"') { $config[$Matches[1]] = $Matches[2] }
            }
            if ($config.sk -and $config.lssn) { return $config }
        }
    }
    throw "Config not found."
}
#endregion

#region ====== API V2 Standard ======
function Invoke-GiipApiV2 {
    param($Config, $CommandText, $JsonData)
    $Uri = $Config.apiaddrv2
    $Body = @{ token = $Config.sk; text = $CommandText; jsondata = $JsonData }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $bodyString = @()
        foreach ($key in $Body.Keys) { $bodyString += "$([System.Uri]::EscapeDataString($key))=$([System.Uri]::EscapeDataString($Body[$key]))" }
        $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyString -join '&'))
        $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded; charset=utf-8' }
        $webResponse = Invoke-WebRequest -Uri $Uri -Method Post -Headers $headers -Body $utf8Bytes -TimeoutSec 30 -UseBasicParsing
        $rawContent = $webResponse.Content
        
        # [ULTRA-ROBUST] Handle JSON parsing with fallback to RegEx for RstVal if parsing fails
        try {
            # Try parsing the whole response
            $response = $rawContent | ConvertFrom-Json
            if ($response.data -and $response.data.Count -gt 0) { return $response.data[0] }
            return $response
        } catch {
            # EMERGENCY: If server returns invalid JSON (e.g. escape sequence error in debug info),
            # manually extract RstVal and RstMsg using RegEx.
            $rstVal = "500"
            $rstMsg = "JSON Parsing Failed"
            if ($rawContent -match '"RstVal"\s*:\s*(\d+)') { $rstVal = $Matches[1] }
            if ($rawContent -match '"RstMsg"\s*:\s*"([^"]+)"') { $rstMsg = $Matches[1] }
            
            return @{ RstVal = $rstVal; RstMsg = "[RegEx Recovery] $rstMsg" }
        }
    } catch {
        return @{ RstVal = "500"; RstMsg = "[Invoke] Connection Exception: $($_.Exception.Message)" }
    }
}
#endregion
