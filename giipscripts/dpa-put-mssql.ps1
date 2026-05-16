<#
.SYNOPSIS
  Azure SQL Server    ,     KVS 
.DESCRIPTION
  -  ()  Azure SQL Server (/CPU/ )
      ()     
  -  JSON  giipAgent.cfg  KVS 
.PARAMETER SqlConnectionString
  Azure SQL Server  
.PARAMETER KFactor
  KVS   factor (: 'sqlnetinv')
.EXAMPLE
  .\Collect-SqlNetInventory.ps1 -SqlConnectionString "Server=...;User Id=...;Password=...;..."
.NOTES
  - giipAgent.cfg KVSConfig 
  - PowerShell 7+  (SqlClient )
#>
[CmdletBinding()]
param(
  [string]$SqlConnectionString,
  [string]$KFactor = 'sqlnetinv'
)

# KVSConfig  SqlConnectionString  (giipAgent.cfg)
#  DO NOT MODIFY THIS PATH 
# Path: ../..giipAgent.cfg (PARENT of repository root)
# DO NOT change to: ../giipAgent.cfg or ./giipAgent.cfg
# WHY? giipAgentWin/giipAgent.cfg is a SAMPLE with 'YOUR_LSSN'!
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
  
  # KType, KKey  
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
  Write-Host "[ERROR] SqlConnectionString   giipAgent.cfg SqlConnectionString  ."; exit 2
}

# SQL Server //  
try {
  Import-Module SqlServer -ErrorAction Stop
}
catch {
  Write-Host "[ERROR] SqlServer  . Install-Module SqlServer -Scope CurrentUser  ."; exit 1 
}

# 
$hostName = $env:COMPUTERNAME

# //   ()

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

# : IP ///
$grouped = $results | Group-Object client_net_address | ForEach-Object {
  [PSCustomObject]@{
    client_net_address = $_.Name
    host_name          = if ($_.Group[0].host_name) { $_.Group[0].host_name } else { "" }
    sessions           = $_.Group.Count
    queries            = $_.Group | Select-Object client_net_address, login_name, status, cpu_load, last_sql, is_open_tran, tran_duration, tran_state
  }
}

#   
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

# KVS  (show endpoint and payload)
if ($KVSConfig['Enabled'] -eq 'true') {
  # Build apirule.md compliant request: text  , jsondata  
  # NOTE: kValue text   (jsondata  )
  $kvspText = "KVSPut kType kKey kFactor"
  
  # jsondata   
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
    Write-Host "[INFO] KVS  : $resp"
  }
  catch {
    Write-Host "[ERROR] KVS  : $($_.Exception.Message)"
    Write-Host "[ERROR] Full request body length: $($bodyStr.Length)"
  }
}
else {
  Write-Host "[INFO] KVS  .  JSON:"
  Write-Host $json
}

