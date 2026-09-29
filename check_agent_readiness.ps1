# check_agent_readiness.ps1
# AI         

$ErrorActionPreference = "SilentlyContinue"
$BaseDir = $PSScriptRoot

Write-Host "=== GIIP Agent Readiness Check ===" -ForegroundColor Cyan

# 1. giipAgent3.ps1 
$agent3 = Join-Path $BaseDir "giipAgent3.ps1"
if (Test-Path $agent3) {
    Write-Host " giipAgent  : YES (giipAgent3.ps1 )" -ForegroundColor Green
} else {
    Write-Host " giipAgent  : NO (giipAgent3.ps1 )" -ForegroundColor Red
}

# 2. AI  CLI 
$agentCmd = $null
$agentVersion = "N/A"
if (Get-Command "antigravity" -ErrorAction SilentlyContinue) {
    $agentCmd = "antigravity"
    $agentVersion = & antigravity --version 2>$null
} elseif (Get-Command "gemini" -ErrorAction SilentlyContinue) {
    $agentCmd = "gemini"
    $agentVersion = & gemini --version 2>$null
} elseif (Get-Command "claude" -ErrorAction SilentlyContinue) {
    $agentCmd = "claude"
    $agentVersion = & claude --version 2>$null
}

if ($agentCmd) {
    Write-Host " AI  CLI: $agentCmd ($agentVersion)" -ForegroundColor Green
} else {
    Write-Host " AI  CLI:  CLI   . (antigravity/gemini/claude)" -ForegroundColor Red
}

# 3.   
$projectRoot = (Get-Item $BaseDir).Parent.FullName
if (Test-Path (Join-Path $projectRoot "GEMINI.md")) {
    Write-Host "   : $projectRoot (GEMINI.md )" -ForegroundColor Green
} else {
    Write-Host "   : $projectRoot (GEMINI.md )" -ForegroundColor Red
}

# 4. addIssueComment.ps1 
$commentPath = Join-Path $projectRoot "giipdb\mgmt\addIssueComment.ps1"
if (Test-Path $commentPath) {
    Write-Host " addIssueComment.ps1: " -ForegroundColor Green
} else {
    Write-Host " addIssueComment.ps1:   (giipdb/mgmt/addIssueComment.ps1)" -ForegroundColor Red
}

# 5. Config (same lookup policy as runtime)
$parentPath = Join-Path (Split-Path -Path $BaseDir -Parent) "giipAgent.cfg"
$userPath = Join-Path $env:USERPROFILE "giipAgent.cfg"
$localPath = Join-Path $BaseDir "giipAgent.cfg"

$configPath = $null
foreach ($candidate in @($parentPath, $userPath)) {
    if (-not (Test-Path $candidate)) { continue }
    $head = Get-Content $candidate -TotalCount 10 -ErrorAction SilentlyContinue
    if ($head -match "SAMPLE") { continue }
    $configPath = $candidate
    break
}

if (-not $configPath -and (Test-Path $localPath)) {
    # Match runtime fallback policy: local config is accepted as last resort.
    $configPath = $localPath
}

if ($configPath) {
    $config = @{}
    Get-Content $configPath -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_ -match '^\s*([^=:#\s\[]+)\s*[:=]\s*(.*)$') {
            $k = $Matches[1].Trim().ToLower()
            $v = $Matches[2].Trim().Trim('"')
            $config[$k] = $v
        }
    }

    if ($config.sk) {
        Write-Host " SK : giipAgent.cfg found ($configPath)" -ForegroundColor Green
    } else {
        Write-Host " SK : giipAgent.cfg found but sk is missing ($configPath)" -ForegroundColor Red
    }
} else {
    Write-Host "  : giipAgent.cfg not found (checked parent/userprofile/local)" -ForegroundColor Red
}

Write-Host "`n ."

