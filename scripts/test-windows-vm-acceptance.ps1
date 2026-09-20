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
    Copy-Item -LiteralPath $script:acceptance `
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
    & $Fixture.acceptance `
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

$acceptance = Join-Path $PSScriptRoot 'windows-vm-acceptance.ps1'
$controller = Join-Path $PSScriptRoot 'run-windows-vm-tests.ps1'
$runner = Join-Path $PSScriptRoot 'windows-vm-guest.ps1'
$recovery = Join-Path $PSScriptRoot 'windows-vm-recovery-acceptance.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'darkrenamer-vm-acceptance-' + [Guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $temporaryRoot)
try {
    $acceptanceAst = $null
    foreach ($path in @($acceptance, $MyInvocation.MyCommand.Path)) {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or
            $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
            throw "$([IO.Path]::GetFileName($path)) must retain its UTF-8 BOM for Windows PowerShell 5.1."
        }
        $parseErrors = $null
        $parseTokens = $null
        $parsedAst = [Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$parseTokens,
            [ref]$parseErrors
        )
        if ($path -ceq $acceptance) {
            $acceptanceAst = $parsedAst
        }
        if ($parseErrors.Count -ne 0) {
            throw "$([IO.Path]::GetFileName($path)) has PowerShell parser errors."
        }
    }
    $controllerParseErrors = $null
    $controllerParseTokens = $null
    $controllerAst = [Management.Automation.Language.Parser]::ParseFile(
        $controller,
        [ref]$controllerParseTokens,
        [ref]$controllerParseErrors
    )
    if ($controllerParseErrors.Count -ne 0) {
        throw 'run-windows-vm-tests.ps1 has PowerShell parser errors.'
    }
    $runnerParseErrors = $null
    $runnerParseTokens = $null
    $runnerAst = [Management.Automation.Language.Parser]::ParseFile(
        $runner,
        [ref]$runnerParseTokens,
        [ref]$runnerParseErrors
    )
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

    foreach ($observerPath in @($acceptance, $runner, $recovery)) {
        $observerText = [IO.File]::ReadAllText($observerPath)
        foreach ($heuristic in @('.MainWindowHandle', '.MainWindowTitle', '.CloseMainWindow(')) {
            if ($observerText.IndexOf($heuristic, [StringComparison]::Ordinal) -ge 0) {
                throw "$([IO.Path]::GetFileName($observerPath)) must not use process main-window heuristics '$heuristic'."
            }
        }
    }
    $controllerText = [IO.File]::ReadAllText($controller)
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
    $earlyAggregatePattern = '\$total\s*\+=\s*\$row(?:\.item)?\.Length\s*' +
        'if\s*\(\$total\s*-gt\s*512MB\)\s*\{\s*throw\s*' +
        "'[^']+aggregate size bound[^']*'\s*\}\s*\[pscustomobject\]@\{"
    if ([regex]::Matches(
        $controllerText,
        $earlyAggregatePattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    ).Count -ne 2) {
        throw 'UI and recovery collection must reject the aggregate limit before hashing rows.'
    }
    $guestOutputComposition = 'Join-GuestWindowsPath -Root (Join-GuestWindowsPath -Root'
    if ([regex]::Matches($controllerText, [regex]::Escape($guestOutputComposition)).Count -ne 3) {
        throw 'Acceptance, text-scale rescue, and High Contrast rescue collection must compose guest output paths without host Join-Path.'
    }
    foreach ($requiredRescueSource in @(
        'function Invoke-AcceptanceTextScaleRescue',
        '-RestoreTextScaleOnly',
        'text-scale-rescue-result.json',
        'text-scale-rescue.stdout.txt',
        'text-scale-rescue.stderr.txt'
    )) {
        if ($controllerText.IndexOf($requiredRescueSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The VM controller is missing the text-scale rescue contract '$requiredRescueSource'."
        }
    }
    foreach ($requiredObserverSource in @(
        'function Invoke-AcceptanceHighContrastRescue',
        '-RestoreHighContrastOnly',
        'high-contrast-rescue-result.json',
        'elseif ($recovery)',
        'Recovery output file count exceeds its bound.',
        'Recovery output contains a reparse entry.',
        '-PrivateEvidenceRoot "'' + $private + ''"',
        "prefix = 'private/'",
        'recovery-inventory.json',
        '-Role recovery',
        'Assert-ObserverResultBinding',
        '(-not $observerTask -or $acceptancePassed)'
    )) {
        if ($controllerText.IndexOf($requiredObserverSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The shared controller is missing observer contract '$requiredObserverSource'."
        }
    }
    foreach ($requiredRawCleanupSource in @(
        'scheduled_task_present =',
        'guest_root_present =',
        'owned_processes_after =',
        "`$transport['raw_cleanup'] = `$cleanupResult.raw_cleanup",
        'Guest cleanup did not return its bound raw observation.'
    )) {
        if ($controllerText.IndexOf($requiredRawCleanupSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The shared controller is missing raw cleanup evidence '$requiredRawCleanupSource'."
        }
    }
    if ($controllerText.IndexOf(
        "(`$state.result_status -cne 'review_required' -or `$state.task_result -ne 0)",
        [StringComparison]::Ordinal
    ) -lt 0) {
        throw 'The VM controller must run its text-scale rescue after every unsuccessful acceptance task.'
    }
    foreach ($requiredTerminalSource in @(
        'result_status = $resultStatus',
        'task_state = $taskState',
        'task_result = $taskResult',
        'last_run_time_ticks = [long]$info.LastRunTime.Ticks',
        '$taskResult = [long]$terminalInfo.LastTaskResult',
        'Resolve-ObserverTaskPollState',
        '-RegisteredLastRunTimeTicks $acceptanceEngine.registered_last_run_time_ticks',
        'if ($state.terminal) { break }',
        '$transport.observer_process = $observerProcess',
        'exit_code = [long]$state.task_result',
        '$observerProcess.exit_code -eq 0'
    )) {
        if ($controllerText.IndexOf($requiredTerminalSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The VM controller is missing terminal observer-task evidence '$requiredTerminalSource'."
        }
    }
    $streamCollectionIndex = $controllerText.IndexOf(
        "foreach (`$leaf in @('observer.stdout.txt', 'observer.stderr.txt'))",
        [StringComparison]::Ordinal
    )
    $successPostlaunchIndex = $controllerText.IndexOf(
        "if (`$state.result_status -ceq 'review_required' -and `$state.task_result -eq 0)",
        $streamCollectionIndex,
        [StringComparison]::Ordinal
    )
    $inventoryIndex = $controllerText.IndexOf(
        '$inventory = @(Invoke-Command',
        $successPostlaunchIndex,
        [StringComparison]::Ordinal
    )
    if ($streamCollectionIndex -lt 0 -or $successPostlaunchIndex -le $streamCollectionIndex -or
        $inventoryIndex -le $successPostlaunchIndex) {
        throw 'Observer streams must be moved before success-only postlaunch identity and bounded inventory collection.'
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
    $policy = Get-ExecutionPolicy
    $policyRoundTrip = [ordered]@{
        effective_policy = $policy.ToString()
    } | ConvertTo-Json -Compress | ConvertFrom-Json
    if ($policyRoundTrip.effective_policy -isnot [string] -or
        $policyRoundTrip.effective_policy -cne $policy.ToString()) {
        throw 'Execution policy evidence must retain its enum name through JSON serialization.'
    }
    $policySerialization = 'effective_policy=(Get-ExecutionPolicy).ToString()'
    if ([regex]::Matches($controllerText, [regex]::Escape($policySerialization)).Count -ne 5) {
        throw 'Core, observer, and rescue engine checks must serialize the execution policy name.'
    }
    foreach ($line in @($controllerText -split "`r?`n" | Where-Object {
        $_ -match '\$observerArguments\s*=' -and $_ -notmatch '^\s*#'
    })) {
        if ($line.IndexOf('ExecutionPolicy', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw 'New GUI acceptance and rescue commands must not override execution policy.'
        }
    }
    if ([IO.File]::ReadAllText($acceptance).IndexOf('[ushort]', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw 'The acceptance script must use Windows PowerShell 5.1-compatible integer type names.'
    }
    $acceptanceText = [IO.File]::ReadAllText($acceptance)
    if ($acceptanceText.IndexOf(
        'journal_after = [ordered]@{ entries = @() }',
        [StringComparison]::Ordinal
    ) -ge 0) {
        throw 'UI cleanup must not serialize an unobserved journal as an empty inventory.'
    }
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
    $scrollInfoProducer = 'return new [] { info.Minimum, info.Maximum, (int)info.Page, info.Position, info.TrackPosition };'
    if ([regex]::Matches($acceptanceText, [regex]::Escape($scrollInfoProducer)).Count -ne 1) {
        throw 'The native scroll-info helper must return its fixed five-value SCROLLINFO projection.'
    }
    $scrollInfoConsumer = '$values.Count -ne 5'
    if ([regex]::Matches($acceptanceText, [regex]::Escape($scrollInfoConsumer)).Count -ne 2 -or
        $acceptanceText.IndexOf('$values.Count -ne 6', [StringComparison]::Ordinal) -ge 0) {
        throw 'Both native scroll-info consumers must require the producer five-value shape.'
    }
    $reachabilityMapIndex = $acceptanceText.IndexOf(
        '$reachability = [ordered]@{',
        [StringComparison]::Ordinal
    )
    $reachabilityReceiptIndex = if ($reachabilityMapIndex -lt 0) { -1 } else {
        $acceptanceText.IndexOf(
            "(`$Prefix + '-reachability.json')",
            $reachabilityMapIndex,
            [StringComparison]::Ordinal
        )
    }
    $reachabilityControlsIndex = if ($reachabilityReceiptIndex -lt 0) { -1 } else {
        $acceptanceText.IndexOf(
            'controls = $reachability',
            $reachabilityReceiptIndex,
            [StringComparison]::Ordinal
        )
    }
    $reachabilityThrowIndex = if ($reachabilityControlsIndex -lt 0) { -1 } else {
        $acceptanceText.IndexOf(
            'After context confirmation has a mouse-inaccessible required control',
            $reachabilityControlsIndex,
            [StringComparison]::Ordinal
        )
    }
    if ($reachabilityMapIndex -lt 0 -or $reachabilityReceiptIndex -le $reachabilityMapIndex -or
        $reachabilityControlsIndex -le $reachabilityReceiptIndex -or
        $reachabilityThrowIndex -le $reachabilityControlsIndex) {
        throw 'Context confirmation must persist its fixed control reachability map before rejecting inaccessible controls.'
    }
    foreach ($diagnosticField in @(
        'hit_window=', 'hit_process_id=', 'hit_root_window=',
        'expected_process_id=', 'expected_root_window='
    )) {
        if ($acceptanceText.IndexOf($diagnosticField, [StringComparison]::Ordinal) -lt 0) {
            throw "Physical target failures must retain bounded diagnostic field '$diagnosticField'."
        }
    }
    if ($acceptanceText.IndexOf(
        '[DarkReNamerVmNative]::GetWindowThreadProcessId($hit',
        [StringComparison]::Ordinal
    ) -lt 0 -or $acceptanceText.IndexOf(
        '[DarkReNamerVmAcceptanceNative]::GetWindowThreadProcessId($hit',
        [StringComparison]::Ordinal
    ) -ge 0) {
        throw 'Physical reachability must call the shared public process-binding API.'
    }
    $regressionModeIndex = $acceptanceText.IndexOf(
        "if (-not [string]::IsNullOrEmpty(`$RegressionMode))",
        [StringComparison]::Ordinal
    )
    $regressionSaveIndex = $acceptanceText.IndexOf(
        '$regressionInvocation = [pscustomobject]@{',
        $regressionModeIndex,
        [StringComparison]::Ordinal
    )
    $regressionGuestIndex = $acceptanceText.IndexOf(
        '. $bootstrap.runner',
        $regressionSaveIndex,
        [StringComparison]::Ordinal
    )
    $regressionRestoreIndex = $acceptanceText.IndexOf(
        '$ValidateOnly = $regressionInvocation.validate_only',
        $regressionGuestIndex,
        [StringComparison]::Ordinal
    )
    $regressionInvokeIndex = $acceptanceText.IndexOf(
        'Invoke-GuiRegressionAcceptance',
        $regressionRestoreIndex,
        [StringComparison]::Ordinal
    )
    if ($regressionModeIndex -lt 0 -or $regressionSaveIndex -le $regressionModeIndex -or
        $regressionGuestIndex -le $regressionSaveIndex -or
        $regressionRestoreIndex -le $regressionGuestIndex -or
        $regressionInvokeIndex -le $regressionRestoreIndex) {
        throw 'The regression entry must restore its caller ValidateOnly switch after importing the guest helper.'
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
        $reachability = $acceptanceAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-VmAutomatedFocusReachability'
        }, $true)
        $stepAssignment = $reachability.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -ceq '$step'
        }, $true)
        . ([scriptblock]::Create($stepAssignment.Extent.Text))
        function Get-VmAutomatedFocusBinding {
            param($Element, $Process, $ExpectedSession, $Label)
            [ordered]@{ automation_id = $Element }
        }
        function Invoke-AcceptanceNavigationStep {
            param($Process, $ExpectedSession, $VirtualKey, $Label)
            if ($VirtualKey -eq 0x09) { '32772' } else { '32773' }
        }
        $Application = @{ process = $null }
        $ExpectedSession = 1
        $navigation = @{ current = '1000' }
        $transitions = [Collections.Generic.List[object]]::new()
        [void](& $step 'tab' 0x09)
        [void](& $step 'down' 0x28)
        if ($transitions.Count -ne 2 -or $transitions[0].input -cne 'tab' -or
            $transitions[1].input -cne 'down' -or $transitions[1].from.automation_id -cne '32772') {
            throw 'Actual navigation step must retain its key labels and contiguous focus observations.'
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
        $script:startupOwned = [pscustomobject]@{ process = $startupProcess }
        Assert-Fails {
            Start-AcceptanceApplication `
                -FilePath 'fixture.exe' `
                -WorkingDirectory 'fixture-root' `
                -SessionId 1 `
                -WaitSeconds 10 `
                -Label 'startup fixture'
        } 'Pinned startup binding failed'
        if (-not $startupProcess.killed -or -not $startupProcess.disposed -or
            $startupProcess.waited_milliseconds -ne 10000) {
            throw 'Failed startup must terminate and dispose the exact owned process within the fixed bound.'
        }

        $timeoutProcess = [pscustomobject]@{
            HasExited = $false
            killed = $false
            disposed = $false
        }
        $timeoutProcess | Add-Member ScriptMethod Refresh { }
        $timeoutProcess | Add-Member ScriptMethod Kill { $this.killed = $true }
        $timeoutProcess | Add-Member ScriptMethod WaitForExit { param([int] $Milliseconds) $false }
        $timeoutProcess | Add-Member ScriptMethod Dispose { $this.disposed = $true }
        $script:startupOwned = [pscustomobject]@{ process = $timeoutProcess }
        Assert-Fails {
            Start-AcceptanceApplication `
                -FilePath 'fixture.exe' `
                -WorkingDirectory 'fixture-root' `
                -SessionId 1 `
                -WaitSeconds 10 `
                -Label 'startup cleanup-timeout fixture'
        } 'Application startup validation and exact-process cleanup both failed: Pinned startup binding failed. Cleanup: The exact owned acceptance process did not terminate.'
        if (-not $timeoutProcess.killed -or -not $timeoutProcess.disposed) {
            throw 'Timed-out startup cleanup must still attempt exact process termination and disposal.'
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
        $script:closeProbe = @{ keyboard = 0; ordinary = 0 }
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
        $application = @{ process = $process; main = $window; main_handle = [IntPtr]5151 }
        [void](Close-AcceptanceApplication -Application $application -SessionId 1 -WaitSeconds 1 -CloseInput keyboard)
        if ($script:closeProbe.keyboard -ne 1 -or $script:closeProbe.ordinary -ne 0) {
            throw 'Keyboard close must deliver Alt+F4 through the actual close helper.'
        }
        [void](Close-AcceptanceApplication -Application $application -SessionId 1 -WaitSeconds 1 -CloseInput ordinary)
        if ($script:closeProbe.keyboard -ne 1 -or $script:closeProbe.ordinary -ne 1) {
            throw 'Ordinary close must target the exact pinned main window.'
        }
        Remove-Variable closeProbe -Scope Script
    }
    $probeValidateOnly = $false
    & {
        $BundleRoot = 'probe-bundle'
        $ExpectedSessionId = 1
        $ValidateOnly = $probeValidateOnly
        . $runner -BundleRoot $BundleRoot -ExpectedSessionId $ExpectedSessionId -ValidateOnly
        if (-not $ValidateOnly) {
            throw 'The guest dot-source contamination probe no longer reproduces the caller-scope switch overwrite.'
        }
        $ValidateOnly = $probeValidateOnly
        if ($ValidateOnly) { throw 'The caller-mode restoration probe failed.' }
    }
    $clipboardAssignments = @($acceptanceAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -ieq 'Clipboard'
    }, $true))
    if ($clipboardAssignments.Count -ne 1 -or
        $clipboardAssignments[0].Left.Extent.Text -cne '$Clipboard' -or
        $clipboardAssignments[0].Right.Extent.Text -cne '$acceptanceInvocation.clipboard') {
        throw 'The Clipboard switch must not be shadowed by a case-insensitive result variable.'
    }
    if ($acceptanceText -match 'extern IntPtr LocalFree|LocalFree\(value\.scheme\)') {
        throw 'The acceptance observer must not free ambiguous High Contrast GET pointers.'
    }
    if ($acceptanceText.IndexOf(
        'private const int MaxHighContrastReads = 128;',
        [StringComparison]::Ordinal
    ) -lt 0) {
        throw 'The process-lifetime High Contrast pointer strategy must remain bounded.'
    }
    $selectionObservationIndex = $acceptanceText.IndexOf(
        '        $selectionPatternObject = $null',
        [StringComparison]::Ordinal
    )
    $previewWaitIndex = $acceptanceText.IndexOf(
        '        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $destinationName -TimeoutSeconds $TimeoutSeconds',
        [StringComparison]::Ordinal
    )
    $resetFocusIndex = $acceptanceText.IndexOf(
        "        [void](Move-RailFocusToCommand -Process `$process -ExpectedSession `$ExpectedSessionId -AutomationId '32781')",
        [StringComparison]::Ordinal
    )
    if ($selectionObservationIndex -lt 0 -or
        $previewWaitIndex -lt 0 -or
        $resetFocusIndex -lt 0 -or
        $selectionObservationIndex -gt $previewWaitIndex -or
        $selectionObservationIndex -gt $resetFocusIndex) {
        throw 'The no-selection reset observation must precede list refresh and reset focus movement.'
    }
    if ($acceptanceText.IndexOf("-AutomationId '1148'", [StringComparison]::Ordinal) -lt 0 -or
        $acceptanceText.IndexOf(
            '-ControlType ([Windows.Automation.ControlType]::Edit)',
            [StringComparison]::Ordinal
        ) -lt 0) {
        throw 'The common-dialog filename target must select the editable UIA child.'
    }
    foreach ($taskDialogId in @('CommandButton_2', 'CommandLink_1101')) {
        if ($acceptanceText.IndexOf(
            "-AutomationId '$taskDialogId'",
            [StringComparison]::Ordinal
        ) -lt 0) {
            throw "The acceptance flow is missing TaskDialog automation ID $taskDialogId."
        }
    }
    foreach ($requiredRawObservation in @(
        'function Get-VmAutomatedKeyboardEventStart',
        "-ExpectedAutomationId 'CommandButton_2'",
        "-ExpectedAutomationId 'CommandLink_1101'",
        'root_hwnd = [long]$rootHandle',
        'Complete-VmAutomatedKeyboardEvent',
        'Get-VmAutomatedCheckpoint',
        '$result.raw_environment = Get-VmAutomatedEnvironment',
        "exit_method = 'normal-close'",
        "exit_method = 'forced-termination'",
        '$result.raw_cleanup = [ordered]@{',
        '$result.layout_observations = [ordered]@{'
        'function New-VmAutomatedLayoutRun'
        'function Complete-VmAutomatedLayoutRun'
        '$result.raw_layout_runs = @($scenario.raw_layout_runs)'
        '$result.raw_text_scale = [ordered]@{'
        'active_winrt_percent = [int]$observations.scenario.environment.text_scale_factor_percent'
        'function Get-VmAutomatedAppearance'
        '$result.raw_appearance = Get-VmAutomatedAppearance'
        'raw_appearance = Get-VmAutomatedAppearance'
        'function Resolve-GuiRegressionLayoutVariant'
        'function Get-VmAutomatedNativeMenuCommandSpec'
        'function Assert-VmAutomatedNativeMenuPathSegment'
        'function ConvertTo-VmAutomatedNativeMenuRelativePath'
        'function Get-VmAutomatedNativeMenuState'
        'function Assert-VmAutomatedNativeMenuTree'
        'function Get-VmAutomatedHiddenRailControls'
        'function Invoke-VmAutomatedNativeMenuOnlyReachability'
        'IntPtr itemOwner = depth == 0 ? window : IntPtr.Zero;'
        "variant = 'native-menu-only'"
        'hidden_rail_controls = $hiddenRails'
        'menu_tree = $menuTree'
        'function New-VmAutomatedFocusReachabilityControl'
        'function Invoke-VmAutomatedFocusReachability'
        'focus_reachability = $focusReachability'
        'focus_reachability = $rawFocusReachability'
        "& `$step 'tab' 0x09"
        "& `$step 'down' 0x28"
        'Get-VmAutomatedFixtureInventory -FixtureRoot $FixtureRoot'
        'Get-VmAutomatedJournalInventory -LocalAppData $LocalAppData'
    )) {
        if ($acceptanceText.IndexOf($requiredRawObservation, [StringComparison]::Ordinal) -lt 0) {
            throw "The candidate UI raw observation contract is missing '$requiredRawObservation'."
        }
    }
    $regressionCleanupValidation = $acceptanceText.IndexOf(
        '[void](Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot)',
        [StringComparison]::Ordinal
    )
    $regressionCleanupDelete = $acceptanceText.IndexOf(
        'Remove-Item -LiteralPath $runtimeRoot -Recurse -Force',
        $regressionCleanupValidation + 1,
        [StringComparison]::Ordinal
    )
    if ($regressionCleanupValidation -lt 0 -or
        $regressionCleanupDelete -le $regressionCleanupValidation) {
        throw 'GUI regression cleanup must validate the bounded ordinary runtime tree before deletion.'
    }
    if ([regex]::Matches(
        $acceptanceText,
        [regex]::Escape('[void](Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot)')
    ).Count -ne 2) {
        throw 'Regression and current-DPI cleanup must both validate their runtime tree before deletion.'
    }
    $appearanceFunctions = @($acceptanceAst.FindAll({
        param($ast)
        $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $ast.Name -ceq 'Get-VmAutomatedAppearance'
    }, $true))
    if ($appearanceFunctions.Count -ne 1) {
        throw 'The acceptance script must define one Get-VmAutomatedAppearance helper.'
    }
    $appearanceDefinition = $appearanceFunctions[0].Extent.Text
    foreach ($requiredAppearanceSource in @(
        'Assert-AutomationBinding',
        '-RequireWindowHandle',
        '0x9010',
        '0x9011',
        '0x9012',
        'menu_checked = $menu'
    )) {
        if ($appearanceDefinition.IndexOf($requiredAppearanceSource, [StringComparison]::Ordinal) -lt 0) {
            throw "Raw appearance observation is missing '$requiredAppearanceSource'."
        }
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
    $focusReachabilityFunctions = @($acceptanceAst.FindAll({
        param($ast)
        $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $ast.Name -ceq 'Invoke-VmAutomatedFocusReachability'
    }, $true))
    if ($focusReachabilityFunctions.Count -ne 1) {
        throw 'The acceptance script must define one bounded focus reachability traversal.'
    }
    $focusReachabilitySource = $focusReachabilityFunctions[0].Extent.Text
    foreach ($requiredFocusSource in @(
        'transition count exceeds its bound',
        'sequence = [int]$transitions.Count + 1',
        "foreach (`$scope in @('list', 'left', 'right'))",
        'Raw keyboard focus cycled before visiting every enabled',
        'Raw keyboard focus traversal changed the fixture or journal state.'
    )) {
        if ($focusReachabilitySource.IndexOf($requiredFocusSource, [StringComparison]::Ordinal) -lt 0) {
            throw "Raw focus reachability is missing '$requiredFocusSource'."
        }
    }
    foreach ($menuHelperName in @(
        'Assert-VmAutomatedNativeMenuPathSegment',
        'ConvertTo-VmAutomatedNativeMenuRelativePath',
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
    $nativeMenuRelativePath = ConvertTo-VmAutomatedNativeMenuRelativePath `
        -ParentSegments @($nativeMenuFixtureParent) -Leaf $nativeMenuFixtureLeaf
    if ($nativeMenuRelativePath -cne "$nativeMenuFixtureParent/$nativeMenuFixtureLeaf") {
        throw 'Native menu fixture paths must preserve Unicode segments with canonical separators.'
    }
    Assert-Fails {
        ConvertTo-VmAutomatedNativeMenuRelativePath `
            -ParentSegments @('one','two','three') -Leaf 'four.txt'
    } 'depth'
    Assert-Fails {
        ConvertTo-VmAutomatedNativeMenuRelativePath `
            -ParentSegments @() -Leaf ('bad-' + [char]0xD800)
    } 'UTF-16'
    Assert-Fails {
        ConvertTo-VmAutomatedNativeMenuRelativePath -ParentSegments @() -Leaf 'bad.'
    } 'unsafe'
    $nativeMenuStateFunction = $acceptanceAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-VmAutomatedNativeMenuState'
    }, $true)
    $nativeMenuStateSource = $nativeMenuStateFunction.Extent.Text
    foreach ($requiredStateSource in @(
        'The native menu fixture inventory exceeds sixteen entries.',
        '[IO.FileAttributes]::ReparsePoint',
        'The native menu fixture inventory contains an oversized file.',
        'The native menu fixture inventory exceeds its aggregate size bound.',
        '[StringComparer]::Ordinal.Compare',
        'relative_path = $relativePath',
        'file_identity = Get-FullFileIdentity -Path $item.FullName'
    )) {
        if ($nativeMenuStateSource.IndexOf($requiredStateSource, [StringComparison]::Ordinal) -lt 0) {
            throw "Native menu recursive fixture state is missing '$requiredStateSource'."
        }
    }
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
    if ([regex]::Matches(
            $menuReachabilitySource,
            [regex]::Escape('Get-VmAutomatedNativeMenuState')
        ).Count -ne 2 -or
        $menuReachabilitySource.IndexOf(
            'Get-VmAutomatedFocusState',
            [StringComparison]::Ordinal
        ) -ge 0) {
        throw 'Native menu traversal must use the bounded recursive fixture state before and after input.'
    }
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
    $virtualKeyAssignment = $menuKeyFunction.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$virtualKeys'
    }, $true)
    foreach ($dispatchCase in @(
        [ordered]@{ action = 'alt-f'; expected = [int[]]@(0x12, 0x46) }
        [ordered]@{ action = 'down'; expected = [int[]]@(0x28) }
        [ordered]@{ action = 'escape'; expected = [int[]]@(0x1B) }
    )) {
        & {
            $KeyAction = $dispatchCase.action
            . ([scriptblock]::Create($virtualKeyAssignment.Extent.Text))
            if ($virtualKeys -isnot [array] -or
                @($virtualKeys).Count -ne $dispatchCase.expected.Count -or
                @(Compare-Object @($virtualKeys) @($dispatchCase.expected) -SyncWindow 0).Count -ne 0) {
                throw "The production native-menu key dispatcher lost or scalarized $KeyAction."
            }
        }
    }
    foreach ($requiredMenuInput in @("'alt-f'", "'alt-e'", "'alt-t'", "'down'", "'right'", "'escape'")) {
        if ($menuReachabilitySource.IndexOf($requiredMenuInput, [StringComparison]::Ordinal) -lt 0) {
            throw "Native menu reachability is missing actual input $requiredMenuInput."
        }
    }
    if ($menuReachabilitySource.IndexOf('SendMenuCommand', [StringComparison]::Ordinal) -ge 0) {
        throw 'Native menu reachability must not invoke a command programmatically.'
    }
    if (($acceptanceText | Select-String -Pattern "failure_reason = 'desktop_lock_release_failed'" -AllMatches).Matches.Count -ne 3) {
        throw 'Current-DPI, GUI regression, and rescue paths must preserve structured evidence after desktop-lock release failure.'
    }
    $captureResizeIndex = $acceptanceText.IndexOf(
        '        $captureWindow = Ensure-AcceptanceMainWindowCaptureSize',
        [StringComparison]::Ordinal
    )
    $initialCaptureIndex = $acceptanceText.IndexOf(
        '        $initialCapture = Save-WindowScreenshot',
        [StringComparison]::Ordinal
    )
    if ($captureResizeIndex -lt 0 -or
        $initialCaptureIndex -lt 0 -or
        $captureResizeIndex -gt $initialCaptureIndex) {
        throw 'Evidence-eligible main-window sizing must precede the first workbench capture.'
    }
    $clipboardFlowIndex = $acceptanceText.IndexOf(
        "        if (`$Clipboard) {",
        [StringComparison]::Ordinal
    )
    $prefixCompleteIndex = $acceptanceText.IndexOf(
        '        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $destinationName -TimeoutSeconds $TimeoutSeconds',
        [StringComparison]::Ordinal
    )
    $beforeResetIndex = $acceptanceText.IndexOf(
        '        $beforeReset = Get-ListPrimarySnapshot -List $list',
        [StringComparison]::Ordinal
    )
    if ($clipboardFlowIndex -lt 0 -or
        $prefixCompleteIndex -lt 0 -or
        $beforeResetIndex -lt 0 -or
        $clipboardFlowIndex -lt $prefixCompleteIndex -or
        $clipboardFlowIndex -gt $beforeResetIndex) {
        throw 'Clipboard acceptance must run after import and prefix while the exact row remains known.'
    }
    foreach ($requiredClipboardSource in @(
        '[switch] $Clipboard',
        '[uint32]0x8018',
        '[uint32]0x801A',
        "-Modifier 0x11 -SecondModifier 0x10 -VirtualKey 0x43",
        'ClearClipboardIfOwned'
    )) {
        if ($acceptanceText.IndexOf($requiredClipboardSource, [StringComparison]::Ordinal) -lt 0) {
            throw "The acceptance flow is missing required Clipboard contract '$requiredClipboardSource'."
        }
    }
    $clipboardNamesFailureIndex = $acceptanceText.IndexOf(
        "            `$result.failure_reason = 'clipboard_names_failed'",
        [StringComparison]::Ordinal
    )
    $clipboardPathsFailureIndex = $acceptanceText.IndexOf(
        "            `$result.failure_reason = 'clipboard_paths_failed'",
        [StringComparison]::Ordinal
    )
    $clipboardPathsChordIndex = $acceptanceText.IndexOf(
        '            Send-AcceptanceTwoModifierChord -Process $process',
        [StringComparison]::Ordinal
    )
    if ($clipboardNamesFailureIndex -lt 0 -or
        $clipboardPathsFailureIndex -le $clipboardNamesFailureIndex -or
        $clipboardPathsChordIndex -le $clipboardPathsFailureIndex) {
        throw 'The Copy Paths phase must identify its failure before the Ctrl+Shift+C action.'
    }

    . $acceptance `
        -BundleRoot 'unused' `
        -ExpectedSessionId 1 `
        -OutputRoot 'unused' `
        -ExpectedScriptSha256 ('0' * 64) `
        -ValidateOnly
    if ($acceptanceText.IndexOf('ContentType=WindowsRuntime', [StringComparison]::Ordinal) -ge 0 -or
        ([IO.File]::ReadAllText($runner)).IndexOf('public static double ReadTextScaleFactor()', [StringComparison]::Ordinal) -lt 0) {
        throw 'Text-scale reads must use the PowerShell Core-compatible native UISettings ABI helper.'
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        . $runner -BundleRoot 'unused' -ExpectedSessionId 1 -ValidateOnly
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
    $prefixMoveIndex = $acceptanceText.IndexOf(
        "Move-RailFocusToCommand -Process `$process -ExpectedSession `$ExpectedSessionId -AutomationId '32773'",
        [StringComparison]::Ordinal
    )
    $prefixBindingIndex = $acceptanceText.IndexOf(
        '$prefixActivationAttempt = Get-AcceptanceCommandActivationAttempt',
        $prefixMoveIndex,
        [StringComparison]::Ordinal
    )
    $prefixPersistIndex = $acceptanceText.IndexOf(
        "`$observations['prefix_activation_attempt'] = `$prefixActivationAttempt",
        $prefixBindingIndex,
        [StringComparison]::Ordinal
    )
    $prefixTapIndex = $acceptanceText.IndexOf(
        '[DarkReNamerVmAcceptanceNative]::Tap(0x20)',
        $prefixPersistIndex,
        [StringComparison]::Ordinal
    )
    $prefixAssertIndex = $acceptanceText.IndexOf(
        'Assert-AcceptanceCommandActivationBinding',
        $prefixPersistIndex,
        [StringComparison]::Ordinal
    )
    $prefixWaitIndex = $acceptanceText.IndexOf(
        '-Label ''keyboard prefix prompt''',
        $prefixTapIndex,
        [StringComparison]::Ordinal
    )
    $prefixRemoveIndex = $acceptanceText.IndexOf(
        "`$observations.Remove('prefix_activation_attempt')",
        $prefixWaitIndex,
        [StringComparison]::Ordinal
    )
    if ($prefixMoveIndex -lt 0 -or $prefixBindingIndex -le $prefixMoveIndex -or
        $prefixPersistIndex -le $prefixBindingIndex -or $prefixAssertIndex -le $prefixPersistIndex -or
        $prefixTapIndex -le $prefixAssertIndex -or
        $prefixWaitIndex -le $prefixTapIndex -or $prefixRemoveIndex -le $prefixWaitIndex) {
        throw 'Prefix Space must bind and persist its exact target before input and retain diagnostics only on failure.'
    }
    if ([regex]::Matches(
            $acceptanceText,
            'Wait-AcceptanceOwnedInputWindow\s+`\s*\r?\n\s*-Process \$process'
        ).Count -ne 2 -or
        [regex]::Matches(
            $acceptanceText,
            '-Owner \$mainWindow\s+`\s*\r?\n\s*-Name ''이름 앞에 문자열 붙이기'''
        ).Count -ne 2) {
        throw 'Both current-DPI prefix prompts must use exact owner-bound native-to-UIA discovery.'
    }
    $windowInventoryFunction = $acceptanceAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-BoundedAcceptanceProcessWindowInventory'
    }, $true)
    $windowInventoryText = $windowInventoryFunction.Extent.Text
    if ($windowInventoryText.IndexOf('Select-Object -First 32', [StringComparison]::Ordinal) -lt 0 -or
        $windowInventoryText.IndexOf('$_.Title', [StringComparison]::Ordinal) -ge 0) {
        throw 'Failure window diagnostics must remain bounded and omit window titles.'
    }
    foreach ($failureField in @(
        'failure_focus_reachability',
        'prefix_failure_process_windows'
    )) {
        if ($acceptanceText.IndexOf($failureField, [StringComparison]::Ordinal) -lt 0) {
            throw "Prefix failure diagnostics omit $failureField."
        }
    }
    if ($acceptanceText.IndexOf('$Verified.manifest.application', [StringComparison]::Ordinal) -ge 0 -or
        [regex]::Matches(
            $acceptanceText,
            [regex]::Escape('$Verified.application')
        ).Count -lt 4) {
        throw 'GUI regression scenarios must use the normalized verified application binding.'
    }
    $startFunction = (Get-Command Start-AcceptanceApplication -CommandType Function).Definition
    if ($startFunction.IndexOf('Wait-ExactApplicationMainWindow', [StringComparison]::Ordinal) -lt 0 -or
        $startFunction.IndexOf('-TimeoutSeconds $WaitSeconds', [StringComparison]::Ordinal) -lt 0 -or
        $startFunction.IndexOf('main_handle = $mainHandle', [StringComparison]::Ordinal) -lt 0) {
        throw 'Shared application startup must retain the exact native-to-UIA main-window binding.'
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
    $closeFunction = (Get-Command Close-AcceptanceApplication -CommandType Function).Definition
    if ($closeFunction.IndexOf('CloseMainWindow', [StringComparison]::Ordinal) -ge 0 -or
        $closeFunction.IndexOf('Close-ExactApplicationMainWindow', [StringComparison]::Ordinal) -lt 0) {
        throw 'Ordinary acceptance close must target the exact pinned main window.'
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
    foreach ($chordName in @('Send-AcceptanceChord', 'Send-AcceptanceTwoModifierChord')) {
        $chordFunction = @($acceptanceAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $chordName
        }, $true))
        if ($chordFunction.Count -ne 1 -or
            $chordFunction[0].Extent.Text.IndexOf(
                '[switch] $ExtendedKey', [StringComparison]::Ordinal
            ) -lt 0 -or
            $chordFunction[0].Extent.Text.IndexOf(
                '::TapExtended($VirtualKey)', [StringComparison]::Ordinal
            ) -lt 0 -or
            $chordFunction[0].Extent.Text.IndexOf(
                '::Tap($VirtualKey)', [StringComparison]::Ordinal
            ) -lt 0) {
            throw "$chordName does not distinguish extended navigation keys from ordinary keys."
        }
    }
    $clipboardInitializerStart = $acceptanceText.IndexOf(
        'public static ClipboardSnapshot ReadOrInitializeEmptyClipboardSnapshot()',
        [StringComparison]::Ordinal
    )
    $clipboardInitializerEnd = $acceptanceText.IndexOf(
        'public static string ClearClipboardIfOwned',
        $clipboardInitializerStart,
        [StringComparison]::Ordinal
    )
    if ($clipboardInitializerStart -lt 0 -or
        $clipboardInitializerEnd -le $clipboardInitializerStart) {
        throw 'The guarded empty Clipboard initializer is missing.'
    }
    $clipboardInitializerSource = $acceptanceText.Substring(
        $clipboardInitializerStart,
        $clipboardInitializerEnd - $clipboardInitializerStart
    )
    $initializerRead = $clipboardInitializerSource.IndexOf(
        'ClipboardSnapshot snapshot = ReadOpenClipboardSnapshot();',
        [StringComparison]::Ordinal
    )
    $initializerDecision = $clipboardInitializerSource.IndexOf(
        'if (!RequiresEmptyClipboardInitialization(snapshot)) { return snapshot; }',
        [StringComparison]::Ordinal
    )
    $initializerEmpty = $clipboardInitializerSource.IndexOf(
        'if (!EmptyClipboard())',
        [StringComparison]::Ordinal
    )
    $initializerReread = $clipboardInitializerSource.IndexOf(
        'ClipboardSnapshot initialized = ReadOpenClipboardSnapshot();',
        [StringComparison]::Ordinal
    )
    if ($clipboardInitializerSource.IndexOf('OpenClipboard(IntPtr.Zero)', [StringComparison]::Ordinal) -lt 0 -or
        $initializerRead -lt 0 -or $initializerDecision -le $initializerRead -or
        $initializerEmpty -le $initializerDecision -or $initializerReread -le $initializerEmpty -or
        $clipboardInitializerSource.IndexOf('CloseClipboard()', [StringComparison]::Ordinal) -le $initializerReread) {
        throw 'The empty Clipboard initializer is not one atomic read-check-empty-reread operation.'
    }
    $clipboardCopyFunction = @($acceptanceAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Copy-GuiRegressionDocument'
    }, $true))
    if ($clipboardCopyFunction.Count -ne 1 -or
        $clipboardCopyFunction[0].Extent.Text.IndexOf(
            'ReadOrInitializeEmptyClipboardSnapshot',
            [StringComparison]::Ordinal
        ) -lt 0 -or
        $clipboardCopyFunction[0].Extent.Text.IndexOf(
            '::EmptyClipboard(',
            [StringComparison]::Ordinal
        ) -ge 0) {
        throw 'GUI document copy must use only the guarded native empty Clipboard initializer.'
    }
    $clipboardCopyText = $clipboardCopyFunction[0].Extent.Text
    foreach ($extendedChord in @(
        '-Modifier 0x11 -VirtualKey 0x24 -Label "$Label selection start" -ExtendedKey',
        '-SecondModifier 0x10 -VirtualKey 0x23 -Label "$Label select to end" -ExtendedKey'
    )) {
        if ($clipboardCopyText.IndexOf($extendedChord, [StringComparison]::Ordinal) -lt 0) {
            throw "GUI document selection does not use an extended navigation key: $extendedChord"
        }
    }
    foreach ($detailsScroll in @(
        '-VirtualKey 0x23 -Label "$Prefix Ctrl+End" -ExtendedKey',
        "-VirtualKey 0x23 -Label 'context full-details Ctrl+End' -ExtendedKey"
    )) {
        if ($acceptanceText.IndexOf($detailsScroll, [StringComparison]::Ordinal) -lt 0) {
            throw "Read-only details scrolling does not use an extended End key: $detailsScroll"
        }
    }
    if ($clipboardCopyText.IndexOf(
            '-VirtualKey 0x43 -Label "$Label Ctrl+C" -ExtendedKey',
            [StringComparison]::Ordinal
        ) -ge 0) {
        throw 'GUI document copy incorrectly marks the letter C as an extended key.'
    }
    $nativeTapExtended = $acceptanceText.IndexOf(
        'public static void TapExtended(ushort virtualKey)',
        [StringComparison]::Ordinal
    )
    if ($nativeTapExtended -lt 0 -or
        $acceptanceText.IndexOf('Send(virtualKey, 0, 1);', $nativeTapExtended,
            [StringComparison]::Ordinal) -lt 0 -or
        $acceptanceText.IndexOf('Send(virtualKey, 0, 3);', $nativeTapExtended,
            [StringComparison]::Ordinal) -lt 0) {
        throw 'Extended navigation input does not emit KEYEVENTF_EXTENDEDKEY on key down and key up.'
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
    $runIdValidationIndex = $controllerText.IndexOf(
        'Assert-SafeAcceptanceRunId -RunId $acceptanceInput.run_id',
        [StringComparison]::Ordinal
    )
    $sessionCreationIndex = $controllerText.IndexOf(
        '$session = New-SshControllerSession',
        [StringComparison]::Ordinal
    )
    if ($runIdValidationIndex -lt 0 -or $sessionCreationIndex -le $runIdValidationIndex) {
        throw 'Acceptance run_id validation must fail before any VM session is created.'
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
    Assert-GuiRegressionInvocationBinding `
        -ManifestInput $candidateRegressionInput `
        -Verified $candidateRegressionResolved `
        -RegressionMode text-scale `
        -Appearance light `
        -TextScalePercent 150 `
        -ExpectedScriptSha256 $candidateManifest.harness.observers.ui.sha256
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
    & $valid.acceptance `
        -BundleRoot $valid.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $valid.output_root `
        -ExpectedScriptSha256 $valid.acceptance_sha256 `
        -HighContrast `
        -ValidateOnly
    & $valid.acceptance `
        -BundleRoot $valid.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $valid.output_root `
        -ExpectedScriptSha256 $valid.acceptance_sha256 `
        -Appearance dark `
        -CaptureNativeMenu `
        -CaptureAdvancedAppearance `
        -ValidateOnly
    & $valid.acceptance `
        -BundleRoot $valid.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $valid.output_root `
        -ExpectedScriptSha256 $valid.acceptance_sha256 `
        -Clipboard `
        -ValidateOnly
    Assert-Fails {
        & $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 $valid.acceptance_sha256 `
            -Appearance dark `
            -HighContrast `
            -ValidateOnly
    } 'High Contrast acceptance uses Forced Colors'
    Assert-Fails {
        & $valid.acceptance `
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
            & $valid.acceptance `
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
        & $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 $valid.acceptance_sha256 `
            -Clipboard `
            -RestoreHighContrastOnly `
            -ValidateOnly
    } 'High Contrast rescue does not accept Clipboard acceptance'
    & $valid.acceptance `
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
        & $valid.acceptance `
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
        & $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 ('0' * 64) `
            -ValidateOnly
    } 'Acceptance script hash mismatch'

    Assert-Fails {
        & $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot (Join-Path $valid.task_root 'different-output') `
            -ExpectedScriptSha256 $valid.acceptance_sha256 `
            -ValidateOnly
    } 'task bundle out directory'

    Assert-Fails {
        & $acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 (Get-Sha256 $acceptance) `
            -ValidateOnly
    } 'task-bundled acceptance artifact'

    $dirty = New-AcceptanceFixture -Name 'dirty' -SourceState 'dirty'
    Assert-Fails { Invoke-ValidateOnly $dirty } 'clean source-bound bundle'

    $changedRunner = New-AcceptanceFixture -Name 'changed-runner'
    [IO.File]::AppendAllText($changedRunner.runner, "`n# changed")
    Assert-Fails { Invoke-ValidateOnly $changedRunner } 'Windows VM helper hash mismatch'

    $occupiedOutput = New-AcceptanceFixture -Name 'occupied-output'
    [void](New-Item -ItemType Directory -Path $occupiedOutput.output_root)
    Assert-Fails { Invoke-ValidateOnly $occupiedOutput } 'already exists'

    Write-Host 'Windows VM current-DPI acceptance contract tests passed.'
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

# Every observer call must satisfy the shared capture contract, including modes
# not exercised by portable execution. This caught a real pre-capture VM failure.
$captureAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'windows-vm-acceptance.ps1'), [ref]$null, [ref]$null)
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
