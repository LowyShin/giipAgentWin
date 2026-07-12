# ============================================================================
# azure-cost-put-win.ps1
# Purpose : Collect Azure usage & cost via Azure Cost Management API (az rest),
#           save as JSON, and push the summary to GIIP KVS (kFactor="azure_cost").
# Runs    : Standalone / independent of giipAgent3.ps1 module chain.
#           Register as its own daily Scheduled Task with -Register.
# Auth    : Uses the current 'az login' context, OR a service principal from
#           giipAgent.cfg (az_client_id / az_client_secret / az_tenant_id).
# API     : POST .../providers/Microsoft.CostManagement/query (works for MCA/EA/PAYG;
#           az consumption usage list returns 'None' costs on MCA and is NOT used).
# KVS     : lib/Kvs.ps1 -> Invoke-GiipKvsPut. jsondata MUST carry kValue (real data),
#           otherwise the server stores an empty {} while returning 200 (silent loss).
# ============================================================================

[CmdletBinding()]
param(
    [switch]$Register,               # Register a daily Scheduled Task and exit
    [string]$AtTime = "06:00",       # Daily run time (for -Register)
    [string]$SubscriptionId,         # Target subscription (else cfg az_subscription / current)
    [int]$Days = 0,                  # Last N days (Custom); 0 = MonthToDate
    [string]$Factor = "azure_cost",  # KVS kFactor
    [string]$OutFile                 # Raw JSON output path (else giipLogs\azure\...)
)

$ErrorActionPreference = "Stop"

# --- Resolve paths and load shared libraries ---------------------------------
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path $ScriptDir -Parent            # giipscripts -> giipAgentWin
$LibDir    = Join-Path $AgentRoot "lib"
$Global:BaseDir = $AgentRoot                                # so Get-GiipConfig finds ../giipAgent.cfg

. (Join-Path $LibDir "Common.ps1")   # Get-GiipConfig, Invoke-GiipApiV2, Write-GiipLog
. (Join-Path $LibDir "Kvs.ps1")      # Invoke-GiipKvsPut

# --- -Register: install a daily Scheduled Task for this script and exit -------
if ($Register) {
    $self = $MyInvocation.MyCommand.Path
    $taskName = "GIIP Azure Cost Collector"
    $arg = "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$self`""
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -Daily -At $AtTime
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-GiipLog "INFO" "Registered Scheduled Task '$taskName' (daily at $AtTime)."
    return
}

# --- Load config -------------------------------------------------------------
$Config = Get-GiipConfig
if (-not $Config.lssn) { Write-GiipLog "ERROR" "lssn missing in giipAgent.cfg. Aborting."; exit 1 }

# --- Ensure Azure CLI is available -------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-GiipLog "ERROR" "Azure CLI (az) not found in PATH. Install it or run 'az login' first."
    exit 1
}

# --- Optional: service-principal login (non-interactive scheduled runs) -------
if ($Config.az_client_id -and $Config.az_client_secret -and $Config.az_tenant_id) {
    Write-GiipLog "INFO" "Logging in with service principal ($($Config.az_client_id))."
    az login --service-principal --username $Config.az_client_id --password $Config.az_client_secret --tenant $Config.az_tenant_id --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { Write-GiipLog "ERROR" "az service-principal login failed."; exit 1 }
}

# --- Resolve subscription ----------------------------------------------------
if (-not $SubscriptionId) { $SubscriptionId = $Config.az_subscription }
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { Write-GiipLog "ERROR" "az account set failed for $SubscriptionId."; exit 1 }
}
$acct = az account show --only-show-errors --output json 2>$null | ConvertFrom-Json
if (-not $acct) { Write-GiipLog "ERROR" "No active Azure account. Run 'az login' or set service-principal creds."; exit 1 }
$subId   = $acct.id
$subName = $acct.name

# --- Resolve shared timeframe once (both axes use the same period) ------------
$today = Get-Date
if ($Days -gt 0) {
    $from = $today.AddDays(-$Days).ToString("yyyy-MM-ddT00:00:00+00:00")
    $to   = $today.ToString("yyyy-MM-ddT23:59:59+00:00")
    $timeframe  = "Custom"
    $timePeriod = @{ from = $from; to = $to }
    $periodDesc = "$from .. $to"
} else {
    $timeframe  = "MonthToDate"
    $timePeriod = $null
    $periodDesc = "MonthToDate"
}

$url = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- Cost Management query helper (grouped by a single dimension) --------------
# Runs one ActualCost query grouped by $GroupDimension over the shared timeframe.
# Cost Management enforces strict 429 rate limits -> retry up to 5x, 35s backoff.
# az rest --body @file avoids shell-quoting issues (BOM-less UTF-8 temp file).
# Returns @{ Raw = <json string>; Result = <parsed object> }, or hard-exits(1).
function Invoke-CmQuery {
    param([Parameter(Mandatory)][string]$GroupDimension)

    $dataset = @{
        granularity = "None"
        aggregation = @{ totalCost = @{ name = "PreTaxCost"; function = "Sum" } }
        grouping    = @( @{ type = "Dimension"; name = $GroupDimension } )
    }
    $bodyObj = @{ type = "ActualCost"; timeframe = $timeframe; dataset = $dataset }
    if ($timePeriod) { $bodyObj.timePeriod = $timePeriod }
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 10 -Compress

    $tmpBody = Join-Path $env:TEMP ("az_cm_body_{0}_{1}.json" -f $GroupDimension, $today.ToString("yyyyMMddHHmmssfff"))
    [System.IO.File]::WriteAllText($tmpBody, $bodyJson, $utf8NoBom)

    Write-GiipLog "INFO" "Querying Cost Management ($GroupDimension) for $subName ($subId): $periodDesc"
    $rawJson = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $rawJson = (az rest --method post --url $url --headers "Content-Type=application/json" --body "@$tmpBody" --only-show-errors --output json 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $rawJson -notmatch '"?429"?') { break }
        if ($rawJson -match '429') {
            Write-GiipLog "WARN" "Rate-limited (429) on $GroupDimension. Retry $attempt/5 after 35s."
            Start-Sleep -Seconds 35
            continue
        }
        Write-GiipLog "ERROR" "Cost Management query ($GroupDimension) failed: $rawJson"
        Remove-Item $tmpBody -ErrorAction SilentlyContinue
        exit 1
    }
    Remove-Item $tmpBody -ErrorAction SilentlyContinue
    if (-not $rawJson -or $rawJson -match '429') { Write-GiipLog "ERROR" "Cost Management query ($GroupDimension) still failing (429)."; exit 1 }

    return @{ Raw = $rawJson; Result = ($rawJson | ConvertFrom-Json) }
}

# --- Query #1: by ServiceName (existing axis -> by_service) -------------------
$svcQ   = Invoke-CmQuery -GroupDimension "ServiceName"
$rawJson = $svcQ.Raw
$result  = $svcQ.Result
$cols = @($result.properties.columns.name)
$rows = @($result.properties.rows)

$iCost = [array]::IndexOf($cols, "PreTaxCost")
$iSvc  = [array]::IndexOf($cols, "ServiceName")
$iCur  = [array]::IndexOf($cols, "Currency")
if ($iCost -lt 0) { Write-GiipLog "ERROR" "Unexpected response shape (no PreTaxCost column)."; exit 1 }

# --- Save raw JSON (UTF-8, no BOM) — service-axis dump is the canonical raw ----
if (-not $OutFile) {
    $azDir = Join-Path $AgentRoot "..\giipLogs\azure"
    if (-not (Test-Path $azDir)) { New-Item -Path $azDir -ItemType Directory -Force | Out-Null }
    $OutFile = Join-Path $azDir ("azure_cost_{0}_{1}.json" -f $subId, $today.ToString("yyyyMMdd"))
}
[System.IO.File]::WriteAllText($OutFile, $rawJson, $utf8NoBom)
Write-GiipLog "INFO" "Saved raw cost JSON ($($rows.Count) service rows) -> $OutFile"

# --- Query #2: by ResourceGroupName (new axis -> by_resource_group) -----------
# Feeds giipv3 azure-cost-rg/page.tsx (by_resource_group[{resource_group,cost}] + resource_group_count).
$rgQ      = Invoke-CmQuery -GroupDimension "ResourceGroupName"
$rgResult = $rgQ.Result
$rgCols   = @($rgResult.properties.columns.name)
$rgRows   = @($rgResult.properties.rows)
$iRgCost  = [array]::IndexOf($rgCols, "PreTaxCost")
$iRg      = [array]::IndexOf($rgCols, "ResourceGroupName")
if ($iRg -lt 0) { $iRg = [array]::IndexOf($rgCols, "ResourceGroup") }  # API shape fallback

$byResourceGroup = @()
if ($iRgCost -ge 0) {
    $rgList = foreach ($row in $rgRows) {
        $rgName = if ($iRg -ge 0 -and $row[$iRg]) { [string]$row[$iRg] } else { "" }
        [PSCustomObject]@{
            resource_group = if ($rgName) { $rgName } else { "(unassigned)" }  # costs with no RG
            cost           = [math]::Round([double]$row[$iRgCost], 4)
        }
    }
    $byResourceGroup = @($rgList | Sort-Object cost -Descending)
} else {
    Write-GiipLog "WARN" "ResourceGroupName query returned no PreTaxCost column; by_resource_group left empty."
}
Write-GiipLog "INFO" "Collected $($byResourceGroup.Count) resource-group rows."

# --- Summarize (this becomes kValue) -----------------------------------------
$services = foreach ($row in $rows) {
    [PSCustomObject]@{
        service = if ($iSvc -ge 0) { $row[$iSvc] } else { "All" }
        cost    = [math]::Round([double]$row[$iCost], 4)
    }
}
$services = @($services | Sort-Object cost -Descending)
$total = 0.0
foreach ($row in $rows) { $total += [double]$row[$iCost] }
$currency = if ($rows.Count -gt 0 -and $iCur -ge 0) { $rows[0][$iCur] } else { $null }

$summary = [PSCustomObject]@{
    subscription_id      = $subId
    subscription_name    = $subName
    period               = $periodDesc
    currency             = $currency
    total_pretax_cost    = [math]::Round($total, 4)
    service_count        = $services.Count
    by_service           = $services
    resource_group_count = $byResourceGroup.Count
    by_resource_group    = $byResourceGroup
    collected_at         = $today.ToString("s")
}

# --- Push to GIIP KVS --------------------------------------------------------
Write-GiipLog "INFO" "Pushing azure_cost to KVS (lssn=$($Config.lssn), total=$($summary.total_pretax_cost) $currency)."
$resp = Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor $Factor -Value $summary

if ($resp -and $resp.RstVal -eq "200") {
    Write-GiipLog "INFO" "Azure cost uploaded successfully."
} else {
    $rv = if ($resp) { $resp.RstVal } else { "no-response" }
    Write-GiipLog "ERROR" "KVS put failed (RstVal=$rv)."
    exit 1
}
