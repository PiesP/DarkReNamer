[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $InputPath,
    [Parameter(Mandatory)]
    [string] $OutputPath,
    [Parameter(Mandatory)]
    [string] $SerialNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.4') {
    throw 'Release CycloneDX preparation requires PowerShell 7.4 or newer (pwsh).'
}
if ($SerialNumber -cnotmatch
    '^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
    throw 'SerialNumber must be a lowercase RFC 4122 UUID URN.'
}
if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "InputPath must identify an existing CycloneDX JSON file: $InputPath"
}
$resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if ([string]::Equals($resolvedInput, $resolvedOutput, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputPath must differ from InputPath.'
}
$outputParent = Split-Path -Parent $resolvedOutput
if ([string]::IsNullOrEmpty($outputParent) -or
    -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw 'OutputPath parent directory must already exist.'
}
if (Test-Path -LiteralPath $resolvedOutput) {
    throw 'OutputPath already exists; CycloneDX preparation never overwrites a destination.'
}

try {
    $document = Get-Content -LiteralPath $resolvedInput -Raw | ConvertFrom-Json
}
catch {
    throw "InputPath is not valid JSON: $($_.Exception.Message)"
}
if ($null -eq $document -or $document -isnot [pscustomobject]) {
    throw 'CycloneDX input must be a JSON object.'
}
if ($null -eq $document.PSObject.Properties['bomFormat'] -or
    $document.bomFormat -cne 'CycloneDX') {
    throw 'CycloneDX bomFormat must be CycloneDX.'
}
if ($null -eq $document.PSObject.Properties['specVersion'] -or
    $document.specVersion -cne '1.5') {
    throw 'CycloneDX specVersion must be 1.5.'
}
if ($null -eq $document.PSObject.Properties['serialNumber']) {
    $document | Add-Member -NotePropertyName serialNumber -NotePropertyValue $SerialNumber
}
else {
    throw 'CycloneDX input already contains serialNumber; update the pinned generator contract before proceeding.'
}

$json = ($document | ConvertTo-Json -Depth 100) + "`n"
$stream = $null
$writer = $null
try {
    $stream = [IO.File]::Open(
        $resolvedOutput,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    $stream = $null
    $writer.Write($json)
    $writer.Flush()
}
finally {
    if ($null -ne $writer) {
        $writer.Dispose()
    }
    elseif ($null -ne $stream) {
        $stream.Dispose()
    }
}

Write-Host "Prepared CycloneDX SBOM with serial number $SerialNumber."
