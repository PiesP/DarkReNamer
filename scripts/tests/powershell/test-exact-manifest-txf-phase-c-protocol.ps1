[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fixture=Join-Path $PSScriptRoot 'test-exact-manifest-txf-phase-c.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($fixture,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Phase C fixture has PowerShell parse errors.' }
$phaseBFixture=Join-Path $PSScriptRoot 'test-exact-manifest-txf-phase-b.ps1'
$bTokens=$null;$bErrors=$null
$bAst=[Management.Automation.Language.Parser]::ParseFile($phaseBFixture,
    [ref]$bTokens,[ref]$bErrors)
if($bErrors.Count){throw 'Phase C shared Phase B helper has parse errors.'}
$batchHelper=$bAst.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Test-PartialRunBatchInput'},$true)
if($null -eq $batchHelper){throw 'Phase C shared child argument helper is absent.'}
. ([scriptblock]::Create($batchHelper.Extent.Text))
if((Test-PartialRunBatchInput '' @('','','','','') '') -or
    -not (Test-PartialRunBatchInput '' @('x','','','','') '') -or
    -not (Test-PartialRunBatchInput '' @('x','y','','','') '') -or
    (Test-PartialRunBatchInput ('1'*32) @('','','','','') '')){
    throw 'Phase C shared actual child argument guard differs.'}
foreach ($name in @('Stream-NameHex','Test-CSource','Test-CSourceIdentity','Test-CBarrier',
        'Test-CStreamContext','Test-CStreamDataIdentity',
        'Test-StreamCatalog','Test-COriginal','Test-CBaseline','Test-CAdmittedPost',
        'Assert-CReceipt','Read-CWorkerRecord','Read-HeadBounded',
        'Invoke-CBoundedPreflight')) {
    $definition=$ast.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $name},$true)
    if ($null -eq $definition) { throw "Phase C actual protocol function is absent: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
Add-Type -Path (Join-Path $PSScriptRoot '../support/exact-manifest-phase-c-streams.cs') -ErrorAction Stop
function Assert-Rejected([scriptblock]$Action,[string]$Label) {
    $rejected=$false
    try { $null=& $Action } catch { $rejected=$true }
    if (-not $rejected) { throw "Phase C accepted invalid $Label" }
}
$profile='C:\Users\runneradmin';$local=$profile+'\AppData\Local'
$scope=$local+'\Temp\Dark180-TxfPhaseB\0123456789abcdef0123456789abcdef'
$target=$scope+'\target'
[DarkPhaseCStreams]::RequireFixtureScope($profile,$local,$scope,$target,'C1',
    ('1'*48),('2'*48))
foreach ($fault in @('protected-root','alias','traversal','wrong-target','bad-id',
        'wrong-trial','wrong-local')) {
    $p=$profile;$l=$local;$s=$scope;$t=$target;$trial='C1';$id='1'*48
    switch ($fault) {
        'protected-root' { $s='C:\ProgramData\DarkReNamerVmRuns\0123456789abcdef0123456789abcdef';
            $t=$s+'\target' }
        'alias' { $p='C:\Users\runneradmin.';$l=$p+'\AppData\Local';
            $s=$p+'\AppData\Local\Temp\Dark180-TxfPhaseB\0123456789abcdef0123456789abcdef';
            $t=$s+'\target' }
        'traversal' { $s=$local+'\Temp\Dark180-TxfPhaseB\..\0123456789abcdef0123456789abcdef';
            $t=$s+'\target' }
        'wrong-target' { $t=$scope+'\different' }
        'bad-id' { $id='g'*48 }
        'wrong-trial' { $trial='C3' }
        'wrong-local' { $l='C:\Other\AppData\Local' }
    }
    Assert-Rejected { [DarkPhaseCStreams]::RequireFixtureScope($p,$l,$s,$t,$trial,$id,
            ('2'*48)) } "pure fixture scope $fault"
}
foreach ($name in @('::$DATA',':phasec-file:$DATA',':phasec-directory:$DATA',
        ([string]::new([char[]]@([char]0xd800,'x'))))) {
    if ([DarkPhaseCStreams]::RawUtf16Hex($name) -cne (Stream-NameHex $name)) {
        throw 'Phase C native and protocol raw UTF-16 stream framing differs.'
    }
}
function Copy-Value($Value) { return $Value | ConvertTo-Json -Depth 24 | ConvertFrom-Json -AsHashtable }
function Byte-Proof([byte[]]$Bytes) {
    return [ordered]@{status='present';bytes=$Bytes.Length;
        base64=[Convert]::ToBase64String($Bytes);
        sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
}
function Catalog([string[]]$Names,[long[]]$Sizes,[bool]$Empty=$false) {
    $rows=@()
    for($i=0;$i -lt $Names.Count;$i++) {
        $rows+=@([ordered]@{NameUtf16Hex=(Stream-NameHex $Names[$i]);Size=$Sizes[$i]})
    }
    return [ordered]@{before_id=$null;after_id=$null;
        native=[ordered]@{Complete=$true;EofError=38;QueryError=0;
            QueryException=$null;CloseException=$null;CloseAttempted=(-not $Empty);
            CloseConfirmed=(-not $Empty);CloseError=0;Rows=@($rows)}}
}
$source=[ordered]@{commit='a'*40;fixture_sha256='b'*64;module_sha256='c'*64;
    shared_phase_b_sha256='d'*64;observer_sha256='e'*64;actor_sha256='f'*64}
$sourceIdentity=[ordered]@{command='git -C <source-root> rev-parse HEAD';started=$true;
    error=$null;terminal=[ordered]@{closed=$true;kill_requested=$false;exit_code=0;
        capture_error=$null;stderr='';stdout=(('a'*40)+"`n")}}
$rootId='1'*48;$fileId='2'*48;$digest='3'*64
$freeze=[ordered]@{phase='independent-freeze';root_id=$rootId;approved_id=$fileId;
    digest=$digest;row_count=2;
    root_security=[ordered]@{owner_sha256='4'*64;sddl_sha256='5'*64};
    approved_security=[ordered]@{owner_sha256='6'*64;sddl_sha256='7'*64}}
$baseline=[ordered]@{root=[ordered]@{status='present';reparse=$false};
    root_id=$rootId;approved_id=$fileId;approved=(Byte-Proof ([byte[]](9,18,27,36,45,54)));
    sentinel=(Byte-Proof ([byte[]](72,63,54,45,36,27)));
    root_security=$freeze.root_security;approved_security=$freeze.approved_security;
    file_catalog=(Catalog @('::$DATA') ([long[]]@(6)));
    directory_catalog=(Catalog ([string[]]@()) ([long[]]@()) $true)}
$baseline.file_catalog.before_id=$fileId;$baseline.file_catalog.after_id=$fileId
$baseline.directory_catalog.before_id=$rootId;$baseline.directory_catalog.after_id=$rootId
if (-not (Test-CBaseline $baseline $freeze 'C1') -or
    -not (Test-CBaseline $baseline $freeze 'C2')) {
    throw 'Phase C baseline file/default and empty directory $DATA controls failed.'
}
foreach ($fault in @('eof','close','extra','id','kind','error87','partial')) {
    $bad=Copy-Value $baseline
    switch ($fault) {
        'eof' { $bad.directory_catalog.native.EofError=87 }
        'close' { $bad.file_catalog.native.CloseConfirmed=$false }
        'extra' { $bad.directory_catalog.native.Rows=@([ordered]@{
            NameUtf16Hex=(Stream-NameHex ':unapproved:$DATA');Size=1}) }
        'id' { $bad.file_catalog.after_id='0'*48 }
        'kind' { $bad.root.reparse=$true }
        'error87' { $bad.directory_catalog.native.QueryError=87 }
        'partial' { $bad.file_catalog.native.Complete=$false }
    }
    if (Test-CBaseline $bad $freeze 'C2') { throw "Phase C accepted catalog fault: $fault" }
}
$barrier=[ordered]@{trial='C1';source=$source;root_id=$rootId;manifest_digest=$digest;
    state='staged';stage_calls=2;target_handles_closed=$true;closure_unknown=$false;
    commit_calls=0;close_receipts=@('staged-writer:C:\fixture\target\approved.bin:closed',
        'staged-anchor:C:\fixture\target\approved.bin:closed',
        'staged-writer:C:\fixture\target:closed',
        'staged-anchor:C:\fixture\target:closed')}
if (-not (Test-CBarrier $barrier 'C1' $source $rootId $digest 'C:\fixture')) {
    throw 'Phase C exact source-bound barrier positive control failed.'
}
foreach ($fault in @('source','stage','close','duplicate-close','wrong-close',
        'missing-close','commit','root')) {
    $bad=Copy-Value $barrier
    switch ($fault) {
        'source' { $bad.source.actor_sha256='0'*64 }
        'stage' { $bad.stage_calls=1 }
        'close' { $bad.close_receipts[0]='staged-writer:C:\fixture\target\approved.bin:unknown' }
        'duplicate-close' { $bad.close_receipts[1]=$bad.close_receipts[0] }
        'wrong-close' { $bad.close_receipts[0]='staged-writer:C:\fixture\target\other.bin:closed' }
        'missing-close' { $bad.close_receipts=@($bad.close_receipts[0..2]) }
        'commit' { $bad.commit_calls=1 }
        'root' { $bad.root_id='0'*48 }
    }
    if (Test-CBarrier $bad 'C1' $source $rootId $digest 'C:\fixture') {
        throw "Phase C accepted barrier fault: $fault"
    }
}
function New-Receipt([string]$TrialName) {
    $fixed=if($TrialName -eq 'C1'){[byte]91}else{[byte]92}
    $b=Copy-Value $baseline
    $after=Copy-Value $baseline
    $name=if($TrialName -eq 'C1'){':phasec-file:$DATA'}else{':phasec-directory:$DATA'}
    if ($TrialName -eq 'C1') {
        $after.file_catalog=Catalog @('::$DATA',$name) ([long[]]@(6,1))
        $after.file_catalog.before_id=$fileId;$after.file_catalog.after_id=$fileId
    } else {
        $after.directory_catalog=Catalog @($name) ([long[]]@(1))
        $after.directory_catalog.before_id=$rootId;$after.directory_catalog.after_id=$rootId
    }
    $close=[ordered]@{Attempted=$true;Confirmed=$true;NativeError=0;ExceptionType=$null}
    $baseKind=if($TrialName -eq 'C1'){'file'}else{'directory'}
    $late=[ordered]@{base_kind_expected=$baseKind;stream_kind_expected='named-data';
        open_admitted=$false;open_error=6800;
        identity_observed=$false;file_id=$null;attributes=0;kind_matches=$false;
        stream_data_kind_matches=$false;
        identity_matches=$false;identity_error=$null;identity_native_error=0;
        write_attempted=$false;write_error=0;write_exception=$null;bytes_written=0;
        close=[ordered]@{Attempted=$false;Confirmed=$true;NativeError=0;ExceptionType=$null}}
    $positive=[ordered]@{base_kind_expected=$baseKind;stream_kind_expected='named-data';
        open_admitted=$true;open_error=0;
        identity_observed=$true;file_id=$(if($TrialName -eq 'C1'){$fileId}else{$rootId});
        attributes=32;kind_matches=$true;stream_data_kind_matches=$true;
        identity_matches=$true;identity_error=$null;identity_native_error=0;
        write_attempted=$true;write_error=0;write_exception=$null;bytes_written=1;close=$close}
    $preflight=[ordered]@{phase='exact-base-preflight';eligible=$true;
        root=[ordered]@{OpenAdmitted=$true;OpenError=0;FileId=$rootId;Attributes=16;
            KindMatches=$true;QueryError=$null;QueryNativeError=0;Close=$close};
        approved=[ordered]@{OpenAdmitted=$true;OpenError=0;FileId=$fileId;Attributes=32;
            KindMatches=$true;QueryError=$null;QueryNativeError=0;Close=$close}}
    $candidate=[ordered]@{schema='dark240-late-stream-phase-c-child-v1';role='candidate';
        trial=$TrialName;source=$source;source_identity=$sourceIdentity;scope='C:\fixture';
        status='intentional-rollback-after-late-stream-attempt';error=$null;cleanup_error=$null;
        stage_calls=2;commit_calls=0;rollback_calls=1;lease_state='rollback-succeeded';
        settlement='rollback-succeeded';closure_unknown=$false;
        gate1='unverified';target_collection=0;product=0}
    $actor=[ordered]@{schema='dark240-late-stream-phase-c-child-v1';role='observer-actor';
        trial=$TrialName;source=$source;source_identity=$sourceIdentity;
        scope='C:\fixture';status='completed';
        events=@($freeze,$preflight,
            [ordered]@{phase='baseline-default-streams-only';state=$b},
            [ordered]@{phase='late-stream-create-new';result=$late},
            [ordered]@{phase='independent-postrollback-before-support';state=(Copy-Value $b);
                named_stream=[ordered]@{status='absent'}},
            [ordered]@{phase='after-release-same-api-support';result=$positive},
            [ordered]@{phase='independent-postproof';data=[ordered]@{state=$after;
                named_stream=(Byte-Proof ([byte[]]@($fixed)))}});
        postproof=[ordered]@{state=$after;named_stream=(Byte-Proof ([byte[]]@($fixed)))};
        gate1='unverified';target_collection=0;product=0}
    $bar=Copy-Value $barrier;$bar.trial=$TrialName
    return [ordered]@{trial=$TrialName;scope='C:\fixture';controller_error=$null;
        elapsed_ms=1000;actor=[ordered]@{closed=$true;exit_code=0;capture_error=$null};
        candidate=[ordered]@{closed=$true;exit_code=0;capture_error=$null};
        ready=[ordered]@{trial=$TrialName;source=$source;root_id=$rootId;manifest_digest=$digest};
        barrier=$bar;late_marker=[ordered]@{trial=$TrialName;source=$source;result=$late};
        actor_receipt=$actor;candidate_receipt=$candidate}
}
foreach ($trial in @('C1','C2')) {
    $ok=New-Receipt $trial
    if ((Assert-CReceipt $ok $source) -cne 'late-stream-refused-supported-gate1-unverified') {
        throw "Phase C $trial exact refusal/support positive failed."
    }
    foreach ($fault in @('late-error','late-admitted-unknown','late-close-error',
            'late-close-exception','event-reorder','baseline-after-support','support-close',
            'support-write','support-id','support-context','support-stream-kind',
            'support-directory-attr','support-reparse-attr','support-query',
            'root-base-kind','file-base-kind','missing-stream','extra-stream','rollback',
            'foreign-source','source-git-unknown','missing-actor','default-bytes')) {
        $bad=Copy-Value $ok
        switch ($fault) {
            'late-error' { $bad.actor_receipt.events[3].result.open_error=5 }
            'late-admitted-unknown' { $bad.actor_receipt.events[3].result.open_admitted=$true }
            'late-close-error' { $bad.actor_receipt.events[3].result.close.NativeError=5 }
            'late-close-exception' { $bad.actor_receipt.events[3].result.close.ExceptionType='System.IO.IOException' }
            'event-reorder' { $temp=$bad.actor_receipt.events[0];
                $bad.actor_receipt.events[0]=$bad.actor_receipt.events[1];
                $bad.actor_receipt.events[1]=$temp }
            'baseline-after-support' { $temp=$bad.actor_receipt.events[4];
                $bad.actor_receipt.events[4]=$bad.actor_receipt.events[5];
                $bad.actor_receipt.events[5]=$temp }
            'support-close' { $bad.actor_receipt.events[5].result.close.Confirmed=$false }
            'support-write' { $bad.actor_receipt.events[5].result.bytes_written=0 }
            'support-id' { $bad.actor_receipt.events[5].result.file_id='0'*48 }
            'support-context' { $bad.actor_receipt.events[5].result.base_kind_expected='other' }
            'support-stream-kind' { $bad.actor_receipt.events[5].result.stream_kind_expected='index-allocation' }
            'support-directory-attr' { $bad.actor_receipt.events[5].result.attributes=16 }
            'support-reparse-attr' { $bad.actor_receipt.events[5].result.attributes=0x400 }
            'support-query' { $bad.actor_receipt.events[5].result.identity_observed=$false }
            'root-base-kind' { $bad.actor_receipt.events[1].root.Attributes=32 }
            'file-base-kind' { $bad.actor_receipt.events[1].approved.Attributes=16 }
            'missing-stream' { $bad.actor_receipt.postproof.named_stream.status='absent';
                $bad.actor_receipt.events[6].data.named_stream.status='absent' }
            'extra-stream' { $bad.actor_receipt.events[6].data.state.directory_catalog.native.Rows=@(
                [ordered]@{NameUtf16Hex=(Stream-NameHex ':extra:$DATA');Size=1}) }
            'rollback' { $bad.candidate_receipt.rollback_calls=0 }
            'foreign-source' { $bad.actor_receipt.source.actor_sha256='0'*64 }
            'source-git-unknown' { $bad.actor_receipt.source_identity.terminal.closed=$false }
            'missing-actor' { $bad.actor_receipt=$null }
            'default-bytes' { $bad.actor_receipt.events[6].data.state.approved.base64='AA==' }
        }
        Assert-Rejected { Assert-CReceipt $bad $source } "$trial $fault"
    }
}
foreach ($trial in @('C1','C2')) {
    $counter=New-Receipt $trial
    $selectedId=if($trial -eq 'C1'){$fileId}else{$rootId}
    $fixed=if($trial -eq 'C1'){[byte]91}else{[byte]92}
    $counter.actor_receipt.events[3].result=[ordered]@{
        base_kind_expected=$(if($trial -eq 'C1'){'file'}else{'directory'});
        stream_kind_expected='named-data';open_admitted=$true;open_error=0;
        identity_observed=$true;file_id=$selectedId;
        attributes=32;kind_matches=$true;stream_data_kind_matches=$true;
        identity_matches=$true;identity_error=$null;identity_native_error=0;
        write_attempted=$true;write_error=0;write_exception=$null;bytes_written=1;
        close=[ordered]@{Attempted=$true;Confirmed=$true;NativeError=0;ExceptionType=$null}}
    $counter.late_marker.result=$counter.actor_receipt.events[3].result
    $counter.actor_receipt.events[5]=[ordered]@{phase='support-skipped';
        known_refusal=$false;baseline_confirmed=$false}
    $streamName=if($trial -eq 'C1'){':phasec-file:$DATA'}else{':phasec-directory:$DATA'}
    $named=if($trial -eq 'C1'){
        Catalog @('::$DATA',$streamName) ([long[]]@(6,1))
    }else{Catalog @($streamName) ([long[]]@(1))}
    $named.before_id=$selectedId;$named.after_id=$selectedId
    if($trial -eq 'C1'){
        $counter.actor_receipt.events[4].state.file_catalog=$named
        $counter.actor_receipt.events[6].data.state.file_catalog=$named
    }else{
        $counter.actor_receipt.events[4].state.directory_catalog=$named
        $counter.actor_receipt.events[6].data.state.directory_catalog=$named
    }
    $counter.actor_receipt.events[4].named_stream=Byte-Proof ([byte[]]@($fixed))
    $counter.actor_receipt.events[6].data.named_stream=Byte-Proof ([byte[]]@($fixed))
    if ((Assert-CReceipt $counter $source) -cne
        'late-ads-exclusion-counterexample-gate1-unverified') {
        throw "Phase C $trial admitted bound stream was not retained as counterexample."
    }
    $counter.actor_receipt.events[3].result.identity_matches=$false
    Assert-Rejected { Assert-CReceipt $counter $source } "$trial unbound admitted stream"
    foreach ($fault in @('wrong-base-context','wrong-stream-context','wrong-id',
            'directory-attr','reparse-attr','query-unobserved','unknown-close',
            'missing-byteproof')) {
        $bad=Copy-Value $counter
        $bad.actor_receipt.events[3].result.identity_matches=$true
        switch ($fault) {
            'wrong-base-context' { $bad.actor_receipt.events[3].result.base_kind_expected='other' }
            'wrong-stream-context' { $bad.actor_receipt.events[3].result.stream_kind_expected='index-allocation' }
            'wrong-id' { $bad.actor_receipt.events[3].result.file_id='0'*48 }
            'directory-attr' { $bad.actor_receipt.events[3].result.attributes=16 }
            'reparse-attr' { $bad.actor_receipt.events[3].result.attributes=0x400 }
            'query-unobserved' { $bad.actor_receipt.events[3].result.identity_observed=$false }
            'unknown-close' { $bad.actor_receipt.events[3].result.close.Confirmed=$false }
            'missing-byteproof' { $bad.actor_receipt.events[6].data.named_stream.status='absent';
                $bad.actor_receipt.postproof.named_stream.status='absent' }
        }
        $bad.late_marker.result=$bad.actor_receipt.events[3].result
        Assert-Rejected { Assert-CReceipt $bad $source } "$trial admitted $fault"
    }
}

$phaseB=Join-Path $PSScriptRoot 'test-exact-manifest-txf-phase-b.ps1'
$sharedAst=[Management.Automation.Language.Parser]::ParseFile($phaseB,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Maintained owned-process helper cannot be parsed.' }
foreach ($name in @('Complete-OwnedChild','Observe-OwnedChildClosure')) {
    $definition=$sharedAst.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $name},$true)
    if ($null -eq $definition) { throw "Phase C missing maintained process helper: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$actorPath=Join-Path $PSScriptRoot '../support/exact-manifest-phase-c-streams.cs'
$script:preflightReceipts=[Collections.Generic.List[object]]::new()
$null=Invoke-CBoundedPreflight 'compile'
if ($script:preflightReceipts.Count -ne 1 -or
    -not $script:preflightReceipts[0].terminal.closed -or
    $script:preflightReceipts[0].error) {
    throw 'Phase C bounded compile preflight receipt is incomplete.'
}
$head=Read-HeadBounded
if ($head -cnotmatch '^[0-9a-f]{40}$' -or
    -not $script:sourceIdentityReceipt.started -or
    -not $script:sourceIdentityReceipt.terminal.closed -or
    $script:sourceIdentityReceipt.terminal.exit_code -ne 0) {
    throw 'Phase C bounded local source identity positive failed.'
}
Assert-Rejected { Read-HeadBounded 'dark-phase-c-nonexistent-git-executable' } 'start failure'
if ($script:sourceIdentityReceipt.started -or
    $null -eq $script:sourceIdentityReceipt.error -or
    $null -ne $script:sourceIdentityReceipt.terminal -or
    [string]::IsNullOrEmpty($script:sourceIdentityReceipt.completed_utc)) {
    throw 'Phase C failed Git process start erased its exact receipt.'
}
$repo=Join-Path ([IO.Path]::GetTempPath()) ('dark-phase-c-no-repository-'+[Guid]::NewGuid().ToString('N'))
Assert-Rejected { Read-HeadBounded } 'exit failure'
if (-not $script:sourceIdentityReceipt.started -or
    -not $script:sourceIdentityReceipt.terminal.closed -or
    $script:sourceIdentityReceipt.terminal.exit_code -eq 0 -or
    [string]::IsNullOrEmpty($script:sourceIdentityReceipt.terminal.stderr) -or
    $null -eq $script:sourceIdentityReceipt.error) {
    throw 'Phase C failed local Git identity lost raw stderr or exit status.'
}

Write-Host 'Phase C late stream protocol tests passed.'
