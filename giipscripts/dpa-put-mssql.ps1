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
  
  # KType, KKey 기본값 설정
  if (-not $KVSConfig['KType']) {
    $KVSConfig['KType'] = 'lssn'
  }
  if (-not $KVSConfig['KKey'] -and $KVSConfig['lssn']) {
    $KVSConfig['KKey'] = $KVSConfig['lssn']
  }
  if (-not $KVSConfig['UserToken'] -and $KVSConfig['sk']) {
    $KVSConfig['UserToken'] = $KVSConfig['sk']
  }
  if (-not $KVSConfig['Endpoint'] -and $KVSConfig['apiaddrv2']) {
    $KVSConfig['Endpoint'] = $KVSConfig['apiaddrv2']
  }
  if (-not $KVSConfig['FunctionCode'] -and $KVSConfig['apiaddrcode']) {
    $KVSConfig['FunctionCode'] = $KVSConfig['apiaddrcode']
  }
}
if (-not $SqlConnectionString) {
  Write-Host "[ERROR] SqlConnectionString 파라미터 또는 giipAgent.cfg에 SqlConnectionString 항목이 필요합니다."; exit 2
}

# SQL Server에서 세션/부하/쿼리 정보 수집
try {
  Import-Module SqlServer -ErrorAction Stop
}
catch {
  Write-Host "[ERROR] SqlServer 모듈 필요. Install-Module SqlServer -Scope CurrentUser 로 설치하세요."; exit 1 
}

# 호스트명
$hostName = $env:COMPUTERNAME

# 세션/부하/쿼리 정보 쿼리 (예시)

$query = @"
SET NOCOUNT ON;
SELECT
  ISNULL(s.client_net_address, '') AS client_net_address,
  s.host_name,
  s.login_name,
  s.program_name,
  s.status,
  ISNULL(r.cpu_time, 0) AS cpu_load,
  ISNULL(REPLACE(REPLACE(t.text, CHAR(13), ' '), CHAR(10), ' '), '') AS last_sql,
  
  -- Transaction Info
  CASE WHEN trans.session_id IS NOT NULL THEN 1 ELSE 0 END as is_open_tran,
  ISNULL(DATEDIFF(MINUTE, trans.transaction_begin_time, GETDATE()), 0) as tran_duration,
  ISNULL(trans.transaction_state_desc, '') as tran_state

FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
LEFT JOIN (
    SELECT
        st.session_id,
        t.transaction_begin_time,
        CASE t.transaction_state
            WHEN 0 THEN 'Not initialized'
            WHEN 1 THEN 'Initialized'
            WHEN 2 THEN 'Active'
            WHEN 3 THEN 'Ended (Read-Only)'
            WHEN 4 THEN 'Commit initiated'
            WHEN 5 THEN 'Prepared'
            WHEN 6 THEN 'Committed'
            WHEN 7 THEN 'Rolling back'
            WHEN 8 THEN 'Rolled back'
        END AS transaction_state_desc
    FROM sys.dm_tran_active_transactions t
    INNER JOIN sys.dm_tran_session_transactions st ON t.transaction_id = st.transaction_id
) trans ON s.session_id = trans.session_id
WHERE
    s.is_user_process = 1
    AND (s.status = 'running' OR trans.session_id IS NOT NULL)
"@

$results = Invoke-Sqlcmd -ConnectionString $SqlConnectionString -Query $query

# 집계: IP별 연결/부하/쿼리/트랜잭션
$grouped = $results | Group-Object client_net_address | ForEach-Object {
  [PSCustomObject]@{
    client_net_address = $_.Name
    host_name          = if ($_.Group[0].host_name) { $_.Group[0].host_name } else { "" }
    sessions           = $_.Group.Count
    queries            = $_.Group | Select-Object client_net_address, login_name, status, cpu_load, last_sql, is_open_tran, tran_duration, tran_state
  }
}

# 전체 부하 요약
$summary = [PSCustomObject]@{
  collected_at   = (Get-Date).ToString('s')
  collector_host = $hostName
  sql_server     = $KVSConfig['Endpoint']
  hosts          = $grouped
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
  # Build apirule.md compliant request: text에는 파라미터 이름만, jsondata에 실제 값
  # NOTE: kValue는 text에 포함하지 않음 (jsondata 전체로 전달됨)
  $kvspText = "KVSPut kType kKey kFactor"
  
  # jsondata에 모든 값 포함
  $kvspJsonData = @{
    kType   = $KVSConfig['KType']
    kKey    = $KVSConfig['KKey']
    kFactor = $KFactor
    kValue  = $summary
  } | ConvertTo-Json -Depth 8 -Compress

  $postParams = [ordered]@{
    text     = $kvspText
    token    = $KVSConfig['UserToken']
    jsondata = $kvspJsonData
  }
  $bodyStr = ($postParams.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, [System.Uri]::EscapeDataString($_.Value) }) -join '&'
  $endpoint = $KVSConfig['Endpoint']
  if ($KVSConfig['FunctionCode']) { $endpoint += "?code=$($KVSConfig['FunctionCode'])" }

  Write-Host "[DIAG] KVS Endpoint: $endpoint"
  Write-Host "[DIAG] KVS text: $kvspText"
  Write-Host "[DIAG] KVS jsondata preview: $($kvspJsonData.Substring(0,[Math]::Min(400,$kvspJsonData.Length)))"

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $endpoint -Body $bodyStr -ContentType 'application/x-www-form-urlencoded'
    Write-Host "[INFO] KVS 업로드 결과: $resp"
  }
  catch {
    Write-Host "[ERROR] KVS 업로드 실패: $($_.Exception.Message)"
    Write-Host "[ERROR] Full request body length: $($bodyStr.Length)"
  }
}
else {
  Write-Host "[INFO] KVS 업로드 비활성화. 결과 JSON:"
  Write-Host $json
}
