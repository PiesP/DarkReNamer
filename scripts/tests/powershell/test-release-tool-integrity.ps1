[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
$repoRoot = Split-Path -Parent $toolingTestPaths.ScriptsRoot
$installer = Join-Path $toolingTestPaths.ScriptsRoot 'install-verified-release-tools.ps1'
$sourceRecord = Join-Path $repoRoot 'config/release-tool-integrity.json'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Record {
    param([string] $Path, [object] $Record)
    [IO.File]::WriteAllText($Path, (($Record | ConvertTo-Json -Depth 12) + "`n"),
        [Text.UTF8Encoding]::new($false))
}
function Assert-InstallerFails {
    param([string] $Fragment, [string] $Destination, [string] $RecordPath,
        [string] $ArchiveRoot, [string] $Marker)
    try {
        & $installer -DestinationRoot $Destination -VerifyOnly `
            -IntegrityRecordPath $RecordPath -ArchiveSourceRoot $ArchiveRoot
        [IO.File]::WriteAllText($Marker, 'executed')
    }
    catch {
        if ($_.Exception.Message -notlike "*$Fragment*") {
            throw "Expected '$Fragment', got: $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $Marker) {
            throw 'Execution marker appeared after an integrity failure.'
        }
        return
    }
    throw "Expected installer failure containing '$Fragment'."
}
function New-TarFixture {
    param([string] $Path, [System.Collections.IDictionary] $Entries)
    $file = [IO.File]::Create($Path)
    $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Compress)
    $writer = [System.Formats.Tar.TarWriter]::new($gzip)
    try {
        foreach ($name in $Entries.Keys) {
            $entry = [System.Formats.Tar.PaxTarEntry]::new(
                [System.Formats.Tar.TarEntryType]::RegularFile, [string]$name)
            $entry.DataStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes([string]$Entries[$name]))
            try { $writer.WriteEntry($entry) } finally { $entry.DataStream.Dispose() }
        }
    }
    finally { $writer.Dispose(); $gzip.Dispose(); $file.Dispose() }
}
function New-ZipFixture {
    param([string] $Path, [System.Collections.IDictionary] $Entries)
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries.Keys) {
            $entry = $zip.CreateEntry([string]$name)
            $stream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Entries[$name])
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}
function Assert-ProductionFixture {
    param([string] $FixtureInstaller, [string] $Destination,
        [System.Collections.IDictionary] $DownloadMap, [string] $Marker,
        [string] $ExpectedFailure, [bool] $ExpectRustup)

    if (Test-Path -LiteralPath $Marker) { Remove-Item -LiteralPath $Marker }
    function Invoke-WebRequest {
        param([string] $Uri, [string] $OutFile, [int] $MaximumRedirection)
        if (-not $DownloadMap.Contains($Uri)) { throw "Unexpected fixture download URI: $Uri" }
        Copy-Item -LiteralPath $DownloadMap[$Uri] -Destination $OutFile
    }
    function rustup {
        [IO.File]::WriteAllText($Marker, ($args -join ' '))
        throw 'VERIFIED_RUSTUP_STAGE_REACHED'
    }

    # The fixture uses the real production entrypoint with its platform check.
    # On Linux, the temporary override reaches the same x64 installer path.
    # IsWindows is AllScope, so restore it even when the installer throws.
    $nativeIsWindows = $IsWindows
    $failure = $null
    try {
        if (-not $nativeIsWindows) {
            Set-Variable -Name IsWindows -Value $true -Scope Local -Force
        }
        try { & $FixtureInstaller -DestinationRoot $Destination }
        catch { $failure = $_.Exception.Message }
    }
    finally {
        if (-not $nativeIsWindows) {
            Set-Variable -Name IsWindows -Value $nativeIsWindows -Scope Local -Force
        }
    }
    if ($null -eq $failure -or $failure -notlike "*$ExpectedFailure*") {
        throw "Expected production-path failure '$ExpectedFailure', got: $failure"
    }
    $reachedRustup = Test-Path -LiteralPath $Marker -PathType Leaf
    if ($reachedRustup -ne $ExpectRustup) {
        throw "Expected rustup marker=$ExpectRustup, observed $reachedRustup after: $failure"
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-release-pins-$([Guid]::NewGuid())"
$archiveRoot = Join-Path $testRoot 'archives'
$recordPath = Join-Path $testRoot 'record.json'
$marker = Join-Path $testRoot 'execution.marker'
try {
    New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    $record = Get-Content -LiteralPath $sourceRecord -Raw | ConvertFrom-Json
    $artifacts = @()
    foreach ($component in $record.rust.components) {
        $artifacts += [pscustomobject]@{ source = $component; file = "$($component.id).tar.gz" }
    }
    foreach ($tool in $record.tools) {
        $extension = if ($tool.url.EndsWith('.zip', [StringComparison]::Ordinal)) { '.zip' } else { '.tar.gz' }
        $artifacts += [pscustomobject]@{ source = $tool; file = "$($tool.id)$extension" }
    }
    foreach ($artifact in $artifacts) {
        $path = Join-Path $archiveRoot $artifact.file
        [IO.File]::WriteAllText($path, "approved fixture bytes: $($artifact.file)",
            [Text.UTF8Encoding]::new($false))
        $artifact.source.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $manifest = "manifest-version = '2'`n"
    foreach ($component in $record.rust.components) {
        $manifest += "[pkg.$($component.id).target.x86_64-pc-windows-msvc]`navailable = true`n"
        $manifest += "url = `"$($component.url)`"`nhash = `"$($component.sha256)`"`n"
    }
    $manifestPath = Join-Path $archiveRoot 'rust-manifest.toml'
    [IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
    $record.rust.manifest.sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Record $recordPath $record

    & $installer -DestinationRoot (Join-Path $testRoot 'valid') -VerifyOnly `
        -IntegrityRecordPath $recordPath -ArchiveSourceRoot $archiveRoot

    [IO.File]::AppendAllText((Join-Path $archiveRoot 'cargo-audit.zip'), 'different bytes')
    Assert-InstallerFails -Fragment 'SHA-256 mismatch for cargo-audit' `
        -Destination (Join-Path $testRoot 'wrong-bytes') -RecordPath $recordPath `
        -ArchiveRoot $archiveRoot -Marker $marker
    [IO.File]::WriteAllText((Join-Path $archiveRoot 'cargo-audit.zip'),
        'approved fixture bytes: cargo-audit.zip', [Text.UTF8Encoding]::new($false))

    Remove-Item -LiteralPath (Join-Path $archiveRoot 'rust-std.tar.gz')
    Assert-InstallerFails -Fragment 'Required pinned artifact is missing' `
        -Destination (Join-Path $testRoot 'missing') -RecordPath $recordPath `
        -ArchiveRoot $archiveRoot -Marker $marker
    [IO.File]::WriteAllText((Join-Path $archiveRoot 'rust-std.tar.gz'),
        'approved fixture bytes: rust-std.tar.gz', [Text.UTF8Encoding]::new($false))

    $originalRustVersion = $record.rust.version
    $record.rust.version = '0.0.0'
    Write-Record $recordPath $record
    Assert-InstallerFails -Fragment 'stale against rust-toolchain.toml' `
        -Destination (Join-Path $testRoot 'stale-rust') -RecordPath $recordPath `
        -ArchiveRoot $archiveRoot -Marker $marker
    $record.rust.version = $originalRustVersion

    $originalAuditVersion = $record.tools[0].version
    $record.tools[0].version = '0.0.0'
    Write-Record $recordPath $record
    Assert-InstallerFails -Fragment 'stale against security.yaml' `
        -Destination (Join-Path $testRoot 'stale-scanner') -RecordPath $recordPath `
        -ArchiveRoot $archiveRoot -Marker $marker
    $record.tools[0].version = $originalAuditVersion

    $originalAboutPath = $record.tools[2].archivePath
    $record.tools[2].archivePath = '../cargo-about.exe'
    Write-Record $recordPath $record
    Assert-InstallerFails -Fragment 'Unsupported archive layout for cargo-about' `
        -Destination (Join-Path $testRoot 'unsupported') -RecordPath $recordPath `
        -ArchiveRoot $archiveRoot -Marker $marker
    $record.tools[2].archivePath = $originalAboutPath

    $record.tools[3].sha256 = ''
    Write-Record $recordPath $record
    Assert-InstallerFails -Fragment 'Missing or invalid reviewed SHA-256 pin for cargo-cyclonedx' `
        -Destination (Join-Path $testRoot 'no-pin') -RecordPath $recordPath `
        -ArchiveRoot $archiveRoot -Marker $marker

    try {
        & $installer -DestinationRoot (Join-Path $testRoot 'override-install') `
            -IntegrityRecordPath $recordPath -ArchiveSourceRoot $archiveRoot
        throw 'Expected production override rejection.'
    }
    catch {
        if ($_.Exception.Message -notlike '*overrides are allowed only with -VerifyOnly*') { throw }
    }

    # Exercise the production invocation, including downloads, hashing, archive
    # staging and the first external execution boundary, in a disposable repo.
    $fixtureRepo = Join-Path $testRoot 'production-fixture'
    $fixtureScripts = Join-Path $fixtureRepo 'scripts'
    $fixtureConfig = Join-Path $fixtureRepo 'config'
    $fixtureWorkflow = Join-Path $fixtureRepo '.github/workflows'
    $fixtureArchives = Join-Path $testRoot 'production-archives'
    foreach ($directory in @($fixtureScripts, $fixtureConfig, $fixtureWorkflow, $fixtureArchives)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $fixtureInstaller = Join-Path $fixtureScripts 'install-verified-release-tools.ps1'
    Copy-Item -LiteralPath $installer -Destination $fixtureInstaller
    Copy-Item -LiteralPath (Join-Path $repoRoot 'rust-toolchain.toml') `
        -Destination (Join-Path $fixtureRepo 'rust-toolchain.toml')
    Copy-Item -LiteralPath (Join-Path $repoRoot '.github/workflows/security.yaml') `
        -Destination (Join-Path $fixtureWorkflow 'security.yaml')
    $productionRecord = Get-Content -LiteralPath $sourceRecord -Raw | ConvertFrom-Json
    $downloadMap = @{}

    foreach ($component in $productionRecord.rust.components) {
        $archiveRootName = [IO.Path]::GetFileName($component.url).Replace('.tar.gz', '')
        $prefix = "$archiveRootName/$($component.directory)"
        $entry = switch ($component.id) {
            'rustc' { 'bin/rustc.exe' }
            'cargo' { 'bin/cargo.exe' }
            'rust-std' { 'lib/rustlib/x86_64-pc-windows-msvc/lib/libstd.rlib' }
            'rustfmt-preview' { 'bin/rustfmt.exe' }
            'clippy-preview' { 'bin/cargo-clippy.exe' }
        }
        $archive = Join-Path $fixtureArchives "$($component.id).tar.gz"
        New-TarFixture -Path $archive -Entries ([ordered]@{ "$prefix/$entry" = 'fixture component data' })
        $component.sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        $downloadMap[$component.url] = $archive
    }
    foreach ($tool in $productionRecord.tools) {
        $isZip = $tool.url.EndsWith('.zip', [StringComparison]::Ordinal)
        $archive = Join-Path $fixtureArchives "$($tool.id)$(if ($isZip) { '.zip' } else { '.tar.gz' })"
        $entries = [ordered]@{ $tool.archivePath = 'fixture executable data' }
        if ($isZip) { New-ZipFixture -Path $archive -Entries $entries }
        else { New-TarFixture -Path $archive -Entries $entries }
        $tool.sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        $downloadMap[$tool.url] = $archive
    }
    $productionManifest = "manifest-version = '2'`n"
    foreach ($component in $productionRecord.rust.components) {
        $productionManifest += "[pkg.$($component.id).target.x86_64-pc-windows-msvc]`navailable = true`n"
        $productionManifest += "url = `"$($component.url)`"`nhash = `"$($component.sha256)`"`n"
    }
    $productionManifestPath = Join-Path $fixtureArchives 'rust-manifest.toml'
    [IO.File]::WriteAllText($productionManifestPath, $productionManifest,
        [Text.UTF8Encoding]::new($false))
    $productionRecord.rust.manifest.sha256 =
        (Get-FileHash -LiteralPath $productionManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $downloadMap[$productionRecord.rust.manifest.url] = $productionManifestPath
    $fixtureRecordPath = Join-Path $fixtureConfig 'release-tool-integrity.json'
    Write-Record $fixtureRecordPath $productionRecord
    $rustupMarker = Join-Path $testRoot 'rustup.marker'
    $testPlatformIsWindows = $IsWindows

    $validStage = Join-Path $testRoot 'production-valid'
    Assert-ProductionFixture -FixtureInstaller $fixtureInstaller -Destination $validStage `
        -DownloadMap $downloadMap -Marker $rustupMarker `
        -ExpectedFailure 'VERIFIED_RUSTUP_STAGE_REACHED' -ExpectRustup $true
    if ((Get-Content -LiteralPath $rustupMarker -Raw) -cnotmatch
        '^toolchain link darkrenamer-release ') {
        throw 'The execution marker did not identify the verified rustup link boundary.'
    }
    foreach ($expected in @('bin/rustc.exe', 'bin/cargo.exe', 'bin/rustfmt.exe',
            'bin/cargo-clippy.exe', 'lib/rustlib/x86_64-pc-windows-msvc/lib/libstd.rlib')) {
        if (-not (Test-Path -LiteralPath (Join-Path $validStage "toolchain/$expected") -PathType Leaf)) {
            throw "Production fixture did not stage expected Rust content: $expected"
        }
    }
    foreach ($tool in $productionRecord.tools) {
        if (-not (Test-Path -LiteralPath (Join-Path $validStage "tools/$($tool.id).exe") -PathType Leaf)) {
            throw "Production fixture did not stage expected tool: $($tool.id)"
        }
    }

    $auditTool = $productionRecord.tools[0]
    $approvedAuditArchive = $downloadMap[$auditTool.url]
    $wrongBytes = Join-Path $fixtureArchives 'cargo-audit-wrong-bytes.zip'
    Copy-Item -LiteralPath $approvedAuditArchive -Destination $wrongBytes
    [IO.File]::AppendAllText($wrongBytes, 'same version, different bytes')
    $downloadMap[$auditTool.url] = $wrongBytes
    $wrongBytesStage = Join-Path $testRoot 'production-wrong-bytes'
    Assert-ProductionFixture -FixtureInstaller $fixtureInstaller -Destination $wrongBytesStage `
        -DownloadMap $downloadMap -Marker $rustupMarker `
        -ExpectedFailure 'SHA-256 mismatch for cargo-audit' -ExpectRustup $false
    if (Test-Path -LiteralPath (Join-Path $wrongBytesStage 'toolchain')) {
        throw 'Wrong bytes reached release-tool extraction before integrity validation.'
    }
    $downloadMap[$auditTool.url] = $approvedAuditArchive

    foreach ($corruption in @(
            [pscustomobject]@{ id = 'rust-manifest'; url = $productionRecord.rust.manifest.url },
            [pscustomobject]@{ id = 'rustc'; url = $productionRecord.rust.components[0].url }
        )) {
        $approved = $downloadMap[$corruption.url]
        $tampered = Join-Path $fixtureArchives "$($corruption.id)-wrong-bytes"
        Copy-Item -LiteralPath $approved -Destination $tampered
        [IO.File]::AppendAllText($tampered, 'different bytes')
        $downloadMap[$corruption.url] = $tampered
        $stage = Join-Path $testRoot "production-$($corruption.id)-wrong-bytes"
        Assert-ProductionFixture -FixtureInstaller $fixtureInstaller -Destination $stage `
            -DownloadMap $downloadMap -Marker $rustupMarker `
            -ExpectedFailure "SHA-256 mismatch for $($corruption.id)" -ExpectRustup $false
        if (Test-Path -LiteralPath (Join-Path $stage 'toolchain')) {
            throw "$($corruption.id) wrong bytes reached release-tool extraction."
        }
        $downloadMap[$corruption.url] = $approved
    }

    $badLayout = Join-Path $fixtureArchives 'cargo-audit-wrong-layout.zip'
    New-ZipFixture -Path $badLayout -Entries ([ordered]@{ 'unexpected.exe' = 'wrong layout' })
    $approvedAuditDigest = $auditTool.sha256
    $auditTool.sha256 = (Get-FileHash -LiteralPath $badLayout -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Record $fixtureRecordPath $productionRecord
    $downloadMap[$auditTool.url] = $badLayout
    Assert-ProductionFixture -FixtureInstaller $fixtureInstaller `
        -Destination (Join-Path $testRoot 'production-wrong-layout') `
        -DownloadMap $downloadMap -Marker $rustupMarker `
        -ExpectedFailure 'Expected executable is missing from verified archive' -ExpectRustup $false
    $auditTool.sha256 = $approvedAuditDigest
    Write-Record $fixtureRecordPath $productionRecord
    $downloadMap[$auditTool.url] = $approvedAuditArchive
    if ($IsWindows -ne $testPlatformIsWindows) {
        throw 'Production fixture changed the PowerShell platform flag outside its call.'
    }

    # Exercise the installer's actual version-probe loop with strict command
    # fixtures. Cargo plugin binaries may require their subcommand argument.
    $parseTokens = $null
    $parseErrors = $null
    $installerAst = [Management.Automation.Language.Parser]::ParseFile(
        $installer, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'The release installer did not parse.' }
    $probeLoops = @($installerAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.VariablePath.UserPath -ceq 'tool' -and
            $node.Extent.Text.Contains('version probe failed')
    }, $true))
    if ($probeLoops.Count -ne 1) { throw 'The release-tool version probe loop is ambiguous.' }
    $record = $productionRecord
    $toolsRoot = Join-Path $testRoot 'version-probe-commands'
    $observedProbes = [Collections.Generic.List[string]]::new()
    $probeFunctions = @()
    try {
        foreach ($tool in $record.tools) {
            $id = $tool.id
            $version = $tool.version
            $expectedArguments = @('--version')
            if ($id -ceq 'cargo-cyclonedx') { $expectedArguments = @('cyclonedx', '--version') }
            $executable = Join-Path $toolsRoot "$id.exe"
            $fixtureCommand = {
                if ($args.Count -ne $expectedArguments.Count -or
                        ($args -join "`0") -cne ($expectedArguments -join "`0")) {
                    throw "Expected $id arguments ($($expectedArguments.Count)): $($expectedArguments -join ' '); observed ($($args.Count)): $($args -join ' ')."
                }
                $observedProbes.Add($id)
                $global:LASTEXITCODE = 0
                return "$id $version"
            }.GetNewClosure()
            $functionPath = "Function:script:$executable"
            Set-Item -LiteralPath $functionPath -Value $fixtureCommand
            $probeFunctions += $functionPath
        }
        & ([scriptblock]::Create($probeLoops[0].Extent.Text))
        if (($observedProbes -join ',') -cne (($record.tools.id) -join ',')) {
            throw 'The version probe did not execute every verified release tool in order.'
        }
    }
    finally {
        foreach ($functionPath in $probeFunctions) { Remove-Item -LiteralPath $functionPath }
    }

    Write-Host 'Release-tool integrity tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
