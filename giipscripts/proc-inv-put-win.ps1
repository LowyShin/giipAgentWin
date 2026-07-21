<#
.SYNOPSIS
  Windows 프로세스 인벤토리(경로/서명/해시/커맨드라인) 수집 → giip KVS 전송 (kFactor='procinv').

.DESCRIPTION
  giip issue #679 E1. 기존 netstat 수집(net-put-win.ps1 / kFactor='netstat')이 "연결을 가진
  프로세스의 이름"만 담는 것과 달리, 본 스크립트는 전체 프로세스의
  name/path/signed/signer/sha256/cmdline/pid/ppid 를 수집한다. 이 데이터가 있어야
  서버측 판정 SP(pApiNet3dProcThreatEvalbyAK [EXT])가 마스커레이딩/경로/서명/해시를 판정할 수 있다.

  성역 준수:
  - run.ps1 무수정. 본 스크립트는 CQE 큐 또는 스케줄러로 배포되는 독립 수집 모듈이다.
  - KVS 전송은 표준 KVSPut 규약(text=파라미터명, jsondata.kValue=실값)만 사용. 임의 API 없음.
    (reference_kvsput_text_signature: kValue는 반드시 jsondata.kValue 필드에)

  procinv KVS 계약 (kValue):
    { "schema_version":"1.0.0", "collected_at_utc":"<ISO8601>",
      "processes":[ { "name","path","signed","signer","sha256","cmdline","pid","ppid" } ] }
  → 서버 SP는 OPENJSON '$.processes' 로 파싱한다.

.PARAMETER Output
  로컬 JSON 저장 경로. 기본 .\proc_inventory.json

.PARAMETER MaxProcesses
  수집 상한(성능 보호). 기본 2000.

.PARAMETER NoHash
  SHA256 해시 수집 생략(가장 비싼 단계). 서명/경로만 필요할 때.

.PARAMETER SendToGiip
  수집 후 giip KVS로 전송.

.NOTES
  경로가 같은 실행파일의 서명/해시는 1회만 계산(캐시)하여 중복 비용 제거.
  인코딩: UTF-8(BOM 없음).
#>
[CmdletBinding()]
param(
  [string]$Output = ".\proc_inventory.json",
  [int]$MaxProcesses = 2000,
  [switch]$NoHash,
  # --- giipapi 전송 파라미터 ---
  [switch]$SendToGiip,
  [string]$GiipEndpoint,
  [string]$GiipCode,
  [string]$GiipUserToken,
  [string]$GiipUserId,
  [string]$KType = 'lssn',
  [string]$KKey,
  [string]$KFactor = 'procinv'
)

# @@ANCHOR:USER_CONFIG_START
# giipAgent.cfg 의 KVSConfig 로드. kFactor 는 고정.
# DO NOT MODIFY THIS PATH
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
  if ($KVSConfig['Enabled']) { $KVSConfig['Enabled'] = ($KVSConfig['Enabled'] -eq 'true') }
  if (-not $KVSConfig['HostKey']) { $KVSConfig['HostKey'] = $env:COMPUTERNAME }
}
$KVSConfig['KFactor'] = 'procinv'
# @@ANCHOR:USER_CONFIG_END

# @@ANCHOR:DEFAULT_INJECTION_START
if (-not $PSBoundParameters.ContainsKey('SendToGiip')) { if ($KVSConfig.Enabled) { $SendToGiip = $true } }
if (-not $GiipEndpoint -and $KVSConfig.Endpoint) { $GiipEndpoint = $KVSConfig.Endpoint }
if (-not $GiipCode -and $KVSConfig.FunctionCode) { $GiipCode = $KVSConfig.FunctionCode }
if (-not $GiipUserToken -and $KVSConfig.UserToken) { $GiipUserToken = $KVSConfig.UserToken }
if (-not $GiipUserId -and $KVSConfig.UserId) { $GiipUserId = $KVSConfig.UserId }
if (-not $KType -and $KVSConfig.KType) { $KType = $KVSConfig.KType }
if (-not $KKey -and $KVSConfig.KKey) { $KKey = $KVSConfig.KKey }
if (-not $KFactor -and $KVSConfig.KFactor) { $KFactor = $KVSConfig.KFactor }
# @@ANCHOR:DEFAULT_INJECTION_END

# region Collect -------------------------------------------------------------
function Get-ProcessInventory {
  param([int]$Max, [switch]$SkipHash)

  # 경로별 서명/해시 캐시 (동일 exe 중복 계산 방지)
  $signCache = @{}
  $hashCache = @{}

  function Get-SignInfo {
    param([string]$Path)
    if (-not $Path) { return @{ signed = $null; signer = $null } }
    if ($signCache.ContainsKey($Path)) { return $signCache[$Path] }
    $res = @{ signed = $false; signer = $null }
    try {
      $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
      $res.signed = ($sig.Status -eq 'Valid')
      if ($sig.SignerCertificate) {
        # Subject CN 추출 (예: "CN=NVIDIA Corporation, O=...")
        $subj = $sig.SignerCertificate.Subject
        $cn = [regex]::Match($subj, 'CN=([^,]+)').Groups[1].Value
        $res.signer = if ($cn) { $cn.Trim() } else { $subj }
      }
    } catch { }
    $signCache[$Path] = $res
    return $res
  }

  function Get-HashInfo {
    param([string]$Path)
    if ($SkipHash -or -not $Path) { return $null }
    if ($hashCache.ContainsKey($Path)) { return $hashCache[$Path] }
    $h = $null
    try { $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    $hashCache[$Path] = $h
    return $h
  }

  $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object -First $Max
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($p in $procs) {
    $path = $p.ExecutablePath
    $si = Get-SignInfo -Path $path
    $list.Add([pscustomobject]@{
      name    = if ($p.Name) { $p.Name.ToLower() } else { $null }
      path    = $path
      signed  = $si.signed
      signer  = $si.signer
      sha256  = Get-HashInfo -Path $path
      cmdline = $p.CommandLine
      pid     = [int]$p.ProcessId
      ppid    = [int]$p.ParentProcessId
    })
  }
  return $list
}
# endregion Collect ----------------------------------------------------------

$processes = Get-ProcessInventory -Max $MaxProcesses -SkipHash:$NoHash

$doc = [pscustomobject]@{
  schema_version   = '1.0.0'
  collected_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  host             = $env:COMPUTERNAME
  processes        = $processes
}

# region giipapi (표준 KVSPut) -----------------------------------------------
function Build-ApiUrl {
  param([Parameter(Mandatory)][string]$Endpoint, [string]$Code)
  $e = ([string]$Endpoint).Trim()
  $c = if ($Code) { ([string]$Code).Trim() } else { '' }
  if (-not ($e -match '^(?i)https?://')) { throw 'GiipEndpoint must start with http:// or https://' }
  $ret = $e
  if (-not [string]::IsNullOrWhiteSpace($c)) {
    try { $cEnc = [uri]::EscapeDataString($c) } catch { $cEnc = $c }
    $sep = if ($e.Contains('?')) { '&' } else { '?' }
    $ret = ('{0}{1}code={2}' -f $e, $sep, $cEnc)
  }
  return $ret
}
function Send-GiipApi {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Endpoint,
    [string]$FunctionCode,
    [Parameter(Mandatory)][string]$JsonValue,
    [string]$UserToken,
    [string]$UserId,
    [string]$KType = 'lssn',
    [Parameter(Mandatory)][string]$KKey,
    [string]$KFactor = 'procinv'
  )
  $url = Build-ApiUrl -Endpoint $Endpoint -Code $FunctionCode
  if (-not [uri]::IsWellFormedUriString($url, [UriKind]::Absolute)) { throw ("Invalid URL built: [{0}]" -f $url) }
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  $ut = if ($UserToken) { $UserToken } else { '' }
  $uid = if ($UserId) { $UserId } else { '' }
  # 표준 KVSPut: text=파라미터명만, jsondata.kValue 에 실값 (인라인 form 은 서버에서 빈값 저장=조용한 손실)
  $body = @{
    text      = "KVSPut kType kKey kFactor kValue";
    jsondata  = (@{ kType = $KType; kKey = $KKey; kFactor = $KFactor; kValue = ($JsonValue | ConvertFrom-Json) } | ConvertTo-Json -Compress -Depth 30);
    usertoken = $ut;
    user_id   = $uid;
    token     = $ut
  }
  try {
    return Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/x-www-form-urlencoded' -Body $body -TimeoutSec 120
  } catch {
    throw ("giipapi upload failed: {0}" -f $_.Exception.Message)
  }
}
# endregion giipapi ----------------------------------------------------------

# region Output --------------------------------------------------------------
try {
  $json = $doc | ConvertTo-Json -Depth 10
  $dir = Split-Path -Parent $Output
  if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
  $json | Out-File -FilePath $Output -Encoding utf8
  Write-Host ("proc inventory JSON written: {0} ({1} processes)" -f (Resolve-Path $Output), $processes.Count)

  if ($SendToGiip) {
    if (-not $GiipEndpoint) { throw 'GiipEndpoint is required.' }
    if (-not $KKey) { throw 'KKey (lssn) is required for KVSPut.' }
    $response = Send-GiipApi -Endpoint $GiipEndpoint -FunctionCode $GiipCode -JsonValue $json -UserToken $GiipUserToken -UserId $GiipUserId -KType $KType -KKey $KKey -KFactor $KFactor
    Write-Host "giipapi response:" -ForegroundColor Cyan
    if ($response) { $response | Out-String | Write-Host } else { Write-Host '(no content)' }
  }
} catch {
  Write-Error $_
}
# endregion Output -----------------------------------------------------------
