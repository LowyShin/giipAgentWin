# GIIP Agent 기능 명세서 (Function Specification)

giipAgent의 핵심 기능 리스트 및 기술적 상세 사양입니다.

## 1. 코어 에이전트 및 오케스트레이션
- **Main Entry Point**: `giipAgent3.ps1`
  - 에이전트 실행의 주 진입점. 라이브러리 로드 및 각 모듈(`CleanState`, `CqeGet`, `DbMonitor`, `ProcessList`)을 순차적으로 실행.
- **상태 관리 (State Management)**: `giipscripts/modules/CleanState.ps1`
  - `data/` 디렉토리 내의 이전 실행 파일(`queue.json`, `task_result.json` 등) 삭제 및 7일 경과된 로그 정리.
- **설정 로드 (Config Loader)**: `lib/Common.ps1` -> `Get-GiipConfig`
  - `giipAgent.cfg` 파일을 탐색 우선순위(Parent > UserProfile > Local)에 따라 파싱.
- **API 통신**: `lib/Common.ps1` -> `Invoke-GiipApiV2`
  - 중앙 서버와 HTTPS TLS 1.2로 통신하며, 동적 AK(Session Key) 관리를 수행.

## 2. 원격 명령 실행 (CQE 시스템)
- **명령 수집 (CqeGet)**: `giipscripts/modules/CqeGet.ps1`
  - `ManagedDatabaseListForAgent` 커맨드를 통해 실행 대기 중인 명령을 가져와 `data/queue.json`에 저장.
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
