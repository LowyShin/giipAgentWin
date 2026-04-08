# ============================================================================
# giipAgentWin Library: Common Functions
# Purpose: Configuration, Logging, and Standard API V2 Interaction
# ============================================================================

#region ====== Logging & Constants ======
$LOG_DIR_REL = '../giipLogs'
$LOG_RETENTION_DAYS = 30

# Helper: Get MD5 hash of a string
function Get-StringMd5 {
    param([string]$InputString)
    if ([string]::IsNullOrWhiteSpace($InputString)) { return "" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash($bytes)
    return "0x" + ($hash | ForEach-Object { $_.ToString("x2") } | Join-String -Separator "")
}

# Helper: Load MySql.Data.dll
function Import-MySqlDll {
    param([string]$LibDir)
    $dllPaths = @(
        Join-Path $LibDir "MySql.Data.dll",
        "C:\Program Files\MySQL\MySQL Connector Net 8.0.33\Assemblies\v4\MySql.Data.dll"
    )
    foreach ($path in $dllPaths) {
        if (Test-Path $path) {
            try { [void][System.Reflection.Assembly]::LoadFrom($path); return $true } catch {}
        }
    }
    return $false
}

function Write-GiipLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')] [string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
    
    # Removed Console Output encoding force to prevent garbage in some terminals
    Write-Host $line

    try {
        $LogBase = if ($Global:BaseDir) { $Global:BaseDir } else { $PSScriptRoot }
        if (-not $LogBase) { $LogBase = Get-Location }
        $LogDir = Join-Path $LogBase $LOG_DIR_REL
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $LogFile = Join-Path $LogDir ("giipAgentWin_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        
        # Log append - Let system decide encoding for best terminal compatibility
        Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue
    } catch {}
}
#endregion

#region ====== Configuration ======
function Get-GiipConfig {
    $candidates = @()
    if ($Global:BaseDir) { $candidates += (Join-Path $Global:BaseDir "../giipAgent.cfg") }
    $candidates += (Join-Path $env:USERPROFILE "giipAgent.cfg")
    if ($PSScriptRoot) { 
        $candidates += (Join-Path $PSScriptRoot "../giipAgent.cfg")
        $candidates += (Join-Path $PSScriptRoot "giipAgent.cfg")
    }
    $candidates += (Join-Path (Get-Location) "giipAgent.cfg")

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            try {
                $config = Parse-ConfigFile -Path $path
                if ($config.lssn -eq "YOUR_LSSN" -or $config.sk -eq "YOUR_KVS_TOKEN") { continue }
                return $config
            } catch {}
        }
    }
    throw "Valid giipAgent.cfg not found."
}

function Parse-ConfigFile {
    param([string]$Path)
    $config = @{}
    # Load with default encoding to match typical user-edited files
    $lines = Get-Content -LiteralPath $Path
    foreach ($line in $lines) {
        if ($line -match '^\s*(\w+)\s*=\s*"([^"]*)"') {
            $config[$Matches[1]] = $Matches[2]
        }
    }
    if (-not $config.ContainsKey('sk')) { throw "Config missing 'sk'." }
    return $config
}
#endregion

#region ====== API V2 Standard ======
function Invoke-GiipApiV2 {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$CommandText,
        [Parameter(Mandatory)][string]$JsonData
    )
    $Uri = $Config.apiaddrv2
    $Body = @{ token = $Config.sk; text = $CommandText; jsondata = $JsonData }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $bodyString = @()
        foreach ($key in $Body.Keys) {
            $bodyString += "$([System.Uri]::EscapeDataString($key))=$([System.Uri]::EscapeDataString($Body[$key]))"
        }
        $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyString -join '&'))
        $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded; charset=utf-8' }
        
        $webResponse = Invoke-WebRequest -Uri $Uri -Method Post -Headers $headers -Body $utf8Bytes -TimeoutSec 30 -UseBasicParsing
        $response = $webResponse.Content | ConvertFrom-Json
        
        if ($response.data -and $response.data.Count -gt 0) {
            return $response.data[0]
        }
        return $response
    } catch {
        return $null
    }
}
#endregion
