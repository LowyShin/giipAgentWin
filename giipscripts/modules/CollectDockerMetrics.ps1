# ============================================================================
# CollectDockerMetrics.ps1
# Purpose: Detect whether Docker Desktop is installed/running on this Windows
#          server and, if so, collect container/image/disk-usage metrics and
#          upload them to KVS (factor "docker_usage") so giipv3 can later show
#          a "Provision now" lssn dropdown with real resource headroom
#          (giip 3043, 1/4 단계 — 이 스크립트는 수집만 한다, 화면/드롭다운은 별도 단계).
# Usage: .\CollectDockerMetrics.ps1
#
# giip 3043 (1/4): Docker 가 없는 서버가 대부분일 것이므로, 미설치/데몬 미기동은
# 에러가 아니라 정상 경로다 - dockerInstalled=$false 만 KVS 에 올리고 조용히 끝낸다.
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "KVS.ps1")
}
catch {
    Write-Host "FATAL: Failed to load libraries from $LibDir"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
}
catch {
    Write-GiipLog "ERROR" "[CollectDockerMetrics] Failed to load config: $_"
    exit 1
}

Write-GiipLog "INFO" "[CollectDockerMetrics] Starting Docker resource usage collection..."

# 사람이 읽는 크기 문자열("1.199GB", "0B", "113.2MB (69%)")을 GB 단위 double 로
# 변환한다. 파싱 실패 시 0.0 을 반환한다(giip #2377: docker 미설치 환경에서 실제
# 출력 포맷을 라이브 검증하지 못했으므로, 알려진 단위(B/KB/MB/GB/TB)를 최대한
# 넓게 커버하되 실패해도 스크립트 전체가 죽지 않게 한다).
function ConvertTo-GbFromSizeString {
    param([string]$SizeText)
    try {
        if ([string]::IsNullOrWhiteSpace($SizeText)) { return 0.0 }
        # "113.2MB (69%)" 처럼 괄호로 퍼센트가 붙는 경우 앞부분만 사용
        $sizePart = ($SizeText -split '\s+')[0]
        if ($sizePart -match '^([0-9.]+)\s*(B|KB|MB|GB|TB)$') {
            $num = [double]$Matches[1]
            switch ($Matches[2]) {
                "B"  { return [math]::Round($num / 1GB, 4) }
                "KB" { return [math]::Round(($num * 1KB) / 1GB, 4) }
                "MB" { return [math]::Round(($num * 1MB) / 1GB, 4) }
                "GB" { return [math]::Round($num, 4) }
                "TB" { return [math]::Round($num * 1024, 4) }
            }
        }
        return 0.0
    }
    catch {
        return 0.0
    }
}

$dockerInstalled = $false
$dockerVersion = ""
$containersRunning = 0
$containersTotal = 0
$imagesCount = 0
$diskUsedGb = 0.0
$diskReclaimableGb = 0.0

try {
    # 1. Docker CLI 존재 확인
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-GiipLog "INFO" "[CollectDockerMetrics] Docker CLI not found on this host. Reporting dockerInstalled=false (normal for most servers)."
    }
    else {
        # 2. 데몬이 실제로 떠 있는지 확인 (CLI 는 있어도 Docker Desktop 이 꺼져 있을 수 있음)
        $serverVersion = $null
        try {
            $serverVersion = & docker version --format '{{.Server.Version}}' 2>$null
        }
        catch {
            $serverVersion = $null
        }

        if ([string]::IsNullOrWhiteSpace($serverVersion) -or $LASTEXITCODE -ne 0) {
            Write-GiipLog "INFO" "[CollectDockerMetrics] Docker CLI found but daemon is not reachable (not running). Reporting dockerInstalled=false."
        }
        else {
            $dockerInstalled = $true
            $dockerVersion = $serverVersion.Trim()
            Write-GiipLog "INFO" "[CollectDockerMetrics] Docker daemon detected (version $dockerVersion). Collecting resource metrics..."

            # 3. docker info -> 컨테이너/이미지 개수
            try {
                $infoJson = & docker info --format '{{json .}}' 2>$null
                if ($infoJson) {
                    $info = $infoJson | ConvertFrom-Json
                    if ($null -ne $info.ContainersRunning) { $containersRunning = [int]$info.ContainersRunning }
                    if ($null -ne $info.Containers) { $containersTotal = [int]$info.Containers }
                    if ($null -ne $info.Images) { $imagesCount = [int]$info.Images }
                }
            }
            catch {
                Write-GiipLog "ERROR" "[CollectDockerMetrics] Failed to parse 'docker info' output: $_"
            }

            # 4. docker system df -> 이미지/컨테이너/볼륨 디스크 사용량 및 회수가능 용량
            # 참고: `docker system df --format '{{json .}}'` 는 보통 타입(Images/
            # Containers/Local Volumes/Build Cache)별로 한 줄씩 JSON 을 출력한다
            # (단일 JSON 배열이 아님). 이 환경엔 Docker 가 없어 라이브 검증을 못 했으므로
            # 줄 단위 파싱을 시도하고, 실패하는 줄은 개별적으로 건너뛴다.
            try {
                $dfLines = & docker system df --format '{{json .}}' 2>$null
                if ($dfLines) {
                    foreach ($line in $dfLines) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        try {
                            $row = $line | ConvertFrom-Json
                            if ($row.Size) { $diskUsedGb += (ConvertTo-GbFromSizeString $row.Size) }
                            if ($row.Reclaimable) { $diskReclaimableGb += (ConvertTo-GbFromSizeString $row.Reclaimable) }
                        }
                        catch {
                            Write-GiipLog "ERROR" "[CollectDockerMetrics] Failed to parse a 'docker system df' row: $_"
                        }
                    }
                    $diskUsedGb = [math]::Round($diskUsedGb, 2)
                    $diskReclaimableGb = [math]::Round($diskReclaimableGb, 2)
                }
            }
            catch {
                Write-GiipLog "ERROR" "[CollectDockerMetrics] Failed to run/parse 'docker system df': $_"
            }
        }
    }
}
catch {
    # 예상 밖 오류가 나도 "Docker 없음"으로 취급하고 KVS 업로드는 계속 시도한다
    # (giip 3043 지시: Docker 없는 서버가 대부분이라 이게 정상 경로).
    Write-GiipLog "ERROR" "[CollectDockerMetrics] Unexpected error during Docker detection: $_"
    $dockerInstalled = $false
}

try {
    $payload = @{
        dockerInstalled   = $dockerInstalled
        dockerVersion     = $dockerVersion
        containersRunning = $containersRunning
        containersTotal   = $containersTotal
        imagesCount       = $imagesCount
        diskUsedGb        = $diskUsedGb
        diskReclaimableGb = $diskReclaimableGb
        collectedAt       = (Get-Date).ToUniversalTime().ToString("o")
    }

    Write-GiipLog "INFO" "[CollectDockerMetrics] Uploading Docker resource usage to KVS (Factor: docker_usage)..."
    $kvsResp = Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "docker_usage" -Value $payload

    # giip #3079 (csn 70418 실측): 반환값을 Out-Null로 버리고 무조건 "성공" 로그를
    # 남기던 버그. HTTP 400/500이 와도 로그에는 정상으로 보였다. 반환값의 RstVal을
    # 실제로 확인해서 로그 레벨을 정직하게 고른다.
    if ($kvsResp -and $kvsResp.RstVal -eq "200") {
        Write-GiipLog "INFO" "[CollectDockerMetrics] Successfully collected and uploaded Docker resource usage."
    } else {
        Write-GiipApiFailure -Config $Config -Context "[CollectDockerMetrics] KVS upload (docker_usage)" -Response $kvsResp
    }
}
catch {
    Write-GiipLog "ERROR" "[CollectDockerMetrics] Unexpected error uploading Docker metrics to KVS: $_"
    exit 1
}

exit 0
