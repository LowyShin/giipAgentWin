<#
.SYNOPSIS
    GitHub 자동 동기화 스크립트 - Safe Pull (Windows 버전)
.DESCRIPTION
    로컬 변경사항을 보존하면서 원격 브랜치와 안전하게 동기화합니다.
.NOTES
    Version: 1.3.8 (Robust Logging)
    Author: GIIP Team
    Last Updated: 2026-03-24
#>

[CmdletBinding()]
param(
    [string]$RepoPath = $null
)

$ErrorActionPreference = "Continue"

# 1. RepoPath 결정
if ([string]::IsNullOrWhiteSpace($RepoPath)) { $RepoPath = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($RepoPath)) { $RepoPath = (Get-Item .).FullName }

$LOG_DIR = Join-Path $RepoPath "logs"
$LOG_FILE = Join-Path $LOG_DIR "git_auto_sync_$(Get-Date -Format 'yyyyMMdd').log"
$HOSTNAME = $env:COMPUTERNAME
$giipConfig = @{}

function Write-Log {
    param([string]$Message, [string]$Tag = "INFO")
    $timestamp = Get-Date -Format "yyyyMMdd HH:mm:ss"
    $logMessage = "[$timestamp] [$Tag] $Message"
    Write-Host $logMessage
    try {
        if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force -ErrorAction SilentlyContinue | Out-Null }
        Add-Content -Path $LOG_FILE -Value $logMessage -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Fallback to console only if file is locked
    }
}

function Send-RemoteLog {
    param([string]$Tag, [string]$Message)
    try {
        if ($giipConfig.ContainsKey("api_url")) {
            $apiUrl = $giipConfig["api_url"]
            $sk = if ($giipConfig.ContainsKey("sk") -and -not [string]::IsNullOrWhiteSpace($giipConfig["sk"])) { $giipConfig["sk"] } else { "${HOSTNAME}_FALLBACK" }
            $jsonData = @{ rlTag = $Tag; rlData = $Message } | ConvertTo-Json -Compress
            $body = @{ text = "RawLogPut rlTag rlData"; token = $sk; jsondata = $jsonData }
            Invoke-WebRequest -Uri $apiUrl -Method Post -Body $body -TimeoutSec 5 -ErrorAction SilentlyContinue -UseBasicParsing | Out-Null
        }
    } catch { }
}

Write-Log "=========================================="
Write-Log "Git Auto-Sync v1.3.8 (Safe Mode)"
Write-Log "Repository: $RepoPath"
Write-Log "=========================================="

# 2. 설정 파일 파싱
function Find-Config {
    param($StartPath)
    $curr = $StartPath
    while ($null -ne $curr) {
        $path = Join-Path $curr "giipAgent.cfg"
        if (Test-Path $path) { return $path }
        $parent = Split-Path $curr -Parent
        if ($parent -eq $curr -or [string]::IsNullOrWhiteSpace($parent)) { break }
        $curr = $parent
    }
    return $null
}

# Rule #23: Respect Config Value
$targetBranch = "main" 

$configPath = Find-Config -StartPath $RepoPath
if ($configPath) {
    Write-Log "✓ Config path: $configPath"
    if (Test-Path $configPath) {
        $raw = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $raw -split "`r?`n" | ForEach-Object {
                if ($_ -match '^\s*([^=:#\s\[]+)\s*[:=]\s*(.*)$') {
                    $k = $Matches[1].Trim().ToLower()
                    $v = $Matches[2].Trim().Trim("'").Trim('"')
                    $giipConfig[$k] = $v
                }
            }
        }
    }
    if ($giipConfig.ContainsKey("branch")) {
        $targetBranch = $giipConfig["branch"]
        Write-Log "✓ Using branch from config: $targetBranch"
    } else {
        Write-Log "⚠️ No branch found in config, defaulting to: $targetBranch"
    }
}

Write-Log "✓ Sync Target Branch: $targetBranch"

# 3. 안전한 동기화 (Conservative Sync)
if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
    Write-Log "ERROR: Not a git repository"
    exit 1
}

Set-Location $RepoPath
Write-Log "Step 1: Stashing local changes (if any)..."
git stash 2>&1 | ForEach-Object { Write-Log "  $_" }

Write-Log "Step 2: Checking out target branch: $targetBranch"
git checkout $targetBranch 2>&1 | ForEach-Object { Write-Log "  $_" }

Write-Log "Step 3: Pulling from origin..."
git pull origin $targetBranch 2>&1 | ForEach-Object { Write-Log "  $_" }

if ($LASTEXITCODE -eq 0) {
    $commit = git rev-parse --short HEAD
    Write-Log "✓ Safe sync completed at $commit"
    Send-RemoteLog -Tag "sync_success" -Message "Safe sync to $targetBranch at $commit"
} else {
    Write-Log "ERROR: Sync failed during pull"
    Send-RemoteLog -Tag "sync_error" -Message "Safe sync failed for branch $targetBranch"
    exit 1
}

exit 0
