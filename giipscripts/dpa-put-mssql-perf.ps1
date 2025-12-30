<#
.SYNOPSIS
  Azure SQL Server 성능(QPS, CPU, Memory 등) 수집 후 MdbStatsUpdate API로 전송
.DESCRIPTION
  - pAgentMdbPerfCollect 저장 프로시저를 실행하여 실시간 QPS 및 성능 지표를 수집
  - 수집된 JSON 데이터를 giipfaw API (pApiMdbStatsUpdatebySK)로 전송
.PARAMETER SqlConnectionString
  Azure SQL Server 연결 문자열
.PARAMETER MdbId
  Managed Database ID (GIIP 상의 ID)
.EXAMPLE
  .\dpa-put-mssql-perf.ps1 -SqlConnectionString "Server=...;" -MdbId 101
#>
[CmdletBinding()]
param(
  [string]$SqlConnectionString,
  [int]$MdbId
)

# 기본 설정 로드 (giipAgent.cfg)
# ⚠️⚠️⚠️ DO NOT MODIFY THIS PATH ⚠️⚠️⚠️
# Path: ../..giipAgent.cfg (PARENT of repository root)
# DO NOT change to: ../giipAgent.cfg or ./giipAgent.cfg
# WHY? giipAgentWin/giipAgent.cfg is a SAMPLE with 'YOUR_LSSN'!
$AgentRoot = Join-Path $PSScriptRoot '..\..'  # giipAgentWin의 상위 디렉토리
$KVSConfig = @{}
$cfgPath = Join-Path $PSScriptRoot '..\..\giipAgent.cfg'
if (Test-Path -LiteralPath $cfgPath) {
  $lines = Get-Content -LiteralPath $cfgPath -Raw
  foreach ($line in ($lines -split "\r?\n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith("'")) { continue }
    $m = [regex]::Match($line, '^(?<k>\w+)\s*=\s*(?<v>.+)$', 'IgnoreCase')
    if ($m.Success) {
      $KVSConfig[$m.Groups['k'].Value.Trim()] = $m.Groups['v'].Value.Trim().Trim('"')
    }
  }
}

# 파라미터 우선 적용
if (-not $SqlConnectionString -and $KVSConfig['SqlConnectionString']) {
  $SqlConnectionString = $KVSConfig['SqlConnectionString']
}
if (-not $MdbId -and $KVSConfig['MdbId']) {
  $MdbId = [int]$KVSConfig['MdbId']
}

if (-not $SqlConnectionString -or -not $MdbId) {
  Write-Error "SqlConnectionString and MdbId are required."
  exit 1
}

# 1. SQL 실행: pAgentMdbPerfCollect (JSON 반환)
try {
  $query = "EXEC pAgentMdbPerfCollect"
  $jsonResult = Invoke-Sqlcmd -ConnectionString $SqlConnectionString -Query $query -MaxCharLength 1000000 | Select-Object -ExpandProperty Column1
  
  if (-not $jsonResult) {
    Write-Error "No data returned from pAgentMdbPerfCollect"
    exit 1
  }

  # JSON 파싱하여 mdb_id 주입
  $perfData = $jsonResult | ConvertFrom-Json
  $perfData.mdb_id = $MdbId
  
  # 다시 JSON으로 변환
  $finalJson = $perfData | ConvertTo-Json -Compress

  Write-Host "[INFO] Collected Data: $finalJson"

  # 2. API 전송: MdbStatsUpdate
  $apiText = "MdbStatsUpdate"
  $apiEndpoint = $KVSConfig['Endpoint']
  if (-not $apiEndpoint -and $KVSConfig['apiaddrv2']) { $apiEndpoint = $KVSConfig['apiaddrv2'] }
  if ($KVSConfig['FunctionCode']) { $apiEndpoint += "?code=$($KVSConfig['FunctionCode'])" }
  
  $postParams = [ordered]@{
    text     = $apiText
    token    = $KVSConfig['sk']
    jsondata = $finalJson
  }
  
  $bodyStr = ($postParams.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, [System.Uri]::EscapeDataString($_.Value) }) -join '&'

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $apiEndpoint -Body $bodyStr -ContentType 'application/x-www-form-urlencoded'
    Write-Host "[SUCCESS] API Response: $resp"
  }
  catch {
    Write-Error "API Upload Failed: $($_.Exception.Message)"
  }

}
catch {
  Write-Error "SQL Execution Failed: $($_.Exception.Message)"
  exit 1
}
