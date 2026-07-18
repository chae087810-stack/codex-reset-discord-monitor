[CmdletBinding()]
param(
    [switch]$SkipImmediateProbe
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$taskName = "Codex Quota Ticket Daily Probe"
$launcher = Join-Path $PSScriptRoot "run-account-monitor-hidden.vbs"
$monitor = Join-Path $PSScriptRoot "account-monitor.mjs"
$tests = Join-Path $PSScriptRoot "tests\account-monitor.test.mjs"
$wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
$dataDirectory = Join-Path $env:LOCALAPPDATA "CodexQuotaMonitor"
$disabledFile = Join-Path $dataDirectory "disabled"

foreach ($required in @($launcher, $monitor, $tests)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required file not found: $required"
    }
}

$node = (Get-Command node.exe -ErrorAction Stop).Source
$null = Get-Command gh.exe -ErrorAction Stop

& $node --test $tests
if ($LASTEXITCODE -ne 0) {
    throw "Account monitor tests failed."
}

Write-Output "Checking the signed-in Codex account (read-only; no ticket will be used)..."
& $node $monitor once
if ($LASTEXITCODE -ne 0) {
    throw "Read-only Codex account preflight failed. The scheduled task was not installed."
}

if (Test-Path -LiteralPath $disabledFile) {
    Remove-Item -LiteralPath $disabledFile -Force
}

$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$actionArguments = '//B //Nologo "{0}" probe' -f $launcher
$action = New-ScheduledTaskAction -Execute $wscript -Argument $actionArguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Daily -At "09:00"
$settings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval ([TimeSpan]::FromMinutes(1)) `
    -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5))
$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Runs for a few seconds daily to discover actual Codex reset tickets; it is not a resident process."

Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

if (-not $SkipImmediateProbe) {
    Start-ScheduledTask -TaskName $taskName
}

Write-Output "Installed hidden daily probe: $taskName"
Write-Output "The task is dormant outside its brief daily check. Ticket-specific one-time tasks are added automatically."
