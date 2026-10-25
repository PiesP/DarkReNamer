[CmdletBinding()]
param(
    [string] $SourceRoot,
    [string] $HandoffRoot,
    [string] $SourceSha,
    [string] $RunId,
    [string] $RunAttempt,
    [string] $TemporaryRoot,
    [string] $DetailOutputPath
)

function Write-DarkReNamerReleaseFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $HandoffRoot,
        [Parameter(Mandatory)][string] $SourceSha,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $RunAttempt,
        [Parameter(Mandatory)][string] $TemporaryRoot,
        [string] $DetailOutputPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($DetailOutputPath) {
        $sourceHead = (& git -C $SourceRoot rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $sourceHead -cne $SourceSha) {
            throw 'Footprint detail source SHA does not match the checked-out source.'
        }
        $detailPath = [IO.Path]::GetFullPath($DetailOutputPath)
        $handoffPath = [IO.Path]::GetFullPath($HandoffRoot)
        if ($detailPath.StartsWith(
                ($handoffPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar),
                [StringComparison]::OrdinalIgnoreCase
            ) -or [string]::Equals($detailPath, $handoffPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Footprint detail must be outside the authenticated handoff.'
        }
        if (Test-Path -LiteralPath $detailPath) {
            throw 'Footprint detail output already exists.'
        }
        if (-not (Test-Path -LiteralPath (Split-Path -Parent $detailPath) -PathType Container)) {
            throw 'Footprint detail output parent directory is missing.'
        }
    }

    $executablePath = Join-Path $HandoffRoot 'DarkReNamer.exe'
    $pdbPath = Join-Path $HandoffRoot 'DarkReNamer.pdb'
    $symbolsPath = Join-Path $HandoffRoot 'DarkReNamer-debug-symbols.zip'
    $sbomPath = Join-Path $HandoffRoot 'DarkReNamer.cdx.json'
    $binaryMeasurementPath = Join-Path `
        $TemporaryRoot `
        "darkrenamer-release-binary-$RunId-$RunAttempt.json"
    try {
        & (Join-Path $PSScriptRoot 'measure-windows-binary.ps1') `
            -ExecutablePath $executablePath `
            -PdbPath $pdbPath `
            -DebugSymbolsZipPath $symbolsPath `
            -OutputPath $binaryMeasurementPath
        $binaryMeasurement = Get-Content `
            -LiteralPath $binaryMeasurementPath `
            -Raw | ConvertFrom-Json
    }
    finally {
        if (Test-Path -LiteralPath $binaryMeasurementPath) {
            Remove-Item -LiteralPath $binaryMeasurementPath
        }
    }
    $rustcVersion = (& rustc --version).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rustcVersion)) {
        throw 'The release rustc version could not be resolved.'
    }
    $cargoLockPackageCount = [regex]::Matches(
        (Get-Content -LiteralPath (Join-Path $SourceRoot 'Cargo.lock') -Raw),
        '(?m)^\[\[package\]\]\s*$'
    ).Count
    if ($cargoLockPackageCount -le 0) {
        throw 'Cargo.lock did not contain any package tables.'
    }
    $metrics = [ordered]@{
        schema_version = 2
        source_sha = $SourceSha
        rustc_version = $rustcVersion
        target_triple = 'x86_64-pc-windows-msvc'
        darkrenamer_exe_bytes = (Get-Item -LiteralPath $executablePath).Length
        darkrenamer_text_raw_bytes = $binaryMeasurement.pe.text_raw_bytes
        debug_symbols_pdb_bytes = $binaryMeasurement.debug_symbols.pdb_bytes
        debug_symbols_zip_bytes = (Get-Item -LiteralPath $symbolsPath).Length
        sbom_bytes = (Get-Item -LiteralPath $sbomPath).Length
        cargo_lock_package_count = $cargoLockPackageCount
    }
    [IO.File]::WriteAllText(
        (Join-Path $HandoffRoot 'release-metrics.json'),
        (($metrics | ConvertTo-Json -Depth 3) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    $executableHash = (Get-FileHash `
            -Algorithm SHA256 `
            -LiteralPath $executablePath).Hash.ToLowerInvariant()
    $handoff = [ordered]@{
        schema_version = 1
        source_sha = $SourceSha
        workflow_run = $RunId
        executable = [ordered]@{
            filename = 'DarkReNamer.exe'
            sha256 = $executableHash
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $HandoffRoot 'release-handoff.json'),
        (($handoff | ConvertTo-Json -Depth 4) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    $files = Get-ChildItem -LiteralPath $HandoffRoot -File |
        Where-Object Name -NotIn @('DarkReNamer.pdb', 'SHA256SUMS.txt') |
        Sort-Object Name
    $lines = foreach ($file in $files) {
        $hash = (Get-FileHash -Algorithm SHA256 $file.FullName).Hash.ToLowerInvariant()
        "$hash *$($file.Name)"
    }
    [IO.File]::WriteAllText(
        (Join-Path $HandoffRoot 'SHA256SUMS.txt'),
        (($lines -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false)
    )

    if ($DetailOutputPath) {
        $rustcVerbose = @(& rustc --version --verbose)
        if ($LASTEXITCODE -ne 0 -or $rustcVerbose.Count -eq 0) {
            throw 'Footprint detail rustc identity could not be resolved.'
        }
        $llvmVersion = @($rustcVerbose | Where-Object { $_ -match '^LLVM version: ' })
        $hostTriple = @($rustcVerbose | Where-Object { $_ -match '^host: ' })
        if ($llvmVersion.Count -ne 1 -or $hostTriple.Count -ne 1) {
            throw 'Footprint detail rustc identity is incomplete.'
        }
        $manifest = Get-Content -LiteralPath (Join-Path $SourceRoot 'Cargo.toml') -Raw
        $profile = [ordered]@{}
        $section = $null
        foreach ($line in ($manifest -split "`n")) {
            if ($line -match '^\[(profile\.release(?:\.package\.[\w-]+)?)\]\s*$') {
                $section = $Matches[1]
                $profile[$section] = [ordered]@{}
            }
            elseif ($line -match '^\[') {
                $section = $null
            }
            elseif ($null -ne $section -and $line -match '^([\w-]+)\s*=\s*(\S.*?)\s*$') {
                $profile[$section][$Matches[1]] = $Matches[2].Trim()
            }
        }
        if (-not $profile.Contains('profile.release')) {
            throw 'Footprint detail release profile is missing.'
        }
        $linkerCommand = Get-Command link.exe -CommandType Application -ErrorAction SilentlyContinue
        $linkerVersion = if ($null -ne $linkerCommand) {
            [Diagnostics.FileVersionInfo]::GetVersionInfo($linkerCommand.Source).ProductVersion
        } else { $null }
        $sdkVersion = [Environment]::GetEnvironmentVariable('WindowsSDKVersion')
        $msvcVersion = [Environment]::GetEnvironmentVariable('VCToolsVersion')
        $overrides = [ordered]@{}
        foreach ($name in 'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'CARGO_PROFILE_RELEASE_OPT_LEVEL',
            'CARGO_PROFILE_RELEASE_LTO', 'CARGO_PROFILE_RELEASE_CODEGEN_UNITS',
            'CARGO_PROFILE_RELEASE_PANIC', 'CARGO_PROFILE_RELEASE_STRIP', 'CARGO_PROFILE_RELEASE_DEBUG') {
            $value = [Environment]::GetEnvironmentVariable($name)
            $overrides[$name] = if ($null -eq $value) { $null } else {
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                        [Text.Encoding]::UTF8.GetBytes($value))).ToLowerInvariant()
            }
        }
        $detail = [ordered]@{
            schema_version = 1
            source_sha = $SourceSha
            workflow_run = $RunId
            workflow_attempt = $RunAttempt
            target_triple = 'x86_64-pc-windows-msvc'
            executable = $binaryMeasurement.executable
            pe = $binaryMeasurement.pe
            debug_symbols = $binaryMeasurement.debug_symbols
            rustc_version = $rustcVersion
            rustc_host = ($hostTriple[0] -replace '^host: ', '')
            llvm_version = ($llvmVersion[0] -replace '^LLVM version: ', '')
            cargo_lock_sha256 = (Get-FileHash -LiteralPath (Join-Path $SourceRoot 'Cargo.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
            cargo_manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $SourceRoot 'Cargo.toml') -Algorithm SHA256).Hash.ToLowerInvariant()
            release_profile = $profile
            flag_override_sha256 = $overrides
            linker_version = if ($linkerVersion) { $linkerVersion } else { $null }
            msvc_tools_version = if ($msvcVersion) { $msvcVersion } else { $null }
            windows_sdk_version = if ($sdkVersion) { $sdkVersion.TrimEnd('\') } else { $null }
            runner_image = if ($env:ImageOS) { $env:ImageOS } else { $null }
            runner_image_version = if ($env:ImageVersion) { $env:ImageVersion } else { $null }
        }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($detail | ConvertTo-Json -Depth 10) + "`n")
        $stream = [IO.File]::Open($detailPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Write-DarkReNamerReleaseFiles @PSBoundParameters
}
