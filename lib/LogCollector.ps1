# ============================================================================
# LogCollector.ps1 - giip #1637 (giip #1614 4단계: Windows FDE Box 로그 수집기)
#
# 목적:
#   giipAgentWin이 도는 Windows Box의 로그 파일을 tail하여 giipfaw의
#   agent-log-register / agent-log-ingest Function으로 전송한다. 계약 정본은
#   giipdb repo의 docs/30_Specs/AGENT_LOG_COLLECTOR_SPECIFICATION.md (giip #1635,
#   3단계 산출물)이며, Linux 쪽 giipAgentLinux/lib/log_collector.sh(giip #1635,
#   PR #30, 이미 merged)와 동일 계약을 공유한다.
#
#   스코프 판단(giip #1637 코멘트 참고): giipAgentWin에는 gissue 처리 스케줄러
#   (run-gissue-claude.ps1, 별도 repo인 giip-fde-agent 소속)가 없다. giipAgent3.ps1
#   자체도 현재 파일 로그를 남기지 않는다(Write-GiipLog는 Write-Host뿐) - 실제로
#   채워지는 giipAgentWin 자신의 운영 로그는 git-auto-sync.ps1이 쓰는
#   "<repo>\logs\git_auto_sync_*.log" 뿐이다(custsvrs/lowy-dp01/giipAgentWin/logs/
#   실측 확인). 따라서 1차 수집 대상을 "<repo>\logs\*.log"로 잡는다 - 이 폴더에
#   앞으로 다른 스크립트가 로그를 남기기 시작해도 자동으로 커버된다.
#   gissue_csn*.log는 giip-fde-agent가 설치된 Box에서만 존재하는 별개 제품의
#   로그이므로 여기 하드코딩하지 않는다 - logcollector_globs 설정으로 그런 Box에서
#   나중에 자유롭게 추가하면 된다(코드 변경 불필요).
#
#   ⚠️ 핵심 원칙(giipAgentLinux의 log_collector.sh와 동일): giipAgent3.ps1의 핵심
#   실행 흐름은 절대 건드리지 않는다. 이 스크립트는 완전히 독립된 신규 파일이며,
#   기존 "GIIP Agent Task (v3)" 스케줄러 태스크와 무관한 별도 opt-in 태스크로만
#   등록된다(-Register 스위치, TaskSchdReg.ps1은 건드리지 않음). logcollector_enabled가
#   truthy가 아니면 아무 것도 하지 않고 조용히 종료한다 - 기존 설치를 깨지 않는다.
#
# 사용법:
#   powershell -File lib\LogCollector.ps1            # 정상 실행(1회 tick, 내부에서
#                                                       #  최대 logcollector_run_duration_sec초 루프)
#   powershell -File lib\LogCollector.ps1 -Once       # 배치 루프 없이 단발 1회 수집/전송
#   powershell -File lib\LogCollector.ps1 -Register   # "GIIP Log Collector Task"를
#                                                       #  1분 간격 Scheduled Task로 등록하고 종료
#
# 설계상 giipAgentLinux(v1)와 다른 점 (giip #1637 스코프 판단, 의도적):
#   - fileFingerprint: Linux는 inode(`stat -c '%i'`)를 쓰지만 Windows(NTFS)는
#     inode가 없다. 대신 `fsutil file queryfileid`가 반환하는 NTFS File ID(파일이
#     삭제 후 재생성되면 바뀌고, 단순 rename에는 살아남는 - inode와 동일한 회전
#     감지 의미론)를 사용한다(관리자 권한 불필요, 이 Box에서 실측 확인:
#     `fsutil file queryfileid <path>` -> "File ID is 0x...."). fsutil 실패 시
#     CreationTimeUtc(ticks)+파일크기 조합으로 폴백하고 WARN 로그를 남긴다.
#   - compression: Linux v1은 구현 단순성 때문에 매 전송을 compression:"none"으로
#     보낸다. 이 Windows 구현은 스펙 §5가 정의하는 gzip 경로(compression:"gzip",
#     linesGzB64)를 실제로 사용한다 - 둘 다 스펙상 유효한 선택지이며, 이 쪽은
#     대역폭 절약을 우선한 결정이다.
#   - agentKey: Linux와 대칭으로 결정론적 자체생성(HKLM MachineGuid 해시 기반)을
#     쓴다. 서버측 발급 SP는 만들지 않는다 - giipdb/docs/30_Specs/
#     AGENT_LOG_COLLECTOR_SPECIFICATION.md §14 참고(giip #1637에서 신설).
#   - tSchedulerAgent 부트스트랩: giip #1637 조사 중 발견한 갭 - agent-log-register는
#     tSchedulerAgent에 (csn, agentKey) 행이 이미 있어야 하는데(없으면 404),
#     monorepo 어디에도 pApiSchedulerAgentUpsertBySK를 호출하는 코드가 없었다
#     (이미 merged된 giipAgentLinux 쪽도 마찬가지 - 별도 후속 이슈 필요). 이 파일은
#     매 실행마다 giipApiSk2 범용 SP 디스패처(기존 Invoke-GiipApiV2, apiaddrv2)를
#     통해 pApiSchedulerAgentUpsertBySK를 먼저 호출해 이 갭을 메운다(아래
#     Invoke-SchedulerAgentBootstrap 참고). 이 CommandText 문자열은 이 저장소의
#     기존 다중 호출부(KVSFactorLast/CQEQueueGet 등)와 동일한 패턴으로 작성했으나,
#     실제 giipdb 대상 라이브 스모크 테스트는 이번 스코프에서 수행하지 못했다.
#
# 필요 설정 (giipAgent.cfg / giipAgent.cfg.example 참고):
#   sk, apiaddrv2                 - 기존 필수값 재사용.
#   logcollector_enabled          - 1/true/yes 가 아니면 조용히 skip(기본: 비활성화)
#   logcollector_globs            - 콤마 구분 경로 패턴 목록. 기본값 "<repo>\logs\*.log"
#   logcollector_streamtype_map   - (선택) "pattern:streamType,pattern:streamType,..."
#   logcollector_agentkey         - (선택) agentKey 강제 지정. 비어있으면 자동생성+캐시.
#   logcollector_batch_interval_sec / logcollector_batch_max_bytes
#   logcollector_run_duration_sec / logcollector_queue_max_batches / logcollector_queue_max_mb
#   agentapibase                  - (선택) agent-* Function base URL(기본: apiaddrv2 마지막 세그먼트 제거)
#   agentfunctionkey              - (선택) Azure Functions key(authLevel=function 대응)
# ============================================================================

[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Register
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------------
# Path resolution
# ----------------------------------------------------------------------------
$ScriptDir  = Split-Path -Path $MyInvocation.MyCommand.Path -Parent   # .../giipAgentWin/lib
$RepoRoot   = Split-Path -Path $ScriptDir -Parent                     # .../giipAgentWin
$InstallDir = Split-Path -Path $RepoRoot -Parent                      # cfg/agentKey 캐시가 사는 부모 디렉토리
$Global:BaseDir = $RepoRoot

. (Join-Path $ScriptDir "Common.ps1")   # Get-GiipConfig / Write-GiipLog / Invoke-GiipApiV2

$StateDir          = Join-Path $RepoRoot "logs\.collector_state"
$QueueDir           = Join-Path $StateDir "queue"
$BackoffStateFile   = Join-Path $QueueDir ".backoff.json"
$AgentKeyCacheFile  = Join-Path $InstallDir ".giip_logcollector_agentkey"
$LockFile           = Join-Path $StateDir ".logcollector.lock"

# 수집기 자신의 진단 로그는 기본 수집 glob("<repo>\logs\*.log")과 겹치지 않도록
# 하위 폴더에 둔다(자기참조 수집 루프 방지).
$DiagLogDir  = Join-Path $RepoRoot "logs\collector_diag"
$DiagLogFile = Join-Path $DiagLogDir ("giip-log-collector_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

function Write-CollectorLog {
    param([string]$Level, [string]$Message)
    Write-GiipLog $Level $Message
    try {
        if (-not (Test-Path $DiagLogDir)) { New-Item -ItemType Directory -Path $DiagLogDir -Force | Out-Null }
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
        Add-Content -Path $DiagLogFile -Value $line -Encoding UTF8
    } catch {}
}

# ============================================================================
# Small pure helpers (테스트 대상 - dot-source 해서 개별 호출 가능)
# ============================================================================

function Get-Iso8601Now {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

function ConvertTo-SanitizedKey {
    param([string]$Key)
    $k = $Key -replace '[\\/:*?"<>|]', '_'
    $k = $k -replace ' ', '_'
    return $k
}

# NTFS File ID(fsutil) 기반 fingerprint - inode의 Windows 대응. 파일이 삭제 후
# 재생성되면 값이 바뀌고, 단순 rename에는 살아남는다(회전 감지 의미론 동일).
function Get-FileFingerprint {
    param([string]$FilePath)
    try {
        $out = & fsutil file queryfileid "$FilePath" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $joined = ($out -join ' ')
            if ($joined -match '(0x[0-9A-Fa-f]+)') {
                return "fileid:$($Matches[1])"
            }
        }
    } catch {}
    try {
        $fi = Get-Item -Path $FilePath -ErrorAction Stop
        Write-CollectorLog "WARN" "Get-FileFingerprint: fsutil queryfileid failed for $FilePath, using ctime+size fallback."
        return "ctime:$($fi.CreationTimeUtc.Ticks)+$($fi.Length)"
    } catch {
        return $null
    }
}

function Get-RelativeStreamPath {
    param([string]$FilePath, [string]$RepoRoot)
    try {
        $full = (Resolve-Path -Path $FilePath -ErrorAction Stop).Path
    } catch { $full = $FilePath }
    try {
        $rootFull = (Resolve-Path -Path $RepoRoot -ErrorAction Stop).Path
    } catch { $rootFull = $RepoRoot }
    if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($rootFull.Length).TrimStart('\', '/')
        return ($rel -replace '\\', '/')
    }
    $noDrive = $full -replace '^[A-Za-z]:', ''
    return (($noDrive -replace '\\', '/').TrimStart('/'))
}

# streamType 결정: logcollector_streamtype_map(있으면, "pattern:type,pattern:type")
# -> 파일명 휴리스틱(logs\ 하위는 agent_operational, 그 외는 generic_log)
function Get-StreamType {
    param([string]$FilePath, [string]$Map)
    if ($Map) {
        foreach ($pair in ($Map -split ',')) {
            $idx = $pair.IndexOf(':')
            if ($idx -lt 1) { continue }
            $pat = $pair.Substring(0, $idx).Trim()
            $typ = $pair.Substring($idx + 1).Trim()
            if (-not $pat -or -not $typ) { continue }
            if ($FilePath -like $pat) { return $typ }
        }
    }
    if ($FilePath -like "*\logs\*.log") { return "agent_operational" }
    return "generic_log"
}

# 비밀 마스킹: sk=/password=/passwd=/pwd=/secret=/token=/api[_-]?key=, Authorization: 헤더
# (완벽한 DLP 아님 - giipAgentLinux/lib/log_collector.sh와 동일한 정책의 명백한 패턴만)
function Protect-SecretLine {
    param([string]$Line)
    $l = $Line
    $l = [regex]::Replace($l, '(?i)\b(sk=)[^ ,;&]+', '$1***MASKED***')
    $l = [regex]::Replace($l, '(?i)\b(password=|passwd=|pwd=)[^ ,;&]+', '$1***MASKED***')
    $l = [regex]::Replace($l, '(?i)\b(secret=)[^ ,;&]+', '$1***MASKED***')
    $l = [regex]::Replace($l, '(?i)\b(token=)[^ ,;&]+', '$1***MASKED***')
    $l = [regex]::Replace($l, '(?i)\b(api[_-]?key=)[^ ,;&]+', '$1***MASKED***')
    $l = [regex]::Replace($l, '(?i)(Authorization:\s*[A-Za-z]+\s+)[^ ,;]+', '$1***MASKED***')
    return $l
}

function ConvertTo-GzipBase64 {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
    $gz.Write($bytes, 0, $bytes.Length)
    $gz.Close()
    $ms.Position = 0
    $compressed = $ms.ToArray()
    $ms.Close()
    return [Convert]::ToBase64String($compressed)
}

function ConvertTo-GzipBytes {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
    $gz.Write($bytes, 0, $bytes.Length)
    $gz.Close()
    $result = $ms.ToArray()
    $ms.Close()
    return , $result
}

function ConvertFrom-GzipBytes {
    param([byte[]]$Bytes)
    $ms = New-Object System.IO.MemoryStream(, $Bytes)
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader($gz, [System.Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd()
    $sr.Close(); $gz.Close(); $ms.Close()
    return $text
}

# agentKey 해석: logcollector_agentkey(cfg) > 캐시파일 > (hostname + MachineGuid 해시) 생성 후 캐시
# 캐시 파일은 repo 밖(InstallDir)에 둬서 git-auto-sync.ps1의 체크아웃 갱신에 영향받지 않는다.
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
        Write-CollectorLog "WARN" "Resolve-AgentKey: MachineGuid registry read failed ($($_.Exception.Message)) - falling back to a random persisted key."
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
        Write-CollectorLog "WARN" "Resolve-AgentKey: failed to cache agentKey to $CacheFile"
    }
    return $key
}

function Get-AgentApiBase {
    param($Config)
    if ($Config -and $Config['agentapibase']) { return $Config['agentapibase'].TrimEnd('/') }
    $api = if ($Config) { $Config['apiaddrv2'] } else { $null }
    if (-not $api) { return $null }
    $idx = $api.LastIndexOf('/')
    if ($idx -lt 0) { return $api }
    return $api.Substring(0, $idx)
}

function Get-DiscoveredFiles {
    param([string]$Globs)
    $seen = @{}
    $results = @()
    if (-not $Globs) { return $results }
    foreach ($pat in ($Globs -split ',')) {
        $p = $pat.Trim()
        if (-not $p) { continue }
        $items = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue
        foreach ($m in $items) {
            if (-not $seen.ContainsKey($m.FullName)) {
                $seen[$m.FullName] = $true
                $results += $m.FullName
            }
        }
    }
    return $results
}

# ============================================================================
# 상태 파일(offset/rotationGen/fingerprint/lastSequence)
# ============================================================================
function Get-StreamStateFile {
    param([string]$StateDir, [string]$StreamKey)
    return (Join-Path $StateDir ((ConvertTo-SanitizedKey $StreamKey) + ".state.json"))
}

function Get-StreamState {
    param([string]$StateFile)
    if (-not (Test-Path $StateFile)) {
        return [PSCustomObject]@{ Offset = [long]0; RotationGen = 0; Fingerprint = $null; LastSequence = [long]0; IsNew = $true }
    }
    try {
        $s = Get-Content -Path $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return [PSCustomObject]@{
            Offset       = [long]$s.offset
            RotationGen  = [int]$s.rotationGen
            Fingerprint  = $s.fingerprint
            LastSequence = [long]$s.lastSequence
            IsNew        = $false
        }
    } catch {
        return [PSCustomObject]@{ Offset = [long]0; RotationGen = 0; Fingerprint = $null; LastSequence = [long]0; IsNew = $true }
    }
}

function Save-StreamState {
    param([string]$StateFile, [long]$Offset, [int]$RotationGen, [string]$Fingerprint, [long]$LastSequence)
    $dir = Split-Path -Path $StateFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [ordered]@{
        offset       = $Offset
        rotationGen  = $RotationGen
        fingerprint  = $Fingerprint
        lastSequence = $LastSequence
    } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

# ============================================================================
# 파일에서 새로 추가된 "완결된 라인"만 읽기(마지막 미종료 라인은 다음 패스로 미룸)
# ============================================================================
function Read-NewCompleteLines {
    param([string]$FilePath, [long]$Offset, [int]$MaxReadBytes = 4194304)

    $result = [PSCustomObject]@{ Lines = @(); NewOffset = $Offset }
    $item = Get-Item -Path $FilePath -ErrorAction SilentlyContinue
    if (-not $item) { return $result }
    $size = $item.Length
    $remain = $size - $Offset
    if ($remain -le 0) { return $result }
    if ($remain -gt $MaxReadBytes) { $remain = $MaxReadBytes }

    $buf = New-Object byte[] $remain
    $readCount = 0
    $fs = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $readCount = $fs.Read($buf, 0, $remain)
    } finally {
        $fs.Close()
    }
    if ($readCount -le 0) { return $result }
    if ($readCount -lt $buf.Length) { $buf = $buf[0..($readCount - 1)] }

    $lastNl = -1
    for ($i = $buf.Length - 1; $i -ge 0; $i--) {
        if ($buf[$i] -eq 10) { $lastNl = $i; break }
    }
    if ($lastNl -lt 0) {
        # 아직 개행으로 끝나는 완결 라인이 없음 - 이번 패스는 건너뜀
        return $result
    }

    $consumed = $lastNl + 1
    $completeBytes = $buf[0..$lastNl]
    $text = [System.Text.Encoding]::UTF8.GetString($completeBytes)
    $rawLines = $text -split "`n"
    if ($rawLines.Length -gt 0 -and $rawLines[$rawLines.Length - 1] -eq "") {
        $rawLines = $rawLines[0..($rawLines.Length - 2)]
    }
    $cleanLines = @()
    foreach ($rl in $rawLines) { $cleanLines += $rl.TrimEnd("`r") }

    $result.Lines = $cleanLines
    $result.NewOffset = $Offset + $consumed
    return $result
}

# ============================================================================
# 배치 분할(대략 바이트 임계값 기준)
# ============================================================================
function Split-LinesIntoBatches {
    param([array]$LineObjects, [int]$MaxBytes)
    $batches = @()
    $current = @()
    $bytes = 0
    foreach ($lo in $LineObjects) {
        $approx = ([System.Text.Encoding]::UTF8.GetByteCount([string]$lo.content)) + 64
        if ($current.Count -gt 0 -and ($bytes + $approx) -gt $MaxBytes) {
            $batches += , $current
            $current = @()
            $bytes = 0
        }
        $current += $lo
        $bytes += $approx
    }
    if ($current.Count -gt 0) { $batches += , $current }
    # PowerShell가 함수 반환 시 배열의 배열을 재귀적으로 풀어버리는 것을 막기 위해
    # 반환문 자체를 콤마로 감싼다(단순히 지역변수를 콤마로 조립하는 것만으로는 부족함).
    return , $batches
}

# ============================================================================
# API helpers
# ============================================================================
function Send-GiipAgentApiPost {
    param($Config, [string]$AgentApiBase, [string]$FunctionKey, [string]$Path, [string]$BodyJson)
    if (-not $AgentApiBase) {
        Write-CollectorLog "WARN" "Send-GiipAgentApiPost: AgentApiBase not resolved (check apiaddrv2/agentapibase)."
        return $null
    }
    $uri = "$AgentApiBase$Path"
    if ($FunctionKey) { $uri = "$uri`?code=$([System.Uri]::EscapeDataString($FunctionKey))" }
    $headers = @{ 'x-api-key' = $Config['sk'] }
    if ($FunctionKey) { $headers['x-functions-key'] = $FunctionKey }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($BodyJson)
        # Invoke-WebRequest 사용(Invoke-RestMethod 아님) - 이 PC에서 외부 API 호출 시
        # Invoke-RestMethod가 행(hang)하는 것으로 확인된 바 있어(레포 내 기존 관례,
        # Common.ps1/azure-cost-put-win.ps1도 전부 Invoke-WebRequest 사용) 동일하게 맞춘다.
        $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 20 -UseBasicParsing
        return ($resp.Content | ConvertFrom-Json)
    } catch {
        Write-CollectorLog "WARN" "Send-GiipAgentApiPost failed path=$Path uri=$uri : $($_.Exception.Message)"
        return $null
    }
}

function Register-LogStream {
    param($Config, [string]$AgentApiBase, [string]$FunctionKey, [string]$AgentKey, [string]$StreamKey, [string]$StreamType, [string]$FileFingerprint, [int]$RotationGen)
    $bodyObj = [ordered]@{
        agentKey        = $AgentKey
        streamKey       = $StreamKey
        streamType      = $StreamType
        fileFingerprint = $FileFingerprint
        rotationGen     = $RotationGen
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Compress
    $resp = Send-GiipAgentApiPost -Config $Config -AgentApiBase $AgentApiBase -FunctionKey $FunctionKey -Path "/agent-log-register" -BodyJson $bodyJson
    if ($resp -and $resp.streamId) {
        Write-CollectorLog "INFO" "register_stream OK stream=$StreamKey streamId=$($resp.streamId) action=$($resp.action)"
        return $true
    }
    $respDump = if ($resp) { ($resp | ConvertTo-Json -Compress -ErrorAction SilentlyContinue) } else { "<null>" }
    Write-CollectorLog "WARN" "register_stream failed stream=$StreamKey resp=$respDump"
    return $false
}

function Send-LogIngestBatch {
    param($Config, [string]$AgentApiBase, [string]$FunctionKey, [string]$AgentKey, [string]$StreamKey, [int]$RotationGen, [array]$Lines, [string]$QueueDir)

    $fromSeq = $Lines[0].seq
    $toSeq = $Lines[$Lines.Count - 1].seq
    $linesJson = $Lines | ConvertTo-Json -Compress -Depth 5
    if ($Lines.Count -eq 1) { $linesJson = "[$linesJson]" }
    $linesGz = ConvertTo-GzipBase64 -Text $linesJson

    $envelope = [ordered]@{
        agentKey     = $AgentKey
        streamKey    = $StreamKey
        rotationGen  = $RotationGen
        fromSequence = $fromSeq
        toSequence   = $toSeq
        sentAt       = (Get-Iso8601Now)
        compression  = "gzip"
        lines        = $null
        linesGzB64   = $linesGz
    }
    $bodyJson = $envelope | ConvertTo-Json -Compress -Depth 6

    $resp = Send-GiipAgentApiPost -Config $Config -AgentApiBase $AgentApiBase -FunctionKey $FunctionKey -Path "/agent-log-ingest" -BodyJson $bodyJson
    if ($resp -and $resp.streamId) {
        Write-CollectorLog "INFO" "ingest OK stream=$StreamKey seq=${fromSeq}-${toSeq} insertedCount=$($resp.insertedCount)"
        return $true
    }
    $respDump = if ($resp) { ($resp | ConvertTo-Json -Compress -ErrorAction SilentlyContinue) } else { "<null>" }
    Write-CollectorLog "WARN" "ingest failed stream=$StreamKey seq=${fromSeq}-${toSeq} resp=$respDump"
    Add-RetryQueueItem -QueueDir $QueueDir -StreamKey $StreamKey -BodyJson $bodyJson
    return $false
}

# ============================================================================
# tSchedulerAgent 부트스트랩 (giip #1637에서 발견/보강한 갭)
# giipApiSk2 범용 SP 디스패처를 통해 pApiSchedulerAgentUpsertBySK를 호출한다.
# 이 디스패처의 CommandText 관례는 "<SP베이스이름> <jsonKey1> <jsonKey2> ..."이며,
# 각 토큰은 JsonData 객체의 프로퍼티 이름과 문자열 매칭되어 값으로 치환된 뒤
# "EXEC pApi<이름>BySk '<sk>', <val1>, <val2>, ..." 형태로 순서대로(위치기반) 실행된다
# (giipfaw/giipApiSk2/run.ps1 참고, 기존 호출부 예시: lib/Kvs.ps1의
# "KVSPut kType kKey kFactor kValue", giipscripts/azure-cost-put-win.ps1의
# "KVSFactorLast kType kKey kFactor"). 위치기반이라 중간 파라미터를 건너뛸 수 없고,
# 이 디스패처로는 SQL NULL 리터럴을 안전하게 넘길 방법이 없다(빈 토큰이 문자열
# "NULL"로 치환되어 타입 변환 에러를 유발할 수 있음) - 그래서 NOT NULL인
# agentKey/displayName 두 파라미터만 넘기고 나머지(hostIdentifier/osType/...)는
# 이번 스코프에서 채우지 않는다(전부 SP 기본값 NULL로 남음, 이후 단계에서 별도
# heartbeat 경로가 생기면 보강 가능).
# ============================================================================
function Invoke-SchedulerAgentBootstrap {
    param($Config, [string]$AgentKey)
    $displayName = "giipAgentWin-$env:COMPUTERNAME"
    $jsonData = (@{ agentKey = $AgentKey; displayName = $displayName } | ConvertTo-Json -Compress)
    try {
        $resp = Invoke-GiipApiV2 -Config $Config -CommandText "SchedulerAgentUpsert agentKey displayName" -JsonData $jsonData
        if ($resp -and (("$($resp.RstVal)") -eq "200")) {
            Write-CollectorLog "INFO" "SchedulerAgentUpsert bootstrap OK agentKey=$AgentKey"
            return $true
        }
        $respDump = if ($resp) { ($resp | ConvertTo-Json -Compress -ErrorAction SilentlyContinue) } else { "<null>" }
        Write-CollectorLog "WARN" "SchedulerAgentUpsert bootstrap non-200 resp=$respDump"
        return $false
    } catch {
        Write-CollectorLog "WARN" "SchedulerAgentUpsert bootstrap failed: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================================
# Retry queue (전송 실패분 gzip 저장, 용량 제한 + 지수 백오프)
# ============================================================================
function Invoke-EnforceQueueCaps {
    param([string]$QueueDir, [int]$MaxBatches = 500, [int]$MaxMb = 20)
    if (-not (Test-Path $QueueDir)) { return }
    $files = @(Get-ChildItem -Path $QueueDir -Filter "*.json.gz" -Recurse -File -ErrorAction SilentlyContinue)
    $totalCount = $files.Count
    $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $totalBytes) { $totalBytes = 0 }
    $maxBytes = $MaxMb * 1MB
    while (($totalCount -gt $MaxBatches) -or ($totalBytes -gt $maxBytes)) {
        $oldest = $files | Sort-Object LastWriteTime | Select-Object -First 1
        if (-not $oldest) { break }
        Write-CollectorLog "WARN" "retry queue over capacity (count=$totalCount/$MaxBatches, bytes=$totalBytes/$maxBytes) - dropping oldest: $($oldest.FullName)"
        Remove-Item -Path $oldest.FullName -Force -ErrorAction SilentlyContinue
        $files = @($files | Where-Object { $_.FullName -ne $oldest.FullName })
        $totalCount = $files.Count
        $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
        if (-not $totalBytes) { $totalBytes = 0 }
    }
}

function Add-RetryQueueItem {
    param([string]$QueueDir, [string]$StreamKey, [string]$BodyJson)
    $sub = Join-Path $QueueDir (ConvertTo-SanitizedKey $StreamKey)
    if (-not (Test-Path $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null }
    $fname = Join-Path $sub ("{0}_{1}.json.gz" -f (Get-Date -Format "yyyyMMddHHmmssfff"), (Get-Random))
    $gzBytes = ConvertTo-GzipBytes -Text $BodyJson
    [System.IO.File]::WriteAllBytes($fname, $gzBytes)
    Write-CollectorLog "WARN" "enqueue_retry: queued failed batch for stream=$StreamKey -> $fname"
    Invoke-EnforceQueueCaps -QueueDir $QueueDir
}

function Invoke-FlushRetryQueue {
    param($Config, [string]$AgentApiBase, [string]$FunctionKey, [string]$QueueDir, [string]$BackoffStateFile)
    if (-not (Test-Path $QueueDir)) { return }

    $now = Get-Date
    $backoffUntil = $null
    if (Test-Path $BackoffStateFile) {
        try {
            $st = Get-Content -Path $BackoffStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.backoffUntil) { $backoffUntil = [datetime]$st.backoffUntil }
        } catch {}
    }
    if ($backoffUntil -and ($now -lt $backoffUntil)) { return }

    $files = @(Get-ChildItem -Path $QueueDir -Filter "*.json.gz" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)
    if ($files.Count -eq 0) {
        if (Test-Path $BackoffStateFile) { Remove-Item -Path $BackoffStateFile -Force -ErrorAction SilentlyContinue }
        return
    }

    $anyFailed = $false
    foreach ($f in $files) {
        $body = $null
        try {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $body = ConvertFrom-GzipBytes -Bytes $bytes
        } catch { $body = $null }
        if (-not $body) {
            Write-CollectorLog "WARN" "flush_retry_queue: corrupt/empty queued batch, dropping: $($f.FullName)"
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $resp = Send-GiipAgentApiPost -Config $Config -AgentApiBase $AgentApiBase -FunctionKey $FunctionKey -Path "/agent-log-ingest" -BodyJson $body
        if ($resp -and $resp.streamId) {
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
            Write-CollectorLog "INFO" "flush_retry_queue: resent $($f.FullName)"
        } else {
            Write-CollectorLog "WARN" "flush_retry_queue: resend still failing for $($f.FullName)"
            $anyFailed = $true
            break
        }
    }

    if ($anyFailed) {
        $prevSec = 5
        if (Test-Path $BackoffStateFile) {
            try {
                $st2 = Get-Content -Path $BackoffStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($st2.backoffSec) { $prevSec = [int]$st2.backoffSec }
            } catch {}
        }
        $newSec = [Math]::Min($prevSec * 2, 300)
        $dir = Split-Path -Path $BackoffStateFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [ordered]@{
            backoffUntil = (Get-Date).AddSeconds($newSec).ToString("o")
            backoffSec   = $newSec
        } | ConvertTo-Json | Set-Content -Path $BackoffStateFile -Encoding UTF8
    } else {
        if (Test-Path $BackoffStateFile) { Remove-Item -Path $BackoffStateFile -Force -ErrorAction SilentlyContinue }
    }
}

# ============================================================================
# 파일 단위 처리: 회전 감지 -> (필요시) register -> 신규 라인 수집/전송 -> 상태 저장
# ============================================================================
function Invoke-ProcessLogFile {
    param(
        $Config, [string]$AgentApiBase, [string]$FunctionKey, [string]$AgentKey,
        [string]$RepoRoot, [string]$StateDir, [string]$QueueDir, [string]$StreamTypeMap,
        [int]$BatchMaxBytes, [int]$MaxReadBytes, [string]$FilePath
    )

    $streamType = Get-StreamType -FilePath $FilePath -Map $StreamTypeMap
    $relPath = Get-RelativeStreamPath -FilePath $FilePath -RepoRoot $RepoRoot
    $streamKey = "${streamType}:${relPath}"
    $stateFile = Get-StreamStateFile -StateDir $StateDir -StreamKey $streamKey
    $state = Get-StreamState -StateFile $stateFile

    $currentFp = Get-FileFingerprint -FilePath $FilePath
    $item = Get-Item -Path $FilePath -ErrorAction SilentlyContinue
    if (-not $item -or -not $currentFp) {
        Write-CollectorLog "WARN" "Invoke-ProcessLogFile: stat failed for $FilePath, skipping this pass"
        return
    }
    $currentSize = $item.Length

    $offset = $state.Offset
    $rotationGen = $state.RotationGen
    $lastSequence = $state.LastSequence
    $needRegister = $false

    if ($state.IsNew) {
        $needRegister = $true
    } elseif (($currentFp -ne $state.Fingerprint) -or ($currentSize -lt $offset)) {
        Write-CollectorLog "INFO" "rotation detected stream=$streamKey (fp $($state.Fingerprint)->$currentFp, size=$currentSize offset=$offset)"
        $rotationGen++
        $offset = 0
        $lastSequence = 0
        $needRegister = $true
    }

    if ($needRegister) {
        $ok = Register-LogStream -Config $Config -AgentApiBase $AgentApiBase -FunctionKey $FunctionKey -AgentKey $AgentKey -StreamKey $streamKey -StreamType $streamType -FileFingerprint $currentFp -RotationGen $rotationGen
        if (-not $ok) {
            Write-CollectorLog "WARN" "register_stream failed, will retry next pass (state not advanced) stream=$streamKey"
            return
        }
    }

    $read = Read-NewCompleteLines -FilePath $FilePath -Offset $offset -MaxReadBytes $MaxReadBytes
    if ($read.Lines.Count -gt 0) {
        $seq = $lastSequence
        $lineObjs = @()
        foreach ($raw in $read.Lines) {
            $seq++
            $lineObjs += [PSCustomObject]@{ seq = $seq; ts = (Get-Iso8601Now); content = (Protect-SecretLine $raw) }
        }
        $batches = Split-LinesIntoBatches -LineObjects $lineObjs -MaxBytes $BatchMaxBytes
        foreach ($b in $batches) {
            Send-LogIngestBatch -Config $Config -AgentApiBase $AgentApiBase -FunctionKey $FunctionKey -AgentKey $AgentKey -StreamKey $streamKey -RotationGen $rotationGen -Lines $b -QueueDir $QueueDir | Out-Null
        }
        $lastSequence = $seq
    }

    Save-StreamState -StateFile $stateFile -Offset $read.NewOffset -RotationGen $rotationGen -Fingerprint $currentFp -LastSequence $lastSequence
}

# ============================================================================
# 동시실행 방지 (Linux의 ps aux self-count 체크에 대응하는 lock 파일 + PID 생존확인)
# ============================================================================
function Test-SelfRunLock {
    param([string]$LockFile)
    if (Test-Path $LockFile) {
        try {
            $pidText = (Get-Content -Path $LockFile -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
            $existingPid = 0
            if ([int]::TryParse($pidText, [ref]$existingPid) -and $existingPid -gt 0) {
                $proc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
                if ($proc) { return $true }
            }
        } catch {}
    }
    $dir = Split-Path -Path $LockFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $LockFile -Value $PID -Encoding UTF8 -NoNewline
    return $false
}

function Remove-SelfRunLock {
    param([string]$LockFile)
    Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
}

function Get-CollectorConfigInt {
    param($Config, [string]$Key, [int]$Default)
    if ($Config -and $Config[$Key]) {
        $v = 0
        if ([int]::TryParse($Config[$Key], [ref]$v)) { return $v }
    }
    return $Default
}

function Test-LogCollectorEnabled {
    param([string]$Value)
    if (-not $Value) { return $false }
    return ($Value -match '^(?i)(1|true|yes)$')
}

# ============================================================================
# Main
# ============================================================================
function Invoke-LogCollectorRun {
    param([switch]$OnceMode)

    $Config = Get-GiipConfig

    if (-not (Test-LogCollectorEnabled -Value $Config['logcollector_enabled'])) {
        Write-CollectorLog "INFO" "logcollector_enabled not truthy (value='$($Config['logcollector_enabled'])') - skipping (opt-in, see giipAgent.cfg.example)."
        return
    }
    if (-not $Config['sk'] -or -not $Config['apiaddrv2']) {
        Write-CollectorLog "ERROR" "Missing required configuration (sk, apiaddrv2) in giipAgent.cfg."
        return
    }

    if (Test-SelfRunLock -LockFile $LockFile) {
        Write-CollectorLog "INFO" "another LogCollector.ps1 instance already running - skipping this invocation."
        return
    }

    try {
        $agentApiBase = Get-AgentApiBase -Config $Config
        $functionKey = $Config['agentfunctionkey']
        $agentKey = Resolve-AgentKey -Config $Config -CacheFile $AgentKeyCacheFile

        Write-CollectorLog "INFO" "=== LogCollector: start (agentKey=$agentKey apiBase=$agentApiBase once=$OnceMode) ==="

        $globs = $Config['logcollector_globs']
        if (-not $globs) { $globs = Join-Path $RepoRoot "logs\*.log" }
        $streamTypeMap = $Config['logcollector_streamtype_map']
        $batchIntervalSec = Get-CollectorConfigInt -Config $Config -Key 'logcollector_batch_interval_sec' -Default 2
        $batchMaxBytes    = Get-CollectorConfigInt -Config $Config -Key 'logcollector_batch_max_bytes' -Default 131072
        $runDurationSec   = Get-CollectorConfigInt -Config $Config -Key 'logcollector_run_duration_sec' -Default 50
        $queueMaxBatches  = Get-CollectorConfigInt -Config $Config -Key 'logcollector_queue_max_batches' -Default 500
        $queueMaxMb       = Get-CollectorConfigInt -Config $Config -Key 'logcollector_queue_max_mb' -Default 20

        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        if (-not (Test-Path $QueueDir)) { New-Item -ItemType Directory -Path $QueueDir -Force | Out-Null }

        $bootstrapped = Invoke-SchedulerAgentBootstrap -Config $Config -AgentKey $agentKey
        if (-not $bootstrapped) {
            Write-CollectorLog "WARN" "tSchedulerAgent bootstrap failed - stream register/ingest will likely 404 until this succeeds. Continuing this pass anyway (idempotent retry next tick)."
        }

        $runOnePass = {
            Invoke-EnforceQueueCaps -QueueDir $QueueDir -MaxBatches $queueMaxBatches -MaxMb $queueMaxMb
            Invoke-FlushRetryQueue -Config $Config -AgentApiBase $agentApiBase -FunctionKey $functionKey -QueueDir $QueueDir -BackoffStateFile $BackoffStateFile
            $files = Get-DiscoveredFiles -Globs $globs
            foreach ($f in $files) {
                Invoke-ProcessLogFile -Config $Config -AgentApiBase $agentApiBase -FunctionKey $functionKey -AgentKey $agentKey `
                    -RepoRoot $RepoRoot -StateDir $StateDir -QueueDir $QueueDir -StreamTypeMap $streamTypeMap `
                    -BatchMaxBytes $batchMaxBytes -MaxReadBytes 4194304 -FilePath $f
            }
        }

        if ($OnceMode) {
            & $runOnePass
            Write-CollectorLog "INFO" "=== LogCollector: single pass complete (--once) ==="
        } else {
            $start = Get-Date
            $elapsed = 0
            do {
                & $runOnePass
                $elapsed = ((Get-Date) - $start).TotalSeconds
                if ($elapsed -ge $runDurationSec) { break }
                Start-Sleep -Seconds $batchIntervalSec
            } while ($true)
            Write-CollectorLog "INFO" "=== LogCollector: run loop finished (elapsed=$([int]$elapsed)s) ==="
        }
    } finally {
        Remove-SelfRunLock -LockFile $LockFile
    }
}

# ----------------------------------------------------------------------------
# -Register: 1분 간격 opt-in Scheduled Task 등록(기존 "GIIP Agent Task (v3)"와
# 완전히 독립적인 별도 태스크). TaskSchdReg.ps1은 건드리지 않는다.
# ----------------------------------------------------------------------------
if ($Register) {
    $self = $MyInvocation.MyCommand.Path
    $taskName = "GIIP Log Collector Task"
    $arg = "-NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$self`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-CollectorLog "INFO" "Registered Scheduled Task '$taskName' (every 1 minute, opt-in log collector, independent of 'GIIP Agent Task (v3)')."
    return
}

# 직접 실행될 때만 Run 호출 - dot-source해서 개별 함수 단위 테스트 가능하게 함
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-LogCollectorRun -OnceMode:$Once
}
