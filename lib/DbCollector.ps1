function Get-GiipDbMetrics {
    param (
        [Parameter(Mandatory = $true)]
        [PSObject]$DbInfo,
        
        [Parameter(Mandatory = $true)]
        [string]$LibDir,

        [Parameter(Mandatory = $true)]
        [PSObject]$Config
    )

    $mdb_id = $DbInfo.mdb_id
    $db_type = $DbInfo.db_type
    $dbHost = $DbInfo.db_host
    $port = $DbInfo.db_port
    $user = $DbInfo.db_user
    $pass = $DbInfo.db_password

    # Default Stat Structure
    $stat = @{
        mdb_id      = $mdb_id
        uptime      = 0
        threads     = 0
        qps         = 0
        buffer_pool = 0
        cpu         = 0
        memory      = 0
    }

    Write-GiipLog "DEBUG" "[DbCollector] Checking DB: $mdb_id ($db_type) at $dbHost"

    if ($db_type -eq 'MSSQL') {
        # MSSQL Collection
        try {
            $connStr = "Server=$dbHost,$port;Database=master;User Id=$user;Password=$pass;TrustServerCertificate=True;Connection Timeout=5;" # Reduced timeout to 5s
            $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
            $conn.Open()
            
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = @"
                SELECT 
                    (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'User Connections') as threads,
                    (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Batch Requests/sec') as qps,
                    (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Total Server Memory (KB)') as memory_kb,
                    (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) as start_time
"@
            $reader = $cmd.ExecuteReader()
            if ($reader.Read()) {
                $stat.threads = $reader["threads"]
                $stat.qps = $reader["qps"]
                
                $mem_kb = $reader["memory_kb"]
                $stat.memory = [math]::Round([double]$mem_kb / 1024, 0)
                
                $startTime = $reader["start_time"]
                if ($startTime) {
                    $stat.uptime = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
                }
            }
            $reader.Close()
            $conn.Close()
            
            Write-GiipLog "DEBUG" "[DbCollector] ✅ Successfully collected metrics for DB $mdb_id"
            return $stat
        }
        catch {
            # Log to local file with WARN
            Write-GiipLog "WARN" "[DbCollector] ❌ MSSQL Connection failed for DB ${mdb_id} ($dbHost): $($_.Exception.Message)"
            
            # Send to Central Error Log only if it's not a simple timeout or for visibility as 'warn'
            try {
                $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
                if (Test-Path $errorLogPath) {
                    . $errorLogPath
                    $errData = @{
                        mdb_id    = $mdb_id
                        db_host   = $dbHost
                        exception = $_.Exception.Message
                        source    = "DbCollector"
                    } | ConvertTo-Json -Compress
                    
                    # Reduce noise by setting severity to 'warn' for connection issues
                    sendErrorLog -Config $Config `
                        -Message "[DbCollector] MSSQL Connection Failed (ID: ${mdb_id}, Host: ${dbHost})" `
                        -Data $errData `
                        -Severity "warn" `
                        -ErrorType "DbConnectionWarning" | Out-Null
                }
            }
            catch {}
            
            return $null
        }
    }
    elseif ($db_type -match 'MySQL|MariaDB') {
        # MySQL Collection
        $dllPath = Join-Path $LibDir "MySql.Data.dll"
        if (Test-Path $dllPath) {
            try {
                [void][System.Reflection.Assembly]::LoadFile($dllPath)
                $connStr = "Server=$dbHost;Port=$port;Uid=$user;Pwd=$pass;SslMode=None;Connection Timeout=10;"
                $conn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
                $conn.Open()
                
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected', 'Questions', 'Innodb_buffer_pool_pages_total', 'Innodb_buffer_pool_pages_free', 'Uptime')"
                $reader = $cmd.ExecuteReader()
                
                while ($reader.Read()) {
                    $name = $reader["Variable_name"]
                    $val = $reader["Value"]
                    
                    switch ($name) {
                        'Threads_connected' { $stat.threads = [int]$val }
                        'Uptime' { $stat.uptime = [long]$val }
                        'Questions' { $stat.qps = [float]$val }
                        'Innodb_buffer_pool_pages_total' { $total_pages = [float]$val }
                        'Innodb_buffer_pool_pages_free' { $free_pages = [float]$val }
                    }
                }
                if ($total_pages -gt 0) {
                    $stat.buffer_pool = [math]::Round((($total_pages - $free_pages) / $total_pages) * 100, 2)
                }
                $conn.Close()
                
                Write-GiipLog "DEBUG" "[DbCollector] ✅ Successfully collected metrics for DB $mdb_id (MySQL)"
                return $stat
            }
            catch {
                Write-GiipLog "WARN" "[DbCollector] MySQL Error for ${dbHost}: $_"
                return $null
            }
        }
        else {
            Write-GiipLog "WARN" "[DbCollector] Skipping MySQL: MySql.Data.dll not found."
            return $null
        }
    }
    else {
        Write-GiipLog "INFO" "[DbCollector] DB Type $db_type not supported."
        return $null
    }
}
