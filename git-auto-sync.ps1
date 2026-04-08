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
        Write-Log "Checking config: $configPath"
        $config = Get-Content $configPath
        foreach ($line in $config) {
            if ($line -match "^branch\s*=\s*`"(.+)`"") {
                $targetBranch = $matches[1]
                Write-Log "Found target branch in config: $targetBranch"
                break
            }
        }
        if ($targetBranch) { break }
    }
}

Write-Log "Target Branch: $targetBranch"

# 현재 브랜치 확인
$currentBranch = git rev-parse --abbrev-ref HEAD
Write-Log "Current Branch: $currentBranch"

if ($currentBranch -ne $targetBranch) {
    Write-Log "Switching to branch: $targetBranch"
    
    # 로컬 변경사항 확인
    $status = git status --porcelain
    if ($status) {
        Write-Log "WARNING: Local changes detected. Stashing changes..."
        git stash | Out-Null
    }
    
    git checkout $targetBranch
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Failed to switch to branch $targetBranch"
        exit 1
    }
}

# ============================================================
# 업데이트 수행 (Pull)
# ============================================================
Write-Log "Fetching changes from origin..."
git fetch origin $targetBranch

$localHash = git rev-parse HEAD
$remoteHash = git rev-parse "origin/$targetBranch"

if ($localHash -ne $remoteHash) {
    Write-Log "New changes detected. Updating..."
    
    # Pull 실행 (이미 checkout 상태임)
    git pull origin $targetBranch
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Update successful: $localHash -> $remoteHash"
    } else {
        Write-Log "ERROR: Update failed"
        exit 1
    }
} else {
    Write-Log "Already up to date."
}

Write-Log "=========================================="
Write-Log "Git Auto-Sync Completed Successfully"
Write-Log "=========================================="
