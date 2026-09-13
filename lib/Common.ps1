# ============================================================================
# giipAgent Common Library (PowerShell)
# Version: 1.09
# Purpose: Shared utilities, Configuration, and API communication
# ============================================================================

$ErrorActionPreference = "Stop"

# Function: Log to local file and console
# giip #2338: previously this only wrote to the console (Write-Host), so when
# giipAgent3.ps1 hung (2026-09-09~11 incident) there was no on-disk trail to
# tell which Step it was stuck in -- giipLogs\giipAgentWin_*.log files were
# all stale (last write 2026-05-16). Now every call also best-effort appends
# to giipLogs\giipAgentWin_YYYYMMDD.log (sibling of the repo, same layout
# lib/LogCleanup.ps1 already expects). Signature is unchanged.
function Write-GiipLog {
    param(
        [string]$Level,
        [string]$Message
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] [$Level] $Message"
    Write-Host $LogLine

    try {
        $base = if ($Global:BaseDir) { $Global:BaseDir } else { $PSScriptRoot }
        $logDir = Join-Path $base "..\giipLogs"
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        }
        $logFile = Join-Path $logDir ("giipAgentWin_{0}.log" -f (Get-Date -Format "yyyyMMdd"))
        Add-Content -Path $logFile -Value $LogLine -Encoding UTF8 -ErrorAction Stop
    } catch {
        # File logging is best-effort only. Never let a logging failure
        # (e.g. locked file, missing permissions) break the caller -- the
        # console line above has already surfaced the message.
    }
}

# giip #1637 / giip #2390: 결정론적 agentKey 해석.
# 원래 lib/LogCollector.ps1 안에 있었으나(giip #1637), giip #2390에서
# giipAgent3.ps1도 동일한 agentKey(같은 Box = 같은 tSchedulerAgent 행)를 써야
# 스케줄러 실행 시작/종료 이력이 부트스트랩된 agent 행에 제대로 연결되므로
# 여기 Common.ps1(giipAgent3.ps1/LogCollector.ps1 둘 다 로드)로 옮겨 공유한다.
# 우선순위: logcollector_agentkey(cfg 명시값) > 캐시파일 > (hostname + HKLM
# MachineGuid 해시) 생성 후 캐시. 캐시 파일은 repo 밖(호출자가 넘기는 CacheFile,
# 보통 InstallDir=레포 상위 폴더)에 둬서 git-auto-sync.ps1의 체크아웃 갱신에
# 영향받지 않는다.
function Resolve-AgentKey {
    param($Config, [string]$CacheFile)
    if ($Config -and $Config['logcollector_agentkey']) { return $Config['logcollector_agentkey'] }
    if (Test-Path $CacheFile) {
        try {
            $cached = (Get-Content -Path $CacheFile -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
            if ($cached) { return $cached }
        } catch {}
    }
    $hn = $env:COMPUTERNAME
    if (-not $hn) { $hn = "unknown-host" }
    $guidPart = $null
    try {
        $mg = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($mg) {
            $clean = $mg -replace '-', ''
            $guidPart = $clean.Substring(0, [Math]::Min(12, $clean.Length))
        }
    } catch {
        Write-GiipLog "WARN" "Resolve-AgentKey: MachineGuid registry read failed ($($_.Exception.Message)) - falling back to a random persisted key."
    }
    if ($guidPart) {
        $key = "$hn-$guidPart"
    } else {
        $key = "$hn-" + ([guid]::NewGuid().ToString('N').Substring(0, 12))
    }
    try {
        $dir = Split-Path -Path $CacheFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $CacheFile -Value $key -Encoding UTF8 -NoNewline
    } catch {
        Write-GiipLog "WARN" "Resolve-AgentKey: failed to cache agentKey to $CacheFile"
    }
    return $key
}

# giip #2390: giipApiSk2/giipApiSk3 위치기반 디스패처(giipfaw/giipApiSk2/run.ps1)용
# 리터럴 빌더.
#
# 실측으로 발견한 함정(pApiSchedulerAgentRunStartBySK 최초 라이브 테스트에서
# "Error converting data type nvarchar to int" 오류로 발견): CommandText 토큰을
# jsonData 프로퍼티명 치환 방식(예: "SchedulerAgentUpsert agentKey displayName")
# 으로 채우면, jsonData가 존재하고 SP 이름에 Get/List가 없고 kvsput도 아닌 이상
# dispatcher가 "ISN 161" 로직으로 원본 jsonData 전체를 우리가 지정한 파라미터
# 뒤에 하나 더(!) 위치기반으로 자동 추가해버린다. 파라미터가 몇 개 안 되고
# 끝쪽이 INT/BIT인 SP(pApiSchedulerAgentRunStartBySK의 @totalIssueCount 등)에서는
# 이 여분의 파라미터가 그대로 타입 변환 에러로 이어진다. giip #1637 최초
# Bootstrap 구현(agentKey/displayName 2개만 채움)도 같은 문제를 안고 있었다 -
# @hostIdentifier 자리에 매 실행마다 원본 요청 JSON 전체가 조용히 들어가고
# 있었다(에러가 안 나는 타입이라 눈치채기 어려웠을 뿐).
#
# 해결: jsonData 프로퍼티 치환을 아예 쓰지 않는다. CommandText 자체에 이미 SQL
# 리터럴로 감싼 값을 직접 박아 넣고, Invoke-GiipApiV2 호출 시 JsonData에는 빈
# 문자열("")을 넘긴다 - dispatcher의 "if ($jsonData -and ...)" 게이트가 빈
# 문자열을 falsy로 판정해 치환/자동추가 로직 전체를 건너뛴다.
#
# 주의: 이 디스패처의 토크나이저(정규식 '[^']*')는 따옴표로 감싼 토큰 안의
# 이스케이프된 홑따옴표를 지원하지 않는다(내부 첫 홑따옴표에서 토큰이 끊겨버림)
# - 그래서 값에 포함된 홑따옴표는 이스케이프하지 않고 통째로 제거한다(상태값/
# 식별자/짧은 설명 문자열만 다루므로 손실 허용 가능한 트레이드오프). 숫자값도
# 그냥 문자열로 감싸 넘기면 된다 - dispatcher가 순수 숫자 토큰은 따옴표 없는
# 리터럴로 재조립하고, 설령 그대로 남아도 T-SQL이 INT/BIT 파라미터로 암시적
# 변환한다.
function ConvertTo-DispatcherSqlLiteral {
    param($Value)
    if ($null -eq $Value) { $Value = "" }
    $s = [string]$Value
    $clean = $s.Replace("'", "")
    $clean = $clean -replace "\r\n|\r|\n", ' '
    return "'$clean'"
}

# Function: Load giipAgent Configuration
function Get-GiipConfig {
    param([string]$SearchBase)
    
    $base = if ($SearchBase) { $SearchBase } elseif ($Global:BaseDir) { $Global:BaseDir } else { $PSScriptRoot }
    $config = @{}
    $configPath = $null
    
    # Priority 1: Parent directory
    $parent = Split-Path -Path $base -Parent
    if ($parent -and (Test-Path (Join-Path $parent "giipAgent.cfg"))) {
        $candidate = Join-Path $parent "giipAgent.cfg"
        $head = Get-Content $candidate -TotalCount 10 -ErrorAction SilentlyContinue
        if ($head -notmatch "SAMPLE") { $configPath = $candidate }
    }
    
    # Priority 2: User Profile
    if (-not $configPath) {
        $userPath = Join-Path $env:USERPROFILE "giipAgent.cfg"
        if (Test-Path $userPath) {
            $head = Get-Content $userPath -TotalCount 10 -ErrorAction SilentlyContinue
            if ($head -notmatch "SAMPLE") { $configPath = $userPath }
        }
    }
    
    # Priority 3: Local Repository (Last Resort)
    if (-not $configPath) {
        $localPath = Join-Path $base "giipAgent.cfg"
        if (Test-Path $localPath) {
            $configPath = $localPath
        }
    }
    
    if ($configPath) {
        $raw = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $raw -split "`r?`n" | ForEach-Object {
                if ($_ -match '^\s*([^=:#\s\[]+)\s*[:=]\s*(.*)$') {
                    $k = $Matches[1].Trim().ToLower()
                    $v = $Matches[2].Trim()
                    # Strip surrounding quotes if present
                    if ($v -match '^["''](.*)["'']$') { $v = $Matches[1] }
                    $config[$k] = $v
                }
            }
        }
    }
    
    return $config
}

# Function: Import MySQL Connector DLL
function Import-MySqlDll {
    param([string]$LibDir)
    $DllPath = Join-Path $LibDir "MySql.Data.dll"
    if (Test-Path $DllPath) {
        Add-Type -Path $DllPath
        return $true
    }
    return $false
}

# Function: Invoke GIIP API V2 (Main Communication)
function Invoke-GiipApiV2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$CommandText,
        # giip #2390: [Parameter(Mandatory)]가 string 타입에 붙으면 PowerShell이
        # 자동으로 "빈 문자열 금지"까지 강제한다(실측: "Cannot bind argument to
        # parameter 'JsonData' because it is an empty string."). 그런데
        # ConvertTo-DispatcherSqlLiteral 방식(CommandText에 값을 직접 SQL
        # 리터럴로 박아 넣는 새 호출부, lib/SchedulerAgentRun.ps1 등)은 의도적으로
        # 빈 문자열을 보내 giipApiSk2 dispatcher의 jsonData 자동추가(ISN 161)
        # 로직을 꺼야 한다 - [AllowEmptyString()]으로 그 경우만 허용한다(기존
        # 호출부는 전부 실제 값을 넘기므로 동작 변화 없음).
        [Parameter(Mandatory)][AllowEmptyString()][string]$JsonData,
        # giip-issue #922: most callers want a single object and rely on the
        # $response.data[0] unwrap below. List endpoints (e.g.
        # "ManagedDatabaseListForAgent") return multiple rows in $response.data
        # and were silently truncated to just the first one. Pass -RawList to
        # get the full, un-unwrapped $response back instead (existing callers
        # are unaffected -- default behavior is unchanged).
        [switch]$RawList
    )
    $effectiveToken = if ($Global:GiipSessionAK) { $Global:GiipSessionAK } else { $Config.sk }
    
    $Uri = $Config.apiaddrv2
    if (-not $Uri) {
        Write-GiipLog "ERROR" "API Address (apiaddrv2) missing in configuration."
        return $null
    }

    $Body = @{ token = $effectiveToken; text = $CommandText; jsondata = $JsonData }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $bodyString = @()
        foreach ($key in $Body.Keys) {
            $bodyString += "$([System.Uri]::EscapeDataString($key))=$([System.Uri]::EscapeDataString($Body[$key]))"
        }
        $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyString -join '&'))
        $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded; charset=utf-8' }
        
        $webResponse = Invoke-WebRequest -Uri $Uri -Method Post -Headers $headers -Body $utf8Bytes -TimeoutSec 30 -UseBasicParsing
        $responseJson = $webResponse.Content
        $response = $null
        
        try {
            $response = $responseJson | ConvertFrom-Json
        } catch {
            Write-GiipLog "WARN" "API Response JSON parsing failed. Attempting dirty parse."
            # Fallback: Try to extract RstVal and RstMsg using regex if JSON is malformed
            $rstVal = if ($responseJson -match '"RstVal"\s*:\s*(\d+)') { $Matches[1] } else { "500" }
            $rstMsg = if ($responseJson -match '"RstMsg"\s*:\s*"([^"]+)"') { $Matches[1] } else { "Unknown JSON Error" }
            $response = @{ RstVal = $rstVal; RstMsg = $rstMsg; isDirty = $true }
            
            # If it's a 200, we can treat it as success even if JSON was ugly
            if ($rstVal -eq "200") {
                Write-GiipLog "INFO" "Dirty parse succeeded: Operation was successful (200)."
            } else {
                Write-GiipLog "DEBUG" "Dirty parse result: $rstVal - $rstMsg"
            }
        }
        
        if ($response.ak) { $Global:GiipSessionAK = $response.ak }
        
        # Debug: Log non-success responses
        if ($response.RstVal -and $response.RstVal -ne "200") {
            $rawJson = $webResponse.Content
            Write-GiipLog "DEBUG" "API Non-Success Response ($($response.RstVal)): $rawJson"
        }
        
        if ($RawList) { return $response }
        if ($response.data -and $response.data.Count -gt 0) { return $response.data[0] }
        return $response
    } catch {
        Write-GiipLog "DEBUG" "API Call Failed: $_"
        return $null
    }
}
