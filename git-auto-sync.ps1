<#
.SYNOPSIS
    GitHub 자동 동기화 스크립트 - Pull-Only (Windows 버전)

.DESCRIPTION
    GitHub에서 변경사항을 자동으로 풀하는 읽기 전용 스크립트입니다.
    공개 저장소용 - 로컬 변경사항은 Push하지 않음 (보안)

.NOTES
    Version: 1.0.0 (Pull-Only)
    Author: GIIP Team
    Last Updated: 2025-10-29
    Security: 로컬 변경사항은 자동 커밋/푸시 하지 않음

.EXAMPLE
    .\git-auto-sync.ps1
    현재 디렉토리에서 Git 동기화 실행

.EXAMPLE
    .\git-auto-sync.ps1 -RepoPath "C:\giipAgent"
    특정 경로에서 Git 동기화 실행
#>

[CmdletBinding()]
param(
    [string]$RepoPath = $PSScriptRoot
)

# ============================================================
# 설정
# ============================================================
$ErrorActionPreference = "Continue"
$LOG_DIR = "C:\giipAgent\logs"
$LOG_FILE = Join-Path $LOG_DIR "git_auto_sync_$(Get-Date -Format 'yyyyMMdd').log"
$HOSTNAME = $env:COMPUTERNAME

# ============================================================
# 로그 함수
# ============================================================
function Write-Log {
    param([string]$Message)
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    
    Write-Host $logMessage
    
    # 로그 디렉토리 생성
    if (-not (Test-Path $LOG_DIR)) {
        New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    }
    
    Add-Content -Path $LOG_FILE -Value $logMessage -Encoding UTF8
}

# ============================================================
# 시작
# ============================================================
Write-Log "=========================================="
Write-Log "Git Auto-Sync v1.0.0 (Pull-Only) Started"
Write-Log "Repository: $RepoPath"
Write-Log "Hostname: $HOSTNAME"
Write-Log "=========================================="

# Git 저장소 확인
if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
    Write-Log "ERROR: Not a git repository: $RepoPath"
    exit 1
}

# 디렉토리 이동
Set-Location $RepoPath
Write-Log "Changed directory to: $RepoPath"

# ============================================================
# Git 사용자 설정 확인
# ============================================================
$gitUserName = git config user.name
$gitUserEmail = git config user.email

if ([string]::IsNullOrWhiteSpace($gitUserName) -or [string]::IsNullOrWhiteSpace($gitUserEmail)) {
    Write-Log "WARNING: Git user.name or user.email not configured"
    Write-Log "Setting default git config..."
    git config user.name "giipAgent-$HOSTNAME"
    git config user.email "giipagent@$HOSTNAME.local"
    Write-Log "Git config set: user.name=giipAgent-$HOSTNAME, user.email=giipagent@$HOSTNAME.local"
}

# ============================================================
# 현재 브랜치 확인 및 전환 (giipAgent.cfg에서 읽기)
# ============================================================
# Default branch
$targetBranch = "real"

# Try to read branch from config file
$configPaths = @(
    (Join-Path (Split-Path $RepoPath -Parent) "giipAgent.cfg"),
    (Join-Path $env:USERPROFILE "giipAgent.cfg"),
    (Join-Path $RepoPath "giipAgent.cfg")
)

foreach ($configPath in $configPaths) {
    if (Test-Path $configPath) {
        Write-Log "Found config file: $configPath"
        $configContent = Get-Content $configPath -ErrorAction SilentlyContinue
        $branchLine = $configContent | Where-Object { $_ -match '^\s*branch\s*=' }
        if ($branchLine) {
            $configBranch = ($branchLine -split '=')[1].Trim().Trim('"')
            if ($configBranch) {
                $targetBranch = $configBranch
                Write-Log "Using branch from config: $targetBranch"
                break
            }
        }
    }
}

Write-Log "Target branch: $targetBranch"
$currentBranch = git rev-parse --abbrev-ref HEAD 2>$null

if ($currentBranch -ne $targetBranch) {
    Write-Log "Current branch is '$currentBranch'. Switching to '$targetBranch'..."
    git fetch origin $targetBranch 2>&1 | ForEach-Object { Write-Log "  $_" }
    git checkout $targetBranch 2>&1 | ForEach-Object { Write-Log "  $_" }
    
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Failed to checkout '$targetBranch'. Please check manually."
        exit 1
    }
    $currentBranch = $targetBranch
}

Write-Log "Current branch: $currentBranch"

# ============================================================
# Step 0: Fetch remote changes
# ============================================================
Write-Log "=========================================="
Write-Log "Step 0: Fetching remote changes..."
Write-Log "=========================================="

git fetch origin 2>&1 | ForEach-Object { Write-Log "  $_" }
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: git fetch failed"
    exit 1
}
Write-Log "✓ Fetch completed successfully"

# ============================================================
# Step 1: 로컬 변경사항 경고 (Push하지 않음)
# ============================================================
Write-Log "=========================================="
Write-Log "Step 1: Checking local changes..."
Write-Log "=========================================="

$changedFiles = git status --porcelain
if ($changedFiles) {
    Write-Log "⚠ WARNING: Local changes detected (will NOT be pushed - Read-Only Mode):"
    $changedFiles -split "`n" | ForEach-Object { Write-Log "  $_" }
    Write-Log ""
    Write-Log "⚠ SECURITY NOTICE: This is a public repository."
    Write-Log "⚠ Local changes will be stashed before pull to prevent conflicts."
    Write-Log "⚠ To commit changes, please use manual git workflow."
    Write-Log ""
    
    Write-Log "Stashing local changes..."
    $stashMessage = "Auto-stash before pull at $(Get-Date -Format 'yyyy-MM-dd HH:MM:ss') on $HOSTNAME"
    git stash save $stashMessage 2>&1 | ForEach-Object { Write-Log "  $_" }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "✓ Local changes stashed successfully"
        Write-Log "To recover: git stash list && git stash pop"
        $stashed = $true
    }
    else {
        Write-Log "ERROR: Failed to stash local changes"
        exit 1
    }
}
else {
    Write-Log "✓ No local changes detected"
    $stashed = $false
}

# ============================================================
# Step 2: Pull remote changes
# ============================================================
Write-Log "=========================================="
Write-Log "Step 2: Checking remote changes..."
Write-Log "=========================================="

$localHash = git rev-parse HEAD
$remoteHash = git rev-parse "origin/$currentBranch"

Write-Log "Local commit:  $localHash"
Write-Log "Remote commit: $remoteHash"

if ($localHash -ne $remoteHash) {
    Write-Log "⚠ Remote changes detected, pulling..."
    
    Write-Log "Pulling from origin/$currentBranch..."
    git pull origin $currentBranch 2>&1 | ForEach-Object { Write-Log "  $_" }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "✓ Pull succeeded"
        $newHash = git rev-parse HEAD
        Write-Log "Updated to commit: $newHash"
        
        # Show what changed
        Write-Log "Changes pulled:"
        git log --oneline "$localHash..$newHash" 2>&1 | ForEach-Object { Write-Log "  $_" }
    }
    else {
        Write-Log "ERROR: Pull failed"
        
        # Restore stashed changes if any
        if ($stashed) {
            Write-Log "Restoring stashed changes..."
            git stash pop 2>&1 | ForEach-Object { Write-Log "  $_" }
        }
        exit 1
    }
}
else {
    Write-Log "✓ Already up to date with remote"
}

# ============================================================
# Step 3: Stashed changes information
# ============================================================
if ($stashed) {
    Write-Log "=========================================="
    Write-Log "Step 3: Stashed changes information"
    Write-Log "=========================================="
    Write-Log "Your local changes are stashed and NOT pushed (Read-Only Mode)"
    Write-Log "Stash list:"
    git stash list | Select-Object -First 5 | ForEach-Object { Write-Log "  $_" }
    Write-Log ""
    Write-Log "To restore your changes:"
    Write-Log "  git stash pop"
    Write-Log "To discard stashed changes:"
    Write-Log "  git stash drop"
    Write-Log ""
    Write-Log "⚠ NOTE: This is a public repository."
    Write-Log "⚠ Do NOT commit sensitive information."
}

# ============================================================
# 완료
# ============================================================
Write-Log "=========================================="
Write-Log "Git Auto-Sync (Pull-Only) Completed"
Write-Log "=========================================="
Write-Log ""

# 최종 상태 출력
Write-Log "Final Status:"
Write-Log "  Branch: $currentBranch"
Write-Log "  Commit: $(git rev-parse --short HEAD)"
Write-Log "  Author: $(git log -1 --format='%an <%ae>')"
Write-Log "  Date:   $(git log -1 --format='%cd')"
Write-Log "  Message: $(git log -1 --format='%s')"

if ($stashed) {
    $stashCount = (git stash list | Measure-Object).Count
    Write-Log "  Stashed: YES ($stashCount items)"
}
else {
    Write-Log "  Stashed: NO"
}

Write-Log ""
Write-Log "✓ Sync completed successfully (Pull-Only Mode)"

exit 0
