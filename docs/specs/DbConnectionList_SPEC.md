# DbConnectionList Module Specification

## 1. 개요 (Overview)
**모듈명**: `DbConnectionList.ps1`
**목적**: Agent가 관리 대상 데이터베이스(Managed Database)에 접속하여 **현재 활성 클라이언트 연결 정보(Active Client Connections)**를 IP 단위로 수집합니다. 이는 **Net3D 네트워크 토폴로지 시각화**에 사용됩니다.
**실행 주기**: `giipAgent3.ps1`에 의해 주기적 실행 (기본 5분, DbMonitor 후행)

## 2. 입출력 사양 (I/O Specs)

### 2.1. 입력 (Input)
- **설정 파일**: `giipAgent.cfg`
- **API**: `ManagedDatabaseListForAgent` (DB 목록 조회)

### 2.2. 출력 (Output)
- **API**: `MdbStatsUpdate` (성능 지표 API 재사용)
- **Payload (JSON)**:
    ```json
    [
        {
            "mdb_id": 101,
            "db_connections": "[{\"client_net_address\":\"192.168.1.50\",\"program_name\":\"MyApp\",\"conn_count\":5}, ...]" 
        }
    ]
    ```
    - `db_connections`: JSON 문자열 형태 (Nested JSON String). 백엔드에서 `OPENJSON`으로 파싱하여 저장.

## 3. 상세 처리 로직 (Processing Logic)

### 3.1. DB 목록 조회
- `DbMonitor.ps1`과 동일하게 `ManagedDatabaseListForAgent` 호출.

### 3.2. 연결 정보 수집 (Collection)

#### A. MSSQL (Target)
- `.NET System.Data.SqlClient` 사용.
- **필수 뷰**: `sys.dm_exec_sessions`, `sys.dm_exec_connections`
- **수집 쿼리**:
    ```sql
    SELECT 
        client_net_address,
        program_name,
        COUNT(*) as conn_count
    FROM sys.dm_exec_sessions s
    JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
    GROUP BY client_net_address, program_name
    ```
    - **호환성**: `FOR JSON PATH`를 사용하지 않고 일반 `SELECT`로 조회 후 PowerShell에서 JSON 직렬화 수행 (SQL Server 2008+ 호환).

#### B. MySQL (Planned)
- `information_schema.processlist` 조회 예정 (현재 미구현).

### 3.3. 데이터 전송
- 수집된 객체를 리스트(`$statsList`)에 담아 `MdbStatsUpdate` API로 전송.
- 백엔드 SP(`pApiKVSPutbySk`)는 이 데이터를 받아 `tKVS` 테이블에 `kType='database'`, `kFactor='db_connections'`로 저장함.
