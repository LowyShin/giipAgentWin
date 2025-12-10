
# ============================================================================
# giipAgent for Windows (Ver 3.0)
# Structure based on giipAgentLinux/giipAgent3.sh
# ============================================================================

$ErrorActionPreference = "Stop"
$Version = "3.00"

# 1. Initialize Paths
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$LibDir = Join-Path $ScriptDir "lib"

# 2. Load Modules
try {
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "Kvs.ps1")
    . (Join-Path $LibDir "Discovery.ps1")
    # Cqe loaded if needed, mostly used by NormalMode
}
catch {
    Write-Host "FATAL: Failed to load modules from $LibDir"
    exit 1
}

# 3. Load Configuration
try {
    $Config = Get-GiipConfig
}
catch {
    Write-Host "FATAL: Failed to load configuration: $_"
    exit 1
}

Write-GiipLog "INFO" "Starting giipAgent3.ps1 (V$Version)"
Write-GiipLog "INFO" "LSSN: $($Config.lssn)"

# 4. Server Registration (if LSSN=0)
if ($Config.lssn -eq "0") {
    Write-GiipLog "INFO" "Server not registered (LSSN=0). Registering..."
    
    # Register via CQEQueueGet (following Linux pattern)
    # Payload: lssn=0, hostname, os, op="op"
    $hostname = [System.Net.Dns]::GetHostName()
    
    $regBody = @{
        lssn     = 0
        hostname = $hostname
        os       = "windows"
        op       = "op"
    } | ConvertTo-Json -Compress
    
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "CQEQueueGet lssn hostname os op" -JsonData $regBody
    
    # Logic: Linux script simply does `lssn=$(cat file)`. Implies Raw LSSN or simple content.
    # Note: If Invoke-GiipApiV2 returns an Object (parsed JSON), we check properties.
    # If it returns string, we use it (if Invoke-RestMethod auto-parses output?)
    # Invoke-RestMethod returns PSObject for JSON.
    
    $newLssn = $null
    
    if ($response -is [string]) {
        $newLssn = $response
    }
    elseif ($response.lssn) {
        $newLssn = $response.lssn
    }
    elseif ($response.data -and $response.data[0].lssn) {
        $newLssn = $response.data[0].lssn
    }
    elseif ($response.data -and $response.data[0].ms_body) {
        # Maybe ms_body contains LSSN?
        $newLssn = $response.data[0].ms_body
    }
    else {
        # Fallback: Assume the whole response might be useful if simple
        # But usually JSON.
        Write-GiipLog "WARN" "Registration response unclear. Dump: $($response | ConvertTo-Json -Depth 5)"
    }
    
    if ($newLssn -and $newLssn -ne "0") {
        Write-GiipLog "INFO" "Registered! New LSSN: $newLssn"
        Update-ConfigLssn -NewLssn $newLssn
        
        # Reload Config
        $Config = Get-GiipConfig
    }
    else {
        Write-GiipLog "ERROR" "Registration failed. Continuing with LSSN=0 (might fail)"
    }
}

# 5. Auto Discovery
# Execute Discovery Module
Invoke-Discovery -Config $Config

# 6. Mode Selection
# Check Gateway Mode (Config.is_gateway or derived)
# Linux fetches this from API ('lssn', 'hostname' -> 'is_gateway')
# We can do the same if we want perfect parity.
# For now, let's check config file or assume Normal.
$IsGateway = $false
if ($Config.is_gateway -eq "1" -or $Config.is_gateway -eq $true) {
    $IsGateway = $true
}

if ($IsGateway) {
    Write-GiipLog "INFO" "Running in GATEWAY MODE"
    $GatewayScript = Join-Path $ScriptDir "scripts\GatewayMode.ps1"
    if (Test-Path $GatewayScript) {
        & $GatewayScript
    }
    else {
        Write-GiipLog "WARN" "Gateway script not found: $GatewayScript"
    }
}

# 7. Normal Mode (Always Run)
Write-GiipLog "INFO" "Running in NORMAL MODE"
$NormalScript = Join-Path $ScriptDir "scripts\NormalMode.ps1"
if (Test-Path $NormalScript) {
    # Execute as independent script
    & $NormalScript
    Write-GiipLog "INFO" "Normal mode completed. Exit Code: $LASTEXITCODE"
}
else {
    Write-GiipLog "ERROR" "Normal mode script not found: $NormalScript"
}

# 8. Completion
Write-GiipLog "INFO" "giipAgent3.ps1 completed."
exit 0
