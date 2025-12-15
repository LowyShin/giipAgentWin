# ============================================================================
# HostConnectionList.ps1
# Purpose: Collect active host connections (Netstat) for Net3D
# Usage: .\HostConnectionList.ps1
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "KVS.ps1")
}
catch {
    Write-Host "FATAL: Failed to load libraries from $LibDir"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
}
catch {
    Write-GiipLog "ERROR" "[HostConnectionList] Failed to load config: $_"
    exit 1
}

Write-GiipLog "INFO" "[HostConnectionList] Starting..."

try {
    # 1. Get TCP Connections (State: Established)
    # Note: Requires Windows 8 / Server 2012 or later
    $connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue

    if (-not $connections) {
        Write-GiipLog "INFO" "[HostConnectionList] No connections found or Get-NetTCPConnection unavailable."
        # Fallback logic could go here (classic netstat parsing), but skipping for now.
        exit 0
    }

    $report = @()

    foreach ($conn in $connections) {
        # Filter Loopback & Generic
        if ($conn.RemoteAddress -eq "127.0.0.1" -or $conn.RemoteAddress -eq "::1" -or $conn.RemoteAddress -eq "0.0.0.0") { continue }
        if ($conn.LocalAddress -eq "127.0.0.1" -or $conn.LocalAddress -eq "::1") { continue }

        # Resolve Process Name
        $procName = "Unknown"
        if ($conn.OwningProcess -gt 0) {
            $p = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($p) { $procName = $p.ProcessName }
        }

        # Build Object
        $report += @{
            local_ip     = $conn.LocalAddress
            local_port   = $conn.LocalPort
            remote_ip    = $conn.RemoteAddress
            remote_port  = $conn.RemotePort
            pid          = $conn.OwningProcess
            process_name = $procName
            state        = "ESTABLISHED"
            # Traffic volume per connection is not easily available via standard cmdlets
            # user_request: "Check traffic volume if possible". 
            # Result: Not possible per-connection without elevated perf counters/ETW.
            traffic      = $null 
        }
    }

    # Deduplicate if necessary? 
    # Netstat usually shows unique 4-tuples. No need to dedup unless aggregating.
    # Currently keeping full detail.

    if ($report.Count -gt 0) {
        Write-GiipLog "INFO" "[HostConnectionList] Found $($report.Count) active connections."
        
        # Send to API (KVS)
        # kType = 'server', kKey = LSSN, kFactor = 'netstat'
        $response = Invoke-GiipKvsPut -Config $Config -Type "server" -Key "$($Config.lssn)" -Factor "netstat" -Value $report

        if ($response.RstVal -eq "200") {
            Write-GiipLog "INFO" "[HostConnectionList] Success. Uploaded netstat data."
        }
        else {
            Write-GiipLog "WARN" "[HostConnectionList] Upload failed. Code: $($response.RstVal), Msg: $($response.RstMsg)"
        }
    }
    else {
        Write-GiipLog "INFO" "[HostConnectionList] No active external connections to report."
    }

}
catch {
    Write-GiipLog "ERROR" "[HostConnectionList] Unexpected error: $_"
}

Write-GiipLog "INFO" "[HostConnectionList] Completed."
exit 0
