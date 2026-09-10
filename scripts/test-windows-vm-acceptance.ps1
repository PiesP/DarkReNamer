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
    Write-Utf8Json `
        -Path (Join-Path $Fixture.output_root 'high-contrast-restore.json') `
        -Value ([ordered]@{
            schema_version = 1
            source_sha = $SourceSha
            acceptance_script_sha256 = $ScriptSha256
            restoration_required = $RestorationRequired
            original = [ordered]@{
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
            }
            restoration_verified = $RestorationVerified
            restored = $null
        })
}

$acceptance = Join-Path $PSScriptRoot 'windows-vm-acceptance.ps1'
$runner = Join-Path $PSScriptRoot 'windows-vm-guest.ps1'
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
    if ([IO.File]::ReadAllText($acceptance).IndexOf('[ushort]', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw 'The acceptance script must use Windows PowerShell 5.1-compatible integer type names.'
    }
    $acceptanceText = [IO.File]::ReadAllText($acceptance)
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
    if (($acceptanceText | Select-String -Pattern "failure_reason = 'desktop_lock_release_failed'" -AllMatches).Matches.Count -ne 2) {
        throw 'Both acceptance and rescue must preserve structured evidence after desktop-lock release failure.'
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

    . $acceptance `
        -BundleRoot 'unused' `
        -ExpectedSessionId 1 `
        -OutputRoot 'unused' `
        -ExpectedScriptSha256 ('0' * 64) `
        -ValidateOnly
    Initialize-AcceptanceNative
    foreach ($method in @(
        'IsWindowEnabled',
        'IsMenuCommandEnabled',
        'ReadClipboardSnapshot',
        'ClearClipboardIfOwned',
        'SetHighContrastColors'
    )) {
        if ($null -eq [DarkReNamerVmAcceptanceNative].GetMethod($method)) {
            throw "The acceptance native probe is missing $method."
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
    $exactRestore = Wait-HighContrastRestoration `
        -Expected $highContrastSnapshot `
        -ReadSnapshot {
            $exactRestoreState.reads++
            $highContrastSnapshot | Select-Object *
        } `
        -SetCapturedColors { param($expected) $exactRestoreState.writes++ } `
        -Label 'exact restoration fixture' `
        -MaximumAttempts 2 `
        -FallbackAttempts 2 `
        -PollMilliseconds 0
    if ($exactRestoreState.reads -ne 2 -or $exactRestoreState.writes -ne 0 -or
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

    $readErrorState = [pscustomobject]@{ writes = 0 }
    Assert-Fails {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot { throw 'fixture snapshot read failed' } `
            -SetCapturedColors { param($expected) $readErrorState.writes++ } `
            -Label 'read error fixture' `
            -AllowPaletteRestore `
            -MaximumAttempts 2 -FallbackAttempts 2 -PollMilliseconds 0
    } 'fixture snapshot read failed'
    if ($readErrorState.writes -ne 0) { throw 'Snapshot read failure must not write system colors.' }

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
    Assert-Fails {
        Wait-HighContrastRestoration `
            -Expected $highContrastSnapshot `
            -ReadSnapshot { $fallbackState.reads++; $paletteDrift | Select-Object * } `
            -SetCapturedColors { param($expected) $fallbackState.writes++ } `
            -Label 'bounded fallback fixture' `
            -AllowPaletteRestore `
            -MaximumAttempts 2 -FallbackAttempts 2 -PollMilliseconds 0
    } 'palette fallback did not settle within the bounded observation attempts'
    if ($fallbackState.reads -ne 4 -or $fallbackState.writes -ne 1) {
        throw 'Palette fallback must remain bounded and must not false-pass persistent drift.'
    }

    $valid = New-AcceptanceFixture -Name 'valid'
    Invoke-ValidateOnly $valid
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
        $resolvedRestore.document.restoration_required -ne $true) {
        throw 'The High Contrast restore snapshot was not parsed exactly.'
    }
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
