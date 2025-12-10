
# ============================================================================
# giipAgent Discovery Library (PowerShell)
# Version: 1.00
# Date: 2025-01-10
# Purpose: Auto-discovery execution and reporting
# ============================================================================

if (-not (Get-Command Send-KVSPut -ErrorAction SilentlyContinue)) {
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $kvsPath = Join-Path $scriptDir "Kvs.ps1"
    if (Test-Path $kvsPath) { . $kvsPath }
}

$DISCOVERY_INTERVAL_SEC = 21600 # 6 hours

function Invoke-Discovery {
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $lssn = $Config.lssn
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent 
    # Assume lib is at root/lib, scripts at root/giipscripts
    $baseDir = Split-Path -Path $scriptDir -Parent
    
    $discoveryScript = Join-Path $baseDir "giipscripts\auto-discover-win.ps1"
    $stateFile = Join-Path $env:TEMP "giip_discovery_state_$lssn.txt"

    # 1. Check Interval
    $shouldRun = $true
    if (Test-Path $stateFile) {
        $lastRun = [int64](Get-Content $stateFile)
        $now = [int64](Get-Date -UFormat %s)
        if (($now - $lastRun) -lt $DISCOVERY_INTERVAL_SEC) {
            $shouldRun = $false
        }
    }

    if (-not $shouldRun) {
        Write-GiipLog "INFO" "Discovery skipped (Interval not reached)"
        return
    }

    # 2. Check Script
    if (-not (Test-Path $discoveryScript)) {
        Write-GiipLog "ERROR" "Discovery script not found: $discoveryScript"
        # Log error to KVS
        Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ type = "discovery"; msg = "Script not found" }
        return
    }

    Write-GiipLog "INFO" "Starting Discovery..."
    
    # 3. Execute Script
    try {
        # Execute and capture JSON output
        $jsonResult = & $discoveryScript
        
        # Validate JSON
        try {
            $jsonObj = $jsonResult | ConvertFrom-Json
        }
        catch {
            Write-GiipLog "ERROR" "Discovery script output invalid JSON"
            Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ type = "discovery"; msg = "Invalid JSON" }
            return
        }
        
        # 4. Save to KVS
        # We save the full result. Linux splits it, but KVS supports large JSON in kValue preferably.
        # Linux `collect_infrastructure_data` saves `auto_discover_result` (full json).
        
        # Compress JSON for transport
        $jsonString = $jsonObj | ConvertTo-Json -Depth 10 -Compress
        
        Send-KVSPut -Config $Config -kType "lssn" -kKey $lssn -kFactor "auto_discover_result" -kValue $jsonString
        
        # Update State
        [int64](Get-Date -UFormat %s) | Set-Content $stateFile
        
        Write-GiipLog "INFO" "Discovery completed and saved."

    }
    catch {
        Write-GiipLog "ERROR" "Discovery execution failed: $_"
        Save-ExecutionLog -Config $Config -EventType "error" -DetailsObj @{ type = "discovery"; msg = $_.Exception.Message }
    }
}
