[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hasher = Join-Path $PSScriptRoot 'get-git-blob-sha256.ps1'
if (-not (Test-Path -LiteralPath $hasher -PathType Leaf)) {
    throw "Git blob hasher is missing: $hasher"
}

function Write-Utf8NoBom {
    param([string] $Path, [string] $Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Assert-HasherFails {
    param(
        [Parameter(Mandatory)][string] $ExpectedFragment,
        [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $Revision,
        [Parameter(Mandatory)][string] $Path
    )
    try {
        & $hasher -SourceRoot $SourceRoot -Revision $Revision -Path $Path
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedFragment*") {
            throw "Expected hasher failure containing '$ExpectedFragment', got: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected hasher failure containing '$ExpectedFragment', but hashing succeeded."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-git-blob-hash-$([Guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $trackedPath = Join-Path $testRoot 'tracked.txt'
    Write-Utf8NoBom -Path $trackedPath -Content "first`nsecond`n"
    & git -C $testRoot init --quiet
    & git -C $testRoot config user.name 'DarkReNamer test'
    & git -C $testRoot config user.email 'darkrenamer-test@example.invalid'
    & git -C $testRoot add -- tracked.txt
    & git -C $testRoot commit --quiet -m 'test: initialize blob hash fixture'
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to initialize Git blob hash fixture.'
    }
    $revision = (& git -C $testRoot rev-parse HEAD).Trim()
    $expectedBytes = [Text.Encoding]::UTF8.GetBytes("first`nsecond`n")
    $expectedHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($expectedBytes)
    ).ToLowerInvariant()

    $firstOutput = @(
        & $hasher -SourceRoot $testRoot -Revision $revision -Path 'tracked.txt'
    )
    if ($firstOutput.Count -ne 1 -or $firstOutput[0] -cne $expectedHash) {
        throw 'Git blob hash does not match canonical committed LF bytes.'
    }

    Write-Utf8NoBom -Path $trackedPath -Content "first`r`nsecond`r`n"
    $secondOutput = @(
        & $hasher -SourceRoot $testRoot -Revision $revision -Path 'tracked.txt'
    )
    if ($secondOutput.Count -ne 1 -or $secondOutput[0] -cne $expectedHash) {
        throw 'Git blob hash changed with uncommitted working-tree line endings.'
    }

    Assert-HasherFails `
        -ExpectedFragment 'full lowercase 40-character Git SHA' `
        -SourceRoot $testRoot `
        -Revision 'HEAD' `
        -Path 'tracked.txt'
    Assert-HasherFails `
        -ExpectedFragment 'normalized repository-relative path' `
        -SourceRoot $testRoot `
        -Revision $revision `
        -Path '../tracked.txt'
    Assert-HasherFails `
        -ExpectedFragment 'normalized repository-relative path' `
        -SourceRoot $testRoot `
        -Revision $revision `
        -Path 'folder//tracked.txt'
    Assert-HasherFails `
        -ExpectedFragment 'identify one Git blob' `
        -SourceRoot $testRoot `
        -Revision $revision `
        -Path 'missing.txt'
    if ($global:LASTEXITCODE -ne 0) {
        throw 'A handled Git blob probe failure leaked a native process exit code.'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Git blob SHA-256 tests passed.'
