# GIIP Agent 기능 명세서 (Function Specification)

giipAgent의 핵심 기능 리스트 및 기술적 상세 사양입니다.

## 1. 코어 에이전트 및 오케스트레이션
- **Main Entry Point**: `giipAgent3.ps1`
  - 에이전트 실행의 주 진입점. 라이브러리 로드 및 각 모듈(`CleanState`, `CqeGet`, `CqeRun`, `DbMonitor`, `ProcessList` ...)을 순차적으로 실행.
  - 실행 순서: Step 1 `CleanState` → Step 2 `CqeGet` → **Step 2.5 `CqeRun`** → Step 3 `DbMonitor` → Step 4 `ProcessList` → Step 5 `DbConnectionList` → Step 6 `HostConnectionList` → Step 7 `CollectEnhancedMetrics`.
- **상태 관리 (State Management)**: `giipscripts/modules/CleanState.ps1`
  - `data/` 디렉토리 내의 이전 실행 파일(`queue.json`, `task_result.json` 등) 삭제 및 7일 경과된 로그 정리.
  - giip #2546: **내용이 있는 `queue.json`을 지우게 되면 WARN 로그**를 남긴다. 정상 흐름이라면 `CqeRun`이 같은 실행 안에서 이미 소비했어야 하므로, 이 WARN 은 "받아만 놓고 실행하지 않은 작업을 버리는 중"이라는 회귀 신호다.
- **설정 로드 (Config Loader)**: `lib/Common.ps1` -> `Get-GiipConfig`
  - `giipAgent.cfg` 파일을 탐색 우선순위(Parent > UserProfile > Local)에 따라 파싱.
- **API 통신**: `lib/Common.ps1` -> `Invoke-GiipApiV2`
  - 중앙 서버와 HTTPS TLS 1.2로 통신하며, 동적 AK(Session Key) 관리를 수행.

## 2. 원격 명령 실행 (CQE 시스템)
- **명령 수집 (CqeGet)**: `giipscripts/modules/CqeGet.ps1`
  - `CQEQueueGet` 커맨드를 통해 실행 대기 중인 명령을 가져와 `data/queue.json`에 저장(`mslsn`/`mssn`/`script_type`/`ms_body`).
- **명령 실행 (CqeRun)**: `giipscripts/modules/CqeRun.ps1` — giip #2546 에서 복원
  - `data/queue.json`을 읽어 `ms_body`를 `script_type`에 맞는 임시 파일로 쓰고 실행한다.
  - **실행 전에 `data/queue_last.json`으로 옮겨 같은 실행 안에서 큐를 소비한다.** 다음 회차 `CleanState`가 미실행 큐를 지워 유실시키는 창을 없애기 위함이다(이 버그가 몇 달간 조용했던 구조 자체를 제거).
  - `{{sk}}` / `{{lssn}}` 플레이스홀더를 `giipAgent.cfg` 값으로 치환한다.
  - 지원 `script_type`
    | 값 | 실행 방식 | 타임아웃 | stdout 캡처 |
    |---|---|---|---|
    | `ps1` | `powershell.exe`, 창 없음 | `cqetimeoutsec`(기본 600초) | O |
    | `cmd` | `cmd.exe`, 창 없음 | `cqetimeoutsec`(기본 600초) | O |
    | `wsf` | `wscript.exe`, 창 없음 | `cqetimeoutsec`(기본 600초) | O |
    | `ps1ui` | `powershell.exe`, **보이는 콘솔 창**(`-NoExit`) | 없음(fire-and-forget) | X |
    | `cmdui` | `cmd.exe`, **보이는 콘솔 창**(`/k`) | 없음(fire-and-forget) | X |
  - `ui` 계열(`ps1ui`/`cmdui`)은 `claude` 같은 **대화형 TUI** 를 띄우기 위한 타입이다. stdout 을 리다이렉트하면 자식의 stdin 이 TTY 가 아니게 되어 그런 도구가 즉시 죽으므로(실측: `Error: Input contained only whitespace ...`), 출력 캡처와 창 표시는 양립할 수 없다. 따라서 실행 이력에는 **"프로세스 기동 성공/실패"만** 기록된다.
  - `ui` 계열은 Task Scheduler 작업이 **LogonType=Interactive(사용자 세션)** 로 돌 때만 창이 실제로 보인다.
- **실행기 라이브러리**: `lib/ScriptRunner.ps1` (`Invoke-ScriptBlock`), 실행 이력: `lib/ExecutionLog.ps1` (`Save-ExecutionLog`)
  - 실행 이력은 KVS `kFactor='giipagent'` 에 `{"event_type":"script_execution","details":{"script_type","exit_code","execution_time_seconds","mslsn","mssn","mode","success","output"}}` 형태로 남는다(Linux 에이전트 `lib/kvs.sh` `save_execution_log()` 와 동일 의미론).
  - giipv3 `cqelsvrRunList` 화면의 **[KVS]** 버튼이 `/{locale}/kvslist?kKey=<lssn>&kFactor=giipagent&mslsn=<mslsn>` 로 이동하므로, 이 형식이어야 화면에서 실행 결과가 보인다(giip-967).
- **자동 업데이트 (Auto-Sync)**: `git-auto-sync.ps1`
  - 설정된 브랜치(`real` 또는 `main`)로 Git Pull 수행.

## 3. 인프라 자동 검색 (Auto-Discovery)
- **데이터 수집**: `giipscripts/auto-discover-win.ps1`
  - `Get-CimInstance`, `Get-NetIPAddress`, `Get-Service` 등을 사용하여 시스템/네트워크/소프트웨어 정보를 JSON으로 생성.
- **데이터 전송**: `giip-auto-discover.ps1`
  - 수집된 데이터를 `AgentAutoRegister` API를 통해 중앙 서버로 전송.

## 4. 데이터베이스 및 프로세스 모니터링
- **데이터베이스 모니터링 (DbMonitor)**: `giipscripts/modules/DbMonitor.ps1`
  - **접속 정보 수집**: `ManagedDatabaseListForAgent` API를 통해 중앙 서버에 등록된 DB 목록 및 접속 정보(Host, Port, User, Password 등)를 동적으로 수집.
  - **지표 수집**: 수집된 접속 정보를 바탕으로 `lib/DbCollector.ps1` 라이브러리를 사용하여 MSSQL/MySQL 성능 지표(Uptime, Threads, QPS 등)를 수집.
  - **결과 전송**: `MdbStatsUpdate` API를 통해 수집된 데이터를 중앙 서버로 전송.
- **프로세스 리스트**: `giipscripts/modules/ProcessList.ps1`
  - `Get-Process` 결과물을 `Invoke-GiipKvsPut` 함수를 통해 KVS(`factor="process_list"`)로 업로드. DB 컬럼 크기 제한을 고려하여 상위 100개 프로세스 정렬 및 문자열 절단 처리 수행.

## 5. 네트워크 연결 분석
- **커넥션 리스트**: `giipscripts/modules/DbConnectionList.ps1`, `giipscripts/modules/HostConnectionList.ps1`
  - 서버 및 DB 간의 실시간 세션 연결 데이터를 분석하여 토폴로지 구성용 데이터 생성.

---

# 코드 수정 및 배포 체크리스트 (Standard Checklist)

## ⚠️ 0단계: 절대 금기 사항 (Absolute Prohibition)
- [x] **AI는 `real` 브랜치에 직접 Push하지 않는다.** (운영 서버 보호)
- [x] **AI는 임의로 브랜치를 전환하여 Push하지 않는다.** (작업은 오직 `main`에서 수행)

## 🔍 1단계: 코드 내용 검증 (Content Verification)
- [x] **버전 확인**: `git-auto-sync.ps1`의 버전이 최신(현재 v1.3.9)이며 `Last Updated`가 오늘 날짜인가?
- [x] **기본 브랜치 확인**: 코드 내 `$targetBranch = "real"`로 명시되어 있는가? (절대 `main`이 아님을 확인)
- [x] **우선순위 확인**: `Find-Config` 함수에서 `Split-Path $StartPath -Parent` (상위 폴더) 탐색이 가장 먼저 실행되는가?
- [x] **샘플 필터링**: 로컬 디렉토리의 `giipAgent.cfg` 탐색 시 "SAMPLE" 문구가 포함된 파일을 무시하는 로직이 작동하는가?

## 🛠 2단계: 기능 및 문법 검증 (Functional Test)
- [x] **PowerShell 오타**: `@@{` 와 같은 해시테이블 문법 오류가 없는가?
- [x] **로컬 실행**: `.\giipAgent3.bat` 또는 `.\gitautosync.bat`을 실행하여 `Exit code: 0`을 확인했는가?
- [x] **로그 확인**: 실행 로그(`logs/`)에 타겟 브랜치가 `real`로 정확히 표시되는가?

## 🚀 3단계: 배포 전 최종 체크 (Pre-Push Check)
- [x] **Git Branch 확인**: `git branch` 명령으로 현재 위치가 `main`임을 확인했는가?
- [x] **Git Status 확인**: 의도하지 않은 파일(예: `giipAgent.cfg` 등 비밀정보)이 포함되지 않았는가?
- [x] **커밋 메시지**: 수정 사항과 준수한 사양(v1.3.9 등)을 메시지에 명시했는가?
