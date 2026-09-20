function Wait-AcceptanceFocusTransition {
    param(
        [Parameter(Mandatory)][object] $Before,
        [Parameter(Mandatory)][scriptblock] $ReadFocusedElement,
        [Parameter(Mandatory)][string] $Label,
        [ValidateRange(1, 40)][int] $MaximumAttempts = 40,
        [ValidateRange(0, 50)][int] $PollMilliseconds = 50
    )

    $beforeId = [string]$Before.Current.AutomationId
    $beforeHandle = [IntPtr]$Before.Current.NativeWindowHandle
    for ($attempt = 0; $attempt -lt $MaximumAttempts; $attempt++) {
        if ($PollMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        $focused = & $ReadFocusedElement
        if ($null -eq $focused) {
            throw "$Label returned no focused automation element."
        }
        if ([string]$focused.Current.AutomationId -cne $beforeId -or
            [IntPtr]$focused.Current.NativeWindowHandle -ne $beforeHandle) {
            return $focused
        }
    }
    throw "$Label did not change focus within the bounded observation attempts."
}
function Invoke-AcceptanceNavigationStep {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][uint16] $VirtualKey,
        [Parameter(Mandatory)][string] $Label
    )

    $before = Get-FocusedAcceptanceElement `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label "$Label before input"
    [DarkReNamerVmAcceptanceNative]::Tap($VirtualKey)
    Wait-AcceptanceFocusTransition `
        -Before $before `
        -ReadFocusedElement {
            Get-FocusedAcceptanceElement `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label "$Label after input"
        } `
        -Label $Label
}
function Send-AcceptanceTap {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][uint16] $VirtualKey,
        [Parameter(Mandatory)][string] $Label
    )

    [void](Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label $Label)
    [DarkReNamerVmAcceptanceNative]::Tap($VirtualKey)
}
function Assert-AcceptanceCommandActivationBinding {
    param(
        [Parameter(Mandatory)][object] $Attempt,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][long] $ExpectedMainWindow,
        [Parameter(Mandatory)][string] $ExpectedAutomationId
    )

    $focused = $Attempt.focused_before
    $foreground = $Attempt.foreground_before
    if ($Attempt.action -cne 'space' -or
        $Attempt.input_method -cne 'keyboard' -or
        $Attempt.virtual_key -ne 0x20 -or
        $Attempt.expected_automation_id -cne $ExpectedAutomationId -or
        $focused.automation_id -cne $ExpectedAutomationId -or
        $focused.control_type -cne 'ControlType.Button' -or
        $focused.class -cne 'Button' -or
        $focused.visible -isnot [bool] -or -not $focused.visible -or
        $focused.enabled -isnot [bool] -or -not $focused.enabled -or
        $focused.keyboard_focusable -isnot [bool] -or -not $focused.keyboard_focusable -or
        $Attempt.input_sent -isnot [bool] -or $Attempt.input_sent -or
        $focused.hwnd -le 0 -or
        $focused.pid -ne $ExpectedProcessId -or
        $focused.session_id -ne $ExpectedSession -or
        $focused.root_hwnd -ne $ExpectedMainWindow -or
        $foreground.hwnd -ne $ExpectedMainWindow -or
        $foreground.process_id -ne $ExpectedProcessId -or
        $foreground.session_id -ne $ExpectedSession -or
        $foreground.window_class -cne 'DarkReNamerWindow') {
        throw 'Keyboard command activation target or foreground binding is invalid.'
    }
}
function Get-AcceptanceCommandActivationAttempt {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $ExpectedAutomationId
    )

    $focused = Get-FocusedAcceptanceElement `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label 'keyboard command activation'
    $control = Get-VmAutomatedControlObservation `
        -Element $focused `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label 'keyboard command activation'
    $focusedHandle = [IntPtr]$focused.Current.NativeWindowHandle
    $focusedProcessId = [uint32]0
    if ($focusedHandle -ne [IntPtr]::Zero) {
        [void][DarkReNamerVmNative]::GetWindowThreadProcessId(
            $focusedHandle,
            [ref]$focusedProcessId
        )
    }
    $focusedClass = [Text.StringBuilder]::new(128)
    if ($focusedHandle -ne [IntPtr]::Zero) {
        [void][DarkReNamerVmNative]::GetClassName(
            $focusedHandle,
            $focusedClass,
            $focusedClass.Capacity
        )
    }
    $attempt = [ordered]@{
        action = 'space'
        input_method = 'keyboard'
        virtual_key = 0x20
        expected_automation_id = $ExpectedAutomationId
        focused_before = [ordered]@{
            hwnd = [long]$focusedHandle
            pid = [int]$focusedProcessId
            session_id = [int]$control.session_id
            class = $focusedClass.ToString()
            automation_id = [string]$control.automation_id
            control_type = [string]$control.control_type
            visible = [bool]$control.visible
            enabled = [bool]$control.enabled
            keyboard_focusable = [bool]$control.keyboard_focusable
            root_hwnd = [long]$control.root_hwnd
        }
        foreground_before = Get-ForegroundObservation
        input_sent = $false
    }
    $attempt
}
function Get-BoundedAcceptanceProcessWindowInventory {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession
    )

    if ($Process.SessionId -ne $ExpectedSession) {
        throw 'Process window inventory belongs to an unexpected desktop session.'
    }
    $windows = @([DarkReNamerVmAcceptanceNative]::ReadProcessTopLevelWindows([uint32]$Process.Id) |
        Sort-Object Handle)
    $entries = @($windows | Select-Object -First 32 | ForEach-Object {
        if ($_.ProcessId -ne $Process.Id) {
            throw 'Process window inventory contains a foreign process.'
        }
        [ordered]@{
            hwnd = [long]$_.Handle
            owner_hwnd = [long]$_.Owner
            pid = [int]$_.ProcessId
            session_id = $ExpectedSession
            window_class = [string]$_.ClassName
            visible = [bool]$_.Visible
            rect = [ordered]@{
                left = [int]$_.Left
                top = [int]$_.Top
                right = [int]$_.Right
                bottom = [int]$_.Bottom
            }
        }
    })
    [ordered]@{
        maximum_entries = 32
        total_count = $windows.Count
        truncated = $windows.Count -gt 32
        entries = $entries
    }
}
function Resolve-AcceptanceOwnedInputWindowCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Windows,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][long] $ExpectedOwnerHandle,
        [Parameter(Mandatory)][string] $ExpectedName
    )

    $matches = @($Windows | Where-Object {
        [long]$_.Handle -gt 0 -and
        [long]$_.Owner -eq $ExpectedOwnerHandle -and
        [int]$_.ProcessId -eq $ExpectedProcessId -and
        [string]$_.ClassName -ceq 'DarkReNamerInputWindow' -and
        [string]$_.Title -ceq $ExpectedName -and
        [bool]$_.Visible -and
        [int]$_.Right -gt [int]$_.Left -and
        [int]$_.Bottom -gt [int]$_.Top -and
        ([long]$_.Right - [long]$_.Left) -le 32768L -and
        ([long]$_.Bottom - [long]$_.Top) -le 32768L -and
        (([long]$_.Right - [long]$_.Left) *
            ([long]$_.Bottom - [long]$_.Top)) -le 100000000L
    })
    if ($matches.Count -gt 1) {
        throw 'Owned input prompt matched more than one exact native window.'
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}
function Wait-AcceptanceOwnedInputWindow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Owner,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-AutomationBinding `
        -Element $Owner `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label "$Label owner" `
        -RequireWindowHandle
    $ownerHandle = [long]$Owner.Current.NativeWindowHandle
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    $nativeFound = $false
    $uiaIdentityMismatch = $false
    do {
        $Process.Refresh()
        if ($Process.HasExited -or $Process.SessionId -ne $ExpectedSession) {
            throw "$Label process left the expected desktop session."
        }
        $windows = @(
            [DarkReNamerVmAcceptanceNative]::ReadProcessTopLevelWindows(
                [uint32]$Process.Id
            )
        )
        $native = Resolve-AcceptanceOwnedInputWindowCandidate `
            -Windows $windows `
            -ExpectedProcessId $Process.Id `
            -ExpectedOwnerHandle $ownerHandle `
            -ExpectedName $Name
        if ($null -ne $native) {
            $nativeFound = $true
            $window = [Windows.Automation.AutomationElement]::FromHandle(
                [IntPtr][long]$native.Handle
            )
            if ($null -ne $window) {
                $freshWindows = @(
                    [DarkReNamerVmAcceptanceNative]::ReadProcessTopLevelWindows(
                        [uint32]$Process.Id
                    )
                )
                $fresh = Resolve-AcceptanceOwnedInputWindowCandidate `
                    -Windows $freshWindows `
                    -ExpectedProcessId $Process.Id `
                    -ExpectedOwnerHandle $ownerHandle `
                    -ExpectedName $Name
                if ($null -eq $fresh -or [long]$fresh.Handle -ne [long]$native.Handle) {
                    throw "$Label changed during exact native-to-UIA binding."
                }
                Assert-AutomationBinding `
                    -Element $window `
                    -Process $Process `
                    -ExpectedSession $ExpectedSession `
                    -Label $Label `
                    -RequireWindowHandle
                if ([long]$window.Current.NativeWindowHandle -ne [long]$fresh.Handle -or
                    $window.Current.Name -cne $Name -or
                    $window.Current.ControlType -ne [Windows.Automation.ControlType]::Window) {
                    $uiaIdentityMismatch = $true
                }
                else {
                    return $window
                }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($uiaIdentityMismatch) {
        throw "$Label exact native window did not publish the expected UI Automation identity before the bounded deadline."
    }
    if ($nativeFound) {
        throw "$Label exact native window did not become available through UI Automation before the bounded deadline."
    }
    throw "$Label exact native window was not found before the bounded deadline."
}
function Send-AcceptanceChord {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][uint16] $Modifier,
        [Parameter(Mandatory)][uint16] $VirtualKey,
        [Parameter(Mandatory)][string] $Label,
        [switch] $ExtendedKey
    )

    [void](Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label $Label)
    try {
        [DarkReNamerVmAcceptanceNative]::KeyDown($Modifier)
        if ($ExtendedKey) {
            [DarkReNamerVmAcceptanceNative]::TapExtended($VirtualKey)
        }
        else {
            [DarkReNamerVmAcceptanceNative]::Tap($VirtualKey)
        }
    }
    finally {
        [DarkReNamerVmAcceptanceNative]::KeyUp($Modifier)
    }
}
function Send-AcceptanceTwoModifierChord {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][uint16] $Modifier,
        [Parameter(Mandatory)][uint16] $SecondModifier,
        [Parameter(Mandatory)][uint16] $VirtualKey,
        [Parameter(Mandatory)][string] $Label,
        [switch] $ExtendedKey
    )

    [void](Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label $Label)
    try {
        [DarkReNamerVmAcceptanceNative]::KeyDown($Modifier)
        [DarkReNamerVmAcceptanceNative]::KeyDown($SecondModifier)
        if ($ExtendedKey) {
            [DarkReNamerVmAcceptanceNative]::TapExtended($VirtualKey)
        }
        else {
            [DarkReNamerVmAcceptanceNative]::Tap($VirtualKey)
        }
    }
    finally {
        [DarkReNamerVmAcceptanceNative]::KeyUp($SecondModifier)
        [DarkReNamerVmAcceptanceNative]::KeyUp($Modifier)
    }
}
function Assert-AcceptanceForegroundBinding {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [switch] $RequireMainWindow
    )

    Assert-ExactApplicationMainWindowBinding `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -MainWindowHandle $MainWindowHandle `
        -ExpectedClassName 'DarkReNamerWindow' `
        -ExpectedTitle 'DarkReNamer' `
        -Label 'acceptance foreground main window'
    $foreground = [DarkReNamerVmNative]::GetForegroundWindow()
    $foregroundProcessId = [uint32]0
    if ($foreground -eq [IntPtr]::Zero -or
        [DarkReNamerVmNative]::GetWindowThreadProcessId(
            $foreground,
            [ref]$foregroundProcessId
        ) -eq 0 -or
        $foregroundProcessId -ne $Process.Id -or
        $Process.SessionId -ne $ExpectedSession -or
        ($RequireMainWindow -and $foreground -ne $MainWindowHandle)) {
        throw 'Clipboard input is not bound to the exact application foreground target and desktop session.'
    }
}
function Find-AcceptanceMenuItem {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $conditions = [Windows.Automation.Condition[]]@(
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ProcessIdProperty,
            $Process.Id
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty,
            $Name
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::MenuItem
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::IsEnabledProperty,
            $true
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::IsOffscreenProperty,
            $false
        )
    )
    $condition = [Windows.Automation.AndCondition]::new($conditions)
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $matches = [Windows.Automation.AutomationElement]::RootElement.FindAll(
            [Windows.Automation.TreeScope]::Descendants,
            $condition
        )
        if ($matches.Count -gt 1) {
            throw "Clipboard menu item '$Name' matched more than one automation element."
        }
        if ($matches.Count -eq 1) {
            $item = $matches.Item(0)
            Assert-AutomationBinding `
                -Element $item `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label "Clipboard menu item '$Name'"
            return $item
        }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    throw "Clipboard menu item '$Name' was not found before the bounded deadline."
}
function Wait-AcceptanceClipboardText {
    param(
        [Parameter(Mandatory)][uint32] $PreviousSequence,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ExpectedText,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label,
        [switch] $AllowDelayedRendering,
        [scriptblock] $ReadSequence = { [DarkReNamerVmAcceptanceNative]::GetClipboardSequenceNumber() },
        [scriptblock] $ReadSnapshot = { [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot() },
        [scriptblock] $GetCurrentTime = { Get-Date },
        [ValidateRange(0, 1000)][int] $PollMilliseconds = 50
    )

    if ($PreviousSequence -eq 0) {
        throw "$Label requires a nonzero baseline Clipboard sequence."
    }
    $deadline = (& $GetCurrentTime).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    $observedSequenceChange = $false
    $unexpectedClipboardMessage = "$Label changed the Clipboard to unexpected text or formats."
    do {
        try {
            $sequence = [uint32](& $ReadSequence)
            if ($sequence -ne 0 -and
                ($sequence -ne $PreviousSequence -or $AllowDelayedRendering)) {
                if ($sequence -ne $PreviousSequence) { $observedSequenceChange = $true }
                # A native edit may defer rendering until this read. Even then,
                # only a stable snapshot with a changed sequence can pass.
                $snapshot = & $ReadSnapshot
                if ($null -eq $snapshot -or
                    $snapshot.SequenceNumber -eq 0 -or
                    $snapshot.SequenceNumber -eq $PreviousSequence) {
                    $snapshot = $null
                }
                else {
                    $observedSequenceChange = $true
                    if (-not (Test-AcceptanceClipboardSnapshotOwned `
                        -Snapshot $snapshot `
                        -ExpectedSequence $snapshot.SequenceNumber `
                        -ExpectedText $ExpectedText)) {
                        throw $unexpectedClipboardMessage
                    }
                    return $snapshot
                }
            }
        }
        catch {
            if ($_.Exception.Message -ceq $unexpectedClipboardMessage) {
                throw
            }
        }
        if ($PollMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    } while ((& $GetCurrentTime) -lt $deadline)
    if ($observedSequenceChange) {
        throw "$Label changed, but the exact expected Clipboard snapshot was not readable before the bounded deadline."
    }
    throw "$Label did not change the Clipboard sequence before the bounded deadline."
}
function Send-AcceptanceText {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Label
    )

    [void](Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label $Label)
    [DarkReNamerVmAcceptanceNative]::TypeUnicode($Value)
}
function Move-TabFocusToId {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $AutomationId,
        [ValidateRange(1, 64)][int] $MaximumSteps = 32
    )

    for ($step = 0; $step -lt $MaximumSteps; $step++) {
        $focused = Get-FocusedAcceptanceElement `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label 'keyboard Tab navigation'
        if ($focused.Current.AutomationId -ceq $AutomationId) {
            return $focused
        }
        [void](Invoke-AcceptanceNavigationStep `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -VirtualKey 0x09 `
            -Label 'keyboard Tab navigation')
    }
    throw "Keyboard Tab navigation did not reach automation ID $AutomationId."
}
function Move-RailFocusToCommand {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $AutomationId
    )

    $leftIds = @('32771','32772','32773','32774','32775','32776','32777','32778','32779','32780')
    $rightIds = @('32781','32783','65535','32784','32788','32789','32790','32785','32786')
    $railIds = if ($leftIds -contains $AutomationId) { $leftIds } else { $rightIds }
    if ($railIds -notcontains $AutomationId) { throw 'Unknown command rail automation ID.' }
    $focused = $null
    for ($step = 0; $step -lt 32; $step++) {
        $focused = Get-FocusedAcceptanceElement `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label 'keyboard command-rail navigation'
        if ($railIds -contains $focused.Current.AutomationId) {
            break
        }
        $focused = Invoke-AcceptanceNavigationStep `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -VirtualKey 0x09 `
            -Label 'keyboard command-rail Tab navigation'
    }
    if ($null -eq $focused -or $railIds -notcontains $focused.Current.AutomationId) {
        throw 'Keyboard Tab navigation did not enter the target command rail.'
    }
    for ($step = 0; $step -lt $railIds.Count; $step++) {
        if ($focused.Current.AutomationId -ceq $AutomationId) {
            return $focused
        }
        $currentIndex = [Array]::IndexOf($railIds, $focused.Current.AutomationId)
        $targetIndex = [Array]::IndexOf($railIds, $AutomationId)
        $direction = if ($currentIndex -lt $targetIndex) { 0x28 } else { 0x26 }
        $focused = Invoke-AcceptanceNavigationStep `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -VirtualKey ([uint16]$direction) `
            -Label 'keyboard command-rail arrow navigation'
    }
    throw "Keyboard rail navigation did not reach automation ID $AutomationId."
}
function Get-RailAccessibilitySnapshot {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $ids = @(
        '32771','32772','32773','32774','32775','32776','32777','32778','32779','32780',
        '32781','32783','65535','32784','32788','32789','32790','32785','32786'
    )
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $element = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId $id `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label "command rail button $id" `
            -RequireWindowHandle
        if ([string]::IsNullOrWhiteSpace($element.Current.Name)) {
            throw "Command rail button $id has no accessible name."
        }
        $invokePattern = $null
        if (-not $element.TryGetCurrentPattern(
            [Windows.Automation.InvokePattern]::Pattern,
            [ref]$invokePattern
        )) {
            throw "Command rail button $id does not expose InvokePattern."
        }
        $rows.Add((Get-ElementObservation -Element $element))
    }
    if (@($rows | ForEach-Object automation_id | Sort-Object -Unique).Count -ne 19) {
        throw 'The command rail accessibility snapshot is incomplete.'
    }
    $rows.ToArray()
}
function Get-ListPrimarySnapshot {
    param([Parameter(Mandatory)][Windows.Automation.AutomationElement] $List)

    $gridObject = $null
    if (-not $List.TryGetCurrentPattern(
        [Windows.Automation.GridPattern]::Pattern,
        [ref]$gridObject
    )) {
        throw 'The production file list does not expose GridPattern for reset observation.'
    }
    $grid = [Windows.Automation.GridPattern]$gridObject
    if ($grid.Current.RowCount -ne 1 -or $grid.Current.ColumnCount -lt 3) {
        throw 'The reset observation requires exactly one row and three primary columns.'
    }
    [ordered]@{
        current_name = $grid.GetItem(0, 0).Current.Name
        proposed_name = $grid.GetItem(0, 1).Current.Name
        destination_parent = $grid.GetItem(0, 2).Current.Name
    }
}
function Resolve-AcceptanceWindowResize {
    param(
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int] $CurrentWidth,
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int] $CurrentHeight,
        [ValidateRange(640, 16384)][int] $MinimumWidth = 640,
        [ValidateRange(360, 16384)][int] $MinimumHeight = 360
    )

    $width = [Math]::Max($CurrentWidth, $MinimumWidth)
    $height = [Math]::Max($CurrentHeight, $MinimumHeight)
    [ordered]@{
        resize_required = $width -ne $CurrentWidth -or $height -ne $CurrentHeight
        width = $width
        height = $height
    }
}
function Ensure-AcceptanceMainWindowCaptureSize {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession
    )

    Assert-AutomationBinding `
        -Element $MainWindow `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label 'acceptance main window resize' `
        -RequireWindowHandle
    $handle = [IntPtr]$MainWindow.Current.NativeWindowHandle
    $beforeDpi = [DarkReNamerVmAcceptanceNative]::GetDpiForWindow($handle)
    $rect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
        throw 'Acceptance main window bounds could not be read before capture sizing.'
    }
    $beforeWidth = $rect.Right - $rect.Left
    $beforeHeight = $rect.Bottom - $rect.Top
    $resize = Resolve-AcceptanceWindowResize `
        -CurrentWidth $beforeWidth `
        -CurrentHeight $beforeHeight
    if ($resize.resize_required) {
        $flags = 0x0002 -bor 0x0004 -bor 0x0010
        if (-not [DarkReNamerVmAcceptanceNative]::SetWindowPos(
            $handle,
            [IntPtr]::Zero,
            0,
            0,
            $resize.width,
            $resize.height,
            $flags
        )) {
            throw 'Windows refused to resize the acceptance main window for eligible capture.'
        }
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            Start-Sleep -Milliseconds 50
            if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
                throw 'Acceptance main window bounds could not be read after capture sizing.'
            }
            if (($rect.Right - $rect.Left) -ge $resize.width -and
                ($rect.Bottom - $rect.Top) -ge $resize.height) {
                break
            }
        }
    }
    if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
        throw 'Acceptance main window final capture bounds could not be read.'
    }
    $finalWidth = $rect.Right - $rect.Left
    $finalHeight = $rect.Bottom - $rect.Top
    if ($finalWidth -lt 640 -or $finalHeight -lt 360) {
        throw 'Acceptance main window did not reach the evidence-eligible capture size.'
    }
    $afterDpi = [DarkReNamerVmAcceptanceNative]::GetDpiForWindow($handle)
    if ($afterDpi -ne $beforeDpi) {
        throw 'Acceptance main window DPI changed during capture sizing.'
    }
    [ordered]@{
        resize_required = $resize.resize_required
        before_width = $beforeWidth
        before_height = $beforeHeight
        width = $finalWidth
        height = $finalHeight
        dpi = $afterDpi
    }
}
function Resolve-AcceptanceAppearance {
    param([Parameter(Mandatory)][ValidateSet('system', 'light', 'dark')][string] $Appearance)

    switch ($Appearance) {
        'system' { [ordered]@{ command_id = 0x9010; evidence_name = 'system' } }
        'light' { [ordered]@{ command_id = 0x9011; evidence_name = 'light' } }
        'dark' { [ordered]@{ command_id = 0x9012; evidence_name = 'dark' } }
    }
}
function Set-AcceptanceAppearance {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][ValidateSet('system', 'light', 'dark')][string] $Appearance
    )

    Assert-ExactApplicationMainWindowBinding `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -MainWindowHandle $MainWindowHandle `
        -ExpectedClassName 'DarkReNamerWindow' `
        -ExpectedTitle 'DarkReNamer' `
        -Label 'acceptance appearance target'
    $spec = Resolve-AcceptanceAppearance -Appearance $Appearance
    [DarkReNamerVmAcceptanceNative]::SendMenuCommand(
        $MainWindowHandle,
        [uint32]$spec.command_id
    )
    $stableReads = 0
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 50
        if ([DarkReNamerVmAcceptanceNative]::IsMenuCommandChecked(
            $MainWindowHandle,
            [uint32]$spec.command_id
        )) {
            $stableReads++
            if ($stableReads -eq 2) {
                return $spec
            }
        }
        else {
            $stableReads = 0
        }
    }
    throw "The $Appearance appearance did not settle within the bounded observation attempts."
}
function Wait-AcceptancePopupMenu {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Label
    )

    if ($Process.SessionId -ne $ExpectedSession) {
        throw "$Label is not bound to the expected desktop session."
    }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 50
        $popup = [DarkReNamerVmAcceptanceNative]::FindVisiblePopupMenu([uint32]$Process.Id)
        if ($popup -ne [IntPtr]::Zero) {
            return $popup
        }
    }
    throw "$Label did not appear within the bounded observation attempts."
}
function Wait-AcceptancePopupMenuClosed {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][string] $Label
    )

    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 50
        if ([DarkReNamerVmAcceptanceNative]::FindVisiblePopupMenu([uint32]$Process.Id) -eq
            [IntPtr]::Zero) {
            return
        }
    }
    throw "$Label did not close within the bounded observation attempts."
}
function Save-AcceptanceNativeMenuScreenshot {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][IntPtr] $Popup,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-SafeLeafName -Value $Leaf -Label "$Label screenshot" -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.png$'
    Assert-AutomationBinding `
        -Element $MainWindow `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label $Label `
        -RequireWindowHandle
    $mainHandle = [IntPtr]$MainWindow.Current.NativeWindowHandle
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle -or
        [DarkReNamerVmAcceptanceNative]::FindVisiblePopupMenu([uint32]$Process.Id) -ne $Popup) {
        throw "$Label is not open on the exact foreground application window."
    }
    $mainRect = [DarkReNamerVmNative+Rect]::new()
    $popupRect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($mainHandle, [ref]$mainRect) -or
        -not [DarkReNamerVmNative]::GetWindowRect($Popup, [ref]$popupRect)) {
        throw "$Label bounds could not be read."
    }
    $left = [Math]::Min($mainRect.Left, $popupRect.Left)
    $top = [Math]::Min($mainRect.Top, $popupRect.Top)
    $right = [Math]::Max($mainRect.Right, $popupRect.Right)
    $bottom = [Math]::Max($mainRect.Bottom, $popupRect.Bottom)
    $width = $right - $left
    $height = $bottom - $top
    if ($width -lt 240 -or $height -lt 120 -or
        $width -gt 16384 -or $height -gt 16384 -or
        ([long]$width * [long]$height) -gt 100000000) {
        throw "$Label bounds are invalid."
    }
    $bitmap = $null
    $graphics = $null
    try {
        $bitmap = [Drawing.Bitmap]::new(
            $width,
            $height,
            [Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen(
            $left,
            $top,
            0,
            0,
            $bitmap.Size,
            [Drawing.CopyPixelOperation]::SourceCopy
        )
        if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle -or
            [DarkReNamerVmAcceptanceNative]::FindVisiblePopupMenu([uint32]$Process.Id) -ne $Popup) {
            throw "$Label changed during screenshot capture."
        }
        $firstColor = $bitmap.GetPixel(0, 0).ToArgb()
        $hasDifferentColor = $false
        $stepX = [Math]::Max(1, [int]($width / 64))
        $stepY = [Math]::Max(1, [int]($height / 64))
        for ($y = 0; $y -lt $height -and -not $hasDifferentColor; $y += $stepY) {
            for ($x = 0; $x -lt $width; $x += $stepX) {
                if ($bitmap.GetPixel($x, $y).ToArgb() -ne $firstColor) {
                    $hasDifferentColor = $true
                    break
                }
            }
        }
        if (-not $hasDifferentColor) {
            throw "$Label screenshot is a solid image."
        }
        $path = Join-Path $Root $Leaf
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        if ((Get-Item -LiteralPath $path).Length -le 0) {
            throw "$Label screenshot is empty."
        }
        [ordered]@{
            file = $Leaf
            sha256 = Get-LowerSha256 -Path $path
            width = $width
            height = $height
        }
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
}
function Add-AcceptanceScreenshotContext {
    param(
        [Parameter(Mandatory)][object] $Screenshot,
        [Parameter(Mandatory)][ValidateSet(
            'system', 'light', 'dark', 'forced-colors'
        )][string] $Appearance,
        [Parameter(Mandatory)][ValidateSet(
            'main-workbench',
            'native-menu',
            'advanced-appearance',
            'input-prompt',
            'common-dialog',
            'confirmation-task-dialog'
        )][string] $Surface
    )

    [ordered]@{
        file = $Screenshot.file
        sha256 = $Screenshot.sha256
        width = $Screenshot.width
        height = $Screenshot.height
        appearance = $Appearance
        surface = $Surface
    }
}
function Write-JsonUtf8Bom {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object] $Value)

    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($true))
}
