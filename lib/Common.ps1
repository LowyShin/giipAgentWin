# ============================================================================
# giipAgent Common Library (PowerShell)
# Version: 1.08
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
    
    # Use Global:BaseDir (set by giipAgent3.ps1) as default if SearchBase not provided
    if (-not $SearchBase) { 
        $SearchBase = if ($Global:BaseDir) { $Global:BaseDir } else { $PSScriptRoot }
    }
    
    $config = @{}
    $configPath = $null
    
    # List of paths to check (Priority Order)
    $checkPaths = @(
        Join-Path (Split-Path $SearchBase -Parent) "giipAgent.cfg", # Parent of BaseDir
        Join-Path $env:USERPROFILE "giipAgent.cfg",                 # User Profile
        Join-Path $SearchBase "giipAgent.cfg"                      # Local (Last Resort)
    )
    
    foreach ($path in $checkPaths) {
        if (Test-Path $path) {
            # Standard "SAMPLE" check to avoid using the repository template
            $contentHead = Get-Content $path -TotalCount 10 -ErrorAction SilentlyContinue
            if ($contentHead -match "SAMPLE") {
                # Skip sample config
                continue
            }
            $configPath = $path
            break
        }
    }
    
    if ($configPath) {
        $raw = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $raw -split "`r?`n" | ForEach-Object {
                if ($_ -match '^\s*([^=:#\s\[]+)\s*[:=]\s*(.*)$') {
                    $k = $Matches[1].Trim().ToLower()
                    $v = $Matches[2].Trim()
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
    # Use Global AK if present (AK/SK Persistence standard)
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
        $response = $webResponse.Content | ConvertFrom-Json
        
        # Capture Dynamic AK for persistence
        if ($response.ak) {
            $Global:GiipSessionAK = $response.ak
        }
        
        if ($response.data -and $response.data.Count -gt 0) {
            return $response.data[0]
        }
        return $response
    } catch {
        Write-GiipLog "DEBUG" "API Call Failed: $_"
        return $null
    }
}
