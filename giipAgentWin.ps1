<#
.SYNOPSIS
    giipAgent (PowerShell port) — with detailed comments. PowerShell version of the original .wsf / VBScript logic.

.DESCRIPTION
    The following processing flow is followed, implemented in a safer and more maintainable way:
    1) Read configuration (../giipAgent.cfg) to get 'at' and 'lsSn'
    2) Retrieve OS and host information
    3) Fetch one queue item from CQE API
       - If numeric, treat as new lssn and update cfg
       - If string, parse as "qsn||type||scriptBody"
    4) Save temporary script to %TEMP% and execute while tracking PID
       - type=wsf: wscript.exe //B //Nologo tmp.wsf
       - type=ps1: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tmp.ps1
       - otherwise: cmd.exe /c tmp.cmd
    5) Send the first 500 characters of execution result to KVS (URL encode/JSON escape)

  Improvements over the previous version:
    - Monitors execution time using Start-Process return value (PID), and kills only the relevant PID (entire process tree) on timeout
    - Uses HttpClient for HTTP with explicit timeout and enforces TLS1.2
    - Logs are daily files with levels (INFO/WARN/ERROR)
    - Temporary files are created with unique names and cleaned up after execution

.NOTES
  Author   : Lowy (original), PS port & comments: 2025-08-12
  Requires : Windows PowerShell 5.1+ (または PowerShell 7+ / Windows)
#>

#region ====== Constants & Initialization ======
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# バージョン表記
$AGENT_VER = '1.72'

# API URL テンプレート
$API_QUEUE_URL_TEMPLATE = 'https://giipasp.azurewebsites.net/api/cqe/cqequeueget04.asp?sk={{sk}}&lssn={{lssn}}&hn={{hn}}&os={{os}}&df=os&sv={{sv}}'
$API_KVS_URL_TEMPLATE   = 'https://giipasp.azurewebsites.net/api/kvs/kvsput.asp?sk={{sk}}&type=lssn&key={{lssn}}&factor={{factor}}&value={{kvsval}}'

# Log output
$LOG_DIR_REL          = '../giipLogs'                 # Compatible with previous version: relative to script location
$LOG_PREFIX           = 'giipAgent_'
$LOG_RETENTION_DAYS   = 30                            # Optional: used to delete old logs

# Timeout (ms)
$HTTP_TIMEOUT_MS      = 20000                         # Total guideline for resolve/connect/send/receive
$EXEC_TIMEOUT_MS      = 60000                         # Maximum wait time for temporary script execution
$RESULT_SNIPPET_LEN   = 500                           # Summary length when sending to KVS

# Log level
$LVL_INFO = 'INFO'
$LVL_WARN = 'WARN'
$LVL_ERR  = 'ERROR'

$BaseDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$TempDir = [System.IO.Path]::GetTempPath()

# Log directory (avoid mixing PathInfo and string)
$LogDirCandidate = Join-Path -Path $BaseDir -ChildPath $LOG_DIR_REL
if (-not (Test-Path -LiteralPath $LogDirCandidate)) { New-Item -ItemType Directory -Path $LogDirCandidate | Out-Null }
$LogDir = (Resolve-Path -LiteralPath $LogDirCandidate).Path
$LogFile = Join-Path $LogDir ("{0}{1}.log" -f $LOG_PREFIX, (Get-Date -Format 'yyyyMMdd'))

# Enable TLS 1.2 (prevent failures on old environments)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}


# HttpClient (reuse to avoid socket exhaustion)
$script:HttpClient = New-Object System.Net.Http.HttpClient
$script:HttpClient.Timeout = [TimeSpan]::FromMilliseconds($HTTP_TIMEOUT_MS)
#endregion

#region ====== Utilities: Logging/Formatting/Encoding ======
function Write-Log {
  param(
    [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR')] [string]$Level,
    [Parameter(Mandatory)][string]$Message
  )
  $ts = Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
  $line = "[$ts] [$Level] $Message"
  Add-Content -LiteralPath $LogFile.ToString() -Value $line
  Write-Host $line
}

function Format-Date([datetime]$dt, [string]$pattern) {
# Approximate of legacy SetDtToStr (only main formats used)
  $s = $pattern.ToUpperInvariant()
  $s = $s -replace 'YYYY', $dt.ToString('yyyy')
  $s = $s -replace 'YY',   $dt.ToString('yy')
  $s = $s -replace 'MM',   $dt.ToString('MM')
  $s = $s -replace 'DD',   $dt.ToString('dd')
  $s = $s -replace 'HH24', $dt.ToString('HH')
  $s = $s -replace 'MI',   $dt.ToString('mm')
  $s = $s -replace 'SS',   $dt.ToString('ss')
  return $s
}

function UrlEncode([string]$s) { if ($null -eq $s) { return '' } [System.Uri]::EscapeDataString($s) }

function Sanitize-ForJson([string]$s) {
  if ($null -eq $s) { return '' }
  $s = $s -replace '\\', '\\\\'
  $s = $s -replace '"', '\\"'
  $s = $s -replace "\r?\n", ' '
  return $s
}
#endregion

#region ====== Config/Environment Retrieval ======
function Get-OsAndHost {
    # Get OS name and host name from Win32_OperatingSystem
  try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    return [PSCustomObject]@{ OsName = [string]$os.Caption; HostName = [string]$os.CSName }
  } catch {
    return [PSCustomObject]@{ OsName = 'UnknownOS'; HostName = $env:COMPUTERNAME }
  }
}


function Read-Cfg { param([string]$CfgPath)
  # Expected format example:
  #   at   = "<AccessToken>"
  #   lsSn = "<LicenseSerialNumber>"
  $result = @{}
  if (-not (Test-Path -LiteralPath $CfgPath)) { throw "Config not found: $CfgPath" }
  $lines = Get-Content -LiteralPath $CfgPath -Raw
  foreach ($line in ($lines -split "\r?\n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith("'")) { continue } # VBScript comment
    $m = [regex]::Match($line, '^(?<k>\w+)\s*=\s*(?<v>.+)$', 'IgnoreCase')
    if ($m.Success) {
      $k = $m.Groups['k'].Value.Trim()
      $v = $m.Groups['v'].Value.Trim().Trim('"')
      $result[$k] = $v
    }
  }
  return $result
}

function Update-CfgLssn {
  param([Parameter(Mandatory)][string]$CfgPath, [Parameter(Mandatory)][string]$NewLssn)
  $content = Get-Content -LiteralPath $CfgPath -Raw
  $re = New-Object System.Text.RegularExpressions.Regex('(^|\r?\n)\s*lssn\s*=\s*.*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($re.IsMatch($content)) {
    $content = $re.Replace($content, "`r`nlssn = $NewLssn")
  } else {
    if (-not $content.EndsWith("`r`n") -and -not $content.EndsWith("`n")) { $content += "`r`n" }
    $content += "lssn = $NewLssn`r`n"
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($CfgPath, $content, $utf8NoBom)
}
#endregion

#region ====== HTTP Wrapper ======
function Invoke-Http {
  param(
    [Parameter(Mandatory)][ValidateSet('GET','POST')] [string]$Method,
    [Parameter(Mandatory)][string]$Url,
    [string]$Body,
    [string]$ContentType = 'text/plain'
  )
  try {
    Write-Host ("[DEBUG] Invoke-Http sending URL: {0}" -f $Url)
    $req = New-Object System.Net.Http.HttpRequestMessage($Method, $Url)
    $req.Headers.Accept.Clear() | Out-Null
    $mt = New-Object System.Net.Http.Headers.MediaTypeWithQualityHeaderValue 'text/plain'
    $null = $req.Headers.Accept.Add($mt)

    if ($Method -eq 'POST') {
      $enc = [System.Text.Encoding]::UTF8
      if ($null -eq $Body) {
        $bodyText = ''
      } else {
        $bodyText = $Body
      }
      $req.Content = New-Object System.Net.Http.StringContent($bodyText, $enc, $ContentType)
    }

    $resp = $script:HttpClient.SendAsync($req).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
      Write-Log $LVL_ERR "HTTP Error: $($resp.StatusCode) $Url"
      return ''
    }
    return $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  } catch {
    Write-Log $LVL_ERR ("HTTP Exception: {0}" -f $_.Exception.Message)
    return ''
  }
}
#endregion

#region ====== キュー実行 ======
function New-TempScriptPath { param([string]$Ext)
  $name = 'giip_tmp_{0}_{1}{2}' -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Maximum 999999), $Ext
  return (Join-Path $TempDir $name)
}


function Write-AllTextUtf8NoBom { param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}


function Invoke-QueueScript {
  param(
    [Parameter(Mandatory)][ValidateSet('wsf','ps1','cmd','other')] [string]$Type,
    [Parameter(Mandatory)][string]$Body
  )
  $ext = switch ($Type) { 'wsf' { '.wsf' } 'ps1' { '.ps1' } 'cmd' { '.cmd' } default { '.cmd' } }

  $tmpScript = New-TempScriptPath -Ext $ext

# Write temporary script
Write-AllTextUtf8NoBom -Path $tmpScript -Content $Body

# Execution command
switch ($Type) {
    'wsf' { $exe = "$env:SystemRoot\System32\wscript.exe"; $arg = "//B //Nologo `"$tmpScript`"" }
    'ps1' { $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"; $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$tmpScript`"" }
    default { $exe = "$env:SystemRoot\System32\cmd.exe"; $arg = "/c `"$tmpScript`"" }
}

# Start-Process (capture standard output/error)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $exe
  $psi.Arguments              = $arg
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi

  $ok = $proc.Start()
  if (-not $ok) { throw 'Failed to start process.' }

# Timeout monitoring
  if (-not $proc.WaitForExit([int]$EXEC_TIMEOUT_MS)) {
    try { & "$env:SystemRoot\System32\taskkill.exe" /PID $proc.Id /T /F | Out-Null } catch {}
    Write-Log $LVL_WARN "Child process timeout. Killed. pid=$($proc.Id)"
    $exitCode = -1
  } else {
    $exitCode = $proc.ExitCode
  }

# Collect output
$stdOut = $proc.StandardOutput.ReadToEnd()
$stdErr = $proc.StandardError.ReadToEnd()

# Cleanup
  if (Test-Path -LiteralPath $tmpScript) { Remove-Item -LiteralPath $tmpScript -ErrorAction SilentlyContinue }

  $output = if ($stdErr) { "$stdOut`nERR:`n$stdErr" } else { $stdOut }

  return [PSCustomObject]@{ Ok = ($exitCode -eq 0); Output = $output; Code = $exitCode }
}
#endregion

#region ====== Main Processing ======
Write-Log $LVL_INFO "Start giipAgent v$AGENT_VER"

# ==== Diagnostics (prints to console for paste) ====
Write-Host "==DIAG=="
Write-Host ("PSVersion     : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("PSHost        : {0}" -f $Host.Name)
Write-Host ("ScriptPath    : {0}" -f $PSCommandPath)
Write-Host ("BaseDir       : {0}" -f $BaseDir)
Write-Host ("TempDir       : {0}" -f $TempDir)
$cfgTestPath = Join-Path $BaseDir '../giipAgent.cfg'
Write-Host ("CfgPath       : {0}" -f $cfgTestPath)
Write-Host ("CfgExists     : {0}" -f (Test-Path -LiteralPath $cfgTestPath))
Write-Host ("LogFile       : {0}" -f $LogFile)
Write-Host ("QueueURL(TOP) : {0}" -f $API_QUEUE_URL_TEMPLATE)
Write-Host ("KVSURL(TOP)   : {0}" -f $API_KVS_URL_TEMPLATE)
Write-Host "==/DIAG=="

# 1) Load configuration
$cfgPath = Join-Path $BaseDir '../giipAgent.cfg'
$cfg = Read-Cfg -CfgPath $cfgPath
if (-not $cfg.ContainsKey('at') -or -not $cfg.ContainsKey('lssn')) {
  Write-Log $LVL_ERR "giipAgent.cfg から 'at' または 'lssn' を取得できません。終了します。 "
  exit 2
}
$at   = [string]$cfg['at']
$lsSn = [string]$cfg['lssn']

# 2) OS/Host information
$info = Get-OsAndHost
$osName   = $info.OsName
$hostName = $info.HostName

# 3) URL construction
$queueUrl = $API_QUEUE_URL_TEMPLATE
$queueUrl = $queueUrl.Replace('{{sk}}',   $at)
$queueUrl = $queueUrl.Replace('{{lssn}}', $lsSn)
$queueUrl = $queueUrl.Replace('{{hn}}',   (UrlEncode $hostName))
$queueUrl = $queueUrl.Replace('{{os}}',   (UrlEncode $osName))
$queueUrl = $queueUrl.Replace('{{sv}}',   (UrlEncode $AGENT_VER))

$kvsUrlBase = $API_KVS_URL_TEMPLATE
$kvsUrlBase = $kvsUrlBase.Replace('{{sk}}',   $at)
$kvsUrlBase = $kvsUrlBase.Replace('{{lssn}}', $lsSn)

Write-Log $LVL_INFO "Queue URL: $queueUrl"

# 4) Fetch queue
$qRes = Invoke-Http -Method GET -Url $queueUrl
if ([string]::IsNullOrWhiteSpace($qRes)) {
  Write-Log $LVL_WARN 'No data received from CQE. Exiting process.'
  Write-Log $LVL_INFO "Finish giipAgent v$AGENT_VER"
  exit 0
}

# 5) If numeric, update lssn; otherwise, execute queue
if ($qRes -match '^[0-9]+$') {
    Write-Log $LVL_INFO "Numeric response (interpreted as new lssn): $qRes"
    Update-CfgLssn -CfgPath $cfgPath -NewLssn $qRes
    Write-Log $LVL_INFO 'Updated lssn in giipAgent.cfg.'
} else {
    $parts = $qRes -split '\|\|'
    if ($parts.Count -eq 3) {
        $qsn   = $parts[0]
        $qType = ($parts[1].Trim().ToLower())
        $qBody = $parts[2]

        # Placeholder replacement
        $qBody = $qBody.Replace('{{sk}}', $at)
        $qBody = $qBody.Replace('{{lssn}}', $lsSn)

        Write-Log $LVL_INFO "Queue received: qsn=$qsn, type=$qType, bodyLen=$($qBody.Length)"

        # Execute (unknown type is treated as cmd)
        $typeForExec = if ($qType -in @('wsf','ps1')) { $qType } else { 'cmd' }
        $exec = Invoke-QueueScript -Type $typeForExec -Body $qBody
        $outLen = 0
        if ($null -ne $exec.Output) {
            $outLen = $exec.Output.Length
        }
        Write-Log $LVL_INFO ("Queue execution finished: Success={0}, ExitCode={1}, OutputLen={2}" -f $exec.Ok, $exec.Code, $outLen)
        # Send to KVS (result summary)
        $snippet = ''
        if ($null -ne $exec.Output -and $exec.Output.Length -gt 0) {
            $snippet = $exec.Output.Substring(0, [Math]::Min($RESULT_SNIPPET_LEN, $exec.Output.Length))
        }
        $payloadObj = @{ CMD = 'Exec CQE'; qsn = $qsn; type = $qType; RstVal = (Sanitize-ForJson $snippet) }
        $payloadJson = ($payloadObj | ConvertTo-Json -Depth 3 -Compress)
        $kvsUrl = $kvsUrlBase.Replace('{{factor}}', 'gpAgentLog').Replace('{{kvsval}}', (UrlEncode $payloadJson))
        $kvsRes = Invoke-Http -Method GET -Url $kvsUrl
        Write-Log $LVL_INFO "KVS response: $kvsRes"
    } else {
        $preview = $qRes
        if ($qRes.Length -gt 200) {
            $preview = $qRes.Substring(0,200)
        }
        Write-Log $LVL_WARN ("Invalid CQE response format: parts={0}, payload='{1}'" -f $parts.Count, $preview)
        $snippet = $qRes
        if ($qRes.Length -gt $RESULT_SNIPPET_LEN) {
            $snippet = $qRes.Substring(0,$RESULT_SNIPPET_LEN)
        }
        $payloadObj = @{ CMD = 'Check CQE'; RstVal = (Sanitize-ForJson $snippet) }
        $payloadJson = ($payloadObj | ConvertTo-Json -Depth 3 -Compress)
        $kvsUrl = $kvsUrlBase.Replace('{{factor}}', 'gpAgentLog').Replace('{{kvsval}}', (UrlEncode $payloadJson))
        $null = Invoke-Http -Method GET -Url $kvsUrl
    }
}

Write-Log $LVL_INFO "Finish giipAgent v$AGENT_VER"

#endregion
