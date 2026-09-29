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
# ============================================================================

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
        [int]$TopDown = 3
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("### $Title")

    $changed = @($Rows | Where-Object { [math]::Abs($_.delta) -ge 0.0001 })
    if ($changed.Count -eq 0) {
        $lines.Add("- 항목별 증감 없음(모든 항목의 차이가 0)")
        $lines.Add("")
        return ($lines -join "`n")
    }

    $ups = @($changed | Where-Object { $_.delta -gt 0 } | Sort-Object -Property delta -Descending | Select-Object -First $TopUp)
    $downs = @($changed | Where-Object { $_.delta -lt 0 } | Sort-Object -Property delta | Select-Object -First $TopDown)

    if ($ups.Count -gt 0) {
        $lines.Add("- 증가 상위 $($ups.Count)건")
        foreach ($r in $ups) {
            $pctText = "신규"
            if ($null -ne $r.pct) { $pctText = (Format-AzureCostSigned -Value $r.pct) + "%" }
            $lines.Add(("  - {0}: {1} -> {2} {3} ({4} {3}, {5})" -f `
                $r.name, (Format-AzureCostNumber -Value $r.prev), (Format-AzureCostNumber -Value $r.cur), $Currency, `
                (Format-AzureCostSigned -Value $r.delta), $pctText))
        }
    }
    if ($downs.Count -gt 0) {
        $lines.Add("- 감소 상위 $($downs.Count)건")
        foreach ($r in $downs) {
            $pctText = "직전 0"
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
        [int]$TopN = 5
    )

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
        $reason = "직전 수집 레코드가 없다(최초 실행이거나 KVS 조회 실패). 전날 값이 없으므로 증감을 산출하지 않는다."
    } elseif ($null -eq $prevTotal) {
        $comparable = $false
        $reason = "직전 레코드에 total_pretax_cost 가 없다. 증감을 산출할 수 없다."
    } elseif ([string]$Previous.period -ne [string]$Current.period) {
        $comparable = $false
        $reason = "기간(period)이 서로 달라 비교할 수 없다 — 직전='$([string]$Previous.period)' / 이번='$([string]$Current.period)'. (-Days N 로 Custom 기간을 같은 kFactor 에 덮어썼을 때 발생한다.)"
    } elseif ([string]$Current.period -eq "MonthToDate" -and $null -ne $prevAt -and ($prevAt.Year -ne $curAt.Year -or $prevAt.Month -ne $curAt.Month)) {
        $comparable = $false
        $reason = "월이 바뀌었다(직전 $($prevAt.ToString('yyyy-MM')) / 이번 $($curAt.ToString('yyyy-MM'))). MonthToDate 는 달이 바뀌면 0 에서 다시 누적되므로 전일 대비 증감이 성립하지 않는다."
    }

    $deltaAmount = $null
    $deltaPercent = $null
    $rateUnavailableReason = ""
    if ($comparable) {
        $deltaAmount = $curTotal - [double]$prevTotal
        if ([double]$prevTotal -gt 0) {
            $deltaPercent = ($deltaAmount / [double]$prevTotal) * 100.0
        } else {
            $rateUnavailableReason = "직전 총액이 0 이하라 증가율(%)은 산출할 수 없다. 증감액만 표기한다."
        }
    }

    $isAlert = ($comparable -and $null -ne $deltaPercent -and $deltaPercent -ge $ThresholdPercent)

    # --- 제목 -----------------------------------------------------------------
    # 중복방지 게이트(같은 mqSubject+mqTo+cSn 의 미발송 메시지가 있으면 조용히 스킵)를
    # 피하려면 제목이 매일 달라야 한다 -> 날짜를 반드시 넣는다.
    $lssnText = ""
    if ($Lssn) { $lssnText = " (lssn $Lssn)" }
    if (-not $comparable) {
        $subject = "[GIIP Azure Cost] 일일 증감 보고 (비교 불가) - $dateLabel$lssnText"
    } elseif ($null -eq $deltaPercent) {
        $subject = "[GIIP Azure Cost] 일일 증감 보고 $(Format-AzureCostSigned -Value $deltaAmount) $currency - $dateLabel$lssnText"
    } elseif ($isAlert) {
        $subject = "[GIIP Azure Cost] 급증 경보 $(Format-AzureCostSigned -Value $deltaPercent)% - $dateLabel$lssnText"
    } else {
        $subject = "[GIIP Azure Cost] 일일 증감 보고 $(Format-AzureCostSigned -Value $deltaPercent)% - $dateLabel$lssnText"
    }

    # --- 본문 -----------------------------------------------------------------
    $b = New-Object System.Collections.Generic.List[string]
    if ($isAlert) {
        $b.Add("## Azure Cost 급증 경보 ($dateLabel)")
        $b.Add("")
        $b.Add("증가율이 임계 $(Format-AzureCostNumber -Value $ThresholdPercent)% 이상이다.")
    } else {
        $b.Add("## Azure Cost 일일 증감 보고 ($dateLabel)")
    }
    $b.Add("")
    $b.Add("- 구독: $([string]$Current.subscription_name) ($([string]$Current.subscription_id))")
    $b.Add("- 수집 노드(lssn): $Lssn / KVS 좌표: kType=lssn, kKey=$Lssn, kFactor=azure_cost")
    $b.Add("- 기간(period): $([string]$Current.period)")
    $b.Add("- 이번 수집 시각: $([string]$Current.collected_at)")
    if ($null -ne $Previous) {
        $b.Add("- 직전 수집 시각: $([string]$Previous.collected_at)")
        if ($null -ne $prevAt) {
            $gapHours = ($curAt - $prevAt).TotalHours
            $b.Add("- 직전과의 간격: $(Format-AzureCostNumber -Value $gapHours -Digits 1) 시간")
            if ($gapHours -lt 0) {
                $b.Add("  - 주의: 직전 레코드의 수집 시각이 이번보다 **미래**다. 시계 오차이거나 비교 대상을 잘못 넘긴 경우다 — 증감 방향을 그대로 믿지 말 것.")
            } elseif ($gapHours -gt 36) {
                $b.Add("  - 주의: 24시간을 크게 넘는 간격이다. '전날 대비'가 아니라 그 간격만큼의 누적 차이다(수집 실패일이 끼어 있을 수 있다).")
            }
        }
    } else {
        $b.Add("- 직전 수집 시각: (없음)")
    }
    $b.Add("- 알람 임계: $(Format-AzureCostNumber -Value $ThresholdPercent)% 이상 증가")
    $b.Add("")

    $b.Add("### 총액")
    if ($comparable) {
        $b.Add("- 직전: $(Format-AzureCostNumber -Value $prevTotal) $currency")
        $b.Add("- 이번: $(Format-AzureCostNumber -Value $curTotal) $currency")
        $b.Add("- 증감액: $(Format-AzureCostSigned -Value $deltaAmount) $currency")
        if ($null -ne $deltaPercent) {
            $b.Add("- 증감률: $(Format-AzureCostSigned -Value $deltaPercent)%")
            if ($isAlert) {
                $b.Add("- 판정: **급증 경보** (임계 $(Format-AzureCostNumber -Value $ThresholdPercent)% 이상)")
            } else {
                $b.Add("- 판정: 정상 범위 (임계 $(Format-AzureCostNumber -Value $ThresholdPercent)% 미만)")
            }
        } else {
            $b.Add("- 증감률: 산출 불가 — $rateUnavailableReason")
            $b.Add("- 판정: 임계 판정 불가(증가율을 낼 수 없음)")
        }
    } else {
        $b.Add("- 이번: $(Format-AzureCostNumber -Value $curTotal) $currency")
        $b.Add("- 증감: **비교 불가**")
        $b.Add("- 사유: $reason")
        if ($null -ne $prevTotal) {
            $b.Add("- 참고: 직전 레코드의 총액은 $(Format-AzureCostNumber -Value $prevTotal) $([string]$Previous.currency) 였다(비교 대상이 아니므로 증감으로 계산하지 않는다).")
        }
    }
    $b.Add("")

    if ([string]$Current.period -eq "MonthToDate") {
        if ($comparable) {
            $b.Add("> 참고: period=MonthToDate 이므로 총액은 '그 달 1일부터의 누적'이다. 위 증감액은 사실상 직전 수집 이후의 실사용액이고, 증감률은 누적 대비 비율이라 월초일수록 구조적으로 크게 나온다.")
        } else {
            $b.Add("> 참고: period=MonthToDate 이므로 총액은 '그 달 1일부터의 누적'이다(하루치가 아니다).")
        }
        $b.Add("")
    }

    # 정직성: carry-forward 로 실려온 축이면 증감 0 이 "변화 없음"을 뜻하지 않는다.
    $staleNotes = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Current.by_service_stale_since) {
        $staleNotes.Add("- by_service / total_pretax_cost: 이번 실행에서 Cost Management 429 소진으로 $([string]$Current.by_service_stale_since) 수집분을 그대로 이어받았다(carry-forward). 즉 '이번' 총액은 오늘 실제로 조회한 값이 아니므로, 위 증감은 실제 비용 변화가 아니라 carry-forward 의 결과일 수 있다.")
    }
    if ($null -ne $Current.by_resource_group_stale_since) {
        $staleNotes.Add("- by_resource_group: $([string]$Current.by_resource_group_stale_since) 수집분 carry-forward.")
    }
    if ($null -ne $Current.by_resource_group_service_stale_since) {
        $staleNotes.Add("- by_resource_group_service: $([string]$Current.by_resource_group_service_stale_since) 수집분 carry-forward.")
    }
    if ($true -eq $Current.by_resource_group_collection_failed) {
        $staleNotes.Add("- by_resource_group: 수집 실패로 비어 있다(실제로 0건이라는 뜻이 아니다).")
    }
    if ($true -eq $Current.by_resource_group_service_collection_failed) {
        $staleNotes.Add("- by_resource_group_service: 수집 실패로 비어 있다(실제로 0건이라는 뜻이 아니다).")
    }
    if ($staleNotes.Count -gt 0) {
        $b.Add("### 데이터 신선도 경고")
        foreach ($n in $staleNotes) { $b.Add($n) }
        $b.Add("")
    }

    if ($comparable) {
        $svcRows = Get-AzureCostAxisDelta -CurrentList @($Current.by_service) -PreviousList @($Previous.by_service) -NameProperty "service"
        $b.Add((Format-AzureCostAxisSection -Title "서비스별 증감 (by_service)" -Rows $svcRows -Currency $currency -TopUp $TopN))

        $rgRows = Get-AzureCostAxisDelta -CurrentList @($Current.by_resource_group) -PreviousList @($Previous.by_resource_group) -NameProperty "resource_group"
        $b.Add((Format-AzureCostAxisSection -Title "리소스 그룹별 증감 (by_resource_group)" -Rows $rgRows -Currency $currency -TopUp $TopN))
    } else {
        $b.Add("### 항목별 증감")
        $b.Add("- 비교 대상이 없어 산출하지 않는다.")
        $b.Add("")
        $b.Add("### 이번 수집 상위 항목 (참고)")
        $topSvc = @(@($Current.by_service) | Where-Object { $null -ne $_ } | Sort-Object -Property cost -Descending | Select-Object -First $TopN)
        if ($topSvc.Count -eq 0) {
            $b.Add("- by_service 비어 있음")
        } else {
            foreach ($s in $topSvc) {
                $b.Add("  - $([string]$s.service): $(Format-AzureCostNumber -Value $s.cost) $currency")
            }
        }
        $b.Add("")
    }

    $b.Add("---")
    $b.Add("생성: giipAgentWin / azure-cost 수집기 (giip #2604). 등록 경로: giipApiJson + pApiMQLogPutbyAk.")

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

function Send-AzureCostDeltaReport {
    <#
      .SYNOPSIS
        보고서를 만들어 MQE(tMQLog)에 등록한다. lib/Mqe.ps1 이 먼저 로드돼 있어야 한다.

      .DESCRIPTION
        수집기(azure-cost-put-win.ps1)와 수동 스크립트(azure-cost-report-mqe.ps1)가
        똑같은 판정을 쓰도록 만든 공통 진입점이다.
        반환값에 Report(제목/본문/판정)와 MqResult(등록 결과)가 함께 들어 있다.
        **MqResult.Ok 만 성공이다. MqResult.Skipped(=RstVal 200 + mqSn 0)는 성공이 아니다.**
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
        [string]$Sk = ""
    )

    $threshold = Resolve-AzureCostAlertThreshold -Config $Config -Requested $ThresholdPercent
    $lssnValue = $Lssn
    if (-not $lssnValue) { $lssnValue = [string]$Config.lssn }
    $toValue = $To
    if (-not $toValue) { $toValue = [string]$Config.mqe_to }

    $report = New-AzureCostDeltaReport -Current $Current -Previous $Previous -ThresholdPercent $threshold -Lssn $lssnValue
    $mq = Invoke-GiipMqLogPut -Config $Config -Subject $report.Subject -Body $report.Body -To $toValue -Type $Type -Sk $Sk

    return [pscustomobject]@{
        Report    = $report
        MqResult  = $mq
        Threshold = $threshold
    }
}
