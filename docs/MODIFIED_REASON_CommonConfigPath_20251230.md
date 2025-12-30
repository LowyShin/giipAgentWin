# 수정 근거: Agent 설정 파일 경로 우선순위 수정

> **수정 일시**: 2025-12-30 21:15  
> **수정자**: AI Agent  
> **관련 에러**: 3626, 3659

---

## 📋 수정 개요

**수정 파일**: `giipAgentWin/lib/Common.ps1`  
**수정 함수**: `Get-GiipConfig` (Line 54-69)  
**수정 이유**: 샘플 설정 파일(`giipAgent.cfg`)을 실제 설정으로 읽어 'YOUR_LSSN' placeholder 값 사용

---

## 🔍 문제 상황

### 발생한 에러
- **에러 ID**: 3626 (09:13:38), 3659 (12:05:38)
- **에러 메시지**: `varchar value 'YOUR_LSSN' to data type int`
- **재발 주기**: 약 3시간 (Agent 실행 주기)

### 근본 원인
`Common.ps1`의 설정 파일 검색 우선순위가 잘못되어 샘플 파일을 먼저 읽음:

**문제 코드** (Line 60):
```powershell
$candidates += (Join-Path $Global:BaseDir "giipAgent.cfg")  # ❌ 샘플!
```

- `$Global:BaseDir` = `giipAgentWin` 디렉토리
- `giipAgentWin/giipAgent.cfg` = 샘플 파일 (lssn = "YOUR_LSSN")
- 결과: 실제 설정 대신 샘플 값 사용

---

## 🛠 수정 내용

### 수정 전 (Line 54-69)
```powershell
function Get-GiipConfig {
    # Priority: 1. Parent Dir (../giipAgent.cfg) represented by $Global:BaseDir/../
    #           2. User Profile
    
    $candidates = @()
    if ($Global:BaseDir) {
        $candidates += (Join-Path $Global:BaseDir "giipAgent.cfg")      # ❌
        $candidates += (Join-Path $Global:BaseDir "../giipAgent.cfg")
    }
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot "giipAgent.cfg")        # ❌
        $candidates += (Join-Path $PSScriptRoot "../giipAgent.cfg")
    }
    $candidates += (Join-Path (Get-Location) "giipAgent.cfg")
    $candidates += (Join-Path $env:USERPROFILE "giipAgent.cfg")
```

### 수정 후 (Line 54-73)
```powershell
function Get-GiipConfig {
    # Priority: 1. Parent Dir (../giipAgent.cfg) - Real Config
    #           2. User Profile
    #           3. Current Directory (fallback)
    # ⚠️ IMPORTANT: Do NOT search in $BaseDir itself - that's where the SAMPLE file is!
    
    $candidates = @()
    if ($Global:BaseDir) {
        # ✅ Search PARENT directory first (real config location)
        $candidates += (Join-Path $Global:BaseDir "../giipAgent.cfg")
    }
    # Current Directory of script (parent of lib/)
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot "../giipAgent.cfg")
    }
    # User Profile
    $candidates += (Join-Path $env:USERPROFILE "giipAgent.cfg")
    # Current working directory (fallback)
    $candidates += (Join-Path (Get-Location) "giipAgent.cfg")
```

### 핵심 변경사항
1. ❌ **삭제**: `Join-Path $Global:BaseDir "giipAgent.cfg"` (Line 60)
2. ❌ **삭제**: `Join-Path $PSScriptRoot "giipAgent.cfg"` (Line 65)
3. ✅ **우선순위 변경**: 상위 디렉토리(`../`) 우선 검색
4. ✅ **주석 추가**: 샘플 파일 검색 금지 명시

---

## ✅ 예상 효과

### 수정 전 검색 순서
1. `giipAgentWin/giipAgent.cfg` ← ❌ **샘플 파일 (YOUR_LSSN)**
2. `giipprj/giipAgent.cfg` ← 실제 설정
3. `lib/giipAgent.cfg` ← (없음)
4. `../giipAgent.cfg` ← (중복)
5. `%USERPROFILE%/giipAgent.cfg` ← 실제 설정

### 수정 후 검색 순서
1. `giipprj/giipAgent.cfg` ← ✅ **실제 설정 우선!**
2. `../giipAgent.cfg` ← (중복, 동일 경로)
3. `%USERPROFILE%/giipAgent.cfg` ← 실제 설정
4. `현재디렉토리/giipAgent.cfg` ← 폴백

### 결과
- ✅ 실제 설정 파일 우선 로드
- ✅ 'YOUR_LSSN' 에러 미발생
- ✅ Agent 정상 동작

---

## 🔗 관련 문서

- [ERROR_ANALYSIS_20251230_ConfigPath_YOUR_LSSN.md](../../giipdb/docs/ERROR_ANALYSIS_20251230_ConfigPath_YOUR_LSSN.md) - 상세 분석
- [ERROR_RESOLUTION_HISTORY.md](../../giipdb/docs/ERROR_RESOLUTION_HISTORY.md) - 해결 이력
- [giipAgent.cfg](../giipAgent.cfg) - 샘플 설정 파일
- [Common.ps1](../lib/Common.ps1) - 수정된 파일

---

## ⚠️ 주의사항

### 이 수정이 필요한 이유
`giipAgentWin/giipAgent.cfg`는 **샘플 파일**이며 다음을 포함:
- `lssn = "YOUR_LSSN"`
- `sk = "YOUR_KVS_TOKEN"`

이 파일은 **절대 실제 값으로 수정하면 안 되며**, 상위 디렉토리나 USERPROFILE에 실제 설정을 만들어야 합니다.

### 배포 시 확인사항
- Agent 배포 서버에 실제 설정 파일 존재 확인
- 샘플 파일은 그대로 유지 (문서용)

---

**작성 완료**: 2025-12-30 21:17
