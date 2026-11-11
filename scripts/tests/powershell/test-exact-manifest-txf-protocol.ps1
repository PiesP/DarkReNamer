[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../modules/powershell/controller-owned-root-guard.ps1')
Add-Type -TypeDefinition $script:DrOwnedRootGuardSource -ErrorAction Stop
Add-Type -Path (Join-Path $PSScriptRoot '../support/exact-manifest-phase-b-observer.cs') -ErrorAction Stop
$candidate=[DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease]

function Assert-Rejected([scriptblock]$Action,[string]$Expected) {
    $caught=$false
    try { & $Action }
    catch {
        $caught=$true
        if ($_.Exception.Message -notlike ('*' + $Expected + '*')) { throw }
    }
    if (-not $caught) { throw "Expected Phase B rejection: $Expected" }
}

$owner=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('S-1-5-21-1'))
$sddl=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('O:SYG:SYD:(A;;FA;;;SY)'))
$id1='a'*48;$id2='b'*48;$sha='c'*64
$rootRow=".|directory|$id1|-|-|$owner|$sddl|default-stream-only"
$fileRow="6100|file|$id2|1|$sha|$owner|$sddl|default-stream-only"
$approved=[string[]]@($rootRow,$fileRow)
$digest=$candidate::RequireExactManifest($approved,[string[]]@($approved))
if ($digest -cnotmatch '^[0-9a-f]{64}$') { throw 'Exact manifest digest is not SHA-256.' }
if ([DarkPhaseBFixtureObserver]::DigestRows($approved) -cne $digest) {
    throw 'Independent observer and candidate disagree on raw UTF-16 row digest.'
}
$profile='C:\Users\runneradmin'
$scope=$profile + '\AppData\Local\Temp\Dark180-TxfPhaseB\0123456789abcdef0123456789abcdef'
if ($candidate::RequireFixturePathScope($scope,($scope + '\target'),$profile) -cne $scope) {
    throw 'Exact fixture path predicate rejected its positive control.'
}
$source='d'*40;$nonceHash='e'*64;$rootId='f'*48
$approval=[string[]]@($source,$nonceHash,$scope,($scope + '\target'),$rootId,$digest)
$candidate::RequireFixtureApprovalFields($approval,$source,$nonceHash,$scope,
    ($scope + '\target'),$rootId,$digest)
foreach ($index in @(0,1,2,3,4,5)) {
    $changed=[string[]]@($approval)
    $changed[$index]='other'
    Assert-Rejected { $candidate::RequireFixtureApprovalFields($changed,$source,$nonceHash,$scope,
            ($scope + '\target'),$rootId,$digest) } 'predelete approval differs'
}
Assert-Rejected { $candidate::RequireFixtureApprovalFields([string[]]@($approval[0..4]),
        $source,$nonceHash,$scope,($scope + '\target'),$rootId,$digest) } 'predelete approval differs'
$protocol=[DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease+FixtureLeaseProtocol]::new()
$protocol.Acquired();$protocol.StageStarted();$protocol.StageCompleted()
$protocol.CommitRequested();$protocol.CommitReturned($true)
Assert-Rejected { $protocol.CommitRequested() } 'cannot proceed'
Assert-Rejected { $protocol.RolledBack($true) } 'cannot repeat or follow commit'
$protocol=[DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease+FixtureLeaseProtocol]::new()
$protocol.Acquired();$protocol.RolledBack($true)
Assert-Rejected { $protocol.StageStarted() } 'cannot repeat'
Assert-Rejected { $protocol.RolledBack($true) } 'cannot repeat or follow commit'
$protocol=[DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease+FixtureLeaseProtocol]::new()
$protocol.Acquired();$protocol.StageStarted();$protocol.CloseUnknown()
Assert-Rejected { $protocol.StageCompleted() } 'confirmed handle closure'
$protocol.CloseUnknown() # A later cleanup pass cannot turn unknown closure into confirmed closure.
Assert-Rejected { $protocol.StageCompleted() } 'confirmed handle closure'
$protocol.RolledBack($true)
if ($protocol.State -cne 'rollback-succeeded-closure-unknown') {
    throw 'Unknown native close was erased by successful rollback.'
}
Assert-Rejected { $protocol.CommitRequested() } 'cannot proceed'
$protocol=[DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease+FixtureLeaseProtocol]::new()
$protocol.Acquired();$protocol.StageStarted();$protocol.StageCompleted()
$protocol.CommitRequested();$protocol.CommitReturned($false)
Assert-Rejected { $protocol.CommitRequested() } 'cannot proceed'
Assert-Rejected { $protocol.RolledBack($true) } 'cannot repeat or follow commit'
Assert-Rejected { $candidate::RequireFixturePathScope(
        'C:\ProgramData\DarkReNamerVmRuns\0123456789abcdef0123456789abcdef',
        'C:\ProgramData\DarkReNamerVmRuns\0123456789abcdef0123456789abcdef\target',
        $profile) } 'protected-root component'
Assert-Rejected { $candidate::RequireFixturePathScope(
        ($profile + '\AppData\Local\Temp\Dark180-TxfPhaseB\..\0123456789abcdef0123456789abcdef'),
        ($profile + '\AppData\Local\Temp\Dark180-TxfPhaseB\..\0123456789abcdef0123456789abcdef\target'),
        $profile) } 'alias or protected-root component'
Assert-Rejected { $candidate::RequireFixturePathScope(
        ($profile + '\AppData\Local\Temp\DARK18~1\0123456789abcdef0123456789abcdef'),
        ($profile + '\AppData\Local\Temp\DARK18~1\0123456789abcdef0123456789abcdef\target'),
        $profile) } 'alias or protected-root component'
Assert-Rejected { $candidate::RequireFixturePathScope(
        ($profile + '\AppData\Local\Temp.\Dark180-TxfPhaseB\0123456789abcdef0123456789abcdef'),
        ($profile + '\AppData\Local\Temp.\Dark180-TxfPhaseB\0123456789abcdef0123456789abcdef\target'),
        $profile) } 'alias or protected-root component'
Assert-Rejected { $candidate::RequireFixturePathScope(
        ($profile + '\AppData\Local\Temp \Dark180-TxfPhaseB\0123456789abcdef0123456789abcdef'),
        ($profile + '\AppData\Local\Temp \Dark180-TxfPhaseB\0123456789abcdef0123456789abcdef\target'),
        $profile) } 'alias or protected-root component'
Assert-Rejected { $candidate::RequireFixturePathScope(
        'C:\ProgramData\DarkReNamerVmRuns.\0123456789abcdef0123456789abcdef',
        'C:\ProgramData\DarkReNamerVmRuns.\0123456789abcdef0123456789abcdef\target',
        $profile) } 'alias or protected-root component'
Assert-Rejected { $candidate::RequireFixturePathScope(
        ($profile + '\AppData\Local\Temp\Dark180-TxfPhaseB\0123456789abcdef0123456789abcdef'),
        ($profile + '\AppData\Local\Temp\Dark180-TxfPhaseB\0123456789abcdef0123456789abcdef\other'),
        $profile) } 'outside exact local profile temp scope'
Assert-Rejected { $candidate::RequireExactManifest($approved,[string[]]@($approved[1],$approved[0])) } 'row differs'
Assert-Rejected { $candidate::RequireExactManifest($approved,[string[]]@($approved[0])) } 'incomplete'
Assert-Rejected { $candidate::RequireExactManifest($approved,[string[]]@($approved[0],$fileRow.Replace($id2,$id1))) } 'row differs'
Assert-Rejected { $candidate::RequireExactManifest([string[]]@($rootRow,$rootRow),[string[]]@($rootRow,$rootRow)) } 'row differs'
Assert-Rejected { $candidate::RequireExactManifest([string[]]@(''),[string[]]@('')) } 'row is empty'
Assert-Rejected { $candidate::RequireExactManifest($null,$approved) } 'absent'
$unpaired=[string][char]0xD800
$replacement=[string][char]0xFFFD
$unpairedHex=$candidate::EncodeComponentUtf16($unpaired)
$replacementHex=$candidate::EncodeComponentUtf16($replacement)
if ($unpairedHex -ceq $replacementHex -or $unpairedHex -cne '00d8') {
    throw 'Raw UTF-16 component encoding conflated a surrogate with replacement.'
}
$surrogateRow="$unpairedHex|file|$id2|1|$sha|$owner|$sddl|default-stream-only"
$replacementRow="$replacementHex|file|$id2|1|$sha|$owner|$sddl|default-stream-only"
$surrogateDigest=$candidate::RequireExactManifest([string[]]@($rootRow,$surrogateRow),
    [string[]]@($rootRow,$surrogateRow))
$replacementDigest=$candidate::RequireExactManifest([string[]]@($rootRow,$replacementRow),
    [string[]]@($rootRow,$replacementRow))
if ($surrogateDigest -ceq $replacementDigest) { throw 'Raw UTF-16 manifest digests collided.' }
Assert-Rejected { $candidate::RequireExactManifest([string[]]@($unpaired),[string[]]@($unpaired)) } 'canonical ASCII'
if ($IsWindows) {
    Assert-Rejected { $candidate::PrepareFixtureOnly('C:\DarkReNamerVmRuns\original',
            'C:\DarkReNamerVmRuns\original\target', 'a'*32,
            '0123456789abcdef0123456789abcdef01234567') } 'protected-root component'
}
$nativeFixture=Join-Path $PSScriptRoot 'test-exact-manifest-txf-phase-b.ps1'
$tokens=$null;$parseErrors=$null
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile($nativeFixture,
    [ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Phase B native fixture has PowerShell syntax errors.' }
foreach ($name in @('Write-NewText','Write-Marker','Read-Marker','Test-MarkerReady',
        'Wait-Marker','Wait-ActorBarrier','Get-PhaseBExceptionChain',
        'Get-ExactOpenWriterRefusalCode','Complete-OwnedChild','Observe-OwnedChildClosure',
        'Read-WorkerRecord','Assert-PhaseB6LReceipt','Assert-PhaseBTrialReceipt')) {
    $definition=$fixtureAst.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $name},$true)
    if ($null -eq $definition) { throw "Actual Phase B terminal function is missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Hash-Control([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
$sourceBinding=[ordered]@{commit='a'*40;fixture_sha256='b'*64;module_sha256='c'*64;
    observer_sha256='d'*64;actor_sha256='e'*64}
$sentinel=[byte[]](72,63,54,45,36,27)
$approvedBytes=[byte[]](9,18,27,36,45,54)
$bytesProof={param([byte[]]$Bytes)
    return [ordered]@{status='present';base64=[Convert]::ToBase64String($Bytes);
        sha256=(Hash-Control $Bytes);bytes=$Bytes.Length}
}
$post=[ordered]@{root=[ordered]@{status='absent'};approved=[ordered]@{status='absent'};
    sentinel=(& $bytesProof $sentinel);approved_before=(& $bytesProof $approvedBytes);
    nested=[ordered]@{status='absent'};sibling=[ordered]@{status='absent'}}
$frozenRoot='f'*48;$frozenFile='1'*48;$frozenDigest='2'*64
$freeze=[ordered]@{phase='independent-freeze';row_count=5;root_id=$frozenRoot;
    approved_id=$frozenFile;manifest_digest=$frozenDigest;
    approved_before=(& $bytesProof $approvedBytes)}
$actorReceipt=[ordered]@{schema='dark180-exact-manifest-phase-b-child-v1';role='observer-actor';
    trial='B1';scope='C:\fixture';source=$sourceBinding;status='completed';postproof=$post;
    events=@($freeze);gate1='unverified';target_collection=0;product=0}
$candidateReceipt=[ordered]@{schema='dark180-exact-manifest-phase-b-child-v1';role='candidate';
    trial='B1';scope='C:\fixture';source=$sourceBinding;
    status='commit-call-succeeded-poststate-unverified';
    cleanup_error=$null;closure_unknown=$false;settlement='commit-call-succeeded-poststate-unverified';
    lease_state='commit-returned-poststate-unverified';commit_calls=1;rollback_calls=0;
    stage_calls=5;gate1='unverified';target_collection=0;product=0}
$complete=[ordered]@{trial='B1';scope='C:\fixture';controller_error=$null;
    ready=[ordered]@{root_id=$frozenRoot;manifest_digest=$frozenDigest};
    actor=[ordered]@{closed=$true;capture_error=$null;exit_code=0};
    candidate=[ordered]@{closed=$true;capture_error=$null;exit_code=0;kill_requested=$false};
    actor_receipt=$actorReceipt;candidate_receipt=$candidateReceipt;barrier=$null}
if ((Assert-PhaseBTrialReceipt $complete 'B1' $sourceBinding) -cne
    'exact-fixture-deleted-gate1-unverified') {
    throw 'Actual Phase B controller rejected a complete positive protocol receipt.'
}
foreach ($changed in @('controller-error','missing-controller-error','missing-postproof',
        'missing-source','unclosed','unknown-closure','false-commit','lost-sentinel',
        'mismatched-freeze','mismatched-ready')) {
    $copy=$complete | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
    switch ($changed) {
        'controller-error' { $copy.controller_error='observer failed' }
        'missing-controller-error' { $copy.Remove('controller_error') }
        'missing-postproof' { $copy.actor_receipt.Remove('postproof') }
        'missing-source' { $copy.candidate_receipt.source.Remove('module_sha256') }
        'unclosed' { $copy.candidate.closed=$false }
        'unknown-closure' { $copy.candidate_receipt.closure_unknown=$true }
        'false-commit' { $copy.candidate_receipt.commit_calls=0 }
        'lost-sentinel' { $copy.actor_receipt.postproof.sentinel.status='absent' }
        'mismatched-freeze' { $copy.actor_receipt.events[0].manifest_digest='3'*64 }
        'mismatched-ready' { $copy.ready.root_id='4'*48 }
    }
    $rejected=$false
    try { $null=Assert-PhaseBTrialReceipt $copy 'B1' $sourceBinding }
    catch { $rejected=$true }
    if (-not $rejected) { throw "Actual Phase B controller accepted protocol fault: $changed" }
}
$death=$complete | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$death.trial='B7';$death.actor_receipt.trial='B7';$death.candidate_receipt=$null
$death.actor_receipt.events[0].row_count=2
$death.candidate.exit_code=137;$death.candidate.kill_requested=$true
$death.actor_receipt.postproof.root.status='present'
$death.actor_receipt.postproof.approved=& $bytesProof $approvedBytes
$death.actor_receipt.postproof.root_id=$frozenRoot
$death.actor_receipt.postproof.approved_id=$frozenFile
$death.barrier=[ordered]@{trial='B7';state='staged';stage_calls=2;
    target_handles_closed=$true;commit_calls=0}
if ((Assert-PhaseBTrialReceipt $death 'B7' $sourceBinding) -cne
    'worker-death-preserved-gate1-unverified') {
    throw 'Actual Phase B controller rejected a proven owned-death receipt.'
}
$death.barrier.commit_calls=1
Assert-Rejected { Assert-PhaseBTrialReceipt $death 'B7' $sourceBinding } 'precommit barrier'
$death.barrier.commit_calls=0
$death.actor_receipt.postproof.approved.status='absent'
Assert-Rejected { Assert-PhaseBTrialReceipt $death 'B7' $sourceBinding } 'independently preserved'
$early=$complete | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$early.trial='B2';$early.actor_receipt.trial='B2';$early.candidate_receipt.trial='B2'
$early.actor_receipt.postproof.root.status='present'
$early.actor_receipt.postproof.approved=& $bytesProof $approvedBytes
$early.actor_receipt.postproof.root_id=$frozenRoot
$early.actor_receipt.postproof.approved_id=$frozenFile
$early.actor_receipt.events[0].row_count=2
$early.actor_receipt.events+=@([ordered]@{phase='required-barrier-unverified';
    reason='candidate-rejected-before-barrier'})
$early.candidate_receipt.status='rejected-or-unknown'
$early.candidate_receipt.settlement='rollback-succeeded'
$early.candidate_receipt.lease_state='rollback-succeeded'
$early.candidate_receipt.commit_calls=0;$early.candidate_receipt.rollback_calls=1
if ((Assert-PhaseBTrialReceipt $early 'B2' $sourceBinding) -cne
    'required-barrier-unverified-candidate-rejected-preserved') {
    throw 'Actual Phase B controller mislabeled an unreachable required barrier.'
}
$early.actor_receipt.postproof.approved.base64=[Convert]::ToBase64String([byte[]](99))
Assert-Rejected { Assert-PhaseBTrialReceipt $early 'B2' $sourceBinding } 'bytes changed'
$late=$early | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$late.trial='B2';$late.actor_receipt.trial='B2';$late.candidate_receipt.trial='B2'
$late.actor_receipt.postproof.approved=& $bytesProof $approvedBytes
$late.actor_receipt.postproof.late_child=& $bytesProof ([byte[]](81))
$late.actor_receipt.events=@($late.actor_receipt.events[0],
    [ordered]@{phase='late-child-after-last-close';admitted=$true;written=$true;native_error=0})
$late.candidate_receipt.status='intentional-rollback-post-barrier'
$late.barrier=[ordered]@{trial='B2';state='staged';stage_calls=2;
    target_handles_closed=$true;commit_calls=0}
if ((Assert-PhaseBTrialReceipt $late 'B2' $sourceBinding) -cne
    'intentional-rollback-late-child-preserved-gate1-unverified') {
    throw 'Actual Phase B controller rejected a complete intentional-rollback receipt.'
}
$late.actor_receipt.postproof.late_child.status='absent'
Assert-Rejected { Assert-PhaseBTrialReceipt $late 'B2' $sourceBinding } 'late child'

$b6=$early | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$b6.trial='B6L';$b6.actor_receipt.trial='B6L';$b6.candidate_receipt.trial='B6L'
$b6.actor_receipt.postproof.approved=& $bytesProof $approvedBytes
$baselineOwner='a'*64;$baselineSddl='b'*64;$afterSupport='c'*64
$rootOwner='d'*64;$rootSddl='e'*64
$b6.actor_receipt.postproof.approved_security=[ordered]@{
    owner_sha256=$baselineOwner;sddl_sha256=$afterSupport}
$b6.actor_receipt.postproof.root_security=[ordered]@{
    owner_sha256=$rootOwner;sddl_sha256=$rootSddl}
$b6.actor_receipt.events[0].root_security=[ordered]@{
    owner_sha256=$rootOwner;sddl_sha256=$rootSddl}
$b6.actor_receipt.events[0].approved_security=[ordered]@{
    owner_sha256=$baselineOwner;sddl_sha256=$baselineSddl}
$b6.candidate_receipt.status='intentional-rollback-B6L-post-barrier'
$b6.candidate_receipt.stage_calls=2
$b6.barrier=[ordered]@{trial='B6L';state='staged';stage_calls=2;
    target_handles_closed=$true;commit_calls=0}
$lateDenied=[ordered]@{open_admitted=$false;open_error=6800;
    identity_observed=$false;identity_error=0;identity_exception=$null;file_id=$null;
    set_attempted=$false;set_error=0;set_exception=$null;
    before_observed=$false;before_error=0;before_exception=$null;before_sha256=$null;
    after_observed=$false;after_error=0;after_exception=$null;after_sha256=$null}
$supportPositive=[ordered]@{open_admitted=$true;open_error=0;
    identity_observed=$true;identity_error=0;identity_exception=$null;
    identity_matches=$true;file_id=$frozenFile;
    before_observed=$true;before_error=0;before_exception=$null;
    before_sha256=$baselineSddl;
    set_attempted=$true;set_error=0;set_exception=$null;
    after_observed=$true;after_error=0;after_exception=$null;
    after_sha256=$afterSupport;
    close=[ordered]@{Attempted=$true;Confirmed=$true;NativeError=0;
        ExceptionType=$null;ExceptionMessage=$null}}
$b6.actor_receipt.events=@($b6.actor_receipt.events[0],
    [ordered]@{phase='B6L-prepared-no-held-handle';approved_id=$frozenFile;
        proposed_sddl_sha256=$afterSupport;
        preparation_close=[ordered]@{Attempted=$true;Confirmed=$true;
            NativeError=0;ExceptionType=$null};
        requested_access='READ_CONTROL|WRITE_DAC|WRITE_OWNER';share='READ|WRITE|DELETE';
        disposition='OPEN_EXISTING|OPEN_REPARSE_POINT';
        baseline=[ordered]@{owner_sha256=$baselineOwner;sddl_sha256=$baselineSddl}},
    [ordered]@{phase='B6L-late-metadata-probe';data=$lateDenied},
    [ordered]@{phase='B6L-late-handle-close-after-candidate-exit';
        data=[ordered]@{Attempted=$false;Confirmed=$true;NativeError=0;
            ExceptionType=$null;ExceptionMessage=$null}},
    [ordered]@{phase='B6L-independent-postrollback-before-support';
        root=[ordered]@{status='present';reparse=$false};root_id=$frozenRoot;
        approved_id=$frozenFile;approved=(& $bytesProof $approvedBytes);
        sentinel=(& $bytesProof $sentinel);
        root_security=[ordered]@{owner_sha256=$rootOwner;sddl_sha256=$rootSddl};
        security=[ordered]@{owner_sha256=$baselineOwner;sddl_sha256=$baselineSddl}},
    [ordered]@{phase='B6L-after-release-support-probe';data=$supportPositive})
$b6.late_probe_marker=[ordered]@{phase='B6L-late-probe-complete';data=$lateDenied}
if ((Assert-PhaseBTrialReceipt $b6 'B6L' $sourceBinding) -cne
    'late-metadata-open-refused-supported-gate1-unverified') {
    throw 'B6L exact late-open refusal and after-release DACL support were rejected.'
}
$b6WriteRefused=$b6 | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$b6WriteRefused.actor_receipt.events[2].data=[ordered]@{
    open_admitted=$true;open_error=0;identity_observed=$true;identity_error=0;
    identity_exception=$null;identity_matches=$true;
    file_id=$frozenFile;before_observed=$true;before_error=0;
    before_exception=$null;before_sha256=$baselineSddl;
    set_attempted=$true;set_error=32;set_exception=$null;
    after_observed=$true;after_error=0;after_exception=$null;
    after_sha256=$baselineSddl}
$b6WriteRefused.actor_receipt.events[3].data.Attempted=$true
$b6WriteRefused.late_probe_marker.data=$b6WriteRefused.actor_receipt.events[2].data
if ((Assert-PhaseBTrialReceipt $b6WriteRefused 'B6L' $sourceBinding) -cne
    'late-dacl-write-refused-supported-gate1-unverified') {
    throw 'B6L exact late-DACL refusal and support were rejected.'
}
$b6NoBefore=$b6WriteRefused | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$b6NoBefore.actor_receipt.events[2].data.before_observed=$false
$b6NoBefore.actor_receipt.events[2].data.before_sha256=$null
Assert-Rejected { Assert-PhaseBTrialReceipt $b6NoBefore 'B6L' $sourceBinding } 'security observation'
foreach ($change in @('wrong-file-id','late-set-succeeded','late-set-error-5',
        'late-set-error-6805','late-after-unobserved','late-open-error-5',
        'late-open-error-6805','phase-mismatch','prep-close-unknown',
        'close-unknown','pre-support-bytes',
        'pre-support-dacl','set-exception','marker-mismatch',
        'support-unchanged','proposed-mismatch',
        'owner-drift')) {
    $bad=$b6WriteRefused | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
    switch ($change) {
        'wrong-file-id' { $bad.actor_receipt.events[2].data.file_id='0'*48 }
        'late-set-succeeded' { $bad.actor_receipt.events[2].data.set_error=0;
            $bad.actor_receipt.events[2].data.after_sha256=$afterSupport }
        'late-set-error-5' { $bad.actor_receipt.events[2].data.set_error=5 }
        'late-set-error-6805' { $bad.actor_receipt.events[2].data.set_error=6805 }
        'late-after-unobserved' { $bad.actor_receipt.events[2].data.after_observed=$false }
        'late-open-error-5' { $bad.actor_receipt.events[2].data.open_admitted=$false;
            $bad.actor_receipt.events[2].data.open_error=5;
            $bad.actor_receipt.events[2].data.identity_observed=$false;
            $bad.actor_receipt.events[2].data.set_attempted=$false;
            $bad.actor_receipt.events[2].data.before_observed=$false;
            $bad.actor_receipt.events[2].data.after_observed=$false;
            $bad.actor_receipt.events[3].data.Attempted=$false }
        'late-open-error-6805' { $bad.actor_receipt.events[2].data.open_admitted=$false;
            $bad.actor_receipt.events[2].data.open_error=6805;
            $bad.actor_receipt.events[2].data.identity_observed=$false;
            $bad.actor_receipt.events[2].data.set_attempted=$false;
            $bad.actor_receipt.events[2].data.before_observed=$false;
            $bad.actor_receipt.events[2].data.after_observed=$false;
            $bad.actor_receipt.events[3].data.Attempted=$false }
        'phase-mismatch' { $bad.barrier.target_handles_closed=$false }
        'prep-close-unknown' { $bad.actor_receipt.events[1].preparation_close.Confirmed=$false }
        'close-unknown' { $bad.actor_receipt.events[3].data.Confirmed=$false }
        'pre-support-bytes' { $bad.actor_receipt.events[4].approved.base64='AA==' }
        'pre-support-dacl' { $bad.actor_receipt.events[4].security.sddl_sha256='0'*64 }
        'set-exception' { $bad.actor_receipt.events[2].data.set_exception='managed throw' }
        'marker-mismatch' { $bad.late_probe_marker.data.open_error=5 }
        'support-unchanged' { $bad.actor_receipt.events[5].data.after_sha256=$baselineSddl }
        'proposed-mismatch' { $bad.actor_receipt.events[1].proposed_sddl_sha256='0'*64 }
        'owner-drift' { $bad.actor_receipt.postproof.approved_security.owner_sha256='0'*64 }
    }
    $rejected=$false
    try { $null=Assert-PhaseBTrialReceipt $bad 'B6L' $sourceBinding }
    catch { $rejected=$true }
    if (-not $rejected) { throw "B6L protocol accepted unproved evidence: $change" }
}

Add-Type -TypeDefinition @'
using System.ComponentModel;
public static class PhaseBThrownNativeProbe {
    public static void Throw1224() { throw new Win32Exception(1224,"probe native refusal"); }
}
'@ -ErrorAction Stop
$actualChain=$null
try { [PhaseBThrownNativeProbe]::Throw1224() }
catch { $actualChain=@(Get-PhaseBExceptionChain $_.Exception) }
$actualNative=@($actualChain | Where-Object { $null -ne $_.native_error })
if ($actualNative.Count -ne 1 -or $actualNative[0].native_error -ne 1224 -or
    @($actualNative[0].method_frames) -cnotcontains 'PhaseBThrownNativeProbe::Throw1224') {
    throw 'Actual exception-chain extractor lost the native code or throwing-method provenance.'
}
$exactChain=$actualChain | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
foreach ($node in $exactChain) {
    if ($null -ne $node.native_error) {
        $node.method_frames=@('DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease::OpenWriter')
    }
}
if ((Get-ExactOpenWriterRefusalCode $exactChain) -ne 1224) {
    throw 'Exact mapped-file refusal metadata was rejected.'
}
$transactionalChain=$exactChain | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
@($transactionalChain | Where-Object { $null -ne $_.native_error })[0].native_error=6800
if ((Get-ExactOpenWriterRefusalCode $transactionalChain) -ne 6800) {
    throw 'Observed transactional-conflict code lost exact OpenWriter provenance.'
}
foreach ($change in @('code-32','code-5','code-6805','code-zero','wrong-method',
        'extra-native','message-only','no-chain')) {
    $bad=$exactChain | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
    switch ($change) {
        'code-32' { @($bad | Where-Object { $null -ne $_.native_error })[0].native_error=32 }
        'code-5' { @($bad | Where-Object { $null -ne $_.native_error })[0].native_error=5 }
        'code-6805' { @($bad | Where-Object { $null -ne $_.native_error })[0].native_error=6805 }
        'code-zero' { @($bad | Where-Object { $null -ne $_.native_error })[0].native_error=0 }
        'wrong-method' { @($bad | Where-Object { $null -ne $_.native_error })[0].method_frames=@('Other::OpenWriter') }
        'extra-native' { $bad+=@([ordered]@{type='System.ComponentModel.Win32Exception';
            native_error=1224;message='same text';hresult=0;method_frames=@(
                'DarkReNamerVmOwnedRootGuard+ExactManifestTxFFixtureLease::OpenWriter')}) }
        'message-only' { @($bad | Where-Object { $null -ne $_.native_error })[0].native_error=$null;
            @($bad | Where-Object { $_.message -like '*probe native refusal*' })[0].message='OpenWriter ERROR_USER_MAPPED_FILE 1224' }
        'no-chain' { $bad=@() }
    }
    if ($null -ne (Get-ExactOpenWriterRefusalCode $bad)) {
        throw "Mapped-file classifier accepted unproved provenance: $change"
    }
}
$mapped=$early | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$mapped.trial='B4';$mapped.actor_receipt.trial='B4';$mapped.candidate_receipt.trial='B4'
$mapped.actor_receipt.postproof.approved=& $bytesProof ([byte[]](82,18,27,36,45,54))
$mapped.actor_receipt.events=@($mapped.actor_receipt.events[0],
    [ordered]@{phase='writable-mapping-held-after-file-close'},
    [ordered]@{phase='required-barrier-unverified';reason='candidate-rejected-before-barrier'},
    [ordered]@{phase='approved-before-mapping-support-control';
        candidate_exit_confirmed=$true;data=(& $bytesProof $approvedBytes)},
    [ordered]@{phase='held-mapping-after-candidate-exit-support-control';
        candidate_exit_confirmed=$true;byte=82;written=$true;error=$null})
$mapped.candidate_receipt.stage_calls=0
$mapped.candidate_receipt.error=[ordered]@{exception_chain=$exactChain}
if ((Assert-PhaseBTrialReceipt $mapped 'B4' $sourceBinding) -cne
    'safe-prestage-refusal-with-writable-mapping-control') {
    throw 'B4 exact native refusal and held-mapping control did not admit their narrow safe verdict.'
}
$mapped6800=$mapped | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$mapped6800.candidate_receipt.error.exception_chain=$transactionalChain
if ((Assert-PhaseBTrialReceipt $mapped6800 'B4' $sourceBinding) -cne
    'prestage-transactional-conflict-with-writable-mapping-control') {
    throw 'B4 transactional conflict lacked its distinct reviewed diagnostic verdict.'
}
foreach ($code in @(32,5,6805,0)) {
    $badMapped=$mapped | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
    @($badMapped.candidate_receipt.error.exception_chain | Where-Object {
        $null -ne $_.native_error })[0].native_error=$code
    if ((Assert-PhaseBTrialReceipt $badMapped 'B4' $sourceBinding) -cne
        'mapping-write-barrier-unverified-acquisition-rejected-preserved') {
        throw "B4 native error $code was misclassified as a reviewed safe refusal."
    }
}
$badMapped=$mapped | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$badMapped.actor_receipt.events[4].written=$false
Assert-Rejected { Assert-PhaseBTrialReceipt $badMapped 'B4' $sourceBinding } 'bytes changed'
$badMapped=$mapped | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$badMapped.candidate_receipt.stage_calls=1
if ((Assert-PhaseBTrialReceipt $badMapped 'B4' $sourceBinding) -cne
    'mapping-write-barrier-unverified-acquisition-rejected-preserved') {
    throw 'B4 staged candidate was misclassified as a pre-stage refusal.'
}
$badMapped=$mapped6800 | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
$badMapped.candidate_receipt.settlement='rollback-outcome-unknown'
Assert-Rejected { Assert-PhaseBTrialReceipt $badMapped 'B4' $sourceBinding } 'unknown settlement'
foreach ($change in @('missing-precontrol','bad-precontrol-bytes','bad-precontrol-hash',
        'missing-frame','missing-chain')) {
    $badMapped=$mapped6800 | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
    switch ($change) {
        'missing-precontrol' { $badMapped.actor_receipt.events=@(
            $badMapped.actor_receipt.events | Where-Object {
                $_.phase -cne 'approved-before-mapping-support-control' }) }
        'bad-precontrol-bytes' { $badMapped.actor_receipt.events[3].data.base64='AA==' }
        'bad-precontrol-hash' { $badMapped.actor_receipt.events[3].data.sha256='0'*64 }
        'missing-frame' { @($badMapped.candidate_receipt.error.exception_chain | Where-Object {
            $null -ne $_.native_error })[0].method_frames=@() }
        'missing-chain' { $badMapped.candidate_receipt.error.exception_chain=@() }
    }
    if ((Assert-PhaseBTrialReceipt $badMapped 'B4' $sourceBinding) -cne
        'mapping-write-barrier-unverified-acquisition-rejected-preserved') {
        throw "B4 evidence gap was misclassified as a safe conflict: $change"
    }
}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('dark180-phase-b-marker-protocol-'+[Guid]::NewGuid().ToString('N'))
$otherRoot=Join-Path ([IO.Path]::GetTempPath()) ('dark180-phase-b-marker-protocol-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
[void][IO.Directory]::CreateDirectory($otherRoot)
$Scope=$testRoot
try {
    $unpublished=Join-Path $testRoot 'unpublished.json'
    Write-NewText $unpublished '{'
    if (Test-MarkerReady $unpublished) { throw 'A data-only marker became observable.' }
    Assert-Rejected { Read-Marker $unpublished } 'not published'
    Assert-Rejected { Wait-Marker $unpublished 0 } 'unavailable'
    $noData=Join-Path $testRoot 'no-data.json'
    Write-NewText ($noData+'.ready') ''
    Assert-Rejected { Test-MarkerReady $noData } 'readiness exists without data'
    $published=Join-Path $testRoot 'published.json'
    Write-Marker $published ([ordered]@{trial='B2';phase='after-last-close'})
    if (-not (Test-MarkerReady $published)) { throw 'A fully published marker was not observable.' }
    $payload=Read-Marker $published
    if ($payload.trial -cne 'B2' -or $payload.phase -cne 'after-last-close' -or
        (Wait-Marker $published 0).trial -cne 'B2') {
        throw 'Published marker payload changed in transit.'
    }
    $before=(Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash
    Assert-Rejected { Write-Marker $published ([ordered]@{trial='B6L'}) } 'exists'
    if ((Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash -cne $before) {
        throw 'Duplicate publication overwrote immutable marker data.'
    }
    $malformed=Join-Path $testRoot 'malformed.json'
    Write-NewText $malformed '{'
    Write-NewText ($malformed+'.ready') ''
    Assert-Rejected { Read-Marker $malformed } 'malformed'
    $wrongSchema=Join-Path $testRoot 'wrong-schema.json'
    Write-NewText $wrongSchema (([ordered]@{schema='old';scope=$testRoot;
        marker='wrong-schema.json';value=[ordered]@{trial='B2'}} | ConvertTo-Json -Compress))
    Write-NewText ($wrongSchema+'.ready') ''
    Assert-Rejected { Read-Marker $wrongSchema } 'scope, name or value differs'
    $nullValue=Join-Path $testRoot 'null-value.json'
    Write-NewText $nullValue (([ordered]@{schema='dark180-phase-b-marker-v2';scope=$testRoot;
        marker='null-value.json';value=$null} | ConvertTo-Json -Compress))
    Write-NewText ($nullValue+'.ready') ''
    Assert-Rejected { Read-Marker $nullValue } 'scope, name or value differs'
    $mixed=Join-Path $otherRoot 'published.json'
    Write-NewText $mixed ([IO.File]::ReadAllText($published))
    if (Test-MarkerReady $mixed) { throw 'Mixed-scope data without readiness became observable.' }
    Write-NewText ($mixed+'.ready') ''
    Assert-Rejected { Read-Marker $mixed } 'scope, name or value differs'
    $stale=Join-Path $testRoot 'stale.json'
    Write-NewText $stale ([IO.File]::ReadAllText($published))
    Write-NewText ($stale+'.ready') ''
    Assert-Rejected { Read-Marker $stale } 'scope, name or value differs'
    $barrier=Join-Path $testRoot 'barrier.json'
    Write-NewText $barrier '{"schema":"dark180-phase-b-marker-v2"}'
    Write-Marker (Join-Path $testRoot 'actor-cancel.json') ([ordered]@{reason='probe'})
    if (Wait-ActorBarrier $barrier 0) { throw 'Unpublished barrier displaced a published cancellation.' }
    if (-not (Wait-ActorBarrier $published 0)) { throw 'Published barrier was ignored.' }
} finally {
    foreach ($root in @($testRoot,$otherRoot)) {
        foreach ($file in @([IO.Directory]::EnumerateFiles($root))) { [IO.File]::Delete($file) }
        [IO.Directory]::Delete($root)
    }
}

function New-OwnedProtocolChild([string]$Command) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $start.UseShellExecute=$false
    $start.RedirectStandardInput=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-Command',$Command)) {
        $start.ArgumentList.Add($arg)
    }
    $process=[Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'Owned protocol child failed to start.' }
    return [ordered]@{process=$process;stdout_task=$process.StandardOutput.ReadToEndAsync();
        stderr_task=$process.StandardError.ReadToEndAsync();
        started_utc=[DateTime]::UtcNow.ToString('o');role='candidate';pid=$process.Id;
        kill_requested=$false}
}
$owned=$null;$pending=$null;$capturePending=$null
try {
    $command='$null=[Console]::ReadLine(); [Console]::Out.WriteLine("DR_PHASE_B_CHILD test"); [Console]::Error.WriteLine("stderr-test")'
    $owned=New-OwnedProtocolChild $command
    $observations=[Collections.Generic.List[object]]::new()
    $early=Observe-OwnedChildClosure $owned 0 $observations 'active-unknown'
    if ($early.closed -or $observations.Count -ne 1 -or $observations[0].closed) {
        throw 'Zero-wait observation falsely confirmed a live owned process.'
    }
    Assert-Rejected { Read-WorkerRecord $early 'candidate' 'B6L' } 'did not close'
    $owned.process.StandardInput.WriteLine('release')
    $owned.process.StandardInput.Flush()
    $terminal=Observe-OwnedChildClosure $owned 3000 $observations 'settle-confirmed'
    if (-not $terminal.closed -or $terminal.exit_code -ne 0 -or $terminal.capture_error -or
        $terminal.stdout.TrimEnd("`r","`n") -cne 'DR_PHASE_B_CHILD test' -or
        $terminal.stderr.TrimEnd("`r","`n") -cne 'stderr-test' -or
        $observations.Count -ne 2 -or $observations[0].closed -or
        -not $observations[1].closed -or $observations[0].pid -ne $observations[1].pid) {
        throw 'Final same-process closure did not preserve unknown history and exact drained output.'
    }
    $owned=$null # Complete-OwnedChild disposed the confirmed process.

    $pending=New-OwnedProtocolChild '$null=[Console]::ReadLine()'
    $pendingObservations=[Collections.Generic.List[object]]::new()
    $null=Observe-OwnedChildClosure $pending 0 $pendingObservations 'active-unknown'
    $stillPending=Observe-OwnedChildClosure $pending 50 $pendingObservations 'settle-unknown'
    if ($stillPending.closed -or $pendingObservations.Count -ne 2 -or
        $pendingObservations[0].closed -or $pendingObservations[1].closed) {
        throw 'A still-running owned child was falsely accepted after bounded wait.'
    }
    Assert-Rejected { Read-WorkerRecord $stillPending 'candidate' 'B6L' } 'did not close'
    $pending.kill_requested=$true
    $pending.process.Kill($true)
    $killed=Observe-OwnedChildClosure $pending 3000 $pendingObservations 'killed-confirmed'
    if (-not $killed.closed -or -not $killed.kill_requested -or $killed.exit_code -eq 0 -or
        $pendingObservations[0].closed -or $pendingObservations[1].closed) {
        throw 'Owned kill erased earlier unknown observations or appeared successful.'
    }
    $pending=$null

    $capturePending=New-OwnedProtocolChild 'exit 0'
    $neverOutput=[Threading.Tasks.TaskCompletionSource[string]]::new()
    $capturePending.stdout_task=$neverOutput.Task
    $capturePending.stderr_task=$neverOutput.Task
    $bounded=[Diagnostics.Stopwatch]::StartNew()
    $incomplete=Complete-OwnedChild $capturePending 1000
    if (-not $incomplete.closed -or [string]::IsNullOrEmpty($incomplete.capture_error) -or
        $bounded.ElapsedMilliseconds -gt 1800) {
        throw 'Incomplete redirected output was not bounded and reported as incomplete.'
    }
    Assert-Rejected { Read-WorkerRecord $incomplete 'candidate' 'B6L' } 'complete raw capture'
    $capturePending=$null
} finally {
    foreach ($child in @($owned,$pending,$capturePending)) {
        if ($null -ne $child) {
            try {
                if (-not $child.process.HasExited) { $child.process.Kill($true) }
                [void]$child.process.WaitForExit(3000)
                $child.process.Dispose()
            } catch { }
        }
    }
}
Write-Host 'Phase B exact-manifest protocol tests passed.'
