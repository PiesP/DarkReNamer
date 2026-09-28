[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/windows-vm-module-loader.ps1')
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind guest)) { . $definition }
$script:AcceptanceProcessJobCleanup = [Collections.Generic.List[object]]::new()
$script:AutomationControlInvocations = [Collections.Generic.List[object]]::new()

function Assert-Fails {
    param([scriptblock] $Action, [string] $Expected)
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure: $Expected"
}
function New-TestOwnedProcess {
    param([Threading.EventWaitHandle] $Release)
    $owner = [pscustomobject]@{ ActiveProcessCount = 0; close_calls = 0; release = $Release }
    $owner | Add-Member ScriptMethod WaitForEmpty { param($milliseconds); return $true }
    $owner | Add-Member ScriptMethod CloseJob {
        $this.close_calls++
        if ($null -ne $this.release) { [void]$this.release.Set() }
        return $true
    }
    $owner | Add-Member ScriptMethod WaitForCapture { param($milliseconds) }
    [pscustomobject]@{
        owner = $owner; process = [pscustomobject]@{ Id = 42 }; process_start_time_utc_ticks = '42'
        job_empty = $false; job_closed = $false; job_capture_complete = $false
        job_active_processes_at_primary_exit = 0; job_had_survivors = $false
        job_forced_termination = $false; job_active_processes_at_close = $null
        job_active_processes_at_stop = $null; job_active_process_ids_at_stop = @()
        job_total_processes_at_stop = $null; job_primary_process_active_at_stop = $null
        job_termination_exit_code = $null; job_cleanup_error = $null
        job_cleanup_recorded = $false; job_cleanup_record = $null
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Threading;
namespace InvocationFixture {
    public class Proxy {
        public string Failure;
        public void SetVariable(string name, object value) {
            if (Failure == "variable") throw new InvalidOperationException("variable failure");
        }
    }
    public class Runspace {
        public string Failure;
        public ApartmentState ApartmentState;
        public Proxy SessionStateProxy = new Proxy();
        public int Disposals;
        public void Open() { if (Failure == "open") throw new InvalidOperationException("open failure"); }
        public void Dispose() { Disposals++; }
    }
    public class Wait {
        public bool Signaled = true;
        public int WaitTotal;
        public int WaitCalls;
        public bool WaitOne(int milliseconds) {
            WaitCalls++;
            if (!Signaled) { WaitTotal += milliseconds; Thread.Sleep(milliseconds); }
            return Signaled;
        }
    }
    public class Async {
        public Wait AsyncWaitHandle = new Wait();
        public bool IsCompleted { get { return AsyncWaitHandle.Signaled; } }
    }
    public class Streams { public object[] Error = new object[0]; }
    public class Pipeline {
        public string Failure;
        public object Runspace;
        public bool HadErrors;
        public Streams Streams = new Streams();
        public Async Result = new Async();
        public int Ends, Disposals;
        public Pipeline AddScript(string text) {
            if (Failure == "script") throw new InvalidOperationException("script failure");
            return this;
        }
        public Async BeginInvoke() {
            if (Failure == "begin") throw new InvalidOperationException("begin failure");
            return Result;
        }
        public void EndInvoke(object result) {
            Ends++;
            if (Failure == "end") throw new InvalidOperationException("end failure");
        }
        public void Dispose() {
            Disposals++;
            if (Failure == "dispose") throw new InvalidOperationException("dispose failure");
        }
    }
}
'@

& {
    function New-AutomationControlRunspace { $script:fakeRunspace }
    function New-AutomationControlPipeline {
        if ($script:phase -ceq 'pipeline') { throw 'pipeline failure' }
        $script:fakePipeline
    }
    foreach ($script:phase in @('open', 'variable', 'pipeline', 'script', 'begin')) {
        $script:fakeRunspace = [InvocationFixture.Runspace]::new()
        $script:fakeRunspace.Failure = $script:phase
        $script:fakeRunspace.SessionStateProxy.Failure = $script:phase
        $script:fakePipeline = [InvocationFixture.Pipeline]::new()
        $script:fakePipeline.Failure = $script:phase
        Assert-Fails {
            Start-OwnedAutomationInvocation -Element 1 -Label 'startup' -OwnedProcess (New-TestOwnedProcess) -ScriptText 'unused'
        } "$script:phase failure"
        $expectedPipelineDisposals = if ($script:phase -cin @('script', 'begin')) { 1 } else { 0 }
        if ($script:fakeRunspace.Disposals -ne 1 -or
            $script:fakePipeline.Disposals -ne $expectedPipelineDisposals -or
            (Get-AutomationInvocationLedger).Count -ne 0) {
            throw "Partial $script:phase initialization leaked an owned resource."
        }
    }
    $script:phase = 'none'
    $states = @()
    $ownerA = New-TestOwnedProcess
    $ownerB = New-TestOwnedProcess
    foreach ($owner in @($ownerA, $ownerA, $ownerB)) {
        $script:fakeRunspace = [InvocationFixture.Runspace]::new()
        $script:fakePipeline = [InvocationFixture.Pipeline]::new()
        $script:fakePipeline.Result.AsyncWaitHandle.Signaled = $false
        $states += Start-OwnedAutomationInvocation -Element 1 -Label "pending-$($states.Count)" -OwnedProcess $owner -ScriptText 'unused'
    }
    Assert-Fails { Complete-AutomationControlInvoke -State $states[0] -TimeoutSeconds 0 } 'bounded deadline'
    $beforeClose = @(Complete-OwnedAutomationControlInvocations -Owned $ownerA -TimeoutMilliseconds 0)
    if ($beforeClose.Count -ne 2 -or $states[0].powershell.Disposals -ne 0 -or $states[0].runspace.Disposals -ne 0) {
        throw 'Timed-out UIA calls must stay owned and undisposed while their candidate is alive.'
    }
    $ownerA.job_empty = $true
    $ownerA.job_closed = $true
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    $pendingErrors = @(Complete-OwnedAutomationControlInvocations -Owned $ownerA -TimeoutMilliseconds 30)
    if ($pendingErrors.Count -ne 2 -or
        $states[0].async_result.AsyncWaitHandle.WaitTotal + $states[1].async_result.AsyncWaitHandle.WaitTotal -gt 30 -or
        $elapsed.ElapsedMilliseconds -gt 500 -or
        $states[2].async_result.AsyncWaitHandle.WaitCalls -ne 0 -or (Get-AutomationInvocationLedger).Count -ne 3) {
        throw 'UIA draining must use one aggregate deadline and only the exact candidate owner.'
    }
    $states[0].powershell.Failure = 'end'
    $states[1].powershell.Failure = 'dispose'
    foreach ($state in $states[0..1]) { $state.async_result.AsyncWaitHandle.Signaled = $true }
    $errors = @(Complete-OwnedAutomationControlInvocations -Owned $ownerA -TimeoutMilliseconds 0)
    if (($errors -join ';') -notlike '*end failure*dispose failure*' -or
        $states[0].runspace.Disposals -ne 1 -or $states[1].runspace.Disposals -ne 1 -or
        (Get-AutomationInvocationLedger).Count -ne 2) {
        throw 'One invocation failure suppressed another resource or lost retained ownership.'
    }
    $record = Complete-AcceptanceOwnedProcessJob -Owned $ownerA
    $repeated = Complete-AcceptanceOwnedProcessJob -Owned $ownerA
    if ($record.status -cne 'failed' -or $record.error -notlike '*dispose failure*' -or
        -not [object]::ReferenceEquals($record, $repeated) -or
        $states[0].powershell.Ends -ne 1 -or $states[1].powershell.Ends -ne 1 -or
        $states[0].powershell.Disposals -ne 1 -or $states[1].powershell.Disposals -ne 1) {
        throw 'UIA cleanup failure must remain in the cached job receipt without repeated disposal.'
    }
    $states[2].async_result.AsyncWaitHandle.Signaled = $true
    Complete-AutomationControlInvoke -State $states[2] -TimeoutSeconds 0
    Complete-AutomationControlInvoke -State $states[2] -TimeoutSeconds 0
    if ($states[2].powershell.Ends -ne 1 -or $states[2].powershell.Disposals -ne 1) {
        throw 'Completed UIA calls were ended or disposed twice.'
    }
    # The remaining retained state deliberately uses fake resources whose Dispose always throws.
    $script:AutomationControlInvocations.Clear()
}

$release = [Threading.ManualResetEvent]::new($false)
$started = [Threading.ManualResetEvent]::new($false)
try {
    $owned = New-TestOwnedProcess -Release $release
    $state = Start-OwnedAutomationInvocation -Element ([pscustomobject]@{ started = $started; release = $release }) `
        -Label 'blocked native-provider analogue' -OwnedProcess $owned -ScriptText @'
[void]$automationElement.started.Set()
[void]$automationElement.release.WaitOne()
'@
    if (-not $started.WaitOne(5000)) { throw 'Real runspace did not reach the blocked invocation.' }
    Assert-Fails { Complete-AutomationControlInvoke -State $state -TimeoutSeconds 0 } 'bounded deadline'
    if ($state.powershell_dispose_attempted -or $state.runspace_dispose_attempted) {
        throw 'The blocked provider analogue was disposed before candidate termination.'
    }
    $record = Complete-AcceptanceOwnedProcessJob -Owned $owned
    if ($record.status -cne 'clean' -or $owned.owner.close_calls -ne 1 -or
        -not $state.completed -or (Get-AutomationInvocationLedger).Count -ne 0) {
        throw 'Job closure must release the provider before runspace cleanup.'
    }
}
finally {
    [void]$release.Set()
    if ($null -ne $state -and -not $state.completed) {
        Complete-AutomationControlInvoke -State $state -TimeoutSeconds 5
    }
    $release.Dispose()
    $started.Dispose()
}

$moduleRoot = Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell'
foreach ($file in Get-ChildItem -LiteralPath $moduleRoot -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw $errors[0] }
    foreach ($command in $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Start-AutomationControlInvoke'
    }, $true)) {
        if (@($command.CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'OwnedProcess'
        }).Count -ne 1) { throw "UIA call has no explicit process owner: $($file.Name)" }
    }
}
Write-Host 'Automation invocation lifecycle contracts passed.'
