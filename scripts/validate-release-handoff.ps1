[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,
    [Parameter(Mandatory)]
    [string] $HandoffRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
$handoffPath = (Resolve-Path -LiteralPath $HandoffRoot).Path

$expectedNames = @(
    'DarkReNamer-debug-symbols.zip'
    'DarkReNamer.cdx.json'
    'DarkReNamer.exe'
    'DarkReNamer.pdb'
    'DISTRIBUTION.md'
    'LICENSE'
    'SHA256SUMS.txt'
    'THIRD_PARTY_NOTICES.md'
)
$actualFiles = @(Get-ChildItem -LiteralPath $handoffPath -File | Sort-Object Name)
$actualNames = @($actualFiles.Name)
$directories = @(Get-ChildItem -LiteralPath $handoffPath -Directory)
if ($directories.Count -ne 0 -or ($actualNames -join "`n") -ne ($expectedNames -join "`n")) {
    throw "Release handoff layout mismatch. Expected: $($expectedNames -join ', '). Actual: $($actualNames -join ', ')."
}

foreach ($file in $actualFiles) {
    if ($file.Length -eq 0) {
        throw "Release handoff file is empty: $($file.Name)"
    }
}

foreach ($name in 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DISTRIBUTION.md') {
    $sourceFile = Join-Path $sourcePath $name
    $handoffFile = Join-Path $handoffPath $name
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Required source policy file is missing: $sourceFile"
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    $handoffHash = (Get-FileHash -LiteralPath $handoffFile -Algorithm SHA256).Hash
    if ($sourceHash -ne $handoffHash) {
        throw "Release handoff file $name does not match the source file."
    }
}

$pdbPath = Join-Path $handoffPath 'DarkReNamer.pdb'
$symbolsPath = Join-Path $handoffPath 'DarkReNamer-debug-symbols.zip'
$archive = [IO.Compression.ZipFile]::OpenRead($symbolsPath)
try {
    $entries = @($archive.Entries)
    if ($entries.Count -ne 1 -or $entries[0].FullName -ne 'DarkReNamer.pdb') {
        throw 'Debug-symbol archive must contain exactly DarkReNamer.pdb at its root.'
    }
    $entryStream = $entries[0].Open()
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $entryHashBytes = $sha256.ComputeHash($entryStream)
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $entryStream.Dispose()
    }
}
finally {
    $archive.Dispose()
}
$entryHash = [Convert]::ToHexString($entryHashBytes).ToLowerInvariant()
$pdbHash = (Get-FileHash -LiteralPath $pdbPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($entryHash -ne $pdbHash) {
    throw 'Debug-symbol archive does not contain the handoff PDB bytes.'
}

$exePath = Join-Path $handoffPath 'DarkReNamer.exe'
$signature = Get-AuthenticodeSignature -FilePath $exePath
if ($signature.Status -ne 'NotSigned') {
    throw "Authenticode status must be NotSigned for the current portable policy; observed $($signature.Status)."
}

$sbomPath = Join-Path $handoffPath 'DarkReNamer.cdx.json'
$sbom = Get-Content -LiteralPath $sbomPath -Raw | ConvertFrom-Json
if ($sbom.bomFormat -ne 'CycloneDX' -or $sbom.specVersion -ne '1.5') {
    throw 'SBOM must be a CycloneDX 1.5 JSON document.'
}
if (@($sbom.components).Count -eq 0) {
    throw 'SBOM must describe at least one component.'
}

$expectedChecksumSubjects = @(
    'DarkReNamer-debug-symbols.zip'
    'DarkReNamer.cdx.json'
    'DarkReNamer.exe'
    'DISTRIBUTION.md'
    'LICENSE'
    'THIRD_PARTY_NOTICES.md'
)
$checksumPath = Join-Path $handoffPath 'SHA256SUMS.txt'
$checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { $_.Length -ne 0 })
if ($checksumLines.Count -ne $expectedChecksumSubjects.Count) {
    throw "Checksum subject count mismatch: expected $($expectedChecksumSubjects.Count), observed $($checksumLines.Count)."
}

$observedSubjects = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
for ($index = 0; $index -lt $checksumLines.Count; $index++) {
    $line = $checksumLines[$index]
    if ($line -notmatch '^([0-9a-f]{64}) \*(.+)$') {
        throw "Invalid checksum line: $line"
    }
    $expectedHash = $Matches[1]
    $name = $Matches[2]
    if ($name -ne $expectedChecksumSubjects[$index]) {
        throw "Checksum subjects must use the canonical sorted order; observed $name at index $index."
    }
    if (-not $observedSubjects.Add($name)) {
        throw "Duplicate checksum subject: $name"
    }
    $actualHash = (Get-FileHash -LiteralPath (Join-Path $handoffPath $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Checksum mismatch for $name."
    }
}

Write-Host "Validated unsigned release handoff at $handoffPath."
