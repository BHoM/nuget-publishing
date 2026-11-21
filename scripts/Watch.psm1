Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Release.psm1')

# watch.yml, once a day.
#
# 1. Every event dated in the 14 days before today (UTC), skipped or not: are all the packages in
#    repos.json on nuget.org at its version? If not, open "NuGet <version> incomplete on nuget.org"
#    listing the missing IDs, or, if the watcher's issue is already open, comment only when the list
#    differs from the one it last recorded there. Today's events are left out because a scheduled publish
#    run can start hours late, so a version still missing is flagged the following day.
# 2. If the last event is fewer than 42 days away, or past, open "Calendar runs out on <date>" once.
# 3. If the newest commit on main is 45 or more days old, open "Scheduled runs stop on <date>" once.
#    GitHub disables scheduled workflows in a public repository after 60 days without activity.
#
# Only issues opened by the workflow's own account count, so an issue anyone else opens with the same
# title cannot silence the watcher. The missing list is recorded in an HTML comment the watcher reads back.

$script:Bot = 'github-actions[bot]'
$script:Marker = 'bhom-release-missing'

function Get-RecordedMissing([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $m = [regex]::Matches($Text, "<!-- $($script:Marker): ([^>]*) -->")
    if ($m.Count -eq 0) { return $null }
    return $m[$m.Count - 1].Groups[1].Value.Trim()
}

function Invoke-WatchCheck {
    <#
    .SYNOPSIS
    Checks recent events against nuget.org and the calendar's end, and opens or updates issues.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Calendar,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [Parameter(Mandatory)]$Issues,
        [scriptblock]$GetIndex = { param($Url) Invoke-FlatContainerGet -Url $Url },
        [string]$Mention,
        [string]$RunUrl,
        [Nullable[DateTimeOffset]]$LastCommit
    )
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $today = $Now.UtcDateTime.Date
    $from = $today.AddDays(-14).ToString('yyyy-MM-dd', $invariant)
    $to = $today.AddDays(-1).ToString('yyyy-MM-dd', $invariant)
    $lead = if ($Mention) { "$Mention " } else { '' }
    $actions = [System.Collections.Generic.List[string]]::new()

    # First, so that a nuget.org error below cannot stop it.
    if ($null -ne $LastCommit) {
        $committed = $LastCommit.UtcDateTime.Date
        $age = ($today - $committed).TotalDays
        if ($age -ge 45) {
            $stopTitle = "Scheduled runs stop on $($committed.AddDays(60).ToString('yyyy-MM-dd', $invariant))"
            if ($null -eq (& $Issues.FindOpen $stopTitle)) {
                $body = "${lead}The newest commit on main is $age days old. GitHub disables scheduled workflows in a public repository after 60 days without activity, and nothing reports it. Merge a small reviewed change to main before then."
                & $Issues.Open $stopTitle $body | Out-Null
                $actions.Add("opened '$stopTitle'")
            }
            else { $actions.Add("unchanged '$stopTitle'") }
        }
    }

    foreach ($e in @($Calendar | Where-Object { [string]::CompareOrdinal($_.date, $from) -ge 0 -and [string]::CompareOrdinal($_.date, $to) -le 0 })) {
        $missing = Get-MissingPackageId -Config $Config -Version $e.version -Get $GetIndex
        $state = if ($e.skip) { 'marked skip, so this workflow did not publish it' } else { 'published by this workflow' }
        if ($missing.Count -eq 0) { $actions.Add("ok $($e.version)"); continue }
        $list = $missing -join ', '
        $title = "NuGet $($e.version) incomplete on nuget.org"
        $issue = & $Issues.FindOpen $title
        $text = "$($missing.Count) of $(@($Config.repos).Count) packages are not on nuget.org at $($e.version) (event dated $($e.date), $state): $list."
        if ($RunUrl) { $text += " Checked by $RunUrl." }
        if ($null -eq $issue) {
            $body = "$lead$text`n`nClose this by hand once the version is complete.`n`n<!-- $($script:Marker): $list -->"
            & $Issues.Open $title $body | Out-Null
            $actions.Add("opened '$title'")
            continue
        }
        $recorded = Get-RecordedMissing $issue.body
        foreach ($c in @(& $Issues.Comments $issue.number)) {
            if ($c.user -ceq $script:Bot) { $r = Get-RecordedMissing $c.body; if ($null -ne $r) { $recorded = $r } }
        }
        if ($recorded -ceq $list) { $actions.Add("unchanged '$title'"); continue }
        & $Issues.Comment $issue.number "The missing list changed. $text`n`n<!-- $($script:Marker): $list -->" | Out-Null
        $actions.Add("commented on '$title'")
    }

    $last = @($Calendar | Sort-Object { $_.date } | Select-Object -Last 1)
    $lookTitle = if ($last.Count -eq 0) { 'Calendar runs out on (no events)' } else { "Calendar runs out on $($last[0].date)" }
    $runsOut = $last.Count -eq 0 -or ([DateTime]::ParseExact($last[0].date, 'yyyy-MM-dd', $invariant) - $today).TotalDays -lt 42
    if ($runsOut) {
        if ($null -eq (& $Issues.FindOpen $lookTitle)) {
            $body = "${lead}The last event in calendar.json is fewer than 42 days away, or past. Add the next events by a reviewed pull request; a scheduled run with no event publishes nothing."
            & $Issues.Open $lookTitle $body | Out-Null
            $actions.Add("opened '$lookTitle'")
        }
        else { $actions.Add("unchanged '$lookTitle'") }
    }

    return , $actions.ToArray()
}

function Invoke-Watch {
    <#
    .SYNOPSIS
    Runs the watch job. Reads the repository, token, release-team mention and run URL from the environment,
    and the date of the newest commit from the checkout.

    .DESCRIPTION
    -Issues and -GetIndex exist so tests can run without the network.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CalendarPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [scriptblock]$GetIndex = { param($Url) Invoke-FlatContainerGet -Url $Url },
        $Issues
    )
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $calendar = Read-ReleaseCalendar -Path $CalendarPath
    if (-not $Issues) { $Issues = New-GitHubIssueClient -Repository $env:GITHUB_REPOSITORY -Token $env:GITHUB_TOKEN }
    $committed = git log -1 --format=%cI
    if ($LASTEXITCODE -ne 0) { throw "git log failed with exit $LASTEXITCODE, so the age of the newest commit is unknown." }
    if (-not $env:MENTION) { Write-Host '::warning title=No release-team mention::The RELEASE_TEAM_MENTION variable is not set, so issues mention nobody.' }
    $actions = Invoke-WatchCheck -Calendar $calendar -Config $config -Now ([DateTimeOffset]::UtcNow) -Issues $Issues -GetIndex $GetIndex -Mention $env:MENTION -RunUrl $env:RUN_URL -LastCommit ([DateTimeOffset]::Parse($committed, [Globalization.CultureInfo]::InvariantCulture))
    $actions | ForEach-Object { Write-Host $_ }
}

function New-GitHubIssueClient {
    <#
    .SYNOPSIS
    Returns the issue calls for the workflow's own repository, made through the REST API with the run's token.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Token)
    $api = "https://api.github.com/repos/$Repository"
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; Authorization = "Bearer $Token" }
    $getAll = {
        param($Url)
        $items = [System.Collections.Generic.List[object]]::new()
        $next = $Url
        for ($page = 1; $next; $page++) {
            if ($page -gt 10) { throw "More than 10 pages from $Url." }
            $r = Invoke-WebRequest -Method Get -Uri $next -Headers $headers -UseBasicParsing
            foreach ($i in @(ConvertFrom-Json -InputObject $r.Content)) { foreach ($x in @($i)) { $items.Add($x) } }
            $next = $null
            if ($r.Headers.ContainsKey('Link')) {
                foreach ($part in (@($r.Headers['Link']) -join ',') -split ',') { if ($part -match '<([^>]+)>\s*;\s*rel="next"') { $next = $Matches[1] } }
            }
            if ($next -and -not $next.StartsWith("$api/", [StringComparison]::Ordinal)) { throw "Next page link leaves ${api}: $next" }
        }
        return , $items.ToArray()
    }.GetNewClosure()
    $post = {
        param($Url, $Payload)
        Invoke-RestMethod -Method Post -Uri $Url -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Compress)))
    }.GetNewClosure()
    $bot = $script:Bot
    return [pscustomobject]@{
        FindOpen = {
            param($Title)
            $open = & $getAll "$api/issues?state=open&per_page=100"
            $hit = @($open | Where-Object { -not $_.PSObject.Properties['pull_request'] -and $_.title -ceq $Title -and $_.user.login -ceq $bot })
            if ($hit.Count -eq 0) { return $null }
            return [pscustomobject]@{ number = $hit[0].number; body = [string]$hit[0].body }
        }.GetNewClosure()
        Comments = {
            param($Number)
            @(& $getAll "$api/issues/$Number/comments?per_page=100" | ForEach-Object { [pscustomobject]@{ user = $_.user.login; body = [string]$_.body } })
        }.GetNewClosure()
        Open    = { param($Title, $Body) & $post "$api/issues" @{ title = $Title; body = $Body } }.GetNewClosure()
        Comment = { param($Number, $Body) & $post "$api/issues/$Number/comments" @{ body = $Body } }.GetNewClosure()
    }
}

Export-ModuleMember -Function Invoke-WatchCheck, Invoke-Watch, New-GitHubIssueClient
