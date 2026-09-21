function Assert-AutomationBinding {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Label,
        [switch] $RequireWindowHandle
    )

    if ($Element.Current.ProcessId -ne $Process.Id -or $Process.SessionId -ne $ExpectedSession) {
        throw "$Label is not bound to the expected process and desktop session."
    }
    $nativeHandle = [IntPtr]$Element.Current.NativeWindowHandle
    if ($RequireWindowHandle) {
        if ($nativeHandle -eq [IntPtr]::Zero -or -not [DarkReNamerVmNative]::IsWindow($nativeHandle)) {
            throw "$Label does not expose one live native control."
        }
        $boundProcessId = [uint32]0
        [void][DarkReNamerVmNative]::GetWindowThreadProcessId($nativeHandle, [ref]$boundProcessId)
        if ($boundProcessId -ne $Process.Id) {
            throw "$Label native control belongs to another process."
        }
    }
}
function Resolve-ExactApplicationMainWindowCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Windows,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][string] $ExpectedClassName,
        [Parameter(Mandatory)][string] $ExpectedTitle
    )

    $matches = @($Windows | Where-Object {
        [long]$_.Handle -gt 0 -and
        [long]$_.Owner -eq 0 -and
        [int]$_.ProcessId -eq $ExpectedProcessId -and
        [string]$_.ClassName -ceq $ExpectedClassName -and
        [string]$_.Title -ceq $ExpectedTitle -and
        [bool]$_.Visible -and
        [int]$_.Right -gt [int]$_.Left -and
        [int]$_.Bottom -gt [int]$_.Top -and
        ([long]$_.Right - [long]$_.Left) -le 32768L -and
        ([long]$_.Bottom - [long]$_.Top) -le 32768L -and
        (([long]$_.Right - [long]$_.Left) *
            ([long]$_.Bottom - [long]$_.Top)) -le 100000000L
    })
    if ($matches.Count -gt 1) {
        throw 'Application main window matched more than one exact native window.'
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}
function Assert-ExactApplicationMainWindowBinding {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][string] $ExpectedClassName,
        [Parameter(Mandatory)][string] $ExpectedTitle,
        [Parameter(Mandatory)][string] $Label
    )

    $Process.Refresh()
    if ($Process.HasExited -or $Process.SessionId -ne $ExpectedSession -or
        $MainWindowHandle -eq [IntPtr]::Zero) {
        throw "$Label is not bound to the expected process and desktop session."
    }
    $native = Resolve-ExactApplicationMainWindowCandidate `
        -Windows @([DarkReNamerVmNative]::ReadProcessTopLevelWindows([uint32]$Process.Id)) `
        -ExpectedProcessId $Process.Id `
        -ExpectedClassName $ExpectedClassName `
        -ExpectedTitle $ExpectedTitle
    if ($null -eq $native -or [long]$native.Handle -ne $MainWindowHandle.ToInt64()) {
        throw "$Label does not retain the exact pinned native main window."
    }
    if ($null -ne $MainWindow) {
        Assert-AutomationBinding `
            -Element $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label $Label `
            -RequireWindowHandle
        if ([long]$MainWindow.Current.NativeWindowHandle -ne $MainWindowHandle.ToInt64() -or
            $MainWindow.Current.Name -cne $ExpectedTitle -or
            $MainWindow.Current.ControlType -ne [Windows.Automation.ControlType]::Window) {
            throw "$Label does not retain the exact pinned UI Automation main window."
        }
    }
}
function Wait-ExactApplicationMainWindow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $ExpectedClassName,
        [Parameter(Mandatory)][string] $ExpectedTitle,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label
    )

    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    $nativeFound = $false
    $uiaIdentityMismatch = $false
    do {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Label exited before creating its main window."
        }
        if ($Process.SessionId -ne $ExpectedSession) {
            throw "$Label left the expected desktop session."
        }
        $native = Resolve-ExactApplicationMainWindowCandidate `
            -Windows @([DarkReNamerVmNative]::ReadProcessTopLevelWindows([uint32]$Process.Id)) `
            -ExpectedProcessId $Process.Id `
            -ExpectedClassName $ExpectedClassName `
            -ExpectedTitle $ExpectedTitle
        if ($null -ne $native) {
            $nativeFound = $true
            try {
                $window = [Windows.Automation.AutomationElement]::FromHandle(
                    [IntPtr][long]$native.Handle
                )
            }
            catch {
                $window = $null
            }
            if ($null -ne $window) {
                $fresh = Resolve-ExactApplicationMainWindowCandidate `
                    -Windows @([DarkReNamerVmNative]::ReadProcessTopLevelWindows([uint32]$Process.Id)) `
                    -ExpectedProcessId $Process.Id `
                    -ExpectedClassName $ExpectedClassName `
                    -ExpectedTitle $ExpectedTitle
                if ($null -eq $fresh -or [long]$fresh.Handle -ne [long]$native.Handle) {
                    throw "$Label changed during exact native-to-UIA binding."
                }
                try {
                    $uiaProcessId = [int]$window.Current.ProcessId
                    $uiaHandle = [long]$window.Current.NativeWindowHandle
                    $uiaName = [string]$window.Current.Name
                    $uiaControlType = $window.Current.ControlType
                }
                catch {
                    $uiaIdentityMismatch = $true
                    $uiaProcessId = 0
                    $uiaHandle = 0L
                    $uiaName = ''
                    $uiaControlType = $null
                }
                if ($uiaProcessId -ne 0 -and $uiaProcessId -ne $Process.Id) {
                    throw "$Label UI Automation provider is bound to a foreign process."
                }
                if ($uiaHandle -ne 0 -and $uiaHandle -ne [long]$fresh.Handle) {
                    throw "$Label UI Automation provider changed from the exact native window."
                }
                if ($uiaProcessId -ne $Process.Id -or $uiaHandle -ne [long]$fresh.Handle -or
                    $uiaName -cne $ExpectedTitle -or
                    $uiaControlType -ne [Windows.Automation.ControlType]::Window) {
                    $uiaIdentityMismatch = $true
                }
                else {
                    return [pscustomobject]@{
                        handle = [IntPtr][long]$fresh.Handle
                        element = $window
                    }
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
function Close-ExactApplicationMainWindow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][string] $ExpectedClassName,
        [Parameter(Mandatory)][string] $ExpectedTitle,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-ExactApplicationMainWindowBinding `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -MainWindowHandle $MainWindowHandle `
        -MainWindow $MainWindow `
        -ExpectedClassName $ExpectedClassName `
        -ExpectedTitle $ExpectedTitle `
        -Label $Label
    if (-not [DarkReNamerVmNative]::IsWindowEnabled($MainWindowHandle)) {
        throw "$Label did not expose an enabled main window for ordinary close."
    }
    [DarkReNamerVmNative]::RequestWindowClose($MainWindowHandle)
}
function Find-UniqueAutomationElement {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Root,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $AutomationId,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label,
        [Windows.Automation.ControlType] $ControlType,
        [Windows.Automation.TreeScope] $Scope = [Windows.Automation.TreeScope]::Descendants,
        [switch] $RequireEnabled,
        [switch] $RequireWindowHandle
    )

    $conditions = [Collections.Generic.List[Windows.Automation.Condition]]::new()
    $conditions.Add([Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ProcessIdProperty,
        $Process.Id
    ))
    $conditions.Add([Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    ))
    if ($null -ne $ControlType) {
        $conditions.Add([Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            $ControlType
        ))
    }
    if ($RequireEnabled) {
        $conditions.Add([Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::IsEnabledProperty,
            $true
        ))
    }
    $condition = [Windows.Automation.AndCondition]::new($conditions.ToArray())
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $matches = $Root.FindAll($Scope, $condition)
        if ($matches.Count -gt 1) {
            throw "$Label matched more than one automation element."
        }
        if ($matches.Count -eq 1) {
            $element = $matches.Item(0)
            Assert-AutomationBinding `
                -Element $element `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label $Label `
                -RequireWindowHandle:$RequireWindowHandle
            return $element
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Label was not found before the application exited."
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Label was not found before the bounded deadline."
}
function Resolve-UniqueAutomationWindowCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $TopLevelCandidates,
        [AllowNull()][scriptblock] $FallbackQuery,
        [Parameter(Mandatory)][string] $Label
    )

    $candidates = @($TopLevelCandidates)
    if ($candidates.Count -eq 0 -and $null -ne $FallbackQuery) {
        $candidates = @(& $FallbackQuery)
    }
    $windows = @{}
    foreach ($candidate in $candidates) {
        $windows[[string]$candidate.Current.NativeWindowHandle] = $candidate
    }
    $matches = @($windows.Values)
    if ($matches.Count -gt 1) {
        throw "$Label matched more than one top-level window."
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}
function Wait-UniqueAutomationWindow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label,
        [Windows.Automation.AutomationElement] $Owner,
        [IntPtr] $MainWindowHandle = [IntPtr]::Zero
    )

    if ($null -ne $Owner) {
        Assert-AutomationBinding `
            -Element $Owner `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label "$Label owner" `
            -RequireWindowHandle
    }
    elseif ($MainWindowHandle -eq [IntPtr]::Zero) {
        throw "$Label requires the exact pinned main-window handle when no owner is supplied."
    }
    $root = [Windows.Automation.AutomationElement]::RootElement
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
            [Windows.Automation.ControlType]::Window
        )
    )
    $condition = [Windows.Automation.AndCondition]::new($conditions)
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $main = if ($null -eq $Owner) {
            $candidateMain = [Windows.Automation.AutomationElement]::FromHandle($MainWindowHandle)
            if ($null -ne $candidateMain) {
                Assert-ExactApplicationMainWindowBinding `
                    -Process $Process `
                    -ExpectedSession $ExpectedSession `
                    -MainWindowHandle $MainWindowHandle `
                    -MainWindow $candidateMain `
                    -ExpectedClassName 'DarkReNamerWindow' `
                    -ExpectedTitle 'DarkReNamer' `
                    -Label "$Label main window"
            }
            $candidateMain
        }
        else {
            $null
        }
        $candidates = @($root.FindAll([Windows.Automation.TreeScope]::Children, $condition))
        if ($null -ne $Owner) {
            $candidates += @($Owner.FindAll([Windows.Automation.TreeScope]::Children, $condition))
        }
        $fallbackQuery = if ($null -eq $Owner -and $null -ne $main) {
            # Managed Win32 providers place owned dialogs below their owner.
            {
                @($main.FindAll([Windows.Automation.TreeScope]::Descendants, $condition))
            }.GetNewClosure()
        }
        else {
            $null
        }
        $element = Resolve-UniqueAutomationWindowCandidate `
            -TopLevelCandidates $candidates `
            -FallbackQuery $fallbackQuery `
            -Label $Label
        if ($null -ne $element) {
            Assert-AutomationBinding `
                -Element $element `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label $Label `
                -RequireWindowHandle
            return $element
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Label was not found before the application exited."
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Label was not found before the bounded deadline."
}
function Invoke-AutomationControl {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Label
    )

    $pattern = $null
    if (-not $Element.TryGetCurrentPattern(
        [Windows.Automation.InvokePattern]::Pattern,
        [ref]$pattern
    )) {
        throw "$Label does not support UI Automation InvokePattern."
    }
    ([Windows.Automation.InvokePattern]$pattern).Invoke()
}
function Start-AutomationControlInvoke {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Label
    )

    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [Threading.ApartmentState]::MTA
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('automationElement', $Element)
    $runspace.SessionStateProxy.SetVariable('automationLabel', $Label)
    $powershell = [PowerShell]::Create()
    $powershell.Runspace = $runspace
    [void]$powershell.AddScript(@'
$invokePattern = $null
if (-not $automationElement.TryGetCurrentPattern(
    [Windows.Automation.InvokePattern]::Pattern,
    [ref]$invokePattern
)) {
    throw "$automationLabel does not support UI Automation InvokePattern."
}
([Windows.Automation.InvokePattern]$invokePattern).Invoke()
'@)
    try {
        $asyncResult = $powershell.BeginInvoke()
        [pscustomobject]@{
            powershell = $powershell
            runspace = $runspace
            async_result = $asyncResult
            label = $Label
            completed = $false
        }
    }
    catch {
        $powershell.Dispose()
        $runspace.Dispose()
        throw
    }
}
function Complete-AutomationControlInvoke {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    if ($State.completed) {
        return
    }
    $waitMilliseconds = [int]([Math]::Min(
        [int]::MaxValue,
        [Math]::Min(30, $TimeoutSeconds) * 1000L
    ))
    if (-not $State.async_result.AsyncWaitHandle.WaitOne($waitMilliseconds)) {
        throw "$($State.label) UI Automation invocation did not return before the bounded deadline."
    }
    try {
        [void]$State.powershell.EndInvoke($State.async_result)
        if ($State.powershell.HadErrors) {
            throw "$($State.label) UI Automation invocation failed."
        }
    }
    finally {
        $State.completed = $true
        $State.powershell.Dispose()
        $State.runspace.Dispose()
    }
}
function Set-AutomationControlValue {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Label
    )

    $pattern = $null
    if (-not $Element.TryGetCurrentPattern(
        [Windows.Automation.ValuePattern]::Pattern,
        [ref]$pattern
    )) {
        $editCondition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::Edit
        )
        $edits = $Element.FindAll([Windows.Automation.TreeScope]::Descendants, $editCondition)
        if ($edits.Count -ne 1 -or -not $edits.Item(0).TryGetCurrentPattern(
            [Windows.Automation.ValuePattern]::Pattern,
            [ref]$pattern
        )) {
            throw "$Label does not expose one UI Automation value control."
        }
    }
    $valuePattern = [Windows.Automation.ValuePattern]$pattern
    if ($valuePattern.Current.IsReadOnly) {
        throw "$Label is read-only."
    }
    $valuePattern.SetValue($Value)
    if ($valuePattern.Current.Value -cne $Value) {
        throw "$Label did not retain the exact requested value."
    }
}
function Wait-WindowClosed {
    param(
        [Parameter(Mandatory)][IntPtr] $Handle,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label
    )

    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    while ([DarkReNamerVmNative]::IsWindow($Handle) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ([DarkReNamerVmNative]::IsWindow($Handle)) {
        throw "$Label did not close before the bounded deadline."
    }
}
function Wait-ListPreviewName {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $ExpectedName,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $list = Find-UniqueAutomationElement `
        -Root $MainWindow `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -AutomationId '1000' `
        -TimeoutSeconds $TimeoutSeconds `
        -Label 'production file list' `
        -RequireWindowHandle
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    # The row and original-name cell can share the preview name.
    # Wait for the preview column instead of requiring unique descendant names.
    do {
        try {
            $gridObject = $null
            if ($list.TryGetCurrentPattern([Windows.Automation.GridPattern]::Pattern, [ref]$gridObject)) {
                $grid = [Windows.Automation.GridPattern]$gridObject
                if ($grid.Current.RowCount -eq 1 -and $grid.Current.ColumnCount -ge 2) {
                    $candidate = $grid.GetItem(0, 1)
                    if ($candidate.Current.Name -ceq $ExpectedName) {
                        return
                    }
                }
            }
        }
        catch [Windows.Automation.ElementNotAvailableException] {
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw 'The expected production preview name was not exposed before the bounded deadline.'
}
function Measure-ScreenshotSparseVariation {
    param(
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int] $Width,
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int] $Height,
        [Parameter(Mandatory)][scriptblock] $ReadArgb
    )

    if (([long]$Width * [long]$Height) -gt 100000000L) {
        throw 'Screenshot sample bounds exceed the resource limit.'
    }
    $stepX = [Math]::Max(1, [int]($Width / 64))
    $stepY = [Math]::Max(1, [int]($Height / 64))
    $firstArgb = [int]0
    $sampleCount = 0
    for ($y = 0; $y -lt $Height; $y += $stepY) {
        for ($x = 0; $x -lt $Width; $x += $stepX) {
            $argb = [int](& $ReadArgb $x $y)
            $sampleCount++
            if ($sampleCount -eq 1) {
                $firstArgb = $argb
            }
            elseif ($argb -ne $firstArgb) {
                return [pscustomobject][ordered]@{
                    first_argb = $firstArgb
                    step_x = $stepX
                    step_y = $stepY
                    sample_count = $sampleCount
                    distinct_sample_count = 2
                    has_sampled_variation = $true
                }
            }
        }
    }
    [pscustomobject][ordered]@{
        first_argb = $firstArgb
        step_x = $stepX
        step_y = $stepY
        sample_count = $sampleCount
        distinct_sample_count = 1
        has_sampled_variation = $false
    }
}
function Save-WindowScreenshot {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[object]] $ForegroundObservations
    )

    Assert-SafeLeafName -Value $Leaf -Label "$Label screenshot" -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.png$'
    Assert-AutomationBinding `
        -Element $Window `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label $Label `
        -RequireWindowHandle
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    if (-not [DarkReNamerVmNative]::IsWindowVisible($handle)) {
        throw "$Label is not visible for screenshot capture."
    }
    $activation = [ordered]@{
        label = $Label
        target_hwnd = [long]$handle
        initial = Get-ForegroundObservation
        uia_set_focus = 'not_attempted'
        set_foreground_window = $null
        final = $null
        capture_complete = $null
        capture_change = $null
    }
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
        try {
            $Window.SetFocus()
            $activation.uia_set_focus = 'succeeded'
        }
        catch {
            $activation.uia_set_focus = 'failed'
        }
        $activation.set_foreground_window = [bool][DarkReNamerVmNative]::SetForegroundWindow($handle)
        $foregroundDeadline = (Get-Date).AddSeconds(5)
        while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle -and
            (Get-Date) -lt $foregroundDeadline) {
            Start-Sleep -Milliseconds 100
        }
    }
    $activation.final = Get-ForegroundObservation
    $activationObservation = [pscustomobject]$activation
    $ForegroundObservations.Add($activationObservation)
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
        throw "$Label is not the foreground window for screenshot capture."
    }
    $rect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
        throw "$Label bounds could not be read."
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0 -or
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
            $rect.Left,
            $rect.Top,
            0,
            0,
            $bitmap.Size,
            [Drawing.CopyPixelOperation]::SourceCopy
        )
        $activationObservation.capture_complete = Get-ForegroundObservation
        if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
            $activationObservation.capture_change = Get-ForegroundObservation
            throw "$Label lost foreground during screenshot capture."
        }
        $sampleObservation = Measure-ScreenshotSparseVariation `
            -Width $width `
            -Height $height `
            -ReadArgb {
                param($x, $y)
                $bitmap.GetPixel($x, $y).ToArgb()
            }.GetNewClosure()
        if (-not $sampleObservation.has_sampled_variation) {
            $diagnosticLeaf = $Leaf.Substring(0, $Leaf.Length - 4) +
                '.solid-diagnostic.png'
            Assert-SafeLeafName `
                -Value $diagnosticLeaf `
                -Label "$Label solid-image diagnostic" `
                -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.png$'
            $diagnosticPath = Join-Path $Root $diagnosticLeaf
            if (Test-Path -LiteralPath $diagnosticPath) {
                throw "$Label solid-image diagnostic path already exists."
            }
            $bitmap.Save($diagnosticPath, [Drawing.Imaging.ImageFormat]::Png)
            $diagnosticItem = Get-Item -LiteralPath $diagnosticPath
            if ($diagnosticItem.Length -le 0) {
                throw "$Label solid-image diagnostic is empty."
            }
            $activationObservation | Add-Member `
                -NotePropertyName solid_image_diagnostic `
                -NotePropertyValue ([ordered]@{
                    classification = 'sampled-grid-uniform'
                    scope = 'sparse-samples-only'
                    file = $diagnosticLeaf
                    sha256 = Get-LowerSha256 -Path $diagnosticPath
                    bytes = [long]$diagnosticItem.Length
                    rect = [ordered]@{
                        left = [int]$rect.Left
                        top = [int]$rect.Top
                        right = [int]$rect.Right
                        bottom = [int]$rect.Bottom
                        width = $width
                        height = $height
                    }
                    first_argb = [int]$sampleObservation.first_argb
                    step_x = [int]$sampleObservation.step_x
                    step_y = [int]$sampleObservation.step_y
                    sample_count = [int]$sampleObservation.sample_count
                    distinct_sample_count = [int]$sampleObservation.distinct_sample_count
                    has_sampled_variation = $false
                    foreground = $activationObservation.capture_complete
                })
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
