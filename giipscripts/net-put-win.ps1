<#
.SYNOPSIS
  Windows  3D       JSON .

.DESCRIPTION
  - OS//  
  -  (MAC,  , MTU, VLAN )
  - IP (IPv4/IPv6, , DNS, )
  -  :  , ARP/Neighbor , TCP ( )

   OS Get-Net*   ,  WMI/CIM     .

.PARAMETER Output
   JSON  . : .\net_inventory.json

.PARAMETER IncludeRoutes
    .

.PARAMETER IncludeArp
  ARP(Neighbor)  .

.PARAMETER IncludeConnections
  TCP   .

.PARAMETER TopConnections
    TCP  .  2000.

.PARAMETER SendToGiip
    giipapi(KVSPut) .

.PARAMETER GiipEndpoint
  giipapi  URL(: Azure Function HTTP ).

.PARAMETER GiipCode
  Azure Function (   code=  ).

.PARAMETER GiipUserToken
    usertoken/token    .

.PARAMETER GiipUserId
    user_id    ID().

.PARAMETER KType
  KVSPut  kType.  'lssn'.

.PARAMETER KKey
  KVSPut  kKey.  lssn   .

.PARAMETER KFactor
  KVSPut  kFactor.  'netinv'.

.EXAMPLE
  .\Collect-NetInventory.ps1 -Output C:\temp\srv1.json -IncludeRoutes -IncludeArp -IncludeConnections

.EXAMPLE
  Invoke-Command -ComputerName srv1 -FilePath .\Collect-NetInventory.ps1 -ArgumentList @("C:\\temp\\srv1.json",$true,$true,$false)

.NOTES
         (ARP,  ).
   : UTF-8(BOM ).
#>
[CmdletBinding()]
param(
  [string]$Output = ".\net_inventory.json",
  [switch]$IncludeRoutes,
  [switch]$IncludeArp,
  [switch]$IncludeConnections,
  [int]$TopConnections = 2000,
  # --- giipapi   ---
  [switch]$SendToGiip,
  [string]$GiipEndpoint,
  [string]$GiipCode,
  [string]$GiipUserToken,
  [string]$GiipUserId,
  [string]$KType = 'lssn',
  [string]$KKey,
  [string]$KFactor = 'netinv'
)


# @@ANCHOR:USER_CONFIG_START
# region  : giipAgent.cfg KVSConfig , kFactor   
#  DO NOT MODIFY THIS PATH 
$kFactor = 'netinv'
$cfgPath = Join-Path $PSScriptRoot '..\..\giipAgent.cfg'
if (Test-Path -LiteralPath $cfgPath) {
  $lines = Get-Content -LiteralPath $cfgPath -Raw
  foreach ($line in ($lines -split "\r?\n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith("'")) { continue }
    $m = [regex]::Match($line, '^(?<k>\w+)\s*=\s*(?<v>.+)$', 'IgnoreCase')
    if ($m.Success) {
      $k = $m.Groups['k'].Value.Trim()
      $v = $m.Groups['v'].Value.Trim().Trim('"')
      $KVSConfig[$k] = $v
    }
  }
  if ($KVSConfig['Enabled']) { $KVSConfig['Enabled'] = ($KVSConfig['Enabled'] -eq 'true') }
  if (-not $KVSConfig['HostKey']) { $KVSConfig['HostKey'] = $env:COMPUTERNAME }
}
# kFactor    
$KVSConfig['KFactor'] = 'netinv'
# @@ANCHOR:USER_CONFIG_END

# @@ANCHOR:DEFAULT_INJECTION_START
#    (  )
# ()     
Write-Host ("[TRACE] Defaults(before): GiipEndpoint='{0}'" -f $GiipEndpoint)
if (-not $PSBoundParameters.ContainsKey('SendToGiip')) { if ($KVSConfig.Enabled) { $SendToGiip = $true } }
if (-not $GiipEndpoint -and $KVSConfig.Endpoint) { $GiipEndpoint = $KVSConfig.Endpoint }
if (-not $GiipCode -and $KVSConfig.FunctionCode) { $GiipCode = $KVSConfig.FunctionCode }
if (-not $GiipUserToken -and $KVSConfig.UserToken) { $GiipUserToken = $KVSConfig.UserToken }
if (-not $GiipUserId -and $KVSConfig.UserId) { $GiipUserId = $KVSConfig.UserId }
if (-not $KType -and $KVSConfig.KType) { $KType = $KVSConfig.KType }
if (-not $KKey -and $KVSConfig.KKey) { $KKey = $KVSConfig.KKey }
if (-not $KFactor -and $KVSConfig.KFactor) { $KFactor = $KVSConfig.KFactor }
if (-not $HostKey -and $KVSConfig.HostKey) { $HostKey = $KVSConfig.HostKey }
# ()     
Write-Host ("[TRACE] Defaults(after):  GiipEndpoint='{0}' ; KVSConfig.Endpoint='{1}'" -f $GiipEndpoint, $KVSConfig.Endpoint)
# @@ANCHOR:DEFAULT_INJECTION_END

# region Utils ---------------------------------------------------------------
function Test-HasCommand {
  param([Parameter(Mandatory)][string]$Name)
  return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function New-StableGuidFromString {
  <#    GUID (MD5 16  GUID ) #>
  param([Parameter(Mandatory)][string]$InputString)
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hash = $md5.ComputeHash($bytes)
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    $guidStr = "{0}-{1}-{2}-{3}-{4}" -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
    return [Guid]$guidStr
  }
  finally { $md5.Dispose() }
}

function Get-FirstNonLoopbackIPv4 {
  $ips = @()
  try {
    if (Test-HasCommand 'Get-NetIPAddress') {
      $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.ValidLifetime -ne 0 }
    }
    else {
      $cfgs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' -ErrorAction SilentlyContinue
      foreach ($c in $cfgs) {
        foreach ($ip in ($c.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -ne '127.0.0.1' })) { $ips += [pscustomobject]@{ IPAddress = $ip; InterfaceIndex = $c.InterfaceIndex } }
      }
    }
  }
  catch {}
  return ($ips | Select-Object -First 1).IPAddress
}
# @@ANCHOR:UTILS_CONVERT_SPEED_START
function Convert-SpeedStringToBps {
  <#   ("1.2 Gbps", "100 Mbps", 1000000000)  Int64 bps  #>
  param([Parameter(Mandatory = $false)]$Value)
  if ($null -eq $Value -or $Value -eq '') { return $null }
  if ($Value -is [int64] -or $Value -is [int] -or $Value -is [long]) { return [int64]$Value }
  $s = [string]$Value; $s = $s.Trim()
  [double]$num = 0
  if ([double]::TryParse($s, [ref]$num)) { return [int64]$num }
  $parts = $s -split ' +'
  if ($parts.Length -ge 1) {
    $nstr = $parts[0]
    $unit = if ($parts.Length -ge 2) { $parts[1] } else { '' }
    if (-not [double]::TryParse($nstr, [ref]$num)) { return $null }
    switch ($unit.ToLower()) {
      'gbps' { return [int64]($num * 1000000000) }
      'mbps' { return [int64]($num * 1000000) }
      'kbps' { return [int64]($num * 1000) }
      'bps' { return [int64]$num }
      default { return $null }
    }
  }
  return $null
}
# @@ANCHOR:UTILS_CONVERT_SPEED_END
# endregion Utils ------------------------------------------------------------

# region System Info ---------------------------------------------------------
function Get-OsHardwareInfo {
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
  $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
  $proc = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
  $mem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
  $uptimeSec = $null
  $bootTime = $null
  # @@ANCHOR:SYSTEM_BOOT_TIME_START
  try {
    if ($os -and $os.LastBootUpTime) {
      if ($os.LastBootUpTime -is [datetime]) { $bootTime = $os.LastBootUpTime }
      else { $bootTime = [Management.ManagementDateTimeConverter]::ToDateTime([string]$os.LastBootUpTime) }
    }
  }
  catch { $bootTime = $null }
  if ($bootTime) { $uptimeSec = [int](New-TimeSpan -Start $bootTime -End (Get-Date)).TotalSeconds }
  # @@ANCHOR:SYSTEM_BOOT_TIME_END
  $isVirtual = $false
  $virtHints = @('VMware', 'VirtualBox', 'KVM', 'Hyper-V', 'HVM', 'XEN', 'QEMU', 'Parallels', 'OpenStack', 'RHEV', 'HYPER-V', 'VIRTUAL')
  $modelStr = ($cs.Model + ' ' + $cs.Manufacturer)
  foreach ($h in $virtHints) { if ($modelStr -match [regex]::Escape($h)) { $isVirtual = $true; break } }

  [pscustomobject]@{
    hostname       = $env:COMPUTERNAME
    fqdn           = $env:COMPUTERNAME
    domain         = $cs.Domain
    os_caption     = $os.Caption
    os_version     = $os.Version
    os_build       = $os.BuildNumber
    last_boot_time = $bootTime
    uptime_seconds = $uptimeSec
    manufacturer   = $cs.Manufacturer
    model          = $cs.Model
    serial_number  = $bios.SerialNumber
    is_virtualized = $isVirtual
    cpu_name       = $proc.Name
    cpu_logical    = $cs.NumberOfLogicalProcessors
    cpu_physical   = $cs.NumberOfProcessors
    memory_bytes   = [int64]($mem.TotalPhysicalMemory)
  }
}
# endregion System Info ------------------------------------------------------

# region Network -------------------------------------------------------------
function Get-NicAdvancedVlanId {
  param([string]$AdapterName)
  try {
    if (Test-HasCommand 'Get-NetAdapterAdvancedProperty') {
      $props = Get-NetAdapterAdvancedProperty -Name $AdapterName -ErrorAction SilentlyContinue
      $cand = $props | Where-Object { $_.DisplayName -match 'VLAN|Priority' -or $_.RegistryKeyword -match 'Vlan' }
      if ($cand) {
        return ($cand | Select-Object -First 1).DisplayValue
      }
    }
  }
  catch {}
  return $null
}

function Get-NetworkAdaptersInfo {
  $adapters = @()
  if (Test-HasCommand 'Get-NetAdapter') {
    $nets = Get-NetAdapter -Physical | Sort-Object ifIndex -ErrorAction SilentlyContinue
    foreach ($n in $nets) {
      $mtu = $null
      try { $mtu = (Get-NetIPInterface -InterfaceIndex $n.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1).NlMtu } catch {}
      $vl = Get-NicAdvancedVlanId -AdapterName $n.Name
      $adapters += [pscustomobject]@{
        name            = $n.Name
        interface_index = $n.ifIndex
        description     = $n.InterfaceDescription
        mac_address     = $n.MacAddress
        status          = $n.Status
        link_speed_bps  = (Convert-SpeedStringToBps $n.LinkSpeed)
        mtu             = $mtu
        vlan            = $vl
        driver_version  = $n.DriverVersion
        pnp_device_id   = $n.PnPDeviceID
        media_type      = $n.MediaType
        virtual         = $n.Virtual
      }
    }
  }
  else {
    # : WMI
    $nets = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalAdapter -eq $true -and $_.NetEnabled -ne $null }
    foreach ($n in $nets) {
      $adapters += [pscustomobject]@{
        name            = $n.NetConnectionID
        interface_index = $n.InterfaceIndex
        description     = $n.Description
        mac_address     = $n.MACAddress
        status          = if ($n.NetEnabled) { 'Up' } else { 'Down' }
        link_speed_bps  = (Convert-SpeedStringToBps $n.Speed)
        mtu             = $null
        vlan            = $null
        driver_version  = $n.DriverVersion
        pnp_device_id   = $n.PNPDeviceID
        media_type      = $null
        virtual         = $null
      }
    }
  }
  return $adapters
}

# @@ANCHOR:GET_IPCONFIG_START
function Get-IPConfigurationInfo {
  $cfgs = @()
  if (Test-HasCommand 'Get-NetIPConfiguration') {
    foreach ($c in (Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
      # DHCP  Get-NetIPInterface 
      $if4 = $null; $if6 = $null
      try { $if4 = Get-NetIPInterface -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1 } catch {}
      try { $if6 = Get-NetIPInterface -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | Select-Object -First 1 } catch {}

      #  DNS /,   (   )
      $dnsServers = @()
      if ($c -and $c.PSObject.Properties.Match('DnsServer').Count -gt 0 -and $c.DnsServer) {
        if ($c.DnsServer.PSObject.Properties.Match('ServerAddresses').Count -gt 0) {
          $dnsServers = @($c.DnsServer.ServerAddresses)
        }
      }
      $dnsSuffix = $null
      if ($c -and $c.PSObject.Properties.Match('DnsSuffix').Count -gt 0) { $dnsSuffix = $c.DnsSuffix }
      elseif ($c -and $c.PSObject.Properties.Match('NetProfile').Count -gt 0 -and $c.NetProfile) {
        if ($c.NetProfile.PSObject.Properties.Match('DnsSuffix').Count -gt 0) { $dnsSuffix = $c.NetProfile.DnsSuffix }
        elseif ($c.NetProfile.PSObject.Properties.Match('Name').Count -gt 0) { $dnsSuffix = $c.NetProfile.Name }
      }
      $gwObjs = @()
      if ($c.PSObject.Properties.Match('IPv4DefaultGateway').Count -gt 0) { $gwObjs += $c.IPv4DefaultGateway }
      if ($c.PSObject.Properties.Match('IPv6DefaultGateway').Count -gt 0) { $gwObjs += $c.IPv6DefaultGateway }
      $gateways = @($gwObjs | Where-Object { $_ } | ForEach-Object { $_.NextHop })

      $cfgs += [pscustomobject]@{
        interface_index = $c.InterfaceIndex
        interface_alias = $c.InterfaceAlias
        dhcp            = [pscustomobject]@{
          ipv4 = if ($if4) { $if4.Dhcp } else { $null }
          ipv6 = if ($if6) { $if6.Dhcp } else { $null }
        }
        ipv4_addresses  = @($c.IPv4Address | ForEach-Object { [pscustomobject]@{ ip = $_.IPAddress; prefix = $_.PrefixLength } })
        ipv6_addresses  = @($c.IPv6Address | ForEach-Object { [pscustomobject]@{ ip = $_.IPAddress; prefix = $_.PrefixLength } })
        gateways        = $gateways
        dns_servers     = $dnsServers
        dns_suffix      = $dnsSuffix
      }
    }
  }
  else {
    foreach ($w in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' -ErrorAction SilentlyContinue)) {
      $ipv4s = @(); $ipv6s = @()
      foreach ($ip in $w.IPAddress) {
        if ($ip -match ':') { $ipv6s += [pscustomobject]@{ ip = $ip; prefix = $null } } else { $ipv4s += [pscustomobject]@{ ip = $ip; prefix = $null } }
      }
      $cfgs += [pscustomobject]@{
        interface_index = $w.InterfaceIndex
        interface_alias = $w.Description
        dhcp            = [pscustomobject]@{ ipv4 = if ($w.DHCPEnabled) { 'Enabled' } else { 'Disabled' }; ipv6 = $null }
        ipv4_addresses  = $ipv4s
        ipv6_addresses  = $ipv6s
        gateways        = @($w.DefaultIPGateway)
        dns_servers     = @($w.DNSServerSearchOrder)
        dns_suffix      = $w.DNSDomain
      }
    }
  }
  return $cfgs
}
# @@ANCHOR:GET_IPCONFIG_END

function Get-RouteTableInfo {
  if (-not $PSBoundParameters.ContainsKey('IncludeRoutes')) { return @() }
  $routes = @()
  if (Test-HasCommand 'Get-NetRoute') {
    $routes = @(Get-NetRoute -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
          address_family = $_.AddressFamily
          destination    = $_.DestinationPrefix
          next_hop       = $_.NextHop
          interface_idx  = $_.IfIndex
          metric         = $_.RouteMetric
          protocol       = $_.Protocol
        }
      })
  }
  else {
    $text = (route print) 2>$null | Out-String
    $routes = @([pscustomobject]@{ raw_text = $text })
  }
  return $routes
}

function Get-NeighborTableInfo {
  if (-not $PSBoundParameters.ContainsKey('IncludeArp')) { return @() }
  $neigh = @()
  if (Test-HasCommand 'Get-NetNeighbor') {
    $neigh = @(Get-NetNeighbor -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
          address_family = $_.AddressFamily
          ip_address     = $_.IPAddress
          link_layer     = $_.LinkLayerAddress
          state          = $_.State
          interface_idx  = $_.IfIndex
        }
      })
  }
  else {
    $raw = (arp -a) 2>$null | Out-String
    #  
    foreach ($line in ($raw -split "`n")) {
      if ($line -match '^(\s*\d+\.\d+\.\d+\.\d+)\s+([0-9a-f\-:]{11,})\s+([\w-]+)') {
        $neigh += [pscustomobject]@{
          address_family = 'IPv4'
          ip_address     = $matches[1]
          link_layer     = $matches[2]
          state          = $matches[3]
          interface_idx  = $null
        }
      }
    }
  }
  return $neigh
}

function Get-TcpConnectionsInfo {
  if (-not $PSBoundParameters.ContainsKey('IncludeConnections')) { return @() }
  $list = @()
  if (Test-HasCommand 'Get-NetTCPConnection') {
    $conns = Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object -First $TopConnections
    $procMap = @{}
    foreach ($p in Get-Process) { $procMap[$p.Id] = $p.ProcessName }
    foreach ($c in $conns) {
      $list += [pscustomobject]@{
        laddr        = $c.LocalAddress
        lport        = $c.LocalPort
        raddr        = $c.RemoteAddress
        rport        = $c.RemotePort
        state        = $c.State
        pid          = $c.OwningProcess
        proc_name    = $procMap[$c.OwningProcess]
        applied_rule = $c.AppliedSetting
      }
    }
  }
  else {
    # : netstat -ano
    $procMap = @{}
    foreach ($p in Get-Process) { $procMap[$p.Id] = $p.ProcessName }
    
    $raw = (netstat -ano) 2>$null | Out-String
    $cnt = 0
    foreach ($line in ($raw -split "`n")) {
      if ($line -match '^\s*(TCP|UDP)\s+(\S+):(\d+)\s+(\S+):(\d+)\s+([A-Z_]+)\s+(\d+)$') {
        $pidVal = [int]$matches[7]
        $list += [pscustomobject]@{
          proto = $matches[1]
          laddr = $matches[2]; lport = [int]$matches[3]
          raddr = $matches[4]; rport = [int]$matches[5]
          state = $matches[6]
          pid = $pidVal
          proc_name = $procMap[$pidVal]
        }
        $cnt++
        if ($cnt -ge $TopConnections) { break }
      }
    }
  }
  return $list
}
# endregion Network ----------------------------------------------------------

# region Build Document ------------------------------------------------------
$sys = Get-OsHardwareInfo
$adapters = Get-NetworkAdaptersInfo
$ipcfgs = Get-IPConfigurationInfo
$routes = Get-RouteTableInfo
$neighbors = Get-NeighborTableInfo
$tcp = Get-TcpConnectionsInfo

# nodeId:  +  IPv4   MAC
$firstIPv4 = Get-FirstNonLoopbackIPv4
if (-not $firstIPv4) { $firstIPv4 = '' }
$primaryMac = ($adapters | Select-Object -First 1).mac_address
if (-not $primaryMac) { $primaryMac = '' }
$primaryKey = "$($sys.hostname)|$firstIPv4|$primaryMac"
$nodeId = (New-StableGuidFromString -InputString $primaryKey).Guid

$doc = [pscustomobject]@{
  schema_version   = '1.0.0'
  collected_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  node_id          = $nodeId
  system           = $sys
  network          = [pscustomobject]@{
    adapters    = $adapters
    ipconfigs   = $ipcfgs
    routes      = $routes
    neighbors   = $neighbors
    connections = $tcp
  }
}
# endregion Build Document ---------------------------------------------------

# region giipapi --------------------------------------------------------------
# @@ANCHOR:API_URL_BUILDER_START
function Build-ApiUrl {
  param([Parameter(Mandatory)][string]$Endpoint, [string]$Code)
  #    (  )
  Write-Host ("[TRACE] Build-ApiUrl: input Endpoint='{0}'" -f $Endpoint)
  # /  ( ,  , code )
  $e = ([string]$Endpoint).Trim()
  $c = if ($Code) { ([string]$Code).Trim() } else { '' }
  Write-Host ("[TRACE] Build-ApiUrl: trimmed Endpoint='{0}'" -f $e)
  if (-not ($e -match '^(?i)https?://')) { throw 'GiipEndpoint must start with http:// or https://' }

  $ret = $e
  if (-not [string]::IsNullOrWhiteSpace($c)) {
    try { $cEnc = [uri]::EscapeDataString($c) } catch { $cEnc = $c }
    $sep = if ($e.Contains('?')) { '&' } else { '?' }
    $ret = ('{0}{1}code={2}' -f $e, $sep, $cEnc)
  }
  Write-Host ("[TRACE] Build-ApiUrl: final URL='{0}'" -f $ret)
  return $ret
}
# @@ANCHOR:API_URL_BUILDER_END
function Send-GiipApi {
  <#
    giipapi  JSON .   (application/x-www-form-urlencoded)
    text     : "KVSPut <kType>, <kKey>, <kFactor>"
    jsondata : JSON  ( )
    usertoken: / 
    user_id  :  ID ()
    token    :   usertoken    
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Endpoint,
    [string]$FunctionCode,
    [Parameter(Mandatory)][string]$JsonValue,
    [string]$UserToken,
    [string]$UserId,
    [string]$KType = 'lssn',
    [Parameter(Mandatory)][string]$KKey,
    [string]$KFactor = 'netinv'
  )
  # () Send-GiipApi   
  Write-Host ("[TRACE] Send-GiipApi: received Endpoint='{0}'" -f $Endpoint)
  $url = Build-ApiUrl -Endpoint $Endpoint -Code $FunctionCode
  Write-Host ("[TRACE] Send-GiipApi: built url='{0}'" -f $url)
  # URL     
  Write-Verbose ("Built URL: [{0}]" -f $url)
  if (-not [uri]::IsWellFormedUriString($url, [UriKind]::Absolute)) { throw ("Invalid URL built: [{0}]" -f $url) }
  # TLS 1.2  (  )
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  $ut = ''
  if ($UserToken) { $ut = $UserToken }
  $uid = ''
  if ($UserId) { $uid = $UserId }
  $body = @{
    text      = "KVSPut $KType, $KKey, $KFactor";
    jsondata  = $JsonValue;
    usertoken = $ut;
    user_id   = $uid;
    token     = $ut
  }
  Write-Verbose ("POST {0} -> text='{1}', json={2} bytes" -f $url, $body.text, ([text.encoding]::UTF8.GetByteCount($JsonValue)))
  try {
    $resp = Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/x-www-form-urlencoded' -Body $body -TimeoutSec 120
    return $resp
  }
  catch {
    throw ("giipapi upload failed: {0}" -f $_.Exception.Message)
  }
}
# endregion giipapi ----------------------------------------------------------

# region Output --------------------------------------------------------------
try {
  $json = $doc | ConvertTo-Json -Depth 10
  $dir = Split-Path -Parent $Output
  if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
  $json | Out-File -FilePath $Output -Encoding utf8
  Write-Host ("JSON written: {0}" -f (Resolve-Path $Output))

  # ()   /  
  Write-Host ("[TRACE] Output block: SendToGiip='{0}' GiipEndpoint='{1}'" -f $SendToGiip, $GiipEndpoint)
  if ($SendToGiip) {
    if (-not $GiipEndpoint) { throw 'GiipEndpoint is required.' }
    if (-not $KKey) { throw 'KKey (lssn) is required for KVSPut.' }
    $response = Send-GiipApi -Endpoint $GiipEndpoint -FunctionCode $GiipCode -JsonValue $json -UserToken $GiipUserToken -UserId $GiipUserId -KType $KType -KKey $KKey -KFactor $KFactor
    Write-Host "giipapi response:" -ForegroundColor Cyan
    if ($response) { $response | Out-String | Write-Host } else { Write-Host '(no content)' }
  }
}
catch {
  Write-Error $_
}
# endregion Output -----------------------------------------------------------

