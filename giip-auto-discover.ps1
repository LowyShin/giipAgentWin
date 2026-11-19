# ============================================================================
# giipAgent Auto-Discovery Integration for Windows
# Runs from Task Scheduler every 6 hours ("GIIP Auto-Discovery (v3)" ->
# giip-auto-discover-launcher.ps1 -> this script).
#
# giip #3559 항목1 — 이 스크립트는 태스크로 등록만 되어 있고 실제로는 한 번도
# 성공한 적이 없다. 원인이 두 개 있었고 둘 다 여기서 고친다.
#  (1) 설정 파일 위치: giipAgent.cfg 는 저장소 루트(giipAgentWin)가 아니라 그
#      상위 폴더에 있다(giipdb/docs/10_Standards/GIIP_CONFIG_FILE_LOCATION.md).
#      예전 코드는 $ScriptDir/giipAgent.cfg 만 찾아 "Configuration file not found"
#      로 종료했다. 종료 지점이 첫 로그 기록보다 앞이어서 로그 파일조차 남지
#      않았다(Task Scheduler 의 "return code 0" 은 conhost.exe 의 exit code).
#      → 저장소 표준 로더(lib/Common.ps1 Get-GiipConfig)를 쓴다.
#  (2) API 호출: 예전 코드는 설정에 없는 키(apiaddr)와 dispatcher 가 읽지 않는
#      쿼리 파라미터(cmd=)를 써서 AK 기반 giipApi 로 갔다. 이제 저장소 표준
#      경로(apiaddrv2 = giipApiSk3, SK 인증)를 쓴다. text 형식("명령어 + 파라미터
#      이름", 값은 jsondata 에서 치환)은 Linux 쪽 giipAgentLinux 의
#      scripts/giip-auto-discover.sh 와 동일하다.
# ============================================================================

# --- Resolve paths and load shared libraries ---------------------------------
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Global:BaseDir = $ScriptDir                                # so Get-GiipConfig finds ../giipAgent.cfg
. (Join-Path $ScriptDir "lib\Common.ps1")   # Get-GiipConfig, Update-ConfigLssn, Invoke-GiipApiV2, Write-GiipLog
# lib/Common.ps1 은 $ErrorActionPreference = "Stop" 으로 바꾼다. 이 스크립트는
# 원래(Continue) 동작을 유지한다 — 자동탐색 중 개별 명령 실패가 수집 전체를
# 중단시키지 않고, 마지막 catch 에서 로그를 남기고 종료해야 하기 때문이다.
$ErrorActionPreference = "Continue"

# --- Persistent run log (태스크 스케줄러 진단용) -----------------------------
$AGENT_VERSION = "1.72"
$LogDir = Join-Path $ScriptDir "..\giipLogs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$LogFile = Join-Path $LogDir ("giip-auto-discover_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

function Write-AgentLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] $Message"
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
    Write-GiipLog "INFO" $Message
}

try {
    # --- Load configuration --------------------------------------------------
    # giip #3559: 설정 파일은 상위 폴더(%USERPROFILE%, 저장소 루트 순으로 폴백)를
    # 검색한다. 실패해도 로그를 남긴다 — 예전에는 로그 기록 전에 exit 해서
    # "동작 안 함" 의 원인이 남지 않았다.
    $Config = Get-GiipConfig
    if (-not $Config -or -not $Config['sk']) {
        Write-AgentLog "ERROR: giipAgent.cfg 를 찾지 못했다 (검색 순서: 상위 폴더 -> %USERPROFILE% -> 저장소 루트)."
        exit 1
    }

    $sk = $Config['sk']
    $lssn = $Config['lssn']
    Write-AgentLog "Config loaded. lssn=$lssn apiaddrv2=$($Config['apiaddrv2'])"

    # --- Run discovery and capture JSON --------------------------------------
    $DiscoveryScript = Join-Path $ScriptDir "giipscripts\auto-discover-win.ps1"

    if (-not (Test-Path $DiscoveryScript)) {
        Write-AgentLog "ERROR: Discovery script not found: $DiscoveryScript"
        exit 1
    }

    Write-AgentLog "Starting auto-discovery..."

    $DiscoveryJson = & $DiscoveryScript
    $DiscoverExitCode = $LASTEXITCODE

    # 주의: PowerShell 스크립트가 exit 없이 끝나면 $LASTEXITCODE 는 설정되지 않는다
    # (신규 프로세스에서는 $null). 그래서 null 을 "실패" 로 보면 안 된다.
    if ($null -ne $DiscoverExitCode -and $DiscoverExitCode -ne 0) {
        Write-AgentLog "ERROR: Discovery script failed with exit code $DiscoverExitCode"
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($DiscoveryJson)) {
        Write-AgentLog "ERROR: Discovery script produced no output."
        exit 1
    }

    # Save to temp file for debugging
    $TempJsonFile = Join-Path $env:TEMP "giip-discovery-$PID.json"
    $DiscoveryJson | Out-File -FilePath $TempJsonFile -Encoding UTF8

    Write-AgentLog "Discovery data saved to: $TempJsonFile"

    # Parse JSON to object and add agent_version
    $DiscoveryObj = $DiscoveryJson | ConvertFrom-Json
    $DiscoveryObj | Add-Member -NotePropertyName "agent_version" -NotePropertyValue $AGENT_VERSION -Force

    # Convert back to JSON (compact)
    $FinalJson = $DiscoveryObj | ConvertTo-Json -Depth 10 -Compress

    # --- Call API (Azure Function) -------------------------------------------
    # 저장소 표준 경로: apiaddrv2 = giipApiSk3 (SK 인증).
    # text 는 "명령어 + 파라미터 이름" 이고 실제 값은 jsondata 에서 치환된다
    # (giipfaw/giipApiSk3/run.ps1 의 Single-pass replacement).
    $ApiResult = Invoke-GiipApiV2 -Config $Config -CommandText "AgentAutoRegister hostname jsondata" -JsonData $FinalJson

    if (-not $ApiResult) {
        Write-AgentLog "ERROR: AgentAutoRegister API 호출 실패 (응답 없음)."
        exit 1
    }

    $ApiJson = $ApiResult | ConvertTo-Json -Depth 5 -Compress
    Write-AgentLog "API response: $ApiJson"

    # 성공 판정 — SP 가 Proc_MSG='200|...' 와 RstVal=200 으로 돌려준다.
    $IsSuccess = (($ApiResult.Proc_MSG -like '200|*') -or ($ApiResult.RstVal -eq '200'))
    if (-not $IsSuccess) {
        Write-AgentLog "ERROR: AgentAutoRegister API 응답이 실패를 나타낸다: $ApiJson"
        exit 1
    }

    Write-AgentLog "SUCCESS: $($ApiResult.Proc_MSG) (lssn=$($ApiResult.lssn), action=$($ApiResult.action))"

    # Extract lssn from response if this is first registration
    if ($lssn -eq "0" -and $ApiResult.lssn) {
        $NewLssn = $ApiResult.lssn
        Write-AgentLog "Received LSSN: $NewLssn"

        # Update config file (저장소 표준 헬퍼 — ../giipAgent.cfg 또는 %USERPROFILE%)
        Update-ConfigLssn -NewLssn $NewLssn

        Write-AgentLog "Updated giipAgent.cfg with LSSN: $NewLssn"
    }

    # Cleanup
    if (Test-Path $TempJsonFile) {
        Remove-Item $TempJsonFile -Force
    }

    Write-AgentLog "Auto-discovery completed successfully"
    exit 0
}
catch {
    Write-AgentLog "ERROR: $_"
    Write-AgentLog "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
