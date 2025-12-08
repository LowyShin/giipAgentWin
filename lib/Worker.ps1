# ============================================================================
# giipAgentWin Library: Worker Functions
# Purpose: Queue Processing, Task Execution, and Result Reporting
# ============================================================================

#region ====== Queue Logic ======
function Get-QueueItem {
    param([hashtable]$Config)
    
    $sysInfo = Get-SystemInfo
    $hn = $sysInfo.Hostname
    $os = $sysInfo.OSName
    $sv = "2.0" # Agent Version

    # SP: pApiCQEQueueGetbySk (Implied by Command string context)
    # Command: CQEQueueGet
    # Params: lssn hn os sv df
    $cmdText = "CQEQueueGet lssn hn os sv df"
    
    $payload = @{
        lssn = $Config.lssn
        hn   = $hn
        os   = $os
        sv   = $sv
        df   = "os"
    } | ConvertTo-Json -Compress

    $response = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $payload
    
    # API V2 returns string data (Raw Response)
    # If using Invoke-RestMethod with JSON response type, it might be an object.
    # But usually CQE returns a raw string or JSON wrapped string.
    # Let's assume it returns the raw content body string.
    
    return $response
}

function Report-TaskResult {
    param(
        [hashtable]$Config,
        [string]$Qsn,
        [string]$Status, # success/fail
        [string]$Output
    )
    
    # Truncate Output standard (500 chars)
    $snippet = $Output
    if ($snippet.Length -gt 500) { $snippet = $snippet.Substring(0, 500) }
    
    # Clean JSON string issues if manually built, but ConvertTo-Json handles it.
    
    # SP: pApiKVSPutbySk
    # Command: KVSPut
    # Params: kType kKey kFactor kValue
    $cmdText = "KVSPut kType kKey kFactor kValue"
    
    $kValueObj = @{
        qsn    = $Qsn
        status = $Status
        output = $snippet
    }

    $payload = @{
        kType   = "lssn"
        kKey    = $Config.lssn
        kFactor = "giipAgentLog"
        kValue  = $kValueObj # Nested JSON logic often handled by API, but usually passing object here works if server expects JSON
    } | ConvertTo-Json -Compress -Depth 5

    $result = Invoke-GiipApiV2 -Config $Config -CommandText $cmdText -JsonData $payload
    Write-GiipLog "DEBUG" "Report Result: $result"
}
#endregion

#region ====== Execution Logic ======
function Invoke-AgentTask {
    param(
        [string]$RawQueueItem,
        [hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($RawQueueItem)) { return }

    # CASE 1: Numeric (Registration Success/Update)
    if ($RawQueueItem -match '^\d+$') {
        Write-GiipLog "INFO" "Received numeric LSSN update: $RawQueueItem"
        Update-ConfigLssn -NewLssn $RawQueueItem
        $Config.lssn = $RawQueueItem # Update runtime config too
        return
    }

    # CASE 2: Task (QSN||TYPE||BODY)
    $parts = $RawQueueItem -split '\|\|'
    if ($parts.Count -lt 3) {
        Write-GiipLog "WARN" "Invalid queue item format: $RawQueueItem"
        return
    }

    $qsn = $parts[0]
    $type = $parts[1].ToLower()
    $body = $parts[2]

    Write-GiipLog "INFO" "Executing Task QSN=$qsn Type=$type"

    # Replace placeholders
    $body = $body.Replace('{{sk}}', $Config.sk).Replace('{{lssn}}', $Config.lssn)

    # Execute
    $execResult = Invoke-ScriptBlock -Type $type -Body $body
    
    # Report
    $status = if ($execResult.Success) { "success" } else { "error" }
    Report-TaskResult -Config $Config -Qsn $qsn -Status $status -Output $execResult.Output
}

function Invoke-ScriptBlock {
    param(
        [ValidateSet('wsf', 'ps1', 'cmd')] [string]$Type,
        [string]$Body
    )

    $TempDir = [System.IO.Path]::GetTempPath()
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $filename = "giip_task_${timestamp}_$((Get-Random))"
    
    $ext = switch ($Type) {
        'wsf' { '.wsf' }
        'ps1' { '.ps1' }
        default { '.cmd' }
    }
    
    $tempFile = Join-Path $TempDir ($filename + $ext)
    
    try {
        # UTF8 No BOM for best compat
        [System.IO.File]::WriteAllText($tempFile, $Body, [System.Text.UTF8Encoding]::new($false))

        $cmdArgs = switch ($Type) {
            'wsf' { "//B //Nologo `"$tempFile`"" }
            'ps1' { "-NoProfile -ExecutionPolicy Bypass -File `"$tempFile`"" }
            default { "/c `"$tempFile`"" }
        }
        
        $exe = switch ($Type) {
            'wsf' { "wscript.exe" }
            'ps1' { "powershell.exe" }
            default { "cmd.exe" }
        }

        # Run Process
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $exe
        $pInfo.Arguments = $cmdArgs
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $pInfo
        $p.Start() | Out-Null
        
        if ($p.WaitForExit(60000)) {
            # 60s Timeout
            $stdOut = $p.StandardOutput.ReadToEnd()
            $stdErr = $p.StandardError.ReadToEnd()
            return @{
                Success = ($p.ExitCode -eq 0)
                Output  = $stdOut + "`n" + $stdErr
            }
        }
        else {
            $p.Kill()
            return @{ Success = $false; Output = "Timeout (60s)" }
        }

    }
    catch {
        return @{ Success = $false; Output = "Execution Error: $_" }
    }
    finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}
#endregion
