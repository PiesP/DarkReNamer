[CmdletBinding()]
param(
    [ValidateSet('controller','candidate','observer-actor')]
    [string]$Mode='controller',
    [ValidateSet('B1','B2','B3','B4','B5','B6L','B7')]
    [string]$Trial,
    [string]$Scope,
    [string]$BatchGuid,
    [string]$RunsRootId,
    [string]$BatchRootId,
    [string]$BatchAuthoritySha,
    [string]$BatchVmGuid,
    [string]$BatchSid
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
$trials=@('B1','B2','B3','B4','B5','B6L','B7')

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
    $record=[ordered]@{schema='dark180-phase-b-marker-v2';
        scope=[IO.Path]::GetDirectoryName($Path);
        marker=[IO.Path]::GetFileName($Path);value=$Value}
    Write-NewText $Path (($record | ConvertTo-Json -Depth 8 -Compress) + "`n")
    Write-NewText ($Path + '.ready') '' # Published only after data flush and close.
}
function Read-Marker([string]$Path) {
    if (-not [IO.File]::Exists(($Path + '.ready'))) {
        throw "Phase B marker is not published: $([IO.Path]::GetFileName($Path))"
    }
    if (-not [IO.File]::Exists($Path)) {
        throw 'Phase B marker readiness exists without data.'
    }
    try { $record=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw 'Phase B published marker JSON is malformed.' }
    if ($null -eq $record -or $record.schema -cne 'dark180-phase-b-marker-v2' -or
        $record.scope -cne [IO.Path]::GetDirectoryName($Path) -or
        $record.marker -cne [IO.Path]::GetFileName($Path) -or
        -not $record.Contains('value') -or $null -eq $record.value) {
        throw 'Phase B published marker scope, name or value differs.'
    }
    return $record.value
}
function Test-MarkerReady([string]$Path) {
    if (-not [IO.File]::Exists(($Path + '.ready'))) { return $false }
    $null=Read-Marker $Path
    return $true
}
function Wait-Marker([string]$Path,[int]$Milliseconds) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-MarkerReady $Path)) {
        if ($clock.ElapsedMilliseconds -ge $Milliseconds) { throw "Phase B marker unavailable: $([IO.Path]::GetFileName($Path))" }
        Start-Sleep -Milliseconds 50
    }
    return Read-Marker $Path
}
function Wait-ActorBarrier([string]$Path,[int]$Milliseconds) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-MarkerReady $Path)) {
        if (Test-MarkerReady (Join-Path $Scope 'actor-cancel.json')) { return $false }
        if ($clock.ElapsedMilliseconds -ge $Milliseconds) {
            throw "Phase B actor barrier unavailable: $([IO.Path]::GetFileName($Path))"
        }
        Start-Sleep -Milliseconds 50
    }
    return $true
}
function Get-PhaseBExceptionChain([Exception]$Failure) {
    $queue=[Collections.Generic.Queue[Exception]]::new()
    $seen=[Collections.Generic.HashSet[Exception]]::new()
    $rows=[Collections.Generic.List[object]]::new()
    $queue.Enqueue($Failure)
    while ($queue.Count -gt 0) {
        $item=$queue.Dequeue()
        if ($null -eq $item -or -not $seen.Add($item)) { continue }
        if ($rows.Count -ge 8) { throw 'Phase B exception chain exceeded eight nodes.' }
        $methods=[Collections.Generic.List[string]]::new()
        $frames=([Diagnostics.StackTrace]::new($item,$false)).GetFrames()
        if ($null -ne $frames) {
            foreach ($frame in @($frames | Select-Object -First 32)) {
                $method=$frame.GetMethod()
                if ($null -ne $method -and $null -ne $method.DeclaringType) {
                    $methods.Add($method.DeclaringType.FullName + '::' + $method.Name)
                }
            }
        }
        $nativeCode=$null
        if ($item -is [ComponentModel.Win32Exception]) { $nativeCode=$item.NativeErrorCode }
        $rows.Add([ordered]@{type=$item.GetType().FullName;message=$item.Message;
            hresult=$item.HResult;native_error=$nativeCode;method_frames=@($methods)})
        if ($null -ne $item.InnerException) { $queue.Enqueue($item.InnerException) }
        if ($item -is [AggregateException]) {
            foreach ($inner in $item.InnerExceptions) { $queue.Enqueue($inner) }
        }
    }
    return $rows.ToArray()
}
function Get-ExactOpenWriterRefusalCode($Chain) {
    if ($null -eq $Chain -or @($Chain).Count -eq 0 -or @($Chain).Count -gt 8) { return $null }
    $native=@($Chain | Where-Object { $null -ne $_.native_error })
    if ($native.Count -ne 1 -or $native[0].type -cne 'System.ComponentModel.Win32Exception' -or
        $native[0].native_error -notin @(1224,6800) -or
        @($native[0].method_frames) -cnotcontains
            'DarkReNamerVmOwnedRootGuard+ExactSetEngine::OpenWriter') {
        return $null
    }
    return [int]$native[0].native_error
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
function Read-SecurityControl([string]$Path,[bool]$Directory=$false) {
    $acl=if($Directory){
        [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($Path))
    }else{[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($Path))}
    $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $sections=[Security.AccessControl.AccessControlSections]::Owner -bor
        [Security.AccessControl.AccessControlSections]::Group -bor
        [Security.AccessControl.AccessControlSections]::Access
    $sddl=$acl.GetSecurityDescriptorSddlForm($sections)
    return [ordered]@{owner_sha256=(Hash-Text $owner);sddl_sha256=(Hash-Text $sddl)}
}
function Convert-NativeDescriptor($Snapshot) {
    if ($null -eq $Snapshot) { return $null }
    $dacl=$null
    if ($null -ne $Snapshot.Dacl) {
        $dacl=[ordered]@{present=$Snapshot.Dacl.Present;
            defaulted=$Snapshot.Dacl.Defaulted;null=$Snapshot.Dacl.Null;
            allocation_bytes=$Snapshot.Dacl.AllocationBytes;
            used_bytes=$Snapshot.Dacl.UsedBytes;free_bytes=$Snapshot.Dacl.FreeBytes;
            ace_count=$Snapshot.Dacl.AceCount;used_sha256=$Snapshot.Dacl.UsedSha256}
    }
    return [ordered]@{sddl_sha256=(Hash-Text $Snapshot.Sddl);
        components_observed=$Snapshot.ComponentsObserved;
        components_error=$Snapshot.ComponentsError;
        components_exception=$Snapshot.ComponentsException;
        owner_sid_bytes=$Snapshot.OwnerSidBytes;owner_sid_sha256=$Snapshot.OwnerSidSha256;
        group_sid_bytes=$Snapshot.GroupSidBytes;group_sid_sha256=$Snapshot.GroupSidSha256;
        control_word=$Snapshot.ControlWord;control_revision=$Snapshot.ControlRevision;
        dacl=$dacl}
}
function Test-NativeDescriptorComplete($Value) {
    if ($null -eq $Value -or $null -eq $Value.dacl) { return $false }
    if (-not $Value.components_observed -or $Value.components_error -ne 0 -or
        $Value.components_exception -or
        $Value.sddl_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Value.owner_sid_bytes -lt 8 -or $Value.owner_sid_bytes -gt 68 -or
        $Value.owner_sid_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Value.group_sid_bytes -lt 8 -or $Value.group_sid_bytes -gt 68 -or
        $Value.group_sid_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Value.control_word -lt 0 -or $Value.control_word -gt 65535 -or
        ($Value.control_word -band 0x00c0) -ne 0 -or
        $Value.control_revision -ne 1 -or
        -not $Value.dacl.present -or $Value.dacl.null -or
        ((($Value.control_word -band 0x0004) -ne 0) -ne [bool]$Value.dacl.present) -or
        ((($Value.control_word -band 0x0008) -ne 0) -ne [bool]$Value.dacl.defaulted) -or
        $Value.dacl.allocation_bytes -lt 8 -or $Value.dacl.allocation_bytes -gt 65535 -or
        $Value.dacl.used_bytes -lt 8 -or
        $Value.dacl.used_bytes -gt $Value.dacl.allocation_bytes -or
        $Value.dacl.free_bytes -lt 0 -or
        ($Value.dacl.used_bytes+$Value.dacl.free_bytes) -gt $Value.dacl.allocation_bytes -or
        $Value.dacl.ace_count -lt 0 -or
        $Value.dacl.ace_count -gt [Math]::Floor(($Value.dacl.used_bytes-8)/4) -or
        $Value.dacl.used_sha256 -cnotmatch '^[0-9a-f]{64}$') { return $false }
    return $true
}
function Test-NativeDescriptorBaseline($Actual,$Baseline) {
    if (-not (Test-NativeDescriptorComplete $Actual) -or
        -not (Test-NativeDescriptorComplete $Baseline)) { return $false }
    foreach ($field in @('sddl_sha256','owner_sid_bytes','owner_sid_sha256','group_sid_bytes',
            'group_sid_sha256','control_revision')) {
        if ($Actual[$field] -cne $Baseline[$field]) { return $false }
    }
    if (($Actual.control_word -band 0x150f) -ne ($Baseline.control_word -band 0x150f)) {
        return $false
    }
    foreach ($field in @('present','defaulted','null','allocation_bytes','used_bytes',
            'free_bytes','ace_count','used_sha256')) {
        if ($Actual.dacl[$field] -cne $Baseline.dacl[$field]) { return $false }
    }
    return $true
}
function Test-NativeDaclSupport($Before,$Expected,$After) {
    if (-not (Test-NativeDescriptorComplete $Before) -or
        -not (Test-NativeDescriptorComplete $After) -or
        -not (Test-NativeDescriptorComplete $Expected)) { return $false }
    if ($Before.owner_sid_bytes -ne $After.owner_sid_bytes -or
        $Before.owner_sid_sha256 -cne $After.owner_sid_sha256 -or
        $Before.group_sid_bytes -ne $After.group_sid_bytes -or
        $Before.group_sid_sha256 -cne $After.group_sid_sha256 -or
        $Before.control_revision -ne $After.control_revision -or
        $After.dacl.defaulted -or -not $After.dacl.present -or $After.dacl.null) {
        return $false
    }
    if ($After.dacl.used_bytes -ne $Expected.dacl.used_bytes -or
        $After.dacl.ace_count -ne $Expected.dacl.ace_count -or
        $After.dacl.used_sha256 -cne $Expected.dacl.used_sha256 -or
        ($After.dacl.used_bytes -eq $Before.dacl.used_bytes -and
         $After.dacl.ace_count -eq $Before.dacl.ace_count -and
         $After.dacl.used_sha256 -ceq $Before.dacl.used_sha256)) { return $false }
    $beforeProjection=$Before.control_word -band 0x150f
    $afterProjection=$After.control_word -band 0x150f
    if (($afterProjection -band 0x0004) -eq 0 -or
        ($afterProjection -band 0x0008) -ne 0 -or
        ((($beforeProjection -bxor $afterProjection) -band (-bnot 0x050c)) -ne 0)) {
        return $false
    }
    return $true
}
function Convert-LateDaclResult($Result) {
    return [ordered]@{open_admitted=$Result.OpenAdmitted;open_error=$Result.OpenError;
        identity_observed=$Result.IdentityObserved;identity_error=$Result.IdentityError;
        identity_exception=$Result.IdentityException;file_id=$Result.FileId;
        identity_matches=$Result.IdentityMatches;
        before_observed=$Result.BeforeObserved;before_error=$Result.BeforeError;
        before_exception=$Result.BeforeException;
        before_sha256=$(if($Result.BeforeObserved){Hash-Text $Result.BeforeSddl}else{$null});
        before_native=(Convert-NativeDescriptor $Result.BeforeNative);
        set_attempted=$Result.SetAttempted;set_error=$Result.SetError;
        set_exception=$Result.SetException;
        after_observed=$Result.AfterObserved;after_error=$Result.AfterError;
        after_exception=$Result.AfterException;
        after_sha256=$(if($Result.AfterObserved){Hash-Text $Result.AfterSddl}else{$null});
        after_native=(Convert-NativeDescriptor $Result.AfterNative);
        close=$Result.Close}
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
function Assert-RunBatchBinding([string]$ScopePath,[string]$SourceSha,
        [switch]$ParentOnly) {
    if ($BatchGuid -cnotmatch '^[0-9a-f]{32}$' -or
        $RunsRootId -cnotmatch '^[0-9a-f]{48}$' -or
        $BatchRootId -cnotmatch '^[0-9a-f]{48}$' -or
        $BatchAuthoritySha -cnotmatch '^[0-9a-f]{64}$' -or
        $BatchVmGuid -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        [guid]$BatchVmGuid -eq [guid]::Empty -or
        [string]::IsNullOrEmpty($BatchSid) -or
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $BatchSid -or
        $SourceSha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Run batch frozen source, VM, SID or identity is invalid.'
    }
    $profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $runsRoot=Join-Path (Join-Path $profile 'AppData/Local/Temp') 'Dark180-TxfPhaseB-runs'
    $batchRoot=Join-Path $runsRoot $BatchGuid
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($ScopePath),$batchRoot,
            [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($ScopePath) -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Run batch scope is outside its exact private batch root.'
    }
    $chain=[Collections.Generic.List[IO.DirectoryInfo]]::new()
    $checkPath=if($ParentOnly){$batchRoot}else{$ScopePath}
    for($item=[IO.DirectoryInfo]::new($checkPath);$null -ne $item;$item=$item.Parent){$chain.Add($item)}
    for($index=$chain.Count-1;$index -ge 0;$index--){
        if (-not $chain[$index].Exists -or
            (($chain[$index].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Run batch ancestry is absent or reparse.'
        }
    }
    $privatePaths=if($ParentOnly){@($runsRoot,$batchRoot)}else{@($runsRoot,$batchRoot,$ScopePath)}
    foreach($directory in $privatePaths) {
        Assert-PrivateDirectory $directory
    }
    if ([DarkPhaseBFixtureObserver]::IdentityOf($runsRoot,$true) -cne $RunsRootId -or
        [DarkPhaseBFixtureObserver]::IdentityOf($batchRoot,$true) -cne $BatchRootId) {
        throw 'Run batch parent or batch FileID changed.'
    }
    $authorityPath=Join-Path $runsRoot ($BatchGuid+'.authority.txt')
    $info=[IO.FileInfo]::new($authorityPath)
    if (-not $info.Exists -or $info.Length -gt 1024 -or
        (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Run batch authority is absent or reparse.'
    }
    $stream=[IO.FileStream]::new($authorityPath,[IO.FileMode]::Open,
        [IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $info.Refresh()
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $stream.Length -gt 1024) { throw 'Run batch authority changed or grew.' }
        $bounded=[byte[]]::new(1025);$count=0
        while($count -lt $bounded.Length){
            $read=$stream.Read($bounded,$count,$bounded.Length-$count)
            if($read -eq 0){break};$count+=$read
        }
        if($count -gt 1024 -or $stream.Length -ne $count){
            throw 'Run batch authority grew or was incomplete.'
        }
        $raw=[byte[]]::new($count)
        [Array]::Copy($bounded,$raw,$count)
    } finally { $stream.Dispose() }
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
    if ($sha -cne $BatchAuthoritySha) { throw 'Run batch authority bytes changed.' }
    $content=[Text.Encoding]::UTF8.GetString($raw)
    if (-not $content.EndsWith("`n",[StringComparison]::Ordinal) -or
        $content.Contains("`r") -or $content.Contains([char]0)) {
        throw 'Run batch authority encoding changed.'
    }
    $fields=@($content.Substring(0,$content.Length-1).Split("`n"))
    if ($fields.Count -ne 7 -or $fields[0] -cne 'dark240-run-batch-v1' -or
        $fields[1] -cne $SourceSha -or $fields[2] -cne $BatchVmGuid -or
        $fields[3] -cne $BatchSid -or $fields[4] -cne $BatchGuid -or
        $fields[5] -cne $RunsRootId -or $fields[6] -cne $BatchRootId) {
        throw 'Run batch authority fields changed.'
    }
    return [ordered]@{mode='run-scoped-v1';guid=$BatchGuid;
        runs_root_id=$RunsRootId;batch_root_id=$BatchRootId;
        authority_sha256=$BatchAuthoritySha;source_head=$SourceSha;
        vm_guid=$BatchVmGuid;token_sid=$BatchSid}
}
function Test-PartialRunBatchInput([string]$SelectedBatchGuid,[string[]]$Fields,
        [string]$InheritedGuid) {
    if(-not [string]::IsNullOrEmpty($SelectedBatchGuid)){return $false}
    $extras=@($Fields | Where-Object { -not [string]::IsNullOrEmpty($_) })
    return ($extras.Count -ne 0 -or -not [string]::IsNullOrEmpty($InheritedGuid))
}
function Assert-ChildScope {
    if ([string]::IsNullOrWhiteSpace($Scope) -or [string]::IsNullOrWhiteSpace($Trial) -or
        $env:DARK_PHASE_B_NONCE -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Phase B child lacks exact controller-issued capability.'
    }
    $profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $expectedBase=if ($BatchGuid) {
        Join-Path (Join-Path (Join-Path $profile 'AppData/Local/Temp') `
            'Dark180-TxfPhaseB-runs') $BatchGuid
    } else { Join-Path (Join-Path $profile 'AppData/Local/Temp') 'Dark180-TxfPhaseB' }
    if ($BatchGuid -and $BatchGuid -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Phase B child has an invalid run batch GUID.'
    }
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($Scope),$expectedBase,
        [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($Scope) -cnotmatch '^[0-9a-f]{32}$' -or
        ($BatchGuid -and [IO.Path]::GetFileName($Scope) -cne $env:DARK_PHASE_B_NONCE)) {
        throw 'Phase B child scope is outside the exact profile temp root.'
    }
    Assert-PrivateDirectory $Scope
}
function New-ChildDeadline {
    return [DarkPhaseBDeadline]::new(15000)
}

if ($Mode -ne 'controller') {
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
    $lateCapability=$null;$lateDaclCapability=$null;$lateDaclResult=$null
    $baselineControl=$null
    $batchBinding=$null
    try {
        Assert-ChildScope
        if(Test-PartialRunBatchInput $BatchGuid `
                @($RunsRootId,$BatchRootId,$BatchAuthoritySha,$BatchVmGuid,$BatchSid) `
                ([Environment]::GetEnvironmentVariable('DARK_PHASE_B_BATCH_GUID'))){
            throw 'Phase B child received a partial or inherited run batch input.'
        }
        if ($BatchGuid) {
            Add-Type -Path $observerPath -ErrorAction Stop
            $batchBinding=Assert-RunBatchBinding $Scope $sourceSha
        }
        if ($Mode -eq 'observer-actor') {
            if (-not $BatchGuid) { Add-Type -Path $observerPath -ErrorAction Stop }
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
            $rootFields=$rows[0].Split('|');$fileFields=$rows[1].Split('|')
            $rootFrozenSecurity=[ordered]@{
                owner_sha256=(Hash-Text ([Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($rootFields[5]))));
                sddl_sha256=(Hash-Text ([Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($rootFields[6]))))}
            $fileFrozenSecurity=[ordered]@{
                owner_sha256=(Hash-Text ([Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($fileFields[5]))));
                sddl_sha256=(Hash-Text ([Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($fileFields[6]))))}
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
                manifest_digest=$digest;approved_before=$known;
                root_security=$rootFrozenSecurity;approved_security=$fileFrozenSecurity})
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
            $b4EarlyCancel=$false
            if ($Trial -eq 'B2') {
                $lateCapability=[DarkPhaseBFixtureActors]::PrepareLateChild($Scope,$target)
            }
            if ($Trial -eq 'B6L') {
                $approvedFields=$rows[1].Split('|')
                $baselineOwner=[Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($approvedFields[5]))
                $baselineSddl=[Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($approvedFields[6]))
                $baselineControl=[ordered]@{owner_sha256=(Hash-Text $baselineOwner);
                    sddl_sha256=(Hash-Text $baselineSddl)}
                $lateDaclCapability=[DarkPhaseBFixtureActors]::PrepareLateDacl(
                    $Scope,$target,$approvedFields[2])
                if ($lateDaclCapability.BaselineSddl -cne $baselineSddl -or
                    $lateDaclCapability.OriginalId -cne $approvedFields[2]) {
                    throw 'B6L independent freeze differs from the no-held-handle preparation.'
                }
                $baselineNative=Convert-NativeDescriptor $lateDaclCapability.BaselineNative
                $proposedNative=Convert-NativeDescriptor $lateDaclCapability.ProposedNative
                if ($baselineNative.sddl_sha256 -cne $baselineControl.sddl_sha256 -or
                    -not (Test-NativeDescriptorComplete $baselineNative) -or
                    -not (Test-NativeDescriptorComplete $proposedNative)) {
                    throw 'B6L bounded native preparation components are incomplete.'
                }
                $events.Add([ordered]@{phase='B6L-prepared-no-held-handle';
                    approved_id=$approvedFields[2];baseline=$baselineControl;
                    proposed_sddl_sha256=(Hash-Text $lateDaclCapability.ProposedSddl);
                    baseline_native=$baselineNative;proposed_native=$proposedNative;
                    preparation_close=$lateDaclCapability.PreparationClose;
                    requested_access='READ_CONTROL|WRITE_DAC|WRITE_OWNER';share='READ|WRITE|DELETE';
                    disposition='OPEN_EXISTING|OPEN_REPARSE_POINT'})
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
                } else {
                    $b4EarlyCancel=$true
                    $events.Add([ordered]@{phase='required-barrier-unverified';reason='candidate-rejected-before-barrier'})
                }
            } elseif ($Trial -eq 'B6L') {
                if (Wait-ActorBarrier (Join-Path $Scope 'actor-go.json') 12000) {
                    $lateDaclResult=$lateDaclCapability.AttemptLate()
                    $lateReceipt=Convert-LateDaclResult $lateDaclResult
                    $events.Add([ordered]@{phase='B6L-late-metadata-probe';data=$lateReceipt})
                    Write-Marker (Join-Path $Scope 'actor-done.json') ([ordered]@{
                        phase='B6L-late-probe-complete';data=$lateReceipt})
                } else { $events.Add([ordered]@{phase='required-barrier-unverified';reason='candidate-rejected-before-barrier'}) }
            }
            $candidateDone=Wait-Marker (Join-Path $Scope 'candidate-done.json') 12000
            if ($Trial -eq 'B6L' -and $null -ne $lateDaclResult) {
                if ($candidateDone.trial -cne 'B6L' -or -not $candidateDone.worker_exit_observed -or
                    -not $candidateDone.candidate_rollback_confirmed -or
                    $candidateDone.death_at_barrier) {
                    throw 'B6L late handle must remain held until confirmed candidate exit and rollback.'
                }
                $lateClose=$lateDaclCapability.CloseLateOnce()
                $events.Add([ordered]@{phase='B6L-late-handle-close-after-candidate-exit';
                    data=$lateClose})
                if (-not $lateClose.Confirmed) { throw 'B6L late handle closure is unknown.' }
                $preRoot=Path-State $target
                $preApproved=Read-KnownBytes (Join-Path $target 'approved.bin') $false
                $preSentinel=Read-KnownBytes (Join-Path $Scope 'sentinel.bin') $false
                $preRootId=[DarkPhaseBFixtureObserver]::IdentityOf($target,$true)
                $preApprovedId=[DarkPhaseBFixtureObserver]::IdentityOf(
                    (Join-Path $target 'approved.bin'),$false)
                $preRootSecurity=Read-SecurityControl $target $true
                $preSecurity=Read-SecurityControl (Join-Path $target 'approved.bin')
                $preSupport=[ordered]@{phase='B6L-independent-postrollback-before-support';
                    root=$preRoot;root_id=$preRootId;approved_id=$preApprovedId;
                    approved=$preApproved;sentinel=$preSentinel;root_security=$preRootSecurity;
                    security=$preSecurity}
                $events.Add($preSupport)
                $originalBytes=[byte[]](9,18,27,36,45,54)
                $baselineConfirmed=$preRoot.status -ceq 'present' -and -not $preRoot.reparse -and
                    $preRootId -ceq $rootId -and $preApprovedId -ceq $approvedFields[2] -and
                    $preApproved.base64 -ceq [Convert]::ToBase64String($originalBytes) -and
                    $preApproved.sha256 -ceq ([Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData($originalBytes)).ToLowerInvariant()) -and
                    $preSentinel.base64 -ceq [Convert]::ToBase64String([byte[]](72,63,54,45,36,27)) -and
                    $preRootSecurity.owner_sha256 -ceq $rootFrozenSecurity.owner_sha256 -and
                    $preRootSecurity.sddl_sha256 -ceq $rootFrozenSecurity.sddl_sha256 -and
                    $preSecurity.owner_sha256 -ceq $baselineControl.owner_sha256 -and
                    $preSecurity.sddl_sha256 -ceq $baselineControl.sddl_sha256
                $knownLateRefusal=($lateReceipt.open_admitted -eq $false -and
                    $lateReceipt.open_error -in @(32,6800)) -or
                    ($lateReceipt.open_admitted -eq $true -and
                     $lateReceipt.identity_observed -and $lateReceipt.identity_matches -and
                     $lateReceipt.before_observed -and
                     $lateReceipt.before_sha256 -ceq $baselineControl.sddl_sha256 -and
                     (Test-NativeDescriptorBaseline $lateReceipt.before_native $baselineNative) -and
                     $lateReceipt.set_attempted -and $null -eq $lateReceipt.set_exception -and
                     $lateReceipt.set_error -in @(32,6800) -and
                     $lateReceipt.after_observed -and
                     $lateReceipt.after_sha256 -ceq $baselineControl.sddl_sha256 -and
                     (Test-NativeDescriptorBaseline $lateReceipt.after_native $baselineNative))
                if ($baselineConfirmed -and $knownLateRefusal) {
                    $supportResult=$lateDaclCapability.AttemptSupport($true,$true)
                    $events.Add([ordered]@{phase='B6L-after-release-support-probe';
                        data=(Convert-LateDaclResult $supportResult)})
                } else {
                    $events.Add([ordered]@{phase='B6L-support-skipped';
                        baseline_confirmed=$baselineConfirmed;known_late_refusal=$knownLateRefusal})
                }
            }
            if ($b4EarlyCancel) {
                if ($candidateDone.trial -cne 'B4' -or -not $candidateDone.worker_exit_observed -or
                    $candidateDone.death_at_barrier) {
                    throw 'B4 mapping support control lacks a confirmed candidate exit.'
                }
                $preControl=Read-KnownBytes (Join-Path $target 'approved.bin') $false
                $events.Add([ordered]@{phase='approved-before-mapping-support-control';
                    candidate_exit_confirmed=$true;data=$preControl})
                if ($preControl.status -cne 'present' -or
                    $preControl.base64 -cne [Convert]::ToBase64String([byte[]](9,18,27,36,45,54)) -or
                    $preControl.sha256 -cne ([Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData([byte[]](9,18,27,36,45,54))).ToLowerInvariant())) {
                    throw 'B4 approved bytes changed before the held-mapping support control.'
                }
                $mappingWritten=$false;$mappingError=$null
                try { $actorResource.WriteOne(82);$mappingWritten=$true }
                catch { $mappingError=[ordered]@{type=$_.Exception.GetType().FullName;
                    message=$_.Exception.Message} }
                $events.Add([ordered]@{phase='held-mapping-after-candidate-exit-support-control';
                    candidate_exit_confirmed=$true;byte=82;written=$mappingWritten;error=$mappingError})
            }
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
                if ($Trial -eq 'B6L') { $post.root_security=Read-SecurityControl $target $true }
            }
            if ($approvedAfter.status -eq 'present') {
                $post.approved_id=[DarkPhaseBFixtureObserver]::IdentityOf(
                    (Join-Path $target 'approved.bin'),$false)
                $post.approved_sddl_sha256=Hash-Text (
                    (Get-Acl -LiteralPath (Join-Path $target 'approved.bin')).Sddl)
                if ($Trial -eq 'B6L') {
                    $post.approved_security=Read-SecurityControl (Join-Path $target 'approved.bin')
                }
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
                batch_binding=$batchBinding;
                source=$source;scope=$Scope;events=@($events);status='completed';postproof=$post;
                gate1='unverified';target_collection=0;product=0} | ConvertTo-Json -Depth 12 -Compress)))
        } else {
            . $modulePath
            Add-Type -TypeDefinition $script:DrOwnedRootGuardSource -ErrorAction Stop
            $status='not-started'
            try {
                $lease=if ($BatchGuid) {
                    [DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease]::PrepareRunFixtureOnly(
                        $Scope,$target,$env:DARK_PHASE_B_NONCE,$sourceSha,
                        $BatchGuid,$BatchVmGuid,$BatchSid,$RunsRootId,$BatchRootId,
                        $BatchAuthoritySha)
                } else {
                    [DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease]::PrepareFixtureOnly(
                        $Scope,$target,$env:DARK_PHASE_B_NONCE,$sourceSha)
                }
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
                if ($Trial -in @('B2','B6L','B7')) {
                    Write-Marker (Join-Path $Scope 'candidate-barrier.json') ([ordered]@{trial=$Trial;
                        state=$lease.LeaseState;stage_calls=$lease.StageCalls;
                        target_handles_closed=$lease.TargetHandlesClosed;
                        close_receipts=$lease.CloseReceipts;commit_calls=$lease.CommitCalls})
                }
                if ($Trial -in @('B2','B6L')) { $null=Wait-Marker (Join-Path $Scope 'actor-done.json') 10000 }
                if ($Trial -eq 'B7') {
                    $null=Wait-Marker (Join-Path $Scope 'candidate-release-should-not-exist.json') 12000
                    throw 'B7 candidate was released instead of killed at the precommit barrier.'
                }
                if ($Trial -in @('B2','B6L')) {
                    if (-not $lease.Abort()) { throw "${Trial} intentional rollback outcome is unknown." }
                    $status=if($Trial -eq 'B2'){'intentional-rollback-post-barrier'}
                        else {'intentional-rollback-B6L-post-barrier'}
                } else {
                $lease.CommitOnce((Join-Path $Scope 'predelete.txt'))
                $status='commit-call-succeeded-poststate-unverified'
                }
            } catch {
                $status='rejected-or-unknown'
                $workerError=[ordered]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message;
                    error_id=$_.FullyQualifiedErrorId;
                    exception_chain=@(Get-PhaseBExceptionChain $_.Exception)}
            } finally {
                if ($null -ne $lease) {
                    try { $lease.Dispose() }
                    catch { $cleanupError=[ordered]@{type=$_.Exception.GetType().FullName;
                        message=$_.Exception.Message;error_id=$_.FullyQualifiedErrorId} }
                }
            }
            [Console]::Out.WriteLine('DR_PHASE_B_CHILD ' + (([ordered]@{
                schema='dark180-exact-manifest-phase-b-child-v1';role='candidate';trial=$Trial;
                batch_binding=$batchBinding;
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
    if ($BatchGuid) {
        foreach ($arg in @('-BatchGuid',$BatchGuid,'-RunsRootId',$RunsRootId,
                '-BatchRootId',$BatchRootId,'-BatchAuthoritySha',$BatchAuthoritySha,
                '-BatchVmGuid',$BatchVmGuid,'-BatchSid',$BatchSid)) {
            $start.ArgumentList.Add($arg)
        }
        $start.Environment['DARK_PHASE_B_BATCH_GUID']=$BatchGuid
    } else { [void]$start.Environment.Remove('DARK_PHASE_B_BATCH_GUID') }
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
    $budget=[Math]::Max(0,$SettleMilliseconds)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $closed=$Child.process.WaitForExit($budget)
    $stdout=$null;$stderr=$null;$capture_error=$null
    if ($closed) {
        try {
            $remaining=[Math]::Max(0,$budget-[int]$clock.ElapsedMilliseconds)
            $capture=[Threading.Tasks.Task]::WhenAll(
                [Threading.Tasks.Task[]]@($Child.stdout_task,$Child.stderr_task))
            if (-not $capture.Wait($remaining)) {
                $capture_error='Redirected child output did not complete within the owned closure budget.'
            }
        } catch { $capture_error=$_.Exception.Message }
        if ($Child.stdout_task.IsCompleted) {
            try { $stdout=$Child.stdout_task.GetAwaiter().GetResult() }
            catch { if ($null -eq $capture_error) { $capture_error=$_.Exception.Message } }
        }
        if ($Child.stderr_task.IsCompleted) {
            try { $stderr=$Child.stderr_task.GetAwaiter().GetResult() }
            catch { if ($null -eq $capture_error) { $capture_error=$_.Exception.Message } }
        }
        if ($null -eq $capture_error -and ($null -eq $stdout -or $null -eq $stderr)) {
            $capture_error='Redirected child output is incomplete.'
        }
    }
    $row=[ordered]@{role=$Child.role;pid=$Child.pid;started_utc=$Child.started_utc;
        completed_utc=[DateTime]::UtcNow.ToString('o');closed=$closed;
        kill_requested=$Child.kill_requested;
        exit_code=$(if($closed){$Child.process.ExitCode}else{$null});
        stdout=$stdout;stderr=$stderr;capture_error=$capture_error}
    if ($closed) { $Child.process.Dispose() }
    return $row
}
function Observe-OwnedChildClosure($Child,[int]$WaitMilliseconds,$Observations,[string]$Phase) {
    $result=Complete-OwnedChild $Child $WaitMilliseconds
    if ($null -ne $result) {
        $Observations.Add([ordered]@{phase=$Phase;wait_budget_ms=$WaitMilliseconds;
            observed_utc=$result.completed_utc;pid=$result.pid;closed=$result.closed;
            kill_requested=$result.kill_requested;exit_code=$result.exit_code;
            capture_error=$result.capture_error})
    }
    return $result
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
function Assert-PhaseB6LReceipt($Row,$Freeze) {
    $candidate=$Row.candidate_receipt
    $post=$Row.actor_receipt.postproof
    if ($candidate.status -cne 'intentional-rollback-B6L-post-barrier' -or
        $candidate.lease_state -cne 'rollback-succeeded' -or
        $candidate.settlement -cne 'rollback-succeeded' -or
        $candidate.stage_calls -ne 2 -or $candidate.commit_calls -ne 0 -or
        $candidate.rollback_calls -ne 1 -or $candidate.cleanup_error -or
        $candidate.closure_unknown -or $null -eq $Row.barrier -or
        $Row.barrier.trial -cne 'B6L' -or $Row.barrier.state -cne 'staged' -or
        $Row.barrier.stage_calls -ne 2 -or $Row.barrier.commit_calls -ne 0 -or
        -not $Row.barrier.target_handles_closed) {
        throw 'B6L lacks an exact last-close barrier and settled intentional rollback.'
    }
    $events=$Row.actor_receipt.events
    $prepared=@($events | Where-Object { $_.phase -ceq 'B6L-prepared-no-held-handle' })
    $late=@($events | Where-Object { $_.phase -ceq 'B6L-late-metadata-probe' })
    $close=@($events | Where-Object { $_.phase -ceq 'B6L-late-handle-close-after-candidate-exit' })
    $before=@($events | Where-Object { $_.phase -ceq 'B6L-independent-postrollback-before-support' })
    $support=@($events | Where-Object { $_.phase -ceq 'B6L-after-release-support-probe' })
    if ($prepared.Count -ne 1 -or $late.Count -ne 1 -or $close.Count -ne 1 -or
        $before.Count -ne 1 -or $prepared[0].approved_id -cne $Freeze.approved_id -or
        $prepared[0].requested_access -cne 'READ_CONTROL|WRITE_DAC|WRITE_OWNER' -or
        $prepared[0].share -cne 'READ|WRITE|DELETE' -or
        $prepared[0].disposition -cne 'OPEN_EXISTING|OPEN_REPARSE_POINT' -or
        -not $prepared[0].preparation_close.Attempted -or
        -not $prepared[0].preparation_close.Confirmed -or
        $prepared[0].preparation_close.NativeError -ne 0 -or
        $prepared[0].preparation_close.ExceptionType) {
        throw 'B6L independent preparation or phase evidence is incomplete.'
    }
    if ($null -eq $Row.late_probe_marker -or
        $Row.late_probe_marker.phase -cne 'B6L-late-probe-complete' -or
        $Row.late_probe_marker.data.open_admitted -ne $late[0].data.open_admitted -or
        $Row.late_probe_marker.data.open_error -ne $late[0].data.open_error -or
        $Row.late_probe_marker.data.file_id -cne $late[0].data.file_id -or
        $Row.late_probe_marker.data.set_attempted -ne $late[0].data.set_attempted -or
        $Row.late_probe_marker.data.set_error -ne $late[0].data.set_error -or
        $Row.late_probe_marker.data.after_sha256 -cne $late[0].data.after_sha256 -or
        ($Row.late_probe_marker.data.before_native | ConvertTo-Json -Depth 8 -Compress) -cne
            ($late[0].data.before_native | ConvertTo-Json -Depth 8 -Compress) -or
        ($Row.late_probe_marker.data.after_native | ConvertTo-Json -Depth 8 -Compress) -cne
            ($late[0].data.after_native | ConvertTo-Json -Depth 8 -Compress)) {
        throw 'B6L independently published late operation differs from actor receipt.'
    }
    $baseline=$prepared[0].baseline
    if ($baseline.owner_sha256 -cne $Freeze.approved_security.owner_sha256 -or
        $baseline.sddl_sha256 -cne $Freeze.approved_security.sddl_sha256 -or
        -not (Test-NativeDescriptorComplete $prepared[0].baseline_native) -or
        -not (Test-NativeDescriptorComplete $prepared[0].proposed_native) -or
        $prepared[0].baseline_native.sddl_sha256 -cne $baseline.sddl_sha256) {
        throw 'B6L prepared owner/DACL differs from independently frozen manifest.'
    }
    $original=[byte[]](9,18,27,36,45,54)
    $sentinel=[byte[]](72,63,54,45,36,27)
    $pre=$before[0]
    if ($pre.root.status -cne 'present' -or $pre.root.reparse -or
        $pre.root_id -cne $Freeze.root_id -or $pre.approved_id -cne $Freeze.approved_id -or
        $pre.approved.status -cne 'present' -or
        $pre.approved.base64 -cne [Convert]::ToBase64String($original) -or
        $pre.approved.sha256 -cne ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($original)).ToLowerInvariant()) -or
        $pre.sentinel.base64 -cne [Convert]::ToBase64String($sentinel) -or
        $pre.sentinel.sha256 -cne ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($sentinel)).ToLowerInvariant()) -or
        $pre.root_security.owner_sha256 -cne $Freeze.root_security.owner_sha256 -or
        $pre.root_security.sddl_sha256 -cne $Freeze.root_security.sddl_sha256 -or
        $pre.security.owner_sha256 -cne $baseline.owner_sha256 -or
        $pre.security.sddl_sha256 -cne $baseline.sddl_sha256) {
        throw 'B6L original identity, bytes or owner/DACL changed before support mutation.'
    }
    $native=$late[0].data
    $closeReceipt=$close[0].data
    if (-not $closeReceipt.Confirmed -or
        $closeReceipt.Attempted -ne [bool]$native.open_admitted -or
        $closeReceipt.NativeError -ne 0 -or $closeReceipt.ExceptionType -or
        $closeReceipt.ExceptionMessage) {
        throw 'B6L late metadata handle closure is unknown or mismatched.'
    }
    $refusal=$null
    if (-not $native.open_admitted) {
        if ($native.open_error -notin @(32,6800) -or $native.identity_observed -or
            $native.identity_error -ne 0 -or $native.identity_exception -or $native.file_id -or
            $native.set_attempted -or $native.set_error -ne 0 -or $native.set_exception -or
            $native.before_observed -or $native.before_error -ne 0 -or
            $native.before_exception -or $native.after_observed -or
            $native.after_error -ne 0 -or $native.after_exception -or
            $null -ne $native.before_native -or $null -ne $native.after_native) {
            throw 'B6L late metadata open has an unsupported or ambiguous refusal.'
        }
        $refusal='late-metadata-open-refused-supported-gate1-unverified'
    } else {
        if ($native.open_error -ne 0 -or
            -not $native.identity_observed -or $native.identity_error -ne 0 -or
            $native.identity_exception -or -not $native.identity_matches -or
            $native.file_id -cne $Freeze.approved_id -or
            -not $native.before_observed -or $native.before_error -ne 0 -or
            $native.before_exception -or
            $native.before_sha256 -cne $baseline.sddl_sha256 -or
            -not (Test-NativeDescriptorBaseline $native.before_native $prepared[0].baseline_native) -or
            -not $native.set_attempted -or -not $native.after_observed -or
            $native.after_error -ne 0 -or $native.after_exception -or
            $native.after_sha256 -cne $native.after_native.sddl_sha256) {
            throw 'B6L late metadata identity or security observation is incomplete.'
        }
        if ($native.set_error -eq 0 -and
            $native.after_sha256 -cne $baseline.sddl_sha256) {
            throw 'B6L late DACL mutation succeeded inside the final-close interval.'
        }
        if ($native.set_exception -or $native.set_error -notin @(32,6800) -or
            $native.after_sha256 -cne $baseline.sddl_sha256 -or
            -not (Test-NativeDescriptorBaseline $native.after_native $prepared[0].baseline_native)) {
            throw 'B6L late DACL SetSecurityInfo result is unsupported or changed.'
        }
        $refusal='late-dacl-write-refused-supported-gate1-unverified'
    }
    if ($support.Count -ne 1) { throw 'B6L after-release same-rights positive control is absent.' }
    $positive=$support[0].data
    if (-not $positive.open_admitted -or $positive.open_error -ne 0 -or
        -not $positive.identity_observed -or $positive.identity_error -ne 0 -or
        $positive.identity_exception -or -not $positive.identity_matches -or
        $positive.file_id -cne $Freeze.approved_id -or
        -not $positive.before_observed -or $positive.before_error -ne 0 -or
        $positive.before_exception -or
        $positive.before_sha256 -cne $baseline.sddl_sha256 -or
        -not (Test-NativeDescriptorBaseline $positive.before_native $prepared[0].baseline_native) -or
        -not $positive.set_attempted -or $positive.set_error -ne 0 -or
        $positive.set_exception -or -not $positive.after_observed -or
        $positive.after_error -ne 0 -or $positive.after_exception -or
        $positive.after_sha256 -ceq $positive.before_sha256 -or
        $positive.after_sha256 -cne $positive.after_native.sddl_sha256 -or
        -not (Test-NativeDaclSupport $prepared[0].baseline_native `
            $prepared[0].proposed_native $positive.after_native) -or
        $null -eq $positive.close -or -not $positive.close.Confirmed -or
        -not $positive.close.Attempted -or $positive.close.NativeError -ne 0 -or
        $positive.close.ExceptionType -or $positive.close.ExceptionMessage -or
        $post.approved.status -cne 'present' -or
        $post.approved.base64 -cne [Convert]::ToBase64String($original) -or
        $post.root_security.owner_sha256 -cne $Freeze.root_security.owner_sha256 -or
        $post.root_security.sddl_sha256 -cne $Freeze.root_security.sddl_sha256 -or
        $post.approved_security.owner_sha256 -cne $baseline.owner_sha256 -or
        $post.approved_security.sddl_sha256 -cne $positive.after_sha256) {
        throw 'B6L after-release support lacks actual same-rights DACL mutation and readback.'
    }
    return $refusal
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
        if ($ExpectedTrial -eq 'B6L') { throw 'B6L candidate committed instead of intentionally rolling back.' }
        return 'exact-fixture-deleted-gate1-unverified'
    }
    if ($ExpectedTrial -eq 'B6L') { return Assert-PhaseB6LReceipt $Row $freeze[0] }
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
        @($Row.actor_receipt.events | Where-Object {
            $_.phase -in @('held-mapping-write-attempt',
                'held-mapping-after-candidate-exit-support-control') -and $_.written }).Count -eq 1) {
        [byte[]](82,18,27,36,45,54)
    } else { $approvedBytes }
    if ($post.approved.base64 -cne [Convert]::ToBase64String($expectedApproved) -or
        $post.approved.sha256 -cne ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($expectedApproved)).ToLowerInvariant())) {
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
    if ($ExpectedTrial -eq 'B2' -and
        @($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'required-barrier-unverified' }).Count -eq 1) {
        return 'required-barrier-unverified-candidate-rejected-preserved'
    }
    if ($ExpectedTrial -eq 'B4' -and
        @($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'required-barrier-unverified' }).Count -eq 1) {
        $held=@($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'writable-mapping-held-after-file-close' })
        $normalWrite=@($Row.actor_receipt.events | Where-Object { $_.phase -ceq 'held-mapping-write-attempt' })
        $preControl=@($Row.actor_receipt.events | Where-Object {
            $_.phase -ceq 'approved-before-mapping-support-control' })
        $support=@($Row.actor_receipt.events | Where-Object {
            $_.phase -ceq 'held-mapping-after-candidate-exit-support-control' })
        if ($held.Count -eq 1 -and $normalWrite.Count -eq 0 -and
            $preControl.Count -eq 1 -and $preControl[0].candidate_exit_confirmed -and
            $preControl[0].data.status -ceq 'present' -and
            $preControl[0].data.base64 -ceq [Convert]::ToBase64String($approvedBytes) -and
            $preControl[0].data.sha256 -ceq ([Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($approvedBytes)).ToLowerInvariant()) -and
            $support.Count -eq 1 -and
            $support[0].candidate_exit_confirmed -and $support[0].written -and
            $support[0].byte -eq 82 -and $null -eq $support[0].error -and
            $candidate.stage_calls -eq 0 -and $candidate.commit_calls -eq 0 -and
            $candidate.rollback_calls -eq 1 -and
            $candidate.lease_state -ceq 'rollback-succeeded' -and
            -not $candidate.closure_unknown) {
            $refusalCode=Get-ExactOpenWriterRefusalCode $candidate.error.exception_chain
            if ($refusalCode -eq 1224) {
                return 'safe-prestage-refusal-with-writable-mapping-control'
            }
            if ($refusalCode -eq 6800) {
                return 'prestage-transactional-conflict-with-writable-mapping-control'
            }
        }
        return 'mapping-write-barrier-unverified-acquisition-rejected-preserved'
    }
    return 'candidate-rejected-preserved-gate1-unverified'
}

$suiteClock=[Diagnostics.Stopwatch]::StartNew()
$all=[Collections.Generic.List[object]]::new()
$controllerFailure=$null
$activeActor=$null;$activeCandidate=$null
$nativeTrialCount=0;$actorCount=0
$controllerBatchBinding=$null
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
    if ($BatchGuid) {
        if ($BatchGuid -cnotmatch '^[0-9a-f]{32}$') {
            throw 'Phase B run batch GUID is invalid.'
        }
        Add-Type -Path $observerPath -ErrorAction Stop
        $runsRoot=Join-Path $temp 'Dark180-TxfPhaseB-runs'
        $base=Join-Path $runsRoot $BatchGuid
        if (-not [IO.Directory]::Exists($base)) {
            throw 'Phase B run batch root was not prepared by the outer controller.'
        }
        Assert-PrivateDirectory $runsRoot
        Assert-PrivateDirectory $base
    } else {
        if (@($RunsRootId,$BatchRootId,$BatchAuthoritySha,$BatchVmGuid,$BatchSid) |
                Where-Object { -not [string]::IsNullOrEmpty($_) }) {
            throw 'Phase B legacy fixture received an unpinned batch input.'
        }
        $base=Join-Path $temp 'Dark180-TxfPhaseB'
        if ([IO.Directory]::Exists($base)) { Assert-PrivateDirectory $base }
        else { New-PrivateScope $base }
    }
    foreach ($name in $trials) {
        if ($suiteClock.Elapsed.TotalSeconds -ge 180) { throw 'Phase B 180-second suite cap expired.' }
        $trialClock=[Diagnostics.Stopwatch]::StartNew()
        $nonce=[Guid]::NewGuid().ToString('N')
        $scope=Join-Path $base $nonce
        if($BatchGuid){[void](Assert-RunBatchBinding $scope $sourceSha -ParentOnly)}
        New-PrivateScope $scope
        $batchBinding=if ($BatchGuid) {
            Assert-RunBatchBinding $scope $sourceSha
        } else { $null }
        if ($BatchGuid) {
            if ($null -eq $controllerBatchBinding) { $controllerBatchBinding=$batchBinding }
            elseif (($controllerBatchBinding | ConvertTo-Json -Compress) -cne
                ($batchBinding | ConvertTo-Json -Compress)) {
                throw 'Phase B run batch binding changed between cases.'
            }
        }
        $row=[ordered]@{trial=$name;scope=$scope;started_utc=[DateTime]::UtcNow.ToString('o');
            source=$source;batch_binding=$batchBinding;actor=$null;candidate=$null;actor_receipt=$null;
            candidate_receipt=$null;ready=$null;barrier=$null;late_probe_marker=$null;
            controller_error=$null;verdict=$null;
            closure_observations=[Collections.Generic.List[object]]::new();
            active_deadline_seconds=15;settle_deadline_seconds=5}
        $all.Add($row)
        $activeActor=$null;$activeCandidate=$null
        try {
            $activeActor=Start-OwnedChild 'observer-actor' $name $scope $nonce
            $actorCount++
            while (-not (Test-MarkerReady (Join-Path $scope 'actor-ready.json'))) {
                if ($activeActor.process.HasExited) { throw 'Phase B actor exited before independent freeze.' }
                if ($trialClock.Elapsed.TotalSeconds -ge 15) { throw 'Phase B actor preparation exceeded 15 seconds.' }
                Start-Sleep -Milliseconds 50
            }
            $ready=Read-Marker (Join-Path $scope 'actor-ready.json')
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
                    (Test-MarkerReady (Join-Path $scope 'candidate-acquired.json'))) {
                    Write-Marker (Join-Path $scope 'actor-go.json') ([ordered]@{phase='post-acquisition';trial=$name})
                    $goWritten=$true
                }
                if ($name -eq 'B6L' -and -not $goWritten -and
                    (Test-MarkerReady (Join-Path $scope 'candidate-barrier.json'))) {
                    Write-Marker (Join-Path $scope 'actor-go.json') ([ordered]@{phase='post-last-close';trial=$name})
                    $goWritten=$true
                }
                if ($name -eq 'B7' -and (Test-MarkerReady (Join-Path $scope 'candidate-barrier.json'))) {
                    $row.barrier=Read-Marker (Join-Path $scope 'candidate-barrier.json')
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
            if ($name -in @('B2','B6L') -and
                (Test-MarkerReady (Join-Path $scope 'candidate-barrier.json'))) {
                $row.barrier=Read-Marker (Join-Path $scope 'candidate-barrier.json')
            }
            $b6RollbackConfirmed=$false
            if ($name -eq 'B6L' -and $null -ne $row.barrier) {
                $row.late_probe_marker=Read-Marker (Join-Path $scope 'actor-done.json')
                $activeRemaining=[Math]::Max(0,[Math]::Min(5000,
                    15000-[int]$trialClock.ElapsedMilliseconds))
                $row.candidate=Observe-OwnedChildClosure $activeCandidate $activeRemaining `
                    $row.closure_observations 'B6L-active-candidate-confirmation'
                if (-not $row.candidate.closed) {
                    throw 'B6L candidate process closure is not confirmed.'
                }
                $activeCandidate=$null
                $earlyReceipt=Read-WorkerRecord $row.candidate 'candidate' $name
                $sourceMatches=$true
                foreach ($field in @('commit','fixture_sha256','module_sha256',
                        'observer_sha256','actor_sha256')) {
                    if (-not $earlyReceipt.source.Contains($field) -or
                        $earlyReceipt.source[$field] -cne $source[$field]) { $sourceMatches=$false }
                }
                if (-not $sourceMatches -or $row.candidate.exit_code -ne 0 -or
                    $earlyReceipt.status -cne 'intentional-rollback-B6L-post-barrier' -or
                    $earlyReceipt.cleanup_error -or $earlyReceipt.closure_unknown -or
                    $earlyReceipt.lease_state -cne 'rollback-succeeded' -or
                    $earlyReceipt.settlement -cne 'rollback-succeeded' -or
                    $earlyReceipt.stage_calls -ne 2 -or $earlyReceipt.commit_calls -ne 0 -or
                    $earlyReceipt.rollback_calls -ne 1 -or
                    $row.barrier.trial -cne 'B6L' -or $row.barrier.state -cne 'staged' -or
                    $row.barrier.stage_calls -ne 2 -or $row.barrier.commit_calls -ne 0 -or
                    -not $row.barrier.target_handles_closed) {
                    throw 'B6L candidate exit lacks exact settled rollback and barrier receipts.'
                }
                $row.candidate_receipt=$earlyReceipt
                $b6RollbackConfirmed=$true
            }
            if ($name -in @('B2','B4','B6L') -and -not $goWritten -and
                -not (Test-MarkerReady (Join-Path $scope 'candidate-barrier.json'))) {
                Write-Marker (Join-Path $scope 'actor-cancel.json') ([ordered]@{reason='candidate-rejected-before-barrier'})
            }
            Write-Marker (Join-Path $scope 'candidate-done.json') ([ordered]@{trial=$name;
                worker_exit_observed=$(if($null -ne $row.candidate){$row.candidate.closed}
                    else{$activeCandidate.process.HasExited});
                candidate_rollback_confirmed=$b6RollbackConfirmed;
                death_at_barrier=$deathAtBarrier})
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
            if ($null -eq $row.candidate -or -not $row.candidate.closed) {
                $row.candidate=Observe-OwnedChildClosure $activeCandidate $remaining `
                    $row.closure_observations 'candidate-settle-confirmation'
            }
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
                if ($BatchGuid) {
                    foreach ($receipt in @($row.actor_receipt,$row.candidate_receipt)) {
                        if ($null -eq $receipt) { continue }
                        foreach ($key in @('mode','guid','runs_root_id','batch_root_id',
                                'authority_sha256','source_head','vm_guid','token_sid')) {
                            if ($null -eq $receipt.batch_binding -or
                                $receipt.batch_binding[$key] -cne $row.batch_binding[$key]) {
                                throw "Phase B child changed the frozen batch binding: $key"
                            }
                        }
                    }
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
    source=$source;batch_binding=$controllerBatchBinding;os=[Environment]::OSVersion.VersionString;
    utc=[DateTime]::UtcNow.ToString('o');trial_count=$all.Count;
    candidate_process_count=$nativeTrialCount;actor_process_count=$actorCount;
    suite_elapsed_ms=[int]$suiteClock.ElapsedMilliseconds;trials=@($all);
    error=$controllerFailure;gate1='unverified';target_collection=0;product=0}
[Console]::Out.WriteLine('DR_PHASE_B_CONTROLLER ' + ($suite | ConvertTo-Json -Depth 18 -Compress))
if ($null -ne $controllerFailure -or $all.Count -ne 7 -or $nativeTrialCount -ne 7 -or
    $actorCount -ne 7 -or
    $suiteClock.Elapsed.TotalSeconds -gt 180) { exit 1 }
Write-Host 'Phase B seven-trial fixture falsification completed; Gate 1 remains unverified.'
