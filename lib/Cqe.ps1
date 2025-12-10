
# ============================================================================
# giipAgent CQE (Centralized Queue Engine) Library (PowerShell)
# Version: 1.00
# Date: 2025-01-10
# Purpose: CQE API wrapper functions for queue fetching
# ============================================================================

if (-not (Get-Command Invoke-GiipApiV2 -ErrorAction SilentlyContinue)) {
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $commonPath = Join-Path $scriptDir "Common.ps1"
    if (Test-Path $commonPath) { . $commonPath }
}

# Function: Fetch queue from API
# Returns: script content (string) or $null if no queue or error
function Get-Queue {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Hostname
    )

    $lssn = $Config.lssn
    # Determine OS string specifically for API
    # Linux agent uses 'detect_os', returns e.g. 'centos', 'ubuntu', 'windows' (?)
    # Let's use 'windows' generic or specific version.
    $os = "windows" 
    
    $text = "CQEQueueGet lssn hostname os op"
    $jsondata = @{
        lssn     = $lssn
        hostname = $Hostname
        os       = $os
        op       = "op"
    } | ConvertTo-Json -Compress

    $response = Invoke-GiipApiV2 -Config $Config -CommandText $text -JsonData $jsondata

    if (-not $response) {
        Write-GiipLog "WARN" "CQEQueueGet API call failed or returned null"
        return $null
    }

    # Analyze Response
    # Structure: { data: [ { RstVal: "200", ms_body: "...", ... } ] } or direct keys
    
    $data = $null
    if ($response.data -and $response.data.Count -gt 0) {
        $data = $response.data[0]
    }
    elseif ($response.RstVal) {
        $data = $response
    }

    if (-not $data) {
        Write-GiipLog "WARN" "CQEQueueGet response invalid structure"
        return $null
    }

    $rstVal = $data.RstVal
    
    # Check 404/No Queue
    if ($rstVal -ne "200") {
        # Check if it's a 404-like response
        # Linux logic: proc_name *404* or rst_val *404* or 0
        $procName = $data.ProcName
        if ($rstVal -match "404" -or $procName -match "404" -or $rstVal -eq "0") {
            # This is normal (No Queue)
            return $null
        }
        
        Write-GiipLog "ERROR" "CQEQueueGet returned error: RstVal=$rstVal, ProcName=$procName"
        return $null
    }

    $scriptBody = $data.ms_body
    return $scriptBody
}
