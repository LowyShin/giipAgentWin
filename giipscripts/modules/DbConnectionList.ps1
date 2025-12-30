# ============================================================================
# DbConnectionList.ps1
# Purpose: Collect active client connections from managed databases (Net3D)
# Usage: .\DbConnectionList.ps1
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

# ============================================================================
# Function: Get-MSSQLConnections
# Purpose: Collect connection info from MSSQL database
# Returns: Array of connection objects
# ============================================================================
function Get-MSSQLConnections {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DbHost,
        
        [Parameter(Mandatory = $true)]
        [int]$Port,
        
        [Parameter(Mandatory = $true)]
        [string]$User,
        
        [Parameter(Mandatory = $true)]
        [string]$Pass
    )
    
    $connStr = "Server=$DbHost,$Port;Database=master;User Id=$User;Password=$Pass;TrustServerCertificate=True;Connection Timeout=10;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()
    
    $connList = @()
    
    try {
        # Try performance query first (requires VIEW SERVER PERFORMANCE STATE)
        try {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = @"
                SELECT 
                    c.client_net_address,
                    MAX(s.program_name) as program_name,
                    COUNT(*) as conn_count,
                    ISNULL(SUM(r.cpu_time), 0) as cpu_load,
                    MAX(REPLACE(REPLACE(SUBSTRING(t.text, 1, 200), CHAR(13), ' '), CHAR(10), ' ')) as last_sql
                FROM sys.dm_exec_connections c
                JOIN sys.dm_exec_sessions s ON c.session_id = s.session_id
                LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
                OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
                GROUP BY c.client_net_address
"@
            $reader = $cmd.ExecuteReader()
            
            while ($reader.Read()) {
                $connList += @{
                    client_net_address = $reader["client_net_address"]
                    program_name       = $reader["program_name"]
                    conn_count         = $reader["conn_count"]
                    cpu_load           = $reader["cpu_load"]
                    last_sql           = $reader["last_sql"]
                }
            }
            $reader.Close()
        }
        catch {
            # Permission denied - use fallback query (basic info only)
            if ($_.Exception.Message -like "*VIEW SERVER PERFORMANCE STATE*") {
                Write-GiipLog "WARN" "[DbConnectionList] No VIEW SERVER PERFORMANCE STATE permission for $DbHost. Using basic query."
                
                # Fallback: Basic connection count only
                $cmdFallback = $conn.CreateCommand()
                $cmdFallback.CommandText = @"
                    SELECT 
                        'N/A' as client_net_address,
                        'N/A' as program_name,
                        COUNT(*) as conn_count,
                        0 as cpu_load,
                        'Permission denied' as last_sql
                    FROM sys.dm_exec_sessions
                    WHERE is_user_process = 1
"@
                $readerFallback = $cmdFallback.ExecuteReader()
                
                while ($readerFallback.Read()) {
                    $connList += @{
                        client_net_address = $readerFallback["client_net_address"]
                        program_name       = $readerFallback["program_name"]
                        conn_count         = $readerFallback["conn_count"]
                        cpu_load           = $readerFallback["cpu_load"]
                        last_sql           = $readerFallback["last_sql"]
                    }
                }
                $readerFallback.Close()
            }
            else {
                # Other error - rethrow
                throw
            }
        }
    }
    finally {
        $conn.Close()
    }
    
    return $connList
}

# ============================================================================
# Function: Send-ConnectionData
# Purpose: Send connection data to API
# ============================================================================
function Send-ConnectionData {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        
        [Parameter(Mandatory = $true)]
        [int]$MdbId,
        
        [Parameter(Mandatory = $true)]
        [array]$ConnList
    )
    
    if ($ConnList.Count -eq 0) {
        return $false
    }
    
    Write-GiipLog "INFO" "[DbConnectionList] Sending connection data for DB: $MdbId"
    
    $response = Invoke-GiipKvsPut -Config $Config -Type "database" -Key "$MdbId" -Factor "db_connections" -Value $ConnList
    
    # ========== DEBUG: 응답 검증 ==========
    if ($null -eq $response) {
        Write-GiipLog "ERROR" "[DbConnectionList] ❌ API returned NULL for DB $MdbId"
        Write-Host "[DbConnectionList] Response is NULL!" -ForegroundColor Red
        return $false
    }
    
    Write-Host "[DbConnectionList] Response Type: $($response.GetType().Name)" -ForegroundColor Cyan
    
    if ($response -is [PSCustomObject]) {
        $props = $response.PSObject.Properties.Name
        Write-Host "[DbConnectionList] Response Properties: $($props -join ', ')" -ForegroundColor Cyan
        Write-Host "[DbConnectionList] RstVal: '$($response.RstVal)'" -ForegroundColor Cyan
        Write-Host "[DbConnectionList] RstMsg: '$($response.RstMsg)'" -ForegroundColor Cyan
    }
    elseif ($response -is [Hashtable]) {
        Write-Host "[DbConnectionList] Response Keys: $($response.Keys -join ', ')" -ForegroundColor Cyan
    }
    else {
        Write-Host "[DbConnectionList] Response Content: $response" -ForegroundColor Cyan
    }
    
    if ($response.RstVal -eq "200") {
        Write-GiipLog "INFO" "[DbConnectionList] Success for DB $MdbId."
        return $true
    }
    else {
        Write-GiipLog "WARN" "[DbConnectionList] API Error for DB $MdbId"
        Write-GiipLog "WARN" "RstVal: '$($response.RstVal)'"
        Write-GiipLog "WARN" "RstMsg: '$($response.RstMsg)'"
        return $false
    }
}

# ============================================================================
# Main Logic
# ============================================================================

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
}
catch {
    Write-GiipLog "ERROR" "[DbConnectionList] Failed to load config: $_"
    exit 1
}

Write-GiipLog "INFO" "[DbConnectionList] Starting..."

# 1. Get DB List from API
try {
    $reqData = @{ lssn = $Config.lssn }
    $reqJson = $reqData | ConvertTo-Json -Compress
    
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson
    
    $dbList = $null
    
    if ($response.data) { $dbList = $response.data }
    elseif ($response -is [Array]) { $dbList = $response }
    elseif ($response.mdb_id) { $dbList = @($response) }

    if (-not $dbList) {
        Write-GiipLog "INFO" "[DbConnectionList] No databases found."
        exit 0
    }

    if (-not ($dbList -is [Array] -or $dbList -is [System.Collections.IEnumerable])) {
        $dbList = @($dbList)
    }

    Write-GiipLog "INFO" "[DbConnectionList] Found $($dbList.Count) databases."
}
catch {
    Write-GiipLog "ERROR" "[DbConnectionList] Failed to get DB list: $_"
    exit 1
}

# 2. Process Each Database
foreach ($db in $dbList) {
    try {
        # Skip non-MSSQL databases
        if ($db.db_type -ne 'MSSQL') {
            continue
        }
        
        # Collect connections
        $connList = Get-MSSQLConnections -DbHost $db.db_host -Port $db.db_port -User $db.db_user -Pass $db.db_password
        
        # Send to API
        Send-ConnectionData -Config $Config -MdbId $db.mdb_id -ConnList $connList
    }
    catch {
        Write-GiipLog "WARN" "[DbConnectionList] Failed for $($db.db_host): $_"
    }
}

Write-GiipLog "INFO" "[DbConnectionList] Completed."
exit 0
