# ============================================================================
# AzureCostReport.ps1
# Purpose : Azure Cost 수집 결과(kValue 요약)를 직전 수집분과 비교해
#           MQE 에 올릴 "일일 증감 보고서"(제목 + 본문)를 만든다.
#           순수 계산만 한다 — 네트워크/파일 I/O 없음(테스트 가능하도록 분리).
# 소비처  : giipscripts/azure-cost-put-win.ps1 (수집 직후 자동 보고)
#           giipscripts/azure-cost-report-mqe.ps1 (수동 재발송 / 테스트)
# 사양서  : giipdb/docs/30_Specs/AZURE_COST_COLLECTOR_SPECIFICATION.md §13
# 이슈    : giip #2604
#
# --- 비교 의미에 대한 주의(중요) --------------------------------------------
# 수집기 기본값은 timeframe="MonthToDate" 이므로 total_pretax_cost 는 "그 달 1일부터
# 수집 시각까지의 누적"이다. 따라서 직전 수집분과의 차이(delta)는 사실상 "그 사이
# 하루치 실사용액"이고, 증가율(delta/prev)은 월초일수록 구조적으로 크게 나온다
# (2일차엔 하루치가 누적 전체의 100% 다). 이 성질을 숨기지 않고 본문에 그대로
# 적고, 임계값을 설정 가능하게 둔다.
#
# --- 언어 지역화 (giip #4209) -----------------------------------------------
# tMQLog 메시지가 수신 csn 의 언어와 무관하게 늘 한글로 나가던 문제를 고친다.
# 제목/본문의 모든 라벨·템플릿은 Get-AzureCostReportStrings 의 언어별 문자열표에서
# 꺼낸다. 숫자 계산·포맷은 그대로 두고 **문자열만** 지역화한다. -Lang 미지정이거나
# 모르는 언어면 ko 로 폴백한다(csn 47 기존 동작과 바이트 단위로 동일).
# 수신 csn 의 언어는 호출부(azure-cost-put-win.ps1 / azure-cost-report-mqe.ps1)가
# SK -> csn -> tCorp.cLang 로 풀어 -Lang 으로 주입한다. 이 파일은 I/O 를 하지 않는다.
# ============================================================================

function Get-AzureCostReportStrings {
    <#
      .SYNOPSIS
        Azure Cost 보고서 제목/본문에 쓰는 언어별 문자열표를 돌려준다.
        {0},{1},... 자리표시자는 호출부가 -f 로 채운다(숫자/통화/날짜는 로직이 만든다).
      .PARAMETER Lang
        tCorp.cLang 값(ko/ja/en/zh-CN/zh-TW 등). 모르는 값·빈 값이면 ko 로 폴백한다.
      .NOTES
        각 언어 블록은 그 언어 100% 로만 쓴다 — 한글 출력은 한자/가나 없이 100% 한글,
        일본어·영어는 각자의 자연스러운 표기로. 새 키를 추가하면 ko 를 먼저 채우고
        나머지 언어도 반드시 같은 키를 채운다(누락 시 아래 병합이 ko 값으로 메운다).
    #>
    [CmdletBinding()]
    param([string]$Lang = "ko")

    # 한국어 — 기준(폴백) 언어. 다른 언어에 키가 비면 여기 값으로 메운다.
    $ko = @{
        subjAlert            = "[GIIP Azure Cost] 급증 경보 {0}% - {1}{2}"
        subjDeltaPct         = "[GIIP Azure Cost] 일일 증감 보고 {0}% - {1}{2}"
        subjDeltaAmt         = "[GIIP Azure Cost] 일일 증감 보고 {0} {1} - {2}{3}"
        subjIncomparable     = "[GIIP Azure Cost] 일일 증감 보고 (비교 불가) - {0}{1}"
        lssnSuffix           = " (lssn {0})"

        hdrAlert             = "## Azure Cost 급증 경보 ({0})"
        hdrDaily             = "## Azure Cost 일일 증감 보고 ({0})"
        alertOverThreshold   = "증가율이 임계 {0}% 이상이다."

        lblSubscription      = "- 구독: {0} ({1})"
        lblNode              = "- 수집 노드(lssn): {0} / KVS 좌표: kType=lssn, kKey={0}, kFactor=azure_cost"
        lblPeriod            = "- 기간(period): {0}"
        lblCollectedAt       = "- 이번 수집 시각: {0}"
        lblPrevCollectedAt   = "- 직전 수집 시각: {0}"
        lblPrevNone          = "- 직전 수집 시각: (없음)"
        lblGap               = "- 직전과의 간격: {0} 시간"
        noteGapFuture        = "  - 주의: 직전 레코드의 수집 시각이 이번보다 **미래**다. 시계 오차이거나 비교 대상을 잘못 넘긴 경우다 — 증감 방향을 그대로 믿지 말 것."
        noteGapTooWide       = "  - 주의: 24시간을 크게 넘는 간격이다. '전날 대비'가 아니라 그 간격만큼의 누적 차이다(수집 실패일이 끼어 있을 수 있다)."
        lblThreshold         = "- 알람 임계: {0}% 이상 증가"

        hdrTotal             = "### 총액"
        lblPrevTotal         = "- 직전: {0} {1}"
        lblCurTotal          = "- 이번: {0} {1}"
        lblDeltaAmount       = "- 증감액: {0} {1}"
        lblDeltaPercent      = "- 증감률: {0}%"
        verdictAlert         = "- 판정: **급증 경보** (임계 {0}% 이상)"
        verdictNormal        = "- 판정: 정상 범위 (임계 {0}% 미만)"
        lblDeltaPctNA        = "- 증감률: 산출 불가 — {0}"
        verdictNA            = "- 판정: 임계 판정 불가(증가율을 낼 수 없음)"
        lblCurTotalOnly      = "- 이번: {0} {1}"
        lblDeltaIncomparable = "- 증감: **비교 불가**"
        lblReason            = "- 사유: {0}"
        lblPrevTotalRef      = "- 참고: 직전 레코드의 총액은 {0} {1} 였다(비교 대상이 아니므로 증감으로 계산하지 않는다)."

        noteMtdComparable    = "> 참고: period=MonthToDate 이므로 총액은 '그 달 1일부터의 누적'이다. 위 증감액은 사실상 직전 수집 이후의 실사용액이고, 증감률은 누적 대비 비율이라 월초일수록 구조적으로 크게 나온다."
        noteMtdIncomparable  = "> 참고: period=MonthToDate 이므로 총액은 '그 달 1일부터의 누적'이다(하루치가 아니다)."

        hdrFreshness         = "### 데이터 신선도 경고"
        staleByService       = "- by_service / total_pretax_cost: 이번 실행에서 Cost Management 429 소진으로 {0} 수집분을 그대로 이어받았다(carry-forward). 즉 '이번' 총액은 오늘 실제로 조회한 값이 아니므로, 위 증감은 실제 비용 변화가 아니라 carry-forward 의 결과일 수 있다."
        staleByRg            = "- by_resource_group: {0} 수집분 carry-forward."
        staleByRgSvc         = "- by_resource_group_service: {0} 수집분 carry-forward."
        failByRg             = "- by_resource_group: 수집 실패로 비어 있다(실제로 0건이라는 뜻이 아니다)."
        failByRgSvc          = "- by_resource_group_service: 수집 실패로 비어 있다(실제로 0건이라는 뜻이 아니다)."

        axisByService        = "서비스별 증감 (by_service)"
        axisByResourceGroup  = "리소스 그룹별 증감 (by_resource_group)"
        hdrAxisIncomparable  = "### 항목별 증감"
        axisNoCompare        = "- 비교 대상이 없어 산출하지 않는다."
        hdrTopItems          = "### 이번 수집 상위 항목 (참고)"
        topSvcEmpty          = "- by_service 비어 있음"
        topSvcRow            = "  - {0}: {1} {2}"

        noChange             = "- 항목별 증감 없음(모든 항목의 차이가 0)"
        upTop                = "- 증가 상위 {0}건"
        downTop              = "- 감소 상위 {0}건"
        newItem              = "신규"
        prevZero             = "직전 0"

        reasonNoPrev         = "직전 수집 레코드가 없다(최초 실행이거나 KVS 조회 실패). 전날 값이 없으므로 증감을 산출하지 않는다."
        reasonNoPrevTotal    = "직전 레코드에 total_pretax_cost 가 없다. 증감을 산출할 수 없다."
        reasonPeriodMismatch = "기간(period)이 서로 달라 비교할 수 없다 — 직전='{0}' / 이번='{1}'. (-Days N 로 Custom 기간을 같은 kFactor 에 덮어썼을 때 발생한다.)"
        reasonMonthRolled    = "월이 바뀌었다(직전 {0} / 이번 {1}). MonthToDate 는 달이 바뀌면 0 에서 다시 누적되므로 전일 대비 증감이 성립하지 않는다."
        reasonRatePrevZero   = "직전 총액이 0 이하라 증가율(%)은 산출할 수 없다. 증감액만 표기한다."

        footer               = "생성: giipAgentWin / azure-cost 수집기 (giip #2604). 등록 경로: giipApiJson + pApiMQLogPutbyAk."
    }

    # 日本語
    $ja = @{
        subjAlert            = "[GIIP Azure Cost] 急増アラート {0}% - {1}{2}"
        subjDeltaPct         = "[GIIP Azure Cost] 日次増減レポート {0}% - {1}{2}"
        subjDeltaAmt         = "[GIIP Azure Cost] 日次増減レポート {0} {1} - {2}{3}"
        subjIncomparable     = "[GIIP Azure Cost] 日次増減レポート (比較不可) - {0}{1}"
        lssnSuffix           = " (lssn {0})"

        hdrAlert             = "## Azure Cost 急増アラート ({0})"
        hdrDaily             = "## Azure Cost 日次増減レポート ({0})"
        alertOverThreshold   = "増加率がしきい値 {0}% 以上です。"

        lblSubscription      = "- サブスクリプション: {0} ({1})"
        lblNode              = "- 収集ノード(lssn): {0} / KVS 座標: kType=lssn, kKey={0}, kFactor=azure_cost"
        lblPeriod            = "- 期間(period): {0}"
        lblCollectedAt       = "- 今回の収集時刻: {0}"
        lblPrevCollectedAt   = "- 前回の収集時刻: {0}"
        lblPrevNone          = "- 前回の収集時刻: (なし)"
        lblGap               = "- 前回との間隔: {0} 時間"
        noteGapFuture        = "  - 注意: 前回レコードの収集時刻が今回より**未来**です。時計のずれか、比較対象を誤って渡した場合です — 増減の方向をそのまま信用しないでください。"
        noteGapTooWide       = "  - 注意: 24時間を大きく超える間隔です。「前日比」ではなく、その間隔ぶんの累積差です(収集失敗日が挟まっている可能性があります)。"
        lblThreshold         = "- アラートしきい値: {0}% 以上の増加"

        hdrTotal             = "### 総額"
        lblPrevTotal         = "- 前回: {0} {1}"
        lblCurTotal          = "- 今回: {0} {1}"
        lblDeltaAmount       = "- 増減額: {0} {1}"
        lblDeltaPercent      = "- 増減率: {0}%"
        verdictAlert         = "- 判定: **急増アラート** (しきい値 {0}% 以上)"
        verdictNormal        = "- 判定: 正常範囲 (しきい値 {0}% 未満)"
        lblDeltaPctNA        = "- 増減率: 算出不可 — {0}"
        verdictNA            = "- 判定: しきい値判定不可(増加率を算出できません)"
        lblCurTotalOnly      = "- 今回: {0} {1}"
        lblDeltaIncomparable = "- 増減: **比較不可**"
        lblReason            = "- 理由: {0}"
        lblPrevTotalRef      = "- 参考: 前回レコードの総額は {0} {1} でした(比較対象ではないため増減としては計算しません)。"

        noteMtdComparable    = "> 参考: period=MonthToDate のため総額は「その月の1日からの累積」です。上記の増減額は実質的に前回収集以降の実使用額であり、増減率は累積に対する比率なので月初ほど構造的に大きく出ます。"
        noteMtdIncomparable  = "> 参考: period=MonthToDate のため総額は「その月の1日からの累積」です(1日ぶんではありません)。"

        hdrFreshness         = "### データ鮮度の警告"
        staleByService       = "- by_service / total_pretax_cost: 今回の実行では Cost Management 429 により {0} 収集分をそのまま引き継ぎました(carry-forward)。つまり「今回」の総額は本日実際に照会した値ではないため、上記の増減は実際のコスト変化ではなく carry-forward の結果である可能性があります。"
        staleByRg            = "- by_resource_group: {0} 収集分を carry-forward。"
        staleByRgSvc         = "- by_resource_group_service: {0} 収集分を carry-forward。"
        failByRg             = "- by_resource_group: 収集失敗で空です(実際に0件という意味ではありません)。"
        failByRgSvc          = "- by_resource_group_service: 収集失敗で空です(実際に0件という意味ではありません)。"

        axisByService        = "サービス別増減 (by_service)"
        axisByResourceGroup  = "リソースグループ別増減 (by_resource_group)"
        hdrAxisIncomparable  = "### 項目別増減"
        axisNoCompare        = "- 比較対象がないため算出しません。"
        hdrTopItems          = "### 今回収集の上位項目 (参考)"
        topSvcEmpty          = "- by_service は空です"
        topSvcRow            = "  - {0}: {1} {2}"

        noChange             = "- 項目別の増減なし(すべての項目の差が0)"
        upTop                = "- 増加の上位 {0} 件"
        downTop              = "- 減少の上位 {0} 件"
        newItem              = "新規"
        prevZero             = "前回 0"

        reasonNoPrev         = "前回の収集レコードがありません(初回実行か KVS 照会失敗)。前日値がないため増減を算出しません。"
        reasonNoPrevTotal    = "前回レコードに total_pretax_cost がありません。増減を算出できません。"
        reasonPeriodMismatch = "期間(period)が互いに異なるため比較できません — 前回='{0}' / 今回='{1}'。(-Days N で Custom 期間を同じ kFactor に上書きしたときに発生します。)"
        reasonMonthRolled    = "月が変わりました(前回 {0} / 今回 {1})。MonthToDate は月が変わると0から再累積するため、前日比の増減が成立しません。"
        reasonRatePrevZero   = "前回総額が0以下のため増加率(%)は算出できません。増減額のみ表示します。"

        footer               = "生成: giipAgentWin / azure-cost 収集機 (giip #2604)。登録経路: giipApiJson + pApiMQLogPutbyAk。"
    }

    # English
    $en = @{
        subjAlert            = "[GIIP Azure Cost] Spike alert {0}% - {1}{2}"
        subjDeltaPct         = "[GIIP Azure Cost] Daily change report {0}% - {1}{2}"
        subjDeltaAmt         = "[GIIP Azure Cost] Daily change report {0} {1} - {2}{3}"
        subjIncomparable     = "[GIIP Azure Cost] Daily change report (not comparable) - {0}{1}"
        lssnSuffix           = " (lssn {0})"

        hdrAlert             = "## Azure Cost spike alert ({0})"
        hdrDaily             = "## Azure Cost daily change report ({0})"
        alertOverThreshold   = "The increase rate is at or above the {0}% threshold."

        lblSubscription      = "- Subscription: {0} ({1})"
        lblNode              = "- Collecting node (lssn): {0} / KVS key: kType=lssn, kKey={0}, kFactor=azure_cost"
        lblPeriod            = "- Period: {0}"
        lblCollectedAt       = "- This collection time: {0}"
        lblPrevCollectedAt   = "- Previous collection time: {0}"
        lblPrevNone          = "- Previous collection time: (none)"
        lblGap               = "- Gap from previous: {0} hours"
        noteGapFuture        = "  - Note: the previous record's collection time is **later** than this one. This is a clock skew or a wrong comparison target was passed - do not trust the change direction as-is."
        noteGapTooWide       = "  - Note: the gap is well over 24 hours. This is not a day-over-day change but the accumulated difference over that gap (a failed collection day may be in between)."
        lblThreshold         = "- Alert threshold: increase of {0}% or more"

        hdrTotal             = "### Total"
        lblPrevTotal         = "- Previous: {0} {1}"
        lblCurTotal          = "- This time: {0} {1}"
        lblDeltaAmount       = "- Change amount: {0} {1}"
        lblDeltaPercent      = "- Change rate: {0}%"
        verdictAlert         = "- Verdict: **spike alert** (threshold {0}% or more)"
        verdictNormal        = "- Verdict: normal range (below {0}% threshold)"
        lblDeltaPctNA        = "- Change rate: not computable - {0}"
        verdictNA            = "- Verdict: threshold not evaluable (cannot compute the increase rate)"
        lblCurTotalOnly      = "- This time: {0} {1}"
        lblDeltaIncomparable = "- Change: **not comparable**"
        lblReason            = "- Reason: {0}"
        lblPrevTotalRef      = "- Note: the previous record's total was {0} {1} (not a comparison target, so it is not counted as a change)."

        noteMtdComparable    = "> Note: period=MonthToDate, so the total is 'the accumulation since the 1st of the month'. The change amount above is effectively the actual usage since the previous collection, and the change rate is a ratio against the accumulation, so it is structurally larger earlier in the month."
        noteMtdIncomparable  = "> Note: period=MonthToDate, so the total is 'the accumulation since the 1st of the month' (not a single day)."

        hdrFreshness         = "### Data freshness warning"
        staleByService       = "- by_service / total_pretax_cost: in this run, Cost Management 429 exhaustion carried forward the {0} collection as-is (carry-forward). So 'this' total is not a value actually queried today, and the change above may be the result of carry-forward rather than a real cost change."
        staleByRg            = "- by_resource_group: carry-forward of the {0} collection."
        staleByRgSvc         = "- by_resource_group_service: carry-forward of the {0} collection."
        failByRg             = "- by_resource_group: empty due to collection failure (does not mean there are genuinely 0 items)."
        failByRgSvc          = "- by_resource_group_service: empty due to collection failure (does not mean there are genuinely 0 items)."

        axisByService        = "Change by service (by_service)"
        axisByResourceGroup  = "Change by resource group (by_resource_group)"
        hdrAxisIncomparable  = "### Change by item"
        axisNoCompare        = "- No comparison target, so not computed."
        hdrTopItems          = "### Top items in this collection (reference)"
        topSvcEmpty          = "- by_service is empty"
        topSvcRow            = "  - {0}: {1} {2}"

        noChange             = "- No change by item (the difference of every item is 0)"
        upTop                = "- Top {0} increases"
        downTop              = "- Top {0} decreases"
        newItem              = "new"
        prevZero             = "prev 0"

        reasonNoPrev         = "There is no previous collection record (first run or KVS lookup failure). With no prior-day value, no change is computed."
        reasonNoPrevTotal    = "The previous record has no total_pretax_cost. The change cannot be computed."
        reasonPeriodMismatch = "The periods differ, so they cannot be compared - previous='{0}' / this='{1}'. (Happens when a Custom period from -Days N overwrote the same kFactor.)"
        reasonMonthRolled    = "The month rolled over (previous {0} / this {1}). MonthToDate re-accumulates from 0 when the month changes, so a day-over-day change does not hold."
        reasonRatePrevZero   = "The previous total is 0 or less, so the increase rate (%) cannot be computed. Only the change amount is shown."

        footer               = "Generated by: giipAgentWin / azure-cost collector (giip #2604). Registration path: giipApiJson + pApiMQLogPutbyAk."
    }

    $tables = @{ "ko" = $ko; "ja" = $ja; "en" = $en }

    # cLang 은 'ko' 뿐 아니라 'ko-KR' / 'ja-JP' / 'en-US' 같은 로캘 태그로도 온다
    # (pApiCorpLangGetbySk 는 값이 없으면 'ko-KR' 로 돌려준다). 먼저 전체 태그로 맞추고,
    # 없으면 '-' 앞 기본 언어(ko/ja/en)로 다시 맞춘다. 그래도 모르면 ko 폴백.
    $key = ([string]$Lang).Trim().ToLowerInvariant()
    if (-not $tables.ContainsKey($key)) {
        $primary = ($key -split '[-_]')[0]
        if ($tables.ContainsKey($primary)) { $key = $primary } else { $key = "ko" }
    }

    # 선택 언어에 없는 키는 ko 값으로 메운다(언어표 누락이 빈칸을 만들지 않도록).
    $selected = $tables[$key]
    $merged = @{}
    foreach ($k in $ko.Keys) {
        if ($selected.ContainsKey($k)) { $merged[$k] = $selected[$k] } else { $merged[$k] = $ko[$k] }
    }
    return $merged
}

function Resolve-AzureCostAlertThreshold {
    <#
      .SYNOPSIS
        증가율 알람 임계(%)를 결정한다. 우선순위: 명시 인자 > cfg azure_cost_alert_pct > 10.
        (하드코딩 금지 — 호출부는 -1 을 넘겨 "지정 안 함"을 표현한다.)
    #>
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary]$Config,
        [double]$Requested = -1
    )
    if ($Requested -ge 0) { return [double]$Requested }
    if ($null -ne $Config -and $Config.azure_cost_alert_pct) {
        $parsed = 0.0
        if ([double]::TryParse([string]$Config.azure_cost_alert_pct, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            if ($parsed -ge 0) { return $parsed }
        }
    }
    return 10.0
}

function Format-AzureCostNumber {
    param([object]$Value, [int]$Digits = 2)
    if ($null -eq $Value) { return "-" }
    $d = 0.0
    if (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        return [string]$Value
    }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:N$Digits}", $d)
}

function Format-AzureCostSigned {
    param([object]$Value, [int]$Digits = 2)
    $d = 0.0
    if (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        return [string]$Value
    }
    $sign = "+"
    if ($d -lt 0) { $sign = "" }   # 음수는 문자열 자체에 '-' 가 붙는다
    return $sign + (Format-AzureCostNumber -Value $d -Digits $Digits)
}

function ConvertTo-AzureCostDateTime {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
        return $dt
    }
    return $null
}

function Get-AzureCostAxisDelta {
    <#
      .SYNOPSIS
        이름 기준으로 현재/직전 축 배열을 조인해 항목별 증감을 계산한다.
        현재에만 있는 항목(신규)은 prev=0, 직전에만 있는 항목(사라짐)은 cur=0 으로 잡는다.
    #>
    [CmdletBinding()]
    param(
        [object[]]$CurrentList,
        [object[]]$PreviousList,
        [Parameter(Mandatory = $true)][string]$NameProperty
    )

    $curMap = @{}
    foreach ($item in @($CurrentList)) {
        if ($null -eq $item) { continue }
        $name = [string]$item.$NameProperty
        if ([string]::IsNullOrEmpty($name)) { continue }
        $curMap[$name] = [double]$item.cost
    }
    $prevMap = @{}
    foreach ($item in @($PreviousList)) {
        if ($null -eq $item) { continue }
        $name = [string]$item.$NameProperty
        if ([string]::IsNullOrEmpty($name)) { continue }
        $prevMap[$name] = [double]$item.cost
    }

    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($k in $curMap.Keys)  { [void]$names.Add($k) }
    foreach ($k in $prevMap.Keys) { [void]$names.Add($k) }

    $rows = foreach ($name in $names) {
        $cur = 0.0
        if ($curMap.ContainsKey($name)) { $cur = [double]$curMap[$name] }
        $prev = 0.0
        if ($prevMap.ContainsKey($name)) { $prev = [double]$prevMap[$name] }
        $delta = $cur - $prev
        $pct = $null
        if ($prev -gt 0) { $pct = ($delta / $prev) * 100.0 }
        [pscustomobject]@{
            name    = $name
            cur     = $cur
            prev    = $prev
            delta   = $delta
            pct     = $pct
            isNew   = (-not $prevMap.ContainsKey($name))
            isGone  = (-not $curMap.ContainsKey($name))
        }
    }
    return @($rows)
}

function Format-AzureCostAxisSection {
    <#
      증감 상위/하위 항목을 사람이 읽는 목록으로 만든다. 변화가 전혀 없으면 안내 문구 1줄.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [object[]]$Rows,
        [string]$Currency = "",
        [int]$TopUp = 5,
        [int]$TopDown = 3,
        # 언어별 문자열표(Get-AzureCostReportStrings). 미지정이면 ko.
        [System.Collections.IDictionary]$Str = $null
    )

    if ($null -eq $Str) { $Str = Get-AzureCostReportStrings -Lang "ko" }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("### $Title")

    $changed = @($Rows | Where-Object { [math]::Abs($_.delta) -ge 0.0001 })
    if ($changed.Count -eq 0) {
        $lines.Add($Str.noChange)
        $lines.Add("")
        return ($lines -join "`n")
    }

    $ups = @($changed | Where-Object { $_.delta -gt 0 } | Sort-Object -Property delta -Descending | Select-Object -First $TopUp)
    $downs = @($changed | Where-Object { $_.delta -lt 0 } | Sort-Object -Property delta | Select-Object -First $TopDown)

    if ($ups.Count -gt 0) {
        $lines.Add(($Str.upTop -f $ups.Count))
        foreach ($r in $ups) {
            $pctText = $Str.newItem
            if ($null -ne $r.pct) { $pctText = (Format-AzureCostSigned -Value $r.pct) + "%" }
            $lines.Add(("  - {0}: {1} -> {2} {3} ({4} {3}, {5})" -f `
                $r.name, (Format-AzureCostNumber -Value $r.prev), (Format-AzureCostNumber -Value $r.cur), $Currency, `
                (Format-AzureCostSigned -Value $r.delta), $pctText))
        }
    }
    if ($downs.Count -gt 0) {
        $lines.Add(($Str.downTop -f $downs.Count))
        foreach ($r in $downs) {
            $pctText = $Str.prevZero
            if ($null -ne $r.pct) { $pctText = (Format-AzureCostSigned -Value $r.pct) + "%" }
            $lines.Add(("  - {0}: {1} -> {2} {3} ({4} {3}, {5})" -f `
                $r.name, (Format-AzureCostNumber -Value $r.prev), (Format-AzureCostNumber -Value $r.cur), $Currency, `
                (Format-AzureCostSigned -Value $r.delta), $pctText))
        }
    }
    $lines.Add("")
    return ($lines -join "`n")
}

function New-AzureCostDeltaReport {
    <#
      .SYNOPSIS
        현재 수집 요약($Current)과 직전 수집 요약($Previous)을 비교해 MQE 보고서를 만든다.

      .PARAMETER Previous
        직전 KVS 레코드의 kValue. $null 이면 "비교 불가"로 정직하게 보고한다
        (0 으로 치지 않고, 건너뛰지도 않는다).

      .PARAMETER ThresholdPercent
        증가율 알람 임계(%). 기본 10. 하드코딩하지 않고 호출부에서 주입한다.

      .PARAMETER Lang
        수신 csn 의 언어(tCorp.cLang: ko/ja/en/ko-KR/ja-JP...). 호출부가 SK->csn->cLang
        로 풀어 넘긴다. 미지정이거나 모르는 값이면 ko 로 폴백한다(기존 동작과 동일).

      .OUTPUTS
        [pscustomobject] @{ Subject; Body; IsAlert; Comparable; Reason;
                            DeltaAmount; DeltaPercent; CurrentTotal; PreviousTotal }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Current,
        $Previous = $null,
        [double]$ThresholdPercent = 10,
        [string]$Lssn = "",
        [int]$TopN = 5,
        [string]$Lang = "ko"
    )

    $Str = Get-AzureCostReportStrings -Lang $Lang

    $currency = [string]$Current.currency
    $curTotal = 0.0
    if ($null -ne $Current.total_pretax_cost) { $curTotal = [double]$Current.total_pretax_cost }
    $curAt = ConvertTo-AzureCostDateTime -Text ([string]$Current.collected_at)
    if ($null -eq $curAt) { $curAt = Get-Date }
    $dateLabel = $curAt.ToString("yyyy-MM-dd")

    $prevAt = $null
    $prevTotal = $null
    if ($null -ne $Previous -and $null -ne $Previous.total_pretax_cost) {
        $prevTotal = [double]$Previous.total_pretax_cost
        $prevAt = ConvertTo-AzureCostDateTime -Text ([string]$Previous.collected_at)
    }

    # --- 비교 가능 여부 판정 (불가 사유는 그대로 본문에 싣는다) ---------------
    $comparable = $true
    $reason = ""
    if ($null -eq $Previous) {
        $comparable = $false
        $reason = $Str.reasonNoPrev
    } elseif ($null -eq $prevTotal) {
        $comparable = $false
        $reason = $Str.reasonNoPrevTotal
    } elseif ([string]$Previous.period -ne [string]$Current.period) {
        $comparable = $false
        $reason = ($Str.reasonPeriodMismatch -f ([string]$Previous.period), ([string]$Current.period))
    } elseif ([string]$Current.period -eq "MonthToDate" -and $null -ne $prevAt -and ($prevAt.Year -ne $curAt.Year -or $prevAt.Month -ne $curAt.Month)) {
        $comparable = $false
        $reason = ($Str.reasonMonthRolled -f $prevAt.ToString('yyyy-MM'), $curAt.ToString('yyyy-MM'))
    }

    $deltaAmount = $null
    $deltaPercent = $null
    $rateUnavailableReason = ""
    if ($comparable) {
        $deltaAmount = $curTotal - [double]$prevTotal
        if ([double]$prevTotal -gt 0) {
            $deltaPercent = ($deltaAmount / [double]$prevTotal) * 100.0
        } else {
            $rateUnavailableReason = $Str.reasonRatePrevZero
        }
    }

    $isAlert = ($comparable -and $null -ne $deltaPercent -and $deltaPercent -ge $ThresholdPercent)

    # --- 제목 -----------------------------------------------------------------
    # 중복방지 게이트(같은 mqSubject+mqTo+cSn 의 미발송 메시지가 있으면 조용히 스킵)를
    # 피하려면 제목이 매일 달라야 한다 -> 날짜를 반드시 넣는다.
    $lssnText = ""
    if ($Lssn) { $lssnText = ($Str.lssnSuffix -f $Lssn) }
    if (-not $comparable) {
        $subject = ($Str.subjIncomparable -f $dateLabel, $lssnText)
    } elseif ($null -eq $deltaPercent) {
        $subject = ($Str.subjDeltaAmt -f (Format-AzureCostSigned -Value $deltaAmount), $currency, $dateLabel, $lssnText)
    } elseif ($isAlert) {
        $subject = ($Str.subjAlert -f (Format-AzureCostSigned -Value $deltaPercent), $dateLabel, $lssnText)
    } else {
        $subject = ($Str.subjDeltaPct -f (Format-AzureCostSigned -Value $deltaPercent), $dateLabel, $lssnText)
    }

    # --- 본문 -----------------------------------------------------------------
    $b = New-Object System.Collections.Generic.List[string]
    if ($isAlert) {
        $b.Add(($Str.hdrAlert -f $dateLabel))
        $b.Add("")
        $b.Add(($Str.alertOverThreshold -f (Format-AzureCostNumber -Value $ThresholdPercent)))
    } else {
        $b.Add(($Str.hdrDaily -f $dateLabel))
    }
    $b.Add("")
    $b.Add(($Str.lblSubscription -f ([string]$Current.subscription_name), ([string]$Current.subscription_id)))
    $b.Add(($Str.lblNode -f $Lssn))
    $b.Add(($Str.lblPeriod -f ([string]$Current.period)))
    $b.Add(($Str.lblCollectedAt -f ([string]$Current.collected_at)))
    if ($null -ne $Previous) {
        $b.Add(($Str.lblPrevCollectedAt -f ([string]$Previous.collected_at)))
        if ($null -ne $prevAt) {
            $gapHours = ($curAt - $prevAt).TotalHours
            $b.Add(($Str.lblGap -f (Format-AzureCostNumber -Value $gapHours -Digits 1)))
            if ($gapHours -lt 0) {
                $b.Add($Str.noteGapFuture)
            } elseif ($gapHours -gt 36) {
                $b.Add($Str.noteGapTooWide)
            }
        }
    } else {
        $b.Add($Str.lblPrevNone)
    }
    $b.Add(($Str.lblThreshold -f (Format-AzureCostNumber -Value $ThresholdPercent)))
    $b.Add("")

    $b.Add($Str.hdrTotal)
    if ($comparable) {
        $b.Add(($Str.lblPrevTotal -f (Format-AzureCostNumber -Value $prevTotal), $currency))
        $b.Add(($Str.lblCurTotal -f (Format-AzureCostNumber -Value $curTotal), $currency))
        $b.Add(($Str.lblDeltaAmount -f (Format-AzureCostSigned -Value $deltaAmount), $currency))
        if ($null -ne $deltaPercent) {
            $b.Add(($Str.lblDeltaPercent -f (Format-AzureCostSigned -Value $deltaPercent)))
            if ($isAlert) {
                $b.Add(($Str.verdictAlert -f (Format-AzureCostNumber -Value $ThresholdPercent)))
            } else {
                $b.Add(($Str.verdictNormal -f (Format-AzureCostNumber -Value $ThresholdPercent)))
            }
        } else {
            $b.Add(($Str.lblDeltaPctNA -f $rateUnavailableReason))
            $b.Add($Str.verdictNA)
        }
    } else {
        $b.Add(($Str.lblCurTotalOnly -f (Format-AzureCostNumber -Value $curTotal), $currency))
        $b.Add($Str.lblDeltaIncomparable)
        $b.Add(($Str.lblReason -f $reason))
        if ($null -ne $prevTotal) {
            $b.Add(($Str.lblPrevTotalRef -f (Format-AzureCostNumber -Value $prevTotal), ([string]$Previous.currency)))
        }
    }
    $b.Add("")

    if ([string]$Current.period -eq "MonthToDate") {
        if ($comparable) {
            $b.Add($Str.noteMtdComparable)
        } else {
            $b.Add($Str.noteMtdIncomparable)
        }
        $b.Add("")
    }

    # 정직성: carry-forward 로 실려온 축이면 증감 0 이 "변화 없음"을 뜻하지 않는다.
    $staleNotes = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Current.by_service_stale_since) {
        $staleNotes.Add(($Str.staleByService -f ([string]$Current.by_service_stale_since)))
    }
    if ($null -ne $Current.by_resource_group_stale_since) {
        $staleNotes.Add(($Str.staleByRg -f ([string]$Current.by_resource_group_stale_since)))
    }
    if ($null -ne $Current.by_resource_group_service_stale_since) {
        $staleNotes.Add(($Str.staleByRgSvc -f ([string]$Current.by_resource_group_service_stale_since)))
    }
    if ($true -eq $Current.by_resource_group_collection_failed) {
        $staleNotes.Add($Str.failByRg)
    }
    if ($true -eq $Current.by_resource_group_service_collection_failed) {
        $staleNotes.Add($Str.failByRgSvc)
    }
    if ($staleNotes.Count -gt 0) {
        $b.Add($Str.hdrFreshness)
        foreach ($n in $staleNotes) { $b.Add($n) }
        $b.Add("")
    }

    if ($comparable) {
        $svcRows = Get-AzureCostAxisDelta -CurrentList @($Current.by_service) -PreviousList @($Previous.by_service) -NameProperty "service"
        $b.Add((Format-AzureCostAxisSection -Title $Str.axisByService -Rows $svcRows -Currency $currency -TopUp $TopN -Str $Str))

        $rgRows = Get-AzureCostAxisDelta -CurrentList @($Current.by_resource_group) -PreviousList @($Previous.by_resource_group) -NameProperty "resource_group"
        $b.Add((Format-AzureCostAxisSection -Title $Str.axisByResourceGroup -Rows $rgRows -Currency $currency -TopUp $TopN -Str $Str))
    } else {
        $b.Add($Str.hdrAxisIncomparable)
        $b.Add($Str.axisNoCompare)
        $b.Add("")
        $b.Add($Str.hdrTopItems)
        $topSvc = @(@($Current.by_service) | Where-Object { $null -ne $_ } | Sort-Object -Property cost -Descending | Select-Object -First $TopN)
        if ($topSvc.Count -eq 0) {
            $b.Add($Str.topSvcEmpty)
        } else {
            foreach ($s in $topSvc) {
                $b.Add(($Str.topSvcRow -f ([string]$s.service), (Format-AzureCostNumber -Value $s.cost), $currency))
            }
        }
        $b.Add("")
    }

    $b.Add("---")
    $b.Add($Str.footer)

    return [pscustomobject]@{
        Subject       = $subject
        Body          = ($b -join "`n")
        IsAlert       = $isAlert
        Comparable    = $comparable
        Reason        = $reason
        DeltaAmount   = $deltaAmount
        DeltaPercent  = $deltaPercent
        CurrentTotal  = $curTotal
        PreviousTotal = $prevTotal
    }
}

function Resolve-AzureCostRecipientLang {
    <#
      .SYNOPSIS
        보고서가 들어갈 수신 csn 의 언어(tCorp.cLang)를 giipApi 로 조회한다.
        cSn 은 SK 로 결정되므로(pApiMQLogPutbyAk 와 같은 규칙), 보고서를 넣을 때
        쓰는 그 SK 로 CorpLangGet 을 호출해 같은 csn 의 언어를 얻는다.

      .DESCRIPTION
        경로: giipApi text="CorpLangGet" (-> pApiCorpLangGetbySk). jsondata 없이
        usertoken=SK 만 넘기면 SK 의 csn 에서 ISNULL(cLang,'ko-KR') 를 돌려준다.
        에이전트는 DB 자격이 없어 API 를 거친다. **조회 실패/빈 값이면 'ko' 로 폴백**해
        csn 47 등 기존 동작에 회귀가 없도록 한다(이 함수가 I/O 를 하는 유일한 곳이고,
        순수 계산 함수 New-AzureCostDeltaReport 는 그대로 I/O 가 없다).

      .OUTPUTS
        [string] 언어 코드(예: 'ko-KR','ja','en'). 실패하면 'ko'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [string]$Sk = ""
    )

    $token = if ($Sk) { $Sk } else { [string]$Config.sk }
    if (-not $token) { return "ko" }

    try {
        # giipApiSk2/Sk3 경로(bySk). 토큰 'CorpLangGet' -> exec pApiCorpLangGetbySk '<SK>'.
        # 이름에 'Get' 이 있어 dispatcher 가 jsondata 를 꼬리 파라미터로 덧붙이지 않는다.
        # SK 는 전용 토큰으로 넘겨 cSn 이 그 SK 로 결정되게 한다($Global:GiipSessionAK 오염 방지).
        $savedAk = $Global:GiipSessionAK
        $Global:GiipSessionAK = $token
        try {
            $resp = Invoke-GiipApiV2 -Config $Config -CommandText "CorpLangGet" -JsonData "{}" -RawList
        } finally {
            $Global:GiipSessionAK = $savedAk
        }

        $row = $null
        if ($resp -and $resp.data -and @($resp.data).Count -gt 0) { $row = @($resp.data)[0] }
        elseif ($resp -and $resp.cLang) { $row = $resp }

        if ($row -and "$($row.RstVal)" -eq "200" -and $row.cLang) {
            return [string]$row.cLang
        }
    } catch {
        Write-MqeLog "WARN" "cLang 조회 실패($($_.Exception.Message)) — ko 로 폴백한다."
    }
    return "ko"
}

function Send-AzureCostDeltaReport {
    <#
      .SYNOPSIS
        보고서를 만들어 MQE(tMQLog)에 등록한다. lib/Mqe.ps1 이 먼저 로드돼 있어야 한다.

      .DESCRIPTION
        수집기(azure-cost-put-win.ps1)와 수동 스크립트(azure-cost-report-mqe.ps1)가
        똑같은 판정을 쓰도록 만든 공통 진입점이다.
        반환값에 Report(제목/본문/판정)와 MqResult(등록 결과)가 함께 들어 있다.
        **MqResult.Ok 만 성공이다. MqResult.Skipped(=RstVal 200 + mqSn 0)는 성공이 아니다.**

      .PARAMETER Lang
        수신 csn 언어. 비우면 이 함수가 SK->csn->tCorp.cLang 을 조회해 채운다
        (조회 실패 시 ko). 명시하면 조회를 건너뛰고 그 값을 쓴다.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Current,
        $Previous = $null,
        [double]$ThresholdPercent = -1,
        [string]$Lssn = "",
        [string]$To = "",
        [string]$Type = "slack",
        [string]$Sk = "",
        [string]$Lang = ""
    )

    $threshold = Resolve-AzureCostAlertThreshold -Config $Config -Requested $ThresholdPercent
    $lssnValue = $Lssn
    if (-not $lssnValue) { $lssnValue = [string]$Config.lssn }
    $toValue = $To
    if (-not $toValue) { $toValue = [string]$Config.mqe_to }

    # 수신 csn 의 언어를 결정한다. 명시값 우선, 없으면 SK 로 조회(실패 시 ko).
    $langValue = $Lang
    if (-not $langValue) { $langValue = Resolve-AzureCostRecipientLang -Config $Config -Sk $Sk }

    $report = New-AzureCostDeltaReport -Current $Current -Previous $Previous -ThresholdPercent $threshold -Lssn $lssnValue -Lang $langValue
    $mq = Invoke-GiipMqLogPut -Config $Config -Subject $report.Subject -Body $report.Body -To $toValue -Type $Type -Sk $Sk

    return [pscustomobject]@{
        Report    = $report
        MqResult  = $mq
        Threshold = $threshold
        Lang      = $langValue
    }
}
