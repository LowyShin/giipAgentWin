# diag_userlist.ps1
# Purpose: Diagnose the User List collection pipeline for mdb_id 70352

$ErrorActionPreference = "Stop"
$AgentWinDir = "c:\Users\lowys\Downloads\projects\giipprj\giipAgentWin"
$LibDir = Join-Path $AgentWinDir "lib"
$Global:BaseDir = $AgentWinDir

# 1. Load Libraries
Write-Host "--- [Step 1] Loading Libraries from $LibDir ---"
if (Test-Path (Join-Path $LibDir "Common.ps1")) {
    . (Join-Path $LibDir "Common.ps1")
    Write-Host "✅ Common.ps1 loaded."
}
else {
    Write-Error "❌ Common.ps1 not found in $LibDir"
    exit 1
}

# 2. Get Config
Write-Host "--- [Step 2] Getting Config ---"
try {
    $Config = Get-GiipConfig
    Write-Host "✅ Config loaded."
    Write-Host "   LSSN: $($Config.lssn)"
    Write-Host "   API : $($Config.apiaddrv2)"
}
catch {
    Write-Error "❌ Failed to load config: $_"
    exit 1
}

# 3. Check DB List Flag
Write-Host "--- [Step 3] Checking DB List from API ---"
try {
    $reqData = @{ lssn = $Config.lssn }
    $reqJson = $reqData | ConvertTo-Json -Compress
    $response = Invoke-GiipApiV2 -Config $Config -CommandText "ManagedDatabaseListForAgent lssn" -JsonData $reqJson

    $dbList = $null
    if ($response.data) { $dbList = $response.data }
    elseif ($response -is [Array]) { $dbList = $response }
    elseif ($response.mdb_id) { $dbList = @($response) }

    if ($dbList) {
        Write-Host "Found $($dbList.Count) databases."
        $target = $dbList | Where-Object { $_.mdb_id -eq 70352 }
        if ($target) {
            Write-Host "✅ Target DB Found: mdb_id=70352" -ForegroundColor Green
            Write-Host "   Name: $($target.db_name)"
            Write-Host "   Host: $($target.db_host)"
            Write-Host "   Type: $($target.db_type)"
            Write-Host "   Req Flag: $($target.user_list_req)" -ForegroundColor (if ($target.user_list_req -eq 1 -or $target.user_list_req -eq $true) { "Green" } else { "Yellow" })
        }
        else {
            Write-Host "❌ Target DB NOT found in the list for LSSN $($Config.lssn)" -ForegroundColor Red
            Write-Host "   Try to find by name 'stagedb97'..."
            $byName = $dbList | Where-Object { $_.db_name -like "*stagedb97*" }
            if ($byName) {
                Write-Host "   Found by name match: mdb_id=$($byName.mdb_id), gateway_lssn=$($byName.gateway_lssn)"
            }
        }
    }
    else {
        Write-Host "❌ Failed to retrieve DB list or response empty." -ForegroundColor Red
    }
}
catch {
    Write-Error "❌ API Call failed: $_"
}

# 4. Check for History
Write-Host "--- [Step 4] Checking for existing User List data in Central DB ---"
try {
    $histReq = @{ mdb_id = 70352 } | ConvertTo-Json -Compress
    $histRes = Invoke-GiipApiV2 -Config $Config -CommandText "Net3dUserListGet mdb_id" -JsonData $histReq
    if ($histRes.data -and $histRes.data[0].history) {
        Write-Host "✅ History found (Count: $($histRes.data[0].history.Count) or length: $($histRes.data[0].history.Length))"
    }
    else {
        Write-Host "No history found for ID 70352."
    }
}
catch {
    Write-Host "Failed to check history: $_"
}
