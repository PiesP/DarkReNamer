function Get-VmAutomatedAppearance {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession
    )

    Assert-AutomationBinding -Element $Window -Process $Process `
        -ExpectedSession $ExpectedSession -Label 'raw appearance menu' -RequireWindowHandle
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    $menu = @(
        foreach ($command in @(0x9010, 0x9011, 0x9012)) {
            [ordered]@{
                command_id = [int]$command
                checked = [bool][DarkReNamerVmAcceptanceNative]::IsMenuCommandChecked($handle, [uint32]$command)
            }
        }
    )
    [ordered]@{
        hwnd = [long]$handle
        pid = [int]$Process.Id
        session_id = [int]$Process.SessionId
        menu_checked = $menu
    }
}
function New-VmAutomatedLayoutRun {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $ApplicationPath,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][ValidateSet('command-rails','native-menu-only')][string] $LayoutVariant
    )

    $mainHandle = [long]$Application.main_handle
    $controls = [Collections.Generic.List[object]]::new()
    $controls.Add((Get-VmAutomatedControlObservation `
        -Element $Application.main -Process $Application.process `
        -ExpectedSession $ExpectedSession -Label 'raw layout main workbench'))
    $controls.Add((Get-VmAutomatedControlObservation `
        -Element $Grid.element -Process $Application.process `
        -ExpectedSession $ExpectedSession -Label 'raw layout file list'))
    if ($LayoutVariant -ceq 'command-rails') {
        foreach ($railId in @(
            '32771','32772','32773','32774','32775','32776','32777','32778','32779','32780',
            '32781','32783','65535','32784','32788','32789','32790','32785','32786'
        )) {
            $rail = Find-UniqueAutomationElement `
                -Root $Application.main -Process $Application.process -ExpectedSession $ExpectedSession `
                -AutomationId $railId -ControlType ([Windows.Automation.ControlType]::Button) `
                -TimeoutSeconds $TimeoutSeconds -Label "raw layout command rail $railId" `
                -RequireWindowHandle
            $controls.Add((Get-VmAutomatedControlObservation `
                -Element $rail -Process $Application.process -ExpectedSession $ExpectedSession `
                -Label "raw layout command rail $railId"))
        }
    }
    else {
        $Grid.element.SetFocus()
        [void][DarkReNamerVmNative]::SetForegroundWindow(
            [IntPtr]$Application.main_handle
        )
        Assert-AcceptanceForegroundBinding `
            -Process $Application.process -ExpectedSession $ExpectedSession `
            -MainWindowHandle ([IntPtr]$Application.main_handle) -RequireMainWindow
    }
    $focused = Get-FocusedAcceptanceElement `
        -Process $Application.process -ExpectedSession $ExpectedSession -Label 'raw layout focus'
    $focusObservation = Get-VmAutomatedControlObservation `
        -Element $focused -Process $Application.process `
        -ExpectedSession $ExpectedSession -Label 'raw layout focused control'
    $misbound = @($controls | Where-Object {
        $_.pid -ne $Application.process.Id -or $_.session_id -ne $ExpectedSession -or
        $_.root_hwnd -ne $mainHandle
    })
    if ($misbound.Count -ne 0 -or $focusObservation.pid -ne $Application.process.Id -or
        $focusObservation.session_id -ne $ExpectedSession -or
        $focusObservation.root_hwnd -ne $mainHandle) {
        throw 'Raw layout control or focus ownership differs from the candidate workbench.'
    }
    $focusReachability = $null
    $nativeMenuOnly = $null
    if ($LayoutVariant -ceq 'command-rails') {
        $focusReachability = Invoke-VmAutomatedFocusReachability `
            -Application $Application -List $Grid.element -FixtureRoot $FixtureRoot `
            -ExpectedSession $ExpectedSession -TimeoutSeconds $TimeoutSeconds
    }
    else {
        $menuTree = @(Get-VmAutomatedNativeMenuTree `
            -MainWindowHandle ([IntPtr]$Application.main.Current.NativeWindowHandle)
        )
        [void](Assert-VmAutomatedNativeMenuTree -MenuTree $menuTree)
        $hiddenRails = @(Get-VmAutomatedHiddenRailControls `
            -Application $Application -ExpectedSession $ExpectedSession -MenuTree $menuTree)
        if ($hiddenRails.Count -ne 19) {
            throw 'Native menu-only layout did not retain all nineteen hidden rail HWNDs.'
        }
        $reachability = Invoke-VmAutomatedNativeMenuOnlyReachability `
            -Application $Application -List $Grid.element -FixtureRoot $FixtureRoot `
            -ExpectedSession $ExpectedSession -MenuTree $menuTree
        $nativeMenuOnly = [ordered]@{
            schema_version = 1
            variant = 'native-menu-only'
            hidden_rail_controls = $hiddenRails
            menu_tree = $menuTree
            initial = $reachability.initial
            events = $reachability.events
            final = $reachability.final
            state_before = $reachability.state_before
            state_after = $reachability.state_after
        }
    }
    $Application.process.Refresh()
    $layoutObservations = if ($LayoutVariant -ceq 'command-rails') {
        [ordered]@{
            controls = $controls.ToArray()
            focus = @($focusObservation)
            focus_reachability = $focusReachability
            screenshots = @()
        }
    }
    else {
        [ordered]@{
            controls = $controls.ToArray()
            focus = @($focusObservation)
            native_menu_only = $nativeMenuOnly
            screenshots = @()
        }
    }
    [ordered]@{
        raw_appearance = Get-VmAutomatedAppearance -Window $Application.main `
            -Process $Application.process -ExpectedSession $ExpectedSession
        raw_environment = Get-VmAutomatedEnvironment `
            -Process $Application.process `
            -WindowHandle ([IntPtr]$Application.main.Current.NativeWindowHandle) `
            -FixtureRoot $FixtureRoot
        process_lifecycle = [ordered]@{
            pid = [int]$Application.process.Id
            session_id = [int]$Application.process.SessionId
            start_time_utc_ticks = $Application.process.StartTime.ToUniversalTime().Ticks.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            executable_path = $ApplicationPath
            executable_sha256 = Get-LowerSha256 -Path $ApplicationPath
            start_observed = $true
            exit_observed = $false
            exit_method = $null
            exit_code = $null
        }
        layout_observations = $layoutObservations
    }
}
function Complete-VmAutomatedLayoutRun {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Run,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExitCode,
        [Parameter(Mandatory)][object[]] $Screenshots
    )

    $Process.Refresh()
    if (-not $Process.HasExited -or $ExitCode -ne 0 -or $Process.ExitCode -ne $ExitCode) {
        throw 'Raw layout application lifecycle did not observe a normal zero exit.'
    }
    $Run.process_lifecycle.exit_observed = $true
    $Run.process_lifecycle.exit_method = 'normal-close'
    $Run.process_lifecycle.exit_code = $ExitCode
    $Run.layout_observations.screenshots = @($Screenshots)
}

function Invoke-DrCurrentDpiAcceptanceScenario {
$null = Resolve-VerifiedBundle -Root $bootstrap.root -InvokedScriptPath $bootstrap.runner
$verified = Resolve-AcceptanceBundle `
    -Root $BundleRoot `
    -ScriptPath $EntryPointPath `
    -ScriptSha256 $ExpectedScriptSha256 `
    -RequestedOutputRoot $OutputRoot `
    -SessionId $ExpectedSessionId `
    -AllowExistingOutput:$RestoreHighContrastOnly
if ($HighContrast -and $Appearance -cne 'system') {
    throw 'High Contrast acceptance uses Forced Colors and requires the system appearance input.'
}
if ($HighContrast -and $CaptureAdvancedAppearance) {
    throw 'Advanced appearance capture is unavailable during Forced Colors acceptance.'
}
if ($RestoreHighContrastOnly -and
    ($Appearance -cne 'system' -or $CaptureNativeMenu -or $CaptureAdvancedAppearance)) {
    throw 'High Contrast rescue does not accept appearance or visual-surface controls.'
}
if ($RestoreHighContrastOnly -and $Clipboard) {
    throw 'High Contrast rescue does not accept Clipboard acceptance.'
}
if ($ValidateOnly) {
    if ($RestoreHighContrastOnly) {
        [void](Resolve-HighContrastRestoreDocument `
            -OutputDirectory $verified.output_root `
            -SourceSha $verified.source_sha `
            -ScriptSha256 $verified.script_sha256)
    }
    Write-Host "Validated current-DPI acceptance bundle for source $($verified.source_sha)."
    return
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Current-DPI acceptance requires Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Current-DPI acceptance must run non-elevated.'
}
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($currentSession -ne $ExpectedSessionId) {
    throw 'Current-DPI acceptance is running in an unexpected desktop session.'
}
if ($RestoreHighContrastOnly) {
    Invoke-HighContrastRescue -Verified $verified -SessionId $ExpectedSessionId
    return
}

[void](New-Item -ItemType Directory -Path $verified.output_root)
$runtimeRoot = New-PrivateDirectory -Parent $verified.output_root -Leaf 'runtime'
$resultPath = Join-Path $verified.output_root 'acceptance-result.json'
$observationPath = Join-Path $verified.output_root 'acceptance-observations.json'
$diagnosticPath = Join-Path $verified.output_root 'acceptance-error.txt'
$processState = [pscustomobject]@{ process = $null }
$desktopLock = $null
$previousExecutionState = $null
$runtimeCleanup = $false
$lifecycle = [pscustomobject]@{ process_terminated = $true }
$highContrastState = [pscustomobject]@{
    requested = [bool]$HighContrast
    changed = $false
    original = $null
    acceptance = $null
    restored = $null
    rescue_path = $null
    restoration_verified = $false
}
$clipboardState = [pscustomobject]@{
    owned = $false
    checks_complete = $false
    expected_sequence = [uint32]0
    expected_text = $null
}
$captures = [Collections.Generic.List[object]]::new()
$rawCandidate = $verified.lane -ceq 'candidate-gui-only'
$rawCheckpoints = [Collections.Generic.List[object]]::new()
$keyboardEvents = [Collections.Generic.List[object]]::new()
$rawControls = [Collections.Generic.List[object]]::new()
$rawFocusReachability = $null
$keyboard = [ordered]@{
    status = 'failed'
    reset_name_enabled_after_prefix = $false
    reset_name_native_enabled_after_prefix = $false
    reset_name_menu_enabled_after_prefix = $false
    reset_name_selection_pattern_available = $false
    reset_name_selection_count_after_prefix = $null
    reset_name_proposal_only = $false
    reset_name_displayed_parent_unchanged = $false
    reset_name_disabled_after_reset = $false
    cancellation_unchanged = $false
    confirmed_disk_rename = $false
    content_preserved = $false
    identity_preserved = $false
    journal_residue_count = $null
}
$accessibility = [ordered]@{ status = 'failed'; rail_button_count = 0 }
$capture = [ordered]@{ status = 'failed'; screenshot_count = 0; visual_review = 'required' }
$highContrastResult = [ordered]@{
    requested = [bool]$HighContrast
    original_enabled = $null
    acceptance_enabled = $null
    system_colors_changed = $null
    restoration = if ($HighContrast) { 'pending' } else { 'not_required' }
    snapshot = $null
}
$clipboardResult = if ($Clipboard) {
    [ordered]@{
        status = 'failed'
        reason = 'Clipboard acceptance did not complete.'
        preflight_empty = $false
        names = $null
        paths = $null
        cleanup = 'not_required'
    }
}
else {
    [ordered]@{
        status = 'not_run'
        reason = 'Clipboard acceptance was not requested.'
    }
}
$observations = [ordered]@{
        foreground_activation = $script:acceptanceForegroundObservations
    schema_version = 1
    environment = $null
    main_window = $null
    list = $null
    rail_buttons = @()
    file_dialog = $null
    prefix_prompt = $null
    native_menu = $null
    advanced_appearance = $null
    name_reset = $null
    apply_confirmation = $null
}
$result = [ordered]@{
    schema_version = if ($verified.lane -ceq 'candidate-gui-only') { 2 } else { 1 }
    target = $verified.target
    application = [ordered]@{
        file = $verified.application.file
        sha256 = $verified.application.sha256
    }
}
if ($verified.lane -ceq 'candidate-gui-only') {
    $result['lane'] = $verified.lane
    $result['product'] = $verified.product
    $result['harness'] = $verified.harness
    $result['observer_role'] = 'ui'
    $result['raw_environment'] = $null
    $result['raw_checkpoints'] = @()
    $result['keyboard_events'] = @()
    $result['process_lifecycle'] = $null
    $result['raw_cleanup'] = $null
    $result['raw_appearance'] = $null
    $result['layout_observations'] = $null
}
else {
    $result['source_sha'] = $verified.source_sha
}
$result['runner_sha256'] = $verified.runner_sha256
$result['acceptance_script_sha256'] = $verified.script_sha256
$result['appearance'] = [ordered]@{
    requested = $Appearance
    observed = $null
}
$result['status'] = 'failed'
$result['visual_review'] = 'required'
$result['keyboard'] = $keyboard
$result['accessibility'] = $accessibility
$result['capture'] = $capture
$result['clipboard'] = $clipboardResult
$result['high_contrast'] = $highContrastResult
$result['observations'] = $null
$result['screenshots'] = @()
$result['guest_cleanup'] = $false
$result['failure_reason'] = 'setup_failed'
$result['diagnostic'] = $null

try {
    $desktopLock = Enter-DesktopTestLock -SessionId $currentSession
    if ($null -eq $desktopLock) {
        throw 'Another Windows VM test runner is using this interactive desktop.'
    }
    $previousExecutionState = Enter-TestExecutionState
    Initialize-NativeCapture
    Initialize-AcceptanceNative
    if (-not [DarkReNamerVmNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
        throw 'Windows refused the per-monitor-v2 acceptance DPI context.'
    }
    $highContrastState.original = [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot()
    $highContrastResult.original_enabled = ($highContrastState.original.Flags -band 1) -ne 0
    if ($HighContrast) {
        $highContrastState.rescue_path = Join-Path $verified.output_root 'high-contrast-restore.json'
        Write-JsonUtf8Bom -Path $highContrastState.rescue_path -Value ([ordered]@{
            schema_version = 2
            source_sha = $verified.source_sha
            acceptance_script_sha256 = $verified.script_sha256
            restoration_required = $true
            original = ConvertTo-HighContrastDocumentSnapshot -Snapshot $highContrastState.original
            restoration_verified = $false
            restored = $null
        })
        if (-not $highContrastResult.original_enabled) {
            $highContrastState.changed = $true
            [DarkReNamerVmAcceptanceNative]::ApplyHighContrast(
                (($highContrastState.original.Flags -bor 1) -band (-bnot 0x1000)),
                $highContrastState.original.Scheme
            )
        }
        $highContrastState.acceptance = Wait-HighContrastSettlement `
            -ReadSnapshot { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
            -AcceptSnapshot {
                param($candidate)
                $enabled = ($candidate.Flags -band 1) -ne 0
                $colorsChanged = -not (Test-HighContrastColorsEqual `
                    -Expected $highContrastState.original `
                    -Actual $candidate)
                $enabled -and ($highContrastResult.original_enabled -or $colorsChanged)
            } `
            -Label 'High Contrast activation'
        $highContrastResult.acceptance_enabled = ($highContrastState.acceptance.Flags -band 1) -ne 0
        if (-not $highContrastResult.acceptance_enabled) {
            throw 'Windows did not enable High Contrast for the acceptance session.'
        }
        $highContrastResult.system_colors_changed = -not (Test-HighContrastColorsEqual `
            -Expected $highContrastState.original `
            -Actual $highContrastState.acceptance)
    }
    else {
        $highContrastState.acceptance = $highContrastState.original
        $highContrastResult.acceptance_enabled = $highContrastResult.original_enabled
        $highContrastResult.system_colors_changed = $false
    }
    $capturePrefix = if ($HighContrast) {
        'high-contrast'
    }
    elseif ($Appearance -ceq 'system') {
        'current-dpi'
    }
    else {
        "current-dpi-$Appearance"
    }

    Invoke-WithIsolatedEnvironment -RuntimeRoot $runtimeRoot -Action {
        $caseRoot = New-PrivateDirectory -Parent $runtimeRoot -Leaf 'keyboard-flow'
        $fixtureRoot = New-PrivateDirectory -Parent $caseRoot -Leaf 'fixture'
        $sourceName = 'acceptance-source.txt'
        $prefix = 'accepted-'
        $destinationName = $prefix + $sourceName
        $sourcePath = Join-Path $fixtureRoot $sourceName
        $destinationPath = Join-Path $fixtureRoot $destinationName
        [IO.File]::WriteAllText(
            $sourcePath,
            "Current-DPI keyboard acceptance fixture`n",
            [Text.UTF8Encoding]::new($false)
        )
        $beforeContent = Get-LowerSha256 -Path $sourcePath
        $beforeIdentity = [DarkReNamerVmNative]::GetFileIdentity($sourcePath)

        $applicationPath = Join-Path $verified.root $verified.application.file
        Assert-OrdinaryFile -Path $applicationPath -Label 'acceptance application'
        if ((Get-LowerSha256 -Path $applicationPath) -cne $verified.application.sha256) {
            throw 'Acceptance application changed after bundle verification.'
        }
        $application = Start-AcceptanceApplication `
            -FilePath $applicationPath `
            -WorkingDirectory $verified.root `
            -SessionId $ExpectedSessionId `
            -WaitSeconds $TimeoutSeconds `
            -Label 'current-DPI acceptance application'
        $processState.process = $application.owned
        $lifecycle.process_terminated = $false
        $process = $application.process
        $mainWindow = $application.main
        $mainHandle = [IntPtr]$application.main_handle
        if ($rawCandidate) {
            $process.Refresh()
            $result.process_lifecycle = [ordered]@{
                pid = [int]$process.Id
                session_id = [int]$process.SessionId
                start_time_utc_ticks = $process.StartTime.ToUniversalTime().Ticks.ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                )
                executable_path = $applicationPath
                executable_sha256 = Get-LowerSha256 -Path $applicationPath
                start_observed = $true
                exit_observed = $false
                exit_method = $null
                exit_code = $null
            }
        }

        $appearanceSpec = if ($HighContrast) {
            [ordered]@{ command_id = $null; evidence_name = 'forced-colors' }
        }
        else {
            Set-AcceptanceAppearance `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -MainWindowHandle $mainHandle `
                -Appearance $Appearance
        }
        $result.appearance.observed = $appearanceSpec.evidence_name
        $captureWindow = Ensure-AcceptanceMainWindowCaptureSize `
            -MainWindow $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId
        if ($rawCandidate) {
            $result.raw_appearance = Get-VmAutomatedAppearance -Window $mainWindow `
                -Process $process -ExpectedSession $ExpectedSessionId
            $result.raw_environment = Get-VmAutomatedEnvironment `
                -Process $process `
                -WindowHandle ([IntPtr]$mainWindow.Current.NativeWindowHandle) `
                -FixtureRoot $fixtureRoot
            $rawControls.Add((Get-VmAutomatedControlObservation `
                -Element $mainWindow -Process $process -ExpectedSession $ExpectedSessionId `
                -Label 'raw main workbench'))
        }

        $observations.environment = [ordered]@{
            main_window = Get-ObserverNativeWindowMetrics -Window $mainWindow
            os_version = [DarkReNamerVmAcceptanceNative]::OsVersion()
            dpi = $captureWindow.dpi
            appearance = $appearanceSpec.evidence_name
            capture_window = $captureWindow
            high_contrast = ($highContrastState.acceptance.Flags -band 1) -ne 0
            high_contrast_flags = $highContrastState.acceptance.Flags
            high_contrast_scheme = $highContrastState.acceptance.Scheme
            high_contrast_colors = [ordered]@{
                window = $highContrastState.acceptance.Window
                window_text = $highContrastState.acceptance.WindowText
                button_face = $highContrastState.acceptance.ButtonFace
                button_text = $highContrastState.acceptance.ButtonText
                highlight = $highContrastState.acceptance.Highlight
                highlight_text = $highContrastState.acceptance.HighlightText
                gray_text = $highContrastState.acceptance.GrayText
                hot_light = $highContrastState.acceptance.HotLight
            }
            ui_automation_client = [Windows.Automation.AutomationElement].Assembly.FullName
            ui_automation_types = [Windows.Automation.AutomationProperty].Assembly.FullName
            ui_automation_providers = [UIAutomationClientsideProviders.UIAutomationClientSideProviders].Assembly.FullName
        }
        $observations.main_window = Get-ElementObservation -Element $mainWindow
        $observations.rail_buttons = Get-RailAccessibilitySnapshot `
            -MainWindow $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -TimeoutSeconds $TimeoutSeconds
        $accessibility.rail_button_count = @($observations.rail_buttons).Count
        $list = Find-UniqueAutomationElement `
            -Root $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -AutomationId '1000' `
            -ControlType ([Windows.Automation.ControlType]::DataGrid) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'acceptance file list' `
            -RequireWindowHandle
        $gridPattern = $null
        if (-not $list.TryGetCurrentPattern([Windows.Automation.GridPattern]::Pattern, [ref]$gridPattern)) {
            throw 'The production file list does not expose GridPattern.'
        }
        $observations.list = Get-ElementObservation -Element $list
        if ($rawCandidate) {
            $rawControls.Add((Get-VmAutomatedControlObservation `
                -Element $list -Process $process -ExpectedSession $ExpectedSessionId `
                -Label 'raw file list'))
            foreach ($railId in @(
                '32771','32772','32773','32774','32775','32776','32777','32778','32779','32780',
                '32781','32783','65535','32784','32788','32789','32790','32785','32786'
            )) {
                $rawRail = Find-UniqueAutomationElement `
                    -Root $mainWindow -Process $process -ExpectedSession $ExpectedSessionId `
                    -AutomationId $railId -ControlType ([Windows.Automation.ControlType]::Button) `
                    -TimeoutSeconds $TimeoutSeconds -Label "raw command rail button $railId" `
                    -RequireWindowHandle
                $rawControls.Add((Get-VmAutomatedControlObservation `
                    -Element $rawRail -Process $process -ExpectedSession $ExpectedSessionId `
                    -Label "raw command rail button $railId"))
            }
        }
        $accessibility.status = 'passed'
        $initialCapture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
            -Window $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf ($capturePrefix + '-initial.png') `
            -Label 'current-DPI initial workbench'
        $captures.Add((Add-AcceptanceScreenshotContext `
            -Screenshot $initialCapture `
            -Appearance $appearanceSpec.evidence_name `
            -Surface 'main-workbench'))

        if ($CaptureNativeMenu) {
            $result.failure_reason = 'native_menu_capture_failed'
            Send-AcceptanceChord `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Modifier 0x12 `
                -VirtualKey 0x56 `
                -Label 'native View menu accelerator'
            $popup = Wait-AcceptancePopupMenu `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Label 'native View menu'
            $nativeMenuCapture = Save-AcceptanceNativeMenuScreenshot `
                -MainWindow $mainWindow `
                -Popup $popup `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Root $verified.output_root `
                -Leaf ($capturePrefix + '-native-menu.png') `
                -Label 'current-DPI native View menu'
            $captures.Add((Add-AcceptanceScreenshotContext `
                -Screenshot $nativeMenuCapture `
                -Appearance $appearanceSpec.evidence_name `
                -Surface 'native-menu'))
            $observations.native_menu = [ordered]@{
                captured = $true
                appearance = $appearanceSpec.evidence_name
            }
            Send-AcceptanceTap `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -VirtualKey 0x1B `
                -Label 'native View menu Escape'
            Wait-AcceptancePopupMenuClosed `
                -Process $process `
                -Label 'native View menu'
        }

        if ($CaptureAdvancedAppearance) {
            $result.failure_reason = 'advanced_appearance_capture_failed'
            [DarkReNamerVmAcceptanceNative]::SendMenuCommand(
                $mainHandle,
                [uint32]0x9013
            )
            $appearanceDialog = Wait-UniqueAutomationWindow `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -MainWindowHandle $mainHandle `
                -Name 'DarkReNamer - 모양 설정 (미리보기)' `
                -TimeoutSeconds $TimeoutSeconds `
                -Label 'advanced appearance window'
            $appearanceDialogHandle = [IntPtr]$appearanceDialog.Current.NativeWindowHandle
            $observations.advanced_appearance = [ordered]@{
                window = Get-ElementObservation -Element $appearanceDialog
                appearance = $appearanceSpec.evidence_name
            }
            $advancedAppearanceCapture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
                -Window $appearanceDialog `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Root $verified.output_root `
                -Leaf ($capturePrefix + '-advanced-appearance.png') `
                -Label 'current-DPI advanced appearance window'
            $captures.Add((Add-AcceptanceScreenshotContext `
                -Screenshot $advancedAppearanceCapture `
                -Appearance $appearanceSpec.evidence_name `
                -Surface 'advanced-appearance'))
            Send-AcceptanceTap `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -VirtualKey 0x1B `
                -Label 'advanced appearance Escape'
            Wait-WindowClosed `
                -Handle $appearanceDialogHandle `
                -TimeoutSeconds $TimeoutSeconds `
                -Label 'advanced appearance window'
            $mainWindow.SetFocus()
            [void][DarkReNamerVmNative]::SetForegroundWindow($mainHandle)
            $advancedReturnDeadline = (Get-Date).AddSeconds(2)
            while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle -and
                (Get-Date) -lt $advancedReturnDeadline) {
                Start-Sleep -Milliseconds 50
            }
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle) {
                throw 'The application did not regain foreground after advanced appearance capture.'
            }
        }

        $result.failure_reason = 'file_dialog_failed'
        Send-AcceptanceChord `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Modifier 0x11 `
            -VirtualKey 0x4F `
            -Label 'Ctrl+O file-add accelerator'
        $fileDialog = Wait-UniqueAutomationWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -MainWindowHandle $mainHandle `
            -Name '이름 붙일 파일 불러오기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'keyboard file dialog'
        $fileName = Find-UniqueAutomationElement `
            -Root $fileDialog `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -AutomationId '1148' `
            -ControlType ([Windows.Automation.ControlType]::Edit) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'keyboard filename field'
        $nativeOpen = Resolve-AcceptanceNativeOpen `
            -Dialog $fileDialog `
            -Process $process `
            -ExpectedSession $ExpectedSessionId
        $open = $nativeOpen.Element
        $openHandle = $nativeOpen.Handle
        $observations.file_dialog = [ordered]@{
            window = Get-ElementObservation -Element $fileDialog
            filename = Get-ElementObservation -Element $fileName
            open = Get-ElementObservation -Element $open
            dialog_native_handle = ([IntPtr]$fileDialog.Current.NativeWindowHandle).ToInt64()
            open_native_handle = $nativeOpen.Handle.ToInt64()
            open_native_class = $nativeOpen.ClassName
            open_native_control_id = 1
            open_native_process_id = $nativeOpen.ProcessId
            open_native_thread_id = $nativeOpen.ThreadId
            dialog_native_bounds = $nativeOpen.DialogBounds
            open_native_bounds = $nativeOpen.ControlBounds
        }
        $commonDialogCapture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
            -Window $fileDialog `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf ($capturePrefix + '-common-dialog.png') `
            -Label 'current-DPI common file dialog'
        $captures.Add((Add-AcceptanceScreenshotContext `
            -Screenshot $commonDialogCapture `
            -Appearance $appearanceSpec.evidence_name `
            -Surface 'common-dialog'))
        $fileName.SetFocus()
        Send-AcceptanceChord -Process $process -ExpectedSession $ExpectedSessionId -Modifier 0x11 -VirtualKey 0x41 -Label 'filename select-all'
        Send-AcceptanceText -Process $process -ExpectedSession $ExpectedSessionId -Value $sourcePath -Label 'filename keyboard input'
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'file dialog Enter'
        Wait-ListPreviewName `
            -MainWindow $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -ExpectedName $sourceName `
            -TimeoutSeconds $TimeoutSeconds
        if ($rawCandidate) {
            $rawFocusReachability = Invoke-VmAutomatedFocusReachability `
                -Application $application -List $list -FixtureRoot $fixtureRoot `
                -ExpectedSession $ExpectedSessionId -TimeoutSeconds $TimeoutSeconds
        }

        $result.failure_reason = 'prefix_keyboard_failed'
        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32773')
        $prefixActivationAttempt = Get-AcceptanceCommandActivationAttempt `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -ExpectedAutomationId '32773'
        $observations['prefix_activation_attempt'] = $prefixActivationAttempt
        Assert-AcceptanceCommandActivationBinding `
            -Attempt $prefixActivationAttempt `
            -ExpectedProcessId $process.Id `
            -ExpectedSession $ExpectedSessionId `
            -ExpectedMainWindow ([long]$mainWindow.Current.NativeWindowHandle) `
            -ExpectedAutomationId '32773'
        [DarkReNamerVmAcceptanceNative]::Tap(0x20)
        $prefixActivationAttempt.input_sent = $true
        $prompt = Wait-AcceptanceOwnedInputWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Owner $mainWindow `
            -Name '이름 앞에 문자열 붙이기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'keyboard prefix prompt'
        [void]$observations.Remove('prefix_activation_attempt')
        $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
        $promptEdit = Find-UniqueAutomationElement -Root $prompt -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1004' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $TimeoutSeconds -Label 'prefix prompt edit' -RequireWindowHandle
        $promptOk = Find-UniqueAutomationElement -Root $prompt -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $TimeoutSeconds -Label 'prefix prompt OK' -RequireWindowHandle
        if ($promptEdit.Current.Name -cne '붙일 문자열') {
            throw "The prefix Edit accessible name is '$($promptEdit.Current.Name)', expected '붙일 문자열'."
        }
        $observations.prefix_prompt = [ordered]@{
            window = Get-ElementObservation -Element $prompt
            edit = Get-ElementObservation -Element $promptEdit
            ok = Get-ElementObservation -Element $promptOk
        }
        $inputPromptCapture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
            -Window $prompt `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf ($capturePrefix + '-input-prompt.png') `
            -Label 'current-DPI input prompt'
        $captures.Add((Add-AcceptanceScreenshotContext `
            -Screenshot $inputPromptCapture `
            -Appearance $appearanceSpec.evidence_name `
            -Surface 'input-prompt'))
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1004')
        Send-AcceptanceText -Process $process -ExpectedSession $ExpectedSessionId -Value $prefix -Label 'prefix keyboard input'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'prefix prompt Enter'
        Wait-WindowClosed `
            -Handle $promptHandle `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt'
        $selectionPatternObject = $null
        if ($list.TryGetCurrentPattern(
            [Windows.Automation.SelectionPattern]::Pattern,
            [ref]$selectionPatternObject
        )) {
            $keyboard.reset_name_selection_pattern_available = $true
            $selectionPattern = [Windows.Automation.SelectionPattern]$selectionPatternObject
            $keyboard.reset_name_selection_count_after_prefix =
                @($selectionPattern.Current.GetSelection()).Count
            if ($keyboard.reset_name_selection_count_after_prefix -ne 0) {
                throw 'The no-selection name reset scenario acquired a list selection after prefix.'
            }
        }
        else {
            throw 'The production file list does not expose SelectionPattern for the no-selection reset observation.'
        }
        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $destinationName -TimeoutSeconds $TimeoutSeconds

        if ($rawCandidate) {
            $rawCheckpoints.Add((Get-VmAutomatedCheckpoint `
                -Phase initial -FixtureRoot $fixtureRoot -LocalAppData $env:LOCALAPPDATA))
        }
        if ($Clipboard) {
            $result.failure_reason = 'clipboard_preflight_failed'
            $clipboardPreflight = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
            if (@($clipboardPreflight.Formats).Count -ne 0 -or
                $null -ne $clipboardPreflight.UnicodeText) {
                throw 'Clipboard acceptance requires an initially empty Clipboard and will not clear existing data.'
            }
            $clipboardResult.preflight_empty = $true
            $expectedNames = $destinationName + "`r`n"
            $expectedPaths = $sourcePath + "`r`n"

            $result.failure_reason = 'clipboard_names_failed'
            Assert-AcceptanceForegroundBinding `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -MainWindowHandle $mainHandle `
                -RequireMainWindow
            if (-not [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                $mainHandle,
                [uint32]0x8018
            )) {
                throw 'The native Copy Names menu command is not enabled for the known row.'
            }
            Send-AcceptanceChord `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Modifier 0x12 `
                -VirtualKey 0x46 `
                -Label 'Clipboard native File menu accelerator'
            [void](Wait-AcceptancePopupMenu `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Label 'Clipboard native File menu')
            Send-AcceptanceTap `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -VirtualKey 0x58 `
                -Label 'Clipboard Export submenu mnemonic'
            $copyNamesItem = Find-AcceptanceMenuItem `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Name '변경 후 이름 목록 복사' `
                -TimeoutSeconds $TimeoutSeconds
            Assert-AcceptanceForegroundBinding `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -MainWindowHandle $mainHandle
            $clipboardBeforeNames = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
            if ($clipboardBeforeNames.SequenceNumber -ne $clipboardPreflight.SequenceNumber -or
                @($clipboardBeforeNames.Formats).Count -ne 0 -or
                $null -ne $clipboardBeforeNames.UnicodeText) {
                throw 'Clipboard changed before Copy Names; preserving it without invoking the menu item.'
            }
            $invokePatternObject = $null
            if (-not $copyNamesItem.TryGetCurrentPattern(
                [Windows.Automation.InvokePattern]::Pattern,
                [ref]$invokePatternObject
            )) {
                throw 'The native Copy Names menu item does not expose InvokePattern.'
            }
            ([Windows.Automation.InvokePattern]$invokePatternObject).Invoke()
            Wait-AcceptancePopupMenuClosed -Process $process -Label 'Clipboard native File menu'
            $namesSnapshot = Wait-AcceptanceClipboardText `
                -PreviousSequence $clipboardPreflight.SequenceNumber `
                -ExpectedText $expectedNames `
                -TimeoutSeconds $TimeoutSeconds `
                -Label 'Copy Names menu command'
            $clipboardState.owned = $true
            $clipboardState.expected_sequence = $namesSnapshot.SequenceNumber
            $clipboardState.expected_text = $expectedNames
            $clipboardResult.names = Get-AcceptanceClipboardTextEvidence -Text $namesSnapshot.UnicodeText

            $result.failure_reason = 'clipboard_paths_failed'
            $mainWindow.SetFocus()
            [void][DarkReNamerVmNative]::SetForegroundWindow($mainHandle)
            $clipboardForegroundDeadline = (Get-Date).AddSeconds(2)
            while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle -and
                (Get-Date) -lt $clipboardForegroundDeadline) {
                Start-Sleep -Milliseconds 50
            }
            Assert-AcceptanceForegroundBinding `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -MainWindowHandle $mainHandle `
                -RequireMainWindow
            if (-not [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                $mainHandle,
                [uint32]0x801A
            )) {
                throw 'The native Copy Paths menu command is not enabled for the known row.'
            }
            $beforePaths = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
            if (-not (Test-AcceptanceClipboardSnapshotOwned `
                -Snapshot $beforePaths `
                -ExpectedSequence $clipboardState.expected_sequence `
                -ExpectedText $clipboardState.expected_text)) {
                throw 'Clipboard changed before Copy Paths; preserving it without invoking the shortcut.'
            }
            Send-AcceptanceTwoModifierChord -Process $process -ExpectedSession $ExpectedSessionId -Modifier 0x11 -SecondModifier 0x10 -VirtualKey 0x43 -Label 'Ctrl+Shift+C Copy Paths shortcut'
            $pathsSnapshot = Wait-AcceptanceClipboardText `
                -PreviousSequence $namesSnapshot.SequenceNumber `
                -ExpectedText $expectedPaths `
                -TimeoutSeconds $TimeoutSeconds `
                -Label 'Ctrl+Shift+C Copy Paths shortcut'
            $clipboardState.expected_sequence = $pathsSnapshot.SequenceNumber
            $clipboardState.expected_text = $expectedPaths
            $clipboardState.checks_complete = $true
            $clipboardResult.paths = Get-AcceptanceClipboardTextEvidence -Text $pathsSnapshot.UnicodeText
            $clipboardResult.status = 'pending_cleanup'
            $clipboardResult.reason = $null
            $clipboardResult.cleanup = 'pending'
        }
        $beforeReset = Get-ListPrimarySnapshot -List $list
        $reset = Find-UniqueAutomationElement `
            -Root $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -AutomationId '32781' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'name reset after prefix' `
            -RequireEnabled `
            -RequireWindowHandle
        $keyboard.reset_name_enabled_after_prefix = $reset.Current.IsEnabled
        $keyboard.reset_name_native_enabled_after_prefix =
            [DarkReNamerVmAcceptanceNative]::IsWindowEnabled(
                [IntPtr]$reset.Current.NativeWindowHandle
            )
        $keyboard.reset_name_menu_enabled_after_prefix =
            [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                $mainHandle,
                0x800D
            )
        if (-not $keyboard.reset_name_native_enabled_after_prefix -or
            -not $keyboard.reset_name_menu_enabled_after_prefix) {
            throw 'Name reset did not become enabled in both the native rail and menu after prefix.'
        }
        $observations.name_reset = [ordered]@{
            before = [ordered]@{
                rail = Get-ElementObservation -Element $reset
                native_enabled = $keyboard.reset_name_native_enabled_after_prefix
                menu_enabled = $keyboard.reset_name_menu_enabled_after_prefix
                selection_pattern_available = $keyboard.reset_name_selection_pattern_available
                selected_item_count = $keyboard.reset_name_selection_count_after_prefix
                row = $beforeReset
            }
            after = $null
        }
        $previewCapture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf ($capturePrefix + '-preview.png') -Label 'current-DPI rename preview before name reset'
        $captures.Add((Add-AcceptanceScreenshotContext -Screenshot $previewCapture -Appearance $appearanceSpec.evidence_name -Surface 'main-workbench'))

        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32781')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'name reset Space'
        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $sourceName -TimeoutSeconds $TimeoutSeconds
        $afterReset = Get-ListPrimarySnapshot -List $list
        $resetAfter = Find-UniqueAutomationElement `
            -Root $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -AutomationId '32781' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'name reset after reset' `
            -RequireWindowHandle
        $nativeResetDisabled = -not [DarkReNamerVmAcceptanceNative]::IsWindowEnabled(
            [IntPtr]$resetAfter.Current.NativeWindowHandle
        )
        $menuResetDisabled = -not [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
            $mainHandle,
            0x800D
        )
        $keyboard.reset_name_disabled_after_reset =
            (-not $resetAfter.Current.IsEnabled) -and $nativeResetDisabled -and $menuResetDisabled
        $keyboard.reset_name_displayed_parent_unchanged =
            $beforeReset.destination_parent -ceq $afterReset.destination_parent -and
            $afterReset.destination_parent -ceq $fixtureRoot
        $keyboard.reset_name_proposal_only =
            $afterReset.current_name -ceq $sourceName -and
            $afterReset.proposed_name -ceq $sourceName -and
            (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $destinationPath) -and
            (Get-LowerSha256 -Path $sourcePath) -ceq $beforeContent -and
            [DarkReNamerVmNative]::GetFileIdentity($sourcePath) -ceq $beforeIdentity
        if (-not $keyboard.reset_name_disabled_after_reset -or
            -not $keyboard.reset_name_displayed_parent_unchanged -or
            -not $keyboard.reset_name_proposal_only) {
            throw 'Name reset did not restore only the proposal while leaving the displayed parent and disk state unchanged.'
        }
        $observations.name_reset.after = [ordered]@{
            rail = Get-ElementObservation -Element $resetAfter
            native_enabled = -not $nativeResetDisabled
            menu_enabled = -not $menuResetDisabled
            row = $afterReset
        }
        $resetCapture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf ($capturePrefix + '-preview-after-name-reset.png') -Label 'current-DPI rename preview after name reset'
        $captures.Add((Add-AcceptanceScreenshotContext -Screenshot $resetCapture -Appearance $appearanceSpec.evidence_name -Surface 'main-workbench'))

        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32773')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'second prefix command Space'
        $prompt = Wait-AcceptanceOwnedInputWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Owner $mainWindow `
            -Name '이름 앞에 문자열 붙이기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'second keyboard prefix prompt'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1004')
        Send-AcceptanceText -Process $process -ExpectedSession $ExpectedSessionId -Value $prefix -Label 'second prefix keyboard input'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'second prefix prompt Enter'
        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $destinationName -TimeoutSeconds $TimeoutSeconds

        $result.failure_reason = 'apply_cancellation_failed'
        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32771')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'Apply command Space'
        $confirmation = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $ExpectedSessionId `
            -MainWindowHandle $mainHandle -Name 'DarkReNamer - 안전한 적용 확인' `
            -TimeoutSeconds $TimeoutSeconds -Label 'keyboard Apply confirmation'
        $cancel = Find-UniqueAutomationElement -Root $confirmation -Process $process -ExpectedSession $ExpectedSessionId -AutomationId 'CommandButton_2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $TimeoutSeconds -Label 'Apply cancellation button' -RequireWindowHandle
        $confirm = Find-UniqueAutomationElement -Root $confirmation -Process $process -ExpectedSession $ExpectedSessionId -AutomationId 'CommandLink_1101' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $TimeoutSeconds -Label 'Apply command link' -RequireWindowHandle
        $observations.apply_confirmation = [ordered]@{
            window = Get-ElementObservation -Element $confirmation
            cancel = Get-ElementObservation -Element $cancel
            confirm = Get-ElementObservation -Element $confirm
        }
        $confirmationCapture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $confirmation -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf ($capturePrefix + '-confirmation.png') -Label 'current-DPI Apply confirmation'
        $captures.Add((Add-AcceptanceScreenshotContext -Screenshot $confirmationCapture -Appearance $appearanceSpec.evidence_name -Surface 'confirmation-task-dialog'))
        if ($rawCandidate) {
            $cancelEvent = Get-VmAutomatedKeyboardEventStart `
                -Action escape -Confirmation $confirmation -Process $process `
                -ExpectedSession $ExpectedSessionId -ExpectedAutomationId 'CommandButton_2' `
                -TimeoutSeconds $TimeoutSeconds
        }
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x1B -Label 'Apply confirmation Escape'
        if ($rawCandidate) {
            Complete-VmAutomatedKeyboardEvent `
                -Event $cancelEvent -Process $process -ExpectedSession $ExpectedSessionId `
                -MainWindowHandle $mainHandle -TimeoutSeconds $TimeoutSeconds
            $keyboardEvents.Add($cancelEvent)
        }
        $cancellationDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            if ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
                -not (Test-Path -LiteralPath $destinationPath) -and
                [DarkReNamerVmNative]::GetForegroundWindow() -eq $mainHandle) {
                break
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $cancellationDeadline)
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $keyboard.cancellation_unchanged = (
            (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $destinationPath) -and
            (Get-LowerSha256 -Path $sourcePath) -ceq $beforeContent -and
            [DarkReNamerVmNative]::GetFileIdentity($sourcePath) -ceq $beforeIdentity
        )
        if (-not $keyboard.cancellation_unchanged) {
            throw 'Escape cancellation changed the acceptance fixture.'
        }
        if ($rawCandidate) {
            $rawCheckpoints.Add((Get-VmAutomatedCheckpoint `
                -Phase after_cancel -FixtureRoot $fixtureRoot -LocalAppData $env:LOCALAPPDATA))
        }

        $result.failure_reason = 'apply_confirmation_failed'
        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32771')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'second Apply command Space'
        $confirmation = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $ExpectedSessionId `
            -MainWindowHandle $mainHandle -Name 'DarkReNamer - 안전한 적용 확인' `
            -TimeoutSeconds $TimeoutSeconds -Label 'second keyboard Apply confirmation'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId 'CommandLink_1101')
        if ($rawCandidate) {
            $applyEvent = Get-VmAutomatedKeyboardEventStart `
                -Action enter -Confirmation $confirmation -Process $process `
                -ExpectedSession $ExpectedSessionId -ExpectedAutomationId 'CommandLink_1101' `
                -TimeoutSeconds $TimeoutSeconds
        }
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'Apply confirmation Enter'
        if ($rawCandidate) {
            Complete-VmAutomatedKeyboardEvent `
                -Event $applyEvent -Process $process -ExpectedSession $ExpectedSessionId `
                -MainWindowHandle $mainHandle -TimeoutSeconds $TimeoutSeconds
            $keyboardEvents.Add($applyEvent)
        }
        $applyDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            if (-not (Test-Path -LiteralPath $sourcePath) -and
                (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                try { Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA; break } catch {}
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $applyDeadline)
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $keyboard.confirmed_disk_rename = (
            -not (Test-Path -LiteralPath $sourcePath) -and
            (Test-Path -LiteralPath $destinationPath -PathType Leaf)
        )
        if (-not $keyboard.confirmed_disk_rename) {
            throw 'Keyboard-confirmed Apply did not perform the expected rename.'
        }
        $keyboard.content_preserved = (Get-LowerSha256 -Path $destinationPath) -ceq $beforeContent
        $keyboard.identity_preserved = [DarkReNamerVmNative]::GetFileIdentity($destinationPath) -ceq $beforeIdentity
        if (-not $keyboard.content_preserved -or -not $keyboard.identity_preserved) {
            throw 'Keyboard-confirmed Apply did not preserve file contents and identity.'
        }
        $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
        $keyboard.journal_residue_count = if (Test-Path -LiteralPath $journalRoot) {
            @(Get-ChildItem -LiteralPath $journalRoot -Force | Where-Object Name -cne 'runtime.lock').Count
        } else { 0 }
        $keyboard.status = 'passed'
        if ($rawCandidate) {
            $rawCheckpoints.Add((Get-VmAutomatedCheckpoint `
                -Phase after_apply -FixtureRoot $fixtureRoot -LocalAppData $env:LOCALAPPDATA))
        }
        $capture.status = 'passed'
        $capture.screenshot_count = $captures.Count

        $result.failure_reason = 'normal_close_failed'
        $normalExitCode = Close-AcceptanceApplication -Application $application -SessionId $ExpectedSessionId -WaitSeconds 10 -CloseInput keyboard
        $lifecycle.process_terminated = $true
        if ($rawCandidate) {
            $result.process_lifecycle.exit_observed = $true
            $result.process_lifecycle.exit_method = 'normal-close'
            $result.process_lifecycle.exit_code = [int]$normalExitCode
            $rawCheckpoints.Add((Get-VmAutomatedCheckpoint `
                -Phase post_close -FixtureRoot $fixtureRoot -LocalAppData $env:LOCALAPPDATA))
            $result.raw_checkpoints = $rawCheckpoints.ToArray()
            $result.keyboard_events = $keyboardEvents.ToArray()
            $rawMainHandle = [long]$mainWindow.Current.NativeWindowHandle
            if (@($rawControls | Where-Object {
                $_.pid -ne $process.Id -or $_.session_id -ne $ExpectedSessionId -or
                $_.root_hwnd -ne $rawMainHandle
            }).Count -ne 0) {
                throw 'Current-DPI raw layout controls differ from the candidate workbench.'
            }
            $result.layout_observations = [ordered]@{
                controls = $rawControls.ToArray()
                focus = @($keyboardEvents | ForEach-Object focused_before)
                focus_reachability = $rawFocusReachability
                screenshots = $captures.ToArray()
            }
        }
    }

    $result.status = Get-AcceptanceVerdict `
        -KeyboardStatus $keyboard.status `
        -AccessibilityStatus $accessibility.status `
        -CaptureStatus $capture.status
    $result.failure_reason = $null
}
catch {
    $acceptanceFailure = $_
    if ($rawCandidate -and $result.failure_reason -ceq 'prefix_keyboard_failed') {
        if ($null -ne $rawFocusReachability) {
            $observations['failure_focus_reachability'] = $rawFocusReachability
        }
        if ($null -ne $processState.process) {
            try {
                $failureProcess = $processState.process.process
                $failureProcess.Refresh()
                if (-not $failureProcess.HasExited) {
                    $observations['prefix_failure_process_windows'] =
                        Get-BoundedAcceptanceProcessWindowInventory `
                            -Process $failureProcess `
                            -ExpectedSession $ExpectedSessionId
                }
            }
            catch {
                $observations['prefix_failure_process_windows'] = [ordered]@{
                    maximum_entries = 32
                    total_count = $null
                    truncated = $null
                    entries = @()
                    observation_status = 'failed'
                }
            }
        }
    }
    $acceptanceFailure | Out-String | Set-Content -LiteralPath $diagnosticPath -Encoding UTF8
    $result.diagnostic = [ordered]@{
        file = 'acceptance-error.txt'
        sha256 = Get-LowerSha256 -Path $diagnosticPath
    }
}
finally {
    try { [DarkReNamerVmAcceptanceNative]::ReleaseModifiers() } catch {}
    if ($Clipboard -and $clipboardState.owned) {
        try {
            $clipboardCleanup = [DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned(
                $clipboardState.expected_sequence,
                $clipboardState.expected_text
            )
            if ($clipboardCleanup -ceq 'cleared') {
                $clipboardResult.cleanup = 'cleared'
                if ($clipboardState.checks_complete) {
                    $clipboardResult.status = 'passed'
                    $clipboardResult.reason = $null
                }
            }
            else {
                $clipboardResult.status = 'failed'
                $clipboardResult.reason = 'Clipboard changed after acceptance; foreign data was preserved.'
                $clipboardResult.cleanup = 'preserved_foreign_change'
                $result.status = 'failed'
                if ($null -eq $result.failure_reason) {
                    $result.failure_reason = 'clipboard_cleanup_preserved_foreign_change'
                }
            }
        }
        catch {
            $clipboardResult.status = 'failed'
            $clipboardResult.reason = 'Guarded Clipboard cleanup could not be verified.'
            $clipboardResult.cleanup = 'failed'
            $result.status = 'failed'
            if ($null -eq $result.failure_reason) {
                $result.failure_reason = 'clipboard_cleanup_failed'
            }
            $_ | Out-String | Add-Content -LiteralPath $diagnosticPath -Encoding UTF8
        }
    }
    if ($null -ne $processState.process) {
        try {
            $process = $processState.process.process
            $process.Refresh()
            if (-not $process.HasExited) {
                Invoke-TaskkillTree -ProcessId $process.Id
                if (-not $process.WaitForExit(10000)) {
                    $result.status = 'failed'
                    $result.failure_reason = 'process_cleanup_failed'
                }
                elseif ($rawCandidate -and $null -ne $result.process_lifecycle) {
                    $result.process_lifecycle.exit_observed = $true
                    $result.process_lifecycle.exit_method = 'forced-termination'
                    $result.process_lifecycle.exit_code = [int]$process.ExitCode
                }
            }
            $lifecycle.process_terminated = $process.HasExited
        }
        finally {
            $processState.process.process.Dispose()
        }
    }
    if ($HighContrast -and $null -ne $highContrastState.original) {
        try {
            if ($highContrastState.changed) {
                [DarkReNamerVmAcceptanceNative]::ApplyHighContrast(
                    $highContrastState.original.Flags,
                    $highContrastState.original.Scheme
                )
            }
            $highContrastState.restored = Wait-HighContrastRestoration `
                -Expected $highContrastState.original `
                -ReadSnapshot { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
                -Label 'High Contrast restoration' `
                -DiagnosticPath $diagnosticPath `
                -AllowPaletteRestore:$highContrastState.changed
            $highContrastState.restoration_verified = $true
            $highContrastResult.restoration = 'verified'
            Write-JsonUtf8Bom -Path $highContrastState.rescue_path -Value ([ordered]@{
                schema_version = 2
                source_sha = $verified.source_sha
                acceptance_script_sha256 = $verified.script_sha256
                restoration_required = $false
                original = ConvertTo-HighContrastDocumentSnapshot -Snapshot $highContrastState.original
                restoration_verified = $true
                restored = ConvertTo-HighContrastDocumentSnapshot -Snapshot $highContrastState.restored
            })
        }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'high_contrast_restore_failed'
            $_ | Out-String | Add-Content -LiteralPath $diagnosticPath -Encoding UTF8
            $highContrastResult.restoration = 'failed'
        }
        if (Test-Path -LiteralPath $highContrastState.rescue_path -PathType Leaf) {
            $highContrastResult.snapshot = [ordered]@{
                file = 'high-contrast-restore.json'
                sha256 = Get-LowerSha256 -Path $highContrastState.rescue_path
            }
        }
    }
    try {
        Exit-TestExecutionState -Previous $previousExecutionState
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'execution_state_restore_failed'
    }
    try {
        Exit-DesktopTestLock -Lock $desktopLock
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'desktop_lock_release_failed'
        $_ | Out-String | Add-Content -LiteralPath $diagnosticPath -Encoding UTF8
    }
    $rawJournalAfter = $null
    $rawJournalObserved = $false
    $rawRuntimeRootAfter = $null
    try {
        if (-not $lifecycle.process_terminated) {
            throw 'The owned application process is still running; runtime evidence was retained.'
        }
        $rawJournalAfter = @(if ($rawCandidate -and $rawCheckpoints.Count -gt 0) {
            @($rawCheckpoints[$rawCheckpoints.Count - 1].journal_entries)
        }
        elseif ($rawCandidate) {
            @(Get-VmAutomatedJournalInventory -LocalAppData (Join-Path $runtimeRoot 'localappdata'))
        }
        else { @() })
        $rawJournalObserved = $rawCandidate
        if (Test-Path -LiteralPath $runtimeRoot) {
            [void](Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot)
            Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
        }
        $runtimeCleanup = -not (Test-Path -LiteralPath $runtimeRoot)
        if ($rawCandidate) {
            $ownedAfter = @(Get-VmAutomatedOwnedProcessInventory -Root $verified.root)
            $rawRuntimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot
            $result.raw_cleanup = [ordered]@{
                owned_processes_after = $ownedAfter
                runtime_root_after = $rawRuntimeRootAfter
                journal_after = (New-VmAutomatedJournalCleanupObservation `
                    -Observed $rawJournalObserved -Entries $rawJournalAfter)
            }
            if ($ownedAfter.Count -ne 0 -or -not $runtimeCleanup) {
                throw 'Current-DPI raw cleanup retained owned state.'
            }
        }
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'runtime_cleanup_failed'
        if ($rawCandidate) {
            try {
                $rawRuntimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot
            }
            catch {
                $rawRuntimeRootAfter = $null
            }
            $result.raw_cleanup = [ordered]@{
                owned_processes_after = @(Get-VmAutomatedOwnedProcessInventory -Root $verified.root)
                runtime_root_after = $rawRuntimeRootAfter
                journal_after = (New-VmAutomatedJournalCleanupObservation `
                    -Observed $rawJournalObserved -Entries $rawJournalAfter)
            }
        }
    }
    $result.guest_cleanup = $runtimeCleanup
    $result.screenshots = $captures.ToArray()
    if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
        $result.diagnostic = [ordered]@{
            file = 'acceptance-error.txt'
            sha256 = Get-LowerSha256 -Path $diagnosticPath
        }
    }
    Write-JsonUtf8Bom -Path $observationPath -Value $observations
    $result.observations = [ordered]@{
        file = 'acceptance-observations.json'
        sha256 = Get-LowerSha256 -Path $observationPath
    }
    Write-JsonUtf8Bom -Path $resultPath -Value $result
}

if ($result.status -eq 'failed') {
    throw 'Current-DPI acceptance failed; inspect the external result and diagnostic artifacts.'
}
Write-Host "Captured source-bound current-DPI evidence; visual review remains required."
}
