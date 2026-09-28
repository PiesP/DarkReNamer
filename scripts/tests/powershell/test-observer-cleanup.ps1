[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/windows-vm-module-loader.ps1')
foreach ($kind in @('guest', 'recovery', 'controller')) {
    foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind $kind)) { . $definition }
}

function Assert-Fails {
    param([scriptblock] $Action, [string] $Expected)
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure: $Expected"
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-observer-cleanup-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $root
    $binaryPath = Join-Path $root 'fixture.exe'
    [IO.File]::WriteAllText($binaryPath, 'not an executable')
    $changedArtifact = [pscustomobject]@{ file = 'fixture.exe'; sha256 = '0' * 64 }
    foreach ($budget in @(0, 1024)) {
        $row = Invoke-RustTestBinary -Test $changedArtifact -Root $root -OutputRoot $root `
            -RuntimeRoot $root -Index $budget -TimeoutSeconds 1 -OutputBudgetBytes $budget
        $expectedReason = if ($budget -eq 0) { 'suite_output_limit_exceeded' } else { 'artifact_changed_after_preflight' }
        if ($row.status -cne 'failed' -or $row.failure_reason -cne $expectedReason -or
            -not $row.job_cleanup -or $row.stdout.bytes -ne 0 -or $row.stderr.bytes -ne 0 -or
            $row.stdout.sha256 -cne 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' -or
            $row.stderr.sha256 -cne $row.stdout.sha256) {
            throw 'A rejected test launch lost its final output or cleanup evidence.'
        }
    }
    $gui = Invoke-GuiSmoke -Application $changedArtifact -Root $root -OutputRoot $root `
        -RuntimeRoot $root -ExpectedSession 1 -TimeoutSeconds 1
    if ($gui.status -cne 'failed' -or $gui.failure_reason -cne 'artifact_changed_after_preflight' -or
        -not $gui.job_cleanup) {
        throw 'A rejected GUI launch lost its final cleanup evidence.'
    }
    $details = [ordered]@{ error_detail = $null }
    foreach ($message in @('original GUI failure', 'process cleanup failed', 'fixture retained')) {
        try { throw $message }
        catch { Set-GuiSmokeFailureDetail -Row $details -ErrorRecord $_ }
    }
    if ($details.error_detail.message -cne 'original GUI failure' -or
        ($details.additional_error_details.message -join ',') -cne 'process cleanup failed,fixture retained') {
        throw 'Cleanup diagnostics must preserve the original GUI error and each later failure.'
    }
    Assert-OrdinaryDirectoryTree -Path $root
    Assert-Fails { Assert-OrdinaryDirectoryTree -Path (Join-Path $root 'absent') } 'does not exist'

    foreach ($failure in @('query', 'terminate', 'wait', 'close', 'capture', 'none')) {
        $owner = [pscustomobject]@{
            failure = $failure
            closed = 0
            captured = 0
        }
        $owner | Add-Member ScriptProperty ActiveProcessCount {
            if ($this.failure -ceq 'query') { throw 'query failed' }
            if ($this.failure -ceq 'terminate') { return 1 }
            return 0
        }
        $owner | Add-Member ScriptMethod Terminate { param($code); throw 'terminate failed' }
        $owner | Add-Member ScriptMethod WaitForEmpty {
            param($milliseconds)
            if ($this.failure -ceq 'wait') { throw 'wait failed' }
            return $true
        }
        $owner | Add-Member ScriptMethod CloseJob {
            $this.closed++
            if ($this.failure -ceq 'close') { throw 'close failed' }
            return $true
        }
        $owner | Add-Member ScriptMethod WaitForCapture {
            param($milliseconds)
            $this.captured++
            if ($this.failure -ceq 'capture') { throw 'capture failed' }
        }
        $state = [pscustomobject]@{
            owner = $owner; job_active_processes_at_close = $null; job_had_survivors = $false
            job_forced_termination = $false; job_empty = $false; job_closed = $false
            job_capture_complete = $false; job_cleanup_error = $null
        }
        if ($failure -ceq 'none') {
            if (-not (Close-JobBoundProcess -State $state)) { throw 'Ordinary job cleanup failed.' }
        }
        else {
            $expected = if ($failure -ceq 'query') { 'active-process count could not be observed' } else { "$failure failed" }
            Assert-Fails { Close-JobBoundProcess -State $state } $expected
        }
        if ($owner.closed -ne 1 -or $owner.captured -ne 1 -or
            ($failure -cin @('query', 'terminate', 'wait') -and $state.job_empty)) {
            throw 'A cleanup failure skipped remaining resources or fabricated job emptiness.'
        }
    }

    $initial = foreach ($index in 1..3) {
        [pscustomobject]@{
            name = if ($index -eq 3) { 'sentinel.bin' } else { "$index.txt" }
            kind = 'file'; bytes = 1; content_sha256 = 'a' * 64
            file_identity = [pscustomobject]@{
                volume_serial = '1' * 16; file_id = $index.ToString('x32')
            }
        }
    }
    $renamed = $initial[1].PSObject.Copy()
    $renamed.name = 'new-' + $renamed.name
    $partial = @($initial[0], $renamed, $initial[2])
    $counts = Assert-AcceptancePartialState -Initial $initial -Partial $partial -Prefix 'new-' -ExpectedCount 2
    if ($counts.original -ne 1 -or $counts.renamed -ne 1) { throw 'A genuine partial state was rejected.' }
    $duplicate = $initial[0].PSObject.Copy()
    $duplicate.name = 'new-' + $duplicate.name
    Assert-Fails {
        Assert-AcceptancePartialState -Initial $initial -Partial @($initial[0], $duplicate, $initial[2]) `
            -Prefix 'new-' -ExpectedCount 2
    } 'duplicate NTFS identity'
    Assert-Fails {
        Assert-AcceptancePartialState -Initial $initial -Partial @($initial[0], $initial[2], $initial[2]) `
            -Prefix 'new-' -ExpectedCount 2
    } 'duplicate NTFS identity'
    $unknown = $initial[1].PSObject.Copy()
    $unknown.file_identity = [pscustomobject]@{ volume_serial = '1' * 16; file_id = 'f' * 32 }
    Assert-Fails {
        Assert-AcceptancePartialState -Initial $initial -Partial @($initial[0], $unknown, $initial[2]) `
            -Prefix 'new-' -ExpectedCount 2
    } 'unknown NTFS identity'

    & {
        function New-TestRecoveryApplication {
            param([int] $Sequence, [string] $Mode)
            $safe = [pscustomobject]@{ IsClosed = $false; IsInvalid = $false }
            $safe | Add-Member ScriptMethod DangerousGetHandle { [IntPtr]42 }
            $process = [pscustomobject]@{
                Id = 100 + $Sequence; SessionId = 2; StartTime = [DateTime]::UtcNow
                SafeHandle = $safe; HasExited = $Mode -in @('exited', 'recorded')
                ExitCode = if ($Mode -ceq 'exited') { 37 } else { 0 }; disposed = 0
                mode = $Mode; refresh_calls = 0
            }
            $process | Add-Member ScriptMethod Refresh {
                $this.refresh_calls++
                if ($this.mode -ceq 'race' -and $this.refresh_calls -eq 2) {
                    $this.HasExited = $true; $this.ExitCode = 37
                }
            }
            $process | Add-Member ScriptMethod WaitForExit { param($timeout); return $this.HasExited }
            $process | Add-Member ScriptMethod Dispose { $this.disposed++ }
            $binding = [pscustomobject]@{
                sequence = $Sequence; role = 'rename-worker'; pid = $process.Id; session_id = 2
                start_time_utc_ticks = $process.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
                executable_path = 'fixture.exe'; executable_sha256 = 'a' * 64
            }
            [pscustomobject]@{
                owned = [pscustomobject]@{ process = $process; mode = $Mode; receipt = $null; stop_calls = 0; close_calls = 0 }
                main_handle = [IntPtr]4096; session_id = 2
                raw_process_object = $process; raw_process_handle = [IntPtr]42
                raw_process_binding = $binding; raw_process_exit_recorded = $Mode -ceq 'recorded'
            }
        }
        function Complete-AcceptanceOwnedProcessJob {
            param($Owned, [switch] $StopActive, [switch] $RequireSolePrimary)
            if ($null -ne $Owned.receipt) { return $Owned.receipt }
            $Owned.close_calls++
            if ($StopActive) {
                $Owned.stop_calls++
                if (-not $RequireSolePrimary) { throw 'Failure cleanup omitted exact primary termination.' }
                $Owned.process.HasExited = $true
                $Owned.process.ExitCode = 12345
            }
            $failed = $Owned.mode -in @('survivors', 'close-failure')
            $exact = $StopActive -and -not $failed
            $Owned.receipt = [pscustomobject]@{
                status = if ($failed) { 'failed' } else { 'clean' }
                job_empty = $true; job_closed = $Owned.mode -cne 'close-failure'
                forced_termination = [bool]$exact; active_processes_at_stop = if ($exact) { 1 } else { 0 }
                active_process_ids_at_stop = [int[]]@(if ($exact) { $Owned.process.Id })
                total_processes_at_stop = if ($exact) { 1 } else { 0 }
                primary_process_active_at_stop = [bool]$exact
                termination_exit_code = if ($exact) { 12345 } else { $null }
                had_survivors = $Owned.mode -ceq 'survivors'
            }
            $Owned.receipt
        }
        $private = Join-Path $root 'failure-processes'
        $null = New-Item -ItemType Directory -Path $private
        $sequence = 0
        foreach ($mode in @('live', 'exited', 'recorded', 'race', 'survivors', 'close-failure')) {
            $sequence++
            $application = New-TestRecoveryApplication -Sequence $sequence -Mode $mode
            $references = [Collections.Generic.List[object]]::new()
            if ($mode -in @('race', 'survivors', 'close-failure')) {
                Assert-Fails {
                    Complete-AcceptanceFailureProcessCleanup -Application $application -PrivateRoot $private -Processes $references
                } $(if ($mode -ceq 'race') { 'exited before' } else { 'Job Object' })
            }
            else {
                Complete-AcceptanceFailureProcessCleanup -Application $application -PrivateRoot $private -Processes $references
            }
            if ($application.owned.close_calls -ne 1 -or
                $application.owned.stop_calls -ne [int]($mode -notin @('exited', 'recorded', 'race'))) {
                throw 'Failure cleanup selected the wrong live/exited job dispatch.'
            }
            if ($mode -ceq 'recorded') {
                if ($references.Count -ne 0) { throw 'Failure cleanup duplicated recorded process exit.' }
                continue
            }
            $exit = Get-Content -LiteralPath (Join-Path $private ('process-{0:D2}-failure-cleanup.json' -f $sequence)) -Raw | ConvertFrom-Json
            $method = if ($mode -ceq 'live') { 'forced-termination' } else { 'observed-exit' }
            if ($references.Count -ne 1 -or $exit.lifecycle.exit_method -cne $method -or
                $exit.lifecycle.exit_code -ne $application.owned.process.ExitCode -or
                ($method -ceq 'observed-exit' -and $null -ne $exit.termination)) {
                throw 'Failure cleanup fabricated an exit method, code or termination receipt.'
            }
        }
        $application = New-TestRecoveryApplication -Sequence 20 -Mode exited
        Assert-Fails {
            Write-AcceptanceProcessExitEvidence -Application $application -PrivateRoot $private `
                -Boundary normal-exit -ExitMethod observed-exit
        } 'restricted to failure cleanup'

        $source = Get-DrTestCombinedPowerShellSource -Kind recovery
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @('Invoke-AcceptanceSession', 'Invoke-AcceptanceIntentOnlyCandidateDiscard')) {
            $function = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $true)
            $finally = @($function.Body.FindAll({ param($node)
                $node -is [Management.Automation.Language.TryStatementAst] -and
                    $null -ne $node.Finally -and $node.Finally.Extent.Text.Contains('Complete-AcceptanceFailureProcessCleanup')
            }, $true))[0].Finally.Extent.Text
            $cleanupBlock = [scriptblock]::Create($finally.Substring(1, $finally.Length - 2))
            $cancelApplication = New-TestRecoveryApplication -Sequence 30 -Mode survivors
            $relaunchApplication = New-TestRecoveryApplication -Sequence 31 -Mode live
            $discardApplication = $null
            $applications = @($cancelApplication, $relaunchApplication)
            $processes = [Collections.Generic.List[object]]::new()
            $PrivateRoot = $private
            $sessionError = $null; $scenarioError = $null
            Assert-Fails {
                try { throw 'original scenario failure' }
                catch { $sessionError = $_; $scenarioError = $_; throw }
                finally { . $cleanupBlock }
            } 'original scenario failure'
            if ($cancelApplication.owned.process.disposed -ne 1 -or
                $relaunchApplication.owned.process.disposed -ne 1 -or
                $relaunchApplication.owned.stop_calls -ne 1) {
                throw 'A scenario cleanup failure skipped another owned application or its disposal.'
            }
            Remove-Item -LiteralPath (Join-Path $private 'process-30-failure-cleanup.json'), (Join-Path $private 'process-31-failure-cleanup.json')
        }

        $application = New-TestRecoveryApplication -Sequence 40 -Mode live
        $pattern = [pscustomobject]@{ calls = 0 }
        $pattern | Add-Member ScriptMethod Invoke { $this.calls++ }
        $element = [pscustomobject]@{}
        $element | Add-Member ScriptProperty Current { throw 'No late UIA property lookup is allowed at the worker boundary.' }
        $binding = [pscustomobject]@{
            hwnd = [IntPtr]4097; main_handle = $application.main_handle
            pid = $application.raw_process_binding.pid; session_id = 2
            start_time_utc_ticks = $application.raw_process_binding.start_time_utc_ticks
            pattern = $pattern; element = $element
        }
        $native = [pscustomobject]@{
            live = $true; child = [IntPtr]4097; parent = [IntPtr]4096; root = [IntPtr]4096
            pid = $binding.pid; root_pid = $binding.pid; class = 'Button'; name = '취소'
            root_class = 'DarkReNamerWindow'; root_name = 'DarkReNamer'; control_id = 1009
            enabled = $true; visible = $true; main_enabled = $true; focused = $false
        }
        function Read-AcceptanceWorkerControlState { param($Binding); $native }
        function Find-UniqueAutomationElement { throw 'No late UIA discovery is allowed at the worker boundary.' }
        $fixture = Join-Path $root 'worker-boundary'
        $localData = Join-Path $root 'worker-local'
        $journal = Join-Path $localData 'DarkReNamer/journal'
        $null = New-Item -ItemType Directory -Path $fixture, $journal -Force
        $first = Join-Path $fixture 'new-item-00000.txt'
        $last = Join-Path $fixture 'item-00127.txt'
        $active = Join-Path $journal 'active.drj'
        foreach ($path in @($first, $last, $active)) { [IO.File]::WriteAllText($path, 'fixture') }
        function Get-FullFileIdentity { param($Path); [pscustomobject]@{ volume_serial = '1' * 16; file_id = '2' * 32 } }
        $initialFirst = [pscustomobject]@{
            name = 'item-00000.txt'; file_identity = Get-FullFileIdentity -Path $first; content_sha256 = Get-LowerSha256 -Path $first
        }
        $initialLast = [pscustomobject]@{
            name = 'item-00127.txt'; file_identity = Get-FullFileIdentity -Path $last; content_sha256 = Get-LowerSha256 -Path $last
        }
        $boundary = Get-AcceptanceActiveWorkerBoundary -Application $application -Cancel $binding `
            -FixtureRoot $fixture -Prefix 'new-' -LocalAppData $localData -InitialFirst $initialFirst `
            -InitialLast $initialLast -ExpectedCount 128 -SessionId 2
        $interruption = Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
            -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerCancellation
        if ($pattern.calls -ne 1 -or $interruption.target.control_id -ne 1009) {
            throw 'The live partial worker did not use its retained real invocation path.'
        }
        foreach ($invalid in @(
            @{ name = 'live'; value = $false }, @{ name = 'child'; value = [IntPtr]99 }
            @{ name = 'parent'; value = [IntPtr]99 }, @{ name = 'root'; value = [IntPtr]99 }
            @{ name = 'pid'; value = 99 }, @{ name = 'root_pid'; value = 99 }
            @{ name = 'class'; value = 'Edit' }, @{ name = 'name'; value = 'wrong' }
            @{ name = 'root_class'; value = 'OtherWindow' }, @{ name = 'root_name'; value = 'wrong' }
            @{ name = 'control_id'; value = 1010 }, @{ name = 'main_enabled'; value = $false }
            @{ name = 'enabled'; value = $false }, @{ name = 'visible'; value = $false }
        )) {
            $saved = $native.($invalid.name)
            $native.($invalid.name) = $invalid.value
            Assert-Fails {
                Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
                    -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerCancellation
            } 'cancellation'
            $native.($invalid.name) = $saved
        }
        foreach ($path in @($first, $last, $active)) {
            Remove-Item -LiteralPath $path
            Assert-Fails {
                Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
                    -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerCancellation
            } 'witnesses or active journal'
            [IO.File]::WriteAllText($path, 'fixture')
        }
        $candidate = Join-Path $journal 'candidate.drj'
        [IO.File]::WriteAllText($candidate, 'fixture')
        Assert-Fails {
            Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
                -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerCancellation
        } 'witnesses or active journal'
        Remove-Item -LiteralPath $candidate
        foreach ($field in @('pid', 'session_id', 'start_time_utc_ticks', 'main_handle')) {
            $saved = $binding.$field
            $binding.$field = if ($field -ceq 'start_time_utc_ticks') { '0' } else { 99 }
            Assert-Fails { Get-AcceptanceWorkerCancelTarget -Application $application -Binding $binding -RequireActive } 'binding changed'
            $binding.$field = $saved
        }
        if ($pattern.calls -ne 1) { throw 'A stale native binding or lost witness still invoked cancellation.' }
        $closeCalls = [Collections.Generic.List[long]]::new()
        function Request-AcceptanceWorkerWindowClose { param($Handle); $closeCalls.Add([long]$Handle) }
        [void](Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
            -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerClose)
        if ($closeCalls.Count -ne 1 -or $closeCalls[0] -ne 4096 -or $pattern.calls -ne 1) {
            throw 'Worker close did not dispatch ordinary close to the exact retained native main window.'
        }
    }

    $controllerPath = Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/controller-entry.psm1'
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($controllerPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw $errors[0] }
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-DrControllerRecoveryProcessIdentities'
    }, $false)
    . ([scriptblock]::Create($function.Extent.Text))
    $private = Join-Path $root 'private'
    $null = New-Item -ItemType Directory -Path $private
    $references = @()
    $files = foreach ($processId in @(101, 102)) {
        $leaf = "start-$processId.json"
        $path = Join-Path $private $leaf
        [IO.File]::WriteAllText($path, (@{
            boundary = 'started'
            binding = @{ pid = $processId; start_time_utc_ticks = [string]$processId }
        } | ConvertTo-Json))
        $reference = [pscustomobject]@{
            boundary = 'started'; sha256 = Get-LowerSha256 -Path $path
            bytes = (Get-Item -LiteralPath $path).Length
        }
        $references += $reference, [pscustomobject]@{ boundary = 'exited' }
        @{ file = $leaf; sha256 = $reference.sha256; bytes = $reference.bytes }
    }
    $indexPath = Join-Path $private 'private-index.json'
    [IO.File]::WriteAllText($indexPath, (@{
        classification = 'private-path-bearing-raw-recovery-evidence'; files = @($files)
    } | ConvertTo-Json -Depth 6))
    $result = [pscustomobject]@{
        selected_mode = 'ProcessCrash'
        process_crash = [pscustomobject]@{ processes = $references[0..1] }
        intent_only_candidate_discard = [pscustomobject]@{ status = 'not-run'; reason = 'switch-not-selected' }
        private_evidence = [pscustomobject]@{
            sha256 = Get-LowerSha256 -Path $indexPath; bytes = (Get-Item -LiteralPath $indexPath).Length
        }
    }
    $identities = Get-DrControllerRecoveryProcessIdentities -Result $result -EvidenceRoot $root
    if ($identities.Count -ne 1 -or -not $identities.Contains('101|101')) {
        throw 'Default ProcessCrash lost its required process binding.'
    }
    $result.intent_only_candidate_discard = [pscustomobject]@{ status = 'passed'; processes = $references[2..3] }
    $identities = Get-DrControllerRecoveryProcessIdentities -Result $result -EvidenceRoot $root
    if ($identities.Count -ne 2 -or -not $identities.Contains('102|102')) {
        throw 'Selected intent evidence lost its additional process binding.'
    }
    $result.intent_only_candidate_discard = [pscustomobject]@{ status = 'not-run'; reason = 'interrupted' }
    Assert-Fails { Get-DrControllerRecoveryProcessIdentities -Result $result -EvidenceRoot $root } 'invalid status'

    & {
        $script:resourceCalls = [Collections.Generic.List[string]]::new()
        function Remove-PSSession {
            [CmdletBinding()]param([object] $Session)
            $script:resourceCalls.Add('session')
            throw 'session failure'
        }
        $password = [pscustomobject]@{}
        $password | Add-Member ScriptMethod Dispose { $script:resourceCalls.Add('password'); throw 'password failure' }
        $mutex = [pscustomobject]@{}
        $mutex | Add-Member ScriptMethod ReleaseMutex { $script:resourceCalls.Add('release'); throw 'release failure' }
        $mutex | Add-Member ScriptMethod Dispose { $script:resourceCalls.Add('mutex'); throw 'mutex failure' }
        $failures = @(Close-DrControllerResources -Session 1 `
            -Credential ([pscustomobject]@{ Password = $password }) -Mutex $mutex -MutexHeld $true)
        if (($script:resourceCalls -join ',') -cne 'session,password,release,mutex' -or $failures.Count -ne 4) {
            throw 'Controller teardown must attempt every independent resource and retain every failure.'
        }
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Host 'Observer cleanup contracts passed.'
