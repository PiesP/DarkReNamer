[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,
    [Parameter(Mandatory)]
    [string] $HandoffRoot,
    [switch] $PassThru
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
    'release-handoff.json'
    'release-metrics.json'
    'SHA256SUMS.txt'
    'THIRD_PARTY_LICENSES.html'
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

function Assert-ObjectShape {
    param(
        [Parameter(Mandatory)]
        [object] $Object,
        [Parameter(Mandatory)]
        [string[]] $Required,
        [Parameter(Mandatory)]
        [string] $Location
    )

    if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
        throw "$Location must be a JSON object."
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Required) {
        [void] $expected.Add($name)
    }
    foreach ($property in $Object.PSObject.Properties) {
        if (-not $expected.Contains($property.Name)) {
            throw "$Location contains an unsupported field: $($property.Name)."
        }
    }
    foreach ($name in $Required) {
        if ($null -eq $Object.PSObject.Properties[$name] -or $null -eq $Object.$name) {
            throw "$Location is missing required field: $name."
        }
    }
}

function Assert-UniqueJsonProperties {
    param(
        [Parameter(Mandatory)]
        [Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)]
        [string] $Location
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $observed.Add($property.Name)) {
                throw "$Location contains a duplicate field: $($property.Name)."
            }
            Assert-UniqueJsonProperties -Element $property.Value -Location "$Location.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-UniqueJsonProperties -Element $item -Location "$Location[$index]"
            $index++
        }
    }
}

function Assert-PositiveJsonInteger {
    param(
        [Parameter(Mandatory)]
        [Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)]
        [string] $Location
    )

    $value = [long] 0
    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
        -not $Element.TryGetInt64([ref] $value) -or
        $value -le 0) {
        throw "$Location must be a positive JSON integer."
    }
    return $value
}

$provenancePath = Join-Path $handoffPath 'release-handoff.json'
try {
    $provenanceJson = Get-Content -LiteralPath $provenancePath -Raw
    $provenanceDocument = [Text.Json.JsonDocument]::Parse($provenanceJson)
}
catch {
    throw "release-handoff.json is not valid JSON: $($_.Exception.Message)"
}
try {
    if ($provenanceDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
        throw 'release-handoff must be a JSON object.'
    }
    Assert-UniqueJsonProperties -Element $provenanceDocument.RootElement -Location 'release-handoff'
    $provenance = $provenanceJson | ConvertFrom-Json
}
finally {
    $provenanceDocument.Dispose()
}

Assert-ObjectShape `
    -Object $provenance `
    -Required @('schema_version', 'source_sha', 'workflow_run', 'executable') `
    -Location 'release-handoff'
Assert-ObjectShape `
    -Object $provenance.executable `
    -Required @('filename', 'sha256') `
    -Location 'release-handoff.executable'

if ($provenance.schema_version -is [string] -or
    $provenance.schema_version -is [bool] -or
    [decimal] $provenance.schema_version -ne 1) {
    throw 'release-handoff.schema_version must be the JSON number 1.'
}
if ($provenance.source_sha -isnot [string] -or $provenance.source_sha -cnotmatch '^[0-9a-f]{40}$') {
    throw 'release-handoff.source_sha must be a full lowercase 40-character Git SHA.'
}
if ($provenance.workflow_run -isnot [string] -or $provenance.workflow_run -notmatch '^[1-9][0-9]*$') {
    throw 'release-handoff.workflow_run must be a positive numeric GitHub Actions run ID.'
}
if ($provenance.executable.filename -isnot [string] -or
    -not [string]::Equals($provenance.executable.filename, 'DarkReNamer.exe', [StringComparison]::Ordinal)) {
    throw 'release-handoff.executable.filename must be DarkReNamer.exe.'
}
if ($provenance.executable.sha256 -isnot [string] -or
    $provenance.executable.sha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'release-handoff.executable.sha256 must be a lowercase 64-character SHA-256 digest.'
}

$sourceTopLevel = @(& git -C $sourcePath rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0 -or $sourceTopLevel.Count -ne 1) {
    throw 'SourceRoot must identify a Git worktree root.'
}
$resolvedTopLevel = [IO.Path]::GetFullPath($sourceTopLevel[0]).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$resolvedSourcePath = [IO.Path]::GetFullPath($sourcePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not [string]::Equals($resolvedTopLevel, $resolvedSourcePath, $pathComparison)) {
    throw 'SourceRoot must identify the exact Git worktree root.'
}
$sourceHead = @(& git -C $sourcePath rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $sourceHead.Count -ne 1 -or $sourceHead[0] -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Source HEAD could not be resolved as a full Git SHA.'
}
if (-not [string]::Equals($provenance.source_sha, $sourceHead[0], [StringComparison]::Ordinal)) {
    throw 'release-handoff.source_sha does not match source HEAD.'
}

$metricsPath = Join-Path $handoffPath 'release-metrics.json'
try {
    $metricsJson = Get-Content -LiteralPath $metricsPath -Raw
    $metricsDocument = [Text.Json.JsonDocument]::Parse($metricsJson)
}
catch {
    throw "release-metrics.json is not valid JSON: $($_.Exception.Message)"
}
try {
    if ($metricsDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
        throw 'release-metrics must be a JSON object.'
    }
    Assert-UniqueJsonProperties -Element $metricsDocument.RootElement -Location 'release-metrics'
    $metrics = $metricsJson | ConvertFrom-Json
    Assert-ObjectShape `
        -Object $metrics `
        -Required @(
            'schema_version'
            'source_sha'
            'rustc_version'
            'target_triple'
            'darkrenamer_exe_bytes'
            'darkrenamer_text_raw_bytes'
            'debug_symbols_pdb_bytes'
            'debug_symbols_zip_bytes'
            'sbom_bytes'
            'cargo_lock_package_count'
        ) `
        -Location 'release-metrics'
    $schemaVersionElement = $metricsDocument.RootElement.GetProperty('schema_version').Clone()
    $numericElements = @{}
    foreach ($name in @(
        'darkrenamer_exe_bytes'
        'darkrenamer_text_raw_bytes'
        'debug_symbols_pdb_bytes'
        'debug_symbols_zip_bytes'
        'sbom_bytes'
        'cargo_lock_package_count'
    )) {
        $numericElements[$name] = $metricsDocument.RootElement.GetProperty($name).Clone()
    }
}
finally {
    $metricsDocument.Dispose()
}

$schemaVersion = [long] 0
if ($schemaVersionElement.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
    -not $schemaVersionElement.TryGetInt64([ref] $schemaVersion) -or
    $schemaVersion -ne 2) {
    throw 'release-metrics.schema_version must be the JSON integer 2.'
}
if ($metrics.source_sha -isnot [string] -or $metrics.source_sha -cnotmatch '^[0-9a-f]{40}$') {
    throw 'release-metrics.source_sha must be a full lowercase 40-character Git SHA.'
}
if (-not [string]::Equals($metrics.source_sha, $provenance.source_sha, [StringComparison]::Ordinal) -or
    -not [string]::Equals($metrics.source_sha, $sourceHead[0], [StringComparison]::Ordinal)) {
    throw 'release-metrics.source_sha does not match release-handoff.source_sha and source HEAD.'
}
if ($metrics.rustc_version -isnot [string] -or
    $metrics.rustc_version.Length -eq 0 -or
    $metrics.rustc_version.Length -gt 256 -or
    $metrics.rustc_version -match '[\r\n]') {
    throw 'release-metrics.rustc_version must be a nonempty single-line string of at most 256 characters.'
}
$rustcVersionMatch = [regex]::Match(
    $metrics.rustc_version,
    '^rustc (?<version>[0-9]+\.[0-9]+\.[0-9]+)(?:$|[ +(-])'
)
if (-not $rustcVersionMatch.Success) {
    throw 'release-metrics.rustc_version must begin with rustc and a semantic version.'
}
$toolchainPath = Join-Path $sourcePath 'rust-toolchain.toml'
if (-not (Test-Path -LiteralPath $toolchainPath -PathType Leaf)) {
    throw 'Required source rust-toolchain.toml is missing.'
}
$toolchainText = Get-Content -LiteralPath $toolchainPath -Raw
$toolchainMatches = [regex]::Matches(
    $toolchainText,
    '(?m)^\s*channel\s*=\s*"([^"]+)"\s*(?:#.*)?$'
)
if ($toolchainMatches.Count -ne 1 -or $toolchainMatches[0].Groups[1].Value -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw 'rust-toolchain.toml must define one exact semantic-version channel.'
}
$toolchainChannel = $toolchainMatches[0].Groups[1].Value
if (-not [string]::Equals(
    $rustcVersionMatch.Groups['version'].Value,
    $toolchainChannel,
    [StringComparison]::Ordinal
)) {
    throw 'release-metrics.rustc_version does not match rust-toolchain.toml channel.'
}
if ($metrics.target_triple -isnot [string] -or
    -not [string]::Equals($metrics.target_triple, 'x86_64-pc-windows-msvc', [StringComparison]::Ordinal)) {
    throw 'release-metrics.target_triple must be x86_64-pc-windows-msvc.'
}

$metricValues = @{}
foreach ($name in $numericElements.Keys) {
    $metricValues[$name] = Assert-PositiveJsonInteger `
        -Element $numericElements[$name] `
        -Location "release-metrics.$name"
}

$expectedByteCounts = @{
    darkrenamer_exe_bytes = (Get-Item -LiteralPath (Join-Path $handoffPath 'DarkReNamer.exe')).Length
    debug_symbols_pdb_bytes = (Get-Item -LiteralPath (Join-Path $handoffPath 'DarkReNamer.pdb')).Length
    debug_symbols_zip_bytes = (Get-Item -LiteralPath (Join-Path $handoffPath 'DarkReNamer-debug-symbols.zip')).Length
    sbom_bytes = (Get-Item -LiteralPath (Join-Path $handoffPath 'DarkReNamer.cdx.json')).Length
}
foreach ($name in $expectedByteCounts.Keys) {
    if ($metricValues[$name] -ne $expectedByteCounts[$name]) {
        throw "release-metrics.$name does not match the handoff file bytes."
    }
}

$cargoLockPath = Join-Path $sourcePath 'Cargo.lock'
if (-not (Test-Path -LiteralPath $cargoLockPath -PathType Leaf)) {
    throw 'Required source Cargo.lock is missing.'
}
$cargoLockPackageCount = [regex]::Matches(
    (Get-Content -LiteralPath $cargoLockPath -Raw),
    '(?m)^\[\[package\]\]\s*$'
).Count
if ($cargoLockPackageCount -le 0) {
    throw 'Source Cargo.lock must contain at least one [[package]] table.'
}
if ($metricValues['cargo_lock_package_count'] -ne $cargoLockPackageCount) {
    throw 'release-metrics.cargo_lock_package_count does not match source Cargo.lock.'
}

$provenanceExePath = Join-Path $handoffPath $provenance.executable.filename
$provenanceExeHash = (Get-FileHash -LiteralPath $provenanceExePath -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not [string]::Equals($provenance.executable.sha256, $provenanceExeHash, [StringComparison]::Ordinal)) {
    throw 'release-handoff.executable.sha256 does not match the handoff executable bytes.'
}

foreach ($name in 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DISTRIBUTION.md') {
    $sourceFile = Join-Path $sourcePath $name
    $handoffFile = Join-Path $handoffPath $name
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Required source policy file is missing: $sourceFile"
    }
    $sourceBytes = [IO.File]::ReadAllBytes($sourceFile)
    if ([Array]::IndexOf($sourceBytes, [byte] 13) -ge 0) {
        throw "Required source policy file $name must use canonical LF line endings."
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

$measurerPath = Join-Path $PSScriptRoot 'measure-windows-binary.ps1'
if (-not (Test-Path -LiteralPath $measurerPath -PathType Leaf)) {
    throw 'Required Windows binary measurement script is missing.'
}
$measurementPath = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "darkrenamer-handoff-measurement-$([Guid]::NewGuid().ToString('N')).json"
try {
    & $measurerPath `
        -ExecutablePath (Join-Path $handoffPath 'DarkReNamer.exe') `
        -PdbPath $pdbPath `
        -DebugSymbolsZipPath $symbolsPath `
        -OutputPath $measurementPath `
        6>$null
    $binaryMeasurement = Get-Content -LiteralPath $measurementPath -Raw | ConvertFrom-Json
}
finally {
    if (Test-Path -LiteralPath $measurementPath) {
        Remove-Item -LiteralPath $measurementPath
    }
}
if ($metricValues['darkrenamer_text_raw_bytes'] -ne $binaryMeasurement.pe.text_raw_bytes) {
    throw 'release-metrics.darkrenamer_text_raw_bytes does not match the executable .text raw bytes.'
}
if ($metricValues['debug_symbols_pdb_bytes'] -ne $binaryMeasurement.debug_symbols.pdb_bytes) {
    throw 'release-metrics.debug_symbols_pdb_bytes does not match the measured PDB bytes.'
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
if ($null -eq $sbom.PSObject.Properties['serialNumber'] -or
    $sbom.serialNumber -isnot [string] -or
    $sbom.serialNumber -cnotmatch
    '^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
    throw 'SBOM serialNumber must be a lowercase RFC 4122 UUID URN.'
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
    'release-handoff.json'
    'release-metrics.json'
    'THIRD_PARTY_LICENSES.html'
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

if ($PassThru) {
    return $provenance
}
Write-Host "Validated unsigned release handoff at $handoffPath."
