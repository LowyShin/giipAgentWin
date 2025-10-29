# Git Auto-Sync for Windows (Pull-Only)

Windows 환경에서 GitHub 변경사항을 자동으로 받는 **읽기 전용** PowerShell 스크립트입니다.

> **⚠ 보안 공지**: 이 저장소는 공개 저장소입니다. 로컬 변경사항은 자동으로 Push되지 않습니다.

## 버전

**v1.0.0 (Pull-Only)** (2025-10-29)

## 기능

### 읽기 전용 동기화 (Pull-Only)

1. **Auto-Pull**
   - GitHub 원격 변경사항 자동 감지
   - 자동 풀 (GitHub → Server)
   - Stash로 로컬 변경사항 보호

2. **보안**
   - ❌ 로컬 변경사항 자동 커밋 **비활성화**
   - ❌ GitHub 푸시 **비활성화**
   - ✅ 공개 저장소 - 기밀정보 유출 방지
   - ✅ 로컬 변경사항은 Stash로 보존

## 설치 방법

### 1. 스크립트 배치

```powershell
# giipAgentWin 디렉토리에 이미 포함되어 있음
C:\giipAgent\git-auto-sync.ps1
```

### 2. 실행 정책 설정

```powershell
# 관리자 권한 PowerShell에서 실행
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 3. 수동 테스트

```powershell
cd C:\giipAgent
.\git-auto-sync.ps1
```

## Windows Task Scheduler 설정

### 방법 1: GUI로 설정

1. **Task Scheduler 실행**
   - `Win + R` → `taskschd.msc`

2. **새 작업 만들기**
   - 우측 "작업 만들기" 클릭

3. **일반 탭**
   - 이름: `GIIP Git Auto-Sync`
   - 설명: `GitHub 양방향 자동 동기화`
   - 사용자 계정: 현재 로그인 사용자
   - ✓ 사용자의 로그온 여부에 관계없이 실행
   - ✓ 가장 높은 수준의 권한으로 실행

4. **트리거 탭**
   - "새로 만들기" 클릭
   - 작업 시작: `일정에 따라`
   - 설정: `매일`
   - 반복 간격: `5분`
   - 기간: `무기한`
   - ✓ 사용

5. **동작 탭**
   - "새로 만들기" 클릭
   - 동작: `프로그램 시작`
   - 프로그램/스크립트: `powershell.exe`
   - 인수 추가:
     ```
     -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "C:\giipAgent\git-auto-sync.ps1"
     ```
   - 시작 위치: `C:\giipAgent`

6. **조건 탭**
   - ☐ 컴퓨터의 AC 전원이 켜져 있는 경우에만 시작
   - ☐ 작업을 실행하기 위해 절전 모드 종료

7. **설정 탭**
   - ✓ 요청 시 작업 실행 허용
   - ✓ 작업 실패 시 다시 시작 간격: `1분`
   - 다시 시작 시도: `3회`

### 방법 2: PowerShell로 설정

```powershell
# 관리자 권한 PowerShell에서 실행

# Task 정의
$Action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File C:\giipAgent\git-auto-sync.ps1" `
    -WorkingDirectory "C:\giipAgent"

$Trigger = New-ScheduledTaskTrigger -Daily -At "00:00" `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 59)

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType S4U `
    -RunLevel Highest

# Task 등록
Register-ScheduledTask -TaskName "GIIP Git Auto-Sync" `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Principal $Principal `
    -Description "GitHub 양방향 자동 동기화 (5분마다 실행)"

Write-Host "✓ Task Scheduler에 등록 완료"
```

### 방법 3: XML 파일로 등록

1. **XML 파일 생성** (`GitAutoSync.xml`)

```xml
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>GitHub 양방향 자동 동기화 (5분마다 실행)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2025-10-29T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal>
      <UserId>YOUR_USERNAME</UserId>
      <LogonType>S4U</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "C:\giipAgent\git-auto-sync.ps1"</Arguments>
      <WorkingDirectory>C:\giipAgent</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
```

2. **Task 등록**

```powershell
# YOUR_USERNAME을 실제 사용자명으로 변경 후
schtasks /Create /TN "GIIP Git Auto-Sync" /XML "GitAutoSync.xml"
```

## 사용 예시

### 수동 실행

```powershell
# 기본 실행 (현재 디렉토리)
cd C:\giipAgent
.\git-auto-sync.ps1

# 특정 경로 지정
.\git-auto-sync.ps1 -RepoPath "C:\giipAgent"
```

### Task Scheduler 관리

```powershell
# Task 목록 확인
Get-ScheduledTask -TaskName "GIIP Git Auto-Sync"

# Task 실행
Start-ScheduledTask -TaskName "GIIP Git Auto-Sync"

# Task 중지
Stop-ScheduledTask -TaskName "GIIP Git Auto-Sync"

# Task 삭제
Unregister-ScheduledTask -TaskName "GIIP Git Auto-Sync" -Confirm:$false

# Task 실행 이력 확인
Get-ScheduledTaskInfo -TaskName "GIIP Git Auto-Sync" | Select-Object LastRunTime, LastTaskResult, NumberOfMissedRuns
```

## 로그 확인

### 로그 파일 위치

```
C:\giipAgent\logs\git_auto_sync_YYYYMMDD.log
```

### 로그 보기

```powershell
# 오늘 로그 보기
$logFile = "C:\giipAgent\logs\git_auto_sync_$(Get-Date -Format 'yyyyMMdd').log"
Get-Content $logFile -Tail 50

# 실시간 로그 모니터링
Get-Content $logFile -Wait -Tail 10

# 에러만 검색
Select-String -Path $logFile -Pattern "ERROR" -Context 2

# 최근 1시간 로그
Get-Content $logFile | Where-Object { $_ -match $(Get-Date -Format 'yyyy-MM-dd') }
```

## 동작 흐름

```
[Step 0] Fetch
    ↓
[Step 1] Local Changes Check
    ↓
    ├─ Changes Found
    │   ├─ git stash save "Auto-stash..."
    │   └─ ⚠ WARNING: Changes stashed (NOT pushed)
    │
    └─ No Changes → Skip
    ↓
[Step 2] Remote Changes Check
    ↓
    ├─ Remote Updated
    │   └─ git pull origin main
    │
    └─ Already Up-to-date → Skip
    ↓
[Step 3] Stash Information
    ↓
    └─ Show stash list and recovery commands
    ↓
[Complete] (Pull-Only Mode)
```

## 보안 특징

### 로컬 변경사항 처리

```powershell
# 로컬 변경 감지 시
⚠ WARNING: Local changes detected (will NOT be pushed - Read-Only Mode)
⚠ SECURITY NOTICE: This is a public repository.
⚠ Local changes will be stashed before pull to prevent conflicts.

# Stash로 보존
git stash save "Auto-stash before pull at 2025-10-29 15:30:00 on SERVER01"

# 복구 방법 안내
To restore your changes:
  git stash pop
To discard stashed changes:
  git stash drop
```

### Push 차단

- ❌ `git add -A` - 실행 안 됨
- ❌ `git commit` - 실행 안 됨
- ❌ `git push` - 실행 안 됨
- ✅ `git pull` - 실행됨
- ✅ `git stash` - 로컬 변경사항 보존

## 에러 처리

### 1. Git 설정 없음

```powershell
# 자동으로 설정됨
git config user.name "giipAgent-COMPUTERNAME"
git config user.email "giipagent@COMPUTERNAME.local"
```

### 2. Push 충돌

```powershell
# 자동으로 rebase 후 재시도
git pull origin main --rebase
git push origin main
```

### 3. Stash 충돌

```powershell
# 로그에 경고 출력
WARNING: Stash pop had conflicts, please resolve manually

# 수동 해결
git stash list
git stash show
git stash drop  # 또는 git stash apply
```

## 트러블슈팅

### Task가 실행되지 않음

```powershell
# Task 상태 확인
Get-ScheduledTask -TaskName "GIIP Git Auto-Sync" | Select-Object State, LastRunTime, LastTaskResult

# 마지막 실행 결과 코드 확인
# 0x0: 성공
# 0x1: 실패
# 0x41301: 실행 중

# Task 이벤트 로그 확인
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 100 | 
    Where-Object { $_.Message -like "*GIIP Git Auto-Sync*" }
```

### Git 인증 실패

```powershell
# Credential Manager 확인
cmdkey /list | Select-String "git"

# GitHub Token 설정 (HTTPS)
git config credential.helper manager
git push  # 인증 프롬프트 표시됨

# 또는 SSH 키 사용
ssh-keygen -t ed25519 -C "giipagent@$env:COMPUTERNAME"
type $env:USERPROFILE\.ssh\id_ed25519.pub | clip
# GitHub.com → Settings → SSH Keys에 추가
```

### PowerShell 실행 정책 에러

```powershell
# 현재 정책 확인
Get-ExecutionPolicy -List

# 정책 변경 (관리자 권한)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# 또는 Bypass로 직접 실행
powershell.exe -ExecutionPolicy Bypass -File "C:\giipAgent\git-auto-sync.ps1"
```

### 로그가 생성되지 않음

```powershell
# 로그 디렉토리 생성
New-Item -ItemType Directory -Path "C:\giipAgent\logs" -Force

# 권한 확인
Get-Acl "C:\giipAgent\logs"

# 수동 실행으로 테스트
cd C:\giipAgent
.\git-auto-sync.ps1
```

## 사용 시나리오

### 시나리오 1: GitHub에서 스크립트 업데이트 받기

```powershell
# GitHub에서 스크립트 수정 (다른 개발자)
# → 5분 후 자동으로 서버에 Pull됨
# → 최신 버전 자동 적용
```

### 시나리오 2: 로컬 설정 파일 보호

```powershell
# 서버별 설정 파일 수정 (민감정보 포함)
notepad C:\giipAgent\giipAgent.cfg
# → Stash로 보존됨
# → GitHub에 Push 안 됨 (보안 유지)
# → 필요시 git stash pop으로 복구
```

### 시나리오 3: 중앙 집중식 배포

```powershell
# 개발팀이 GitHub에 코드 Push
# → 모든 운영 서버가 5분 내 자동 Pull
# → 수동 배포 작업 불필요
# → 서버별 기밀정보는 보호됨
```

## 성능 최적화

### 대용량 파일 제외

`.gitignore` 설정:

```gitignore
# 로그 파일 (너무 큰 경우)
logs/*.log

# 임시 파일
*.tmp
*.temp

# 백업 파일
*.bak
*.backup
```

### 부분 커밋

```powershell
# 특정 파일만 커밋하도록 수정
git add giipAgent.cfg
git commit -m "Update config only"
```

## Linux 버전과의 차이점

| 기능 | Linux (bash) | Windows (PowerShell) |
|------|--------------|----------------------|
| 기본 경로 | `/home/giip/giipAgentAdmLinux` | `C:\giipAgent` |
| 로그 위치 | `/var/log/giip/` | `C:\giipAgent\logs\` |
| Cron | `/etc/cron.d/` | Task Scheduler |
| 실행 주기 | `*/5 * * * *` | 5분 반복 트리거 |
| 권한 | `chmod +x` | ExecutionPolicy |
| 로그 방식 | `echo >>&2` | `Write-Log` 함수 |

## 버전 히스토리

### v1.0.0 (Pull-Only) (2025-10-29)
- ✨ 읽기 전용 모드 구현
- ✅ GitHub → Server 단방향 동기화만 지원
- ✅ 로컬 변경사항 Stash로 보호
- ✅ 공개 저장소 보안 강화
- ❌ 자동 커밋/푸시 기능 제거 (보안)

## 관련 저장소

- **giipAgentWin**: 공개 저장소 - Pull-Only 모드
- **giipAgentLinux**: 공개 저장소 - Pull-Only 모드
- **giipAgentAdmLinux**: 비공개 저장소 - 양방향 동기화 가능 (v2.0.0)

## 참고 문서

- [GIT_AUTO_SYNC.md](../giipAgentAdmLinux/docs/GIT_AUTO_SYNC.md) - Linux 버전
- [SQLNETINV_DATA_FLOW.md](../giipAgentAdmLinux/docs/SQLNETINV_DATA_FLOW.md) - 데이터 흐름
- [Task Scheduler 공식 문서](https://docs.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-start-page)

## 라이선스

GIIP Project - Internal Use Only

---

**마지막 업데이트**: 2025-10-29  
**버전**: 2.0.0  
**관리자**: GIIP Team
