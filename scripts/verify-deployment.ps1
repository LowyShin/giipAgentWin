# GIIP Agent Deployment Verifier
# 이 스크립트는 SPEC_AND_CHECKLIST.md의 핵심 사양을 강제로 검증합니다.

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot = Split-Path -Path $ScriptDir -Parent
$SyncScript = Join-Path $RepoRoot "git-auto-sync.ps1"

function Test-Checklist {
    Write-Host "--- GIIP Deployment Verification ---" -ForegroundColor Cyan
    $Failed = $false

    # 1. 파일 존재 확인
    if (-not (Test-Path $SyncScript)) {
        Write-Host "[FAIL] git-auto-sync.ps1 not found at $SyncScript" -ForegroundColor Red
        return $false
    }

    # 2. 내용 파싱
    $Content = Get-Content $SyncScript -Raw

    # [검증 A] 기본 브랜치가 'real'인가?
    if ($Content -match '\$targetBranch\s*=\s*"real"') {
        Write-Host "[PASS] Default branch is 'real'." -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Default branch is NOT 'real'! (Must be 'real')" -ForegroundColor Red
        $Failed = $true
    }

    # [검증 B] 설정 탐색 우선순위 (Parent Dir가 먼저인가?)
    # v1.3.9 에서는 Split-Path $StartPath -Parent 로 상위 폴더를 먼저 체크함
    if ($Content -match 'Split-Path\s+\$StartPath\s+-Parent') {
        Write-Host "[PASS] Config search priority logic found." -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Config search priority logic NOT found!" -ForegroundColor Red
        $Failed = $true
    }

    # [검증 C] 현재 브랜치 확인
    $Branch = (git branch --show-current).Trim()
    if ($Branch -eq "main") {
        Write-Host "[PASS] Current branch is 'main'. (Safe to work)" -ForegroundColor Green
    } elseif ($Branch -eq "real") {
        Write-Host "[BLOCK] Current branch is 'real'! (AI MUST NOT WORK HERE)" -ForegroundColor Red
        $Failed = $true
    } else {
        Write-Host "[WARN] Current branch is '$Branch'." -ForegroundColor Yellow
    }

    # [검증 D] 문법 오류 (@@{ 체크)
    if ($Content -match "@@{") {
        Write-Host "[FAIL] Found syntax error '@@{'!" -ForegroundColor Red
        $Failed = $true
    } else {
        Write-Host "[PASS] No '@@{' syntax errors found." -ForegroundColor Green
    }

    Write-Host "------------------------------------"
    if ($Failed) {
        Write-Host ">>> VERIFICATION FAILED! DO NOT PUSH! <<<" -ForegroundColor Red
        exit 1
    } else {
        Write-Host ">>> VERIFICATION PASSED. READY FOR DEPLOY. <<<" -ForegroundColor Green
        exit 0
    }
}

Test-Checklist
