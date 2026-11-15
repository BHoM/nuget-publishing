<#
Clones, builds and packs the repositories in config/repos.json at pinned commits, so that the packages
match the ones the bot published, with failures surfaced instead of skipped. Writes the .nupkg files
and manifest.json (ID, file, SHA-256, tier and pinned commit of each package) under -OutDir. Publishes
nothing.

-Version comes from calendar.json. -Sprint is the event's sprint field: required for a beta, optional
for an alpha (whose version carries it). The default code location is the path embedded in the PDBs of
every package published so far, so those paths stay the same.
#>
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$PinnedPath,
    [Parameter(Mandatory)][string]$Version,
    [int]$Sprint = 0,
    [Parameter(Mandatory)][string]$OutDir,
    [int]$TimeoutMinutes = 10,
    [string]$CodeLocation = 'C:\ProgramData\BHoMBotNuget',
    [string]$BuiltLocation = 'C:\ProgramData\BHoMBotNugetBuilt'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BotReplica.psm1') -Force

$repoRoot = Split-Path $PSScriptRoot -Parent
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$pinned = Get-Content -LiteralPath $PinnedPath -Raw | ConvertFrom-Json
$release = Get-ReleaseInfo -Version $Version -Sprint $Sprint
Write-Host "Package version: $Version (sprint $($release.Sprint) of $($release.Major).$($release.Minor))"

$assetPaths = @{
    icon    = Join-Path $repoRoot $config.assets.icon.path
    licence = Join-Path $repoRoot $config.assets.licence.path
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild not found through vswhere.' }
$nuget = (Get-Command nuget.exe -ErrorAction Stop).Source
Write-Host "MSBuild: $msbuild ($(& $msbuild -nologo -version | Select-Object -Last 1))"
Write-Host "NuGet:   $nuget ($((& $nuget help | Select-Object -First 1)))"
$env:MSBUILDDISABLENODEREUSE = '1'

# Start clean: working folders and ProgramData\BHoM.
# Deleting C:\ProgramData\BHoM wipes a developer's installed BHoM, so only do it on an ephemeral Actions runner.
if ($env:GITHUB_ACTIONS -ne 'true') {
    throw 'Refusing to delete C:\ProgramData\BHoM outside GitHub Actions. This script is meant for an ephemeral hosted runner.'
}
foreach ($d in @($CodeLocation, $BuiltLocation, 'C:\ProgramData\BHoM')) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path $CodeLocation, $BuiltLocation | Out-Null
$logDir = Join-Path $OutDir 'logs'
$pkgDir = Join-Path $OutDir 'packages'
$nuspecDir = Join-Path $OutDir 'nuspecs'
New-Item -ItemType Directory -Force -Path $logDir, $pkgDir, $nuspecDir | Out-Null

# Clone at the pinned commit.
$entries = [ordered]@{}
foreach ($e in $config.repos) {
    $pin = $pinned.repos | Where-Object { $_.repo -eq $e.repo }
    if (-not $pin) { throw "$($e.repo) has no pinned commit." }
    $name = $e.repo.Split('/')[1]
    $dir = Join-Path $CodeLocation $name
    Write-Host "::group::Clone $($e.repo) at $($pin.sha)"
    & git clone --quiet "https://github.com/$($e.repo).git" $dir
    if ($LASTEXITCODE -ne 0) { throw "$($e.repo): git clone failed." }
    & git -C $dir -c advice.detachedHead=false checkout --quiet $pin.sha
    if ($LASTEXITCODE -ne 0) { throw "$($e.repo): checkout of $($pin.sha) failed." }
    $head = (& git -C $dir rev-parse HEAD).Trim()
    if ($head -ne $pin.sha) { throw "$($e.repo): HEAD is $head, expected $($pin.sha)." }
    Write-Host '::endgroup::'

    if (Test-Path -LiteralPath (Join-Path $dir 'altConfigs.txt')) {
        throw "$($e.repo) has altConfigs.txt at the pinned commit. This script does not build those extra configurations, so the package would be incomplete; extend it before continuing."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dir "$name.sln"))) { throw "$($e.repo): $name.sln not found." }
    $entries[$e.repo] = [pscustomobject]@{
        Repo = $e.repo; Name = $name; Dir = $dir; Config = $e.config
        ExpectedId = $e.packageId; Sha = $pin.sha
        Dependencies = Read-DependencyFile (Join-Path $dir 'dependencies.txt')
    }
}

$deps = @{}
foreach ($k in $entries.Keys) { $deps[$k] = $entries[$k].Dependencies }
$tiers = Get-TierOrder -Repos @($entries.Keys) -Dependencies $deps
for ($i = 0; $i -lt $tiers.Count; $i++) { Write-Host "Tier $i`: $($tiers[$i] -join ', ')" }

$packages = @{}
$status = [ordered]@{}
$tierOf = @{}
for ($i = 0; $i -lt $tiers.Count; $i++) { foreach ($r in $tiers[$i]) { $tierOf[$r] = $i } }

foreach ($tier in $tiers) {
    foreach ($key in $tier) {
        $e = $entries[$key]
        $failedDeps = @($e.Dependencies | Where-Object { $status[$_].status -ne 'packed' })
        if ($failedDeps.Count -gt 0) {
            $roots = @($failedDeps | ForEach-Object { $status[$_].rootCause } | Select-Object -Unique)
            $status[$key] = [pscustomobject]@{ repo = $key; status = 'not attempted'; rootCause = ($roots -join ', '); detail = "Upstream failure in $($failedDeps -join ', ')"; packageId = $e.ExpectedId; libTfm = $null }
            Write-Host "::error title=$($e.Name) not attempted::Root cause: $($roots -join ', ')"
            continue
        }

        $log = Join-Path $logDir "$($e.Name).log"
        $sln = Join-Path $e.Dir "$($e.Name).sln"
        $stage = 'start'
        try {
            Write-Host "::group::Build $key"
            if ([string]::IsNullOrEmpty($e.Config)) {
                # DEVIATION: a failed nuget restore stops the build.
                $stage = 'nuget restore'
                Invoke-Logged -FilePath $nuget -Arguments "restore `"$sln`"" -LogFile $log -Repo $key -Stage $stage -TimeoutMinutes $TimeoutMinutes -WorkingDirectory $e.Dir
                $stage = 'msbuild Debug'
                Invoke-Logged -FilePath $msbuild -Arguments "`"$sln`" /v:m /p:Configuration=Debug" -LogFile $log -Repo $key -Stage $stage -TimeoutMinutes $TimeoutMinutes -WorkingDirectory $e.Dir
            }
            else {
                # With a config: Debug first so ProgramData is populated, then clear Build\ and build
                # the named config. DEVIATION: a failed Debug build stops the build.
                # DEVIATION: a failed nuget restore stops the build.
                $stage = 'nuget restore'
                Invoke-Logged -FilePath $nuget -Arguments "restore `"$sln`"" -LogFile $log -Repo $key -Stage $stage -TimeoutMinutes $TimeoutMinutes -WorkingDirectory $e.Dir
                $stage = 'msbuild Debug (pre-config)'
                Invoke-Logged -FilePath $msbuild -Arguments "`"$sln`" /v:m /p:Configuration=Debug" -LogFile $log -Repo $key -Stage $stage -TimeoutMinutes $TimeoutMinutes -WorkingDirectory $e.Dir
                Remove-Item -LiteralPath (Join-Path $e.Dir 'Build') -Recurse -Force
                # DEVIATION: a failed msbuild -restore stops the build.
                $stage = "msbuild -restore $($e.Config)"
                Invoke-Logged -FilePath $msbuild -Arguments "-restore `"$sln`" /p:Configuration=$($e.Config)" -LogFile $log -Repo $key -Stage $stage -TimeoutMinutes $TimeoutMinutes -WorkingDirectory $e.Dir
                $stage = "msbuild $($e.Config)"
                Invoke-Logged -FilePath $msbuild -Arguments "`"$sln`" /v:m /p:Configuration=$($e.Config)" -LogFile $log -Repo $key -Stage $stage -TimeoutMinutes $TimeoutMinutes -WorkingDirectory $e.Dir
            }

            $stage = 'nuspec'
            $depPackages = @($e.Dependencies | ForEach-Object { $packages[$_] })
            $outFolder = Join-Path $BuiltLocation $e.Name
            $pkg = New-BotNuspec -RepoName $e.Name -RepoLocation $e.Dir -OutputFolder $outFolder `
                -Release $release -AssetPaths $assetPaths -DependencyPackages $depPackages
            if ($pkg.Id -cne $e.ExpectedId) { throw "Template package ID is '$($pkg.Id)', config expects '$($e.ExpectedId)'." }

            $stage = 'nuget pack'
            Invoke-Logged -FilePath $nuget -Arguments "pack `"$($pkg.NuspecPath)`" -OutputDirectory `"$outFolder`"" -LogFile $log -Repo $key -Stage $stage -TimeoutMinutes $TimeoutMinutes -WorkingDirectory $outFolder
            $nupkg = Join-Path $outFolder "$($pkg.Id).$Version.nupkg"
            if (-not (Test-Path -LiteralPath $nupkg)) { throw "nuget pack exited 0 but $nupkg does not exist." }

            Copy-Item -LiteralPath $nupkg -Destination $pkgDir -Force
            Copy-Item -LiteralPath $pkg.NuspecPath -Destination (Join-Path $nuspecDir "$($e.Name).input.nuspec") -Force
            $packages[$key] = $pkg
            $status[$key] = [pscustomobject]@{ repo = $key; status = 'packed'; rootCause = $null; detail = "licence from $($pkg.LicenceSource)"; packageId = $pkg.Id; libTfm = $pkg.LibTfm }
            Write-Host '::endgroup::'
        }
        catch {
            Write-Host '::endgroup::'
            $msg = $_.Exception.Message
            $kind = if ($_.Exception -is [System.TimeoutException]) { 'timed out' } else { 'failed' }
            $status[$key] = [pscustomobject]@{ repo = $key; status = $kind; rootCause = $key; detail = "$stage`: $msg"; packageId = $e.ExpectedId; libTfm = $null }
            Write-Host "::error title=$($e.Name) $kind at $stage::$msg"
            if (Test-Path -LiteralPath $log) {
                Select-String -LiteralPath $log -Pattern ': error ' | Select-Object -First 20 | ForEach-Object { Write-Host "::error title=$($e.Name)::$($_.Line.Trim())" }
                Write-Host "--- last 40 lines of $log ---"
                Get-Content -LiteralPath $log -Tail 40 | Write-Host
            }
        }
    }
}

$summary = @($status.Values)
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir 'build-summary.json') -Encoding utf8
$md = @('| Repository | Status | Root cause | lib TFM | Detail |', '|---|---|---|---|---|')
$md += $summary | ForEach-Object { "| $($_.repo) | $($_.status) | $($_.rootCause) | $($_.libTfm) | $($_.detail) |" }
$md | Set-Content -LiteralPath (Join-Path $OutDir 'build-summary.md') -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) { (@('## Build and pack') + $md) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }

$bad = @($summary | Where-Object { $_.status -ne 'packed' })
if ($bad.Count -gt 0) {
    $roots = @($bad | ForEach-Object { $_.rootCause } | ForEach-Object { $_ -split ', ' } | Select-Object -Unique)
    throw "$($bad.Count) of $($summary.Count) repositories did not pack. Root cause: $($roots -join ', ')."
}
$manifest = [ordered]@{
    version   = $Version
    sprint    = $release.Sprint
    cutoffUtc = $pinned.cutoffUtc
    packages  = @(foreach ($e in $config.repos) {
            $file = "$($e.packageId).$Version.nupkg"
            [ordered]@{
                id     = $e.packageId
                file   = $file
                sha256 = (Get-FileHash -LiteralPath (Join-Path $pkgDir $file) -Algorithm SHA256).Hash.ToLowerInvariant()
                tier   = $tierOf[$e.repo]
                repo   = $e.repo
                pin    = $entries[$e.repo].Sha
            }
        })
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir 'manifest.json') -Encoding utf8
Write-Host "All $($summary.Count) packages packed at $Version; manifest.json written."
