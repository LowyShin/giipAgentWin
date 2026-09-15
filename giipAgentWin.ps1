# ============================================================================
# giipAgentWin (Main Orchestrator)
# Version: 2.0 (Modular / V2 API Standard)
#
# [용도] Windows 에이전트의 **구 진입점**. 프로세스가 죽지 않고 상주하면서
#        "큐 조회 -> 실행 -> Sleep" 을 무한 반복하는 데몬형 루프다.
#        2025-08-12 커밋 6b912f2("Create giipAgentWin.ps1")에서 단일 파일로
#        만들어졌고, 2025-12-08 커밋 1558e27("refactor: Modularize Windows Agent
#        to v2.0 structure")에서 458줄 본문이 lib/Common.ps1 + lib/Worker.ps1 로
#        분리되며 지금의 얇은 오케스트레이터 형태가 됐다.
#
# [입력]  giipAgent.cfg (Get-GiipConfig 로 탐색: 상위폴더 > USERPROFILE > 로컬)
#         루프 간격은 cfg 의 giipagentdelay(초), 없으면 60초
# [처리]  Step A Get-QueueItem(lib/Worker.ps1) -> Step B Invoke-AgentTask ->
#         Step C Start-Sleep -> 매 회차 끝에 cfg 재로드(운영 중 lssn 변경 반영)
# [저장]  이 파일 자체는 저장하지 않는다. 저장은 lib/Worker.ps1 의
#         Report-TaskResult 가 수행한다:
#           giipdb tKVS, kType='lssn', kKey=<lssn>, kFactor='giipAgentLog',
#           kValue={"qsn","status","output"} (API 'KVSPut kType kKey kFactor kValue')
#         로컬 로그: <레포상위>\giipLogs\giipAgentWin_<yyyyMMdd>.log (Write-GiipLog)
# [소비처] kFactor='giipAgentLog' 를 읽는 화면/SP 는 현재 없다(giipv3 src/ 및
#          giipdb 전수 검색 SELECT 0건. giipdb SP/pAdmCleanTable.sql L113 의
#          14일 경과분 DELETE 조건만 매치). 자세한 근거는 lib/Worker.ps1 헤더 참조.
#          확인 명령: rg -n -i "giipagentlog" -g '!node_modules' .   (giipv3, giipdb 각각)
#
# [현재 호출 상태] Task Scheduler 등록 0건 + 상주 프로세스 0건(Win32_Process 실측).
#   - 언제부터: 2025-12-11 커밋 b69abcd("feat: Implement Windows Agent v3 modular
#     architecture (CleanState, CqeGet, Orchestrator)")가 TaskSchdReg.ps1 의 등록
#     대상을 이 파일에서 giipAgent3.ps1 로 바꿨다. 그 이전, 2025-08-28 커밋
#     f7f8102 부터 2025-12-11 까지는 이 파일이 실제 운영 진입점이었다
#     (그보다 앞은 giipAgent.wsf).
#   - 왜: 상주 데몬 방식을 버리고 Task Scheduler 5분 주기 단발 실행 방식으로
#     바꿨기 때문이다. 현재 등록된 작업은 'GIIP Agent Task (v3)' 하나이고 그
#     액션은 wscript.exe + giipAgent3-silent.vbs -> giipAgent3.ps1 이다
#     (2026-07-28 커밋 82db711 에서 콘솔 창 깜빡임을 없애려 vbs 래퍼로 바뀜).
#     giipAgent3.ps1 은 Step 1~7 + Step 2.5 를 giipscripts\modules\ 의 개별
#     모듈로 순차 실행한다.
#
# [giip #2556 에서 고친 결함]
#   - 이 진입점은 2026-04-08 커밋 95a5560 이후 **기동해도 루프 첫 회차에서 반드시
#     죽는 상태**였다. lib/Worker.ps1 의 Get-QueueItem 이 첫 줄에서 부르는
#     Get-SystemInfo 의 정의가 그 커밋에서 사라졌기 때문이다(실측 재현:
#     CommandNotFoundException "The term 'Get-SystemInfo' is not recognized ...").
#     lib/Common.ps1 에 Get-SystemInfo / Update-ConfigLssn 원본 정의를 복원해
#     해소했다. 호출되지 않는 동안 아무도 이 결함을 만나지 않았을 뿐이다.
#
# [실행 시 주의] 아래 Main 은 while($true) 무한 루프다. 검증 목적으로 실행하면
#   끝나지 않으므로 타임아웃을 주거나, 함수만 dot-source 해 개별 호출할 것.
#
# 상세 사양: docs/SPEC_UNCALLED_PATHS.md
# ============================================================================

# Define Global BaseDir for Modules
$Global:BaseDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

# Load Modules
try {
  . (Join-Path $Global:BaseDir "lib\Common.ps1")
  . (Join-Path $Global:BaseDir "lib\Worker.ps1")
}
catch {
  Write-Host "FATAL ERROR: Failed to load modules (lib\Common.ps1, lib\Worker.ps1)"
  exit 1
}

# Main Execution Orchestrator
function Main {
  Write-GiipLog "INFO" "Starting giipAgentWin v2.0 (Modular)"

  # 1. Load Configuration
  try {
    $Config = Get-GiipConfig
    Write-GiipLog "INFO" "Config Loaded. LSSN=$($Config.lssn)"
        
    # Validate critical loop param
    $delay = if ($Config.giipagentdelay) { [int]$Config.giipagentdelay } else { 60 }
  }
  catch {
    Write-GiipLog "ERROR" "Initialization Failed: $($_.Exception.Message)"
    exit 1
  }
    
  # 2. Infinite Loop (Poll -> Execute -> Sleep)
  while ($true) {
    try {
      # Step A: Poll
      $queueItem = Get-QueueItem -Config $Config
            
      # Step B: Execute (if any)
      if (-not [string]::IsNullOrWhiteSpace($queueItem)) {
        Invoke-AgentTask -RawQueueItem $queueItem -Config $Config
      }
            
    }
    catch {
      Write-GiipLog "ERROR" "Loop Error: $($_.Exception.Message)"
    }
        
    # Step C: Sleep
    Start-Sleep -Seconds $delay
        
    # Reload config in case lssn updated or changed
    try { $Config = Get-GiipConfig } catch {}
  }
}

# Start Main
try {
  Main
}
catch {
  Write-Host "Unhandled Exception: $($_.Exception.Message)"
  exit 1
}

