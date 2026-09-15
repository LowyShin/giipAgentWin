# 현재 호출되지 않는 경로 사양서 (Uncalled Paths Specification)

giipAgentWin 레포 안에서 **현재 어떤 진입점으로도 도달하지 않는 5개 파일**의 정본 사양서입니다.

이 문서의 목적은 **삭제 판단이 아니라 기록**입니다. 사용자 지시(2026-09-15)에 따라, 각 파일이
(a) 어떤 용도로 만들어졌는지 (b) 무엇을 처리하는지 (c) 처리 결과가 어디에 어떤 형식으로 저장되는지
(d) 그 저장물을 어디서 읽어 쓰는지, 그리고 (e) 왜 만들어졌는지 (f) 언제부터 (g) 왜 안 쓰이게 됐는지를
**git 근거와 함께** 남깁니다. 향후 처리 방침은 사람이 이 문서를 읽고 판단합니다.

> **"죽은 코드"라고 부르지 않습니다.** 호출되지 않는 것과 불필요한 것은 다릅니다.
> 실제로 이 5개 파일은 호출되지 않는 동안 **정의 없는 함수 호출 결함 4계열을 숨기고 있었고**,
> giip #2546 / #2556 조사에서야 드러났습니다(아래 "숨어 있던 결함" 절).

- 관련 이슈: giip #2556 (본 문서), giip #2546 (CQE 실행기 복원), giip-967 (실행 이력 화면 연동)
- 상위 사양서: [`docs/SPEC_AND_CHECKLIST.md`](./SPEC_AND_CHECKLIST.md)
- 레포 토폴로지 규칙: `lowyworkenv/.agent/rules/42_giipagentwin_repo_topology.md`

---

## 0. 한눈에 보는 참조 그래프

```
[Task Scheduler]  "GIIP Agent Task (v3)"  (5분 주기, 현재 유일하게 등록된 작업)
   └─ wscript.exe giipAgent3-silent.vbs
        └─ giipAgent3.ps1                         ← 현재 운영 진입점
             ├─ lib/Common.ps1, lib/Kvs.ps1, lib/ProcessLock.ps1,
             │  lib/SchedulerAgentRegister.ps1, lib/SchedulerAgentRun.ps1
             └─ giipscripts/modules/
                  Step 1   CleanState.ps1
                  Step 2   CqeGet.ps1
                  Step 2.5 CqeRun.ps1              ← giip #2546 에서 추가
                  Step 3~7 DbMonitor / ProcessList / DbConnectionList /
                           HostConnectionList / CollectEnhancedMetrics

──────── 아래부터가 이 문서의 대상: 위 그래프에서 도달하지 않는다 ────────

giipAgentWin.ps1          (진입점, Task Scheduler 등록 0건 / 상주 프로세스 0건)
   └─ lib/Worker.ps1      (dot-source 1건: giipAgentWin.ps1 L12)
         └─ lib/ScriptRunner.ps1   ← 이것만은 운영 경로(CqeRun.ps1)와 공유

scripts/NormalMode.ps1    (진입점, 기동하는 곳 0건)
   └─ lib/Cqe.ps1         (dot-source 1건: NormalMode.ps1 L23)

lib/Discovery.ps1         (dot-source 0건, Invoke-Discovery 호출처 0건)
```

### 공통 연표 (git 근거)

| 날짜 | 커밋 | 무슨 일이 있었나 |
|---|---|---|
| 2024-11-12 | `caeeb5b` | `TaskSchdReg.ps1` 최초. 등록 대상은 `giipAgent.wsf` |
| 2025-08-12 | `6b912f2` | `giipAgentWin.ps1` 최초 생성(단일 파일) |
| 2025-08-28 | `f7f8102` | `TaskSchdReg.ps1` 등록 대상이 `giipAgent.wsf` → **`giipAgentWin.ps1`** |
| 2025-12-08 | `1558e27` | v2.0 모듈화. `giipAgentWin.ps1` 458줄 → 슬림화, **`lib/Common.ps1` + `lib/Worker.ps1` 신설**. `Get-SystemInfo` / `Update-ConfigLssn` 이 `Common.ps1` 에 정의됨 |
| 2025-12-10 | `ef30c46` | "giipAgent3.ps1 신규 작성". **`giipAgent3.ps1` + `lib/Cqe.ps1` + `lib/Discovery.ps1` + `lib/Kvs.ps1` + `scripts/NormalMode.ps1`** 동시 도입(v3 1차 설계). 이때 `Kvs.ps1` 에 `Send-KVSPut` 과 `Save-ExecutionLog` 가 **정의돼 있었다** |
| **2025-12-11** | **`b69abcd`** | v3 재설계. `giipAgent3.ps1` 을 `giipscripts/modules/`(CleanState, CqeGet) 호출 구조로 재작성하고, 같은 커밋에서 **`TaskSchdReg.ps1` 등록 대상을 `giipAgentWin.ps1` → `giipAgent3.ps1` 로 변경**. → 5개 파일 전부가 이 시점에 도달 불가가 된다 |
| **2025-12-14** | **`bc813d8`** | "Refactor DbConnectionList: Use shared KVS library and save payloads". `lib/Kvs.ps1` 190줄 재작성으로 **`Send-KVSPut`(→`Invoke-GiipKvsPut` 개명) 과 `Save-ExecutionLog`(소실) 정의가 동시에 제거**됨. 호출부 9곳은 갱신 안 됨 |
| **2026-04-08** | **`95a5560`** | `lib/Common.ps1` 전면 재작성. **`Get-SystemInfo` / `Update-ConfigLssn` 정의 소실**. `lib/Worker.ps1` 호출부는 그대로 |
| 2026-07-28 | `82db711` | Task Scheduler 액션이 `powershell.exe` → `wscript.exe` + `giipAgent3-silent.vbs`(창 깜빡임 제거) |
| 2026-09-15 | `f0ebbc5` | giip #2546. `lib/ScriptRunner.ps1` 분리 + **`lib/ExecutionLog.ps1` 신설**(`Save-ExecutionLog` 정의 복원) + `giipscripts/modules/CqeRun.ps1` 추가 |
| 2026-09-15 | 본 작업 | giip #2556. 숨어 있던 결함 수정 + 본 사양서 작성 |

**연표에서 읽을 수 있는 것**: 5개 파일이 도달 불가가 된 시점(2025-12-11)이, 정의가 사라진 시점
(2025-12-14 / 2026-04-08)보다 **앞섭니다**. 그래서 이후의 재작성들이 호출부를 깨뜨렸는데도
아무도 알아채지 못했습니다.

---

## 1. `giipAgentWin.ps1` — 구 상주 진입점

### (a) 어떤 용도로 만들어졌는가
Windows 에이전트의 **데몬형 진입점**. 프로세스가 죽지 않고 상주하면서
"CQE 큐 조회 → 실행 → Sleep" 을 무한 반복한다.

- 도입: 2025-08-12 `6b912f2` "Create giipAgentWin.ps1" (단일 파일, 약 458줄)
- 현재 형태: 2025-12-08 `1558e27` "refactor: Modularize Windows Agent to v2.0 structure" 에서
  본문이 `lib/Common.ps1` + `lib/Worker.ps1` 로 빠지고 얇은 오케스트레이터만 남았다.
- 연관 giip 번호: **근거 미상** (두 커밋 메시지 모두 giip 번호를 달지 않았다)

### (b) 무엇을 처리하는가
- **입력**: `giipAgent.cfg` (`Get-GiipConfig` 탐색 우선순위: 레포 상위폴더 > `%USERPROFILE%` > 로컬).
  루프 간격은 cfg 의 `giipagentdelay`(초), 없으면 60초.
- **동작**: `Main` 함수의 `while ($true)` 루프.
  - Step A `Get-QueueItem -Config $Config` (lib/Worker.ps1)
  - Step B 응답이 비어 있지 않으면 `Invoke-AgentTask -RawQueueItem ... -Config ...`
  - Step C `Start-Sleep -Seconds $delay`
  - 매 회차 끝에 `Get-GiipConfig` 재실행 (운영 중 lssn 변경을 반영하기 위함)
- **출력**: 없음(프로세스가 계속 돈다). 실패 시 `exit 1`.

### (c) 처리 결과가 어디에 어떤 형식으로 저장되는가
이 파일 자체는 저장하지 않는다. 저장은 `lib/Worker.ps1` 의 `Report-TaskResult` 가 수행한다
(아래 2-(c) 참조). 로컬 로그만 이 파일 경유로 남는다.

- 로컬 로그 파일: `<레포 상위폴더>\giipLogs\giipAgentWin_<yyyyMMdd>.log`
  (`lib/Common.ps1` 의 `Write-GiipLog`, giip #2338 에서 파일 기록 추가)

### (d) 그 저장물을 어디서 읽어 쓰는가
`lib/Worker.ps1` 과 동일 — **현재 소비처 없음**. 근거는 2-(d) 참조.

### (e)(f)(g) 왜 만들고, 언제부터, 왜 안 쓰이게 됐는가
- **(e) 왜 만들었나**: 위 (a). 상주 데몬 방식으로 큐를 폴링하기 위해.
- **(f) 언제부터 안 쓰이나**: **2025-12-11 `b69abcd`** 부터. 이 커밋이
  `TaskSchdReg.ps1` 의 `Register-ScheduledTask` 대상을 `giipAgentWin.ps1` → `giipAgent3.ps1` 로 바꿨다.
  그 이전 **2025-08-28 `f7f8102` ~ 2025-12-11** 사이에는 이 파일이 실제 운영 진입점이었다.
- **(g) 왜 안 쓰이나**: 상주 데몬 방식을 버리고 **Task Scheduler 5분 주기 단발 실행** 방식으로
  전환했기 때문이다. 상주 프로세스는 죽으면 아무도 되살리지 않는 반면 Task Scheduler 는 매 주기
  새로 띄우므로 복원력이 높다(참고: `docs/task-scheduler-multiple-instances.md`, giip #2338 의
  giipAgent3 hang 인시던트).
  현재 등록된 작업은 `GIIP Agent Task (v3)` 하나이고, 액션은
  `wscript.exe "giipAgent3-silent.vbs"` → `giipAgent3.ps1` 이다.
  - **의도적 대체였는가?** 진입점 전환 자체는 의도적이다(같은 커밋에서 등록 대상을 명시적으로 바꿨다).
    다만 **기능 이식은 완결되지 않았다** — 큐 "실행" 단계에 해당하는
    `giipscripts/modules/CqeRun.ps1` 은 2026-09-15 `f0ebbc5`(giip #2546)에서야 추가됐다.
    즉 2025-12-11 ~ 2026-09-15 약 9개월간 운영 경로는 큐를 **받아만 놓고 실행하지 않았다**.

### 현재 호출 상태 (실측)
- Task Scheduler 등록 0건, 상주 프로세스 0건 (`Win32_Process` 조회)
- 이 파일을 실행하는 스크립트/문서/배치 0건

---

## 2. `lib/Worker.ps1` — 구 진입점의 본체

### (a) 어떤 용도로 만들어졌는가
`giipAgentWin.ps1` 루프가 호출하는 3개 함수(`Get-QueueItem` / `Invoke-AgentTask` /
`Report-TaskResult`)를 담은 라이브러리.

- 도입: 2025-12-08 `1558e27` "refactor: Modularize Windows Agent to v2.0 structure"
  (`giipAgentWin.ps1` 458줄을 `Common.ps1` 158줄 + `Worker.ps1` 185줄로 분리)
- 연관 giip 번호: **근거 미상** (커밋 메시지에 giip 번호 없음).
  이후 수정 커밋에는 번호가 있다 — `8a079f5`(2026-07-01, KVSPut 4-파라미터 표준 복원),
  `f0ebbc5`(2026-09-15, giip #2546 로 `Invoke-ScriptBlock` 을 `ScriptRunner.ps1` 로 분리)

### (b) 무엇을 처리하는가
- **입력**: `$Config` (hashtable: `lssn` / `sk` / `apiaddrv2` 등), CQE 큐 응답 원문 문자열
- **동작**
  - `Get-QueueItem`: `Get-SystemInfo` 로 호스트명/OS 를 얻어
    API 커맨드 `CQEQueueGet lssn hn os sv df` (`df="os"`, `sv="2.0"`) 를
    `Invoke-GiipApiV2` 로 호출하고 **응답 원문을 그대로 반환**한다.
  - `Invoke-AgentTask`: 응답이
    - **순수 숫자**(`^\d+$`)면 서버가 새 LSSN 을 내려준 것으로 보고 `Update-ConfigLssn` 으로
      `giipAgent.cfg` 를 갱신하고 런타임 `$Config.lssn` 도 바꾼다.
    - 그 외에는 `QSN||TYPE||BODY` 로 분해(`-split '\|\|'`, 3토막 미만이면 WARN 후 반환)하고,
      본문의 `{{sk}}` / `{{lssn}}` 플레이스홀더를 cfg 값으로 치환한 뒤
      `Invoke-ScriptBlock -Type $type -Body $body` (lib/ScriptRunner.ps1) 로 실행한다.
  - `Report-TaskResult`: 실행 결과를 KVS 에 적재한다. 출력은 **500자로 절단**한다.
- **출력**: 큐 원문 문자열(`Get-QueueItem`), 나머지는 부수효과만.

### (c) 처리 결과가 어디에 어떤 형식으로 저장되는가
`Report-TaskResult` 가 API 커맨드 **`KVSPut kType kKey kFactor kValue`**
(→ giipdb SP `pApiKVSPutbySk`) 로 **giipdb `tKVS`** 에 적재한다.

| 항목 | 값 |
|---|---|
| 테이블 | `tKVS` |
| `kType` | `lssn` (리터럴) |
| `kKey` | `<lssn>` (cfg 의 `lssn`) |
| `kFactor` | **`giipAgentLog`** (리터럴) |
| `kValue` | `{"qsn":"<QSN>","status":"success\|error","output":"<500자 이내>"}` |

- 로컬 로그: `<레포 상위폴더>\giipLogs\giipAgentWin_<yyyyMMdd>.log`
- 참고: `kValue` 파라미터는 2026-06-30 `121a386` 이 시그니처에서 뺐다가
  2026-07-01 `8a079f5` 가 4-파라미터 표준으로 복원했다(파일 안 주석 참조).

### (d) 그 저장물을 어디서 읽어 쓰는가
**현재 소비처 없음.**

- giipv3 `src/` 및 giipdb `SP`/`Views`/`Functions`/`Tables` 전수 검색 결과
  `kFactor = 'giipAgentLog'` 를 **SELECT 하는 코드는 0건**이다.
- 유일한 매치는 giipdb `SP/pAdmCleanTable.sql` L113 의
  `where kFactor like 'GiipAgentLogs%'` 인데, 이는 **14일 경과분 DELETE 조건**이다(소비가 아니라 폐기).
- 같은 파일 L41 주석에 따르면 원본 로그 라인은 **`tAgentLogEntry` 테이블**이 대체했고,
  그쪽 소비처는 `SP/pApiAgentLogTailByAK.sql` / `SP/pApiAgentLogTailBySK.sql` 이다.
- **확인 방법(실제 실행한 명령)**
  ```bash
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipv3 && rg -n -i "giipagentlog" -g '!node_modules' .
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipdb  && rg -n -i "giipagentlog" .
  ```

> **대조**: CQE 실행 이력을 giipv3 `cqelsvrRunList` 화면의 **[KVS]** 버튼에서 보려면
> `kFactor='giipagent'` + `kValue.details.mslsn` 형태여야 한다(giip-967).
> 그 형식으로 쓰는 것은 `lib/ExecutionLog.ps1` 의 `Save-ExecutionLog` 다.
> 즉 `giipAgentLog` 와 `giipagent` 는 **서로 다른 kFactor** 이고, 화면이 읽는 쪽은 후자다.

### (e)(f)(g) 왜 만들고, 언제부터, 왜 안 쓰이게 됐는가
- **(e)** 위 (a). `giipAgentWin.ps1` 모듈화의 산물.
- **(f)** `giipAgentWin.ps1` 과 동일하게 **2025-12-11 `b69abcd`** 부터.
  이 파일을 dot-source 하는 곳은 `giipAgentWin.ps1` L12 하나뿐이다.
- **(g)** 역할이 `giipscripts/modules/CqeGet.ps1`(조회) + `CqeRun.ps1`(실행)으로 갈라졌다.
  다만 **동등한 이식은 아니다**:
  - `CqeGet.ps1` 은 `mslsn` / `mssn` / `script_type` / `ms_body` 를 `data/queue.json` 에 보존하는 반면,
    `Get-QueueItem` 은 원문 문자열 하나만 돌려주고 `Invoke-AgentTask` 가 `QSN||TYPE||BODY` 로 쪼갠다.
  - 실행 로직 `Invoke-ScriptBlock` 은 giip #2546 에서 `lib/ScriptRunner.ps1` 로 **추출**되어
    `CqeRun.ps1` 과 공유된다. 그래서 이 파일도 지금은 그것을 dot-source 한다
    (60초 하드코딩 → `cqetimeoutsec` 기본 600초, stdout 비동기 읽기, `cmdui`/`ps1ui` 타입 추가).
  - 결과 보고 방식은 이식되지 않았다 — `Report-TaskResult`(`giipAgentLog`) 대신
    `Save-ExecutionLog`(`giipagent`)가 정본이 됐다(giip-967 화면 연동 요건).

---

## 3. `lib/Cqe.ps1` — 구 CQE 큐 조회 래퍼

### (a) 어떤 용도로 만들어졌는가
CQE 큐 조회 API 의 얇은 래퍼(`Get-Queue` 1개 함수). `scripts/NormalMode.ps1` 이 쓸 조회 함수로
만들어졌다. Linux 에이전트의 큐 조회 로직을 PowerShell 로 옮긴 것이다 — 파일 안에
`Linux agent uses 'detect_os'`, `Linux logic: proc_name *404* or rst_val *404* or 0` 같은
주석이 그 흔적으로 남아 있다.

- 도입: 2025-12-10 `ef30c46` "giipAgent3.ps1 신규 작성" (v3 1차 설계)
- 연관 giip 번호: **근거 미상** (커밋 메시지에 giip 번호 없음)

### (b) 무엇을 처리하는가
- **입력**: `$Config`(hashtable), `$Hostname`(string)
- **동작**: API 커맨드 `CQEQueueGet lssn hostname os op` (`os` 는 `"windows"` 고정, `op="op"`)를
  `Invoke-GiipApiV2` 로 호출 → giipdb SP `pApiCQEQueueGetbySk` → 내부적으로 `pCQEQueueGetbySK02`.
  - `RstVal == "200"` 이면 `data.ms_body` 를 반환
  - `RstVal` 이 `404` 계열이거나 `0`, 또는 `ProcName` 에 `404` 가 있으면 **"큐 없음"** 으로 보고 `$null`
    (SP 쪽 메시지: `[pCQEQueueGetbySK02] no queue 2`)
  - 그 외는 ERROR 로그 후 `$null`
- **출력**: 큐에 실린 스크립트 본문(`ms_body`) 문자열 1건, 또는 `$null`

### (c) 처리 결과가 어디에 어떤 형식으로 저장되는가
**이 파일은 아무것도 저장하지 않는다(조회 전용).**
저장은 호출자인 `scripts/NormalMode.ps1` 이 `Save-ExecutionLog` 로 수행한다(4-(c) 참조).
조회 실패 시 로컬 로그만 남는다: `<레포 상위폴더>\giipLogs\giipAgentWin_<yyyyMMdd>.log`

### (d) 그 저장물을 어디서 읽어 쓰는가
반환값의 소비처는 `scripts/NormalMode.ps1` L50 **한 곳뿐**이며, giipv3 화면이 직접 읽는 산출물은 없다.

- `CQEQueueGet` 은 에이전트 전용 API 라 **giipv3 `src/` 안의 호출부도 0건**이다.
  문서/스킬 파일에만 등장한다: `public/skills/giip-agent/references/api.md` L108-125,
  `public/skills/giip-agent/scripts/giip_agent.py` L230, `public/help/giip-agent-api.*.md` L111-138
- SP 정의는 존재: giipdb `SP/pApiCQEQueueGetbySK.sql` L1, L9 (시그니처 `CQEQueueGet lssn hostname os op`)
- **확인 방법(실제 실행한 명령)**
  ```bash
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipv3 && rg -n "CQEQueueGet" -g '!node_modules' .
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipv3 && rg -n "CQEQueueGet|KVSPut|AgentAutoRegister" src
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipdb  && rg -n -i "CQEQueueGet" SP
  ```

### (e)(f)(g) 왜 만들고, 언제부터, 왜 안 쓰이게 됐는가
- **(e)** 위 (a). v3 1차 설계에서 `NormalMode.ps1` 의 조회 단계로.
- **(f)** 도입 **다음날**인 **2025-12-11 `b69abcd`** 부터. 이 파일을 dot-source 하는 곳은
  `scripts/NormalMode.ps1` L23 하나인데 그 NormalMode.ps1 을 기동하는 곳이 0건이다.
- **(g)** 같은 역할을 `giipscripts/modules/CqeGet.ps1` 이 맡았다.
  **동등하지 않다** — `Get-Queue` 는 `ms_body` 문자열 하나만 돌려주므로
  `script_type` / `mslsn` / `mssn` 을 잃어버린다. 그래서 실행 이력을 `mslsn` 으로 추적하는
  giip-967 형식(`kvslist?...&mslsn=<mslsn>`)을 만들 수 없다.
  `CqeGet.ps1` 은 이 4개 필드를 모두 `data/queue.json` 에 보존한다.

### 알려진 동작 특성 (giip #2556 조사, 이번에 수정하지 않음)
`Get-Queue` 의 `if ($response.data -and $response.data.Count -gt 0)` 분기는 **실제로는 타지 않는다.**
`lib/Common.ps1` 의 `Invoke-GiipApiV2` 가 이미 `$response.data[0]` 로 한 겹 벗겨서 돌려주기 때문이다
(giip-issue #922 에서 추가된 `-RawList` 스위치가 이 언랩을 끄는 용도다).
현재는 바로 아래 `elseif ($response.RstVal)` 폴백이 받아내므로 **동작에 문제는 없어** 이번 이슈에서는
건드리지 않았다. 다만 응답에 `RstVal` 이 없는 형태가 오면 `"CQEQueueGet response invalid structure"`
로 빠지므로, 이 경로를 되살릴 때는 확인이 필요하다.

---

## 4. `scripts/NormalMode.ps1` — 구 단발 실행 진입점

### (a) 어떤 용도로 만들어졌는가
CQE 큐를 **1회만** 받아 실행하고 끝나는 "단발(one-shot) 실행 모드" 진입점.
상주 무한루프(`giipAgentWin.ps1`)와 달리, Task Scheduler 가 주기적으로 불러주는 형태를 전제한다.
파일 헤더의 `Purpose: Execute normal mode independently` 가 그 의도를 말한다.

- 도입: 2025-12-10 `ef30c46` "giipAgent3.ps1 신규 작성" (v3 1차 설계)
- 이후 수정: 2025-12-30 `db5c3d1` (수집 스크립트 추가와 함께 소폭 수정),
  2026-05-16 `cecf4a3` (BOM/ASCII 정리)
- 연관 giip 번호: **근거 미상** (커밋 메시지에 giip 번호 없음)

### (b) 무엇을 처리하는가
- **입력**: `giipAgent.cfg`(`Get-GiipConfig`), CQE 큐(API `CQEQueueGet`)
- **동작** (`$ErrorActionPreference = "Stop"` 하에서)
  1. `lib/Common.ps1`, `lib/Kvs.ps1`, `lib/Cqe.ps1`, `lib/ExecutionLog.ps1` dot-source
  2. `Get-GiipConfig` 로 설정 로드, `[System.Net.Dns]::GetHostName()` 으로 호스트명
  3. `startup` 실행 로그 기록
  4. `Get-Queue -Config $Config -Hostname $hostname` 로 큐 1건 조회
     (실패 시 `error` 로그, `context="queue_fetch"`)
  5. 내용이 있으면 `%TEMP%\giip_task_<PID>.ps1` 에 UTF8 로 쓰고 **`& $tmpFile`** 로 실행
     → `$LASTEXITCODE` 와 경과 초를 `script_execution` 로그로 기록 → `finally` 에서 임시파일 삭제
     (실패 시 `error` 로그, `context="script_exec"`)
  6. 내용이 없으면 `queue_check` 로그(`has_queue=$false`)만 기록
  7. `shutdown` 로그 후 `exit 0`
- **출력**: 종료코드 0

### (c) 처리 결과가 어디에 어떤 형식으로 저장되는가
`Save-ExecutionLog`(`lib/ExecutionLog.ps1`) → `Invoke-GiipKvsPut`(`lib/Kvs.ps1`) →
API 커맨드 **`KVSPut kType kKey kFactor kValue`** → giipdb SP `pApiKVSPutbySk` → **`tKVS`**

| 항목 | 값 |
|---|---|
| 테이블 | `tKVS` |
| `kType` | `lssn` (리터럴) |
| `kKey` | `<lssn>` |
| `kFactor` | **`giipagent`** (리터럴, 소문자) |
| `kValue` | `{"event_type":"...","timestamp":"yyyy-MM-dd HH:mm:ss","lssn":...,"hostname":...,"mode":"normal","version":...,"details":{...}}` |

`event_type` 은 이 파일에서 5종이 나온다:
`startup` / `queue_check` / `script_execution` / `error` / `shutdown`

| `event_type` | `details` 내용 |
|---|---|
| `startup` | `{"mode":"normal","pid":<PID>}` |
| `queue_check` | `{"has_queue":false}` |
| `script_execution` | `{"exit_code":<int>,"duration":<초>,"type":"powershell"}` |
| `error` | `{"context":"queue_fetch"\|"script_exec","error":"<메시지>"}` |
| `shutdown` | `{"mode":"normal","status":"ok"}` |

그 밖의 저장물:
- 임시 스크립트 파일 `%TEMP%\giip_task_<PID>.ps1` (실행 직후 `finally` 에서 삭제)
- KVSPut 페이로드 사본 `<레포 상위폴더>\giipLogs\payloads\KVSPut_lssn_<kKey>_<yyyyMMdd_HHmmss_fff>.json`
  (`Invoke-GiipKvsPut` 이 디버깅용으로 ASCII 로 남긴다)
- 로컬 로그 `<레포 상위폴더>\giipLogs\giipAgentWin_<yyyyMMdd>.log`

### (d) 그 저장물을 어디서 읽어 쓰는가
`kFactor='giipagent'` 는 **소비처가 있다**(위 1~3번과 다른 점).

| 소비처 | 무엇을 하는가 |
|---|---|
| giipv3 `src/components/CqeLsvrRunData.tsx` L98 | `cqelsvrRunList` 화면의 **[KVS]** 버튼. `/{locale}/kvslist?kKey=<lssn>&kFactor=giipagent&mslsn=<mslsn>` 로 이동 (giip-967) |
| giipv3 `src/app/[locale]/kvslist/page.tsx` | `kKey`/`kFactor`/`mslsn` 쿼리파라미터를 받아 API `KVSList kType kKey kFactor` 호출(`kType='lssn'` 하드코딩, L32). 빈 값은 `'*'` 로 치환 |
| giipdb `SP/pApiKVSListbySk.sql` (및 `pApiKVSListbyAK.sql` L40, L68) | `and k.kFactor = @kFactor` — **정확 일치**(LIKE 아님). SQL Server 기본 CI collation 이라 `giipagent`/`giipAgent` 모두 매치 |
| giipv3 `src/components/dashboard/dashboardStatsTypes.ts` L73 | `kFactor === 'giipagent' \|\| kFactor === 'giipAgent'` → 대시보드 KVS Activity 배지 색상. 화면은 `KvsActivitySection.tsx` |
| giipv3 `src/lib/kvsHourlyDashboard.ts` L73 | `DEFAULT_MAJOR_FACTORS` 에 포함 → `kvs-hourly-dashboard` 화면의 "주요 factor 누락" 판정 |

- **주의**: `kvslist` 는 `mslsn` 이 주어지면 SP 결과를 받은 뒤 **프론트에서**
  `item.details.mslsn ?? item.mslsn` 으로 추가 필터링한다(`page.tsx` L387-400).
  그런데 이 파일의 `details` 에는 `mslsn` 이 없다 — `Get-Queue` 가 `ms_body` 만 돌려주기 때문이다
  (3-(g) 참조). 따라서 **이 파일이 남긴 로그는 [KVS] 버튼의 mslsn 필터에는 걸리지 않고**,
  `mslsn` 없이 `kFactor=giipagent` 로만 조회할 때 보인다.
- **확인 방법(실제 실행한 명령)**
  ```bash
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipv3 && rg -n -i "['\"]giipagent['\"]" -g '!node_modules' src
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipv3 && rg -n "kFactor" -g '!node_modules' src
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipdb  && rg -n "kFactor|@kFactor" SP/pApiKVSListbyAK.sql
  ```

### (e)(f)(g) 왜 만들고, 언제부터, 왜 안 쓰이게 됐는가
- **(e)** 위 (a). 상주 루프 대신 "스케줄러가 부르는 단발 실행" 모델을 구현하려고.
- **(f)** 도입 **다음날**인 **2025-12-11 `b69abcd`** 부터. 이 스크립트를 기동하는 곳은 0건
  (Task Scheduler 미등록, 다른 스크립트의 호출도 0건).
- **(g)** "큐를 1회 받아 실행한다"는 **역할 자체는 채택됐다** — 그게 지금의
  `giipAgent3.ps1` + Task Scheduler 5분 주기 모델이다. 다만 구현은 이 단일 파일이 아니라
  `giipscripts/modules/` 의 모듈 2개로 나뉘었다:
  - Step 2 `CqeGet.ps1` (조회 → `data/queue.json`)
  - Step 2.5 `CqeRun.ps1` (실행)
  - **`CqeRun.ps1` 은 2026-09-15 `f0ebbc5`(giip #2546)에서야 추가됐다.**
    즉 2025-12-11 재설계 시점에 **실행 단계가 이식되지 않은 채** 남아 있었고,
    그 공백(큐를 받아만 놓고 다음 회차 `CleanState` 가 지워버림)이 giip #2546 에서 드러났다.
    이것은 의도적 폐기가 아니라 **이식 누락**이다.

---

## 5. `lib/Discovery.ps1` — 구 인프라 자동탐색 라이브러리

> 사용자가 이 문서에 반드시 포함하도록 명시적으로 지목한 파일입니다.

### (a) 어떤 용도로 만들어졌는가
**6시간 주기로 인프라 자동탐색(auto-discovery)을 실행하고 결과 JSON 을 KVS 에 적재**하는 라이브러리.
함수 1개(`Invoke-Discovery`) + 상수 1개(`$DISCOVERY_INTERVAL_SEC = 21600`).
Linux 에이전트의 `collect_infrastructure_data`(전체 JSON 을 `auto_discover_result` 로 저장) 를
PowerShell 로 옮긴 것이다 — 파일 안 주석
`Linux 'collect_infrastructure_data' saves 'auto_discover_result' (full json).` 가 근거.

- 도입: 2025-12-10 `ef30c46` "giipAgent3.ps1 신규 작성" (v3 1차 설계)
- 이후 수정: 2026-05-16 `cecf4a3` (BOM/ASCII 정리)뿐 — **기능 수정 이력이 없다**
- 연관 giip 번호: **근거 미상** (커밋 메시지에 giip 번호 없음)

### (b) 무엇을 처리하는가
- **입력**
  - `$Config` (hashtable: `lssn` / `sk` / `apiaddrv2`)
  - 상태파일 `%TEMP%\giip_discovery_state_<lssn>.txt` (마지막 실행 시각, epoch 초)
- **동작**
  1. **간격 검사**: 상태파일의 epoch 과 현재를 비교해 21600초(6시간) 미만이면
     `"Discovery skipped (Interval not reached)"` 로그 후 반환
  2. **스크립트 존재 검사**: `<레포루트>\giipscripts\auto-discover-win.ps1` 이 없으면
     `error` 실행로그(`{"type":"discovery","msg":"Script not found"}`) 후 반환
  3. **실행**: `& $discoveryScript` 로 호출해 stdout 캡처
  4. **JSON 검증**: `ConvertFrom-Json` 실패 시
     `error` 실행로그(`{"type":"discovery","msg":"Invalid JSON"}`) 후 반환
  5. **적재**: `ConvertTo-Json -Depth 10 -Compress` 로 압축해 KVS 에 PUT
  6. **상태 갱신**: 현재 epoch 을 상태파일에 기록
  - 전 과정이 `try/catch` 로 감싸여 있고, 예외 시
    `error` 실행로그(`{"type":"discovery","msg":<예외메시지>}`)를 남긴다
- **출력**: 없음(부수효과만)

### (c) 처리 결과가 어디에 어떤 형식으로 저장되는가
API 커맨드 **`KVSPut kType kKey kFactor kValue`** → giipdb SP `pApiKVSPutbySk` → **`tKVS`**

| 항목 | 값 |
|---|---|
| 테이블 | `tKVS` |
| `kType` | `lssn` (리터럴) |
| `kKey` | `<lssn>` |
| `kFactor` | **`auto_discover_result`** (리터럴) |
| `kValue` | `giipscripts/auto-discover-win.ps1` 의 **전체 JSON**(Depth 10, Compress). 시스템/네트워크/서비스 인벤토리(`Get-CimInstance`, `Get-NetIPAddress`, `Get-Service` 결과) |

그 밖:
- 상태파일 `%TEMP%\giip_discovery_state_<lssn>.txt` (epoch 초, 평문)
- KVSPut 페이로드 사본 `<레포 상위폴더>\giipLogs\payloads\KVSPut_lssn_<kKey>_<타임스탬프>.json`
- 실행로그(에러 시에만) → `tKVS`, `kFactor='giipagent'` (4-(c) 와 동일 형식, `details.type="discovery"`)
- 로컬 로그 `<레포 상위폴더>\giipLogs\giipAgentWin_<yyyyMMdd>.log`

### (d) 그 저장물을 어디서 읽어 쓰는가
`kFactor='auto_discover_result'` 는 **소비처가 있다.**

| 소비처 | 무엇을 하는가 |
|---|---|
| giipdb `SP/pApiInfrastructureDetailbyAK.sql` L41 | `AND kFactor = 'auto_discover_result'` (+ `kRegdt >= DATEADD(DAY,-7,...)`, `TOP 1` 최신). API 명 **`InfrastructureDetail`** |
| giipv3 `src/app/[locale]/infrastructure-detail/page.tsx` L111 | `fetchAzureCommand('InfrastructureDetail lssn', ...)` → **Infrastructure Detail 화면** |

- **주의**: giipv3 `src/` 안에는 `auto_discover_result` 리터럴이 **0건**이다.
  화면은 kFactor 를 모른 채 **SP 를 통해 간접 소비**한다. 즉 kFactor 문자열만 grep 하면
  "소비처 없음" 으로 잘못 판단하게 된다 — SP 까지 봐야 한다.
- **확인 방법(실제 실행한 명령)**
  ```bash
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipv3 && rg -n -i "auto_discover_result" -g '!node_modules' .
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipdb  && rg -n -i "auto_discover_result" SP Views Functions Tables
  cd /c/Users/lowys/Downloads/Projects/giipprj/giipv3 && rg -n "InfrastructureDetail" src
  ```

### (e)(f)(g) 왜 만들고, 언제부터, 왜 안 쓰이게 됐는가
- **(e)** 위 (a). v3 1차 설계에서 자동탐색을 6시간 주기로 돌리는 라이브러리로.
- **(f)** 도입 **다음날**인 **2025-12-11 `b69abcd`** 부터.
  이 파일을 dot-source 하는 곳 **0건**, `Invoke-Discovery` 호출처 **0건**(5개 중 유일하게
  진입점조차 연결된 적이 없다).
- **(g)** **자동탐색 기능 자체는 폐기되지 않았다. 별도 경로로 살아 있다.**
  - 레포 루트의 **`giip-auto-discover.ps1`** 이 **같은** `giipscripts/auto-discover-win.ps1` 을
    실행하고, 결과를 **`AgentAutoRegister`** API 로 보낸다.
  - 그 SP(giipdb `SP/pApiAgentAutoRegisterBySK.sql` L194-196, L324-326)가
    `tKVS` 의 **같은 `kFactor='auto_discover_result'`** 행을 `MERGE` 로 갱신한다.
  - 즉 이 파일은 **"KVSPut 직접 적재"** 변형이고, 운영은 **"AgentAutoRegister 경유"** 변형을 쓴다.
    최종 저장 위치는 같다.
  - **어느 쪽을 정본으로 할지 정리한 문서상 근거는 찾지 못했다(근거 미상).**
    두 경로가 병존하게 된 경위를 설명하는 커밋 메시지나 사양서가 없다.
  - ※ 혼동 주의: `giip-auto-discover.ps1` 은 `lib/Discovery.ps1` 을 **부르지 않는다.**
    이름이 비슷할 뿐 완전히 별개 경로다.

---

## 6. 숨어 있던 결함 — giip #2556 에서 고친 것

5개 파일은 호출되지 않는 동안 **정의 없는 함수 호출 3종 + 스코프 오류 1종**을 숨기고 있었습니다.
모두 "호출됐다면 반드시 에러났을" 결함이며, 도달 불가라 아무도 만나지 않았습니다.

### 검출 방법
Windows PowerShell 5.1 의 `[System.Management.Automation.Language.Parser]::ParseFile()` 로
레포 전체(`*.ps1`)의 `FunctionDefinitionAst` 를 모아 정의 집합(113개)을 만들고,
대상 5개 파일의 모든 `CommandAst` 중 **정의 집합에도 없고 `Get-Command` 로도 안 잡히는** 이름을
찾았습니다. 파싱 자체는 5개 파일 모두 처음부터 에러 0건이었습니다(문법 오류는 없었다는 뜻).

### 결함 목록

| # | 파일:라인 | 결함 | 언제 깨졌나 | 수정 |
|---|---|---|---|---|
| D1 | `lib/Worker.ps1:34` | `Get-SystemInfo` **정의 0건** | 2026-04-08 `95a5560` 이 `lib/Common.ps1` 전면 재작성하며 정의 소실(원래 `1558e27` 에 있었음) | `lib/Common.ps1` 에 원본 정의 복원 |
| D2 | `lib/Worker.ps1:121` | `Update-ConfigLssn` **정의 0건** | 위와 동일 커밋 | `lib/Common.ps1` 에 원본 정의 복원 |
| D3 | `lib/Discovery.ps1:77` | `Send-KVSPut` **정의 0건** (실제 이름은 `Invoke-GiipKvsPut`, 파라미터명도 `-Type/-Key/-Factor/-Value` 로 다름) | 2025-12-14 `bc813d8` 이 `lib/Kvs.ps1` 재작성하며 개명, 호출부 미갱신 | `Invoke-GiipKvsPut` 로 교정 |
| D4 | `lib/Discovery.ps1` (3곳) | `Save-ExecutionLog` 호출하면서 `lib/ExecutionLog.ps1` **dot-source 0건** | 정의는 `bc813d8` 에서 소실 → giip #2546 `f0ebbc5` 에서 복원됐으나 이 파일은 로드하지 않음 | dot-source 가드 추가 |
| D5 | `scripts/NormalMode.ps1` (6곳) | `Save-ExecutionLog` 호출하면서 **dot-source 0건**. `$ErrorActionPreference='Stop'` 이라 L45 첫 호출에서 즉시 종료 | 위와 동일 | `lib/ExecutionLog.ps1` dot-source 추가 |
| D6 | `lib/Discovery.ps1:23` | **함수 내부**에서 `$MyInvocation.MyCommand.Path` 사용 → PS 5.1 에서 함수 스코프의 그 값은 `$null` → `Split-Path` 가 예외 | 도입 시점(2025-12-10 `ef30c46`)부터 | `$PSScriptRoot` 로 교정 |
| D7 | `lib/Discovery.ps1:9` | 로드 가드가 `Send-KVSPut` 존재 여부를 봄 → `Kvs.ps1` 이 이미 로드돼 있어도 매번 재로드(무해하나 의도와 다름) | 도입 시점부터 | 실제 정의명 `Invoke-GiipKvsPut` 으로 교정 |

### 재현 원문 (수정 전, Windows PowerShell 5.1 실측)

```
UNDEFINED-CALL Worker.ps1:34     Get-SystemInfo
UNDEFINED-CALL Worker.ps1:121    Update-ConfigLssn
UNDEFINED-CALL Discovery.ps1:77  Send-KVSPut

Worker.ps1 로드 후 Get-SystemInfo 존재?    = False
Worker.ps1 로드 후 Update-ConfigLssn 존재? = False
Get-QueueItem 실호출 -> CommandNotFoundException: The term 'Get-SystemInfo' is not
  recognized as the name of a cmdlet, function, script file, or operable program.

NormalMode 3개 모듈(Common/Kvs/Cqe) 로드 후 Save-ExecutionLog 존재? = False
Discovery.ps1 로드 후 Send-KVSPut 존재?       = False
Discovery.ps1 로드 후 Save-ExecutionLog 존재? = False

# 함수 스코프의 $MyInvocation.MyCommand.Path (D6 근거)
TOPLEVEL   Path = [C:\...\probe.ps1]
INFUNCTION Path = []
  Split-Path THROWS: ParameterBindingValidationException:
    Cannot bind argument to parameter 'Path' because it is null.
  PSScriptRoot  = [C:\...]
```

### 수정 후 (같은 검증 재실행)

```
UNDEFINED-CALL : 0건

Worker.ps1 로드 후 Get-SystemInfo 존재?    = True
Worker.ps1 로드 후 Update-ConfigLssn 존재? = True
Get-QueueItem OK (예외 없음)

NormalMode.ps1 4개 모듈 로드 후 Save-ExecutionLog 존재? = True
Save-ExecutionLog 실호출 반환 = True (예외 없음)

Discovery.ps1 로드 후 Save-ExecutionLog 존재? = True
Invoke-Discovery 실호출 -> 예외 없이 완료 (auto-discover-win.ps1 실제 실행 33초,
  KVS PUT 단계까지 도달. apiaddrv2 를 일부러 비워 네트워크 호출은 발생시키지 않음)

PARSE-OK: giipAgentWin.ps1 / Worker.ps1 / Cqe.ps1 / NormalMode.ps1 / Discovery.ps1 / Common.ps1
```

### 라이브 경로 회귀 영향
없습니다. 수정은 (1) `lib/Common.ps1` 에 **신규 함수 2개 추가**(레포 전체에서 동명 정의 0건이므로
충돌 없음), (2) 호출되지 않는 2개 파일 내부의 이름/스코프 교정, (3) dot-source 추가뿐입니다.
운영 경로 `giipAgent3.ps1` Step 1~7 + Step 2.5 는 `Get-SystemInfo` / `Update-ConfigLssn` /
`Invoke-Discovery` / `Get-Queue` / `Get-QueueItem` 중 어느 것도 호출하지 않습니다.

---

## 7. 이 문서에서 얻을 교훈

1. **"호출되지 않는다"는 사실은 품질 보증이 아니라 결함 은폐다.**
   참조 그래프상 도달 불가한 코드는 정적 검사도 실행 검증도 받지 않으므로, 리팩터링이
   호출부를 깨뜨려도 드러나지 않는다. 이 레포에서는 그 상태가 **9개월(2025-12-14 ~ 2026-09-15)**
   지속됐다.
2. **호출되지 않는 것과 불필요한 것은 다르다.**
   `lib/Discovery.ps1` 의 기능(자동탐색)은 폐기된 적이 없고 지금도 `giip-auto-discover.ps1` 로
   돌고 있다. 파일이 안 불린다는 이유로 기능까지 없어졌다고 단정하면 틀린다.
3. **kFactor 문자열 grep 만으로 소비처를 판단하면 틀린다.**
   `auto_discover_result` 는 giipv3 소스에 리터럴이 0건이지만, SP
   (`pApiInfrastructureDetailbyAK.sql`)를 통해 실제로 화면에 쓰인다. **SP 까지 봐야 한다.**
4. **대규모 재작성 커밋은 호출부 검증을 동반해야 한다.**
   `bc813d8`(Kvs.ps1 190줄 재작성) 과 `95a5560`(Common.ps1 전면 재작성) 둘 다
   함수 정의를 지우면서 호출부를 확인하지 않았다.
