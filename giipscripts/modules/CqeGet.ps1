# ============================================================================
# CqeGet.ps1 (Restored Pure ASCII Version)
# Purpose: Fetch task from CQE API and save to data/queue.json
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"
$DataDir = Join-Path $AgentRoot "data"
$QueueFile = Join-Path $DataDir "queue.json"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
} catch {
    Write-Host "FATAL: Failed to load Common.ps1"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
} catch {
    Write-Host "FATAL: Failed to load configuration"
    exit 1
}

Write-GiipLog "INFO" "[CqeGet] Starting... LSSN=$($Config.lssn)"

# Prepare generic Windows info
$hostname = [System.Net.Dns]::GetHostName()
$os = "windows " + [System.Environment]::OSVersion.Version.ToString()

# Prepare API Call
$jsondata = @{
    lssn     = $Config.lssn
    hostname = $hostname
    os       = $os
    op       = "op"
} | ConvertTo-Json -Compress

Write-GiipLog "INFO" "[CqeGet] Fetching queue..."

try {
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "CQEQueueGet lssn hostname os op" -JsonData $jsondata
    
    if (-not $response) {
        Write-GiipLog "INFO" "[CqeGet] No response."
        exit 0
    }

    $data = $null
    if ($response.data) {
        if ($response.data.Count -gt 0) { $data = $response.data[0] }
    } elseif ($response.RstVal) {
        $data = $response
    }
    
    if (-not $data) {
        Write-GiipLog "INFO" "[CqeGet] No valid data in response."
        exit 0
    }

    # 404 = No Queue
    if ($data.RstVal -ne "200") {
        if ("$($data.RstVal)" -match "404") {
            Write-GiipLog "INFO" "[CqeGet] Queue empty."
            exit 0
        }
        Write-GiipLog "WARN" "[CqeGet] API Error: $($data.RstVal)"
        exit 0
    }

    # giip #2546: 예전에는 여기서 -Encoding ASCII 로 저장했다("ASCII format for
    # absolute stability"). 그런데 **PowerShell 5.1 의 ConvertTo-Json 은 비ASCII
    # 문자를 \uXXXX 로 이스케이프하지 않는다**(실측: @{t="한글 테스트"} |
    # ConvertTo-Json -Compress -> {"t":"한글 테스트"}). 따라서 ASCII 로 쓰는 순간
    # 한글/일본어/중국어가 전부 '?' 로 치환돼 **스크립트 본문이 파괴**됐다.
    #
    # 실측(2026-09-15, mslsn=8045): 본문
    #   Write-Host "[giip #2546] CQE 실행기 라이브 검증 - 한글 출력 OK"
    # 가 에이전트에서
    #   [giip #2546] CQE ??? ??? ?? - ?? ?? OK
    # 로 실행됐다(글자 수까지 정확히 일치 = ASCII 치환이 원인).
    #
    # UTF-8 로 저장한다. 읽는 쪽(giipscripts\modules\CqeRun.ps1)은 이미
    # Get-Content -Encoding UTF8 로 읽으므로 BOM 도 문제되지 않는다.
    Write-GiipLog "INFO" "[CqeGet] Task received! Saving to $QueueFile"
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $QueueFile -Encoding UTF8
} catch {
    Write-GiipLog "ERROR" "[CqeGet] Failed: $_"
    exit 1
}

exit 0
