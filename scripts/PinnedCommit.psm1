Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pins a repository to the commit its default branch pointed at just before a cutoff.
#
# The primary source is the repository activity log: the "after" SHA of the newest update to the branch
# timestamped before the cutoff. The log records actual branch movements with a server timestamp. The
# commits API is not used to choose the pin, because it lists every ancestor of today's head by date,
# so a pull request merged after the cutoff that carries commits dated before it yields a commit that
# was never the branch head at the cutoff.
#
# Two sanity checks, both through the compare API: the pin is an ancestor of (or equal to) today's
# branch head, and its committer date is at or before the cutoff. The log must also be continuous at
# the pin: the next update's "before" is the pin, or, if there is no later update, today's head is the
# pin. That catches a gap in the log and two same-second updates listed in the wrong order. Anything
# unexpected throws, so a caller never receives a pin it cannot trust.

$script:ApiRoot = 'https://api.github.com/'
$script:ZeroSha = '0000000000000000000000000000000000000000'
$script:Branch = 'develop'

function ConvertTo-UtcOffset($Value, [string]$What) {
    # PowerShell 7's ConvertFrom-Json turns ISO 8601 strings into DateTime values; 5.1 leaves strings.
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw "$What has a time with no zone: $Value" }
        return [DateTimeOffset]$Value.ToUniversalTime()
    }
    if ($Value -is [string] -and $Value -match '(Z|[+-][0-9]{2}:[0-9]{2})\z') {
        return [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    }
    throw "$What is not a UTC timestamp: '$Value'"
}

function Format-Utc([DateTimeOffset]$Value) {
    return $Value.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-GitHubGet {
    <#
    .SYNOPSIS
    Fetches a URL under api.github.com and returns its parsed body and Link header. Uses GH_TOKEN when set.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    if (-not $Url.StartsWith($script:ApiRoot, [StringComparison]::Ordinal)) { throw "Refusing to fetch ${Url}: not under $script:ApiRoot" }
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($env:GH_TOKEN) { $headers.Authorization = "Bearer $env:GH_TOKEN" }
    $r = Invoke-WebRequest -Method Get -Uri $Url -Headers $headers -UseBasicParsing
    $link = $null
    if ($r.Headers.ContainsKey('Link')) { $link = @($r.Headers['Link']) -join ',' }
    $body = ConvertFrom-Json -InputObject $r.Content
    return [pscustomobject]@{ Body = $body; Link = $link }
}

function Get-NextLink {
    <#
    .SYNOPSIS
    Returns the rel="next" URL from a Link header, or $null when there is none.
    #>
    [CmdletBinding()]
    param([string]$Link)
    if ([string]::IsNullOrEmpty($Link)) { return $null }
    foreach ($part in $Link -split ',') {
        if ($part -match '<([^>]+)>\s*;\s*rel="next"') { return $Matches[1] }
    }
    return $null
}

function Resolve-PinnedCommit {
    <#
    .SYNOPSIS
    Returns the commit a repository's develop branch pointed at just before the cutoff, or throws.

    .DESCRIPTION
    If the branch moved between the activity read and the compare call, the newest logged update no
    longer equals today's head. The whole pin is read again once, so the new update is in the log;
    if it still fails, the pin is refused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][DateTimeOffset]$Cutoff,
        [scriptblock]$ApiGet = { param($Url) Invoke-GitHubGet -Url $Url },
        [int]$MaxPages = 10,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    try {
        return Resolve-PinnedCommitOnce -Repo $Repo -Cutoff $Cutoff -ApiGet $ApiGet -MaxPages $MaxPages -Now $Now
    }
    catch {
        if (-not $_.Exception.Data['HeadMoved']) { throw }
        Write-Host "$($_.Exception.Message) Reading the pin again once."
    }
    try {
        return Resolve-PinnedCommitOnce -Repo $Repo -Cutoff $Cutoff -ApiGet $ApiGet -MaxPages $MaxPages -Now $Now
    }
    catch {
        if (-not $_.Exception.Data['HeadMoved']) { throw }
        throw "$($_.Exception.Message.TrimEnd('.')), after one retry."
    }
}

function Resolve-PinnedCommitOnce {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][DateTimeOffset]$Cutoff,
        [Parameter(Mandatory)][scriptblock]$ApiGet,
        [Parameter(Mandatory)][int]$MaxPages,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )
    $cutoffIso = Format-Utc $Cutoff
    if ($Cutoff -gt $Now) { throw "${Repo}: cutoff $cutoffIso is in the future, so the branch can still move before it." }
    if ($Repo -notmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw "'$Repo' is not an owner/name repository." }

    $meta = (& $ApiGet "$($script:ApiRoot)repos/$Repo").Body
    if ($meta.private -ne $false) { throw "$Repo is not public." }
    $branch = [string]$meta.default_branch
    if ([string]::IsNullOrEmpty($branch)) { throw "${Repo}: no default branch reported." }
    if ($branch -cne $script:Branch) { throw "${Repo}: default branch is $branch, not $script:Branch, and the release builds $script:Branch." }
    $ref = "refs/heads/$branch"

    $first = "$($script:ApiRoot)repos/$Repo/activity?ref=$([uri]::EscapeDataString($ref))&per_page=100&direction=desc"
    $nextPrefix = "$($script:ApiRoot)repos/$Repo/activity?"
    $url = $first
    $pages = 0
    $found = $null
    $oldest = $null
    $previous = $null
    $last = $null
    $newer = $null
    while ($url) {
        $pages++
        if ($pages -gt $MaxPages) { throw "${Repo}: the activity walk did not reach $cutoffIso within $MaxPages pages." }
        $response = & $ApiGet $url
        foreach ($entry in @($response.Body)) {
            if ($null -eq $entry) { continue }
            if ($entry.ref -cne $ref) { throw "${Repo}: activity entry for '$($entry.ref)' in a walk filtered on $ref." }
            $at = ConvertTo-UtcOffset $entry.timestamp "$Repo activity timestamp"
            if ($previous -and $at -gt $previous) { throw "${Repo}: activity log is not in descending time order at $($at.UtcDateTime.ToString('o'))." }
            $previous = $at
            $oldest = $entry
            if ($at -lt $Cutoff) { $found = $entry; $newer = $last; break }
            $last = $entry
        }
        if ($found) { break }
        $url = Get-NextLink $response.Link
        if ($url -and -not $url.StartsWith($nextPrefix, [StringComparison]::Ordinal)) { throw "${Repo}: next page link points outside the activity endpoint: $url" }
    }

    if (-not $found) {
        if ($null -eq $oldest) { throw "${Repo}: no activity recorded for $ref, so the walk cannot reach $cutoffIso." }
        $oldestAt = Format-Utc (ConvertTo-UtcOffset $oldest.timestamp 'oldest entry')
        if ($oldest.activity_type -eq 'branch_creation') { throw "${Repo}: $branch was created at $oldestAt, after the cutoff $cutoffIso." }
        throw "${Repo}: the activity log for $branch ends at $oldestAt, after the cutoff $cutoffIso, so the head at the cutoff is unknown."
    }

    $sha = [string]$found.after
    if ($found.activity_type -eq 'branch_deletion' -or $sha -eq $script:ZeroSha) { throw "${Repo}: the last update before $cutoffIso deleted $branch." }
    if ($sha -cnotmatch '\A[0-9a-f]{40}\z') { throw "${Repo}: activity entry has no valid 'after' SHA: '$sha'." }
    if ($newer -and [string]$newer.before -cne $sha) {
        throw "${Repo}: the update at $(Format-Utc (ConvertTo-UtcOffset $newer.timestamp 'activity')) does not continue from the pin $sha (it starts from '$($newer.before)'), so the log has a gap or lists same-second updates out of order."
    }

    # The base is the fully qualified ref, so a tag with the branch's name cannot stand in for it.
    $compare = (& $ApiGet "$($script:ApiRoot)repos/$Repo/compare/$([uri]::EscapeDataString($ref))...$sha").Body
    if ($compare.status -notin @('behind', 'identical')) {
        throw "${Repo}: pin $sha is not an ancestor of today's $branch (compare status '$($compare.status)')."
    }
    if (-not $newer -and $compare.status -ne 'identical') {
        $moved = [System.Exception]::new("${Repo}: the pin $sha is the newest update in the log, but today's $branch is not it (compare status '$($compare.status)'), so $branch moved without an entry in the activity log.")
        $moved.Data['HeadMoved'] = $true
        throw $moved
    }
    if ($compare.merge_base_commit.sha -ne $sha) { throw "${Repo}: compare merge base $($compare.merge_base_commit.sha) is not the pin $sha." }
    $committed = ConvertTo-UtcOffset $compare.merge_base_commit.commit.committer.date "$Repo committer date"
    if ($committed -gt $Cutoff) {
        throw "${Repo}: pin $sha has committer date $(Format-Utc $committed), after the cutoff $cutoffIso."
    }

    return [pscustomobject]@{
        repo              = $Repo
        branch            = $branch
        sha               = $sha
        committerDate     = Format-Utc $committed
        activityType      = [string]$found.activity_type
        activityTimestamp = Format-Utc (ConvertTo-UtcOffset $found.timestamp 'activity')
        activityPages     = $pages
        compareStatus     = [string]$compare.status
    }
}

Export-ModuleMember -Function Resolve-PinnedCommit, Invoke-GitHubGet, Get-NextLink
