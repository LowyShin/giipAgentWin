# tests/Test-LogCollector-OffsetRotation.ps1 - giip #1637
#
# lib/LogCollector.ps1의 순수 헬퍼(Protect-SecretLine/ConvertTo-SanitizedKey/...)와
# 오프셋 추적 + 회전 감지(NTFS fileid 변경, truncate) + 재시도 큐(용량 제한,
# drop-oldest) + agentKey 해석 우선순위를 실제 네트워크 호출 없이 검증한다
# (Send-GiipAgentApiPost를 로컬에서 override해서 mock).
#
# 스타일 참고: giipAgentLinux/tests/test-log-collector-offset-rotation.sh -
# 단순 assert + PASS/FAIL 카운트 + 종료 코드.
# 실행: powershell -NoProfile -File tests\Test-LogCollector-OffsetRotation.ps1

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Path -Parent) -Parent

$script:PassCount = 0
$script:FailCount = 0

function Assert-Eq {
    param([string]$Desc, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        Write-Host "  [PASS] $Desc"
        $script:PassCount++
    } else {
        Write-Host "  [FAIL] $Desc (expected='$Expected' actual='$Actual')"
        $script:FailCount++
    }
}

function Assert-True {
    param([string]$Desc, [bool]$Condition)
    if ($Condition) {
        Write-Host "  [PASS] $Desc"
        $script:PassCount++
    } else {
        Write-Host "  [FAIL] $Desc"
        $script:FailCount++
    }
}

function Assert-Contains {
    param([string]$Desc, [string]$Haystack, [string]$Needle)
    if ($Haystack -and $Haystack.Contains($Needle)) {
        Write-Host "  [PASS] $Desc"
        $script:PassCount++
    } else {
        Write-Host "  [FAIL] $Desc (expected to contain '$Needle', got '$Haystack')"
        $script:FailCount++
    }
}

function Assert-NotContains {
    param([string]$Desc, [string]$Haystack, [string]$Needle)
    if ($Haystack -and (-not $Haystack.Contains($Needle))) {
        Write-Host "  [PASS] $Desc"
        $script:PassCount++
    } else {
        Write-Host "  [FAIL] $Desc (expected NOT to contain '$Needle', got '$Haystack')"
        $script:FailCount++
    }
}

# --- source the script under test (main() is guarded, does not auto-run) -----
. (Join-Path $RepoRoot "lib\LogCollector.ps1")

# --- mock the network POST so no real HTTP call happens ----------------------
$script:MockRegisterCalls = 0
$script:MockIngestCalls = 0
$script:MockShouldFailIngest = $false
function Send-GiipAgentApiPost {
    param($Config, [string]$AgentApiBase, [string]$FunctionKey, [string]$Path, [string]$BodyJson)
    if ($Path -eq "/agent-log-register") {
        $script:MockRegisterCalls++
        return [PSCustomObject]@{ streamId = 42; action = "insert"; RstVal = 200 }
    }
    if ($Path -eq "/agent-log-ingest") {
        $script:MockIngestCalls++
        if ($script:MockShouldFailIngest) { return $null }
        return [PSCustomObject]@{ streamId = 42; insertedCount = 1; RstVal = 200 }
    }
    return $null
}

# --- sandbox: throwaway temp dir for all stateful paths -----------------------
$Sandbox = Join-Path $env:TEMP ("logcollector_test_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null
try {

Write-Host "=== Test-LogCollector-OffsetRotation ==="

# ------------------------------------------------------------------
# 1) Protect-SecretLine masking
# ------------------------------------------------------------------
Write-Host "-- Protect-SecretLine --"
$masked = Protect-SecretLine "call url?sk=ABCDEF123&other=1"
Assert-Contains "sk= masked" $masked "sk=***MASKED***"
Assert-NotContains "sk value not leaked" $masked "ABCDEF123"

$masked2 = Protect-SecretLine "login password=hunter2 user=bob"
Assert-Contains "password= masked" $masked2 "password=***MASKED***"
Assert-NotContains "password value not leaked" $masked2 "hunter2"

$masked3 = Protect-SecretLine "Authorization: Bearer abc.def.ghi"
Assert-Contains "Authorization header masked" $masked3 "Authorization: Bearer ***MASKED***"
Assert-NotContains "bearer token not leaked" $masked3 "abc.def.ghi"

$masked4 = Protect-SecretLine "token=xyz789 api_key=k123 secret=s456"
Assert-NotContains "token value not leaked" $masked4 "xyz789"
Assert-NotContains "api_key value not leaked" $masked4 "k123"
Assert-NotContains "secret value not leaked" $masked4 "s456"

# ------------------------------------------------------------------
# 2) ConvertTo-SanitizedKey
# ------------------------------------------------------------------
Write-Host "-- ConvertTo-SanitizedKey --"
Assert-Eq "colon+slash replaced" "agent_operational_log_foo.log" (ConvertTo-SanitizedKey "agent_operational:log/foo.log")
Assert-True "no path separators remain" ((ConvertTo-SanitizedKey "a/b\c:d") -notmatch '[\\/:]')

# ------------------------------------------------------------------
# 3) Get-StreamType heuristic + explicit map
# ------------------------------------------------------------------
Write-Host "-- Get-StreamType --"
Assert-Eq "logs dir -> agent_operational" "agent_operational" (Get-StreamType -FilePath "C:\x\giipAgentWin\logs\git_auto_sync_20260828.log" -Map $null)
Assert-Eq "other dir -> generic_log" "generic_log" (Get-StreamType -FilePath "C:\x\other\foo.log" -Map $null)
Assert-Eq "explicit map wins" "claude_jsonl" (Get-StreamType -FilePath "C:\x\.claude\projects\p\s.jsonl" -Map "*.jsonl:claude_jsonl")

# ------------------------------------------------------------------
# 4) Split-LinesIntoBatches
# ------------------------------------------------------------------
Write-Host "-- Split-LinesIntoBatches --"
$bigContent = "x" * 100
$lineObjs = @()
for ($i = 1; $i -le 10; $i++) { $lineObjs += [PSCustomObject]@{ seq = $i; ts = "t"; content = $bigContent } }
$batches = Split-LinesIntoBatches -LineObjects $lineObjs -MaxBytes 500
Assert-True "batching split into multiple batches" ($batches.Count -gt 1)
$totalLines = 0
foreach ($b in $batches) { $totalLines += $b.Count }
Assert-Eq "all lines preserved across batches" 10 $totalLines

# ------------------------------------------------------------------
# 5) Resolve-AgentKey precedence: cfg override > cache file > generate
# ------------------------------------------------------------------
Write-Host "-- Resolve-AgentKey --"
$cacheFile = Join-Path $Sandbox ".agentkey_cache"

$cfgWithOverride = @{ logcollector_agentkey = "forced-key-123" }
Assert-Eq "cfg override wins" "forced-key-123" (Resolve-AgentKey -Config $cfgWithOverride -CacheFile $cacheFile)
Assert-True "cfg override does not write cache file" (-not (Test-Path $cacheFile))

$cfgNoOverride = @{}
$generated = Resolve-AgentKey -Config $cfgNoOverride -CacheFile $cacheFile
Assert-True "generated key is non-empty" ([bool]$generated)
Assert-True "generated key cached to file" (Test-Path $cacheFile)

$again = Resolve-AgentKey -Config $cfgNoOverride -CacheFile $cacheFile
Assert-Eq "second call reuses cached key" $generated $again

# ------------------------------------------------------------------
# 6) Read-NewCompleteLines: offset advances, incomplete trailing line held back
# ------------------------------------------------------------------
Write-Host "-- Read-NewCompleteLines --"
$logFile = Join-Path $Sandbox "sample.log"
[System.IO.File]::WriteAllText($logFile, "line1`nline2`nline3`n", [System.Text.Encoding]::UTF8)
$r1 = Read-NewCompleteLines -FilePath $logFile -Offset 0
Assert-Eq "3 complete lines read" 3 $r1.Lines.Count
Assert-Eq "line content correct" "line2" $r1.Lines[1]
$offsetAfter1 = $r1.NewOffset
Assert-True "offset advanced past 0" ($offsetAfter1 -gt 0)

# append an incomplete (no trailing newline) line
Add-Content -Path $logFile -Value "partial-no-newline" -NoNewline -Encoding UTF8
$r2 = Read-NewCompleteLines -FilePath $logFile -Offset $offsetAfter1
Assert-Eq "incomplete trailing line NOT returned yet" 0 $r2.Lines.Count
Assert-Eq "offset unchanged when only incomplete data pending" $offsetAfter1 $r2.NewOffset

# complete that line now
Add-Content -Path $logFile -Value "" -Encoding UTF8   # appends newline
$r3 = Read-NewCompleteLines -FilePath $logFile -Offset $offsetAfter1
Assert-Eq "1 newly-completed line read" 1 $r3.Lines.Count
Assert-Eq "completed line content correct" "partial-no-newline" $r3.Lines[0]

# ------------------------------------------------------------------
# 7) Invoke-ProcessLogFile: offset/rotationGen state tracking end-to-end
# ------------------------------------------------------------------
Write-Host "-- Invoke-ProcessLogFile (offset + rotation via mocked API) --"
$stateDir = Join-Path $Sandbox "state"
$queueDir = Join-Path $stateDir "queue"
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
New-Item -ItemType Directory -Path $queueDir -Force | Out-Null

$procLogFile = Join-Path $Sandbox "logs\proc.log"
New-Item -ItemType Directory -Path (Split-Path $procLogFile -Parent) -Force | Out-Null
[System.IO.File]::WriteAllText($procLogFile, "alpha`nbeta`n", [System.Text.Encoding]::UTF8)

$dummyConfig = @{ sk = "test-sk" }
$script:MockRegisterCalls = 0
$script:MockIngestCalls = 0

Invoke-ProcessLogFile -Config $dummyConfig -AgentApiBase "https://example.invalid/api" -FunctionKey $null -AgentKey "test-agent" `
    -RepoRoot $Sandbox -StateDir $stateDir -QueueDir $queueDir -StreamTypeMap $null -BatchMaxBytes 131072 -MaxReadBytes 4194304 -FilePath $procLogFile

Assert-Eq "first pass: 1 register call (new stream)" 1 $script:MockRegisterCalls
Assert-Eq "first pass: 1 ingest call" 1 $script:MockIngestCalls

$streamKeyForState = "agent_operational:" + (Get-RelativeStreamPath -FilePath $procLogFile -RepoRoot $Sandbox)
$stateFile1 = Get-StreamStateFile -StateDir $stateDir -StreamKey $streamKeyForState
$state1 = Get-StreamState -StateFile $stateFile1
Assert-Eq "rotationGen starts at 0" 0 $state1.RotationGen
Assert-Eq "lastSequence after 2 lines" 2 $state1.LastSequence

# second pass, no new data -> no new register, no new ingest
Invoke-ProcessLogFile -Config $dummyConfig -AgentApiBase "https://example.invalid/api" -FunctionKey $null -AgentKey "test-agent" `
    -RepoRoot $Sandbox -StateDir $stateDir -QueueDir $queueDir -StreamTypeMap $null -BatchMaxBytes 131072 -MaxReadBytes 4194304 -FilePath $procLogFile
Assert-Eq "second pass (no new data): register still 1" 1 $script:MockRegisterCalls
Assert-Eq "second pass (no new data): ingest still 1" 1 $script:MockIngestCalls

# append more data -> offset advances, sequence continues (not reset)
Add-Content -Path $procLogFile -Value "gamma" -Encoding UTF8
Invoke-ProcessLogFile -Config $dummyConfig -AgentApiBase "https://example.invalid/api" -FunctionKey $null -AgentKey "test-agent" `
    -RepoRoot $Sandbox -StateDir $stateDir -QueueDir $queueDir -StreamTypeMap $null -BatchMaxBytes 131072 -MaxReadBytes 4194304 -FilePath $procLogFile
$state2 = Get-StreamState -StateFile $stateFile1
Assert-Eq "lastSequence advances (not reset) on plain append" 3 $state2.LastSequence
Assert-Eq "rotationGen unchanged on plain append" 0 $state2.RotationGen

# --- rotation: delete + recreate the file (changes NTFS fileid AND truncates) --
Remove-Item -Path $procLogFile -Force
Start-Sleep -Milliseconds 200
[System.IO.File]::WriteAllText($procLogFile, "new-gen-line1`n", [System.Text.Encoding]::UTF8)
Invoke-ProcessLogFile -Config $dummyConfig -AgentApiBase "https://example.invalid/api" -FunctionKey $null -AgentKey "test-agent" `
    -RepoRoot $Sandbox -StateDir $stateDir -QueueDir $queueDir -StreamTypeMap $null -BatchMaxBytes 131072 -MaxReadBytes 4194304 -FilePath $procLogFile
$state3 = Get-StreamState -StateFile $stateFile1
Assert-Eq "rotationGen incremented after delete+recreate" 1 $state3.RotationGen
Assert-Eq "sequence reset to 1 (single new line) after rotation" 1 $state3.LastSequence

# ------------------------------------------------------------------
# 8) Retry queue: capacity enforcement drops oldest with a logged WARN
# ------------------------------------------------------------------
Write-Host "-- Retry queue capacity (drop-oldest) --"
$rqDir = Join-Path $Sandbox "rq"
New-Item -ItemType Directory -Path $rqDir -Force | Out-Null
for ($i = 1; $i -le 5; $i++) {
    Add-RetryQueueItem -QueueDir $rqDir -StreamKey "test:stream" -BodyJson ("{`"n`":$i}")
    Start-Sleep -Milliseconds 20
}
Invoke-EnforceQueueCaps -QueueDir $rqDir -MaxBatches 3 -MaxMb 20
$remaining = @(Get-ChildItem -Path $rqDir -Filter "*.json.gz" -Recurse -File)
Assert-Eq "queue capped to MaxBatches" 3 $remaining.Count

# ------------------------------------------------------------------
# 9) Retry queue: failed ingest gets queued, and flush resends it
# ------------------------------------------------------------------
Write-Host "-- Retry queue flush --"
$flushQueueDir = Join-Path $Sandbox "flushq"
$backoffFile = Join-Path $flushQueueDir ".backoff.json"
New-Item -ItemType Directory -Path $flushQueueDir -Force | Out-Null

$script:MockShouldFailIngest = $true
$script:MockIngestCalls = 0
$lineObjsFail = @([PSCustomObject]@{ seq = 1; ts = (Get-Iso8601Now); content = "fail-me" })
Send-LogIngestBatch -Config $dummyConfig -AgentApiBase "https://example.invalid/api" -FunctionKey $null -AgentKey "test-agent" -StreamKey "test:fail" -RotationGen 0 -Lines $lineObjsFail -QueueDir $flushQueueDir | Out-Null
$queuedFiles = @(Get-ChildItem -Path $flushQueueDir -Filter "*.json.gz" -Recurse -File)
Assert-Eq "failed ingest queued 1 file" 1 $queuedFiles.Count

$script:MockShouldFailIngest = $false
Invoke-FlushRetryQueue -Config $dummyConfig -AgentApiBase "https://example.invalid/api" -FunctionKey $null -QueueDir $flushQueueDir -BackoffStateFile $backoffFile
$queuedAfterFlush = @(Get-ChildItem -Path $flushQueueDir -Filter "*.json.gz" -Recurse -File)
Assert-Eq "queue drained after successful flush" 0 $queuedAfterFlush.Count

} finally {
    Remove-Item -Path $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Results: $($script:PassCount) passed, $($script:FailCount) failed ==="
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
