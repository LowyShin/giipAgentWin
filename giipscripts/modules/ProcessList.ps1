# ============================================================================
# ProcessList.ps1
# Purpose: Collect Windows Process List and send to KVS
# Usage: . (Join-Path $ModuleDir "ProcessList.ps1")
# Dependencies: Common.ps1, Kvs.ps1
# ============================================================================

try {
    # Load Config (Assume Common/Kvs loaded by caller or load here if needed)
    $Config = Get-GiipConfig

    # 1. Collect Process List
    # Mimic Linux 'ps -ef' style or detailed list
    # Select key properties to keep payload reasonable
    $processes = Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet, StartTime, MainWindowTitle, Path | Sort-Object -Property Id

    # Format as a string table for readability (similar to Linux ps output)
    # Or JSON if the frontend parses it. The frontend page.tsx logic seems to handle both string and object.
    # Let's try to match the Linux agent's output format if possible, or provide a clean string table.
    
    # Text format approach (Header + Rows)
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

    # 2. Send to KVS
    # kFactor: process_list
    # kType: lssn
    # kKey: lssn
    
    $response = Invoke-GiipKvsPut -Config $Config -Type "lssn" -Key $Config.lssn -Factor "process_list" -Value $processListText

    if ($response.RstVal -eq "200") {
        Write-GiipLog "INFO" "[ProcessList] Successfully uploaded process list."
    }
    else {
        Write-GiipLog "WARN" "[ProcessList] Upload failed: $($response.RstMsg)"
    }

}
catch {
    Write-GiipLog "ERROR" "[ProcessList] Failed: $_"
}
