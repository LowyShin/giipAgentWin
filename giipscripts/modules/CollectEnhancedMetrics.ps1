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

try {
    # 1. cpu_usage_detail
    $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    $cpuJson = @{
        user_pct     = [double]$cpu.PercentUserTime
        system_pct   = [double]$cpu.PercentPrivilegedTime
        idle_pct     = [double]$cpu.PercentIdleTime
        iowait_pct   = 0.0
        steal_pct    = 0.0
    } | ConvertTo-Json -Compress

    # 2. mem_usage_detail
    $cs = Get-CimInstance Win32_ComputerSystem
    $totalMem = $cs.TotalPhysicalMemory
    $totalMb = [math]::Round($totalMem / 1MB)
    $perfMem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $availMb = [double]$perfMem.AvailableMBytes
    $usedMb = $totalMb - $availMb
    
    $memJson = @{
        total_mb   = $totalMb
        used_mb    = $usedMb
        free_mb    = $availMb
        shared_mb  = 0
        buffers_mb = 0
        cached_mb  = 0
    } | ConvertTo-Json -Compress

    # 3. disk_usage_partition
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    $diskPartitions = @()
    foreach ($disk in $disks) {
        $size = $disk.Size
        $free = $disk.FreeSpace
        if ($size -gt 0) {
            $used = $size - $free
            $pct = [math]::Round(($used / $size) * 100, 2)
            $diskPartitions += @{
                device   = $disk.DeviceID
                total    = ("{0:N1}G" -f ($size / 1GB))
                used     = ("{0:N1}G" -f ($used / 1GB))
                avail    = ("{0:N1}G" -f ($free / 1GB))
                use_pct  = ("{0}%" -f $pct)
                mount    = "$($disk.DeviceID)\"
            }
        }
    }
    $diskJson = $diskPartitions | ConvertTo-Json -Compress

    # 4. io_statistics
    $pDisks = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne "_Total" }
    $ioStats = @()
    foreach ($pd in $pDisks) {
        $ioStats += @{
            device     = $pd.Name
            tps        = [double]$pd.DiskTransfersPerSec
            read_kb_s  = [math]::Round($pd.DiskReadBytesPerSec / 1KB, 2)
            write_kb_s = [math]::Round($pd.DiskWriteBytesPerSec / 1KB, 2)
            avg_wait   = [math]::Round($pd.AverageDiskSecPerTransfer * 1000, 2)
        }
    }
    $ioJson = $ioStats | ConvertTo-Json -Compress

    # 5. network_traffic
    $netAdapters = Get-NetAdapterStatistics -ErrorAction SilentlyContinue
    $netTraffic = @()
    if ($netAdapters) {
        foreach ($na in $netAdapters) {
            $rxPackets = if ($null -ne $na.ReceivedPackets) { [double]$na.ReceivedPackets } else { 0.0 }
            $txPackets = if ($null -ne $na.SentPackets) { [double]$na.SentPackets } else { 0.0 }
            $netTraffic += @{
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
            $netTraffic += @{
                interface   = $wn.Name
                rx_bytes    = [double]$wn.BytesReceivedPersec
                tx_bytes    = [double]$wn.BytesSentPersec
                rx_packets  = [double]$wn.PacketsReceivedPersec
                tx_packets  = [double]$wn.PacketsSentPersec
            }
        }
    }
    $netJson = $netTraffic | ConvertTo-Json -Compress

    # 6. top_processes
    $perfProcs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | 
                 Where-Object { $_.Name -notmatch "_Total|Idle" } | 
                 Sort-Object -Property PercentProcessorTime -Descending | 
                 Select-Object -First 10
    $topProcs = @()
    foreach ($pp in $perfProcs) {
        $topProcs += @{
            pid      = [int]$pp.IDProcess
            ppid     = [int]$pp.CreatingProcessID
            cpu_pct  = [double]$pp.PercentProcessorTime
            mem_pct  = [math]::Round(([double]$pp.WorkingSetPrivate / $totalMem) * 100, 2)
            cmd      = $pp.Name
        }
    }
    $topProcsJson = $topProcs | ConvertTo-Json -Compress

    # Upload all metrics to KVS
    Write-GiipLog "INFO" "[CollectEnhancedMetrics] Uploading performance details to KVS..."
    
    Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "cpu_usage_detail" -Value $cpuJson | Out-Null
    Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "mem_usage_detail" -Value $memJson | Out-Null
    Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "disk_usage_partition" -Value $diskJson | Out-Null
    Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "io_statistics" -Value $ioJson | Out-Null
    Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "network_traffic" -Value $netJson | Out-Null
    Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "top_processes" -Value $topProcsJson | Out-Null

    Write-GiipLog "INFO" "[CollectEnhancedMetrics] Successfully collected and uploaded all performance metrics."

}
catch {
    Write-GiipLog "ERROR" "[CollectEnhancedMetrics] Unexpected error collecting performance details: $_"
    exit 1
}

exit 0
