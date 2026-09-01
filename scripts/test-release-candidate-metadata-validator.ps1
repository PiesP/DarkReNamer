[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'validate-release-candidate-metadata.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Release candidate metadata validator is missing: $validator"
}

function Write-JsonObject {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [object] $Value
    )

    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Assert-ValidatorFails {
    param(
        [Parameter(Mandatory)]
        [string] $ExpectedFragment,
        [Parameter(Mandatory)]
        [string] $RunMetadataPath,
        [Parameter(Mandatory)]
        [string] $ArtifactMetadataPath,
        [string] $ExpectedRunId = '33465335192',
        [string] $ExpectedRunAttempt = '2',
        [string] $ExpectedArtifactId = '9123456789',
        [string] $ExpectedSourceSha = ('a' * 40),
        [string] $ExpectedArtifactName = 'DarkReNamer-dry-run-33465335192-2-windows'
    )

    try {
        & $validator `
            -RunMetadataPath $RunMetadataPath `
            -ArtifactMetadataPath $ArtifactMetadataPath `
            -ExpectedRunId $ExpectedRunId `
            -ExpectedRunAttempt $ExpectedRunAttempt `
            -ExpectedArtifactId $ExpectedArtifactId `
            -ExpectedSourceSha $ExpectedSourceSha `
            -ExpectedArtifactName $ExpectedArtifactName
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedFragment*") {
            throw "Expected validator failure containing '$ExpectedFragment', got: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected validator failure containing '$ExpectedFragment', but validation succeeded."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-candidate-metadata-$([Guid]::NewGuid())"
$runMetadataPath = Join-Path $testRoot 'run.json'
$artifactMetadataPath = Join-Path $testRoot 'artifact.json'
$sourceSha = 'a' * 40
$runId = '33465335192'
$runAttempt = '2'
$artifactId = '9123456789'
$artifactName = "DarkReNamer-dry-run-$runId-$runAttempt-windows"

function New-RunMetadata {
    [pscustomobject][ordered]@{
        id = [Int64]$runId
        run_attempt = [Int64]$runAttempt
        event = 'workflow_dispatch'
        status = 'completed'
        conclusion = 'success'
        head_branch = 'master'
        head_sha = $sourceSha
        path = '.github/workflows/release.yaml'
    }
}

function New-ArtifactMetadata {
    [pscustomobject][ordered]@{
        id = [Int64]$artifactId
        name = $artifactName
        expired = $false
        workflow_run = [pscustomobject][ordered]@{
            id = [Int64]$runId
            head_branch = 'master'
            head_sha = $sourceSha
        }
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Write-JsonObject -Path $runMetadataPath -Value (New-RunMetadata)
    Write-JsonObject -Path $artifactMetadataPath -Value (New-ArtifactMetadata)

    $successOutput = @(
        & $validator `
            -RunMetadataPath $runMetadataPath `
            -ArtifactMetadataPath $artifactMetadataPath `
            -ExpectedRunId $runId `
            -ExpectedRunAttempt $runAttempt `
            -ExpectedArtifactId $artifactId `
            -ExpectedSourceSha $sourceSha `
            -ExpectedArtifactName $artifactName 6>&1
    )
    $successText = (($successOutput | ForEach-Object { "$_" }) -join ' ')
    if ($successText -notlike '*Validated immutable release candidate artifact*') {
        throw "Candidate metadata validation did not report success: $successText"
    }

    Assert-ValidatorFails `
        -ExpectedFragment 'ExpectedRunId must be a positive numeric GitHub Actions run ID' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath `
        -ExpectedRunId '0'

    $run = New-RunMetadata
    $run.run_attempt = 3
    Write-JsonObject -Path $runMetadataPath -Value $run
    Assert-ValidatorFails `
        -ExpectedFragment 'run_attempt does not match' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    $run = New-RunMetadata
    $run.event = 'push'
    Write-JsonObject -Path $runMetadataPath -Value $run
    Assert-ValidatorFails `
        -ExpectedFragment 'must be workflow_dispatch' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    $run = New-RunMetadata
    $run.conclusion = 'failure'
    Write-JsonObject -Path $runMetadataPath -Value $run
    Assert-ValidatorFails `
        -ExpectedFragment 'must be completed successfully' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    $run = New-RunMetadata
    $run.head_sha = 'b' * 40
    Write-JsonObject -Path $runMetadataPath -Value $run
    Assert-ValidatorFails `
        -ExpectedFragment 'head_sha does not match' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    $run = New-RunMetadata
    $run.path = '.github/workflows/other.yaml'
    Write-JsonObject -Path $runMetadataPath -Value $run
    Assert-ValidatorFails `
        -ExpectedFragment 'must identify .github/workflows/release.yaml' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    Write-JsonObject -Path $runMetadataPath -Value (New-RunMetadata)
    $artifact = New-ArtifactMetadata
    $artifact.id = [Int64]9123456790
    Write-JsonObject -Path $artifactMetadataPath -Value $artifact
    Assert-ValidatorFails `
        -ExpectedFragment 'artifact id does not match' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    $artifact = New-ArtifactMetadata
    $artifact.name = 'unexpected-artifact'
    Write-JsonObject -Path $artifactMetadataPath -Value $artifact
    Assert-ValidatorFails `
        -ExpectedFragment 'artifact name does not match' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    $artifact = New-ArtifactMetadata
    $artifact.expired = $true
    Write-JsonObject -Path $artifactMetadataPath -Value $artifact
    Assert-ValidatorFails `
        -ExpectedFragment 'artifact is expired' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    $artifact = New-ArtifactMetadata
    $artifact.workflow_run.id = [Int64]33465335193
    Write-JsonObject -Path $artifactMetadataPath -Value $artifact
    Assert-ValidatorFails `
        -ExpectedFragment 'artifact workflow_run.id does not match' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    $artifact = New-ArtifactMetadata
    $artifact.workflow_run.head_sha = 'b' * 40
    Write-JsonObject -Path $artifactMetadataPath -Value $artifact
    Assert-ValidatorFails `
        -ExpectedFragment 'artifact workflow_run.head_sha does not match' `
        -RunMetadataPath $runMetadataPath `
        -ArtifactMetadataPath $artifactMetadataPath

    Write-Host 'Release candidate metadata validator tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
