function Read-RustTestSummary {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Stdout,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Stderr,

        [switch] $AllowZeroTests,
        [switch] $RefreshProfile
    )

    $pattern = '(?m)^test result: (ok|FAILED)\. ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored; ([0-9]+) measured; ([0-9]+) filtered out;(?:[^\r\n]*)\r?$'
    $matches = [regex]::Matches($Stdout, $pattern)
    if ($matches.Count -eq 0) {
        throw 'Rust test stdout must contain a test result summary.'
    }
    $summary = $matches[$matches.Count - 1]
    $passed = [int]::Parse($summary.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    $failed = [int]::Parse($summary.Groups[3].Value, [Globalization.CultureInfo]::InvariantCulture)
    $ignored = [int]::Parse($summary.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture)
    $filtered = [int]::Parse($summary.Groups[6].Value, [Globalization.CultureInfo]::InvariantCulture)
    if (-not $RefreshProfile -and $filtered -ne 0) {
        throw 'The final Rust test harness must not filter tests.'
    }
    if ($RefreshProfile -and ($summary.Groups[1].Value -cne 'ok' -or
        $passed -ne 1 -or $failed -ne 0 -or $ignored -ne 0 -or $filtered -lt 1)) {
        throw 'The fixed refresh diagnostic must select exactly one passing ignored test.'
    }
    if (-not $AllowZeroTests -and ($passed + $failed + $ignored) -eq 0) {
        throw 'A non-main Rust test harness reported zero tests.'
    }

    [pscustomobject]@{
        outcome = $summary.Groups[1].Value
        passed = $passed
        failed = $failed
        ignored = $ignored
        filtered = $filtered
    }
}
function New-PrivateDirectory {
    param(
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Leaf
    )

    $path = Join-Path $Parent $Leaf
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'A runtime directory is unsafe.'
        }
    }
    else {
        [void](New-Item -ItemType Directory -Path $path)
    }
    $path
}
function Resolve-JobBoundShortPath {
    param([Parameter(Mandatory)][string] $Path)

    Initialize-JobBoundProcessRuntime
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The isolated temporary root must be an ordinary directory.'
    }
    $shortPath = [DarkReNamerVmFileSystem]::GetShortPathName($item.FullName)
    if (-not [IO.Path]::IsPathRooted($shortPath) -or
        [string]::Equals($shortPath, $item.FullName, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The isolated temporary root has no usable short path for parent traversal.'
    }
    $shortPath
}
function New-ObserverFixtureDirectory {
    param(
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $RunnerSid
    )

    $parentItem = Get-Item -LiteralPath $Parent -Force -ErrorAction Stop
    if (-not $parentItem.PSIsContainer -or
        ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $Leaf -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'The protected observer fixture parent or leaf is unsafe.'
    }
    $path = Join-Path $parentItem.FullName $Leaf
    if (Test-Path -LiteralPath $path) {
        throw 'The protected observer fixture already exists.'
    }
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $runnerSidObject = [Security.Principal.SecurityIdentifier]::new($RunnerSid)
    $security.SetOwner($administratorSid)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($principalSid in @($administratorSid, $systemSid)) {
        [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $principalSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        ))
    }
    $directoryRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
    [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $runnerSidObject,
        $directoryRights,
        [Security.AccessControl.AccessControlType]::Allow
    ))
    [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $runnerSidObject,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [Security.AccessControl.PropagationFlags]::InheritOnly,
        [Security.AccessControl.AccessControlType]::Allow
    ))
    [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $path)
    $created = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (-not $created.PSIsContainer -or
        ($created.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The protected observer fixture could not be created as an ordinary directory.'
    }
    $path
}
function New-ObserverCandidateWriteDirectory {
    param(
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $RunnerSid
    )

    $parentItem = Get-Item -LiteralPath $Parent -Force -ErrorAction Stop
    if (-not $parentItem.PSIsContainer -or
        ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $Leaf -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'The protected candidate output parent or leaf is unsafe.'
    }
    $path = Join-Path $parentItem.FullName $Leaf
    if (Test-Path -LiteralPath $path) {
        throw 'The protected candidate output directory already exists.'
    }
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $runnerSidObject = [Security.Principal.SecurityIdentifier]::new($RunnerSid)
    $security.SetOwner($administratorSid)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($principalSid in @($administratorSid, $systemSid)) {
        [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $principalSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        ))
    }
    $directoryRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
    [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $runnerSidObject,
        $directoryRights,
        [Security.AccessControl.AccessControlType]::Allow
    ))
    [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $runnerSidObject,
        [Security.AccessControl.FileSystemRights]::Modify,
        [Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [Security.AccessControl.PropagationFlags]::InheritOnly,
        [Security.AccessControl.AccessControlType]::Allow
    ))
    [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $path)
    $created = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (-not $created.PSIsContainer -or
        ($created.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The protected candidate output directory could not be created safely.'
    }
    $path
}
function Assert-OrdinaryDirectoryTree {
    param([Parameter(Mandatory)][string] $Path)

    $observation = Get-VmAutomatedRuntimeRootObservation -Root $Path
    if (-not $observation.exists) {
        throw 'The runtime cleanup root does not exist.'
    }
}
function Invoke-TaskkillTree {
    param([Parameter(Mandatory)][int] $ProcessId)

    & "$env:SystemRoot\System32\taskkill.exe" /PID $ProcessId /T /F 2>$null | Out-Null
}
$script:VmTestOutputChannelLimitBytes = 4MB
$script:VmTestOutputAggregateLimitBytes = 8MB
$script:VmTestOutputSuiteLimitBytes = 64MB
function Initialize-JobBoundProcessRuntime {
    if ('DarkReNamerVmJobBoundProcess' -as [type]) { return }
    Add-Type @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class DarkReNamerVmJobBoundProcess : IDisposable {
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const uint HANDLE_FLAG_INHERIT = 0x00000001;
    private const uint HANDLE_LIST_ATTRIBUTE = 0x00020002;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const uint JOB_OBJECT_LIMIT_ACTIVE_PROCESS = 0x00000008;
    private const uint WAIT_OBJECT_0 = 0;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const int MAX_ENVIRONMENT_BLOCK_CHARS = 32767;
    private const uint TOKEN_ASSIGN_PRIMARY = 0x0001;
    private const uint TOKEN_DUPLICATE = 0x0002;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint TOKEN_ADJUST_DEFAULT = 0x0080;
    private const uint TOKEN_ADJUST_SESSIONID = 0x0100;
    private const int SECURITY_IMPERSONATION = 2;
    private const int TOKEN_TYPE = 8;
    private const int TOKEN_STATISTICS = 10;
    private const int TOKEN_LINKED_TOKEN = 19;
    private const int TOKEN_ELEVATION_TYPE = 18;
    private const int TOKEN_ELEVATION = 20;
    private const int TOKEN_SESSION_ID = 12;
    private const int TOKEN_USER = 1;
    private const int TOKEN_INTEGRITY_LEVEL = 25;
    private const int TOKEN_UI_ACCESS = 26;
    private const int TOKEN_ELEVATION_TYPE_FULL = 2;
    private const int TOKEN_ELEVATION_TYPE_LIMITED = 3;
    private const int TOKEN_PRIMARY = 1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
        public int dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation {
        public IntPtr hProcess, hThread;
        public uint dwProcessId, dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LinkedToken { public IntPtr Token; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Luid { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TokenStatistics {
        public Luid TokenId;
        public Luid AuthenticationId;
        public long ExpirationTime;
        public int TokenType;
        public int ImpersonationLevel;
        public uint DynamicCharged;
        public uint DynamicAvailable;
        public uint GroupCount;
        public uint PrivilegeCount;
        public Luid ModifiedId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicAccountingInformation {
        public long TotalUserTime, TotalKernelTime;
        public long ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }

    public sealed class JobTerminationReceipt {
        public uint ProcessId;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint ExitCode;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(
        string applicationName, StringBuilder commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags, IntPtr environment, string currentDirectory,
        ref StartupInfoEx startupInfo, out ProcessInformation processInformation);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessWithTokenW(
        IntPtr token, uint logonFlags, string applicationName, StringBuilder commandLine,
        uint creationFlags, IntPtr environment, string currentDirectory,
        ref StartupInfo startupInfo, out ProcessInformation processInformation);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateTokenEx(
        IntPtr existingToken, uint desiredAccess, IntPtr tokenAttributes,
        int impersonationLevel, int tokenType, out IntPtr newToken);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(
        IntPtr token, int informationClass, IntPtr information,
        uint informationLength, out uint returnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageNameW(
        IntPtr process, uint flags, StringBuilder imageName, ref uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetWindowsDirectoryW(StringBuilder windowsDirectory, uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetEnvironmentStringsW();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeEnvironmentStringsW(IntPtr environment);
    [DllImport("user32.dll")]
    private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr stringSid);
    [DllImport("kernel32.dll", EntryPoint = "LocalFree")]
    private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(
        IntPtr job, int informationClass, IntPtr information, uint informationLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryInformationJobObject(
        IntPtr job, int informationClass, out BasicAccountingInformation information,
        uint informationLength, IntPtr returnLength);
    [DllImport("kernel32.dll", EntryPoint = "QueryInformationJobObject", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryInformationJobObjectBuffer(
        IntPtr job, int informationClass, IntPtr information, uint informationLength,
        out uint returnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsProcessInJob(IntPtr process, IntPtr job,
        [MarshalAs(UnmanagedType.Bool)] out bool result);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreatePipe(
        out IntPtr readPipe, out IntPtr writePipe, ref SecurityAttributes attributes, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value,
        IntPtr size, IntPtr previousValue, IntPtr returnSize);
    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    private static Win32Exception Win32Failure(string operation) {
        int error = Marshal.GetLastWin32Error();
        return new Win32Exception(error, operation + " failed.");
    }

    private static IntPtr CopyCurrentEnvironmentBlock() {
        IntPtr source = GetEnvironmentStringsW();
        if (source == IntPtr.Zero) throw Win32Failure("GetEnvironmentStringsW");
        try {
            char[] environment = new char[MAX_ENVIRONMENT_BLOCK_CHARS];
            int length = 0;
            int consecutiveNulls = 0;
            while (length < environment.Length) {
                char value = unchecked((char)(ushort)Marshal.ReadInt16(
                    source, length * sizeof(char)));
                environment[length++] = value;
                if (value == '\0') {
                    consecutiveNulls++;
                    if (consecutiveNulls == 2) {
                        IntPtr copy = Marshal.AllocHGlobal(length * sizeof(char));
                        try {
                            Marshal.Copy(environment, 0, copy, length);
                            return copy;
                        }
                        catch {
                            Marshal.FreeHGlobal(copy);
                            throw;
                        }
                    }
                }
                else {
                    consecutiveNulls = 0;
                }
            }
            throw new InvalidOperationException(
                "The current process environment block exceeds its supported bound.");
        }
        finally { FreeEnvironmentStringsW(source); }
    }

    private static IntPtr QueryTokenBuffer(IntPtr token, int informationClass) {
        uint required = 0;
        GetTokenInformation(token, informationClass, IntPtr.Zero, 0, out required);
        if (required == 0) {
            throw Win32Failure("GetTokenInformation size query for class " + informationClass);
        }
        IntPtr buffer = Marshal.AllocHGlobal((int)required);
        uint returned;
        if (!GetTokenInformation(token, informationClass, buffer, required, out returned)) {
            Marshal.FreeHGlobal(buffer);
            throw Win32Failure("GetTokenInformation for class " + informationClass);
        }
        return buffer;
    }

    private static string SidString(IntPtr sid) {
        IntPtr text = IntPtr.Zero;
        try {
            if (!ConvertSidToStringSidW(sid, out text))
                throw Win32Failure("ConvertSidToStringSidW");
            return Marshal.PtrToStringUni(text);
        }
        finally { if (text != IntPtr.Zero) LocalFree(text); }
    }

    private static string TokenSid(IntPtr token, int informationClass) {
        IntPtr buffer = QueryTokenBuffer(token, informationClass);
        try {
            IntPtr sid = Marshal.PtrToStructure<SidAndAttributes>(buffer).Sid;
            if (sid == IntPtr.Zero) throw new InvalidOperationException("Token SID is missing.");
            return SidString(sid);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static uint TokenDword(IntPtr token, int informationClass) {
        IntPtr buffer = QueryTokenBuffer(token, informationClass);
        try { return unchecked((uint)Marshal.ReadInt32(buffer)); }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static TokenStatistics ReadTokenStatistics(IntPtr token) {
        IntPtr buffer = QueryTokenBuffer(token, TOKEN_STATISTICS);
        try { return Marshal.PtrToStructure<TokenStatistics>(buffer); }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static bool SameLuid(Luid left, Luid right) {
        return left.LowPart == right.LowPart && left.HighPart == right.HighPart;
    }

    private static void RequireToken(
        IntPtr token, uint expectedElevation, uint expectedElevationType,
        uint expectedSession, string expectedIntegrity, string expectedUser) {
        if (TokenDword(token, TOKEN_ELEVATION) != expectedElevation ||
            TokenDword(token, TOKEN_ELEVATION_TYPE) != expectedElevationType ||
            TokenDword(token, TOKEN_SESSION_ID) != expectedSession ||
            TokenDword(token, TOKEN_UI_ACCESS) != 0 ||
            TokenSid(token, TOKEN_USER) != expectedUser ||
            TokenSid(token, TOKEN_INTEGRITY_LEVEL) != expectedIntegrity) {
            throw new InvalidOperationException("Process token identity, elevation type, UI access, integrity, or session differs from the VM observer contract.");
        }
    }

    private static IntPtr GetLinkedToken(IntPtr token) {
        IntPtr buffer = QueryTokenBuffer(token, TOKEN_LINKED_TOKEN);
        try {
            IntPtr linked = Marshal.PtrToStructure<LinkedToken>(buffer).Token;
            if (linked == IntPtr.Zero) throw new InvalidOperationException("Elevated observer has no linked filtered token.");
            return linked;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static bool IsElevatedObserver() {
        return String.Equals(Environment.GetEnvironmentVariable(
            "DARKRENAMER_VM_ELEVATED_OBSERVER"), "1", StringComparison.Ordinal);
    }

    public static void AssertHighObserverToken(uint expectedSession) {
        IntPtr token = IntPtr.Zero;
        try {
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, out token))
                throw Win32Failure("OpenProcessToken for the elevated observer");
            string userSid = TokenSid(token, TOKEN_USER);
            RequireToken(
                token, 1, TOKEN_ELEVATION_TYPE_FULL, expectedSession,
                "S-1-16-12288", userSid);
        }
        finally { if (token != IntPtr.Zero) CloseHandle(token); }
    }

    private static uint GetShellProcessId(IntPtr shellWindow) {
        uint processId;
        if (GetWindowThreadProcessId(shellWindow, out processId) == 0 || processId == 0)
            throw new InvalidOperationException("The interactive shell window has no owning process.");
        return processId;
    }

    private static string GetSystemExplorerPath() {
        StringBuilder windowsDirectory = new StringBuilder(32768);
        uint length = GetWindowsDirectoryW(windowsDirectory, (uint)windowsDirectory.Capacity);
        if (length == 0) throw Win32Failure("GetWindowsDirectoryW");
        if (length >= (uint)windowsDirectory.Capacity)
            throw new InvalidOperationException("The Windows directory path exceeded its fixed buffer.");
        return Path.GetFullPath(Path.Combine(windowsDirectory.ToString(), "explorer.exe"));
    }

    private static string GetProcessImagePath(IntPtr process) {
        StringBuilder imagePath = new StringBuilder(32768);
        uint length = (uint)imagePath.Capacity;
        if (!QueryFullProcessImageNameW(process, 0, imagePath, ref length))
            throw Win32Failure("QueryFullProcessImageNameW for the interactive shell");
        if (length == 0 || length > (uint)imagePath.Capacity)
            throw new InvalidOperationException("The interactive shell image path is invalid.");
        return Path.GetFullPath(imagePath.ToString());
    }

    private static IntPtr OpenVerifiedShellPrimaryToken(
        IntPtr linkedToken, uint expectedSession, string expectedUser) {
        IntPtr shellWindow = GetShellWindow();
        if (shellWindow == IntPtr.Zero)
            throw new InvalidOperationException("The interactive desktop has no shell window.");
        uint shellProcessId = GetShellProcessId(shellWindow);
        IntPtr shellProcess = IntPtr.Zero, shellToken = IntPtr.Zero;
        try {
            shellProcess = OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION, false, shellProcessId);
            if (shellProcess == IntPtr.Zero)
                throw Win32Failure("OpenProcess for the interactive shell");
            string imagePath = GetProcessImagePath(shellProcess);
            string expectedImagePath = GetSystemExplorerPath();
            if (!String.Equals(imagePath, expectedImagePath, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The interactive shell image is not the Windows Explorer binary.");
            if (GetShellProcessId(shellWindow) != shellProcessId)
                throw new InvalidOperationException("The interactive shell process changed during token acquisition.");
            // Retry 17 with the documented CPWT mask returned ERROR_ACCESS_DENIED; retry 18
            // reached ERROR_TOKEN_ALREADY_IN_USE, so retain a tightly scoped probe mask.
            uint desiredAccess = TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY |
                TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID;
            if (!OpenProcessToken(shellProcess, desiredAccess, out shellToken))
                throw Win32Failure("OpenProcessToken for the verified interactive shell");
            if (TokenDword(shellToken, TOKEN_TYPE) != TOKEN_PRIMARY)
                throw new InvalidOperationException("The verified interactive shell token is not primary.");
            RequireToken(
                shellToken, 0, TOKEN_ELEVATION_TYPE_LIMITED, expectedSession,
                "S-1-16-8192", expectedUser);
            Luid linkedAuthenticationId = ReadTokenStatistics(linkedToken).AuthenticationId;
            TokenStatistics shellStatistics = ReadTokenStatistics(shellToken);
            Luid shellAuthenticationId = shellStatistics.AuthenticationId;
            if (!SameLuid(linkedAuthenticationId, shellAuthenticationId))
                throw new InvalidOperationException("The shell token belongs to a different interactive logon.");
            IntPtr primaryToken = IntPtr.Zero;
            try {
                if (!DuplicateTokenEx(shellToken, desiredAccess, IntPtr.Zero,
                        SECURITY_IMPERSONATION, TOKEN_PRIMARY, out primaryToken))
                    throw Win32Failure("DuplicateTokenEx for the verified interactive shell token");
                if (TokenDword(primaryToken, TOKEN_TYPE) != TOKEN_PRIMARY)
                    throw new InvalidOperationException("The duplicated shell token is not primary.");
                RequireToken(
                    primaryToken, 0, TOKEN_ELEVATION_TYPE_LIMITED, expectedSession,
                    "S-1-16-8192", expectedUser);
                TokenStatistics primaryStatistics = ReadTokenStatistics(primaryToken);
                if (SameLuid(shellStatistics.TokenId, primaryStatistics.TokenId))
                    throw new InvalidOperationException("DuplicateTokenEx returned the existing shell token identity.");
                if (!SameLuid(linkedAuthenticationId, primaryStatistics.AuthenticationId))
                    throw new InvalidOperationException("The duplicated shell token belongs to a different interactive logon.");
                IntPtr result = primaryToken;
                primaryToken = IntPtr.Zero;
                return result;
            }
            finally {
                if (primaryToken != IntPtr.Zero) CloseHandle(primaryToken);
            }
        }
        finally {
            if (shellToken != IntPtr.Zero) CloseHandle(shellToken);
            if (shellProcess != IntPtr.Zero) CloseHandle(shellProcess);
        }
    }

    private static IntPtr OpenVerifiedLinkedShellPrimaryToken(out uint session, out string userSid) {
        string expectedSessionText = Environment.GetEnvironmentVariable(
            "DARKRENAMER_VM_EXPECTED_SESSION_ID");
        uint expectedSession;
        if (!UInt32.TryParse(expectedSessionText, out expectedSession) || expectedSession == 0)
            throw new InvalidOperationException("Elevated observer session binding is missing.");
        IntPtr current = IntPtr.Zero, linked = IntPtr.Zero;
        try {
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, out current))
                throw Win32Failure("OpenProcessToken for linked-token verification");
            uint currentSession = TokenDword(current, TOKEN_SESSION_ID);
            userSid = TokenSid(current, TOKEN_USER);
            RequireToken(
                current, 1, TOKEN_ELEVATION_TYPE_FULL, expectedSession,
                "S-1-16-12288", userSid);
            linked = GetLinkedToken(current);
            RequireToken(
                linked, 0, TOKEN_ELEVATION_TYPE_LIMITED, expectedSession,
                "S-1-16-8192", userSid);
            IntPtr shellToken = OpenVerifiedShellPrimaryToken(
                linked, expectedSession, userSid);
            session = currentSession;
            return shellToken;
        }
        finally {
            if (current != IntPtr.Zero) CloseHandle(current);
            if (linked != IntPtr.Zero) CloseHandle(linked);
        }
    }

    private static void RequireCreatedChild(
        IntPtr process, uint expectedSession, string expectedUser,
        Luid expectedAuthenticationId) {
        IntPtr token;
        if (!OpenProcessToken(process, TOKEN_QUERY, out token))
            throw Win32Failure("OpenProcessToken for the suspended observer child");
        try {
            if (TokenDword(token, TOKEN_TYPE) != TOKEN_PRIMARY)
                throw new InvalidOperationException("The suspended observer child token is not primary.");
            if (!SameLuid(expectedAuthenticationId, ReadTokenStatistics(token).AuthenticationId))
                throw new InvalidOperationException("The suspended observer child belongs to a different logon session.");
            RequireToken(
                token, 0, TOKEN_ELEVATION_TYPE_LIMITED, expectedSession,
                "S-1-16-8192", expectedUser);
        }
        finally { CloseHandle(token); }
    }

    private readonly object outputLock = new object();
    private IntPtr job;
    private Task stdoutTask, stderrTask;
    private Exception captureError;
    private long totalOutputBytes, stdoutBytes, stderrBytes;
    private long channelLimit, aggregateLimit;
    private volatile bool outputLimitExceeded;
    public Process Process { get; private set; }
    public long ProcessCreateBeginTimestamp { get; private set; }
    public long ProcessCreateEndTimestamp { get; private set; }
    public bool OutputLimitExceeded { get { return outputLimitExceeded; } }
    public uint LastProcessListAssigned;
    public uint LastProcessListListed;
    public int LastProcessListError;

    private DarkReNamerVmJobBoundProcess(IntPtr job, Process process) {
        this.job = job;
        Process = process;
    }

    private static void CreateBoundedPipe(
        ref SecurityAttributes security, bool childReads,
        out IntPtr readPipe, out IntPtr writePipe) {
        if (!CreatePipe(out readPipe, out writePipe, ref security, 0)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        IntPtr parentHandle = childReads ? writePipe : readPipe;
        if (!SetHandleInformation(parentHandle, HANDLE_FLAG_INHERIT, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    private void StartCapture(
        ref IntPtr stdoutRead, ref IntPtr stderrRead, string stdoutPath, string stderrPath,
        long perChannelLimit, long combinedLimit) {
        channelLimit = perChannelLimit;
        aggregateLimit = combinedLimit;
        IntPtr stdoutHandle = stdoutRead;
        stdoutTask = Task.Run(() => Capture(stdoutHandle, stdoutPath, true));
        stdoutRead = IntPtr.Zero;
        IntPtr stderrHandle = stderrRead;
        stderrTask = Task.Run(() => Capture(stderrHandle, stderrPath, false));
        stderrRead = IntPtr.Zero;
    }

    private void Capture(IntPtr readHandle, string path, bool stdout) {
        try {
            using (FileStream input = new FileStream(
                    new SafeFileHandle(readHandle, true), FileAccess.Read, 65536, false))
            using (FileStream output = new FileStream(
                    path, FileMode.Create, FileAccess.Write, FileShare.Read, 65536, false)) {
                byte[] buffer = new byte[65536];
                for (;;) {
                    int count = input.Read(buffer, 0, buffer.Length);
                    if (count == 0) break;
                    int accepted;
                    bool exceeded;
                    lock (outputLock) {
                        long channelBytes = stdout ? stdoutBytes : stderrBytes;
                        long available = Math.Min(channelLimit - channelBytes,
                            aggregateLimit - totalOutputBytes);
                        accepted = available <= 0 ? 0 : (int)Math.Min((long)count, available);
                        if (stdout) stdoutBytes += accepted; else stderrBytes += accepted;
                        totalOutputBytes += accepted;
                        exceeded = accepted != count;
                        if (exceeded) outputLimitExceeded = true;
                    }
                    if (accepted > 0) output.Write(buffer, 0, accepted);
                    if (exceeded) {
                        Terminate(1);
                        break;
                    }
                }
                output.Flush(true);
            }
        }
        catch (Exception error) {
            lock (outputLock) {
                if (captureError == null) captureError = error;
            }
            try { Terminate(1); } catch { }
        }
    }

    public static DarkReNamerVmJobBoundProcess Start(
        string filePath, string arguments, string workingDirectory,
        string stdoutPath, string stderrPath, long channelLimit, long aggregateLimit,
        bool singleProcessOnly) {
        if (String.IsNullOrWhiteSpace(filePath) || filePath.IndexOf('\0') >= 0 ||
            filePath.IndexOf('"') >= 0 || String.IsNullOrWhiteSpace(workingDirectory)) {
            throw new ArgumentException("The process launch path is invalid.");
        }
        bool redirect = !String.IsNullOrEmpty(stdoutPath) || !String.IsNullOrEmpty(stderrPath);
        if (redirect && (String.IsNullOrWhiteSpace(stdoutPath) ||
                String.IsNullOrWhiteSpace(stderrPath) || channelLimit <= 0 ||
                aggregateLimit <= 0)) {
            throw new ArgumentException("Bounded process output configuration is invalid.");
        }

        IntPtr job = IntPtr.Zero;
        IntPtr stdoutRead = IntPtr.Zero, stdoutWrite = IntPtr.Zero;
        IntPtr stderrRead = IntPtr.Zero, stderrWrite = IntPtr.Zero;
        IntPtr stdinRead = IntPtr.Zero, stdinWrite = IntPtr.Zero;
        IntPtr attributeList = IntPtr.Zero, handleList = IntPtr.Zero;
        bool attributeListInitialized = false;
        IntPtr observerToken = IntPtr.Zero;
        IntPtr environmentBlock = IntPtr.Zero;
        ProcessInformation created = new ProcessInformation();
        Process process = null;
        DarkReNamerVmJobBoundProcess result = null;
        try {
            job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            ExtendedLimitInformation limits = new ExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (singleProcessOnly) {
                limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
                limits.BasicLimitInformation.ActiveProcessLimit = 1;
            }
            int limitSize = Marshal.SizeOf(typeof(ExtendedLimitInformation));
            IntPtr limitBuffer = Marshal.AllocHGlobal(limitSize);
            try {
                Marshal.StructureToPtr(limits, limitBuffer, false);
                if (!SetInformationJobObject(job, 9, limitBuffer, (uint)limitSize))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { Marshal.FreeHGlobal(limitBuffer); }

            bool elevatedObserver = IsElevatedObserver();
            StartupInfoEx startup = new StartupInfoEx();
            startup.StartupInfo.cb = Marshal.SizeOf(elevatedObserver
                ? typeof(StartupInfo) : typeof(StartupInfoEx));
            uint flags = CREATE_SUSPENDED;
            if (!elevatedObserver) flags |= EXTENDED_STARTUPINFO_PRESENT;
            uint observerSession = 0;
            string observerUserSid = null;
            Luid observerAuthenticationId = new Luid();
            if (elevatedObserver) {
                DarkReNamerVmRunnerSecurity.AssertDefaultObserverDesktop();
                observerToken = OpenVerifiedLinkedShellPrimaryToken(out observerSession, out observerUserSid);
                observerAuthenticationId = ReadTokenStatistics(observerToken).AuthenticationId;
                environmentBlock = CopyCurrentEnvironmentBlock();
                flags |= CREATE_UNICODE_ENVIRONMENT;
                // Inherit the task desktop so CreateProcessWithTokenW grants the verified user access.
            }
            bool inheritHandles = false;
            if (redirect) {
                SecurityAttributes security = new SecurityAttributes();
                security.nLength = Marshal.SizeOf(typeof(SecurityAttributes));
                security.bInheritHandle = true;
                CreateBoundedPipe(ref security, false, out stdoutRead, out stdoutWrite);
                CreateBoundedPipe(ref security, false, out stderrRead, out stderrWrite);
                CreateBoundedPipe(ref security, true, out stdinRead, out stdinWrite);
                startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
                startup.StartupInfo.hStdInput = stdinRead;
                startup.StartupInfo.hStdOutput = stdoutWrite;
                startup.StartupInfo.hStdError = stderrWrite;
                if (!elevatedObserver) {
                    IntPtr attributeSize = IntPtr.Zero;
                    InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeSize);
                    attributeList = Marshal.AllocHGlobal(attributeSize);
                    if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeSize))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    attributeListInitialized = true;
                    handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                    Marshal.WriteIntPtr(handleList, 0, stdinRead);
                    Marshal.WriteIntPtr(handleList, IntPtr.Size, stdoutWrite);
                    Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, stderrWrite);
                    if (!UpdateProcThreadAttribute(attributeList, 0,
                            new IntPtr(HANDLE_LIST_ATTRIBUTE), handleList,
                            new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    startup.lpAttributeList = attributeList;
                    inheritHandles = true;
                }
                flags |= CREATE_NO_WINDOW;
            }

            StringBuilder commandLine = new StringBuilder("\"" + filePath + "\"");
            if (!String.IsNullOrEmpty(arguments)) commandLine.Append(' ').Append(arguments);
            if (elevatedObserver && commandLine.Length >= 1024)
                throw new InvalidOperationException(
                    "The CreateProcessWithTokenW command line exceeds its supported bound.");
            long processCreateBegin = Stopwatch.GetTimestamp();
            bool started = elevatedObserver
                ? CreateProcessWithTokenW(observerToken, 0, filePath, commandLine,
                    flags, environmentBlock,
                    workingDirectory, ref startup.StartupInfo, out created)
                : CreateProcessW(filePath, commandLine, IntPtr.Zero, IntPtr.Zero,
                    inheritHandles, flags, IntPtr.Zero, workingDirectory,
                    ref startup, out created);
            // The P/Invoke last error is captured before timing or cleanup work.
            int processCreateError = started ? 0 : Marshal.GetLastWin32Error();
            long processCreateEnd = Stopwatch.GetTimestamp();
            if (!started) {
                throw new Win32Exception(processCreateError, elevatedObserver
                    ? "CreateProcessWithTokenW for the verified medium shell token failed."
                    : "CreateProcessW for the VM test child failed.");
            }
            if (!AssignProcessToJobObject(job, created.hProcess)) {
                int error = Marshal.GetLastWin32Error();
                if (!TerminateProcess(created.hProcess, 1)) {
                    int terminateError = Marshal.GetLastWin32Error();
                    throw new Win32Exception(terminateError,
                        "Could not terminate a process after Job Object assignment failed.");
                }
                uint terminated = WaitForSingleObject(created.hProcess, 10000);
                if (terminated != WAIT_OBJECT_0) {
                    if (terminated == UInt32.MaxValue) {
                        throw new Win32Exception(Marshal.GetLastWin32Error(),
                            "Could not confirm process termination after Job Object assignment failed.");
                    }
                    throw new TimeoutException(
                        "Process remained alive after Job Object assignment failed.");
                }
                throw new Win32Exception(error);
            }
            if (elevatedObserver) {
                try {
                    RequireCreatedChild(created.hProcess, observerSession, observerUserSid, observerAuthenticationId);
                }
                catch {
                    if (!TerminateProcess(created.hProcess, 1)) {
                        int terminateError = Marshal.GetLastWin32Error();
                        throw new Win32Exception(terminateError,
                            "Could not terminate a candidate whose token failed observer verification.");
                    }
                    uint terminated = WaitForSingleObject(created.hProcess, 10000);
                    if (terminated != WAIT_OBJECT_0) {
                        if (terminated == UInt32.MaxValue)
                            throw new Win32Exception(Marshal.GetLastWin32Error(),
                                "Could not confirm termination of a candidate whose token failed observer verification.");
                        throw new TimeoutException(
                            "A candidate whose token failed observer verification remained alive.");
                    }
                    throw;
                }
            }
            process = Process.GetProcessById((int)created.dwProcessId);
            if (process.Handle == IntPtr.Zero) throw new Win32Exception();
            result = new DarkReNamerVmJobBoundProcess(job, process);
            result.ProcessCreateBeginTimestamp = processCreateBegin;
            result.ProcessCreateEndTimestamp = processCreateEnd;
            job = IntPtr.Zero;
            process = null;
            if (redirect) {
                CloseHandle(stdoutWrite); stdoutWrite = IntPtr.Zero;
                CloseHandle(stderrWrite); stderrWrite = IntPtr.Zero;
                CloseHandle(stdinRead); stdinRead = IntPtr.Zero;
                CloseHandle(stdinWrite); stdinWrite = IntPtr.Zero;
                result.StartCapture(ref stdoutRead, ref stderrRead, stdoutPath, stderrPath,
                    channelLimit, aggregateLimit);
            }
            if (ResumeThread(created.hThread) == UInt32.MaxValue) {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error);
            }
            return result;
        }
        catch (Exception launchError) {
            if (result != null) {
                try { result.Terminate(1); }
                catch (Exception error) { launchError.Data["termination_error"] = error.Message; }
                try { result.Dispose(); }
                catch (Exception error) { launchError.Data["disposal_error"] = error.Message; }
            }
            throw;
        }
        finally {
            if (created.hThread != IntPtr.Zero) CloseHandle(created.hThread);
            if (created.hProcess != IntPtr.Zero) CloseHandle(created.hProcess);
            if (observerToken != IntPtr.Zero) CloseHandle(observerToken);
            if (environmentBlock != IntPtr.Zero) Marshal.FreeHGlobal(environmentBlock);
            if (attributeListInitialized) DeleteProcThreadAttributeList(attributeList);
            if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
            if (attributeList != IntPtr.Zero) Marshal.FreeHGlobal(attributeList);
            foreach (IntPtr handle in new [] { stdoutRead, stdoutWrite, stderrRead,
                    stderrWrite, stdinRead, stdinWrite })
                if (handle != IntPtr.Zero) CloseHandle(handle);
            if (process != null) process.Dispose();
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }

    public void WaitForCapture(int milliseconds) {
        Task[] tasks = stderrTask != null ? new [] { stdoutTask, stderrTask }
            : stdoutTask != null ? new [] { stdoutTask } : new Task[0];
        if (tasks.Length != 0 && !Task.WaitAll(tasks, milliseconds))
            throw new TimeoutException("Bounded process output did not finish draining.");
        if (captureError != null)
            throw new IOException("Bounded process output capture failed.", captureError);
    }

    public uint ActiveProcessCount {
        get {
            if (job == IntPtr.Zero) return 0;
            BasicAccountingInformation information;
            if (!QueryInformationJobObject(job, 1, out information,
                    (uint)Marshal.SizeOf(typeof(BasicAccountingInformation)), IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return information.ActiveProcesses;
        }
    }

    public JobTerminationReceipt TerminateVerifiedSingleProcess(uint expectedProcessId) {
        if (job == IntPtr.Zero || Process == null || expectedProcessId == 0 ||
            Process.Id != expectedProcessId) {
            throw new InvalidOperationException("The retained primary process identity is unavailable.");
        }
        bool isInJob;
        if (!IsProcessInJob(Process.Handle, job, out isInJob))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!isInJob)
            throw new InvalidOperationException("The retained primary process is outside its owned Job Object.");

        BasicAccountingInformation accounting;
        if (!QueryInformationJobObject(job, 1, out accounting,
                (uint)Marshal.SizeOf(typeof(BasicAccountingInformation)), IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (accounting.TotalProcesses != 1 || accounting.ActiveProcesses != 1)
            throw new InvalidOperationException("The recovery process job contains another or previously assigned process.");

        IntPtr processList = Marshal.AllocHGlobal(8 + IntPtr.Size);
        uint returnedLength;
        try {
            if (!QueryInformationJobObjectBuffer(job, 3, processList,
                    (uint)(8 + IntPtr.Size), out returnedLength))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (returnedLength < (uint)(8 + IntPtr.Size))
                throw new InvalidOperationException("The recovery process job returned a truncated process list.");
            uint assigned = unchecked((uint)Marshal.ReadInt32(processList, 0));
            uint listed = unchecked((uint)Marshal.ReadInt32(processList, 4));
            ulong listedProcessId = IntPtr.Size == 8
                ? unchecked((ulong)Marshal.ReadInt64(processList, 8))
                : unchecked((uint)Marshal.ReadInt32(processList, 8));
            if (assigned != 1 || listed != 1 || listedProcessId != expectedProcessId)
                throw new InvalidOperationException("The recovery process job does not contain only the retained candidate PID.");
        }
        finally { Marshal.FreeHGlobal(processList); }

        byte[] randomBytes = new byte[4];
        uint exitCode;
        using (RandomNumberGenerator generator = RandomNumberGenerator.Create()) {
            do {
                generator.GetBytes(randomBytes);
                exitCode = BitConverter.ToUInt32(randomBytes, 0) & 0x7fffffff;
            } while (exitCode == 0 || exitCode == 1 || exitCode == 259);
        }
        if (!TerminateJobObject(job, exitCode))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return new JobTerminationReceipt {
            ProcessId = expectedProcessId,
            TotalProcesses = accounting.TotalProcesses,
            ActiveProcesses = accounting.ActiveProcesses,
            ExitCode = exitCode
        };
    }

    public bool WaitForEmpty(int milliseconds) {
        long deadline = Environment.TickCount64 + milliseconds;
        do {
            if (ActiveProcessCount == 0) return true;
            Thread.Sleep(50);
        } while (Environment.TickCount64 < deadline);
        return ActiveProcessCount == 0;
    }

    public long GetSoleActiveProcessId() {
        LastProcessListAssigned = 0;
        LastProcessListListed = 0;
        LastProcessListError = 0;
        if (job == IntPtr.Zero) return 0;
        uint bufferLength = (uint)(8 + IntPtr.Size);
        IntPtr processList = Marshal.AllocHGlobal((int)bufferLength);
        uint returnedLength;
        try {
            if (!QueryInformationJobObjectBuffer(job, 3, processList,
                    bufferLength, out returnedLength)) {
                int error = Marshal.GetLastWin32Error();
                LastProcessListError = error;
                if (error == 122 || error == 234) return -1;
                throw new Win32Exception(error);
            }
            if (returnedLength < 8)
                throw new InvalidOperationException("The Job Object process list is truncated.");
            uint assigned = unchecked((uint)Marshal.ReadInt32(processList, 0));
            uint listed = unchecked((uint)Marshal.ReadInt32(processList, 4));
            LastProcessListAssigned = assigned;
            LastProcessListListed = listed;
            if (assigned > 1 || listed > 1) return -1;
            if (listed == 0) return 0;
            if (assigned != 1 || listed != 1) return -1;
            if (returnedLength < bufferLength)
                throw new InvalidOperationException("The sole Job Object process ID is truncated.");
            ulong processId = IntPtr.Size == 8
                ? unchecked((ulong)Marshal.ReadInt64(processList, 8))
                : unchecked((uint)Marshal.ReadInt32(processList, 8));
            if (processId == 0 || processId > UInt32.MaxValue) return -1;
            return (long)processId;
        }
        finally { Marshal.FreeHGlobal(processList); }
    }

    public void Terminate(uint exitCode) {
        if (job != IntPtr.Zero && !TerminateJobObject(job, exitCode))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public bool CloseJob() {
        if (job == IntPtr.Zero) return true;
        IntPtr current = job;
        job = IntPtr.Zero;
        return CloseHandle(current);
    }

    public void Dispose() {
        CloseJob();
        try { WaitForCapture(10000); } catch { }
        if (Process != null) { Process.Dispose(); Process = null; }
        GC.SuppressFinalize(this);
    }

    ~DarkReNamerVmJobBoundProcess() { CloseJob(); }
}

public static class DarkReNamerVmRunnerSecurity {
    private const uint PROCESS_WRITE_DAC = 0x00040000;
    private const uint DACL_SECURITY_INFORMATION = 0x00000004;
    private const uint PROTECTED_DACL_SECURITY_INFORMATION = 0x80000000;
    private const int UOI_NAME = 2;
    private const int SE_FILE_OBJECT = 1;
    private const int SE_KERNEL_OBJECT = 6;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(
        string path, uint access, uint share, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentProcessId();
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetUserObjectInformationW(
        IntPtr handle, int index, StringBuilder information, uint length, out uint requiredLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", EntryPoint = "LocalFree")]
    private static extern IntPtr ReleaseSecurityDescriptorBuffer(IntPtr memory);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string descriptor, uint revision, out IntPtr securityDescriptor, out uint size);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSecurityDescriptorDacl(
        IntPtr securityDescriptor, out bool present, out IntPtr dacl,
        out bool defaulted);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint SetSecurityInfo(
        IntPtr handle, int objectType, uint information, IntPtr owner,
        IntPtr group, IntPtr dacl, IntPtr sacl);

    public static void ProtectCurrentProcess(string runnerSid) {
        if (String.IsNullOrWhiteSpace(runnerSid))
            throw new ArgumentException("The VM runner SID is required.", "runnerSid");
        string validatedRunnerSid =
            new System.Security.Principal.SecurityIdentifier(runnerSid).Value;
        IntPtr process = OpenProcess(PROCESS_WRITE_DAC, false, GetCurrentProcessId());
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            // The medium linked token is not the elevated process object's owner.
            // Grant its verified SID query-only access while denying mutation rights.
            ApplyProtectedDacl(process, SE_KERNEL_OBJECT,
                "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x00101000;;;" +
                validatedRunnerSid + ")(A;;0x00101000;;;OW)");
        }
        finally {
            CloseHandle(process);
        }
    }

    public static void AssertHighObserverToken(uint expectedSession) {
        DarkReNamerVmJobBoundProcess.AssertHighObserverToken(expectedSession);
    }

    private static string GetUserObjectName(IntPtr handle, string label) {
        StringBuilder name = new StringBuilder(256);
        uint requiredLength;
        if (!GetUserObjectInformationW(handle, UOI_NAME, name,
                (uint)(name.Capacity * sizeof(char)), out requiredLength))
            throw new Win32Exception(Marshal.GetLastWin32Error(), label + " failed.");
        if (requiredLength == 0 || requiredLength > (uint)(name.Capacity * sizeof(char)))
            throw new InvalidOperationException(label + " returned an invalid object name.");
        return name.ToString();
    }

    public static void AssertDefaultObserverDesktop() {
        IntPtr windowStation = GetProcessWindowStation();
        if (windowStation == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "GetProcessWindowStation for the elevated observer failed.");
        IntPtr desktop = GetThreadDesktop(GetCurrentThreadId());
        if (desktop == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "GetThreadDesktop for the elevated observer failed.");
        string windowStationName = GetUserObjectName(
            windowStation, "GetUserObjectInformationW for the observer window station");
        string desktopName = GetUserObjectName(
            desktop, "GetUserObjectInformationW for the observer desktop");
        if (!String.Equals(windowStationName, "WinSta0", StringComparison.OrdinalIgnoreCase) ||
            !String.Equals(desktopName, "Default", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                "The elevated observer is not attached to WinSta0\\Default.");
    }

    public static void ProtectResultFile(SafeFileHandle file, string runnerSid) {
        if (file == null || file.IsInvalid || file.IsClosed)
            throw new ArgumentException("The trusted result file handle is invalid.");
        if (String.IsNullOrWhiteSpace(runnerSid))
            throw new ArgumentException("The trusted result reader SID is missing.");
        string validatedRunnerSid = new System.Security.Principal.SecurityIdentifier(runnerSid).Value;
        ApplyProtectedDacl(file.DangerousGetHandle(), SE_FILE_OBJECT,
            "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;" + validatedRunnerSid + ")(A;;FR;;;OW)");
    }

    public static SafeFileHandle CreateTrustedResultFile(string path, bool createNew) {
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint WRITE_DAC = 0x00040000;
        const uint SHARE_READ = 0x00000001;
        const uint CREATE_NEW = 1;
        const uint OPEN_EXISTING = 3;
        const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        IntPtr file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE | WRITE_DAC,
            SHARE_READ, IntPtr.Zero, createNew ? CREATE_NEW : OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (file == new IntPtr(-1))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return new SafeFileHandle(file, true);
    }

    private static void ApplyProtectedDacl(IntPtr handle, int objectType, string sddl) {
        IntPtr descriptor = IntPtr.Zero;
        try {
            uint size;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl, 1, out descriptor, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            bool present, defaulted;
            IntPtr dacl;
            if (!GetSecurityDescriptorDacl(descriptor, out present, out dacl, out defaulted) ||
                    !present || dacl == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            uint error = SetSecurityInfo(handle, objectType,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
            if (error != 0)
                throw new Win32Exception((int)error);
        }
        finally {
            if (descriptor != IntPtr.Zero) ReleaseSecurityDescriptorBuffer(descriptor);
        }
    }
}
public static class DarkReNamerVmFileSystem {
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint FILE_WRITE_ATTRIBUTES = 0x00000100;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const int FileCaseSensitiveInfo = 23;
    private const uint FILE_CS_FLAG_CASE_SENSITIVE_DIR = 0x00000001;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileCaseSensitiveInformation {
        public uint Flags;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetShortPathNameW(string longPath, StringBuilder shortPath,
        uint bufferLength);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string fileName, uint desiredAccess,
        uint shareMode, IntPtr securityAttributes, uint creationDisposition,
        uint flagsAndAttributes, IntPtr templateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle file,
        int fileInformationClass, ref FileCaseSensitiveInformation fileInformation,
        uint bufferSize);

    public static string GetShortPathName(string longPath) {
        if (String.IsNullOrWhiteSpace(longPath))
            throw new ArgumentException("A private runtime directory is required.", "longPath");
        uint required = GetShortPathNameW(longPath, null, 0);
        if (required == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetShortPathNameW failed.");
        if (required > 32768)
            throw new InvalidOperationException("The short runtime path exceeds its supported bound.");
        StringBuilder shortPath = new StringBuilder(checked((int)required));
        uint written = GetShortPathNameW(longPath, shortPath, required);
        if (written == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetShortPathNameW failed.");
        if (written >= required)
            throw new InvalidOperationException("GetShortPathNameW returned an invalid path length.");
        return shortPath.ToString();
    }

    public static void SetCaseSensitiveDirectory(string path) {
        if (String.IsNullOrWhiteSpace(path))
            throw new ArgumentException("A case-sensitive fixture path is required.", "path");
        using (SafeFileHandle directory = CreateFileW(path,
                FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero)) {
            if (directory == null || directory.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Opening the case-sensitive fixture failed.");
            FileCaseSensitiveInformation information = new FileCaseSensitiveInformation();
            information.Flags = FILE_CS_FLAG_CASE_SENSITIVE_DIR;
            if (!SetFileInformationByHandle(directory, FileCaseSensitiveInfo,
                    ref information, (uint)Marshal.SizeOf(typeof(FileCaseSensitiveInformation))))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "SetFileInformationByHandle(FileCaseSensitiveInfo) failed.");
        }
    }
}
'@
}

function Protect-CurrentRunnerProcess {
    Initialize-JobBoundProcessRuntime
    $runnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    [DarkReNamerVmRunnerSecurity]::ProtectCurrentProcess($runnerSid)
    if ([Environment]::GetEnvironmentVariable('DARKRENAMER_VM_ELEVATED_OBSERVER') -ceq '1') {
        Test-MediumObserverBoundary
    }
}

function Assert-VmObserverExecutionContext {
    param([Parameter(Mandatory)][int] $ExpectedSessionId)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $elevatedObserver = [Environment]::GetEnvironmentVariable(
        'DARKRENAMER_VM_ELEVATED_OBSERVER'
    ) -ceq '1'
    $currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($currentSession -ne $ExpectedSessionId) {
        throw 'VM observer is running in an unexpected desktop session.'
    }
    if ($elevatedObserver) {
        $trustedPath = [Environment]::GetEnvironmentVariable(
            'DARKRENAMER_VM_TRUSTED_RESULT_PATH'
        )
        $environmentSession = [Environment]::GetEnvironmentVariable(
            'DARKRENAMER_VM_EXPECTED_SESSION_ID'
        )
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
            [string]::IsNullOrWhiteSpace($trustedPath) -or
            -not [IO.Path]::IsPathRooted($trustedPath) -or
            $environmentSession -cne $ExpectedSessionId.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )) {
            throw 'Elevated VM observer task contract is incomplete.'
        }
        Initialize-JobBoundProcessRuntime
        [DarkReNamerVmRunnerSecurity]::AssertHighObserverToken([uint32]$ExpectedSessionId)
    }
    elseif ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'VM validation must use the protected observer task or a non-elevated direct runner.'
    }
}

function Resolve-JobBoundCapturePaths {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $BoundParameters,
        [AllowNull()][string] $StdoutPath,
        [AllowNull()][string] $StderrPath
    )

    $stdoutBound = $BoundParameters.Keys -contains 'StdoutPath'
    $stderrBound = $BoundParameters.Keys -contains 'StderrPath'
    if (-not $stdoutBound -and -not $stderrBound) {
        return [pscustomobject]@{ stdout_path = $null; stderr_path = $null }
    }
    if (-not $stdoutBound -or -not $stderrBound -or
        [string]::IsNullOrWhiteSpace($StdoutPath) -or
        [string]::IsNullOrWhiteSpace($StderrPath)) {
        throw 'Bounded process output configuration must include both output paths.'
    }
    [pscustomobject]@{ stdout_path = $StdoutPath; stderr_path = $StderrPath }
}

function Start-JobBoundProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Arguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [string] $StdoutPath,
        [string] $StderrPath,
        [switch] $SingleProcessOnly,
        [ValidateRange(1, 8388608)][long] $AggregateOutputLimitBytes =
            $script:VmTestOutputAggregateLimitBytes
    )

    Initialize-JobBoundProcessRuntime
    $capturePaths = Resolve-JobBoundCapturePaths `
        -BoundParameters $PSBoundParameters `
        -StdoutPath $StdoutPath `
        -StderrPath $StderrPath
    $owner = [DarkReNamerVmJobBoundProcess]::Start(
        $FilePath, $Arguments, $WorkingDirectory,
        $capturePaths.stdout_path, $capturePaths.stderr_path,
        $script:VmTestOutputChannelLimitBytes, $AggregateOutputLimitBytes,
        [bool]$SingleProcessOnly
    )
    [void]$owner.Process.Handle
    [pscustomobject]@{
        process = $owner.Process
        owner = $owner
        ProcessCreateBeginTimestamp = $owner.ProcessCreateBeginTimestamp
        ProcessCreateEndTimestamp = $owner.ProcessCreateEndTimestamp
        process_start_time_utc_ticks = $owner.Process.StartTime.ToUniversalTime().Ticks.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )
        job_closed = $false
        job_empty = $false
        job_capture_complete = $false
        job_cleanup_error = $null
        job_had_survivors = $false
        job_forced_termination = $false
        job_active_processes_at_primary_exit = $null
        job_process_snapshot = $null
        job_active_processes_at_close = $null
        job_active_processes_at_stop = $null
        job_active_process_ids_at_stop = @()
        job_total_processes_at_stop = $null
        job_primary_process_active_at_stop = $null
        job_termination_exit_code = $null
        job_cleanup_recorded = $false
        job_cleanup_record = $null
        aggregate_output_limit_bytes = $AggregateOutputLimitBytes
    }
}

function Test-MediumObserverBoundary {
    $trustedResultPath = [Environment]::GetEnvironmentVariable('DARKRENAMER_VM_TRUSTED_RESULT_PATH')
    if ([string]::IsNullOrWhiteSpace($trustedResultPath) -or
        -not [IO.Path]::IsPathRooted($trustedResultPath) -or
        -not (Test-Path -LiteralPath $trustedResultPath -PathType Leaf)) {
        throw 'The medium boundary probe has no controller-created result file.'
    }
    $trustedOutputRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($trustedResultPath))
    $stdoutPath = Join-Path $trustedOutputRoot 'medium-boundary-probe.stdout.log'
    $stderrPath = Join-Path $trustedOutputRoot 'medium-boundary-probe.stderr.log'
    foreach ($path in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $path) {
            throw 'The medium boundary probe output path already exists.'
        }
    }
    $probeOutputLimitBytes = 32768
    $probe = @'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class DarkReNamerVmBoundaryProbe {
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenThread(uint access, bool inherit, uint threadId);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
    private static bool RequireDenied(Func<IntPtr> open, string label) {
        IntPtr handle = open();
        if (handle != IntPtr.Zero) {
            CloseHandle(handle);
            throw new InvalidOperationException(label + " was accessible to the medium child.");
        }
        int error = Marshal.GetLastWin32Error();
        if (error == 87) return false;
        if (error != 5)
            throw new InvalidOperationException(label + " failed with native error " + error + ".");
        return true;
    }
    public static int Check(uint observerProcessId) {
        IntPtr query = OpenProcess(0x1000, false, observerProcessId);
        if (query == IntPtr.Zero)
            throw new InvalidOperationException("observer process query-limited access failed with native error " +
                Marshal.GetLastWin32Error() + ".");
        CloseHandle(query);
        foreach (uint right in new uint[] { 0x0001, 0x0002, 0x0008, 0x0020, 0x00040000 }) {
            uint requested = right;
            RequireDenied(() => OpenProcess(requested, false, observerProcessId),
                "observer process access 0x" + right.ToString("x"));
        }
        Process observer = Process.GetProcessById((int)observerProcessId);
        int inspected = 0;
        foreach (ProcessThread thread in observer.Threads) {
            uint threadId = (uint)thread.Id;
            IntPtr queryThread = OpenThread(0x0800, false, threadId);
            if (queryThread == IntPtr.Zero) {
                int queryError = Marshal.GetLastWin32Error();
                if (queryError == 87) continue;
                if (queryError != 5)
                    throw new InvalidOperationException(
                        "observer thread query-limited access failed with native error " + queryError + ".");
            }
            else CloseHandle(queryThread);
            bool stable = true;
            foreach (uint right in new uint[] { 0x0001, 0x0010, 0x0020, 0x00040000 }) {
                uint requested = right;
                if (!RequireDenied(() => OpenThread(requested, false, threadId),
                        "observer thread access 0x" + right.ToString("x"))) {
                    stable = false;
                    break;
                }
            }
            if (stable) inspected++;
        }
        if (inspected == 0) throw new InvalidOperationException("No live observer thread was available for the boundary probe.");
        return inspected;
    }
}
"@
try {
    [DarkReNamerVmBoundaryProbe]::Check([uint32]__OBSERVER_PROCESS_ID__) | Out-Null
}
catch {
    $exception = $_.Exception.GetBaseException()
    $nativeError = if ($exception -is [System.ComponentModel.Win32Exception]) {
        $exception.NativeErrorCode
    }
    else { -1 }
    $line = 'BOUNDARY_PROBE_FAILURE type={0} native_error={1} message={2}' -f `
        $exception.GetType().FullName, $nativeError, $exception.Message
    $bytes = [Text.Encoding]::UTF8.GetBytes($line + [Environment]::NewLine)
    $stream = [Console]::OpenStandardError()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    throw
}
$trustedResultPath = [Environment]::GetEnvironmentVariable('DARKRENAMER_VM_TRUSTED_RESULT_PATH')
if ([string]::IsNullOrWhiteSpace($trustedResultPath) -or
    -not [IO.Path]::IsPathRooted($trustedResultPath) -or
    -not (Test-Path -LiteralPath $trustedResultPath -PathType Leaf)) {
    throw 'The medium boundary probe has no controller-created result file.'
}
$trustedOutputRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($trustedResultPath))
$probePath = Join-Path $trustedOutputRoot ('medium-write-probe-' + [Guid]::NewGuid().ToString('N'))
$directoryWriteDenied = $false
try {
    $probeStream = [IO.FileStream]::new(
        $probePath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $probeStream.Dispose()
}
catch [UnauthorizedAccessException] {
    $directoryWriteDenied = $true
}
if (-not $directoryWriteDenied) {
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
    throw 'The medium child can create files in the protected observer output directory.'
}
$resultWriteDenied = $false
try {
    $resultStream = [IO.File]::Open(
        $trustedResultPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite
    )
    $resultStream.Dispose()
}
catch [UnauthorizedAccessException] {
    $resultWriteDenied = $true
}
catch [IO.IOException] {
    $nativeError = $_.Exception.HResult -band 0xffff
    if ($nativeError -in @(32, 33)) {
        throw 'The medium child result write probe encountered a sharing violation instead of an access denial.'
    }
    if ($nativeError -ne 5) { throw }
    $resultWriteDenied = $true
}
if (-not $resultWriteDenied) {
    throw 'The medium child can write the controller-created observer result.'
}
'@
    $observerProcessId = [Diagnostics.Process]::GetCurrentProcess().Id.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $probe = $probe.Replace('__OBSERVER_PROCESS_ID__', $observerProcessId)
    $probeScriptPath = Join-Path $trustedOutputRoot (
        'medium-boundary-probe-' + [Guid]::NewGuid().ToString('N') + '.ps1'
    )
    $probeBytes = [Text.UTF8Encoding]::new($false).GetBytes($probe)
    $probeStream = [IO.FileStream]::new(
        $probeScriptPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read
    )
    try {
        $probeStream.Write($probeBytes, 0, $probeBytes.Length)
        $probeStream.Flush($true)
    }
    finally {
        $probeStream.Dispose()
    }
    $powerShell = Join-Path $PSHOME 'pwsh.exe'
    $state = $null
    $probeSucceeded = $false
    try {
        $state = Start-JobBoundProcess `
            -FilePath $powerShell `
            -Arguments ('-NoLogo -NoProfile -NonInteractive -File "' + $probeScriptPath + '"') `
            -WorkingDirectory $PSHOME `
            -StdoutPath $stdoutPath `
            -StderrPath $stderrPath `
            -AggregateOutputLimitBytes $probeOutputLimitBytes
        if (-not $state.process.WaitForExit(30000)) {
            Stop-JobBoundProcess -State $state
            throw 'Medium integrity observer-boundary probe timed out.'
        }
        $state.owner.WaitForCapture(10000)
        if ($state.process.ExitCode -ne 0) {
            $diagnosticParts = [Collections.Generic.List[string]]::new()
            foreach ($channel in @(
                [pscustomobject]@{ label = 'stdout'; path = $stdoutPath }
                [pscustomobject]@{ label = 'stderr'; path = $stderrPath }
            )) {
                try {
                    $bytes = Get-CapturedOutputBytes -Path $channel.path
                    if ($bytes -gt $probeOutputLimitBytes) { continue }
                    $text = [IO.File]::ReadAllText($channel.path, [Text.Encoding]::UTF8).Trim()
                    if ($text.Length -gt 4096) { $text = $text.Substring(0, 4096) }
                    if ($text) { $diagnosticParts.Add($channel.label + ': ' + $text) }
                }
                catch {}
            }
            $diagnostic = if ($diagnosticParts.Count -gt 0) {
                ' ' + ($diagnosticParts -join ' | ')
            }
            else { '' }
            throw ('A medium integrity child could access or could not verify observer process/thread boundaries.' + $diagnostic)
        }
        $probeSucceeded = $true
    }
    finally {
        if ($null -ne $state) {
            if ($state.owner.ActiveProcessCount -gt 0) {
                Stop-JobBoundProcess -State $state
            }
            [void](Close-JobBoundProcess -State $state)
            $state.process.Dispose()
        }
        if ($probeSucceeded) {
            Remove-Item -LiteralPath $stdoutPath, $stderrPath, $probeScriptPath `
                -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-JobBoundProcess {
    param(
        [Parameter(Mandatory)][object] $State,
        [switch] $RequireSolePrimary
    )

    if ($RequireSolePrimary) {
        $State.process.Refresh()
        if ($State.process.HasExited) {
            throw 'The retained candidate exited before verified Job Object termination.'
        }
        $termination = $State.owner.TerminateVerifiedSingleProcess([uint32]$State.process.Id)
        if ($termination.ProcessId -ne [uint32]$State.process.Id) {
            throw 'The verified Job Object termination receipt identifies another process.'
        }
        $State.job_active_processes_at_stop = [int]$termination.ActiveProcesses
        $State.job_active_process_ids_at_stop = @([int]$termination.ProcessId)
        $State.job_total_processes_at_stop = [int]$termination.TotalProcesses
        $State.job_primary_process_active_at_stop = $true
        $State.job_termination_exit_code = [int]$termination.ExitCode
        $State.job_had_survivors = $false
        $State.job_forced_termination = $true
    }
    elseif ($State.owner.ActiveProcessCount -gt 0) {
        $State.process.Refresh()
        $primaryActive = -not $State.process.HasExited
        $State.job_active_processes_at_stop = [int]$State.owner.ActiveProcessCount
        $State.job_had_survivors = $State.job_active_processes_at_stop -gt [int]$primaryActive
        $State.job_forced_termination = $true
        $State.owner.Terminate(1)
    }
    if (-not $State.owner.WaitForEmpty(10000)) {
        throw 'The process job did not become empty after termination.'
    }
    $State.process.Refresh()
    if (-not $State.process.HasExited -and -not $State.process.WaitForExit(10000)) {
        throw 'The primary process did not exit after job termination.'
    }
}

function Close-JobBoundProcess {
    param([Parameter(Mandatory)][object] $State)

    $errors = [Collections.Generic.List[string]]::new()
    $empty = $false
    $emptyOnWait = $false
    $closed = $false
    $captureComplete = $false
    try {
        $activeProcesses = $State.owner.ActiveProcessCount
        if ($null -eq $activeProcesses) {
            throw 'The process job active-process count could not be observed.'
        }
        $State.job_active_processes_at_close = [int]$activeProcesses
        if ($State.job_active_processes_at_close -gt 0) {
            $State.job_had_survivors = $true
            $State.job_forced_termination = $true
            $State.owner.Terminate(1)
            $empty = $State.owner.WaitForEmpty(10000)
        }
        else {
            $emptyOnWait = $State.owner.WaitForEmpty(10000)
            $empty = $emptyOnWait
            if (-not $emptyOnWait) {
                $State.job_had_survivors = $true
                $State.job_forced_termination = $true
                $State.owner.Terminate(1)
                $empty = $State.owner.WaitForEmpty(10000)
            }
        }
    }
    catch { $errors.Add($_.Exception.Message) }
    finally {
        try { $closed = $State.owner.CloseJob() }
        catch { $errors.Add($_.Exception.Message) }
        try {
            $State.owner.WaitForCapture(10000)
            $captureComplete = $true
        }
        catch { $errors.Add($_.Exception.Message) }
        $State.job_empty = $empty
        $State.job_closed = $closed
        $State.job_capture_complete = $captureComplete
        if ($errors.Count -gt 0) { $State.job_cleanup_error = $errors -join '; ' }
    }
    if ($errors.Count -gt 0) { throw $State.job_cleanup_error }
    $State.job_active_processes_at_close -eq 0 -and
        $emptyOnWait -and $empty -and $closed -and $captureComplete -and
        -not $State.job_had_survivors
}

function Complete-AcceptanceOwnedProcessJob {
    param(
        [Parameter(Mandatory)][object] $Owned,
        [switch] $StopActive,
        [switch] $RequireSolePrimary
    )

    if ($Owned.job_cleanup_recorded) { return $Owned.job_cleanup_record }
    $processId = $null
    try { $processId = [int]$Owned.process.Id } catch {}
    $cleanupError = $null
    if (-not $Owned.job_closed) {
        if ($StopActive) {
            try {
                Stop-JobBoundProcess -State $Owned -RequireSolePrimary:$RequireSolePrimary
            }
            catch { $cleanupError = $_.Exception.Message }
        }
        try { [void](Close-JobBoundProcess -State $Owned) }
        catch {
            $cleanupError = @($cleanupError, $_.Exception.Message | Where-Object { $_ }) -join '; '
        }
    }
    $automationErrors = @(Complete-OwnedAutomationControlInvocations -Owned $Owned)
    if ($automationErrors.Count -gt 0) {
        $cleanupError = @(@($cleanupError) + $automationErrors | Where-Object { $_ }) -join '; '
    }
    $record = [ordered]@{
        pid = $processId
        process_start_time_utc_ticks = $Owned.process_start_time_utc_ticks
        job_empty = [bool]$Owned.job_empty
        job_closed = [bool]$Owned.job_closed
        capture_complete = [bool]$Owned.job_capture_complete
        active_processes_at_primary_exit = $Owned.job_active_processes_at_primary_exit
        had_survivors = [bool]$Owned.job_had_survivors
        forced_termination = [bool]$Owned.job_forced_termination
        active_processes_at_close = $Owned.job_active_processes_at_close
        active_processes_at_stop = $Owned.job_active_processes_at_stop
        active_process_ids_at_stop = @($Owned.job_active_process_ids_at_stop)
        total_processes_at_stop = $Owned.job_total_processes_at_stop
        primary_process_active_at_stop = $Owned.job_primary_process_active_at_stop
        termination_exit_code = $Owned.job_termination_exit_code
        status = if ($Owned.job_empty -and $Owned.job_closed -and
            $Owned.job_capture_complete -and
            $Owned.job_active_processes_at_close -eq 0 -and
            -not $Owned.job_had_survivors -and $null -eq $cleanupError) { 'clean' } else { 'failed' }
        error = if ($null -ne $cleanupError) { $cleanupError } else { $Owned.job_cleanup_error }
    }
    $Owned.job_cleanup_record = $record
    $Owned.job_cleanup_recorded = $true
    if ($null -ne $script:AcceptanceProcessJobCleanup) {
        $script:AcceptanceProcessJobCleanup.Add($record)
    }
    $record
}

function Assert-AcceptanceProcessJobLedgerClosed {
    if ($null -eq $script:AcceptanceProcessJobCleanup) {
        throw 'The candidate process-job cleanup ledger was not initialized.'
    }
    $rows = @($script:AcceptanceProcessJobCleanup.ToArray())
    if ($rows.Count -eq 0) {
        throw 'No candidate process-job cleanup records were captured.'
    }
    foreach ($row in $rows) {
        if ($row.status -cne 'clean' -or -not $row.job_empty -or
            -not $row.job_closed -or -not $row.capture_complete -or
            $row.active_processes_at_close -ne 0 -or $row.had_survivors) {
            throw "A candidate process job is not proven empty, closed, and fully captured. $($row.error)"
        }
    }
    $rows
}

function Get-CapturedOutputBytes {
    param([Parameter(Mandatory)][string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item -isnot [IO.FileInfo]) {
        throw 'Captured process output is not an ordinary file.'
    }
    [long]$item.Length
}

function Set-ProcessCleanupFailureReason {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Row,
        [Parameter(Mandatory)][string] $Reason
    )
    if ($null -eq $Row['failure_reason']) {
        $Row['failure_reason'] = $Reason
    }
    else {
        $Row['cleanup_failure_reason'] = $Reason
    }
}

function Wait-JobBoundProcessWithOutputLimit {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][string] $StdoutPath,
        [Parameter(Mandatory)][string] $StderrPath,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $reason = $null
    $soleActiveProcessId = $null
    $activeProcessesAfterAccountingGrace = $null
    while (-not $State.process.WaitForExit(100)) {
        if ($State.owner.OutputLimitExceeded) {
            $reason = 'output_limit_exceeded'
            break
        }
        if ($deadline.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $reason = 'timeout'
            break
        }
    }
    if ($null -ne $reason) {
        Stop-JobBoundProcess -State $State
    }
    else {
        $State.process.WaitForExit()
        $State.job_active_processes_at_primary_exit = [int]$State.owner.ActiveProcessCount
        if ($State.job_active_processes_at_primary_exit -gt 0) {
            $State.job_process_snapshot = [ordered]@{
                primary_pid = [long]$State.process.Id
                sole_pid = $null
                sole_process_name = $null
                assigned = [uint32]0
                listed = [uint32]0
                query_error = [int]0
                active_after_grace = $null
            }
            try {
                $soleActiveProcessId = [long]$State.owner.GetSoleActiveProcessId()
                $State.job_process_snapshot.sole_pid = $soleActiveProcessId
                if ($soleActiveProcessId -gt 0 -and
                    $soleActiveProcessId -le [int]::MaxValue) {
                    try {
                        $State.job_process_snapshot.sole_process_name =
                            (Get-Process -Id ([int]$soleActiveProcessId) -ErrorAction Stop).ProcessName
                    }
                    catch {}
                }
            }
            finally {
                $State.job_process_snapshot.assigned = [uint32]$State.owner.LastProcessListAssigned
                $State.job_process_snapshot.listed = [uint32]$State.owner.LastProcessListListed
                $State.job_process_snapshot.query_error = [int]$State.owner.LastProcessListError
            }
        }
        if ($State.job_active_processes_at_primary_exit -gt 0) {
            if ($soleActiveProcessId -lt 0) {
                $State.job_had_survivors = $true
                Stop-JobBoundProcess -State $State
                $reason = 'process_job_not_empty'
            }
            else {
                $emptyAfterAccountingGrace = $State.owner.WaitForEmpty(1000)
                $activeProcessesAfterAccountingGrace = [int]$State.owner.ActiveProcessCount
                $State.job_process_snapshot.active_after_grace = $activeProcessesAfterAccountingGrace
                if (-not $emptyAfterAccountingGrace) {
                    $State.job_had_survivors = $true
                    Stop-JobBoundProcess -State $State
                    $reason = 'process_job_not_empty'
                }
            }
        }
    }
    try {
        $State.owner.WaitForCapture(10000)
    }
    catch {
        Stop-JobBoundProcess -State $State
        try { $State.owner.WaitForCapture(10000) } catch {}
        throw
    }
    if ($null -eq $reason -and -not $State.owner.WaitForEmpty(10000)) {
        Stop-JobBoundProcess -State $State
        $State.job_had_survivors = $true
        $reason = 'process_job_not_empty'
    }
    $stdoutBytes = Get-CapturedOutputBytes -Path $StdoutPath
    $stderrBytes = Get-CapturedOutputBytes -Path $StderrPath
    if ($null -eq $reason -and $State.owner.OutputLimitExceeded) {
        $reason = 'output_limit_exceeded'
    }
    if ($stdoutBytes -gt $script:VmTestOutputChannelLimitBytes -or
        $stderrBytes -gt $script:VmTestOutputChannelLimitBytes -or
        $stdoutBytes -gt ($State.aggregate_output_limit_bytes - $stderrBytes)) {
        throw 'Bounded process output exceeded its persisted size contract.'
    }
    [pscustomobject]@{
        failure_reason = $reason
        active_processes_at_primary_exit = $State.job_active_processes_at_primary_exit
        process_job_snapshot = $State.job_process_snapshot
        stdout_bytes = $stdoutBytes
        stderr_bytes = $stderrBytes
    }
}
function Invoke-WithIsolatedEnvironment {
    param(
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][scriptblock] $Action,
        [string] $TemporaryRoot,
        [string] $CaseSensitiveFixtureRoot,
        [string] $RefreshProfileOrder
    )

    $temporary = if ([string]::IsNullOrWhiteSpace($TemporaryRoot)) {
        New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'temp'
    }
    else {
        $temporaryItem = Get-Item -LiteralPath $TemporaryRoot -Force -ErrorAction Stop
        if (-not $temporaryItem.PSIsContainer -or
            ($temporaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The supplied isolated temporary root is not an ordinary directory.'
        }
        $TemporaryRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($CaseSensitiveFixtureRoot)) {
        $expectedFixtureRoot = Join-Path $temporary 'case-sensitive-fixture'
        $fixtureItem = Get-Item -LiteralPath $CaseSensitiveFixtureRoot -Force -ErrorAction Stop
        if (-not [string]::Equals(
                [IO.Path]::GetFullPath($CaseSensitiveFixtureRoot),
                [IO.Path]::GetFullPath($expectedFixtureRoot),
                [StringComparison]::OrdinalIgnoreCase) -or
            -not $fixtureItem.PSIsContainer -or
            ($fixtureItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The case-sensitive fixture is outside the isolated temporary root.'
        }
    }
    $localAppData = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'localappdata'
    $names = @(
        'TEMP', 'TMP', 'LOCALAPPDATA', 'DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES',
        'DARKRENAMER_CASE_SENSITIVE_FIXTURE_ROOT', 'DARKRENAMER_REFRESH_PROFILE_ORDER'
    )
    $original = @{}
    foreach ($name in $names) {
        $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        [Environment]::SetEnvironmentVariable('TEMP', $temporary, 'Process')
        [Environment]::SetEnvironmentVariable('TMP', $temporary, 'Process')
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData, 'Process')
        [Environment]::SetEnvironmentVariable('DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES', '1', 'Process')
        [Environment]::SetEnvironmentVariable(
            'DARKRENAMER_CASE_SENSITIVE_FIXTURE_ROOT', $CaseSensitiveFixtureRoot, 'Process'
        )
        [Environment]::SetEnvironmentVariable(
            'DARKRENAMER_REFRESH_PROFILE_ORDER', $RefreshProfileOrder, 'Process'
        )
        & $Action
    }
    finally {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
        }
    }
}
function Start-OwnedProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Arguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [switch] $SingleProcessOnly
    )

    # UI candidates must share the observer's desktop while their entire
    # process tree remains owned by a kill-on-close Job Object.
    Start-JobBoundProcess `
        -FilePath $FilePath `
        -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -SingleProcessOnly:$SingleProcessOnly
}
function Complete-JobBoundCaseSensitiveFixture {
    param(
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Row
    )

    try {
        Assert-OrdinaryDirectoryTree -Path $FixtureRoot
        if (@(Get-ChildItem -LiteralPath $FixtureRoot -Force).Count -ne 0) {
            throw 'The case-sensitive test fixture was not emptied before cleanup.'
        }
        Remove-Item -LiteralPath $FixtureRoot -Force
        if (Test-Path -LiteralPath $FixtureRoot) {
            throw 'The case-sensitive test fixture cleanup was incomplete.'
        }
    }
    catch {
        $Row.status = 'failed'
        $Row.failure_reason = 'process_error'
        throw
    }
}
function Invoke-RustTestBinary {
    param(
        [Parameter(Mandatory)][object] $Test,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][int] $Index,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [ValidateSet('hidden-visible', 'visible-hidden')][string] $RefreshProfileOrder,
        [ValidateRange(0, 8388608)][long] $OutputBudgetBytes =
            $script:VmTestOutputAggregateLimitBytes
    )

    $stdoutLeaf = 'test-{0:D3}.stdout.txt' -f $Index
    $stderrLeaf = 'test-{0:D3}.stderr.txt' -f $Index
    $stdoutPath = Join-Path $OutputRoot $stdoutLeaf
    $stderrPath = Join-Path $OutputRoot $stderrLeaf
    [IO.File]::WriteAllBytes($stdoutPath, [byte[]]@())
    [IO.File]::WriteAllBytes($stderrPath, [byte[]]@())
    $binaryPath = Join-Path $Root $Test.file
    $row = [ordered]@{
        file = $Test.file
        sha256 = $Test.sha256
        status = 'failed'
        job_cleanup = $false
        exit_code = $null
        passed = $null
        failed = $null
        ignored = $null
        stdout = $null
        stderr = $null
        failure_reason = 'process_start_failed'
        cleanup_failure_reason = $null
        active_processes_at_primary_exit = $null
        process_job_snapshot = $null
    }
    $processState = [pscustomobject]@{ process = $null }
    try {
        do {
            if ($OutputBudgetBytes -eq 0) {
                $row.failure_reason = 'suite_output_limit_exceeded'
                break
            }
            Assert-OrdinaryFile -Path $binaryPath -Label 'test binary'
            if ((Get-LowerSha256 -Path $binaryPath) -cne $Test.sha256) {
                $row.failure_reason = 'artifact_changed_after_preflight'
                break
            }
            $caseRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf ('test-{0:D3}' -f $Index)
            $temporaryRoot = $null
            $caseSensitiveFixtureRoot = $null
            if ($Test.file -cmatch '^rename_windows_backend-[0-9a-f]{16}\.exe$') {
                $temporaryRoot = New-PrivateDirectory -Parent $caseRoot -Leaf 'temp'
                $temporaryRoot = Resolve-JobBoundShortPath -Path $temporaryRoot
                $caseSensitiveFixtureRoot = New-PrivateDirectory `
                    -Parent $temporaryRoot -Leaf 'case-sensitive-fixture'
                [DarkReNamerVmFileSystem]::SetCaseSensitiveDirectory($caseSensitiveFixtureRoot)
            }
            Invoke-WithIsolatedEnvironment `
                -RuntimeRoot $caseRoot `
                -TemporaryRoot $temporaryRoot `
                -CaseSensitiveFixtureRoot $caseSensitiveFixtureRoot `
                -RefreshProfileOrder $RefreshProfileOrder `
                -Action {
                $testArguments = if ($RefreshProfileOrder) {
                    '--exact windows::list_view::native_tests::profile_refresh_stages --ignored --nocapture --test-threads=1'
                } else { '--nocapture --test-threads=1' }
                $ownedProcess = Start-JobBoundProcess `
                    -FilePath $binaryPath `
                    -Arguments $testArguments `
                    -WorkingDirectory $Root `
                    -StdoutPath $stdoutPath `
                    -StderrPath $stderrPath `
                    -AggregateOutputLimitBytes $OutputBudgetBytes
                $processState.process = $ownedProcess
                $row.process_lifecycle = [ordered]@{
                    pid = [int]$ownedProcess.process.Id
                    start_time_utc_ticks = [string]$ownedProcess.process_start_time_utc_ticks
                }
                $wait = Wait-JobBoundProcessWithOutputLimit `
                    -State $processState.process `
                    -StdoutPath $stdoutPath `
                    -StderrPath $stderrPath `
                    -TimeoutSeconds $TimeoutSeconds
                if ($null -ne $wait.failure_reason) {
                    $row.failure_reason = $wait.failure_reason
                    $row.active_processes_at_primary_exit = $wait.active_processes_at_primary_exit
                    $row.process_job_snapshot = $wait.process_job_snapshot
                    return
                }
                $row.active_processes_at_primary_exit = $wait.active_processes_at_primary_exit
                $row.process_job_snapshot = $wait.process_job_snapshot
                $row.exit_code = $processState.process.process.ExitCode
                $stdoutText = [IO.File]::ReadAllText($stdoutPath, [Text.Encoding]::UTF8)
                $stderrText = [IO.File]::ReadAllText($stderrPath, [Text.Encoding]::UTF8)
                try {
                    $summary = Read-RustTestSummary `
                        -Stdout $stdoutText `
                        -Stderr $stderrText `
                        -AllowZeroTests:($Test.name -ceq 'DarkReNamer') `
                        -RefreshProfile:([bool]$RefreshProfileOrder)
                    $row.passed = $summary.passed
                    $row.failed = $summary.failed
                    $row.ignored = $summary.ignored
                    if ($processState.process.process.ExitCode -eq 0 -and
                        $summary.outcome -ceq 'ok' -and
                        $summary.failed -eq 0) {
                        $row.status = 'passed'
                        $row.failure_reason = $null
                    }
                    else {
                        $row.failure_reason = 'test_failed'
                    }
                }
                catch {
                    $row.failure_reason = 'invalid_test_summary'
                }
            }
            if ($null -ne $caseSensitiveFixtureRoot -and $row.status -ceq 'passed') {
                Complete-JobBoundCaseSensitiveFixture `
                    -FixtureRoot $caseSensitiveFixtureRoot -Row $row
            }
        } while ($false)
    }
    catch {
        $row.status = 'failed'
        $row.failure_reason = 'process_error'
        if ($null -ne $processState.process) {
            $row.active_processes_at_primary_exit =
                $processState.process.job_active_processes_at_primary_exit
            $row.process_job_snapshot = $processState.process.job_process_snapshot
        }
    }
    finally {
        if ($null -ne $processState.process) {
            try {
                $processState.process.process.Refresh()
                if (-not $processState.process.process.HasExited) {
                    Stop-JobBoundProcess -State $processState.process
                }
            }
            catch {
                $row.status = 'failed'
                Set-ProcessCleanupFailureReason -Row $row -Reason 'process_cleanup_failed'
            }
        }
        else {
            $row.job_cleanup = $true
        }
        try {
            $stdoutBytes = Get-CapturedOutputBytes -Path $stdoutPath
            $stderrBytes = Get-CapturedOutputBytes -Path $stderrPath
            $row.stdout = [ordered]@{
                file = $stdoutLeaf
                sha256 = Get-LowerSha256 -Path $stdoutPath
                bytes = $stdoutBytes
            }
            $row.stderr = [ordered]@{
                file = $stderrLeaf
                sha256 = Get-LowerSha256 -Path $stderrPath
                bytes = $stderrBytes
            }
        }
        catch {
            $row.status = 'failed'
            $row.failure_reason = 'output_evidence_failed'
        }
        finally {
            if ($null -ne $processState.process) {
                try {
                    $jobCleanup = Complete-AcceptanceOwnedProcessJob -Owned $processState.process
                    $row.job_cleanup = $jobCleanup.status -ceq 'clean'
                    $processState.process.process.Dispose()
                    if (-not $row.job_cleanup) {
                        $row.status = 'failed'
                        Set-ProcessCleanupFailureReason -Row $row -Reason 'process_job_cleanup_failed'
                    }
                }
                catch {
                    $row.status = 'failed'
                    Set-ProcessCleanupFailureReason -Row $row -Reason 'process_job_cleanup_failed'
                    try { $processState.process.owner.Dispose() } catch {}
                    try { $processState.process.process.Dispose() } catch {}
                }
            }
        }
    }
    [pscustomobject]$row
}
