[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$preparer = Join-Path $PSScriptRoot 'prepare-release-cyclonedx.ps1'
if (-not (Test-Path -LiteralPath $preparer -PathType Leaf)) {
    throw "Release CycloneDX preparer is missing: $preparer"
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
        (($Value | ConvertTo-Json -Depth 10) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function New-CycloneDxFixture {
    [pscustomobject][ordered]@{
        bomFormat = 'CycloneDX'
        specVersion = '1.5'
        version = 1
        metadata = [pscustomobject][ordered]@{
            component = [pscustomobject][ordered]@{
                type = 'application'
                name = 'DarkReNamer'
                version = '0.1.0'
            }
        }
        components = @()
        dependencies = @()
    }
}

function Assert-PreparerFails {
    param(
        [Parameter(Mandatory)]
        [string] $ExpectedFragment,
        [Parameter(Mandatory)]
        [string] $InputPath,
        [Parameter(Mandatory)]
        [string] $OutputPath,
        [string] $SerialNumber = 'urn:uuid:12345678-1234-4234-9234-123456789abc'
    )

    try {
        & $preparer `
            -InputPath $InputPath `
            -OutputPath $OutputPath `
            -SerialNumber $SerialNumber
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedFragment*") {
            throw "Expected preparer failure containing '$ExpectedFragment', got: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected preparer failure containing '$ExpectedFragment', but preparation succeeded."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-release-cyclonedx-$([Guid]::NewGuid())"
$inputPath = Join-Path $testRoot 'input.json'
$outputPath = Join-Path $testRoot 'output.json'
$serialNumber = 'urn:uuid:12345678-1234-4234-9234-123456789abc'

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Write-JsonObject -Path $inputPath -Value (New-CycloneDxFixture)

    & $preparer `
        -InputPath $inputPath `
        -OutputPath $outputPath `
        -SerialNumber $serialNumber
    $prepared = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    if ($prepared.bomFormat -cne 'CycloneDX' -or
        $prepared.specVersion -cne '1.5' -or
        $prepared.serialNumber -cne $serialNumber -or
        $prepared.metadata.component.name -cne 'DarkReNamer') {
        throw 'Prepared CycloneDX values do not preserve the source document and exact serial number.'
    }

    Assert-PreparerFails `
        -ExpectedFragment 'OutputPath already exists' `
        -InputPath $inputPath `
        -OutputPath $outputPath

    $invalidSerialOutput = Join-Path $testRoot 'invalid-serial.json'
    Assert-PreparerFails `
        -ExpectedFragment 'SerialNumber must be a lowercase RFC 4122 UUID URN' `
        -InputPath $inputPath `
        -OutputPath $invalidSerialOutput `
        -SerialNumber 'urn:uuid:not-a-uuid'

    $existingSerial = New-CycloneDxFixture
    $existingSerial | Add-Member -NotePropertyName serialNumber -NotePropertyValue $serialNumber
    Write-JsonObject -Path $inputPath -Value $existingSerial
    Assert-PreparerFails `
        -ExpectedFragment 'already contains serialNumber' `
        -InputPath $inputPath `
        -OutputPath (Join-Path $testRoot 'existing-serial.json')

    $wrongFormat = New-CycloneDxFixture
    $wrongFormat.bomFormat = 'SPDX'
    Write-JsonObject -Path $inputPath -Value $wrongFormat
    Assert-PreparerFails `
        -ExpectedFragment 'bomFormat must be CycloneDX' `
        -InputPath $inputPath `
        -OutputPath (Join-Path $testRoot 'wrong-format.json')

    Write-Host 'Release CycloneDX preparer tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
