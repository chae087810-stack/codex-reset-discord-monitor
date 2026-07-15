param([switch]$TestTranslation)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebhookPath = Join-Path $Root ".webhook"
$StatePath = Join-Path $Root "state.json"
$LogPath = Join-Path $Root "monitor.log"
$ForecastUrl = "https://www.willcodexquotareset.com/api/forecast"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-MonitorLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Send-DiscordEmbed {
    param(
        [string]$Title,
        [string]$Description,
        [string]$Url = "",
        [int]$Color = 5793266,
        [string]$Footer = "Codex quota watcher"
    )

    $embed = [ordered]@{
        title = $Title
        description = if ($Description.Length -gt 4000) { $Description.Substring(0, 3997) + "..." } else { $Description }
        color = $Color
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        footer = @{ text = $Footer }
    }
    if ($Url) { $embed.url = $Url }

    $payload = [ordered]@{
        username = "Codex 리셋 알림"
        embeds = @($embed)
    } | ConvertTo-Json -Depth 8 -Compress

    $body = [Text.Encoding]::UTF8.GetBytes($payload)
    Invoke-RestMethod -Uri $script:WebhookUrl -Method Post -ContentType "application/json; charset=utf-8" -Body $body | Out-Null
}

function Get-KoreanTranslation {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "(본문 없음)" }

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

    return "⚠️ 자동 번역을 가져오지 못했습니다. 원문 알림은 정상적으로 전송됐습니다."
}

function Limit-PostSection {
    param([string]$Text, [int]$MaxLength = 1800)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "(본문 없음)" }
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, $MaxLength - 3) + "..."
}

function Format-BilingualPost {
    param([string]$Original, [string]$Korean)
    $originalSection = Limit-PostSection -Text $Original
    $koreanSection = Limit-PostSection -Text $Korean
    return "🇺🇸 **원문**`n$originalSection`n`n🇰🇷 **한글 번역**`n$koreanSection"
}

function Get-PostKind {
    param([string]$Text)
    if ($Text -match '(?i)banked reset|apply the reset|replenish the weekly usage') {
        return @{ Title = "🎟️ Codex 리셋 쿠폰 지급"; Color = 16753920 }
    }
    if ($Text -match "(?is)\b(?:will|we['’]ll|going to|plan(?:ning)? to|about to|scheduled to|expect(?:ed)? to)\b.{0,100}\b(?:reset|refill)\b|\b(?:reset|refill)\b.{0,80}\b(?:soon|later|tomorrow)\b") {
        return @{ Title = "⏳ Tibo의 Codex 리셋 예고"; Color = 16753920 }
    }
    return @{ Title = "🔮 Codex 리셋 확률 상승 떡밥"; Color = 10181046 }
}

function Test-IsResetRelatedPost {
    param([object]$Post, [hashtable]$SiteSignalTweetUrls)

    $text = [string]$Post.title
    $url = [string]$Post.link

    # Prefer Tibo tweets that the forecast site recorded as a positive signal.
    # Confirmed/completed resets reduce the forecast and are excluded here.
    if ($url -and $SiteSignalTweetUrls.ContainsKey($url)) { return $true }

    # The site currently treats banked-reset coupons as event hints, so retain
    # a narrow text check for those without accepting general Tibo chatter.
    if ($text -match '(?is)\bbanked\s+reset\b|\bapply\s+(?:the|your)\s+reset\b|\breplenish\b.{0,100}\bweekly\s+usage\b|\breset\s+coupon\b') {
        return $true
    }

    # Mirror both of the site's rules as a fallback: the post must mention a
    # quota/limit reset and explicitly put that reset in the future.
    $mentionsQuotaReset = $text -match '(?is)\b(?:reset|resetting|refill)\b.{0,180}\b(?:usage|limits?|quotas?|tokens?)\b|\b(?:usage|limits?|quotas?|tokens?)\b.{0,180}\b(?:reset|resetting|refill)\b'
    $promisesFutureReset = $text -match "(?is)\b(?:will|we['’]ll|going to|plan(?:ning)? to|about to|scheduled to|expect(?:ed)? to)\s+(?:be\s+)?(?:reset|resetting|refill)\b|\bgive\s+(?:us|me)\s+(?:up to\s+)?(?:\d+\s*)?(?:minutes?|hours?|days?)\s+to\s+(?:reset|refill)\b|\b(?:reset|refill)\b.{0,80}\b(?:soon|later|tomorrow|within\s+\d+|in\s+\d+\s+(?:minutes?|hours?|days?))\b"
    return $mentionsQuotaReset -and $promisesFutureReset
}

$script:WebhookUrl = [Environment]::GetEnvironmentVariable("DISCORD_WEBHOOK_URL")
if ([string]::IsNullOrWhiteSpace($script:WebhookUrl) -and (Test-Path -LiteralPath $WebhookPath)) {
    $script:WebhookUrl = (Get-Content -LiteralPath $WebhookPath -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($script:WebhookUrl)) {
    throw "Set the DISCORD_WEBHOOK_URL secret or provide the local .webhook file."
}
if ($script:WebhookUrl -notmatch '^https://discord(?:app)?\.com/api/webhooks/') {
    throw "The configured Discord webhook URL is invalid."
}

$forecast = Invoke-RestMethod -Uri $ForecastUrl -Headers @{ Accept = "application/json" }
$posts = @($forecast.tiboPosts | Sort-Object { [datetime]$_.pubDate })
$currentIds = @($posts | ForEach-Object { [string]$_.guid })
$siteSignalTweetUrls = @{}
$positiveTiboSignalLabels = @(
    "public reset announcement",
    "OpenAI team vagueposting",
    "product-release hint",
    "imminent GPT-5.6 release",
    "OpenAI event hint"
)
foreach ($historyEntry in @($forecast.history)) {
    foreach ($change in @($historyEntry.changes)) {
        if ([int]$change.delta -gt 0 -and [string]$change.label -in $positiveTiboSignalLabels) {
            foreach ($detail in @($change.details)) {
                if ([string]$detail.kind -eq "tweet" -and [string]$detail.url) {
                    $siteSignalTweetUrls[[string]$detail.url] = $true
                }
            }
        }
    }
}
$resetPosts = @($posts | Where-Object { Test-IsResetRelatedPost -Post $_ -SiteSignalTweetUrls $siteSignalTweetUrls })

if ($TestTranslation) {
    if (-not $resetPosts.Count) { throw "No reset-related Tibo posts are available for the translation test." }
    $latestPost = $resetPosts[-1]
    $latestText = [string]$latestPost.title
    $translation = Get-KoreanTranslation -Text $latestText
    $testKind = Get-PostKind -Text $latestText
    $bilingual = Format-BilingualPost -Original $latestText -Korean $translation
    Send-DiscordEmbed `
        -Title ("🧪 번역 적용 확인 · {0}" -f $testKind.Title) `
        -Description $bilingual `
        -Url ([string]$latestPost.link) `
        -Color $testKind.Color `
        -Footer "Tibo @thsottiaux"
    Write-MonitorLog ("Sent translation test for post {0}." -f [string]$latestPost.guid)
    exit 0
}

$state = $null
if (Test-Path -LiteralPath $StatePath) {
    try { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { $state = $null }
}

if (-not $state) {
    $state = [ordered]@{
        seenPostIds = $currentIds
        latestResetAt = [string]$forecast.forecast.latestResetAt
        highForecastAlerted = ([int]$forecast.forecast.score -ge 70)
        initializedAt = (Get-Date).ToUniversalTime().ToString("o")
    }

    Send-DiscordEmbed `
        -Title "✅ Codex 리셋 감지 시작" `
        -Description ("Tibo의 향후 리셋 예고, 리셋 쿠폰, 실제 할당량 리셋을 감시합니다.`n현재 예측: **{0}%**`n마지막 확인: {1}" -f [int]$forecast.forecast.score, [string]$forecast.fetchedAt) `
        -Url "https://www.willcodexquotareset.com/" `
        -Color 5763719
    Write-MonitorLog "Initialized monitor state and sent startup notification."
} else {
    $seen = @{}
    @($state.seenPostIds) | ForEach-Object { $seen[[string]$_] = $true }
    $newPosts = @($resetPosts | Where-Object { -not $seen.ContainsKey([string]$_.guid) })

    foreach ($post in $newPosts) {
        $text = [string]$post.title
        $kind = Get-PostKind -Text $text
        $translation = Get-KoreanTranslation -Text $text
        $bilingual = Format-BilingualPost -Original $text -Korean $translation
        Send-DiscordEmbed -Title $kind.Title -Description $bilingual -Url ([string]$post.link) -Color $kind.Color -Footer "Tibo @thsottiaux"
        Write-MonitorLog ("Sent post {0} ({1})." -f [string]$post.guid, $kind.Title)
    }

    $newResetAt = [string]$forecast.forecast.latestResetAt
    if ($newResetAt -and $newResetAt -ne [string]$state.latestResetAt) {
        Send-DiscordEmbed `
            -Title "🔄 Codex 리셋 상태 확인" `
            -Description ("공개 상태 데이터에서 새로운 할당량 리셋을 확인했습니다.`n리셋 시각: **{0}**" -f $newResetAt) `
            -Url "https://www.willcodexquotareset.com/" `
            -Color 15158332
        Write-MonitorLog "Sent reset-state notification for $newResetAt."
    }

    $score = [int]$forecast.forecast.score
    $wasHigh = [bool]$state.highForecastAlerted
    if ($score -ge 70 -and -not $wasHigh) {
        Send-DiscordEmbed `
            -Title "⚠️ Codex 리셋 가능성 상승" `
            -Description ("향후 48시간 리셋 예측이 **{0}%**까지 상승했습니다." -f $score) `
            -Url "https://www.willcodexquotareset.com/" `
            -Color 16753920
        Write-MonitorLog "Sent high-forecast notification at $score percent."
    }

    $state = [ordered]@{
        seenPostIds = @($currentIds | Select-Object -First 200)
        latestResetAt = $newResetAt
        highForecastAlerted = ($score -ge 70)
        initializedAt = [string]$state.initializedAt
        lastCheckedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
}

$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
Write-MonitorLog "Check completed."
