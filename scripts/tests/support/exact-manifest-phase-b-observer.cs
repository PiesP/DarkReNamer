using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

// Independent, read-only fixture observer. It never creates a transaction or
// receives a candidate lease. The observer-actor child freezes these rows
// before any adversarial operation or candidate worker starts.
public static class DarkPhaseBFixtureObserver {
    const uint ReadData = 1, ReadAttributes = 0x80, ReadControl = 0x20000;
    const uint ShareAll = 7, OpenExisting = 3;
    const uint BackupSemantics = 0x02000000, OpenReparsePoint = 0x00200000;
    const int FileIdInfo = 18, FileAttributeTagInfo = 9, FileStreamInfo = 7;
    const int DirectoryAttribute = 0x10, ReparseAttribute = 0x400;

    [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode,
        ExactSpelling=true, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind,
        byte[] buffer, uint size);

    static SafeFileHandle Open(string path, bool directory) {
        SafeFileHandle handle=CreateFile(path, ReadData|ReadAttributes|ReadControl,
            ShareAll, IntPtr.Zero, OpenExisting,
            OpenReparsePoint|(directory ? BackupSemantics : 0), IntPtr.Zero);
        if (handle == null || handle.IsInvalid) {
            int error=Marshal.GetLastWin32Error();
            if (handle != null) handle.Dispose();
            throw new Win32Exception(error, "Independent fixture observation could not open entry.");
        }
        return handle;
    }
    static byte[] Info(SafeFileHandle file, int kind, int size) {
        byte[] buffer=new byte[size];
        if (!GetFileInformationByHandleEx(file, kind, buffer, (uint)size))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Independent fixture handle information query failed.");
        return buffer;
    }
    static string Id(SafeFileHandle file, bool directory) {
        byte[] attrs=Info(file, FileAttributeTagInfo, 8);
        int value=BitConverter.ToInt32(attrs,0);
        if ((value & ReparseAttribute)!=0 || ((value & DirectoryAttribute)!=0)!=directory)
            throw new InvalidOperationException("Independent fixture entry changed kind or is reparse.");
        return BitConverter.ToString(Info(file,FileIdInfo,24)).Replace("-","").ToLowerInvariant();
    }
    static void DefaultStreamsOnly(SafeFileHandle file, bool directory) {
        int size=4096;
        while (size<=1024*1024) {
            byte[] bytes=new byte[size];
            if (GetFileInformationByHandleEx(file,FileStreamInfo,bytes,(uint)size)) {
                int offset=0,count=0;
                while (true) {
                    if (offset>size-24 || ++count>20000)
                        throw new InvalidOperationException("Independent stream inventory is malformed.");
                    uint next=BitConverter.ToUInt32(bytes,offset);
                    uint nameBytes=BitConverter.ToUInt32(bytes,offset+4);
                    if ((nameBytes&1)!=0 || nameBytes>size-offset-24 ||
                        (next!=0 && ((next&7)!=0 || next<24+nameBytes || next>size-offset)))
                        throw new InvalidOperationException("Independent stream frame is malformed.");
                    string name=Encoding.Unicode.GetString(bytes,offset+24,(int)nameBytes);
                    bool allowed=directory ?
                        String.Equals(name,"::$INDEX_ALLOCATION",StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name,":$I30:$INDEX_ALLOCATION",StringComparison.OrdinalIgnoreCase) :
                        name.Length==0 || String.Equals(name,"::$DATA",StringComparison.OrdinalIgnoreCase);
                    if (!allowed)
                        throw new InvalidOperationException("Independent fixture found an unapproved named stream.");
                    if (next==0) return;
                    offset+=(int)next;
                }
            }
            int error=Marshal.GetLastWin32Error();
            if (directory && error==38) return;
            if (error!=122 && error!=234)
                throw new Win32Exception(error,"Independent stream inventory failed.");
            size*=2;
        }
        throw new InvalidOperationException("Independent stream inventory exceeded its bound.");
    }
    static string HexName(string name) {
        if (String.IsNullOrEmpty(name) || name.Length>255 || name=="." || name==".." ||
            name.IndexOfAny(new char[]{'\\','/',':','\0'})>=0)
            throw new InvalidOperationException("Independent fixture name is unsafe.");
        char[] digits="0123456789abcdef".ToCharArray(), output=new char[name.Length*4];
        for (int i=0;i<name.Length;i++) {
            ushort unit=name[i]; byte low=(byte)unit,high=(byte)(unit>>8);
            output[i*4]=digits[low>>4];output[i*4+1]=digits[low&15];
            output[i*4+2]=digits[high>>4];output[i*4+3]=digits[high&15];
        }
        return new string(output);
    }
    static string Encoded(string value) {
        return Convert.ToBase64String(Encoding.Unicode.GetBytes(value));
    }
    static string[] Security(string path, bool directory) {
        FileSystemSecurity acl=directory ?
            (FileSystemSecurity)FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(path)) :
            (FileSystemSecurity)FileSystemAclExtensions.GetAccessControl(new FileInfo(path));
        return new string[] {
            acl.GetOwner(typeof(SecurityIdentifier)).Value,
            acl.GetSecurityDescriptorSddlForm(AccessControlSections.Owner|
                AccessControlSections.Group|AccessControlSections.Access)
        };
    }
    static string[] Content(string path, long remaining) {
        using (FileStream stream=new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite|FileShare.Delete)) {
            long length=stream.Length;
            if (length<0 || length>remaining)
                throw new InvalidOperationException("Independent fixture content exceeded aggregate bound.");
            string hash=BitConverter.ToString(SHA256.HashData(stream)).Replace("-","").ToLowerInvariant();
            if (stream.Position!=length || stream.Length!=length)
                throw new InvalidOperationException("Independent fixture content changed while hashing.");
            return new string[] { length.ToString(System.Globalization.CultureInfo.InvariantCulture),hash };
        }
    }
    static void Visit(string path, List<string> components, int depth,
        List<string> rows, ref long bytes) {
        if (depth>64 || rows.Count>=20000)
            throw new InvalidOperationException("Independent fixture traversal exceeded bounds.");
        bool directory=(File.GetAttributes(path)&FileAttributes.Directory)!=0;
        using (SafeFileHandle handle=Open(path,directory)) {
            string before=Id(handle,directory);
            DefaultStreamsOnly(handle,directory);
            string[] security=Security(path,directory);
            string length="-",hash="-";
            if (!directory) {
                string[] content=Content(path,512L*1024*1024-bytes);
                length=content[0];hash=content[1];
                bytes+=Int64.Parse(length,System.Globalization.CultureInfo.InvariantCulture);
            }
            string row=String.Join("|",new string[]{
                components.Count==0 ? "." : String.Join("/",components.ToArray()),
                directory ? "directory" : "file",before,length,hash,
                Encoded(security[0]),Encoded(security[1]),"default-stream-only"});
            rows.Add(row);
            if (directory) {
                List<string> children=new List<string>(Directory.EnumerateFileSystemEntries(path));
                children.Sort((a,b)=>StringComparer.Ordinal.Compare(
                    HexName(Path.GetFileName(a)),HexName(Path.GetFileName(b))));
                foreach (string child in children) {
                    List<string> next=new List<string>(components);
                    next.Add(HexName(Path.GetFileName(child)));
                    Visit(child,next,depth+1,rows,ref bytes);
                }
            }
            if (Id(handle,directory)!=before)
                throw new InvalidOperationException("Independent fixture identity changed while observing.");
        }
    }
    public static string[] Freeze(string root) {
        List<string> rows=new List<string>();long bytes=0;
        Visit(root,new List<string>(),0,rows,ref bytes);
        return rows.ToArray();
    }
    public static string IdentityOf(string path,bool directory) {
        using (SafeFileHandle handle=Open(path,directory)) return Id(handle,directory);
    }
    public static string DigestRows(string[] rows) {
        if (rows==null || rows.Length==0 || rows.Length>20000)
            throw new InvalidOperationException("Independent approved row count is invalid.");
        using (MemoryStream data=new MemoryStream()) {
            foreach (string row in rows) {
                if (String.IsNullOrEmpty(row))
                    throw new InvalidOperationException("Independent approved row is empty.");
                int count=checked(row.Length*2);
                data.WriteByte((byte)count);data.WriteByte((byte)(count>>8));
                data.WriteByte((byte)(count>>16));data.WriteByte((byte)(count>>24));
                foreach (char unit in row) {
                    data.WriteByte((byte)unit);data.WriteByte((byte)(unit>>8));
                }
            }
            return BitConverter.ToString(SHA256.HashData(data.ToArray()))
                .Replace("-","").ToLowerInvariant();
        }
    }
}
