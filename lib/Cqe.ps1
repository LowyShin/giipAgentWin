
# ============================================================================
# giipAgent CQE (Centralized Queue Engine) Library (PowerShell)
# Version: 1.00
#
# [용도] CQE 큐 조회 API 의 얇은 래퍼. 2025-12-10 커밋 ef30c46("giipAgent3.ps1
#        신규 작성")에서 scripts\NormalMode.ps1 이 쓸 조회 함수로 도입됐다.
#        Linux 에이전트의 큐 조회 로직을 PowerShell 로 옮긴 것이다(파일 안
#        주석의 'Linux agent uses detect_os' 등이 그 흔적).
#
# [입력]  $Config(hashtable: lssn/sk/apiaddrv2), $Hostname(string)
# [처리]  API 커맨드 'CQEQueueGet lssn hostname os op'(os 는 "windows" 고정)를
#         Invoke-GiipApiV2 로 호출 -> SP pApiCQEQueueGetbySk ->
#         내부적으로 pCQEQueueGetbySK02. RstVal 이 200 이 아니고 404/0 계열이면
#         "큐 없음"으로 보고 $null 을 돌려준다(그 외는 ERROR 로그 후 $null).
# [출력]  큐에 실을 스크립트 본문(ms_body) 문자열 1건, 또는 $null.
# [저장]  이 파일 자체는 아무것도 저장하지 않는다(조회 전용). 저장은 호출자인
#         scripts\NormalMode.ps1 이 Save-ExecutionLog 로 수행한다
#         (tKVS, kType='lssn', kFactor='giipagent').
#         조회 실패 시 로컬 로그만 남는다:
#         <레포상위>\giipLogs\giipAgentWin_<yyyyMMdd>.log
# [소비처] 반환값의 소비처는 scripts\NormalMode.ps1 L50 뿐이다. giipv3 화면이
#          직접 읽는 산출물은 없다. 참고로 'CQEQueueGet' 은 에이전트 전용 API 라
#          giipv3 src/ 안의 호출부도 0건이다(문서/스킬 파일에만 등장:
#          public/skills/giip-agent/references/api.md 등).
#          확인 명령: rg -n "CQEQueueGet" -g '!node_modules' .   (giipv3, giipdb 각각)
#
# [현재 호출 상태] 이 파일을 dot-source 하는 곳은 scripts\NormalMode.ps1 L23
#   하나이고, 그 NormalMode.ps1 을 기동하는 곳은 0건이다.
#   - 언제부터: 도입 다음날인 2025-12-11 커밋 b69abcd 의 v3 재설계부터.
#   - 왜: 같은 역할을 giipscripts\modules\CqeGet.ps1 이 맡았다. 다만 동일하지는
#     않다 - CqeGet.ps1 은 mslsn/mssn/script_type/ms_body 를 data/queue.json 에
#     보존하는 반면, 이 파일의 Get-Queue 는 ms_body 문자열 하나만 돌려주므로
#     실행 이력을 mslsn 으로 추적하는 giip-967 형식을 만들 수 없다.
#
# [알려진 동작 특성 - giip #2556 조사, 수정하지 않음]
#   L57 의 "$response.data -and $response.data.Count -gt 0" 분기는 실제로는
#   타지 않는다. lib/Common.ps1 의 Invoke-GiipApiV2 가 이미 $response.data[0] 로
#   한 겹 벗겨서 돌려주기 때문이다(giip-issue #922 의 -RawList 스위치 참고).
#   현재는 바로 아래 "elseif ($response.RstVal)" 폴백이 받아내므로 동작에는
#   문제가 없어 이번 이슈에서는 건드리지 않았다. 다만 응답에 RstVal 이 없는
#   형태가 오면 "invalid structure" 로 빠지므로, 되살릴 때 확인이 필요하다.
#
# 상세 사양: docs/SPEC_UNCALLED_PATHS.md
# ============================================================================

if (-not (Get-Command Invoke-GiipApiV2 -ErrorAction SilentlyContinue)) {
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $commonPath = Join-Path $scriptDir "Common.ps1"
    if (Test-Path $commonPath) { . $commonPath }
}

# Function: Fetch queue from API
# Returns: script content (string) or $null if no queue or error
function Get-Queue {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Hostname
    )

    $lssn = $Config.lssn
    # Determine OS string specifically for API
    # Linux agent uses 'detect_os', returns e.g. 'centos', 'ubuntu', 'windows' (?)
    # Let's use 'windows' generic or specific version.
    $os = "windows" 
    
    $text = "CQEQueueGet lssn hostname os op"
    $jsondata = @{
        lssn     = $lssn
        hostname = $Hostname
        os       = $os
        op       = "op"
    } | ConvertTo-Json -Compress

    $response = Invoke-GiipApiV2 -Config $Config -CommandText $text -JsonData $jsondata

    if (-not $response) {
        Write-GiipLog "WARN" "CQEQueueGet API call failed or returned null"
        return $null
    }

    # Analyze Response
    # Structure: { data: [ { RstVal: "200", ms_body: "...", ... } ] } or direct keys
    
    $data = $null
    if ($response.data -and $response.data.Count -gt 0) {
        $data = $response.data[0]
    }
    elseif ($response.RstVal) {
        $data = $response
    }

    if (-not $data) {
        Write-GiipLog "WARN" "CQEQueueGet response invalid structure"
        return $null
    }

    $rstVal = $data.RstVal
    
    # Check 404/No Queue
    if ($rstVal -ne "200") {
        # Check if it's a 404-like response
        # Linux logic: proc_name *404* or rst_val *404* or 0
        $procName = $data.ProcName
        if ($rstVal -match "404" -or $procName -match "404" -or $rstVal -eq "0") {
            # This is normal (No Queue)
            return $null
        }
        
        Write-GiipLog "ERROR" "CQEQueueGet returned error: RstVal=$rstVal, ProcName=$procName"
        return $null
    }

    $scriptBody = $data.ms_body
    return $scriptBody
}

