# ============================================================================
# CqeGet.ps1
# Purpose: Fetch task from CQE API and save to data/queue.json
# Usage: .\CqeGet.ps1
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
}
catch {
    Write-Host "FATAL: Failed to load Common.ps1 from $LibDir"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
}
catch {
    Write-Host "FATAL: Failed to load configuration"
    exit 1
}

Write-GiipLog "INFO" "[CqeGet] Starting... LSSN=$($Config.lssn)"

# Prepare generic Windows info
# Prepare generic Windows info
$hostname = [System.Net.Dns]::GetHostName()
try {
    # [FIX] WMI Hang issue discovered 2026-01-14. Replaced with .NET Environment call.
    $os = "windows " + [System.Environment]::OSVersion.Version.ToString()
}
catch {
    $os = "windows (fallback)"
} 

# Prepare API Call
# CQEQueueGet payload
$jsondata = @{
    lssn     = $Config.lssn
    hostname = $hostname
    os       = $os
    op       = "op"
} | ConvertTo-Json -Compress

Write-GiipLog "INFO" "[CqeGet] Fetching queue..."

# Execute API Call (using Common.ps1 wrapper if available, or direct)
# Invoke-GiipApiV2 is defined in Common.ps1
try {
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "CQEQueueGet lssn hostname os op" -JsonData $jsondata
    
    if (-not $response) {
        Write-GiipLog "INFO" "[CqeGet] No response or null."
        exit 0
    }

    # Normalize Response (Handle wrapped object or direct array)
    $data = $null
    
    # Structure A: { data: [...] }
    if ($response.data) {
        if ($response.data.Count -gt 0) { $data = $response.data[0] }
    }
    # Structure B: Direct Object with RstVal
    elseif ($response.RstVal) {
        $data = $response
    }
    
    if (-not $data) {
        Write-GiipLog "INFO" "[CqeGet] No valid data in response."
        exit 0
    }

    # Check Logical Error (404 = No Queue is Normal)
    if ($data.RstVal -ne "200") {
        if ("$($data.RstVal)" -match "404" -or "$($data.ProcName)" -match "404") {
            Write-GiipLog "INFO" "[CqeGet] Queue empty (No task)."
            exit 0
        }
        Write-GiipLog "WARN" "[CqeGet] API Error: $($data.RstVal) - $($data.RstMsg)"
        exit 0
    }

    # Queue Found! Save to JSON
    Write-GiipLog "INFO" "[CqeGet] Task received! Saving to $QueueFile"
    
    # Save only the script content or full object? User requested data exchange via JSON.
    # We save the full task object.
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $QueueFile -Encoding UTF8
    
    Write-GiipLog "INFO" "[CqeGet] Success."
}
catch {
    Write-GiipLog "ERROR" "[CqeGet] Failed: $_"
    exit 1
}

exit 0
