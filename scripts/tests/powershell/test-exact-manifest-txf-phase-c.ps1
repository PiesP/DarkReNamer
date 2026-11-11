[CmdletBinding()]
param(
    [ValidateSet('controller','candidate','observer-actor')][string]$Mode='controller',
    [ValidateSet('C1','C2')][string]$Trial,
    [string]$Scope
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Phase C native stream falsification requires Windows.' }
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$modulePath=Join-Path $repo 'scripts/modules/powershell/controller-owned-root-guard.ps1'
$phaseBPath=Join-Path $PSScriptRoot 'test-exact-manifest-txf-phase-b.ps1'
$observerPath=Join-Path $repo 'scripts/tests/support/exact-manifest-phase-b-observer.cs'
$actorPath=Join-Path $repo 'scripts/tests/support/exact-manifest-phase-c-streams.cs'
$sharedNames=@('Hash-Text','Write-NewText','Write-Marker','Read-Marker',
    'Test-MarkerReady','Wait-Marker','Wait-ActorBarrier','Read-KnownBytes',
    'Read-SecurityControl','Path-State','Assert-PrivateDirectory','New-PrivateScope',
    'Complete-OwnedChild','Observe-OwnedChildClosure')
$tokens=$null;$parseErrors=$null
$sharedAst=[Management.Automation.Language.Parser]::ParseFile($phaseBPath,
    [ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Maintained Phase B shared protocol cannot be parsed.' }
foreach ($name in $sharedNames) {
    $definition=$sharedAst.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $name},$true)
    if ($null -eq $definition) { throw "Maintained Phase B helper is missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Read-HeadBounded([string]$Executable='git') {
    $script:sourceIdentityReceipt=[ordered]@{command='git -C <source-root> rev-parse HEAD';
        started_utc=[DateTime]::UtcNow.ToString('o');started=$false;
        completed_utc=$null;observations=@();terminal=$null;error=$null}
    $start=[Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    foreach ($arg in @('-C',$repo,'rev-parse','HEAD')) { $start.ArgumentList.Add($arg) }
    try { $process=[Diagnostics.Process]::Start($start) }
    catch {
        $native=if($_.Exception -is [ComponentModel.Win32Exception]){
            $_.Exception.NativeErrorCode}else{$null}
        $script:sourceIdentityReceipt.error=[ordered]@{type=$_.Exception.GetType().FullName;
            native_error=$native;message=$_.Exception.Message}
        $script:sourceIdentityReceipt.completed_utc=[DateTime]::UtcNow.ToString('o')
        throw
    }
    if ($null -eq $process) {
        $script:sourceIdentityReceipt.error=[ordered]@{type='ProcessStartNull';
            native_error=$null;message='Phase C local Git identity process did not start.'}
        $script:sourceIdentityReceipt.completed_utc=[DateTime]::UtcNow.ToString('o')
        throw 'Phase C local Git identity process did not start.'
    }
    $script:sourceIdentityReceipt.started=$true
    $child=[ordered]@{process=$process;stdout_task=$process.StandardOutput.ReadToEndAsync();
        stderr_task=$process.StandardError.ReadToEndAsync();
        started_utc=[DateTime]::UtcNow.ToString('o');role='local-source-identity';
        pid=$process.Id;kill_requested=$false}
    $observations=[Collections.Generic.List[object]]::new()
    $result=$null
    try {
        $result=Observe-OwnedChildClosure $child 2000 $observations 'git-active'
        if (-not $result.closed) {
            $child.kill_requested=$true
            try { $process.Kill($true) }
            catch [InvalidOperationException] { if (-not $process.HasExited) { throw } }
            $result=Observe-OwnedChildClosure $child 500 $observations 'git-settle'
            throw 'Phase C local Git identity exceeded two seconds.'
        }
        if ($result.capture_error) { throw 'Phase C local Git identity output is incomplete.' }
        $value=$result.stdout.Trim()
        if ($result.exit_code -ne 0 -or $value -cnotmatch '^[0-9a-f]{40}$') {
            throw 'Phase C local Git identity failed.'
        }
        return $value
    } catch {
        if ($null -eq $script:sourceIdentityReceipt.error) {
            $native=if($_.Exception -is [ComponentModel.Win32Exception]){
                $_.Exception.NativeErrorCode}else{$null}
            $script:sourceIdentityReceipt.error=[ordered]@{type=$_.Exception.GetType().FullName;
                native_error=$native;message=$_.Exception.Message}
        }
        throw
    } finally {
        $script:sourceIdentityReceipt.completed_utc=[DateTime]::UtcNow.ToString('o')
        $script:sourceIdentityReceipt.observations=@($observations)
        $script:sourceIdentityReceipt.terminal=$result
    }
}
try { $sourceSha=Read-HeadBounded }
catch {
    [Console]::Error.WriteLine('DR_PHASE_C_SOURCE_IDENTITY ' +
        ($script:sourceIdentityReceipt | ConvertTo-Json -Depth 8 -Compress))
    throw
}
$source=[ordered]@{commit=$sourceSha;
    fixture_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
    module_sha256=(Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant();
    shared_phase_b_sha256=(Get-FileHash -LiteralPath $phaseBPath -Algorithm SHA256).Hash.ToLowerInvariant();
    observer_sha256=(Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash.ToLowerInvariant();
    actor_sha256=(Get-FileHash -LiteralPath $actorPath -Algorithm SHA256).Hash.ToLowerInvariant()}
$trials=@('C1','C2')
function Stream-NameHex([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { throw 'Phase C stream name is empty.' }
    $hex=[Text.StringBuilder]::new($Value.Length*4)
    foreach ($unit in $Value.ToCharArray()) {
        [void]$hex.Append(([int]$unit -band 255).ToString('x2'))
        [void]$hex.Append((([int]$unit -shr 8) -band 255).ToString('x2'))
    }
    return $hex.ToString()
}
function Observe-StreamCatalog([string]$Path,[bool]$Directory) {
    $before=[DarkPhaseBFixtureObserver]::IdentityOf($Path,$Directory)
    $native=[DarkPhaseCStreams]::Observe($Path)
    $after=[DarkPhaseBFixtureObserver]::IdentityOf($Path,$Directory)
    return [ordered]@{before_id=$before;after_id=$after;native=$native}
}
function Test-StreamCatalog($Catalog,[string]$ExpectedId,[string[]]$ExpectedNames,
    [long[]]$ExpectedSizes) {
    if ($null -eq $ExpectedNames) { $ExpectedNames=[string[]]@() }
    if ($null -eq $ExpectedSizes) { $ExpectedSizes=[long[]]@() }
    if ($null -eq $Catalog -or $Catalog.before_id -cne $ExpectedId -or
        $Catalog.after_id -cne $ExpectedId -or $null -eq $Catalog.native) { return $false }
    $query=$Catalog.native
    if (-not $query.Complete -or $query.EofError -ne 38 -or
        $query.QueryError -ne 0 -or $query.QueryException -or $query.CloseException -or
        ($query.CloseAttempted -and (-not $query.CloseConfirmed -or $query.CloseError -ne 0)) -or
        (-not $query.CloseAttempted -and @($query.Rows).Count -ne 0)) { return $false }
    $rows=@($query.Rows)
    if ($rows.Count -gt 8 -or $rows.Count -ne $ExpectedNames.Count -or
        $ExpectedNames.Count -ne $ExpectedSizes.Count) { return $false }
    $found=[Collections.Generic.Dictionary[string,long]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        if ($row.NameUtf16Hex -cnotmatch '^(?:[0-9a-f]{4}){1,295}$' -or
            $row.Size -lt 0 -or -not $found.TryAdd($row.NameUtf16Hex,[long]$row.Size)) {
            return $false
        }
    }
    for ($i=0;$i -lt $ExpectedNames.Count;$i++) {
        $name=Stream-NameHex $ExpectedNames[$i]
        if (-not $found.ContainsKey($name) -or $found[$name] -ne $ExpectedSizes[$i]) {
            return $false
        }
    }
    return $true
}
function Test-COriginal($State,$Freeze) {
    if ($null -eq $State -or $State.root.status -cne 'present' -or
        $State.root.reparse -or $State.root_id -cne $Freeze.root_id -or
        $State.approved_id -cne $Freeze.approved_id -or
        $State.approved.status -cne 'present' -or
        $State.approved.bytes -ne 6 -or
        $State.approved.base64 -cne [Convert]::ToBase64String([byte[]](9,18,27,36,45,54)) -or
        $State.approved.sha256 -cne ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([byte[]](9,18,27,36,45,54))).ToLowerInvariant()) -or
        $State.sentinel.status -cne 'present' -or $State.sentinel.bytes -ne 6 -or
        $State.sentinel.base64 -cne [Convert]::ToBase64String([byte[]](72,63,54,45,36,27)) -or
        $State.sentinel.sha256 -cne ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([byte[]](72,63,54,45,36,27))).ToLowerInvariant()) -or
        $State.root_security.owner_sha256 -cne $Freeze.root_security.owner_sha256 -or
        $State.root_security.sddl_sha256 -cne $Freeze.root_security.sddl_sha256 -or
        $State.approved_security.owner_sha256 -cne $Freeze.approved_security.owner_sha256 -or
        $State.approved_security.sddl_sha256 -cne $Freeze.approved_security.sddl_sha256) {
        return $false
    }
    return $true
}
function Test-CBaseline($State,$Freeze,[string]$TrialName,[bool]$AfterSupport=$false) {
    if (-not (Test-COriginal $State $Freeze)) { return $false }
    $default='::$DATA'
    $named=if($TrialName -eq 'C1'){':phasec-file:$DATA'}else{':phasec-directory:$DATA'}
    $fileNames=if($TrialName -eq 'C1' -and $AfterSupport){@($default,$named)}else{@($default)}
    $fileSizes=if($TrialName -eq 'C1' -and $AfterSupport){[long[]]@(6,1)}else{[long[]]@(6)}
    $dirNames=if($TrialName -eq 'C2' -and $AfterSupport){@($named)}else{[string[]]@()}
    $dirSizes=if($TrialName -eq 'C2' -and $AfterSupport){[long[]]@(1)}else{[long[]]@()}
    return (Test-StreamCatalog $State.file_catalog $Freeze.approved_id $fileNames $fileSizes) -and
        (Test-StreamCatalog $State.directory_catalog $Freeze.root_id $dirNames $dirSizes)
}
function Test-CAdmittedPost($State,$Freeze,[string]$TrialName,$Named,[byte]$FixedByte) {
    if (-not (Test-COriginal $State $Freeze)) { return $false }
    $streamName=if($TrialName -eq 'C1'){':phasec-file:$DATA'}else{':phasec-directory:$DATA'}
    $file=$State.file_catalog;$directory=$State.directory_catalog
    $baselineFile=Test-StreamCatalog $file $Freeze.approved_id @('::$DATA') ([long[]]@(6))
    $baselineDir=Test-StreamCatalog $directory $Freeze.root_id ([string[]]@()) ([long[]]@())
    if ($baselineFile -and $baselineDir) { return $Named.status -ceq 'absent' }
    foreach ($size in @(0,1)) {
        $fileOkay=if($TrialName -eq 'C1'){
            Test-StreamCatalog $file $Freeze.approved_id @('::$DATA',$streamName) ([long[]]@(6,$size))
        }else{$baselineFile}
        $dirOkay=if($TrialName -eq 'C2'){
            Test-StreamCatalog $directory $Freeze.root_id @($streamName) ([long[]]@($size))
        }else{$baselineDir}
        if ($fileOkay -and $dirOkay) {
            if ($size -eq 0) {
                return $Named.status -ceq 'present' -and $Named.bytes -eq 0 -and
                    $Named.base64 -ceq '' -and
                    $Named.sha256 -ceq ([Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData([byte[]]@())).ToLowerInvariant())
            }
            return $Named.status -ceq 'present' -and $Named.bytes -eq 1 -and
                $Named.base64 -ceq [Convert]::ToBase64String([byte[]]@($FixedByte)) -and
                $Named.sha256 -ceq ([Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData([byte[]]@($FixedByte))).ToLowerInvariant())
        }
    }
    return $false
}
function Observe-CState([string]$Target,[string]$TrialScope) {
    $file=Join-Path $Target 'approved.bin'
    $root=Path-State $Target
    if ($root.status -cne 'present' -or $root.reparse) {
        return [ordered]@{root=$root;observation_error='target root absent or reparse'}
    }
    return [ordered]@{root=$root;
        root_id=[DarkPhaseBFixtureObserver]::IdentityOf($Target,$true);
        approved_id=[DarkPhaseBFixtureObserver]::IdentityOf($file,$false);
        approved=(Read-KnownBytes $file $false);
        sentinel=(Read-KnownBytes (Join-Path $TrialScope 'sentinel.bin') $false);
        root_security=(Read-SecurityControl $Target $true);
        approved_security=(Read-SecurityControl $file);
        file_catalog=(Observe-StreamCatalog $file $false);
        directory_catalog=(Observe-StreamCatalog $Target $true)}
}
function Read-StreamByte([string]$Path) {
    try { return Read-KnownBytes $Path $true }
    catch { return [ordered]@{status='unobservable';error=$_.Exception.Message} }
}
function Assert-CChildScope {
    if ($env:DARK_PHASE_C_NONCE -cnotmatch '^[0-9a-f]{32}$' -or
        $Trial -notin @('C1','C2') -or [string]::IsNullOrEmpty($Scope)) {
        throw 'Phase C child lacks controller-issued nonce and trial.'
    }
    $profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $base=Join-Path (Join-Path $profile 'AppData/Local/Temp') 'Dark180-TxfPhaseB'
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($Scope),$base,
            [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($Scope) -cne $env:DARK_PHASE_C_NONCE) {
        throw 'Phase C child scope escaped the exact engine fixture prefix.'
    }
    Assert-PrivateDirectory $Scope
}
function Convert-StreamAttempt($Value) {
    return [ordered]@{open_admitted=$Value.OpenAdmitted;open_error=$Value.OpenError;
        identity_observed=$Value.IdentityObserved;file_id=$Value.FileId;
        attributes=$Value.Attributes;kind_matches=$Value.KindMatches;
        identity_matches=$Value.IdentityMatches;
        identity_error=$Value.IdentityError;identity_native_error=$Value.IdentityNativeError;
        write_attempted=$Value.WriteAttempted;
        write_error=$Value.WriteError;write_exception=$Value.WriteException;
        bytes_written=$Value.BytesWritten;close=$Value.Close}
}
function Test-CSource($Actual,$Expected) {
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    foreach ($field in @('commit','fixture_sha256','module_sha256',
            'shared_phase_b_sha256','observer_sha256','actor_sha256')) {
        if (-not $Actual.Contains($field) -or
            $Actual[$field] -cne $Expected[$field]) { return $false }
    }
    return $true
}
function Test-CSourceIdentity($Receipt,[string]$Commit) {
    return $null -ne $Receipt -and $Receipt.started -and
        $null -eq $Receipt.error -and $Receipt.command -ceq 'git -C <source-root> rev-parse HEAD' -and
        $null -ne $Receipt.terminal -and $Receipt.terminal.closed -and
        -not $Receipt.terminal.kill_requested -and $Receipt.terminal.exit_code -eq 0 -and
        -not $Receipt.terminal.capture_error -and
        [string]::IsNullOrEmpty($Receipt.terminal.stderr) -and
        $Receipt.terminal.stdout.Trim() -ceq $Commit
}
function Test-CBarrier($Barrier,[string]$ExpectedTrial,$ExpectedSource,
    [string]$RootId,[string]$Digest,[string]$ExpectedScope) {
    if ([string]::IsNullOrEmpty($ExpectedScope) -or $ExpectedScope.EndsWith('\')) {
        return $false
    }
    # StageExactSet closes the deeper entry first, using each entry's engine path.
    $target=$ExpectedScope+'\target'
    $approved=$target+'\approved.bin'
    $expectedClose=@("staged-writer:${approved}:closed","staged-anchor:${approved}:closed",
        "staged-writer:${target}:closed","staged-anchor:${target}:closed")
    if ($null -eq $Barrier -or $Barrier.trial -cne $ExpectedTrial -or
        -not (Test-CSource $Barrier.source $ExpectedSource) -or
        $Barrier.root_id -cne $RootId -or $Barrier.manifest_digest -cne $Digest -or
        $Barrier.state -cne 'staged' -or $Barrier.stage_calls -ne 2 -or
        -not $Barrier.target_handles_closed -or $Barrier.closure_unknown -or
        $Barrier.commit_calls -ne 0 -or @($Barrier.close_receipts).Count -ne 4) {
        return $false
    }
    for ($i=0;$i -lt $expectedClose.Count;$i++) {
        if ($Barrier.close_receipts[$i] -cne $expectedClose[$i]) { return $false }
    }
    return $true
}
function Read-CWorkerRecord($ProcessRow,[string]$ExpectedRole,[string]$ExpectedTrial) {
    if ($null -eq $ProcessRow -or -not $ProcessRow.closed -or
        $ProcessRow.capture_error -or $ProcessRow.exit_code -ne 0) {
        throw "Phase C $ExpectedRole owned process closure/output is incomplete."
    }
    $records=@($ProcessRow.stdout -split "`r?`n" | Where-Object {
        $_.StartsWith('DR_PHASE_C_CHILD ') })
    if ($records.Count -ne 1) { throw "Phase C $ExpectedRole has $($records.Count) structured records." }
    $receipt=$records[0].Substring('DR_PHASE_C_CHILD '.Length) | ConvertFrom-Json -AsHashtable
    if ($receipt.schema -cne 'dark240-late-stream-phase-c-child-v1' -or
        $receipt.role -cne $ExpectedRole -or $receipt.trial -cne $ExpectedTrial) {
        throw "Phase C $ExpectedRole structured record differs."
    }
    return $receipt
}
function Assert-CReceipt($Row,$ExpectedSource) {
    $trial=$Row.trial
    if ($trial -notin @('C1','C2') -or $Row.controller_error -or
        $null -eq $Row.actor_receipt -or $null -eq $Row.candidate_receipt -or
        $null -eq $Row.ready -or $null -eq $Row.barrier -or
        $null -eq $Row.late_marker -or $Row.elapsed_ms -gt 20000 -or
        $Row.actor.exit_code -ne 0 -or $Row.candidate.exit_code -ne 0 -or
        -not $Row.actor.closed -or -not $Row.candidate.closed -or
        $Row.actor.capture_error -or $Row.candidate.capture_error) {
        throw 'Phase C required process, marker or deadline evidence is incomplete.'
    }
    foreach ($receipt in @($Row.actor_receipt,$Row.candidate_receipt)) {
        if (-not (Test-CSource $receipt.source $ExpectedSource) -or
            -not (Test-CSourceIdentity $receipt.source_identity $ExpectedSource.commit) -or
            $receipt.trial -cne $trial -or $receipt.scope -cne $Row.scope -or
            $receipt.gate1 -cne 'unverified' -or $receipt.target_collection -ne 0 -or
            $receipt.product -ne 0) { throw 'Phase C worker source or scope differs.' }
    }
    $events=$Row.actor_receipt.events
    $freeze=@($events | Where-Object { $_.phase -ceq 'independent-freeze' })
    $preflight=@($events | Where-Object { $_.phase -ceq 'exact-base-preflight' })
    $baseline=@($events | Where-Object { $_.phase -ceq 'baseline-default-streams-only' })
    $late=@($events | Where-Object { $_.phase -ceq 'late-stream-create-new' })
    $before=@($events | Where-Object { $_.phase -ceq 'independent-postrollback-before-support' })
    $post=@($events | Where-Object { $_.phase -ceq 'independent-postproof' })
    $expectedPhases=@('independent-freeze','exact-base-preflight',
        'baseline-default-streams-only','late-stream-create-new',
        'independent-postrollback-before-support',
        $(if ($late.Count -eq 1 -and $late[0].result.open_admitted) {
            'support-skipped'
        } else { 'after-release-same-api-support' }),
        'independent-postproof')
    if (@($events).Count -ne $expectedPhases.Count) {
        throw "Phase C actor event count differs from the exact observation order: $(@($events).Count) versus $($expectedPhases.Count)."
    }
    for ($i=0;$i -lt $expectedPhases.Count;$i++) {
        if ($events[$i].phase -cne $expectedPhases[$i]) {
            throw 'Phase C actor event order differs from the required observation order.'
        }
    }
    if ($freeze.Count -ne 1 -or $preflight.Count -ne 1 -or $baseline.Count -ne 1 -or
        $late.Count -ne 1 -or $before.Count -ne 1 -or $post.Count -ne 1 -or
        $Row.actor_receipt.status -cne 'completed' -or
        ($Row.actor_receipt.postproof | ConvertTo-Json -Depth 14 -Compress) -cne
            ($post[0].data | ConvertTo-Json -Depth 14 -Compress) -or
        ($Row.actor_receipt.postproof | ConvertTo-Json -Depth 14 -Compress) -cne
            ($post[0].data | ConvertTo-Json -Depth 14 -Compress) -or
        $Row.ready.trial -cne $trial -or
        -not (Test-CSource $Row.ready.source $ExpectedSource) -or
        $Row.ready.root_id -cne $freeze[0].root_id -or
        $Row.ready.manifest_digest -cne $freeze[0].digest -or
        $freeze[0].row_count -ne 2 -or
        -not (Test-CBarrier $Row.barrier $trial $ExpectedSource $freeze[0].root_id `
            $freeze[0].digest $Row.scope)) {
        throw 'Phase C independent freeze, preflight or barrier differs.'
    }
    foreach ($kind in @('root','approved')) {
        $item=$preflight[0][$kind]
        $id=if($kind -eq 'root'){$freeze[0].root_id}else{$freeze[0].approved_id}
        if (-not $item.OpenAdmitted -or $item.OpenError -ne 0 -or
            $item.FileId -cne $id -or -not $item.KindMatches -or
            $item.QueryError -or $item.QueryNativeError -ne 0 -or
            -not $item.Close.Attempted -or
            -not $item.Close.Confirmed -or $item.Close.NativeError -ne 0 -or
            $item.Close.ExceptionType) { throw 'Phase C exact base preflight is incomplete.' }
    }
    if (-not $preflight[0].eligible -or
        -not (Test-CBaseline $baseline[0].state $freeze[0] $trial)) {
        throw 'Phase C original frozen catalog, identity, bytes or security differs.'
    }
    $candidate=$Row.candidate_receipt
    if ($candidate.status -cne 'intentional-rollback-after-late-stream-attempt' -or
        $candidate.error -or $candidate.cleanup_error -or $candidate.stage_calls -ne 2 -or
        $candidate.commit_calls -ne 0 -or $candidate.rollback_calls -ne 1 -or
        $candidate.lease_state -cne 'rollback-succeeded' -or
        $candidate.settlement -cne 'rollback-succeeded' -or $candidate.closure_unknown) {
        throw 'Phase C candidate did not settle one exact rollback.'
    }
    $actual=$late[0].result
    if ($Row.late_marker.trial -cne $trial -or
        -not (Test-CSource $Row.late_marker.source $ExpectedSource) -or
        ($Row.late_marker.result | ConvertTo-Json -Depth 10 -Compress) -cne
            ($actual | ConvertTo-Json -Depth 10 -Compress)) {
        throw 'Phase C published late CreateFile/Write/Close result differs.'
    }
    $support=@($events | Where-Object { $_.phase -ceq 'after-release-same-api-support' })
    $expectedBaseId=if($trial -eq 'C1'){$freeze[0].approved_id}else{$freeze[0].root_id}
    if ($actual.open_admitted) {
        if ($actual.open_error -ne 0 -or -not $actual.identity_observed -or
            -not $actual.identity_matches -or
            -not $actual.kind_matches -or $actual.identity_error -or
            $actual.identity_native_error -ne 0 -or
            $actual.file_id -cne $expectedBaseId -or
            -not $actual.write_attempted -or
            -not $actual.close.Attempted -or -not $actual.close.Confirmed -or
            $actual.close.NativeError -ne 0 -or $actual.close.ExceptionType -or
            $support.Count -ne 0 -or
            -not (Test-CAdmittedPost $before[0].state $freeze[0] $trial `
                $before[0].named_stream ([byte]$(if($trial -eq 'C1'){91}else{92}))) -or
            -not (Test-CAdmittedPost $post[0].data.state $freeze[0] $trial `
                $post[0].data.named_stream ([byte]$(if($trial -eq 'C1'){91}else{92})))) {
            throw 'Phase C admitted stream lacks bound identity, known close or independent postproof.'
        }
        # Admission falsifies only late ADS exclusion; intentional Abort does not test Commit loss.
        return 'late-ads-exclusion-counterexample-gate1-unverified'
    }
    if ($actual.open_error -notin @(32,6800) -or $actual.identity_observed -or
        $actual.file_id -or $actual.identity_error -or $actual.identity_native_error -ne 0 -or
        $actual.write_attempted -or $actual.write_error -ne 0 -or
        $actual.write_exception -or $actual.bytes_written -ne 0 -or
        $actual.close.Attempted -or
        -not $actual.close.Confirmed -or $actual.close.NativeError -ne 0 -or
        $actual.close.ExceptionType -or $support.Count -ne 1 -or
        -not (Test-CBaseline $before[0].state $freeze[0] $trial) -or
        $before[0].named_stream.status -cne 'absent') {
        throw 'Phase C late stream refusal or support presence is unsupported.'
    }
    $positive=$support[0].result
    $expectedByte=[byte]$(if($trial -eq 'C1'){91}else{92})
    if (-not $positive.open_admitted -or $positive.open_error -ne 0 -or
        -not $positive.identity_observed -or -not $positive.identity_matches -or
        -not $positive.kind_matches -or $positive.identity_error -or
        $positive.identity_native_error -ne 0 -or
        $positive.file_id -cne $expectedBaseId -or
        -not $positive.write_attempted -or $positive.write_error -ne 0 -or
        $positive.write_exception -or $positive.bytes_written -ne 1 -or
        -not $positive.close.Attempted -or -not $positive.close.Confirmed -or
        $positive.close.NativeError -ne 0 -or $positive.close.ExceptionType -or
        -not (Test-CBaseline $post[0].data.state $freeze[0] $trial $true) -or
        $post[0].data.named_stream.status -cne 'present' -or
        $post[0].data.named_stream.bytes -ne 1 -or
        $post[0].data.named_stream.base64 -cne
            [Convert]::ToBase64String([byte[]]@($expectedByte)) -or
        $post[0].data.named_stream.sha256 -cne ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([byte[]]@($expectedByte))).ToLowerInvariant())) {
        throw 'Phase C same-API support or independent named stream readback is incomplete.'
    }
    return 'late-stream-refused-supported-gate1-unverified'
}
function Invoke-CChild {
    Assert-CChildScope
    Add-Type -Path $observerPath -ErrorAction Stop
    Add-Type -Path $actorPath -ErrorAction Stop
    $deadline=[DarkPhaseCDeadline]::new(15000)
    $target=Join-Path $Scope 'target'
    $events=[Collections.Generic.List[object]]::new()
    $lease=$null;$workerError=$null;$cleanupError=$null
    $status='not-started'
    try {
        if ($Mode -eq 'observer-actor') {
            [void][IO.Directory]::CreateDirectory($target)
            [IO.File]::WriteAllBytes((Join-Path $target 'approved.bin'),[byte[]](9,18,27,36,45,54))
            [IO.File]::WriteAllBytes((Join-Path $Scope 'sentinel.bin'),[byte[]](72,63,54,45,36,27))
            [IO.File]::WriteAllBytes((Join-Path $Scope 'approved-before.bin'),[byte[]](9,18,27,36,45,54))
            $rows=[DarkPhaseBFixtureObserver]::Freeze($target)
            if ($rows.Count -ne 2 -or $rows[0].Split('|')[0] -cne '.' -or
                $rows[1].Split('|')[0] -cne '61007000700072006f007600650064002e00620069006e00') {
                throw 'Phase C independent raw UTF-16 fixture topology differs.'
            }
            $digest=[DarkPhaseBFixtureObserver]::DigestRows($rows)
            $rootId=$rows[0].Split('|')[2];$fileId=$rows[1].Split('|')[2]
            $rootParts=$rows[0].Split('|');$fileParts=$rows[1].Split('|')
            $frozen=[ordered]@{phase='independent-freeze';root_id=$rootId;
                approved_id=$fileId;digest=$digest;row_count=2;
                root_security=[ordered]@{owner_sha256=(Hash-Text ([Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($rootParts[5]))));
                    sddl_sha256=(Hash-Text ([Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($rootParts[6]))))};
                approved_security=[ordered]@{owner_sha256=(Hash-Text ([Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($fileParts[5]))));
                    sddl_sha256=(Hash-Text ([Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($fileParts[6]))))}}
            $events.Add($frozen)
            $nonceHash=Hash-Text $env:DARK_PHASE_C_NONCE
            $fields=@($sourceSha,$nonceHash,$Scope,$target,$rootId,$digest)
            Write-NewText (Join-Path $Scope 'approved-manifest.txt') (($rows -join "`n") + "`n")
            Write-NewText (Join-Path $Scope 'authority.txt') (($fields -join "`n") + "`n")
            Write-NewText (Join-Path $Scope 'predelete.txt') (($fields -join "`n") + "`n")
            $capability=[DarkPhaseCStreams]::Prepare($Scope,$target,$Trial,$rootId,$fileId)
            $events.Add([ordered]@{phase='exact-base-preflight';
                root=$capability.RootPreflight;approved=$capability.FilePreflight;
                eligible=$capability.Eligible})
            if (-not $capability.Eligible) { throw 'Phase C exact base preflight was not admitted.' }
            $baseline=Observe-CState $target $Scope
            if (-not (Test-CBaseline $baseline $frozen $Trial)) {
                throw 'Phase C initial complete $DATA catalog or frozen base differs.'
            }
            $events.Add([ordered]@{phase='baseline-default-streams-only';state=$baseline})
            Write-Marker (Join-Path $Scope 'actor-ready.json') ([ordered]@{
                trial=$Trial;source=$source;root_id=$rootId;manifest_digest=$digest})
            $barrier=Wait-Marker (Join-Path $Scope 'candidate-barrier.json') 12000
            if (-not (Test-CBarrier $barrier $Trial $source $rootId $digest $Scope)) {
                throw 'Phase C exact last-close barrier is unsupported.'
            }
            $late=Convert-StreamAttempt ($capability.Late())
            $events.Add([ordered]@{phase='late-stream-create-new';result=$late})
            Write-Marker (Join-Path $Scope 'actor-done.json') ([ordered]@{
                trial=$Trial;source=$source;result=$late})
            $candidateDone=Wait-Marker (Join-Path $Scope 'candidate-done.json') 12000
            if ($candidateDone.trial -cne $Trial -or
                -not $candidateDone.candidate_rollback_confirmed) {
                throw 'Phase C actor lacks confirmed candidate rollback and process exit.'
            }
            $before=Observe-CState $target $Scope
            $streamBefore=Read-StreamByte $capability.StreamPath
            $events.Add([ordered]@{phase='independent-postrollback-before-support';
                state=$before;named_stream=$streamBefore})
            $knownRefusal=-not $late.open_admitted -and $late.open_error -in @(32,6800) -and
                -not $late.identity_observed -and -not $late.file_id -and
                -not $late.identity_error -and $late.identity_native_error -eq 0 -and
                -not $late.write_attempted -and $late.write_error -eq 0 -and
                -not $late.write_exception -and $late.bytes_written -eq 0 -and
                -not $late.close.Attempted -and $late.close.Confirmed -and
                $late.close.NativeError -eq 0 -and -not $late.close.ExceptionType
            $baselineConfirmed=(Test-CBaseline $before $frozen $Trial) -and
                $streamBefore.status -ceq 'absent'
            if ($knownRefusal -and $baselineConfirmed) {
                $support=Convert-StreamAttempt ($capability.Support($true,$true,$true))
                $events.Add([ordered]@{phase='after-release-same-api-support';result=$support})
            } else {
                $events.Add([ordered]@{phase='support-skipped';
                    known_refusal=$knownRefusal;baseline_confirmed=$baselineConfirmed})
            }
            $after=Observe-CState $target $Scope
            $streamAfter=Read-StreamByte $capability.StreamPath
            $post=[ordered]@{state=$after;named_stream=$streamAfter}
            $events.Add([ordered]@{phase='independent-postproof';data=$post})
            $status='completed'
            [Console]::Out.WriteLine('DR_PHASE_C_CHILD ' + (([ordered]@{
                schema='dark240-late-stream-phase-c-child-v1';role=$Mode;trial=$Trial;
                source=$source;source_identity=$script:sourceIdentityReceipt;
                scope=$Scope;status=$status;events=@($events);postproof=$post;
                gate1='unverified';target_collection=0;product=0} | ConvertTo-Json -Depth 18 -Compress)))
        } else {
            . $modulePath
            Add-Type -TypeDefinition $script:DrOwnedRootGuardSource -ErrorAction Stop
            try {
                $lease=[DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease]::PrepareFixtureOnly(
                    $Scope,$target,$env:DARK_PHASE_C_NONCE,$sourceSha)
                $digest=$lease.AcquireExactSet()
                $events.Add([ordered]@{phase='exact-set-acquired';digest=$digest;count=$lease.HeldEntryCount})
                $lease.StageExactSet((Join-Path $Scope 'predelete.txt'))
                $barrier=[ordered]@{trial=$Trial;source=$source;root_id=$lease.RootId;
                    manifest_digest=$digest;state=$lease.LeaseState;stage_calls=$lease.StageCalls;
                    target_handles_closed=$lease.TargetHandlesClosed;
                    closure_unknown=$lease.ClosureUnknown;close_receipts=$lease.CloseReceipts;
                    commit_calls=$lease.CommitCalls}
                Write-Marker (Join-Path $Scope 'candidate-barrier.json') $barrier
                $null=Wait-Marker (Join-Path $Scope 'actor-done.json') 10000
                if (-not $lease.Abort()) { throw 'Phase C intentional rollback outcome is unknown.' }
                $status='intentional-rollback-after-late-stream-attempt'
            } catch {
                $status='rejected-or-unknown'
                $workerError=[ordered]@{type=$_.Exception.GetType().FullName;
                    message=$_.Exception.Message;error_id=$_.FullyQualifiedErrorId}
            } finally {
                if ($null -ne $lease) {
                    try { $lease.Dispose() }
                    catch { $cleanupError=[ordered]@{type=$_.Exception.GetType().FullName;
                        message=$_.Exception.Message;error_id=$_.FullyQualifiedErrorId} }
                }
            }
            [Console]::Out.WriteLine('DR_PHASE_C_CHILD ' + (([ordered]@{
                schema='dark240-late-stream-phase-c-child-v1';role=$Mode;trial=$Trial;
                source=$source;source_identity=$script:sourceIdentityReceipt;
                scope=$Scope;status=$status;events=@($events);
                error=$workerError;cleanup_error=$cleanupError;
                stage_calls=$(if($null -ne $lease){$lease.StageCalls}else{0});
                commit_calls=$(if($null -ne $lease){$lease.CommitCalls}else{0});
                rollback_calls=$(if($null -ne $lease){$lease.RollbackCalls}else{0});
                lease_state=$(if($null -ne $lease){$lease.LeaseState}else{'not-started'});
                settlement=$(if($null -ne $lease){$lease.Settlement}else{'not-started'});
                closure_unknown=$(if($null -ne $lease){$lease.ClosureUnknown}else{$false});
                gate1='unverified';target_collection=0;product=0} | ConvertTo-Json -Depth 16 -Compress)))
        }
    } catch {
        [Console]::Error.WriteLine('DR_PHASE_C_WORKER_ERROR ' + (([ordered]@{
            role=$Mode;trial=$Trial;source=$source;events=@($events);
            type=$_.Exception.GetType().FullName;message=$_.Exception.Message} |
            ConvertTo-Json -Depth 12 -Compress)))
        throw
    } finally { $deadline.Dispose() }
}

function Start-CChild([string]$Role,[string]$TrialName,[string]$TrialScope,[string]$Nonce) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $start.WorkingDirectory=$repo;$start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,
            '-Mode',$Role,'-Trial',$TrialName,'-Scope',$TrialScope)) { $start.ArgumentList.Add($arg) }
    $start.Environment['DARK_PHASE_C_NONCE']=$Nonce
    $process=[Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'Phase C owned primary child did not start.' }
    return [ordered]@{process=$process;stdout_task=$process.StandardOutput.ReadToEndAsync();
        stderr_task=$process.StandardError.ReadToEndAsync();
        started_utc=[DateTime]::UtcNow.ToString('o');role=$Role;
        pid=$process.Id;kill_requested=$false}
}
function Stop-CChild($Child) {
    if ($null -eq $Child -or $Child.process.HasExited) { return }
    $Child.kill_requested=$true
    try { $Child.process.Kill($true) }
    catch [InvalidOperationException] { if (-not $Child.process.HasExited) { throw } }
}
function Invoke-CBoundedPreflight([string]$Kind) {
    $receipt=[ordered]@{kind=$Kind;started_utc=[DateTime]::UtcNow.ToString('o');
        started=$false;completed_utc=$null;observations=@();terminal=$null;error=$null}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.WorkingDirectory=$repo;$start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    if ($Kind -eq 'status') {
        $start.FileName='git'
        foreach ($arg in @('-C',$repo,'status','--porcelain','--untracked-files=all')) {
            $start.ArgumentList.Add($arg)
        }
    } elseif ($Kind -eq 'compile') {
        $start.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $start.Environment['DARK_PHASE_C_ACTOR_PATH']=$actorPath
        foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-Command',
                'Add-Type -Path $env:DARK_PHASE_C_ACTOR_PATH -ErrorAction Stop')) {
            $start.ArgumentList.Add($arg)
        }
    } else { throw 'Phase C unsupported preflight kind.' }
    try { $process=[Diagnostics.Process]::Start($start) }
    catch {
        $receipt.error=[ordered]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
        $receipt.completed_utc=[DateTime]::UtcNow.ToString('o')
        $script:preflightReceipts.Add($receipt)
        throw
    }
    if ($null -eq $process) {
        $receipt.error=[ordered]@{type='ProcessStartNull';message="Phase C $Kind subprocess did not start."}
        $receipt.completed_utc=[DateTime]::UtcNow.ToString('o')
        $script:preflightReceipts.Add($receipt)
        throw "Phase C $Kind subprocess did not start."
    }
    $receipt.started=$true
    $child=[ordered]@{process=$process;stdout_task=$process.StandardOutput.ReadToEndAsync();
        stderr_task=$process.StandardError.ReadToEndAsync();started_utc=$receipt.started_utc;
        role="preflight-$Kind";pid=$process.Id;kill_requested=$false}
    $observations=[Collections.Generic.List[object]]::new();$result=$null
    try {
        $result=Observe-OwnedChildClosure $child 5000 $observations 'preflight-active'
        if (-not $result.closed) {
            $child.kill_requested=$true
            try { $process.Kill($true) }
            catch [InvalidOperationException] { if (-not $process.HasExited) { throw } }
            $result=Observe-OwnedChildClosure $child 500 $observations 'preflight-settle'
            throw "Phase C $Kind subprocess exceeded five seconds."
        }
        if ($result.capture_error -or $result.exit_code -ne 0 -or
            -not [string]::IsNullOrEmpty($result.stderr)) {
            throw "Phase C $Kind subprocess failed or output is incomplete."
        }
        return $result.stdout
    } catch {
        $receipt.error=[ordered]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
        throw
    } finally {
        $receipt.completed_utc=[DateTime]::UtcNow.ToString('o')
        $receipt.observations=@($observations);$receipt.terminal=$result
        $script:preflightReceipts.Add($receipt)
    }
}

if ($Mode -ne 'controller') { Invoke-CChild;return }
$suiteClock=[Diagnostics.Stopwatch]::StartNew()
$all=[Collections.Generic.List[object]]::new()
$script:preflightReceipts=[Collections.Generic.List[object]]::new()
$controllerFailure=$null;$activeActor=$null;$activeCandidate=$null
$environment=$null
$actorCount=0;$candidateCount=0
try {
    $dirty=Invoke-CBoundedPreflight 'status'
    if (-not [string]::IsNullOrEmpty($dirty)) { throw 'Phase C native fixture needs a clean source-bound checkout.' }
    $null=Invoke-CBoundedPreflight 'compile'
    $profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ($profile -cnotmatch '^[A-Za-z]:\\' -or
        -not [string]::Equals($local,($profile+'\AppData\Local'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Phase C profile and LocalAppData are not canonical.'
    }
    $drive=[IO.DriveInfo]::new($profile.Substring(0,3))
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed -or
        $drive.DriveFormat -cne 'NTFS') { throw 'Phase C requires fixed local NTFS.' }
    $environment=[ordered]@{os=[Environment]::OSVersion.VersionString;
        volume=$drive.Name;drive_type=$drive.DriveType.ToString();format=$drive.DriveFormat}
    $temp=Join-Path $local 'Temp'
    $chain=[Collections.Generic.List[IO.DirectoryInfo]]::new()
    for($item=[IO.DirectoryInfo]::new($temp);$null -ne $item;$item=$item.Parent){$chain.Add($item)}
    for($index=$chain.Count-1;$index -ge 0;$index--){
        if (-not $chain[$index].Exists -or
            (($chain[$index].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Phase C profile Temp ancestry is absent or reparse.'
        }
    }
    $base=Join-Path $temp 'Dark180-TxfPhaseB'
    if ([IO.Directory]::Exists($base)) { Assert-PrivateDirectory $base }
    else { New-PrivateScope $base }
    foreach ($name in $trials) {
        if ($suiteClock.Elapsed.TotalSeconds -ge 60) { throw 'Phase C suite exceeded 60 seconds.' }
        $trialClock=[Diagnostics.Stopwatch]::StartNew()
        $nonce=[Guid]::NewGuid().ToString('N')
        $scope=Join-Path $base $nonce
        New-PrivateScope $scope
        $row=[ordered]@{trial=$name;scope=$scope;source=$source;
            started_utc=[DateTime]::UtcNow.ToString('o');ready=$null;barrier=$null;
            late_marker=$null;actor=$null;candidate=$null;actor_receipt=$null;
            candidate_receipt=$null;controller_error=$null;verdict=$null;
            closure_observations=[Collections.Generic.List[object]]::new()}
        $all.Add($row)
        $activeActor=$null;$activeCandidate=$null
        try {
            $activeActor=Start-CChild 'observer-actor' $name $scope $nonce;$actorCount++
            while (-not (Test-MarkerReady (Join-Path $scope 'actor-ready.json'))) {
                if ($activeActor.process.HasExited) { throw 'Phase C actor exited before independent freeze.' }
                if ($trialClock.ElapsedMilliseconds -ge 15000) { throw 'Phase C actor preparation timed out.' }
                Start-Sleep -Milliseconds 50
            }
            $row.ready=Read-Marker (Join-Path $scope 'actor-ready.json')
            if ($row.ready.trial -cne $name -or
                -not (Test-CSource $row.ready.source $source)) {
                throw 'Phase C actor readiness has mixed source or trial.'
            }
            $activeCandidate=Start-CChild 'candidate' $name $scope $nonce;$candidateCount++
            while (-not $activeCandidate.process.HasExited) {
                if ($trialClock.ElapsedMilliseconds -ge 15000) { throw 'Phase C active trial timed out.' }
                Start-Sleep -Milliseconds 50
            }
            $row.barrier=Read-Marker (Join-Path $scope 'candidate-barrier.json')
            if (-not (Test-CBarrier $row.barrier $name $source $row.ready.root_id `
                    $row.ready.manifest_digest $scope)) { throw 'Phase C barrier differs from independent freeze.' }
            $row.late_marker=Read-Marker (Join-Path $scope 'actor-done.json')
            $remaining=[Math]::Max(0,[Math]::Min(5000,15000-[int]$trialClock.ElapsedMilliseconds))
            $row.candidate=Observe-OwnedChildClosure $activeCandidate $remaining `
                $row.closure_observations 'active-candidate-confirmation'
            if (-not $row.candidate.closed) { throw 'Phase C candidate closure is unknown.' }
            $activeCandidate=$null
            $row.candidate_receipt=Read-CWorkerRecord $row.candidate 'candidate' $name
            if (-not (Test-CSource $row.candidate_receipt.source $source) -or
                $row.candidate_receipt.status -cne 'intentional-rollback-after-late-stream-attempt' -or
                $row.candidate_receipt.stage_calls -ne 2 -or
                $row.candidate_receipt.commit_calls -ne 0 -or
                $row.candidate_receipt.rollback_calls -ne 1 -or
                $row.candidate_receipt.lease_state -cne 'rollback-succeeded' -or
                $row.candidate_receipt.settlement -cne 'rollback-succeeded' -or
                $row.candidate_receipt.closure_unknown -or $row.candidate_receipt.cleanup_error) {
                throw 'Phase C candidate exit lacks settled intentional rollback.'
            }
            Write-Marker (Join-Path $scope 'candidate-done.json') ([ordered]@{
                trial=$name;candidate_rollback_confirmed=$true})
            while (-not $activeActor.process.HasExited) {
                if ($trialClock.ElapsedMilliseconds -ge 15000) { throw 'Phase C postproof timed out.' }
                Start-Sleep -Milliseconds 50
            }
        } catch {
            $row.controller_error=[ordered]@{type=$_.Exception.GetType().FullName;
                message=$_.Exception.Message}
        } finally {
            $settle=[Diagnostics.Stopwatch]::StartNew()
            try { Stop-CChild $activeCandidate;Stop-CChild $activeActor }
            catch { if ($null -eq $row.controller_error) {
                $row.controller_error=[ordered]@{type=$_.Exception.GetType().FullName;
                    message=$_.Exception.Message} } }
            if ($null -eq $row.candidate -or -not $row.candidate.closed) {
                $remaining=[Math]::Max(0,[Math]::Min(5000,20000-[int]$trialClock.ElapsedMilliseconds))
                $row.candidate=Observe-OwnedChildClosure $activeCandidate $remaining `
                    $row.closure_observations 'candidate-settle-confirmation'
            }
            $remaining=[Math]::Max(0,[Math]::Min(5000-[int]$settle.ElapsedMilliseconds,
                20000-[int]$trialClock.ElapsedMilliseconds))
            $row.actor=Observe-OwnedChildClosure $activeActor $remaining `
                $row.closure_observations 'actor-settle-confirmation'
            $row.elapsed_ms=[int]$trialClock.ElapsedMilliseconds
            $row.completed_utc=[DateTime]::UtcNow.ToString('o')
            if ($null -ne $row.actor -and $row.actor.closed) { $activeActor=$null }
            if ($null -ne $row.candidate -and $row.candidate.closed) { $activeCandidate=$null }
        }
        if ($null -eq $row.controller_error) {
            try {
                $row.actor_receipt=Read-CWorkerRecord $row.actor 'observer-actor' $name
                $row.verdict=Assert-CReceipt $row $source
            } catch { $row.controller_error=[ordered]@{type=$_.Exception.GetType().FullName;
                message=$_.Exception.Message} }
        }
        [Console]::Out.WriteLine('DR_PHASE_C_TRIAL ' + ($row | ConvertTo-Json -Depth 18 -Compress))
        if ($row.controller_error -or $row.elapsed_ms -gt 20000 -or
            $row.verdict -ceq 'late-ads-exclusion-counterexample-gate1-unverified') {
            throw "Phase C $name stopped after unknown or counterexample evidence."
        }
    }
} catch { $controllerFailure=[ordered]@{type=$_.Exception.GetType().FullName;
    message=$_.Exception.Message} }
finally {
    foreach ($child in @($activeCandidate,$activeActor)) {
        if ($null -ne $child) { try { Stop-CChild $child } catch { } }
    }
}
$summary=[ordered]@{schema='dark240-late-stream-phase-c-controller-v1';
    source=$source;source_identity=$script:sourceIdentityReceipt;environment=$environment;
    preflight_receipts=@($script:preflightReceipts);
    utc=[DateTime]::UtcNow.ToString('o');
    trial_count=$all.Count;candidate_process_count=$candidateCount;
    actor_process_count=$actorCount;suite_elapsed_ms=[int]$suiteClock.ElapsedMilliseconds;
    trials=@($all);error=$controllerFailure;gate1='unverified';product=0}
[Console]::Out.WriteLine('DR_PHASE_C_CONTROLLER ' + ($summary | ConvertTo-Json -Depth 20 -Compress))
if ($null -ne $controllerFailure -or $all.Count -ne 2 -or
    $candidateCount -ne 2 -or $actorCount -ne 2 -or
    $suiteClock.ElapsedMilliseconds -gt 60000) { exit 1 }
Write-Host 'Phase C two-trial late-stream falsification completed; Gate 1 remains unverified.'
