[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
$toolingScriptsRoot = $toolingTestPaths.ScriptsRoot

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $toolingScriptsRoot 'tests/support/windows-vm-module-loader.ps1')
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
        'job_active_processes_at_primary_exit',
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
        'PROTECTED_DACL_SECURITY_INFORMATION',
        'Initialize-TrustedResultWriter',
        'CreateTrustedResultFile',
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
        '-RawEvidence:$candidateLane'
    )) {
        if ($runnerText.IndexOf($requiredRawSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The shared VM-Automated raw contract is missing '$requiredRawSource'."
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
            foreach ($requestedAccess in @(0x00000001, 0x00000010, 0x00040000)) {
                $probeHandle = [DarkReNamerVmRunnerSecurityProbe]::OpenProcess(
                    [uint32]$requestedAccess, $false, [uint32]$protectedRunnerPid
                )
                if ($probeHandle -ne [IntPtr]::Zero) {
                    [void][DarkReNamerVmRunnerSecurityProbe]::CloseHandle($probeHandle)
                    throw ('The same-user process opened protected runner access 0x{0:x}.' -f
                        $requestedAccess)
                }
                if ([DarkReNamerVmRunnerSecurityProbe]::LastError -ne 5) {
                    throw ('The protected runner access check returned Win32 error {0}.' -f
                        [DarkReNamerVmRunnerSecurityProbe]::LastError)
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
        [IO.File]::WriteAllText($trustedResultPath, '{}', [Text.UTF8Encoding]::new($false))
        Initialize-TrustedResultWriter -Root $trustedResultRoot
        $writeBlockedByShare = $false
        try {
            [IO.File]::WriteAllText($trustedResultPath, '{"status":"forged"}')
        }
        catch [IO.IOException] {
            $writeBlockedByShare = $true
        }
        if (-not $writeBlockedByShare) {
            throw 'The retained result handle allowed another same-user writer.'
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
        if (-not $writeBlockedByDacl) {
            throw 'The closed result file remained writable by the same user.'
        }
        $deleteBlockedByDacl = $false
        try {
            Remove-Item -LiteralPath $trustedResultPath -Force
        }
        catch [UnauthorizedAccessException] {
            $deleteBlockedByDacl = $true
        }
        if (-not $deleteBlockedByDacl) {
            throw 'The same user removed the trusted result through its bundle directory.'
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
        $exhaustedSuiteRow = Invoke-RustTestBinary `
            -Test $valid.manifest.test_binaries[0] `
            -Root $valid.root `
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
        '(?m)^\s+Register-DrVmTask\s+`\s*$'
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
    }
    $guestEntryText = Get-Content -LiteralPath (Join-Path $toolingScriptsRoot 'modules/powershell/guest-entry.psm1') -Raw
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
        'Remove-Item -LiteralPath $runtimeRoot -Recurse -Force', [StringComparison]::Ordinal
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
    param([Parameter(Position = 0)][string] $ClassName, [string] $Filter)
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
    param([object] $InputObject, [string] $MethodName)
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
        '$cursor.Directory',
        '$cursor.Parent',
        '$trustedOutputRoot = Join-Path $trustedTaskRoot ''out''',
        'Assert-ProtectedTaskDirectory -Path $trustedTaskRoot',
        'Assert-ProtectedTaskDirectory -Path $trustedOutputRoot',
        '$resultPath = Join-Path $trustedOutputRoot $TrustedResultLeaf',
        'function Set-QuotedVmTaskPath',
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
        $initProcess = Start-OwnedProcess `
            -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -Arguments "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedInit" `
            -WorkingDirectory $valid.root `
            -RedirectOutput
        try {
            if (-not $initProcess.process.WaitForExit(30000)) {
                throw 'Fresh PowerShell Core UI Automation initialization timed out.'
            }
            $initProcess.process.WaitForExit()
            if ($initProcess.process.ExitCode -ne 0) {
                throw "Fresh PowerShell Core UI Automation initialization failed: $($initProcess.stderr_task.GetAwaiter().GetResult())"
            }
        }
        finally {
            if (-not $initProcess.process.HasExited) {
                Invoke-TaskkillTree -ProcessId $initProcess.process.Id
                [void]$initProcess.process.WaitForExit(10000)
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
            $ownedProcess = Start-OwnedProcess `
                -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
                -Arguments "/d /c `"echo synthetic-exit-$expectedExitCode & exit /b $expectedExitCode`"" `
                -WorkingDirectory $valid.root `
                -RedirectOutput
            try {
                if (-not $ownedProcess.process.WaitForExit(10000)) {
                    throw "Synthetic exit-$expectedExitCode child timed out."
                }
                $ownedProcess.process.WaitForExit()
                Save-CapturedProcessOutput `
                    -State $ownedProcess `
                    -StdoutPath $nativeStdout `
                    -StderrPath $nativeStderr
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
                if (-not $ownedProcess.process.HasExited) {
                    Invoke-TaskkillTree -ProcessId $ownedProcess.process.Id
                    [void]$ownedProcess.process.WaitForExit(10000)
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

    Write-Host 'Windows VM guest runner tests passed.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
