# ============================================================================
# giipAgentWin Library: Worker Functions
# Purpose: Queue Processing, Task Execution, and Result Reporting
#
# ⚠️ giip #2546 - 이 파일 전체가 현재 **죽은 경로**다.
#    유일한 호출자는 구 진입점 giipAgentWin.ps1 의 무한루프인데, Task Scheduler
#    에 등록된 작업은 'GIIP Agent Task (v3)' 하나뿐이고 그 액션은
#    giipAgent3.ps1 이다(실측: 상주 프로세스 0건). lib/Cqe.ps1 의 Get-Queue,
#    scripts/NormalMode.ps1, lib/Discovery.ps1 도 같은 이유로 도달 불가다.
#    운영 경로는 giipAgent3.ps1 -> giipscripts\modules\CqeGet.ps1 ->
#    giipscripts\modules\CqeRun.ps1 이다.
#
#    실제 실행 로직(Invoke-ScriptBlock)은 CqeRun.ps1 이 재사용할 수 있도록
#    lib\ScriptRunner.ps1 로 옮겼다. 이 파일은 그것을 dot-source 하므로 구
#    경로의 동작(giipAgentWin.ps1 을 수동으로 띄우는 경우)은 변하지 않는다.
#
#    이 파일 / lib\Cqe.ps1 / giipAgentWin.ps1 / scripts\NormalMode.ps1 /
#    lib\Discovery.ps1 은 **정리(삭제) 후보**다. 다만 이번 이슈 범위에서는
#    지우지 않고 후속 이슈로 올린다(운영 중인 에이전트 경로를 고치는 변경과
#    삭제를 한 PR 에 섞지 않기 위함).
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

# ⚠️ giip #2546: 이 함수는 kFactor='giipAgentLog' 로 KVS 에 쓴다. 그런데 giipv3
#    어느 화면도 그 kFactor 를 읽지 않는다(실측: cqelsvrRunList 의 [KVS] 버튼은
#    /kvslist?kKey=<lssn>&kFactor=giipagent&mslsn=<mslsn> 로 이동하고, kvslist 는
#    kValue.details.mslsn 으로 필터링한다 - giip-967).
#    따라서 CQE 실행 이력의 **정본은 lib\ExecutionLog.ps1 의 Save-ExecutionLog**
#    (kFactor='giipagent', Linux lib/kvs.sh save_execution_log 와 동일 의미론)이며,
#    이 함수는 죽은 경로에 남은 레거시다. 새 코드에서 쓰지 말 것.
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

