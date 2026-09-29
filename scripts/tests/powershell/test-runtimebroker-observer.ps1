[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$observerPath = Join-Path $repository 'scripts/modules/powershell/runtimebroker-observer.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($observerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Observer has PowerShell syntax errors.' }
. $observerPath
function Assert-ObserverTest($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# Compile the actual embedded interop without calling Windows APIs or starting watchers.
$code = $ast.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('using System;') }, $true).Value
if ($PSVersionTable.PSEdition -eq 'Core') {
    $references = @(Get-ChildItem "$PSHOME/ref/*.dll" | ForEach-Object FullName) + "$PSHOME/System.Management.dll"
    Add-Type -TypeDefinition $code -ReferencedAssemblies $references
} else { Add-Type -TypeDefinition $code -ReferencedAssemblies System.dll,System.Core.dll,System.Management.dll }
Assert-ObserverTest ([DrRuntimeBrokerNative]::ProcessAccess -eq 0x00101000) 'Process access changed.'
Assert-ObserverTest ([DrRuntimeBrokerNative]::TokenAccess -eq 8) 'Token access changed.'
Assert-ObserverTest ([DrRuntimeBrokerNative]::MatchesCapturedLifetime(50,50,'134351000000000003','134351000000000009')) 'Valid event/native lifetime association failed.'
Assert-ObserverTest (-not [DrRuntimeBrokerNative]::MatchesCapturedLifetime(50,50,'134351000000000003','134351000000000002')) 'Old event attached to reused PID.'
Assert-ObserverTest (-not [DrRuntimeBrokerNative]::MatchesCapturedLifetime(50,51,'134351000000000003',$null)) 'Wrong native PID attached.'
Assert-ObserverTest (-not [DrRuntimeBrokerNative]::MatchesCapturedLifetime(50,50,$null,$null)) 'Unknown native creation attached.'
Assert-ObserverTest ([DrRuntimeBrokerNative]::ExistingAtSubscriptionStart('134351000000000001','134351000000000002')) 'Pre-subscription lifetime was misclassified.'
Assert-ObserverTest (-not [DrRuntimeBrokerNative]::ExistingAtSubscriptionStart('134351000000000003','134351000000000002')) 'Subscription/snapshot gap lifetime was labelled pre-observation.'
Assert-ObserverTest ($null -eq [DrRuntimeBrokerNative]::ExistingAtSubscriptionStart('134351000000000001',$null)) 'Unknown start boundary became existing-at-start.'
Assert-ObserverTest ([DrRuntimeBrokerNative]::MatchesSnapshotLifetime(50,50,'134351000000000000','134351000000000009',2,2)) 'Same snapshot/native lifetime failed microsecond corroboration.'
Assert-ObserverTest (-not [DrRuntimeBrokerNative]::MatchesSnapshotLifetime(50,50,'134351000000000000','134351000000000010',2,2)) 'Reused snapshot PID attached to a later native lifetime.'
Assert-ObserverTest (-not [DrRuntimeBrokerNative]::MatchesSnapshotLifetime(50,50,'134351000000000000','134351000000000001',2,3)) 'Snapshot session mismatch attached.'
Assert-ObserverTest (-not [DrRuntimeBrokerNative]::MatchesSnapshotLifetime(50,50,$null,'134351000000000001',2,2)) 'Missing snapshot creation became a lifetime match.'
Assert-ObserverTest ([DrRuntimeBrokerNative]::IsRuntimeBrokerImage('C:\Windows\System32\RuntimeBroker.exe')) 'Native target image leaf failed.'
Assert-ObserverTest (-not [DrRuntimeBrokerNative]::IsRuntimeBrokerImage('C:\Windows\System32\cmd.exe')) 'Unrelated native process image was enriched.'


# Exercise the actual common target/parent reservation counter, with no process opens.
$session = [DrRuntimeBrokerSession]::new('S-1-5-21-1')
$binding = [Reflection.BindingFlags]'Instance,NonPublic'
$reserve = $session.GetType().GetMethod('Reserve', $binding)
$release = $session.GetType().GetMethod('Release', $binding)
for ($index = 0; $index -lt 64; $index++) { Assert-ObserverTest ($reserve.Invoke($session, @())) 'A permitted slot failed.' }
Assert-ObserverTest (-not $reserve.Invoke($session, @())) '65th native slot was permitted.'
for ($index = 0; $index -lt 64; $index++) { [void]$release.Invoke($session, @($null)) }
Assert-ObserverTest ($session.Close().owned_handles_remaining -eq 0) 'Reserved native slots were not released.'

function New-FakeLease([uint32]$ProcessId, [string]$Creation, [uint32]$Wait = 0, [bool]$PollFailure = $false) {
    $life = [pscustomobject]@{ Identity = @{ pid = $ProcessId; creation_filetime_100ns = $Creation; token_close_error = 0;
        package_first_status = 15700; package_status = $null; package_full_name = $null; aumid_first_status = 15703; aumid_status = $null; aumid = $null };
        CloseError = 0; Closed = $false; Wait = $Wait; PollFailure = $PollFailure; PollCount = 0 }
    $life | Add-Member ScriptMethod Poll {
        $this.PollCount++
        if ($this.PollFailure) { throw 'Fake poll failed.' }
        return @{ wait_result = $this.Wait; times_succeeded = $this.Wait -eq 0; exit_code_succeeded = $this.Wait -eq 0;
            pid = $this.Identity.pid; creation_filetime_100ns = $this.Identity.creation_filetime_100ns;
            exit_filetime_100ns = if ($this.Wait -eq 0) { '134351000000000100' } else { $null }; exit_code = 1 }
    }
    $lease = [pscustomobject]@{ Life = $life; Closed = $false; CloseCount = 0 }
    $lease | Add-Member ScriptMethod Close { if (-not $this.Closed) { $this.CloseCount++; $this.Closed = $true; $this.Life.Closed = $true } }
    return $lease
}
function New-FakeRecord($Lease, [string]$Scope = 'runner', [string]$Kind = 'capture') {
    [pscustomobject]@{ Kind = $Kind; Source = 'initial-snapshot'; Pid = $Lease.Life.Identity.pid; EventTime = $null;
        ReceivedUtc = '2026-09-30T00:00:00.0000000Z'; OwnerScope = $Scope; ErrorType = $null; ErrorHResult = 0; Lease = $Lease; TraceAuxiliary = @{ parent_process_id=55; event_sid='S-1-5-21-1'; event_sid_base64='AA=='; sid_status='observed'; exit_status=1; field_errors=@() }; NativeCaptureStartedUtc='2026-09-30T00:00:00.0000000Z'; NativeIdentityCompletedUtc='2026-09-30T00:00:00.0000001Z'; SubscriptionStartFileTime='134351000000000000'; ExistingAtStart=$false; OriginClassification='born-since-subscription-start' }
}
function New-FakeBackend([string]$Root, [object[]]$Records = @(), [bool]$SnapshotFailure = $false, [bool]$WrongStop = $false) {
    $context = @{ Root = $Root; Rows = $Records; Calls = [Collections.Generic.List[string]]::new(); CloseCount = 0; CompilerCleanup = @{ completed=$true; owned_temp_artifacts_remaining=0; errors=@(); compilation_succeeded=$true };
        EnrichCount = 0; SnapshotFailure = $SnapshotFailure; WrongStop = $WrongStop; ProviderFailures = 0; ProviderFailOnSnapshot=$false; ProviderFailOnEnrich=$false; ProviderFailOnDelay=$false }
    $backend = @{
        Context = $context
        Start = { $context.Calls.Add('subscriptions-started') }.GetNewClosure()
        Ready = { $context.ProviderFailures -eq 0 }.GetNewClosure()
        Snapshot = { $context.Calls.Add('snapshot'); if ($context.ProviderFailOnSnapshot) { $context.ProviderFailures=1 }; if ($context.SnapshotFailure) { throw 'Snapshot failed.' }; @(50) }.GetNewClosure()
        Capture = { param($ProcessId) $context.Calls.Add('capture') }.GetNewClosure()
        Drain = { $records = $context.Rows; $context.Rows = @(); return $records }.GetNewClosure()
        Enrich = { param($Record,$Backend) $context.EnrichCount++; if ($context.ProviderFailOnEnrich) { $context.ProviderFailures=1 }; @{ command_line_sha256 = 'redacted-fake'; marker = 'preserved' } }.GetNewClosure()
        Delay = {
            if ($context.ProviderFailOnDelay) { $context.ProviderFailures=1 }
            Assert-ObserverTest (Test-Path (Join-Path $context.Root 'ready.json')) 'Delay preceded readiness.'
            $id = if ($context.WrongStop) { 'ffffffffffffffffffffffffffffffff' } else { '11111111111111111111111111111111' }
            [IO.File]::WriteAllText((Join-Path $context.Root 'stop-request.json'), (@{ schema_version = 1; run_id = $id } | ConvertTo-Json -Compress))
        }.GetNewClosure()
        Close = {
            $context.CloseCount++; $context.Calls.Add('close')
            foreach ($record in $Records) { if ($record.Lease) { $record.Lease.Close() } }
            return @{ subscriptions_closed = $true; owned_handles_remaining = 0; errors = @(); dropped_records = 0;
                handle_cap_misses = 0; capture_failures = 0; provider_failures = $context.ProviderFailures; native_close_failures = 0 }
        }.GetNewClosure()
    }
    return $backend
}
function Invoke-FakeRun($Backend, [int]$Limit = 14MB, [int]$Reserve = 256KB) {
    Invoke-DrRuntimeBrokerObserverCore -Root $Backend.Context.Root -RunId '11111111111111111111111111111111' -RunnerSid 'S-1-5-21-1' -ExpectedVmId '00000000-0000-0000-0000-000000000001' -DurationSeconds 5 -Backend $Backend -MetadataLimit $Limit -TerminalReserve $Reserve -CompilerCleanup $Backend.Context.CompilerCleanup
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('runtimebroker-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function New-TestRoot([string]$Name) { $root = Join-Path $testRoot $Name; [void][IO.Directory]::CreateDirectory($root); return $root }
try {
    $one = New-FakeLease 50 '134351000000000001'; $duplicate = New-FakeLease 50 '134351000000000001'; $reused = New-FakeLease 50 '134351000000000002'
    $backend = New-FakeBackend (New-TestRoot 'lifetime') @((New-FakeRecord $one),(New-FakeRecord $duplicate),(New-FakeRecord $reused))
    $result = Invoke-FakeRun $backend
    Assert-ObserverTest ($result.status -ceq 'diagnostic-completed' -and $result.stop_reason -ceq 'matching-stop-request') 'Normal stop failed.'
    Assert-ObserverTest (($backend.Context.Calls[0..1] -join ',') -ceq 'subscriptions-started,snapshot') 'Snapshot preceded subscriptions.'
    Assert-ObserverTest ($backend.Context.EnrichCount -eq 2 -and $backend.Context.CloseCount -eq 1) 'Deduplication or cleanup failed.'
    foreach ($lease in @($one,$duplicate,$reused)) { Assert-ObserverTest ($lease.CloseCount -eq 1) 'A held lifetime was not closed exactly once.' }
    $ready = Get-Content (Join-Path $backend.Context.Root 'ready.json') -Raw | ConvertFrom-Json
    Assert-ObserverTest ($ready.runner_sid -ceq 'S-1-5-21-1' -and $ready.expected_vm_id -ceq '00000000-0000-0000-0000-000000000001' -and $ready.initial_snapshot_complete) 'Ready identity binding lost.'
    $rows = @(Get-Content (Join-Path $backend.Context.Root 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-ObserverTest (@($rows | Where-Object kind -eq 'same-handle-exit-or-final').Count -eq 2) 'PID reuse collapsed distinct lifetimes.'
    Assert-ObserverTest ($rows[0].native_identity.package_first_status -eq 15700 -and $rows[0].native_identity.aumid_first_status -eq 15703) 'Raw no-identity API codes lost.'
    Assert-ObserverTest ($rows[0].identity_status -ceq 'no-package-identity') 'No-identity confused with capture failure.'
    Assert-ObserverTest ($rows[-1].native_exit.exit_code -eq 1) 'Observed nonzero exit code changed.'
    Assert-ObserverTest ($rows[0].trace_auxiliary.parent_process_id -eq 55 -and $rows[0].trace_auxiliary.exit_status -eq 1 -and -not $rows[0].existing_at_start) 'Auxiliary trace or actual start boundary data was lost.'
    Assert-ObserverTest ($result.compiler_cleanup.completed -and $result.compiler_cleanup.owned_temp_artifacts_remaining -eq 0 -and $result.output_staging.published_before_result -eq 1 -and $result.output_staging.remaining_before_result -eq 0) 'Compiler/staging resource receipt lost.'
    Assert-ObserverTest (@(Get-ChildItem $backend.Context.Root -Filter '*.tmp').Count -eq 0) 'Atomic publication leaked staging files.'

    $foreign = New-FakeLease 51 '134351000000000003'; $foreign.Close(); $unknown = New-FakeLease 52 '134351000000000004' 258
    $backend = New-FakeBackend (New-TestRoot 'scope') @((New-FakeRecord $foreign 'foreign'),(New-FakeRecord $unknown 'unknown'))
    $result = Invoke-FakeRun $backend
    Assert-ObserverTest ($backend.Context.EnrichCount -eq 0 -and $unknown.Closed) 'Foreign/unknown metadata was broadly enriched or leaked.'
    Assert-ObserverTest ($result.status -ceq 'diagnostic-incomplete') 'Unknown owner was treated as complete.'
    $rows = @(Get-Content (Join-Path $backend.Context.Root 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-ObserverTest (@($rows[0].native_identity.PSObject.Properties).Count -eq 2) 'Foreign exclusion exposed extra identity metadata.'

    $backend = New-FakeBackend (New-TestRoot 'not-ready') @() $true
    $result = Invoke-FakeRun $backend
    Assert-ObserverTest (-not $result.ready_written -and $backend.Context.CloseCount -eq 1 -and -not (Test-Path (Join-Path $backend.Context.Root 'ready.json'))) 'Failed snapshot published readiness or skipped cleanup.'
    $broken = New-FakeLease 53 '134351000000000005' 258 $true
    $backend = New-FakeBackend (New-TestRoot 'poll-failure') @((New-FakeRecord $broken))
    $result = Invoke-FakeRun $backend
    Assert-ObserverTest ($broken.Closed -and $backend.Context.CloseCount -eq 1 -and $result.status -ceq 'diagnostic-incomplete') 'Poll failure leaked a handle or hid incomplete evidence.'

    $backend = New-FakeBackend (New-TestRoot 'wrong-stop') @() $false $true
    $result = Invoke-FakeRun $backend
    Assert-ObserverTest ($result.status -ceq 'diagnostic-incomplete' -and $backend.Context.CloseCount -eq 1) 'Foreign stop request was accepted.'
    $backend = New-FakeBackend (New-TestRoot 'provider-failure')
    $backend.Context.ProviderFailOnDelay = $true
    $result = Invoke-FakeRun $backend
    Assert-ObserverTest ($result.ready_written -and $result.issues -contains 'coverage-or-close-loss:provider_failures') 'Provider loss was silently treated as lossless.'

    $backend = New-FakeBackend (New-TestRoot 'phase')
    $phaseRoot = Join-Path $backend.Context.Root 'phases'; [void][IO.Directory]::CreateDirectory($phaseRoot)
    $phase = @{ schema_version = 1; run_id = '11111111111111111111111111111111'; phase = 'high-contrast'; state = 'observed';
        recorded_at_utc = '2026-09-30T00:00:00.0000000Z'; source = 'ui-observer'; details = @{ product_source_sha = 'opaque'; diagnostic_source_sha = 'opaque' } }
    [IO.File]::WriteAllText((Join-Path $phaseRoot ('2' * 32 + '.json')), ($phase | ConvertTo-Json -Compress))
    $result = Invoke-FakeRun $backend
    Assert-ObserverTest ($result.status -ceq 'diagnostic-completed' -and $result.phase_input_bytes -gt 0) 'Bounded phase was not accepted.'
    $phaseRow = ConvertFrom-DrRuntimeBrokerJson ([IO.File]::ReadAllBytes((Join-Path $backend.Context.Root 'events.jsonl')))
    Assert-ObserverTest ($phaseRow.clock_domain -ceq 'ui-observer' -and $phaseRow.record.recorded_at_utc -ceq $phase.recorded_at_utc) 'Guest marker clock domain changed.'

    $backend = New-FakeBackend (New-TestRoot 'budget') @((New-FakeRecord (New-FakeLease 54 '134351000000000006' 258)))
    $result = Invoke-FakeRun $backend 2048 1500
    Assert-ObserverTest ($result.status -ceq 'diagnostic-incomplete' -and $backend.Context.CloseCount -eq 1) 'Output cap failed open or skipped final cleanup.'
    $actualBytes = (Get-ChildItem $backend.Context.Root -File | Where-Object Name -in @('ready.json','events.jsonl','result.json') | Measure-Object Length -Sum).Sum
    Assert-ObserverTest ($actualBytes -le 2048) 'Collector output exceeded its aggregate cap.'

    $backend = New-FakeBackend (New-TestRoot 'deadline')
    $result = Invoke-DrRuntimeBrokerObserverCore -Root $backend.Context.Root -RunId ('1' * 32) -RunnerSid 'S-1-5-21-1' -DurationSeconds 0 -Backend $backend
    Assert-ObserverTest (-not $result.ready_written -and $backend.Context.CloseCount -eq 1) 'Consumed deadline published ready.'
    $backend = New-FakeBackend (New-TestRoot 'phase-cap')
    $phaseRoot = Join-Path $backend.Context.Root 'phases'; [void][IO.Directory]::CreateDirectory($phaseRoot)
    [IO.File]::WriteAllText((Join-Path $phaseRoot ('2' * 32 + '.json')), (' ' * 4097))
    $result = Invoke-FakeRun $backend
    Assert-ObserverTest ($result.status -ceq 'diagnostic-incomplete' -and $result.phase_input_bytes -eq 0 -and $backend.Context.CloseCount -eq 1) 'Oversized phase bypassed its separate budget.'

    # Exercise the production enrichment function with CIM and image evidence substituted.
    # No process lookup, signature lookup, watcher or native open occurs in these cases.
    $savedEnrichmentImage = ${function:Get-DrRuntimeBrokerImageEvidence}
    $savedWindir = $env:windir
    $env:windir = '/mockWindows'
    function Get-DrRuntimeBrokerImageEvidence { param($Path,$ExpectedLeaf) @{ status = 'mock-image'; image_path = $Path; leaf = $ExpectedLeaf } }
    function Get-CimInstance { param($ClassName,$Filter,$OperationTimeoutSec,$ErrorAction) if ($script:cimFailure -ceq $Filter) { throw 'Mocked CIM failure.' }; return $script:cimRows[$Filter] }
    $script:cimFailure = ''
    try {
        $child = New-FakeLease 50 '134351000000000003' 258
        $child.Life.Identity.session_id = 2; $child.Life.Identity.image_path = '/mockWindows/System32/RuntimeBroker.exe'
        $parent = New-FakeLease 55 '134350999999000003' 258
        $parent.Life.Identity.open_error = 0; $parent.Life.Identity.session_id = 0; $parent.Life.Identity.owner_sid = 'S-1-5-18'; $parent.Life.Identity.image_path = '/mockWindows/System32/svchost.exe'
        $fakeSession = [pscustomobject]@{ Parent = $parent; Calls = 0 }
        $fakeSession | Add-Member ScriptMethod OpenParent { param($ProcessId) $this.Calls++; return $this.Parent }
        $script:cimRows = @{
            'ProcessId=50' = [pscustomobject]@{ CreationDate = [DateTime]::FromFileTimeUtc(134351000000000000); SessionId = 2; ParentProcessId = 55; CommandLine = '/mockWindows/System32/RuntimeBroker.exe -Embedding' }
            'ProcessId=55' = [pscustomobject]@{ CreationDate = [DateTime]::FromFileTimeUtc(134350999999000000); SessionId = 0; Name = 'svchost.exe' }
        }
        $row = Get-DrRuntimeBrokerEnrichment (New-FakeRecord $child) @{ Session = $fakeSession }
        Assert-ObserverTest ($row.native_minus_cim_ticks -ceq '3' -and $row.parent.cim.value.native_minus_cim_ticks -ceq '3') 'Native 100ns precision was lost.'
        Assert-ObserverTest ($row.parent.association_status -ceq 'creation-order-corroborated-not-causality' -and $row.parent.native_identity.owner_sid -ceq 'S-1-5-18' -and $row.parent.handle_closed -and $parent.CloseCount -eq 1) 'Parent evidence or guaranteed close failed.'
        Assert-ObserverTest ($row.command_line -ceq '/mockWindows/System32/RuntimeBroker.exe -Embedding') 'First captured command was lost.'
        $parent = New-FakeLease 55 '134351000000000010' 258
        $parent.Life.Identity.open_error = 0; $fakeSession.Parent = $parent
        $script:cimRows['ProcessId=50'].CommandLine = 'unexpected private command'
        $row = Get-DrRuntimeBrokerEnrichment (New-FakeRecord $child) @{ Session = $fakeSession }
        Assert-ObserverTest ($row.parent.association_status -ceq 'invalid-parent-newer-than-child' -and $parent.Closed) 'Reused parent PID was associated or leaked.'
        Assert-ObserverTest ($row.command_line -ceq 'unexpected private command' -and $row.command_line_length -eq 26) 'Bounded noncanonical runner command was lost.'
        $parent = New-FakeLease 55 '134350999999000003' 258
        $parent.Life.Identity.open_error=0; $parent.Life.Identity.session_id=0; $fakeSession.Parent=$parent
        $script:cimFailure='ProcessId=55'
        $row=Get-DrRuntimeBrokerEnrichment (New-FakeRecord $child) @{ Session=$fakeSession }
        Assert-ObserverTest ($row.command_line -ceq 'unexpected private command' -and $row.parent_pid -eq 55 -and $row.image_evidence.status -ceq 'mock-image') 'Parent CIM failure discarded target fields.'
        Assert-ObserverTest (-not $row.parent.cim.succeeded -and $null -ne $row.parent.cim.error_hresult -and $row.parent.cim.started_guest_utc -and $row.parent.cim.completed_guest_utc -and $parent.Closed) 'Independent parent query failure or close was lost.'
        $script:cimFailure=''
        $script:cimRows['ProcessId=50'].CommandLine=$null
        $row=Get-DrRuntimeBrokerEnrichment (New-FakeRecord $child) @{ Session=$fakeSession }
        Assert-ObserverTest ($row.command_line_present -and $row.command_line_status -ceq 'null' -and $null -eq $row.command_line) 'Null command was converted to empty.'
        $script:cimRows['ProcessId=50'].PSObject.Properties.Remove('CommandLine')
        $row=Get-DrRuntimeBrokerEnrichment (New-FakeRecord $child) @{ Session=$fakeSession }
        Assert-ObserverTest (-not $row.command_line_present -and $row.command_line_status -ceq 'absent') 'Missing command was conflated with null.'
        $script:cimRows['ProcessId=50'] | Add-Member NoteProperty CommandLine ''
        $row=Get-DrRuntimeBrokerEnrichment (New-FakeRecord $child) @{ Session=$fakeSession }
        Assert-ObserverTest ($row.command_line_status -ceq 'observed' -and $row.command_line -ceq '' -and $row.command_line_length -eq 0) 'Empty command was converted to null.'
        $child.Life.Identity.creation_filetime_100ns = '134351000000000010'
        $calls = $fakeSession.Calls
        $row = Get-DrRuntimeBrokerEnrichment (New-FakeRecord $child) @{ Session = $fakeSession }
        Assert-ObserverTest ($row.status -ceq 'CIM-native-lifetime-mismatch' -and $fakeSession.Calls -eq $calls -and $null -eq $row.target_cim.value.command_line -and $null -eq $row.target_cim.value.parent_pid) 'Mismatched child lifetime obtained unrelated command or parent evidence.'
    } finally { $env:windir = $savedWindir; Set-Item Function:Get-DrRuntimeBrokerImageEvidence $savedEnrichmentImage; Remove-Item Function:Get-CimInstance }

    $savedReader=${function:Read-DrRuntimeBrokerJsonBytes}; $savedWindir=$env:windir; $env:windir='/mockWindows'
    function Read-DrRuntimeBrokerJsonBytes { param($Path,$Limit) return ,([byte[]]@(1,2,3)) }
    function Get-AuthenticodeSignature { param($LiteralPath,$ErrorAction) throw 'Mocked signature failure.' }
    try {
        $image=Get-DrRuntimeBrokerImageEvidence '/mockWindows/System32/RuntimeBroker.exe' 'RuntimeBroker.exe'
        Assert-ObserverTest ($image.content.succeeded -and $image.content.value.bytes -eq 3 -and $image.content.value.sha256.Length -eq 64) 'Signature failure discarded captured file hash.'
        Assert-ObserverTest (-not $image.signature.succeeded -and $image.signature.error_type -and $null -ne $image.signature.error_hresult -and $image.signature.started_guest_utc -and $image.signature.completed_guest_utc) 'Signature error metadata or timing was lost.'
    } finally { Set-Item Function:Read-DrRuntimeBrokerJsonBytes $savedReader; Remove-Item Function:Get-AuthenticodeSignature; $env:windir=$savedWindir }
    $backend=New-FakeBackend (New-TestRoot 'publication-collision')
    [IO.File]::WriteAllText((Join-Path $backend.Context.Root 'ready.json'),'existing evidence')
    $result=Invoke-FakeRun $backend
    Assert-ObserverTest (-not $result.ready_written -and [IO.File]::ReadAllText((Join-Path $backend.Context.Root 'ready.json')) -ceq 'existing evidence') 'Atomic publication overwrote a ready record.'
    Assert-ObserverTest ($result.output_staging.discarded_before_result -eq 1 -and $result.output_staging.remaining_before_result -eq 0 -and @(Get-ChildItem $backend.Context.Root -Filter '*.tmp').Count -eq 0) 'Publication failure leaked its owned stage.'

    $compilerRoot=New-TestRoot 'compiler-temp'; $artifact=Join-Path $compilerRoot 'known.tmp'; $outside=Join-Path $testRoot 'unrelated.tmp'
    [IO.File]::WriteAllText($artifact,'owned compiler bytes'); [IO.File]::WriteAllText($outside,'unrelated retained bytes')
    $receipt=Remove-DrRuntimeBrokerCompilerArtifacts @($artifact) $compilerRoot
    Assert-ObserverTest ($receipt.completed -and $receipt.owned_temp_artifacts_remaining -eq 0 -and -not (Test-Path $artifact)) 'Known owned compiler artifact was not removed/read back.'
    $receipt=Remove-DrRuntimeBrokerCompilerArtifacts @($outside) $compilerRoot
    Assert-ObserverTest (-not $receipt.completed -and -not $receipt.all_paths_inside_owned_root -and [IO.File]::ReadAllText($outside) -ceq 'unrelated retained bytes') 'Compiler cleanup removed an unowned path.'
    $directory=Join-Path $compilerRoot 'ordinary-directory'; [void][IO.Directory]::CreateDirectory($directory)
    $receipt=Remove-DrRuntimeBrokerCompilerArtifacts @($directory) $compilerRoot
    Assert-ObserverTest (-not $receipt.completed -and (Test-Path $directory)) 'Compiler cleanup recursively removed a directory.'

    foreach ($case in @('Snapshot','Enrich')) {
        $lease=New-FakeLease 56 '134351000000000007' 258
        $backend=New-FakeBackend (New-TestRoot ('provider-before-ready-' + $case)) @((New-FakeRecord $lease))
        $backend.Context['ProviderFailOn' + $case]=$true
        $result=Invoke-FakeRun $backend
        Assert-ObserverTest (-not $result.ready_written -and -not (Test-Path (Join-Path $backend.Context.Root 'ready.json')) -and $lease.Closed -and $backend.Context.CloseCount -eq 1) 'Known provider failure during initial work published READY or leaked a lifetime.'
    }
    'RuntimeBroker observer focused checks passed (fake backend; C# compilation only; no native invocation).'
} finally { [IO.Directory]::Delete($testRoot, $true) }
