<#
Offline tests for Resolve-PinnedCommit. Each case serves recorded or planted API responses through a
fake ApiGet, so nothing touches the network. The BHoM_Engine entries are the three newest develop
updates as recorded from the activity API on 2026-11-11.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/PinnedCommit.psm1') -Force

$api = 'https://api.github.com/repos'
$repo = 'BHoM/BHoM_Engine'
$activity = "$api/$repo/activity?ref=refs%2Fheads%2Fdevelop&per_page=100&direction=desc"
$now = [DateTimeOffset]::Parse('2026-11-12T00:00:00Z')

$sha = @{
    merge1105 = 'b5984c7a8a4209005f53b06341e214095bb0afbe'
    merge1027 = '182d37161fbd28d733331c89b2da033a21e6bf9d'
    merge0925 = 'a32beec1eb50736182c9b72bef8554b537efd1a8'
    merge0911 = '0456b6f32f0477db4c16e5ce185ef94a40fa89d5'
    prBranch  = '96c720586fe9000000000000000000000000beef'
    unseen    = '1111111111111111111111111111111111111111'
}

function New-Entry([string]$At, [string]$After, [string]$Type = 'pr_merge', [string]$Ref = 'refs/heads/develop', [string]$Before = $sha.merge0925) {
    [pscustomobject]@{ ref = $Ref; timestamp = $At; activity_type = $Type; before = $Before; after = $After }
}
$recorded = @(
    (New-Entry '2026-11-05T14:04:10Z' $sha.merge1105 -Before $sha.merge1027),
    (New-Entry '2026-10-27T12:50:16Z' $sha.merge1027 -Before $sha.merge0925),
    (New-Entry '2026-09-25T11:57:36Z' $sha.merge0925 -Before $sha.merge0911)
)
function New-Compare([string]$Status, [string]$Base, [string]$Committed) {
    [pscustomobject]@{ status = $Status; merge_base_commit = [pscustomobject]@{ sha = $Base; commit = [pscustomobject]@{ committer = [pscustomobject]@{ date = $Committed } } } }
}

function New-Api([hashtable]$Routes, [string]$DefaultBranch = 'develop') {
    $r = $Routes
    $r["$api/$repo"] = [pscustomobject]@{ Body = [pscustomobject]@{ private = $false; default_branch = $DefaultBranch }; Link = $null }
    return { param($Url) if (-not $r.ContainsKey($Url)) { throw "unexpected request $Url" }; $v = $r[$Url]; if ($v -is [scriptblock]) { & $v } else { $v } }.GetNewClosure()
}
# A route that serves its responses in order, once each, and throws on any further request.
function Seq([object[]]$Responses) {
    $state = @{ i = 0; r = $Responses }
    return { if ($state.i -ge $state.r.Count) { throw "served $($state.r.Count) time(s) already" }; $x = $state.r[$state.i]; $state.i++; $x }.GetNewClosure()
}
function Page($Entries, [string]$Next) {
    $link = if ($Next) { "<$Next>; rel=`"next`"" } else { $null }
    [pscustomobject]@{ Body = @($Entries); Link = $link }
}
function Body($Value) { [pscustomobject]@{ Body = $Value; Link = $null } }

$cases = @(
    @{
        Name = 'late merge: cutoff 2026-11-04T14:59:05Z returns the develop head at the cutoff (182d371), not the PR commit dated 11-03'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page $recorded $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Body (New-Compare 'behind' $sha.merge1027 '2026-10-27T12:50:16Z')) }
        Expect = $sha.merge1027
    },
    @{
        Name = 'cutoff 2026-11-06T05:00:00Z, after the newest update, returns the 11-05 merge'
        Cutoff = '2026-11-06T05:00:00Z'
        Routes = @{ $activity = (Page $recorded $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1105)" = (Body (New-Compare 'identical' $sha.merge1105 '2026-11-05T14:04:09Z')) }
        Expect = $sha.merge1105
    },
    @{
        Name = 'entry before the cutoff found on page 2'
        Cutoff = '2026-10-01T00:00:00Z'
        Routes = @{ $activity = (Page $recorded[0..1] "$api/$repo/activity?ref=refs%2Fheads%2Fdevelop&per_page=100&direction=desc&after=c2"); "$api/$repo/activity?ref=refs%2Fheads%2Fdevelop&per_page=100&direction=desc&after=c2" = (Page $recorded[2] $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge0925)" = (Body (New-Compare 'behind' $sha.merge0925 '2026-09-25T11:57:36Z')) }
        Expect = $sha.merge0925
    },
    @{
        Name = 'cutoff older than the history: walk ends without reaching it'
        Cutoff = '2023-01-01T00:00:00Z'
        Routes = @{ $activity = (Page $recorded $null) }
        Refuse = 'ends at 2026-09-25T11:57:36Z, after the cutoff'
    },
    @{
        Name = 'no activity at all'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page @() $null) }
        Refuse = 'no activity recorded'
    },
    @{
        Name = 'branch created after the cutoff'
        Cutoff = '2026-09-01T00:00:00Z'
        Routes = @{ $activity = (Page @($recorded[0], (New-Entry '2026-09-25T11:57:36Z' $sha.merge0925 'branch_creation')) $null) }
        Refuse = 'was created at'
    },
    @{
        Name = 'walk needs more than 10 pages'
        Cutoff = '2023-01-01T00:00:00Z'
        MaxPages = 10
        Routes = @{ $activity = (Page $recorded[0] $activity) }
        Refuse = 'within 10 pages'
    },
    @{
        Name = 'sanity: pin not an ancestor of today''s head (diverged)'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page $recorded $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Body (New-Compare 'diverged' $sha.merge0925 '2026-10-27T12:50:16Z')) }
        Refuse = 'is not an ancestor'
    },
    @{
        Name = 'sanity: committer date after the cutoff'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page $recorded $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Body (New-Compare 'behind' $sha.merge1027 '2026-11-04T15:00:00Z')) }
        Refuse = 'after the cutoff 2026-11-04T14:59:05Z'
    },
    @{
        Name = 'sanity: compare merge base is not the pin'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page $recorded $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Body (New-Compare 'behind' $sha.merge0925 '2026-10-27T12:50:16Z')) }
        Refuse = 'is not the pin'
    },
    @{
        Name = 'last update before the cutoff deleted the branch'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page @($recorded[0], (New-Entry '2026-10-27T12:50:16Z' '0000000000000000000000000000000000000000' 'branch_deletion')) $null) }
        Refuse = 'deleted develop'
    },
    @{
        Name = 'activity log out of time order'
        Cutoff = '2026-09-01T00:00:00Z'
        Routes = @{ $activity = (Page @($recorded[1], $recorded[0]) $null) }
        Refuse = 'not in descending time order'
    },
    @{
        Name = 'entry for another ref'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page @((New-Entry '2026-10-27T12:50:16Z' $sha.merge1027 'push' 'refs/heads/main')) $null) }
        Refuse = 'in a walk filtered on refs/heads/develop'
    },
    @{
        Name = 'next link leaves the activity endpoint'
        Cutoff = '2023-01-01T00:00:00Z'
        Routes = @{ $activity = (Page $recorded[0] 'https://api.github.com/repos/someone/else/activity?after=x') }
        Refuse = 'outside the activity endpoint'
    },
    @{
        Name = 'cutoff in the future'
        Cutoff = '2026-11-13T05:00:00Z'
        Routes = @{}
        Refuse = 'is in the future'
    },
    @{
        Name = 'default branch is not develop, so the pin would be another branch''s head'
        Cutoff = '2026-11-04T14:59:05Z'
        DefaultBranch = 'main'
        Routes = @{ "$api/$repo/activity?ref=refs%2Fheads%2Fmain&per_page=100&direction=desc" = (Page @((New-Entry '2026-10-27T12:50:16Z' $sha.prBranch 'push' 'refs/heads/main')) $null); "$api/$repo/compare/refs%2Fheads%2Fmain...$($sha.prBranch)" = (Body (New-Compare 'identical' $sha.prBranch '2026-10-27T12:50:16Z')) }
        Refuse = 'default branch is main, not develop'
    },
    @{
        Name = 'entry for refs/heads/Develop (case differs) in a develop walk'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page @((New-Entry '2026-10-27T12:50:16Z' $sha.merge1027 'push' 'refs/heads/Develop')) $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Body (New-Compare 'identical' $sha.merge1027 '2026-10-27T12:50:16Z')) }
        Refuse = 'in a walk filtered on refs/heads/develop'
    },
    @{
        Name = 'two updates in the same second listed in the wrong order'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page @((New-Entry '2026-11-05T14:04:10Z' $sha.merge1105 -Before $sha.prBranch), (New-Entry '2026-10-27T12:50:16Z' $sha.merge1027 -Before $sha.prBranch), (New-Entry '2026-10-27T12:50:16Z' $sha.prBranch 'push' -Before $sha.merge1027)) $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Body (New-Compare 'behind' $sha.merge1027 '2026-10-27T12:50:16Z')) }
        Refuse = 'does not continue from'
    },
    @{
        Name = 'an update missing from the log just after the pin'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page @((New-Entry '2026-11-05T14:04:10Z' $sha.merge1105 -Before $sha.unseen), $recorded[1]) $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Body (New-Compare 'behind' $sha.merge1027 '2026-10-27T12:50:16Z')) }
        Refuse = 'does not continue from'
    },
    @{
        Name = 'newest logged update is the pin but today''s head has moved without a log entry'
        Cutoff = '2026-11-06T05:00:00Z'
        Routes = @{ $activity = (Page $recorded $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1105)" = (Body (New-Compare 'behind' $sha.merge1105 '2026-11-05T14:04:09Z')) }
        Refuse = 'moved without an entry in the activity log'
    },
    @{
        Name = 'times in the result use a colon under a culture whose time separator is a full stop (fi-FI)'
        Cutoff = '2026-11-04T14:59:05Z'
        Culture = 'fi-FI'
        Routes = @{ $activity = (Page $recorded $null); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Body (New-Compare 'behind' $sha.merge1027 '2026-10-27T12:50:16Z')) }
        Expect = $sha.merge1027
        ExpectCommitted = '2026-10-27T12:50:16Z'
    },
    @{
        Name = 'the compare names refs/heads/develop, so a tag called develop cannot answer it'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Page $recorded $null); "$api/$repo/compare/develop...$($sha.merge1027)" = (Body (New-Compare 'identical' $sha.merge1027 '2026-10-27T12:50:16Z')); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Body (New-Compare 'diverged' $sha.merge0925 '2026-10-27T12:50:16Z')) }
        Refuse = 'is not an ancestor'
    },
    @{
        Name = 'head moved between the activity read and the compare; one retry of the whole pin succeeds'
        Cutoff = '2026-11-06T05:00:00Z'
        Routes = @{
            $activity = (Seq @((Page $recorded $null), (Page (@((New-Entry '2026-11-11T23:00:00Z' $sha.unseen 'push' -Before $sha.merge1105)) + $recorded) $null)))
            "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1105)" = (Seq @((Body (New-Compare 'behind' $sha.merge1105 '2026-11-05T14:04:09Z')), (Body (New-Compare 'behind' $sha.merge1105 '2026-11-05T14:04:09Z'))))
        }
        Expect = $sha.merge1105
    },
    @{
        Name = 'head still moved without a log entry after one retry fails closed, and retries only once'
        Cutoff = '2026-11-06T05:00:00Z'
        Routes = @{
            $activity = (Seq @((Page $recorded $null), (Page $recorded $null)))
            "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1105)" = (Seq @((Body (New-Compare 'behind' $sha.merge1105 '2026-11-05T14:04:09Z')), (Body (New-Compare 'behind' $sha.merge1105 '2026-11-05T14:04:09Z'))))
        }
        Refuse = 'moved without an entry in the activity log, after one retry'
    },
    @{
        Name = 'other sanity failures are not retried'
        Cutoff = '2026-11-04T14:59:05Z'
        Routes = @{ $activity = (Seq @((Page $recorded $null))); "$api/$repo/compare/refs%2Fheads%2Fdevelop...$($sha.merge1027)" = (Seq @((Body (New-Compare 'diverged' $sha.merge0925 '2026-10-27T12:50:16Z')))) }
        Refuse = 'is not an ancestor'
    }
)

$failures = 0
foreach ($c in $cases) {
    $branch = if ($c.ContainsKey('DefaultBranch')) { $c.DefaultBranch } else { 'develop' }
    $apiGet = New-Api $c.Routes $branch
    $max = if ($c.ContainsKey('MaxPages')) { $c.MaxPages } else { 10 }
    $savedCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        if ($c.ContainsKey('Culture')) { [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($c.Culture) }
        $pin = Resolve-PinnedCommit -Repo $repo -Cutoff ([DateTimeOffset]::Parse($c.Cutoff, [Globalization.CultureInfo]::InvariantCulture)) -ApiGet $apiGet -MaxPages $max -Now $now
        [Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
        $timesOk = -not $c.ContainsKey('ExpectCommitted') -or $pin.committerDate -ceq $c.ExpectCommitted
        if ($c.ContainsKey('Expect') -and $pin.sha -eq $c.Expect -and $timesOk) { Write-Host "PASS  $($c.Name) -> $($pin.sha) committed $($pin.committerDate)" }
        else { $failures++; Write-Host "FAIL  $($c.Name): returned $($pin.sha) committed $($pin.committerDate)" }
    }
    catch {
        [Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
        $msg = $_.Exception.Message
        if ($c.ContainsKey('Refuse') -and $msg -like "*$($c.Refuse)*") { Write-Host "PASS  $($c.Name) -> refused: $msg" }
        else { $failures++; Write-Host "FAIL  $($c.Name): threw $msg" }
    }
}
Write-Host "PowerShell $($PSVersionTable.PSVersion): $($cases.Count) cases, $failures failed."
if ($failures -gt 0) { exit 1 }
