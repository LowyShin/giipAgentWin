# IssueWorkflowRunner.ps1
# CQE  . GIIP Issue AI  .
param(
    [int]$isn,          # GIIP Issue 
    [string]$workflow = "gissue-proc" #   (: 'gissue-proc')
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent -Resolve
$BaseDir = Split-Path $ScriptDir -Parent | Split-Path -Parent  # giipAgentWin root

#   
. (Join-Path $BaseDir "lib\Common.ps1")

Write-GiipLog "INFO" "=== IssueWorkflowRunner START: isn=$isn, workflow=$workflow ==="

# 1. AI  CLI  (     )
$agentCmd = $null
$agentType = $null

# Antigravity (Void IDE) 
if (Get-Command "antigravity" -ErrorAction SilentlyContinue) {
    $agentCmd = "antigravity"
    $agentType = "antigravity"
}
# Gemini CLI 
elseif (Get-Command "gemini" -ErrorAction SilentlyContinue) {
    $agentCmd = "gemini"
    $agentType = "gemini"
}
# Claude Code 
elseif (Get-Command "claude" -ErrorAction SilentlyContinue) {
    $agentCmd = "claude"
    $agentType = "claude"
}

if (-not $agentCmd) {
    Write-GiipLog "ERROR" "AI  CLI   . (antigravity / gemini / claude)"
    #    
    $addCommentPath = Join-Path $BaseDir "..\giipdb\mgmt\addIssueComment.ps1"
    if (Test-Path $addCommentPath) {
        & $addCommentPath -isn $isn -content "   : AI  CLI  ." -issuetype "result"
    }
    exit 1
}

Write-GiipLog "INFO" "AI  : $agentType"

# 2.    (giipprj)
$projectRoot = Join-Path $BaseDir ".."  # giipAgentWin  = giipprj
if (-not (Test-Path (Join-Path $projectRoot "GEMINI.md"))) {
    Write-GiipLog "ERROR" "    : $projectRoot"
    exit 1
}

# 3. AI    
$prompt = "/$workflow $isn"
Write-GiipLog "INFO" ": $agentCmd '$prompt' (in $projectRoot)"

Push-Location $projectRoot
try {
    #    ( )
    # --dangerously-skip-permissions --print  Gemini CLI  Antigravity   .
    $result = & $agentCmd --dangerously-skip-permissions --print "$prompt" 2>&1
    $exitCode = $LASTEXITCODE
    Write-GiipLog "INFO" "   (exitCode=$exitCode)"
    
    # 4.    
    $summary = if ($result.Length -gt 2000) { $result.Substring(0, 2000) + "..." } else { $result }
    $commentContent = "##    `n`n$summary`n`n****: $(hostname)`n** **: $exitCode"
    
    $addCommentPath = Join-Path $BaseDir "..\giipdb\mgmt\addIssueComment.ps1"
    if (Test-Path $addCommentPath) {
        & $addCommentPath -isn $isn -content $commentContent -issuetype "result"
    }
    
    Write-GiipLog "INFO" "   "
}
catch {
    Write-GiipLog "ERROR" "  : $_"
}
finally {
    Pop-Location
}

Write-GiipLog "INFO" "=== IssueWorkflowRunner END ==="

