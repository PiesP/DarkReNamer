param([Parameter(Mandatory)][hashtable] $Libraries)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedRoles = @(
    'powershell-guest-contracts'
    'powershell-guest-process'
    'powershell-guest-native'
    'powershell-guest-platform'
    'powershell-guest-uia'
    'powershell-guest-state'
    'powershell-guest-scenario'
    'powershell-guest-runtime'
    'powershell-recovery-bootstrap'
    'powershell-recovery-journal'
    'powershell-recovery-evidence'
    'powershell-recovery-process'
    'powershell-recovery-native'
    'powershell-recovery-worker'
    'powershell-recovery-scenarios'
)
if ($Libraries.Count -ne $expectedRoles.Count) { throw 'The verified definition library set is incomplete.' }
foreach ($role in $expectedRoles) {
    if (-not $Libraries.ContainsKey($role) -or $Libraries[$role] -isnot [scriptblock]) {
        throw "Missing verified definition library: $role"
    }
    . $Libraries[$role]
}

function Invoke-DrWindowsVmRecoveryAcceptance {
    [CmdletBinding()]
    param(
    [Parameter(Mandatory)]
    [string] $BundleRoot,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $ExpectedSessionId,

    [Parameter(Mandatory)]
    [string] $OutputRoot,

    [string] $EvidenceRoot,

    [Parameter(Mandatory)]
    [string] $PrivateEvidenceRoot,

    [string] $RuntimeRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string] $ExpectedScriptSha256,

    [ValidateSet('ProcessCrash', 'WorkerCancellation', 'WorkerClose')]
    [string] $Mode = 'ProcessCrash',

    [ValidateRange(128, 10000)]
    [int] $FixtureCount = 4096,

    [ValidateRange(10, 600)]
    [int] $TimeoutSeconds = 300,

    [switch] $RecoveryExport,

    [switch] $IntentOnlyCandidateDiscard,

    [switch] $ValidateOnly
,
    [Parameter(Mandatory)][string] $EntryPointPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AcceptanceProcessSequence = 0
$script:AcceptanceProcessJobCleanup = [Collections.Generic.List[object]]::new()


$requestedBundleRoot = $BundleRoot
$bootstrap = Resolve-AcceptanceBootstrap `
    -Root $requestedBundleRoot `
    -ObserverPath $EntryPointPath `
    -ExpectedObserverSha256 $ExpectedScriptSha256
$null = Resolve-VerifiedBundle -Root $requestedBundleRoot -InvokedScriptPath $bootstrap.runner_path
$BundleRoot = $requestedBundleRoot
$inputs = Resolve-AcceptanceInputs `
    -Root $BundleRoot `
    -RunnerPath $bootstrap.runner_path `
    -ObserverPath $EntryPointPath `
    -ExpectedObserverSha256 $ExpectedScriptSha256
if ($inputs.runner_sha256 -cne $bootstrap.runner_sha256 -or
    $inputs.observer_sha256 -cne $bootstrap.observer_sha256) {
    throw 'Authenticated bootstrap hashes changed during full bundle verification.'
}
if (($RecoveryExport -or $IntentOnlyCandidateDiscard) -and $Mode -cne 'ProcessCrash') {
    throw 'RecoveryExport and IntentOnlyCandidateDiscard require Mode ProcessCrash.'
}
if ($ValidateOnly) {
    Write-Host "Validated recovery acceptance inputs for product source $($inputs.contract.product_source_sha) and harness source $($inputs.contract.harness_source_sha)."
    return
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Recovery acceptance execution requires Windows.'
}
Assert-VmObserverExecutionContext -ExpectedSessionId $ExpectedSessionId
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
Protect-CurrentRunnerProcess

$evidenceParent = $OutputRoot
if ($EvidenceRoot) {
    $outputPath = [IO.Path]::GetFullPath($OutputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $evidencePath = [IO.Path]::GetFullPath($EvidenceRoot)
    $evidenceItem = Get-Item -LiteralPath $evidencePath -Force -ErrorAction Stop
    if (-not $evidencePath.StartsWith($outputPath, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFullPath((Split-Path -Parent $evidencePath)) -cne
            [IO.Path]::GetFullPath($OutputRoot) -or
        (Split-Path -Leaf $evidencePath) -cnotmatch '^recovery-acceptance-[0-9a-f]{32}$' -or
        -not $evidenceItem.PSIsContainer -or
        ($evidenceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The controller-selected recovery evidence directory is unsafe.'
    }
    $evidenceParent = $evidencePath
}
$evidenceRoot = New-AcceptanceOutputDirectory -Parent $evidenceParent
$privateRoot = New-AcceptancePrivateEvidenceDirectory -Parent $PrivateEvidenceRoot
$summaryPath = Join-Path $evidenceRoot 'summary.json'
Initialize-TrustedResultWriter `
    -Root $inputs.verified.root `
    -ResultRoot $evidenceRoot `
    -Path $summaryPath
if ([string]::IsNullOrWhiteSpace($RuntimeRoot) -or
    -not [IO.Path]::IsPathRooted($RuntimeRoot)) {
    throw 'Recovery acceptance requires the controller-provisioned candidate runtime directory.'
}
$runtimeItem = Get-Item -LiteralPath $RuntimeRoot -Force -ErrorAction Stop
if (-not $runtimeItem.PSIsContainer -or
    ($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Recovery candidate runtime root is unsafe.'
}
$runtimeRoot = $runtimeItem.FullName
$runtimeCursor = $runtimeItem
while ($null -ne $runtimeCursor) {
    if (($runtimeCursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Recovery candidate runtime path traverses a reparse point.'
    }
    $runtimeCursor = $runtimeCursor.Parent
}
$candidateOutputParentRoot = [IO.Path]::GetDirectoryName(
    [IO.Path]::GetFullPath($OutputRoot)
)
$verifiedBundleRoot = [IO.Path]::GetFullPath($inputs.verified.root)
if ([IO.Path]::GetFileName($verifiedBundleRoot) -cne 'bundle' -or
    [IO.Path]::GetFileName([IO.Path]::GetFullPath($OutputRoot)) -cne 'out' -or
    -not [string]::Equals(
        [IO.Path]::GetDirectoryName($verifiedBundleRoot),
        $candidateOutputParentRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Recovery acceptance requires a bundle and output directory under the same protected task root.'
}
$result = [ordered]@{
    schema_version = if ($inputs.contract.lane -ceq 'candidate-gui-only') { 2 } else { 1 }
    application = [ordered]@{
        file = $inputs.contract.application.file
        sha256 = $inputs.contract.application.sha256
    }
}
if ($inputs.contract.lane -ceq 'candidate-gui-only') {
    $result['lane'] = $inputs.contract.lane
    $result['product'] = $inputs.verified.manifest.product
    $result['harness'] = $inputs.verified.manifest.harness
    $result['observer_role'] = 'recovery'
}
else {
    $result['source_sha'] = $inputs.contract.product_source_sha
    $result['source_state'] = $inputs.contract.product_source_state
}
$result['runner_sha256'] = $inputs.runner_sha256
$result['observer'] = [ordered]@{
    file = $inputs.observer_file
    sha256 = $inputs.observer_sha256
}
$result['status'] = 'failed'
$result['scope'] = 'production-rename-worker-interruption'
$result['selected_mode'] = $Mode
$result['process_crash'] = [ordered]@{ status = 'not-run'; reason = 'mode-not-selected' }
$result['worker_cancellation'] = [ordered]@{ status = 'not-run'; reason = 'mode-not-selected' }
$result['worker_close'] = [ordered]@{ status = 'not-run'; reason = 'mode-not-selected' }
$result['recovery_export'] = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
$result['intent_only_candidate_discard'] = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
$result['failure_reason'] = $null
$result['diagnostic'] = $null
$result['ui_diagnostic'] = $null
$result['private_evidence'] = $null
$result['raw_cleanup'] = $null
$desktopLock = $null
$previousExecutionState = $null
try {
    Initialize-NativeCapture
    if (-not [DarkReNamerVmNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
        throw 'The observer could not enable per-monitor DPI awareness.'
    }
    $desktopLock = Enter-DesktopTestLock -SessionId $currentSession
    if ($null -eq $desktopLock) {
        throw 'Another Windows VM test runner is using this interactive desktop.'
    }
    $previousExecutionState = Enter-TestExecutionState
    Invoke-WithIsolatedEnvironment -RuntimeRoot $runtimeRoot -Action {
        $sessionResult = Invoke-AcceptanceSession `
            -Inputs $inputs `
            -EvidenceRoot $evidenceRoot `
            -PrivateRoot $privateRoot `
            -RuntimeRoot $runtimeRoot `
            -CandidateOutputParentRoot $candidateOutputParentRoot `
            -Count $FixtureCount `
            -Mode $Mode `
            -SessionId $currentSession `
            -WaitSeconds $TimeoutSeconds `
            -RunRecoveryExport ([bool]$RecoveryExport) `
            -RunIntentOnlyCandidateDiscard ([bool]$IntentOnlyCandidateDiscard)
        switch ($Mode) {
            'ProcessCrash' { $result.process_crash = $sessionResult.mode_result }
            'WorkerCancellation' { $result.worker_cancellation = $sessionResult.mode_result }
            'WorkerClose' { $result.worker_close = $sessionResult.mode_result }
        }
        $result.recovery_export = $sessionResult.recovery_export
        $result.intent_only_candidate_discard = $sessionResult.intent_only_candidate_discard
    }
    $result.status = 'passed'
}
catch {
    $result.failure_reason = 'recovery_acceptance_error'
    $modeFailure = [ordered]@{
        status = 'failed'
        reason = 'recovery_acceptance_error'
    }
    switch ($Mode) {
        'ProcessCrash' { $result.process_crash = $modeFailure }
        'WorkerCancellation' { $result.worker_cancellation = $modeFailure }
        'WorkerClose' { $result.worker_close = $modeFailure }
    }
    if ($RecoveryExport) {
        $result.recovery_export = $modeFailure
    }
    if ($IntentOnlyCandidateDiscard) {
        $result.intent_only_candidate_discard = $modeFailure
    }
    $uiDiagnosticPath = Join-Path $privateRoot 'session-ui-diagnostic.json'
    if (Test-Path -LiteralPath $uiDiagnosticPath -PathType Leaf) {
        $result.ui_diagnostic = New-AcceptancePrivateReference `
            -Path $uiDiagnosticPath -PrivateRoot $privateRoot -Boundary 'failure-ui-diagnostic'
    }
    $diagnosticPath = Join-Path $privateRoot 'diagnostic.txt'
    $diagnosticBytes = [Text.UTF8Encoding]::new($false).GetBytes(
        ($_ | Out-String -Width 4096)
    )
    Write-AcceptanceNewBytes -Path $diagnosticPath -Bytes $diagnosticBytes
    $result.diagnostic = New-AcceptancePrivateReference `
        -Path $diagnosticPath -PrivateRoot $privateRoot -Boundary 'failure-diagnostic'
}
finally {
    try {
        Exit-TestExecutionState -Previous $previousExecutionState
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'execution_state_restore_failed'
    }
    try {
        Exit-DesktopTestLock -Lock $desktopLock
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'desktop_lock_release_failed'
    }
    $ownedProcessesAfter = $null
    $journalAfter = $null
    $runtimeRootAfter = $null
    $candidateExportRootAfter = $null
    try {
        $ownedProcessesAfter = @(
            Get-VmAutomatedOwnedProcessInventory -Root $inputs.verified.root
        )
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'owned_process_cleanup_observation_failed'
    }
    try {
        $journalAfter = @(
            Get-VmAutomatedJournalInventory `
                -LocalAppData (Join-Path $runtimeRoot 'localappdata')
        )
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'journal_cleanup_observation_failed'
    }
    $processJobsClosed = $false
    try {
        [void](Assert-AcceptanceProcessJobLedgerClosed)
        $processJobsClosed = $true
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'process_job_cleanup_failed'
    }
    if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
        try {
            if (-not $processJobsClosed) {
                throw 'Candidate process jobs are not proven closed; runtime evidence was retained.'
            }
            Assert-OrdinaryDirectoryTree -Path $runtimeRoot
            Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
            if (Test-Path -LiteralPath $runtimeRoot) {
                throw 'The owned runtime fixture cleanup was incomplete.'
            }
        }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'runtime_cleanup_refused'
        }
    }
    try {
        $runtimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'runtime_cleanup_observation_failed'
    }
    try {
        $candidateExportRoot = Join-Path $candidateOutputParentRoot 'recovery-export'
        if (Test-Path -LiteralPath $candidateExportRoot) {
            $candidateExportItem = Get-Item -LiteralPath $candidateExportRoot -Force -ErrorAction Stop
            $candidateExportRootAfter = [ordered]@{
                exists = $true
                ordinary_directory = [bool]($candidateExportItem.PSIsContainer -and
                    ($candidateExportItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
                entries = @(
                    if ($candidateExportItem.PSIsContainer -and
                        ($candidateExportItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                        Get-ChildItem -LiteralPath $candidateExportRoot -Force -ErrorAction Stop |
                            ForEach-Object { [string]$_.Name }
                    }
                )
            }
        }
        else {
            $candidateExportRootAfter = [ordered]@{ exists = $false; ordinary_directory = $true; entries = @() }
        }
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'candidate_export_cleanup_observation_failed'
    }
    $result.raw_cleanup = [ordered]@{
        owned_processes_after = $ownedProcessesAfter
        runtime_root_after = $runtimeRootAfter
        candidate_export_root_after = $candidateExportRootAfter
        journal_after = [ordered]@{ entries = $journalAfter }
    }
    if ($null -eq $ownedProcessesAfter -or $ownedProcessesAfter.Count -ne 0 -or
        $null -eq $runtimeRootAfter -or $runtimeRootAfter.exists -or
        @($runtimeRootAfter.entries).Count -ne 0 -or
        $null -eq $candidateExportRootAfter -or $candidateExportRootAfter.exists -or
        @($candidateExportRootAfter.entries).Count -ne 0) {
        $result.status = 'failed'
        if ($null -eq $result.failure_reason) {
            $result.failure_reason = 'raw_cleanup_incomplete'
        }
    }
    if ($null -ne $journalAfter) {
        $unexpectedJournal = @($journalAfter | Where-Object {
            $_.name -cne 'runtime.lock' -or $_.kind -cne 'file' -or $_.bytes -ne 0
        })
        if ($unexpectedJournal.Count -ne 0 -or $journalAfter.Count -gt 1) {
            $result.status = 'failed'
            if ($null -eq $result.failure_reason) {
                $result.failure_reason = 'raw_journal_cleanup_incomplete'
            }
        }
    }
    try {
        if ($result.status -ceq 'passed') {
            try {
                Remove-AcceptanceRecoveryWindowProgress -PrivateRoot $privateRoot
            }
            catch {
                $result.status = 'failed'
                $result.failure_reason = 'recovery_window_progress_cleanup_failed'
            }
        }
        $result.private_evidence = Write-AcceptancePrivateIndex -PrivateRoot $privateRoot
    }
    catch {
        $result.status = 'failed'
        if ($null -eq $result.failure_reason) {
            $result.failure_reason = 'private_evidence_index_failed'
        }
    }
    Write-ResultDocument -Root $inputs.verified.root -Path $summaryPath -Result $result
}
Write-Host "Recovery acceptance evidence: $evidenceRoot"
if ($result.status -cne 'passed') {
    throw 'Recovery acceptance failed; inspect the external evidence directory.'
}
}

Export-ModuleMember -Function Invoke-DrWindowsVmRecoveryAcceptance
