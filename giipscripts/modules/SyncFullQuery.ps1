# ============================================================================
# SyncFullQuery.ps1
# Purpose: Periodically collect full SQL query text for query_hashes in tKVS
# Usage: Run as CQE script
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
    . (Join-Path $LibDir "KVS.ps1")
}
catch {
    Write-Host "FATAL: Failed to load libraries from $LibDir"
    exit 1
}

# 1. Load Config
$Config = Get-GiipConfig

# 2. Get DB List
$reqData = @{ lssn = $Config.lssn }
$reqJson = $reqData | ConvertTo-Json -Compress
$response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson
$dbList = $response.data ?: @($response)

foreach ($db in $dbList) {
    if ($db.db_type -ne 'MSSQL') { continue }
    
    try {
        $connStr = "Server=$($db.db_host),$($db.db_port);Database=master;User Id=$($db.db_user);Password=$($db.db_password);TrustServerCertificate=True;Connection Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $conn.Open()
        
        # Collect full SQL for queries executed in the last hour
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
            SELECT 
                CONVERT(NVARCHAR(64), qs.query_hash, 1) as query_hash,
                st.text as full_text
            FROM sys.dm_exec_query_stats qs
            CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
            WHERE qs.last_execution_time > DATEADD(HOUR, -1, GETDATE())
"@
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $hash = $reader["query_hash"]
            $text = $reader["full_text"]
            if ($hash -and $text) {
                Invoke-GiipKvsPut -Config $Config -Type "query" -Key "$hash" -Factor "full_text" -Value $text
            }
        }
        $reader.Close()
        $conn.Close()
    }
    catch {
        Write-GiipLog "WARN" "Failed to sync full queries for $($db.db_host): $_"
    }
}

exit 0
