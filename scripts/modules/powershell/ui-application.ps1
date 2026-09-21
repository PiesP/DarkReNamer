function Initialize-AcceptanceNativeOpen {
    if ('DarkReNamerAcceptanceNativeOpen' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DarkReNamerAcceptanceNativeOpen {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetDlgItem(IntPtr dialog, int controlId);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern int GetClassName(IntPtr window, StringBuilder className, int capacity);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern int GetWindowText(IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
}
'@
}
function Resolve-AcceptanceNativeOpen {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Dialog,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession
    )

    Initialize-AcceptanceNativeOpen
    Assert-AutomationBinding -Element $Dialog -Process $Process -ExpectedSession $ExpectedSession -Label 'keyboard file dialog' -RequireWindowHandle
    $dialogHandle = [IntPtr]$Dialog.Current.NativeWindowHandle
    $openHandle = [DarkReNamerAcceptanceNativeOpen]::GetDlgItem($dialogHandle, 1)
    if ($openHandle -eq [IntPtr]::Zero -or -not [DarkReNamerAcceptanceNativeOpen]::IsWindow($openHandle)) {
        throw 'The source-bound file dialog has no live native control ID 1.'
    }
    if ([DarkReNamerAcceptanceNativeOpen]::GetParent($openHandle) -ne $dialogHandle -or
        [DarkReNamerAcceptanceNativeOpen]::GetDlgCtrlID($openHandle) -ne 1) {
        throw 'The native Open control is not the exact direct child ID 1 of the source-bound file dialog.'
    }
    $openProcessId = [uint32]0
    $openThreadId = [DarkReNamerAcceptanceNativeOpen]::GetWindowThreadProcessId($openHandle, [ref]$openProcessId)
    if ($openThreadId -eq 0 -or $openProcessId -ne $Process.Id -or $Process.SessionId -ne $ExpectedSession) {
        throw 'The native Open control is outside the source-bound process or desktop session.'
    }
    $openClass = [Text.StringBuilder]::new(32)
    if ([DarkReNamerAcceptanceNativeOpen]::GetClassName($openHandle, $openClass, $openClass.Capacity) -le 0 -or
        $openClass.ToString() -cne 'Button') {
        throw 'The source-bound file dialog Open control is not a native Button class.'
    }
    if (-not [DarkReNamerAcceptanceNativeOpen]::IsWindowVisible($openHandle) -or
        -not [DarkReNamerAcceptanceNativeOpen]::IsWindowEnabled($openHandle)) {
        throw 'The source-bound native Open control is not visible and enabled.'
    }
    $dialogRect = [DarkReNamerAcceptanceNativeOpen+Rect]::new()
    $openRect = [DarkReNamerAcceptanceNativeOpen+Rect]::new()
    if (-not [DarkReNamerAcceptanceNativeOpen]::GetWindowRect($dialogHandle, [ref]$dialogRect) -or
        -not [DarkReNamerAcceptanceNativeOpen]::GetWindowRect($openHandle, [ref]$openRect) -or
        $dialogRect.Right -le $dialogRect.Left -or $dialogRect.Bottom -le $dialogRect.Top -or
        $openRect.Right -le $openRect.Left -or $openRect.Bottom -le $openRect.Top -or
        $openRect.Left -lt $dialogRect.Left -or $openRect.Top -lt $dialogRect.Top -or
        $openRect.Right -gt $dialogRect.Right -or $openRect.Bottom -gt $dialogRect.Bottom) {
        throw 'The source-bound native Open control bounds are invalid or outside its dialog.'
    }
    $element = [Windows.Automation.AutomationElement]::FromHandle($openHandle)
    Assert-AutomationBinding -Element $element -Process $Process -ExpectedSession $ExpectedSession -Label 'native keyboard file dialog Open control' -RequireWindowHandle
    if ([IntPtr]$element.Current.NativeWindowHandle -ne $openHandle) {
        throw 'UI Automation did not map back to the exact native Open control.'
    }
    [pscustomobject]@{
        Element = $element
        Handle = $openHandle
        ProcessId = $openProcessId
        ThreadId = $openThreadId
        ClassName = $openClass.ToString()
        DialogBounds = [ordered]@{ left = $dialogRect.Left; top = $dialogRect.Top; right = $dialogRect.Right; bottom = $dialogRect.Bottom }
        ControlBounds = [ordered]@{ left = $openRect.Left; top = $openRect.Top; right = $openRect.Right; bottom = $openRect.Bottom }
    }
}
# Four fixed GUI regression scenarios composed from the tracked acceptance helpers above.
function Normalize-ObserverText {
    param([AllowEmptyString()][string] $Value)
    if ($null -eq $Value) { return $null }
    $Value.Replace("`r`n", "`n").Replace("`r", "`n")
}
function Get-ObserverWindowTree {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][string] $Label
    )
    Assert-AutomationBinding -Element $Window -Process $Process -ExpectedSession $SessionId -Label $Label -RequireWindowHandle
    $all = $Window.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.Condition]::TrueCondition
    )
    if ($all.Count -gt 512) { throw "$Label exposes an unexpectedly large automation tree." }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($element in $all) {
        if (-not [string]::IsNullOrEmpty($element.Current.Name) -or
            -not [string]::IsNullOrEmpty($element.Current.AutomationId)) {
            $rows.Add((Get-ElementObservation -Element $element))
        }
    }
    $rows.ToArray()
}
function Stop-AndDisposeAcceptanceOwnedProcess {
    param([Parameter(Mandatory)][object] $Owned)

    $process = $Owned.process
    try {
        $process.Refresh()
        if (-not $process.HasExited) {
            $process.Kill()
            if (-not $process.WaitForExit(10000)) {
                throw 'The exact owned acceptance process did not terminate.'
            }
        }
    }
    finally {
        $process.Dispose()
    }
}
function Start-AcceptanceApplication {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $Label
    )
    $owned = $null
    try {
        $owned = Start-OwnedProcess -FilePath $FilePath -Arguments '' -WorkingDirectory $WorkingDirectory
        $process = $owned.process
        $binding = Wait-ExactApplicationMainWindow `
            -Process $process `
            -ExpectedSession $SessionId `
            -ExpectedClassName 'DarkReNamerWindow' `
            -ExpectedTitle 'DarkReNamer' `
            -TimeoutSeconds $WaitSeconds `
            -Label $Label
        $window = $binding.element
        $mainHandle = [IntPtr]$binding.handle
        $window.SetFocus()
        [void][DarkReNamerVmNative]::SetForegroundWindow($mainHandle)
        $foregroundDeadline = (Get-Date).AddSeconds(5)
        while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle -and (Get-Date) -lt $foregroundDeadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-AcceptanceForegroundBinding `
            -Process $process `
            -ExpectedSession $SessionId `
            -MainWindowHandle $mainHandle `
            -RequireMainWindow
        [pscustomobject]@{
            owned = $owned
            process = $process
            main = $window
            main_handle = $mainHandle
        }
    }
    catch {
        $startupError = $_
        if ($null -ne $owned) {
            try {
                Stop-AndDisposeAcceptanceOwnedProcess -Owned $owned
            }
            catch {
                throw "Application startup validation and exact-process cleanup both failed: $($startupError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
        }
        throw $startupError
    }
}
function Get-ObserverGrid {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )
    $list = Find-UniqueAutomationElement `
        -Root $Application.main `
        -Process $Application.process `
        -ExpectedSession $SessionId `
        -AutomationId '1000' `
        -ControlType ([Windows.Automation.ControlType]::DataGrid) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'long-name UX file list' `
        -RequireWindowHandle
    $pattern = $null
    if (-not $list.TryGetCurrentPattern([Windows.Automation.GridPattern]::Pattern, [ref]$pattern)) {
        throw 'The file list does not expose GridPattern.'
    }
    [pscustomobject]@{ element = $list; pattern = [Windows.Automation.GridPattern]$pattern }
}
function Import-GuiRegressionPathList {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $PathsFile,
        [Parameter(Mandatory)][int] $ExpectedRows,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [object] $Grid
    )
    if ($null -eq $Grid) {
        $Grid = Get-ObserverGrid -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds
    }
    Add-Type -AssemblyName System.Windows.Forms
    $Application.main.SetFocus()
    [void][DarkReNamerVmNative]::SetForegroundWindow([IntPtr]$Application.main_handle)
    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId `
        -MainWindowHandle ([IntPtr]$Application.main_handle) -RequireMainWindow
    [Windows.Forms.SendKeys]::SendWait('^+v')
    $dialog = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId `
        -MainWindowHandle ([IntPtr]$Application.main_handle) -Name '파일에서 경로목록 읽어 추가하기' `
        -TimeoutSeconds $WaitSeconds -Label 'GUI regression path-list import dialog'
    $handle = [IntPtr]$dialog.Current.NativeWindowHandle
    $edit = Find-UniqueAutomationElement -Root $dialog -Process $Application.process -ExpectedSession $SessionId -AutomationId '1148' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $WaitSeconds -Label 'path-list import filename' -RequireWindowHandle
    Set-AutomationControlValue -Element $edit -Value $PathsFile -Label 'path-list import filename'
    $nativeOpen = Resolve-AcceptanceNativeOpen -Dialog $dialog -Process $Application.process -ExpectedSession $SessionId
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-AutomationControl -Element $nativeOpen.Element -Label 'path-list import Open'
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label 'path-list import dialog'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        if ($Grid.pattern.Current.RowCount -eq $ExpectedRows) { break }
        if ($Grid.pattern.Current.RowCount -gt $ExpectedRows) { throw 'Path admission produced too many rows.' }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($Grid.pattern.Current.RowCount -ne $ExpectedRows) {
        throw "Path admission did not reach $ExpectedRows rows before the bounded deadline."
    }
    [pscustomobject]@{ grid = $Grid; elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3) }
}
function Set-ObserverSelectedRow {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][int] $Row,
        [Parameter(Mandatory)][int] $SessionId
    )
    if ($Row -ge $Grid.pattern.Current.RowCount) { throw 'Requested row is outside the file list.' }
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow([IntPtr]$Application.main_handle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId `
        -MainWindowHandle ([IntPtr]$Application.main_handle) -RequireMainWindow
    $cell = $Grid.pattern.GetItem($Row, 0)
    $Grid.element.SetFocus()
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x24 -Label 'select first preview row'
    for ($index = 0; $index -lt $Row; $index++) {
        Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x28 -Label 'advance preview row selection'
    }
    $selection = $null
    if (-not $Grid.element.TryGetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern, [ref]$selection)) {
        throw 'The file list does not expose SelectionPattern.'
    }
    $selectionDeadline = (Get-Date).AddSeconds(3)
    do {
        $selected = @(([Windows.Automation.SelectionPattern]$selection).Current.GetSelection())
        if ($selected.Count -eq 1) { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $selectionDeadline)
    if ($selected.Count -ne 1) { throw "The scenario requires exactly one selected row; observed $($selected.Count)." }
    [ordered]@{ row = $Row; current_name = $cell.Current.Name; selected_count = $selected.Count }
}
function Set-ObserverManualName {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][int] $Row,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [string] $CaptureRoot,
        [string] $CaptureLeaf,
        [AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    [void](Set-ObserverSelectedRow -Application $Application -Grid $Grid -Row $Row -SessionId $SessionId)
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x71 -Label "manual change row $Row F2"
    $prompt = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name '선택 항목 이름 직접 변경' -TimeoutSeconds $WaitSeconds -Label "manual change row $Row prompt"
    $handle = [IntPtr]$prompt.Current.NativeWindowHandle
    $edit = Find-UniqueAutomationElement -Root $prompt -Process $Application.process -ExpectedSession $SessionId -AutomationId '1004' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $WaitSeconds -Label "manual change row $Row edit" -RequireWindowHandle
    $rasterTarget = $null
    if (-not [string]::IsNullOrEmpty($CaptureRoot) -and -not [string]::IsNullOrEmpty($CaptureLeaf)) {
        if ($null -eq $Captures) { throw 'Editable prompt capture requires the capture ledger.' }
        $rasterTarget = Get-ObserverNativeStaticRasterTarget -Window $prompt -Application $Application -SessionId $SessionId -ControlId 1002 -ExpectedText '으로' -Id 'prefix-input' -Image $CaptureLeaf
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $prompt -Process $Application.process -ExpectedSession $SessionId -Root $CaptureRoot -Leaf $CaptureLeaf -Label "manual change row $Row prompt"))
    }
    Set-AutomationControlValue -Element $edit -Value $Name -Label "manual change row $Row edit"
    $ok = Find-UniqueAutomationElement -Root $prompt -Process $Application.process -ExpectedSession $SessionId -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label "manual change row $Row OK" -RequireEnabled -RequireWindowHandle
    Invoke-AutomationControl -Element $ok -Label "manual change row $Row OK"
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label "manual change row $Row prompt"
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $actual = $Grid.pattern.GetItem($Row, 1).Current.Name
        if ($actual -ceq $Name) {
            if ($null -ne $rasterTarget) { return $rasterTarget }
            return
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "Manual row $Row preview did not expose the exact requested name."
}
function Copy-GuiRegressionDocument {
    param(
        [Parameter(Mandatory)][ValidateSet('selection', 'mnemonic')][string] $Mode,
        [Parameter(Mandatory)][object] $Application,
        [Windows.Automation.AutomationElement] $Edit,
        [Parameter(Mandatory)][string] $ExpectedText,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $Label
    )
    $expectedClipboard = (Normalize-ObserverText $ExpectedText).Replace("`n", "`r`n")
    $before = [DarkReNamerVmAcceptanceNative]::ReadOrInitializeEmptyClipboardSnapshot()
    if ($before.SequenceNumber -eq 0 -or $before.Formats.Count -ne 0) {
        throw ("$Label requires an empty Clipboard with a nonzero sequence preflight; " +
            "observed sequence=$($before.SequenceNumber), formats=$($before.Formats -join ',').")
    }
    if ($Mode -ceq 'selection') {
        if ($null -eq $Edit) { throw 'Selection copy requires the bound read-only Edit.' }
        Assert-AutomationBinding -Element $Edit -Process $Application.process `
            -ExpectedSession $SessionId -Label "$Label exact edit" -RequireWindowHandle
        $editHandle = [long]$Edit.Current.NativeWindowHandle
        $Edit.SetFocus()
        $focused = Get-FocusedAcceptanceElement `
            -Process $Application.process -ExpectedSession $SessionId -Label "$Label edit focus"
        if ([long]$focused.Current.NativeWindowHandle -ne $editHandle) {
            throw "$Label did not focus the exact read-only edit before selection."
        }
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x24 -Label "$Label selection start" -ExtendedKey
        Send-AcceptanceTwoModifierChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -SecondModifier 0x10 -VirtualKey 0x23 -Label "$Label select to end" -ExtendedKey
        $textObject = $null
        if (-not $Edit.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$textObject)) {
            throw "$Label read-only edit no longer exposes TextPattern."
        }
        $selectionDeadline = (Get-Date).AddSeconds(3)
        $selectedText = ''
        do {
            $focused = Get-FocusedAcceptanceElement `
                -Process $Application.process -ExpectedSession $SessionId -Label "$Label selected edit focus"
            if ([long]$focused.Current.NativeWindowHandle -ne $editHandle) {
                throw "$Label lost the exact read-only edit focus during selection."
            }
            $selected = @(([Windows.Automation.TextPattern]$textObject).GetSelection())
            $selectedText = if ($selected.Count -eq 1) { $selected[0].GetText(-1) } else { '' }
            if ((Normalize-ObserverText $selectedText) -ceq (Normalize-ObserverText $ExpectedText)) { break }
            Start-Sleep -Milliseconds 50
        } while ((Get-Date) -lt $selectionDeadline)
        if ($selected.Count -ne 1 -or
            (Normalize-ObserverText $selectedText) -cne (Normalize-ObserverText $ExpectedText)) {
            throw ("$Label keyboard selection did not cover the exact document; " +
                "ranges=$($selected.Count), selected_units=$($selectedText.Length), " +
                "expected_units=$($expectedClipboard.Length), edit_hwnd=$editHandle.")
        }
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x43 -Label "$Label Ctrl+C"
    }
    else {
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x43 -Label "$Label Alt+C"
    }
    $snapshot = $null
    try {
        $snapshot = Wait-AcceptanceClipboardText `
            -PreviousSequence $before.SequenceNumber -ExpectedText $expectedClipboard `
            -TimeoutSeconds $WaitSeconds -Label $Label `
            -AllowDelayedRendering:($Mode -ceq 'selection')
    }
    finally {
        if ($null -eq $snapshot) {
            try {
                $candidate = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
                if ($candidate.SequenceNumber -ne $before.SequenceNumber -and
                    (Test-AcceptanceClipboardSnapshotOwned -Snapshot $candidate -ExpectedSequence $candidate.SequenceNumber -ExpectedText $expectedClipboard)) {
                    [void][DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned([uint32]$candidate.SequenceNumber, [string]$candidate.UnicodeText)
                }
            } catch {}
        }
    }
    $cleanup = [DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned([uint32]$snapshot.SequenceNumber, [string]$snapshot.UnicodeText)
    if ($cleanup -cne 'cleared') { throw "$Label Clipboard cleanup preserved a foreign or changed value: $cleanup" }
    [ordered]@{
        input = if ($Mode -ceq 'selection') { 'native-edit-ctrl-home-ctrl-shift-end-ctrl-c' } else { 'copy-all-mnemonic-alt-c' }
        exact = (Normalize-ObserverText $snapshot.UnicodeText) -ceq (Normalize-ObserverText $expectedClipboard)
        utf8_sha256 = Get-LowerTextSha256 -Value (Normalize-ObserverText $snapshot.UnicodeText)
        length_utf16 = $snapshot.UnicodeText.Length
        cleanup = $cleanup
    }
}
function Get-ObserverProcessWindows {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)
    @([DarkReNamerVmAcceptanceNative]::ReadProcessTopLevelWindows([uint32]$Process.Id) | ForEach-Object {
        [ordered]@{
            hwnd = $_.Handle
            owner_hwnd = $_.Owner
            process_id = $_.ProcessId
            class_name = $_.ClassName
            title = $_.Title
            visible = $_.Visible
            rect = [ordered]@{ left = $_.Left; top = $_.Top; right = $_.Right; bottom = $_.Bottom; width = $_.Right - $_.Left; height = $_.Bottom - $_.Top }
        }
    })
}
function Get-ObserverEnvironmentMetadata {
    param([Parameter(Mandatory)][object] $Application)
    $handle = [IntPtr]$Application.main.Current.NativeWindowHandle
    $screen = [DarkReNamerVmAcceptanceNative]::ReadPhysicalScreenSize()
    $work = [DarkReNamerVmAcceptanceNative]::ReadWorkArea()
    $monitor = [DarkReNamerVmAcceptanceNative]::ReadMonitorInfo($handle)
    Initialize-TextScaleNative
    $textScale = [double][DarkReNamerTextScaleNative]::ReadTextScaleFactor()
    if ([double]::IsNaN($textScale) -or $textScale -lt 1.0 -or $textScale -gt 2.25) {
        throw 'UISettings.TextScaleFactor is outside the documented system range.'
    }
    $textScalePercent = [int][Math]::Round($textScale * 100.0)
    $displayModes = @('{0}x{1}@current' -f ($monitor[2] - $monitor[0]),($monitor[3] - $monitor[1]))
    [ordered]@{
        physical_screen = [ordered]@{ left = $monitor[0]; top = $monitor[1]; right = $monitor[2]; bottom = $monitor[3]; width = $monitor[2] - $monitor[0]; height = $monitor[3] - $monitor[1] }
        work_area = [ordered]@{ left = $monitor[4]; top = $monitor[5]; right = $monitor[6]; bottom = $monitor[7]; width = $monitor[6] - $monitor[4]; height = $monitor[7] - $monitor[5] }
        monitor_query = 'MonitorFromWindow(MONITOR_DEFAULTTONEAREST)+GetMonitorInfoW'
        global_metrics_diagnostic = [ordered]@{
            physical_screen = [ordered]@{ width = $screen.X; height = $screen.Y }
            work_area = [ordered]@{ left = $work.Left; top = $work.Top; right = $work.Right; bottom = $work.Bottom }
        }
        hwnd = $handle.ToInt64()
        hwnd_dpi = [DarkReNamerVmAcceptanceNative]::GetDpiForWindow($handle)
        text_scale_factor_percent = $textScalePercent
        text_scale_factor_source = [ordered]@{
            query = 'Windows.UI.ViewManagement.UISettings.TextScaleFactor'
            raw_factor = $textScale
            documented_range = '1.0..2.25'
        }
        dpi_awareness = 'per-monitor-v2-observer'
        display_mode_inventory = [ordered]@{
            query = 'GetMonitorInfoW current monitor'
            maximum_entries = 1
            values = $displayModes
        }
    }
}
function Get-ObserverNativeWindowMetrics {
    param([Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window)
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    if ($handle -eq [IntPtr]::Zero) { throw 'Top-level observer window has no native HWND.' }
    $rect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
        throw 'Top-level observer window bounds could not be read.'
    }
    $monitor = [DarkReNamerVmAcceptanceNative]::ReadMonitorInfo($handle)
    [ordered]@{
        hwnd = $handle.ToInt64()
        process_id = [int]$Window.Current.ProcessId
        hwnd_dpi = [DarkReNamerVmAcceptanceNative]::GetDpiForWindow($handle)
        coordinate_space = 'physical pixels; observer is Per-Monitor-V2 aware'
        rect = [ordered]@{ left = $rect.Left; top = $rect.Top; right = $rect.Right; bottom = $rect.Bottom; width = $rect.Right - $rect.Left; height = $rect.Bottom - $rect.Top }
        target_monitor = [ordered]@{ left = $monitor[0]; top = $monitor[1]; right = $monitor[2]; bottom = $monitor[3]; width = $monitor[2] - $monitor[0]; height = $monitor[3] - $monitor[1] }
        target_work_area = [ordered]@{ left = $monitor[4]; top = $monitor[5]; right = $monitor[6]; bottom = $monitor[7]; width = $monitor[6] - $monitor[4]; height = $monitor[7] - $monitor[5] }
        fully_inside_work_area = $rect.Left -ge $monitor[4] -and $rect.Top -ge $monitor[5] -and $rect.Right -le $monitor[6] -and $rect.Bottom -le $monitor[7]
    }
}
function Get-ObserverNativeStaticRasterTarget {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $ControlId,
        [Parameter(Mandatory)][string] $ExpectedText,
        [Parameter(Mandatory)][ValidateSet('prefix-input', 'full-details')][string] $Id,
        [Parameter(Mandatory)][string] $Image
    )

    Initialize-AcceptanceNativeOpen
    Assert-AutomationBinding -Element $Window -Process $Application.process -ExpectedSession $SessionId -Label "$Id raster window" -RequireWindowHandle
    $windowHandle = [IntPtr]$Window.Current.NativeWindowHandle
    $controlHandle = [DarkReNamerAcceptanceNativeOpen]::GetDlgItem($windowHandle, $ControlId)
    if ($controlHandle -eq [IntPtr]::Zero -or
        [DarkReNamerAcceptanceNativeOpen]::GetParent($controlHandle) -ne $windowHandle) {
        throw "$Id native STATIC is not the expected direct dialog child."
    }
    $processId = [uint32]0
    $threadId = [DarkReNamerAcceptanceNativeOpen]::GetWindowThreadProcessId($controlHandle, [ref]$processId)
    if ($threadId -eq 0 -or $processId -ne $Application.process.Id -or
        $Application.process.SessionId -ne $SessionId) {
        throw "$Id native STATIC is outside the source-bound process or desktop session."
    }
    $className = [Text.StringBuilder]::new(32)
    $text = [Text.StringBuilder]::new(256)
    if ([DarkReNamerAcceptanceNativeOpen]::GetClassName($controlHandle, $className, $className.Capacity) -le 0 -or
        $className.ToString() -cne 'Static' -or
        [DarkReNamerAcceptanceNativeOpen]::GetWindowText($controlHandle, $text, $text.Capacity) -le 0 -or
        $text.ToString() -cne $ExpectedText) {
        throw "$Id native STATIC class or text differs from the fixed label."
    }
    $controlRect = [DarkReNamerAcceptanceNativeOpen+Rect]::new()
    $windowRect = [DarkReNamerAcceptanceNativeOpen+Rect]::new()
    if (-not [DarkReNamerAcceptanceNativeOpen]::GetWindowRect($controlHandle, [ref]$controlRect) -or
        -not [DarkReNamerAcceptanceNativeOpen]::GetWindowRect($windowHandle, [ref]$windowRect) -or
        $controlRect.Right -le $controlRect.Left -or $controlRect.Bottom -le $controlRect.Top -or
        $controlRect.Left -lt $windowRect.Left -or $controlRect.Top -lt $windowRect.Top -or
        $controlRect.Right -gt $windowRect.Right -or $controlRect.Bottom -gt $windowRect.Bottom) {
        throw "$Id native STATIC bounds are invalid or outside its captured dialog."
    }
    $controlRectangle = [ordered]@{
        left = $controlRect.Left; top = $controlRect.Top
        right = $controlRect.Right; bottom = $controlRect.Bottom
        width = $controlRect.Right - $controlRect.Left
        height = $controlRect.Bottom - $controlRect.Top
    }
    $windowRectangle = [ordered]@{
        left = $windowRect.Left; top = $windowRect.Top
        right = $windowRect.Right; bottom = $windowRect.Bottom
        width = $windowRect.Right - $windowRect.Left
        height = $windowRect.Bottom - $windowRect.Top
    }
    [ordered]@{
        id = $Id
        image = $Image
        text_sha256 = Get-LowerTextSha256 -Value $ExpectedText
        control = [ordered]@{
            observation = 'native-static-v1'
            hwnd = $controlHandle.ToInt64()
            process_id = [int]$processId
            control_id = $ControlId
            class_name = $className.ToString()
            text = $text.ToString()
        }
        window = [ordered]@{
            hwnd = $windowHandle.ToInt64()
            process_id = [int]$processId
            rect = $windowRectangle
        }
        screenshot_origin = [ordered]@{ x = $windowRect.Left; y = $windowRect.Top }
        control_rect = $controlRectangle
    }
}
function Get-GuiRegressionPhysicalTarget {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][IntPtr] $ExpectedRoot,
        [Parameter(Mandatory)][string] $Label,
        [switch] $Click
    )
    Assert-AutomationBinding -Element $Element -Process $Application.process -ExpectedSession $SessionId -Label $Label
    $bounds = $Element.Current.BoundingRectangle
    if ($bounds.Width -lt 4 -or $bounds.Height -lt 4 -or [double]::IsNaN($bounds.X) -or [double]::IsNaN($bounds.Y)) {
        throw "$Label has invalid physical bounds."
    }
    $x = [int][Math]::Floor($bounds.X + $bounds.Width / 2.0)
    $y = [int][Math]::Floor($bounds.Y + $bounds.Height / 2.0)
    $point = [DarkReNamerVmAcceptanceNative+Point]::new()
    $point.X = $x; $point.Y = $y
    $hit = [DarkReNamerVmAcceptanceNative]::WindowFromPoint($point)
    $targetProcessId = [uint32]0
    $hitThreadId = if ($hit -eq [IntPtr]::Zero) { [uint32]0 } else {
        [DarkReNamerVmNative]::GetWindowThreadProcessId($hit, [ref]$targetProcessId)
    }
    $hitRoot = if ($hit -eq [IntPtr]::Zero) { [IntPtr]::Zero } else {
        [DarkReNamerVmAcceptanceNative]::GetAncestor($hit, [uint32]2)
    }
    if ($hit -eq [IntPtr]::Zero -or $hitThreadId -eq 0 -or
        $targetProcessId -ne $Application.process.Id -or
        $hitRoot -ne $ExpectedRoot) {
        throw ("$Label is not physically bound to the expected process/window tree: " +
            "hit_window=$($hit.ToInt64()); hit_process_id=$targetProcessId; " +
            "hit_root_window=$($hitRoot.ToInt64()); expected_process_id=$($Application.process.Id); " +
            "expected_root_window=$($ExpectedRoot.ToInt64()).")
    }
    $result = [ordered]@{ x = $x; y = $y; hit_window = $hit.ToInt64(); root_window = $ExpectedRoot.ToInt64() }
    if ($Click) {
        [DarkReNamerVmAcceptanceNative]::MoveCursor($x, $y)
        $foreground = [DarkReNamerVmNative]::GetForegroundWindow()
        if ($foreground -ne $ExpectedRoot -and $foreground -ne [IntPtr]$Application.main_handle) {
            throw "$Label foreground does not belong to the expected modal path."
        }
        [DarkReNamerVmAcceptanceNative]::Click()
    }
    $result
}
function New-ObserverPathList {
    param(
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string[]] $Paths,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}$')][string] $Leaf = 'paths-utf16le.txt'
    )
    $text = [string]::Join("`r`n", $Paths) + "`r`n"
    $aggregateUnits = ($Paths | Measure-Object -Property Length -Sum).Sum
    if ($aggregateUnits * 2L -gt 4MB) { throw 'Fixture paths exceed the aggregate path budget.' }
    $encoding = [Text.UnicodeEncoding]::new($false, $true)
    $body = $encoding.GetBytes($text)
    $preamble = $encoding.GetPreamble()
    if ($body.Length + $preamble.Length -gt 2MB) {
        throw 'Fixture path list exceeds the import limit.'
    }
    $bytes = [byte[]]::new($body.Length + $preamble.Length)
    [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    $path = Join-Path $RuntimeRoot $Leaf
    [IO.File]::WriteAllBytes($path, $bytes)
    $path
}
function Get-ObserverFixtureState {
    param([Parameter(Mandatory)][string] $FixtureRoot)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $FixtureRoot -File -Recurse -Force | Sort-Object FullName)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Fixture contains a reparse point.'
        }
        $rows.Add([ordered]@{
            path = $file.FullName
            name = $file.Name
            content_sha256 = Get-LowerSha256 -Path $file.FullName
            identity = [DarkReNamerVmNative]::GetFileIdentity($file.FullName)
        })
    }
    $rows.ToArray()
}
function Test-ObserverFixtureStateEqual {
    param([Parameter(Mandatory)][object[]] $Expected, [Parameter(Mandatory)][object[]] $Actual)
    if ($Expected.Count -ne $Actual.Count) { return $false }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Expected[$index].path -cne $Actual[$index].path -or
            $Expected[$index].name -cne $Actual[$index].name -or
            $Expected[$index].content_sha256 -cne $Actual[$index].content_sha256 -or
            $Expected[$index].identity -cne $Actual[$index].identity) {
            return $false
        }
    }
    $true
}
function New-ObserverStandardFixture {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $fixtureRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'fixture'
    $parentA = New-PrivateDirectory -Parent $fixtureRoot -Leaf '한글-매우-긴-상위-경로-공통-자료-보관-2026-09-A-😀'
    $parentB = New-PrivateDirectory -Parent $fixtureRoot -Leaf '한글-매우-긴-상위-경로-공통-자료-보관-2026-09-B-😀'
    $common = '한글-😀-아주긴공통접두어-월별정리-원본자료-검토완료-배포대기-장기보존-최종승인-추가검증-'
    $source0 = $common + '0001-final.txt'
    $source1 = $common + '0002-final.md'
    $source2 = $source0
    $after0 = $common + '9001-approved.webp'
    $after1 = $common + '9002-approved.png'
    foreach ($leaf in @($source0, $source1, $after0, $after1)) {
        if ($leaf.Length -gt 240) { throw 'Standard fixture leaf exceeds the observer bound.' }
    }
    $paths = @(
        (Join-Path $parentA $source0),
        (Join-Path $parentA $source1),
        (Join-Path $parentB $source2)
    )
    for ($index = 0; $index -lt $paths.Count; $index++) {
        [IO.File]::WriteAllText(
            $paths[$index],
            "long-name-ux-fixture-$index`n",
            [Text.UTF8Encoding]::new($false)
        )
    }
    $destinations = @(
        (Join-Path $parentA $after0),
        (Join-Path $parentA $after1),
        $paths[2]
    )
    [pscustomobject]@{
        root = $fixtureRoot
        paths = $paths
        paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths $paths
        source_names = @($source0, $source1, $source2)
        destination_names = @($after0, $after1, $source2)
        destinations = $destinations
        initial = Get-ObserverFixtureState -FixtureRoot $fixtureRoot
    }
}
function Invoke-ObserverPrefix {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [string] $ExpectedFirstSourceName = 'item-00000.txt'
    )
    $command = Find-UniqueAutomationElement -Root $Application.main -Process $Application.process -ExpectedSession $SessionId -AutomationId '32773' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix command' -RequireEnabled -RequireWindowHandle
    $invoke = Start-AutomationControlInvoke -Element $command -Label 'large smoke prefix command'
    $prompt = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name '이름 앞에 문자열 붙이기' -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix prompt'
    $handle = [IntPtr]$prompt.Current.NativeWindowHandle
    $edit = Find-UniqueAutomationElement -Root $prompt -Process $Application.process -ExpectedSession $SessionId -AutomationId '1004' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix edit' -RequireWindowHandle
    Set-AutomationControlValue -Element $edit -Value $Prefix -Label 'large smoke prefix edit'
    $ok = Find-UniqueAutomationElement -Root $prompt -Process $Application.process -ExpectedSession $SessionId -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix OK' -RequireEnabled -RequireWindowHandle
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-AutomationControl -Element $ok -Label 'large smoke prefix OK'
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix prompt'
    Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $WaitSeconds
    $expected = $Prefix + $ExpectedFirstSourceName
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        if ($Grid.pattern.GetItem(0, 1).Current.Name -ceq $expected) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($Grid.pattern.GetItem(0, 1).Current.Name -cne $expected) {
        throw 'Large smoke preview did not settle.'
    }
    [ordered]@{ elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3); expected_first_name = $expected }
}
function Get-ObserverReadOnlyDetails {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $ExpectedText,
        [Parameter(Mandatory)][string] $Label
    )
    $edit = Find-UniqueAutomationElement -Root $Window -Process $Application.process -ExpectedSession $SessionId -AutomationId '1004' -TimeoutSeconds $WaitSeconds -Label "$Label read-only edit" -RequireWindowHandle
    $textObject = $null
    if (-not $edit.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$textObject)) {
        throw "$Label edit does not expose TextPattern."
    }
    $text = [Windows.Automation.TextPattern]$textObject
    $readOnly = $text.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::IsReadOnlyAttribute)
    $valueText = Normalize-ObserverText $text.DocumentRange.GetText(-1)
    $documentText = Normalize-ObserverText $text.DocumentRange.GetText(-1)
    $expected = Normalize-ObserverText $ExpectedText
    if ($readOnly -ne $true -or $documentText -cne $expected) {
        throw "$Label does not expose the exact canonical read-only text."
    }
    [pscustomobject]@{
        edit = $edit
        text_pattern = $text
        evidence = [ordered]@{
            automation = Get-ElementObservation -Element $edit
            read_only = $readOnly
            value_text = $valueText
            document_text = $documentText
            exact_value = $null; value_pattern = 'not-exposed-by-native-readonly-document'
            exact_document = $true
            utf8_sha256 = Get-LowerTextSha256 -Value $valueText
            utf16_length = $text.DocumentRange.GetText(-1).Length
        }
    }
}
function Get-ObserverVisibleText {
    param([Parameter(Mandatory)][Windows.Automation.TextPattern] $TextPattern)
    $ranges = @($TextPattern.GetVisibleRanges())
    Normalize-ObserverText ([string]::Join('', @($ranges | ForEach-Object { $_.GetText(-1) })))
}
function Wait-AcceptanceMainWindowForeground {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $WaitSeconds, [Parameter(Mandatory)][string] $Label)
    $deadline = (Get-Date).AddSeconds([Math]::Min(5, $WaitSeconds))
    while ([DarkReNamerVmNative]::GetForegroundWindow() -ne [IntPtr]$Application.main_handle -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not [DarkReNamerVmAcceptanceNative]::IsWindowEnabled([IntPtr]$Application.main_handle)) {
        throw "$Label did not restore the enabled owner."
    }
    Assert-AcceptanceForegroundBinding -Process $Application.process `
        -ExpectedSession $Application.process.SessionId `
        -MainWindowHandle ([IntPtr]$Application.main_handle) -RequireMainWindow
}
function Open-ObserverDiagnosticKeyboard {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId, [Parameter(Mandatory)][int] $WaitSeconds)
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow([IntPtr]$Application.main_handle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId `
        -MainWindowHandle ([IntPtr]$Application.main_handle) -RequireMainWindow
    Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x56 -Label 'View menu Alt+V'
    [void](Wait-AcceptancePopupMenu -Process $Application.process -ExpectedSession $SessionId -Label 'View menu for keyboard diagnostics')
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x49 -Label 'View diagnostic mnemonic I'
    Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name 'DarkReNamer - 선택 항목 진단' -TimeoutSeconds $WaitSeconds -Label 'keyboard selected-item diagnostic'
}
function Invoke-ObserverClipboardContention {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $DetailsWindow,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $CaptureLeaf,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $detailsHandle = [IntPtr]$DetailsWindow.Current.NativeWindowHandle
    $failure = $null
    [DarkReNamerVmAcceptanceNative]::HoldObserverClipboard()
    try {
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x43 -Label 'copy-all Clipboard contention Alt+C'
        $failure = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $DetailsWindow -Name 'DarkReNamer - 복사 실패' -TimeoutSeconds $WaitSeconds -Label 'copy-all Clipboard contention failure'
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $failure -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf $CaptureLeaf -Label 'copy-all Clipboard contention failure'))
    }
    finally {
        [DarkReNamerVmAcceptanceNative]::ReleaseObserverClipboard()
    }
    if ($null -eq $failure) { throw 'Clipboard contention did not expose its failure dialog.' }
    $failureTree = Get-ObserverWindowTree -Window $failure -Process $Application.process -SessionId $SessionId -Label 'copy failure dialog'
    $failureHandle = [IntPtr]$failure.Current.NativeWindowHandle
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'dismiss copy failure dialog'
    Wait-WindowClosed -Handle $failureHandle -TimeoutSeconds $WaitSeconds -Label 'copy failure dialog'
    if (-not [DarkReNamerVmNative]::IsWindow($detailsHandle)) {
        throw 'Copy failure closed the read-only details window.'
    }
    $deadline = (Get-Date).AddSeconds(3)
    while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $detailsHandle -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $detailsHandle) {
        throw 'Read-only details did not regain foreground after copy failure.'
    }
    [ordered]@{
        hold = 'observer-process-openclipboard'
        failure_title = 'DarkReNamer - 복사 실패'
        failure_tree = $failureTree
        details_handle_preserved = $true
        details_foreground_restored = $true
        clipboard_released_in_finally = $true
    }
}
function Inspect-ObserverDiagnostic {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $ExpectedText,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][ValidateSet('escape', 'button')][string] $CloseMethod,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    $tree = Get-ObserverWindowTree -Window $Window -Process $Application.process -SessionId $SessionId -Label "$Prefix diagnostic"
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Window -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-diagnostic.png') -Label "$Prefix diagnostic"))
    Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-diagnostic-tree.json')) -Value $tree
    $editMatches = @($tree | Where-Object { $_.automation_id -ceq '1004' })
    $result = [ordered]@{
        title = $Window.Current.Name
        tree = $tree
        presentation = if ($editMatches.Count -eq 1) { 'read-only-multiline-edit' } else { 'message-box-baseline' }
        canonical_text = $null
        copy_selection = $null
        copy_all_mnemonic = $null
        baseline_ctrl_c = $null
        native_end_scroll = $null
        close = $null
    }
        $details = Get-ObserverReadOnlyDetails -Window $Window -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedText $ExpectedText -Label $Prefix
        $result.canonical_text = $details.evidence
        $result.copy_selection = Copy-GuiRegressionDocument -Mode selection -Application $Application -Edit $details.edit -ExpectedText $details.evidence.value_text -SessionId $SessionId -WaitSeconds $WaitSeconds -Label "$Prefix native edit selection copy"
        $result.copy_all_mnemonic = Copy-GuiRegressionDocument -Mode mnemonic -Application $Application -ExpectedText $details.evidence.value_text -SessionId $SessionId -WaitSeconds $WaitSeconds -Label "$Prefix explicit copy all"
        $details.edit.SetFocus()
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x23 -Label "$Prefix Ctrl+End" -ExtendedKey
        Start-Sleep -Milliseconds 150
        $visible = Get-ObserverVisibleText -TextPattern $details.text_pattern
        $ending = '파일 시스템 검사와 실행 확인은 변경 적용 시 별도로 수행합니다.'
        if (-not $visible.EndsWith($ending, [StringComparison]::Ordinal)) {
            throw "$Prefix did not expose the canonical ending after native scrolling."
        }
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Window -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-diagnostic-end.png') -Label "$Prefix diagnostic end scroll"))
        $result.native_end_scroll = [ordered]@{ input = 'native-edit-ctrl-end'; visible_text = $visible; ending_visible = $true }
    switch ($CloseMethod) {
        'escape' {
            Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label "$Prefix diagnostic Escape"
            Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label "$Prefix diagnostic"
            $result.close = [ordered]@{ input = 'keyboard-escape'; closed = $true }
        }
        'button' {
            $close = Find-UniqueAutomationElement -Root $Window -Process $Application.process -ExpectedSession $SessionId -AutomationId '2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label "$Prefix close button" -RequireEnabled -RequireWindowHandle
            Invoke-AutomationControl -Element $close -Label "$Prefix close button"
            Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label "$Prefix diagnostic"
            $result.close = [ordered]@{ input = 'close-button-id-2'; closed = $true }
        }
    }
    Wait-AcceptanceMainWindowForeground -Application $Application -WaitSeconds $WaitSeconds -Label "$Prefix diagnostic close"
    $result
}
function Get-ObserverConfirmationDefaultFocus {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId)
    $focused = Get-FocusedAcceptanceElement -Process $Application.process -ExpectedSession $SessionId -Label 'confirmation default focus'
    $snapshot = Get-ElementObservation -Element $focused
    $snapshot['is_default_cancel'] = $snapshot.automation_id -ceq 'CommandButton_2' -or $snapshot.name -ceq '취소'
    if (-not $snapshot.is_default_cancel) { throw 'Confirmation default focus is not Cancel.' }
    $snapshot
}
function Wait-ObserverConfirmation {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId, [Parameter(Mandatory)][int] $WaitSeconds, [Parameter(Mandatory)][string] $Label)
    Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name 'DarkReNamer - 안전한 적용 확인' -TimeoutSeconds $WaitSeconds -Label $Label
}
function Start-ObserverApplyFromPublicUi {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][string] $Label
    )
    $id = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, '32771')
    $buttonType = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::Button)
    $apply = $Application.main.FindFirst(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.AndCondition]::new($id, $buttonType))
    if ($null -ne $apply -and $apply.Current.IsEnabled -and -not $apply.Current.IsOffscreen) {
        Assert-AutomationBinding -Element $apply -Process $Application.process -ExpectedSession $SessionId -Label $Label
        return [pscustomobject]@{
            input = 'visible-command-rail'
            invocation = Start-AutomationControlInvoke -Element $apply -Label $Label
            menu_entry = $null
        }
    }

    $menuType = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::MenuItem)
    $fileMenus = @($Application.main.FindAll(
        [Windows.Automation.TreeScope]::Descendants, $menuType) |
        Where-Object { $_.Current.Name -ceq '파일(F)' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($fileMenus.Count -ne 1) {
        throw "$Label has neither a visible command rail nor one public File menu."
    }
    Assert-AutomationBinding -Element $fileMenus[0] -Process $Application.process -ExpectedSession $SessionId -Label "$Label File menu fallback"
    $menu = Get-ElementObservation -Element $fileMenus[0]
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow([IntPtr]$Application.main_handle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId `
        -MainWindowHandle ([IntPtr]$Application.main_handle) -RequireMainWindow
    $mainHandle = [IntPtr]$Application.main.Current.NativeWindowHandle
    $fileTarget = Get-GuiRegressionPhysicalTarget -Click -Element $fileMenus[0] -Application $Application -SessionId $SessionId -ExpectedRoot $mainHandle -Label "$Label File menu"
    $popup = Wait-AcceptancePopupMenu -Process $Application.process -ExpectedSession $SessionId -Label "$Label File popup"
    $popupElement = [Windows.Automation.AutomationElement]::FromHandle($popup)
    $items = @($popupElement.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::MenuItem)))
    $matches = @($items | Where-Object { $_.Current.Name -like '*변경 사항 적용*' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($matches.Count -ne 1) { throw "$Label public File menu Apply matched $($matches.Count) items." }
    $menuItem = Get-ElementObservation -Element $matches[0]
    $itemTarget = Get-GuiRegressionPhysicalTarget -Click -Element $matches[0] -Application $Application -SessionId $SessionId -ExpectedRoot $popup -Label "$Label public File menu Apply"
    Wait-AcceptancePopupMenuClosed -Process $Application.process -Label "$Label File popup"
    [pscustomobject]@{
        input = 'physical-mouse-file-menu-public-apply'
        invocation = $null
        menu_entry = [ordered]@{
            file = $menu
            file_target = $fileTarget
            apply = $menuItem
            apply_target = $itemTarget
        }
    }
}
function Scroll-ObserverTaskDialogToEnd {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Confirmation,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $CaptureLeaf,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $scrollCondition = [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'VerticalScrollBar'),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ScrollBar))
    $scrolls = @($Confirmation.FindAll([Windows.Automation.TreeScope]::Descendants, $scrollCondition) |
        Where-Object { $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($scrolls.Count -eq 0) {
        [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf $CaptureLeaf -Label "$Label fully visible"))
        return [ordered]@{
            input = 'none'
            scrollbar = $null
            physical_targets = @()
            tree = Get-ObserverWindowTree -Window $Confirmation -Process $Application.process -SessionId $SessionId -Label "$Label fully visible"
            bottom_capture = $CaptureLeaf
            visual_review_required_for_content_tail = $true
            status = 'native-scrollbar-not-present-content-fits'
        }
    }
    if ($scrolls.Count -ne 1) { throw "$Label vertical scrollbar matched $($scrolls.Count) elements." }
    $scroll = $scrolls[0]
    $buttons = @($scroll.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::Button)))
    $down = @($buttons | Where-Object { $_.Current.Name -ceq '아래쪽 스크롤 화살표' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($down.Count -ne 1) { throw "$Label down-scroll button matched $($down.Count) elements." }
    $root = [IntPtr]$Confirmation.Current.NativeWindowHandle
    $targets = [Collections.Generic.List[object]]::new()

    $rangeObject = $null
    $range = if ($scroll.TryGetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern, [ref]$rangeObject)) {
        [Windows.Automation.RangeValuePattern]$rangeObject
    } else { $null }

    $scrollPattern = $null
    if ($null -eq $range) {
        $patternCandidates = [Collections.Generic.List[Windows.Automation.AutomationElement]]::new()
        $patternCandidates.Add($Confirmation)
        foreach ($candidate in $Confirmation.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
            $patternCandidates.Add($candidate)
        }
        foreach ($candidate in $patternCandidates) {
            $candidatePattern = $null
            if ($candidate.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$candidatePattern)) {
                $typedPattern = [Windows.Automation.ScrollPattern]$candidatePattern
                if ($typedPattern.Current.VerticallyScrollable) {
                    if ($null -ne $scrollPattern) { throw "$Label exposed more than one vertically scrollable UIA container." }
                    $scrollPattern = $typedPattern
                }
            }
        }
    }

    $nativeCandidates = [Collections.Generic.List[object]]::new()
    if ($null -eq $range -and $null -eq $scrollPattern) {
        $scrollHandle = [IntPtr]$scroll.Current.NativeWindowHandle
        if ($scrollHandle -ne [IntPtr]::Zero) {
            $nativeCandidates.Add([ordered]@{ handle = $scrollHandle; bar = 2; origin = 'scrollbar-uia-hwnd'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($scrollHandle) })
        }
        $scrollRect = $scroll.Current.BoundingRectangle
        $scrollPoint = [DarkReNamerVmAcceptanceNative+Point]::new()
        $scrollPoint.X = [int][Math]::Floor($scrollRect.Left + ($scrollRect.Width / 2.0))
        $scrollPoint.Y = [int][Math]::Floor($scrollRect.Top + ($scrollRect.Height / 2.0))
        $hitHandle = [DarkReNamerVmAcceptanceNative]::WindowFromPoint($scrollPoint)
        if ($hitHandle -ne [IntPtr]::Zero -and $hitHandle -ne $scrollHandle) {
            $nativeCandidates.Add([ordered]@{ handle = $hitHandle; bar = 2; origin = 'scrollbar-center-window-from-point-sb-ctl'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($hitHandle) })
            $nativeCandidates.Add([ordered]@{ handle = $hitHandle; bar = 1; origin = 'scrollbar-center-window-from-point-sb-vert'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($hitHandle) })
        }
        $nativeCandidates.Add([ordered]@{ handle = $root; bar = 1; origin = 'taskdialog-root-sb-vert'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($root) })
        $nativeCandidates.Add([ordered]@{ handle = $root; bar = 2; origin = 'taskdialog-root-sb-ctl'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($root) })
    }
    $native = $null
    foreach ($candidate in $nativeCandidates) {
        $values = [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo([IntPtr]$candidate.handle, [int]$candidate.bar)
        if ($null -eq $values -or $values.Count -ne 5) { continue }
        $bottomPosition = [int]$values[1] - [Math]::Max(([int]$values[2] - 1), 0)
        if ([int]$values[1] -le [int]$values[0] -or [int]$values[2] -le 0 -or [int]$values[3] -ge $bottomPosition) { continue }
        $native = [ordered]@{
            handle = ([IntPtr]$candidate.handle).ToInt64()
            bar = [int]$candidate.bar
            origin = $candidate.origin
            description = $candidate.description
            initial = [ordered]@{ minimum = [int]$values[0]; maximum = [int]$values[1]; page = [int]$values[2]; position = [int]$values[3]; bottom_position = $bottomPosition }
        }
        break
    }
    if ($null -eq $range -and $null -eq $scrollPattern -and $null -eq $native) {
        throw "$Label exposes no verifiable UIA or Win32 scroll position state."
    }

    $initialValue = if ($null -ne $range) { [double]$range.Current.Value } elseif ($null -ne $scrollPattern) { [double]$scrollPattern.Current.VerticalScrollPercent } else { [int]$native.initial.position }
    $maximum = if ($null -ne $range) { [double]$range.Current.Maximum } elseif ($null -ne $scrollPattern) { 100.0 } else { [int]$native.initial.bottom_position }
    $finalValue = $initialValue
    for ($index = 0; $index -lt 128 -and $finalValue -lt $maximum; $index++) {
        $targets.Add((Get-GuiRegressionPhysicalTarget -Click -Element $down[0] -Application $Application -SessionId $SessionId -ExpectedRoot $root -Label "$Label down-scroll arrow"))
        Start-Sleep -Milliseconds 35
        if ($null -ne $range) {
            $finalValue = [double]$range.Current.Value
        } elseif ($null -ne $scrollPattern) {
            $finalValue = [double]$scrollPattern.Current.VerticalScrollPercent
        } else {
            $values = [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo([IntPtr]$native.handle, [int]$native.bar)
            if ($null -eq $values -or $values.Count -ne 5) { throw "$Label lost Win32 scroll position state during physical scrolling." }
            $expectedBottom = [int]$values[1] - [Math]::Max(([int]$values[2] - 1), 0)
            if ($expectedBottom -ne [int]$native.initial.bottom_position) { throw "$Label Win32 scroll range changed during physical scrolling." }
            $finalValue = [int]$values[3]
        }
    }
    if ($finalValue -lt $maximum) {
        throw "$Label did not reach the verified scrollbar bottom after 128 physical clicks."
    }
    $tree = Get-ObserverWindowTree -Window $Confirmation -Process $Application.process -SessionId $SessionId -Label "$Label bottom"
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf $CaptureLeaf -Label "$Label bottom"))
    [ordered]@{
        input = 'bounded physical mouse clicks on native TaskDialog down-scroll arrow'
        scrollbar = Get-ElementObservation -Element $scroll
        physical_targets = $targets.ToArray()
        range_value = [ordered]@{
            provider = if ($null -ne $range) { 'UIAutomation.RangeValuePattern' } elseif ($null -ne $scrollPattern) { 'UIAutomation.ScrollPattern.VerticalScrollPercent' } else { 'Win32.GetScrollInfo' }
            initial = $initialValue
            final = $finalValue
            maximum = $maximum
            reached_maximum = $true
            win32 = $native
        }
        tree = $tree
        bottom_capture = $CaptureLeaf
        visual_review_required_for_content_tail = $true
        status = 'physically-scrolled-to-native-bottom'
    }
}
function Open-ObserverConfirmationDetails {
    param([Parameter(Mandatory)][Windows.Automation.AutomationElement] $Confirmation, [Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId, [Parameter(Mandatory)][int] $WaitSeconds)
    $button = Find-UniqueAutomationElement -Root $Confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1102' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'confirmation full-details command link' -RequireEnabled
    if ($button.Current.Name -cne '예시 전체 정보 · 복사') { throw 'Confirmation full-details command text differs.' }
    $buttonObservation = Get-ElementObservation -Element $button
    if ($buttonObservation.automation_id -cne 'CommandLink_1102') {
        throw "Full-details command link has unexpected AutomationId $($buttonObservation.automation_id)."
    }
    $button.SetFocus()
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'confirmation full-details command link Enter'
    $details = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name 'DarkReNamer - 변경 예시 전체 정보' -TimeoutSeconds $WaitSeconds -Label 'confirmation full-details prompt'
    [pscustomobject]@{ window = $details; command_link = $buttonObservation }
}
function Get-ObserverPublicApplyState {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][string] $Label
    )
    $id = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, '32771')
    $buttonType = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
    $rail = $Application.main.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.AndCondition]::new($id, $buttonType))
    if ($null -ne $rail -and -not $rail.Current.IsOffscreen) {
        Assert-AutomationBinding -Element $rail -Process $Application.process -ExpectedSession $SessionId -Label "$Label visible rail"
        return [ordered]@{ source = 'visible-command-rail'; enabled = [bool]$rail.Current.IsEnabled; automation = Get-ElementObservation -Element $rail }
    }
    $menuType = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::MenuItem)
    $fileMenus = @($Application.main.FindAll([Windows.Automation.TreeScope]::Descendants, $menuType) | Where-Object { $_.Current.Name -ceq '파일(F)' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($fileMenus.Count -ne 1) { throw "$Label public File menu matched $($fileMenus.Count) elements." }
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow([IntPtr]$Application.main_handle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId `
        -MainWindowHandle ([IntPtr]$Application.main_handle) -RequireMainWindow
    $fileTarget = Get-GuiRegressionPhysicalTarget -Click -Element $fileMenus[0] -Application $Application -SessionId $SessionId -ExpectedRoot ([IntPtr]$Application.main.Current.NativeWindowHandle) -Label "$Label File menu"
    $popup = Wait-AcceptancePopupMenu -Process $Application.process -ExpectedSession $SessionId -Label "$Label File popup"
    try {
        $popupElement = [Windows.Automation.AutomationElement]::FromHandle($popup)
        $items = @($popupElement.FindAll([Windows.Automation.TreeScope]::Descendants, $menuType))
        $matches = @($items | Where-Object { $_.Current.Name -like '*변경 사항 적용*' -and -not $_.Current.IsOffscreen })
        if ($matches.Count -ne 1) { throw "$Label public File menu Apply matched $($matches.Count) items." }
        [ordered]@{ source = 'physical-file-menu'; enabled = [bool]$matches[0].Current.IsEnabled; file_target = $fileTarget; automation = Get-ElementObservation -Element $matches[0] }
    }
    finally {
        Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label "$Label close File popup"
        Wait-AcceptancePopupMenuClosed -Process $Application.process -Label "$Label File popup"
    }
}
function Invoke-ObserverBlockedChecks {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][object] $Fixture,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $status = Find-UniqueAutomationElement -Root $Application.main -Process $Application.process -ExpectedSession $SessionId -AutomationId '1007' -ControlType ([Windows.Automation.ControlType]::Text) -TimeoutSeconds $WaitSeconds -Label 'blocked-check status message' -RequireWindowHandle
    $reset = Find-UniqueAutomationElement -Root $Application.main -Process $Application.process -ExpectedSession $SessionId -AutomationId '32781' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'blocked-check reset names' -RequireWindowHandle
    Invoke-AutomationControl -Element $reset -Label 'blocked-check reset names'
    Start-Sleep -Milliseconds 200
    $applyState = Get-ObserverPublicApplyState -Application $Application -SessionId $SessionId -Label 'blocked-check no-change Apply command'
    if ($applyState.enabled) { throw 'Apply stayed enabled with no changes.' }
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-blocked-no-change.png') -Label 'no-change blocked state'))
    $noChange = [ordered]@{ apply = $applyState; status = $status.Current.Name; blocked = $true }

    $collisionName = '충돌-😀-같은-대상.txt'
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 0 -Name $collisionName -SessionId $SessionId -WaitSeconds $WaitSeconds
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 1 -Name $collisionName -SessionId $SessionId -WaitSeconds $WaitSeconds
    Start-Sleep -Milliseconds 200
    $collisionStatus = $status.Current.Name
    $applyState = Get-ObserverPublicApplyState -Application $Application -SessionId $SessionId -Label 'blocked-check collision Apply command'
    if ($applyState.enabled -or $collisionStatus.IndexOf('대상 경로 충돌', [StringComparison]::Ordinal) -lt 0) {
        throw 'Collision state did not block Apply with its existing meaning.'
    }
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-blocked-collision.png') -Label 'collision blocked state'))
    $collision = [ordered]@{ apply = $applyState; status = $collisionStatus; blocked = $true }

    Invoke-AutomationControl -Element $reset -Label 'reset collision proposals'
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 0 -Name 'bad:name.txt' -SessionId $SessionId -WaitSeconds $WaitSeconds
    Start-Sleep -Milliseconds 200
    $invalidStatus = $status.Current.Name
    $applyState = Get-ObserverPublicApplyState -Application $Application -SessionId $SessionId -Label 'blocked-check invalid-name Apply command'
    if ($applyState.enabled -or $invalidStatus.IndexOf('잘못된 대상 이름', [StringComparison]::Ordinal) -lt 0) {
        throw 'Invalid-name state did not block Apply with its existing meaning.'
    }
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-blocked-invalid.png') -Label 'invalid-name blocked blocked state'))
    $invalid = [ordered]@{ apply = $applyState; status = $invalidStatus; blocked = $true }
    Invoke-AutomationControl -Element $reset -Label 'reset invalid proposal'
    Start-Sleep -Milliseconds 200
    $actual = Get-ObserverFixtureState -FixtureRoot $Fixture.root
    if (-not (Test-ObserverFixtureStateEqual -Expected $Fixture.initial -Actual $actual)) {
        throw 'Blocking checks changed a fixture file, content digest, or NTFS identity.'
    }
    Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
    [ordered]@{ no_change = $noChange; collision = $collision; invalid_name = $invalid; disk_unchanged = $true; journal_residue_count = 0 }
}
function Invoke-ObserverActualApply {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][object] $Fixture,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 0 -Name $Fixture.destination_names[0] -SessionId $SessionId -WaitSeconds $WaitSeconds
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 1 -Name $Fixture.destination_names[1] -SessionId $SessionId -WaitSeconds $WaitSeconds
    $selection = Set-ObserverSelectedRow -Application $Application -Grid $Grid -Row 0 -SessionId $SessionId
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-actual-apply-preview.png') -Label 'actual 3/1/2 Apply preview'))

    $applyTrigger = Start-ObserverApplyFromPublicUi -Application $Application -SessionId $SessionId -Label 'actual 3/1/2 Apply command'
    $applyInvocation = $applyTrigger.invocation
    $confirmation = Wait-ObserverConfirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'actual 3/1/2 Apply confirmation'
    $tree = Get-ObserverWindowTree -Window $confirmation -Process $Application.process -SessionId $SessionId -Label 'actual 3/1/2 Apply confirmation'
    if (([string]::Join("`n", @($tree | ForEach-Object { $_.name } | Where-Object { $_ }))).IndexOf('목록 전체 3개 · 선택 1개 · 실제 변경 2개', [StringComparison]::Ordinal) -lt 0) {
        throw 'Actual Apply confirmation lost the exact 3/1/2 scope.'
    }
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-actual-apply-confirmation.png') -Label 'actual 3/1/2 Apply confirmation'))
    $confirm = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1101' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'actual Apply command link' -RequireEnabled -RequireWindowHandle
    $confirmInvocation = Start-AutomationControlInvoke -Element $confirm -Label 'actual Apply command link'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $complete = -not (Test-Path -LiteralPath $Fixture.paths[0]) -and
            -not (Test-Path -LiteralPath $Fixture.paths[1]) -and
            (Test-Path -LiteralPath $Fixture.destinations[0] -PathType Leaf) -and
            (Test-Path -LiteralPath $Fixture.destinations[1] -PathType Leaf) -and
            (Test-Path -LiteralPath $Fixture.paths[2] -PathType Leaf)
        if ($complete) {
            try { Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA; break } catch {}
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    Complete-AutomationControlInvoke -State $confirmInvocation -TimeoutSeconds $WaitSeconds
    if ($null -ne $applyInvocation) { Complete-AutomationControlInvoke -State $applyInvocation -TimeoutSeconds $WaitSeconds }
    if (-not $complete) { throw 'Actual 3/1/2 Apply did not reach the exact destination paths.' }
    Wait-AcceptanceMainWindowForeground -Application $Application -WaitSeconds $WaitSeconds -Label 'actual 3/1/2 Apply'

    $initial0 = @($Fixture.initial | Where-Object { $_.path -ceq $Fixture.paths[0] })[0]
    $initial1 = @($Fixture.initial | Where-Object { $_.path -ceq $Fixture.paths[1] })[0]
    $initial2 = @($Fixture.initial | Where-Object { $_.path -ceq $Fixture.paths[2] })[0]
    $actual0 = Get-Item -LiteralPath $Fixture.destinations[0] -Force
    $actual1 = Get-Item -LiteralPath $Fixture.destinations[1] -Force
    $actual2 = Get-Item -LiteralPath $Fixture.paths[2] -Force
    $preserved = (Get-LowerSha256 -Path $actual0.FullName) -ceq $initial0.content_sha256 -and
        [DarkReNamerVmNative]::GetFileIdentity($actual0.FullName) -ceq $initial0.identity -and
        (Get-LowerSha256 -Path $actual1.FullName) -ceq $initial1.content_sha256 -and
        [DarkReNamerVmNative]::GetFileIdentity($actual1.FullName) -ceq $initial1.identity -and
        (Get-LowerSha256 -Path $actual2.FullName) -ceq $initial2.content_sha256 -and
        [DarkReNamerVmNative]::GetFileIdentity($actual2.FullName) -ceq $initial2.identity
    if (-not $preserved) { throw 'Actual 3/1/2 Apply changed content or NTFS identity.' }
    Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
    [void]$Captures.Add((Save-WindowScreenshot -ForegroundObservations $script:acceptanceForegroundObservations -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-actual-apply-complete.png') -Label 'actual 3/1/2 Apply completion'))
    [ordered]@{ scope = '3/1/2'; apply_entry = [ordered]@{ input = $applyTrigger.input; menu_entry = $applyTrigger.menu_entry }; selection = $selection; destinations_reached = $true; unchanged_row_preserved = $true; content_and_identity_preserved = $true; journal_residue_count = 0 }
}
function Close-AcceptanceApplication {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][ValidateSet('keyboard', 'ordinary')][string] $CloseInput
    )
    $Application.process.Refresh()
    if ($Application.process.HasExited) { throw 'The acceptance application exited before normal close.' }
    if ($CloseInput -ceq 'keyboard') {
        Assert-ExactApplicationMainWindowBinding `
            -Process $Application.process `
            -ExpectedSession $SessionId `
            -MainWindowHandle ([IntPtr]$Application.main_handle) `
            -MainWindow $Application.main `
            -ExpectedClassName 'DarkReNamerWindow' `
            -ExpectedTitle 'DarkReNamer' `
            -Label 'acceptance application keyboard close'
        $Application.main.SetFocus()
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x73 -Label 'application Alt+F4 close'
    }
    else {
        Close-ExactApplicationMainWindow `
            -Process $Application.process `
            -ExpectedSession $SessionId `
            -MainWindowHandle ([IntPtr]$Application.main_handle) `
            -MainWindow $Application.main `
            -ExpectedClassName 'DarkReNamerWindow' `
            -ExpectedTitle 'DarkReNamer' `
            -Label 'acceptance application ordinary close'
    }
    if (-not $Application.process.WaitForExit([Math]::Min(30, $WaitSeconds) * 1000)) {
        throw 'The acceptance application did not close before the bounded deadline.'
    }
    if ($Application.process.ExitCode -ne 0) { throw 'The acceptance application returned a nonzero exit code.' }
    $Application.process.ExitCode
}
