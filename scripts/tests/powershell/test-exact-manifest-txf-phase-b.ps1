[CmdletBinding()]
param(
    [ValidateSet('controller','candidate','observer-actor')]
    [string]$Mode='controller',
    [ValidateSet('B1','B2','B3','B4','B5','B6','B7')]
    [string]$Trial,
    [string]$Scope
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Phase B native falsification requires Windows.' }
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$modulePath=Join-Path $repo 'scripts/modules/powershell/controller-owned-root-guard.ps1'
$observerPath=Join-Path $repo 'scripts/tests/support/exact-manifest-phase-b-observer.cs'
$actorPath=Join-Path $repo 'scripts/tests/support/exact-manifest-phase-b-actors.cs'
$sourceSha=(git -C $repo rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Phase B source SHA is unavailable.' }
$source=[ordered]@{commit=$sourceSha;
    fixture_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
    module_sha256=(Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant();
    observer_sha256=(Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash.ToLowerInvariant();
    actor_sha256=(Get-FileHash -LiteralPath $actorPath -Algorithm SHA256).Hash.ToLowerInvariant()}
$trials=@('B1','B2','B3','B4','B5','B6','B7')

function Hash-Text([string]$Value) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
}
function Write-NewText([string]$Path,[string]$Value) {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Value)
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) }
    finally { $stream.Dispose() }
}
function Write-Marker([string]$Path,$Value) {
    $pending=$Path + '.pending-' + [Guid]::NewGuid().ToString('N')
    Write-NewText $pending (($Value | ConvertTo-Json -Depth 6 -Compress) + "`n")
    [IO.File]::Move($pending,$Path) # Same-directory, no-overwrite publication after flush.
}
function Wait-Marker([string]$Path,[int]$Milliseconds) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($Path)) {
        if ($clock.ElapsedMilliseconds -ge $Milliseconds) { throw "Phase B marker unavailable: $([IO.Path]::GetFileName($Path))" }
        Start-Sleep -Milliseconds 50
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Wait-ActorBarrier([string]$Path,[int]$Milliseconds) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($Path)) {
        if ([IO.File]::Exists((Join-Path $Scope 'actor-cancel.json'))) { return $false }
        if ($clock.ElapsedMilliseconds -ge $Milliseconds) {
            throw "Phase B actor barrier unavailable: $([IO.Path]::GetFileName($Path))"
        }
        Start-Sleep -Milliseconds 50
    }
    return $true
}
function Read-KnownBytes([string]$Path,[bool]$AllowAbsent) {
    try {
        $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    } catch [IO.FileNotFoundException] {
        if ($AllowAbsent) { return [ordered]@{status='absent'} };throw
    } catch [IO.DirectoryNotFoundException] {
        if ($AllowAbsent) { return [ordered]@{status='absent'} };throw
    }
    try {
        if ($stream.Length -gt 64) { throw 'Phase B known byte proof exceeded 64 bytes.' }
        $bytes=[byte[]]::new([int]$stream.Length)
        $position=0
        while ($position -lt $bytes.Length) {
            $count=$stream.Read($bytes,$position,$bytes.Length-$position)
            if ($count -le 0) { throw 'Phase B known byte proof ended early.' }
            $position+=$count
        }
        return [ordered]@{status='present';bytes=$bytes.Length;
            sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();
            base64=[Convert]::ToBase64String($bytes)}
    } finally { $stream.Dispose() }
}
function Path-State([string]$Path) {
    try {
        $attrs=[IO.File]::GetAttributes($Path)
        return [ordered]@{status='present';directory=(($attrs -band [IO.FileAttributes]::Directory) -ne 0);
            reparse=(($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0)}
    } catch [IO.FileNotFoundException] { return [ordered]@{status='absent'} }
    catch [IO.DirectoryNotFoundException] { return [ordered]@{status='absent'} }
}
function Assert-PrivateDirectory([string]$Path) {
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected -or
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $current.Value) {
        throw 'Phase B fixture root owner/ACL is not private.'
    }
    $allowed=@($current.Value,'S-1-5-18','S-1-5-32-544')
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if ($rules.Count -eq 0 -or @($rules | Where-Object {
        $_.IdentityReference.Value -notin $allowed -or $_.AccessControlType -ne 'Allow' -or
        $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl
    }).Count -ne 0) { throw 'Phase B fixture has an unexpected ACE.' }
}
function New-PrivateScope([string]$Path) {
    if ([IO.Directory]::Exists($Path)) { throw 'Phase B scope already exists.' }
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($sid)
    foreach ($ownerSid in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($ownerSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
             [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    [void][IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path),$acl)
    Assert-PrivateDirectory $Path
}
function Assert-ChildScope {
    if ([string]::IsNullOrWhiteSpace($Scope) -or [string]::IsNullOrWhiteSpace($Trial) -or
        $env:DARK_PHASE_B_NONCE -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Phase B child lacks exact controller-issued capability.'
    }
    $profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $expectedBase=Join-Path (Join-Path $profile 'AppData/Local/Temp') 'Dark180-TxfPhaseB'
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($Scope),$expectedBase,
        [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($Scope) -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Phase B child scope is outside the exact profile temp root.'
    }
    Assert-PrivateDirectory $Scope
}
function New-ChildDeadline {
    return [DarkPhaseBDeadline]::new(15000)
}

if ($Mode -ne 'controller') {
    Assert-ChildScope
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
public sealed class DarkPhaseBDeadline : IDisposable {
    readonly Timer timer;
    public DarkPhaseBDeadline(int milliseconds) {
        timer = new Timer(_ => {
            Console.Error.WriteLine("DR_PHASE_B_OWNED_DEADLINE active worker exceeded 15 seconds");
            Environment.Exit(124);
        }, null, milliseconds, Timeout.Infinite);
    }
    public void Dispose() { timer.Dispose(); }
}
'@ -ErrorAction Stop
    $deadline=New-ChildDeadline
    $target=Join-Path $Scope 'target'
    $events=[Collections.Generic.List[object]]::new()
    $workerError=$null;$cleanupError=$null;$lease=$null;$actorResource=$null;$result=$null
    $lateCapability=$null
    try {
        if ($Mode -eq 'observer-actor') {
            Add-Type -Path $observerPath -ErrorAction Stop
            Add-Type -Path $actorPath -ErrorAction Stop
            [void][IO.Directory]::CreateDirectory($target)
            [IO.File]::WriteAllBytes((Join-Path $target 'approved.bin'),[byte[]](9,18,27,36,45,54))
            [IO.File]::WriteAllBytes((Join-Path $Scope 'approved-before.bin'),[byte[]](9,18,27,36,45,54))
            [IO.File]::WriteAllBytes((Join-Path $Scope 'sentinel.bin'),[byte[]](72,63,54,45,36,27))
            if ($Trial -in @('B1','B5')) {
                $folder=Join-Path $target 'folder';[void][IO.Directory]::CreateDirectory($folder)
                [IO.File]::WriteAllBytes((Join-Path $folder 'nested.bin'),[byte[]](1,2,3,4))
            }
            if ($Trial -eq 'B1') {
                [IO.File]::WriteAllBytes((Join-Path $target 'sibling.bin'),[byte[]](5,6,7,8))
            }
            $rows=[DarkPhaseBFixtureObserver]::Freeze($target)
            $digest=[DarkPhaseBFixtureObserver]::DigestRows($rows)
            $rootId=$rows[0].Split('|')[2]
            $expectedPaths=switch ($Trial) {
                'B1' {@('.', '61007000700072006f007600650064002e00620069006e00',
                    '66006f006c00640065007200','66006f006c00640065007200/6e00650073007400650064002e00620069006e00',
                    '7300690062006c0069006e0067002e00620069006e00')}
                'B5' {@('.', '61007000700072006f007600650064002e00620069006e00',
                    '66006f006c00640065007200','66006f006c00640065007200/6e00650073007400650064002e00620069006e00')}
                default {@('.','61007000700072006f007600650064002e00620069006e00')}
            }
            $paths=@($rows | ForEach-Object { $_.Split('|')[0] })
            if (($paths -join ',') -cne ($expectedPaths -join ',')) {
                throw 'Independent fixture inventory differs from frozen trial topology.'
            }
            $known=Read-KnownBytes (Join-Path $target 'approved.bin') $false
            if ($known.sha256 -cne ([Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData([byte[]](9,18,27,36,45,54))).ToLowerInvariant())) {
                throw 'Independent approved byte control differs before candidate start.'
            }
            $nonceHash=Hash-Text $env:DARK_PHASE_B_NONCE
            $fields=@($sourceSha,$nonceHash,$Scope,$target,$rootId,$digest)
            Write-NewText (Join-Path $Scope 'approved-manifest.txt') (($rows -join "`n") + "`n")
            Write-NewText (Join-Path $Scope 'authority.txt') (($fields -join "`n") + "`n")
            Write-NewText (Join-Path $Scope 'predelete.txt') (($fields -join "`n") + "`n")
            $events.Add([ordered]@{phase='independent-freeze';row_count=$rows.Count;
                root_id=$rootId;approved_id=$rows[1].Split('|')[2];
                manifest_digest=$digest;approved_before=$known})
            if ($Trial -eq 'B3') {
                $ads=[DarkPhaseBFixtureActors]::CreateDirectoryAds($Scope,$target)
                $events.Add([ordered]@{phase='preexisting-directory-ads';admitted=$ads.Admitted;
                    error=$ads.NativeError;written=$ads.ByteWritten})
                if (-not $ads.Admitted -or -not $ads.ByteWritten) { throw 'B3 directory ADS control was unavailable.' }
            }
            if ($Trial -eq 'B5') {
                $stash=Join-Path $Scope 'stashed-approved-folder'
                [IO.Directory]::Move((Join-Path $target 'folder'),$stash)
                $sentinelDir=Join-Path $Scope 'junction-sentinel-dir'
                [void][IO.Directory]::CreateDirectory($sentinelDir)
                [IO.File]::WriteAllBytes((Join-Path $sentinelDir 'sentinel.bin'),[byte[]](81))
                $junction=Join-Path $target 'folder'
                $null=New-Item -ItemType Junction -Path $junction -Target $sentinelDir -ErrorAction Stop
                if (([IO.File]::GetAttributes($junction) -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    throw 'B5 owned junction is not a reparse point.'
                }
                $events.Add([ordered]@{phase='owned-junction-installed';path=$junction;target=$sentinelDir})
            }
            if ($Trial -eq 'B4') {
                $actorResource=[DarkPhaseBFixtureActors]::OpenHeldMapping($Scope,$target)
                $events.Add([ordered]@{phase='writable-mapping-held-after-file-close'})
            }
            if ($Trial -eq 'B2') {
                $lateCapability=[DarkPhaseBFixtureActors]::PrepareLateChild($Scope,$target)
            }
            if ($Trial -eq 'B6') {
                $actorResource=[DarkPhaseBFixtureActors]::OpenHeldDacl($Scope,$target)
                $events.Add([ordered]@{phase='READ_CONTROL-WRITE_DAC-handle-held'})
            }
            Write-Marker (Join-Path $Scope 'actor-ready.json') ([ordered]@{trial=$Trial;
                source=$source;manifest_digest=$digest;root_id=$rootId})
            if ($Trial -eq 'B2') {
                if (Wait-ActorBarrier (Join-Path $Scope 'candidate-barrier.json') 12000) {
                    $result=$lateCapability.Attempt()
                    $events.Add([ordered]@{phase='late-child-after-last-close';admitted=$result.Admitted;
                        native_error=$result.NativeError;written=$result.ByteWritten})
                    Write-Marker (Join-Path $Scope 'actor-done.json') ([ordered]@{admitted=$result.Admitted;
                        native_error=$result.NativeError;written=$result.ByteWritten})
                } else { $events.Add([ordered]@{phase='required-barrier-unverified';reason='candidate-rejected-before-barrier'}) }
            } elseif ($Trial -eq 'B4') {
                if (Wait-ActorBarrier (Join-Path $Scope 'actor-go.json') 12000) {
                    $mappingWritten=$false;$mappingError=$null
                    try { $actorResource.WriteOne(82);$mappingWritten=$true }
                    catch { $mappingError=[ordered]@{type=$_.Exception.GetType().FullName;
                        message=$_.Exception.Message} }
                    $events.Add([ordered]@{phase='held-mapping-write-attempt';byte=82;
                        written=$mappingWritten;error=$mappingError})
                    Write-Marker (Join-Path $Scope 'actor-done.json') ([ordered]@{
                        written=$mappingWritten;byte=82;error=$mappingError})
                } else { $events.Add([ordered]@{phase='required-barrier-unverified';reason='candidate-rejected-before-barrier'}) }
            } elseif ($Trial -eq 'B6') {
                if (Wait-ActorBarrier (Join-Path $Scope 'actor-go.json') 12000) {
                    $change=[DarkPhaseBFixtureActors]::AddAuthenticatedUsersReadAttributes($actorResource)
                    $events.Add([ordered]@{phase='held-WRITE_DAC-change';native_error=$change.NativeError;
                        changed=$change.Changed;before_sha256=(Hash-Text $change.Before);
                        after_sha256=(Hash-Text $change.After)})
                    Write-Marker (Join-Path $Scope 'actor-done.json') ([ordered]@{
                        native_error=$change.NativeError;changed=$change.Changed})
                } else { $events.Add([ordered]@{phase='required-barrier-unverified';reason='candidate-rejected-before-barrier'}) }
            }
            $null=Wait-Marker (Join-Path $Scope 'candidate-done.json') 12000
            if ($null -ne $actorResource) { $actorResource.Dispose();$actorResource=$null }
            if ($Trial -eq 'B2' -and $null -ne $result -and -not $result.Admitted) {
                $released=$lateCapability.Attempt()
                $events.Add([ordered]@{phase='late-child-after-release-support-control';
                    admitted=$released.Admitted;native_error=$released.NativeError;
                    written=$released.ByteWritten})
            }
            $rootState=Path-State $target
            $approvedAfter=Read-KnownBytes (Join-Path $target 'approved.bin') $true
            $sentinelAfter=Read-KnownBytes (Join-Path $Scope 'sentinel.bin') $false
            $beforeAfter=Read-KnownBytes (Join-Path $Scope 'approved-before.bin') $false
            $post=[ordered]@{root=$rootState;approved=$approvedAfter;
                sentinel=$sentinelAfter;approved_before=$beforeAfter}
            if ($rootState.status -eq 'present') {
                $post.root_id=[DarkPhaseBFixtureObserver]::IdentityOf($target,$true)
                $post.owner_sddl_sha256=Hash-Text (Get-Acl -LiteralPath $target).Sddl
            }
            if ($approvedAfter.status -eq 'present') {
                $post.approved_id=[DarkPhaseBFixtureObserver]::IdentityOf(
                    (Join-Path $target 'approved.bin'),$false)
                $post.approved_sddl_sha256=Hash-Text (
                    (Get-Acl -LiteralPath (Join-Path $target 'approved.bin')).Sddl)
            }
            if ($Trial -eq 'B2') {
                $post.late_child=Read-KnownBytes (Join-Path $target 'late-child.bin') $true
            }
            if ($Trial -eq 'B1') {
                $post.nested=Read-KnownBytes (Join-Path $target 'folder/nested.bin') $true
                $post.sibling=Read-KnownBytes (Join-Path $target 'sibling.bin') $true
            }
            if ($Trial -eq 'B3') {
                $post.directory_ads=Read-KnownBytes ($target + ':unexpected') $false
            }
            if ($Trial -eq 'B5') {
                $post.junction=Path-State (Join-Path $target 'folder')
                if ($post.junction.status -eq 'present' -and $post.junction.reparse) {
                    $post.junction_target=@((Get-Item -LiteralPath (Join-Path $target 'folder')).Target)
                }
                $post.junction_sentinel=Read-KnownBytes (Join-Path $Scope 'junction-sentinel-dir/sentinel.bin') $false
                $post.stashed_approved=Read-KnownBytes (Join-Path $Scope 'stashed-approved-folder/nested.bin') $false
            }
            $events.Add([ordered]@{phase='independent-postproof';data=$post})
            [Console]::Out.WriteLine('DR_PHASE_B_CHILD ' + (([ordered]@{
                schema='dark180-exact-manifest-phase-b-child-v1';role='observer-actor';trial=$Trial;
                source=$source;scope=$Scope;events=@($events);status='completed';postproof=$post;
                gate1='unverified';target_collection=0;product=0} | ConvertTo-Json -Depth 12 -Compress)))
        } else {
            . $modulePath
            Add-Type -TypeDefinition $script:DrOwnedRootGuardSource -ErrorAction Stop
            $status='not-started'
            try {
                $lease=[DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease]::PrepareFixtureOnly(
                    $Scope,$target,$env:DARK_PHASE_B_NONCE,$sourceSha)
                $events.Add([ordered]@{phase='prepared';root_id=$lease.RootId})
                $digest=$lease.AcquireExactSet()
                $events.Add([ordered]@{phase='exact-set-acquired';digest=$digest;
                    count=$lease.HeldEntryCount})
                if ($Trial -eq 'B4') {
                    Write-Marker (Join-Path $Scope 'candidate-acquired.json') ([ordered]@{trial=$Trial;digest=$digest})
                    $null=Wait-Marker (Join-Path $Scope 'actor-done.json') 10000
                }
                $lease.StageExactSet((Join-Path $Scope 'predelete.txt'))
                $events.Add([ordered]@{phase='staged-target-handles-closed';stage_calls=$lease.StageCalls;
                    close_receipts=$lease.CloseReceipts})
                if ($Trial -in @('B2','B6','B7')) {
                    Write-Marker (Join-Path $Scope 'candidate-barrier.json') ([ordered]@{trial=$Trial;
                        state=$lease.LeaseState;stage_calls=$lease.StageCalls;
                        target_handles_closed=$lease.TargetHandlesClosed;
                        close_receipts=$lease.CloseReceipts;commit_calls=$lease.CommitCalls})
                }
                if ($Trial -in @('B2','B6')) { $null=Wait-Marker (Join-Path $Scope 'actor-done.json') 10000 }
                if ($Trial -eq 'B7') {
                    $null=Wait-Marker (Join-Path $Scope 'candidate-release-should-not-exist.json') 12000
                    throw 'B7 candidate was released instead of killed at the precommit barrier.'
                }
                if ($Trial -eq 'B2') {
                    if (-not $lease.Abort()) { throw 'B2 intentional rollback outcome is unknown.' }
                    $status='intentional-rollback-post-barrier'
                } else {
                $lease.CommitOnce((Join-Path $Scope 'predelete.txt'))
                $status='commit-call-succeeded-poststate-unverified'
                }
            } catch {
                $status='rejected-or-unknown'
                $workerError=[ordered]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message;
                    error_id=$_.FullyQualifiedErrorId}
            } finally {
                if ($null -ne $lease) {
                    try { $lease.Dispose() }
                    catch { $cleanupError=[ordered]@{type=$_.Exception.GetType().FullName;
                        message=$_.Exception.Message;error_id=$_.FullyQualifiedErrorId} }
                }
            }
            [Console]::Out.WriteLine('DR_PHASE_B_CHILD ' + (([ordered]@{
                schema='dark180-exact-manifest-phase-b-child-v1';role='candidate';trial=$Trial;
                source=$source;scope=$Scope;events=@($events);status=$status;
                error=$workerError;cleanup_error=$cleanupError;
                lease_state=$(if($null -ne $lease){$lease.LeaseState}else{'not-created'});
                settlement=$(if($null -ne $lease){$lease.Settlement}else{'not-started'});
                stage_calls=$(if($null -ne $lease){$lease.StageCalls}else{0});
                commit_calls=$(if($null -ne $lease){$lease.CommitCalls}else{0});
                rollback_calls=$(if($null -ne $lease){$lease.RollbackCalls}else{0});
                close_receipts=$(if($null -ne $lease){$lease.CloseReceipts}else{@()});
                closure_unknown=$(if($null -ne $lease){$lease.ClosureUnknown}else{$false});
                native_error=$(if($null -ne $lease){$lease.LastNativeError}else{0});
                native_exception_type=$(if($null -ne $lease){$lease.NativeExceptionType}else{$null});
                native_exception_message=$(if($null -ne $lease){$lease.NativeExceptionMessage}else{$null});
                gate1='unverified';target_collection=0;product=0} | ConvertTo-Json -Depth 12 -Compress)))
        }
    } catch {
        [Console]::Error.WriteLine('DR_PHASE_B_WORKER_ERROR ' + (([ordered]@{
            trial=$Trial;role=$Mode;source=$source;scope=$Scope;events=@($events);
            type=$_.Exception.GetType().FullName;message=$_.Exception.Message} | ConvertTo-Json -Depth 10 -Compress)))
        throw
    } finally { $deadline.Dispose() }
    return
}

function Start-OwnedChild([string]$Role,[string]$TrialName,[string]$TrialScope,[string]$Nonce) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $start.WorkingDirectory=$repo
    $start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,
            '-Mode',$Role,'-Trial',$TrialName,'-Scope',$TrialScope)) { $start.ArgumentList.Add($arg) }
    $start.Environment['DARK_PHASE_B_NONCE']=$Nonce
    $process=[Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw "Phase B $Role process did not start." }
    return [ordered]@{process=$process;stdout_task=$process.StandardOutput.ReadToEndAsync();
        stderr_task=$process.StandardError.ReadToEndAsync();started_utc=[DateTime]::UtcNow.ToString('o');
        role=$Role;pid=$process.Id;kill_requested=$false}
}
function Stop-OwnedChild($Child) {
    if ($null -eq $Child -or $Child.process.HasExited) { return }
    $Child.kill_requested=$true
    try { $Child.process.Kill($true) }
    catch [InvalidOperationException] { if (-not $Child.process.HasExited) { throw } }
}
function Complete-OwnedChild($Child,[int]$SettleMilliseconds) {
    if ($null -eq $Child) { return $null }
    $closed=$Child.process.WaitForExit([Math]::Max(0,$SettleMilliseconds))
    $stdout=$null;$stderr=$null;$capture_error=$null
    if ($closed) {
        try {
            $stdout=$Child.stdout_task.GetAwaiter().GetResult()
            $stderr=$Child.stderr_task.GetAwaiter().GetResult()
        } catch { $capture_error=$_.Exception.Message }
    }
    $row=[ordered]@{role=$Child.role;pid=$Child.pid;started_utc=$Child.started_utc;
        completed_utc=[DateTime]::UtcNow.ToString('o');closed=$closed;
        kill_requested=$Child.kill_requested;
        exit_code=$(if($closed){$Child.process.ExitCode}else{$null});
        stdout=$stdout;stderr=$stderr;capture_error=$capture_error}
    if ($closed) { $Child.process.Dispose() }
    return $row
}
function Read-WorkerRecord($ProcessRow,[string]$ExpectedRole,[string]$ExpectedTrial) {
    if ($null -eq $ProcessRow -or -not $ProcessRow.closed -or
        -not [string]::IsNullOrEmpty($ProcessRow.capture_error)) {
        throw "Phase B $ExpectedRole owned process did not close with complete raw capture."
    }
    $records=@($ProcessRow.stdout -split "`r?`n" | Where-Object { $_.StartsWith('DR_PHASE_B_CHILD ') })
    if ($records.Count -ne 1) { throw "Phase B $ExpectedRole has $($records.Count) structured records." }
    $receipt=($records[0].Substring('DR_PHASE_B_CHILD '.Length) | ConvertFrom-Json -AsHashtable)
    if ($receipt.schema -cne 'dark180-exact-manifest-phase-b-child-v1' -or
        $receipt.role -cne $ExpectedRole -or $receipt.trial -cne $ExpectedTrial) {
        throw "Phase B $ExpectedRole structured record is mixed or malformed."
    }
    return $receipt
}
function Assert-PhaseBTrialReceipt($Row,[string]$ExpectedTrial,$ExpectedSource) {
    if ($Row.trial -cne $ExpectedTrial -or $Row.controller_error -or
        $null -eq $Row.actor -or $null -eq $Row.candidate -or
        -not $Row.actor.closed -or -not $Row.candidate.closed -or
        $Row.actor.capture_error -or $Row.candidate.capture_error -or
        $Row.actor.exit_code -ne 0 -or
        ($ExpectedTrial -ne 'B7' -and $Row.candidate.exit_code -ne 0) -or
        ($ExpectedTrial -eq 'B7' -and (-not $Row.candidate.kill_requested -or
            $Row.candidate.exit_code -eq 0))) {
        throw "Phase B $ExpectedTrial process receipt is incomplete or failed."
    }
    if ($null -eq $Row.actor_receipt -or
        $Row.actor_receipt.status -cne 'completed' -or
        $null -eq $Row.actor_receipt.postproof -or
        ($ExpectedTrial -ne 'B7' -and $null -eq $Row.candidate_receipt)) {
        throw "Phase B $ExpectedTrial required independent worker receipt is missing."
    }
    foreach ($receipt in @($Row.actor_receipt,$Row.candidate_receipt)) {
        if ($null -eq $receipt) { continue }
        if ($receipt.trial -cne $ExpectedTrial -or $receipt.scope -cne $Row.scope -or
            $receipt.gate1 -cne 'unverified' -or $receipt.target_collection -ne 0 -or
            $receipt.product -ne 0) {
            throw "Phase B $ExpectedTrial worker scope/gate record differs."
        }
        foreach ($field in @('commit','fixture_sha256','module_sha256',
                'observer_sha256','actor_sha256')) {
            if (-not $receipt.source.Contains($field) -or
                $receipt.source[$field] -cne $ExpectedSource[$field]) {
                throw "Phase B $ExpectedTrial worker source binding differs: $field."
            }
        }
    }
    $post=$Row.actor_receipt.postproof
    $freeze=@($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'independent-freeze' })
    $expectedRows=switch ($ExpectedTrial) {'B1' {5} 'B5' {4} default {2}}
    if ($freeze.Count -ne 1 -or $freeze[0].row_count -ne $expectedRows -or
        $freeze[0].manifest_digest -cne $Row.ready.manifest_digest -or
        $freeze[0].root_id -cne $Row.ready.root_id -or
        $freeze[0].approved_before.base64 -cne
            [Convert]::ToBase64String([byte[]](9,18,27,36,45,54))) {
        throw "Phase B $ExpectedTrial independent frozen authority differs."
    }
    if ($post.root.status -ceq 'present' -and $post.root_id -cne $freeze[0].root_id) {
        throw "Phase B $ExpectedTrial root identity changed after candidate settlement."
    }
    if ($post.approved.status -ceq 'present' -and
        $post.approved_id -cne $freeze[0].approved_id) {
        throw "Phase B $ExpectedTrial approved file identity changed after settlement."
    }
    $sentinelBytes=[byte[]](72,63,54,45,36,27)
    $approvedBytes=[byte[]](9,18,27,36,45,54)
    foreach ($control in @(@('sentinel',$sentinelBytes),@('approved_before',$approvedBytes))) {
        $actual=$post[$control[0]]
        $expected=[Convert]::ToBase64String($control[1])
        if ($actual.status -cne 'present' -or $actual.base64 -cne $expected -or
            $actual.sha256 -cne ([Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($control[1])).ToLowerInvariant())) {
            throw "Phase B $ExpectedTrial independent known-byte control changed: $($control[0])."
        }
    }
    $candidate=$Row.candidate_receipt
    if ($ExpectedTrial -eq 'B7') {
        if ($null -ne $candidate -or $null -eq $Row.barrier -or
            $Row.barrier.commit_calls -ne 0 -or
            -not $Row.barrier.target_handles_closed) {
            throw 'Phase B B7 death did not bind the exact precommit barrier.'
        }
        if ($post.approved.status -cne 'present' -or
            $post.approved.base64 -cne [Convert]::ToBase64String($approvedBytes)) {
            throw 'Phase B B7 approved bytes were not independently preserved.'
        }
        return 'worker-death-preserved-gate1-unverified'
    }
    if ($candidate.closure_unknown -or $candidate.cleanup_error -or
        $candidate.settlement -match 'unknown' -or
        $candidate.lease_state -match 'unknown' -or $candidate.commit_calls -gt 1 -or
        $candidate.rollback_calls -gt 1 -or $candidate.stage_calls -gt 20000) {
        throw "Phase B $ExpectedTrial has unknown settlement/closure or exceeded exact-call bounds."
    }
    if ($candidate.status -ceq 'commit-call-succeeded-poststate-unverified') {
        if ($candidate.commit_calls -ne 1 -or $candidate.rollback_calls -ne 0 -or
            $candidate.stage_calls -ne $expectedRows -or
            $post.root.status -cne 'absent' -or $post.approved.status -cne 'absent') {
            throw "Phase B $ExpectedTrial commit API result lacks independent target deletion."
        }
        if ($ExpectedTrial -eq 'B1' -and
            ($post.nested.status -cne 'absent' -or $post.sibling.status -cne 'absent')) {
            throw 'Phase B B1 committed but the exact nested/sibling set survived.'
        }
        if ($ExpectedTrial -eq 'B2') {
            throw 'Phase B B2 committed; the late-child interval lacks supported independent preservation proof.'
        }
        if ($ExpectedTrial -in @('B3','B4','B5')) {
            throw "Phase B $ExpectedTrial committed despite its frozen falsifier."
        }
        if ($ExpectedTrial -eq 'B6') {
            $dacl=@($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'held-WRITE_DAC-change' })
            if ($dacl.Count -ne 1 -or $dacl[0].native_error -eq 0 -or
                $dacl[0].changed -or $dacl[0].before_sha256 -cne $dacl[0].after_sha256) {
                throw 'Phase B B6 committed without excluding the held DACL mutation.'
            }
        }
        return 'exact-fixture-deleted-gate1-unverified'
    }
    $intentionalB2=$ExpectedTrial -eq 'B2' -and
        $candidate.status -ceq 'intentional-rollback-post-barrier'
    if ((-not $intentionalB2 -and $candidate.status -cne 'rejected-or-unknown') -or
        $candidate.commit_calls -ne 0 -or
        $candidate.lease_state -notin @('rollback-succeeded','rejected-before-transaction') -or
        $post.root.status -cne 'present' -or
        $post.approved.status -cne 'present') {
        throw "Phase B $ExpectedTrial has an unproved safe rejection."
    }
    if ($intentionalB2 -and ($candidate.lease_state -cne 'rollback-succeeded' -or
        $candidate.rollback_calls -ne 1 -or $null -eq $Row.barrier -or
        $Row.barrier.state -cne 'staged' -or
        -not $Row.barrier.target_handles_closed -or $Row.barrier.commit_calls -ne 0)) {
        throw 'Phase B B2 intentional rollback lacks the exact last-close barrier.'
    }
    $expectedApproved=if ($ExpectedTrial -eq 'B4' -and
        @($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'held-mapping-write-attempt' -and $_.written }).Count -eq 1) {
        [byte[]](82,18,27,36,45,54)
    } else { $approvedBytes }
    if ($post.approved.base64 -cne [Convert]::ToBase64String($expectedApproved)) {
        throw "Phase B $ExpectedTrial unapproved approved-file bytes changed."
    }
    if ($ExpectedTrial -eq 'B4') {
        $mapping=@($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'held-mapping-write-attempt' })
        if ($mapping.Count -eq 1 -and $null -ne $mapping[0].error) {
            throw 'Phase B B4 mapping write outcome is unobservable or unsupported.'
        }
    }
    if ($ExpectedTrial -eq 'B2') {
        $late=@($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'late-child-after-last-close' })
        if ($intentionalB2 -and ($late.Count -ne 1 -or
            ($late[0].admitted -and -not $late[0].written))) {
            throw 'Phase B B2 actor did not observe a complete late-child attempt.'
        }
        if ($late.Count -eq 1 -and $late[0].admitted -and
            ($post.late_child.status -cne 'present' -or
             $post.late_child.base64 -cne [Convert]::ToBase64String([byte[]](81)))) {
            throw 'Phase B B2 admitted late child was not independently preserved.'
        }
        if ($late.Count -eq 1 -and -not $late[0].admitted) {
            $support=@($Row.actor_receipt.events | Where-Object {
                $_.phase -ceq 'late-child-after-release-support-control' })
            if ($support.Count -ne 1 -or -not $support[0].admitted -or
                $post.late_child.base64 -cne [Convert]::ToBase64String([byte[]](81))) {
                throw 'Phase B B2 refused child lacks a valid after-release control.'
            }
        }
    }
    if ($ExpectedTrial -eq 'B3' -and
        $post.directory_ads.base64 -cne [Convert]::ToBase64String([byte[]](91))) {
        throw 'Phase B B3 directory stream was not preserved.'
    }
    if ($ExpectedTrial -eq 'B5' -and
        ($post.junction.status -cne 'present' -or -not $post.junction.reparse -or
         @($post.junction_target).Count -ne 1 -or
         $post.junction_target[0] -cne (Join-Path $Row.scope 'junction-sentinel-dir') -or
         $post.junction_sentinel.base64 -cne [Convert]::ToBase64String([byte[]](81)) -or
         $post.stashed_approved.base64 -cne [Convert]::ToBase64String([byte[]](1,2,3,4)))) {
        throw 'Phase B B5 junction or owned sentinel was not preserved.'
    }
    if ($ExpectedTrial -eq 'B1' -and
        ($post.nested.base64 -cne [Convert]::ToBase64String([byte[]](1,2,3,4)) -or
         $post.sibling.base64 -cne [Convert]::ToBase64String([byte[]](5,6,7,8)))) {
        throw 'Phase B B1 rejected but its approved nested/sibling bytes changed.'
    }
    if ($intentionalB2) { return 'intentional-rollback-late-child-preserved-gate1-unverified' }
    if ($ExpectedTrial -eq 'B1') { return 'positive-control-rejected-preserved-mechanism-falsified' }
    if ($ExpectedTrial -in @('B2','B6') -and
        @($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'required-barrier-unverified' }).Count -eq 1) {
        return 'required-barrier-unverified-candidate-rejected-preserved'
    }
    if ($ExpectedTrial -eq 'B4' -and
        @($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'required-barrier-unverified' }).Count -eq 1) {
        return 'mapping-write-barrier-unverified-acquisition-rejected-preserved'
    }
    return 'candidate-rejected-preserved-gate1-unverified'
}

$suiteClock=[Diagnostics.Stopwatch]::StartNew()
$all=[Collections.Generic.List[object]]::new()
$controllerFailure=$null
$activeActor=$null;$activeCandidate=$null
$nativeTrialCount=0;$actorCount=0
try {
    $dirty=@(git -C $repo status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
        throw 'Phase B native fixture requires a clean source-bound checkout.'
    }
    $profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ($profile -cnotmatch '^[A-Za-z]:\\' -or
        -not [string]::Equals($local,($profile+'\AppData\Local'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Phase B local profile and AppData origin are not canonical.'
    }
    $drive=[IO.DriveInfo]::new($profile.Substring(0,3))
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed -or
        $drive.DriveFormat -cne 'NTFS') { throw 'Phase B requires a fixed local NTFS profile volume.' }
    $temp=Join-Path $local 'Temp'
    $chain=[Collections.Generic.List[IO.DirectoryInfo]]::new()
    for($item=[IO.DirectoryInfo]::new($temp);$null -ne $item;$item=$item.Parent){$chain.Add($item)}
    for($index=$chain.Count-1;$index -ge 0;$index--){
        if (-not $chain[$index].Exists -or
            (($chain[$index].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Phase B profile Temp ancestry is absent or reparse.'
        }
    }
    $base=Join-Path $temp 'Dark180-TxfPhaseB'
    if ([IO.Directory]::Exists($base)) { Assert-PrivateDirectory $base }
    else { New-PrivateScope $base }
    foreach ($name in $trials) {
        if ($suiteClock.Elapsed.TotalSeconds -ge 180) { throw 'Phase B 180-second suite cap expired.' }
        $trialClock=[Diagnostics.Stopwatch]::StartNew()
        $nonce=[Guid]::NewGuid().ToString('N')
        $scope=Join-Path $base $nonce
        New-PrivateScope $scope
        $row=[ordered]@{trial=$name;scope=$scope;started_utc=[DateTime]::UtcNow.ToString('o');
            source=$source;actor=$null;candidate=$null;actor_receipt=$null;
            candidate_receipt=$null;ready=$null;barrier=$null;controller_error=$null;verdict=$null;
            active_deadline_seconds=15;settle_deadline_seconds=5}
        $all.Add($row)
        $activeActor=$null;$activeCandidate=$null
        try {
            $activeActor=Start-OwnedChild 'observer-actor' $name $scope $nonce
            $actorCount++
            while (-not [IO.File]::Exists((Join-Path $scope 'actor-ready.json'))) {
                if ($activeActor.process.HasExited) { throw 'Phase B actor exited before independent freeze.' }
                if ($trialClock.Elapsed.TotalSeconds -ge 15) { throw 'Phase B actor preparation exceeded 15 seconds.' }
                Start-Sleep -Milliseconds 50
            }
            $ready=Get-Content -LiteralPath (Join-Path $scope 'actor-ready.json') -Raw | ConvertFrom-Json -AsHashtable
            if ($ready.trial -cne $name -or $ready.source.commit -cne $source.commit) {
                throw 'Phase B actor readiness is not bound to this trial/source.'
            }
            $row.ready=$ready
            $activeCandidate=Start-OwnedChild 'candidate' $name $scope $nonce
            $nativeTrialCount++
            $goWritten=$false;$deathAtBarrier=$false
            while (-not $activeCandidate.process.HasExited) {
                if ($trialClock.Elapsed.TotalSeconds -ge 15) { throw 'Phase B active trial exceeded 15 seconds.' }
                if ($name -eq 'B4' -and -not $goWritten -and
                    [IO.File]::Exists((Join-Path $scope 'candidate-acquired.json'))) {
                    Write-Marker (Join-Path $scope 'actor-go.json') ([ordered]@{phase='post-acquisition';trial=$name})
                    $goWritten=$true
                }
                if ($name -eq 'B6' -and -not $goWritten -and
                    [IO.File]::Exists((Join-Path $scope 'candidate-barrier.json'))) {
                    Write-Marker (Join-Path $scope 'actor-go.json') ([ordered]@{phase='post-last-close';trial=$name})
                    $goWritten=$true
                }
                if ($name -eq 'B7' -and [IO.File]::Exists((Join-Path $scope 'candidate-barrier.json'))) {
                    $row.barrier=Get-Content -LiteralPath (Join-Path $scope 'candidate-barrier.json') -Raw |
                        ConvertFrom-Json -AsHashtable
                    if ($row.barrier.trial -cne 'B7' -or
                        $row.barrier.state -cne 'staged' -or
                        $row.barrier.stage_calls -lt 2 -or
                        $row.barrier.commit_calls -ne 0 -or
                        -not $row.barrier.target_handles_closed) {
                        throw 'Phase B B7 barrier is not a precommit last-close state.'
                    }
                    Stop-OwnedChild $activeCandidate
                    $deathAtBarrier=$true
                    break
                }
                Start-Sleep -Milliseconds 50
            }
            if ($name -eq 'B7' -and -not $deathAtBarrier) {
                throw 'Phase B B7 candidate exited before owned-death barrier.'
            }
            if ($deathAtBarrier -and
                -not $activeCandidate.process.WaitForExit([Math]::Max(0,
                    [Math]::Min(5000,20000-[int]$trialClock.ElapsedMilliseconds)))) {
                throw 'Phase B B7 owned candidate death could not be confirmed.'
            }
            if ($name -in @('B2','B6') -and
                [IO.File]::Exists((Join-Path $scope 'candidate-barrier.json'))) {
                $row.barrier=Get-Content -LiteralPath (Join-Path $scope 'candidate-barrier.json') -Raw |
                    ConvertFrom-Json -AsHashtable
            }
            if ($name -in @('B2','B4','B6') -and -not $goWritten -and
                -not [IO.File]::Exists((Join-Path $scope 'candidate-barrier.json'))) {
                Write-Marker (Join-Path $scope 'actor-cancel.json') ([ordered]@{reason='candidate-rejected-before-barrier'})
            }
            Write-Marker (Join-Path $scope 'candidate-done.json') ([ordered]@{trial=$name;
                worker_exit_observed=$activeCandidate.process.HasExited;death_at_barrier=$deathAtBarrier})
            while (-not $activeActor.process.HasExited) {
                if ($trialClock.Elapsed.TotalSeconds -ge 15) { throw 'Phase B actor postproof exceeded 15 seconds.' }
                Start-Sleep -Milliseconds 50
            }
        } catch {
            $row.controller_error=[ordered]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
        } finally {
            $settle=[Diagnostics.Stopwatch]::StartNew()
            try { Stop-OwnedChild $activeCandidate; Stop-OwnedChild $activeActor }
            catch {
                if ($null -eq $row.controller_error) {
                    $row.controller_error=[ordered]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
                }
            }
            $remaining=[Math]::Max(0,[Math]::Min(5000,20000-[int]$trialClock.ElapsedMilliseconds))
            $row.candidate=Complete-OwnedChild $activeCandidate $remaining
            $remaining=[Math]::Max(0,[Math]::Min(5000-[int]$settle.ElapsedMilliseconds,
                20000-[int]$trialClock.ElapsedMilliseconds))
            $row.actor=Complete-OwnedChild $activeActor $remaining
            $row.completed_utc=[DateTime]::UtcNow.ToString('o')
            $row.elapsed_ms=[int]$trialClock.ElapsedMilliseconds
            if ($null -ne $row.actor -and $row.actor.closed) { $activeActor=$null }
            if ($null -ne $row.candidate -and $row.candidate.closed) { $activeCandidate=$null }
        }
        if ($null -eq $row.controller_error) {
            try {
                $row.actor_receipt=Read-WorkerRecord $row.actor 'observer-actor' $name
                if ($name -ne 'B7') {
                    $row.candidate_receipt=Read-WorkerRecord $row.candidate 'candidate' $name
                }
                $row.verdict=Assert-PhaseBTrialReceipt $row $name $source
            } catch {
                $row.controller_error=[ordered]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
            }
        }
        [Console]::Out.WriteLine('DR_PHASE_B_TRIAL ' + ($row | ConvertTo-Json -Depth 16 -Compress))
        if ($null -ne $row.controller_error -or $row.elapsed_ms -gt 20000 -or
            $row.verdict -in @('positive-control-rejected-preserved-mechanism-falsified',
                'required-barrier-unverified-candidate-rejected-preserved',
                'mapping-write-barrier-unverified-acquisition-rejected-preserved')) {
            throw "Phase B $name stopped on incomplete/unknown evidence."
        }
    }
} catch {
    $controllerFailure=[ordered]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
} finally {
    foreach ($child in @($activeCandidate,$activeActor)) {
        if ($null -ne $child) {
            try { Stop-OwnedChild $child } catch { }
        }
    }
}
$suite=[ordered]@{schema='dark180-exact-manifest-phase-b-controller-v1';
    source=$source;os=[Environment]::OSVersion.VersionString;
    utc=[DateTime]::UtcNow.ToString('o');trial_count=$all.Count;
    candidate_process_count=$nativeTrialCount;actor_process_count=$actorCount;
    suite_elapsed_ms=[int]$suiteClock.ElapsedMilliseconds;trials=@($all);
    error=$controllerFailure;gate1='unverified';target_collection=0;product=0}
[Console]::Out.WriteLine('DR_PHASE_B_CONTROLLER ' + ($suite | ConvertTo-Json -Depth 18 -Compress))
if ($null -ne $controllerFailure -or $all.Count -ne 7 -or $nativeTrialCount -ne 7 -or
    $actorCount -ne 7 -or
    $suiteClock.Elapsed.TotalSeconds -gt 180) { exit 1 }
Write-Host 'Phase B seven-trial fixture falsification completed; Gate 1 remains unverified.'
