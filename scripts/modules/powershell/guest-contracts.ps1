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
        if ($manifest.lane -cne 'candidate-gui-only') {
            throw 'bundle.json candidate lane is invalid.'
        }
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
    else {
        Assert-ExactProperties -Value $manifest -Names @(
            'schema_version'
            'source_sha'
            'source_state'
            'target'
            'cargo_lock_sha256'
            'test_binaries'
            'application'
            'runner'
        ) -Label 'bundle.json'
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

    if ($candidateLane) {
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
            lane = 'candidate-gui-only'
            product_source_sha = $manifest.product.source_sha
            product_source_state = $manifest.product.source_state
            application = $application
            harness_source_sha = $manifest.harness.source_sha
            harness_source_state = $manifest.harness.source_state
            runner = $runner
            observers = $manifest.harness.observers
            validators = $manifest.harness.validators
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
