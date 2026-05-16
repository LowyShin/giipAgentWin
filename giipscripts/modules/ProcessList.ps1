# ============================================================================
# ProcessList.ps1 (Restored Pure ASCII Version)
# Purpose: Collect Windows Process List and send to KVS
# ============================================================================

try {
    # Load Library Dependencies
    $LibDir = Join-Path $Global:BaseDir "lib"
    if (Test-Path (Join-Path $LibDir "KVS.ps1")) { . (Join-Path $LibDir "KVS.ps1") }
    
    $Config = Get-GiipConfig

    # 1. Collect Process List (Top 100 by Memory to prevent DB truncation)
    $processes = Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet, StartTime, MainWindowTitle | 
                 Sort-Object -Property WorkingSet -Descending | Select-Object -First 100

    # Format as a string table
    $sb = new-object System.Text.StringBuilder
    $sb.AppendLine(("{0,-8} {1,-30} {2,-10} {3,-15} {4,-25} {5}" -f "PID", "Name", "CPU(s)", "Mem(MB)", "StartTime", "Title"))
    $sb.AppendLine("-" * 120)

    foreach ($p in $processes) {
        $cpu = if ($p.CPU) { "{0:N2}" -f $p.CPU } else { "0.00" }
        $mem = if ($p.WorkingSet) { "{0:N2}" -f ($p.WorkingSet / 1MB) } else { "0.00" }
        $start = if ($p.StartTime) { $p.StartTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "-" }
        $title = if ($p.MainWindowTitle) { $p.MainWindowTitle } else { "" }
        if ($title.Length -gt 50) { $title = $title.Substring(0, 47) + "..." }
        
        $sb.AppendLine(("{0,-8} {1,-30} {2,-10} {3,-15} {4,-25} {5}" -f $p.Id, $p.ProcessName, $cpu, $mem, $start, $title))
    }

    $processListText = $sb.ToString()
    # Hard truncation at 7,500 chars for DB safety (tKvs.kValue often VARCHAR(8000))
    if ($processListText.Length -gt 7500) {
        $processListText = $processListText.Substring(0, 7480) + "...(TRUNCATED)"
    }

    # 2. Send to KVS
    $response = Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key $Config.lssn -Factor "process_list" -Value $processListText

    if ($response.RstVal -eq "200") {
        Write-GiipLog "INFO" "[ProcessList] Successfully uploaded process list."
    } else {
        Write-GiipLog "WARN" "[ProcessList] Upload failed: $($response.RstMsg)"
    }
}
catch {
    Write-GiipLog "ERROR" "[ProcessList] Failed: $_"
}
