using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using Microsoft.Win32.SafeHandles;

// Fixture-only ADS actor and independent $DATA catalog. No transaction authority.
public static class DarkPhaseCStreams {
    const uint ReadAttributes=0x80,ReadControl=0x20000,GenericWrite=0x40000000;
    const uint ShareAll=7,OpenExisting=3,CreateNew=1,Normal=0x80;
    const uint BackupSemantics=0x02000000,OpenReparsePoint=0x00200000;
    const int FileIdInfo=18,FileAttributeTagInfo=9;
    [DllImport("kernel32.dll",EntryPoint="CreateFileW",CharSet=CharSet.Unicode,
        ExactSpelling=true,SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path,uint access,uint share,
        IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file,int kind,
        byte[] buffer,uint size);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool WriteFile(SafeFileHandle file,byte[] bytes,uint count,
        out uint written,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool CloseHandle(SafeFileHandle file);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    struct FindStreamData {
        public long StreamSize;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=296)] public string Name;
    }
    [DllImport("kernel32.dll",EntryPoint="FindFirstStreamW",CharSet=CharSet.Unicode,
        ExactSpelling=true,SetLastError=true)]
    static extern IntPtr FindFirstStream(string path,int level,out FindStreamData data,uint flags);
    [DllImport("kernel32.dll",EntryPoint="FindNextStreamW",CharSet=CharSet.Unicode,
        ExactSpelling=true,SetLastError=true)]
    static extern bool FindNextStream(IntPtr search,out FindStreamData data);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool FindClose(IntPtr search);

    public sealed class CloseReceipt {
        public bool Attempted {get;set;}
        public bool Confirmed {get;set;}
        public int NativeError {get;set;}
        public string ExceptionType {get;set;}
    }
    static CloseReceipt CloseOnce(ref SafeFileHandle handle) {
        SafeFileHandle owned=handle;handle=null;
        if (owned==null) return new CloseReceipt {Confirmed=true};
        CloseReceipt result=new CloseReceipt {Attempted=true,NativeError=-1};
        try {
            result.Confirmed=CloseHandle(owned);
            result.NativeError=result.Confirmed ? 0 : Marshal.GetLastWin32Error();
        } catch (Exception error) { result.ExceptionType=error.GetType().FullName; }
        finally { owned.SetHandleAsInvalid();owned.Dispose(); }
        return result;
    }
    static string Identity(SafeFileHandle file,bool directory,out int attributes,
        out bool kindMatches) {
        attributes=0;kindMatches=false;
        byte[] attrs=new byte[8],id=new byte[24];
        if (!GetFileInformationByHandleEx(file,FileAttributeTagInfo,attrs,(uint)attrs.Length))
            throw new Win32Exception(Marshal.GetLastWin32Error(),"Phase C attribute query failed.");
        attributes=BitConverter.ToInt32(attrs,0);
        kindMatches=(attributes&0x400)==0 && ((attributes&0x10)!=0)==directory;
        if (!GetFileInformationByHandleEx(file,FileIdInfo,id,(uint)id.Length))
            throw new Win32Exception(Marshal.GetLastWin32Error(),"Phase C FileID query failed.");
        return BitConverter.ToString(id).Replace("-","").ToLowerInvariant();
    }
    public sealed class BaseObservation {
        public bool OpenAdmitted {get;set;}
        public int OpenError {get;set;}
        public string FileId {get;set;}
        public int Attributes {get;set;}
        public bool KindMatches {get;set;}
        public int QueryNativeError {get;set;}
        public string QueryError {get;set;}
        public CloseReceipt Close {get;set;}
    }
    static BaseObservation CheckBase(string path,bool directory) {
        BaseObservation result=new BaseObservation();
        SafeFileHandle handle=CreateFile(path,ReadAttributes|ReadControl,ShareAll,
            IntPtr.Zero,OpenExisting,OpenReparsePoint|(directory?BackupSemantics:0),IntPtr.Zero);
        if (handle==null || handle.IsInvalid) {
            result.OpenError=Marshal.GetLastWin32Error();if (handle!=null) handle.Dispose();
            result.Close=new CloseReceipt {Confirmed=true};return result;
        }
        result.OpenAdmitted=true;
        int attributes=0;bool kind=false;
        try { result.FileId=Identity(handle,directory,out attributes,out kind); }
        catch (Exception error) {Win32Exception native=error as Win32Exception;
            result.QueryNativeError=native==null?-1:native.NativeErrorCode;
            result.QueryError=error.GetType().FullName+": "+error.Message;}
        finally {result.Attributes=attributes;result.KindMatches=kind;
            result.Close=CloseOnce(ref handle);}
        return result;
    }
    public sealed class Capability {
        readonly string streamPath,expectedId;
        readonly bool directory;
        readonly byte value;
        bool lateUsed,supportUsed;
        public BaseObservation RootPreflight {get;internal set;}
        public BaseObservation FilePreflight {get;internal set;}
        public bool Eligible {get;internal set;}
        internal Capability(string path,string id,bool isDirectory,byte fixedByte) {
            streamPath=path;expectedId=id;directory=isDirectory;value=fixedByte;
        }
        public string StreamPath {get{return streamPath;}}
        public byte FixedByte {get{return value;}}
        public StreamAttempt Late() {
            if (!Eligible || lateUsed || supportUsed)
                throw new InvalidOperationException("Phase C late attempt lacks exact preflight or repeats.");
            lateUsed=true;return Attempt(streamPath,expectedId,directory,value);
        }
        public StreamAttempt Support(bool settled,bool baselineConfirmed,bool knownRefusal) {
            if (!Eligible || !lateUsed || supportUsed || !settled || !baselineConfirmed || !knownRefusal)
                throw new InvalidOperationException("Phase C support lacks settled exact authority.");
            supportUsed=true;return Attempt(streamPath,expectedId,directory,value);
        }
    }
    public static Capability Prepare(string scope,string target,string trial,
        string frozenRootId,string frozenFileId) {
        string profile=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string local=Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        RequireFixtureScope(profile,local,scope,target,trial,frozenRootId,frozenFileId);
        DriveInfo drive=new DriveInfo(profile.Substring(0,3));
        if (!drive.IsReady || drive.DriveType!=DriveType.Fixed ||
            !String.Equals(drive.DriveFormat,"NTFS",StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Phase C requires fixed local NTFS.");
        for (DirectoryInfo item=new DirectoryInfo(target);item!=null;item=item.Parent)
            if ((item.Attributes&FileAttributes.ReparsePoint)!=0)
                throw new InvalidOperationException("Phase C fixture ancestor is reparse.");
        DirectorySecurity acl=FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(scope));
        SecurityIdentifier current=WindowsIdentity.GetCurrent().User;
        if (!acl.AreAccessRulesProtected || !acl.GetOwner(typeof(SecurityIdentifier)).Equals(current))
            throw new InvalidOperationException("Phase C fixture root is not private.");
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true,true,typeof(SecurityIdentifier))) {
            string sid=rule.IdentityReference.Value;
            if ((sid!=current.Value && sid!="S-1-5-18" && sid!="S-1-5-32-544") ||
                rule.AccessControlType!=AccessControlType.Allow ||
                rule.FileSystemRights!=FileSystemRights.FullControl)
                throw new InvalidOperationException("Phase C fixture contains another writer.");
        }
        foreach (string name in new string[]{"authority.txt","approved-manifest.txt","predelete.txt"}) {
            FileInfo authority=new FileInfo(scope+"\\"+name);
            if (!authority.Exists || (authority.Attributes&FileAttributes.ReparsePoint)!=0)
                throw new InvalidOperationException("Phase C independent authority is unavailable.");
        }
        BaseObservation root=CheckBase(target,true);
        bool rootConfirmed=root.OpenAdmitted && root.OpenError==0 &&
            root.QueryError==null && root.KindMatches && root.FileId==frozenRootId &&
            root.Close.Confirmed && root.Close.NativeError==0;
        BaseObservation file=rootConfirmed ? CheckBase(target+"\\approved.bin",false) : null;
        bool directory=trial=="C2";
        Capability capability=new Capability(directory?target+":phasec-directory":
            target+"\\approved.bin:phasec-file",directory?frozenRootId:frozenFileId,
            directory,directory?(byte)92:(byte)91);
        capability.RootPreflight=root;capability.FilePreflight=file;
        capability.Eligible=rootConfirmed && file.OpenAdmitted && file.OpenError==0 &&
            file.QueryError==null && file.KindMatches && file.FileId==frozenFileId &&
            file.Close.Confirmed && file.Close.NativeError==0;
        return capability;
    }
    static bool LowerHex(string value,int size) {
        if (value==null || value.Length!=size) return false;
        foreach (char unit in value)
            if ((unit<'0'||unit>'9') && (unit<'a'||unit>'f')) return false;
        return true;
    }
    public static void RequireFixtureScope(string profile,string local,string scope,
        string target,string trial,string frozenRootId,string frozenFileId) {
        if (trial!="C1" && trial!="C2") throw new InvalidOperationException("Phase C trial differs.");
        if (profile==null || profile.Length<4 || !Char.IsLetter(profile[0]) ||
            profile[1]!=':' || profile[2]!='\\' ||
            !String.Equals(local,profile+"\\AppData\\Local",StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Phase C lacks canonical profile origin.");
        string prefix=profile+"\\AppData\\Local\\Temp\\Dark180-TxfPhaseB\\";
        string leaf=scope!=null && scope.StartsWith(prefix,StringComparison.OrdinalIgnoreCase) ?
            scope.Substring(prefix.Length) : "";
        Guid parsed;
        if (!Guid.TryParseExact(leaf,"N",out parsed) ||
            !String.Equals(target,scope+"\\target",StringComparison.OrdinalIgnoreCase) ||
            !LowerHex(frozenRootId,48) || !LowerHex(frozenFileId,48) ||
            profile.IndexOf("DarkReNamerVmRuns",StringComparison.OrdinalIgnoreCase)>=0)
            throw new InvalidOperationException("Phase C exact fixture scope or frozen identity is absent.");
        foreach (string part in (target+"\\approved.bin").Substring(3).Split('\\')) {
            if (part.Length==0 || part=="." || part==".." ||
                part.EndsWith(".",StringComparison.Ordinal) ||
                part.EndsWith(" ",StringComparison.Ordinal) || part.IndexOf('~')>=0 ||
                String.Equals(part,"DarkReNamerVmRuns",StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Phase C path contains an alias or protected component.");
        }
    }
    public sealed class StreamAttempt {
        public string BaseKindExpected {get;set;}
        public string StreamKindExpected {get;set;}
        public bool OpenAdmitted {get;set;}
        public int OpenError {get;set;}
        public bool IdentityObserved {get;set;}
        public string FileId {get;set;}
        public int Attributes {get;set;}
        public bool KindMatches {get;set;}
        public bool StreamDataKindMatches {get;set;}
        public bool IdentityMatches {get;set;}
        public string IdentityError {get;set;}
        public int IdentityNativeError {get;set;}
        public bool WriteAttempted {get;set;}
        public int WriteError {get;set;}
        public string WriteException {get;set;}
        public uint BytesWritten {get;set;}
        public CloseReceipt Close {get;set;}
    }
    static StreamAttempt Attempt(string path,string expected,bool directory,byte value) {
        StreamAttempt result=new StreamAttempt {
            BaseKindExpected=directory?"directory":"file",
            StreamKindExpected="named-data"
        };
        SafeFileHandle file=CreateFile(path,GenericWrite,ShareAll,IntPtr.Zero,
            CreateNew,Normal,IntPtr.Zero);
        if (file==null || file.IsInvalid) {
            result.OpenError=Marshal.GetLastWin32Error();if (file!=null) file.Dispose();
            result.Close=new CloseReceipt {Confirmed=true};return result;
        }
        result.OpenAdmitted=true;
        try {
            int attrs=0;bool kind=false;
            try {
                // A named $DATA handle is a data stream even when its base is a directory.
                result.FileId=Identity(file,false,out attrs,out kind);
                result.IdentityObserved=true;
                result.IdentityMatches=String.Equals(result.FileId,expected,StringComparison.Ordinal) && kind;
            } catch (Exception error) {Win32Exception native=error as Win32Exception;
                result.IdentityNativeError=native==null?-1:native.NativeErrorCode;
                result.IdentityError=error.GetType().FullName+": "+error.Message; }
            finally {result.Attributes=attrs;result.KindMatches=kind;
                result.StreamDataKindMatches=kind;}
            if (result.IdentityObserved && result.IdentityMatches) {
                result.WriteAttempted=true;
                try {
                    bool wrote=WriteFile(file,new byte[]{value},1,out uint count,IntPtr.Zero);
                    result.BytesWritten=count;
                    result.WriteError=wrote?0:Marshal.GetLastWin32Error();
                } catch (Exception error) { result.WriteError=-1;
                    result.WriteException=error.GetType().FullName+": "+error.Message; }
            }
        } finally { result.Close=CloseOnce(ref file); }
        return result;
    }
    public sealed class StreamRow {
        public string NameUtf16Hex {get;set;}
        public long Size {get;set;}
    }
    public sealed class Catalog {
        public bool Complete {get;set;}
        public int EofError {get;set;}
        public int QueryError {get;set;}
        public string QueryException {get;set;}
        public string CloseException {get;set;}
        public bool CloseAttempted {get;set;}
        public bool CloseConfirmed {get;set;}
        public int CloseError {get;set;}
        public StreamRow[] Rows {get;set;}
    }
    public static string RawUtf16Hex(string name) {
        if (String.IsNullOrEmpty(name) || name.Length>295)
            throw new InvalidOperationException("Phase C stream name is malformed.");
        const string digits="0123456789abcdef";
        char[] output=new char[name.Length*4];
        for (int i=0;i<name.Length;i++) {
            ushort unit=name[i];
            output[i*4]=digits[(unit&255)>>4];output[i*4+1]=digits[unit&15];
            output[i*4+2]=digits[(unit>>12)&15];output[i*4+3]=digits[(unit>>8)&15];
        }
        return new string(output);
    }
    public static Catalog Observe(string basePath) {
        Catalog result=new Catalog();List<StreamRow> rows=new List<StreamRow>();
        IntPtr search=IntPtr.Zero;bool opened=false;
        try {
            FindStreamData data;
            search=FindFirstStream(basePath,0,out data,0);
            if (search==new IntPtr(-1)) {
                int error=Marshal.GetLastWin32Error();search=IntPtr.Zero;
                if (error==38) {result.Complete=true;result.EofError=38;}
                else result.QueryError=error;
                return result;
            }
            opened=true;
            while (true) {
                if (rows.Count>=8 || data.StreamSize<0 || (rows.Count+1)*620>1024*1024)
                    throw new InvalidOperationException("Phase C stream catalog exceeded bounds.");
                rows.Add(new StreamRow {NameUtf16Hex=RawUtf16Hex(data.Name),Size=data.StreamSize});
                if (!FindNextStream(search,out data)) {
                    int error=Marshal.GetLastWin32Error();
                    if (error==38) {result.Complete=true;result.EofError=38;}
                    else result.QueryError=error;
                    break;
                }
            }
        } catch (Exception error) { result.QueryException=error.GetType().FullName+": "+error.Message; }
        finally {
            if (opened) {
                result.CloseAttempted=true;
                try {
                    result.CloseConfirmed=FindClose(search);
                    result.CloseError=result.CloseConfirmed?0:Marshal.GetLastWin32Error();
                } catch (Exception error) {result.CloseError=-1;
                    result.CloseException=error.GetType().FullName+": "+error.Message;}
            }
            result.Rows=rows.ToArray();
            if (result.CloseAttempted && !result.CloseConfirmed) result.Complete=false;
        }
        return result;
    }
}

public sealed class DarkPhaseCDeadline : IDisposable {
    readonly Timer timer;
    public DarkPhaseCDeadline(int milliseconds) {
        timer=new Timer(_ => {
            Console.Error.WriteLine("DR_PHASE_C_OWNED_DEADLINE active worker exceeded 15 seconds");
            Environment.Exit(124);
        },null,milliseconds,Timeout.Infinite);
    }
    public void Dispose() { timer.Dispose(); }
}
