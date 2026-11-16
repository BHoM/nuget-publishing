<#
Offline tests for Compare-WithNuGetOrg.ps1 on packages built in memory, with nuget.org replaced by a stub:
DLL bytes alone are not a difference, and file lists, dependencies and nuspec metadata are.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/Compare-WithNuGetOrg.ps1')

$utf8 = [Text.UTF8Encoding]::new($false)
function New-Package([hashtable]$Entries) {
    $ms = [System.IO.MemoryStream]::new()
    $zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($name in $Entries.Keys) {
        [byte[]]$bytes = if ($Entries[$name] -is [byte[]]) { $Entries[$name] } else { $utf8.GetBytes([string]$Entries[$name]) }
        $s = $zip.CreateEntry($name).Open(); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
    }
    $zip.Dispose()
    return , $ms.ToArray()
}
function Nuspec([string]$Id, [string]$Notes = 'Sprint 1.', [string]$DepVersion = '10.1.0-alpha.1.0') {
    $deps = if ($Id -ceq 'BHoM') { '' } else { "<dependencies><group targetFramework=`".NETStandard2.0`"><dependency id=`"BHoM`" version=`"$DepVersion`" /></group></dependencies>" }
    "<?xml version=`"1.0`"?><package><metadata><id>$Id</id><version>10.1.0-alpha.1.0</version><authors>BHoM</authors><license type=`"expression`">LGPL-3.0-only</license><releaseNotes>$Notes</releaseNotes>$deps</metadata></package>"
}
function Pkg([string]$Id, [byte]$DllByte = 1, [string]$Notes = 'Sprint 1.', [string]$DepVersion = '10.1.0-alpha.1.0', [hashtable]$Extra = @{}) {
    $e = @{ "$Id.nuspec" = (Nuspec $Id $Notes $DepVersion); "lib/netstandard2.0/${Id}_oM.dll" = [byte[]](77, 90, $DllByte) }
    foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
    New-Package $e
}

$v = '10.1.0-alpha.1.0'
$config = [pscustomobject]@{
    nugetOrgFlatContainer = 'https://api.nuget.org/v3-flatcontainer'
    repos = @([pscustomobject]@{ packageId = 'BHoM' }, [pscustomobject]@{ packageId = 'BHoM.Engine' })
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) "compare-nugetorg-test-$PID"
$failures = 0
function Run([string]$Name, [hashtable]$Rehearsal, [hashtable]$NuGetOrg, [string[]]$Expected) {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    foreach ($f in $Rehearsal.Keys) { [IO.File]::WriteAllBytes((Join-Path $tmp $f), $Rehearsal[$f]) }
    $stub = { param($Id, $Version) if ($NuGetOrg.ContainsKey($Id)) { , $NuGetOrg[$Id] } else { $null } }.GetNewClosure()
    $got = Compare-WithNuGetOrg -PackagesFolder $tmp -Version $v -Config $config -GetPackage $stub
    $ok = ($got -join "`n") -ceq ($Expected -join "`n")
    if ($ok) { Write-Host "PASS  $Name -> [$($got -join '; ')]" } else { $script:failures++; Write-Host "FAIL  $Name -> got [$($got -join '; ')], expected [$($Expected -join '; ')]" }
}

$theirs = @{ 'BHoM' = (Pkg 'BHoM' 9); 'BHoM.Engine' = (Pkg 'BHoM.Engine' 9) }
$same = @{ "BHoM.$v.nupkg" = (Pkg 'BHoM'); "BHoM.Engine.$v.nupkg" = (Pkg 'BHoM.Engine') }
try {
    Run 'DLL bytes differ only: no difference' $same $theirs @()
    Run 'extra file in the rehearsal' @{ "BHoM.$v.nupkg" = (Pkg 'BHoM' -Extra @{ 'lib/netstandard2.0/Extra.dll' = 'x' }); "BHoM.Engine.$v.nupkg" = (Pkg 'BHoM.Engine') } $theirs @('BHoM: file only in the rehearsal: lib/netstandard2.0/Extra.dll')
    Run 'dependency version differs' @{ "BHoM.$v.nupkg" = (Pkg 'BHoM'); "BHoM.Engine.$v.nupkg" = (Pkg 'BHoM.Engine' -DepVersion '10.1.0-alpha.2.0') } $theirs @(
        'BHoM.Engine: dependency only in the rehearsal: .NETStandard2.0 BHoM 10.1.0-alpha.2.0',
        'BHoM.Engine: dependency only on nuget.org: .NETStandard2.0 BHoM 10.1.0-alpha.1.0')
    Run 'nuspec metadata differs' @{ "BHoM.$v.nupkg" = (Pkg 'BHoM' -Notes 'Sprint 2.'); "BHoM.Engine.$v.nupkg" = (Pkg 'BHoM.Engine') } $theirs @("BHoM: nuspec <releaseNotes> is 'Sprint 2.' in the rehearsal and 'Sprint 1.' on nuget.org")
    Run 'package not on nuget.org' $same @{ 'BHoM' = $theirs['BHoM'] } @("BHoM.Engine: not on nuget.org at $v")
    Run 'package not in the rehearsal folder, and an unexpected file' @{ "BHoM.$v.nupkg" = (Pkg 'BHoM'); 'notes.txt' = $utf8.GetBytes('x') } $theirs @(
        "notes.txt: in the rehearsal folder, but not one of the expected packages at $v",
        'BHoM.Engine: not in the rehearsal folder')

    $shell = (Get-Process -Id $PID).Path
    & $shell -NoProfile -NonInteractive -File (Join-Path $root 'scripts/Compare-WithNuGetOrg.ps1') -PackagesFolder $tmp | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "PASS  command line without -Version -> exit $LASTEXITCODE" }
    else { $failures++; Write-Host 'FAIL  command line without -Version exited 0' }
}
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }

Write-Host "PowerShell $($PSVersionTable.PSVersion): 7 cases, $failures failed."
if ($failures -gt 0) { exit 1 }
