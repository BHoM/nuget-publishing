<#
.SYNOPSIS
Compares two .nupkg files by content: the same set of zip entries and the same SHA-256 per entry.

.DESCRIPTION
Ignored, because they differ between two packs of the same content or are added by nuget.org:
.signature.p7s, _rels/.rels, [Content_Types].xml and package/services/metadata/core-properties/*.psmdcp.
Both packages are read in memory; nothing is extracted.

Dot-source it for the functions, or run it with two paths:
  ./Compare-PackageContent.ps1 -Left a.nupkg -Right b.nupkg     exit 0 if identical, 1 if not
#>
[CmdletBinding()]
param([string]$Left, [string]$Right)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Test-IgnoredPackageEntry([string]$Name) {
    if ($Name -ceq '.signature.p7s' -or $Name -ceq '_rels/.rels' -or $Name -ceq '[Content_Types].xml') { return $true }
    return $Name -cmatch '\Apackage/services/metadata/core-properties/[^/]+\.psmdcp\z'
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PackageEntryHash {
    # Entry name to SHA-256 of its uncompressed bytes, ignored entries left out. A name that appears
    # twice in one archive throws: two entries with one name could show a reader either of them.
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $stream = [System.IO.MemoryStream]::new($Bytes, $false)
    $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        $hashes = [System.Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $zip.Entries) {
            if (-not $seen.Add($entry.FullName)) { throw "The package has two entries named '$($entry.FullName)'." }
            if (Test-IgnoredPackageEntry $entry.FullName) { continue }
            $buffer = [System.IO.MemoryStream]::new()
            $s = $entry.Open()
            try { $s.CopyTo($buffer) } finally { $s.Dispose() }
            $hashes[$entry.FullName] = Get-Sha256Hex $buffer.ToArray()
        }
        return , $hashes
    }
    finally { $zip.Dispose(); $stream.Dispose() }
}

function Compare-PackageContent {
    param([Parameter(Mandatory)][byte[]]$Left, [Parameter(Mandatory)][byte[]]$Right)
    $l = Get-PackageEntryHash -Bytes $Left
    $r = Get-PackageEntryHash -Bytes $Right
    $onlyLeft = @($l.Keys | Where-Object { -not $r.ContainsKey($_) })
    $onlyRight = @($r.Keys | Where-Object { -not $l.ContainsKey($_) })
    $differ = @($l.Keys | Where-Object { $r.ContainsKey($_) -and $l[$_] -cne $r[$_] })
    return [pscustomobject]@{
        Identical = ($onlyLeft.Count + $onlyRight.Count + $differ.Count) -eq 0
        OnlyLeft  = $onlyLeft
        OnlyRight = $onlyRight
        Differ    = $differ
    }
}

if ($Left -or $Right) {
    if (-not ($Left -and $Right)) { throw 'Give both -Left and -Right.' }
    $result = Compare-PackageContent -Left ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Left).Path)) -Right ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Right).Path))
    if ($result.Identical) { Write-Host "Identical content: $Left and $Right"; exit 0 }
    foreach ($n in $result.OnlyLeft) { Write-Host "only in left:  $n" }
    foreach ($n in $result.OnlyRight) { Write-Host "only in right: $n" }
    foreach ($n in $result.Differ) { Write-Host "differs:       $n" }
    exit 1
}
