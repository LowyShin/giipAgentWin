# Auto-Discovery Script for Windows
# Collects OS, Hardware, Software, Services, Network information
# Output: JSON format
#
# giip #3559 항목1: 서버 SP(pApiAgentAutoRegisterBySK)가 읽는 키를 모두 채운다.
#   os / cpu / cpu_cores / memory_gb / disk_gb / agent_version / ipv4_global / ipv4_local
# 키가 빠지면 SP 의 UPDATE 가 해당 컬럼을 NULL 로 덮어쓴다(LSCPU, LSSpecCPUs,
# LSSpecDiskSizeGB, LSAgentVer, LSNIFLocal).
# 키 목록의 정본은 giipdb/SP/pApiAgentAutoRegisterBySK.sql 의 JSON_VALUE 대상 8개 키다.
#   (키를 추가/이름을 바꾸려면 그 SP 와 이 파일을 함께 고쳐야 한다)

# Function to escape JSON strings
function ConvertTo-JsonString {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return $Text.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
}

# RFC1918 사설 IPv4 인지 판별 (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
function Test-IsPrivateIPv4 {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($oct in $Ip.Split('.')) { if ([int]$oct -gt 255) { return $false } }
    return ($Ip -like '10.*' -or $Ip -like '192.168.*' -or ($Ip -match '^172\.(1[6-9]|2\d|3[01])\.'))
}

# 공인(공개) IPv4 인지 판별 — 루프백/링크로컬/사설/IPv6 는 모두 제외
function Test-IsPublicIPv4 {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($oct in $Ip.Split('.')) { if ([int]$oct -gt 255) { return $false } }
    if ($Ip -like '127.*' -or $Ip -like '0.*' -or $Ip -like '169.254.*') { return $false }
    return (-not (Test-IsPrivateIPv4 $Ip))
}

try {
    # ========================================
    # 1. OS Information
    # ========================================
    $os = Get-CimInstance Win32_OperatingSystem
    $osName = $os.Caption
    $osVersion = $os.Version
    $osFullName = "$osName $osVersion"

    # ========================================
    # 2. CPU Information
    # ========================================
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cpuName = $cpu.Name
    $cpuCores = $cpu.NumberOfCores
    $cpuLogical = $cpu.NumberOfLogicalProcessors
    $cpuInfo = "$cpuCores cores ($cpuLogical logical) - $cpuName"

    # ========================================
    # 3. Memory Information
    # ========================================
    $memoryBytes = $os.TotalVisibleMemorySize * 1KB
    $memoryGB = [math]::Round($memoryBytes / 1GB)

    # ========================================
    # 4. Hostname
    # ========================================
    $hostname = $env:COMPUTERNAME

    # ========================================
    # 5. Network Interfaces
    # ========================================
    $networkInterfaces = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.InterfaceAlias -notlike "*Loopback*" -and 
        $_.IPAddress -ne "127.0.0.1"
    }

    $networkArray = @()
    foreach ($iface in $networkInterfaces) {
        $adapter = Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $iface.InterfaceIndex }
        $mac = $adapter.MacAddress
        
        $netObj = [PSCustomObject]@{
            name = $iface.InterfaceAlias
            ipv4 = $iface.IPAddress
        }
        
        if ($mac) {
            $netObj | Add-Member -NotePropertyName mac -NotePropertyValue $mac
        }
        
        # Try to get IPv6
        $ipv6 = (Get-NetIPAddress -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv6 | 
                 Where-Object { $_.AddressState -eq "Preferred" -and $_.IPAddress -notlike "fe80::*" } |
                 Select-Object -First 1).IPAddress
        
        if ($ipv6) {
            $netObj | Add-Member -NotePropertyName ipv6 -NotePropertyValue $ipv6
        }
        
        $networkArray += $netObj
    }

    # 공인/사설 IPv4 판별 — 서버 SP(pApiAgentAutoRegisterBySK)의 ipv4_global/ipv4_local.
    # Linux(giipAgentLinux/scripts/auto-discover-linux.sh)와 같은 판정 기준을 쓴다.
    # 공인 IP 가 없으면 ipv4_global 은 빈 문자열로 둔다 — 서버 SP 가
    # COALESCE(NULLIF(@ipv4_global,''), LSNIFGlobal) 로 마지막 알려진 값을 유지한다.
    # (NAT 된 사내 PC 는 대부분 사설 IP 만 가진다 — 정상 동작이다)
    $ipv4Global = ""
    $ipv4Local = ""
    foreach ($iface in $networkInterfaces) {
        $ifaceIp = $iface.IPAddress
        if ([string]::IsNullOrEmpty($ipv4Global) -and (Test-IsPublicIPv4 $ifaceIp)) {
            $ipv4Global = $ifaceIp
        }
        if ([string]::IsNullOrEmpty($ipv4Local) -and (Test-IsPrivateIPv4 $ifaceIp)) {
            $ipv4Local = $ifaceIp
        }
    }

    # ========================================
    # 6. Disk Information
    # ========================================
    # Linux 는 df -BG / (루트 파일시스템 전체 크기, GB) 를 보낸다. Windows 에서는
    # 시스템 볼륨($env:SystemDrive) 의 전체 크기로 대응시킨다(하드코딩 C: 금지).
    $diskGB = 0
    try {
        $systemDrive = $env:SystemDrive
        if ([string]::IsNullOrWhiteSpace($systemDrive)) { $systemDrive = "C:" }
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$systemDrive'"
        if ($disk -and $disk.Size) {
            $diskGB = [int][math]::Round($disk.Size / 1GB)
        }
    } catch {
        $diskGB = 0
    }

    # ========================================
    # 7. Software Inventory (Registry-based)
    # ========================================
    $registryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $softwareList = @()
    $maxPackages = 100  # Limit to prevent huge JSON
    $count = 0

    foreach ($path in $registryPaths) {
        if ($count -ge $maxPackages) { break }
        
        Get-ItemProperty $path -ErrorAction SilentlyContinue | ForEach-Object {
            if ($count -ge $maxPackages) { return }
            
            $displayName = $_.DisplayName
            if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                $swObj = [PSCustomObject]@{
                    name = ConvertTo-JsonString $displayName
                    version = ConvertTo-JsonString ($_.DisplayVersion)
                    vendor = ConvertTo-JsonString ($_.Publisher)
                    type = "WIN"
                }
                
                if ($_.InstallDate) {
                    try {
                        $installDateStr = $_.InstallDate
                        if ($installDateStr -match '^\d{8}$') {
                            $year = $installDateStr.Substring(0, 4)
                            $month = $installDateStr.Substring(4, 2)
                            $day = $installDateStr.Substring(6, 2)
                            $swObj | Add-Member -NotePropertyName install_date -NotePropertyValue "$year-$month-$day"
                        }
                    } catch {}
                }
                
                if ($_.InstallLocation) {
                    $swObj | Add-Member -NotePropertyName install_path -NotePropertyValue (ConvertTo-JsonString $_.InstallLocation)
                }
                
                if ($_.EstimatedSize) {
                    $sizeBytes = $_.EstimatedSize * 1KB
                    $swObj | Add-Member -NotePropertyName size -NotePropertyValue ([int64]$sizeBytes)
                }
                
                $softwareList += $swObj
                $count++
            }
        }
    }

    # ========================================
    # 8. Service Status
    # ========================================
    $servicesList = @()
    $maxServices = 50  # Limit to prevent huge JSON
    $count = 0

    # Get important services first
    $importantServices = @("*sql*", "*apache*", "*nginx*", "*iis*", "*tomcat*", "*docker*", "*redis*", "*mongo*")
    $services = Get-Service | Where-Object {
        $svcName = $_.Name
        $importantServices | Where-Object { $svcName -like $_ }
    } | Select-Object -First $maxServices

    # If less than max, add more general services
    if ($services.Count -lt $maxServices) {
        $remaining = $maxServices - $services.Count
        $moreServices = Get-Service | Where-Object {
            $_.Status -eq 'Running' -and 
            $_.StartType -ne 'Disabled'
        } | Select-Object -First $remaining
        $services = @($services) + @($moreServices)
    }

    foreach ($svc in $services) {
        if ($count -ge $maxServices) { break }
        
        $status = switch ($svc.Status) {
            "Running" { "Running" }
            "Stopped" { "Stopped" }
            default { $svc.Status.ToString() }
        }
        
        $startType = switch ($svc.StartType) {
            "Automatic" { "Auto" }
            "Manual" { "Manual" }
            "Disabled" { "Disabled" }
            default { $svc.StartType.ToString() }
        }
        
        $svcObj = [PSCustomObject]@{
            name = $svc.Name
            display_name = ConvertTo-JsonString $svc.DisplayName
            status = $status
            start_type = $startType
        }
        
        # Try to get port for common services
        $port = $null
        switch -Wildcard ($svc.Name) {
            "*nginx*" { $port = 80 }
            "*apache*" { $port = 80 }
            "*httpd*" { $port = 80 }
            "*iis*" { $port = 80 }
            "*mssql*" { $port = 1433 }
            "*mysql*" { $port = 3306 }
            "*postgres*" { $port = 5432 }
            "*redis*" { $port = 6379 }
            "*mongo*" { $port = 27017 }
        }
        
        if ($port) {
            $svcObj | Add-Member -NotePropertyName port -NotePropertyValue $port
        }
        
        # Try to get process info if running
        if ($svc.Status -eq 'Running') {
            try {
                $process = Get-Process -Id (Get-CimInstance Win32_Service | Where-Object { $_.Name -eq $svc.Name }).ProcessId -ErrorAction SilentlyContinue
                if ($process) {
                    $svcObj | Add-Member -NotePropertyName pid -NotePropertyValue $process.Id
                    $svcObj | Add-Member -NotePropertyName cpu -NotePropertyValue ([math]::Round($process.CPU, 2))
                    $svcObj | Add-Member -NotePropertyName memory_mb -NotePropertyValue ([math]::Round($process.WorkingSet64 / 1MB))
                }
            } catch {}
        }
        
        $servicesList += $svcObj
        $count++
    }

    # ========================================
    # Generate Final JSON
    # ========================================
    $result = [PSCustomObject]@{
        hostname = $hostname
        os = $osFullName
        cpu = $cpuInfo
        cpu_cores = $cpuLogical
        memory_gb = $memoryGB
        disk_gb = $diskGB
        network = $networkArray
        ipv4_global = $ipv4Global
        ipv4_local = $ipv4Local
        software = $softwareList
        services = $servicesList
    }

    # Output as JSON
    $result | ConvertTo-Json -Depth 10 -Compress

} catch {
    # Error handling - output minimal JSON
    Write-Error $_.Exception.Message
    @{
        hostname = $env:COMPUTERNAME
        os = "Unknown"
        cpu = "Unknown"
        cpu_cores = 0
        memory_gb = 0
        disk_gb = 0
        network = @()
        ipv4_global = ""
        ipv4_local = ""
        software = @()
        services = @()
        error = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}

