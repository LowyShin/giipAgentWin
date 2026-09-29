
# ============================================================================
# giipAgent Discovery Library (PowerShell)
# Version: 1.01
#
# [용도] 6시간 주기로 인프라 자동탐색(auto-discovery)을 실행하고 그 결과 JSON 을
#        KVS 에 적재한다. 2025-12-10 커밋 ef30c46("giipAgent3.ps1 신규 작성")에서
#        giipAgent3 의 1차 설계 일부로 도입됐다.
#
# [입력]  $Config(hashtable, Get-GiipConfig 결과: lssn/sk/apiaddrv2 등)
#         상태파일 %TEMP%\giip_discovery_state_<lssn>.txt (마지막 실행 epoch 초)
# [처리]  간격 미달이면 스킵 -> giipscripts\auto-discover-win.ps1 실행 ->
#         stdout 을 JSON 으로 검증 -> 압축(-Compress) 후 KVS 적재 -> 상태파일 갱신
# [저장]  giipdb tKVS
#           kType   = 'lssn'
#           kKey    = <lssn>
#           kFactor = 'auto_discover_result'
#           kValue  = auto-discover-win.ps1 의 전체 JSON(Depth 10, Compress)
#         API 커맨드 'KVSPut kType kKey kFactor kValue' -> SP pApiKVSPutbySk
# [소비처] giipdb SP/pApiInfrastructureDetailbyAK.sql L41
#            "AND kFactor = 'auto_discover_result'" (최근 7일, TOP 1) ->
#          API 'InfrastructureDetail lssn' ->
#          giipv3 src/app/[locale]/infrastructure-detail/page.tsx L111
#            (Infrastructure Detail 화면)
#          ※ giipv3 소스에는 'auto_discover_result' 리터럴이 0건이다. 화면은
#            kFactor 를 모른 채 SP 를 통해 간접 소비한다.
#          확인 명령: rg -n -i "auto_discover_result" -g '!node_modules' .  (giipv3/giipdb 각각)
#
# [현재 호출 상태] 이 파일을 dot-source 하는 곳 0건, Invoke-Discovery 호출처 0건.
#   - 언제부터: 도입 다음날인 2025-12-11 커밋 b69abcd("feat: Implement Windows
#     Agent v3 modular architecture (CleanState, CqeGet, Orchestrator)")가
#     giipAgent3.ps1 을 giipscripts\modules\ 호출 구조로 재작성하면서, 이 파일을
#     부르는 경로가 새 구조에 포함되지 않았다.
#   - 왜: 자동탐색 기능 자체는 폐기되지 않았고 별도 경로로 살아 있다 —
#     루트의 giip-auto-discover.ps1 이 같은 giipscripts\auto-discover-win.ps1 을
#     실행해 'AgentAutoRegister' API(SP pApiAgentAutoRegisterBySK)로 보내며,
#     그 SP 가 tKVS 의 같은 kFactor='auto_discover_result' 행을 MERGE 로 갱신한다
#     (giipdb SP/pApiAgentAutoRegisterBySK.sql L194-196, L324-326).
#     즉 이 파일은 "KVSPut 직접 적재" 변형이고, 운영은 "AgentAutoRegister 경유"
#     변형을 쓴다. 어느 쪽을 정본으로 할지는 아직 문서로 정리된 근거가 없다.
#
# [giip #2556 에서 고친 결함] 이 파일은 호출되지 않는 동안 결함 4건을 숨기고 있었다.
#   (1) Send-KVSPut 정의 0건 -> Invoke-GiipKvsPut 으로 교정(파라미터명도 다름).
#       2025-12-14 커밋 bc813d8 이 lib/Kvs.ps1 을 재작성하며 개명했는데 호출부가
#       따라가지 않았다.
#   (2) Save-ExecutionLog 를 3곳에서 호출하면서 lib/ExecutionLog.ps1 dot-source 0건
#       -> 아래에서 로드하도록 교정. (정의 자체도 bc813d8 에서 함께 사라졌다가
#       giip #2546 에서 lib/ExecutionLog.ps1 로 복원됨)
#   (3) 함수 **내부**에서 $MyInvocation.MyCommand.Path 사용 -> PS 5.1 에서 함수
#       스코프의 그 값은 $null 이라 Split-Path 가 ParameterBindingValidationException
#       을 던진다(실측). $PSScriptRoot 로 교정.
#   (4) 로드 가드가 Send-KVSPut 존재 여부를 봐서 Kvs.ps1 이 로드돼 있어도 매번
#       다시 dot-source 했다 -> 실제 정의명 Invoke-GiipKvsPut 으로 교정.
#
# 상세 사양: docs/SPEC_UNCALLED_PATHS.md
# ============================================================================

# giip #2556: 가드가 보던 Send-KVSPut 은 이 레포에 정의가 없다(실제 정의는
# lib/Kvs.ps1 의 Invoke-GiipKvsPut). 실제 이름으로 교정한다.
if (-not (Get-Command Invoke-GiipKvsPut -ErrorAction SilentlyContinue)) {
    $__discScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $kvsPath = Join-Path $__discScriptDir "Kvs.ps1"
    if (Test-Path $kvsPath) { . $kvsPath }
}

# giip #2556: Save-ExecutionLog 를 아래에서 3번 호출하는데 이 파일은 그 정의를
# 로드한 적이 없었다(호출 3건 / dot-source 0건). lib/ExecutionLog.ps1 을 로드한다.
if (-not (Get-Command Save-ExecutionLog -ErrorAction SilentlyContinue)) {
    $__discScriptDir2 = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $__execLogPath = Join-Path $__discScriptDir2 "ExecutionLog.ps1"
    if (Test-Path $__execLogPath) { . $__execLogPath }
}

$DISCOVERY_INTERVAL_SEC = 21600 # 6 hours

function Invoke-Discovery {
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $lssn = $Config.lssn
    # giip #2556: 함수 스코프에서 $MyInvocation.MyCommand.Path 는 $null 이라
    # Split-Path 가 "Cannot bind argument to parameter 'Path' because it is null."
    # 로 죽는다(PS 5.1 실측). 스크립트 파일 위치는 $PSScriptRoot 로 얻는다.
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Module.Path -Parent }
    # Assume lib is at root/lib, scripts at root/giipscripts
    $baseDir = Split-Path -Path $scriptDir -Parent
    
    $discoveryScript = Join-Path $baseDir "giipscripts\auto-discover-win.ps1"
    $stateFile = Join-Path $env:TEMP "giip_discovery_state_$lssn.txt"

    # 1. Check Interval
    $shouldRun = $true
    if (Test-Path $stateFile) {
        $lastRun = [int64](Get-Content $stateFile)
        $now = [int64](Get-Date -UFormat %s)
        if (($now - $lastRun) -lt $DISCOVERY_INTERVAL_SEC) {
            $shouldRun = $false
        }
    }

    if (-not $shouldRun) {
        Write-GiipLog "INFO" "Discovery skipped (Interval not reached)"
        return
    }

    # 2. Check Script
    if (-not (Test-Path $discoveryScript)) {
        Write-GiipLog "ERROR" "Discovery script not found: $discoveryScript"
        # Log error to KVS
        Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ type = "discovery"; msg = "Script not found" }
        return
    }

    Write-GiipLog "INFO" "Starting Discovery..."
    
    # 3. Execute Script
    try {
        # Execute and capture JSON output
        $jsonResult = & $discoveryScript
        
        # Validate JSON
        try {
            $jsonObj = $jsonResult | ConvertFrom-Json
        }
        catch {
            Write-GiipLog "ERROR" "Discovery script output invalid JSON"
            Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ type = "discovery"; msg = "Invalid JSON" }
            return
        }
        
        # 4. Save to KVS
        # We save the full result. Linux splits it, but KVS supports large JSON in kValue preferably.
        # Linux `collect_infrastructure_data` saves `auto_discover_result` (full json).
        
        # Compress JSON for transport
        $jsonString = $jsonObj | ConvertTo-Json -Depth 10 -Compress
        
        # giip #2556: Send-KVSPut 은 이 레포에 정의가 없다. 2025-12-14 커밋
        # bc813d8 이 lib/Kvs.ps1 재작성 때 Invoke-GiipKvsPut 으로 개명했는데 이
        # 호출부만 갱신되지 않았다. 실제 시그니처(-Type/-Key/-Factor/-Value)로 교정.
        # giip #3079: 반환값을 확인하지 않고 무조건 "completed and saved" 로 남기던
        # 버그. RstVal을 실제로 확인한다.
        $discResp = Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$lssn" -Factor "auto_discover_result" -Value $jsonString

        if ($discResp -and $discResp.RstVal -eq "200") {
            # Update State
            [int64](Get-Date -UFormat %s) | Set-Content $stateFile
            Write-GiipLog "INFO" "Discovery completed and saved."
        } else {
            Write-GiipApiFailure -Config $Config -Context "[Discovery] auto_discover_result KVS put" -Response $discResp
            Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ type = "discovery"; msg = "KVS put failed"; rstVal = $(if ($discResp) { $discResp.RstVal } else { $null }) }
        }

    }
    catch {
        Write-GiipLog "ERROR" "Discovery execution failed: $_"
        Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ type = "discovery"; msg = $_.Exception.Message }
    }
}

