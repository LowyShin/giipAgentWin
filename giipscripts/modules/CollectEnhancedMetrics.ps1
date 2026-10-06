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
    # 1. cpu_usage_detail
    $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    $cpuDetailObj = @{
        user_pct     = [double]$cpu.PercentUserTime
        system_pct   = [double]$cpu.PercentPrivilegedTime
        idle_pct     = [double]$cpu.PercentIdleTime
        iowait_pct   = 0.0
        steal_pct    = 0.0
    }

    # 2. mem_usage_detail
    $cs = Get-CimInstance Win32_ComputerSystem
    $totalMem = $cs.TotalPhysicalMemory
    $totalMb = [math]::Round($totalMem / 1MB)
    $perfMem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
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

    # 3. disk_usage_partition
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    $diskPartitionsList = @()
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

    # 4. io_statistics
    $pDisks = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne "_Total" }
    $ioStatsList = @()
    foreach ($pd in $pDisks) {
        $ioStatsList += @{
            device     = $pd.Name
            tps        = [double]$pd.DiskTransfersPerSec
            read_kb_s  = [math]::Round($pd.DiskReadBytesPerSec / 1KB, 2)
            write_kb_s = [math]::Round($pd.DiskWriteBytesPerSec / 1KB, 2)
            avg_wait   = [math]::Round($pd.AverageDiskSecPerTransfer * 1000, 2)
        }
    }

    # 5. network_traffic
    $netAdapters = Get-NetAdapterStatistics -ErrorAction SilentlyContinue
    $netTrafficList = @()
    if ($netAdapters) {
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
        $wmiNet = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface
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

    # 6. top_processes
    $perfProcs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | 
                 Where-Object { $_.Name -notmatch "_Total|Idle" } | 
                 Sort-Object -Property PercentProcessorTime -Descending | 
                 Select-Object -First 10
    $topProcsList = @()
    foreach ($pp in $perfProcs) {
        $topProcsList += @{
            pid      = [int]$pp.IDProcess
            ppid     = [int]$pp.CreatingProcessID
            cpu_pct  = [double]$pp.PercentProcessorTime
            mem_pct  = [math]::Round(([double]$pp.WorkingSetPrivate / $totalMem) * 100, 2)
            cmd      = $pp.Name
        }
    }

    # 6-2. top_mem_processes
    $perfMemProcs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | 
                     Where-Object { $_.Name -notmatch "_Total|Idle" } | 
                     Sort-Object -Property WorkingSetPrivate -Descending | 
                     Select-Object -First 10
    $topMemProcsList = @()
    foreach ($pp in $perfMemProcs) {
        $topMemProcsList += @{
            pid      = [int]$pp.IDProcess
            ppid     = [int]$pp.CreatingProcessID
            cpu_pct  = [double]$pp.PercentProcessorTime
            mem_pct  = [math]::Round(([double]$pp.WorkingSetPrivate / $totalMem) * 100, 2)
            cmd      = $pp.Name
        }
    }

    # 7. Dashboard Compatibility Top-level Fields
    $cpuUsage = [math]::Round(100.0 - [double]$cpu.PercentIdleTime, 2)
    if ($cpuUsage -lt 0) { $cpuUsage = 0.0 }

    $cpuCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
    if (-not $cpuCores) { $cpuCores = 1 }

    $memUsage = [math]::Round(($usedMb / $totalMb) * 100, 2)

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
    } catch {}

    $totalProcessCount = (Get-Process).Count

    $uptimeStr = "N/A"
    try {
        $osInfo = Get-CimInstance Win32_OperatingSystem
        $uptimeSpan = (Get-Date) - $osInfo.LastBootUpTime
        $uptimeStr = "{0}d {1}h {2}m" -f $uptimeSpan.Days, $uptimeSpan.Hours, $uptimeSpan.Minutes
    } catch {}

    # Build Unified Payload
    $buildVersion = (Get-CimInstance Win32_OperatingSystem).Version
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
