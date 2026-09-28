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
