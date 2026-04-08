# ============================================================================
# DbCollector.ps1 (Restored Pure English Version)
# Purpose: Collect and Format MSSQL/MySQL Database Metrics
# ============================================================================

function Get-GiipDbMetrics {
    param(
        [Parameter(Mandatory=$true)][string]$Type,
        [Parameter(Mandatory=$true)][string]$ConnStr
    )

    $results = @()
    
    try {
        if ($Type -eq "mssql") {
            $query = @"
SELECT 
    d.name AS db_name,
    SUM(mf.size) * 8 / 1024 AS size_mb,
    (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE database_id = d.database_id) AS active_conns
FROM sys.databases d
JOIN sys.master_files mf ON d.database_id = mf.database_id
GROUP BY d.name, d.database_id
"@
            $conn = New-Object System.Data.SqlClient.SqlConnection($ConnStr)
            $cmd = New-Object System.Data.SqlClient.SqlCommand($query, $conn)
            $conn.Open()
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $results += @{
                    dbname = $reader["db_name"].ToString()
                    size   = $reader["size_mb"].ToString()
                    conns  = $reader["active_conns"].ToString()
                }
            }
            $conn.Close()
        }
        elseif ($Type -eq "mysql") {
            # Requires MySql.Data.dll logic here (simplified for core restoration)
            Write-GiipLog "INFO" "[DbCollector] MySQL collection not fully implemented in this stub."
        }
    }
    catch {
        Write-GiipLog "WARN" "[DbCollector] Failed to collect metrics for $Type: $($_.Exception.Message)"
    }
    
    return $results
}

Write-Host "[DbCollector] Loaded."
