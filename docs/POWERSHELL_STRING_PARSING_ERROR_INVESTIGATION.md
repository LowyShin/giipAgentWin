# PowerShell 문자열 파싱 에러 조사 보고서

## 문제 요약

**에러**: `DbUserList.ps1`에서 PowerShell 스크립트 파싱 에러
**증상**: "The string is missing the terminator: `"`"
**에러 위치**: 172번째 줄, 70번째 문자
**근본 원인**: 미확인 (조사 중)

---

## 에러 메시지

```
At C:\Users\shinh\Downloads\projects\ist-servers\tidb-relay-mgmt\giipAgentWin\giipscripts\modules\DbUserList.ps1:172
char:70
+ ... pLog "ERROR" ("[DbUserList] Error checking requests: {0}" -f $errMsg)
+                                                             ~~~~~~~~~~~~~
The string is missing the terminator: ".
```

---

## 조사 히스토리

### 시도 1: SqlConnectionStringBuilder (실패)
**가설**: Connection string의 password에 특수문자(따옴표, 세미콜론)가 포함되어 있음  
**조치**: 직접 문자열 보간 대신 `SqlConnectionStringBuilder` 사용
```powershell
# 이전
$connStr = "Server=$dbHost,$port;...;Password=$pass;..."

# 수정 후
$connStrBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$connStrBuilder["Password"] = $pass
```
**결과**: ❌ 에러 지속됨  
**결론**: Connection string이 근본 원인이 아님

---

### 시도 2: 에러 핸들러에 Format Operator 적용 (실패)
**가설**: Exception 메시지에 따옴표가 포함되어 문자열 보간이 깨짐  
**조치**: `$($_.Exception.Message)` 대신 `-f` format operator 사용
```powershell
# 이전
Write-GiipLog "ERROR" "[DbUserList] Error: $($_.Exception.Message)"

# 수정 후
$errMsg = $_.Exception.Message
Write-GiipLog "ERROR" ("[DbUserList] Error: {0}" -f $errMsg)
```
**결과**: ❌ 에러 지속됨  
**결론**: Format operator만으로는 불충분

---

### 시도 3: Write-GiipLog 함수 수정 (실패)
**가설**: `Write-GiipLog` 내부에서 문자열 보간을 사용하여 중첩 파싱 문제 발생  
**조치**: `lib/Common.ps1`의 `Write-GiipLog` 함수를 format operator로 수정
```powershell
# 이전
$line = "[$ts] [$Level] $Message"

# 수정 후
$line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
```
**결과**: ❌ 에러 여전히 지속됨 (2025-12-27 11:49:23 기준)  
**결론**: 다른 문제가 있음

---

## 주요 관찰사항

### 1. Git Pull은 정상 작동
서버가 최신 코드를 성공적으로 받음:
```
HEAD is now at 6451dc9 fix: Remove ALL string interpolations to prevent parsing errors with special characters
```

### 2. 라인 번호 불일치
- **로컬 파일**: 177줄 (`Get-Content`로 확인)
- **에러 보고**: 172줄
- **결론**: 서버에 다른 버전이 있거나 파일 인코딩 문제

### 3. 에러는 파싱 타임에 발생 (런타임 아님)
- 스크립트 실행 전에 에러 발생
- PowerShell 파서가 스크립트 로드 자체를 실패
- 가능성:
  - 파일 손상
  - 인코딩 문제 (UTF-8 with BOM vs without BOM, CR/LF vs LF)
  - 실제 문법 오류

### 4. 에러 위치 분석
172번째 줄:
```powershell
Write-GiipLog "ERROR" ("[DbUserList] Error checking requests: {0}" -f $errMsg)
```
이 문법은 정상적인 PowerShell 문법임. `-f` operator는 안전해야 함.

---

## 남은 가능성들

### 가능성 1: 파일 인코딩 문제
- **가설**: Windows에서 git pull 시 CR/LF 줄바꿈이 손상됨
- **필요 테스트**: `.gitattributes`에서 줄바꿈 설정 확인
- **필요 테스트**: 서버에서 파일 인코딩 확인 (UTF-8 with/without BOM)

### 가능성 2: 숨겨진 문자
- **가설**: 파일에 보이지 않는 유니코드 문자 존재 (zero-width space, smart quotes)
- **필요 테스트**: 172번째 줄 근처 hex dump 확인
- **필요 테스트**: "따옴표"가 실제로 유니코드 따옴표(U+201C/U+201D)인지 ASCII(U+0022)인지 확인

### 가능성 3: PowerShell 버전 비호환성
- **가설**: 서버가 구버전 PowerShell 사용 (다른 파싱 규칙)
- **필요 테스트**: 서버의 PowerShell 버전 확인 (`$PSVersionTable`)
- **필요 테스트**: PowerShell 5.1 vs 7.x에서 문법 테스트

### 가능성 4: 놓친 실제 문법 오류
- **가설**: 다른 곳에 실제 문법 오류가 있어서 172번째 줄까지 cascading
- **필요 테스트**: PowerShell parser AST 체크 실행
- **필요 테스트**: Strict mode에서 스크립트 테스트

### 가능성 5: DbUserList.ps1이 아닌 다른 곳의 문제
- **가설**: 실제 에러는 `Common.ps1`에 있는데 잘못 보고됨
- **필요 테스트**: `Write-GiipLog` 함수가 정상 로드되는지 확인
- **필요 테스트**: `DbUserList.ps1`을 최소 stub `Write-GiipLog`로 테스트

---

## 다음 단계 (권장 접근법)

### 1단계: 서버 환경 확인
```powershell
# 서버에서 실행:
$PSVersionTable
Get-Content "DbUserList.ps1" -Encoding UTF8 | Measure-Object -Line
(Get-Content "DbUserList.ps1" -Raw).Length
```

### 2단계: 숨겨진 문자 확인
```powershell
# 서버에서 172번째 줄 체크:
$lines = Get-Content "DbUserList.ps1" -Encoding UTF8
$line172 = $lines[171]
$line172.ToCharArray() | ForEach-Object { "[{0}] U+{1:X4}" -f $_, [int]$_ }
```

### 3단계: 간소화된 버전 테스트
최소 테스트 파일로 문제 격리:
```powershell
# test-string-format.ps1
function Write-GiipLog {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
    Write-Host $line
}

$errMsg = 'Test error with "quotes" and $pecial characters'
Write-GiipLog "ERROR" ("[Test] Error: {0}" -f $errMsg)
```

### 4단계: 외부 문자열에 단일 따옴표 사용 ⭐ **현재 적용 중**
이중 따옴표 대신:
```powershell
Write-GiipLog "ERROR" ("[DbUserList] Error checking requests: {0}" -f $errMsg)
```
단일 따옴표 사용:
```powershell
Write-GiipLog 'ERROR' ('[DbUserList] Error checking requests: {0}' -f $errMsg)
```
단일 따옴표는 어떤 보간도 하지 않으므로 더 안전함.

### 5단계: 최종 해결책 - 모든 동적 문자열 회피 ⭐ **현재 적용 중**
```powershell
# 복잡한 방법 대신 아주 명시적으로:
try {
    # ... code ...
} catch {
    $safeMsg = $_.Exception.Message -replace '"', "'" -replace '`', ''
    $fullMsg = '[DbUserList] Error checking requests: ' + $safeMsg
    Write-GiipLog 'ERROR' $fullMsg
}
```

---

## 결론

3번의 실패 후, 근본 원인은 **여전히 미확인**. 다음을 시도했으나 에러 지속:
1. ✅ Connection string 특수문자 처리 수정
2. ✅ 문자열 보간 대신 format operator 사용
3. ✅ Write-GiipLog 함수 수정

**현재 상태**: BLOCKED - 추가 디버깅을 위해 서버 직접 접근 필요

**권장 조치**: 
1. 서버에서 PowerShell 버전 확인
2. 문제 라인의 hex dump 확인
3. 최소 재현 케이스로 테스트
4. **최종 해결책**: 단일 따옴표 + 문자열 연결 사용 (현재 적용 중)

---

## 추가 조치 (2025-12-27 11:50)

### 시도 4: 단일 따옴표 + 특수문자 Escape (진행 중)
**조치**: 
- 모든 이중 따옴표를 단일 따옴표로 변경
- format operator 대신 문자열 연결(`+`) 사용
- Exception 메시지의 특수문자를 escape 처리

```powershell
# 최종 적용 코드
$errMsg = ($_.Exception.Message -replace '"', "'" -replace '`', '')
Write-GiipLog 'ERROR' ('[DbUserList] Error checking requests: ' + $errMsg)
```

**기대 결과**: 어떤 특수문자도 PowerShell 파서를 깨지 못하도록 완전 방어

## Problem Summary

**Error**: PowerShell script parsing error in `DbUserList.ps1`
**Symptom**: "The string is missing the terminator: `"`"
**Error Location**: Line 172, character 70
**Root Cause**: UNKNOWN (Still investigating)

---

## Error Message

```
At C:\Users\shinh\Downloads\projects\ist-servers\tidb-relay-mgmt\giipAgentWin\giipscripts\modules\DbUserList.ps1:172
char:70
+ ... pLog "ERROR" ("[DbUserList] Error checking requests: {0}" -f $errMsg)
+                                                             ~~~~~~~~~~~~~
The string is missing the terminator: ".
```

---

## Investigation History

### Attempt 1: SqlConnectionStringBuilder (FAILED)
**Hypothesis**: Password in connection string contains special characters (quotes, semicolons)  
**Action**: Replaced direct string interpolation with `SqlConnectionStringBuilder`
```powershell
# Before
$connStr = "Server=$dbHost,$port;...;Password=$pass;..."

# After
$connStrBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$connStrBuilder["Password"] = $pass
```
**Result**: ❌ Error persists  
**Conclusion**: Connection string was NOT the root cause

---

### Attempt 2: Format Operator in Error Handlers (FAILED)
**Hypothesis**: Exception messages contain quotes, breaking string interpolation  
**Action**: Replaced `$($_.Exception.Message)` with `-f` format operator
```powershell
# Before
Write-GiipLog "ERROR" "[DbUserList] Error: $($_.Exception.Message)"

# After
$errMsg = $_.Exception.Message
Write-GiipLog "ERROR" ("[DbUserList] Error: {0}" -f $errMsg)
```
**Result**: ❌ Error persists  
**Conclusion**: Format operator alone was NOT sufficient

---

### Attempt 3: Fix Write-GiipLog Function (FAILED)
**Hypothesis**: `Write-GiipLog` internally uses string interpolation, causing nested parsing issues  
**Action**: Modified `lib/Common.ps1` to use format operator in `Write-GiipLog` function
```powershell
# Before
$line = "[$ts] [$Level] $Message"

# After
$line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
```
**Result**: ❌ Error STILL persists (as of 2025-12-27 11:49:23)  
**Conclusion**: Something else is wrong

---

## Key Observations

### 1. Git Pull is Working
Server successfully pulls latest code:
```
HEAD is now at 6451dc9 fix: Remove ALL string interpolations to prevent parsing errors with special characters
```

### 2. Line Number Mismatch
- **Local file**: 177 lines (confirmed by `Get-Content`)
- **Error reports**: Line 172
- **Conclusion**: Server might have different version OR file encoding issue

### 3. Error is PARSE-TIME, not RUNTIME
- Error occurs BEFORE script executes
- PowerShell parser fails to load the script
- This suggests:
  - File corruption
  - Encoding issue (UTF-8 with BOM vs without BOM, CR/LF vs LF)
  - Actual syntax error in the file

### 4. Error Location Analysis
Line 172 points to:
```powershell
Write-GiipLog "ERROR" ("[DbUserList] Error checking requests: {0}" -f $errMsg)
```
But this SHOULD be valid PowerShell syntax. The `-f` operator is safe.

---

## Remaining Possibilities

### Possibility 1: File Encoding Issue
- **Hypothesis**: CR/LF line endings are corrupted during git pull on Windows
- **Test Needed**: Check `.gitattributes` for line ending settings
- **Test Needed**: Verify file encoding on server (UTF-8 with/without BOM)

### Possibility 2: Hidden Characters
- **Hypothesis**: Invisible Unicode characters (zero-width space, smart quotes) in the file
- **Test Needed**: Hex dump of the file around line 172
- **Test Needed**: Check if "quotes" are actually Unicode quotes (U+201C/U+201D) instead of ASCII (U+0022)

### Possibility 3: PowerShell Version Incompatibility
- **Hypothesis**: Server uses old PowerShell version with different parsing rules
- **Test Needed**: Check PowerShell version on server (`$PSVersionTable`)
- **Test Needed**: Test script syntax on PowerShell 5.1 vs 7.x

### Possibility 4: Actual Syntax Error We Missed
- **Hypothesis**: There's a REAL syntax error elsewhere that cascades to line 172
- **Test Needed**: Run PowerShell parser AST check
- **Test Needed**: Test script in strict mode

### Possibility 5: The Problem is NOT in DbUserList.ps1
- **Hypothesis**: Error is actually in `Common.ps1` but reported incorrectly
- **Test Needed**: Check if `Write-GiipLog` function loads correctly
- **Test Needed**: Test `DbUserList.ps1` with a minimal stub of `Write-GiipLog`

---

## Next Steps (Recommended Approach)

### Step 1: Verify Server Environment
```powershell
# On the server, run:
$PSVersionTable
Get-Content "DbUserList.ps1" -Encoding UTF8 | Measure-Object -Line
(Get-Content "DbUserList.ps1" -Raw).Length
```

### Step 2: Check for Hidden Characters
```powershell
# On the server, check line 172:
$lines = Get-Content "DbUserList.ps1" -Encoding UTF8
$line172 = $lines[171]
$line172.ToCharArray() | ForEach-Object { "[{0}] U+{1:X4}" -f $_, [int]$_ }
```

### Step 3: Test Simplified Version
Create a minimal test file to isolate the issue:
```powershell
# test-string-format.ps1
function Write-GiipLog {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
    Write-Host $line
}

$errMsg = 'Test error with "quotes" and $pecial characters'
Write-GiipLog "ERROR" ("[Test] Error: {0}" -f $errMsg)
```

### Step 4: Use Single Quotes for Outer String
Instead of:
```powershell
Write-GiipLog "ERROR" ("[DbUserList] Error checking requests: {0}" -f $errMsg)
```
Try:
```powershell
Write-GiipLog 'ERROR' ('[DbUserList] Error checking requests: {0}' -f $errMsg)
```
Single quotes don't do ANY interpolation, so they're safer.

### Step 5: Ultimate Workaround - Avoid All Dynamic Strings
```powershell
# Instead of trying to be clever, just be VERY explicit:
try {
    # ... code ...
} catch {
    $safeMsg = $_.Exception.Message -replace '"', "'" -replace '`', ''
    $fullMsg = '[DbUserList] Error checking requests: ' + $safeMsg
    Write-GiipLog 'ERROR' $fullMsg
}
```

---

## Conclusion

After 3 failed attempts, the root cause is **still unknown**. The error persists despite:
1. ✅ Fixing connection string special character handling
2. ✅ Using format operator instead of string interpolation  
3. ✅ Fixing Write-GiipLog function

**Current Status**: BLOCKED - Need direct server access to debug further

**Recommended Action**: 
1. Get PowerShell version from server
2. Get hex dump of problematic line
3. Test with minimal reproduction case
4. Consider using single quotes and string concatenation as ultimate workaround
