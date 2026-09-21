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
    $details.edit.SetFocus()
    Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x23 -Label 'context full-details Ctrl+End' -ExtendedKey
    Start-Sleep -Milliseconds 150
    $visibleEnd = Get-ObserverVisibleText -TextPattern $details.text_pattern
    $expectedEnding = (Normalize-ObserverText $ExpectedFullText).Split("`n")[-1]
    if (-not $visibleEnd.EndsWith($expectedEnding, [StringComparison]::Ordinal)) {
        throw 'Context full details did not expose the canonical ending after native scrolling.'
    }
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
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $applicationPath = Join-Path $Verified.root $Verified.application.file
    $rawLayoutCandidate = $Verified.lane -ceq 'candidate-gui-only'
    if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.application.sha256) {
        throw 'Application changed after bundle verification.'
    }
    $repeatedFixture = New-ObserverRepeatedFixture -RuntimeRoot $RuntimeRoot
    $script:ownedContextFixedRoot = $null
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
    try {
        $repeatedApplication = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'repeated-name GUI regression application'
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
        $repeatedApplication.owned.process.Dispose()
        $repeatedApplication = $null

        $moveFixture = New-ObserverMoveFixture -RuntimeRoot $RuntimeRoot
        $rawCaptureStart = $Captures.Count
        $moveApplication = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'movement GUI regression application'
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
        if ($actualReachability.status -ceq 'reachable') {
            $actualApplyInput = 'physical-mouse'
            $physicalApply = Get-GuiRegressionPhysicalTarget -Click -Element $confirm -Application $moveApplication -SessionId $SessionId -ExpectedRoot $actualHandle -Label 'actual move Apply'
        }
        else {
            $actualApplyInput = 'keyboard-enter-fallback-after-inaccessible-mouse-observation'
            $confirm.SetFocus()
            Send-AcceptanceTap -Process $moveApplication.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'actual move Apply keyboard fallback'
            $physicalApply = $null
        }
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
        $moveApplication.owned.process.Dispose()
        $moveApplication = $null

        $mixedFixture = New-ObserverMixedFixture -RuntimeRoot $RuntimeRoot
        $rawCaptureStart = $Captures.Count
        $mixedApplication = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'mixed GUI regression application'
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
    finally {
        foreach ($application in @($repeatedApplication, $moveApplication, $mixedApplication)) {
            if ($null -ne $application) {
                $application.process.Refresh()
                if (-not $application.process.HasExited) {
                    Invoke-TaskkillTree -ProcessId $application.process.Id
                    [void]$application.process.WaitForExit(10000)
                }
                $application.owned.process.Dispose()
            }
        }
        if ($null -ne $script:ownedContextFixedRoot -and (Test-Path -LiteralPath $script:ownedContextFixedRoot -PathType Container)) {
            $ownedRoot = Get-Item -LiteralPath $script:ownedContextFixedRoot -Force
            if ($ownedRoot.FullName -cne 'C:\fixture' -or ($ownedRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Owned fixed fixture root failed its cleanup identity check.'
            }
            Remove-Item -LiteralPath $ownedRoot.FullName -Recurse -Force
            if (Test-Path -LiteralPath $ownedRoot.FullName) { throw 'Owned fixed fixture root cleanup failed.' }
            $script:ownedContextFixedRoot = $null
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
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
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
        $application = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'standard GUI regression application'
        $appearanceSpec = Set-AcceptanceAppearance -Process $application.process -ExpectedSession $SessionId -MainWindowHandle ([IntPtr]$application.main_handle) -Appearance $Appearance
        $minimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $application.main -Process $application.process -ExpectedSession $SessionId
        $environment = Get-ObserverEnvironmentMetadata -Application $application
        $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $application.main
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
            $application.process.Refresh()
            if (-not $application.process.HasExited) {
                Invoke-TaskkillTree -ProcessId $application.process.Id
                [void]$application.process.WaitForExit(10000)
            }
            $application.owned.process.Dispose()
        }
    }
}
