$script:PerformanceResponseTimelineSchemaVersion = 1
$script:PickerFailureSchemaVersion = 3

function Get-ObserverContextConfirmationReachability {
    param(
        [Parameter(Mandatory)][object] $Confirmation,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][IntPtr] $ConfirmationHandle,
        [Parameter(Mandatory)][object] $WorkArea,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $Prefix
    )

    $cancel = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandButton_2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context Cancel button' -RequireEnabled -RequireWindowHandle
    $confirm = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1101' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context confirmation Apply link' -RequireEnabled -RequireWindowHandle
    $detailsButton = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1102' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context full-details command link' -RequireEnabled
    if ($detailsButton.Current.Name -cne '예시 전체 정보 · 복사') { throw 'Context full-details command text differs.' }
    $buttonCondition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
    $expanders = @($confirmation.FindAll([Windows.Automation.TreeScope]::Descendants, $buttonCondition) | Where-Object { $_.Current.Name -cin @('진단 정보 표시', '상세 정보 표시') })
    if ($expanders.Count -ne 1) { throw 'Context detail expander was not uniquely available.' }
    $reachability = [ordered]@{
        cancel = Get-ObserverControlReachability -Element $cancel -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'context Cancel'
        apply = Get-ObserverControlReachability -Element $confirm -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'context Apply'
        full_details = Get-ObserverControlReachability -Element $detailsButton -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'context full details'
        expander = Get-ObserverControlReachability -Element $expanders[0] -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'context expander'
    }
    Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-reachability.json')) -Value ([ordered]@{
        schema_version = 1
        controls = $reachability
    })
    $inaccessible = @($reachability.Values | Where-Object { $_.status -cne 'reachable' })
    if ($inaccessible.Count -ne 0) {
        $failedLabels = @($inaccessible | ForEach-Object { [string]$_.label })
        throw ('After context confirmation has a mouse-inaccessible required control: ' +
            [string]::Join(', ', $failedLabels) + '.')
    }
    [ordered]@{ cancel = $cancel; confirm = $confirm; details_button = $detailsButton; expanders = $expanders; reachability = $reachability; button_condition = $buttonCondition }
}

function Invoke-ObserverContextConfirmation {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $ExpectedScope,
        [Parameter(Mandatory)][string] $ExpectedFullText,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ExpectedDestinationParent,
        [AllowEmptyString()][string] $ExpectedDestinationPath = '',
        [switch] $ExpectItemSpecificDestination,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][object] $WorkArea,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [switch] $PhysicalMouseActivation,
        [switch] $Standard
    )
    $tooltipProbe = [bool]$script:contract.tooltip_regression
    $preModalTooltip = $null
    if ($tooltipProbe) {
        $gridForTooltip = Get-ObserverGrid -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds
        $listViewHandle = [IntPtr]$gridForTooltip.element.Current.NativeWindowHandle
        if ($listViewHandle -eq [IntPtr]::Zero) { throw 'Context ListView has no native HWND for tooltip identity.' }
        $tooltipHandle = [DarkReNamerVmAcceptanceNative]::ReadListViewTooltip($listViewHandle)
        if ($tooltipHandle -eq 0) { throw 'LVM_GETTOOLTIPS returned no ListView infotip HWND.' }
        $mainBounds = $Application.main.Current.BoundingRectangle
        $neutralPoint = [DarkReNamerVmAcceptanceNative+Point]::new()
        $neutralPoint.X = [int][Math]::Floor($mainBounds.Left + ($mainBounds.Width / 2.0))
        $neutralPoint.Y = [int][Math]::Floor($mainBounds.Top + [Math]::Min(10.0, $mainBounds.Height / 2.0))
        [DarkReNamerVmAcceptanceNative]::MoveCursor($neutralPoint.X, $neutralPoint.Y)
        Start-Sleep -Milliseconds 600
        $neutralWindows = Get-ObserverProcessWindows -Process $Application.process
        if (@($neutralWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible }).Count -ne 0) {
            throw 'ListView infotip did not hide at the neutral title-bar point.'
        }
        $hoverColumn = 0
        $hoverCell = $gridForTooltip.pattern.GetItem(0, $hoverColumn)
        if ($hoverCell.Current.IsOffscreen) { throw 'Tooltip overlap probe current-name cell is offscreen.' }
        $rowRect = $hoverCell.Current.BoundingRectangle
        $point = [DarkReNamerVmAcceptanceNative+Point]::new()
        $point.X = [int][Math]::Floor($rowRect.Left + [Math]::Min(8.0, $rowRect.Width / 2.0))
        $point.Y = [int][Math]::Floor($rowRect.Top + ($rowRect.Height / 2.0))
        [DarkReNamerVmAcceptanceNative]::MoveCursor($point.X, $point.Y)
        $hit = [DarkReNamerVmAcceptanceNative]::WindowFromPoint($point)
        $mainRoot = [IntPtr]$Application.main.Current.NativeWindowHandle
        if ([DarkReNamerVmAcceptanceNative]::GetAncestor($hit, [uint32]2) -ne $mainRoot) {
            throw 'Tooltip overlap probe hover point did not hit the exact application root.'
        }
        $visibleTooltip = @()
        for ($attempt = 0; $attempt -lt 30 -and $visibleTooltip.Count -ne 1; $attempt++) {
            Start-Sleep -Milliseconds 100
            $hoverWindows = Get-ObserverProcessWindows -Process $Application.process
            $visibleTooltip = @($hoverWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible -and $_.rect.height -ge 100 })
        }
        if ($visibleTooltip.Count -ne 1) { throw 'Ordinary current-name hover did not expose the bound multiline ListView infotip HWND.' }
        $preModalTooltip = [ordered]@{
            input = 'physical-mouse-hover-without-click'
            neutral_point = [ordered]@{ x = $neutralPoint.X; y = $neutralPoint.Y }
            point = [ordered]@{ x = $point.X; y = $point.Y; hit_window = $hit.ToInt64(); root_window = $mainRoot.ToInt64() }
            listview_hwnd = $listViewHandle.ToInt64()
            listview_tooltip_hwnd = $tooltipHandle
            hovered_column = $hoverColumn
            hovered_cell = Get-ElementObservation -Element $hoverCell
            hover_state = 'multiline-infotip-visible-before-keyboard-apply'
            visible_before_public_apply = $true
            window = $visibleTooltip[0]
        }
    }
    $applyTrigger = if ($tooltipProbe) {
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x53 -Label 'context public Ctrl+S Apply with visible ListView infotip'
        [pscustomobject]@{ input = 'keyboard-ctrl-s-with-visible-listview-infotip'; invocation = $null; menu_entry = $null }
    }
    else {
        Start-ObserverApplyFromPublicUi -Application $Application -SessionId $SessionId -Label 'context Apply command'
    }
    $applyInvocation = $applyTrigger.invocation
    $confirmation = Wait-ObserverConfirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'context Apply confirmation'
    $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
    $confirmationWindowMetrics = Get-ObserverNativeWindowMetrics -Window $confirmation
    $tree = Get-ObserverWindowTree -Window $confirmation -Process $Application.process -SessionId $SessionId -Label 'context Apply confirmation'
    $treeText = [string]::Join("`n", @($tree | ForEach-Object { $_.name } | Where-Object { $_ }))
    Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-confirmation-tree.json')) -Value $tree
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-confirmation.png') -Label 'context confirmation'))
    $modalOverlay = $null
    if ($tooltipProbe) {
        $entryWindows = Get-ObserverProcessWindows -Process $Application.process
        Start-Sleep -Milliseconds 3000
        $settledWindows = Get-ObserverProcessWindows -Process $Application.process
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-confirmation-settled.png') -Label 'context confirmation after tooltip settling interval'))
        $essential = @($tree | Where-Object { $_.automation_id -cin @('ContentText', 'CommandLink_1101', 'CommandLink_1102', 'CommandButton_2') })
        $entryTooltip = @($entryWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        $settledTooltip = @($settledWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        $blocking = @($settledTooltip | Where-Object {
            $window = $_.rect
            @($essential | Where-Object {
                $control = $_.bounds
                $window.left -lt ($control.x + $control.width) -and $window.right -gt $control.x -and
                $window.top -lt ($control.y + $control.height) -and $window.bottom -gt $control.y
            }).Count -gt 0
        })
        $modalOverlay = [ordered]@{
            observation = 'process-top-level-HWND-enumeration-plus-LVM_GETTOOLTIPS'
            pre_modal = $preModalTooltip
            settling_interval_ms = 3000
            listview_hwnd = $listViewHandle.ToInt64()
            listview_tooltip_hwnd = $tooltipHandle
            owner_disabled = -not [DarkReNamerVmAcceptanceNative]::IsWindowEnabled([IntPtr]$Application.main_handle)
            at_entry = $entryWindows
            at_entry_bound_tooltip_visible = $entryTooltip.Count -eq 1
            after_settling = $settledWindows
            persisted_visible_tooltip = $settledTooltip.Count -eq 1
            persisted_essential_overlap = $blocking.Count -eq 1
            settled_capture = $Prefix + '-confirmation-settled.png'
        }
        Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-modal-overlay.json')) -Value $modalOverlay
        if ($modalOverlay.at_entry_bound_tooltip_visible -or $modalOverlay.persisted_visible_tooltip -or $modalOverlay.persisted_essential_overlap) {
            throw 'ListView infotip remained visible during the modal confirmation entry or settling interval.'
        }
    }
    if ($treeText.IndexOf($ExpectedScope, [StringComparison]::Ordinal) -lt 0) {
        throw 'Context confirmation lost its exact list/selection/change scope.'
    }
    $notice = $false
    $identicalSnippetPairs = [Collections.Generic.List[object]]::new()
    $destinationPrimary = $true
    $destinationExample = $true
    $destination = $true
    if (-not $Standard) {
        $notice = $treeText.IndexOf('축약문에 차이가 드러나지 않습니다', [StringComparison]::Ordinal) -ge 0
        $currentLines = @($treeText.Split("`n") | Where-Object { $_.StartsWith('현재: ', [StringComparison]::Ordinal) })
        $changedLines = @($treeText.Split("`n") | Where-Object { $_.StartsWith('변경 후: ', [StringComparison]::Ordinal) })
        for ($index = 0; $index -lt [Math]::Min($currentLines.Count, $changedLines.Count); $index++) {
            $currentSnippet = $currentLines[$index].Substring('현재: '.Length)
            $changedSnippet = $changedLines[$index].Substring('변경 후: '.Length)
            if ($currentSnippet -ceq $changedSnippet) {
                $identicalSnippetPairs.Add([ordered]@{ example = $index; snippet = $currentSnippet })
            }
        }
        if (-not $ExpectItemSpecificDestination -and [string]::IsNullOrEmpty($ExpectedDestinationParent) -and $identicalSnippetPairs.Count -eq 0) {
            throw 'Repeated-name fixture did not reproduce an identical rendered snippet pair.'
        }
        $destinationParentSnippet = if ([string]::IsNullOrEmpty($ExpectedDestinationParent)) { '' } else {
            Get-ObserverBoundedDifferenceSnippet -Text $ExpectedDestinationParent -FocusStart $ExpectedDestinationParent.Length -FocusEnd $ExpectedDestinationParent.Length
        }
        $destinationLabel = $treeText.IndexOf('대상 폴더:', [StringComparison]::Ordinal) -ge 0 -or
            $treeText.IndexOf('대상 폴더 (축약):', [StringComparison]::Ordinal) -ge 0
        $destinationPrimary = [string]::IsNullOrEmpty($ExpectedDestinationParent) -or
            ($destinationLabel -and $treeText.IndexOf($destinationParentSnippet, [StringComparison]::Ordinal) -ge 0)
        $destinationExample = [string]::IsNullOrEmpty($ExpectedDestinationParent) -or
            (-not [string]::IsNullOrEmpty($ExpectedDestinationPath) -and $treeText.IndexOf($ExpectedDestinationPath, [StringComparison]::Ordinal) -ge 0)
        $destination = if ($ExpectItemSpecificDestination) {
            $treeText.IndexOf('대상 폴더는 항목별로 확인하세요', [StringComparison]::Ordinal) -ge 0
        } elseif ([string]::IsNullOrEmpty($ExpectedDestinationParent)) { $true } else { $destinationPrimary }
        if (-not $ExpectItemSpecificDestination -and -not $notice -and [string]::IsNullOrEmpty($ExpectedDestinationParent)) {
            throw 'Repeated-name confirmation omitted the explicit indistinguishable-snippet notice.'
        }
        if (-not $destination) { throw 'Context confirmation omitted the required destination-folder context.' }
    }
    $defaultFocus = Get-ObserverConfirmationDefaultFocus -Application $Application -SessionId $SessionId

    $contextControls = Get-ObserverContextConfirmationReachability -Confirmation $confirmation `
        -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds `
        -ConfirmationHandle $confirmationHandle -WorkArea $WorkArea -OutputRoot $OutputRoot -Prefix $Prefix
    $cancel = $contextControls.cancel
    $confirm = $contextControls.confirm
    $detailsButton = $contextControls.details_button
    $expanders = $contextControls.expanders
    $reachability = $contextControls.reachability
    $buttonCondition = $contextControls.button_condition
    $cancel = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandButton_2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context Cancel after default scroll' -RequireEnabled -RequireWindowHandle
    $cancel.SetFocus()

    $opened = Open-ObserverConfirmationDetails -Confirmation $confirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds
    $opened | Add-Member -NotePropertyName activation -NotePropertyValue ([ordered]@{ input = 'keyboard-enter'; target = $null })
    $detailsWindow = $opened.window
    $detailsHandle = [IntPtr]$detailsWindow.Current.NativeWindowHandle
    $detailsWindowMetrics = Get-ObserverNativeWindowMetrics -Window $detailsWindow
    $details = Get-ObserverReadOnlyDetails -Window $detailsWindow -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedText $ExpectedFullText -Label 'context full details'
    $detailsRasterTarget = $null
    $contention = $null
    $selectionCopy = $null
    $copyAll = $null
    if ($Standard) {
        $detailsRasterTarget = Get-ObserverNativeStaticRasterTarget -Window $detailsWindow -Application $Application -SessionId $SessionId -ControlId 1001 -ExpectedText '전체 이름과 경로' -Id 'full-details' -Image ($Prefix + '-full-details.png')
        $contention = Invoke-ObserverClipboardContention -DetailsWindow $detailsWindow -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -OutputRoot $OutputRoot -CaptureLeaf ($Prefix + '-copy-failure.png') -Captures $Captures
        $selectionCopy = Copy-GuiRegressionDocument -Mode selection -Application $Application -Edit $details.edit -ExpectedText $details.evidence.value_text -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'confirmation full-details native selection'
        $copyAll = Copy-GuiRegressionDocument -Mode mnemonic -Application $Application -ExpectedText $details.evidence.value_text -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'confirmation full-details retry copy all'
    }
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $detailsWindow -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-full-details.png') -Label 'context full details'))
    Assert-AutomationBinding -Element $details.edit -Process $Application.process -ExpectedSession $SessionId -Label 'context full-details edit before end scroll'
    $expectedEnding = (Normalize-ObserverText $ExpectedFullText).Split("`n")[-1]
    $endObservation = Get-ObserverDetailsEndObservation -Application $Application -Details $details `
        -SessionId $SessionId -Label 'context full-details Ctrl+End' -ExpectedEnding $expectedEnding
    $visibleEnd = $endObservation.visible_text
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $detailsWindow -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-full-details-end.png') -Label 'context full details ending'))
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label 'confirmation full-details Escape close'
    $detailsCloseTarget = $null
    $detailsCloseInput = 'keyboard-escape'
    Wait-WindowClosed -Handle $detailsHandle -TimeoutSeconds $WaitSeconds -Label 'context full-details prompt'
    $confirmation = Wait-ObserverConfirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'context confirmation after details'
    $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
    $afterDetailsFocus = Get-ObserverConfirmationDefaultFocus -Application $Application -SessionId $SessionId
    if ($tooltipProbe) {
        $afterDetailsWindows = Get-ObserverProcessWindows -Process $Application.process
        $afterDetailsTooltip = @($afterDetailsWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-confirmation-after-details-return.png') -Label 'context confirmation after full-details return'))
        $modalOverlay['after_details_return'] = [ordered]@{
            windows = $afterDetailsWindows
            bound_tooltip_visible = $afterDetailsTooltip.Count -eq 1
            essential_overlap = $false
            capture = $Prefix + '-confirmation-after-details-return.png'
        }
        if ($modalOverlay.after_details_return.bound_tooltip_visible) {
            $modalOverlay.after_details_return.essential_overlap = $true
            throw 'ListView infotip reappeared over the confirmation after full-details return.'
        }
    }
    $expanders = @($confirmation.FindAll([Windows.Automation.TreeScope]::Descendants, $buttonCondition) | Where-Object { $_.Current.Name -cin @('진단 정보 표시', '상세 정보 표시') })
    if ($expanders.Count -ne 1) { throw 'Recreated context detail expander was not uniquely available.' }
    $reachability.expander = Get-ObserverControlReachability -Element $expanders[0] -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'recreated context expander'
    if ($reachability.expander.status -cne 'reachable') {
        throw 'After context confirmation recreated an inaccessible expander.'
    }

    $expanderInput = 'physical-mouse'
    $physicalExpander = Get-GuiRegressionPhysicalTarget -Click -Element $expanders[0] -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -Label 'context detail expander'
    Start-Sleep -Milliseconds 200
    $expandedTree = Get-ObserverWindowTree -Window $confirmation -Process $Application.process -SessionId $SessionId -Label 'expanded context confirmation'
    $expandedWindowMetrics = Get-ObserverNativeWindowMetrics -Window $confirmation
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-confirmation-expanded.png') -Label 'expanded context confirmation'))
    if ($tooltipProbe) {
        $expandedWindows = Get-ObserverProcessWindows -Process $Application.process
        $expandedTooltip = @($expandedWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        $modalOverlay['after_expansion'] = [ordered]@{
            windows = $expandedWindows
            bound_tooltip_visible = $expandedTooltip.Count -eq 1
            essential_overlap = $false
            capture = $Prefix + '-confirmation-expanded.png'
        }
        if ($modalOverlay.after_expansion.bound_tooltip_visible) {
            $modalOverlay.after_expansion.essential_overlap = $true
            throw 'ListView infotip reappeared over the expanded confirmation.'
        }
    }
    $expandedBottom = Scroll-ObserverTaskDialogToEnd -Confirmation $confirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -OutputRoot $OutputRoot -CaptureLeaf ($Prefix + '-confirmation-expanded-bottom.png') -Label 'context confirmation expanded' -Captures $Captures
    $expandedInfo = @($expandedBottom.tree | Where-Object { $_.automation_id -ceq 'ExpandedInformationText' })
    if ($expandedInfo.Count -ne 1 -or $expandedInfo[0].offscreen -or
        $expandedInfo[0].name.IndexOf('계획 지문', [StringComparison]::Ordinal) -lt 0 -or
        $expandedInfo[0].name.IndexOf('목록 버전', [StringComparison]::Ordinal) -lt 0 -or
        $expandedInfo[0].name.IndexOf(':\', [StringComparison]::Ordinal) -ge 0) {
        throw 'Expanded context diagnostic was not visibly technical-only at the native scroll bottom.'
    }
    if ($PhysicalMouseActivation) {
        $cancel = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandButton_2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context Cancel after expanded scroll' -RequireEnabled -RequireWindowHandle
        $cancelTarget = Get-GuiRegressionPhysicalTarget -Click -Element $cancel -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -Label 'context confirmation Cancel'
        $cancelInput = 'physical-mouse'
    }
    else {
        Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label 'context confirmation cancellation Escape'
        $cancelTarget = $null
        $cancelInput = 'keyboard-escape'
    }
    Wait-WindowClosed -Handle $confirmationHandle -TimeoutSeconds $WaitSeconds -Label 'context confirmation cancellation'
    if ($null -ne $applyInvocation) {
        Complete-AutomationControlInvoke -State $applyInvocation -TimeoutSeconds $WaitSeconds
    }
    Wait-AcceptanceMainWindowForeground -Application $Application -WaitSeconds $WaitSeconds -Label 'context confirmation cancellation'
    if ($tooltipProbe) {
        $gridAfterCancel = Get-ObserverGrid -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds
        $tooltipAfterCancel = [DarkReNamerVmAcceptanceNative]::ReadListViewTooltip([IntPtr]$gridAfterCancel.element.Current.NativeWindowHandle)
        if ($tooltipAfterCancel -ne $tooltipHandle) {
            throw 'ListView infotip HWND identity changed across the confirmation modal lifecycle.'
        }
        $hoverCellAfterCancel = $gridAfterCancel.pattern.GetItem(0, 0)
        if ($hoverCellAfterCancel.Current.IsOffscreen) { throw 'Post-cancel tooltip probe current-name cell is offscreen.' }
        $postRect = $hoverCellAfterCancel.Current.BoundingRectangle
        $postPoint = [DarkReNamerVmAcceptanceNative+Point]::new()
        $postPoint.X = [int][Math]::Floor($postRect.Left + [Math]::Min(8.0, $postRect.Width / 2.0))
        $postPoint.Y = [int][Math]::Floor($postRect.Top + ($postRect.Height / 2.0))
        [DarkReNamerVmAcceptanceNative]::MoveCursor($postPoint.X, $postPoint.Y)
        $postHit = [DarkReNamerVmAcceptanceNative]::WindowFromPoint($postPoint)
        if ([DarkReNamerVmAcceptanceNative]::GetAncestor($postHit, [uint32]2) -ne [IntPtr]$Application.main.Current.NativeWindowHandle) {
            throw 'Post-cancel tooltip hover point did not hit the exact application root.'
        }
        $postVisibleTooltip = @()
        for ($attempt = 0; $attempt -lt 30 -and $postVisibleTooltip.Count -ne 1; $attempt++) {
            Start-Sleep -Milliseconds 100
            $postWindows = Get-ObserverProcessWindows -Process $Application.process
            $postVisibleTooltip = @($postWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible -and $_.rect.height -ge 100 })
        }
        if ($postVisibleTooltip.Count -ne 1) {
            throw 'Ordinary current-name hover did not restore the bound multiline ListView infotip after Cancel.'
        }
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-after-cancel-infotip.png') -Label 'context ListView infotip restored after Cancel'))
        [DarkReNamerVmAcceptanceNative]::MoveCursor($neutralPoint.X, $neutralPoint.Y)
        Start-Sleep -Milliseconds 600
        $postNeutralWindows = Get-ObserverProcessWindows -Process $Application.process
        $postNeutralTooltip = @($postNeutralWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        $modalOverlay['after_cancel'] = [ordered]@{
            input = 'physical-mouse-hover-without-click'
            point = [ordered]@{ x = $postPoint.X; y = $postPoint.Y; hit_window = $postHit.ToInt64(); root_window = $Application.main.Current.NativeWindowHandle }
            listview_tooltip_hwnd = $tooltipAfterCancel
            bound_tooltip_reexposed = $true
            window = $postVisibleTooltip[0]
            capture = $Prefix + '-after-cancel-infotip.png'
            neutral_point = [ordered]@{ x = $neutralPoint.X; y = $neutralPoint.Y }
            neutral_hidden = $postNeutralTooltip.Count -eq 0
            after_neutral = $postNeutralWindows
        }
        if (-not $modalOverlay.after_cancel.neutral_hidden) {
            throw 'Restored ListView infotip did not hide at the neutral point after Cancel.'
        }
        Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-modal-overlay.json')) -Value $modalOverlay
    }
    $result = [ordered]@{
        apply_entry = [ordered]@{ input = $applyTrigger.input; menu_entry = $applyTrigger.menu_entry }
        modal_overlay = $modalOverlay
        window = $confirmationWindowMetrics
        tree = $tree
        destination_context_visible = $destination
        default_focus = $defaultFocus
        reachability = $reachability
        expanded = [ordered]@{ window = $expandedWindowMetrics; input = $expanderInput; target = $physicalExpander; tree = $expandedTree; bottom_scroll = $expandedBottom }
        cancellation = [ordered]@{ input = $cancelInput; target = $cancelTarget; returned_to_preview = $true; default_cancel_preserved = $true }
    }
    if ($Standard) {
        $result['scope_3_1_2'] = $true
        $result['full_details'] = [ordered]@{
            text_raster_target = $detailsRasterTarget
            command_link = $opened.command_link
            canonical_text = $details.evidence
            copy_contention = $contention
            selection_copy = $selectionCopy
            copy_all_retry = $copyAll
            native_end_scroll = [ordered]@{ visible_text = $visibleEnd; ending_visible = $true }
            escape_return_default_cancel = $afterDetailsFocus
        }
    }
    else {
        $result['scope_exact'] = $true
        $result['indistinguishable_snippet_notice_visible'] = $notice
        $result['identical_rendered_snippet_pairs'] = $identicalSnippetPairs.ToArray()
        $result['item_specific_destination_notice_visible'] = [bool]$ExpectItemSpecificDestination -and $destination
        $result['destination_primary_visible'] = $destinationPrimary
        $result['destination_example_visible'] = $destinationExample
        $result['full_details'] = [ordered]@{
            window = $detailsWindowMetrics
            command_link = $opened.command_link
            activation = $opened.activation
            canonical_text = $details.evidence
            native_end_scroll = [ordered]@{ visible_text = $visibleEnd; ending_visible = $true }
            close = [ordered]@{ input = $detailsCloseInput; target = $detailsCloseTarget }
            return_default_cancel = $afterDetailsFocus
        }
    }
    $result

}
function Invoke-ObserverContextScenario {
    param(
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $Appearance,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [AllowNull()][Collections.Generic.List[object]] $ProcessLifecycleObservations
    )
    $applicationPath = Join-Path $Verified.root $Verified.application.file
    $rawLayoutCandidate = $Verified.lane -ceq 'candidate-gui-only'
    if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.application.sha256) {
        throw 'Application changed after bundle verification.'
    }
    $repeatedFixture = New-ObserverRepeatedFixture -RuntimeRoot $RuntimeRoot
    $repeatedApplication = $null
    $moveFixture = $null
    $moveApplication = $null
    $mixedFixture = $null
    $mixedApplication = $null
    $rawLayoutRuns = [Collections.Generic.List[object]]::new()
    $rawRepeatedRun = $null
    $rawMoveRun = $null
    $rawMixedRun = $null
    $rawCaptureStart = $Captures.Count
    $scenarioError = $null
    try {
        $repeatedApplication = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'repeated-name GUI regression application' -ProcessLifecycleObservations $ProcessLifecycleObservations
        $appearanceSpec = Set-AcceptanceAppearance -Process $repeatedApplication.process -ExpectedSession $SessionId -MainWindowHandle ([IntPtr]$repeatedApplication.main_handle) -Appearance $Appearance
        $minimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $repeatedApplication.main -Process $repeatedApplication.process -ExpectedSession $SessionId
        $environment = Get-ObserverEnvironmentMetadata -Application $repeatedApplication
        $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $repeatedApplication.main
        $requested = $script:contract.requested_small_workspace
        $requestedModePrefix = '{0}x{1}@' -f $requested.width,$requested.height
        $environment['requested_small_workspace'] = [ordered]@{
            width = [int]$requested.width
            height = [int]$requested.height
            actual_screen_matches = $environment.physical_screen.width -eq $requested.width -and $environment.physical_screen.height -eq $requested.height
            display_mode_advertised = @($environment.display_mode_inventory.values | Where-Object { $_.StartsWith($requestedModePrefix, [StringComparison]::Ordinal) }).Count -gt 0
            status = if ($environment.physical_screen.width -eq $requested.width -and $environment.physical_screen.height -eq $requested.height) { 'observed-exact' } else { 'not-available-in-current-managed-session' }
            mutation_attempted = $false
        }
        if ($minimum.dpi -ne $script:contract.expected_dpi -or $environment.hwnd_dpi -ne $script:contract.expected_dpi -or
            $environment.text_scale_factor_percent -ne $script:contract.expected_text_scale_percent -or
            -not $environment.requested_small_workspace.actual_screen_matches) {
            $environment['failure_classification'] = 'environment_blocked'
            $environment['failure_reason'] = if (-not $environment.requested_small_workspace.actual_screen_matches) {
                'requested_and_actual_target_monitor_geometry_differ'
            } elseif ($environment.text_scale_factor_percent -ne $script:contract.expected_text_scale_percent) {
                'actual_and_requested_text_scale_differ'
            } elseif ($minimum.dpi -ne $script:contract.expected_dpi) {
                'minimum_window_and_requested_dpi_differ'
            } else { 'main_hwnd_and_requested_dpi_differ' }
            $environment['requested_dpi'] = [int]$script:contract.expected_dpi
            $environment['requested_text_scale_factor_percent'] = [int]$script:contract.expected_text_scale_percent
            $environment['minimum_window_dpi'] = [int]$minimum.dpi
            Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot 'environment-preflight.json') -Value $environment
            throw ("environment_blocked: requested {0}x{1}@{2}, observed target monitor {3}x{4}, minimum DPI {5}, main HWND DPI {6}; confirmation matrix was not started." -f `
                $requested.width, $requested.height, $script:contract.expected_dpi, $environment.physical_screen.width, $environment.physical_screen.height, $minimum.dpi, $environment.hwnd_dpi)
        }
        Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot 'environment-preflight.json') -Value $environment
        $prefix = 'after-context-repeated-{0}-{1}' -f $Appearance,$minimum.dpi
        $import = Import-GuiRegressionPathList -Application $repeatedApplication -PathsFile $repeatedFixture.paths_file -ExpectedRows 3 -SessionId $SessionId -WaitSeconds $WaitSeconds
        $grid = $import.grid
        if ($rawLayoutCandidate) {
            $rawRepeatedRun = New-VmAutomatedLayoutRun `
                -Application $repeatedApplication -ApplicationPath $applicationPath `
                -FixtureRoot $repeatedFixture.root -Grid $grid -ExpectedSession $SessionId `
                -TimeoutSeconds $WaitSeconds -LayoutVariant $script:contract.layout_variant
        }
        for ($index = 0; $index -lt 3; $index++) {
            Set-ObserverManualName -Application $repeatedApplication -Grid $grid -Row $index -Name $repeatedFixture.destination_names[$index] -SessionId $SessionId -WaitSeconds $WaitSeconds
        }
        $selection = Set-ObserverSelectedRow -Application $repeatedApplication -Grid $grid -Row 0 -SessionId $SessionId
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $repeatedApplication.main -Process $repeatedApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($prefix + '-preview.png') -Label 'repeated-name preview'))
        $fullText = "변경 예시 전체 경로 (2/3개)`n`n현재 이름: $($repeatedFixture.source_names[0])`n변경 후 이름: $($repeatedFixture.destination_names[0])`n현재 전체 경로: $($repeatedFixture.paths[0])`n변경 후 전체 경로: $($repeatedFixture.destination_paths[0])`n`n현재 이름: $($repeatedFixture.source_names[1])`n변경 후 이름: $($repeatedFixture.destination_names[1])`n현재 전체 경로: $($repeatedFixture.paths[1])`n변경 후 전체 경로: $($repeatedFixture.destination_paths[1])"
        $fullText += "`n`n[U+XXXX]는 원본 UTF-16 코드 단위의 표시이며 입력할 이름이 아닙니다. 대괄호와 원본 …도 코드로 표시합니다."
        $repeatedConfirmation = Invoke-ObserverContextConfirmation -Application $repeatedApplication -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 3개' -ExpectedFullText $fullText -ExpectedDestinationParent '' -OutputRoot $EvidenceRoot -Prefix $prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures -PhysicalMouseActivation:($script:contract.mode -ceq 'context-surface')
        $afterCancel = Get-ObserverFixtureState -FixtureRoot $repeatedFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $repeatedFixture.initial -Actual $afterCancel)) {
            throw 'Repeated-name confirmation cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        if ($script:contract.mode -ceq 'context-surface') {
            $repeatedExit = Close-AcceptanceApplication -Application $repeatedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
            if ($rawLayoutCandidate) {
                Complete-VmAutomatedLayoutRun `
                    -Run $rawRepeatedRun -Process $repeatedApplication.process -ExitCode $repeatedExit `
                    -Screenshots @($Captures.ToArray() | Select-Object -Skip $rawCaptureStart)
                $rawLayoutRuns.Add($rawRepeatedRun)
            }
            [void](Complete-AcceptanceOwnedProcessJob -Owned $repeatedApplication.owned)
            $repeatedApplication.owned.process.Dispose()
            $repeatedApplication = $null
            return [ordered]@{
                raw_layout_runs = $rawLayoutRuns.ToArray()
                mode = 'context-surface'
                full_context_coverage = [ordered]@{
                    status = 'covered-by-separate-full-context-cell'
                    reference = [string]$script:contract.full_context_reference
                    omitted = @('second-repeated-fixture', 'movement-actual-apply', 'mixed-destination-third-unsampled-reentry', 'default-enter-cancel', 'alt-tab-roundtrip')
                }
                environment = $environment
                appearance = $appearanceSpec.evidence_name
                minimum_window = $minimum
                surface = [ordered]@{
                    fixture = 'long-repeated-3'
                    selection = $selection
                    confirmation = $repeatedConfirmation
                    cancellation_disk_unchanged = $true
                    fixture_identity_unchanged = $true
                    journal_residue_count = 0
                    normal_exit_code = $repeatedExit
                }
            }
        }
        Set-ObserverManualName -Application $repeatedApplication -Grid $grid -Row 0 -Name $repeatedFixture.source_names[0] -SessionId $SessionId -WaitSeconds $WaitSeconds
        Set-ObserverManualName -Application $repeatedApplication -Grid $grid -Row 1 -Name $repeatedFixture.source_names[1] -SessionId $SessionId -WaitSeconds $WaitSeconds
        $remainingSelection = Set-ObserverSelectedRow -Application $repeatedApplication -Grid $grid -Row 2 -SessionId $SessionId
        $remainingPrefix = 'after-context-repeated-korean-insert-{0}-{1}' -f $Appearance,$minimum.dpi
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $repeatedApplication.main -Process $repeatedApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($remainingPrefix + '-preview.png') -Label 'Korean repeated insertion preview'))
        $remainingFullText = "변경 예시 전체 경로 (1/1개)`n`n현재 이름: $($repeatedFixture.source_names[2])`n변경 후 이름: $($repeatedFixture.destination_names[2])`n현재 전체 경로: $($repeatedFixture.paths[2])`n변경 후 전체 경로: $($repeatedFixture.destination_paths[2])"
        $remainingFullText += "`n`n[U+XXXX]는 원본 UTF-16 코드 단위의 표시이며 입력할 이름이 아닙니다. 대괄호와 원본 …도 코드로 표시합니다."
        $remainingConfirmation = Invoke-ObserverContextConfirmation -Application $repeatedApplication -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 1개' -ExpectedFullText $remainingFullText -ExpectedDestinationParent '' -OutputRoot $EvidenceRoot -Prefix $remainingPrefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $afterRemainingCancel = Get-ObserverFixtureState -FixtureRoot $repeatedFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $repeatedFixture.initial -Actual $afterRemainingCancel)) {
            throw 'Korean repeated-insertion confirmation cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $repeatedExit = Close-AcceptanceApplication -Application $repeatedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
        if ($rawLayoutCandidate) {
            Complete-VmAutomatedLayoutRun `
                -Run $rawRepeatedRun -Process $repeatedApplication.process -ExitCode $repeatedExit `
                -Screenshots @($Captures.ToArray() | Select-Object -Skip $rawCaptureStart)
            $rawLayoutRuns.Add($rawRepeatedRun)
        }
        [void](Complete-AcceptanceOwnedProcessJob -Owned $repeatedApplication.owned -StopActive)
        $repeatedApplication.owned.process.Dispose()
        $repeatedApplication = $null

        $moveFixture = New-ObserverMoveFixture -RuntimeRoot $RuntimeRoot
        $rawCaptureStart = $Captures.Count
        $moveApplication = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'movement GUI regression application' -ProcessLifecycleObservations $ProcessLifecycleObservations
        $moveAppearance = Set-AcceptanceAppearance -Process $moveApplication.process -ExpectedSession $SessionId -MainWindowHandle ([IntPtr]$moveApplication.main_handle) -Appearance $Appearance
        $moveMinimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $moveApplication.main -Process $moveApplication.process -ExpectedSession $SessionId
        if ($moveMinimum.dpi -ne $script:contract.expected_dpi) { throw 'Move context HWND DPI differs from the staged contract.' }
        $movePrefix = 'after-context-move-{0}-{1}' -f $Appearance,$moveMinimum.dpi
        $moveImport = Import-GuiRegressionPathList -Application $moveApplication -PathsFile $moveFixture.paths_file -ExpectedRows 1 -SessionId $SessionId -WaitSeconds $WaitSeconds
        $moveGrid = $moveImport.grid
        if ($rawLayoutCandidate) {
            $rawMoveRun = New-VmAutomatedLayoutRun `
                -Application $moveApplication -ApplicationPath $applicationPath `
                -FixtureRoot $moveFixture.root -Grid $moveGrid -ExpectedSession $SessionId `
                -TimeoutSeconds $WaitSeconds -LayoutVariant $script:contract.layout_variant
        }
        $destinationInput = Set-ObserverDestinationParent -Application $moveApplication -Grid $moveGrid -DestinationParent $moveFixture.parent_b -SessionId $SessionId -WaitSeconds $WaitSeconds
        $moveOnlySelection = Set-ObserverSelectedRow -Application $moveApplication -Grid $moveGrid -Row 0 -SessionId $SessionId
        $moveOnlyPrefix = 'after-context-move-only-{0}-{1}' -f $Appearance,$moveMinimum.dpi
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $moveApplication.main -Process $moveApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($moveOnlyPrefix + '-preview.png') -Label 'move-only preview'))
        $moveOnlyDestination = Join-Path $moveFixture.parent_b 'old.txt'
        $moveOnlySnippets = Get-ObserverDifferenceSnippetPair -Current $moveFixture.source -After $moveOnlyDestination
        $moveOnlyFullText = "변경 예시 전체 경로 (1/1개)`n`n현재 이름: old.txt`n변경 후 이름: old.txt`n현재 전체 경로: $($moveFixture.source)`n변경 후 전체 경로: $moveOnlyDestination"
        $moveOnlyFullText += "`n`n[U+XXXX]는 원본 UTF-16 코드 단위의 표시이며 입력할 이름이 아닙니다. 대괄호와 원본 …도 코드로 표시합니다."
        $moveOnlyConfirmation = Invoke-ObserverContextConfirmation -Application $moveApplication -ExpectedScope '목록 전체 1개 · 선택 1개 · 실제 변경 1개' -ExpectedFullText $moveOnlyFullText -ExpectedDestinationParent $moveFixture.parent_b -ExpectedDestinationPath $moveOnlySnippets.after -OutputRoot $EvidenceRoot -Prefix $moveOnlyPrefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $moveOnlyAfterCancel = Get-ObserverFixtureState -FixtureRoot $moveFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $moveFixture.initial -Actual $moveOnlyAfterCancel)) {
            throw 'Move-only confirmation cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA

        Set-ObserverManualName -Application $moveApplication -Grid $moveGrid -Row 0 -Name 'new.txt' -SessionId $SessionId -WaitSeconds $WaitSeconds
        $moveSelection = Set-ObserverSelectedRow -Application $moveApplication -Grid $moveGrid -Row 0 -SessionId $SessionId
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $moveApplication.main -Process $moveApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($movePrefix + '-preview.png') -Label 'move-plus-rename preview'))
        $moveSnippets = Get-ObserverDifferenceSnippetPair -Current $moveFixture.source -After $moveFixture.destination
        $moveFullText = "변경 예시 전체 경로 (1/1개)`n`n현재 이름: old.txt`n변경 후 이름: new.txt`n현재 전체 경로: $($moveFixture.source)`n변경 후 전체 경로: $($moveFixture.destination)"
        $moveFullText += "`n`n[U+XXXX]는 원본 UTF-16 코드 단위의 표시이며 입력할 이름이 아닙니다. 대괄호와 원본 …도 코드로 표시합니다."
        $moveConfirmation = Invoke-ObserverContextConfirmation -Application $moveApplication -ExpectedScope '목록 전체 1개 · 선택 1개 · 실제 변경 1개' -ExpectedFullText $moveFullText -ExpectedDestinationParent $moveFixture.parent_b -ExpectedDestinationPath $moveSnippets.after -OutputRoot $EvidenceRoot -Prefix $movePrefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $moveAfterCancel = Get-ObserverFixtureState -FixtureRoot $moveFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $moveFixture.initial -Actual $moveAfterCancel)) {
            throw 'Move-plus-rename cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA

        $actualApplyTrigger = Start-ObserverApplyFromPublicUi -Application $moveApplication -SessionId $SessionId -Label 'actual move Apply command'
        $applyInvocation = $actualApplyTrigger.invocation
        $actualConfirmation = Wait-ObserverConfirmation -Application $moveApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'actual move confirmation'
        $actualTree = Get-ObserverWindowTree -Window $actualConfirmation -Process $moveApplication.process -SessionId $SessionId -Label 'actual move confirmation'
        $actualText = [string]::Join("`n", @($actualTree | ForEach-Object { $_.name } | Where-Object { $_ }))
        Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot ($movePrefix + '-actual-apply-confirmation-tree.json')) -Value $actualTree
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $actualConfirmation -Process $moveApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($movePrefix + '-actual-apply-confirmation.png') -Label 'actual move confirmation'))
        if ($actualText.IndexOf('목록 전체 1개 · 선택 1개 · 실제 변경 1개', [StringComparison]::Ordinal) -lt 0) {
            throw 'Actual move confirmation lost its exact 1/1/1 scope.'
        }
        $actualParentSnippet = Get-ObserverBoundedDifferenceSnippet -Text $moveFixture.parent_b -FocusStart $moveFixture.parent_b.Length -FocusEnd $moveFixture.parent_b.Length
        $actualDestinationVisible = ($actualText.IndexOf('대상 폴더:', [StringComparison]::Ordinal) -ge 0 -or
            $actualText.IndexOf('대상 폴더 (축약):', [StringComparison]::Ordinal) -ge 0) -and
            $actualText.IndexOf($actualParentSnippet, [StringComparison]::Ordinal) -ge 0
        if (-not $actualDestinationVisible) { throw 'Actual move confirmation omitted destination context.' }
        $actualHandle = [IntPtr]$actualConfirmation.Current.NativeWindowHandle
        $confirm = Find-UniqueAutomationElement -Root $actualConfirmation -Process $moveApplication.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1101' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'actual move confirmation Apply link' -RequireEnabled -RequireWindowHandle
        $actualReachability = Get-ObserverControlReachability -Element $confirm -Application $moveApplication -SessionId $SessionId -ExpectedRoot $actualHandle -WorkArea $environment.work_area -Label 'actual move Apply'
        if ($actualReachability.status -cne 'reachable') { throw 'Actual move Apply is mouse-inaccessible.' }
        $actualApplyInput = 'physical-mouse'
        $physicalApply = Get-GuiRegressionPhysicalTarget -Click -Element $confirm -Application $moveApplication -SessionId $SessionId -ExpectedRoot $actualHandle -Label 'actual move Apply'
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        do {
            $complete = -not (Test-Path -LiteralPath $moveFixture.source) -and (Test-Path -LiteralPath $moveFixture.destination -PathType Leaf)
            if ($complete) { try { Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA; break } catch {} }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        if ($null -ne $applyInvocation) {
            Complete-AutomationControlInvoke -State $applyInvocation -TimeoutSeconds $WaitSeconds
        }
        if (-not $complete) { throw 'Actual move-plus-rename did not reach the exact destination.' }
        Wait-AcceptanceMainWindowForeground -Application $moveApplication -WaitSeconds $WaitSeconds -Label 'actual move-plus-rename Apply'
        $initialMatches = @($moveFixture.initial | Where-Object { $_.path -ceq $moveFixture.source })
        if ($initialMatches.Count -ne 1) { throw 'Move source identity witness was not unique.' }
        $initial = $initialMatches[0]
        $actual = Get-Item -LiteralPath $moveFixture.destination -Force
        $contentPreserved = (Get-LowerSha256 -Path $actual.FullName) -ceq $initial.content_sha256
        $identityPreserved = [DarkReNamerVmNative]::GetFileIdentity($actual.FullName) -ceq $initial.identity
        if (-not $contentPreserved -or -not $identityPreserved) { throw 'Actual move-plus-rename changed content or NTFS identity.' }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $moveApplication.main -Process $moveApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($movePrefix + '-actual-apply-complete.png') -Label 'actual move completion'))
        $moveExit = Close-AcceptanceApplication -Application $moveApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
        if ($rawLayoutCandidate) {
            Complete-VmAutomatedLayoutRun `
                -Run $rawMoveRun -Process $moveApplication.process -ExitCode $moveExit `
                -Screenshots @($Captures.ToArray() | Select-Object -Skip $rawCaptureStart)
            $rawLayoutRuns.Add($rawMoveRun)
        }
        [void](Complete-AcceptanceOwnedProcessJob -Owned $moveApplication.owned -StopActive)
        $moveApplication.owned.process.Dispose()
        $moveApplication = $null

        $mixedFixture = New-ObserverMixedFixture -RuntimeRoot $RuntimeRoot
        $rawCaptureStart = $Captures.Count
        $mixedApplication = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'mixed GUI regression application' -ProcessLifecycleObservations $ProcessLifecycleObservations
        $mixedAppearance = Set-AcceptanceAppearance -Process $mixedApplication.process -ExpectedSession $SessionId -MainWindowHandle ([IntPtr]$mixedApplication.main_handle) -Appearance $Appearance
        $mixedMinimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $mixedApplication.main -Process $mixedApplication.process -ExpectedSession $SessionId
        if ($mixedMinimum.dpi -ne $script:contract.expected_dpi) { throw 'Mixed context HWND DPI differs from the staged contract.' }
        $mixedPrefix = 'after-context-mixed-{0}-{1}' -f $Appearance,$mixedMinimum.dpi
        $mixedImport = Import-GuiRegressionPathList -Application $mixedApplication -PathsFile $mixedFixture.first_paths_file -ExpectedRows 1 -SessionId $SessionId -WaitSeconds $WaitSeconds
        $mixedGrid = $mixedImport.grid
        if ($rawLayoutCandidate) {
            $rawMixedRun = New-VmAutomatedLayoutRun `
                -Application $mixedApplication -ApplicationPath $applicationPath `
                -FixtureRoot $mixedFixture.root -Grid $mixedGrid -ExpectedSession $SessionId `
                -TimeoutSeconds $WaitSeconds -LayoutVariant $script:contract.layout_variant
        }
        if ($mixedGrid.pattern.GetItem(0, 0).Current.Name -cne '03-unsampled-move.txt') {
            throw 'Unsampled-move source was not the first admitted row.'
        }
        $mixedDestinationInput = Set-ObserverDestinationParent -Application $mixedApplication -Grid $mixedGrid -DestinationParent $mixedFixture.parent_d -SessionId $SessionId -WaitSeconds $WaitSeconds
        [void](Import-GuiRegressionPathList -Application $mixedApplication -PathsFile $mixedFixture.later_paths_file -ExpectedRows 3 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $mixedGrid)
        $admissionOrder = @('03-unsampled-move.txt', '01-rename.txt', '02-rename.txt')
        for ($index = 0; $index -lt 3; $index++) {
            if ($mixedGrid.pattern.GetItem($index, 0).Current.Name -cne $admissionOrder[$index]) {
                throw 'Later admission altered an existing proposal or unexpected row order.'
            }
        }
        [void](Set-ObserverSelectedRow -Application $mixedApplication -Grid $mixedGrid -Row 0 -SessionId $SessionId)
        $reorderInputs = [Collections.Generic.List[object]]::new()
        foreach ($expectedOrder in @(
            ,@('01-rename.txt', '03-unsampled-move.txt', '02-rename.txt')
            ,@('01-rename.txt', '02-rename.txt', '03-unsampled-move.txt'))) {
            Send-AcceptanceChord -Process $mixedApplication.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x28 -Label 'public row Move Down Alt+Down'
            $deadline = (Get-Date).AddSeconds($WaitSeconds)
            do {
                $actualOrder = @(for ($index = 0; $index -lt 3; $index++) { $mixedGrid.pattern.GetItem($index, 0).Current.Name })
                if (@(Compare-Object -CaseSensitive $expectedOrder $actualOrder -SyncWindow 0).Count -eq 0) { break }
                Start-Sleep -Milliseconds 100
            } while ((Get-Date) -lt $deadline)
            if (@(Compare-Object -CaseSensitive $expectedOrder $actualOrder -SyncWindow 0).Count -ne 0) {
                throw 'Public Alt+Down did not establish the expected row order.'
            }
            $reorderInputs.Add([ordered]@{ input = 'physical-keyboard-alt-down'; observed_order = $actualOrder })
        }
        $prefixInput = Invoke-ObserverPrefix -Application $mixedApplication -Grid $mixedGrid -Prefix $mixedFixture.prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedFirstSourceName '01-rename.txt'
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        do {
            $mixedParentsSettled = $true
            $expectedParents = @($mixedFixture.parent_a, $mixedFixture.parent_a, $mixedFixture.parent_d)
            for ($index = 0; $index -lt 3; $index++) {
                if ($mixedGrid.pattern.GetItem($index, 2).Current.Name -cne $expectedParents[$index]) {
                    $mixedParentsSettled = $false
                    break
                }
            }
            if ($mixedParentsSettled) { break }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        if (-not $mixedParentsSettled) { throw 'Mixed preview did not preserve item-specific destination parents.' }
        $expectedStatuses = @('이름 변경 예정', '이름 변경 예정', '이동·이름 변경 예정')
        $mixedStatuses = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt 3; $index++) {
            $status = $mixedGrid.pattern.GetItem($index, 7).Current.Name
            if ($status -cne $expectedStatuses[$index]) {
                throw 'Mixed preview did not preserve two rename-only rows and one third move-plus-rename row.'
            }
            $mixedStatuses.Add([ordered]@{ row = $index; source = $mixedFixture.sources[$index]; destination = $mixedFixture.destinations[$index]; status = $status })
        }
        $mixedSelection = Set-ObserverSelectedRow -Application $mixedApplication -Grid $mixedGrid -Row 0 -SessionId $SessionId
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $mixedApplication.main -Process $mixedApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($mixedPrefix + '-preview.png') -Label 'mixed preview'))
        $mixedFullText = "변경 예시 전체 경로 (2/3개)`n`n현재 이름: 01-rename.txt`n변경 후 이름: $($mixedFixture.prefix)01-rename.txt`n현재 전체 경로: $($mixedFixture.sources[0])`n변경 후 전체 경로: $($mixedFixture.destinations[0])`n`n현재 이름: 02-rename.txt`n변경 후 이름: $($mixedFixture.prefix)02-rename.txt`n현재 전체 경로: $($mixedFixture.sources[1])`n변경 후 전체 경로: $($mixedFixture.destinations[1])"
        $mixedFullText += "`n`n[U+XXXX]는 원본 UTF-16 코드 단위의 표시이며 입력할 이름이 아닙니다. 대괄호와 원본 …도 코드로 표시합니다."
        $mixedConfirmation = Invoke-ObserverContextConfirmation -Application $mixedApplication -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 3개' -ExpectedFullText $mixedFullText -ExpectedDestinationParent '' -ExpectItemSpecificDestination -OutputRoot $EvidenceRoot -Prefix $mixedPrefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $mixedTreeText = [string]::Join("`n", @($mixedConfirmation.tree | ForEach-Object { $_.name } | Where-Object { $_ }))
        if ($mixedTreeText.IndexOf('03-unsampled-move.txt', [StringComparison]::Ordinal) -ge 0) {
            throw 'The two-of-three confirmation examples unexpectedly sampled the third moved row.'
        }
        $mixedAfterCancel = Get-ObserverFixtureState -FixtureRoot $mixedFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $mixedFixture.initial -Actual $mixedAfterCancel)) {
            throw 'Mixed confirmation cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $thirdSelection = Set-ObserverSelectedRow -Application $mixedApplication -Grid $mixedGrid -Row 2 -SessionId $SessionId
        $thirdDiagnosticText = "이동·이름 변경 예정`n`n현재 이름: 03-unsampled-move.txt`n변경 후 이름: $($mixedFixture.prefix)03-unsampled-move.txt`n현재 전체 경로: $($mixedFixture.sources[2])`n대상 전체 경로: $($mixedFixture.destinations[2])`n`n[U+XXXX]는 원본 UTF-16 코드 단위의 표시이며 입력할 이름이 아닙니다. 대괄호와 원본 …도 코드로 표시합니다.`n`n파일 시스템 검사와 실행 확인은 변경 적용 시 별도로 수행합니다."
        $thirdDiagnosticWindow = Open-ObserverDiagnosticKeyboard -Application $mixedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds
        $thirdDiagnostic = Inspect-ObserverDiagnostic -Window $thirdDiagnosticWindow -Application $mixedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedText $thirdDiagnosticText -OutputRoot $EvidenceRoot -Prefix ($mixedPrefix + '-third-destination') -CloseMethod escape -Captures $Captures
        $reentryConfirmation = Invoke-ObserverContextConfirmation -Application $mixedApplication -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 3개' -ExpectedFullText $mixedFullText -ExpectedDestinationParent '' -ExpectItemSpecificDestination -OutputRoot $EvidenceRoot -Prefix ($mixedPrefix + '-reentry') -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $firstExpanded = @($mixedConfirmation.expanded.tree | Where-Object { $_.automation_id -ceq 'ExpandedInformationText' })
        $secondExpanded = @($reentryConfirmation.expanded.tree | Where-Object { $_.automation_id -ceq 'ExpandedInformationText' })
        $expandedIdentityStable = $firstExpanded.Count -eq 1 -and $secondExpanded.Count -eq 1 -and $firstExpanded[0].name -ceq $secondExpanded[0].name
        if (-not $expandedIdentityStable) { throw 'Expanded plan fingerprint/list revision changed across cancellation, selected diagnostic, and reentry.' }
        $enterTrigger = Start-ObserverApplyFromPublicUi -Application $mixedApplication -SessionId $SessionId -Label 'mixed default Enter cancellation Apply command'
        $enterConfirmation = Wait-ObserverConfirmation -Application $mixedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'mixed default Enter cancellation confirmation'
        $enterHandle = [IntPtr]$enterConfirmation.Current.NativeWindowHandle
        $enterFocus = Get-ObserverConfirmationDefaultFocus -Application $mixedApplication -SessionId $SessionId
        if ([DarkReNamerVmAcceptanceNative]::IsWindowEnabled([IntPtr]$mixedApplication.main_handle)) { throw 'Default Enter confirmation owner remained enabled.' }
        Send-AcceptanceTap -Process $mixedApplication.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'mixed default Cancel Enter'
        Wait-WindowClosed -Handle $enterHandle -TimeoutSeconds $WaitSeconds -Label 'mixed default Enter cancellation confirmation'
        if ($null -ne $enterTrigger.invocation) { Complete-AutomationControlInvoke -State $enterTrigger.invocation -TimeoutSeconds $WaitSeconds }
        Wait-AcceptanceMainWindowForeground -Application $mixedApplication -WaitSeconds $WaitSeconds -Label 'mixed default Enter cancellation'
        $mixedAfterEnterCancel = Get-ObserverFixtureState -FixtureRoot $mixedFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $mixedFixture.initial -Actual $mixedAfterEnterCancel)) { throw 'Default Enter cancellation changed mixed fixture disk state.' }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $mixedExit = Close-AcceptanceApplication -Application $mixedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
        if ($rawLayoutCandidate) {
            Complete-VmAutomatedLayoutRun `
                -Run $rawMixedRun -Process $mixedApplication.process -ExitCode $mixedExit `
                -Screenshots @($Captures.ToArray() | Select-Object -Skip $rawCaptureStart)
            $rawLayoutRuns.Add($rawMixedRun)
        }
        [void](Complete-AcceptanceOwnedProcessJob -Owned $mixedApplication.owned)
        $mixedApplication.owned.process.Dispose()
        $mixedApplication = $null

        [ordered]@{
            raw_layout_runs = $rawLayoutRuns.ToArray()
            environment = $environment
            appearance = $appearanceSpec.evidence_name
            minimum_window = $minimum
            repeated = [ordered]@{
                inputs_in_admission_order = @('0 x101 -> 0 x100', 'a x100 -> a x101', '가 x100 -> 가 x101')
                selection = $selection
                zero_deletion_and_a_insertion_confirmation = $repeatedConfirmation
                korean_insertion_selection = $remainingSelection
                korean_insertion_confirmation = $remainingConfirmation
                cancellation_disk_unchanged = $true
                journal_residue_count = 0
                normal_exit_code = $repeatedExit
            }
            movement = [ordered]@{
                requested = 'C:\fixture\A\old.txt -> C:\fixture\B\new.txt'
                actual_source = $moveFixture.source
                actual_destination = $moveFixture.destination
                fixed_path_occupied = $moveFixture.fixed_path_occupied
                isolated_private_equivalent = $moveFixture.isolated_equivalent
                destination_input = $destinationInput
                move_only_selection = $moveOnlySelection
                move_only_confirmation = $moveOnlyConfirmation
                move_only_cancellation_disk_unchanged = $true
                selection = $moveSelection
                cancellation_confirmation = $moveConfirmation
                cancellation_disk_unchanged = $true
                actual_apply = [ordered]@{
                    entry = [ordered]@{ input = $actualApplyTrigger.input; menu_entry = $actualApplyTrigger.menu_entry }
                    tree = $actualTree
                    destination_context_visible = $actualDestinationVisible
                    reachability = $actualReachability
                    input = $actualApplyInput
                    target = $physicalApply
                    destination_reached = $true
                    content_preserved = $contentPreserved
                    identity_preserved = $identityPreserved
                    journal_residue_count = 0
                }
                appearance = $moveAppearance.evidence_name
                minimum_window = $moveMinimum
                normal_exit_code = $moveExit
            }
            mixed = [ordered]@{
                statuses = $mixedStatuses.ToArray()
                common_destination_parent = $null
                destination_parents = @($mixedFixture.parent_a, $mixedFixture.parent_a, $mixedFixture.parent_d)
                destination_input = $mixedDestinationInput
                later_admission_preserved_existing_destination = $true
                reorder_inputs = $reorderInputs.ToArray()
                prefix_input = $prefixInput
                selection = $mixedSelection
                confirmation = $mixedConfirmation
                two_of_three_examples_exclude_third_move = $true
                third_selection = $thirdSelection
                third_destination_diagnostic = $thirdDiagnostic
                reentry_confirmation = $reentryConfirmation
                expanded_plan_identity_stable = $expandedIdentityStable
                default_enter_cancellation = [ordered]@{
                    apply_entry = [ordered]@{ input = $enterTrigger.input; menu_entry = $enterTrigger.menu_entry }
                    default_focus = $enterFocus
                    owner_disabled = $true
                    input = 'keyboard-enter-on-default-cancel'
                    disk_unchanged = $true
                    journal_residue_count = 0
                }
                cancellation_disk_unchanged = $true
                journal_residue_count = 0
                appearance = $mixedAppearance.evidence_name
                minimum_window = $mixedMinimum
                normal_exit_code = $mixedExit
            }
        }
    }
    catch {
        $scenarioError = $_
        throw
    }
    finally {
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        foreach ($application in @($repeatedApplication, $moveApplication, $mixedApplication)) {
            if ($null -eq $application) { continue }
            try { Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned }
            catch { $cleanupErrors.Add($_.Exception.Message) }
        }
        if ($cleanupErrors.Count -gt 0) {
            if ($null -ne $scenarioError) {
                throw "$($scenarioError.Exception.Message) Cleanup: $($cleanupErrors -join '; ')"
            }
            throw ($cleanupErrors -join '; ')
        }
    }
}
function Invoke-ObserverStandardScenario {
    param(
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $Appearance,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [AllowNull()][Collections.Generic.List[object]] $ProcessLifecycleObservations
    )
    $fixture = New-ObserverStandardFixture -RuntimeRoot $RuntimeRoot
    $rawLayoutCandidate = $Verified.lane -ceq 'candidate-gui-only'
    $application = $null
    $rawLayoutRun = $null
    $rawCaptureStart = $Captures.Count
    try {
        $applicationPath = Join-Path $Verified.root $Verified.application.file
        if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.application.sha256) {
            throw 'Application changed after bundle verification.'
        }
        $application = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'standard GUI regression application' -ProcessLifecycleObservations $ProcessLifecycleObservations
        $appearanceSpec = Set-AcceptanceAppearance -Process $application.process -ExpectedSession $SessionId -MainWindowHandle ([IntPtr]$application.main_handle) -Appearance $Appearance
        $minimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $application.main -Process $application.process -ExpectedSession $SessionId
        $environment = Get-ObserverEnvironmentMetadata -Application $application
        $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $application.main
        $environment['system_visual_style'] = Get-ObserverSystemVisualStyle
        $requested = $script:contract.requested_small_workspace
        $requestedModePrefix = '{0}x{1}@' -f $requested.width,$requested.height
        $environment['requested_small_workspace'] = [ordered]@{
            width = [int]$requested.width
            height = [int]$requested.height
            actual_screen_matches = $environment.physical_screen.width -eq $requested.width -and $environment.physical_screen.height -eq $requested.height
            display_mode_advertised = @($environment.display_mode_inventory.values | Where-Object { $_.StartsWith($requestedModePrefix, [StringComparison]::Ordinal) }).Count -gt 0
            status = if ($environment.physical_screen.width -eq $requested.width -and $environment.physical_screen.height -eq $requested.height) { 'observed-exact' } else { 'not-available-in-current-managed-session' }
            mutation_attempted = $false
        }
        if ($minimum.dpi -ne $script:contract.expected_dpi -or $environment.hwnd_dpi -ne $script:contract.expected_dpi -or
            $environment.text_scale_factor_percent -ne $script:contract.expected_text_scale_percent -or
            -not $environment.requested_small_workspace.actual_screen_matches) {
            $environment['failure_classification'] = 'environment_blocked'
            $environment['failure_reason'] = if (-not $environment.requested_small_workspace.actual_screen_matches) {
                'requested_and_actual_target_monitor_geometry_differ'
            } elseif ($environment.text_scale_factor_percent -ne $script:contract.expected_text_scale_percent) {
                'actual_and_requested_text_scale_differ'
            } elseif ($minimum.dpi -ne $script:contract.expected_dpi) {
                'minimum_window_and_requested_dpi_differ'
            } else { 'main_hwnd_and_requested_dpi_differ' }
            $environment['requested_dpi'] = [int]$script:contract.expected_dpi
            $environment['requested_text_scale_factor_percent'] = [int]$script:contract.expected_text_scale_percent
            $environment['minimum_window_dpi'] = [int]$minimum.dpi
            Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot 'environment-preflight.json') -Value $environment
            throw ("environment_blocked: requested {0}x{1}@{2}, observed target monitor {3}x{4}, minimum DPI {5}, main HWND DPI {6}; standard matrix was not started." -f `
                $requested.width, $requested.height, $script:contract.expected_dpi, $environment.physical_screen.width, $environment.physical_screen.height, $minimum.dpi, $environment.hwnd_dpi)
        }
        Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot 'environment-preflight.json') -Value $environment
        $prefix = 'after-standard-{0}-{1}' -f $Appearance,$minimum.dpi
        $import = Import-GuiRegressionPathList -Application $application -PathsFile $fixture.paths_file -ExpectedRows 3 -SessionId $SessionId -WaitSeconds $WaitSeconds
        $grid = $import.grid
        if ($rawLayoutCandidate) {
            $rawLayoutRun = New-VmAutomatedLayoutRun `
                -Application $application -ApplicationPath $applicationPath `
                -FixtureRoot $fixture.root -Grid $grid -ExpectedSession $SessionId `
                -TimeoutSeconds $WaitSeconds -LayoutVariant $script:contract.layout_variant
        }
        $importMs = $import.elapsed_ms
        $prefixRasterTarget = Set-ObserverManualName -Application $application -Grid $grid -Row 0 -Name $fixture.destination_names[0] -SessionId $SessionId -WaitSeconds $WaitSeconds -CaptureRoot $EvidenceRoot -CaptureLeaf ($prefix + '-editable-input-prompt.png') -Captures $Captures
        Set-ObserverManualName -Application $application -Grid $grid -Row 1 -Name $fixture.destination_names[1] -SessionId $SessionId -WaitSeconds $WaitSeconds
        $selection = Set-ObserverSelectedRow -Application $application -Grid $grid -Row 0 -SessionId $SessionId
        if ($grid.pattern.GetItem(0, 1).Current.Name -cne $fixture.destination_names[0] -or
            $grid.pattern.GetItem(1, 1).Current.Name -cne $fixture.destination_names[1] -or
            $grid.pattern.GetItem(2, 1).Current.Name -cne $fixture.source_names[2]) {
            throw 'The exact 3/1/2 preview did not settle.'
        }
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $application.main -Process $application.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($prefix + '-minimum-preview.png') -Label 'minimum-size long-name preview'))
        $fullText = "변경 예시 전체 경로 (2/2개)`n`n현재 이름: $($fixture.source_names[0])`n변경 후 이름: $($fixture.destination_names[0])`n현재 전체 경로: $($fixture.paths[0])`n변경 후 전체 경로: $($fixture.destinations[0])`n`n현재 이름: $($fixture.source_names[1])`n변경 후 이름: $($fixture.destination_names[1])`n현재 전체 경로: $($fixture.paths[1])`n변경 후 전체 경로: $($fixture.destinations[1])"
        $fullText += "`n`n[U+XXXX]는 원본 UTF-16 코드 단위의 표시이며 입력할 이름이 아닙니다. 대괄호와 원본 …도 코드로 표시합니다."
        $confirmation = Invoke-ObserverContextConfirmation -Standard -Application $application -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 2개' -ExpectedFullText $fullText -ExpectedDestinationParent '' -OutputRoot $EvidenceRoot -Prefix $prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $afterCancel = Get-ObserverFixtureState -FixtureRoot $fixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $fixture.initial -Actual $afterCancel)) {
            throw 'Apply cancellation changed a name, content digest, or NTFS identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $blocked = if ($script:contract.expected_text_scale_percent -eq 150) {
            [ordered]@{ status = 'not-run'; reason = 'covered-by-paired-text100-standard-run' }
        }
        else {
            Invoke-ObserverBlockedChecks -Application $application -Grid $grid -Fixture $fixture -OutputRoot $EvidenceRoot -Prefix $prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -Captures $Captures
        }
        $actualApply = Invoke-ObserverActualApply -Application $application -Grid $grid -Fixture $fixture -OutputRoot $EvidenceRoot -Prefix $prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -Captures $Captures
        $exitCode = Close-AcceptanceApplication -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
        if ($rawLayoutCandidate) {
            Complete-VmAutomatedLayoutRun `
                -Run $rawLayoutRun -Process $application.process -ExitCode $exitCode `
                -Screenshots @($Captures.ToArray() | Select-Object -Skip $rawCaptureStart)
        }
        [ordered]@{
            raw_layout_runs = @($rawLayoutRun)
            environment = $environment
            fixture = [ordered]@{
                count = 3; selected = 1; changed = 2
                sources = $fixture.paths; destinations = $fixture.destinations
                same_leaf_different_parent = $fixture.paths[0].EndsWith($fixture.source_names[2], [StringComparison]::Ordinal) -and $fixture.paths[2].EndsWith($fixture.source_names[2], [StringComparison]::Ordinal)
                long_korean_supplementary = $fixture.source_names[0].IndexOf('😀', [StringComparison]::Ordinal) -ge 0
            }
            timings_ms = [ordered]@{ import = $importMs }
            appearance = $appearanceSpec.evidence_name
            minimum_window = $minimum
            selection = $selection
            confirmation = $confirmation
            text_raster_targets = @($prefixRasterTarget, $confirmation.full_details.text_raster_target)
            blocking = $blocked
            actual_apply = $actualApply
            cancellation_disk_unchanged = $true
            journal_residue_count = 0
            normal_exit_code = $exitCode
        }
    }
    finally {
        if ($null -ne $application) {
            Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned
        }
    }
}

# A diagnostic scene retains one application process while only the app appearance changes.
function Get-ObserverAppearanceColumnPreferenceBytes {
    # Exact ui-columns-v1 format in preferences.rs: header, seven six-byte
    # column records, then a little-endian FNV-1a checksum.
    $bytes = [byte[]]::new(58)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('DRCOLS'), $bytes, 6)
    $bytes[8] = 1; $bytes[9] = 7
    $widths = @(900, 900, 260, 120, 80, 120, 120)
    for ($index = 0; $index -lt 7; $index++) {
        $offset = 12 + 6 * $index
        if ($index -lt 3) { $bytes[$offset] = 1; $bytes[$offset + 1] = 1 }
        $widthBytes = [BitConverter]::GetBytes([int]$widths[$index])
        if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($widthBytes) }
        [Array]::Copy($widthBytes, 0, $bytes, $offset + 2, 4)
    }
    $hash = [uint32]2166136261
    for ($index = 0; $index -lt 54; $index++) {
        $hash = [uint32]((([uint64]($hash -bxor [uint32]$bytes[$index])) * [uint64]16777619) -band [uint64]4294967295)
    }
    $checksum = [BitConverter]::GetBytes($hash)
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($checksum) }
    [Array]::Copy($checksum, 0, $bytes, 54, 4)
    ,$bytes
}
function Assert-ObserverAppearanceColumnPreference {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][byte[]] $ExpectedBytes)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -ne $ExpectedBytes.Length) { throw 'Appearance column preference changed.' }
    $actual = [IO.File]::ReadAllBytes($item.FullName)
    if (-not [Linq.Enumerable]::SequenceEqual[byte]($actual, $ExpectedBytes)) {
        throw 'Appearance column preference changed.'
    }
    Get-LowerSha256 -Path $item.FullName
}
function Assert-ObserverAppearancePrivateAppDirectory {
    param([Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier] $UserSid)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Appearance private app directory is unsafe.'
    }
    $actual = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($item.FullName))
    if ($actual.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $UserSid.Value -or
        -not $actual.AreAccessRulesProtected) {
        throw 'Appearance private app directory owner or DACL differs from production.'
    }
    $expected = @($UserSid.Value, 'S-1-5-18', 'S-1-5-32-544')
    $rules = @($actual.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    if ($rules.Count -ne $expected.Count) {
        throw 'Appearance private app directory owner or DACL differs from production.'
    }
    foreach ($rule in $rules) {
        $sid = ([Security.Principal.SecurityIdentifier]$rule.IdentityReference).Value
        if ($sid -cnotin $expected -or $rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne $inheritance -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) {
            throw 'Appearance private app directory owner or DACL differs from production.'
        }
        $expected = @($expected | Where-Object { $_ -cne $sid })
    }
    if ($expected.Count -ne 0) {
        throw 'Appearance private app directory owner or DACL differs from production.'
    }
}
function New-ObserverAppearancePrivateAppDirectory {
    param([Parameter(Mandatory)][string] $Parent)

    $path = Join-Path $Parent 'DarkReNamer'
    if (-not $IsWindows) {
        # Ubuntu fixture tests cannot execute the Windows ACL API or the product.
        return New-PrivateDirectory -Parent $Parent -Leaf 'DarkReNamer'
    }
    if (Test-Path -LiteralPath $path) {
        throw 'Appearance private app directory already exists.'
    }
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($userSid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($principal in @($userSid,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $principal, [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    # The descriptor is supplied at creation so no inherited, unsafe interval exists.
    [void][IO.FileSystemAclExtensions]::CreateDirectory($security, $path)
    Assert-ObserverAppearancePrivateAppDirectory -Path $path -UserSid $userSid
    $path
}
function New-ObserverAppearanceColumnPreference {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $expectedLocalData = Join-Path $RuntimeRoot 'localappdata'
    if (-not [string]::Equals([IO.Path]::GetFullPath($env:LOCALAPPDATA),
        [IO.Path]::GetFullPath($expectedLocalData), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Appearance preference requires isolated LOCALAPPDATA.'
    }
    $appRoot = New-ObserverAppearancePrivateAppDirectory -Parent $expectedLocalData
    $path = Join-Path $appRoot 'ui-columns-v1'
    if (Test-Path -LiteralPath $path) { throw 'Appearance column preference already exists.' }
    $bytes = Get-ObserverAppearanceColumnPreferenceBytes
    [IO.File]::WriteAllBytes($path, $bytes)
    [ordered]@{
        source = 'isolated-persisted-user-settings'; path = $path; format_version = 1
        primary_width_dip = @(900, 900, 260)
        sha256 = Assert-ObserverAppearanceColumnPreference -Path $path -ExpectedBytes $bytes
    }
}
function Get-ObserverAppearanceColumnWidthsPx {
    param([Parameter(Mandatory)][int] $Dpi)
    if ($Dpi -notin @(96, 120, 144, 192)) { throw 'Unsupported appearance fixture DPI.' }
    @(900, 900, 260) | ForEach-Object { [int][Math]::Floor(($_ * $Dpi + 48) / 96.0) }
}
function Get-ObserverAppearanceDefaultPrimaryWidthsPx {
    param([Parameter(Mandatory)][int] $ClientWidth,
        [Parameter(Mandatory)][int] $StatusWidth,
        [Parameter(Mandatory)][int] $Dpi)
    # Mirrors allocate_primary_column_widths for untouched default settings.
    $scale = { param([int] $dip) [int][Math]::Floor(($dip * $Dpi + 48) / 96.0) }
    $budget = [Math]::Max(0, $ClientWidth - [Math]::Max(0, $StatusWidth) - [Math]::Max(1, (& $scale 1)))
    $minimum = @((& $scale 120), (& $scale 120), (& $scale 80))
    $minimumTotal = [int]($minimum[0] + $minimum[1] + $minimum[2])
    if ($budget -lt $minimumTotal) {
        # The production fallback keeps its minima and allows overflow.
        return $minimum
    }
    $surplus = $budget - $minimumTotal
    $share = [int][Math]::Floor($surplus / 5.0)
    $widths = [int[]]@(($minimum[0] + 2 * $share), ($minimum[1] + 2 * $share), ($minimum[2] + $share))
    foreach ($index in @(0, 1, 2, 0, 1) | Select-Object -First ($surplus % 5)) { $widths[$index]++ }
    $widths
}
function Get-ObserverAppearanceTransitionSnapshot {
    param([Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][string] $ExecutableSha256,
        [Parameter(Mandatory)][string] $ColumnPreferencePath,
        [Parameter(Mandatory)][byte[]] $ExpectedPreferenceBytes,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][ValidateSet('before_dark','after_dark','before_light','after_light')][string] $Phase)
    $listHandle = [IntPtr]$Grid.element.Current.NativeWindowHandle
    $rendering = Get-ObserverAppearanceRenderingEnvironment -Application $Application
    # Capture the committed viewport before any UIA row lookup, which may
    # realize an offscreen item in some providers. Reject observer side effects.
    $horizontal = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 0))
    $vertical = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 1))
    $topIndex = [DarkReNamerVmAcceptanceNative]::ReadBoundListViewTopIndex($listHandle, [uint32]$Application.process.Id)
    $names = [Collections.Generic.List[string]]::new()
    $values = [Collections.Generic.List[object]]::new()
    $rowCount = [int]$Grid.pattern.Current.RowCount
    $columnCount = [int]$Grid.pattern.Current.ColumnCount
    if ($rowCount -ne 60 -or $columnCount -ne 8) {
        throw 'Transition preservation requires sixty rows and eight native columns.'
    }
    for ($index = 0; $index -lt $rowCount; $index++) {
        $row = [string[]]::new($columnCount)
        for ($column = 0; $column -lt $columnCount; $column++) {
            $row[$column] = [string]$Grid.pattern.GetItem($index, $column).Current.Name
        }
        $names.Add($row[0]); $values.Add($row)
    }
    $textScale = [double][DarkReNamerTextScaleNative]::ReadTextScaleFactor()
    if ([double]::IsNaN($textScale) -or $textScale -lt 1.0 -or $textScale -gt 2.25) {
        throw 'Transition text scale is outside the supported range.'
    }
    $snapshot = [ordered]@{
        phase = $Phase; appearance = if ($Phase -in @('after_dark','before_light')) { 'dark' } else { 'light' }
        executable_sha256 = $ExecutableSha256
        column_preference_sha256 = Assert-ObserverAppearanceColumnPreference -Path $ColumnPreferencePath -ExpectedBytes $ExpectedPreferenceBytes
        process_id = [int]$Application.process.Id
        main_handle = [long]$Application.main_handle
        list_handle = $listHandle.ToInt64()
        client_bounds = $rendering.client
        list_client_bounds = @([DarkReNamerVmAcceptanceNative]::ReadBoundListViewClientBounds($listHandle, [uint32]$Application.process.Id))
        dpi = [int]$rendering.hwnd_dpi
        text_scale_percent = [int][Math]::Round($textScale * 100.0)
        columns = @(0..7 | ForEach-Object { [DarkReNamerVmAcceptanceNative]::ReadListViewColumnWidth($listHandle, $_) })
        column_order = @([DarkReNamerVmAcceptanceNative]::ReadBoundHeaderColumnOrder($listHandle, [uint32]$Application.process.Id))
        row_count = $rowCount; column_count = $columnCount
        current_names = $names.ToArray(); row_values = $values.ToArray()
        selection = Get-ObserverAppearanceSelection -Grid $Grid
        horizontal_scroll = $horizontal
        vertical_scroll = $vertical
        top_index = $topIndex
        native_focus = @([DarkReNamerVmAcceptanceNative]::ReadGuiThreadSnapshot([IntPtr]$Application.main_handle, [uint32]$Application.process.Id))
        appearance_menu = Get-VmAutomatedAppearance -Window $Application.main -Process $Application.process -ExpectedSession $SessionId
    }
    $afterRead = [ordered]@{
        horizontal_scroll = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 0))
        vertical_scroll = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 1))
        top_index = [DarkReNamerVmAcceptanceNative]::ReadBoundListViewTopIndex($listHandle, [uint32]$Application.process.Id)
    }
    $snapshot['observer_read_native_after'] = $afterRead
    $snapshot['observer_read_preserved'] = ((@($snapshot.horizontal_scroll[0..3]) -join ',') -ceq (@($afterRead.horizontal_scroll[0..3]) -join ',') -and
        (@($snapshot.vertical_scroll[0..3]) -join ',') -ceq (@($afterRead.vertical_scroll[0..3]) -join ',') -and
        $snapshot.top_index -eq $afterRead.top_index)
    $snapshot
}
function Assert-ObserverAppearanceTransitionEqual {
    param([Parameter(Mandatory)][object] $Before,
        [Parameter(Mandatory)][object] $After)
    foreach ($axis in @('horizontal_scroll', 'vertical_scroll')) {
        $first = @($Before.$axis); $second = @($After.$axis)
        if ($first.Count -ne 5 -or $second.Count -ne 5 -or $first[2] -le 0 -or
            $first[1] - $first[0] + 1 -le $first[2] -or
            $first[3] -le $first[0] -or $first[3] -gt ($first[1] - $first[2] + 1) -or
            (($first[0..3] -join ',') -cne ($second[0..3] -join ','))) {
            throw "Transition preservation changed or lacked nonminimum $axis native range/position."
        }
    }
    foreach ($field in @('executable_sha256','column_preference_sha256','process_id','main_handle','list_handle','dpi',
            'text_scale_percent','row_count','column_count','top_index')) {
        if ($Before.$field -cne $After.$field) { throw "Transition preservation changed $field." }
    }
    foreach ($field in @('columns','column_order','list_client_bounds','current_names')) {
        if ((@($Before.$field) -join "`0") -cne (@($After.$field) -join "`0")) {
            throw "Transition preservation changed $field."
        }
    }
    if (@($Before.row_values).Count -ne 60 -or @($After.row_values).Count -ne 60) {
        throw 'Transition preservation row values are incomplete.'
    }
    for ($row = 0; $row -lt 60; $row++) {
        if (@($Before.row_values[$row]).Count -ne 8 -or @($After.row_values[$row]).Count -ne 8) {
            throw 'Transition preservation row values are incomplete.'
        }
        for ($column = 0; $column -lt 8; $column++) {
            if ($Before.row_values[$row][$column] -cne $After.row_values[$row][$column]) {
                throw 'Transition preservation changed a row value.'
            }
        }
    }
    foreach ($field in @('left','top','right','bottom','width','height')) {
        if ($Before.client_bounds.$field -ne $After.client_bounds.$field) {
            throw 'Transition preservation changed client bounds.'
        }
    }
    if ($Before.selection.count -ne $After.selection.count -or
        $Before.selection.name -cne $After.selection.name) {
        throw 'Transition preservation changed selected row identity.'
    }
}
function Assert-ObserverAppearanceTransitionPhase {
    param([Parameter(Mandatory)][object] $Snapshot,
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][string] $Appearance)
    if ($Snapshot.phase -cne $Phase -or $Snapshot.appearance -cne $Appearance) {
        throw "Transition preservation missing or reordered $Phase observation."
    }
    if ($Snapshot.observer_read_preserved -ne $true) {
        throw 'Transition snapshot UIA reads moved the native viewport.'
    }
}
function Invoke-ObserverAppearanceTransitionPreservation {
    param([Parameter(Mandatory)][scriptblock] $ReadSnapshot,
        [Parameter(Mandatory)][scriptblock] $SetAppearance,
        [Parameter(Mandatory)][Collections.IDictionary] $ObservationSink,
        [Parameter(Mandatory)][object] $Fixture)
    $probe = [ordered]@{
        snapshot_order = @('before_dark','after_dark','before_light','after_light')
        fixture = $Fixture
        observations = [Collections.Generic.List[object]]::new()
        check = [ordered]@{ status = 'pending'; reason = $null }
    }
    $ObservationSink['transition_preservation'] = $probe
    try {
        $beforeDark = & $ReadSnapshot 'before_dark'
        $probe.observations.Add($beforeDark)
        Assert-ObserverAppearanceTransitionPhase -Snapshot $beforeDark -Phase 'before_dark' -Appearance 'light'
        Assert-ObserverAppearanceTransitionEqual -Before $beforeDark -After $beforeDark
        & $SetAppearance 'dark'
        $afterDark = & $ReadSnapshot 'after_dark'
        $probe.observations.Add($afterDark)
        Assert-ObserverAppearanceTransitionPhase -Snapshot $afterDark -Phase 'after_dark' -Appearance 'dark'
        Start-Sleep -Milliseconds 150
        $settledDark = & $ReadSnapshot 'after_dark'
        Assert-ObserverAppearanceTransitionPhase -Snapshot $settledDark -Phase 'after_dark' -Appearance 'dark'
        $afterDark['settlement'] = [ordered]@{
            horizontal_scroll = @($settledDark.horizontal_scroll)
            vertical_scroll = @($settledDark.vertical_scroll)
            top_index = $settledDark.top_index
        }
        Assert-ObserverAppearanceTransitionEqual -Before $afterDark -After $settledDark
        $afterDark['settled'] = $true
        Assert-ObserverAppearanceTransitionEqual -Before $beforeDark -After $afterDark
        $afterDark['command_focus_transfer'] = [ordered]@{
            before_control_id = [long]$beforeDark.native_focus[2]
            after_control_id = [long]$afterDark.native_focus[2]
        }
        $beforeLight = & $ReadSnapshot 'before_light'
        $probe.observations.Add($beforeLight)
        Assert-ObserverAppearanceTransitionPhase -Snapshot $beforeLight -Phase 'before_light' -Appearance 'dark'
        Assert-ObserverAppearanceTransitionEqual -Before $afterDark -After $beforeLight
        & $SetAppearance 'light'
        $afterLight = & $ReadSnapshot 'after_light'
        $probe.observations.Add($afterLight)
        Assert-ObserverAppearanceTransitionPhase -Snapshot $afterLight -Phase 'after_light' -Appearance 'light'
        Start-Sleep -Milliseconds 150
        $settledLight = & $ReadSnapshot 'after_light'
        Assert-ObserverAppearanceTransitionPhase -Snapshot $settledLight -Phase 'after_light' -Appearance 'light'
        $afterLight['settlement'] = [ordered]@{
            horizontal_scroll = @($settledLight.horizontal_scroll)
            vertical_scroll = @($settledLight.vertical_scroll)
            top_index = $settledLight.top_index
        }
        Assert-ObserverAppearanceTransitionEqual -Before $afterLight -After $settledLight
        $afterLight['settled'] = $true
        Assert-ObserverAppearanceTransitionEqual -Before $beforeLight -After $afterLight
        $afterLight['command_focus_transfer'] = [ordered]@{
            before_control_id = [long]$beforeLight.native_focus[2]
            after_control_id = [long]$afterLight.native_focus[2]
        }
        $probe.check.status = 'passed'
        $probe
    }
    catch {
        $probe.check.status = 'failed'; $probe.check.reason = $_.Exception.Message
        throw
    }
}
function Get-ObserverAppearanceDefaultColumnState {
    param([Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds)
    $listHandle = [IntPtr]$Grid.element.Current.NativeWindowHandle
    $candidateProcessId = [uint32]$Application.process.Id
    $allWidths = @(0..7 | ForEach-Object { [DarkReNamerVmAcceptanceNative]::ReadListViewColumnWidth($listHandle, $_) })
    $order = @([DarkReNamerVmAcceptanceNative]::ReadBoundHeaderColumnOrder($listHandle, $candidateProcessId))
    $clientBounds = @([DarkReNamerVmAcceptanceNative]::ReadBoundListViewClientBounds($listHandle, $candidateProcessId))
    $clientWidth = $clientBounds[2] - $clientBounds[0]
    $rendering = Get-ObserverAppearanceRenderingEnvironment -Application $Application
    $expected = @(Get-ObserverAppearanceDefaultPrimaryWidthsPx -ClientWidth $clientWidth -StatusWidth $allWidths[7] -Dpi $rendering.hwnd_dpi)
    if ($allWidths.Count -ne 8 -or $expected.Count -ne 3 -or
        (($allWidths[0..2] -join ',') -cne ($expected -join ',')) -or
        (@($allWidths[3..6] | Where-Object { $_ -ne 0 }).Count -ne 0) -or
        $allWidths[7] -lt [int][Math]::Floor((112 * $rendering.hwnd_dpi + 48) / 96.0) -or
        (($order -join ',') -cne '0,1,2,3,4,5,6,7')) {
        throw 'Clean-start native columns differ from automatic default allocation.'
    }
    if ([int]$Grid.pattern.Current.RowCount -ne 1) { throw 'Clean-start default scene requires one unchanged row.' }
    $current = $Grid.pattern.GetItem(0, 0)
    $proposed = $Grid.pattern.GetItem(0, 1)
    $currentName = [string]$current.Current.Name
    if ($currentName -cne [string]$proposed.Current.Name) {
        throw 'Clean-start default row unexpectedly changed its proposed name.'
    }
    $apply = Get-ObserverPublicApplyState -Application $Application -SessionId $SessionId -Label 'clean-start default Apply'
    if ($apply.enabled) { throw 'Clean-start default row enables Apply without a change.' }
    $status = Find-UniqueAutomationElement -Root $Application.main -Process $Application.process -ExpectedSession $SessionId `
        -AutomationId '1007' -ControlType ([Windows.Automation.ControlType]::Text) -TimeoutSeconds $WaitSeconds `
        -Label 'clean-start default status' -RequireWindowHandle
    [ordered]@{
        column_origin = 'clean-start-default'
        columns = @($allWidths[0..2])
        runtime_columns = [ordered]@{ status_width_px = [int]$allWidths[7]; optional_widths = @($allWidths[3..6]) }
        column_visibility = @(0..7 | ForEach-Object { [bool]($allWidths[$_] -gt 0) })
        column_order = $order
        list_client_bounds = $clientBounds; list_client_width = $clientWidth
        row_count = 1; current_names = @($currentName); proposed_name = [string]$proposed.Current.Name
        current_name_cell = Get-ElementObservation -Element $current
        proposed_name_cell = Get-ElementObservation -Element $proposed
        apply_enabled = $false; status = [string]$status.Current.Name
        selection = Get-ObserverAppearanceSelection -Grid $Grid
        horizontal_scroll = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 0))
        vertical_scroll = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 1))
        target_rendering = $rendering
        appearance_menu = Get-VmAutomatedAppearance -Window $Application.main -Process $Application.process -ExpectedSession $SessionId
        list = Get-ElementObservation -Element $Grid.element
        native_list = Get-ObserverNativeWindowMetrics -Window $Grid.element
        native_header = Get-ObserverNativeWindowMetrics -Window ([Windows.Automation.AutomationElement]::FromHandle(
            [DarkReNamerVmAcceptanceNative]::ReadBoundListHeader($listHandle, $candidateProcessId)))
        window = Get-ObserverNativeWindowMetrics -Window $Application.main
    }
}
function Invoke-ObserverAppearanceDefaultColumnsScene {
    param([Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $PathsFile,
        [Parameter(Mandatory)][string] $RowName,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string[]] $FixturePaths,
        [Parameter(Mandatory)][object] $ExpectedFixtureState,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][object] $ExpectedEnvironment,
        [Parameter(Mandatory)][int] $CustomProcessId,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [AllowNull()][Collections.Generic.List[object]] $ProcessLifecycleObservations,
        [Parameter(Mandatory)][Collections.IDictionary] $ObservationSink)
    $scene = [ordered]@{
        fixture = [ordered]@{
            source = 'clean-start-default'; settings_path_kind = 'isolated-localappdata'
            settings_absent_before_launch = $false; row_name = $RowName
            disk_unchanged = $false; journal_residue_count = $null
        }
        process_id = $null; main_handle = $null; executable_sha256 = $Verified.application.sha256
        steps = [Collections.Generic.List[object]]::new(); normal_exit_code = $null
        check = [ordered]@{ status = 'pending'; reason = $null }
    }
    $ObservationSink['default_columns'] = $scene
    $application = $null
    $priorLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', 'Process')
    try {
        $root = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'appearance-default-columns'
        $localAppData = New-PrivateDirectory -Parent $root -Leaf 'localappdata'
        $settings = Join-Path (Join-Path $localAppData 'DarkReNamer') 'ui-columns-v1'
        if ((Test-Path -LiteralPath $settings) -or
            @((Get-ChildItem -LiteralPath $localAppData -Force)).Count -ne 0) {
            throw 'Clean-start default columns were preseeded.'
        }
        $scene.fixture.settings_absent_before_launch = $true
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData, 'Process')
        $applicationPath = Join-Path $Verified.root $Verified.application.file
        if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.application.sha256) {
            throw 'Clean-start default application bytes differ from verified executable.'
        }
        $application = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root `
            -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'clean-start default application' `
            -ProcessLifecycleObservations $ProcessLifecycleObservations
        $scene.process_id = [int]$application.process.Id
        $scene.main_handle = [long]$application.main_handle
        if ($scene.process_id -eq $CustomProcessId) { throw 'Clean-start default scene reused the custom-column process.' }
        $minimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $application.main -Process $application.process -ExpectedSession $SessionId
        $environment = Get-ObserverEnvironmentMetadata -Application $application
        if ($environment.physical_screen.width -ne $ExpectedEnvironment.physical_screen.width -or
            $environment.physical_screen.height -ne $ExpectedEnvironment.physical_screen.height -or
            $environment.hwnd_dpi -ne $ExpectedEnvironment.hwnd_dpi -or
            $environment.text_scale_factor_percent -ne $ExpectedEnvironment.text_scale_factor_percent -or
            $minimum.dpi -ne $ExpectedEnvironment.hwnd_dpi) {
            throw 'environment_blocked: clean-start default display, DPI, or text scale differs.'
        }
        $grid = Get-ObserverGrid -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds
        $scene.fixture['startup_columns'] = @(0..7 | ForEach-Object {
            [DarkReNamerVmAcceptanceNative]::ReadListViewColumnWidth([IntPtr]$grid.element.Current.NativeWindowHandle, $_)
        })
        [void](Import-GuiRegressionPathList -Application $application -PathsFile $PathsFile -ExpectedRows 1 `
            -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid)
        foreach ($step in @('light-before','dark','light-after')) {
            $appearance = if ($step -eq 'dark') { 'dark' } else { 'light' }
            [void](Set-AcceptanceAppearance -Process $application.process -ExpectedSession $SessionId `
                -MainWindowHandle ([IntPtr]$application.main_handle) -Appearance $appearance)
            Start-Sleep -Milliseconds 150
            $overlay = Assert-ObserverAppearanceNoTooltip -Application $application
            $state = Get-ObserverAppearanceDefaultColumnState -Application $application -Grid $grid `
                -SessionId $SessionId -WaitSeconds $WaitSeconds
            $state['overlay'] = $overlay
            if ($state.current_names[0] -cne $RowName) { throw 'Clean-start default row differs from owned fixture.' }
            $leaf = "appearance-default-columns-$step.png"
            $capture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
                -Window $application.main -Process $application.process -ExpectedSession $SessionId `
                -Root $EvidenceRoot -Leaf $leaf -Label "appearance default columns $step"
            $Captures.Add((Add-AcceptanceScreenshotContext -Screenshot $capture -Appearance $appearance -Surface 'main-workbench'))
            $scene.steps.Add([ordered]@{ phase = $step; appearance = $appearance; state = $state; capture = $capture })
        }
        $scene.normal_exit_code = Close-AcceptanceApplication -Application $application -SessionId $SessionId `
            -WaitSeconds $WaitSeconds -CloseInput ordinary
        $after = Get-ObserverAppearanceFixtureState -Root $FixtureRoot -Paths $FixturePaths
        if (-not (Test-ObserverFixtureStateEqual -Expected $ExpectedFixtureState -Actual $after)) {
            throw 'Clean-start default scene changed the owned fixture files.'
        }
        $scene.fixture.disk_unchanged = $true
        Assert-NoJournalResidue -LocalAppData $localAppData
        $scene.fixture.journal_residue_count = 0
        $scene.check.status = 'passed'
        $scene
    }
    catch {
        $scene.check.status = 'failed'; $scene.check.reason = $_.Exception.Message
        throw
    }
    finally {
        try { if ($null -ne $application) { Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned } }
        finally { [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $priorLocalAppData, 'Process') }
    }
}
function Assert-ObserverAppearanceNoTooltip {
    param([Parameter(Mandatory)][object] $Application)
    $bounds = $Application.main.Current.BoundingRectangle
    $x = [int][Math]::Floor($bounds.Left + $bounds.Width / 2.0)
    $y = [int][Math]::Floor($bounds.Top + [Math]::Min(10.0, $bounds.Height / 2.0))
    [DarkReNamerVmAcceptanceNative]::MoveCursor($x, $y)
    Start-Sleep -Milliseconds 600
    $visible = @(Get-ObserverProcessWindows -Process $Application.process | Where-Object {
        $_.visible -and $_.class_name -ieq 'tooltips_class32'
    })
    if ($visible.Count -gt 3) { throw 'Appearance owned tooltip inventory exceeds the bounded fixture.' }
    $dismissed = $visible.Count
    foreach ($tooltip in $visible) {
        [DarkReNamerVmAcceptanceNative]::PopOwnedTooltip([IntPtr][long]$tooltip.hwnd, [uint32]$Application.process.Id)
    }
    if ($dismissed -gt 0) { Start-Sleep -Milliseconds 150 }
    $remaining = @(Get-ObserverProcessWindows -Process $Application.process | Where-Object {
        $_.visible -and $_.class_name -ieq 'tooltips_class32'
    })
    if ($remaining.Count -ne 0) { throw 'Appearance capture has a visible owned tooltip after native dismissal.' }
    [ordered]@{ visible_tooltip_count = 0; neutral_cursor = $true; dismissed_tooltip_count = $dismissed }
}
function Get-ObserverAppearanceFixtureState {
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string[]] $Paths)
    $parent = Split-Path -Parent $Paths[0]
    $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if ($Paths.Count -ne 60 -or
        @((Get-ChildItem -LiteralPath $Root -Force)).Count -ne 1 -or
        -not $parentItem.PSIsContainer -or
        ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        @((Get-ChildItem -LiteralPath $parent -Force)).Count -ne 60) {
        throw 'Appearance fixture must contain exactly sixty owned files.'
    }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($path in $Paths) {
        $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $file.Length -gt 1MB) { throw 'Appearance fixture file is unsafe.' }
        $rows.Add([ordered]@{
            path = $file.FullName
            name = $file.Name
            content_sha256 = Get-LowerSha256 -Path $file.FullName
            identity = [DarkReNamerVmNative]::GetFileIdentity($file.FullName)
        })
    }
    $rows.ToArray()
}
function Get-ObserverSystemVisualStyle {
    $visualStyle = [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot()
    [ordered]@{
        theme_path_sha256 = Get-LowerTextSha256 -Value $visualStyle.ThemePath
        theme_color = $visualStyle.ThemeColor
        theme_size = $visualStyle.ThemeSize
        forced_colors = ($visualStyle.Flags -band 1) -ne 0
    }
}
function Reset-ObserverAppearanceProposals {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds, [object] $Control)
    if ($null -eq $Control) {
        $Control = Find-UniqueAutomationElement -Root $Application.main -Process $Application.process `
            -ExpectedSession $SessionId -AutomationId '32781' -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $WaitSeconds -Label 'appearance reset proposals' -RequireEnabled -RequireWindowHandle
    }
    Assert-ObserverCommandButton -Control $Control -Application $Application -SessionId $SessionId -AutomationId '32781'
    Invoke-AutomationControl -Element $Control -Label 'appearance reset proposals'
}

function Read-ObserverPerformancePreviewRows {
    param([Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][int[]] $Indices,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Prefix,
        [Parameter(Mandatory)][int] $WaitSeconds)
    if ($Grid.pattern.Current.RowCount -ne 10000 -or
        ($Indices -join ',') -cne '0,2499,4999,7499,9999') {
        throw 'Performance preview probe differs from its fixed five-row plan.'
    }
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $WaitSeconds))
    do {
        $rows = [Collections.Generic.List[object]]::new()
        $allMatched = $true
        foreach ($index in $Indices) {
            $source = 'ordinary-{0:D5}.txt' -f $index
            $current = [string]$Grid.pattern.GetItem($index, 0).Current.Name
            $proposed = [string]$Grid.pattern.GetItem($index, 1).Current.Name
            $rows.Add([ordered]@{ index=$index; source=$current; proposed=$proposed })
            if ($current -cne $source -or $proposed -cne ($Prefix + $source)) {
                $allMatched = $false
                break
            }
        }
        if ($allMatched -and $rows.Count -eq $Indices.Count) { return ,$rows.ToArray() }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw 'Performance preview did not settle for all five representative rows.'
}

function Get-ObserverPerformancePhaseSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Samples,
        [Parameter(Mandatory)][string[]] $PhaseOrder)

    $summary = [Collections.Generic.List[object]]::new()
    foreach ($phaseName in $PhaseOrder) {
        $count = 0
        $maxGapMs = [double]0
        $maxCollectionMs = [double]0
        foreach ($sample in $Samples) {
            if ($sample['phase'] -cne $phaseName) { continue }
            $count++
            $gapMs = [double]$sample['sample_gap_ms']
            $collectionMs = [double]$sample['resource_collection_ms']
            if ($gapMs -gt $maxGapMs) { $maxGapMs = $gapMs }
            if ($collectionMs -gt $maxCollectionMs) { $maxCollectionMs = $collectionMs }
        }
        $summary.Add([ordered]@{ phase=$phaseName; sample_count=$count;
            max_sample_gap_ms=$maxGapMs; max_resource_collection_ms=$maxCollectionMs })
    }
    $summary.ToArray()
}

function Invoke-ObserverBoundPerformanceCommand {
    param([Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][uint32] $CommandId,
        [Parameter(Mandatory)][string] $ScenarioPhase,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $CommandSends)

    if ($CommandSends.Count -ge 20) { throw 'Performance command observation limit exceeded.' }
    try {
        [DarkReNamerVmAcceptanceNative]::SendBoundPerformanceCommand(
            [IntPtr]$Application.main_handle, [uint32]$Application.process.Id, $CommandId, $ScenarioPhase)
    }
    finally {
        $diagnostic = [DarkReNamerVmAcceptanceNative]::LastPerformanceCommandDiagnostic
        if ($null -ne $diagnostic) {
            $CommandSends.Add([ordered]@{
                command_id = [long]$diagnostic.CommandId
                scenario_phase = [string]$diagnostic.ScenarioPhase
                native_return = $diagnostic.NativeReturn
                message_result = $diagnostic.MessageResult
                error_code = $diagnostic.ErrorCode
                elapsed_ms = $diagnostic.ElapsedMs
                status = [string]$diagnostic.Status
            })
        }
    }
}

function Convert-ObserverPopupDiagnostic {
    param([AllowNull()][object] $Popup)
    if ($null -eq $Popup) { return $null }
    [ordered]@{
        stage=[string]$Popup.Stage; begin_ticks=[long]$Popup.BeginTicks;
        end_ticks=[long]$Popup.EndTicks;
        raw_popup_handle=[long]$Popup.RawPopupHandle;
        accepted_popup_handle=[long]$Popup.AcceptedPopupHandle;
        popup_lookup=[string]$Popup.PopupLookup;
        popup_process_id=[long]$Popup.PopupProcessId;
        popup_thread_id=[long]$Popup.PopupThreadId;
        thread_lookup=[string]$Popup.ThreadLookup;
        thread_lookup_error=$Popup.ThreadLookupError;
        popup_class=[string]$Popup.PopupClass;
        class_lookup=[string]$Popup.ClassLookup;
        class_lookup_error=$Popup.ClassLookupError;
        popup_visible=[bool]$Popup.PopupVisible;
        main_enabled_at_lookup=[bool]$Popup.MainEnabledAtLookup;
        visibility_lookup=[string]$Popup.VisibilityLookup;
        direct_owner=[long]$Popup.DirectOwner;
        owner_lookup=[string]$Popup.OwnerLookup;
        owner_lookup_error=$Popup.OwnerLookupError;
        owner_chain=@($Popup.OwnerChain | ForEach-Object { [long]$_ });
        owner_chain_lookup=[string]$Popup.OwnerChainLookup;
        owner_chain_lookup_error=$Popup.OwnerChainLookupError;
        disposition=[string]$Popup.Disposition;
        observed_predicates=@($Popup.ObservedPredicates | ForEach-Object { [string]$_ });
        failed_predicates=@($Popup.FailedPredicates | ForEach-Object { [string]$_ })
    }
}

function Convert-ObserverPerformanceSampleRows {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Samples,
          [switch] $Timeline, [switch] $Picker, [switch] $ClockIdentity)
    @($Samples | ForEach-Object {
        $row = [ordered]@{ phase=$_.Phase; elapsed_ms=$_.ElapsedMs; cpu_ms=$_.CpuMs;
            private_bytes=$_.PrivateBytes; working_set_bytes=$_.WorkingSetBytes;
            threads=$_.Threads; handles=$_.Handles; gdi_objects=$_.GdiObjects;
            ui_response_ms=$_.UiResponseMs; probe_status=$_.ProbeStatus;
            probe_error_code=$_.ProbeErrorCode;
            resource_collection_ms=$_.ResourceCollectionMs; sample_gap_ms=$_.SampleGapMs }
        if ($Timeline -or $ClockIdentity) {
            $row['probe_begin_ticks'] = [long]$_.ProbeBeginTicks
            $row['probe_end_ticks'] = [long]$_.ProbeEndTicks
            $row['process_id'] = [long]$_.ProcessId
            $row['process_start_utc_ticks'] = [long]$_.ProcessStartUtcTicks
            $row['main_window_handle'] = [long]$_.BoundMainHandle
            $row['main_thread_id'] = [long]$_.MainThreadId
        }
        if ($Timeline) {
            $row['main_class'] = [string]$_.MainClass
            $row['main_enabled'] = [bool]$_.MainEnabled
            $row['main_enabled_before'] = [bool]$_.MainEnabledBefore
            $row['owned_popup_handle'] = [long]$_.OwnedPopupHandle
            $row['owned_popup_handle_before'] = [long]$_.OwnedPopupHandleBefore
            $row['owned_popup_thread_id'] = [long]$_.OwnedPopupThreadId
            $row['owned_popup_thread_id_before'] = [long]$_.OwnedPopupThreadIdBefore
            $row['owned_popup_class'] = [string]$_.OwnedPopupClass
            $row['owned_popup_class_before'] = [string]$_.OwnedPopupClassBefore
            if ($Picker) {
                $row['popup_before'] = Convert-ObserverPopupDiagnostic -Popup $_.PopupBeforeDiagnostic
                $row['popup_after'] = Convert-ObserverPopupDiagnostic -Popup $_.PopupAfterDiagnostic
            }
        }
        $row
    })
}

function Convert-ObserverSamplerFailure {
    param([AllowNull()][object] $Failure)
    if ($null -eq $Failure) { return $null }
    if ($Failure.SchemaVersion -ne $script:PickerFailureSchemaVersion) {
        throw 'Sampler failure schema differs from its source-selected producer.'
    }
    $mainBefore = $Failure.MainBefore
    $mainAfter = $Failure.MainAfter
    $convertMain = {
        param($value)
        if ($null -eq $value) { return $null }
        [ordered]@{ handle=[long]$value.Handle; process_id=[long]$value.ProcessId;
            process_start_utc_ticks=[long]$value.ProcessStartUtcTicks;
            thread_id=[long]$value.ThreadId; class=[string]$value.Class;
            enabled=[bool]$value.Enabled; lookup=[string]$value.Lookup;
            thread_lookup_error=$value.ThreadLookupError;
            class_lookup_error=$value.ClassLookupError }
    }
    [ordered]@{
        schema_version=[int]$Failure.SchemaVersion; phase=[string]$Failure.Phase;
        error_type=[string]$Failure.ErrorType; message=[string]$Failure.Message;
        sample_begin_ticks=[long]$Failure.SampleBeginTicks;
        sample_end_ticks=[long]$Failure.SampleEndTicks;
        probe_begin_ticks=[long]$Failure.ProbeBeginTicks;
        probe_end_ticks=[long]$Failure.ProbeEndTicks;
        probe_error_code=$Failure.ProbeErrorCode;
        qpc_frequency=[long]$Failure.QpcFrequency;
        main_before=(& $convertMain $mainBefore);
        main_after=(& $convertMain $mainAfter);
        popup_before=(Convert-ObserverPopupDiagnostic -Popup $Failure.PopupBefore);
        popup_after=(Convert-ObserverPopupDiagnostic -Popup $Failure.PopupAfter)
    }
}

function Initialize-ObserverOwnedPerformanceLifetime {
    param([Parameter(Mandatory)]$Application,
          [Parameter(Mandatory)][Collections.IDictionary]$ObservationSink,
          [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Checkpoints)
    $handle = [IntPtr]$Application.process.Handle
    $productPid = [uint32]$Application.process.Id
    $initial = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
        $handle,$productPid,0,$false)
    $nativeCreationFileTime = [long]$initial[0]
    $ticks = [long]$Application.owned.process_start_time_utc_ticks
    if ([decimal]$ticks -ne ([decimal]$nativeCreationFileTime + 504911232000000000)) {
        throw 'Performance managed and native creation times differ.'
    }
    $Application.process_lifecycle['creation_filetime'] = $nativeCreationFileTime
    $Checkpoints.Add([ordered]@{ phase='pre-work'; creation_filetime=$nativeCreationFileTime })
    $ObservationSink['native_process_lifetime'] = [ordered]@{
        pid=[long]$productPid; creation_filetime=$nativeCreationFileTime
        checkpoints=$Checkpoints; terminal_exit_filetime=$null
    }
    return $nativeCreationFileTime
}

function Invoke-ObserverPerformanceSampleScenario {
    param([Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [ValidateSet('hidden-visible','visible-hidden')][string] $LongPathOrder = 'hidden-visible',
        [switch] $ObserveFirstClear,
        [switch] $ObservePicker,
        [switch] $ObserveCustomInput,
        [switch] $OwnedPerformance,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [AllowNull()][Collections.Generic.List[object]] $ProcessLifecycleObservations,
        [Parameter(Mandatory)][Collections.IDictionary] $ObservationSink)

    if ([int][bool]$ObserveFirstClear +
        [int][bool]$ObservePicker + [int][bool]$ObserveCustomInput -gt 1) {
        throw 'Focused performance modes are mutually exclusive.'
    }
    if ($OwnedPerformance -and $ObserveFirstClear) {
        throw 'Owned performance lifetime applies only to a reviewed owned workload.'
    }
    if (($ObservePicker -or $ObserveCustomInput) -and -not $OwnedPerformance) {
        throw 'Focused popup observation requires the owned-resource lifetime contract.'
    }
    $focusedPopup = $ObservePicker -or $ObserveCustomInput
    $scenarioClock = if ($ObserveFirstClear) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
    $fixture = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'performance-fixture'
    $shortFixture = Resolve-JobBoundShortPath -Path $fixture
    $ordinary = New-PrivateDirectory -Parent $shortFixture -Leaf 'ordinary'
    $longRoot = New-PrivateDirectory -Parent $fixture -Leaf 'long'
    foreach ($segment in @(('a' * 42), ('b' * 42), ('c' * 42))) {
        $longRoot = New-PrivateDirectory -Parent $longRoot -Leaf $segment
    }
    $extensionRoot = New-PrivateDirectory -Parent $fixture -Leaf 'extensions'
    $ordinaryPaths = [Collections.Generic.List[string]]::new()
    $longPaths = [Collections.Generic.List[string]]::new()
    $extensionPaths = [Collections.Generic.List[string]]::new()
    foreach ($index in 0..$(if ($focusedPopup) { 99 } else { 9999 })) {
        $path = Join-Path $ordinary ('ordinary-{0:D5}.txt' -f $index)
        [IO.File]::WriteAllText($path, ('issue24-ordinary-{0:D5}' -f $index), [Text.Encoding]::ASCII)
        $ordinaryPaths.Add($path)
    }
    if (-not $focusedPopup) { foreach ($index in 0..999) {
        $path = Join-Path $longRoot ('long-{0:D4}.txt' -f $index)
        [IO.File]::WriteAllText($path, ('issue24-long-{0:D4}' -f $index), [Text.Encoding]::ASCII)
        $longPaths.Add($path)
        $extension = if ($index -lt 299) { 'e{0:D3}' -f $index } else { 'txt' }
        $name = if ($index -lt 299) { 'extension-{0:D4}' -f $index } else { 'recurring-{0:D4}' -f $index }
        $extensionPath = Join-Path $extensionRoot ($name + '.' + $extension)
        [IO.File]::WriteAllText($extensionPath, ('issue24-extension-{0:D4}' -f $index), [Text.Encoding]::ASCII)
        $extensionPaths.Add($extensionPath)
    } }
    $paths100 = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths ([string[]]$ordinaryPaths.GetRange(0, 100)) -Leaf 'performance-100.txt'
    $paths900 = if ($focusedPopup) { $null } else { New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths ([string[]]$ordinaryPaths.GetRange(100, 900)) -Leaf 'performance-900.txt' }
    $paths2250 = if ($focusedPopup) { @() } else { @(0..3 | ForEach-Object {
        New-ObserverPathList -RuntimeRoot $RuntimeRoot `
            -Paths ([string[]]$ordinaryPaths.GetRange(1000 + 2250 * $_, 2250)) `
            -Leaf ('performance-2250-{0}.txt' -f $_)
    }) }
    $pathsLong = if ($focusedPopup) { $null } else { New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths ([string[]]$longPaths.ToArray()) -Leaf 'performance-long.txt' }
    $pathsExtensions = if ($focusedPopup) { $null } else { New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths ([string[]]$extensionPaths.ToArray()) -Leaf 'performance-extensions.txt' }
    $pathsCycle = if ($focusedPopup) { $null } else { New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths ([string[]]$ordinaryPaths.GetRange(0, 1000)) -Leaf 'performance-cycle.txt' }
    $applicationPath = Join-Path $Verified.root $Verified.application.file
    if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.application.sha256) {
        throw 'Performance application differs from the staged executable.'
    }
    $application = $null
    $sampler = $null
    $samples = $null
    $timings = [Collections.Generic.List[object]]::new()
    $clearRowCounts = [Collections.Generic.List[int]]::new()
    $commandSends = [Collections.Generic.List[object]]::new()
    $timelineEnabled = -not $ObserveFirstClear
    $measureReadinessBrackets = -not ($ObserveFirstClear -or $ObservePicker -or $ObserveCustomInput)
    $timelineEvents = [Collections.Generic.List[object]]::new()
    $activeTimelineEvents = $null
    if ($timelineEnabled) { $activeTimelineEvents = $timelineEvents }
    $nativeCreationFileTime = [long]0
    $nativeLifetimeCheckpoints = [Collections.Generic.List[object]]::new()
    $resetControl = $null
    $prefixControl = $null
    $postStopStage = $null
    $ObservationSink['mode'] = if ($ObserveFirstClear) { 'first-clear-observation' }
        elseif ($ObservePicker) { 'picker-identity-observation' }
        elseif ($ObserveCustomInput) { 'custom-input-identity-observation' }
        else { 'performance-sample' }
    if ($focusedPopup) {
        $ObservationSink['popup_diagnostic_schema_version'] = $script:PickerFailureSchemaVersion
    }
    $ObservationSink['plan'] = if ($ObserveCustomInput) {
        [ordered]@{ ordinary_rows=@(100); idle_ms=1000; sample_interval_ms=200;
            maximum_seconds=120; command_timeout_ms=5000; fixture_file_limit=100;
            prompt_settle_ms=350; controlled_hidden_ms=700;
            confirmed_prefix='confirmed-'; cancelled_prefix='cancelled-';
            prompt_count=2; full_performance_sample=$false }
    } elseif ($ObservePicker) {
        [ordered]@{ ordinary_rows=@(100); idle_ms=1000; picker_settle_ms=350; sample_interval_ms=200;
            maximum_seconds=120; command_timeout_ms=5000; fixture_file_limit=100;
            full_performance_sample=$false }
    } elseif ($ObserveFirstClear) {
        [ordered]@{ ordinary_rows=@(100,1000,10000); idle_seconds=30;
            sample_interval_ms=200; maximum_seconds=600; clear_command_id=32782;
            command_timeout_ms=5000; passive_poll_limit=50; passive_window_ms=10000;
            passive_interval_ms=200; individual_query_timeout_ms=50;
            stop_after_first_clear=$true; full_performance_sample=$false }
    } else {
        [ordered]@{
            ordinary_rows = @(100,1000,10000); long_path_rows = 1000; extension_classes = 300
            add_remove_reset_cycles = 3; idle_seconds = 30; sample_interval_ms = 200
            long_path_order = $LongPathOrder
        }
    }
    $ObservationSink['timing_definitions'] = [ordered]@{
        import = 'native Open invocation to observed expected ListView row count; includes observer polling'
        import_readiness = 'row count observed to enabled path-list import command; separate from import elapsed'
        'ordinary-10000' = 'sum of four 2250-row additions to an existing 1000-row list'
        'full-preview' = 'prefix command invocation to five representative proposals observed'
        cycle = 'import invocation through edit, reset and clear observations'
        startup = 'process creation bracket and launch invocation to bound main HWND, empty grid and enabled import command'
        probe = 'SendMessageTimeoutW entry to immediate return; configured timeout 50 ms, not complete stall duration'
        resources = 'probe return to completion of process resource queries'
    }
    $ObservationSink['timings'] = $timings
    $ObservationSink['clear_row_counts'] = $clearRowCounts
    $ObservationSink['command_sends'] = $commandSends
    if ($timelineEnabled) {
        $ObservationSink['response_timeline'] = [ordered]@{
            schema_version=$script:PerformanceResponseTimelineSchemaVersion;
            qpc_frequency=[long][Diagnostics.Stopwatch]::Frequency;
            events=$timelineEvents }
    }
    try {
        $application = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root `
            -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'performance sample application' `
            -ProcessLifecycleObservations $ProcessLifecycleObservations
        if ($OwnedPerformance) {
            $nativeCreationFileTime = Initialize-ObserverOwnedPerformanceLifetime `
                -Application $application -ObservationSink $ObservationSink `
                -Checkpoints $nativeLifetimeCheckpoints
        }
        [void](Ensure-AcceptanceMainWindowCaptureSize -MainWindow $application.main `
            -Process $application.process -ExpectedSession $SessionId)
        $environment = Get-ObserverEnvironmentMetadata -Application $application
        $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $application.main
        if ($environment.physical_screen.width -ne 1366 -or $environment.physical_screen.height -ne 768 -or
            $environment.hwnd_dpi -ne 96 -or $environment.text_scale_factor_percent -ne 100) {
            throw 'Performance sample display differs from the fixed request.'
        }
        $ObservationSink['environment'] = $environment
        $ObservationSink['process_id'] = [int]$application.process.Id
        $ObservationSink['process_start_utc_ticks'] = [long]$application.process.StartTime.ToUniversalTime().Ticks
        $ObservationSink['executable_sha256'] = $Verified.application.sha256
        $ObservationSink['executable_bytes'] = [long](Get-Item -LiteralPath $applicationPath).Length
        $grid = Get-ObserverGrid -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds
        if ($grid.pattern.Current.RowCount -ne 0) { throw 'Performance sample did not begin with an empty list.' }
        if ($measureReadinessBrackets) {
            $readyProbe = Wait-ObserverMeasuredReadiness -Application $application `
                -WaitSeconds $WaitSeconds -Operation startup -Predicate 'import-command-enabled' -Probe {
                    return [bool][DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                        [IntPtr]$application.main_handle, [uint32]0x801D)
                }
            $readyTicks = [long]$readyProbe.probes[-1].end_ticks
        }
        else {
            $readyDeadline = (Get-Date).AddSeconds($WaitSeconds)
            while (-not [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                [IntPtr]$application.main_handle, [uint32]0x801D)) {
                if ((Get-Date) -ge $readyDeadline) { throw 'Performance import command did not become ready.' }
                Start-Sleep -Milliseconds 100
            }
            $readyTicks = [Diagnostics.Stopwatch]::GetTimestamp()
        }
        $createBegin = [long]$application.owned.ProcessCreateBeginTimestamp
        $createEnd = [long]$application.owned.ProcessCreateEndTimestamp
        if ($createBegin -le 0 -or $createEnd -lt $createBegin -or $readyTicks -lt $createEnd) {
            throw 'Performance process creation timestamp bracket is invalid.'
        }
        $ObservationSink['startup'] = [ordered]@{
            launch_request_to_ready_ms = [Math]::Round(($readyTicks - $application.launch_ticks) * 1000.0 / [Diagnostics.Stopwatch]::Frequency, 3)
            process_start_to_ready_lower_ms = [Math]::Round(($readyTicks - $createEnd) * 1000.0 / [Diagnostics.Stopwatch]::Frequency, 3)
            process_start_to_ready_upper_ms = [Math]::Round(($readyTicks - $createBegin) * 1000.0 / [Diagnostics.Stopwatch]::Frequency, 3)
            main_hwnd_bound = $true; empty_grid = $true; import_command_enabled = $true
        }
        $listHandle = [IntPtr]$grid.element.Current.NativeWindowHandle
        $hiddenWidths = @(3..6 | ForEach-Object { [DarkReNamerVmAcceptanceNative]::ReadListViewColumnWidth($listHandle, $_) })
        if (@($hiddenWidths | Where-Object { $_ -ne 0 }).Count -ne 0) {
            throw 'Performance auxiliary columns were not hidden at clean start.'
        }
        $sampler = if ($focusedPopup) {
            [DarkReNamerPerformanceSampler]::new($application.process, [IntPtr]$application.main_handle,
                120000, 650)
        } else {
            [DarkReNamerPerformanceSampler]::new($application.process, [IntPtr]$application.main_handle)
        }
        if ($OwnedPerformance) {
            $check = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
                [IntPtr]$application.process.Handle,[uint32]$application.process.Id,$nativeCreationFileTime,$false)
            $nativeLifetimeCheckpoints.Add([ordered]@{ phase='idle'; creation_filetime=[long]$check[0] })
        }
        if ($focusedPopup) { Start-Sleep -Milliseconds 1000 } else { Start-Sleep -Seconds 30 }
        if (-not $focusedPopup) {
            [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
                -Window $application.main -Process $application.process -ExpectedSession $SessionId `
                -Root $EvidenceRoot -Leaf 'performance-empty.png' -Label 'performance empty idle'))
        }
        foreach ($stage in $(if ($focusedPopup) {
                @([ordered]@{ id='ordinary-100'; file=$paths100; rows=100 })
            } else { @(
                [ordered]@{ id='ordinary-100'; file=$paths100; rows=100 },
                [ordered]@{ id='ordinary-1000'; file=$paths900; rows=1000 }) })) {
            $sampler.SetPhase($stage.id)
            $timing = Import-GuiRegressionPathList -Application $application -PathsFile $stage.file `
                -ExpectedRows $stage.rows -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid -MeasureCommandReadiness `
                -RecordReadinessBrackets:$measureReadinessBrackets `
                -PickerSettleMilliseconds $(if ($focusedPopup) { 350 } else { 0 }) `
                -TimelineEvents $activeTimelineEvents -TimelineOperation $stage.id
            $timings.Add([ordered]@{ id=$stage.id; elapsed_ms=$timing.elapsed_ms;
                command_ready_after_rows_ms=$timing.command_ready_after_rows_ms;
                rows=$stage.rows; observed_rows=[int]$grid.pattern.Current.RowCount })
            if ($ObserveCustomInput) {
                $prefixControl = Find-UniqueAutomationElement -Root $application.main -Process $application.process `
                    -ExpectedSession $SessionId -AutomationId '32773' -ControlType ([Windows.Automation.ControlType]::Button) `
                    -TimeoutSeconds $WaitSeconds -Label 'focused custom input command' -RequireEnabled -RequireWindowHandle
                $sampler.SetPhase('custom-confirm')
                $confirmed = Invoke-ObserverPrefix -Application $application -Grid $grid -Prefix 'confirmed-' `
                    -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedFirstSourceName 'ordinary-00000.txt' `
                    -Command $prefixControl -PromptSettleMilliseconds 350 `
                    -ControlledHiddenMilliseconds 700 -Sampler $sampler -TimelineEvents $activeTimelineEvents
                $ObservationSink['controlled_hidden_input'] = $confirmed.hidden_control
                if ($grid.pattern.GetItem(0, 1).Current.Name -cne 'confirmed-ordinary-00000.txt') {
                    throw 'Focused confirmed input did not update the preview.'
                }
                $resetControl = Find-UniqueAutomationElement -Root $application.main -Process $application.process `
                    -ExpectedSession $SessionId -AutomationId '32781' -ControlType ([Windows.Automation.ControlType]::Button) `
                    -TimeoutSeconds $WaitSeconds -Label 'focused input reset command' -RequireEnabled -RequireWindowHandle
                Reset-ObserverAppearanceProposals -Application $application -SessionId $SessionId `
                    -WaitSeconds $WaitSeconds -Control $resetControl
                if ($grid.pattern.GetItem(0, 1).Current.Name -cne 'ordinary-00000.txt') {
                    throw 'Focused input reset did not restore the preview.'
                }
                $sampler.SetPhase('custom-cancel')
                Assert-ObserverCommandButton -Control $prefixControl -Application $application `
                    -SessionId $SessionId -AutomationId '32773'
                $cancelRequestTicks = [Diagnostics.Stopwatch]::GetTimestamp()
                $cancelInvoke = Start-AutomationControlInvoke -OwnedProcess $application.owned `
                    -Element $prefixControl -Label 'focused custom cancel command'
                $cancelPrompt = Wait-UniqueAutomationWindow -Process $application.process -ExpectedSession $SessionId `
                    -Owner $application.main -Name '이름 앞에 문자열 붙이기' -TimeoutSeconds $WaitSeconds `
                    -Label 'focused custom cancel prompt'
                $cancelFoundTicks = [Diagnostics.Stopwatch]::GetTimestamp()
                $cancelHandle = [IntPtr]$cancelPrompt.Current.NativeWindowHandle
                $cancelClass = [string]$cancelPrompt.Current.ClassName
                if ($cancelClass -cne 'DarkReNamerInputWindow' -or
                    [bool]$cancelPrompt.Current.IsOffscreen -or -not [bool]$cancelPrompt.Current.IsEnabled) {
                    throw 'Focused cancellation prompt class or visible/enabled state differs.'
                }
                $cancelEdit = Find-UniqueAutomationElement -Root $cancelPrompt -Process $application.process `
                    -ExpectedSession $SessionId -AutomationId '1004' -ControlType ([Windows.Automation.ControlType]::Edit) `
                    -TimeoutSeconds $WaitSeconds -Label 'focused custom cancel edit' -RequireWindowHandle
                Set-AutomationControlValue -Element $cancelEdit -Value 'cancelled-' -Label 'focused custom cancel edit'
                Start-Sleep -Milliseconds 350
                $cancel = Find-UniqueAutomationElement -Root $cancelPrompt -Process $application.process `
                    -ExpectedSession $SessionId -AutomationId '2' -ControlType ([Windows.Automation.ControlType]::Button) `
                    -TimeoutSeconds $WaitSeconds -Label 'focused custom Cancel' -RequireEnabled -RequireWindowHandle
                $cancelInvokeTicks = [Diagnostics.Stopwatch]::GetTimestamp()
                Invoke-AutomationControl -Element $cancel -Label 'focused custom Cancel'
                Wait-WindowClosed -Handle $cancelHandle -TimeoutSeconds $WaitSeconds -Label 'focused custom prompt'
                $cancelClosedTicks = [Diagnostics.Stopwatch]::GetTimestamp()
                Complete-AutomationControlInvoke -State $cancelInvoke -TimeoutSeconds $WaitSeconds
                Start-Sleep -Milliseconds 400
                if ($grid.pattern.GetItem(0, 1).Current.Name -cne 'ordinary-00000.txt') {
                    throw 'Focused cancelled input changed the preview.'
                }
                foreach ($boundary in @(
                    @('prompt_request', $cancelRequestTicks, 0),
                    @('prompt_found', $cancelFoundTicks, $cancelHandle.ToInt64()),
                    @('cancel_invoke', $cancelInvokeTicks, $cancelHandle.ToInt64()),
                    @('prompt_closed', $cancelClosedTicks, $cancelHandle.ToInt64()))) {
                    $timelineEvents.Add([ordered]@{ operation='custom-cancel'; step=[string]$boundary[0];
                        ticks=[long]$boundary[1]; window_handle=[long]$boundary[2] })
                }
                $sampler.SetPhase('post')
                $check = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
                    [IntPtr]$application.process.Handle,[uint32]$application.process.Id,$nativeCreationFileTime,$false)
                $nativeLifetimeCheckpoints.Add([ordered]@{ phase='post'; creation_filetime=[long]$check[0] })
                Start-Sleep -Milliseconds 400
                $samples = @($sampler.Stop())
                $sampler = $null
                try {
                    $ObservationSink['samples'] = @(Convert-ObserverPerformanceSampleRows -Samples $samples -Timeline -Picker)
                }
                catch {
                    [void]$ObservationSink.Remove('samples')
                    $ObservationSink['sample_transfer_failure'] = [ordered]@{
                        schema_version=1; stage='convert-stopped-samples';
                        reported_raw_sample_count=$samples.Count;
                        reported_last_probe_end_ticks=[long]$samples[-1].ProbeEndTicks }
                    throw
                }
                $postStopStage = 'capture'
                [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
                    -Window $application.main -Process $application.process -ExpectedSession $SessionId `
                    -Root $EvidenceRoot -Leaf 'custom-100-after.png' -Label 'focused custom input rows'))
                $ObservationSink['custom_input'] = [ordered]@{
                    expected_rows=100; observed_rows=[int]$grid.pattern.Current.RowCount;
                    import_command_ready=$true; picker_closed=$true; fixture_files=100;
                    confirmed_prompt_handle=[long]$confirmed.prompt_handle;
                    confirmed_prompt_class=[string]$confirmed.prompt_class;
                    confirmed_prompt_visible=[bool]$confirmed.prompt_visible;
                    confirmed_prompt_enabled=[bool]$confirmed.prompt_enabled;
                    confirmed_preview='confirmed-ordinary-00000.txt';
                    cancelled_prompt_handle=$cancelHandle.ToInt64();
                    cancelled_prompt_class=$cancelClass;
                    cancelled_prompt_visible=$true; cancelled_prompt_enabled=$true;
                    cancelled_preview='ordinary-00000.txt';
                    confirmed_then_reset=$true; cancellation_retired=$true }
                $postStopStage = 'fixture-readback'
                $ObservationSink['disk_unchanged'] = $false
                if (@(Get-ChildItem -LiteralPath $ordinary -File -Force).Count -ne 100) {
                    throw 'Focused custom fixture file count changed on disk.'
                }
                foreach ($index in 0..99) {
                    if ([IO.File]::ReadAllText($ordinaryPaths[$index], [Text.Encoding]::ASCII) -cne
                        ('issue24-ordinary-{0:D5}' -f $index)) {
                        throw 'Focused custom fixture content changed on disk.'
                    }
                }
                $ObservationSink['disk_unchanged'] = $true
                $postStopStage = 'journal-readback'
                Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
                $ObservationSink['journal_residue_count'] = 0
                $postStopStage = 'normal-close'
                $ObservationSink['normal_exit_code'] = Close-AcceptanceApplication `
                    -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
                $postStopStage = 'native-exit'
                $terminal = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
                    [IntPtr]$application.process.Handle,[uint32]$application.process.Id,$nativeCreationFileTime,$true)
                $ObservationSink['native_process_lifetime'].terminal_exit_filetime = [long]$terminal[1]
                $ObservationSink['appearance'] = 'light'
                return $ObservationSink
            }
            if ($ObservePicker) {
                $sampler.SetPhase('post')
                $check = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
                    [IntPtr]$application.process.Handle,[uint32]$application.process.Id,$nativeCreationFileTime,$false)
                $nativeLifetimeCheckpoints.Add([ordered]@{ phase='post'; creation_filetime=[long]$check[0] })
                Start-Sleep -Milliseconds 400
                $samples = @($sampler.Stop())
                $sampler = $null
                $ObservationSink['samples'] = @(Convert-ObserverPerformanceSampleRows -Samples $samples -Timeline -Picker)
                [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
                    -Window $application.main -Process $application.process -ExpectedSession $SessionId `
                    -Root $EvidenceRoot -Leaf 'picker-100-after.png' -Label 'focused picker rows'))
                $ObservationSink['picker'] = [ordered]@{
                    expected_rows=100; observed_rows=[int]$grid.pattern.Current.RowCount;
                    import_command_ready=$true; picker_closed=$true;
                    import_elapsed_ms=$timing.elapsed_ms; fixture_files=100 }
                $ObservationSink['disk_unchanged'] = $false
                if (@(Get-ChildItem -LiteralPath $ordinary -File -Force).Count -ne 100) {
                    throw 'Picker fixture file count changed on disk.'
                }
                foreach ($index in 0..99) {
                    if ([IO.File]::ReadAllText($ordinaryPaths[$index], [Text.Encoding]::ASCII) -cne
                        ('issue24-ordinary-{0:D5}' -f $index)) {
                        throw 'Picker fixture content changed on disk.'
                    }
                }
                $ObservationSink['disk_unchanged'] = $true
                Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
                $ObservationSink['journal_residue_count'] = 0
                $ObservationSink['normal_exit_code'] = Close-AcceptanceApplication `
                    -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
                $terminal = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
                    [IntPtr]$application.process.Handle,[uint32]$application.process.Id,$nativeCreationFileTime,$true)
                $ObservationSink['native_process_lifetime'].terminal_exit_filetime = [long]$terminal[1]
                $ObservationSink['appearance'] = 'light'
                return $ObservationSink
            }
            if ($stage.rows -eq 100) {
                # Retain stable command controls before the ListView grows.
                $resetControl = Find-UniqueAutomationElement -Root $application.main -Process $application.process `
                    -ExpectedSession $SessionId -AutomationId '32781' -ControlType ([Windows.Automation.ControlType]::Button) `
                    -TimeoutSeconds $WaitSeconds -Label 'performance reset command' -RequireWindowHandle
                $prefixControl = Find-UniqueAutomationElement -Root $application.main -Process $application.process `
                    -ExpectedSession $SessionId -AutomationId '32773' -ControlType ([Windows.Automation.ControlType]::Button) `
                    -TimeoutSeconds $WaitSeconds -Label 'performance prefix command' -RequireEnabled -RequireWindowHandle
            }
        }
        $sampler.SetPhase('ordinary-10000')
        if ($OwnedPerformance) {
            $check = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
                [IntPtr]$application.process.Handle,[uint32]$application.process.Id,$nativeCreationFileTime,$false)
            $nativeLifetimeCheckpoints.Add([ordered]@{ phase='ordinary-10000'; creation_filetime=[long]$check[0] })
        }
        $largeElapsed = [double]0
        $largeReadiness = [Collections.Generic.List[double]]::new()
        for ($chunk = 0; $chunk -lt 4; $chunk++) {
            $timing = Import-GuiRegressionPathList -Application $application -PathsFile $paths2250[$chunk] `
                -ExpectedRows (1000 + 2250 * ($chunk + 1)) -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid -MeasureCommandReadiness `
                -RecordReadinessBrackets:$measureReadinessBrackets `
                -TimelineEvents $activeTimelineEvents `
                -TimelineOperation ('ordinary-10000-{0}' -f ($chunk + 1))
            $largeElapsed += [double]$timing.elapsed_ms
            $largeReadiness.Add([double]$timing.command_ready_after_rows_ms)
        }
        $timings.Add([ordered]@{ id='ordinary-10000'; elapsed_ms=[Math]::Round($largeElapsed, 3);
            rows=10000; observed_rows=[int]$grid.pattern.Current.RowCount;
            batch_rows=@(2250,2250,2250,2250); batch_command_ready_after_rows_ms=@($largeReadiness.ToArray()) })
        $ObservationSink['ordinary_representatives'] = @(0,4999,9999 | ForEach-Object {
            [ordered]@{ index=$_; name=[string]$grid.pattern.GetItem($_,0).Current.Name }
        })
        $sampler.SetPhase('single-row')
        [void](Set-ObserverManualName -Application $application -Grid $grid -Row 0 -Name 'changed-first.txt' `
            -SessionId $SessionId -WaitSeconds $WaitSeconds)
        if ($grid.pattern.GetItem(0, 1).Current.Name -cne 'changed-first.txt') {
            throw 'Performance single-row preview differs.'
        }
        Reset-ObserverAppearanceProposals -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds -Control $resetControl
        if ($grid.pattern.GetItem(0, 1).Current.Name -cne 'ordinary-00000.txt') {
            throw 'Performance single-row reset did not restore the original name.'
        }
        $sampler.SetPhase('full-preview')
        $fullWatch = [Diagnostics.Stopwatch]::StartNew()
        $prefix = Invoke-ObserverPrefix -Application $application -Grid $grid -Prefix 'sample-' `
            -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedFirstSourceName 'ordinary-00000.txt' -Command $prefixControl `
            -TimelineEvents $activeTimelineEvents
        $previewIndices = [int[]]@(0,2499,4999,7499,9999)
        $prefixRows = Read-ObserverPerformancePreviewRows -Grid $grid -Indices $previewIndices `
            -Prefix 'sample-' -WaitSeconds $WaitSeconds
        if ($timelineEnabled) {
            $timelineEvents.Add([ordered]@{operation='full-preview'; step='representatives_observed';
                ticks=[long][Diagnostics.Stopwatch]::GetTimestamp(); window_handle=0})
            $timelineEvents.Add([ordered]@{operation='full-preview'; step='reset_request';
                ticks=[long][Diagnostics.Stopwatch]::GetTimestamp(); window_handle=0})
        }
        $fullElapsedMs = [Math]::Round($fullWatch.Elapsed.TotalMilliseconds, 3)
        Reset-ObserverAppearanceProposals -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds -Control $resetControl
        if ($timelineEnabled) {
            $timelineEvents.Add([ordered]@{operation='full-preview'; step='reset_returned';
                ticks=[long][Diagnostics.Stopwatch]::GetTimestamp(); window_handle=0})
        }
        $resetRows = Read-ObserverPerformancePreviewRows -Grid $grid -Indices $previewIndices `
            -Prefix '' -WaitSeconds $WaitSeconds
        if ($timelineEnabled) {
            $timelineEvents.Add([ordered]@{operation='full-preview'; step='reset_observed';
                ticks=[long][Diagnostics.Stopwatch]::GetTimestamp(); window_handle=0})
        }
        $ObservationSink['full_preview_rows'] = @(
            for ($probe = 0; $probe -lt $previewIndices.Count; $probe++) {
                [ordered]@{ index=$previewIndices[$probe]; source=$prefixRows[$probe].source;
                    prefixed=$prefixRows[$probe].proposed; reset=$resetRows[$probe].proposed }
            }
        )
        $timings.Add([ordered]@{ id='full-preview'; elapsed_ms=$fullElapsedMs;
            command_elapsed_ms=$prefix.elapsed_ms; rows=10000;
            observed_rows=[int]$grid.pattern.Current.RowCount })
        if ($ObserveFirstClear) {
            $ObservationSink['first_clear'] = [ordered]@{
                stage = 'before-send'; command_id = 32782
                process_id = [int]$application.process.Id
                main_handle = [long]$application.main_handle
                pre_clear_rows = [int]$grid.pattern.Current.RowCount
                preview_reset = @($ObservationSink['full_preview_rows'] | ForEach-Object { $_.reset })
                post_clear_rows = $null
            }
            $ObservationSink['first_clear']['schema_version'] = 1
            $ObservationSink['first_clear']['polls'] = @()
            $ObservationSink['first_clear']['poll_status'] = 'not-started'
            $ObservationSink['first_clear']['poll_elapsed_ms'] = 0
            $ObservationSink['first_clear']['native_identity'] = $null
            if ($ObservationSink['first_clear'].pre_clear_rows -ne 10000) {
                throw 'First-clear observation did not begin with 10000 rows.'
            }
        }
        $firstClearIdentity = $null
        if ($ObserveFirstClear) {
            $firstClearIdentity = [DarkReNamerVmAcceptanceNative]::CaptureFirstClearIdentity(
                [IntPtr]$application.process.Handle, [uint32]$application.process.Id,
                [IntPtr]$application.main_handle, [IntPtr]$listHandle)
            $ObservationSink['first_clear'].native_identity = [ordered]@{
                process_id=[long]$firstClearIdentity.ProcessId
                creation_filetime=[long]$firstClearIdentity.CreationFileTime
                main_handle=[long]$firstClearIdentity.MainHandle
                list_handle=[long]$firstClearIdentity.ListHandle
                main_thread_id=[long]$firstClearIdentity.MainThreadId
                list_thread_id=[long]$firstClearIdentity.ListThreadId
                main_class=[string]$firstClearIdentity.MainClass
                list_class=[string]$firstClearIdentity.ListClass
                list_parent=[long]$firstClearIdentity.ListParent
                list_control_id=[int]$firstClearIdentity.ListControlId
            }
        }
        try {
            Invoke-ObserverBoundPerformanceCommand -Application $application -CommandId 0x800E `
                -ScenarioPhase 'full-preview-clear' -CommandSends $commandSends
        }
        catch {
            if ($ObserveFirstClear) { $ObservationSink['first_clear'].stage = 'send-failed' }
            if ($ObserveFirstClear -and $commandSends.Count -gt 0 -and
                $commandSends[$commandSends.Count - 1].command_id -eq 32782 -and
                $commandSends[$commandSends.Count - 1].status -ceq 'timeout' -and
                $commandSends[$commandSends.Count - 1].error_code -eq 1460) {
                $originalFailure = $_
                if ($null -ne $sampler) {
                    try {
                        $ObservationSink['partial_samples'] = @(
                            Convert-ObserverPerformanceSampleRows -Samples @($sampler.Stop()) -Timeline:$timelineEnabled -Picker:$focusedPopup)
                    }
                    catch {
                        $ObservationSink['partial_sampling_error'] = $_.Exception.GetType().Name
                        $ObservationSink['partial_samples'] = @(
                            Convert-ObserverPerformanceSampleRows -Samples @($sampler.ReadStoppedSamples()) -Timeline:$timelineEnabled -Picker:$focusedPopup)
                    }
                    finally { $sampler = $null }
                }
                $pollClock = $null
                $polls = $null
                try {
                    $pollClock = [Diagnostics.Stopwatch]::StartNew()
                    $polls = [Collections.Generic.List[object]]::new()
                    $pollStatus = 'budget-exhausted'
                    for ($pollIndex = 0; $pollIndex -lt 50; $pollIndex++) {
                        $elapsed = [long]$pollClock.ElapsedMilliseconds
                        $slotStart = $pollIndex * 200
                        if ($elapsed -gt $slotStart + 199) { continue }
                        if ($elapsed -lt $slotStart) {
                            if ($slotStart + 100 -gt 10000 -or
                                [long]$scenarioClock.ElapsedMilliseconds + ($slotStart - $elapsed) + 100 -gt 600000) { break }
                            Start-Sleep -Milliseconds ($slotStart - $elapsed)
                            $elapsed = [long]$pollClock.ElapsedMilliseconds
                            if ($elapsed -gt $slotStart + 199) { continue }
                        }
                        if ($elapsed + 100 -gt 10000 -or
                            [long]$scenarioClock.ElapsedMilliseconds + 100 -gt 600000) { break }
                        $poll = [DarkReNamerVmAcceptanceNative]::PollFirstClear(
                            [IntPtr]$application.process.Handle, $firstClearIdentity)
                        $polls.Add([ordered]@{
                            index=$pollIndex; elapsed_ms=[long]$pollClock.ElapsedMilliseconds
                            status=[string]$poll.Status; creation_filetime=[long]$poll.CreationFileTime
                            count_status=[string]$poll.CountStatus; count_error=[int]$poll.CountError
                            count_elapsed_ms=[double]$poll.CountElapsedMs
                            row_count=$poll.RowCount; response_status=[string]$poll.ResponseStatus
                            response_error=[int]$poll.ResponseError
                            response_elapsed_ms=[double]$poll.ResponseElapsedMs
                        })
                        if ($poll.Status -cne 'identity-bound') { $pollStatus = 'identity-unknown'; break }
                        if ($pollIndex -eq 49) { $pollStatus = 'poll-limit'; break }
                    }
                    $ObservationSink['first_clear'].polls = @($polls.ToArray())
                    $ObservationSink['first_clear'].poll_status = $pollStatus
                    $ObservationSink['first_clear'].poll_elapsed_ms = [long]$pollClock.ElapsedMilliseconds
                }
                catch {
                    if ($null -ne $polls) { $ObservationSink['first_clear'].polls = @($polls.ToArray()) }
                    $ObservationSink['first_clear'].poll_status = 'observer-error'
                    if ($null -ne $pollClock) {
                        $ObservationSink['first_clear'].poll_elapsed_ms = [long]$pollClock.ElapsedMilliseconds
                    }
                    $ObservationSink['first_clear'].poll_error_type = $_.Exception.GetType().Name
                }
                throw $originalFailure
            }
            throw
        }
        if ($ObserveFirstClear) { $ObservationSink['first_clear'].stage = 'sent' }
        $clearedRows = [int]$grid.pattern.Current.RowCount
        if ($ObserveFirstClear) {
            $ObservationSink['first_clear'].post_clear_rows = $clearedRows
            $ObservationSink['first_clear'].stage = 'after-send'
        }
        if ($clearedRows -ne 0) { throw 'Performance list clear did not remove all rows.' }
        if ($ObserveFirstClear) { $ObservationSink['first_clear'].stage = 'verified-empty' }
        $clearRowCounts.Add([int]$grid.pattern.Current.RowCount)
        if (-not $ObserveFirstClear) {
        $longModes = if ($LongPathOrder -eq 'visible-hidden') { @('long-visible','long-hidden') }
            else { @('long-hidden','long-visible') }
        $columnsVisible = $false
        $visibleWidths = $null
        $auxiliaryValues = $null
        $longRepresentatives = [ordered]@{}
        foreach ($mode in $longModes) {
            $wantVisible = $mode -eq 'long-visible'
            if ($wantVisible -ne $columnsVisible) {
                foreach ($command in @(0x8020,0x8021,0x8022,0x8023)) {
                    Invoke-ObserverBoundPerformanceCommand -Application $application -CommandId $command `
                        -ScenarioPhase "$mode-columns" -CommandSends $commandSends
                }
                $columnsVisible = $wantVisible
            }
            $widths = @(3..6 | ForEach-Object { [DarkReNamerVmAcceptanceNative]::ReadListViewColumnWidth($listHandle, $_) })
            if (($wantVisible -and @($widths | Where-Object { $_ -le 0 }).Count -ne 0) -or
                (-not $wantVisible -and @($widths | Where-Object { $_ -ne 0 }).Count -ne 0)) {
                throw "Performance $mode column state differs."
            }
            if ($wantVisible) { $visibleWidths = $widths }
            $sampler.SetPhase($mode)
            $longTiming = Import-GuiRegressionPathList -Application $application -PathsFile $pathsLong `
                -ExpectedRows 1000 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid -MeasureCommandReadiness `
                -RecordReadinessBrackets `
                -TimelineEvents $timelineEvents -TimelineOperation $mode
            $timings.Add([ordered]@{ id=$mode; elapsed_ms=$longTiming.elapsed_ms;
                command_ready_after_rows_ms=$longTiming.command_ready_after_rows_ms;
                rows=1000; observed_rows=[int]$grid.pattern.Current.RowCount })
            $longRepresentatives[$mode] = @(0,499,999 | ForEach-Object {
                [ordered]@{ index=$_; name=[string]$grid.pattern.GetItem($_,0).Current.Name }
            })
            if ($wantVisible) {
                $auxiliaryValues = @(3..6 | ForEach-Object { [string]$grid.pattern.GetItem(0, $_).Current.Name })
                if ($auxiliaryValues[0] -cne $longPaths[0] -or
                    @($auxiliaryValues | Where-Object { [string]::IsNullOrEmpty($_) }).Count -ne 0) {
                    throw 'Performance visible auxiliary column values differ.'
                }
            }
            Invoke-ObserverBoundPerformanceCommand -Application $application -CommandId 0x800E `
                -ScenarioPhase "$mode-clear" -CommandSends $commandSends
            if ($grid.pattern.Current.RowCount -ne 0) { throw "Performance $mode list did not clear." }
            $clearRowCounts.Add([int]$grid.pattern.Current.RowCount)
        }
        $ObservationSink['columns'] = [ordered]@{ hidden_widths=$hiddenWidths; visible_widths=$visibleWidths; first_values=$auxiliaryValues }
        $ObservationSink['long_representatives'] = $longRepresentatives
        if (-not $columnsVisible) {
            foreach ($command in @(0x8020,0x8021,0x8022,0x8023)) {
                Invoke-ObserverBoundPerformanceCommand -Application $application -CommandId $command `
                    -ScenarioPhase 'extension-columns' -CommandSends $commandSends
            }
        }
        $restoredWidths = @(3..6 | ForEach-Object {
            [DarkReNamerVmAcceptanceNative]::ReadListViewColumnWidth($listHandle, $_)
        })
        if (@($restoredWidths | Where-Object { $_ -le 0 }).Count -ne 0) {
            throw 'Performance extension workload did not start with visible auxiliary columns.'
        }
        $ObservationSink['columns']['extension_widths'] = $restoredWidths
        $sampler.SetPhase('extensions')
        $extensionTiming = Import-GuiRegressionPathList -Application $application -PathsFile $pathsExtensions `
            -ExpectedRows 1000 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid -MeasureCommandReadiness `
            -RecordReadinessBrackets `
            -TimelineEvents $timelineEvents -TimelineOperation 'extensions'
        $timings.Add([ordered]@{ id='extensions'; elapsed_ms=$extensionTiming.elapsed_ms;
            command_ready_after_rows_ms=$extensionTiming.command_ready_after_rows_ms;
            rows=1000; observed_rows=[int]$grid.pattern.Current.RowCount })
        $ObservationSink['extension_representatives'] = @(0,499,999 | ForEach-Object {
            [ordered]@{ index=$_; name=[string]$grid.pattern.GetItem($_,0).Current.Name }
        })
        if ($grid.pattern.GetItem(999, 0).Current.Name -cne 'recurring-0999.txt') {
            throw 'Performance recurring extension fixture differs.'
        }
        Invoke-ObserverBoundPerformanceCommand -Application $application -CommandId 0x800E `
            -ScenarioPhase 'extension-clear' -CommandSends $commandSends
        if ($grid.pattern.Current.RowCount -ne 0) { throw 'Performance extension list did not clear.' }
        $clearRowCounts.Add([int]$grid.pattern.Current.RowCount)
        foreach ($cycle in 1..3) {
            $id = 'cycle-{0}' -f $cycle
            $sampler.SetPhase($id)
            $cycleWatch = [Diagnostics.Stopwatch]::StartNew()
            $cycleTiming = Import-GuiRegressionPathList -Application $application -PathsFile $pathsCycle `
                -ExpectedRows 1000 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid -MeasureCommandReadiness `
                -RecordReadinessBrackets `
                -TimelineEvents $timelineEvents -TimelineOperation $id
            $cycleObservedRows = [int]$grid.pattern.Current.RowCount
            [void](Set-ObserverManualName -Application $application -Grid $grid -Row 0 `
                -Name ('cycle-{0}.txt' -f $cycle) -SessionId $SessionId -WaitSeconds $WaitSeconds)
            Reset-ObserverAppearanceProposals -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds -Control $resetControl
            if ($grid.pattern.GetItem(0, 1).Current.Name -cne 'ordinary-00000.txt') {
                throw "Performance $id reset did not restore the original name."
            }
            Invoke-ObserverBoundPerformanceCommand -Application $application -CommandId 0x800E `
                -ScenarioPhase "$id-clear" -CommandSends $commandSends
            if ($grid.pattern.Current.RowCount -ne 0) { throw "Performance $id did not clear." }
            $clearRowCounts.Add([int]$grid.pattern.Current.RowCount)
            $timings.Add([ordered]@{ id=$id; elapsed_ms=[Math]::Round($cycleWatch.Elapsed.TotalMilliseconds, 3);
                import_elapsed_ms=$cycleTiming.elapsed_ms;
                import_command_ready_after_rows_ms=$cycleTiming.command_ready_after_rows_ms;
                rows=1000; observed_rows=$cycleObservedRows })
        }
        }
        $sampler.SetPhase('post')
        if ($OwnedPerformance) {
            $check = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
                [IntPtr]$application.process.Handle,[uint32]$application.process.Id,$nativeCreationFileTime,$false)
            $nativeLifetimeCheckpoints.Add([ordered]@{ phase='post'; creation_filetime=[long]$check[0] })
        }
        Start-Sleep -Milliseconds 400
        $samples = @($sampler.Stop())
        $sampler = $null
        $ObservationSink['samples'] = @(Convert-ObserverPerformanceSampleRows -Samples $samples -Timeline:$timelineEnabled -Picker:$focusedPopup)
        $phaseOrder = @('empty-idle','ordinary-100','ordinary-1000','ordinary-10000',
            'single-row','full-preview') + $(if ($ObserveFirstClear) { @() }
                else { @($longModes) + @('extensions','cycle-1','cycle-2','cycle-3') }) + @('post')
        $ObservationSink['phase_summary'] = @(Get-ObserverPerformancePhaseSummary `
            -Samples $ObservationSink['samples'] -PhaseOrder $phaseOrder)
        $ObservationSink['wakeups'] = [ordered]@{ status='not_run'; reason='no-supported-process-wakeup-counter' }
        $ObservationSink['disk_unchanged'] = $false
        foreach ($group in @(
            [ordered]@{ path=$ordinary; files=$ordinaryPaths; kind='ordinary' },
            [ordered]@{ path=$longRoot; files=$longPaths; kind='long' },
            [ordered]@{ path=$extensionRoot; files=$extensionPaths; kind='extension' })) {
            if (@(Get-ChildItem -LiteralPath $group.path -File -Force).Count -ne $group.files.Count) {
                throw 'Performance fixture file count changed on disk.'
            }
            for ($index = 0; $index -lt $group.files.Count; $index++) {
                $expected = 'issue24-{0}-{1:D4}' -f $group.kind,$index
                if ($group.kind -eq 'ordinary') { $expected = 'issue24-ordinary-{0:D5}' -f $index }
                if ([IO.File]::ReadAllText($group.files[$index], [Text.Encoding]::ASCII) -cne $expected) {
                    throw 'Performance fixture content changed on disk.'
                }
            }
        }
        $ObservationSink['disk_unchanged'] = $true
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $ObservationSink['journal_residue_count'] = 0
        $exitCode = Close-AcceptanceApplication -Application $application -SessionId $SessionId `
            -WaitSeconds $WaitSeconds -CloseInput ordinary
        if ($OwnedPerformance) {
            $terminal = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
                [IntPtr]$application.process.Handle,[uint32]$application.process.Id,$nativeCreationFileTime,$true)
            $ObservationSink['native_process_lifetime'].terminal_exit_filetime = [long]$terminal[1]
        }
        $ObservationSink['normal_exit_code'] = $exitCode
        if ($measureReadinessBrackets) {
            $ObservationSink['readiness_brackets'] = @($application.readiness_brackets.ToArray())
        }
        $ObservationSink['appearance'] = 'light'
        $ObservationSink['mode'] = if ($ObserveFirstClear) { 'first-clear-observation' }
            elseif ($ObservePicker) { 'picker-identity-observation' }
            elseif ($ObserveCustomInput) { 'custom-input-identity-observation' }
            else { 'performance-sample' }
        return $ObservationSink
    }
    catch {
        if ($ObserveCustomInput -and $null -eq $sampler -and $null -ne $postStopStage -and
            $ObservationSink.Contains('samples')) {
            $retained = @($ObservationSink['samples'])
            $ObservationSink['post_stop_failure'] = [ordered]@{
                schema_version=1; stage=$postStopStage; sample_count=$retained.Count;
                last_probe_end_ticks=[long]$retained[-1].probe_end_ticks }
        }
        throw
    }
    finally {
        if ($null -ne $sampler) {
            try {
                $ObservationSink['partial_samples'] = @(
                    Convert-ObserverPerformanceSampleRows -Samples @($sampler.Stop()) -Timeline:$timelineEnabled -Picker:$focusedPopup)
            }
            catch {
                $ObservationSink['partial_sampling_error'] = $_.Exception.Message
                $ObservationSink['partial_samples'] = @(
                    Convert-ObserverPerformanceSampleRows -Samples @($sampler.ReadStoppedSamples()) -Timeline:$timelineEnabled -Picker:$focusedPopup)
            }
            $failure = $sampler.ReadFailureDiagnostic()
            if ($null -ne $failure) {
                $ObservationSink['sampler_failure'] = Convert-ObserverSamplerFailure -Failure $failure
            }
        }
        if ($null -ne $application) {
            try { Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned }
            catch {
                if ($ObserveCustomInput -and $null -eq $sampler -and
                    $ObservationSink.Contains('samples') -and
                    -not $ObservationSink.Contains('post_stop_failure')) {
                    $retained = @($ObservationSink['samples'])
                    $ObservationSink['post_stop_failure'] = [ordered]@{
                        schema_version=1; stage='owned-dispose'; sample_count=$retained.Count;
                        last_probe_end_ticks=[long]$retained[-1].probe_end_ticks }
                }
                throw
            }
        }
    }
}
function Get-ObserverAppearanceSelection {
    param([Parameter(Mandatory)][object] $Grid)
    $pattern = $null
    if (-not $Grid.element.TryGetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern, [ref]$pattern)) {
        throw 'Appearance ListView lacks native selection state.'
    }
    $selected = @(([Windows.Automation.SelectionPattern]$pattern).Current.GetSelection())
    if ($selected.Count -gt 1) { throw 'Appearance ListView has unexpected multiple selection.' }
    [ordered]@{
        count = $selected.Count
        name = if ($selected.Count -eq 1) { [string]$selected[0].Current.Name } else { $null }
    }
}
function Get-ObserverAppearanceFocusId {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId)
    [void](Get-FocusedAcceptanceElement -Process $Application.process -ExpectedSession $SessionId -Label 'appearance interaction focus')
    $native = [DarkReNamerVmAcceptanceNative]::ReadGuiThreadSnapshot([IntPtr]$Application.main_handle, [uint32]$Application.process.Id)
    [string]$native[2]
}
function Show-ObserverAppearanceProposalCell {
    param([Parameter(Mandatory)][object] $Grid)
    $scrollObject = $null
    if (-not $Grid.element.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$scrollObject)) {
        throw 'Appearance ListView does not expose horizontal scroll control.'
    }
    $scroll = [Windows.Automation.ScrollPattern]$scrollObject
    if (-not $scroll.Current.HorizontallyScrollable) {
        throw 'Appearance proposal fixture did not expose horizontal scrolling.'
    }
    $scroll.SetScrollPercent(45.0, [Windows.Automation.ScrollPattern]::NoScroll)
    Start-Sleep -Milliseconds 100
    $cell = $Grid.pattern.GetItem(0, 1)
    if ($cell.Current.IsOffscreen -or $cell.Current.BoundingRectangle.Width -lt 20) {
        throw 'Appearance proposed-name cell is not visibly exposed by horizontal scroll.'
    }
    $cell
}
function Save-ObserverAppearanceCapture {
    param([Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Window,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Appearance,
        [Parameter(Mandatory)][string] $Surface,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures)
    $capture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
        -Window $Window -Process $Application.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf $Leaf -Label $Leaf
    $Captures.Add((Add-AcceptanceScreenshotContext -Screenshot $capture -Appearance $Appearance -Surface $Surface))
    $capture
}
function Get-ObserverAppearanceRenderingEnvironment {
    param([Parameter(Mandatory)][object] $Application)
    $value = [DarkReNamerVmAcceptanceNative]::ReadWindowRenderingEnvironment([IntPtr]$Application.main_handle, [uint32]$Application.process.Id)
    $fonts = [ordered]@{}
    foreach ($role in @('MessageFont', 'StatusFont')) {
        $font = $value.$role
        if ([string]::IsNullOrWhiteSpace($font.FaceName) -or $font.FaceName.Length -gt 31 -or $font.Height -eq 0) {
            throw 'Appearance system font recipe is missing or invalid.'
        }
        $fonts[$role] = [ordered]@{
            family = $font.FaceName; height = [int]$font.Height; width = [int]$font.Width
            weight = [int]$font.Weight; charset = [int]$font.CharSet; quality = [int]$font.Quality
            italic = [int]$font.Italic; underline = [int]$font.Underline; strikeout = [int]$font.StrikeOut
        }
    }
    [ordered]@{
        hwnd = [long]$Application.main_handle; process_id = [int]$Application.process.Id; hwnd_dpi = [int]$value.Dpi
        awareness = [ordered]@{ query = 'GetWindowDpiAwarenessContext+GetAwarenessFromDpiAwarenessContext+AreDpiAwarenessContextsEqual'; context = $value.Context; value = $value.Awareness; per_monitor_v2 = $value.PerMonitorV2 }
        client = [ordered]@{ left = $value.Client.Left; top = $value.Client.Top; right = $value.Client.Right; bottom = $value.Client.Bottom; width = $value.Client.Right - $value.Client.Left; height = $value.Client.Bottom - $value.Client.Top }
        client_query = 'GetClientRect+ClientToScreen'
        system_font_recipe = [ordered]@{ query = 'SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS)'; dpi = [int]$value.Dpi; fonts = $fonts; scope = 'system LOGFONT recipe; not a dereferenced application HFONT' }
    }
}
function Get-ObserverAppearanceInstalledFontEnvironment {
    $collection = [Drawing.Text.InstalledFontCollection]::new()
    $families = @()
    try {
        $families = @($collection.Families)
        $names = [string[]]@($families | ForEach-Object { $_.Name })
        if ($names.Count -lt 1 -or $names.Count -gt 4096) { throw 'Appearance installed font inventory is outside its bound.' }
        [Array]::Sort($names, [StringComparer]::Ordinal)
        $bytes = [Text.Encoding]::UTF8.GetBytes(($names -join "`n"))
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $digest = -join ($hash.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
        finally { $hash.Dispose() }
        [ordered]@{ query = 'System.Drawing.Text.InstalledFontCollection'; count = $names.Count; family_names_sha256 = $digest; encoding = 'UTF-8 ordinal sorted names joined by LF'; scope = 'installed family environment; glyph fallback is observed in original rasters' }
    }
    finally {
        if ($null -ne $families) { foreach ($family in $families) { $family.Dispose() } }
        $collection.Dispose()
    }
}
function Invoke-ObserverAppearanceScrollProbe {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][string] $EvidenceRoot, [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][string] $Appearance, [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures)
    Assert-AutomationBinding -Element $Grid.element -Process $Application.process -ExpectedSession $SessionId -Label 'appearance scrollbar list' -RequireWindowHandle
    $window = [IntPtr]$Grid.element.Current.NativeWindowHandle
    $scrollObject = $null
    if (-not $Grid.element.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$scrollObject)) {
        throw 'Appearance scrollbar probe lacks native scrolling.'
    }
    $scrollPattern = [Windows.Automation.ScrollPattern]$scrollObject
    $axes = [ordered]@{}
    foreach ($axis in 0..1) {
        $axisName = if ($axis -eq 0) { 'horizontal' } else { 'vertical' }
        $scrollPattern.SetScrollPercent(0.0, 0.0)
        $Grid.element.SetFocus()
        [void](Assert-ObserverAppearanceNoTooltip -Application $Application)
        $bar = [DarkReNamerVmAcceptanceNative]::ReadScrollBarComponents($window, $axis)
        $length = if ($axis -eq 0) { $bar[2] - $bar[0] } else { $bar[3] - $bar[1] }
        if ($bar.Count -ne 13 -or ($bar[7] -band 0x18000) -ne 0 -or $bar[4] -lt 1 -or
            $bar[5] -lt $bar[4] -or $bar[6] -le $bar[5] -or $bar[6] -gt $length - $bar[4]) {
            throw 'Appearance scrollbar probe has invalid native thumb geometry.'
        }
        $point = [DarkReNamerVmAcceptanceNative+Point]::new()
        $point.X = if ($axis -eq 0) { $bar[0] + [int][Math]::Floor(($bar[5] + $bar[6]) / 2.0) } else { [int][Math]::Floor(($bar[0] + $bar[2]) / 2.0) }
        $point.Y = if ($axis -eq 1) { $bar[1] + [int][Math]::Floor(($bar[5] + $bar[6]) / 2.0) } else { [int][Math]::Floor(($bar[1] + $bar[3]) / 2.0) }
        $hit = [DarkReNamerVmAcceptanceNative]::WindowFromPoint($point)
        $pidObserved = [uint32]0
        $thread = [DarkReNamerVmNative]::GetWindowThreadProcessId($hit, [ref]$pidObserved)
        $root = [DarkReNamerVmAcceptanceNative]::GetAncestor($hit, 2)
        if ($hit -ne $window -or $thread -eq 0 -or $pidObserved -ne $Application.process.Id -or
            $root -ne [IntPtr]$Application.main_handle -or
            [DarkReNamerVmNative]::GetForegroundWindow() -ne $root) {
            throw 'Appearance scrollbar thumb is obscured or belongs to a different window.'
        }
        $initial = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($window, $axis))
        $steps = [Collections.Generic.List[object]]::new()
        try {
            [DarkReNamerVmAcceptanceNative]::MoveCursor($point.X, $point.Y)
            Start-Sleep -Milliseconds 150
            [DarkReNamerVmAcceptanceNative]::PressLeftButton()
            foreach ($stage in @('held', 'moving', 'released')) {
                if ($stage -eq 'moving') {
                    $delta = [Math]::Max(8, [int][Math]::Floor(($length - 2 * $bar[4] - ($bar[6] - $bar[5])) / 3.0))
                    $moveX = if ($axis -eq 0) { $point.X + $delta } else { $point.X }
                    $moveY = if ($axis -eq 1) { $point.Y + $delta } else { $point.Y }
                    [DarkReNamerVmAcceptanceNative]::MoveCursor($moveX, $moveY)
                }
                elseif ($stage -eq 'released') { [DarkReNamerVmAcceptanceNative]::ReleaseLeftButton() }
                Start-Sleep -Milliseconds 200
                $gui = @([DarkReNamerVmAcceptanceNative]::ReadGuiThreadSnapshot([IntPtr]$Application.main_handle, [uint32]$Application.process.Id))
                if (($stage -ne 'released' -and $gui[1] -ne $window.ToInt64()) -or
                    ($stage -eq 'released' -and $gui[1] -ne 0)) {
                    throw "Appearance scrollbar $stage capture state differs from native tracking."
                }
                $steps.Add([ordered]@{
                    stage = $stage; native_gui = $gui
                    components = @([DarkReNamerVmAcceptanceNative]::ReadScrollBarComponents($window, $axis))
                    scroll = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($window, $axis))
                    capture = Save-ObserverAppearanceCapture -Application $Application -Window $Application.main -EvidenceRoot $EvidenceRoot -Leaf "appearance-scroll-$axisName-$stage-$Phase.png" -Appearance $Appearance -Surface 'main-workbench' -SessionId $SessionId -Captures $Captures
                })
            }
            if ($steps[2].scroll[3] -le $initial[3]) { throw 'Appearance native thumb drag did not scroll the list.' }
        }
        finally {
            [DarkReNamerVmAcceptanceNative]::ReleaseLeftButton()
            Start-Sleep -Milliseconds 150
            $scrollPattern.SetScrollPercent(0.0, 0.0)
            [void](Assert-ObserverAppearanceNoTooltip -Application $Application)
        }
        $axes[$axisName] = [ordered]@{
            list_hwnd = $window.ToInt64(); target = [ordered]@{ x = $point.X; y = $point.Y; hit_window = $hit.ToInt64(); root_window = $root.ToInt64() }
            initial_scroll = $initial; steps = $steps.ToArray()
            restored_scroll = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($window, $axis))
        }
        if ($axes[$axisName].restored_scroll[3] -ne $initial[3]) { throw 'Appearance scrollbar viewport was not restored.' }
    }
    $axes
}
function Get-ObserverResolvedSystemAppearance {
    Initialize-AcceptanceNative
    $color = @([DarkReNamerVmAcceptanceNative]::ReadSystemForegroundColor())
    $style = Get-ObserverSystemVisualStyle
    $resolved = if ($style.forced_colors) { 'native' } elseif ($color[1] * 299 + $color[2] * 587 + $color[3] * 114 -ge 128000) { 'dark' } else { 'light' }
    [ordered]@{ query = 'UISettings.GetColorValue(UIColorType.Foreground)+SPI_GETHIGHCONTRAST'; foreground_argb = $color; resolved_theme = $resolved; system_visual_style = $style }
}
function Save-ObserverAppearanceSystemCapture {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][int] $SessionId, [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures)
    $scrollObject = $null
    if (-not $Grid.element.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$scrollObject)) {
        throw 'System appearance probe lacks native scroll control.'
    }
    ([Windows.Automation.ScrollPattern]$scrollObject).SetScrollPercent(45.0, 0.0)
    $Grid.element.SetFocus()
    Start-Sleep -Milliseconds 150
    $overlay = Assert-ObserverAppearanceNoTooltip -Application $Application
    $resolved = Get-ObserverResolvedSystemAppearance
    $listHandle = [IntPtr]$Grid.element.Current.NativeWindowHandle
    $viewport = [DarkReNamerVmAcceptanceNative]::SetListHorizontalViewport($listHandle, [uint32]$Application.process.Id)
    Start-Sleep -Milliseconds 100
    $names = @(for ($index = 0; $index -lt 60; $index++) { [string]$Grid.pattern.GetItem($index, 0).Current.Name })
    [ordered]@{
        phase = $Phase; appearance = 'system'; resolution = $resolved; overlay = $overlay
        appearance_menu = Get-VmAutomatedAppearance -Window $Application.main -Process $Application.process -ExpectedSession $SessionId
        row_count = 60; current_names = $names
        selection = Get-ObserverAppearanceSelection -Grid $Grid
        proposal_viewport = [ordered]@{ query = 'LVM_SCROLL horizontal scalar pixels after focus'; percent = 45; requested = $viewport[0]; observed = $viewport[1] }
        semantic_cells = [ordered]@{
            selected = Get-ElementObservation -Element ($Grid.pattern.GetItem(0, 1))
            unselected = Get-ElementObservation -Element ($Grid.pattern.GetItem(1, 1))
        }
        native_focus = @([DarkReNamerVmAcceptanceNative]::ReadGuiThreadSnapshot([IntPtr]$Application.main_handle, [uint32]$Application.process.Id))
        target_rendering = Get-ObserverAppearanceRenderingEnvironment -Application $Application
        native_window = Get-ObserverNativeWindowMetrics -Window $Application.main
        native_list = Get-ObserverNativeWindowMetrics -Window $Grid.element
        horizontal_scroll = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 0))
        vertical_scroll = @([DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 1))
        horizontal_components = @([DarkReNamerVmAcceptanceNative]::ReadScrollBarComponents($listHandle, 0))
        vertical_components = @([DarkReNamerVmAcceptanceNative]::ReadScrollBarComponents($listHandle, 1))
        colors = (ConvertTo-HighContrastDocumentSnapshot -Snapshot ([DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot())).colors
        capture = Save-ObserverAppearanceCapture -Application $Application -Window $Application.main -EvidenceRoot $EvidenceRoot `
            -Leaf "appearance-system-$Phase.png" -Appearance 'system' -Surface 'main-workbench' -SessionId $SessionId -Captures $Captures
    }
}
function Invoke-ObserverAppearanceSystemProbe {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][int] $SessionId, [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $SourceSha, [Parameter(Mandatory)][string] $AcceptanceScriptSha256,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures)
    if ($SourceSha -cnotmatch '^[0-9a-f]{40}$' -or $AcceptanceScriptSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'High Contrast pair requires exact source and acceptance script bindings.'
    }
    [void](Set-AcceptanceAppearance -Process $Application.process -ExpectedSession $SessionId `
        -MainWindowHandle ([IntPtr]$Application.main_handle) -Appearance 'system')
    $original = [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot()
    if (($original.Flags -band 1) -ne 0) { throw 'Normal paired scenes require an initially non-Forced Colors session.' }
    $before = Save-ObserverAppearanceSystemCapture -Application $Application -Grid $Grid -SessionId $SessionId -EvidenceRoot $EvidenceRoot -Phase 'before' -Captures $Captures
    $restorePath = Join-Path $EvidenceRoot 'high-contrast-restore.json'
    # Persist exact recovery scope before the first session mutation.
    Write-JsonUtf8Bom -Path $restorePath -Value ([ordered]@{
        schema_version = 2; source_sha = $SourceSha; acceptance_script_sha256 = $AcceptanceScriptSha256
        restoration_required = $true; original = ConvertTo-HighContrastDocumentSnapshot -Snapshot $original
        restoration_verified = $false; restored = $null
    })
    try {
        [DarkReNamerVmAcceptanceNative]::ApplyHighContrast(($original.Flags -bor 1) -band (-bnot 0x1000), $original.Scheme)
        $active = Wait-HighContrastSettlement -ReadSnapshot { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
            -AcceptSnapshot { param($candidate) ($candidate.Flags -band 1) -ne 0 -and -not (Test-HighContrastColorsEqual -Expected $original -Actual $candidate) } -Label 'appearance pair High Contrast activation' -MaximumAttempts 24
        $activeCapture = Save-ObserverAppearanceSystemCapture -Application $Application -Grid $Grid -SessionId $SessionId -EvidenceRoot $EvidenceRoot -Phase 'forced-colors' -Captures $Captures
        if ($activeCapture.resolution.resolved_theme -cne 'native') { throw 'Forced Colors probe did not observe native fallback.' }
    }
    finally {
        [DarkReNamerVmAcceptanceNative]::ApplyHighContrast($original.Flags, $original.Scheme)
        $restored = Wait-HighContrastRestoration -Expected $original -ReadSnapshot { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
            -Label 'appearance pair High Contrast restoration' -AllowPaletteRestore -MaximumAttempts 24 -FallbackAttempts 12
        Write-JsonUtf8Bom -Path $restorePath -Value ([ordered]@{
            schema_version = 2; source_sha = $SourceSha; acceptance_script_sha256 = $AcceptanceScriptSha256
            restoration_required = $false; original = ConvertTo-HighContrastDocumentSnapshot -Snapshot $original
            restoration_verified = $true; restored = ConvertTo-HighContrastDocumentSnapshot -Snapshot $restored
        })
    }
    $after = Save-ObserverAppearanceSystemCapture -Application $Application -Grid $Grid -SessionId $SessionId -EvidenceRoot $EvidenceRoot -Phase 'after' -Captures $Captures
    [ordered]@{
        snapshot = [ordered]@{ file = 'high-contrast-restore.json'; sha256 = Get-LowerSha256 -Path $restorePath }
        restoration_verified = $true; original_enabled = $false; acceptance_enabled = $true
        before = $before; active = $activeCapture; after = $after
    }
}
function Invoke-ObserverAppearancePairScenario {
    param(
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [AllowNull()][Collections.Generic.List[object]] $ProcessLifecycleObservations,
        [Collections.IDictionary] $ObservationSink,
        [string] $SourceSha, [string] $AcceptanceScriptSha256, [switch] $HighContrast
    )
    if ($null -eq $ObservationSink) { $ObservationSink = [ordered]@{} }
    $root = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'appearance-fixture'
    $parent = New-PrivateDirectory -Parent $root -Leaf '한국어-日本語-long-path-2026'
    $paths = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt 60; $index++) {
        $leaf = '{0:D2}-한국어-日本語-{1}.txt' -f $index,('긴이름-長い名前-' * 6)
        $path = Join-Path $parent $leaf
        [IO.File]::WriteAllText($path, ('appearance-fixture-{0:D2}' -f $index), [Text.UTF8Encoding]::new($false))
        [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::Parse('2026-01-01T00:00:00Z').AddMinutes($index))
        $paths.Add($path)
    }
    $oneList = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths @($paths[0]) -Leaf 'appearance-one-utf16le.txt'
    $remainingList = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths @($paths.ToArray() | Select-Object -Skip 1) -Leaf 'appearance-remaining-utf16le.txt'
    $initial = Get-ObserverAppearanceFixtureState -Root $root -Paths $paths.ToArray()
    $columnPreference = New-ObserverAppearanceColumnPreference -RuntimeRoot $RuntimeRoot
    $columnPreferenceBytes = Get-ObserverAppearanceColumnPreferenceBytes
    $application = $null
    try {
        $applicationPath = Join-Path $Verified.root $Verified.application.file
        if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.application.sha256) {
            throw 'Appearance application changed after bundle verification.'
        }
        $application = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'appearance pair application' -ProcessLifecycleObservations $ProcessLifecycleObservations
        $minimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $application.main -Process $application.process -ExpectedSession $SessionId
        $environment = Get-ObserverEnvironmentMetadata -Application $application
        $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $application.main
        $environment['system_visual_style'] = Get-ObserverSystemVisualStyle
        $environment['target_rendering'] = Get-ObserverAppearanceRenderingEnvironment -Application $application
        $environment['installed_fonts'] = Get-ObserverAppearanceInstalledFontEnvironment
        $requested = $script:contract.requested_small_workspace
        $environment['requested_small_workspace'] = [ordered]@{
            width = [int]$requested.width; height = [int]$requested.height
            actual_screen_matches = $environment.physical_screen.width -eq $requested.width -and $environment.physical_screen.height -eq $requested.height
            display_mode_advertised = $true; status = 'observed-exact'; mutation_attempted = $false
        }
        Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot 'environment-preflight.json') -Value $environment
        if (-not $environment.requested_small_workspace.actual_screen_matches -or
            $environment.hwnd_dpi -ne $script:contract.expected_dpi -or
            $minimum.dpi -ne $script:contract.expected_dpi -or
            $environment.text_scale_factor_percent -ne $script:contract.expected_text_scale_percent) {
            throw 'environment_blocked: appearance pair display, DPI, or text scale differs from request.'
        }
        $grid = Get-ObserverGrid -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds
        $scenes = [ordered]@{}
        $ObservationSink['scenes'] = $scenes
        foreach ($scene in @('empty', 'unchanged', 'overflow', 'changed', 'collision', 'warning', 'selected-active', 'selected-inactive')) {
            if ($scene -eq 'unchanged') {
                [void](Import-GuiRegressionPathList -Application $application -PathsFile $oneList -ExpectedRows 1 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid)
            }
            elseif ($scene -eq 'overflow') {
                [void](Import-GuiRegressionPathList -Application $application -PathsFile $remainingList -ExpectedRows 60 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid)
                [void](Set-ObserverSelectedRow -Application $application -Grid $grid -Row 0 -SessionId $SessionId)
                $grid.element.SetFocus()
                $scrollObject = $null
                if (-not $grid.element.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$scrollObject)) {
                    throw 'Transition preservation fixture lacks native scroll control.'
                }
                $scroll = [Windows.Automation.ScrollPattern]$scrollObject
                if (-not $scroll.Current.HorizontallyScrollable -or -not $scroll.Current.VerticallyScrollable) {
                    throw 'Transition preservation fixture must scroll on both axes.'
                }
                $scroll.SetScrollPercent(45.0, 45.0)
                Start-Sleep -Milliseconds 150
                [void](Invoke-ObserverAppearanceTransitionPreservation `
                    -ReadSnapshot { param($phase) Get-ObserverAppearanceTransitionSnapshot -Application $application -Grid $grid `
                        -ExecutableSha256 $Verified.application.sha256 -ColumnPreferencePath $columnPreference.path `
                        -ExpectedPreferenceBytes $columnPreferenceBytes -SessionId $SessionId -Phase $phase } `
                    -SetAppearance { param($appearance) [void](Set-AcceptanceAppearance -Process $application.process `
                        -ExpectedSession $SessionId -MainWindowHandle ([IntPtr]$application.main_handle) -Appearance $appearance) } `
                    -ObservationSink $ObservationSink `
                    -Fixture ([ordered]@{ source = 'isolated-persisted-user-settings';
                        column_preference_sha256 = $columnPreference.sha256; row_count = 60 }))
            }
            elseif ($scene -eq 'changed') {
                Set-ObserverManualName -Application $application -Grid $grid -Row 0 -Name 'paired-change-00.txt' -SessionId $SessionId -WaitSeconds $WaitSeconds
                [void](Set-ObserverSelectedRow -Application $application -Grid $grid -Row 2 -SessionId $SessionId)
            }
            elseif ($scene -eq 'collision') {
                Reset-ObserverAppearanceProposals -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds
                Set-ObserverManualName -Application $application -Grid $grid -Row 0 -Name 'paired-collision.txt' -SessionId $SessionId -WaitSeconds $WaitSeconds
                Set-ObserverManualName -Application $application -Grid $grid -Row 1 -Name 'paired-collision.txt' -SessionId $SessionId -WaitSeconds $WaitSeconds
                [void](Set-ObserverSelectedRow -Application $application -Grid $grid -Row 2 -SessionId $SessionId)
            }
            elseif ($scene -eq 'warning') {
                Reset-ObserverAppearanceProposals -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds
                Set-ObserverManualName -Application $application -Grid $grid -Row 0 -Name '.txt' -SessionId $SessionId -WaitSeconds $WaitSeconds
                [void](Set-ObserverSelectedRow -Application $application -Grid $grid -Row 2 -SessionId $SessionId)
            }
            elseif ($scene -eq 'selected-active') {
                Reset-ObserverAppearanceProposals -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds
                $scrollObject = $null
                if (-not $grid.element.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$scrollObject)) {
                    throw 'Appearance selection fixture lacks horizontal scroll control.'
                }
                ([Windows.Automation.ScrollPattern]$scrollObject).SetScrollPercent(0.0, [Windows.Automation.ScrollPattern]::NoScroll)
                [void](Set-ObserverSelectedRow -Application $application -Grid $grid -Row 0 -SessionId $SessionId)
            }
            $steps = [Collections.Generic.List[object]]::new()
            foreach ($step in @('light-before', 'dark', 'light-after')) {
                $appearance = if ($step -eq 'dark') { 'dark' } else { 'light' }
                [void](Set-AcceptanceAppearance -Process $application.process -ExpectedSession $SessionId -MainWindowHandle ([IntPtr]$application.main_handle) -Appearance $appearance)
                Start-Sleep -Milliseconds 200
                $count = [int]$grid.pattern.Current.RowCount
                if ($count -ne @{'empty'=0; 'unchanged'=1; 'overflow'=60; 'changed'=60; 'collision'=60; 'warning'=60; 'selected-active'=60; 'selected-inactive'=60}[$scene]) { throw 'Appearance scene row count changed.' }
                $names = [Collections.Generic.List[string]]::new()
                for ($index = 0; $index -lt $count; $index++) {
                    $names.Add([string]$grid.pattern.GetItem($index, 0).Current.Name)
                }
                $listHandle = [IntPtr]$grid.element.Current.NativeWindowHandle
                $columns = @(0..2 | ForEach-Object { [DarkReNamerVmAcceptanceNative]::ReadListViewColumnWidth($listHandle, $_) })
                if (($columns -join ',') -cne ((Get-ObserverAppearanceColumnWidthsPx -Dpi $minimum.dpi) -join ',')) {
                    throw 'Appearance native column widths differ from seeded user settings.'
                }
                $preferenceHash = Assert-ObserverAppearanceColumnPreference -Path $columnPreference.path -ExpectedBytes $columnPreferenceBytes
                if ($preferenceHash -cne $columnPreference.sha256) {
                    throw 'Appearance column preference digest changed.'
                }
                $horizontal = [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 0)
                $vertical = [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 1)
                $horizontalBounds = [DarkReNamerVmAcceptanceNative]::TryReadScrollBarBounds($listHandle, 0)
                $verticalBounds = [DarkReNamerVmAcceptanceNative]::TryReadScrollBarBounds($listHandle, 1)
                if ($scene -eq 'overflow') {
                    foreach ($axis in 0..1) {
                        $scroll = if ($axis -eq 0) { $horizontal } else { $vertical }
                        if ($null -eq $scroll -or $scroll.Count -ne 5 -or $scroll[1] - $scroll[0] + 1 -le $scroll[2]) {
                            throw 'Appearance overflow fixture did not expose both scrollbars.'
                        }
                    }
                    if ($null -eq $horizontalBounds -or $null -eq $verticalBounds -or
                        $horizontalBounds[2] -le $horizontalBounds[0] -or $verticalBounds[3] -le $verticalBounds[1]) {
                        throw 'Appearance overflow lacks observed native scrollbar rectangles.'
                    }
                }
                $apply = Get-ObserverPublicApplyState -Application $application -SessionId $SessionId -Label 'appearance unchanged Apply'
                $expectedApply = $scene -in @('changed', 'warning')
                if ([bool]$apply.enabled -ne $expectedApply) { throw "Appearance $scene Apply readiness differs." }
                $proposedCell = $null
                if ($scene -in @('changed', 'collision', 'warning')) {
                    $proposedCell = Show-ObserverAppearanceProposalCell -Grid $grid
                }
                elseif ($scene -in @('selected-active', 'selected-inactive')) {
                    $scrollObject = $null
                    if (-not $grid.element.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$scrollObject)) {
                        throw 'Appearance selected ListView lacks horizontal scroll control.'
                    }
                    ([Windows.Automation.ScrollPattern]$scrollObject).SetScrollPercent(0.0, [Windows.Automation.ScrollPattern]::NoScroll)
                }
                if ($scene -eq 'selected-inactive') {
                    $focusButton = Find-UniqueAutomationElement -Root $application.main -Process $application.process `
                        -ExpectedSession $SessionId -AutomationId '32773' -ControlType ([Windows.Automation.ControlType]::Button) `
                        -TimeoutSeconds $WaitSeconds -Label 'appearance inactive-selection focus target' -RequireEnabled -RequireWindowHandle
                    $focusButton.SetFocus()
                }
                else { $grid.element.SetFocus() }
                Start-Sleep -Milliseconds 150
                $focused = Get-FocusedAcceptanceElement -Process $application.process -ExpectedSession $SessionId -Label 'appearance settled list focus'
                $expectedFocus = if ($scene -eq 'selected-inactive') { '32773' } else { '1000' }
                # UIA may report a focused ListItem after row selection. Bind
                # keyboard focus to the native control, retaining the UIA identity.
                $nativeFocus = [DarkReNamerVmAcceptanceNative]::ReadGuiThreadSnapshot([IntPtr]$application.main_handle, [uint32]$application.process.Id)
                if ([string]$nativeFocus[2] -cne $expectedFocus -or
                    ($scene -ne 'selected-inactive' -and $nativeFocus[0] -ne $listHandle.ToInt64()) -or
                    ($scene -eq 'selected-inactive' -and $nativeFocus[0] -ne $focusButton.Current.NativeWindowHandle)) {
                    throw "Appearance $scene native focus did not settle: control=$($nativeFocus[2]), UIA=$($focused.Current.AutomationId)."
                }
                $proposalViewport = $null
                if ($null -ne $proposedCell) {
                    $position = [DarkReNamerVmAcceptanceNative]::SetListHorizontalViewport($listHandle, [uint32]$application.process.Id)
                    Start-Sleep -Milliseconds 100
                    $proposalViewport = [ordered]@{ query = 'LVM_SCROLL horizontal scalar pixels after focus'; percent = 45; requested = $position[0]; observed = $position[1] }
                    $proposedCell = $grid.pattern.GetItem(0, 1)
                    $focused = Get-FocusedAcceptanceElement -Process $application.process -ExpectedSession $SessionId -Label 'appearance exact viewport focus'
                }
                $status = Find-UniqueAutomationElement -Root $application.main -Process $application.process -ExpectedSession $SessionId -AutomationId '1007' -ControlType ([Windows.Automation.ControlType]::Text) -TimeoutSeconds $WaitSeconds -Label 'appearance status' -RequireWindowHandle
                if (($scene -eq 'collision' -and $status.Current.Name.IndexOf('대상 경로 충돌', [StringComparison]::Ordinal) -lt 0) -or
                    ($scene -eq 'warning' -and $status.Current.Name.IndexOf('이름 본체가 비어 있는 항목', [StringComparison]::Ordinal) -lt 0)) {
                    throw "Appearance $scene status did not expose its semantic warning."
                }
                # Observe the settled viewport, after proposal exposure/selection
                # and focus commands that can move the native scroll position.
                $horizontal = [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 0)
                $vertical = [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo($listHandle, 1)
                $horizontalBounds = [DarkReNamerVmAcceptanceNative]::TryReadScrollBarBounds($listHandle, 0)
                $verticalBounds = [DarkReNamerVmAcceptanceNative]::TryReadScrollBarBounds($listHandle, 1)
                $selection = Get-ObserverAppearanceSelection -Grid $grid
                if ($scene -in @('selected-active', 'selected-inactive') -and $selection.count -ne 1) {
                    throw "Appearance $scene lost the selected row."
                }
                $overlay = Assert-ObserverAppearanceNoTooltip -Application $application
                $state = [ordered]@{
                    overlay = $overlay
                    target_rendering = Get-ObserverAppearanceRenderingEnvironment -Application $application
                    row_count = $count; current_names = $names.ToArray(); columns = $columns
                    column_preference_sha256 = $preferenceHash
                    horizontal_scroll = if ($null -eq $horizontal) { $null } else { @($horizontal) }
                    proposal_viewport = $proposalViewport
                    vertical_scroll = if ($null -eq $vertical) { $null } else { @($vertical) }
                    horizontal_scrollbar_bounds = if ($null -eq $horizontalBounds) { $null } else { @($horizontalBounds) }
                    vertical_scrollbar_bounds = if ($null -eq $verticalBounds) { $null } else { @($verticalBounds) }
                    apply_enabled = [bool]$apply.enabled; status = [string]$status.Current.Name
                    selection = $selection
                    selected_row_cell = if ($scene -in @('selected-active', 'selected-inactive')) { Get-ElementObservation -Element ($grid.pattern.GetItem(0, 0)) } else { $null }
                    proposed_name = if ($null -eq $proposedCell) { $null } else { [string]$proposedCell.Current.Name }
                    proposed_cell = if ($null -eq $proposedCell) { $null } else { Get-ElementObservation -Element $proposedCell }
                    current_name_cell = if ($null -eq $proposedCell) { $null } else { Get-ElementObservation -Element ($grid.pattern.GetItem(0, 0)) }
                    focus_automation_id = [string]$nativeFocus[2]
                    native_focus = @($nativeFocus)
                    focused_uia = Get-ElementObservation -Element $focused
                    appearance_menu = Get-VmAutomatedAppearance -Window $application.main -Process $application.process -ExpectedSession $SessionId
                    list_physical_target = Get-GuiRegressionPhysicalTarget -Element $grid.element -Application $application -SessionId $SessionId -ExpectedRoot ([IntPtr]$application.main_handle) -Label 'appearance unobscured list'
                    list = Get-ElementObservation -Element $grid.element
                    native_list = Get-ObserverNativeWindowMetrics -Window $grid.element
                    native_header = Get-ObserverNativeWindowMetrics -Window ([Windows.Automation.AutomationElement]::FromHandle(
                        [DarkReNamerVmAcceptanceNative]::ReadBoundListHeader($listHandle, [uint32]$application.process.Id)))
                    window = Get-ObserverNativeWindowMetrics -Window $application.main
                }
                $leaf = "appearance-$scene-$step.png"
                $capture = Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $application.main -Process $application.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf $leaf -Label "appearance $scene $step"
                $Captures.Add((Add-AcceptanceScreenshotContext -Screenshot $capture -Appearance $appearance -Surface 'main-workbench'))
                $steps.Add([ordered]@{ phase = $step; appearance = $appearance; state = $state; capture = $capture })
            }
            $scenes[$scene] = $steps.ToArray()
        }
        $interactions = [Collections.Generic.List[object]]::new()
        $ObservationSink['interactions'] = $interactions
        foreach ($step in @('light-before', 'dark', 'light-after')) {
            $appearance = if ($step -eq 'dark') { 'dark' } else { 'light' }
            [void](Set-AcceptanceAppearance -Process $application.process -ExpectedSession $SessionId `
                -MainWindowHandle ([IntPtr]$application.main_handle) -Appearance $appearance)
            $prefix = Find-UniqueAutomationElement -Root $application.main -Process $application.process `
                -ExpectedSession $SessionId -AutomationId '32773' -ControlType ([Windows.Automation.ControlType]::Button) `
                -TimeoutSeconds $WaitSeconds -Label 'appearance prefix button' -RequireEnabled -RequireWindowHandle
            $applyButton = Find-UniqueAutomationElement -Root $application.main -Process $application.process `
                -ExpectedSession $SessionId -AutomationId '32771' -ControlType ([Windows.Automation.ControlType]::Button) `
                -TimeoutSeconds $WaitSeconds -Label 'appearance disabled Apply button' -RequireWindowHandle
            if ($prefix.Current.IsOffscreen -or $applyButton.Current.IsOffscreen -or $applyButton.Current.IsEnabled) {
                throw 'Appearance button-state fixture lacks visible enabled and disabled controls.'
            }
            $prefixTarget = Get-GuiRegressionPhysicalTarget -Element $prefix -Application $application -SessionId $SessionId `
                -ExpectedRoot ([IntPtr]$application.main_handle) -Label 'appearance prefix button'
            $applyTarget = Get-GuiRegressionPhysicalTarget -Element $applyButton -Application $application -SessionId $SessionId `
                -ExpectedRoot ([IntPtr]$application.main_handle) -Label 'appearance disabled Apply button'
            $buttons = [ordered]@{}
            $grid.element.SetFocus()
            [void](Assert-ObserverAppearanceNoTooltip -Application $application)
            $buttons['normal'] = [ordered]@{
                cursor = @([DarkReNamerVmAcceptanceNative]::ReadBoundCursor([IntPtr]$application.main_handle, [uint32]$application.process.Id))
                control = Get-ElementObservation -Element $prefix
                focus_automation_id = Get-ObserverAppearanceFocusId -Application $application -SessionId $SessionId
                native_button_state = [DarkReNamerVmAcceptanceNative]::ReadButtonState([IntPtr]$prefix.Current.NativeWindowHandle)
                target = $prefixTarget
                capture = Save-ObserverAppearanceCapture -Application $application -Window $application.main -EvidenceRoot $EvidenceRoot `
                    -Leaf "appearance-button-normal-$step.png" -Appearance $appearance -Surface 'main-workbench' -SessionId $SessionId -Captures $Captures
            }
            $buttons['disabled'] = [ordered]@{
                cursor = @([DarkReNamerVmAcceptanceNative]::ReadBoundCursor([IntPtr]$application.main_handle, [uint32]$application.process.Id))
                control = Get-ElementObservation -Element $applyButton
                focus_automation_id = Get-ObserverAppearanceFocusId -Application $application -SessionId $SessionId
                native_button_state = [DarkReNamerVmAcceptanceNative]::ReadButtonState([IntPtr]$applyButton.Current.NativeWindowHandle)
                target = $applyTarget
                capture = Save-ObserverAppearanceCapture -Application $application -Window $application.main -EvidenceRoot $EvidenceRoot `
                    -Leaf "appearance-button-disabled-$step.png" -Appearance $appearance -Surface 'main-workbench' -SessionId $SessionId -Captures $Captures
            }
            [DarkReNamerVmAcceptanceNative]::MoveCursor([int]$prefixTarget.x, [int]$prefixTarget.y)
            Start-Sleep -Milliseconds 150
            $buttons['hover'] = [ordered]@{
                cursor = @([DarkReNamerVmAcceptanceNative]::ReadBoundCursor([IntPtr]$application.main_handle, [uint32]$application.process.Id))
                control = Get-ElementObservation -Element $prefix
                focus_automation_id = Get-ObserverAppearanceFocusId -Application $application -SessionId $SessionId
                native_button_state = [DarkReNamerVmAcceptanceNative]::ReadButtonState([IntPtr]$prefix.Current.NativeWindowHandle)
                target = $prefixTarget
                capture = Save-ObserverAppearanceCapture -Application $application -Window $application.main -EvidenceRoot $EvidenceRoot `
                    -Leaf "appearance-button-hover-$step.png" -Appearance $appearance -Surface 'main-workbench' -SessionId $SessionId -Captures $Captures
            }
            try {
                [DarkReNamerVmAcceptanceNative]::PressLeftButton()
                Start-Sleep -Milliseconds 150
                $pressedState = [DarkReNamerVmAcceptanceNative]::ReadButtonState([IntPtr]$prefix.Current.NativeWindowHandle)
                if (($pressedState -band 4) -eq 0) { throw 'Appearance button did not enter native pressed state.' }
                $buttons['pressed'] = [ordered]@{
                    cursor = @([DarkReNamerVmAcceptanceNative]::ReadBoundCursor([IntPtr]$application.main_handle, [uint32]$application.process.Id))
                    control = Get-ElementObservation -Element $prefix
                    focus_automation_id = Get-ObserverAppearanceFocusId -Application $application -SessionId $SessionId
                    native_button_state = $pressedState
                    target = $prefixTarget
                    capture = Save-ObserverAppearanceCapture -Application $application -Window $application.main -EvidenceRoot $EvidenceRoot `
                        -Leaf "appearance-button-pressed-$step.png" -Appearance $appearance -Surface 'main-workbench' -SessionId $SessionId -Captures $Captures
                }
            }
            finally {
                try { [void](Assert-ObserverAppearanceNoTooltip -Application $application) }
                finally { [DarkReNamerVmAcceptanceNative]::ReleaseLeftButton() }
            }
            if (([DarkReNamerVmAcceptanceNative]::ReadButtonState([IntPtr]$prefix.Current.NativeWindowHandle) -band 4) -ne 0) {
                throw 'Appearance button stayed native-pressed after release outside its bounds.'
            }
            [void](Move-RailFocusToCommand -Process $application.process -ExpectedSession $SessionId -AutomationId '32773')
            $buttons['keyboard-focus'] = [ordered]@{
                cursor = @([DarkReNamerVmAcceptanceNative]::ReadBoundCursor([IntPtr]$application.main_handle, [uint32]$application.process.Id))
                control = Get-ElementObservation -Element $prefix
                focus_automation_id = Get-ObserverAppearanceFocusId -Application $application -SessionId $SessionId
                native_button_state = [DarkReNamerVmAcceptanceNative]::ReadButtonState([IntPtr]$prefix.Current.NativeWindowHandle)
                target = $prefixTarget
                capture = Save-ObserverAppearanceCapture -Application $application -Window $application.main -EvidenceRoot $EvidenceRoot `
                    -Leaf "appearance-button-keyboard-focus-$step.png" -Appearance $appearance -Surface 'main-workbench' -SessionId $SessionId -Captures $Captures
            }

            Send-AcceptanceChord -Process $application.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x56 -Label 'appearance View menu accelerator'
            $popup = Wait-AcceptancePopupMenu -Process $application.process -ExpectedSession $SessionId -Label 'appearance View menu'
            try {
                $menuCapture = Save-AcceptanceNativeMenuScreenshot -MainWindow $application.main -Popup $popup `
                    -Process $application.process -ExpectedSession $SessionId -Root $EvidenceRoot `
                    -Leaf "appearance-native-menu-$step.png" -Label 'appearance native View menu'
                $Captures.Add((Add-AcceptanceScreenshotContext -Screenshot $menuCapture -Appearance $appearance -Surface 'native-menu'))
                $menu = [ordered]@{ popup_hwnd = $popup.ToInt64(); popup = Get-ElementObservation -Element ([Windows.Automation.AutomationElement]::FromHandle($popup)); capture = $menuCapture }
            }
            finally {
                Send-AcceptanceTap -Process $application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label 'appearance View menu Escape'
                Wait-AcceptancePopupMenuClosed -Process $application.process -Label 'appearance View menu'
            }

            [DarkReNamerVmAcceptanceNative]::SendMenuCommand([IntPtr]$application.main_handle, [uint32]0x9013)
            $dialog = Wait-UniqueAutomationWindow -Process $application.process -ExpectedSession $SessionId `
                -MainWindowHandle ([IntPtr]$application.main_handle) -Name 'DarkReNamer - 모양 설정 (미리보기)' `
                -TimeoutSeconds $WaitSeconds -Label 'appearance advanced dialog'
            $dialogHandle = [IntPtr]$dialog.Current.NativeWindowHandle
            try {
                $advanced = [ordered]@{
                    window = Get-ElementObservation -Element $dialog
                    native_window = Get-ObserverNativeWindowMetrics -Window $dialog
                    capture = Save-ObserverAppearanceCapture -Application $application -Window $dialog -EvidenceRoot $EvidenceRoot `
                        -Leaf "appearance-advanced-$step.png" -Appearance $appearance -Surface 'advanced-appearance' -SessionId $SessionId -Captures $Captures
                }
            }
            finally {
                Send-AcceptanceTap -Process $application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label 'appearance advanced Escape'
                Wait-WindowClosed -Handle $dialogHandle -TimeoutSeconds $WaitSeconds -Label 'appearance advanced dialog'
            }
            $application.main.SetFocus()
            [void][DarkReNamerVmNative]::SetForegroundWindow([IntPtr]$application.main_handle)

            $promptObservations = [ordered]@{}
            $prompt = Invoke-CurrentDpiPrefixActivation -Process $application.process -MainWindow $application.main `
                -ExpectedSessionId $SessionId -TimeoutSeconds $WaitSeconds -Observations $promptObservations
            $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
            try {
                $edit = Find-UniqueAutomationElement -Root $prompt -Process $application.process -ExpectedSession $SessionId `
                    -AutomationId '1004' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $WaitSeconds -Label 'appearance prefix edit' -RequireWindowHandle
                $ok = Find-UniqueAutomationElement -Root $prompt -Process $application.process -ExpectedSession $SessionId `
                    -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'appearance prefix default OK' -RequireEnabled -RequireWindowHandle
                $label = Find-UniqueAutomationElement -Root $prompt -Process $application.process -ExpectedSession $SessionId `
                    -AutomationId '1002' -ControlType ([Windows.Automation.ControlType]::Text) -TimeoutSeconds $WaitSeconds -Label 'appearance prefix native label' -RequireWindowHandle
                $labelNative = [DarkReNamerVmAcceptanceNative]::DescribeWindow([IntPtr]$label.Current.NativeWindowHandle)
                $labelText = [DarkReNamerVmAcceptanceNative]::ReadBoundStaticText([IntPtr]$label.Current.NativeWindowHandle, $promptHandle, [uint32]$application.process.Id)
                if ($label.Current.Name -cne '붙일 문자열' -or $labelNative[3] -ine 'Static' -or $labelText -cne '붙일 문자열' -or
                    [int]$labelNative[2] -ne $application.process.Id) {
                    throw 'Appearance prefix native label identity differs.'
                }
                $defaultId = [DarkReNamerVmAcceptanceNative]::ReadDefaultPushButtonId([IntPtr]$ok.Current.NativeWindowHandle)
                if ($edit.Current.Name -cne '붙일 문자열' -or $defaultId -ne 1) {
                    throw "Appearance prefix prompt lost its label or default button: label=$($edit.Current.Name), default=$defaultId."
                }
                $promptState = [ordered]@{
                    window = Get-ElementObservation -Element $prompt
                    native_window = Get-ObserverNativeWindowMetrics -Window $prompt
                    edit = Get-ElementObservation -Element $edit
                    same_glyph_label = [ordered]@{
                        control = Get-ElementObservation -Element $label
                        native_window = Get-ObserverNativeWindowMetrics -Window $label
                        native_class = $labelNative[3]
                        text_sha256 = Get-LowerTextSha256 -Value '붙일 문자열'
                        query = 'bound STATIC/WM_GETTEXT original prompt raster'
                    }
                    default_button = Get-ElementObservation -Element $ok
                    default_button_id = $defaultId
                    default_button_query = 'WM_GETDLGCODE(DLGC_BUTTON|DLGC_DEFPUSHBUTTON)+GetDlgCtrlID'
                    capture = Save-ObserverAppearanceCapture -Application $application -Window $prompt -EvidenceRoot $EvidenceRoot `
                        -Leaf "appearance-input-prompt-$step.png" -Appearance $appearance -Surface 'input-prompt' -SessionId $SessionId -Captures $Captures
                }
            }
            finally {
                Send-AcceptanceTap -Process $application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label 'appearance prefix prompt Cancel'
                Wait-WindowClosed -Handle $promptHandle -TimeoutSeconds $WaitSeconds -Label 'appearance prefix prompt'
            }
            if ((Get-ObserverPublicApplyState -Application $application -SessionId $SessionId -Label 'appearance prompt Cancel Apply').enabled) {
                throw 'Appearance canceled prompt enabled Apply.'
            }
            $scrollbars = Invoke-ObserverAppearanceScrollProbe -Application $application -Grid $grid -EvidenceRoot $EvidenceRoot -Phase $step -Appearance $appearance -SessionId $SessionId -Captures $Captures
            $preferenceHash = Assert-ObserverAppearanceColumnPreference -Path $columnPreference.path -ExpectedBytes $columnPreferenceBytes
            $interactions.Add([ordered]@{
                phase = $step; appearance = $appearance; buttons = $buttons
                native_menu = $menu; advanced_appearance = $advanced; input_prompt = $promptState
                scrollbars = $scrollbars
                column_preference_sha256 = $preferenceHash
                selected = Get-ObserverAppearanceSelection -Grid $grid
                appearance_menu = Get-VmAutomatedAppearance -Window $application.main -Process $application.process -ExpectedSession $SessionId
            })
        }
        $highContrastResult = $null
        if ($HighContrast) {
            Set-ObserverManualName -Application $application -Grid $grid -Row 0 -Name '.txt' -SessionId $SessionId -WaitSeconds $WaitSeconds
            Set-ObserverManualName -Application $application -Grid $grid -Row 1 -Name '.log' -SessionId $SessionId -WaitSeconds $WaitSeconds
            [void](Set-ObserverSelectedRow -Application $application -Grid $grid -Row 0 -SessionId $SessionId)
            $highContrastResult = Invoke-ObserverAppearanceSystemProbe -Application $application -Grid $grid -SessionId $SessionId `
                -EvidenceRoot $EvidenceRoot -SourceSha $SourceSha -AcceptanceScriptSha256 $AcceptanceScriptSha256 -Captures $Captures
        }
        $after = Get-ObserverAppearanceFixtureState -Root $root -Paths $paths.ToArray()
        if (-not (Test-ObserverFixtureStateEqual -Expected $initial -Actual $after)) {
            throw 'Appearance pair changed a fixture file, content digest, or NTFS identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $exitCode = Close-AcceptanceApplication -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
        $ObservationSink['environment'] = $environment
        $ObservationSink['appearance'] = 'light-dark-light'
        $ObservationSink['process_id'] = [int]$application.process.Id
        $ObservationSink['fixture'] = [ordered]@{
            file_count = 60; disk_unchanged = $true; journal_residue_count = 0; column_preferences = $columnPreference
        }
        $ObservationSink['normal_exit_code'] = $exitCode
        $ObservationSink['high_contrast'] = $highContrastResult
        $ObservationSink['limitations'] = if ($HighContrast) {
            @('normal OS Light/Dark setting transitions not-run; current System resolution and Forced Colors restoration observed')
        } else { @('system-theme and forced-colors configurations not-run in this diagnostic') }
        [void](Invoke-ObserverAppearanceDefaultColumnsScene -Verified $Verified -RuntimeRoot $RuntimeRoot `
            -EvidenceRoot $EvidenceRoot -PathsFile $oneList -RowName ([IO.Path]::GetFileName($paths[0])) `
            -FixtureRoot $root -FixturePaths $paths.ToArray() -ExpectedFixtureState $initial `
            -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedEnvironment $environment `
            -CustomProcessId ([int]$application.process.Id) -Captures $Captures `
            -ProcessLifecycleObservations $ProcessLifecycleObservations -ObservationSink $ObservationSink)
        $ObservationSink['interactions'] = $interactions.ToArray()
        $ObservationSink
    }
    finally { if ($null -ne $application) { Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned } }
}

function Get-ObserverIconStatusSnapshot {
    param([Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][long] $StartUtcTicks)

    $value = [DarkReNamerIconStatusObserver]::ReadBound(
        $Application.process, [IntPtr]$Application.main_handle, $StartUtcTicks)
    [ordered]@{
        version = 1
        session = [string]$value.Session
        generation = [string]$value.Generation
        bootstrap = [int]$value.Bootstrap
        queued = [int]$value.Queued
        inflight = [int]$value.InFlight
        undrained = [int]$value.Undrained
        unresolved_rows = [int]$value.UnresolvedRows
        cursor = [int]$value.Cursor
        settled = $value.Settled -eq 1
        worker_joined = $value.WorkerJoined -eq 1
        reconcile_rows = [int]$value.ReconcileRows
        batch_ack = [int]$value.BatchAck
        status_revision = [string]$value.StatusRevision
        demand_exhausted = $value.DemandExhausted -eq 1
        demand_remaining = [int]$value.DemandRemaining
        model_revision = [string]$value.ModelRevision
        unavailable_or_retiring = $value.UnavailableOrRetiring -eq 1
    }
}

function Get-ObserverIconChurnFileName {
    param([Parameter(Mandatory)][ValidateRange(0,999)][int] $Index)

    if ($Index -lt 598 -and $Index % 2 -eq 0) {
        return 'extension-{0:D4}.e{1:D3}' -f $Index,[int]($Index / 2)
    }
    'recurring-{0:D4}.txt' -f $Index
}

function Test-ObserverIconTerminalSnapshot {
    param([Parameter(Mandatory)][Collections.IDictionary] $Snapshot,
        [Parameter(Mandatory)][int] $Rows)

    if ($Snapshot.version -ne 1 -or [ulong]$Snapshot.session -eq 0 -or
        $Snapshot.bootstrap -notin @(0,1,2) -or
        $Snapshot.queued -lt 0 -or $Snapshot.inflight -gt 1 -or
        $Snapshot.queued + $Snapshot.inflight + $Snapshot.undrained -gt 64 -or
        $Snapshot.unresolved_rows -gt $Rows -or $Snapshot.cursor -gt $Rows -or
        $Snapshot.reconcile_rows -gt $Rows -or $Snapshot.demand_remaining -gt $Rows -or
        $Snapshot.batch_ack -gt 64 -or ([ulong]$Snapshot.status_revision -band 1) -ne 0) {
        throw 'Icon status snapshot violates its bounded version-one contract.'
    }
    if ($Snapshot.bootstrap -eq 2) {
        throw 'Icon image-list bootstrap failed; no-image fallback is not icon settlement.'
    }
    if ($Snapshot.unavailable_or_retiring) {
        throw 'Icon worker became unavailable or retired before settlement; no-image fallback is not icon settlement.'
    }
    [ulong]$Snapshot.generation -gt 0 -and
        $Snapshot.bootstrap -eq 1 -and $Snapshot.settled -eq $true -and
        $Snapshot.worker_joined -eq $false -and
        $Snapshot.demand_exhausted -eq $true -and $Snapshot.demand_remaining -eq 0 -and
        $Snapshot.queued -eq 0 -and $Snapshot.inflight -eq 0 -and
        $Snapshot.undrained -eq 0 -and $Snapshot.unresolved_rows -eq 0 -and
        $Snapshot.reconcile_rows -eq 0 -and $Snapshot.batch_ack -eq 0
}

function Test-ObserverIconTransientStatusQueryError {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord] $ErrorRecord)

    $outer = $ErrorRecord.Exception
    $inner = $outer.InnerException
    $outer -is [Management.Automation.MethodInvocationException] -and
        $null -ne $inner -and $inner.GetType() -eq [InvalidOperationException] -and
        $inner.Message -ceq 'Icon status query did not produce a stable published snapshot.'
}

function Wait-ObserverIconSettlementPhase {
    param([Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][long] $StartUtcTicks,
        [Parameter(Mandatory)][long] $OpenTicks,
        [Parameter(Mandatory)][double] $DataReadyMs,
        [Parameter(Mandatory)][int] $Rows,
        [Parameter(Mandatory)][DateTime] $OverallDeadline)

    if ($OpenTicks -le 0 -or $OpenTicks -gt [Diagnostics.Stopwatch]::GetTimestamp() -or
        $DataReadyMs -le 0) {
        throw 'Icon settlement data-ready clock bracket is invalid.'
    }
    $first = $null
    $candidate = $null
    $polls = 0
    $unstableQueries = 0
    $peakPending = 0
    $peakUnresolved = 0
    while ((Get-Date) -lt $OverallDeadline) {
        try {
            $snapshot = Get-ObserverIconStatusSnapshot -Application $Application -StartUtcTicks $StartUtcTicks
        }
        catch {
            if (-not (Test-ObserverIconTransientStatusQueryError -ErrorRecord $_)) {
                throw
            }
            $unstableQueries++
            Start-Sleep -Milliseconds 100
            continue
        }
        $observedTicks = [Diagnostics.Stopwatch]::GetTimestamp()
        if ($null -eq $first) { $first = $snapshot }
        if ($snapshot.session -cne $first.session) { throw 'Icon status session changed during a fixed import.' }
        if ($snapshot.model_revision -cne $first.model_revision) {
            throw 'Icon arrival changed the model revision after data readiness.'
        }
        $polls++
        $pending = $snapshot.queued + $snapshot.inflight + $snapshot.undrained
        $peakPending = [Math]::Max($peakPending, $pending)
        $peakUnresolved = [Math]::Max($peakUnresolved, $snapshot.unresolved_rows)
        $terminal = Test-ObserverIconTerminalSnapshot -Snapshot $snapshot -Rows $Rows
        if ($terminal) {
            if ($null -ne $candidate -and
                $snapshot.generation -ceq $candidate.generation -and
                $snapshot.model_revision -ceq $candidate.model_revision) {
                $settledMs = [Math]::Round(($observedTicks - $OpenTicks) * 1000.0 /
                    [Diagnostics.Stopwatch]::Frequency, 3)
                if ($settledMs -lt $DataReadyMs) {
                    throw 'Icon-settled observation preceded the data-ready endpoint.'
                }
                return [ordered]@{
                    data_ready_ms = $DataReadyMs
                    icon_settled_observed_ms = $settledMs
                    first_status = $first
                    settled_status = $candidate
                    confirmation_status = $snapshot
                    poll_count = $polls
                    unstable_query_attempts = $unstableQueries
                    sampled_peak_pending = $peakPending
                    sampled_peak_unresolved_rows = $peakUnresolved
                }
            }
            $candidate = $snapshot
        }
        else { $candidate = $null }
        Start-Sleep -Milliseconds 100
    }
    throw 'Icon settlement was not observed before the fixed diagnostic deadline.'
}

function Invoke-ObserverIconSettlementScenario {
    param([Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][ValidateSet('async-status-v1', 'synchronous-row-count-upper-bound-v1')]
        [string] $EndpointMethod,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [AllowNull()][Collections.Generic.List[object]] $ProcessLifecycleObservations,
        [Parameter(Mandatory)][Collections.IDictionary] $ObservationSink)

    $deadline = (Get-Date).AddSeconds([Math]::Min(600, $WaitSeconds))
    $fixture = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'icon-settlement-fixture'
    $ordinary = New-PrivateDirectory -Parent $fixture -Leaf 'ordinary'
    $churn = New-PrivateDirectory -Parent $fixture -Leaf 'churn'
    $ordinaryPaths = [Collections.Generic.List[string]]::new()
    $churnPaths = [Collections.Generic.List[string]]::new()
    foreach ($index in 0..999) {
        $plain = Join-Path $ordinary ('ordinary-{0:D4}.txt' -f $index)
        [IO.File]::WriteAllText($plain, ('icon-ordinary-{0:D4}' -f $index), [Text.Encoding]::ASCII)
        $ordinaryPaths.Add($plain)
        $name = Get-ObserverIconChurnFileName -Index $index
        $interleaved = Join-Path $churn $name
        [IO.File]::WriteAllText($interleaved, ('icon-churn-{0:D4}' -f $index), [Text.Encoding]::ASCII)
        $churnPaths.Add($interleaved)
    }
    $ordinaryList = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths ([string[]]$ordinaryPaths.ToArray()) -Leaf 'icon-ordinary.txt'
    $churnList = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths ([string[]]$churnPaths.ToArray()) -Leaf 'icon-churn.txt'
    $applicationPath = Join-Path $Verified.root $Verified.application.file
    if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.application.sha256) {
        throw 'Icon settlement executable differs from the staged candidate.'
    }
    $ObservationSink['mode'] = 'icon-settlement'
    $ObservationSink['endpoint_method'] = $EndpointMethod
    if ($EndpointMethod -ceq 'synchronous-row-count-upper-bound-v1') {
        $ObservationSink['endpoint_coverage'] = 'source-derived-synchronous-lookup-completion-upper-bound'
        $ObservationSink['baseline_product_source_sha'] = 'b152761010b16ef74e2a3765241a253778b88e0b'
    }
    $ObservationSink['plan'] = [ordered]@{
        ordinary_rows = 1000; churn_rows = 1000; extension_classes = 300
        poll_interval_ms = 100; maximum_seconds = 600
    }
    $application = $null
    try {
        $application = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root `
            -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'icon settlement application' `
            -ProcessLifecycleObservations $ProcessLifecycleObservations
        [void](Ensure-AcceptanceMainWindowCaptureSize -MainWindow $application.main `
            -Process $application.process -ExpectedSession $SessionId)
        $environment = Get-ObserverEnvironmentMetadata -Application $application
        $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $application.main
        if ($environment.physical_screen.width -ne 1366 -or $environment.physical_screen.height -ne 768 -or
            $environment.hwnd_dpi -ne 96 -or $environment.text_scale_factor_percent -ne 100) {
            throw 'Icon settlement display differs from the fixed request.'
        }
        $ObservationSink['environment'] = $environment
        $ObservationSink['process_id'] = [int]$application.process.Id
        $ObservationSink['process_start_utc_ticks'] = [long]$application.process.StartTime.ToUniversalTime().Ticks
        $ObservationSink['executable_sha256'] = $Verified.application.sha256
        $grid = Get-ObserverGrid -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds
        if ($grid.pattern.Current.RowCount -ne 0) { throw 'Icon settlement list was not empty at launch.' }
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations `
            -Window $application.main -Process $application.process -ExpectedSession $SessionId `
            -Root $EvidenceRoot -Leaf 'icon-settlement-empty.png' -Label 'icon settlement empty list'))
        $phases = [Collections.Generic.List[object]]::new()
        $ObservationSink['phases'] = $phases
        foreach ($step in @(
            [ordered]@{ id='ordinary-cached'; file=$ordinaryList; names=@('ordinary-0000.txt','ordinary-0499.txt','ordinary-0999.txt') },
            # The model sorts admitted source paths after reading the interleaved list.
            [ordered]@{ id='interleaved-churn'; file=$churnList; names=@('extension-0000.e000','recurring-0401.txt','recurring-0999.txt') })) {
            $timing = Import-GuiRegressionPathList -Application $application -PathsFile $step.file `
                -ExpectedRows 1000 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid -IncludeOpenTicks
            $receipt = if ($EndpointMethod -ceq 'async-status-v1') {
                Wait-ObserverIconSettlementPhase -Application $application `
                    -StartUtcTicks $ObservationSink['process_start_utc_ticks'] -OpenTicks $timing.open_ticks `
                    -DataReadyMs $timing.elapsed_ms -Rows 1000 -OverallDeadline $deadline
            } else {
                [ordered]@{
                    data_ready_ms = $timing.elapsed_ms
                    synchronous_lookup_completion_upper_bound_ms = $timing.elapsed_ms
                }
            }
            $receipt['id'] = $step.id
            $receipt['rows'] = 1000
            $receipt['representative_names'] = @(0,499,999 | ForEach-Object {
                [string]$grid.pattern.GetItem($_,0).Current.Name
            })
            for ($probe = 0; $probe -lt 3; $probe++) {
                if ($receipt['representative_names'][$probe] -cne $step.names[$probe]) {
                    throw "Icon settlement $($step.id) representative text differs."
                }
            }
            $phases.Add($receipt)
            [DarkReNamerVmAcceptanceNative]::SendBoundPerformanceCommand(
                [IntPtr]$application.main_handle, [uint32]$application.process.Id, [uint32]0x800E)
            if ($grid.pattern.Current.RowCount -ne 0) { throw 'Icon settlement clear did not empty the list.' }
        }
        if ($EndpointMethod -ceq 'async-status-v1' -and
            [ulong]$phases[1].settled_status.generation -le [ulong]$phases[0].settled_status.generation) {
            throw 'Icon settlement clear/repopulate did not advance the request generation.'
        }
        $ObservationSink['phases'] = $phases.ToArray()
        foreach ($group in @([ordered]@{ paths=$ordinaryPaths; prefix='icon-ordinary' },
                           [ordered]@{ paths=$churnPaths; prefix='icon-churn' })) {
            for ($index = 0; $index -lt 1000; $index++) {
                if ([IO.File]::ReadAllText($group.paths[$index], [Text.Encoding]::ASCII) -cne
                    ('{0}-{1:D4}' -f $group.prefix,$index)) {
                    throw 'Icon settlement fixture bytes changed.'
                }
            }
        }
        $ObservationSink['disk_unchanged'] = $true
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $ObservationSink['journal_residue_count'] = 0
        if ($EndpointMethod -ceq 'async-status-v1') {
            $ObservationSink['worker_join_evidence'] = [ordered]@{
                kind = 'source-contract-inference'; observed = $false
            }
        }
        $ObservationSink['normal_exit_code'] = Close-AcceptanceApplication -Application $application `
            -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
        $ObservationSink['appearance'] = 'light'
        return $ObservationSink
    }
    finally { if ($null -ne $application) { Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned } }
}

function New-ObserverRuntimeLanguagePreference {
    param([Parameter(Mandatory)][string] $LocalAppData,
        [Parameter(Mandatory)][ValidateSet(0,2)][int] $Value)

    $directory = New-ObserverAppearancePrivateAppDirectory -Parent $LocalAppData
    $path = Join-Path $directory 'ui-language-v1'
    if (Test-Path -LiteralPath $path) { throw 'Runtime baseline language fixture is not fresh.' }
    $bytes = [byte[]]::new(20)
    [Text.Encoding]::ASCII.GetBytes("DRLANG`0`0").CopyTo($bytes, 0)
    $bytes[8] = 1
    $bytes[12] = [byte]$Value
    $hash = [uint32]2166136261
    foreach ($index in 0..15) {
        $hash = [uint32]((([uint64]($hash -bxor [uint32]$bytes[$index])) *
            [uint64]16777619) -band [uint64]4294967295)
    }
    [BitConverter]::GetBytes($hash).CopyTo($bytes, 16)
    [IO.File]::WriteAllBytes($path, $bytes)
    $record = Read-ProductionLanguagePreference -LocalAppData $LocalAppData
    if ($record.value -ne $Value) { throw 'Runtime baseline language fixture failed its production decoder.' }
    return $record
}

function Read-ObserverRuntimeAppearancePreference {
    param([Parameter(Mandatory)][string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -ne 24) { throw 'Runtime appearance preference length or file kind is invalid.' }
    $bytes = [byte[]]::new(24)
    $share = [IO.FileShare]([int][IO.FileShare]::ReadWrite -bor [int][IO.FileShare]::Delete)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        if ($stream.Length -ne 24) { throw 'Runtime appearance preference length changed.' }
        $count = 0
        while ($count -lt $bytes.Length) {
            $read = $stream.Read($bytes, $count, $bytes.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -ne 24 -or $stream.ReadByte() -ne -1) {
            throw 'Runtime appearance preference changed during its bounded read.'
        }
    }
    finally { $stream.Dispose() }
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 8) -cne "DRAPPR`0`0" -or
        $bytes[8] -ne 1 -or $bytes[9] -ne 8 -or $bytes[10] -ne 0 -or $bytes[11] -ne 0) {
        throw 'Runtime appearance preference header is invalid.'
    }
    $checksum = [uint32]2166136261
    foreach ($index in 0..19) {
        $checksum = [uint32]((([uint64]($checksum -bxor [uint32]$bytes[$index])) *
            [uint64]16777619) -band [uint64]4294967295)
    }
    if ([BitConverter]::ToUInt32($bytes, 20) -ne $checksum) {
        throw 'Runtime appearance preference checksum is invalid.'
    }
    if ($bytes[18] -ne 0 -or $bytes[19] -ne 0 -or $bytes[12] -gt 2 -or
        $bytes[13] -gt 3 -or $bytes[14] -gt 2 -or $bytes[15] -gt 1 -or
        $bytes[16] -gt 1 -or $bytes[17] -gt 1) {
        throw 'Runtime appearance preference reserved bytes, enums, or flags are invalid.'
    }
    [ordered]@{ status='valid-saved'; bytes=24;
        sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        bytes_hex=[Convert]::ToHexString($bytes).ToLowerInvariant()
        value=[ordered]@{ theme=[int]$bytes[12]; density=[int]$bytes[13]; emphasis=[int]$bytes[14];
            show_separators=($bytes[15] -eq 1); show_preview_tint=($bytes[16] -eq 1);
            show_empty_safety=($bytes[17] -eq 1) }
    }
}

function Assert-ObserverRuntimeDefaultAppearancePreference {
    param([Parameter(Mandatory)] $Record)
    $expected = [ordered]@{ theme=0; density=0; emphasis=1; show_separators=$true;
        show_preview_tint=$true; show_empty_safety=$true }
    if (($Record.value | ConvertTo-Json -Compress) -cne ($expected | ConvertTo-Json -Compress)) {
        throw 'Runtime persisted appearance differs from the default System snapshot.'
    }
}

function Get-ObserverRuntimeLightAppearance {
    $resolution = Get-ObserverResolvedSystemAppearance
    if ($resolution.resolved_theme -cne 'light' -or
        $resolution.system_visual_style.forced_colors -isnot [bool] -or
        $resolution.system_visual_style.forced_colors) {
        throw 'Runtime baseline requires observed System Light appearance without Forced Colors.'
    }
    return $resolution
}

function Assert-ObserverRuntimeSystemAppearanceMenu {
    param([Parameter(Mandatory)] $Menu)
    $expected = @(
        [ordered]@{ command_id=0x9010; checked=$true },
        [ordered]@{ command_id=0x9011; checked=$false },
        [ordered]@{ command_id=0x9012; checked=$false })
    if (($Menu.menu_checked | ConvertTo-Json -Compress) -cne
        ($expected | ConvertTo-Json -Compress)) {
        throw 'Runtime baseline product appearance did not retain the fresh System selection.'
    }
}

function Wait-ObserverRuntimeMinimumIdle {
    param([Parameter(Mandatory)][long] $StartTicks,
        [Parameter(Mandatory)][int] $MinimumMilliseconds,
        [Parameter(Mandatory)][datetime] $OverallDeadline,
        [scriptblock] $GetTimestamp = { [Diagnostics.Stopwatch]::GetTimestamp() },
        [scriptblock] $SleepMilliseconds = { param([int] $Milliseconds)
            Start-Sleep -Milliseconds $Milliseconds })

    $frequency = [long][Diagnostics.Stopwatch]::Frequency
    $requiredTicks = [long][Math]::Ceiling($MinimumMilliseconds * [double]$frequency / 1000.0)
    while ($true) {
        if ((Get-Date) -ge $OverallDeadline) {
            throw 'Runtime baseline exceeded its fixed scenario deadline.'
        }
        $now = [long](& $GetTimestamp)
        $remainingTicks = $requiredTicks - ($now - $StartTicks)
        if ($remainingTicks -le 0) { return $now }
        $sleepMs = [int][Math]::Ceiling($remainingTicks * 1000.0 / $frequency)
        $budgetMs = [int][Math]::Ceiling(($OverallDeadline - (Get-Date)).TotalMilliseconds)
        if ($budgetMs -le 0) {
            throw 'Runtime baseline exceeded its fixed scenario deadline.'
        }
        & $SleepMilliseconds ([Math]::Min($sleepMs, $budgetMs))
    }
}

function Invoke-ObserverRuntimeBaselineScenario {
    param([Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [AllowNull()][Collections.Generic.List[object]] $ProcessLifecycleObservations,
        [Parameter(Mandatory)][Collections.IDictionary] $ObservationSink)

    $deadline = (Get-Date).AddSeconds([Math]::Min(600, $WaitSeconds))
    $applicationPath = Join-Path $Verified.root $Verified.application.file
    if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.application.sha256) {
        throw 'Runtime baseline executable differs from its source-bound bundle.'
    }
    Initialize-ProductionLanguageMenuReader
    $systemLanguage = Resolve-ProductionSystemLanguage `
        -Tags @([DarkReNamerLanguageMenuReader]::PreferredLanguages())
    if ($systemLanguage.language -cne 'ko') {
        throw 'Runtime baseline expected Korean System language on the prepared VM.'
    }
    $fixture = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'runtime-baseline-fixture'
    $ordinary = New-PrivateDirectory -Parent $fixture -Leaf 'ordinary'
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($index in 0..999) {
        $path = Join-Path $ordinary ('ordinary-{0:D4}.txt' -f $index)
        [IO.File]::WriteAllText($path, ('runtime-ordinary-{0:D4}' -f $index), [Text.Encoding]::ASCII)
        $paths.Add($path)
    }
    $pathList = New-ObserverPathList -RuntimeRoot $RuntimeRoot `
        -Paths ([string[]]$paths.ToArray()) -Leaf 'runtime-baseline-paths.txt'
    $ObservationSink['mode'] = 'runtime-baseline'
    $ObservationSink['plan'] = [ordered]@{
        startup_cells=@('fresh-system','saved-system','saved-english')
        idle_seconds=30; populated_rows=1000; sample_interval_ms=200
        icon_poll_interval_ms=100; maximum_seconds=600
        transform_cases=@('grow','shrink','no-op')
        sample_clock_contract='qpc-identity-v2'
    }
    $ObservationSink['system_resolution'] = $systemLanguage
    $ObservationSink['executable_sha256'] = $Verified.application.sha256
    $cells = [Collections.Generic.List[object]]::new()
    $ObservationSink['cells'] = $cells
    foreach ($step in @(
        [ordered]@{ id='fresh-system'; preference=$null; value=0; language='ko'; workload=$true },
        [ordered]@{ id='saved-system'; preference=0; value=0; language='ko'; workload=$false },
        [ordered]@{ id='saved-english'; preference=2; value=2; language='en'; workload=$false }
    )) {
        if ((Get-Date) -ge $deadline) { throw 'Runtime baseline exceeded its fixed scenario deadline.' }
        $cellRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf ('runtime-cell-' + $step.id)
        $cell = [ordered]@{ id=$step.id; preference_kind=$(if ($null -eq $step.preference) {
                'absent' } else { 'valid-saved' }); preference_value=$step.value;
            resolved_language=$step.language; process_id=$null; process_start_utc_ticks=$null;
            startup=$null; preference_before=$null; preference_after=$null; menu=$null;
            empty_idle=$null; import=$null; icon_settlement=$null;
            populated_idle=$null; transforms=$null; samples=$null; phase_summary=$null;
            idle_cpu_windows=$null; readiness_brackets=$null;
            normal_exit_code=$null; disk_unchanged=$false; journal_residue_count=$null }
        $cells.Add($cell)
        Invoke-WithIsolatedEnvironment -RuntimeRoot $cellRoot -Action {
            $application = $null
            $sampler = $null
            try {
                $preferencePath = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'ui-language-v1'
                if ($null -eq $step.preference) {
                    if (Test-Path -LiteralPath $preferencePath) {
                        throw 'Fresh runtime baseline cell has preexisting language preference.'
                    }
                    $cell.preference_before = [ordered]@{ status='absent'; value=$null; sha256=$null }
                }
                else {
                    $seed = New-ObserverRuntimeLanguagePreference -LocalAppData $env:LOCALAPPDATA `
                        -Value $step.preference
                    $cell.preference_before = [ordered]@{ status='valid-saved'; value=$seed.value;
                        sha256=$seed.sha256 }
                }
                $appearancePreferencePath = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'ui-appearance-v1'
                if (Test-Path -LiteralPath $appearancePreferencePath) {
                    throw 'Runtime baseline startup contains an appearance preference override.'
                }
                $appearanceBeforeLaunch = Get-ObserverRuntimeLightAppearance
                $application = Start-AcceptanceApplication -FilePath $applicationPath `
                    -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds `
                    -Label 'runtime baseline application' `
                    -ProcessLifecycleObservations $ProcessLifecycleObservations
                $grid = Get-ObserverGrid -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds
                if ($grid.pattern.Current.RowCount -ne 0) {
                    throw 'Runtime baseline product did not start with an empty list.'
                }
                $readyProbe = Wait-ObserverMeasuredReadiness -Application $application `
                    -WaitSeconds $WaitSeconds -Operation startup -Predicate 'import-command-enabled' -Probe {
                        return [bool][DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                            [IntPtr]$application.main_handle, [uint32]0x801D)
                    }
                $readyTicks = [long]$readyProbe.probes[-1].end_ticks
                $createBegin = [long]$application.owned.ProcessCreateBeginTimestamp
                $createEnd = [long]$application.owned.ProcessCreateEndTimestamp
                $mainBound = [long]$application.main_bound_ticks
                $frequency = [long][Diagnostics.Stopwatch]::Frequency
                if ($application.launch_ticks -le 0 -or $frequency -le 0 -or
                    $createBegin -lt $application.launch_ticks -or $createEnd -lt $createBegin -or
                    $mainBound -lt $createEnd -or $readyTicks -lt $mainBound) {
                    throw 'Runtime baseline process creation, main binding, or readiness clock is invalid.'
                }
                $cell.startup = [ordered]@{
                    clock=[ordered]@{ qpc_frequency=$frequency;
                        launch_request_ticks=[long]$application.launch_ticks;
                        process_create_begin_ticks=$createBegin; process_create_end_ticks=$createEnd;
                        main_window_bound_ticks=$mainBound; command_ready_ticks=[long]$readyTicks }
                    launch_request_to_main_bound_ms=[Math]::Round(($mainBound - $application.launch_ticks) * 1000.0 / $frequency, 3)
                    process_start_to_main_bound_lower_ms=[Math]::Round(($mainBound - $createEnd) * 1000.0 / $frequency, 3)
                    process_start_to_main_bound_upper_ms=[Math]::Round(($mainBound - $createBegin) * 1000.0 / $frequency, 3)
                    main_bound_to_ready_ms=[Math]::Round(($readyTicks - $mainBound) * 1000.0 / $frequency, 3)
                    launch_request_to_ready_ms=[Math]::Round(($readyTicks - $application.launch_ticks) * 1000.0 / $frequency, 3)
                    process_start_to_ready_lower_ms=[Math]::Round(($readyTicks - $createEnd) * 1000.0 / $frequency, 3)
                    process_start_to_ready_upper_ms=[Math]::Round(($readyTicks - $createBegin) * 1000.0 / $frequency, 3)
                    main_hwnd_bound=$true; empty_grid=$true; import_command_enabled=$true
                }
                # Lifetime verification, capture sizing, and environment probes are outside these clocks.
                $nativeLifetime = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
                    [IntPtr]$application.process.Handle, [uint32]$application.process.Id, 0, $false)
                if ([decimal]$application.owned.process_start_time_utc_ticks -ne
                    ([decimal]$nativeLifetime[0] + 504911232000000000)) {
                    throw 'Runtime baseline native and managed creation times differ.'
                }
                $application.process_lifecycle['creation_filetime'] = [long]$nativeLifetime[0]
                [void](Ensure-AcceptanceMainWindowCaptureSize -MainWindow $application.main `
                    -Process $application.process -ExpectedSession $SessionId)
                $environment = Get-ObserverEnvironmentMetadata -Application $application
                $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $application.main
                $environment['region'] = [ordered]@{
                    culture=[Globalization.CultureInfo]::CurrentCulture.Name
                    ui_culture=[Globalization.CultureInfo]::CurrentUICulture.Name
                    timezone=[TimeZoneInfo]::Local.Id
                }
                if ($environment.physical_screen.width -ne 1366 -or
                    $environment.physical_screen.height -ne 768 -or $environment.hwnd_dpi -ne 96 -or
                    $environment.text_scale_factor_percent -ne 100) {
                    throw 'Runtime baseline display differs from its fixed request.'
                }
                if ($step.workload) { $ObservationSink['environment'] = $environment }
                $cell['environment'] = $environment
                $cell.process_id = [int]$application.process.Id
                $cell.process_start_utc_ticks = [long]$application.process.StartTime.ToUniversalTime().Ticks
                # Keep environment queries outside the launch-to-ready clock above.
                $appearanceReady = Get-ObserverRuntimeLightAppearance
                $appearanceMenu = Get-VmAutomatedAppearance -Window $application.main `
                    -Process $application.process -ExpectedSession $SessionId
                Assert-ObserverRuntimeSystemAppearanceMenu -Menu $appearanceMenu
                $environment['appearance'] = [ordered]@{
                    preference_before='absent'; preference_after=$null
                    pre_launch_resolution=$appearanceBeforeLaunch; ready_resolution=$appearanceReady
                    pre_close_resolution=$null; ready_menu=$appearanceMenu; pre_close_menu=$null
                }
                $menu = Read-ProductionLanguageMenu -Process $application.process `
                    -MainWindow $application.main -Session $SessionId -Language $step.language
                if ($menu.checked_command -ne (0x9020 + $step.value)) {
                    throw 'Runtime baseline startup language radio selection differs.'
                }
                $cell.menu = $menu
                $preferenceAfter = if (Test-Path -LiteralPath $preferencePath) {
                    Read-ProductionLanguagePreference -LocalAppData $env:LOCALAPPDATA
                } else { $null }
                if ($null -ne $step.preference -and ($null -eq $preferenceAfter -or
                    $preferenceAfter.value -ne $step.preference -or
                    $preferenceAfter.sha256 -cne $cell.preference_before.sha256)) {
                    throw 'Runtime baseline saved language preference changed during startup.'
                }
                if ($null -eq $step.preference -and $null -ne $preferenceAfter -and
                    $preferenceAfter.value -ne 0) {
                    throw 'Runtime baseline fresh System preference resolved unexpectedly.'
                }
                $cell.preference_after = if ($null -ne $preferenceAfter) {
                    [ordered]@{ status='valid-saved'; value=$preferenceAfter.value;
                        sha256=$preferenceAfter.sha256 }
                } else { [ordered]@{ status='absent'; value=$null; sha256=$null } }
                if ($step.workload) {
                    $sampler = [DarkReNamerPerformanceSampler]::new(
                        $application.process, [IntPtr]$application.main_handle)
                    $sampler.SetPhase('empty-idle')
                    $emptyCpuBefore = Read-ObserverOwnedCpuSnapshot -Application $application
                    $emptyStart = [Diagnostics.Stopwatch]::GetTimestamp()
                    $emptyEnd = Wait-ObserverRuntimeMinimumIdle -StartTicks $emptyStart `
                        -MinimumMilliseconds 30000 -OverallDeadline $deadline
                    $emptyCpuAfter = Read-ObserverOwnedCpuSnapshot -Application $application
                    $cell.empty_idle = [ordered]@{ elapsed_ms=[Math]::Round(
                        ($emptyEnd - $emptyStart) * 1000.0 /
                        [Diagnostics.Stopwatch]::Frequency, 3); rows=0 }
                    $sampler.SetPhase('import-1000')
                    $import = Import-GuiRegressionPathList -Application $application -PathsFile $pathList `
                        -ExpectedRows 1000 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid `
                        -MeasureCommandReadiness -IncludeOpenTicks -RecordReadinessBrackets
                    $cell.import = [ordered]@{ rows=1000; observed_rows=[int]$grid.pattern.Current.RowCount;
                        data_ready_ms=$import.elapsed_ms;
                        command_ready_after_rows_ms=$import.command_ready_after_rows_ms;
                        open_ticks=[long]$import.open_ticks;
                        row_observed_ticks=[long]$import.row_observed_ticks;
                        command_ready_ticks=[long]$import.command_ready_ticks }
                    $sampler.SetPhase('icon-settlement')
                    $cell.icon_settlement = Wait-ObserverIconSettlementPhase -Application $application `
                        -StartUtcTicks $cell.process_start_utc_ticks -OpenTicks $import.open_ticks `
                        -DataReadyMs $import.elapsed_ms -Rows 1000 -OverallDeadline $deadline
                    $sampler.SetPhase('populated-idle')
                    $populatedCpuBefore = Read-ObserverOwnedCpuSnapshot -Application $application
                    $populatedStart = [Diagnostics.Stopwatch]::GetTimestamp()
                    [void](Wait-ObserverRuntimeMinimumIdle -StartTicks $populatedStart `
                        -MinimumMilliseconds 30000 -OverallDeadline $deadline)
                    $populatedCpuAfter = Read-ObserverOwnedCpuSnapshot -Application $application
                    $cell.idle_cpu_windows = @(
                        [ordered]@{ phase='empty-idle'; before=$emptyCpuBefore; after=$emptyCpuAfter },
                        [ordered]@{ phase='populated-idle'; before=$populatedCpuBefore; after=$populatedCpuAfter })
                    $afterIdleReceipt = Wait-ObserverIconSettlementPhase -Application $application `
                        -StartUtcTicks $cell.process_start_utc_ticks -OpenTicks $import.open_ticks `
                        -DataReadyMs $import.elapsed_ms -Rows 1000 -OverallDeadline $deadline
                    $afterIdle = $afterIdleReceipt.confirmation_status
                    if (-not (Test-ObserverIconTerminalSnapshot -Snapshot $afterIdle -Rows 1000) -or
                        $afterIdle.session -cne $cell.icon_settlement.confirmation_status.session -or
                        $afterIdle.model_revision -cne $cell.icon_settlement.confirmation_status.model_revision -or
                        $afterIdle.generation -cne $cell.icon_settlement.confirmation_status.generation) {
                        throw 'Runtime baseline populated idle did not preserve settled icon ownership.'
                    }
                    $cell.populated_idle = [ordered]@{ elapsed_ms=[Math]::Round(
                        ([Diagnostics.Stopwatch]::GetTimestamp() - $populatedStart) * 1000.0 /
                        [Diagnostics.Stopwatch]::Frequency, 3); rows=1000; end_status=$afterIdle }
                    [void]$Captures.Add((Save-WindowScreenshot `
                        -ForegroundObservations $script:acceptanceForegroundObservations `
                        -Window $application.main -Process $application.process -ExpectedSession $SessionId `
                        -Root $EvidenceRoot -Leaf 'runtime-baseline-populated.png' `
                        -Label 'runtime baseline settled populated list'))
                    $transforms = [Collections.Generic.List[object]]::new()
                    foreach ($edit in @(
                        [ordered]@{ id='grow'; target='expanded-ordinary-0000.txt' },
                        [ordered]@{ id='shrink'; target='x.txt' },
                        [ordered]@{ id='no-op'; target='ordinary-0000.txt' }
                    )) {
                        $sampler.SetPhase('transform-' + $edit.id)
                        $editStart = [Diagnostics.Stopwatch]::GetTimestamp()
                        [void](Set-ObserverManualName -Application $application -Grid $grid -Row 0 `
                            -Name $edit.target -SessionId $SessionId -WaitSeconds $WaitSeconds)
                        $editElapsed = [Math]::Round((
                            [Diagnostics.Stopwatch]::GetTimestamp() - $editStart) * 1000.0 /
                            [Diagnostics.Stopwatch]::Frequency, 3)
                        if ($grid.pattern.GetItem(0, 0).Current.Name -cne 'ordinary-0000.txt' -or
                            $grid.pattern.GetItem(0, 1).Current.Name -cne $edit.target) {
                            throw 'Runtime baseline transform preview differs from its expected proposal.'
                        }
                        $resetElapsed = [double]0
                        if ($edit.id -cne 'no-op') {
                            $resetStart = [Diagnostics.Stopwatch]::GetTimestamp()
                            Reset-ObserverAppearanceProposals -Application $application -SessionId $SessionId `
                                -WaitSeconds $WaitSeconds
                            $resetElapsed = [Math]::Round((
                                [Diagnostics.Stopwatch]::GetTimestamp() - $resetStart) * 1000.0 /
                                [Diagnostics.Stopwatch]::Frequency, 3)
                        }
                        if ($grid.pattern.GetItem(0, 1).Current.Name -cne 'ordinary-0000.txt') {
                            throw 'Runtime baseline transform reset did not restore original proposal.'
                        }
                        $transforms.Add([ordered]@{ id=$edit.id; source='ordinary-0000.txt';
                            proposal=$edit.target; reset='ordinary-0000.txt';
                            edit_elapsed_ms=$editElapsed; reset_elapsed_ms=$resetElapsed;
                            reset_required=($edit.id -cne 'no-op') })
                    }
                    $cell.transforms = $transforms.ToArray()
                    $sampler.SetPhase('post')
                    Start-Sleep -Milliseconds 400
                    $cell.samples = @(Convert-ObserverPerformanceSampleRows -Samples @($sampler.Stop()) -ClockIdentity)
                    $sampler = $null
                    $cell.phase_summary = @(Get-ObserverPerformancePhaseSummary `
                        -Samples $cell.samples -PhaseOrder @('empty-idle','import-1000',
                            'icon-settlement','populated-idle','transform-grow',
                            'transform-shrink','transform-no-op','post'))
                }
                if (@(Get-ChildItem -LiteralPath $ordinary -File -Force).Count -ne 1000) {
                    throw 'Runtime baseline fixture count changed on disk.'
                }
                foreach ($index in 0..999) {
                    if ([IO.File]::ReadAllText($paths[$index], [Text.Encoding]::ASCII) -cne
                        ('runtime-ordinary-{0:D4}' -f $index)) {
                        throw 'Runtime baseline fixture bytes changed on disk.'
                    }
                }
                $cell.disk_unchanged = $true
                Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
                $cell.journal_residue_count = 0
                $environment.appearance.pre_close_resolution = Get-ObserverRuntimeLightAppearance
                $environment.appearance.pre_close_menu = Get-VmAutomatedAppearance `
                    -Window $application.main -Process $application.process -ExpectedSession $SessionId
                Assert-ObserverRuntimeSystemAppearanceMenu -Menu $environment.appearance.pre_close_menu
                $cell.normal_exit_code = Close-AcceptanceApplication -Application $application `
                    -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
                $cell.readiness_brackets = @($application.readiness_brackets.ToArray())
                $finalPreference = if (Test-Path -LiteralPath $preferencePath) {
                    $record = Read-ProductionLanguagePreference -LocalAppData $env:LOCALAPPDATA
                    [ordered]@{ status='valid-saved'; value=$record.value; sha256=$record.sha256 }
                } else { [ordered]@{ status='absent'; value=$null; sha256=$null } }
                if (($finalPreference | ConvertTo-Json -Compress) -cne
                    ($cell.preference_after | ConvertTo-Json -Compress)) {
                    throw 'Runtime baseline preference changed before normal process exit.'
                }
                # Normal close flushes a final appearance snapshot even without edits.
                $environment.appearance.preference_after = if (Test-Path -LiteralPath $appearancePreferencePath) {
                    Read-ObserverRuntimeAppearancePreference -Path $appearancePreferencePath
                } else { 'absent' }
                if ($environment.appearance.preference_after -isnot [string]) {
                    Assert-ObserverRuntimeDefaultAppearancePreference `
                        -Record $environment.appearance.preference_after
                }
                Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
            }
            finally {
                if ($null -ne $sampler) {
                    try { [void]$sampler.Stop() } catch {}
                }
                if ($null -ne $application) {
                    Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned
                }
            }
        }
    }
    if ((Get-Date) -ge $deadline -or $cells.Count -ne 3 -or
        @($cells | Where-Object { $_.normal_exit_code -ne 0 -or -not $_.disk_unchanged }).Count -ne 0) {
        throw 'Runtime baseline cells did not complete inside the fixed deadline.'
    }
    $ObservationSink['cells'] = $cells.ToArray()
    $ObservationSink['disk_unchanged'] = $true
    $ObservationSink['journal_residue_count'] = 0
    $ObservationSink['wakeups'] = [ordered]@{ status='not_run'; reason='no-supported-process-wakeup-counter' }
    $ObservationSink['appearance'] = 'light'
    return $ObservationSink
}

function Get-ObserverGuiApplyFixtureState {
    param([Parameter(Mandatory)][string] $Ordinary,
        [Parameter(Mandatory)][ValidateSet(100,1000,10000)][int] $Count,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Prefix)
    $files = @(Get-ChildItem -LiteralPath $Ordinary -File -Force)
    if ($files.Count -ne $Count -or
        @(Get-ChildItem -LiteralPath $Ordinary -Force).Count -ne $Count) {
        throw 'GUI Apply fixture has extra or missing directory entries.'
    }
    $rows = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Count; $index++) {
        $name = $Prefix + ('ordinary-{0:D5}.txt' -f $index)
        $file = Get-Item -LiteralPath (Join-Path $Ordinary $name) -Force -ErrorAction Stop
        if ($file -isnot [IO.FileInfo] -or
            ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'GUI Apply fixture has a nonordinary file.'
        }
        $rows.Add([ordered]@{
            name=$name; content_sha256=(Get-ObserverFixtureFileHash -File $file);
            identity=[DarkReNamerVmNative]::GetFileIdentity($file.FullName) })
    }
    $rows.ToArray()
}

function Read-ObserverGuiApplyClockFrame {
    param([Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][long] $ExpectedStartUtcTicks)
    $begin = [long][Diagnostics.Stopwatch]::GetTimestamp()
    $frame = [DarkReNamerIconStatusObserver]::ReadGuiApplyClockBound(
        $Application.process, [IntPtr]$Application.main_handle,
        $ExpectedStartUtcTicks)
    $end = [long][Diagnostics.Stopwatch]::GetTimestamp()
    return [ordered]@{
        query_begin_ticks=$begin; query_end_ticks=$end;
        qpc_frequency=[long]$frame.Frequency; revision=[long]$frame.Revision;
        initial_apply_accepted_ticks=[long]$frame.InitialApplyAcceptedTicks;
        confirmation_accepted_ticks=[long]$frame.ConfirmationAcceptedTicks;
        cancel_accepted_ticks=[long]$frame.CancelAcceptedTicks;
        cancel_kind=[int]$frame.CancelKind;
        process_id=[int]$Application.process.Id;
        process_start_utc_ticks=$ExpectedStartUtcTicks;
        main_window_handle=[long]$Application.main_handle }
}

function Invoke-ObserverGuiApplyFeedbackScenario {
    param([Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][ValidateSet('success-100','success-1000','success-10000','cancel-10000')]
        [string] $Case,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [AllowNull()][Collections.Generic.List[object]] $ProcessLifecycleObservations,
        [Parameter(Mandatory)][Collections.IDictionary] $ObservationSink)

    $count = [int]($Case.Split('-')[-1])
    $cancelCase = $Case -ceq 'cancel-10000'
    $frequency = [long][Diagnostics.Stopwatch]::Frequency
    $fixture = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'gui-apply-fixture'
    $ordinary = New-PrivateDirectory -Parent (Resolve-JobBoundShortPath -Path $fixture) -Leaf 'ordinary'
    $paths = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $count; $index++) {
        $path = Join-Path $ordinary ('ordinary-{0:D5}.txt' -f $index)
        [IO.File]::WriteAllText($path, ('gui-apply-{0:D5}' -f $index), [Text.Encoding]::ASCII)
        $paths.Add($path)
    }
    $initial = @(Get-ObserverGuiApplyFixtureState -Ordinary $ordinary -Count $count -Prefix '')
    if ($initial.Count -ne $count) { throw 'GUI Apply fixture inventory is incomplete.' }
    $initialLeaf = 'gui-apply-initial.json'
    Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot $initialLeaf) -Value $initial
    $stages = [Collections.Generic.List[object]]::new()
    if ($count -le 1000) {
        $stages.Add([ordered]@{ id='initial'; rows=$count; file=(New-ObserverPathList `
            -RuntimeRoot $RuntimeRoot -Paths ([string[]]$paths.ToArray()) -Leaf 'gui-apply-paths.txt') })
    }
    else {
        $stages.Add([ordered]@{ id='initial'; rows=1000; file=(New-ObserverPathList `
            -RuntimeRoot $RuntimeRoot -Paths ([string[]]$paths.GetRange(0, 1000)) `
            -Leaf 'gui-apply-paths-0.txt') })
        for ($chunk = 0; $chunk -lt 4; $chunk++) {
            $stages.Add([ordered]@{ id=('remainder-' + $chunk); rows=(1000 + 2250 * ($chunk + 1));
                file=(New-ObserverPathList -RuntimeRoot $RuntimeRoot `
                    -Paths ([string[]]$paths.GetRange(1000 + 2250 * $chunk, 2250)) `
                    -Leaf ('gui-apply-paths-{0}.txt' -f ($chunk + 1))) })
        }
    }
    $applicationPath = Join-Path $Verified.root $Verified.application.file
    if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.application.sha256) {
        throw 'GUI Apply executable differs from the prepared source-built bundle.'
    }
    $ObservationSink['mode'] = 'gui-apply-feedback'
    $ObservationSink['case'] = $Case
    $ObservationSink['count'] = $count
    $ObservationSink['qpc_frequency'] = $frequency
    $ObservationSink['executable_sha256'] = $Verified.application.sha256
    $ObservationSink['fixture_initial'] = [ordered]@{
        file=$initialLeaf; sha256=(Get-LowerSha256 -Path (Join-Path $EvidenceRoot $initialLeaf)) }
    $application = $null
    $sampler = $null
    $nativeCreationFileTime = [long]0
    $lifetimeCheckpoints = [Collections.Generic.List[object]]::new()
    try {
        $application = Start-AcceptanceApplication -FilePath $applicationPath `
            -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -Label 'GUI Apply feedback application' `
            -ProcessLifecycleObservations $ProcessLifecycleObservations
        $nativeCreationFileTime = Initialize-ObserverOwnedPerformanceLifetime `
            -Application $application -ObservationSink $ObservationSink -Checkpoints $lifetimeCheckpoints
        $ObservationSink['process_id'] = [int]$application.process.Id
        $ObservationSink['process_start_utc_ticks'] = [long]$application.process.StartTime.ToUniversalTime().Ticks
        $ObservationSink['main_window_handle'] = [long]$application.main_handle
        $environment = Get-ObserverEnvironmentMetadata -Application $application
        $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $application.main
        if ($environment.physical_screen.width -ne 1366 -or
            $environment.physical_screen.height -ne 768 -or $environment.hwnd_dpi -ne 96 -or
            $environment.text_scale_factor_percent -ne 100) {
            throw 'GUI Apply display differs from its fixed prepared-VM request.'
        }
        $ObservationSink['environment'] = $environment
        $grid = Get-ObserverGrid -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds
        if ($grid.pattern.Current.RowCount -ne 0) { throw 'GUI Apply did not begin with an empty list.' }
        $sampler = [DarkReNamerPerformanceSampler]::new($application.process,
            [IntPtr]$application.main_handle)
        $imports = [Collections.Generic.List[object]]::new()
        foreach ($stage in $stages) {
            $sampler.SetPhase('import-' + $stage.id)
            $import = Import-GuiRegressionPathList -Application $application -PathsFile $stage.file `
                -ExpectedRows $stage.rows -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid `
                -MeasureCommandReadiness -IncludeOpenTicks -RecordReadinessBrackets `
                -MeasureFirstFeedback:($stage.id -ceq 'initial' -and $count -ge 1000) `
                -ExpectedStartUtcTicks $ObservationSink.process_start_utc_ticks `
                -TimelineOperation ('gui-apply-' + $stage.id)
            $imports.Add([ordered]@{ id=$stage.id; expected_rows=$stage.rows;
                open_ticks=[long]$import.open_ticks; rows_observed_ticks=[long]$import.row_observed_ticks;
                command_ready_ticks=[long]$import.command_ready_ticks;
                first_feedback=$import.first_feedback })
        }
        $ObservationSink['imports'] = $imports.ToArray()
        if ($grid.pattern.Current.RowCount -ne $count) { throw 'GUI Apply import row count is incomplete.' }
        $lastImport = $imports[-1]
        $ObservationSink['icon_settlement'] = Wait-ObserverIconSettlementPhase `
            -Application $application -StartUtcTicks $ObservationSink.process_start_utc_ticks `
            -OpenTicks $lastImport.open_ticks -DataReadyMs (($lastImport.rows_observed_ticks - `
                $lastImport.open_ticks) * 1000.0 / $frequency) -Rows $count `
            -OverallDeadline (Get-Date).AddSeconds($WaitSeconds)
        [void]$Captures.Add((Save-WindowScreenshot `
            -ForegroundObservations $script:acceptanceForegroundObservations `
            -Window $application.main -Process $application.process -ExpectedSession $SessionId `
            -Root $EvidenceRoot -Leaf 'gui-apply-imported.png' -Label 'GUI Apply imported rows'))
        $sampler.SetPhase('preview')
        [void](Invoke-ObserverPrefix -Application $application -Grid $grid -Prefix 'sample-' `
            -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -ExpectedFirstSourceName 'ordinary-00000.txt')
        $lastName = 'ordinary-{0:D5}.txt' -f ($count - 1)
        if ($grid.pattern.GetItem($count - 1, 1).Current.Name -cne ('sample-' + $lastName)) {
            throw 'GUI Apply last proposal was not ready before confirmation.'
        }
        $status = Find-UniqueAutomationElement -Root $application.main -Process $application.process `
            -ExpectedSession $SessionId -AutomationId '1007' `
            -ControlType ([Windows.Automation.ControlType]::Text) -TimeoutSeconds $WaitSeconds `
            -Label 'GUI Apply functional status' -RequireWindowHandle
        $sampler.SetPhase('planning')
        $initialClockBefore = Read-ObserverGuiApplyClockFrame -Application $application `
            -ExpectedStartUtcTicks $ObservationSink.process_start_utc_ticks
        $applyTrigger = Start-ObserverApplyFromPublicUi -Application $application `
            -SessionId $SessionId -Label 'measured public Apply'
        if ($applyTrigger.input -cne 'visible-command-rail') {
            throw 'GUI Apply public invocation clock requires the visible command rail.'
        }
        $planningFeedback = if ($count -ge 1000) {
            Wait-ObserverMeasuredReadiness -Application $application -WaitSeconds ([Math]::Min(5, $WaitSeconds)) `
                -PollMilliseconds 10 -Operation 'apply-request' -Predicate 'planning-status' -Probe {
                    return [bool]($status.Current.Name -ceq '파일 시스템을 확인하고 실행 계획을 만들고 있습니다...')
                }
        } else { $null }
        $readyConfirmation = Wait-ObserverApplyConfirmationReady -Application $application `
            -SessionId $SessionId -WaitSeconds $WaitSeconds
        $initialClockAfter = Read-ObserverGuiApplyClockFrame -Application $application `
            -ExpectedStartUtcTicks $ObservationSink.process_start_utc_ticks
        $initialFeedbackEnd = if ($null -ne $planningFeedback) {
            [long]$planningFeedback.probes[-1].end_ticks
        } else { [long]$readyConfirmation.bracket.probes[-1].end_ticks }
        if ($initialClockBefore.initial_apply_accepted_ticks -ne 0 -or
            $initialClockBefore.confirmation_accepted_ticks -ne 0 -or
            $initialClockBefore.cancel_accepted_ticks -ne 0 -or
            $initialClockAfter.revision -le $initialClockBefore.revision -or
            $initialClockAfter.initial_apply_accepted_ticks -lt $applyTrigger.request_ticks -or
            $initialClockAfter.initial_apply_accepted_ticks -gt $initialFeedbackEnd) {
            throw 'GUI Apply initial owner acceptance is stale or follows its feedback.'
        }
        $confirmation = $readyConfirmation.window
        $tree = Get-ObserverWindowTree -Window $confirmation -Process $application.process `
            -SessionId $SessionId -Label 'GUI Apply confirmation scope'
        $scopeText = [string]::Join("`n", @($tree | ForEach-Object { $_.name } | Where-Object { $_ }))
        if ($scopeText.IndexOf("목록 전체 ${count}개", [StringComparison]::Ordinal) -lt 0 -or
            $scopeText.IndexOf("실제 변경 ${count}개", [StringComparison]::Ordinal) -lt 0) {
            throw 'GUI Apply confirmation is not bound to the exact changed-row scope.'
        }
        $ObservationSink['apply_request'] = [ordered]@{
            input=$applyTrigger.input; request_ticks=[long]$applyTrigger.request_ticks;
            owner_thread_acceptance=[ordered]@{
                before=$initialClockBefore; after=$initialClockAfter };
            planning_feedback=$planningFeedback;
            confirmation_ready=$readyConfirmation.bracket;
            confirmation_handle=[long]$confirmation.Current.NativeWindowHandle;
            expected_changed_rows=$count }
        $confirm = Find-UniqueAutomationElement -Root $confirmation -Process $application.process `
            -ExpectedSession $SessionId -AutomationId 'CommandLink_1101' `
            -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds `
            -Label 'measured Apply acceptance' -RequireEnabled -RequireWindowHandle
        $sampler.SetPhase('execution')
        $confirmationClockBefore = Read-ObserverGuiApplyClockFrame -Application $application `
            -ExpectedStartUtcTicks $ObservationSink.process_start_utc_ticks
        $invocationTicks = [long][Diagnostics.Stopwatch]::GetTimestamp()
        $confirmInvocation = Start-AutomationControlInvoke -OwnedProcess $application.owned `
            -Element $confirm -Label 'measured Apply acceptance'
        $executionFeedback = Wait-ObserverMeasuredReadiness -Application $application `
            -WaitSeconds ([Math]::Min(5, $WaitSeconds)) -PollMilliseconds 10 `
            -Operation 'apply-accepted' -Predicate 'execution-busy-status' -Probe {
                $value = $status.Current.Name
                return [bool]($value -ceq '실행 순서를 준비하고 있습니다...' -or
                    $value.StartsWith('실행 준비 완료:', [StringComparison]::Ordinal) -or
                    $value.StartsWith('파일 변경 중:', [StringComparison]::Ordinal))
            }
        $confirmationClockAfter = Read-ObserverGuiApplyClockFrame -Application $application `
            -ExpectedStartUtcTicks $ObservationSink.process_start_utc_ticks
        if ($confirmationClockBefore.confirmation_accepted_ticks -ne 0 -or
            $confirmationClockAfter.revision -le $confirmationClockBefore.revision -or
            $confirmationClockAfter.confirmation_accepted_ticks -lt $invocationTicks -or
            $confirmationClockAfter.confirmation_accepted_ticks -gt
                $executionFeedback.probes[-1].end_ticks) {
            throw 'GUI Apply confirmation owner acceptance is stale or follows execution feedback.'
        }
        $ObservationSink['apply_execution'] = [ordered]@{
            invocation_ticks=$invocationTicks;
            owner_thread_acceptance=[ordered]@{
                before=$confirmationClockBefore; after=$confirmationClockAfter };
            first_feedback=$executionFeedback }
        if ($cancelCase) {
            $cancel = Find-UniqueAutomationElement -Root $application.main -Process $application.process `
                -ExpectedSession $SessionId -AutomationId '1009' `
                -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds `
                -Label 'active worker Cancel' -RequireEnabled -RequireWindowHandle
            if ($cancel.Current.IsOffscreen) { throw 'Active worker Cancel is hidden before request.' }
            $cancelClockBefore = Read-ObserverGuiApplyClockFrame -Application $application `
                -ExpectedStartUtcTicks $ObservationSink.process_start_utc_ticks
            $cancelRequestTicks = [long][Diagnostics.Stopwatch]::GetTimestamp()
            $cancelInvocation = Start-AutomationControlInvoke -OwnedProcess $application.owned `
                -Element $cancel -Label 'active worker Cancel request'
            $ack = Wait-ObserverMeasuredReadiness -Application $application `
                -WaitSeconds ([Math]::Min(5, $WaitSeconds)) -PollMilliseconds 10 `
                -Operation 'active-apply-cancel' -Predicate 'cancel-request-acknowledged' -Probe {
                    if ($cancel.Current.IsOffscreen) {
                        throw 'Apply cancellation reached terminal state before acknowledgment was observed.'
                    }
                    $value = $status.Current.Name
                    return [bool](-not $cancel.Current.IsEnabled -and
                        ($value -ceq '적용 취소를 요청했습니다. 파일 처리 결과가 표시될 때까지 기다려 주세요.' -or
                         $value.StartsWith('취소 요청됨 · 처리 결과를 기다려 주세요', [StringComparison]::Ordinal)))
                }
            $cancelClockAfter = Read-ObserverGuiApplyClockFrame -Application $application `
                -ExpectedStartUtcTicks $ObservationSink.process_start_utc_ticks
            if ($cancelClockBefore.cancel_accepted_ticks -ne 0 -or
                $cancelClockAfter.revision -le $cancelClockBefore.revision -or
                $cancelClockAfter.cancel_kind -ne 4 -or
                $cancelClockAfter.cancel_accepted_ticks -lt $cancelRequestTicks -or
                $cancelClockAfter.cancel_accepted_ticks -gt $ack.probes[-1].end_ticks) {
                throw 'GUI Apply Cancel owner acceptance is stale or follows acknowledgment.'
            }
            $ObservationSink['cancel'] = [ordered]@{
                request_ticks=$cancelRequestTicks; acknowledgment=$ack;
                owner_thread_acceptance=[ordered]@{
                    before=$cancelClockBefore; after=$cancelClockAfter };
                control_id=1009; requested_from='active-apply-worker' }
            Complete-AutomationControlInvoke -State $cancelInvocation -TimeoutSeconds $WaitSeconds
        }
        Complete-AutomationControlInvoke -State $confirmInvocation -TimeoutSeconds $WaitSeconds
        if ($null -ne $applyTrigger.invocation) {
            Complete-AutomationControlInvoke -State $applyTrigger.invocation -TimeoutSeconds $WaitSeconds
        }
        $sampler.SetPhase('result')
        $expectedStatus = '{0}개 변경 완료 · 목록에 실제 결과를 반영했습니다.' -f $count
        $nativeSyncReads = [Collections.Generic.List[object]]::new()
        $ready = Wait-ObserverMeasuredReadiness -Application $application -WaitSeconds $WaitSeconds `
            -Operation 'apply-result' `
            -Predicate $(if ($cancelCase) { 'cancelled-result-and-commands' } else {
                'completed-result-rows-and-commands' }) -Probe {
                $value = [string]$status.Current.Name
                $terminal = if ($cancelCase) {
                    $value -ceq '파일 변경을 시작하기 전에 취소했습니다.' -or
                    $value -ceq '요청에 따라 변경을 취소하고 원래 상태로 복원했습니다.' -or
                    $value -ceq '요청에 따라 변경을 취소했습니다.'
                } else { $value -ceq $expectedStatus }
                if (-not $terminal) { return $false }
                if ($grid.pattern.Current.RowCount -ne $count) { return $false }
                if (-not [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                    [IntPtr]$application.main_handle, [uint32]0x801D)) { return $false }
                $applyEnabled = [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                    [IntPtr]$application.main_handle, [uint32]0x8003)
                if ($applyEnabled -ne $cancelCase) { return $false }
                $first = [string]$grid.pattern.GetItem(0, 0).Current.Name
                $last = [string]$grid.pattern.GetItem($count - 1, 0).Current.Name
                $prefix = if ($cancelCase) { '' } else { 'sample-' }
                if ($first -cne ($prefix + 'ordinary-00000.txt') -or
                    $last -cne ($prefix + $lastName)) { return $false }
                $syncBegin = [long][Diagnostics.Stopwatch]::GetTimestamp()
                $synchronized = [DarkReNamerIconStatusObserver]::ReadPreviewSynchronizationBound(
                    $application.process, [IntPtr]$application.main_handle,
                    [long]$ObservationSink.process_start_utc_ticks)
                $syncEnd = [long][Diagnostics.Stopwatch]::GetTimestamp()
                if ($synchronized -ne 1) { return $false }
                $nativeSyncReads.Add([ordered]@{
                    selector=34; value=[int]$synchronized;
                    qpc_frequency=[long][Diagnostics.Stopwatch]::Frequency;
                    query_begin_ticks=$syncBegin; query_end_ticks=$syncEnd;
                    process_id=[int]$application.process.Id;
                    process_start_utc_ticks=[long]$ObservationSink.process_start_utc_ticks;
                    main_window_handle=[long]$application.main_handle })
                return $true
            }
        if ($nativeSyncReads.Count -ne 1) {
            throw 'GUI Apply native preview synchronization was not observed in the ready probe.'
        }
        $ObservationSink['apply_execution']['operation_ready'] = $ready
        $ObservationSink['apply_execution']['native_preview_synchronization'] = $nativeSyncReads[0]
        $ObservationSink['apply_execution']['result_status'] = [string]$status.Current.Name
        $ObservationSink['apply_execution']['outcome'] = if (-not $cancelCase) { 'completed' }
            elseif ($ObservationSink['apply_execution']['result_status'] -ceq
                '파일 변경을 시작하기 전에 취소했습니다.') { 'cancelled-before-mutation' }
            elseif ($ObservationSink['apply_execution']['result_status'] -ceq
                '요청에 따라 변경을 취소하고 원래 상태로 복원했습니다.') { 'rolled-back' }
            else { 'cancelled-rollback-unproven' }
        $ObservationSink['apply_execution']['rows'] = [int]$grid.pattern.Current.RowCount
        $ObservationSink['apply_execution']['import_command_enabled'] = [bool][DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
            [IntPtr]$application.main_handle, [uint32]0x801D)
        $ObservationSink['apply_execution']['apply_command_enabled'] = [bool][DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
            [IntPtr]$application.main_handle, [uint32]0x8003)
        # Full content, name, identity, and journal checks follow the user-ready endpoint.
        $ObservationSink['verification_begin_ticks'] = [long][Diagnostics.Stopwatch]::GetTimestamp()
        $finalPrefix = if ($cancelCase) { '' } else { 'sample-' }
        $final = @(Get-ObserverGuiApplyFixtureState -Ordinary $ordinary -Count $count -Prefix $finalPrefix)
        if ($final.Count -ne $count) { throw 'GUI Apply final fixture count differs.' }
        for ($index = 0; $index -lt $count; $index++) {
            $prefix = if ($cancelCase) { '' } else { 'sample-' }
            $expectedName = $prefix + ('ordinary-{0:D5}.txt' -f $index)
            if ($final[$index].name -cne $expectedName -or
                $final[$index].content_sha256 -cne $initial[$index].content_sha256 -or
                $final[$index].identity -cne $initial[$index].identity) {
                throw 'GUI Apply file name, content, or NTFS identity differs.'
            }
        }
        $finalLeaf = 'gui-apply-final.json'
        Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot $finalLeaf) -Value $final
        $ObservationSink['fixture_final'] = [ordered]@{
            file=$finalLeaf; sha256=(Get-LowerSha256 -Path (Join-Path $EvidenceRoot $finalLeaf)) }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $ObservationSink['journal_residue_count'] = 0
        $ObservationSink['verification_end_ticks'] = [long][Diagnostics.Stopwatch]::GetTimestamp()
        $ObservationSink['samples'] = @(Convert-ObserverPerformanceSampleRows `
            -Samples @($sampler.Stop()) -ClockIdentity)
        $sampler = $null
        $ObservationSink['close_readiness_wait'] = Wait-ObserverMeasuredReadiness `
            -Application $application -WaitSeconds $WaitSeconds -Operation 'idle-close' `
            -Predicate 'close-readiness-mask31' -Probe {
                return [bool]([DarkReNamerIconStatusObserver]::ReadCloseReadinessBound(
                    $application.process, [IntPtr]$application.main_handle,
                    [long]$ObservationSink.process_start_utc_ticks) -eq 31)
            }
        $closeReadyBegin = [long][Diagnostics.Stopwatch]::GetTimestamp()
        $closeFlags = [DarkReNamerIconStatusObserver]::ReadCloseReadinessBound(
            $application.process, [IntPtr]$application.main_handle,
            [long]$ObservationSink.process_start_utc_ticks)
        $closeReadyEnd = [long][Diagnostics.Stopwatch]::GetTimestamp()
        if ($closeFlags -ne 31) { throw 'GUI Apply idle close prerequisites are not all acknowledged.' }
        $ObservationSink['close_readiness'] = [ordered]@{
            selector=22; required_mask=31; flags=[int]$closeFlags;
            query_begin_ticks=$closeReadyBegin; query_end_ticks=$closeReadyEnd;
            process_id=[int]$application.process.Id;
            process_start_utc_ticks=[long]$ObservationSink.process_start_utc_ticks;
            main_window_handle=[long]$application.main_handle }
        $ObservationSink['normal_close'] = Close-AcceptanceApplication -Application $application `
            -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary -MeasureExit
        $terminal = [DarkReNamerVmAcceptanceNative]::ReadPerformanceLifetime(
            [IntPtr]$application.process.Handle,[uint32]$application.process.Id,
            $nativeCreationFileTime,$true)
        $ObservationSink['native_process_lifetime'].terminal_exit_filetime = [long]$terminal[1]
        $ObservationSink['readiness_brackets'] = @($application.readiness_brackets.ToArray())
        $ObservationSink['appearance'] = 'light'
        return $ObservationSink
    }
    finally {
        if ($null -ne $sampler) {
            try { $ObservationSink['partial_samples'] = @(Convert-ObserverPerformanceSampleRows `
                -Samples @($sampler.Stop()) -ClockIdentity) }
            catch { $ObservationSink['partial_sampling_error'] = $_.Exception.Message }
        }
        if ($null -ne $application) {
            Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned
        }
    }
}
