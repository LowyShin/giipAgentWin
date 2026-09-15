# ============================================================================
# CleanState.ps1 (Restored Pure ASCII Version)
# Purpose: Delete previous state files and old logs for a clean start.
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$DataDir = Join-Path $AgentRoot "data"

# Create data directory if not exists
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Write-Host "Created data directory: $DataDir"
}

Write-Host "Cleaning state files in $DataDir..."

# giip #2546: 이 스크립트가 남기는 로그가 Write-Host 뿐이라(파일 로그가 아님)
# "내용이 있는 queue.json 이 실행되지 않은 채 삭제되는" 회귀가 몇 달간 아무
# 흔적도 남기지 않았다. 같은 일이 다시 일어나면 giipLogs\giipAgentWin_*.log 만
# 봐도 드러나도록 WARN 을 남긴다. CleanState.ps1 은 단독 실행도 가능하므로
# (giipAgent3.ps1 이 Common.ps1 을 먼저 로드하지 않은 경우) Write-GiipLog 가
# 없으면 Write-Host 로 떨어진다.
function Write-CleanStateWarn {
    param([string]$Message)
    if (Get-Command "Write-GiipLog" -ErrorAction SilentlyContinue) {
        Write-GiipLog "WARN" $Message
    } else {
        Write-Host "[WARN] $Message"
    }
}

# Clean target files
$targets = @("queue.json", "task_result.json", "last_run.json")

foreach ($file in $targets) {
    $path = Join-Path $DataDir $file
    if (Test-Path $path) {
        # giip #2546: 정상 흐름에서 queue.json 은 giipscripts\modules\CqeRun.ps1 이
        # 같은 실행 안에서 이미 소비(queue_last.json 으로 이동)했어야 한다. 여기서
        # 내용이 있는 queue.json 을 만났다는 것은 "받아만 놓고 실행하지 않은 작업을
        # 지금 버리는 중"이라는 뜻이므로 반드시 눈에 띄게 남긴다.
        if ($file -eq "queue.json") {
            try {
                $queueRaw = Get-Content -Path $path -Raw -Encoding UTF8 -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($queueRaw)) {
                    $preview = $queueRaw.Trim() -replace '\s+', ' '
                    if ($preview.Length -gt 300) { $preview = $preview.Substring(0, 300) + "..." }
                    Write-CleanStateWarn "[CleanState] giip #2546: deleting a NON-EMPTY queue.json - an unexecuted CQE task is being discarded. Content: $preview"
                }
            }
            catch {
                Write-CleanStateWarn "[CleanState] giip #2546: could not inspect queue.json before deleting it ($($_.Exception.Message))."
            }
        }

        try {
            Remove-Item -Path $path -Force
            Write-Host "  Deleted: $file"
        }
        catch {
            Write-Host "  Failed to delete: $file ($($_.Exception.Message))"
        }
    }
}

# Clean old log files (keep last 7 days)
$LogDir = Join-Path $AgentRoot "giipLogs"
if (Test-Path $LogDir) {
    Write-Host "Cleaning old log files (keeping last 7 days)..."
    $cutoffDate = (Get-Date).AddDays(-7)
    
    try {
        Get-ChildItem -Path $LogDir -Filter "*.log" | Where-Object {
            $_.LastWriteTime -lt $cutoffDate
        } | ForEach-Object {
            Remove-Item $_.FullName -Force
            Write-Host "  Deleted old log: $($_.Name)"
        }
    }
    catch {
        Write-Host "  Warning: Failed to clean some log files ($($_.Exception.Message))"
    }
}

Write-Host "Clean state completed."
exit 0
