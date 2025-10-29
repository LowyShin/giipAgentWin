<#
.SYNOPSIS
    GitHub 양방향 자동 동기화 스크립트 (Windows 버전)

.DESCRIPTION
    로컬 변경사항을 자동으로 커밋/푸시하고, GitHub에서 변경사항을 자동으로 풀합니다.
    Linux의 git-auto-sync.sh와 동일한 기능을 제공합니다.

.NOTES
    Version: 2.0.0
    Author: GIIP Team
    Last Updated: 2025-10-29

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
Write-Log "Git Auto-Sync v2.0.0 Started"
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
# 현재 브랜치 확인
# ============================================================
$currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to get current branch"
    exit 1
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
# Step 1: Auto-commit and push local changes
# ============================================================
Write-Log "=========================================="
Write-Log "Step 1: Checking local changes..."
Write-Log "=========================================="

$changedFiles = git status --porcelain
if ($changedFiles) {
    Write-Log "⚠ Local changes detected:"
    $changedFiles -split "`n" | ForEach-Object { Write-Log "  $_" }
    
    Write-Log "Adding all changes to staging..."
    git add -A 2>&1 | ForEach-Object { Write-Log "  $_" }
    
    $commitMessage = "Auto-commit from $HOSTNAME at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "Creating commit: $commitMessage"
    git commit -m $commitMessage 2>&1 | ForEach-Object { Write-Log "  $_" }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Pushing to origin/$currentBranch..."
        git push origin $currentBranch 2>&1 | ForEach-Object { Write-Log "  $_" }
        
        if ($LASTEXITCODE -eq 0) {
            Write-Log "✓ Push succeeded"
        } else {
            Write-Log "ERROR: Push failed, attempting pull and retry..."
            
            Write-Log "Pulling with rebase..."
            git pull origin $currentBranch --rebase 2>&1 | ForEach-Object { Write-Log "  $_" }
            
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Retrying push..."
                git push origin $currentBranch 2>&1 | ForEach-Object { Write-Log "  $_" }
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "✓ Push succeeded after rebase"
                } else {
                    Write-Log "ERROR: Push failed even after rebase"
                    Write-Log "Manual intervention may be required"
                    exit 1
                }
            } else {
                Write-Log "ERROR: Rebase failed"
                Write-Log "Aborting rebase..."
                git rebase --abort 2>&1 | Out-Null
                exit 1
            }
        }
    } else {
        Write-Log "ERROR: Commit failed"
        exit 1
    }
} else {
    Write-Log "✓ No local changes to commit"
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
    
    # Stash 확인
    $stashList = git stash list
    $needsStash = $false
    
    if (git status --porcelain) {
        Write-Log "Stashing local changes..."
        git stash save "Auto-stash before pull at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" 2>&1 | ForEach-Object { Write-Log "  $_" }
        $needsStash = $true
    }
    
    # Pull
    Write-Log "Pulling from origin/$currentBranch..."
    git pull origin $currentBranch 2>&1 | ForEach-Object { Write-Log "  $_" }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "✓ Pull succeeded"
        
        # Stash 복원
        if ($needsStash) {
            Write-Log "Restoring stashed changes..."
            git stash pop 2>&1 | ForEach-Object { Write-Log "  $_" }
            
            if ($LASTEXITCODE -eq 0) {
                Write-Log "✓ Stash restored successfully"
            } else {
                Write-Log "WARNING: Stash pop had conflicts, please resolve manually"
                Write-Log "Use 'git stash list' to see stashed changes"
            }
        }
        
        $newHash = git rev-parse HEAD
        Write-Log "Updated to commit: $newHash"
    } else {
        Write-Log "ERROR: Pull failed"
        
        # Stash 복원 시도
        if ($needsStash) {
            Write-Log "Restoring stashed changes..."
            git stash pop 2>&1 | Out-Null
        }
        exit 1
    }
} else {
    Write-Log "✓ Already up to date with remote"
}

# ============================================================
# 완료
# ============================================================
Write-Log "=========================================="
Write-Log "Git Auto-Sync Completed Successfully"
Write-Log "=========================================="
Write-Log ""

# 최종 상태 출력
Write-Log "Final Status:"
Write-Log "  Branch: $currentBranch"
Write-Log "  Commit: $(git rev-parse --short HEAD)"
Write-Log "  Author: $(git log -1 --format='%an <%ae>')"
Write-Log "  Date:   $(git log -1 --format='%cd')"
Write-Log "  Message: $(git log -1 --format='%s')"
Write-Log ""

exit 0
