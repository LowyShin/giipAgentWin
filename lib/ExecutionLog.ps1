# ============================================================================
# giipAgentWin Library: ExecutionLog
# Purpose: 에이전트 실행 이력을 KVS(kFactor='giipagent')에 남긴다.
#          Linux 에이전트 lib/kvs.sh 의 save_execution_log() 와 동일 의미론.
#
# giip #2546:
#   Save-ExecutionLog 는 lib/Discovery.ps1 과 scripts/NormalMode.ps1 이 이미
#   호출하고 있었지만 이 레포 어디에도 **정의가 없었다**(실측: 전체 검색 결과
#   호출 9건 / 정의 0건). 두 호출자 모두 Task Scheduler 에 등록되지 않은 죽은
#   경로라 그동안 아무도 NullReference 를 만나지 않았을 뿐이다. CQE 실행기
#   복원(giipscripts/modules/CqeRun.ps1)이 실행 이력을 남겨야 하므로 여기서
#   정식으로 구현한다.
#
# kFactor 를 'giipagent' 로 고정하는 근거(추측 아님, 화면 코드 실측):
#   giipv3 src/components/CqeLsvrRunData.tsx 의 [KVS] 버튼이
#     /{locale}/kvslist?kKey=<lssn>&kFactor=giipagent&mslsn=<mslsn>
#   로 이동하고, kvslist 페이지가 `item.details.mslsn` 으로 클라이언트 필터링한다
#   (giip-967, giipAgentLinux 쓰기측과 짝). 즉 실행 이력이 이 화면에 보이려면
#   kFactor='giipagent' + kValue.details.mslsn 형태여야 한다.
#   lib/Worker.ps1 의 Report-TaskResult 가 쓰는 kFactor='giipAgentLog' 는
#   giipv3 어느 화면도 읽지 않는다 - 그래서 정본은 이쪽이다.
# ============================================================================

if (-not (Get-Command Invoke-GiipKvsPut -ErrorAction SilentlyContinue)) {
    $__elScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $__elKvsPath = Join-Path $__elScriptDir "Kvs.ps1"
    if (Test-Path $__elKvsPath) { . $__elKvsPath }
}

# 에이전트 버전 문자열(Linux 의 $sv 에 해당). 호출자가 덮어쓸 수 있다.
if (-not $Global:GiipAgentVersion) { $Global:GiipAgentVersion = "3.0" }

function Save-ExecutionLog {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$EventType,
        [object]$DetailsObj
    )

    # 로깅 실패가 본 작업을 깨뜨리면 안 된다 - 전 구간 best-effort.
    try {
        $lssn = $Config['lssn']
        if (-not $lssn) {
            Write-GiipLog "WARN" "[ExecutionLog] lssn missing in config - skipping '$EventType' log."
            return $false
        }

        if ($null -eq $DetailsObj) { $DetailsObj = @{} }

        $kValue = @{
            event_type = $EventType
            timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            lssn       = $lssn
            hostname   = $env:COMPUTERNAME
            mode       = "normal"
            version    = $Global:GiipAgentVersion
            details    = $DetailsObj
        }

        $response = Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$lssn" -Factor "giipagent" -Value $kValue
        Write-GiipLog "INFO" "[ExecutionLog] event_type=$EventType sent (RstVal=$($response.RstVal))"
        return $true
    }
    catch {
        Write-GiipLog "WARN" "[ExecutionLog] Failed to save '$EventType' log (non-fatal): $($_.Exception.Message)"
        return $false
    }
}
