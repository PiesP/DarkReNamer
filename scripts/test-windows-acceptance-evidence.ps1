[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'validate-windows-acceptance-evidence.ps1'
$schema = Join-Path $PSScriptRoot 'windows-acceptance-evidence.schema.json'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Windows acceptance evidence validator is missing: $validator"
}
if (-not (Test-Path -LiteralPath $schema -PathType Leaf)) {
    throw "Windows acceptance evidence schema is missing: $schema"
}

function Copy-Evidence {
    param(
        [Parameter(Mandatory)]
        [object] $Evidence
    )

    return $Evidence | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function Write-Evidence {
    param(
        [Parameter(Mandatory)]
        [object] $Evidence,
        [Parameter(Mandatory)]
        [string] $Path
    )

    $json = $Evidence | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Assert-ValidatorPasses {
    param(
        [Parameter(Mandatory)]
        [object] $Evidence,
        [Parameter(Mandatory)]
        [string] $Name,
        [switch] $Draft
    )

    $path = Join-Path $script:testRoot "$Name.json"
    Write-Evidence -Evidence $Evidence -Path $path
    if ($Draft) {
        & $validator -EvidencePath $path -Draft | Out-Null
    }
    else {
        & $validator -EvidencePath $path | Out-Null
    }
}

function Assert-ValidatorFails {
    param(
        [Parameter(Mandatory)]
        [object] $Evidence,
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $ExpectedFragment,
        [switch] $Draft
    )

    $path = Join-Path $script:testRoot "$Name.json"
    Write-Evidence -Evidence $Evidence -Path $path
    try {
        if ($Draft) {
            & $validator -EvidencePath $path -Draft | Out-Null
        }
        else {
            & $validator -EvidencePath $path | Out-Null
        }
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedFragment*") {
            throw "Expected '$Name' to fail with '$ExpectedFragment', got: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected '$Name' to fail with '$ExpectedFragment', but validation succeeded."
}

function New-CompleteEvidence {
    $uiMatrix = @(
        foreach ($product in 'Windows 10', 'Windows 11') {
            foreach ($dpi in 100, 125, 150, 200) {
                foreach ($contrast in 'normal', 'high-contrast') {
                    [pscustomobject]@{
                        windows_product = $product
                        dpi_percent = $dpi
                        contrast = $contrast
                        status = 'pass'
                        observation = 'Layout and command state matched the acceptance checklist.'
                    }
                }
            }
        }
    )

    $scenarioKinds = @(
        'keyboard-only',
        'accessibility',
        'explorer-drag-drop',
        'common-dialog',
        'clipboard',
        'worker-cancellation',
        'worker-close',
        'startup-recovery',
        'recovery-export',
        'intent-only-candidate-discard'
    )
    $scenarios = @(
        foreach ($product in 'Windows 10', 'Windows 11') {
            foreach ($kind in $scenarioKinds) {
                $row = [ordered]@{
                    windows_product = $product
                    kind = $kind
                    status = 'pass'
                    observation = 'The named interaction completed with the expected visible state.'
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
        source_sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        artifact = [pscustomobject]@{
            filename = 'DarkReNamer.exe'
            sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            origin = 'actions-handoff'
            workflow_run = '33253917056'
        }
        recorded_at_utc = '2026-08-29T12:00:00Z'
        operator_context = @(
            [pscustomobject]@{
                windows_product = 'Windows 10'
                windows_build = '19045.6216'
                architecture = 'x64'
            },
            [pscustomobject]@{
                windows_product = 'Windows 11'
                windows_build = '26100.4946'
                architecture = 'x64'
            }
        )
        ui_matrix = $uiMatrix
        scenarios = $scenarios
        benchmarks = $benchmarks
        durability_trials = @(
            [pscustomobject]@{
                kind = 'process-crash'
                status = 'pass'
                observation = 'Restart recovery returned the fixture to the original state.'
            },
            [pscustomobject]@{
                kind = 'vm-hard-reset'
                status = 'pass'
                observation = 'An authorized VM hard reset preserved a recoverable journal state.'
                authorization = 'operator-authorized'
            }
        )
        unexecuted = @(
            [pscustomobject]@{
                id = 'power-loss-deferred'
                target = 'durability|physical-power-loss'
                reason = 'No authorized physical power-loss environment was available.'
            },
            [pscustomobject]@{
                id = 'storage-fault-deferred'
                target = 'durability|storage-fault'
                reason = 'Storage fault injection was not authorized for this run.'
            }
        )
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-acceptance-validator-$([Guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    $complete = New-CompleteEvidence
    Assert-ValidatorPasses -Evidence $complete -Name 'valid-complete'

    $localBuild = Copy-Evidence $complete
    $localBuild.artifact.origin = 'local-build'
    $localBuild.artifact.PSObject.Properties.Remove('workflow_run')
    Assert-ValidatorPasses -Evidence $localBuild -Name 'valid-local-build'

    $storageFaultAlternative = Copy-Evidence $complete
    $storageFaultAlternative.durability_trials[1].kind = 'storage-fault'
    $storageFaultAlternative.durability_trials[1].observation = 'Authorized fault injection preserved a recoverable journal state.'
    $storageFaultAlternative.unexecuted[1].id = 'vm-reset-deferred'
    $storageFaultAlternative.unexecuted[1].target = 'durability|vm-hard-reset'
    $storageFaultAlternative.unexecuted[1].reason = 'No authorized VM hard-reset environment was available.'
    Assert-ValidatorPasses -Evidence $storageFaultAlternative -Name 'valid-storage-fault-alternative'

    $draft = Copy-Evidence $complete
    $draft.ui_matrix = @($draft.ui_matrix | Select-Object -SkipLast 1)
    $draft.scenarios[0].status = 'not-run'
    $draft.scenarios[0].observation = 'Not executed in this draft.'
    $draft.scenarios[0] | Add-Member -NotePropertyName unexecuted_id -NotePropertyValue 'keyboard-deferred'
    $draft.unexecuted = @(
        [pscustomobject]@{
            id = 'ui-cell-deferred'
            target = 'ui|Windows 11|200|high-contrast'
            reason = 'This display configuration was unavailable for the draft run.'
        },
        [pscustomobject]@{
            id = 'keyboard-deferred'
            target = 'scenario|Windows 10|keyboard-only'
            reason = 'Keyboard-only review was scheduled for the next operator session.'
        },
        $complete.unexecuted[0],
        $complete.unexecuted[1]
    )
    Assert-ValidatorPasses -Evidence $draft -Name 'valid-draft' -Draft

    $missingCell = Copy-Evidence $complete
    $missingCell.ui_matrix = @($missingCell.ui_matrix | Select-Object -SkipLast 1)
    Assert-ValidatorFails `
        -Evidence $missingCell `
        -Name 'missing-ui-cell' `
        -ExpectedFragment 'missing UI matrix target'

    $duplicateBenchmark = Copy-Evidence $complete
    $duplicateBenchmark.benchmarks += Copy-Evidence $duplicateBenchmark.benchmarks[0]
    Assert-ValidatorFails `
        -Evidence $duplicateBenchmark `
        -Name 'duplicate-benchmark' `
        -ExpectedFragment 'Duplicate benchmark row'

    $malformedHash = Copy-Evidence $complete
    $malformedHash.artifact.sha256 = 'abc123'
    Assert-ValidatorFails `
        -Evidence $malformedHash `
        -Name 'malformed-hash' `
        -ExpectedFragment '64-character SHA-256'

    $missingRun = Copy-Evidence $complete
    $missingRun.artifact.PSObject.Properties.Remove('workflow_run')
    Assert-ValidatorFails `
        -Evidence $missingRun `
        -Name 'missing-workflow-run' `
        -ExpectedFragment 'workflow_run is required'

    $pathLeak = Copy-Evidence $complete
    $pathLeak.ui_matrix[0].observation = 'Captured from C:\Users\operator\Desktop\acceptance.png.'
    Assert-ValidatorFails `
        -Evidence $pathLeak `
        -Name 'path-leakage' `
        -ExpectedFragment 'prohibited absolute or profile path'

    $usernameField = Copy-Evidence $complete
    $usernameField.operator_context[0] | Add-Member -NotePropertyName username -NotePropertyValue 'operator'
    Assert-ValidatorFails `
        -Evidence $usernameField `
        -Name 'username-field' `
        -ExpectedFragment 'prohibited identity or volume field'

    $hostnameValue = Copy-Evidence $complete
    $hostnameValue.scenarios[0].observation = 'hostname=acceptance-machine'
    Assert-ValidatorFails `
        -Evidence $hostnameValue `
        -Name 'hostname-value' `
        -ExpectedFragment 'prohibited identity or volume-serial data'

    $volumeSerialValue = Copy-Evidence $complete
    $volumeSerialValue.benchmarks[0].storage_model = 'volume serial=1234-5678'
    Assert-ValidatorFails `
        -Evidence $volumeSerialValue `
        -Name 'volume-serial-value' `
        -ExpectedFragment 'prohibited identity or volume-serial data'

    $notRunWithoutReason = Copy-Evidence $complete
    $notRunWithoutReason.ui_matrix[0].status = 'not-run'
    $notRunWithoutReason.ui_matrix[0].observation = 'Not executed.'
    Assert-ValidatorFails `
        -Evidence $notRunWithoutReason `
        -Name 'not-run-without-reason' `
        -ExpectedFragment 'must reference unexecuted_id' `
        -Draft

    $physicalPowerOnly = Copy-Evidence $complete
    $physicalPowerOnly.durability_trials[1].kind = 'physical-power-loss'
    $physicalPowerOnly.durability_trials[1].observation = 'The separately authorized physical trial recovered successfully.'
    $physicalPowerOnly.unexecuted = @(
        [pscustomobject]@{
            id = 'vm-reset-deferred'
            target = 'durability|vm-hard-reset'
            reason = 'No authorized VM hard-reset environment was available.'
        },
        $complete.unexecuted[1]
    )
    Assert-ValidatorFails `
        -Evidence $physicalPowerOnly `
        -Name 'physical-power-is-not-disruptive-gate' `
        -ExpectedFragment 'VM hard-reset or storage-fault trial'

    $equivalenceClaim = Copy-Evidence $complete
    $equivalenceClaim.durability_trials[0].observation = 'This process crash is the same as a physical power loss.'
    Assert-ValidatorFails `
        -Evidence $equivalenceClaim `
        -Name 'durability-equivalence-claim' `
        -ExpectedFragment 'must not claim equivalence'

    $missingAuthorization = Copy-Evidence $complete
    $missingAuthorization.durability_trials[1].PSObject.Properties.Remove('authorization')
    Assert-ValidatorFails `
        -Evidence $missingAuthorization `
        -Name 'missing-disruptive-authorization' `
        -ExpectedFragment 'requires operator-authorized scope'

    Write-Host 'Windows acceptance evidence validator tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
