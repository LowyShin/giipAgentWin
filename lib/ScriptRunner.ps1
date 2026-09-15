# ============================================================================
# giipAgentWin Library: ScriptRunner
# Purpose: CQE 로 받은 스크립트 본문을 타입별로 실제 실행한다.
#
# giip #2546:
#   원래 이 함수(Invoke-ScriptBlock)는 lib/Worker.ps1 안에만 있었고, 그
#   Worker.ps1 을 부르는 유일한 호출자는 구 진입점 giipAgentWin.ps1 의
#   무한루프였다. 그런데 Task Scheduler 에 등록된 것은 giipAgent3.ps1 뿐이라
#   실행기가 통째로 도달 불가능한 상태였다(= CQE 큐를 받아만 놓고 실행하지
#   않는 버그의 실행부 원인). giipscripts/modules/CqeRun.ps1 이 이 함수를
#   재사용할 수 있도록 별도 파일로 분리했다. Worker.ps1 은 이 파일을
#   dot-source 하므로 구 경로의 동작은 그대로 유지된다.
#
# 실행 모드는 두 가지다.
#   - headless : ps1 / cmd / wsf. 창 없이 실행하고 stdout/stderr 를 수집한다.
#                (기존 무인 수집 스크립트의 동작 - 절대 바뀌면 안 된다)
#   - ui       : ps1ui / cmdui. 사용자 세션에 실제 콘솔 창을 띄우고
#                fire-and-forget 한다(stdout 수집 불가, 타임아웃 없음).
# ============================================================================

# giip #2546: 헤드리스 실행 기본 타임아웃(초).
# 예전에는 60초가 Invoke-ScriptBlock 안에 하드코딩돼 있어 조금만 긴 작업도
# 조용히 Kill 당했다. 이제 호출자가 giipAgent.cfg 의 'cqetimeoutsec' 값을
# 넘겨 조정할 수 있고, 키가 없으면 이 기본값(600초)으로 떨어진다.
$Global:GiipCqeDefaultTimeoutSec = 600

# ---------------------------------------------------------------------------
# 인코딩 (giip #2546 / 메모리 'task_scheduler_cp932_stdout_mojibake')
# ---------------------------------------------------------------------------
# 2026-09-15 실측으로 확인한 것 (추측 아님):
#
#  (1) 입력측 - powershell.exe -File 은 BOM 없는 .ps1 을 UTF-8 이 아니라 현재
#      ANSI 코드페이지(이 PC ko-KR = 949)로 읽는다. 예전 코드는 타입과 무관하게
#      UTF-8 **BOM 없이** 썼으므로, 스크립트 본문의 한글이 실행되기도 전에
#      깨졌다(`Write-Host '한글 출력 테스트 OK'` -> `該쒓? 갋쒕젰 行뚯뒪咳?OK`).
#      cmd.exe 는 반대로 BOM 을 붙이면 첫 줄이 `∩╗┐@echo` 가 되어 죽는다.
#
#  (2) 출력측 - 자식 powershell.exe 는 stdout 이 리다이렉트되면 부모의 콘솔
#      코드페이지와 **무관하게** [Console]::OutputEncoding 을 932 로 잡는다
#      (부모가 65001 인 상태에서 자식이 `[Console]::OutputEncoding.CodePage` ->
#      `932`, `IsOutputRedirected` -> `True` 로 응답). 932 로는 한글을 표현할 수
#      없어 자식이 쓰는 시점에 이미 '?' 로 치환돼 버리므로, 부모가 어떤 인코딩으로
#      **읽든** 복구할 수 없다. 자식이 스스로 UTF-8 로 바꿔야만 살아난다
#      (`-Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; ..."` 로
#      확인 -> `한글 테스트2` 정상 출력).
#      이것이 "콘솔에서 직접 돌리면 통과하고 정시 실행만 깨진다"는 그 함정이다.
#
# 결론적으로 타입별 인코딩 정책은 아래와 같다. 순수 ASCII 본문이면 어느 경우든
# 바이트가 동일하므로 **기존 무인 수집 스크립트의 동작은 바뀌지 않는다.**
#
#   | type   | 임시파일 인코딩   | 자식 stdout        |
#   |--------|-------------------|--------------------|
#   | ps1    | UTF-8 with BOM    | 자식이 UTF-8 로 전환, UTF-8 로 디코드 |
#   | cmd    | UTF-8 no BOM      | chcp 65001 후 UTF-8 로 디코드          |
#   | wsf    | UTF-8 no BOM(기존)| OEM 코드페이지(기존 동작 유지)         |
#   | ps1ui  | UTF-8 with BOM    | 캡처 안 함(보이는 창)                  |
#   | cmdui  | OEM 코드페이지    | 캡처 안 함(보이는 창, chcp 건드리지 않음) |
#
# ui 타입에서 chcp 를 건드리지 않는 이유: 보이는 콘솔 창은 그 창의 기본 코드페이지
# 를 그대로 쓰는 것이 대화형 TUI(claude 등) 렌더링에 가장 안전하다.

function Get-GiipOemEncoding {
    try {
        $oemCp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        if ($oemCp -gt 0) { return [System.Text.Encoding]::GetEncoding($oemCp) }
    } catch {
        # 실패하면 호출자가 UTF-8 로 떨어진다.
    }
    return $null
}

# 타입 -> 임시파일 확장자 / 인터프리터 / 실행 모드 / 인코딩 매핑.
function Get-GiipScriptTypeInfo {
    param([string]$Type)

    $utf8Bom   = [System.Text.UTF8Encoding]::new($true)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $oem = Get-GiipOemEncoding
    if (-not $oem) { $oem = $utf8NoBom }

    switch ($Type) {
        'wsf'   { return @{ Ext = '.wsf'; Exe = 'wscript.exe';   Mode = 'headless'; FileEncoding = $utf8NoBom; OutputEncoding = $oem } }
        'ps1'   { return @{ Ext = '.ps1'; Exe = 'powershell.exe'; Mode = 'headless'; FileEncoding = $utf8Bom;   OutputEncoding = $utf8NoBom } }
        'cmd'   { return @{ Ext = '.cmd'; Exe = 'cmd.exe';        Mode = 'headless'; FileEncoding = $utf8NoBom; OutputEncoding = $utf8NoBom } }
        'ps1ui' { return @{ Ext = '.ps1'; Exe = 'powershell.exe'; Mode = 'ui';       FileEncoding = $utf8Bom;   OutputEncoding = $null } }
        'cmdui' { return @{ Ext = '.cmd'; Exe = 'cmd.exe';        Mode = 'ui';       FileEncoding = $oem;       OutputEncoding = $null } }
        default { return $null }
    }
}

function Invoke-ScriptBlock {
    param(
        # giip #2546: 'cmdui' / 'ps1ui' 추가. 기존 3종의 동작은 그대로다.
        [ValidateSet('wsf', 'ps1', 'cmd', 'cmdui', 'ps1ui')] [string]$Type,
        [string]$Body,
        # 헤드리스 실행에만 적용된다(ui 타입은 타임아웃 없음).
        [int]$TimeoutSec = 0
    )

    if ($TimeoutSec -le 0) { $TimeoutSec = $Global:GiipCqeDefaultTimeoutSec }

    $typeInfo = Get-GiipScriptTypeInfo -Type $Type
    if (-not $typeInfo) {
        return @{ Success = $false; Output = "Unsupported script_type: $Type"; ExitCode = -1; Mode = 'unknown' }
    }

    $TempDir = [System.IO.Path]::GetTempPath()
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $filename = "giip_task_${timestamp}_$((Get-Random))"
    $tempFile = Join-Path $TempDir ($filename + $typeInfo.Ext)

    try {
        [System.IO.File]::WriteAllText($tempFile, $Body, $typeInfo.FileEncoding)
    } catch {
        return @{ Success = $false; Output = "Failed to write temp script: $_"; ExitCode = -1; Mode = $typeInfo.Mode }
    }

    if ($typeInfo.Mode -eq 'ui') {
        return Invoke-GiipUiScript -TypeInfo $typeInfo -TempFile $tempFile
    }
    return Invoke-GiipHeadlessScript -TypeInfo $typeInfo -TempFile $tempFile -TimeoutSec $TimeoutSec
}

# ---------------------------------------------------------------------------
# headless 실행 (기존 동작 유지 + 타임아웃 설정화 + stdout 교착 제거)
# ---------------------------------------------------------------------------
function Invoke-GiipHeadlessScript {
    param($TypeInfo, [string]$TempFile, [int]$TimeoutSec)

    # giip #2546: powershell.exe 는 -File 대신 -Command 래퍼를 쓴다. 자식이
    # **스스로** [Console]::OutputEncoding 을 UTF-8 로 바꾸지 않으면 한글이
    # 자식 쪽에서 '?' 로 치환돼 복구 불가가 되기 때문이다(위 인코딩 주석 (2) 참조).
    #   - `& '<file>'` 로 부르므로 스크립트 첫 줄의 param() 블록도 그대로 동작한다
    #     (본문에 프롤로그를 덧붙이는 방식은 param() 을 깨뜨려서 쓸 수 없다).
    #   - `$global:LASTEXITCODE = 0` 으로 초기화한 뒤 마지막에 `exit $LASTEXITCODE`
    #     하므로, 스크립트의 `exit N` 종료 코드가 -File 때와 동일하게 전달된다.
    # cmd.exe 는 chcp 65001 로 콘솔 코드페이지를 UTF-8 로 올린 뒤 본체를 부른다
    # (`&` 체이닝이라 마지막 명령인 본체의 종료 코드가 cmd 의 종료 코드가 된다).
    $cmdArgs = switch ($TypeInfo.Exe) {
        'wscript.exe'    { "//B //Nologo `"$TempFile`"" }
        'powershell.exe' { "-NoProfile -ExecutionPolicy Bypass -Command `"[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$global:LASTEXITCODE=0; & '$TempFile'; exit `$LASTEXITCODE`"" }
        default          { "/c `"chcp 65001>nul & `"`"$TempFile`"`"`"" }
    }

    try {
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $TypeInfo.Exe
        $pInfo.Arguments = $cmdArgs
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true

        if ($TypeInfo.OutputEncoding) {
            $pInfo.StandardOutputEncoding = $TypeInfo.OutputEncoding
            $pInfo.StandardErrorEncoding = $TypeInfo.OutputEncoding
        }

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $pInfo
        $p.Start() | Out-Null

        # giip #2546: 예전 코드는 WaitForExit() 가 끝난 뒤에야 ReadToEnd() 를
        # 불렀다. 자식이 파이프 버퍼(기본 4KB)를 채우면 자식은 write 에서 블록되고
        # 부모는 exit 를 기다리며 블록되는 고전적 교착이 된다. 타임아웃이 60초일
        # 때는 그럭저럭 넘어갔지만 기본값이 600초가 된 지금은 치명적이므로,
        # 기다리기 전에 비동기 읽기를 먼저 시작한다.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        if ($p.WaitForExit($TimeoutSec * 1000)) {
            $stdOut = $outTask.Result
            $stdErr = $errTask.Result
            return @{
                Success  = ($p.ExitCode -eq 0)
                Output   = $stdOut + "`n" + $stdErr
                ExitCode = $p.ExitCode
                Mode     = 'headless'
            }
        }
        else {
            try { $p.Kill() } catch {}
            return @{ Success = $false; Output = "Timeout (${TimeoutSec}s)"; ExitCode = -1; Mode = 'headless' }
        }
    }
    catch {
        return @{ Success = $false; Output = "Execution Error: $_"; ExitCode = -1; Mode = 'headless' }
    }
    finally {
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# ui 실행 (giip #2546 신규): 보이는 콘솔 창 + fire-and-forget
# ---------------------------------------------------------------------------
# ⚠️ 한계 — 반드시 알고 쓸 것:
#   1) stdout/stderr 를 캡처하지 않는다. 캡처하려면 파이프를 리다이렉트해야 하는데
#      그 순간 자식의 stdin 이 TTY 가 아니게 되고, claude 같은 대화형 TUI 는
#      --print 모드로 폴백해 "Input contained only whitespace" 로 즉시 죽는다
#      (giip #2546 통제 비교 실측). 창을 띄우는 것과 출력을 잡는 것은 양립 불가다.
#   2) 따라서 실행 결과로 기록되는 것은 "프로세스 생성 성공/실패"까지다.
#      종료 코드도, 실행 시간도 알 수 없다.
#   3) Task Scheduler 작업이 LogonType=Interactive(사용자 세션)로 돌 때만 창이
#      실제 데스크톱에 보인다. 서비스 계정/세션 0 에서 돌리면 프로세스는 뜨지만
#      화면에는 아무것도 보이지 않는다.
#   4) 임시 스크립트 파일은 자식이 아직 쓰고 있으므로 여기서 지우지 않는다.
#      CqeRun.ps1 이 다음 실행 때 오래된 giip_task_* 파일을 청소한다.
function Invoke-GiipUiScript {
    param($TypeInfo, [string]$TempFile)

    try {
        # -NoExit / /k : 스크립트가 끝나도 창을 닫지 않는다. 대화형 TUI(claude 등)가
        # 살아 있어야 하고, 짧게 끝나는 스크립트도 결과를 눈으로 볼 수 있어야 한다.
        $argList = switch ($TypeInfo.Exe) {
            'powershell.exe' { @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $TempFile) }
            default          { @('/k', "`"$TempFile`"") }
        }

        # UseShellExecute=$true(Start-Process 의 기본, 리다이렉트를 쓰지 않을 때)
        # 로 콘솔 앱을 띄우면 OS 가 새 콘솔을 할당한다 = 진짜 창 + 진짜 TTY stdin.
        $proc = Start-Process -FilePath $TypeInfo.Exe -ArgumentList $argList -WindowStyle Normal -PassThru -ErrorAction Stop

        if ($proc -and $proc.Id) {
            return @{
                Success  = $true
                Output   = "UI process started (PID=$($proc.Id), exe=$($TypeInfo.Exe), script=$TempFile). stdout is not captured for ui script types."
                ExitCode = 0
                Mode     = 'ui'
                Pid      = $proc.Id
            }
        }
        return @{ Success = $false; Output = "Start-Process returned no process object"; ExitCode = -1; Mode = 'ui' }
    }
    catch {
        return @{ Success = $false; Output = "UI Execution Error: $_"; ExitCode = -1; Mode = 'ui' }
    }
}
