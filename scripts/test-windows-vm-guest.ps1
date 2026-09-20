[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$runner = Join-Path $PSScriptRoot 'windows-vm-guest.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-vm-guest-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temporaryRoot)
try {
    $valid = New-Fixture -Name 'valid'
    & $valid.runner -BundleRoot $valid.root -ExpectedSessionId 1 -ValidateOnly
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Assert-Fails {
            & $valid.runner -BundleRoot $valid.root -ExpectedSessionId 1
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
    & $candidate.runner -BundleRoot $candidate.root -ExpectedSessionId 1 -ValidateOnly
    . $candidate.runner -BundleRoot $candidate.root -ExpectedSessionId 1 -ValidateOnly
    $candidateContract = Resolve-VerifiedBundle `
        -Root $candidate.root `
        -InvokedScriptPath $candidate.runner
    if ($candidateContract.contract.lane -cne 'candidate-gui-only' -or
        $candidateContract.contract.product_source_sha -cne ('a' * 40) -or
        $candidateContract.contract.harness_source_sha -cne ('b' * 40) -or
        $candidateContract.tests.Count -ne 0) {
        throw 'The candidate product and harness normalization contract is invalid.'
    }

    $candidateMetadataMismatch = New-CandidateFixture -Name 'candidate-metadata-mismatch'
    $candidateMetadataMismatch.manifest.product.candidate.artifact_id = '21'
    Save-Manifest $candidateMetadataMismatch
    Assert-Fails {
        & $candidateMetadataMismatch.runner `
            -BundleRoot $candidateMetadataMismatch.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'GitHub metadata differs'

    $candidateHashMismatch = New-CandidateFixture -Name 'candidate-hash-mismatch'
    $candidateHashMismatch.manifest.product.application.sha256 = 'f' * 64
    Save-Manifest $candidateHashMismatch
    Assert-Fails {
        & $candidateHashMismatch.runner `
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
        & $candidateDuplicateMetadata.runner `
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
        & $candidateDuplicateArtifact.runner `
            -BundleRoot $candidateDuplicateArtifact.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'duplicate field: id'

    $emptyDefault = New-Fixture -Name 'empty-default'
    $emptyDefault.manifest.test_binaries = @()
    Save-Manifest $emptyDefault
    Assert-Fails {
        & $emptyDefault.runner -BundleRoot $emptyDefault.root -ExpectedSessionId 1 -ValidateOnly
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
        & $duplicateManifest.runner `
            -BundleRoot $duplicateManifest.root `
            -ExpectedSessionId 1 `
            -ValidateOnly
    } 'duplicate field: schema_version'

    $numericType = New-CandidateFixture -Name 'candidate-numeric-type'
    $numericType.manifest.schema_version = [double]2.0
    Save-Manifest $numericType
    Assert-Fails {
        & $numericType.runner -BundleRoot $numericType.root -ExpectedSessionId 1 -ValidateOnly
    } 'JSON integer 2'

    $badHash = New-Fixture -Name 'bad-hash'
    $badHash.manifest.test_binaries[0].sha256 = '2' * 64
    Save-Manifest $badHash
    Assert-Fails {
        & $badHash.runner -BundleRoot $badHash.root -ExpectedSessionId 1 -ValidateOnly
    } 'test binary hash mismatch'

    $traversal = New-Fixture -Name 'traversal'
    $traversal.manifest.test_binaries[0].file = '..\outside.exe'
    Save-Manifest $traversal
    Assert-Fails {
        & $traversal.runner -BundleRoot $traversal.root -ExpectedSessionId 1 -ValidateOnly
    } 'safe leaf filename'

    $duplicate = New-Fixture -Name 'duplicate'
    $duplicate.manifest.test_binaries += [ordered]@{
        name = 'second-test'
        file = 'CORE-TESTS.EXE'
        sha256 = $duplicate.manifest.test_binaries[0].sha256
    }
    Save-Manifest $duplicate
    Assert-Fails {
        & $duplicate.runner -BundleRoot $duplicate.root -ExpectedSessionId 1 -ValidateOnly
    } 'filenames must be unique'

    $extraField = New-Fixture -Name 'extra-field'
    $extraField.manifest.application.extra = 'untrusted'
    Save-Manifest $extraField
    Assert-Fails {
        & $extraField.runner -BundleRoot $extraField.root -ExpectedSessionId 1 -ValidateOnly
    } 'unexpected fields'

    $wrongTarget = New-Fixture -Name 'wrong-target'
    $wrongTarget.manifest.target = 'x86_64-pc-windows-gnu'
    Save-Manifest $wrongTarget
    Assert-Fails {
        & $wrongTarget.runner -BundleRoot $wrongTarget.root -ExpectedSessionId 1 -ValidateOnly
    } 'target is invalid'

    $changedRunner = New-Fixture -Name 'changed-runner'
    [IO.File]::AppendAllText($changedRunner.runner, "`n# changed")
    Assert-Fails {
        & $changedRunner.runner -BundleRoot $changedRunner.root -ExpectedSessionId 1 -ValidateOnly
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
            & $reparse.runner -BundleRoot $reparse.root -ExpectedSessionId 1 -ValidateOnly
        } 'must not be a reparse point'
    }

    . $valid.runner -BundleRoot $valid.root -ExpectedSessionId 1 -ValidateOnly
    # UI Automation providers may expose an empty Name for a valid focused control.
    if ((Get-LowerTextSha256 -Value '') -cne
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') {
        throw 'The source-bound text digest helper rejected an empty UI Automation name.'
    }
    if ((Get-LowerTextSha256 -Value 'abc') -cne
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') {
        throw 'The source-bound identity digest helper returned the wrong SHA-256 value.'
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
    $hostRunner = Join-Path $PSScriptRoot 'run-windows-vm-tests.ps1'
    $hostRunnerText = [IO.File]::ReadAllText($hostRunner)
    if ($hostRunnerText.IndexOf('-ExecutionPolicy RemoteSigned', [StringComparison]::Ordinal) -ge 0 -or
        $hostRunnerText.IndexOf('Get-Command pwsh.exe', [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf("edition -cne 'Core'", [StringComparison]::Ordinal) -lt 0 -or
        $hostRunnerText.IndexOf("effective_policy -cne 'RemoteSigned'", [StringComparison]::Ordinal) -lt 0) {
        throw 'The native scheduled task must use the inspected PowerShell 7.4+ Core RemoteSigned engine without a policy override.'
    }
    . $hostRunner -BundleRoot $valid.root -SshHost 'darkrenamer-vm'
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
        . $hostRunner -BundleRoot $valid.root -SshHost 'user@darkrenamer-vm'
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
    $runnerText = [IO.File]::ReadAllText($runner)
    $bindingTokens = $null
    $bindingErrors = $null
    $runnerAst = [Management.Automation.Language.Parser]::ParseInput(
        $runnerText, [ref]$bindingTokens, [ref]$bindingErrors)
    $captureFunction = $runnerAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Save-WindowScreenshot'
    }, $true)
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
. $runnerPath -BundleRoot 'GUEST_BUNDLE_PATH' -ExpectedSessionId 1 -ValidateOnly
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
Initialize-NativeCapture
'@
        $initScript = $initScript.Replace('GUEST_RUNNER_PATH', $valid.runner.Replace("'", "''")).Replace('GUEST_BUNDLE_PATH', $valid.root.Replace("'", "''"))
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
        [IO.File]::WriteAllText($lockProbe, @'
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
. $env:DARKRENAMER_LOCK_RUNNER `
    -BundleRoot $env:DARKRENAMER_LOCK_BUNDLE `
    -ExpectedSessionId ([int]$env:DARKRENAMER_LOCK_SESSION) `
    -ValidateOnly
$lock = Enter-DesktopTestLock -SessionId ([int]$env:DARKRENAMER_LOCK_SESSION)
try {
    $state = if ($null -eq $lock) { 'busy' } else { 'acquired' }
    [IO.File]::WriteAllText($env:DARKRENAMER_LOCK_OUTPUT, $state)
}
finally {
    Exit-DesktopTestLock -Lock $lock
}
'@)
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
