# ============================================================================
# ga-collect.cqe.ps1  —  CQE-delivered GA4 collector (giip-678)
# ----------------------------------------------------------------------------
# This is a SELF-CONTAINED script body meant to be registered in the giip CQE
# repo (tMgmtScript) and dispatched to a remote PC's giipAgentWin via CQE.
# It has NO dependency on giipAgentWin/lib because CQE runs the body from a
# throwaway %TEMP% file (lib/Worker.ps1 -> Invoke-ScriptBlock, 60s budget).
#
# CQE placeholder substitution (do NOT edit these tokens):
#   {{sk}}              -> agent GIIP token   (lib/Worker.ps1)
#   {{lssn}}            -> agent lssn         (lib/Worker.ps1)
#   {{CustomVariables}} -> per-assignment custom_values injected as PS code
#                          (giipdb pCQEForcebyUsn REPLACE). Must set:
#                            $GaProperty  = 'properties/123456789'
#                            $GaKeyFile   = 'C:\giip\ga-service-account.json'
#                            $GaDispatcher= 'https://<giip byAK dispatcher url>'
#                          optional: $GaFactor (default 'daily'), $GaRange (default 'yesterday')
#
# Remote PC prerequisites:
#   - PowerShell 7 (pwsh) installed  (RSA PKCS#8 JWT signing). Body re-execs under pwsh.
#   - GA4 service-account key JSON present at $GaKeyFile (NOT shipped in ms_body).
#   - giipAgentWin running and polling CQE for this lssn.
#
# Registration: giipdb/mgmt/register-ga-cqe.ps1 (CQERepoPut + CQEQueuePut).
# Spec: giip-678 / SPEC_20260720_GA_KVS_AI_REPORT.md T3 (CQE delivery variant)
# ============================================================================

$ErrorActionPreference = "Stop"

# --- CQE-injected values -----------------------------------------------------
$GiipToken = '{{sk}}'
$Lssn      = '{{lssn}}'
$GaFactor  = 'daily'
$GaRange   = 'yesterday'
$GaProperty   = ''
$GaKeyFile    = ''
$GaDispatcher = ''
# {{CustomVariables}}  (injected PS assignments override the blanks above)
{{CustomVariables}}

function GaLog($lvl, $msg) { Write-Output ("[{0}] [ga-cqe] {1}: {2}" -f (Get-Date -Format s), $lvl, $msg) }

# --- Re-exec under PowerShell 7 if we are on Windows PowerShell 5.1 -----------
# RSA.ImportPkcs8PrivateKey (JWT RS256) needs .NET Core (pwsh). CQE launches the
# body with powershell.exe, so hop to pwsh once for the crypto path.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh -and $PSCommandPath) {
        GaLog "INFO" "Re-executing under pwsh 7 for JWT signing."
        & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
    GaLog "ERROR" "PowerShell 7 (pwsh) required but not found. Install pwsh on this PC."
    exit 1
}

# --- Validate injected config ------------------------------------------------
if (-not $GaProperty)   { GaLog "ERROR" "GaProperty not set (custom_values)."; exit 1 }
if (-not $GaDispatcher) { GaLog "ERROR" "GaDispatcher not set (custom_values)."; exit 1 }
if (-not $GaKeyFile -or -not (Test-Path $GaKeyFile)) { GaLog "ERROR" "GaKeyFile not found: '$GaKeyFile'."; exit 1 }
if (-not $GiipToken -or $GiipToken -like '*{{*') { GaLog "ERROR" "GIIP token not injected."; exit 1 }

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Build a signed JWT from the service account and exchange it for an access token.
function Get-GaAccessToken([string]$KeyFilePath) {
    $sa = Get-Content $KeyFilePath -Raw | ConvertFrom-Json
    if (-not $sa.client_email -or -not $sa.private_key) { throw "SA JSON missing client_email/private_key." }
    $tokenUri = if ($sa.token_uri) { $sa.token_uri } else { "https://oauth2.googleapis.com/token" }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $headerJson = @{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress
    $claimJson  = @{ iss = $sa.client_email; scope = 'https://www.googleapis.com/auth/analytics.readonly'; aud = $tokenUri; iat = $now; exp = $now + 3600 } | ConvertTo-Json -Compress
    $signingInput = (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($headerJson))) + "." + (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($claimJson)))
    $pemBody = ($sa.private_key -replace '-----BEGIN PRIVATE KEY-----', '' -replace '-----END PRIVATE KEY-----', '') -replace '\s', ''
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportPkcs8PrivateKey([Convert]::FromBase64String($pemBody), [ref]0) | Out-Null
    $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($signingInput), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $jwt = "$signingInput." + (ConvertTo-Base64Url $sig)
    $resp = Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30 -Body @{ grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer'; assertion = $jwt }
    if (-not $resp.access_token) { throw "OAuth returned no access_token." }
    return $resp.access_token
}

try {
    GaLog "INFO" "Collecting GA for $GaProperty (lssn=$Lssn)."
    $accessToken = Get-GaAccessToken $GaKeyFile

    $reportBody = @{
        dateRanges = @(@{ startDate = $GaRange; endDate = $GaRange })
        metrics    = @(@{ name = 'activeUsers' }, @{ name = 'sessions' }, @{ name = 'screenPageViews' }, @{ name = 'bounceRate' }, @{ name = 'conversions' }, @{ name = 'averageSessionDuration' })
    } | ConvertTo-Json -Depth 6
    $reportUrl = "https://analyticsdata.googleapis.com/v1beta/$GaProperty`:runReport"
    $report = Invoke-RestMethod -Method Post -Uri $reportUrl -Headers @{ Authorization = "Bearer $accessToken" } -ContentType 'application/json' -Body $reportBody -TimeoutSec 40

    $metrics = [ordered]@{}
    $headers = @($report.metricHeaders)
    $row0 = if ($report.rows) { @($report.rows)[0] } else { $null }
    if ($row0) {
        for ($i = 0; $i -lt $headers.Count; $i++) {
            $name = $headers[$i].name; $val = $row0.metricValues[$i].value; $num = 0.0
            if ([double]::TryParse($val, [ref]$num)) { $metrics[$name] = $num } else { $metrics[$name] = $val }
        }
    } else { GaLog "WARN" "runReport returned no rows." }

    $kValue = [ordered]@{
        propertyId  = $GaProperty
        range       = $GaRange
        metrics     = $metrics
        collectedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        source      = "giipAgentWin/cqe/ga-collect.cqe.ps1"
    }

    # --- POST GaPut to the byAK dispatcher (self-contained; no lib) ---
    $payload = @{ kKey = $GaProperty; kFactor = $GaFactor; kValue = $kValue } | ConvertTo-Json -Compress -Depth 10
    $form = "text=" + [uri]::EscapeDataString("GaPut kKey kFactor kValue") +
            "&token=" + [uri]::EscapeDataString($GiipToken) +
            "&jsondata=" + [uri]::EscapeDataString($payload)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $resp = Invoke-RestMethod -Method Post -Uri $GaDispatcher -ContentType 'application/x-www-form-urlencoded; charset=utf-8' -Body $form -TimeoutSec 30

    $ok = $false
    if ($resp) {
        $pm = $resp.Proc_MSG; if (-not $pm -and $resp.data) { $pm = $resp.data[0].Proc_MSG }
        if ("$pm" -match '^200' -or "$($resp.RstVal)" -eq '200') { $ok = $true }
    }
    if ($ok) { GaLog "INFO" "GaPut OK ($GaProperty)."; exit 0 }
    else { GaLog "ERROR" ("GaPut failed: " + ($resp | ConvertTo-Json -Compress -Depth 5)); exit 1 }
}
catch {
    GaLog "ERROR" "GA CQE collect failed: $_"
    exit 1
}
