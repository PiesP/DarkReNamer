[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/windows-vm-module-loader.ps1')
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind ui)) { . $definition }

function Assert-Fails {
    param([scriptblock] $Action, [string] $Expected)
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure: $Expected"
}

$pathDialog = [pscustomobject]@{ ProcessId=42; Owner=10L; Visible=$true;
    ClassName='#32770'; Title='파일에서 경로목록 읽어 추가하기'; Handle=20L }
if ($null -ne (Resolve-ObserverPathImportWindowCandidate -Windows @() -ProcessId 42 -MainWindowHandle 10)) {
    throw 'An absent native dialog was accepted.'
}
foreach ($change in @(
    @{ ProcessId=43 }, @{ Owner=11L }, @{ Visible=$false }, @{ ClassName='Other' }, @{ Title='Other' })) {
    $wrong = [pscustomobject]@{ ProcessId=42; Owner=10L; Visible=$true;
        ClassName='#32770'; Title=$pathDialog.Title; Handle=30L }
    foreach ($key in $change.Keys) { $wrong.$key = $change[$key] }
    $selected = Resolve-ObserverPathImportWindowCandidate -Windows @($wrong,$pathDialog) `
        -ProcessId 42 -MainWindowHandle 10
    if ($selected.Handle -ne 20) { throw 'The native import resolver accepted a mismatched window.' }
    if ($null -ne (Resolve-ObserverPathImportWindowCandidate -Windows @($wrong) -ProcessId 42 -MainWindowHandle 10)) {
        throw 'The native import resolver accepted an unbound dialog.'
    }
}
Assert-Fails -Expected 'multiple bound native dialogs' -Action {
    Resolve-ObserverPathImportWindowCandidate -Windows @($pathDialog,$pathDialog) -ProcessId 42 -MainWindowHandle 10
}

# These inert UIA/native adapters expose observations and record requests. The
# complete production functions retain all traversal, ownership and copy logic.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace Windows.Automation {
    public enum TreeScope { Descendants }
    public class ControlType {
        public static readonly ControlType ScrollBar = new ControlType();
        public static readonly ControlType Button = new ControlType();
        public static readonly ControlType Edit = new ControlType();
    }
    public class Bounds {
        public double X = 10, Y = 20, Width = 20, Height = 40;
        public double Left { get { return X; } }
        public double Top { get { return Y; } }
    }
    public class ElementInfo {
        public int ProcessId = 42, NativeWindowHandle = 10;
        public string AutomationId = "", Name = "";
        public bool IsEnabled = true, IsOffscreen;
        public ControlType ControlType = ControlType.Button;
        public Bounds BoundingRectangle = new Bounds();
    }
    public class Condition {
        public static readonly Condition TrueCondition = new Condition();
        public virtual bool Matches(AutomationElement element) { return true; }
    }
    public class PropertyCondition : Condition {
        private readonly string property; private readonly object value;
        public PropertyCondition(object property, object value) { this.property = (string)property; this.value = value; }
        public override bool Matches(AutomationElement element) {
            return Object.Equals(typeof(ElementInfo).GetField(property).GetValue(element.Current), value);
        }
    }
    public class AndCondition : Condition {
        private readonly Condition[] conditions;
        public AndCondition(params Condition[] conditions) { this.conditions = conditions; }
        public override bool Matches(AutomationElement element) {
            foreach (Condition condition in conditions) if (!condition.Matches(element)) return false;
            return true;
        }
    }
    public class AutomationElement {
        public static readonly object AutomationIdProperty = "AutomationId", ControlTypeProperty = "ControlType";
        public ElementInfo Current = new ElementInfo();
        public List<AutomationElement> Children = new List<AutomationElement>();
        public Dictionary<object, object> Patterns = new Dictionary<object, object>();
        public int FocusCalls;
        public void SetFocus() { FocusCalls++; }
        public bool TryGetCurrentPattern(object key, out object value) { return Patterns.TryGetValue(key, out value); }
        public AutomationElement[] FindAll(TreeScope scope, Condition condition) {
            var result = new List<AutomationElement>();
            foreach (var child in Children) {
                if (condition.Matches(child)) result.Add(child);
                result.AddRange(child.FindAll(scope, condition));
            }
            return result.ToArray();
        }
    }
    public class TextRange {
        public string Text;
        public string GetText(int maximum) { return Text; }
    }
    public class TextPattern {
        public static readonly object Pattern = new object();
        public TextRange[] Selection = new TextRange[0];
        public TextRange[] GetSelection() { return Selection; }
    }
    public class RangeValuePattern {
        public static readonly object Pattern = new object();
        public RangeInfo Current = new RangeInfo();
        public class RangeInfo { public double Value, Maximum; }
    }
    public class ScrollPattern {
        public static readonly object Pattern = new object();
        public ScrollInfo Current = new ScrollInfo();
        public class ScrollInfo { public bool VerticallyScrollable; public double VerticalScrollPercent; }
    }
}
public static class DarkReNamerVmNative {
    public static uint HitProcess = 42, HitThread = 1;
    public static IntPtr Foreground = new IntPtr(10);
    public static uint GetWindowThreadProcessId(IntPtr window, out uint process) { process = HitProcess; return HitThread; }
    public static IntPtr GetForegroundWindow() { return Foreground; }
    public static bool SetForegroundWindow(IntPtr window) { Foreground = window; return true; }
}
public static class DarkReNamerVmAcceptanceNative {
    public struct Point { public int X, Y; }
    public class ClipboardSnapshot {
        public uint SequenceNumber;
        public uint[] Formats = new uint[0];
        public string UnicodeText = "";
    }
    public class WindowMeasurement {
        public long Handle, Owner;
        public uint ProcessId;
        public string ClassName = "fixture", Title = "private title";
        public bool Visible = true;
        public int Left, Top, Right = 100, Bottom = 100;
    }
    public static IntPtr Hit = new IntPtr(21), Root = new IntPtr(10);
    public static int Clicks, Moves, ScrollReads;
    public static int[][] ScrollValues;
    public static ClipboardSnapshot Before, After;
    public static int Clears;
    public static uint ClearedSequence;
    public static string ClearedText, ClearResult = "cleared";
    public static WindowMeasurement[] Windows = new WindowMeasurement[0];
    public static IntPtr WindowFromPoint(Point point) { return Hit; }
    public static IntPtr GetAncestor(IntPtr window, uint flags) { return Root; }
    public static void MoveCursor(int x, int y) { Moves++; }
    public static void Click() { Clicks++; }
    public static string[] DescribeWindow(IntPtr window) { return new string[] { window.ToString() }; }
    public static int[] TryReadScrollInfo(IntPtr window, int bar) {
        return ScrollValues[Math.Min(ScrollReads++, ScrollValues.Length - 1)];
    }
    public static ClipboardSnapshot ReadOrInitializeEmptyClipboardSnapshot() { return Before; }
    public static ClipboardSnapshot ReadClipboardSnapshot() { return After; }
    public static string ClearClipboardIfOwned(uint sequence, string text) {
        Clears++; ClearedSequence = sequence; ClearedText = text; return ClearResult;
    }
    public static WindowMeasurement[] ReadProcessTopLevelWindows(uint process) { return Windows; }
}
'@

& {
    function Assert-AutomationBinding { param($Element, $Process, $ExpectedSession, $Label) }
    $element = [Windows.Automation.AutomationElement]::new()
    $application = @{ process = @{ Id = 42 }; main_handle = 11 }
    $arguments = @{ Element = $element; Application = $application; SessionId = 1; ExpectedRoot = [IntPtr]10; Label = 'physical fixture' }
    $target = Get-GuiRegressionPhysicalTarget @arguments -Click
    if ($target.x -ne 20 -or $target.y -ne 40 -or $target.hit_window -ne 21 -or
        [DarkReNamerVmAcceptanceNative]::Clicks -ne 1) { throw 'Physical target lost its observed center/binding.' }
    foreach ($case in @('foreign-pid', 'foreign-root', 'main-instead-of-modal', 'zero-hit', 'zero-thread', 'foreign-foreground')) {
        [DarkReNamerVmNative]::HitProcess = 42; [DarkReNamerVmNative]::HitThread = 1
        [DarkReNamerVmNative]::Foreground = [IntPtr]10
        [DarkReNamerVmAcceptanceNative]::Hit = [IntPtr]21; [DarkReNamerVmAcceptanceNative]::Root = [IntPtr]10
        switch ($case) {
            'foreign-pid' { [DarkReNamerVmNative]::HitProcess = 99 }
            'foreign-root' { [DarkReNamerVmAcceptanceNative]::Root = [IntPtr]99 }
            'main-instead-of-modal' { [DarkReNamerVmAcceptanceNative]::Root = [IntPtr]11 }
            'zero-hit' { [DarkReNamerVmAcceptanceNative]::Hit = [IntPtr]::Zero }
            'zero-thread' { [DarkReNamerVmNative]::HitThread = 0 }
            'foreign-foreground' { [DarkReNamerVmNative]::Foreground = [IntPtr]99 }
        }
        $expected = if ($case -ceq 'foreign-foreground') { 'foreground does not belong' } else {
            'hit_window=*hit_process_id=*hit_root_window=*expected_process_id=42*expected_root_window=10'
        }
        Assert-Fails { Get-GuiRegressionPhysicalTarget @arguments -Click } $expected
        if ([DarkReNamerVmAcceptanceNative]::Clicks -ne 1) { throw "Unsafe $case target received input." }
    }
    [DarkReNamerVmNative]::HitProcess = 42; [DarkReNamerVmNative]::HitThread = 1
    [DarkReNamerVmNative]::Foreground = [IntPtr]10
    [DarkReNamerVmAcceptanceNative]::Hit = [IntPtr]21; [DarkReNamerVmAcceptanceNative]::Root = [IntPtr]10
    function Get-ElementObservation { param($Element)
        @{ offscreen = $Element.Current.IsOffscreen; bounds = @{ x = 10; y = 20; width = 20; height = 40 } }
    }
    $reach = Get-ObserverControlReachability @arguments -WorkArea @{ left = 0; top = 0; right = 100; bottom = 100 }
    if ($reach.status -cne 'reachable' -or $null -eq $reach.physical_mouse_target) { throw 'Valid physical control was rejected.' }
    [DarkReNamerVmNative]::HitProcess = 99
    $reach = Get-ObserverControlReachability @arguments -WorkArea @{ left = 0; top = 0; right = 100; bottom = 100 }
    if ($reach.status -cne 'inaccessible' -or $reach.observation -notlike '*hit_process_id=99*') { throw 'Foreign physical control lost its rejection diagnostic.' }
    $element.Current.IsOffscreen = $true
    $reach = Get-ObserverControlReachability @arguments -WorkArea @{ left = 0; top = 0; right = 100; bottom = 100 }
    if ($reach.status -cne 'inaccessible' -or $reach.observation -cne 'control-bounds-outside-work-area') { throw 'Offscreen control was considered reachable.' }
}

& {
    function Start-Sleep { param($Milliseconds) }
    function Get-ElementObservation { param($Element) @{ automation_id = $Element.Current.AutomationId } }
    function Get-ObserverWindowTree { param($Window, $Process, $SessionId, $Label) @() }
    function Save-WindowScreenshot { param($ForegroundObservations, $Window, $Process, $ExpectedSession, $Root, $Leaf, $Label) $Leaf }
    function Get-GuiRegressionPhysicalTarget { param($Element, $Application, $SessionId, $ExpectedRoot, $Label, [switch]$Click)
        if (-not $Click -or $ExpectedRoot -ne [IntPtr]10 -or $Element -ne $scrollFixture.down) { throw 'Scroll input lost its exact target.' }
        $probe.clicks++; @{ click = $probe.clicks }
    }
    $script:acceptanceForegroundObservations = [Collections.Generic.List[object]]::new()
    $confirmation = [Windows.Automation.AutomationElement]::new()
    $scroll = [Windows.Automation.AutomationElement]::new()
    $scroll.Current.AutomationId = 'VerticalScrollBar'; $scroll.Current.ControlType = [Windows.Automation.ControlType]::ScrollBar
    $scroll.Current.NativeWindowHandle = 21
    $down = [Windows.Automation.AutomationElement]::new()
    $down.Current.Name = '아래쪽 스크롤 화살표'
    $scroll.Children.Add($down)
    $scrollFixture = @{ down = $down }
    [DarkReNamerVmAcceptanceNative]::Hit = [IntPtr]21
    foreach ($case in @('fits', 'success', 'initial-null', 'initial-four', 'initial-six', 'lost-null', 'lost-six', 'changed-range', 'stalled')) {
        $confirmation.Children.Clear()
        if ($case -cne 'fits') { $confirmation.Children.Add($scroll) }
        $probe = @{ clicks = 0 }
        $captures = [Collections.Generic.List[object]]::new()
        [DarkReNamerVmAcceptanceNative]::ScrollReads = 0
        $initial = [int[]]@(0, 10, 3, 0, 0)
        $final = [int[]]@(0, 10, 3, 8, 8)
        switch ($case) {
            'initial-null' { $initial = $null; $final = $null }
            'initial-four' { $initial = [int[]]@(0, 10, 3, 0); $final = $initial }
            'initial-six' { $initial = [int[]]@(0, 10, 3, 0, 0, 0); $final = $initial }
            'lost-null' { $final = $null }
            'lost-six' { $final = [int[]]@(0, 10, 3, 8, 8, 8) }
            'changed-range' { $final = [int[]]@(0, 20, 3, 8, 8) }
            'stalled' { $final = $initial }
        }
        [DarkReNamerVmAcceptanceNative]::ScrollValues = [int[][]]@($initial, $final)
        $arguments = @{ Confirmation = $confirmation; Application = @{ process = $null }; SessionId = 1; WaitSeconds = 1;
            OutputRoot = 'fixture'; CaptureLeaf = 'bottom.png'; Label = 'scroll fixture'; Captures = $captures }
        if ($case -cin @('fits', 'success')) {
            $result = Scroll-ObserverTaskDialogToEnd @arguments
            if ($captures.Count -ne 1 -or $result.bottom_capture -cne 'bottom.png') { throw 'Scroll success did not capture its final state.' }
            if ($case -ceq 'success' -and ($probe.clicks -ne 1 -or $result.range_value.final -ne 8 -or
                $result.range_value.maximum -ne 8 -or $result.range_value.provider -cne 'Win32.GetScrollInfo')) { throw 'Win32 five-value range was interpreted incorrectly.' }
        }
        else {
            $expected = if ($case -like 'initial-*') { 'no verifiable UIA or Win32' } elseif ($case -like 'lost-*') { 'lost Win32 scroll position' } `
                elseif ($case -ceq 'changed-range') { 'range changed' } else { 'after 128 physical clicks' }
            Assert-Fails { Scroll-ObserverTaskDialogToEnd @arguments } $expected
            if ($captures.Count -ne 0) { throw 'Failed scroll published a success capture.' }
            $expectedClicks = if ($case -like 'initial-*') { 0 } elseif ($case -ceq 'stalled') { 128 } else { 1 }
            if ($probe.clicks -ne $expectedClicks) { throw "Unexpected $case physical input count." }
        }
    }
}

& {
    $calls = [Collections.Generic.List[string]]::new()
    $edit = [Windows.Automation.AutomationElement]::new()
    $edit.Current.NativeWindowHandle = 101
    $textPattern = [Windows.Automation.TextPattern]::new()
    $range = [Windows.Automation.TextRange]::new(); $range.Text = "first`n둘째"
    $textPattern.Selection = @($range)
    $edit.Patterns.Add([Windows.Automation.TextPattern]::Pattern, $textPattern)
    function Set-ObserverExactEditFocus { param($Application, $Edit, $SessionId, $Label, $TimeoutMilliseconds)
        $calls.Add('focus'); 101L
    }
    function Send-AcceptanceChord { param($Process, $ExpectedSession, $Modifier, $VirtualKey, $Label, [switch]$ExtendedKey)
        $calls.Add("chord:$Modifier/$VirtualKey/$([bool]$ExtendedKey)")
    }
    function Send-AcceptanceTwoModifierChord { param($Process, $ExpectedSession, $Modifier, $SecondModifier, $VirtualKey, $Label, [switch]$ExtendedKey)
        $calls.Add("two:$Modifier/$SecondModifier/$VirtualKey/$([bool]$ExtendedKey)")
    }
    function Get-FocusedAcceptanceElement { param($Process, $ExpectedSession, $Label)
        if ($case -ceq 'focus-lost') { $edit.Current.NativeWindowHandle = 102 }
        $edit
    }
    function Wait-AcceptanceClipboardText { param($PreviousSequence, $ExpectedText, $TimeoutSeconds, $Label, [switch]$AllowDelayedRendering)
        if ($PreviousSequence -ne 10 -or $ExpectedText -cne "first`r`n둘째" -or
            [bool]$AllowDelayedRendering -ne ($mode -ceq 'selection')) { throw 'Copy wait contract changed.' }
        $calls.Add('wait')
        if ($case -like 'wait-*') { throw 'injected copy observation failure' }
        [DarkReNamerVmAcceptanceNative]::After
    }
    function Start-Sleep { param($Milliseconds) }
    function Get-Date { $clock.value = $clock.value.AddSeconds(4); $clock.value }
    foreach ($mode in @('selection', 'mnemonic')) {
        foreach ($case in @('success', 'preflight-zero', 'preflight-foreign', 'wait-owned', 'wait-foreign', 'cleanup-changed', 'focus-lost', 'no-text-pattern', 'wrong-selection')) {
            if ($mode -ceq 'mnemonic' -and $case -cin @('focus-lost', 'no-text-pattern', 'wrong-selection')) { continue }
            $calls.Clear(); $clock = @{ value = [DateTime]::UtcNow }
            $edit.Current.NativeWindowHandle = 101; $range.Text = "first`n둘째"
            $edit.Patterns.Clear(); $edit.Patterns.Add([Windows.Automation.TextPattern]::Pattern, $textPattern)
            $before = [DarkReNamerVmAcceptanceNative+ClipboardSnapshot]::new(); $before.SequenceNumber = 10
            $after = [DarkReNamerVmAcceptanceNative+ClipboardSnapshot]::new(); $after.SequenceNumber = 11; $after.Formats = @(13); $after.UnicodeText = "first`r`n둘째"
            if ($case -ceq 'preflight-zero') { $before.SequenceNumber = 0 }
            if ($case -ceq 'preflight-foreign') { $before.Formats = @(13) }
            if ($case -ceq 'wait-foreign') { $after.UnicodeText = 'foreign value' }
            if ($case -ceq 'no-text-pattern') { $edit.Patterns.Clear() }
            if ($case -ceq 'wrong-selection') { $range.Text = 'partial' }
            [DarkReNamerVmAcceptanceNative]::Before = $before; [DarkReNamerVmAcceptanceNative]::After = $after
            [DarkReNamerVmAcceptanceNative]::Clears = 0
            [DarkReNamerVmAcceptanceNative]::ClearResult = if ($case -ceq 'cleanup-changed') { 'changed' } else { 'cleared' }
            $arguments = @{ Mode = $mode; Application = @{ process = $null }; Edit = $edit; ExpectedText = "first`n둘째"; SessionId = 1; WaitSeconds = 1; Label = 'copy fixture' }
            if ($case -ceq 'success') {
                $result = Copy-GuiRegressionDocument @arguments
                $expectedInput = if ($mode -ceq 'selection') { 'focus,chord:17/36/True,two:17/16/35/True,chord:17/67/False,wait' } else { 'chord:18/67/False,wait' }
                if (($calls -join ',') -cne $expectedInput -or -not $result.exact -or $result.cleanup -cne 'cleared' -or
                    $result.utf8_sha256 -cne (Get-LowerTextSha256 -Value "first`n둘째") -or $result.length_utf16 -ne 9) { throw "Full $mode copy result/input changed." }
            }
            else {
                $expected = switch -Wildcard ($case) {
                    'preflight-*' { 'requires an empty Clipboard' }
                    'wait-*' { 'injected copy observation failure' }
                    'cleanup-changed' { 'preserved a foreign or changed value' }
                    'focus-lost' { 'lost the exact read-only edit focus' }
                    'no-text-pattern' { 'no longer exposes TextPattern' }
                    'wrong-selection' { 'selection did not cover the exact document' }
                }
                Assert-Fails { Copy-GuiRegressionDocument @arguments } $expected
            }
            $expectedClears = if ($case -cin @('success', 'cleanup-changed', 'wait-owned')) { 1 } else { 0 }
            if ([DarkReNamerVmAcceptanceNative]::Clears -ne $expectedClears) { throw "Copy $case cleared an unowned Clipboard or leaked its owned value." }
            if ($case -like 'preflight-*' -and $calls.Count -ne 0) { throw 'Copy input preceded its empty Clipboard preflight.' }
            if ($expectedClears -eq 1 -and ([DarkReNamerVmAcceptanceNative]::ClearedSequence -ne 11 -or
                [DarkReNamerVmAcceptanceNative]::ClearedText -cne "first`r`n둘째")) { throw 'Copy cleanup lost its exact ownership guard.' }
            if ($case -cin @('focus-lost', 'no-text-pattern', 'wrong-selection') -and $calls -contains 'chord:17/67/False') { throw 'Unsafe selection reached Ctrl+C.' }
        }
    }
}

& {
    $ending = '파일 시스템 검사와 실행 확인은 변경 적용 시 별도로 수행합니다.'
    $window = [Windows.Automation.AutomationElement]::new()
    $edit = [Windows.Automation.AutomationElement]::new()
    $detailsFixture = @{ edit = $edit; text_pattern = 'text-provider'; evidence = @{ value_text = "document`n$ending" } }
    $probe = @{ inputs = [Collections.Generic.List[string]]::new(); visible = $ending }
    function Get-ObserverWindowTree { param($Window, $Process, $SessionId, $Label) @{ automation_id = '1004' } }
    function Save-WindowScreenshot { param($ForegroundObservations, $Window, $Process, $ExpectedSession, $Root, $Leaf, $Label) $Leaf }
    function Write-JsonUtf8Bom { param($Path, $Value) }
    function Get-ObserverReadOnlyDetails { param($Window, $Application, $SessionId, $WaitSeconds, $ExpectedText, $Label) $detailsFixture }
    function Copy-GuiRegressionDocument { param($Mode, $Application, $Edit, $ExpectedText, $SessionId, $WaitSeconds, $Label) @{ mode = $Mode } }
    function Send-AcceptanceChord { param($Process, $ExpectedSession, $Modifier, $VirtualKey, $Label, [switch]$ExtendedKey)
        if ($edit.FocusCalls -eq 0 -or $Modifier -ne 0x11 -or $VirtualKey -ne 0x23 -or -not $ExtendedKey) { throw 'Details end scrolling did not focus and send extended Ctrl+End.' }
        $probe.inputs.Add('ctrl-end')
    }
    function Get-ObserverVisibleText { param($TextPattern)
        if ($TextPattern -cne 'text-provider' -or $probe.inputs.Count -eq 0) { throw 'Details end observation preceded input.' }
        $probe.visible
    }
    function Start-Sleep { param($Milliseconds) }
    function Send-AcceptanceTap { param($Process, $ExpectedSession, $VirtualKey, $Label)
        if ($VirtualKey -ne 0x1B) { throw 'Unexpected diagnostic close input.' }
        $probe.inputs.Add('escape')
    }
    function Wait-WindowClosed { param($Handle, $TimeoutSeconds, $Label) $probe.inputs.Add('closed') }
    function Wait-AcceptanceMainWindowForeground { param($Application, $WaitSeconds, $Label) $probe.inputs.Add('main-foreground') }
    $captures = [Collections.Generic.List[object]]::new()
    $arguments = @{ Window = $window; Application = @{ process = $null }; SessionId = 1; WaitSeconds = 1;
        ExpectedText = $detailsFixture.evidence.value_text; OutputRoot = 'fixture'; Prefix = 'details'; CloseMethod = 'escape'; Captures = $captures }
    $result = Inspect-ObserverDiagnostic @arguments
    if (($probe.inputs -join ',') -cne 'ctrl-end,escape,closed,main-foreground' -or
        ($captures -join ',') -cne 'details-diagnostic.png,details-diagnostic-end.png' -or
        -not $result.native_end_scroll.ending_visible -or $result.native_end_scroll.visible_text -cne $ending -or
        $result.native_end_scroll.input -cne 'native-edit-ctrl-end') { throw 'Complete diagnostic observation lost its end-scroll evidence.' }
    $probe.inputs.Clear(); $probe.visible = 'partial content'; $captures.Clear()
    Assert-Fails { Inspect-ObserverDiagnostic @arguments } 'did not expose the canonical ending'
    if (($probe.inputs -join ',') -cne 'ctrl-end' -or ($captures -join ',') -cne 'details-diagnostic.png') { throw 'Failed details scrolling published a successful end capture or continued input.' }
}

& {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        foreach ($count in @(0, 32)) {
            $boundaryWindows = @(for ($index = 1; $index -le $count; $index++) {
                $row = [DarkReNamerVmAcceptanceNative+WindowMeasurement]::new()
                $row.Handle = $index; $row.ProcessId = $process.Id; $row
            })
            [DarkReNamerVmAcceptanceNative]::Windows = $boundaryWindows
            $boundary = Get-BoundedAcceptanceProcessWindowInventory -Process $process -ExpectedSession $process.SessionId
            if ($boundary.truncated -or $boundary.maximum_entries -ne 32 -or $boundary.total_count -ne $count -or
                $boundary.entries.Count -ne $count) { throw 'An untruncated process diagnostic inventory changed its boundary contract.' }
        }
        $windows = @(1..33 | ForEach-Object {
            $row = [DarkReNamerVmAcceptanceNative+WindowMeasurement]::new()
            $row.Handle = 34 - $_; $row.ProcessId = $process.Id; $row
        })
        [DarkReNamerVmAcceptanceNative]::Windows = $windows
        $inventory = Get-BoundedAcceptanceProcessWindowInventory -Process $process -ExpectedSession $process.SessionId
        if (-not $inventory.truncated -or $inventory.maximum_entries -ne 32 -or $inventory.total_count -ne 33 -or $inventory.entries.Count -ne 32 -or
            $inventory.entries[0].hwnd -ne 1 -or $inventory.entries[31].hwnd -ne 32) { throw 'Process diagnostics lost their sorted 32-window bound.' }
        $fields = @('hwnd', 'owner_hwnd', 'pid', 'session_id', 'window_class', 'visible', 'rect') | Sort-Object
        foreach ($entry in $inventory.entries) {
            if ((@($entry.Keys | Sort-Object) -join ',') -cne ($fields -join ',')) { throw 'Process diagnostics exposed an unexpected field.' }
        }
        $windows[32].ProcessId++
        Assert-Fails { Get-BoundedAcceptanceProcessWindowInventory -Process $process -ExpectedSession $process.SessionId } 'foreign process'
        Assert-Fails { Get-BoundedAcceptanceProcessWindowInventory -Process $process -ExpectedSession ($process.SessionId + 1) } 'unexpected desktop session'
    }
    finally { $process.Dispose() }
}

& {
    $events = [Collections.Generic.List[string]]::new()
    $process = [pscustomobject]@{ Id = 42; SessionId = 2 }
    $owned = [pscustomobject]@{ process = $process; owner = @{}; process_start_time_utc_ticks = '639000000000000201' }
    $window = [Windows.Automation.AutomationElement]::new()
    $startupFixture = @{ owned = $owned; process = $process; window = $window }
    function Get-LowerSha256 { param($Path) $events.Add("hash:$Path"); 'd' * 64 }
    function Start-OwnedProcess { param($FilePath, $Arguments, $WorkingDirectory)
        if ($FilePath -cne 'verified-app.exe' -or $WorkingDirectory -cne 'owned-root' -or $Arguments -cne '') { throw 'Startup lost its verified application arguments.' }
        $events.Add('start'); $startupFixture.owned
    }
    function Wait-ExactApplicationMainWindow { param($Process, $ExpectedSession, $ExpectedClassName, $ExpectedTitle, $TimeoutSeconds, $Label)
        if ($Process -ne $startupFixture.process -or $ExpectedSession -ne 2 -or $ExpectedClassName -cne 'DarkReNamerWindow' -or
            $ExpectedTitle -cne 'DarkReNamer' -or $TimeoutSeconds -ne 17) { throw 'Startup lost its exact window wait contract.' }
        $events.Add('wait'); @{ element = $startupFixture.window; handle = 5151L }
    }
    function Assert-AcceptanceForegroundBinding { param($Process, $ExpectedSession, $MainWindowHandle, [switch]$RequireMainWindow)
        if ($MainWindowHandle -ne 5151 -or -not $RequireMainWindow) { throw 'Startup foreground used an unpinned window.' }
        $events.Add('foreground')
    }
    $lifecycles = [Collections.Generic.List[object]]::new()
    $application = Start-AcceptanceApplication -FilePath 'verified-app.exe' -WorkingDirectory 'owned-root' -SessionId 2 -WaitSeconds 17 -Label 'startup fixture' -ProcessLifecycleObservations $lifecycles
    if (($events -join ',') -cne 'hash:verified-app.exe,start,wait,foreground' -or $application.main_handle -ne 5151 -or
        $application.main -ne $window -or $window.FocusCalls -ne 1 -or $lifecycles.Count -ne 1 -or
        $application.process_lifecycle.executable_path -cne 'verified-app.exe' -or $application.process_lifecycle.executable_sha256 -cne ('d' * 64)) { throw 'Successful startup lost its pinned window or source lifecycle.' }
}

# Import the real entry module: only its verified definition libraries are inert.
$entryProbeName = 'DrUiApplicationEntryProbe'
if (Test-Path "variable:global:$entryProbeName") { throw 'Entry fixture global state is occupied.' }
$global:DrUiApplicationEntryProbe = @{ events = [Collections.Generic.List[string]]::new(); reject = $false }
$entry = $null
try {
    $libraries = @{}
    foreach ($path in (Get-DrTestPowerShellModuleSpec -Kind ui).definitions) {
        $libraries['powershell-' + [IO.Path]::GetFileNameWithoutExtension($path)] = {}
    }
    $libraries['powershell-ui-bootstrap'] = {
        function Resolve-AcceptanceBootstrap { param($Root, $ScriptPath, $ScriptSha256)
            if ($Root -cne 'requested-root' -or $ScriptPath -cne 'entry.ps1' -or $ScriptSha256 -cne ('e' * 64)) { throw 'Entry bootstrap binding changed.' }
            $global:DrUiApplicationEntryProbe.events.Add('bootstrap'); @{ root = 'verified-root'; runner = 'verified-runner' }
        }
        function Resolve-VerifiedBundle { param($Root, $InvokedScriptPath)
            if ($Root -cne 'verified-root' -or $InvokedScriptPath -cne 'verified-runner') { throw 'Entry verified the wrong bundle.' }
            $global:DrUiApplicationEntryProbe.events.Add('verify')
            if ($global:DrUiApplicationEntryProbe.reject) { throw 'injected bundle rejection' }
        }
        function Invoke-GuiRegressionAcceptance { $global:DrUiApplicationEntryProbe.events.Add('regression') }
        function Invoke-DrCurrentDpiAcceptanceScenario { $global:DrUiApplicationEntryProbe.events.Add('current-dpi') }
    }
    $entry = Import-Module (Get-DrTestPowerShellModuleSpec -Kind ui).entry -ArgumentList $libraries -Force -PassThru
    $arguments = @{ BundleRoot = 'requested-root'; ExpectedSessionId = 2; OutputRoot = 'output'; ExpectedScriptSha256 = 'e' * 64; EntryPointPath = 'entry.ps1' }
    Invoke-DrWindowsVmAcceptance @arguments -RegressionMode standard -InputManifestPath 'input.json'
    if (($global:DrUiApplicationEntryProbe.events -join ',') -cne 'bootstrap,verify,regression') { throw 'Regression scenario preceded shared bundle authentication.' }
    $global:DrUiApplicationEntryProbe.events.Clear(); $global:DrUiApplicationEntryProbe.reject = $true
    Assert-Fails { Invoke-DrWindowsVmAcceptance @arguments -RegressionMode standard -InputManifestPath 'input.json' } 'injected bundle rejection'
    if (($global:DrUiApplicationEntryProbe.events -join ',') -cne 'bootstrap,verify') { throw 'Rejected bundle reached GUI dispatch.' }
    $global:DrUiApplicationEntryProbe.events.Clear()
    Assert-Fails { Invoke-DrWindowsVmAcceptance @arguments -RegressionMode standard } 'requires InputManifestPath'
    if (($global:DrUiApplicationEntryProbe.events -join ',') -cne 'bootstrap') { throw 'Incomplete regression request reached dispatch.' }
    $global:DrUiApplicationEntryProbe.events.Clear()
    Invoke-DrWindowsVmAcceptance @arguments
    if (($global:DrUiApplicationEntryProbe.events -join ',') -cne 'bootstrap,current-dpi') { throw 'Default current-DPI dispatch changed.' }
}
finally {
    if ($null -ne $entry) { Remove-Module $entry }
    Remove-Variable -Name $entryProbeName -Scope Global
}

& {
    $script:retainedCommandBindings = 0
    function Assert-AutomationBinding {
        param($Element, $Process, $ExpectedSession, $Label, [switch]$RequireWindowHandle)
        if (-not $RequireWindowHandle) { throw 'Retained command skipped native binding.' }
        $script:retainedCommandBindings++
    }
    $control = [Windows.Automation.AutomationElement]::new()
    $control.Current.AutomationId = '32781'
    $application = [pscustomobject]@{ process = [Diagnostics.Process]::GetCurrentProcess() }
    Assert-ObserverCommandButton -Control $control -Application $application -SessionId 1 -AutomationId '32781'
    $control.Current.IsEnabled = $false
    Assert-Fails -Expected 'identity or enabled state differs' -Action {
        Assert-ObserverCommandButton -Control $control -Application $application -SessionId 1 -AutomationId '32781'
    }
    $control.Current.IsEnabled = $true
    $control.Current.AutomationId = '32773'
    Assert-Fails -Expected 'identity or enabled state differs' -Action {
        Assert-ObserverCommandButton -Control $control -Application $application -SessionId 1 -AutomationId '32781'
    }
    if ($script:retainedCommandBindings -ne 3) { throw 'Retained commands bypassed repeated identity validation.' }
}
$performanceSamples = @(
    [ordered]@{ phase='empty-idle'; sample_gap_ms=[double]0; resource_collection_ms=[double]3.25 },
    [ordered]@{ phase='empty-idle'; sample_gap_ms=[double]201.75; resource_collection_ms=[double]4.5 },
    [ordered]@{ phase='post'; sample_gap_ms=[double]245.125; resource_collection_ms=[double]2.75 }
)
$phaseSummary = @(Get-ObserverPerformancePhaseSummary -Samples $performanceSamples `
    -PhaseOrder @('empty-idle','post','unobserved'))
if ($phaseSummary.Count -ne 3 -or
    $phaseSummary[0].phase -cne 'empty-idle' -or $phaseSummary[0].sample_count -ne 2 -or
    $phaseSummary[0].max_sample_gap_ms -ne 201.75 -or
    $phaseSummary[0].max_resource_collection_ms -ne 4.5 -or
    $phaseSummary[1].phase -cne 'post' -or $phaseSummary[1].sample_count -ne 1 -or
    $phaseSummary[1].max_sample_gap_ms -ne 245.125 -or
    $phaseSummary[1].max_resource_collection_ms -ne 2.75 -or
    $phaseSummary[2].phase -cne 'unobserved' -or $phaseSummary[2].sample_count -ne 0 -or
    $phaseSummary[2].max_sample_gap_ms -ne 0 -or
    $phaseSummary[2].max_resource_collection_ms -ne 0) {
    throw 'Performance phase summary did not preserve ordered sample counts and numeric maxima.'
}
Write-Host 'UI application behavior contracts passed.'
