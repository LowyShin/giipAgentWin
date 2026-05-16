﻿# ============================================================================
# giipAgent Common Library (PowerShell)
# Version: 1.05
# Purpose: Shared utilities and API communication
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
        
        # Capture Dynamic AK for persistence (from result or RstMsg metadata if applicable)
        if ($response.ak) {
            $Global:GiipSessionAK = $response.ak
            Write-GiipLog "DEBUG" "Dynamic AK updated for session."
        }
        
        if ($response.data -and $response.data.Count -gt 0) {
            return $response.data[0]
        }
        return $response
    } catch {
        return $null
    }
}
