# GIIP Agent for Windows

**Version**: 3.0  
**Release**: 2025-03-11  
**Windows**: 2012 R2+

## 🌟 개념

GIIP Agent는 Windows 기반 경량 모니터링 및 관리 에이전트입니다.

**주요 특징:**
- ✅ 원격 명령 실행 - CQE (Command Queue Execution) 시스템
- ✅ 자동 인프라 검색 - OS, 하드웨어, 소프트웨어, 서비스 검색
- ✅ 운영 조언 - 수집 데이터 기반 최적화 제안
- ✅ 하트비트 보고 - 5분마다 중앙 서버에 보고
- ✅ 다양한 런타임 지원 - PowerShell, WSF, AutoHotkey

**배포:**
- 모든 Windows Server/Desktop에 자동 배포 가능
- Task Scheduler를 통한 백그라운드 실행
- 최소 리소스 사용

## 📁 디렉토리 구조

```
giipAgentWin/
├── 📄 giipAgentWin.ps1       # PowerShell 에이전트 (권장)
├── 📄 giipAgent.wsf          # WSF 에이전트 (레거시)
├── 📄 giipAgent.ahk          # AutoHotkey v1.1 에이전트
├── 📄 giipAgent.cfg          # 설정 파일 (템플릿)
├── 📄 TaskSchdReg.ps1        # Task Scheduler 등록
├── 📄 git-auto-sync.ps1      # Git 자동 동기화
├── 📄 gitsync.ps1            # Git 동기화 스크립트
├── 📁 docs/                  # 문서
├── 📁 giipscripts/           # 에이전트 모듈
├── 📁 admin/                 # 관리 도구
└── 📁 tests/                 # 테스트 스크립트
```

## 🚀 빠른 시작 (Quick Start)

### 1단계: Git 저장소 클론 (Git Clone)
에이전트를 구동할 윈도우 컴퓨터의 터미널(Command Prompt 또는 PowerShell)에서 윈도우용 에이전트 소스 코드를 클론합니다.

```bash
# 원하는 디렉토리로 이동 후 클론
git clone https://github.com/LowyShin/giipAgentWin.git
cd giipAgentWin
```

### 2단계: 설정 파일(`giipAgent.cfg`) 설정 및 배치
> ⚠️ **중요 (주의사항)**: 
> `giipAgentWin` 폴더 내부의 설정 파일은 샘플 템플릿입니다. 이 파일을 그대로 직접 수정해 버리면, 나중에 에이전트가 자동 업데이트(Git Pull)될 때 충돌(Conflict)이 발생하여 에이전트가 오작동하게 됩니다.

1. `giipAgentWin` 폴더 내부에 있는 **`giipAgent.cfg`** 파일을 복사합니다.
2. 복사한 파일을 **`giipAgentWin` 폴더의 부모(상위) 디렉토리** 혹은 **사용자 홈 폴더(`%USERPROFILE%` / 예: `C:\Users\사용자명`)** 위치에 붙여넣습니다.
   * *예: 에이전트 경로가 `C:\giip\giipAgentWin` 이라면 설정 파일은 `C:\giip\giipAgent.cfg`에 둡니다.*
3. 붙여넣은 외부 `giipAgent.cfg` 파일을 메모장 등으로 열어 정보를 수정합니다:
   * **`sk`**: 본인의 GIIP 시크릿 키 입력 (예: `"f059cdcf1df3b1e38e7f551e434677f9"`)
   * **`lssn`**: 관제 대상 장비의 LSSN 번호 입력 (예: `"71274"`)
   * **`branch`**: `"main"`으로 지정 (또는 개발 중인 특정 브랜치 지정)

### 3단계: 최초 수동 실행 및 데이터 수집 검증 (KVS 초기 적재)
에이전트가 수동으로 정상 구동되어 클라우드 KVS로 데이터를 처음 올리는지 검증합니다.

1. `giipAgentWin` 폴더 내부에서 **`giipAgent3.bat`** 배치 파일을 더블 클릭하여 실행합니다. (또는 PowerShell에서 아래 명령 수행)
   ```powershell
   # PowerShell에서 수동 검증 수행 시 (실행정책 임시 우회)
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\giipAgent3.ps1
   ```
2. 실행 창 로그에 아래와 같이 **성공(Successfully)** 메시지가 출력되는지 확인합니다:
   ```text
   [INFO] [Step 7] Running Enhanced Metrics Collector...
   [INFO] [CollectEnhancedMetrics] Uploading unified performance metrics to KVS (Factor: performance_metrics)...
   [INFO] [CollectEnhancedMetrics] Successfully collected and uploaded unified performance metrics.
   ```
   * *이 과정이 완료되면 최초의 실시간 성능 데이터(`performance_metrics` 또는 `system_metrics`)가 KVS 클라우드에 성공적으로 적재됩니다.*

### 4단계: 5분 주기 자동 스케줄러 등록
사용자가 매번 수동으로 실행하지 않아도 백그라운드에서 윈도우가 주기적으로 데이터를 수집해 올리도록 작업 스케줄러에 등록합니다.

1. **PowerShell을 "관리자 권한으로 실행"**합니다.
2. `giipAgentWin` 디렉토리로 이동한 뒤 작업 등록 스크립트(`TaskSchdReg.ps1`)를 실행합니다:
   ```powershell
   # 실행 권한 우회 설정 후 등록 스크립트 구동
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\TaskSchdReg.ps1
   ```
3. 화면에 **`Task 'GIIP Agent Task (v3)' registered successfully to run every 5 minutes.`** 초록색 메시지가 출력되면 모든 스케줄러 등록이 완료됩니다.

## 📚 주요 문서

### 🆕 필수 문서
- **[설치 가이드](docs/INSTALLATION_GUIDE.md)** - 단계별 설치
- **[설정 가이드](docs/CONFIGURATION_GUIDE.md)** - giipAgent.cfg 설정
- **[Task Scheduler 설정](docs/TASK_SCHEDULER_SETUP.md)** - 백그라운드 실행

### 📋 개념 & 아키텍처
- [에이전트 아키텍처](docs/AGENT_ARCHITECTURE.md) - 동작 원리
- [CQE 시스템](docs/CQE_SYSTEM.md) - 명령 큐 실행
- [자동 검색 설계](../giipdb/docs/AUTO_DISCOVERY_DESIGN.md) - 인프라 검색

### 🔧 개발 & 운영
- **[문제 해결](docs/TROUBLESHOOTING.md)** - 설치/실행 문제
- **[로그 분석](docs/LOG_ANALYSIS.md)** - 에러 로그 분석
- [보안 체크리스트](../giipdb/docs/SECURITY_CHECKLIST.md) - 보안 설정

### 🛠️ 관리 도구
- `.\TaskSchdReg.ps1` - Task Scheduler 등록/제거
- `.\git-auto-sync.ps1` - Git 자동 업데이트
- `.\gitsync.ps1` - Git 수동 동기화

### 🔗 관련 프로젝트
- [GIIP Dev Agent (Multi-Agent Framework)](https://github.com/LowyShin/giip-dev-agent) - 🤖 자율 멀티 에이전트 프레임워크 (신규!)
- [GIIP Agent Linux](../giipAgentLinux/README.md) - Linux/Unix 에이전트
- [GIIP FAW (API)](../giipfaw/README.md) - API 서버
- [GIIP DB](../giipdb/README.md) - 데이터베이스

## ⚠️ 주의사항

### 보안 필수
```powershell
# ❌ 절대 금지: 실제 비밀키를 저장소에 커밋
❌ git add giipAgent.cfg
❌ git push

# ✅ 올바른 방법: 부모 폴더에 보관
cp .\giipAgent.cfg ..\giipAgent.cfg.myserver
New-Item -ItemType SymbolicLink -Path giipAgent.cfg `
  -Target ..\giipAgent.cfg.myserver
```

### 실행 정책
```powershell
# 현재 정책 확인
Get-ExecutionPolicy

# 변경 필요시
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Task Scheduler 검증
```powershell
# 등록된 작업 확인
Get-ScheduledTask -TaskName "GIIP*"

# 실행 결과 확인
Get-ScheduledTask -TaskName "GIIP Agent Task" | Get-ScheduledTaskInfo

# 로그 위치
$env:LOCALAPPDATA\GIIP\logs\
```

### 다중 설치
- 한 서버에 **한 번만** 설치
- 중복 설치 시 이전 버전 자동 제거 여부 확인
- 설정 파일은 항상 외부에 보관 (git 무시 대상)

## 📊 에이전트 런타임 선택

| 런타임 | 파일 | 권장 | 특징 |
|--------|------|------|------|
| PowerShell | `giipAgentWin.ps1` | ✅ | 현대적, 기능 완전 |
| WSF | `giipAgent.wsf` | ⚠️ | 레거시, 보안 제약 |
| AutoHotkey | `giipAgent.ahk` | ❌ | v1.1만 지원, 비권장 |

**권장:** PowerShell 에이전트 사용

## 📞 지원

- **GitHub**: https://github.com/LowyShin/giipAgentWin
- **Issues**: https://github.com/LowyShin/giipAgentWin/issues
- **Linux 버전**: https://github.com/LowyShin/giipAgentLinux

## 📄 라이선스

GIIP 프로젝트 라이선스 준용
