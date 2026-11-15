<#
Runs Test-Calendar.ps1 against the repository's calendar.json, which must pass, and against one planted
bad sample per rule in tests/calendar/<rule>.json or <rule>.<case>.json, each of which must fail with
exactly that rule.
Runs in a child process of the same PowerShell, so it tests whichever edition starts it.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'scripts/Test-Calendar.ps1'
$shell = (Get-Process -Id $PID).Path

function Invoke-Calendar([string]$Path) {
    $out = & $shell -NoProfile -NonInteractive -File $script -Path $Path 2>&1 | Out-String
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out }
}

$failures = 0
$r = Invoke-Calendar (Join-Path $root 'calendar.json')
if ($r.Exit -eq 0) { Write-Host "PASS  calendar.json passes" }
else { $failures++; Write-Host "FAIL  calendar.json should pass, exit $($r.Exit)`n$($r.Output)" }

# The workflows run the script with no -Path, so its default must find the repository's calendar.json.
# Continue, so that under Windows PowerShell 5.1 the child's error text is reported, not thrown here.
$out = & { $ErrorActionPreference = 'Continue'; & $shell -NoProfile -NonInteractive -File $script 2>&1 | Out-String }
if ($LASTEXITCODE -eq 0) { Write-Host 'PASS  with no -Path, as the workflows call it, the default calendar.json passes' }
else { $failures++; Write-Host "FAIL  with no -Path the script should pass, exit $LASTEXITCODE`n$out" }

$samples = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'calendar') -Filter '*.json' | Sort-Object Name)
if ($samples.Count -eq 0) { throw 'No planted samples found.' }
foreach ($s in $samples) {
    $rule = $s.BaseName.Split('.')[0]
    $r = Invoke-Calendar $s.FullName
    $tags = @([regex]::Matches($r.Output, 'ERROR: \[([a-z-]+)\]') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $line = ($r.Output -split "`r?`n" | Where-Object { $_ -like "ERROR: *" }) -join ' | '
    if ($r.Exit -eq 1 -and $tags.Count -eq 1 -and $tags[0] -eq $rule) {
        Write-Host "PASS  $($s.BaseName) -> $line"
    }
    else {
        $failures++
        Write-Host "FAIL  $rule expected exit 1 with only [$rule]; got exit $($r.Exit), rules [$($tags -join ', ')]`n$($r.Output)"
    }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)): $($samples.Count + 2) cases, $failures failed."
if ($failures -gt 0) { exit 1 }
