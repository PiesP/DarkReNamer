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
        if ($_.Exception.ToString() -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure: $Expected"
}

$nativeSource = [IO.File]::ReadAllText((Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/ui-native.ps1'))
function Get-NativeFixtureMember {
    param([string] $Signature)
    $start = $nativeSource.IndexOf($Signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Native test member missing: $Signature" }
    $opening = $nativeSource.IndexOf('{', $start)
    $depth = 1
    $end = $opening + 1
    # These selected members contain no braces in strings or comments.
    while ($depth -gt 0 -and $end -lt $nativeSource.Length) {
        if ($nativeSource[$end] -eq '{') { $depth++ }
        elseif ($nativeSource[$end] -eq '}') { $depth-- }
        $end++
    }
    if ($depth -ne 0) { throw "Unbalanced native test member: $Signature" }
    $nativeSource.Substring($start, $end - $start)
}
$members = foreach ($signature in @(
    'public sealed class WindowMeasurement', 'public sealed class NativePopupMeasurement',
    'public struct Rect', 'private static void EnumerateWindowsChecked',
    'public static IntPtr FindVisiblePopupMenu', 'public static NativePopupMeasurement[] ReadVisibleNativeMenuPopups',
    'public static WindowMeasurement[] ReadProcessTopLevelWindows', 'public static void ReleaseModifiers'
)) { Get-NativeFixtureMember $signature }
$mock = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class DarkReNamerVmAcceptanceNative {
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);
    public static int WindowCount = 1, IncompleteAfter = -1;
    public static bool RectFailure, CallbackEscaped, TapFailure;
    public static ushort ReleaseFailure;
    public static List<ushort> Releases = new List<ushort>();
    public static object Snapshot;
    public static int SnapshotReads, ApplyCalls;
    private static bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter) {
        if (IncompleteAfter == 0) return false;
        for (int i = 1; i <= WindowCount; i++) {
            try { if (!callback(new IntPtr(i), parameter)) return false; }
            catch { CallbackEscaped = true; throw; }
            if (IncompleteAfter == i) return false;
        }
        return true;
    }
    private static bool IsWindowVisible(IntPtr window) { return true; }
    private static uint GetWindowThreadProcessId(IntPtr window, out uint processId) { processId = 42; return 1; }
    private static int GetClassName(IntPtr window, StringBuilder value, int capacity) { value.Append("#32768"); return 6; }
    private static bool GetWindowRect(IntPtr window, out Rect rect) { rect = new Rect { Right = 100, Bottom = 100 }; return !RectFailure; }
    private static string[] DescribeWindow(IntPtr window) { return new [] { "1", "0", "42", "fixture", "fixture", "true" }; }
    public static void KeyDown(ushort key) { }
    public static void KeyUp(ushort key) { Releases.Add(key); if (key == ReleaseFailure) throw new InvalidOperationException("release failure"); }
    public static void Tap(ushort key) { if (TapFailure) throw new InvalidOperationException("primary input failure"); }
    public static void TapExtended(ushort key) { Tap(key); }
    public static object GetHighContrastSnapshot() { SnapshotReads++; return Snapshot; }
    public static void ApplyHighContrast(uint flags, string scheme) { ApplyCalls++; throw new InvalidOperationException("unexpected desktop mutation"); }
'@ + ($members -join "`n") + @'
}
public static class DarkReNamerVmNative {
    public static string GetFileIdentity(string path) { return path; }
    public static IntPtr FocusRoot = new IntPtr(10), Foreground = new IntPtr(10), LostWindow;
    public static IntPtr GetAncestor(IntPtr window, uint flags) { return FocusRoot; }
    public static IntPtr GetForegroundWindow() { return Foreground; }
    public static bool IsWindow(IntPtr window) { return window != IntPtr.Zero && window != LostWindow; }
}
'@
Add-Type -TypeDefinition $mock

foreach ($reader in @(
    { [DarkReNamerVmAcceptanceNative]::FindVisiblePopupMenu(42) },
    { [DarkReNamerVmAcceptanceNative]::ReadVisibleNativeMenuPopups(42) },
    { [DarkReNamerVmAcceptanceNative]::ReadProcessTopLevelWindows(42) }
)) {
    foreach ($stop in @(0, 1)) {
        [DarkReNamerVmAcceptanceNative]::IncompleteAfter = $stop
        Assert-Fails $reader 'enumeration did not complete'
    }
    [DarkReNamerVmAcceptanceNative]::IncompleteAfter = -1
    if (@(& $reader).Count -ne 1) { throw 'Complete native observation lost its one row.' }
}
foreach ($case in @(
    @{ count = 3; read = { [DarkReNamerVmAcceptanceNative]::ReadVisibleNativeMenuPopups(42) } },
    @{ count = 129; read = { [DarkReNamerVmAcceptanceNative]::ReadProcessTopLevelWindows(42) } }
)) {
    [DarkReNamerVmAcceptanceNative]::WindowCount = $case.count
    Assert-Fails $case.read 'exceeded its bound'
}
[DarkReNamerVmAcceptanceNative]::WindowCount = 1
[DarkReNamerVmAcceptanceNative]::RectFailure = $true
Assert-Fails { [DarkReNamerVmAcceptanceNative]::ReadVisibleNativeMenuPopups(42) } 'enumeration failed'
Assert-Fails { [DarkReNamerVmAcceptanceNative]::ReadProcessTopLevelWindows(42) } 'enumeration failed'
if ([DarkReNamerVmAcceptanceNative]::CallbackEscaped) { throw 'An exception escaped the native callback boundary.' }

[DarkReNamerVmAcceptanceNative]::ReleaseFailure = 0x10
Assert-Fails { [DarkReNamerVmAcceptanceNative]::ReleaseModifiers() } 'release failure'
if (([DarkReNamerVmAcceptanceNative]::Releases -join ',') -cne '16,17,18') {
    throw 'Native modifier cleanup stopped at its first failure.'
}
& {
    function Get-FocusedAcceptanceElement { param($Process, $ExpectedSession, $Label) }
    [DarkReNamerVmAcceptanceNative]::Releases.Clear()
    [DarkReNamerVmAcceptanceNative]::TapFailure = $true
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        Assert-Fails {
            Send-AcceptanceTwoModifierChord -Process $process -ExpectedSession 1 `
                -Modifier 0x11 -SecondModifier 0x10 -VirtualKey 0x41 -Label 'fixture'
        } 'primary input failure*release failure'
        if (([DarkReNamerVmAcceptanceNative]::Releases -join ',') -cne '16,17') {
            throw 'Chord cleanup skipped an owned modifier after the other release failed.'
        }
    }
    finally { $process.Dispose() }
}

& {
    function New-FocusFixture {
        $process = [pscustomobject]@{ Id = 42; SessionId = 2; HasExited = $false }
        $process | Add-Member ScriptMethod Refresh {}
        $edit = [pscustomobject]@{
            Current = [pscustomobject]@{
                ProcessId = 42; NativeWindowHandle = 101; AutomationId = '1004'; ClassName = 'Edit'
                ControlType = [pscustomobject]@{ ProgrammaticName = 'ControlType.Edit' }
                IsEnabled = $true; IsOffscreen = $false
            }
            focus_calls = 0
        }
        $edit | Add-Member ScriptMethod SetFocus { $this.focus_calls++ }
        [pscustomobject]@{
            application = [pscustomobject]@{ process = $process }; edit = $edit
            reads = [Collections.Generic.List[long]]::new(); inputs = [Collections.Generic.List[string]]::new()
            mode = 'delayed'; last_hwnd = 0
        }
    }
    function Assert-AutomationBinding {
        param($Element, $Process, $ExpectedSession, $Label, [switch] $RequireWindowHandle)
        if ($Element.Current.ProcessId -ne $Process.Id -or $Process.SessionId -ne $ExpectedSession) {
            throw 'Unexpected process or desktop session.'
        }
        if ($RequireWindowHandle -and -not [DarkReNamerVmNative]::IsWindow([IntPtr]$Element.Current.NativeWindowHandle)) {
            throw 'The bound edit is no longer one live native control.'
        }
    }
    function Get-FocusedAcceptanceElement {
        param($Process, $ExpectedSession, $Label)
        if ($fixture.inputs.Count -ne 0) { throw 'Keyboard input preceded settled edit focus.' }
        $hwnd = if ($fixture.mode -ceq 'delayed' -and $fixture.reads.Count -eq 0) { 202 } `
            elseif ($fixture.mode -ceq 'persistent') { 202 } else { 101 }
        $current = [pscustomobject]@{
            ProcessId = 42; NativeWindowHandle = $hwnd
            AutomationId = if ($hwnd -eq 101) { '1004' } else { '2' }
            ClassName = if ($hwnd -eq 101) { 'Edit' } else { 'Button' }
            ControlType = [pscustomobject]@{ ProgrammaticName = if ($hwnd -eq 101) { 'ControlType.Edit' } else { 'ControlType.Button' } }
        }
        switch ($fixture.mode) {
            'foreign-pid' { $current.ProcessId = 99 }
            'foreign-session' { $fixture.application.process.SessionId = 3 }
            'lost' { [DarkReNamerVmNative]::LostWindow = [IntPtr]101 }
            'rebound' { $fixture.edit.Current.NativeWindowHandle = 99 }
            'wrong-root' { [DarkReNamerVmNative]::FocusRoot = [IntPtr]99 }
            'foreground' { [DarkReNamerVmNative]::Foreground = [IntPtr]99 }
            'disabled' { $fixture.edit.Current.IsEnabled = $false }
            'hidden' { $fixture.edit.Current.IsOffscreen = $true }
            'persistent' {
                $current | Add-Member ScriptProperty ClassName { throw 'metadata read exploded' } -Force
            }
        }
        $fixture.last_hwnd = $hwnd
        $fixture.reads.Add($hwnd)
        [pscustomobject]@{ Current = $current }
    }
    function Send-AcceptanceChord {
        param($Process, $ExpectedSession, $Modifier, $VirtualKey, $Label, [switch] $ExtendedKey)
        if ($fixture.last_hwnd -ne 101) { throw 'Keyboard input preceded exact Edit HWND equality.' }
        $fixture.inputs.Add($Label)
    }
    function Send-AcceptanceTwoModifierChord {
        param($Process, $ExpectedSession, $Modifier, $SecondModifier, $VirtualKey, $Label, [switch] $ExtendedKey)
        if ($fixture.last_hwnd -ne 101) { throw 'Keyboard input preceded exact Edit HWND equality.' }
        $fixture.inputs.Add($Label)
    }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/ui-application.ps1'),
        [ref]$tokens, [ref]$parseErrors
    )
    $copy = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Copy-GuiRegressionDocument'
    }, $true)
    $selection = $copy.Body.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -ceq "`$Mode -ceq 'selection'"
    }, $true)
    # Execute the production selection prefix through the first two keyboard
    # inputs, before the platform TextPattern/Clipboard APIs begin.
    $prefix = [Collections.Generic.List[string]]::new()
    foreach ($statement in $selection.Clauses[0].Item2.Statements) {
        if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and
            $statement.Left.Extent.Text -ceq '$textObject') { break }
        $prefix.Add($statement.Extent.Text)
    }
    $fixture = New-FocusFixture
    $Application = $fixture.application; $Edit = $fixture.edit; $SessionId = 2; $WaitSeconds = 3; $Label = 'focus regression'
    & ([scriptblock]::Create([string]::Join("`n", $prefix)))
    if ($fixture.edit.focus_calls -ne 1 -or ($fixture.reads -join ',') -cne '202,101' -or $fixture.inputs.Count -ne 2) {
        throw 'Delayed same-process focus did not settle once before the real selection input prefix.'
    }

    $fixture = New-FocusFixture; $fixture.mode = 'persistent'
    try {
        Set-ObserverExactEditFocus -Application $fixture.application -Edit $fixture.edit `
            -SessionId 2 -Label 'persistent focus' -TimeoutMilliseconds 500
        throw 'Persistent focus mismatch did not time out.'
    }
    catch {
        foreach ($expected in @('did not focus the exact', 'expected_hwnd=101', 'actual_hwnd=202', 'actual_id=2', 'expected_type=ControlType.Edit', 'foreground_hwnd=10', 'actual_class=<unavailable:')) {
            if ($_.Exception.Message -notlike "*$expected*") { throw "Missing focus timeout diagnostic $expected : $($_.Exception.Message)" }
        }
        if ($_.Exception.Message.Contains('metadata read exploded')) { throw 'A diagnostic error replaced the focus timeout.' }
    }
    if ($fixture.edit.focus_calls -ne 1 -or $fixture.inputs.Count -ne 0) { throw 'A persistent mismatch retried focus or sent input.' }

    foreach ($mode in @('foreign-pid', 'foreign-session', 'lost', 'rebound', 'wrong-root', 'foreground', 'disabled', 'hidden')) {
        $fixture = New-FocusFixture; $fixture.mode = $mode
        Assert-Fails {
            Set-ObserverExactEditFocus -Application $fixture.application -Edit $fixture.edit `
                -SessionId 2 -Label $mode -TimeoutMilliseconds 500
        } $(if ($mode -like 'foreign-*') { 'expected application and desktop session' } elseif ($mode -ceq 'lost') { 'live native control' } else { 'lost or changed' })
        if ($fixture.reads.Count -ne 1 -or $fixture.edit.focus_calls -ne 1 -or $fixture.inputs.Count -ne 0) {
            throw "Unsafe $mode focus was retried or allowed keyboard input."
        }
        [DarkReNamerVmNative]::FocusRoot = [IntPtr]10
        [DarkReNamerVmNative]::Foreground = [IntPtr]10
        [DarkReNamerVmNative]::LostWindow = [IntPtr]::Zero
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-ui-observation-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $root
    & {
        $expected = [pscustomobject]@{
            Flags = 0; Scheme = ''; ThemePath = ''; ThemeColor = ''; ThemeSize = ''
            Window = 1; WindowText = 2; ButtonFace = 3; ButtonText = 4
            Highlight = 5; HighlightText = 6; GrayText = 7; HotLight = 8
        }
        $snapshotPath = Join-Path $root 'high-contrast-restore.json'
        [IO.File]::WriteAllText($snapshotPath, 'fixture snapshot')
        function Resolve-HighContrastRestoreDocument {
            param($OutputDirectory, $SourceSha, $ScriptSha256)
            [pscustomobject]@{
                path = $snapshotPath; expected = $expected
                document = [pscustomobject]@{ restoration_required = $false; restoration_verified = $true }
            }
        }
        function Initialize-TrustedResultWriter { param($Root, $ResultRoot, $Path) }
        function Initialize-AcceptanceNative { }
        function Enter-DesktopTestLock { param($SessionId); [pscustomobject]@{} }
        function Exit-DesktopTestLock { param($Lock) }
        function Write-ResultDocument { param($Root, $Path, $Result); $script:rescueReceipt = $Result }
        $verified = [pscustomobject]@{ output_root = $root; root = $root; source_sha = 'a' * 40; script_sha256 = 'b' * 64 }
        [DarkReNamerVmAcceptanceNative]::Snapshot = $expected.PSObject.Copy()
        Invoke-HighContrastRescue -Verified $verified -SessionId 1
        if ($script:rescueReceipt.status -cne 'passed' -or [DarkReNamerVmAcceptanceNative]::SnapshotReads -ne 1) {
            throw 'Already-restored High Contrast must be observed before it passes.'
        }
        [DarkReNamerVmAcceptanceNative]::Snapshot.Window = 99
        Assert-Fails { Invoke-HighContrastRescue -Verified $verified -SessionId 1 } 'High Contrast rescue failed'
        if ($script:rescueReceipt.status -cne 'failed' -or [DarkReNamerVmAcceptanceNative]::SnapshotReads -ne 2 -or
            [DarkReNamerVmAcceptanceNative]::ApplyCalls -ne 0 -or [DarkReNamerVmAcceptanceNative]::Snapshot.Window -ne 99) {
            throw 'Later desktop changes must remain preserved and cannot inherit a historical restoration pass.'
        }
    }
    $fixture = Join-Path $root 'normal'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'parent')
    $file = Join-Path $fixture 'parent/a.txt'
    [IO.File]::WriteAllText($file, 'fixture')
    $rows = @(Get-ObserverFixtureState -FixtureRoot $fixture)
    if ($rows.Count -ne 1 -or $rows[0].path -cne $file -or $rows[0].name -cne 'a.txt' -or
        $rows[0].identity -cne $file -or $rows[0].content_sha256 -cne (Get-LowerSha256 -Path $file)) {
        throw 'Bounded UI fixture observation changed its existing file evidence shape.'
    }
    $before = Get-Item -LiteralPath $file
    [void]$before.Length
    [IO.File]::AppendAllText($file, 'growth')
    Assert-Fails { Get-ObserverFixtureFileHash -File $before } 'grew during observation'
    $before = Get-Item -LiteralPath $file
    [void]$before.Length
    [IO.File]::WriteAllText($file, '')
    Assert-Fails { Get-ObserverFixtureFileHash -File $before } 'shrank during observation'

    & {
        function Get-ObserverFixtureFileHash { param($File); throw 'hashing must not begin for an invalid inventory' }
        $many = Join-Path $root 'many'
        $null = New-Item -ItemType Directory -Path $many
        foreach ($index in 0..16) { [IO.File]::WriteAllText((Join-Path $many "$index.txt"), '') }
        Assert-Fails { Get-ObserverFixtureState -FixtureRoot $many } 'exceeds sixteen entries'
        $deep = Join-Path $root 'deep'
        $null = New-Item -ItemType Directory -Path (Join-Path $deep 'a/b/c/d')
        Assert-Fails { Get-ObserverFixtureState -FixtureRoot $deep } 'exceeds depth three'
        $large = Join-Path $root 'large'
        $null = New-Item -ItemType Directory -Path $large
        $stream = [IO.File]::Create((Join-Path $large 'large.bin'))
        try { $stream.SetLength(64MB + 1) } finally { $stream.Dispose() }
        Assert-Fails { Get-ObserverFixtureState -FixtureRoot $large } 'oversized file'
        $stream = [IO.File]::OpenWrite((Join-Path $large 'large.bin'))
        try { $stream.SetLength(64MB) } finally { $stream.Dispose() }
        foreach ($index in 1..8) {
            $stream = [IO.File]::Create((Join-Path $large "$index.bin"))
            try { $stream.SetLength(64MB) } finally { $stream.Dispose() }
        }
        Assert-Fails { Get-ObserverFixtureState -FixtureRoot $large } 'aggregate size bound'
    }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-Host 'UI observation contracts passed.'
