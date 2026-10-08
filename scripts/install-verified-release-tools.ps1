[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $DestinationRoot,
    [switch] $VerifyOnly,
    [string] $IntegrityRecordPath,
    [string] $ArchiveSourceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.4') {
    throw 'Verified release tools require PowerShell 7.4 or newer.'
}
if (($IntegrityRecordPath -or $ArchiveSourceRoot) -and -not $VerifyOnly) {
    throw 'Record and archive overrides are allowed only with -VerifyOnly; the release installer uses repository pins and downloads.'
}
if (-not $VerifyOnly -and (-not $IsWindows -or
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
        [Runtime.InteropServices.Architecture]::X64)) {
    throw 'Release tool installation supports only hosted Windows x86_64 runners.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$defaultRecordPath = Join-Path $repoRoot 'config/release-tool-integrity.json'
if (-not $IntegrityRecordPath) { $IntegrityRecordPath = $defaultRecordPath }
if (-not (Test-Path -LiteralPath $IntegrityRecordPath -PathType Leaf)) {
    throw "Release-tool integrity record is missing: $IntegrityRecordPath"
}
$record = Get-Content -LiteralPath $IntegrityRecordPath -Raw | ConvertFrom-Json
if ($record.schemaVersion -ne 1 -or $record.platform -cne 'x86_64-pc-windows-msvc') {
    throw 'Unsupported release-tool integrity record schema or platform.'
}

function Assert-Digest {
    param([string] $Id, [string] $Digest)
    if ($Digest -cnotmatch '^[0-9a-f]{64}$') {
        throw "Missing or invalid reviewed SHA-256 pin for $Id."
    }
}
function Get-ReviewedDigest {
    param([object] $Source, [string] $Id)
    if ($null -eq $Source.PSObject.Properties['sha256']) {
        throw "Missing reviewed SHA-256 pin for $Id."
    }
    return [string]$Source.sha256
}
function Assert-Artifact {
    param([string] $Id, [string] $Url, [string] $Digest, [string] $Pattern)
    Assert-Digest $Id $Digest
    if ($Url -cnotmatch $Pattern) {
        throw "Unsupported or stale release artifact URL for $Id`: $Url"
    }
}

$toolchainText = Get-Content -LiteralPath (Join-Path $repoRoot 'rust-toolchain.toml') -Raw
$channel = [regex]::Matches($toolchainText, '(?m)^channel\s*=\s*"([^"]+)"\s*$')
if ($channel.Count -ne 1 -or $channel[0].Groups[1].Value -cne $record.rust.version) {
    throw 'Rust release-tool pin is stale against rust-toolchain.toml channel.'
}
if ($toolchainText -cnotmatch '(?m)^components\s*=\s*\["clippy",\s*"rustfmt"\]\s*$' -or
    $toolchainText -cnotmatch '(?m)^targets\s*=\s*\["x86_64-pc-windows-msvc"\]\s*$' -or
    $toolchainText -cnotmatch '(?m)^profile\s*=\s*"minimal"\s*$') {
    throw 'Unsupported Rust toolchain component, target, or profile; review the integrity record.'
}
$rustVersion = [regex]::Escape([string]$record.rust.version)
Assert-Artifact 'Rust channel manifest' $record.rust.manifest.url (Get-ReviewedDigest $record.rust.manifest 'Rust channel manifest') "^https://static\.rust-lang\.org/dist/channel-rust-$rustVersion\.toml$"
$expectedRust = @('rustc', 'cargo', 'rust-std', 'rustfmt-preview', 'clippy-preview')
if (@($record.rust.components).Count -ne $expectedRust.Count) {
    throw 'Rust component integrity record is incomplete.'
}
$rustDirectories = @{
    rustc = 'rustc'
    cargo = 'cargo'
    'rust-std' = 'rust-std-x86_64-pc-windows-msvc'
    'rustfmt-preview' = 'rustfmt-preview'
    'clippy-preview' = 'clippy-preview'
}
$rustArchiveNames = @{
    rustc = 'rustc'
    cargo = 'cargo'
    'rust-std' = 'rust-std'
    'rustfmt-preview' = 'rustfmt'
    'clippy-preview' = 'clippy'
}
for ($i = 0; $i -lt $expectedRust.Count; $i++) {
    $component = $record.rust.components[$i]
    $id = $expectedRust[$i]
    if ($component.id -cne $id -or $component.directory -cne $rustDirectories[$id]) {
        throw "Unsupported or missing Rust component at index $i; review the integrity record."
    }
    $archiveName = [regex]::Escape($rustArchiveNames[$id])
    Assert-Artifact $id $component.url (Get-ReviewedDigest $component $id) "^https://static\.rust-lang\.org/dist/[0-9]{4}-[0-9]{2}-[0-9]{2}/$archiveName-$rustVersion-x86_64-pc-windows-msvc\.tar\.gz$"
}
$securityText = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/security.yaml') -Raw
$expectedTools = @('cargo-audit', 'cargo-deny', 'cargo-about', 'cargo-cyclonedx')
if (@($record.tools).Count -ne $expectedTools.Count) {
    throw 'Release-tool integrity record is incomplete.'
}
$toolHosts = @{
    'cargo-audit' = 'rustsec/rustsec'
    'cargo-deny' = 'EmbarkStudios/cargo-deny'
    'cargo-about' = 'EmbarkStudios/cargo-about'
    'cargo-cyclonedx' = 'CycloneDX/cyclonedx-rust-cargo'
}
for ($i = 0; $i -lt $expectedTools.Count; $i++) {
    $tool = $record.tools[$i]
    $id = $expectedTools[$i]
    if ($tool.id -cne $id -or $tool.version -cnotmatch '^\d+\.\d+\.\d+$') {
        throw "Unsupported or missing release tool at index $i."
    }
    $version = [regex]::Escape([string]$tool.version)
    if ($id -in @('cargo-audit', 'cargo-deny')) {
        $matches = [regex]::Matches($securityText, "cargo install --locked[^`r`n]*?\b$([regex]::Escape($id)) --version ([0-9.]+)")
        if ($matches.Count -ne 1 -or $matches[0].Groups[1].Value -cne $tool.version) {
            throw "$id integrity pin is stale against security.yaml."
        }
    }
    switch ($id) {
        'cargo-audit' {
            $pattern = "^https://github\.com/rustsec/rustsec/releases/download/cargo-audit/v$version/cargo-audit-x86_64-pc-windows-msvc-v$version\.zip$"
            $archivePath = "cargo-audit-x86_64-pc-windows-msvc-v$($tool.version)/cargo-audit.exe"
        }
        'cargo-deny' {
            $pattern = "^https://github\.com/EmbarkStudios/cargo-deny/releases/download/$version/cargo-deny-$version-x86_64-pc-windows-msvc\.tar\.gz$"
            $archivePath = "cargo-deny-$($tool.version)-x86_64-pc-windows-msvc/cargo-deny.exe"
        }
        'cargo-about' {
            $pattern = "^https://github\.com/EmbarkStudios/cargo-about/releases/download/$version/cargo-about-$version-x86_64-pc-windows-msvc\.tar\.gz$"
            $archivePath = "cargo-about-$($tool.version)-x86_64-pc-windows-msvc/cargo-about.exe"
        }
        'cargo-cyclonedx' {
            $pattern = "^https://github\.com/CycloneDX/cyclonedx-rust-cargo/releases/download/cargo-cyclonedx-$version/cargo-cyclonedx-x86_64-pc-windows-msvc\.zip$"
            $archivePath = 'cargo-cyclonedx.exe'
        }
    }
    if ($tool.archivePath -cne $archivePath) {
        throw "Unsupported archive layout for $id."
    }
    Assert-Artifact $id $tool.url (Get-ReviewedDigest $tool $id) $pattern
}

$destination = [IO.Path]::GetFullPath($DestinationRoot)
if (Test-Path -LiteralPath $destination) {
    throw "DestinationRoot already exists; use a new directory: $destination"
}
New-Item -ItemType Directory -Path $destination | Out-Null
$downloads = Join-Path $destination 'downloads'
New-Item -ItemType Directory -Path $downloads | Out-Null

$artifacts = @([pscustomobject]@{ id = 'rust-manifest'; source = $record.rust.manifest; file = 'rust-manifest.toml' })
foreach ($component in $record.rust.components) {
    $artifacts += [pscustomobject]@{ id = $component.id; source = $component; file = "$($component.id).tar.gz" }
}
foreach ($tool in $record.tools) {
    $extension = if ($tool.url.EndsWith('.zip', [StringComparison]::Ordinal)) { '.zip' } else { '.tar.gz' }
    $artifacts += [pscustomobject]@{ id = $tool.id; source = $tool; file = "$($tool.id)$extension" }
}
foreach ($artifact in $artifacts) {
    $path = Join-Path $downloads $artifact.file
    if ($ArchiveSourceRoot) {
        $fixture = Join-Path $ArchiveSourceRoot $artifact.file
        if (-not (Test-Path -LiteralPath $fixture -PathType Leaf)) {
            throw "Required pinned artifact is missing from fixture source: $($artifact.id) ($fixture)"
        }
        Copy-Item -LiteralPath $fixture -Destination $path
    }
    else {
        Invoke-WebRequest -Uri $artifact.source.url -OutFile $path -MaximumRedirection 5
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $artifact.source.sha256) {
        throw "SHA-256 mismatch for $($artifact.id): expected $($artifact.source.sha256), got $actual. No archive was extracted or tool executed."
    }
}
$manifestText = Get-Content -LiteralPath (Join-Path $downloads 'rust-manifest.toml') -Raw
foreach ($component in $record.rust.components) {
    $header = [regex]::Escape("[pkg.$($component.id).target.x86_64-pc-windows-msvc]")
    $section = [regex]::Matches($manifestText, "(?ms)^$header`r?`n(.*?)(?=^\[|\z)")
    if ($section.Count -ne 1 -or
        [regex]::Matches($section[0].Groups[1].Value, '(?m)^available = true\s*$').Count -ne 1 -or
        [regex]::Matches($section[0].Groups[1].Value, '(?m)^url = "([^"]+)"\s*$').Count -ne 1 -or
        [regex]::Matches($section[0].Groups[1].Value, '(?m)^hash = "([0-9a-f]{64})"\s*$').Count -ne 1) {
        throw "Verified Rust manifest lacks an unambiguous available $($component.id) Windows archive."
    }
    $url = [regex]::Match($section[0].Groups[1].Value, '(?m)^url = "([^"]+)"\s*$').Groups[1].Value
    $hash = [regex]::Match($section[0].Groups[1].Value, '(?m)^hash = "([0-9a-f]{64})"\s*$').Groups[1].Value
    if ($url -cne $component.url -or $hash -cne $component.sha256) {
        throw "Rust manifest and repository pin disagree for $($component.id)."
    }
}
if ($VerifyOnly) {
    Write-Host 'All release-tool archives match the selected integrity record; verification-only mode did not install or execute tools.'
    return
}

function Assert-ArchivePath {
    param([string] $Name)
    if ($Name -cnotmatch '^[A-Za-z0-9_.+/-]+/?$' -or $Name -match '(^|/)\.\.?(/|$)' -or $Name.StartsWith('/')) {
        throw "Unsupported archive entry path: $Name"
    }
}
function Open-TarReader {
    param([string] $Path)
    $file = [IO.File]::OpenRead($Path)
    try {
        $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Decompress)
        return [pscustomobject]@{ file = $file; gzip = $gzip; reader = [System.Formats.Tar.TarReader]::new($gzip) }
    }
    catch {
        $file.Dispose()
        throw
    }
}
function Copy-TarContent {
    param([string] $Archive, [string] $Prefix, [string] $OutputRoot, [string] $ExactEntry)
    $opened = Open-TarReader $Archive
    $copied = 0
    try {
        while ($null -ne ($entry = $opened.reader.GetNextEntry())) {
            $name = $entry.Name.Replace('\', '/')
            Assert-ArchivePath $name
            if ($entry.EntryType -notin @([System.Formats.Tar.TarEntryType]::Directory,
                    [System.Formats.Tar.TarEntryType]::RegularFile,
                    [System.Formats.Tar.TarEntryType]::V7RegularFile)) {
                throw "Unsupported link or special entry in verified archive: $name"
            }
            if ($entry.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory) { continue }
            $relative = if ($ExactEntry) {
                if ($name -cne $ExactEntry) { continue }
                [IO.Path]::GetFileName($ExactEntry)
            }
            else {
                if (-not $name.StartsWith("$Prefix/", [StringComparison]::Ordinal)) { continue }
                $name.Substring($Prefix.Length + 1)
            }
            if (-not $relative) { continue }
            # Rust's component inventory is installer metadata, not toolchain content.
            if (-not $ExactEntry -and $relative -ceq 'manifest.in') { continue }
            $output = [IO.Path]::GetFullPath((Join-Path $OutputRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
            if (-not $output.StartsWith(($OutputRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escapes the destination: $name"
            }
            if (Test-Path -LiteralPath $output) { throw "Duplicate release toolchain entry: $relative" }
            New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
            $stream = [IO.File]::Open($output, [IO.FileMode]::CreateNew)
            try { $entry.DataStream.CopyTo($stream) } finally { $stream.Dispose() }
            $copied++
        }
    }
    finally {
        $opened.reader.Dispose()
        $opened.gzip.Dispose()
        $opened.file.Dispose()
    }
    if ($copied -eq 0) { throw "Expected content is missing from verified archive: $Archive" }
}
function Copy-ZipExecutable {
    param([string] $Archive, [string] $EntryName, [string] $Output)
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $matched = @($zip.Entries | Where-Object { $_.FullName -ceq $EntryName })
        foreach ($entry in $zip.Entries) { Assert-ArchivePath $entry.FullName }
        if ($matched.Count -ne 1 -or $matched[0].Length -eq 0) {
            throw "Expected executable is missing from verified archive: $EntryName"
        }
        $inputStream = $matched[0].Open()
        $outputStream = [IO.File]::Open($Output, [IO.FileMode]::CreateNew)
        try { $inputStream.CopyTo($outputStream) }
        finally { $outputStream.Dispose(); $inputStream.Dispose() }
    }
    finally { $zip.Dispose() }
}

$toolchainRoot = Join-Path $destination 'toolchain'
$toolsRoot = Join-Path $destination 'tools'
New-Item -ItemType Directory -Path $toolchainRoot, $toolsRoot | Out-Null
foreach ($component in $record.rust.components) {
    $archiveRoot = [IO.Path]::GetFileName($component.url).Replace('.tar.gz', '')
    Copy-TarContent -Archive (Join-Path $downloads "$($component.id).tar.gz") `
        -Prefix "$archiveRoot/$($component.directory)" -OutputRoot $toolchainRoot
}
foreach ($required in @('bin/rustc.exe', 'bin/cargo.exe', 'bin/rustfmt.exe', 'bin/cargo-clippy.exe',
        'lib/rustlib/x86_64-pc-windows-msvc/lib')) {
    if (-not (Test-Path -LiteralPath (Join-Path $toolchainRoot $required))) {
        throw "Verified Rust archive layout lacks required $required."
    }
}
foreach ($tool in $record.tools) {
    $toolArchiveName = if ($tool.url.EndsWith('.zip', [StringComparison]::Ordinal)) {
        "$($tool.id).zip"
    } else { "$($tool.id).tar.gz" }
    $archive = Join-Path $downloads $toolArchiveName
    $output = Join-Path $toolsRoot "$($tool.id).exe"
    if ($archive.EndsWith('.zip', [StringComparison]::Ordinal)) {
        Copy-ZipExecutable -Archive $archive -EntryName $tool.archivePath -Output $output
    }
    else {
        Copy-TarContent -Archive $archive -ExactEntry $tool.archivePath -OutputRoot $toolsRoot
    }
}

$alias = 'darkrenamer-release'
& rustup toolchain link $alias $toolchainRoot
if ($LASTEXITCODE -ne 0) { throw 'rustup could not link the verified Rust toolchain.' }
$env:RUSTUP_TOOLCHAIN = $alias
$env:PATH = "$toolsRoot;$env:PATH"
foreach ($required in @('rustc', 'cargo')) {
    $output = & $required --version
    if ($LASTEXITCODE -ne 0 -or $output -cnotmatch "\b$([regex]::Escape($record.rust.version))\b") {
        throw "Verified $required version probe failed: $output"
    }
}
foreach ($tool in $record.tools) {
    $versionArguments = @('--version')
    if ($tool.id -ceq 'cargo-cyclonedx') {
        $versionArguments = @('cyclonedx', '--version')
    }
    $output = & (Join-Path $toolsRoot "$($tool.id).exe") @versionArguments
    if ($LASTEXITCODE -ne 0 -or $output -cnotmatch "\b$([regex]::Escape($tool.version))\b") {
        throw "Verified $($tool.id) version probe failed: $output"
    }
}
if (-not $env:GITHUB_ENV -or -not $env:GITHUB_PATH) {
    throw 'GITHUB_ENV and GITHUB_PATH are required to export the verified toolchain to later release steps.'
}
Add-Content -LiteralPath $env:GITHUB_ENV -Value "RUSTUP_TOOLCHAIN=$alias" -Encoding utf8
Add-Content -LiteralPath $env:GITHUB_PATH -Value $toolsRoot -Encoding utf8
Write-Host "Verified release tools installed from repository SHA-256 pins into $destination."
