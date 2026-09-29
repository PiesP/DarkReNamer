# Diagnostic observer only. No acceptance classification or process intervention.
function Remove-DrRuntimeBrokerCompilerArtifacts {
    param($TempFiles, [string]$CompilerRoot)
    $known=@($TempFiles)
    $receipt=@{ completed=$false; owned_temp_artifacts_remaining=0; errors=@(); owned_temp_artifacts_count=$known.Count; all_paths_inside_owned_root=$true }
    $prefix=[IO.Path]::GetFullPath($CompilerRoot).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)) + [IO.Path]::DirectorySeparatorChar
    if ($known.Count -gt 128) {
        $receipt.errors += 'compiler-temp-count-exceeded'; $receipt.owned_temp_artifacts_remaining=$known.Count
        $receipt.all_paths_inside_owned_root=$false
        return $receipt
    }
    foreach ($path in $known) {
        try {
            $full=[IO.Path]::GetFullPath($path)
            if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                $receipt.all_paths_inside_owned_root=$false
                throw 'Compiler artifact escaped its owned root.'
            }
            if (Test-Path -LiteralPath $full) {
                $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Compiler artifact is not ordinary.' }
                [IO.File]::Delete($full)
            }
            if (Test-Path -LiteralPath $full) { $receipt.owned_temp_artifacts_remaining++ }
        } catch { $receipt.errors += $_.Exception.GetType().FullName; $receipt.owned_temp_artifacts_remaining++ }
    }
    $receipt.completed=$receipt.errors.Count -eq 0 -and $receipt.owned_temp_artifacts_remaining -eq 0
    return $receipt
}

function Initialize-DrRuntimeBrokerNative {
    param([string]$CompilerRoot)
    if ('DrRuntimeBrokerNative' -as [type]) { return @{ completed=$true; owned_temp_artifacts_remaining=0; errors=@(); compilation_succeeded=$true; type_reused=$true } }
    $code = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class DrRuntimeBrokerHandle : SafeHandleZeroOrMinusOneIsInvalid {
    public DrRuntimeBrokerHandle() : base(true) { }
    public int CloseError { get; private set; }
    protected override bool ReleaseHandle() {
        bool ok = DrRuntimeBrokerNative.CloseHandle(handle);
        CloseError = ok ? 0 : Marshal.GetLastWin32Error();
        return ok;
    }
}
public sealed class DrRuntimeBrokerLifetime : IDisposable {
    private readonly DrRuntimeBrokerHandle handle;
    internal DrRuntimeBrokerHandle IdentityHandle { get { return handle; } }
    public Dictionary<string, object> Identity { get; private set; }
    public int CloseError { get { return handle.CloseError; } }
    public bool Closed { get { return handle.IsClosed; } }
    internal DrRuntimeBrokerLifetime(DrRuntimeBrokerHandle handle, Dictionary<string, object> identity) {
        this.handle = handle; Identity = identity;
    }
    public Dictionary<string, object> Poll() {
        if (handle.IsClosed || handle.IsInvalid) throw new ObjectDisposedException("DrRuntimeBrokerLifetime");
        uint wait = DrRuntimeBrokerNative.WaitForSingleObject(handle, 0);
        if (wait == uint.MaxValue) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        if (wait != 0 && wait != 258) throw new InvalidDataException("Unexpected process wait status.");
        var row = new Dictionary<string, object> {
            {"pid", Identity["pid"]}, {"creation_filetime_100ns", Identity["creation_filetime_100ns"]},
            {"exit_filetime_100ns", null}, {"wait_result", wait}, {"times_succeeded", false},
            {"times_win32_error", 0}, {"exit_code_succeeded", false}, {"exit_code_win32_error", 0},
            {"exit_code", null}, {"handle_closed", false}, {"close_win32_error", 0}
        };
        if (wait == 0) {
            DrRuntimeBrokerNative.FileTime creation, exit, kernel, user;
            bool ok = DrRuntimeBrokerNative.GetProcessTimes(handle, out creation, out exit, out kernel, out user);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            row["times_succeeded"] = ok; row["times_win32_error"] = error;
            if (ok) {
                if (creation.Value.ToString(CultureInfo.InvariantCulture) != (string)Identity["creation_filetime_100ns"])
                    throw new InvalidDataException("Same-handle process creation time changed.");
                row["exit_filetime_100ns"] = exit.Value.ToString(CultureInfo.InvariantCulture);
            }
            uint code;
            ok = DrRuntimeBrokerNative.GetExitCodeProcess(handle, out code);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            row["exit_code_succeeded"] = ok; row["exit_code_win32_error"] = error;
            if (ok) row["exit_code"] = code;
        }
        return row;
    }
    public void Dispose() { handle.Dispose(); }
}
public static class DrRuntimeBrokerNative {
    public const uint ProcessAccess = 0x00101000; // Limited query and synchronize only.
    public const uint TokenAccess = 8; // TOKEN_QUERY only; no privilege changes.
    [StructLayout(LayoutKind.Sequential)] public struct FileTime {
        public uint Low, High;
        public ulong Value { get { return ((ulong)High << 32) | Low; } }
    }
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    private static extern DrRuntimeBrokerHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint pid);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    private static extern uint GetProcessId(DrRuntimeBrokerHandle handle);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetProcessTimes(DrRuntimeBrokerHandle handle, out FileTime creation, out FileTime exit, out FileTime kernel, out FileTime user);
    [DllImport("kernel32.dll", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryFullProcessImageNameW(DrRuntimeBrokerHandle handle, uint flags, StringBuilder text, ref uint chars);
    [DllImport("kernel32.dll", ExactSpelling=true, CharSet=CharSet.Unicode)]
    private static extern int GetPackageFullName(DrRuntimeBrokerHandle handle, ref uint chars, StringBuilder text);
    [DllImport("kernel32.dll", ExactSpelling=true, CharSet=CharSet.Unicode)]
    private static extern int GetApplicationUserModelId(DrRuntimeBrokerHandle handle, ref uint chars, StringBuilder text);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    public static extern uint WaitForSingleObject(DrRuntimeBrokerHandle handle, uint milliseconds);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetExitCodeProcess(DrRuntimeBrokerHandle handle, out uint code);
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenProcessToken(DrRuntimeBrokerHandle process, uint access, out DrRuntimeBrokerHandle token);
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetTokenInformation(DrRuntimeBrokerHandle token, int kind, IntPtr buffer, uint bytes, out uint required);

    private static void WindowsOnly() {
        if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
            throw new PlatformNotSupportedException("RuntimeBroker interop requires native x64 Windows.");
    }
    private delegate int NameQuery(ref uint length, StringBuilder text);
    private static void Name(DrRuntimeBrokerHandle handle, bool package, Dictionary<string, object> row) {
        string prefix = package ? "package" : "aumid";
        string key = package ? "package_full_name" : "aumid";
        uint required = 0;
        NameQuery query = package ? new NameQuery(delegate(ref uint n, StringBuilder b) { return GetPackageFullName(handle, ref n, b); })
                                 : new NameQuery(delegate(ref uint n, StringBuilder b) { return GetApplicationUserModelId(handle, ref n, b); });
        int first = query(ref required, null); row[prefix + "_first_status"] = first;
        row[prefix + "_status"] = null; row[key] = null; row[prefix + "_required_chars"] = required; row[prefix + "_returned_chars"] = null; row[prefix + "_buffer_valid"] = false;
        if (first != 122 || required < 2 || required > (package ? 128 : 130)) return;
        uint length = required; var text = new StringBuilder((int)length);
        int second = query(ref length, text); row[prefix + "_status"] = second; row[prefix + "_returned_chars"] = length;
        if (second == 0 && length >= 2 && length <= required && text.Length == length - 1 && text.ToString().IndexOf('\0') < 0)
            { row[key] = text.ToString(); row[prefix + "_buffer_valid"] = true; }
    }
    private static void Token(DrRuntimeBrokerHandle process, Dictionary<string, object> row) {
        DrRuntimeBrokerHandle token;
        bool ok = OpenProcessToken(process, TokenAccess, out token);
        int openError = ok ? 0 : Marshal.GetLastWin32Error();
        row["token_error"] = openError;
        try {
            if (!ok) return;
            uint required;
            ok = GetTokenInformation(token, 1, IntPtr.Zero, 0, out required);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            if (ok || error != 122 || required < 16 || required > 4096) {
                row["token_sid_error"] = error == 0 ? 13 : error; return;
            }
            IntPtr buffer = Marshal.AllocHGlobal((int)required);
            try {
                uint returned;
                ok = GetTokenInformation(token, 1, buffer, required, out returned);
                error = ok ? 0 : Marshal.GetLastWin32Error();
                row["token_sid_error"] = error;
                if (!ok) return;
                if (returned > required || returned < 16) throw new InvalidDataException("Token user buffer size invalid.");
                IntPtr sid = Marshal.ReadIntPtr(buffer);
                long offset = sid.ToInt64() - buffer.ToInt64();
                if (offset < 16 || offset > returned - 8) throw new InvalidDataException("Token SID pointer outside buffer.");
                int subs = Marshal.ReadByte(sid, 1);
                int length = 8 + 4 * subs;
                if (subs > 15 || offset + length > returned) throw new InvalidDataException("Token SID size outside buffer.");
                byte[] bytes = new byte[length]; Marshal.Copy(sid, bytes, 0, length);
                row["owner_sid"] = new SecurityIdentifier(bytes, 0).Value;
            } finally { Marshal.FreeHGlobal(buffer); }
            uint sessionBytes;
            IntPtr session = Marshal.AllocHGlobal(4);
            try {
                ok = GetTokenInformation(token, 12, session, 4, out sessionBytes);
                error = ok ? 0 : Marshal.GetLastWin32Error(); row["token_session_error"] = error;
                if (ok && sessionBytes == 4) row["session_id"] = unchecked((uint)Marshal.ReadInt32(session));
                else if (ok) row["token_session_error"] = 13;
            } finally { Marshal.FreeHGlobal(session); }
        } finally {
            if (token != null) {
                token.Dispose();
                if (token.CloseError != 0) row["token_close_error"] = token.CloseError;
            }
        }
    }
    public static bool IsRuntimeBrokerImage(string path) {
        if(String.IsNullOrEmpty(path)) return false;
        int separator=path.LastIndexOfAny(new[]{'\\','/'});
        return String.Equals(path.Substring(separator+1),"RuntimeBroker.exe",StringComparison.OrdinalIgnoreCase);
    }
    public static bool MatchesSnapshotLifetime(uint expectedPid,uint nativePid,string cimCreation,string nativeCreation,uint? cimSession,uint? nativeSession) {
        ulong cim, native;
        return expectedPid==nativePid && ulong.TryParse(cimCreation,out cim) && cim>0 &&
            ulong.TryParse(nativeCreation,out native) && native>=cim && native-cim<=9 &&
            cimSession.HasValue && nativeSession.HasValue && cimSession.Value==nativeSession.Value;
    }
    public static bool? ExistingAtSubscriptionStart(string creation, string subscriptionStart) {
        ulong created, start;
        if(!ulong.TryParse(creation,out created) || !ulong.TryParse(subscriptionStart,out start) || created==0 || start==0) return null;
        return created<start;
    }
    public static bool MatchesCapturedLifetime(uint expectedPid, uint nativePid, string creation, string eventTime) {
        ulong created, occurred;
        return nativePid == expectedPid && ulong.TryParse(creation, out created) && created > 0 &&
            (eventTime == null || (ulong.TryParse(eventTime, out occurred) && created <= occurred));
    }
    public static void CompletePackage(DrRuntimeBrokerLifetime life) {
        Name(life.IdentityHandle, true, life.Identity); Name(life.IdentityHandle, false, life.Identity);
    }
    public static DrRuntimeBrokerLifetime Open(uint pid, bool package) {
        WindowsOnly(); if (pid == 0) throw new ArgumentOutOfRangeException("pid");
        DrRuntimeBrokerHandle handle = OpenProcess(ProcessAccess, false, pid);
        int openError = handle.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        var row = new Dictionary<string, object> {
                {"pid", 0u}, {"creation_filetime_100ns", null}, {"owner_sid", null}, {"session_id", null}, {"image_path", null},
                {"open_error", openError}, {"pid_error", 0}, {"times_error", 0}, {"image_error", 0},
                {"token_error", 0}, {"token_close_error", 0}, {"token_sid_error", 0}, {"token_session_error", 0}
            };
            if (package) { row["package_first_status"] = null; row["package_status"] = null; row["aumid_first_status"] = null; row["aumid_status"] = null; row["package_full_name"] = null; row["aumid"] = null; }
        try {
            if (!handle.IsInvalid) {
                uint actual = GetProcessId(handle); int error = actual == 0 ? Marshal.GetLastWin32Error() : 0;
                row["pid"] = actual; row["pid_error"] = error;
                FileTime creation, exit, kernel, user;
                bool ok = GetProcessTimes(handle, out creation, out exit, out kernel, out user);
                error = ok ? 0 : Marshal.GetLastWin32Error(); row["times_error"] = error;
                if (ok) row["creation_filetime_100ns"] = creation.Value.ToString(CultureInfo.InvariantCulture);
                Token(handle, row);
                var image = new StringBuilder(32768); uint chars = 32768;
                ok = QueryFullProcessImageNameW(handle, 0, image, ref chars);
                error = ok ? 0 : Marshal.GetLastWin32Error(); row["image_error"] = error;
                if (ok && chars > 0 && chars < 32768 && image.Length == chars && image.ToString().IndexOf('\0') < 0) row["image_path"] = image.ToString();
                if (package) { Name(handle, true, row); Name(handle, false, row); }
            }
            return new DrRuntimeBrokerLifetime(handle, row);
        } catch(Exception error) { handle.Dispose(); error.Data["process_close_error"]=handle.CloseError; error.Data["token_close_error"]=row["token_close_error"]; throw; }
    }
}

public sealed class DrRuntimeBrokerLease {
    public DrRuntimeBrokerLifetime Life;
    private readonly DrRuntimeBrokerSession owner;
    private int released;
    internal DrRuntimeBrokerLease(DrRuntimeBrokerSession owner, DrRuntimeBrokerLifetime life) { this.owner=owner; Life=life; }
    public bool Closed { get { return Life.Closed; } }
    public void Close() { try { Life.Dispose(); } finally { if (System.Threading.Interlocked.Exchange(ref released,1)==0) owner.Release(this); } }
}
public sealed class DrRuntimeBrokerRecord {
    public string Kind, Source, EventTime, ReceivedUtc, OwnerScope, ErrorType, NativeCaptureStartedUtc, NativeIdentityCompletedUtc, SubscriptionStartFileTime, OriginClassification;
    public bool? ExistingAtStart;
    public string SnapshotCreationFileTime;
    public uint? SnapshotSessionId;
    public Dictionary<string,object> TraceAuxiliary, FailureClose;
    public int ErrorHResult;
    public uint Pid;
    public uint? EventSessionId;
    public DrRuntimeBrokerLease Lease;
}
public sealed class DrRuntimeBrokerSession : IDisposable {
    private readonly object gate = new object();
    private readonly Queue<DrRuntimeBrokerRecord> queue = new Queue<DrRuntimeBrokerRecord>();
    private readonly List<DrRuntimeBrokerLease> leases = new List<DrRuntimeBrokerLease>();
    private readonly HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
    private readonly string runnerSid;
    private System.Management.ManagementEventWatcher start, stop;
    private bool disposing;
    private int slots, inFlight;
    public long Dropped, CapacityMisses, CaptureFailures, ProviderFailures, Duplicates, NativeCloseFailures;
    public bool Started { get; private set; }
    public string SubscriptionStartFileTime { get; private set; }
    public int OpenHandles { get { lock(gate) { return slots; } } }
    public DrRuntimeBrokerSession(string sid) { runnerSid=sid; }
    internal void Release(DrRuntimeBrokerLease lease) { lock(gate) { slots--; if(lease!=null) { leases.Remove(lease); if(lease.Life.CloseError!=0 || (int)lease.Life.Identity["token_close_error"]!=0) NativeCloseFailures++; } } }
    private bool Reserve() { lock(gate) { if(disposing || slots>=64) { CapacityMisses++; return false; } slots++; return true; } }
    private void Put(DrRuntimeBrokerRecord row) {
        bool dropped=false;
        lock(gate) { if(disposing || queue.Count>=256) { Dropped++; dropped=true; } else queue.Enqueue(row); }
        if(dropped && row.Lease!=null) row.Lease.Close();
    }
    private Dictionary<string,object> AccountFailedClose(Exception error) {
        var evidence=new Dictionary<string,object> {{"process_close_error",0},{"token_close_error",0}};
        foreach(string key in new[]{"process_close_error","token_close_error"}) {
            if(error.Data.Contains(key)) evidence[key]=Convert.ToInt32(error.Data[key],CultureInfo.InvariantCulture);
        }
        if((int)evidence["process_close_error"]!=0 || (int)evidence["token_close_error"]!=0) lock(gate) { NativeCloseFailures++; }
        return evidence;
    }
    public DrRuntimeBrokerLease OpenParent(uint pid) {
        if(!Reserve()) return null;
        try {
            var lease=new DrRuntimeBrokerLease(this,DrRuntimeBrokerNative.Open(pid,false));
            lock(gate) { leases.Add(lease); }
            return lease;
        } catch(Exception error) { Release(null); AccountFailedClose(error); throw; }
    }
    public void Capture(uint pid, string eventTime, string source) { Capture(pid,eventTime,source,null,null,null,null); }
    public void CaptureSnapshot(uint pid,string cimCreation,uint? cimSession) { Capture(pid,null,"initial-snapshot",null,null,cimCreation,cimSession); }
    private void Capture(uint pid, string eventTime, string source, uint? eventSession, Dictionary<string,object> auxiliary,string snapshotCreation,uint? snapshotSession) {
        lock(gate) { if(disposing) { Dropped++; return; } inFlight++; }
        try {
        var row=new DrRuntimeBrokerRecord { Kind="capture",Pid=pid,Source=source,EventTime=eventTime,EventSessionId=eventSession,ReceivedUtc=DateTime.UtcNow.ToString("o"),TraceAuxiliary=auxiliary,SubscriptionStartFileTime=SubscriptionStartFileTime,SnapshotCreationFileTime=snapshotCreation,SnapshotSessionId=snapshotSession };
        if(!Reserve()) { row.Kind="handle-cap"; Put(row); return; }
        DrRuntimeBrokerLease lease=null;
        try {
            row.NativeCaptureStartedUtc=DateTime.UtcNow.ToString("o");
            lease=new DrRuntimeBrokerLease(this,DrRuntimeBrokerNative.Open(pid,false));
            row.Lease=lease; row.NativeIdentityCompletedUtc=DateTime.UtcNow.ToString("o");
            lock(gate) { leases.Add(lease); }
            var id=lease.Life.Identity;
            string created=id["creation_filetime_100ns"] as string;
            string sid=id["owner_sid"] as string;
            row.OwnerScope=sid==null ? "unknown" : (sid==runnerSid ? "runner" : "foreign");
            if(!DrRuntimeBrokerNative.MatchesCapturedLifetime(pid,(uint)id["pid"],created,eventTime) ||
                (eventSession.HasValue && id["session_id"]!=null && (uint)id["session_id"]!=eventSession.Value) ||
                !DrRuntimeBrokerNative.IsRuntimeBrokerImage(id["image_path"] as string) ||
                (source=="initial-snapshot" && !DrRuntimeBrokerNative.MatchesSnapshotLifetime(pid,(uint)id["pid"],snapshotCreation,created,snapshotSession,id["session_id"] as uint?))) {
                row.Kind="capture-mismatch-or-failure"; lock(gate) { CaptureFailures++; } lease.Close(); Put(row); return;
            }
            row.ExistingAtStart=DrRuntimeBrokerNative.ExistingAtSubscriptionStart(created,SubscriptionStartFileTime);
            row.OriginClassification=!row.ExistingAtStart.HasValue ? "subscription-start-unknown" :
                (row.ExistingAtStart.Value ? "born-before-subscription-start" : "born-since-subscription-start");
            string key=pid.ToString(CultureInfo.InvariantCulture)+"|"+created;
            lock(gate) {
                if(seen.Contains(key)) { row.Kind="duplicate"; Duplicates++; }
                else if(seen.Count>=4096) { row.Kind="identity-cap"; CapacityMisses++; }
                else seen.Add(key);
            }
            if(row.Kind!="capture") { lease.Close(); Put(row); return; }
            if(row.OwnerScope=="runner") DrRuntimeBrokerNative.CompletePackage(lease.Life);
            else if(row.OwnerScope=="foreign") lease.Close();
            row.NativeIdentityCompletedUtc=DateTime.UtcNow.ToString("o");
            Put(row);
        } catch(Exception error) {
            if(lease!=null) lease.Close(); else Release(null);
            row.NativeIdentityCompletedUtc=DateTime.UtcNow.ToString("o");
            row.FailureClose=AccountFailedClose(error);
            row.Kind="capture-error"; row.ErrorType=error.GetType().FullName; row.ErrorHResult=error.HResult;
            lock(gate) { CaptureFailures++; } Put(row);
        }
        } finally { lock(gate) { inFlight--; System.Threading.Monitor.PulseAll(gate); } }
    }
    private static object TraceValue(System.Management.ManagementBaseObject e, string name) {
        int count=0;
        foreach(System.Management.PropertyData property in e.Properties) {
            if(++count>32) throw new InvalidDataException("Trace property count exceeded.");
            if(String.Equals(property.Name,name,StringComparison.Ordinal)) return property.Value;
        }
        return null;
    }
    private static Dictionary<string,object> Auxiliary(System.Management.ManagementBaseObject e) {
        var row=new Dictionary<string,object> {{"parent_process_id",null},{"event_sid",null},{"event_sid_base64",null},{"sid_status","absent"},{"exit_status",null},{"field_errors",new List<string>()}};
        var errors=(List<string>)row["field_errors"];
        foreach(string field in new[]{"ParentProcessID","ExitStatus"}) {
            object value=TraceValue(e,field);
            if(value!=null) {
                try { row[field=="ParentProcessID" ? "parent_process_id" : "exit_status"]=Convert.ToUInt32(value,CultureInfo.InvariantCulture); }
                catch(Exception error) { errors.Add(field+":"+error.GetType().FullName); }
            }
        }
        object rawSid=TraceValue(e,"Sid");
        if(rawSid!=null) {
            byte[] bytes=rawSid as byte[];
            if(bytes==null || bytes.Length<8 || bytes.Length>68) row["sid_status"]="invalid-or-overbound";
            else {
                row["event_sid_base64"]=Convert.ToBase64String(bytes);
                try { row["event_sid"]=new SecurityIdentifier(bytes,0).Value; row["sid_status"]="observed"; }
                catch(Exception error) { row["sid_status"]="decode-failed"; errors.Add("Sid:"+error.GetType().FullName); }
            }
        }
        return row;
    }
    private bool EnterCallback() { lock(gate) { if(disposing) return false; inFlight++; return true; } }
    private void ExitCallback() { lock(gate) { inFlight--; System.Threading.Monitor.PulseAll(gate); } }
    private void Arrived(object sender, System.Management.EventArrivedEventArgs args) {
        if(!EnterCallback()) return;
        try {
        try {
            using(var e=args.NewEvent) {
            if(e==null || !String.Equals(Convert.ToString(e["ProcessName"]),"RuntimeBroker.exe",StringComparison.OrdinalIgnoreCase)) {
                lock(gate) { ProviderFailures++; } return;
            }
            if(e["ProcessID"]==null || e["TIME_CREATED"]==null || e["SessionID"]==null) throw new InvalidDataException("Incomplete process trace fields.");
            uint pid=Convert.ToUInt32(e["ProcessID"],CultureInfo.InvariantCulture);
            if(pid==0) throw new InvalidDataException("Invalid process trace PID.");
            uint eventSession=Convert.ToUInt32(e["SessionID"],CultureInfo.InvariantCulture);
            string eventTime=Convert.ToUInt64(e["TIME_CREATED"],CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture);
            if(Object.ReferenceEquals(sender,start)) Capture(pid,eventTime,"start-trace",eventSession,Auxiliary(e),null,null);
            else Put(new DrRuntimeBrokerRecord {Kind="stop-trace",Pid=pid,Source="stop-trace",EventTime=eventTime,EventSessionId=eventSession,ReceivedUtc=DateTime.UtcNow.ToString("o"),TraceAuxiliary=Auxiliary(e)});
            }
        } catch(Exception error) {
            lock(gate) { ProviderFailures++; }
            Put(new DrRuntimeBrokerRecord {Kind="event-error",ErrorType=error.GetType().FullName,ErrorHResult=error.HResult,ReceivedUtc=DateTime.UtcNow.ToString("o")});
        }
        } finally { ExitCallback(); }
    }
    private void Stopped(object sender, System.Management.StoppedEventArgs args) {
        if(!EnterCallback()) return;
        try {
            lock(gate) { ProviderFailures++; }
            Put(new DrRuntimeBrokerRecord {Kind="provider-stopped",ErrorHResult=(int)args.Status,ReceivedUtc=DateTime.UtcNow.ToString("o")});
        } finally { ExitCallback(); }
    }
    public void Start() {
        start=new System.Management.ManagementEventWatcher("SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'RuntimeBroker.exe'");
        stop=new System.Management.ManagementEventWatcher("SELECT * FROM Win32_ProcessStopTrace WHERE ProcessName = 'RuntimeBroker.exe'");
        start.EventArrived+=Arrived; stop.EventArrived+=Arrived; start.Stopped+=Stopped; stop.Stopped+=Stopped;
        SubscriptionStartFileTime=DateTime.UtcNow.ToFileTimeUtc().ToString(CultureInfo.InvariantCulture);
        start.Start(); stop.Start(); Started=true;
    }
    public DrRuntimeBrokerRecord[] Drain() { lock(gate) { var rows=queue.ToArray(); queue.Clear(); return rows; } }
    public Dictionary<string,object> Close() {
        lock(gate) { disposing=true; }
        var errors=new List<string>();
        foreach(var watcher in new[]{start,stop}) {
            if(watcher==null) continue;
            try { watcher.Stop(); } catch(Exception e) { errors.Add(e.GetType().FullName); }
            try { watcher.EventArrived-=Arrived; watcher.Stopped-=Stopped; watcher.Dispose(); } catch(Exception e) { errors.Add(e.GetType().FullName); }
        }
        // Stop callbacks before closing leases; no event can create a new held lifetime afterward.
        lock(gate) {
            while(inFlight!=0) System.Threading.Monitor.Wait(gate);
            foreach(var lease in leases.ToArray()) { try { lease.Close(); if(lease.Life.CloseError!=0) errors.Add("native-close-error:"+lease.Life.CloseError); } catch(Exception e) { errors.Add(e.GetType().FullName); } }
            Dropped+=queue.Count; queue.Clear();
        }
        return new Dictionary<string,object> {{"subscriptions_closed",errors.Count==0},{"owned_handles_remaining",OpenHandles},{"errors",errors.ToArray()},
            {"dropped_records",Dropped},{"handle_cap_misses",CapacityMisses},{"capture_failures",CaptureFailures},{"provider_failures",ProviderFailures},{"duplicate_captures",Duplicates},{"native_close_failures",NativeCloseFailures}};
    }
    public void Dispose() { Close(); }
}
'@
    # PS5 CodeDOM permits compiler temporary files to remain inside the owned root.
    $parameters = [CodeDom.Compiler.CompilerParameters]::new()
    $parameters.GenerateInMemory = $true
    $parameters.TempFiles = [CodeDom.Compiler.TempFileCollection]::new($CompilerRoot, $false)
    foreach ($assembly in @('System.dll','System.Core.dll','System.Management.dll')) { [void]$parameters.ReferencedAssemblies.Add($assembly) }
    $receipt = @{ completed=$false; compilation_succeeded=$false; owned_temp_artifacts_remaining=0; errors=@();
        compilation_failure=$null; type_reused=$false; started_guest_utc=[DateTime]::UtcNow.ToString('o') }
    try { Add-Type -TypeDefinition $code -CompilerParameters $parameters -ErrorAction Stop; $receipt.compilation_succeeded=$true }
    catch { $receipt.compilation_failure=@{ error_type=$_.Exception.GetType().FullName; hresult=$_.Exception.HResult } }
    finally {
        $cleanup=Remove-DrRuntimeBrokerCompilerArtifacts -TempFiles $parameters.TempFiles -CompilerRoot $CompilerRoot
        foreach ($key in $cleanup.Keys) { $receipt[$key]=$cleanup[$key] }
        $receipt.completed_guest_utc=[DateTime]::UtcNow.ToString('o')
        if ($cleanup.completed) {
            try { $parameters.TempFiles.Dispose() } catch { $receipt.errors += $_.Exception.GetType().FullName; $receipt.completed=$false }
        }
        else { [GC]::SuppressFinalize($parameters.TempFiles) }
    }
    return $receipt
}

function Read-DrRuntimeBrokerJsonBytes {
    param([string]$Path, [int]$Limit)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Diagnostic input is not an ordinary file.' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $Limit) { throw 'Diagnostic input byte limit exceeded.' }
        $bytes = [byte[]]::new([int]$stream.Length); $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($count -eq 0) { throw 'Diagnostic input changed during read.' }
            $offset += $count
        }
        if ($stream.ReadByte() -ne -1) { throw 'Diagnostic input changed during read.' }
        return ,$bytes
    } finally { $stream.Dispose() }
}
function ConvertFrom-DrRuntimeBrokerJson {
    param([byte[]]$Bytes)
    $text = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes).TrimStart([char]0xfeff)
    # PS5 preserves JSON dates as strings; require the same behavior in host-only PS7 tests.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $text -DateKind String }
    return ConvertFrom-Json -InputObject $text
}

function Get-DrRuntimeBrokerBytesHash {
    param([byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Invoke-DrRuntimeBrokerMetadataQuery {
    param([string]$Name, [scriptblock]$Action)
    $query = [ordered]@{ query=$Name; started_guest_utc=[DateTime]::UtcNow.ToString('o'); completed_guest_utc=$null;
        succeeded=$false; value=$null; error_type=$null; error_hresult=$null }
    try { $query.value = & $Action; $query.succeeded=$true }
    catch { $query.error_type=$_.Exception.GetType().FullName; $query.error_hresult=$_.Exception.HResult }
    finally { $query.completed_guest_utc=[DateTime]::UtcNow.ToString('o') }
    return $query
}
function Get-DrRuntimeBrokerImageEvidence {
    param([string]$Path, [string]$ExpectedLeaf)
    $canonical = Join-Path (Join-Path $env:windir 'System32') $ExpectedLeaf
    if (-not [string]::Equals($Path, $canonical, [StringComparison]::OrdinalIgnoreCase)) {
        return [ordered]@{ status='noncanonical-not-inspected'; image_path=$Path }
    }
    $content = Invoke-DrRuntimeBrokerMetadataQuery 'image-content' {
        $bytes=Read-DrRuntimeBrokerJsonBytes $canonical 16MB
        [ordered]@{ sha256=Get-DrRuntimeBrokerBytesHash $bytes; bytes=$bytes.Length }
    }
    $signature = Invoke-DrRuntimeBrokerMetadataQuery 'image-signature' {
        $value=Get-AuthenticodeSignature -LiteralPath $canonical -ErrorAction Stop
        [ordered]@{ signature_status=[string]$value.Status;
            signer_subject=if ($null -ne $value.SignerCertificate) { $value.SignerCertificate.Subject } else { $null };
            signer_thumbprint=if ($null -ne $value.SignerCertificate) { $value.SignerCertificate.Thumbprint } else { $null } }
    }
    return [ordered]@{ status=if ($content.succeeded -and $signature.succeeded) { 'observed' } else { 'partial-query-failure' };
        image_path=$canonical; content=$content; signature=$signature; signature_and_hash_same_read=$false }
}
function Get-DrRuntimeBrokerEnrichment {
    param($Record, $Backend)
    $native=$Record.Lease.Life.Identity
    $row=[ordered]@{ status='partial'; target_cim=$null; command_line=$null; command_line_present=$false; command_line_status='not-observed'; parent_pid=$null; parent=$null; image_evidence=$null }
    $query=Invoke-DrRuntimeBrokerMetadataQuery 'target-cim' {
        $processes=@(Get-CimInstance Win32_Process -Filter "ProcessId=$($Record.Pid)" -OperationTimeoutSec 3 -ErrorAction Stop)
        if ($processes.Count -ne 1 -or $null -eq $processes[0].CreationDate) { throw 'CIM target is missing or ambiguous.' }
        $process=$processes[0]
        $ticks=$process.CreationDate.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        $delta=[long]$native.creation_filetime_100ns - [long]$ticks
        if ($delta -lt 0 -or $delta -gt 9 -or $process.SessionId -ne $native.session_id) {
            return [ordered]@{ creation_filetime_100ns=$ticks; session_id=[int]$process.SessionId; parent_pid=$null; command_line_present=$false; command_line_status='not-read-lifetime-mismatch'; command_line=$null }
        }
        $present=$null -ne $process.PSObject.Properties['CommandLine']
        $command=if ($present) { $process.CommandLine } else { $null }
        $commandStatus=if (-not $present) { 'absent' } elseif ($null -eq $command) { 'null' } elseif ($command -isnot [string]) { 'invalid-type' } elseif ($command.Length -gt 4096) { 'overbound' } else { 'observed' }
        [ordered]@{ creation_filetime_100ns=$process.CreationDate.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture); session_id=[int]$process.SessionId;
            parent_pid=[int]$process.ParentProcessId; command_line_present=$present; command_line_status=$commandStatus;
            command_line=if ($commandStatus -ceq 'observed') { $command } else { $null } }
    }
    $row.target_cim=$query
    if (-not $query.succeeded) { return $row }
    $value=$query.value
    $difference=[long]$native.creation_filetime_100ns - [long]$value.creation_filetime_100ns
    $row.cim_creation_filetime_100ns=$value.creation_filetime_100ns; $row.native_minus_cim_ticks=$difference.ToString([Globalization.CultureInfo]::InvariantCulture); $row.session_id=$value.session_id
    if ($difference -lt 0 -or $difference -gt 9 -or $value.session_id -ne $native.session_id) { $row.status='CIM-native-lifetime-mismatch'; return $row }
    $row.command_line=$value.command_line; $row.command_line_present=$value.command_line_present; $row.command_line_status=$value.command_line_status; $row.parent_pid=$value.parent_pid
    if ($value.command_line_status -ceq 'observed') {
        $row.command_line_sha256=Get-DrRuntimeBrokerBytesHash ([Text.Encoding]::UTF8.GetBytes($value.command_line)); $row.command_line_length=$value.command_line.Length
    }
    $row.image_evidence=Get-DrRuntimeBrokerImageEvidence ([string]$native.image_path) 'RuntimeBroker.exe'
    $row.status=if ($row.image_evidence.status -ceq 'partial-query-failure' -or $value.command_line_status -in @('invalid-type','overbound')) { 'partial' } else { 'observed' }
    if ($value.parent_pid -eq 0) { $row.parent=[ordered]@{ association_status='no-parent-pid' }; return $row }
    $parentQuery=Invoke-DrRuntimeBrokerMetadataQuery 'parent-native-open' { $Backend.Session.OpenParent([uint32]$value.parent_pid) }
    $parent=$parentQuery.value; $parentQuery.value=$null
    $parentRow=[ordered]@{ native_open=$parentQuery; native_identity=$null; association_status='unknown'; cim=$null; image_evidence=$null; same_handle_wait=$null; handle_closed=$false; close_win32_error=$null; close_query=$null }
    $row.parent=$parentRow
    if (-not $parentQuery.succeeded) { $parentRow.association_status='capture-failed'; $row.status='partial'; return $row }
    if ($null -eq $parent) { $parentRow.association_status='handle-cap'; $row.status='partial'; return $row }
    try {
        $identity=$parent.Life.Identity; $parentRow.native_identity=$identity
        if ($identity.open_error -ne 0 -or $null -eq $identity.creation_filetime_100ns) { $parentRow.association_status='capture-failed'; $row.status='partial'; return $row }
        if ([long]$identity.creation_filetime_100ns -gt [long]$native.creation_filetime_100ns) { $parentRow.association_status='invalid-parent-newer-than-child'; $row.status='partial'; return $row }
        $parentRow.cim=Invoke-DrRuntimeBrokerMetadataQuery 'parent-cim' {
            $parents=@(Get-CimInstance Win32_Process -Filter "ProcessId=$($value.parent_pid)" -OperationTimeoutSec 3 -ErrorAction Stop)
            if ($parents.Count -ne 1 -or $null -eq $parents[0].CreationDate) { throw 'CIM parent is missing or ambiguous.' }
            [ordered]@{ creation_filetime_100ns=$parents[0].CreationDate.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture); session_id=[int]$parents[0].SessionId; name=[string]$parents[0].Name }
        }
        if (-not $parentRow.cim.succeeded) { $parentRow.association_status='CIM-parent-query-failed'; $row.status='partial'; return $row }
        $parentCim=$parentRow.cim.value
        $delta=[long]$identity.creation_filetime_100ns - [long]$parentCim.creation_filetime_100ns; $parentCim.native_minus_cim_ticks=$delta.ToString([Globalization.CultureInfo]::InvariantCulture)
        if ($delta -lt 0 -or $delta -gt 9 -or $parentCim.session_id -ne $identity.session_id) { $parentRow.association_status='CIM-native-parent-mismatch'; $row.status='partial'; return $row }
        $parentRow.association_status='creation-order-corroborated-not-causality'
        if ($parentCim.name -cmatch '^[A-Za-z0-9._-]{1,128}\.exe$') {
            $parentRow.image_evidence=Get-DrRuntimeBrokerImageEvidence ([string]$identity.image_path) $parentCim.name
            if ($parentRow.image_evidence.status -ceq 'partial-query-failure') { $row.status='partial' }
        }
        $parentRow.same_handle_wait=Invoke-DrRuntimeBrokerMetadataQuery 'parent-same-handle-wait' { $parent.Life.Poll() }
        if (-not $parentRow.same_handle_wait.succeeded) { $row.status='partial' }
    } finally {
        $parentRow.close_query=Invoke-DrRuntimeBrokerMetadataQuery 'parent-close' { $parent.Close() }
        $parentRow.handle_closed=$parent.Closed; $parentRow.close_win32_error=$parent.Life.CloseError
        if (-not $parentRow.close_query.succeeded -or -not $parent.Closed -or $parent.Life.CloseError -ne 0) { $row.status='partial' }
    }
    return $row
}

function Invoke-DrRuntimeBrokerObserverCore {
    param([string]$Root, [string]$RunId, [string]$RunnerSid, [int]$DurationSeconds, [hashtable]$Backend,
        [int]$MetadataLimit = 14MB, [int]$TerminalReserve = 256KB, [string]$ExpectedVmId = '', [System.Collections.IDictionary]$CompilerCleanup = @{ completed=$false; owned_temp_artifacts_remaining=$null; errors=@('not-supplied') })
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $state = @{ bytes = 0; issues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); active = @{}; seen = @{};
        phases = @{}; phase_bytes = 0; records = 0; ready = $false; stop_reason = 'deadline'; cleanup = $null; failure_detail = $null; staging = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); staging_created = 0; staging_published = 0; staging_discarded = 0 }
    $events = $null
    function Write-ObserverRecord {
        param($Record, [bool]$Terminal = $false, [string]$Leaf = '')
        $json = $Record | ConvertTo-Json -Depth 16 -Compress
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
        $limit = if ($Terminal) { $MetadataLimit } else { $MetadataLimit - $TerminalReserve }
        if ($bytes.Length -gt 96KB -or $state.bytes + $bytes.Length -gt $limit) { throw 'Diagnostic metadata budget exceeded.' }
        if ($Leaf) {
            $path=Join-Path $Root $Leaf
            $stage=Join-Path $Root ('.runtimebroker-' + [guid]::NewGuid().ToString('N') + '.tmp')
            $file=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            [void]$state.staging.Add($stage); $state.staging_created++
            try {
                try { $file.Write($bytes,0,$bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
                [IO.File]::Move($stage,$path)
                $state.staging_published++; [void]$state.staging.Remove($stage)
            } finally {
                if ($state.staging.Contains($stage)) {
                    if (Test-Path -LiteralPath $stage) { [IO.File]::Delete($stage) }
                    if (-not (Test-Path -LiteralPath $stage)) { [void]$state.staging.Remove($stage); $state.staging_discarded++ }
                }
            }
        } else { $events.Write($bytes,0,$bytes.Length); $events.Flush(); $state.records++ }
        $state.bytes += $bytes.Length
    }
    function Drain-ObserverRecords {
        foreach ($record in @(& $Backend.Drain)) {
            $row = [ordered]@{ kind = $record.Kind; source = $record.Source; pid = $record.Pid;
                event_filetime_100ns = $record.EventTime; event_session_id = $record.EventSessionId; received_at_utc = $record.ReceivedUtc; discovered_elapsed_ms = $watch.ElapsedMilliseconds;
                native_capture_started_guest_utc = $record.NativeCaptureStartedUtc; native_identity_completed_guest_utc = $record.NativeIdentityCompletedUtc;
                subscription_start_filetime_100ns = $record.SubscriptionStartFileTime; existing_at_start = $record.ExistingAtStart; origin_classification = $record.OriginClassification; trace_auxiliary = $record.TraceAuxiliary;
                snapshot_identity = if ($record.Source -ceq 'initial-snapshot') { @{ pid=$record.Pid; creation_filetime_100ns=$record.SnapshotCreationFileTime; session_id=$record.SnapshotSessionId } } else { $null };
                identity_status = 'not-captured'; owner_scope = $record.OwnerScope; native_identity = $null; enrichment = $null;
                error_type = $record.ErrorType; error_hresult = $record.ErrorHResult; failure_close = $record.FailureClose; causal_attribution = 'unknown' }
            if ($null -ne $record.Lease) {
                $lease = $record.Lease; $identity = $lease.Life.Identity
                if ($record.OwnerScope -ceq 'foreign') {
                    $row.trace_auxiliary=$null; $row.snapshot_identity=$null; $row.identity_status = 'foreign-owner-excluded'; $row.native_identity = [ordered]@{ pid = $identity.pid; creation_filetime_100ns = $identity.creation_filetime_100ns }
                } else { $row.native_identity = $identity; $row.identity_status = if ($record.OwnerScope -ceq 'runner') { 'native-identified' } else { 'partial-or-capture-failed' } }
                if ($record.Kind -ceq 'capture-mismatch-or-failure' -and $record.OwnerScope -cne 'foreign') { $row.identity_status='target-association-mismatch-or-capture-failed' }
                if ($record.Kind -ceq 'capture' -and $record.OwnerScope -ceq 'runner') {
                    $row.identity_status = if ($identity.package_first_status -eq 15700) { 'no-package-identity' } elseif ($identity.aumid_first_status -eq 15703) { 'no-application-identity' } elseif ($null -eq $identity.package_full_name -or $null -eq $identity.aumid) { 'identity-query-incomplete' } else { 'native-identified' }
                }
                $key = [string]$identity.pid + '|' + [string]$identity.creation_filetime_100ns
                if (-not $lease.Closed -and $record.Kind -ceq 'capture') {
                    if ($state.seen.ContainsKey($key)) { $lease.Close(); $row.kind = 'duplicate' }
                    else {
                        if ($state.seen.Count -ge 4096) { throw 'Lifetime identity count exceeded.' }
                        $state.seen[$key] = $true
                        $state.active[$key] = @{ lease = $lease; last_poll = $null }
                        if ($watch.Elapsed.TotalSeconds -ge $DurationSeconds) {
                            $lease.Close(); $state.active.Remove($key); [void]$state.issues.Add('deadline-before-record-enrichment')
                        } elseif ($record.OwnerScope -ceq 'runner') {
                            try { $row.enrichment = & $Backend.Enrich $record $Backend; if ($row.enrichment.status -in @('partial','CIM-native-lifetime-mismatch')) { [void]$state.issues.Add('metadata-enrichment-incomplete') } }
                            catch { [void]$state.issues.Add('metadata-enrichment-failed'); $row.error_type = $_.Exception.GetType().FullName; $row.error_hresult = $_.Exception.HResult }
                        }
                    }
                }
                if ($record.OwnerScope -ceq 'unknown') { [void]$state.issues.Add('owner-query-incomplete') }
                foreach ($field in @('open_error','pid_error','times_error','image_error','token_error','token_sid_error','token_session_error')) {
                    if ($identity.ContainsKey($field) -and $identity[$field] -ne 0) { [void]$state.issues.Add('native-identity-query-incomplete') }
                }
                if ($identity.ContainsKey('token_close_error') -and $identity.token_close_error -ne 0) { [void]$state.issues.Add('token-close-failed') }
                $row.handle_closed = $lease.Closed; $row.close_win32_error = $lease.Life.CloseError
            }
            if ($record.Kind -in @('handle-cap','identity-cap','capture-error','capture-mismatch-or-failure','event-error','provider-stopped')) { [void]$state.issues.Add($record.Kind) }
            Write-ObserverRecord $row
        }
    }
    function Poll-ObserverHandles {
        param([bool]$Final = $false)
        foreach ($key in @($state.active.Keys)) {
            $entry = $state.active[$key]
            try {
                $poll = $entry.lease.Life.Poll(); $entry.last_poll = $poll
                if ($poll.wait_result -eq 0 -or $Final) {
                    if ($poll.wait_result -eq 0 -and (-not $poll.times_succeeded -or -not $poll.exit_code_succeeded)) { [void]$state.issues.Add('native-exit-query-incomplete') }
                    $entry.lease.Close(); $poll.handle_closed = $entry.lease.Closed; $poll.close_win32_error = $entry.lease.Life.CloseError
                    Write-ObserverRecord ([ordered]@{ kind = 'same-handle-exit-or-final'; identity = $key;
                        exit_observation_status = if ($poll.wait_result -eq 0 -and $poll.times_succeeded -and $poll.exit_code_succeeded) { 'same-held-handle-exit-observed' } else { 'alive-or-incomplete-at-final-observation' };
                        native_exit = $poll; elapsed_ms = $watch.ElapsedMilliseconds; causal_attribution = 'unknown' }) $Final
                    $state.active.Remove($key)
                }
            } catch { [void]$state.issues.Add('native-poll-or-output-failed'); if (-not $Final) { throw } }
        }
    }
    function Read-ObserverRequests {
        $stop = Join-Path $Root 'stop-request.json'
        if (Test-Path -LiteralPath $stop) {
            $bytes = Read-DrRuntimeBrokerJsonBytes $stop 4KB
            $request = ConvertFrom-DrRuntimeBrokerJson $bytes
            if ($request.schema_version -ne 1 -or $request.run_id -cne $RunId) { throw 'Stop request identity differs.' }
            if ($bytes.Length -gt 4KB) { throw 'Stop request byte limit exceeded.' }; $state.stop_reason = 'matching-stop-request'; return $true
        }
        $phaseRoot = Join-Path $Root 'phases'
        if (Test-Path -LiteralPath $phaseRoot) {
            $item = Get-Item -LiteralPath $phaseRoot -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Phase root is not ordinary.' }
            $files = @(Get-ChildItem -LiteralPath $phaseRoot -Force -ErrorAction Stop)
            if ($files.Count -gt 256) { throw 'Phase file count exceeded.' }
            foreach ($file in $files) {
                if ($file.Name -cnotmatch '^[0-9a-f]{32}\.json$') { throw 'Phase leaf identity differs.' }
                $bytes = Read-DrRuntimeBrokerJsonBytes $file.FullName 4096
                if ($state.phases.ContainsKey($file.Name)) {
                    if ((Get-DrRuntimeBrokerBytesHash $bytes) -cne $state.phases[$file.Name]) { throw 'Immutable phase record changed.' }
                    continue
                }
                $data = ConvertFrom-DrRuntimeBrokerJson $bytes
                if ($data.schema_version -ne 1 -or $data.run_id -cne $RunId -or $data.phase -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or
                    $data.state -cnotin @('begin','end','observed') -or $data.source -cnotin @('host','controller','ui-observer') -or
                    $data.recorded_at_utc -notmatch '^\d{4}-\d{2}-\d{2}T[^\r\n]{1,40}Z$' -or $data.details -isnot [pscustomobject]) { throw 'Phase record schema differs.' }
                $state.phase_bytes += $bytes.Length
                if ($state.phase_bytes -gt 1MB) { throw 'Phase input aggregate budget exceeded.' }
                Write-ObserverRecord ([ordered]@{ kind = 'phase'; clock_domain = $data.source; record = $data;
                    received_guest_utc = [DateTime]::UtcNow.ToString('o'); received_elapsed_ms = $watch.ElapsedMilliseconds })
                $state.phases[$file.Name] = Get-DrRuntimeBrokerBytesHash $bytes
            }
        }
        return $false
    }
    try {
        $events = [IO.File]::Open((Join-Path $Root 'events.jsonl'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        & $Backend.Start
        if (-not (& $Backend.Ready)) { throw 'Subscriptions are not ready.' }
        foreach ($snapshot in @(& $Backend.Snapshot)) {
            if ($watch.Elapsed.TotalSeconds -ge $DurationSeconds) { throw 'Initial snapshot capture exceeded deadline.' }
            & $Backend.Capture $snapshot
        }
        Drain-ObserverRecords
        if ($watch.Elapsed.TotalSeconds -ge $DurationSeconds) { throw 'Readiness exceeded observation deadline.' }
        if (-not (& $Backend.Ready)) { throw 'Subscriptions failed during initial snapshot or enrichment.' }
        Write-ObserverRecord ([ordered]@{ schema_version = 1; run_id = $RunId; runner_sid = $RunnerSid; expected_vm_id = $ExpectedVmId; status = 'ready'; subscriptions_started_before_snapshot = $true;
            initial_snapshot_complete = $true; ready_guest_utc = [DateTime]::UtcNow.ToString('o'); elapsed_ms = $watch.ElapsedMilliseconds;
            observation_coverage = 'best-effort-WMI-not-lossless'; causal_attribution = 'unknown' }) $false 'ready.json'
        $state.ready = $true
        while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
            Poll-ObserverHandles
            Drain-ObserverRecords
            if (Read-ObserverRequests) { break }
            & $Backend.Delay
        }
    } catch { [void]$state.issues.Add('observer-failed:' + $_.Exception.GetType().FullName); $state.stop_reason = 'error-or-budget';
        $state.failure_detail = @{ error_type = $_.Exception.GetType().FullName; hresult = $_.Exception.HResult; line = $_.InvocationInfo.ScriptLineNumber } }
    finally {
        try { Poll-ObserverHandles $true } catch { [void]$state.issues.Add('final-poll-failed') }
        try { $state.cleanup = & $Backend.Close } catch { [void]$state.issues.Add('backend-cleanup-failed'); $state.cleanup = @{ subscriptions_closed = $false; owned_handles_remaining = $null; errors = @($_.Exception.GetType().FullName) } }
        if ($null -ne $events) { $events.Dispose() }
    }
    if ($null -ne $state.cleanup) {
        if (-not $state.cleanup.subscriptions_closed -or $state.cleanup.owned_handles_remaining -ne 0 -or @($state.cleanup.errors).Count -ne 0) {
            [void]$state.issues.Add('cleanup-incomplete')
        }
        foreach ($field in @('dropped_records','handle_cap_misses','capture_failures','provider_failures','native_close_failures')) {
            if ($state.cleanup.ContainsKey($field) -and $state.cleanup[$field] -gt 0) { [void]$state.issues.Add('coverage-or-close-loss:' + $field) }
        }
    }
    if (-not $CompilerCleanup.completed -or $CompilerCleanup.owned_temp_artifacts_remaining -ne 0 -or @($CompilerCleanup.errors).Count -ne 0) { [void]$state.issues.Add('compiler-cleanup-incomplete') }
    if ($state.staging.Count -ne 0) {
        [void]$state.issues.Add('output-staging-cleanup-incomplete')
        if ($null -ne $state.cleanup) { $state.cleanup['errors']=@($state.cleanup.errors) + 'output-staging-cleanup-incomplete' }
    }
    $result = [ordered]@{ schema_version = 1; run_id = $RunId; runner_sid = $RunnerSid; expected_vm_id = $ExpectedVmId; status = if ($state.issues.Count) { 'diagnostic-incomplete' } else { 'diagnostic-completed' };
        identity_status = 'per-lifetime-recorded-or-unknown'; exit_observation_status = 'per-held-handle-recorded-or-unknown';
        observation_coverage = if ($state.issues.Count) { 'incomplete-best-effort-not-lossless' } else { 'best-effort-not-lossless' }; causal_attribution = 'unknown'; ready_written = $state.ready;
        stop_reason = $state.stop_reason; observed_guest_utc = [DateTime]::UtcNow.ToString('o'); elapsed_ms = $watch.ElapsedMilliseconds;
        records = $state.records; diagnostic_metadata_bytes_before_result = $state.bytes; phase_input_bytes = $state.phase_bytes; issues = @($state.issues | Sort-Object); failure_detail = $state.failure_detail; cleanup = $state.cleanup; compiler_cleanup = $CompilerCleanup;
        output_staging = @{ created_before_result=$state.staging_created; published_before_result=$state.staging_published; discarded_before_result=$state.staging_discarded; remaining_before_result=$state.staging.Count; result_publication='atomic-exclusive-after-close' };
        processes_terminated = 0; settings_or_acl_changes = $false }
    Write-ObserverRecord $result $true 'result.json'
    return [pscustomobject]$result
}

function Invoke-DrRuntimeBrokerObserver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^S-1-[0-9-]{1,180}$')][string]$RunnerSid,
        [Parameter(Mandatory)][guid]$ExpectedVmId,
        [ValidateRange(1,900)][int]$DurationSeconds = 900
    )
    $entryWatch = [Diagnostics.Stopwatch]::StartNew()
    if ($env:OS -cne 'Windows_NT' -or $PSVersionTable.PSEdition -cne 'Desktop' -or [IntPtr]::Size -ne 8) {
        throw 'Native diagnostics require Windows PowerShell 5.1 x64.'
    }
    $expectedRoot = Join-Path $env:ProgramData ('DarkReNamerRuntimeBrokerDiag-' + $RunId)
    if ($env:ProgramData -ine 'C:\ProgramData' -or $Root -cne $expectedRoot -or $ExpectedVmId -eq [guid]::Empty) { throw 'Fixed diagnostic root or VM identity differs.' }
    foreach ($path in @('C:\','C:\ProgramData',$Root)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Diagnostic root ancestry is not ordinary.' }
    }
    $acl = Get-Acl -LiteralPath $Root -ErrorAction Stop
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -cnotin @('S-1-5-18','S-1-5-32-544') -or -not $acl.AreAccessRulesProtected) { throw 'Diagnostic root is not privately protected by a trusted owner.' }
    $runnerRead = $false
    foreach ($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if (($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        if ($ace.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) {
            $sid = $ace.IdentityReference.Value; $mask = [uint32]([int64]$ace.FileSystemRights -band 0xffffffffL)
            if ($sid -cnotin @('S-1-5-18','S-1-5-32-544') -and ($mask -band 0x500d0156L) -ne 0) { throw 'Diagnostic root permits an untrusted effective write.' }
            if ($sid -ceq $RunnerSid -and ($mask -band 1) -ne 0) { $runnerRead = $true }
        }
    }
    if (-not $runnerRead) { throw 'Diagnostic root has no explicit runner read access.' }
    $actualVm = [guid](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -Name VirtualMachineId -ErrorAction Stop).VirtualMachineId
    if ($actualVm -ne $ExpectedVmId) { throw 'Prepared guest VM identity differs.' }
    foreach ($leaf in @('ready.json','events.jsonl','result.json')) {
        if (Test-Path -LiteralPath (Join-Path $Root $leaf)) { throw 'Existing diagnostic output is preserved.' }
    }
    $compilerReceipt=Initialize-DrRuntimeBrokerNative $Root
    $remainingSeconds = [int][Math]::Floor($DurationSeconds - $entryWatch.Elapsed.TotalSeconds)
    if ($remainingSeconds -le 0) { throw 'Diagnostic setup consumed observation deadline.' }
    if (-not $compilerReceipt.compilation_succeeded -or -not $compilerReceipt.completed) {
        $failedBackend=@{ Start={ throw 'Native compilation or compiler cleanup failed.' }; Ready={ $false }; Drain={ @() };
            Close={ @{ subscriptions_closed=$true; owned_handles_remaining=0; errors=@(); native_close_failures=0 } } }
        [void](Invoke-DrRuntimeBrokerObserverCore -Root $Root -RunId $RunId -RunnerSid $RunnerSid -DurationSeconds $remainingSeconds -Backend $failedBackend -ExpectedVmId $ExpectedVmId.ToString() -CompilerCleanup $compilerReceipt)
        throw 'Native compilation or compiler cleanup failed; inspect result.json.'
    }
    $session = [DrRuntimeBrokerSession]::new($RunnerSid)
    $backend = @{
        Session = $session
        Start = { $session.Start() }.GetNewClosure()
        Ready = { $session.Started -and $session.ProviderFailures -eq 0 }.GetNewClosure()
        Snapshot = {
            $rows = @(Get-CimInstance Win32_Process -Filter "Name='RuntimeBroker.exe'" -OperationTimeoutSec 3 -ErrorAction Stop)
            if ($rows.Count -gt 4096) { throw 'Initial target snapshot bound exceeded.' }
            @($rows | ForEach-Object { [pscustomobject]@{ pid=[uint32]$_.ProcessId;
                creation_filetime_100ns=if ($null -ne $_.CreationDate) { $_.CreationDate.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture) } else { $null };
                session_id=if ($null -ne $_.SessionId) { [uint32]$_.SessionId } else { $null } } })
        }
        Capture = { param($Snapshot) $session.CaptureSnapshot([uint32]$Snapshot.pid,$Snapshot.creation_filetime_100ns,$Snapshot.session_id) }.GetNewClosure()
        Drain = { $session.Drain() }.GetNewClosure()
        Enrich = ${function:Get-DrRuntimeBrokerEnrichment}
        Delay = { Start-Sleep -Milliseconds 100 }
        Close = { $session.Close() }.GetNewClosure()
    }
    Invoke-DrRuntimeBrokerObserverCore -Root $Root -RunId $RunId -RunnerSid $RunnerSid -DurationSeconds $remainingSeconds -Backend $backend -ExpectedVmId $ExpectedVmId.ToString() -CompilerCleanup $compilerReceipt
}
