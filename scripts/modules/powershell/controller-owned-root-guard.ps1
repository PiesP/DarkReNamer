$script:DrOwnedRootGuardSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
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
    [DllImport("kernel32.dll", EntryPoint = "CreateFileTransactedW", CharSet = CharSet.Unicode,
        ExactSpelling = true, SetLastError = true)]
    static extern SafeFileHandle CreateFileTransactedW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr templateFile,
        SafeFileHandle transaction, IntPtr version, IntPtr extended);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle file, long distance,
        out long newPointer, uint moveMethod);
    [DllImport("kernel32.dll", EntryPoint = "CloseHandle", SetLastError = true)]
    static extern bool CloseHandleForFixture(IntPtr handle);
    [DllImport("KtmW32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateTransaction(IntPtr security, IntPtr unitOfWork,
        uint options, uint isolationLevel, uint isolationFlags, uint timeout, string description);
    [DllImport("KtmW32.dll", SetLastError = true)]
    static extern bool CommitTransaction(SafeFileHandle transaction);
    [DllImport("KtmW32.dll", SetLastError = true)]
    static extern bool RollbackTransaction(SafeFileHandle transaction);
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
    // A separate, fixture-only TxF candidate. The maintained constructor and
    // Delete() path above remain the production implementation.
    // An internally prepared binding, not a production authorization entrypoint.
    private interface IExactSetPreparation {
        string Scope { get; }
        string Target { get; }
        string SourceSha { get; }
        string NonceSha { get; }
        string FrozenRootId { get; }
        string ManifestDigest { get; }
        string[] ApprovedRows { get; }
        void RequirePredeleteReceipt(string path, string rootId, string approvedDigest);
    }
    private sealed class FixturePreparation : IExactSetPreparation {
        public string Scope { get; private set; }
        public string Target { get; private set; }
        public string SourceSha { get; private set; }
        public string NonceSha { get; private set; }
        public string FrozenRootId { get; private set; }
        public string ManifestDigest { get; private set; }
        readonly string[] rows;
        public string[] ApprovedRows { get { return (string[])rows.Clone(); } }
        readonly Action runBindingRecheck;
        public FixturePreparation(string scope, string target, string sourceSha,
            string nonceSha, string rootId, string digest, string[] approvedRows,
            Action runRecheck) {
            Scope = scope; Target = target; SourceSha = sourceSha; NonceSha = nonceSha;
            FrozenRootId = rootId; ManifestDigest = digest;
            rows = (string[])approvedRows.Clone();
            runBindingRecheck = runRecheck;
        }
        public void RequirePredeleteReceipt(string receiptPath, string rootId,
            string approvedDigest) {
            if (runBindingRecheck != null) runBindingRecheck();
            if (String.IsNullOrEmpty(receiptPath))
                throw new InvalidOperationException("Phase B predelete receipt path is absent.");
            string expectedPath = Path.Combine(Scope, "predelete.txt");
            if (!String.Equals(Path.GetFullPath(receiptPath), expectedPath,
                    StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(receiptPath, expectedPath, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Phase B predelete receipt is outside the exact fixture scope.");
            FileInfo info = new FileInfo(expectedPath);
            if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length > 1024)
                throw new InvalidOperationException("Phase B predelete receipt is absent or unsafe.");
            string[] lines = File.ReadAllLines(expectedPath, Encoding.UTF8);
            ExactManifestTxFFixtureLease.RequireFixtureApprovalFields(
                lines, SourceSha, NonceSha, Scope, Target,
                rootId, approvedDigest);
        }
    }
    // This is the only entrypoint to the exact-set engine. It continues to
    // require the independently frozen, private fixture authority before opening
    // any target handle. No original retained root is admitted here.
    public sealed class ExactManifestTxFFixtureLease : IDisposable {
        public sealed class FixtureLeaseProtocol {
            public string State { get; private set; } = "prepared";
            public bool ClosureUnknown { get; private set; }
            public void Acquired() {
                if (State != "prepared") throw new InvalidOperationException("Phase B acquisition cannot repeat.");
                State = "acquired";
            }
            public void StageStarted() {
                if (State != "acquired") throw new InvalidOperationException("Phase B stage cannot repeat.");
                State = "staging";
            }
            public void StageCompleted() {
                if (State != "staging" || ClosureUnknown)
                    throw new InvalidOperationException("Phase B stage lacks confirmed handle closure.");
                State = "staged";
            }
            public void CloseUnknown() { ClosureUnknown = true; }
            public void CommitRequested() {
                if (State != "staged" || ClosureUnknown)
                    throw new InvalidOperationException("Phase B commit cannot proceed after incomplete stage.");
                State = "commit-requested";
            }
            public void CommitReturned(bool success) {
                if (State != "commit-requested")
                    throw new InvalidOperationException("Phase B commit return has no matching request.");
                State = success ? "commit-returned-poststate-unverified" : "commit-outcome-unknown";
            }
            public void RolledBack(bool success) {
                if (State == "commit-requested" || State == "commit-outcome-unknown" ||
                    State.StartsWith("commit-returned", StringComparison.Ordinal) ||
                    State.StartsWith("rollback-", StringComparison.Ordinal))
                    throw new InvalidOperationException("Phase B rollback cannot repeat or follow commit.");
                State = success ? (ClosureUnknown ? "rollback-succeeded-closure-unknown" :
                    "rollback-succeeded") : "rollback-outcome-unknown";
            }
            public void RejectedBeforeTransaction() {
                if (State != "prepared")
                    throw new InvalidOperationException("Phase B pre-transaction rejection cannot repeat.");
                State = "rejected-before-transaction";
            }
        }
        readonly ExactSetEngine engine;
        private ExactManifestTxFFixtureLease(ExactSetEngine prepared) { engine = prepared; }
        public string LeaseState { get { return engine.LeaseState; } }
        public bool ClosureUnknown { get { return engine.ClosureUnknown; } }
        public string NativeExceptionType { get { return engine.NativeExceptionType; } }
        public string NativeExceptionMessage { get { return engine.NativeExceptionMessage; } }
        public bool IsClosed { get { return engine.IsClosed; } }
        public string FixtureRoot { get { return engine.FixtureRoot; } }
        public string SourceSha { get { return engine.SourceSha; } }
        public string ScopePath { get { return engine.ScopePath; } }
        public string RootId { get { return engine.RootId; } }
        public int StageCalls { get { return engine.StageCalls; } }
        public int CommitCalls { get { return engine.CommitCalls; } }
        public int RollbackCalls { get { return engine.RollbackCalls; } }
        public int LastNativeError { get { return engine.LastNativeError; } }
        public string Settlement { get { return engine.Settlement; } }
        public bool TargetHandlesClosed { get { return engine.TargetHandlesClosed; } }
        public int HeldEntryCount { get { return engine.HeldEntryCount; } }
        public string ApprovedDigest { get { return engine.ApprovedDigest; } }
        public string[] CloseReceipts { get { return engine.CloseReceipts; } }
        const string ScopeName = "Dark180-TxfPhaseB";
        const string RunScopeName = "Dark180-TxfPhaseB-runs";
        static void CheckWindowsComponents(string path) {
            if (String.IsNullOrEmpty(path) || path.Length < 4 ||
                !((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) ||
                path[1] != ':' || path[2] != '\\' || path.IndexOf('/') >= 0 ||
                path.IndexOf(':', 2) >= 0 || path.IndexOf('\0') >= 0 ||
                path.EndsWith("\\", StringComparison.Ordinal))
                throw new InvalidOperationException("Phase B path is not a canonical local drive path.");
            foreach (string component in path.Substring(3).Split('\\')) {
                if (component.Length == 0 || component == "." || component == ".." ||
                    component.EndsWith(".", StringComparison.Ordinal) ||
                    component.EndsWith(" ", StringComparison.Ordinal) ||
                    component.IndexOf('~') >= 0 ||
                    String.Equals(component, "DarkReNamerVmRuns", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Phase B path has an alias or protected-root component.");
            }
        }
        public static string RequireFixturePathScope(string scopePath, string targetPath,
            string independentlyResolvedUserProfile) {
            CheckWindowsComponents(independentlyResolvedUserProfile);
            CheckWindowsComponents(scopePath);
            CheckWindowsComponents(targetPath);
            string basePath = independentlyResolvedUserProfile + "\\AppData\\Local\\Temp\\" + ScopeName;
            if (!scopePath.StartsWith(basePath + "\\", StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(targetPath, scopePath + "\\target", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Phase B target is outside exact local profile temp scope.");
            string leaf = scopePath.Substring(basePath.Length + 1);
            Guid parsed;
            if (leaf.IndexOf('\\') >= 0 || !Guid.TryParseExact(leaf, "N", out parsed))
                throw new InvalidOperationException("Phase B fixture scope lacks one exact GUID component.");
            return scopePath;
        }
        public static string RequireRunFixturePathScope(string scopePath, string targetPath,
            string independentlyResolvedUserProfile, string batchGuid) {
            CheckWindowsComponents(independentlyResolvedUserProfile);
            CheckWindowsComponents(scopePath);
            CheckWindowsComponents(targetPath);
            if (!ExactSetEngine.LowerHex(batchGuid, 32))
                throw new InvalidOperationException("Run fixture batch GUID is invalid.");
            string prefix = independentlyResolvedUserProfile +
                "\\AppData\\Local\\Temp\\" + RunScopeName + "\\" + batchGuid + "\\";
            string leaf = scopePath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ?
                scopePath.Substring(prefix.Length) : "";
            if (!ExactSetEngine.LowerHex(leaf, 32) ||
                !String.Equals(targetPath, scopePath + "\\target", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Run fixture is outside its exact batch scope.");
            return scopePath;
        }
        static string ReadRunDirectoryId(string path) {
            using (SafeFileHandle handle = CreateFileW(path,
                    READ_ATTRIBUTES | LIST_DIRECTORY | READ_CONTROL | SYNCHRONIZE, 7,
                    IntPtr.Zero, OPEN_EXISTING, BACKUP_SEMANTICS | OPEN_REPARSE_POINT,
                    IntPtr.Zero)) {
                if (handle == null || handle.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Run fixture directory identity open failed.");
                Ordinary(handle, true);
                return Identity(handle);
            }
        }
        static void RequireRunPrivateDirectory(string path, string currentSid) {
            DirectorySecurity acl = FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(path));
            if (!acl.AreAccessRulesProtected ||
                acl.GetOwner(typeof(SecurityIdentifier)).Value != currentSid)
                throw new InvalidOperationException("Run fixture directory owner or ACL is not private.");
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true,
                    typeof(SecurityIdentifier))) {
                string sid = rule.IdentityReference.Value;
                if (!seen.Add(sid) ||
                    (sid != currentSid && sid != "S-1-5-18" && sid != "S-1-5-32-544") ||
                    rule.AccessControlType != AccessControlType.Allow ||
                    rule.FileSystemRights != FileSystemRights.FullControl ||
                    rule.IsInherited ||
                    rule.InheritanceFlags != (InheritanceFlags.ContainerInherit |
                        InheritanceFlags.ObjectInherit) ||
                    rule.PropagationFlags != PropagationFlags.None)
                    throw new InvalidOperationException("Run fixture directory has an unexpected ACE.");
            }
            if (seen.Count != 3 || !seen.Contains(currentSid) ||
                !seen.Contains("S-1-5-18") || !seen.Contains("S-1-5-32-544"))
                throw new InvalidOperationException("Run fixture directory ACL is incomplete.");
        }
        static void RequireRunBatchBinding(string scopePath, string batchGuid,
            string expectedSourceSha, string expectedVmGuid, string expectedSid,
            string runsRootId, string batchRootId, string authoritySha) {
            if (!ExactSetEngine.LowerHex(expectedSourceSha, 40) ||
                !ExactSetEngine.LowerHex(runsRootId, 48) ||
                !ExactSetEngine.LowerHex(batchRootId, 48) ||
                !ExactSetEngine.LowerHex(authoritySha, 64) ||
                !Guid.TryParseExact(expectedVmGuid, "D", out Guid vm) ||
                vm == Guid.Empty || expectedVmGuid != vm.ToString("D") ||
                String.IsNullOrEmpty(expectedSid) ||
                WindowsIdentity.GetCurrent().User.Value != expectedSid)
                throw new InvalidOperationException("Run fixture source, VM, SID or frozen identity is invalid.");
            string batchRoot = Path.GetDirectoryName(scopePath);
            string runsRoot = Path.GetDirectoryName(batchRoot);
            string[] paths = new string[] { runsRoot, batchRoot, scopePath };
            List<DirectoryInfo> chain = new List<DirectoryInfo>();
            for (DirectoryInfo ancestor = new DirectoryInfo(scopePath);
                ancestor != null; ancestor = ancestor.Parent) chain.Add(ancestor);
            for (int index = chain.Count - 1; index >= 0; index--) {
                if ((chain[index].Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Run fixture ancestry is reparse.");
            }
            foreach (string path in paths) {
                CheckWindowsComponents(path);
                RequireRunPrivateDirectory(path, expectedSid);
            }
            if (ReadRunDirectoryId(runsRoot) != runsRootId ||
                ReadRunDirectoryId(batchRoot) != batchRootId)
                throw new InvalidOperationException("Run fixture parent or batch FileID changed.");
            string authorityPath = Path.Combine(runsRoot, batchGuid + ".authority.txt");
            FileInfo info = new FileInfo(authorityPath);
            if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0 ||
                info.Length > 1024)
                throw new InvalidOperationException("Run fixture batch authority is absent or unsafe.");
            byte[] bytes;
            using (FileStream input = new FileStream(authorityPath, FileMode.Open,
                    FileAccess.Read, FileShare.Read)) {
                Ordinary(input.SafeFileHandle, false);
                if (input.Length > 1024)
                    throw new InvalidOperationException("Run fixture batch authority exceeded its bound.");
                byte[] bounded = new byte[1025];
                int count = 0, read;
                while (count < bounded.Length &&
                    (read = input.Read(bounded, count, bounded.Length - count)) != 0) count += read;
                if (count > 1024 || input.Length != count)
                    throw new InvalidOperationException("Run fixture batch authority grew or was incomplete.");
                bytes = new byte[count];
                Array.Copy(bounded, bytes, count);
            }
            string observedSha = BitConverter.ToString(SHA256.HashData(bytes)).Replace("-", "")
                .ToLowerInvariant();
            if (observedSha != authoritySha)
                throw new InvalidOperationException("Run fixture batch authority bytes changed.");
            string content = Encoding.UTF8.GetString(bytes);
            if (!content.EndsWith("\n", StringComparison.Ordinal) ||
                content.IndexOf('\r') >= 0 || content.IndexOf('\0') >= 0)
                throw new InvalidOperationException("Run fixture batch authority encoding changed.");
            string[] fields = content.Substring(0, content.Length - 1).Split('\n');
            if (fields.Length != 7 || fields[0] != "dark240-run-batch-v1" ||
                fields[1] != expectedSourceSha || fields[2] != expectedVmGuid ||
                fields[3] != expectedSid || fields[4] != batchGuid ||
                fields[5] != runsRootId || fields[6] != batchRootId)
                throw new InvalidOperationException("Run fixture batch authority fields changed.");
        }
        public static void RequireFixtureApprovalFields(string[] fields,
            string source, string nonceHash, string scopePath, string targetPath,
            string expectedRootId, string manifestDigest) {
            if (fields == null || fields.Length != 6 ||
                String.IsNullOrEmpty(source) || String.IsNullOrEmpty(nonceHash) ||
                String.IsNullOrEmpty(scopePath) || String.IsNullOrEmpty(targetPath) ||
                String.IsNullOrEmpty(expectedRootId) || String.IsNullOrEmpty(manifestDigest) ||
                fields[0] != source || fields[1] != nonceHash ||
                !String.Equals(fields[2], scopePath, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(fields[3], targetPath, StringComparison.OrdinalIgnoreCase) ||
                fields[4] != expectedRootId || fields[5] != manifestDigest)
                throw new InvalidOperationException("Phase B predelete approval differs from source, nonce, root or approved manifest.");
        }
        public static string EncodeComponentUtf16(string name) {
            return ExactSetEngine.EncodeComponentUtf16(name);
        }
        public static string RequireExactManifest(string[] approved, string[] observed) {
            return ExactSetEngine.RequireExactManifest(approved, observed);
        }
        public static ExactManifestTxFFixtureLease PrepareFixtureOnly(
            string scopePath, string targetPath, string nonce, string expectedSourceSha) {
            // Reject every non-fixture pathname before even opening an anchor.
            if (String.IsNullOrEmpty(scopePath) || String.IsNullOrEmpty(targetPath) ||
                !ExactSetEngine.LowerHex(nonce, 32) ||
                !ExactSetEngine.LowerHex(expectedSourceSha, 40))
                throw new InvalidOperationException("Phase B fixture capability is incomplete.");
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string exactScope = RequireFixturePathScope(scopePath, targetPath, profile);
            return PrepareValidatedFixture(exactScope, targetPath, nonce,
                expectedSourceSha, profile, localAppData, null);
        }
        public static ExactManifestTxFFixtureLease PrepareRunFixtureOnly(
            string scopePath, string targetPath, string nonce, string expectedSourceSha,
            string batchGuid, string expectedVmGuid, string expectedSid,
            string runsRootId, string batchRootId, string authoritySha) {
            if (String.IsNullOrEmpty(scopePath) || String.IsNullOrEmpty(targetPath) ||
                !ExactSetEngine.LowerHex(nonce, 32) ||
                !ExactSetEngine.LowerHex(expectedSourceSha, 40))
                throw new InvalidOperationException("Run fixture capability is incomplete.");
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string exactScope = RequireRunFixturePathScope(scopePath, targetPath, profile, batchGuid);
            Action recheck = () => RequireRunBatchBinding(exactScope, batchGuid,
                expectedSourceSha, expectedVmGuid, expectedSid,
                runsRootId, batchRootId, authoritySha);
            recheck();
            return PrepareValidatedFixture(exactScope, targetPath, nonce,
                expectedSourceSha, profile, localAppData, recheck);
        }
        static ExactManifestTxFFixtureLease PrepareValidatedFixture(
            string exactScope, string targetPath, string nonce, string expectedSourceSha,
            string profile, string localAppData, Action runBindingRecheck) {
            if (!String.Equals(localAppData, profile + "\\AppData\\Local",
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Phase B profile temp origin is not independently resolved.");
            string volumeRoot = profile.Substring(0, 3);
            DriveInfo drive = new DriveInfo(volumeRoot);
            if (!drive.IsReady || drive.DriveType != DriveType.Fixed ||
                !String.Equals(drive.DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Phase B fixture requires fixed local NTFS.");
            List<DirectoryInfo> pathChain = new List<DirectoryInfo>();
            for (DirectoryInfo ancestor = new DirectoryInfo(exactScope);
                ancestor != null; ancestor = ancestor.Parent) pathChain.Add(ancestor);
            for (int index = pathChain.Count - 1; index >= 0; index--) {
                DirectoryInfo ancestor = pathChain[index];
                if ((ancestor.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Phase B fixture ancestor is a reparse point.");
            }
            SecurityIdentifier current = WindowsIdentity.GetCurrent().User;
            DirectorySecurity acl = FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(exactScope));
            if (!acl.AreAccessRulesProtected || !acl.GetOwner(typeof(SecurityIdentifier)).Equals(current))
                throw new InvalidOperationException("Phase B fixture root is not private to the current owner.");
            foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
                string sid = rule.IdentityReference.Value;
                if ((sid != current.Value && sid != "S-1-5-18" && sid != "S-1-5-32-544") ||
                    rule.AccessControlType != AccessControlType.Allow ||
                    rule.FileSystemRights != FileSystemRights.FullControl)
                    throw new InvalidOperationException("Phase B fixture ACL contains another writer.");
            }
            string authorityPath = Path.Combine(exactScope, "authority.txt");
            FileInfo authorityInfo = new FileInfo(authorityPath);
            if (!authorityInfo.Exists || (authorityInfo.Attributes & FileAttributes.ReparsePoint) != 0 ||
                authorityInfo.Length > 1024)
                throw new InvalidOperationException("Phase B fixture authority file is absent or unsafe.");
            string[] lines = File.ReadAllLines(authorityPath, Encoding.UTF8);
            string nonceSha = BitConverter.ToString(SHA256.HashData(Encoding.UTF8.GetBytes(nonce)))
                .Replace("-", "").ToLowerInvariant();
            if (lines.Length != 6 || lines[0] != expectedSourceSha || lines[1] != nonceSha ||
                !String.Equals(lines[2], exactScope, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(lines[3], targetPath, StringComparison.OrdinalIgnoreCase) ||
                !ExactSetEngine.LowerHex(lines[4], 48) ||
                !ExactSetEngine.LowerHex(lines[5], 64))
                throw new InvalidOperationException("Phase B fixture authority lacks independently frozen source, nonce, root or manifest.");
            string manifestPath = Path.Combine(exactScope, "approved-manifest.txt");
            FileInfo manifestInfo = new FileInfo(manifestPath);
            if (!manifestInfo.Exists || (manifestInfo.Attributes & FileAttributes.ReparsePoint) != 0 ||
                manifestInfo.Length > 1024 * 1024)
                throw new InvalidOperationException("Phase B approved fixture manifest is absent or unsafe.");
            string[] frozenRows = File.ReadAllLines(manifestPath, Encoding.UTF8);
            if (RequireExactManifest(frozenRows, frozenRows) != lines[5])
                throw new InvalidOperationException("Phase B approved fixture rows differ from authority digest.");
            string predeletePath = Path.Combine(exactScope, "predelete.txt");
            FileInfo predeleteInfo = new FileInfo(predeletePath);
            if (!predeleteInfo.Exists || (predeleteInfo.Attributes & FileAttributes.ReparsePoint) != 0 ||
                predeleteInfo.Length > 1024)
                throw new InvalidOperationException("Phase B predelete approval was not frozen before candidate open.");
            RequireFixtureApprovalFields(File.ReadAllLines(predeletePath, Encoding.UTF8),
                expectedSourceSha, nonceSha, exactScope, targetPath, lines[4], lines[5]);
            FixturePreparation prepared = new FixturePreparation(exactScope, targetPath,
                expectedSourceSha, nonceSha, lines[4], lines[5], frozenRows,
                runBindingRecheck);
            ExactSetEngine exactSet = new ExactSetEngine(prepared);
            exactSet.OpenRoot();
            if (runBindingRecheck != null) {
                try { runBindingRecheck(); }
                catch (Exception primary) {
                    try { exactSet.Dispose(); }
                    catch (Exception closure) { throw new AggregateException(primary, closure); }
                    throw;
                }
            }
            return new ExactManifestTxFFixtureLease(exactSet);
        }
        public string[] ObserveExactManifest() { return engine.ObserveExactManifest(); }
        public string AcquireExactSet() { return engine.AcquireExactSet(); }
        public void StageExactSet(string predeleteReceiptPath) {
            engine.StageExactSet(predeleteReceiptPath);
        }
        public void CommitOnce(string predeleteReceiptPath) {
            engine.CommitOnce(predeleteReceiptPath);
        }
        public bool Abort() { return engine.Abort(); }
        public void Dispose() { engine.Dispose(); }
    }

    // Shared exact-set mechanics are internal and have no direct constructor
    // or production authority entrypoint. The fixture facade above remains the
    // sole factory until a separately reviewed authority contract exists.
    private sealed class ExactSetEngine : IDisposable {
        readonly ExactManifestTxFFixtureLease.FixtureLeaseProtocol lifecycle =
            new ExactManifestTxFFixtureLease.FixtureLeaseProtocol();
        public string LeaseState { get { return lifecycle.State; } }
        public bool ClosureUnknown { get { return lifecycle.ClosureUnknown; } }
        readonly string scope, target, sourceSha;
        readonly List<SafeFileHandle> ancestors = new List<SafeFileHandle>();
        SafeFileHandle rootAnchor, transaction;
        string rootId, approvedDigest, frozenRootId, frozenManifestDigest;
        string[] approvedRows;
        readonly List<FixtureEntry> held = new List<FixtureEntry>();
        readonly List<string> closeReceipts = new List<string>();
        long observedBytes;
        int observedNodes;
        bool rollbackAttempted, commitAttempted;
        bool terminalDisabled;
        bool staged;
        bool closed;
        public string NativeExceptionType { get; private set; }
        public string NativeExceptionMessage { get; private set; }
        public bool IsClosed { get { return closed; } }
        public string FixtureRoot { get { return target; } }
        public string SourceSha { get { return sourceSha; } }
        public string ScopePath { get { return scope; } }
        public string RootId { get { return rootId; } }
        public int StageCalls { get; private set; }
        public int CommitCalls { get; private set; }
        public int RollbackCalls { get; private set; }
        public int LastNativeError { get; private set; }
        public string Settlement { get; private set; } = "not-started";
        public bool TargetHandlesClosed { get; private set; }
        public int HeldEntryCount { get { return held.Count; } }
        public string ApprovedDigest { get { return approvedDigest; } }
        public string[] CloseReceipts { get { return closeReceipts.ToArray(); } }
        public static string EncodeComponentUtf16(string name) {
            if (String.IsNullOrEmpty(name) || name.Length > 255 || name == "." || name == ".." ||
                name.IndexOfAny(new char[] {'\\', '/', ':', '\0'}) >= 0)
                throw new InvalidOperationException("Phase B component is unsafe.");
            return HexName(name);
        }
        public static bool LowerHex(string value, int exactLength) {
            if (value == null || value.Length != exactLength) return false;
            foreach (char unit in value) {
                if (!((unit >= '0' && unit <= '9') || (unit >= 'a' && unit <= 'f'))) return false;
            }
            return true;
        }
        static bool EncodedUtf16(string value) {
            if (String.IsNullOrEmpty(value)) return false;
            try {
                byte[] bytes = Convert.FromBase64String(value);
                return bytes.Length > 0 && (bytes.Length & 1) == 0;
            } catch (FormatException) { return false; }
        }
        static string ValidateManifestRow(string row) {
            if (String.IsNullOrEmpty(row))
                throw new InvalidOperationException("Phase B manifest row is empty.");
            foreach (char unit in row) {
                if (unit < 0x20 || unit > 0x7e)
                    throw new InvalidOperationException("Phase B manifest row is not canonical ASCII.");
            }
            string[] fields = row.Split('|');
            if (fields.Length != 8 || !LowerHex(fields[2], 48) ||
                !EncodedUtf16(fields[5]) || !EncodedUtf16(fields[6]) ||
                fields[7] != "default-stream-only")
                throw new InvalidOperationException("Phase B manifest row is malformed.");
            string path = fields[0];
            if (path != ".") {
                foreach (string component in path.Split('/')) {
                    if (component.Length == 0 || component.Length > 1020 ||
                        (component.Length & 3) != 0 || !LowerHex(component, component.Length))
                        throw new InvalidOperationException("Phase B manifest path is not raw UTF-16 hex.");
                }
            }
            if (fields[1] == "directory") {
                if (fields[3] != "-" || fields[4] != "-")
                    throw new InvalidOperationException("Phase B directory row has file content fields.");
            } else if (fields[1] == "file") {
                long length;
                if (!Int64.TryParse(fields[3], System.Globalization.NumberStyles.None,
                        System.Globalization.CultureInfo.InvariantCulture, out length) ||
                    length < 0 || length > 512L * 1024 * 1024 ||
                    length.ToString(System.Globalization.CultureInfo.InvariantCulture) != fields[3] ||
                    !LowerHex(fields[4], 64))
                    throw new InvalidOperationException("Phase B file row has invalid bounded contents.");
            } else throw new InvalidOperationException("Phase B manifest row has an unknown kind.");
            return path;
        }

        public static string RequireExactManifest(string[] approved, string[] observed) {
            if (approved == null || observed == null || approved.Length == 0 ||
                approved.Length > 20000 || observed.Length != approved.Length)
                throw new InvalidOperationException("Phase B approved manifest is absent, oversized or incomplete.");
            using (MemoryStream stream = new MemoryStream()) {
                HashSet<string> unique = new HashSet<string>(StringComparer.Ordinal);
                string previous = null;
                for (int index = 0; index < approved.Length; index++) {
                    string left = approved[index], right = observed[index];
                    string path = ValidateManifestRow(left);
                    if (!String.Equals(left, right, StringComparison.Ordinal) ||
                        !unique.Add(path) ||
                        (index == 0 && path != ".") ||
                        (index > 0 && (path == "." ||
                            StringComparer.Ordinal.Compare(previous, path) >= 0)))
                        throw new InvalidOperationException("Phase B manifest row differs from the exact approved set.");
                    previous = path;
                    int byteLength = checked(left.Length * 2);
                    for (int shift = 0; shift < 32; shift += 8)
                        stream.WriteByte((byte)(byteLength >> shift));
                    foreach (char unit in left) {
                        stream.WriteByte((byte)unit);
                        stream.WriteByte((byte)(unit >> 8));
                    }
                }
                return BitConverter.ToString(SHA256.HashData(stream.ToArray()))
                    .Replace("-", "").ToLowerInvariant();
            }
        }

        readonly IExactSetPreparation preparation;
        public ExactSetEngine(IExactSetPreparation prepared) {
            if (prepared == null || String.IsNullOrEmpty(prepared.Scope) ||
                String.IsNullOrEmpty(prepared.Target) ||
                !LowerHex(prepared.SourceSha, 40) || !LowerHex(prepared.NonceSha, 64) ||
                !LowerHex(prepared.FrozenRootId, 48) ||
                !LowerHex(prepared.ManifestDigest, 64) ||
                prepared.ApprovedRows == null ||
                RequireExactManifest(prepared.ApprovedRows, prepared.ApprovedRows) !=
                    prepared.ManifestDigest)
                throw new InvalidOperationException("Exact-set prepared binding is incomplete.");
            preparation = prepared;
            scope = prepared.Scope; target = prepared.Target; sourceSha = prepared.SourceSha;
            frozenRootId = prepared.FrozenRootId;
            frozenManifestDigest = prepared.ManifestDigest;
            approvedRows = prepared.ApprovedRows;
        }
        sealed class FixtureEntry {
            public string Path, Row;
            public int Depth;
            public bool Directory;
            public SafeFileHandle Anchor, Writer;
        }
        static SafeFileHandle OpenFixtureRelative(SafeFileHandle parent, string name) {
            if (name.Length == 0 || name.Length > 255 || name == "." || name == ".." ||
                name.IndexOfAny(new char[] {'\\', '/', ':', '\0'}) >= 0)
                throw new InvalidOperationException("Phase B relative component is unsafe.");
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
                    READ_ATTRIBUTES | LIST_DIRECTORY | READ_CONTROL | SYNCHRONIZE,
                    ref attributes, out status, IntPtr.Zero, 0, 7, FILE_OPEN,
                    FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
                    IntPtr.Zero, 0);
                if (code != 0 || result == null || result.IsInvalid) {
                    if (result != null) result.Dispose();
                    throw new InvalidOperationException("Phase B relative anchor failed: NTSTATUS " +
                        ((uint)code).ToString("x8"));
                }
                return result;
            } finally {
                if (unicode != IntPtr.Zero) Marshal.FreeHGlobal(unicode);
                if (characters != IntPtr.Zero) Marshal.FreeHGlobal(characters);
            }
        }
        static string[] SecurityFor(SafeFileHandle file) {
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetSecurityInfo(file, 1, 7,
                out owner, out group, out dacl, out sacl, out descriptor);
            if (error != 0) throw new Win32Exception((int)error, "Phase B held security query failed.");
            IntPtr ownerText = IntPtr.Zero, sddlText = IntPtr.Zero;
            try {
                uint length;
                if (!ConvertSidToStringSidW(owner, out ownerText) ||
                    !ConvertSecurityDescriptorToStringSecurityDescriptorW(
                        descriptor, 1, 7, out sddlText, out length))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Phase B held descriptor conversion failed.");
                return new string[] { Marshal.PtrToStringUni(ownerText),
                    Marshal.PtrToStringUni(sddlText) };
            } finally {
                if (ownerText != IntPtr.Zero) LocalFree(ownerText);
                if (sddlText != IntPtr.Zero) LocalFree(sddlText);
                if (descriptor != IntPtr.Zero) LocalFree(descriptor);
            }
        }
        static string Encoded(string value) {
            return Convert.ToBase64String(Encoding.Unicode.GetBytes(value));
        }
        string DescribeFixture(SafeFileHandle handle, List<string> path, bool directory,
            bool accountBytes = true) {
            Ordinary(handle, directory);
            NoNamedStreams(handle, directory);
            string[] security = SecurityFor(handle);
            string length = "-", hash = "-";
            if (!directory) {
                long bytes = Length(handle);
                if (bytes < 0 || bytes > 512L * 1024 * 1024 - (accountBytes ? observedBytes : 0))
                    throw new InvalidOperationException("Phase B aggregate content bound exceeded.");
                length = bytes.ToString(System.Globalization.CultureInfo.InvariantCulture);
                hash = HashFile(handle, bytes);
                if (accountBytes) observedBytes += bytes;
            }
            return String.Join("|", new string[] {
                path.Count == 0 ? "." : String.Join("/", path.ToArray()),
                directory ? "directory" : "file", Identity(handle), length, hash,
                Encoded(security[0]), Encoded(security[1]), "default-stream-only" });
        }
        void ObserveNode(SafeFileHandle node, List<string> components,
            bool directory, int depth, List<string> rows) {
            if (depth > 64 || ++observedNodes > 20000)
                throw new InvalidOperationException("Phase B entry/depth bound exceeded.");
            rows.Add(DescribeFixture(node, components, directory));
            if (!directory) return;
            List<ChildEntry> children = Names(node, 20000 - observedNodes);
            children.Sort((a, b) => StringComparer.Ordinal.Compare(HexName(a.Name), HexName(b.Name)));
            foreach (ChildEntry child in children) {
                using (SafeFileHandle entry = OpenFixtureRelative(node, child.Name)) {
                    int attributes = Attributes(entry);
                    bool childDirectory = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                    if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                        (child.Attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                        ((attributes ^ child.Attributes) & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
                        Identity(entry).Substring(16) != child.Id)
                        throw new InvalidOperationException("Phase B child changed or became a reparse entry.");
                    List<string> next = new List<string>(components);
                    next.Add(HexName(child.Name));
                    ObserveNode(entry, next, childDirectory, depth + 1, rows);
                }
            }
        }
        public void OpenRoot() {
            string drive = Path.GetPathRoot(scope);
            string[] parts = scope.Substring(drive.Length).Split(Path.DirectorySeparatorChar);
            try {
                ancestors.Add(OpenDrive(drive));
                Ordinary(ancestors[0], true);
                foreach (string part in parts) {
                    SafeFileHandle next = OpenRelative(ancestors[ancestors.Count - 1], part, false);
                    try { Ordinary(next, true); ancestors.Add(next); }
                    catch { next.Dispose(); throw; }
                }
                rootAnchor = OpenFixtureRelative(ancestors[ancestors.Count - 1], "target");
                Ordinary(rootAnchor, true);
                rootId = Identity(rootAnchor);
                if (rootId != frozenRootId)
                    throw new InvalidOperationException("Phase B root differs from the independently frozen fixture identity.");
            } catch { Dispose(); throw; }
        }
        public string[] ObserveExactManifest() {
            if (closed || rootAnchor == null || rootAnchor.IsClosed)
                throw new InvalidOperationException("Phase B root anchor is unavailable.");
            if (Identity(rootAnchor) != rootId)
                throw new InvalidOperationException("Phase B root identity changed.");
            observedBytes = 0; observedNodes = 0;
            List<string> rows = new List<string>();
            ObserveNode(rootAnchor, new List<string>(), true, 0, rows);
            if (Identity(rootAnchor) != rootId)
                throw new InvalidOperationException("Phase B root identity changed while indexing.");
            return rows.ToArray();
        }
        static SafeFileHandle OpenWriter(string path, SafeFileHandle tx, bool directory) {
            const uint FILE_WRITE_DATA = 2, FILE_APPEND_DATA = 4;
            uint access = READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE | DELETE |
                LIST_DIRECTORY | FILE_WRITE_DATA | (directory ? FILE_APPEND_DATA : 0);
            SafeFileHandle result = CreateFileTransactedW(path, access, 3,
                IntPtr.Zero, OPEN_EXISTING,
                OPEN_REPARSE_POINT | (directory ? BACKUP_SEMANTICS : 0),
                IntPtr.Zero, tx, IntPtr.Zero, IntPtr.Zero);
            if (result == null || result.IsInvalid) {
                int error = Marshal.GetLastWin32Error();
                if (result != null) result.Dispose();
                throw new Win32Exception(error, "Phase B exact transacted writer was refused.");
            }
            return result;
        }
        void AcquireNode(SafeFileHandle anchor, string path, List<string> components,
            bool directory, int depth, List<string> rows) {
            if (depth > 64 || held.Count >= 20000)
                throw new InvalidOperationException("Phase B held exact set exceeds its bounds.");
            Ordinary(anchor, directory);
            FixtureEntry item = new FixtureEntry {
                Path = path, Directory = directory, Depth = depth, Anchor = anchor
            };
            held.Add(item);
            item.Row = DescribeFixture(anchor, components, directory);
            item.Writer = OpenWriter(path, transaction, directory);
            Ordinary(item.Writer, directory);
            NoNamedStreams(item.Writer, directory);
            if (Identity(anchor) != Identity(item.Writer))
                throw new InvalidOperationException("Phase B transacted writer differs from its relative anchor.");
            if (!directory) {
                long pointer;
                if (!SetFilePointerEx(item.Writer, 0, out pointer, 0) || pointer != 0)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Phase B transacted content pointer reset failed.");
            }
            // The writer is a distinct, transaction-bound object. Re-read its
            // complete row rather than trusting the ordinary anchor alone.
            string writerRow = DescribeFixture(item.Writer, components, directory, false);
            if (!String.Equals(item.Row, writerRow, StringComparison.Ordinal))
                throw new InvalidOperationException("Phase B transacted writer content/security differs.");
            rows.Add(item.Row);
            if (!directory) return;
            List<ChildEntry> children = Names(anchor, 20000 - held.Count);
            children.Sort((a, b) => StringComparer.Ordinal.Compare(HexName(a.Name), HexName(b.Name)));
            foreach (ChildEntry child in children) {
                SafeFileHandle next = OpenFixtureRelative(anchor, child.Name);
                try {
                    int attributes = Attributes(next);
                    bool childDirectory = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                    if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                        (child.Attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                        ((attributes ^ child.Attributes) & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
                        Identity(next).Substring(16) != child.Id)
                        throw new InvalidOperationException("Phase B held child changed or became a reparse entry.");
                    List<string> childComponents = new List<string>(components);
                    childComponents.Add(HexName(child.Name));
                    AcquireNode(next, Path.Combine(path, child.Name), childComponents,
                        childDirectory, depth + 1, rows);
                } catch (Exception primary) {
                    bool transferred = held.Exists(entry => Object.ReferenceEquals(entry.Anchor, next));
                    if (!transferred) {
                        try { CloseOwned(ref next, "untransferred-child:" + child.Name); }
                        catch (Exception closeFailure) {
                            throw new AggregateException(primary, closeFailure);
                        }
                    }
                    throw;
                }
            }
        }
        public string AcquireExactSet() {
            if (closed || terminalDisabled || transaction != null || held.Count != 0 || approvedRows == null)
                throw new InvalidOperationException("Phase B exact set was already acquired or closed.");
            try {
                string[] initial = ObserveExactManifest();
                string digest = RequireExactManifest(approvedRows, initial);
                if (digest != frozenManifestDigest)
                    throw new InvalidOperationException("Phase B observed manifest differs from the independently frozen digest.");
                transaction = CreateTransaction(IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 15000,
                    "Dark180 fixture-only exact manifest Phase B");
                if (transaction == null || transaction.IsInvalid) {
                    int error = Marshal.GetLastWin32Error();
                    if (transaction != null) transaction.Dispose();
                    transaction = null;
                    throw new Win32Exception(error, "Phase B transaction could not be created.");
                }
                observedBytes = 0; observedNodes = 0;
                List<string> heldRows = new List<string>();
                AcquireNode(rootAnchor, target, new List<string>(), true, 0, heldRows);
                RequireExactManifest(approvedRows, heldRows.ToArray());
                RequireExactManifest(approvedRows, ObserveExactManifest());
                approvedDigest = digest;
                Settlement = "active-exact-set";
                lifecycle.Acquired();
                return digest;
            } catch (Exception primary) {
                try {
                    if (!Abort()) throw new InvalidOperationException("Phase B rollback outcome is unknown.");
                }
                catch (Exception settlement) { throw new AggregateException(primary, settlement); }
                throw;
            }
        }
        void CloseOwned(ref SafeFileHandle handle, string label) {
            SafeFileHandle owned = handle;
            handle = null; // transfer ownership before any native close result
            if (owned == null) return;
            bool attempted = !owned.IsClosed && !owned.IsInvalid;
            bool success = false;
            int error = -1;
            Exception nativeFailure = null;
            try {
                if (attempted) {
                    success = CloseHandleForFixture(owned.DangerousGetHandle());
                    error = success ? 0 : Marshal.GetLastWin32Error();
                }
            } catch (Exception failure) {
                nativeFailure = failure;
                NativeExceptionType = failure.GetType().FullName;
                NativeExceptionMessage = failure.Message;
            }
            finally {
                owned.SetHandleAsInvalid(); // no SafeHandle retry after one native attempt
                owned.Dispose();
                closeReceipts.Add(label + ":" + (success ? "closed" :
                    "unknown:" + error + (nativeFailure == null ? "" :
                    ":" + nativeFailure.GetType().FullName + ":" + nativeFailure.Message)));
                if (!success) lifecycle.CloseUnknown();
            }
            if (!success) {
                LastNativeError = error;
                if (nativeFailure != null)
                    throw new InvalidOperationException("Phase B owned handle closure threw: " + label,
                        nativeFailure);
                throw new Win32Exception(error, "Phase B owned handle closure is unknown: " + label);
            }
        }
        void CloseTargetHandles() {
            Exception first = null;
            for (int index = held.Count - 1; index >= 0; index--) {
                FixtureEntry entry = held[index];
                if (Object.ReferenceEquals(rootAnchor, entry.Anchor)) rootAnchor = null;
                try { CloseOwned(ref entry.Writer, "writer:" + index); }
                catch (Exception failure) { if (first == null) first = failure; }
                try { CloseOwned(ref entry.Anchor, "anchor:" + index); }
                catch (Exception failure) { if (first == null) first = failure; }
            }
            if (rootAnchor != null) {
                try { CloseOwned(ref rootAnchor, "root-anchor"); }
                catch (Exception failure) { if (first == null) first = failure; }
            }
            if (first != null) throw first;
            TargetHandlesClosed = !lifecycle.ClosureUnknown;
        }
        void RequirePredeleteReceipt(string receiptPath) {
            preparation.RequirePredeleteReceipt(receiptPath, rootId, approvedDigest);
        }
        public void StageExactSet(string predeleteReceiptPath) {
            if (closed || terminalDisabled || transaction == null || approvedRows == null || staged)
                throw new InvalidOperationException("Phase B lacks a current independent fixture approval.");
            try {
                RequirePredeleteReceipt(predeleteReceiptPath);
                RequireExactManifest(approvedRows, ObserveExactManifest());
                lifecycle.StageStarted();
                List<FixtureEntry> order = new List<FixtureEntry>(held);
                order.Sort((a, b) => {
                    int depth = b.Depth.CompareTo(a.Depth);
                    return depth != 0 ? depth : StringComparer.Ordinal.Compare(a.Path, b.Path);
                });
                foreach (FixtureEntry entry in order) {
                    StageCalls++;
                    if (!SetFileInformationByHandle(entry.Writer, FILE_DISPOSITION_INFO,
                        new byte[] { 1 }, 1)) {
                        LastNativeError = Marshal.GetLastWin32Error();
                        throw new Win32Exception(LastNativeError,
                            "Phase B exact entry disposition was refused.");
                    }
                    if (Object.ReferenceEquals(rootAnchor, entry.Anchor)) rootAnchor = null;
                    CloseOwned(ref entry.Writer, "staged-writer:" + entry.Path);
                    CloseOwned(ref entry.Anchor, "staged-anchor:" + entry.Path);
                }
                TargetHandlesClosed = true;
                staged = true;
                Settlement = "staged-target-handles-closed";
                lifecycle.StageCompleted();
            } catch (Exception primary) {
                try {
                    if (!Abort()) throw new InvalidOperationException("Phase B rollback outcome is unknown.");
                }
                catch (Exception settlement) { throw new AggregateException(primary, settlement); }
                throw;
            }
        }
        public void CommitOnce(string predeleteReceiptPath) {
            if (closed || terminalDisabled || !staged || !TargetHandlesClosed ||
                lifecycle.ClosureUnknown || transaction == null || commitAttempted || rollbackAttempted)
                throw new InvalidOperationException("Phase B commit lacks exact staged authority.");
            try {
                RequirePredeleteReceipt(predeleteReceiptPath);
                lifecycle.CommitRequested();
            } catch (Exception primary) {
                try {
                    if (!Abort()) throw new InvalidOperationException("Phase B rollback outcome is unknown.");
                }
                catch (Exception settlement) { throw new AggregateException(primary, settlement); }
                throw;
            }
            commitAttempted = true; CommitCalls++;
            try {
                if (!CommitTransaction(transaction)) {
                    LastNativeError = Marshal.GetLastWin32Error();
                    throw new Win32Exception(LastNativeError, "Phase B commit outcome is unknown.");
                }
            } catch (Exception failure) {
                NativeExceptionType = failure.GetType().FullName;
                NativeExceptionMessage = failure.Message;
                Settlement = "commit-outcome-unknown";
                terminalDisabled = true;
                lifecycle.CommitReturned(false);
                throw;
            }
            Settlement = "commit-call-succeeded-poststate-unverified";
            terminalDisabled = true;
            lifecycle.CommitReturned(true);
        }
        public bool Abort() {
            if (commitAttempted || rollbackAttempted || terminalDisabled)
                throw new InvalidOperationException("Phase B settlement cannot repeat or follow commit.");
            terminalDisabled = true;
            if (transaction == null) {
                lifecycle.RejectedBeforeTransaction();
                return true;
            }
            Exception closeFailure = null;
            try { CloseTargetHandles(); }
            catch (Exception failure) { closeFailure = failure; }
            rollbackAttempted = true; RollbackCalls++;
            bool rollbackSucceeded = false;
            Exception rollbackFailure = null;
            try {
                rollbackSucceeded = RollbackTransaction(transaction);
                if (!rollbackSucceeded) LastNativeError = Marshal.GetLastWin32Error();
            } catch (Exception failure) {
                rollbackFailure = failure; LastNativeError = -1;
                NativeExceptionType = failure.GetType().FullName;
                NativeExceptionMessage = failure.Message;
            }
            if (!rollbackSucceeded) {
                Settlement = "rollback-outcome-unknown";
                lifecycle.RolledBack(false);
                if (rollbackFailure != null) {
                    if (closeFailure != null) throw new AggregateException(closeFailure, rollbackFailure);
                    throw new InvalidOperationException("Phase B rollback native call threw; outcome unknown.", rollbackFailure);
                }
                if (closeFailure != null) throw closeFailure;
                return false;
            }
            Settlement = lifecycle.ClosureUnknown ? "rollback-succeeded-closure-unknown" : "rollback-succeeded";
            lifecycle.RolledBack(true);
            if (closeFailure != null) throw closeFailure;
            return true;
        }
        public void Dispose() {
            if (closed) return;
            closed = true;
            Exception first = null;
            if (transaction != null && !commitAttempted && !rollbackAttempted) {
                try { Abort(); }
                catch (Exception failure) { first = failure; }
            }
            try { CloseTargetHandles(); }
            catch (Exception failure) { if (first == null) first = failure; }
            held.Clear();
            for (int index = ancestors.Count - 1; index >= 0; index--) {
                SafeFileHandle ancestor = ancestors[index]; ancestors[index] = null;
                try { CloseOwned(ref ancestor, "ancestor:" + index); }
                catch (Exception failure) { if (first == null) first = failure; }
            }
            ancestors.Clear();
            try { CloseOwned(ref transaction, "transaction"); }
            catch (Exception failure) { if (first == null) first = failure; }
            if (first != null) throw first;
        }
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
