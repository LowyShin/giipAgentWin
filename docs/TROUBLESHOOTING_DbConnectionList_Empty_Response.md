# Windows Agent API 에러 분석 - DbConnectionList

**날짜**: 2025-12-29 12:35  
**증상**: KVSPut API 빈 응답 (`RstVal: ''`, `RstMsg: ''`)

---

## 🐛 문제 분석

### 로그 분석

**API 호출**:
```
URL: https://giipfaw.azurewebsites.net/api/giipApiSk2
CMD: KVSPut kType kKey kFactor
JSON: {"kFactor":"db_connections","kValue":[...]}
```

**응답**:
```
RstVal: ''  ← 빈 문자열!
RstMsg: ''  ← 빈 문자열!
False
```

**정상 응답이어야 할 것**:
```json
{
  "data": [{
    "RstVal": "200",
    "RstMsg": "Process has done successfully"
  }]
}
```

---

## 🔍 확인된 사실

### 사실 1: 로그에서 관찰된 것

**로그 원본**:
```
"last_sql": "create procedure sys.sp_replmonitorrefreshagentdata   as  begin      set nocount on      declare @retcode int                  ,@agent_id int                  ,@agent_id2 int                  ,@publis"
```

**관찰**:
- 단어 사이 공백이 많음
- 그 외 특이사항 없음

**확인 불가**:
- 개행 문자가 있는지 로그만으로는 알 수 없음
- 실제 원인 불명

---

### 사실 2: API 응답 빈 문자열

**로그 원본**:
```
[WARN] RstVal: ''
[WARN] RstMsg: ''
False
```

**관찰**:
- RstVal 빈 문자열
- RstMsg 빈 문자열
- False 반환

**의미**:
- Azure Function이 정상 응답 반환 안함
- 에러 발생했으나 구체적 원인 불명

**DbConnectionList.ps1 현재 상태**:
```powershell
# L58 (2025-12-29 12:20 이전)
MAX(SUBSTRING(t.text, 1, 200)) as last_sql  ← 개행 제거 안함
```

**로컬 수정 완료** (Step 1457, 2025-12-29 12:05):
```powershell
# L58 (수정 후)
MAX(REPLACE(REPLACE(SUBSTRING(t.text, 1, 200), CHAR(13), ' '), CHAR(10), ' ')) as last_sql
```

**Windows 서버 배포**: 미확인

---

### 사실 2: API 응답 빈 문자열

**로그 증거**:
```
[WARN] RstVal: ''
[WARN] RstMsg: ''
False
```

**정상 응답**:
```json
{
  "RstVal": "200",
  "RstMsg": "Process has done successfully"
}
```

**의미**:
- Azure Function이 에러 발생
- 응답 JSON 생성 실패
- PowerShell `ConvertTo-Json` 실패 가능성

---

### 사실 3: run.ps1 수정 완료 (로컬)

**로컬 파일**:
- 파일: `giipfaw/giipApiSk2/run.ps1`
- 수정: L338-369 (Step 1569, 2025-12-29 12:20)
- 상태: NN 버그 수정 완료

**Azure Portal**: 미확인

---

## ❓ 미확인 사항

1. **Windows 서버 DbConnectionList.ps1 버전**
   - 수정된 버전인가?
   - 확인 방법: Windows 서버 L58 확인

2. **Azure Portal run.ps1 버전**
   - L338-369 수정되었는가?
   - 확인 방법: Azure Portal Code + Test

3. **실제 에러 메시지**
   - Azure Function 로그에 에러 있는가?
   - 확인 방법: Azure Portal Logs

---

## ✅ 확실한 해결 방법

### 1. DbConnectionList.ps1 배포

**현재 확인된 사실**:
- ✅ 로컬 수정 완료 (Step 1457)
- ❓ Windows 서버 배포 여부 불명

**조치**:
1. Windows 서버 접속
2. `giipAgentWin/giipscripts/modules/DbConnectionList.ps1` L58 확인
3. 수정되지 않았으면 로컬 파일로 교체
4. Agent 재시작

---

### 2. Azure Portal run.ps1 확인

**현재 확인된 사실**:
- ✅ 로컬 수정 완료 (Step 1569)
- ❓ Azure Portal 배포 여부 불명

**조치**:
1. Azure Portal 접속
2. giipApiSk2 → Code + Test
3. L338-369 확인
4. 수정되지 않았으면 로컬 파일로 교체
5. Save

---

### 3. 로그 확인

**필요한 정보**:
- Azure Function 실시간 로그
- 정확한 에러 메시지

**조치**:
1. Azure Portal → giipApiSk2 → Monitor → Logs
2. 최근 실행 로그 확인
3. 에러 스택 트레이스 확인

---

## 📋 즉시 조치 체크리스트

- [ ] Windows 서버 DbConnectionList.ps1 L58 확인
- [ ] 미수정이면 파일 교체
- [ ] Azure Portal run.ps1 L338-369 확인
- [ ] 미수정이면 파일 교체
- [ ] Agent 재시작
- [ ] Azure Function 로그 확인
- [ ] 테스트: Agent 재실행
- [ ] 로그 확인: RstVal='200'

---

## ✅ 해결 방법

### 1단계: DbConnectionList.ps1 배포 ⭐ 즉시

**파일**: `giipAgentWin/giipscripts/modules/DbConnectionList.ps1`  
**라인**: 58

**수정 내용**:
```powershell
# Before
MAX(SUBSTRING(t.text, 1, 200)) as last_sql

# After
MAX(REPLACE(REPLACE(SUBSTRING(t.text, 1, 200), CHAR(13), ' '), CHAR(10), ' ')) as last_sql
```

**배포**:
1. Windows 서버 접속
2. 파일 교체
3. Agent 재시작

**문서**: [DbConnectionList_SQL_Newline_Fix.md](../../giipAgentWin/docs/DbConnectionList_SQL_Newline_Fix.md)

---

### 2단계: run.ps1 배포 확인

**Azure Portal 확인**:
1. https://portal.azure.com
2. Function Apps → giipfaw → giipApiSk2
3. Code + Test → run.ps1
4. L338-369 확인

**기대값** (L339):
```powershell
# ✅ FIX: Match N'key' pattern and replace entirely to avoid NN prefix (2025-12-29)
```

**만약 다르면**:
1. 로컬 run.ps1 복사
2. Azure Portal에 붙여넣기
3. Save
4. Function App 재시작

---

### 3단계: 즉시 검증

**Windows Agent 재실행**:
```powershell
.\giipAgent3.ps1
```

**로그 확인**:
```
[INFO] [DbConnectionList] Sending connection data for DB: 28
RstVal: '200'  ← 정상!
RstMsg: 'Process has done successfully'
```

---

## 📊 우선순위

| 단계 | 작업 | 우선순위 | 예상 시간 |
|------|------|----------|-----------|
| 1 | DbConnectionList.ps1 배포 | ⭐⭐⭐ 긴급 | 5분 |
| 2 | run.ps1 Azure 배포 확인 | ⭐⭐⭐ 긴급 | 5분 |
| 3 | Agent 재시작 | ⭐⭐ 높음 | 1분 |
| 4 | 로그 검증 | ⭐⭐ 높음 | 5분 |

**총 예상 시간**: 15분

---

## 🚨 긴급 조치

### 임시 해결 (테스트용)

**DbConnectionList.ps1 L58만 수정**:
```powershell
# 개행 없는 더미 데이터 전송
last_sql = "QUERY_TOO_LONG"
```

**효과**:
- 개행 에러 회피
- 데이터는 부정확 (임시)

---

## 📝 체크리스트

### 배포 전
- [x] DbConnectionList.ps1 수정 완료 (Step 1457)
- [x] run.ps1 수정 완료 (Step 1569)
- [ ] **Windows 서버에 DbConnectionList.ps1 배포** ← 필수!
- [ ] **Azure Portal에 run.ps1 배포 확인** ← 필수!

### 배포 후
- [ ] Agent 재시작
- [ ] RstVal='200' 확인
- [ ] DB 연결 정보 업데이트 확인
- [ ] network-topology 페이지 확인

---

## 🔗 관련 문서

- [DbConnectionList_SQL_Newline_Fix.md](../../giipAgentWin/docs/DbConnectionList_SQL_Newline_Fix.md)
- [CHANGE_LOG_20251229_NN_BUG_FIX.md](../../giipfaw/giipApiSk2/CHANGE_LOG_20251229_NN_BUG_FIX.md)
- [VERSION_HISTORY_run_ps1.md](../../giipfaw/giipApiSk2/VERSION_HISTORY_run_ps1.md)

---

**작성**: 2025-12-29 12:35  
**우선순위**: 🔴 긴급
