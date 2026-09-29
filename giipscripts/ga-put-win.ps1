# ============================================================================
# ga-put-win.ps1
# Purpose : Collect GA4 metrics via the Google Analytics Data API (runReport)
#           using a service-account key, then push the summary to GIIP as
#           text=GaPut (kType='ga') through the byAK dispatcher.
# Runs    : Standalone / independent of giipAgent3.ps1. Register as its own
#           daily Scheduled Task with -Register. Requires PowerShell 7 (pwsh)
#           for RSA PKCS#8 JWT signing.
# Auth    : Service-account JSON (client_email + private_key) -> signed JWT ->
#           OAuth2 access token (scope analytics.readonly). GIIP side uses
#           $Config.sk (resolved by SP via lwGetUSNbyat, SK or AK).
# GIIP    : lib/Common.ps1 -> Invoke-GiipApiV2 with CommandText
#           "GaPut kKey kFactor kValue". kKey MUST be registered in
#           tGaProperty(gaPropertyId, cSn) or the SP returns 403.
# Spec    : giip-678 / SPEC_20260720_GA_KVS_AI_REPORT.md T3
# ============================================================================

[CmdletBinding()]
param(
    [switch]$Register,                  # Register a daily Scheduled Task and exit
    [string]$AtTime = "00:10",          # Daily run time (for -Register)
    [string]$PropertyId,                # GA4 property, e.g. "properties/123456789" (else cfg ga_property)
    [string]$KeyFile,                   # Service-account JSON path (else cfg ga_keyfile)
    [string]$Factor = "daily",          # KVS kFactor (metric set id)
    [string]$Range = "yesterday",       # GA4 date range keyword (yesterday / today / 7daysAgo..)
    [string]$OutFile                    # Raw JSON output path (else giipLogs\ga\...)
)

$ErrorActionPreference = "Stop"

# --- Resolve paths and load shared libraries ---------------------------------
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path $ScriptDir -Parent            # giipscripts -> giipAgentWin
$LibDir    = Join-Path $AgentRoot "lib"
$Global:BaseDir = $AgentRoot                                # so Get-GiipConfig finds ../giipAgent.cfg

. (Join-Path $LibDir "Common.ps1")   # Get-GiipConfig, Invoke-GiipApiV2, Write-GiipLog

# --- -Register: install a daily Scheduled Task (prefer pwsh 7 for crypto) ------
if ($Register) {
    $self = $MyInvocation.MyCommand.Path
    $taskName = "GIIP GA Collector"
    $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
    $arg = "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$self`""
    $action    = New-ScheduledTaskAction -Execute $exe -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -Daily -At $AtTime
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-GiipLog "INFO" "Registered Scheduled Task '$taskName' ($exe, daily at $AtTime)."
    return
}

# --- Capability guard: JWT RS256 needs .NET Core RSA (PowerShell 7) ------------
if (-not ([System.Security.Cryptography.RSA].GetMethod('ImportPkcs8PrivateKey'))) {
    Write-GiipLog "ERROR" "RSA.ImportPkcs8PrivateKey unavailable. Run this script under PowerShell 7 (pwsh)."
    exit 1
}

# --- Load config -------------------------------------------------------------
$Config = Get-GiipConfig
if (-not $PropertyId) { $PropertyId = $Config.ga_property }
if (-not $KeyFile)    { $KeyFile    = $Config.ga_keyfile }
if (-not $PropertyId) { Write-GiipLog "ERROR" "PropertyId missing (-PropertyId or cfg ga_property)."; exit 1 }
if (-not $KeyFile -or -not (Test-Path $KeyFile)) { Write-GiipLog "ERROR" "Service-account KeyFile not found: '$KeyFile'."; exit 1 }
if (-not $Config.apiaddrv2) { Write-GiipLog "ERROR" "apiaddrv2 (dispatcher URL) missing in giipAgent.cfg."; exit 1 }
if (-not $Config.sk)        { Write-GiipLog "ERROR" "sk missing in giipAgent.cfg (GIIP auth token)."; exit 1 }

# --- Helpers -----------------------------------------------------------------
function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Build a signed JWT from the service account and exchange it for an access token.
function Get-GaAccessToken {
    param([Parameter(Mandatory)][string]$KeyFilePath)
    $sa = Get-Content $KeyFilePath -Raw | ConvertFrom-Json
    if (-not $sa.client_email -or -not $sa.private_key) { throw "Service-account JSON missing client_email/private_key." }
    $tokenUri = if ($sa.token_uri) { $sa.token_uri } else { "https://oauth2.googleapis.com/token" }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $headerJson = @{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress
    $claimJson  = @{
        iss   = $sa.client_email
        scope = 'https://www.googleapis.com/auth/analytics.readonly'
        aud   = $tokenUri
        iat   = $now
        exp   = $now + 3600
    } | ConvertTo-Json -Compress

    $hB = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($headerJson))
    $cB = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($claimJson))
    $signingInput = "$hB.$cB"

    # PKCS#8 PEM -> DER -> RSA
    $pemBody = ($sa.private_key -replace '-----BEGIN PRIVATE KEY-----', '' -replace '-----END PRIVATE KEY-----', '') -replace '\s', ''
    $der = [Convert]::FromBase64String($pemBody)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportPkcs8PrivateKey($der, [ref]0) | Out-Null
    $sig = $rsa.SignData(
        [Text.Encoding]::UTF8.GetBytes($signingInput),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $jwt = "$signingInput." + (ConvertTo-Base64Url $sig)

    $resp = Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType 'application/x-www-form-urlencoded' -Body @{
        grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer'
        assertion  = $jwt
    } -TimeoutSec 30
    if (-not $resp.access_token) { throw "OAuth token exchange returned no access_token." }
    return $resp.access_token
}

# --- Acquire access token ----------------------------------------------------
Write-GiipLog "INFO" "Requesting GA access token for $PropertyId."
try { $accessToken = Get-GaAccessToken -KeyFilePath $KeyFile }
catch { Write-GiipLog "ERROR" "GA token acquisition failed: $_"; exit 1 }

# --- runReport (minimal metric set per spec) ---------------------------------
$reportBody = @{
    dateRanges = @(@{ startDate = $Range; endDate = $Range })
    metrics    = @(
        @{ name = 'activeUsers' },
        @{ name = 'sessions' },
        @{ name = 'screenPageViews' },
        @{ name = 'bounceRate' },
        @{ name = 'conversions' },
        @{ name = 'averageSessionDuration' }
    )
} | ConvertTo-Json -Depth 6

$reportUrl = "https://analyticsdata.googleapis.com/v1beta/$PropertyId`:runReport"
Write-GiipLog "INFO" "Calling GA4 runReport ($Range)."
try {
    $report = Invoke-RestMethod -Method Post -Uri $reportUrl -Headers @{ Authorization = "Bearer $accessToken" } `
        -ContentType 'application/json' -Body $reportBody -TimeoutSec 60
} catch {
    Write-GiipLog "ERROR" "GA4 runReport failed: $_"; exit 1
}

# --- Map metric headers -> values (row 0 is the aggregate for a single range) --
$metrics = [ordered]@{}
$headers = @($report.metricHeaders)
$row0    = if ($report.rows) { @($report.rows)[0] } else { $null }
if ($row0) {
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $name = $headers[$i].name
        $val  = $row0.metricValues[$i].value
        $num  = 0.0
        if ([double]::TryParse($val, [ref]$num)) { $metrics[$name] = $num } else { $metrics[$name] = $val }
    }
} else {
    Write-GiipLog "WARN" "GA4 runReport returned no rows; storing empty metric set."
}

# --- Build kValue payload ----------------------------------------------------
$collectedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$kValue = [ordered]@{
    propertyId  = $PropertyId
    range       = $Range
    metrics     = $metrics
    collectedAt = $collectedAt
    source      = "giipAgentWin/ga-put-win.ps1"
}

# --- Save raw report (UTF-8, no BOM) -----------------------------------------
if (-not $OutFile) {
    $gaDir = Join-Path $AgentRoot "..\giipLogs\ga"
    if (-not (Test-Path $gaDir)) { New-Item -Path $gaDir -ItemType Directory -Force | Out-Null }
    $safeProp = $PropertyId -replace '[\\/:*?"<>|]', '_'
    $OutFile = Join-Path $gaDir ("ga_{0}_{1}.json" -f $safeProp, (Get-Date).ToString("yyyyMMdd"))
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutFile, ($report | ConvertTo-Json -Depth 12), $utf8NoBom)
Write-GiipLog "INFO" "Saved raw GA report -> $OutFile"

# --- Push to GIIP (text=GaPut) -----------------------------------------------
# Mirror Invoke-GiipKvsPut contract: payload keys match CommandText tokens.
$payload = @{
    kKey    = $PropertyId
    kFactor = $Factor
    kValue  = $kValue
}
$jsonPayload = $payload | ConvertTo-Json -Compress -Depth 10
$cmdText = "GaPut kKey kFactor kValue"

Write-GiipLog "INFO" "Pushing GaPut (kKey=$PropertyId, kFactor=$Factor)."
$resp = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $jsonPayload

# SP returns Proc_MSG "200|OK" (dispatcher may surface as data[0].Proc_MSG or RstVal).
$ok = $false
if ($resp) {
    if ($resp.Proc_MSG -and "$($resp.Proc_MSG)" -match '^200') { $ok = $true }
    elseif ($resp.RstVal -eq "200") { $ok = $true }
}
if ($ok) {
    Write-GiipLog "INFO" "GA metrics uploaded successfully."
} else {
    $rv = if ($resp) { ($resp | ConvertTo-Json -Compress -Depth 5) } else { "no-response" }
    Write-GiipLog "ERROR" "GaPut failed: $rv"
    exit 1
}
