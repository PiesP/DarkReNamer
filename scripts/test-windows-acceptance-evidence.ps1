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
        [switch] $Draft,
        [string] $ExpectedOutput,
        [string] $ForbiddenOutput,
        [string] $VisualEvidenceRoot
    )

    $path = Join-Path $script:testRoot "$Name.json"
    Write-Evidence -Evidence $Evidence -Path $path
    $arguments = @{ EvidencePath = $path }
    $effectiveVisualRoot = if ($VisualEvidenceRoot) {
        $VisualEvidenceRoot
    }
    elseif (-not $Draft) {
        $script:visualRoot
    }
    if ($effectiveVisualRoot) {
        $arguments.VisualEvidenceRoot = $effectiveVisualRoot
    }
    if ($Draft) {
        $arguments.Draft = $true
        $output = @(& $validator @arguments 6>&1)
    }
    else {
        $output = @(& $validator @arguments 6>&1)
    }
    $flattenedOutput = (($output | ForEach-Object { "$_" }) -join ' ')
    $flattenedOutput = (($flattenedOutput -split '\s+') -join ' ').Trim()
    if ($ExpectedOutput -and $flattenedOutput -notlike "*$ExpectedOutput*") {
        throw "Expected '$Name' output to contain '$ExpectedOutput', got: $flattenedOutput"
    }
    if ($ForbiddenOutput -and $flattenedOutput -like "*$ForbiddenOutput*") {
        throw "Expected '$Name' output not to contain '$ForbiddenOutput', got: $flattenedOutput"
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
        [switch] $Draft,
        [string] $VisualEvidenceRoot
    )

    $path = Join-Path $script:testRoot "$Name.json"
    Write-Evidence -Evidence $Evidence -Path $path
    try {
        $arguments = @{ EvidencePath = $path }
        $effectiveVisualRoot = if ($VisualEvidenceRoot) {
            $VisualEvidenceRoot
        }
        elseif (-not $Draft) {
            $script:visualRoot
        }
        if ($effectiveVisualRoot) {
            $arguments.VisualEvidenceRoot = $effectiveVisualRoot
        }
        if ($Draft) {
            $arguments.Draft = $true
            & $validator @arguments | Out-Null
        }
        else {
            & $validator @arguments | Out-Null
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

function Assert-SchemaRejects {
    param(
        [Parameter(Mandatory)]
        [object] $Evidence,
        [Parameter(Mandatory)]
        [string] $Name
    )

    $path = Join-Path $script:testRoot "$Name.json"
    Write-Evidence -Evidence $Evidence -Path $path
    $json = Get-Content -LiteralPath $path -Raw
    if ($json | Test-Json -SchemaFile $script:schema -ErrorAction SilentlyContinue) {
        throw "Expected JSON Schema to reject '$Name', but schema validation succeeded."
    }
}

function Assert-EvidencePathspec {
    param(
        [Parameter(Mandatory)]
        [string] $TestRoot
    )

    $repository = Join-Path $TestRoot 'pathspec-repository'
    $nested = Join-Path $repository 'evidence'
    $scripts = Join-Path $repository 'scripts'
    New-Item -ItemType Directory -Path $repository, $nested, $scripts | Out-Null

    $rootEvidence = 'windows-acceptance-evidence-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json'
    $nestedEvidence = 'windows-acceptance-evidence-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json'
    $mixedRootEvidence = 'Windows-Acceptance-Evidence-cccccccccccccccccccccccccccccccccccccccc.JSON'
    $mixedNestedEvidence = 'WINDOWS-ACCEPTANCE-EVIDENCE-dddddddddddddddddddddddddddddddddddddddd.json'
    [IO.File]::WriteAllText((Join-Path $repository $rootEvidence), '{}')
    [IO.File]::WriteAllText((Join-Path $nested $nestedEvidence), '{}')
    [IO.File]::WriteAllText((Join-Path $repository $mixedRootEvidence), '{}')
    [IO.File]::WriteAllText((Join-Path $nested $mixedNestedEvidence), '{}')
    [IO.File]::WriteAllText(
        (Join-Path $scripts 'windows-acceptance-evidence.schema.json'),
        '{}'
    )

    & git -C $repository init --quiet
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to initialize the evidence pathspec fixture repository.'
    }
    & git -C $repository add --all
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to populate the evidence pathspec fixture index.'
    }
    $matches = @(& git -C $repository ls-files -- ':(glob,icase)**/windows-acceptance-evidence-*.json')
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to evaluate the evidence pathspec fixture.'
    }
    $expected = @(
        "evidence/$mixedNestedEvidence"
        "evidence/$nestedEvidence"
        $mixedRootEvidence
        $rootEvidence
    )
    if ($matches.Count -ne $expected.Count -or
        @($expected | Where-Object { $matches -cnotcontains $_ }).Count -ne 0) {
        throw "Evidence pathspec mismatch. Expected: $($expected -join ', '). Actual: $($matches -join ', ')."
    }
}

function New-VisualCaptures {
    param([Parameter(Mandatory)][string] $ExecutableSha)

    $captures = [Collections.Generic.List[object]]::new()
    $sequence = 1
    foreach ($product in 'Windows 10', 'Windows 11') {
        $productId = $product.ToLowerInvariant().Replace(' ', '')
        $dpiIndex = 0
        foreach ($dpi in 100, 125, 150, 200, 250, 300) {
            foreach ($contrast in 'normal', 'high-contrast') {
                $appearance = if ($contrast -eq 'high-contrast') {
                    'forced-colors'
                }
                else {
                    @('system', 'light', 'dark')[$dpiIndex % 3]
                }
                $id = "main-$productId-$dpi-$contrast"
                $captures.Add([pscustomobject][ordered]@{
                    id = $id
                    image = [pscustomobject][ordered]@{
                        filename = "$id.png"
                        sha256 = ([Convert]::ToString($sequence, 16).PadLeft(64, '0'))
                        pixel_width = 1280
                        pixel_height = 900
                    }
                    executable_sha256 = $ExecutableSha
                    ui_target = "ui|$product|$dpi|$contrast"
                    appearance = $appearance
                    surface = 'main-workbench'
                })
                $sequence++
            }
            $dpiIndex++
        }
    }

    foreach ($extra in @(
            @{ Id = 'surface-native-menu'; Product = 'Windows 10'; Dpi = 100; Appearance = 'system'; Surface = 'native-menu' },
            @{ Id = 'surface-appearance-dialog'; Product = 'Windows 10'; Dpi = 100; Appearance = 'light'; Surface = 'appearance-dialog' },
            @{ Id = 'surface-input-prompt'; Product = 'Windows 10'; Dpi = 125; Appearance = 'dark'; Surface = 'input-prompt' },
            @{ Id = 'surface-common-dialog'; Product = 'Windows 10'; Dpi = 150; Appearance = 'system'; Surface = 'common-dialog'; Scenario = 'common-dialog' },
            @{ Id = 'surface-confirmation-task-dialog'; Product = 'Windows 11'; Dpi = 100; Appearance = 'light'; Surface = 'confirmation-task-dialog' },
            @{ Id = 'surface-recovery-window'; Product = 'Windows 11'; Dpi = 150; Appearance = 'dark'; Surface = 'recovery-window'; Scenario = 'startup-recovery' }
        )) {
        $capture = [ordered]@{
            id = $extra.Id
            image = [pscustomobject][ordered]@{
                filename = "$($extra.Id).png"
                sha256 = ([Convert]::ToString($sequence, 16).PadLeft(64, '0'))
                pixel_width = 1280
                pixel_height = 900
            }
            executable_sha256 = $ExecutableSha
            ui_target = "ui|$($extra.Product)|$($extra.Dpi)|normal"
            appearance = $extra.Appearance
            surface = $extra.Surface
        }
        if ($extra.ContainsKey('Scenario')) {
            $capture.scenario_target = "scenario|$($extra.Product)|$($extra.Scenario)"
        }
        $captures.Add([pscustomobject] $capture)
        $sequence++
    }
    return @($captures)
}

function Write-VisualEvidenceFiles {
    param(
        [Parameter(Mandatory)][object] $Evidence,
        [Parameter(Mandatory)][string] $Root
    )
    foreach ($capture in $Evidence.visual_captures) {
        $path = Join-Path $Root $capture.image.filename
        $header = [byte[]](
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        )
        $suffix = [Text.Encoding]::UTF8.GetBytes($capture.id)
        [IO.File]::WriteAllBytes($path, [byte[]] ($header + $suffix))
        $capture.image.pixel_width = 1
        $capture.image.pixel_height = 1
        $capture.image.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function New-CompleteEvidence {
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
                    filesystem = 'ntfs'
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
        schema_version = 3
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
        visual_captures = @(New-VisualCaptures -ExecutableSha ('a' * 64))
        scenarios = $scenarios
        benchmarks = $benchmarks
        durability_trials = @(
            [pscustomobject]@{
                kind = 'process-crash'
                status = 'pass'
                observation_code = 'recovery-verified'
            },
            [pscustomobject]@{
                kind = 'vm-hard-reset'
                status = 'pass'
                observation_code = 'recovery-verified'
                authorization = 'operator-authorized'
            }
        )
        unexecuted = @(
            [pscustomobject]@{
                id = 'power-loss-deferred'
                target = 'durability|physical-power-loss'
                reason_code = 'hardware-unavailable'
            },
            [pscustomobject]@{
                id = 'storage-fault-deferred'
                target = 'durability|storage-fault'
                reason_code = 'authorization-not-granted'
            }
        )
    }
}

function New-HddUnavailableEvidence {
    param(
        [Parameter(Mandatory)]
        [object] $CompleteEvidence
    )

    $evidence = Copy-Evidence $CompleteEvidence
    $evidence.benchmarks = @($evidence.benchmarks | Where-Object { $_.media -ne 'hdd' })
    $evidence.unexecuted += @(
        [pscustomobject]@{
            id = 'hdd-100-unavailable'
            target = 'benchmark|hdd|100'
            reason_code = 'hardware-unavailable'
        },
        [pscustomobject]@{
            id = 'hdd-1000-unavailable'
            target = 'benchmark|hdd|1000'
            reason_code = 'hardware-unavailable'
        },
        [pscustomobject]@{
            id = 'hdd-10000-unavailable'
            target = 'benchmark|hdd|10000'
            reason_code = 'hardware-unavailable'
        }
    )
    return $evidence
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-acceptance-validator-$([Guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Assert-EvidencePathspec -TestRoot $testRoot

    $complete = New-CompleteEvidence
    $visualRoot = Join-Path $testRoot 'visual-root'
    New-Item -ItemType Directory -Path $visualRoot | Out-Null
    Write-VisualEvidenceFiles -Evidence $complete -Root $visualRoot
    $passThruPath = Join-Path $testRoot 'pass-thru-draft.json'
    Write-Evidence -Evidence $complete -Path $passThruPath
    $defaultOutput = @(& $validator -EvidencePath $passThruPath -Draft 6>&1)
    if ((($defaultOutput | ForEach-Object { "$_" }) -join ' ') -notlike
        '*Validated draft Windows acceptance evidence*') {
        throw 'Default evidence validation did not retain its human success output.'
    }
    $passThruOutput = @(& $validator -EvidencePath $passThruPath -Draft -PassThru 6>&1)
    if ($passThruOutput.Count -ne 1 -or $passThruOutput[0] -isnot [pscustomobject]) {
        throw 'Evidence PassThru must return exactly one validated evidence object.'
    }
    if (($passThruOutput[0].PSObject.Properties.Name -join ',') -cne
        'schema_version,source_sha,artifact,recorded_at_utc,operator_context,ui_matrix,visual_captures,scenarios,benchmarks,durability_trials,unexecuted') {
        throw 'Evidence PassThru fields do not match the validated evidence contract.'
    }
    $evidenceJson = ($complete | ConvertTo-Json -Depth 20) + "`n"
    $jsonDefaultOutput = @(& $validator -EvidenceJson $evidenceJson -Draft 6>&1)
    if ((($jsonDefaultOutput | ForEach-Object { "$_" }) -join ' ') -notlike
        '*Validated draft Windows acceptance evidence*') {
        throw 'EvidenceJson validation did not retain default human success output.'
    }
    $jsonPassThruOutput = @(& $validator -EvidenceJson $evidenceJson -Draft -PassThru 6>&1)
    if ($jsonPassThruOutput.Count -ne 1 -or $jsonPassThruOutput[0] -isnot [pscustomobject]) {
        throw 'EvidenceJson PassThru must return exactly one validated evidence object.'
    }
    $pathSemanticJson = $passThruOutput[0] | ConvertTo-Json -Depth 20 -Compress
    $memorySemanticJson = $jsonPassThruOutput[0] | ConvertTo-Json -Depth 20 -Compress
    if ($pathSemanticJson -cne $memorySemanticJson) {
        throw 'EvidencePath and EvidenceJson validation returned different semantic objects.'
    }
    $missingVisualRootRejected = $false
    try {
        & $validator -EvidencePath $passThruPath | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike '*requires VisualEvidenceRoot*') { throw }
        $missingVisualRootRejected = $true
    }
    if (-not $missingVisualRootRejected) {
        throw 'Complete evidence validation accepted a missing VisualEvidenceRoot.'
    }
    foreach ($invalidJson in '{', '{"schema_version":3,"schema_version":3}') {
        try {
            & $validator -EvidenceJson $invalidJson -Draft | Out-Null
        }
        catch {
            if ($_.Exception.Message -notlike '*Evidence is not valid JSON*') { throw }
            continue
        }
        throw 'EvidenceJson accepted invalid or duplicate JSON.'
    }
    Assert-ValidatorPasses `
        -Evidence $complete `
        -Name 'valid-complete' `
        -ForbiddenOutput 'HDD-unavailable limitation'

    Assert-ValidatorPasses `
        -Evidence $complete `
        -Name 'valid-complete-with-visual-root' `
        -VisualEvidenceRoot $visualRoot

    $wrongVisualDimensions = Copy-Evidence $complete
    $wrongVisualDimensions.visual_captures[0].image.pixel_width = 2
    Assert-ValidatorFails `
        -Evidence $wrongVisualDimensions `
        -Name 'visual-root-dimension-mismatch' `
        -ExpectedFragment 'PNG dimensions do not match' `
        -VisualEvidenceRoot $visualRoot

    [IO.File]::AppendAllText(
        (Join-Path $visualRoot $complete.visual_captures[0].image.filename),
        'tampered'
    )
    Assert-ValidatorFails `
        -Evidence $complete `
        -Name 'visual-root-hash-mismatch' `
        -ExpectedFragment 'image SHA-256 does not match VisualEvidenceRoot bytes' `
        -VisualEvidenceRoot $visualRoot
    Write-VisualEvidenceFiles -Evidence $complete -Root $visualRoot

    $missingVisualCell = Copy-Evidence $complete
    $missingVisualCell.visual_captures = @(
        $missingVisualCell.visual_captures |
            Where-Object { $_.ui_target -ne 'ui|Windows 11|300|high-contrast' }
    )
    Assert-ValidatorFails `
        -Evidence $missingVisualCell `
        -Name 'missing-main-workbench-capture' `
        -ExpectedFragment 'missing a main-workbench visual capture'

    $wrongVisualExecutable = Copy-Evidence $complete
    $wrongVisualExecutable.visual_captures[0].executable_sha256 = 'b' * 64
    Assert-ValidatorFails `
        -Evidence $wrongVisualExecutable `
        -Name 'wrong-visual-executable' `
        -ExpectedFragment 'must match artifact.sha256'

    $wrongVisualAppearance = Copy-Evidence $complete
    $wrongVisualAppearance.visual_captures[1].appearance = 'dark'
    Assert-ValidatorFails `
        -Evidence $wrongVisualAppearance `
        -Name 'wrong-high-contrast-appearance' `
        -ExpectedFragment 'appearance does not match its UI contrast target'

    $missingVisualSurface = Copy-Evidence $complete
    $missingVisualSurface.visual_captures = @(
        $missingVisualSurface.visual_captures |
            Where-Object { $_.surface -ne 'recovery-window' }
    )
    Assert-ValidatorFails `
        -Evidence $missingVisualSurface `
        -Name 'missing-visual-surface' `
        -ExpectedFragment 'missing visual surface coverage: recovery-window'

    $duplicateVisualFilename = Copy-Evidence $complete
    $duplicateVisualFilename.visual_captures[1].image.filename =
        $duplicateVisualFilename.visual_captures[0].image.filename
    Assert-ValidatorFails `
        -Evidence $duplicateVisualFilename `
        -Name 'duplicate-visual-filename' `
        -ExpectedFragment 'Duplicate visual capture filename'

    $reservedVisualFilename = Copy-Evidence $complete
    $reservedVisualFilename.visual_captures[0].image.filename = 'CON.png'
    Assert-ValidatorFails `
        -Evidence $reservedVisualFilename `
        -Name 'reserved-visual-filename' `
        -ExpectedFragment 'must not use a reserved Windows device name'

    foreach ($filesystem in 'refs', 'exfat', 'other') {
        $draftFilesystem = Copy-Evidence $complete
        $draftFilesystem.benchmarks[0].filesystem = $filesystem
        Assert-ValidatorPasses `
            -Evidence $draftFilesystem `
            -Name "valid-draft-$filesystem-filesystem" `
            -Draft

        Assert-ValidatorFails `
            -Evidence $draftFilesystem `
            -Name "complete-$filesystem-filesystem" `
            -ExpectedFragment 'requires NTFS for every benchmark row'
    }

    $invalidFilesystem = Copy-Evidence $complete
    $invalidFilesystem.benchmarks[0].filesystem = 'ext4'
    Assert-ValidatorFails `
        -Evidence $invalidFilesystem `
        -Name 'invalid-filesystem' `
        -ExpectedFragment 'filesystem must be one of' `
        -Draft

    $missingFilesystem = Copy-Evidence $complete
    $missingFilesystem.benchmarks[0].PSObject.Properties.Remove('filesystem')
    Assert-ValidatorFails `
        -Evidence $missingFilesystem `
        -Name 'missing-filesystem' `
        -ExpectedFragment 'missing required field: filesystem' `
        -Draft

    $schemaV1 = Copy-Evidence $complete
    $schemaV1.schema_version = 1
    Assert-ValidatorFails `
        -Evidence $schemaV1 `
        -Name 'schema-v1' `
        -ExpectedFragment 'schema_version must be 3'

    $hddUnavailable = New-HddUnavailableEvidence -CompleteEvidence $complete
    Assert-ValidatorPasses `
        -Evidence $hddUnavailable `
        -Name 'valid-complete-hdd-unavailable' `
        -ExpectedOutput 'complete release-gate with HDD-unavailable limitation'

    $partialHdd = Copy-Evidence $complete
    $partialHdd.benchmarks = @(
        $partialHdd.benchmarks |
            Where-Object { $_.media -ne 'hdd' -or $_.count -ne 10000 }
    )
    $partialHdd.unexecuted += [pscustomobject]@{
        id = 'hdd-10000-unavailable'
        target = 'benchmark|hdd|10000'
        reason_code = 'hardware-unavailable'
    }
    Assert-ValidatorFails `
        -Evidence $partialHdd `
        -Name 'partial-hdd-complete' `
        -ExpectedFragment 'all three HDD benchmark rows or no HDD benchmark rows'
    Assert-ValidatorPasses -Evidence $partialHdd -Name 'partial-hdd-draft' -Draft

    $mixedHdd = Copy-Evidence $complete
    $mixedHdd.unexecuted += [pscustomobject]@{
        id = 'hdd-100-unavailable'
        target = 'benchmark|hdd|100'
        reason_code = 'hardware-unavailable'
    }
    Assert-ValidatorFails `
        -Evidence $mixedHdd `
        -Name 'mixed-hdd-rows-and-reasons' `
        -ExpectedFragment 'Unexecuted reason is not referenced'

    $uncleanHdd = Copy-Evidence $complete
    $uncleanHdd.benchmarks |
        Where-Object { $_.media -eq 'hdd' -and $_.count -eq 1000 } |
        ForEach-Object { $_.cleanup_observation = 'residue-found' }
    Assert-ValidatorFails `
        -Evidence $uncleanHdd `
        -Name 'unclean-hdd-complete' `
        -ExpectedFragment 'requires clean benchmark cleanup observations'

    $missingHddReason = New-HddUnavailableEvidence -CompleteEvidence $complete
    $missingHddReason.unexecuted = @(
        $missingHddReason.unexecuted |
            Where-Object { $_.target -ne 'benchmark|hdd|10000' }
    )
    Assert-ValidatorFails `
        -Evidence $missingHddReason `
        -Name 'missing-hdd-unavailable-reason' `
        -ExpectedFragment 'must explain unavailable HDD benchmark target'

    $wrongHddReason = New-HddUnavailableEvidence -CompleteEvidence $complete
    $wrongHddReason.unexecuted |
        Where-Object { $_.target -eq 'benchmark|hdd|1000' } |
        ForEach-Object { $_.reason_code = 'environment-unavailable' }
    Assert-ValidatorFails `
        -Evidence $wrongHddReason `
        -Name 'non-hardware-hdd-unavailable-reason' `
        -ExpectedFragment 'must use reason_code hardware-unavailable'

    $missingSsd = Copy-Evidence $hddUnavailable
    $missingSsd.benchmarks = @(
        $missingSsd.benchmarks |
            Where-Object { $_.media -ne 'ssd' -or $_.count -ne 10000 }
    )
    $missingSsd.unexecuted += [pscustomobject]@{
        id = 'ssd-10000-unavailable'
        target = 'benchmark|ssd|10000'
        reason_code = 'hardware-unavailable'
    }
    Assert-ValidatorFails `
        -Evidence $missingSsd `
        -Name 'ssd-unavailable-is-not-complete' `
        -ExpectedFragment 'missing SSD benchmark target'

    $uiStatusMismatch = Copy-Evidence $complete
    $uiStatusMismatch.ui_matrix[0].observation_code = 'layout-defect'
    Assert-SchemaRejects -Evidence $uiStatusMismatch -Name 'schema-ui-status-code-mismatch'

    $scenarioStatusMismatch = Copy-Evidence $complete
    $scenarioStatusMismatch.scenarios[0].observation_code = 'interaction-defect'
    Assert-SchemaRejects `
        -Evidence $scenarioStatusMismatch `
        -Name 'schema-scenario-status-code-mismatch'

    $durabilityStatusMismatch = Copy-Evidence $complete
    $durabilityStatusMismatch.durability_trials[0].observation_code = 'recovery-defect'
    Assert-SchemaRejects `
        -Evidence $durabilityStatusMismatch `
        -Name 'schema-durability-status-code-mismatch'

    $localBuild = Copy-Evidence $complete
    $localBuild.artifact.origin = 'local-build'
    $localBuild.artifact.PSObject.Properties.Remove('workflow_run')
    Assert-ValidatorPasses -Evidence $localBuild -Name 'valid-local-build'

    $storageFaultAlternative = Copy-Evidence $complete
    $storageFaultAlternative.durability_trials[1].kind = 'storage-fault'
    $storageFaultAlternative.unexecuted[1].id = 'vm-reset-deferred'
    $storageFaultAlternative.unexecuted[1].target = 'durability|vm-hard-reset'
    $storageFaultAlternative.unexecuted[1].reason_code = 'environment-unavailable'
    Assert-ValidatorPasses -Evidence $storageFaultAlternative -Name 'valid-storage-fault-alternative'

    $draft = Copy-Evidence $complete
    $draft.ui_matrix = @($draft.ui_matrix | Select-Object -SkipLast 1)
    $draft.visual_captures = @()
    $draft.scenarios[0].status = 'not-run'
    $draft.scenarios[0].observation_code = 'not-executed'
    $draft.scenarios[0] | Add-Member -NotePropertyName unexecuted_id -NotePropertyValue 'keyboard-deferred'
    $draft.unexecuted = @(
        [pscustomobject]@{
            id = 'ui-cell-deferred'
            target = 'ui|Windows 11|300|high-contrast'
            reason_code = 'environment-unavailable'
        },
        [pscustomobject]@{
            id = 'keyboard-deferred'
            target = 'scenario|Windows 10|keyboard-only'
            reason_code = 'scheduled-later'
        },
        $complete.unexecuted[0],
        $complete.unexecuted[1]
    )
    Assert-ValidatorPasses -Evidence $draft -Name 'valid-draft' -Draft

    $zeroContextDraft = Copy-Evidence $complete
    $zeroContextDraft.operator_context = @()
    $zeroContextDraft.visual_captures = @()
    $zeroContextDraft.unexecuted = @()
    $rowIndex = 0
    foreach ($row in $zeroContextDraft.ui_matrix) {
        $id = "ui-not-run-$rowIndex"
        $row.status = 'not-run'
        $row.observation_code = 'not-executed'
        $row | Add-Member -NotePropertyName unexecuted_id -NotePropertyValue $id
        $zeroContextDraft.unexecuted += [pscustomobject]@{
            id = $id
            target = "ui|$($row.windows_product)|$($row.dpi_percent)|$($row.contrast)"
            reason_code = 'scheduled-later'
        }
        $rowIndex++
    }
    $rowIndex = 0
    foreach ($row in $zeroContextDraft.scenarios) {
        $id = "scenario-not-run-$rowIndex"
        $row.status = 'not-run'
        $row.observation_code = 'not-executed'
        $row.PSObject.Properties.Remove('accessibility_tool')
        $row | Add-Member -NotePropertyName unexecuted_id -NotePropertyValue $id
        $zeroContextDraft.unexecuted += [pscustomobject]@{
            id = $id
            target = "scenario|$($row.windows_product)|$($row.kind)"
            reason_code = 'scheduled-later'
        }
        $rowIndex++
    }
    $zeroContextDraft.benchmarks = @()
    foreach ($media in 'ssd', 'hdd') {
        foreach ($count in 100, 1000, 10000) {
            $zeroContextDraft.unexecuted += [pscustomobject]@{
                id = "benchmark-$media-$count-not-run"
                target = "benchmark|$media|$count"
                reason_code = 'scheduled-later'
            }
        }
    }
    $rowIndex = 0
    foreach ($row in $zeroContextDraft.durability_trials) {
        $id = "durability-not-run-$rowIndex"
        $row.status = 'not-run'
        $row.observation_code = 'not-executed'
        $row.PSObject.Properties.Remove('authorization')
        $row | Add-Member -NotePropertyName unexecuted_id -NotePropertyValue $id
        $zeroContextDraft.unexecuted += [pscustomobject]@{
            id = $id
            target = "durability|$($row.kind)"
            reason_code = 'scheduled-later'
        }
        $rowIndex++
    }
    $zeroContextDraft.unexecuted += @(
        [pscustomobject]@{
            id = 'durability-physical-power-loss-not-run'
            target = 'durability|physical-power-loss'
            reason_code = 'scheduled-later'
        },
        [pscustomobject]@{
            id = 'durability-storage-fault-not-run'
            target = 'durability|storage-fault'
            reason_code = 'scheduled-later'
        }
    )
    Assert-ValidatorPasses `
        -Evidence $zeroContextDraft `
        -Name 'zero-context-not-run-draft' `
        -Draft

    $zeroContextUiExecuted = Copy-Evidence $zeroContextDraft
    $zeroContextUiExecuted.ui_matrix[0].status = 'pass'
    $zeroContextUiExecuted.ui_matrix[0].observation_code = 'layout-verified'
    $zeroContextUiExecuted.ui_matrix[0].PSObject.Properties.Remove('unexecuted_id')
    $zeroContextUiExecuted.unexecuted = @(
        $zeroContextUiExecuted.unexecuted |
            Where-Object { $_.target -ne 'ui|Windows 10|100|normal' }
    )
    Assert-ValidatorFails `
        -Evidence $zeroContextUiExecuted `
        -Name 'zero-context-executed-ui-draft' `
        -ExpectedFragment 'may omit operator_context only when no acceptance rows are executed' `
        -Draft

    $zeroContextScenarioExecuted = Copy-Evidence $zeroContextDraft
    $zeroContextScenarioExecuted.scenarios[0].status = 'pass'
    $zeroContextScenarioExecuted.scenarios[0].observation_code = 'interaction-verified'
    $zeroContextScenarioExecuted.scenarios[0].PSObject.Properties.Remove('unexecuted_id')
    $zeroContextScenarioExecuted.unexecuted = @(
        $zeroContextScenarioExecuted.unexecuted |
            Where-Object { $_.target -ne 'scenario|Windows 10|keyboard-only' }
    )
    Assert-ValidatorFails `
        -Evidence $zeroContextScenarioExecuted `
        -Name 'zero-context-executed-scenario-draft' `
        -ExpectedFragment 'may omit operator_context only when no acceptance rows are executed' `
        -Draft

    $zeroContextBenchmarkExecuted = Copy-Evidence $zeroContextDraft
    $zeroContextBenchmarkExecuted.benchmarks = @(Copy-Evidence $complete.benchmarks[0])
    $zeroContextBenchmarkExecuted.unexecuted = @(
        $zeroContextBenchmarkExecuted.unexecuted |
            Where-Object { $_.target -ne 'benchmark|ssd|100' }
    )
    Assert-ValidatorFails `
        -Evidence $zeroContextBenchmarkExecuted `
        -Name 'zero-context-executed-benchmark-draft' `
        -ExpectedFragment 'may omit operator_context only when no acceptance rows are executed' `
        -Draft

    $zeroContextDurabilityExecuted = Copy-Evidence $zeroContextDraft
    $zeroContextDurabilityExecuted.durability_trials[0].status = 'pass'
    $zeroContextDurabilityExecuted.durability_trials[0].observation_code = 'recovery-verified'
    $zeroContextDurabilityExecuted.durability_trials[0].PSObject.Properties.Remove('unexecuted_id')
    $zeroContextDurabilityExecuted.unexecuted = @(
        $zeroContextDurabilityExecuted.unexecuted |
            Where-Object { $_.target -ne 'durability|process-crash' }
    )
    Assert-ValidatorFails `
        -Evidence $zeroContextDurabilityExecuted `
        -Name 'zero-context-executed-durability-draft' `
        -ExpectedFragment 'may omit operator_context only when no acceptance rows are executed' `
        -Draft

    $zeroContextComplete = Copy-Evidence $complete
    $zeroContextComplete.operator_context = @()
    Assert-ValidatorFails `
        -Evidence $zeroContextComplete `
        -Name 'zero-context-complete' `
        -ExpectedFragment 'Complete evidence requires operator context for Windows 10'

    $arm64Context = Copy-Evidence $complete
    foreach ($context in $arm64Context.operator_context) {
        $context.architecture = 'arm64'
    }
    Assert-ValidatorFails `
        -Evidence $arm64Context `
        -Name 'arm64-context-complete' `
        -ExpectedFragment 'architecture must be one of: x64'

    $missingUiProductContext = Copy-Evidence $zeroContextDraft
    $missingUiProductContext.operator_context = @($complete.operator_context[0])
    $missingUiProductContext.ui_matrix[12].status = 'pass'
    $missingUiProductContext.ui_matrix[12].observation_code = 'layout-verified'
    $missingUiProductContext.ui_matrix[12].PSObject.Properties.Remove('unexecuted_id')
    $missingUiProductContext.unexecuted = @(
        $missingUiProductContext.unexecuted |
            Where-Object { $_.target -ne 'ui|Windows 11|100|normal' }
    )
    Assert-ValidatorFails `
        -Evidence $missingUiProductContext `
        -Name 'executed-ui-missing-product-context' `
        -ExpectedFragment 'has no matching operator_context for Windows 11' `
        -Draft

    $missingScenarioProductContext = Copy-Evidence $zeroContextDraft
    $missingScenarioProductContext.operator_context = @($complete.operator_context[0])
    $missingScenarioProductContext.scenarios[10].status = 'pass'
    $missingScenarioProductContext.scenarios[10].observation_code = 'interaction-verified'
    $missingScenarioProductContext.scenarios[10].PSObject.Properties.Remove('unexecuted_id')
    $missingScenarioProductContext.unexecuted = @(
        $missingScenarioProductContext.unexecuted |
            Where-Object { $_.target -ne 'scenario|Windows 11|keyboard-only' }
    )
    Assert-ValidatorFails `
        -Evidence $missingScenarioProductContext `
        -Name 'executed-scenario-missing-product-context' `
        -ExpectedFragment 'has no matching operator_context for Windows 11' `
        -Draft

    $missingCell = Copy-Evidence $complete
    $missingCell.ui_matrix = @($missingCell.ui_matrix | Select-Object -SkipLast 1)
    $missingCell.visual_captures = @(
        $missingCell.visual_captures |
            Where-Object { $_.ui_target -ne 'ui|Windows 11|300|high-contrast' }
    )
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
    $pathLeak.benchmarks[0].storage_model = 'C:\Users\operator\Desktop\acceptance.png'
    Assert-ValidatorFails `
        -Evidence $pathLeak `
        -Name 'path-leakage' `
        -ExpectedFragment 'prohibited absolute or profile path'

    foreach ($leakCase in @(
            @{ Name = 'relative-path-leakage'; Value = '.\screenshots\acceptance.png'; Expected = 'model family using only safe characters' },
            @{ Name = 'posix-path-leakage'; Value = '/tmp/private/acceptance.png'; Expected = 'model family using only safe characters' },
            @{ Name = 'email-leakage'; Value = 'operator@example.com'; Expected = 'model family using only safe characters' },
            @{ Name = 'ip-address-leakage'; Value = '192.0.2.10'; Expected = 'prohibited IP address' }
        )) {
        $constrainedTextLeak = Copy-Evidence $complete
        $constrainedTextLeak.benchmarks[0].storage_model = $leakCase.Value
        Assert-ValidatorFails `
            -Evidence $constrainedTextLeak `
            -Name $leakCase.Name `
            -ExpectedFragment $leakCase.Expected
    }

    $prefixedIpModel = Copy-Evidence $complete
    $prefixedIpModel.benchmarks[0].storage_model = 'Drive 192.0.2.10'
    Assert-ValidatorFails `
        -Evidence $prefixedIpModel `
        -Name 'prefixed-ip-model-leakage' `
        -ExpectedFragment 'prohibited IP address'

    $prefixedIpTool = Copy-Evidence $complete
    $prefixedIpTool.scenarios[1].accessibility_tool.name = 'Narrator 192.0.2.10'
    Assert-ValidatorFails `
        -Evidence $prefixedIpTool `
        -Name 'prefixed-ip-tool-leakage' `
        -ExpectedFragment 'prohibited IP address'

    $usernameField = Copy-Evidence $complete
    $usernameField.operator_context[0] | Add-Member -NotePropertyName username -NotePropertyValue 'operator'
    Assert-ValidatorFails `
        -Evidence $usernameField `
        -Name 'username-field' `
        -ExpectedFragment 'prohibited identity or volume field'

    $hostnameValue = Copy-Evidence $complete
    $hostnameValue.benchmarks[0].storage_model = 'hostname=acceptance-machine'
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
    $notRunWithoutReason.ui_matrix[0].observation_code = 'not-executed'
    $notRunWithoutReason.visual_captures = @(
        $notRunWithoutReason.visual_captures |
            Where-Object { $_.ui_target -ne 'ui|Windows 10|100|normal' }
    )
    Assert-ValidatorFails `
        -Evidence $notRunWithoutReason `
        -Name 'not-run-without-reason' `
        -ExpectedFragment 'must reference unexecuted_id' `
        -Draft

    $physicalPowerOnly = Copy-Evidence $complete
    $physicalPowerOnly.durability_trials[1].kind = 'physical-power-loss'
    $physicalPowerOnly.unexecuted = @(
        [pscustomobject]@{
            id = 'vm-reset-deferred'
            target = 'durability|vm-hard-reset'
            reason_code = 'environment-unavailable'
        },
        $complete.unexecuted[1]
    )
    Assert-ValidatorFails `
        -Evidence $physicalPowerOnly `
        -Name 'physical-power-is-not-disruptive-gate' `
        -ExpectedFragment 'VM hard-reset or storage-fault trial'

    $equivalenceClaim = Copy-Evidence $complete
    $equivalenceClaim.durability_trials[0] | Add-Member `
        -NotePropertyName equivalence_claim `
        -NotePropertyValue 'physical-power-loss'
    Assert-ValidatorFails `
        -Evidence $equivalenceClaim `
        -Name 'durability-equivalence-claim' `
        -ExpectedFragment 'unsupported field: equivalence_claim'

    $missingAuthorization = Copy-Evidence $complete
    $missingAuthorization.durability_trials[1].PSObject.Properties.Remove('authorization')
    Assert-ValidatorFails `
        -Evidence $missingAuthorization `
        -Name 'missing-disruptive-authorization' `
        -ExpectedFragment 'requires operator-authorized scope'

    $uppercaseEnum = Copy-Evidence $complete
    $uppercaseEnum.artifact.origin = 'ACTIONS-HANDOFF'
    Assert-ValidatorFails `
        -Evidence $uppercaseEnum `
        -Name 'uppercase-enum' `
        -ExpectedFragment 'artifact.origin must be one of'

    $uppercaseAuthorization = Copy-Evidence $complete
    $uppercaseAuthorization.durability_trials[1].authorization = 'OPERATOR-AUTHORIZED'
    Assert-ValidatorFails `
        -Evidence $uppercaseAuthorization `
        -Name 'uppercase-authorization' `
        -ExpectedFragment 'requires operator-authorized scope'

    $stringSchemaVersion = Copy-Evidence $complete
    $stringSchemaVersion.schema_version = '3'
    Assert-ValidatorFails `
        -Evidence $stringSchemaVersion `
        -Name 'string-schema-version' `
        -ExpectedFragment 'schema_version must be'

    $stringDpi = Copy-Evidence $complete
    $stringDpi.ui_matrix[0].dpi_percent = '100'
    Assert-ValidatorFails `
        -Evidence $stringDpi `
        -Name 'string-dpi' `
        -ExpectedFragment 'dpi_percent must be one of'

    $stringCount = Copy-Evidence $complete
    $stringCount.benchmarks[0].count = '100'
    Assert-ValidatorFails `
        -Evidence $stringCount `
        -Name 'string-benchmark-count' `
        -ExpectedFragment 'count must be one of'

    Write-Host 'Windows acceptance evidence validator tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
