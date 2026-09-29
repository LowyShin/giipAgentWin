
# ============================================================================
# GIIP Agent Normal Mode (PowerShell)
# Version: 1.01
#
# [용도] CQE 큐를 1회만 받아 실행하고 끝나는 "단발(one-shot) 실행 모드" 진입점.
#        상주 무한루프(giipAgentWin.ps1)와 달리 Task Scheduler 가 주기적으로
#        불러주는 형태를 전제로 2025-12-10 커밋 ef30c46("giipAgent3.ps1 신규
#        작성")에서 giipAgent3 1차 설계의 일부로 도입됐다.
#
# [입력]  giipAgent.cfg(Get-GiipConfig), CQE 큐(API 'CQEQueueGet')
# [처리]  startup 로그 -> Get-Queue 로 큐 1건 조회 -> 내용이 있으면 %TEMP% 에
#         .ps1 로 써서 & 연산자로 실행 -> exit code/duration 기록 -> 임시파일 삭제
#         -> shutdown 로그. 큐가 없으면 queue_check 로그만 남긴다.
# [저장]  giipdb tKVS (Save-ExecutionLog 경유)
#           kType   = 'lssn'
#           kKey    = <lssn>
#           kFactor = 'giipagent'
#           kValue  = {"event_type":"startup|queue_check|script_execution|error|shutdown",
#                      "timestamp","lssn","hostname","mode":"normal","version",
#                      "details":{...}}
#         임시 스크립트 파일: %TEMP%\giip_task_<PID>.ps1 (실행 후 삭제)
#         로컬 로그: <레포상위>\giipLogs\giipAgentWin_<yyyyMMdd>.log (Write-GiipLog)
# [소비처] giipv3 src/components/CqeLsvrRunData.tsx L98 의 [KVS] 버튼이
#            /{locale}/kvslist?kKey=<lssn>&kFactor=giipagent&mslsn=<mslsn> 로 이동
#          giipv3 src/app/[locale]/kvslist/page.tsx (API 'KVSList kType kKey kFactor'
#            -> SP pApiKVSListbySk, kFactor 정확일치. mslsn 은 프론트에서
#            item.details.mslsn 으로 추가 필터 - giip-967)
#          giipv3 src/components/dashboard/dashboardStatsTypes.ts L73 (KVS Activity 배지)
#          giipv3 src/lib/kvsHourlyDashboard.ts L73 (주요 factor 누락 판정)
#          ※ 단 이 파일은 mslsn/mssn 을 details 에 넣지 않으므로(Get-Queue 가
#            ms_body 만 돌려주기 때문) CqeLsvrRunData 의 mslsn 필터에는 걸리지 않는다.
#          확인 명령: rg -n -i "['\"]giipagent['\"]" -g '!node_modules' src   (giipv3)
#
# [현재 호출 상태] 이 스크립트를 기동하는 곳 0건(Task Scheduler 미등록, 다른
#   스크립트의 호출도 0건).
#   - 언제부터: 도입 다음날인 2025-12-11 커밋 b69abcd("feat: Implement Windows
#     Agent v3 modular architecture (CleanState, CqeGet, Orchestrator)")가
#     giipAgent3.ps1 을 giipscripts\modules\ 호출 구조로 재작성하고 같은 커밋에서
#     TaskSchdReg.ps1 의 등록 대상을 giipAgentWin.ps1 -> giipAgent3.ps1 로 바꿨다.
#     이 파일을 부르는 경로는 새 구조에 포함되지 않았다.
#   - 왜: "큐를 1회 받아 실행한다"는 역할 자체는 살아 있고, giipscripts\modules\
#     CqeGet.ps1(조회) + CqeRun.ps1(실행)으로 나뉘어 giipAgent3.ps1 Step 2 / Step 2.5
#     가 됐다. 다만 CqeRun.ps1 은 2026-09-15 커밋 f0ebbc5(giip #2546)에서야
#     추가됐다 - 즉 2025-12-11 재설계 시점에 실행 단계가 이식되지 않은 채로
#     남아 있었고, 그 공백이 giip #2546 에서 드러났다.
#
# [giip #2556 에서 고친 결함]
#   - Save-ExecutionLog 를 6곳에서 호출하면서 그 정의를 로드하지 않았다
#     (아래 2번에서 Common/Kvs/Cqe 만 dot-source). $ErrorActionPreference='Stop'
#     이라 L45 첫 호출에서 즉시 CommandNotFoundException 으로 종료됐을 것이다.
#     lib/ExecutionLog.ps1 을 로드하도록 교정했다.
#
# 상세 사양: docs/SPEC_UNCALLED_PATHS.md
# ============================================================================

$ErrorActionPreference = "Stop"

# 1. Initialize Paths
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$BaseDir = Split-Path -Path $ScriptDir -Parent
$LibDir = Join-Path $BaseDir "lib"
#  DO NOT MODIFY THIS PATH 
# Config file is in PARENT of repository root
$ConfigFile = Join-Path $BaseDir "../giipAgent.cfg" # Parent of Repository Root

# 2. Load Modules
try {
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "Kvs.ps1")
    . (Join-Path $LibDir "Cqe.ps1")
    # giip #2556: 아래에서 Save-ExecutionLog 를 6번 호출하는데 그 정의(lib/
    # ExecutionLog.ps1, giip #2546 에서 도입)를 로드하지 않고 있었다.
    # $ErrorActionPreference='Stop' 이므로 첫 호출에서 바로 죽는다.
    . (Join-Path $LibDir "ExecutionLog.ps1")
}
catch {
    Write-Host "FATAL: Failed to load modules from $LibDir"
    exit 1
}

# 3. Load Config
try {
    # If config file is passed as arg, use it (TODO: args parsing if needed)
    $Config = Get-GiipConfig
}
catch {
    Write-Host "FATAL: Failed to load config: $_"
    exit 1
}

# 4. Initialization Logging
$lssn = $Config.lssn
$hostname = [System.Net.Dns]::GetHostName()

Write-GiipLog "INFO" "Starting Normal Mode. LSSN=$lssn"
Save-ExecutionLog -Config $Config -EventType "startup" -DetailsObj @{ mode = "normal"; pid = $PID }

# 5. Get Queue
$scriptContent = $null
try {
    $scriptContent = Get-Queue -Config $Config -Hostname $hostname
}
catch {
    Write-GiipLog "ERROR" "Queue fetch failed: $_"
    Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ context = "queue_fetch"; error = $_.Exception.Message }
}

# 6. Execute (if content)
if ($scriptContent) {
    Write-GiipLog "INFO" "Received task. Executing..."
    
    # Save to temp file to execute (for better debugging context and handling)
    $tmpFile = Join-Path $env:TEMP "giip_task_$PID.ps1"
    
    try {
        $scriptContent | Set-Content -Path $tmpFile -Encoding UTF8
        
        $startTime = Get-Date
        
        # Execute
        # Use Invoke-Expression or Call Operator &
        # & $tmpFile is safer/better for scripts
        
        & $tmpFile
        
        $exitCode = $LASTEXITCODE
        $duration = ((Get-Date) - $startTime).TotalSeconds
        
        Write-GiipLog "INFO" "Task executed. Exist Code: $exitCode. Duration: $duration s"
        
        Save-ExecutionLog -Config $Config -EventType "script_execution" -DetailsObj @{
            exit_code = $exitCode
            duration  = $duration
            type      = "powershell"
        }
        
    }
    catch {
        Write-GiipLog "ERROR" "Task execution failed: $_"
        Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ context = "script_exec"; error = $_.Exception.Message }
    }
    finally {
        if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force }
    }
}
else {
    Write-GiipLog "INFO" "No task."
    # Optional: Log check event (Linux does queue_check)
    Save-ExecutionLog -Config $Config -EventType "queue_check" -DetailsObj @{ has_queue = $false }
}

# 7. Shutdown Log
Save-ExecutionLog -Config $Config -EventType "shutdown" -DetailsObj @{ mode = "normal"; status = "ok" }
Write-GiipLog "INFO" "Normal Mode Completed."
exit 0

