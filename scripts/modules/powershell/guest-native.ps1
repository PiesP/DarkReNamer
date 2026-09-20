function Initialize-NativeCapture {
    if (-not ('DarkReNamerVmNative' -as [type])) {
        Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DarkReNamerVmNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }

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

    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo {
        public uint Size;
        public Rect Monitor;
        public Rect Work;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HighContrast {
        public uint Size;
        public uint Flags;
        public IntPtr DefaultScheme;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileId128 {
        public ulong LowPart;
        public ulong HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInfo {
        public ulong VolumeSerialNumber;
        public FileId128 FileId;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo information);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HighContrast value, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SwitchDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseDesktop(IntPtr desktop);

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string path, uint access, uint share, IntPtr securityAttributes,
        uint creationDisposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        IntPtr file, out ByHandleFileInformation information);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(
        IntPtr file, int informationClass, out FileIdInfo information, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr token, int informationClass, out int information, uint length, out uint returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static string GetFileIdentity(string path) {
        IntPtr file = CreateFile(path, 0x80, 1 | 2 | 4, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
        if (file == new IntPtr(-1)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(file, out information)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            ulong index = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
            return information.VolumeSerialNumber.ToString("x8") + ":" + index.ToString("x16");
        }
        finally {
            CloseHandle(file);
        }
    }

    public static WindowMeasurement[] ReadProcessTopLevelWindows(uint expectedProcessId) {
        List<WindowMeasurement> windows = new List<WindowMeasurement>();
        bool exceededBound = false;
        bool completed = EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) return true;
            if (windows.Count >= 128) {
                exceededBound = true;
                return false;
            }
            Rect rect;
            if (!GetWindowRect(window, out rect)) rect = new Rect();
            System.Text.StringBuilder className = new System.Text.StringBuilder(128);
            System.Text.StringBuilder title = new System.Text.StringBuilder(1024);
            GetClassName(window, className, className.Capacity);
            GetWindowTextW(window, title, title.Capacity);
            windows.Add(new WindowMeasurement {
                Handle = window.ToInt64(),
                Owner = GetWindow(window, 4).ToInt64(),
                ProcessId = processId,
                ClassName = className.ToString(),
                Title = title.ToString(),
                Visible = IsWindowVisible(window),
                Left = rect.Left,
                Top = rect.Top,
                Right = rect.Right,
                Bottom = rect.Bottom
            });
            return true;
        }, IntPtr.Zero);
        if (exceededBound) {
            throw new InvalidOperationException("Process window inventory exceeded its bound.");
        }
        if (!completed) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        return windows.ToArray();
    }

    public static void RequestWindowClose(IntPtr window) {
        if (!PostMessageW(window, 0x0010, IntPtr.Zero, IntPtr.Zero)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static string[] GetFullFileIdentity(string path) {
        IntPtr file = CreateFile(path, 0x80, 1 | 2 | 4, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (file == new IntPtr(-1)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            FileIdInfo information;
            if (!GetFileInformationByHandleEx(
                    file, 18, out information, (uint)Marshal.SizeOf(typeof(FileIdInfo)))) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            return new string[] {
                information.VolumeSerialNumber.ToString("x16"),
                FormatFileIdNumeric(information.FileId.LowPart, information.FileId.HighPart)
            };
        }
        finally {
            CloseHandle(file);
        }
    }

    public static string FormatFileIdNumeric(ulong lowPart, ulong highPart) {
        // FILE_ID_128 stores the little-endian bytes of the product's u128.
        // Render the numeric value so this matches u128::from_le_bytes.
        return highPart.ToString("x16") + lowPart.ToString("x16");
    }

    public static int[] ReadMonitorInfo(IntPtr window) {
        IntPtr monitor = MonitorFromWindow(window, 2);
        if (monitor == IntPtr.Zero) {
            throw new InvalidOperationException("MonitorFromWindow returned no target monitor.");
        }
        MonitorInfo information = new MonitorInfo();
        information.Size = (uint)Marshal.SizeOf(typeof(MonitorInfo));
        if (!GetMonitorInfoW(monitor, ref information)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        return new int[] {
            information.Monitor.Left, information.Monitor.Top,
            information.Monitor.Right, information.Monitor.Bottom,
            information.Work.Left, information.Work.Top,
            information.Work.Right, information.Work.Bottom
        };
    }

    public static uint GetHighContrastFlags() {
        HighContrast value = new HighContrast();
        value.Size = (uint)Marshal.SizeOf(typeof(HighContrast));
        if (!SystemParametersInfo(0x42, value.Size, ref value, 0)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        return value.Flags;
    }

    public static bool InputDesktopAvailable() {
        IntPtr desktop = OpenInputDesktop(0, false, 0x0100);
        if (desktop == IntPtr.Zero) return false;
        try { return SwitchDesktop(desktop); }
        finally { CloseDesktop(desktop); }
    }

    public static bool IsProcessElevated(uint processId) {
        IntPtr process = OpenProcess(0x1000, false, processId);
        if (process == IntPtr.Zero) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            IntPtr token;
            if (!OpenProcessToken(process, 0x0008, out token)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            try {
                int elevation;
                uint returned;
                if (!GetTokenInformation(token, 20, out elevation, 4, out returned) || returned != 4) {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
                return elevation != 0;
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }
}
'@
    }
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName UIAutomationClientsideProviders
    if (-not ('DarkReNamerVmAutomation' -as [type])) {
        $automationReferences = @(
            [Windows.Automation.AutomationElement].Assembly.Location
            [Windows.Automation.AutomationProperty].Assembly.Location
            [UIAutomationClientsideProviders.UIAutomationClientSideProviders].Assembly.Location
        )
        Add-Type -ReferencedAssemblies $automationReferences -TypeDefinition @'
public static class DarkReNamerVmAutomation {
    // UIA's default-proxy stack walk cannot inspect PowerShell dynamic frames.
    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    public static void Initialize() {
        var providerType = typeof(UIAutomationClientsideProviders.UIAutomationClientSideProviders);
        var providerName = providerType.Assembly.GetName();
        // .NET 8 changed the assembly name's Side casing while the namespace stayed stable.
        providerName.Name = providerType.Namespace;
        System.Windows.Automation.ClientSettings.RegisterClientSideProviderAssembly(providerName);
    }
}
'@
    }
    [DarkReNamerVmAutomation]::Initialize()
}
function Get-VmAutomatedCanonicalRootPath {
    param([Parameter(Mandatory)][string] $Path)

    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw 'VM-Automated fixture root must be drive-absolute.'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'VM-Automated fixture root must be an ordinary directory.'
    }
    $full = $item.FullName
    $ordinaryDrive = $full -cmatch '^[A-Za-z]:\\.'
    $verbatimDrive = $full -cmatch '^\\\\\?\\[A-Za-z]:\\.'
    if ((-not $ordinaryDrive -and -not $verbatimDrive) -or
        $full.StartsWith('\\\\.\\', [StringComparison]::Ordinal) -or
        $full -cmatch '^\\\\(?!\?\\)') {
        throw 'VM-Automated fixture root must use a canonical local drive path.'
    }
    $relative = if ($verbatimDrive) { $full.Substring(7) } else { $full.Substring(3) }
    $components = @($relative.Split([char]92))
    if ([string]::IsNullOrEmpty($relative) -or $components -contains '' -or
        @($components | Where-Object {
            $_ -in @('.', '..') -or $_.EndsWith('.', [StringComparison]::Ordinal) -or
            $_.EndsWith(' ', [StringComparison]::Ordinal) -or
            $_.IndexOfAny([char[]]'<>:"/|?*') -ge 0 -or
            $_.Split('.')[0] -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
        }).Count -ne 0) {
        throw 'VM-Automated fixture root must not be a drive root or contain dot segments.'
    }
    $full
}
function Get-FullFileIdentity {
    param([Parameter(Mandatory)][string] $Path)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'FILE_ID_INFO observation requires Windows.'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (-not $item.PSIsContainer -and $item -isnot [IO.FileInfo])) {
        throw 'FILE_ID_INFO observation requires an ordinary file or directory.'
    }
    Initialize-NativeCapture
    $identity = [DarkReNamerVmNative]::GetFullFileIdentity($item.FullName)
    if ($identity.Count -ne 2 -or
        $identity[0] -cnotmatch '^[0-9a-f]{16}$' -or
        $identity[1] -cnotmatch '^[0-9a-f]{32}$') {
        throw 'FILE_ID_INFO observation returned a malformed identity.'
    }
    [ordered]@{
        volume_serial = $identity[0]
        file_id = $identity[1]
    }
}
function Initialize-TextScaleNative {
    if ('DarkReNamerTextScaleNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DarkReNamerTextScaleNative {
    private const int RpcChangedMode = unchecked((int)0x80010106);
    private const uint RoInitMultithreaded = 1;
    private static readonly Guid IidUiSettings2 = new Guid("bad82401-2721-44f9-bb91-2bb228be442f");

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int QueryInterfaceDelegate(IntPtr instance, ref Guid iid, out IntPtr value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate uint ReleaseDelegate(IntPtr instance);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int TextScaleFactorDelegate(IntPtr instance, out double value);

    [DllImport("combase.dll")]
    private static extern int RoInitialize(uint initType);
    [DllImport("combase.dll")]
    private static extern void RoUninitialize();
    [DllImport("combase.dll", CharSet=CharSet.Unicode)]
    private static extern int WindowsCreateString(string source, uint length, out IntPtr value);
    [DllImport("combase.dll")]
    private static extern int WindowsDeleteString(IntPtr value);
    [DllImport("combase.dll")]
    private static extern int RoActivateInstance(IntPtr classId, out IntPtr instance);

    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr SendMessageTimeoutW(
        IntPtr window, uint message, UIntPtr wParam, string lParam,
        uint flags, uint timeout, out UIntPtr result);

    private static IntPtr ReadVtableMethod(IntPtr instance, int slot) {
        if (instance == IntPtr.Zero) {
            throw new ArgumentException("A COM interface pointer is required.", "instance");
        }
        return Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), slot * IntPtr.Size);
    }

    private static void Release(ref IntPtr instance) {
        if (instance == IntPtr.Zero) { return; }
        var release = (ReleaseDelegate)Marshal.GetDelegateForFunctionPointer(
            ReadVtableMethod(instance, 2), typeof(ReleaseDelegate));
        release(instance);
        instance = IntPtr.Zero;
    }

    public static double ReadTextScaleFactor() {
        int initializeResult = RoInitialize(RoInitMultithreaded);
        bool uninitialize = initializeResult >= 0;
        if (initializeResult < 0 && initializeResult != RpcChangedMode) {
            Marshal.ThrowExceptionForHR(initializeResult);
        }

        IntPtr classId = IntPtr.Zero;
        IntPtr instance = IntPtr.Zero;
        IntPtr settings2 = IntPtr.Zero;
        try {
            const string runtimeClass = "Windows.UI.ViewManagement.UISettings";
            int result = WindowsCreateString(runtimeClass, (uint)runtimeClass.Length, out classId);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }
            result = RoActivateInstance(classId, out instance);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }

            var query = (QueryInterfaceDelegate)Marshal.GetDelegateForFunctionPointer(
                ReadVtableMethod(instance, 0), typeof(QueryInterfaceDelegate));
            Guid iid = IidUiSettings2;
            result = query(instance, ref iid, out settings2);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }

            var read = (TextScaleFactorDelegate)Marshal.GetDelegateForFunctionPointer(
                ReadVtableMethod(settings2, 6), typeof(TextScaleFactorDelegate));
            double value;
            result = read(settings2, out value);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }
            return value;
        }
        finally {
            Release(ref settings2);
            Release(ref instance);
            if (classId != IntPtr.Zero) { WindowsDeleteString(classId); }
            if (uninitialize) { RoUninitialize(); }
        }
    }

    public static void NotifyAccessibilitySettingChange() {
        UIntPtr result;
        SendMessageTimeoutW(
            new IntPtr(0xffff), 0x001A, UIntPtr.Zero, "Accessibility",
            0x0002, 5000, out result);
    }
}
'@
}
