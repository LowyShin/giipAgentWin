# Openclaw Sync Script
# 2026-05-07 - Created for Openclaw Data Synchronization

$ErrorActionPreference = "Stop"

# 1. Load Configuration
function Get-GiipConfig {
    $Config = @{}
    # Search paths: Current Dir, Parent Dir, User Profile
    $SearchPaths = @(
        $PSScriptRoot,
        (Join-Path $PSScriptRoot ".."),
        $env:USERPROFILE
    )
    
    $CfgFile = "giipAgent.cfg"
    $FoundPath = $null
    
    foreach ($path in $SearchPaths) {
        $fullPath = Join-Path $path $CfgFile
        if (Test-Path $fullPath) {
            $FoundPath = $fullPath
            break
        }
    }
    
    if ($null -eq $FoundPath) {
        throw "Configuration file ($CfgFile) not found in search paths."
    }
    
    $lines = Get-Content $FoundPath
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Trim().StartsWith("#")) { continue }
        if ($line -match '^(?<k>\w+)\s*=\s*"(?<v>.*)"') {
            $Config[$Matches.k.Trim()] = $Matches.v.Trim()
        }
        elseif ($line -match '^(?<k>\w+)\s*=\s*(?<v>.*)') {
            $Config[$Matches.k.Trim()] = $Matches.v.Trim()
        }
    }
    return $Config
}

# 2. Extract Openclaw Data
function Get-OpenclawData {
    $OpenclawDir = Join-Path $PSScriptRoot "..\.openclaw"
    if (-not (Test-Path $OpenclawDir)) {
        throw "Openclaw directory (.openclaw) not found at $OpenclawDir"
    }
    
    $ConfigsDir = Join-Path $OpenclawDir "configs"
    $DocsDir = Join-Path $OpenclawDir "docs"
    
    $ChangedConfigs = @{}
    if (Test-Path $ConfigsDir) {
        Get-ChildItem -Path $ConfigsDir -Filter *.json | ForEach-Object {
            $name = $_.Name
            $content = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $ChangedConfigs[$name] = $content
        }
    }
    
    $ChangedDocs = @()
    if (Test-Path $DocsDir) {
        Get-ChildItem -Path $DocsDir -Recurse -File | ForEach-Object {
            $relPath = $_.FullName.Replace($DocsDir, "").TrimStart("\")
            $content = Get-Content $_.FullName -Raw
            $ChangedDocs += @{
                doc_path = "docs/$relPath"
                doc_content = $content
            }
        }
    }
    
    return @{
        changedConfigs = $ChangedConfigs
        changedDocs = $ChangedDocs
    }
}

# 3. Main Execution
try {
    Write-Host "[Sync] Loading configuration..."
    $Config = Get-GiipConfig
    $at = $Config.sk
    $lssn = $Config.lssn
    
    if ([string]::IsNullOrWhiteSpace($at) -or $at -eq "YOUR_KVS_TOKEN") {
        throw "Invalid Agent Token (sk) in configuration."
    }
    if ([string]::IsNullOrWhiteSpace($lssn) -or $lssn -eq "YOUR_LSSN") {
        throw "Invalid LSSN in configuration."
    }
    
    Write-Host "[Sync] Extracting local data from .openclaw..."
    $localData = Get-OpenclawData
    
    $payload = @{
        at = $at
        lssn = [int]$lssn
        changedConfigs = $localData.changedConfigs
        changedDocs = $localData.changedDocs
    }
    
    $apiUrl = "https://api.netbako.com/api/PutOpenclawSync"
    Write-Host "[Sync] Calling API: $apiUrl"
    
    $jsonPayload = $payload | ConvertTo-Json -Depth 10 -Compress
    $headers = @{ "Content-Type" = "application/json" }
    
    $response = Invoke-RestMethod -Method Put -Uri $apiUrl -Headers $headers -Body $jsonPayload
    
    if ($response.RstVal -eq 1) {
        Write-Host "[SUCCESS] Sync completed." -ForegroundColor Green
        Write-Host "Message: $($response.RstMsg)"
        Write-Host "New Config Hash: $($response.Data.newConfigHash)"
        Write-Host "New Doc Hash: $($response.Data.newDocHash)"
    } else {
        Write-Host "[ERROR] Sync failed: $($response.RstMsg)" -ForegroundColor Red
    }
}
catch {
    Write-Host "[FATAL] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
