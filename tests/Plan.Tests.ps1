<#
Offline tests for plan's event selection (Select-ReleaseEvent) on fixed dates, for which runs need
approval (Test-AlphaOnly), and for the outputs Invoke-Plan writes. Completeness on nuget.org is a stub,
so nothing touches the network.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/Release.psm1') -Force
Import-Module (Join-Path $root 'scripts/Plan.psm1') -Force

function Ev([string]$Date, [string]$Version, [int]$Sprint = 0, [bool]$Skip = $false) {
    [pscustomobject]@{ date = $Date; version = $Version; sprint = $Sprint; skip = $Skip }
}
$calendar = @(
    (Ev '2027-01-15' '10.1.0-alpha.1.0'),
    (Ev '2027-01-29' '10.1.0-alpha.2.0' -Skip $true),
    (Ev '2027-03-26' '10.1.0-beta.0' 6),
    (Ev '2027-03-26' '10.1.0-alpha.6.0')
)
function At([string]$Iso) { [DateTimeOffset]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture) }
$never = { param($v) throw "completeness was checked for $v, and should not have been" }
$complete = { param($v) $true }
$incomplete = { param($v) $false }

$cases = @(
    @{ Name = 'schedule, no event today'; Args = @{ EventName = 'schedule'; Now = (At '2027-01-16T05:17:00Z') }; Expect = @() },
    @{ Name = 'schedule, one event today'; Args = @{ EventName = 'schedule'; Now = (At '2027-01-15T05:17:00Z') }; Expect = @('10.1.0-alpha.1.0@2027-01-15T05:00:00Z') },
    @{ Name = 'schedule, same-day beta and alpha come out alpha first'; Args = @{ EventName = 'schedule'; Now = (At '2027-03-26T05:17:00Z') }; Expect = @('10.1.0-alpha.6.0@2027-03-26T05:00:00Z', '10.1.0-beta.0@2027-03-26T05:00:00Z') },
    @{ Name = 'schedule, the only event today is skipped'; Args = @{ EventName = 'schedule'; Now = (At '2027-01-29T05:17:00Z') }; Expect = @() },
    @{ Name = 'schedule, before the cutoff on the event day selects nothing'; Args = @{ EventName = 'schedule'; Now = (At '2027-01-15T04:59:59Z') }; Expect = @() },
    @{ Name = 'schedule, late run created after midnight on the event day selects nothing'; Args = @{ EventName = 'schedule'; Now = (At '2027-01-15T00:30:00Z') }; Expect = @() },
    @{ Name = 'schedule, at the cutoff selects the event'; Args = @{ EventName = 'schedule'; Now = (At '2027-01-15T05:00:00Z') }; Expect = @('10.1.0-alpha.1.0@2027-01-15T05:00:00Z') },
    @{ Name = 'schedule, late run still on the event day (UTC)'; Args = @{ EventName = 'schedule'; Now = (At '2027-01-15T23:59:59Z') }; Expect = @('10.1.0-alpha.1.0@2027-01-15T05:00:00Z') },
    @{ Name = 'dispatch, unknown version'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.9.0'; Now = (At '2027-02-01T10:00:00Z'); IsComplete = $never }; Refuse = 'is not in calendar.json' },
    @{ Name = 'dispatch, version differing only in case is unknown'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-ALPHA.1.0'; Now = (At '2027-02-01T10:00:00Z'); IsComplete = $never }; Refuse = 'is not in calendar.json' },
    @{ Name = 'dispatch, empty version'; Args = @{ EventName = 'workflow_dispatch'; Version = ''; Now = (At '2027-02-01T10:00:00Z'); IsComplete = $never }; Refuse = 'needs a version' },
    @{ Name = 'dispatch, future version'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-beta.0'; Now = (At '2027-02-01T10:00:00Z'); IsComplete = $never }; Refuse = 'after today' },
    @{ Name = 'dispatch, skipped version'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.2.0'; Now = (At '2027-02-01T10:00:00Z'); IsComplete = $never }; Refuse = 'marked skip' },
    @{ Name = 'dispatch, already complete'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.1.0'; Now = (At '2027-02-01T10:00:00Z'); IsComplete = $complete }; Refuse = 'already complete on nuget.org' },
    @{ Name = 'dispatch, past and incomplete (catch-up)'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.1.0'; Now = (At '2027-02-01T10:00:00Z'); IsComplete = $incomplete }; Expect = @('10.1.0-alpha.1.0@2027-01-15T05:00:00Z') },
    @{ Name = 'dispatch, event day after 05:00'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.1.0'; Now = (At '2027-01-15T12:30:00Z'); IsComplete = $incomplete }; Expect = @('10.1.0-alpha.1.0@2027-01-15T05:00:00Z') },
    @{ Name = 'dispatch, event day before 05:00'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.1.0'; Now = (At '2027-01-15T04:59:59Z'); IsComplete = $never }; Refuse = 'has not passed yet' },
    @{ Name = 'rehearsal, future version pins at the run start'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.1.0'; Rehearsal = $true; Now = (At '2026-12-10T09:15:42.750Z'); IsComplete = $never }; Expect = @('10.1.0-alpha.1.0@2026-12-10T09:15:42Z') },
    @{ Name = 'rehearsal, complete past version pins at its cutoff and skips the completeness check'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.1.0'; Rehearsal = $true; Now = (At '2027-02-01T10:00:00Z'); IsComplete = $never }; Expect = @('10.1.0-alpha.1.0@2027-01-15T05:00:00Z') },
    @{ Name = 'rehearsal, skipped version is still refused'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.2.0'; Rehearsal = $true; Now = (At '2026-12-10T09:00:00Z'); IsComplete = $never }; Refuse = 'marked skip' },
    @{ Name = 'rehearsal, unknown version is still refused'; Args = @{ EventName = 'workflow_dispatch'; Version = '10.1.0-alpha.9.0'; Rehearsal = $true; Now = (At '2026-12-10T09:00:00Z'); IsComplete = $never }; Refuse = 'is not in calendar.json' }
)

$failures = 0
foreach ($c in $cases) {
    $a = $c.Args
    try {
        $events = Select-ReleaseEvent -Calendar $calendar @a
        $got = @($events | ForEach-Object { "$($_.version)@$($_.cutoff)" })
        $sprintOk = @($events | Where-Object { $_.version -eq '10.1.0-beta.0' -and $_.sprint -ne 6 }).Count -eq 0
        if ($c.ContainsKey('Expect') -and (($got -join ',') -ceq ($c.Expect -join ',')) -and $sprintOk) { Write-Host "PASS  $($c.Name) -> [$($got -join ', ')]" }
        else { $failures++; Write-Host "FAIL  $($c.Name): got [$($got -join ', ')]" }
    }
    catch {
        $msg = $_.Exception.Message
        if ($c.ContainsKey('Refuse') -and $msg -like "*$($c.Refuse)*") { Write-Host "PASS  $($c.Name) -> refused: $msg" }
        else { $failures++; Write-Host "FAIL  $($c.Name): threw $msg" }
    }
}

# Only a run whose events are all alphas publishes without approval.
$approvalCases = @(
    @{ Name = 'alpha only'; Versions = @('10.1.0-alpha.1.0'); Expect = $true },
    @{ Name = 'two alphas'; Versions = @('10.1.0-alpha.1.0', '10.1.0-alpha.2.0'); Expect = $true },
    @{ Name = 'beta only'; Versions = @('10.1.0-beta.0'); Expect = $false },
    @{ Name = 'alpha with a beta'; Versions = @('10.1.0-alpha.6.0', '10.1.0-beta.0'); Expect = $false },
    @{ Name = 'no event'; Versions = @(); Expect = $false }
)
foreach ($c in $approvalCases) {
    $got = Test-AlphaOnly -Events @($c.Versions | ForEach-Object { Ev '2027-03-26' $_ })
    if ($got -eq $c.Expect) { Write-Host "PASS  alphas only, $($c.Name) -> $got" }
    else { $failures++; Write-Host "FAIL  alphas only, $($c.Name): got $got" }
}

# Invoke-Plan end to end, schedule mode, on a planted calendar dated today so no network is needed.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "plan-test-$PID"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$saved = @{ GITHUB_EVENT_NAME = $env:GITHUB_EVENT_NAME; GITHUB_OUTPUT = $env:GITHUB_OUTPUT; GITHUB_STEP_SUMMARY = $env:GITHUB_STEP_SUMMARY; INPUT_VERSION = $env:INPUT_VERSION; INPUT_REHEARSAL = $env:INPUT_REHEARSAL; GITHUB_RUN_ATTEMPT = $env:GITHUB_RUN_ATTEMPT }
try {
    $noon = [DateTimeOffset]::new([DateTime]::UtcNow.Date.AddHours(12), [TimeSpan]::Zero)
    $today = $noon.UtcDateTime.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $cal = Join-Path $tmp 'calendar.json'
    Set-Content -LiteralPath $cal -Value "[ { `"date`": `"$today`", `"version`": `"10.1.0-beta.0`", `"sprint`": 6 }, { `"date`": `"$today`", `"version`": `"10.1.0-alpha.6.0`" } ]"
    $env:GITHUB_EVENT_NAME = 'schedule'; $env:INPUT_VERSION = $null; $env:INPUT_REHEARSAL = $null; $env:GITHUB_STEP_SUMMARY = $null
    $env:GITHUB_RUN_ATTEMPT = '1'
    $env:GITHUB_OUTPUT = Join-Path $tmp 'output.txt'
    Invoke-Plan -CalendarPath $cal -ConfigPath (Join-Path $root 'config/repos.json') -Now $noon | Out-Null
    $out = @(Get-Content -LiteralPath $env:GITHUB_OUTPUT)
    $eventsLine = @($out | Where-Object { $_ -like 'events=*' })
    $parsed = $eventsLine[0].Substring(7) | ConvertFrom-Json; $parsed = @($parsed)
    $ok = $eventsLine.Count -eq 1 -and $parsed.Count -eq 2 -and $parsed[0].version -eq '10.1.0-alpha.6.0' -and $parsed[1].sprint -eq 6 -and ($out -contains 'rehearsal=false') -and
        ($out -contains 'approval=true') -and ($out -contains "planned_on=$today")
    if ($ok) { Write-Host "PASS  Invoke-Plan writes events, rehearsal, approval and planned_on as single-line outputs -> $($eventsLine[0])" }
    else { $failures++; Write-Host "FAIL  Invoke-Plan outputs: $($out -join ' | ')" }

    Set-Content -LiteralPath $cal -Value '[ { "date": "2001-01-01", "version": "10.1.0-alpha.1.0" } ]'
    Remove-Item -LiteralPath $env:GITHUB_OUTPUT
    Invoke-Plan -CalendarPath $cal -ConfigPath (Join-Path $root 'config/repos.json') -Now $noon | Out-Null
    $out = @(Get-Content -LiteralPath $env:GITHUB_OUTPUT)
    if (($out -contains 'events=[]') -and ($out -contains 'approval=true')) { Write-Host 'PASS  Invoke-Plan with no event today writes events=[] and approval=true' }
    else { $failures++; Write-Host "FAIL  Invoke-Plan no-event outputs: $($out -join ' | ')" }

    Set-Content -LiteralPath $cal -Value "[ { `"date`": `"$today`", `"version`": `"10.1.0-alpha.1.0`" } ]"
    Remove-Item -LiteralPath $env:GITHUB_OUTPUT
    Invoke-Plan -CalendarPath $cal -ConfigPath (Join-Path $root 'config/repos.json') -Now $noon | Out-Null
    $out = @(Get-Content -LiteralPath $env:GITHUB_OUTPUT)
    if ($out -contains 'approval=false') { Write-Host 'PASS  Invoke-Plan with an alpha only writes approval=false' }
    else { $failures++; Write-Host "FAIL  Invoke-Plan alpha-only outputs: $($out -join ' | ')" }

    $env:GITHUB_RUN_ATTEMPT = '2'
    Remove-Item -LiteralPath $env:GITHUB_OUTPUT
    try { Invoke-Plan -CalendarPath $cal -ConfigPath (Join-Path $root 'config/repos.json') -Now $noon | Out-Null; $failures++; Write-Host 'FAIL  plan ran on a second attempt' }
    catch {
        if ($_.Exception.Message -like '*plan runs once only*' -and -not (Test-Path -LiteralPath $env:GITHUB_OUTPUT)) { Write-Host "PASS  second attempt of a run -> refused: $($_.Exception.Message)" }
        else { $failures++; Write-Host "FAIL  second attempt: threw $($_.Exception.Message)" }
    }
    $env:GITHUB_RUN_ATTEMPT = '1'

    $env:GITHUB_EVENT_NAME = 'workflow_dispatch'; $env:INPUT_VERSION = '10.1.0-alpha.1.0'; $env:INPUT_REHEARSAL = 'yes'
    try { Invoke-Plan -CalendarPath $cal -ConfigPath (Join-Path $root 'config/repos.json') -Now $noon | Out-Null; $failures++; Write-Host 'FAIL  rehearsal input other than true or false was accepted' }
    catch { Write-Host "PASS  rehearsal input other than true or false -> refused: $($_.Exception.Message)" }
}
finally {
    foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

# Build reads plan's events with ConvertFrom-Json, which under PowerShell 7 turns the
# cutoff string into a DateTime. Passed straight to Get-PinnedCommits.ps1's [string] parameter it would
# read 01/15/2027 05:00:00 and be refused. Format-EventCutoff must give back yyyy-MM-ddTHH:mm:ssZ.
$cutoffCases = @(
    @{ Name = 'cutoff as the string plan wrote'; Value = '2027-01-15T05:00:00Z'; Expect = '2027-01-15T05:00:00Z' },
    @{ Name = 'cutoff as a UTC DateTime (PowerShell 7 ConvertFrom-Json)'; Value = [DateTime]::new(2027, 1, 15, 5, 0, 0, [DateTimeKind]::Utc); Expect = '2027-01-15T05:00:00Z' },
    @{ Name = 'cutoff as a local DateTime'; Value = [DateTime]::new(2027, 1, 15, 5, 0, 0, [DateTimeKind]::Utc).ToLocalTime(); Expect = '2027-01-15T05:00:00Z' },
    @{ Name = 'cutoff as a DateTime with no zone is refused'; Value = [DateTime]::new(2027, 1, 15, 5, 0, 0, [DateTimeKind]::Unspecified); Refuse = 'no time zone' },
    @{ Name = 'cutoff in another format is refused'; Value = '01/15/2027 05:00:00'; Refuse = 'is not yyyy-MM-ddTHH:mm:ssZ' }
)
foreach ($c in $cutoffCases) {
    try {
        $got = Format-EventCutoff $c.Value
        if ($c.ContainsKey('Expect') -and $got -ceq $c.Expect) { Write-Host "PASS  $($c.Name) -> $got" }
        else { $failures++; Write-Host "FAIL  $($c.Name): got $got" }
    }
    catch {
        if ($c.ContainsKey('Refuse') -and $_.Exception.Message -like "*$($c.Refuse)*") { Write-Host "PASS  $($c.Name) -> refused: $($_.Exception.Message)" }
        else { $failures++; Write-Host "FAIL  $($c.Name): threw $($_.Exception.Message)" }
    }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion): $($cases.Count + $approvalCases.Count + 5 + $cutoffCases.Count) cases, $failures failed."
if ($failures -gt 0) { exit 1 }
