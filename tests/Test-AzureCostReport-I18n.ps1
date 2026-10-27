# tests/Test-AzureCostReport-I18n.ps1 - giip #4209
#
# lib/AzureCostReport.ps1 의 언어 지역화를 검증한다:
#   1) -Lang 미지정(기본) = ko: 지역화 이전과 바이트 단위로 동일(csn 47 무회귀)
#   2) -Lang ja: 제목/본문이 일본어, 숫자/통화/날짜는 그대로
#   3) -Lang 로캘 태그(ja-JP / ko-KR): '-' 앞 기본 언어로 정규화
#   4) 모르는 언어(zz-ZZ) / 빈 값 = ko 폴백
#   5) 비교 불가 경로도 언어별로 지역화된다
#   6) -Lang en: 영어 라벨(한글/일본어 누출 없음)
#   7) 숫자·통화 포맷은 언어와 무관하게 동일(라벨만 바뀐다)
#   8) Get-AzureCostReportStrings: 폴백/정규화/키 완전성
#
# 순수 계산 함수만 검증한다(네트워크 I/O 없음). cLang 조회(Resolve-AzureCostRecipientLang)와
# MQE 등록(Send-AzureCostDeltaReport)은 API/DB 의존이라 여기서는 다루지 않는다.
#
# 스타일 참고: tests/Test-ProcessLock.ps1 - 단순 assert + PASS/FAIL 카운트 + 종료 코드.
# 실행: pwsh -NoProfile -File tests/Test-AzureCostReport-I18n.ps1
#       (Windows: powershell -NoProfile -File tests\Test-AzureCostReport-I18n.ps1)

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
        Write-Host "  [FAIL] $Desc"
        Write-Host "         expected: $Expected"
        Write-Host "         actual  : $Actual"
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

# --- source the script under test ---------------------------------------------
. (Join-Path $RepoRoot "lib/AzureCostReport.ps1")

# --- fixtures: alert(증감 비교 가능) + incomparable(직전 없음) -----------------
function New-CurFixture {
    [pscustomobject]@{
        subscription_name = "Sub"
        subscription_id   = "sub-1"
        period            = "MonthToDate"
        currency          = "KRW"
        total_pretax_cost = 1200.0
        collected_at      = "2026-10-27T00:30:00"
        by_service        = @(
            [pscustomobject]@{ service = "VM";      cost = 1000.0 },
            [pscustomobject]@{ service = "Storage"; cost = 200.0 }
        )
        by_resource_group = @([pscustomobject]@{ resource_group = "rg1"; cost = 1200.0 })
    }
}
function New-PrevFixture {
    [pscustomobject]@{
        subscription_name = "Sub"
        subscription_id   = "sub-1"
        period            = "MonthToDate"
        currency          = "KRW"
        total_pretax_cost = 1000.0
        collected_at      = "2026-10-26T00:30:00"
        by_service        = @(
            [pscustomobject]@{ service = "VM";      cost = 900.0 },
            [pscustomobject]@{ service = "Storage"; cost = 100.0 }
        )
        by_resource_group = @([pscustomobject]@{ resource_group = "rg1"; cost = 1000.0 })
    }
}

$cur  = New-CurFixture
$prev = New-PrevFixture

Write-Host "=== 1) -Lang 미지정(기본 ko) ==="
$default = New-AzureCostDeltaReport -Current $cur -Previous $prev -ThresholdPercent 10 -Lssn "71197"
$ko      = New-AzureCostDeltaReport -Current $cur -Previous $prev -ThresholdPercent 10 -Lssn "71197" -Lang "ko"
Assert-Eq   "1a) 기본값 subject == -Lang ko subject" $ko.Subject $default.Subject
Assert-Eq   "1b) 기본값 body == -Lang ko body"       $ko.Body    $default.Body
# 기본 ko 는 지역화 이전의 고정 문구를 그대로 쓴다(샘플 라인으로 무회귀 확인).
Assert-Eq   "1c) ko subject (급증 경보, 지역화 전과 동일)" `
    "[GIIP Azure Cost] 급증 경보 +20.00% - 2026-10-27 (lssn 71197)" $default.Subject
Assert-True "1d) ko body 에 '## Azure Cost 급증 경보' 헤더가 있다" ($default.Body.Contains("## Azure Cost 급증 경보 (2026-10-27)"))
Assert-True "1e) ko body 에 '### 총액' 가 있다"                    ($default.Body.Contains("### 총액"))
Assert-True "1f) ko body 에 '서비스별 증감 (by_service)' 가 있다"  ($default.Body.Contains("### 서비스별 증감 (by_service)"))

Write-Host "=== 2) -Lang ja (일본어) ==="
$ja = New-AzureCostDeltaReport -Current $cur -Previous $prev -ThresholdPercent 10 -Lssn "71197" -Lang "ja"
Assert-Eq   "2a) ja subject (急増アラート)" `
    "[GIIP Azure Cost] 急増アラート +20.00% - 2026-10-27 (lssn 71197)" $ja.Subject
Assert-True "2b) ja body 에 '## Azure Cost 急増アラート' 헤더" ($ja.Body.Contains("## Azure Cost 急増アラート (2026-10-27)"))
Assert-True "2c) ja body 에 '### 総額'"                        ($ja.Body.Contains("### 総額"))
Assert-True "2d) ja body 에 'サービス別増減 (by_service)'"      ($ja.Body.Contains("### サービス別増減 (by_service)"))
Assert-True "2e) ja body 에 일본어 판정 문구"                   ($ja.Body.Contains("**急増アラート**"))
# 지역화는 라벨만 바꾼다 — 숫자/통화/날짜/증감 라인은 그대로다.
Assert-True "2f) ja body 에 숫자/통화 라인 보존(1,000.00 KRW)" ($ja.Body.Contains("1,000.00 KRW"))
Assert-True "2g) ja body 에 증감 항목 라인 보존(VM: 900.00 -> 1,000.00)" ($ja.Body.Contains("VM: 900.00 -> 1,000.00 KRW"))
# 한글이 일본어 출력에 새어 나오면 안 된다(제목/본문의 고정 라벨 기준).
Assert-True "2h) ja subject 에 '급증' 한글 없음" (-not $ja.Subject.Contains("급증"))
Assert-True "2i) ja body 에 '총액' 한글 라벨 없음" (-not $ja.Body.Contains("### 총액"))

Write-Host "=== 3) 로캘 태그 정규화 (ja-JP / ko-KR) ==="
$jaJP = New-AzureCostDeltaReport -Current $cur -Previous $prev -ThresholdPercent 10 -Lssn "71197" -Lang "ja-JP"
Assert-Eq   "3a) ja-JP == ja (subject)" $ja.Subject $jaJP.Subject
Assert-Eq   "3b) ja-JP == ja (body)"    $ja.Body    $jaJP.Body
$koKR = New-AzureCostDeltaReport -Current $cur -Previous $prev -ThresholdPercent 10 -Lssn "71197" -Lang "ko-KR"
Assert-Eq   "3c) ko-KR == ko (subject)" $default.Subject $koKR.Subject
Assert-Eq   "3d) ko-KR == ko (body)"    $default.Body    $koKR.Body

Write-Host "=== 4) 모르는 언어 / 빈 값 -> ko 폴백 ==="
$unk = New-AzureCostDeltaReport -Current $cur -Previous $prev -ThresholdPercent 10 -Lssn "71197" -Lang "zz-ZZ"
Assert-Eq   "4a) zz-ZZ subject == ko subject" $default.Subject $unk.Subject
Assert-Eq   "4b) zz-ZZ body == ko body"       $default.Body    $unk.Body
$empty = New-AzureCostDeltaReport -Current $cur -Previous $prev -ThresholdPercent 10 -Lssn "71197" -Lang ""
Assert-Eq   "4c) 빈 Lang body == ko body"     $default.Body    $empty.Body

Write-Host "=== 5) 비교 불가(직전 없음) 경로도 지역화 ==="
$incKo = New-AzureCostDeltaReport -Current $cur -Previous $null -Lang "ko"
$incJa = New-AzureCostDeltaReport -Current $cur -Previous $null -Lang "ja"
Assert-True "5a) ko 비교불가 subject '(비교 불가)'"  ($incKo.Subject.Contains("(비교 불가)"))
Assert-True "5b) ja 비교불가 subject '(比較不可)'"    ($incJa.Subject.Contains("(比較不可)"))
Assert-True "5c) ko 비교불가 body '비교 불가'"        ($incKo.Body.Contains("**비교 불가**"))
Assert-True "5d) ja 비교불가 body '比較不可'"          ($incJa.Body.Contains("**比較不可**"))
Assert-True "5e) 두 경로 모두 Comparable=false"       ((-not $incKo.Comparable) -and (-not $incJa.Comparable))

Write-Host "=== 6) -Lang en (영어) ==="
$en = New-AzureCostDeltaReport -Current $cur -Previous $prev -ThresholdPercent 10 -Lssn "71197" -Lang "en"
Assert-True "6a) en subject 'Spike alert'"      ($en.Subject.Contains("Spike alert"))
Assert-True "6b) en body '### Total'"           ($en.Body.Contains("### Total"))
Assert-True "6c) en body 'Change by service'"   ($en.Body.Contains("### Change by service (by_service)"))
Assert-True "6d) en 에 한글 누출 없음(### 총액)" (-not $en.Body.Contains("### 총액"))
Assert-True "6e) en 에 일본어 누출 없음(### 総額)" (-not $en.Body.Contains("### 総額"))

Write-Host "=== 7) 숫자/통화 포맷은 언어 불문 동일 ==="
# 세 언어 모두 같은 증감 숫자 라인을 포함해야 한다(라벨만 다르고 계산/포맷은 공통).
foreach ($r in @(@{n="ko";v=$default}, @{n="ja";v=$ja}, @{n="en";v=$en})) {
    Assert-True ("7-{0}) '+200.00 KRW' 증감액 라인 포함" -f $r.n) ($r.v.Body.Contains("+200.00 KRW"))
}
Assert-Eq "7x) DeltaAmount 동일(ko==ja)"  $default.DeltaAmount  $ja.DeltaAmount
Assert-Eq "7y) DeltaPercent 동일(ko==en)" $default.DeltaPercent $en.DeltaPercent

Write-Host "=== 8) Get-AzureCostReportStrings 직접 검증 ==="
$sKo = Get-AzureCostReportStrings -Lang "ko"
$sJa = Get-AzureCostReportStrings -Lang "ja"
$sEn = Get-AzureCostReportStrings -Lang "en"
$sFb = Get-AzureCostReportStrings -Lang "zz"
# 모든 언어표가 ko 와 동일한 키 집합을 가져야 한다(누락 시 빈칸이 생긴다).
$missingJa = @($sKo.Keys | Where-Object { -not $sJa.ContainsKey($_) })
$missingEn = @($sKo.Keys | Where-Object { -not $sEn.ContainsKey($_) })
Assert-Eq   "8a) ja 에 누락된 키 0개" 0 $missingJa.Count
Assert-Eq   "8b) en 에 누락된 키 0개" 0 $missingEn.Count
Assert-Eq   "8c) 모르는 언어 폴백표 == ko 표(hdrTotal)" $sKo.hdrTotal $sFb.hdrTotal
Assert-True "8d) ja hdrTotal 는 ko 와 다르다(실제 번역됨)" ($sJa.hdrTotal -ne $sKo.hdrTotal)

Write-Host ""
Write-Host "=== Results: $($script:PassCount) passed, $($script:FailCount) failed ==="
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
