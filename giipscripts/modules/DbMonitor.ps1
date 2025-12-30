# ============================================================================
# DbMonitor.ps1
# Purpose: Fetch registered DB list and collect performance metrics
# Usage: .\DbMonitor.ps1
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$AgentRoot = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$LibDir = Join-Path $AgentRoot "lib"
$DataDir = Join-Path $AgentRoot "data"
$DbStatsFile = Join-Path $DataDir "db_stats.json"

# Load Libraries
try {
    . (Join-Path $LibDir "Common.ps1")
}
catch {
    Write-Host "FATAL: Failed to load Common.ps1 from $LibDir"
    exit 1
}

# Load Config
try {
    $Config = Get-GiipConfig
    if (-not $Config) { throw "Config is empty" }
}
catch {
    Write-GiipLog "ERROR" "[DbMonitor] Failed to load config: $_"
    
    # Config 로드 실패를 에러로그에 기록 (ErrorLog.ps1이 로드되지 않았으므로 직접 API 호출)
    try {
        # Try to load ErrorLog.ps1
        $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
        if (Test-Path $errorLogPath) {
            . $errorLogPath
            
            # Get minimal config for error logging
            $minimalConfig = @{
                sk        = if ($env:GIIP_SK) { $env:GIIP_SK } else { "CONFIG_FAILED" }
                apiaddrv2 = "https://giipfaw.azurewebsites.net/api/giipApiSk2"
            }
            
            sendErrorLog -Config $minimalConfig `
                -Message "[DbMonitor] FATAL: Failed to load config" `
                -Data @{
                step      = "DbMonitor_ConfigLoadFailed"
                exception = $_.Exception.Message
                scriptDir = $ScriptDir
                agentRoot = $AgentRoot
                libDir    = $LibDir
            } `
                -Severity "critical" `
                -ErrorType "DbMonitor_Fatal"
        }
    }
    catch {
        # If error logging also fails, just write to console
        Write-Host "[DbMonitor] Failed to log config error: $_"
    }
    
    exit 1
}

Write-GiipLog "INFO" "[DbMonitor] Starting DB Monitoring..."

# ========== DEBUG: DbMonitor 시작을 에러로그에 기록 ==========
try {
    $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
    if (Test-Path $errorLogPath) {
        . $errorLogPath
        sendErrorLog -Config $Config `
            -Message "[DbMonitor] Starting DB monitoring process" `
            -Data @{
            step      = "DbMonitor_Start"
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        } `
            -Severity "info" `
            -ErrorType "DbMonitor_Debug"
    }
}
catch {
    Write-GiipLog "WARN" "[DbMonitor] Failed to log debug info: $_"
}

# 1. Get DB List from API
try {
    # Command: MdbList (No args needed, SK is sent automatically by Invoke-GiipApiV2)
    # Note: Invoke-GiipApiV2 sends lssn/hostname/os inside JSON payload by default, 
    # but MdbList endpoint might just need 'code=MdbList'.
    # Assuming standard API call structure:
    # Debug Info
    $maskedSk = if ($Config.sk -and $Config.sk.Length -gt 4) { $Config.sk.Substring(0, 4) + "****" } else { "Invalid SK" }
    Write-GiipLog "INFO" "[DbMonitor] Requesting DB List using SK: $maskedSk"

    # Send LSSN to allow filtering by gateway_lssn on server side
    $reqData = @{ lssn = $Config.lssn }
    $reqJson = $reqData | ConvertTo-Json -Compress
    
    # Use unified SP 'pApiManagedDatabaseListForAgentbySk' which supports optional LSSN filtering
    # API Rule: text="Cmd ParamName" -> exec pApiCmdBySk @sk, @ParamValue
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson
    
    # Detailed Debug
    Write-GiipLog "DEBUG" "[DbMonitor] Raw Response Type: $($response.GetType().Name)"
    try {
        $debugJson = $response | ConvertTo-Json -Depth 2 -Compress
        Write-GiipLog "DEBUG" "[DbMonitor] Raw Response Content: $debugJson"
    }
    catch {
        Write-GiipLog "DEBUG" "[DbMonitor] Raw Response Content: (Cannot serialize)"
    }

    if ($response.RstVal) {
        Write-GiipLog "INFO" "[DbMonitor] API Result: Val=$($response.RstVal), Msg=$($response.RstMsg)"
    }
    
    $dbList = $null
    
    # Case 1: Wrapped in 'data' property
    if ($response.data) { 
        $dbList = $response.data 
    }
    # Case 2: Array of DBs (Standard list)
    elseif ($response -is [Array]) { 
        $dbList = $response 
    }
    # Case 3: Single DB Object (1 item returned) - Check for known property
    elseif ($response.mdb_id) {
        Write-GiipLog "INFO" "[DbMonitor] Single DB detected."
        $dbList = @($response)
    }

    if (-not $dbList) {
        Write-GiipLog "INFO" "[DbMonitor] No databases found to monitor (dbList is empty)."
        
        # ========== DEBUG: DB 리스트 없음을 에러로그에 기록 ==========
        try {
            $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
            if (Test-Path $errorLogPath) {
                . $errorLogPath
                sendErrorLog -Config $Config `
                    -Message "[DbMonitor] No databases found in DB list" `
                    -Data @{
                    step         = "DbMonitor_GetList"
                    responseType = $response.GetType().Name
                    hasData      = if ($response.data) { "yes" } else { "no" }
                    isArray      = if ($response -is [Array]) { "yes" } else { "no" }
                } `
                    -Severity "warn" `
                    -ErrorType "DbMonitor_Debug"
            }
        }
        catch {
            Write-GiipLog "WARN" "[DbMonitor] Failed to log debug info: $_"
        }
        
        exit 0
    }

    # Ensure it's an array/collection for the loop
    if (-not ($dbList -is [Array] -or $dbList -is [System.Collections.IEnumerable])) {
        $dbList = @($dbList)
    }

    Write-GiipLog "INFO" "[DbMonitor] Found $($dbList.Count) databases to monitor."
    
    # ========== CRITICAL DEBUG: Log DB list details ==========
    foreach ($db in $dbList) {
        Write-GiipLog "DEBUG" "[DbMonitor] Will monitor: DB ID=$($db.mdb_id), Name=$($db.db_name), Host=$($db.db_host), Type=$($db.db_type)"
    }
    
    # ========== DEBUG: DB 리스트를 에러로그에 기록 ==========
    try {
        $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
        if (Test-Path $errorLogPath) {
            . $errorLogPath
            $dbListInfo = $dbList | ForEach-Object {
                @{
                    mdb_id  = $_.mdb_id
                    db_name = $_.db_name
                    db_host = $_.db_host
                    db_type = $_.db_type
                }
            }
            sendErrorLog -Config $Config `
                -Message "[DbMonitor] Retrieved DB list for monitoring" `
                -Data @{
                step      = "DbMonitor_GetList"
                dbCount   = $dbList.Count
                databases = $dbListInfo
            } `
                -Severity "info" `
                -ErrorType "DbMonitor_Debug"
        }
    }
    catch {
        Write-GiipLog "WARN" "[DbMonitor] Failed to log debug info: $_"
    }

}
catch {
    Write-GiipLog "ERROR" "[DbMonitor] Failed to get DB list: $_"
    exit 1
}

# 2. Collect Stats
$statsList = @()

foreach ($db in $dbList) {
    try {
        $mdb_id = $db.mdb_id
        $db_type = $db.db_type
        $dbHost = $db.db_host
        $port = $db.db_port
        $user = $db.db_user
        $pass = $db.db_password # Decrypted by SP

        Write-GiipLog "DEBUG" "[DbMonitor] Checking DB: $mdb_id ($db_type) at $dbHost"
        
        $stat = @{
            mdb_id      = $mdb_id
            uptime      = 0
            threads     = 0
            qps         = 0
            buffer_pool = 0
            cpu         = 0
            memory      = 0
        }

        if ($db_type -eq 'MSSQL') {
            # MSSQL Collection using .NET SqlClient
            try {
                $connStr = "Server=$dbHost,$port;Database=master;User Id=$user;Password=$pass;TrustServerCertificate=True;Connection Timeout=10;"
                $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
                $conn.Open()
                
                # Simple Metrics
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
                    SELECT 
                        (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'User Connections') as threads,
                        (SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Batch Requests/sec') as qps, -- This is cumulative, need delta (simplified for now)
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
                $statsList += $stat
                Write-GiipLog "DEBUG" "[DbMonitor] ✅ Successfully collected metrics for DB $mdb_id ($dbHost)"
            }
            catch {
                Write-GiipLog "WARN" "[DbMonitor] ❌ MSSQL Connection failed for DB $mdb_id ($dbHost): $_"
                
                # DB 연결 실패도 에러로그에 기록
                try {
                    $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
                    if (Test-Path $errorLogPath) {
                        . $errorLogPath
                        sendErrorLog -Config $Config `
                            -Message "[DbMonitor] MSSQL connection failed - metrics not collected" `
                            -Data @{
                            mdb_id    = $mdb_id
                            db_host   = $dbHost
                            db_port   = $port
                            db_type   = $db_type
                            exception = $_.Exception.Message
                        } `
                            -Severity "warn" `
                            -ErrorType "DbConnectionFailed"
                    }
                }
                catch {
                    Write-GiipLog "WARN" "[DbMonitor] Failed to log DB connection error: $_"
                }
            }
        }
        elseif ($db_type -match 'MySQL|MariaDB') {
            # MySQL Collection
            # Requires MySql.Data.dll or similar.
            # Attempt to load assembly if present in lib
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
                    
                    $questions = 0
                    while ($reader.Read()) {
                        $name = $reader["Variable_name"]
                        $val = $reader["Value"]
                        
                        switch ($name) {
                            'Threads_connected' { $stat.threads = [int]$val }
                            'Uptime' { $stat.uptime = [long]$val }
                            'Questions' { $stat.qps = [float]$val } # Cumulative
                            'Innodb_buffer_pool_pages_total' { $total_pages = [float]$val }
                            'Innodb_buffer_pool_pages_free' { $free_pages = [float]$val }
                        }
                    }
                    if ($total_pages -gt 0) {
                        $stat.buffer_pool = [math]::Round((($total_pages - $free_pages) / $total_pages) * 100, 2)
                    }
                    $conn.Close()
                    $statsList += $stat
                }
                catch {
                    Write-GiipLog "WARN" "[DbMonitor] MySQL Error for $($dbHost): $_"
                }
            }
            else {
                Write-GiipLog "WARN" "[DbMonitor] Skipping MySQL $($dbHost): MySql.Data.dll not found in lib."
            }
        }
        else {
            Write-GiipLog "INFO" "[DbMonitor] DB Type $db_type not supported yet."
        }
    }
    catch {
        Write-GiipLog "ERROR" "[DbMonitor] Unexpected error on DB loop: $_"
    }
}

# 3. Send Stats
if ($statsList.Count -gt 0) {
    # ========== DEBUG: 메트릭 수집 성공을 에러로그에 기록 ==========
    try {
        $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
        if (Test-Path $errorLogPath) {
            . $errorLogPath
            sendErrorLog -Config $Config `
                -Message "[DbMonitor] Metrics collected successfully, preparing to send" `
                -Data @{
                step         = "DbMonitor_MetricsCollected"
                metricsCount = $statsList.Count
                databases    = ($statsList | ForEach-Object { $_.mdb_id }) -join ","
            } `
                -Severity "info" `
                -ErrorType "DbMonitor_Debug"
        }
    }
    catch {
        Write-GiipLog "WARN" "[DbMonitor] Failed to log debug info: $_"
    }
    
    try {
        $jsonPayload = $statsList | ConvertTo-Json -Compress
        Write-GiipLog "INFO" "[DbMonitor] Sending stats for $($statsList.Count) databases..."
        Write-GiipLog "DEBUG" "[DbMonitor] Stats Payload: $jsonPayload"
        
        # Must include 'jsondata' to pass payload to SP
        $response = Invoke-GiipApiV2 -Config $Config -CommandText "MdbStatsUpdate jsondata" -JsonData $jsonPayload
        
        # ========== DEBUG: Response Validation ==========
        Write-Host "[DbMonitor] Response Type: $($response.GetType().Name)" -ForegroundColor Cyan
        if ($response -is [PSCustomObject]) {
            $props = $response.PSObject.Properties.Name
            Write-Host "[DbMonitor] Response Properties: $($props -join ', ')" -ForegroundColor Cyan
            Write-Host "[DbMonitor] RstVal: '$($response.RstVal)'" -ForegroundColor Cyan
            Write-Host "[DbMonitor] RstMsg: '$($response.RstMsg)'" -ForegroundColor Cyan
        }
        
        if ($response.RstVal -eq "200") {
            Write-GiipLog "INFO" "[DbMonitor] ✅ MdbStatsUpdate SUCCESS - last_check_dt should be updated"
        }
        else {
            Write-GiipLog "WARN" "[DbMonitor] ⚠️ MdbStatsUpdate FAILED: RstVal=$($response.RstVal), RstMsg=$($response.RstMsg)"
            
            # 에러로그 DB에 기록
            try {
                $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
                if (Test-Path $errorLogPath) {
                    . $errorLogPath
                    sendErrorLog -Config $Config `
                        -Message "[DbMonitor] MdbStatsUpdate API failed - last_check_dt not updated" `
                        -Data @{
                        api            = "MdbStatsUpdate"
                        dbCount        = $statsList.Count
                        RstVal         = "$($response.RstVal)"
                        RstMsg         = "$($response.RstMsg)"
                        payloadPreview = if ($jsonPayload.Length -gt 1000) { $jsonPayload.Substring(0, 1000) } else { $jsonPayload }
                        fullResponse   = $response | ConvertTo-Json -Depth 5 -Compress -ErrorAction SilentlyContinue
                    } `
                        -Severity "error" `
                        -ErrorType "MdbStatsUpdateFailed"
                }
            }
            catch {
                Write-GiipLog "WARN" "[DbMonitor] Failed to log error: $_"
            }

            # [DEBUG] 로컬 파일 로깅 (DB 로깅 실패 대비)
            try {
                $logDir = Join-Path $PSScriptRoot "..\..\logs"
                if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
                $debugFile = Join-Path $logDir "dbmonitor_debug.json"
                
                $debugInfo = @{
                    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    RstVal    = "$($response.RstVal)"
                    RstMsg    = "$($response.RstMsg)"
                    Payload   = $jsonPayload
                    FullRes   = $response
                }
                $debugInfo | ConvertTo-Json -Depth 5 | Out-File $debugFile -Encoding UTF8 -Force
                Write-GiipLog "INFO" "[DbMonitor] Debug data saved to $debugFile"
            }
            catch {
                Write-GiipLog "WARN" "[DbMonitor] Failed to save local debug file: $_"
            }
        }
    }
    catch {
        Write-GiipLog "ERROR" "[DbMonitor] ❌ Exception during MdbStatsUpdate: $_"
        Write-GiipLog "ERROR" "[DbMonitor] Stack Trace: $($_.ScriptStackTrace)"
        
        # 예외 발생 시에도 에러로그 기록
        try {
            $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
            if (Test-Path $errorLogPath) {
                . $errorLogPath
                sendErrorLog -Config $Config `
                    -Message "[DbMonitor] Exception during MdbStatsUpdate - last_check_dt not updated" `
                    -Data @{
                    api        = "MdbStatsUpdate"
                    dbCount    = $statsList.Count
                    exception  = $_.Exception.Message
                    stackTrace = $_.ScriptStackTrace
                } `
                    -Severity "error" `
                    -Error Type "MdbStatsUpdateException"
            }
        }
        catch {
            Write-GiipLog "WARN" "[DbMonitor] Failed to log exception: $_"
        }
    }
}
else {
    Write-GiipLog "WARN" "[DbMonitor] No metrics collected - last_check_dt will NOT be updated"
    
    # 메트릭 수집 실패도 에러로그에 기록
    try {
        $errorLogPath = Join-Path $LibDir "ErrorLog.ps1"
        if (Test-Path $errorLogPath) {
            . $errorLogPath
            sendErrorLog -Config $Config `
                -Message "[DbMonitor] No DB metrics collected - unable to update last_check_dt" `
                -Data @{
                dbListCount = if ($dbList) { $dbList.Count } else { 0 }
                note        = "Check DB connection settings or permissions"
            } `
                -Severity "warn" `
                -ErrorType "NoMetricsCollected"
        }
    }
    catch {
        Write-GiipLog "WARN" "[DbMonitor] Failed to log warning: $_"
    }
}

exit 0
