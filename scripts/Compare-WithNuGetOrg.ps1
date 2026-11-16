<#
.SYNOPSIS
Compares a rehearsal's packages with the same version on nuget.org: file lists, dependencies and nuspec
metadata. File bytes are not compared, because two builds of the same commits differ in their DLLs.

.DESCRIPTION
Run by hand; no workflow runs it. Download the rehearsal run's release artifact and give the folder that
holds its .nupkg files, which is <artifact>/<version>/packages:

  ./scripts/Compare-WithNuGetOrg.ps1 -PackagesFolder ./release/10.1.0-alpha.1.0/packages -Version 10.1.0-alpha.1.0

Prints one line per difference and exits 0 if there is none, 1 if there is any. Dot-source it for the
function; -GetPackage exists so tests can run without the network.
#>
param(
    [string]$PackagesFolder,
    [string]$Version,
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/repos.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Release.psm1')
Import-Module (Join-Path $PSScriptRoot 'Validate.psm1')
. (Join-Path $PSScriptRoot 'Compare-PackageContent.ps1')

function Compare-WithNuGetOrg {
    param(
        [Parameter(Mandatory)][string]$PackagesFolder,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)]$Config,
        [scriptblock]$GetPackage = {
            param($Id, $Version)
            $listed = Get-FlatContainerVersion -FlatContainer $Config.nugetOrgFlatContainer -Id $Id
            if ($listed -cnotcontains $Version.ToLowerInvariant()) { return $null }
            Get-NuGetOrgPackage -FlatContainer $Config.nugetOrgFlatContainer -Id $Id -Version $Version
        }
    )
    $expected = @($Config.repos | ForEach-Object { $_.packageId })
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $PackagesFolder -File | Where-Object { $expected -cnotcontains ($_.Name -creplace "\.$([regex]::Escape($Version))\.nupkg\z", '') })) {
        $found.Add("$($f.Name): in the rehearsal folder, but not one of the expected packages at $Version")
    }
    foreach ($id in $expected) {
        $path = Join-Path $PackagesFolder "$id.$Version.nupkg"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $found.Add("${id}: not in the rehearsal folder"); continue }
        [byte[]]$mine = [IO.File]::ReadAllBytes($path)
        [byte[]]$theirs = & $GetPackage $id $Version
        if ($null -eq $theirs -or $theirs.Length -eq 0) { $found.Add("${id}: not on nuget.org at $Version"); continue }

        $files = Compare-PackageContent -Left $mine -Right $theirs
        foreach ($n in $files.OnlyLeft) { $found.Add("${id}: file only in the rehearsal: $n") }
        foreach ($n in $files.OnlyRight) { $found.Add("${id}: file only on nuget.org: $n") }

        $l = Read-PackageNuspec -Bytes $mine -Label "rehearsal $id"
        $r = Read-PackageNuspec -Bytes $theirs -Label "nuget.org $id"
        $ld = @($l.dependencies | ForEach-Object { "$($_.framework) $($_.id) $($_.version)".Trim() })
        $rd = @($r.dependencies | ForEach-Object { "$($_.framework) $($_.id) $($_.version)".Trim() })
        foreach ($d in @($ld | Where-Object { $rd -cnotcontains $_ })) { $found.Add("${id}: dependency only in the rehearsal: $d") }
        foreach ($d in @($rd | Where-Object { $ld -cnotcontains $_ })) { $found.Add("${id}: dependency only on nuget.org: $d") }

        foreach ($k in @(@($l.metadata.Keys) + @($r.metadata.Keys) | Select-Object -Unique)) {
            $lv = if ($l.metadata.Contains($k)) { $l.metadata[$k] } else { '(absent)' }
            $rv = if ($r.metadata.Contains($k)) { $r.metadata[$k] } else { '(absent)' }
            if ($lv -cne $rv) { $found.Add("${id}: nuspec <$k> is '$lv' in the rehearsal and '$rv' on nuget.org") }
        }
    }
    return , $found.ToArray()
}

if ($PackagesFolder -or $Version) {
    if (-not ($PackagesFolder -and $Version)) { throw 'Give both -PackagesFolder and -Version.' }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $result = Compare-WithNuGetOrg -PackagesFolder (Resolve-Path -LiteralPath $PackagesFolder).Path -Version $Version -Config $config
    if ($result.Count -eq 0) { Write-Host "No differences at $Version in file lists, dependencies or nuspec metadata. File bytes were not compared."; exit 0 }
    $result | ForEach-Object { Write-Host $_ }
    Write-Host "$($result.Count) difference(s) at $Version."
    exit 1
}
