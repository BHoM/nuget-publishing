Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Replicates the bot's NuGet packaging, so that packages built here match the ones it published.
# Where this is deliberately stricter than that packaging, the comment is marked DEVIATION.

function Get-ReleaseInfo {
    <#
    .SYNOPSIS
    Returns the version, major, minor, kind and sprint of a calendar version.

    .DESCRIPTION
    The version comes from calendar.json. The release notes name a sprint: an alpha's is the number after
    "alpha.", and a beta, whose version carries none, takes it from the event's sprint field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Version,
        [int]$Sprint = 0
    )
    $m = [regex]::Match($Version, '\A([0-9]+)\.([0-9]+)\.0-(alpha\.([0-9]+)\.[0-9]+|beta\.[0-9]+)\z')
    if (-not $m.Success) { throw "Version '$Version' is not M.m.0-alpha.S.P or M.m.0-beta.P." }
    $major = [int]$m.Groups[1].Value; $minor = [int]$m.Groups[2].Value
    if ($m.Groups[3].Value.StartsWith('alpha')) {
        $fromVersion = [int]$m.Groups[4].Value
        if ($Sprint -ne 0 -and $Sprint -ne $fromVersion) { throw "Version $Version is sprint $fromVersion, but sprint $Sprint was given." }
        return [pscustomobject]@{ Version = $Version; Major = $major; Minor = $minor; Kind = 'alpha'; Sprint = $fromVersion }
    }
    if ($Sprint -le 0) { throw "Version $Version is a beta and needs a positive sprint number for its release notes." }
    return [pscustomobject]@{ Version = $Version; Major = $major; Minor = $minor; Kind = 'beta'; Sprint = $Sprint }
}

function Get-TierOrder {
    <#
    .SYNOPSIS
    Returns the repositories in dependency tiers by Kahn's algorithm; ties keep the order of config/repos.json.

    .DESCRIPTION
    DEVIATION: a repository with an unmet dependency stops the run; it is not left out of the release.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Repos,
        [Parameter(Mandatory)][hashtable]$Dependencies
    )
    $remaining = [ordered]@{}
    foreach ($r in $Repos) { $remaining[$r] = [System.Collections.Generic.List[string]]@($Dependencies[$r]) }
    $tiers = [System.Collections.Generic.List[object]]::new()
    while ($remaining.Count -gt 0) {
        $ready = @($remaining.Keys | Where-Object { $remaining[$_].Count -eq 0 })
        if ($ready.Count -eq 0) { break }
        $tiers.Add($ready)
        foreach ($r in $ready) { $remaining.Remove($r) }
        foreach ($k in @($remaining.Keys)) {
            $remaining[$k] = [System.Collections.Generic.List[string]]@($remaining[$k] | Where-Object { $_ -notin $ready })
        }
    }
    if ($remaining.Count -gt 0) {
        $detail = ($remaining.Keys | ForEach-Object { "$_ is missing: $($remaining[$_] -join ', ')" }) -join '; '
        throw "Dependency sort cannot place every repository. $detail"
    }
    return , $tiers
}

function Read-DependencyFile {
    <#
    .SYNOPSIS
    Reads dependencies.txt exactly as File.ReadAllLines does: every line counts, including blank ones.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "dependencies.txt not found: $Path" }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -eq 0) { return , [string[]]@() }
    $lines = $text -split "`r`n|`n|`r"
    if ($lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    return , [string[]]$lines
}

function Read-NuspecTemplate {
    <#
    .SYNOPSIS
    Reads a repository's nuspec template into the fields a published package carries.

    .DESCRIPTION
    Only those fields are kept, so anything else in the template is dropped (for example the exclude
    attribute on <file>), as it is in the packages already published.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    [xml]$doc = Get-Content -LiteralPath $Path -Raw
    $root = $doc.DocumentElement
    if ($root.LocalName -ne 'package' -or $root.NamespaceURI -ne '') {
        throw "Template $Path has root <$($root.Name)> in namespace '$($root.NamespaceURI)'. Only an un-namespaced <package> root is supported."
    }
    $m = $root.SelectSingleNode('metadata')
    function Get-MetadataText([string]$Name, [string]$Default = '') {
        $n = $m.SelectSingleNode($Name)
        if ($null -eq $n) { return $Default }
        return $n.InnerText
    }
    $licNode = $m.SelectSingleNode('license')
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $m.SelectNodes('dependencies/group')) {
        $deps = [System.Collections.Generic.List[object]]::new()
        foreach ($d in $g.SelectNodes('dependency')) {
            $deps.Add([pscustomobject]@{ Id = $d.GetAttribute('id'); Version = $d.GetAttribute('version') })
        }
        $groups.Add([pscustomobject]@{ TargetFramework = $g.GetAttribute('targetFramework'); Dependencies = $deps })
    }
    $content = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $m.SelectNodes('contentFiles/files')) {
        $content.Add([pscustomobject]@{
                Include      = $f.GetAttribute('include')
                BuildAction  = $f.GetAttribute('buildAction')
                CopyToOutput = [System.Xml.XmlConvert]::ToBoolean($(if ($f.HasAttribute('copyToOutput')) { $f.GetAttribute('copyToOutput') } else { 'false' }))
                Flatten      = [System.Xml.XmlConvert]::ToBoolean($(if ($f.HasAttribute('flatten')) { $f.GetAttribute('flatten') } else { 'false' }))
            })
    }
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $root.SelectNodes('files/file')) {
        $files.Add([pscustomobject]@{ Source = $f.GetAttribute('src'); Target = $f.GetAttribute('target') })
    }
    return [pscustomobject]@{
        Id                       = Get-MetadataText 'id'
        Version                  = Get-MetadataText 'version'
        Authors                  = Get-MetadataText 'authors'
        ProjectUrl               = Get-MetadataText 'projectUrl' 'https://bhom.xyz'
        LicenceType              = $(if ($licNode -and $licNode.HasAttribute('type')) { $licNode.GetAttribute('type') } else { 'file' })
        Licence                  = Get-MetadataText 'license' 'licence.txt'
        Icon                     = Get-MetadataText 'icon' 'icon.png'
        Readme                   = Get-MetadataText 'readme' 'readme.md'
        RequireLicenseAcceptance = Get-MetadataText 'requireLicenseAcceptance'
        Description              = Get-MetadataText 'description'
        ReleaseNotes             = Get-MetadataText 'releaseNotes'
        Copyright                = Get-MetadataText 'copyright'
        Tags                     = Get-MetadataText 'tags'
        Title                    = Get-MetadataText 'title'
        Groups                   = $groups
        ContentFiles             = $content
        Files                    = $files
    }
}

function Get-PackageTargetFramework {
    <#
    .SYNOPSIS
    Returns the target framework of a package's first lib/net* file, or $null when it has none.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package)
    $t = $Package.Files | Where-Object { $_.Target -clike 'lib/net*' } | Select-Object -First 1
    if ($null -eq $t) { return $null }
    return $t.Target.Split('/')[1]
}

function Copy-RepoDll {
    <#
    .SYNOPSIS
    Copies the repository's built DLLs into the package's lib folder and returns the target framework.

    .DESCRIPTION
    DEVIATION: a missing Build\ folder, or one with no matching DLL, fails the package. It is never
    skipped or packed with an empty lib folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoLocation,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)]$Package
    )
    $buildFolder = Join-Path $RepoLocation 'Build'
    if (-not (Test-Path -LiteralPath $buildFolder -PathType Container)) { throw "No Build folder at $buildFolder after a successful build." }

    $subDirs = @(Get-ChildItem -LiteralPath $buildFolder -Directory)
    foreach ($d in $subDirs) { New-Item -ItemType Directory -Force -Path (Join-Path $OutputFolder "lib/$($d.Name)") | Out-Null }
    if ($subDirs.Count -eq 0) { New-Item -ItemType Directory -Force -Path (Join-Path $OutputFolder 'lib/net472') | Out-Null }

    $projectNames = @(Get-ChildItem -LiteralPath $RepoLocation -Recurse -File -Filter '*.csproj' | ForEach-Object { $_.BaseName })
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dlls = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $projectNames) {
        foreach ($f in Get-ChildItem -LiteralPath $buildFolder -Recurse -File -Filter "$name*.dll") {
            if ($seen.Add($f.FullName)) { $dlls.Add($f.FullName) }
        }
    }
    if ($dlls.Count -eq 0) { throw "No DLL in $buildFolder matches any project name in the repository." }

    $tfm = $dlls | ForEach-Object { Split-Path (Split-Path $_ -Parent) -Leaf } | Select-Object -Unique |
        Where-Object { $_ -clike 'net*' } | Select-Object -First 1
    if ([string]::IsNullOrEmpty($tfm)) { $tfm = 'net472' }

    $libDir = Join-Path $OutputFolder "lib/$tfm"
    New-Item -ItemType Directory -Force -Path $libDir | Out-Null
    $collisions = [System.Collections.Generic.List[string]]::new()
    foreach ($dll in $dlls) {
        $fileName = Split-Path $dll -Leaf
        Copy-Item -LiteralPath $dll -Destination (Join-Path $libDir $fileName) -Force
        $target = "lib/$tfm/$fileName"
        # DEVIATION: when two Build subfolders hold the same file name, the later copy wins and the
        # <file> entry is added once, not once per copy.
        if ($Package.Files | Where-Object { $_.Target -eq $target }) { $collisions.Add($fileName); continue }
        $Package.Files.Add([pscustomobject]@{ Source = $target; Target = $target })
    }
    if ($collisions.Count -gt 0) {
        Write-Host "::warning title=DLL name collision::$($Package.Id): $($collisions -join ', ') found in more than one Build subfolder; the last copy was packed."
    }
    return $tfm
}

function Set-DependencyLink {
    <#
    .SYNOPSIS
    Adds each dependency package, at its version, to the group for its target framework.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package, [object[]]$DependencyPackages = @())
    foreach ($dep in $DependencyPackages) {
        $tfm = Get-PackageTargetFramework $dep
        $group = $Package.Groups | Where-Object { $_.TargetFramework -ceq $tfm } | Select-Object -First 1
        if ($null -eq $group) {
            $group = [pscustomobject]@{ TargetFramework = $tfm; Dependencies = [System.Collections.Generic.List[object]]::new() }
            $Package.Groups.Add($group)
        }
        $existing = $group.Dependencies | Where-Object { $_.Id -ceq $dep.Id } | Select-Object -First 1
        if ($existing) { $existing.Version = $dep.Version }
        else { $group.Dependencies.Add([pscustomobject]@{ Id = $dep.Id; Version = $dep.Version }) }
    }
}

function Get-CopyrightText {
    <#
    .SYNOPSIS
    Returns the copyright text written into every nuspec. The year is the current UTC year.
    #>
    [CmdletBinding()]
    param([int]$Year = [DateTime]::UtcNow.Year)
    $lines = @(
        'This package is part of the Buildings and Habitats object Model (BHoM)'
        "Copyright (c) 2015 - $Year, the respective contributors. All rights reserved."
        'Each contributor holds copyright over their respective contributions.'
        'The project versioning (Git) records all such contribution source information.'
        ''
        'The BHoM is free software: you can redistribute it and/or modify'
        'it under the terms of the GNU Lesser General Public License as published by'
        'the Free Software Foundation, either version 3.0 of the License, or'
        '(at your option) any later version.'
        ''
        'The BHoM is distributed in the hope that it will be useful,'
        'but WITHOUT ANY WARRANTY; without even the implied warranty of'
        'MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the'
        'GNU Lesser General Public License for more details.'
        ''
        'You should have received a copy of the GNU Lesser General Public License'
        'along with this code. If not, see https://www.gnu.org/licenses/lgpl-3.0.html'
    )
    return $lines -join "`r`n"
}

function Save-Nuspec {
    <#
    .SYNOPSIS
    Writes the package as a nuspec, with the same element order as the published packages.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$Path)
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $w = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $w.WriteStartDocument()
        $w.WriteStartElement('package')
        $w.WriteStartElement('metadata')
        $w.WriteElementString('id', $Package.Id)
        $w.WriteElementString('version', $Package.Version)
        $w.WriteElementString('authors', $Package.Authors)
        $w.WriteElementString('projectUrl', $Package.ProjectUrl)
        $w.WriteStartElement('license'); $w.WriteAttributeString('type', $Package.LicenceType); $w.WriteString($Package.Licence); $w.WriteEndElement()
        $w.WriteElementString('icon', $Package.Icon)
        $w.WriteElementString('readme', $Package.Readme)
        $w.WriteElementString('requireLicenseAcceptance', $Package.RequireLicenseAcceptance)
        $w.WriteElementString('description', $Package.Description)
        $w.WriteElementString('releaseNotes', $Package.ReleaseNotes)
        $w.WriteElementString('copyright', $Package.Copyright)
        $w.WriteElementString('tags', $Package.Tags)
        $w.WriteElementString('title', $Package.Title)
        $w.WriteStartElement('dependencies')
        foreach ($g in $Package.Groups) {
            $w.WriteStartElement('group'); $w.WriteAttributeString('targetFramework', $g.TargetFramework)
            foreach ($d in $g.Dependencies) {
                $w.WriteStartElement('dependency'); $w.WriteAttributeString('id', $d.Id); $w.WriteAttributeString('version', $d.Version); $w.WriteEndElement()
            }
            $w.WriteEndElement()
        }
        $w.WriteEndElement()
        $w.WriteStartElement('contentFiles')
        foreach ($c in $Package.ContentFiles) {
            $w.WriteStartElement('files')
            $w.WriteAttributeString('include', $c.Include)
            $w.WriteAttributeString('buildAction', $c.BuildAction)
            $w.WriteAttributeString('copyToOutput', [System.Xml.XmlConvert]::ToString([bool]$c.CopyToOutput))
            $w.WriteAttributeString('flatten', [System.Xml.XmlConvert]::ToString([bool]$c.Flatten))
            $w.WriteEndElement()
        }
        $w.WriteEndElement()
        $w.WriteEndElement()
        $w.WriteStartElement('files')
        foreach ($f in $Package.Files) {
            $w.WriteStartElement('file'); $w.WriteAttributeString('src', $f.Source); $w.WriteAttributeString('target', $f.Target); $w.WriteEndElement()
        }
        $w.WriteEndElement()
        $w.WriteEndElement()
        $w.WriteEndDocument()
    }
    finally { $w.Dispose() }
}

function New-BotNuspec {
    <#
    .SYNOPSIS
    Builds a package's folder and nuspec from the repository's template, and returns the package.

    .DESCRIPTION
    The repository's own licence is used when present, otherwise assets/licence.txt; the readme is always
    the repository's own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RepoLocation,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][hashtable]$AssetPaths,
        [object[]]$DependencyPackages = @()
    )
    $templateDir = Join-Path $RepoLocation '.ci/BHoMBot/Nuget'
    $template = Get-ChildItem -LiteralPath $templateDir -File -Filter '*.nuspec' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $template) { throw "No nuspec template in $templateDir." }

    $pkg = Read-NuspecTemplate $template.FullName
    New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
    $tfm = Copy-RepoDll -RepoLocation $RepoLocation -OutputFolder $OutputFolder -Package $pkg

    $pkg.Version = $Release.Version
    $pkg.Title = $RepoName

    $licence = Join-Path $RepoLocation 'licence.txt'
    $licenceSource = 'repo'
    if (-not (Test-Path -LiteralPath $licence -PathType Leaf)) { $licence = $AssetPaths.licence; $licenceSource = 'assets' }
    New-Item -ItemType Directory -Force -Path (Join-Path $OutputFolder 'licence') | Out-Null
    Copy-Item -LiteralPath $licence -Destination (Join-Path $OutputFolder 'licence/licence.txt') -Force

    New-Item -ItemType Directory -Force -Path (Join-Path $OutputFolder 'images') | Out-Null
    Copy-Item -LiteralPath $AssetPaths.icon -Destination (Join-Path $OutputFolder 'images/icon.png') -Force

    # The README is found whatever the case of its file name: NTFS is case-insensitive, and so is Test-Path on Windows.
    # There is no fallback: each of the 16 carries its own README, as in the bot's packages.
    $readme = Join-Path $RepoLocation 'readme.md'
    if (-not (Test-Path -LiteralPath $readme -PathType Leaf)) {
        throw "$RepoName has no README.md at its root. Every package carries its repository's own README, and this release has no fallback."
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $OutputFolder 'docs') | Out-Null
    Copy-Item -LiteralPath $readme -Destination (Join-Path $OutputFolder 'docs/readme.md') -Force

    Set-DependencyLink -Package $pkg -DependencyPackages $DependencyPackages
    $pkg.ReleaseNotes = "This package contains all work completed during Sprint $($Release.Sprint) of the $($Release.Major).$($Release.Minor) milestone."
    $pkg.Copyright = Get-CopyrightText

    $nuspecPath = Join-Path $OutputFolder $template.Name
    Save-Nuspec -Package $pkg -Path $nuspecPath
    $pkg | Add-Member -NotePropertyName NuspecPath -NotePropertyValue $nuspecPath
    $pkg | Add-Member -NotePropertyName LibTfm -NotePropertyValue $tfm
    $pkg | Add-Member -NotePropertyName LicenceSource -NotePropertyValue $licenceSource
    return $pkg
}

function Invoke-Logged {
    <#
    .SYNOPSIS
    Runs a process with a hard timeout, appending its output to a log file, and throws if it fails.

    .DESCRIPTION
    DEVIATION: a timeout kills the process tree and throws, so a build that hangs fails its repository
    visibly. It is never left running or dropped without a log line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [string]$WorkingDirectory = (Get-Location).Path
    )
    $errFile = "$LogFile.stderr"
    Add-Content -LiteralPath $LogFile -Value "> `"$FilePath`" $Arguments"
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru `
        -RedirectStandardOutput "$LogFile.part" -RedirectStandardError $errFile
    $null = $p.Handle  # forces the handle open so ExitCode is readable after exit
    $finished = $p.WaitForExit($TimeoutMinutes * 60 * 1000)
    if (-not $finished) {
        & taskkill.exe /T /F /PID $p.Id | Out-Null
        $p.WaitForExit()
    }
    Get-Content -LiteralPath "$LogFile.part", $errFile -ErrorAction SilentlyContinue | Add-Content -LiteralPath $LogFile
    Remove-Item -LiteralPath "$LogFile.part", $errFile -ErrorAction SilentlyContinue
    if (-not $finished) { throw [System.TimeoutException]::new("${Repo}: $Stage timed out after $TimeoutMinutes minutes") }
    if ($p.ExitCode -ne 0) { throw "${Repo}: $Stage exited with code $($p.ExitCode)" }
}

Export-ModuleMember -Function Get-ReleaseInfo, Get-TierOrder, Read-DependencyFile, Read-NuspecTemplate, Get-PackageTargetFramework, Copy-RepoDll, Set-DependencyLink, Get-CopyrightText, Save-Nuspec, New-BotNuspec, Invoke-Logged
