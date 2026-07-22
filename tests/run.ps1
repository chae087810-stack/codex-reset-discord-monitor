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
    param([switch]$TestLatestLog)
    $output = & $Monitor -DryRun -ForecastFile $Fixture -StateFile $State -TestLatestLog:$TestLatestLog *>&1 | Out-String
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

function New-TiboPost {
    param(
        [string]$Guid,
        [string]$Category,
        [string]$Title,
        [int]$Strength = 70,
        [string]$Reason = "Reset-related post."
    )
    return [ordered]@{
        guid = $Guid
        link = "https://x.com/thsottiaux/status/$Guid"
        pubDate = "2026-07-19T00:$Guid`:00.000Z"
        title = $Title
        context = ""
        tweetAssessment = [ordered]@{
            category = $Category
            reason = $Reason
            resetSignalStrength = $Strength
        }
    }
}

try {
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

    $proposal = New-TiboPost -Guid "01" -Category "reset_proposal" -Title "Should we reset tomorrow?"
    $announcement = New-TiboPost -Guid "02" -Category "reset_announced" -Title "A reset may happen later."
    $coupon = New-TiboPost -Guid "03" -Category "reset_coupon" -Title "You have a banked reset coupon."
    $base = [ordered]@{
        fetchedAt = "2026-07-19T00:05:00.000Z"
        forecast = [ordered]@{
            score = 95
            latestResetAt = $null
            aggregateAssessment = [ordered]@{ supportingGuids = @("01", "02", "03") }
        }
        history = @([ordered]@{
            at = "2026-07-19T00:04:00.000Z"
            fromScore = 20
            scoreDelta = 75
            toScore = 95
            changes = @([ordered]@{ label = "strong reset forecast"; from = 0; delta = 75; to = 75 })
        })
        tiboPosts = @($proposal, $announcement, $coupon)
    }

    Save-Fixture -Value $base
    $initialOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $initialOutput).Count -eq 0) "Initialization produced an unwanted Discord alert."
    $initialState = Get-Content -LiteralPath $State -Raw | ConvertFrom-Json
    Assert-True ([int]$initialState.schemaVersion -eq 3) "The monitor did not initialize schema v3."

    $base.fetchedAt = "2026-07-19T00:06:00.000Z"
    $base.forecast.score = 100
    $base.history = @([ordered]@{
        at = "2026-07-19T00:06:00.000Z"
        fromScore = 95
        scoreDelta = 5
        toScore = 100
        changes = @([ordered]@{ label = "confirmed soon"; from = 0; delta = 5; to = 5 })
    }) + @($base.history)
    Save-Fixture -Value $base
    $noiseOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $noiseOutput).Count -eq 0) "Forecast, history, proposal, announcement, or coupon noise produced an alert."

    $completed = New-TiboPost -Guid "10" -Category "reset_completed" -Title "Enjoy reset usage limits." -Strength 90 -Reason "Explicit completed Codex usage reset."
    $base.fetchedAt = "2026-07-19T00:11:00.000Z"
    $base.forecast.score = 3
    $base.forecast.latestResetAt = "2026-07-19T00:10:00.000Z"
    $base.tiboPosts = @($proposal, $announcement, $coupon, $completed)
    $base.history = @([ordered]@{
        at = "2026-07-19T00:10:00.000Z"
        fromScore = 100
        scoreDelta = -97
        toScore = 3
        changes = @([ordered]@{
            label = "confirmed reset"
            from = 100
            delta = -97
            to = 3
            details = @([ordered]@{ kind = "tweet"; name = $completed.title; url = $completed.link })
        })
    }) + @($base.history)
    Save-Fixture -Value $base

    $completedOutput = Invoke-DryRun
    $completedPayloads = @(Get-Payloads -Output $completedOutput)
    Assert-True ($completedPayloads.Count -eq 1) "A completed reset did not produce exactly one Tibo alert."
    $completedEmbed = $completedPayloads[0].embeds[0]
    Assert-True ([string]$completedEmbed.title -match "Tibo.*Codex") "The alert title did not identify Tibo's Codex reset."
    Assert-True ([string]$completedEmbed.url -eq $completed.link) "The completed Tibo post link was not preserved."
    Assert-True ([string]$completedEmbed.description -match "Enjoy reset usage limits") "The completed Tibo original was not included."
    Assert-True ((@($completedEmbed.fields | ForEach-Object { [string]$_.value }) -join " ") -match "reset_completed") "The completed category was not included."

    $duplicateOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $duplicateOutput).Count -eq 0) "An unchanged completed post produced a duplicate alert."

    $base.history[0].changes[0].details += [ordered]@{ name = "History revision only" }
    $base.fetchedAt = "2026-07-19T00:12:00.000Z"
    Save-Fixture -Value $base
    $revisionOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $revisionOutput).Count -eq 0) "A Recent Movement revision produced an alert."

    $conflict = New-TiboPost -Guid "20" -Category "reset_completed" -Title "The sun came out." -Strength 0 -Reason "No Codex reset mention; unrelated."
    $base.fetchedAt = "2026-07-19T00:21:00.000Z"
    $base.tiboPosts += $conflict
    Save-Fixture -Value $base
    $conflictOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $conflictOutput).Count -eq 0) "A contradictory reset-completed classification produced an alert."
    $conflictDuplicateOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $conflictDuplicateOutput).Count -eq 0) "A suppressed contradictory post was reconsidered on every run."

    $testOutput = Invoke-DryRun -TestLatestLog
    $testPayloads = @(Get-Payloads -Output $testOutput)
    Assert-True ($testPayloads.Count -eq 1) "The manual format test did not send exactly one completed-reset example."
    Assert-True ([string]$testPayloads[0].embeds[0].title -match "Tibo.*Codex") "The manual test did not use the completed-reset alert format."

    Remove-Item -LiteralPath $State -Force
    [ordered]@{
        schemaVersion = 2
        seenHistoryIds = @("legacy")
        seenSignalPostIds = @()
        initializedAt = "2026-07-01T00:00:00.000Z"
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $State -Encoding UTF8
    $migrationOutput = Invoke-DryRun
    Assert-True (@(Get-Payloads -Output $migrationOutput).Count -eq 0) "The v2-to-v3 migration replayed old completed posts."
    $migrated = Get-Content -LiteralPath $State -Raw | ConvertFrom-Json
    Assert-True ([int]$migrated.schemaVersion -eq 3) "The state did not migrate to schema v3."
    Assert-True (@($migrated.seenCompletedResetPostIds).Count -eq 2) "Migration did not baseline all current completed-post IDs."

    Write-Output "All monitor tests passed."
} finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
