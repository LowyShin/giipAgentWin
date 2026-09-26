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

# ============================================================================
# giip #2556: 아래 두 함수(Get-SystemInfo / Update-ConfigLssn)는 이 파일에
# 원래 있었으나(1558e27, 2025-12-08 "refactor: Modularize Windows Agent to v2.0
# structure"), 2026-04-08 커밋 95a5560("feat: implement modular agent task
# execution framework with new library and script modules")이 lib/Common.ps1 을
# 전면 재작성하면서 **정의만 사라지고 호출부는 그대로 남았다**.
#
# 호출부: lib/Worker.ps1 L34(Get-SystemInfo), L121(Update-ConfigLssn).
# 그 결과 구 진입점 giipAgentWin.ps1 은 2026-04-08 이후 루프 첫 회차에서
# 반드시 CommandNotFoundException 으로 죽는 상태였다(giip #2556 실측 재현:
#   "The term 'Get-SystemInfo' is not recognized as the name of a cmdlet,
#    function, script file, or operable program.").
# Task Scheduler 가 그 진입점을 부르지 않게 된 뒤(b69abcd, 2025-12-11)라
# 아무도 이 결함을 만나지 않았을 뿐이다.
#
# 여기서 1558e27 의 원본 정의를 그대로 복원한다. 레포 전체에서 이 두 이름의
# 정의는 0건이었으므로(실측) 이름 충돌이 없고, 운영 경로(giipAgent3.ps1 Step
# 1~7 + Step 2.5)는 이 함수들을 호출하지 않으므로 동작 변화가 없다.
# 상세 사양: docs/SPEC_UNCALLED_PATHS.md
# ============================================================================

# Function: 호스트명/OS 이름 조회 (lib/Worker.ps1 Get-QueueItem 이 사용)
function Get-SystemInfo {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return @{
            Hostname = $os.CSName
            OSName   = $os.Caption
        }
    }
    catch {
        return @{
            Hostname = $env:COMPUTERNAME
            OSName   = "Windows (Unknown)"
        }
    }
}

# Function: giipAgent.cfg 의 lssn 값을 갱신 (lib/Worker.ps1 Invoke-AgentTask 가
#           서버에서 숫자 LSSN 을 돌려받았을 때 사용)
function Update-ConfigLssn {
    param([string]$NewLssn)
    # Re-find the config file to update it
    $candidates = @()
    if ($Global:BaseDir) { $candidates += (Join-Path $Global:BaseDir "../giipAgent.cfg") }
    $candidates += (Join-Path $env:USERPROFILE "giipAgent.cfg")

    $targetFile = $null
    foreach ($path in $candidates) {
        if (Test-Path $path) { $targetFile = $path; break }
    }

    if ($targetFile) {
        $content = Get-Content $targetFile
        $newContent = $content -replace 'lssn\s*=\s*"\d+"', "lssn = `"$NewLssn`"" -replace "lssn\s*=\s*'\d+'", "lssn = `"$NewLssn`""
        Set-Content -Path $targetFile -Value $newContent -Encoding UTF8
        Write-GiipLog "INFO" "Updated LSSN in config file to $NewLssn"
    }
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

        # giip #3079 (csn 70418 실측): 이 두 로그가 DEBUG 레벨이었던 것 자체가 근본 원인
        # 중 하나였다 - HTTP 200으로 도착한 400/500급 애플리케이션 오류(RstVal != 200)도,
        # 진짜 네트워크/예외 실패도 전부 DEBUG로만 남아서, 호출부가 반환값을 제대로
        # 확인해도 사람이 로그를 볼 때는 "오류가 안 보이는" 상태였다. WARN/ERROR로 올린다.
        if ($response.RstVal -and $response.RstVal -ne "200") {
            $rawJson = $webResponse.Content
            Write-GiipLog "WARN" "API Non-Success Response ($($response.RstVal)): $rawJson"
        }

        if ($RawList) { return $response }
        if ($response.data -and $response.data.Count -gt 0) { return $response.data[0] }
        return $response
    } catch {
        Write-GiipLog "ERROR" "API Call Failed: $_"
        return $null
    }
}

# giip #3079: API 호출은 HTTP 200으로 도착해도 애플리케이션 레벨에서 실패(RstVal != 200)
# 할 수 있고, Invoke-GiipApiV2는 그 경우에도 예외를 던지지 않고 응답 객체를 그대로
# 반환한다(네트워크 예외/URI 누락일 때만 $null). 호출부가 반환값을 Out-Null로 버리거나
# 확인 없이 "성공" 로그를 남기면, 400/500 응답이 로그에는 성공으로 남는다(csn 70418
# 실측 - CollectDockerMetrics.ps1 giip 3043에서 발견). 실패로 판정된 호출부는 이 함수로
# (a) ERROR 레벨 로그를 남기고 (b) 이미 이 레포에 있었지만 어디서도 호출되지 않던
# 기존 giip 오류 보고 채널(lib/ErrorLog.ps1 sendErrorLog -> ErrorLogCreate SP)을
# 재사용해 서버에도 알린다. giipfaw agent-log-* 계열(스트림 등록/시퀀스 번호가 필요한
# 별도 파이프라인)은 새 통합 작업이 필요해 이번 범위에서 손대지 않았다 - 판단 근거는
# giip 3079 완료 코멘트 참고.
function Write-GiipApiFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Context,
        [object]$Response
    )
    $rstVal = if ($Response -and $Response.RstVal) { $Response.RstVal } else { "no-response" }
    $rstMsg = if ($Response -and $Response.RstMsg) { $Response.RstMsg } else { "null response (network/exception or missing config)" }
    $msg = "$Context failed (RstVal=$rstVal, RstMsg=$rstMsg)"
    Write-GiipLog "ERROR" $msg

    try {
        if (-not (Get-Command sendErrorLog -ErrorAction SilentlyContinue)) {
            $__errorLogPath = Join-Path $PSScriptRoot "ErrorLog.ps1"
            if (Test-Path $__errorLogPath) { . $__errorLogPath }
        }
        if (Get-Command sendErrorLog -ErrorAction SilentlyContinue) {
            sendErrorLog -Config $Config -Message $msg -Severity 'error' | Out-Null
        }
    } catch {
        Write-GiipLog "DEBUG" "[Write-GiipApiFailure] sendErrorLog reuse failed (non-fatal): $_"
    }
}
