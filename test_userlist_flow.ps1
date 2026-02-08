# test_userlist_flow.ps1
# Purpose: Manually execute the collection logic for mdb_id 70352 and captue trace

$ErrorActionPreference = "Stop"

# Use absolute paths for current environment
$AgentRoot = "C:\Users\lowys\Downloads\projects\giipprj\giipAgentWin"
$LibDir = Join-Path $AgentRoot "lib"

# 1. Load Standard Libraries
Write-Host "--- [1] Loading Libraries ---"
. (Join-Path $LibDir "Common.ps1")
# Mock GiipLog to console for visibility
function Write-GiipLog($level, $msg) { Write-Host "[$level] $msg" }

# 2. Get Config (Simulate Get-GiipConfig since we can't find it easily)
# We'll try to find it again or use hardcoded if known (Not safe, let's try finding)
Write-Host "--- [2] Locating giipAgent.cfg ---"
$Config = $null
$candidates = @(
    "C:\Users\lowys\Downloads\projects\giipprj\giipAgent.cfg",
    "C:\Users\lowys\giipAgent.cfg"
)
foreach ($p in $candidates) {
    if (Test-Path $p) {
        $Config = Parse-ConfigFile -Path $p
        Write-Host "✅ Found config at $p"
        break
    }
}

if (-not $Config) {
    Write-Host "❌ Active config NOT found. Cannot proceed with API calls."
    exit 1
}

# 3. Simulate Request Check
Write-Host "--- [3] Checking for mdb_id 70352 in Request List ---"
$reqData = @{ lssn = $Config.lssn }
$reqJson = $reqData | ConvertTo-Json -Compress
$response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson

$dbList = $null
if ($response.data) { $dbList = $response.data }
elseif ($response -is [Array]) { $dbList = $response }
elseif ($response.mdb_id) { $dbList = @($response) }

$targetDb = $dbList | Where-Object { $_.mdb_id -eq 70352 }
if (-not $targetDb) {
    Write-Host "❌ Database 70352 not returned by API for LSSN $($Config.lssn)."
    exit 1
}

Write-Host "✅ DB 70352 Found. user_list_req = $($targetDb.user_list_req)"

# 4. Simulate Collection (MSSQL)
Write-Host "--- [4] Simulating MSSQL Collection ---"
$dbHost = $targetDb.db_host
$port = $targetDb.db_port
$user = $targetDb.db_user
$pass = $targetDb.db_password # Decrypted by pApiManagedDatabaseListForAgentbySk

Write-Host "Connecting to $dbHost,$port as $user..."

try {
    $connStrBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $connStrBuilder["Data Source"] = "$dbHost,$port"
    $connStrBuilder["Initial Catalog"] = "master"
    $connStrBuilder["User ID"] = $user
    $connStrBuilder["Password"] = $pass
    $connStrBuilder["TrustServerCertificate"] = $true
    $connStrBuilder["Connection Timeout"] = 10
    
    $userConn = New-Object System.Data.SqlClient.SqlConnection($connStrBuilder.ConnectionString)
    $userConn.Open()
    Write-Host "✅ DB Connection SUCCESS."
    
    $userCmd = $userConn.CreateCommand()
    $userCmd.CommandText = "SELECT name, type_desc, is_disabled FROM sys.server_principals WHERE type IN ('S','U','G') AND name NOT LIKE '##%'"
    $userReader = $userCmd.ExecuteReader()
    $userList = @()
    while ($userReader.Read()) {
        $userList += @{
            name   = $userReader["name"]
            type   = $userReader["type_desc"]
            status = if ($userReader["is_disabled"] -eq 1) { "DISABLED" } else { "ENABLED" }
        }
    }
    $userReader.Close()
    $userConn.Close()
    Write-Host "✅ Collected $($userList.Count) users."

    if ($userList.Count -gt 0) {
        # 5. Simulate Upload
        Write-Host "--- [5] Simulating Upload ---"
        $ulPayload = @{
            mdb_id    = 70352
            lssn      = $Config.lssn
            user_list = $userList
        } | ConvertTo-Json -Depth 5 -Compress
        
        $uploadRes = Invoke-GiipApiV2 -Config $Config -CommandText "Net3dUserListPut jsondata" -JsonData $ulPayload
        if ($uploadRes -and $uploadRes.RstVal -eq 200) {
            Write-Host "✅ UPLOAD SUCCESS." -ForegroundColor Green
        }
        else {
            Write-Host "❌ UPLOAD FAILED. RstVal=$($uploadRes.RstVal), RstMsg=$($uploadRes.RstMsg)" -ForegroundColor Red
        }
    }
}
catch {
    Write-Host "❌ Collection Error: $($_.Exception.Message)" -ForegroundColor Red
}
