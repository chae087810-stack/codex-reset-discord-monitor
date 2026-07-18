[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Register", "Remove")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[a-f0-9]{16}$")]
    [string]$CreditKey,

    [long]$ExpiresAt = 0
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$warningTaskName = "Codex Quota Ticket Warnings $CreditKey"
$consumeTaskName = "Codex Quota Ticket Consume $CreditKey"
$launcher = Join-Path $PSScriptRoot "run-account-monitor-hidden.vbs"
$wscript = Join-Path $env:SystemRoot "System32\wscript.exe"

function Remove-MonitorTask {
    param([string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

if ($Mode -eq "Remove") {
    Remove-MonitorTask -TaskName $warningTaskName
    Remove-MonitorTask -TaskName $consumeTaskName
    return
}

if ($ExpiresAt -le 0) {
    throw "ExpiresAt must be a positive Unix timestamp for Register mode."
}
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Hidden launcher not found: $launcher"
}

$expiry = [DateTimeOffset]::FromUnixTimeSeconds($ExpiresAt).LocalDateTime
$now = Get-Date
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$warningSettings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval ([TimeSpan]::FromMinutes(1)) `
    -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5))
$consumeSettings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -StartWhenAvailable `
    -WakeToRun `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval ([TimeSpan]::FromMinutes(1)) `
    -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10))

$warningArguments = '//B //Nologo "{0}" event --credit-key {1}' -f $launcher, $CreditKey
$consumeArguments = '//B //Nologo "{0}" consume --credit-key {1}' -f $launcher, $CreditKey
$warningAction = New-ScheduledTaskAction -Execute $wscript -Argument $warningArguments -WorkingDirectory $PSScriptRoot
$consumeAction = New-ScheduledTaskAction -Execute $wscript -Argument $consumeArguments -WorkingDirectory $PSScriptRoot

$warningTriggers = @()
foreach ($seconds in @(86400, 43200, 21600, 3600, 1800)) {
    $runAt = $expiry.AddSeconds(-$seconds)
    if ($runAt -gt $now.AddSeconds(3)) {
        $warningTriggers += New-ScheduledTaskTrigger -Once -At $runAt
    }
}

if ($warningTriggers.Count -gt 0) {
    $warningTask = New-ScheduledTask `
        -Action $warningAction `
        -Trigger $warningTriggers `
        -Principal $principal `
        -Settings $warningSettings `
        -Description "Checks the actual Codex reset ticket only at final-day warning thresholds."
    Register-ScheduledTask -TaskName $warningTaskName -InputObject $warningTask -Force | Out-Null
} else {
    Remove-MonitorTask -TaskName $warningTaskName
}

if ($expiry -gt $now) {
    $consumeTriggers = @()
    $prepareAt = $expiry.AddMinutes(-5)
    if ($prepareAt -gt $now.AddSeconds(3)) {
        $consumeTriggers += New-ScheduledTaskTrigger -Once -At $prepareAt
    } else {
        $consumeTriggers += New-ScheduledTaskTrigger -Once -At $now.AddSeconds(5)
    }
    foreach ($safetyWakeAt in @($expiry.AddMinutes(-3), $expiry.AddMinutes(-2))) {
        if ($safetyWakeAt -gt $now.AddSeconds(8)) {
            $consumeTriggers += New-ScheduledTaskTrigger -Once -At $safetyWakeAt
        }
    }
    $consumeTask = New-ScheduledTask `
        -Action $consumeAction `
        -Trigger $consumeTriggers `
        -Principal $principal `
        -Settings $consumeSettings `
        -Description "Prepares at T-5, adds T-3/T-2 safety wakes, and uses the actual Codex reset ticket at T-1."
    Register-ScheduledTask -TaskName $consumeTaskName -InputObject $consumeTask -Force | Out-Null
} else {
    Remove-MonitorTask -TaskName $consumeTaskName
}
