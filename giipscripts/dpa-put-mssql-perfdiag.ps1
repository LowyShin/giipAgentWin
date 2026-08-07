<#
.SYNOPSIS
  MSSQL Query Store 회귀쿼리/대기유형 + Azure SQL(PaaS) Monitor 지표를 수집해 KVS(kFactor=db_perf_diag)에 저장.
.DESCRIPTION
  giipAgentLinux PR #22(giip-issue #921)의 lib/db_perf_diag_mssql.sh + lib/azure_sql_metrics.sh +
  lib/build_perf_diagnosis.py를 PowerShell로 이식한 것. Linux 에이전트와 완전히 같은 tKVS 좌표
  (kType=database, kKey=<mdb_id>, kFactor=db_perf_diag)에 쓰므로, giipv3의
  BubbleDbDiagnostics.tsx(giipv3 PR #388)가 Windows/Linux 어느 쪽이 수집했든 동일하게 표시한다
  — 프론트엔드 추가 수정 불필요.
  Query Store는 상태(actual_state_desc) 확인 후 READ_WRITE/READ_ONLY일 때만 조회하고,
  절대 자동으로 켜지 않는다(고객 DB 설정 변경 금지).
  Azure Monitor 파트는 db_host가 *.database.windows.net 일 때만 동작하며, 인증은
  giipscripts/azure-cost-put-win.ps1과 동일한 서비스 프린시펄 패턴(giipAgent.cfg의
  az_client_id/az_client_secret/az_tenant_id, 없으면 기존 az login 세션)을 재사용한다.
  giipdb 스키마/SP 변경 없음 — 이 기능 전체의 설계 원칙.
.PARAMETER SqlConnectionString
  대상 MSSQL/Azure SQL 접속 문자열(giipAgent.cfg의 SqlConnectionString으로도 지정 가능).
.PARAMETER MdbId
  giip Managed Database ID(giipAgent.cfg의 MdbId로도 지정 가능).
.EXAMPLE
  .\dpa-put-mssql-perfdiag.ps1 -SqlConnectionString "Server=xxx.database.windows.net;Initial Catalog=mydb;..." -MdbId 101
.NOTES
  dpa-put-mssql-perf.ps1(기존 QPS/CPU/Threads 수집, pAgentMdbPerfCollect 경유)은 건드리지 않는다 —
  이 스크립트는 그 옆에 나란히 동작하는 별도 진단 채널이다.
#>
[CmdletBinding()]
param(
  [string]$SqlConnectionString,
  [int]$MdbId
)

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path $ScriptDir -Parent   # giipscripts -> giipAgentWin
$LibDir    = Join-Path $AgentRoot "lib"
$Global:BaseDir = $AgentRoot                       # so Get-GiipConfig finds ../giipAgent.cfg

. (Join-Path $LibDir "Common.ps1")   # Get-GiipConfig, Invoke-GiipApiV2, Write-GiipLog
. (Join-Path $LibDir "Kvs.ps1")      # Invoke-GiipKvsPut

$Config = Get-GiipConfig
if (-not $SqlConnectionString -and $Config['sqlconnectionstring']) { $SqlConnectionString = $Config['sqlconnectionstring'] }
if (-not $MdbId -and $Config['mdbid']) { $MdbId = [int]$Config['mdbid'] }

if (-not $SqlConnectionString -or -not $MdbId) {
  Write-GiipLog "ERROR" "SqlConnectionString and MdbId are required (param or giipAgent.cfg)."
  exit 2
}

try {
  Import-Module SqlServer -ErrorAction Stop
} catch {
  Write-GiipLog "ERROR" "SqlServer module not available. Install-Module SqlServer -Scope CurrentUser."
  exit 1
}

# --- Extract host/database from the connection string for the Azure Monitor resource ID ---
function Get-ConnStringField {
  param([string]$ConnStr, [string[]]$Keys)
  foreach ($k in $Keys) {
    $m = [regex]::Match($ConnStr, "(?:^|;)\s*$k\s*=\s*([^;]+)", 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
  }
  return $null
}
$dbHost = Get-ConnStringField -ConnStr $SqlConnectionString -Keys @('Server', 'Data Source')
if ($dbHost) { $dbHost = ($dbHost -replace '^tcp:', '') -replace ',\d+$', '' }
$dbDatabase = Get-ConnStringField -ConnStr $SqlConnectionString -Keys @('Initial Catalog', 'Database')

# ================================================================
# 1. Query Store diagnostics (READ-ONLY — mirrors db_perf_diag_mssql.sh)
# ================================================================
function Get-MssqlPerfDiag {
  param([string]$ConnStr)

  $result = [ordered]@{
    query_store_status = "NOT_AVAILABLE"
    regressions        = @()
    wait_stats         = @()
    real_cpu_percent   = $null
  }

  try {
    $qsRow = Invoke-Sqlcmd -ConnectionString $ConnStr -Query "SET NOCOUNT ON; SELECT ISNULL(actual_state_desc,'NOT_AVAILABLE') AS s FROM sys.database_query_store_options;" -ErrorAction Stop
    if ($qsRow -and $qsRow.s) { $result.query_store_status = [string]$qsRow.s }
  } catch {
    $result.query_store_status = "error"
  }

  if ($result.query_store_status -in @('READ_WRITE', 'READ_ONLY')) {
    $regressQuery = @"
SET NOCOUNT ON;
;WITH recent AS (
    SELECT rs.query_id, AVG(rs.avg_duration) AS avg_dur_recent, SUM(rs.count_executions) AS exec_recent
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(MINUTE, -30, GETUTCDATE())
    GROUP BY rs.query_id
),
baseline AS (
    SELECT rs.query_id, AVG(rs.avg_duration) AS avg_dur_baseline
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(HOUR, -25, GETUTCDATE()) AND rsi.start_time < DATEADD(MINUTE, -30, GETUTCDATE())
    GROUP BY rs.query_id
)
SELECT TOP 5
    r.query_id,
    CAST(r.avg_dur_recent AS BIGINT) AS avg_dur_recent_us,
    CAST(ISNULL(b.avg_dur_baseline,0) AS BIGINT) AS avg_dur_baseline_us,
    r.exec_recent AS exec_count,
    ISNULL(SUBSTRING(qt.query_sql_text, 1, 500), '') AS query_text
FROM recent r
LEFT JOIN baseline b ON r.query_id = b.query_id
JOIN sys.query_store_query q ON r.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE r.avg_dur_recent > 100000
  AND r.avg_dur_recent > ISNULL(b.avg_dur_baseline,0) * 2
ORDER BY r.avg_dur_recent DESC;
"@
    try {
      $rows = @(Invoke-Sqlcmd -ConnectionString $ConnStr -Query $regressQuery -ErrorAction Stop)
      $result.regressions = @($rows | ForEach-Object {
          [ordered]@{
            query_id            = [int]$_.query_id
            avg_dur_recent_ms   = [math]::Round([double]$_.avg_dur_recent_us / 1000.0, 1)
            avg_dur_baseline_ms = [math]::Round([double]$_.avg_dur_baseline_us / 1000.0, 1)
            exec_count          = [int]$_.exec_count
            query_text          = [string]$_.query_text
          }
        })
    } catch {
      Write-GiipLog "WARN" "Query Store regression query failed: $($_.Exception.Message)"
    }

    $waitQuery = @"
SET NOCOUNT ON;
SELECT TOP 5
    ws.wait_category_desc,
    CAST(SUM(ws.total_query_wait_time_ms) AS BIGINT) AS total_wait_ms
FROM sys.query_store_wait_stats ws
JOIN sys.query_store_runtime_stats_interval rsi ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(MINUTE, -30, GETUTCDATE())
GROUP BY ws.wait_category_desc
ORDER BY total_wait_ms DESC;
"@
    try {
      $rows = @(Invoke-Sqlcmd -ConnectionString $ConnStr -Query $waitQuery -ErrorAction Stop)
      $result.wait_stats = @($rows | ForEach-Object {
          [ordered]@{ wait_category = [string]$_.wait_category_desc; total_wait_ms = [int64]$_.total_wait_ms }
        })
    } catch {
      Write-GiipLog "WARN" "Query Store wait-stats query failed: $($_.Exception.Message)"
    }
  }

  $cpuQuery = @"
SET NOCOUNT ON;
SELECT TOP 1 CAST(SQLProcessUtilization AS INT) AS cpu
FROM (
    SELECT
        record.value('(./Record/@id)[1]', 'int') AS record_id,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQLProcessUtilization
    FROM (
        SELECT CONVERT(xml, record) AS record
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
        AND record LIKE '%<SystemHealth>%'
    ) AS x
) AS y
ORDER BY record_id DESC;
"@
  try {
    $cpuRow = Invoke-Sqlcmd -ConnectionString $ConnStr -Query $cpuQuery -ErrorAction Stop
    if ($cpuRow -and $null -ne $cpuRow.cpu) { $result.real_cpu_percent = [int]$cpuRow.cpu }
  } catch {
    Write-GiipLog "WARN" "Ring-buffer CPU% query failed: $($_.Exception.Message)"
  }

  return $result
}

# ================================================================
# 2. Azure SQL (PaaS) Monitor metrics — mirrors azure_sql_metrics.sh,
#    reuses the auth pattern from azure-cost-put-win.ps1 (same repo, same cfg keys).
# ================================================================
function Get-AzureSqlMetrics {
  param([string]$DbHost, [string]$DbDatabase, [hashtable]$Config)

  if (-not $DbHost -or $DbHost -notlike "*.database.windows.net") {
    return [ordered]@{ azure_status = "not_applicable" }
  }
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    return [ordered]@{ azure_status = "not_installed" }
  }
  if (-not $DbDatabase) {
    return [ordered]@{ azure_status = "forbidden"; reason = "database_name_not_resolved_from_connection_string" }
  }

  $loggedIn = $false
  az account show --only-show-errors -o none 2>$null
  if ($LASTEXITCODE -eq 0) {
    $loggedIn = $true
  } elseif ($Config['az_client_id'] -and $Config['az_client_secret'] -and $Config['az_tenant_id']) {
    az login --service-principal --username $Config['az_client_id'] --password $Config['az_client_secret'] --tenant $Config['az_tenant_id'] --only-show-errors -o none 2>$null
    if ($LASTEXITCODE -eq 0) { $loggedIn = $true }
  }
  if (-not $loggedIn) { return [ordered]@{ azure_status = "login_required" } }

  if ($Config['az_subscription']) {
    az account set --subscription $Config['az_subscription'] --only-show-errors 2>$null
  }

  $serverName = $DbHost -replace '\.database\.windows\.net$', ''
  $subId = $Config['az_subscription']
  if (-not $subId) { $subId = (az account show --query id -o tsv --only-show-errors 2>$null) }
  if (-not $subId) { return [ordered]@{ azure_status = "forbidden"; reason = "subscription_not_resolved" } }

  # Resource group rarely changes for a given server — 24h file cache (same TTL choice as Linux side).
  $rgCacheFile = Join-Path $env:TEMP "giip_azure_rg_cache_$serverName.txt"
  $resourceGroup = $null
  if (Test-Path $rgCacheFile) {
    $age = (Get-Date) - (Get-Item $rgCacheFile).LastWriteTime
    if ($age.TotalHours -lt 24) { $resourceGroup = (Get-Content $rgCacheFile -Raw -ErrorAction SilentlyContinue) }
    if ($resourceGroup) { $resourceGroup = $resourceGroup.Trim() }
  }
  if (-not $resourceGroup) {
    $resourceGroup = az sql server list --query "[?fullyQualifiedDomainName=='$DbHost'].resourceGroup | [0]" -o tsv --only-show-errors 2>$null
    if ($resourceGroup) { Set-Content -Path $rgCacheFile -Value $resourceGroup -NoNewline -ErrorAction SilentlyContinue }
  }
  if (-not $resourceGroup) { return [ordered]@{ azure_status = "forbidden"; reason = "resource_group_not_found" } }

  $resourceId = "/subscriptions/$subId/resourceGroups/$resourceGroup/providers/Microsoft.Sql/servers/$serverName/databases/$DbDatabase"
  $metricsJson = az monitor metrics list --resource $resourceId --metric "cpu_percent" "dtu_consumption_percent" "physical_data_read_percent" "log_write_percent" "storage_percent" "workers_percent" "sessions_percent" --interval PT1M --aggregation Average -o json --only-show-errors 2>$null
  if (-not $metricsJson) { return [ordered]@{ azure_status = "forbidden"; reason = "metrics_call_failed" } }

  try {
    $parsed = $metricsJson | ConvertFrom-Json
  } catch {
    return [ordered]@{ azure_status = "forbidden"; reason = "metrics_parse_failed" }
  }

  $metricKeyMap = @{
    'cpu_percent' = 'cpu_percent'; 'dtu_consumption_percent' = 'dtu_consumption_percent'
    'physical_data_read_percent' = 'physical_data_read_percent'; 'log_write_percent' = 'log_write_percent'
    'storage_percent' = 'storage_percent'; 'workers_percent' = 'workers_percent'; 'sessions_percent' = 'sessions_percent'
  }
  $out = [ordered]@{ azure_status = "ok" }
  foreach ($entry in @($parsed.value)) {
    $metricName = $entry.name.value
    if (-not $metricKeyMap.ContainsKey($metricName)) { continue }
    $latestVal = $null; $latestTs = $null
    foreach ($series in @($entry.timeseries)) {
      foreach ($point in @($series.data)) {
        if ($null -eq $point.average) { continue }
        if (-not $latestTs -or $point.timeStamp -gt $latestTs) { $latestTs = $point.timeStamp; $latestVal = $point.average }
      }
    }
    $out[$metricKeyMap[$metricName]] = if ($null -ne $latestVal) { [math]::Round([double]$latestVal, 1) } else { $null }
  }
  return $out
}

# ================================================================
# 3. Rule-based diagnosis — mirrors build_perf_diagnosis.py
#    Priority: storage > resource saturation (DTU/CPU) > blocking > IO bottleneck
#              > query regression > high real CPU > insufficient_data > normal
# ================================================================
function Build-PerfDiagnosis {
  param([System.Collections.Specialized.OrderedDictionary]$Qs, [System.Collections.Specialized.OrderedDictionary]$Az)

  $THRESH_STORAGE = 90; $THRESH_DTU = 90; $THRESH_AZURE_CPU = 90; $THRESH_REAL_CPU = 80
  $evidence = New-Object System.Collections.Generic.List[string]
  $diagnosis = "normal"

  $azureStatus = $Az.azure_status
  $storagePct = $Az.storage_percent
  $dtuPct = $Az.dtu_consumption_percent
  $azureCpu = $Az.cpu_percent
  $realCpu = $Qs.real_cpu_percent
  $waits = @($Qs.wait_stats)
  $regressions = @($Qs.regressions)
  $topWait = if ($waits.Count -gt 0) { $waits[0] } else { $null }

  if ($azureStatus -eq "ok" -and $null -ne $storagePct -and [double]$storagePct -ge $THRESH_STORAGE) {
    $diagnosis = "storage_pressure"
    $evidence.Add("Azure storage_percent=$storagePct% (>= $THRESH_STORAGE%)")
  } elseif ($azureStatus -eq "ok" -and ((($null -ne $dtuPct) -and [double]$dtuPct -ge $THRESH_DTU) -or (($null -ne $azureCpu) -and [double]$azureCpu -ge $THRESH_AZURE_CPU))) {
    $diagnosis = "resource_saturation"
    if ($null -ne $dtuPct -and [double]$dtuPct -ge $THRESH_DTU) { $evidence.Add("Azure dtu_consumption_percent=$dtuPct% (>= $THRESH_DTU%)") }
    if ($null -ne $azureCpu -and [double]$azureCpu -ge $THRESH_AZURE_CPU) { $evidence.Add("Azure cpu_percent=$azureCpu% (>= $THRESH_AZURE_CPU%)") }
  } elseif ($topWait -and ([string]$topWait.wait_category).ToLower() -eq "lock") {
    $diagnosis = "blocking"
    $evidence.Add("Top wait category=Lock, total_wait_ms=$($topWait.total_wait_ms)")
  } elseif ($topWait -and (([string]$topWait.wait_category).ToLower() -replace '[ _]', '') -eq "bufferio" -and ($null -eq $realCpu -or [double]$realCpu -lt 50)) {
    $diagnosis = "io_bottleneck"
    $evidence.Add("Top wait category=$($topWait.wait_category), total_wait_ms=$($topWait.total_wait_ms), real_cpu_percent=$realCpu")
  } elseif ($regressions.Count -gt 0) {
    $diagnosis = "query_regression"
    $topR = $regressions[0]
    $evidence.Add("Query $($topR.query_id) regressed: recent=$($topR.avg_dur_recent_ms)ms vs baseline=$($topR.avg_dur_baseline_ms)ms")
  } elseif ($null -ne $realCpu -and [double]$realCpu -ge $THRESH_REAL_CPU) {
    $diagnosis = "high_cpu"
    $evidence.Add("real_cpu_percent=$realCpu% (>= $THRESH_REAL_CPU%)")
  } elseif ($Qs.query_store_status -notin @('READ_WRITE', 'READ_ONLY') -and $azureStatus -ne "ok") {
    $diagnosis = "insufficient_data"
    $evidence.Add("query_store_status=$($Qs.query_store_status), azure_status=$azureStatus")
  }

  return [ordered]@{
    diagnosis    = $diagnosis
    evidence     = @($evidence)
    query_store  = $Qs
    azure        = $Az
    collected_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  }
}

# ================================================================
# Run
# ================================================================
try {
  Write-GiipLog "INFO" "Collecting MSSQL perf diagnostics (Query Store + Azure) for mdb_id=$MdbId host=$dbHost db=$dbDatabase"
  $qs = Get-MssqlPerfDiag -ConnStr $SqlConnectionString
  $az = Get-AzureSqlMetrics -DbHost $dbHost -DbDatabase $dbDatabase -Config $Config
  $diag = Build-PerfDiagnosis -Qs $qs -Az $az

  Write-GiipLog "INFO" "diagnosis=$($diag.diagnosis) query_store_status=$($qs.query_store_status) azure_status=$($az.azure_status)"

  $resp = Invoke-GiipKvsPut -Config $Config -Type "database" -Key "$MdbId" -Factor "db_perf_diag" -Value $diag
  if ($resp -and ($resp.RstVal -eq "200" -or $resp.RstVal -eq 200)) {
    Write-GiipLog "INFO" "db_perf_diag uploaded successfully (mdb_id=$MdbId)."
    exit 0
  } else {
    $rv = if ($resp) { $resp.RstVal } else { "no-response" }
    Write-GiipLog "ERROR" "KVS put failed (RstVal=$rv) for mdb_id=$MdbId."
    exit 1
  }
} catch {
  Write-GiipLog "ERROR" "Unhandled failure: $($_.Exception.Message)"
  exit 1
}
