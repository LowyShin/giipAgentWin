# Configuration & Script Migration Report (giipAgentWin)

> **⚠️ CRITICAL**: The `giipAgent.cfg` format has been standardized. All scripts MUST be updated to read the new format and use the correct API V2 endpoints.

## 1. Config File Standard (New)
The new configuration file (`giipAgent.cfg`) uses the following keys:

| Key | Old Equivalent | Description |
|-----|----------------|-------------|
| `sk` | `at` | Security Token / Secret Key |
| `lssn` | `lsSn` | Logical Server Serial Number |
| `apiaddrv2` | N/A (Hardcoded) | V2 API Endpoint URL |
| `giipagentdelay` | N/A | Polling Loop Delay (seconds) |

**Format**: `Key = "Value"` (with spaces around `=`).
**Forbidden**: Do NOT use `SqlConnectionString` or direct DB params.

---

## 2. Required Updates in `giipAgentWin.ps1`

### 2.1. Config Reading
- **Current**: Reads `at` and `lsSn`.
- ** Required**: Must read `sk` and `lssn`.
- **Action**: Update `Read-Cfg` logic to map `sk` -> `$Config.sk`.

### 2.2. API URL & Authentication
- **Current**: Hardcoded ASP URLs (`https://giipasp.../cqequeueget04.asp?sk=...`).
- **Required**: Use `apiaddrv2` from config.
- **Action**:
  - Remove `$API_QUEUE_URL_TEMPLATE`.
  - Implement `Invoke-GiipApiV2` using `apiaddrv2`.
  - **Security Fix**: STOP sending `sk` in the URL query string. Send `token` in the POST body.

### 2.3. Payload Formatting
- **Current**: Query string parameters.
- **Required**:
    - `token`: `$Config.sk`
    - `text`: "CommandName Param1 Param2"
    - `jsondata`: JSON String

---

## 3. Required Updates in `giip-auto-discover.ps1`

### 3.1. Config Parsing Regex
- **Current**: `^(\w+)="([^"]*)"` (Fails if spaces exist around `=`).
- **Required**: `^\s*(\w+)\s*=\s*"([^"]*)"` (Handles `sk = "value"`).

### 3.2. API Endpoint
- **Current**: `$apiaddr` (often missing or defaults to legacy).
- **Required**: Use `apiaddrv2` if available.
- **Action**: Ensure `AgentAutoRegister` command is compatible with V2, or route it correctly via the standard gateway.

---

## 4. Extracting Unused/Missing Data
The User requested documentation for data that cannot be extracted or is missing in the new config but present in old scripts.

| Script | Missing Data | Action |
|--------|--------------|--------|
| `giipAgentWin.ps1` | `API_KVS_URL_TEMPLATE` | Legacy KVS PUT URL. Must be replaced by `KVSPut` command via V2 API. |
| `giipAgentWin.ps1` | `RESULT_SNIPPET_LEN` | Not in config. Keep as internal constant (500 chars). |
| `giip-auto-discover` | `apiaddr` | Old V1 address. Replace utilization with `apiaddrv2`. |

---

## 5. Development Checklist
- [ ] regex in `giip-auto-discover.ps1` is fixed.
- [ ] `giipAgentWin.ps1` uses `apiaddrv2`.
- [ ] `at` variable renmaed to `sk` in all scripts.
- [ ] No DB connection strings are used/required.
