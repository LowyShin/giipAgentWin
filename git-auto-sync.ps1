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
#>

[CmdletBinding()]
param(
    [string]$RepoPath = $PSScriptRoot
)

$ErrorActionPreference = "Continue"
$LOG_DIR = "C:\giipAgent\logs"
$LOG_FILE = Join-Path $LOG_DIR "git_auto_sync_$(Get-Date -Format 'yyyyMMdd').log"
$HOSTNAME = $env:COMPUTERNAME

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage
    if (-not (Test-Path $LOG_DIR)) {
        New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    }
    Add-Content -Path $LOG_FILE -Value $logMessage -Encoding UTF8
}

Write-Log "Git Auto-Sync v1.0.0 (Pull-Only) Started"

if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
    Write-Log "ERROR: Not a git repository: $RepoPath"
    exit 1
}

Set-Location $RepoPath

$targetBranch = "real"
$configPaths = @(
    (Join-Path (Split-Path $RepoPath -Parent) "giipAgent.cfg"),
    (Join-Path $env:USERPROFILE "giipAgent.cfg"),
    (Join-Path $RepoPath "giipAgent.cfg")
)

foreach ($configPath in $configPaths) {
    if (Test-Path $configPath) {
        $config = Get-Content $configPath
        foreach ($line in $config) {
            if ($line -match "^branch\s*=\s*`"(.+)`"") {
                $targetBranch = $matches[1]
                break
            }
        }
        if ($targetBranch) { break }
    }
}

$currentBranch = git rev-parse --abbrev-ref HEAD

if ($currentBranch -ne $targetBranch) {
    git checkout $targetBranch
}

git pull origin $targetBranch

Write-Log "Git Auto-Sync Completed Successfully"
