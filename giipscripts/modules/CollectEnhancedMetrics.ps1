# ============================================================================
# CollectEnhancedMetrics.ps1
# Purpose: Collect detailed CPU, Memory, Disk Partitions, IO, Network, and Top Processes
#          on Windows in JSON format and upload to KVS using same factors as Linux.
# Usage: .\CollectEnhancedMetrics.ps1
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"

# Buffer retention caps (giip #3560) -- keep buffered payloads from accumulating
# indefinitely when KVS stays unreachable for a long time.
$BufferRetentionDays = 7
$BufferMaxCount = 500

# giip #6162: upper bound (seconds) applied to every CIM/WMI query below.
# A WMI provider that stops responding used to block the call forever, and
# that single hang stalled the whole agent cycle -- each metric section is
# now isolated in its own try/catch so a timeout only skips that section.
$CimTimeoutSec = 30

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
    Write-GiipLog "ERROR" "[CollectEnhancedMetrics] Failed to load config: $_"
    exit 1
}

Write-GiipLog "INFO" "[CollectEnhancedMetrics] Starting detailed performance metrics collection..."

# ============================================================================
# Buffer resend (giip #3560): re-upload payloads that previous runs buffered
# locally after KVS was unreachable. Runs BEFORE collecting new metrics so that
# a recovered network flushes the backlog oldest-first. This block never aborts
# the script (no exit 1) and is wrapped in try/catch so a single bad file cannot
# break metrics collection -- failed files stay for the next run to retry.
# ============================================================================
try {
    $resendDir = Join-Path $AgentRoot "giipLogs/payloads"
    if (Test-Path $resendDir) {
        # Oldest first: filenames embed a yyyyMMdd_HHmmss_fff timestamp, so Name sorts chronologically.
        $pending = @(Get-ChildItem -Path $resendDir -Filter "CollectEnhancedMetrics_*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($pending.Count -gt 0) {
            Write-GiipLog "INFO" "[CollectEnhancedMetrics] Buffer resend: found $($pending.Count) pending buffer file(s)."
            foreach ($bf in $pending) {
                # One attempt per file per run: failures are retried on later runs, keeping startup short.
                try {
                    Write-GiipLog "INFO" "[CollectEnhancedMetrics] Buffer resend attempt: $($bf.Name)"
                    $bufObj = (Get-Content -Path $bf.FullName -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
                    $resendResp = Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "performance_metrics" -Value $bufObj
                    if ($resendResp -and $resendResp.RstVal -eq "200") {
                        Remove-Item -Path $bf.FullName -Force -ErrorAction SilentlyContinue
                        Write-GiipLog "INFO" "[CollectEnhancedMetrics] Buffer resend success and deleted: $($bf.Name)"
                    } else {
                        $rv = if ($resendResp) { $resendResp.RstVal } else { "null" }
                        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Buffer resend failed, kept: $($bf.Name) (RstVal=$rv)"
                    }
                } catch {
                    Write-GiipLog "WARN" "[CollectEnhancedMetrics] Buffer resend error, kept: $($bf.Name) ($_)"
                }
            }
        }

        # Retention caps: prune oldest buffers beyond age/count limits so they never pile up unbounded.
        $ageCutoff = (Get-Date).AddDays(-$BufferRetentionDays)
        $aged = @(Get-ChildItem -Path $resendDir -Filter "CollectEnhancedMetrics_*.json" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $ageCutoff })
        foreach ($old in $aged) {
            try {
                Remove-Item -Path $old.FullName -Force -ErrorAction SilentlyContinue
                Write-GiipLog "INFO" "[CollectEnhancedMetrics] Buffer retention: deleted (age > ${BufferRetentionDays}d): $($old.Name)"
            } catch {}
        }
        $remaining = @(Get-ChildItem -Path $resendDir -Filter "CollectEnhancedMetrics_*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
        if ($remaining.Count -gt $BufferMaxCount) {
            $excess = $remaining.Count - $BufferMaxCount
            foreach ($old in ($remaining | Select-Object -First $excess)) {
                try {
                    Remove-Item -Path $old.FullName -Force -ErrorAction SilentlyContinue
                    Write-GiipLog "INFO" "[CollectEnhancedMetrics] Buffer retention: deleted (count > ${BufferMaxCount}): $($old.Name)"
                } catch {}
            }
        }
    }
} catch {
    Write-GiipLog "WARN" "[CollectEnhancedMetrics] Buffer resend block error (non-fatal): $_"
}

try {
    # ==========================================================================
    # giip #6162: every metric section below runs inside its own try/catch.
    # A CIM/WMI query that times out (or fails for any other reason) is logged
    # as WARN, that section alone is skipped, and the remaining sections are
    # still collected and uploaded. Before this change one unresponsive WMI
    # provider hung the whole script, which -- combined with Task Scheduler
    # MultipleInstances=IgnoreNew -- stalled the entire agent cycle.
    #
    # The uploaded payload keeps exactly the same shape: every key is always
    # present, and a skipped section reports neutral defaults (0 / empty list /
    # "N/A") instead of disappearing from the payload.
    # ==========================================================================
    $cpu = $null
    $cpuDetailObj = @{
        user_pct     = 0.0
        system_pct   = 0.0
        idle_pct     = 0.0
        iowait_pct   = 0.0
        steal_pct    = 0.0
    }
    $totalMem = 0
    $totalMb = 0.0
    $availMb = 0.0
    $usedMb = 0.0
    $memDetailObj = @{
        total_mb   = 0.0
        used_mb    = 0.0
        free_mb    = 0.0
        shared_mb  = 0
        buffers_mb = 0
        cached_mb  = 0
    }
    $diskPartitionsList = @()
    $ioStatsList = @()
    $netTrafficList = @()
    $topProcsList = @()
    $topMemProcsList = @()

    # 1. cpu_usage_detail
    try {
        $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec $CimTimeoutSec
        $cpuDetailObj = @{
            user_pct     = [double]$cpu.PercentUserTime
            system_pct   = [double]$cpu.PercentPrivilegedTime
            idle_pct     = [double]$cpu.PercentIdleTime
            iowait_pct   = 0.0
            steal_pct    = 0.0
        }
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'cpu_usage_detail' failed, skipped: $_"
    }

    # 2. mem_usage_detail
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec $CimTimeoutSec
        $totalMem = $cs.TotalPhysicalMemory
        $totalMb = [math]::Round($totalMem / 1MB)
        $perfMem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -OperationTimeoutSec $CimTimeoutSec
        $availMb = [double]$perfMem.AvailableMBytes
        $usedMb = $totalMb - $availMb

        $memDetailObj = @{
            total_mb   = $totalMb
            used_mb    = $usedMb
            free_mb    = $availMb
            shared_mb  = 0
            buffers_mb = 0
            cached_mb  = 0
        }
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'mem_usage_detail' failed, skipped: $_"
    }

    # 3. disk_usage_partition
    try {
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -OperationTimeoutSec $CimTimeoutSec
        foreach ($disk in $disks) {
            $size = $disk.Size
            $free = $disk.FreeSpace
            if ($size -gt 0) {
                $used = $size - $free
                $pct = [math]::Round(($used / $size) * 100, 2)
                $diskPartitionsList += @{
                    device   = $disk.DeviceID
                    total    = ("{0:N1}G" -f ($size / 1GB))
                    used     = ("{0:N1}G" -f ($used / 1GB))
                    avail    = ("{0:N1}G" -f ($free / 1GB))
                    use_pct  = ("{0}%" -f $pct)
                    mount    = "$($disk.DeviceID)\"
                }
            }
        }
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'disk_usage_partition' failed, skipped: $_"
    }

    # 4. io_statistics
    try {
        $pDisks = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -OperationTimeoutSec $CimTimeoutSec | Where-Object { $_.Name -ne "_Total" }
        foreach ($pd in $pDisks) {
            $ioStatsList += @{
                device     = $pd.Name
                tps        = [double]$pd.DiskTransfersPerSec
                read_kb_s  = [math]::Round($pd.DiskReadBytesPerSec / 1KB, 2)
                write_kb_s = [math]::Round($pd.DiskWriteBytesPerSec / 1KB, 2)
                avg_wait   = [math]::Round($pd.AverageDiskSecPerTransfer * 1000, 2)
            }
        }
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'io_statistics' failed, skipped: $_"
    }

    # 5. network_traffic
    try {
        # Get-NetAdapterStatistics is missing on some Windows builds: fall back
        # to the CIM counter class instead of losing the whole section.
        $netAdapters = @()
        try {
            $netAdapters = @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue)
        }
        catch {
            Write-GiipLog "WARN" "[CollectEnhancedMetrics] Get-NetAdapterStatistics failed, using CIM fallback: $_"
        }
        if ($netAdapters.Count -gt 0) {
            foreach ($na in $netAdapters) {
                $rxPackets = if ($null -ne $na.ReceivedPackets) { [double]$na.ReceivedPackets } else { 0.0 }
                $txPackets = if ($null -ne $na.SentPackets) { [double]$na.SentPackets } else { 0.0 }
                $netTrafficList += @{
                    interface   = $na.Name
                    rx_bytes    = [double]$na.ReceivedBytes
                    tx_bytes    = [double]$na.SentBytes
                    rx_packets  = $rxPackets
                    tx_packets  = $txPackets
                }
            }
        } else {
            $wmiNet = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface -OperationTimeoutSec $CimTimeoutSec
            foreach ($wn in $wmiNet) {
                $netTrafficList += @{
                    interface   = $wn.Name
                    rx_bytes    = [double]$wn.BytesReceivedPersec
                    tx_bytes    = [double]$wn.BytesSentPersec
                    rx_packets  = [double]$wn.PacketsReceivedPersec
                    tx_packets  = [double]$wn.PacketsSentPersec
                }
            }
        }
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'network_traffic' failed, skipped: $_"
    }

    # 6. top_processes
    try {
        $perfProcs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -OperationTimeoutSec $CimTimeoutSec | 
                 Where-Object { $_.Name -notmatch "_Total|Idle" } | 
                 Sort-Object -Property PercentProcessorTime -Descending | 
                 Select-Object -First 10
        foreach ($pp in $perfProcs) {
            # mem_pct needs the total physical memory. If the memory section
            # was skipped there is no denominator, so report 0 instead of
            # dividing by zero (that would take this section down as well).
            $memPct = 0.0
            if ($totalMem -gt 0) { $memPct = [math]::Round(([double]$pp.WorkingSetPrivate / $totalMem) * 100, 2) }
            $topProcsList += @{
                pid      = [int]$pp.IDProcess
                ppid     = [int]$pp.CreatingProcessID
                cpu_pct  = [double]$pp.PercentProcessorTime
                mem_pct  = $memPct
                cmd      = $pp.Name
            }
        }
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'top_processes' failed, skipped: $_"
    }

    # 6-2. top_mem_processes
    try {
        $perfMemProcs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -OperationTimeoutSec $CimTimeoutSec | 
                     Where-Object { $_.Name -notmatch "_Total|Idle" } | 
                     Sort-Object -Property WorkingSetPrivate -Descending | 
                     Select-Object -First 10
        foreach ($pp in $perfMemProcs) {
            $memPct = 0.0
            if ($totalMem -gt 0) { $memPct = [math]::Round(([double]$pp.WorkingSetPrivate / $totalMem) * 100, 2) }
            $topMemProcsList += @{
                pid      = [int]$pp.IDProcess
                ppid     = [int]$pp.CreatingProcessID
                cpu_pct  = [double]$pp.PercentProcessorTime
                mem_pct  = $memPct
                cmd      = $pp.Name
            }
        }
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'top_mem_processes' failed, skipped: $_"
    }

    # 7. Dashboard Compatibility Top-level Fields
    # Every value below is derived from the section above, so it degrades to a
    # neutral default when that section was skipped.
    $cpuUsage = 0.0
    if ($cpu) {
        $cpuUsage = [math]::Round(100.0 - [double]$cpu.PercentIdleTime, 2)
        if ($cpuUsage -lt 0) { $cpuUsage = 0.0 }
    }

    $cpuCores = 1
    try {
        $coreSum = (Get-CimInstance Win32_Processor -OperationTimeoutSec $CimTimeoutSec | Measure-Object -Property NumberOfCores -Sum).Sum
        if ($coreSum) { $cpuCores = $coreSum }
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'cpu_cores' failed, skipped: $_"
    }

    $memUsage = 0.0
    if ($totalMb -gt 0) { $memUsage = [math]::Round(($usedMb / $totalMb) * 100, 2) }

    $systemDisk = $diskPartitionsList | Where-Object { $_.device -eq "C:" }
    if (-not $systemDisk -and $diskPartitionsList.Count -gt 0) { $systemDisk = $diskPartitionsList[0] }
    $diskUsagePct = 0.0
    $diskH = "N/A"
    if ($systemDisk) {
        if ($systemDisk.use_pct -match "([0-9.]+)") {
            $diskUsagePct = [double]$Matches[1]
        }
        $diskH = "$($systemDisk.used) / $($systemDisk.total) ($($systemDisk.use_pct))"
    }

    $connCount = 0
    try {
        $connCount = (Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue).Count
        if ($null -eq $connCount) { $connCount = 0 }
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'conn_count' failed, skipped: $_"
    }

    $totalProcessCount = 0
    try {
        $totalProcessCount = (Get-Process).Count
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'total_process_count' failed, skipped: $_"
    }

    $uptimeStr = "N/A"
    try {
        $osInfo = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec $CimTimeoutSec
        $uptimeSpan = (Get-Date) - $osInfo.LastBootUpTime
        $uptimeStr = "{0}d {1}h {2}m" -f $uptimeSpan.Days, $uptimeSpan.Hours, $uptimeSpan.Minutes
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'uptime' failed, skipped: $_"
    }

    # Build Unified Payload
    $buildVersion = "N/A"
    try {
        $buildVersion = (Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec $CimTimeoutSec).Version
    }
    catch {
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] Section 'build_version' failed, skipped: $_"
    }
    $unifiedPayload = @{
        cpu_usage           = $cpuUsage
        mem_usage           = $memUsage
        disk_usage          = $diskUsagePct
        disk_h              = $diskH
        conn_count          = $connCount
        total_process_count = $totalProcessCount
        status              = "NORMAL"
        
        cpu = @{
            cores     = $cpuCores
            usage_pct = $cpuUsage
        }
        
        memory = @{
            total_mb  = $totalMb
            used_mb   = $usedMb
            free_mb   = $availMb
            usage_pct = $memUsage
        }
        
        system = @{
            os       = "Windows"
            uptime   = $uptimeStr
            hostname = $env:COMPUTERNAME
            build    = $buildVersion
        }
        
        cpu_usage_detail     = $cpuDetailObj
        mem_usage_detail     = $memDetailObj
        disk_usage_partition = $diskPartitionsList
        io_statistics        = $ioStatsList
        network_traffic      = $netTrafficList
        top_processes        = $topProcsList
        top_mem_processes    = $topMemProcsList
    }

    # Upload all metrics under a single factor to KVS with retry and local buffer (giip #3116)
    # - Max 3 retries with exponential backoff (1s, 2s, 4s)
    # - Buffer payload to local file before each retry attempt
    # - Delete buffer file on successful upload
    # - Exit 0 even when all retries fail (metrics collection itself succeeded)
    $kvsSuccess = $false
    $maxRetries = 3
    $bufferDir = Join-Path $AgentRoot "giipLogs/payloads"
    $bufferFile = $null

    if (-not (Test-Path $bufferDir)) {
        try { New-Item -Path $bufferDir -ItemType Directory -Force | Out-Null } catch {}
    }

    for ($retry = 0; $retry -lt $maxRetries; $retry++) {
        if ($retry -gt 0) {
            $backoffSec = [math]::Pow(2, $retry - 1)
            Write-GiipLog "INFO" "[CollectEnhancedMetrics] KVS upload retry $retry/$maxRetries after ${backoffSec}s backoff..."
            Start-Sleep -Seconds $backoffSec
        }

        # Buffer payload before attempt
        if (-not $bufferFile) {
            $ts = Get-Date -Format "yyyyMMdd_HHmmss_fff"
            $bufferFile = Join-Path $bufferDir "CollectEnhancedMetrics_${ts}_retry${retry}.json"
            try {
                $payloadJson = $unifiedPayload | ConvertTo-Json -Compress -Depth 10
                $payloadJson | Set-Content -Path $bufferFile -Encoding ASCII
            } catch {
                Write-GiipLog "WARN" "[CollectEnhancedMetrics] Failed to write buffer file: $_"
            }
        }

        $kvsResp = Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "performance_metrics" -Value $unifiedPayload

        if ($kvsResp -and $kvsResp.RstVal -eq "200") {
            Write-GiipLog "INFO" "[CollectEnhancedMetrics] Successfully collected and uploaded unified performance metrics."
            $kvsSuccess = $true
            # Delete buffer file on success
            if ($bufferFile -and (Test-Path $bufferFile)) {
                try { Remove-Item -Path $bufferFile -Force } catch {}
            }
            break
        }
    }

    if (-not $kvsSuccess) {
        Write-GiipApiFailure -Config $Config -Context "[CollectEnhancedMetrics] KVS upload (performance_metrics)" -Response $kvsResp
        # giip #3116: All retries exhausted, but metrics collection itself succeeded - exit 0
        Write-GiipLog "WARN" "[CollectEnhancedMetrics] KVS upload failed after $maxRetries retries. Metrics collected but not uploaded. Buffer saved at: $bufferFile"
    }
}
catch {
    Write-GiipLog "ERROR" "[CollectEnhancedMetrics] Unexpected error collecting performance details: $_"
    exit 1
}

exit 0
