# ============================================================================
# CqeRun.ps1 (giip #2546 신규)
# Purpose: CqeGet.ps1 이 data/queue.json 에 저장해 둔 CQE 작업을 실제로 실행한다.
#
# 배경(버그):
#   giipAgent3.ps1 의 Step 2(CqeGet)는 CQEQueueGet 응답을 data/queue.json 에
#   저장만 하고 끝났고, 그 파일을 읽어 실행하는 코드가 giipAgent3 경로 어디에도
#   없었다. 게다가 Step 1(CleanState)이 매 실행 서두에 queue.json 을 지운다.
#   결과적으로 5분마다 큐를 하나씩 소비(서버측 send_flag 는 전송 완료로 바뀜)
#   하면서 아무것도 실행하지 않는 상태가 몇 달간 지속됐다.
#   실행 로직(Invoke-AgentTask/Invoke-ScriptBlock)은 Task Scheduler 에 등록되지
#   않은 구 진입점 giipAgentWin.ps1 쪽에만 있었다 = 이식 누락.
#
# 의미론 기준: giipAgentLinux lib/normal.sh 의 run_normal_mode()/execute_script().
#   - 타입별 인터프리터로 실행
#   - {"script_type","exit_code","execution_time_seconds","mslsn","mssn"} 을
#     실행 이력(save_execution_log "script_execution")으로 남김
#
# 중요: **큐는 같은 실행 안에서 소비한다.** 실행 전에 queue.json 을
#   data/queue_last.json 으로 옮겨 놓기 때문에, 이 스크립트가 도중에 죽어도
#   다음 회차 CleanState 가 "실행되지 않은 큐"를 조용히 지워 유실시키는 창이
#   남지 않는다(= 이번 버그가 몇 달간 조용했던 구조 자체를 없앤다).
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"
$DataDir = Join-Path $AgentRoot "data"
$QueueFile = Join-Path $DataDir "queue.json"
$QueueArchiveFile = Join-Path $DataDir "queue_last.json"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "Kvs.ps1")
    . (Join-Path $LibDir "ExecutionLog.ps1")
    . (Join-Path $LibDir "ScriptRunner.ps1")
} catch {
    Write-Host "FATAL: [CqeRun] Failed to load libraries: $_"
    exit 1
}

# 큐가 없으면 조용히 끝낸다(대부분의 실행이 이 경로다).
if (-not (Test-Path $QueueFile)) {
    Write-GiipLog "INFO" "[CqeRun] No queue file. Nothing to run."
    exit 0
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config -or -not $Config.lssn) { throw "Config is empty or lssn missing" }
} catch {
    Write-GiipLog "ERROR" "[CqeRun] Failed to load configuration: $_"
    exit 1
}

# ---------------------------------------------------------------------------
# 1) 큐 파일을 읽고 즉시 소비(아카이브로 이동)한다.
# ---------------------------------------------------------------------------
$queue = $null
try {
    $raw = Get-Content -Path $QueueFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "queue.json is empty" }
    $queue = $raw | ConvertFrom-Json
} catch {
    Write-GiipLog "ERROR" "[CqeRun] Failed to parse queue.json: $($_.Exception.Message)"
    try { Remove-Item $QueueFile -Force -ErrorAction Stop } catch {}
    Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{
        error_type    = "queue_parse"
        error_message = "Failed to parse queue.json"
        context       = "cqe_run"
    } | Out-Null
    exit 1
}

# 실행 전에 소비한다. 실패해도 재실행하지 않는다(Linux 도 동일 - 큐는 이미
# 서버측에서 send_flag=1 로 소비된 상태라 재시도는 중복 실행이 된다).
try {
    Move-Item -Path $QueueFile -Destination $QueueArchiveFile -Force -ErrorAction Stop
} catch {
    Write-GiipLog "WARN" "[CqeRun] Failed to archive queue.json ($($_.Exception.Message)) - deleting instead."
    try { Remove-Item $QueueFile -Force -ErrorAction SilentlyContinue } catch {}
}

# ---------------------------------------------------------------------------
# 2) ui 타입이 남긴 임시 스크립트 파일 청소(하루 이상 지난 것만).
#    ui 실행은 fire-and-forget 이라 ScriptRunner 가 임시파일을 지울 수 없다.
# ---------------------------------------------------------------------------
try {
    $cutoff = (Get-Date).AddDays(-1)
    Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter "giip_task_*" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
} catch {}

# ---------------------------------------------------------------------------
# 3) 실행
# ---------------------------------------------------------------------------
# giip #2546: CQEQueueGet 이 돌려주는 script_type 은 tMgmtScript.msType 사본이라
# '.ps1'(앞에 점) / 'bat' / 빈 값 같은 변형이 실제로 섞여 있다(lssn=71197 실측).
# 정규화는 lib\ScriptRunner.ps1 의 ConvertTo-GiipScriptType 이 담당한다.
$rawScriptType = "$($queue.script_type)"
$scriptType = ConvertTo-GiipScriptType -RawType $rawScriptType
$msBody = [string]$queue.ms_body
$mslsn = $queue.mslsn
$mssn = $queue.mssn

if ([string]::IsNullOrWhiteSpace($msBody)) {
    Write-GiipLog "WARN" "[CqeRun] Empty ms_body (mslsn=$mslsn mssn=$mssn). Nothing to execute."
    Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{
        error_type    = "empty_body"
        error_message = "Empty ms_body"
        context       = "cqe_run"
        mslsn         = $mslsn
        mssn          = $mssn
    } | Out-Null
    exit 0
}

# 플레이스홀더 치환 - lib/Worker.ps1 의 Invoke-AgentTask 와 동일하게 유지한다.
$msBody = $msBody.Replace('{{sk}}', "$($Config.sk)").Replace('{{lssn}}', "$($Config.lssn)")

# 헤드리스 타임아웃(초). giipAgent.cfg 의 'cqetimeoutsec' -> 없으면 600.
# (실 cfg 파일은 git 밖에 있으므로 키가 없어도 동작해야 한다.)
$timeoutSec = $Global:GiipCqeDefaultTimeoutSec
if ($Config['cqetimeoutsec']) {
    $parsed = 0
    if ([int]::TryParse("$($Config['cqetimeoutsec'])".Trim(), [ref]$parsed) -and $parsed -gt 0) {
        $timeoutSec = $parsed
    } else {
        Write-GiipLog "WARN" "[CqeRun] Invalid cqetimeoutsec='$($Config['cqetimeoutsec'])' - falling back to ${timeoutSec}s."
    }
}

# giip #4296: stdout/stderr 꼬리 전송 용량(KB). giipAgent.cfg 의 'cqeoutputtailkb'
# -> 없으면 기본 8KB. 0 이면 cqeresult 출력 전송을 생략한다(§5.7.2-2).
$outputTailKb = 8
if ($null -ne $Config['cqeoutputtailkb'] -and "$($Config['cqeoutputtailkb'])".Trim() -ne '') {
    $parsedKb = -1
    if ([int]::TryParse("$($Config['cqeoutputtailkb'])".Trim(), [ref]$parsedKb) -and $parsedKb -ge 0) {
        $outputTailKb = $parsedKb
    } else {
        Write-GiipLog "WARN" "[CqeRun] Invalid cqeoutputtailkb='$($Config['cqeoutputtailkb'])' - falling back to ${outputTailKb}KB."
    }
}

if (-not (Get-GiipScriptTypeInfo -Type $scriptType)) {
    Write-GiipLog "ERROR" "[CqeRun] Unsupported script_type='$rawScriptType' (normalized='$scriptType', mslsn=$mslsn mssn=$mssn)."
    Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{
        error_type    = "unsupported_script_type"
        error_message = "Unsupported script_type: $rawScriptType (normalized: $scriptType)"
        context       = "cqe_run"
        script_type   = $rawScriptType
        mslsn         = $mslsn
        mssn          = $mssn
    } | Out-Null
    exit 1
}

Write-GiipLog "INFO" "[CqeRun] Executing CQE task mslsn=$mslsn mssn=$mssn script_type=$scriptType (raw='$rawScriptType') timeout=${timeoutSec}s"

$startTime = Get-Date
$execResult = Invoke-ScriptBlock -Type $scriptType -Body $msBody -TimeoutSec $timeoutSec
$endTime = Get-Date
$durationSec = [int][Math]::Round(($endTime - $startTime).TotalSeconds)
$startTimeStr = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
$endTimeStr = $endTime.ToString("yyyy-MM-dd HH:mm:ss")

$outputSnippet = "$($execResult.Output)"
if ($outputSnippet.Length -gt 2000) { $outputSnippet = $outputSnippet.Substring(0, 2000) }

if ($execResult.Success) {
    Write-GiipLog "INFO" "[CqeRun] Completed mslsn=$mslsn exit_code=$($execResult.ExitCode) duration=${durationSec}s mode=$($execResult.Mode)"
} else {
    Write-GiipLog "ERROR" "[CqeRun] Failed mslsn=$mslsn exit_code=$($execResult.ExitCode) duration=${durationSec}s mode=$($execResult.Mode)"
}
if ($outputSnippet.Trim()) {
    Write-GiipLog "INFO" "[CqeRun] Output: $outputSnippet"
}

# ---------------------------------------------------------------------------
# 4) 실행 이력 기록 (Linux save_execution_log "script_execution" 과 동등)
#    ui 타입은 stdout/종료코드를 알 수 없으므로 exit_code 는 "기동 성공 여부"의
#    의미만 갖는다 - details.mode='ui' 로 구분 가능하게 남긴다.
# ---------------------------------------------------------------------------
Save-ExecutionLog -Config $Config -EventType "script_execution" -DetailsObj @{
    script_type            = $scriptType
    exit_code              = $execResult.ExitCode
    execution_time_seconds = $durationSec
    mslsn                  = $mslsn
    mssn                   = $mssn
    mode                   = $execResult.Mode
    success                = [bool]$execResult.Success
    output                 = $outputSnippet
} | Out-Null

# ---------------------------------------------------------------------------
# 4b) giip #4296: 콘솔 조회 정본인 cqeresult 행을 병행 기록한다(위 giipagent
#     이벤트는 호환을 위해 그대로 둔다). stdout/stderr 를 분리해 각각 마지막
#     $outputTailKb KB 만 보낸다. 장애 원인은 대개 출력 끝부분에 있기 때문이다.
#     $outputTailKb=0 이면 출력 전송을 생략한다(§5.7.2-2).
#
#     ui 타입/타임아웃/에러 경로는 StdOut/StdErr 가 없으므로 합본 Output 을
#     stdout 쪽에 넣어 유실되지 않게 한다(stderr 는 빈 값).
# ---------------------------------------------------------------------------
function Get-GiipTail {
    param([string]$Text, [int]$TailKb)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $maxChars = $TailKb * 1024
    if ($Text.Length -le $maxChars) { return $Text }
    return $Text.Substring($Text.Length - $maxChars)
}

if ($outputTailKb -gt 0) {
    if ($null -ne $execResult.StdOut -or $null -ne $execResult.StdErr) {
        $stdoutRaw = "$($execResult.StdOut)"
        $stderrRaw = "$($execResult.StdErr)"
    } else {
        # 분리 캡처가 없는 경로(ui/timeout/error): 합본을 stdout 으로 보존.
        $stdoutRaw = "$($execResult.Output)"
        $stderrRaw = ""
    }

    $cqeStatus = if ($execResult.Mode -eq 'ui') { "started" }
                 elseif ($execResult.Success) { "success" }
                 elseif ($execResult.ExitCode -eq -1) { "failed" }
                 else { "failed" }

    Save-CqeResult -Config $Config `
        -Mslsn $mslsn -Mssn $mssn `
        -ScriptName "" `
        -Status $cqeStatus `
        -ExitCode ([int]$execResult.ExitCode) `
        -StdOut (Get-GiipTail -Text $stdoutRaw -TailKb $outputTailKb) `
        -StdErr (Get-GiipTail -Text $stderrRaw -TailKb $outputTailKb) `
        -StartTime $startTimeStr -EndTime $endTimeStr `
        -DurationSeconds $durationSec | Out-Null
} else {
    Write-GiipLog "INFO" "[CqeRun] cqeoutputtailkb=0 - skipping cqeresult output upload (mslsn=$mslsn)."
}

if ($execResult.Success) { exit 0 } else { exit 1 }
