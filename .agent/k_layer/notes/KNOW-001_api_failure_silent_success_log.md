# KNOW-001: API 호출 실패가 로그에는 "성공"으로 남는 패턴 (Invoke-GiipApiV2/Invoke-GiipKvsPut)

> 자동 생성: 2026-09-26 | source: giip 3079(csn 70418 실측), giip 3078 조사 중 발견

## CLAIM-001

- **주장**: `Invoke-GiipApiV2`(`lib/Common.ps1`)는 애플리케이션 레벨 실패(HTTP 200으로 응답이
  왔지만 `RstVal != 200`, 예: giipApiSk2가 SK 토큰을 일반 문자열로 오판정해 400을 반환하는 giip
  3078류 회귀)에도 예외를 던지지 않고 응답 객체를 그대로 반환한다. 네트워크 예외나 `apiaddrv2`
  누락일 때만 `$null`을 반환한다. 이 계약을 모르고 호출부가 반환값을 `Out-Null`로 버리거나
  확인 없이 무조건 "성공" 로그를 남기면, 서버 쪽 실패가 로그에는 전혀 보이지 않는다.
- **관측**: 2026-09-25 giip 3043에서 신규 작성된 `giipscripts/modules/CollectDockerMetrics.ps1`
  163~165행이 정확히 이 패턴이었다(`Invoke-GiipKvsPut ... | Out-Null` 후 무조건
  `Write-GiipLog "INFO" "...Successfully..."`). csn 70418이 giipApiSk2 회귀(giip 3078) 진단 중
  실제 로그에서 "API가 400으로 실패했는데 로그는 성공"인 사례를 발견해 보고했다.
- **부가 원인**: `Invoke-GiipApiV2` 내부에서 실패를 알리는 두 로그(`API Non-Success Response`,
  `API Call Failed`)가 원래 DEBUG 레벨이었다 - 호출부가 반환값을 제대로 확인해도, 사람이 보는
  로그(보통 INFO 이상)에는 애초에 안 찍히는 구조였다.
- **source**: giip 3079 작업 세션(2026-09-26), giip 3078 조사 코멘트
- **status**: resolved (giipAgentWin PR #52, giipAgentLinux PR #42)
- **대응책**:
  1. `Invoke-GiipApiV2`/`Invoke-GiipKvsPut` 호출부는 반환값의 `RstVal`을 실제로 확인한 뒤에만
     성공 로그를 남긴다(`$resp -and $resp.RstVal -eq "200"` 패턴 - 이미 `azure-cost-put-win.ps1`
     등 일부 호출부는 이 패턴을 쓰고 있었다).
  2. 실패 시 `lib/Common.ps1`의 `Write-GiipApiFailure` 헬퍼를 쓴다: ERROR 로그 +
     `lib/ErrorLog.ps1`의 `sendErrorLog`(`ErrorLogCreate` SP, 이미 있었지만 어디서도 호출되지
     않던 기존 채널)로 giip 서버에도 보고.
  3. `Invoke-GiipApiV2` 내부 실패 로그는 DEBUG -> WARN/ERROR로 상향했다.
  4. 새 giipfaw 엔드포인트(`agent-log-ingest` 등, 스트림 등록/시퀀스 번호 필요)는 이번 범위에서
     채택하지 않았다 - 기존의 더 가벼운 `ErrorLogCreate` 경로로 충분했다.

## 적용 규칙

- giipAgentWin에 `Invoke-GiipApiV2`/`Invoke-GiipKvsPut`를 호출하는 새 코드를 추가할 때 → 반드시
  반환값의 `RstVal`을 확인하고, 실패 시 `Write-GiipApiFailure`를 호출한다.
- giipAgentLinux의 `kvs_put()`도 같은 계약(0=성공, 비0=실패, 자체적으로 stderr에 상세 로그)이다 -
  호출부에서 종료 코드를 확인하고 실패 시 `log_error()`(`lib/common.sh`)로 보고한다. giipAgentLinux
  쪽 잔여 호출부(99건 중 2건만 이번에 수정) 전수 점검은
  https://giip.littleworld.net/ko/admin/giip-issues/3081 참고.
- 참조: `docs/SPEC_AND_CHECKLIST.md` 섹션 7 (giipAgentWin), `MAINTENANCE_PRECAUTIONS.md` 섹션 6
  (giipAgentLinux).
