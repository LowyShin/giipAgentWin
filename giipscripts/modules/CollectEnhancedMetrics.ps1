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
    $buildVersion = (Get-CimInstance Win32_OperatingSystem).BuildNumber
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
    }

    # Upload all metrics under a single factor to KVS (Pass the hashtable directly to avoid double stringification)
    Write-GiipLog "INFO" "[CollectEnhancedMetrics] Uploading unified performance metrics to KVS (Factor: performance_metrics)..."
    Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key "$($Config.lssn)" -Factor "performance_metrics" -Value $unifiedPayload | Out-Null

    Write-GiipLog "INFO" "[CollectEnhancedMetrics] Successfully collected and uploaded unified performance metrics."
}
catch {
    Write-GiipLog "ERROR" "[CollectEnhancedMetrics] Unexpected error collecting performance details: $_"
    exit 1
}

exit 0
