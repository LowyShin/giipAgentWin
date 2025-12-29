# Windows Agent DbConnectionList.ps1 수정 내역

**날짜**: 2025-12-29  
**수정자**: AI Agent  
**목적**: JSON 파싱 에러 방지

---

## 문제

**에러 메시지**:
```
認識できないエスケープ シーケンスです。(3410)
```

**원인**: 
- `last_sql` 필드에 개행 문자(`\r\n`) 포함
- JSON으로 직렬화 시 이스케이프 시퀀스 에러 발생
- PowerShell `ConvertTo-Json` 파싱 실패

---

## 수정 내용

**파일**: `giipAgentWin/giipscripts/modules/DbConnectionList.ps1`

### Before (L58)
```sql
MAX(SUBSTRING(t.text, 1, 200)) as last_sql
```

### After (L58)
```sql
MAX(REPLACE(REPLACE(SUBSTRING(t.text, 1, 200), CHAR(13), ' '), CHAR(10), ' ')) as last_sql
```

**변경 사항**:
- `CHAR(13)` (Carriage Return, `\r`) → 공백
- `CHAR(10)` (Line Feed, `\n`) → 공백
- SQL 쿼리 레벨에서 개행 문자 제거

---

## 수정 이유

### 데이터 흐름
```
SQL Server → PowerShell → JSON → Azure Function → JSON 파싱
                                              ↑
                                          여기서 에러!
```

### 문제 발생 지점
1. SQL Server에서 실행 중인 쿼리 텍스트 추출
2. 쿼리에 개행 문자 포함 (예: `SELECT\r\n    FROM...`)
3. PowerShell에서 `ConvertTo-Json`으로 직렬화
4. Azure Function에서 JSON 파싱 시 `\r\n` 이스케이프 에러

### 해결 방법 비교

| 방법 | 위치 | 장점 | 단점 |
|------|------|------|------|
| SQL에서 제거 | DbConnectionList.ps1 L58 | ✅ 근본 해결 | - |
| PowerShell에서 제거 | DbConnectionList.ps1 L73 | - | ❌ 코드 복잡 |
| run.ps1에서 제거 | run.ps1 L424 | - | ❌ 금지됨! |

**선택**: SQL 쿼리 레벨에서 제거 (가장 근본적)

---

## 영향 범위

**변경됨**:
- ✅ `DbConnectionList.ps1` SQL 쿼리

**영향 없음**:
- ✅ run.ps1 (수정 금지)
- ✅ DB 스키마
- ✅ API 규격
- ✅ 기존 데이터

---

## 테스트

**테스트 방법**:
1. Windows 서버에서 DbConnectionList.ps1 실행
2. Azure Function 로그에서 `_debug_executedQuery` 확인
3. `RstVal: 200` 확인

**예상 결과**:
```json
{
  "data": [{
    "RstVal": 200,
    "RstMsg": "Process has done successfully"
  }]
}
```

---

## 관련 문서

- [NN_PREFIX_BUG_ANALYSIS.md](../../giipfaw/giipApiSk2/NN_PREFIX_BUG_ANALYSIS.md) - NN 버그 분석
- [PROHIBITED_ACTION_2_RUN_PS1.md](../../giipdb/docs/PROHIBITED_ACTION_2_RUN_PS1.md) - run.ps1 수정 금지

---

**최종 수정**: 2025-12-29
