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
- **MS SQL/MySQL 모니터링**: `giipscripts/dpa-put-mssql.ps1`, `giipscripts/dpa-put-mysql.ps1`
  - DB 세션 및 쿼리 성능 데이터를 수집하여 KVS 또는 전용 API로 전송.
- **프로세스 리스트**: `giipscripts/modules/ProcessList.ps1`
  - `Get-Process` 결과물을 `Invoke-GiipKvsPut` 함수를 통해 KVS(`factor="process_list"`)로 업로드.

## 5. 네트워크 연결 분석
- **커넥션 리스트**: `giipscripts/modules/DbConnectionList.ps1`, `giipscripts/modules/HostConnectionList.ps1`
  - 서버 및 DB 간의 실시간 세션 연결 데이터를 분석하여 토폴로지 구성용 데이터 생성.

---

# 코드 수정 및 배포 체크리스트 (Standard Checklist)

## ✅ 설정 및 아키텍처
- [ ] **외부 설정 우선**: `Find-Config` 또는 `Get-GiipConfig`에서 `..` (상위 디렉토리) 탐색이 1순위인가?
- [ ] **샘플 파일 보호**: 소스 내의 `giipAgent.cfg`에 "SAMPLE" 문구가 있을 시 이를 실제 설정으로 읽지 않는가?
- [ ] **기본 브랜치 준수**: `git-auto-sync.ps1` 내 `$targetBranch` 기본값이 `real`로 설정되어 있는가?

## ✅ 기능 및 호환성
- [ ] **PowerShell 문법**: `@@{` (X) -> `@{` (O) 해시테이블 문법을 정확히 사용했는가?
- [ ] **로컬 변경사항 보호**: 동기화 전 `git stash`를 수행하여 사용자 수동 수정분을 보존하는가?
- [ ] **환경 변수**: `$Global:BaseDir` 등 에이전트 루트 경로 변수가 올바르게 참조되는가?

## ✅ 보안 및 배포
- [ ] **Token 노출 금지**: `sk` 등 비밀키 정보가 로그에 남거나 저장소에 Push되지 않는가?
- [ ] **로컬 검증**: 배포 전 `.\giipAgent3.ps1` 실행을 통해 정상 종료(Exit 0)를 확인했는가?
- [ ] **문서 현행화**: 기능 변경 시 `SPEC_AND_CHECKLIST.md`에 파일 및 함수 정보를 업데이트했는가?
