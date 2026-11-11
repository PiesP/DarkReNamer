using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

// Disposable diagnostic only. Do not use this helper for a retained target.
public static class DarkTxfHandoffProbe
{
    public const uint ReadAttributes = 0x80, ReadControl = 0x20000, Synchronize = 0x100000;
    public const uint ListDirectory = 1, GenericRead = 0x80000000, GenericWrite = 0x40000000, Delete = 0x10000;
    public const uint ShareRead = 1, ShareWrite = 2, ShareDelete = 4, ShareAll = 7;
    public const uint OpenExisting = 3, CreateNew = 1;
    public const uint BackupSemantics = 0x02000000, OpenReparsePoint = 0x00200000;
    const int FileIdInfo = 18, FileAttributeTagInfo = 9, FileDispositionInfo = 4;
    const uint ObjCaseInsensitive = 0x40, ObjDontReparse = 0x1000;
    const uint FileOpen = 1, FileOpenReparsePoint = 0x00200000, FileSynchronousIoNonalert = 0x20;
    const int FileAttributeDirectory = 0x10, FileAttributeReparsePoint = 0x400;

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
    public sealed class OpenResult {
        public SafeFileHandle Handle;
        public int Error;
        public string NtStatus;
        public bool Accepted { get { return Handle != null && !Handle.IsInvalid; } }
    }
    [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", EntryPoint="CreateFileTransactedW", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    static extern SafeFileHandle CreateFileTransacted(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template, SafeFileHandle tx, IntPtr version, IntPtr extended);
    [DllImport("ntdll.dll")]
    static extern int NtCreateFile(out SafeFileHandle file, uint access, ref ObjectAttributes attributes,
        out IoStatusBlock status, IntPtr allocationSize, uint fileAttributes, uint share,
        uint disposition, uint options, IntPtr eaBuffer, uint eaLength);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file, int kind, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteFile(SafeFileHandle file, byte[] data, uint size, out uint written, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(SafeFileHandle file, byte[] data, uint size, out uint read, IntPtr overlapped);
    [DllImport("KtmW32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateTransaction(IntPtr security, IntPtr uow, uint options,
        uint isolation, uint flags, uint timeout, string description);
    [DllImport("KtmW32.dll", SetLastError=true)]
    static extern bool CommitTransaction(SafeFileHandle transaction);
    [DllImport("KtmW32.dll", SetLastError=true)]
    static extern bool RollbackTransaction(SafeFileHandle transaction);

    static OpenResult Wrap(SafeFileHandle h) {
        int error = Marshal.GetLastWin32Error();
        return new OpenResult { Handle=h, Error=(h == null || h.IsInvalid) ? error : 0 };
    }
    public static OpenResult Parent(string path) {
        return Wrap(CreateFile(path, ReadAttributes | ListDirectory | ReadControl | Synchronize,
            ShareRead, IntPtr.Zero, OpenExisting, BackupSemantics | OpenReparsePoint, IntPtr.Zero));
    }
    public static OpenResult Relative(SafeFileHandle parent, string name, bool directory, uint share) {
        if (String.IsNullOrEmpty(name) || name == "." || name == ".." ||
            name.IndexOfAny(new char[]{'\\','/',':','\0'}) >= 0) throw new ArgumentException("Unsafe component");
        IntPtr nameBytes = IntPtr.Zero, unicodeBytes = IntPtr.Zero;
        try {
            nameBytes = Marshal.StringToHGlobalUni(name);
            UnicodeString u = new UnicodeString { Length=checked((ushort)(name.Length*2)),
                MaximumLength=checked((ushort)((name.Length+1)*2)), Buffer=nameBytes };
            unicodeBytes = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
            Marshal.StructureToPtr(u, unicodeBytes, false);
            ObjectAttributes a = new ObjectAttributes { Length=(uint)Marshal.SizeOf<ObjectAttributes>(),
                RootDirectory=parent.DangerousGetHandle(), ObjectName=unicodeBytes,
                Attributes=ObjCaseInsensitive | ObjDontReparse };
            SafeFileHandle h;
            IoStatusBlock result;
            int status = NtCreateFile(out h, ReadAttributes | ReadControl | Synchronize |
                (directory ? ListDirectory : 1), ref a, out result, IntPtr.Zero, 0, share,
                FileOpen, FileOpenReparsePoint | FileSynchronousIoNonalert, IntPtr.Zero, 0);
            return new OpenResult { Handle=h, Error=0, NtStatus=((uint)status).ToString("x8") };
        } finally {
            if (unicodeBytes != IntPtr.Zero) Marshal.FreeHGlobal(unicodeBytes);
            if (nameBytes != IntPtr.Zero) Marshal.FreeHGlobal(nameBytes);
        }
    }
    public static OpenResult Begin() {
        return Wrap(CreateTransaction(IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 20000, "Dark180 isolated phase A"));
    }
    public static OpenResult Writer(string path, SafeFileHandle tx, bool directory) {
        return Wrap(CreateFileTransacted(path, ReadAttributes | ReadControl | GenericRead | GenericWrite | Delete,
            ShareRead | ShareWrite, IntPtr.Zero, OpenExisting,
            OpenReparsePoint | (directory ? BackupSemantics : 0), IntPtr.Zero, tx,
            IntPtr.Zero, IntPtr.Zero));
    }
    public static OpenResult ExternalWriter(string path, bool create) {
        return Wrap(CreateFile(path, GenericWrite, ShareAll, IntPtr.Zero,
            create ? CreateNew : OpenExisting, 0x80, IntPtr.Zero));
    }
    public static string Identity(SafeFileHandle h, bool directory) {
        byte[] id = new byte[24], attr = new byte[8];
        if (!GetFileInformationByHandleEx(h, FileIdInfo, id, 24) ||
            !GetFileInformationByHandleEx(h, FileAttributeTagInfo, attr, 8))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        int flags = BitConverter.ToInt32(attr, 0);
        if ((flags & FileAttributeReparsePoint) != 0 ||
            ((flags & FileAttributeDirectory) != 0) != directory)
            throw new InvalidOperationException("Fixture entry is reparse/changed kind");
        return BitConverter.ToString(id).Replace("-", "").ToLowerInvariant();
    }
    public static int Stage(SafeFileHandle h) {
        if (SetFileInformationByHandle(h, FileDispositionInfo, new byte[]{1}, 1)) return 0;
        return Marshal.GetLastWin32Error();
    }
    public static int WriteOne(SafeFileHandle h, byte value) {
        uint written;
        if (!WriteFile(h, new byte[]{value}, 1, out written, IntPtr.Zero)) return Marshal.GetLastWin32Error();
        return written == 1 ? 0 : -1;
    }
    public static string HashSixBytes(SafeFileHandle h) {
        byte[] buffer = new byte[7];
        uint read;
        if (!ReadFile(h, buffer, (uint)buffer.Length, out read, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Transacted fixture data read failed");
        if (read != 6) throw new InvalidOperationException("Transacted fixture data length changed");
        byte[] actual = new byte[6];
        Array.Copy(buffer, actual, 6);
        return Convert.ToHexString(SHA256.HashData(actual)).ToLowerInvariant();
    }
    public static int Commit(SafeFileHandle tx) {
        if (CommitTransaction(tx)) return 0;
        return Marshal.GetLastWin32Error();
    }
    public static int Rollback(SafeFileHandle tx) {
        if (RollbackTransaction(tx)) return 0;
        return Marshal.GetLastWin32Error();
    }
}
