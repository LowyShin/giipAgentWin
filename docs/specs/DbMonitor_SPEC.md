# DbMonitor Module Specification

## 1. 개요 (Overview)
**모듈명**: `DbMonitor.ps1`
**목적**: Agent가 관리 대상 데이터베이스(Managed Database)에 주기적으로 접속하여 **성능 지표(Performance Metrics)**를 수집하고 서버로 전송합니다.
**실행 주기**: `giipAgent3.ps1`에 의해 주기적 실행 (기본 5분)

## 2. 입출력 사양 (I/O Specs)

### 2.1. 입력 (Input)
- **설정 파일**: `giipAgent.cfg`
    - `lssn`: Gateway 서버 식별자
    - `sk`: 보안 토큰
    - `apiaddrv2`: API 엔드포인트
- **API**: `ManagedDatabaseListForAgent`
    - Gateway(LSSN)에 할당된 모니터링 대상 DB 목록 반환.

### 2.2. 출력 (Output)
- **API**: `MdbStatsUpdate`
- **Payload (JSON)**:
    ```json
    [
        {
            "mdb_id": 101,
            "uptime": 12345,
            "threads": 15,    // 현재 연결된 세션 수
            "qps": 50.5,      // 초당 쿼리 수
            "buffer_pool": 85.5, // 메모리 버퍼 사용률 (%)
            "cpu": 12.5,      // (Optional) DB 프로세스 CPU 사용률
            "memory": 2048    // (Optional) DB 메모리 사용량 (MB)
        }
    ]
    ```

## 3. 상세 처리 로직 (Processing Logic)

### 3.1. DB 목록 조회
- `Invoke-GiipApiV2`를 사용하여 `ManagedDatabaseListForAgent` 호출.
- `lssn` 파라미터를 사용해 해당 Gateway가 담당하는 DB만 필터링.

### 3.2. 성능 지표 수집 (Collection)
각 DB 타입별로 접속하여 다음 쿼리를 수행합니다.

#### A. MSSQL
`.NET System.Data.SqlClient` 사용.
- **Threads (User Connections)**:
    ```sql
    SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'User Connections'
    ```
- **QPS (Batch Requests/sec)**:
    ```sql
    SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Batch Requests/sec'
    ```
- **Memory**:
    ```sql
    SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Total Server Memory (KB)'
    ```
- **Uptime**:
    ```sql
    SELECT sqlserver_start_time FROM sys.dm_os_sys_info
    ```

#### B. MySQL / MariaDB
`MySql.Data.dll` (Agent lib 폴더 내) 사용.
- `SHOW GLOBAL STATUS` 쿼리 사용.
    - `Threads_connected`
    - `Questions` (QPS 계산용)
    - `Innodb_buffer_pool_pages_total` / `free` (버퍼풀 사용률)
    - `Uptime`

### 3.3. 데이터 전송
- 수집된 통계 리스트(`$statsList`)를 JSON으로 직렬화.
- `MdbStatsUpdate` API 호출하여 일괄 전송.
