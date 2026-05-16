﻿# ============================================================================
# giipAgent DB Collector Library (PowerShell)
# Purpose: MSSQL & MySQL Performance Metrics Collection
# ============================================================================

function Get-GiipDbMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][PSObject]$DbInfo,
        [Parameter(Mandatory = $true)][string]$LibDir,
        [Parameter(Mandatory = $true)][PSObject]$Config
    )

    $results = @{
        uptime             = 0
        threads_connected  = 0
        questions_per_sec  = 0
        buffer_pool_usage  = 0
        cpu_usage          = 0
        memory_usage       = 0
        query_analysis     = @()
    }

    $dbType = $DbInfo.db_type
    $ip = $DbInfo.ip
    $port = $DbInfo.port
    $user = $DbInfo.user
    $pass = $DbInfo.pass

    Write-GiipLog "INFO" "Collecting metrics for $dbType on $ip : $port"

    try {
        if ($dbType -eq "mssql") {
            # MSSQL Collection Logic (using SqlConnectionStringBuilder)
            $connBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
            $connBuilder["Data Source"] = "$ip,$port"
            $connBuilder["User ID"] = $user
            $connBuilder["Password"] = $pass
            $connBuilder["Connect Timeout"] = 15
            
            $conn = New-Object System.Data.SqlClient.SqlConnection($connBuilder.ConnectionString)
            $conn.Open()
            
            # (Logic for MSSQL Uptime, Threads, etc.)
            # ... 
            
            $conn.Close()
        }
        elseif ($dbType -eq "mysql") {
            # MySQL Collection Logic
            if (Import-MySqlDll -LibDir $LibDir) {
                $connStr = "Server=$ip;Port=$port;Uid=$user;Pwd=$pass;Connect Timeout=15;"
                $conn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
                $conn.Open()
                
                # (Logic for MySQL Uptime, Threads, Buffer Pool, etc.)
                # ...
                
                $conn.Close()
            }
        }
    } catch {
        Write-GiipLog "ERROR" "Failed to collect metrics: $($_.Exception.Message)"
    }

    return $results
}
