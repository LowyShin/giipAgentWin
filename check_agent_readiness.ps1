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

# 5.    
$configPath = Join-Path $BaseDir "giipAgent.cfg"
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-StringData
    if ($config.sk) {
        Write-Host " SK : giipAgent.cfg " -ForegroundColor Green
    } else {
        Write-Host " SK : giipAgent.cfg sk  ." -ForegroundColor Red
    }
} else {
    Write-Host "  : giipAgent.cfg " -ForegroundColor Red
}

Write-Host "`n ."

