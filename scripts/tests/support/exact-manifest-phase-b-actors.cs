using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

// Deliberately limited to one named file inside an exact Phase-B fixture.
// These actors cannot acquire a transaction or commit authority.
public static class DarkPhaseBFixtureActors {
    const uint ReadControl=0x20000, WriteDac=0x40000, ReadAttributes=0x80,
        GenericWrite=0x40000000;
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
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetSecurityDescriptorOwner(IntPtr descriptor,out IntPtr owner,
        [MarshalAs(UnmanagedType.Bool)] out bool defaulted);
    [DllImport("advapi32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetSecurityDescriptorGroup(IntPtr descriptor,out IntPtr group,
        [MarshalAs(UnmanagedType.Bool)] out bool defaulted);
    [DllImport("advapi32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetSecurityDescriptorControl(IntPtr descriptor,
        out ushort control,out uint revision);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
    [DllImport("advapi32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool IsValidSid(IntPtr sid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint GetLengthSid(IntPtr sid);
    [DllImport("advapi32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetAclInformation(IntPtr acl,IntPtr information,uint length,int kind);
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
    static extern UIntPtr LocalSize(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteFile(SafeFileHandle file,byte[] bytes,uint size,
        out uint written,IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(SafeFileHandle file);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file,int kind,
        byte[] buffer,uint size);

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
        string batch=Environment.GetEnvironmentVariable("DARK_PHASE_B_BATCH_GUID");
        if (!String.IsNullOrEmpty(batch)) {
            if (batch.Length!=32 || batch!=batch.ToLowerInvariant() ||
                !Guid.TryParseExact(batch,"N",out Guid parsedBatch))
                throw new InvalidOperationException("Phase B actor batch GUID is invalid.");
        }
        string expected=profile+"\\AppData\\Local\\Temp\\"+
            (String.IsNullOrEmpty(batch) ? "Dark180-TxfPhaseB\\" :
                "Dark180-TxfPhaseB-runs\\"+batch+"\\");
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
    public sealed class NativeDaclProjection {
        public bool Present {get;set;}
        public bool Defaulted {get;set;}
        public bool Null {get;set;}
        public int AllocationBytes {get;set;}
        public int UsedBytes {get;set;}
        public int FreeBytes {get;set;}
        public int AceCount {get;set;}
        public string UsedSha256 {get;set;}
    }
    public sealed class NativeDescriptorSnapshot {
        public string Sddl {get;set;}
        public bool ComponentsObserved {get;set;}
        public int ComponentsError {get;set;}
        public string ComponentsException {get;set;}
        public int OwnerSidBytes {get;set;}
        public string OwnerSidSha256 {get;set;}
        public int GroupSidBytes {get;set;}
        public string GroupSidSha256 {get;set;}
        public int ControlWord {get;set;}
        public int ControlRevision {get;set;}
        public NativeDaclProjection Dacl {get;set;}
    }
    static bool CompleteNativeSnapshot(NativeDescriptorSnapshot value) {
        if (value==null || !value.ComponentsObserved || value.ComponentsError!=0 ||
            value.ComponentsException!=null || String.IsNullOrEmpty(value.Sddl) ||
            value.OwnerSidBytes<8 || value.OwnerSidBytes>68 ||
            String.IsNullOrEmpty(value.OwnerSidSha256) ||
            value.GroupSidBytes<8 || value.GroupSidBytes>68 ||
            String.IsNullOrEmpty(value.GroupSidSha256) ||
            value.ControlRevision!=1 || (value.ControlWord&0x00c0)!=0 || value.Dacl==null ||
            !value.Dacl.Present || value.Dacl.Null ||
            (((value.ControlWord&4)!=0)!=value.Dacl.Present) ||
            (((value.ControlWord&8)!=0)!=value.Dacl.Defaulted) ||
            value.Dacl.AllocationBytes<8 || value.Dacl.AllocationBytes>65535 ||
            value.Dacl.UsedBytes<8 || value.Dacl.UsedBytes>value.Dacl.AllocationBytes ||
            value.Dacl.FreeBytes<0 ||
            (long)value.Dacl.UsedBytes+value.Dacl.FreeBytes>value.Dacl.AllocationBytes ||
            value.Dacl.AceCount<0 || value.Dacl.AceCount>(value.Dacl.UsedBytes-8)/4 ||
            String.IsNullOrEmpty(value.Dacl.UsedSha256)) return false;
        return true;
    }
    // This is the support actor's gate before its one authorized DACL write.
    public static bool CanAttemptSupportSet(NativeDescriptorSnapshot observed,
        NativeDescriptorSnapshot frozen) {
        if (!CompleteNativeSnapshot(observed) || !CompleteNativeSnapshot(frozen)) return false;
        NativeDaclProjection actual=observed.Dacl,expected=frozen.Dacl;
        return String.Equals(observed.Sddl,frozen.Sddl,StringComparison.Ordinal) &&
            observed.OwnerSidBytes==frozen.OwnerSidBytes &&
            String.Equals(observed.OwnerSidSha256,frozen.OwnerSidSha256,StringComparison.Ordinal) &&
            observed.GroupSidBytes==frozen.GroupSidBytes &&
            String.Equals(observed.GroupSidSha256,frozen.GroupSidSha256,StringComparison.Ordinal) &&
            observed.ControlRevision==frozen.ControlRevision &&
            (observed.ControlWord&0x150f)==(frozen.ControlWord&0x150f) &&
            actual.Present==expected.Present && actual.Defaulted==expected.Defaulted &&
            actual.Null==expected.Null && actual.AllocationBytes==expected.AllocationBytes &&
            actual.UsedBytes==expected.UsedBytes && actual.FreeBytes==expected.FreeBytes &&
            actual.AceCount==expected.AceCount &&
            String.Equals(actual.UsedSha256,expected.UsedSha256,StringComparison.Ordinal);
    }
    static string Sha256(byte[] bytes) {
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }
    static long Remaining(IntPtr descriptor,int length,IntPtr component,int minimum) {
        long offset=component.ToInt64()-descriptor.ToInt64();
        if (component==IntPtr.Zero || offset<0 || offset>length-minimum)
            throw new InvalidOperationException("B6L native security component lies outside its descriptor.");
        return length-offset;
    }
    static string ReadSid(IntPtr descriptor,int length,IntPtr sid,out int sidBytes) {
        long remaining=Remaining(descriptor,length,sid,8);
        int expected=8+4*Marshal.ReadByte(sid,1);
        if (expected>68 || expected>remaining)
            throw new InvalidOperationException("B6L native SID header exceeds its bounded descriptor.");
        if (!IsValidSid(sid))
            throw new Win32Exception(Marshal.GetLastWin32Error(),"B6L native SID is invalid.");
        uint count=GetLengthSid(sid);
        if (count!=(uint)expected)
            throw new InvalidOperationException("B6L native SID length exceeds its bounded descriptor.");
        sidBytes=(int)count;
        byte[] bytes=new byte[sidBytes];
        Marshal.Copy(sid,bytes,0,sidBytes);
        return Sha256(bytes);
    }
    static NativeDaclProjection ReadDacl(IntPtr descriptor,int length,IntPtr dacl,
        bool present,bool defaulted) {
        NativeDaclProjection result=new NativeDaclProjection {
            Present=present,Defaulted=defaulted,Null=dacl==IntPtr.Zero };
        if (!present || dacl==IntPtr.Zero) return result;
        long remaining=Remaining(descriptor,length,dacl,8);
        int allocation=(ushort)Marshal.ReadInt16(dacl,2);
        if (allocation<8 || allocation>65535 || allocation>remaining)
            throw new InvalidOperationException("B6L native ACL allocation exceeds its descriptor.");
        IntPtr details=Marshal.AllocHGlobal(12);
        try {
            if (!GetAclInformation(dacl,details,12,2))
                throw new Win32Exception(Marshal.GetLastWin32Error(),"B6L native ACL size query failed.");
            uint aceCount=unchecked((uint)Marshal.ReadInt32(details,0));
            uint used=unchecked((uint)Marshal.ReadInt32(details,4));
            uint free=unchecked((uint)Marshal.ReadInt32(details,8));
            if (used<8 || used>allocation || (ulong)used+free>(uint)allocation ||
                aceCount>(used-8)/4)
                throw new InvalidOperationException("B6L native ACL used/free/ACE count is outside allocation.");
            byte[] bytes=new byte[used];
            Marshal.Copy(dacl,bytes,0,(int)used);
            result.AllocationBytes=allocation;result.UsedBytes=(int)used;
            result.FreeBytes=(int)free;result.AceCount=(int)aceCount;
            result.UsedSha256=Sha256(bytes);
            return result;
        } finally { Marshal.FreeHGlobal(details); }
    }
    static NativeDescriptorSnapshot ReadDescriptor(IntPtr descriptor,int actualLength) {
        if (descriptor==IntPtr.Zero || actualLength<20)
            throw new InvalidOperationException("B6L native descriptor buffer is unavailable.");
        uint reported=GetSecurityDescriptorLength(descriptor);
        if (reported<20 || reported>65535 || reported>actualLength)
            throw new InvalidOperationException("B6L native descriptor length is outside its bounded buffer.");
        int length=(int)reported;
        NativeDescriptorSnapshot result=new NativeDescriptorSnapshot();
        IntPtr text=IntPtr.Zero;
        try {
            uint textLength;
            if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor,1,7,
                    out text,out textLength))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "B6L native descriptor SDDL conversion failed.");
            result.Sddl=Marshal.PtrToStringUni(text);
            if (result.Sddl==null)
                throw new InvalidOperationException("B6L native descriptor SDDL is absent.");
        } finally { if (text!=IntPtr.Zero) LocalFree(text); }
        try {
            IntPtr owner,group,dacl;
            bool ownerDefaulted,groupDefaulted,present,daclDefaulted;
            ushort control;uint revision;
            if (!GetSecurityDescriptorOwner(descriptor,out owner,out ownerDefaulted) ||
                !GetSecurityDescriptorGroup(descriptor,out group,out groupDefaulted) ||
                !GetSecurityDescriptorDacl(descriptor,out present,out dacl,out daclDefaulted) ||
                !GetSecurityDescriptorControl(descriptor,out control,out revision))
                throw new Win32Exception(Marshal.GetLastWin32Error(),"B6L native descriptor query failed.");
            if (((control&0x0001)!=0)!=ownerDefaulted ||
                ((control&0x0002)!=0)!=groupDefaulted ||
                ((control&0x0004)!=0)!=present ||
                ((control&0x0008)!=0)!=daclDefaulted)
                throw new InvalidOperationException("B6L native descriptor control disagrees with its components.");
            result.OwnerSidSha256=ReadSid(descriptor,length,owner,out int ownerBytes);
            result.OwnerSidBytes=ownerBytes;
            result.GroupSidSha256=ReadSid(descriptor,length,group,out int groupBytes);
            result.GroupSidBytes=groupBytes;
            result.ControlWord=control;result.ControlRevision=(int)revision;
            result.Dacl=ReadDacl(descriptor,length,dacl,present,daclDefaulted);
            result.ComponentsObserved=true;
        } catch (Exception failure) {
            Win32Exception native=failure as Win32Exception;
            result.ComponentsError=native==null ? -1 : native.NativeErrorCode;
            result.ComponentsException=failure.GetType().FullName+": "+failure.Message;
        }
        return result;
    }
    static NativeDescriptorSnapshot HeldSnapshot(SafeFileHandle held) {
        IntPtr owner,group,dacl,sacl,descriptor;
        uint error=GetSecurityInfo(held,1,7,out owner,out group,out dacl,out sacl,
            out descriptor);
        if (error!=0) throw new Win32Exception((int)error,"B6L held descriptor readback failed.");
        try {
            ulong allocated=descriptor==IntPtr.Zero ? 0 : LocalSize(descriptor).ToUInt64();
            if (allocated<20 || allocated>Int32.MaxValue)
                throw new InvalidOperationException("B6L held descriptor allocation is unavailable.");
            return ReadDescriptor(descriptor,(int)allocated);
        }
        finally { if (descriptor!=IntPtr.Zero) LocalFree(descriptor); }
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
    public sealed class NativeCloseReceipt {
        public bool Attempted {get;set;}
        public bool Confirmed {get;set;}
        public int NativeError {get;set;}
        public string ExceptionType {get;set;}
        public string ExceptionMessage {get;set;}
    }
    static NativeCloseReceipt CloseOnce(ref SafeFileHandle owned) {
        SafeFileHandle file=owned;owned=null;
        if (file==null) return new NativeCloseReceipt {Attempted=false,Confirmed=true};
        NativeCloseReceipt result=new NativeCloseReceipt {Attempted=true,NativeError=-1};
        try {
            result.Confirmed=CloseHandle(file);
            result.NativeError=result.Confirmed ? 0 : Marshal.GetLastWin32Error();
        } catch (Exception failure) {
            result.ExceptionType=failure.GetType().FullName;
            result.ExceptionMessage=failure.Message;
        } finally {
            file.SetHandleAsInvalid(); // one native close attempt, no SafeHandle retry
            file.Dispose();
        }
        return result;
    }
    static string FileIdentity(SafeFileHandle file) {
        byte[] attributes=new byte[8],id=new byte[24];
        if (!GetFileInformationByHandleEx(file,9,attributes,(uint)attributes.Length))
            throw new Win32Exception(Marshal.GetLastWin32Error(),"B6L attribute query failed.");
        int flags=BitConverter.ToInt32(attributes,0);
        if ((flags&(0x10|0x400))!=0)
            throw new InvalidOperationException("B6L opened object changed kind or became reparse.");
        if (!GetFileInformationByHandleEx(file,18,id,(uint)id.Length))
            throw new Win32Exception(Marshal.GetLastWin32Error(),"B6L FileID query failed.");
        return BitConverter.ToString(id).Replace("-","").ToLowerInvariant();
    }
    static int NativeCode(Exception failure) {
        Win32Exception win=failure as Win32Exception;
        return win==null ? -1 : win.NativeErrorCode;
    }
    public sealed class LateDaclProbeResult {
        public bool OpenAdmitted {get;set;}
        public int OpenError {get;set;}
        public bool IdentityObserved {get;set;}
        public int IdentityError {get;set;}
        public string IdentityException {get;set;}
        public string FileId {get;set;}
        public bool IdentityMatches {get;set;}
        public bool BeforeObserved {get;set;}
        public int BeforeError {get;set;}
        public string BeforeException {get;set;}
        public string BeforeSddl {get;set;}
        public NativeDescriptorSnapshot BeforeNative {get;set;}
        public bool SetAttempted {get;set;}
        public int SetError {get;set;}
        public string SetException {get;set;}
        public bool AfterObserved {get;set;}
        public int AfterError {get;set;}
        public string AfterException {get;set;}
        public string AfterSddl {get;set;}
        public NativeDescriptorSnapshot AfterNative {get;set;}
        public NativeCloseReceipt Close {get;set;}
    }
    public sealed class LateDaclCapability {
        const uint WriteOwner=0x80000,ReadAttributes=0x80,OpenReparsePoint=0x00200000;
        readonly string path,originalId,baselineSddl,proposedSddl;
        readonly NativeCloseReceipt preparationClose;
        readonly byte[] proposedDescriptor;
        readonly NativeDescriptorSnapshot baselineNative,proposedNative;
        SafeFileHandle lateHandle;
        bool lateAttempted,supportAttempted,lateCloseDone,lateCloseConfirmed;
        internal LateDaclCapability(string approvedPath,string id,string baseline,
            string expectedProposed,byte[] proposed,NativeDescriptorSnapshot nativeBaseline,
            NativeDescriptorSnapshot nativeProposed,NativeCloseReceipt close) {
            path=approvedPath;originalId=id;baselineSddl=baseline;
            proposedSddl=expectedProposed;proposedDescriptor=proposed;
            baselineNative=nativeBaseline;proposedNative=nativeProposed;
            preparationClose=close;
        }
        public string OriginalId {get{return originalId;}}
        public string BaselineSddl {get{return baselineSddl;}}
        public string ProposedSddl {get{return proposedSddl;}}
        public NativeDescriptorSnapshot BaselineNative {get{return baselineNative;}}
        public NativeDescriptorSnapshot ProposedNative {get{return proposedNative;}}
        public NativeCloseReceipt PreparationClose {get{return preparationClose;}}
        static void TryIdentity(SafeFileHandle handle,string expected,LateDaclProbeResult result) {
            try {
                result.FileId=FileIdentity(handle);result.IdentityObserved=true;
                result.IdentityMatches=String.Equals(result.FileId,expected,StringComparison.Ordinal);
            } catch (Exception failure) {
                result.IdentityError=NativeCode(failure);
                result.IdentityException=failure.GetType().FullName+": "+failure.Message;
            }
        }
        static void TrySnapshot(SafeFileHandle handle,bool before,LateDaclProbeResult result) {
            try {
                NativeDescriptorSnapshot snapshot=HeldSnapshot(handle);
                if (before) {
                    result.BeforeObserved=true;result.BeforeSddl=snapshot.Sddl;
                    result.BeforeNative=snapshot;
                } else {
                    result.AfterObserved=true;result.AfterSddl=snapshot.Sddl;
                    result.AfterNative=snapshot;
                }
            } catch (Exception failure) {
                if (before) {
                    result.BeforeError=NativeCode(failure);
                    result.BeforeException=failure.GetType().FullName+": "+failure.Message;
                } else {
                    result.AfterError=NativeCode(failure);
                    result.AfterException=failure.GetType().FullName+": "+failure.Message;
                }
            }
        }
        LateDaclProbeResult Probe(bool retainHandle) {
            LateDaclProbeResult result=new LateDaclProbeResult();
            SafeFileHandle opened=CreateFile(path,ReadControl|WriteDac|WriteOwner,ShareAll,
                IntPtr.Zero,OpenExisting,OpenReparsePoint,IntPtr.Zero);
            if (opened==null || opened.IsInvalid) {
                result.OpenError=Marshal.GetLastWin32Error();
                if (opened!=null) opened.Dispose();
                return result;
            }
            result.OpenAdmitted=true;
            if (retainHandle) { lateHandle=opened; }
            try {
                TryIdentity(opened,originalId,result);
                if (!result.IdentityObserved || !result.IdentityMatches) return result;
                TrySnapshot(opened,true,result);
                if ((retainHandle && result.BeforeObserved &&
                        !String.Equals(result.BeforeSddl,baselineSddl,StringComparison.Ordinal)) ||
                    (!retainHandle && !CanAttemptSupportSet(result.BeforeNative,baselineNative)))
                    return result;
                GCHandle pin=GCHandle.Alloc(proposedDescriptor,GCHandleType.Pinned);
                try {
                    bool present,defaulted;IntPtr dacl;
                    if (!GetSecurityDescriptorDacl(pin.AddrOfPinnedObject(),out present,
                            out dacl,out defaulted) || !present || dacl==IntPtr.Zero) {
                        result.SetException="Proposed DACL could not be inspected.";
                        result.SetError=Marshal.GetLastWin32Error();
                    } else {
                        result.SetAttempted=true;
                        try { result.SetError=(int)SetSecurityInfo(opened,1,4,
                            IntPtr.Zero,IntPtr.Zero,dacl,IntPtr.Zero); }
                        catch (Exception failure) {
                            result.SetError=NativeCode(failure);
                            result.SetException=failure.GetType().FullName+": "+failure.Message;
                        }
                    }
                } finally { pin.Free(); }
                TrySnapshot(opened,false,result);
                return result;
            } finally {
                if (!retainHandle) result.Close=CloseOnce(ref opened);
            }
        }
        public LateDaclProbeResult AttemptLate() {
            if (lateAttempted || supportAttempted)
                throw new InvalidOperationException("B6L late metadata open cannot repeat.");
            lateAttempted=true;
            return Probe(true);
        }
        public NativeCloseReceipt CloseLateOnce() {
            if (!lateAttempted || lateCloseDone)
                throw new InvalidOperationException("B6L late handle close cannot repeat or precede open.");
            lateCloseDone=true;
            NativeCloseReceipt receipt=CloseOnce(ref lateHandle);
            lateCloseConfirmed=receipt.Confirmed;
            return receipt;
        }
        public LateDaclProbeResult AttemptSupport(bool candidateExitedAndRolledBack,
            bool independentBaselineConfirmed) {
            if (!lateAttempted || !lateCloseDone || !lateCloseConfirmed || supportAttempted ||
                !candidateExitedAndRolledBack || !independentBaselineConfirmed)
                throw new InvalidOperationException("B6L support lacks settled independent authority.");
            supportAttempted=true;
            return Probe(false);
        }
    }
    public static LateDaclCapability PrepareLateDacl(string scope,string target,
        string expectedFileId) {
        string path=ApprovedFile(scope,target);
        if (expectedFileId==null || expectedFileId.Length!=48)
            throw new InvalidOperationException("B6L frozen FileID is absent.");
        FileSecurity baseline=FileSystemAclExtensions.GetAccessControl(new FileInfo(path));
        string baselineSddl=baseline.GetSecurityDescriptorSddlForm(
            AccessControlSections.Owner|AccessControlSections.Group|AccessControlSections.Access);
        FileSecurity proposed=new FileSecurity();
        proposed.SetSecurityDescriptorBinaryForm(baseline.GetSecurityDescriptorBinaryForm());
        proposed.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-11"),
            FileSystemRights.ReadAttributes,AccessControlType.Allow));
        string proposedSddl=proposed.GetSecurityDescriptorSddlForm(
            AccessControlSections.Owner|AccessControlSections.Group|AccessControlSections.Access);
        if (String.Equals(proposedSddl,baselineSddl,StringComparison.Ordinal))
            throw new InvalidOperationException("B6L proposed benign DACL is indistinguishable.");
        SafeFileHandle prep=CreateFile(path,ReadControl|ReadAttributes,ShareAll,
            IntPtr.Zero,OpenExisting,0x00200000,IntPtr.Zero);
        if (prep==null || prep.IsInvalid) {
            int error=Marshal.GetLastWin32Error();
            if (prep!=null) prep.Dispose();
            throw new Win32Exception(error,"B6L preparation identity open failed.");
        }
        string observed=null;NativeDescriptorSnapshot baselineNative=null;Exception primary=null;
        try {
            observed=FileIdentity(prep);
            baselineNative=HeldSnapshot(prep);
            if (baselineNative.Sddl!=baselineSddl)
                throw new InvalidOperationException("B6L preparation security differs across handles.");
        }
        catch (Exception failure) {primary=failure;}
        NativeCloseReceipt close=CloseOnce(ref prep);
        if (!close.Confirmed) throw new InvalidOperationException("B6L preparation close is unknown.");
        if (primary!=null) throw primary;
        if (!String.Equals(observed,expectedFileId,StringComparison.Ordinal))
            throw new InvalidOperationException("B6L preparation FileID differs from independent freeze.");
        byte[] proposedBytes=proposed.GetSecurityDescriptorBinaryForm();
        NativeDescriptorSnapshot proposedNative;
        GCHandle proposedPin=GCHandle.Alloc(proposedBytes,GCHandleType.Pinned);
        try { proposedNative=ReadDescriptor(proposedPin.AddrOfPinnedObject(),proposedBytes.Length); }
        finally { proposedPin.Free(); }
        return new LateDaclCapability(path,observed,baselineSddl,proposedSddl,
            proposedBytes,baselineNative,proposedNative,close);
    }
}
