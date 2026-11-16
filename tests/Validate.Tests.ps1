<#
Offline tests for the validate and verify jobs (Validate.psm1) on planted artifact folders, with nuget.org
replaced by stubs. A three-package config stands in for the 16.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/Validate.psm1') -Force

$config = [pscustomobject]@{
    nugetOrgFlatContainer = 'https://api.nuget.org/v3-flatcontainer'
    repos = @(
        [pscustomobject]@{ repo = 'BHoM/BHoM_UI'; packageId = 'BHoM.UI' },
        [pscustomobject]@{ repo = 'BHoM/BHoM'; packageId = 'BHoM' },
        [pscustomobject]@{ repo = 'BHoM/BHoM_Engine'; packageId = 'BHoM.Engine' }
    )
}
$deps = @{ 'BHoM' = @(); 'BHoM.Engine' = @('BHoM'); 'BHoM.UI' = @('BHoM', 'BHoM.Engine') }

function New-Nupkg([string]$Id, [string]$Version, [hashtable]$DepVersions = @{}, [string]$Dll = 'dll') {
    $depXml = (@($deps[$Id] | Where-Object { $_ }) | ForEach-Object { $v = if ($DepVersions.ContainsKey($_)) { $DepVersions[$_] } else { $Version }; "<dependency id=`"$_`" version=`"$v`" />" }) -join ''
    $nuspec = "<?xml version=`"1.0`"?><package xmlns=`"urn:nuspec-test`"><metadata><id>$Id</id><version>$Version</version><dependencies><group targetFramework=`".NETStandard2.0`"><dependency id=`"NETStandard.Library`" version=`"2.0.3`" />$depXml</group></dependencies></metadata></package>"
    $ms = [System.IO.MemoryStream]::new()
    $zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($e in @(@("$Id.nuspec", $nuspec), @("lib/netstandard2.0/$Id.dll", $Dll))) {
        $b = [Text.Encoding]::UTF8.GetBytes($e[1])
        $s = $zip.CreateEntry($e[0]).Open(); $s.Write($b, 0, $b.Length); $s.Dispose()
    }
    $zip.Dispose()
    return , $ms.ToArray()
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "validate-test-$PID"
function New-Release([string]$Version, [scriptblock]$Tweak) {
    $dir = Join-Path $tmp "case-$([guid]::NewGuid().ToString('N'))"
    $pkg = Join-Path (Join-Path $dir $Version) 'packages'
    New-Item -ItemType Directory -Force -Path $pkg | Out-Null
    $files = [ordered]@{}
    foreach ($id in 'BHoM', 'BHoM.Engine', 'BHoM.UI') { $files["$id.$Version.nupkg"] = New-Nupkg $id $Version }
    if ($Tweak) { & $Tweak $files $Version }
    foreach ($k in $files.Keys) { [IO.File]::WriteAllBytes((Join-Path $pkg $k), $files[$k]) }
    return $dir
}
function Ev([string]$Version) { [pscustomobject]@{ version = $Version; date = '2027-01-15'; sprint = 0; cutoff = '2027-01-15T05:00:00Z' } }
$none = { param($Url) $null }
$noDownload = { param($Id, $Version) throw "unexpected download of $Id" }

$failures = 0
function Assert-List([string]$Name, [scriptblock]$Run, [string]$Expect) {
    try {
        $r = & $Run
        $got = (@($r.toPublish) | ForEach-Object { "$($_.version)/$($_.id)" }) -join ','
        if ($got -ceq $Expect) { Write-Host "PASS  $Name -> [$got] skipped [$(@($r.skipped) -join ', ')]" }
        else { $script:failures++; Write-Host "FAIL  $Name -> [$got], expected [$Expect]" }
    }
    catch { $script:failures++; Write-Host "FAIL  $Name threw $($_.Exception.Message)" }
}
function Assert-Refusal([string]$Name, [scriptblock]$Run, [string]$Like) {
    try { & $Run | Out-Null; $script:failures++; Write-Host "FAIL  $Name was accepted" }
    catch {
        if ($_.Exception.Message -like "*$Like*") { Write-Host "PASS  $Name -> refused: $($_.Exception.Message)" }
        else { $script:failures++; Write-Host "FAIL  $Name threw $($_.Exception.Message)" }
    }
}

New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $v = '10.1.0-alpha.1.0'
    $good = New-Release $v $null
    Assert-List 'good set, tier order then repos.json order' { Get-PublishList -Config $config -ReleaseRoot $good -Events @(Ev $v) -GetIndex $none -GetPackage $noDownload } "$v/BHoM,$v/BHoM.Engine,$v/BHoM.UI"

    $r = Get-PublishList -Config $config -ReleaseRoot $good -Events @(Ev $v) -GetIndex $none -GetPackage $noDownload
    $expectedHash = (Get-FileHash -LiteralPath (Join-Path $good "$v/packages/BHoM.$v.nupkg") -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($r.toPublish[0].sha256 -ceq $expectedHash -and $r.toPublish[0].file -ceq "$v/packages/BHoM.$v.nupkg") { Write-Host 'PASS  hash recomputed from the bytes and file path relative to the artifact' }
    else { $failures++; Write-Host "FAIL  hash or file: $($r.toPublish[0] | ConvertTo-Json -Compress)" }

    $missing = New-Release $v { param($f, $v) $f.Remove("BHoM.UI.$v.nupkg") }
    Assert-Refusal 'one package missing' { Get-PublishList -Config $config -ReleaseRoot $missing -Events @(Ev $v) -GetIndex $none -GetPackage $noDownload } 'expected exactly 3 packages, found 2'

    $extraFile = New-Release $v { param($f, $v) $f['notes.txt'] = [Text.Encoding]::UTF8.GetBytes('x') }
    Assert-Refusal 'a file that is not a package' { Get-PublishList -Config $config -ReleaseRoot $extraFile -Events @(Ev $v) -GetIndex $none -GetPackage $noDownload } 'not packages: notes.txt'

    $wrongId = New-Release $v { param($f, $v) $f["BHoM.UI.$v.nupkg"] = New-Nupkg 'BHoM.Interop.Other' $v }
    Assert-Refusal 'unexpected ID' { Get-PublishList -Config $config -ReleaseRoot $wrongId -Events @(Ev $v) -GetIndex $none -GetPackage $noDownload } "has ID 'BHoM.Interop.Other'"

    $wrongVersion = New-Release $v { param($f, $v) $f["BHoM.Engine.$v.nupkg"] = New-Nupkg 'BHoM.Engine' '10.1.0-alpha.2.0' }
    Assert-Refusal 'package at another version' { Get-PublishList -Config $config -ReleaseRoot $wrongVersion -Events @(Ev $v) -GetIndex $none -GetPackage $noDownload } "has version '10.1.0-alpha.2.0'"

    $wrongDep = New-Release $v { param($f, $v) $f["BHoM.UI.$v.nupkg"] = New-Nupkg 'BHoM.UI' $v @{ 'BHoM.Engine' = '10.0.0-alpha.3.0' } }
    Assert-Refusal 'dependency on one of the set at another version' { Get-PublishList -Config $config -ReleaseRoot $wrongDep -Events @(Ev $v) -GetIndex $none -GetPackage $noDownload } 'depends on BHoM.Engine at ''10.0.0-alpha.3.0'''

    $rangeDep = New-Release $v { param($f, $v) $f["BHoM.UI.$v.nupkg"] = New-Nupkg 'BHoM.UI' $v @{ 'BHoM' = "[$v]" } }
    Assert-Refusal 'dependency written as a range' { Get-PublishList -Config $config -ReleaseRoot $rangeDep -Events @(Ev $v) -GetIndex $none -GetPackage $noDownload } "not exactly $v"

    $identical = { param($Url) if ($Url -like '*/bhom.engine/index.json') { [pscustomobject]@{ versions = @('10.0.0-alpha.3.0', $v) } } else { $null } }
    $sameBytes = [IO.File]::ReadAllBytes((Join-Path $good "$v/packages/BHoM.Engine.$v.nupkg"))
    Assert-List 'already on nuget.org with identical content is skipped' { Get-PublishList -Config $config -ReleaseRoot $good -Events @(Ev $v) -GetIndex $identical -GetPackage ({ param($Id, $Version) , $sameBytes }.GetNewClosure()) } "$v/BHoM,$v/BHoM.UI"

    $otherBytes = New-Nupkg 'BHoM.Engine' $v @{} 'other dll'
    Assert-Refusal 'already on nuget.org with different content' { Get-PublishList -Config $config -ReleaseRoot $good -Events @(Ev $v) -GetIndex $identical -GetPackage ({ param($Id, $Version) , $otherBytes }.GetNewClosure()) } 'already on nuget.org with different content'

    $b = '10.1.0-beta.0'
    $two = New-Release $b $null
    $alphaDir = Join-Path $two $v
    Copy-Item -LiteralPath (Join-Path $good $v) -Destination $alphaDir -Recurse
    Assert-List 'same-day beta and alpha publish alpha first' { Get-PublishList -Config $config -ReleaseRoot $two -Events @((Ev $b), (Ev $v)) -GetIndex $none -GetPackage $noDownload } "$v/BHoM,$v/BHoM.Engine,$v/BHoM.UI,$b/BHoM,$b/BHoM.Engine,$b/BHoM.UI"

    # verify
    $cfgPath = Join-Path $tmp 'repos.json'
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cfgPath
    $eventsJson = ConvertTo-Json -InputObject @(Ev $v) -Compress
    $queried = [System.Collections.Generic.List[string]]::new()
    $allListed = { param($Url) $queried.Add($Url); [pscustomobject]@{ versions = @($v) } }.GetNewClosure()
    $noSleep = { param($Seconds) throw 'verify slept although every package was listed' }
    try { Invoke-Verify -ConfigPath $cfgPath -ReleaseRoot $good -EventsJson $eventsJson -Rehearsal $true -GetIndex $none; Write-Host 'PASS  verify, rehearsal: version absent from nuget.org' }
    catch { $failures++; Write-Host "FAIL  verify, rehearsal absent threw $($_.Exception.Message)" }
    Assert-Refusal 'verify, rehearsal: version present on nuget.org' { Invoke-Verify -ConfigPath $cfgPath -ReleaseRoot $good -EventsJson $eventsJson -Rehearsal $true -GetIndex $identical } 'already lists 1 of 3'

    $tp = (Get-PublishList -Config $config -ReleaseRoot $good -Events @(Ev $v) -GetIndex $none -GetPackage $noDownload).toPublish
    $tpJson = ConvertTo-Json -InputObject @($tp) -Compress
    $results = "[{`"id`":`"BHoM.Engine`",`"version`":`"$v`",`"state`":`"already-present`"},{`"id`":`"BHoM`",`"version`":`"$v`",`"state`":`"pushed`"}]"
    try {
        $compared = [System.Collections.Generic.List[string]]::new()
        Invoke-Verify -ConfigPath $cfgPath -ReleaseRoot $good -EventsJson $eventsJson -Rehearsal $false -ToPublishJson $tpJson -PublishResultsJson $results -GetIndex $allListed -Sleep $noSleep -GetPackage ({ param($Id, $Version) $compared.Add($Id); , [IO.File]::ReadAllBytes((Join-Path $good "$Version/packages/$Id.$Version.nupkg")) }.GetNewClosure())
        if ($queried.Count -eq 3 -and ($compared -join ',') -ceq 'BHoM.Engine,BHoM') { Write-Host "PASS  verify: asks nuget.org for every package, then compares every package publish reported -> $($queried.Count) index queries, compared [$($compared -join ', ')]" }
        else { $failures++; Write-Host "FAIL  verify made $($queried.Count) index queries, compared [$($compared -join ', ')]" }
    }
    catch { $failures++; Write-Host "FAIL  verify identical threw $($_.Exception.Message)" }
    $lostRace = "[{`"id`":`"BHoM`",`"version`":`"$v`",`"state`":`"pushed`"}]"
    Assert-Refusal 'verify: a push that lost a --skip-duplicate race is still compared' { Invoke-Verify -ConfigPath $cfgPath -ReleaseRoot $good -EventsJson $eventsJson -Rehearsal $false -ToPublishJson $tpJson -PublishResultsJson $lostRace -GetIndex $allListed -Sleep $noSleep -GetPackage ({ param($Id, $Version) , $otherBytes }.GetNewClosure()) } 'is not the package validate approved'
    Assert-Refusal 'verify: already-present copy differs' { Invoke-Verify -ConfigPath $cfgPath -ReleaseRoot $good -EventsJson $eventsJson -Rehearsal $false -ToPublishJson $tpJson -PublishResultsJson $results -GetIndex $allListed -Sleep $noSleep -GetPackage ({ param($Id, $Version) , $otherBytes }.GetNewClosure()) } 'is not the package validate approved'

    # The wait for nuget.org to list a version, on a clock the test controls: each sleep moves it on.
    # A round starts with the first ID in the config, BHoM.UI.
    function Invoke-Wait([int]$ListedFromRound) {
        $clock = @{ now = [DateTime]::new(2027, 1, 15, 6, 0, 0, [DateTimeKind]::Utc); sleeps = 0; rounds = 0 }
        $index = { param($Url) if ($Url -like '*/bhom.ui/index.json') { $clock.rounds++ }; if ($clock.rounds -ge $ListedFromRound) { [pscustomobject]@{ versions = @($v) } } else { $null } }.GetNewClosure()
        Wait-PackageSet -Config $config -Version $v -DeadlineUtc $clock.now.AddMinutes(3) -IntervalSeconds 60 -GetIndex $index -Sleep ({ param($Seconds) $clock.sleeps++; $clock.now = $clock.now.AddSeconds($Seconds) }.GetNewClosure()) -UtcNow ({ $clock.now }.GetNewClosure())
        return $clock
    }
    try { $c = Invoke-Wait 1; if ($c.sleeps -eq 0 -and $c.rounds -eq 1) { Write-Host 'PASS  wait: listed at once -> no sleep' } else { $failures++; Write-Host "FAIL  wait, listed at once: $($c.sleeps) sleeps, $($c.rounds) rounds" } }
    catch { $failures++; Write-Host "FAIL  wait, listed at once threw $($_.Exception.Message)" }
    try { $c = Invoke-Wait 3; if ($c.sleeps -eq 2 -and $c.rounds -eq 3) { Write-Host 'PASS  wait: listed after a delay -> 2 sleeps, then accepted' } else { $failures++; Write-Host "FAIL  wait, listed after a delay: $($c.sleeps) sleeps, $($c.rounds) rounds" } }
    catch { $failures++; Write-Host "FAIL  wait, listed after a delay threw $($_.Exception.Message)" }
    Assert-Refusal 'wait: never listed within the limit' { Invoke-Wait 99 } 'still does not list 3 of 3 packages at 10.1.0-alpha.1.0: BHoM.UI, BHoM, BHoM.Engine'
    $elsewhere = [pscustomobject]@{ nugetOrgFlatContainer = ('https:' + '//example.invalid/v3-flatcontainer'); repos = $config.repos }
    Assert-Refusal 'wait: an index that is not on api.nuget.org is not fetched' { Wait-PackageSet -Config $elsewhere -Version $v -DeadlineUtc ([DateTime]::UtcNow) } 'not on api.nuget.org'

    $cycle = $null
    try { Get-DependencyTier -DependsOn @{ a = @('b'); b = @('a') } | Out-Null } catch { $cycle = $_.Exception.Message }
    if ($cycle -like '*cycle*') { Write-Host "PASS  dependency cycle -> refused: $cycle" } else { $failures++; Write-Host 'FAIL  dependency cycle accepted' }

    $dtd = [Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><!DOCTYPE p [<!ENTITY x "y">]><package><metadata><id>BHoM</id><version>&x;</version></metadata></package>')
    $ms = [System.IO.MemoryStream]::new(); $zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    $s = $zip.CreateEntry('BHoM.nuspec').Open(); $s.Write($dtd, 0, $dtd.Length); $s.Dispose(); $zip.Dispose()
    Assert-Refusal 'nuspec with a DTD is not parsed' { Read-PackageNuspec -Bytes $ms.ToArray() -Label 'dtd' } 'DTD'
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force }

Write-Host "PowerShell $($PSVersionTable.PSVersion): 22 cases, $failures failed."
if ($failures -gt 0) { exit 1 }
