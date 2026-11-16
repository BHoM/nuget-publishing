Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared by plan, validate, verify and the watcher: reading calendar.json, and asking nuget.org's flat
# container which versions of a package it lists. Run Test-Calendar.ps1 first; this reader assumes a
# calendar that passed it, and only normalises what PowerShell 7's ConvertFrom-Json may have changed.

$script:Invariant = [Globalization.CultureInfo]::InvariantCulture

function Read-ReleaseCalendar {
    <#
    .SYNOPSIS
    Reads calendar.json into events with date, version, sprint and skip.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return , @(foreach ($e in @($raw)) {
            if ($null -eq $e) { continue }
            # PowerShell 7 may turn "2027-01-15" into a DateTime; write it back as the date it was.
            $date = if ($e.date -is [DateTime]) { $e.date.ToString('yyyy-MM-dd', $script:Invariant) } else { [string]$e.date }
            $names = @($e.PSObject.Properties | ForEach-Object { $_.Name })
            [pscustomobject]@{
                date    = $date
                version = [string]$e.version
                sprint  = $(if ($names -ccontains 'sprint') { [int]$e.sprint } else { 0 })
                skip    = $(if ($names -ccontains 'skip') { [bool]$e.skip } else { $false })
            }
        })
}

function Get-ReleaseKind {
    <#
    .SYNOPSIS
    Returns the kind of a calendar version: alpha or beta.
    #>
    [CmdletBinding()]
    param([string]$Version)
    return $Version.Split('-')[1].Split('.')[0]
}

function Get-FlatContainerVersion {
    <#
    .SYNOPSIS
    Returns the versions nuget.org lists for an ID, lower case, or an empty list for a 404.

    .DESCRIPTION
    -Get takes a URL and returns the parsed index, or $null for a 404; tests replace it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FlatContainer,
        [Parameter(Mandatory)][string]$Id,
        [scriptblock]$Get = { param($Url) Invoke-FlatContainerGet -Url $Url }
    )
    $url = "$($FlatContainer.TrimEnd('/'))/$($Id.ToLowerInvariant())/index.json"
    $index = & $Get $url
    if ($null -eq $index) { return , @() }
    return , @($index.versions | ForEach-Object { ([string]$_).ToLowerInvariant() })
}

function Invoke-FlatContainerGet {
    <#
    .SYNOPSIS
    Fetches a flat-container index from api.nuget.org. Returns $null for a 404 and refuses any other host.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    if (-not $Url.StartsWith('https://api.nuget.org/', [StringComparison]::Ordinal)) { throw "Refusing to fetch ${Url}: not on api.nuget.org." }
    try { return Invoke-RestMethod -Method Get -Uri $Url }
    catch {
        $response = $_.Exception.Response
        if ($response -and [int]$response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Get-MissingPackageId {
    <#
    .SYNOPSIS
    Returns the IDs from repos.json that nuget.org does not list at the version, in repos.json order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Version,
        [scriptblock]$Get = { param($Url) Invoke-FlatContainerGet -Url $Url }
    )
    $wanted = $Version.ToLowerInvariant()
    return , @(foreach ($id in @($Config.repos | ForEach-Object { $_.packageId })) {
            $listed = Get-FlatContainerVersion -FlatContainer $Config.nugetOrgFlatContainer -Id $id -Get $Get
            if ($listed -cnotcontains $wanted) { $id }
        })
}

function Format-EventCutoff {
    <#
    .SYNOPSIS
    Returns an event's cutoff as yyyy-MM-ddTHH:mm:ssZ, whether it arrives as that string or as a DateTime.

    .DESCRIPTION
    Plan writes each cutoff as yyyy-MM-ddTHH:mm:ssZ. PowerShell 7's ConvertFrom-Json reads it back as a
    DateTime, which a [string] parameter would render as 01/15/2027 05:00:00.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw "Cutoff $Value has no time zone." }
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Invariant)
    }
    $text = [string]$Value
    if ($text -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z') { throw "Cutoff '$text' is not yyyy-MM-ddTHH:mm:ssZ." }
    return $text
}

function Write-ActionOutput {
    <#
    .SYNOPSIS
    Writes a single-line step output to GITHUB_OUTPUT, when set, and to the log.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match "[`r`n]") { throw "Output $Name must be a single line." }
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding utf8 }
    Write-Host "$Name=$Value"
}

Export-ModuleMember -Function Read-ReleaseCalendar, Get-ReleaseKind, Get-FlatContainerVersion, Invoke-FlatContainerGet, Get-MissingPackageId, Format-EventCutoff, Write-ActionOutput
