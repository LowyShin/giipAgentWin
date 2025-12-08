# Windows Agent (giipAgentWin) 개발 프롬프트

> **배경**: 레거시 `giipAgentWin`을 `giipAgentLinux` (v3)의 현대적인 아키텍처에 맞춰 개보수(Renovate)하려고 합니다. 목표는 API 사용(V2/Sk2), 설정 처리, 로깅 방식을 표준화하는 것입니다.

## 📋 작업 요청 템플릿

아래 프롬프트를 복사하여 AI 에이전트에게 전달하면 `giipAgentWin`의 개발 또는 유지보수 작업을 시작할 수 있습니다.

---

```markdown
**작업**: `giipAgentWin` 컴포넌트 개보수 및 설정 표준화

**컴포넌트**: `giipAgentWin`
**플랫폼**: Windows PowerShell

### 📚 참조 문서 (필독)
1. **[GIIPAGENTWIN_SPECIFICATION.md](./GIIPAGENTWIN_SPECIFICATION.md)** - ⭐ 사양서
2. **[CONFIG_MIGRATION_REPORT.md](./CONFIG_MIGRATION_REPORT.md)** - ⭐ 설정 변경에 따른 **필수 수정 사항 리포트**

### 🚨 최우선 수정 사항 (Config & API)

**1. 설정 파일 (giipAgent.cfg) 파싱 로직 수정**
- 새로운 설정 파일 포맷: `Key = "Value"` (등호 주위 공백 있음)
- `giip-auto-discover.ps1`의 정규식 수정 필요: `^\s*(\w+)\s*=\s*"([^"]*)"` 사용.
- 스크립트 내 변수 매핑 수정:
  - Old `at` -> New `sk`
  - Old `lsSn` -> New `lssn`
  - Old `apiaddr` -> New `apiaddrv2`

**2. API 호출 로직 전면 교체 (Legacy ASP -> V2 API)**
- `giipAgentWin.ps1` 내 하드코딩된 `$API_QUEUE_URL_TEMPLATE` 제거.
- 대신 `apiaddrv2`를 사용하여 `Invoke-GiipApiV2` 호출 구조로 변경.
- **인증 보안**: URL에 `?sk=...` 노출 절대 금지. 반드시 Body의 `token` 파라미터 사용.

### 🛠️ 개발 규칙 (Standard Rules)

**1. API 상호작용**
- POST 요청만 사용.
- Payload: `token`(=$Config.sk), `text`, `jsondata`.

**2. 설정(Configuration) 처리**
- 위치 우선순위: 부모 디렉토리(`../giipAgent.cfg`) -> 사용자 프로필.
- DB 연결 문자열(SqlConnectionString) 사용 금지.

**3. 로깅 (Logging)**
- 저장 위치: `../giipLogs/`

### 🚀 구현 단계

1. **마이그레이션 리포트 확인**: `CONFIG_MIGRATION_REPORT.md`를 읽고 기존 코드의 문제점 파악.
2. **리팩토링**: `Read-Config` 함수와 정규식을 업데이트하여 공백이 포함된 새 설정 포맷 지원.
3. **API 함수 구현**: `Invoke-GiipApiV2` (Token/Text/JsonData 지원) 구현.
4. **메인 로직 업데이트**: 구형 ASP 호출 코드를 삭제하고 V2 API 폴링/보고 로직으로 대체.

### ✅ 완료 조건 (Definition of Done)
- [ ] `giip-auto-discover.ps1`이 새 설정 포맷(` = "`)을 에러 없이 읽어야 함.
- [ ] `giipAgentWin.ps1`이 `apiaddrv2`를 사용하여 통신해야 함.
- [ ] 소스 코드 내 `cqequeueget04.asp` 등의 레거시 문자열이 완전히 제거되어야 함.
```
