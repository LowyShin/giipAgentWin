> **📅 문서 메타데이터**
> - **작성일**: 2025-12-17
> - **작성자**: AI Agent
> - **상태**: Draft (Implementation Guide Included)
> - **대상**: Agent Developers (Windows/Linux)

# Agent Data Collection Specification

## 1. 개요 (Overview)
본 문서는 GIIP Agent가 수집하여 서버로 전송해야 할 데이터의 표준 규격 및 형식을 정의한다.
이 규격은 Linux, Windows 등 OS 환경과 MySQL, SQL Server 등 DB 종류에 상관없이 공통적으로 적용되어야 한다.

---

## 2. 공통 프로토콜 (Common Protocol)
*   **Method**: HTTP POST
*   **Format**: JSON
*   **Authentication**: Secret Key (`sk` or `token`) in Header or Body.

---

## 3. Database Agent (DB 성능 수집)
DB 에이전트는 주기적으로(예: 5분) DB의 성능 지표와 활성 연결 정보를 수집하여 전송해야 한다.

### 3.1 API Endpoint
*   **SP**: `pApiMdbStatsUpdatebySK`
*   **Key Type**: `database` (MDB ID)

### 3.2 Payload Schema (JSON)
단일 객체 형태로 전송한다.

```json
{
  "mdb_id": 101,                  // Managed Database ID (Required)
  "uptime": 123456,               // DB 가동 시간 (초)
  "threads": 15,                  // 현재 연결된 세션/스레드 수
  "qps": 500.5,                   // 초당 쿼리 수 (Queries Per Second) 또는 누적 쿼리 수
  "buffer_pool": 85.5,            // 버퍼 풀 사용률 (%)
  "cpu": 45.2,                    // DB 프로세스 CPU 사용률 (%)
  "memory": 2048,                 // DB 프로세스 메모리 사용량 (MB)
  "db_connections": [             // 활성 연결 상세 리스트 (Stringified JSON or Array)
    {
      "client_net_address": "192.168.1.50", // 클라이언트 IP
      "program_name": "MyApp.exe",          // 접속 프로그램명
      "last_sql": "SELECT * FROM ...",      // (Optional) 마지막 실행 SQL
      "conn_count": 1,                      // 해당 클라이언트에서의 연결 수
      "cpu_load": 0                         // (Optional) 해당 세션의 CPU 부하
    }
  ]
}
```

### 3.3 Metric Definitions
*   **qps**: 누적 쿼리 수(Total Queries)로 보낼 경우, 서버 측에서 상태 판별(Critical 여부) 시 제외될 수 있음. 가급적 순간 QPS(Rate)로 계산하여 전송 권장.
*   **high_load detection**: 서버는 `cpu >= 80%` 또는 `threads >= 50`일 경우 'critical' 상태로 기록함.

### 3.4. SQL Server Implementation Guide (Windows)
Windows (PowerShell) 에이전트는 복잡한 성능 쿼리를 직접 수행하는 대신, DB에 사전 배포된 **`pAgentMdbPerfCollect`** 저장 프로시저를 호출하여 표준화된 JSON을 수집해야 한다.

#### 3.4.1. 수집 스크립트: `dpa-put-mssql-perf.ps1`
*   **역할**: `pAgentMdbPerfCollect` 실행 -> `MdbStatsUpdate` API 전송
*   **필수 파라미터**: `SqlConnectionString`, `MdbId`
*   **실행 예시**:
    ```powershell
    .\giipscripts\dpa-put-mssql-perf.ps1 -SqlConnectionString "Server=...;" -MdbId 101
    ```

#### 3.4.2. `pAgentMdbPerfCollect` SP 로직 (Backend)
*   **QPS (Real-time)**: `Batch Requests/sec` 카운터를 1초 간격으로 샘플링하여 차분 계산. (누적값 오차 해결)
*   **Metrics**: `uptime`, `threads`(active), `buffer_pool`, `cpu`, `memory` 자동 수집.
*   **출력**: `AGENT_DATA_SPEC` 3.2절에 정의된 표준 JSON 포맷 반환.

---

## 4. Server Agent (OS/Network 수집)
서버 에이전트는 네트워크 연결 상태(`netstat`)를 수집하여 KVS에 저장한다.

### 4.1 API Endpoint
*   **SP**: `pApiKVSPutbySk`
*   **kType**: `lssn` (Server ID)
*   **kFactor**: `netstat`

### 4.2 Payload Schema (JSON)
`kValue` 필드에 아래 JSON 배열을 문자열로 변환하여 전송한다.

```json
[
  {
    "pid": 1234,
    "process_name": "nginx",
    "local_ip": "192.168.1.10",
    "local_port": 80,
    "remote_ip": "203.0.113.5",
    "remote_port": 54321,
    "state": "ESTABLISHED",
    "traffic": 1024            // (Optional) 트래픽 양 (Bytes)
  },
  ...
]
```

### 4.3 Data Handling
*   **Filtering**: `ESTABLISHED`, `LISTEN` 등 유의미한 상태의 연결만 수집 권장.
*   **Loopback**: `127.0.0.1` 연결은 상황에 따라 필터링 가능하나, 로컬 통신 분석이 필요하면 포함한다.

---

## 5. 데이터 이력화 (Data History)
*   **DB Agent**: `pApiMdbStatsUpdatebySK` 호출 시, 서버는 자동으로 `tManagedDatabase`(Live)를 갱신하고 `tKVS`(`status_log`)에 이력을 저장한다. 따라서 에이전트는 별도로 이력 저장 API를 호출할 필요가 없다.
*   **Server Agent**: `netstat` 데이터는 `tKVS`에 매번 새로운 레코드로 쌓이므로 자동으로 이력화된다. (단, 과도한 데이터 축적 방지를 위해 주기적 삭제 정책이 적용될 수 있음)
