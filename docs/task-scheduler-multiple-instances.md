# Task Scheduler "GIIP Agent Task (v3)" — MultipleInstances policy (giip #2338)

## Background

2026-09-09 01:15 ~ 2026-09-11 (57시간+): `giipAgent3.ps1` (Windows 오케스트레이터,
Lowy-DP01 / lssn 71197)가 hang되어 Net3D(network-topology) 데이터 수집이 전면
중단됐다. 원인 프로세스는 강제 종료했으나, Task Scheduler 작업 "GIIP Agent Task
(v3)"의 `MultipleInstances` 정책이 `IgnoreNew`이기 때문에, hang된 이전 인스턴스가
남아있는 동안에는 **새 `giipAgent3.ps1` 프로세스 자체가 전혀 시작되지 않았다**
(Microsoft-Windows-TaskScheduler/Operational 이벤트 로그에 ID 322 "instance is
already running" 경고만 5분마다 반복 기록되고, 새 프로세스 생성 자체가 없었음을
실측 확인).

라이브 조회 결과(2026-09-11, 읽기 전용):

```
TaskName                    : GIIP Agent Task (v3)
State                       : Ready
Settings.MultipleInstances  : IgnoreNew
Settings.ExecutionTimeLimit : PT72H   (72시간 — 57시간 hang도 이 한도 안이라 Task
                                        Scheduler 자체 타임아웃으로도 안 죽었을 것)
```

## 이번 코드 변경과의 관계

이번 PR로 `giipAgent3.ps1`에 30분 임계값 lock 메커니즘(`lib/ProcessLock.ps1`)을
추가했다 — 시작 시 이전 인스턴스가 30분 넘게 살아있으면 강제 종료 후 진행한다.
**하지만 이 코드는 새 `giipAgent3.ps1` 프로세스가 실제로 시작되어야만 실행된다.**
`MultipleInstances=IgnoreNew`인 상태에서는 이전 인스턴스가 hang된 채로 있으면
Task Scheduler가 새 프로세스를 아예 기동하지 않으므로, lock 체크 코드가 실행될
기회 자체가 없다. 따라서 이 lock 메커니즘이 실제로 효과를 내려면 아래 정책
변경이 함께 적용되어야 한다.

## 권장 변경: MultipleInstances를 Parallel로 전환

```powershell
$task = Get-ScheduledTask -TaskName "GIIP Agent Task (v3)"
$task.Settings.MultipleInstances = "Parallel"
Set-ScheduledTask -InputObject $task
```

- `Get-ScheduledTask`/`Set-ScheduledTask`는 Windows 내장 `ScheduledTasks` 모듈
  (관리자 권한 필요 없음, 현재 사용자 권한으로 이 태스크를 등록했으므로 수정도
  가능할 것으로 예상되나 최종 실행 시 권한 오류가 나면 관리자 PowerShell에서
  재시도).
- `$task.Settings`는 CIM 인스턴스(`MSFT_TaskSettings3`)이며 `MultipleInstances`
  열거형 값은 이 머신에서 `Parallel` / `Queue` / `IgnoreNew` 세 가지가 확인됨
  (읽기 전용 조회로 실측, 2026-09-11).
- 변경 후 확인:
  ```powershell
  (Get-ScheduledTask -TaskName "GIIP Agent Task (v3)").Settings.MultipleInstances
  # 기대값: Parallel
  ```

### 왜 Parallel인가 (Queue가 아니라)

- `Queue`는 이전 인스턴스가 아직 "실행 중"으로 잡혀 있으면 새 인스턴스를 큐에
  넣고 대기시킨다 — hang 상황에서는 이전 인스턴스가 영원히 "실행 중"이므로
  큐에 쌓인 새 인스턴스도 영원히 시작되지 못한다. `IgnoreNew`와 사실상 같은
  실패 모드를 갖는다.
- `Parallel`은 이전 인스턴스 상태와 무관하게 새 프로세스를 즉시 시작한다.
  이번에 추가한 `lib/ProcessLock.ps1`의 lock 체크가 실행될 기회를 보장하는
  유일한 옵션이다. 새로 시작된 프로세스가 lock을 읽어 (a) 이전 PID가 30분
  미만이면 즉시 종료(중복 실행 방지), (b) 30분 이상이면 이전 PID를 강제
  종료하고 진행 — 이 두 경로가 사실상 애플리케이션 레벨에서
  `IgnoreNew`/`Queue`가 원래 하려던 "중복 실행 방지" 역할을 대신하면서,
  hang에 대해서는 자가 복구까지 겸한다.

### 부가 권장 사항 (이번 PR 범위 밖, 참고용)

`ExecutionTimeLimit=PT72H`도 낮추는 것을 고려할 수 있다 — 이번 인시던트의 57시간
hang은 72시간 한도 내였으므로 Task Scheduler 자체의 타임아웃으로도 종료되지
않았을 것이다. 다만 각 실행 주기(5분)와 Step 7개의 정상 소요시간을 감안해
적정값(예: PT1H)을 정하려면 별도 검토가 필요해 이번 PR에는 포함하지 않았다.
필요 시 후속 이슈로 등록할 것.

## 적용 여부

**이 문서는 명령과 근거만 남긴다 — 실제 라이브 변경은 오케스트레이터가 최종
확인 후 직접 실행한다 (giip #2338 작업 지시 사항).**
