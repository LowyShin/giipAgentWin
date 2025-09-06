<#
.SYNOPSIS
  Azure SQL Server 연결 현황 및 부하, 쿼리 요청 정보를 수집하여 KVS에 업로드
.DESCRIPTION
  - 현재 머신(호스트명)에서 연결된 Azure SQL Server의 부하(세션/CPU/메모리 등)와
    연결된 각 클라이언트(머신)별로 최근 쿼리 요청 내역을 수집
  - 결과를 JSON으로 변환하여 giipAgent.cfg 기반 KVS로 업로드
.PARAMETER SqlConnectionString
  Azure SQL Server 연결 문자열
.PARAMETER KFactor
  KVS 업로드 시 factor 값(기본값: 'sqlnetinv')
.EXAMPLE
  .\Collect-SqlNetInventory.ps1 -SqlConnectionString "Server=...;User Id=...;Password=...;..."
.NOTES
  - giipAgent.cfg에서 KVSConfig를 읽어옴
  - PowerShell 7+ 필요 (SqlClient 사용)
#>
[CmdletBinding()]
param(
  [string]$SqlConnectionString,
  [string]$KFactor = 'sqlnetinv'
)

# KVSConfig 및 SqlConnectionString 로드 (giipAgent.cfg)
$KVSConfig = @{}
$cfgPath = Join-Path $PSScriptRoot '..\..\giipAgent.cfg'
if (Test-Path -LiteralPath $cfgPath) {
  $lines = Get-Content -LiteralPath $cfgPath -Raw
  foreach ($line in ($lines -split "\r?\n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith("'")) { continue }
    $m = [regex]::Match($line, '^(?<k>\w+)\s*=\s*(?<v>.+)$', 'IgnoreCase')
    if ($m.Success) {
      $k = $m.Groups['k'].Value.Trim()
      $v = $m.Groups['v'].Value.Trim().Trim('"')
      $KVSConfig[$k] = $v
    }
  }
  if (-not $SqlConnectionString -and $KVSConfig['SqlConnectionString']) {
    $SqlConnectionString = $KVSConfig['SqlConnectionString']
  }
}
if (-not $SqlConnectionString) {
  Write-Host "[ERROR] SqlConnectionString 파라미터 또는 giipAgent.cfg에 SqlConnectionString 항목이 필요합니다."; exit 2
}

# 호스트명
$hostName = $env:COMPUTERNAME

# MySQL 프로세스/세션/쿼리 정보 쿼리

$query = @"
SELECT
  t.PROCESSLIST_ID AS id,
  t.PROCESSLIST_USER AS login_name,
  t.PROCESSLIST_HOST AS host_name,
  t.PROCESSLIST_DB AS db,
  t.PROCESSLIST_COMMAND AS command,
  t.PROCESSLIST_TIME AS cpu_time,
  t.PROCESSLIST_STATE AS status,
  t.PROCESSLIST_INFO AS query_text,
  es.TIMER_START,
  es.TIMER_END,
  es.SQL_TEXT
FROM performance_schema.threads t
LEFT JOIN performance_schema.events_statements_current es
  ON t.THREAD_ID = es.THREAD_ID
WHERE t.PROCESSLIST_USER IS NOT NULL
"@

# MySQL 연결 및 쿼리 실행 (MySql.Data 사용)
try {
  Add-Type -Path "C:\Program Files\MySQL\MySQL Connector Net 8.0.33\Assemblies\v4\MySql.Data.dll"
} catch {
  Write-Host "[ERROR] MySql.Data.dll 로드 실패. MySQL Connector/NET 설치 필요."; exit 1 }

$conn = New-Object MySql.Data.MySqlClient.MySqlConnection($SqlConnectionString)
try {
  $conn.Open()
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $query
  $reader = $cmd.ExecuteReader()
  $results = @()
  while ($reader.Read()) {
    $results += [PSCustomObject]@{
      host_name   = $reader["host_name"]
      login_name  = $reader["login_name"]
      command     = $reader["command"]
      cpu_time    = $reader["cpu_time"]
      status      = $reader["status"]
      query_text  = $reader["query_text"]
    }
  }
  $reader.Close()
  $conn.Close()
} catch {
  Write-Host "[ERROR] MySQL 쿼리 실행 실패: $($_.Exception.Message)"; exit 2 }

# 집계: 호스트별 연결/부하/쿼리
$grouped = $results | Group-Object host_name | ForEach-Object {
  [PSCustomObject]@{
    host_name = $_.Name
    sessions = $_.Group.Count
    queries  = $_.Group | Select-Object login_name, status, cpu_time, reads, writes, logical_reads, start_time, command, query_text
  }
}

# 전체 부하 요약
$summary = [PSCustomObject]@{
  collected_at = (Get-Date).ToString('s')
  collector_host = $hostName
  sql_server = $KVSConfig['Endpoint']
  hosts = $grouped
}

$json = $summary | ConvertTo-Json -Depth 5 -Compress

# --- Diagnostic output for what was collected ---
Write-Host "[DIAG] SQL rows fetched: $($results.Count)"
if ($results.Count -gt 0) {
  Write-Host "[DIAG] Sample row (first):"
  $results | Select-Object -First 1 | Format-List | ForEach-Object { Write-Host "  $_" }
}
Write-Host "[DIAG] Grouped hosts: $($grouped.Count)"
Write-Host "[DIAG] JSON size (chars): $($json.Length)"
Write-Host "[DIAG] JSON preview: $($json.Substring(0, [Math]::Min(400, $json.Length)))"

# KVS 업로드 (show endpoint and payload)
if ($KVSConfig['Enabled'] -eq 'true') {
  # Build apirule.md compliant request: text + jsondata
  $kvspText = "KVSPut $($KVSConfig['KType']) $($KVSConfig['KKey']) $KFactor"
  $kvspJsonObj = @{ kType = $KVSConfig['KType']; kKey = $KVSConfig['KKey']; kFactor = $KFactor; value = $summary }
  $kvspJson = $kvspJsonObj | ConvertTo-Json -Depth 8 -Compress

  $postParams = [ordered]@{
    text     = $kvspText
    token    = $KVSConfig['UserToken']
    jsondata = $kvspJson
  }
  $bodyStr = ($postParams.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, [System.Uri]::EscapeDataString($_.Value) }) -join '&'
  $endpoint = $KVSConfig['Endpoint']
  if ($KVSConfig['FunctionCode']) { $endpoint += "?code=$($KVSConfig['FunctionCode'])" }

  Write-Host "[DIAG] KVS Endpoint: $endpoint"
  Write-Host "[DIAG] KVS text: $kvspText"
  Write-Host "[DIAG] KVS jsondata preview: $($kvspJson.Substring(0,[Math]::Min(400,$kvspJson.Length)))"

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $endpoint -Body $bodyStr -ContentType 'application/x-www-form-urlencoded'
    Write-Host "[INFO] KVS 업로드 결과: $resp"
  } catch {
    Write-Host "[ERROR] KVS 업로드 실패: $($_.Exception.Message)"
    Write-Host "[ERROR] Full request body length: $($bodyStr.Length)"
  }
} else {
  Write-Host "[INFO] KVS 업로드 비활성화. 결과 JSON:"
  Write-Host $json
}
