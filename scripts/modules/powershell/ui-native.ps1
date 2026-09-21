function Get-AcceptanceClipboardTextEvidence {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $bytes = [Text.Encoding]::Unicode.GetBytes($Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    [ordered]@{
        utf16le_bytes = $bytes.Length
        sha256 = -join ($digest | ForEach-Object { $_.ToString('x2') })
    }
}
function Test-AcceptanceClipboardSnapshotOwned {
    param(
        [Parameter(Mandatory)][object] $Snapshot,
        [Parameter(Mandatory)][uint32] $ExpectedSequence,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ExpectedText
    )

    if ($Snapshot.SequenceNumber -ne $ExpectedSequence -or
        -not [string]::Equals(
            [string]$Snapshot.UnicodeText,
            $ExpectedText,
            [StringComparison]::Ordinal
        )) {
        return $false
    }
    $formats = @($Snapshot.Formats)
    if ($formats.Count -eq 0 -or $formats -notcontains [uint32]13) {
        return $false
    }
    @($formats | Where-Object { $_ -notin @([uint32]1, [uint32]7, [uint32]13, [uint32]16) }).Count -eq 0
}
function Initialize-AcceptanceNative {
    if ('DarkReNamerVmAcceptanceNative' -as [type]) {
        return
    }
    Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class DarkReNamerVmAcceptanceNative {
    private const int MaxHighContrastReads = 128;
    private static int highContrastReads;
    private static readonly IntPtr[] retainedSchemePointers = new IntPtr[MaxHighContrastReads];
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    public sealed class HighContrastSnapshot {
        public uint Flags { get; set; }
        public string Scheme { get; set; }
        public uint Window { get; set; }
        public uint WindowText { get; set; }
        public uint ButtonFace { get; set; }
        public uint ButtonText { get; set; }
        public uint Highlight { get; set; }
        public uint HighlightText { get; set; }
        public uint GrayText { get; set; }
        public uint HotLight { get; set; }
        public string ThemePath { get; set; }
        public string ThemeColor { get; set; }
        public string ThemeSize { get; set; }
    }

    public sealed class ClipboardSnapshot {
        public uint SequenceNumber { get; set; }
        public uint[] Formats { get; set; }
        public string UnicodeText { get; set; }
    }

    public sealed class WindowMeasurement {
        public long Handle;
        public long Owner;
        public uint ProcessId;
        public string ClassName;
        public string Title;
        public bool Visible;
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public sealed class NativeMenuItemMeasurement {
        public int[] MenuPath;
        public int Position;
        public string ItemType;
        public int? CommandId;
        public uint StateFlags;
        public bool Enabled;
        public bool Checked;
    }

    public sealed class NativeMenuHighlightMeasurement {
        public int[] MenuPath;
        public int Position;
        public int? CommandId;
        public uint StateFlags;
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public sealed class NativePopupMeasurement {
        public long Handle;
        public uint ProcessId;
        public string ClassName;
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMonitorInfo {
        public uint Size;
        public Rect Monitor;
        public Rect Work;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeScrollInfo {
        public uint Size;
        public uint Mask;
        public int Minimum;
        public int Maximum;
        public uint Page;
        public int Position;
        public int TrackPosition;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MENUITEMINFO {
        public uint Size;
        public uint Mask;
        public uint Type;
        public uint State;
        public uint Id;
        public IntPtr SubMenu;
        public IntPtr CheckedBitmap;
        public IntPtr UncheckedBitmap;
        public UIntPtr ItemData;
        public IntPtr TypeData;
        public uint TextLength;
        public IntPtr ItemBitmap;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT {
        public ushort virtualKey;
        public ushort scanCode;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT {
        public int x;
        public int y;
        public uint mouseData;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION {
        [FieldOffset(0)] public KEYBDINPUT keyboard;
        [FieldOffset(0)] public MOUSEINPUT mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT {
        public uint type;
        public INPUTUNION value;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct HIGHCONTRAST {
        public uint size;
        public uint flags;
        public IntPtr scheme;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RTL_OSVERSIONINFOEX {
        public uint size;
        public uint major;
        public uint minor;
        public uint build;
        public uint platform;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string servicePack;
        public ushort servicePackMajor;
        public ushort servicePackMinor;
        public ushort suiteMask;
        public byte productType;
        public byte reserved;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    private static extern bool ReadSystemWorkArea(uint action, uint parameter, out Rect value, uint flags);
    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref NativeMonitorInfo info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowTextW(IntPtr window, StringBuilder value, int capacity);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetScrollInfo(IntPtr window, int bar, ref NativeScrollInfo info);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")]
    private static extern IntPtr GetMenu(IntPtr window);
    [DllImport("user32.dll")]
    private static extern uint GetMenuState(IntPtr menu, uint item, uint flags);
    [DllImport("user32.dll")]
    private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")]
    private static extern IntPtr GetSubMenu(IntPtr menu, int position);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetMenuItemInfoW(
        IntPtr menu, uint item, bool byPosition, ref MENUITEMINFO info);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetMenuItemRect(
        IntPtr window, IntPtr menu, uint item, out Rect rect);
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
    [DllImport("user32.dll")]
    private static extern uint GetSysColor(int index);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetSysColors(int count, int[] indices, uint[] colors);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentThemeName(
        StringBuilder themeFileName,
        int maximumNameCharacters,
        StringBuilder colorName,
        int maximumColorCharacters,
        StringBuilder sizeName,
        int maximumSizeCharacters);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")]
    private static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UIntPtr GlobalSize(IntPtr memory);
    [DllImport("kernel32.dll", EntryPoint = "SetLastError")]
    private static extern void SetLastErrorNative(uint code);
    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    private static extern int RtlGetVersion(ref RTL_OSVERSIONINFOEX version);

    private static uint[] EnumerateClipboardFormats() {
        List<uint> formats = new List<uint>();
        uint previous = 0;
        while (true) {
            SetLastErrorNative(0);
            uint current = EnumClipboardFormats(previous);
            if (current == 0) {
                int error = Marshal.GetLastWin32Error();
                if (error != 0) { throw new Win32Exception(error); }
                return formats.ToArray();
            }
            formats.Add(current);
            previous = current;
            if (formats.Count > 64) {
                throw new InvalidOperationException("Clipboard format count exceeded the acceptance bound.");
            }
        }
    }

    private static string ReadClipboardUnicodeText(uint[] formats) {
        if (Array.IndexOf(formats, 13U) < 0) { return null; }
        IntPtr memory = GetClipboardData(13);
        if (memory == IntPtr.Zero) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        ulong byteCount = GlobalSize(memory).ToUInt64();
        if (byteCount < 2 || byteCount > 2 * 1024 * 1024 || (byteCount & 1) != 0) {
            throw new InvalidOperationException("Clipboard Unicode text allocation is invalid or over limit.");
        }
        IntPtr pointer = GlobalLock(memory);
        if (pointer == IntPtr.Zero) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            string allocation = Marshal.PtrToStringUni(pointer, checked((int)(byteCount / 2)));
            int terminator = allocation.IndexOf('\0');
            if (terminator < 0) {
                throw new InvalidOperationException("Clipboard Unicode text is not terminated.");
            }
            return allocation.Substring(0, terminator);
        }
        finally {
            GlobalUnlock(memory);
        }
    }

    private static ClipboardSnapshot ReadOpenClipboardSnapshot() {
        uint sequence = GetClipboardSequenceNumber();
        uint[] formats = EnumerateClipboardFormats();
        string text = ReadClipboardUnicodeText(formats);
        if (GetClipboardSequenceNumber() != sequence) {
            throw new InvalidOperationException("Clipboard changed during one acceptance observation.");
        }
        return new ClipboardSnapshot {
            SequenceNumber = sequence,
            Formats = formats,
            UnicodeText = text
        };
    }

    public static ClipboardSnapshot ReadClipboardSnapshot() {
        if (!OpenClipboard(IntPtr.Zero)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try { return ReadOpenClipboardSnapshot(); }
        finally {
            if (!CloseClipboard()) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        }
    }

    private static bool RequiresEmptyClipboardInitialization(ClipboardSnapshot snapshot) {
        if (snapshot == null || snapshot.Formats == null) {
            throw new InvalidOperationException("Clipboard preflight snapshot is incomplete.");
        }
        if (snapshot.Formats.Length != 0 || snapshot.UnicodeText != null) {
            throw new InvalidOperationException(
                "Clipboard acceptance requires an initially empty Clipboard and will not clear existing data.");
        }
        return snapshot.SequenceNumber == 0;
    }

    public static ClipboardSnapshot ReadOrInitializeEmptyClipboardSnapshot() {
        if (!OpenClipboard(IntPtr.Zero)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            ClipboardSnapshot snapshot = ReadOpenClipboardSnapshot();
            if (!RequiresEmptyClipboardInitialization(snapshot)) { return snapshot; }
            if (!EmptyClipboard()) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            ClipboardSnapshot initialized = ReadOpenClipboardSnapshot();
            if (initialized.SequenceNumber == 0 || initialized.Formats.Length != 0 ||
                initialized.UnicodeText != null) {
                throw new InvalidOperationException(
                    "Empty Clipboard initialization did not establish a nonzero empty baseline.");
            }
            return initialized;
        }
        finally {
            if (!CloseClipboard()) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        }
    }

    public static string ClearClipboardIfOwned(uint expectedSequence, string expectedText) {
        if (!OpenClipboard(IntPtr.Zero)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            ClipboardSnapshot snapshot = ReadOpenClipboardSnapshot();
            if (snapshot.SequenceNumber != expectedSequence) { return "sequence_changed"; }
            if (!String.Equals(snapshot.UnicodeText, expectedText, StringComparison.Ordinal)) {
                return "text_changed";
            }
            bool unicode = false;
            foreach (uint format in snapshot.Formats) {
                if (format == 13) { unicode = true; }
                else if (format != 1 && format != 7 && format != 16) {
                    return "foreign_format";
                }
            }
            if (!unicode || snapshot.Formats.Length == 0) { return "text_format_missing"; }
            if (!EmptyClipboard()) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (EnumerateClipboardFormats().Length != 0) {
                throw new InvalidOperationException("Clipboard was not empty after guarded cleanup.");
            }
            return "cleared";
        }
        finally {
            if (!CloseClipboard()) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        }
    }

    private static void Send(ushort virtualKey, ushort scanCode, uint flags) {
        INPUT input = new INPUT {
            type = 1,
            value = new INPUTUNION {
                keyboard = new KEYBDINPUT {
                    virtualKey = virtualKey,
                    scanCode = scanCode,
                    flags = flags,
                    time = 0,
                    extraInfo = UIntPtr.Zero
                }
            }
        };
        if (SendInput(1, new [] { input }, Marshal.SizeOf(typeof(INPUT))) != 1) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void KeyDown(ushort virtualKey) { Send(virtualKey, 0, 0); }
    public static void KeyUp(ushort virtualKey) { Send(virtualKey, 0, 2); }
    public static void Tap(ushort virtualKey) { KeyDown(virtualKey); KeyUp(virtualKey); }
    public static void TapExtended(ushort virtualKey) {
        Send(virtualKey, 0, 1);
        Send(virtualKey, 0, 3);
    }

    public static void TypeUnicode(string value) {
        foreach (char unit in value) {
            Send(0, unit, 4);
            Send(0, unit, 4 | 2);
        }
    }

    public static void ReleaseModifiers() {
        KeyUp(0x10);
        KeyUp(0x11);
        KeyUp(0x12);
    }

    private static bool TryGetMenuCommandState(IntPtr menu, uint command, out uint state) {
        state = GetMenuState(menu, command, 0);
        if (state != UInt32.MaxValue) { return true; }
        int count = GetMenuItemCount(menu);
        if (count < 0) {
            throw new InvalidOperationException("The native menu could not be inspected.");
        }
        for (int position = 0; position < count; position++) {
            IntPtr submenu = GetSubMenu(menu, position);
            if (submenu != IntPtr.Zero && TryGetMenuCommandState(submenu, command, out state)) {
                return true;
            }
        }
        return false;
    }

    private static MENUITEMINFO ReadMenuItem(IntPtr menu, int position) {
        MENUITEMINFO info = new MENUITEMINFO {
            Size = (uint)Marshal.SizeOf(typeof(MENUITEMINFO)),
            Mask = 0x00000107
        };
        if (!GetMenuItemInfoW(menu, (uint)position, true, ref info)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return info;
    }

    private static void ReadNativeMenuTree(
        IntPtr menu,
        List<int> path,
        List<NativeMenuItemMeasurement> rows,
        int depth) {
        if (depth > 3) {
            throw new InvalidOperationException("Native menu depth exceeded its bound.");
        }
        int count = GetMenuItemCount(menu);
        if (count < 0 || count > 32) {
            throw new InvalidOperationException("Native menu item count is invalid or over limit.");
        }
        for (int position = 0; position < count; position++) {
            uint state = GetMenuState(menu, (uint)position, 0x400);
            if (state == UInt32.MaxValue) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            MENUITEMINFO info = ReadMenuItem(menu, position);
            bool separator = (info.Type & 0x800) != 0;
            bool submenu = info.SubMenu != IntPtr.Zero;
            rows.Add(new NativeMenuItemMeasurement {
                MenuPath = path.ToArray(),
                Position = position,
                ItemType = separator ? "separator" : submenu ? "submenu" : "command",
                CommandId = separator || submenu ? (int?)null : checked((int)info.Id),
                StateFlags = state & 0xFF,
                Enabled = (state & 0x3) == 0,
                Checked = (state & 0x8) != 0
            });
            if (rows.Count > 128) {
                throw new InvalidOperationException("Native menu tree exceeded its item bound.");
            }
            if (submenu) {
                path.Add(position);
                ReadNativeMenuTree(info.SubMenu, path, rows, depth + 1);
                path.RemoveAt(path.Count - 1);
            }
        }
    }

    private static InvalidOperationException NoNativeMenuException(IntPtr window) {
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        StringBuilder className = new StringBuilder(128);
        GetClassName(window, className, className.Capacity);
        return new InvalidOperationException(
            "The application window has no native menu (hwnd=" +
            window.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture) +
            ", pid=" + processId.ToString(System.Globalization.CultureInfo.InvariantCulture) +
            ", class=" + className.ToString() + ").");
    }

    public static NativeMenuItemMeasurement[] ReadNativeMenuTree(IntPtr window) {
        IntPtr root = GetMenu(window);
        if (root == IntPtr.Zero) {
            throw NoNativeMenuException(window);
        }
        List<NativeMenuItemMeasurement> rows = new List<NativeMenuItemMeasurement>();
        ReadNativeMenuTree(root, new List<int>(), rows, 0);
        return rows.ToArray();
    }

    private static void ReadHighlightedNativeMenuItems(
        IntPtr window,
        IntPtr menu,
        List<int> path,
        List<NativeMenuHighlightMeasurement> rows,
        int depth) {
        if (depth > 3) {
            throw new InvalidOperationException("Native highlighted menu depth exceeded its bound.");
        }
        int count = GetMenuItemCount(menu);
        if (count < 0 || count > 32) {
            throw new InvalidOperationException("Native highlighted menu item count is invalid or over limit.");
        }
        for (int position = 0; position < count; position++) {
            uint state = GetMenuState(menu, (uint)position, 0x400);
            if (state == UInt32.MaxValue) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            MENUITEMINFO info = ReadMenuItem(menu, position);
            bool separator = (info.Type & 0x800) != 0;
            bool submenu = info.SubMenu != IntPtr.Zero;
            if ((state & 0x80) != 0) {
                Rect rect;
                IntPtr itemOwner = depth == 0 ? window : IntPtr.Zero;
                if (!GetMenuItemRect(itemOwner, menu, (uint)position, out rect)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                rows.Add(new NativeMenuHighlightMeasurement {
                    MenuPath = path.ToArray(),
                    Position = position,
                    CommandId = separator || submenu ? (int?)null : checked((int)info.Id),
                    StateFlags = state & 0xFF,
                    Left = rect.Left,
                    Top = rect.Top,
                    Right = rect.Right,
                    Bottom = rect.Bottom
                });
                if (rows.Count > 4) {
                    throw new InvalidOperationException("Native highlighted menu count exceeded its bound.");
                }
            }
            if (submenu) {
                path.Add(position);
                ReadHighlightedNativeMenuItems(window, info.SubMenu, path, rows, depth + 1);
                path.RemoveAt(path.Count - 1);
            }
        }
    }

    public static NativeMenuHighlightMeasurement[] ReadHighlightedNativeMenuItems(IntPtr window) {
        IntPtr root = GetMenu(window);
        if (root == IntPtr.Zero) {
            throw NoNativeMenuException(window);
        }
        List<NativeMenuHighlightMeasurement> rows = new List<NativeMenuHighlightMeasurement>();
        ReadHighlightedNativeMenuItems(window, root, new List<int>(), rows, 0);
        return rows.ToArray();
    }

    public static bool IsMenuCommandEnabled(IntPtr window, uint command) {
        IntPtr root = GetMenu(window);
        if (root == IntPtr.Zero) {
            throw NoNativeMenuException(window);
        }
        uint state;
        if (!TryGetMenuCommandState(root, command, out state)) {
            throw new InvalidOperationException("The native menu command was not found.");
        }
        return (state & 3) == 0;
    }

    public static bool IsMenuCommandChecked(IntPtr window, uint command) {
        IntPtr root = GetMenu(window);
        if (root == IntPtr.Zero) {
            throw NoNativeMenuException(window);
        }
        uint state;
        if (!TryGetMenuCommandState(root, command, out state)) {
            throw new InvalidOperationException("The native menu command was not found.");
        }
        return (state & 8) != 0;
    }

    public static void SendMenuCommand(IntPtr window, uint command) {
        SendMessageW(window, 0x0111, new IntPtr(command), IntPtr.Zero);
    }

    public static IntPtr FindVisiblePopupMenu(uint expectedProcessId) {
        IntPtr match = IntPtr.Zero;
        int matches = 0;
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            if (!IsWindowVisible(window)) { return true; }
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) { return true; }
            StringBuilder className = new StringBuilder(32);
            if (GetClassName(window, className, className.Capacity) > 0 &&
                String.Equals(className.ToString(), "#32768", StringComparison.Ordinal)) {
                match = window;
                matches++;
            }
            return true;
        }, IntPtr.Zero);
        if (matches > 1) {
            throw new InvalidOperationException("More than one visible native menu popup was found.");
        }
        return match;
    }

    public static NativePopupMeasurement[] ReadVisibleNativeMenuPopups(uint expectedProcessId) {
        List<NativePopupMeasurement> rows = new List<NativePopupMeasurement>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            if (!IsWindowVisible(window)) { return true; }
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) { return true; }
            StringBuilder className = new StringBuilder(32);
            if (GetClassName(window, className, className.Capacity) > 0 &&
                String.Equals(className.ToString(), "#32768", StringComparison.Ordinal)) {
                Rect rect;
                if (!GetWindowRect(window, out rect)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                rows.Add(new NativePopupMeasurement {
                    Handle = window.ToInt64(), ProcessId = processId,
                    ClassName = className.ToString(),
                    Left = rect.Left, Top = rect.Top, Right = rect.Right, Bottom = rect.Bottom
                });
                if (rows.Count > 2) {
                    throw new InvalidOperationException("Visible native menu popup count exceeded its bound.");
                }
            }
            return true;
        }, IntPtr.Zero);
        rows.Sort(delegate(NativePopupMeasurement left, NativePopupMeasurement right) {
            return left.Handle.CompareTo(right.Handle);
        });
        return rows.ToArray();
    }

    public static HighContrastSnapshot GetHighContrastSnapshot() {
        int slot = System.Threading.Interlocked.Increment(ref highContrastReads) - 1;
        if (slot >= MaxHighContrastReads) {
            System.Threading.Interlocked.Decrement(ref highContrastReads);
            throw new InvalidOperationException("High Contrast snapshot read limit exceeded.");
        }
        HIGHCONTRAST value = new HIGHCONTRAST();
        value.size = (uint)Marshal.SizeOf(typeof(HIGHCONTRAST));
        if (!SystemParametersInfo(0x42, value.size, ref value, 0)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        // Treat the GET pointer as borrowed in this bounded observer. Copy it
        // synchronously without freeing it; the OS reclaims any allocation at
        // process exit. Retain at most 128 pointer values for that lifetime.
        retainedSchemePointers[slot] = value.scheme;
        const int themePathCapacity = 512;
        const int themeComponentCapacity = 128;
        StringBuilder themePath = new StringBuilder(themePathCapacity);
        StringBuilder themeColor = new StringBuilder(themeComponentCapacity);
        StringBuilder themeSize = new StringBuilder(themeComponentCapacity);
        int themeResult = GetCurrentThemeName(
            themePath,
            themePathCapacity,
            themeColor,
            themeComponentCapacity,
            themeSize,
            themeComponentCapacity);
        if (themeResult != 0) { Marshal.ThrowExceptionForHR(themeResult); }
        if (themePath.Length == 0 || themePath.Length >= themePathCapacity - 1 ||
            themeColor.Length == 0 || themeColor.Length >= themeComponentCapacity - 1 ||
            themeSize.Length == 0 || themeSize.Length >= themeComponentCapacity - 1 ||
            !System.IO.Path.IsPathRooted(themePath.ToString())) {
            throw new InvalidOperationException("The active visual-style identity is unavailable or truncated.");
        }
        return new HighContrastSnapshot {
            Flags = value.flags,
            Scheme = value.scheme == IntPtr.Zero ? null : Marshal.PtrToStringUni(value.scheme),
            Window = GetSysColor(5),
            WindowText = GetSysColor(8),
            ButtonFace = GetSysColor(15),
            ButtonText = GetSysColor(18),
            Highlight = GetSysColor(13),
            HighlightText = GetSysColor(14),
            GrayText = GetSysColor(17),
            HotLight = GetSysColor(26),
            ThemePath = themePath.ToString(),
            ThemeColor = themeColor.ToString(),
            ThemeSize = themeSize.ToString()
        };
    }

    public static bool HighContrastEnabled() {
        return (GetHighContrastSnapshot().Flags & 1) != 0;
    }

    public static void ApplyHighContrast(uint flags, string scheme) {
        IntPtr schemeBuffer = IntPtr.Zero;
        try {
            if (scheme != null) { schemeBuffer = Marshal.StringToHGlobalUni(scheme); }
            HIGHCONTRAST value = new HIGHCONTRAST {
                size = (uint)Marshal.SizeOf(typeof(HIGHCONTRAST)),
                flags = flags,
                scheme = schemeBuffer
            };
            if (!SystemParametersInfo(0x43, value.size, ref value, 0x2)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally {
            if (schemeBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(schemeBuffer); }
        }
    }

    public static void SetHighContrastColors(
        uint window,
        uint windowText,
        uint buttonFace,
        uint buttonText,
        uint highlight,
        uint highlightText,
        uint grayText,
        uint hotLight) {
        int[] indices = new int[] { 5, 8, 15, 18, 13, 14, 17, 26 };
        uint[] colors = new uint[] {
            window, windowText, buttonFace, buttonText,
            highlight, highlightText, grayText, hotLight
        };
        if (!SetSysColors(indices.Length, indices, colors)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    private static bool observerClipboardHeld;

    public static Point ReadCursor() {
        Point point;
        if (!GetCursorPos(out point)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return point;
    }

    public static void MoveCursor(int x, int y) {
        if (!SetCursorPos(x, y)) throw new Win32Exception(Marshal.GetLastWin32Error());
        Point actual = ReadCursor();
        if (actual.X != x || actual.Y != y) {
            throw new InvalidOperationException("Windows did not retain the exact observer cursor position.");
        }
    }

    private static void SendMouseButton(uint flags) {
        INPUT input = new INPUT {
            type = 0,
            value = new INPUTUNION {
                mouse = new MOUSEINPUT { flags = flags, extraInfo = UIntPtr.Zero }
            }
        };
        if (SendInput(1, new [] { input }, Marshal.SizeOf(typeof(INPUT))) != 1) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void Click() { SendMouseButton(0x0002); SendMouseButton(0x0004); }
    public static void ReleaseAllButtons() {
        SendMouseButton(0x0004); SendMouseButton(0x0010); SendMouseButton(0x0040);
    }

    public static void HoldObserverClipboard() {
        if (observerClipboardHeld) throw new InvalidOperationException("Observer Clipboard hold is already active.");
        if (!OpenClipboard(IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        observerClipboardHeld = true;
    }

    public static void ReleaseObserverClipboard() {
        if (!observerClipboardHeld) return;
        if (!CloseClipboard()) throw new Win32Exception(Marshal.GetLastWin32Error());
        observerClipboardHeld = false;
    }

    public static Rect ReadWorkArea() {
        Rect value;
        if (!ReadSystemWorkArea(0x0030, 0, out value, 0)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return value;
    }

    public static Point ReadPhysicalScreenSize() {
        Point value = new Point { X = GetSystemMetrics(0), Y = GetSystemMetrics(1) };
        if (value.X <= 0 || value.Y <= 0) {
            throw new InvalidOperationException("Windows returned invalid physical screen bounds.");
        }
        return value;
    }

    public static int[] ReadMonitorInfo(IntPtr window) {
        IntPtr monitor = MonitorFromWindow(window, 2);
        if (monitor == IntPtr.Zero) throw new InvalidOperationException("MonitorFromWindow returned no target monitor.");
        NativeMonitorInfo info = new NativeMonitorInfo();
        info.Size = (uint)Marshal.SizeOf(typeof(NativeMonitorInfo));
        if (!GetMonitorInfoW(monitor, ref info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return new [] {
            info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom,
            info.Work.Left, info.Work.Top, info.Work.Right, info.Work.Bottom
        };
    }

    public static string[] DescribeWindow(IntPtr window) {
        StringBuilder className = new StringBuilder(128);
        StringBuilder title = new StringBuilder(1024);
        GetClassName(window, className, className.Capacity);
        GetWindowTextW(window, title, title.Capacity);
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        IntPtr owner = GetWindow(window, 4);
        return new [] {
            window.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture),
            owner.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture),
            processId.ToString(System.Globalization.CultureInfo.InvariantCulture),
            className.ToString(), title.ToString(), IsWindowVisible(window) ? "true" : "false"
        };
    }

    public static int[] TryReadScrollInfo(IntPtr window, int bar) {
        NativeScrollInfo info = new NativeScrollInfo();
        info.Size = (uint)Marshal.SizeOf(typeof(NativeScrollInfo));
        info.Mask = 0x17;
        if (!GetScrollInfo(window, bar, ref info)) return null;
        return new [] { info.Minimum, info.Maximum, (int)info.Page, info.Position, info.TrackPosition };
    }

    public static WindowMeasurement[] ReadProcessTopLevelWindows(uint expectedProcessId) {
        List<WindowMeasurement> windows = new List<WindowMeasurement>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) return true;
            Rect rect;
            if (!GetWindowRect(window, out rect)) rect = new Rect();
            string[] description = DescribeWindow(window);
            windows.Add(new WindowMeasurement {
                Handle = window.ToInt64(), Owner = Int64.Parse(description[1]), ProcessId = processId,
                ClassName = description[3], Title = description[4], Visible = description[5] == "true",
                Left = rect.Left, Top = rect.Top, Right = rect.Right, Bottom = rect.Bottom
            });
            if (windows.Count > 128) throw new InvalidOperationException("Process window inventory exceeded its bound.");
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }

    public static long ReadListViewTooltip(IntPtr listView) {
        return SendMessageW(listView, 0x104E, IntPtr.Zero, IntPtr.Zero).ToInt64();
    }

    public static string OsVersion() {
        RTL_OSVERSIONINFOEX value = new RTL_OSVERSIONINFOEX();
        value.size = (uint)Marshal.SizeOf(typeof(RTL_OSVERSIONINFOEX));
        int status = RtlGetVersion(ref value);
        if (status != 0) { throw new Win32Exception(status); }
        return value.major + "." + value.minor + "." + value.build;
    }
}
'@
}
