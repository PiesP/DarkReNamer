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

    [Parameter(Mandatory)]
    [string] $PrivateEvidenceRoot,

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
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Recovery acceptance must run with a non-elevated token.'
}
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($currentSession -ne $ExpectedSessionId) {
    throw 'Recovery acceptance is in an unexpected desktop session.'
}

$evidenceRoot = New-AcceptanceOutputDirectory -Parent $OutputRoot
$privateRoot = New-AcceptancePrivateEvidenceDirectory -Parent $PrivateEvidenceRoot
$runtimeRoot = New-PrivateDirectory -Parent $evidenceRoot -Leaf 'runtime'
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
    if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
        try {
            $runtimeItem = Get-Item -LiteralPath $runtimeRoot -Force
            if (($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The owned runtime root became a reparse point.'
            }
            foreach ($entry in @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -Force)) {
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'The owned runtime tree contains a reparse point.'
                }
            }
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
    $result.raw_cleanup = [ordered]@{
        owned_processes_after = $ownedProcessesAfter
        runtime_root_after = $runtimeRootAfter
        journal_after = [ordered]@{ entries = $journalAfter }
    }
    if ($null -eq $ownedProcessesAfter -or $ownedProcessesAfter.Count -ne 0 -or
        $null -eq $runtimeRootAfter -or $runtimeRootAfter.exists -or
        @($runtimeRootAfter.entries).Count -ne 0) {
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
    Write-AcceptanceUtf8Json -Path (Join-Path $evidenceRoot 'summary.json') -Value $result
}
Write-Host "Recovery acceptance evidence: $evidenceRoot"
if ($result.status -cne 'passed') {
    throw 'Recovery acceptance failed; inspect the external evidence directory.'
}
}

Export-ModuleMember -Function Invoke-DrWindowsVmRecoveryAcceptance
