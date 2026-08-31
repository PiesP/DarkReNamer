[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'validate-release-acceptance.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Release acceptance validator is missing: $validator"
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Copy-JsonObject {
    param([Parameter(Mandatory)][object] $Value)
    return $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function Write-JsonObject {
    param([Parameter(Mandatory)][object] $Value, [Parameter(Mandatory)][string] $Path)
    Write-Utf8NoBom -Path $Path -Content (($Value | ConvertTo-Json -Depth 20) + "`n")
}

function New-CompleteEvidence {
    param(
        [Parameter(Mandatory)][string] $SourceSha,
        [Parameter(Mandatory)][string] $ExecutableSha,
        [Parameter(Mandatory)][string] $WorkflowRun
    )

    $uiMatrix = @(
        foreach ($product in 'Windows 10', 'Windows 11') {
            foreach ($dpi in 100, 125, 150, 200, 250, 300) {
                foreach ($contrast in 'normal', 'high-contrast') {
                    [pscustomobject]@{
                        windows_product = $product
                        dpi_percent = $dpi
                        contrast = $contrast
                        status = 'pass'
                        observation_code = 'layout-verified'
                    }
                }
            }
        }
    )
    $scenarioKinds = @(
        'keyboard-only', 'accessibility', 'explorer-drag-drop', 'common-dialog',
        'clipboard', 'worker-cancellation', 'worker-close', 'startup-recovery',
        'recovery-export', 'intent-only-candidate-discard'
    )
    $scenarios = @(
        foreach ($product in 'Windows 10', 'Windows 11') {
            foreach ($kind in $scenarioKinds) {
                $row = [ordered]@{
                    windows_product = $product
                    kind = $kind
                    status = 'pass'
                    observation_code = 'interaction-verified'
                }
                if ($kind -eq 'accessibility') {
                    $row.accessibility_tool = [ordered]@{
                        name = 'Narrator'
                        version = 'tested Windows inbox version'
                    }
                }
                [pscustomobject] $row
            }
        }
    )
    $benchmarks = @(
        foreach ($media in 'ssd', 'hdd') {
            foreach ($count in 100, 1000, 10000) {
                [pscustomobject]@{
                    media = $media
                    count = $count
                    planning_ms = 12.5
                    execution_ms = 42.25
                    storage_model = "Fixture $($media.ToUpperInvariant()) model"
                    connection = if ($media -eq 'ssd') { 'nvme' } else { 'sata' }
                    free_space_bucket = '50-percent-or-more'
                    power_mode = 'balanced'
                    cleanup_observation = 'clean'
                }
            }
        }
    )

    return [pscustomobject]@{
        schema_version = 1
        source_sha = $SourceSha
        artifact = [pscustomobject]@{
            filename = 'DarkReNamer.exe'
            sha256 = $ExecutableSha
            origin = 'actions-handoff'
            workflow_run = $WorkflowRun
        }
        recorded_at_utc = '2026-08-30T12:00:00Z'
        operator_context = @(
            [pscustomobject]@{ windows_product = 'Windows 10'; windows_build = '19045.6216'; architecture = 'x64' },
            [pscustomobject]@{ windows_product = 'Windows 11'; windows_build = '26100.4946'; architecture = 'x64' }
        )
        ui_matrix = $uiMatrix
        scenarios = $scenarios
        benchmarks = $benchmarks
        durability_trials = @(
            [pscustomobject]@{ kind = 'process-crash'; status = 'pass'; observation_code = 'recovery-verified' },
            [pscustomobject]@{ kind = 'vm-hard-reset'; status = 'pass'; observation_code = 'recovery-verified'; authorization = 'operator-authorized' }
        )
        unexecuted = @(
            [pscustomobject]@{ id = 'power-loss-deferred'; target = 'durability|physical-power-loss'; reason_code = 'hardware-unavailable' },
            [pscustomobject]@{ id = 'storage-fault-deferred'; target = 'durability|storage-fault'; reason_code = 'authorization-not-granted' }
        )
    }
}

function Write-Provenance {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $SourceSha,
        [Parameter(Mandatory)][string] $ExecutableSha,
        [Parameter(Mandatory)][string] $WorkflowRun
    )
    Write-JsonObject -Path $Path -Value ([ordered]@{
        schema_version = 1
        source_sha = $SourceSha
        workflow_run = $WorkflowRun
        executable = [ordered]@{ filename = 'DarkReNamer.exe'; sha256 = $ExecutableSha }
    })
}

function Write-Checksums {
    param([Parameter(Mandatory)][string] $HandoffRoot)
    $subjects = @(
        'DarkReNamer-debug-symbols.zip', 'DarkReNamer.cdx.json', 'DarkReNamer.exe',
        'DISTRIBUTION.md', 'LICENSE', 'release-handoff.json', 'THIRD_PARTY_NOTICES.md'
    )
    $lines = foreach ($name in $subjects) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $HandoffRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash *$name"
    }
    Write-Utf8NoBom -Path (Join-Path $HandoffRoot 'SHA256SUMS.txt') -Content (($lines -join "`n") + "`n")
}

function Assert-ValidatorFails {
    param(
        [Parameter(Mandatory)][string] $ExpectedFragment,
        [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $HandoffRoot,
        [Parameter(Mandatory)][string] $EvidencePath
    )
    try {
        & $validator -SourceRoot $SourceRoot -HandoffRoot $HandoffRoot -EvidencePath $EvidencePath | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedFragment*") {
            throw "Expected validator failure containing '$ExpectedFragment', got: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected validator failure containing '$ExpectedFragment', but validation succeeded."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-release-acceptance-$([Guid]::NewGuid())"
$sourceRoot = Join-Path $testRoot 'source'
$handoffRoot = Join-Path $testRoot 'dist'
$evidencePath = Join-Path $testRoot 'windows-acceptance-evidence.json'
$workflowRun = '33257061299'

try {
    New-Item -ItemType Directory -Path $sourceRoot, $handoffRoot | Out-Null
    foreach ($name in 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DISTRIBUTION.md') {
        Write-Utf8NoBom -Path (Join-Path $sourceRoot $name) -Content "$name source policy`n"
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination $handoffRoot
    }
    & git -C $sourceRoot init --quiet
    & git -C $sourceRoot config user.name 'DarkReNamer test'
    & git -C $sourceRoot config user.email 'darkrenamer-test@example.invalid'
    & git -C $sourceRoot add -- LICENSE THIRD_PARTY_NOTICES.md DISTRIBUTION.md
    & git -C $sourceRoot commit --quiet -m 'test: initialize release source fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit source fixture repository.' }
    $sourceSha = (& git -C $sourceRoot rev-parse HEAD).Trim()

    [IO.File]::WriteAllBytes((Join-Path $handoffRoot 'DarkReNamer.exe'), [byte[]](0x4d, 0x5a, 0x01, 0x02))
    [IO.File]::WriteAllBytes((Join-Path $handoffRoot 'DarkReNamer.pdb'), [byte[]](0x50, 0x44, 0x42, 0x00))
    Write-Utf8NoBom -Path (Join-Path $handoffRoot 'DarkReNamer.cdx.json') -Content '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[{"type":"application","name":"darknamer-app","version":"0.1.0"}]}'
    Compress-Archive -LiteralPath (Join-Path $handoffRoot 'DarkReNamer.pdb') -DestinationPath (Join-Path $handoffRoot 'DarkReNamer-debug-symbols.zip')
    $exeSha = (Get-FileHash -LiteralPath (Join-Path $handoffRoot 'DarkReNamer.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Provenance -Path (Join-Path $handoffRoot 'release-handoff.json') -SourceSha $sourceSha -ExecutableSha $exeSha -WorkflowRun $workflowRun
    Write-Checksums -HandoffRoot $handoffRoot

    $global:DarkReNamerTestAuthenticodeStatus = 'NotSigned'
    function global:Get-AuthenticodeSignature {
        param([string] $FilePath)
        [pscustomobject]@{ Path = $FilePath; Status = $global:DarkReNamerTestAuthenticodeStatus }
    }

    $complete = New-CompleteEvidence -SourceSha $sourceSha -ExecutableSha $exeSha -WorkflowRun $workflowRun
    Write-JsonObject -Value $complete -Path $evidencePath
    & $validator -SourceRoot $sourceRoot -HandoffRoot $handoffRoot -EvidencePath $evidencePath | Out-Null

    $sourceMismatch = Copy-JsonObject $complete
    $sourceMismatch.source_sha = 'a' * 40
    Write-JsonObject -Value $sourceMismatch -Path $evidencePath
    Assert-ValidatorFails -ExpectedFragment 'source_sha does not match checkout HEAD' -SourceRoot $sourceRoot -HandoffRoot $handoffRoot -EvidencePath $evidencePath

    $originMismatch = Copy-JsonObject $complete
    $originMismatch.artifact.origin = 'local-build'
    $originMismatch.artifact.PSObject.Properties.Remove('workflow_run')
    Write-JsonObject -Value $originMismatch -Path $evidencePath
    Assert-ValidatorFails -ExpectedFragment 'artifact.origin as actions-handoff' -SourceRoot $sourceRoot -HandoffRoot $handoffRoot -EvidencePath $evidencePath

    $runMismatch = Copy-JsonObject $complete
    $runMismatch.artifact.workflow_run = '33257061300'
    Write-JsonObject -Value $runMismatch -Path $evidencePath
    Assert-ValidatorFails -ExpectedFragment 'artifact.workflow_run does not match' -SourceRoot $sourceRoot -HandoffRoot $handoffRoot -EvidencePath $evidencePath

    $filenameMismatch = Copy-JsonObject $complete
    $filenameMismatch.artifact.filename = 'Other.exe'
    Write-JsonObject -Value $filenameMismatch -Path $evidencePath
    Assert-ValidatorFails -ExpectedFragment 'artifact.filename does not match' -SourceRoot $sourceRoot -HandoffRoot $handoffRoot -EvidencePath $evidencePath

    $hashMismatch = Copy-JsonObject $complete
    $hashMismatch.artifact.sha256 = 'a' * 64
    Write-JsonObject -Value $hashMismatch -Path $evidencePath
    Assert-ValidatorFails -ExpectedFragment 'artifact.sha256 does not match' -SourceRoot $sourceRoot -HandoffRoot $handoffRoot -EvidencePath $evidencePath

    Write-Provenance -Path (Join-Path $handoffRoot 'release-handoff.json') -SourceSha ('b' * 40) -ExecutableSha $exeSha -WorkflowRun $workflowRun
    Write-Checksums -HandoffRoot $handoffRoot
    Write-JsonObject -Value $complete -Path $evidencePath
    Assert-ValidatorFails -ExpectedFragment 'source_sha does not match source HEAD' -SourceRoot $sourceRoot -HandoffRoot $handoffRoot -EvidencePath $evidencePath

    Write-Host 'Release acceptance cross-validation tests passed.'
}
finally {
    Remove-Item Function:\global:Get-AuthenticodeSignature -ErrorAction SilentlyContinue
    Remove-Variable DarkReNamerTestAuthenticodeStatus -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
