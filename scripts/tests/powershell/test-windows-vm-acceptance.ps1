[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
$toolingScriptsRoot = $toolingTestPaths.ScriptsRoot

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $toolingScriptsRoot 'tests/support/windows-vm-module-loader.ps1')
. (Join-Path $toolingScriptsRoot 'tests/support/protected-result-fixture-cleanup.ps1')
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind ui)) { . $definition }
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind controller)) { . $definition }

function Invoke-TestAcceptance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EntryPointPath,
        [Parameter(Mandatory)][string] $BundleRoot,
        [Parameter(Mandatory)][int] $ExpectedSessionId,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $ExpectedScriptSha256,
        [int] $TimeoutSeconds = 60,
        [ValidateSet('system', 'light', 'dark')][string] $Appearance = 'system',
        [switch] $CaptureNativeMenu,
        [switch] $CaptureAdvancedAppearance,
        [switch] $Clipboard,
        [switch] $HighContrast,
        [switch] $RestoreHighContrastOnly,
        [ValidateSet('full-context', 'standard', 'text-scale', 'tooltip', 'appearance-pair', 'performance-sample')][string] $RegressionMode,
        [string] $InputManifestPath,
        [ValidateSet(100, 150)][int] $TextScalePercent = 100,
        [switch] $RestoreTextScaleOnly,
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

    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}

function New-AcceptanceFixture {
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $SourceState = 'clean'
    )

    $taskRoot = Join-Path $script:temporaryRoot $Name
    $bundleRoot = Join-Path $taskRoot 'bundle'
    [void](New-Item -ItemType Directory -Path $bundleRoot)
    $acceptancePath = Join-Path $taskRoot 'windows-vm-acceptance.ps1'
    $runnerPath = Join-Path $bundleRoot 'windows-vm-guest.ps1'
    Copy-Item -LiteralPath $script:acceptance -Destination $acceptancePath
    [void](New-DrTestFrozenToolingBundle `
        -TaskRoot $taskRoot -Kind ui -EntrypointPaths @($acceptancePath))
    Copy-Item -LiteralPath $script:runner -Destination $runnerPath
    [IO.File]::WriteAllText((Join-Path $bundleRoot 'DarkReNamer.exe'), 'application fixture')
    [IO.File]::WriteAllText((Join-Path $bundleRoot 'fixture-tests.exe'), 'test fixture')
    $manifest = [ordered]@{
        schema_version = 1
        source_sha = '0123456789abcdef0123456789abcdef01234567'
        source_state = $SourceState
        target = 'x86_64-pc-windows-msvc'
        cargo_lock_sha256 = '1' * 64
        test_binaries = @(
            [ordered]@{
                name = 'fixture-tests'
                file = 'fixture-tests.exe'
                sha256 = Get-Sha256 (Join-Path $bundleRoot 'fixture-tests.exe')
            }
        )
        application = [ordered]@{
            file = 'DarkReNamer.exe'
            sha256 = Get-Sha256 (Join-Path $bundleRoot 'DarkReNamer.exe')
        }
        runner = [ordered]@{
            file = 'windows-vm-guest.ps1'
            sha256 = Get-Sha256 $runnerPath
        }
    }
    Write-Utf8Json -Path (Join-Path $bundleRoot 'bundle.json') -Value $manifest
    [pscustomobject]@{
        task_root = $taskRoot
        bundle_root = $bundleRoot
        output_root = Join-Path $taskRoot 'out'
        acceptance = $acceptancePath
        acceptance_sha256 = Get-Sha256 $acceptancePath
        runner = $runnerPath
        manifest = $manifest
    }
}

function New-CandidateAcceptanceFixture {
    param([Parameter(Mandatory)][string] $Name)

    $fixture = New-AcceptanceFixture -Name $Name
    Remove-Item -LiteralPath (Join-Path $fixture.bundle_root 'fixture-tests.exe')
    Copy-Item -LiteralPath $fixture.acceptance `
        -Destination (Join-Path $fixture.bundle_root 'windows-vm-acceptance.ps1')
    foreach ($row in @(
        @{ name = 'test-windows-vm.py'; content = 'launcher fixture' }
        @{ name = 'run-windows-vm-tests.ps1'; content = 'controller fixture' }
        @{ name = 'windows-vm-recovery-acceptance.ps1'; content = 'recovery observer fixture' }
        @{ name = 'validate-release-handoff.ps1'; content = 'handoff validator fixture' }
        @{ name = 'validate-release-candidate-metadata.ps1'; content = 'metadata validator fixture' }
        @{ name = 'measure-windows-binary.ps1'; content = 'binary measurement fixture' }
        @{ name = 'release-handoff.json'; content = '{"source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","workflow_run":"10","executable":{"filename":"DarkReNamer.exe","sha256":"APP_HASH"}}' }
        @{ name = 'candidate-run.json'; content = '{"id":10,"run_attempt":1,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' }
        @{ name = 'candidate-artifact.json'; content = '{"id":20,"name":"DarkReNamer-dry-run-10-1-windows","workflow_run":{"id":10,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' }
    )) {
        [IO.File]::WriteAllText((Join-Path $fixture.bundle_root $row.name), $row.content)
    }
    $applicationHash = Get-Sha256 (Join-Path $fixture.bundle_root 'DarkReNamer.exe')
    $handoffPath = Join-Path $fixture.bundle_root 'release-handoff.json'
    [IO.File]::WriteAllText(
        $handoffPath,
        ([IO.File]::ReadAllText($handoffPath).Replace('APP_HASH', $applicationHash))
    )
    $artifact = {
        param([string] $Leaf)
        [ordered]@{ file = $Leaf; sha256 = Get-Sha256 (Join-Path $fixture.bundle_root $Leaf) }
    }
    $fixture.manifest = [ordered]@{
        schema_version = 2
        lane = 'candidate-gui-only'
        target = 'x86_64-pc-windows-msvc'
        product = [ordered]@{
            source_sha = 'a' * 40
            source_state = 'clean'
            candidate = [ordered]@{
                workflow_run = '10'; run_attempt = '1'; artifact_id = '20'
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
    Write-Utf8Json -Path (Join-Path $fixture.bundle_root 'bundle.json') -Value $fixture.manifest
    $fixture
}

function Invoke-ValidateOnly([object] $Fixture) {
    Invoke-TestAcceptance -EntryPointPath $Fixture.acceptance `
        -BundleRoot $Fixture.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $Fixture.output_root `
        -ExpectedScriptSha256 $Fixture.acceptance_sha256 `
        -ValidateOnly
}

function Write-RestoreSnapshot {
    param(
        [Parameter(Mandatory)][object] $Fixture,
        [string] $SourceSha = '0123456789abcdef0123456789abcdef01234567',
        [string] $ScriptSha256 = $Fixture.acceptance_sha256,
        [uint32] $Flags = 126,
        [bool] $RestorationRequired = $true,
        [bool] $RestorationVerified = $false
    )

    if (-not (Test-Path -LiteralPath $Fixture.output_root)) {
        [void](New-Item -ItemType Directory -Path $Fixture.output_root)
    }
    $original = [ordered]@{
        flags = $Flags
        scheme = 'fixture scheme'
        colors = [ordered]@{
            window = 1
            window_text = 2
            button_face = 3
            button_text = 4
            highlight = 5
            highlight_text = 6
            gray_text = 7
            hot_light = 8
        }
        visual_style = [ordered]@{
            path = 'C:\Windows\resources\Themes\Aero\Aero.msstyles'
            color = 'NormalColor'
            size = 'NormalSize'
        }
    }
    Write-Utf8Json `
        -Path (Join-Path $Fixture.output_root 'high-contrast-restore.json') `
        -Value ([ordered]@{
            schema_version = 2
            source_sha = $SourceSha
            acceptance_script_sha256 = $ScriptSha256
            restoration_required = $RestorationRequired
            original = $original
            restoration_verified = $RestorationVerified
            restored = if (-not $RestorationRequired -and $RestorationVerified) { $original } else { $null }
        })
}

function Write-TextScaleSnapshot {
    param(
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $SourceSha,
        [Parameter(Mandatory)][string] $ScriptSha256,
        [bool] $RestorationVerified = $false
    )
    if (-not (Test-Path -LiteralPath $OutputRoot)) {
        [void](New-Item -ItemType Directory -Path $OutputRoot)
    }
    $original = [ordered]@{
        registry_key_existed = $true
        registry_value_existed = $true
        registry_value_kind = 'DWord'
        registry_value = 100
        ui_settings_raw_factor = 1.0
        ui_settings_percent = 100
    }
    Write-Utf8Json -Path (Join-Path $OutputRoot 'text-scale-snapshot.json') -Value ([ordered]@{
        schema_version = 1
        source_sha = $SourceSha
        acceptance_script_sha256 = $ScriptSha256
        restoration_required = $true
        original = $original
        restoration_verified = $RestorationVerified
        restored = if ($RestorationVerified) { $original } else { $null }
    })
}

$acceptance = Join-Path $toolingScriptsRoot 'windows-vm-acceptance.ps1'
$controller = Join-Path $toolingScriptsRoot 'run-windows-vm-tests.ps1'
$runner = Join-Path $toolingScriptsRoot 'windows-vm-guest.ps1'
$recovery = Join-Path $toolingScriptsRoot 'windows-vm-recovery-acceptance.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'darkrenamer-vm-acceptance-' + [Guid]::NewGuid().ToString('N')
)
$script:protectedResultFixturePaths = [Collections.Generic.List[string]]::new()
$testFailure = $null
[void](New-Item -ItemType Directory -Path $temporaryRoot)
try {
    $acceptanceSource = Get-DrTestCombinedPowerShellSource -Kind ui
    $controllerText = Get-DrTestCombinedPowerShellSource -Kind controller
    $runnerSource = Get-DrTestCombinedPowerShellSource -Kind guest
    $recoverySource = Get-DrTestCombinedPowerShellSource -Kind recovery
    $uiModuleSpec = Get-DrTestPowerShellModuleSpec -Kind ui
    $bomPaths = @(
        $acceptance,
        $MyInvocation.MyCommand.Path
    ) + @($uiModuleSpec.definitions) + @($uiModuleSpec.entry)
    foreach ($path in $bomPaths) {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or
            $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
            throw "$([IO.Path]::GetFileName($path)) must retain its UTF-8 BOM for Windows PowerShell 5.1."
        }
    }
    $parseErrors = $null
    $parseTokens = $null
    $acceptanceAst = [Management.Automation.Language.Parser]::ParseInput(
        $acceptanceSource, [ref]$parseTokens, [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) { throw 'The combined UI module source has parser errors.' }
    $controllerParseErrors = $null
    $controllerParseTokens = $null
    $controllerAst = [Management.Automation.Language.Parser]::ParseInput(
        $controllerText, [ref]$controllerParseTokens, [ref]$controllerParseErrors)
    if ($controllerParseErrors.Count -ne 0) {
        throw 'run-windows-vm-tests.ps1 has PowerShell parser errors.'
    }
    $runnerParseErrors = $null
    $runnerParseTokens = $null
    $runnerAst = [Management.Automation.Language.Parser]::ParseInput(
        $runnerSource, [ref]$runnerParseTokens, [ref]$runnerParseErrors)
    if ($runnerParseErrors.Count -ne 0) {
        throw 'windows-vm-guest.ps1 has PowerShell parser errors.'
    }
    $mainWindowSelector = @($runnerAst.FindAll({
        param($ast)
        $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $ast.Name -ceq 'Resolve-ExactApplicationMainWindowCandidate'
    }, $true))
    if ($mainWindowSelector.Count -ne 1) {
        throw 'The VM guest helper must define one exact application main-window selector.'
    }
    . ([scriptblock]::Create($mainWindowSelector[0].Extent.Text))

    foreach ($functionName in @(
        'Assert-PlainFile',
        'Join-GuestWindowsPath',
        'Get-SafeEvidencePathSegments',
        'Join-GuestEvidencePath',
        'Resolve-ControllerTaskSelection',
        'Assert-AcceptanceInputArtifactBinding',
        'Assert-SafeAcceptanceRunId',
        'Assert-ObserverResultBinding'
    )) {
        $pathFunctions = @($controllerAst.FindAll({
            param($ast)
            $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $ast.Name -ceq $functionName
        }, $true))
        if ($pathFunctions.Count -ne 1) {
            throw "The VM controller must define one $functionName helper."
        }
        . ([scriptblock]::Create($pathFunctions[0].Extent.Text))
    }
    $pathRewriter = @($controllerAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Set-QuotedVmTaskPath'
    }, $true))
    if ($pathRewriter.Count -ne 1) { throw 'The protected task path rewriter is ambiguous.' }
    . ([scriptblock]::Create($pathRewriter[0].Extent.Text))
    $mutablePath = Join-Path $temporaryRoot 'candidate-writable/out'
    $protectedPath = Join-Path $temporaryRoot 'trusted/out'
    $mutableArgument = '"' + [IO.Path]::GetFullPath($mutablePath) + '"'
    $protectedArgument = '"' + [IO.Path]::GetFullPath($protectedPath) + '"'
    $taskArguments = '-OutputRoot ' + $mutableArgument + ' -Other "sentinel"'
    $rewritten = Set-QuotedVmTaskPath -CurrentArguments $taskArguments -SourcePath $mutablePath -DestinationPath $protectedPath
    if ($rewritten -cne ('-OutputRoot ' + $protectedArgument + ' -Other "sentinel"')) {
        throw 'Protected task staging did not replace only its exact quoted output path.'
    }
    foreach ($invalidArguments in @('-Other "sentinel"', ($taskArguments + ' ' + $mutableArgument))) {
        Assert-Fails {
            Set-QuotedVmTaskPath -CurrentArguments $invalidArguments -SourcePath $mutablePath -DestinationPath $protectedPath
        } 'missing or ambiguous'
    }
    if ((Set-QuotedVmTaskPath -CurrentArguments '-Other "sentinel"' -SourcePath $mutablePath -DestinationPath $protectedPath -Optional) -cne '-Other "sentinel"') {
        throw 'An absent optional task output argument changed unrelated arguments.'
    }
    $selectionDefaults = @{
        RequestedKind = ''
        HasUiOutput = $false
        HasUiManifest = $false
        HasUiMode = $false
        HasUiAppearance = $false
        UiMode = ''
        UiAppearance = ''
        UiTextScalePercent = 100
        HasUiTextScalePercent = $false
        UiHighContrast = $false
        UiClipboard = $false
        UiCaptureNativeMenu = $false
        UiCaptureAdvancedAppearance = $false
        HasRecoveryOutput = $false
        HasRecoveryMode = $false
        HasRecoveryObserverSha256 = $false
        RecoveryMode = ''
        RecoveryExport = $false
        RecoveryIntentOnlyCandidateDiscard = $false
        HasRecoveryFixtureCount = $false
        TimeoutSeconds = 300
    }
    $coreSelection = Resolve-ControllerTaskSelection @selectionDefaults
    if ($coreSelection.kind -cne 'core' -or $coreSelection.is_observer) {
        throw 'The default controller task selection must preserve the native core lane.'
    }
    $uiSelectionArguments = $selectionDefaults.Clone()
    $uiSelectionArguments.HasUiOutput = $true
    $uiSelectionArguments.HasUiManifest = $true
    $uiSelectionArguments.HasUiMode = $true
    $uiSelectionArguments.HasUiAppearance = $true
    $uiSelectionArguments.UiMode = 'current-dpi'
    $uiSelectionArguments.UiAppearance = 'system'
    $uiSelectionArguments.UiHighContrast = $true
    $uiSelection = Resolve-ControllerTaskSelection @uiSelectionArguments
    if ($uiSelection.kind -cne 'ui' -or -not $uiSelection.is_observer) {
        throw 'Legacy acceptance arguments must select the shared UI observer task.'
    }
    $pairSelection = $uiSelectionArguments.Clone()
    $pairSelection.UiMode = 'appearance-pair'
    if ((Resolve-ControllerTaskSelection @pairSelection).kind -cne 'ui') {
        throw 'Controlled High Contrast appearance pair was rejected.'
    }
    $pairSelection.UiHighContrast = $false
    $pairSelection.UiAppearance = 'light'
    $pairSelection.UiTextScalePercent = 150
    $pairSelection.HasUiTextScalePercent = $true
    if ((Resolve-ControllerTaskSelection @pairSelection).kind -cne 'ui') {
        throw 'Text-150 appearance pair was rejected.'
    }
    $pairSelection.UiHighContrast = $true
    $pairSelection.UiAppearance = 'system'
    Assert-Fails { Resolve-ControllerTaskSelection @pairSelection } 'non-High-Contrast appearance-pair'
    $pairSelection.UiTextScalePercent = 100
    $pairSelection.UiAppearance = 'light'
    Assert-Fails { Resolve-ControllerTaskSelection @pairSelection } 'system appearance'
    $recoverySelectionArguments = $selectionDefaults.Clone()
    $recoverySelectionArguments.RequestedKind = 'recovery'
    $recoverySelectionArguments.HasRecoveryOutput = $true
    $recoverySelectionArguments.HasRecoveryMode = $true
    $recoverySelectionArguments.HasRecoveryObserverSha256 = $true
    $recoverySelectionArguments.RecoveryMode = 'ProcessCrash'
    $recoverySelectionArguments.RecoveryExport = $true
    $recoverySelection = Resolve-ControllerTaskSelection @recoverySelectionArguments
    if ($recoverySelection.kind -cne 'recovery' -or -not $recoverySelection.is_observer) {
        throw 'Explicit recovery arguments must select the shared recovery observer task.'
    }
    $invalidSelectionArguments = $selectionDefaults.Clone()
    $invalidSelectionArguments.RequestedKind = 'core'
    $invalidSelectionArguments.HasRecoveryOutput = $true
    Assert-Fails {
        Resolve-ControllerTaskSelection @invalidSelectionArguments
    } 'Core tasks do not accept observer arguments'
    $invalidSelectionArguments = $recoverySelectionArguments.Clone()
    $invalidSelectionArguments.RecoveryMode = 'WorkerClose'
    Assert-Fails {
        Resolve-ControllerTaskSelection @invalidSelectionArguments
    } 'require ProcessCrash mode'
    $invalidSelectionArguments = $uiSelectionArguments.Clone()
    $invalidSelectionArguments.UiCaptureAdvancedAppearance = $true
    Assert-Fails {
        Resolve-ControllerTaskSelection @invalidSelectionArguments
    } 'unavailable during High Contrast'
    $invalidSelectionArguments = $uiSelectionArguments.Clone()
    $invalidSelectionArguments.HasRecoveryOutput = $true
    Assert-Fails {
        Resolve-ControllerTaskSelection @invalidSelectionArguments
    } 'cannot be combined'
    $guestOut = Join-GuestWindowsPath `
        -Root 'C:\Users\TestUser\AppData\Local\Temp\DarkReNamerTests-fixture' `
        -Leaf 'out'
    $guestEvidence = Join-GuestWindowsPath -Root $guestOut -Leaf 'observer.stderr.txt'
    if ($guestEvidence -cne 'C:\Users\TestUser\AppData\Local\Temp\DarkReNamerTests-fixture\out\observer.stderr.txt') {
        throw 'The guest Windows path helper must compose nested paths on non-Windows hosts.'
    }
    $nestedEvidence = Join-GuestEvidencePath `
        -Root 'C:\Users\TestUser\AppData\Local\Temp\DarkReNamerTests-fixture\out' `
        -RelativePath 'recovery-acceptance-fixture/summary.json'
    if ($nestedEvidence -cne 'C:\Users\TestUser\AppData\Local\Temp\DarkReNamerTests-fixture\out\recovery-acceptance-fixture\summary.json') {
        throw 'The controller must compose validated nested recovery evidence paths.'
    }
    Assert-Fails {
        Get-SafeEvidencePathSegments '../summary.json'
    } 'Invalid relative evidence path segment'
    Assert-Fails {
        Get-SafeEvidencePathSegments 'fixture\summary.json'
    } 'Invalid relative evidence path'
    Assert-Fails {
        Get-SafeEvidencePathSegments 'fixture/NUL.txt'
    } 'Invalid Windows ordinary file name'
    Assert-Fails {
        Get-SafeEvidencePathSegments 'fixture/trailing.'
    } 'Invalid Windows ordinary file name'
    # Retain static privilege policy; executable inventory, rescue, cleanup and
    # window-selection contracts are exercised by behavior tests.
    foreach ($protectedOutputContract in @(
        '$trustedOutputRoot = Join-Path $trustedTaskRoot ''out''',
        'Assert-ProtectedTaskDirectory -Path $trustedOutputRoot',
        '$requiresPrivateRoot = $Arguments.IndexOf(',
        'if ($requiresPrivateRoot) {',
        "elseif (Test-Path -LiteralPath `$trustedPrivateRoot) {",
        '$trustedOutputArgument = ''"'' + [IO.Path]::GetFullPath($trustedOutputRoot) + ''"'''
    )) {
        if ($controllerText.IndexOf($protectedOutputContract, [StringComparison]::Ordinal) -lt 0) {
            throw "VM observer outputs are not bound to the protected output root: $protectedOutputContract"
        }
    }
    foreach ($requiredObserverSource in @(
        "-TrustedResultLeaf 'acceptance-result.json'",
        "-TrustedResultLeaf 'recovery-summary.json'",
        '-EvidenceRoot "',
        'New-DrVmGuestDirectory',
        'elseif ($recovery)',
        '-PrivateEvidenceRoot "'' + $private + ''"',
        'recovery-inventory.json',
        '-Role recovery',
        'Assert-ObserverResultBinding',
        '(-not $observerTask -or $outputPreservedForCleanup)',
        'Test-DrControllerPreservedOutputCleanupAuthorization',
        '($observerTask -and -not $acceptancePassed)'
    )) {
        if ($controllerText.IndexOf($requiredObserverSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The shared controller is missing observer contract '$requiredObserverSource'."
        }
    }
    # The cleanup boundary may inspect the exact runner identity and may only
    # terminate processes in the current run's owned roots. This is source policy,
    # separate from the observed residue and incomplete-evidence behavior tests.
    foreach ($scopePolicy in @(
        '-UserSid $taskContext.runner_sid',
        'Test-ProcessExecutableInOwnedRoots -Path $actualPath -Prefixes $prefixes'
    )) {
        if ($controllerText.IndexOf($scopePolicy, [StringComparison]::Ordinal) -lt 0) {
            throw "The controller cleanup changed its authorized process scope: $scopePolicy"
        }
    }
    foreach ($requiredEngineSource in @(
        "executable = 'pwsh.exe'",
        "effective_policy = [string]`$acceptanceEngine.effective_policy",
        "`$engine.effective_policy -cne 'RemoteSigned'",
        "`$engine.edition -cne 'Core'"
    )) {
        if ($controllerText.IndexOf($requiredEngineSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The VM controller is missing acceptance-engine evidence '$requiredEngineSource'."
        }
    }
    foreach ($requiredCandidateObserverSource in @(
        '@($manifest.harness.observers.PSObject.Properties | ForEach-Object Value)',
        '$expectedAcceptanceSourceSha = if ($candidateLane)',
        '$manifest.harness.observers.ui.file -cne ''windows-vm-acceptance.ps1''',
        '$manifest.harness.observers.ui.sha256 -ine $observer.sha256'
    )) {
        if ($controllerText.IndexOf(
            $requiredCandidateObserverSource,
            [StringComparison]::Ordinal
        ) -lt 0) {
            throw "The VM controller is missing frozen candidate observer staging '$requiredCandidateObserverSource'."
        }
    }
    # Execute each embedded engine probe against a policy enum; source counts do
    # not establish how the observation survives the remote JSON boundary.
    & {
        function Get-ExecutionPolicy { [Microsoft.PowerShell.ExecutionPolicy]::RemoteSigned }
        $probes = @($controllerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $node.Value -like '*effective_policy=*ConvertTo-Json*'
        }, $true))
        if ($probes.Count -eq 0) { throw 'No engine observation probes were exercised.' }
        foreach ($probe in $probes) {
            $observation = & ([scriptblock]::Create($probe.Value)) | ConvertFrom-Json
            if ($observation.effective_policy -isnot [string] -or
                $observation.effective_policy -cne 'RemoteSigned' -or
                $observation.edition -cne $PSVersionTable.PSEdition -or
                $observation.version -cne $PSVersionTable.PSVersion.ToString()) {
                throw 'An engine probe lost its exact version, edition or policy name in JSON.'
            }
        }
    }
    foreach ($line in @($controllerText -split "`r?`n" | Where-Object {
        $_ -match '\$observerArguments\s*=' -and $_ -notmatch '^\s*#'
    })) {
        if ($line.IndexOf('ExecutionPolicy', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw 'New GUI acceptance and rescue commands must not override execution policy.'
        }
    }
    if ($acceptanceSource.IndexOf('[ushort]', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw 'The acceptance script must use Windows PowerShell 5.1-compatible integer type names.'
    }
    $acceptanceText = $acceptanceSource
    if ($acceptanceText.IndexOf(
        'journal_after = [ordered]@{ entries = @() }',
        [StringComparison]::Ordinal
    ) -ge 0) {
        throw 'UI cleanup must not serialize an unobserved journal as an empty inventory.'
    }
    function Get-UiObserverFinalizerBody {
        param([Parameter(Mandatory)][string] $FunctionName)

        $functionAst = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $FunctionName
        }, $true)
        $finalizers = @($functionAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and
                $null -ne $node.Finally -and
                $node.Finally.Extent.Text.IndexOf(
                    'Write-ResultDocument', [StringComparison]::Ordinal
                ) -ge 0
        }, $true))
        if ($finalizers.Count -ne 1) {
            throw "Expected one publishing finalizer in $FunctionName."
        }
        $text = $finalizers[0].Finally.Extent.Text
        [scriptblock]::Create($text.Substring(1, $text.Length - 2))
    }
    function Invoke-UiObserverFinalizerFixture {
        param(
            [Parameter(Mandatory)][scriptblock] $Finalizer,
            [Parameter(Mandatory)][ValidateSet('current-dpi', 'regression')][string] $Mode,
            [Parameter(Mandatory)][bool] $InventoryFailure,
            [AllowNull()][string] $InitialFailureReason,
            [ValidateSet('source-built','candidate-gui-only')][string] $RegressionLane =
                'candidate-gui-only'
        )

        & {
            $caseRoot = Join-Path $temporaryRoot (
                'finalizer-' + $Mode + '-' + $RegressionLane + '-' +
                    [Guid]::NewGuid().ToString('N')
            )
            [void](New-Item -ItemType Directory -Path $caseRoot)
            $diagnosticPath = Join-Path $caseRoot 'acceptance-error.txt'
            $hasInitialFailure = -not [string]::IsNullOrEmpty($InitialFailureReason)
            $originalDiagnostic = if ($hasInitialFailure) {
                "original diagnostic: $InitialFailureReason"
            }
            else { $null }
            if ($null -ne $originalDiagnostic) {
                [IO.File]::WriteAllText(
                    $diagnosticPath,
                    $originalDiagnostic,
                    [Text.UTF8Encoding]::new($false)
                )
            }
            $runtimeRoot = Join-Path $caseRoot 'absent-runtime'
            $effectiveRuntimeRoot = $runtimeRoot
            $resultPath = Join-Path $caseRoot 'acceptance-result.json'
            $observationPath = Join-Path $caseRoot 'acceptance-observations.json'
            $verifiedRoot = Join-Path $caseRoot 'verified'
            $resolvedRoot = Join-Path $caseRoot 'resolved'
            [void](New-Item -ItemType Directory -Path $verifiedRoot)
            [void](New-Item -ItemType Directory -Path $resolvedRoot)
            $resolved = [pscustomobject]@{
                root = $resolvedRoot
                lane = $RegressionLane
                target = 'x86_64-pc-windows-msvc'
                application = [pscustomobject]@{
                    file = 'DarkReNamer.exe'
                    sha256 = 'a' * 64
                }
                source_sha = '0123456789abcdef0123456789abcdef01234567'
                runner_sha256 = 'b' * 64
                script_sha256 = 'c' * 64
                product = [pscustomobject]@{ fixture = 'product' }
                harness = [pscustomobject]@{ fixture = 'harness' }
            }
            $result = if ($Mode -ceq 'regression') {
                New-GuiRegressionResult -Verified $resolved -Appearance system
            }
            else {
                [ordered]@{
                    raw_cleanup = $null
                    process_cleanup = $false
                    guest_cleanup = $false
                    screenshots = @()
                    diagnostic = $null
                    observations = $null
                }
            }
            $result.status = if ($hasInitialFailure) { 'failed' } else { 'review_required' }
            $result.failure_reason = if ($hasInitialFailure) { $InitialFailureReason } else { $null }
            $writerProbe = [ordered]@{ observations_written = $false }
            $inventoryFailureMessage = "injected $Mode CIM cleanup failure"
            function Get-CimInstance {
                [CmdletBinding()]
                param([Parameter(Position = 0)][string] $ClassName)
                if ($InventoryFailure) { throw $inventoryFailureMessage }
                @()
            }
            function Get-VmAutomatedJournalInventory { param($LocalAppData) @() }
            function Get-VmAutomatedRuntimeRootObservation {
                param($Root)
                [ordered]@{ exists = $false; entries = @() }
            }
            function Assert-AcceptanceProcessJobLedgerClosed { }
            function Exit-TestExecutionState { param($Previous) }
            function Exit-DesktopTestLock { param($Lock) }
            function Write-JsonUtf8Bom {
                param($Path, $Value)
                $writerProbe.observations_written = $true
                [IO.File]::WriteAllText(
                    $Path,
                    ($Value | ConvertTo-Json -Depth 8),
                    [Text.UTF8Encoding]::new($true)
                )
            }
            $rawCandidate = $Mode -ceq 'current-dpi'
            $rawRegression = $Mode -ceq 'regression' -and
                $RegressionLane -ceq 'candidate-gui-only'
            $verified = [pscustomobject]@{ root = $verifiedRoot }
            $lifecycle = [pscustomobject]@{ process_terminated = $true }
            $rawCheckpoints = [Collections.Generic.List[object]]::new()
            $processState = [pscustomobject]@{ process = $null }
            $Clipboard = $false
            $clipboardState = [pscustomobject]@{ owned = $false }
            $HighContrast = $false
            $highContrastState = [pscustomobject]@{ requested = $false }
            $previousExecutionState = $null
            $executionState = $null
            $desktopLock = $null
            $runtimeCleanup = $true
            $runtimeCleaned = $true
            $rawRegressionJournalAfter = $null
            $rawRegressionJournalObserved = $false
            $rawRegressionRuntimeRootAfter = $null
            $RegressionMode = 'standard'
            $textOriginal = $null
            $textChanged = $false
            $cursor = $null
            $captures = [Collections.Generic.List[object]]::new()
            $observations = [ordered]@{ fixture = $Mode }

            $writerRoot = if ($Mode -ceq 'current-dpi') { $verified.root } else { $resolved.root }
            $script:protectedResultFixturePaths.Add($resultPath)
            Initialize-TrustedResultWriter `
                -Root $writerRoot `
                -ResultRoot $caseRoot `
                -Path $resultPath
            . $Finalizer
            $publishedResult = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json

            [pscustomobject]@{
                result = $result
                writer = $writerProbe
                result_published = (Test-Path -LiteralPath $resultPath -PathType Leaf)
                published_result = $publishedResult
                original_diagnostic = $originalDiagnostic
                diagnostic = if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
                    [IO.File]::ReadAllText($diagnosticPath)
                }
                else { $null }
                diagnostic_sha256 = if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
                    Get-Sha256 $diagnosticPath
                }
                else { $null }
                inventory_failure_message = $inventoryFailureMessage
                observation_sha256 = Get-Sha256 $observationPath
                observations = [IO.File]::ReadAllText($observationPath) | ConvertFrom-Json
            }
        }
    }
    function Assert-UiObserverObservationBinding {
        param(
            [Parameter(Mandatory)][object] $Published,
            [Parameter(Mandatory)][string] $Label
        )

        $embedded = $Published.published_result.acceptance_observations |
            ConvertTo-Json -Depth 12 -Compress
        $separate = $Published.observations | ConvertTo-Json -Depth 12 -Compress
        if ($Published.published_result.observations.file -cne
                'acceptance-observations.json' -or
            $Published.published_result.observations.sha256 -cne
                $Published.observation_sha256 -or
            $embedded -cne $separate) {
            throw "$Label did not bind its exact published observations file and embedded object."
        }
    }
    $currentDpiFinalizer = Get-UiObserverFinalizerBody `
        -FunctionName 'Invoke-DrCurrentDpiAcceptanceScenario'
    $regressionFinalizer = Get-UiObserverFinalizerBody `
        -FunctionName 'Invoke-GuiRegressionAcceptance'
    foreach ($fixture in @(
        [pscustomobject]@{
            mode = 'current-dpi'
            finalizer = $currentDpiFinalizer
            failure_reason = 'original_current_dpi_failure'
        },
        [pscustomobject]@{
            mode = 'regression'
            finalizer = $regressionFinalizer
            failure_reason = 'original_regression_failure'
        }
    )) {
        $published = Invoke-UiObserverFinalizerFixture `
            -Finalizer $fixture.finalizer `
            -Mode $fixture.mode `
            -InventoryFailure $true `
            -InitialFailureReason $fixture.failure_reason
        if (-not $published.result_published -or
            -not $published.writer.observations_written -or
            $published.published_result.status -cne 'failed' -or
            $published.published_result.failure_reason -cne $fixture.failure_reason -or
            $null -ne $published.published_result.raw_cleanup.owned_processes_after -or
            $published.published_result.raw_cleanup.owned_processes_observation_error.message -cne
                $published.inventory_failure_message -or
            $published.published_result.diagnostic.sha256 -cne $published.diagnostic_sha256 -or
            -not $published.diagnostic.StartsWith(
                $published.original_diagnostic, [StringComparison]::Ordinal
            ) -or
            $published.diagnostic.IndexOf(
                $published.inventory_failure_message, [StringComparison]::Ordinal
            ) -lt 0) {
            throw "The $($fixture.mode) finalizer did not publish its retained failure and unobserved inventory."
        }
        Assert-UiObserverObservationBinding `
            -Published $published `
            -Label "$($fixture.mode) cleanup-failure result"
    }
    $passingFinalizer = Invoke-UiObserverFinalizerFixture `
        -Finalizer $regressionFinalizer `
        -Mode regression `
        -InventoryFailure $false `
        -InitialFailureReason $null
    $passingCleanupNames = @(
        $passingFinalizer.published_result.raw_cleanup.PSObject.Properties.Name | Sort-Object
    )
    $expectedPassingCleanupNames = @(
        'journal_after', 'owned_processes_after', 'runtime_root_after'
    )
    if (-not $passingFinalizer.result_published -or
        $passingFinalizer.published_result.status -cne 'review_required' -or
        $null -ne $passingFinalizer.published_result.failure_reason -or
        @($passingFinalizer.published_result.raw_cleanup.owned_processes_after).Count -ne 0 -or
        @(Compare-Object -CaseSensitive $expectedPassingCleanupNames $passingCleanupNames).Count -ne 0 -or
        $null -ne $passingFinalizer.diagnostic) {
        throw ('The observed-empty UI cleanup changed the passing raw cleanup contract: ' +
            "published=$($passingFinalizer.result_published); " +
            "status=$($passingFinalizer.published_result.status); " +
            "reason=$($passingFinalizer.published_result.failure_reason); " +
            "owned=$(@($passingFinalizer.published_result.raw_cleanup.owned_processes_after).Count); " +
            "keys=$($passingCleanupNames -join ','); " +
            "diagnostic=$($null -ne $passingFinalizer.diagnostic)")
    }
    Assert-UiObserverObservationBinding `
        -Published $passingFinalizer `
        -Label 'candidate GUI regression result'
    $sourceFinalizer = Invoke-UiObserverFinalizerFixture `
        -Finalizer $regressionFinalizer `
        -Mode regression `
        -InventoryFailure $false `
        -InitialFailureReason $null `
        -RegressionLane source-built
    if (-not $sourceFinalizer.result_published -or
        $sourceFinalizer.published_result.schema_version -ne 1 -or
        $sourceFinalizer.published_result.status -cne 'review_required' -or
        $sourceFinalizer.published_result.PSObject.Properties.Name -ccontains 'raw_cleanup') {
        throw 'The source-built GUI regression finalizer changed its result contract.'
    }
    Assert-UiObserverObservationBinding `
        -Published $sourceFinalizer `
        -Label 'source-built GUI regression result'
    $mixedTreeAssignments = @($acceptanceAst.FindAll({
        param($ast)
        $ast -is [Management.Automation.Language.AssignmentStatementAst] -and
            $ast.Left.Extent.Text -ceq '$mixedTreeText'
    }, $true))
    if ($mixedTreeAssignments.Count -ne 1) {
        throw 'The mixed confirmation tree must have one text projection.'
    }
    $mixedConfirmation = [ordered]@{
        tree = @(
            [pscustomobject]@{ name = 'first' },
            [pscustomobject]@{ name = '' },
            [pscustomobject]@{ name = 'last' }
        )
    }
    $mixedTreeText = $null
    . ([scriptblock]::Create($mixedTreeAssignments[0].Extent.Text))
    if ($mixedTreeText -cne "first`nlast") {
        throw 'The mixed confirmation text projection must read and filter the returned tree rows.'
    }
    & {
        $regressionFunction = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-GuiRegressionAcceptance'
        }, $true)
        $appearanceCalls = @($regressionFunction.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Invoke-ObserverAppearancePairScenario'
        }, $true))
        if ($appearanceCalls.Count -ne 1) {
            throw 'Expected one nested appearance-pair scenario dispatch.'
        }
        $dispatch = [scriptblock]::Create($appearanceCalls[0].Extent.Text)
        function Invoke-ObserverAppearancePairScenario {
            param(
                $Verified, $RuntimeRoot, $EvidenceRoot, $SessionId,
                $WaitSeconds, $SourceSha, $AcceptanceScriptSha256,
                [switch] $HighContrast, $ObservationSink, $Captures, $ProcessLifecycleObservations
            )
            $ObservationSink['source_sha'] = $SourceSha
            if ($dispatchFailure) { throw 'fixture transition failure after original observation' }
            $SourceSha
        }
        foreach ($sourceSha in @(('a' * 40), ('b' * 40))) {
            $observedSourceSha = & {
                $manifestInput = [pscustomobject]@{ source_sha = $sourceSha }
                $verified = $null
                $effectiveRuntimeRoot = 'runtime'
                $resolved = [pscustomobject]@{ output_root = 'evidence' }
                $session = 1
                $TimeoutSeconds = 60
                $ExpectedScriptSha256 = 'c' * 64
                $HighContrast = $false
                $dispatchFailure = $false
                $scenarioSink = [ordered]@{}
                $captures = [Collections.Generic.List[object]]::new()
                $processLifecycleObservations = @()
                & $dispatch
            }
            if ($observedSourceSha -cne $sourceSha) {
                throw 'Nested appearance-pair dispatch lost its manifest source SHA.'
            }
        }
        # Execute the production dispatch block, including its original sink
        # assignments, and fail inside the observer after recording evidence.
        $dispatchBlock = $appearanceCalls[0].Parent
        while ($dispatchBlock -isnot [Management.Automation.Language.StatementBlockAst]) {
            $dispatchBlock = $dispatchBlock.Parent
        }
        $dispatchBody = [scriptblock]::Create(($dispatchBlock.Statements.Extent.Text -join "`n"))
        $manifestInput = [pscustomobject]@{ source_sha = 'd' * 40 }
        $verified = $null
        $effectiveRuntimeRoot = 'runtime'
        $resolved = [pscustomobject]@{ output_root = 'evidence' }
        $session = 1; $TimeoutSeconds = 60; $ExpectedScriptSha256 = 'c' * 64
        $HighContrast = $false; $dispatchFailure = $true
        $captures = [Collections.Generic.List[object]]::new()
        $processLifecycleObservations = @()
        $observations = [ordered]@{ scenario = $null }
        $result = [ordered]@{ assertions = [ordered]@{ scenario = $null } }
        Assert-Fails { . $dispatchBody } 'fixture transition failure after original observation'
        if (-not [object]::ReferenceEquals($observations.scenario, $result.assertions.scenario) -or
            $observations.scenario.source_sha -cne $manifestInput.source_sha) {
            throw 'A failed pair dispatch must retain its original mutable observations in both output documents.'
        }
    }
    & {
        $regressionFunction = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-GuiRegressionAcceptance'
        }, $true)
        $verifiedAssignment = $regressionFunction.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq '$verified'
        }, $true)
        $resolved = [pscustomobject]@{
            root = 'bundle-root'
            output_root = 'output-root'
            manifest = [pscustomobject]@{ schema_version = 2 }
            application = [pscustomobject]@{ file = 'DarkReNamer.exe'; sha256 = 'a' * 64 }
            lane = 'candidate-gui-only'
        }
        $bundleManifest = $resolved.manifest
        . ([scriptblock]::Create($verifiedAssignment.Extent.Text))
        if ($verified.root -cne $resolved.root -or
            $verified.output_root -cne $resolved.output_root -or
            $verified.application.sha256 -cne $resolved.application.sha256 -or
            $verified.lane -cne $resolved.lane) {
            throw 'GUI regression scenario binding did not retain the authenticated candidate lane.'
        }
    }
    & {
        $regressionFunction = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-GuiRegressionAcceptance'
        }, $true)
        $effectiveRuntimeAssignment = @($regressionFunction.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq '$effectiveRuntimeRoot' -and
                $node.Right.Extent.Text -ceq '$null'
        }, $true))
        if ($effectiveRuntimeAssignment.Count -ne 1) {
            throw 'GUI regression must keep validated runtime state separate from its RuntimeRoot parameter.'
        }
        $runtimeParameterClears = @($regressionFunction.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -ieq 'RuntimeRoot' -and
                $node.Right.Extent.Text -ieq '$null'
        }, $true))
        if ($runtimeParameterClears.Count -ne 0) {
            throw 'GUI regression must not clear its case-insensitive RuntimeRoot parameter.'
        }
        $runtimeGuardTry = @($regressionFunction.FindAll({
            param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and
                $node.Body.Extent.Text.IndexOf(
                    'GUI regression requires the controller-provisioned candidate runtime directory.',
                    [StringComparison]::Ordinal
                ) -ge 0
        }, $true))
        if ($runtimeGuardTry.Count -ne 1) {
            throw 'Expected one GUI regression runtime-root guard.'
        }
        $guardStatements = @($runtimeGuardTry[0].Body.Statements)
        $guardStart = -1
        $guardEnd = -1
        for ($index = 0; $index -lt $guardStatements.Count; $index++) {
            $statementText = $guardStatements[$index].Extent.Text
            if ($guardStart -lt 0 -and $statementText.IndexOf(
                    'GUI regression requires the controller-provisioned candidate runtime directory.',
                    [StringComparison]::Ordinal
                ) -ge 0) {
                $guardStart = $index
            }
            if ($statementText.Trim() -ceq
                '$effectiveRuntimeRoot = $runtimeItem.FullName') {
                $guardEnd = $index
                break
            }
        }
        if ($guardStart -lt 0 -or $guardEnd -lt $guardStart) {
            throw 'GUI regression runtime-root guard statements are incomplete.'
        }
        $initializeRuntimeState = [scriptblock]::Create(
            $effectiveRuntimeAssignment[0].Extent.Text
        )
        $validateRuntimeRoot = [scriptblock]::Create(
            [string]::Join(
                [Environment]::NewLine,
                @($guardStatements[$guardStart..$guardEnd] | ForEach-Object { $_.Extent.Text })
            )
        )
        function Invoke-RuntimeRootGuardFixture {
            param(
                [AllowNull()][AllowEmptyString()][string] $RequestedRuntimeRoot,
                [Parameter(Mandatory)][ValidateSet('source-built','candidate-gui-only')][string] $Lane,
                [Parameter(Mandatory)][Collections.IDictionary] $Probe
            )

            & {
                $RuntimeRoot = $RequestedRuntimeRoot
                $verified = [pscustomobject]@{ lane = $Lane }
                . $initializeRuntimeState
                try {
                    . $validateRuntimeRoot
                    [pscustomobject]@{
                        requested = $RuntimeRoot
                        effective = $effectiveRuntimeRoot
                        lane = $verified.lane
                    }
                }
                finally {
                    $Probe.effective = $effectiveRuntimeRoot
                }
            }
        }

        $validRuntimeRoot = Join-Path $temporaryRoot 'runtime-root-guard-valid'
        [void](New-Item -ItemType Directory -Path $validRuntimeRoot)
        foreach ($lane in @('source-built', 'candidate-gui-only')) {
            $probe = [ordered]@{ effective = 'not-observed' }
            $validated = Invoke-RuntimeRootGuardFixture `
                -RequestedRuntimeRoot $validRuntimeRoot `
                -Lane $lane `
                -Probe $probe
            if ($validated.requested -cne $validRuntimeRoot -or
                $validated.effective -cne (Get-Item -LiteralPath $validRuntimeRoot).FullName -or
                $probe.effective -cne $validated.effective -or
                $validated.lane -cne $lane) {
                throw ("GUI regression runtime-root validation lost the controller path for {0}: requested={1}; effective={2}; probe={3}; lane={4}." -f `
                    $lane, $validated.requested, $validated.effective, $probe.effective, $validated.lane)
            }
        }
        foreach ($invalidRoot in @($null, '', 'relative-runtime-root')) {
            $probe = [ordered]@{ effective = 'not-observed' }
            Assert-Fails {
                Invoke-RuntimeRootGuardFixture `
                    -RequestedRuntimeRoot $invalidRoot `
                    -Lane source-built `
                    -Probe $probe
            } 'controller-provisioned candidate runtime directory'
            if ($null -ne $probe.effective) {
                throw 'Rejected runtime input became an effective cleanup path.'
            }
        }
        $linkedRuntimeRoot = Join-Path $temporaryRoot 'runtime-root-guard-link'
        [void](New-Item -ItemType SymbolicLink -Path $linkedRuntimeRoot -Target $validRuntimeRoot)
        $probe = [ordered]@{ effective = 'not-observed' }
        Assert-Fails {
            Invoke-RuntimeRootGuardFixture `
                -RequestedRuntimeRoot $linkedRuntimeRoot `
                -Lane candidate-gui-only `
                -Probe $probe
        } 'candidate runtime root is unsafe'
        if ($null -ne $probe.effective) {
            throw 'A direct runtime reparse point became an effective cleanup path.'
        }
        $ancestorTarget = Join-Path $temporaryRoot 'runtime-root-guard-ancestor-target'
        $ancestorChild = Join-Path $ancestorTarget 'child'
        [void](New-Item -ItemType Directory -Path $ancestorChild)
        $ancestorLink = Join-Path $temporaryRoot 'runtime-root-guard-ancestor-link'
        [void](New-Item -ItemType SymbolicLink -Path $ancestorLink -Target $ancestorTarget)
        $linkedChild = Join-Path $ancestorLink 'child'
        $probe = [ordered]@{ effective = 'not-observed' }
        Assert-Fails {
            Invoke-RuntimeRootGuardFixture `
                -RequestedRuntimeRoot $linkedChild `
                -Lane source-built `
                -Probe $probe
        } 'candidate runtime path traverses a reparse point'
        if ($null -ne $probe.effective) {
            throw 'A runtime path below a reparse ancestor became an effective cleanup path.'
        }
    }
    & {
        $stateFunction = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Get-VmAutomatedFocusState'
        }, $true)
        . ([scriptblock]::Create($stateFunction.Extent.Text))
        function Get-VmAutomatedCanonicalRootPath {
            param([Parameter(Mandatory)][string] $Path)
            if ($Path -cne 'fixture-root') { throw 'Unexpected fixture root.' }
            'C:\fixture-root'
        }
        function Get-FullFileIdentity {
            param([Parameter(Mandatory)][string] $Path)
            if ($Path -cne 'fixture-root') { throw 'Unexpected identity root.' }
            [ordered]@{ volume_serial = '1' * 16; file_id = '2' * 32 }
        }
        function Get-VmAutomatedFixtureInventory {
            param([Parameter(Mandatory)][string] $FixtureRoot)
            if ($FixtureRoot -cne 'fixture-root') { throw 'Unexpected fixture root.' }
            [ordered]@{ name = 'source.txt'; kind = 'file'; bytes = 1 }
        }
        function Get-VmAutomatedJournalInventory {
            param([Parameter(Mandatory)][string] $LocalAppData)
            if ($LocalAppData -cne 'local-app-data') { throw 'Unexpected local app data.' }
            @()
        }
        $state = Get-VmAutomatedFocusState -FixtureRoot 'fixture-root' -LocalAppData 'local-app-data'
        if (@($state.fixture_entries).Count -ne 1 -or @($state.journal_entries).Count -ne 0) {
            throw 'Focus state did not preserve complete fixture and journal arrays.'
        }
    }
    & {
        $cleanupFunction = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Stop-AndDisposeAcceptanceOwnedProcess'
        }, $true)
        $startFunction = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Start-AcceptanceApplication'
        }, $true)
        . ([scriptblock]::Create($cleanupFunction.Extent.Text))
        . ([scriptblock]::Create($startFunction.Extent.Text))
        function Start-OwnedProcess {
            param($FilePath, $Arguments, $WorkingDirectory)
            $script:startupOwned
        }
        function Get-LowerSha256 {
            param([string] $Path)
            'd' * 64
        }
        function Complete-AcceptanceOwnedProcessJob {
            param($Owned, [switch] $StopActive)
            if ($Owned -ne $script:startupOwned -or -not $StopActive) {
                throw 'Startup cleanup did not stop the exact owned process job.'
            }
            $Owned.stop_requested = $true
            if ($Owned.cleanup_failure) {
                throw 'The exact owned acceptance process did not terminate.'
            }
            [pscustomobject]@{
                job_empty = $true
                job_closed = $true
                forced_termination = $false
                termination_exit_code = $null
            }
        }
        function Wait-ExactApplicationMainWindow {
            param(
                $Process, $ExpectedSession, $ExpectedClassName,
                $ExpectedTitle, $TimeoutSeconds, $Label
            )
            if ($Process -ne $script:startupOwned.process) {
                throw 'Startup validation received a different process.'
            }
            throw 'Pinned startup binding failed.'
        }
        $startupProcess = [pscustomobject]@{
            Id = 4201
            SessionId = 1
            HasExited = $false
            killed = $false
            disposed = $false
            waited_milliseconds = 0
        }
        $startupProcess | Add-Member ScriptMethod Refresh { }
        $startupProcess | Add-Member ScriptMethod Kill { $this.killed = $true }
        $startupProcess | Add-Member ScriptMethod WaitForExit {
            param([int] $Milliseconds)
            $this.waited_milliseconds = $Milliseconds
            $true
        }
        $startupProcess | Add-Member ScriptMethod Dispose { $this.disposed = $true }
        $script:startupOwned = [pscustomobject]@{
            process = $startupProcess
            owner = [pscustomobject]@{}
            process_start_time_utc_ticks = '639000000000000201'
            stop_requested = $false
            cleanup_failure = $false
        }
        $startupLifecycles = [Collections.Generic.List[object]]::new()
        Assert-Fails {
            Start-AcceptanceApplication `
                -FilePath 'fixture.exe' `
                -WorkingDirectory 'fixture-root' `
                -SessionId 1 `
                -WaitSeconds 10 `
                -Label 'startup fixture' `
                -ProcessLifecycleObservations $startupLifecycles
        } 'Pinned startup binding failed'
        if (-not $script:startupOwned.stop_requested -or -not $startupProcess.disposed -or
            $startupLifecycles.Count -ne 1 -or
            $startupLifecycles[0].process_lifecycle.pid -ne 4201 -or
            $startupLifecycles[0].process_lifecycle.start_time_utc_ticks -cne '639000000000000201') {
            throw 'Failed startup must retain its independent start identity before stopping and disposing the exact owned process job.'
        }

        $timeoutProcess = [pscustomobject]@{
            Id = 4202
            SessionId = 1
            HasExited = $false
            killed = $false
            disposed = $false
        }
        $timeoutProcess | Add-Member ScriptMethod Refresh { }
        $timeoutProcess | Add-Member ScriptMethod Kill { $this.killed = $true }
        $timeoutProcess | Add-Member ScriptMethod WaitForExit { param([int] $Milliseconds) $false }
        $timeoutProcess | Add-Member ScriptMethod Dispose { $this.disposed = $true }
        $script:startupOwned = [pscustomobject]@{
            process = $timeoutProcess
            owner = [pscustomobject]@{}
            process_start_time_utc_ticks = '639000000000000202'
            stop_requested = $false
            cleanup_failure = $true
        }
        Assert-Fails {
            Start-AcceptanceApplication `
                -FilePath 'fixture.exe' `
                -WorkingDirectory 'fixture-root' `
                -SessionId 1 `
                -WaitSeconds 10 `
                -Label 'startup cleanup-timeout fixture'
        } 'Application startup validation and exact-process cleanup both failed: Pinned startup binding failed. Cleanup: The exact owned acceptance process did not terminate.'
        if (-not $script:startupOwned.stop_requested -or -not $timeoutProcess.disposed) {
            throw 'Timed-out startup cleanup must stop and dispose the exact owned process job.'
        }
        Remove-Variable startupOwned -Scope Script
    }
    & {
        $closeFunction = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Close-AcceptanceApplication'
        }, $true)
        . ([scriptblock]::Create($closeFunction.Extent.Text))
        $script:closeProbe = @{ keyboard = 0; ordinary = 0; jobs = 0 }
        function Complete-AcceptanceOwnedProcessJob {
            param($Owned)
            if ($Owned.process -ne $script:closeProcess) {
                throw 'Close cleanup received a different process job.'
            }
            $script:closeProbe.jobs++
            [pscustomobject]@{ status = 'clean'; job_empty = $true; job_closed = $true }
        }
        function Send-AcceptanceChord {
            param($Process, $ExpectedSession, $Modifier, $VirtualKey, $Label)
            if ($Modifier -ne 0x12 -or $VirtualKey -ne 0x73) { throw 'Expected Alt+F4.' }
            $script:closeProbe.keyboard++
        }
        function Assert-ExactApplicationMainWindowBinding {
            param(
                $Process, $ExpectedSession, $MainWindowHandle, $MainWindow,
                $ExpectedClassName, $ExpectedTitle, $Label
            )
            if ([long]$MainWindowHandle -ne 5151L -or
                $ExpectedClassName -cne 'DarkReNamerWindow' -or
                $ExpectedTitle -cne 'DarkReNamer') {
                throw 'Close binding did not retain the pinned main window.'
            }
        }
        function Close-ExactApplicationMainWindow {
            param(
                $Process, $ExpectedSession, $MainWindowHandle, $MainWindow,
                $ExpectedClassName, $ExpectedTitle, $Label
            )
            Assert-ExactApplicationMainWindowBinding @PSBoundParameters
            $script:closeProbe.ordinary++
        }
        $process = [pscustomobject]@{ HasExited = $false; ExitCode = 0 }
        $process | Add-Member ScriptMethod Refresh { }
        $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) $true }
        $window = [pscustomobject]@{ }
        $window | Add-Member ScriptMethod SetFocus { }
        $script:closeProcess = $process
        $application = @{
            process = $process
            owned = [pscustomobject]@{ process = $process; owner = [pscustomobject]@{} }
            main = $window
            main_handle = [IntPtr]5151
            process_lifecycle = [ordered]@{
                exit_observed = $false
                exit_method = $null
                exit_code = $null
            }
        }
        [void](Close-AcceptanceApplication -Application $application -SessionId 1 -WaitSeconds 1 -CloseInput keyboard)
        if ($script:closeProbe.keyboard -ne 1 -or $script:closeProbe.ordinary -ne 0) {
            throw 'Keyboard close must deliver Alt+F4 through the actual close helper.'
        }
        [void](Close-AcceptanceApplication -Application $application -SessionId 1 -WaitSeconds 1 -CloseInput ordinary)
        if ($script:closeProbe.keyboard -ne 1 -or $script:closeProbe.ordinary -ne 1 -or
            $script:closeProbe.jobs -ne 2 -or
            -not $application.process_lifecycle.exit_observed -or
            $application.process_lifecycle.exit_method -cne 'normal-close' -or
            $application.process_lifecycle.exit_code -ne 0) {
            throw 'Ordinary close must target the exact pinned main window.'
        }
        Remove-Variable closeProbe -Scope Script
        Remove-Variable closeProcess -Scope Script
    }
    if ($acceptanceSource.IndexOf('. $bootstrap.runner', [StringComparison]::Ordinal) -ge 0) {
        throw 'The UI observer must not dot-source the guest executable.'
    }
    $clipboardAssignments = @($acceptanceAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -ieq 'Clipboard'
    }, $true))
    if ($clipboardAssignments.Count -ne 0) {
        throw 'The Clipboard switch must not be shadowed by a case-insensitive result variable.'
    }
    $highContrastMethodStart = $acceptanceText.IndexOf(
        'public static HighContrastSnapshot GetHighContrastSnapshot()',
        [StringComparison]::Ordinal
    )
    $highContrastMethodEnd = if ($highContrastMethodStart -ge 0) {
        $acceptanceText.IndexOf(
            'public static bool HighContrastEnabled()',
            $highContrastMethodStart,
            [StringComparison]::Ordinal
        )
    } else { -1 }
    if ($highContrastMethodStart -lt 0 -or $highContrastMethodEnd -le $highContrastMethodStart -or
        $acceptanceText.Substring(
            $highContrastMethodStart,
            $highContrastMethodEnd - $highContrastMethodStart
        ) -match 'LocalFree|FreeHGlobal') {
        throw 'The acceptance observer must retain, not free, borrowed High Contrast GET pointers.'
    }
    # GetMenuItemRect uses the root owner HWND only for top-level items; native
    # submenu observations must not reuse that HWND. Keep this narrow ABI policy.
    if ($acceptanceText.IndexOf('IntPtr itemOwner = depth == 0 ? window : IntPtr.Zero;', [StringComparison]::Ordinal) -lt 0) {
        throw 'Native submenu geometry must retain its documented null-owner ABI.'
    }
    $focusControlFunctions = @($acceptanceAst.FindAll({
        param($ast)
        $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $ast.Name -ceq 'New-VmAutomatedFocusReachabilityControl'
    }, $true))
    if ($focusControlFunctions.Count -ne 1) {
        throw 'The acceptance script must define one focus reachability control classifier.'
    }
    . ([scriptblock]::Create($focusControlFunctions[0].Extent.Text))
    $focusObservation = [ordered]@{
        automation_id = '32772'
        control_type = 'ControlType.Button'
        visible = $true
        enabled = $true
        keyboard_focusable = $false
        bounds = [ordered]@{ left = 1; top = 2; right = 3; bottom = 4 }
        pid = 20
        session_id = 3
        root_hwnd = 40
    }
    $focusControl = New-VmAutomatedFocusReachabilityControl `
        -Observation $focusObservation -Rail left -RailGroup 1
    $expectedFocusKeys = @(
        'automation_id','control_type','visible','enabled','keyboard_focusable','bounds',
        'pid','session_id','root_hwnd','rail','rail_group','expected_reachable','exclusion_reason'
    )
    if (-not $focusControl.expected_reachable -or
        $null -ne $focusControl.exclusion_reason -or
        $focusControl.keyboard_focusable -or
        $focusControl.rail_group -ne 1 -or
        @($focusControl.Keys).Count -ne $expectedFocusKeys.Count -or
        @(Compare-Object -CaseSensitive @($focusControl.Keys) $expectedFocusKeys -SyncWindow 0).Count -ne 0) {
        throw 'Roving-tab-stop rail commands must remain required when initially non-focusable.'
    }
    $focusObservation.enabled = $false
    $disabledFocusControl = New-VmAutomatedFocusReachabilityControl `
        -Observation $focusObservation -Rail right -RailGroup 2
    if ($disabledFocusControl.expected_reachable -or
        $disabledFocusControl.exclusion_reason -cne 'disabled') {
        throw 'Disabled rail commands must be explicitly excluded from focus reachability.'
    }
    $focusObservation.visible = $false
    Assert-Fails {
        New-VmAutomatedFocusReachabilityControl `
            -Observation $focusObservation -Rail right -RailGroup 2
    } 'is not visible'
    foreach ($menuHelperName in @(
        'Assert-ObserverFixturePathSegment',
        'ConvertTo-ObserverFixtureRelativePath',
        'Get-VmAutomatedNativeMenuCommandSpec',
        'ConvertTo-VmAutomatedMenuPathKey',
        'Test-VmAutomatedMenuPathEqual',
        'Assert-VmAutomatedNativeMenuTree',
        'ConvertTo-VmAutomatedMenuHighlight',
        'Assert-VmAutomatedMenuHighlightBinding'
    )) {
        $menuHelper = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $menuHelperName
        }, $true)
        if ($null -eq $menuHelper) {
            throw "The acceptance script is missing native menu helper $menuHelperName."
        }
        . ([scriptblock]::Create($menuHelper.Extent.Text))
    }
    $nativeMenuFixtureParent = '한글-매우-긴-상위-경로-A-😀'
    $menuBarRect = [pscustomobject]@{ Left = 0; Top = 0; Right = 800; Bottom = 600 }
    $nativeBarHighlight = [pscustomobject]@{
        MenuPath = [int[]]@(); Position = 0; CommandId = $null
        StateFlags = 144; Left = 86; Top = 31; Right = 171; Bottom = 50
    }
    $barHighlight = ConvertTo-VmAutomatedMenuHighlight `
        -NativeHighlights @($nativeBarHighlight) -OpenMenuPaths @() -Popups @() `
        -MainRect $menuBarRect
    if (@($barHighlight.menu_path).Count -ne 0 -or $barHighlight.position -ne 0 -or
        $barHighlight.state_flags -ne 144 -or $null -ne $barHighlight.command_id) {
        throw 'Closing a native popup must retain its observed menu-bar highlight.'
    }
    if ($null -ne (ConvertTo-VmAutomatedMenuHighlight `
            -NativeHighlights @() -OpenMenuPaths @() -Popups @() -MainRect $menuBarRect)) {
        throw 'Leaving the native menu bar must retain the observed absence of highlights.'
    }
    Assert-Fails {
        ConvertTo-VmAutomatedMenuHighlight `
            -NativeHighlights @($nativeBarHighlight, $nativeBarHighlight) `
            -OpenMenuPaths @() -Popups @() -MainRect $menuBarRect
    } 'ambiguous highlight'
    $nativeBarHighlight.MenuPath = [int[]]@(0)
    Assert-Fails {
        ConvertTo-VmAutomatedMenuHighlight `
            -NativeHighlights @($nativeBarHighlight) -OpenMenuPaths @() -Popups @() `
            -MainRect $menuBarRect
    } 'ambiguous highlight'
    $nativeBarHighlight.MenuPath = [int[]]@()
    $nativeBarHighlight.Right = 801
    Assert-Fails {
        ConvertTo-VmAutomatedMenuHighlight `
            -NativeHighlights @($nativeBarHighlight) -OpenMenuPaths @() -Popups @() `
            -MainRect $menuBarRect
    } 'outside its exact owned window'
    $nativeMenuFixtureLeaf = '한글-😀-0001-final.txt'
    $nativeMenuRelativePath = ConvertTo-ObserverFixtureRelativePath `
        -ParentSegments @($nativeMenuFixtureParent) -Leaf $nativeMenuFixtureLeaf
    if ($nativeMenuRelativePath -cne "$nativeMenuFixtureParent/$nativeMenuFixtureLeaf") {
        throw 'Native menu fixture paths must preserve Unicode segments with canonical separators.'
    }
    Assert-Fails {
        ConvertTo-ObserverFixtureRelativePath `
            -ParentSegments @('one','two','three') -Leaf 'four.txt'
    } 'depth'
    Assert-Fails {
        ConvertTo-ObserverFixtureRelativePath `
            -ParentSegments @() -Leaf ('bad-' + [char]0xD800)
    } 'UTF-16'
    Assert-Fails {
        ConvertTo-ObserverFixtureRelativePath -ParentSegments @() -Leaf 'bad.'
    } 'unsafe'
    $nativeMenuStateFunction = $acceptanceAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-VmAutomatedNativeMenuState'
    }, $true)
    $nativeMenuStateSource = $nativeMenuStateFunction.Extent.Text + $acceptanceAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-ObserverFixtureEntries'
    }, $true).Extent.Text
    & {
        . ([scriptblock]::Create($nativeMenuStateFunction.Extent.Text))
        function Get-VmAutomatedCanonicalRootPath {
            param([string] $Path)
            (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
        }
        function Get-FullFileIdentity {
            param([string] $Path)
            $digest = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($Path)
                )
            ).ToLowerInvariant()
            [ordered]@{ volume_serial = '0123456789abcdef'; file_id = $digest.Substring(0, 32) }
        }
        function Get-LowerSha256 {
            param([string] $Path)
            Get-Sha256 $Path
        }
        function Get-VmAutomatedJournalInventory { param([string] $LocalAppData) @() }

        $probeRoot = Join-Path $temporaryRoot 'native-menu-recursive-state'
        $parentA = Join-Path $probeRoot '한글-A-😀'
        $parentB = Join-Path $probeRoot '한글-B-😀'
        [void](New-Item -ItemType Directory -Path $parentA)
        [void](New-Item -ItemType Directory -Path $parentB)
        [IO.File]::WriteAllText(
            (Join-Path $parentA '한글-😀-0001-final.txt'),
            "long-name-ux-fixture-0`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            (Join-Path $parentA '한글-😀-0002-final.md'),
            "long-name-ux-fixture-1`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            (Join-Path $parentB '한글-😀-0001-final.txt'),
            "long-name-ux-fixture-2`n",
            [Text.UTF8Encoding]::new($false)
        )
        $recursiveState = Get-VmAutomatedNativeMenuState `
            -FixtureRoot $probeRoot -LocalAppData $temporaryRoot
        $expectedRelativePaths = @(
            '한글-A-😀',
            '한글-A-😀/한글-😀-0001-final.txt',
            '한글-A-😀/한글-😀-0002-final.md',
            '한글-B-😀',
            '한글-B-😀/한글-😀-0001-final.txt'
        )
        if ($recursiveState.fixture_entries.Count -ne 5 -or
            @(Compare-Object -CaseSensitive `
                @($recursiveState.fixture_entries.relative_path) `
                $expectedRelativePaths -SyncWindow 0).Count -ne 0) {
            throw 'Native menu recursive state did not retain the complete sorted Unicode fixture.'
        }
        foreach ($row in $recursiveState.fixture_entries) {
            $expectedRowKeys = @('relative_path','kind','bytes','content_sha256','file_identity')
            if (@(Compare-Object -CaseSensitive @($row.Keys) $expectedRowKeys -SyncWindow 0).Count -ne 0 -or
                $row.bytes -isnot [long]) {
                throw 'Native menu recursive state emitted a malformed fixture row.'
            }
            if ($row.kind -ceq 'directory' -and
                ($row.bytes -ne 0 -or $null -ne $row.content_sha256)) {
                throw 'Native menu directory rows must retain zero bytes and a null content digest.'
            }
            if ($row.kind -ceq 'file' -and
                ($row.bytes -ne 23 -or $row.content_sha256 -cnotmatch '^[0-9a-f]{64}$')) {
                throw 'Native menu file rows must retain their exact bytes and content digest.'
            }
        }

        $overBoundRoot = Join-Path $temporaryRoot 'native-menu-over-bound'
        [void](New-Item -ItemType Directory -Path $overBoundRoot)
        foreach ($index in 0..16) {
            [IO.File]::WriteAllBytes(
                (Join-Path $overBoundRoot ("item-{0:D2}.txt" -f $index)),
                [byte[]]@()
            )
        }
        Assert-Fails {
            Get-VmAutomatedNativeMenuState `
                -FixtureRoot $overBoundRoot -LocalAppData $temporaryRoot
        } 'exceeds sixteen entries'
    }
    $menuTree = [Collections.Generic.List[object]]::new()
    $addMenuRow = {
        param(
            [int[]] $Path,
            [int] $Position,
            [string] $Type,
            [AllowNull()][object] $CommandId,
            [bool] $Enabled
        )
        $flags = if ($Enabled) { 0 } else { 3 }
        $menuTree.Add([ordered]@{
            menu_path = $Path
            position = $Position
            item_type = $Type
            command_id = if ($null -eq $CommandId) { $null } else { [int]$CommandId }
            state_flags = [int]$flags
            enabled = $Enabled
            checked = $false
        })
    }
    foreach ($position in 0..3) {
        & $addMenuRow ([int[]]@()) $position 'submenu' $null $true
    }
    & $addMenuRow ([int[]]@(0)) 0 'command' 32791 $true
    & $addMenuRow ([int[]]@(0)) 1 'separator' $null $false
    & $addMenuRow ([int[]]@(0)) 2 'command' 32771 $false
    & $addMenuRow ([int[]]@(1)) 0 'command' 32783 $false
    & $addMenuRow ([int[]]@(1)) 1 'command' 65535 $false
    & $addMenuRow ([int[]]@(1)) 2 'separator' $null $false
    & $addMenuRow ([int[]]@(1)) 3 'command' 32798 $true
    & $addMenuRow ([int[]]@(1)) 4 'command' 32799 $true
    & $addMenuRow ([int[]]@(1)) 5 'command' 32784 $true
    & $addMenuRow ([int[]]@(1)) 6 'separator' $null $false
    & $addMenuRow ([int[]]@(1)) 7 'command' 32781 $false
    & $addMenuRow ([int[]]@(2)) 0 'command' 32800 $true
    foreach ($position in 0..4) {
        & $addMenuRow ([int[]]@(3)) $position 'submenu' $null $true
    }
    $command = 32772
    foreach ($branch in 0..3) {
        foreach ($position in 0..2) {
            & $addMenuRow ([int[]]@(3,$branch)) $position 'command' $command $true
            $command++
        }
        if ($branch -eq 2) { $command = 32788 }
        elseif ($branch -eq 3) { $command = 32785 }
    }
    foreach ($position in 0..1) {
        & $addMenuRow ([int[]]@(3,4)) $position 'command' (32785 + $position) $true
    }
    $requiredMenuSpecs = @(Assert-VmAutomatedNativeMenuTree -MenuTree $menuTree.ToArray())
    if ($requiredMenuSpecs.Count -ne 19 -or
        @($requiredMenuSpecs | Where-Object expected_enabled).Count -ne 15 -or
        @($requiredMenuSpecs | Where-Object { -not $_.expected_enabled }).Count -ne 4) {
        throw 'Native menu fixture must retain the exact required enabled and disabled command sets.'
    }
    $prefixTreeRow = @($menuTree | Where-Object { $_.command_id -eq 32773 })
    if ($prefixTreeRow.Count -ne 1 -or $prefixTreeRow[0].position -ne 1 -or
        -not (Test-VmAutomatedMenuPathEqual -Left @($prefixTreeRow[0].menu_path) -Right @(3,0))) {
        throw 'Native menu fixture must retain the exact positional path for Prefix.'
    }
    Assert-VmAutomatedMenuHighlightBinding `
        -Highlight ([ordered]@{
            menu_path = [int[]]@(3,0); position = 1; command_id = 32773
            item_rect = [ordered]@{ left = 1; top = 2; right = 3; bottom = 4 }
            state_flags = 0x80
        }) `
        -MenuTree $menuTree.ToArray()
    Assert-Fails {
        Assert-VmAutomatedMenuHighlightBinding `
            -Highlight ([ordered]@{
                menu_path = [int[]]@(3,0); position = 1; command_id = 32774
                item_rect = [ordered]@{ left = 1; top = 2; right = 3; bottom = 4 }
                state_flags = 0x80
            }) `
            -MenuTree $menuTree.ToArray()
    } 'immutable menu tree row'
    $copyMenuTree = {
        @($menuTree | ForEach-Object {
            [ordered]@{
                menu_path = [int[]]@($_.menu_path); position = [int]$_.position
                item_type = [string]$_.item_type
                command_id = if ($null -eq $_.command_id) { $null } else { [int]$_.command_id }
                state_flags = [int]$_.state_flags; enabled = [bool]$_.enabled; checked = [bool]$_.checked
            }
        })
    }
    $wrongMenuState = @(& $copyMenuTree)
    $wrongApply = @($wrongMenuState | Where-Object command_id -EQ 32771)[0]
    $wrongApply.state_flags = 0
    $wrongApply.enabled = $true
    Assert-Fails {
        Assert-VmAutomatedNativeMenuTree -MenuTree $wrongMenuState
    } 'fixed fixture'
    $duplicateMenuCommand = @(& $copyMenuTree)
    @($duplicateMenuCommand | Where-Object command_id -EQ 32791)[0].command_id = 32772
    Assert-Fails {
        Assert-VmAutomatedNativeMenuTree -MenuTree $duplicateMenuCommand
    } 'duplicated'
    $orphanedMenuPath = @(& $copyMenuTree)
    @($orphanedMenuPath | Where-Object {
        $_.menu_path.Count -eq 1 -and $_.menu_path[0] -eq 2
    })[0].menu_path = [int[]]@(9)
    $orphanedMenuPath += [ordered]@{
        menu_path = [int[]]@(2); position = 0; item_type = 'separator'; command_id = $null
        state_flags = 0; enabled = $true; checked = $false
    }
    Assert-Fails {
        Assert-VmAutomatedNativeMenuTree -MenuTree $orphanedMenuPath
    } 'parent submenu'
    $unknownMenuField = @(& $copyMenuTree)
    $unknownMenuField[0]['unexpected'] = $true
    Assert-Fails {
        Assert-VmAutomatedNativeMenuTree -MenuTree $unknownMenuField
    } 'malformed'
    $menuReachabilityFunction = $acceptanceAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-VmAutomatedNativeMenuOnlyReachability'
    }, $true)
    $menuReachabilitySource = $menuReachabilityFunction.Extent.Text
    $menuKeyFunction = $acceptanceAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-VmAutomatedMenuKey'
    }, $true)
    $menuHighlightFunction = $acceptanceAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-VmAutomatedMenuHighlight'
    }, $true)
    $closedMenuBinding = [scriptblock]::Create(
        $menuHighlightFunction.Body.ParamBlock.Extent.Text + "`n" + '$Popups.Count'
    )
    if ((& $closedMenuBinding -MainWindowHandle ([IntPtr]1) -OpenMenuPaths @() -Popups @()) -ne 0) {
        throw 'Escape must allow an empty popup inventory at the menu highlight boundary.'
    }
    $reservedInputParameters = @(
        @($menuKeyFunction, $menuReachabilityFunction) | ForEach-Object {
            $_.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ParameterAst] -and
                    $node.Name.VariablePath.UserPath -ieq 'Input'
            }, $true)
        }
    )
    if ($reservedInputParameters.Count -ne 0) {
        throw 'Native menu helpers must not shadow the PowerShell automatic $input variable.'
    }
    if ($menuReachabilitySource.IndexOf('SendMenuCommand', [StringComparison]::Ordinal) -ge 0) {
        throw 'Native menu reachability must not invoke a command programmatically.'
    }
    if ($acceptanceText.IndexOf('ContentType=WindowsRuntime', [StringComparison]::Ordinal) -ge 0) {
        throw 'Text-scale reads must use the PowerShell Core-compatible native UISettings ABI helper.'
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Initialize-TextScaleNative
        $coreTextScale = [double][DarkReNamerTextScaleNative]::ReadTextScaleFactor()
        if ([double]::IsNaN($coreTextScale) -or $coreTextScale -lt 1.0 -or $coreTextScale -gt 2.25) {
            throw 'The in-process PowerShell Core native UISettings factor is invalid.'
        }
    }
    foreach ($regressionFunction in @(
        'Invoke-GuiRegressionAcceptance',
        'Invoke-ObserverStandardScenario',
        'Invoke-ObserverContextScenario',
        'Get-ObserverNativeStaticRasterTarget',
        'Start-AcceptanceApplication',
        'Close-AcceptanceApplication'
    )) {
        if ($null -eq (Get-Command $regressionFunction -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Dot-sourcing did not load GUI regression function $regressionFunction."
        }
    }
    $commandActivation = [ordered]@{
        action = 'space'
        input_method = 'keyboard'
        virtual_key = 32
        expected_automation_id = '32773'
        focused_before = [ordered]@{
            hwnd = 200
            pid = 300
            session_id = 4
            class = 'Button'
            automation_id = '32773'
            control_type = 'ControlType.Button'
            visible = $true
            enabled = $true
            keyboard_focusable = $true
            root_hwnd = 100
        }
        foreground_before = [ordered]@{
            hwnd = 100
            process_id = 300
            session_id = 4
            window_class = 'DarkReNamerWindow'
        }
        input_sent = $false
    }
    Assert-AcceptanceCommandActivationBinding `
        -Attempt $commandActivation `
        -ExpectedProcessId 300 `
        -ExpectedSession 4 `
        -ExpectedMainWindow 100 `
        -ExpectedAutomationId '32773'
    foreach ($mutation in @('target', 'disabled', 'root', 'pid', 'session', 'foreground')) {
        $changedActivation = $commandActivation | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        switch ($mutation) {
            'target' { $changedActivation.focused_before.automation_id = '32774' }
            'disabled' { $changedActivation.focused_before.enabled = $false }
            'root' { $changedActivation.focused_before.root_hwnd = 101 }
            'pid' { $changedActivation.focused_before.pid = 301 }
            'session' { $changedActivation.focused_before.session_id = 5 }
            'foreground' { $changedActivation.foreground_before.hwnd = 102 }
        }
        Assert-Fails {
            Assert-AcceptanceCommandActivationBinding `
                -Attempt $changedActivation `
                -ExpectedProcessId 300 `
                -ExpectedSession 4 `
                -ExpectedMainWindow 100 `
                -ExpectedAutomationId '32773'
        } 'Keyboard command activation target or foreground binding is invalid'
    }
    $ownedPromptCandidate = [pscustomobject]@{
        Handle = 300L
        Owner = 100L
        ProcessId = 200
        ClassName = 'DarkReNamerInputWindow'
        Title = '이름 앞에 문자열 붙이기'
        Visible = $true
        Left = 10
        Top = 20
        Right = 310
        Bottom = 220
    }
    $unrelatedPromptWindow = [pscustomobject]@{
        Handle = 301L
        Owner = 100L
        ProcessId = 200
        ClassName = 'tooltips_class32'
        Title = ''
        Visible = $true
        Left = 0
        Top = 0
        Right = 10
        Bottom = 10
    }
    $selectedPromptCandidate = Resolve-AcceptanceOwnedInputWindowCandidate `
        -Windows @($unrelatedPromptWindow, $ownedPromptCandidate) `
        -ExpectedProcessId 200 `
        -ExpectedOwnerHandle 100L `
        -ExpectedName '이름 앞에 문자열 붙이기'
    if ($selectedPromptCandidate.Handle -ne 300L) {
        throw 'Exact owned input-window selection did not ignore unrelated process windows.'
    }
    foreach ($mutation in @('handle', 'owner', 'pid', 'class', 'title', 'hidden', 'geometry')) {
        $changedPromptCandidate = $ownedPromptCandidate | ConvertTo-Json | ConvertFrom-Json
        switch ($mutation) {
            'handle' { $changedPromptCandidate.Handle = 0L }
            'owner' { $changedPromptCandidate.Owner = 101L }
            'pid' { $changedPromptCandidate.ProcessId = 201 }
            'class' { $changedPromptCandidate.ClassName = '#32770' }
            'title' { $changedPromptCandidate.Title = '다른 창' }
            'hidden' { $changedPromptCandidate.Visible = $false }
            'geometry' { $changedPromptCandidate.Right = $changedPromptCandidate.Left }
        }
        $rejectedPromptCandidate = Resolve-AcceptanceOwnedInputWindowCandidate `
            -Windows @($changedPromptCandidate) `
            -ExpectedProcessId 200 `
            -ExpectedOwnerHandle 100L `
            -ExpectedName '이름 앞에 문자열 붙이기'
        if ($null -ne $rejectedPromptCandidate) {
            throw "Owned input-window selection accepted a $mutation mismatch."
        }
    }
    $duplicatePromptCandidate = $ownedPromptCandidate | ConvertTo-Json | ConvertFrom-Json
    $duplicatePromptCandidate.Handle = 302L
    Assert-Fails {
        Resolve-AcceptanceOwnedInputWindowCandidate `
            -Windows @($ownedPromptCandidate, $duplicatePromptCandidate) `
            -ExpectedProcessId 200 `
            -ExpectedOwnerHandle 100L `
            -ExpectedName '이름 앞에 문자열 붙이기'
    } 'matched more than one exact native window'
    $pinnedMainCandidate = [pscustomobject]@{
        Handle = 100L
        Owner = 0L
        ProcessId = 200
        ClassName = 'DarkReNamerWindow'
        Title = 'DarkReNamer'
        Visible = $true
        Left = 10
        Top = 20
        Right = 810
        Bottom = 620
    }
    $ownerlessShadowCandidate = [pscustomobject]@{
        Handle = 99L
        Owner = 0L
        ProcessId = 200
        ClassName = 'SysShadow'
        Title = ''
        Visible = $true
        Left = 600
        Top = 300
        Right = 900
        Bottom = 350
    }
    $selectedMainCandidate = Resolve-ExactApplicationMainWindowCandidate `
        -Windows @($ownerlessShadowCandidate, $pinnedMainCandidate) `
        -ExpectedProcessId 200 `
        -ExpectedClassName 'DarkReNamerWindow' `
        -ExpectedTitle 'DarkReNamer'
    if ($selectedMainCandidate.Handle -ne 100L) {
        throw 'Pinned main-window selection did not ignore an ownerless visible shadow window.'
    }
    foreach ($mutation in @('handle', 'owner', 'pid', 'class', 'title', 'hidden', 'geometry')) {
        $changedMainCandidate = $pinnedMainCandidate | ConvertTo-Json | ConvertFrom-Json
        switch ($mutation) {
            'handle' { $changedMainCandidate.Handle = 0L }
            'owner' { $changedMainCandidate.Owner = 99L }
            'pid' { $changedMainCandidate.ProcessId = 201 }
            'class' { $changedMainCandidate.ClassName = 'SysShadow' }
            'title' { $changedMainCandidate.Title = 'Other' }
            'hidden' { $changedMainCandidate.Visible = $false }
            'geometry' { $changedMainCandidate.Right = $changedMainCandidate.Left }
        }
        $rejectedMainCandidate = Resolve-ExactApplicationMainWindowCandidate `
            -Windows @($changedMainCandidate) `
            -ExpectedProcessId 200 `
            -ExpectedClassName 'DarkReNamerWindow' `
            -ExpectedTitle 'DarkReNamer'
        if ($null -ne $rejectedMainCandidate) {
            throw "Pinned main-window selection accepted a $mutation mismatch."
        }
    }
    $duplicateMainCandidate = $pinnedMainCandidate | ConvertTo-Json | ConvertFrom-Json
    $duplicateMainCandidate.Handle = 101L
    Assert-Fails {
        Resolve-ExactApplicationMainWindowCandidate `
            -Windows @($pinnedMainCandidate, $duplicateMainCandidate) `
            -ExpectedProcessId 200 `
            -ExpectedClassName 'DarkReNamerWindow' `
            -ExpectedTitle 'DarkReNamer'
    } 'matched more than one exact native window'
    foreach ($failureField in @(
        'failure_focus_reachability',
        'prefix_failure_process_windows'
    )) {
        if ($acceptanceText.IndexOf($failureField, [StringComparison]::Ordinal) -lt 0) {
            throw "Prefix failure diagnostics omit $failureField."
        }
    }
    if ($acceptanceText.IndexOf('$Verified.manifest.application', [StringComparison]::Ordinal) -ge 0) {
        throw 'GUI regression scenarios must use the normalized verified application binding.'
    }
    if ($acceptanceText.IndexOf('.MainWindowHandle', [StringComparison]::Ordinal) -ge 0) {
        throw 'Acceptance actions must not recompute the pinned application main window.'
    }
    $unboundWindowWaits = @($acceptanceAst.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.CommandAst] -or
            $node.GetCommandName() -cne 'Wait-UniqueAutomationWindow') {
            return $false
        }
        $parameters = @($node.CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.CommandParameterAst]
        } | ForEach-Object ParameterName)
        -not ($parameters -contains 'Owner') -and -not ($parameters -contains 'MainWindowHandle')
    }, $true))
    if ($unboundWindowWaits.Count -ne 0) {
        throw 'Every acceptance dialog wait must bind an owner or the exact pinned main-window handle.'
    }
    $manualNameAst = (Get-Command Set-ObserverManualName -CommandType Function).ScriptBlock.Ast
    $manualNameSuccessBranches = @($manualNameAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses.Count -eq 1 -and
            $node.Clauses[0].Item1.Extent.Text -ceq '$actual -ceq $Name'
    }, $true))
    if ($manualNameSuccessBranches.Count -ne 1) {
        throw 'Manual-name output test could not identify the exact successful observation branch.'
    }
    $manualNameSuccessText = $manualNameSuccessBranches[0].Clauses[0].Item2.Extent.Text
    $manualNameSuccess = [scriptblock]::Create($manualNameSuccessText.Substring(1, $manualNameSuccessText.Length - 2))
    $actual = 'renamed.txt'
    $Name = $actual
    $rasterTarget = $null
    $defaultManualNameOutput = @(& $manualNameSuccess)
    if ($defaultManualNameOutput.Count -ne 0) {
        throw 'Manual-name success without a raster capture must not add a null pipeline result.'
    }
    $rasterTarget = [pscustomobject]@{ id = 'prefix-input' }
    $capturedManualNameOutput = @(& $manualNameSuccess)
    if ($capturedManualNameOutput.Count -ne 1 -or
        -not [object]::ReferenceEquals($capturedManualNameOutput[0], $rasterTarget)) {
        throw 'Manual-name success with a raster capture must return exactly the observed target.'
    }
    $textScaleRoot = Join-Path $temporaryRoot 'text-scale-documents'
    $textScaleSource = '0123456789abcdef0123456789abcdef01234567'
    $textScaleScript = 'a' * 64
    Assert-Fails {
        Resolve-TextScaleRestoreDocument -OutputDirectory $textScaleRoot -SourceSha $textScaleSource -ScriptSha256 $textScaleScript
    } 'Text-scale snapshot is missing.'
    Write-TextScaleSnapshot -OutputRoot $textScaleRoot -SourceSha $textScaleSource -ScriptSha256 $textScaleScript
    $pendingTextScale = Resolve-TextScaleRestoreDocument -OutputDirectory $textScaleRoot -SourceSha $textScaleSource -ScriptSha256 $textScaleScript
    if (-not $pendingTextScale.document.restoration_required -or
        $pendingTextScale.document.restoration_verified -or
        $null -ne $pendingTextScale.document.restored -or
        $pendingTextScale.path -cne (Join-Path $textScaleRoot 'text-scale-snapshot.json')) {
        throw 'Pending text-scale rescue document did not retain the exact restoration instruction.'
    }
    Write-TextScaleSnapshot -OutputRoot $textScaleRoot -SourceSha $textScaleSource -ScriptSha256 $textScaleScript -RestorationVerified $true
    $verifiedTextScale = Resolve-TextScaleRestoreDocument -OutputDirectory $textScaleRoot -SourceSha $textScaleSource -ScriptSha256 $textScaleScript
    if (-not $verifiedTextScale.document.restoration_required -or
        -not $verifiedTextScale.document.restoration_verified -or
        -not (Test-TextScaleSnapshotEqual -Expected $verifiedTextScale.expected -Actual (
            ConvertFrom-TextScaleDocumentSnapshot -Document $verifiedTextScale.document.restored -Label 'verified fixture'
        ))) {
        throw 'Verified text-scale rescue document did not prove exact original-state restoration.'
    }
    $textScalePath = Join-Path $textScaleRoot 'text-scale-snapshot.json'
    $boolNumeric = Get-Content -LiteralPath $textScalePath -Raw | ConvertFrom-Json
    $boolNumeric.original.registry_value = $true
    Write-Utf8Json -Path $textScalePath -Value $boolNumeric
    Assert-Fails {
        Resolve-TextScaleRestoreDocument -OutputDirectory $textScaleRoot -SourceSha $textScaleSource -ScriptSha256 $textScaleScript
    } 'registry value is invalid'
    Write-TextScaleSnapshot -OutputRoot $textScaleRoot -SourceSha $textScaleSource -ScriptSha256 $textScaleScript -RestorationVerified $true
    $boolSchema = Get-Content -LiteralPath $textScalePath -Raw | ConvertFrom-Json
    $boolSchema.schema_version = $true
    Write-Utf8Json -Path $textScalePath -Value $boolSchema
    Assert-Fails {
        Resolve-TextScaleRestoreDocument -OutputDirectory $textScaleRoot -SourceSha $textScaleSource -ScriptSha256 $textScaleScript
    } 'binding mismatch'
    Initialize-AcceptanceNative
    foreach ($method in @(
        'IsWindowEnabled',
        'IsMenuCommandEnabled',
        'GetClipboardSequenceNumber',
        'ReadClipboardSnapshot',
        'ReadOrInitializeEmptyClipboardSnapshot',
        'ClearClipboardIfOwned',
        'TapExtended',
        'SetHighContrastColors',
        'ReadNativeMenuTree',
        'ReadHighlightedNativeMenuItems',
        'ReadVisibleNativeMenuPopups'
    )) {
        if ($null -eq [DarkReNamerVmAcceptanceNative].GetMethod($method)) {
            throw "The acceptance native probe is missing $method."
        }
    }
    $initializerClassifier = [DarkReNamerVmAcceptanceNative].GetMethod(
        'RequiresEmptyClipboardInitialization',
        ([Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static)
    )
    if ($null -eq $initializerClassifier) {
        throw 'The empty Clipboard initializer classifier is missing.'
    }
    $zeroEmptyClipboard = [DarkReNamerVmAcceptanceNative+ClipboardSnapshot]::new()
    $zeroEmptyClipboard.SequenceNumber = 0
    $zeroEmptyClipboard.Formats = [uint32[]]@()
    if (-not [bool]$initializerClassifier.Invoke($null, [object[]]@($zeroEmptyClipboard))) {
        throw 'A verified zero-sequence empty Clipboard must request guarded initialization.'
    }
    $nonzeroEmptyClipboard = [DarkReNamerVmAcceptanceNative+ClipboardSnapshot]::new()
    $nonzeroEmptyClipboard.SequenceNumber = 41
    $nonzeroEmptyClipboard.Formats = [uint32[]]@()
    if ([bool]$initializerClassifier.Invoke($null, [object[]]@($nonzeroEmptyClipboard))) {
        throw 'A nonzero empty Clipboard must not request initialization.'
    }
    foreach ($foreignClipboard in @(
        [DarkReNamerVmAcceptanceNative+ClipboardSnapshot]@{
            SequenceNumber = 0
            Formats = [uint32[]]@(13)
            UnicodeText = $null
        },
        [DarkReNamerVmAcceptanceNative+ClipboardSnapshot]@{
            SequenceNumber = 42
            Formats = [uint32[]]@(13)
            UnicodeText = 'foreign'
        }
    )) {
        $foreignRejected = $false
        try {
            [void]$initializerClassifier.Invoke($null, [object[]]@($foreignClipboard))
        }
        catch {
            $foreignRejected = $null -ne $_.Exception.InnerException -and
                $_.Exception.InnerException.Message.IndexOf(
                    'will not clear existing data',
                    [StringComparison]::Ordinal
                ) -ge 0
        }
        if (-not $foreignRejected) {
            throw 'A nonempty Clipboard snapshot did not fail before guarded initialization.'
        }
    }
    $clipboardEvidence = Get-AcceptanceClipboardTextEvidence `
        -Text "accepted-acceptance-source.txt`r`n"
    if ($clipboardEvidence.utf16le_bytes -ne 64 -or
        $clipboardEvidence.sha256 -cne 'bf9bd2f940bfb8b88330541879bd52c6b9b42f16e807e1b5f6591b9bfc892d92') {
        throw 'Clipboard evidence must bind the exact UTF-16LE bytes without retaining text.'
    }
    $ownedClipboard = [pscustomobject]@{
        SequenceNumber = [uint32]42
        UnicodeText = "accepted-acceptance-source.txt`r`n"
        Formats = [uint32[]]@(1, 7, 13, 16)
    }
    if (-not (Test-AcceptanceClipboardSnapshotOwned `
        -Snapshot $ownedClipboard `
        -ExpectedSequence 42 `
        -ExpectedText "accepted-acceptance-source.txt`r`n")) {
        throw 'Owned Clipboard text plus Windows-synthesized formats must be cleanup eligible.'
    }
    foreach ($foreignClipboard in @(
        [pscustomobject]@{
            SequenceNumber = [uint32]43
            UnicodeText = $ownedClipboard.UnicodeText
            Formats = $ownedClipboard.Formats
        },
        [pscustomobject]@{
            SequenceNumber = [uint32]42
            UnicodeText = "foreign`r`n"
            Formats = $ownedClipboard.Formats
        },
        [pscustomobject]@{
            SequenceNumber = [uint32]42
            UnicodeText = $ownedClipboard.UnicodeText
            Formats = [uint32[]]@(13, 49152)
        }
    )) {
        if (Test-AcceptanceClipboardSnapshotOwned `
            -Snapshot $foreignClipboard `
            -ExpectedSequence 42 `
            -ExpectedText $ownedClipboard.UnicodeText) {
            throw 'Changed sequence, text, or foreign formats must preserve the Clipboard.'
        }
    }

    $expectedClipboardText = "expected.txt`r`n"
    $expectedClipboardSnapshot = [pscustomobject]@{
        SequenceNumber = [uint32]43
        UnicodeText = $expectedClipboardText
        Formats = [uint32[]]@(1, 7, 13, 16)
    }
    $unchangedState = [pscustomobject]@{ sequence_reads = 0; snapshot_reads = 0; clock_reads = 0 }
    Assert-Fails {
        Wait-AcceptanceClipboardText `
            -PreviousSequence 42 `
            -ExpectedText $expectedClipboardText `
            -TimeoutSeconds 10 `
            -Label 'unchanged sequence fixture' `
            -ReadSequence { $unchangedState.sequence_reads++; [uint32]42 } `
            -ReadSnapshot { $unchangedState.snapshot_reads++; $expectedClipboardSnapshot } `
            -GetCurrentTime {
                $value = ([datetime]'2026-01-01T00:00:00Z').AddSeconds(11 * $unchangedState.clock_reads)
                $unchangedState.clock_reads++
                $value
            } `
            -PollMilliseconds 0
    } 'did not change the Clipboard sequence before the bounded deadline'
    if ($unchangedState.snapshot_reads -ne 0) {
        throw 'An unchanged Clipboard sequence must not open or read the Clipboard.'
    }

    $delayedState = [pscustomobject]@{ snapshot_reads = 0 }
    $delayedResult = Wait-AcceptanceClipboardText `
        -PreviousSequence 42 -ExpectedText $expectedClipboardText -TimeoutSeconds 10 `
        -Label 'native delayed rendering fixture' -AllowDelayedRendering `
        -ReadSequence { [uint32]42 } `
        -ReadSnapshot { $delayedState.snapshot_reads++; $expectedClipboardSnapshot } `
        -PollMilliseconds 0
    if ($delayedState.snapshot_reads -ne 1 -or $delayedResult.SequenceNumber -ne 43) {
        throw 'Native delayed rendering must still prove a changed stable snapshot.'
    }
    $delayedUnchanged = [pscustomobject]@{ snapshot_reads = 0; clock_reads = 0 }
    Assert-Fails {
        Wait-AcceptanceClipboardText `
            -PreviousSequence 42 -ExpectedText $expectedClipboardText -TimeoutSeconds 10 `
            -Label 'delayed unchanged fixture' -AllowDelayedRendering `
            -ReadSequence { [uint32]42 } `
            -ReadSnapshot {
                $delayedUnchanged.snapshot_reads++
                [pscustomobject]@{
                    SequenceNumber = [uint32]42
                    UnicodeText = $expectedClipboardText
                    Formats = [uint32[]]@(13)
                }
            } `
            -GetCurrentTime {
                $value = ([datetime]'2026-01-01T00:00:00Z').AddSeconds(11 * $delayedUnchanged.clock_reads)
                $delayedUnchanged.clock_reads++
                $value
            } `
            -PollMilliseconds 0
    } 'did not change the Clipboard sequence before the bounded deadline'
    if ($delayedUnchanged.snapshot_reads -ne 1) {
        throw 'Delayed rendering must perform a bounded read without accepting unchanged content.'
    }
    Assert-Fails {
        Wait-AcceptanceClipboardText `
            -PreviousSequence 42 -ExpectedText $expectedClipboardText -TimeoutSeconds 10 `
            -Label 'delayed foreign fixture' -AllowDelayedRendering `
            -ReadSequence { [uint32]42 } `
            -ReadSnapshot {
                [pscustomobject]@{
                    SequenceNumber = [uint32]43
                    UnicodeText = 'foreign'
                    Formats = [uint32[]]@(13)
                }
            } `
            -PollMilliseconds 0
    } 'changed the Clipboard to unexpected text or formats'

    $transitionState = [pscustomobject]@{ sequence_reads = 0; snapshot_reads = 0; clock_reads = 0 }
    $transitionResult = Wait-AcceptanceClipboardText `
        -PreviousSequence 42 `
        -ExpectedText $expectedClipboardText `
        -TimeoutSeconds 10 `
        -Label 'sequence transition fixture' `
        -ReadSequence {
            $transitionState.sequence_reads++
            if ($transitionState.sequence_reads -eq 1) { [uint32]42 } else { [uint32]43 }
        } `
        -ReadSnapshot { $transitionState.snapshot_reads++; $expectedClipboardSnapshot } `
        -GetCurrentTime {
            $value = ([datetime]'2026-01-01T00:00:00Z').AddSeconds($transitionState.clock_reads)
            $transitionState.clock_reads++
            $value
        } `
        -PollMilliseconds 0
    if ($transitionState.snapshot_reads -ne 1 -or $transitionResult.SequenceNumber -ne 43) {
        throw 'A changed sequence with the exact expected snapshot must succeed after one full read.'
    }

    $busyState = [pscustomobject]@{ snapshot_reads = 0; clock_reads = 0 }
    $busyResult = Wait-AcceptanceClipboardText `
        -PreviousSequence 42 `
        -ExpectedText $expectedClipboardText `
        -TimeoutSeconds 10 `
        -Label 'busy then readable fixture' `
        -ReadSequence { [uint32]43 } `
        -ReadSnapshot {
            $busyState.snapshot_reads++
            if ($busyState.snapshot_reads -eq 1) { throw 'fixture Clipboard busy' }
            $expectedClipboardSnapshot
        } `
        -GetCurrentTime {
            $value = ([datetime]'2026-01-01T00:00:00Z').AddSeconds($busyState.clock_reads)
            $busyState.clock_reads++
            $value
        } `
        -PollMilliseconds 0
    if ($busyState.snapshot_reads -ne 2 -or $busyResult.SequenceNumber -ne 43) {
        throw 'A changed sequence must retry a transient busy full snapshot.'
    }

    foreach ($foreignCase in @(
        [pscustomobject]@{ SequenceNumber = [uint32]43; UnicodeText = $null; Formats = [uint32[]]@() },
        [pscustomobject]@{ SequenceNumber = [uint32]43; UnicodeText = "foreign`r`n"; Formats = [uint32[]]@(13) },
        [pscustomobject]@{ SequenceNumber = [uint32]43; UnicodeText = $expectedClipboardText; Formats = [uint32[]]@(13, 49152) }
    )) {
        $foreignState = [pscustomobject]@{ sequence_reads = 0; snapshot_reads = 0; clock_reads = 0 }
        Assert-Fails {
            Wait-AcceptanceClipboardText `
                -PreviousSequence 42 `
                -ExpectedText $expectedClipboardText `
                -TimeoutSeconds 10 `
                -Label 'foreign changed Clipboard fixture' `
                -ReadSequence { $foreignState.sequence_reads++; [uint32]43 } `
                -ReadSnapshot { $foreignState.snapshot_reads++; $foreignCase } `
                -GetCurrentTime {
                    $value = ([datetime]'2026-01-01T00:00:00Z').AddSeconds($foreignState.clock_reads)
                    $foreignState.clock_reads++
                    $value
                } `
                -PollMilliseconds 0
        } 'changed the Clipboard to unexpected text or formats'
        if ($foreignState.sequence_reads -ne 1 -or $foreignState.snapshot_reads -ne 1) {
            throw 'Foreign Clipboard text or formats must fail immediately after one full read.'
        }
    }

    $continuousBusyState = [pscustomobject]@{ snapshot_reads = 0; clock_reads = 0 }
    Assert-Fails {
        Wait-AcceptanceClipboardText `
            -PreviousSequence 42 `
            -ExpectedText $expectedClipboardText `
            -TimeoutSeconds 10 `
            -Label 'continuous busy fixture' `
            -ReadSequence { [uint32]43 } `
            -ReadSnapshot { $continuousBusyState.snapshot_reads++; throw 'fixture Clipboard busy' } `
            -GetCurrentTime {
                $value = ([datetime]'2026-01-01T00:00:00Z').AddSeconds(11 * $continuousBusyState.clock_reads)
                $continuousBusyState.clock_reads++
                $value
            } `
            -PollMilliseconds 0
    } 'changed, but the exact expected Clipboard snapshot was not readable before the bounded deadline'
    if ($continuousBusyState.snapshot_reads -ne 1) {
        throw 'A continuously busy changed Clipboard fixture must stay bounded.'
    }

    $zeroSequenceState = [pscustomobject]@{ snapshot_reads = 0; clock_reads = 0 }
    Assert-Fails {
        Wait-AcceptanceClipboardText `
            -PreviousSequence 42 `
            -ExpectedText $expectedClipboardText `
            -TimeoutSeconds 10 `
            -Label 'zero sequence fixture' `
            -ReadSequence { [uint32]0 } `
            -ReadSnapshot { $zeroSequenceState.snapshot_reads++; $expectedClipboardSnapshot } `
            -GetCurrentTime {
                $value = ([datetime]'2026-01-01T00:00:00Z').AddSeconds(11 * $zeroSequenceState.clock_reads)
                $zeroSequenceState.clock_reads++
                $value
            } `
            -PollMilliseconds 0
    } 'did not change the Clipboard sequence before the bounded deadline'
    if ($zeroSequenceState.snapshot_reads -ne 0) {
        throw 'Clipboard sequence zero must never be treated as a readable change.'
    }
    Assert-Fails {
        Wait-AcceptanceClipboardText `
            -PreviousSequence 0 `
            -ExpectedText $expectedClipboardText `
            -TimeoutSeconds 10 `
            -Label 'zero baseline fixture' `
            -ReadSequence { [uint32]43 } `
            -ReadSnapshot { $expectedClipboardSnapshot } `
            -GetCurrentTime { [datetime]'2026-01-01T00:00:00Z' } `
            -PollMilliseconds 0
    } 'requires a nonzero baseline Clipboard sequence'
    $focusBefore = [pscustomobject]@{
        Current = [pscustomobject]@{ AutomationId = '1000'; NativeWindowHandle = 100 }
    }
    $focusAfter = [pscustomobject]@{
        Current = [pscustomobject]@{ AutomationId = '32773'; NativeWindowHandle = 200 }
    }
    $focusSequence = @($focusBefore, $focusBefore, $focusAfter)
    $focusState = [pscustomobject]@{ index = 0 }
    $settledFocus = Wait-AcceptanceFocusTransition `
        -Before $focusBefore `
        -ReadFocusedElement {
            $value = $focusSequence[$focusState.index]
            $focusState.index++
            $value
        } `
        -Label 'delayed focus fixture' `
        -MaximumAttempts 3 `
        -PollMilliseconds 0
    if ($focusState.index -ne 3 -or
        $settledFocus.Current.AutomationId -cne '32773') {
        throw 'Delayed focus navigation did not settle on the changed element.'
    }
    Assert-Fails {
        Wait-AcceptanceFocusTransition `
            -Before $focusBefore `
            -ReadFocusedElement { $focusBefore } `
            -Label 'stalled focus fixture' `
            -MaximumAttempts 2 `
            -PollMilliseconds 0
    } 'did not change focus within the bounded observation attempts'

    $smallCapture = Resolve-AcceptanceWindowResize `
        -CurrentWidth 594 `
        -CurrentHeight 508
    if (-not $smallCapture.resize_required -or
        $smallCapture.width -ne 640 -or
        $smallCapture.height -ne 508) {
        throw 'The 100-percent-DPI window must be enlarged to an evidence-eligible width.'
    }
    $largeCapture = Resolve-AcceptanceWindowResize `
        -CurrentWidth 900 `
        -CurrentHeight 700
    if ($largeCapture.resize_required -or
        $largeCapture.width -ne 900 -or
        $largeCapture.height -ne 700) {
        throw 'An already eligible capture window must retain its dimensions.'
    }

    foreach ($appearanceCase in @(
        @{ Name = 'system'; Command = 0x9010; Evidence = 'system' },
        @{ Name = 'light'; Command = 0x9011; Evidence = 'light' },
        @{ Name = 'dark'; Command = 0x9012; Evidence = 'dark' }
    )) {
        $appearanceSpec = Resolve-AcceptanceAppearance -Appearance $appearanceCase.Name
        if ($appearanceSpec.command_id -ne $appearanceCase.Command -or
            $appearanceSpec.evidence_name -cne $appearanceCase.Evidence) {
            throw "Acceptance appearance mapping failed for $($appearanceCase.Name)."
        }
    }
    foreach ($method in @(
        'IsMenuCommandChecked',
        'SendMenuCommand',
        'FindVisiblePopupMenu',
        'ReadVisibleNativeMenuPopups',
        'SetWindowPos'
    )) {
        if ($null -eq [DarkReNamerVmAcceptanceNative].GetMethod($method)) {
            throw "The acceptance native probe is missing $method."
        }
    }
    $captureContext = Add-AcceptanceScreenshotContext `
        -Screenshot ([ordered]@{
            file = 'fixture.png'
            sha256 = 'a' * 64
            width = 640
            height = 508
        }) `
        -Appearance 'dark' `
        -Surface 'main-workbench'
    if ($captureContext.appearance -cne 'dark' -or
        $captureContext.surface -cne 'main-workbench' -or
        $captureContext.width -ne 640) {
        throw 'Screenshot context must retain explicit appearance, surface, and dimensions.'
    }
    if ((Get-AcceptanceVerdict -KeyboardStatus passed -AccessibilityStatus passed -CaptureStatus passed) -cne 'review_required') {
        throw 'Complete technical evidence must retain the visual-review requirement.'
    }
    if ((Get-AcceptanceVerdict -KeyboardStatus failed -AccessibilityStatus passed -CaptureStatus passed) -cne 'failed') {
        throw 'A failed technical lane must fail the acceptance verdict.'
    }
    if ((Get-AcceptanceVerdict -KeyboardStatus passed -AccessibilityStatus not_run -CaptureStatus passed) -cne 'not_run') {
        throw 'Incomplete technical evidence must remain not-run.'
    }
    Assert-Fails {
        Get-AcceptanceVerdict -KeyboardStatus unknown -AccessibilityStatus passed -CaptureStatus passed
    } 'status is invalid'
    $highContrastSnapshot = [pscustomobject]@{
        Flags = 126
        Scheme = 'fixture scheme'
        Window = 1
        WindowText = 2
        ButtonFace = 3
        ButtonText = 4
        Highlight = 5
        HighlightText = 6
        GrayText = 7
        HotLight = 8
        ThemePath = 'C:\Windows\resources\Themes\Aero\Aero.msstyles'
        ThemeColor = 'NormalColor'
        ThemeSize = 'NormalSize'
    }
    $sameSnapshot = $highContrastSnapshot | Select-Object *
    if (-not (Test-HighContrastSnapshotEqual -Expected $highContrastSnapshot -Actual $sameSnapshot)) {
        throw 'Equal High Contrast snapshots must prove restoration.'
    }
    $changedSnapshot = $highContrastSnapshot | Select-Object *
    $changedSnapshot.Highlight = 9
    if (Test-HighContrastSnapshotEqual -Expected $highContrastSnapshot -Actual $changedSnapshot) {
        throw 'Changed High Contrast system colors must fail restoration proof.'
    }
    foreach ($themeChange in @(
        @{ Name = 'ThemePath'; Value = 'C:\Windows\resources\Themes\Aero\AeroLite.msstyles' },
        @{ Name = 'ThemeColor'; Value = 'HighContrast' },
        @{ Name = 'ThemeSize'; Value = 'Large' }
    )) {
        $changedThemeSnapshot = $highContrastSnapshot | Select-Object *
        $changedThemeSnapshot.($themeChange.Name) = $themeChange.Value
        if (Test-HighContrastSnapshotEqual -Expected $highContrastSnapshot -Actual $changedThemeSnapshot) {
            throw "Changed $($themeChange.Name) must fail restoration proof."
        }
        $themeMismatchState = [pscustomobject]@{ writes = 0 }
        $themeDiagnosticPath = Join-Path $temporaryRoot ($themeChange.Name + '-restore-error.json')
        Assert-Fails {
            Wait-HighContrastRestoration `
                -Expected $highContrastSnapshot `
                -ReadSnapshot { $changedThemeSnapshot | Select-Object * } `
                -SetCapturedColors { param($expected) $themeMismatchState.writes++ } `
                -Label "changed $($themeChange.Name) fixture" `
                -DiagnosticPath $themeDiagnosticPath `
                -AllowPaletteRestore `
                -MaximumAttempts 2 -FallbackAttempts 2 -PollMilliseconds 0
        } 'did not settle within the bounded observation attempts'
        if ($themeMismatchState.writes -ne 0) {
            throw "Changed $($themeChange.Name) must not invoke the palette setter."
        }
        $themeDiagnostic = Get-Content -LiteralPath $themeDiagnosticPath -Raw | ConvertFrom-Json
        if ($themeDiagnostic.kind -cne 'high_contrast_restoration_observations' -or
            $themeDiagnostic.phase -cne 'initial' -or $themeDiagnostic.observations.Count -ne 2) {
            throw 'Failed theme restoration must preserve both bounded observations.'
        }
        $diagnosticExpected = ConvertFrom-HighContrastDocumentSnapshot -Document $themeDiagnostic.expected -Label 'diagnostic expected'
        if (-not (Test-HighContrastSnapshotEqual -Expected $highContrastSnapshot -Actual $diagnosticExpected)) {
            throw 'Failed restoration diagnostics must retain the complete expected state.'
        }
        foreach ($observation in $themeDiagnostic.observations) {
            [void][DateTimeOffset]::Parse([string]$observation.utc)
            $diagnosticObserved = ConvertFrom-HighContrastDocumentSnapshot -Document $observation.snapshot -Label 'diagnostic observed'
            if ($observation.phase -cne 'initial' -or
                -not (Test-HighContrastSnapshotEqual -Expected $changedThemeSnapshot -Actual $diagnosticObserved)) {
                throw 'Failed restoration diagnostics must retain the actual mismatched state.'
            }
        }
    }
    $settlementState = [pscustomobject]@{ reads = 0 }
    $settled = Wait-HighContrastSettlement `
        -ReadSnapshot {
            $settlementState.reads++
            $highContrastSnapshot | Select-Object *
        } `
        -AcceptSnapshot { param($candidate) $candidate.Flags -eq 126 } `
        -Label 'immediate fixture' `
        -MaximumAttempts 2 `
        -PollMilliseconds 0
    if ($settlementState.reads -ne 2 -or
        -not (Test-HighContrastSnapshotEqual -Expected $highContrastSnapshot -Actual $settled)) {
        throw 'An immediately stable High Contrast state did not settle in two reads.'
    }
    $enabledSnapshot = $highContrastSnapshot | Select-Object *
    $enabledSnapshot.Flags = 127
    $enabledSnapshot.Highlight = 9
    $delayedSequence = @(
        $highContrastSnapshot,
        ($enabledSnapshot | Select-Object *),
        ($enabledSnapshot | Select-Object *)
    )
    $delayedState = [pscustomobject]@{ index = 0 }
    $delayed = Wait-HighContrastSettlement `
        -ReadSnapshot {
            $value = $delayedSequence[$delayedState.index]
            $delayedState.index++
            $value
        } `
        -AcceptSnapshot { param($candidate) $candidate.Flags -eq 127 } `
        -Label 'delayed fixture' `
        -MaximumAttempts 3 `
        -PollMilliseconds 0
    if ($delayedState.index -ne 3 -or $delayed.Highlight -ne 9) {
        throw 'A delayed High Contrast state did not wait for stable accepted reads.'
    }
    Assert-Fails {
        Wait-HighContrastSettlement `
            -ReadSnapshot { $highContrastSnapshot | Select-Object * } `
            -AcceptSnapshot { param($candidate) $candidate.Flags -eq 127 } `
            -Label 'timeout fixture' `
            -MaximumAttempts 3 `
            -PollMilliseconds 0
    } 'did not settle within the bounded observation attempts'

    $exactRestoreState = [pscustomobject]@{ reads = 0; writes = 0 }
    $exactDiagnosticPath = Join-Path $temporaryRoot 'exact-restore-error.json'
    $exactRestore = Wait-HighContrastRestoration `
        -Expected $highContrastSnapshot `
        -ReadSnapshot {
            $exactRestoreState.reads++
            $highContrastSnapshot | Select-Object *
        } `
        -SetCapturedColors { param($expected) $exactRestoreState.writes++ } `
        -Label 'exact restoration fixture' `
        -DiagnosticPath $exactDiagnosticPath `
        -MaximumAttempts 2 `
        -FallbackAttempts 2 `
        -PollMilliseconds 0
    if ($exactRestoreState.reads -ne 2 -or $exactRestoreState.writes -ne 0 -or
        (Test-Path -LiteralPath $exactDiagnosticPath) -or
        -not (Test-HighContrastSnapshotEqual -Expected $highContrastSnapshot -Actual $exactRestore)) {
        throw 'Exact restoration must complete without writing the captured palette.'
    }

    $nestedScopeState = [pscustomobject]@{ reads = 0; writes = 0 }
    $nestedScopeRestore = & {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot {
                $nestedScopeState.reads++
                $highContrastSnapshot | Select-Object *
            } `
            -SetCapturedColors { param($expected) $nestedScopeState.writes++ } `
            -Label 'nested script scope fixture' `
            -MaximumAttempts 2 `
            -FallbackAttempts 2 `
            -PollMilliseconds 0
    }
    if ($nestedScopeState.reads -ne 2 -or $nestedScopeState.writes -ne 0 -or
        -not (Test-HighContrastSnapshotEqual -Expected $highContrastSnapshot -Actual $nestedScopeRestore)) {
        throw 'Restoration callbacks must resolve comparators from a nested script scope.'
    }

    $paletteDrift = $highContrastSnapshot | Select-Object *
    $paletteDrift.Highlight = 9
    $repairState = [pscustomobject]@{ reads = 0; writes = 0; repaired = $false }
    $repairedRestore = Wait-HighContrastRestoration `
        -Expected $highContrastSnapshot `
        -ReadSnapshot {
            $repairState.reads++
            if ($repairState.repaired) { $highContrastSnapshot | Select-Object * }
            else { $paletteDrift | Select-Object * }
        } `
        -SetCapturedColors {
            param($expected)
            $repairState.writes++
            if ($expected.Highlight -ne 5) { throw 'unexpected palette fixture' }
            $repairState.repaired = $true
        } `
        -Label 'single palette drift fixture' `
        -AllowPaletteRestore `
        -MaximumAttempts 2 `
        -FallbackAttempts 2 `
        -PollMilliseconds 0
    if ($repairState.reads -ne 4 -or $repairState.writes -ne 1 -or
        -not (Test-HighContrastSnapshotEqual -Expected $highContrastSnapshot -Actual $repairedRestore)) {
        throw 'Stable palette-only drift must repair once and require two exact verification reads.'
    }

    $settingsMismatch = $paletteDrift | Select-Object *
    $settingsMismatch.Flags = 127
    $settingsState = [pscustomobject]@{ writes = 0 }
    Assert-Fails {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot { $settingsMismatch | Select-Object * } `
            -SetCapturedColors { param($expected) $settingsState.writes++ } `
            -Label 'settings mismatch fixture' `
            -AllowPaletteRestore `
            -MaximumAttempts 2 -FallbackAttempts 2 -PollMilliseconds 0
    } 'did not settle within the bounded observation attempts'
    if ($settingsState.writes -ne 0) { throw 'Settings mismatch must not write system colors.' }

    $deniedState = [pscustomobject]@{ writes = 0 }
    Assert-Fails {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot { $paletteDrift | Select-Object * } `
            -SetCapturedColors { param($expected) $deniedState.writes++ } `
            -Label 'not applied by observer fixture' `
            -MaximumAttempts 2 -FallbackAttempts 2 -PollMilliseconds 0
    } 'did not settle within the bounded observation attempts'
    if ($deniedState.writes -ne 0) { throw 'A palette not changed by this observer must never be rewritten.' }

    $unstableState = [pscustomobject]@{ index = 0; writes = 0 }
    $otherPaletteDrift = $paletteDrift | Select-Object *
    $otherPaletteDrift.Highlight = 10
    $unstableSequence = @($paletteDrift, $otherPaletteDrift)
    Assert-Fails {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot {
                $value = $unstableSequence[$unstableState.index]
                $unstableState.index++
                $value | Select-Object *
            } `
            -SetCapturedColors { param($expected) $unstableState.writes++ } `
            -Label 'unstable palette fixture' `
            -AllowPaletteRestore `
            -MaximumAttempts 2 -FallbackAttempts 2 -PollMilliseconds 0
    } 'did not settle within the bounded observation attempts'
    if ($unstableState.writes -ne 0) { throw 'Unstable palette observations must not write system colors.' }

    $readErrorState = [pscustomobject]@{ reads = 0; writes = 0 }
    $readErrorDiagnosticPath = Join-Path $temporaryRoot 'read-restore-error.json'
    Assert-Fails {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot {
                $readErrorState.reads++
                if ($readErrorState.reads -eq 1) { return $paletteDrift | Select-Object * }
                ([Runtime.ExceptionServices.ExceptionDispatchInfo]::Capture(
                    [ComponentModel.Win32Exception]::new(5, 'fixture snapshot read failed')
                )).Throw()
            } `
            -SetCapturedColors { param($expected) $readErrorState.writes++ } `
            -Label 'read error fixture' `
            -DiagnosticPath $readErrorDiagnosticPath `
            -AllowPaletteRestore `
            -MaximumAttempts 2 -FallbackAttempts 2 -PollMilliseconds 0
    } 'fixture snapshot read failed'
    if ($readErrorState.writes -ne 0) { throw 'Snapshot read failure must not write system colors.' }
    $readErrorDiagnostic = Get-Content -LiteralPath $readErrorDiagnosticPath -Raw | ConvertFrom-Json
    if ($readErrorState.reads -ne 2 -or $readErrorDiagnostic.observations.Count -ne 1 -or
        $readErrorDiagnostic.error.base_type -cne 'System.ComponentModel.Win32Exception' -or
        $readErrorDiagnostic.error.native_error_code -ne 5) {
        throw 'A failed native read must preserve prior observations and the underlying Win32 error.'
    }
    Assert-Fails {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot { throw 'original restore read failure' } `
            -Label 'unwritable diagnostic fixture' `
            -DiagnosticPath $temporaryRoot `
            -MaximumAttempts 2 -PollMilliseconds 0
    } 'original restore read failure'

    Assert-Fails {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot { $paletteDrift | Select-Object * } `
            -SetCapturedColors { param($expected) throw 'fixture palette setter failed' } `
            -Label 'setter error fixture' `
            -AllowPaletteRestore `
            -MaximumAttempts 2 -FallbackAttempts 2 -PollMilliseconds 0
    } 'fixture palette setter failed'

    $fallbackState = [pscustomobject]@{ reads = 0; writes = 0 }
    $fallbackDiagnosticPath = Join-Path $temporaryRoot 'fallback-restore-error.json'
    Assert-Fails {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot { $fallbackState.reads++; $paletteDrift | Select-Object * } `
            -SetCapturedColors { param($expected) $fallbackState.writes++ } `
            -Label 'bounded fallback fixture' `
            -DiagnosticPath $fallbackDiagnosticPath `
            -AllowPaletteRestore `
            -MaximumAttempts 2 -FallbackAttempts 2 -PollMilliseconds 0
    } 'palette fallback did not settle within the bounded observation attempts'
    if ($fallbackState.reads -ne 4 -or $fallbackState.writes -ne 1) {
        throw 'Palette fallback must remain bounded and must not false-pass persistent drift.'
    }
    $fallbackDiagnostic = Get-Content -LiteralPath $fallbackDiagnosticPath -Raw | ConvertFrom-Json
    if ($fallbackDiagnostic.phase -cne 'palette_fallback' -or
        $fallbackDiagnostic.observations.Count -ne 4 -or
        @($fallbackDiagnostic.observations | Where-Object phase -CEQ 'initial').Count -ne 2 -or
        @($fallbackDiagnostic.observations | Where-Object phase -CEQ 'palette_fallback').Count -ne 2) {
        throw 'Failed palette fallback diagnostics must distinguish both bounded observation phases.'
    }

    $valid = New-AcceptanceFixture -Name 'valid'
    Invoke-ValidateOnly $valid
    $legacyManifest = $valid.manifest | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $legacyUiResult = [pscustomobject]@{
        schema_version = [long]1
        source_sha = $legacyManifest.source_sha
        application = $legacyManifest.application
        runner_sha256 = $legacyManifest.runner.sha256
        acceptance_script_sha256 = Get-Sha256 $valid.acceptance
    }
    Assert-ObserverResultBinding `
        -Result $legacyUiResult `
        -Manifest $legacyManifest `
        -Role ui `
        -ExpectedObserverSha256 $legacyUiResult.acceptance_script_sha256

    $candidateValid = New-CandidateAcceptanceFixture -Name 'candidate-valid'
    Invoke-ValidateOnly $candidateValid
    $candidateManifest = $candidateValid.manifest | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $candidateCurrentDpiInput = [pscustomobject]@{
        artifacts = [pscustomobject]@{
            application = [pscustomobject]@{
                sha256 = $candidateManifest.product.application.sha256
            }
            runner = [pscustomobject]@{
                sha256 = $candidateManifest.harness.runner.sha256
            }
        }
    }
    Assert-AcceptanceInputArtifactBinding `
        -InputDocument $candidateCurrentDpiInput `
        -Manifest $candidateManifest `
        -CandidateLane $true
    foreach ($field in @('application', 'runner')) {
        $wrongCandidateCurrentDpiInput = $candidateCurrentDpiInput |
            ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $wrongCandidateCurrentDpiInput.artifacts.$field.sha256 = 'f' * 64
        Assert-Fails {
            Assert-AcceptanceInputArtifactBinding `
                -InputDocument $wrongCandidateCurrentDpiInput `
                -Manifest $candidateManifest `
                -CandidateLane $true
        } 'candidate application or runner'
    }
    Assert-AcceptanceInputArtifactBinding `
        -InputDocument ([pscustomobject]@{}) `
        -Manifest $legacyManifest `
        -CandidateLane $false
    foreach ($validRunId in @('run-1', '20260920.ui_01', ('a' * 128))) {
        Assert-SafeAcceptanceRunId -RunId $validRunId
    }
    foreach ($invalidRunId in @($null, '', '../run', 'run id', ('a' * 129), 'run.')) {
        Assert-Fails { Assert-SafeAcceptanceRunId -RunId $invalidRunId } 'bounded safe token'
    }
    & {
        $controllerFunction = $controllerAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-DrWindowsVmController'
        }, $true)
        . ([scriptblock]::Create($controllerFunction.Extent.Text))
        $probe = @{ sessions = 0 }
        function New-SshControllerSession {
            param($HostAlias)
            $probe.sessions++
            throw 'fixture session boundary'
        }
        foreach ($runId in @('../unsafe-run', 'valid-run')) {
            $fixture = New-AcceptanceFixture -Name ('controller-run-id-' + $probe.sessions + '-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $fixture.output_root)
            Copy-Item -LiteralPath $fixture.acceptance -Destination (Join-Path $fixture.bundle_root 'windows-vm-acceptance.ps1')
            $inputPath = Join-Path $fixture.task_root 'input.json'
            Write-Utf8Json -Path $inputPath -Value ([ordered]@{
                schema_version = 1
                source_sha = $fixture.manifest.source_sha
                run_id = $runId
                request = [ordered]@{ mode = 'current-dpi'; appearance = 'system'; text_scale_percent = 100 }
                artifacts = [ordered]@{ observer = [ordered]@{
                    file = 'inputs/windows-vm-acceptance.ps1'; sha256 = $fixture.acceptance_sha256
                } }
            })
            Assert-Fails {
                Invoke-DrWindowsVmController -BundleRoot $fixture.bundle_root -SshHost 'inert-fixture' `
                    -ExpectedGuestVmId '11111111-1111-1111-1111-111111111111' -TaskKind ui `
                    -AcceptanceOutputRoot $fixture.output_root -AcceptanceManifest $inputPath `
                    -AcceptanceMode current-dpi -AcceptanceAppearance system `
                    -EntryPointPath $controller -VerifiedTooling ([pscustomobject]@{})
            } 'VM transport, acceptance, or cleanup failed'
            $diagnostic = [IO.File]::ReadAllText((Join-Path $fixture.output_root 'transport-error.txt'))
            if ($runId -ceq '../unsafe-run') {
                if ($probe.sessions -ne 0 -or $diagnostic -notlike '*bounded safe token*') {
                    throw 'Unsafe acceptance run ID reached the VM session boundary.'
                }
            }
            elseif ($probe.sessions -ne 1 -or $diagnostic -notlike '*fixture session boundary*') {
                throw 'The valid acceptance input did not reach the inert session boundary.'
            }
        }
    }
    $candidateRegressionResolved = [pscustomobject]@{
        lane = 'candidate-gui-only'
        target = $candidateManifest.target
        application = $candidateManifest.product.application
        source_sha = $candidateManifest.product.source_sha
        runner = $candidateManifest.harness.runner
        runner_sha256 = $candidateManifest.harness.runner.sha256
        script_sha256 = $candidateManifest.harness.observers.ui.sha256
        product = $candidateManifest.product
        harness = $candidateManifest.harness
    }
    $candidateRegressionInput = [pscustomobject]@{
        schema_version = [long]1
        source_sha = $candidateManifest.product.source_sha
        artifacts = [pscustomobject]@{
            application = $candidateManifest.product.application
            runner = $candidateManifest.harness.runner
            observer = $candidateManifest.harness.observers.ui
        }
        request = [pscustomobject]@{
            mode = 'text-scale'; appearance = 'light'; text_scale_percent = [long]150
            layout_variant = 'native-menu-only'
            desktop = [pscustomobject]@{ width = [long]800; height = [long]600; dpi = [long]96 }
        }
    }
    $candidateRegressionInputPath = Join-Path $candidateValid.task_root 'input-manifest.json'
    Write-Utf8Json -Path $candidateRegressionInputPath -Value $candidateRegressionInput
    Invoke-TestAcceptance `
        -EntryPointPath $candidateValid.acceptance `
        -BundleRoot $candidateValid.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $candidateValid.output_root `
        -ExpectedScriptSha256 $candidateValid.acceptance_sha256 `
        -RegressionMode text-scale `
        -InputManifestPath $candidateRegressionInputPath `
        -Appearance light `
        -TextScalePercent 150 `
        -ValidateOnly
    Assert-GuiRegressionInvocationBinding `
        -ManifestInput $candidateRegressionInput `
        -Verified $candidateRegressionResolved `
        -RegressionMode text-scale `
        -Appearance light `
        -TextScalePercent 150 `
        -HighContrast $false `
        -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
    $candidatePairInput = $candidateRegressionInput | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $candidatePairInput.request.mode = 'appearance-pair'
    $candidatePairInput.request.appearance = 'system'
    $candidatePairInput.request.text_scale_percent = [long]100
    $candidatePairInput.request.PSObject.Properties.Remove('layout_variant')
    $candidatePairInput.request | Add-Member -NotePropertyName high_contrast -NotePropertyValue $true
    Assert-GuiRegressionInvocationBinding -ManifestInput $candidatePairInput `
        -Verified $candidateRegressionResolved -RegressionMode appearance-pair `
        -Appearance system -TextScalePercent 100 -HighContrast $true `
        -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
    Assert-Fails {
        Assert-GuiRegressionInvocationBinding -ManifestInput $candidatePairInput `
            -Verified $candidateRegressionResolved -RegressionMode appearance-pair `
            -Appearance system -TextScalePercent 100 -HighContrast $false `
            -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
    } 'contrast or text scale differs'
    $candidatePairInput.request.appearance = 'light'
    $candidatePairInput.request.high_contrast = $false
    $candidatePairInput.request.text_scale_percent = [long]150
    Assert-GuiRegressionInvocationBinding -ManifestInput $candidatePairInput `
        -Verified $candidateRegressionResolved -RegressionMode appearance-pair `
        -Appearance light -TextScalePercent 150 -HighContrast $false `
        -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
    $candidatePerformanceInput = $candidateRegressionInput | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $candidatePerformanceInput.request.mode = 'performance-sample'
    $candidatePerformanceInput.request.text_scale_percent = [long]100
    $candidatePerformanceInput.request.PSObject.Properties.Remove('layout_variant')
    $candidatePerformanceInput.request.desktop.width = [long]1366
    $candidatePerformanceInput.request.desktop.height = [long]768
    $candidatePerformanceInput.request | Add-Member -NotePropertyName performance_plan -NotePropertyValue ([ordered]@{
        iterations=2; idle_seconds=30; maximum_seconds=600; ordinary_rows=@(100,1000,10000)
        long_path_rows=1000; extension_classes=300; add_remove_reset_cycles=3; sample_interval_ms=200
        long_path_order='hidden-visible'
    })
    Assert-GuiRegressionInvocationBinding -ManifestInput $candidatePerformanceInput `
        -Verified $candidateRegressionResolved -RegressionMode performance-sample `
        -Appearance light -TextScalePercent 100 -HighContrast $false `
        -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
    $candidatePerformanceInput.request.performance_plan.long_path_order = 'visible-hidden'
    Assert-GuiRegressionInvocationBinding -ManifestInput $candidatePerformanceInput `
        -Verified $candidateRegressionResolved -RegressionMode performance-sample `
        -Appearance light -TextScalePercent 100 -HighContrast $false `
        -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
    $candidatePerformanceInput.request.performance_plan.long_path_order = 'invalid'
    Assert-Fails {
        Assert-GuiRegressionInvocationBinding -ManifestInput $candidatePerformanceInput `
            -Verified $candidateRegressionResolved -RegressionMode performance-sample `
            -Appearance light -TextScalePercent 100 -HighContrast $false `
            -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
    } 'fixed immutable plan'
    $candidatePerformanceInput.request.performance_plan.long_path_order = 'hidden-visible'
    $candidatePerformanceInput.request.performance_plan.idle_seconds = 0
    Assert-Fails {
        Assert-GuiRegressionInvocationBinding -ManifestInput $candidatePerformanceInput `
            -Verified $candidateRegressionResolved -RegressionMode performance-sample `
            -Appearance light -TextScalePercent 100 -HighContrast $false `
            -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
    } 'fixed immutable plan'
    Assert-Fails -Expected 'performance scenario entered with empty captures' -Action {
        & {
            function New-PrivateDirectory { throw 'performance scenario entered with empty captures' }
            Invoke-ObserverPerformanceSampleScenario -Verified ([pscustomobject]@{}) `
                -RuntimeRoot 'unopened-fixture' -EvidenceRoot 'unopened-evidence' `
                -SessionId 1 -WaitSeconds 1 -Captures ([Collections.Generic.List[object]]::new()) `
                -ProcessLifecycleObservations ([Collections.Generic.List[object]]::new()) `
                -ObservationSink ([ordered]@{})
        }
    }
    $performanceGridPattern = [pscustomobject]@{
        Current = [pscustomobject]@{ RowCount = 10000 }
        Prefix = 'sample-'
        TamperLast = $false
    }
    $performanceGridPattern | Add-Member -MemberType ScriptMethod -Name GetItem -Value {
        param([int] $row, [int] $column)
        $name = 'ordinary-{0:D5}.txt' -f $row
        if ($column -eq 1) {
            $name = $this.Prefix + $name
            if ($this.TamperLast -and $row -eq 9999) { $name = 'wrong-last.txt' }
        }
        [pscustomobject]@{ Current = [pscustomobject]@{ Name = $name } }
    }
    $performanceGrid = [pscustomobject]@{ pattern = $performanceGridPattern }
    $performanceIndices = [int[]]@(0,2499,4999,7499,9999)
    $prefixProbe = Read-ObserverPerformancePreviewRows -Grid $performanceGrid `
        -Indices $performanceIndices -Prefix 'sample-' -WaitSeconds 1
    if ($prefixProbe.Count -ne 5 -or $prefixProbe[4].proposed -cne 'sample-ordinary-09999.txt') {
        throw 'The performance probe did not verify the last prefixed row.'
    }
    $performanceGridPattern.Prefix = ''
    $resetProbe = Read-ObserverPerformancePreviewRows -Grid $performanceGrid `
        -Indices $performanceIndices -Prefix '' -WaitSeconds 1
    if ($resetProbe[4].proposed -cne 'ordinary-09999.txt') {
        throw 'The performance probe did not verify the last reset row.'
    }
    $performanceGridPattern.TamperLast = $true
    Assert-Fails {
        Read-ObserverPerformancePreviewRows -Grid $performanceGrid `
            -Indices $performanceIndices -Prefix '' -WaitSeconds 0
    } 'did not settle for all five representative rows'
    if ((Resolve-GuiRegressionLayoutVariant `
        -ManifestInput $candidateRegressionInput `
        -Verified $candidateRegressionResolved `
        -RegressionMode text-scale `
        -Appearance light `
        -TextScalePercent 150) -cne 'native-menu-only') {
        throw 'The authenticated text-150 request did not retain native-menu-only layout.'
    }
    $ordinaryRegressionInput = $candidateRegressionInput |
        ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $ordinaryRegressionInput.request.PSObject.Properties.Remove('layout_variant')
    if ((Resolve-GuiRegressionLayoutVariant `
        -ManifestInput $ordinaryRegressionInput `
        -Verified $candidateRegressionResolved `
        -RegressionMode text-scale `
        -Appearance light `
        -TextScalePercent 150) -cne 'command-rails') {
        throw 'A legacy request without a layout variant must retain command rails.'
    }
    foreach ($invalidVariant in @('adaptive', [long]1)) {
        $invalidVariantInput = $candidateRegressionInput |
            ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $invalidVariantInput.request.layout_variant = $invalidVariant
        Assert-Fails {
            Resolve-GuiRegressionLayoutVariant `
                -ManifestInput $invalidVariantInput `
                -Verified $candidateRegressionResolved `
                -RegressionMode text-scale `
                -Appearance light `
                -TextScalePercent 150
        } 'layout variant'
    }
    $wrongNativeGeometry = $candidateRegressionInput |
        ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $wrongNativeGeometry.request.desktop.width = [long]801
    Assert-Fails {
        Resolve-GuiRegressionLayoutVariant `
            -ManifestInput $wrongNativeGeometry `
            -Verified $candidateRegressionResolved `
            -RegressionMode text-scale `
            -Appearance light `
            -TextScalePercent 150
    } 'fixed text-150 cell'
    $manifestGuestPreflight = [pscustomobject][ordered]@{
        architecture = 'x86_64'
        build = '26200'
        os_version = 'Microsoft Windows NT 10.0.26200.0'
        product_caption = 'Microsoft Windows 11 Pro'
        system = 'windows'
        vm_identity_kind = 'hyper-v-guest-parameters-virtual-machine-id-v1'
        vm_identity_sha256 = 'a' * 64
    }
    $observedGuestPreflight = [ordered]@{
        system = 'windows'
        product_caption = 'Microsoft Windows 11 Pro'
        os_version = 'Microsoft Windows NT 10.0.26200.0'
        build = '26200'
        architecture = 'x86_64'
        vm_identity_kind = 'hyper-v-guest-parameters-virtual-machine-id-v1'
        vm_identity_sha256 = 'a' * 64
    }
    Assert-GuiRegressionGuestPreflightBinding `
        -Expected $manifestGuestPreflight `
        -Actual $observedGuestPreflight
    foreach ($mutation in @('missing', 'extra', 'type', 'identity')) {
        $changedGuestPreflight = $manifestGuestPreflight | Select-Object *
        switch ($mutation) {
            'missing' {
                $changedGuestPreflight.PSObject.Properties.Remove('build')
            }
            'extra' {
                $changedGuestPreflight | Add-Member -NotePropertyName unexpected -NotePropertyValue 'value'
            }
            'type' {
                $changedGuestPreflight.build = [long]26200
            }
            'identity' {
                $changedGuestPreflight.vm_identity_sha256 = 'b' * 64
            }
        }
        Assert-Fails {
            Assert-GuiRegressionGuestPreflightBinding `
                -Expected $changedGuestPreflight `
                -Actual $observedGuestPreflight
        } 'Guest platform or VM identity differs from immutable preflight'
    }
    $candidateRegressionResult = New-GuiRegressionResult `
        -Verified $candidateRegressionResolved `
        -Appearance light
    if ($candidateRegressionResult.schema_version -ne 2 -or
        $candidateRegressionResult.lane -cne 'candidate-gui-only' -or
        $candidateRegressionResult.observer_role -cne 'ui' -or
        $candidateRegressionResult.product -ne $candidateManifest.product -or
        $candidateRegressionResult.harness -ne $candidateManifest.harness -or
        $candidateRegressionResult.Contains('process_lifecycles') -or
        $candidateRegressionResult.PSObject.Properties.Name -ccontains 'source_sha') {
        throw 'Candidate GUI regression results must preserve v2 product and harness provenance.'
    }
    $candidateRegressionResult.status = 'review_required'
    $candidateRegressionResultDocument = $candidateRegressionResult |
        ConvertTo-Json -Depth 12 | ConvertFrom-Json
    Assert-ObserverResultBinding `
        -Result $candidateRegressionResultDocument `
        -Manifest $candidateManifest `
        -Role ui `
        -ExpectedObserverSha256 $candidateManifest.harness.observers.ui.sha256
    $wrongCandidateRegressionInput = $candidateRegressionInput |
        ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $wrongCandidateRegressionInput.source_sha = 'c' * 40
    Assert-Fails {
        Assert-GuiRegressionInvocationBinding `
            -ManifestInput $wrongCandidateRegressionInput `
            -Verified $candidateRegressionResolved `
            -RegressionMode text-scale `
            -Appearance light `
            -TextScalePercent 150 `
            -HighContrast $false `
            -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
    } 'immutable manifest'
    $legacyRegressionResolved = [pscustomobject]@{
        lane = 'source-built'
        target = $legacyManifest.target
        application = $legacyManifest.application
        source_sha = $legacyManifest.source_sha
        runner = $legacyManifest.runner
        runner_sha256 = $legacyManifest.runner.sha256
        script_sha256 = $legacyUiResult.acceptance_script_sha256
        product = $null
        harness = $null
    }
    $legacyRegressionResult = New-GuiRegressionResult `
        -Verified $legacyRegressionResolved `
        -Appearance light
    if ($legacyRegressionResult.schema_version -ne 1 -or
        $legacyRegressionResult.source_sha -cne $legacyManifest.source_sha -or
        $legacyRegressionResult.PSObject.Properties.Name -ccontains 'product' -or
        $legacyRegressionResult.PSObject.Properties.Name -ccontains 'harness' -or
        $legacyRegressionResult.PSObject.Properties.Name -ccontains 'observer_role') {
        throw 'Legacy GUI regression result shape must remain schema 1.'
    }
    $candidateUiResult = [pscustomobject]@{
        schema_version = [long]2
        lane = 'candidate-gui-only'
        product = $candidateManifest.product
        harness = $candidateManifest.harness
        observer_role = 'ui'
        application = $candidateManifest.product.application
        runner_sha256 = $candidateManifest.harness.runner.sha256
        acceptance_script_sha256 = $candidateManifest.harness.observers.ui.sha256
    }
    Assert-ObserverResultBinding `
        -Result $candidateUiResult `
        -Manifest $candidateManifest `
        -Role ui `
        -ExpectedObserverSha256 $candidateManifest.harness.observers.ui.sha256
    $candidateRecoveryResult = [pscustomobject]@{
        schema_version = [long]2
        lane = 'candidate-gui-only'
        product = $candidateManifest.product
        harness = $candidateManifest.harness
        observer_role = 'recovery'
        application = $candidateManifest.product.application
        runner_sha256 = $candidateManifest.harness.runner.sha256
        observer = $candidateManifest.harness.observers.recovery
    }
    Assert-ObserverResultBinding `
        -Result $candidateRecoveryResult `
        -Manifest $candidateManifest `
        -Role recovery `
        -ExpectedObserverSha256 $candidateManifest.harness.observers.recovery.sha256
    $wrongRoleResult = $candidateRecoveryResult | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $wrongRoleResult.observer_role = 'ui'
    Assert-Fails {
        Assert-ObserverResultBinding `
            -Result $wrongRoleResult `
            -Manifest $candidateManifest `
            -Role recovery `
            -ExpectedObserverSha256 $candidateManifest.harness.observers.recovery.sha256
    } 'role or provenance shape is invalid'
    $wrongProductResult = $candidateUiResult | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $wrongProductResult.product.candidate.artifact_id = '21'
    Assert-Fails {
        Assert-ObserverResultBinding `
            -Result $wrongProductResult `
            -Manifest $candidateManifest `
            -Role ui `
            -ExpectedObserverSha256 $candidateManifest.harness.observers.ui.sha256
    } 'product or harness provenance differs'

    $candidateSwappedObserver = New-CandidateAcceptanceFixture -Name 'candidate-swapped-observer'
    $candidateSwappedObserver.manifest.harness.observers.ui =
        $candidateSwappedObserver.manifest.harness.observers.recovery
    Write-Utf8Json `
        -Path (Join-Path $candidateSwappedObserver.bundle_root 'bundle.json') `
        -Value $candidateSwappedObserver.manifest
    Assert-Fails { Invoke-ValidateOnly $candidateSwappedObserver } 'UI observer binding is invalid'

    $candidateFalseAlias = New-CandidateAcceptanceFixture -Name 'candidate-false-alias'
    $candidateFalseAlias.manifest['runner'] = $candidateFalseAlias.manifest.harness.runner
    Write-Utf8Json `
        -Path (Join-Path $candidateFalseAlias.bundle_root 'bundle.json') `
        -Value $candidateFalseAlias.manifest
    Assert-Fails { Invoke-ValidateOnly $candidateFalseAlias } 'unexpected fields'

    $candidateDuplicate = New-CandidateAcceptanceFixture -Name 'candidate-duplicate'
    $candidateManifestPath = Join-Path $candidateDuplicate.bundle_root 'bundle.json'
    $candidateManifestText = [IO.File]::ReadAllText($candidateManifestPath)
    [IO.File]::WriteAllText(
        $candidateManifestPath,
        $candidateManifestText.Replace('"schema_version": 2,', '"schema_version": 2, "schema_version": 2,'),
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Fails { Invoke-ValidateOnly $candidateDuplicate } 'duplicate field: schema_version'
    if (Test-Path -LiteralPath $valid.output_root) {
        throw 'ValidateOnly must not create acceptance output.'
    }
    Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
        -BundleRoot $valid.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $valid.output_root `
        -ExpectedScriptSha256 $valid.acceptance_sha256 `
        -HighContrast `
        -ValidateOnly
    Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
        -BundleRoot $valid.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $valid.output_root `
        -ExpectedScriptSha256 $valid.acceptance_sha256 `
        -Appearance dark `
        -CaptureNativeMenu `
        -CaptureAdvancedAppearance `
        -ValidateOnly
    Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
        -BundleRoot $valid.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $valid.output_root `
        -ExpectedScriptSha256 $valid.acceptance_sha256 `
        -Clipboard `
        -ValidateOnly
    Assert-Fails {
        Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 $valid.acceptance_sha256 `
            -Appearance dark `
            -HighContrast `
            -ValidateOnly
    } 'High Contrast acceptance uses Forced Colors'
    Assert-Fails {
        Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 $valid.acceptance_sha256 `
            -CaptureAdvancedAppearance `
            -HighContrast `
            -ValidateOnly
    } 'Advanced appearance capture is unavailable'
    if (Test-Path -LiteralPath $valid.output_root) {
        throw 'HighContrast ValidateOnly must not create output or change system state.'
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Assert-Fails {
            Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
                -BundleRoot $valid.bundle_root `
                -ExpectedSessionId 1 `
                -OutputRoot $valid.output_root `
                -ExpectedScriptSha256 $valid.acceptance_sha256
        } 'acceptance requires Windows'
        if (Test-Path -LiteralPath $valid.output_root) {
            throw 'The unsupported-platform guard must run before creating acceptance output.'
        }
    }
    Write-RestoreSnapshot -Fixture $valid
    Assert-Fails {
        Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 $valid.acceptance_sha256 `
            -Clipboard `
            -RestoreHighContrastOnly `
            -ValidateOnly
    } 'High Contrast rescue does not accept Clipboard acceptance'
    Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
        -BundleRoot $valid.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $valid.output_root `
        -ExpectedScriptSha256 $valid.acceptance_sha256 `
        -RestoreHighContrastOnly `
        -ValidateOnly
    $resolvedRestore = Resolve-HighContrastRestoreDocument `
        -OutputDirectory $valid.output_root `
        -SourceSha $valid.manifest.source_sha `
        -ScriptSha256 $valid.acceptance_sha256
    if ($resolvedRestore.expected.Flags -ne 126 -or
        $resolvedRestore.expected.Highlight -ne 5 -or
        $resolvedRestore.expected.ThemePath -cne 'C:\Windows\resources\Themes\Aero\Aero.msstyles' -or
        $resolvedRestore.expected.ThemeColor -cne 'NormalColor' -or
        $resolvedRestore.expected.ThemeSize -cne 'NormalSize' -or
        $resolvedRestore.document.restoration_required -ne $true) {
        throw 'The High Contrast restore snapshot was not parsed exactly.'
    }
    $malformedRestorePath = Join-Path $valid.output_root 'high-contrast-restore.json'
    $malformedRestore = Get-Content -LiteralPath $malformedRestorePath -Raw | ConvertFrom-Json
    $malformedRestore.original.PSObject.Properties.Remove('visual_style')
    Write-Utf8Json -Path $malformedRestorePath -Value $malformedRestore
    Assert-Fails {
        Resolve-HighContrastRestoreDocument `
            -OutputDirectory $valid.output_root `
            -SourceSha $valid.manifest.source_sha `
            -ScriptSha256 $valid.acceptance_sha256
    } 'fields are invalid'
    Write-RestoreSnapshot `
        -Fixture $valid `
        -RestorationRequired $false `
        -RestorationVerified $true
    $verifiedRestore = Resolve-HighContrastRestoreDocument `
        -OutputDirectory $valid.output_root `
        -SourceSha $valid.manifest.source_sha `
        -ScriptSha256 $valid.acceptance_sha256
    if ($verifiedRestore.document.restoration_verified -ne $true) {
        throw 'An exact restored visual-style identity must retain verified rescue proof.'
    }
    $mismatchedRestore = Get-Content -LiteralPath $malformedRestorePath -Raw | ConvertFrom-Json
    $mismatchedRestore.restored.visual_style.size = 'DifferentSize'
    Write-Utf8Json -Path $malformedRestorePath -Value $mismatchedRestore
    Assert-Fails {
        Resolve-HighContrastRestoreDocument `
            -OutputDirectory $valid.output_root `
            -SourceSha $valid.manifest.source_sha `
            -ScriptSha256 $valid.acceptance_sha256
    } 'restored state differs'
    Write-RestoreSnapshot -Fixture $valid -SourceSha ('f' * 40)
    Assert-Fails {
        Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 $valid.acceptance_sha256 `
            -RestoreHighContrastOnly `
            -ValidateOnly
    } 'restore snapshot binding mismatch'
    Write-RestoreSnapshot -Fixture $valid -Flags 0x1000
    Assert-Fails {
        Resolve-HighContrastRestoreDocument `
            -OutputDirectory $valid.output_root `
            -SourceSha $valid.manifest.source_sha `
            -ScriptSha256 $valid.acceptance_sha256
    } 'prohibited toggle option'

    Assert-Fails {
        Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 ('0' * 64) `
            -ValidateOnly
    } 'Acceptance script hash mismatch'

    Assert-Fails {
        Invoke-TestAcceptance -EntryPointPath $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot (Join-Path $valid.task_root 'different-output') `
            -ExpectedScriptSha256 $valid.acceptance_sha256 `
            -ValidateOnly
    } 'task bundle out directory'

    Assert-Fails {
        Invoke-DrTestPowerShellEntrypoint `
            -Kind ui `
            -EntryPointPath $acceptance `
            -Parameters @{
                BundleRoot = $valid.bundle_root
                ExpectedSessionId = 1
                OutputRoot = $valid.output_root
                ExpectedScriptSha256 = Get-Sha256 $acceptance
                ValidateOnly = $true
            }
    } 'task-bundled acceptance artifact'

    $dirty = New-AcceptanceFixture -Name 'dirty' -SourceState 'dirty'
    Assert-Fails { Invoke-ValidateOnly $dirty } 'clean source-bound bundle'

    $changedRunner = New-AcceptanceFixture -Name 'changed-runner'
    [IO.File]::AppendAllText($changedRunner.runner, "`n# changed")
    Assert-Fails { Invoke-ValidateOnly $changedRunner } 'Windows VM helper hash mismatch'

    $occupiedOutput = New-AcceptanceFixture -Name 'occupied-output'
    [void](New-Item -ItemType Directory -Path $occupiedOutput.output_root)
    Assert-Fails { Invoke-ValidateOnly $occupiedOutput } 'result file is missing'

    Write-Host 'Windows VM current-DPI acceptance contract tests passed.'
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
            throw 'The Windows VM acceptance test did not remove its owned fixture root.'
        }
    }
    catch {
        if ($null -eq $testFailure) { throw }
        Write-Warning "Fixture cleanup also failed: $($_.Exception.Message)"
    }
}

# Every observer call must satisfy the shared capture contract, including modes
# not exercised by portable execution. This caught a real pre-capture VM failure.
$captureAst = [Management.Automation.Language.Parser]::ParseInput(
    (Get-DrTestCombinedPowerShellSource -Kind ui), [ref]$null, [ref]$null)
$captureCalls = @($captureAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Save-WindowScreenshot'
}, $true))
if ($captureCalls.Count -eq 0) { throw 'Expected real observer screenshot calls.' }
foreach ($call in $captureCalls) {
    $bindings = @($call.CommandElements | Where-Object {
        $_ -is [Management.Automation.Language.CommandParameterAst] -and
        $_.ParameterName -ceq 'ForegroundObservations'
    })
    if ($bindings.Count -ne 1) {
        throw "Screenshot call omits foreground evidence at line $($call.Extent.StartLineNumber)."
    }
}
$applicationStartCalls = @($captureAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Start-AcceptanceApplication'
}, $true))
if ($applicationStartCalls.Count -ne 8) {
    throw 'Expected all eight current-DPI and GUI diagnostic application start sites, including performance sampling.'
}
foreach ($call in $applicationStartCalls) {
    $lifecycleBindings = @($call.CommandElements | Where-Object {
        $_ -is [Management.Automation.Language.CommandParameterAst] -and
            $_.ParameterName -ceq 'ProcessLifecycleObservations'
    })
    if ($lifecycleBindings.Count -ne 1) {
        throw "Application start omits independent lifecycle recording at line $($call.Extent.StartLineNumber)."
    }
}

& {
    $controllerEntryPath = Join-Path $toolingScriptsRoot 'modules/powershell/controller-entry.psm1'
    $controllerTokens = $null
    $controllerErrors = $null
    $controllerAst = [Management.Automation.Language.Parser]::ParseFile(
        $controllerEntryPath, [ref]$controllerTokens, [ref]$controllerErrors
    )
    if ($controllerErrors.Count -ne 0) {
        throw 'The controller entrypoint must parse before producer lifecycle binding is exercised.'
    }
    foreach ($functionName in @(
        'Add-DrControllerLifecycleIdentity'
        'Test-DrControllerProcessJobCleanupLedger'
    )) {
        $definitions = @($controllerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $functionName
        }, $true))
        if ($definitions.Count -ne 1) {
            throw "Expected one controller lifecycle binding function: $functionName"
        }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }

    function New-CleanProcessJobRow {
        param(
            [Parameter(Mandatory)][int] $ProcessId,
            [Parameter(Mandatory)][string] $StartTimeUtcTicks
        )

        [pscustomobject][ordered]@{
            pid = $ProcessId
            process_start_time_utc_ticks = $StartTimeUtcTicks
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
    }
    function Copy-ResultDocument([object] $Value) {
        $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    }

    $verified = [pscustomobject]@{
        lane = 'source-built'
        target = 'x86_64-pc-windows-msvc'
        application = [pscustomobject]@{ file = 'DarkReNamer.exe'; sha256 = 'a' * 64 }
        source_sha = '0123456789abcdef0123456789abcdef01234567'
        runner_sha256 = 'b' * 64
        script_sha256 = 'c' * 64
    }
    $producerResult = New-GuiRegressionResult -Verified $verified -Appearance system
    $producerLifecycles = Get-GuiRegressionProcessLifecycleCollection `
        -Result $producerResult `
        -RawRegression $false
    if (-not $producerResult.Contains('process_lifecycles') -or
        $producerLifecycles -isnot [Collections.Generic.List[object]] -or
        -not [object]::ReferenceEquals($producerLifecycles, $producerResult.process_lifecycles)) {
        throw 'Source-built GUI regression results must own a mutable process lifecycle collection.'
    }
    if ($null -ne (Get-GuiRegressionProcessLifecycleCollection `
            -Result $producerResult `
            -RawRegression $true)) {
        throw 'Candidate GUI regression results must continue using their existing raw lifecycle shape.'
    }
    $expectedIdentities = @(
        [pscustomobject]@{ pid = 4101; ticks = '639000000000000101' }
        [pscustomobject]@{ pid = 4102; ticks = '639000000000000102' }
        [pscustomobject]@{ pid = 4103; ticks = '639000000000000103' }
    )
    foreach ($identity in $expectedIdentities) {
        $application = [pscustomobject]@{
            process = [pscustomobject]@{ Id = $identity.pid; SessionId = 7 }
            owned = [pscustomobject]@{ process_start_time_utc_ticks = $identity.ticks }
        }
        $lifecycle = New-AcceptanceProcessLifecycle `
            -Application $application `
            -ApplicationPath 'C:\fixture\DarkReNamer.exe' `
            -ExecutableSha256 ('d' * 64)
        $producerLifecycles.Add([ordered]@{ process_lifecycle = $lifecycle })
    }
    $producerResult['process_job_cleanup'] = @(
        foreach ($identity in $expectedIdentities) {
            New-CleanProcessJobRow -ProcessId $identity.pid -StartTimeUtcTicks $identity.ticks
        }
    )
    $publishedResult = Copy-ResultDocument $producerResult
    if (-not (Test-DrControllerProcessJobCleanupLedger -Result $publishedResult)) {
        throw 'The controller rejected a source-built producer result with three independently recorded start identities.'
    }

    $singleResult = Copy-ResultDocument $producerResult
    $singleResult.process_lifecycles = @($singleResult.process_lifecycles[0])
    $singleResult.process_job_cleanup = @($singleResult.process_job_cleanup[0])
    if (-not (Test-DrControllerProcessJobCleanupLedger -Result $singleResult)) {
        throw 'The controller rejected a source-built current-DPI-shaped result with one independent start identity.'
    }

    $missingCleanup = Copy-ResultDocument $publishedResult
    $missingCleanup.process_job_cleanup = @($missingCleanup.process_job_cleanup | Select-Object -First 2)
    if (Test-DrControllerProcessJobCleanupLedger -Result $missingCleanup) {
        throw 'The controller accepted a producer lifecycle without its cleanup identity.'
    }
    $mismatchedCleanup = Copy-ResultDocument $publishedResult
    $mismatchedCleanup.process_job_cleanup[1].process_start_time_utc_ticks = '639000000000009999'
    if (Test-DrControllerProcessJobCleanupLedger -Result $mismatchedCleanup) {
        throw 'The controller accepted a cleanup row with a mismatched creation time.'
    }
    $extraCleanup = Copy-ResultDocument $publishedResult
    $extraCleanup.process_job_cleanup = @($extraCleanup.process_job_cleanup) + @(
        New-CleanProcessJobRow -ProcessId 4104 -StartTimeUtcTicks '639000000000000104'
    )
    if (Test-DrControllerProcessJobCleanupLedger -Result $extraCleanup) {
        throw 'The controller accepted an extra cleanup identity absent from producer lifecycles.'
    }
    $duplicateCleanup = Copy-ResultDocument $publishedResult
    $duplicateCleanup.process_job_cleanup = @($duplicateCleanup.process_job_cleanup) + @(
        New-CleanProcessJobRow -ProcessId 4103 -StartTimeUtcTicks '639000000000000103'
    )
    if (Test-DrControllerProcessJobCleanupLedger -Result $duplicateCleanup) {
        throw 'The controller accepted a duplicated cleanup identity.'
    }
}
