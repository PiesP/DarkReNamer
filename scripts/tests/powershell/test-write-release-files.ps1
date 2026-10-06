[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
$toolingScriptsRoot = $toolingTestPaths.ScriptsRoot
. (Join-Path $toolingScriptsRoot 'tests/support/windows-binary-fixture.ps1')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$writer = Join-Path $toolingScriptsRoot 'write-release-files.ps1'
$validator = Join-Path $toolingScriptsRoot 'validate-release-handoff.ps1'
if (-not (Test-Path -LiteralPath $writer -PathType Leaf)) {
    throw "Release file writer is missing: $writer"
}

function Write-TestText {
    param([string] $Path, [string] $Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Assert-NoGeneratedFiles {
    param([string] $HandoffRoot)
    foreach ($name in 'release-metrics.json', 'release-handoff.json', 'SHA256SUMS.txt') {
        if (Test-Path -LiteralPath (Join-Path $HandoffRoot $name)) {
            throw "Unexpected generated release file: $name"
        }
    }
}

function Assert-WriterFails {
    param(
        [string] $ExpectedFragment,
        [hashtable] $Arguments,
        [string] $MeasurementPath
    )
    try {
        & $writer @Arguments
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedFragment*") {
            throw "Expected '$ExpectedFragment', received: $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $MeasurementPath) {
            throw 'Temporary binary measurement survived failed release file generation.'
        }
        return
    }
    throw "Expected release file generation to fail with: $ExpectedFragment"
}

function Assert-Utf8NoBomNewline {
    param([string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) -or
        $bytes[$bytes.Length - 1] -ne 0x0a) {
        throw "Release output must be UTF-8 without BOM and end in LF: $Path"
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-release-files-$([Guid]::NewGuid())"
$sourceRoot = Join-Path $testRoot 'source'
$handoffRoot = Join-Path $testRoot 'dist'
$temporaryRoot = Join-Path $testRoot 'temporary'
$runId = '33257061299'
$runAttempt = '2'
$measurementPath = Join-Path $temporaryRoot "darkrenamer-release-binary-$runId-$runAttempt.json"
$rustcFails = $false
$global:DarkReNamerTestRustcCalls = 0

function rustc {
    param([string] $Option)
    $global:DarkReNamerTestRustcCalls++
    if ($Option -cne '--version') { throw 'Unexpected rustc fixture argument.' }
    if ($rustcFails) {
        $global:LASTEXITCODE = 1
        'rustc fixture failed'
    }
    else {
        $global:LASTEXITCODE = 0
        'rustc 1.97.1 (fixture 2026-08-01)'
    }
}

try {
    $null = New-Item -ItemType Directory -Path $sourceRoot, $handoffRoot, $temporaryRoot
    foreach ($name in 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DISTRIBUTION.md') {
        Write-TestText -Path (Join-Path $sourceRoot $name) -Content "$name source policy`n"
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination $handoffRoot
    }
    Write-TestText -Path (Join-Path $sourceRoot 'rust-toolchain.toml') `
        -Content "[toolchain]`nchannel = `"1.97.1`"`n"
    $cargoLock = Join-Path $sourceRoot 'Cargo.lock'
    $lockText = "version = 4`n`n[[package]]`nname = `"fixture-a`"`nversion = `"0.1.0`"`n`n[[package]]`nname = `"fixture-b`"`nversion = `"0.2.0`"`n"
    Write-TestText -Path $cargoLock -Content $lockText

    & git -C $sourceRoot init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize release source fixture.' }
    & git -C $sourceRoot config user.name 'DarkReNamer test'
    & git -C $sourceRoot config user.email 'darkrenamer-test@example.invalid'
    & git -C $sourceRoot add -- LICENSE THIRD_PARTY_NOTICES.md DISTRIBUTION.md rust-toolchain.toml Cargo.lock
    & git -C $sourceRoot commit --quiet -m 'test: initialize release source fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit release source fixture.' }
    $sourceSha = (& git -C $sourceRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Failed to resolve release source SHA.' }

    $null = Write-WindowsBinaryFixture -Root $handoffRoot
    $executablePath = Join-Path $handoffRoot 'DarkReNamer.exe'
    $pdbPath = Join-Path $handoffRoot 'DarkReNamer.pdb'
    $symbolsPath = Join-Path $handoffRoot 'DarkReNamer-debug-symbols.zip'
    Compress-Archive -LiteralPath $pdbPath -DestinationPath $symbolsPath
    Write-TestText -Path (Join-Path $handoffRoot 'DarkReNamer.cdx.json') `
        -Content '{"bomFormat":"CycloneDX","specVersion":"1.5","serialNumber":"urn:uuid:12345678-1234-4234-9234-123456789abc","components":[{"type":"application","name":"darknamer-app","version":"0.1.0"}]}'
    Write-TestText -Path (Join-Path $handoffRoot 'THIRD_PARTY_LICENSES.html') `
        -Content '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Third-party licenses for DarkReNamer</title></head><body><h1>Third-party licenses for DarkReNamer</h1><pre class="license-text">fixture license text</pre></body></html>'

    $importOutput = @(& { . $writer })
    Assert-NoGeneratedFiles -HandoffRoot $handoffRoot
    if ($importOutput.Count -ne 0 -or $global:DarkReNamerTestRustcCalls -ne 0 -or
        (Test-Path -LiteralPath $measurementPath)) {
        throw 'Importing the release writer ran tooling or produced output.'
    }

    $arguments = @{
        SourceRoot = $sourceRoot
        HandoffRoot = $handoffRoot
        SourceSha = $sourceSha
        RunId = $runId
        RunAttempt = $runAttempt
        TemporaryRoot = $temporaryRoot
    }
    & $writer @arguments
    if (Test-Path -LiteralPath $measurementPath) {
        throw 'Temporary binary measurement survived successful release file generation.'
    }
    $metricsPath = Join-Path $handoffRoot 'release-metrics.json'
    $handoffPath = Join-Path $handoffRoot 'release-handoff.json'
    $checksumsPath = Join-Path $handoffRoot 'SHA256SUMS.txt'
    foreach ($path in $metricsPath, $handoffPath, $checksumsPath) {
        Assert-Utf8NoBomNewline -Path $path
    }
    $metrics = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
    $handoff = Get-Content -LiteralPath $handoffPath -Raw | ConvertFrom-Json
    if (($metrics.PSObject.Properties.Name -join ',') -cne 'schema_version,source_sha,rustc_version,target_triple,darkrenamer_exe_bytes,darkrenamer_text_raw_bytes,debug_symbols_pdb_bytes,debug_symbols_zip_bytes,sbom_bytes,cargo_lock_package_count' -or
        $metrics.schema_version -ne 2 -or $metrics.source_sha -cne $sourceSha -or
        $metrics.rustc_version -cne 'rustc 1.97.1 (fixture 2026-08-01)' -or
        $metrics.target_triple -cne 'x86_64-pc-windows-msvc' -or
        $metrics.darkrenamer_exe_bytes -ne 0x500 -or $metrics.darkrenamer_text_raw_bytes -ne 0x200 -or
        $metrics.debug_symbols_pdb_bytes -ne 0xa00 -or
        $metrics.debug_symbols_zip_bytes -ne (Get-Item -LiteralPath $symbolsPath).Length -or
        $metrics.sbom_bytes -ne (Get-Item -LiteralPath (Join-Path $handoffRoot 'DarkReNamer.cdx.json')).Length -or
        $metrics.cargo_lock_package_count -ne 2 -or
        ($handoff.PSObject.Properties.Name -join ',') -cne 'schema_version,source_sha,workflow_run,executable' -or
        $handoff.schema_version -ne 1 -or $handoff.source_sha -cne $sourceSha -or
        $handoff.workflow_run -cne $runId -or
        $handoff.executable.filename -cne 'DarkReNamer.exe' -or
        $handoff.executable.sha256 -cne (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Release metrics or handoff did not preserve the expected source-bound schema and values.'
    }
    $expectedNames = @(
        'DarkReNamer-debug-symbols.zip', 'DarkReNamer.cdx.json', 'DarkReNamer.exe',
        'DISTRIBUTION.md', 'LICENSE', 'release-handoff.json', 'release-metrics.json',
        'THIRD_PARTY_LICENSES.html', 'THIRD_PARTY_NOTICES.md'
    )
    $actualLines = @(Get-Content -LiteralPath $checksumsPath)
    $expectedLines = foreach ($name in $expectedNames) {
        "$((Get-FileHash -LiteralPath (Join-Path $handoffRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()) *$name"
    }
    if (($actualLines -join "`n") -cne ($expectedLines -join "`n")) {
        throw 'Release checksum subjects, order, or hashes changed.'
    }

    $global:DarkReNamerTestAuthenticodeStatus = 'NotSigned'
    function global:Get-AuthenticodeSignature {
        param([string] $FilePath)
        [pscustomobject]@{ Path = $FilePath; Status = $global:DarkReNamerTestAuthenticodeStatus }
    }
    $validated = @(& $validator -SourceRoot $sourceRoot -HandoffRoot $handoffRoot -PassThru 6>&1)
    if ($validated.Count -ne 1 -or $validated[0].source_sha -cne $sourceSha) {
        throw 'Existing handoff validator rejected the writer output.'
    }

    $originalChecksums = Get-Content -LiteralPath $checksumsPath -Raw
    Write-TestText -Path $checksumsPath -Content "stale checksum file`n"
    & $writer @arguments
    if ((Get-Content -LiteralPath $checksumsPath -Raw) -cne $originalChecksums) {
        throw 'Rerunning the writer changed checksum subjects or generated bytes.'
    }
    Remove-Item -LiteralPath $metricsPath, $handoffPath, $checksumsPath

    $fakeWriterRoot = Join-Path $testRoot 'missing-measurement-writer'
    $null = New-Item -ItemType Directory -Path $fakeWriterRoot
    $fakeWriter = Join-Path $fakeWriterRoot 'write-release-files.ps1'
    Copy-Item -LiteralPath $writer -Destination $fakeWriter
    Write-TestText -Path (Join-Path $fakeWriterRoot 'measure-windows-binary.ps1') -Content 'param($ExecutablePath, $PdbPath, $DebugSymbolsZipPath, $OutputPath)'
    try {
        & $fakeWriter @arguments
        throw 'Writer accepted a missing measurement output.'
    }
    catch {
        if ($_.Exception.Message -notlike '*darkrenamer-release-binary*' -or
            (Test-Path -LiteralPath $measurementPath)) {
            throw "Missing measurement did not fail cleanly: $($_.Exception.Message)"
        }
    }
    Assert-NoGeneratedFiles -HandoffRoot $handoffRoot

    $exeBytes = [IO.File]::ReadAllBytes($executablePath)
    $exeBytes[0] = 0
    [IO.File]::WriteAllBytes($executablePath, $exeBytes)
    Assert-WriterFails -ExpectedFragment 'MZ header' -Arguments $arguments -MeasurementPath $measurementPath
    Assert-NoGeneratedFiles -HandoffRoot $handoffRoot
    [IO.File]::WriteAllBytes($executablePath, (New-PeFixture))

    Write-TestText -Path $measurementPath -Content "preexisting measurement`n"
    Assert-WriterFails -ExpectedFragment 'OutputPath already exists' -Arguments $arguments -MeasurementPath $measurementPath
    Assert-NoGeneratedFiles -HandoffRoot $handoffRoot

    $rustcFails = $true
    Assert-WriterFails -ExpectedFragment 'rustc version could not be resolved' -Arguments $arguments -MeasurementPath $measurementPath
    Assert-NoGeneratedFiles -HandoffRoot $handoffRoot
    $rustcFails = $false

    Write-TestText -Path $cargoLock -Content "version = 4`n"
    Assert-WriterFails -ExpectedFragment 'did not contain any package tables' -Arguments $arguments -MeasurementPath $measurementPath
    Assert-NoGeneratedFiles -HandoffRoot $handoffRoot
    Write-TestText -Path $cargoLock -Content $lockText

    $sbomPath = Join-Path $handoffRoot 'DarkReNamer.cdx.json'
    $sbomText = Get-Content -LiteralPath $sbomPath -Raw
    Remove-Item -LiteralPath $sbomPath
    Assert-WriterFails -ExpectedFragment 'DarkReNamer.cdx.json' -Arguments $arguments -MeasurementPath $measurementPath
    Assert-NoGeneratedFiles -HandoffRoot $handoffRoot
    Write-TestText -Path $sbomPath -Content $sbomText

    $null = New-Item -ItemType Directory -Path $metricsPath
    Assert-WriterFails -ExpectedFragment 'release-metrics.json' -Arguments $arguments -MeasurementPath $measurementPath
    Remove-Item -LiteralPath $metricsPath
    Assert-NoGeneratedFiles -HandoffRoot $handoffRoot

    $null = New-Item -ItemType Directory -Path $handoffPath
    Assert-WriterFails -ExpectedFragment 'release-handoff.json' -Arguments $arguments -MeasurementPath $measurementPath
    if (-not (Test-Path -LiteralPath $metricsPath -PathType Leaf) -or
        (Test-Path -LiteralPath $checksumsPath)) {
        throw 'Release output write ordering changed on handoff failure.'
    }
    Remove-Item -LiteralPath $metricsPath, $handoffPath

    Write-Host 'Release file writer tests passed.'
}
finally {
    Remove-Variable DarkReNamerTestRustcCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Get-AuthenticodeSignature -ErrorAction SilentlyContinue
    Remove-Variable DarkReNamerTestAuthenticodeStatus -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
