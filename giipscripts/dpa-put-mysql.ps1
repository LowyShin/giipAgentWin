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
# DO NOT change to: ../giipAgent.cfg or ./giipAgent.cfg
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
  Write-Host "[ERROR] SqlConnectionString   giipAgent.cfg SqlConnectionString  ."; exit 2
}

# 
$hostName = $env:COMPUTERNAME

# MySQL //  

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

# MySQL     (MySql.Data )
try {
  Add-Type -Path "C:\Program Files\MySQL\MySQL Connector Net 8.0.33\Assemblies\v4\MySql.Data.dll"
}
catch {
  Write-Host "[ERROR] MySql.Data.dll  . MySQL Connector/NET  ."; exit 1 
}

$conn = New-Object MySql.Data.MySqlClient.MySqlConnection($SqlConnectionString)
try {
  $conn.Open()
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $query
  $reader = $cmd.ExecuteReader()
  $results = @()
  while ($reader.Read()) {
    $results += [PSCustomObject]@{
      host_name  = $reader["host_name"]
      login_name = $reader["login_name"]
      command    = $reader["command"]
      cpu_time   = $reader["cpu_time"]
      status     = $reader["status"]
      query_text = $reader["query_text"]
    }
  }
  $reader.Close()
  $conn.Close()
}
catch {
  Write-Host "[ERROR] MySQL   : $($_.Exception.Message)"; exit 2 
}

# :  //
$grouped = $results | Group-Object host_name | ForEach-Object {
  [PSCustomObject]@{
    host_name = $_.Name
    sessions  = $_.Group.Count
    queries   = $_.Group | Select-Object login_name, status, cpu_time, reads, writes, logical_reads, start_time, command, query_text
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
  # Build apirule.md compliant request: text , jsondata  
  $kvspText = "KVSPut kType kKey kFactor"
  #  $summary JSON  (value  )
  $kvspJson = $summary | ConvertTo-Json -Depth 8 -Compress

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

