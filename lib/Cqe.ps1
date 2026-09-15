
# ============================================================================
# giipAgent CQE (Centralized Queue Engine) Library (PowerShell)
# Version: 1.00
# Date: 2025-01-10
# Purpose: CQE API wrapper functions for queue fetching
#
# ⚠️ giip #2546 - 이 파일의 Get-Queue 는 **호출자 없는 죽은 코드**다.
#    유일한 호출자였던 scripts\NormalMode.ps1 역시 Task Scheduler 에 등록돼
#    있지 않다(등록된 작업은 'GIIP Agent Task (v3)' = giipAgent3.ps1 하나뿐).
#    운영 경로의 큐 조회는 giipscripts\modules\CqeGet.ps1 이, 실행은
#    giipscripts\modules\CqeRun.ps1 이 담당한다.
#    또한 Get-Queue 는 ms_body 만 돌려주므로 script_type/mslsn/mssn 을 잃어버려
#    실행 이력 추적(giip-967)에도 쓸 수 없다.
#    이 파일은 **정리(삭제) 후보**이며 후속 이슈로 올린다.
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

