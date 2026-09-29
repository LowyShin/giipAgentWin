# ============================================================================
# giipAgentWin Library: Worker Functions
#
# [용도] 구 진입점 giipAgentWin.ps1(상주 무한루프)의 본체. 큐 1건을 받아
#        (Get-QueueItem) 해석·실행하고(Invoke-AgentTask) 결과를 보고한다
#        (Report-TaskResult). 2025-12-08 커밋 1558e27("refactor: Modularize
#        Windows Agent to v2.0 structure")에서 giipAgentWin.ps1 458줄을
#        lib/Common.ps1 + lib/Worker.ps1 로 쪼개며 신설됐다.
#
# [입력]  $Config(hashtable: lssn/sk/apiaddrv2), CQE 큐 원문 문자열
# [처리]  Get-QueueItem: API 'CQEQueueGet lssn hn os sv df' 호출(SP
#           pApiCQEQueueGetbySk) -> 원문 문자열 반환
#         Invoke-AgentTask: 응답이 순수 숫자면 LSSN 갱신(Update-ConfigLssn),
#           아니면 "QSN||TYPE||BODY" 로 분해해 {{sk}}/{{lssn}} 치환 후
#           lib/ScriptRunner.ps1 의 Invoke-ScriptBlock 으로 실행
#         Report-TaskResult: 실행 결과를 KVS 에 적재(출력 500자 절단)
# [저장]  giipdb tKVS (Report-TaskResult)
#           kType   = 'lssn'
#           kKey    = <lssn>
#           kFactor = 'giipAgentLog'
#           kValue  = {"qsn","status":"success|error","output":<500자 이내>}
#         API 커맨드 'KVSPut kType kKey kFactor kValue' -> SP pApiKVSPutbySk
#         로컬 로그: <레포상위>\giipLogs\giipAgentWin_<yyyyMMdd>.log
# [소비처] kFactor='giipAgentLog' 를 **읽는 곳은 현재 없다**.
#          giipv3 src/ 와 giipdb SP/Views/Functions/Tables 전수 검색 결과 SELECT
#          하는 코드는 0건이고, 유일한 매치는 giipdb SP/pAdmCleanTable.sql L113
#          "where kFactor like 'GiipAgentLogs%'" 로 **14일 경과분 DELETE 조건**이다
#          (소비가 아니라 폐기). 같은 파일 L41 주석에 따르면 원본 로그 라인은
#          tAgentLogEntry 테이블이 대체했고 그쪽 소비처는 SP/pApiAgentLogTailByAK.sql
#          / pApiAgentLogTailBySK.sql 이다.
#          확인 명령: rg -n -i "giipagentlog" -g '!node_modules' .   (giipv3, giipdb 각각)
#          ※ CQE 실행 이력을 giipv3 cqelsvrRunList 의 [KVS] 버튼으로 보려면
#            kFactor='giipagent' + kValue.details.mslsn 형태여야 한다(giip-967).
#            그 형식으로 쓰는 것은 lib/ExecutionLog.ps1 의 Save-ExecutionLog 다.
#
# [현재 호출 상태] 이 파일을 dot-source 하는 곳은 giipAgentWin.ps1 L12 하나이고,
#   그 giipAgentWin.ps1 은 Task Scheduler 미등록 + 상주 프로세스 0건이다(실측).
#   - 언제부터: 2025-12-11 커밋 b69abcd 가 TaskSchdReg.ps1 의 등록 대상을
#     giipAgentWin.ps1 -> giipAgent3.ps1 로 바꿨다. 그 이전(2025-08-28 커밋
#     f7f8102 ~ 2025-12-11)에는 giipAgentWin.ps1 이 실제 운영 진입점이었다.
#   - 왜: 상주 루프 방식을 Task Scheduler 5분 주기 단발 실행으로 바꾸면서
#     역할이 giipscripts\modules\CqeGet.ps1(조회) + CqeRun.ps1(실행)으로 갈라졌다.
#     다만 CqeRun.ps1 은 2026-09-15 커밋 f0ebbc5(giip #2546)에서야 추가됐다 -
#     2025-12-11 재설계 때 실행 단계가 이식되지 않은 채 남아 있었다.
#
# [giip #2556 에서 고친 결함]
#   - Get-QueueItem L34 의 Get-SystemInfo, Invoke-AgentTask L121 의
#     Update-ConfigLssn 이 **정의 0건**이었다. 두 함수는 1558e27 에서
#     lib/Common.ps1 에 정의돼 있었으나 2026-04-08 커밋 95a5560 이 Common.ps1 을
#     전면 재작성하며 정의만 없어지고 이 호출부는 그대로 남았다. 즉 2026-04-08
#     이후 giipAgentWin.ps1 은 루프 첫 회차에서 반드시 죽는 상태였다(실측 재현:
#     "The term 'Get-SystemInfo' is not recognized ..."). lib/Common.ps1 에
#     원본 정의를 복원해 해소했다.
#
# 상세 사양: docs/SPEC_UNCALLED_PATHS.md
# ============================================================================

# giip #2546: 실행기는 lib\ScriptRunner.ps1 로 분리됐다(CqeRun.ps1 과 공유).
if (-not (Get-Command Invoke-ScriptBlock -ErrorAction SilentlyContinue)) {
    $__workerScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $__workerRunnerPath = Join-Path $__workerScriptDir "ScriptRunner.ps1"
    if (Test-Path $__workerRunnerPath) { . $__workerRunnerPath }
}

#region ====== Queue Logic ======
function Get-QueueItem {
    param([hashtable]$Config)
    
    $sysInfo = Get-SystemInfo
    $hn = $sysInfo.Hostname
    $os = $sysInfo.OSName
    $sv = "2.0" # Agent Version

    # SP: pApiCQEQueueGetbySk (Implied by Command string context)
    # Command: CQEQueueGet
    # Params: lssn hn os sv df
    $cmdText = "CQEQueueGet lssn hn os sv df"
    
    $payload = @{
        lssn = $Config.lssn
        hn   = $hn
        os   = $os
        sv   = $sv
        df   = "os"
    } | ConvertTo-Json -Compress

    $response = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $payload
    
    # API V2 returns string data (Raw Response)
    # If using Invoke-RestMethod with JSON response type, it might be an object.
    # But usually CQE returns a raw string or JSON wrapped string.
    # Let's assume it returns the raw content body string.
    
    return $response
}

# giip #2546 / #2556: 이 함수는 kFactor='giipAgentLog' 로 KVS 에 쓴다. 그 kFactor
#   를 읽는 곳은 현재 없다(giipv3 src/ 및 giipdb 전수 검색 결과 SELECT 0건,
#   giipdb SP/pAdmCleanTable.sql L113 의 14일 경과분 DELETE 조건만 매치).
#   CQE 실행 이력을 giipv3 cqelsvrRunList 의 [KVS] 버튼에서 보려면
#   kFactor='giipagent' + kValue.details.mslsn 형태여야 하며(giip-967), 그 형식으로
#   쓰는 것은 lib\ExecutionLog.ps1 의 Save-ExecutionLog 다(Linux lib/kvs.sh
#   save_execution_log 와 동일 의미론). 새 코드는 그쪽을 쓴다.
function Report-TaskResult {
    param(
        [hashtable]$Config,
        [string]$Qsn,
        [string]$Status, # success/fail
        [string]$Output
    )
    
    # Truncate Output standard (500 chars)
    $snippet = $Output
    if ($snippet.Length -gt 500) { $snippet = $snippet.Substring(0, 500) }
    
    # Clean JSON string issues if manually built, but ConvertTo-Json handles it.
    
    # SP: pApiKVSPutbySk
    # Command: KVSPut
    # Params: kType kKey kFactor kValue  (kValue 필수 — 표준 시그니처)
    # Ref: giipprj/giipdb/docs/10_Standards/DEVELOPMENT_RULES_INDEX.md (L58, L272)
    #      giipAgentWin 'real' branch lib/Worker.ps1 (정상 기준)
    # 주의: 커밋 121a386이 kValue를 제거(4→3)하여 표준과 어긋났으므로 복원함.
    $cmdText = "KVSPut kType kKey kFactor kValue"
    
    $kValueObj = @{
        qsn    = $Qsn
        status = $Status
        output = $snippet
    }

    $payload = @{
        kType   = "lssn"
        kKey    = $Config.lssn
        kFactor = "giipAgentLog"
        kValue  = $kValueObj # Nested JSON logic often handled by API, but usually passing object here works if server expects JSON
    } | ConvertTo-Json -Compress -Depth 5

    $result = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $payload
    Write-GiipLog "DEBUG" "Report Result: $result"
}
#endregion

#region ====== Execution Logic ======
function Invoke-AgentTask {
    param(
        [string]$RawQueueItem,
        [hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($RawQueueItem)) { return }

    # CASE 1: Numeric (Registration Success/Update)
    if ($RawQueueItem -match '^\d+$') {
        Write-GiipLog "INFO" "Received numeric LSSN update: $RawQueueItem"
        Update-ConfigLssn -NewLssn $RawQueueItem
        $Config.lssn = $RawQueueItem # Update runtime config too
        return
    }

    # CASE 2: Task (QSN||TYPE||BODY)
    $parts = $RawQueueItem -split '\|\|'
    if ($parts.Count -lt 3) {
        Write-GiipLog "WARN" "Invalid queue item format: $RawQueueItem"
        return
    }

    $qsn = $parts[0]
    $type = $parts[1].ToLower()
    $body = $parts[2]

    Write-GiipLog "INFO" "Executing Task QSN=$qsn Type=$type"

    # Replace placeholders
    $body = $body.Replace('{{sk}}', $Config.sk).Replace('{{lssn}}', $Config.lssn)

    # Execute
    $execResult = Invoke-ScriptBlock -Type $type -Body $body
    
    # Report
    $status = if ($execResult.Success) { "success" } else { "error" }
    Report-TaskResult -Config $Config -Qsn $qsn -Status $status -Output $execResult.Output
}

# giip #2546: Invoke-ScriptBlock 은 lib\ScriptRunner.ps1 로 이동했다.
#   - 60초 하드코딩 타임아웃 -> giipAgent.cfg 의 cqetimeoutsec(기본 600초)
#   - stdout 비동기 읽기(파이프 버퍼 교착 제거)
#   - script_type 'cmdui'/'ps1ui'(보이는 콘솔 창) 추가
# 이 파일 상단에서 dot-source 하므로 아래 Invoke-AgentTask 의 호출부는 그대로다.
#endregion

