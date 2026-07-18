$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Monitor = Join-Path $RepoRoot "monitor.ps1"
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-monitor-tests-" + [guid]::NewGuid().ToString("N"))
$Fixture = Join-Path $TempRoot "forecast.json"
$State = Join-Path $TempRoot "state.json"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Save-Fixture {
    param([object]$Value)
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Fixture -Encoding UTF8
}

function Invoke-DryRun {
    $output = & $Monitor -DryRun -ForecastFile $Fixture -StateFile $State *>&1 | Out-String
    if (-not $?) { throw "Monitor dry run failed: $output" }
    return $output
}

function Get-Payloads {
    param([string]$Output)
    $payloads = @()
    foreach ($line in @($Output -split "`r?`n")) {
        if ($line.StartsWith("DRYRUN_PAYLOAD ")) {
            $payloads += $line.Substring("DRYRUN_PAYLOAD ".Length) | ConvertFrom-Json
        }
    }
    return @($payloads)
}

try {
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

    $baseHistory = [ordered]@{
        at = "2026-07-18T23:45:00.000Z"
        fromScore = 60
        scoreDelta = 0
        toScore = 60
        changes = @([ordered]@{ label = "baseline"; from = 12; delta = 0; to = 12 })
    }
    $base = [ordered]@{
        fetchedAt = "2026-07-18T23:50:00.000Z"
        forecast = [ordered]@{
            score = 60
            latestResetAt = $null
            aggregateAssessment = [ordered]@{ supportingGuids = @() }
        }
        history = @($baseHistory)
        tiboPosts = @()
    }
    Save-Fixture -Value $base
    $null = Invoke-DryRun

    $proposalPost = [ordered]@{
        guid = "1001"
        link = "https://x.com/thsottiaux/status/1001"
        pubDate = "2026-07-19T00:00:00.000Z"
        title = "Confirmed"
        context = "How about today's reset?"
        tweetAssessment = [ordered]@{
            category = "reset_proposal"
            reason = "Explicit reset proposal."
            resetSignalStrength = 70
        }
    }
    $crossing = [ordered]@{
        at = "2026-07-19T00:00:00.000Z"
        fromScore = 60
        scoreDelta = 15
        toScore = 75
        changes = @([ordered]@{
            label = "LLM tweet-context judgment"
            from = 0
            delta = 15
            to = 15
        })
    }
    $base.fetchedAt = "2026-07-19T00:01:00.000Z"
    $base.forecast.score = 75
    $base.forecast.aggregateAssessment.supportingGuids = @("1001")
    $base.history = @($crossing, $baseHistory)
    $base.tiboPosts = @($proposalPost)
    Save-Fixture -Value $base

    $crossingOutput = Invoke-DryRun
    $crossingPayloads = @(Get-Payloads -Output $crossingOutput)
    Assert-True ($crossingPayloads.Count -eq 2) "Expected one history payload and one Tibo payload for the 70 percent crossing."
    Assert-True ([string]$crossingPayloads[0].embeds[0].title -match "70%") "The history title did not identify the 70 percent crossing."
    Assert-True ([string]$crossingPayloads[0].embeds[0].description -match "2026-07-19 09:00:00 KST") "The site event was not rendered in KST."
    Assert-True ([string]$crossingPayloads[1].embeds[0].url -eq $proposalPost.link) "The site-selected Tibo link was not preserved."
    Assert-True ([string]$crossingPayloads[1].embeds[0].description -match "Confirmed") "The Tibo original was not included."

    $duplicateOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $duplicateOutput).Count -eq 0) "An unchanged API response produced duplicate alerts."

    $base.forecast.latestResetAt = "2026-07-19T00:05:00.000Z"
    Save-Fixture -Value $base
    $latestResetOnlyOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $latestResetOnlyOutput).Count -eq 0) "A latestResetAt-only change produced an alert."

    $completedPost = [ordered]@{
        guid = "1002"
        link = "https://x.com/thsottiaux/status/1002"
        pubDate = "2026-07-19T00:10:00.000Z"
        title = "Enjoy reset usage limits."
        context = ""
        tweetAssessment = [ordered]@{
            category = "reset_completed"
            reason = "Explicit completed reset post."
            resetSignalStrength = 85
        }
    }
    $completed = [ordered]@{
        at = "2026-07-19T00:10:00.000Z"
        fromScore = 75
        scoreDelta = -72
        toScore = 3
        changes = @([ordered]@{
            label = "confirmed reset"
            from = 75
            delta = -72
            to = 3
            details = @(
                [ordered]@{ kind = "tweet"; action = "Source post"; name = $completedPost.title; url = $completedPost.link },
                [ordered]@{ action = "Why it counted"; name = "Explicit completed reset post." }
            )
        })
    }
    $base.fetchedAt = "2026-07-19T00:11:00.000Z"
    $base.forecast.score = 3
    $base.forecast.latestResetAt = $completed.at
    $base.history = @($completed, $crossing, $baseHistory)
    $base.tiboPosts = @($proposalPost, $completedPost)
    Save-Fixture -Value $base

    $completedOutput = Invoke-DryRun
    $completedPayloads = @(Get-Payloads -Output $completedOutput)
    Assert-True ($completedPayloads.Count -eq 2) "Expected one completed-reset history payload and one source-post payload."
    $actualCompletedTimestamp = ([DateTime]$completedPayloads[0].embeds[0].timestamp).ToUniversalTime()
    $expectedCompletedTimestamp = ([DateTime]"2026-07-19T00:10:00.000Z").ToUniversalTime()
    Assert-True ($actualCompletedTimestamp -eq $expectedCompletedTimestamp) "The embed timestamp did not use the site event time."
    Assert-True ([string]$completedPayloads[1].embeds[0].fields[0].value -match "reset_completed") "The completed category was not shown."
    Assert-True ([string]$completedPayloads[1].embeds[0].description -match "Enjoy reset usage limits") "The completed Tibo original was not shown."

    $completed.changes[0].details[1].name = "Corrected site explanation."
    $base.fetchedAt = "2026-07-19T00:12:00.000Z"
    Save-Fixture -Value $base
    $revisionOutput = Invoke-DryRun
    $revisionPayloads = @(Get-Payloads -Output $revisionOutput)
    Assert-True ($revisionPayloads.Count -eq 1) "A revised history entry did not produce exactly one revision alert."
    Assert-True ([string]$revisionPayloads[0].embeds[0].fields[0].value -match "Corrected site explanation") "The revised site detail was not shown."

    $longChanges = @()
    for ($index = 1; $index -le 8; $index++) {
        $longChanges += [ordered]@{
            label = "long change $index"
            from = 0
            delta = 1
            to = 1
            details = @([ordered]@{ action = "Detail"; name = ("x" * 900) })
        }
    }
    $longEntry = [ordered]@{
        at = "2026-07-19T00:20:00.000Z"
        fromScore = 3
        scoreDelta = 8
        toScore = 11
        changes = $longChanges
    }
    $base.fetchedAt = "2026-07-19T00:21:00.000Z"
    $base.forecast.score = 11
    $base.history = @($longEntry, $completed, $crossing, $baseHistory)
    Save-Fixture -Value $base
    $longOutput = Invoke-DryRun
    $longPayloads = @(Get-Payloads -Output $longOutput)
    Assert-True ($longPayloads.Count -gt 1) "A long history entry was not split across payloads."
    $longFieldCount = 0
    foreach ($payload in $longPayloads) {
        $embed = $payload.embeds[0]
        $textLength = ([string]$embed.title).Length + ([string]$embed.description).Length + ([string]$embed.footer.text).Length
        foreach ($field in @($embed.fields)) {
            $textLength += ([string]$field.name).Length + ([string]$field.value).Length
            $longFieldCount++
        }
        Assert-True ($textLength -le 6000) "A split embed exceeded Discord's 6000-character limit."
    }
    Assert-True ($longFieldCount -eq 8) "A long history entry dropped one or more change fields."

    $conflictPost = [ordered]@{
        guid = "1003"
        link = "https://x.com/thsottiaux/status/1003"
        pubDate = "2026-07-19T00:30:00.000Z"
        title = "The sun came out " + ("y" * 4000)
        context = "Unrelated conversation " + ("c" * 4000)
        tweetAssessment = [ordered]@{
            category = "reset_completed"
            reason = "No Codex reset mention; unrelated. " + ("r" * 4000)
            resetSignalStrength = 0
        }
    }
    $conflictEntry = [ordered]@{
        at = "2026-07-19T00:30:00.000Z"
        fromScore = 95
        scoreDelta = -53
        toScore = 42
        changes = @([ordered]@{
            label = "confirmed reset"
            from = 95
            delta = -53
            to = 42
            details = @(
                [ordered]@{ kind = "tweet"; action = "Source post"; name = $conflictPost.title; url = $conflictPost.link },
                [ordered]@{ action = "Why it counted"; name = "Explicit completed Codex quota-reset post. " + ("h" * 4000) }
            )
        })
    }
    $base.fetchedAt = "2026-07-19T00:31:00.000Z"
    $base.forecast.score = 42
    $base.history = @($conflictEntry, $longEntry, $completed, $crossing, $baseHistory)
    $base.tiboPosts = @($proposalPost, $completedPost, $conflictPost)
    Save-Fixture -Value $base
    $conflictOutput = Invoke-DryRun
    $conflictPayloads = @(Get-Payloads -Output $conflictOutput)
    Assert-True ($conflictPayloads.Count -eq 2) "The contradictory site classification did not produce history and source payloads."
    Assert-True ([int]$conflictPayloads[0].embeds[0].color -eq 15105570) "The contradictory site classification was not rendered as a warning."
    Assert-True ([string]$conflictPayloads[1].embeds[0].description -match "The sun came out") "The contradictory Tibo original was hidden."
    Assert-True ((@($conflictPayloads[1].embeds[0].fields | ForEach-Object { [string]$_.value }) -join " ") -match "No Codex reset mention; unrelated") "The current contradictory model reason was hidden."
    Assert-True (@($conflictPayloads[1].embeds[0].fields).Count -ge 2) "Long Tibo content removed a safety field."
    Assert-True ([string]$conflictPayloads[1].embeds[0].fields[0].value -match "Recent Movement") "The contradiction warning was not prioritized under Discord's length limit."

    Remove-Item -LiteralPath $State -Force
    [ordered]@{
        seenPostIds = @("legacy")
        latestResetAt = "2026-07-01T00:00:00.000Z"
        highForecastAlerted = $true
        initializedAt = "2026-07-01T00:00:00.000Z"
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $State -Encoding UTF8
    $migrationOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $migrationOutput).Count -eq 0) "The v1 migration replayed old alerts."
    $migrated = Get-Content -LiteralPath $State -Raw | ConvertFrom-Json
    Assert-True ([int]$migrated.schemaVersion -eq 2) "The state did not migrate to schema v2."

    Write-Output "All monitor tests passed."
} finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
