$script:DrOwnedRootGuardSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

public sealed class DarkReNamerVmOwnedRootGuard : IDisposable {
    const uint READ_ATTRIBUTES = 0x80, LIST_DIRECTORY = 1, READ_CONTROL = 0x20000;
    const uint DELETE = 0x10000, SYNCHRONIZE = 0x100000;
    const uint SHARE_READ = 1, OPEN_EXISTING = 3, FILE_OPEN = 1;
    const uint BACKUP_SEMANTICS = 0x02000000, OPEN_REPARSE_POINT = 0x00200000;
    const uint FILE_OPEN_REPARSE_POINT = 0x00200000, FILE_SYNCHRONOUS_IO_NONALERT = 0x20;
    const uint OBJ_CASE_INSENSITIVE = 0x40, OBJ_DONT_REPARSE = 0x1000;
    const int FILE_ATTRIBUTE_DIRECTORY = 0x10, FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
    const int FILE_ID_INFO = 18, FILE_ATTRIBUTE_TAG_INFO = 9, FILE_DISPOSITION_INFO = 4;
    const int FILE_STANDARD_INFO = 1, FILE_STREAM_INFO = 7;
    const int FILE_ID_EXTD_DIRECTORY_INFO = 19, FILE_ID_EXTD_DIRECTORY_RESTART_INFO = 20;
    readonly List<SafeFileHandle> chain = new List<SafeFileHandle>();
    readonly bool mayDelete;
    int nodes, enumerated;
    long indexedBytes;
    int indexEntryLimit = 20000;
    long indexByteLimit = 512L * 1024 * 1024;
    public string BaseId { get; private set; }
    public string RootId { get; private set; }

    [StructLayout(LayoutKind.Sequential)] struct UnicodeString {
        public ushort Length, MaximumLength;
        public IntPtr Buffer;
    }
    [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes {
        public uint Length;
        public IntPtr RootDirectory, ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor, SecurityQualityOfService;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoStatusBlock {
        public IntPtr Status, Information;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr templateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int info,
        byte[] buffer, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file, int info,
        byte[] buffer, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle file, byte[] buffer, uint count,
        out uint read, IntPtr overlapped);
    [DllImport("kernel32.dll", EntryPoint = "SetLastError")]
    static extern void SetLastErrorNative(uint error);
    [DllImport("ntdll.dll")]
    static extern int NtCreateFile(out SafeFileHandle file, uint access,
        ref ObjectAttributes attributes, out IoStatusBlock status, IntPtr allocation,
        uint fileAttributes, uint share, uint disposition, uint options,
        IntPtr ea, uint eaLength);
    [DllImport("advapi32.dll")]
    static extern uint GetSecurityInfo(SafeFileHandle file, int objectType, uint requested,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl,
        out IntPtr descriptor);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
        IntPtr descriptor, uint revision, uint requested, out IntPtr text, out uint length);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr text);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);

    static SafeFileHandle OpenDrive(string name) {
        SafeFileHandle result = CreateFileW(name,
            READ_ATTRIBUTES | LIST_DIRECTORY | READ_CONTROL | SYNCHRONIZE,
            SHARE_READ, IntPtr.Zero, OPEN_EXISTING,
            BACKUP_SEMANTICS | OPEN_REPARSE_POINT, IntPtr.Zero);
        if (result.IsInvalid) {
            int error = Marshal.GetLastWin32Error(); result.Dispose();
            throw new Win32Exception(error, "Owned cleanup handle could not be opened.");
        }
        return result;
    }
    static SafeFileHandle OpenRelative(SafeFileHandle parent, string name, bool delete) {
        if (name.Length == 0 || name.Length > 255 || name == "." || name == ".." ||
            name.IndexOfAny(new char[] {'\\', '/', ':', '\0'}) >= 0)
            throw new InvalidOperationException("Owned cleanup encountered an unsafe relative name.");
        IntPtr characters = IntPtr.Zero, unicode = IntPtr.Zero;
        try {
            characters = Marshal.StringToHGlobalUni(name);
            UnicodeString value = new UnicodeString();
            value.Length = checked((ushort)(name.Length * 2));
            value.MaximumLength = checked((ushort)((name.Length + 1) * 2));
            value.Buffer = characters;
            unicode = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
            Marshal.StructureToPtr(value, unicode, false);
            ObjectAttributes attributes = new ObjectAttributes();
            attributes.Length = (uint)Marshal.SizeOf(typeof(ObjectAttributes));
            attributes.RootDirectory = parent.DangerousGetHandle();
            attributes.ObjectName = unicode;
            attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
            IoStatusBlock status;
            SafeFileHandle result;
            int code = NtCreateFile(out result,
                READ_ATTRIBUTES | LIST_DIRECTORY | READ_CONTROL | SYNCHRONIZE | (delete ? DELETE : 0),
                ref attributes, out status, IntPtr.Zero, 0, SHARE_READ, FILE_OPEN,
                FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
                IntPtr.Zero, 0);
            if (code != 0 || result == null || result.IsInvalid) {
                if (result != null) result.Dispose();
                throw new InvalidOperationException("Relative owned cleanup open failed: NTSTATUS " +
                    ((uint)code).ToString("x8"));
            }
            return result;
        }
        finally {
            if (unicode != IntPtr.Zero) Marshal.FreeHGlobal(unicode);
            if (characters != IntPtr.Zero) Marshal.FreeHGlobal(characters);
        }
    }
    static byte[] Info(SafeFileHandle file, int kind, int size) {
        byte[] data = new byte[size];
        if (!GetFileInformationByHandleEx(file, kind, data, (uint)size))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return data;
    }
    static int Attributes(SafeFileHandle file) {
        return BitConverter.ToInt32(Info(file, FILE_ATTRIBUTE_TAG_INFO, 8), 0);
    }
    static string Identity(SafeFileHandle file) {
        return BitConverter.ToString(Info(file, FILE_ID_INFO, 24)).Replace("-", "").ToLowerInvariant();
    }
    static void Ordinary(SafeFileHandle file, bool directory) {
        int attributes = Attributes(file);
        if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
            ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory)
            throw new InvalidOperationException("Owned cleanup encountered a reparse or changed entry kind.");
    }
    public string[] Security() {
        IntPtr owner, group, dacl, sacl, descriptor;
        uint error = GetSecurityInfo(chain[chain.Count - 1], 1, 7,
            out owner, out group, out dacl, out sacl, out descriptor);
        if (error != 0) throw new Win32Exception((int)error, "Held root security query failed.");
        IntPtr ownerText = IntPtr.Zero, sddlText = IntPtr.Zero;
        try {
            uint length;
            if (!ConvertSidToStringSidW(owner, out ownerText) ||
                !ConvertSecurityDescriptorToStringSecurityDescriptorW(
                    descriptor, 1, 7, out sddlText, out length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Held root descriptor conversion failed.");
            return new string[] { Marshal.PtrToStringUni(ownerText), Marshal.PtrToStringUni(sddlText) };
        }
        finally {
            if (ownerText != IntPtr.Zero) LocalFree(ownerText);
            if (sddlText != IntPtr.Zero) LocalFree(sddlText);
            if (descriptor != IntPtr.Zero) LocalFree(descriptor);
        }
    }
    sealed class ChildEntry {
        public string Name;
        public string Id;
        public int Attributes;
    }
    static List<ChildEntry> Names(SafeFileHandle directory, int maximumEntries) {
        Ordinary(directory, true);
        List<ChildEntry> names = new List<ChildEntry>();
        byte[] buffer = new byte[65536];
        bool first = true;
        while (true) {
            Array.Clear(buffer, 0, buffer.Length);
            if (!GetFileInformationByHandleEx(directory,
                    first ? FILE_ID_EXTD_DIRECTORY_RESTART_INFO : FILE_ID_EXTD_DIRECTORY_INFO,
                    buffer, (uint)buffer.Length)) {
                int error = Marshal.GetLastWin32Error();
                if (error == 18) break; // ERROR_NO_MORE_FILES
                throw new Win32Exception(error, "Held directory enumeration failed.");
            }
            first = false;
            int offset = 0;
            while (true) {
                if (offset > buffer.Length - 88)
                    throw new InvalidOperationException("Held directory enumeration returned an invalid frame.");
                uint next = BitConverter.ToUInt32(buffer, offset);
                uint byteLength = BitConverter.ToUInt32(buffer, offset + 60);
                if (byteLength == 0 || (byteLength & 1) != 0 ||
                    byteLength > buffer.Length - offset - 88 ||
                    (next != 0 && (next < 88 + byteLength || next > buffer.Length - offset)))
                    throw new InvalidOperationException("Held directory name length is invalid.");
                char[] units = new char[byteLength / 2];
                Buffer.BlockCopy(buffer, offset + 88, units, 0, (int)byteLength);
                string name = new string(units);
                if (name != "." && name != "..") {
                    if (names.Count >= maximumEntries || name.Length > 255 ||
                        name.IndexOfAny(new char[] {'\\', '/', ':', '\0'}) >= 0)
                        throw new InvalidOperationException("Held directory contains an unsafe or oversized entry.");
                    byte[] identifier = new byte[16];
                    Buffer.BlockCopy(buffer, offset + 72, identifier, 0, 16);
                    if (Array.TrueForAll(identifier, value => value == 0))
                        throw new InvalidOperationException("Held directory did not report a child file identity.");
                    names.Add(new ChildEntry {
                        Name = name,
                        Id = BitConverter.ToString(identifier).Replace("-", "").ToLowerInvariant(),
                        Attributes = BitConverter.ToInt32(buffer, offset + 56)
                    });
                }
                if (next == 0) break;
                offset += (int)next;
            }
        }
        return names;
    }
    public static bool[] ObserveRoots(string basePath, string expectedBaseId,
        string guestName, string trustedName) {
        string path = Path.GetFullPath(basePath);
        string drive = Path.GetPathRoot(path);
        if (drive == null || drive.Length != 3 ||
            !path.EndsWith("\\DarkReNamerVmRuns", StringComparison.Ordinal) ||
            guestName.Length == 0 || trustedName.Length == 0)
            throw new InvalidOperationException("Owned cleanup post-observation base is invalid.");
        string[] parts = path.Substring(drive.Length).Split(Path.DirectorySeparatorChar);
        List<SafeFileHandle> handles = new List<SafeFileHandle>();
        try {
            handles.Add(OpenDrive(drive));
            Ordinary(handles[0], true);
            foreach (string part in parts) {
                SafeFileHandle child = OpenRelative(handles[handles.Count - 1], part, false);
                try { Ordinary(child, true); handles.Add(child); }
                catch { child.Dispose(); throw; }
            }
            SafeFileHandle parent = handles[handles.Count - 1];
            if (Identity(parent) != expectedBaseId)
                throw new InvalidOperationException("Owned cleanup base changed after disposition.");
            bool guest = false, trusted = false;
            foreach (ChildEntry child in Names(parent, 20000)) {
                if (String.Equals(child.Name, guestName, StringComparison.OrdinalIgnoreCase)) guest = true;
                if (String.Equals(child.Name, trustedName, StringComparison.OrdinalIgnoreCase)) trusted = true;
            }
            return new bool[] { guest, trusted };
        }
        finally {
            for (int index = handles.Count - 1; index >= 0; --index) handles[index].Dispose();
        }
    }
    public DarkReNamerVmOwnedRootGuard(string root) : this(root, true) {}
    public DarkReNamerVmOwnedRootGuard(string root, bool allowDelete) {
        mayDelete = allowDelete;
        string path = Path.GetFullPath(root);
        string drive = Path.GetPathRoot(path);
        if (drive == null || drive.Length != 3 || path.Length <= drive.Length)
            throw new InvalidOperationException("Owned cleanup root must be drive absolute.");
        string[] parts = path.Substring(drive.Length).Split(Path.DirectorySeparatorChar);
        if (parts.Length < 3 || parts[parts.Length - 2] != "DarkReNamerVmRuns")
            throw new InvalidOperationException("Owned cleanup path is outside its exact base.");
        try {
            chain.Add(OpenDrive(drive));
            Ordinary(chain[0], true);
            foreach (string part in parts) {
                if (part.Length == 0 || part == "." || part == "..")
                    throw new InvalidOperationException("Owned cleanup path contains an alias.");
                SafeFileHandle handle = OpenRelative(chain[chain.Count - 1], part,
                    mayDelete && part == parts[parts.Length - 1]);
                try { Ordinary(handle, true); chain.Add(handle); }
                catch { handle.Dispose(); throw; }
                if (part == "DarkReNamerVmRuns") BaseId = Identity(handle);
            }
            if (BaseId == null) throw new InvalidOperationException("Owned cleanup base is unavailable.");
            RootId = Identity(chain[chain.Count - 1]);
        } catch { Dispose(); throw; }
    }
    public void Assert(string expectedBaseId, string expectedRootId) {
        if (BaseId != expectedBaseId || RootId != expectedRootId ||
            Identity(chain[chain.Count - 2]) != expectedBaseId ||
            Identity(chain[chain.Count - 1]) != expectedRootId)
            throw new InvalidOperationException("Owned cleanup root or base identity changed.");
    }
    List<ChildEntry> Children(SafeFileHandle directory) {
        List<ChildEntry> entries = Names(directory, indexEntryLimit - enumerated);
        enumerated += entries.Count;
        return entries;
    }
    static string HexName(string name) {
        char[] digits = "0123456789abcdef".ToCharArray();
        char[] result = new char[name.Length * 4];
        for (int index = 0; index < name.Length; index++) {
            ushort unit = name[index];
            byte low = (byte)(unit & 0xff), high = (byte)(unit >> 8);
            result[4 * index] = digits[low >> 4];
            result[4 * index + 1] = digits[low & 15];
            result[4 * index + 2] = digits[high >> 4];
            result[4 * index + 3] = digits[high & 15];
        }
        return new string(result);
    }
    static long Length(SafeFileHandle file) {
        return BitConverter.ToInt64(Info(file, FILE_STANDARD_INFO, 24), 8);
    }
    static void NoNamedStreams(SafeFileHandle file, bool directory) {
        int size = 4096;
        byte[] data;
        while (true) {
            data = new byte[size];
            SetLastErrorNative(0);
            bool found = GetFileInformationByHandleEx(file, FILE_STREAM_INFO, data, (uint)data.Length);
            int error = Marshal.GetLastWin32Error();
            if (error == 38 && directory) return; // no streams on an ordinary directory
            if (found) {
                if (error == 38)
                    throw new InvalidOperationException("Held file has no default data stream.");
                break;
            }
            if ((error != 122 && error != 234) || size >= 1024 * 1024)
                throw new Win32Exception(error, "Held owned stream inventory failed or exceeded its bound.");
            size *= 2;
        }
        int offset = 0, count = 0;
        while (true) {
            if (offset > data.Length - 24 || ++count > 20000)
                throw new InvalidOperationException("Held owned stream inventory is malformed or oversized.");
            uint next = BitConverter.ToUInt32(data, offset);
            uint nameBytes = BitConverter.ToUInt32(data, offset + 4);
            if ((nameBytes & 1) != 0 ||
                nameBytes > data.Length - offset - 24 ||
                (next != 0 && ((next & 7) != 0 || next < 24 + nameBytes ||
                               next > data.Length - offset)))
                throw new InvalidOperationException("Held owned stream inventory frame is invalid.");
            string name = System.Text.Encoding.Unicode.GetString(data, offset + 24, (int)nameBytes);
            bool allowed = directory
                ? String.Equals(name, "::$INDEX_ALLOCATION", StringComparison.OrdinalIgnoreCase) ||
                  String.Equals(name, ":$I30:$INDEX_ALLOCATION", StringComparison.OrdinalIgnoreCase)
                : name.Length == 0 || String.Equals(name, "::$DATA", StringComparison.OrdinalIgnoreCase);
            if (!allowed)
                throw new InvalidOperationException("Held owned entry has an unindexed named stream.");
            if (next == 0) break;
            offset += (int)next;
        }
    }
    static string HashFile(SafeFileHandle file, long maximum) {
        long length = Length(file);
        if (length < 0 || length > maximum)
            throw new InvalidOperationException("Owned content exceeds its bounded byte allowance.");
        using (SHA256 hash = SHA256.Create()) {
            byte[] buffer = new byte[65536];
            long count = 0;
            while (true) {
                uint read;
                if (!ReadFile(file, buffer, (uint)buffer.Length, out read, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Held owned content read failed.");
                if (read == 0) break;
                count += read;
                if (count > length || count > maximum)
                    throw new InvalidOperationException("Held owned content grew during indexing.");
                hash.TransformBlock(buffer, 0, (int)read, buffer, 0);
            }
            hash.TransformFinalBlock(new byte[0], 0, 0);
            if (count != length || Length(file) != length)
                throw new InvalidOperationException("Held owned content changed during indexing.");
            return BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
        }
    }
    Dictionary<string, object> Describe(SafeFileHandle parent, ChildEntry child,
        List<string> prefix, int depth, List<Dictionary<string, object>> output) {
        if (depth > 64 || ++nodes > indexEntryLimit)
            throw new InvalidOperationException("Owned content index exceeds its entry or depth bound.");
        using (SafeFileHandle entry = OpenRelative(parent, child.Name, false)) {
            int attributes = Attributes(entry);
            bool directory = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                (child.Attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                ((attributes ^ child.Attributes) & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
                Identity(entry).Substring(16) != child.Id)
                throw new InvalidOperationException("Owned content changed or became a reparse entry.");
            NoNamedStreams(entry, directory);
            List<string> components = new List<string>(prefix);
            components.Add(HexName(child.Name));
            Dictionary<string, object> row = new Dictionary<string, object> {
                {"components_utf16_hex", components.ToArray()},
                {"file_id", Identity(entry)},
                {"kind", directory ? "directory" : "file"}
            };
            if (directory) {
                foreach (ChildEntry nested in Children(entry))
                    Describe(entry, nested, components, depth + 1, output);
                if (Identity(entry).Substring(16) != child.Id)
                    throw new InvalidOperationException("Owned directory changed while indexing.");
            } else {
                long length = Length(entry);
                if (length < 0 || length > indexByteLimit - indexedBytes)
                    throw new InvalidOperationException("Owned content exceeds its aggregate byte bound.");
                row["bytes"] = length;
                row["sha256"] = HashFile(entry, length);
                indexedBytes += length;
            }
            output.Add(row);
            return row;
        }
    }
    public Dictionary<string, object>[] ContentIndex() {
        return ContentIndex(20000, 512L * 1024 * 1024);
    }
    public Dictionary<string, object>[] ContentIndex(int maximumEntries, long maximumBytes) {
        if (maximumEntries < 0 || maximumEntries > 20000 ||
            maximumBytes < 0 || maximumBytes > 512L * 1024 * 1024)
            throw new InvalidOperationException("Owned content index received an invalid aggregate allowance.");
        indexEntryLimit = maximumEntries;
        indexByteLimit = maximumBytes;
        nodes = 0; enumerated = 0; indexedBytes = 0;
        SafeFileHandle root = chain[chain.Count - 1];
        Ordinary(root, true);
        NoNamedStreams(root, true);
        if (Identity(root) != RootId)
            throw new InvalidOperationException("Owned root changed before indexing.");
        List<Dictionary<string, object>> rows = new List<Dictionary<string, object>>();
        foreach (ChildEntry child in Children(root))
            Describe(root, child, new List<string>(), 1, rows);
        if (Identity(root) != RootId)
            throw new InvalidOperationException("Owned root changed during indexing.");
        return rows.ToArray();
    }
    void DeleteEntry(SafeFileHandle parent, ChildEntry child, int depth) {
        if (depth > 64 || ++nodes > 20000)
            throw new InvalidOperationException("Owned cleanup tree exceeds its bound.");
        using (SafeFileHandle entry = OpenRelative(parent, child.Name, true)) {
            int attributes = Attributes(entry);
            if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                (child.Attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                ((attributes ^ child.Attributes) & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
                Identity(entry).Substring(16) != child.Id)
                throw new InvalidOperationException("Owned cleanup child changed or became a reparse entry.");
            if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                foreach (ChildEntry nested in Children(entry)) DeleteEntry(entry, nested, depth + 1);
            }
            if (!SetFileInformationByHandle(entry, FILE_DISPOSITION_INFO,
                    new byte[] { 1 }, 1))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Owned cleanup disposition failed.");
        }
    }
    public void Delete() {
        if (!mayDelete)
            throw new InvalidOperationException("Read-only owned root guard cannot delete.");
        indexEntryLimit = 20000;
        nodes = 0;
        enumerated = 0;
        SafeFileHandle root = chain[chain.Count - 1];
        Ordinary(root, true);
        if (Identity(root) != RootId)
            throw new InvalidOperationException("Owned cleanup root changed before disposition.");
        foreach (ChildEntry child in Children(root)) DeleteEntry(root, child, 1);
        if (!SetFileInformationByHandle(root, FILE_DISPOSITION_INFO,
                new byte[] { 1 }, 1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Owned root disposition failed.");
    }
    public void Dispose() {
        for (int index = chain.Count - 1; index >= 0; --index) chain[index].Dispose();
        chain.Clear();
    }
    public sealed class ProtectedPathChain : IDisposable {
        const uint SHARE_ALL = 7, FILE_TRAVERSE = 0x20;
        readonly List<SafeFileHandle> held = new List<SafeFileHandle>();
        readonly string[] parts;
        readonly string drive;
        readonly bool finalDirectory;
        readonly Dictionary<string, object>[] original;
        bool closed;

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);
        static int CloseAll(List<SafeFileHandle> handles) {
            int firstError = 0;
            for (int index = handles.Count - 1; index >= 0; index--) {
                SafeFileHandle handle = handles[index];
                if (!handle.IsInvalid && !handle.IsClosed) {
                    if (!CloseHandle(handle.DangerousGetHandle())) {
                        int error = Marshal.GetLastWin32Error();
                        if (firstError == 0) firstError = error == 0 ? -1 : error;
                    } else handle.SetHandleAsInvalid();
                }
                handle.Dispose();
            }
            handles.Clear();
            return firstError;
        }

        static SafeFileHandle OpenProtectedDrive(string path) {
            SafeFileHandle result = CreateFileW(path,
                READ_ATTRIBUTES | READ_CONTROL | FILE_TRAVERSE | SYNCHRONIZE,
                SHARE_ALL, IntPtr.Zero, OPEN_EXISTING,
                BACKUP_SEMANTICS | OPEN_REPARSE_POINT, IntPtr.Zero);
            if (result.IsInvalid) {
                int error = Marshal.GetLastWin32Error(); result.Dispose();
                throw new Win32Exception(error, "Protected image drive could not be opened.");
            }
            return result;
        }
        static SafeFileHandle OpenProtectedRelative(SafeFileHandle parent, string name, bool directory) {
            if (name.Length == 0 || name.Length > 255 || name == "." || name == ".." ||
                name.IndexOfAny(new char[] {'\\', '/', ':', '\0'}) >= 0)
                throw new InvalidOperationException("Protected image ancestry has an unsafe name.");
            IntPtr characters = IntPtr.Zero, unicode = IntPtr.Zero;
            try {
                characters = Marshal.StringToHGlobalUni(name);
                UnicodeString value = new UnicodeString();
                value.Length = checked((ushort)(name.Length * 2));
                value.MaximumLength = checked((ushort)((name.Length + 1) * 2));
                value.Buffer = characters;
                unicode = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
                Marshal.StructureToPtr(value, unicode, false);
                ObjectAttributes attributes = new ObjectAttributes();
                attributes.Length = (uint)Marshal.SizeOf(typeof(ObjectAttributes));
                attributes.RootDirectory = parent.DangerousGetHandle();
                attributes.ObjectName = unicode;
                attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
                IoStatusBlock status; SafeFileHandle result;
                int code = NtCreateFile(out result,
                    READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE | (directory ? FILE_TRAVERSE : 0),
                    ref attributes, out status, IntPtr.Zero, 0, SHARE_ALL, FILE_OPEN,
                    FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
                    IntPtr.Zero, 0);
                if (code != 0 || result == null || result.IsInvalid) {
                    if (result != null) result.Dispose();
                    throw new InvalidOperationException("Protected image relative open failed: NTSTATUS " +
                        ((uint)code).ToString("x8"));
                }
                return result;
            }
            finally {
                if (unicode != IntPtr.Zero) Marshal.FreeHGlobal(unicode);
                if (characters != IntPtr.Zero) Marshal.FreeHGlobal(characters);
            }
        }
        static Dictionary<string, object> Describe(SafeFileHandle file, bool directory) {
            Ordinary(file, directory);
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetSecurityInfo(file, 1, 7,
                out owner, out group, out dacl, out sacl, out descriptor);
            if (error != 0) throw new Win32Exception((int)error, "Held protected image security query failed.");
            IntPtr ownerText = IntPtr.Zero, sddlText = IntPtr.Zero;
            try {
                if (owner == IntPtr.Zero || dacl == IntPtr.Zero)
                    throw new InvalidOperationException("Held protected image owner or DACL is absent.");
                uint length;
                if (!ConvertSidToStringSidW(owner, out ownerText) ||
                    !ConvertSecurityDescriptorToStringSecurityDescriptorW(
                        descriptor, 1, 7, out sddlText, out length))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Held protected image descriptor conversion failed.");
                uint descriptorLength = GetSecurityDescriptorLength(descriptor);
                if (descriptorLength < 20 || descriptorLength > 65536)
                    throw new InvalidOperationException("Held protected image descriptor length is invalid.");
                byte[] descriptorBytes = new byte[descriptorLength];
                Marshal.Copy(descriptor, descriptorBytes, 0, (int)descriptorLength);
                return new Dictionary<string, object> {
                    {"file_id", Identity(file)}, {"attributes", Attributes(file)},
                    {"owner_sid", Marshal.PtrToStringUni(ownerText)},
                    {"sddl", Marshal.PtrToStringUni(sddlText)},
                    {"security_descriptor_base64", Convert.ToBase64String(descriptorBytes)},
                    {"is_directory", directory}
                };
            }
            finally {
                if (ownerText != IntPtr.Zero) LocalFree(ownerText);
                if (sddlText != IntPtr.Zero) LocalFree(sddlText);
                if (descriptor != IntPtr.Zero) LocalFree(descriptor);
            }
        }
        static List<SafeFileHandle> Walk(string drive, string[] parts, bool finalDirectory) {
            List<SafeFileHandle> result = new List<SafeFileHandle>();
            try {
                result.Add(OpenProtectedDrive(drive));
                Ordinary(result[0], true);
                for (int index = 0; index < parts.Length; index++) {
                    bool directory = index < parts.Length - 1 || finalDirectory;
                    SafeFileHandle child = OpenProtectedRelative(result[result.Count - 1], parts[index], directory);
                    result.Add(child);
                    Ordinary(child, directory);
                }
                return result;
            }
            catch (Exception primary) {
                int closeError = CloseAll(result);
                if (closeError != 0)
                    throw new AggregateException(primary,
                        new Win32Exception(closeError, "Protected image partial walk close failed."));
                throw;
            }
        }
        static Dictionary<string, object>[] Snapshot(List<SafeFileHandle> handles, bool finalDirectory) {
            var rows = new Dictionary<string, object>[handles.Count];
            for (int index = 0; index < handles.Count; index++)
                rows[index] = Describe(handles[index], index < handles.Count - 1 || finalDirectory);
            return rows;
        }
        public ProtectedPathChain(string path) {
            string canonical = Path.GetFullPath(path);
            if (!String.Equals(canonical, path, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Protected image path is not canonical.");
            drive = Path.GetPathRoot(canonical);
            if (drive == null || drive.Length != 3 || canonical.Length <= drive.Length)
                throw new InvalidOperationException("Protected image path is not drive absolute.");
            parts = canonical.Substring(drive.Length).Split(Path.DirectorySeparatorChar);
            if (parts.Length != 6 || Array.Exists(parts, part => part.Length == 0 || part == "." || part == ".."))
                throw new InvalidOperationException("Protected image path has an unexpected depth.");
            finalDirectory = false;
            try {
                held.AddRange(Walk(drive, parts, finalDirectory));
                original = Snapshot(held, finalDirectory);
            } catch (Exception primary) {
                Dispose();
                if (CloseError != 0) throw new AggregateException(primary,
                    new Win32Exception(CloseError, "Protected image initial handle close failed."));
                throw;
            }
        }
        public Dictionary<string, object>[] Original { get { return original; } }
        public Dictionary<string, object>[] Recheck() {
            if (closed) throw new ObjectDisposedException("ProtectedPathChain");
            Dictionary<string, object>[] same = Snapshot(held, finalDirectory);
            var current = new ProtectedPathChainView(drive, parts, finalDirectory);
            Exception primary = null;
            try {
                Dictionary<string, object>[] fresh = current.Rows;
                for (int index = 0; index < same.Length; index++) {
                    foreach (string key in new [] { "file_id", "attributes", "owner_sid", "sddl",
                                                   "security_descriptor_base64", "is_directory" }) {
                        string expected = Convert.ToString(original[index][key]);
                        if (!String.Equals(Convert.ToString(same[index][key]), expected, StringComparison.Ordinal) ||
                            !String.Equals(Convert.ToString(fresh[index][key]), expected, StringComparison.Ordinal))
                            throw new InvalidOperationException("Protected image held ancestry or namespace changed.");
                    }
                }
            } catch (Exception error) { primary = error; }
            int closeError = current.Close();
            if (closeError != 0) {
                var closeFailure = new Win32Exception(closeError, "Protected image refresh handle close failed.");
                if (primary != null) throw new AggregateException(primary, closeFailure);
                throw closeFailure;
            }
            if (primary != null) throw primary;
            return same;
        }
        sealed class ProtectedPathChainView : IDisposable {
            readonly List<SafeFileHandle> handles;
            public Dictionary<string, object>[] Rows { get; private set; }
            public ProtectedPathChainView(string drive, string[] parts, bool finalDirectory) {
                handles = Walk(drive, parts, finalDirectory);
                try { Rows = Snapshot(handles, finalDirectory); }
                catch (Exception primary) {
                    int error = Close();
                    if (error != 0) throw new AggregateException(primary,
                        new Win32Exception(error, "Protected image refresh close failed."));
                    throw;
                }
            }
            public int Close() { return CloseAll(handles); }
            public void Dispose() {
                int error = Close();
                if (error != 0) throw new Win32Exception(error,
                    "Protected image refresh handle close failed.");
            }
        }
        public bool Closed { get { return closed; } }
        public int CloseError { get; private set; }
        public void Dispose() {
            if (closed) return;
            CloseError = CloseAll(held); closed = true;
        }
    }
}
'@
