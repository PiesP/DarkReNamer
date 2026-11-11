using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

// Deliberately limited to one named file inside an exact Phase-B fixture.
// These actors cannot acquire a transaction or commit authority.
public static class DarkPhaseBFixtureActors {
    const uint ReadControl=0x20000, WriteDac=0x40000, GenericWrite=0x40000000;
    const uint ShareAll=7, OpenExisting=3, CreateNew=1;
    [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode,
        ExactSpelling=true, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path,uint access,uint share,
        IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("advapi32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetSecurityDescriptorDacl(IntPtr descriptor,
        [MarshalAs(UnmanagedType.Bool)] out bool present,out IntPtr dacl,
        [MarshalAs(UnmanagedType.Bool)] out bool defaulted);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint SetSecurityInfo(SafeFileHandle file,int objectType,uint requested,
        IntPtr owner,IntPtr group,IntPtr dacl,IntPtr sacl);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint GetSecurityInfo(SafeFileHandle file,int objectType,uint requested,
        out IntPtr owner,out IntPtr group,out IntPtr dacl,out IntPtr sacl,
        out IntPtr descriptor);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
        IntPtr descriptor,uint revision,uint information,out IntPtr output,out uint length);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteFile(SafeFileHandle file,byte[] bytes,uint size,
        out uint written,IntPtr overlapped);

    static string ApprovedFile(string scope,string target) {
        string profile=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (profile.Length<4 ||
            !Char.IsLetter(profile[0]) || profile[1]!=':' || profile[2]!='\\' ||
            !String.Equals(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                profile+"\\AppData\\Local",StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Phase B actor lacks a canonical local profile.");
        DriveInfo drive=new DriveInfo(profile.Substring(0,3));
        if (!drive.IsReady || drive.DriveType!=DriveType.Fixed ||
            !String.Equals(drive.DriveFormat,"NTFS",StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Phase B actor requires fixed local NTFS.");
        string expected=profile+"\\AppData\\Local\\Temp\\Dark180-TxfPhaseB\\";
        string leaf=scope.StartsWith(expected,StringComparison.OrdinalIgnoreCase) ?
            scope.Substring(expected.Length) : "";
        Guid parsed;
        if (!Guid.TryParseExact(leaf,"N",out parsed) ||
            !String.Equals(target,scope+"\\target",StringComparison.OrdinalIgnoreCase) ||
            profile.IndexOf("DarkReNamerVmRuns",StringComparison.OrdinalIgnoreCase)>=0)
            throw new InvalidOperationException("Phase B actor escaped its exact private fixture scope.");
        foreach (string component in (target+"\\approved.bin").Substring(3).Split('\\')) {
            if (component.Length==0 || component=="." || component==".." ||
                component.EndsWith(".",StringComparison.Ordinal) ||
                component.EndsWith(" ",StringComparison.Ordinal) || component.IndexOf('~')>=0 ||
                String.Equals(component,"DarkReNamerVmRuns",StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Phase B actor path has an alias or protected-root component.");
        }
        List<DirectoryInfo> ancestry=new List<DirectoryInfo>();
        for (DirectoryInfo item=new DirectoryInfo(target);item!=null;item=item.Parent)
            ancestry.Add(item);
        for (int index=ancestry.Count-1;index>=0;index--)
            if ((ancestry[index].Attributes&FileAttributes.ReparsePoint)!=0)
                throw new InvalidOperationException("Phase B actor ancestor is reparse.");
        DirectorySecurity acl=FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(scope));
        if (!acl.AreAccessRulesProtected ||
            !acl.GetOwner(typeof(SecurityIdentifier)).Equals(WindowsIdentity.GetCurrent().User))
            throw new InvalidOperationException("Phase B actor fixture root lacks a private owner/ACL.");
        foreach (string name in new string[]{"authority.txt","approved-manifest.txt","predelete.txt"}) {
            FileInfo required=new FileInfo(scope+"\\"+name);
            if (!required.Exists || (required.Attributes&FileAttributes.ReparsePoint)!=0)
                throw new InvalidOperationException("Phase B actor fixture authority is absent or reparse.");
        }
        string path=target+"\\approved.bin";
        FileAttributes attrs=File.GetAttributes(path);
        if ((attrs&(FileAttributes.Directory|FileAttributes.ReparsePoint))!=0)
            throw new InvalidOperationException("Phase B actor target is not an ordinary approved fixture file.");
        return path;
    }
    public sealed class HeldDacl : IDisposable {
        internal SafeFileHandle Handle;
        internal FileSecurity Baseline;
        internal HeldDacl(SafeFileHandle handle,FileSecurity baseline) {
            Handle=handle;Baseline=baseline;
        }
        public void Dispose() { if (Handle!=null) {Handle.Dispose();Handle=null;} }
    }
    public static HeldDacl OpenHeldDacl(string scope,string target) {
        string path=ApprovedFile(scope,target);
        FileSecurity baseline=FileSystemAclExtensions.GetAccessControl(new FileInfo(path));
        SafeFileHandle handle=CreateFile(path,ReadControl|WriteDac,ShareAll,
            IntPtr.Zero,OpenExisting,0,IntPtr.Zero);
        if (handle==null || handle.IsInvalid) {
            int error=Marshal.GetLastWin32Error();
            if (handle!=null) handle.Dispose();
            throw new Win32Exception(error,"Phase B standard-right actor open failed.");
        }
        return new HeldDacl(handle,baseline);
    }
    public sealed class DaclChangeResult {
        public int NativeError {get;set;}
        public bool Changed {get;set;}
        public string Before {get;set;}
        public string After {get;set;}
    }
    static string HeldSddl(SafeFileHandle held) {
        IntPtr owner,group,dacl,sacl,descriptor;
        uint error=GetSecurityInfo(held,1,7,out owner,out group,out dacl,out sacl,
            out descriptor);
        if (error!=0) throw new Win32Exception((int)error,"Phase B held DACL readback failed.");
        IntPtr text=IntPtr.Zero;
        try {
            uint length;
            if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor,1,7,
                    out text,out length))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Phase B held DACL conversion failed.");
            return Marshal.PtrToStringUni(text);
        } finally {
            if (text!=IntPtr.Zero) LocalFree(text);
            if (descriptor!=IntPtr.Zero) LocalFree(descriptor);
        }
    }
    public static DaclChangeResult AddAuthenticatedUsersReadAttributes(HeldDacl held) {
        if (held==null || held.Handle==null || held.Handle.IsClosed || held.Handle.IsInvalid)
            throw new InvalidOperationException("Phase B held DACL capability is unavailable.");
        string before=HeldSddl(held.Handle);
        SecurityIdentifier authenticated=new SecurityIdentifier("S-1-5-11");
        held.Baseline.AddAccessRule(new FileSystemAccessRule(authenticated,
            FileSystemRights.ReadAttributes,AccessControlType.Allow));
        byte[] descriptor=held.Baseline.GetSecurityDescriptorBinaryForm();
        GCHandle pin=GCHandle.Alloc(descriptor,GCHandleType.Pinned);
        try {
            bool present,defaulted;IntPtr dacl;
            if (!GetSecurityDescriptorDacl(pin.AddrOfPinnedObject(),out present,
                    out dacl,out defaulted) || !present || dacl==IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Phase B actor could not inspect its proposed DACL.");
            uint result=SetSecurityInfo(held.Handle,1,4,IntPtr.Zero,IntPtr.Zero,dacl,IntPtr.Zero);
            string after=HeldSddl(held.Handle);
            return new DaclChangeResult { NativeError=(int)result,
                Changed=!String.Equals(before,after,StringComparison.Ordinal),
                Before=before,After=after };
        } finally { pin.Free(); }
    }
    public sealed class HeldMapping : IDisposable {
        MemoryMappedFile map;
        MemoryMappedViewAccessor view;
        internal HeldMapping(MemoryMappedFile file,MemoryMappedViewAccessor accessor) {
            map=file;view=accessor;
        }
        public void WriteOne(byte value) { view.Write(0,value);view.Flush(); }
        public void Dispose() {
            if (view!=null) {view.Dispose();view=null;}
            if (map!=null) {map.Dispose();map=null;}
        }
    }
    public static HeldMapping OpenHeldMapping(string scope,string target) {
        string path=ApprovedFile(scope,target);
        using (FileStream file=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,
            FileShare.ReadWrite|FileShare.Delete)) {
            MemoryMappedFile map=MemoryMappedFile.CreateFromFile(file,null,0,
                MemoryMappedFileAccess.ReadWrite,HandleInheritability.None,true);
            try { return new HeldMapping(map,map.CreateViewAccessor(0,1,MemoryMappedFileAccess.ReadWrite)); }
            catch {map.Dispose();throw;}
        } // The writable mapping intentionally outlives the ordinary file handle.
    }
    public sealed class OneByteWriterResult {
        public bool Admitted {get;set;}
        public int NativeError {get;set;}
        public bool ByteWritten {get;set;}
    }
    static OneByteWriterResult WriteOneNew(string path,byte value) {
        SafeFileHandle file=CreateFile(path,GenericWrite,ShareAll,IntPtr.Zero,
            CreateNew,0x80,IntPtr.Zero);
        if (file==null || file.IsInvalid) {
            int error=Marshal.GetLastWin32Error();
            if (file!=null) file.Dispose();
            return new OneByteWriterResult {Admitted=false,NativeError=error};
        }
        using (file) {
            uint written;
            if (!WriteFile(file,new byte[]{value},1,out written,IntPtr.Zero))
                return new OneByteWriterResult {Admitted=true,
                    NativeError=Marshal.GetLastWin32Error(),ByteWritten=false};
            return new OneByteWriterResult {Admitted=true,NativeError=0,
                ByteWritten=written==1};
        }
    }
    public sealed class LateChildCapability {
        readonly string path;
        internal LateChildCapability(string knownPath) { path=knownPath; }
        public OneByteWriterResult Attempt() { return WriteOneNew(path,81); }
    }
    public static LateChildCapability PrepareLateChild(string scope,string target) {
        ApprovedFile(scope,target); // exact fixture boundary before candidate starts
        return new LateChildCapability(target+"\\late-child.bin");
    }
    public static OneByteWriterResult CreateDirectoryAds(string scope,string target) {
        ApprovedFile(scope,target);
        return WriteOneNew(target+":unexpected",91);
    }
}
