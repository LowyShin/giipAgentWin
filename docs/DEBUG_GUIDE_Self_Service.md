# Windows Agent API 에러 디버깅 가이드

**날짜**: 2025-12-29  
**목적**: 스스로 에러 원인 찾기

---

## 🔍 1단계: ErrorLog 확인

### 데이터베이스 쿼리

```sql
-- 최근 에러 로그 확인 (최근 1시간)
SELECT TOP 20
    elId,
    elCreatedAt,
    elSource,
    elSpName,
    elErrorMessage,
    elRequestData,
    elResponseData,
    elJsonDataRaw,
    elQueryText
FROM ErrorLogs
WHERE elCreatedAt >= DATEADD(HOUR, -1, GETDATE())
  AND elSource = 'azure-function-sk2'
ORDER BY elCreatedAt DESC
```

### 확인할 필드

**elJsonDataRaw**: 원본 JSON 데이터  
**elRequestData**: API 요청 데이터  
**elQueryText**: 실행된 SQL 쿼리  
**elErrorMessage**: 에러 메시지

---

## 🔍 2단계: Azure Function 로그

### Azure Portal 접속

1. https://portal.azure.com
2. Function Apps → giipfaw → giipApiSk2
3. Monitor → Logs

### 쿼리 실행

```kusto
traces
| where timestamp > ago(1h)
| where message contains "KVSPut" or message contains "error"
| order by timestamp desc
| take 50
```

### 확인 사항

- Exception 메시지
- Stack trace
- Request/Response 데이터

---

## 🔧 3단계: run.ps1에 디버그 로그 추가

### 수정 위치: run.ps1 L272 (jsondata 처리 전)

```powershell
# jsondata 처리 전에 로그 추가
if ($jsonData -and ($spName.ToLower() -ne 'kvsput')) {
    try {
        # ✅ 디버그: jsondata 길이와 첫 100자 출력
        Write-Host "[DEBUG] jsonData length: $($jsonData.Length)"
        Write-Host "[DEBUG] jsonData preview: $($jsonData.Substring(0, [Math]::Min(100, $jsonData.Length)))"
        
        # ✅ 디버그: JSON 파싱 시도
        try {
            $testParse = $jsonData | ConvertFrom-Json
            Write-Host "[DEBUG] JSON parsing: SUCCESS"
        }
        catch {
            Write-Host "[DEBUG] JSON parsing: FAILED - $_"
            
            # ✅ ErrorLog 기록
            Log-AzureError `
                -ErrorMessage "JSON parsing failed for $spName" `
                -StackTrace $_.Exception.StackTrace `
                -ApiEndpoint "giipApiSk2" `
                -RequestData "text=$bodyText, jsondata=$($jsonData.Substring(0, [Math]::Min(200, $jsonData.Length)))" `
                -ConnectionString $SqlConnectionString
        }
        
        # 기존 로직 계속...
    }
    catch { ... }
}
```

---

## 🔧 4단계: DbConnectionList.ps1에 디버그 로그 추가

### 수정 위치: DbConnectionList.ps1 L218 (API 호출 전)

```powershell
try {
    $jsonPayload = $statsList | ConvertTo-Json -Compress
    
    # ✅ 디버그: JSON 길이 출력
    Write-GiipLog "DEBUG" "[DbConnectionList] JSON length: $($jsonPayload.Length)"
    
    # ✅ 디버그: JSON 미리보기
    $preview = $jsonPayload.Substring(0, [Math]::Min(200, $jsonPayload.Length))
    Write-GiipLog "DEBUG" "[DbConnectionList] JSON preview: $preview"
    
    # ✅ 디버그: 개행 문자 검사
    if ($jsonPayload -match "[\r\n]") {
        Write-GiipLog "WARN" "[DbConnectionList] JSON contains newline characters!"
    }
    
    Write-GiipLog "INFO" "[DbConnectionList] Sending connection data for DB: $dbId"
    
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "KVSPut kType kKey kFactor" -JsonData $jsonPayload
    
    # ... 기존 로직
}
```

---

## 📋 실행 순서

### 1. 로그 확인 (기존)

```sql
-- 최근 1시간 에러
SELECT * FROM ErrorLogs 
WHERE elCreatedAt >= DATEADD(HOUR, -1, GETDATE())
ORDER BY elCreatedAt DESC
```

### 2. 디버그 로그 추가 (필요시)

- run.ps1 수정
- DbConnectionList.ps1 수정
- Azure Portal 배포
- Windows 서버 파일 교체

### 3. Agent 재실행

```powershell
.\giipAgent3.ps1
```

### 4. 로그 재확인

- ErrorLogs 테이블
- Azure Function Logs
- Agent 로그 파일

---

## 🎯 핵심 디버그 포인트

### DbConnectionList.ps1 L58

**현재**:
```powershell
MAX(SUBSTRING(t.text, 1, 200)) as last_sql
```

**수정 (Step 1457)**:
```powershell
MAX(REPLACE(REPLACE(SUBSTRING(t.text, 1, 200), CHAR(13), ' '), CHAR(10), ' ')) as last_sql
```

**배포 여부 확인**:
1. Windows 서버 접속
2. 파일 열기
3. L58 확인

---

## 📁 관련 파일

### ErrorLog SP
- `giipdb/SP/pApiErrorLogCreatebyAK.sql`
- `giipdb/SP/pApiErrorLogCreatebySk.sql`

### ErrorLog Table
- `giipdb/Tables/ErrorLogs.sql`

### run.ps1
- `giipfaw/giipApiSk2/run.ps1` L60-90 (Log-AzureError)

---

**작성**: 2025-12-29  
**사용자**: 스스로 찾기
