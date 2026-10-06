[CmdletBinding()]
param(
    [string] $SourceRoot,
    [string] $HandoffRoot,
    [string] $SourceSha,
    [string] $RunId,
    [string] $RunAttempt,
    [string] $TemporaryRoot
)

function Write-DarkReNamerReleaseFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $HandoffRoot,
        [Parameter(Mandatory)][string] $SourceSha,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $RunAttempt,
        [Parameter(Mandatory)][string] $TemporaryRoot
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

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
}

if ($MyInvocation.InvocationName -ne '.') {
    Write-DarkReNamerReleaseFiles @PSBoundParameters
}
