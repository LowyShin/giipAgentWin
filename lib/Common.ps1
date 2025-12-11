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
    $line = "[$ts] [$Level] $Message"
    
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
        $candidates += (Join-Path $Global:BaseDir "giipAgent.cfg")
    }
    $candidates += (Join-Path $env:USERPROFILE "giipAgent.cfg")

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            # Try to resolve to absolute path for clarity
            $fullPath = Resolve-Path $path
            Write-GiipLog "INFO" "Loading config from: $fullPath"
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
        Write-GiipLog "INFO" "Updated LSSN in config file to $NewLssn"
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

        $response = Invoke-RestMethod -Uri $Uri -Method Post -Body $Body -TimeoutSec 30
        return $response
    }
    catch {
        Write-GiipLog "ERROR" "API Call Failed ($CommandText): $($_.Exception.Message)"
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
