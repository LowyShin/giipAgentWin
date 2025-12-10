# Windows Agent 3.0 Specification (giipAgent3.ps1)

> **문서 메타데이터**
> - **버전**: 1.0
> - **작성일**: 2025-12-10
> - **대상**: Windows Server 2016+ (PowerShell 5.1+)
> - **기반**: giipAgentLinux 3.0 (`giipAgent3.sh`)

---

## 1. 개요 (Overview)

`giipAgent3.ps1`은 Linux용 에이전트(`giipAgent3.sh`)의 구조와 처리 로직을 Windows 환경(PowerShell)으로 완벽하게 이식한 버전입니다.
기존의 무한 루프 방식(`while($true)`)에서 **단발성 실행(One-shot execution)** 방식으로 변경되었으며, Windows Task Scheduler에 의해 주기적(예: 1분 간격)으로 실행되도록 설계되었습니다.

### 핵심 설계 원칙
1.  **모듈화 (Modularity)**: 핵심 기능(KVS, CQE, Discovery)을 `lib/` 디렉토리의 독립적인 모듈로 분리.
2.  **프로세스 격리**: `NormalMode` 등 작업 실행은 별도 스크립트로 분리하여 메인 프로세스와 격리.
3.  **API 표준 준수**: `giipApiSk2` (token 인증 방식)를 철저히 준수 (`sk` 파라미터 금지).
4.  **설정 파일 위치**: `RepoRoot/../giipAgent.cfg` (부모 디렉토리) 참조.

---

## 2. 파일 구조 (File Structure)

```text
giipAgentWin/
├── giipAgent3.ps1          # [메인] 에이전트 진입점 (Orchestrator)
├── giipAgent.cfg (Example) # 설정 파일 (실제 파일은 상위 디렉토리에 위치)
├── lib/                    # [라이브러리] 공통 모듈
│   ├── Common.ps1          # 공통 기능 (설정 로드, 로깅, 기본 API)
│   ├── Kvs.ps1             # KVS 로깅 및 데이터 전송
│   ├── Cqe.ps1             # CQE 큐 조회
│   └── Discovery.ps1       # 인프라 정보 수집 및 전송
└── scripts/                # [실행 스크립트] 독립 실행 프로세스
    ├── NormalMode.ps1      # 일반 모드 작업 처리기
    └── GatewayMode.ps1     # (Optional) 게이트웨이 모드
```

---

## 3. 처리 플로우 (Process Flow)

`giipAgent3.ps1` 실행 시 다음 순서로 처리가 진행됩니다.

1.  **초기화 (Initialization)**
    *   경로 설정 (`$ScriptDir`, `$LibDir`)
    *   필수 모듈 로드 (`lib/*.ps1`)
    *   설정 파일 로드 (`Get-GiipConfig`)

2.  **서버 등록 (Registration)** (If `lssn=0`)
    *   LSSN이 0인 경우 `CQEQueueGet` API를 호출하여 신규 LSSN 발급 시도.
    *   성공 시 `giipAgent.cfg` 파일의 `lssn` 값을 업데이트.

3.  **인프라 정보 수집 (Discovery)**
    *   `Invoke-Discovery` 호출.
    *   6시간 주기 체크 (Temp 폴더의 상태 파일 활용).
    *   `giipscripts/auto-discover-win.ps1` 실행 및 결과 수집.
    *   KVS (`auto_discover_result`)로 전체 JSON 전송.

4.  **모드 실행 (Mode Execution)**
    *   **Gateway Mode**: `is_gateway=1`인 경우 `scripts/GatewayMode.ps1` 실행.
    *   **Normal Mode**: 항상 `scripts/NormalMode.ps1` 실행.
    
5.  **종료 (Completion)**
    *   로그 기록 및 종료 (Exit Code 0).

---

## 4. 주요 모듈 및 함수

### 4.1. giipAgent3.ps1 (Main)
*   **역할**: 전체 흐름 제어, 의존성 확인, 하위 스크립트 호출.
*   **특징**: 직접적인 비즈니스 로직(작업 수행 등)을 포함하지 않고 오케스트레이션만 담당.

### 4.2. lib/Kvs.ps1 (KVS Logging)
*   **`Save-ExecutionLog`**: 실행 로그 저장 (Startup, Shutdown, Error 등).
*   **`Send-KVSPut`**: KVS API 호출 (`KVSPut` command).
    *   **규칙**: `text="KVSPut..."`, `jsondata={kType, ...}` 구조와 `token` 파라미터 사용.

### 4.3. lib/Cqe.ps1 (Command Queue)
*   **`Get-Queue`**: `CQEQueueGet` API를 호출하여 실행할 스크립트 확보.
    *   **Return**: 스크립트 Plain Text 내용 또는 `$null`.
    *   **Logic**: `RstVal`이 200이 아니거나 404인 경우 정상적으로 `$null` 반환.

### 4.4. lib/Discovery.ps1 (Infrastructure)
*   **`Invoke-Discovery`**: 주기적으로 Discovery 스크립트 실행.
    *   **Interval**: 6시간 (21600초). 상태 파일로 마지막 실행 시간 추적.
    *   **Action**: `giipscripts/auto-discover-win.ps1` 실행 -> JSON 결과 KVS 전송.

### 4.5. scripts/NormalMode.ps1 (Worker)
*   **역할**: 실제 작업(스크립트)을 받아와서 실행.
*   **Flow**:
    1.  `Get-Queue` 호출.
    2.  스크립트 존재 시 Temp 파일로 저장.
    3.  `& $tmpFile`로 실행.
    4.  Exit Code 및 Duration을 `Save-ExecutionLog`로 기록.

---

## 5. 설치 및 실행 가이드

### 5.1. 사전 준비
1.  **PowerShell 버전**: 5.1 이상.
2.  **설정 파일**: 상위 디렉토리(`../giipAgent.cfg`)에 필수 정보(`sk`, `lssn`, `apiaddrv2`) 포함.

### 5.2. Task Scheduler 등록 (권장)
Windows Agent는 Linux의 Cron과 유사하게 Task Scheduler를 통해 주기적으로 실행해야 합니다.

```powershell
# 1분 간격으로 실행 등록 예시 (관리자 권한 필요)
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\Path\To\giipAgentWin\giipAgent3.ps1"
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -Action $Action -Trigger $Trigger -TaskName "GIIP Agent V3" -User "System"
```

### 5.3. 디버깅
*   로그 위치: `../giipLogs/` (또는 `Common.ps1`에 정의된 위치).
*   수동 실행: PowerShell 콘솔에서 `.\giipAgent3.ps1` 직접 실행.

---

## 6. Linux Agent와의 차이점

| 항목 | Linux (`giipAgent3.sh`) | Windows (`giipAgent3.ps1`) |
| :--- | :--- | :--- |
| **언어** | Bash Shell Script | PowerShell |
| **실행 방식** | Cron | Task Scheduler |
| **Discovery** | `auto-discover-linux.sh` | `auto-discover-win.ps1` |
| **JSON 파싱** | `jq` 의존성 | `ConvertFrom-Json` (내장) |
| **HTTP Client** | `curl`, `wget` | `Invoke-RestMethod` |
