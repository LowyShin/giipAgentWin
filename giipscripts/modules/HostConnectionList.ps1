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

    # 1. Get TCP Connections (State: Established, Listen)
    # Note: Requires Windows 8 / Server 2012 or later
    # ⚠️ Security Note: Include LISTEN state to detect potential backdoors/threats
    # ⚠️ Performance Note: Limit to 2000 to prevent data bloat
    $TopConnections = 2000
    $connections = Get-NetTCPConnection -State Established, Listen -ErrorAction SilentlyContinue | Select-Object -First $TopConnections

    if (-not $connections) {
        Write-GiipLog "INFO" "[HostConnectionList] No connections found or Get-NetTCPConnection unavailable."
        # Fallback logic could go here (classic netstat parsing), but skipping for now.
        exit 0
    }

    # ============================================================================
    # 🔍 [NEW] ENRICHMENT: Local SQL Server Session Check
    # ============================================================================
    $SqlSessionMap = @{}
    $isSqlSvrRunning = Get-Process -Name "sqlservr" -ErrorAction SilentlyContinue
    if ($isSqlSvrRunning) {
        Write-GiipLog "DEBUG" "Local SQL Server detected. Attempting to fetch session map for query_hash enrichment."
        try {
            # Use LocalHost with Integrated Security
            $sqlConnStr = "Server=.;Database=master;Integrated Security=True;Connection Timeout=5;"
            $sqlConn = New-Object System.Data.SqlClient.SqlConnection($sqlConnStr)
            $sqlConn.Open()
            
            $sqlCmd = $sqlConn.CreateCommand()
            # Note: We join with dm_exec_requests to get the ACTIVE query_hash.
            # If the session is idle, it won't be in dm_exec_requests.
            $sqlCmd.CommandText = @"
                SELECT 
                    c.client_net_address,
                    c.client_tcp_port,
                    CONVERT(NVARCHAR(64), r.query_hash, 1) as query_hash,
                    CONVERT(NVARCHAR(130), r.sql_handle, 1) as sql_handle,
                    CONVERT(NVARCHAR(130), r.plan_handle, 1) as plan_handle,
                    c.local_tcp_port
                FROM sys.dm_exec_connections c WITH(NOLOCK)
                JOIN sys.dm_exec_requests r WITH(NOLOCK) ON c.session_id = r.session_id
                WHERE c.net_transport = 'TCP'
"@
            $sqlReader = $sqlCmd.ExecuteReader()
            while ($sqlReader.Read()) {
                $cAddr = $sqlReader["client_net_address"].ToString().Trim()
                $cPort = $sqlReader["client_tcp_port"].ToString()
                $qHash = $sqlReader["query_hash"].ToString()
                $sHandle = $sqlReader["sql_handle"].ToString()
                $pHandle = $sqlReader["plan_handle"].ToString()
                $lPort = $sqlReader["local_tcp_port"].ToString()
                
                # Use "address:port" as key for precise matching (IP:Port standard)
                if ($cAddr -and $cPort) {
                    $SqlSessionMap["$($cAddr):$($cPort)"] = @{ 
                        hash        = $qHash 
                        sql_handle  = $sHandle 
                        plan_handle = $pHandle 
                        localPort   = $lPort 
                    }
                }
            }
            $sqlReader.Close()
            $sqlConn.Close()
            Write-GiipLog "DEBUG" ("Successfully mapped $($SqlSessionMap.Count) active SQL sessions.")
        }
        catch {
            Write-GiipLog "WARN" "Failed to fetch local SQL session map: $($_.Exception.Message)"
        }
    }
    # ============================================================================

    $report = @()

    foreach ($conn in $connections) {
        # Filter Loopback & Generic
        # Keep LISTEN sockets even if RemoteAddress is wildcard (0.0.0.0 or ::)
        if ($conn.RemoteAddress -eq "127.0.0.1" -or $conn.RemoteAddress -eq "::1") { continue }
        if ($conn.LocalAddress -eq "127.0.0.1" -or $conn.LocalAddress -eq "::1") { continue }

        # Resolve Process Name
        $procName = "Unknown"
        if ($conn.OwningProcess -gt 0) {
            $p = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($p) { $procName = $p.ProcessName }
        }

        # Build Object
        # Determine if this row can be enriched with query metadata
        $qHash = ""
        $sqlHandle = ""
        $planHandle = ""
        if ($SqlSessionMap.Count -gt 0) {
            $key = "$($conn.RemoteAddress):$($conn.RemotePort)"
            if ($SqlSessionMap.ContainsKey($key)) {
                # Verify local port matches to ensure we aren't matching a different service
                if ($conn.LocalPort -eq $SqlSessionMap[$key].localPort) {
                    $qHash = $SqlSessionMap[$key].hash
                    $sqlHandle = $SqlSessionMap[$key].sql_handle
                    $planHandle = $SqlSessionMap[$key].plan_handle
                }
            }
        }

        $report += @{
            local_ip     = $conn.LocalAddress
            local_port   = $conn.LocalPort
            remote_ip    = $conn.RemoteAddress
            remote_port  = $conn.RemotePort
            pid          = $conn.OwningProcess
            process_name = $procName
            state        = $conn.State.ToString().ToUpper()
            traffic      = $null
            query_hash   = $qHash
            sql_handle   = $sqlHandle
            plan_handle  = $planHandle
        }
    }

    # Deduplicate if necessary? 
    # Netstat usually shows unique 4-tuples. No need to dedup unless aggregating.
    # Currently keeping full detail.

    if ($report.Count -gt 0) {
        Write-GiipLog "INFO" "[HostConnectionList] Found $($report.Count) active connections."
        
        # Send to API (KVS)
        $response = Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "netstat" -Value $report

        # 🚀 Report status to Agent Work Explorer
        $workStatus = if ($response.RstVal -eq "200") { "success" } else { "fail" }
        $workMsg = if ($response.RstVal -eq "200") { "Uploaded $($report.Count) connections." } else { "Upload failed: $($response.RstMsg)" }
        
        Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "host_connection_check" -Value @{
            status    = $workStatus
            message   = $workMsg
            exit_code = if ($response.RstVal -eq "200") { 0 } else { 1 }
        } | Out-Null

        if ($response.RstVal -eq "200") {
            Write-GiipLog "INFO" "[HostConnectionList] Success. Uploaded netstat data."
        }
        else {
            Write-GiipLog "WARN" "[HostConnectionList] Upload failed. Code: $($response.RstVal), Msg: $($response.RstMsg)"
        }
    }
    else {
        Write-GiipLog "INFO" "[HostConnectionList] No active external connections to report."
        
        # Report "success" but empty to KVS
        Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "host_connection_check" -Value @{
            status    = "success"
            message   = "No active external connections found."
            exit_code = 0
        } | Out-Null
    }

}
catch {
    Write-GiipLog "ERROR" "[HostConnectionList] Unexpected error: $_"
    # Report failure to KVS
    try {
        Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "host_connection_check" -Value @{
            status    = "fail"
            message   = "Exception: $_"
            exit_code = 1
        } | Out-Null
    }
    catch {}
}

Write-GiipLog "INFO" "[HostConnectionList] Completed."
exit 0
