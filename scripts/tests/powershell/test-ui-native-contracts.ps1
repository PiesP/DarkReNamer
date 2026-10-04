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
function Assert-Equal {
    param($Actual, $Expected, [string] $Label)
    if ($Actual -cne $Expected) { throw "$Label expected <$Expected>, observed <$Actual>." }
}

$nativeSource = [IO.File]::ReadAllText((Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/ui-native.ps1'))
function Get-NativeFixtureMember {
    param([string] $Signature)
    $start = $nativeSource.IndexOf($Signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Native test member missing: $Signature" }
    $opening = $nativeSource.IndexOf('{', $start)
    # Include the exact production StructLayout attribute where present.
    $lineStart = $nativeSource.LastIndexOf("`n", $start) + 1
    if ($lineStart -gt 0) {
        $previousStart = $nativeSource.LastIndexOf("`n", $lineStart - 2) + 1
        if ($nativeSource.Substring($previousStart, $lineStart - $previousStart).Trim().StartsWith('[StructLayout(')) {
            $start = $previousStart
        }
    }
    $depth = 1; $end = $opening + 1
    # Selected production members contain no braces in strings or comments.
    while ($depth -gt 0 -and $end -lt $nativeSource.Length) {
        if ($nativeSource[$end] -eq '{') { $depth++ }
        elseif ($nativeSource[$end] -eq '}') { $depth-- }
        $end++
    }
    if ($depth -ne 0) { throw "Unbalanced native test member: $Signature" }
    $nativeSource.Substring($start, $end - $start)
}
$members = foreach ($signature in @(
    'public sealed class HighContrastSnapshot', 'public sealed class ClipboardSnapshot',
    'private struct NativeScrollInfo', 'private struct HIGHCONTRAST',
    'private struct KEYBDINPUT', 'private struct MOUSEINPUT', 'private struct INPUTUNION {', 'private struct INPUT {',
    'private static uint[] EnumerateClipboardFormats', 'private static string ReadClipboardUnicodeText',
    'private static ClipboardSnapshot ReadOpenClipboardSnapshot', 'public static ClipboardSnapshot ReadClipboardSnapshot',
    'private static bool RequiresEmptyClipboardInitialization', 'public static ClipboardSnapshot ReadOrInitializeEmptyClipboardSnapshot',
    'public static string ClearClipboardIfOwned', 'private static void Send(',
    'public static void KeyDown(', 'public static void KeyUp(', 'public static void Tap(',
    'public static void TapExtended(', 'public static int[] TryReadScrollInfo(',
    'public static HighContrastSnapshot GetHighContrastSnapshot('
)) { Get-NativeFixtureMember $signature }
# Keep the production resource policy and retained storage, rather than a replica
# counter. Reflection below observes their state after executing the real body.
$fields = [regex]::Matches($nativeSource,
    '(?m)^    private (?:const int MaxHighContrastReads|static int highContrastReads|static readonly IntPtr\[\] retainedSchemePointers)[^\r\n]+') |
    ForEach-Object { $_.Value }
$nativeFixture = @'
// Unassigned mouse-union fields are retained only for the production ABI.
#pragma warning disable 0649
using System;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class DarkReNamerVmAcceptanceNative {
    public static List<string> Calls = new List<string>();
    public static string Failure = "";
    public static int FailInputCall, FailInputCall2, InputCalls;
    public static List<string> Inputs = new List<string>();
    public static bool ScrollFailure;
    public static int ScrollPosition = 17;
    private static bool GetScrollInfo(IntPtr window, int bar, ref NativeScrollInfo info) {
        Calls.Add("scroll:" + window + ":" + bar + ":" + info.Size + ":" + info.Mask);
        info.Minimum = -3; info.Maximum = 99; info.Page = 8;
        info.Position = ScrollPosition; info.TrackPosition = 19;
        return !ScrollFailure;
    }
    private static uint SendInput(uint count, INPUT[] inputs, int size) {
        InputCalls++;
        if (count != 1 || inputs.Length != 1 || size != Marshal.SizeOf(typeof(INPUT)) || inputs[0].type != 1)
            throw new InvalidOperationException("invalid input ABI");
        KEYBDINPUT key = inputs[0].value.keyboard;
        if (key.scanCode != 0 || key.time != 0 || key.extraInfo != UIntPtr.Zero)
            throw new InvalidOperationException("invalid keyboard payload");
        Inputs.Add(key.virtualKey + ":" + key.flags);
        if (InputCalls == FailInputCall || InputCalls == FailInputCall2) { Marshal.SetLastPInvokeError(5); return 0; }
        return 1;
    }
    public static uint Sequence;
    public static uint[] Formats = new uint[0];
    public static string Text;
    public static bool Held;
    public static int SequenceReads;
    public static bool ChangeSequenceDuringRead, LeaveDataAfterEmpty, ZeroAfterEmpty, ForeignAfterEmpty;
    private static IntPtr clipboardMemory;
    public static uint? MemoryBytes;
    public static void ResetClipboard(uint sequence, string text, uint[] formats) {
        ReleaseMemory(); Sequence = sequence; Text = text; Formats = formats; Calls.Clear();
        Failure = ""; Held = false; SequenceReads = 0; MemoryBytes = null; ChangeSequenceDuringRead = false;
        LeaveDataAfterEmpty = false; ZeroAfterEmpty = false; ForeignAfterEmpty = false;
        if (text != null) clipboardMemory = Marshal.StringToHGlobalUni(text);
    }
    public static void ReleaseMemory() {
        if (clipboardMemory != IntPtr.Zero) Marshal.FreeHGlobal(clipboardMemory);
        clipboardMemory = IntPtr.Zero;
    }
    private static void RequireHeld() { if (!Held) throw new InvalidOperationException("operation outside Clipboard lock"); }
    private static bool OpenClipboard(IntPtr owner) {
        Calls.Add("open");
        if (owner != IntPtr.Zero || Held) throw new InvalidOperationException("invalid Clipboard open");
        if (Failure == "open") { Marshal.SetLastPInvokeError(5); return false; }
        Held = true; return true;
    }
    private static bool CloseClipboard() {
        RequireHeld(); Calls.Add("close"); Held = false;
        if (Failure == "close") { Marshal.SetLastPInvokeError(5); return false; }
        return true;
    }
    public static uint GetClipboardSequenceNumber() {
        RequireHeld(); Calls.Add("sequence"); SequenceReads++;
        return ChangeSequenceDuringRead && SequenceReads == 2 ? Sequence + 1 : Sequence;
    }
    private static void SetLastErrorNative(uint code) { Marshal.SetLastPInvokeError((int)code); }
    private static uint EnumClipboardFormats(uint previous) {
        RequireHeld(); Calls.Add("formats:" + previous);
        if (Failure == "enumerate") { Marshal.SetLastPInvokeError(5); return 0; }
        int next = previous == 0 ? 0 : Array.IndexOf(Formats, previous) + 1;
        Marshal.SetLastPInvokeError(0);
        return next < Formats.Length ? Formats[next] : 0;
    }
    private static IntPtr GetClipboardData(uint format) {
        RequireHeld(); Calls.Add("data:" + format);
        if (Failure == "data") { Marshal.SetLastPInvokeError(5); return IntPtr.Zero; }
        return clipboardMemory;
    }
    private static UIntPtr GlobalSize(IntPtr memory) {
        RequireHeld(); Calls.Add("size");
        return new UIntPtr(MemoryBytes.HasValue ? MemoryBytes.Value : (uint)(Text.Length + 1) * 2);
    }
    private static IntPtr GlobalLock(IntPtr memory) {
        RequireHeld(); Calls.Add("lock");
        if (Failure == "lock") { Marshal.SetLastPInvokeError(5); return IntPtr.Zero; }
        return memory;
    }
    private static bool GlobalUnlock(IntPtr memory) { RequireHeld(); Calls.Add("unlock"); return true; }
    private static bool EmptyClipboard() {
        RequireHeld(); Calls.Add("empty");
        if (Failure == "empty") { Marshal.SetLastPInvokeError(5); return false; }
        Sequence = ZeroAfterEmpty ? 0 : Sequence + 1;
        if (!LeaveDataAfterEmpty) { Formats = new uint[0]; Text = null; }
        if (ForeignAfterEmpty) Formats = new uint[] { 49152 };
        return true;
    }
    public static IntPtr SchemePointer;
    public static int SpiCalls;
    public static string ThemeMode = "valid";
    private static bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags) {
        Calls.Add("spi"); SpiCalls++;
        if (action != 0x42 || parameter != Marshal.SizeOf(typeof(HIGHCONTRAST)) || flags != 0)
            throw new InvalidOperationException("invalid High Contrast ABI");
        if (Failure == "spi") { Marshal.SetLastPInvokeError(5); return false; }
        value.flags = 1; value.scheme = SchemePointer; return true;
    }
    private static int GetCurrentThemeName(StringBuilder path, int pathCapacity, StringBuilder color, int colorCapacity,
        StringBuilder size, int sizeCapacity) {
        Calls.Add("theme");
        if (ThemeMode == "error") return unchecked((int)0x80004005);
        path.Append(ThemeMode == "relative" ? "relative.theme" :
            ThemeMode == "path-bound" ? new string('x', pathCapacity - 1) :
            System.IO.Path.Combine(System.IO.Path.GetTempPath(), "fixture.theme"));
        if (ThemeMode != "empty") color.Append(ThemeMode == "color-bound" ? new string('x', colorCapacity - 1) : "NormalColor");
        size.Append(ThemeMode == "size-bound" ? new string('x', sizeCapacity - 1) : "NormalSize");
        return 0;
    }
    private static uint GetSysColor(int index) { Calls.Add("color:" + index); return (uint)index; }
    public static uint Dpi = 96;
    public static bool ChangeDpi, ResizeFailure, ResizeNeverSettles;
    public static int DpiReads, ResizeCalls, RequestedWidth, RequestedHeight;
    public static uint GetDpiForWindow(IntPtr window) {
        Calls.Add("dpi:" + window); DpiReads++;
        return ChangeDpi && DpiReads > 1 ? Dpi + 1 : Dpi;
    }
    public static bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags) {
        Calls.Add("resize:" + window); ResizeCalls++; RequestedWidth = width; RequestedHeight = height;
        if (window != new IntPtr(101) || after != IntPtr.Zero || x != 0 || y != 0 || flags != 0x16)
            throw new InvalidOperationException("unexpected resize target or flags");
        if (!ResizeNeverSettles) { DarkReNamerVmNative.Width = width; DarkReNamerVmNative.Height = height; }
        return !ResizeFailure;
    }
'@ + ($fields -join "`n") + "`n" + ($members -join "`n") + @'
}
public static class DarkReNamerVmNative {
    public struct Rect { public int Left, Top, Right, Bottom; }
    public static int Width = 594, Height = 508, Reads, FailRead;
    public static bool GetWindowRect(IntPtr window, out Rect rect) {
        DarkReNamerVmAcceptanceNative.Calls.Add("rect:" + window); Reads++;
        if (window != new IntPtr(101)) throw new InvalidOperationException("foreign rectangle target");
        rect = new Rect { Left = 20, Top = 30, Right = 20 + Width, Bottom = 30 + Height };
        return Reads != FailRead;
    }
}
namespace Windows.Automation {
    public class AutomationElement {
        public class Information { public int NativeWindowHandle = 101; }
        public Information Current = new Information();
    }
}
'@
Add-Type -TypeDefinition $nativeFixture

$scroll = [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo([IntPtr]101, 2)
Assert-Equal ($scroll -join ',') '-3,99,8,17,19' 'SCROLLINFO projection'
Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') 'scroll:101:2:28:23' 'SCROLLINFO request'
[DarkReNamerVmAcceptanceNative]::ScrollFailure = $true
if ($null -ne [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo([IntPtr]101, 2)) { throw 'Failed scroll observation manufactured a projection.' }

# Real native Clipboard bodies run under one inert Open/Close lock. Fixture
# allocations belong to the test, never the desktop or the OS Clipboard.
try {
    [DarkReNamerVmAcceptanceNative]::ResetClipboard(42, 'owned', [uint32[]]@(1,7,13,16))
    $read = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
    Assert-Equal $read.SequenceNumber 42 'Clipboard observed sequence'
    Assert-Equal $read.UnicodeText 'owned' 'Clipboard Unicode text'
    Assert-Equal ($read.Formats -join ',') '1,7,13,16' 'Clipboard observed formats'
    Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') `
        'open,sequence,formats:0,formats:1,formats:7,formats:13,formats:16,data:13,size,lock,unlock,sequence,close' 'Complete native snapshot calls'
    foreach ($count in @(64,65)) {
        [DarkReNamerVmAcceptanceNative]::ResetClipboard(42, $null, [uint32[]]@(101..(100 + $count)))
        if ($count -eq 64) {
            Assert-Equal ([DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot().Formats.Length) 64 'Clipboard format boundary'
        } else { Assert-Fails { [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot() } 'format count exceeded' }
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Held) $false 'Format-bound observation lock release'
    }
    foreach ($byteCount in @([uint32]0,[uint32]1,[uint32]3,[uint32]2097154)) {
        [DarkReNamerVmAcceptanceNative]::ResetClipboard(42, 'owned', [uint32[]]@(13))
        [DarkReNamerVmAcceptanceNative]::MemoryBytes = $byteCount
        Assert-Fails { [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot() } 'invalid or over limit'
        if ([DarkReNamerVmAcceptanceNative]::Calls.Contains('lock')) { throw 'Invalid Unicode allocation was locked before its bounds were checked.' }
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Held) $false 'Allocation-bound observation lock release'
    }
    [DarkReNamerVmAcceptanceNative]::ResetClipboard(42, 'owned', [uint32[]]@(13))
    [DarkReNamerVmAcceptanceNative]::MemoryBytes = 10
    Assert-Fails { [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot() } 'not terminated'
    Assert-Equal (@([DarkReNamerVmAcceptanceNative]::Calls | Select-Object -Last 2) -join ',') 'unlock,close' 'Invalid Unicode unlock and close'
    foreach ($sequence in @([uint32]0, [uint32]42)) {
        [DarkReNamerVmAcceptanceNative]::ResetClipboard($sequence, $null, [uint32[]]@())
        $snapshot = [DarkReNamerVmAcceptanceNative]::ReadOrInitializeEmptyClipboardSnapshot()
        Assert-Equal $snapshot.SequenceNumber $(if ($sequence -eq 0) { 1 } else { 42 }) 'Empty baseline sequence'
        Assert-Equal $snapshot.Formats.Length 0 'Empty baseline formats'
        if ($null -ne $snapshot.UnicodeText) { throw 'Empty baseline acquired text.' }
        $expected = if ($sequence -eq 0) { 'open,sequence,formats:0,sequence,empty,sequence,formats:0,sequence,close' } `
            else { 'open,sequence,formats:0,sequence,close' }
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') $expected 'Atomic baseline calls'
    }
    foreach ($formats in @([uint32[]]@(13), [uint32[]]@(49152))) {
        [DarkReNamerVmAcceptanceNative]::ResetClipboard(0, 'foreign', $formats)
        Assert-Fails { [DarkReNamerVmAcceptanceNative]::ReadOrInitializeEmptyClipboardSnapshot() } 'initially empty Clipboard'
        if ([DarkReNamerVmAcceptanceNative]::Calls.Contains('empty')) { throw 'Clipboard preflight cleared foreign state.' }
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls[0]) 'open' 'Foreign-state open'
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls[([DarkReNamerVmAcceptanceNative]::Calls.Count - 1)]) 'close' 'Foreign-state close'
    }
    foreach ($failure in @('open', 'enumerate', 'empty', 'close')) {
        [DarkReNamerVmAcceptanceNative]::ResetClipboard(0, $null, [uint32[]]@())
        [DarkReNamerVmAcceptanceNative]::Failure = $failure
        Assert-Fails { [DarkReNamerVmAcceptanceNative]::ReadOrInitializeEmptyClipboardSnapshot() } 'Win32Exception'
        $expected = switch ($failure) {
            'open' { 'open' }
            'enumerate' { 'open,sequence,formats:0,close' }
            'empty' { 'open,sequence,formats:0,sequence,empty,close' }
            'close' { 'open,sequence,formats:0,sequence,empty,sequence,formats:0,sequence,close' }
        }
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') $expected "$failure failure calls"
        if ([DarkReNamerVmAcceptanceNative]::Held) { throw 'Clipboard fixture retained the lock after failure.' }
    }
    foreach ($failure in @('ChangeSequenceDuringRead', 'ZeroAfterEmpty', 'ForeignAfterEmpty')) {
        [DarkReNamerVmAcceptanceNative]::ResetClipboard(0, $null, [uint32[]]@())
        [DarkReNamerVmAcceptanceNative]::$failure = $true
        Assert-Fails { [DarkReNamerVmAcceptanceNative]::ReadOrInitializeEmptyClipboardSnapshot() } `
            $(if ($failure -ceq 'ChangeSequenceDuringRead') { 'changed during one acceptance observation' } else { 'nonzero empty baseline' })
        if ([DarkReNamerVmAcceptanceNative]::Held) { throw 'Failed Clipboard reread retained a lock.' }
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls.Contains('empty')) ($failure -cne 'ChangeSequenceDuringRead') 'Reread failure mutation guard'
    }
    foreach ($case in @(
        @{ sequence = 41; text = 'owned'; formats = [uint32[]]@(13); expected = 'sequence_changed' },
        @{ sequence = 42; text = 'foreign'; formats = [uint32[]]@(13); expected = 'text_changed' },
        @{ sequence = 42; text = 'owned'; formats = [uint32[]]@(13,49152); expected = 'foreign_format' },
        @{ sequence = 42; text = $null; formats = [uint32[]]@(); expected = 'text_format_missing' },
        @{ sequence = 42; text = 'owned'; formats = [uint32[]]@(1,7,13,16); expected = 'cleared' }
    )) {
        [DarkReNamerVmAcceptanceNative]::ResetClipboard($case.sequence, $case.text, $case.formats)
        $expectedText = if ($case.expected -ceq 'text_format_missing') { $null } else { 'owned' }
        $cleanupResult = if ($case.expected -ceq 'text_format_missing') {
            # Reflection preserves a C# null instead of PowerShell's null-to-empty
            # string conversion, so the real missing-format guard is reachable.
            [DarkReNamerVmAcceptanceNative].GetMethod('ClearClipboardIfOwned').Invoke($null, [object[]]@([uint32]42, $null))
        } else { [DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned(42, $expectedText) }
        Assert-Equal $cleanupResult $case.expected 'Guarded cleanup result'
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls.Contains('empty')) ($case.expected -ceq 'cleared') 'Guarded cleanup authorization'
        if ($case.expected -ceq 'cleared') {
            Assert-Equal (@([DarkReNamerVmAcceptanceNative]::Calls | Select-Object -Last 3) -join ',') 'empty,formats:0,close' 'Cleanup empty verification'
        }
        if ([DarkReNamerVmAcceptanceNative]::Held) { throw 'Guarded cleanup retained a lock.' }
    }
    foreach ($failure in @('open','enumerate','data','lock','empty','close')) {
        [DarkReNamerVmAcceptanceNative]::ResetClipboard(42, 'owned', [uint32[]]@(13))
        [DarkReNamerVmAcceptanceNative]::Failure = $failure
        Assert-Fails { [DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned(42, 'owned') } 'Win32Exception'
        if ($failure -in @('open','enumerate','data','lock') -and [DarkReNamerVmAcceptanceNative]::Calls.Contains('empty')) {
            throw 'Cleanup mutated the Clipboard after a failed ownership observation.'
        }
        if ([DarkReNamerVmAcceptanceNative]::Held) { throw 'Failed guarded cleanup retained a lock.' }
    }
    [DarkReNamerVmAcceptanceNative]::ResetClipboard(42, 'owned', [uint32[]]@(13))
    [DarkReNamerVmAcceptanceNative]::LeaveDataAfterEmpty = $true
    Assert-Fails { [DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned(42, 'owned') } 'not empty after guarded cleanup'
    [DarkReNamerVmAcceptanceNative]::ResetClipboard(42, 'owned', [uint32[]]@(13))
    [DarkReNamerVmAcceptanceNative]::ChangeSequenceDuringRead = $true
    Assert-Fails { [DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned(42, 'owned') } 'changed during one acceptance observation'
    if ([DarkReNamerVmAcceptanceNative]::Calls.Contains('empty')) { throw 'Unstable Clipboard observation authorized cleanup.' }
}
finally { [DarkReNamerVmAcceptanceNative]::ReleaseMemory() }

# Borrowed High Contrast pointers remain live in the fixture's ownership through
# successful and failing reads; inspect actual retained storage and read budget.
$flags = [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
$counter = [DarkReNamerVmAcceptanceNative].GetField('highContrastReads', $flags)
$retained = [DarkReNamerVmAcceptanceNative].GetField('retainedSchemePointers', $flags)
$scheme = [Runtime.InteropServices.Marshal]::StringToHGlobalUni('fixture scheme')
try {
    [DarkReNamerVmAcceptanceNative]::SchemePointer = $scheme
    [DarkReNamerVmAcceptanceNative]::Failure = ''
    [DarkReNamerVmAcceptanceNative]::Calls.Clear()
    $snapshot = [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot()
    Assert-Equal $snapshot.Scheme 'fixture scheme' 'Borrowed scheme projection'
    Assert-Equal $snapshot.Flags 1 'High Contrast flags'
    Assert-Equal (@($snapshot.Window,$snapshot.WindowText,$snapshot.ButtonFace,$snapshot.ButtonText,
        $snapshot.Highlight,$snapshot.HighlightText,$snapshot.GrayText,$snapshot.HotLight) -join ',') '5,8,15,18,13,14,17,26' 'System colors'
    Assert-Equal ($retained.GetValue($null)[0]) $scheme 'Retained borrowed pointer'
    Assert-Equal ([Runtime.InteropServices.Marshal]::PtrToStringUni($scheme)) 'fixture scheme' 'Borrowed pointer lifetime'
    [Runtime.InteropServices.Marshal]::WriteInt16($scheme, [int16][char]'X')
    Assert-Equal $snapshot.Scheme 'fixture scheme' 'Snapshot owns the copied string'
    Assert-Equal ([Runtime.InteropServices.Marshal]::PtrToStringUni($scheme)) 'Xixture scheme' 'Borrowed storage remains owned by fixture'
    [DarkReNamerVmAcceptanceNative]::SchemePointer = [IntPtr]::Zero
    if ($null -ne [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot().Scheme) { throw 'Null scheme pointer acquired a string.' }
    foreach ($mode in @('error','empty','relative','path-bound','color-bound','size-bound')) {
        [DarkReNamerVmAcceptanceNative]::ThemeMode = $mode
        Assert-Fails { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
            $(if ($mode -ceq 'error') { '0x80004005' } else { 'unavailable or truncated' })
    }
    [DarkReNamerVmAcceptanceNative]::ThemeMode = 'valid'
    [DarkReNamerVmAcceptanceNative]::Failure = 'spi'
    Assert-Fails { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } 'Win32Exception'
    [DarkReNamerVmAcceptanceNative]::Failure = ''
    while ([int]$counter.GetValue($null) -lt 128) { [void][DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() }
    $callsBefore = [DarkReNamerVmAcceptanceNative]::SpiCalls
    foreach ($attempt in 1..3) {
        Assert-Fails { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } 'read limit exceeded'
        Assert-Equal ($counter.GetValue($null)) 128 'High Contrast saturated counter'
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::SpiCalls) $callsBefore 'No native read above budget'
    }
    Assert-Equal ($retained.GetValue($null).Length) 128 'Retained pointer budget'
}
finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($scheme) }

& {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $probe = [pscustomobject]@{ focus = 0; fail = $false }
    function Get-FocusedAcceptanceElement {
        param($Process, $ExpectedSession, $Label)
        $probe.focus++
        if ($probe.fail) { throw 'fixture focus failure' }
        if ([DarkReNamerVmAcceptanceNative]::Inputs.Count -ne 0) { throw 'Chord sent input before binding focus.' }
    }
    try {
        foreach ($two in @($false,$true)) {
            foreach ($extended in @($false,$true)) {
                foreach ($failCall in @(0,1,2,3,4,5,6)) {
                    if (-not $two -and $failCall -gt 4) { continue }
                    [DarkReNamerVmAcceptanceNative]::Inputs.Clear()
                    [DarkReNamerVmAcceptanceNative]::InputCalls = 0
                    [DarkReNamerVmAcceptanceNative]::FailInputCall = $failCall
                    $probe.focus = 0
                    $parameters = @{ Process = $process; ExpectedSession = 1; Modifier = 0x11; VirtualKey = 0x23; Label = 'chord fixture'; ExtendedKey = $extended }
                    $command = if ($two) { $parameters.SecondModifier = 0x10; 'Send-AcceptanceTwoModifierChord' } else { 'Send-AcceptanceChord' }
                    if ($failCall -eq 0) { & $command @parameters }
                    else { Assert-Fails { & $command @parameters } $(if ($two -and $failCall -ge 5) { 'Modifier release failed' } else { 'Win32Exception' }) }
                    Assert-Equal $probe.focus 1 'Chord focus binding'
                    $down = if ($extended) { 1 } else { 0 }; $up = if ($extended) { 3 } else { 2 }
                    $expected = if ($two) {
                        switch ($failCall) {
                            1 { '17:0,16:2,17:2' }
                            2 { '17:0,16:0,16:2,17:2' }
                            3 { "17:0,16:0,35:$down,16:2,17:2" }
                            default { "17:0,16:0,35:$down,35:$up,16:2,17:2" }
                        }
                    } else {
                        switch ($failCall) {
                            1 { '17:0,17:2' }
                            2 { "17:0,35:$down,17:2" }
                            default { "17:0,35:$down,35:$up,17:2" }
                        }
                    }
                    Assert-Equal ([DarkReNamerVmAcceptanceNative]::Inputs -join ',') $expected 'Input flags and modifier restoration'
                }
            }
        }
        [DarkReNamerVmAcceptanceNative]::Inputs.Clear()
        [DarkReNamerVmAcceptanceNative]::InputCalls = 0
        [DarkReNamerVmAcceptanceNative]::FailInputCall = 3
        [DarkReNamerVmAcceptanceNative]::FailInputCall2 = 5
        Assert-Fails { Send-AcceptanceTwoModifierChord -Process $process -ExpectedSession 1 `
            -Modifier 0x11 -SecondModifier 0x10 -VirtualKey 0x23 -Label 'two failures' -ExtendedKey } 'Modifier release failed'
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Inputs -join ',') '17:0,16:0,35:1,16:2,17:2' 'Restoration continues after primary and release failures'
        [DarkReNamerVmAcceptanceNative]::FailInputCall2 = 0
        [DarkReNamerVmAcceptanceNative]::Inputs.Clear(); $probe.fail = $true
        foreach ($command in @('Send-AcceptanceChord','Send-AcceptanceTwoModifierChord')) {
            $focusParameters = @{} + $parameters
            if ($command -ceq 'Send-AcceptanceChord') { $focusParameters.Remove('SecondModifier') }
            Assert-Fails { & $command @focusParameters } 'fixture focus failure'
            Assert-Equal ([DarkReNamerVmAcceptanceNative]::Inputs.Count) 0 'No input after binding failure'
        }
    }
    finally { $process.Dispose() }
}

& {
    function Start-Sleep { param($Milliseconds) }
    function Assert-AutomationBinding {
        param($Element, $Process, $ExpectedSession, $Label, [switch] $RequireWindowHandle)
        if (-not $RequireWindowHandle -or $Element.Current.NativeWindowHandle -ne 101 -or $ExpectedSession -ne 1) { throw 'invalid resize binding' }
        if ($bindingFailure) { throw 'fixture resize binding failure' }
    }
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $window = [Windows.Automation.AutomationElement]::new()
    try {
        foreach ($case in @('small','large','minimum','height','before-rect','poll-rect','final-rect','resize-failure','never-settles','dpi-changed','binding','invalid-width','oversized-height')) {
            $bindingFailure = $case -ceq 'binding'
            [DarkReNamerVmAcceptanceNative]::Calls.Clear()
            [DarkReNamerVmAcceptanceNative]::DpiReads = 0
            [DarkReNamerVmAcceptanceNative]::ResizeCalls = 0
            [DarkReNamerVmAcceptanceNative]::ResizeFailure = $case -ceq 'resize-failure'
            [DarkReNamerVmAcceptanceNative]::ResizeNeverSettles = $case -ceq 'never-settles'
            [DarkReNamerVmAcceptanceNative]::ChangeDpi = $case -ceq 'dpi-changed'
            [DarkReNamerVmNative]::Reads = 0
            [DarkReNamerVmNative]::FailRead = switch ($case) { 'before-rect' { 1 } 'poll-rect' { 2 } 'final-rect' { 3 } default { 0 } }
            [DarkReNamerVmNative]::Width = switch ($case) { 'large' { 900 } 'minimum' { 640 } 'height' { 700 } 'invalid-width' { 0 } default { 594 } }
            [DarkReNamerVmNative]::Height = switch ($case) { 'large' { 700 } 'minimum' { 360 } 'height' { 300 } 'oversized-height' { 16385 } default { 508 } }
            $action = { Ensure-AcceptanceMainWindowCaptureSize -MainWindow $window -Process $process -ExpectedSession 1 }
            if ($case -in @('small','large','minimum','height')) {
                $result = & $action
                $expectedWidth = switch ($case) { 'large' { 900 } 'height' { 700 } default { 640 } }
                $expectedHeight = switch ($case) { 'large' { 700 } 'minimum' { 360 } 'height' { 360 } default { 508 } }
                Assert-Equal $result.width $expectedWidth 'Final capture width'
                Assert-Equal $result.height $expectedHeight 'Final capture height'
                Assert-Equal $result.dpi 96 'Final capture DPI'
                Assert-Equal ([DarkReNamerVmAcceptanceNative]::ResizeCalls) $(if ($case -in @('small','height')) { 1 } else { 0 }) 'Resize calls'
                Assert-Equal ($result.resize_required) ($case -in @('small','height')) 'Resize receipt'
                Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') `
                    $(if ($case -in @('small','height')) { 'dpi:101,rect:101,resize:101,rect:101,rect:101,dpi:101' } else { 'dpi:101,rect:101,rect:101,dpi:101' }) 'Bound sizing call order'
            }
            else {
                $expected = switch ($case) {
                    'before-rect' { 'before capture sizing' }
                    'poll-rect' { 'after capture sizing' }
                    'final-rect' { 'final capture bounds' }
                    'resize-failure' { 'refused to resize' }
                    'never-settles' { 'did not reach' }
                    'dpi-changed' { 'DPI changed' }
                    'binding' { 'fixture resize binding failure' }
                    'invalid-width' { 'CurrentWidth' }
                    'oversized-height' { 'CurrentHeight' }
                }
                Assert-Fails $action $expected
                if ($case -ceq 'never-settles') { Assert-Equal ([DarkReNamerVmNative]::Reads) 42 'Bounded resize polling' }
                if ($case -in @('binding','before-rect','invalid-width','oversized-height')) { Assert-Equal ([DarkReNamerVmAcceptanceNative]::ResizeCalls) 0 'No resize after failed binding or observation' }
            }
        }
    }
    finally { $process.Dispose() }
}
$performanceSample = Get-NativeFixtureMember 'public sealed class DarkReNamerPerformanceSample'
$performanceSampler = Get-NativeFixtureMember 'public sealed class DarkReNamerPerformanceSampler'
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
$performanceSample
$performanceSampler
"@
Assert-Equal ([DarkReNamerPerformanceSampler]::ClassifyProbe($true, 0)) 'success' 'Successful probe classification'
Assert-Equal ([DarkReNamerPerformanceSampler]::ClassifyProbe($false, 1460)) 'timeout' 'Identified timeout classification'
foreach ($unknown in @(0, 5, 87)) {
    Assert-Equal ([DarkReNamerPerformanceSampler]::ClassifyProbe($false, $unknown)) 'failure_unknown' 'Unknown failure classification'
}
$resetAt = $performanceSampler.IndexOf('SetLastErrorNative(0);', [StringComparison]::Ordinal)
$beginAt = $performanceSampler.IndexOf('long begun = System.Diagnostics.Stopwatch.GetTimestamp();', [StringComparison]::Ordinal)
$sendAt = $performanceSampler.IndexOf('bool responsive = SendMessageTimeoutW(', [StringComparison]::Ordinal)
$endAt = $performanceSampler.IndexOf('long probeEnded = System.Diagnostics.Stopwatch.GetTimestamp();', [StringComparison]::Ordinal)
$errorAt = $performanceSampler.IndexOf('Marshal.GetLastWin32Error();', [StringComparison]::Ordinal)
$resourcesAt = $performanceSampler.IndexOf('process.TotalProcessorTime', [StringComparison]::Ordinal)
if (-not (0 -le $resetAt -and $resetAt -lt $beginAt -and $beginAt -lt $sendAt -and
    $sendAt -lt $endAt -and $endAt -lt $errorAt -and $errorAt -lt $resourcesAt)) {
    throw 'Performance native probe timestamp or last-error capture order changed.'
}
$iconStatus = [ordered]@{ version=1; session='41'; generation='2'; bootstrap=1;
    queued=0; inflight=0; undrained=0; unresolved_rows=0; cursor=1000;
    settled=$true; worker_joined=$false; reconcile_rows=0; batch_ack=0;
    status_revision='8'; demand_exhausted=$true; demand_remaining=0; model_revision='2';
    unavailable_or_retiring=$false }
Assert-Equal (Test-ObserverIconTerminalSnapshot -Snapshot $iconStatus -Rows 1000) $true 'Stable icon terminal state'
$iconStatus.unavailable_or_retiring = $true
Assert-Fails { Test-ObserverIconTerminalSnapshot -Snapshot $iconStatus -Rows 1000 } 'unavailable or retired'
$iconStatus.worker_joined = $true
Assert-Fails { Test-ObserverIconTerminalSnapshot -Snapshot $iconStatus -Rows 1000 } 'unavailable or retired'
$iconStatus.unavailable_or_retiring = $false
Assert-Equal (Test-ObserverIconTerminalSnapshot -Snapshot $iconStatus -Rows 1000) $false 'Joined worker is not active terminal state'
$iconStatus.worker_joined = $false
$iconStatus.demand_remaining = 1
Assert-Equal (Test-ObserverIconTerminalSnapshot -Snapshot $iconStatus -Rows 1000) $false 'Unexhausted icon demand'
$iconStatus.demand_remaining = 0
$iconStatus.queued = 65
Assert-Fails { Test-ObserverIconTerminalSnapshot -Snapshot $iconStatus -Rows 1000 } 'bounded version-one contract'
$churnNames = @(0..999 | ForEach-Object { Get-ObserverIconChurnFileName -Index $_ })
Assert-Equal @($churnNames | ForEach-Object { [IO.Path]::GetExtension($_) } | Sort-Object -Unique).Count 300 'Interleaved extension-class count'
Assert-Equal $churnNames[0] 'extension-0000.e000' 'First unique class'
Assert-Equal $churnNames[1] 'recurring-0001.txt' 'Interleaved recurring class'
Assert-Equal $churnNames[596] 'extension-0596.e298' 'Last unique class'
Assert-Equal $churnNames[999] 'recurring-0999.txt' 'Last recurring class'
Write-Output 'UI native/input behavior contracts passed.'
