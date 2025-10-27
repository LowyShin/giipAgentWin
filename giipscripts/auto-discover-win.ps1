# Auto-Discovery Script for Windows
# Collects OS, Hardware, Software, Services, Network information
# Output: JSON format

# Function to escape JSON strings
function ConvertTo-JsonString {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return $Text.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
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

    # ========================================
    # 6. Software Inventory (Registry-based)
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
    # 7. Service Status
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
        memory_gb = $memoryGB
        network = $networkArray
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
        memory_gb = 0
        network = @()
        software = @()
        services = @()
        error = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
