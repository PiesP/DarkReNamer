# Synthetic two-directory KTM vote probe. Invoke this file with PowerShell 7.
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Voter')]
    [Guid]$FixtureId,
    [Parameter(Mandatory, ParameterSetName = 'Voter')]
    [Guid]$TransactionId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$native = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class Dark240Vote
{
    const uint QueryInformation = 0x0001;
    const uint Enlist = 0x0004;
    const uint PrePrepare = 0x0001;
    const uint Prepare = 0x0002;
    const uint Commit = 0x0004;
    const uint Rollback = 0x0008;
    const uint LastRecover = 0x2000;
    const uint VolatileTransactionManager = 0x0001;
    const uint VolatileResourceManager = 0x0001;
    const uint DoNotPromote = 0x0001;
    const uint FileShareAll = 0x0007;
    const uint OpenExisting = 3;
    const uint CreateNew = 1;
    const uint Read = 0x80000000;
    const uint Write = 0x40000000;
    const uint FileFlagBackupSemantics = 0x02000000;
    const uint FileFlagOpenReparsePoint = 0x00200000;
    const uint FileReadAttributes = 0x0080;
    const int FileIdInfo = 18;
    const int ErrorFileNotFound = 2;

    [StructLayout(LayoutKind.Sequential)]
    struct Notification
    {
        public IntPtr Key;
        public uint Mask;
        public long Clock;
        public uint ArgumentLength;
    }

    [DllImport("ktmw32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    static extern SafeFileHandle CreateTransaction(IntPtr security, IntPtr id, uint options,
        uint isolation, uint flags, uint timeout, string description);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern SafeFileHandle OpenTransaction(uint access, ref Guid id);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool GetTransactionId(SafeFileHandle transaction, out Guid id);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool GetTransactionInformation(SafeFileHandle transaction, out uint outcome,
        IntPtr isolation, IntPtr flags, IntPtr timeout, uint length, IntPtr description);
    [DllImport("ktmw32.dll", EntryPoint = "GetTransactionInformation", CharSet = CharSet.Unicode,
        ExactSpelling = true, SetLastError = true)]
    static extern bool GetTransactionDescription(SafeFileHandle transaction, IntPtr outcome,
        IntPtr isolation, IntPtr flags, IntPtr timeout, uint length, StringBuilder description);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool CommitTransactionAsync(SafeFileHandle transaction);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool RollbackTransactionAsync(SafeFileHandle transaction);
    [DllImport("ktmw32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    static extern SafeFileHandle CreateTransactionManager(IntPtr security, string log,
        uint options, uint commitStrength);
    [DllImport("ktmw32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    static extern SafeFileHandle CreateResourceManager(IntPtr security, ref Guid id,
        uint options, SafeFileHandle manager, string description);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool RecoverResourceManager(SafeFileHandle manager);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern SafeFileHandle CreateEnlistment(IntPtr security, SafeFileHandle manager,
        SafeFileHandle transaction, uint mask, uint options, IntPtr key);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool GetNotificationResourceManager(SafeFileHandle manager, IntPtr notification,
        uint capacity, uint milliseconds, out uint size);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool PrePrepareComplete(SafeFileHandle enlistment, ref long clock);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool PrepareComplete(SafeFileHandle enlistment, ref long clock);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool CommitComplete(SafeFileHandle enlistment, ref long clock);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool RollbackEnlistment(SafeFileHandle enlistment, ref long clock);
    [DllImport("ktmw32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool RollbackComplete(SafeFileHandle enlistment, ref long clock);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    static extern bool CreateDirectoryW(string path, IntPtr security);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    static extern SafeFileHandle CreateFileTransactedW(string path, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template,
        SafeFileHandle transaction, IntPtr version, IntPtr extra);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass,
        [Out] byte[] info, uint length);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle handle, [Out] byte[] bytes, uint count,
        out uint read, IntPtr overlapped);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle handle, byte[] bytes, uint count,
        out uint written, IntPtr overlapped);

    static void Check(bool success, string operation)
    {
        if (!success)
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
    }

    static SafeFileHandle Checked(SafeFileHandle handle, string operation)
    {
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, operation);
        }
        return handle;
    }

    public static void MakeDirectory(string path)
    {
        Check(CreateDirectoryW(path, IntPtr.Zero), "CreateDirectoryW");
    }

    public static string DirectoryId(string path)
    {
        using (var handle = Checked(CreateFileW(path, FileReadAttributes, FileShareAll, IntPtr.Zero,
            OpenExisting, FileFlagBackupSemantics | FileFlagOpenReparsePoint, IntPtr.Zero), "CreateFileW directory"))
        {
            var identity = new byte[24];
            Check(GetFileInformationByHandleEx(handle, FileIdInfo, identity, (uint)identity.Length),
                "GetFileInformationByHandleEx FileIdInfo");
            return Convert.ToHexString(identity);
        }
    }

    static string FixtureDescription(Guid fixture)
    {
        return "Dark240-" + fixture.ToString("N").Substring(0, 16);
    }

    public static SafeFileHandle Begin(Guid fixture)
    {
        return Checked(CreateTransaction(IntPtr.Zero, IntPtr.Zero, DoNotPromote, 0, 0, 45000,
            FixtureDescription(fixture)), "CreateTransaction");
    }

    public static Guid Id(SafeFileHandle transaction)
    {
        Guid id;
        Check(GetTransactionId(transaction, out id), "GetTransactionId");
        return id;
    }

    public static int RequestCommit(SafeFileHandle transaction)
    {
        return CommitTransactionAsync(transaction) ? 0 : Marshal.GetLastWin32Error();
    }

    public static int RequestRollback(SafeFileHandle transaction)
    {
        return RollbackTransactionAsync(transaction) ? 0 : Marshal.GetLastWin32Error();
    }

    public static string Outcome(SafeFileHandle transaction)
    {
        uint outcome;
        Check(GetTransactionInformation(transaction, out outcome, IntPtr.Zero, IntPtr.Zero,
            IntPtr.Zero, 0, IntPtr.Zero), "GetTransactionInformation");
        switch (outcome)
        {
            case 1: return "undetermined";
            case 2: return "committed";
            case 3: return "aborted";
            default: throw new IOException("Unknown KTM outcome: " + outcome);
        }
    }

    public static void WriteMarker(SafeFileHandle transaction, string path, string text)
    {
        using (var handle = Checked(CreateFileTransactedW(path, Write, FileShareAll, IntPtr.Zero,
            CreateNew, FileFlagOpenReparsePoint, IntPtr.Zero, transaction, IntPtr.Zero, IntPtr.Zero),
            "CreateFileTransactedW CREATE_NEW"))
        {
            byte[] bytes = Encoding.UTF8.GetBytes(text);
            uint written;
            Check(WriteFile(handle, bytes, (uint)bytes.Length, out written, IntPtr.Zero), "WriteFile");
            if (written != bytes.Length)
                throw new IOException("Incomplete synthetic marker write.");
        }
    }

    public static string MarkerState(SafeFileHandle transaction, string path, string text)
    {
        using (var handle = CreateFileTransactedW(path, Read, FileShareAll, IntPtr.Zero, OpenExisting,
            FileFlagOpenReparsePoint, IntPtr.Zero, transaction, IntPtr.Zero, IntPtr.Zero))
        {
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ErrorFileNotFound)
                    return "missing";
                throw new Win32Exception(error, "CreateFileTransactedW read");
            }
            byte[] bytes = new byte[128];
            uint read;
            Check(ReadFile(handle, bytes, (uint)bytes.Length, out read, IntPtr.Zero), "ReadFile");
            return read < bytes.Length && Encoding.UTF8.GetString(bytes, 0, (int)read) == text
                ? "matched" : "different";
        }
    }

    public sealed class Voter : IDisposable
    {
        readonly IntPtr notificationKey = new IntPtr(42);
        SafeFileHandle transaction, manager, resource, enlistment;
        public Voter(Guid id, Guid fixture)
        {
            try
            {
                transaction = Checked(OpenTransaction(QueryInformation | Enlist, ref id), "OpenTransaction");
                if (Id(transaction) != id)
                    throw new IOException("Opened a different transaction.");
                var description = new StringBuilder(64);
                Check(GetTransactionDescription(transaction, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    IntPtr.Zero, 64, description), "GetTransactionInformation description");
                if (description.ToString() != FixtureDescription(fixture))
                    throw new IOException("Transaction description did not match this synthetic fixture.");
                manager = Checked(CreateTransactionManager(IntPtr.Zero, null, VolatileTransactionManager, 0),
                    "CreateTransactionManager");
                Guid resourceId = Guid.NewGuid();
                resource = Checked(CreateResourceManager(IntPtr.Zero, ref resourceId, VolatileResourceManager,
                    manager, "DarkReNamer synthetic membership observer"), "CreateResourceManager");
                Check(RecoverResourceManager(resource), "RecoverResourceManager");
                enlistment = Checked(CreateEnlistment(IntPtr.Zero, resource, transaction,
                    PrePrepare | Prepare | Commit | Rollback, 0, notificationKey), "CreateEnlistment");
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        public string ObserveMarker(string path, string text)
        {
            return MarkerState(transaction, path, text);
        }

        public void Vote(bool accept, List<string> events, List<string> setupEvents)
        {
            int headerSize = Marshal.OffsetOf<Notification>(nameof(Notification.ArgumentLength)).ToInt32() + sizeof(uint);
            const uint capacity = 512;
            IntPtr buffer = Marshal.AllocHGlobal((int)capacity);
            var budget = Stopwatch.StartNew();
            bool prePrepared = false;
            bool prepared = false;
            try
            {
                for (int index = 0; index < 8; ++index)
                {
                    uint size;
                    int remaining = 33000 - (int)budget.ElapsedMilliseconds;
                    if (remaining <= 0)
                        throw new TimeoutException("KTM notification deadline passed.");
                    Check(GetNotificationResourceManager(resource, buffer, capacity,
                        (uint)remaining, out size), "GetNotificationResourceManager");
                    if (size < headerSize || size > capacity)
                        throw new IOException("Invalid KTM notification length: " + size);
                    var notification = Marshal.PtrToStructure<Notification>(buffer);
                    if (notification.ArgumentLength > size - headerSize)
                        throw new IOException("Invalid KTM notification argument length.");
                    if (notification.Mask == LastRecover)
                    {
                        if (setupEvents.Count != 0 || prePrepared || prepared)
                            throw new IOException("Unexpected resource manager recovery completion.");
                        setupEvents.Add("last_recover");
                        continue;
                    }
                    if (notification.Key != notificationKey)
                        throw new IOException("Unexpected KTM notification key.");
                    long clock = notification.Clock;
                    switch (notification.Mask)
                    {
                        case PrePrepare:
                            events.Add("preprepare");
                            if (prePrepared || prepared)
                                throw new IOException("Duplicate preprepare.");
                            Check(PrePrepareComplete(enlistment, ref clock), "PrePrepareComplete");
                            prePrepared = true;
                            break;
                        case Prepare:
                            events.Add("prepare");
                            if (!prePrepared || prepared)
                                throw new IOException("Prepare out of order.");
                            if (accept)
                            {
                                Check(PrepareComplete(enlistment, ref clock), "PrepareComplete");
                                events.Add("prepare_complete");
                            }
                            else
                            {
                                Check(RollbackEnlistment(enlistment, ref clock), "RollbackEnlistment");
                                events.Add("rollback_requested");
                            }
                            prepared = true;
                            break;
                        case Commit:
                            events.Add("commit");
                            Check(CommitComplete(enlistment, ref clock), "CommitComplete");
                            return;
                        case Rollback:
                            events.Add("rollback");
                            Check(RollbackComplete(enlistment, ref clock), "RollbackComplete");
                            return;
                        default:
                            throw new IOException("Unexpected KTM notification: " + notification.Mask);
                    }
                }
                throw new IOException("KTM did not produce a terminal notification.");
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public void Dispose()
        {
            if (enlistment != null) enlistment.Dispose();
            if (resource != null) resource.Dispose();
            if (manager != null) manager.Dispose();
            if (transaction != null) transaction.Dispose();
        }
    }
}
'@

if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7 -or -not [Environment]::Is64BitProcess) {
    throw 'PowerShell 7 on 64-bit Windows is required.'
}
Add-Type -TypeDefinition $native

$roles = 'left', 'right'
$markerName = 'member.txt'
$sentinelName = 'sentinel.txt'
$outsideName = 'outside.txt'
$stage = 'initializing'

function Require([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw $Label }
}

function Write-Record([System.Collections.IDictionary]$Record) {
    [Console]::WriteLine(($Record | ConvertTo-Json -Depth 8 -Compress))
}

function Get-RunPath([Guid]$Id) {
    Require ($Id -ne [Guid]::Empty) 'Empty fixture ID.'
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($temporary))
    Require ($drive.DriveType -eq 'Fixed' -and $drive.DriveFormat -eq 'NTFS') 'Fixed local NTFS required.'
    $part = [IO.DirectoryInfo]::new($temporary)
    while ($null -ne $part) {
        Require ($part.Exists -and -not $part.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'Unexpected temporary directory ancestor.'
        $part = $part.Parent
    }
    return [IO.Path]::Combine($temporary, ('dark240-vote-' + $Id.ToString('N')))
}

function Assert-OrdinaryDirectory([string]$Path) {
    $directory = [IO.DirectoryInfo]::new($Path)
    Require ($directory.Exists -and -not $directory.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'Unexpected fixture directory.'
}

function Get-Hash([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}

function Get-TextHash([string]$Text) {
    return Get-Hash ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Get-Text([string]$Name, [Guid]$Id) {
    return ('synthetic:{0}:{1}' -f $Name, $Id.ToString('N'))
}

function New-Text([string]$Path, [string]$Text) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        [byte[]]$bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Get-FixtureState([string]$Path, [bool]$Parent) {
    Assert-OrdinaryDirectory $Path
    $state = [ordered]@{ file_id = [Dark240Vote]::DirectoryId($Path); files = [ordered]@{}; directories = @() }
    foreach ($entry in [IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos()) {
        Require (-not $entry.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'Fixture reparse point.'
        if ($entry -is [IO.DirectoryInfo]) {
            Require ($Parent -and $entry.Name -cin $roles) 'Unexpected fixture subdirectory.'
            $state.directories += $entry.Name
            continue
        }
        $expectedNames = if ($Parent) { @($outsideName) } else { @($sentinelName, $markerName) }
        Require ($entry -is [IO.FileInfo] -and $entry.Name -cin $expectedNames -and $entry.Length -le 128) 'Unexpected fixture entry.'
        $state.files[$entry.Name] = Get-Hash ([IO.File]::ReadAllBytes($entry.FullName))
    }
    return $state
}

function Get-PairState([string]$Base) {
    return [ordered]@{
        parent = Get-FixtureState $Base $true
        left = Get-FixtureState (Join-Path $Base 'left') $false
        right = Get-FixtureState (Join-Path $Base 'right') $false
    }
}

function Assert-PairState([System.Collections.IDictionary]$State, [Guid]$Id, [bool]$MarkersPresent) {
    Require ($State.parent.directories.Count -eq 2 -and $State.parent.files.Count -eq 1 -and
        $State.parent.files[$outsideName] -ceq (Get-TextHash (Get-Text 'outside' $Id))) 'Outsider bytes or membership changed.'
    foreach ($role in $roles) {
        $files = $State[$role].files
        Require ($files[$sentinelName] -ceq (Get-TextHash (Get-Text "sentinel-$role" $Id))) 'Sentinel bytes changed.'
        if ($MarkersPresent) {
            Require ($files.Count -eq 2 -and
                $files[$markerName] -ceq (Get-TextHash (Get-Text "member-$role" $Id))) 'Committed marker or membership mismatch.'
        }
        else { Require ($files.Count -eq 1) 'Unexpected member outside committed full case.' }
    }
    Require ($State.left.file_id -cne $State.right.file_id) 'The two directories share an identity.'
}

function Invoke-Voter([Guid]$Id, [Guid]$Uow) {
    $script:stage = 'voter_precondition'
    $base = Get-RunPath $Id
    $before = Get-PairState $base
    Assert-PairState $before $Id $false
    $script:stage = 'voter_enlistment'
    $voter = [Dark240Vote+Voter]::new($Uow, $Id)
    $eventList = [Collections.Generic.List[string]]::new()
    $setupEvents = [Collections.Generic.List[string]]::new()
    try {
        $script:stage = 'voter_inspection'
        $members = [ordered]@{}
        foreach ($role in $roles) {
            $members[$role] = $voter.ObserveMarker((Join-Path (Join-Path $base $role) $markerName),
                (Get-Text "member-$role" $Id))
        }
        $accept = $members.left -ceq 'matched' -and $members.right -ceq 'matched'
        Write-Record ([ordered]@{
            record = 'ready'; pid = $PID; uow = $Uow; members = $members; baseline = $before; intend_accept = $accept
        })
        $script:stage = 'voter_notifications'
        try { $voter.Vote($accept, $eventList, $setupEvents) }
        catch {
            Write-Record ([ordered]@{ record = 'incomplete_vote'; events = $eventList.ToArray(); setup_events = $setupEvents.ToArray() })
            throw
        }
        Write-Record ([ordered]@{ record = 'vote'; pid = $PID; uow = $Uow; events = $eventList.ToArray(); setup_events = $setupEvents.ToArray() })
    }
    finally { $voter.Dispose() }
}

function Start-Voter([Guid]$Id, [Guid]$Uow) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [Environment]::ProcessPath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
        '-FixtureId', $Id.ToString('D'), '-TransactionId', $Uow.ToString('D'))) {
        $start.ArgumentList.Add($argument)
    }
    return [Diagnostics.Process]::Start($start)
}

function Wait-Outcome([Microsoft.Win32.SafeHandles.SafeFileHandle]$Transaction, [int]$Milliseconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $state = [Dark240Vote]::Outcome($Transaction)
        if ($state -ne 'undetermined') { return $state }
        Start-Sleep -Milliseconds 25
    } while ($timer.ElapsedMilliseconds -lt $Milliseconds)
    return $state
}

function Invoke-Case([bool]$IncludeBoth) {
    $mode = if ($IncludeBoth) { 'full' } else { 'omitted-right' }
    $id = [Guid]::NewGuid()
    $base = Get-RunPath $id
    $script:stage = "$mode.fixture_setup"
    [Dark240Vote]::MakeDirectory($base)
    Write-Record ([ordered]@{ record = 'fixture_created'; mode = $mode; fixture = $id; producer_pid = $PID })
    foreach ($role in $roles) {
        $path = Join-Path $base $role
        [Dark240Vote]::MakeDirectory($path)
        New-Text (Join-Path $path $sentinelName) (Get-Text "sentinel-$role" $id)
    }
    New-Text (Join-Path $base $outsideName) (Get-Text 'outside' $id)
    $before = Get-PairState $base
    Assert-PairState $before $id $false
    $script:stage = "$mode.transaction"
    $transaction = [Dark240Vote]::Begin($id)
    $child = $null
    $stderr = $null
    try {
        $uow = [Dark240Vote]::Id($transaction)
        [Dark240Vote]::WriteMarker($transaction, (Join-Path (Join-Path $base 'left') $markerName), (Get-Text 'member-left' $id))
        if ($IncludeBoth) {
            [Dark240Vote]::WriteMarker($transaction, (Join-Path (Join-Path $base 'right') $markerName), (Get-Text 'member-right' $id))
        }
        $script:stage = "$mode.wait_voter"
        $child = Start-Voter $id $uow
        $stderr = $child.StandardError.ReadToEndAsync()
        $readyLine = $child.StandardOutput.ReadLineAsync()
        Require ($readyLine.Wait(12000)) 'Voter readiness deadline passed.'
        Require (-not [string]::IsNullOrEmpty($readyLine.Result)) 'Voter returned no readiness record.'
        $tail = $child.StandardOutput.ReadToEndAsync()
        Write-Record ([ordered]@{ record = 'voter_readiness'; mode = $mode; stdout = $readyLine.Result })
        $ready = $readyLine.Result | ConvertFrom-Json -AsHashtable
        Require ($ready.record -ceq 'ready' -and $ready.pid -eq $child.Id -and $ready.pid -ne $PID -and
            [Guid]$ready.uow -eq $uow) 'Invalid voter readiness.'
        foreach ($role in @('parent') + $roles) {
            Require ($ready.baseline[$role].file_id -ceq $before[$role].file_id) 'Voter observed a different directory identity.'
        }
        $expectedRight = if ($IncludeBoth) { 'matched' } else { 'missing' }
        Require ($ready.members.left -ceq 'matched' -and $ready.members.right -ceq $expectedRight -and
            $ready.intend_accept -eq $IncludeBoth) 'Voter marker observations did not match the frozen case.'
        Require ([Dark240Vote]::Outcome($transaction) -ceq 'undetermined') 'The transaction already settled before the vote.'
        $script:stage = "$mode.commit_and_vote"
        $commitError = [Dark240Vote]::RequestCommit($transaction)
        Write-Record ([ordered]@{ record = 'commit_requested'; mode = $mode; uow = $uow; win32 = $commitError })
        if ($IncludeBoth) { Require ($commitError -eq 0) 'Full case commit request was rejected.' }
        Require ($child.WaitForExit(35000)) 'The voter failed to exit before its deadline.'
        Require ($tail.Wait(1000) -and $stderr.Wait(1000)) 'Voter output pipes remained open.'
        $outcome = Wait-Outcome $transaction 3000
        Write-Record ([ordered]@{
            record = 'voter_result'; mode = $mode; exit_code = $child.ExitCode
            stdout = $tail.Result; stderr = $stderr.Result; outcome = $outcome
        })
        Require ($child.ExitCode -eq 0 -and $stderr.Result.Length -eq 0) 'Independent voter failed.'
        $vote = $tail.Result.Trim() | ConvertFrom-Json -AsHashtable
        Require ($vote.record -ceq 'vote' -and [Guid]$vote.uow -eq $uow -and $vote.pid -eq $child.Id) 'Invalid terminal vote.'
        $expectedOutcome = if ($IncludeBoth) { 'committed' } else { 'aborted' }
        $expectedEvents = if ($IncludeBoth) { 'preprepare,prepare,prepare_complete,commit' }
            else { 'preprepare,prepare,rollback_requested,rollback' }
        Require ($outcome -ceq $expectedOutcome -and ($vote.events -join ',') -ceq $expectedEvents) 'Unexpected vote or KTM outcome.'
        $script:stage = "$mode.after_state"
        $after = Get-PairState $base
        Assert-PairState $after $id $IncludeBoth
        foreach ($role in @('parent') + $roles) {
            Require ($after[$role].file_id -ceq $before[$role].file_id) 'Settlement changed a directory identity.'
        }
        Write-Record ([ordered]@{ record = 'verified_after'; mode = $mode; baseline = $before; after = $after })
    }
    catch {
        $failure = $_
        try {
            if ([Dark240Vote]::Outcome($transaction) -ceq 'undetermined') {
                $rollbackError = [Dark240Vote]::RequestRollback($transaction)
                Write-Record ([ordered]@{ record = 'emergency_rollback_requested'; mode = $mode; win32 = $rollbackError })
            }
        }
        catch {
            Write-Record ([ordered]@{ record = 'emergency_rollback_error'; mode = $mode; error = $_.Exception.Message })
        }
        throw $failure
    }
    finally {
        if ($null -ne $child) {
            try {
                if (-not $child.HasExited) {
                    $child.Kill($true)
                    Require ($child.WaitForExit(3000)) 'Could not confirm terminal voter process.'
                }
                if ($child.ExitCode -ne 0 -and $null -ne $stderr -and $stderr.Wait(1000)) {
                    Write-Record ([ordered]@{ record = 'voter_stderr'; mode = $mode; stderr = $stderr.Result })
                }
            }
            finally { $child.Dispose(); $transaction.Dispose() }
        }
        else { $transaction.Dispose() }
    }
    $script:stage = "$mode.fixture_cleanup"
    $live = Get-PairState $base
    Assert-PairState $live $id $IncludeBoth
    foreach ($role in @('parent') + $roles) {
        Require ($live[$role].file_id -ceq $before[$role].file_id) 'Cleanup rejected a different directory identity.'
    }
    foreach ($role in $roles) {
        $path = Join-Path $base $role
        if ($IncludeBoth) { [IO.File]::Delete((Join-Path $path $markerName)) }
        [IO.File]::Delete((Join-Path $path $sentinelName))
        [IO.Directory]::Delete($path, $false)
    }
    [IO.File]::Delete((Join-Path $base $outsideName))
    [IO.Directory]::Delete($base, $false)
    Write-Record ([ordered]@{ record = 'fixture_cleaned'; mode = $mode; fixture = $id })
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'Voter') {
        Invoke-Voter $FixtureId $TransactionId
    }
    else {
        Require (-not [string]::IsNullOrEmpty($PSCommandPath)) 'Invoke an actual script file using pwsh -File.'
        Write-Record ([ordered]@{
            record = 'run'; kind = 'synthetic-ktm-vote'; pid = $PID; os = [Environment]::OSVersion.VersionString
            source_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
            powershell = $PSVersionTable.PSVersion.ToString()
        })
        Invoke-Case $true
        Invoke-Case $false
        Write-Record ([ordered]@{ record = 'pass'; cases = 2 })
    }
}
catch {
    $exception = $_.Exception
    $nativeCode = $null
    while ($null -ne $exception) {
        if ($exception -is [ComponentModel.Win32Exception]) { $nativeCode = $exception.NativeErrorCode; break }
        $exception = $exception.InnerException
    }
    Write-Record ([ordered]@{ record = 'failed'; stage = $stage; win32 = $nativeCode; error = $_.Exception.Message })
    exit 1
}
