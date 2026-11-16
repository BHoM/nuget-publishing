<#
Offline tests for the watcher (Invoke-WatchCheck) against a planted calendar, stubbed nuget.org
responses and an in-memory issue tracker. Each case runs the watcher one or more times and checks what it
opened and commented.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/Release.psm1') -Force
Import-Module (Join-Path $root 'scripts/Watch.psm1') -Force

$config = [pscustomobject]@{
    nugetOrgFlatContainer = 'https://api.nuget.org/v3-flatcontainer'
    repos = @(
        [pscustomobject]@{ repo = 'BHoM/BHoM'; packageId = 'BHoM' },
        [pscustomobject]@{ repo = 'BHoM/BHoM_Engine'; packageId = 'BHoM.Engine' },
        [pscustomobject]@{ repo = 'BHoM/BHoM_UI'; packageId = 'BHoM.UI' }
    )
}
function Ev([string]$Date, [string]$Version, [bool]$Skip = $false) { [pscustomobject]@{ date = $Date; version = $Version; sprint = 0; skip = $Skip } }
function At([string]$Iso) { [DateTimeOffset]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture) }

# nuget.org stub: $listed[id] is the set of versions present.
function New-NuGet([hashtable]$Listed) {
    $l = $Listed
    return { param($Url)
        if ($Url -notmatch '/v3-flatcontainer/([^/]+)/index\.json$') { throw "unexpected $Url" }
        $id = $Matches[1]
        $key = @($l.Keys | Where-Object { $_.ToLowerInvariant() -eq $id })
        if ($key.Count -eq 0) { return $null }
        [pscustomobject]@{ versions = @($l[$key[0]]) }
    }.GetNewClosure()
}

# Issue tracker stub. Issues and comments are kept so a later run sees what an earlier one wrote.
function New-Tracker {
    $state = [pscustomobject]@{ issues = [System.Collections.Generic.List[object]]::new(); comments = [System.Collections.Generic.List[object]]::new() }
    $client = [pscustomobject]@{
        State    = $state
        FindOpen = { param($Title) $h = @($state.issues | Where-Object { $_.title -ceq $Title -and $_.open -and $_.user -ceq 'github-actions[bot]' }); if ($h.Count) { $h[0] } else { $null } }.GetNewClosure()
        Comments = { param($Number) @($state.comments | Where-Object { $_.number -eq $Number }) }.GetNewClosure()
        Open     = { param($Title, $Body) $state.issues.Add([pscustomobject]@{ number = $state.issues.Count + 1; title = $Title; body = $Body; open = $true; user = 'github-actions[bot]' }) }.GetNewClosure()
        Comment  = { param($Number, $Body) $state.comments.Add([pscustomobject]@{ number = $Number; body = $Body; user = 'github-actions[bot]' }) }.GetNewClosure()
    }
    return $client
}

$calendar = @(
    (Ev '2027-01-15' '10.1.0-alpha.1.0'),
    (Ev '2027-01-29' '10.1.0-alpha.2.0' $true),
    (Ev '2027-04-30' '10.1.0-alpha.8.0')
)
$all = @('10.1.0-alpha.1.0', '10.1.0-alpha.2.0')
$failures = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host "PASS  $Name -> $Detail" } else { $script:failures++; Write-Host "FAIL  $Name -> $Detail" }
}
function Summary($t) { "issues [$(@($t.State.issues | ForEach-Object { $_.title }) -join '; ')], comments $($t.State.comments.Count)" }

# 1. A missing version opens one issue listing the missing IDs and mentioning the team.
$t = New-Tracker
$nuget = New-NuGet @{ 'BHoM' = $all; 'BHoM.Engine' = @('10.1.0-alpha.2.0'); 'BHoM.UI' = $all }
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-16T12:37:00Z') -Issues $t -GetIndex $nuget -Mention '@BHoM/release-team'
$issue = @($t.State.issues)
Check 'missing version opens one issue' ($issue.Count -eq 1 -and $issue[0].title -ceq 'NuGet 10.1.0-alpha.1.0 incomplete on nuget.org' -and $issue[0].body -like '@BHoM/release-team *BHoM.Engine*' -and $t.State.comments.Count -eq 0) (Summary $t)

# 2. A second run with the same missing IDs adds nothing.
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-17T12:37:00Z') -Issues $t -GetIndex $nuget -Mention '@BHoM/release-team'
Check 'same missing IDs: no new issue, no comment' ($t.State.issues.Count -eq 1 -and $t.State.comments.Count -eq 0) (Summary $t)

# 3. A changed list adds one comment, and a further run with that list adds nothing.
$nuget2 = New-NuGet @{ 'BHoM' = @(); 'BHoM.Engine' = @('10.1.0-alpha.2.0'); 'BHoM.UI' = $all }
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-18T12:37:00Z') -Issues $t -GetIndex $nuget2
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-19T12:37:00Z') -Issues $t -GetIndex $nuget2
Check 'changed list: one comment, then none' ($t.State.issues.Count -eq 1 -and $t.State.comments.Count -eq 1 -and $t.State.comments[0].body -like '*BHoM, BHoM.Engine.*') (Summary $t)

# 4. A skipped event is checked, and the issue says this workflow did not publish it.
$t = New-Tracker
$nuget = New-NuGet @{ 'BHoM' = $all; 'BHoM.Engine' = $all; 'BHoM.UI' = @('10.1.0-alpha.1.0') }
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-30T12:37:00Z') -Issues $t -GetIndex $nuget
Check 'skipped event is checked' (@($t.State.issues).Count -eq 1 -and $t.State.issues[0].title -ceq 'NuGet 10.1.0-alpha.2.0 incomplete on nuget.org' -and $t.State.issues[0].body -like '*marked skip, so this workflow did not publish it*BHoM.UI*') (Summary $t)

# 5. The 14-day window: an event 13 days back is checked, 14 days back and future events are not.
$t = New-Tracker
$none = New-NuGet @{}
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-28T12:37:00Z') -Issues $t -GetIndex $none
$inWindow = @($t.State.issues | Where-Object { $_.title -like 'NuGet*' } | ForEach-Object { $_.title })
$t2 = New-Tracker
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-29T00:00:00Z') -Issues $t2 -GetIndex $none
$outWindow = @($t2.State.issues | Where-Object { $_.title -like 'NuGet*' } | ForEach-Object { $_.title })
Check 'window is today and the 13 days before it' (($inWindow -join ';') -ceq 'NuGet 10.1.0-alpha.1.0 incomplete on nuget.org' -and ($outWindow -join ';') -ceq 'NuGet 10.1.0-alpha.2.0 incomplete on nuget.org') "28th: [$($inWindow -join '; ')]; 29th: [$($outWindow -join '; ')]"

# 6. A complete version opens nothing.
$t = New-Tracker
$complete = New-NuGet @{ 'BHoM' = $all; 'BHoM.Engine' = $all; 'BHoM.UI' = $all }
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-16T12:37:00Z') -Issues $t -GetIndex $complete
Check 'complete version: nothing opened' ($t.State.issues.Count -eq 0) (Summary $t)

# 7. Lookahead: the last event 41 days away opens its issue once; the next run adds no comment.
$t = New-Tracker
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-03-20T12:37:00Z') -Issues $t -GetIndex $complete -Mention '@BHoM/release-team'
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-03-21T12:37:00Z') -Issues $t -GetIndex $complete -Mention '@BHoM/release-team'
Check 'lookahead opens once, no comment' ($t.State.issues.Count -eq 1 -and $t.State.issues[0].title -ceq 'Calendar runs out on 2027-04-30' -and $t.State.comments.Count -eq 0) (Summary $t)

# 8. Lookahead at 42 days does not open.
$t = New-Tracker
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-03-19T12:37:00Z') -Issues $t -GetIndex $complete
Check 'last event 42 days away: no lookahead issue' ($t.State.issues.Count -eq 0) (Summary $t)

# 9. An issue with the same title opened by someone else does not silence the watcher.
$t = New-Tracker
$t.State.issues.Add([pscustomobject]@{ number = 1; title = 'NuGet 10.1.0-alpha.1.0 incomplete on nuget.org'; body = '<!-- bhom-release-missing: BHoM.Engine -->'; open = $true; user = 'someone' })
$nuget = New-NuGet @{ 'BHoM' = $all; 'BHoM.Engine' = @(); 'BHoM.UI' = $all }
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-16T12:37:00Z') -Issues $t -GetIndex $nuget
Check 'same-titled issue by another user is ignored' (@($t.State.issues | Where-Object { $_.user -eq 'github-actions[bot]' }).Count -eq 1) (Summary $t)

# 10. A closed issue does not count: the watcher opens a new one.
$t = New-Tracker
$t.State.issues.Add([pscustomobject]@{ number = 1; title = 'NuGet 10.1.0-alpha.1.0 incomplete on nuget.org'; body = '<!-- bhom-release-missing: BHoM.Engine -->'; open = $false; user = 'github-actions[bot]' })
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-01-16T12:37:00Z') -Issues $t -GetIndex $nuget
Check 'closed issue: a new one opens' (@($t.State.issues | Where-Object { $_.open }).Count -eq 1) (Summary $t)

# 12. Inactivity: a newest commit 44 days old opens nothing; at 45 days one issue opens, mentioning the
# team and naming day 60, and the next run adds nothing.
$t = New-Tracker
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-02-28T12:37:00Z') -Issues $t -GetIndex $complete -LastCommit (At '2027-01-15T23:59:00Z')
Check 'newest commit 44 days old: no issue' ($t.State.issues.Count -eq 0) (Summary $t)
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-03-01T12:37:00Z') -Issues $t -GetIndex $complete -LastCommit (At '2027-01-15T23:59:00Z') -Mention '@BHoM/release-team'
$a = Invoke-WatchCheck -Calendar $calendar -Config $config -Now (At '2027-03-02T12:37:00Z') -Issues $t -GetIndex $complete -LastCommit (At '2027-01-15T23:59:00Z') -Mention '@BHoM/release-team'
Check 'newest commit 45 days old: one issue, once' ($t.State.issues.Count -eq 1 -and $t.State.issues[0].title -ceq 'Scheduled runs stop on 2027-03-16' -and $t.State.issues[0].body -like '@BHoM/release-team The newest commit on main is 45 days old.*' -and $t.State.comments.Count -eq 0) (Summary $t)

# 13. A nuget.org error on a day with a recent event still leaves the inactivity issue opened.
$t = New-Tracker
$threw = $false
try { Invoke-WatchCheck -Calendar @(Ev '2027-02-26' '10.1.0-alpha.4.0') -Config $config -Now (At '2027-03-01T12:37:00Z') -Issues $t -GetIndex { throw 'nuget.org unavailable' } -LastCommit (At '2027-01-15T23:59:00Z') | Out-Null }
catch { $threw = $true }
Check 'nuget.org error: inactivity issue still opens' ($threw -and $t.State.issues.Count -eq 1 -and $t.State.issues[0].title -ceq 'Scheduled runs stop on 2027-03-16') (Summary $t)

# 11. The entry point, run the way watch.yml runs it: a fresh process in the repository root that imports
# only Watch.psm1 and takes the mention and run URL from the environment. The calendar is planted with one
# event dated today, and nuget.org and the issue tracker are stubs, so nothing touches the network.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "watch-test-$PID"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$saved = @{ WATCH_TEST_CALENDAR = $env:WATCH_TEST_CALENDAR; GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY; GITHUB_TOKEN = $env:GITHUB_TOKEN; MENTION = $env:MENTION; RUN_URL = $env:RUN_URL }
try {
    $today = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $env:WATCH_TEST_CALENDAR = Join-Path $tmp 'calendar.json'
    Set-Content -LiteralPath $env:WATCH_TEST_CALENDAR -Value "[ { `"date`": `"$today`", `"version`": `"10.1.0-alpha.1.0`" } ]"
    $env:GITHUB_REPOSITORY = 'BHoM/nuget-publishing'; $env:GITHUB_TOKEN = 'not-a-token'; $env:MENTION = '@BHoM/release-team'; $env:RUN_URL = 'the-run-url'
    $step = @'
$ErrorActionPreference = 'Stop'
Import-Module ./scripts/Watch.psm1
$opened = [System.Collections.Generic.List[string]]::new()
$issues = [pscustomobject]@{
    FindOpen = { $null }
    Comments = { @() }
    Open     = { param($Title, $Body) $opened.Add("$Title | $Body") }.GetNewClosure()
    Comment  = { throw 'unexpected comment' }
}
Invoke-Watch -CalendarPath $env:WATCH_TEST_CALENDAR -ConfigPath config/repos.json -GetIndex { $null } -Issues $issues
$opened | ForEach-Object { Write-Host "OPENED $_" }
'@
    $stepFile = Join-Path $tmp 'step.ps1'
    Set-Content -LiteralPath $stepFile -Value $step
    $shell = (Get-Process -Id $PID).Path
    Push-Location -LiteralPath $root
    try { $out = (& $shell -NoProfile -NonInteractive -File $stepFile 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { Pop-Location }
    $ok = $code -eq 0 -and $out -like "*opened 'NuGet 10.1.0-alpha.1.0 incomplete on nuget.org'*" -and $out -like "*opened 'Calendar runs out on $today'*" -and $out -notlike '*Scheduled runs stop*' -and
        $out -like '*OPENED NuGet 10.1.0-alpha.1.0 incomplete on nuget.org | @BHoM/release-team 16 of 16 packages*Checked by the-run-url.*'
    Check 'Invoke-Watch as watch.yml calls it: reads the calendar, config and environment, opens both issues' $ok "exit $code$(if (-not $ok) { "`n$out" })"
}
finally {
    foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

Write-Host "PowerShell $($PSVersionTable.PSVersion): 14 cases, $failures failed."
if ($failures -gt 0) { exit 1 }
