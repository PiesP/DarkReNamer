function Assert-ExactProperties {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string[]] $Names,

        [Parameter(Mandatory)]
        [string] $Label
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if ($actual.Count -ne $expected.Count) {
        throw "$Label has unexpected fields."
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($actual[$index] -cne $expected[$index]) {
            throw "$Label has unexpected fields."
        }
    }
}
function Assert-UniqueJsonProperties {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)][string] $Location
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $observed.Add($property.Name)) {
                throw "$Location contains a duplicate field: $($property.Name)."
            }
            Assert-UniqueJsonProperties -Element $property.Value -Location "$Location.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-UniqueJsonProperties -Element $item -Location "$Location[$index]"
            $index++
        }
    }
}
function Read-UniqueJsonObject {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-OrdinaryFile -Path $Path -Label $Label
    if ((Get-Item -LiteralPath $Path -Force).Length -gt 4MB) {
        throw "$Label is too large."
    }
    $text = Get-Content -LiteralPath $Path -Raw
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($text)
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw "$Label must be a JSON object."
        }
        Assert-UniqueJsonProperties -Element $document.RootElement -Location $Label
        $text | ConvertFrom-Json
    }
    catch {
        throw "$Label is not valid unique-key JSON: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}
function Assert-SafeLeafName {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string] $Pattern
    )

    if ($Value -isnot [string] -or
        $Value.Length -gt 160 -or
        $Value -notmatch $Pattern -or
        [IO.Path]::GetFileName($Value) -cne $Value) {
        throw "$Label must be a safe leaf filename."
    }
}
function Assert-Sha256 {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Label
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Label must be a lowercase SHA-256 digest."
    }
}
function Assert-OrdinaryFile {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing."
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a reparse point."
    }
}
function Get-LowerSha256 {
    param([Parameter(Mandatory)][string] $Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-LowerTextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}
function Resolve-VerifiedBundle {
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $InvokedScriptPath
    )

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be an absolute directory.'
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'BundleRoot must be an existing directory.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BundleRoot must not be a reparse point.'
    }
    $resolvedRoot = $rootItem.FullName

    $manifestPath = Join-Path $resolvedRoot 'bundle.json'
    Assert-OrdinaryFile -Path $manifestPath -Label 'bundle.json'
    if ((Get-Item -LiteralPath $manifestPath).Length -gt 1MB) {
        throw 'bundle.json is too large.'
    }
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifestText.IndexOf([char]0) -ge 0) {
        throw 'bundle.json contains NUL.'
    }
    $manifestDocument = $null
    try {
        $manifestDocument = [Text.Json.JsonDocument]::Parse($manifestText)
        Assert-UniqueJsonProperties -Element $manifestDocument.RootElement -Location 'bundle.json'
        $manifest = $manifestText | ConvertFrom-Json
    }
    catch {
        throw "bundle.json is not valid unique-key JSON: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $manifestDocument) {
            $manifestDocument.Dispose()
        }
    }
    if ($null -eq $manifest) {
        throw 'bundle.json must contain an object.'
    }

    $candidateLane = $manifest.schema_version -eq 2
    $focusedPreservedLane = $candidateLane -and
        $manifest.lane -ceq 'focused-preserved-source-built-product-v1'
    if ($candidateLane) {
        if ($manifest.schema_version -isnot [int] -and $manifest.schema_version -isnot [long]) {
            throw 'bundle.json candidate schema_version must be the JSON integer 2.'
        }
        Assert-ExactProperties -Value $manifest -Names @(
            'schema_version'
            'lane'
            'target'
            'product'
            'harness'
            'test_binaries'
        ) -Label 'bundle.json'
        if ($manifest.lane -cnotin @('candidate-gui-only',
                'focused-preserved-source-built-product-v1')) {
            throw 'bundle.json candidate lane is invalid.'
        }
        if ($focusedPreservedLane) {
            Assert-ExactProperties -Value $manifest.product -Names @(
                'source_sha','source_tree','source_state','application','provenance'
            ) -Label 'bundle.json focused product'
            Assert-ExactProperties -Value $manifest.product.provenance -Names @(
                'kind','reference_source_sha','original_bundle_manifest',
                'non_tooling_entries_sha256','non_tooling_entries_count','cargo_lock_sha256'
            ) -Label 'bundle.json focused product provenance'
            Assert-ExactProperties -Value $manifest.harness -Names @(
                'source_sha','source_tree','source_state','launcher','builder','controller',
                'runner','observers','tooling_record'
            ) -Label 'bundle.json focused harness'
            Assert-ExactProperties -Value $manifest.harness.observers -Names @('ui') `
                -Label 'bundle.json focused observers'
            if ($manifest.product.source_sha -cne '8248c73859e3a3ff0e524fd9448acfe965fa3f68' -or
                $manifest.product.provenance.reference_source_sha -cne
                    'b152761010b16ef74e2a3765241a253778b88e0b' -or
                $manifest.product.provenance.kind -cne 'preserved-source-built-bundle' -or
                $manifest.product.provenance.non_tooling_entries_sha256 -cne
                    '7c4fc53698413bbab601629a5a56c1129ecd96aaac4a98af09530f87b4a25735' -or
                $manifest.product.provenance.non_tooling_entries_count -ne 104 -or
                $manifest.product.application.sha256 -cne
                    '06c5511e042714f5a343e541856f2dbdc3850d5d60eeb62c3c36c2dacfef2f0f' -or
                $manifest.product.source_state -cne 'clean' -or
                $manifest.harness.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
                $manifest.harness.source_state -cne 'clean' -or
                $manifest.product.source_tree -cnotmatch '^[0-9a-f]{40}$' -or
                $manifest.harness.source_tree -cnotmatch '^[0-9a-f]{40}$' -or
                @($manifest.test_binaries).Count -ne 0) {
                throw 'bundle.json focused preserved product identity is invalid.'
            }
            $application = $manifest.product.application
            $runner = $manifest.harness.runner
            $testBinaryRows = @()
            $candidateArtifacts = @(
                $manifest.product.provenance.original_bundle_manifest,
                $manifest.harness.launcher, $manifest.harness.builder,
                $manifest.harness.controller, $manifest.harness.observers.ui,
                $manifest.harness.tooling_record,
                [pscustomobject]@{ file = 'Cargo.lock'; sha256 = $manifest.product.provenance.cargo_lock_sha256 }
            )
        }
        else {
        Assert-ExactProperties -Value $manifest.product -Names @(
            'source_sha'
            'source_state'
            'candidate'
            'application'
            'provenance'
        ) -Label 'bundle.json product'
        Assert-ExactProperties -Value $manifest.product.candidate -Names @(
            'workflow_run'
            'run_attempt'
            'artifact_id'
            'artifact_name'
            'origin_authentication'
        ) -Label 'bundle.json product candidate'
        Assert-ExactProperties -Value $manifest.product.provenance -Names @(
            'release_handoff'
            'run_metadata'
            'artifact_metadata'
        ) -Label 'bundle.json product provenance'
        Assert-ExactProperties -Value $manifest.harness -Names @(
            'source_sha'
            'source_state'
            'launcher'
            'controller'
            'runner'
            'observers'
            'validators'
        ) -Label 'bundle.json harness'
        Assert-ExactProperties -Value $manifest.harness.observers -Names @(
            'ui'
            'recovery'
        ) -Label 'bundle.json harness observers'
        Assert-ExactProperties -Value $manifest.harness.validators -Names @(
            'release_handoff'
            'candidate_metadata'
            'binary_measurement'
        ) -Label 'bundle.json harness validators'
        foreach ($binding in @($manifest.product, $manifest.harness)) {
            if ($binding.source_sha -isnot [string] -or $binding.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
                $binding.source_state -cne 'clean') {
                throw 'bundle.json source binding is invalid.'
            }
        }
        foreach ($name in @('workflow_run', 'run_attempt', 'artifact_id')) {
            if ($manifest.product.candidate.$name -isnot [string] -or
                $manifest.product.candidate.$name -cnotmatch '^[1-9][0-9]*$') {
                throw "bundle.json product candidate $name is invalid."
            }
        }
        $expectedArtifactName = "DarkReNamer-dry-run-$($manifest.product.candidate.workflow_run)-$($manifest.product.candidate.run_attempt)-windows"
        if ($manifest.product.candidate.artifact_name -cne $expectedArtifactName) {
            throw 'bundle.json product candidate artifact name is invalid.'
        }
        if ($manifest.product.candidate.origin_authentication -cne 'pending-hosted') {
            throw 'bundle.json product candidate origin authentication scope is invalid.'
        }
        if (@($manifest.test_binaries).Count -ne 0) {
            throw 'bundle.json candidate GUI-only lane must not contain test binaries.'
        }
        $application = $manifest.product.application
        $runner = $manifest.harness.runner
        $testBinaryRows = @()
        $candidateArtifacts = @(
            @($manifest.product.provenance.PSObject.Properties | ForEach-Object Value) +
            @($manifest.harness.launcher, $manifest.harness.controller) +
            @($manifest.harness.observers.PSObject.Properties | ForEach-Object Value) +
            @($manifest.harness.validators.PSObject.Properties | ForEach-Object Value)
        )
        }
    }
    else {
        $diagnostic = $manifest.PSObject.Properties['diagnostic']
        Assert-ExactProperties -Value $manifest -Names (@(
            'schema_version'
            'source_sha'
            'source_state'
            'target'
            'cargo_lock_sha256'
            'test_binaries'
            'application'
            'runner'
        ) + @(if ($null -ne $diagnostic) { 'diagnostic' })) -Label 'bundle.json'
        if (($manifest.schema_version -isnot [int] -and $manifest.schema_version -isnot [long]) -or
            $manifest.schema_version -ne 1) {
            throw 'bundle.json schema_version must be 1 or the exact candidate schema 2.'
        }
        if ($manifest.source_sha -isnot [string] -or $manifest.source_sha -cnotmatch '^[0-9a-f]{40}$') {
            throw 'bundle.json source_sha must be a lowercase full Git SHA.'
        }
        if ($manifest.source_state -isnot [string] -or
            $manifest.source_state -cne 'clean' -and $manifest.source_state -cne 'dirty') {
            throw 'bundle.json source_state is invalid.'
        }
        Assert-Sha256 -Value $manifest.cargo_lock_sha256 -Label 'bundle.json cargo_lock_sha256'
        if ($manifest.test_binaries -isnot [array] -or $manifest.test_binaries.Count -le 0) {
            throw 'bundle.json test_binaries must be a non-empty array.'
        }
        $application = $manifest.application
        $runner = $manifest.runner
        $testBinaryRows = @($manifest.test_binaries)
        if ($null -ne $diagnostic) {
            if ($diagnostic.Value.kind -ceq 'profile-refresh-stages') {
                Assert-ExactProperties -Value $diagnostic.Value -Names @(
                    'kind', 'test_profile', 'test_name', 'orders') -Label 'bundle.json diagnostic'
                if ($diagnostic.Value.test_profile -cne 'release' -or
                    $diagnostic.Value.test_name -cne 'windows::list_view::native_tests::profile_refresh_stages' -or
                    (@($diagnostic.Value.orders) -join ',') -cne 'hidden-visible,visible-hidden') {
                    throw 'bundle.json fixed refresh diagnostic is invalid.'
                }
            }
            elseif ($diagnostic.Value.kind -ceq 'focused-icon-tests') {
                $selectedCase = $diagnostic.Value.PSObject.Properties['test_name']
                Assert-ExactProperties -Value $diagnostic.Value -Names (@(
                    'kind', 'test_profile', 'test_filter'
                ) + @(if ($null -ne $selectedCase) { 'test_name' } else { 'test_names' })) -Label 'bundle.json diagnostic'
                $fixedNames = @(
                    'windows::list_view::native_tests::icon_worker_bootstrap_and_miss_keep_ui_responsive',
                    'windows::list_view::native_tests::icon_worker_bounds_eviction_and_stale_results',
                    'windows::list_view::native_tests::icon_worker_close_and_forced_destroy_retire',
                    'windows::list_view::native_tests::icon_worker_failures_and_message_loop_retire'
                )
                $validNames = $true
                if ($null -eq $selectedCase) {
                    $validNames = $null -ne $diagnostic.Value.PSObject.Properties['test_names'] -and
                        $diagnostic.Value.test_names -is [array] -and
                        $diagnostic.Value.test_names.Count -eq $fixedNames.Count
                }
                if ($null -eq $selectedCase -and $validNames) {
                    for ($nameIndex = 0; $nameIndex -lt $fixedNames.Count; $nameIndex++) {
                        if ($diagnostic.Value.test_names[$nameIndex] -isnot [string] -or
                            $diagnostic.Value.test_names[$nameIndex] -cne $fixedNames[$nameIndex]) {
                            $validNames = $false
                            break
                        }
                    }
                }
                if ($diagnostic.Value.test_profile -cnotin @('debug', 'release') -or
                    $diagnostic.Value.test_filter -cne 'windows::list_view::native_tests::icon_worker_' -or
                    ($null -ne $selectedCase -and $selectedCase.Value -cnotin $fixedNames) -or
                    ($null -eq $selectedCase -and -not $validNames)) {
                    throw 'bundle.json fixed focused icon selection is invalid.'
                }
            }
            else { throw 'bundle.json diagnostic kind is invalid.' }
            if ($testBinaryRows.Count -ne 1 -or $testBinaryRows[0].name -cne 'darknamer_app') {
                throw 'bundle.json selected native tests require one app library binary.'
            }
        }
        $candidateArtifacts = @()
    }
    if ($manifest.target -isnot [string] -or $manifest.target -cne 'x86_64-pc-windows-msvc') {
        throw 'bundle.json target is invalid.'
    }
    Assert-ExactProperties -Value $application -Names @('file', 'sha256') -Label 'bundle.json application'
    Assert-ExactProperties -Value $runner -Names @('file', 'sha256') -Label 'bundle.json runner'
    Assert-SafeLeafName -Value $application.file -Label 'application file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.exe$'
    if ($application.file -cne 'DarkReNamer.exe') {
        throw 'bundle.json application file is invalid.'
    }
    Assert-Sha256 -Value $application.sha256 -Label 'application sha256'
    Assert-SafeLeafName -Value $runner.file -Label 'runner file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.ps1$'
    if ($runner.file -cne 'windows-vm-guest.ps1') {
        throw 'bundle.json runner file is invalid.'
    }
    Assert-Sha256 -Value $runner.sha256 -Label 'runner sha256'

    $leafNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $testNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $artifacts = [Collections.Generic.List[object]]::new()
    $testRows = [Collections.Generic.List[object]]::new()
    foreach ($binary in @($testBinaryRows)) {
        Assert-ExactProperties -Value $binary -Names @('name', 'file', 'sha256') -Label 'bundle.json test binary'
        if ($binary.name -isnot [string] -or $binary.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            throw 'A test binary name is invalid.'
        }
        if (-not $testNames.Add($binary.name)) {
            throw 'Test binary names must be unique.'
        }
        Assert-SafeLeafName -Value $binary.file -Label 'test binary file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.exe$'
        Assert-Sha256 -Value $binary.sha256 -Label 'test binary sha256'
        if (-not $leafNames.Add($binary.file)) {
            throw 'Artifact filenames must be unique.'
        }
        $testRows.Add([pscustomobject]@{
            name = $binary.name
            file = $binary.file
            sha256 = $binary.sha256
        })
        $artifacts.Add([pscustomobject]@{
            label = 'test binary'
            file = $binary.file
            sha256 = $binary.sha256
        })
    }
    foreach ($artifact in @($application, $runner) + $candidateArtifacts) {
        Assert-ExactProperties -Value $artifact -Names @('file', 'sha256') -Label 'bundle.json artifact'
        Assert-SafeLeafName -Value $artifact.file -Label 'artifact file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*$'
        Assert-Sha256 -Value $artifact.sha256 -Label 'artifact sha256'
        if (-not $leafNames.Add($artifact.file)) {
            throw 'Artifact filenames must be unique.'
        }
        $artifacts.Add([pscustomobject]@{
            label = 'manifest artifact'
            file = $artifact.file
            sha256 = $artifact.sha256
        })
    }

    $runnerPath = Join-Path $resolvedRoot $runner.file
    Assert-OrdinaryFile -Path $runnerPath -Label 'runner artifact'
    $actualScriptPath = (Get-Item -LiteralPath $InvokedScriptPath -Force).FullName
    if (-not [string]::Equals($runnerPath, $actualScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The invoked runner is not the bundled runner artifact.'
    }

    $verifiedHashes = @{}
    foreach ($artifact in $artifacts) {
        $artifactPath = Join-Path $resolvedRoot $artifact.file
        Assert-OrdinaryFile -Path $artifactPath -Label $artifact.label
        $actualHash = Get-LowerSha256 -Path $artifactPath
        if ($actualHash -cne $artifact.sha256) {
            throw "$($artifact.label) hash mismatch."
        }
        $verifiedHashes[$artifact.file] = $actualHash
    }

    if ($focusedPreservedLane) {
        if ($manifest.product.provenance.original_bundle_manifest.file -cne 'original-bundle.json' -or
            $manifest.product.provenance.original_bundle_manifest.sha256 -cne
                '23f42a2c2af9e7a9417e275e10b9415be46dc05a0ecf610527a89e632ec7f38e' -or
            $manifest.harness.launcher.file -cne 'run-gui-regression.py' -or
            $manifest.harness.builder.file -cne 'test-windows-vm.py' -or
            $manifest.harness.controller.file -cne 'run-windows-vm-tests.ps1' -or
            $manifest.harness.observers.ui.file -cne 'windows-vm-acceptance.ps1' -or
            $manifest.harness.tooling_record.file -cne 'tooling-record.json') {
            throw 'bundle.json focused retained provenance or harness filenames are invalid.'
        }
        $original = Read-UniqueJsonObject -Path (Join-Path $resolvedRoot 'original-bundle.json') `
            -Label 'original-bundle.json'
        if ($original.schema_version -ne 1 -or
            $original.source_sha -cne $manifest.product.source_sha -or
            $original.source_state -cne 'clean' -or
            $original.target -cne $manifest.target -or
            $original.application.file -cne $application.file -or
            $original.application.sha256 -cne $application.sha256 -or
            $original.cargo_lock_sha256 -cne $manifest.product.provenance.cargo_lock_sha256 -or
            @($original.test_binaries).Count -eq 0) {
            throw 'Focused retained original source-built manifest differs from product provenance.'
        }
    }
    if ($candidateLane -and -not $focusedPreservedLane) {
        $expectedFiles = [ordered]@{
            release_handoff = 'release-handoff.json'
            run_metadata = 'candidate-run.json'
            artifact_metadata = 'candidate-artifact.json'
        }
        foreach ($name in $expectedFiles.Keys) {
            if ($manifest.product.provenance.$name.file -cne $expectedFiles[$name]) {
                throw "bundle.json product provenance $name file is invalid."
            }
        }
        if ($manifest.harness.launcher.file -cne 'test-windows-vm.py' -or
            $manifest.harness.controller.file -cne 'run-windows-vm-tests.ps1') {
            throw 'bundle.json candidate harness filenames are invalid.'
        }
        $expectedObservers = [ordered]@{
            ui = 'windows-vm-acceptance.ps1'
            recovery = 'windows-vm-recovery-acceptance.ps1'
        }
        foreach ($name in $expectedObservers.Keys) {
            if ($manifest.harness.observers.$name.file -cne $expectedObservers[$name]) {
                throw "bundle.json candidate harness observer $name file is invalid."
            }
        }
        $expectedValidators = [ordered]@{
            release_handoff = 'validate-release-handoff.ps1'
            candidate_metadata = 'validate-release-candidate-metadata.ps1'
            binary_measurement = 'measure-windows-binary.ps1'
        }
        foreach ($name in $expectedValidators.Keys) {
            if ($manifest.harness.validators.$name.file -cne $expectedValidators[$name]) {
                throw "bundle.json candidate harness validator $name file is invalid."
            }
        }
        $handoff = Read-UniqueJsonObject `
            -Path (Join-Path $resolvedRoot 'release-handoff.json') `
            -Label 'release-handoff.json'
        if ($handoff.source_sha -cne $manifest.product.source_sha -or
            $handoff.workflow_run -cne $manifest.product.candidate.workflow_run -or
            $handoff.executable.filename -cne $application.file -or
            $handoff.executable.sha256 -cne $application.sha256) {
            throw 'Frozen release handoff metadata differs from the candidate identity.'
        }
        $runMetadata = Read-UniqueJsonObject `
            -Path (Join-Path $resolvedRoot 'candidate-run.json') `
            -Label 'candidate-run.json'
        $artifactMetadata = Read-UniqueJsonObject `
            -Path (Join-Path $resolvedRoot 'candidate-artifact.json') `
            -Label 'candidate-artifact.json'
        if ([string]$runMetadata.id -cne $manifest.product.candidate.workflow_run -or
            [string]$runMetadata.run_attempt -cne $manifest.product.candidate.run_attempt -or
            $runMetadata.head_sha -cne $manifest.product.source_sha -or
            [string]$artifactMetadata.id -cne $manifest.product.candidate.artifact_id -or
            $artifactMetadata.name -cne $manifest.product.candidate.artifact_name -or
            [string]$artifactMetadata.workflow_run.id -cne $manifest.product.candidate.workflow_run -or
            $artifactMetadata.workflow_run.head_sha -cne $manifest.product.source_sha) {
            throw 'Frozen GitHub metadata differs from the candidate identity.'
        }
    }

    $contract = if ($candidateLane) {
        [pscustomobject]@{
            lane = $manifest.lane
            product_source_sha = $manifest.product.source_sha
            product_source_state = $manifest.product.source_state
            application = $application
            harness_source_sha = $manifest.harness.source_sha
            harness_source_state = $manifest.harness.source_state
            runner = $runner
            observers = $manifest.harness.observers
            validators = if ($focusedPreservedLane) { $null } else { $manifest.harness.validators }
        }
    } else {
        [pscustomobject]@{
            lane = 'source-built-native'
            product_source_sha = $manifest.source_sha
            product_source_state = $manifest.source_state
            application = $application
            harness_source_sha = $manifest.source_sha
            harness_source_state = $manifest.source_state
            runner = $runner
            observers = $null
            validators = $null
        }
    }
    [pscustomobject]@{
        root = $resolvedRoot
        manifest = $manifest
        contract = $contract
        tests = $testRows.ToArray()
        hashes = $verifiedHashes
    }
}
