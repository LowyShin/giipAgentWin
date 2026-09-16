# ============================================================================
# Mqe.ps1
# Purpose : GIIP MQE(Message Queue Engine) 큐(tMQLog)에 메시지를 등록한다.
# Endpoint: giipApiJson  (giipApiSk2/Sk3 가 아니다 — 아래 "왜 giipApiJson 인가" 참조)
# SP      : pApiMQLogPutbyAk(@ak, @jsondata)
# 정본 문서: giipdb/docs/20_Guides/MQE_MESSAGE_REGISTRATION_GUIDE.md (giip #2604)
#
# --- 왜 giipApiJson 인가 (실측, giip #2604) ---------------------------------
# giipApiSk2/Sk3 는 text 의 파라미터 이름을 SQL 리터럴로 조립하면서
#   $unescaped = $unescaped -replace "\r\n|\r|\n", ' '
# 로 개행을 전부 공백으로 바꾼다(kvsadvrstput 만 예외). 보고서 본문처럼 여러 줄인
# mqBody 가 한 줄로 뭉개지므로 이 경로로 보내면 안 된다.
# giipApiJson 은 jsondata 를 통째로 SP 에 넘기고 SP 가 JSON_VALUE 로 꺼내므로
# JSON 이스케이프(\n)가 그대로 살아 개행이 보존된다. pApiMQLogPutbyAk 의 헤더
# 주석("giipApiJson 연동용, 개행 보존")이 이 의도를 명시하고 있다.
#
# --- 함정 1: 파라미터 이름이 usertoken 이다 ---------------------------------
# giipApiSk2/Sk3 는 form 키가 `token` 이지만 giipApiJson 은 `usertoken` 이다.
# `token` 으로 보내면 HTTP 400 "usertoken is required" 문자열(JSON 아님)이 돌아온다.
#
# --- 함정 2: @ak 는 이름과 달리 SK 다 ---------------------------------------
# pApiMQLogPutbyAk 내부는 `SELECT @cSn = csn FROM tSecretKey WHERE skey = @ak`.
# 즉 cSn 은 파라미터가 아니라 **SK 로 결정된다**. 어느 csn 에 넣을지는 어느 SK 를
# 쓰느냐로만 정해진다.
#
# --- 함정 3: 중복방지 게이트가 스킵을 "성공"으로 돌려준다 -------------------
# 같은 mqSubject + mqTo + cSn 의 **미발송**(mqSentdt IS NULL) 행이 이미 있으면
# SP 는 INSERT 하지 않고 RstVal=200 / mqSn=0 을 돌려준다. 200 만 보고 성공으로
# 처리하면 보고서가 소리 없이 사라진다. → 제목에 날짜를 넣어 회피하고,
# mqSn=0 이면 Skipped 로 판정해 반드시 로그에 남긴다(이 파일의 반환값 Skipped).
# ============================================================================

function Write-MqeLog {
    param([string]$Level, [string]$Message)
    if (Get-Command Write-GiipLog -ErrorAction SilentlyContinue) {
        Write-GiipLog $Level $Message
    } else {
        Write-Host ("[{0}] {1}" -f $Level, $Message)
    }
}

function Get-GiipApiJsonUri {
    <#
      apiaddrv2(= .../api/giipApiSk2 또는 .../api/giipApiSk3) 에서 마지막 경로 세그먼트만
      giipApiJson 으로 바꾼다. cfg 에 apiaddrjson 이 명시돼 있으면 그쪽을 우선한다.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config)

    if ($Config.apiaddrjson) { return [string]$Config.apiaddrjson }
    $base = [string]$Config.apiaddrv2
    if (-not $base) { return $null }
    return ($base -replace '/[^/]+$', '/giipApiJson')
}

function Invoke-GiipMqLogPut {
    <#
      .SYNOPSIS
        tMQLog 에 메시지 1건을 등록한다(pApiMQLogPutbyAk 경유).

      .OUTPUTS
        [pscustomobject] @{
          Ok      = [bool]   RstVal 200 이고 실제 INSERT 된 경우에만 $true
          Skipped = [bool]   중복방지 게이트로 스킵된 경우($true 면 Ok 는 $false)
          RstVal  = [string]
          RstMsg  = [string]
          MqSn    = [long]   실제 INSERT 된 tMQLog.mqSn (스킵/실패면 0)
          Uri     = [string]
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$Body,
        # 비우면 jsondata 에서 mqTo 자체를 뺀다(tMQLog.mqTo=NULL).
        # 그러면 발송기(execmqe)가 pApiMQListbySk 의 tMQENotificationConfig 조인으로
        # csn 의 기본 수신처를 쓴다. 다만 중복방지 게이트의 `mqTo = @mqTo` 비교는
        # NULL 이면 절대 참이 되지 않으므로 게이트가 작동하지 않는다는 점에 주의.
        [string]$To = "",
        [string]$Type = "slack",
        [string]$FromEmail = "",
        [string]$FromName = "",
        # 비우면 $Config.sk 를 쓴다. **이 SK 가 곧 cSn 을 결정한다.**
        [string]$Sk = ""
    )

    $uri = Get-GiipApiJsonUri -Config $Config
    if (-not $uri) {
        Write-MqeLog "ERROR" "MQE: apiaddrv2/apiaddrjson 이 cfg 에 없어 giipApiJson URI 를 만들 수 없다."
        return [pscustomobject]@{ Ok = $false; Skipped = $false; RstVal = "500"; RstMsg = "no api uri"; MqSn = [long]0; Uri = $null }
    }

    $token = if ($Sk) { $Sk } else { [string]$Config.sk }
    if (-not $token) {
        Write-MqeLog "ERROR" "MQE: SK 가 없어 등록할 수 없다(cSn 은 SK 로 결정된다)."
        return [pscustomobject]@{ Ok = $false; Skipped = $false; RstVal = "401"; RstMsg = "no sk"; MqSn = [long]0; Uri = $uri }
    }

    $payload = [ordered]@{
        mqSubject = $Subject
        mqBody    = $Body
        mqType    = $Type
    }
    if ($To)        { $payload["mqTo"] = $To }
    if ($FromEmail) { $payload["mqFromEmail"] = $FromEmail }
    if ($FromName)  { $payload["mqFromName"] = $FromName }

    $jsonData = ($payload | ConvertTo-Json -Compress -Depth 5)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        # giipApiJson 의 본문 파서는 `$pair -split "="` 후 길이 2 인 쌍만 받는다.
        # EscapeDataString 이 값 안의 '=' 와 '&' 를 %3D/%26 로 바꾸므로 안전하다.
        $fields = @(
            "usertoken=$([System.Uri]::EscapeDataString($token))",
            "text=$([System.Uri]::EscapeDataString('MQLogPut'))",
            "jsondata=$([System.Uri]::EscapeDataString($jsonData))"
        )
        $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes(($fields -join '&'))
        $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded; charset=utf-8' }

        $webResponse = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $utf8Bytes -TimeoutSec 60 -UseBasicParsing
        $raw = $webResponse.Content
    } catch {
        Write-MqeLog "ERROR" "MQE: giipApiJson 호출 실패: $($_.Exception.Message)"
        return [pscustomobject]@{ Ok = $false; Skipped = $false; RstVal = "500"; RstMsg = $_.Exception.Message; MqSn = [long]0; Uri = $uri }
    }

    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
    if ($null -eq $parsed) {
        Write-MqeLog "ERROR" "MQE: 응답 JSON 파싱 실패. raw=$raw"
        return [pscustomobject]@{ Ok = $false; Skipped = $false; RstVal = "500"; RstMsg = "unparsable: $raw"; MqSn = [long]0; Uri = $uri }
    }
    # 단건이면 객체, 복수면 배열로 올 수 있다(giipApi 계열 공통).
    if ($parsed -is [System.Array]) { $parsed = @($parsed)[0] }

    $rstVal = [string]$parsed.RstVal
    $rstMsg = [string]$parsed.RstMsg
    $mqSn = [long]0
    if ($null -ne $parsed.mqSn) { [long]::TryParse([string]$parsed.mqSn, [ref]$mqSn) | Out-Null }

    $skipped = ($rstVal -eq "200" -and $mqSn -le 0)
    $ok = ($rstVal -eq "200" -and $mqSn -gt 0)

    if ($ok) {
        Write-MqeLog "INFO" "MQE: tMQLog 등록 성공 mqSn=$mqSn subject='$Subject'"
    } elseif ($skipped) {
        # RstVal 200 이지만 INSERT 되지 않았다. 호출부가 성공으로 오인하지 않도록 WARN.
        Write-MqeLog "WARN" "MQE: 중복방지 게이트로 스킵됨(mqSn=0). 같은 제목/수신처/csn 의 미발송 메시지가 이미 있다. RstMsg='$rstMsg' subject='$Subject'"
    } else {
        Write-MqeLog "ERROR" "MQE: 등록 실패 RstVal=$rstVal RstMsg='$rstMsg' subject='$Subject'"
    }

    return [pscustomobject]@{
        Ok      = $ok
        Skipped = $skipped
        RstVal  = $rstVal
        RstMsg  = $rstMsg
        MqSn    = $mqSn
        Uri     = $uri
    }
}
