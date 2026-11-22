# GIIP Agent 기능 명세서 (Function Specification)

giipAgent의 핵심 기능 리스트 및 기술적 상세 사양입니다.

> **현재 호출되지 않는 경로 5개**(`giipAgentWin.ps1`, `lib/Worker.ps1`, `lib/Cqe.ps1`,
> `scripts/NormalMode.ps1`, `lib/Discovery.ps1`)의 용도·처리·저장위치·소비처와,
> 왜 만들어졌고 언제부터 왜 안 쓰이게 됐는지는
> **[`docs/SPEC_UNCALLED_PATHS.md`](./SPEC_UNCALLED_PATHS.md)** 에 있습니다(giip #2556).
> 그 문서에는 도달 불가 상태로 숨어 있던 결함 7건과 수정 내역도 함께 기록돼 있습니다.

## 1. 코어 에이전트 및 오케스트레이션

### 1.1 구조 원칙 (giip #6163 — Lowy 지시 2026-11-22)
- **메인 태스크(슈퍼바이저)는 가볍고 안정적으로 유지**한다. 실제 작업은 언제든 **종료·리셋**할 수 있는
  서브 태스크(워커)가 수행한다.
- 한 Step 이 멈춰도 **그 Step(과 그 자식 프로세스 트리)만** 강제 종료되고 **다음 Step 은 계속**된다
  (giip #5924 — Step 7 의 행 하나가 3일간 전체 사이클을 정지시킨 사고의 근본 해결).
- 슈퍼바이저는 무거운 작업(WMI 조회, 외부 도구 실행, 대용량 수집)을 **직접 하지 않는다** —
  그 일은 전부 워커 프로세스(= Step 모듈) 안에서 일어난다.

### 1.2 진입점 계층과 Step 실행 순서
- **Task Scheduler 진입점**: `TaskSchdReg.ps1` 가 등록하는 예약 작업 액션
  `conhost.exe --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File giipAgent3-launcher.ps1`
  → `giipAgent3-launcher.ps1` (= `git-auto-sync.ps1` 실행 후 `giipAgent3.ps1` 실행)
- **메인 태스크(슈퍼바이저)**: `giipAgent3.ps1`
  - Step 1~8 을 **직접 실행하지 않는다**. 각 Step 을 별도 프로세스(워커 = `giipAgentWorker.ps1`)로 띄워 실행한다.
  - **실행 순서(기존 목록 유지)**: Step 1 `CleanState` → Step 2 `CqeGet` → **Step 2.5 `CqeRun`** →
    Step 3 `DbMonitor` → Step 4 `ProcessList` → Step 5 `DbConnectionList` → Step 6 `HostConnectionList` →
    Step 7 `CollectEnhancedMetrics` → Step 8 `CollectDockerMetrics` (총 9개 Step).
  - **바뀐 것은 실행 방식뿐**: 각 Step 은 이제 같은 프로세스 안이 아니라 **워커 프로세스**에서 실행된다.
  - Step 간 데이터 전달은 전부 **파일 기반**(`data/queue.json` 등)이라 프로세스가 나뉘어도 흐름이 유지된다
    (Step 2 가 만든 큐를 Step 2.5 가 소비하고, Step 2.5 는 실행 전에 큐를 `data/queue_last.json` 으로 옮겨 소비한다).
- **워커 호스트**: `giipAgentWorker.ps1` (아래 1.4)

### 1.3 슈퍼바이저의 책임 (`giipAgent3.ps1`)
| 책임 | 구현 | 비고 |
|---|---|---|
| 락(중복 실행 방지) | `lib/ProcessLock.ps1` 의 `Enter-GiipAgentLock` / `Exit-GiipAgentLock` | 락 파일 `giipAgent3.lock`, stale 기준 30분. 종료 시 `finally` 에서 항상 해제 |
| 실행 이력(RunStart/RunEnd) | `lib/SchedulerAgentRun.ps1` 의 `Invoke-SchedulerAgentRunStart` / `Invoke-SchedulerAgentRunEnd` | RunStart 가 실패/스킵됐으면 RunEnd 는 호출하지 않는다(짝이 안 맞는 호출 방지) |
| 워커 기동·감시·강제 종료 | `giipAgent3.ps1` 의 `Invoke-GiipStepWorker` | 워커 기동 → 제한 시간 대기 → 필요 시 프로세스 트리 강제 종료 |
| Step 순서·타임아웃 결정 | `giipAgent3.ps1` 의 `$steps` 목록 + `steptimeout_*` 설정 | 아래 1.5 |

- **큐 조회·소비는 Step 워커의 몫**이다: Step 2 `CqeGet` 워커가 `CQEQueueGet` 으로 큐를 받아
  `data/queue.json` 에 쓰고, Step 2.5 `CqeRun` 워커가 그 큐를 소비한다.
  **슈퍼바이저는 CQE API 를 직접 호출하지 않는다.**
- 슈퍼바이저가 직접 하는 외부 통신은 `RunStart`/`RunEnd` 뿐이고(WMI·외부 도구·대용량 수집 없음),
  수집 작업은 전부 워커(= Step 모듈) 안에서 일어난다.
- 라이브러리 로드 순서(필수): `lib/Common.ps1` → `lib/KVS.ps1`(또는 `Kvs.ps1`) → `lib/ProcessLock.ps1` →
  `lib/SchedulerAgentRegister.ps1` → `lib/SchedulerAgentRun.ps1`.

### 1.4 워커 호스트 (`giipAgentWorker.ps1`)
- **인자**: `-StepName`(로그용 Step 이름), `-ModuleScript`(실행할 모듈 경로), `-ResultFile`(선택).
- **슈퍼바이저와 동일한 초기화 환경**을 만든다 — `$Global:BaseDir`, `giipscripts/modules`, `lib` 경로,
  `lib/Common.ps1` + KVS 로드, `[Console]::OutputEncoding = UTF-8`(한글 깨짐 방지), `Get-GiipConfig`.
  - Step 모듈 중 `ProcessList.ps1` 은 `$Global:BaseDir` 를, `CleanState.ps1` 은 `Write-GiipLog` 를
    상위 스코프에서 물려받아 쓰므로 이 재현이 필수다.
- **모듈 1개만** `&` 로 실행하고 그 종료코드로 종료한다. 모듈이 예외를 던지면 워커는 `1` 로 끝난다.
  (모듈이 `exit` 을 호출하지 않으면 마지막 native 명령의 코드를 물려받지 않도록 `$LASTEXITCODE` 를 먼저 0 으로 초기화한다)
- **락 획득과 RunStart/RunEnd 는 하지 않는다** — 슈퍼바이저의 일이다(워커가 하면 실행 이력이 두벌 생긴다).
  그래서 워커는 `ProcessLock`/`SchedulerAgentRegister`/`SchedulerAgentRun` 을 로드하지 않는다.
- 워커 기동 방식은 슈퍼바이저가 등록한 Task Scheduler 진입점과 **똑같은 패턴**이다
  (`conhost.exe --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File giipAgentWorker.ps1 ...`,
  AGENTS.md 2번 "진입점과 창 숨김 방식은 고정"). vbs/LOLBin/`-EncodedCommand`/`-WindowStyle Hidden` 은 쓰지 않는다.
- **결과 파일 규약**: 워커는 `%TEMP%/giip_step_<Step 라벨(숫자만)>_<토큰>.json` 에 JSON 을 남긴다
  (`step`/`pid`/`state`/`exitCode`/`at`).
  | `state` | 기록 시점 | `exitCode` |
  |---|---|---|
  | `running` | 기동 직후(자기 PID) | `null` |
  | `finished` | 종료 직후 | 실제 종료코드 |
  - 목적: 래퍼(`conhost.exe --headless`)가 자식의 종료코드를 그대로 되돌려주지 않아도
    **워커가 직접 기록한 종료코드**로 Step 실패를 판정할 수 있게 한다. 타임아웃 때 워커 PID 를
    직접 kill 하는 용도로도 쓴다.
  - 기록 실패는 best-effort 다(슈퍼바이저가 프로세스 종료코드로 대체 판정한다).

### 1.5 Step 별 타임아웃
- **기본값**(코드 `giipAgent3.ps1` 의 `$steps` 목록, 단위 초):

  | Step | 모듈 | 기본 타임아웃 | 설정 키(`giipAgent.cfg`) |
  |---|---|---|---|
  | 1 | `CleanState` | 60 | `steptimeout_cleanstate` |
  | 2 | `CqeGet` | 90 | `steptimeout_cqeget` |
  | 2.5 | `CqeRun` | 720 (= `cqetimeoutsec` 600 + 120) | `steptimeout_cqerun` |
  | 3 | `DbMonitor` | 420 | `steptimeout_dbmonitor` |
  | 4 | `ProcessList` | 120 | `steptimeout_processlist` |
  | 5 | `DbConnectionList` | 180 | `steptimeout_dbconnectionlist` |
  | 6 | `HostConnectionList` | 180 | `steptimeout_hostconnectionlist` |
  | 7 | `CollectEnhancedMetrics` | 240 | `steptimeout_collectenhancedmetrics` |
  | 8 | `CollectDockerMetrics` | 180 | `steptimeout_collectdockermetrics` |

- 키 이름 규칙: `steptimeout_<Step 모듈명 소문자>` (예: `steptimeout_dbmonitor = "600"`).
  키가 있으면 해당 Step 의 기본값을 대체하고, 없으면 기본값을 쓴다.
- `CqeRun` 만 기본값 계산이 다르다: **`cqetimeoutsec`(기본 600) + 120 = 720**.
  `cqetimeoutsec` 는 `CqeRun` 이 **CQE 스크립트 1건**을 실행하는 시간 제한으로도 쓰이므로(§2),
  워커 전체 시간 제한(기본 720)과는 구분해야 한다. `steptimeout_cqerun` 을 주면 이 계산값을 대체한다.
- 값이 양의 정수가 아니면 WARN 로그를 남기고 **기본값을 유지**한다.

### 1.6 실패 처리
- **타임아웃**(워커가 제한 시간 안에 끝나지 않음):
  1. `taskkill.exe /PID <슈퍼바이저가 띄운 프로세스 id(conhost 래퍼)> /T /F` 로
     **프로세스 트리 전체**(워커와 그 자식 프로세스 포함)를 강제 종료한다.
  2. 워커 PID 를 추가로 kill 한다 — 래퍼가 먼저 죽어 워커가 고아(orphan)로 남는 경우 대비.
  3. 그래도 남아 있으면 `Stop-Process -Id <id> -Force` 로 마무리한다.
  4. `[Step N] Worker timeout after {n}s - killed, continuing (pid=...)` ERROR 로그를 남기고 **다음 Step 을 계속**한다.
     (정리가 실패해도 `kill failed` / `worker still alive` 메시지를 남긴 뒤 계속 진행한다)
- **워커 종료코드 ≠ 0**: `[Step N] Worker failed (exit code {code}, duration={n}s) - continuing` ERROR 로그를
  남기고 **기록만 하고 다음 Step 을 계속**한다. 래퍼와 워커의 종료코드가 다르면
  `Worker exit code mismatch (launcher=..., worker=...)` WARN 후 **워커 값**을 쓴다.
- **Step 모듈 파일이 없으면**: 조용히 건너뛴다(`Skipped`) — 배포 이상으로 전체 사이클을 죽이지 않는다.
  건너뛴 Step 은 **실패로 세지 않으므로**(종료코드·RunEnd 상태에 영향 없음) 배포 오류 신호로
  로그의 `Module not found ... skipped` WARN 을 본다.
- **에이전트 종료코드**: 실패/타임아웃이 하나라도 있으면 `exit 1`, 없으면 `exit 0`.
- **RunEnd 상태**(`lib/SchedulerAgentRun.ps1` 의 `ValidateSet` = SP `pApiSchedulerAgentRunEndBySK` 의 `@status`
  지원값과 동일 — 새 값을 만들지 않는다):

  | 조건 | RunEnd 상태 | 종료코드 |
  |---|---|---|
  | 타임아웃 Step 있음 | `TIMED_OUT` | 1 |
  | 그 외 실패 Step 있음 | `FAILED` | 1 |
  | 실패 없음 | `SUCCEEDED` | 0 |

- **실패 Step 목록 summary**: `timedOut=Step3:DbMonitor,failed=Step2:CqeGet:exit3` 형태(콤마 구분)로
  RunEnd 의 `summary` 파라미터에 실린다. `lib/SchedulerAgentRun.ps1` 이 1000자로 절단한다.
- **검증**: `tests/Test-SupervisorWorker.ps1` 가 스텁 모듈로 (1) 타임아웃 강제 종료 후 다음 Step 진행,
  (2) 종료코드 전파, (3) 래퍼가 종료코드를 먹는 경우, (4) 정상 경로를 확인한다.

### 1.7 Phase 2 (예정 — 현재 미구현)
아래는 **구현된 것이 아니라 예정된 항목**이다(현행 구현 범위는 1단계 = 프로세스 분리까지다).
- **CQE 제어 명령으로 워커 리셋/종료**: 큐(CQE)로 들어오는 제어 명령이 실행 중인 Step 워커를
  중지·리셋할 수 있게 하는 제어 채널. (구현 예정)
- **워커 단위 실행 기록**: Step 별 PID·종료코드·소요시간을 서버 쪽 실행 이력에 별도 단위로 남기는 것.
  현행 실행 이력은 **사이클 단위**(RunStart/RunEnd) 하나뿐이다. (구현 예정)

### 1.8 공통 라이브러리 (모든 Step 공통)
- **상태 관리 (State Management)**: `giipscripts/modules/CleanState.ps1` (Step 1)
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
  - **`script_type` 정규화**: `CQEQueueGet` 이 돌려주는 값은 `tMgmtQue.script_type` 이고, 그것은 `pCQEForcebyUsn` 이 **`tMgmtScript.msType` 을 그대로 복사**한 것이다(큐 등록 화면에서 고른 `tMgmtScriptList.script_type` 이 아니다). `msType` 은 자유 입력 `varchar(5)` 라 실운영 데이터에 `.ps1`(앞에 점) / `bat` / 빈 값이 섞여 있다(2026-09-15 lssn=71197 실측). 따라서 소문자화 + 앞의 점 제거 + 별칭 매핑(`powershell`/`pwsh`→`ps1`, `bat`/`batch`/`cmdwin`→`cmd`, 빈 값→`ps1`)을 거쳐 실행한다.
- **실행기 라이브러리**: `lib/ScriptRunner.ps1` (`Invoke-ScriptBlock`), 실행 이력: `lib/ExecutionLog.ps1` (`Save-ExecutionLog`)
  - 실행 이력은 KVS `kFactor='giipagent'` 에 `{"event_type":"script_execution","details":{"script_type","exit_code","execution_time_seconds","mslsn","mssn","mode","success","output"}}` 형태로 남는다(Linux 에이전트 `lib/kvs.sh` `save_execution_log()` 와 동일 의미론).
  - giipv3 `cqelsvrRunList` 화면의 **[KVS]** 버튼이 `/{locale}/kvslist?kKey=<lssn>&kFactor=giipagent&mslsn=<mslsn>` 로 이동하므로, 이 형식이어야 화면에서 실행 결과가 보인다(giip-967).
- **스케줄 필드의 의미 (`tMgmtScriptList`)** — giip #2561
  | 필드 | 의미 | 주의 |
  |---|---|---|
  | `active` | 큐 배급 대상 여부. `1` 이면 `CQEQueueGet` 이 이 lssn 의 활성 항목을 **로테이션으로 계속 배급**한다 | **on-demand(force-run) 전용 스크립트는 `active=0` 이어야 한다.** `1` 로 두면 영구 반복된다 |
  | `interval` | `0` 은 **"주기 없음"이 아니라 "매 로테이션마다 재배급"** 이다 | 활성 큐 N건 × 5분 폴링 = 약 `N×5`분 주기로 재실행된다(실측: N=3 → 약 15분) |
  | `repeat` | `1` 이면 1회 실행 후 비활성화되는 1회성 등록 | 검증용 임시 등록에 쓴다 |
  | `script_type` | 큐 배급 시 실제로 쓰이는 값은 이 컬럼이 **아니라** `tMgmtScript.msType` 이다(위 "정규화" 항목) | 화면에서 고른 값과 실행 타입이 다를 수 있다 |

  giip #2561 실측 사고: `mslSn=8039`(msSn=6096, `cleanup-stale-worktrees.cqe`)는 스크립트 본문 첫
  줄이 스스로 `On-demand only (force-run)` 이라고 선언하는데 `active=1, interval=0` 으로 등록돼
  있어, **파괴적인 worktree 정리가 약 15분마다 무인으로 반복 실행**되고 있었다.
- **CQE 스크립트 본문 작성 규칙** — giip #2561
  1. **본문을 `tMgmtScript.msBody` 에만 두지 않는다.** DB 안의 본문은 리뷰·이력·롤백이 불가능하고
     레포의 규칙·테스트 어느 것에도 닿지 않는다. 정본은 git-tracked 파일에 두고 `msBody` 는 그
     파일을 호출하는 **얇은 런처**로 만든다(정본 폴더: `lowyworkenv/scripts/cqe/`).
  2. **`$ErrorActionPreference = 'Stop'` 상태에서 네이티브 exe 의 stderr 를 리다이렉트하지 않는다**
     (`2>$null`, `2>&1` 모두 해당). CQE 의 `ps1` 은 `powershell.exe`(**Windows PowerShell 5.1**)로
     실행되는데, 5.1 은 네이티브 exe 가 stderr 에 한 줄이라도 쓰면 **exe 의 종료코드가 0 이어도**
     그 줄을 `NativeCommandError` `ErrorRecord` 로 감싸 던지고, `Stop` 과 만나면 종료성 오류가 된다.
     실측(2026-09-15 19:45): `git branch -d ... 2>&1` 이 git 의 성공 경고(`warning: deleting
     branch '...' that has been merged to`) 한 줄에 죽어 `exit_code=1` 로 끝났다. **PowerShell 7
     에서 잘 돌던 스크립트를 그대로 붙이면 재발한다.** 정본 형태는 `Continue` + 호출 직후
     `$LASTEXITCODE` 직접 검사다.
  3. **stdout 에 한글을 의존하지 않는다.** CqeRun 은 자식 stdout 을 콘솔 코드페이지로 읽어 한글이
     `?` 로 뭉개진다. 상태 라인은 ASCII 로 쓰고, 한국어 상세는 UTF-8 로그 파일에 남긴다.
  4. 실행 이력에 실리는 `output` 은 **2000자에서 절단**된다(`CqeRun.ps1`). 중간 사망 여부는 출력
     끝의 요약 마커 도달 여부로 판별할 수 있게 스크립트가 **마지막에 요약을 찍도록** 만든다.
- **자동 업데이트 (Auto-Sync)**: `git-auto-sync.ps1`
  - 설정된 브랜치(`real` 또는 `main`)로 Git Pull 수행.
  - **독립성(giip 3079)**: `giipAgent3-launcher.ps1`이 `giipAgent3.ps1`보다 먼저 실행하므로
    에이전트 본 로직(API 호출 등)의 실패가 pull 자체를 막을 수는 없었다. 다만 반대 결합이
    있었다 - sync가 실패하면 이번 주기의 `giipAgent3.ps1` 실행을 통째로 건너뛰었다. 코드 갱신과
    모니터링 업무는 서로 무관하므로 분리했다: sync 실패는 로그만 남기고 `giipAgent3.ps1`은 계속
    실행한다(다음 5분 주기가 sync를 독립적으로 재시도).

## 3. 인프라 자동 검색 (Auto-Discovery)
- **실행 경로**: Task Scheduler 작업 `"GIIP Auto-Discovery (v3)"` (6시간 주기, `TaskSchdReg.ps1` 가 등록)
  → `giip-auto-discover-launcher.ps1` → `giip-auto-discover.ps1` → `giipscripts/auto-discover-win.ps1`
  → `lib/Common.ps1:Invoke-GiipApiV2` → giipfaw SK 인증 디스패처 → giipdb
  `SP/pApiAgentAutoRegisterBySK.sql` → `tLSSvr`(LSSpec*·LSNIFGlobal/LSNIFLocal) + `tKVS`
  (`kFactor='auto_discover_result'`).
  - giip #3559: 이 태스크는 등록만 되어 있었고 **한 번도 성공한 적이 없었다**(아래 두 결함).
    고친 뒤에도 서버 SP 가 읽는 키가 빠지면 UPDATE 가 해당 컬럼을 NULL 로 덮어쓴다.
- **설정 파일 위치**: `lib/Common.ps1:Get-GiipConfig` — `giipAgent.cfg` 를
  **① 저장소 상위 폴더 → ② `%USERPROFILE%` → ③ 저장소 루트** 순으로 찾는다
  (머리글에 `SAMPLE` 이 있는 파일은 템플릿으로 간주해 건너뛴다).
  - giip #3559: 예전 `giip-auto-discover.ps1` 는 저장소 루트만 찾아 "Configuration file not
    found" 로 종료했다(로그 기록보다 앞에서 끝나서 실패 흔적조차 안 남았다).
    → 저장소 표준 로더(`Get-GiipConfig`)를 쓰도록 수정.
- **API 호출 경로**: `Invoke-GiipApiV2 -Config <cfg> -CommandText "AgentAutoRegister hostname jsondata" -JsonData <수집 JSON>`
  - 엔드포인트는 cfg 의 **`apiaddrv2`**(= SK 인증 디스패처 URL, 예: `.../api/giipApiSk2`).
    `text` 는 "명령어 + 파라미터 이름" 이고 실제 값은 `jsondata` 에서 치환된다.
  - giip #3559: 예전 코드는 cfg 에 없는 키(`apiaddr`)와 dispatcher 가 읽지 않는 쿼리 파라미터
    (`cmd=`)를 써서 AK 기반 `giipApi` 로 갔다 → 위 표준 경로로 교체.
  - **성공 판정**: SP 응답의 `Proc_MSG` 가 `'200|*'` 이거나 `RstVal` 이 `200` 이어야 성공이다
    (7장의 "API 호출 실패 보고 원칙" 적용 — 응답을 확인하지 않고 성공 로그를 남기지 않는다).
  - **최초 등록**: cfg 의 `lssn` 이 `0` 이고 응답에 `lssn` 이 있으면
    `Update-ConfigLssn` 으로 cfg 를 갱신한다(저장소 상위 폴더 → `%USERPROFILE%` 순).
  - **로그**: `<저장소 상위>\giipLogs\giip-auto-discover_<yyyyMMdd>.log` (자동탐색 전용) +
    `lib/Common.ps1:Write-GiipLog` 의 `<저장소 상위>\giipLogs\giipAgentWin_<yyyyMMdd>.log`.
- **데이터 수집**: `giipscripts/auto-discover-win.ps1`
  - `Get-CimInstance`, `Get-NetIPAddress`, `Get-Service` 등을 사용하여 시스템/네트워크/소프트웨어 정보를 JSON으로 생성.
- **서버 SP(`pApiAgentAutoRegisterBySK.sql`)가 읽는 JSON 키 8개** — 하나라도 빠지면
  UPDATE 가 해당 컬럼을 NULL 로 덮어쓴다(heartbeat 갱신):
  | 키 | 의미 | Windows 수집 방법 | 비어 있을 때 서버 동작 |
  |---|---|---|---|
  | `os` | OS 이름+버전 | `Win32_OperatingSystem` | — |
  | `cpu` | CPU 모델 문자열 | `Win32_Processor` | — |
  | `cpu_cores` | **논리** CPU 수 (`LSSpecCPUs`) | `NumberOfLogicalProcessors` | `NULL` 로 덮어씀 |
  | `memory_gb` | 메모리 GB (`LSSpecRAMGB`) | `TotalVisibleMemorySize` | — |
  | `disk_gb` | 시스템 볼륨 전체 GB (`LSSpecDiskSizeGB`) | `Win32_LogicalDisk`(`$env:SystemDrive`) | `NULL` 로 덮어씀 |
  | `agent_version` | 에이전트 버전 (`LSAgentVer`) | 호출부(`giip-auto-discover.ps1`)가 추가 | `NULL` 로 덮어씀 |
  | `ipv4_global` | 공인 IPv4 (`LSNIFGlobal`) | NIC IPv4 중 공인 IP 첫 개 | **빈 문자열이면 서버가 마지막 값을 유지** (`COALESCE(NULLIF(...), LSNIFGlobal)`) |
  | `ipv4_local` | 사설 IPv4 (`LSNIFLocal`) | NIC IPv4 중 사설 IP 첫 개 | `NULL` 로 덮어씀 |
  - `ipv4_global` 판정은 Linux 에이전트(`giipAgentLinux/scripts/auto-discover-linux.sh`)와 같은 기준이다.
    NAT 된 사내 PC 에서는 공인 IP 가 없으므로 **빈 문자열**이 정상값이다(외부 echo 조회는 하지 않는다).
  - 판정 기준: 사설 = `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` /
    공인 = 루프백(`127.*`)·링크로컬(`169.254.*`)·`0.*`·사설을 제외한 나머지.
  - **키를 추가/이름을 바꾸려면 이 표와 `giipdb/SP/pApiAgentAutoRegisterBySK.sql` 를 함께 고쳐야 한다.**

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

## 6. Docker 리소스 수집 (giip 3043, 1/4 단계)
- **Docker 리소스 메트릭**: `giipscripts/modules/CollectDockerMetrics.ps1`
  - Docker Instances "Provision now" 드롭다운에서 lssn 별 리소스 여유도를 보여주기 위한 4단계
    작업 중 **1단계(수집)** 만 담당한다. 화면/드롭다운 자체는 giipv3 쪽 2~4단계에서 별도로 구현된다.
  - **감지**: `Get-Command docker`로 CLI 존재를 확인하고, `docker version --format
    '{{.Server.Version}}'` 실행 성공 여부로 데몬 기동 여부를 판정한다. CLI 가 없거나 데몬이 응답하지
    않으면 `dockerInstalled=$false` 만 KVS 에 올리고 나머지 수집은 건너뛴다 — Docker 가 설치되지
    않은 서버가 대부분일 것이므로 이것이 **정상 경로**이며 에러로 취급하지 않는다.
  - **수집 항목**(설치돼 있을 때만): `docker info --format '{{json .}}'` 로
    `ContainersRunning`/`Containers`/`Images` 개수를, `docker system df --format '{{json .}}'` 로
    타입별(Images/Containers/Local Volumes/Build Cache) `Size`/`Reclaimable` 크기 문자열(예:
    `"1.199GB"`, `"113.2MB (69%)"`)을 가져와 GB 단위 합계로 환산한다. 각 cmd 파싱은 개별
    try/catch 로 감싸 한쪽이 실패해도 나머지 수집과 업로드는 계속된다.
  - **업로드**: `Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor
    "docker_usage" -Value $payload` (기존 `performance_metrics`/`process_list` 와 동일한 KVS
    인프라를 재사용, 신규 테이블 없음). Payload 필드:
    `dockerInstalled`/`dockerVersion`/`containersRunning`/`containersTotal`/`imagesCount`/
    `diskUsedGb`/`diskReclaimableGb`/`collectedAt`.
  - **호출 등록**: `giipAgent3.ps1` Step 8(Step 7 `CollectEnhancedMetrics` 다음).
  - **미검증 사항(2026-09-25)**: 이 작업을 수행한 Windows 개발 PC에는 Docker Desktop 이 설치돼
    있지 않아 `docker info`/`docker system df` 의 **실제 출력 포맷을 라이브로 검증하지 못했다**.
    구현은 Docker CLI 공식 문서상 알려진 포맷(정보 필드명, `docker system df --format
    '{{json .}}'` 가 타입별로 한 줄씩 JSON 을 출력하는 방식)에 근거한 추정이며, 문법 검사(PowerShell
    파서)만 통과했다. Docker 가 실제로 설치된 서버에서 1회 실측 후 파싱 로직이 맞는지 확인이
    필요하다.

## 7. API 호출 실패 보고 원칙 (giip 3079)
- **문제(csn 70418 실측)**: `Invoke-GiipApiV2`(`lib/Common.ps1`)는 애플리케이션 레벨 실패
  (HTTP 200 응답 안에 `RstVal != 200`)에도 예외를 던지지 않고 응답 객체를 그대로 반환한다
  (네트워크 예외/URI 누락일 때만 `$null`). 여러 호출부가 반환값을 `Out-Null`로 버리거나 확인
  없이 무조건 "성공" 로그를 남기고 있었다 - 대표 사례가 `CollectDockerMetrics.ps1`(giip 3043
  당일 작성분)이었다.
- **원칙**: `Invoke-GiipApiV2`/`Invoke-GiipKvsPut`을 호출하는 모든 코드는 반환값의 `RstVal`을
  실제로 확인한 뒤에만 성공 로그를 남긴다. 실패 시:
  1. `Write-GiipLog "ERROR" ...`로 정직하게 남기고
  2. `lib/Common.ps1`의 `Write-GiipApiFailure` 헬퍼를 사용해 giip 서버에도 보고한다. 이 헬퍼는
     ERROR 로그 + 기존에 이미 있었지만 어디서도 호출되지 않던 `lib/ErrorLog.ps1`의
     `sendErrorLog`(`ErrorLogCreate` SP)를 재사용한다 - 새 giipfaw 엔드포인트를 만들지 않았다.
- **giipfaw `agent-log-*` 계열과의 관계**: `giipfaw/agent-log-ingest`·`agent-log-register` 등은
  스트림 등록(`streamKey`)과 시퀀스 번호(`fromSequence`/`toSequence`) 추적이 필요한 별도의
  대용량 로그 라인 수집 파이프라인이다. 단발성 실패 보고에 쓰기엔 새 통합 작업(등록 플로우,
  회전/시퀀스 관리)이 필요해 이번 범위에서는 채택하지 않았다 - 필요해지면 별도 이슈로 검토.
- `Invoke-GiipApiV2` 내부 실패 로그 레벨도 DEBUG -> WARN/ERROR로 상향했다(DEBUG로만 남아 사람이
  보는 로그에 실패가 안 보였던 것이 근본 원인 중 하나였다).

---

# 코드 수정 및 배포 체크리스트 (Standard Checklist)

## ⚠️ 0단계: 절대 금기 사항 (Absolute Prohibition)
- [x] **AI는 `real` 브랜치에 직접 Push하지 않는다.** (운영 서버 보호)
- [x] **AI는 임의로 브랜치를 전환하여 Push하지 않는다.** (작업은 오직 `main`에서 수행)

## 🔍 1단계: 코드 내용 검증 (Content Verification)
- [x] **버전 확인**: `git-auto-sync.ps1`의 버전이 최신(현재 v1.3.9)이며 `Last Updated`가 오늘 날짜인가?
- [x] **기본 브랜치 확인**: 코드 내 `$targetBranch = "real"`로 명시되어 있는가? (절대 `main`이 아님을 확인)
- [x] **우선순위 확인**: `lib/Common.ps1:Get-GiipConfig` 가 `Split-Path -Path <base> -Parent` (상위 폴더) 탐색을 가장 먼저 실행하는가?
- [x] **샘플 필터링**: 상위 폴더 / `%USERPROFILE%` 에서 `giipAgent.cfg` 를 찾을 때 머리글 10줄에 "SAMPLE" 이 있으면 무시하는 로직이 작동하는가?
  (저장소 루트 3순위 탐색에는 이 필터가 없다 — 그 위치의 파일은 예제여도 그대로 읽는다)

## 🛠 2단계: 기능 및 문법 검증 (Functional Test)
- [x] **PowerShell 오타**: `@@{` 와 같은 해시테이블 문법 오류가 없는가?
- [x] **로컬 실행**: `.\giipAgent3.bat` 또는 `.\gitautosync.bat`을 실행하고 종료코드를 확인했는가?
  - **종료코드 판정(giip #6163)**: `giipAgent3.ps1`(슈퍼바이저)의 종료코드는 **모든 Step 이 성공했을 때만 0** 이고,
    **Step 실패나 타임아웃이 하나라도 있으면 1** 이다(그 뒤의 Step 은 계속 실행된다).
    그래서 `Exit code: 0` 은 "무조건 기대"하는 값이 아니라 "0 이면 전 Step 성공 / 1 이면 로그에서
    어떤 Step 이 실패·타임아웃인지 확인" 으로 읽는다.
  - `.\gitautosync.bat` 은 sync 만 돌리므로 그 종료코드는 sync 결과(0/1)일 뿐 Step 결과가 아니다.
- [x] **슈퍼바이저/워커 분리 확인**: `giipAgent3.ps1` 가 Step 을 직접 실행하지 않고
  `giipAgentWorker.ps1` 를 별도 프로세스로 띄우는지(Step 별 워커 PID 가 결과 파일/로그에 남는지) 확인했는가?
- [x] **로그 확인**: 실행 로그(`logs/`)에 타겟 브랜치가 `real`로 정확히 표시되는가?
  - 에이전트 로그(`<저장소 상위>\giipLogs\giipAgentWin_<yyyyMMdd>.log`)에는 Step 별로
    `[Step N] Completed (exit=0, duration=Ns)` / `Worker failed (exit code ...)` /
    `Worker timeout after Ns - killed, continuing` 이 남는다 — 어느 Step 이 얼마나 걸렸는지 여기서 특정한다.

## 🚀 3단계: 배포 전 최종 체크 (Pre-Push Check)
- [x] **Git Branch 확인**: `git branch` 명령으로 현재 위치가 `main`임을 확인했는가?
- [x] **Git Status 확인**: 의도하지 않은 파일(예: `giipAgent.cfg` 등 비밀정보)이 포함되지 않았는가?
- [x] **커밋 메시지**: 수정 사항과 준수한 사양(v1.3.9 등)을 메시지에 명시했는가?
