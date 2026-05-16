# ============================================================================
# giipAgent Common Library (PowerShell)
# Version: 1.09
# Purpose: Shared utilities, Configuration, and API communication
# ============================================================================

$ErrorActionPreference = "Stop"

# Function: Log to local file and console
function Write-GiipLog {
    param(
        [string]$Level,
        [string]$Message
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] [$Level] $Message"
    Write-Host $LogLine
}

# Function: Load giipAgent Configuration
function Get-GiipConfig {
    param([string]$SearchBase)
    
    $base = if ($SearchBase) { $SearchBase } elseif ($Global:BaseDir) { $Global:BaseDir } else { $PSScriptRoot }
    $config = @{}
    $configPath = $null
    
    # Priority 1: Parent directory
    $parent = Split-Path -Path $base -Parent
    if ($parent -and (Test-Path (Join-Path $parent "giipAgent.cfg"))) {
        $candidate = Join-Path $parent "giipAgent.cfg"
        $head = Get-Content $candidate -TotalCount 10 -ErrorAction SilentlyContinue
        if ($head -notmatch "SAMPLE") { $configPath = $candidate }
    }
    
    # Priority 2: User Profile
    if (-not $configPath) {
        $userPath = Join-Path $env:USERPROFILE "giipAgent.cfg"
        if (Test-Path $userPath) {
            $head = Get-Content $userPath -TotalCount 10 -ErrorAction SilentlyContinue
            if ($head -notmatch "SAMPLE") { $configPath = $userPath }
        }
    }
    
    # Priority 3: Local Repository (Last Resort)
    if (-not $configPath) {
        $localPath = Join-Path $base "giipAgent.cfg"
        if (Test-Path $localPath) {
            $configPath = $localPath
        }
    }
    
    if ($configPath) {
        $raw = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $raw -split "`r?`n" | ForEach-Object {
                if ($_ -match '^\s*([^=:#\s\[]+)\s*[:=]\s*(.*)$') {
                    $k = $Matches[1].Trim().ToLower()
                    $v = $Matches[2].Trim()
                    # Strip surrounding quotes if present
                    if ($v -match '^["''](.*)["'']$') { $v = $Matches[1] }
                    $config[$k] = $v
                }
            }
        }
    }
    
    return $config
}

# Function: Import MySQL Connector DLL
function Import-MySqlDll {
    param([string]$LibDir)
    $DllPath = Join-Path $LibDir "MySql.Data.dll"
    if (Test-Path $DllPath) {
        Add-Type -Path $DllPath
        return $true
    }
    return $false
}

# Function: Invoke GIIP API V2 (Main Communication)
function Invoke-GiipApiV2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$CommandText,
        [Parameter(Mandatory)][string]$JsonData
    )
    $effectiveToken = if ($Global:GiipSessionAK) { $Global:GiipSessionAK } else { $Config.sk }
    
    $Uri = $Config.apiaddrv2
    if (-not $Uri) {
        Write-GiipLog "ERROR" "API Address (apiaddrv2) missing in configuration."
        return $null
    }

    $Body = @{ token = $effectiveToken; text = $CommandText; jsondata = $JsonData }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $bodyString = @()
        foreach ($key in $Body.Keys) {
            $bodyString += "$([System.Uri]::EscapeDataString($key))=$([System.Uri]::EscapeDataString($Body[$key]))"
        }
        $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyString -join '&'))
        $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded; charset=utf-8' }
        
        $webResponse = Invoke-WebRequest -Uri $Uri -Method Post -Headers $headers -Body $utf8Bytes -TimeoutSec 30 -UseBasicParsing
        $responseJson = $webResponse.Content
        $response = $null
        
        try {
            $response = $responseJson | ConvertFrom-Json
        } catch {
            Write-GiipLog "WARN" "API Response JSON parsing failed. Attempting dirty parse."
            # Fallback: Try to extract RstVal and RstMsg using regex if JSON is malformed
            $rstVal = if ($responseJson -match '"RstVal"\s*:\s*(\d+)') { $Matches[1] } else { "500" }
            $rstMsg = if ($responseJson -match '"RstMsg"\s*:\s*"([^"]+)"') { $Matches[1] } else { "Unknown JSON Error" }
            $response = @{ RstVal = $rstVal; RstMsg = $rstMsg; isDirty = $true }
            
            # If it's a 200, we can treat it as success even if JSON was ugly
            if ($rstVal -eq "200") {
                Write-GiipLog "INFO" "Dirty parse succeeded: Operation was successful (200)."
            } else {
                Write-GiipLog "DEBUG" "Dirty parse result: $rstVal - $rstMsg"
            }
        }
        
        if ($response.ak) { $Global:GiipSessionAK = $response.ak }
        
        # Debug: Log non-success responses
        if ($response.RstVal -and $response.RstVal -ne "200") {
            $rawJson = $webResponse.Content
            Write-GiipLog "DEBUG" "API Non-Success Response ($($response.RstVal)): $rawJson"
        }
        
        if ($response.data -and $response.data.Count -gt 0) { return $response.data[0] }
        return $response
    } catch {
        Write-GiipLog "DEBUG" "API Call Failed: $_"
        return $null
    }
}
