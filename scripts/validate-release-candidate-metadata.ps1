[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunMetadataPath,
    [Parameter(Mandatory)]
    [string] $ArtifactMetadataPath,
    [Parameter(Mandatory)]
    [string] $ExpectedRunId,
    [Parameter(Mandatory)]
    [string] $ExpectedRunAttempt,
    [Parameter(Mandatory)]
    [string] $ExpectedArtifactId,
    [Parameter(Mandatory)]
    [string] $ExpectedSourceSha,
    [Parameter(Mandatory)]
    [string] $ExpectedArtifactName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.4') {
    throw 'Release candidate metadata validation requires PowerShell 7.4 or newer (pwsh).'
}

function Assert-PositiveNumericInput {
    param(
        [Parameter(Mandatory)]
        [string] $Value,
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Description
    )

    if ($Value -notmatch '^[1-9][0-9]*$') {
        throw "$Name must be a positive numeric $Description."
    }
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)]
        [object] $Object,
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Location
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Location is missing required field: $Name"
    }
    $property.Value
}

function Get-JsonPositiveIntegerText {
    param(
        [Parameter(Mandatory)]
        [object] $Value,
        [Parameter(Mandatory)]
        [string] $Location
    )

    $integerTypes = @(
        [byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64]
    )
    $isInteger = $false
    foreach ($type in $integerTypes) {
        if ($Value -is $type) {
            $isInteger = $true
            break
        }
    }
    if (-not $isInteger) {
        throw "$Location must be a positive JSON integer."
    }
    $text = [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($text -notmatch '^[1-9][0-9]*$') {
        throw "$Location must be a positive JSON integer."
    }
    $text
}

function Read-JsonObject {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $Location
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Location file is missing: $Path"
    }
    try {
        $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "$Location is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $value -or $value -isnot [pscustomobject]) {
        throw "$Location must be a JSON object."
    }
    $value
}

Assert-PositiveNumericInput `
    -Value $ExpectedRunId `
    -Name 'ExpectedRunId' `
    -Description 'GitHub Actions run ID'
Assert-PositiveNumericInput `
    -Value $ExpectedRunAttempt `
    -Name 'ExpectedRunAttempt' `
    -Description 'GitHub Actions run attempt'
Assert-PositiveNumericInput `
    -Value $ExpectedArtifactId `
    -Name 'ExpectedArtifactId' `
    -Description 'GitHub Actions artifact ID'
if ($ExpectedSourceSha -cnotmatch '^[0-9a-f]{40}$') {
    throw 'ExpectedSourceSha must be a full lowercase 40-character Git SHA.'
}
$derivedArtifactName = "DarkReNamer-dry-run-$ExpectedRunId-$ExpectedRunAttempt-windows"
if (-not [string]::Equals($ExpectedArtifactName, $derivedArtifactName, [StringComparison]::Ordinal)) {
    throw 'ExpectedArtifactName does not match the run and attempt identity.'
}

$run = Read-JsonObject -Path $RunMetadataPath -Location 'run metadata'
$runId = Get-JsonPositiveIntegerText `
    -Value (Get-RequiredProperty -Object $run -Name 'id' -Location 'run metadata') `
    -Location 'run metadata.id'
if ($runId -cne $ExpectedRunId) {
    throw 'Run metadata id does not match ExpectedRunId.'
}
$runAttempt = Get-JsonPositiveIntegerText `
    -Value (Get-RequiredProperty -Object $run -Name 'run_attempt' -Location 'run metadata') `
    -Location 'run metadata.run_attempt'
if ($runAttempt -cne $ExpectedRunAttempt) {
    throw 'Run metadata run_attempt does not match ExpectedRunAttempt.'
}
if ((Get-RequiredProperty -Object $run -Name 'event' -Location 'run metadata') -cne 'workflow_dispatch') {
    throw 'Candidate run event must be workflow_dispatch.'
}
if ((Get-RequiredProperty -Object $run -Name 'status' -Location 'run metadata') -cne 'completed' -or
    (Get-RequiredProperty -Object $run -Name 'conclusion' -Location 'run metadata') -cne 'success') {
    throw 'Candidate run must be completed successfully.'
}
if ((Get-RequiredProperty -Object $run -Name 'head_branch' -Location 'run metadata') -cne 'master') {
    throw 'Candidate run head_branch must be master.'
}
if ((Get-RequiredProperty -Object $run -Name 'head_sha' -Location 'run metadata') -cne $ExpectedSourceSha) {
    throw 'Candidate run head_sha does not match ExpectedSourceSha.'
}
if ((Get-RequiredProperty -Object $run -Name 'path' -Location 'run metadata') -cne
    '.github/workflows/release.yaml') {
    throw 'Candidate run path must identify .github/workflows/release.yaml.'
}

$artifact = Read-JsonObject -Path $ArtifactMetadataPath -Location 'artifact metadata'
$artifactId = Get-JsonPositiveIntegerText `
    -Value (Get-RequiredProperty -Object $artifact -Name 'id' -Location 'artifact metadata') `
    -Location 'artifact metadata.id'
if ($artifactId -cne $ExpectedArtifactId) {
    throw 'Candidate artifact id does not match ExpectedArtifactId.'
}
if ((Get-RequiredProperty -Object $artifact -Name 'name' -Location 'artifact metadata') -cne
    $ExpectedArtifactName) {
    throw 'Candidate artifact name does not match ExpectedArtifactName.'
}
$expired = Get-RequiredProperty -Object $artifact -Name 'expired' -Location 'artifact metadata'
if ($expired -isnot [bool]) {
    throw 'Artifact metadata.expired must be a JSON boolean.'
}
if ($expired) {
    throw 'Candidate artifact is expired.'
}
$artifactRun = Get-RequiredProperty `
    -Object $artifact `
    -Name 'workflow_run' `
    -Location 'artifact metadata'
if ($artifactRun -isnot [pscustomobject]) {
    throw 'Artifact metadata.workflow_run must be a JSON object.'
}
$artifactRunId = Get-JsonPositiveIntegerText `
    -Value (Get-RequiredProperty -Object $artifactRun -Name 'id' -Location 'artifact metadata.workflow_run') `
    -Location 'artifact metadata.workflow_run.id'
if ($artifactRunId -cne $ExpectedRunId) {
    throw 'Candidate artifact workflow_run.id does not match ExpectedRunId.'
}
if ((Get-RequiredProperty `
        -Object $artifactRun `
        -Name 'head_branch' `
        -Location 'artifact metadata.workflow_run') -cne 'master') {
    throw 'Candidate artifact workflow_run.head_branch must be master.'
}
if ((Get-RequiredProperty `
        -Object $artifactRun `
        -Name 'head_sha' `
        -Location 'artifact metadata.workflow_run') -cne $ExpectedSourceSha) {
    throw 'Candidate artifact workflow_run.head_sha does not match ExpectedSourceSha.'
}

Write-Host "Validated immutable release candidate artifact $ExpectedArtifactId from run $ExpectedRunId attempt $ExpectedRunAttempt at source $ExpectedSourceSha."
