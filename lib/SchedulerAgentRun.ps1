# ============================================================================
# SchedulerAgentRun.ps1 (giip #2390)
#
# 목적:
#   giipdb.tSchedulerAgentRun에 giipAgent3.ps1의 1회 실행(Task Scheduler 5분
#   tick) 단위 시작/종료 이력을 기록한다. giipv3의 lssn 기준
#   "스케줄러 실행 이력" 페이지(schedulerrunhistory?lssn=71197)가 표시할 데이터를
#   쌓는 것이 목적이며, SP(pApiSchedulerAgentRunStartBySK /
#   pApiSchedulerAgentRunEndBySK, giipdb repo SP/ 참고, giip #1558)는 이미 존재
#   했으나 giipAgentWin 어디서도 호출하지 않아 실행 이력이 전혀 쌓이지 않았다.
#
# 위치기반 디스패처 + jsonData 자동추가 함정(giipfaw/giipApiSk2/run.ps1 직접
# 확인, 아래 두 함수 최초 라이브 테스트에서 "Error converting data type
# nvarchar to int"로 실측 발견):
#   1) 이 SP 호출들은 이름 없는(unnamed) 위치기반 EXEC로 조립되므로,
#      CommandText 토큰 순서는 반드시 각 SP의 파라미터 선언 순서와 정확히
#      일치해야 한다(중간을 건너뛸 수 없음).
#   2) CommandText 토큰을 jsonData 프로퍼티명 치환 방식으로 채우면, jsonData가
#      존재하는 한 dispatcher가 "ISN 161" 로직으로 원본 jsonData 전체를 우리가
#      지정한 마지막 파라미터 뒤에 하나 더(!) 자동으로 얹는다. 파라미터 개수가
#      적고 끝쪽이 INT인 pApiSchedulerAgentRunStartBySK(@totalIssueCount)
#      같은 SP에서는 이게 그대로 타입 변환 에러가 된다.
#   두 문제를 모두 피하려고, 값은 이미 SQL 리터럴로 감싼 채로 CommandText에
#   직접 박아 넣고(ConvertTo-DispatcherSqlLiteral, lib/Common.ps1), JsonData는
#   항상 빈 문자열("")로 보낸다(dispatcher가 falsy로 판정해 치환/자동추가 전체를
#   건너뜀).
#
# 두 함수 모두 giipAgent3.ps1 본 실행 흐름에 영향을 주면 안 되므로(네트워크 장애 등),
# 내부에서 예외를 잡아 WARN 로그만 남기고 항상 $true/$false를 반환한다(예외를
# 다시 던지지 않음).
#
# 사용법 (giipAgent3.ps1 참고):
#   . (Join-Path $LibDir "SchedulerAgentRun.ps1")
#   $ok = Invoke-SchedulerAgentRunStart -Config $Config -AgentKey $agentKey -RunIdKey $runIdKey
#   ...
#   Invoke-SchedulerAgentRunEnd -Config $Config -AgentKey $agentKey -RunIdKey $runIdKey -Status "SUCCEEDED" -ExitCode 0
# ============================================================================

# ----------------------------------------------------------------------------
# Invoke-SchedulerAgentRunStart
#   pApiSchedulerAgentRunStartBySK 호출 (SP 파라미터 순서: @sk, @runIdKey, @agentKey,
#   @executionMode, @totalIssueCount=0). totalIssueCount는 이 에이전트에서 의미있게
#   채울 값이 없어 끝쪽 기본값(0)으로 남기고 토큰에서 생략한다(끝쪽 생략은 unnamed
#   EXEC에서도 안전 - SP 자체의 DEFAULT가 적용됨. 중간 파라미터는 생략 불가하지만
#   여기선 전부 채우므로 해당 없음).
# ----------------------------------------------------------------------------
#
# giip #2470: 이 SP 는 tSchedulerAgent 에 (csn, agentKey) 행이 있어야만 200 을 준다.
# 행이 없으면 "404|Agent not found" 를 돌려주는데, 기존 구현은 그걸 WARN 한 줄
# 찍고 끝내서 Task Scheduler 5분 트리거마다 영구히 서버 ErrorLogs 를 쌓았다
# (LOWYDN01 실측: 24시간 576건, 평소의 약 35배). 이제 404 를 만나면
#   (1) pApiSchedulerAgentUpsertBySK 로 자가등록을 시도하고 한 번만 재시도하고,
#   (2) 그래도 안 되면 실패를 누적 기록한 뒤 백오프에 들어간다.
# 백오프 창 안에서는 API 호출 자체를 건너뛰므로 서버 로그가 더 쌓이지 않지만,
# 첫 발생 시각(firstSeenUtc)과 누적 횟수(totalCount)는 상태파일에 계속 남고
# 백오프가 끝나면 반드시 다시 시도한다 - 조용히 버리는 것이 아니다.
# 상세: lib/SchedulerAgentRegister.ps1
#
function Invoke-SchedulerAgentRunStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AgentKey,
        [Parameter(Mandatory)][string]$RunIdKey,
        [string]$ExecutionMode = "scheduled",
        # giip #2470: 404 누적/백오프 상태파일을 둘 폴더(보통 InstallDir).
        # 지정하지 않으면 자가등록/백오프 없이 기존 동작 그대로다(하위호환).
        [string]$StateDir
    )
    $statePath = $null
    if ($StateDir) {
        $statePath = Get-SchedulerAgentStatePath -StateDir $StateDir
        if (Test-SchedulerAgentBackoffActive -StatePath $statePath) { return $false }
    }

    $invoke = {
        $literals = @($RunIdKey, $AgentKey, $ExecutionMode) | ForEach-Object { ConvertTo-DispatcherSqlLiteral $_ }
        $commandText = "SchedulerAgentRunStart " + ($literals -join ' ')
        Invoke-GiipApiV2 -Config $Config -CommandText $commandText -JsonData ""
    }

    try {
        $resp = & $invoke
        if ($resp -and (("$($resp.RstVal)") -eq "200")) {
            Write-GiipLog "INFO" "SchedulerAgentRunStart OK runIdKey=$RunIdKey agentKey=$AgentKey runId=$($resp.run_id) action=$($resp.action)"
            if ($statePath) { Clear-SchedulerAgentBackoff -StatePath $statePath }
            return $true
        }

        $respDump = if ($resp) { ($resp | ConvertTo-Json -Compress -ErrorAction SilentlyContinue) } else { "<null>" }

        # giip #2470: 404 = tSchedulerAgent 미등록. 자가등록 후 1회만 재시도한다.
        if ($statePath -and $resp -and (("$($resp.RstVal)") -eq "404")) {
            Write-GiipLog "WARN" "SchedulerAgentRunStart 404 (Agent not found) - attempting tSchedulerAgent self-registration. agentKey=$AgentKey"
            if (Invoke-SchedulerAgentUpsert -Config $Config -AgentKey $AgentKey) {
                $resp = & $invoke
                if ($resp -and (("$($resp.RstVal)") -eq "200")) {
                    Write-GiipLog "INFO" "SchedulerAgentRunStart OK (after self-registration retry) runIdKey=$RunIdKey agentKey=$AgentKey runId=$($resp.run_id)"
                    Clear-SchedulerAgentBackoff -StatePath $statePath
                    return $true
                }
                $respDump = if ($resp) { ($resp | ConvertTo-Json -Compress -ErrorAction SilentlyContinue) } else { "<null>" }
            }
            Write-GiipLog "WARN" "SchedulerAgentRunStart still failing after self-registration resp=$respDump"
            Add-SchedulerAgentFailure -StatePath $statePath -Reason "404|Agent not found (self-register retry failed)" | Out-Null
            return $false
        }

        Write-GiipLog "WARN" "SchedulerAgentRunStart non-200 resp=$respDump"
        if ($statePath) { Add-SchedulerAgentFailure -StatePath $statePath -Reason "non-200" | Out-Null }
        return $false
    } catch {
        Write-GiipLog "WARN" "SchedulerAgentRunStart failed: $($_.Exception.Message)"
        if ($statePath) { Add-SchedulerAgentFailure -StatePath $statePath -Reason "exception: $($_.Exception.Message)" | Out-Null }
        return $false
    }
}

# ----------------------------------------------------------------------------
# Invoke-SchedulerAgentRunEnd
#   pApiSchedulerAgentRunEndBySK 호출 (SP 파라미터 순서: @sk, @runIdKey, @agentKey,
#   @status, @processedCount=0, @skippedCount=0, @failedCount=0, @exitCode=NULL,
#   @summary=NULL). processedCount/skippedCount/failedCount는 giipAgent3.ps1이
#   현재 추적하지 않는 값이라 SP 기본값과 동일한 0을 그대로 채워 위치를 맞춘다
#   (중간 파라미터라 생략 불가). exitCode는 끝에서 두 번째라 항상 채우고, summary는
#   진짜 끝 파라미터라 값이 있을 때만 토큰에 추가한다(없으면 SP 기본값 NULL 유지).
# ----------------------------------------------------------------------------
function Invoke-SchedulerAgentRunEnd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AgentKey,
        [Parameter(Mandatory)][string]$RunIdKey,
        [Parameter(Mandatory)][ValidateSet('SUCCEEDED', 'FAILED', 'TIMED_OUT', 'ZOMBIE_TERMINATED', 'SKIPPED')][string]$Status,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$Summary
    )
    try {
        $values = @($RunIdKey, $AgentKey, $Status, 0, 0, 0, $ExitCode)
        if ($Summary) {
            $trimmed = $Summary
            if ($trimmed.Length -gt 1000) { $trimmed = $trimmed.Substring(0, 1000) }
            $values += $trimmed
        }
        $literals = $values | ForEach-Object { ConvertTo-DispatcherSqlLiteral $_ }
        $commandText = "SchedulerAgentRunEnd " + ($literals -join ' ')

        $resp = Invoke-GiipApiV2 -Config $Config -CommandText $commandText -JsonData ""
        if ($resp -and (("$($resp.RstVal)") -eq "200")) {
            Write-GiipLog "INFO" "SchedulerAgentRunEnd OK runIdKey=$RunIdKey agentKey=$AgentKey status=$Status exitCode=$ExitCode"
            return $true
        }
        $respDump = if ($resp) { ($resp | ConvertTo-Json -Compress -ErrorAction SilentlyContinue) } else { "<null>" }
        Write-GiipLog "WARN" "SchedulerAgentRunEnd non-200 resp=$respDump"
        return $false
    } catch {
        Write-GiipLog "WARN" "SchedulerAgentRunEnd failed: $($_.Exception.Message)"
        return $false
    }
}
