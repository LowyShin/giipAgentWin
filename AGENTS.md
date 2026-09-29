# AGENTS.md — giipAgentWin 수정 규칙 (사람·AI 모두 필독)

이 에이전트는 고객 PC/서버에 설치되어 실행된다. 보안 프로그램(EDR/백신)이 한 번이라도 차단하면
giip 서비스 신뢰도가 떨어지므로, 아래 규칙은 기능 요구보다 우선한다. 규칙과 충돌하는 변경은
구현하지 말고 오너(LowyShin)에게 먼저 물어라.

## 1. 보안 프로그램이 차단하는 실행 방식 — 절대 금지

에이전트 자신의 실행 경로(Task Scheduler 액션, launcher, 자동 업데이트, 설치 스크립트)에 아래를 넣지 않는다.

- `wscript.exe` / `cscript.exe` / `.vbs` / `.wsf` / `.js`(WSH) 래퍼로 PowerShell 실행
  (2026-07-28 신입이 창 깜빡임 제거용으로 vbs 래퍼를 넣었다가 2026-09-29 제거함)
- `mshta.exe`, `rundll32.exe`, `regsvr32.exe`, `certutil`, `bitsadmin` 등 LOLBin 으로 코드 실행/다운로드
- `-EncodedCommand`, Base64/난독화된 명령, `Invoke-Expression`(`iex`) 로 원격 문자열 실행
- 다운로드한 스크립트를 검증 없이 바로 실행하는 패턴 (`DownloadString | iex` 등)
- "숨김 창 + ExecutionPolicy Bypass" 를 새 래퍼에 추가로 조합하는 것
- 안티바이러스/EDR 예외 등록이나 보안 설정 변경을 전제로 하는 설계

예외: 큐로 받은 고객 스크립트를 실행하는 `lib/ScriptRunner.ps1` 의 `wsf` 타입은 기존 기능이며,
에이전트 자신의 기동 경로에 쓰는 것과는 별개다. 이 기능도 임의로 확장하지 않는다.

## 2. 진입점과 창 숨김 방식은 고정

- Task Scheduler 액션은 `conhost.exe --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File giipAgent3-launcher.ps1` 이다 (`TaskSchdReg.ps1` 이 등록).
- 창을 숨기려는 목적으로 다른 방식(vbs, `-WindowStyle Hidden` 단독, 별도 exe 등)을 새로 도입하지 않는다.
- LogonType 은 `Interactive` 를 유지한다. `S4U`/SYSTEM 으로 바꾸면 `ps1ui`/`cmdui` 스크립트가 사용자 화면에 창을 못 띄운다.
- 서명되지 않은 exe/dll 을 새로 추가해 에이전트가 실행하게 하지 않는다.

## 3. 오너 승인 없이 수정 금지 파일

업데이트 메커니즘이 깨지면 전 머신에서 수동 복구가 필요하다.

- `TaskSchdReg.ps1`, `giipAgent3-launcher.ps1`, `git-auto-sync.ps1`, `gitsync.ps1`
- 위 파일을 바꿀 때는 PR 본문에 "실행 경로 변경"을 명시하고 오너 리뷰를 받는다.

## 4. 브랜치·배포

- 에이전트는 `git-auto-sync` 로 5분마다 `git stash` 후 지정 브랜치(`main`, 설정에 따라 `real`)를 pull 한다.
  **커밋하지 않은 로컬 수정은 자동으로 stash 되어 사라진 것처럼 보인다.** 수정은 항상 작업 브랜치에 커밋·push 한다.
- 작업 브랜치 → PR → `main`. `real`(운영) 반영은 오너만 한다 — 신입/AI 는 `real` 에 직접 push 하지 않는다.
  정본: `giipdb/docs/10_Standards/BRANCH_STRATEGY.md`
- push 전에 변경한 `.ps1` 은 `[System.Management.Automation.Language.Parser]::ParseFile` 로 파싱 오류 0건을 확인한다.

## 5. 의심되면 멈춘다

"보안 프로그램에 걸릴 수 있나?"가 조금이라도 의심되면 구현하기 전에 오너에게 묻는다.
차단으로 에이전트가 멈추면 고객 PC 전체의 모니터링이 끊긴다.
