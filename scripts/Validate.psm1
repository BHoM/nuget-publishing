Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Release.psm1')
. (Join-Path $PSScriptRoot 'Compare-PackageContent.ps1')

# The validate job (Invoke-Validate) and the verify job (Invoke-Verify).
#
# Validate: for each planned event, the build artifact must hold exactly the packages in repos.json, at
# the event's version, each depending on the others at exactly that version. Everything is read from the
# package bytes in memory; build's manifest.json is not trusted. A package nuget.org already lists at
# that version is skipped if its content is identical (see Compare-PackageContent.ps1) and fails the job
# if not. The result is the ordered list publish pushes: event order (alpha first), then dependency
# tier, then repos.json order.

function Read-PackageNuspec {
    <#
    .SYNOPSIS
    Reads the ID, version and dependencies from the nuspec at the root of a package held in memory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][string]$Label)
    $stream = [System.IO.MemoryStream]::new($Bytes, $false)
    $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        $nuspecs = @($zip.Entries | Where-Object { $_.FullName -notmatch '/' -and $_.FullName -like '*.nuspec' })
        if ($nuspecs.Count -ne 1) { throw "${Label}: expected one nuspec at the package root, found $($nuspecs.Count)." }
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $s = $nuspecs[0].Open()
        try {
            $reader = [System.Xml.XmlReader]::Create($s, $settings)
            $xml = [System.Xml.XmlDocument]::new()
            $xml.XmlResolver = $null
            $xml.Load($reader)
        }
        finally { $s.Dispose() }
    }
    finally { $zip.Dispose(); $stream.Dispose() }

    # Matched by local name, so the nuspec schema namespace, whichever year it carries, does not matter.
    if ($xml.DocumentElement.LocalName -cne 'package') { throw "${Label}: nuspec root is not <package>." }
    $meta = @($xml.DocumentElement.SelectNodes("*[local-name()='metadata']"))
    if ($meta.Count -ne 1) { throw "${Label}: nuspec has $($meta.Count) metadata elements." }
    $meta = $meta[0]
    $id = @($meta.SelectNodes("*[local-name()='id']"))
    $version = @($meta.SelectNodes("*[local-name()='version']"))
    if ($id.Count -ne 1 -or $version.Count -ne 1) { throw "${Label}: nuspec needs exactly one id and one version." }
    $id = $id[0]; $version = $version[0]
    $deps = @($meta.SelectNodes("*[local-name()='dependencies']//*[local-name()='dependency']") | ForEach-Object { [pscustomobject]@{ id = $_.GetAttribute('id'); version = $_.GetAttribute('version') } })
    return [pscustomobject]@{ id = $id.InnerText.Trim(); version = $version.InnerText.Trim(); dependencies = $deps }
}

function Get-DependencyTier {
    <#
    .SYNOPSIS
    Returns each package's dependency tier: 0 with no dependencies, otherwise one more than its deepest dependency.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$DependsOn)
    $tier = @{}
    $visiting = @{}
    function Resolve-Tier([string]$Id) {
        if ($tier.ContainsKey($Id)) { return $tier[$Id] }
        if ($visiting.ContainsKey($Id)) { throw "Dependency cycle through $Id." }
        $visiting[$Id] = $true
        $t = 0
        foreach ($d in $DependsOn[$Id]) { $t = [Math]::Max($t, (Resolve-Tier $d) + 1) }
        $tier[$Id] = $t
        return $t
    }
    foreach ($id in @($DependsOn.Keys)) { Resolve-Tier $id | Out-Null }
    return $tier
}

function Test-EventPackage {
    # Checks one event's packages folder and returns its packages in publish order.
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][string]$Version
    )
    $expected = @($Config.repos | ForEach-Object { $_.packageId })
    $folder = Join-Path (Join-Path $ReleaseRoot $Version) 'packages'
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "${Version}: no packages folder in the artifact." }
    $files = @(Get-ChildItem -LiteralPath $folder -File)
    $nupkgs = @($files | Where-Object { $_.Name -like '*.nupkg' })
    if ($files.Count -ne $nupkgs.Count) { throw "${Version}: the packages folder holds files that are not packages: $(@($files | Where-Object { $_.Name -notlike '*.nupkg' } | ForEach-Object Name) -join ', ')." }
    if ($nupkgs.Count -ne $expected.Count) { throw "${Version}: expected exactly $($expected.Count) packages, found $($nupkgs.Count)." }

    $byId = @{}
    foreach ($f in $nupkgs) {
        [byte[]]$bytes = [IO.File]::ReadAllBytes($f.FullName)
        $n = Read-PackageNuspec -Bytes $bytes -Label "$Version/$($f.Name)"
        if ($expected -cnotcontains $n.id) { throw "${Version}: $($f.Name) has ID '$($n.id)', which is not one of the expected packages." }
        if ($byId.ContainsKey($n.id)) { throw "${Version}: two packages have ID $($n.id)." }
        if ($n.version -cne $Version) { throw "${Version}: $($n.id) has version '$($n.version)'." }
        if ($f.Name -cne "$($n.id).$Version.nupkg") { throw "${Version}: $($n.id) is in a file named $($f.Name)." }
        foreach ($d in $n.dependencies) {
            if ($expected -ccontains $d.id -and $d.version -cne $Version) { throw "${Version}: $($n.id) depends on $($d.id) at '$($d.version)', not exactly $Version." }
            if ($expected -cnotcontains $d.id -and $expected -contains $d.id) { throw "${Version}: $($n.id) depends on '$($d.id)', which differs only in case from an expected ID." }
        }
        $byId[$n.id] = [pscustomobject]@{ id = $n.id; bytes = $bytes; file = "$Version/packages/$($f.Name)"; deps = @($n.dependencies | Where-Object { $expected -ccontains $_.id } | ForEach-Object { $_.id } | Select-Object -Unique) }
    }

    $dependsOn = @{}
    foreach ($k in $byId.Keys) { $dependsOn[$k] = $byId[$k].deps }
    $tier = Get-DependencyTier -DependsOn $dependsOn
    $order = @{}
    for ($i = 0; $i -lt $expected.Count; $i++) { $order[$expected[$i]] = $i }
    $sorted = @($byId.Values | Sort-Object @{ Expression = { $tier[$_.id] } }, @{ Expression = { $order[$_.id] } })
    return , @($sorted | ForEach-Object {
            [pscustomobject]@{ version = $Version; id = $_.id; file = $_.file; sha256 = (Get-Sha256Hex $_.bytes); tier = $tier[$_.id]; bytes = $_.bytes }
        })
}

function Get-NuGetOrgPackage {
    param([Parameter(Mandatory)][string]$FlatContainer, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Version)
    $lid = $Id.ToLowerInvariant(); $lv = $Version.ToLowerInvariant()
    $url = "$($FlatContainer.TrimEnd('/'))/$lid/$lv/$lid.$lv.nupkg"
    if (-not $url.StartsWith('https://api.nuget.org/', [StringComparison]::Ordinal)) { throw "Refusing to fetch ${url}: not on api.nuget.org." }
    Add-Type -AssemblyName System.Net.Http
    $client = [System.Net.Http.HttpClient]::new()
    try { return , $client.GetByteArrayAsync($url).GetAwaiter().GetResult() }
    finally { $client.Dispose() }
}

function Get-PublishList {
    <#
    .SYNOPSIS
    Checks every event's packages and returns those to publish, in order, and those already on nuget.org.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][object[]]$Events,
        [scriptblock]$GetIndex = { param($Url) Invoke-FlatContainerGet -Url $Url },
        [scriptblock]$GetPackage = { param($Id, $Version) Get-NuGetOrgPackage -FlatContainer $Config.nugetOrgFlatContainer -Id $Id -Version $Version }
    )
    $alpha = @($Events | Where-Object { (Get-ReleaseKind $_.version) -eq 'alpha' })
    $beta = @($Events | Where-Object { (Get-ReleaseKind $_.version) -eq 'beta' })
    $list = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($alpha + $beta)) {
        foreach ($p in (Test-EventPackage -Config $Config -ReleaseRoot $ReleaseRoot -Version $e.version)) {
            $listed = Get-FlatContainerVersion -FlatContainer $Config.nugetOrgFlatContainer -Id $p.id -Get $GetIndex
            if ($listed -ccontains $p.version.ToLowerInvariant()) {
                [byte[]]$existing = & $GetPackage $p.id $p.version
                $cmp = Compare-PackageContent -Left $p.bytes -Right $existing
                if (-not $cmp.Identical) {
                    throw "$($p.id) $($p.version) is already on nuget.org with different content: differs [$($cmp.Differ -join ', ')], only here [$($cmp.OnlyLeft -join ', ')], only there [$($cmp.OnlyRight -join ', ')]."
                }
                $skipped.Add("$($p.id) $($p.version)")
                continue
            }
            $list.Add([pscustomobject][ordered]@{ version = $p.version; id = $p.id; file = $p.file; sha256 = $p.sha256 })
        }
    }
    return [pscustomobject]@{ toPublish = $list.ToArray(); skipped = $skipped.ToArray() }
}

function Invoke-Validate {
    <#
    .SYNOPSIS
    Runs the validate job and writes its outputs, to_publish and count.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$ReleaseRoot, [Parameter(Mandatory)][string]$EventsJson)
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $events = $EventsJson | ConvertFrom-Json
    $events = @($events)
    if ($events.Count -eq 0) { throw 'validate ran with no events.' }
    $result = Get-PublishList -Config $config -ReleaseRoot $ReleaseRoot -Events $events
    $json = if ($result.toPublish.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject @($result.toPublish) -Compress -Depth 3 }
    Write-ActionOutput -Name 'to_publish' -Value $json
    Write-ActionOutput -Name 'count' -Value ([string]$result.toPublish.Count)
    if ($env:GITHUB_STEP_SUMMARY) {
        $md = @('## Validate', '', "$($result.toPublish.Count) to publish, $($result.skipped.Count) already on nuget.org with identical content.", '', '| Version | Package | SHA-256 |', '|---|---|---|')
        $md += @($result.toPublish | ForEach-Object { "| $($_.version) | $($_.id) | ``$($_.sha256)`` |" })
        $md += @($result.skipped | ForEach-Object { "| skipped | $_ | |" })
        $md | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
    }
}

function Wait-PackageSet {
    <#
    .SYNOPSIS
    Polls nuget.org until it lists every package in repos.json at the version.

    .DESCRIPTION
    Throws, naming the missing IDs, if any is still missing once the deadline has passed. -Sleep and
    -UtcNow exist so tests can run without waiting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc,
        [int]$IntervalSeconds = 60,
        [scriptblock]$GetIndex = { param($Url) Invoke-FlatContainerGet -Url $Url },
        [scriptblock]$Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds },
        [scriptblock]$UtcNow = { [DateTime]::UtcNow }
    )
    $total = @($Config.repos).Count
    while ($true) {
        $missing = Get-MissingPackageId -Config $Config -Version $Version -Get $GetIndex
        if ($missing.Count -eq 0) { Write-Host "nuget.org lists all $total packages at $Version."; return }
        if ((& $UtcNow) -ge $DeadlineUtc) { throw "nuget.org still does not list $($missing.Count) of $total packages at ${Version}: $($missing -join ', ')." }
        Write-Host "$($missing.Count) of $total not yet on nuget.org at $Version; checking again in $IntervalSeconds s."
        & $Sleep $IntervalSeconds
    }
}

function Invoke-Verify {
    <#
    .SYNOPSIS
    Runs the verify job: checks nuget.org after publish, or after a rehearsal.

    .DESCRIPTION
    A rehearsal only confirms nuget.org does not list the version. Otherwise every package must appear
    on the flat container within the time allowed, and every package publish reported, pushed or
    already present, must have the content validate approved. A push that lost a race to another run
    exits 0 under --skip-duplicate and is reported as pushed, so checking only the already-present
    ones would miss it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][string]$EventsJson,
        [Parameter(Mandatory)][bool]$Rehearsal,
        [AllowEmptyString()][string]$ToPublishJson = '[]',
        [AllowEmptyString()][string]$PublishResultsJson = '[]',
        [int]$TimeoutMinutes = 30,
        [int]$IntervalSeconds = 60,
        [scriptblock]$GetIndex = { param($Url) Invoke-FlatContainerGet -Url $Url },
        [scriptblock]$GetPackage,
        [scriptblock]$Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $GetPackage) { $GetPackage = { param($Id, $Version) Get-NuGetOrgPackage -FlatContainer $config.nugetOrgFlatContainer -Id $Id -Version $Version } }
    $events = $EventsJson | ConvertFrom-Json
    $events = @($events)
    $total = @($config.repos).Count

    if ($Rehearsal) {
        foreach ($e in $events) {
            $missing = Get-MissingPackageId -Config $config -Version $e.version -Get $GetIndex
            if ($missing.Count -ne $total) {
                $present = @($config.repos | ForEach-Object { $_.packageId } | Where-Object { $missing -cnotcontains $_ })
                throw "Rehearsal of $($e.version): nuget.org already lists $($present.Count) of $total at that version ($($present -join ', ')). A rehearsal must not reach nuget.org."
            }
            Write-Host "Rehearsal of $($e.version): nuget.org lists none of the $total packages at that version."
        }
        return
    }

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    foreach ($e in $events) {
        Wait-PackageSet -Config $config -Version $e.version -DeadlineUtc $deadline -IntervalSeconds $IntervalSeconds -GetIndex $GetIndex -Sleep $Sleep
    }

    # Assigned before wrapping: Windows PowerShell 5.1 emits a parsed array as one object.
    $toPublish = $ToPublishJson | ConvertFrom-Json
    $toPublish = @($toPublish)
    $results = $PublishResultsJson | ConvertFrom-Json
    $results = @($results)
    foreach ($r in @($results | Where-Object { $_ })) {
        if ($r.state -cnotin @('pushed', 'already-present')) { throw "$($r.id) $($r.version) has publish state '$($r.state)'." }
        $planned = @($toPublish | Where-Object { $_.id -ceq $r.id -and $_.version -ceq $r.version })
        if ($planned.Count -ne 1) { throw "$($r.id) $($r.version) was reported $($r.state) but is not in to_publish." }
        $path = Join-Path $ReleaseRoot $planned[0].file
        [byte[]]$mine = [IO.File]::ReadAllBytes($path)
        if ((Get-Sha256Hex $mine) -cne $planned[0].sha256) { throw "$($planned[0].file) no longer has the SHA-256 validate approved." }
        [byte[]]$theirs = & $GetPackage $r.id $r.version
        $cmp = Compare-PackageContent -Left $mine -Right $theirs
        if (-not $cmp.Identical) { throw "$($r.id) $($r.version) on nuget.org is not the package validate approved: differs [$($cmp.Differ -join ', ')], only here [$($cmp.OnlyLeft -join ', ')], only there [$($cmp.OnlyRight -join ', ')]." }
        Write-Host "$($r.id) $($r.version) ($($r.state)): the copy on nuget.org has identical content."
    }
}

Export-ModuleMember -Function Read-PackageNuspec, Get-DependencyTier, Get-PublishList, Wait-PackageSet, Invoke-Validate, Invoke-Verify
