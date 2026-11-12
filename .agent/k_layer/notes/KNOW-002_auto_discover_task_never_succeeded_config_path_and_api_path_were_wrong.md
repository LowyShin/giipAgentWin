# KNOW-002: Auto-Discovery 태스크가 한 번도 성공하지 못한 원인 (설정 파일 탐색 위치 + API 호출 경로)

> 등록: 2026-11-13 | source: giip 3559 (CSN 47)
> 원본: 2026-11-13 01:14~01:52 KST 사망 세션의 잔여물(auto-unblock stash) 복구분
> 수정 커밋: `6457818` (giipAgentWin `bot/task-giip-3559` 브랜치, `fix(auto-discover): 3559 dead-session residue recovery`)

## CLAIM-002

- **주장 1 (설정 파일 탐색 위치)**: `giip-auto-discover.ps1` 은 `giipAgent.cfg` 를
  **저장소 루트만** 찾아 "Configuration file not found" 로 종료했다. 정본은 저장소
  **상위 폴더 → `%USERPROFILE%` → 저장소 루트** 순으로 탐색하는
  `lib/Common.ps1:Get-GiipConfig` 다. 종료 지점이 첫 로그 기록보다 앞이어서
  **로그 파일조차 남지 않았다**(Task Scheduler 의 "return code 0" 은 conhost.exe 의
  exit code 라서 성공으로 오인된다).
- **주장 2 (API 호출 경로)**: 예전 코드는 cfg 에 **없는 키(`apiaddr`)** 와 dispatcher 가
  읽지 않는 쿼리 파라미터(`cmd=`)로 AK 기반 `giipApi` 를 불렀다. 표준 경로는
  `Invoke-GiipApiV2 -CommandText "AgentAutoRegister hostname jsondata"`(엔드포인트는 cfg 의
  `apiaddrv2`, SK 인증)이고 실제 값은 `jsondata` 에서 치환된다.
  → 두 결함 모두 2026-11-13 전까지 **태스크가 한 번도 성공하지 못한** 원인이다.
- **주장 3 (서버 SP 필수 키)**: 서버 SP `giipdb/SP/pApiAgentAutoRegisterBySK.sql` 는
  `$.os`, `$.cpu`, `$.cpu_cores`, `$.memory_gb`, `$.disk_gb`, `$.agent_version`,
  `$.ipv4_global`, `$.ipv4_local` 8개 키만 읽는다. Windows 수집기
  (`giipscripts/auto-discover-win.ps1`)는 그중 **`cpu_cores`·`disk_gb`·`ipv4_global`·
  `ipv4_local` 4개를 내보내지 않아** heartbeat UPDATE 가 `LSSpecCPUs`·`LSSpecDiskSizeGB`·
  `LSNIFLocal` 을 NULL 로 덮어썼다. `LSNIFGlobal` 은 `COALESCE(NULLIF(@ipv4_global,''),
  LSNIFGlobal)` 이라 빈 값이면 마지막 알려진 값이 유지된다.
- **관측**: giip 2426 이 "Windows 는 auto-discover 태스크가 등록된 적 없다" 라고 적은 것은
  **태스크 등록** 층위의 문제였고, 등록돼 있어도 **성공한 적 없음**이 giip 3559 에서 확인됐다.
  두 층위를 구분하지 않으면 "등록만 하면 된다" 는 잘못된 결론으로 끝난다.
- **대응책**:
  1. `giip-auto-discover.ps1` — 저장소 표준 로더(`Get-GiipConfig`) + 표준 API 경로
     (`Invoke-GiipApiV2`)로 교체. 실패도 **로그를 남긴 뒤** 종료한다.
  2. `giipscripts/auto-discover-win.ps1` — SP 필수 키 4종 추가: `cpu_cores`=논리 CPU 수,
     `disk_gb`=시스템 볼륨 전체 GB, `ipv4_global`=공인 IPv4, `ipv4_local`=사설 IPv4.
     Linux(`giipAgentLinux/scripts/auto-discover-linux.sh`)와 판정 기준을 같게 했다.
  3. **재발 방지**: SP 가 읽는 키 목록을 `docs/SPEC_AND_CHECKLIST.md` §3 표로 고정했다.
     키를 추가/이름을 바꾸려면 **그 SP 와 수집기·사양표를 함께** 고쳐야 한다.
     NAT 된 PC 는 공인 IP 가 없으므로 `ipv4_global` 이 빈 값인 것은 정상이다(외부 echo 조회 금지).

## 적용 규칙

- 서버에 데이터를 보내는 수집 스크립트를 만들면 **수신 SP 가 읽는 키 목록을 먼저 확인**하고
  그 키를 빠짐없이 채운다. 키 누락 = 서버 UPDATE 가 NULL 로 덮어쓰기(조용한 데이터 손실).
- 설정 파일 위치·API 호출 경로는 **저장소 표준 헬퍼**(`Get-GiipConfig`/`Invoke-GiipApiV2`)를 쓴다.
  자체 구현으로 탐색/호출하면 조용히 실패한다.
- 실패 경로에서도 **로그를 먼저 남기고** 종료한다. 로그 없는 종료는 원인 파악을 막는다.
- 참조: `docs/SPEC_AND_CHECKLIST.md` §3, `docs/SPEC_UNCALLED_PATHS.md` §5(g), giip 3559.
