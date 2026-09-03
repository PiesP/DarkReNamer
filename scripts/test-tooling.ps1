[CmdletBinding()]
param(
    [ValidateSet('Current', 'Ubuntu', 'Windows')]
    [string] $Platform = 'Current'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Platform -eq 'Current') {
    $Platform = if ($IsWindows) { 'Windows' } else { 'Ubuntu' }
}

$commonTests = @(
    'test-toolchain-consistency.ps1'
    'test-measure-windows-binary.ps1'
    'test-get-git-blob-sha256.ps1'
    'test-prepare-release-cyclonedx.ps1'
    'test-release-workflow-powershell-syntax.ps1'
    'test-release-candidate-metadata-validator.ps1'
    'test-windows-acceptance-evidence.ps1'
    'test-new-windows-acceptance-draft.ps1'
    'test-add-windows-acceptance-benchmark.ps1'
    'test-release-acceptance-validator.ps1'
)
$platformTests = if ($Platform -eq 'Ubuntu') {
    @('test-release-handoff-validator.ps1') + $commonTests
}
else {
    $commonTests
}

foreach ($test in $platformTests) {
    $path = Join-Path $PSScriptRoot $test
    Write-Host "Running $test ($Platform)"
    $global:LASTEXITCODE = 0
    & $path
    if ($LASTEXITCODE -ne 0) {
        throw "$test failed with exit code $LASTEXITCODE."
    }
}

Write-Host "Tooling tests passed for $Platform ($($platformTests.Count) scripts)."
