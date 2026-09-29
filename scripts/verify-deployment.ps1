# GIIP Agent Deployment Verifier
# ?? ??????????SPEC_AND_CHECKLIST.md?????? ????? ??????????????.

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot = Split-Path -Path $ScriptDir -Parent
$SyncScript = Join-Path $RepoRoot "git-auto-sync.ps1"

function Test-Checklist {
    Write-Host "--- GIIP Deployment Verification ---" -ForegroundColor Cyan
    $Failed = $false

    # 1. ??? ???? ???
    if (-not (Test-Path $SyncScript)) {
        Write-Host "[FAIL] git-auto-sync.ps1 not found at $SyncScript" -ForegroundColor Red
        return $false
    }

    # 2. ???? ???
    $Content = Get-Content $SyncScript -Raw

    # [????A] ???? ??????? 'real'?????
    if ($Content -match '\$targetBranch\s*=\s*"real"') {
        Write-Host "[PASS] Default branch is 'real'." -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Default branch is NOT 'real'! (Must be 'real')" -ForegroundColor Red
        $Failed = $true
    }

    # [????B] ??????? ??????? (Parent Dir?? ?????????)
    # v1.3.9 ?????Split-Path $StartPath -Parent ????? ?????? ???? ??????
    if ($Content -match 'Split-Path\s+\$StartPath\s+-Parent') {
        Write-Host "[PASS] Config search priority logic found." -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Config search priority logic NOT found!" -ForegroundColor Red
        $Failed = $true
    }

    # [????C] ??? ????????
    $Branch = (git branch --show-current).Trim()
    if ($Branch -eq "main") {
        Write-Host "[PASS] Current branch is 'main'. (Safe to work)" -ForegroundColor Green
    } elseif ($Branch -eq "real") {
        Write-Host "[BLOCK] Current branch is 'real'! (AI MUST NOT WORK HERE)" -ForegroundColor Red
        $Failed = $true
    } else {
        Write-Host "[WARN] Current branch is '$Branch'." -ForegroundColor Yellow
    }

    # [????D] ????????(@@{ ????)
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
