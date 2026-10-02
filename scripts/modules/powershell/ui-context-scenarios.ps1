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
        $thirdDiagnosticText = "이동·이름 변경 예정`n`n현재 이름: 03-unsampled-move.txt`n변경 후 이름: $($mixedFixture.prefix)03-unsampled-move.txt`n현재 전체 경로: $($mixedFixture.sources[2])`n대상 전체 경로: $($mixedFixture.destinations[2])`n`n파일 시스템 검사와 실행 확인은 변경 적용 시 별도로 수행합니다."
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
function New-ObserverAppearanceColumnPreference {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $expectedLocalData = Join-Path $RuntimeRoot 'localappdata'
    if (-not [string]::Equals([IO.Path]::GetFullPath($env:LOCALAPPDATA),
        [IO.Path]::GetFullPath($expectedLocalData), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Appearance preference requires isolated LOCALAPPDATA.'
    }
    $appRoot = New-PrivateDirectory -Parent $expectedLocalData -Leaf 'DarkReNamer'
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
        [Parameter(Mandatory)][int] $WaitSeconds)
    $reset = Find-UniqueAutomationElement -Root $Application.main -Process $Application.process `
        -ExpectedSession $SessionId -AutomationId '32781' -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds -Label 'appearance reset proposals' -RequireEnabled -RequireWindowHandle
    Invoke-AutomationControl -Element $reset -Label 'appearance reset proposals'
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
function Invoke-ObserverAppearancePairScenario {
    param(
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [AllowNull()][Collections.Generic.List[object]] $ProcessLifecycleObservations
    )
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
        foreach ($scene in @('empty', 'unchanged', 'overflow', 'changed', 'collision', 'warning', 'selected-active', 'selected-inactive')) {
            if ($scene -eq 'unchanged') {
                [void](Import-GuiRegressionPathList -Application $application -PathsFile $oneList -ExpectedRows 1 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid)
            }
            elseif ($scene -eq 'overflow') {
                [void](Import-GuiRegressionPathList -Application $application -PathsFile $remainingList -ExpectedRows 60 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $grid)
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
                    focus_automation_id = [string]$nativeFocus[2]
                    native_focus = @($nativeFocus)
                    focused_uia = Get-ElementObservation -Element $focused
                    appearance_menu = Get-VmAutomatedAppearance -Window $application.main -Process $application.process -ExpectedSession $SessionId
                    list_physical_target = Get-GuiRegressionPhysicalTarget -Element $grid.element -Application $application -SessionId $SessionId -ExpectedRoot ([IntPtr]$application.main_handle) -Label 'appearance unobscured list'
                    list = Get-ElementObservation -Element $grid.element
                    native_list = Get-ObserverNativeWindowMetrics -Window $grid.element
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
                control = Get-ElementObservation -Element $prefix
                focus_automation_id = Get-ObserverAppearanceFocusId -Application $application -SessionId $SessionId
                native_button_state = [DarkReNamerVmAcceptanceNative]::ReadButtonState([IntPtr]$prefix.Current.NativeWindowHandle)
                target = $prefixTarget
                capture = Save-ObserverAppearanceCapture -Application $application -Window $application.main -EvidenceRoot $EvidenceRoot `
                    -Leaf "appearance-button-normal-$step.png" -Appearance $appearance -Surface 'main-workbench' -SessionId $SessionId -Captures $Captures
            }
            $buttons['disabled'] = [ordered]@{
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
                if ($label.Current.Name -cne '붙일 문자열' -or $labelNative[3] -ine 'Static' -or $labelNative[4] -cne '붙일 문자열' -or
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
                        query = 'bound STATIC/GetWindowTextW original prompt raster'
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
        $after = Get-ObserverAppearanceFixtureState -Root $root -Paths $paths.ToArray()
        if (-not (Test-ObserverFixtureStateEqual -Expected $initial -Actual $after)) {
            throw 'Appearance pair changed a fixture file, content digest, or NTFS identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $exitCode = Close-AcceptanceApplication -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds -CloseInput ordinary
        [ordered]@{
            environment = $environment; appearance = 'light-dark-light'; process_id = [int]$application.process.Id
            fixture = [ordered]@{ file_count = 60; disk_unchanged = $true; journal_residue_count = 0; column_preferences = $columnPreference }
            scenes = $scenes; interactions = $interactions.ToArray(); normal_exit_code = $exitCode
            limitations = @('system-theme and forced-colors configurations not-run in this diagnostic')
        }
    }
    finally { if ($null -ne $application) { Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned } }
}
