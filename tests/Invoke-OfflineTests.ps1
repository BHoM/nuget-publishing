<#
.SYNOPSIS
Runs every offline test script, tests/*.Tests.ps1, and fails if any of them fails.

.DESCRIPTION
Each runs in a child process of the PowerShell that starts this one. PinnedCommit.Live.ps1 calls the
API and is not run here.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$shell = (Get-Process -Id $PID).Path
$scripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.Tests.ps1' | Sort-Object Name)
if ($scripts.Count -eq 0) { throw 'No test scripts found.' }
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($s in $scripts) {
    Write-Host "::group::$($s.Name)"
    & $shell -NoProfile -NonInteractive -File $s.FullName
    $code = $LASTEXITCODE
    Write-Host '::endgroup::'
    if ($code -ne 0) { $failed.Add("$($s.Name) (exit $code)"); Write-Host "FAILED  $($s.Name)" } else { Write-Host "passed  $($s.Name)" }
}
Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) on $([Environment]::OSVersion.Platform): $($scripts.Count) scripts, $($failed.Count) failed."
if ($failed.Count -gt 0) { throw "Failed: $($failed -join ', ')" }
