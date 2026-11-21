Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Release.psm1')

# The plan job: chooses the events a run of publish-nuget.yml builds.
#
#   schedule           every event dated today (UTC) that is not skipped and whose cutoff has passed; none
#                      is a normal day. A late run created after midnight selects nothing for the new day.
#   workflow_dispatch  the one event with that version: dated today or earlier, not skipped, and not
#                      already complete on nuget.org. A rehearsal waives the date and completeness rules
#                      but not skip, and pins at the earlier of the event's cutoff and the run's start.
#
# Each event is pinned at <date>T05:00:00Z. Same-day events come out alpha first.
#
# Plan also tells publish whether the run needs approval (it does unless every event is an alpha) and
# the UTC day it ran, and it refuses to run a second time in one run: a re-run would read the calendar
# of the day the run was first started.

function Select-ReleaseEvent {
    <#
    .SYNOPSIS
    Returns the calendar events a run builds, each with its cutoff, or throws saying why a manual run is refused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Calendar,
        [Parameter(Mandatory)][ValidateSet('schedule', 'workflow_dispatch')][string]$EventName,
        [string]$Version,
        [bool]$Rehearsal = $false,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [scriptblock]$IsComplete = { param($Version) throw 'no completeness check supplied' }
    )
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $today = $Now.UtcDateTime.ToString('yyyy-MM-dd', $invariant)
    $nowSeconds = [DateTimeOffset]::new($Now.UtcDateTime.Ticks - ($Now.UtcDateTime.Ticks % [TimeSpan]::TicksPerSecond), [TimeSpan]::Zero)

    function New-PlannedEvent($e, [DateTimeOffset]$Cutoff) {
        [pscustomobject][ordered]@{
            version = $e.version
            date    = $e.date
            sprint  = $e.sprint
            cutoff  = $Cutoff.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $invariant)
        }
    }
    function Get-Cutoff($e) { [DateTimeOffset]::ParseExact("$($e.date)T05:00:00Z", "yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant, [Globalization.DateTimeStyles]::AssumeUniversal) }

    if ($EventName -eq 'schedule') {
        $due = @($Calendar | Where-Object { $_.date -ceq $today -and -not $_.skip -and (Get-Cutoff $_) -le $nowSeconds })
        $ordered = @($due | Where-Object { (Get-ReleaseKind $_.version) -eq 'alpha' }) + @($due | Where-Object { (Get-ReleaseKind $_.version) -eq 'beta' })
        return , @($ordered | ForEach-Object { New-PlannedEvent $_ (Get-Cutoff $_) })
    }

    if ([string]::IsNullOrWhiteSpace($Version)) { throw 'A manual run needs a version.' }
    $match = @($Calendar | Where-Object { $_.version -ceq $Version })
    if ($match.Count -eq 0) { throw "Version $Version is not in calendar.json." }
    $e = $match[0]
    if ($e.skip) { throw "Version $Version is marked skip in calendar.json, so this workflow does not publish it." }
    $cutoff = Get-Cutoff $e
    if ($Rehearsal) {
        if ($nowSeconds -lt $cutoff) { $cutoff = $nowSeconds }
        return , @(New-PlannedEvent $e $cutoff)
    }
    if ([string]::CompareOrdinal($e.date, $today) -gt 0) { throw "Version $Version is dated $($e.date), after today ($today)." }
    if ($cutoff -gt $nowSeconds) { throw "Version $Version is pinned at $($cutoff.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $invariant)), which has not passed yet." }
    if (& $IsComplete $Version) { throw "Version $Version is already complete on nuget.org: every package in repos.json is listed at it." }
    return , @(New-PlannedEvent $e $cutoff)
}

function Test-AlphaOnly {
    <#
    .SYNOPSIS
    Returns true when a run has events and every one is an alpha, the only case publish runs without approval.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events)
    return $Events.Count -gt 0 -and @($Events | Where-Object { (Get-ReleaseKind $_.version) -ne 'alpha' }).Count -eq 0
}

function Invoke-Plan {
    <#
    .SYNOPSIS
    Runs the plan job: reads the run's context from the environment and writes the job's outputs.
    -Now exists so tests do not depend on the time of day.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CalendarPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    if ($env:GITHUB_RUN_ATTEMPT -and $env:GITHUB_RUN_ATTEMPT -ne '1') {
        throw "This is attempt $env:GITHUB_RUN_ATTEMPT of the run, and plan runs once only. Start a new run, so that it reads today's calendar."
    }
    $eventName = $env:GITHUB_EVENT_NAME
    $rehearsal = $false
    if ($eventName -eq 'workflow_dispatch') {
        if ($env:INPUT_REHEARSAL -notin @('true', 'false')) { throw "rehearsal input must be true or false, got '$env:INPUT_REHEARSAL'." }
        $rehearsal = $env:INPUT_REHEARSAL -eq 'true'
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $calendar = Read-ReleaseCalendar -Path $CalendarPath
    $isComplete = { param($v) (Get-MissingPackageId -Config $config -Version $v).Count -eq 0 }
    $events = Select-ReleaseEvent -Calendar $calendar -EventName $eventName -Version $env:INPUT_VERSION -Rehearsal $rehearsal -Now $now -IsComplete $isComplete
    $json = ConvertTo-Json -InputObject @($events) -Compress -Depth 3
    if (@($events).Count -eq 0) { $json = '[]' }
    Write-ActionOutput -Name 'events' -Value $json
    Write-ActionOutput -Name 'rehearsal' -Value $(if ($rehearsal) { 'true' } else { 'false' })
    $approval = if (Test-AlphaOnly -Events @($events)) { 'false' } else { 'true' }
    Write-ActionOutput -Name 'approval' -Value $approval
    Write-ActionOutput -Name 'planned_on' -Value $now.UtcDateTime.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    if ($env:GITHUB_STEP_SUMMARY) {
        $lines = @('## Plan', '', "Trigger: $eventName. Rehearsal: $rehearsal.", '')
        if (@($events).Count -eq 0) { $lines += 'No event today.' }
        else {
            $lines += @($events | ForEach-Object { "- $($_.version), dated $($_.date), pinned at $($_.cutoff)" })
            $lines += @('', $(if ($approval -eq 'false') { 'Alphas only: publish runs without approval.' } else { 'Publish waits for approval.' }))
        }
        $lines | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
    }
}

Export-ModuleMember -Function Select-ReleaseEvent, Test-AlphaOnly, Invoke-Plan
