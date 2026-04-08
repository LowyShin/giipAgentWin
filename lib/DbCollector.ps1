# ============================================================================
# DbCollector.ps1 (Fixed Syntax Pure ASCII Version)
# Purpose: Database metrics collection for MSSQL and MySQL/MariaDB
# ============================================================================

function Get-GiipDbMetrics {
    param (
        [Parameter(Mandatory = $true)][PSObject]$DbInfo,
        [Parameter(Mandatory = $true)][string]$LibDir,
        [Parameter(Mandatory = $true)][PSObject]$Config
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
        query_hash  = ""
    }

    Write-GiipLog "DEBUG" "[DbCollector] Checking DB: ${mdb_id} (${db_type}) at ${dbHost}"

    if ($db_type -eq 'MSSQL') {
        try {
            $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
            $builder.DataSource = "${dbHost},${port}"
            $builder.InitialCatalog = "master"
            $builder.UserID = $user
            $builder.Password = $pass
            $builder.TrustServerCertificate = $true
            $builder.ConnectTimeout = 10
            
            $conn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
            $conn.Open()
            
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'User Connections') as threads, (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Batch Requests/sec') as qps, (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Total Server Memory (KB)') as memory_kb, (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) as start_time, (SELECT TOP 1 CONVERT(NVARCHAR(64), query_hash, 1) FROM sys.dm_exec_requests WHERE query_hash != 0x0 ORDER BY cpu_time DESC) as active_query_hash"
            
            $reader = $cmd.ExecuteReader()
            if ($reader.Read()) {
                $stat.threads = $reader["threads"]
                $stat.qps = $reader["qps"]
                $stat.memory = [math]::Round([double]$reader["memory_kb"] / 1024, 0)
                if ($reader["start_time"]) { $stat.uptime = [math]::Round(((Get-Date) - $reader["start_time"]).TotalSeconds, 0) }
                if ($reader["active_query_hash"] -isnot [System.DBNull]) { $stat.query_hash = $reader["active_query_hash"] }
            }
            $reader.Close(); $conn.Close()
            return $stat
        } catch {
            Write-GiipLog "WARN" "[DbCollector] MSSQL Error for ${mdb_id} : $($_.Exception.Message)"
            return $null
        }
    }
    elseif ($db_type -match 'MySQL|MariaDB') {
        if (Import-MySqlDll -LibDir $LibDir) {
            try {
                $connStr = "Server=${dbHost};Port=${port};Uid=${user};Pwd=${pass};SslMode=None;Connection Timeout=10;"
                $conn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected', 'Questions', 'Innodb_buffer_pool_pages_total', 'Innodb_buffer_pool_pages_free', 'Uptime'); SELECT info FROM information_schema.processlist WHERE command != 'Sleep' AND info IS NOT NULL ORDER BY time DESC LIMIT 1;"
                $reader = $cmd.ExecuteReader()
                
                $total_pages = 0; $free_pages = 0
                while ($reader.Read()) {
                    $name = $reader["Variable_name"]; $val = $reader["Value"]
                    switch ($name) {
                        'Threads_connected' { $stat.threads = [int]$val }
                        'Uptime' { $stat.uptime = [long]$val }
                        'Questions' { $stat.qps = [float]$val }
                        'Innodb_buffer_pool_pages_total' { $total_pages = [float]$val }
                        'Innodb_buffer_pool_pages_free' { $free_pages = [float]$val }
                    }
                }
                if ($reader.NextResult() -and $reader.Read()) {
                    if ($reader["info"] -isnot [System.DBNull]) { $stat.query_hash = Get-StringMd5 -InputString $reader["info"] }
                }
                if ($total_pages -gt 0) { $stat.buffer_pool = [math]::Round((($total_pages - $free_pages) / $total_pages) * 100, 2) }
                $conn.Close()
                return $stat
            } catch {
                Write-GiipLog "WARN" "[DbCollector] MySQL Error for ${mdb_id} : $_"
                return $null
            }
        }
    }
    return $null
}
