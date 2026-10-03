[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
$toolingScriptsRoot = $toolingTestPaths.ScriptsRoot

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $toolingScriptsRoot 'tests/support/windows-vm-module-loader.ps1')
. (Join-Path $toolingScriptsRoot 'tests/support/protected-result-fixture-cleanup.ps1')
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind guest)) { . $definition }
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind controller)) { . $definition }

function Invoke-TestGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EntryPointPath,
        [Parameter(Mandatory)][string] $BundleRoot,
        [Parameter(Mandatory)][int] $ExpectedSessionId,
        [int] $TestTimeoutSeconds = 300,
        [switch] $ValidateOnly
    )
    $parameters = @{} + $PSBoundParameters
    [void]$parameters.Remove('EntryPointPath')
    & $EntryPointPath @parameters
}

function Assert-Fails {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $Expected
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) {
            throw "Expected failure containing '$Expected', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected failure containing '$Expected'."
}

function Assert-Win32Failure {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][int] $NativeErrorCode,
        [Parameter(Mandatory)][string] $Label
    )

    try {
        & $Action
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception -and
            $exception -isnot [ComponentModel.Win32Exception]) {
            $exception = $exception.InnerException
        }
        if ($null -eq $exception -or $exception.NativeErrorCode -ne $NativeErrorCode) {
            throw "$Label returned an unexpected exception: $($_.Exception.Message)"
        }
        return
    }
    throw "$Label did not fail."
}

function Get-Sha256([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8Json {
    param([string] $Path, [object] $Value)

    $json = $Value | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function New-Fixture {
    param([Parameter(Mandatory)][string] $Name)

    $root = Join-Path $script:temporaryRoot $Name
    [void](New-Item -ItemType Directory -Path $root)
    $runnerPath = Join-Path $root 'windows-vm-guest.ps1'
    Copy-Item -LiteralPath $script:runner -Destination $runnerPath
    [void](New-DrTestFrozenToolingBundle `
        -TaskRoot $root -Kind guest -EntrypointPaths @($runnerPath))
    [IO.File]::WriteAllText((Join-Path $root 'DarkReNamer.exe'), 'application fixture')
    [IO.File]::WriteAllText((Join-Path $root 'core-tests.exe'), 'test fixture')
    $manifest = [ordered]@{
        schema_version = 1
        source_sha = '0123456789abcdef0123456789abcdef01234567'
        source_state = 'clean'
        target = 'x86_64-pc-windows-msvc'
        cargo_lock_sha256 = '1' * 64
        test_binaries = @(
            [ordered]@{
                name = 'core-tests'
                file = 'core-tests.exe'
                sha256 = Get-Sha256 (Join-Path $root 'core-tests.exe')
            }
        )
        application = [ordered]@{
            file = 'DarkReNamer.exe'
            sha256 = Get-Sha256 (Join-Path $root 'DarkReNamer.exe')
        }
        runner = [ordered]@{
            file = 'windows-vm-guest.ps1'
            sha256 = Get-Sha256 $runnerPath
        }
    }
    Write-Utf8Json -Path (Join-Path $root 'bundle.json') -Value $manifest
    [pscustomobject]@{ root = $root; manifest = $manifest; runner = $runnerPath }
}

function New-CandidateFixture {
    param([Parameter(Mandatory)][string] $Name)

    $fixture = New-Fixture -Name $Name
    Remove-Item -LiteralPath (Join-Path $fixture.root 'core-tests.exe')
    foreach ($row in @(
        @{ name = 'test-windows-vm.py'; content = 'launcher fixture' }
        @{ name = 'run-windows-vm-tests.ps1'; content = 'controller fixture' }
        @{ name = 'windows-vm-acceptance.ps1'; content = 'ui observer fixture' }
        @{ name = 'windows-vm-recovery-acceptance.ps1'; content = 'recovery observer fixture' }
        @{ name = 'validate-release-handoff.ps1'; content = 'handoff validator fixture' }
        @{ name = 'validate-release-candidate-metadata.ps1'; content = 'metadata validator fixture' }
        @{ name = 'measure-windows-binary.ps1'; content = 'binary measurement fixture' }
        @{ name = 'release-handoff.json'; content = '{"source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","workflow_run":"10","executable":{"filename":"DarkReNamer.exe","sha256":"APP_HASH"}}' }
        @{ name = 'candidate-run.json'; content = '{"id":10,"run_attempt":1,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' }
        @{ name = 'candidate-artifact.json'; content = '{"id":20,"name":"DarkReNamer-dry-run-10-1-windows","workflow_run":{"id":10,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' }
    )) {
        [IO.File]::WriteAllText((Join-Path $fixture.root $row.name), $row.content)
    }
    $applicationHash = Get-Sha256 (Join-Path $fixture.root 'DarkReNamer.exe')
    $handoffPath = Join-Path $fixture.root 'release-handoff.json'
    [IO.File]::WriteAllText(
        $handoffPath,
        ([IO.File]::ReadAllText($handoffPath).Replace('APP_HASH', $applicationHash))
    )
    $artifact = {
        param([string] $Leaf)
        [ordered]@{ file = $Leaf; sha256 = Get-Sha256 (Join-Path $fixture.root $Leaf) }
    }
    $fixture.manifest = [ordered]@{
        schema_version = 2
        lane = 'candidate-gui-only'
        target = 'x86_64-pc-windows-msvc'
        product = [ordered]@{
            source_sha = 'a' * 40
            source_state = 'clean'
            candidate = [ordered]@{
                workflow_run = '10'
                run_attempt = '1'
                artifact_id = '20'
                artifact_name = 'DarkReNamer-dry-run-10-1-windows'
                origin_authentication = 'pending-hosted'
            }
            application = & $artifact 'DarkReNamer.exe'
            provenance = [ordered]@{
                release_handoff = & $artifact 'release-handoff.json'
                run_metadata = & $artifact 'candidate-run.json'
                artifact_metadata = & $artifact 'candidate-artifact.json'
            }
        }
        harness = [ordered]@{
            source_sha = 'b' * 40
            source_state = 'clean'
            launcher = & $artifact 'test-windows-vm.py'
            controller = & $artifact 'run-windows-vm-tests.ps1'
            runner = & $artifact 'windows-vm-guest.ps1'
            observers = [ordered]@{
                ui = & $artifact 'windows-vm-acceptance.ps1'
                recovery = & $artifact 'windows-vm-recovery-acceptance.ps1'
            }
            validators = [ordered]@{
                release_handoff = & $artifact 'validate-release-handoff.ps1'
                candidate_metadata = & $artifact 'validate-release-candidate-metadata.ps1'
                binary_measurement = & $artifact 'measure-windows-binary.ps1'
            }
        }
        test_binaries = @()
    }
    Save-Manifest $fixture
    $fixture
}

function Save-Manifest([object] $Fixture) {
    Write-Utf8Json -Path (Join-Path $Fixture.root 'bundle.json') -Value $Fixture.manifest
}

$runner = Join-Path $toolingScriptsRoot 'windows-vm-guest.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-vm-guest-' + [Guid]::NewGuid().ToString('N'))
$script:protectedResultFixturePaths = [Collections.Generic.List[string]]::new()
$testFailure = $null
[void](New-Item -ItemType Directory -Path $temporaryRoot)
try {
    $valid = New-Fixture -Name 'valid'
    Invoke-TestGuest -EntryPointPath $valid.runner -BundleRoot $valid.root -ExpectedSessionId 1 -ValidateOnly
    $leakedCommand = Get-Command Get-DrToolingVerifiedBundle -ErrorAction SilentlyContinue
    $leakedModules = @(Get-Module | Where-Object Name -Like 'DarkReNamer.*')
    if ($null -ne $leakedCommand) { throw "The public guest facade leaked loader command from $($leakedCommand.ModuleName)." }
    if ($leakedModules.Count -ne 0) { throw 'The public guest facade leaked its private modules.' }
    $tamperedTooling = New-Fixture -Name 'tampered-tooling'
    [IO.File]::AppendAllText(
        (Join-Path $tamperedTooling.root 'guest-contracts.ps1'),
        "`n# changed after manifest freeze"
    )
    Assert-Fails {
        Invoke-TestGuest `
            -EntryPointPath $tamperedTooling.runner `
            -BundleRoot $tamperedTooling.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'mismatch'
    foreach ($layout in @('checkout', 'bundle')) {
        $controllerFixture = New-DrTestControllerFacadeFixture `
            -Root (Join-Path $temporaryRoot "controller-$layout") `
            -Layout $layout
        $facadeResult = & $controllerFixture.entrypoint `
            -BundleRoot $controllerFixture.root `
            -SshHost fixture
        if ($facadeResult.bundle_root -cne $controllerFixture.root -or
            $facadeResult.ssh_host -cne 'fixture' -or
            $facadeResult.entrypoint_path -cne $controllerFixture.entrypoint -or
            $facadeResult.library_count -ne 4 -or
            $facadeResult.record_count -ne 6) {
            throw "The public controller facade did not execute its verified $layout fixture."
        }
        if ($null -ne (Get-Command Get-DrToolingVerifiedBundle -ErrorAction SilentlyContinue) -or
            @(Get-Module | Where-Object Name -Like 'DarkReNamer.loader.*').Count -ne 0 -or
            @(Get-Module | Where-Object Name -Like 'DarkReNamer.controller.*').Count -ne 0) {
            throw "The public controller facade leaked private $layout tooling state."
        }
    }
    $tamperedController = New-DrTestControllerFacadeFixture `
        -Root (Join-Path $temporaryRoot 'controller-tampered') `
        -Layout bundle
    [IO.File]::AppendAllText($tamperedController.controller_entry, "`n# changed after manifest freeze")
    Assert-Fails {
        & $tamperedController.entrypoint -BundleRoot $tamperedController.root -SshHost fixture
    } 'SHA-256 mismatch for tooling role'
    $missingController = New-DrTestControllerFacadeFixture `
        -Root (Join-Path $temporaryRoot 'controller-missing') `
        -Layout bundle
    Remove-Item -LiteralPath $missingController.loader
    Assert-Fails {
        & $missingController.entrypoint -BundleRoot $missingController.root -SshHost fixture
    } 'layout is missing or ambiguous'
    $ambiguousController = New-DrTestControllerFacadeFixture `
        -Root (Join-Path $temporaryRoot 'controller-ambiguous') `
        -Layout checkout
    Copy-Item -LiteralPath $ambiguousController.manifest `
        -Destination (Join-Path (Split-Path $ambiguousController.entrypoint -Parent) 'tooling-bundle.json')
    Copy-Item -LiteralPath $ambiguousController.loader `
        -Destination (Join-Path (Split-Path $ambiguousController.entrypoint -Parent) 'tooling-loader.ps1')
    Assert-Fails {
        & $ambiguousController.entrypoint -BundleRoot $ambiguousController.root -SshHost fixture
    } 'layout is missing or ambiguous'
    $transferManifestText = '{"schema_version":1,"modules":[]}'
    $transferModuleText = 'function Test-FrozenTransfer { $true }'
    $transferStage = New-ControllerToolingTransferStage -VerifiedTooling ([pscustomobject]@{
        ManifestBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($transferManifestText)
        )
        ManifestSha256 = Get-LowerTextSha256 -Value $transferManifestText
        Records = @([pscustomobject]@{
            Role = 'powershell-controller-contracts'
            Bundle = 'controller-contracts.ps1'
            Sha256 = Get-LowerTextSha256 -Value $transferModuleText
            FrozenBase64 = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($transferModuleText)
            )
            Length = [Text.Encoding]::UTF8.GetByteCount($transferModuleText)
        })
    })
    try {
        if ((Get-Sha256 (Join-Path $transferStage.root 'tooling-bundle.json')) -cne
                $transferStage.manifest_sha256 -or
            (Get-Sha256 (Join-Path $transferStage.root 'controller-contracts.ps1')) -cne
                $transferStage.records[0].sha256) {
            throw 'The controller did not materialize its frozen tooling closure exactly.'
        }
    }
    finally {
        Remove-Item -LiteralPath $transferStage.root -Recurse -Force
    }
    $throwingTransfer = [pscustomobject]@{}
    $throwingTransfer | Add-Member -MemberType ScriptProperty -Name root -Value {
        throw 'cleanup fixture failure'
    }
    $cleanupContinuation = $false
    $cleanupFailure = Remove-ControllerToolingTransferStage -Transfer $throwingTransfer
    $cleanupContinuation = $true
    if (-not $cleanupContinuation -or
        $cleanupFailure -cne 'Local frozen-tooling transfer cleanup failed.') {
        throw 'A local tooling cleanup failure escaped its best-effort boundary.'
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Assert-Fails {
            Invoke-TestGuest -EntryPointPath $valid.runner -BundleRoot $valid.root -ExpectedSessionId 1
        } 'requires Windows'
        $failedResultText = [IO.File]::ReadAllText((Join-Path $valid.root 'result.json'))
        $failedResult = $failedResultText | ConvertFrom-Json
        if ($failedResult.schema_version -ne 1 -or
            $failedResult.source_sha -cne $valid.manifest.source_sha -or
            $failedResult.source_state -cne 'clean' -or
            $failedResult.status -cne 'failed' -or
            $failedResult.failure_reason -cne 'unsupported_platform' -or
            @($failedResult.tests).Count -ne 0 -or
            $null -ne $failedResult.gui) {
            throw 'The fail-closed result document was parsed incorrectly.'
        }
        if ($failedResultText.IndexOf($valid.root, [StringComparison]::Ordinal) -ge 0) {
            throw 'The result document must not contain BundleRoot.'
        }
    }

    $caseFixtureFailureRoot = Join-Path $valid.root 'case-fixture-cleanup-failure'
    [void](New-Item -ItemType Directory -Path $caseFixtureFailureRoot)
    [IO.File]::WriteAllText((Join-Path $caseFixtureFailureRoot 'unexpected.txt'), 'retained')
    $caseFixtureFailureRow = [ordered]@{
        status = 'passed'
        failure_reason = $null
    }
    Assert-Fails {
        Complete-JobBoundCaseSensitiveFixture `
            -FixtureRoot $caseFixtureFailureRoot -Row $caseFixtureFailureRow
    } 'was not emptied before cleanup'
    if ($caseFixtureFailureRow.status -cne 'failed' -or
        $caseFixtureFailureRow.failure_reason -cne 'process_error' -or
        -not (Test-Path -LiteralPath $caseFixtureFailureRoot)) {
        throw 'Case-sensitive fixture cleanup failure must fail the test row and preserve its evidence.'
    }

    $candidate = New-CandidateFixture -Name 'candidate-valid'
    Invoke-TestGuest -EntryPointPath $candidate.runner -BundleRoot $candidate.root -ExpectedSessionId 1 -ValidateOnly
    Invoke-TestGuest -EntryPointPath $candidate.runner -BundleRoot $candidate.root -ExpectedSessionId 1 -ValidateOnly
    $candidateContract = Resolve-VerifiedBundle `
        -Root $candidate.root `
        -InvokedScriptPath $candidate.runner
    if ($candidateContract.contract.lane -cne 'candidate-gui-only' -or
        $candidateContract.contract.product_source_sha -cne ('a' * 40) -or
        $candidateContract.contract.harness_source_sha -cne ('b' * 40) -or
        $candidateContract.contract.observers.ui.file -cne 'windows-vm-acceptance.ps1' -or
        $candidateContract.contract.observers.recovery.file -cne 'windows-vm-recovery-acceptance.ps1' -or
        $candidateContract.tests.Count -ne 0) {
        throw 'The candidate product and harness normalization contract is invalid.'
    }

    $exactMain = [pscustomobject]@{
        Handle = 5151L; Owner = 0L; ProcessId = 700
        ClassName = 'DarkReNamerWindow'; Title = 'DarkReNamer'; Visible = $true
        Left = 10; Top = 20; Right = 810; Bottom = 620
    }
    $ownerlessShadow = [pscustomobject]@{
        Handle = 4141L; Owner = 0L; ProcessId = 700
        ClassName = 'SysShadow'; Title = ''; Visible = $true
        Left = 600; Top = 300; Right = 900; Bottom = 350
    }
    $selectedMain = Resolve-ExactApplicationMainWindowCandidate `
        -Windows @($ownerlessShadow, $exactMain) `
        -ExpectedProcessId 700 `
        -ExpectedClassName 'DarkReNamerWindow' `
        -ExpectedTitle 'DarkReNamer'
    if ($selectedMain.Handle -ne 5151L) {
        throw 'Exact main-window selection accepted an ownerless shadow before the application window.'
    }
    $duplicateMain = $exactMain | ConvertTo-Json | ConvertFrom-Json
    $duplicateMain.Handle = 5152L
    Assert-Fails {
        Resolve-ExactApplicationMainWindowCandidate `
            -Windows @($exactMain, $duplicateMain) `
            -ExpectedProcessId 700 `
            -ExpectedClassName 'DarkReNamerWindow' `
            -ExpectedTitle 'DarkReNamer'
    } 'matched more than one exact native window'

    $topLevelCandidate = [pscustomobject]@{
        Current = [pscustomobject]@{ NativeWindowHandle = 101 }
    }
    $fallbackCandidate = [pscustomobject]@{
        Current = [pscustomobject]@{ NativeWindowHandle = 102 }
    }
    $fallbackProbe = [pscustomobject]@{ calls = 0 }
    $fallbackQuery = {
        $fallbackProbe.calls++
        $fallbackCandidate
    }.GetNewClosure()
    $selected = Resolve-UniqueAutomationWindowCandidate `
        -TopLevelCandidates @($topLevelCandidate) `
        -FallbackQuery $fallbackQuery `
        -Label 'top-level fixture'
    if ($selected.Current.NativeWindowHandle -ne 101 -or $fallbackProbe.calls -ne 0) {
        throw 'A unique top-level window did not bypass the descendant fallback query.'
    }
    $selected = Resolve-UniqueAutomationWindowCandidate `
        -TopLevelCandidates @() `
        -FallbackQuery $fallbackQuery `
        -Label 'fallback fixture'
    if ($selected.Current.NativeWindowHandle -ne 102 -or $fallbackProbe.calls -ne 1) {
        throw 'The descendant fallback did not run exactly once after an empty top-level query.'
    }
    $ambiguousCandidate = [pscustomobject]@{
        Current = [pscustomobject]@{ NativeWindowHandle = 103 }
    }
    Assert-Fails {
        Resolve-UniqueAutomationWindowCandidate `
            -TopLevelCandidates @($topLevelCandidate, $ambiguousCandidate) `
            -FallbackQuery $fallbackQuery `
            -Label 'ambiguous fixture'
    } 'matched more than one top-level window'
    if ($fallbackProbe.calls -ne 1) {
        throw 'An ambiguous top-level query incorrectly invoked the descendant fallback.'
    }
    Assert-Fails {
        Resolve-UniqueAutomationWindowCandidate `
            -TopLevelCandidates @() `
            -FallbackQuery { @($fallbackCandidate, $ambiguousCandidate) } `
            -Label 'ambiguous fallback fixture'
    } 'matched more than one top-level window'

    $candidateSwappedObserver = New-CandidateFixture -Name 'candidate-swapped-observer'
    $uiObserver = $candidateSwappedObserver.manifest.harness.observers.ui
    $candidateSwappedObserver.manifest.harness.observers.ui =
        $candidateSwappedObserver.manifest.harness.observers.recovery
    $candidateSwappedObserver.manifest.harness.observers.recovery = $uiObserver
    Save-Manifest $candidateSwappedObserver
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $candidateSwappedObserver.runner `
            -BundleRoot $candidateSwappedObserver.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'observer ui file is invalid'

    $candidateObserverHashMismatch = New-CandidateFixture -Name 'candidate-observer-hash-mismatch'
    $candidateObserverHashMismatch.manifest.harness.observers.ui.sha256 = 'f' * 64
    Save-Manifest $candidateObserverHashMismatch
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $candidateObserverHashMismatch.runner `
            -BundleRoot $candidateObserverHashMismatch.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'manifest artifact hash mismatch'

    $candidateMetadataMismatch = New-CandidateFixture -Name 'candidate-metadata-mismatch'
    $candidateMetadataMismatch.manifest.product.candidate.artifact_id = '21'
    Save-Manifest $candidateMetadataMismatch
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $candidateMetadataMismatch.runner `
            -BundleRoot $candidateMetadataMismatch.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'GitHub metadata differs'

    $candidateHashMismatch = New-CandidateFixture -Name 'candidate-hash-mismatch'
    $candidateHashMismatch.manifest.product.application.sha256 = 'f' * 64
    Save-Manifest $candidateHashMismatch
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $candidateHashMismatch.runner `
            -BundleRoot $candidateHashMismatch.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'manifest artifact hash mismatch'

    $candidateDuplicateMetadata = New-CandidateFixture -Name 'candidate-duplicate-metadata'
    $duplicateRunPath = Join-Path $candidateDuplicateMetadata.root 'candidate-run.json'
    [IO.File]::WriteAllText(
        $duplicateRunPath,
        '{"id":10,"id":10,"run_attempt":1,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    )
    $candidateDuplicateMetadata.manifest.product.provenance.run_metadata.sha256 =
        Get-Sha256 $duplicateRunPath
    Save-Manifest $candidateDuplicateMetadata
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $candidateDuplicateMetadata.runner `
            -BundleRoot $candidateDuplicateMetadata.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'duplicate field: id'

    $candidateDuplicateArtifact = New-CandidateFixture -Name 'candidate-duplicate-artifact'
    $duplicateArtifactPath = Join-Path $candidateDuplicateArtifact.root 'candidate-artifact.json'
    [IO.File]::WriteAllText(
        $duplicateArtifactPath,
        '{"id":20,"id":20,"name":"DarkReNamer-dry-run-10-1-windows","workflow_run":{"id":10,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
    )
    $candidateDuplicateArtifact.manifest.product.provenance.artifact_metadata.sha256 =
        Get-Sha256 $duplicateArtifactPath
    Save-Manifest $candidateDuplicateArtifact
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $candidateDuplicateArtifact.runner `
            -BundleRoot $candidateDuplicateArtifact.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'duplicate field: id'

    $emptyDefault = New-Fixture -Name 'empty-default'
    $emptyDefault.manifest.test_binaries = @()
    Save-Manifest $emptyDefault
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $emptyDefault.runner -BundleRoot $emptyDefault.root -ExpectedSessionId 1 -ValidateOnly
    } 'non-empty array'

    $duplicateManifest = New-Fixture -Name 'duplicate-manifest'
    $duplicateJson = $duplicateManifest.manifest | ConvertTo-Json -Depth 8
    $duplicateJson = $duplicateJson.Replace(
        '"schema_version": 1,',
        '"schema_version": 1, "schema_version": 1,'
    )
    [IO.File]::WriteAllText(
        (Join-Path $duplicateManifest.root 'bundle.json'),
        $duplicateJson,
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $duplicateManifest.runner `
            -BundleRoot $duplicateManifest.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'duplicate field: schema_version'

    $numericType = New-CandidateFixture -Name 'candidate-numeric-type'
    $numericType.manifest.schema_version = [double]2.0
    Save-Manifest $numericType
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $numericType.runner -BundleRoot $numericType.root -ExpectedSessionId 1 -ValidateOnly
    } 'JSON integer 2'

    $badHash = New-Fixture -Name 'bad-hash'
    $badHash.manifest.test_binaries[0].sha256 = '2' * 64
    Save-Manifest $badHash
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $badHash.runner -BundleRoot $badHash.root -ExpectedSessionId 1 -ValidateOnly
    } 'test binary hash mismatch'

    $traversal = New-Fixture -Name 'traversal'
    $traversal.manifest.test_binaries[0].file = '..\outside.exe'
    Save-Manifest $traversal
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $traversal.runner -BundleRoot $traversal.root -ExpectedSessionId 1 -ValidateOnly
    } 'safe leaf filename'

    $duplicate = New-Fixture -Name 'duplicate'
    $duplicate.manifest.test_binaries += [ordered]@{
        name = 'second-test'
        file = 'CORE-TESTS.EXE'
        sha256 = $duplicate.manifest.test_binaries[0].sha256
    }
    Save-Manifest $duplicate
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $duplicate.runner -BundleRoot $duplicate.root -ExpectedSessionId 1 -ValidateOnly
    } 'filenames must be unique'

    $extraField = New-Fixture -Name 'extra-field'
    $extraField.manifest.application.extra = 'untrusted'
    Save-Manifest $extraField
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $extraField.runner -BundleRoot $extraField.root -ExpectedSessionId 1 -ValidateOnly
    } 'unexpected fields'

    $wrongTarget = New-Fixture -Name 'wrong-target'
    $wrongTarget.manifest.target = 'x86_64-pc-windows-gnu'
    Save-Manifest $wrongTarget
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $wrongTarget.runner -BundleRoot $wrongTarget.root -ExpectedSessionId 1 -ValidateOnly
    } 'target is invalid'

    $changedRunner = New-Fixture -Name 'changed-runner'
    [IO.File]::AppendAllText($changedRunner.runner, "`n# changed")
    Assert-Fails {
        Invoke-TestGuest -EntryPointPath $changedRunner.runner -BundleRoot $changedRunner.root -ExpectedSessionId 1 -ValidateOnly
    } 'manifest artifact hash mismatch'

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $reparse = New-Fixture -Name 'reparse'
        $targetPath = Join-Path $reparse.root 'real-tests.exe'
        [IO.File]::WriteAllText($targetPath, 'linked fixture')
        Remove-Item -LiteralPath (Join-Path $reparse.root 'core-tests.exe')
        [void](New-Item -ItemType SymbolicLink -Path (Join-Path $reparse.root 'core-tests.exe') -Target $targetPath)
        $reparse.manifest.test_binaries[0].sha256 = Get-Sha256 $targetPath
        Save-Manifest $reparse
        Assert-Fails {
            Invoke-TestGuest -EntryPointPath $reparse.runner -BundleRoot $reparse.root -ExpectedSessionId 1 -ValidateOnly
        } 'must not be a reparse point'
    }

    Invoke-TestGuest -EntryPointPath $valid.runner -BundleRoot $valid.root -ExpectedSessionId 1 -ValidateOnly
    # UI Automation providers may expose an empty Name for a valid focused control.
    if ((Get-LowerTextSha256 -Value '') -cne
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') {
        throw 'The source-bound text digest helper rejected an empty UI Automation name.'
    }
    if ((Get-LowerTextSha256 -Value 'abc') -cne
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') {
        throw 'The source-bound identity digest helper returned the wrong SHA-256 value.'
    }
    foreach ($helper in @(
        'Get-FullFileIdentity',
        'Get-VmAutomatedEnvironment',
        'Get-VmAutomatedFixtureInventory',
        'Get-VmAutomatedJournalInventory',
        'Get-VmAutomatedCheckpoint',
        'Get-VmAutomatedOwnedProcessInventory',
        'Get-VmAutomatedOwnedProcessCleanupObservation',
        'Get-VmAutomatedRuntimeRootObservation',
        'New-VmAutomatedJournalCleanupObservation'
    )) {
        if ($null -eq (Get-Command $helper -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "The shared VM-Automated helper $helper is unavailable after dot-sourcing."
        }
    }
    $observedJournal = New-VmAutomatedJournalCleanupObservation `
        -Observed $true `
        -Entries @([ordered]@{ name = 'runtime.lock'; kind = 'file'; bytes = [long]0 })
    if ($null -eq $observedJournal -or
        @($observedJournal.entries).Count -ne 1 -or
        $observedJournal.entries[0].name -cne 'runtime.lock' -or
        $null -ne (New-VmAutomatedJournalCleanupObservation -Observed $false -Entries @())) {
        throw 'Cleanup journal evidence must distinguish an observed inventory from an unobserved one.'
    }
    # Exercise the actual fixture producer in a fresh process so Linux-only native stubs cannot leak.
    $producerScript = @'
param([string] $ScriptsRoot, [string] $TestRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $ScriptsRoot 'tests/support/windows-vm-module-loader.ps1')
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind guest)) { . $definition }
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Initialize-NativeCapture
}
else {
    # Only Windows identity/drive-path boundaries are substituted; inventories and hashes remain real.
    Add-Type 'public static class DarkReNamerVmNative { public static string GetFileIdentity(string path) { return "portable-fixture-id"; } }'
    function Get-VmAutomatedCanonicalRootPath([string] $Path) {
        (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
    }
    function Get-FullFileIdentity([string] $Path) {
        [ordered]@{ volume_serial = 'aabbccdd11223344'; file_id = 'ffffffff000000000000000000000001' }
    }
}
[void](New-Item -ItemType Directory -Path $TestRoot)
$applicationRoot = Join-Path $TestRoot 'application'
[void](New-Item -ItemType Directory -Path $applicationRoot)
[IO.File]::WriteAllText((Join-Path $applicationRoot 'DarkReNamer.exe'), 'fixture application bytes')
foreach ($rawEvidence in @($true, $false)) {
    $caseRoot = Join-Path $TestRoot ([string]$rawEvidence)
    $fixtureRoot = Join-Path $caseRoot 'fixture'
    $localAppData = Join-Path $caseRoot 'local-app-data'
    [void](New-Item -ItemType Directory -Path $fixtureRoot -Force)
    [void](New-Item -ItemType Directory -Path $localAppData)
    $initial = Initialize-ProductionRenameFlowFixture -FixtureRoot $fixtureRoot `
        -ApplicationRoot $applicationRoot -LocalAppData $localAppData -RawEvidence:$rawEvidence
    if ($initial.checkpoints -isnot [array] -or $initial.checkpoints.Count -ne 1) {
        throw 'The actual fixture producer must return a singleton legacy checkpoint array.'
    }
    if ($initial.raw_checkpoints -isnot [array] -or
        $initial.raw_checkpoints.Count -ne $(if ($rawEvidence) { 1 } else { 0 })) {
        throw "The actual fixture producer must return a raw checkpoint array (RawEvidence=$rawEvidence)."
    }
    $journalRoot = Join-Path $localAppData 'DarkReNamer/journal'
    [void](New-Item -ItemType Directory -Path $journalRoot -Force)
    [IO.File]::WriteAllBytes((Join-Path $journalRoot 'runtime.lock'), [byte[]]@())
    $startup = @((Get-FlowCheckpoint -Phase initial -FixtureRoot $fixtureRoot -LocalAppData $localAppData))
    Assert-ProductionRenameFlowStartupCheckpoint -Prelaunch $initial.checkpoints[0] -Startup $startup[0]
    if ($rawEvidence) {
        $rawStartup = @((Get-VmAutomatedCheckpoint -Phase initial -FixtureRoot $fixtureRoot -LocalAppData $localAppData))
        if ($initial.raw_checkpoints[0] -isnot [Collections.IDictionary] -or
            $initial.raw_checkpoints[0].phase -cne 'initial' -or
            @($initial.raw_checkpoints[0].journal_entries).Count -ne 0 -or
            @($rawStartup[0].journal_entries).Count -ne 1) {
            throw 'The actual singleton raw checkpoint must retain prelaunch and observed startup state.'
        }
        # Match the production call shape; an unwrapped OrderedDictionary indexes to "initial" here.
        Assert-ProductionRenameFlowStartupCheckpoint -Prelaunch $initial.raw_checkpoints[0] -Startup $rawStartup[0]
    }
}
'@
    $producerScriptPath = Join-Path $temporaryRoot 'fixture-producer-regression.ps1'
    [IO.File]::WriteAllText($producerScriptPath, $producerScript, [Text.UTF8Encoding]::new($false))
    $producerStartInfo = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $producerStartInfo.UseShellExecute = $false
    $producerStartInfo.CreateNoWindow = $true
    $producerStartInfo.RedirectStandardOutput = $true
    $producerStartInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $producerScriptPath,
        '-ScriptsRoot', $toolingScriptsRoot, '-TestRoot', (Join-Path $temporaryRoot 'fixture-producer'))) {
        [void]$producerStartInfo.ArgumentList.Add($argument)
    }
    $producerProcess = [Diagnostics.Process]::Start($producerStartInfo)
    try {
        $producerOutput = $producerProcess.StandardOutput.ReadToEndAsync()
        $producerError = $producerProcess.StandardError.ReadToEndAsync()
        if (-not $producerProcess.WaitForExit(30000)) { throw 'Fixture producer regression timed out.' }
        if ($producerProcess.ExitCode -ne 0) {
            throw "Actual fixture producer regression failed: $($producerError.GetAwaiter().GetResult())"
        }
        [void]$producerOutput.GetAwaiter().GetResult()
    }
    finally {
        if (-not $producerProcess.HasExited) { $producerProcess.Kill($true); $producerProcess.WaitForExit() }
        $producerProcess.Dispose()
    }
    # Startup may create the runtime lock; Cancel starts from the observed running state.
    $startupLocalAppData = Join-Path $temporaryRoot 'startup-local-app-data'
    [void](New-Item -ItemType Directory -Path $startupLocalAppData)
    $prelaunchJournal = @(Get-VmAutomatedJournalInventory -LocalAppData $startupLocalAppData)
    $startupJournalRoot = Join-Path $startupLocalAppData 'DarkReNamer/journal'
    [void](New-Item -ItemType Directory -Path $startupJournalRoot -Force)
    [IO.File]::WriteAllBytes((Join-Path $startupJournalRoot 'runtime.lock'), [byte[]]@())
    $startupJournal = @(Get-VmAutomatedJournalInventory -LocalAppData $startupLocalAppData)
    foreach ($rawIdentity in @($false, $true)) {
        $entry = [ordered]@{
            name = 'vm-flow-source.txt'; kind = 'file'; bytes = [long]65
            content_sha256 = 'a' * 64
        }
        if ($rawIdentity) {
            $entry['file_identity'] = [ordered]@{
                volume_serial = 'aabbccdd11223344'
                file_id = 'ffffffff000000000000000000000001'
            }
        }
        else { $entry['file_identity_sha256'] = 'b' * 64 }
        $prelaunch = [ordered]@{
            phase = 'initial'; fixture_entries = @($entry); journal_entries = $prelaunchJournal
        }
        $startup = [ordered]@{
            phase = 'initial'; fixture_entries = @($entry); journal_entries = $startupJournal
        }
        $observedBefore = $startup | ConvertTo-Json -Depth 8 -Compress
        Assert-ProductionRenameFlowStartupCheckpoint -Prelaunch $prelaunch -Startup $startup
        Assert-ProductionRenameFlowStartupCheckpoint -Prelaunch $prelaunch -Startup $prelaunch
        if (@($prelaunch.journal_entries).Count -ne 0 -or
            @($startup.journal_entries).Count -ne 1 -or
            ($startup | ConvertTo-Json -Depth 8 -Compress) -cne $observedBefore) {
            throw 'Startup validation must preserve the actual prelaunch and post-startup observations.'
        }
        foreach ($mutation in @('content', 'size', 'name', 'extra', 'identity', 'file-id')) {
            $changed = $observedBefore | ConvertFrom-Json -Depth 8
            switch ($mutation) {
                content { $changed.fixture_entries[0].content_sha256 = 'c' * 64 }
                size { $changed.fixture_entries[0].bytes++ }
                name { $changed.fixture_entries[0].name = 'changed.txt' }
                extra { $changed.fixture_entries += $changed.fixture_entries[0] }
                identity {
                    if ($rawIdentity) {
                        $changed.fixture_entries[0].file_identity.volume_serial = '0000000011223344'
                    }
                    else { $changed.fixture_entries[0].file_identity_sha256 = 'd' * 64 }
                }
                file-id {
                    if ($rawIdentity) {
                        $changed.fixture_entries[0].file_identity.file_id = '00000000000000000000000000000001'
                    }
                    else { $changed.fixture_entries[0].file_identity_sha256 = 'e' * 64 }
                }
            }
            Assert-Fails {
                Assert-ProductionRenameFlowStartupCheckpoint -Prelaunch $prelaunch -Startup $changed
            } 'Startup changed the production flow fixture inventory'
        }
        foreach ($mutation in @('bytes', 'boolean-bytes', 'kind', 'name', 'extra')) {
            $changed = $observedBefore | ConvertFrom-Json -Depth 8
            switch ($mutation) {
                bytes { $changed.journal_entries[0].bytes = 1 }
                boolean-bytes { $changed.journal_entries[0].bytes = $false }
                kind { $changed.journal_entries[0].kind = 'directory' }
                name { $changed.journal_entries[0].name = 'active.drj' }
                extra { $changed.journal_entries += $changed.journal_entries[0] }
            }
            Assert-Fails {
                Assert-ProductionRenameFlowStartupCheckpoint -Prelaunch $prelaunch -Startup $changed
            } 'Startup left an unexpected production flow journal inventory'
        }
        $dirtyPrelaunch = $observedBefore | ConvertFrom-Json -Depth 8
        Assert-Fails {
            Assert-ProductionRenameFlowStartupCheckpoint -Prelaunch $dirtyPrelaunch -Startup $startup
        } 'The prelaunch production flow journal inventory is not empty'
    }
    $injectedOwnedPath = [IO.Path]::GetFullPath($valid.root).TrimEnd('\\') +
        '\\injected-owned.exe'
    $observedOwned = Get-VmAutomatedOwnedProcessCleanupObservation `
        -Root $valid.root `
        -ProcessQuery {
            [pscustomobject]@{
                ProcessId = 42
                SessionId = 7
                ExecutablePath = $injectedOwnedPath
            }
        }
    if (-not $observedOwned.observed -or
        $null -ne $observedOwned.error -or
        @($observedOwned.entries).Count -ne 1 -or
        $observedOwned.entries[0].pid -ne 42 -or
        $observedOwned.entries[0].session_id -ne 7 -or
        $observedOwned.entries[0].executable_path -cne $injectedOwnedPath) {
        throw 'Injected CIM cleanup inventory did not retain its observed process identity.'
    }
    $unobservedOwned = Get-VmAutomatedOwnedProcessCleanupObservation `
        -Root $valid.root `
        -ProcessQuery { throw 'injected CIM cleanup failure' }
    if ($unobservedOwned.observed -or
        $null -ne $unobservedOwned.entries -or
        $null -eq $unobservedOwned.error -or
        $unobservedOwned.error.type -cne 'System.Management.Automation.RuntimeException' -or
        $unobservedOwned.error.message -cne 'injected CIM cleanup failure' -or
        $unobservedOwned.diagnostic.IndexOf(
            'injected CIM cleanup failure', [StringComparison]::Ordinal
        ) -lt 0) {
        throw 'Cleanup inventory failure must remain explicit and distinguishable from an empty inventory.'
    }
    $runtimeObservationRoot = Join-Path $valid.root 'runtime-observation'
    [void](New-Item -ItemType Directory -Path $runtimeObservationRoot)
    [IO.File]::WriteAllText((Join-Path $runtimeObservationRoot 'first.txt'), 'first')
    [IO.File]::WriteAllText((Join-Path $runtimeObservationRoot 'second.txt'), 'second')
    $runtimeObservation = Get-VmAutomatedRuntimeRootObservation `
        -Root $runtimeObservationRoot `
        -MaximumEntries 2
    if (-not $runtimeObservation.exists -or @($runtimeObservation.entries).Count -ne 2) {
        throw 'The bounded runtime inventory did not enumerate its complete ordinary tree.'
    }
    [IO.File]::WriteAllText((Join-Path $runtimeObservationRoot 'third.txt'), 'third')
    Assert-Fails {
        Get-VmAutomatedRuntimeRootObservation -Root $runtimeObservationRoot -MaximumEntries 2
    } 'entry count exceeds its bound'
    $reparseTarget = Join-Path $valid.root 'runtime-reparse-target'
    [void](New-Item -ItemType Directory -Path $reparseTarget)
    $reparsePath = Join-Path $runtimeObservationRoot 'linked'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        & "$env:SystemRoot\System32\cmd.exe" /d /c mklink /J $reparsePath $reparseTarget | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the runtime-observation junction fixture.' }
    }
    else {
        [void](New-Item -ItemType SymbolicLink -Path $reparsePath -Target $reparseTarget)
    }
    Assert-Fails {
        Get-VmAutomatedRuntimeRootObservation -Root $runtimeObservationRoot -MaximumEntries 8
    } 'contains a reparse point'
    $runnerText = Get-DrTestCombinedPowerShellSource -Kind guest
    foreach ($requiredJobSource in @(
        'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE',
        'CREATE_SUSPENDED = 0x00000004',
        'EXTENDED_STARTUPINFO_PRESENT = 0x00080000',
        'CREATE_UNICODE_ENVIRONMENT = 0x00000400',
        'MAX_ENVIRONMENT_BLOCK_CHARS = 32767',
        'UOI_NAME = 2',
        'HANDLE_LIST_ATTRIBUTE',
        'CopyCurrentEnvironmentBlock()',
        'GetEnvironmentStringsW()',
        'FreeEnvironmentStringsW(source)',
        'consecutiveNulls == 2',
        'flags |= CREATE_UNICODE_ENVIRONMENT;',
        'Inherit the task desktop so CreateProcessWithTokenW grants the verified user access.',
        'flags, environmentBlock,',
        'commandLine.Length >= 1024',
        'The CreateProcessWithTokenW command line exceeds its supported bound.',
        'function Resolve-JobBoundCapturePaths',
        '$BoundParameters.Keys -contains ''StdoutPath''',
        'bool redirect = !String.IsNullOrEmpty(stdoutPath) || !String.IsNullOrEmpty(stderrPath);',
        'public static class DarkReNamerVmFileSystem',
        'public static string GetShortPathName(string longPath)',
        'public static void SetCaseSensitiveDirectory(string path)',
        'function Resolve-JobBoundShortPath',
        '$temporaryRoot = Resolve-JobBoundShortPath -Path $temporaryRoot',
        '[DarkReNamerVmFileSystem]::SetCaseSensitiveDirectory($caseSensitiveFixtureRoot)',
        'DARKRENAMER_CASE_SENSITIVE_FIXTURE_ROOT',
        '-CaseSensitiveFixtureRoot $caseSensitiveFixtureRoot',
        'function Complete-JobBoundCaseSensitiveFixture',
        '$Row.status = ''failed''',
        '$row[''process_lifecycle''] = [ordered]@{',
        'start_time_utc_ticks = $processStartTimeUtcTicks',
        '$capturePaths.stdout_path',
        '$capturePaths.stderr_path',
        'AssertDefaultObserverDesktop();',
        'GetProcessWindowStation()',
        'GetThreadDesktop(GetCurrentThreadId())',
        'GetUserObjectInformationW(handle, UOI_NAME, name,',
        'The elevated observer is not attached to WinSta0\\Default.',
        'ref StartupInfo startupInfo, out ProcessInformation processInformation);',
        'ref startup.StartupInfo, out created)',
        'TOKEN_LINKED_TOKEN = 19',
        'TOKEN_ASSIGN_PRIMARY = 0x0001',
        'TOKEN_DUPLICATE = 0x0002',
        'TOKEN_ADJUST_DEFAULT = 0x0080',
        'TOKEN_ADJUST_SESSIONID = 0x0100',
        'SECURITY_IMPERSONATION = 2',
        'uint desiredAccess = TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY |',
        'TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID;',
        'DuplicateTokenEx(shellToken, desiredAccess, IntPtr.Zero,',
        'The duplicated shell token is not primary.',
        'DuplicateTokenEx returned the existing shell token identity.',
        'The duplicated shell token belongs to a different interactive logon.',
        'TOKEN_PRIMARY = 1',
        'TOKEN_ELEVATION_TYPE = 18',
        'TOKEN_ELEVATION_TYPE_FULL = 2',
        'TOKEN_ELEVATION_TYPE_LIMITED = 3',
        'TOKEN_UI_ACCESS = 26',
        'GetTokenInformation(token, informationClass',
        'OpenVerifiedLinkedShellPrimaryToken',
        'OpenVerifiedShellPrimaryToken',
        'GetShellWindow()',
        'GetWindowThreadProcessId(shellWindow, out processId)',
        'PROCESS_QUERY_LIMITED_INFORMATION, false, shellProcessId)',
        'QueryFullProcessImageNameW(process, 0, imagePath, ref length)',
        'GetWindowsDirectoryW(windowsDirectory, (uint)windowsDirectory.Capacity)',
        'TokenDword(shellToken, TOKEN_TYPE) != TOKEN_PRIMARY',
        'ReadTokenStatistics(linkedToken).AuthenticationId',
        'TokenStatistics shellStatistics = ReadTokenStatistics(shellToken);',
        'Luid shellAuthenticationId = shellStatistics.AuthenticationId;',
        'ReadTokenStatistics(observerToken).AuthenticationId',
        'SameLuid(expectedAuthenticationId, ReadTokenStatistics(token).AuthenticationId)',
        'SameLuid(linkedAuthenticationId, shellAuthenticationId)',
        'token, 1, TOKEN_ELEVATION_TYPE_FULL, expectedSession,',
        'linked, 0, TOKEN_ELEVATION_TYPE_LIMITED, expectedSession,',
        'shellToken, 0, TOKEN_ELEVATION_TYPE_LIMITED, expectedSession,',
        'Win32Exception Win32Failure(string operation)',
        'GetTokenInformation for class ',
        'CreateProcessWithTokenW for the verified medium shell token',
        'The shell token belongs to a different interactive logon.',
        'The suspended observer child belongs to a different logon session.',
        'The interactive shell image is not the Windows Explorer binary.',
        'The interactive shell process changed during token acquisition.',
        'CreateProcessWithTokenW(observerToken, 0, filePath',
        'RequireCreatedChild(created.hProcess, observerSession, observerUserSid,',
        'AssertHighObserverToken',
        'Assert-VmObserverExecutionContext',
        'Test-MediumObserverBoundary',
        'DARKRENAMER_VM_ELEVATED_OBSERVER',
        'AssignProcessToJobObject(job, created.hProcess)',
        'ResumeThread(created.hThread)',
        'output_limit_exceeded',
        'process_job_not_empty',
        'function Set-GuiSmokeFailureDetail',
        'error_detail = $null',
        '$row.job_cleanup = $true',
        'job_active_processes_at_primary_exit',
        'WaitForEmpty(1000)',
        'GetSoleActiveProcessId()',
        'uint bufferLength = (uint)(8 + IntPtr.Size);',
        'if (error == 122 || error == 234) return -1;',
        'if (assigned > 1 || listed > 1) return -1;',
        'if (listed == 0) return 0;',
        'public uint LastProcessListAssigned;',
        'public uint LastProcessListListed;',
        'public int LastProcessListError;',
        'sole_process_name = $null',
        'Get-Process -Id ([int]$soleActiveProcessId) -ErrorAction Stop',
        '$State.job_process_snapshot.query_error = [int]$State.owner.LastProcessListError',
        'process_job_snapshot = $State.job_process_snapshot',
        'function Set-ProcessCleanupFailureReason',
        'if ($soleActiveProcessId -lt 0)',
        '-not $State.job_had_survivors',
        '[System.IO.FileSystemAclExtensions]::CreateDirectory($security, $path)',
        'job_cleanup = $false',
        'AggregateOutputLimitBytes =',
        '$script:VmTestOutputAggregateLimitBytes',
        'aggregate_output_limit_bytes = $AggregateOutputLimitBytes',
        'Protect-CurrentRunnerProcess',
        'medium-boundary-probe.stdout.log',
        'medium-boundary-probe.stderr.log',
        'BOUNDARY_PROBE_FAILURE type={0} native_error={1} message={2}',
        '-AggregateOutputLimitBytes $probeOutputLimitBytes',
        '$probeSucceeded = $false',
        '$state.owner.WaitForCapture(10000)',
        'Get-CapturedOutputBytes -Path $channel.path',
        'medium integrity child could access or could not verify observer process/thread boundaries.',
        '$probeSucceeded = $true',
        'if ($probeSucceeded)',
        'Remove-Item -LiteralPath $stdoutPath, $stderrPath, $probeScriptPath',
        'PROCESS_WRITE_DAC',
        'ProtectCurrentProcess(string runnerSid)',
        'new System.Security.Principal.SecurityIdentifier(runnerSid).Value',
        'D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x00101000;;;',
        'validatedRunnerSid + ',
        ')(A;;0x00101000;;;OW)',
        '[Security.Principal.WindowsIdentity]::GetCurrent().User.Value',
        '[DarkReNamerVmRunnerSecurity]::ProtectCurrentProcess($runnerSid)',
        'PROTECTED_DACL_SECURITY_INFORMATION',
        'Initialize-TrustedResultWriter',
        'CreateTrustedResultFile(string path, bool createNew)',
        'const uint CREATE_NEW = 1;',
        'createNew ? CREATE_NEW : OPEN_EXISTING',
        '$trustedPath, -not $elevatedObserver)',
        'ProtectResultFile($writer.SafeFileHandle, $runnerSid)',
        'D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;',
        'function New-ObserverFixtureDirectory',
        'function New-ObserverCandidateWriteDirectory',
        'FileSystemRights]::DeleteSubdirectoriesAndFiles',
        'FileSystemRights]::Modify',
        'ObjectInherit',
        'InheritOnly',
        '[IO.FileMode]::CreateNew',
        '[IO.FileShare]::Read'
    )) {
        if ($runnerText.IndexOf($requiredJobSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The guest process containment contract is missing '$requiredJobSource'."
        }
    }
    $guiProcessStartIndex = $runnerText.IndexOf(
        '$processState.process = Start-JobBoundProcess',
        [StringComparison]::Ordinal
    )
    $guiProcessLifecycleIndex = $runnerText.IndexOf(
        '$row[''process_lifecycle''] = [ordered]@{',
        $guiProcessStartIndex,
        [StringComparison]::Ordinal
    )
    $guiRawEvidenceIndex = $runnerText.IndexOf(
        'if ($RawEvidence) {',
        $guiProcessStartIndex,
        [StringComparison]::Ordinal
    )
    if ($guiProcessStartIndex -lt 0 -or
        $guiProcessLifecycleIndex -le $guiProcessStartIndex -or
        $guiRawEvidenceIndex -le $guiProcessLifecycleIndex) {
        throw 'Every started GUI process must record its PID and creation time before optional raw-evidence enrichment.'
    }
    $preservedCleanupFailure = [ordered]@{
        failure_reason = 'process_job_not_empty'
        cleanup_failure_reason = $null
    }
    Set-ProcessCleanupFailureReason -Row $preservedCleanupFailure -Reason 'process_job_cleanup_failed'
    $primaryCleanupFailure = [ordered]@{
        failure_reason = $null
        cleanup_failure_reason = $null
    }
    Set-ProcessCleanupFailureReason -Row $primaryCleanupFailure -Reason 'process_job_cleanup_failed'
    if ($preservedCleanupFailure.failure_reason -cne 'process_job_not_empty' -or
        $preservedCleanupFailure.cleanup_failure_reason -cne 'process_job_cleanup_failed' -or
        $primaryCleanupFailure.failure_reason -cne 'process_job_cleanup_failed' -or
        $primaryCleanupFailure.cleanup_failure_reason) {
        throw 'Cleanup failures must preserve an earlier process failure reason and retain cleanup failure separately.'
    }
    $guiFailureDetail = [ordered]@{ error_detail = $null }
    try { throw [ComponentModel.Win32Exception]::new(5) }
    catch {
        Set-GuiSmokeFailureDetail -Row $guiFailureDetail -ErrorRecord $_
    }
    if ($guiFailureDetail.error_detail.exception_type -cne 'System.ComponentModel.Win32Exception' -or
        $guiFailureDetail.error_detail.native_error -ne 5 -or
        $guiFailureDetail.error_detail.message.Length -gt 1024) {
        throw 'GUI smoke failure details must preserve exception type and native error in a bounded record.'
    }
    $longGuiFailureDetail = [ordered]@{ error_detail = $null }
    try { throw [Exception]::new('x' * 2048) }
    catch {
        Set-GuiSmokeFailureDetail -Row $longGuiFailureDetail -ErrorRecord $_
    }
    if ($longGuiFailureDetail.error_detail.message.Length -ne 1024) {
        throw 'GUI smoke failure messages must be capped at 1024 characters.'
    }
    if ($runnerText.Contains('maximumProcessIds') -or
        $runnerText.Contains('capacity = capacity * 2')) {
        throw 'The sole-process Job Object query must not retry a multi-PID snapshot with a larger buffer.'
    }
    $noCapturePaths = Resolve-JobBoundCapturePaths -BoundParameters ([ordered]@{})
    if ($null -ne $noCapturePaths.stdout_path -or $null -ne $noCapturePaths.stderr_path) {
        throw 'An unredirected process must receive null capture paths.'
    }
    $capturePathParameters = [ordered]@{
        StdoutPath = $true
        StderrPath = $true
    }
    $capturePaths = Resolve-JobBoundCapturePaths `
        -BoundParameters $capturePathParameters `
        -StdoutPath 'stdout.log' `
        -StderrPath 'stderr.log'
    if ($capturePaths.stdout_path -cne 'stdout.log' -or
        $capturePaths.stderr_path -cne 'stderr.log') {
        throw 'Redirected process capture paths were not retained.'
    }
    Assert-Fails {
        Resolve-JobBoundCapturePaths `
            -BoundParameters ([ordered]@{ StdoutPath = $true }) `
            -StdoutPath 'stdout.log'
    } 'both output paths'
    Assert-Fails {
        Resolve-JobBoundCapturePaths `
            -BoundParameters $capturePathParameters `
            -StdoutPath ' ' `
            -StderrPath 'stderr.log'
    } 'both output paths'
    $aclAwareDirectoryCalls = [regex]::Matches(
        $runnerText,
        [regex]::Escape('[System.IO.FileSystemAclExtensions]::CreateDirectory($security, $path)')
    ).Count
    if ($aclAwareDirectoryCalls -ne 2 -or
        $runnerText.IndexOf(
            '[IO.Directory]::CreateDirectory($path, $security)',
            [StringComparison]::Ordinal
        ) -ge 0) {
        throw 'Observer directories must use the .NET Core ACL-aware directory creation API.'
    }
    foreach ($flowFixtureContract in @(
        "if (`$RawEvidence -and [string]::IsNullOrWhiteSpace(`$FixtureParentRoot)) {",
        '$flowFixtureParent = if ($FixtureParentRoot) { $FixtureParentRoot } else { $caseRoot }',
        '-Parent $flowFixtureParent',
        "-Leaf 'production-flow-fixture'"
    )) {
        if ($runnerText.IndexOf($flowFixtureContract, [StringComparison]::Ordinal) -lt 0) {
            throw "The production flow fixture escaped the protected task parent: $flowFixtureContract"
        }
    }
    $tokenStatisticsStartIndex = $runnerText.IndexOf(
        'private struct TokenStatistics {',
        [StringComparison]::Ordinal
    )
    if ($tokenStatisticsStartIndex -lt 0) {
        throw 'The native TOKEN_STATISTICS structure declaration is missing.'
    }
    $tokenIdFieldIndex = $runnerText.IndexOf(
        'public Luid TokenId;',
        $tokenStatisticsStartIndex,
        [StringComparison]::Ordinal
    )
    $authenticationIdFieldIndex = $runnerText.IndexOf(
        'public Luid AuthenticationId;',
        $tokenStatisticsStartIndex,
        [StringComparison]::Ordinal
    )
    $expirationTimeFieldIndex = $runnerText.IndexOf(
        'public long ExpirationTime;',
        $tokenStatisticsStartIndex,
        [StringComparison]::Ordinal
    )
    if ($tokenIdFieldIndex -le $tokenStatisticsStartIndex -or
        $authenticationIdFieldIndex -le $tokenIdFieldIndex -or
        $expirationTimeFieldIndex -le $authenticationIdFieldIndex) {
        throw 'TOKEN_STATISTICS fields must match the native TokenId, AuthenticationId, ExpirationTime order.'
    }
    if ($runnerText.IndexOf(
        '-Parent $OutputRoot -Leaf ''production-flow-fixture''',
        [StringComparison]::Ordinal
    ) -ge 0) {
        throw 'The production flow fixture must remain outside the protected result directory.'
    }
    $assignIndex = $runnerText.IndexOf(
        'AssignProcessToJobObject(job, created.hProcess)',
        [StringComparison]::Ordinal
    )
    $createWithTokenIndex = $runnerText.IndexOf(
        'CreateProcessWithTokenW(observerToken, 0, filePath',
        [StringComparison]::Ordinal
    )
    $observerAuthenticationCaptureIndex = $runnerText.IndexOf(
        'observerAuthenticationId = ReadTokenStatistics(observerToken).AuthenticationId;',
        [StringComparison]::Ordinal
    )
    $observerDesktopCheckIndex = $runnerText.IndexOf(
        'DarkReNamerVmRunnerSecurity.AssertDefaultObserverDesktop();',
        [StringComparison]::Ordinal
    )
    $childTokenIndex = $runnerText.IndexOf(
        'RequireCreatedChild(created.hProcess, observerSession, observerUserSid, observerAuthenticationId)',
        [StringComparison]::Ordinal
    )
    $resumeIndex = $runnerText.IndexOf(
        'ResumeThread(created.hThread)',
        [StringComparison]::Ordinal
    )
    if ($observerDesktopCheckIndex -lt 0 -or
        $observerDesktopCheckIndex -ge $createWithTokenIndex -or
        $observerAuthenticationCaptureIndex -lt 0 -or
        $createWithTokenIndex -le $observerAuthenticationCaptureIndex -or
        $assignIndex -le $createWithTokenIndex -or
        $childTokenIndex -le $assignIndex -or $resumeIndex -le $childTokenIndex -or
        $runnerText.IndexOf('CREATE_BREAKAWAY_FROM_JOB', [StringComparison]::Ordinal) -ge 0 -or
        $runnerText.IndexOf('JOB_OBJECT_LIMIT_BREAKAWAY_OK', [StringComparison]::Ordinal) -ge 0 -or
        $runnerText.IndexOf('JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK', [StringComparison]::Ordinal) -ge 0) {
        throw 'The verified desktop and token must be checked before the suspended child enters its job.'
    }
    if ($runnerText.IndexOf(
        'startup.StartupInfo.lpDesktop =',
        [StringComparison]::Ordinal
    ) -ge 0) {
        throw 'The verified medium child must inherit the interactive task desktop.'
    }
    $attributeListInitIndex = $runnerText.IndexOf(
        'InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeSize);',
        [StringComparison]::Ordinal
    )
    $attributeListGateIndex = $runnerText.LastIndexOf(
        'if (!elevatedObserver) {',
        $attributeListInitIndex,
        [StringComparison]::Ordinal
    )
    $handleListUpdateIndex = $runnerText.IndexOf(
        'new IntPtr(HANDLE_LIST_ATTRIBUTE), handleList,',
        $attributeListInitIndex,
        [StringComparison]::Ordinal
    )
    $mediumProbeStartIndex = $runnerText.IndexOf(
        'function Test-MediumObserverBoundary {',
        [StringComparison]::Ordinal
    )
    $mediumProbeEndIndex = $runnerText.IndexOf(
        'function Stop-JobBoundProcess {',
        $mediumProbeStartIndex,
        [StringComparison]::Ordinal
    )
    if ($attributeListInitIndex -lt 0 -or $attributeListGateIndex -lt 0 -or
        $attributeListInitIndex -le $attributeListGateIndex -or
        $handleListUpdateIndex -le $attributeListInitIndex -or
        $mediumProbeStartIndex -lt 0 -or $mediumProbeEndIndex -le $mediumProbeStartIndex) {
        throw 'The elevated token launch must avoid the inherited-handle attribute list.'
    }
    $mediumProbeSource = $runnerText.Substring(
        $mediumProbeStartIndex,
        $mediumProbeEndIndex - $mediumProbeStartIndex
    )
    $probeStageIndex = $mediumProbeSource.IndexOf(
        "[IO.FileMode]::CreateNew",
        [StringComparison]::Ordinal
    )
    $probeLaunchIndex = $mediumProbeSource.IndexOf(
        '-Arguments (''-NoLogo -NoProfile -NonInteractive -File "',
        [StringComparison]::Ordinal
    )
    if ($mediumProbeSource.IndexOf('-EncodedCommand', [StringComparison]::Ordinal) -ge 0 -or
        $mediumProbeSource.IndexOf("'.ps1'", [StringComparison]::Ordinal) -lt 0 -or
        $probeStageIndex -lt 0 -or $probeLaunchIndex -le $probeStageIndex) {
        throw 'The medium observer boundary script must be staged as a short -File launch.'
    }
    $shellWindowIndex = $runnerText.IndexOf(
        'IntPtr shellWindow = GetShellWindow();',
        [StringComparison]::Ordinal
    )
    $shellProcessIndex = $runnerText.IndexOf(
        'shellProcess = OpenProcess(',
        [StringComparison]::Ordinal
    )
    $shellImageIndex = $runnerText.IndexOf(
        'string imagePath = GetProcessImagePath(shellProcess);',
        [StringComparison]::Ordinal
    )
    $shellTokenIndex = $runnerText.IndexOf(
        'OpenProcessToken(shellProcess, desiredAccess, out shellToken)',
        [StringComparison]::Ordinal
    )
    $shellAuthenticationIndex = $runnerText.IndexOf(
        'SameLuid(linkedAuthenticationId, shellAuthenticationId)',
        [StringComparison]::Ordinal
    )
    $linkedAuthenticationReadIndex = $runnerText.IndexOf(
        'ReadTokenStatistics(linkedToken).AuthenticationId',
        [StringComparison]::Ordinal
    )
    $shellAuthenticationReadIndex = $runnerText.IndexOf(
        'Luid shellAuthenticationId = shellStatistics.AuthenticationId;',
        [StringComparison]::Ordinal
    )
    $duplicateShellTokenIndex = $runnerText.IndexOf(
        'DuplicateTokenEx(shellToken, desiredAccess, IntPtr.Zero,',
        [StringComparison]::Ordinal
    )
    $duplicateAuthenticationCheckIndex = $runnerText.IndexOf(
        'SameLuid(linkedAuthenticationId,',
        $duplicateShellTokenIndex,
        [StringComparison]::Ordinal
    )
    $duplicateTokenIdentityCheckIndex = $runnerText.IndexOf(
        'SameLuid(shellStatistics.TokenId, primaryStatistics.TokenId)',
        $duplicateShellTokenIndex,
        [StringComparison]::Ordinal
    )
    if ($shellWindowIndex -lt 0 -or $shellProcessIndex -le $shellWindowIndex -or
        $shellImageIndex -le $shellProcessIndex -or $shellTokenIndex -le $shellImageIndex -or
        $linkedAuthenticationReadIndex -le $shellTokenIndex -or
        $shellAuthenticationReadIndex -le $linkedAuthenticationReadIndex -or
        $shellAuthenticationIndex -le $shellAuthenticationReadIndex -or
        $duplicateShellTokenIndex -le $shellAuthenticationIndex -or
        $duplicateTokenIdentityCheckIndex -le $duplicateShellTokenIndex -or
        $duplicateAuthenticationCheckIndex -le $duplicateShellTokenIndex -or
        $runnerText.IndexOf('ReadTokenStatistics(current).AuthenticationId', [StringComparison]::Ordinal) -ge 0) {
        throw 'The medium observer must duplicate the verified interactive shell token and retain its logon binding.'
    }
    $suiteBudgetStartIndex = $runnerText.IndexOf(
        '$remainingSuiteOutputBytes = [long]$script:VmTestOutputSuiteLimitBytes',
        [StringComparison]::Ordinal
    )
    $perTestBudgetIndex = $runnerText.IndexOf(
        '$testOutputBudgetBytes = [Math]::Min(',
        $suiteBudgetStartIndex,
        [StringComparison]::Ordinal
    )
    $budgetedTestIndex = $runnerText.IndexOf(
        '-OutputBudgetBytes $testOutputBudgetBytes',
        $perTestBudgetIndex,
        [StringComparison]::Ordinal
    )
    $suiteBudgetDecreaseIndex = $runnerText.IndexOf(
        '$remainingSuiteOutputBytes -= $testOutputBytes',
        $budgetedTestIndex,
        [StringComparison]::Ordinal
    )
    if ($suiteBudgetStartIndex -lt 0 -or $perTestBudgetIndex -le $suiteBudgetStartIndex -or
        $budgetedTestIndex -le $perTestBudgetIndex -or
        $suiteBudgetDecreaseIndex -le $budgetedTestIndex) {
        throw 'Each guest test must receive and consume the remaining suite output budget before another test starts.'
    }
    if ($runnerText.IndexOf(
        'journal_after = [ordered]@{ entries = @() }',
        [StringComparison]::Ordinal
    ) -ge 0) {
        throw 'Candidate cleanup must not serialize an unobserved journal as an empty inventory.'
    }
    foreach ($requiredRawSource in @(
        'GetFileInformationByHandleEx(',
        'information.VolumeSerialNumber.ToString("x16")',
        'FormatFileIdNumeric(information.FileId.LowPart, information.FileId.HighPart)',
        'Get-VmAutomatedCanonicalRootPath -Path $FixtureRoot',
        'product_type = [int]$operatingSystem.ProductType',
        'root_identity = Get-FullFileIdentity -Path $rootPath',
        'is_elevated = [bool][DarkReNamerVmNative]::IsProcessElevated',
        'input_desktop_active = $desktopAvailable',
        'high_contrast_flags = [long][DarkReNamerVmNative]::GetHighContrastFlags()'
        "exit_method = 'normal-close'"
        "exit_method = 'forced-termination'"
        "`$result['raw_cleanup'] = [ordered]@{"
        'Get-VmAutomatedOwnedProcessCleanupObservation'
        'owned_processes_observation_error'
        "'owned_process_cleanup_observation_failed'"
        '-RawEvidence:$candidateLane'
    )) {
        if ($runnerText.IndexOf($requiredRawSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The shared VM-Automated raw contract is missing '$requiredRawSource'."
        }
    }
    $guestFinalizerAst = [Management.Automation.Language.Parser]::ParseInput(
        $runnerText, [ref]$null, [ref]$null
    )
    $guestEntryFunction = $guestFinalizerAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-DrWindowsVmGuest'
    }, $true)
    $guestPublishingFinalizers = @($guestEntryFunction.FindAll({
        param($node)
        $node -is [Management.Automation.Language.TryStatementAst] -and
            $null -ne $node.Finally -and
            $node.Finally.Extent.Text.IndexOf(
                'Write-ResultDocument', [StringComparison]::Ordinal
            ) -ge 0
    }, $true))
    if ($guestPublishingFinalizers.Count -ne 1) {
        throw 'Expected one publishing finalizer in the Windows VM guest entrypoint.'
    }
    $guestFinalizerText = $guestPublishingFinalizers[0].Finally.Extent.Text
    $guestFinalizer = [scriptblock]::Create(
        $guestFinalizerText.Substring(1, $guestFinalizerText.Length - 2)
    )
    function Invoke-CoreGuestFinalizerFixture {
        param(
            [Parameter(Mandatory)][scriptblock] $Finalizer,
            [Parameter(Mandatory)][ValidateSet('passed', 'failed')][string] $InitialStatus,
            [AllowNull()][string] $InitialFailureReason
        )

        & {
            $caseRoot = Join-Path $temporaryRoot (
                'core-finalizer-' + [Guid]::NewGuid().ToString('N')
            )
            [void](New-Item -ItemType Directory -Path $caseRoot)
            $effectiveRuntimeRoot = Join-Path $caseRoot 'retained-runtime'
            [void](New-Item -ItemType Directory -Path $effectiveRuntimeRoot)
            $retainedPath = Join-Path $effectiveRuntimeRoot 'retained.txt'
            [IO.File]::WriteAllText($retainedPath, 'retain on incomplete inventory')
            $hasInitialFailure = -not [string]::IsNullOrEmpty($InitialFailureReason)
            $result = [ordered]@{
                status = $InitialStatus
                failure_reason = if ($hasInitialFailure) { $InitialFailureReason } else { $null }
                gui = $null
                raw_cleanup = $null
            }
            $candidateLane = $true
            $verified = [pscustomobject]@{ root = $caseRoot }
            $previousExecutionState = $null
            $desktopLock = $null
            $ledgerProbe = [ordered]@{ called = $false }
            $inventoryFailureMessage = 'injected core CIM cleanup failure'
            function Get-CimInstance {
                [CmdletBinding()]
                param([Parameter(Position = 0)][string] $ClassName)
                throw $inventoryFailureMessage
            }
            function Get-VmAutomatedJournalInventory { param($LocalAppData) @() }
            function Assert-AcceptanceProcessJobLedgerClosed {
                $ledgerProbe.called = $true
            }
            function Exit-TestExecutionState { param($Previous) }
            function Exit-DesktopTestLock { param($Lock) }

            $resultPath = Join-Path $caseRoot 'result.json'
            $script:protectedResultFixturePaths.Add($resultPath)
            Initialize-TrustedResultWriter -Root $verified.root
            . $Finalizer
            $publishedResult = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json

            [pscustomobject]@{
                result = $result
                result_published = (Test-Path -LiteralPath $resultPath -PathType Leaf)
                published_result = $publishedResult
                ledger_called = $ledgerProbe.called
                runtime_retained = (Test-Path -LiteralPath $effectiveRuntimeRoot -PathType Container)
                sentinel_retained = (Test-Path -LiteralPath $retainedPath -PathType Leaf)
                inventory_failure_message = $inventoryFailureMessage
            }
        }
    }
    $coreFailedResult = Invoke-CoreGuestFinalizerFixture `
        -Finalizer $guestFinalizer `
        -InitialStatus failed `
        -InitialFailureReason original_core_failure
    if (-not $coreFailedResult.result_published -or
        $coreFailedResult.published_result.status -cne 'failed' -or
        $coreFailedResult.published_result.failure_reason -cne 'original_core_failure' -or
        $null -ne $coreFailedResult.published_result.raw_cleanup.owned_processes_after -or
        $coreFailedResult.published_result.raw_cleanup.owned_processes_observation_error.message -cne
            $coreFailedResult.inventory_failure_message -or
        -not $coreFailedResult.runtime_retained -or
        -not $coreFailedResult.sentinel_retained -or
        $coreFailedResult.ledger_called) {
        throw 'The core finalizer did not publish and retain evidence after an unobserved inventory.'
    }
    $corePassingResult = Invoke-CoreGuestFinalizerFixture `
        -Finalizer $guestFinalizer `
        -InitialStatus passed `
        -InitialFailureReason $null
    if (-not $corePassingResult.result_published -or
        $corePassingResult.published_result.status -cne 'failed' -or
        $corePassingResult.published_result.failure_reason -cne
            'owned_process_cleanup_observation_failed' -or
        $null -ne $corePassingResult.published_result.raw_cleanup.owned_processes_after -or
        $corePassingResult.published_result.raw_cleanup.owned_processes_observation_error.message -cne
            $corePassingResult.inventory_failure_message -or
        -not $corePassingResult.runtime_retained -or
        -not $corePassingResult.sentinel_retained -or
        $corePassingResult.ledger_called) {
        throw 'The core finalizer did not fail closed after an unobserved inventory.'
    }
    $accountingScript = Join-Path $valid.root 'accounting-grace.ps1'
    $accountingStdoutPath = Join-Path $valid.root 'accounting-grace.stdout.log'
    $accountingStderrPath = Join-Path $valid.root 'accounting-grace.stderr.log'
    [IO.File]::WriteAllText(
        $accountingScript,
        'Start-Sleep -Milliseconds 75',
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllBytes($accountingStdoutPath, [byte[]]@())
    [IO.File]::WriteAllBytes($accountingStderrPath, [byte[]]@())
    $accountingStartInfo = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $accountingStartInfo.UseShellExecute = $false
    $accountingStartInfo.CreateNoWindow = $true
    $accountingStartInfo.WorkingDirectory = $valid.root
    [void]$accountingStartInfo.ArgumentList.Add('-NoLogo')
    [void]$accountingStartInfo.ArgumentList.Add('-NoProfile')
    [void]$accountingStartInfo.ArgumentList.Add('-NonInteractive')
    [void]$accountingStartInfo.ArgumentList.Add('-File')
    [void]$accountingStartInfo.ArgumentList.Add($accountingScript)
    $accountingProcess = $null
    try {
        $accountingProcess = [Diagnostics.Process]::Start($accountingStartInfo)
        $accountingOwner = [pscustomobject]@{
            active_processes = 1
            sole_active_process_id = [long]$accountingProcess.Id
            LastProcessListAssigned = [uint32]1
            LastProcessListListed = [uint32]1
            LastProcessListError = 0
            process_list_queries = 0
            hold_active_processes = $false
            throw_on_process_list = $false
            OutputLimitExceeded = $false
        }
        Add-Member -InputObject $accountingOwner -MemberType ScriptProperty -Name ActiveProcessCount -Value { [int]$this.active_processes } -Force
        Add-Member -InputObject $accountingOwner -MemberType ScriptMethod -Name WaitForEmpty -Value {
            param([int] $Milliseconds)
            if ($this.active_processes -gt 0 -and -not $this.hold_active_processes) {
                Start-Sleep -Milliseconds 25
                $this.active_processes = 0
            }
            return $this.active_processes -eq 0
        } -Force
        Add-Member -InputObject $accountingOwner -MemberType ScriptMethod -Name GetSoleActiveProcessId -Value {
            $this.process_list_queries++
            if ($this.throw_on_process_list) {
                $this.LastProcessListError = 5
                throw [ComponentModel.Win32Exception]::new(5)
            }
            return [long]$this.sole_active_process_id
        } -Force
        Add-Member -InputObject $accountingOwner -MemberType ScriptMethod -Name WaitForCapture -Value { param([int] $Milliseconds) } -Force
        Add-Member -InputObject $accountingOwner -MemberType ScriptMethod -Name Terminate -Value { $this.active_processes = 0 } -Force
        Add-Member -InputObject $accountingOwner -MemberType ScriptMethod -Name CloseJob -Value { return $true } -Force
        $accountingState = [pscustomobject]@{
            process = $accountingProcess
            owner = $accountingOwner
            aggregate_output_limit_bytes = [long]4096
            job_active_processes_at_primary_exit = $null
            job_process_snapshot = $null
            job_had_survivors = $false
            job_forced_termination = $false
            job_active_processes_at_close = $null
            job_empty = $false
            job_closed = $false
            job_capture_complete = $false
        }
        $accountingResult = Wait-JobBoundProcessWithOutputLimit -State $accountingState -StdoutPath $accountingStdoutPath -StderrPath $accountingStderrPath -TimeoutSeconds 10
        if ($accountingResult.failure_reason -or
            $accountingResult.active_processes_at_primary_exit -ne 1 -or
            $accountingOwner.ActiveProcessCount -ne 0 -or
            $accountingState.job_had_survivors -or
            $accountingResult.process_job_snapshot.primary_pid -ne $accountingProcess.Id -or
            $accountingResult.process_job_snapshot.sole_pid -ne $accountingProcess.Id -or
            $accountingResult.process_job_snapshot.assigned -ne 1 -or
            $accountingResult.process_job_snapshot.listed -ne 1 -or
            $accountingResult.process_job_snapshot.active_after_grace -ne 0) {
            throw 'A transient Job Object accounting delay was classified as a surviving process.'
        }
        if (-not (Close-JobBoundProcess -State $accountingState)) {
            throw 'The process job did not close cleanly after accounting settled.'
        }
        $accountingOwner.active_processes = 1
        $accountingOwner.sole_active_process_id = 0
        $accountingOwner.LastProcessListListed = [uint32]0
        $emptyListAccountingState = [pscustomobject]@{
            process = $accountingProcess
            owner = $accountingOwner
            aggregate_output_limit_bytes = [long]4096
            job_active_processes_at_primary_exit = $null
            job_process_snapshot = $null
            job_had_survivors = $false
            job_forced_termination = $false
            job_active_processes_at_close = $null
            job_empty = $false
            job_closed = $false
            job_capture_complete = $false
        }
        $emptyListAccountingResult = Wait-JobBoundProcessWithOutputLimit `
            -State $emptyListAccountingState `
            -StdoutPath $accountingStdoutPath `
            -StderrPath $accountingStderrPath `
            -TimeoutSeconds 10
        if ($emptyListAccountingResult.failure_reason -or
            $emptyListAccountingResult.active_processes_at_primary_exit -ne 1 -or
            $accountingOwner.ActiveProcessCount -ne 0 -or
            $emptyListAccountingState.job_had_survivors -or
            $emptyListAccountingResult.process_job_snapshot.sole_pid -ne 0 -or
            $emptyListAccountingResult.process_job_snapshot.assigned -ne 1 -or
            $emptyListAccountingResult.process_job_snapshot.listed -ne 0 -or
            $emptyListAccountingResult.process_job_snapshot.active_after_grace -ne 0) {
            throw 'An empty live PID snapshot during Job Object accounting lag was classified as a survivor.'
        }
        if (-not (Close-JobBoundProcess -State $emptyListAccountingState)) {
            throw 'The process job did not close cleanly after an empty accounting snapshot.'
        }
        $accountingOwner.active_processes = 1
        $accountingOwner.throw_on_process_list = $true
        $queryErrorAccountingState = [pscustomobject]@{
            process = $accountingProcess
            owner = $accountingOwner
            aggregate_output_limit_bytes = [long]4096
            job_active_processes_at_primary_exit = $null
            job_process_snapshot = $null
            job_had_survivors = $false
            job_forced_termination = $false
            job_active_processes_at_close = $null
            job_empty = $false
            job_closed = $false
            job_capture_complete = $false
        }
        $queryErrorMessage = $null
        try {
            [void](Wait-JobBoundProcessWithOutputLimit `
                -State $queryErrorAccountingState `
                -StdoutPath $accountingStdoutPath `
                -StderrPath $accountingStderrPath `
                -TimeoutSeconds 10)
        }
        catch { $queryErrorMessage = $_.Exception.Message }
        $accountingOwner.active_processes = 0
        $accountingOwner.throw_on_process_list = $false
        if (-not $queryErrorMessage -or
            $queryErrorAccountingState.job_process_snapshot.primary_pid -ne $accountingProcess.Id -or
            $queryErrorAccountingState.job_process_snapshot.sole_pid -ne $null -or
            $queryErrorAccountingState.job_process_snapshot.query_error -ne 5) {
            throw 'An unexpected Job Object query error was not retained in the process snapshot.'
        }
        if (-not (Close-JobBoundProcess -State $queryErrorAccountingState)) {
            throw 'The process job did not close after the query-error fixture settled.'
        }
        $zeroActiveAccountingState = [pscustomobject]@{
            process = $accountingProcess
            owner = $accountingOwner
            aggregate_output_limit_bytes = [long]4096
            job_active_processes_at_primary_exit = $null
            job_process_snapshot = $null
            job_had_survivors = $false
            job_forced_termination = $false
            job_active_processes_at_close = $null
            job_empty = $false
            job_closed = $false
            job_capture_complete = $false
        }
        $zeroActiveAccountingResult = Wait-JobBoundProcessWithOutputLimit `
            -State $zeroActiveAccountingState `
            -StdoutPath $accountingStdoutPath `
            -StderrPath $accountingStderrPath `
            -TimeoutSeconds 10
        if ($zeroActiveAccountingResult.failure_reason -or
            $zeroActiveAccountingResult.active_processes_at_primary_exit -ne 0 -or
            $null -ne $zeroActiveAccountingResult.process_job_snapshot -or
            $accountingOwner.process_list_queries -ne 3 -or
            $zeroActiveAccountingState.job_had_survivors) {
            throw 'A zero Job Object active count must not be treated as a missing PID snapshot.'
        }
        if (-not (Close-JobBoundProcess -State $zeroActiveAccountingState)) {
            throw 'The process job did not close cleanly after a zero active count.'
        }
        $accountingOwner.active_processes = 1
        $accountingOwner.sole_active_process_id = [long]($accountingProcess.Id + 1000000)
        $accountingOwner.LastProcessListAssigned = [uint32]1
        $accountingOwner.LastProcessListListed = [uint32]1
        $differentPidAccountingState = [pscustomobject]@{
            process = $accountingProcess
            owner = $accountingOwner
            aggregate_output_limit_bytes = [long]4096
            job_active_processes_at_primary_exit = $null
            job_process_snapshot = $null
            job_had_survivors = $false
            job_active_processes_at_stop = $null
            job_forced_termination = $false
            job_active_processes_at_close = $null
            job_empty = $false
            job_closed = $false
            job_capture_complete = $false
        }
        $differentPidAccountingResult = Wait-JobBoundProcessWithOutputLimit `
            -State $differentPidAccountingState `
            -StdoutPath $accountingStdoutPath `
            -StderrPath $accountingStderrPath `
            -TimeoutSeconds 10
        if ($differentPidAccountingResult.failure_reason -or
            $differentPidAccountingResult.active_processes_at_primary_exit -ne 1 -or
            $accountingOwner.ActiveProcessCount -ne 0 -or
            $differentPidAccountingState.job_had_survivors -or
            $differentPidAccountingResult.process_job_snapshot.primary_pid -ne $accountingProcess.Id -or
            $differentPidAccountingResult.process_job_snapshot.sole_pid -eq $accountingProcess.Id -or
            $differentPidAccountingResult.process_job_snapshot.active_after_grace -ne 0) {
            throw 'A different sole process PID that exits during accounting grace was classified as a survivor.'
        }
        if (-not (Close-JobBoundProcess -State $differentPidAccountingState)) {
            throw 'The process job did not close after a different PID settled.'
        }
        $accountingOwner.active_processes = 1
        $accountingOwner.hold_active_processes = $true
        $accountingOwner.sole_active_process_id = [long]($accountingProcess.Id + 1000001)
        $persistentPidAccountingState = [pscustomobject]@{
            process = $accountingProcess
            owner = $accountingOwner
            aggregate_output_limit_bytes = [long]4096
            job_active_processes_at_primary_exit = $null
            job_process_snapshot = $null
            job_had_survivors = $false
            job_active_processes_at_stop = $null
            job_forced_termination = $false
            job_active_processes_at_close = $null
            job_empty = $false
            job_closed = $false
            job_capture_complete = $false
        }
        $persistentPidAccountingResult = Wait-JobBoundProcessWithOutputLimit `
            -State $persistentPidAccountingState `
            -StdoutPath $accountingStdoutPath `
            -StderrPath $accountingStderrPath `
            -TimeoutSeconds 10
        $accountingOwner.hold_active_processes = $false
        if ($persistentPidAccountingResult.failure_reason -ne 'process_job_not_empty' -or
            $persistentPidAccountingResult.process_job_snapshot.primary_pid -ne $accountingProcess.Id -or
            $persistentPidAccountingResult.process_job_snapshot.sole_pid -eq $accountingProcess.Id -or
            $persistentPidAccountingResult.process_job_snapshot.active_after_grace -ne 1 -or
            -not $persistentPidAccountingState.job_had_survivors -or
            -not $persistentPidAccountingState.job_forced_termination -or
            $accountingOwner.ActiveProcessCount -ne 0) {
            throw 'A different sole process PID that survives accounting grace was not terminated and reported.'
        }
        [void](Close-JobBoundProcess -State $persistentPidAccountingState)
        if (-not $persistentPidAccountingState.job_closed -or
            -not $persistentPidAccountingState.job_empty -or
            $persistentPidAccountingState.job_active_processes_at_close -ne 0) {
            throw 'The process job did not close after the persistent PID was terminated.'
        }
    }
    finally {
        if ($null -ne $accountingProcess) {
            try {
                $accountingProcess.Refresh()
                if (-not $accountingProcess.HasExited) {
                    $accountingProcess.Kill()
                    [void]$accountingProcess.WaitForExit(5000)
                }
            }
            catch {}
            $accountingProcess.Dispose()
        }
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-NativeCapture
        if (-not ('DarkReNamerVmRunnerSecurityProbe' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class DarkReNamerVmRunnerSecurityProbe {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr handle);
    public static int LastError { get { return Marshal.GetLastWin32Error(); } }
}
'@
        }
        $securityHelperScript = Join-Path $valid.root 'runner-security-helper.ps1'
        $securityHelperPidPath = Join-Path $valid.root 'runner-security-helper.pid'
        $securityHelperReleasePath = Join-Path $valid.root 'runner-security-helper.release'
        $productionProcessModule = Join-Path $toolingScriptsRoot 'modules/powershell/guest-process.ps1'
        [IO.File]::WriteAllText(
            $securityHelperScript,
            @'
param([string] $PidPath, [string] $ReleasePath, [string] $ProcessModule)
. $ProcessModule
Protect-CurrentRunnerProcess
[IO.File]::WriteAllText($PidPath, [string]$PID)
while (-not [IO.File]::Exists($ReleasePath)) { Start-Sleep -Milliseconds 50 }
'@,
            [Text.UTF8Encoding]::new($false)
        )
        $securityHelperProcess = Start-Process `
            -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList (
                '-NoLogo -NoProfile -NonInteractive -File "' + $securityHelperScript +
                '" "' + $securityHelperPidPath + '" "' + $securityHelperReleasePath +
                '" "' + $productionProcessModule + '"'
            ) `
            -PassThru
        try {
            $pidWait = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $securityHelperPidPath) -and
                $pidWait.Elapsed.TotalSeconds -lt 20) {
                Start-Sleep -Milliseconds 50
            }
            if (-not (Test-Path -LiteralPath $securityHelperPidPath)) {
                throw 'The process-DACL helper did not publish its process id.'
            }
            $protectedRunnerPid = [int][IO.File]::ReadAllText($securityHelperPidPath)
            $probePrincipal = [Security.Principal.WindowsPrincipal]::new(
                [Security.Principal.WindowsIdentity]::GetCurrent()
            )
            $probeIsAdministrator = $probePrincipal.IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
            if ($probeIsAdministrator) {
                Write-Host 'Administrator token detected; verifying BUILTIN\Administrators grants. Same-user denial is not tested in this context.'
            }
            foreach ($requestedAccess in @(0x00000001, 0x00000010, 0x00040000)) {
                $probeHandle = [DarkReNamerVmRunnerSecurityProbe]::OpenProcess(
                    [uint32]$requestedAccess, $false, [uint32]$protectedRunnerPid
                )
                if ($probeIsAdministrator) {
                    if ($probeHandle -eq [IntPtr]::Zero) {
                        $requestedAccessHex = '{0:x}' -f $requestedAccess
                        throw "The enabled Administrator token was denied protected runner access 0x$requestedAccessHex granted to BUILTIN\Administrators."
                    }
                    [void][DarkReNamerVmRunnerSecurityProbe]::CloseHandle($probeHandle)
                    continue
                }
                if ($probeHandle -ne [IntPtr]::Zero) {
                    [void][DarkReNamerVmRunnerSecurityProbe]::CloseHandle($probeHandle)
                    $requestedAccessHex = '{0:x}' -f $requestedAccess
                    throw "The non-administrator same-user process opened protected runner access 0x$requestedAccessHex."
                }
                $probeError = [DarkReNamerVmRunnerSecurityProbe]::LastError
                if ($probeError -ne 5) {
                    throw ('The protected runner access check returned Win32 error {0}.' -f
                        $probeError)
                }
            }
        }
        finally {
            [IO.File]::WriteAllText($securityHelperReleasePath, 'release')
            if (-not $securityHelperProcess.WaitForExit(10000)) {
                $securityHelperProcess.Kill()
                [void]$securityHelperProcess.WaitForExit(10000)
                throw 'The process-DACL helper did not exit after release.'
            }
            $securityHelperProcess.Dispose()
        }

        $trustedResultRoot = Join-Path $valid.root 'trusted-result'
        $testSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $testRootSecurity = [Security.AccessControl.DirectorySecurity]::new()
        $testRootSecurity.SetAccessRuleProtection($true, $false)
        $testRootSecurity.SetOwner($testSid)
        $testLocalRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
            [Security.AccessControl.FileSystemRights]::WriteData -bor
            [Security.AccessControl.FileSystemRights]::AppendData -bor
            [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
            [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
        $testRootSecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $testSid, $testLocalRights,
            [Security.AccessControl.AccessControlType]::Allow
        ))
        $testRootSecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $testSid,
            [Security.AccessControl.FileSystemRights]::Modify,
            [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit,
            [Security.AccessControl.PropagationFlags]::InheritOnly,
            [Security.AccessControl.AccessControlType]::Allow
        ))
        [void][System.IO.FileSystemAclExtensions]::CreateDirectory($testRootSecurity, $trustedResultRoot)
        $trustedResultPath = Join-Path $trustedResultRoot 'result.json'
        $script:protectedResultFixturePaths.Add($trustedResultPath)
        if (Test-Path -LiteralPath $trustedResultPath) {
            throw 'The direct trusted result fixture must begin without a result file.'
        }
        Initialize-TrustedResultWriter -Root $trustedResultRoot
        if (-not (Test-Path -LiteralPath $trustedResultPath -PathType Leaf)) {
            throw 'The direct trusted result writer did not atomically create its missing destination.'
        }
        $readBlockedByShare = $false
        $contendingReader = $null
        try {
            # Read is allowed by the protected DACL; exclusive sharing must fail.
            $contendingReader = [IO.File]::Open(
                $trustedResultPath, [IO.FileMode]::Open,
                [IO.FileAccess]::Read, [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            if (($_.Exception.HResult -band 0xffff) -ne 32) { throw }
            $readBlockedByShare = $true
        }
        finally {
            if ($null -ne $contendingReader) { $contendingReader.Dispose() }
        }
        if (-not $readBlockedByShare) {
            throw 'The retained result handle allowed an exclusive same-user reader.'
        }
        Write-ResultDocument -Root $trustedResultRoot -Result ([ordered]@{
            schema_version = 1
            status = 'failed'
            failure_reason = 'security_test'
        })
        $trustedResult = [IO.File]::ReadAllText($trustedResultPath) | ConvertFrom-Json
        if ($trustedResult.status -cne 'failed' -or
            $trustedResult.failure_reason -cne 'security_test') {
            throw 'The trusted result writer did not persist its own final document.'
        }
        $writeBlockedByDacl = $false
        try {
            [IO.File]::WriteAllText($trustedResultPath, '{"status":"forged"}')
        }
        catch [UnauthorizedAccessException] {
            $writeBlockedByDacl = $true
        }
        if ($probeIsAdministrator -and $writeBlockedByDacl) {
            throw 'The enabled Administrator token was denied the trusted result file access granted to BUILTIN\Administrators.'
        }
        if (-not $probeIsAdministrator -and -not $writeBlockedByDacl) {
            throw 'The closed result file remained writable by the same user.'
        }
        $deleteBlockedByDacl = $false
        try {
            Remove-Item -LiteralPath $trustedResultPath -Force
        }
        catch [UnauthorizedAccessException] {
            $deleteBlockedByDacl = $true
        }
        if ($probeIsAdministrator -and $deleteBlockedByDacl) {
            throw 'The enabled Administrator token could not remove the trusted result file granted to BUILTIN\Administrators.'
        }
        if (-not $probeIsAdministrator -and -not $deleteBlockedByDacl) {
            throw 'The same user removed the trusted result through its bundle directory.'
        }

        $directExistingRoot = Join-Path $valid.root 'trusted-result-direct-existing'
        [void](New-Item -ItemType Directory -Path $directExistingRoot)
        $directExistingPath = Join-Path $directExistingRoot 'result.json'
        [IO.File]::WriteAllText($directExistingPath, '{}', [Text.UTF8Encoding]::new($false))
        Assert-Win32Failure -NativeErrorCode 80 `
            -Label 'Direct existing trusted result creation' `
            -Action {
            Initialize-TrustedResultWriter -Root $directExistingRoot
        }

        $managedResultRoot = Join-Path $valid.root 'trusted-result-managed'
        [void](New-Item -ItemType Directory -Path $managedResultRoot)
        $managedResultPath = Join-Path $managedResultRoot 'result.json'
        $script:protectedResultFixturePaths.Add($managedResultPath)
        [IO.File]::WriteAllText($managedResultPath, '{}', [Text.UTF8Encoding]::new($false))
        $managedIdentityBefore = Get-FullFileIdentity -Path $managedResultPath
        $missingManagedResultPath = Join-Path $managedResultRoot 'missing-result.json'
        $previousElevatedObserver = [Environment]::GetEnvironmentVariable(
            'DARKRENAMER_VM_ELEVATED_OBSERVER'
        )
        $previousTrustedResultPath = [Environment]::GetEnvironmentVariable(
            'DARKRENAMER_VM_TRUSTED_RESULT_PATH'
        )
        try {
            [Environment]::SetEnvironmentVariable('DARKRENAMER_VM_ELEVATED_OBSERVER', '1')
            [Environment]::SetEnvironmentVariable(
                'DARKRENAMER_VM_TRUSTED_RESULT_PATH', $missingManagedResultPath
            )
            Assert-Win32Failure -NativeErrorCode 2 `
                -Label 'Managed missing trusted result open' `
                -Action {
                    Initialize-TrustedResultWriter `
                        -Root $managedResultRoot `
                        -Path $missingManagedResultPath
            }
            [Environment]::SetEnvironmentVariable(
                'DARKRENAMER_VM_TRUSTED_RESULT_PATH', $managedResultPath
            )
            Initialize-TrustedResultWriter -Root $managedResultRoot
            Write-ResultDocument -Root $managedResultRoot -Result ([ordered]@{
                schema_version = 1
                status = 'failed'
                failure_reason = 'managed_security_test'
            })
            $managedResult = [IO.File]::ReadAllText($managedResultPath) | ConvertFrom-Json
            if ($managedResult.failure_reason -cne 'managed_security_test') {
                throw 'The managed trusted result writer did not use its controller-created destination.'
            }
            $managedIdentityAfter = Get-FullFileIdentity -Path $managedResultPath
            if ($managedIdentityAfter.volume_serial -cne $managedIdentityBefore.volume_serial -or
                $managedIdentityAfter.file_id -cne $managedIdentityBefore.file_id) {
                throw 'The managed trusted result writer replaced its controller-created file identity.'
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                'DARKRENAMER_VM_TRUSTED_RESULT_PATH', $previousTrustedResultPath
            )
            [Environment]::SetEnvironmentVariable(
                'DARKRENAMER_VM_ELEVATED_OBSERVER', $previousElevatedObserver
            )
        }

        $numericFileId = [DarkReNamerVmNative]::FormatFileIdNumeric(
            [Convert]::ToUInt64('0706050403020100', 16),
            [Convert]::ToUInt64('0f0e0d0c0b0a0908', 16)
        )
        if ($numericFileId -cne '0f0e0d0c0b0a09080706050403020100') {
            throw 'FILE_ID_128 was not encoded as the product u128 numeric value.'
        }
        $identityRoot = Join-Path $valid.root 'full-identity'
        [void](New-Item -ItemType Directory -Path $identityRoot)
        $identityFile = Join-Path $identityRoot 'fixture.txt'
        [IO.File]::WriteAllText($identityFile, 'identity fixture')
        $directoryIdentity = Get-FullFileIdentity -Path $identityRoot
        $fileIdentity = Get-FullFileIdentity -Path $identityFile
        foreach ($observed in @($directoryIdentity, $fileIdentity)) {
            if ($observed.volume_serial -cnotmatch '^[0-9a-f]{16}$' -or
                $observed.file_id -cnotmatch '^[0-9a-f]{32}$') {
                throw 'FILE_ID_INFO did not retain its full lowercase numeric width.'
            }
        }
        if ($directoryIdentity.volume_serial -cne $fileIdentity.volume_serial -or
            $directoryIdentity.file_id -ceq $fileIdentity.file_id) {
            throw 'FILE_ID_INFO did not bind distinct entries on the same fixture volume.'
        }
        $rawFixture = Join-Path $valid.root 'raw-fixture'
        [void](New-Item -ItemType Directory -Path $rawFixture)
        $rawFile = Join-Path $rawFixture 'source.txt'
        [IO.File]::WriteAllText($rawFile, 'raw fixture')
        $rawCheckpoint = Get-VmAutomatedCheckpoint `
            -Phase initial -FixtureRoot $rawFixture `
            -LocalAppData (Join-Path $valid.root 'raw-localappdata')
        if (@($rawCheckpoint.fixture_entries).Count -ne 1 -or
            $rawCheckpoint.fixture_entries[0].name -cne 'source.txt' -or
            $rawCheckpoint.fixture_entries[0].kind -cne 'file' -or
            $rawCheckpoint.fixture_entries[0].file_identity.file_id -cne
                (Get-FullFileIdentity -Path $rawFile).file_id -or
            @($rawCheckpoint.journal_entries).Count -ne 0) {
            throw 'The raw checkpoint did not preserve complete fixture identity and journal state.'
        }

        $jobPowerShell = (Get-Process -Id $PID).Path
        $outputCapScript = Join-Path $valid.root 'job-output-cap.ps1'
        $outputCapStdout = Join-Path $valid.root 'job-output-cap.stdout.txt'
        $outputCapStderr = Join-Path $valid.root 'job-output-cap.stderr.txt'
        [IO.File]::WriteAllText(
            $outputCapScript,
            "[Console]::Out.Write(('x' * 4096))`nStart-Sleep -Seconds 30`n",
            [Text.UTF8Encoding]::new($false)
        )
        $savedChannelLimit = $script:VmTestOutputChannelLimitBytes
        $savedAggregateLimit = $script:VmTestOutputAggregateLimitBytes
        $outputCapState = $null
        try {
            $script:VmTestOutputChannelLimitBytes = 1024
            $script:VmTestOutputAggregateLimitBytes = 512
            $outputCapState = Start-JobBoundProcess `
                -FilePath $jobPowerShell `
                -Arguments ('-NoLogo -NoProfile -NonInteractive -File "' + $outputCapScript + '"') `
                -WorkingDirectory $valid.root `
                -StdoutPath $outputCapStdout `
                -StderrPath $outputCapStderr
            $outputCapResult = Wait-JobBoundProcessWithOutputLimit `
                -State $outputCapState `
                -StdoutPath $outputCapStdout `
                -StderrPath $outputCapStderr `
                -TimeoutSeconds 20
            if ($outputCapResult.failure_reason -cne 'output_limit_exceeded' -or
                $outputCapResult.stdout_bytes -gt 1024 -or
                $outputCapResult.stderr_bytes -gt 1024 -or
                $outputCapResult.stdout_bytes -gt (512 - $outputCapResult.stderr_bytes)) {
                throw 'The bounded process runtime did not terminate the job at its output cap.'
            }
        }
        finally {
            $script:VmTestOutputChannelLimitBytes = $savedChannelLimit
            $script:VmTestOutputAggregateLimitBytes = $savedAggregateLimit
            if ($null -ne $outputCapState -and -not $outputCapState.job_closed) {
                if ($outputCapState.owner.ActiveProcessCount -ne 0) {
                    Stop-JobBoundProcess -State $outputCapState
                }
                if (-not (Close-JobBoundProcess -State $outputCapState)) {
                    throw 'The output-cap Job Object did not close cleanly.'
                }
            }
        }

        $suiteBudgetBytes = [long]1536
        $remainingSuiteBytes = $suiteBudgetBytes
        $suiteBytesCaptured = [long]0
        $suiteRunCount = 0
        while ($remainingSuiteBytes -gt 0) {
            $testBudgetBytes = [Math]::Min([long]1024, $remainingSuiteBytes)
            $suiteStdoutPath = Join-Path $valid.root "suite-$suiteRunCount.stdout.txt"
            $suiteStderrPath = Join-Path $valid.root "suite-$suiteRunCount.stderr.txt"
            $suiteProcess = $null
            try {
                $suiteProcess = Start-JobBoundProcess `
                    -FilePath $jobPowerShell `
                    -Arguments ('-NoLogo -NoProfile -NonInteractive -File "' + $outputCapScript + '"') `
                    -WorkingDirectory $valid.root `
                    -StdoutPath $suiteStdoutPath `
                    -StderrPath $suiteStderrPath `
                    -AggregateOutputLimitBytes $testBudgetBytes
                $suiteResult = Wait-JobBoundProcessWithOutputLimit `
                    -State $suiteProcess `
                    -StdoutPath $suiteStdoutPath `
                    -StderrPath $suiteStderrPath `
                    -TimeoutSeconds 20
                $capturedForTest = $suiteResult.stdout_bytes + $suiteResult.stderr_bytes
                if ($suiteResult.failure_reason -cne 'output_limit_exceeded' -or
                    $capturedForTest -le 0 -or $capturedForTest -gt $testBudgetBytes) {
                    throw 'A test process exceeded its shrinking suite output allowance.'
                }
                $suiteBytesCaptured += $capturedForTest
                $remainingSuiteBytes -= $capturedForTest
                $suiteRunCount++
            }
            finally {
                if ($null -ne $suiteProcess -and -not $suiteProcess.job_closed) {
                    if ($suiteProcess.owner.ActiveProcessCount -ne 0) {
                        Stop-JobBoundProcess -State $suiteProcess
                    }
                    if (-not (Close-JobBoundProcess -State $suiteProcess)) {
                        throw 'A suite-budget Job Object did not close cleanly.'
                    }
                }
            }
        }
        if ($suiteBytesCaptured -ne $suiteBudgetBytes -or $suiteRunCount -ne 2) {
            throw 'The shrinking per-test output allowance did not cap the complete guest suite.'
        }
        $jobLedgerOutputRoot = Join-Path $valid.root 'rust-job-ledger-output'
        [void](New-Item -ItemType Directory -Path $jobLedgerOutputRoot)
        $savedJobLedger = $script:AcceptanceProcessJobCleanup
        $script:AcceptanceProcessJobCleanup = [Collections.Generic.List[object]]::new()
        try {
            $jobLedgerCountBefore = $script:AcceptanceProcessJobCleanup.Count
            $jobLedgerTest = [pscustomobject]@{
                file = Split-Path -Leaf $jobPowerShell
                name = 'rust-job-ledger-fixture'
                sha256 = Get-LowerSha256 -Path $jobPowerShell
            }
            # The real child rejects libtest arguments. Even a failed test must
            # retain its exact lifecycle and closed Job in the independent ledger.
            $jobLedgerRow = Invoke-RustTestBinary `
                -Test $jobLedgerTest `
                -Root (Split-Path -Parent $jobPowerShell) `
                -OutputRoot $jobLedgerOutputRoot `
                -RuntimeRoot $runtimeObservationRoot `
                -Index 98 `
                -TimeoutSeconds 20
            if ($jobLedgerRow.status -cne 'failed' -or -not $jobLedgerRow.job_cleanup -or
                $script:AcceptanceProcessJobCleanup.Count -ne ($jobLedgerCountBefore + 1)) {
                throw 'A launched Rust test must retain exactly one closed process-job record.'
            }
            $jobLedgerRecord = $script:AcceptanceProcessJobCleanup[$jobLedgerCountBefore]
            if ($jobLedgerRecord.pid -ne $jobLedgerRow.process_lifecycle.pid -or
                $jobLedgerRecord.process_start_time_utc_ticks -cne
                    $jobLedgerRow.process_lifecycle.start_time_utc_ticks -or
                $jobLedgerRecord.status -cne 'clean' -or
                -not $jobLedgerRecord.job_empty -or -not $jobLedgerRecord.job_closed -or
                -not $jobLedgerRecord.capture_complete) {
                throw 'The Rust test job record must match its exact lifecycle and closed capture.'
            }
        }
        finally { $script:AcceptanceProcessJobCleanup = $savedJobLedger }

        $exhaustedOutputRoot = Join-Path $valid.root 'exhausted-output'
        [void](New-Item -ItemType Directory -Path $exhaustedOutputRoot)
        $exhaustedSuiteRow = Invoke-RustTestBinary `
            -Test $valid.manifest.test_binaries[0] `
            -Root $valid.root `
            -OutputRoot $exhaustedOutputRoot `
            -RuntimeRoot $runtimeObservationRoot `
            -Index 99 `
            -TimeoutSeconds 1 `
            -OutputBudgetBytes 0
        if ($exhaustedSuiteRow.status -cne 'failed' -or
            $exhaustedSuiteRow.failure_reason -cne 'suite_output_limit_exceeded' -or
            -not $exhaustedSuiteRow.job_cleanup -or
            $exhaustedSuiteRow.stdout.bytes -ne 0 -or
            $exhaustedSuiteRow.stderr.bytes -ne 0) {
            throw 'An exhausted suite budget must record the remaining test without launching it.'
        }

        $descendantPidPath = Join-Path $valid.root 'job-descendant.pid'
        $descendantScript = Join-Path $valid.root 'job-descendant.ps1'
        $descendantStdoutPath = Join-Path $valid.root 'job-descendant.stdout.txt'
        $descendantStderrPath = Join-Path $valid.root 'job-descendant.stderr.txt'
        [IO.File]::WriteAllText(
            $descendantScript,
            ('$child = Start-Process -FilePath "$env:SystemRoot\System32\ping.exe" ' +
                '-ArgumentList @("-n","60","127.0.0.1") -WindowStyle Hidden -PassThru' +
                "`n[IO.File]::WriteAllText('" + $descendantPidPath.Replace("'", "''") +
                "', [string]`$child.Id)`n"),
            [Text.UTF8Encoding]::new($false)
        )
        $descendantState = Start-JobBoundProcess `
            -FilePath $jobPowerShell `
            -Arguments ('-NoLogo -NoProfile -NonInteractive -File "' + $descendantScript + '"') `
            -WorkingDirectory $valid.root `
            -StdoutPath $descendantStdoutPath `
            -StderrPath $descendantStderrPath
        try {
            if (-not $descendantState.process.WaitForExit(20000)) {
                throw 'The descendant-launching parent did not exit.'
            }
            $descendantPid = [int][IO.File]::ReadAllText($descendantPidPath)
            if ($null -eq (Get-Process -Id $descendantPid -ErrorAction SilentlyContinue)) {
                throw 'The outside-bundle descendant fixture did not remain active.'
            }
            $descendantWait = Wait-JobBoundProcessWithOutputLimit `
                -State $descendantState `
                -StdoutPath $descendantStdoutPath `
                -StderrPath $descendantStderrPath `
                -TimeoutSeconds 20
            if ($descendantWait.failure_reason -cne 'process_job_not_empty' -or
                $descendantWait.active_processes_at_primary_exit -le 0) {
                throw 'The primary-exit check did not record and terminate its active descendant immediately.'
            }
            if (Close-JobBoundProcess -State $descendantState) {
                throw 'Job cleanup reported success while an outside-bundle descendant remained.'
            }
            if ($null -ne (Get-Process -Id $descendantPid -ErrorAction SilentlyContinue)) {
                throw 'Closing the Job Object did not terminate its outside-bundle descendant.'
            }
        }
        finally {
            if (-not $descendantState.job_closed) {
                if ($descendantState.owner.ActiveProcessCount -ne 0) {
                    Stop-JobBoundProcess -State $descendantState
                }
                [void](Close-JobBoundProcess -State $descendantState)
            }
        }
    }
    else {
        Assert-Fails {
            Get-FullFileIdentity -Path $valid.root
        } 'requires Windows'
    }
    $isolatedLocalAppData = Join-Path $valid.root 'isolated-localappdata'
    $isolatedJournalRoot = Join-Path (Join-Path $isolatedLocalAppData 'DarkReNamer') 'journal'
    [void](New-Item -ItemType Directory -Path $isolatedJournalRoot)
    [IO.File]::WriteAllBytes((Join-Path $isolatedJournalRoot 'runtime.lock'), [byte[]]@())
    Assert-NoJournalResidue -LocalAppData $isolatedLocalAppData
    [IO.File]::WriteAllBytes((Join-Path $isolatedJournalRoot 'active.drj'), [byte[]](1, 2, 3))
    Assert-Fails {
        Assert-NoJournalResidue -LocalAppData $isolatedLocalAppData
    } 'rename-journal residue'
    Remove-Item -LiteralPath (Join-Path $isolatedJournalRoot 'active.drj')
    $hostRunner = Join-Path $toolingScriptsRoot 'run-windows-vm-tests.ps1'
    $hostRunnerText = Get-DrTestCombinedPowerShellSource -Kind controller
    $taskRegistrationMatches = [regex]::Matches(
        $hostRunnerText,
        '(?m)^\s+(?:\$registeredTask\s+=\s+)?Register-DrVmTask\s+`\s*$'
    )
    if ($taskRegistrationMatches.Count -ne 5) {
        throw 'Every Windows VM task registration must be enumerated by the controller contract test.'
    }
    $directPowerShellActions = [regex]::Matches(
        $hostRunnerText,
        '(?m)^\s+-Execute \$powerShell `\s*$'
    )
    if ($directPowerShellActions.Count -ne 5) {
        throw 'Core, UI, recovery, and rescue tasks must launch their verified PowerShell entrypoint directly.'
    }
    foreach ($registration in $taskRegistrationMatches) {
        $nextStart = $hostRunnerText.IndexOf(
            'Start-ScheduledTask -TaskName $name',
            $registration.Index,
            [StringComparison]::Ordinal
        )
        if ($nextStart -le $registration.Index) {
            throw 'Each atomically registered Windows VM task must be verified before task start.'
        }
        $runtimeParameterIndex = $hostRunnerText.IndexOf(
            '-RuntimeRoot $',
            $registration.Index,
            [StringComparison]::Ordinal
        )
        if ($runtimeParameterIndex -lt $registration.Index -or $runtimeParameterIndex -ge $nextStart) {
            throw 'Each Windows VM task must register its protected guest runtime root.'
        }
    }
    if ([regex]::Matches(
            $hostRunnerText,
            [regex]::Escape('-RuntimeRoot "'),
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        ).Count -ne 5) {
        throw 'Each Windows VM observer command must include exactly one runtime-root argument.'
    }
    $guestEntryText = Get-Content -LiteralPath (Join-Path $toolingScriptsRoot 'modules/powershell/guest-entry.psm1') -Raw
    foreach ($requiredRuntimeRootContract in @(
        '$effectiveRuntimeRoot = $null',
        '$effectiveRuntimeRoot = if ($RuntimeRoot) {',
        '-RuntimeRoot $effectiveRuntimeRoot',
        'Join-Path $effectiveRuntimeRoot ''gui\localappdata''',
        'if (Test-Path -LiteralPath $effectiveRuntimeRoot) {',
        'Get-VmAutomatedRuntimeRootObservation -Root $effectiveRuntimeRoot',
        'Remove-Item -LiteralPath $effectiveRuntimeRoot -Recurse -Force'
    )) {
        if ($guestEntryText.IndexOf($requiredRuntimeRootContract, [StringComparison]::Ordinal) -lt 0) {
            throw "The guest runtime-root contract is missing '$requiredRuntimeRootContract'."
        }
    }
    $shadowRuntimeRootPattern = '\$runtimeRoot\s*=\s*\$null\b'
    foreach ($shadowRuntimeRootExample in @('$runtimeRoot = $null', '$RuntimeROOT=$NULL')) {
        if (-not [regex]::IsMatch(
                $shadowRuntimeRootExample,
                $shadowRuntimeRootPattern,
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )) {
            throw 'The case-insensitive RuntimeRoot shadow-assignment pattern does not match its regression examples.'
        }
    }
    $shadowRuntimeRootAssignments = [regex]::Matches(
        $guestEntryText,
        $shadowRuntimeRootPattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($shadowRuntimeRootAssignments.Count -ne 0) {
        throw 'The guest lifecycle sentinel must not clear the RuntimeRoot parameter.'
    }
    $runtimeRootArgumentCount = [regex]::Matches(
        $guestEntryText,
        [regex]::Escape('-RuntimeRoot $effectiveRuntimeRoot')
    ).Count
    $testInvocationIndex = $guestEntryText.IndexOf('Invoke-RustTestBinary `', [StringComparison]::Ordinal)
    $testRuntimeArgumentIndex = if ($testInvocationIndex -ge 0) {
        $guestEntryText.IndexOf(
            '-RuntimeRoot $effectiveRuntimeRoot', $testInvocationIndex, [StringComparison]::Ordinal
        )
    } else { -1 }
    $guiInvocationIndex = $guestEntryText.IndexOf('Invoke-GuiSmoke `', [StringComparison]::Ordinal)
    $guiRuntimeArgumentIndex = if ($guiInvocationIndex -ge 0) {
        $guestEntryText.IndexOf(
            '-RuntimeRoot $effectiveRuntimeRoot', $guiInvocationIndex, [StringComparison]::Ordinal
        )
    } else { -1 }
    if ($runtimeRootArgumentCount -ne 2 -or $testInvocationIndex -lt 0 -or
        $testRuntimeArgumentIndex -le $testInvocationIndex -or
        $testRuntimeArgumentIndex -ge $guiInvocationIndex -or
        $guiRuntimeArgumentIndex -le $guiInvocationIndex) {
        throw 'The verified runtime root must be passed separately to both the test binary and GUI smoke runner.'
    }
    foreach ($requiredBootstrapDiagnostic in @(
        "Join-Path `$OutputRoot 'observer-bootstrap-failure.txt'",
        'if (-not $elevatedObserver) { return }',
        '$Message.Length -gt 4096',
        'bundle-verification-failed',
        'fixture-root-validation-failed',
        'runtime-root-validation-failed',
        'execution-context-check-failed',
        'runner-protection-started',
        'trusted-result-writer-initialization-started',
        'if ($null -eq $script:VmTrustedResultWriter)',
        '[ComponentModel.Win32Exception]',
        '$exception.NativeErrorCode',
        '$errorRecord.ScriptStackTrace',
        'runner-bootstrap-failed',
        'Remove-Item -LiteralPath $bootstrapDiagnosticPath -Force -ErrorAction Stop',
        'The VM observer bootstrap diagnostic remained after result-writer initialization.'
    )) {
        if ($guestEntryText.IndexOf($requiredBootstrapDiagnostic, [StringComparison]::Ordinal) -lt 0) {
            throw "The guest bootstrap diagnostic contract is missing '$requiredBootstrapDiagnostic'."
        }
    }
    $bootstrapDiagnosticFactoryIndex = $guestEntryText.IndexOf(
        '$writeBootstrapDiagnostic = {', [StringComparison]::Ordinal
    )
    $elevatedBundleVerificationIndex = $guestEntryText.IndexOf(
        'if ($null -eq $verified)', [StringComparison]::Ordinal
    )
    if ($bootstrapDiagnosticFactoryIndex -lt 0 -or
        $elevatedBundleVerificationIndex -le $bootstrapDiagnosticFactoryIndex) {
        throw 'Elevated bundle verification must be covered by the trusted bootstrap diagnostic sink.'
    }
    $runnerProtectionIndex = $guestEntryText.LastIndexOf(
        'Protect-CurrentRunnerProcess', [StringComparison]::Ordinal
    )
    $resultWriterIndex = $guestEntryText.LastIndexOf(
        'Initialize-TrustedResultWriter -Root $verified.root', [StringComparison]::Ordinal
    )
    $processLedgerIndex = $guestEntryText.LastIndexOf(
        '[void](Assert-AcceptanceProcessJobLedgerClosed)', [StringComparison]::Ordinal
    )
    $runtimeDeleteIndex = $guestEntryText.IndexOf(
        'Remove-Item -LiteralPath $effectiveRuntimeRoot -Recurse -Force', [StringComparison]::Ordinal
    )
    if ($runnerProtectionIndex -lt 0 -or $resultWriterIndex -le $runnerProtectionIndex -or
        $processLedgerIndex -lt 0 -or $runtimeDeleteIndex -le $processLedgerIndex) {
        throw 'Core observer protection must precede the open result writer, and runtime deletion must follow closed process-job evidence.'
    }
    if ([regex]::Matches(
            $hostRunnerText,
            '\[System\.IO\.FileSystemAclExtensions\]::CreateDirectory\('
        ).Count -ne 8 -or
        $hostRunnerText.IndexOf('[IO.Directory]::CreateDirectory(', [StringComparison]::Ordinal) -ge 0) {
        throw 'Every security-sensitive VM directory must be created with its explicit ACL in one operation.'
    }
    if ($hostRunnerText.IndexOf('Test-DrControllerProcessJobCleanupLedger', [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf('$requiredProcessJobsClosed = $processJobsClosed', [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf('-not $jobsClosed -or $taskPresentBeforeDelete', [StringComparison]::Ordinal) -lt 0) {
        throw 'The VM controller must bind process-job cleanup evidence before deleting guest and trusted roots.'
    }
    if ($hostRunnerText.IndexOf('for ($attempt = 1; $attempt -le 3; $attempt++)', [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf('if ($attempt -lt 3) { Start-Sleep -Milliseconds 200 }', [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf('$trustedTaskRoot = $null', [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf('trusted_task_root = Join-Path $base ($name + ''-trusted'')', [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf('$trustedTaskRoot = [string]$workspaceRoots.trusted_task_root', [StringComparison]::Ordinal) -lt 0) {
        throw 'The VM controller must retry transient process inventories and retain exact cleanup roots before baseline collection.'
    }
    $controllerLifecycle = [pscustomobject]@{
        pid = 1234
        start_time_utc_ticks = '639000000000000000'
    }
    $controllerJob = [pscustomobject][ordered]@{
        pid = 1234
        process_start_time_utc_ticks = '639000000000000000'
        job_empty = $true
        job_closed = $true
        capture_complete = $true
        active_processes_at_primary_exit = $null
        had_survivors = $false
        forced_termination = $false
        active_processes_at_close = 0
        active_processes_at_stop = $null
        active_process_ids_at_stop = @()
        total_processes_at_stop = $null
        primary_process_active_at_stop = $null
        termination_exit_code = $null
        status = 'clean'
        error = $null
    }
    $controllerResult = [pscustomobject]@{
        process_job_cleanup = @($controllerJob)
        gui = [pscustomobject]@{ process_lifecycle = $controllerLifecycle }
    }
    $controllerEntryPath = Join-Path $toolingScriptsRoot 'modules/powershell/controller-entry.psm1'
    $controllerEntryTokens = $null
    $controllerEntryErrors = $null
    $controllerEntryAst = [Management.Automation.Language.Parser]::ParseFile(
        $controllerEntryPath, [ref]$controllerEntryTokens, [ref]$controllerEntryErrors
    )
    if ($controllerEntryErrors.Count -ne 0) {
        throw 'The controller entrypoint must parse before its cleanup contract is exercised.'
    }
    foreach ($functionName in @(
        'Add-DrControllerLifecycleIdentity'
        'Test-DrControllerProcessJobCleanupLedger'
    )) {
        $functionDefinitions = @($controllerEntryAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $functionName
        }, $true))
        if ($functionDefinitions.Count -ne 1) {
            throw "Expected one controller cleanup contract function: $functionName"
        }
        . ([scriptblock]::Create($functionDefinitions[0].Extent.Text))
    }
    if (-not (Test-DrControllerProcessJobCleanupLedger -Result $controllerResult)) {
        throw 'The controller rejected a complete lifecycle-bound process-job ledger.'
    }
    $controllerJob.pid = 1235
    if (Test-DrControllerProcessJobCleanupLedger -Result $controllerResult) {
        throw 'The controller accepted a clean process-job row for a different candidate identity.'
    }
    $unstartedGuiResult = [pscustomobject]@{
        process_job_cleanup = @()
        gui = [pscustomobject]@{
            status = 'failed'
            job_cleanup = $true
            process_id = $null
            failure_reason = 'gui_error'
            error_detail = [pscustomobject]@{
                exception_type = 'System.Exception'
                message = 'fixture initialization failed'
                native_error = $null
            }
        }
    }
    if (Test-DrControllerProcessJobCleanupLedger -Result $unstartedGuiResult) {
        throw 'An empty process-job ledger must remain invalid outside the core GUI no-start case.'
    }
    if (-not (Test-DrControllerProcessJobCleanupLedger -Result $unstartedGuiResult -AllowEmpty)) {
        throw 'A GUI failure before process creation must allow an empty but complete process-job ledger.'
    }
    $unstartedGuiResult.gui.process_id = 1234
    if (Test-DrControllerProcessJobCleanupLedger -Result $unstartedGuiResult -AllowEmpty) {
        throw 'An empty process-job ledger must not be accepted when a GUI process identity exists.'
    }
    $runnerProcessDefinitions = @($controllerEntryAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'global:Get-DrVmRunnerProcesses'
    }, $true))
    if ($runnerProcessDefinitions.Count -ne 1) {
        throw 'Expected one controller runner-process inventory function.'
    }
    $runnerProcessProbe = [scriptblock]::Create(@'
param([string] $FunctionText)
$script:runnerCimCalls = 0
$script:runnerOwnerCalls = 0
$script:failFirstOwner = $true
$script:failAllOwners = $false
function Get-CimInstance {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string] $ClassName,
        [string] $Filter,
        [uint32] $OperationTimeoutSec
    )
    $script:runnerCimCalls++
    [pscustomobject]@{
        ProcessId = 4242
        SessionId = 2
        CreationDate = [datetime]::SpecifyKind([datetime]'2026-09-27T00:00:00', [DateTimeKind]::Utc)
        ExecutablePath = 'C:\vm-test\runner.exe'
    }
}
function Invoke-CimMethod {
    [CmdletBinding()]
    param(
        [object] $InputObject,
        [string] $MethodName,
        [uint32] $OperationTimeoutSec
    )
    $script:runnerOwnerCalls++
    if ($script:failFirstOwner) {
        $script:failFirstOwner = $false
        throw 'Simulated process exit during owner inventory.'
    }
    if ($script:failAllOwners) {
        return [pscustomobject]@{ ReturnValue = 5; Sid = $null }
    }
    [pscustomobject]@{ ReturnValue = 0; Sid = 'S-1-5-21-1-2-3-1001' }
}
$localFunctionText = $FunctionText.Replace(
    'function global:Get-DrVmRunnerProcesses',
    'function Get-DrVmRunnerProcesses'
)
. ([scriptblock]::Create($localFunctionText))
$transient = Get-DrVmRunnerProcesses -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2
$transientCimCalls = $script:runnerCimCalls
$script:runnerCimCalls = 0
$script:runnerOwnerCalls = 0
$script:failAllOwners = $true
$incomplete = Get-DrVmRunnerProcesses -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2
[pscustomobject]@{
    transient_complete = $transient.complete
    transient_attempts = $transient.attempts
    transient_process_count = @($transient.processes).Count
    transient_cim_calls = $transientCimCalls
    incomplete_complete = $incomplete.complete
    incomplete_attempts = $incomplete.attempts
    incomplete_process_count = @($incomplete.processes).Count
    incomplete_cim_calls = $script:runnerCimCalls
}
'@)
    $runnerProcessProbeResult = & $runnerProcessProbe $runnerProcessDefinitions[0].Extent.Text
    if (-not $runnerProcessProbeResult.transient_complete -or
        $runnerProcessProbeResult.transient_attempts -ne 2 -or
        $runnerProcessProbeResult.transient_process_count -ne 1 -or
        $runnerProcessProbeResult.transient_cim_calls -ne 2 -or
        $runnerProcessProbeResult.incomplete_complete -or
        $runnerProcessProbeResult.incomplete_attempts -ne 3 -or
        $runnerProcessProbeResult.incomplete_process_count -ne 0 -or
        $runnerProcessProbeResult.incomplete_cim_calls -ne 3) {
        throw 'The VM process inventory must recover from one transient owner query failure and remain incomplete after the bounded retries.'
    }
    $brokerFunctionDefinitions = @($controllerEntryAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'global:Test-DrVmSmartScreenBrokerEvidence'
    }, $true))
    $commandLineFunctionDefinitions = @($controllerEntryAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'global:Get-DrVmCommandLineArguments'
    }, $true))
    $waitFunctionDefinitions = @($controllerEntryAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'global:Wait-DrVmSmartScreenNaturalExit'
    }, $true))
    if ($brokerFunctionDefinitions.Count -ne 1 -or
        $commandLineFunctionDefinitions.Count -ne 1 -or
        $waitFunctionDefinitions.Count -ne 1) {
        throw 'The controller must expose one pure broker contract and one bounded natural-exit wait.'
    }
    $commandLineProbe = [scriptblock]::Create(@'
param([string] $FunctionText)
$localFunctionText = $FunctionText.Replace(
    'function global:Get-DrVmCommandLineArguments',
    'function Get-DrVmCommandLineArguments'
)
. ([scriptblock]::Create($localFunctionText))
try {
    Get-DrVmCommandLineArguments -CommandLine 'C:\Windows\System32\smartscreen.exe -Embedding' | Out-Null
}
catch {
    # The helper reaches its P/Invoke on the non-Windows tooling host; inspect the compiled declaration below.
}
$nativeType = 'DrVmCommandLineNative' -as [type]
if ($null -eq $nativeType) { throw 'The command-line native declaration was not loaded.' }
$method = $nativeType.GetMethod('CommandLineToArgvW')
$import = $method.GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false)[0]
[pscustomobject]@{
    unicode = $import.CharSet -eq [Runtime.InteropServices.CharSet]::Unicode
    entry_point = $import.EntryPoint
}
'@)
$commandLineProbeResult = & $commandLineProbe $commandLineFunctionDefinitions[0].Extent.Text
if (-not $commandLineProbeResult.unicode -or
    $commandLineProbeResult.entry_point -cne 'CommandLineToArgvW') {
    throw 'The SmartScreen command-line parser must marshal the Windows wide-character API as Unicode.'
}
    $brokerProbe = [scriptblock]::Create(@'
param([string] $FunctionText)
$localFunctionText = $FunctionText.Replace(
    'function global:Test-DrVmSmartScreenBrokerEvidence',
    'function Test-DrVmSmartScreenBrokerEvidence'
)
. ([scriptblock]::Create($localFunctionText))
$candidateIdentity = '4242|2026-09-27T18:34:27.0489960Z'
$processPath = 'C:\Windows\System32\smartscreen.exe'
$parentPath = 'C:\Windows\System32\svchost.exe'
$evidence = [ordered]@{
    windows_directory = 'C:\Windows'
    process_identity = $candidateIdentity
    process_pid = [int]4242
    process_creation_time_utc = '2026-09-27T18:34:27.0489960Z'
    process_session_id = [int]2
    process_owner_sid = 'S-1-5-21-1-2-3-1001'
    process_executable_path = $processPath
    process_path_verified = $true
    process_command_line_arguments = @($processPath, '-Embedding')
    process_signature_status = 'Valid'
    process_signer_subject = 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    process_signer_thumbprint = ('A' * 40)
    parent_identity = '2000|2026-09-27T18:00:00.0000000Z'
    parent_pid = [int]2000
    parent_creation_time_utc = '2026-09-27T18:00:00.0000000Z'
    parent_session_id = [int]0
    parent_owner_sid = 'S-1-5-18'
    parent_executable_path = $parentPath
    parent_path_verified = $true
    parent_command_line_arguments = @($parentPath, '-k', 'DcomLaunch', '-p')
    parent_signature_status = 'Valid'
    parent_signer_subject = 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    parent_signer_thumbprint = ('B' * 40)
    service_name = 'DcomLaunch'
    service_process_id = [int]2000
    service_state = 'Running'
}
$valid = Test-DrVmSmartScreenBrokerEvidence -Evidence $evidence `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -CandidateIdentity $candidateIdentity
$badOwner = [ordered]@{}; foreach ($key in $evidence.Keys) { $badOwner[$key] = $evidence[$key] }
$badOwner.process_owner_sid = 'S-1-5-18'
$ownerRejected = -not (Test-DrVmSmartScreenBrokerEvidence -Evidence $badOwner `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -CandidateIdentity $candidateIdentity)
$badSignature = [ordered]@{}; foreach ($key in $evidence.Keys) { $badSignature[$key] = $evidence[$key] }
$badSignature.process_signature_status = 'NotSigned'
$signatureRejected = -not (Test-DrVmSmartScreenBrokerEvidence -Evidence $badSignature `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -CandidateIdentity $candidateIdentity)
$badService = [ordered]@{}; foreach ($key in $evidence.Keys) { $badService[$key] = $evidence[$key] }
$badService.service_process_id = [int]2001
$serviceRejected = -not (Test-DrVmSmartScreenBrokerEvidence -Evidence $badService `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -CandidateIdentity $candidateIdentity)
$badArguments = [ordered]@{}; foreach ($key in $evidence.Keys) { $badArguments[$key] = $evidence[$key] }
$badArguments.process_command_line_arguments = @($processPath, '-Embedding', '-unsafe')
$argumentsRejected = -not (Test-DrVmSmartScreenBrokerEvidence -Evidence $badArguments `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -CandidateIdentity $candidateIdentity)
[pscustomobject]@{
    valid = $valid
    owner_rejected = $ownerRejected
    signature_rejected = $signatureRejected
    service_rejected = $serviceRejected
    arguments_rejected = $argumentsRejected
}
'@)
$brokerProbeResult = & $brokerProbe $brokerFunctionDefinitions[0].Extent.Text
if (-not $brokerProbeResult.valid -or -not $brokerProbeResult.owner_rejected -or
    -not $brokerProbeResult.signature_rejected -or -not $brokerProbeResult.service_rejected -or
    -not $brokerProbeResult.arguments_rejected) {
    throw 'The SmartScreen broker contract must reject an owner, signature, service, or command-line mismatch.'
}
    $waitProbe = [scriptblock]::Create(@'
param([string] $FunctionText)
$localFunctionText = $FunctionText.Replace(
    'function global:Wait-DrVmSmartScreenNaturalExit',
    'function Wait-DrVmSmartScreenNaturalExit'
)
. ([scriptblock]::Create($localFunctionText))
$script:inventoryQueue = [Collections.Generic.Queue[object]]::new()
$script:taskRows = @()
$script:ownedPathPresent = $false
function Get-DrVmRunnerProcesses {
    param([string] $UserSid, [int] $SessionId)
    if ($script:inventoryQueue.Count -gt 0) { return $script:inventoryQueue.Dequeue() }
    throw 'Unexpected process inventory poll.'
}
function Get-DrVmRunnerTasks { return @($script:taskRows) }
function Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string] $ClassName, [uint32] $OperationTimeoutSec)
    if ($script:ownedPathPresent) {
        return @([pscustomobject]@{ ExecutablePath = 'C:\owned\candidate.exe' })
    }
    return @()
}
function Test-ProcessExecutableInOwnedRoots {
    param([AllowNull()][string] $Path, [string[]] $Prefixes)
    return $script:ownedPathPresent
}
function Start-Sleep { param([int] $Milliseconds) }
$baseline = [pscustomobject]@{
    identity = '1000|2026-09-27T18:00:00.0000000Z'
    pid = [int]1000
    session_id = [int]2
    creation_time_utc = '2026-09-27T18:00:00.0000000Z'
    executable_path = 'C:\Windows\explorer.exe'
}
$candidateIdentity = '4242|2026-09-27T18:34:27.0489960Z'
$candidate = [pscustomobject]@{ identity = $candidateIdentity }
$script:inventoryQueue.Enqueue([pscustomobject]@{ complete = $true; processes = @($baseline, $candidate) })
$script:inventoryQueue.Enqueue([pscustomobject]@{ complete = $true; processes = @($baseline) })
$natural = Wait-DrVmSmartScreenNaturalExit `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 `
    -BaselineProcessIdentities @($baseline.identity) -BaselineTasks @() `
    -CandidateIdentity $candidateIdentity -OwnedRootPrefixes @('C:\owned\') `
    -TimeoutMilliseconds 360000
$script:inventoryQueue.Enqueue([pscustomobject]@{ complete = $true; processes = @($baseline, $candidate) })
$script:inventoryQueue.Enqueue([pscustomobject]@{ complete = $true; processes = @($baseline, $candidate,
    [pscustomobject]@{ identity = '4243|2026-09-27T18:34:28.0489960Z' }) })
$secondProcess = Wait-DrVmSmartScreenNaturalExit `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 `
    -BaselineProcessIdentities @($baseline.identity) -BaselineTasks @() `
    -CandidateIdentity $candidateIdentity -OwnedRootPrefixes @('C:\owned\') `
    -TimeoutMilliseconds 360000
$script:inventoryQueue.Enqueue([pscustomobject]@{ complete = $true; processes = @($baseline, $candidate) })
$deadline = Wait-DrVmSmartScreenNaturalExit `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 `
    -BaselineProcessIdentities @($baseline.identity) -BaselineTasks @() `
    -CandidateIdentity $candidateIdentity -OwnedRootPrefixes @('C:\owned\') `
    -TimeoutMilliseconds 0
$script:inventoryQueue.Enqueue([pscustomobject]@{ complete = $true; processes = @($baseline, $candidate) })
$baselineTask = [pscustomobject]@{
    identity = '\User\BaselineTask'
    definition_sha256 = ('D' * 64)
}
$missingTask = Wait-DrVmSmartScreenNaturalExit `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 `
    -BaselineProcessIdentities @($baseline.identity) -BaselineTasks @($baselineTask) `
    -CandidateIdentity $candidateIdentity -OwnedRootPrefixes @('C:\owned\') `
    -TimeoutMilliseconds 360000
$script:nativeWait=[uint32]0;$script:nativeTimes=$true
$nativeOwner=[pscustomobject]@{}
$nativeOwner|Add-Member ScriptMethod Poll { @{wait_result=$script:nativeWait;times_succeeded=$script:nativeTimes;exit_code_succeeded=$true;exit_code=[uint32]1} }
function New-NativeCapture { [pscustomobject]@{lifetimes=@{$candidateIdentity=[pscustomobject]@{owner=$nativeOwner;exit=@{wait_result=[uint32]258}}}} }
$common=@{UserSid='S-1-5-21-1-2-3-1001';SessionId=2;BaselineProcessIdentities=@($baseline.identity);BaselineTasks=@();CandidateIdentity=$candidateIdentity;OwnedRootPrefixes=@('C:\owned\');TimeoutMilliseconds=360000}
$script:inventoryQueue.Enqueue([pscustomobject]@{complete=$true;processes=@($baseline)})
$nativeNatural=Wait-DrVmSmartScreenNaturalExit @common -NativeCapture (New-NativeCapture)
# Native signal arriving during a slow inventory requires a fresh clean inventory.
$lateOwner=[pscustomobject]@{calls=0}
$lateOwner|Add-Member ScriptMethod Poll {$this.calls++;@{wait_result=([uint32]$(if($this.calls -eq 1){258}else{0}));times_succeeded=$true;exit_code_succeeded=$true;exit_code=[uint32]1}}
$lateCapture=[pscustomobject]@{lifetimes=@{$candidateIdentity=[pscustomobject]@{owner=$lateOwner;exit=@{wait_result=[uint32]258}}}}
$script:inventoryQueue.Enqueue([pscustomobject]@{complete=$true;processes=@($baseline)})
$script:inventoryQueue.Enqueue([pscustomobject]@{complete=$true;processes=@($baseline)})
$late=Wait-DrVmSmartScreenNaturalExit @common -NativeCapture $lateCapture
if($late.status -cne 'natural-exit' -or $late.polls.Count -ne 2 -or $script:inventoryQueue.Count -ne 0){throw 'Late signal lacked a new complete inventory or added an intermediate zero poll.'}
$lateOwner.calls=0;$lateCapture.lifetimes[$candidateIdentity].exit=@{wait_result=[uint32]258}
$script:inventoryQueue.Enqueue([pscustomobject]@{complete=$true;processes=@($baseline)})
$script:inventoryQueue.Enqueue([pscustomobject]@{complete=$true;processes=@($baseline,[pscustomobject]@{identity='extra'})})
$lateExtra=Wait-DrVmSmartScreenNaturalExit @common -NativeCapture $lateCapture
if($lateExtra.status -cne 'rejected'){throw 'A new process in the fresh inventory was washed away.'}
$lateOwner.calls=0;$lateCapture.lifetimes[$candidateIdentity].exit=@{wait_result=[uint32]258}
$script:inventoryQueue.Enqueue([pscustomobject]@{complete=$true;processes=@($baseline)})
$script:inventoryQueue.Enqueue([pscustomobject]@{complete=$false;processes=@()})
$lateIncomplete=Wait-DrVmSmartScreenNaturalExit @common -NativeCapture $lateCapture
if($lateIncomplete.status -cne 'inventory-failed'){throw 'An incomplete fresh inventory accepted a native signal.'}
$script:nativeWait=[uint32]258
$script:inventoryQueue.Enqueue([pscustomobject]@{complete=$true;processes=@($baseline)})
$nativeMissing=Wait-DrVmSmartScreenNaturalExit @common -NativeCapture (New-NativeCapture)
$script:nativeWait=[uint32]0;$script:nativeTimes=$false
$nativeFailure=Wait-DrVmSmartScreenNaturalExit @common -NativeCapture (New-NativeCapture)
$script:nativeTimes=$true
$script:inventoryQueue.Enqueue([pscustomobject]@{complete=$true;processes=@($baseline,$candidate,[pscustomobject]@{identity='extra'})})
$nativeExtra=Wait-DrVmSmartScreenNaturalExit @common -NativeCapture (New-NativeCapture)
if($nativeNatural.status -cne 'natural-exit' -or $nativeMissing.status -cne 'inventory-failed' -or
    $nativeFailure.status -cne 'inventory-failed' -or $nativeExtra.status -cne 'rejected'){throw 'Native proof weakened whole inventory or same-handle exit requirements.'}
[pscustomobject]@{
    natural_status = $natural.status
    natural_exit = $natural.natural_exit_observed
    natural_first = $natural.polls[0].process_delta_identities[0]
    natural_final_count = @($natural.final_runner_process_delta_identities).Count
    second_process_status = $secondProcess.status
    second_process_exit = $secondProcess.natural_exit_observed
    deadline_status = $deadline.status
    deadline_exit = $deadline.natural_exit_observed
    missing_task_status = $missingTask.status
    missing_task_delta = $missingTask.polls[1].task_delta_identities[0]
}
'@)
$waitProbeResult = & $waitProbe $waitFunctionDefinitions[0].Extent.Text
if ($waitProbeResult.natural_status -cne 'natural-exit' -or
    -not $waitProbeResult.natural_exit -or
    $waitProbeResult.natural_first -cne '4242|2026-09-27T18:34:27.0489960Z' -or
    $waitProbeResult.natural_final_count -ne 0 -or
    $waitProbeResult.second_process_status -cne 'rejected' -or
    $waitProbeResult.second_process_exit -or
    $waitProbeResult.deadline_status -cne 'timed-out' -or
    $waitProbeResult.deadline_exit -or
    $waitProbeResult.missing_task_status -cne 'rejected' -or
    $waitProbeResult.missing_task_delta -cne '\User\BaselineTask') {
    throw 'The SmartScreen wait must accept only natural exit, reject process/task changes, and enforce its monotonic deadline.'
}
    if ($hostRunnerText.IndexOf('Register-ScheduledTask', [StringComparison]::Ordinal) -ge 0 -or
        $hostRunnerText.IndexOf('SetSecurityDescriptor(', [StringComparison]::Ordinal) -ge 0) {
        throw 'Windows VM tasks must not expose a mutable registration before applying their protected DACL.'
    }
    foreach ($workspaceContract in @(
        "Join-Path `$env:ProgramData 'DarkReNamerVmRuns'",
        'SetAccessRuleProtection($true, $false)',
        'FileSystemRights]::Traverse',
        'PropagationFlags]::InheritOnly',
        'CreateResultFile',
        'D:P(A;;FA;;;SY)(A;;FA;;;BA)',
        '$folder.RegisterTaskDefinition(',
        '0x12,',
        '$actualDefinition.Actions.Item(1)',
        '[int]$actualPrincipal.LogonType -ne 3',
        '$definition.Principal.RunLevel = 1',
        '[int]$actualPrincipal.RunLevel -ne 1',
        'D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x20089;;;',
        '$trustedTaskRoot = Join-Path $base ($TaskName + ''-trusted'')',
        '$runnerReadRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor',
        '[Security.AccessControl.FileSystemRights]::Synchronize',
        '[int]$_.FileSystemRights -eq [int]$runnerReadRights',
        '$trustedObserverRoot = $trustedTaskRoot',
        '$trustedBundleRoot = Join-Path $trustedTaskRoot ''bundle''',
        '$bundleSourceFull = [IO.Path]::GetFullPath($BundleSourcePath).TrimEnd(',
        '# The core runner and its verified tooling files resolve from the same directory.',
        '$cursor = if ($cursor -is [IO.FileInfo]) {',
        '$cursor = if ($pathItem -is [IO.FileInfo]) {',
        '$pathItem.Directory',
        '$pathItem.Parent',
        '$cursor.Directory',
        '$cursor.Parent',
        '$trustedOutputRoot = Join-Path $trustedTaskRoot ''out''',
        'Assert-ProtectedTaskDirectory -Path $trustedTaskRoot',
        'Assert-ProtectedTaskDirectory -Path $trustedOutputRoot',
        '$resultPath = Join-Path $trustedOutputRoot $TrustedResultLeaf',
        '[Parameter(Mandatory)][string] $RuntimeRoot,',
        '-not [IO.Path]::IsPathRooted($RuntimeRoot) -or',
        '$expectedRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $guestRootFull ''runtime''))',
        'The VM runtime root must be the controller-created guest runtime directory.',
        'function Assert-ProtectedRuntimeDirectory',
        '0x001201bf',
        '0x001301bf',
        'Assert-ProtectedRuntimeDirectory -Path $runtimeRootFull',
        'function Set-QuotedVmTaskPath',
        '-SourcePath $RuntimeRoot',
        '-DestinationPath $expectedRuntimeRoot',
        '$trustedOutputArgument = ''"'' + [IO.Path]::GetFullPath($trustedOutputRoot) + ''"''',
        'FileSystemRights]::ReadAndExecute',
        'Copy-VerifiedTrustedInput',
        '-TrustedResultPath "',
        '$actualDefinition.Settings.ExecutionTimeLimit',
        'DiscretionaryAclProtected',
        'function global:Get-DrVmRunnerProcesses',
        'Get-DrVmRunnerProcesses -UserSid $sid -SessionId $sessionId',
        '$guestRoot = [string]$workspaceRoots.guest_root',
        '$trustedTaskRoot = [string]$workspaceRoots.trusted_task_root',
        '$transport[''runner_process_baseline''] = @($runnerProcessBaseline)',
        'runner_process_inventory_complete =',
        'unexpected_runner_processes =',
        'terminated_runner_processes ='
    )) {
        if ($hostRunnerText.IndexOf($workspaceContract, [StringComparison]::Ordinal) -lt 0) {
            throw "The protected Windows VM workspace contract is missing '$workspaceContract'."
        }
    }
    $baseBegin = $hostRunnerText.IndexOf('if ($ForBase) {', [StringComparison]::Ordinal)
    $baseEnd = $hostRunnerText.IndexOf('if ($ForGuestRoot) {', $baseBegin, [StringComparison]::Ordinal)
    if ($baseBegin -lt 0 -or $baseEnd -le $baseBegin) {
        throw 'The protected workspace base ACL clause is missing.'
    }
    $baseAclClause = $hostRunnerText.Substring($baseBegin, $baseEnd - $baseBegin)
    $baseRights = @([regex]::Matches(
        $baseAclClause, '\[Security\.AccessControl\.FileSystemRights\]::([A-Za-z]+)') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    if (($baseRights -join ',') -cne 'ReadAttributes,ReadPermissions,Traverse' -or
        $baseAclClause.IndexOf('[Security.AccessControl.InheritanceFlags]', [StringComparison]::Ordinal) -ge 0 -or
        $baseAclClause.IndexOf('[Security.AccessControl.PropagationFlags]', [StringComparison]::Ordinal) -ge 0 -or
        $baseAclClause.IndexOf('$security.AddAccessRule($ancestorRead)', [StringComparison]::Ordinal) -lt 0) {
        throw 'The runner base ACL must grant only non-inherited traverse, attribute read, and descriptor read rights.'
    }
    if ([regex]::Matches(
            $hostRunnerText,
            [regex]::Escape('-RuntimeRoot $runtime '),
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        ).Count -ne 3 -or
        [regex]::Matches(
            $hostRunnerText,
            [regex]::Escape('-RuntimeRoot $runtimeRoot '),
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        ).Count -ne 2) {
        throw 'Acceptance, recovery, and core scheduled tasks must each bind the controller-created runtime root.'
    }
    $resultSizeIndex = $hostRunnerText.IndexOf(
        "throw 'Guest result exceeds its size bound.'",
        [StringComparison]::Ordinal
    )
    $resultCopyIndex = $hostRunnerText.IndexOf(
        "Copy-Item -LiteralPath `$guestResultPath",
        [StringComparison]::Ordinal
    )
    $outputInventoryIndex = $hostRunnerText.IndexOf(
        '$remoteOutputSizes = @{}',
        [StringComparison]::Ordinal
    )
    $outputBoundIndex = $hostRunnerText.IndexOf(
        "throw 'Guest output exceeds its host collection bound.'",
        $outputInventoryIndex,
        [StringComparison]::Ordinal
    )
    $outputCopyIndex = $hostRunnerText.IndexOf(
        'Copy-Item -LiteralPath $guestOutputPath',
        $outputInventoryIndex,
        [StringComparison]::Ordinal
    )
    $corePollParamIndex = $hostRunnerText.IndexOf(
        'param($trustedRoot,$name,$maximumResultBytes,$registeredRunTicks)',
        [StringComparison]::Ordinal
    )
    $taskCompletionIndex = $hostRunnerText.IndexOf(
        '$taskCompleted = $taskState -ceq ''Ready'' -and',
        $corePollParamIndex,
        [StringComparison]::Ordinal
    )
    $resultReadIndex = $hostRunnerText.IndexOf(
        '$data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json',
        $corePollParamIndex,
        [StringComparison]::Ordinal
    )
    $registeredRunTimeIndex = $hostRunnerText.IndexOf(
        '$registeredLastRunTimeTicks = [long]$registered.LastRunTime.Ticks',
        [StringComparison]::Ordinal
    )
    $earlyResultReturnIndex = $hostRunnerText.IndexOf(
        'if (-not $taskCompleted)',
        $corePollParamIndex,
        [StringComparison]::Ordinal
    )
    $coreResultPathIndex = $hostRunnerText.IndexOf(
        '$file = Join-Path (Join-Path $trustedRoot ''out'') ''core-result.json''',
        $corePollParamIndex,
        [StringComparison]::Ordinal
    )
    $taskStateResolverIndex = $hostRunnerText.IndexOf(
        '$pollState = Resolve-ObserverTaskPollState',
        $resultReadIndex,
        [StringComparison]::Ordinal
    )
    $terminalResultGuardIndex = $hostRunnerText.IndexOf(
        'if ($pollState.terminal) {',
        $taskStateResolverIndex,
        [StringComparison]::Ordinal
    )
    $passTaskResultGuardIndex = $hostRunnerText.IndexOf(
        'if ($pollState.result_status -ceq ''passed'' -and',
        $terminalResultGuardIndex,
        [StringComparison]::Ordinal
    )
    if ($resultSizeIndex -lt 0 -or $resultCopyIndex -le $resultSizeIndex -or
        $outputInventoryIndex -lt 0 -or $outputBoundIndex -le $outputInventoryIndex -or
        $outputCopyIndex -le $outputBoundIndex -or
        $corePollParamIndex -lt 0 -or $taskCompletionIndex -le $corePollParamIndex -or
        $resultReadIndex -le $coreResultPathIndex -or
        $registeredRunTimeIndex -lt 0 -or $earlyResultReturnIndex -le $taskCompletionIndex -or
        $coreResultPathIndex -le $earlyResultReturnIndex -or
        $taskStateResolverIndex -le $resultReadIndex -or
        $terminalResultGuardIndex -le $taskStateResolverIndex -or
        $passTaskResultGuardIndex -le $terminalResultGuardIndex -or
        $hostRunnerText.IndexOf('process_jobs_closed = [bool]$jobsClosed',
            [StringComparison]::Ordinal) -lt 0) {
        throw 'The controller must wait for the scheduled task to terminate before reading its result, bound evidence before copying, and require closed process jobs for cleanup.'
    }
    $forgedRunningResult = Resolve-ObserverTaskPollState `
        -ResultStatus 'passed' `
        -TaskState 'Running' `
        -TaskResult 0 `
        -RegisteredLastRunTimeTicks 100 `
        -LastRunTimeTicks 200
    $staleReadyResult = Resolve-ObserverTaskPollState `
        -ResultStatus 'passed' `
        -TaskState 'Ready' `
        -TaskResult 0 `
        -RegisteredLastRunTimeTicks 100 `
        -LastRunTimeTicks 100
    $completedPassResult = Resolve-ObserverTaskPollState `
        -ResultStatus 'passed' `
        -TaskState 'Ready' `
        -TaskResult 0 `
        -RegisteredLastRunTimeTicks 100 `
        -LastRunTimeTicks 200
    $completedFailureResult = Resolve-ObserverTaskPollState `
        -ResultStatus 'failed' `
        -TaskState 'Ready' `
        -TaskResult 1 `
        -RegisteredLastRunTimeTicks 100 `
        -LastRunTimeTicks 200
    if ($forgedRunningResult.terminal -or $staleReadyResult.terminal -or
        -not $completedPassResult.terminal -or -not $completedFailureResult.terminal) {
        throw 'Core result polling must ignore forged in-flight status and retain completed pass/failure results.'
    }
    if ($hostRunnerText.IndexOf('-ExecutionPolicy RemoteSigned', [StringComparison]::Ordinal) -ge 0 -or
        $hostRunnerText.IndexOf('Get-DrVmTrustedPowerShellPath', [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf('Get-Command pwsh.exe', [StringComparison]::Ordinal) -ge 0 -or
        $hostRunnerText.IndexOf("edition -cne 'Core'", [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf("effective_policy -cne 'RemoteSigned'", [StringComparison]::Ordinal) -lt 0) {
        throw 'The native scheduled task must use the inspected PowerShell 7.4+ Core RemoteSigned engine without a policy override.'
    }
    Assert-Fails {
        Assert-SshPowerShellVersion -Version '7.3.9' -Context 'Fixture SSH endpoint'
    } '7.4 or newer'
    foreach ($version in @('7.4', '7.4.0', '7.5.2', '8.0.0')) {
        Assert-SshPowerShellVersion -Version $version -Context 'Fixture SSH endpoint'
    }
    foreach ($version in @('7', '7.4-preview.1', 'not-a-version', $null)) {
        Assert-Fails {
            Assert-SshPowerShellVersion -Version $version -Context 'Fixture SSH endpoint'
        } 'numeric PowerShell version'
    }
    $script:capturedSshSession = $null
    function New-PSSession {
        param(
            [string] $HostName,
            [hashtable] $Options
        )
        $script:capturedSshSession = [pscustomobject]@{
            host_name = $HostName
            options = $Options
        }
        [pscustomobject]@{ transport = 'fixture' }
    }
    try {
        $null = New-SshControllerSession -HostAlias 'darkrenamer-vm'
    }
    finally {
        Remove-Item Function:\New-PSSession
    }
    if ($script:capturedSshSession.host_name -cne 'darkrenamer-vm' -or
        $script:capturedSshSession.options.Count -ne 3 -or
        $script:capturedSshSession.options.BatchMode -cne 'yes' -or
        $script:capturedSshSession.options.StrictHostKeyChecking -cne 'yes' -or
        $script:capturedSshSession.options.ForwardAgent -cne 'no') {
        throw 'The SSH PowerShell session did not enforce the required non-interactive host-key and agent options.'
    }
    Assert-Fails {
        Invoke-DrTestPowerShellEntrypoint -Kind controller -EntryPointPath $hostRunner -Parameters @{ BundleRoot = $valid.root; SshHost = 'user@darkrenamer-vm'; VerifiedTooling = [pscustomobject]@{} }
    } 'SshHost'
    $script:expectedVmGuid = [guid]'12345678-1234-5678-9abc-1234567890ab'
    $script:vmMatches = @([pscustomobject]@{ Id = $script:expectedVmGuid; Name = 'Exact VM'; State = 'Running' })
    $script:queriedVmId = [guid]::Empty
    $script:connectedVmId = [guid]::Empty
    function Get-VM {
        [CmdletBinding()]
        param([guid] $Id, [string] $Name)
        $script:queriedVmId = $Id
        $script:vmMatches
    }
    function New-PSSession {
        param([guid] $VMId, [Management.Automation.PSCredential] $Credential)
        $script:connectedVmId = $VMId
        [pscustomobject]@{ transport = 'direct-fixture' }
    }
    $fixtureSecret = [Security.SecureString]::new()
    $fixtureSecret.AppendChar('x')
    $fixtureCredential = [Management.Automation.PSCredential]::new('fixture-user', $fixtureSecret)
    try {
        $resolved = Resolve-DirectControllerVm -Name 'Exact VM' -ExpectedId $script:expectedVmGuid
        if ($script:queriedVmId -ne $script:expectedVmGuid) { throw 'Direct VM resolution must query the exact expected GUID.' }
        $null = New-DirectControllerSession -VmId $resolved.Id -Credential $fixtureCredential
        if ($script:connectedVmId -ne $script:expectedVmGuid) { throw 'Direct sessions must connect using the resolved GUID.' }
        Assert-Fails { Resolve-DirectControllerVm -Name 'Another VM' -ExpectedId $script:expectedVmGuid } 'GUID and exact name'
        Assert-Fails {
            Resolve-DirectControllerVm -Name 'Exact VM' -ExpectedId ([guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
        } 'GUID and exact name'
        $script:vmMatches = @($script:vmMatches[0], $script:vmMatches[0])
        Assert-Fails { Resolve-DirectControllerVm -Name 'Exact VM' } 'exactly one VM'
    }
    finally {
        Remove-Item Function:\Get-VM
        Remove-Item Function:\New-PSSession
        $fixtureSecret.Dispose()
    }
    $guestTransferRoot = 'C:\Users\TestUser\AppData\Local\Temp\DarkReNamerTests-0123456789abcdef0123456789abcdef'
    $copyInPath = Join-GuestWindowsPath -Root $guestTransferRoot -Leaf 'bundle.json'
    $copyOutPath = Join-GuestWindowsPath -Root ($guestTransferRoot + '\') -Leaf 'result.json'
    if ($copyInPath -cne ($guestTransferRoot + '\bundle.json') -or
        $copyOutPath -cne ($guestTransferRoot + '\result.json')) {
        throw 'Guest copy paths must use Windows separators without resolving a local PowerShell drive.'
    }
    Assert-Fails {
        Join-GuestWindowsPath -Root $guestTransferRoot -Leaf '..\result.json'
    } 'Invalid bundle file name'
    $failureDiagnostic = [pscustomobject]@{
        classification = 'sampled-grid-uniform'
        scope = 'sparse-samples-only'
        file = 'rename-preview.solid-diagnostic.png'
        sha256 = 'a' * 64
        bytes = 1234L
    }
    $diagnosticGui = [pscustomobject]@{
        flow = [pscustomobject]@{
            foreground_observations = @(
                [pscustomobject]@{ label = 'first' }
                [pscustomobject]@{
                    label = 'failed capture'
                    solid_image_diagnostic = $failureDiagnostic
                }
            )
        }
    }
    $selectedDiagnostics = @(Get-CoreGuiFailureDiagnosticOutputs -Gui $diagnosticGui)
    if ($selectedDiagnostics.Count -ne 1 -or
        $selectedDiagnostics[0].file -cne $failureDiagnostic.file -or
        $selectedDiagnostics[0].sha256 -cne $failureDiagnostic.sha256 -or
        $selectedDiagnostics[0].bytes -ne $failureDiagnostic.bytes) {
        throw 'Core GUI failure diagnostic selection changed its exact file binding.'
    }
    if (@(Get-CoreGuiFailureDiagnosticOutputs -Gui $null).Count -ne 0 -or
        @(Get-CoreGuiFailureDiagnosticOutputs -Gui ([pscustomobject]@{
            flow = [pscustomobject]@{ foreground_observations = @() }
        })).Count -ne 0) {
        throw 'Core GUI failure diagnostic selection did not remain optional.'
    }
    $duplicateDiagnosticGui = $diagnosticGui | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $duplicateDiagnosticGui.flow.foreground_observations += [pscustomobject]@{
        label = 'duplicate'
        solid_image_diagnostic = $failureDiagnostic
    }
    Assert-Fails {
        Get-CoreGuiFailureDiagnosticOutputs -Gui $duplicateDiagnosticGui
    } 'duplicate file reference'
    foreach ($mutation in @('unsafe', 'missing', 'malformed')) {
        $changedDiagnosticGui = $diagnosticGui | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $changed = $changedDiagnosticGui.flow.foreground_observations[1].solid_image_diagnostic
        switch ($mutation) {
            'unsafe' { $changed.file = '..\capture.png' }
            'missing' { $changed.PSObject.Properties.Remove('file') }
            'malformed' { $changed.sha256 = 'not-a-digest' }
        }
        Assert-Fails {
            Get-CoreGuiFailureDiagnosticOutputs -Gui $changedDiagnosticGui
        } $(if ($mutation -ceq 'unsafe') {
            'Invalid bundle file name'
        } else {
            'malformed reference'
        })
    }
    $solidSamples = Measure-ScreenshotSparseVariation `
        -Width 128 `
        -Height 128 `
        -ReadArgb { param($x, $y) 7 }
    if ($solidSamples.has_sampled_variation -or
        $solidSamples.first_argb -ne 7 -or
        $solidSamples.step_x -ne 2 -or
        $solidSamples.step_y -ne 2 -or
        $solidSamples.sample_count -ne 4096 -or
        $solidSamples.distinct_sample_count -ne 1) {
        throw 'Sparse screenshot measurement did not identify a uniform sample grid.'
    }
    $unsampledVariation = Measure-ScreenshotSparseVariation `
        -Width 128 `
        -Height 128 `
        -ReadArgb {
            param($x, $y)
            if ($x -eq 1 -and $y -eq 1) { 9 } else { 7 }
        }
    if ($unsampledVariation.has_sampled_variation -or
        $unsampledVariation.sample_count -ne 4096 -or
        $unsampledVariation.distinct_sample_count -ne 1) {
        throw 'Sparse screenshot measurement claimed knowledge of an unsampled pixel.'
    }
    $sampledVariation = Measure-ScreenshotSparseVariation `
        -Width 128 `
        -Height 128 `
        -ReadArgb {
            param($x, $y)
            if ($x -eq 2 -and $y -eq 0) { 9 } else { 7 }
        }
    if (-not $sampledVariation.has_sampled_variation -or
        $sampledVariation.first_argb -ne 7 -or
        $sampledVariation.step_x -ne 2 -or
        $sampledVariation.step_y -ne 2 -or
        $sampledVariation.sample_count -ne 2 -or
        $sampledVariation.distinct_sample_count -ne 2) {
        throw 'Sparse screenshot measurement did not identify sampled variation.'
    }
    Assert-Fails {
        Measure-ScreenshotSparseVariation `
            -Width 10001 `
            -Height 10000 `
            -ReadArgb { param($x, $y) 7 }
    } 'Screenshot sample bounds exceed the resource limit'
    $bindingTokens = $null
    $bindingErrors = $null
    $runnerAst = [Management.Automation.Language.Parser]::ParseInput(
        $runnerText, [ref]$bindingTokens, [ref]$bindingErrors)
    $captureFunction = $runnerAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Save-WindowScreenshot'
    }, $true)
    $captureText = $captureFunction.Extent.Text
    $sampleIndex = $captureText.IndexOf(
        '$sampleObservation = Measure-ScreenshotSparseVariation',
        [StringComparison]::Ordinal
    )
    $diagnosticSaveIndex = $captureText.IndexOf(
        '$bitmap.Save($diagnosticPath, [Drawing.Imaging.ImageFormat]::Png)',
        [StringComparison]::Ordinal
    )
    $diagnosticHashIndex = $captureText.IndexOf(
        'sha256 = Get-LowerSha256 -Path $diagnosticPath',
        [StringComparison]::Ordinal
    )
    $diagnosticObservationIndex = $captureText.IndexOf(
        '-NotePropertyName solid_image_diagnostic',
        [StringComparison]::Ordinal
    )
    $solidFailureIndex = $captureText.IndexOf(
        'throw "$Label screenshot is a solid image."',
        [StringComparison]::Ordinal
    )
    if ($sampleIndex -lt 0 -or
        $diagnosticSaveIndex -le $sampleIndex -or
        $diagnosticObservationIndex -le $diagnosticSaveIndex -or
        $diagnosticHashIndex -le $diagnosticObservationIndex -or
        $solidFailureIndex -le $diagnosticHashIndex) {
        throw 'Sparse-solid capture must preserve and hash the exact failed bitmap before failing.'
    }
    $failureSelectionIndex = $hostRunnerText.IndexOf(
        '$failureDiagnostics = @(Get-CoreGuiFailureDiagnosticOutputs -Gui $result.gui)',
        [StringComparison]::Ordinal
    )
    $acceptedOutputLoopIndex = $hostRunnerText.IndexOf(
        'foreach ($output in $outputs)',
        $failureSelectionIndex,
        [StringComparison]::Ordinal
    )
    $failureOutputLoopIndex = $hostRunnerText.IndexOf(
        'foreach ($diagnosticOutput in $failureDiagnostics)',
        $acceptedOutputLoopIndex,
        [StringComparison]::Ordinal
    )
    if ($failureSelectionIndex -lt 0 -or
        $acceptedOutputLoopIndex -le $failureSelectionIndex -or
        $failureOutputLoopIndex -le $acceptedOutputLoopIndex) {
        throw 'Core GUI failure diagnostics must be collected separately from accepted screenshots.'
    }
    $collectionParameter = @($captureFunction.Body.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -ceq 'ForegroundObservations'
    })
    if ($collectionParameter.Count -ne 1) { throw 'Screenshot observation parameter is missing.' }
    $bindingProbe = [scriptblock]::Create(
        'param(' + $collectionParameter[0].Extent.Text + ') $ForegroundObservations.Add("first"); $ForegroundObservations.Count')
    $emptyObservations = [Collections.Generic.List[object]]::new()
    if ((& $bindingProbe -ForegroundObservations $emptyObservations) -ne 1 -or
        $emptyObservations.Count -ne 1) {
        throw 'The first screenshot must accept and populate the initially empty observation list.'
    }
    foreach ($requiredCoreRegistrationSource in @(
        'var providerType = typeof(UIAutomationClientsideProviders.UIAutomationClientSideProviders);',
        'var providerName = providerType.Assembly.GetName();',
        'providerName.Name = providerType.Namespace;',
        'RegisterClientSideProviderAssembly(providerName);'
    )) {
        if ($runnerText.IndexOf($requiredCoreRegistrationSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The UI Automation initializer is missing the Core-safe provider registration '$requiredCoreRegistrationSource'."
        }
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-NativeCapture
        if ($null -eq [Windows.Automation.AutomationElement]::RootElement) {
            throw 'In-process PowerShell Core UI Automation initialization returned no root element.'
        }
        $initScript = @'
$ErrorActionPreference = 'Stop'
$runnerPath = 'GUEST_RUNNER_PATH'
$moduleLoaderPath = 'MODULE_LOADER_PATH'
& $runnerPath -BundleRoot 'GUEST_BUNDLE_PATH' -ExpectedSessionId 1 -ValidateOnly
$tokens = $null
$errors = $null
$fromFile = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
$fromUtf8 = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($runnerPath, [Text.Encoding]::UTF8), [ref]$tokens, [ref]$errors)
$stringNode = { param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }
$fileStrings = @($fromFile.FindAll($stringNode, $true) | ForEach-Object Value)
$utf8Strings = @($fromUtf8.FindAll($stringNode, $true) | ForEach-Object Value)
if ($fileStrings.Count -ne $utf8Strings.Count) { throw 'Guest script string decoding differs from UTF-8.' }
for ($index = 0; $index -lt $fileStrings.Count; $index++) {
    if ($fileStrings[$index] -cne $utf8Strings[$index]) { throw 'Guest script string decoding differs from UTF-8.' }
}
. $moduleLoaderPath
Invoke-DrTestPowerShellModuleScope -Kind guest -Action { Initialize-NativeCapture }
'@
        $moduleLoaderPath = Join-Path $toolingScriptsRoot 'tests/support/windows-vm-module-loader.ps1'
        $initScript = $initScript.Replace('GUEST_RUNNER_PATH', $valid.runner.Replace("'", "''")).Replace(
            'GUEST_BUNDLE_PATH',
            $valid.root.Replace("'", "''")
        ).Replace('MODULE_LOADER_PATH', $moduleLoaderPath.Replace("'", "''"))
        $encodedInit = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($initScript))
        $initStdoutPath = Join-Path $valid.root 'uia-core-init.stdout.txt'
        $initStderrPath = Join-Path $valid.root 'uia-core-init.stderr.txt'
        $launchRequestTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        $initProcess = Start-JobBoundProcess `
            -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -Arguments "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedInit" `
            -WorkingDirectory $valid.root `
            -StdoutPath $initStdoutPath `
            -StderrPath $initStderrPath
        try {
            $launchReturnedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
            if ($initProcess.ProcessCreateBeginTimestamp -lt $launchRequestTimestamp -or
                $initProcess.ProcessCreateEndTimestamp -lt $initProcess.ProcessCreateBeginTimestamp -or
                $initProcess.ProcessCreateEndTimestamp -gt $launchReturnedTimestamp -or
                $initProcess.ProcessCreateBeginTimestamp -ne $initProcess.owner.ProcessCreateBeginTimestamp -or
                $initProcess.ProcessCreateEndTimestamp -ne $initProcess.owner.ProcessCreateEndTimestamp) {
                throw 'Native process creation interval is outside its monotonic launch bounds.'
            }
            $initResult = Wait-JobBoundProcessWithOutputLimit `
                -State $initProcess `
                -StdoutPath $initStdoutPath `
                -StderrPath $initStderrPath `
                -TimeoutSeconds 30
            if ($initResult.failure_reason -or $initProcess.process.ExitCode -ne 0) {
                $initError = [IO.File]::ReadAllText($initStderrPath, [Text.Encoding]::UTF8).Trim()
                throw "Fresh PowerShell Core UI Automation initialization failed: $initError"
            }
        }
        finally {
            if (-not $initProcess.job_closed) {
                if ($initProcess.owner.ActiveProcessCount -gt 0) {
                    Stop-JobBoundProcess -State $initProcess
                }
                if (-not (Close-JobBoundProcess -State $initProcess)) {
                    throw 'Fresh PowerShell Core UI Automation initialization job did not close cleanly.'
                }
            }
            $initProcess.process.Dispose()
        }

        $previousExecutionState = Enter-TestExecutionState
        if ($previousExecutionState -isnot [uint32]) {
            throw 'The execution-state helper did not return the previous Windows flags.'
        }
        Exit-TestExecutionState -Previous $previousExecutionState

        $lockProbe = Join-Path $valid.root 'desktop-lock-probe.ps1'
        $lockProbeText = @'
if ($env:DARKRENAMER_LOCK_MODE -ceq 'runner') {
    try {
        & $env:DARKRENAMER_LOCK_RUNNER `
            -BundleRoot $env:DARKRENAMER_LOCK_BUNDLE `
            -ExpectedSessionId ([int]$env:DARKRENAMER_LOCK_SESSION)
    }
    catch {
    }
    $result = Get-Content -LiteralPath (Join-Path $env:DARKRENAMER_LOCK_BUNDLE 'result.json') -Raw |
        ConvertFrom-Json
    $state = if ($result.status -ceq 'failed' -and
        $result.failure_reason -ceq 'desktop_busy' -and
        @($result.tests).Count -eq 0 -and
        $null -eq $result.gui) { 'busy-result' } else { 'unexpected-result' }
    [IO.File]::WriteAllText($env:DARKRENAMER_LOCK_OUTPUT, $state)
    return
}
. 'MODULE_LOADER_PATH'
Invoke-DrTestPowerShellModuleScope `
    -Kind guest `
    -Action {
        param($SessionId, $OutputPath)
        $lock = Enter-DesktopTestLock -SessionId $SessionId
        try {
            $state = if ($null -eq $lock) { 'busy' } else { 'acquired' }
            [IO.File]::WriteAllText($OutputPath, $state)
        }
        finally {
            Exit-DesktopTestLock -Lock $lock
        }
    } `
    -ArgumentList @([int]$env:DARKRENAMER_LOCK_SESSION, $env:DARKRENAMER_LOCK_OUTPUT)
'@
        $lockProbeText = $lockProbeText.Replace(
            'MODULE_LOADER_PATH',
            $moduleLoaderPath.Replace("'", "''")
        )
        [IO.File]::WriteAllText($lockProbe, $lockProbeText)
        function Invoke-DesktopLockProbe {
            param(
                [Parameter(Mandatory)][string] $OutputPath,
                [switch] $RunGuest
            )

            $names = @(
                'DARKRENAMER_LOCK_RUNNER'
                'DARKRENAMER_LOCK_BUNDLE'
                'DARKRENAMER_LOCK_SESSION'
                'DARKRENAMER_LOCK_OUTPUT'
                'DARKRENAMER_LOCK_MODE'
            )
            $original = @{}
            foreach ($name in $names) {
                $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            try {
                [Environment]::SetEnvironmentVariable('DARKRENAMER_LOCK_RUNNER', $valid.runner, 'Process')
                [Environment]::SetEnvironmentVariable('DARKRENAMER_LOCK_BUNDLE', $valid.root, 'Process')
                [Environment]::SetEnvironmentVariable('DARKRENAMER_LOCK_SESSION', [string][Diagnostics.Process]::GetCurrentProcess().SessionId, 'Process')
                [Environment]::SetEnvironmentVariable('DARKRENAMER_LOCK_OUTPUT', $OutputPath, 'Process')
                $mode = if ($RunGuest) { 'runner' } else { 'probe' }
                [Environment]::SetEnvironmentVariable('DARKRENAMER_LOCK_MODE', $mode, 'Process')
                & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $lockProbe
                if ($LASTEXITCODE -ne 0) {
                    throw "Desktop lock probe failed with exit code $LASTEXITCODE."
                }
            }
            finally {
                foreach ($name in $names) {
                    [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
                }
            }
            [IO.File]::ReadAllText($OutputPath)
        }

        $currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $parentLock = Enter-DesktopTestLock -SessionId $currentSession
        if ($null -eq $parentLock) {
            throw 'The desktop lock fixture could not acquire its initial lock.'
        }
        try {
            $busyState = Invoke-DesktopLockProbe -OutputPath (Join-Path $valid.root 'desktop-lock-busy.txt')
            if ($busyState -cne 'busy') {
                throw 'A concurrent guest process acquired the occupied desktop lock.'
            }
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                $script:protectedResultFixturePaths.Add((Join-Path $valid.root 'result.json'))
                $busyResultState = Invoke-DesktopLockProbe `
                    -OutputPath (Join-Path $valid.root 'desktop-lock-result.txt') `
                    -RunGuest
                if ($busyResultState -cne 'busy-result') {
                    throw 'A busy guest runner did not write the expected fail-closed result.'
                }
            }
        }
        finally {
            Exit-DesktopTestLock -Lock $parentLock
        }
        $releasedState = Invoke-DesktopLockProbe -OutputPath (Join-Path $valid.root 'desktop-lock-released.txt')
        if ($releasedState -cne 'acquired') {
            throw 'The desktop lock remained occupied after its owner released it.'
        }

        foreach ($expectedExitCode in @(0, 7)) {
            $nativeStdout = Join-Path $valid.root "native-exit-$expectedExitCode.stdout.txt"
            $nativeStderr = Join-Path $valid.root "native-exit-$expectedExitCode.stderr.txt"
            $ownedProcess = Start-JobBoundProcess `
                -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
                -Arguments "/d /c `"echo synthetic-exit-$expectedExitCode & exit /b $expectedExitCode`"" `
                -WorkingDirectory $valid.root `
                -StdoutPath $nativeStdout `
                -StderrPath $nativeStderr
            try {
                $ownedResult = Wait-JobBoundProcessWithOutputLimit `
                    -State $ownedProcess `
                    -StdoutPath $nativeStdout `
                    -StderrPath $nativeStderr `
                    -TimeoutSeconds 10
                if ($ownedResult.failure_reason) {
                    throw "Synthetic exit-$expectedExitCode child timed out."
                }
                if ($ownedProcess.process.ExitCode -ne $expectedExitCode) {
                    throw "Synthetic child exit code was $($ownedProcess.process.ExitCode), expected $expectedExitCode."
                }
                if ([IO.File]::ReadAllText($nativeStdout).IndexOf(
                    "synthetic-exit-$expectedExitCode",
                    [StringComparison]::Ordinal
                ) -lt 0) {
                    throw "Synthetic exit-$expectedExitCode stdout was not captured."
                }
            }
            finally {
                if (-not $ownedProcess.job_closed) {
                    if ($ownedProcess.owner.ActiveProcessCount -gt 0) {
                        Stop-JobBoundProcess -State $ownedProcess
                    }
                    if (-not (Close-JobBoundProcess -State $ownedProcess)) {
                        throw 'Synthetic native exit child job did not close cleanly.'
                    }
                }
                $ownedProcess.process.Dispose()
            }
        }
    }
    $summary = Read-RustTestSummary `
        -Stdout "running 2 tests`ntest alpha ... ok`ntest beta ... ignored`ntest result: ok. 1 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.01s`n" `
        -Stderr ''
    if ($summary.outcome -cne 'ok' -or
        $summary.passed -ne 1 -or
        $summary.failed -ne 0 -or
        $summary.ignored -ne 1) {
        throw 'Rust test result summary was parsed incorrectly.'
    }
    Assert-Fails {
        Read-RustTestSummary -Stdout 'no summary' -Stderr ''
    } 'stdout must contain a test result summary'
    $nestedSummary = Read-RustTestSummary `
        -Stdout "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out; finished in 0.00s`ntest result: ok. 3 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.01s`n" `
        -Stderr 'test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out'
    if ($nestedSummary.passed -ne 3 -or $nestedSummary.failed -ne 0 -or
        $nestedSummary.ignored -ne 1 -or $nestedSummary.filtered -ne 0) {
        throw 'The final parent libtest summary was not selected from stdout.'
    }
    Assert-Fails {
        Read-RustTestSummary `
            -Stdout 'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 2 filtered out;' `
            -Stderr ''
    } 'must not filter tests'
    Assert-Fails {
        Read-RustTestSummary -Stdout 'test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;' -Stderr ''
    } 'reported zero tests'
    $zeroMain = Read-RustTestSummary `
        -Stdout 'test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;' `
        -Stderr '' `
        -AllowZeroTests
    if ($zeroMain.passed -ne 0 -or $zeroMain.failed -ne 0 -or $zeroMain.ignored -ne 0) {
        throw 'The explicitly allowed zero-test main harness was parsed incorrectly.'
    }

    $parsePaths = @($runner)
    if (Test-Path -LiteralPath $hostRunner -PathType Leaf) {
        $parsePaths += $hostRunner
    }
    foreach ($parsePath in $parsePaths) {
        $tokens = $null
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile($parsePath, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count -ne 0) {
            throw "PowerShell parse failed: $(($parseErrors | ForEach-Object Message) -join '; ')"
        }
    }

}
catch {
    $testFailure = $_
    throw
}
finally {
    try {
        if ($null -ne $script:VmTrustedResultWriter) {
            $script:VmTrustedResultWriter.Dispose()
            $script:VmTrustedResultWriter = $null
        }
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-ProtectedResultFixtures `
                -Root $temporaryRoot -Paths $script:protectedResultFixturePaths.ToArray()
            # PowerShell removes reparse links themselves without recursing into targets.
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $temporaryRoot) {
            throw 'The Windows VM guest test did not remove its owned fixture root.'
        }
    }
    catch {
        if ($null -eq $testFailure) { throw }
        Write-Warning "Fixture cleanup also failed: $($_.Exception.Message)"
    }
}

# Exercise the actual early capture seam without invoking Windows APIs on Linux.
& {
    $errors=$null;$tokens=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $toolingScriptsRoot 'modules/powershell/controller-entry.psm1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw $errors}
    $names=@('Initialize-DrVmSpotlightNative','New-DrVmSpotlightCaptureContext','Test-DrVmSpotlightNativeIdentity',
        'Add-DrVmSpotlightInitialObservation','Close-DrVmSpotlightCaptureContext','Get-DrVmRunnerProcesses',
        'Test-DrVmSpotlightManifestIdentity','Get-DrVmSpotlightBrokerEvidence','Test-DrVmSpotlightRegistration',
        'Test-DrVmSmartScreenBrokerEvidence','Get-DrVmCommandLineArguments','Test-DrVmCanonicalSystemBinaryPath',
        'Read-DrVmVerifiedPreflightLoaderBytes','Read-DrVmBoundedOrdinaryBytes')
    foreach($name in $names){
        $definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq ('global:'+$name)}.GetNewClosure(),$true))
        if($definitions.Count -ne 1){throw "Missing actual Spotlight function $name"}
        . ([scriptblock]::Create($definitions[0].Extent.Text.Replace('function global:','function ')))
    }
    $byteRoot=Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-preflight-bytes-'+[guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $byteRoot)
    try {
        $path=Join-Path $byteRoot 'loader.ps1';$data=[Text.Encoding]::UTF8.GetBytes('$safe=1')
        [IO.File]::WriteAllBytes($path,$data)
        $record=[pscustomobject]@{bytes=$data.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        $checked=Read-DrVmVerifiedPreflightLoaderBytes $path $record
        [IO.File]::WriteAllBytes($path,[Text.Encoding]::UTF8.GetBytes('$evil=1'))
        if([Text.Encoding]::UTF8.GetString($checked) -cne '$safe=1'){throw 'Checked loader bytes changed after pathname replacement.'}
        Assert-Fails {Read-DrVmVerifiedPreflightLoaderBytes $path $record} 'hash mismatch'
        [IO.File]::WriteAllBytes($path,[byte[]]::new(65537))
        Assert-Fails {Read-DrVmBoundedOrdinaryBytes $path 65536} 'byte length'
        Assert-Fails {Read-DrVmBoundedOrdinaryBytes $path 0} 'byte length'
        [IO.File]::WriteAllBytes($path,[byte[]]::new(0))
        if((Read-DrVmBoundedOrdinaryBytes $path 0).Length -ne 0){throw 'Exact empty stderr was not preserved.'}
    } finally {Remove-Item -LiteralPath $byteRoot -Recurse -Force}
    # Run the actual child command in an isolated runspace with a package-query
    # fixture. Progress must be suppressed before the query; real errors stop it.
    $queryLiterals=@($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value.Contains('$items=@(Get-AppxPackage -Name MicrosoftWindows.Client.CBS)')
    },$true))
    if($queryLiterals.Count -ne 1){throw 'Expected one actual CBS child query command.'}
    $queryFixture=@'
$ProgressPreference='Continue'
function Get-AppxPackage {
    Write-Progress -Activity 'Preparing modules for first use.' -Completed
    [pscustomobject]@{Name='MicrosoftWindows.Client.CBS';PackageFullName='fixture';
        PackageFamilyName='fixture';Publisher='fixture';PublisherId='fixture';Version='1.0.0.0';
        Architecture='X64';ResourceId='';InstallLocation='fixture';SignatureKind='System';
        Status='Ok';IsDevelopmentMode=$false}
}
'@
    $queryShell=[PowerShell]::Create()
    try {
        [void]$queryShell.AddScript($queryFixture+"`n"+$queryLiterals[0].Value)
        $queryOutput=@($queryShell.Invoke())
        if($queryShell.HadErrors -or $queryShell.Streams.Progress.Count -ne 0 -or $queryOutput.Count -ne 1){
            throw 'CBS child query emitted progress or lost its single JSON result.'
        }
        $queryRecord=[string]$queryOutput[0]|ConvertFrom-Json
        if($queryRecord.name -cne 'MicrosoftWindows.Client.CBS' -or $queryRecord.architecture -cne 'x64'){
            throw 'CBS child query result was changed by progress suppression.'
        }
    } finally {$queryShell.Dispose()}
    $queryShell=[PowerShell]::Create()
    try {
        [void]$queryShell.AddScript("function Get-AppxPackage { Write-Error 'fixture registration failure' }`n"+$queryLiterals[0].Value)
        $queryOutput=@();$queryFailure=$null
        try {$queryOutput=@($queryShell.Invoke())} catch {$queryFailure=$_}
        if(-not $queryShell.HadErrors -or $queryShell.InvocationStateInfo.State -ne 'Failed' -or
            $null -eq $queryFailure -or $queryOutput.Count -ne 0 -or
            $queryFailure.Exception.Message -cnotlike '*fixture registration failure*'){
            throw 'CBS child query suppressed a real registration error.'
        }
    } finally {$queryShell.Dispose()}
    Initialize-DrVmSpotlightNative
    if([Runtime.InteropServices.Marshal]::SizeOf([type][DrVmSpotlightNative+PackageInfo]) -ne 80 -or
        [Runtime.InteropServices.Marshal]::SizeOf([type][DrVmSpotlightNative+PackageId]) -ne 48 -or
        [DrVmSpotlightNative]::ProcessAccess -ne 0x101000 -or [DrVmSpotlightNative]::TokenAccess -ne 8){throw 'Native ABI/access boundary changed.'}
    # Exercise the effective-write guard from the actual raw-ACL producer.
    $manifestAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'global:Get-DrVmSpotlightManifest'},$true)
    $riskAst=$manifestAst.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$risk'},$true)
    $rootRisk=$manifestAst.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$effectiveRisk' -and $n.Right.Extent.Text -like '*-bnot*'},$true)
    $guard=$manifestAst.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($type -in @(0,9)')},$true)
    $aclCheck=[scriptblock]::Create('param($type,$flags,$sid,$mask,$isRoot) $trusted=@("S-1-5-18","S-1-5-32-544"); '+$riskAst.Extent.Text+'; $effectiveRisk=$risk; if($isRoot){'+$rootRisk.Extent.Text+'}; '+$guard.Extent.Text)
    foreach($case in @(@(0,0,'S-1-5-32-545',4,$true),@(9,0,'S-1-5-32-545',0x1200a9,$false),
        @(0,8,'S-1-5-32-545',0x500D0156,$false),@(0,0,'S-1-5-18',0x500D0156,$false))){& $aclCheck @case}
    foreach($case in @(@(0,0,'S-1-5-32-545',2,$true),@(0,0,'S-1-5-32-545',0x40,$true),
        @(9,0,'S-1-5-32-545',4,$false),@(0,0,'S-1-5-32-545',0x40000,$false))){
        Assert-Fails {& $aclCheck @case} 'effective write'
    }
    $registration=[pscustomobject]@{name='MicrosoftWindows.Client.CBS';publisher='CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US';version='1000.26100.372.0';architecture='x64'}
    $xml='<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:uap3="http://schemas.microsoft.com/appx/manifest/uap/windows10/3"><Identity Name="MicrosoftWindows.Client.CBS" Publisher="CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" Version="1000.26100.372.0" ProcessorArchitecture="x64"/><Applications><Application Id="Global.DesktopSpotlight"><Extensions>'
    foreach($entry in @('UpdateTimer','RegistrationStatusCheck','OnlineIdChange','Maintenance')){
        $kind=if($entry -ceq 'UpdateTimer'){'timer'}else{'systemEvent'}
        $xml+='<Extension Category="windows.backgroundTasks" EntryPoint="DesktopSpotlight.BackgroundTask.'+$entry+'"><BackgroundTasks><Task Type="'+$kind+'"/></BackgroundTasks></Extension>'
    }
    $xml+='<uap:Extension Category="windows.appService" EntryPoint="DesktopSpotlight.BackgroundTask.AppService"><uap3:AppService Name="com.microsoft.desktopspotlight"/></uap:Extension></Extensions></Application></Applications></Package>'
    function New-ManifestFixture([string]$Text){[pscustomobject]@{data_base64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))}}
    if(-not(Test-DrVmSpotlightManifestIdentity (New-ManifestFixture $xml) $registration)){throw 'Synthetic declared application manifest rejected.'}
    foreach($mutated in @($xml.Replace('Global.DesktopSpotlight','Wrong.Application'),
        $xml.Replace('Type="timer"','Type="systemEvent"'),$xml.Replace('com.microsoft.desktopspotlight','unrelated.service'),
        $xml.Replace('foundation/windows10','foundation/unknown'),$xml.Replace('<Applications>','<Applications><Application Id="Global.DesktopSpotlight"/>'),
        $xml.Replace('Version="1000.26100.372.0"','Version="999.1.1.1"'))){
        if(Test-DrVmSpotlightManifestIdentity (New-ManifestFixture $mutated) $registration){throw 'Manifest application/declaration mismatch accepted.'}
    }
    Assert-Fails {Test-DrVmSpotlightManifestIdentity (New-ManifestFixture ('<!DOCTYPE Package [<!ENTITY bad "unsafe">]>'+$xml)) $registration} 'DTD'
    # Use the depth actually selected by the final producer command.
    $jsonCommand=$ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -ceq 'ConvertTo-Json -Depth 16'},$true)
    if($jsonCommand.Count -ne 1){throw 'Final transport serialization depth is ambiguous.'}
    $deep=[ordered]@{raw_cleanup=[ordered]@{runner_process_natural_exit=[ordered]@{broker=[ordered]@{
        manifest=[ordered]@{path_objects=@([ordered]@{aces=@([ordered]@{ace_type=9;ace_flags=0;access_mask=[uint32]0x1200a9;sid='S-1-5-32-545'})})}
        registration=[ordered]@{preflight=[ordered]@{child_lifecycle=[ordered]@{process_job_closed=$true}}}
    }}}}
    $roundtrip=(& ([scriptblock]::Create('param($value) $value | '+$jsonCommand[0].Extent.Text)) $deep)|ConvertFrom-Json
    if($roundtrip.raw_cleanup.runner_process_natural_exit.broker.manifest.path_objects[0].aces[0].access_mask -ne 0x1200a9 -or
        -not $roundtrip.raw_cleanup.runner_process_natural_exit.broker.registration.preflight.child_lifecycle.process_job_closed){throw 'Transport truncated nested authentication evidence.'}
    $candidate=[pscustomobject]@{pid=4242;session_id=2;creation_time_utc='2026-09-29T00:00:00.0000000Z';executable_path='C:\Windows\System32\backgroundTaskHost.exe'}
    $ticks=[datetime]::Parse($candidate.creation_time_utc).ToFileTimeUtc()
    $native=@{pid=[uint32]4242;owner_sid='S-1-5-21-1-2-3-1001';session_id=[uint32]2;image_path=$candidate.executable_path
        creation_filetime_100ns=([long]($ticks+3)).ToString();open_error=0;pid_error=0;times_error=0;image_error=0
        token_error=0;token_sid_error=0;token_session_error=0}
    foreach($difference in @(0,3,9)){
        $native.creation_filetime_100ns=([long]($ticks+$difference)).ToString()
        if(-not(Test-DrVmSpotlightNativeIdentity $native $candidate $native.owner_sid 2)){throw 'Exact integer CIM normalization rejected.'}
    }
    foreach($difference in @(-1,10)){
        $native.creation_filetime_100ns=([long]($ticks+$difference)).ToString()
        if(Test-DrVmSpotlightNativeIdentity $native $candidate $native.owner_sid 2){throw 'Out-of-precision native creation accepted.'}
    }
    $native.creation_filetime_100ns=([long]($ticks+3)).ToString()
    foreach($field in @('open_error','pid_error','times_error','image_error','token_error','token_sid_error','token_session_error')){
        $native[$field]=5
        if(Test-DrVmSpotlightNativeIdentity $native $candidate $native.owner_sid 2){throw "Native failure $field accepted."}
        $native[$field]=0
    }
    $native.pid=4243
    if(Test-DrVmSpotlightNativeIdentity $native $candidate $native.owner_sid 2){throw 'Reused PID accepted.'}
    $native.pid=[uint32]4242
    $native['package_first_status']=122;$native['package_status']=0;$native['aumid_first_status']=122;$native['aumid_status']=0
    $native['package_full_name']='MicrosoftWindows.Client.CBS_1000.26100.372.0_x64__cw5n1h2txyewy'
    $native['aumid']='MicrosoftWindows.Client.CBS_cw5n1h2txyewy!Global.DesktopSpotlight'
    # Exercise the actual classifier and leaf binder; native argv parsing is mocked on Linux.
    & {
        $saved=$env:windir;$env:windir='C:\Windows'
        $candidate|Add-Member NoteProperty identity ('4242|'+$candidate.creation_time_utc)
        $preflight=[pscustomobject]@{runner_sid=$native.owner_sid;name=$registration.name;publisher=$registration.publisher
            version=$registration.version;architecture=$registration.architecture;package_full_name=$native.package_full_name
            package_family_name='MicrosoftWindows.Client.CBS_cw5n1h2txyewy';publisher_id='cw5n1h2txyewy'
            resource_id='';install_location='C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy'
            signature_kind='System';status='Ok';is_development_mode=$false
            child_lifecycle=[pscustomobject]@{pid=10;start_time_utc_ticks=([long]($ticks+504911232000000000-100)).ToString()
                exit_code=0;exited=$true;streams_complete=$true;exact_lifetime_absent=$true;process_job_closed=$true}}
        $current=@{open_status=0;first_status=122;second_status=0;close_status=0;required_bytes=658;returned_bytes=658
            count=1;request_flags=0x110;property_flags=16;caller_sid=$native.owner_sid;resource_id=$null;path=$preflight.install_location}
        foreach($key in @('name','publisher','version','architecture','package_full_name','package_family_name','publisher_id')){$current[$key]=$preflight.$key}
        $parent=[pscustomobject]@{ProcessId=1336;SessionId=0;CreationDate=[datetime]::Parse('2026-09-28T00:00:00.0000000Z')
            ExecutablePath='C:\Windows\System32\svchost.exe';CommandLine='"C:\Windows\System32\svchost.exe" -k DcomLaunch -p'}
        $parent.ExecutablePath=[IO.Path]::GetFullPath($env:windir).TrimEnd('\')+'\System32\svchost.exe'
        $parent.CommandLine='"'+$parent.ExecutablePath+'" -k DcomLaunch -p'
        $parentOwner=[pscustomobject]@{Identity=$native.Clone();Closed=$false;CloseError=0}
        foreach($key in @('package_first_status','package_status','aumid_first_status','aumid_status','package_full_name','aumid')){$parentOwner.Identity.Remove($key)}
        $parentOwner.Identity.pid=[uint32]1336;$parentOwner.Identity.owner_sid='S-1-5-18';$parentOwner.Identity.session_id=[uint32]0
        $parentOwner.Identity.creation_filetime_100ns=$parent.CreationDate.ToFileTimeUtc().ToString();$parentOwner.Identity.image_path=$parent.ExecutablePath
        $parentOwner|Add-Member ScriptMethod Poll {@{wait_result=[uint32]258}}
        $parentOwner|Add-Member ScriptMethod Dispose {$this.Closed=$true}
        $targetOwner=[pscustomobject]@{Identity=$native}
        $childMetadata=[pscustomobject]@{ProcessId=4242;SessionId=2;CreationDate=[datetime]::Parse($candidate.creation_time_utc);ParentProcessId=1336;CommandLine=$null}
        $capture=[pscustomobject]@{failed=$false;observations=@([ordered]@{attempt=1});lifetimes=@{$candidate.identity=[pscustomobject]@{owner=$targetOwner;process=$childMetadata}}}
        $token='-ServerName:Global.DesktopSpotlight.AppXz2j21w56bgxkgsjhtn7zkjsepq96erz2.mca'
        $script:command='"C:\Windows\System32\backgroundTaskHost.exe" '+$token
        $childMetadata.CommandLine=$script:command
        function Get-CimInstance {
            param($ClassName,$Filter,$OperationTimeoutSec)
            if($ClassName -ceq 'Win32_Service'){return [pscustomobject]@{Name='DcomLaunch';State='Running';ProcessId=1336}}
            if($Filter -ceq 'ProcessId=1336'){return $parent}
            throw 'A short-lived child must not be reopened by CIM during classification.'
        }
        function Open-DrVmSpotlightLifetime {param($ProcessId,[switch]$Parent) $parentOwner}
        function Get-DrVmSpotlightCurrentRegistration {param($PackageFullName) $current}
        function Get-DrVmCommandLineArguments {
            param($CommandLine)
            if($CommandLine -cnotmatch '^"([^"]+)" (.+)$'){throw 'Unexpected command fixture.'}
            ,([string[]](@($Matches[1])+@($Matches[2].Split(' '))))
        }
        function Get-DrVmSpotlightManifest {param($InstallLocation) New-ManifestFixture $xml}
        function Get-DrVmAuthenticodeEvidence {param($Path)[pscustomobject]@{status='Valid';signer_subject='CN=Microsoft Windows, O=Microsoft Corporation';signer_thumbprint='A'*40}}
        # Preserve the real ValidateSet so omitting the new leaf is a test failure.
        $pathDefinition=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'global:Test-DrVmCanonicalSystemBinaryPath'},$true)
        $pathParameters=$pathDefinition.Body.ParamBlock.Extent.Text
        . ([scriptblock]::Create('function Test-DrVmCanonicalSystemBinaryPath {'+$pathParameters+' $true }'))
        try {
            $broker=Get-DrVmSpotlightBrokerEvidence $candidate $capture $preflight $native.owner_sid 2
            if($broker.process_command_line_arguments.Count -ne 2 -or $broker.process_command_line_arguments[1] -cne $token -or -not $parentOwner.Closed){throw 'Actual classifier lost native two-argument command or parent closure.'}
            $script:command='"C:\Windows\System32\backgroundTaskHost.exe" -ServerName '+$token.Substring(12)
            $childMetadata.CommandLine=$script:command
            Assert-Fails {Get-DrVmSpotlightBrokerEvidence $candidate $capture $preflight $native.owner_sid 2} 'command identity'
            $current.resource_id=''
            if(Test-DrVmSpotlightRegistration $preflight $current $native $native.owner_sid){throw 'Native resource NULL was coerced into an empty string.'}
        } finally {$env:windir=$saved}
    }
    $script:cimCalls=0;$script:ownerCalls=0;$script:openCalls=0;$script:disposeCalls=0;$script:failOpen=$false
    $savedWindir=$env:windir;$env:windir='C:\Windows'
    function Open-DrVmSpotlightLifetime {
        param($ProcessId)
        $script:openCalls++
        if($script:failOpen){throw 'fixture Open failed'}
        $owner=[pscustomobject]@{Identity=$native.Clone();Closed=$false;CloseError=0}
        $owner|Add-Member ScriptMethod Poll { @{wait_result=[uint32]258;handle_closed=$false;close_win32_error=0} }
        $owner|Add-Member ScriptMethod Dispose {$script:disposeCalls++;$this.Closed=$true}
        $owner
    }
    function Get-CimInstance {
        param($ClassName,$Filter,$OperationTimeoutSec)
        $script:cimCalls++
        if($script:cimCalls -eq 1){
            [pscustomobject]@{ProcessId=4242;SessionId=2;CreationDate=[datetime]::Parse($candidate.creation_time_utc);ExecutablePath=$candidate.executable_path}
            [pscustomobject]@{ProcessId=5000;SessionId=2;CreationDate=[datetime]::Parse($candidate.creation_time_utc);ExecutablePath='C:\unrelated.exe'}
        }
    }
    function Invoke-CimMethod {
        param($InputObject,$MethodName,$OperationTimeoutSec)
        $script:ownerCalls++
        if($script:openCalls -ne 1){throw 'Owner lookup ran before native capture.'}
        throw 'Simulated unrelated owner failure forces a retry.'
    }
    function Start-Sleep { param($Milliseconds) }
    try {
        $context=New-DrVmSpotlightCaptureContext @()
        $snapshot=Get-DrVmRunnerProcesses -UserSid $native.owner_sid -SessionId 2 -CaptureContext $context
        if(-not $snapshot.complete -or $snapshot.attempts -ne 2 -or $snapshot.processes.Count -ne 1 -or
            $context.observations.Count -ne 1 -or $context.observations[0].attempt -ne 1 -or
            $script:openCalls -ne 1 -or $script:ownerCalls -ne 1){throw 'Early captured lifetime was lost on the empty retry.'}
        Close-DrVmSpotlightCaptureContext $context
        if($script:disposeCalls -ne 1 -or -not $context.lifetimes[$candidate.pid.ToString()+'|'+$candidate.creation_time_utc].exit.handle_closed){throw 'Held lifetime did not close.'}
        $script:cimCalls=0;$script:openCalls=0;$script:failOpen=$true
        $failed=New-DrVmSpotlightCaptureContext @()
        $snapshot=Get-DrVmRunnerProcesses -UserSid $native.owner_sid -SessionId 2 -CaptureContext $failed
        if(-not $failed.failed -or $failed.observations.Count -ne 1 -or $null -eq $failed.observations[0].capture_error){throw 'Capture error disappeared during inventory retries.'}
    } finally {$env:windir=$savedWindir}
}

function Test-DrControllerSpotlightPreflightTransport {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $toolingScriptsRoot 'modules/powershell/controller-entry.psm1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw $errors}
    # Extract the actual final guest-module expression, not a duplicate serializer.
    $boundaries=@($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.ScriptBlockAst] -and
        $null -ne $node.EndBlock -and $node.EndBlock.Statements.Count -gt 0 -and
        $node.EndBlock.Statements[-1].Extent.Text -match '^if \(\$v2\)' -and
        $node.Extent.Text.Contains('Start-JobBoundProcess -FilePath $ps5')
    },$true))
    if($boundaries.Count -ne 1){throw 'Expected one actual registration return boundary.'}
    $serializer=$boundaries[0].EndBlock.Statements[-1].Extent.Text
    $job=$null
    try {
        # Start-Job/Receive-Job uses the real remoting serializer on both hosts.
        $job=Start-Job -ArgumentList $serializer -ScriptBlock {
            param($serializer)
            $record=[pscustomobject]@{
                name='MicrosoftWindows.Client.CBS';resource_id='';is_development_mode=$false
                runner_sid='S-1-5-21-1';unknown_field='retain for strict verification'
                child_lifecycle=[ordered]@{pid=4242;start_time_utc_ticks='639262682600000000'
                    exited=$true;streams_complete=$true;exact_lifetime_absent=$true;process_job_closed=$true;exit_code=0}
            }
            $presentRecord=$record
            $childLifecycle=$record.child_lifecycle
            $engineRecord=[ordered]@{version='7.4.19';edition='Core';effective_policy='RemoteSigned'}
            $engineChild=[ordered]@{pid=4343;start_time_utc_ticks='639262682600000001'
                exited=$true;streams_complete=$true;exact_lifetime_absent=$true;process_job_closed=$true;exit_code=0}
            $record
            $v2=$false
            & ([scriptblock]::Create($serializer))
            $record=$null
            & ([scriptblock]::Create($serializer))
            $v2=$true
            & ([scriptblock]::Create($serializer))
            $record=$presentRecord
            & ([scriptblock]::Create($serializer))
        }
        if($null -eq (Wait-Job -Job $job -Timeout 30)){throw 'Registration transport regression timed out.'}
        $received=@(Receive-Job -Job $job -ErrorAction Stop)
        if($job.State -ne 'Completed'){throw 'Registration transport regression job failed.'}
    } finally {
        if($null -ne $job){
            if($job.State -notin @('Completed','Failed','Stopped')){Stop-Job -Job $job}
            Remove-Job -Job $job -Force
        }
    }
    if($received.Count -lt 1 -or $received[0].PSObject.Properties.Name -notcontains 'PSComputerName' -or
        $received[0].PSObject.Properties.Name -notcontains 'RunspaceId' -or
        $received[0].PSObject.Properties.Name -notcontains 'PSShowComputerName'){
        throw 'Direct object regression did not reproduce remoting metadata.'
    }
    if($received.Count -ne 5 -or @($received[1..4] | Where-Object {$_ -isnot [string]}).Count -ne 0){
        throw 'Actual registration boundary leaked an object or lost JSON null.'
    }
    $decoder=@($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'ConvertFrom-DrControllerSpotlightPreflightJson'
    },$true))
    if($decoder.Count -ne 1){throw 'Expected one actual registration transport decoder.'}
    . ([scriptblock]::Create($decoder[0].Extent.Text))
    $decoded=ConvertFrom-DrControllerSpotlightPreflightJson -Values @($received[1])
    $expected=$received[0].PSObject.Properties.Name|Where-Object {$_ -notin @('PSComputerName','PSShowComputerName','RunspaceId')}
    if((@($decoded.PSObject.Properties.Name|Sort-Object) -join '|') -cne (@($expected|Sort-Object) -join '|') -or
        $decoded.name -cne 'MicrosoftWindows.Client.CBS' -or $decoded.resource_id -cne '' -or
        $decoded.is_development_mode -ne $false -or $decoded.runner_sid -cne 'S-1-5-21-1' -or
        $decoded.unknown_field -cne 'retain for strict verification' -or
        -not $decoded.child_lifecycle.process_job_closed -or $decoded.child_lifecycle.pid -ne 4242 -or
        $decoded.child_lifecycle.start_time_utc_ticks -cne '639262682600000000'){
        throw 'Registration JSON changed fields, nested lifecycle, or retained unknown fields.'
    }
    if(($decoded.child_lifecycle|ConvertTo-Json -Depth 8 -Compress) -cne
        ($received[0].child_lifecycle|ConvertTo-Json -Depth 8 -Compress)){
        throw 'Registration transport changed an exact child lifecycle value.'
    }
    $unknown=ConvertFrom-DrControllerSpotlightPreflightJson -Values @(
        '{"PSComputerName":"unknown data","nested":{"null_value":null,"items":[1,false,""]}}')
    if($unknown.PSComputerName -cne 'unknown data' -or $null -ne $unknown.nested.null_value -or
        ($unknown.nested.items|ConvertTo-Json -Compress) -cne '[1,false,""]'){
        throw 'Registration decoder silently removed unknown data or changed nested values.'
    }
    if($null -ne (ConvertFrom-DrControllerSpotlightPreflightJson -Values @($received[2]))){throw 'Missing CBS registration lost JSON null.'}
    foreach($index in @(3,4)) {
        $envelope=ConvertFrom-DrControllerSpotlightPreflightJson -Values @($received[$index])
        if (($envelope.PSObject.Properties.Name | Sort-Object) -join '|' -cne
            'child_lifecycle|engine|engine_child|registration|schema_version' -or
            $envelope.schema_version -ne 2 -or
            $envelope.child_lifecycle.pid -ne 4242 -or
            $envelope.engine_child.pid -ne 4343 -or
            -not $envelope.engine_child.process_job_closed -or
            $envelope.engine.edition -cne 'Core' -or
            $envelope.engine.effective_policy -cne 'RemoteSigned' -or
            ($index -eq 3 -and $null -ne $envelope.registration) -or
            ($index -eq 4 -and $envelope.registration.name -cne 'MicrosoftWindows.Client.CBS')) {
            throw 'V2 preflight envelope lost registration availability or exact helper lifetimes.'
        }
        if (($envelope.child_lifecycle | ConvertTo-Json -Depth 8 -Compress) -cne
            ($decoded.child_lifecycle | ConvertTo-Json -Depth 8 -Compress)) {
            throw 'V2 preflight envelope changed the registration-query child lifetime.'
        }
    }
    Assert-Fails {ConvertFrom-DrControllerSpotlightPreflightJson -Values @($received[0])} 'one nonempty JSON string'
    foreach($invalid in @(@(),@(''),@(' '),@('null','null'),@(42),@($null))){
        Assert-Fails {ConvertFrom-DrControllerSpotlightPreflightJson -Values $invalid} 'one nonempty JSON string'
    }
    Assert-Fails {ConvertFrom-DrControllerSpotlightPreflightJson -Values @('{bad')} 'invalid JSON'
    foreach($invalid in @('[]','1','true','"text"')){
        Assert-Fails {ConvertFrom-DrControllerSpotlightPreflightJson -Values @($invalid)} 'object or null'
    }
    Assert-Fails {ConvertFrom-DrControllerSpotlightPreflightJson -Values @(('x'*65537))} '65536 UTF-8 bytes'
    Assert-Fails {ConvertFrom-DrControllerSpotlightPreflightJson -Values @(('é'*32769))} '65536 UTF-8 bytes'
    $limit='{"value":"'+('x'*65524)+'"}'
    if([Text.Encoding]::UTF8.GetByteCount($limit) -ne 65536 -or
        (ConvertFrom-DrControllerSpotlightPreflightJson -Values @($limit)).value.Length -ne 65524){
        throw 'Exact registration transport byte limit was not accepted.'
    }
}

Test-DrControllerSpotlightPreflightTransport

Write-Host 'Windows VM guest runner tests passed.'
