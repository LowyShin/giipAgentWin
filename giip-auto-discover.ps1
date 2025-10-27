# giipAgent Auto-Discovery Integration for Windows
# Call this script periodically (every 5 minutes) from Task Scheduler
# Example: schtasks /create /tn "GIIP Auto-Discovery" /tr "powershell.exe -File C:\path\to\giip-auto-discover.ps1" /sc minute /mo 5

# Load configuration
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$ConfigFile = Join-Path $ScriptDir "giipAgent.cfg"

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}

# Parse config file (key="value" format)
$Config = @{}
Get-Content $ConfigFile | ForEach-Object {
    if ($_ -match '^(\w+)="([^"]*)"') {
        $Config[$matches[1]] = $matches[2]
    }
}

$sk = $Config['sk']
$lssn = $Config['lssn']
$apiaddr = $Config['apiaddr']

if (-not $apiaddr) {
    $apiaddr = "https://giipasp.azurewebsites.net"
}

$AGENT_VERSION = "1.72"
$LogDir = Join-Path $ScriptDir "..\giipLogs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$LogFile = Join-Path $LogDir ("giip-auto-discover_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

function Write-AgentLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] $Message"
    Add-Content -Path $LogFile -Value $logEntry
    Write-Host $logEntry
}

try {
    # Check if discovery script exists
    $DiscoveryScript = Join-Path $ScriptDir "giipscripts\auto-discover-win.ps1"
    
    if (-not (Test-Path $DiscoveryScript)) {
        Write-AgentLog "ERROR: Discovery script not found: $DiscoveryScript"
        exit 1
    }

    # Run discovery and capture JSON
    Write-AgentLog "Starting auto-discovery..."
    
    $DiscoveryJson = & $DiscoveryScript
    
    if ($LASTEXITCODE -ne 0) {
        Write-AgentLog "ERROR: Discovery script failed with exit code $LASTEXITCODE"
        exit 1
    }

    # Save to temp file for debugging
    $TempJsonFile = Join-Path $env:TEMP "giip-discovery-$PID.json"
    $DiscoveryJson | Out-File -FilePath $TempJsonFile -Encoding UTF8
    
    Write-AgentLog "Discovery data saved to: $TempJsonFile"

    # Parse JSON to object and add agent_version
    $DiscoveryObj = $DiscoveryJson | ConvertFrom-Json
    $DiscoveryObj | Add-Member -NotePropertyName "agent_version" -NotePropertyValue $AGENT_VERSION -Force

    # Convert back to JSON (compact)
    $FinalJson = $DiscoveryObj | ConvertTo-Json -Depth 10 -Compress

    # Call API (Azure Function)
    # Note: API endpoint configured in giipAgent.cfg
    $ApiUrl = "$apiaddr/api/giipApi?cmd=AgentAutoRegister"

    Write-AgentLog "Sending data to API: $ApiUrl"

    $RequestBody = @{
        at = $sk
        jsondata = $DiscoveryObj
    } | ConvertTo-Json -Depth 10

    $Headers = @{
        "Content-Type" = "application/json"
        "Authorization" = "Bearer $sk"
    }

    try {
        $Response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $Headers -Body $RequestBody -TimeoutSec 30
        
        Write-AgentLog "SUCCESS: $($Response | ConvertTo-Json -Compress)"

        # Extract lssn from response if this is first registration
        if ($lssn -eq "0" -and $Response.lssn) {
            $NewLssn = $Response.lssn
            Write-AgentLog "Received LSSN: $NewLssn"
            
            # Update config file
            $ConfigContent = Get-Content $ConfigFile
            $ConfigContent = $ConfigContent -replace 'lssn="0"', "lssn=`"$NewLssn`""
            $ConfigContent | Set-Content $ConfigFile
            
            Write-AgentLog "Updated giipAgent.cfg with LSSN: $NewLssn"
        }

    } catch {
        Write-AgentLog "ERROR: API call failed - $($_.Exception.Message)"
        Write-AgentLog "Response: $($_.Exception.Response)"
        exit 1
    }

    # Cleanup
    if (Test-Path $TempJsonFile) {
        Remove-Item $TempJsonFile -Force
    }

    Write-AgentLog "Auto-discovery completed successfully"

} catch {
    Write-AgentLog "ERROR: $_"
    Write-AgentLog "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
