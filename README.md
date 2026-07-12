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

## 🚀 빠른 시작

### 1. 준비사항

```bash
# 시스템 요구사항 확인
- Windows Server 2012 R2 이상
- PowerShell 5.1 이상
- Administrator 권한
- 인터넷 연결
```

### 2. 설치

```powershell
# 관리자 권한으로 PowerShell 실행
# (마우스 우클릭 → "관리자로 실행")

# 설치 폴더 이동
cd C:\

# 저장소 클론
git clone https://github.com/LowyShin/giipAgentWin.git
cd giipAgentWin

# 실행 정책 설정 (필요시)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 3. 설정

```powershell
# 설정 파일 편집
notepad giipAgent.cfg
```

**필수 설정:**
```ini
sk="Secret-Key"              # GIIP 포털에서 발급받은 키
lssn="0"                    # 서버 번호 (0 = 자동 할당)
giipagentdelay="60"         # 실행 간격 (초)
apiaddr="https://..."       # API 주소
```

### 4. 등록

```powershell
# Task Scheduler에 등록
.\TaskSchdReg.ps1

# 검증
Get-ScheduledTask -TaskName "GIIP*"
```

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

## 🗂️ 레포 / 기밀 분리 구조 (중요 — 혼동 주의)

이 폴더(`giipAgentWin/`)는 **그 자체가 독립 git 저장소**다: `git@github.com:LowyShin/giipAgentWin.git`.
여러 서버·여러 사용자가 이 저장소를 clone 해 **공용(public) 스크립트**를 공유한다.

- ✅ **공용(저장소에 커밋)**: `giipscripts/*.ps1`, `lib/*.ps1`, `giipAgent.cfg.example`(플레이스홀더 템플릿) 등 코드.
- 🔒 **기밀(저장소 밖, 절대 커밋 금지)**: 실 `giipAgent.cfg`(각자의 `sk`/`lssn`/Azure SPN 시크릿).
  이 저장소 **폴더 밖**에 둔다 → ① `giipAgentWin`의 **부모 디렉터리**(예: `…/giipAgent/giipAgent.cfg`),
  또는 ② `%USERPROFILE%\giipAgent.cfg`. 설정 로더(`lib/Common.ps1: Get-GiipConfig`)가 이 순서로 찾으며,
  머리글에 `SAMPLE`이 있으면 **템플릿으로 간주해 건너뛴다**(실수로 예제를 실설정으로 쓰는 것 방지).

> ⚠️ **자주 하는 오해:** `giipAgent/` **루트**에서 `git status`를 돌리면 "not a git repository"가 나온다.
> 그렇다고 스크립트가 비-git인 게 **아니다** — 저장소는 한 단계 아래 `giipAgent/giipAgentWin/`이다.
> 정본 코드는 `LowyShin/giipAgentWin`에 있고, 기밀만 부모 폴더(비-git)에 있다.

## 💰 Azure 비용 수집기 (멀티유저)

`giipscripts/azure-cost-put-win.ps1` — Azure Cost Management API로 구독 비용을 수집해 GIIP KVS(`kFactor=azure_cost`)에 적재하는 **독립 실행형** 스크립트. **서비스별(`by_service`)과 리소스 그룹별(`by_resource_group`) 두 축**을 함께 수집한다.

사용자마다 **자기 계정 정보**로 수집하려면:

1. `giipAgent.cfg.example`을 **저장소 밖**으로 복사한다(위 "레포/기밀 분리" 참고): 부모 폴더 또는 `%USERPROFILE%\giipAgent.cfg`.
2. 복사본에 본인 값을 채운다: `sk`, `lssn`, 그리고 무인 실행용 Azure 서비스 주체 `az_subscription`/`az_client_id`/`az_client_secret`/`az_tenant_id`(생략 시 대화형 `az login` 세션 사용).
3. 실행/등록:
   ```powershell
   # 수동 실행(최근 7일)
   .\giipscripts\azure-cost-put-win.ps1 -Days 7
   # 매일 06:00 예약 작업 등록
   .\giipscripts\azure-cost-put-win.ps1 -Register -AtTime "06:00"
   ```

- 조회 페이지(giipv3): 서비스별 `/{locale}/azure-cost`, 리소스 그룹별 `/{locale}/azure-cost-rg`.
- 상세 사양: `giipdb/docs/30_Specs/AZURE_COST_COLLECTOR_SPECIFICATION.md`(giipdb 저장소).

## 📞 지원

- **GitHub**: https://github.com/LowyShin/giipAgentWin
- **Issues**: https://github.com/LowyShin/giipAgentWin/issues
- **Linux 버전**: https://github.com/LowyShin/giipAgentLinux

## 📄 라이선스

GIIP 프로젝트 라이선스 준용
