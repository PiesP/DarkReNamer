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

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeScrollBarInfo {
        public uint Size;
        public Rect Bounds;
        public int LineButtonSize;
        public int ThumbTop;
        public int ThumbBottom;
        public int Reserved;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public uint[] States;
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
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetScrollBarInfo(IntPtr window, int objectId, ref NativeScrollBarInfo info);
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
        List<Exception> errors = new List<Exception>();
        foreach (ushort key in new ushort[] { 0x10, 0x11, 0x12 }) {
            try { KeyUp(key); }
            catch (Exception error) { errors.Add(error); }
        }
        if (errors.Count != 0) throw new AggregateException("Modifier release failed.", errors);
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

    public static void SendBoundPerformanceCommand(IntPtr window, uint expectedProcessId, uint command) {
        uint processId;
        if (GetWindowThreadProcessId(window, out processId) == 0 || processId != expectedProcessId ||
            !IsMenuCommandEnabled(window, command))
            throw new InvalidOperationException("Performance command target or menu state is invalid.");
        IntPtr result;
        if (SendMessageTimeoutW(window, 0x0111, new IntPtr(command), IntPtr.Zero, 3, 5000, out result) == IntPtr.Zero)
            throw new InvalidOperationException("Performance menu command timed out.");
    }

    private static void EnumerateWindowsChecked(EnumWindowsCallback callback) {
        Exception callbackError = null;
        bool complete = EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            try { return callback(window, parameter); }
            catch (Exception error) { callbackError = error; return false; }
        }, IntPtr.Zero);
        if (callbackError != null)
            throw new InvalidOperationException("Native window enumeration failed.", callbackError);
        if (!complete)
            throw new InvalidOperationException("Native window enumeration did not complete.");
    }

    public static IntPtr FindVisiblePopupMenu(uint expectedProcessId) {
        IntPtr match = IntPtr.Zero;
        int matches = 0;
        EnumerateWindowsChecked(delegate(IntPtr window, IntPtr parameter) {
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
        });
        if (matches > 1) {
            throw new InvalidOperationException("More than one visible native menu popup was found.");
        }
        return match;
    }

    public static NativePopupMeasurement[] ReadVisibleNativeMenuPopups(uint expectedProcessId) {
        List<NativePopupMeasurement> rows = new List<NativePopupMeasurement>();
        EnumerateWindowsChecked(delegate(IntPtr window, IntPtr parameter) {
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
        });
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
    public static long[] ReadBoundCursor(IntPtr main, uint expectedProcessId) {
        Point point = ReadCursor();
        IntPtr hit = WindowFromPoint(point);
        uint processId;
        IntPtr root = GetAncestor(hit, 2);
        if (hit == IntPtr.Zero || root != main || GetWindowThreadProcessId(hit, out processId) == 0
            || processId != expectedProcessId)
            throw new InvalidOperationException("Appearance cursor is outside the bound main window.");
        return new [] { (long)point.X, point.Y, hit.ToInt64(), root.ToInt64() };
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
    public static void PressLeftButton() { SendMouseButton(0x0002); }
    public static void ReleaseLeftButton() { SendMouseButton(0x0004); }
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wParam,
        IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    public static void PopOwnedTooltip(IntPtr tooltip, uint expectedProcessId) {
        uint processId;
        StringBuilder name = new StringBuilder(64);
        if (GetWindowThreadProcessId(tooltip, out processId) == 0 || processId != expectedProcessId
            || GetClassName(tooltip, name, name.Capacity) == 0
            || !String.Equals(name.ToString(), "tooltips_class32", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Tooltip dismissal target is not owned by the bound application.");
        IntPtr result;
        if (SendMessageTimeoutW(tooltip, 0x041C, IntPtr.Zero, IntPtr.Zero, 3, 500, out result) == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Tooltip dismissal failed or timed out.");
    }
    public static int ReadDefaultPushButtonId(IntPtr button) {
        long code = SendMessageW(button, 0x0087, IntPtr.Zero, IntPtr.Zero).ToInt64();
        if ((code & 0x2010) != 0x2010 || (code & 0x0020) != 0) return 0;
        return GetDlgCtrlID(button);
    }
    public static int ReadButtonState(IntPtr button) {
        if (button == IntPtr.Zero) throw new ArgumentException("Button handle is missing.");
        return checked((int)SendMessageW(button, 0x00F2, IntPtr.Zero, IntPtr.Zero).ToInt64());
    }
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

    [StructLayout(LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    public struct NativeLogFont {
        public int Height, Width, Escapement, Orientation, Weight;
        public byte Italic, Underline, StrikeOut, CharSet, OutPrecision, ClipPrecision, Quality, PitchAndFamily;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeNonClientMetrics {
        public uint Size;
        public int BorderWidth, ScrollWidth, ScrollHeight, CaptionWidth, CaptionHeight;
        public NativeLogFont CaptionFont;
        public int SmallCaptionWidth, SmallCaptionHeight;
        public NativeLogFont SmallCaptionFont;
        public int MenuWidth, MenuHeight;
        public NativeLogFont MenuFont, StatusFont, MessageFont;
        public int PaddedBorderWidth;
    }
    public class WindowRenderingEnvironment {
        public long Context;
        public int Awareness;
        public bool PerMonitorV2;
        public Rect Client;
        public uint Dpi;
        public NativeLogFont MessageFont, StatusFont;
    }
    [DllImport("user32.dll")] private static extern IntPtr GetWindowDpiAwarenessContext(IntPtr window);
    [DllImport("user32.dll")] private static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AreDpiAwarenessContextsEqual(IntPtr first, IntPtr second);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfoForDpi(uint action, uint parameter,
        ref NativeNonClientMetrics value, uint flags, uint dpi);
    public static WindowRenderingEnvironment ReadWindowRenderingEnvironment(IntPtr window, uint expectedProcessId) {
        uint processId;
        if (GetWindowThreadProcessId(window, out processId) == 0 || processId != expectedProcessId)
            throw new InvalidOperationException("Rendering environment target is outside the bound process.");
        IntPtr context = GetWindowDpiAwarenessContext(window);
        if (context == IntPtr.Zero) throw new InvalidOperationException("Target DPI awareness context is missing.");
        Rect client;
        Point origin = new Point();
        if (!GetClientRect(window, out client) || !ClientToScreen(window, ref origin))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (client.Left != 0 || client.Top != 0 || client.Right <= 0 || client.Bottom <= 0)
            throw new InvalidOperationException("Target client geometry is invalid.");
        uint dpi = GetDpiForWindow(window);
        if (dpi == 0) throw new InvalidOperationException("Target DPI is missing.");
        NativeNonClientMetrics metrics = new NativeNonClientMetrics {
            Size = (uint)Marshal.SizeOf(typeof(NativeNonClientMetrics))
        };
        if (!SystemParametersInfoForDpi(0x29, metrics.Size, ref metrics, 0, dpi))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return new WindowRenderingEnvironment {
            Context = context.ToInt64(), Awareness = GetAwarenessFromDpiAwarenessContext(context),
            PerMonitorV2 = AreDpiAwarenessContextsEqual(context, new IntPtr(-4)), Dpi = dpi,
            Client = new Rect { Left = origin.X, Top = origin.Y,
                Right = checked(origin.X + client.Right), Bottom = checked(origin.Y + client.Bottom) },
            MessageFont = metrics.MessageFont, StatusFont = metrics.StatusFont
        };
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

    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadSnapshot {
        public uint Size, Flags;
        public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public Rect CaretRect;
    }
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadSnapshot info);
    [DllImport("user32.dll")]
    private static extern int GetDlgCtrlID(IntPtr window);
    public static long[] ReadGuiThreadSnapshot(IntPtr mainWindow, uint expectedProcessId) {
        uint processId;
        uint thread = GetWindowThreadProcessId(mainWindow, out processId);
        if (thread == 0 || processId != expectedProcessId)
            throw new InvalidOperationException("GUI thread target differs from bound application.");
        GuiThreadSnapshot info = new GuiThreadSnapshot();
        info.Size = (uint)Marshal.SizeOf(typeof(GuiThreadSnapshot));
        if (!GetGUIThreadInfo(thread, ref info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (info.Focus == IntPtr.Zero || GetWindowThreadProcessId(info.Focus, out processId) == 0
            || processId != expectedProcessId || GetAncestor(info.Focus, 2) != mainWindow)
            throw new InvalidOperationException("Native focus is outside the bound main window.");
        return new [] { info.Focus.ToInt64(), info.Capture.ToInt64(), (long)GetDlgCtrlID(info.Focus) };
    }

    public static int[] TryReadScrollInfo(IntPtr window, int bar) {
        NativeScrollInfo info = new NativeScrollInfo();
        info.Size = (uint)Marshal.SizeOf(typeof(NativeScrollInfo));
        info.Mask = 0x17;
        if (!GetScrollInfo(window, bar, ref info)) return null;
        return new [] { info.Minimum, info.Maximum, (int)info.Page, info.Position, info.TrackPosition };
    }

    public static int[] SetListHorizontalViewport(IntPtr window, uint expectedProcessId) {
        uint processId;
        StringBuilder className = new StringBuilder(128);
        if (GetWindowThreadProcessId(window, out processId) == 0 || processId != expectedProcessId
            || GetClassName(window, className, className.Capacity) == 0
            || className.ToString() != "SysListView32")
            throw new InvalidOperationException("Viewport target differs from bound native ListView.");
        int[] before = TryReadScrollInfo(window, 0);
        if (before == null || before[2] <= 0)
            throw new InvalidOperationException("Native horizontal viewport is unavailable.");
        long available = (long)before[1] - before[0] - before[2] + 1;
        if (available <= 0) throw new InvalidOperationException("Native ListView has no horizontal overflow.");
        int requested = checked((int)(before[0] + (available * 45 + 50) / 100));
        // Normalize the path as well as its endpoint: native XOR focus chrome
        // cannot be copied through differing small scroll deltas consistently.
        int resetDelta = checked(before[0] - before[3]);
        if (resetDelta != 0) {
            IntPtr resetResult;
            if (SendMessageTimeoutW(window, 0x1014, new IntPtr(resetDelta), IntPtr.Zero,
                    3, 500, out resetResult) == IntPtr.Zero || resetResult == IntPtr.Zero)
                throw new InvalidOperationException("Native ListView viewport reset failed.");
        }
        int[] reset = TryReadScrollInfo(window, 0);
        if (reset == null || reset[0] != before[0] || reset[1] != before[1]
            || reset[2] != before[2] || reset[3] != before[0] || reset[4] != before[0])
            throw new InvalidOperationException("Native ListView viewport reset did not settle exactly.");
        int delta = checked(requested - reset[3]);
        if (delta != 0) {
            IntPtr result;
            // LVM_SCROLL uses scalar pixel deltas in report view; no remote pointer is passed.
            if (SendMessageTimeoutW(window, 0x1014, new IntPtr(delta), IntPtr.Zero,
                    3, 500, out result) == IntPtr.Zero || result == IntPtr.Zero)
                throw new InvalidOperationException("Native ListView viewport request failed.");
        }
        int[] after = TryReadScrollInfo(window, 0);
        if (after == null || after[0] != before[0] || after[1] != before[1]
            || after[2] != before[2] || after[3] != requested || after[4] != requested)
            throw new InvalidOperationException("Native ListView viewport did not settle exactly.");
        return new [] { requested, after[3] };
    }
    public static IntPtr ReadBoundListHeader(IntPtr list, uint expectedProcessId) {
        uint processId;
        IntPtr header;
        if (GetWindowThreadProcessId(list, out processId) == 0 || processId != expectedProcessId
            || SendMessageTimeoutW(list, 0x101F, IntPtr.Zero, IntPtr.Zero, 3, 500, out header) == IntPtr.Zero
            || header == IntPtr.Zero || GetAncestor(header, 1) != list
            || GetWindowThreadProcessId(header, out processId) == 0 || processId != expectedProcessId)
            throw new InvalidOperationException("Native header is outside the bound ListView.");
        StringBuilder className = new StringBuilder(128);
        if (GetClassName(header, className, className.Capacity) == 0 || className.ToString() != "SysHeader32")
            throw new InvalidOperationException("Native ListView header class differs.");
        return header;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct UiColor { public byte A, R, G, B; }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int ReadUiColor(IntPtr instance, int colorType, out UiColor color);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int QueryUiInterface(IntPtr instance, ref Guid iid, out IntPtr value);
    [DllImport("combase.dll")]
    private static extern int RoInitialize(uint initType);
    [DllImport("combase.dll")]
    private static extern void RoUninitialize();
    [DllImport("combase.dll", CharSet = CharSet.Unicode)]
    private static extern int WindowsCreateString(string source, uint length, out IntPtr value);
    [DllImport("combase.dll")]
    private static extern int WindowsDeleteString(IntPtr value);
    [DllImport("combase.dll")]
    private static extern int RoActivateInstance(IntPtr classId, out IntPtr instance);
    public static byte[] ReadSystemForegroundColor() {
        int initialized = RoInitialize(1);
        if (initialized < 0 && initialized != unchecked((int)0x80010106))
            Marshal.ThrowExceptionForHR(initialized);
        IntPtr classId = IntPtr.Zero, instance = IntPtr.Zero, settings = IntPtr.Zero;
        try {
            const string runtimeClass = "Windows.UI.ViewManagement.UISettings";
            int result = WindowsCreateString(runtimeClass, (uint)runtimeClass.Length, out classId);
            if (result < 0) Marshal.ThrowExceptionForHR(result);
            result = RoActivateInstance(classId, out instance);
            if (result < 0) Marshal.ThrowExceptionForHR(result);
            Guid iid = new Guid("03021be4-5254-4781-8194-5168f7d06d7b");
            var query = (QueryUiInterface)Marshal.GetDelegateForFunctionPointer(
                Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance)), typeof(QueryUiInterface));
            result = query(instance, ref iid, out settings);
            if (result < 0) Marshal.ThrowExceptionForHR(result);
            // IUISettings3 inherits IInspectable; GetColorValue is its first method.
            IntPtr method = Marshal.ReadIntPtr(Marshal.ReadIntPtr(settings), 6 * IntPtr.Size);
            var read = (ReadUiColor)Marshal.GetDelegateForFunctionPointer(method, typeof(ReadUiColor));
            UiColor color;
            result = read(settings, 1, out color); // UIColorType.Foreground
            if (result < 0) Marshal.ThrowExceptionForHR(result);
            return new [] { color.A, color.R, color.G, color.B };
        }
        finally {
            if (settings != IntPtr.Zero) Marshal.Release(settings);
            if (instance != IntPtr.Zero) Marshal.Release(instance);
            if (classId != IntPtr.Zero) WindowsDeleteString(classId);
            if (initialized >= 0) RoUninitialize();
        }
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wParam,
        StringBuilder lParam, uint flags, uint timeout, out IntPtr result);
    public static string ReadBoundStaticText(IntPtr control, IntPtr dialog, uint expectedProcessId) {
        uint processId;
        StringBuilder className = new StringBuilder(128);
        if (GetWindowThreadProcessId(control, out processId) == 0 || processId != expectedProcessId
            || GetAncestor(control, 1) != dialog || GetDlgCtrlID(control) != 1002
            || GetClassName(control, className, className.Capacity) == 0
            || !String.Equals(className.ToString(), "Static", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Text target differs from bound prompt STATIC.");
        StringBuilder text = new StringBuilder(256);
        IntPtr result;
        // WM_GETTEXT is below WM_USER, so Windows marshals its text buffer cross-process.
        if (SendMessageTimeoutW(control, 0x000D, new IntPtr(text.Capacity), text, 3, 500, out result) == IntPtr.Zero
            || result.ToInt64() <= 0 || result.ToInt64() >= text.Capacity || result.ToInt64() != text.Length)
            throw new InvalidOperationException("Bound prompt STATIC text query failed.");
        return text.ToString();
    }

    public static int[] TryReadScrollBarBounds(IntPtr window, int bar) {
        NativeScrollBarInfo info = new NativeScrollBarInfo {
            Size = (uint)Marshal.SizeOf(typeof(NativeScrollBarInfo)),
            States = new uint[6]
        };
        if (!GetScrollBarInfo(window, bar == 0 ? -6 : -5, ref info)) return null;
        return new [] { info.Bounds.Left, info.Bounds.Top, info.Bounds.Right, info.Bounds.Bottom,
            info.ThumbTop, info.ThumbBottom, checked((int)info.States[0]) };
    }

    public static int[] ReadScrollBarComponents(IntPtr window, int bar) {
        if (bar != 0 && bar != 1) throw new ArgumentException("Invalid scrollbar axis.");
        NativeScrollBarInfo info = new NativeScrollBarInfo {
            Size = (uint)Marshal.SizeOf(typeof(NativeScrollBarInfo)), States = new uint[6]
        };
        if (!GetScrollBarInfo(window, bar == 0 ? -6 : -5, ref info))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return new [] { info.Bounds.Left, info.Bounds.Top, info.Bounds.Right, info.Bounds.Bottom,
            info.LineButtonSize, info.ThumbTop, info.ThumbBottom,
            checked((int)info.States[0]), checked((int)info.States[1]),
            checked((int)info.States[2]), checked((int)info.States[3]),
            checked((int)info.States[4]), checked((int)info.States[5]) };
    }

    public static WindowMeasurement[] ReadProcessTopLevelWindows(uint expectedProcessId) {
        List<WindowMeasurement> windows = new List<WindowMeasurement>();
        EnumerateWindowsChecked(delegate(IntPtr window, IntPtr parameter) {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) return true;
            Rect rect;
            if (!GetWindowRect(window, out rect)) throw new Win32Exception(Marshal.GetLastWin32Error());
            string[] description = DescribeWindow(window);
            windows.Add(new WindowMeasurement {
                Handle = window.ToInt64(), Owner = Int64.Parse(description[1]), ProcessId = processId,
                ClassName = description[3], Title = description[4], Visible = description[5] == "true",
                Left = rect.Left, Top = rect.Top, Right = rect.Right, Bottom = rect.Bottom
            });
            if (windows.Count > 128) throw new InvalidOperationException("Process window inventory exceeded its bound.");
            return true;
        });
        return windows.ToArray();
    }

    public static long ReadListViewTooltip(IntPtr listView) {
        return SendMessageW(listView, 0x104E, IntPtr.Zero, IntPtr.Zero).ToInt64();
    }

    public static int ReadListViewColumnWidth(IntPtr listView, int column) {
        return checked((int)SendMessageW(listView, 0x101D, new IntPtr(column), IntPtr.Zero).ToInt64());
    }

    private static void AssertBoundListView(IntPtr listView, uint expectedProcessId) {
        uint processId;
        StringBuilder className = new StringBuilder(128);
        if (GetWindowThreadProcessId(listView, out processId) == 0 || processId != expectedProcessId
            || GetClassName(listView, className, className.Capacity) == 0
            || className.ToString() != "SysListView32")
            throw new InvalidOperationException("Native ListView query target differs from bound application.");
    }

    public static int ReadBoundListViewTopIndex(IntPtr listView, uint expectedProcessId) {
        AssertBoundListView(listView, expectedProcessId);
        IntPtr result;
        if (SendMessageTimeoutW(listView, 0x1027, IntPtr.Zero, IntPtr.Zero, 3, 500, out result) == IntPtr.Zero)
            throw new InvalidOperationException("Bound ListView top index query timed out.");
        return checked((int)result.ToInt64());
    }

    public static int[] ReadBoundListViewClientBounds(IntPtr listView, uint expectedProcessId) {
        AssertBoundListView(listView, expectedProcessId);
        Rect client;
        Point origin = new Point();
        if (!GetClientRect(listView, out client) || !ClientToScreen(listView, ref origin)
            || client.Left != 0 || client.Top != 0 || client.Right <= 0 || client.Bottom <= 0)
            throw new InvalidOperationException("Bound ListView client geometry is invalid.");
        return new [] { origin.X, origin.Y, checked(origin.X + client.Right), checked(origin.Y + client.Bottom) };
    }

    public static int[] ReadBoundHeaderColumnOrder(IntPtr listView, uint expectedProcessId) {
        AssertBoundListView(listView, expectedProcessId);
        IntPtr header = ReadBoundListHeader(listView, expectedProcessId);
        IntPtr result;
        if (SendMessageTimeoutW(header, 0x1200, IntPtr.Zero, IntPtr.Zero, 3, 500, out result) == IntPtr.Zero
            || result.ToInt64() != 8)
            throw new InvalidOperationException("Bound ListView header does not have eight columns.");
        int[] order = new int[8];
        HashSet<int> seen = new HashSet<int>();
        for (int position = 0; position < order.Length; position++) {
            if (SendMessageTimeoutW(header, 0x120F, new IntPtr(position), IntPtr.Zero, 3, 500, out result) == IntPtr.Zero)
                throw new InvalidOperationException("Bound ListView header order query timed out.");
            int index = checked((int)result.ToInt64());
            if (index < 0 || index >= order.Length || !seen.Add(index))
                throw new InvalidOperationException("Bound ListView header order is invalid.");
            order[position] = index;
        }
        return order;
    }



    public static string OsVersion() {
        RTL_OSVERSIONINFOEX value = new RTL_OSVERSIONINFOEX();
        value.size = (uint)Marshal.SizeOf(typeof(RTL_OSVERSIONINFOEX));
        int status = RtlGetVersion(ref value);
        if (status != 0) { throw new Win32Exception(status); }
        return value.major + "." + value.minor + "." + value.build;
    }
}

public sealed class DarkReNamerPerformanceSample {
    public string Phase { get; set; }
    public long ElapsedMs { get; set; }
    public long CpuMs { get; set; }
    public long PrivateBytes { get; set; }
    public long WorkingSetBytes { get; set; }
    public int Threads { get; set; }
    public int Handles { get; set; }
    public uint GdiObjects { get; set; }
    public double UiResponseMs { get; set; }
    public double ResourceCollectionMs { get; set; }
    public double SampleGapMs { get; set; }
    public string ProbeStatus { get; set; }
    public int ProbeErrorCode { get; set; }
}

// Observer-only bounded sampler. It does not inject a thread into the product.
public sealed class DarkReNamerPerformanceSampler : IDisposable {
    [DllImport("user32.dll", SetLastError=true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError=true)]
    private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wParam,
        IntPtr lParam, uint flags, uint timeoutMs, out IntPtr result);
    [DllImport("user32.dll", SetLastError=true)]
    private static extern uint GetGuiResources(IntPtr process, uint flags);
    [DllImport("kernel32.dll", EntryPoint="SetLastError")]
    private static extern void SetLastErrorNative(uint code);
    private readonly System.Diagnostics.Process process;
    private readonly IntPtr window;
    private readonly long startTicks;
    private readonly System.Diagnostics.Stopwatch watch;
    private readonly System.Threading.Timer timer;
    private readonly object gate = new object();
    private readonly List<DarkReNamerPerformanceSample> samples = new List<DarkReNamerPerformanceSample>();
    private string failure;
    private string phase = "empty-idle";
    private long previousSampleTicks;
    private bool stopped;

    public static string ClassifyProbe(bool responsive, int errorCode) {
        return responsive ? "success" : errorCode == 1460 ? "timeout" : "failure_unknown";
    }

    public DarkReNamerPerformanceSampler(System.Diagnostics.Process ownedProcess, IntPtr ownedWindow) {
        if (ownedProcess == null || ownedWindow == IntPtr.Zero) throw new ArgumentException("Missing owned target.");
        uint pid;
        if (GetWindowThreadProcessId(ownedWindow, out pid) == 0 || pid != (uint)ownedProcess.Id)
            throw new InvalidOperationException("Sampler HWND does not belong to the owned process.");
        process = ownedProcess; window = ownedWindow; startTicks = process.StartTime.ToUniversalTime().Ticks;
        watch = System.Diagnostics.Stopwatch.StartNew();
        timer = new System.Threading.Timer(Sample, null, 0, 200);
    }
    private void Sample(object ignored) {
        if (!System.Threading.Monitor.TryEnter(gate)) return;
        try {
            if (stopped || samples.Count >= 3000 || watch.ElapsedMilliseconds > 600000) return;
            process.Refresh();
            uint pid;
            if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != startTicks ||
                GetWindowThreadProcessId(window, out pid) == 0 || pid != (uint)process.Id)
                throw new InvalidOperationException("Sampler target identity changed.");
            IntPtr result;
            SetLastErrorNative(0);
            long begun = System.Diagnostics.Stopwatch.GetTimestamp();
            bool responsive = SendMessageTimeoutW(window, 0, IntPtr.Zero, IntPtr.Zero, 3, 50, out result) != IntPtr.Zero;
            long probeEnded = System.Diagnostics.Stopwatch.GetTimestamp();
            // SetLastError=true cached this call's native error; QPC does not replace that cache.
            int probeError = responsive ? 0 : Marshal.GetLastWin32Error();
            string probeStatus = ClassifyProbe(responsive, probeError);
            long cpuMs = (long)process.TotalProcessorTime.TotalMilliseconds;
            long privateBytes = process.PrivateMemorySize64;
            long workingSetBytes = process.WorkingSet64;
            int threads = process.Threads.Count;
            int handles = process.HandleCount;
            uint gdiObjects = GetGuiResources(process.Handle, 0);
            long collected = System.Diagnostics.Stopwatch.GetTimestamp();
            double ticksPerMs = (double)System.Diagnostics.Stopwatch.Frequency / 1000.0;
            samples.Add(new DarkReNamerPerformanceSample {
                Phase = phase,
                ElapsedMs = watch.ElapsedMilliseconds,
                CpuMs = cpuMs, PrivateBytes = privateBytes, WorkingSetBytes = workingSetBytes,
                Threads = threads, Handles = handles, GdiObjects = gdiObjects,
                UiResponseMs = (probeEnded - begun) / ticksPerMs,
                ResourceCollectionMs = (collected - probeEnded) / ticksPerMs,
                SampleGapMs = previousSampleTicks == 0 ? 0 : (begun - previousSampleTicks) / ticksPerMs,
                ProbeStatus = probeStatus, ProbeErrorCode = probeError,
            });
            previousSampleTicks = begun;
        } catch (Exception error) { failure = error.GetType().Name + ": " + error.Message; stopped = true; }
        finally { System.Threading.Monitor.Exit(gate); }
    }
    public void SetPhase(string value) {
        if (String.IsNullOrEmpty(value) || value.Length > 64) throw new ArgumentException("Invalid sample phase.");
        lock (gate) { if (stopped) throw new InvalidOperationException("Sampler stopped."); phase = value; }
    }
    public DarkReNamerPerformanceSample[] Stop() {
        timer.Change(System.Threading.Timeout.Infinite, System.Threading.Timeout.Infinite);
        lock (gate) {
            stopped = true; timer.Dispose();
            if (failure != null) throw new InvalidOperationException("Performance sampling failed: " + failure);
            if (samples.Count == 0) throw new InvalidOperationException("Performance sampler produced no samples.");
            return samples.ToArray();
        }
    }
    public void Dispose() { if (!stopped) Stop(); }
}

// Pointer-free, versioned WM_APP status query against the exact owned main HWND.
// No process memory or application object crosses this diagnostic boundary.
public sealed class DarkReNamerIconStatusSnapshot {
    public ulong Session, Generation, StatusRevision, ModelRevision;
    public uint Bootstrap, Queued, InFlight, Undrained, UnresolvedRows, Cursor;
    public uint Settled, WorkerJoined, ReconcileRows, BatchAck, DemandExhausted, DemandRemaining;
}

public static class DarkReNamerIconStatusObserver {
    private const uint StatusMessage = 0x8056; // WM_APP + 0x56, version 1.
    [DllImport("user32.dll", SetLastError=true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError=true)]
    private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wParam,
        IntPtr lParam, uint flags, uint timeoutMs, out IntPtr result);

    private static uint Scalar(IntPtr window, int selector) {
        IntPtr result;
        if (SendMessageTimeoutW(window, StatusMessage, new IntPtr(selector), IntPtr.Zero,
                                3, 50, out result) == IntPtr.Zero)
            throw new InvalidOperationException("Icon status query timed out or failed.");
        long value = result.ToInt64();
        if (value == -1) throw new InvalidOperationException("Icon status query is unpublished or unstable.");
        if (value < 0 || value > uint.MaxValue)
            throw new InvalidOperationException("Icon status query returned a non-scalar value.");
        return checked((uint)value);
    }

    private static ulong Pair(IntPtr window, int lowSelector) {
        uint low = Scalar(window, lowSelector);
        uint high = Scalar(window, lowSelector + 1);
        return ((ulong)high << 32) | low;
    }

    public static DarkReNamerIconStatusSnapshot ReadBound(
        System.Diagnostics.Process process, IntPtr window, long expectedStartUtcTicks) {
        if (process == null || window == IntPtr.Zero || process.HasExited ||
            process.StartTime.ToUniversalTime().Ticks != expectedStartUtcTicks)
            throw new InvalidOperationException("Icon status target process identity changed.");
        uint pid;
        if (GetWindowThreadProcessId(window, out pid) == 0 || pid != (uint)process.Id)
            throw new InvalidOperationException("Icon status HWND does not belong to the owned process.");
        for (int attempt = 0; attempt < 4; attempt++) {
            try {
                ulong before = Pair(window, 15);
                if ((before & 1) != 0) continue;
                if (Scalar(window, 0) != 1)
                    throw new InvalidOperationException("Unsupported icon status query version.");
                ulong modelBefore = Pair(window, 19);
                DarkReNamerIconStatusSnapshot value = new DarkReNamerIconStatusSnapshot {
                    Session = Pair(window, 1), Generation = Pair(window, 3),
                    Bootstrap = Scalar(window, 5), Queued = Scalar(window, 6),
                    InFlight = Scalar(window, 7), Undrained = Scalar(window, 8),
                    UnresolvedRows = Scalar(window, 9), Cursor = Scalar(window, 10),
                    Settled = Scalar(window, 11), WorkerJoined = Scalar(window, 12),
                    ReconcileRows = Scalar(window, 13), BatchAck = Scalar(window, 14),
                    DemandExhausted = Scalar(window, 17), DemandRemaining = Scalar(window, 18),
                };
                ulong modelAfter = Pair(window, 19);
                ulong after = Pair(window, 15);
                if (before != after || (after & 1) != 0 || modelBefore != modelAfter) continue;
                if (value.Bootstrap > 2 || value.Settled > 1 || value.WorkerJoined > 1 ||
                    value.DemandExhausted > 1)
                    throw new InvalidOperationException("Icon status scalar flags are invalid.");
                if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != expectedStartUtcTicks ||
                    GetWindowThreadProcessId(window, out pid) == 0 || pid != (uint)process.Id)
                    throw new InvalidOperationException("Icon status target changed during query.");
                value.ModelRevision = modelAfter;
                value.StatusRevision = after;
                return value;
            }
            catch (InvalidOperationException error) {
                if (error.Message != "Icon status query is unpublished or unstable.") throw;
            }
        }
        throw new InvalidOperationException("Icon status query did not produce a stable published snapshot.");
    }
}
'@
}
