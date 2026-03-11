# check_agent_readiness.ps1
# AI 에이전트 원격 실행을 위한 로컬 환경 준비 상태 점검

$ErrorActionPreference = "SilentlyContinue"
$BaseDir = $PSScriptRoot

Write-Host "=== GIIP Agent Readiness Check ===" -ForegroundColor Cyan

# 1. giipAgent3.ps1 확인
$agent3 = Join-Path $BaseDir "giipAgent3.ps1"
if (Test-Path $agent3) {
    Write-Host "✅ giipAgent 실행 가능: YES (giipAgent3.ps1 존재)" -ForegroundColor Green
} else {
    Write-Host "❌ giipAgent 실행 가능: NO (giipAgent3.ps1 없음)" -ForegroundColor Red
}

# 2. AI 에이전트 CLI 확인
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
    Write-Host "✅ AI 에이전트 CLI: $agentCmd ($agentVersion)" -ForegroundColor Green
} else {
    Write-Host "❌ AI 에이전트 CLI: 설치된 CLI를 찾을 수 없습니다. (antigravity/gemini/claude)" -ForegroundColor Red
}

# 3. 프로젝트 루트 확인
$projectRoot = (Get-Item $BaseDir).Parent.FullName
if (Test-Path (Join-Path $projectRoot "GEMINI.md")) {
    Write-Host "✅ 프로젝트 루트 연결: $projectRoot (GEMINI.md 확인)" -ForegroundColor Green
} else {
    Write-Host "❌ 프로젝트 루트 연결: $projectRoot (GEMINI.md 없음)" -ForegroundColor Red
}

# 4. addIssueComment.ps1 확인
$commentPath = Join-Path $projectRoot "giipdb\mgmt\addIssueComment.ps1"
if (Test-Path $commentPath) {
    Write-Host "✅ addIssueComment.ps1: 확인됨" -ForegroundColor Green
} else {
    Write-Host "❌ addIssueComment.ps1: 파일 없음 (giipdb/mgmt/addIssueComment.ps1)" -ForegroundColor Red
}

# 5. 네트워크 및 설정 확인
$configPath = Join-Path $BaseDir "giipAgent.cfg"
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-StringData
    if ($config.sk) {
        Write-Host "✅ SK 설정: giipAgent.cfg 확인됨" -ForegroundColor Green
    } else {
        Write-Host "❌ SK 설정: giipAgent.cfg에 sk 값이 없습니다." -ForegroundColor Red
    }
} else {
    Write-Host "❌ 설정 파일: giipAgent.cfg 없음" -ForegroundColor Red
}

Write-Host "`n점검 완료."
