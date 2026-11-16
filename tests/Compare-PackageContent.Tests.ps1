<#
Offline tests for Compare-PackageContent.ps1 on packages built in memory: two packs of the same content
compare identical, a changed DLL does not, and the ignored entries change nothing.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/Compare-PackageContent.ps1')

$utf8 = [Text.UTF8Encoding]::new($false)
function E([string]$Name, $Value) { [pscustomobject]@{ n = $Name; v = $Value } }
function New-Package([object[]]$Entries, [string]$Level = 'Optimal', [DateTimeOffset]$Stamp = [DateTimeOffset]::new(2027, 1, 15, 5, 30, 0, [TimeSpan]::Zero)) {
    $ms = [System.IO.MemoryStream]::new()
    $zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($e in $Entries) {
        $entry = $zip.CreateEntry($e.n, [System.IO.Compression.CompressionLevel]$Level)
        $entry.LastWriteTime = $Stamp
        [byte[]]$bytes = if ($e.v -is [byte[]]) { $e.v } else { $utf8.GetBytes([string]$e.v) }
        $s = $entry.Open(); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
    }
    $zip.Dispose()
    return , $ms.ToArray()
}

$dll = [byte[]](77, 90, 144, 0, 3, 0, 0, 0, 4, 0, 0, 0, 255, 255)
$changedDll = [byte[]]$dll.Clone(); $changedDll[13] = 254
$nuspec = '<?xml version="1.0"?><package><metadata><id>BHoM.Interop.Sample</id><version>10.1.0-alpha.1.0</version></metadata></package>'
$base = @(
    (E '_rels/.rels' '<Relationships><Relationship Id="R1" Target="/BHoM.Interop.Sample.nuspec" /></Relationships>')
    (E 'BHoM.Interop.Sample.nuspec' $nuspec)
    (E 'lib/net472/Sample_oM.dll' $dll)
    (E 'icon.png' ([byte[]](137, 80, 78, 71)))
    (E '[Content_Types].xml' '<Types><Default Extension="dll" /></Types>')
    (E 'package/services/metadata/core-properties/0f1e2d3c.psmdcp' '<coreProperties><created>2027-01-15T05:30:00Z</created></coreProperties>')
)
$a = New-Package $base
# A second pack of the same content: other entry order, compression, timestamps and generated parts.
$repack = @(
    (E 'lib/net472/Sample_oM.dll' $dll)
    (E 'package/services/metadata/core-properties/9a8b7c6d.psmdcp' '<coreProperties><created>2027-01-15T06:02:11Z</created></coreProperties>')
    (E 'icon.png' ([byte[]](137, 80, 78, 71)))
    (E 'BHoM.Interop.Sample.nuspec' $nuspec)
    (E '[Content_Types].xml' '<Types><Default Extension="dll" /><Default Extension="png" /></Types>')
    (E '_rels/.rels' '<Relationships><Relationship Id="R9" Target="/BHoM.Interop.Sample.nuspec" /></Relationships>')
)
$b = New-Package $repack 'NoCompression' ([DateTimeOffset]::new(2027, 2, 1, 10, 0, 0, [TimeSpan]::Zero))
$signed = New-Package ($repack + @(E '.signature.p7s' ([byte[]](48, 130, 1, 2))))
$changed = New-Package (@($base | Where-Object { $_.n -ne 'lib/net472/Sample_oM.dll' }) + @(E 'lib/net472/Sample_oM.dll' $changedDll))
$extra = New-Package ($base + @(E 'lib/net472/Extra.dll' $dll))
$renamedCase = New-Package (@($base | Where-Object { $_.n -ne 'lib/net472/Sample_oM.dll' }) + @(E 'lib/NET472/Sample_oM.dll' $dll))
$changedNuspec = New-Package (@($base | Where-Object { $_.n -ne 'BHoM.Interop.Sample.nuspec' }) + @(E 'BHoM.Interop.Sample.nuspec' ($nuspec -replace 'alpha.1.0', 'alpha.2.0')))
$psmdcpElsewhere = New-Package ($base + @(E 'lib/net472/hidden.psmdcp' 'x'))
$duplicate = New-Package ($base + @(E 'lib/net472/Sample_oM.dll' $changedDll))

$failures = 0
function Check([string]$Name, [byte[]]$L, [byte[]]$R, [bool]$Identical, [string]$Detail) {
    $res = Compare-PackageContent -Left $L -Right $R
    $what = "identical=$($res.Identical) differ=[$($res.Differ -join ',')] onlyLeft=[$($res.OnlyLeft -join ',')] onlyRight=[$($res.OnlyRight -join ',')]"
    $detailOk = [string]::IsNullOrEmpty($Detail) -or $what.Contains($Detail)
    if ($res.Identical -eq $Identical -and $detailOk) { Write-Host "PASS  $Name -> $what" }
    else { $script:failures++; Write-Host "FAIL  $Name -> $what" }
}

Check 'two packs of the same content' $a $b $true ''
Check 'nuget.org repository signature is ignored' $a $signed $true ''
Check 'changed DLL' $a $changed $false 'differ=[lib/net472/Sample_oM.dll]'
Check 'changed nuspec' $a $changedNuspec $false 'differ=[BHoM.Interop.Sample.nuspec]'
Check 'extra entry' $a $extra $false 'onlyRight=[lib/net472/Extra.dll]'
Check 'entry name differing only in case' $a $renamedCase $false 'onlyRight=[lib/NET472/Sample_oM.dll]'
Check 'a .psmdcp outside core-properties is compared' $a $psmdcpElsewhere $false 'onlyRight=[lib/net472/hidden.psmdcp]'
try { Compare-PackageContent -Left $a -Right $duplicate | Out-Null; $failures++; Write-Host 'FAIL  duplicate entry name was accepted' }
catch { Write-Host "PASS  duplicate entry name -> refused: $($_.Exception.Message)" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "compare-test-$PID"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    [IO.File]::WriteAllBytes((Join-Path $tmp 'a.nupkg'), $a)
    [IO.File]::WriteAllBytes((Join-Path $tmp 'b.nupkg'), $b)
    [IO.File]::WriteAllBytes((Join-Path $tmp 'c.nupkg'), $changed)
    $shell = (Get-Process -Id $PID).Path
    $script = Join-Path $root 'scripts/Compare-PackageContent.ps1'
    & $shell -NoProfile -NonInteractive -File $script -Left (Join-Path $tmp 'a.nupkg') -Right (Join-Path $tmp 'b.nupkg') | Out-Null
    $same = $LASTEXITCODE
    & $shell -NoProfile -NonInteractive -File $script -Left (Join-Path $tmp 'a.nupkg') -Right (Join-Path $tmp 'c.nupkg') | Out-Null
    $diff = $LASTEXITCODE
    if ($same -eq 0 -and $diff -eq 1) { Write-Host 'PASS  command line exits 0 for identical and 1 for different' }
    else { $failures++; Write-Host "FAIL  command line exit codes: identical $same, different $diff" }
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force }

Write-Host "PowerShell $($PSVersionTable.PSVersion): 9 cases, $failures failed."
if ($failures -gt 0) { exit 1 }
