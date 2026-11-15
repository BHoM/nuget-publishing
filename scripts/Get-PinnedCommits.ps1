<#
.SYNOPSIS
Pins every repository in config/repos.json to the commit its default branch pointed at just before
the cutoff, and writes the pin file.

.DESCRIPTION
Uses the branch activity log (see PinnedCommit.psm1). Fails closed: if any repository cannot be pinned
with confidence, no pin file is written and the script throws, naming each one. Reads only. Uses a
token from the GH_TOKEN environment variable when one is set.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$CutoffUtc,
    [Parameter(Mandatory)][string]$OutFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PinnedCommit.psm1') -Force

if ($CutoffUtc -notmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z') {
    throw "Cutoff '$CutoffUtc' must be UTC in the form yyyy-MM-ddTHH:mm:ssZ."
}
$cutoff = [DateTimeOffset]::Parse($CutoffUtc, [Globalization.CultureInfo]::InvariantCulture)
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$results = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $config.repos) {
    try {
        $results.Add((Resolve-PinnedCommit -Repo $entry.repo -Cutoff $cutoff))
    }
    catch {
        $failures.Add("$($entry.repo): $($_.Exception.Message)")
        Write-Host "::error title=Pin refused::$($_.Exception.Message)"
    }
}

$results | Format-Table repo, sha, committerDate, activityTimestamp, activityType -AutoSize | Out-String -Width 200 | Write-Host

if ($env:GITHUB_STEP_SUMMARY) {
    $md = @('## Pinned commits', '', "Cutoff $CutoffUtc. Each pin is the branch head recorded in the activity log just before the cutoff.", '',
        '| Repository | Pin | Committed | Branch updated |', '|---|---|---|---|')
    $md += $results | ForEach-Object { "| $($_.repo) | ``$($_.sha)`` | $($_.committerDate) | $($_.activityTimestamp) |" }
    $md += $failures | ForEach-Object { "| **refused** | $($_ -replace '\|', '\|') | | |" }
    $md | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

if ($failures.Count -gt 0) {
    throw "Pinning refused for $($failures.Count) of $(@($config.repos).Count) repositories; no pin file written.`n$($failures -join "`n")"
}
$doc = [ordered]@{ cutoffUtc = $CutoffUtc; generatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture); repos = @($results) }
$doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutFile -Encoding utf8
Write-Host "Pinned $($results.Count) repositories at $CutoffUtc."
