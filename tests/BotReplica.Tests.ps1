<#
Checks the calendar-driven version and release notes. Get-ReleaseInfo cases, then New-BotNuspec on a
small synthetic repository in a temporary folder, read back from the written nuspec. Needs no build
tools and touches nothing outside the temporary folder.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/BotReplica.psm1') -Force

$failures = 0
function Check([string]$Name, [scriptblock]$Test) {
    try { $detail = & $Test; Write-Host "PASS  $Name$(if ($detail) { " -> $detail" })" }
    catch { $script:failures++; Write-Host "FAIL  ${Name}: $($_.Exception.Message)" }
}
function Refuses([scriptblock]$Action, [string]$Like) {
    try { & $Action } catch { if ($_.Exception.Message -like "*$Like*") { return "refused: $($_.Exception.Message)" }; throw "wrong error: $($_.Exception.Message)" }
    throw 'did not refuse'
}

Check 'alpha takes the sprint from its version' {
    $r = Get-ReleaseInfo -Version '10.0.0-alpha.3.0'
    if ($r.Major -ne 10 -or $r.Minor -ne 0 -or $r.Sprint -ne 3 -or $r.Kind -ne 'alpha') { throw "got $($r | ConvertTo-Json -Compress)" }
    "$($r.Kind) sprint $($r.Sprint) of $($r.Major).$($r.Minor)"
}
Check 'alpha with a matching sprint field' { $r = Get-ReleaseInfo -Version '10.1.0-alpha.1.0' -Sprint 1; "sprint $($r.Sprint)" }
Check 'alpha with a different sprint field is refused' { Refuses { Get-ReleaseInfo -Version '10.1.0-alpha.1.0' -Sprint 2 } 'but sprint 2 was given' }
Check 'beta takes the sprint field' { $r = Get-ReleaseInfo -Version '10.1.0-beta.0' -Sprint 6; "$($r.Kind) sprint $($r.Sprint) of $($r.Major).$($r.Minor)" }
Check 'beta without a sprint is refused' { Refuses { Get-ReleaseInfo -Version '10.1.0-beta.0' } 'needs a positive sprint' }
Check 'malformed version is refused' { Refuses { Get-ReleaseInfo -Version '10.1.0-rc.1' } 'is not M.m.0-alpha' }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "botreplica-test-$PID"
try {
    $repoDir = Join-Path $tmp 'Sample_Toolkit'
    New-Item -ItemType Directory -Force -Path (Join-Path $repoDir '.ci/BHoMBot/Nuget'), (Join-Path $repoDir 'Build/net472'), (Join-Path $repoDir 'Sample_oM') | Out-Null
    Set-Content -LiteralPath (Join-Path $repoDir '.ci/BHoMBot/Nuget/Sample.nuspec') -Value '<?xml version="1.0"?><package><metadata><id>BHoM.Interop.Sample</id><version>0.0.0</version><authors>BHoM</authors><description>d</description></metadata><files /></package>'
    Set-Content -LiteralPath (Join-Path $repoDir 'Sample_oM/Sample_oM.csproj') -Value '<Project />'
    [IO.File]::WriteAllBytes((Join-Path $repoDir 'Build/net472/Sample_oM.dll'), [byte[]](1, 2, 3))
    Set-Content -LiteralPath (Join-Path $repoDir 'readme.md') -Value '# Sample'
    $assets = @{ icon = (Join-Path $root 'assets/icon.png'); licence = (Join-Path $root 'assets/licence.txt') }

    foreach ($case in @(
            @{ Version = '10.0.0-alpha.3.0'; Sprint = 0; Notes = 'This package contains all work completed during Sprint 3 of the 10.0 milestone.' },
            @{ Version = '10.1.0-beta.0'; Sprint = 6; Notes = 'This package contains all work completed during Sprint 6 of the 10.1 milestone.' })) {
        Check "nuspec for $($case.Version)" {
            $out = Join-Path $tmp "out-$($case.Version)"
            $pkg = New-BotNuspec -RepoName 'Sample_Toolkit' -RepoLocation $repoDir -OutputFolder $out -Release (Get-ReleaseInfo -Version $case.Version -Sprint $case.Sprint) -AssetPaths $assets
            [xml]$x = Get-Content -LiteralPath $pkg.NuspecPath -Raw
            $m = $x.package.metadata
            if ($m.version -cne $case.Version) { throw "version '$($m.version)'" }
            if ($m.releaseNotes -cne $case.Notes) { throw "releaseNotes '$($m.releaseNotes)'" }
            "version $($m.version); `"$($m.releaseNotes)`""
        }
    }

    # There is no readme fallback. Each package carries its repository's own README,
    # as the bot's packages of the 16 do, and a repository without one fails with a message that says so.
    Check 'repository without a readme is refused, naming the repository' {
        $noReadme = Join-Path $tmp 'NoReadme_Toolkit'
        Copy-Item -LiteralPath $repoDir -Destination $noReadme -Recurse
        Remove-Item -LiteralPath (Join-Path $noReadme 'readme.md')
        Refuses { New-BotNuspec -RepoName 'NoReadme_Toolkit' -RepoLocation $noReadme -OutputFolder (Join-Path $tmp 'out-noreadme') -Release (Get-ReleaseInfo -Version '10.1.0-alpha.1.0') -AssetPaths $assets } 'NoReadme_Toolkit has no README.md at its root'
    }
    Check 'the packed readme is the repository''s own' {
        $docs = Get-Content -LiteralPath (Join-Path $tmp 'out-10.1.0-beta.0/docs/readme.md') -Raw
        if ($docs.Trim() -cne '# Sample') { throw "docs/readme.md is '$docs'" }
        'docs/readme.md is the repository README'
    }
    Check 'config/repos.json names no readme fallback' {
        $cfg = Get-Content -LiteralPath (Join-Path $root 'config/repos.json') -Raw | ConvertFrom-Json
        if ($cfg.assets.PSObject.Properties.Name -contains 'readme') { throw 'assets.readme is still configured' }
        "assets: $($cfg.assets.PSObject.Properties.Name -join ', ')"
    }
}
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }

Write-Host "PowerShell $($PSVersionTable.PSVersion): $failures failed."
if ($failures -gt 0) { exit 1 }
