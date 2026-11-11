[CmdletBinding()]
param(
    [ValidateSet('controller','overlap','mismatch','close-first','commit-first','abort','late-child')]
    [string] $Mode = 'controller',
    [string] $EvidenceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The isolated TxF diagnostic requires Windows.' }
$nativeSource = Join-Path $PSScriptRoot '../support/txf-identity-handoff-native.cs'
$guardSource = Join-Path $PSScriptRoot '../../modules/powershell/controller-owned-root-guard.ps1'
$caseNames = @('overlap','mismatch','close-first','commit-first','abort','late-child')
$sourceSha = (git -C (Join-Path $PSScriptRoot '../../..') rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceSha -notmatch '^[0-9a-f]{40}$') { throw 'Fixture source is not an exact Git commit.' }
$sourceBinding = [ordered]@{
    source_sha = $sourceSha
    fixture_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    native_sha256 = (Get-FileHash -LiteralPath $nativeSource -Algorithm SHA256).Hash.ToLowerInvariant()
    production_guard_sha256 = (Get-FileHash -LiteralPath $guardSource -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Ordinary([string] $Path) {
    $entry = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Fixture path contains a reparse point.'
    }
}
function New-PrivateDirectory([string] $Path) {
    if ([IO.Directory]::Exists($Path)) { throw 'Private fixture directory already exists.' }
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $security=[Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true,$false)
    $security.SetOwner($current)
    foreach ($sid in @($current,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl',
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
             [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        [void]$security.AddAccessRule($rule)
    }
    [void][IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path),$security)
    $acl=Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected -or
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $current.Value) {
        throw 'Fixture evidence directory ACL was not read back as private.'
    }
    Assert-Ordinary $Path
}
function Hash-File([string] $Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Hash-ExistingStream([string] $Path) {
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
}
function Read-KnownBytes([string] $Path, [bool] $AllowAbsent) {
    if ($AllowAbsent -and -not [IO.File]::Exists($Path)) { return [ordered]@{status='absent'} }
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        if ($stream.Length -gt 64) { throw 'Known fixture byte observation exceeds 64-byte bound.' }
        $bytes=[byte[]]::new([int]$stream.Length)
        $count=$stream.Read($bytes,0,$bytes.Length)
        if ($count -ne $bytes.Length) { throw 'Incomplete known fixture byte observation.' }
        return [ordered]@{status='present';length=$bytes.Length;
            sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();
            bytes_base64=[Convert]::ToBase64String($bytes)}
    } finally { $stream.Dispose() }
}
function Hash-One([byte] $Value) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]@($Value))).ToLowerInvariant()
}
function Hash-Text([string] $Value) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
}
function Assert-IssuedRoot([string] $Path, [string] $ExpectedSource) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $tempBase=Join-Path ([IO.Path]::GetTempPath()) 'Dark180-TxfHandoffPhaseA'
    $base=[IO.Path]::GetFullPath($tempBase).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($full),$base,
            [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($full) -cnotmatch '^[0-9a-f]{32}$' -or
        -not [string]::Equals($full,$Path.TrimEnd([IO.Path]::DirectorySeparatorChar),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Child received a root outside the exact controller-issued temp scope.'
    }
    $walk=[IO.DirectoryInfo]::new($full)
    while ($null -ne $walk) {
        Assert-Ordinary $walk.FullName
        $walk=$walk.Parent
    }
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=Get-Acl -LiteralPath $full
    if (-not $acl.AreAccessRulesProtected -or
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $current.Value) {
        throw 'Controller-issued fixture root lacks exact owner/protected ACL.'
    }
    $allowed=@($current.Value,'S-1-5-18','S-1-5-32-544')
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if ($rules.Count -lt 1 -or @($rules | Where-Object {
        $_.IdentityReference.Value -notin $allowed -or $_.AccessControlType -ne 'Allow' -or
        $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl
    }).Count -ne 0) { throw 'Controller-issued fixture ACL has another writer.' }
    $authority=Join-Path $full 'authority.json'
    Assert-Ordinary $authority
    $record=Get-Content -LiteralPath $authority -Raw | ConvertFrom-Json
    if ($record.schema -cne 'dark180-txf-phase-a-authority-v1' -or
        $record.source_sha -cne $ExpectedSource -or
        $record.root -cne $full -or
        [string]::IsNullOrWhiteSpace($env:DARK180_TXF_PHASE_A_NONCE) -or
        $record.nonce_sha256 -cne (Hash-Text $env:DARK180_TXF_PHASE_A_NONCE) -or
        ([datetime]::UtcNow - [datetime]::Parse($record.issued_utc).ToUniversalTime()).TotalSeconds -gt 150) {
        throw 'Child lacks a current exact controller-issued fixture capability.'
    }
}
function Snapshot([string] $Path) {
    $exists = [IO.Directory]::Exists($Path)
    $names = @()
    if ($exists) { $names = @([IO.Directory]::EnumerateFileSystemEntries($Path) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object) }
    return [ordered]@{ exists=$exists; children=$names }
}
function New-CaseRoot([string] $Name) {
    $root = Join-Path $EvidenceRoot ($Name + '-' + [guid]::NewGuid().ToString('N'))
    if ([IO.Directory]::Exists($root)) { throw 'Fixture root already exists.' }
    [void][IO.Directory]::CreateDirectory($root)
    $target = Join-Path $root 'target'
    [void][IO.Directory]::CreateDirectory($target)
    $approved = Join-Path $target 'approved.bin'
    $sentinel = Join-Path $root 'sentinel.bin'
    $snapshot = Join-Path $root 'approved-before.bin'
    [IO.File]::WriteAllBytes($approved, [byte[]](9,18,27,36,45,54))
    [IO.File]::WriteAllBytes($sentinel, [byte[]](72,63,54,45,36,27))
    [IO.File]::WriteAllBytes($snapshot, [byte[]](9,18,27,36,45,54))
    return [ordered]@{ root=$root; target=$target; approved=$approved; sentinel=$sentinel;
        snapshot=$snapshot;approved_sha=(Hash-File $approved); sentinel_sha=(Hash-File $sentinel) }
}
function Close-Handle($Opened) { if ($null -ne $Opened -and $null -ne $Opened.Handle) { $Opened.Handle.Dispose() } }
function Need-Open($Opened, [string] $What) {
    if (-not $Opened.Accepted) { throw "$What failed: Win32=$($Opened.Error), NTSTATUS=$($Opened.NtStatus)" }
}
function Need-Same($A,$B,[bool]$Directory) {
    $left = [DarkTxfHandoffProbe]::Identity($A.Handle,$Directory)
    $right = [DarkTxfHandoffProbe]::Identity($B.Handle,$Directory)
    return [ordered]@{ anchor=$left; transacted=$right; same=($left -ceq $right) }
}
function New-AncestorChain([string] $Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $drive=[IO.Path]::GetPathRoot($full)
    $parts=$full.Substring($drive.Length).Split([IO.Path]::DirectorySeparatorChar)
    $chain=[Collections.Generic.List[object]]::new()
    try {
        $first=[DarkTxfHandoffProbe]::Parent($drive)
        Need-Open $first 'Drive anchor'; $null=[DarkTxfHandoffProbe]::Identity($first.Handle,$true)
        $chain.Add($first)
        foreach ($part in $parts) {
            if ($part.Length -eq 0) { throw 'Empty fixture ancestor component.' }
            $next=[DarkTxfHandoffProbe]::Relative($chain[$chain.Count-1].Handle,$part,$true,[DarkTxfHandoffProbe]::ShareRead)
            Need-Open $next 'Parent-relative ancestor'; $null=[DarkTxfHandoffProbe]::Identity($next.Handle,$true)
            $chain.Add($next)
        }
        return ,$chain
    } catch {
        for ($i=$chain.Count-1;$i -ge 0;$i--) { Close-Handle $chain[$i] }
        throw
    }
}
function Close-AncestorChain($Chain) {
    if ($null -eq $Chain) { return }
    for ($i=$Chain.Count-1;$i -ge 0;$i--) { Close-Handle $Chain[$i] }
}
function Snapshot-AncestorChain($Chain) {
    return ,@($Chain | ForEach-Object { [DarkTxfHandoffProbe]::Identity($_.Handle,$true) })
}
function Assert-Preserved($Fixture, [string] $UnknownPath, [string] $UnknownSha) {
    if ((Hash-File $Fixture.snapshot) -cne $Fixture.approved_sha) { throw 'Approved pre-disposition snapshot changed or disappeared.' }
    if ((Hash-File $Fixture.sentinel) -cne $Fixture.sentinel_sha) { throw 'Unapproved sentinel changed or disappeared.' }
    $hasUnknownPath=-not [string]::IsNullOrEmpty($UnknownPath)
    $hasUnknownSha=-not [string]::IsNullOrEmpty($UnknownSha)
    if ($hasUnknownPath -ne $hasUnknownSha) { throw 'Unapproved late child path and expected hash must be paired.' }
    if ($hasUnknownPath) {
        if ($UnknownSha -cnotmatch '^[0-9a-f]{64}$' -or
            (Hash-File $UnknownPath) -cne $UnknownSha) {
            throw 'Unapproved late child changed or disappeared.'
        }
    }
    $approvedHash=Hash-File $Fixture.approved
    if ($null -ne $approvedHash -and $approvedHash -cne $Fixture.approved_sha) {
        throw 'Surviving approved fixture bytes changed.'
    }
}
function Complete-Record([string]$Name,$Fixture,$Events,[string]$Verdict) {
    Assert-Preserved $Fixture $null $null
    return [ordered]@{ schema='dark180-txf-handoff-phase-a-v1'; case=$Name; source=$sourceBinding;
        fixture=$Fixture; events=@($Events); verdict=$Verdict; target_after=(Snapshot $Fixture.target);
        approved_sha_after=(Hash-File $Fixture.approved); sentinel_sha_after=(Hash-File $Fixture.sentinel);
        stream_coverage='partial: separate file/directory ADS writer controls, not complete bound-stream inventory';
        gate1='unverified'; target_collection=0; original_vm_product=0 }
}
function Write-WorkerError([string]$Scope,$Fixture,$Observed,[Management.Automation.ErrorRecord]$Failure) {
    try {
        $receipt=[ordered]@{schema='dark180-txf-handoff-phase-a-worker-error-v1';
            utc=[datetime]::UtcNow.ToString('o');case=$Mode;scope=$Scope;
            source=$sourceBinding;fixture_root=$Fixture.root;events=@($Observed);
            error_type=$Failure.Exception.GetType().FullName;
            error_id=$Failure.FullyQualifiedErrorId;error_message=$Failure.Exception.Message;
            gate1='unverified'}
        [Console]::Error.WriteLine('DR_PHASE_A_WORKER_ERROR ' +
            ($receipt | ConvertTo-Json -Depth 12 -Compress))
    } catch {
        [Console]::Error.WriteLine('DR_PHASE_A_WORKER_ERROR receipt-serialization-failed')
    }
}
function Assert-PhaseACompletedCases([object[]]$Results) {
    $expected=@('overlap','mismatch','close-first','commit-first','abort','late-child')
    if ($Results.Count -ne $expected.Count) { throw 'Phase A case count is incomplete.' }
    for ($index=0; $index -lt $expected.Count; $index++) {
        $row=$Results[$index]
        if ($null -eq $row) { throw "Phase A case $index has no receipt." }
        foreach ($field in @('case','exited','timed_out','exit_code','controller_error')) {
            $present=if ($row -is [Collections.IDictionary]) { $row.Contains($field) }
                else { $null -ne $row.PSObject.Properties[$field] }
            if (-not $present) { throw "Phase A case $index lacks required receipt field $field." }
        }
        $expectedExit=if ($expected[$index] -eq 'abort') { 71 } else { 0 }
        if ($row.case -cne $expected[$index] -or $row.exited -ne $true -or
            $row.timed_out -ne $false -or $row.exit_code -ne $expectedExit -or
            $null -ne $row.controller_error) {
            throw "Phase A case $index has a wrong identity, exit or closure receipt."
        }
    }
}
function Invoke-LateTrial([string]$Barrier) {
    $f=New-CaseRoot ('late-' + $Barrier)
    $p=$null; $ancestors=$null; $root=$null; $file=$null; $tx=$null; $rootWriter=$null; $fileWriter=$null
    $newChild=Join-Path $f.target 'late-child.bin'; $newHash=$null; $outcome=$null
    $committedLocal=$false; $rollbackLocal='not-attempted'; $admitted=$false
    $steps=[Collections.Generic.List[object]]::new()
    try {
        $ancestors=New-AncestorChain $f.root
        $p=$ancestors[$ancestors.Count-1]
        $root=[DarkTxfHandoffProbe]::Relative($p.Handle,'target',$true,[DarkTxfHandoffProbe]::ShareAll)
        Need-Open $root 'Late-trial root anchor'
        $file=[DarkTxfHandoffProbe]::Relative($root.Handle,'approved.bin',$false,[DarkTxfHandoffProbe]::ShareAll)
        Need-Open $file 'Late-trial file anchor'
        $tx=[DarkTxfHandoffProbe]::Begin(); Need-Open $tx 'Late-trial transaction'
        $rootWriter=[DarkTxfHandoffProbe]::Writer($f.target,$tx.Handle,$true)
        $fileWriter=[DarkTxfHandoffProbe]::Writer($f.approved,$tx.Handle,$false)
        $steps.Add([ordered]@{stage='open'; root_error=$rootWriter.Error; file_error=$fileWriter.Error})
        if (-not $rootWriter.Accepted -or -not $fileWriter.Accepted) {
            return [ordered]@{barrier=$Barrier;fixture=$f;steps=@($steps);verdict='candidate-rejected';
                unknown_sha=$null;poststate='pending-owned-handle-closure'}
        }
        $rootId=Need-Same $root $rootWriter $true
        $fileId=Need-Same $file $fileWriter $false
        $boundHash=[DarkTxfHandoffProbe]::HashSixBytes($fileWriter.Handle)
        if (-not $rootId.same -or -not $fileId.same -or $boundHash -cne $f.approved_sha) {
            throw 'Late-trial identity or contents mismatch before stage.'
        }
        $steps.Add([ordered]@{stage='identity';root=$rootId;file=$fileId;
            bound_sha256=$boundHash;ancestor_ids=(Snapshot-AncestorChain $ancestors)})
        $fileStage=[DarkTxfHandoffProbe]::Stage($fileWriter.Handle)
        $steps.Add([ordered]@{stage='file-disposition';native_error=$fileStage})
        if ($fileStage -ne 0) {
            return [ordered]@{barrier=$Barrier;fixture=$f;steps=@($steps);verdict='candidate-rejected';
                unknown_sha=$null;poststate='pending-owned-handle-closure'}
        }
        Close-Handle $fileWriter; $fileWriter=$null
        Close-Handle $file; $file=$null
        if ($Barrier -ne 'after-stage') {
            $rootStage=[DarkTxfHandoffProbe]::Stage($rootWriter.Handle)
            $steps.Add([ordered]@{stage='root-disposition';native_error=$rootStage})
            if ($rootStage -ne 0) {
                return [ordered]@{barrier=$Barrier;fixture=$f;steps=@($steps);verdict='candidate-rejected';
                    unknown_sha=$null;poststate='pending-owned-handle-closure'}
            }
        }
        if ($Barrier -eq 'before-commit') {
            Close-Handle $rootWriter; $rootWriter=$null
            Close-Handle $root; $root=$null
        }
        $outside=[DarkTxfHandoffProbe]::ExternalWriter($newChild,$true)
        $admitted=$outside.Accepted
        if ($admitted) {
            $write=[DarkTxfHandoffProbe]::WriteOne($outside.Handle,81)
            if ($write -ne 0) { throw "Late child writer opened but write failed: $write" }
        }
        $steps.Add([ordered]@{stage='late-child-writer';barrier=$Barrier;admitted=$admitted;
            native_error=$outside.Error;write_error=$(if($admitted){$write}else{$null})})
        Close-Handle $outside
        if ($admitted) {
            $newHash=Hash-One 81
            if ((Hash-File $newChild) -cne $newHash) {
                throw 'Admitted unapproved child is absent or differs immediately after writer close.'
            }
        }
        if ($Barrier -eq 'after-stage') {
            $rootStage=[DarkTxfHandoffProbe]::Stage($rootWriter.Handle)
            $steps.Add([ordered]@{stage='root-disposition';native_error=$rootStage})
        }
        if ($rootStage -ne 0) {
            $refusal=($admitted -and $rootStage -eq 145)
            $outcome=[ordered]@{barrier=$Barrier;fixture=$f;steps=@($steps);
                verdict=$(if($refusal){'root-stage-refused-with-late-child-present'}else{'candidate-rejected'});
                native_error=$rootStage;phase='root-stage-after-late-writer';commit_calls=0;
                unknown_sha=$newHash;poststate='pending-owned-handle-closure';rollback='pending'}
            return $outcome
        }
        if ($rootStage -eq 0) {
            Close-Handle $rootWriter; $rootWriter=$null
            Close-Handle $root; $root=$null
            $commitCode=[DarkTxfHandoffProbe]::Commit($tx.Handle)
            $committedLocal=($commitCode -eq 0)
            $steps.Add([ordered]@{stage='commit';native_error=$commitCode})
            if (-not $committedLocal) { throw 'Late-trial commit outcome is unknown.' }
        }
        $verdict=if ($admitted) { 'admitted-child-preserved' } else { 'late-child-refused' }
        return [ordered]@{barrier=$Barrier;fixture=$f;steps=@($steps);verdict=$verdict;
            unknown_sha=$newHash;poststate='pending-owned-handle-closure'}
    } catch {
        Write-WorkerError ('late-trial:' + $Barrier) $f $steps $_
        throw
    } finally {
        try {
            Close-Handle $fileWriter; Close-Handle $rootWriter
            if ($null -ne $tx -and $tx.Accepted -and -not $committedLocal) {
                $rollbackCode=[DarkTxfHandoffProbe]::Rollback($tx.Handle)
                $rollbackLocal=if ($rollbackCode -eq 0) { 'succeeded' } else { "unknown:$rollbackCode" }
                if ($null -ne $outcome) { $outcome.rollback=$rollbackLocal }
                [Console]::Error.WriteLine('DR_PHASE_A_ROLLBACK ' + ([ordered]@{
                    barrier=$Barrier;fixture=$f.root;outcome=$rollbackLocal;
                    utc=[datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress))
            }
            Close-Handle $file; Close-Handle $root; Close-AncestorChain $ancestors; Close-Handle $tx
            if ($rollbackLocal -like 'unknown:*') { throw 'Late-trial rollback outcome is unknown.' }
            Assert-Preserved $f $(if($admitted){$newChild}else{$null}) $newHash
            if ($null -ne $outcome -and
                $outcome.verdict -eq 'root-stage-refused-with-late-child-present' -and
                (Hash-File $f.approved) -cne $f.approved_sha) {
                throw 'Root-stage refusal did not preserve the approved original bytes.'
            }
        } catch {
            Write-WorkerError ('late-trial-cleanup-and-preservation:' + $Barrier) $f $steps $_
            throw
        }
    }
}

if ($Mode -eq 'controller') {
    if ($null -ne $EvidenceRoot -and $EvidenceRoot.Length) { throw 'Controller chooses its own fresh evidence root.' }
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $volumeRoot=[IO.Path]::GetPathRoot($temp)
    if ($volumeRoot -cnotmatch '^[A-Za-z]:\\$') { throw 'Fixture temp must have a local drive-letter root.' }
    $volume=[IO.DriveInfo]::new($volumeRoot)
    if (-not $volume.IsReady -or $volume.DriveType -ne [IO.DriveType]::Fixed -or
        $volume.DriveFormat -cne 'NTFS') {
        throw 'Fixture temp must be on an observed ready fixed local NTFS volume.'
    }
    $tempAncestor=[IO.DirectoryInfo]::new($temp)
    while ($null -ne $tempAncestor) {
        Assert-Ordinary $tempAncestor.FullName
        $tempAncestor=$tempAncestor.Parent
    }
    $base = Join-Path $temp 'Dark180-TxfHandoffPhaseA'
    if (-not [IO.Directory]::Exists($base)) { [void][IO.Directory]::CreateDirectory($base) }
    Assert-Ordinary $base
    $EvidenceRoot = Join-Path $base ([guid]::NewGuid().ToString('N'))
    New-PrivateDirectory $EvidenceRoot
    $nonce=[guid]::NewGuid().ToString('N')
    $authority=[ordered]@{schema='dark180-txf-phase-a-authority-v1';
        root=[IO.Path]::GetFullPath($EvidenceRoot);source_sha=$sourceSha;
        nonce_sha256=(Hash-Text $nonce);issued_utc=[datetime]::UtcNow.ToString('o')}
    $authorityBytes=[Text.UTF8Encoding]::new($false).GetBytes(
        ($authority | ConvertTo-Json -Compress -Depth 4))
    $authorityPath=Join-Path $EvidenceRoot 'authority.json'
    $authorityStream=[IO.FileStream]::new($authorityPath,[IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $authorityStream.Write($authorityBytes,0,$authorityBytes.Length);$authorityStream.Flush($true) }
    finally { $authorityStream.Dispose() }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $results = [Collections.Generic.List[object]]::new()
    $stop = $false; $controllerError=$null
    try { foreach ($name in $caseNames) {
        if ($stop) { break }
        $remainingMs=120000-[int]$clock.ElapsedMilliseconds
        if ($remainingMs -le 5000) { throw 'Fixture total deadline expired before next case.' }
        # Keep the owned worker and a possible five-second kill/settle inside 20 seconds.
        $caseBudgetMs=[Math]::Min(15000,$remainingMs-5000)
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = (Get-Process -Id $PID).Path
        $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true; $info.CreateNoWindow = $true
        $info.Environment['DARK180_TXF_PHASE_A_NONCE']=$nonce
        foreach ($part in @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Mode',$name,'-EvidenceRoot',$EvidenceRoot)) {
            [void]$info.ArgumentList.Add($part)
        }
        $child = [Diagnostics.Process]::new(); $child.StartInfo = $info
        $started = [datetime]::UtcNow.ToString('o'); $exited=$false; $childStarted=$false
        $outTask=$null; $errTask=$null; $caseReceipt=$null; $timedOut=$false
        try {
            if (-not $child.Start()) { throw 'Owned child did not start.' }
            $childStarted=$true
            $outTask=$child.StandardOutput.ReadToEndAsync(); $errTask=$child.StandardError.ReadToEndAsync()
            $exited=$child.WaitForExit($caseBudgetMs)
            if (-not $exited) {
                $timedOut=$true
                $child.Kill($true)
                $exited=$child.WaitForExit(5000)
                if (-not $exited) { throw 'Owned child closure is unknown after deadline.' }
            }
            $stdout=$outTask.GetAwaiter().GetResult(); $stderr=$errTask.GetAwaiter().GetResult()
            $caseReceipt=[ordered]@{case=$name; started_utc=$started; ended_utc=[datetime]::UtcNow.ToString('o');
                pid=$child.Id; exited=$exited; timed_out=$timedOut; exit_code=$child.ExitCode;
                stdout=$stdout; stderr=$stderr; controller_error=$null }
            $results.Add($caseReceipt)
            if ($timedOut) { throw 'Owned child exceeded its bounded run deadline.' }
            $expectedExit=if($name -eq 'abort'){71}else{0}
            if ($child.ExitCode -ne $expectedExit) { throw "Unexpected child exit status $($child.ExitCode)." }
            $body=$stdout.Trim() | ConvertFrom-Json -ErrorAction Stop
            if ($body.schema -cne 'dark180-txf-handoff-phase-a-v1' -or $body.case -cne $name -or
                $body.gate1 -cne 'unverified' -or $body.source.source_sha -cne $sourceSha -or
                $body.fixture.root -notlike ($EvidenceRoot + '\*')) {
                throw 'Child outcome has an unexpected identity, scope or source.'
            }
            foreach ($field in @('source_sha','fixture_sha256','native_sha256','production_guard_sha256')) {
                if ($body.source.$field -cne $sourceBinding[$field]) {
                    throw "Child source binding differs from the frozen controller input: $field."
                }
            }
            $allowedVerdicts=switch ($name) {
                'overlap' {@('handoff-observed')}
                'mismatch' {@('identity-rejected-before-stage')}
                'close-first' {@('file-removed-by-commit','file-survived-commit')}
                'commit-first' {@('file-removed-by-commit','file-survived-commit')}
                'abort' {@('abrupt-owned-worker-exit')}
                'late-child' {@('late-barriers-observed')}
            }
            if ($body.verdict -notin $allowedVerdicts) {
                $stop=$true
                throw "Child reported a rejected or incomplete candidate: $($body.verdict)."
            }
            if ($name -eq 'late-child') {
                $lateTrials=@($body.events | Where-Object stage -eq 'late-trial')
                if ($lateTrials.Count -ne 3 -or
                    (@($lateTrials | ForEach-Object barrier) -join ',') -cne 'after-stage,before-last-close,before-commit') {
                    throw 'Late-child controls did not cover exactly the frozen three barriers.'
                }
                foreach ($trial in $lateTrials) {
                    if ($trial.verdict -notin @('admitted-child-preserved','late-child-refused',
                            'root-stage-refused-with-late-child-present')) {
                        throw 'Late-child trial has an unknown terminal verdict.'
                    }
                    if ($trial.verdict -eq 'root-stage-refused-with-late-child-present' -and
                        ($trial.native_error -ne 145 -or $trial.commit_calls -ne 0 -or
                         $trial.rollback -cne 'succeeded' -or
                         $trial.unknown_sha -cne (Hash-One 81))) {
                        throw 'Directory refusal lacks exact error, zero commits or successful rollback.'
                    }
                }
            }
            if ($child.ExitCode -in @(0,71)) {
                $snapshotProof=Read-KnownBytes $body.fixture.snapshot $false
                $sentinelProof=Read-KnownBytes $body.fixture.sentinel $false
                $approvedProof=Read-KnownBytes $body.fixture.approved ($name -in @('close-first','commit-first'))
                if ($snapshotProof.sha256 -cne $body.fixture.approved_sha -or
                    $sentinelProof.sha256 -cne $body.fixture.sentinel_sha -or
                    ($approvedProof.status -eq 'present' -and
                     $approvedProof.sha256 -cne $body.fixture.approved_sha)) {
                    throw 'Controller byte snapshot differs from the frozen original.'
                }
                $caseReceipt.independent_bytes=[ordered]@{approved_before=$snapshotProof;
                    sentinel_after=$sentinelProof;approved_after=$approvedProof}
                if ((Hash-File $body.fixture.sentinel) -cne $body.fixture.sentinel_sha) {
                    throw 'Controller observed unapproved sentinel loss.'
                }
                $approvedAfter=Hash-File $body.fixture.approved
                if ($null -ne $approvedAfter -and $approvedAfter -cne $body.fixture.approved_sha) {
                    throw 'Controller observed changed surviving approved bytes.'
                }
                if ($name -eq 'abort' -and (Hash-File $body.fixture.approved) -cne $body.fixture.approved_sha) {
                    throw 'Controller observed approved bytes changed after worker death.'
                }
                if ($name -eq 'late-child') {
                    $trialProofs=[Collections.Generic.List[object]]::new()
                    foreach ($trial in $body.events | Where-Object stage -eq 'late-trial') {
                        $trialSnapshot=Read-KnownBytes $trial.fixture.snapshot $false
                        $trialSentinel=Read-KnownBytes $trial.fixture.sentinel $false
                        $trialApproved=Read-KnownBytes $trial.fixture.approved $true
                        if ($trialSnapshot.sha256 -cne $trial.fixture.approved_sha -or
                            $trialSentinel.sha256 -cne $trial.fixture.sentinel_sha -or
                            ($trialApproved.status -eq 'present' -and
                             $trialApproved.sha256 -cne $trial.fixture.approved_sha)) {
                            throw 'Controller late-trial known bytes differ from frozen originals.'
                        }
                        $trialBytes=[ordered]@{barrier=$trial.barrier;
                            approved_before=$trialSnapshot;sentinel_after=$trialSentinel;
                            approved_after=$trialApproved}
                        if ($trial.verdict -eq 'root-stage-refused-with-late-child-present' -and
                            $trialApproved.status -cne 'present') {
                            throw 'Controller found no approved original after root-stage refusal.'
                        }
                        if ((Hash-File $trial.fixture.sentinel) -cne $trial.fixture.sentinel_sha) {
                            throw 'Controller observed late-trial sentinel loss.'
                        }
                        $trialApprovedHash=Hash-File $trial.fixture.approved
                        if ($null -ne $trialApprovedHash -and $trialApprovedHash -cne $trial.fixture.approved_sha) {
                            throw 'Controller observed late-trial approved-byte corruption.'
                        }
                        $writerEvent=@($trial.steps | Where-Object stage -eq 'late-child-writer')
                        if ($writerEvent.Count -gt 1) { throw 'Duplicate late-child writer outcome.' }
                        if ($writerEvent.Count -eq 1 -and $writerEvent[0].admitted -and
                            $trial.unknown_sha -cne (Hash-One 81)) {
                            throw 'Admitted late child lacks the immutable expected byte digest.'
                        }
                        if ($null -ne $trial.unknown_sha -and
                            (Hash-File (Join-Path $trial.fixture.target 'late-child.bin')) -cne $trial.unknown_sha) {
                            throw 'Controller observed unapproved late child loss.'
                        }
                        if ($null -ne $trial.unknown_sha) {
                            $childProof=Read-KnownBytes (Join-Path $trial.fixture.target 'late-child.bin') $false
                            if ($childProof.sha256 -cne $trial.unknown_sha) {
                                throw 'Controller late-child byte proof differs from preknown writer bytes.'
                            }
                            $trialBytes.late_child_after=$childProof
                        }
                        $trialProofs.Add($trialBytes)
                    }
                    $caseReceipt.independent_late_bytes=@($trialProofs)
                }
                if ($name -eq 'overlap') {
                    $fileAdsProof=Read-KnownBytes ($body.fixture.approved + ':after-release') $false
                    $dirAdsProof=Read-KnownBytes ($body.fixture.target + ':after-release') $false
                    if ($fileAdsProof.sha256 -cne (Hash-One 90) -or
                        $dirAdsProof.sha256 -cne (Hash-One 91)) {
                        throw 'Controller after-release ADS byte proof differs from written controls.'
                    }
                    $caseReceipt.independent_ads_bytes=[ordered]@{file=$fileAdsProof;directory=$dirAdsProof}
                }
            }
        } catch {
            if ($childStarted -and -not $exited) {
                try { $child.Kill($true) } catch { }
                try { $exited=$child.WaitForExit(5000) } catch { }
            }
            if ($null -eq $caseReceipt) {
                $caseReceipt=[ordered]@{case=$name;started_utc=$started;
                    ended_utc=[datetime]::UtcNow.ToString('o');exited=$exited;timed_out=$timedOut;
                    pid=$(if($childStarted){$child.Id}else{$null});
                    exit_code=$(if($exited){$child.ExitCode}else{$null});
                    stdout=$(if($exited -and $null -ne $outTask){$outTask.GetAwaiter().GetResult()}else{$null});
                    stderr=$(if($exited -and $null -ne $errTask){$errTask.GetAwaiter().GetResult()}else{$null});
                    controller_error=$null}
                $results.Add($caseReceipt)
            }
            $caseReceipt.controller_error=$_.Exception.Message
            throw
        } finally { $child.Dispose() }
    } } catch { $controllerError=$_.Exception }
    $record=[ordered]@{schema='dark180-txf-handoff-phase-a-controller-v1'; utc=[datetime]::UtcNow.ToString('o');
        source=$sourceBinding; evidence_root=$EvidenceRoot; observed_os=[Environment]::OSVersion.VersionString;
        volume=[ordered]@{root=$volumeRoot;name=$volume.Name;type=$volume.DriveType.ToString();
            filesystem=$volume.DriveFormat;ready=$volume.IsReady};
        results=@($results); stopped_early=$stop; elapsed_ms=$clock.ElapsedMilliseconds;
        scope='Disposable native hypothesis only; not Gate 1, target collection or product qualification' }
    $json=$record | ConvertTo-Json -Depth 12 -Compress
    [Console]::Out.WriteLine('DR_GATE1_PHASE_A ' + $json)
    if ($null -ne $controllerError) { throw $controllerError }
    Assert-PhaseACompletedCases -Results @($results)
    return
}

if ([string]::IsNullOrWhiteSpace($EvidenceRoot) -or -not [IO.Path]::IsPathFullyQualified($EvidenceRoot)) {
    throw 'Child requires a parent-owned absolute fixture root.'
}
Assert-IssuedRoot $EvidenceRoot $sourceSha
$fs = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($EvidenceRoot))
if ([IO.Path]::GetPathRoot($EvidenceRoot) -cnotmatch '^[A-Za-z]:\\$' -or
    -not $fs.IsReady -or $fs.DriveType -ne [IO.DriveType]::Fixed -or
    $fs.DriveFormat -cne 'NTFS') { throw 'Isolated TxF child requires observed fixed local NTFS.' }
Add-Type -Path $nativeSource

$events=[Collections.Generic.List[object]]::new()
$fixture=New-CaseRoot $Mode
$parent=$null; $ancestors=$null; $anchorRoot=$null; $anchorFile=$null; $oldRoot=$null; $transaction=$null; $writerRoot=$null; $writerFile=$null
$committed=$false; $rollback='not-attempted'; $verdict='candidate-unproven'; $unknownPath=$null; $unknownSha=$null
try {
    $ancestors=New-AncestorChain $fixture.root
    $parent=$ancestors[$ancestors.Count-1]
    $anchorRoot=[DarkTxfHandoffProbe]::Relative($parent.Handle,'target',$true,[DarkTxfHandoffProbe]::ShareAll)
    Need-Open $anchorRoot 'Root relative anchor'
    $anchorFile=[DarkTxfHandoffProbe]::Relative($anchorRoot.Handle,'approved.bin',$false,[DarkTxfHandoffProbe]::ShareAll)
    Need-Open $anchorFile 'File relative anchor'
    $baselineRoot=[DarkTxfHandoffProbe]::Identity($anchorRoot.Handle,$true)
    $baselineFile=[DarkTxfHandoffProbe]::Identity($anchorFile.Handle,$false)
    $events.Add([ordered]@{stage='relative-anchors'; ancestor_ids=(Snapshot-AncestorChain $ancestors);
        root_id=$baselineRoot; file_id=$baselineFile;
        flags='OBJ_DONT_REPARSE|FILE_OPEN_REPARSE_POINT'; share='READ|WRITE|DELETE'})
    $transaction=[DarkTxfHandoffProbe]::Begin(); Need-Open $transaction 'CreateTransaction'
    if ($Mode -eq 'overlap') {
        # The maintained read-only guard currently opens its root with
        # SHARE_READ. Show this compatibility failure before the candidate's
        # deliberately different SHARE_ALL anchor is considered.
        $oldRoot=[DarkTxfHandoffProbe]::Relative($parent.Handle,'target',$true,[DarkTxfHandoffProbe]::ShareRead)
        Need-Open $oldRoot 'Maintained-share control'
        $oldWriter=[DarkTxfHandoffProbe]::Writer($fixture.target,$transaction.Handle,$true)
        $events.Add([ordered]@{stage='maintained-SHARE_READ-control';accepted=$oldWriter.Accepted;
            native_error=$oldWriter.Error;relative_root_id=[DarkTxfHandoffProbe]::Identity($oldRoot.Handle,$true)})
        Close-Handle $oldWriter
        if ($oldWriter.Accepted) { throw 'Maintained SHARE_READ control unexpectedly accepted a write handle.' }
        Close-Handle $oldRoot; $oldRoot=$null
    }
    if ($Mode -eq 'mismatch') {
        # Open the wrong ordinary file through a valid transaction. An identity
        # comparison must reject before any call that could stage deletion.
        $moved=Join-Path $fixture.target 'moved-original.bin'
        [IO.File]::Move($fixture.approved,$moved)
        [IO.File]::WriteAllBytes($fixture.approved,[byte[]](9,18,27,36,45,54))
        $events.Add([ordered]@{stage='replacement';held_original=$moved;
            original_sha=(Hash-File $moved);replacement_sha=(Hash-File $fixture.approved)})
        $writerFile=[DarkTxfHandoffProbe]::Writer($fixture.approved,$transaction.Handle,$false)
        Need-Open $writerFile 'Replacement transaction open'
        $comparison=Need-Same $anchorFile $writerFile $false
        $events.Add([ordered]@{stage='wrong-identity-control'; comparison=$comparison; disposition_calls=0})
        if ($comparison.same) { throw 'Wrong-file identity was accepted.' }
        $verdict='identity-rejected-before-stage'
    } else {
        $writerRoot=[DarkTxfHandoffProbe]::Writer($fixture.target,$transaction.Handle,$true)
        $events.Add([ordered]@{stage='transacted-directory-open'; accepted=$writerRoot.Accepted;
            win32_error=$writerRoot.Error; access='READ|GENERIC_WRITE|DELETE'; share='READ|WRITE'})
        if (-not $writerRoot.Accepted) { $verdict='candidate-rejected' }
        else {
            $writerFile=[DarkTxfHandoffProbe]::Writer($fixture.approved,$transaction.Handle,$false)
            $events.Add([ordered]@{stage='transacted-file-open'; accepted=$writerFile.Accepted;
                win32_error=$writerFile.Error; access='READ|GENERIC_WRITE|DELETE'; share='READ|WRITE'})
            if (-not $writerFile.Accepted) { $verdict='candidate-rejected' }
            else {
                $rootCompare=Need-Same $anchorRoot $writerRoot $true
                $fileCompare=Need-Same $anchorFile $writerFile $false
                $events.Add([ordered]@{stage='identity-handoff-before-mutation'; root=$rootCompare; file=$fileCompare})
                if (-not $rootCompare.same -or -not $fileCompare.same) { throw 'Transacted pathname identity mismatch.' }
                $boundHash=[DarkTxfHandoffProbe]::HashSixBytes($writerFile.Handle)
                $events.Add([ordered]@{stage='bound-content-before-stage';sha256=$boundHash;
                    expected_sha256=$fixture.approved_sha;ancestor_ids=(Snapshot-AncestorChain $ancestors)})
                if ($boundHash -cne $fixture.approved_sha) { throw 'Approved fixture bytes changed before staging.' }
                if ($Mode -eq 'overlap') {
                    $stream=$fixture.approved + ':while-held'
                    $external=[DarkTxfHandoffProbe]::ExternalWriter($stream,$true)
                    $events.Add([ordered]@{stage='ADS-while-held'; admitted=$external.Accepted; win32_error=$external.Error})
                    Close-Handle $external
                    if ($external.Accepted) { throw 'Outside ADS writer admitted while transacted writer held.' }
                    $directoryStream=$fixture.target + ':while-held'
                    $external=[DarkTxfHandoffProbe]::ExternalWriter($directoryStream,$true)
                    $events.Add([ordered]@{stage='directory-ADS-while-held';admitted=$external.Accepted;
                        win32_error=$external.Error})
                    Close-Handle $external
                    if ($external.Accepted) { throw 'Outside directory ADS writer admitted while transacted writer held.' }
                    $verdict='handoff-observed'
                } elseif ($Mode -eq 'abort') {
                    $stage=[DarkTxfHandoffProbe]::Stage($writerFile.Handle)
                    $events.Add([ordered]@{stage='file-staged-before-abrupt-exit'; native_error=$stage})
                    if ($stage -ne 0) { $verdict='candidate-rejected' }
                    else {
                        $record=[ordered]@{schema='dark180-txf-handoff-phase-a-v1';case=$Mode;
                            source=$sourceBinding;fixture=$fixture;events=@($events);
                            verdict='abrupt-owned-worker-exit';
                            approved_sha_after='pending-independent-post-exit-readback';
                            sentinel_sha_after='pending-independent-post-exit-readback';
                            stream_coverage='partial: no complete bound-stream inventory';
                            gate1='unverified';target_collection=0;original_vm_product=0}
                        [Console]::Out.WriteLine(($record | ConvertTo-Json -Depth 12 -Compress))
                        [Console]::Out.Flush()
                        [Environment]::Exit(71)
                    }
                } elseif ($Mode -in @('close-first','commit-first')) {
                    $stage=[DarkTxfHandoffProbe]::Stage($writerFile.Handle)
                    $events.Add([ordered]@{stage='file-disposition'; native_error=$stage})
                    if ($stage -ne 0) { $verdict='candidate-rejected' }
                    else {
                        if ($Mode -eq 'close-first') { Close-Handle $writerFile; $writerFile=$null }
                        Close-Handle $anchorFile; $anchorFile=$null
                        $commit=[DarkTxfHandoffProbe]::Commit($transaction.Handle)
                        $committed=($commit -eq 0)
                        $events.Add([ordered]@{stage='commit'; native_error=$commit;
                            file_handle_closed_first=($Mode -eq 'close-first')})
                        if ($Mode -eq 'commit-first') { Close-Handle $writerFile; $writerFile=$null }
                        if (-not $committed) { throw 'Commit outcome is unknown; no retry.' }
                        if ([IO.File]::Exists($fixture.approved)) {
                            $survivor=[DarkTxfHandoffProbe]::Relative($anchorRoot.Handle,'approved.bin',$false,[DarkTxfHandoffProbe]::ShareAll)
                            Need-Open $survivor 'Post-commit surviving file'
                            $events.Add([ordered]@{stage='survivor-identity';file_id=[DarkTxfHandoffProbe]::Identity($survivor.Handle,$false);
                                expected_original_id=$baselineFile;sha256=(Hash-File $fixture.approved)})
                            Close-Handle $survivor
                        }
                        $verdict=if ([IO.File]::Exists($fixture.approved)) { 'file-survived-commit' } else { 'file-removed-by-commit' }
                    }
                } else {
                    # This preliminary transaction only proved identity handoff.
                    # Its rollback precedes three separately owned barrier trials.
                    Close-Handle $writerFile; $writerFile=$null
                    Close-Handle $writerRoot; $writerRoot=$null
                    Close-Handle $anchorFile; $anchorFile=$null
                    Close-Handle $anchorRoot; $anchorRoot=$null
                    $rollback='attempted'
                    $rollbackCode=[DarkTxfHandoffProbe]::Rollback($transaction.Handle)
                    $rollback=if($rollbackCode -eq 0){'succeeded'}else{"unknown:$rollbackCode"}
                    if ($rollbackCode -ne 0) { throw 'Initial late-case rollback is unknown; no retry.' }
                    Close-Handle $transaction; $transaction=$null
                    foreach ($barrier in @('after-stage','before-last-close','before-commit')) {
                        $trial=Invoke-LateTrial $barrier
                        $trialEvent=[ordered]@{stage='late-trial'; barrier=$barrier; fixture=$trial.fixture;
                            steps=$trial.steps; verdict=$trial.verdict; unknown_sha=$trial.unknown_sha;
                            poststate=$trial.poststate}
                        foreach ($optional in @('native_error','phase','commit_calls','rollback')) {
                            if ($trial.Contains($optional)) { $trialEvent[$optional]=$trial[$optional] }
                        }
                        $events.Add($trialEvent)
                        if ($trial.verdict -eq 'candidate-rejected') { $verdict='candidate-rejected'; break }
                    }
                    if ($verdict -ne 'candidate-rejected') { $verdict='late-barriers-observed' }
                }
            }
        }
    }
} catch {
    Write-WorkerError 'main-case-before-cleanup' $fixture $events $_
    throw
} finally {
    try {
        Close-Handle $writerFile; Close-Handle $writerRoot
        if ($null -ne $transaction -and $transaction.Accepted -and -not $committed -and
            $rollback -eq 'not-attempted') {
            $rollbackCode=[DarkTxfHandoffProbe]::Rollback($transaction.Handle)
            $rollback=if ($rollbackCode -eq 0) { 'succeeded' } else { "unknown:$rollbackCode" }
        }
        Close-Handle $oldRoot; Close-Handle $anchorFile; Close-Handle $anchorRoot;
        Close-AncestorChain $ancestors; Close-Handle $transaction
    } catch {
        Write-WorkerError 'main-case-cleanup' $fixture $events $_
        throw
    }
}
try {
if ($rollback -like 'unknown:*') { throw 'Transaction rollback outcome is unknown.' }
Assert-Preserved $fixture $unknownPath $unknownSha
if ($Mode -in @('mismatch','overlap','abort','late-child') -and (Hash-File $fixture.approved) -cne $fixture.approved_sha) {
    throw 'Approved fixture changed unexpectedly.'
}
if ($Mode -eq 'overlap') {
    $after=$fixture.approved + ':after-release'
    $external=[DarkTxfHandoffProbe]::ExternalWriter($after,$true)
    $events.Add([ordered]@{stage='ADS-after-release-control'; admitted=$external.Accepted; win32_error=$external.Error})
    if ($external.Accepted) {
        $write=[DarkTxfHandoffProbe]::WriteOne($external.Handle,90)
        if ($write -ne 0) { throw "ADS after-release control write failed: $write" }
    }
    Close-Handle $external
    if (-not $external.Accepted) { throw 'ADS support after release was not demonstrated.' }
    $afterHash=Hash-ExistingStream $after
    if ($afterHash -cne (Hash-One 90)) { throw 'After-release file ADS bytes did not match written control.' }
    $events.Add([ordered]@{stage='ADS-after-release-content';sha256=$afterHash;bytes=1})
    $directoryAfter=$fixture.target + ':after-release'
    $external=[DarkTxfHandoffProbe]::ExternalWriter($directoryAfter,$true)
    $events.Add([ordered]@{stage='directory-ADS-after-release-control';admitted=$external.Accepted;
        win32_error=$external.Error})
    if ($external.Accepted) {
        $write=[DarkTxfHandoffProbe]::WriteOne($external.Handle,91)
        if ($write -ne 0) { throw "Directory ADS after-release write failed: $write" }
    }
    Close-Handle $external
    if (-not $external.Accepted) { throw 'Directory ADS support after release was not demonstrated.' }
    $directoryAfterHash=Hash-ExistingStream $directoryAfter
    if ($directoryAfterHash -cne (Hash-One 91)) { throw 'After-release directory ADS bytes did not match written control.' }
    $events.Add([ordered]@{stage='directory-ADS-after-release-content';sha256=$directoryAfterHash;bytes=1})
}
$events.Add([ordered]@{stage='terminal'; rollback=$rollback; os=[Environment]::OSVersion.VersionString;
    volume_root=$fs.Name;volume_type=$fs.DriveType.ToString();
    volume_format=$fs.DriveFormat; native_windows_runner=$true})
$record=Complete-Record $Mode $fixture $events $verdict
[Console]::Out.WriteLine(($record | ConvertTo-Json -Depth 12 -Compress))
} catch {
    Write-WorkerError 'main-case-post-cleanup-verification' $fixture $events $_
    throw
}
