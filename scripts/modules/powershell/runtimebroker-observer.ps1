# Diagnostic observer only. No acceptance classification or process intervention.
function Initialize-DrRuntimeBrokerNative {
    param([string]$CompilerRoot)
    if ('DrRuntimeBrokerNative' -as [type]) { return }
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
        try {
            var row = new Dictionary<string, object> {
                {"pid", 0u}, {"creation_filetime_100ns", null}, {"owner_sid", null}, {"session_id", null}, {"image_path", null},
                {"open_error", openError}, {"pid_error", 0}, {"times_error", 0}, {"image_error", 0},
                {"token_error", 0}, {"token_close_error", 0}, {"token_sid_error", 0}, {"token_session_error", 0}
            };
            if (package) { row["package_first_status"] = null; row["package_status"] = null; row["aumid_first_status"] = null; row["aumid_status"] = null; row["package_full_name"] = null; row["aumid"] = null; }
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
        } catch { handle.Dispose(); throw; }
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
    public string Kind, Source, EventTime, ReceivedUtc, OwnerScope, ErrorType;
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
    public int OpenHandles { get { lock(gate) { return slots; } } }
    public DrRuntimeBrokerSession(string sid) { runnerSid=sid; }
    internal void Release(DrRuntimeBrokerLease lease) { lock(gate) { slots--; if(lease!=null) { leases.Remove(lease); if(lease.Life.CloseError!=0) NativeCloseFailures++; } } }
    private bool Reserve() { lock(gate) { if(disposing || slots>=64) { CapacityMisses++; return false; } slots++; return true; } }
    private void Put(DrRuntimeBrokerRecord row) {
        bool dropped=false;
        lock(gate) { if(disposing || queue.Count>=256) { Dropped++; dropped=true; } else queue.Enqueue(row); }
        if(dropped && row.Lease!=null) row.Lease.Close();
    }
    public DrRuntimeBrokerLease OpenParent(uint pid) {
        if(!Reserve()) return null;
        try {
            var lease=new DrRuntimeBrokerLease(this,DrRuntimeBrokerNative.Open(pid,false));
            lock(gate) { leases.Add(lease); }
            return lease;
        } catch { Release(null); throw; }
    }
    public void Capture(uint pid, string eventTime, string source) { Capture(pid,eventTime,source,null); }
    private void Capture(uint pid, string eventTime, string source, uint? eventSession) {
        lock(gate) { if(disposing) { Dropped++; return; } inFlight++; }
        try {
        var row=new DrRuntimeBrokerRecord { Kind="capture",Pid=pid,Source=source,EventTime=eventTime,EventSessionId=eventSession,ReceivedUtc=DateTime.UtcNow.ToString("o") };
        if(!Reserve()) { row.Kind="handle-cap"; Put(row); return; }
        DrRuntimeBrokerLease lease=null;
        try {
            lease=new DrRuntimeBrokerLease(this,DrRuntimeBrokerNative.Open(pid,false));
            row.Lease=lease;
            lock(gate) { leases.Add(lease); }
            var id=lease.Life.Identity;
            string created=id["creation_filetime_100ns"] as string;
            if(!DrRuntimeBrokerNative.MatchesCapturedLifetime(pid,(uint)id["pid"],created,eventTime) ||
                (eventSession.HasValue && id["session_id"]!=null && (uint)id["session_id"]!=eventSession.Value)) {
                row.Kind="capture-mismatch-or-failure"; lock(gate) { CaptureFailures++; } lease.Close(); Put(row); return;
            }
            string key=pid.ToString(CultureInfo.InvariantCulture)+"|"+created;
            lock(gate) {
                if(seen.Contains(key)) { row.Kind="duplicate"; Duplicates++; }
                else if(seen.Count>=4096) { row.Kind="identity-cap"; CapacityMisses++; }
                else seen.Add(key);
            }
            if(row.Kind!="capture") { lease.Close(); Put(row); return; }
            string sid=id["owner_sid"] as string;
            row.OwnerScope=sid==null ? "unknown" : (sid==runnerSid ? "runner" : "foreign");
            if(row.OwnerScope=="runner") DrRuntimeBrokerNative.CompletePackage(lease.Life);
            else if(row.OwnerScope=="foreign") lease.Close();
            Put(row);
        } catch(Exception error) {
            if(lease!=null) lease.Close(); else Release(null);
            row.Kind="capture-error"; row.ErrorType=error.GetType().FullName; row.ErrorHResult=error.HResult;
            lock(gate) { CaptureFailures++; } Put(row);
        }
        } finally { lock(gate) { inFlight--; System.Threading.Monitor.PulseAll(gate); } }
    }
    private void Arrived(object sender, System.Management.EventArrivedEventArgs args) {
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
            if(Object.ReferenceEquals(sender,start)) Capture(pid,eventTime,"start-trace",eventSession);
            else Put(new DrRuntimeBrokerRecord {Kind="stop-trace",Pid=pid,Source="stop-trace",EventTime=eventTime,EventSessionId=eventSession,ReceivedUtc=DateTime.UtcNow.ToString("o")});
            }
        } catch(Exception error) {
            lock(gate) { ProviderFailures++; }
            Put(new DrRuntimeBrokerRecord {Kind="event-error",ErrorType=error.GetType().FullName,ErrorHResult=error.HResult,ReceivedUtc=DateTime.UtcNow.ToString("o")});
        }
    }
    private void Stopped(object sender, System.Management.StoppedEventArgs args) {
        lock(gate) { if(disposing) return; ProviderFailures++; }
        Put(new DrRuntimeBrokerRecord {Kind="provider-stopped",ErrorHResult=(int)args.Status,ReceivedUtc=DateTime.UtcNow.ToString("o")});
    }
    public void Start() {
        start=new System.Management.ManagementEventWatcher("SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'RuntimeBroker.exe'");
        stop=new System.Management.ManagementEventWatcher("SELECT * FROM Win32_ProcessStopTrace WHERE ProcessName = 'RuntimeBroker.exe'");
        start.EventArrived+=Arrived; stop.EventArrived+=Arrived; start.Stopped+=Stopped; stop.Stopped+=Stopped;
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
    try { Add-Type -TypeDefinition $code -CompilerParameters $parameters -ErrorAction Stop }
    finally { $parameters.TempFiles.Delete() }
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
function Get-DrRuntimeBrokerImageEvidence {
    param([string]$Path, [string]$ExpectedLeaf)
    $canonical = Join-Path (Join-Path $env:windir 'System32') $ExpectedLeaf
    if (-not [string]::Equals($Path, $canonical, [StringComparison]::OrdinalIgnoreCase)) {
        return [ordered]@{ status = 'noncanonical-not-inspected'; image_path = $Path }
    }
    $item = Get-Item -LiteralPath $canonical -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 16MB) {
        throw 'Canonical image is not a bounded ordinary file.'
    }
    $bytes = Read-DrRuntimeBrokerJsonBytes $canonical 16MB
    $signature = Get-AuthenticodeSignature -LiteralPath $canonical -ErrorAction Stop
    return [ordered]@{ status = 'observed'; image_path = $canonical; sha256 = Get-DrRuntimeBrokerBytesHash $bytes;
        bytes = $bytes.Length; signature_status = [string]$signature.Status;
        signer_subject = if ($null -ne $signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null };
        signer_thumbprint = if ($null -ne $signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { $null };
        signature_and_hash_same_read = $false }
}
function Get-DrRuntimeBrokerEnrichment {
    param($Record, $Backend)
    $native = $Record.Lease.Life.Identity
    $processes = @(Get-CimInstance Win32_Process -Filter "ProcessId=$($Record.Pid)" -OperationTimeoutSec 3 -ErrorAction Stop)
    if ($processes.Count -ne 1 -or $null -eq $processes[0].CreationDate) { return [ordered]@{ status = 'CIM-missing-or-ambiguous'; parent = $null } }
    $process = $processes[0]; $cimTicks = $process.CreationDate.ToUniversalTime().ToFileTimeUtc()
    $difference = [long]$native.creation_filetime_100ns - [long]$cimTicks
    $row = [ordered]@{ status = 'observed'; cim_creation_filetime_100ns = $cimTicks.ToString(); native_minus_cim_ticks = $difference.ToString();
        session_id = [int]$process.SessionId; parent_pid = [int]$process.ParentProcessId; parent = $null }
    if ($difference -lt 0 -or $difference -gt 9 -or $process.SessionId -ne $native.session_id) { $row.status = 'CIM-native-lifetime-mismatch'; return $row }
    $command = [string]$process.CommandLine
    if ($command.Length -gt 4096) { throw 'Target command metadata exceeds bound.' }
    $row.command_line_sha256 = Get-DrRuntimeBrokerBytesHash ([Text.Encoding]::UTF8.GetBytes($command))
    $row.command_line_length = $command.Length
    $canonicalImage = Join-Path (Join-Path $env:windir 'System32') 'RuntimeBroker.exe'
    $safeCommand = [string]::Equals($command, $canonicalImage + ' -Embedding', [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($command, '"' + $canonicalImage + '" -Embedding', [StringComparison]::OrdinalIgnoreCase)
    $row.command_line = if ($safeCommand) { $command } else { $null }
    # Only the fixed canonical command is emitted; other commands remain hash/length only.
    $row.command_line_redacted = $null -eq $row.command_line
    $row.image_evidence = Get-DrRuntimeBrokerImageEvidence ([string]$native.image_path) 'RuntimeBroker.exe'
    if ($process.ParentProcessId -eq 0) { $row.parent = [ordered]@{ association_status = 'no-parent-pid' }; return $row }
    $parent = $Backend.Session.OpenParent([uint32]$process.ParentProcessId)
    if ($null -eq $parent) { $row.parent = [ordered]@{ association_status = 'handle-cap' }; return $row }
    try {
        $identity = $parent.Life.Identity
        $parentRow = [ordered]@{ native_identity = $identity; association_status = 'unknown'; cim = $null; handle_closed = $false; close_win32_error = 0 }
        $row.parent = $parentRow
        if ($identity.open_error -ne 0 -or $null -eq $identity.creation_filetime_100ns) { $parentRow.association_status = 'capture-failed'; return $row }
        if ([long]$identity.creation_filetime_100ns -gt [long]$native.creation_filetime_100ns) { $parentRow.association_status = 'invalid-parent-newer-than-child'; return $row }
        $parents = @(Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ParentProcessId)" -OperationTimeoutSec 3 -ErrorAction Stop)
        if ($parents.Count -ne 1 -or $null -eq $parents[0].CreationDate) { $parentRow.association_status = 'CIM-parent-missing'; return $row }
        $parentCim = $parents[0]; $ticks = $parentCim.CreationDate.ToUniversalTime().ToFileTimeUtc()
        $delta = [long]$identity.creation_filetime_100ns - [long]$ticks
        $parentRow.cim = [ordered]@{ creation_filetime_100ns = $ticks.ToString(); native_minus_cim_ticks = $delta.ToString(); session_id = [int]$parentCim.SessionId; name = [string]$parentCim.Name }
        if ($delta -lt 0 -or $delta -gt 9 -or $parentCim.SessionId -ne $identity.session_id) { $parentRow.association_status = 'CIM-native-parent-mismatch'; return $row }
        $parentRow.association_status = 'creation-order-corroborated-not-causality'
        if ($parentCim.Name -cmatch '^[A-Za-z0-9._-]{1,128}\.exe$') {
            $parentRow.image_evidence = Get-DrRuntimeBrokerImageEvidence ([string]$identity.image_path) ([string]$parentCim.Name)
        }
        $parentRow.same_handle_wait = $parent.Life.Poll()
    } finally {
        $parent.Close()
        if ($null -ne $row.parent) { $row.parent.handle_closed = $parent.Closed; $row.parent.close_win32_error = $parent.Life.CloseError }
    }
    return $row
}

function Invoke-DrRuntimeBrokerObserverCore {
    param([string]$Root, [string]$RunId, [string]$RunnerSid, [int]$DurationSeconds, [hashtable]$Backend,
        [int]$MetadataLimit = 14MB, [int]$TerminalReserve = 256KB, [string]$ExpectedVmId = '')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $state = @{ bytes = 0; issues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); active = @{}; seen = @{};
        phases = @{}; phase_bytes = 0; records = 0; ready = $false; stop_reason = 'deadline'; cleanup = $null; failure_detail = $null }
    $events = $null
    function Write-ObserverRecord {
        param($Record, [bool]$Terminal = $false, [string]$Leaf = '')
        $json = $Record | ConvertTo-Json -Depth 16 -Compress
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
        $limit = if ($Terminal) { $MetadataLimit } else { $MetadataLimit - $TerminalReserve }
        if ($bytes.Length -gt 96KB -or $state.bytes + $bytes.Length -gt $limit) { throw 'Diagnostic metadata budget exceeded.' }
        if ($Leaf) {
            $path = Join-Path $Root $Leaf
            $file = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            try { $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() }
        } else { $events.Write($bytes, 0, $bytes.Length); $events.Flush(); $state.records++ }
        $state.bytes += $bytes.Length
    }
    function Drain-ObserverRecords {
        foreach ($record in @(& $Backend.Drain)) {
            $row = [ordered]@{ kind = $record.Kind; source = $record.Source; pid = $record.Pid;
                event_filetime_100ns = $record.EventTime; event_session_id = $record.EventSessionId; received_at_utc = $record.ReceivedUtc; discovered_elapsed_ms = $watch.ElapsedMilliseconds;
                identity_status = 'not-captured'; owner_scope = $record.OwnerScope; native_identity = $null; enrichment = $null;
                error_type = $record.ErrorType; error_hresult = $record.ErrorHResult; causal_attribution = 'unknown' }
            if ($null -ne $record.Lease) {
                $lease = $record.Lease; $identity = $lease.Life.Identity
                if ($record.OwnerScope -ceq 'foreign') {
                    $row.identity_status = 'foreign-owner-excluded'; $row.native_identity = [ordered]@{ pid = $identity.pid; creation_filetime_100ns = $identity.creation_filetime_100ns }
                } else { $row.native_identity = $identity; $row.identity_status = if ($record.OwnerScope -ceq 'runner') { 'native-identified' } else { 'partial-or-capture-failed' } }
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
                            try { $row.enrichment = & $Backend.Enrich $record $Backend }
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
        foreach ($pidValue in @(& $Backend.Snapshot)) {
            if ($watch.Elapsed.TotalSeconds -ge $DurationSeconds) { throw 'Initial snapshot capture exceeded deadline.' }
            & $Backend.Capture ([uint32]$pidValue)
        }
        Drain-ObserverRecords
        if ($watch.Elapsed.TotalSeconds -ge $DurationSeconds) { throw 'Readiness exceeded observation deadline.' }
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
    $result = [ordered]@{ schema_version = 1; run_id = $RunId; runner_sid = $RunnerSid; expected_vm_id = $ExpectedVmId; status = if ($state.issues.Count) { 'diagnostic-incomplete' } else { 'diagnostic-completed' };
        identity_status = 'per-lifetime-recorded-or-unknown'; exit_observation_status = 'per-held-handle-recorded-or-unknown';
        observation_coverage = if ($state.issues.Count) { 'incomplete-best-effort-not-lossless' } else { 'best-effort-not-lossless' }; causal_attribution = 'unknown'; ready_written = $state.ready;
        stop_reason = $state.stop_reason; observed_guest_utc = [DateTime]::UtcNow.ToString('o'); elapsed_ms = $watch.ElapsedMilliseconds;
        records = $state.records; diagnostic_metadata_bytes_before_result = $state.bytes; phase_input_bytes = $state.phase_bytes; issues = @($state.issues | Sort-Object); failure_detail = $state.failure_detail; cleanup = $state.cleanup;
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
    Initialize-DrRuntimeBrokerNative $Root
    $remainingSeconds = [int][Math]::Floor($DurationSeconds - $entryWatch.Elapsed.TotalSeconds)
    if ($remainingSeconds -le 0) { throw 'Diagnostic setup consumed observation deadline.' }
    $session = [DrRuntimeBrokerSession]::new($RunnerSid)
    $backend = @{
        Session = $session
        Start = { $session.Start() }.GetNewClosure()
        Ready = { $session.Started -and $session.ProviderFailures -eq 0 }.GetNewClosure()
        Snapshot = {
            $rows = @(Get-CimInstance Win32_Process -Filter "Name='RuntimeBroker.exe'" -OperationTimeoutSec 3 -ErrorAction Stop)
            if ($rows.Count -gt 4096) { throw 'Initial target snapshot bound exceeded.' }
            @($rows | ForEach-Object { [uint32]$_.ProcessId })
        }
        Capture = { param([uint32]$ProcessId) $session.Capture($ProcessId,$null,'initial-snapshot') }.GetNewClosure()
        Drain = { $session.Drain() }.GetNewClosure()
        Enrich = ${function:Get-DrRuntimeBrokerEnrichment}
        Delay = { Start-Sleep -Milliseconds 100 }
        Close = { $session.Close() }.GetNewClosure()
    }
    Invoke-DrRuntimeBrokerObserverCore -Root $Root -RunId $RunId -RunnerSid $RunnerSid -DurationSeconds $remainingSeconds -Backend $backend -ExpectedVmId $ExpectedVmId.ToString()
}
