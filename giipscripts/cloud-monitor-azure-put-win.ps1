# cloud-monitor-azure-put-win.ps1
# Purpose : Collect Azure resource inventory via Azure Resource Manager (az resource list),
#           save raw snapshot to GIIP KVS, and push resource list to GIIP DB via
#           CloudCollection / CloudResourceBatchUpsert SPs.
# Runs    : Standalone / independent of giipAgent3.ps1 module chain.
#           Register as its own 5-minute Scheduled Task with -Register.
# Auth    : Uses service principal from giipAgent.cfg (az_client_id / az_client_secret /
#           az_tenant_id) and az_subscription. Reuses the same credential pattern as
#           azure-cost-put-win.ps1.
# API     : CloudCollectionLeaseAcquire / CloudCollectionStart / CloudCollectionComplete /
#           CloudCollectionLeaseRenew / CloudCollectionLeaseRelease /
#           CloudResourceBatchUpsert (giipdb SP11, giip #1944/#1946).
# KVS     : lib/Kvs.ps1 -> Invoke-GiipKvsPut (kType='cloudinv').

param(
    [switch]$Register,
    [string]$ConnectionId,
    [string]$SubscriptionId,
    [string]$AgentKeyOverride
)

$ErrorActionPreference = "Stop"
if ($null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path $ScriptDir -Parent
$LibDir    = Join-Path $AgentRoot "lib"
$Global:BaseDir = $AgentRoot

. (Join-Path $LibDir "Common.ps1")
. (Join-Path $LibDir "Kvs.ps1")

$CmLogDir = Join-Path $AgentRoot "..\giipLogs\cloudmonitor"
if (-not (Test-Path $CmLogDir)) { New-Item -Path $CmLogDir -ItemType Directory -Force | Out-Null }
$RunLogFile = Join-Path $CmLogDir ("cloudmonitor_task_{0}.log" -f (Get-Date).ToString("yyyyMMdd"))

function Write-TaskLog {
    param([string]$Level, [string]$Message)
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-GiipLog $Level $Message
    Add-Content -Path $RunLogFile -Value $line -Encoding UTF8
}

if ($Register) {
    $self = $MyInvocation.MyCommand.Path
    $taskName = "GIIP Cloud Monitor Azure Collector"
    $arg = "-NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$self`""
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-TaskLog "INFO" "Registered Scheduled Task '$taskName' (every 5 minutes)."
    return
}

# Self-update
try {
    $gitDir = Join-Path $AgentRoot ".git"
    if (Test-Path $gitDir) {
        Push-Location $AgentRoot
        try {
            $dirty = git status --porcelain 2>$null
            if ([string]::IsNullOrWhiteSpace($dirty)) {
                git fetch origin main --quiet 2>$null
                $behind = git rev-list --count "HEAD..origin/main" 2>$null
                if ($behind -and [int]$behind -gt 0) {
                    $before = git rev-parse --short HEAD
                    git pull --ff-only origin main --quiet 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $after = git rev-parse --short HEAD
                        Write-TaskLog "INFO" "Self-update: $before -> $after ($behind commit(s) pulled)"
                    }
                }
            }
        } finally { Pop-Location }
    }
} catch {
    Write-TaskLog "WARN" "Self-update check failed: $($_.Exception.Message)"
}

function Resolve-CloudMonitorAgentKey {
    param($Config)
    if ($Config -and $Config["cloudmonitor_agentkey"]) { return $Config["cloudmonitor_agentkey"] }
    $cacheFile = Join-Path $AgentRoot "..\.giip_cloudmonitor_agentkey"
    if (Test-Path $cacheFile) {
        try {
            $cached = (Get-Content -Path $cacheFile -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
            if ($cached) { return $cached }
        } catch {}
    }
    $hn = $env:COMPUTERNAME
    if (-not $hn) { $hn = "unknown-host" }
    $guidPart = $null
    try {
        $mg = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($mg) {
            $clean = $mg -replace "-", ""
            $guidPart = $clean.Substring(0, [Math]::Min(12, $clean.Length))
        }
    } catch {}
    if ($guidPart) { $key = "$hn-$guidPart" } else { $key = "$hn-" + ([guid]::NewGuid().ToString("N").Substring(0, 12)) }
    try {
        $dir = Split-Path -Path $cacheFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $cacheFile -Value $key -Encoding UTF8 -NoNewline
    } catch {}
    return $key
}

function Invoke-AzureContainerInstanceProbe {
    param([string]$ResourceId)
    $checkedAt = (Get-Date).ToString("s")
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $json = az rest --method get --url "https://management.azure.com$ResourceId`?api-version=2023-05-01" --only-show-errors --output json 2>$null
        $sw.Stop()
        if ($LASTEXITCODE -ne 0 -or -not $json) {
            return [PSCustomObject]@{ probe_state="UNKNOWN"; latency_ms=$null; checked_at=$checkedAt; detail="ARM GET failed" }
        }
        $obj = $json | ConvertFrom-Json
        $state = $obj.properties.instanceView.state
        $probeState = switch -Regex ($state) {
            "Running"            { "UP" }
            "Terminated|Failed"  { "DOWN" }
            default              { "DEGRADED" }
        }
        return [PSCustomObject]@{ probe_state=$probeState; latency_ms=$sw.ElapsedMilliseconds; checked_at=$checkedAt; detail=$state }
    } catch {
        return [PSCustomObject]@{ probe_state="UNKNOWN"; latency_ms=$null; checked_at=$checkedAt; detail=$_.Exception.Message }
    }
}

try {

    $Config = Get-GiipConfig
    if (-not $Config.lssn) { Write-TaskLog "ERROR" "lssn missing in giipAgent.cfg"; exit 1 }

    if (-not $ConnectionId) { $ConnectionId = $Config.cloud_connection_id }
    if (-not $ConnectionId) {
        Write-TaskLog "ERROR" "cloud_connection_id not configured. Run the bootstrap step first."
        exit 1
    }

    $AgentKey = if ($AgentKeyOverride) { $AgentKeyOverride } else { Resolve-CloudMonitorAgentKey -Config $Config }
    Write-TaskLog "INFO" "Using agentKey: $AgentKey"

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-TaskLog "ERROR" "Azure CLI (az) not found."
        exit 1
    }

    if ($Config.az_client_id -and $Config.az_client_secret -and $Config.az_tenant_id) {
        Write-TaskLog "INFO" "Logging in with service principal ($($Config.az_client_id))."
        az login --service-principal --username $Config.az_client_id --password $Config.az_client_secret --tenant $Config.az_tenant_id --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { Write-TaskLog "ERROR" "az login failed"; exit 1 }
    }

    if (-not $SubscriptionId) { $SubscriptionId = $Config.az_subscription }
    if ($SubscriptionId) {
        az account set --subscription $SubscriptionId --only-show-errors
        if ($LASTEXITCODE -ne 0) { Write-TaskLog "ERROR" "az account set failed"; exit 1 }
    }
    $acct = az account show --only-show-errors --output json 2>$null | ConvertFrom-Json
    if (-not $acct) { Write-TaskLog "ERROR" "No active Azure account"; exit 1 }
    $subId   = $acct.id
    $subName = $acct.name
    Write-TaskLog "INFO" "Using subscription: $subName ($subId)"

    # Lease Acquire
    $leaseAcquireJson = (@{ connection_id=$ConnectionId; scope_id=0; holder=$AgentKey } | ConvertTo-Json -Compress)
    $leaseResp = Invoke-GiipApiV2 -Config $Config -CommandText "CloudCollectionLeaseAcquire connection_id scope_id holder" -JsonData $leaseAcquireJson

    if ($leaseResp.RstVal -eq 409) {
        Write-TaskLog "INFO" "Lease held by another agent - skipping."
        exit 0
    }
    if ($leaseResp.RstVal -ne 200) {
        Write-TaskLog "ERROR" "Lease acquire failed: $($leaseResp.RstMsg)"
        exit 1
    }
    $leaseId = $leaseResp.lease_id
    Write-TaskLog "INFO" "Lease acquired: lease_id=$leaseId"

    try {

        # Collection Start
        $collStartJson = (@{ connection_id=$ConnectionId; scope_id=$null; collector_agent_key=$AgentKey } | ConvertTo-Json -Compress)
        $collResp = Invoke-GiipApiV2 -Config $Config -CommandText "CloudCollectionStart connection_id scope_id collector_agent_key" -JsonData $collStartJson

        if ($collResp.RstVal -ne 200) {
            Write-TaskLog "ERROR" "Collection start failed: $($collResp.RstMsg)"
            exit 1
        }
        $collectionId = $collResp.collection_id
        Write-TaskLog "INFO" "Collection started: collection_id=$collectionId"

        # Bulk Inventory: az resource list
        $tmpOut = Join-Path $env:TEMP ("cm_resource_list_{0}.txt" -f (Get-Date).ToString("yyyyMMddHHmmssfff"))
        $tmpErr = Join-Path $env:TEMP ("cm_resource_list_err_{0}.txt" -f (Get-Date).ToString("yyyyMMddHHmmssfff"))

        $proc = Start-Process -FilePath "az" -ArgumentList @("resource","list","--subscription",$subId,"--output","json") -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr

        $outText = if (Test-Path $tmpOut) { Get-Content -Path $tmpOut -Raw -ErrorAction SilentlyContinue } else { "" }
        $errText = if (Test-Path $tmpErr) { Get-Content -Path $tmpErr -Raw -ErrorAction SilentlyContinue } else { "" }
        Remove-Item $tmpOut, $tmpErr -ErrorAction SilentlyContinue

        $rawJson = ("$outText`n$errText").Trim()
        $resources = $null
        $providerFailed = $false
        $providerErrorMsg = ""

        if ($proc.ExitCode -ne 0 -or -not $rawJson) {
            $providerFailed = $true
            $providerErrorMsg = if ($errText) { $errText.Substring(0, [Math]::Min(2000, $errText.Length)) } else { "az resource list failed $($proc.ExitCode)" }
            Write-TaskLog "ERROR" "az resource list failed: $providerErrorMsg"
        } else {
            try {
                $resources = $rawJson | ConvertFrom-Json
                if (-not ($resources -is [array])) { $resources = @($resources) }
                Write-TaskLog "INFO" "az resource list returned $($resources.Count) resources."
            } catch {
                $providerFailed = $true
                $providerErrorMsg = "JSON parse failed: $($_.Exception.Message)"
                Write-TaskLog "ERROR" "Failed to parse az resource list output: $providerErrorMsg"
            }
        }

        if ($providerFailed) {
            $failCollJson = (@{ collection_id=$collectionId; status="FAILED"; total_count=$null; upsert_count=0; missing_count=0; raw_kvs_ksn=$null; error_message=$providerErrorMsg } | ConvertTo-Json -Compress)
            $failCollResp = Invoke-GiipApiV2 -Config $Config -CommandText "CloudCollectionComplete collection_id status total_count upsert_count missing_count raw_kvs_ksn error_message" -JsonData $failCollJson
            Write-TaskLog "ERROR" "Collection complete (FAILED) recorded."
            exit 1
        }

        # Raw Snapshot to KVS (compact: metadata + id/name/type list only, not full objects)
        $resourceSummary = foreach ($r in $resources) {
            [PSCustomObject]@{
                id   = $r.id
                name = $r.name
                type = $r.type
            }
        }
        $rawValue = [PSCustomObject]@{
            subscription_id   = $subId
            subscription_name = $subName
            collected_at      = (Get-Date).ToString("s")
            resource_count    = $resources.Count
            resources         = $resourceSummary
        }
        $kvsResp = Invoke-GiipKvsPut -Config $Config -Type "cloudinv" -Key "$ConnectionId" -Factor "$collectionId" -Value $rawValue
        if ($kvsResp -and ($kvsResp.RstVal -eq 200 -or $kvsResp.RstVal -eq "200")) {
            Write-TaskLog "INFO" "Raw snapshot saved to KVS (collection_id=$collectionId)."
        } else {
            $kvsRst = if ($kvsResp) { $kvsResp.RstVal } else { "no-response" }
            Write-TaskLog "WARN" "KVS put failed (RstVal=$kvsRst); continuing."
        }

        # Lease Renew
        $leaseRenewJson = (@{ lease_id=$leaseId } | ConvertTo-Json -Compress)
        $leaseRenewResp = Invoke-GiipApiV2 -Config $Config -CommandText "CloudCollectionLeaseRenew lease_id" -JsonData $leaseRenewJson
        if ($leaseRenewResp.RstVal -eq 200) {
            Write-TaskLog "INFO" "Lease renewed (expires_at=$($leaseRenewResp.expires_at))."
        } else {
            Write-TaskLog "WARN" "Lease renew failed (RstVal=$($leaseRenewResp.RstVal)); continuing."
        }

        # Container Instance Probe
        $aciResources = @($resources | Where-Object { $_.type -eq "Microsoft.ContainerInstance/containerGroups" })
        if ($aciResources.Count -gt 0) {
            Write-TaskLog "INFO" "Running Container Instance Probe on $($aciResources.Count) ACI resources."
            foreach ($aci in $aciResources) {
                $probeResult = Invoke-AzureContainerInstanceProbe -ResourceId $aci.id
                $originalState = $aci.provisioningState
                if ($probeResult.probe_state -eq "UP") {
                    $aci | Add-Member -NotePropertyName "provisioningState" -NotePropertyValue "Running(probed)" -Force
                } elseif ($probeResult.probe_state -eq "DOWN") {
                    $aci | Add-Member -NotePropertyName "provisioningState" -NotePropertyValue "Terminated(probed)" -Force
                }
                Write-TaskLog "DEBUG" "ACI probe $($aci.id): $originalState -> $($probeResult.probe_state)"
            }
        }

        # Map resources to BatchUpsert schema
        $mappedResources = foreach ($r in $resources) {
            $tagsJson = @{
                resourceGroup = if ($r.resourceGroup) { $r.resourceGroup } else { $null }
                tags = if ($r.tags -and $r.tags -is [hashtable]) { $r.tags } else { @{} }
            }
            [PSCustomObject]@{
                external_resource_id = $r.id
                resource_type        = $r.type
                resource_name        = $r.name
                region               = if ($r.location) { $r.location } else { $null }
                provider_state       = if ($r.provisioningState) { $r.provisioningState } else { $null }
                scope_id             = $null
                tags_json            = $tagsJson
            }
        }

        # Resource BatchUpsert (chunked to avoid URI length limits)
        $chunkSize = 30
        $totalUpsert = 0
        $totalMissing = 0
        $batchFailed = $false
        $batchErrorMsg = ""
        for ($i = 0; $i -lt $mappedResources.Count; $i += $chunkSize) {
            $chunk = $mappedResources[$i..[Math]::Min($i+$chunkSize-1, $mappedResources.Count-1)]
            $batchJson = (@{
                connection_id  = $ConnectionId
                collection_id  = $collectionId
                resources_json = @($chunk)
            } | ConvertTo-Json -Depth 10 -Compress)
            $upsertResp = Invoke-GiipApiV2 -Config $Config -CommandText "CloudResourceBatchUpsert connection_id collection_id resources_json" -JsonData $batchJson
            if ($upsertResp.RstVal -ne 200) {
                $batchFailed = $true
                $batchErrorMsg = "BatchUpsert chunk $($i/$chunkSize+1) failed: $($upsertResp.RstMsg)"
                Write-TaskLog "ERROR" $batchErrorMsg
                break
            }
            $totalUpsert += $upsertResp.upsert_count
            $totalMissing += $upsertResp.missing_count
        }

        if ($batchFailed) {
            $failCollJson2 = (@{ collection_id=$collectionId; status="FAILED"; total_count=$resources.Count; upsert_count=0; missing_count=0; raw_kvs_ksn=$null; error_message=$batchErrorMsg } | ConvertTo-Json -Compress)
            $failCollResp2 = Invoke-GiipApiV2 -Config $Config -CommandText "CloudCollectionComplete collection_id status total_count upsert_count missing_count raw_kvs_ksn error_message" -JsonData $failCollJson2
            exit 1
        }

        # Collection Complete (SUCCEEDED)
        $completeJson = (@{
            collection_id   = $collectionId
            status          = "SUCCEEDED"
            total_count     = $resources.Count
            upsert_count    = $totalUpsert
            missing_count   = $totalMissing
            raw_kvs_ksn     = $null
            error_message   = $null
        } | ConvertTo-Json -Compress)
        $completeResp = Invoke-GiipApiV2 -Config $Config -CommandText "CloudCollectionComplete collection_id status total_count upsert_count missing_count raw_kvs_ksn error_message" -JsonData $completeJson

        Write-TaskLog "INFO" "Collection $collectionId complete: total=$($resources.Count) upsert=$totalUpsert missing=$totalMissing"
        exit 0

    } finally {
        $leaseReleaseJson = (@{ lease_id=$leaseId } | ConvertTo-Json -Compress)
        $leaseReleaseResp = Invoke-GiipApiV2 -Config $Config -CommandText "CloudCollectionLeaseRelease lease_id" -JsonData $leaseReleaseJson
        if ($leaseReleaseResp.RstVal -eq 200) {
            Write-TaskLog "INFO" "Lease released: lease_id=$leaseId"
        } else {
            Write-TaskLog "WARN" "Lease release returned RstVal=$($leaseReleaseResp.RstVal)"
        }
    }

} catch {
    Write-TaskLog "ERROR" "Unhandled failure: $($_.Exception.Message)"
    exit 1
}
