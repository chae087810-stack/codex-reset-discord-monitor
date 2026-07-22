param(
    [switch]$TestTranslation,
    [switch]$TestLatestLog,
    [string]$ForecastFile = "",
    [string]$StateFile = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebhookPath = Join-Path $Root ".webhook"
$StatePath = if ($StateFile) { $StateFile } else { Join-Path $Root "state.json" }
$LogPath = Join-Path $Root "monitor.log"
$ForecastUrl = "https://www.willcodexquotareset.com/api/forecast"
$SiteUrl = "https://www.willcodexquotareset.com/"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Limit-Text {
    param([AllowNull()][string]$Text, [int]$MaxLength)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, [Math]::Max(0, $MaxLength - 3)) + "..."
}

function Write-MonitorLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Convert-ToDateTimeOffset {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [DateTimeOffset]::UtcNow
    }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) {
        $dateValue = [DateTime]$Value
        if ($dateValue.Kind -eq [DateTimeKind]::Unspecified) {
            $dateValue = [DateTime]::SpecifyKind($dateValue, [DateTimeKind]::Utc)
        }
        return [DateTimeOffset]$dateValue
    }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
}

function Convert-ToIsoUtc {
    param([AllowNull()][object]$Value)
    return (Convert-ToDateTimeOffset -Value $Value).ToUniversalTime().ToString("o")
}

function Get-KoreaTimeZone {
    if ($script:KoreaTimeZone) { return $script:KoreaTimeZone }
    foreach ($id in @("Asia/Seoul", "Korea Standard Time")) {
        try {
            $script:KoreaTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById($id)
            return $script:KoreaTimeZone
        } catch { }
    }
    throw "Could not locate the Korea time zone."
}

function Format-KstTime {
    param([AllowNull()][object]$Value)
    $dateValue = Convert-ToDateTimeOffset -Value $Value
    $kst = [TimeZoneInfo]::ConvertTime($dateValue, (Get-KoreaTimeZone))
    return $kst.ToString("yyyy-MM-dd HH:mm:ss 'KST'")
}

function New-DiscordEmbed {
    param(
        [string]$Title,
        [string]$Description,
        [string]$Url = "",
        [int]$Color = 5793266,
        [AllowNull()][object]$EventAt = $null,
        [string]$Footer = "Codex quota watcher",
        [AllowNull()][object[]]$Fields = @()
    )

    $safeTitle = Limit-Text -Text $Title -MaxLength 256
    $safeDescription = Limit-Text -Text $Description -MaxLength 4096
    $safeFooter = Limit-Text -Text $Footer -MaxLength 2048
    $embed = [ordered]@{
        title = $safeTitle
        description = $safeDescription
        color = $Color
        timestamp = Convert-ToIsoUtc -Value $EventAt
        footer = @{ text = $safeFooter }
    }
    if ($Url) { $embed.url = $Url }
    if (@($Fields).Count -gt 0) {
        # Discord limits all textual content in one embed to 6,000 characters.
        $remaining = 5900 - $safeTitle.Length - $safeDescription.Length - $safeFooter.Length
        $safeFields = [System.Collections.Generic.List[object]]::new()
        foreach ($field in @($Fields | Select-Object -First 25)) {
            if ($remaining -le 2) { break }
            $fieldName = Limit-Text -Text ([string]$field.name) -MaxLength ([Math]::Min(256, $remaining - 1))
            $remaining -= $fieldName.Length
            if ($remaining -le 1) { break }
            $fieldValue = Limit-Text -Text ([string]$field.value) -MaxLength ([Math]::Min(1024, $remaining))
            $remaining -= $fieldValue.Length
            $safeFields.Add([ordered]@{ name = $fieldName; value = $fieldValue; inline = [bool]$field.inline })
        }
        if ($safeFields.Count -gt 0) { $embed.fields = @($safeFields) }
    }
    return $embed
}

function Send-DiscordEmbeds {
    param([object[]]$Embeds)

    foreach ($embed in @($Embeds)) {
        $payloadObject = [ordered]@{
            username = "Codex 리셋 알림"
            embeds = @($embed)
        }
        $payload = $payloadObject | ConvertTo-Json -Depth 12 -Compress

        if ($DryRun) {
            Write-Output ("DRYRUN_PAYLOAD {0}" -f $payload)
            continue
        }

        $body = [Text.Encoding]::UTF8.GetBytes($payload)
        $sent = $false
        for ($attempt = 1; $attempt -le 4 -and -not $sent; $attempt++) {
            try {
                Invoke-RestMethod -Uri $script:WebhookUrl -Method Post -ContentType "application/json; charset=utf-8" -Body $body | Out-Null
                $sent = $true
            } catch {
                $statusCode = 0
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
                $retryable = $statusCode -eq 429 -or $statusCode -ge 500 -or $statusCode -eq 0
                if (-not $retryable -or $attempt -eq 4) { throw }

                $delaySeconds = [Math]::Min(8, [Math]::Pow(2, $attempt - 1))
                if ($statusCode -eq 429 -and $_.ErrorDetails.Message) {
                    try {
                        $retryBody = $_.ErrorDetails.Message | ConvertFrom-Json
                        if ($null -ne $retryBody.retry_after) {
                            $delaySeconds = [Math]::Min(10, [Math]::Max(1, [double]$retryBody.retry_after))
                        }
                    } catch { }
                }
                Write-MonitorLog "Discord delivery retry $attempt after HTTP $statusCode; waiting $delaySeconds second(s)."
                Start-Sleep -Milliseconds ([int]($delaySeconds * 1000))
            }
        }
    }
}

function Get-KoreanTranslation {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "(본문 없음)" }
    if ($DryRun) { return "[테스트 번역] $Text" }

    try {
        $response = Invoke-RestMethod `
            -Uri "https://translate.googleapis.com/translate_a/single" `
            -Method Post `
            -ContentType "application/x-www-form-urlencoded; charset=utf-8" `
            -Body @{ client = "gtx"; sl = "auto"; tl = "ko"; dt = "t"; q = $Text }

        $pieces = @()
        foreach ($segment in @($response[0])) {
            if ($null -ne $segment -and $segment.Count -gt 0) {
                $pieces += [string]$segment[0]
            }
        }
        $translated = ($pieces -join "").Trim()
        if ($translated) { return $translated }
    } catch {
        Write-MonitorLog ("Translation failed: {0}" -f $_.Exception.Message)
    }

    return "⚠️ 자동 번역을 가져오지 못했습니다. 원문과 링크는 정상입니다."
}

function Format-BilingualPost {
    param([string]$Original, [string]$Korean)
    $originalSection = Limit-Text -Text $Original -MaxLength 1350
    $koreanSection = Limit-Text -Text $Korean -MaxLength 1350
    return "🇺🇸 **Tibo 원문**`n$originalSection`n`n🇰🇷 **한글 번역**`n$koreanSection"
}

function Get-TweetGuidFromUrl {
    param([AllowNull()][string]$Url)
    if ($Url -match '/status/(\d+)') { return [string]$Matches[1] }
    return ""
}

function Get-HistoryId {
    param([object]$Entry)
    return "hist:v2:{0}:{1}:{2}" -f (Convert-ToIsoUtc -Value $Entry.at), [int]$Entry.fromScore, [int]$Entry.toScore
}

function Get-HistoryFingerprint {
    param([object]$Entry)

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("$(Convert-ToIsoUtc -Value $Entry.at)|$([int]$Entry.fromScore)|$([int]$Entry.scoreDelta)|$([int]$Entry.toScore)")
    foreach ($change in @($Entry.changes | Sort-Object { "{0}|{1}|{2}|{3}" -f [string]$_.label, [int]$_.from, [int]$_.delta, [int]$_.to })) {
        $parts.Add("change|$([string]$change.label)|$([int]$change.from)|$([int]$change.delta)|$([int]$change.to)")
        foreach ($detail in @($change.details | Sort-Object { "{0}|{1}|{2}|{3}" -f [string]$_.kind, [string]$_.action, [string]$_.name, [string]$_.url })) {
            $parts.Add("detail|$([string]$detail.kind)|$([string]$detail.action)|$([string]$detail.name)|$([string]$detail.url)")
        }
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($parts -join "`n")
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

function Get-TweetId {
    param([AllowNull()][object]$Post, [AllowNull()][string]$FallbackUrl = "")
    $guid = if ($null -ne $Post) { [string]$Post.guid } else { "" }
    if (-not $guid) { $guid = Get-TweetGuidFromUrl -Url $FallbackUrl }
    if ($guid) { return "tweet:v2:$guid" }
    if ($FallbackUrl) { return "tweet:v2:$FallbackUrl" }
    return ""
}

function Resolve-TiboPost {
    param([AllowNull()][string]$Url, [AllowNull()][string]$Guid = "")
    if ($Guid -and $script:PostByGuid.ContainsKey($Guid)) { return $script:PostByGuid[$Guid] }
    if ($Url -and $script:PostByUrl.ContainsKey($Url)) { return $script:PostByUrl[$Url] }
    $urlGuid = Get-TweetGuidFromUrl -Url $Url
    if ($urlGuid -and $script:PostByGuid.ContainsKey($urlGuid)) { return $script:PostByGuid[$urlGuid] }
    return $null
}

function Test-IsPostClassificationConflict {
    param([AllowNull()][object]$Post, [AllowNull()][object[]]$HistoryEntries = @())
    if ($null -eq $Post) { return $false }
    if ([string]$Post.tweetAssessment.category -ne "reset_completed") { return $false }
    $strength = [int]$Post.tweetAssessment.resetSignalStrength
    $reason = [string]$Post.tweetAssessment.reason
    return ($strength -le 0 -or $reason -match '(?i)\bno\b.{0,80}\b(?:reset|limits?)\b.{0,40}\b(?:mention|signal|relevance)|\bunrelated\b|\bnot\b.{0,40}\b(?:reset|limits?)\b|무관|리셋.{0,20}아님')
}

function Get-TiboTitle {
    param(
        [AllowNull()][object]$Post,
        [string]$DefaultTitle = "🔎 사이트 로그의 Tibo 근거",
        [switch]$ClassificationConflict
    )
    $category = if ($null -ne $Post) { [string]$Post.tweetAssessment.category } else { "" }
    $postText = if ($null -ne $Post) { [string]$Post.title } else { "" }
    if ($ClassificationConflict) { return "⚠️ 사이트가 모순되게 분류한 Tibo 메시지" }
    if ($category -eq "reset_completed") { return "🔄 Tibo의 Codex 사용량 리셋 완료 게시" }
    if ($postText -match '(?is)\bbanked\s+reset\b|\bapply\s+(?:the|your)\s+reset\b|\breplenish\b.{0,100}\bweekly\s+usage\b|\breset\s+coupon\b') {
        return "🎟️ Tibo의 리셋 쿠폰 게시"
    }
    switch ($category) {
        "reset_announced" { return "📣 사이트가 ‘리셋 예정’으로 분류한 Tibo 메시지" }
        "reset_proposal" { return "⏳ 사이트가 ‘리셋 제안’으로 분류한 Tibo 메시지" }
        "banked_reset" { return "🎟️ Tibo의 리셋 쿠폰 게시" }
        "reset_coupon" { return "🎟️ Tibo의 리셋 쿠폰 게시" }
        default { return $DefaultTitle }
    }
}

function Send-TiboNotification {
    param(
        [AllowNull()][object]$Post,
        [string]$FallbackOriginal = "",
        [string]$FallbackUrl = "",
        [AllowNull()][object]$FallbackAt = $null,
        [string]$SourceLabel = "사이트가 근거로 채택한 메시지",
        [string]$HistoryReason = "",
        [switch]$ClassificationConflict,
        [switch]$IsTest
    )

    $original = if ($null -ne $Post -and [string]$Post.title) { [string]$Post.title } else { $FallbackOriginal }
    $url = if ($null -ne $Post -and [string]$Post.link) { [string]$Post.link } else { $FallbackUrl }
    $eventAt = if ($null -ne $Post -and $null -ne $Post.pubDate) { $Post.pubDate } else { $FallbackAt }
    $translation = Get-KoreanTranslation -Text $original
    $description = Format-BilingualPost -Original $original -Korean $translation
    $fields = [System.Collections.Generic.List[object]]::new()
    $category = if ($null -ne $Post) { [string]$Post.tweetAssessment.category } else { "site_history_source" }
    $reason = if ($null -ne $Post) { [string]$Post.tweetAssessment.reason } else { "" }

    # Safety fields come first so Discord's aggregate length limit can never
    # hide the contradiction/applicability warning behind long post context.
    if ($ClassificationConflict) {
        $fields.Add([ordered]@{
            name = "⚠️ 사이트 내부 판정 모순"
            value = "Recent Movement는 이 글을 리셋 근거로 기록했지만, 현재 트윗 판정은 신호 강도 0 또는 ‘무관함’으로 설명합니다. **리셋으로 해석하지 마세요.**"
            inline = $false
        })
    }

    if ($null -ne $Post -and -not [string]::IsNullOrWhiteSpace([string]$Post.context)) {
        $fields.Add([ordered]@{
            name = "답글 대상 문맥"
            value = Limit-Text -Text ([string]$Post.context) -MaxLength 1024
            inline = $false
        })
    }

    $classification = "분류: ``$category``"
    if ($null -ne $Post -and $null -ne $Post.tweetAssessment.resetSignalStrength) {
        $classification += "`n신호 강도: **$([int]$Post.tweetAssessment.resetSignalStrength)** (확률 아님)"
    }
    if ($reason) { $classification += "`n$reason" }
    $fields.Add([ordered]@{
        name = "사이트 모델 판정"
        value = Limit-Text -Text $classification -MaxLength 1024
        inline = $false
    })

    if ($HistoryReason) {
        $fields.Add([ordered]@{
            name = "Recent Movement의 설명"
            value = Limit-Text -Text $HistoryReason -MaxLength 1024
            inline = $false
        })
    }

    if ($category -eq "reset_completed") {
        $fields.Add([ordered]@{
            name = "⚠️ 적용 여부"
            value = "사이트가 이 게시물을 완료 신호로 분류한 것입니다. **글 내용이나 이 계정의 5시간·주간 한도 적용을 봇이 직접 확인한 것은 아닙니다.**"
            inline = $false
        })
    } elseif ($category -eq "reset_announced") {
        $fields.Add([ordered]@{
            name = "상태"
            value = "리셋 예정 발표입니다. 아직 완료 신호가 아닙니다."
            inline = $false
        })
    }

    $title = Get-TiboTitle -Post $Post -ClassificationConflict:$ClassificationConflict
    if ($IsTest) { $title = "🧪 형식 확인 · $title" }
    $footer = "Tibo @thsottiaux · $SourceLabel · 게시 $(Format-KstTime -Value $eventAt) · 사이트 스냅샷 $(Format-KstTime -Value $script:ForecastFetchedAt)"
    $embed = New-DiscordEmbed `
        -Title $title `
        -Description $description `
        -Url $url `
        -Color 10181046 `
        -EventAt $eventAt `
        -Footer $footer `
        -Fields @($fields)
    Send-DiscordEmbeds -Embeds @($embed)
}

function Format-HistoryDetail {
    param([object]$Detail)
    $action = [string]$Detail.action
    $name = [string]$Detail.name
    $url = [string]$Detail.url
    $line = if ($action) { "**$action**: $name" } else { $name }
    if ($url) { $line += "`n$url" }
    return $line
}

function Send-HistoryNotification {
    param(
        [object]$Entry,
        [hashtable]$NotifiedSignals,
        [switch]$IsRevision,
        [switch]$IsTest,
        [scriptblock]$AfterHistorySent = $null,
        [scriptblock]$AfterSignalSent = $null
    )

    $fromScore = [int]$Entry.fromScore
    $toScore = [int]$Entry.toScore
    $scoreDelta = [int]$Entry.scoreDelta
    $deltaText = if ($scoreDelta -gt 0) { "+$scoreDelta" } else { [string]$scoreDelta }
    $labels = @($Entry.changes | ForEach-Object { [string]$_.label })
    $crossed70 = $fromScore -lt 70 -and $toScore -ge 70
    $confirmedReset = $labels -contains "confirmed reset"
    $announcedReset = $labels -contains "public reset announcement"
    $classificationConflict = $false
    if ($confirmedReset) {
        foreach ($detail in @($Entry.changes.details | Where-Object { [string]$_.kind -eq "tweet" })) {
            $conflictPost = Resolve-TiboPost -Url ([string]$detail.url)
            if ($null -ne $conflictPost) {
                $conflictStrength = [int]$conflictPost.tweetAssessment.resetSignalStrength
                $conflictReason = [string]$conflictPost.tweetAssessment.reason
                if ($conflictStrength -le 0 -or $conflictReason -match '(?i)no .*(?:reset|limits?)|unrelated|무관') {
                    $classificationConflict = $true
                }
            }
        }
    }

    if ($classificationConflict) {
        $title = "⚠️ 사이트 판정 모순 · Recent Movement"
        $color = 15105570
    } elseif ($crossed70) {
        $title = "🚨 70% 돌파 · 사이트 Recent Movement"
        $color = 16753920
    } elseif ($confirmedReset) {
        $title = "📉 사이트 로그 · confirmed reset"
        $color = 15158332
    } elseif ($announcedReset) {
        $title = "📣 사이트 로그 · public reset announcement"
        $color = 16753920
    } elseif ($scoreDelta -gt 0) {
        $title = "📈 사이트 Recent Movement"
        $color = 5763719
    } elseif ($scoreDelta -lt 0) {
        $title = "📉 사이트 Recent Movement"
        $color = 15105570
    } else {
        $title = "➖ 사이트 Recent Movement"
        $color = 9807270
    }
    if ($IsRevision) { $title = "📝 사이트 로그 수정 · $title" }
    if ($IsTest) { $title = "🧪 형식 확인 · $title" }

    $description = "**${fromScore}% → ${toScore}%** (**${deltaText} pts**)`n이벤트·게시 시각: **$(Format-KstTime -Value $Entry.at)**`n현재 API 스냅샷: **$(Format-KstTime -Value $script:ForecastFetchedAt)**`n봇 감지 시각: **$(Format-KstTime -Value ([DateTimeOffset]::UtcNow))**"
    if ($IsRevision) {
        $description += "`n`n📝 같은 이벤트 시각·점수의 사이트 로그 내용이 수정되어 다시 표시합니다."
    }
    if ($classificationConflict) {
        $description += "`n`n⚠️ 사이트 로그는 ``confirmed reset``이라고 쓰지만 현재 트윗 판정은 이를 부정합니다. **리셋 완료로 해석하지 마세요.**"
    } elseif ($confirmedReset) {
        $description += "`n`n⚠️ 사이트가 ``confirmed reset``으로 기록한 공개 신호이며 **글 내용이나 이 계정의 실제 한도 적용을 봇이 검증한 것이 아닙니다.**"
    } elseif ($announcedReset) {
        $description += "`n`n📣 리셋 예정 발표 신호이며 아직 완료 확인이 아닙니다."
    }

    $fields = [System.Collections.Generic.List[object]]::new()
    foreach ($change in @($Entry.changes)) {
        $changeDelta = [int]$change.delta
        $changeDeltaText = if ($changeDelta -gt 0) { "+$changeDelta" } else { [string]$changeDelta }
        $detailLines = [System.Collections.Generic.List[string]]::new()
        $detailLines.Add("기여도: $([int]$change.from) → $([int]$change.to)")
        foreach ($detail in @($change.details)) {
            $detailLines.Add((Format-HistoryDetail -Detail $detail))
        }
        if (@($change.details).Count -eq 0) { $detailLines.Add("세부 설명 없음") }
        $fields.Add([ordered]@{
            name = Limit-Text -Text ("$changeDeltaText pts · $([string]$change.label)") -MaxLength 256
            value = Limit-Text -Text ($detailLines -join "`n`n") -MaxLength 1024
            inline = $false
        })
    }

    $footer = "willcodexquotareset.com · 이벤트/게시 · 사이트 스냅샷 · 봇 감지 시각을 본문에 각각 표시"
    $fieldChunks = [System.Collections.Generic.List[object]]::new()
    $currentChunk = [System.Collections.Generic.List[object]]::new()
    $currentSize = 0
    foreach ($field in @($fields)) {
        $fieldSize = ([string]$field.name).Length + ([string]$field.value).Length
        if ($currentChunk.Count -gt 0 -and ($currentChunk.Count -ge 20 -or $currentSize + $fieldSize -gt 4200)) {
            $fieldChunks.Add([object]$currentChunk.ToArray())
            $currentChunk = [System.Collections.Generic.List[object]]::new()
            $currentSize = 0
        }
        $currentChunk.Add($field)
        $currentSize += $fieldSize
    }
    if ($currentChunk.Count -gt 0) { $fieldChunks.Add([object]$currentChunk.ToArray()) }
    if ($fieldChunks.Count -eq 0) { $fieldChunks.Add([object]@()) }

    for ($chunkIndex = 0; $chunkIndex -lt $fieldChunks.Count; $chunkIndex++) {
        $chunkTitle = $title
        $chunkDescription = $description
        if ($fieldChunks.Count -gt 1) {
            $chunkTitle = "$title ($($chunkIndex + 1)/$($fieldChunks.Count))"
            if ($chunkIndex -gt 0) { $chunkDescription = "같은 사이트 Recent Movement 기록의 계속입니다." }
        }
        $embed = New-DiscordEmbed `
            -Title $chunkTitle `
            -Description $chunkDescription `
            -Url $SiteUrl `
            -Color $color `
            -EventAt $Entry.at `
            -Footer $footer `
            -Fields ([object[]]$fieldChunks[$chunkIndex])
        Send-DiscordEmbeds -Embeds @($embed)
    }
    if ($null -ne $AfterHistorySent) { & $AfterHistorySent }

    foreach ($change in @($Entry.changes)) {
        $historyReason = @($change.details | Where-Object { [string]$_.action -eq "Why it counted" } | ForEach-Object { [string]$_.name }) -join " "
        foreach ($detail in @($change.details | Where-Object { [string]$_.kind -eq "tweet" })) {
            $post = Resolve-TiboPost -Url ([string]$detail.url)
            $signalId = Get-TweetId -Post $post -FallbackUrl ([string]$detail.url)
            if ($signalId -and -not $NotifiedSignals.ContainsKey($signalId)) {
                Send-TiboNotification `
                    -Post $post `
                    -FallbackOriginal ([string]$detail.name) `
                    -FallbackUrl ([string]$detail.url) `
                    -FallbackAt $Entry.at `
                    -SourceLabel "Recent Movement 근거" `
                    -HistoryReason $historyReason `
                    -ClassificationConflict:$classificationConflict `
                    -IsTest:$IsTest
                $NotifiedSignals[$signalId] = $true
                if ($null -ne $AfterSignalSent) { & $AfterSignalSent $signalId }
                Write-MonitorLog "Sent Tibo source $signalId for history $(Get-HistoryId -Entry $Entry)."
            }
        }
    }
}

function Get-CompletedResetPosts {
    param([object]$Forecast)

    $selected = @{}
    foreach ($post in @($Forecast.tiboPosts)) {
        if ([string]$post.tweetAssessment.category -eq "reset_completed") {
            $postId = Get-TweetId -Post $post
            if ($postId) { $selected[$postId] = $post }
        }
    }
    return @($selected.Values | Sort-Object { Convert-ToDateTimeOffset -Value $_.pubDate })
}

function Save-State {
    param([object]$State)
    $parent = Split-Path -Parent $StatePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Save-WorkingState {
    param(
        [hashtable]$SeenCompletedPosts,
        [string]$InitializedAt,
        [int]$Score,
        [AllowNull()][object]$FetchedAt
    )

    $workingState = [ordered]@{
        schemaVersion = 3
        seenCompletedResetPostIds = @($SeenCompletedPosts.Keys | Sort-Object -Descending | Select-Object -First 500)
        lastScore = $Score
        initializedAt = $InitializedAt
        lastCheckedAt = [DateTimeOffset]::UtcNow.ToString("o")
        siteFetchedAt = Convert-ToIsoUtc -Value $FetchedAt
    }
    Save-State -State $workingState
}

$script:WebhookUrl = [Environment]::GetEnvironmentVariable("DISCORD_WEBHOOK_URL")
if (-not $DryRun -and [string]::IsNullOrWhiteSpace($script:WebhookUrl) -and (Test-Path -LiteralPath $WebhookPath)) {
    $script:WebhookUrl = (Get-Content -LiteralPath $WebhookPath -Raw).Trim()
}
if (-not $DryRun -and [string]::IsNullOrWhiteSpace($script:WebhookUrl)) {
    throw "Set the DISCORD_WEBHOOK_URL secret or provide the local .webhook file."
}
if (-not $DryRun -and $script:WebhookUrl -notmatch '^https://discord(?:app)?\.com/api/webhooks/') {
    throw "The configured Discord webhook URL is invalid."
}

if ($ForecastFile) {
    $forecast = Get-Content -LiteralPath $ForecastFile -Raw | ConvertFrom-Json
} else {
    $forecast = Invoke-RestMethod -Uri $ForecastUrl -Headers @{ Accept = "application/json" }
}
$script:ForecastFetchedAt = $forecast.fetchedAt

$script:PostByGuid = @{}
$script:PostByUrl = @{}
foreach ($post in @($forecast.tiboPosts)) {
    if ([string]$post.guid) { $script:PostByGuid[[string]$post.guid] = $post }
    if ([string]$post.link) { $script:PostByUrl[[string]$post.link] = $post }
}

$historyEntries = @($forecast.history | Sort-Object { Convert-ToDateTimeOffset -Value $_.at } | Select-Object -Last 500)
$completedResetPosts = @(Get-CompletedResetPosts -Forecast $forecast | Select-Object -Last 500)
$currentCompletedResetIds = @($completedResetPosts | ForEach-Object { Get-TweetId -Post $_ } | Where-Object { $_ })

if ($TestTranslation) {
    $latestPost = @($completedResetPosts | Where-Object { -not (Test-IsPostClassificationConflict -Post $_) } | Sort-Object { Convert-ToDateTimeOffset -Value $_.pubDate } -Descending | Select-Object -First 1)[0]
    if ($null -eq $latestPost) { throw "No valid Tibo reset-completed post is available for the translation test." }
    Send-TiboNotification -Post $latestPost -SourceLabel "리셋 완료 번역 시험" -IsTest
    Write-MonitorLog ("Sent translation test for post {0}." -f [string]$latestPost.guid)
    exit 0
}

if ($TestLatestLog) {
    $latestPost = @($completedResetPosts | Where-Object { -not (Test-IsPostClassificationConflict -Post $_) } | Sort-Object { Convert-ToDateTimeOffset -Value $_.pubDate } -Descending | Select-Object -First 1)[0]
    if ($null -eq $latestPost) { throw "No valid Tibo reset-completed post is available for the format test." }
    Send-TiboNotification -Post $latestPost -SourceLabel "리셋 완료 알림 시험" -IsTest
    Write-MonitorLog ("Sent reset-completed format test for {0}." -f (Get-TweetId -Post $latestPost))
    exit 0
}

$state = $null
if (Test-Path -LiteralPath $StatePath) {
    try { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { $state = $null }
}

$stateVersion = if ($null -ne $state -and $state.PSObject.Properties.Name -contains "schemaVersion") { [int]$state.schemaVersion } else { 0 }
if ($stateVersion -lt 3) {
    $initializedAt = if ($null -ne $state -and $state.PSObject.Properties.Name -contains "initializedAt") {
        [string]$state.initializedAt
    } else {
        [DateTimeOffset]::UtcNow.ToString("o")
    }
    $newState = [ordered]@{
        schemaVersion = 3
        seenCompletedResetPostIds = @($currentCompletedResetIds | Select-Object -Last 500)
        lastScore = [int]$forecast.forecast.score
        initializedAt = $initializedAt
        lastCheckedAt = [DateTimeOffset]::UtcNow.ToString("o")
        siteFetchedAt = Convert-ToIsoUtc -Value $forecast.fetchedAt
    }

    Write-MonitorLog "Initialized v3 reset-completed-only state without replaying old posts."

    Save-State -State $newState
    exit 0
}

$seenCompletedPosts = @{}
@($state.seenCompletedResetPostIds) | ForEach-Object { $seenCompletedPosts[[string]$_] = $true }

foreach ($post in $completedResetPosts) {
    $postId = Get-TweetId -Post $post
    if (-not $postId -or $seenCompletedPosts.ContainsKey($postId)) { continue }

    if (Test-IsPostClassificationConflict -Post $post) {
        $seenCompletedPosts[$postId] = $true
        Save-WorkingState -SeenCompletedPosts $seenCompletedPosts -InitializedAt ([string]$state.initializedAt) -Score ([int]$forecast.forecast.score) -FetchedAt $forecast.fetchedAt
        Write-MonitorLog "Suppressed contradictory reset-completed classification $postId."
        continue
    }

    Send-TiboNotification -Post $post -SourceLabel "Tibo 리셋 완료 게시"
    $seenCompletedPosts[$postId] = $true
    Save-WorkingState -SeenCompletedPosts $seenCompletedPosts -InitializedAt ([string]$state.initializedAt) -Score ([int]$forecast.forecast.score) -FetchedAt $forecast.fetchedAt
    Write-MonitorLog "Sent Tibo reset-completed post $postId."
}

Save-WorkingState -SeenCompletedPosts $seenCompletedPosts -InitializedAt ([string]$state.initializedAt) -Score ([int]$forecast.forecast.score) -FetchedAt $forecast.fetchedAt
Write-MonitorLog "Check completed; forecast, movement, proposal, announcement, and coupon alerts are disabled."
