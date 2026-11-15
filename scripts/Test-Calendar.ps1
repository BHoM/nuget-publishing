<#
.SYNOPSIS
Validates calendar.json. Fails with one line per broken rule, each tagged with the rule name.

.DESCRIPTION
Rules:
  json             the file is valid JSON, with no key repeated within an object
  root-array       the top level is an array
  event-object     every element is an object
  unknown-key      only date, version, sprint and skip are allowed, case-sensitive,
                   so a misspelt skip cannot be ignored and publish the event
  date-format      date is a string in yyyy-MM-dd and a real calendar date
  version-format   version matches M.m.0-alpha.S.P or M.m.0-beta.P, digits only, no leading zeros,
                   lower case
  version-unique   no version appears twice
  skip-type        skip, if present, is true or false
  sprint-type      sprint, if present, is a positive integer
  beta-sprint      a beta carries sprint, because its version holds no sprint number
  alpha-sprint     an alpha that carries sprint carries the number in its version

Runs under Windows PowerShell 5.1 and PowerShell 7. PowerShell 7's ConvertFrom-Json turns date-like
strings into DateTime values, which would hide the original text, so under 7 the file is read with
System.Text.Json instead. 5.1's ConvertFrom-Json keeps the last of two identical keys without a word,
so under 5.1 the keys are first checked through the JSON-to-XML reader, which keeps every one.
#>
param(
    [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'calendar.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-JsonElement($Element) {
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $o = [ordered]@{}
            foreach ($p in $Element.EnumerateObject()) {
                if ($o.Contains($p.Name)) { throw "duplicate key '$($p.Name)'" }
                $o[$p.Name] = ConvertFrom-JsonElement $p.Value
            }
            return [pscustomobject]$o
        }
        'Array' { return , @(foreach ($i in $Element.EnumerateArray()) { ConvertFrom-JsonElement $i }) }
        'String' { return $Element.GetString() }
        'Number' {
            $raw = $Element.GetRawText()
            if ($raw -match '^-?[0-9]+$') { return [long]$raw }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
    }
    throw "unexpected JSON value kind $($Element.ValueKind)"
}

function Read-Json([string]$Text) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $doc = [System.Text.Json.JsonDocument]::Parse($Text)
        try { return , (ConvertFrom-JsonElement $doc.RootElement) }
        finally { $doc.Dispose() }
    }
    Assert-UniqueKey $Text
    return , (ConvertFrom-Json -InputObject $Text)
}

function Assert-UniqueKey([string]$Text) {
    Add-Type -AssemblyName System.Runtime.Serialization
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $reader = [System.Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader($bytes, [System.Xml.XmlDictionaryReaderQuotas]::Max)
    $xml = [System.Xml.XmlDocument]::new()
    try { $xml.Load($reader) }
    finally { $reader.Close() }
    foreach ($object in $xml.SelectNodes('//*[@type="object"]')) {
        $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($member in $object.ChildNodes) {
            $name = if ($member.HasAttribute('item')) { $member.GetAttribute('item') } else { $member.LocalName }
            if (-not $names.Add($name)) { throw "duplicate key '$name'" }
        }
    }
}

function Test-Integer($Value) {
    return ($Value -is [int] -or $Value -is [long]) -and -not ($Value -is [bool])
}

function Get-TypeName($Value) {
    if ($null -eq $Value) { return 'null' }
    return $Value.GetType().Name
}

function Get-Field($Item, [string]$Name) {
    $p = $Item.PSObject.Properties | Where-Object { $_.Name -ceq $Name }
    if ($p) { return , $p.Value }
    return $null
}

$errors = [System.Collections.Generic.List[string]]::new()
function Add-Error([string]$Rule, [string]$Message) { $errors.Add("[$Rule] $Message") }

$allowedKeys = @('date', 'version', 'sprint', 'skip')
$n = '(0|[1-9][0-9]*)'
$versionPattern = "\A$n\.$n\.0-(alpha\.$n\.$n|beta\.$n)\z"

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Calendar not found: $Path" }
$text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)

$root = $null
try { $root = Read-Json $text }
catch { Add-Error 'json' "$Path is not valid JSON: $($_.Exception.Message)" }

if ($errors.Count -eq 0 -and -not ($root -is [array])) {
    Add-Error 'root-array' "the top level of $Path must be an array of events."
}

if ($errors.Count -eq 0) {
    $seen = @{}
    for ($i = 0; $i -lt $root.Count; $i++) {
        $e = $root[$i]
        $where = "event $($i + 1)"
        if (-not ($e -is [System.Management.Automation.PSCustomObject])) {
            Add-Error 'event-object' "$where is not an object."
            continue
        }
        $keys = @($e.PSObject.Properties | ForEach-Object { $_.Name })
        $version = Get-Field $e 'version'
        if ($version -is [string]) { $where = "$where ($version)" }
        foreach ($k in $keys) {
            if ($k -cnotin $allowedKeys) { Add-Error 'unknown-key' "$where has key '$k'; allowed keys are $($allowedKeys -join ', ')." }
        }
        $hasKey = { param($Name) $keys -ccontains $Name }

        $date = Get-Field $e 'date'
        $parsed = [DateTime]::MinValue
        if (-not (& $hasKey 'date')) { Add-Error 'date-format' "$where has no date." }
        elseif (-not ($date -is [string]) -or -not [DateTime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            Add-Error 'date-format' "$where has date '$date'; it must be a real date written yyyy-MM-dd."
        }

        $kind = $null
        if (-not (& $hasKey 'version')) { Add-Error 'version-format' "$where has no version." }
        elseif (-not ($version -is [string]) -or $version -cnotmatch $versionPattern) {
            Add-Error 'version-format' "$where has version '$version'; it must look like 10.1.0-alpha.1.0 or 10.1.0-beta.0."
        }
        else {
            $kind = $version.Split('-')[1].Split('.')[0]
            if ($seen.ContainsKey($version)) { Add-Error 'version-unique' "$where repeats version $version, first used by event $($seen[$version])." }
            else { $seen[$version] = $i + 1 }
        }

        if ((& $hasKey 'skip') -and -not ((Get-Field $e 'skip') -is [bool])) {
            Add-Error 'skip-type' "$where has skip '$(Get-Field $e 'skip')' of type $(Get-TypeName (Get-Field $e 'skip')); it must be the JSON value true or false."
        }

        $sprint = Get-Field $e 'sprint'
        $sprintOk = $false
        if (& $hasKey 'sprint') {
            if ((Test-Integer $sprint) -and $sprint -gt 0) { $sprintOk = $true }
            else { Add-Error 'sprint-type' "$where has sprint '$sprint' of type $(Get-TypeName $sprint); it must be a positive integer." }
        }
        if ($kind -eq 'beta' -and -not (& $hasKey 'sprint')) {
            Add-Error 'beta-sprint' "$where is a beta and has no sprint. The release notes name a sprint, and a beta version does not carry one."
        }
        if ($kind -eq 'alpha' -and $sprintOk) {
            $fromVersion = [long]$version.Split('-')[1].Split('.')[1]
            if ($sprint -ne $fromVersion) { Add-Error 'alpha-sprint' "$where carries sprint $sprint but its version says sprint $fromVersion." }
        }
    }
}

$annotate = $env:GITHUB_ACTIONS -eq 'true'
foreach ($m in $errors) { if ($annotate) { Write-Host "::error title=calendar.json::$m" } else { Write-Host "ERROR: $m" } }
if ($errors.Count -gt 0) {
    Write-Host "calendar.json: $($errors.Count) problem(s)."
    exit 1
}
Write-Host "calendar.json: $($root.Count) events, all rules pass."
exit 0
