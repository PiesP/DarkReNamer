[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'validate-release-handoff.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Release handoff validator is missing: $validator"
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $Content
    )

    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Write-Checksums {
    param(
        [Parameter(Mandatory)]
        [string] $HandoffRoot
    )

    $subjects = @(
        'DarkReNamer-debug-symbols.zip'
        'DarkReNamer.cdx.json'
        'DarkReNamer.exe'
        'DISTRIBUTION.md'
        'LICENSE'
        'THIRD_PARTY_NOTICES.md'
    )
    $lines = foreach ($name in $subjects) {
        $path = Join-Path $HandoffRoot $name
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash *$name"
    }
    Write-Utf8NoBom `
        -Path (Join-Path $HandoffRoot 'SHA256SUMS.txt') `
        -Content (($lines -join "`n") + "`n")
}

function Assert-ValidatorFails {
    param(
        [Parameter(Mandatory)]
        [string] $ExpectedFragment,
        [Parameter(Mandatory)]
        [string] $SourceRoot,
        [Parameter(Mandatory)]
        [string] $HandoffRoot
    )

    try {
        & $validator -SourceRoot $SourceRoot -HandoffRoot $HandoffRoot
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedFragment*") {
            throw "Expected validator failure containing '$ExpectedFragment', got: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected validator failure containing '$ExpectedFragment', but validation succeeded."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-release-validator-$([Guid]::NewGuid())"
$sourceRoot = Join-Path $testRoot 'source'
$handoffRoot = Join-Path $testRoot 'dist'

try {
    New-Item -ItemType Directory -Path $sourceRoot, $handoffRoot | Out-Null

    foreach ($name in 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DISTRIBUTION.md') {
        Write-Utf8NoBom -Path (Join-Path $sourceRoot $name) -Content "$name source policy`n"
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination $handoffRoot
    }

    [IO.File]::WriteAllBytes((Join-Path $handoffRoot 'DarkReNamer.exe'), [byte[]](0x4d, 0x5a, 0x01, 0x02))
    [IO.File]::WriteAllBytes((Join-Path $handoffRoot 'DarkReNamer.pdb'), [byte[]](0x50, 0x44, 0x42, 0x00))
    Write-Utf8NoBom `
        -Path (Join-Path $handoffRoot 'DarkReNamer.cdx.json') `
        -Content '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[{"type":"application","name":"darknamer-app","version":"0.1.0"}]}'
    Compress-Archive `
        -LiteralPath (Join-Path $handoffRoot 'DarkReNamer.pdb') `
        -DestinationPath (Join-Path $handoffRoot 'DarkReNamer-debug-symbols.zip')
    Write-Checksums -HandoffRoot $handoffRoot

    $global:DarkReNamerTestAuthenticodeStatus = 'NotSigned'
    function global:Get-AuthenticodeSignature {
        param([string] $FilePath)
        [pscustomobject]@{
            Path = $FilePath
            Status = $global:DarkReNamerTestAuthenticodeStatus
        }
    }

    & $validator -SourceRoot $sourceRoot -HandoffRoot $handoffRoot

    Write-Utf8NoBom -Path (Join-Path $sourceRoot 'LICENSE') -Content "LICENSE source policy`r`n"
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') -Destination $handoffRoot -Force
    Assert-ValidatorFails `
        -ExpectedFragment 'must use canonical LF line endings' `
        -SourceRoot $sourceRoot `
        -HandoffRoot $handoffRoot
    Write-Utf8NoBom -Path (Join-Path $sourceRoot 'LICENSE') -Content "LICENSE source policy`n"
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') -Destination $handoffRoot -Force

    $global:DarkReNamerTestAuthenticodeStatus = 'Valid'
    Assert-ValidatorFails `
        -ExpectedFragment 'Authenticode status must be NotSigned' `
        -SourceRoot $sourceRoot `
        -HandoffRoot $handoffRoot
    $global:DarkReNamerTestAuthenticodeStatus = 'NotSigned'

    Write-Utf8NoBom -Path (Join-Path $handoffRoot 'LICENSE') -Content "tampered`n"
    Assert-ValidatorFails `
        -ExpectedFragment 'does not match the source file' `
        -SourceRoot $sourceRoot `
        -HandoffRoot $handoffRoot
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') -Destination $handoffRoot -Force

    Write-Checksums -HandoffRoot $handoffRoot
    $checksumPath = Join-Path $handoffRoot 'SHA256SUMS.txt'
    $checksums = Get-Content -LiteralPath $checksumPath -Raw
    $replacement = if ($checksums[0] -eq '0') { '1' } else { '0' }
    Write-Utf8NoBom `
        -Path $checksumPath `
        -Content ($replacement + $checksums.Substring(1))
    Assert-ValidatorFails `
        -ExpectedFragment 'Checksum mismatch' `
        -SourceRoot $sourceRoot `
        -HandoffRoot $handoffRoot

    Write-Checksums -HandoffRoot $handoffRoot
    Write-Utf8NoBom -Path (Join-Path $handoffRoot 'unexpected.txt') -Content "unexpected`n"
    Assert-ValidatorFails `
        -ExpectedFragment 'Release handoff layout mismatch' `
        -SourceRoot $sourceRoot `
        -HandoffRoot $handoffRoot

    Write-Host 'Release handoff validator tests passed.'
}
finally {
    Remove-Item Function:\global:Get-AuthenticodeSignature -ErrorAction SilentlyContinue
    Remove-Variable DarkReNamerTestAuthenticodeStatus -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
