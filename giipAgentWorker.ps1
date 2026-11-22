# ============================================================================
# giipAgentWorker.ps1 (giip #6163 신규)
# Purpose: Step 1개만 실행하는 "워커" 프로세스.
#
# 왜 필요한가 (giip #5924):
#   예전에는 giipAgent3.ps1 한 프로세스가 Step 1~8 을 순차 실행했다. Step 7
#   (Enhanced Metrics) 의 행 하나가 멈추면 그 프로세스 전체가 멈춰 3일간
#   고객 PC 모니터링이 끊겼다(giip #5924). 이제 메인(giipAgent3.ps1)은 가벼운
#   "슈퍼바이저"가 되고, 각 Step 은 이 스크립트를 별도 프로세스로 띄워 실행한다.
#   한 Step 이 멈춰도 그 Step(과 그 자식 프로세스 트리)만 강제 종료되고 다음
#   Step 은 계속된다.
#
# 이 스크립트의 역할:
#   1) giipAgent3.ps1 의 초기화(전역 변수 + 설정/라이브러리 로드)를 그대로
#      재현해 "in-process 로 호출할 때와 같은 실행 환경"을 만든다.
#      (Step 모듈 중 ProcessList.ps1 은 $Global:BaseDir 를, CleanState.ps1 은
#       Write-GiipLog 를 상위 스코프에서 물려받아 쓴다.)
#   2) 지정된 Step 모듈 스크립트 1개를 & 로 실행하고, 그 종료코드로 종료한다.
#   3) 락(ProcessLock) 획득과 RunStart/RunEnd 는 하지 않는다 - 그건 슈퍼바이저
#      (giipAgent3.ps1)의 일이다. 워커가 대신 하면 실행 이력이 두벌 생긴다.
#
# 기동 방식 (슈퍼바이저가 호출):
#   conhost.exe --headless powershell.exe -NoProfile -NonInteractive
#       -ExecutionPolicy Bypass -File giipAgentWorker.ps1
#       -StepName "DbMonitor" -ModuleScript "<...>\DbMonitor.ps1"
#       -ResultFile "<temp>\giip_step_3_<token>.json"
#   - TaskSchdReg.ps1 이 등록한 진입점과 **똑같은** 패턴이다(AGENTS.md 2번
#     "진입점과 창 숨김 방식은 고정" 규칙). vbs/LOLBin/-EncodedCommand/
#     -WindowStyle Hidden 같은 다른 방식은 쓰지 않는다.
#   - ResultFile 은 워커의 PID/종료코드를 슈퍼바이저에 넘기는 통로다(선택).
#
# 주의: lib/Worker.ps1 은 다른 용도(구 진입점 giipAgentWin.ps1 의 CQE 큐
#       실행기)다. 이 파일(giipAgentWorker.ps1)은 Step 단위 워커로 별개다.
# ============================================================================

[CmdletBinding()]
param(
    # 로그/진단용 Step 이름 (예: "DbMonitor")
    [Parameter(Mandatory = $true)][string]$StepName,
    # 실행할 Step 모듈 스크립트의 전체 경로
    [Parameter(Mandatory = $true)][string]$ModuleScript,
    # 슈퍼바이저가 워커의 PID/종료코드를 확실히 읽기 위한 결과 파일(선택).
    #   - 워커는 시작할 때 자기 PID 를, 끝날 때 종료코드를 이 파일에 남긴다.
    #   - 이유: 워커는 conhost.exe --headless 아래에서 돌아가므로, 래퍼
    #     (conhost)가 자식의 종료코드를 그대로 되돌려주지 않는 경우에도
    #     슈퍼바이저는 워커가 직접 기록한 종료코드로 Step 실패를 판정할 수
    #     있다. 타임아웃 때 워커 PID 를 직접 kill 하는 용도로도 쓴다.
    [string]$ResultFile = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Global:BaseDir = $ScriptDir
# 경로 구분자는 Join-Path 로 잇는다(Windows 의 "giipscripts\modules" 를
# 그대로 쓰면 다른 OS 에서 경로가 깨진다 - Windows 동작은 동일).
$ModuleDir = Join-Path (Join-Path $ScriptDir "giipscripts") "modules"
$LibDir = Join-Path $ScriptDir "lib"

# ---------------------------------------------------------------------------
# 결과 파일 기록 (best-effort)
#   state=running  : 워커 기동 직후(자기 PID)
#   state=finished : 워커 종료 직후(종료코드)
# 기록에 실패해도 워커 실행에는 영향이 없다(슈퍼바이저는 $proc.ExitCode 로
# 대체 판단한다).
# ---------------------------------------------------------------------------
function Write-WorkerResult {
    param([string]$State, $ExitCode)
    if (-not $ResultFile) { return }
    try {
        $payload = [ordered]@{
            step     = $StepName
            pid      = $PID
            state    = $State
            exitCode = $ExitCode
            at       = (Get-Date -Format "o")
        }
        ($payload | ConvertTo-Json -Compress) | Set-Content -Path $ResultFile -Encoding UTF8 -Force -ErrorAction Stop
    } catch {
        # best-effort. 결과 파일이 없으면 슈퍼바이저가 프로세스 종료코드로 판정한다.
    }
}

# Load Libraries (MANDATORY ORDER) - giipAgent3.ps1 의 초기화 코드를 재현한다.
# 주의: ProcessLock / SchedulerAgentRegister / SchedulerAgentRun 은 슈퍼바이저
# 전용(락 획득 / RunStart / RunEnd)이라 워커에서는 로드하지 않는다. 이들을
# 로드하면 워커가 대신 실행 이력을 남길 수 있어 이력이 중복/경합한다.
try {
    # 1. Base Common Functions
    . (Join-Path $LibDir "Common.ps1")

    # 2. Key-Value Store Library (REQUIRED for ProcessList)
    #    저장소 파일명의 실제 대소문자는 "Kvs.ps1" 이고 Windows 의 대소문자
    #    구분 없는 파일시스템에서는 "KVS.ps1" 로도 잡힌다. 둘 다 시도해 어떤
    #    파일시스템에서도 똑같이 로드되게 한다.
    $kvsPath = $null
    foreach ($kvsCandidate in @((Join-Path $LibDir "KVS.ps1"), (Join-Path $LibDir "Kvs.ps1"))) {
        if (Test-Path $kvsCandidate) { $kvsPath = $kvsCandidate; break }
    }
    if (-not $kvsPath) {
        throw "KVS library not found at: $(Join-Path $LibDir 'KVS.ps1')"
    }
    . $kvsPath
} catch {
    Write-Host "FATAL: Failed to load core libraries. ($_)"
    exit 1
}

# Ensure Logging is available (giipAgent3.ps1 과 동일)
if (-not (Get-Command "Write-GiipLog" -ErrorAction SilentlyContinue)) {
    function Write-GiipLog { param($Level, $Message) Write-Host "[$Level] $Message" }
}

# stdout 인코딩 고정 (giip #2546 에서 이미 같은 함정을 밟은 곳이 있다).
# stdout 이 리다이렉트된 자식 powershell.exe 는 [Console]::OutputEncoding 이
# 콘솔 코드페이지(국내 PC = 949)로 잡혀 한글이 자식 쪽에서 '?' 로 치환된다.
# 워커가 스스로 UTF-8 로 바꿔 놓으면 슈퍼바이저가 캡처 파일을 UTF-8 로 읽어
# 그대로 되돌릴 수 있다(깨짐 없음).
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
    # 콘솔이 없는 환경이면 무시한다(로그 파일 기록에는 영향 없음).
}

# 설정 로드 (giipAgent3.ps1 의 초기화 코드 재현).
# Step 모듈은 각자 Get-GiipConfig 를 다시 호출하지만, 워커가 시작되는 시점에
# 설정을 한 번 읽어 "설정 자체가 없음"을 즉시 드러내 둔다 - 설정이 없으면
# Step 내부에서 조용히 아무것도 안 하고 끝나는 경우가 생기면(log가 없어서)
# 원인을 알 수 없다.
try {
    $Config = Get-GiipConfig
    if (-not $Config -or $Config.Count -eq 0) {
        Write-GiipLog "WARN" "[$StepName] Config is empty - check giipAgent.cfg (searched from: $($Global:BaseDir))"
    }
} catch {
    Write-GiipLog "WARN" "[$StepName] Config load failed (non-fatal): $($_.Exception.Message)"
}

if (-not (Test-Path $ModuleScript)) {
    Write-Host "FATAL: [$StepName] Module script not found: $ModuleScript"
    Write-WorkerResult -State "finished" -ExitCode 2
    exit 2
}

# 워커 기동을 슈퍼바이저에 알려 준다(타임아웃 때 워커 PID 를 직접 kill 하기 위해).
Write-WorkerResult -State "running" -ExitCode $null

# ---------------------------------------------------------------------------
# Step 모듈 실행
# ---------------------------------------------------------------------------
# '&' 로 부른 스크립트의 exit 코드는 $LASTEXITCODE 에만 남고 호출자(워커)를
# 중단시키지 않는다(giipAgent3.ps1 의 Step 실행과 동일한 구조). 모듈이 exit 을
# 호출하지 않는 경우(=마지막 native 명령의 코드)를 물려받지 않도록 먼저 0 으로
# 초기화한다.
$exitCode = 0
try {
    $LASTEXITCODE = 0
    & $ModuleScript
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
} catch {
    # 모듈이 예외를 던진 경우. 워커가 실패(1)로 끝나고, 슈퍼바이저는 그 종료
    # 코드를 Step 실패로 기록만 하고 다음 Step 으로 진행한다.
    try {
        Write-GiipLog "ERROR" "[$StepName] Worker failed: $_"
    } catch {
        Write-Host "[ERROR] [$StepName] Worker failed: $_"
    }
    $exitCode = 1
}

# 종료코드를 슈퍼바이저에 남긴다(래퍼가 종료코드를 먹어도 판정할 수 있게).
Write-WorkerResult -State "finished" -ExitCode $exitCode

exit $exitCode
