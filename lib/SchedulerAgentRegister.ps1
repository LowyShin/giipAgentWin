# ============================================================================
# SchedulerAgentRegister.ps1 (giip #2470)
#
# 목적:
#   1) tSchedulerAgent 등록(부트스트랩)의 단일 정본. 기존에는 이 로직이
#      lib/LogCollector.ps1 안에만 있었다.
#   2) 미등록 상태에서 "404|Agent not found" 가 무한히 쌓이는 것을 억제하는
#      실패 상태 추적 + 백오프.
#
# 배경(giip #2470 장애 — 24시간 576건, 약 35배 급증):
#   giip #2390 이 giipAgent3.ps1 에 Invoke-SchedulerAgentRunStart/RunEnd 호출을
#   추가했다. 그런데 tSchedulerAgent 행을 실제로 만드는 부트스트랩
#   (pApiSchedulerAgentUpsertBySK 호출)은 lib/LogCollector.ps1 의
#   Invoke-LogCollectorMain 안에서만 실행됐고, giipAgent3.ps1 은 LogCollector.ps1 을
#   dot-source 하지도 않는다.
#   => LogCollector 를 돌리지 않는 호스트에서는 에이전트 행이 영원히 생기지 않고,
#      Task Scheduler 5분 트리거마다 RunStart/RunEnd 가 각각 404 로 실패해
#      서버 ErrorLogs 에 시간당 24건씩 영구히 쌓였다(LOWYDN01, lssn 71198, csn 33).
#      giipAgent3.ps1 의 주석(L93-98)은 "Resolve-AgentKey 가 쓰는 agentKey 는
#      Invoke-SchedulerAgentBootstrap 이 쓰는 것과 같아야 한다"고 적고 있었지만,
#      정작 그 부트스트랩을 호출하지는 않았다.
#
# 의존성: lib/Common.ps1 (Invoke-GiipApiV2, ConvertTo-DispatcherSqlLiteral,
#         Write-GiipLog). 이 파일보다 먼저 dot-source 돼 있어야 한다.
# ============================================================================

# ----------------------------------------------------------------------------
# 백오프 정책 (순수 함수 - 테스트 대상)
#   연속 실패 n회 -> 다음 재시도까지 기다릴 분(minute).
#   Task Scheduler 트리거가 5분이므로 5분 미만은 의미가 없다.
#   1회차부터 5,10,20,40,60(상한) 분으로 늘려, 최악의 경우에도 서버 에러 기록이
#   시간당 1건 수준으로 줄어든다(기존 24건/시간).
#   주의: 0 을 반환하지 않는다 - 억제하더라도 백오프 창이 끝나면 반드시 다시
#   시도해서, 등록이 뒤늦게 이뤄지면 스스로 정상 복귀하고(자가치유) 문제가
#   계속되면 서버에도 계속(단, 저빈도로) 기록이 남게 한다.
# ----------------------------------------------------------------------------
function Get-SchedulerAgentBackoffMinutes {
    param([int]$FailureCount)
    if ($FailureCount -le 0) { return 0 }
    $minutes = 5 * [Math]::Pow(2, [Math]::Min($FailureCount - 1, 4))
    if ($minutes -gt 60) { $minutes = 60 }
    return [int]$minutes
}

function Get-SchedulerAgentStatePath {
    param([string]$StateDir)
    if (-not $StateDir) { $StateDir = $env:TEMP }
    return (Join-Path $StateDir ".giip_scheduler_agent_state.json")
}

# ----------------------------------------------------------------------------
# 실패 상태 읽기. 파일이 없거나 깨졌으면 "실패 없음" 기본값을 돌려준다.
# firstSeenUtc(첫 발생)와 totalCount(누적 횟수)는 절대 리셋하지 않고 보존한다 -
# 억제는 하되 "조용히 버리지는 않는다"는 요구(giip #2470 C항)를 이 두 필드가 담당.
# ----------------------------------------------------------------------------
function Read-SchedulerAgentFailState {
    param([string]$StatePath)
    $default = [ordered]@{ firstSeenUtc = $null; totalCount = 0; consecutiveCount = 0; nextAttemptUtc = $null; lastReason = $null }
    if (-not $StatePath -or -not (Test-Path $StatePath)) { return $default }
    try {
        $raw = Get-Content -Path $StatePath -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw) { return $default }
        $o = $raw | ConvertFrom-Json -ErrorAction Stop
        return [ordered]@{
            firstSeenUtc     = $o.firstSeenUtc
            totalCount       = [int]$o.totalCount
            consecutiveCount = [int]$o.consecutiveCount
            nextAttemptUtc   = $o.nextAttemptUtc
            lastReason       = $o.lastReason
        }
    } catch {
        return $default
    }
}

function Save-SchedulerAgentFailState {
    param([string]$StatePath, $State)
    try {
        $dir = Split-Path -Path $StatePath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($State | ConvertTo-Json -Compress) | Set-Content -Path $StatePath -Encoding UTF8 -NoNewline
    } catch {
        Write-GiipLog "WARN" "SchedulerAgent state save failed ($StatePath): $($_.Exception.Message)"
    }
}

# 등록이 성공해 정상 복귀했을 때 호출. 백오프는 풀되 통계(firstSeenUtc/totalCount)는
# 남겨 둔다 - 나중에 "언제부터 몇 번 실패했었는지" 추적이 가능해야 하기 때문.
function Clear-SchedulerAgentBackoff {
    param([string]$StatePath)
    $state = Read-SchedulerAgentFailState -StatePath $StatePath
    if ($state.totalCount -le 0 -and -not $state.firstSeenUtc) { return }
    $state.consecutiveCount = 0
    $state.nextAttemptUtc = $null
    $state.lastReason = "recovered"
    Save-SchedulerAgentFailState -StatePath $StatePath -State $state
}

# 실패 1건 기록 + 다음 재시도 시각 계산.
function Add-SchedulerAgentFailure {
    param([string]$StatePath, [string]$Reason)
    $state = Read-SchedulerAgentFailState -StatePath $StatePath
    $nowUtc = (Get-Date).ToUniversalTime()
    if (-not $state.firstSeenUtc) { $state.firstSeenUtc = $nowUtc.ToString("o") }
    $state.totalCount = $state.totalCount + 1
    $state.consecutiveCount = $state.consecutiveCount + 1
    $state.lastReason = $Reason
    $waitMin = Get-SchedulerAgentBackoffMinutes -FailureCount $state.consecutiveCount
    $state.nextAttemptUtc = $nowUtc.AddMinutes($waitMin).ToString("o")
    Save-SchedulerAgentFailState -StatePath $StatePath -State $state
    Write-GiipLog "WARN" ("SchedulerAgent registration failure recorded: reason={0} firstSeenUtc={1} totalCount={2} consecutive={3} nextAttemptUtc={4}" -f `
        $Reason, $state.firstSeenUtc, $state.totalCount, $state.consecutiveCount, $state.nextAttemptUtc)
    return $state
}

# 백오프 창 안이면 $true(이번 tick 은 API 호출 자체를 건너뛴다).
function Test-SchedulerAgentBackoffActive {
    param([string]$StatePath)
    $state = Read-SchedulerAgentFailState -StatePath $StatePath
    if (-not $state.nextAttemptUtc) { return $false }
    try { $next = [datetime]::Parse($state.nextAttemptUtc).ToUniversalTime() } catch { return $false }
    if ((Get-Date).ToUniversalTime() -lt $next) {
        Write-GiipLog "INFO" ("SchedulerAgent backoff active - skipping this run (firstSeenUtc={0} totalCount={1} nextAttemptUtc={2}). Log flood suppressed; first-seen and cumulative count are preserved." -f `
            $state.firstSeenUtc, $state.totalCount, $state.nextAttemptUtc)
        return $true
    }
    return $false
}

# ----------------------------------------------------------------------------
# Invoke-SchedulerAgentUpsert
#   pApiSchedulerAgentUpsertBySK 호출. lib/LogCollector.ps1 의
#   Invoke-SchedulerAgentBootstrap 에 있던 구현을 그대로 옮겨 온 정본이다.
#
#   ⚠️ 위치기반 디스패처 주의(giipfaw/giipApiSk2/run.ps1): 이 SP 호출은
#   "EXEC pApiSchedulerAgentUpsertBySK '<sk>', <v1>, <v2>, ..." 형태의 이름 없는
#   (unnamed) 위치기반 호출로 조립된다. T-SQL unnamed EXEC 는 중간 파라미터를
#   건너뛸 수 없으므로, SP 선언 순서(@agentKey, @displayName, @hostIdentifier,
#   @windowsTaskName, @projectName, @scheduleDesc, @isActive, @lssn, @osType,
#   @agentType, ...)상 lssn/osType/agentType 보다 앞선 값들을 전부 채워야만
#   실제로 그 자리에 값이 들어간다. 아래 $values 의 순서를 바꾸지 말 것.
#
#   또한 JsonData 는 반드시 빈 문자열("")로 보낸다 - dispatcher 가 jsonData 를
#   마지막 파라미터 뒤에 하나 더 자동 추가하는 "ISN 161" 로직을 끄기 위함
#   (안 그러면 끝쪽 INT 파라미터에서 "Error converting data type nvarchar to int").
# ----------------------------------------------------------------------------
function Invoke-SchedulerAgentUpsert {
    param($Config, [string]$AgentKey)

    $values = [ordered]@{
        agentKey        = $AgentKey
        displayName     = "giipAgentWin-$env:COMPUTERNAME"
        hostIdentifier  = $env:COMPUTERNAME
        windowsTaskName = "GIIP Agent Task (v3)"
        projectName     = "giipAgentWin"
        scheduleDesc    = "Windows Task Scheduler, giipAgent3.ps1, 5-minute trigger"
        isActive        = 1
    }

    $lssnVal = $null
    if ($Config -and $Config['lssn']) {
        $parsed = 0
        if ([int]::TryParse([string]$Config['lssn'], [ref]$parsed) -and $parsed -gt 0) { $lssnVal = $parsed }
    }
    if ($null -ne $lssnVal) {
        $values['lssn']      = $lssnVal
        $values['osType']    = "Windows"
        $values['agentType'] = "giipAgentWin"
    } else {
        Write-GiipLog "WARN" "SchedulerAgentUpsert: Config.lssn missing/invalid ('$($Config['lssn'])') - skipping lssn/osType/agentType this run."
    }

    $literals = $values.Values | ForEach-Object { ConvertTo-DispatcherSqlLiteral $_ }
    $commandText = "SchedulerAgentUpsert " + ($literals -join ' ')
    try {
        $resp = Invoke-GiipApiV2 -Config $Config -CommandText $commandText -JsonData ""
        if ($resp -and (("$($resp.RstVal)") -eq "200")) {
            Write-GiipLog "INFO" "SchedulerAgentUpsert OK agentKey=$AgentKey lssn=$lssnVal"
            return $true
        }
        $respDump = if ($resp) { ($resp | ConvertTo-Json -Compress -ErrorAction SilentlyContinue) } else { "<null>" }
        Write-GiipLog "WARN" "SchedulerAgentUpsert non-200 resp=$respDump"
        return $false
    } catch {
        Write-GiipLog "WARN" "SchedulerAgentUpsert failed: $($_.Exception.Message)"
        return $false
    }
}
