# ============================================================================
# CqeGet.ps1 (Restored Pure ASCII Version)
# Purpose: Fetch task from CQE API and save to data/queue.json
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"
$DataDir = Join-Path $AgentRoot "data"
$QueueFile = Join-Path $DataDir "queue.json"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
} catch {
    Write-Host "FATAL: Failed to load Common.ps1"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
} catch {
    Write-Host "FATAL: Failed to load configuration"
    exit 1
}

Write-GiipLog "INFO" "[CqeGet] Starting... LSSN=$($Config.lssn)"

# Prepare generic Windows info
$hostname = [System.Net.Dns]::GetHostName()
$os = "windows " + [System.Environment]::OSVersion.Version.ToString()

# Prepare API Call
$jsondata = @{
    lssn     = $Config.lssn
    hostname = $hostname
    os       = $os
    op       = "op"
} | ConvertTo-Json -Compress

Write-GiipLog "INFO" "[CqeGet] Fetching queue..."

try {
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "CQEQueueGet lssn hostname os op" -JsonData $jsondata
    
    if (-not $response) {
        Write-GiipLog "INFO" "[CqeGet] No response."
        exit 0
    }

    $data = $null
    if ($response.data) {
        if ($response.data.Count -gt 0) { $data = $response.data[0] }
    } elseif ($response.RstVal) {
        $data = $response
    }
    
    if (-not $data) {
        Write-GiipLog "INFO" "[CqeGet] No valid data in response."
        exit 0
    }

    # 404 = No Queue
    if ($data.RstVal -ne "200") {
        if ("$($data.RstVal)" -match "404") {
            Write-GiipLog "INFO" "[CqeGet] Queue empty."
            exit 0
        }
        Write-GiipLog "WARN" "[CqeGet] API Error: $($data.RstVal)"
        exit 0
    }

    # Save to JSON (ASCII format for absolute stability)
    Write-GiipLog "INFO" "[CqeGet] Task received! Saving to $QueueFile"
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $QueueFile -Encoding ASCII
} catch {
    Write-GiipLog "ERROR" "[CqeGet] Failed: $_"
    exit 1
}

exit 0
