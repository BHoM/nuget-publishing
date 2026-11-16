<#
.SYNOPSIS
Live checks of the pin against the public GitHub API.

.DESCRIPTION
Read-only GETs; set GH_TOKEN to avoid the anonymous rate limit (about 55 requests for all three parts).

  -Part LateMerge    BHoM_Engine at 2026-11-04T14:59:05Z must return 182d371, the develop head then
  -Part Unreachable  XML_Toolkit at 2023-01-01T00:00:00Z, before the activity history, must be refused
  -Part KnownPins    all 16 at 2026-11-06T05:00:00Z must equal tests/pins/known-2026-11-06.json
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('LateMerge', 'Unreachable', 'KnownPins')][string]$Part)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/PinnedCommit.psm1') -Force

switch ($Part) {
    'LateMerge' {
        $pin = Resolve-PinnedCommit -Repo 'BHoM/BHoM_Engine' -Cutoff ([DateTimeOffset]::Parse('2026-11-04T14:59:05Z'))
        $pin | Format-List | Out-String | Write-Host
        if ($pin.sha -ne '182d37161fbd28d733331c89b2da033a21e6bf9d') { Write-Host "FAIL  expected 182d37161fbd, got $($pin.sha)"; exit 1 }
        Write-Host 'PASS  late merge returns the develop head at the cutoff'
    }
    'Unreachable' {
        try {
            $pin = Resolve-PinnedCommit -Repo 'BHoM/XML_Toolkit' -Cutoff ([DateTimeOffset]::Parse('2023-01-01T00:00:00Z'))
            Write-Host "FAIL  expected a refusal, got $($pin.sha)"; exit 1
        }
        catch {
            if ($_.Exception.Message -notlike '*after the cutoff*head at the cutoff is unknown*') { Write-Host "FAIL  unexpected error: $($_.Exception.Message)"; exit 1 }
            Write-Host "PASS  refused: $($_.Exception.Message)"
        }
    }
    'KnownPins' {
        $expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'pins/known-2026-11-06.json') -Raw | ConvertFrom-Json
        $out = Join-Path ([IO.Path]::GetTempPath()) "pins-live-$PID.json"
        & (Join-Path $root 'scripts/Get-PinnedCommits.ps1') -ConfigPath (Join-Path $root 'config/repos.json') -CutoffUtc $expected.cutoffUtc -OutFile $out
        $actual = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        Remove-Item -LiteralPath $out
        $diff = 0
        foreach ($e in $expected.repos) {
            $a = $actual.repos | Where-Object { $_.repo -eq $e.repo }
            if (-not $a) { $diff++; Write-Host "DIFF  $($e.repo): no pin"; continue }
            if ($a.sha -ne $e.sha) { $diff++; Write-Host "DIFF  $($e.repo): recorded $($e.sha), now $($a.sha)" }
            else { Write-Host "SAME  $($e.repo) $($a.sha) ($($a.activityType) $($a.activityTimestamp), compare $($a.compareStatus))" }
        }
        Write-Host "$(@($expected.repos).Count) expected, $diff differ."
        if ($diff -gt 0) { exit 1 }
    }
}
