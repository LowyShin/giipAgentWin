# IssueWorkflowRunner.ps1
# CQE 큐로부터 실행됨. GIIP Issue를 AI 에이전트로 처리.
param(
    [int]$isn,          # GIIP Issue 번호
    [string]$workflow = "gissue-proc" # 실행할 워크플로우 (기본값: 'gissue-proc')
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent -Resolve
$BaseDir = Split-Path $ScriptDir -Parent | Split-Path -Parent  # giipAgentWin root

# 공통 라이브러리 로드
. (Join-Path $BaseDir "lib\Common.ps1")

Write-GiipLog "INFO" "=== IssueWorkflowRunner START: isn=$isn, workflow=$workflow ==="

# 1. AI 에이전트 CLI 확인 (아래 중 설치된 것 자동 탐지)
$agentCmd = $null
$agentType = $null

# Antigravity (Void IDE) 확인
if (Get-Command "antigravity" -ErrorAction SilentlyContinue) {
    $agentCmd = "antigravity"
    $agentType = "antigravity"
}
# Gemini CLI 확인
elseif (Get-Command "gemini" -ErrorAction SilentlyContinue) {
    $agentCmd = "gemini"
    $agentType = "gemini"
}
# Claude Code 확인
elseif (Get-Command "claude" -ErrorAction SilentlyContinue) {
    $agentCmd = "claude"
    $agentType = "claude"
}

if (-not $agentCmd) {
    Write-GiipLog "ERROR" "AI 에이전트 CLI를 찾을 수 없습니다. (antigravity / gemini / claude)"
    # 이슈에 실패 코멘트 등록
    $addCommentPath = Join-Path $BaseDir "..\giipdb\mgmt\addIssueComment.ps1"
    if (Test-Path $addCommentPath) {
        & $addCommentPath -isn $isn -content "❌ 에이전트 실행 실패: AI 에이전트 CLI가 설치되지 않았습니다." -issuetype "result"
    }
    exit 1
}

Write-GiipLog "INFO" "AI 에이전트 감지: $agentType"

# 2. 프로젝트 루트 찾기 (giipprj)
$projectRoot = Join-Path $BaseDir ".."  # giipAgentWin의 상위 = giipprj
if (-not (Test-Path (Join-Path $projectRoot "GEMINI.md"))) {
    Write-GiipLog "ERROR" "프로젝트 루트를 찾을 수 없습니다: $projectRoot"
    exit 1
}

# 3. AI 에이전트에게 워크플로우 실행 지시
$prompt = "/$workflow $isn"
Write-GiipLog "INFO" "실행: $agentCmd '$prompt' (in $projectRoot)"

Push-Location $projectRoot
try {
    # 비대화형 모드로 실행 (출력 캡처)
    # --dangerously-skip-permissions --print 옵션은 Gemini CLI 또는 Antigravity의 비대화형 실행 옵션입니다.
    $result = & $agentCmd --dangerously-skip-permissions --print "$prompt" 2>&1
    $exitCode = $LASTEXITCODE
    Write-GiipLog "INFO" "에이전트 실행 완료 (exitCode=$exitCode)"
    
    # 4. 결과를 이슈 코멘트로 등록
    $summary = if ($result.Length -gt 2000) { $result.Substring(0, 2000) + "..." } else { $result }
    $commentContent = "## 원격 에이전트 실행 결과`n`n$summary`n`n**머신**: $(hostname)`n**종료 코드**: $exitCode"
    
    $addCommentPath = Join-Path $BaseDir "..\giipdb\mgmt\addIssueComment.ps1"
    if (Test-Path $addCommentPath) {
        & $addCommentPath -isn $isn -content $commentContent -issuetype "result"
    }
    
    Write-GiipLog "INFO" "결과 코멘트 등록 완료"
}
catch {
    Write-GiipLog "ERROR" "실행 중 오류: $_"
}
finally {
    Pop-Location
}

Write-GiipLog "INFO" "=== IssueWorkflowRunner END ==="
