[CmdletBinding()]
param(
    [ValidateSet('controller','candidate','actor')][string]$Mode='controller',
    [string]$Scope
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Active-Acquire child control requires Windows.' }
$ownedDeadline=$null
if ($Mode -ne 'controller') {
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
public sealed class DarkAcquireChildDeadline : IDisposable {
    readonly Timer timer;
    public DarkAcquireChildDeadline(int milliseconds) {
        if (milliseconds<1 || milliseconds>30000)
            throw new ArgumentOutOfRangeException(nameof(milliseconds));
        timer=new Timer(_ => {
            Console.Error.WriteLine("DR_ACQUIRE_CHILD_OWNED_DEADLINE");
            Environment.Exit(124);
        },null,milliseconds,Timeout.Infinite);
    }
    public void Dispose() { timer.Dispose(); }
}
'@ -ErrorAction Stop
    $ownedDeadline=[DarkAcquireChildDeadline]::new(30000)
}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$modulePath=Join-Path $repo 'scripts/modules/powershell/controller-owned-root-guard.ps1'
$observerPath=Join-Path $repo 'scripts/tests/support/exact-manifest-phase-b-observer.cs'
$actorPath=Join-Path $repo 'scripts/tests/support/exact-manifest-phase-b-actors.cs'
$phaseBPath=Join-Path $PSScriptRoot 'test-exact-manifest-txf-phase-b.ps1'

# Reuse the maintained fixture, marker, and owned-child primitives without invoking B/C.
$sharedNames=@('Hash-Text','Write-NewText','Write-Marker','Read-Marker',
    'Test-MarkerReady','Wait-Marker','Wait-ActorBarrier','Read-KnownBytes',
    'Assert-PrivateDirectory','New-PrivateScope','Complete-OwnedChild')
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($phaseBPath,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Maintained Phase B helpers cannot be parsed.' }
foreach ($name in $sharedNames) {
    $definition=$ast.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $name},$true)
    if ($null -eq $definition) { throw "Maintained fixture helper is missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-AcquireChildReceipt($Candidate,$Actor,$Barrier,$Ready,
    $AttemptMarker,$DoneMarker,$ExpectedSource) {
    foreach ($receipt in @($Candidate,$Actor)) {
        if ($null -eq $receipt -or $receipt.schema -cne 'dark240-acquire-child-v1' -or
            $receipt.gate1 -cne 'unverified' -or $receipt.target_collection -ne 0 -or
            $receipt.product -ne 0 -or $receipt.owned_deadline_ms -ne 30000) {
            throw 'Control receipt scope differs.'
        }
        foreach ($field in @('commit','control_sha256','module_sha256',
                'observer_sha256','actor_sha256','phase_b_sha256','registry_sha256')) {
            if ($receipt.source[$field] -cne $ExpectedSource[$field]) {
                throw "Control receipt source binding differs: $field"
            }
        }
    }
    if ($Candidate.role -cne 'candidate' -or $Actor.role -cne 'actor' -or
        $Ready.phase -cne 'independent-freeze' -or $Ready.row_count -ne 2 -or
        [string]::IsNullOrEmpty($Ready.issued_utc) -or
        [string]::IsNullOrEmpty($Barrier.issued_utc) -or
        [string]::IsNullOrEmpty($Actor.attempt_utc) -or
        [string]::IsNullOrEmpty($Candidate.done_utc) -or
        [string]::IsNullOrEmpty($Actor.postproof.observed_utc) -or
        [string]::CompareOrdinal($Ready.issued_utc,$Barrier.issued_utc) -gt 0 -or
        [string]::CompareOrdinal($Barrier.issued_utc,$Actor.attempt_utc) -gt 0 -or
        [string]::CompareOrdinal($Actor.attempt_utc,$Candidate.done_utc) -gt 0 -or
        [string]::CompareOrdinal($Candidate.done_utc,$Actor.postproof.observed_utc) -gt 0 -or
        $Ready.manifest_digest -cne $Barrier.digest -or
        $Ready.stream_checks.Count -ne 2 -or
        $Actor.postproof.stream_checks.Count -ne 3 -or
        @(@($Ready.stream_checks) + @($Actor.postproof.stream_checks) |
            Where-Object { $_.result -ne 0 -or $_.io_status -ne 0 -or
                $_.information -lt 0 -or $_.information -gt 1048576 -or
                $_.named_streams -ne 0 }).Count -ne 0 -or
        $Barrier.phase -cne 'active-acquire-before-stage' -or
        $Barrier.lease_state -cne 'acquired' -or
        $Barrier.settlement -cne 'active-exact-set' -or
        $Barrier.held_count -ne 2 -or $Barrier.stage_calls -ne 0 -or
        $Barrier.commit_calls -ne 0 -or $Candidate.acquire_digest -cne $Barrier.digest -or
        $Candidate.barrier_phase -cne $Barrier.phase -or
        $Candidate.settlement -cne 'rollback-succeeded' -or
        $Candidate.lease_state -cne 'rollback-succeeded' -or
        $Candidate.rollback_calls -ne 1 -or $Candidate.commit_calls -ne 0 -or
        $Candidate.stage_calls -ne 0 -or $Candidate.closure_unknown -or
        -not $Candidate.target_handles_closed -or -not $Candidate.is_closed -or
        $Candidate.cleanup_error -or $Candidate.native_error -ne 0 -or
        $Candidate.close_receipts.Count -lt 5 -or
        $DoneMarker.status -cne $Candidate.status -or
        $DoneMarker.issued_utc -cne $Candidate.done_utc -or
        $DoneMarker.settlement -cne $Candidate.settlement -or
        $DoneMarker.rollback_calls -ne $Candidate.rollback_calls -or
        $DoneMarker.stage_calls -ne $Candidate.stage_calls -or
        $DoneMarker.commit_calls -ne $Candidate.commit_calls -or
        $DoneMarker.closure_unknown -ne $Candidate.closure_unknown -or
        $DoneMarker.target_handles_closed -ne $Candidate.target_handles_closed -or
        $DoneMarker.is_closed -ne $Candidate.is_closed -or
        -not $DoneMarker.transaction_closed -or
        @($Candidate.close_receipts | Where-Object { $_ -cnotmatch ':closed$' }).Count -ne 0) {
        throw 'Control lacks active lease barrier or settled zero-stage rollback.'
    }
    foreach ($requiredClose in @('writer:0:closed','anchor:0:closed',
            'writer:1:closed','anchor:1:closed','transaction:closed')) {
        if (@($Candidate.close_receipts | Where-Object { $_ -ceq $requiredClose }).Count -ne 1) {
            throw "Control lacks a unique confirmed closure: $requiredClose"
        }
    }
    if ($Ready.stream_checks[0].file_id -cne $Ready.root_id -or
        $Ready.stream_checks[1].file_id -cne $Ready.approved_id -or
        $Actor.postproof.stream_checks[0].file_id -cne $Actor.postproof.root_id -or
        $Actor.postproof.stream_checks[1].file_id -cne $Actor.postproof.approved_id) {
        throw 'Independent stream query was not bound to the frozen original identities.'
    }
    $rootFields=$Ready.root_row.Split('|')
    $approvedFields=$Ready.approved_row.Split('|')
    $approvedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [byte[]](9,18,27,36,45,54))).ToLowerInvariant()
    $sentinelHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [byte[]](72,63,54,45,36,27))).ToLowerInvariant()
    if ($rootFields.Count -ne 8 -or $rootFields[0] -cne '.' -or
        $rootFields[1] -cne 'directory' -or
        $rootFields[2] -cne $Ready.root_id -or
        $Ready.root_id -cnotmatch '^[0-9a-f]{48}$' -or
        $rootFields[3] -cne '-' -or $rootFields[4] -cne '-' -or
        $rootFields[7] -cne 'default-stream-only' -or
        $approvedFields.Count -ne 8 -or
        $approvedFields[0] -cne '61007000700072006f007600650064002e00620069006e00' -or
        $approvedFields[1] -cne 'file' -or
        $approvedFields[2] -cne $Ready.approved_id -or
        $Ready.approved_id -cnotmatch '^[0-9a-f]{48}$' -or
        $approvedFields[3] -cne '6' -or $approvedFields[4] -cne $approvedHash -or
        $approvedFields[7] -cne 'default-stream-only' -or
        $Ready.sentinel_sha256 -cne $sentinelHash) {
        throw 'Control frozen original bytes or stream row differs.'
    }
    $attempt=$Actor.attempt
    if ($null -eq $attempt -or $Actor.attempt_phase -cne 'child-create-during-active-acquire' -or
        $AttemptMarker.admitted -ne $attempt.admitted -or
        $AttemptMarker.native_error -ne $attempt.native_error -or
        $AttemptMarker.written -ne $attempt.written -or
        $AttemptMarker.attempt_utc -cne $Actor.attempt_utc -or
        $Actor.barrier_digest -cne $Barrier.digest -or
        $Actor.postproof.root_id -cne $Ready.root_id -or
        $Actor.postproof.root_row -cne $Ready.root_row -or
        $Actor.postproof.approved_id -cne $Ready.approved_id -or
        $Actor.postproof.approved_row -cne $Ready.approved_row -or
        $Actor.postproof.sentinel_sha256 -cne $Ready.sentinel_sha256 -or
        $Actor.postproof.sentinel_bytes -cne
            [Convert]::ToBase64String([byte[]](72,63,54,45,36,27)) -or
        $Actor.postproof.child_bytes -cne [Convert]::ToBase64String([byte[]](81)) -or
        $Actor.postproof.child_sha256 -cne ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([byte[]](81))).ToLowerInvariant()) -or
        $Actor.postproof.row_count -ne 3) {
        throw 'Control independent original, stream, or child postproof differs.'
    }
    $childFields=$Actor.postproof.child_row.Split('|')
    if ($childFields.Count -ne 8 -or
        $childFields[0] -cne '6c006100740065002d006300680069006c0064002e00620069006e00' -or
        $childFields[1] -cne 'file' -or $childFields[2] -cnotmatch '^[0-9a-f]{48}$' -or
        $childFields[3] -cne '1' -or
        $childFields[4] -cne $Actor.postproof.child_sha256 -or
        $childFields[7] -cne 'default-stream-only') {
        throw 'Control child identity, bytes, or stream row differs.'
    }
    if ($Actor.postproof.stream_checks[2].file_id -cne $childFields[2]) {
        throw 'Independent child stream query changed object identity.'
    }
    foreach ($encodedSecurity in @($rootFields[5],$rootFields[6],
            $approvedFields[5],$approvedFields[6],$childFields[5],$childFields[6])) {
        try { $decoded=[Convert]::FromBase64String($encodedSecurity) }
        catch { throw 'Control security row is not valid Base64.' }
        if ($decoded.Length -lt 2 -or ($decoded.Length % 2) -ne 0) {
            throw 'Control security row is not UTF-16 data.'
        }
    }
    if ($attempt.admitted) {
        if ($attempt.native_error -ne 0 -or -not $attempt.written -or
            $Candidate.status -cne 'admitted-stage-rejected-postproof-pending' -or
            -not $Candidate.stage_attempted -or -not $Candidate.stage_rejected -or
            $Candidate.stage_error -cne 'exact-manifest-mismatch' -or
            $Actor.support_attempted -or $null -ne $Actor.support) {
            throw 'Admitted child lacked pre-disposition Stage rejection and preservation.'
        }
        return 'admitted-stage-rejected-gate1-unverified'
    }
    if ($attempt.native_error -notin @(32,6800) -or $attempt.written -or
        $Candidate.status -cne 'refused-intentional-abort-postproof-pending' -or
        $Candidate.stage_attempted -or $Candidate.stage_rejected -or
        $Candidate.stage_error -or
        -not $Actor.support_attempted -or -not $Actor.support.admitted -or
        $Actor.support.native_error -ne 0 -or -not $Actor.support.written) {
        throw 'Refused child lacked supported native status, abort, or same-path support.'
    }
    return 'refused-during-active-acquire-gate1-unverified'
}

$sourceSha=(git -C $repo rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceSha -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Control source SHA is unavailable.'
}
$dirty=@(git -C $repo status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Control requires a clean exact-source checkout.'
}
$registryPath=Join-Path $repo 'config/tooling-tests.json'
$source=[ordered]@{commit=$sourceSha;
    control_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
    module_sha256=(Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant();
    observer_sha256=(Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash.ToLowerInvariant();
    actor_sha256=(Get-FileHash -LiteralPath $actorPath -Algorithm SHA256).Hash.ToLowerInvariant();
    phase_b_sha256=(Get-FileHash -LiteralPath $phaseBPath -Algorithm SHA256).Hash.ToLowerInvariant();
    registry_sha256=(Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()}
$profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
$base=Join-Path (Join-Path $profile 'AppData/Local/Temp') 'Dark180-TxfPhaseB'

function Assert-ControlPathChain([string]$Path) {
    for ($item=[IO.DirectoryInfo]::new($Path);$null -ne $item;$item=$item.Parent) {
        if (-not $item.Exists -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Control fixture ancestry is absent or reparse.'
        }
    }
}
function Assert-ControlScope {
    if ($env:DARK_PHASE_B_BATCH_GUID -or $Scope -cnotmatch '[0-9a-f]{32}$' -or
        $env:DARK_PHASE_B_NONCE -cnotmatch '^[0-9a-f]{32}$' -or
        [IO.Path]::GetFileName($Scope) -cne $env:DARK_PHASE_B_NONCE -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($Scope),$base,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Control child lacks an exact private fixture scope.'
    }
    Assert-ControlPathChain $Scope
    Assert-PrivateDirectory $base
    Assert-PrivateDirectory $Scope
}
function Write-ControlRecord([string]$Role,$Fields) {
    $Fields.schema='dark240-acquire-child-v1';$Fields.role=$Role
    $Fields.source=$source;$Fields.gate1='unverified'
    $Fields.target_collection=0;$Fields.product=0;$Fields.owned_deadline_ms=30000
    [Console]::Out.WriteLine('DR_ACQUIRE_CHILD ' +
        ($Fields | ConvertTo-Json -Depth 10 -Compress))
}

if ($Mode -ne 'controller') {
    try {
    Assert-ControlScope
    $target=Join-Path $Scope 'target'
    if ($Mode -eq 'actor') {
        Add-Type -Path $observerPath -ErrorAction Stop
        Add-Type -Path $actorPath -ErrorAction Stop
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
// Independent of the Phase-B observer's legacy BOOL/EOF directory-stream path.
public static class DarkAcquireChildStrictStreams {
    [StructLayout(LayoutKind.Sequential)] struct IoStatusBlock {
        public IntPtr Status, Information;
    }
    [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode,
        ExactSpelling=true, SetLastError=true)]
    static extern SafeFileHandle Open(string path,uint access,uint share,
        IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationFile(SafeFileHandle file,
        out IoStatusBlock status,byte[] data,uint size,int informationClass);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file,int kind,
        byte[] data,uint size);
    public sealed class Result {
        public int ResultStatus {get;set;}
        public long IoStatus {get;set;}
        public long Information {get;set;}
        public int NamedStreams {get;set;}
        public string FileId {get;set;}
    }
    public static Result Check(string path,bool directory) {
        using (SafeFileHandle file=Open(path,1|0x80|0x20000,7,IntPtr.Zero,3,
            0x00200000|(directory ? 0x02000000u : 0u),IntPtr.Zero)) {
            if (file==null || file.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Active-Acquire independent stream open failed.");
            byte[] id=new byte[24];
            if (!GetFileInformationByHandleEx(file,18,id,(uint)id.Length))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Active-Acquire independent FileID query failed.");
            string fileId=BitConverter.ToString(id).Replace("-","").ToLowerInvariant();
            int capacity=4096;
            while (capacity<=1048576) {
                byte[] bytes=new byte[capacity];IoStatusBlock status;
                int result=NtQueryInformationFile(file,out status,bytes,(uint)capacity,22);
                if (result==unchecked((int)0x80000005) ||
                    result==unchecked((int)0xc0000023)) { capacity*=2;continue; }
                long io=status.Status.ToInt64(),length=status.Information.ToInt64();
                if (result!=0 || unchecked((uint)io)!=0 || length<0 ||
                    length>capacity || (!directory && length==0))
                    throw new InvalidOperationException(
                        "Active-Acquire independent NT stream outcome is incomplete.");
                int offset=0,count=0;
                while (offset<length) {
                    if (offset>length-24 || ++count>20000)
                        throw new InvalidOperationException("Independent stream frame is short.");
                    uint next=BitConverter.ToUInt32(bytes,offset);
                    uint nameBytes=BitConverter.ToUInt32(bytes,offset+4);
                    if ((nameBytes&1)!=0 || nameBytes>length-offset-24 ||
                        (next!=0 && ((next&7)!=0 || next<24+nameBytes || next>length-offset)))
                        throw new InvalidOperationException("Independent stream frame is invalid.");
                    string name=Encoding.Unicode.GetString(bytes,offset+24,(int)nameBytes);
                    bool allowed=directory ?
                        String.Equals(name,"::$INDEX_ALLOCATION",StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name,":$I30:$INDEX_ALLOCATION",StringComparison.OrdinalIgnoreCase) :
                        name.Length==0 || String.Equals(name,"::$DATA",StringComparison.OrdinalIgnoreCase);
                    if (!allowed) throw new InvalidOperationException("Independent named stream exists.");
                    if (next==0) {
                        if (length-offset-24-nameBytes>7)
                            throw new InvalidOperationException("Independent stream query has trailing bytes.");
                        break;
                    }
                    offset+=(int)next;
                }
                return new Result {ResultStatus=result,IoStatus=io,Information=length,
                    NamedStreams=0,FileId=fileId};
            }
            throw new InvalidOperationException("Independent stream query exceeded one MiB.");
        }
    }
}
'@ -ErrorAction Stop
        if ([IO.Directory]::Exists($target) -or [IO.File]::Exists($target)) {
            throw 'Control fixture target already exists.'
        }
        [void][IO.Directory]::CreateDirectory($target)
        Assert-ControlPathChain $target
        [IO.File]::WriteAllBytes((Join-Path $target 'approved.bin'),[byte[]](9,18,27,36,45,54))
        [IO.File]::WriteAllBytes((Join-Path $Scope 'sentinel.bin'),[byte[]](72,63,54,45,36,27))
        $rows=[DarkPhaseBFixtureObserver]::Freeze($target)
        if ($rows.Count -ne 2) { throw 'Control fixture is not the two-entry exact set.' }
        $beforeStreams=@(
            [DarkAcquireChildStrictStreams]::Check($target,$true),
            [DarkAcquireChildStrictStreams]::Check((Join-Path $target 'approved.bin'),$false)) |
            ForEach-Object { [ordered]@{result=$_.ResultStatus;io_status=$_.IoStatus;
                information=$_.Information;named_streams=$_.NamedStreams;
                file_id=$_.FileId} }
        $digest=[DarkPhaseBFixtureObserver]::DigestRows($rows)
        $fields=@($sourceSha,(Hash-Text $env:DARK_PHASE_B_NONCE),$Scope,$target,
            $rows[0].Split('|')[2],$digest)
        Write-NewText (Join-Path $Scope 'approved-manifest.txt') (($rows -join "`n") + "`n")
        Write-NewText (Join-Path $Scope 'authority.txt') (($fields -join "`n") + "`n")
        Write-NewText (Join-Path $Scope 'predelete.txt') (($fields -join "`n") + "`n")
        $cap=[DarkPhaseBFixtureActors]::PrepareLateChild($Scope,$target)
        $sentinelSha=(Get-FileHash -LiteralPath (Join-Path $Scope 'sentinel.bin') -Algorithm SHA256).Hash.ToLowerInvariant()
        $ready=[ordered]@{phase='independent-freeze';issued_utc=[DateTime]::UtcNow.ToString('o');
            row_count=2;manifest_digest=$digest;
            root_id=$rows[0].Split('|')[2];root_row=$rows[0];
            approved_id=$rows[1].Split('|')[2];
            approved_row=$rows[1];sentinel_sha256=$sentinelSha;
            stream_checks=@($beforeStreams)}
        Write-Marker (Join-Path $Scope 'actor-ready.json') $ready
        if (-not (Wait-ActorBarrier (Join-Path $Scope 'candidate-barrier.json') 12000)) {
            throw 'Control actor was cancelled before the active-Acquire barrier.'
        }
        $barrier=Read-Marker (Join-Path $Scope 'candidate-barrier.json')
        if ($barrier.phase -cne 'active-acquire-before-stage' -or
            $barrier.held_count -ne 2 -or $barrier.digest -cne $digest) {
            throw 'Control actor received a non-active or mismatched barrier.'
        }
        $attempt=$cap.Attempt()
        $attemptUtc=[DateTime]::UtcNow.ToString('o')
        $attemptRow=[ordered]@{admitted=$attempt.Admitted;native_error=$attempt.NativeError;
            written=$attempt.ByteWritten;attempt_utc=$attemptUtc}
        Write-Marker (Join-Path $Scope 'actor-done.json') $attemptRow
        $done=Wait-Marker (Join-Path $Scope 'candidate-done.json') 12000
        $expectedStatus=if ($attempt.Admitted) {'admitted-stage-rejected-postproof-pending'}
            else {'refused-intentional-abort-postproof-pending'}
        if ($done.status -cne $expectedStatus -or
            $done.settlement -cne 'rollback-succeeded' -or
            $done.rollback_calls -ne 1 -or $done.stage_calls -ne 0 -or
            $done.commit_calls -ne 0 -or $done.closure_unknown -or
            -not $done.target_handles_closed -or -not $done.transaction_closed -or
            -not $done.is_closed) {
            throw 'Control actor refuses after-release work without confirmed settlement.'
        }
        $supportAttempted=$false;$support=$null
        if (-not $attempt.Admitted) {
            $supportAttempted=$true
            $again=$cap.Attempt()
            $support=[ordered]@{admitted=$again.Admitted;native_error=$again.NativeError;
                written=$again.ByteWritten}
        }
        $after=[DarkPhaseBFixtureObserver]::Freeze($target)
        $child=Read-KnownBytes (Join-Path $target 'late-child.bin') $false
        $sentinelAfter=Read-KnownBytes (Join-Path $Scope 'sentinel.bin') $false
        $afterStreams=@(
            [DarkAcquireChildStrictStreams]::Check($target,$true),
            [DarkAcquireChildStrictStreams]::Check((Join-Path $target 'approved.bin'),$false),
            [DarkAcquireChildStrictStreams]::Check((Join-Path $target 'late-child.bin'),$false)) |
            ForEach-Object { [ordered]@{result=$_.ResultStatus;io_status=$_.IoStatus;
                information=$_.Information;named_streams=$_.NamedStreams;
                file_id=$_.FileId} }
        $post=[ordered]@{observed_utc=[DateTime]::UtcNow.ToString('o');
            row_count=$after.Count;root_id=$after[0].Split('|')[2];
            root_row=$after[0];
            approved_id=$after[1].Split('|')[2];approved_row=$after[1];
            child_row=$after[2];child_bytes=$child.base64;child_sha256=$child.sha256;
            sentinel_sha256=$sentinelAfter.sha256;sentinel_bytes=$sentinelAfter.base64;
            stream_checks=@($afterStreams)}
        Write-ControlRecord 'actor' ([ordered]@{attempt_phase='child-create-during-active-acquire';
            attempt_utc=$attemptUtc;
            barrier_digest=$barrier.digest;attempt=$attemptRow;support_attempted=$supportAttempted;
            support=$support;postproof=$post})
    } else {
        $null=Wait-Marker (Join-Path $Scope 'actor-ready.json') 12000
        . $modulePath
        Add-Type -TypeDefinition $script:DrOwnedRootGuardSource -ErrorAction Stop
        $lease=$null;$cleanupError=$null;$stageAttempted=$false;$stageRejected=$false
        $stageError=$null
        $status='unknown';$digest=$null;$barrier=$null
        try {
            $lease=[DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease]::PrepareFixtureOnly(
                $Scope,$target,$env:DARK_PHASE_B_NONCE,$sourceSha)
            $digest=$lease.AcquireExactSet()
            if ($lease.LeaseState -cne 'acquired' -or
                $lease.Settlement -cne 'active-exact-set' -or
                $lease.HeldEntryCount -ne 2 -or $lease.StageCalls -ne 0 -or
                $lease.CommitCalls -ne 0) { throw 'Control did not acquire two active entries.' }
            $barrier=[ordered]@{phase='active-acquire-before-stage';
                issued_utc=[DateTime]::UtcNow.ToString('o');digest=$digest;
                lease_state=$lease.LeaseState;settlement=$lease.Settlement;
                held_count=$lease.HeldEntryCount;stage_calls=$lease.StageCalls;
                commit_calls=$lease.CommitCalls}
            Write-Marker (Join-Path $Scope 'candidate-barrier.json') $barrier
            $attempt=Wait-Marker (Join-Path $Scope 'actor-done.json') 10000
            if ($attempt.admitted) {
                if ($attempt.native_error -ne 0 -or -not $attempt.written) {
                    throw 'Admitted child did not complete its known-byte write.'
                }
                $stageAttempted=$true
                try { $lease.StageExactSet((Join-Path $Scope 'predelete.txt')) }
                catch {
                    $cause=$_.Exception
                    for ($depth=0;$depth -lt 3 -and
                            $cause -is [Management.Automation.MethodInvocationException];$depth++) {
                        $cause=$cause.InnerException
                    }
                    if ($null -eq $cause -or
                        $cause.GetType().FullName -cne 'System.InvalidOperationException' -or
                        $cause.Message -cne
                            'Phase B approved manifest is absent, oversized or incomplete.') { throw }
                    $stageRejected=$true
                    $stageError='exact-manifest-mismatch'
                }
                if (-not $stageRejected -or $lease.StageCalls -ne 0) {
                    throw 'Stage accepted an unapproved child or attempted a disposition.'
                }
                $status='admitted-stage-rejected-postproof-pending'
            } else {
                if ($attempt.native_error -notin @(32,6800) -or $attempt.written) {
                    throw 'Child refusal has an unsupported native status.'
                }
                if (-not $lease.Abort()) { throw 'Intentional rollback is unknown.' }
                $status='refused-intentional-abort-postproof-pending'
            }
        } finally {
            if ($null -ne $lease) {
                try { $lease.Dispose() }
                catch { $cleanupError=$_.Exception.GetType().FullName }
            }
        }
        $doneUtc=[DateTime]::UtcNow.ToString('o')
        $record=[ordered]@{status=$status;done_utc=$doneUtc;acquire_digest=$digest;
            barrier_phase=$barrier.phase;stage_attempted=$stageAttempted;
            stage_rejected=$stageRejected;stage_error=$stageError;
            lease_state=$lease.LeaseState;
            settlement=$lease.Settlement;rollback_calls=$lease.RollbackCalls;
            commit_calls=$lease.CommitCalls;stage_calls=$lease.StageCalls;
            close_receipts=@($lease.CloseReceipts);closure_unknown=$lease.ClosureUnknown;
            target_handles_closed=$lease.TargetHandlesClosed;is_closed=$lease.IsClosed;
            native_error=$lease.LastNativeError;cleanup_error=$cleanupError}
        if ($record.cleanup_error -or $record.closure_unknown -or
            $record.settlement -cne 'rollback-succeeded' -or
            -not $record.target_handles_closed -or -not $record.is_closed -or
            $record.stage_calls -ne 0 -or $record.commit_calls -ne 0 -or
            $record.rollback_calls -ne 1 -or
            @($record.close_receipts | Where-Object { $_ -cnotmatch ':closed$' }).Count -ne 0 -or
            @($record.close_receipts | Where-Object { $_ -ceq 'transaction:closed' }).Count -ne 1) {
            throw 'Control settlement or closure is unknown; after-release support is forbidden.'
        }
        foreach ($requiredClose in @('writer:0:closed','anchor:0:closed',
                'writer:1:closed','anchor:1:closed')) {
            if (@($record.close_receipts | Where-Object { $_ -ceq $requiredClose }).Count -ne 1) {
                throw 'Control target closure is incomplete; after-release support is forbidden.'
            }
        }
        Write-Marker (Join-Path $Scope 'candidate-done.json') ([ordered]@{
            status=$status;issued_utc=$doneUtc;settlement=$record.settlement;
            rollback_calls=$record.rollback_calls;stage_calls=$record.stage_calls;
            commit_calls=$record.commit_calls;closure_unknown=$record.closure_unknown;
            target_handles_closed=$record.target_handles_closed;is_closed=$record.is_closed;
            transaction_closed=$true})
        Write-ControlRecord 'candidate' $record
    }
    } finally { $ownedDeadline.Dispose() }
    return
}

if ($Scope) { throw 'Controller does not accept caller-selected fixture scope.' }
if ($env:DARK_PHASE_B_BATCH_GUID -or $env:DARK_PHASE_B_NONCE) {
    throw 'Controller inherited a fixture capability.'
}
Assert-ControlPathChain (Join-Path $profile 'AppData/Local/Temp')
if ([IO.Directory]::Exists($base)) { Assert-PrivateDirectory $base }
else { New-PrivateScope $base }
Assert-ControlPathChain $base
$nonce=[Guid]::NewGuid().ToString('N')
$Scope=Join-Path $base $nonce
New-PrivateScope $Scope
Assert-ControlPathChain $Scope
$children=[Collections.Generic.List[object]]::new()
function Start-ControlChild([string]$Role) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $start.WorkingDirectory=$repo;$start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,
            '-Mode',$Role,'-Scope',$Scope)) { $start.ArgumentList.Add($arg) }
    $start.Environment['DARK_PHASE_B_NONCE']=$nonce
    [void]$start.Environment.Remove('DARK_PHASE_B_BATCH_GUID')
    $process=[Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'Control owned child did not start.' }
    return [ordered]@{process=$process;stdout_task=$process.StandardOutput.ReadToEndAsync();
        stderr_task=$process.StandardError.ReadToEndAsync();
        started_utc=[DateTime]::UtcNow.ToString('o');role=$Role;pid=$process.Id;
        kill_requested=$false}
}
function Read-ControlChild($Result,[string]$Role) {
    if ($null -eq $Result -or -not $Result.closed -or $Result.exit_code -ne 0 -or
        $Result.capture_error -or $Result.kill_requested -or
        -not [string]::IsNullOrEmpty($Result.stderr)) {
        throw 'Control child did not close successfully with complete capture.'
    }
    $lines=@($Result.stdout -split "`r?`n" | Where-Object { $_.StartsWith('DR_ACQUIRE_CHILD ') })
    if ($lines.Count -ne 1) { throw 'Control child has no unique structured receipt.' }
    $receipt=$lines[0].Substring('DR_ACQUIRE_CHILD '.Length) | ConvertFrom-Json -AsHashtable
    if ($receipt.role -cne $Role) { throw 'Control child receipt role differs.' }
    return $receipt
}
$clock=[Diagnostics.Stopwatch]::StartNew();$actor=$null;$candidate=$null
$actorResult=$null;$candidateResult=$null;$failure=$null
try {
    $actor=Start-ControlChild 'actor';$children.Add($actor)
    while (-not (Test-MarkerReady (Join-Path $Scope 'actor-ready.json'))) {
        if ($actor.process.HasExited -or $clock.ElapsedMilliseconds -ge 12000) {
            throw 'Control independent freeze did not complete within deadline.'
        }
        Start-Sleep -Milliseconds 50
    }
    $ready=Read-Marker (Join-Path $Scope 'actor-ready.json')
    $candidate=Start-ControlChild 'candidate';$children.Add($candidate)
    $candidateResult=Complete-OwnedChild $candidate ([Math]::Max(0,20000-[int]$clock.ElapsedMilliseconds))
    if ($null -eq $candidateResult -or -not $candidateResult.closed) {
        throw 'Control candidate exceeded the active deadline.'
    }
    $actorResult=Complete-OwnedChild $actor ([Math]::Max(0,25000-[int]$clock.ElapsedMilliseconds))
    if ($null -eq $actorResult -or -not $actorResult.closed) {
        throw 'Control actor exceeded the settlement deadline.'
    }
    if ($clock.ElapsedMilliseconds -gt 25000) {
        throw 'Control exceeded its settlement deadline.'
    }
    $barrier=Read-Marker (Join-Path $Scope 'candidate-barrier.json')
    $attemptMarker=Read-Marker (Join-Path $Scope 'actor-done.json')
    $doneMarker=Read-Marker (Join-Path $Scope 'candidate-done.json')
    $candidateReceipt=Read-ControlChild $candidateResult 'candidate'
    $actorReceipt=Read-ControlChild $actorResult 'actor'
    $verdict=Assert-AcquireChildReceipt $candidateReceipt $actorReceipt $barrier $ready `
        $attemptMarker $doneMarker $source
    Write-NewText (Join-Path $Scope 'control-receipt.json') (([ordered]@{
        schema='dark240-acquire-child-controller-v1';source=$source;ready=$ready;
        barrier=$barrier;attempt_marker=$attemptMarker;done_marker=$doneMarker;
        candidate=$candidateReceipt;actor=$actorReceipt;
        candidate_close=$candidateResult;actor_close=$actorResult;verdict=$verdict;
        elapsed_ms=[int]$clock.ElapsedMilliseconds;active_deadline_ms=20000;
        settle_deadline_ms=25000;owned_child_deadline_ms=30000;
        gate1='unverified'} | ConvertTo-Json -Depth 12) + "`n")
    Write-Host "Active-Acquire child diagnostic passed: $verdict. Gate 1 unverified."
} catch {
    $failure=[ordered]@{type=$_.Exception.GetType().FullName;
        message=$_.Exception.Message;observed_utc=[DateTime]::UtcNow.ToString('o')}
    throw
} finally {
    foreach ($child in $children) {
        $closed=if ($child.role -ceq 'candidate') {
            $null -ne $candidateResult -and $candidateResult.closed
        } else { $null -ne $actorResult -and $actorResult.closed }
        if (-not $closed -and -not $child.process.HasExited) {
            $child.kill_requested=$true
            try { $child.process.Kill($true) } catch { }
            [void]$child.process.WaitForExit(5000)
        }
    }
    if ($null -ne $failure) {
        try {
            if ($null -ne $candidate -and ($null -eq $candidateResult -or
                    -not $candidateResult.closed)) {
                $candidateResult=Complete-OwnedChild $candidate 1000
            }
            if ($null -ne $actor -and ($null -eq $actorResult -or
                    -not $actorResult.closed)) {
                $actorResult=Complete-OwnedChild $actor 1000
            }
            Write-NewText (Join-Path $Scope 'control-failure.json') (([ordered]@{
                schema='dark240-acquire-child-failure-v1';source=$source;
                failure=$failure;candidate_close=$candidateResult;
                actor_close=$actorResult;elapsed_ms=[int]$clock.ElapsedMilliseconds;
                gate1='unverified'} | ConvertTo-Json -Depth 10) + "`n")
        } catch { }
    }
    foreach ($child in $children) {
        try { $child.process.Dispose() } catch { }
    }
    # Preserve the disposable private fixture and raw receipts for independent review.
}
