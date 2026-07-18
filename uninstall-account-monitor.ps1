[CmdletBinding()]
param(
    [switch]$RemoveLocalState
)

$ErrorActionPreference = "Stop"
$taskPrefix = "Codex Quota Ticket"
$dataDirectory = Join-Path $env:LOCALAPPDATA "CodexQuotaMonitor"
$disabledFile = Join-Path $dataDirectory "disabled"

New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
New-Item -ItemType File -Path $disabledFile -Force | Out-Null

Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName.StartsWith($taskPrefix, [StringComparison]::Ordinal) } |
    ForEach-Object {
        Stop-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false
        Write-Output "Removed scheduled task: $($_.TaskName)"
    }

if ($RemoveLocalState) {
    if (Test-Path -LiteralPath $dataDirectory) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $dataDirectory).Path)
        $expected = [IO.Path]::GetFullPath($dataDirectory)
        if (-not $resolved.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected state path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Write-Output "Removed local monitor state: $resolved"
    }
    New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
    New-Item -ItemType File -Path $disabledFile -Force | Out-Null
}

Write-Output "Automatic ticket use is disabled. Reinstalling removes the disable marker."
