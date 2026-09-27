param([Parameter(Mandatory)][hashtable] $Libraries)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedRoles = @(
    'powershell-controller-contracts'
    'powershell-controller-transport'
    'powershell-controller-poll'
    'powershell-controller-rescue'
)
if ($Libraries.Count -ne $expectedRoles.Count) { throw 'The verified definition library set is incomplete.' }
foreach ($role in $expectedRoles) {
    if (-not $Libraries.ContainsKey($role) -or $Libraries[$role] -isnot [scriptblock]) {
        throw "Missing verified definition library: $role"
    }
    . $Libraries[$role]
}

function Add-DrControllerLifecycleIdentity {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]] $Identities,
        [ValidateRange(0, 32)][int] $Depth = 0
    )

    if ($null -eq $Value) { return }
    if ($Depth -gt 32) { throw 'Observer result nesting exceeds its bound.' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        foreach ($item in $Value) {
            Add-DrControllerLifecycleIdentity -Value $item -Identities $Identities -Depth ($Depth + 1)
        }
        return
    }
    $properties = $Value.PSObject.Properties
    $lifecycleProperty = $properties['process_lifecycle']
    if ($null -ne $lifecycleProperty -and $null -ne $lifecycleProperty.Value) {
        $lifecycle = $lifecycleProperty.Value
        $pidValue = $lifecycle.pid
        $ticks = $lifecycle.start_time_utc_ticks
        if (($pidValue -isnot [int] -and $pidValue -isnot [long]) -or
            [long]$pidValue -lt 1 -or [long]$pidValue -gt 4294967295 -or
            $ticks -isnot [string] -or $ticks -cnotmatch '^[1-9][0-9]{0,18}$' -or
            [decimal]$ticks -gt 3155378975999999999) {
            throw 'A result process lifecycle has an invalid PID or creation time.'
        }
        $identity = ([long]$pidValue).ToString([Globalization.CultureInfo]::InvariantCulture) + '|' + $ticks
        [void]$Identities.Add($identity)
    }
    foreach ($property in $properties) {
        if ($property.Name -cne 'process_lifecycle') {
            Add-DrControllerLifecycleIdentity -Value $property.Value `
                -Identities $Identities -Depth ($Depth + 1)
        }
    }
}

function Get-DrControllerRecoveryProcessIdentities {
    param(
        [Parameter(Mandatory)][object] $Result,
        [Parameter(Mandatory)][string] $EvidenceRoot
    )

    $references = @()
    switch ([string]$Result.selected_mode) {
        'ProcessCrash' {
            $crash = $Result.PSObject.Properties['process_crash']
            $intent = $Result.PSObject.Properties['intent_only_candidate_discard']
            if ($null -eq $crash -or $null -eq $intent) { throw 'Recovery process references are missing.' }
            $references = @($crash.Value.processes) + @($intent.Value.processes)
        }
        'WorkerCancellation' { $references = @($Result.worker_cancellation.processes) }
        'WorkerClose' { $references = @($Result.worker_close.processes) }
        default { throw 'Recovery process mode is unavailable.' }
    }
    if ($references.Count -lt 2 -or $references.Count -gt 14 -or $references.Count % 2 -ne 0) {
        throw 'Recovery process reference count is invalid.'
    }
    $privateEvidence = $Result.PSObject.Properties['private_evidence']
    if ($null -eq $privateEvidence -or
        $privateEvidence.Value.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        ($privateEvidence.Value.bytes -isnot [int] -and $privateEvidence.Value.bytes -isnot [long])) {
        throw 'Recovery private index reference is invalid.'
    }
    $privateRoot = Join-Path $EvidenceRoot 'private'
    Assert-PathWithoutReparse $privateRoot
    $indexFiles = @(Get-ChildItem -LiteralPath $privateRoot -Filter 'private-index.json' -File -Recurse -Force)
    $indexMatches = @($indexFiles | Where-Object {
        $_.Length -eq [long]$privateEvidence.Value.bytes -and
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -ieq $privateEvidence.Value.sha256
    })
    if ($indexMatches.Count -ne 1) { throw 'Recovery private index does not match its protected reference.' }
    Assert-PathWithoutReparse $indexMatches[0].FullName
    $index = Get-Content -LiteralPath $indexMatches[0].FullName -Raw | ConvertFrom-Json
    if ($index.classification -cne 'private-path-bearing-raw-recovery-evidence' -or
        @($index.files).Count -lt 1 -or @($index.files).Count -gt 240) {
        throw 'Recovery private index classification or size is invalid.'
    }
    $privateDirectory = Split-Path -Parent $indexMatches[0].FullName
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($offset = 0; $offset -lt $references.Count; $offset += 2) {
        $reference = $references[$offset]
        if ($reference.boundary -cne 'started' -or
            $reference.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            ($reference.bytes -isnot [int] -and $reference.bytes -isnot [long])) {
            throw 'Recovery process start reference is invalid.'
        }
        $members = @($index.files | Where-Object {
            $_.bytes -eq [long]$reference.bytes -and $_.sha256 -ceq $reference.sha256
        })
        if ($members.Count -ne 1) { throw 'Recovery process start is absent or ambiguous in its private index.' }
        $segments = @(Get-SafeEvidencePathSegments ([string]$members[0].file))
        $rawPath = $privateDirectory
        foreach ($segment in $segments) { $rawPath = Join-Path $rawPath $segment }
        Assert-PathWithoutReparse $rawPath
        $rawLength = (Get-Item -LiteralPath $rawPath -Force).Length
        $actualDigest = (Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($rawLength -ne [long]$reference.bytes -or $actualDigest -cne $reference.sha256) {
            throw 'Recovery process start bytes differ from their digest reference.'
        }
        $start = Get-Content -LiteralPath $rawPath -Raw | ConvertFrom-Json
        if ($start.boundary -cne 'started' -or $null -eq $start.binding) {
            throw 'Recovery process start document has the wrong boundary.'
        }
        $pidValue = $start.binding.pid
        $ticks = $start.binding.start_time_utc_ticks
        if (($pidValue -isnot [int] -and $pidValue -isnot [long]) -or
            [long]$pidValue -lt 1 -or [long]$pidValue -gt 4294967295 -or
            $ticks -isnot [string] -or $ticks -cnotmatch '^[1-9][0-9]{0,18}$' -or
            [decimal]$ticks -gt 3155378975999999999) {
            throw 'Recovery process start binding has an invalid identity.'
        }
        $identity = ([long]$pidValue).ToString([Globalization.CultureInfo]::InvariantCulture) + '|' + $ticks
        if (-not $identities.Add($identity)) { throw 'Recovery process start identity is duplicated.' }
    }
    return ,$identities
}

function Test-DrControllerProcessJobCleanupLedger {
    param(
        [Parameter(Mandatory)][object] $Result,
        [string] $RecoveryEvidenceRoot,
        [switch] $AllowEmpty
    )

    try {
    $ledgerProperty = $Result.PSObject.Properties['process_job_cleanup']
    if ($null -eq $ledgerProperty) { return $false }
    $rows = @($ledgerProperty.Value)
    if ($rows.Count -gt 64) { return $false }
    if ($rows.Count -eq 0) {
        if (-not $AllowEmpty) { return $false }
        $guiProperty = $Result.PSObject.Properties['gui']
        if ($null -eq $guiProperty -or $null -eq $guiProperty.Value) { return $false }
        $gui = $guiProperty.Value
        $errorDetailProperty = $gui.PSObject.Properties['error_detail']
        if ($gui.status -cne 'failed' -or
            $gui.job_cleanup -isnot [bool] -or -not $gui.job_cleanup -or
            $null -ne $gui.process_id -or
            $gui.PSObject.Properties.Name -ccontains 'process_lifecycle' -or
            $gui.failure_reason -cne 'gui_error' -or
            $null -eq $errorDetailProperty -or $null -eq $errorDetailProperty.Value) {
            return $false
        }
        $errorDetail = $errorDetailProperty.Value
        $errorFields = @($errorDetail.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        $expectedErrorFields = @('exception_type', 'message', 'native_error') | Sort-Object -CaseSensitive
        if (($errorFields -join "`n") -cne ($expectedErrorFields -join "`n") -or
            $errorDetail.exception_type -isnot [string] -or
            [string]::IsNullOrWhiteSpace($errorDetail.exception_type) -or
            $errorDetail.exception_type.Length -gt 256 -or
            $errorDetail.message -isnot [string] -or $errorDetail.message.Length -gt 1024 -or
            ($null -ne $errorDetail.native_error -and
                ($errorDetail.native_error -isnot [int] -and $errorDetail.native_error -isnot [long]))) {
            return $false
        }
        return $true
    }
    $expectedFields = @(
        'active_process_ids_at_stop', 'active_processes_at_close',
        'active_processes_at_primary_exit', 'active_processes_at_stop',
        'capture_complete', 'error', 'forced_termination', 'had_survivors',
        'job_closed', 'job_empty', 'pid', 'primary_process_active_at_stop',
        'process_start_time_utc_ticks', 'status', 'termination_exit_code',
        'total_processes_at_stop'
    )
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        if ($null -eq $row) { return $false }
        $fields = @($row.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        $expected = @($expectedFields | Sort-Object -CaseSensitive)
        if (($fields -join "`n") -cne ($expected -join "`n")) { return $false }
        if ($row.pid -isnot [int] -and $row.pid -isnot [long]) { return $false }
        if ([long]$row.pid -lt 1 -or [long]$row.pid -gt 4294967295 -or
            $row.process_start_time_utc_ticks -isnot [string] -or
            $row.process_start_time_utc_ticks -cnotmatch '^[1-9][0-9]{0,18}$' -or
            [decimal]$row.process_start_time_utc_ticks -gt 3155378975999999999) { return $false }
        $identity = ([long]$row.pid).ToString([Globalization.CultureInfo]::InvariantCulture) + '|' +
            $row.process_start_time_utc_ticks
        if (-not $identities.Add($identity)) { return $false }
        if ($row.status -cne 'clean' -or $row.job_empty -isnot [bool] -or -not $row.job_empty -or
            $row.job_closed -isnot [bool] -or -not $row.job_closed -or
            $row.capture_complete -isnot [bool] -or -not $row.capture_complete -or
            $row.had_survivors -isnot [bool] -or $row.had_survivors -or
            $row.forced_termination -isnot [bool] -or
            $row.error -ne $null -or
            $row.active_processes_at_close -isnot [int] -and $row.active_processes_at_close -isnot [long] -or
            [long]$row.active_processes_at_close -ne 0) { return $false }
        $activeIds = @()
        if ($null -ne $row.active_process_ids_at_stop) {
            $activeIds = @($row.active_process_ids_at_stop)
        }
        if ($activeIds.Count -gt 64) { return $false }
        foreach ($field in @('active_processes_at_primary_exit', 'active_processes_at_stop',
                             'total_processes_at_stop')) {
            $value = $row.$field
            if ($null -ne $value -and
                (($value -isnot [int] -and $value -isnot [long]) -or
                 [long]$value -lt 0 -or [long]$value -gt 4294967295)) { return $false }
        }
        foreach ($processId in $activeIds) {
            if (($processId -isnot [int] -and $processId -isnot [long]) -or
                [long]$processId -lt 1 -or [long]$processId -gt 4294967295) { return $false }
        }
        if ($null -ne $row.primary_process_active_at_stop) {
            if ($row.primary_process_active_at_stop -isnot [bool]) { return $false }
            if ($row.primary_process_active_at_stop) {
                if ($row.forced_termination -isnot [bool] -or -not $row.forced_termination -or
                    $row.active_processes_at_stop -isnot [int] -and $row.active_processes_at_stop -isnot [long] -or
                    [long]$row.active_processes_at_stop -ne 1 -or
                    $row.total_processes_at_stop -isnot [int] -and $row.total_processes_at_stop -isnot [long] -or
                    [long]$row.total_processes_at_stop -ne 1 -or
                    $activeIds.Count -ne 1 -or [long]$activeIds[0] -ne [long]$row.pid -or
                    $row.termination_exit_code -isnot [int] -and $row.termination_exit_code -isnot [long] -or
                    [long]$row.termination_exit_code -lt 2 -or
                    [long]$row.termination_exit_code -gt 2147483647 -or
                    [long]$row.termination_exit_code -eq 259) { return $false }
            }
            elseif ($row.forced_termination -or $row.termination_exit_code -ne $null) {
                return $false
            }
        }
        else {
            if ($row.forced_termination -or $row.termination_exit_code -ne $null) { return $false }
        }
    }
    $expectedIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if (-not [string]::IsNullOrWhiteSpace($RecoveryEvidenceRoot)) {
        $expectedIdentities = Get-DrControllerRecoveryProcessIdentities `
            -Result $Result -EvidenceRoot $RecoveryEvidenceRoot
    }
    else {
        Add-DrControllerLifecycleIdentity -Value $Result -Identities $expectedIdentities
    }
    if ($expectedIdentities.Count -lt 1 -or $expectedIdentities.Count -ne $identities.Count) {
        return $false
    }
    foreach ($identity in $expectedIdentities) {
        if (-not $identities.Contains($identity)) { return $false }
    }
    return $true
    }
    catch { return $false }
}

function Invoke-DrWindowsVmController {
    [CmdletBinding(DefaultParameterSetName = 'Direct')]
    param(
    [Parameter(Mandatory = $true)][string] $BundleRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string] $VmName,
    [Parameter(ParameterSetName = 'Direct')]
    [ValidateScript({ $_ -ne [guid]::Empty })][guid] $ExpectedVmId,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string] $CredentialHelper,
    [Parameter(Mandatory = $true, ParameterSetName = 'Ssh')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z')]
    [string] $SshHost,
    [ValidatePattern('^S-1-5-21-(\d+-){2}\d+-\d+$')][string] $ExpectedDesktopSid,
    [ValidateRange(10, 1800)][int] $TestTimeoutSeconds = 300,
    [ValidateRange(60, 14400)][int] $SuiteTimeoutSeconds = 2400,
    [ValidateSet('core', 'ui', 'recovery')][string] $TaskKind,
    [string] $AcceptanceOutputRoot,
    [string] $AcceptanceManifest,
    [ValidateSet('current-dpi', 'full-context', 'standard', 'text-scale', 'tooltip')]
    [string] $AcceptanceMode,
    [ValidateSet('system', 'light', 'dark')][string] $AcceptanceAppearance,
    [ValidateSet(100, 150)][int] $AcceptanceTextScalePercent = 100,
    [switch] $AcceptanceHighContrast,
    [switch] $AcceptanceClipboard,
    [switch] $AcceptanceCaptureNativeMenu,
    [switch] $AcceptanceCaptureAdvancedAppearance,
    [string] $RecoveryOutputRoot,
    [ValidateSet('ProcessCrash', 'WorkerCancellation', 'WorkerClose')]
    [string] $RecoveryMode,
    [ValidateRange(128, 10000)][int] $RecoveryFixtureCount = 4096,
    [ValidatePattern('^[0-9a-f]{64}\z')][string] $RecoveryObserverSha256,
    [switch] $RecoveryExport,
    [switch] $RecoveryIntentOnlyCandidateDiscard,
    [guid] $ExpectedGuestVmId = [guid]::Empty,
    [ValidatePattern('^[0-9a-f]{64}\z')][string] $ExpectedBundleManifestSha256
,
    [Parameter(Mandatory)][string] $EntryPointPath,
    [Parameter(Mandatory)][object] $VerifiedTooling
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$coreResultMaximumBytes = 4MB
$coreTestChannelMaximumBytes = 4MB
$coreTestOutputAggregateMaximumBytes = 64MB
$coreOutputFileMaximumBytes = 128MB
$coreOutputAggregateMaximumBytes = 256MB


$taskSelection = Resolve-ControllerTaskSelection `
    -RequestedKind $TaskKind `
    -HasUiOutput $PSBoundParameters.ContainsKey('AcceptanceOutputRoot') `
    -HasUiManifest $PSBoundParameters.ContainsKey('AcceptanceManifest') `
    -HasUiMode $PSBoundParameters.ContainsKey('AcceptanceMode') `
    -HasUiAppearance $PSBoundParameters.ContainsKey('AcceptanceAppearance') `
    -UiMode $AcceptanceMode `
    -UiAppearance $AcceptanceAppearance `
    -UiTextScalePercent $AcceptanceTextScalePercent `
    -HasUiTextScalePercent $PSBoundParameters.ContainsKey('AcceptanceTextScalePercent') `
    -UiHighContrast ([bool]$AcceptanceHighContrast) `
    -UiClipboard ([bool]$AcceptanceClipboard) `
    -UiCaptureNativeMenu ([bool]$AcceptanceCaptureNativeMenu) `
    -UiCaptureAdvancedAppearance ([bool]$AcceptanceCaptureAdvancedAppearance) `
    -HasRecoveryOutput $PSBoundParameters.ContainsKey('RecoveryOutputRoot') `
    -HasRecoveryMode $PSBoundParameters.ContainsKey('RecoveryMode') `
    -HasRecoveryObserverSha256 $PSBoundParameters.ContainsKey('RecoveryObserverSha256') `
    -RecoveryMode $RecoveryMode `
    -RecoveryExport ([bool]$RecoveryExport) `
    -RecoveryIntentOnlyCandidateDiscard ([bool]$RecoveryIntentOnlyCandidateDiscard) `
    -HasRecoveryFixtureCount $PSBoundParameters.ContainsKey('RecoveryFixtureCount') `
    -TimeoutSeconds $TestTimeoutSeconds

$transportKind = if ($PSCmdlet.ParameterSetName -eq 'Ssh') { 'ssh' } else { 'powershell_direct' }
$acceptance = $taskSelection.kind -ceq 'ui'
$recovery = $taskSelection.kind -ceq 'recovery'
$observerTask = [bool]$taskSelection.is_observer
if ($observerTask -and $ExpectedGuestVmId -eq [guid]::Empty) {
    throw 'Observer tasks require the expected Hyper-V guest VM identity.'
}
$hostPlatform = if ($PSVersionTable.ContainsKey('Platform')) {
    [string]$PSVersionTable.Platform
}
else {
    [Environment]::OSVersion.Platform.ToString()
}
if ($transportKind -eq 'powershell_direct') {
    $env:PSModulePath = "$PSHOME\Modules;C:\Program Files\WindowsPowerShell\Modules"
}
$BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
if ($acceptance) {
    $AcceptanceOutputRoot = [IO.Path]::GetFullPath($AcceptanceOutputRoot)
    $AcceptanceManifest = [IO.Path]::GetFullPath($AcceptanceManifest)
}
if ($recovery) {
    $RecoveryOutputRoot = [IO.Path]::GetFullPath($RecoveryOutputRoot)
}
$transport = [ordered]@{
    kind = $transportKind
    task_kind = $taskSelection.kind
    host_platform = $hostPlatform
    status = 'starting'
    guest_cleanup = $false
}
$credential = $null
$session = $null
$guestRoot = $null
$trustedTaskRoot = $null
$taskName = 'DarkReNamerTests-' + [guid]::NewGuid().ToString('N')
$runnerTaskBaseline = @()
$runnerProcessBaseline = @()
$result = $null
$processJobsClosed = $false
$acceptancePassed = $false
$observerProcess = $null
$transportOutputRoot = if ($acceptance) {
    $AcceptanceOutputRoot
} elseif ($recovery) {
    $RecoveryOutputRoot
} else {
    $BundleRoot
}
$mutex = $null
$mutexHeld = $false
$toolingTransfer = $null


try {
    Assert-PathWithoutReparse $BundleRoot
    $bundleManifestPath = Join-Path $BundleRoot 'bundle.json'
    if (-not [string]::IsNullOrEmpty($ExpectedBundleManifestSha256) -and
        (Get-FileHash -LiteralPath $bundleManifestPath -Algorithm SHA256).Hash -ine
            $ExpectedBundleManifestSha256) {
        throw 'Bundle manifest differs from the launcher-frozen input.'
    }
    $manifest = Get-Content -LiteralPath $bundleManifestPath -Raw | ConvertFrom-Json
    $candidateLane = $manifest.schema_version -eq 2 -and $manifest.lane -ceq 'candidate-gui-only'
    if ($candidateLane) {
        if ($manifest.product.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
            $manifest.product.source_state -cne 'clean' -or
            $manifest.harness.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
            $manifest.harness.source_state -cne 'clean' -or
            $manifest.product.candidate.origin_authentication -cne 'pending-hosted' -or
            @($manifest.test_binaries).Count -ne 0) {
            throw 'An exact-candidate GUI-only bundle is invalid.'
        }
        if ($ExpectedGuestVmId -eq [guid]::Empty) {
            throw 'Exact-candidate execution requires an expected guest VM identity.'
        }
        if ([string]::IsNullOrEmpty($ExpectedBundleManifestSha256)) {
            throw 'Exact-candidate execution requires a launcher-frozen bundle manifest digest.'
        }
        $artifacts = @(
            $manifest.product.application
            $manifest.product.provenance.release_handoff
            $manifest.product.provenance.run_metadata
            $manifest.product.provenance.artifact_metadata
            $manifest.harness.launcher
            $manifest.harness.controller
            $manifest.harness.runner
            @($manifest.harness.observers.PSObject.Properties | ForEach-Object Value)
            @($manifest.harness.validators.PSObject.Properties | ForEach-Object Value)
        )
        if ($manifest.harness.controller.file -cne 'run-windows-vm-tests.ps1' -or
            (Get-FileHash -LiteralPath $EntryPointPath -Algorithm SHA256).Hash -ine
                $manifest.harness.controller.sha256) {
            throw 'The invoked controller differs from the frozen candidate harness.'
        }
    }
    else {
        if ($manifest.schema_version -ne 1 -or $manifest.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
            $manifest.source_state -ne 'clean' -or @($manifest.test_binaries).Count -eq 0) {
            throw 'A clean source-bound bundle with native tests is required.'
        }
        $artifacts = @($manifest.test_binaries) + @($manifest.application, $manifest.runner)
    }
    $names = @{}
    foreach ($artifact in $artifacts) {
        Assert-PlainFile $artifact.file
        if ($names.ContainsKey($artifact.file)) { throw 'Duplicate artifact name.' }
        $names[$artifact.file] = $true
        $path = Join-Path $BundleRoot $artifact.file
        Assert-PathWithoutReparse $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $artifact.sha256) { throw 'Bundle artifact hash mismatch.' }
    }
    if ($acceptance) {
        Assert-PathWithoutReparse $AcceptanceManifest
        Assert-PathWithoutReparse $AcceptanceOutputRoot
        $outputItem = Get-Item -LiteralPath $AcceptanceOutputRoot -Force
        if (-not $outputItem.PSIsContainer -or @(Get-ChildItem -LiteralPath $outputItem.FullName -Force).Count -ne 0) {
            throw 'Acceptance output must be an existing empty ordinary directory.'
        }
        $acceptanceInput = Get-Content -LiteralPath $AcceptanceManifest -Raw | ConvertFrom-Json
        Assert-SafeAcceptanceRunId -RunId $acceptanceInput.run_id
        $expectedAcceptanceSourceSha = if ($candidateLane) {
            $manifest.product.source_sha
        } else {
            $manifest.source_sha
        }
        if ($acceptanceInput.schema_version -ne 1 -or
            $acceptanceInput.source_sha -cne $expectedAcceptanceSourceSha -or
            $acceptanceInput.request.mode -cne $AcceptanceMode -or
            $acceptanceInput.request.appearance -cne $AcceptanceAppearance -or
            $acceptanceInput.request.text_scale_percent -ne $AcceptanceTextScalePercent) {
            throw 'Acceptance arguments differ from the immutable input manifest.'
        }
        Assert-AcceptanceInputArtifactBinding `
            -InputDocument $acceptanceInput `
            -Manifest $manifest `
            -CandidateLane $candidateLane
        $observer = $acceptanceInput.artifacts.observer
        if ($observer.file -cne 'inputs/windows-vm-acceptance.ps1' -or
            (Get-FileHash -LiteralPath (Join-Path $BundleRoot 'windows-vm-acceptance.ps1') -Algorithm SHA256).Hash -ine $observer.sha256) {
            throw 'Acceptance observer differs from the immutable input manifest.'
        }
        if ($candidateLane -and
            ($manifest.harness.observers.ui.file -cne 'windows-vm-acceptance.ps1' -or
             $manifest.harness.observers.ui.sha256 -ine $observer.sha256)) {
            throw 'Acceptance observer differs from the frozen candidate harness role.'
        }
    }
    elseif ($recovery) {
        Assert-PathWithoutReparse $RecoveryOutputRoot
        $outputItem = Get-Item -LiteralPath $RecoveryOutputRoot -Force
        if (-not $outputItem.PSIsContainer -or
            @(Get-ChildItem -LiteralPath $outputItem.FullName -Force).Count -ne 0) {
            throw 'Recovery output must be an existing empty ordinary directory.'
        }
        $observer = if ($candidateLane) {
            $manifest.harness.observers.recovery
        }
        else {
            [pscustomobject]@{
                file = 'windows-vm-recovery-acceptance.ps1'
                sha256 = $RecoveryObserverSha256
            }
        }
        $observerPath = Join-Path $BundleRoot 'windows-vm-recovery-acceptance.ps1'
        Assert-PathWithoutReparse $observerPath
        if ($observer.file -cne 'windows-vm-recovery-acceptance.ps1' -or
            $observer.sha256 -cne $RecoveryObserverSha256 -or
            (Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine
                $RecoveryObserverSha256) {
            throw 'Recovery observer differs from the frozen task role.'
        }
    }
    if ($transportKind -eq 'powershell_direct') {
        $vm = Resolve-DirectControllerVm -Name $VmName -ExpectedId $ExpectedVmId
        $mutex = New-Object Threading.Mutex($false, ('Local\DarkReNamerVmTests-' + $vm.Id))
        try { $mutexHeld = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
        if (-not $mutexHeld) { throw 'Another native test controller is using this VM.' }
        $credential = & $CredentialHelper -Action Load
        if ($credential -isnot [Management.Automation.PSCredential]) { throw 'Credential helper did not return a PSCredential.' }
        $vm = Resolve-DirectControllerVm -Name $VmName -ExpectedId $vm.Id
        if ($vm.State.ToString() -ne 'Running') { throw 'Start the configured VM before testing.' }
        $session = New-DirectControllerSession -VmId $vm.Id -Credential $credential
        $transport.vm_id = $vm.Id.ToString()
    }
    else {
        $session = New-SshControllerSession -HostAlias $SshHost
    }
    $endpoint = Invoke-Command -Session $session -ScriptBlock {
        $platform = [Environment]::OSVersion.Platform.ToString()
        $isAdministrator = $false
        if ($platform -ceq 'Win32NT') {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        [pscustomobject]@{
            platform = $platform
            powershell_version = $PSVersionTable.PSVersion.ToString()
            is_administrator = $isAdministrator
            vm_id = if ($platform -ceq 'Win32NT') {
                (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -Name VirtualMachineId).VirtualMachineId
            } else { $null }
        }
    }
    if ($endpoint.platform -cne 'Win32NT') {
        throw 'The selected transport endpoint must be the configured Windows VM.'
    }
    if ($transportKind -eq 'ssh') {
        Assert-SshPowerShellVersion -Version $endpoint.powershell_version -Context 'The VM SSH PowerShell subsystem'
    }
    if (-not $endpoint.is_administrator) {
        throw 'The VM controller account must be a local administrator so it can register the limited interactive test task.'
    }
    if ($observerTask -or $candidateLane) {
        $expectedGuestId = $ExpectedGuestVmId.ToString('D').ToLowerInvariant()
        try { $actualGuestId = ([guid]$endpoint.vm_id).ToString('D').ToLowerInvariant() }
        catch { throw 'The guest did not expose a canonical Hyper-V Guest Parameters VM identity.' }
        if ($actualGuestId -cne $expectedGuestId) {
            throw 'The SSH endpoint Hyper-V VM identity differs from the private connection profile.'
        }
        $guestIdentitySha256 = Get-LowerTextSha256 $actualGuestId
        if ($acceptance -and
            ($acceptanceInput.guest_preflight.vm_identity_kind -cne 'hyper-v-guest-parameters-virtual-machine-id-v1' -or
             $acceptanceInput.guest_preflight.vm_identity_sha256 -cne $guestIdentitySha256)) {
            throw 'The post-connection guest VM identity differs from the immutable preflight.'
        }
        $transport.vm_id = $actualGuestId
        $transport.vm_identity_kind = 'hyper-v-guest-parameters-virtual-machine-id-v1'
        $transport.vm_identity_sha256 = $guestIdentitySha256
    }
    $desktop = Invoke-Command -Session $session -ArgumentList $ExpectedDesktopSid -ScriptBlock {
        param($expectedSid)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($expectedSid -and $sid -cne $expectedSid) { throw 'RDP profile and controller account differ.' }
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VmDesktopState {
    [DllImport("wtsapi32.dll", SetLastError=true)]
    static extern bool WTSQuerySessionInformation(IntPtr server, int session, int info, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
    public static bool Active(int session) {
        IntPtr buffer; int bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, session, 8, out buffer, out bytes)) return false;
        try { return bytes >= 4 && Marshal.ReadInt32(buffer) == 0; }
        finally { WTSFreeMemory(buffer); }
    }
}
'@
        $localUser = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object SID -eq $sid)
        if ($localUser.Count -ne 1) { throw 'The VM test account must be local.' }
        $deadline = (Get-Date).AddSeconds(30)
        do {
            $sessions = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid -eq $sid } | Select-Object -ExpandProperty SessionId -Unique)
            $unlocked = @($sessions | Where-Object { $candidate = $_; [VmDesktopState]::Active($candidate) -and -not (Get-Process LogonUI -ErrorAction SilentlyContinue | Where-Object SessionId -eq $candidate) })
            if ($unlocked.Count -eq 1) { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)
        if ($unlocked.Count -ne 1 -or $unlocked[0] -le 0) { throw 'Log in to one unlocked desktop with the configured VM test account.' }
        if (-not (Test-Path "$env:SystemRoot\System32\VCRUNTIME140.dll")) { throw 'Install the Microsoft x64 Visual C++ runtime in the VM before testing.' }
        [pscustomobject]@{sid = $sid; session_id = $unlocked[0]}
    }
    $workspaceRoots = Invoke-Command -Session $session -ArgumentList $taskName,$desktop.sid -ScriptBlock {
        param($name,$runnerSid)
        if ($name -cnotmatch '^DarkReNamerTests-[0-9a-f]{32}$' -or
            $runnerSid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$') {
            throw 'The VM workspace identity is invalid.'
        }
        if (-not ('DarkReNamerVmControllerWorkspace' -as [type])) {
            Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class DarkReNamerVmControllerWorkspace {
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes {
        public int Length;
        public IntPtr SecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string descriptor, uint revision, out IntPtr securityDescriptor, out uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string path, uint access, uint share, ref SecurityAttributes attributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static void CreateResultFile(string path, string runnerSid) {
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint WRITE_DAC = 0x00040000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint CREATE_NEW = 1;
        const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        string descriptor = "O:BA G:BA D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;" + runnerSid +")(A;;FR;;;OW)";
        IntPtr securityDescriptor = IntPtr.Zero;
        try {
            uint size;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    descriptor, 1, out securityDescriptor, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            SecurityAttributes attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            attributes.SecurityDescriptor = securityDescriptor;
            attributes.InheritHandle = false;
            using (SafeFileHandle file = CreateFileW(path,
                    GENERIC_READ | GENERIC_WRITE | WRITE_DAC, FILE_SHARE_READ,
                    ref attributes, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero)) {
                if (file == null || file.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally {
            if (securityDescriptor != IntPtr.Zero) LocalFree(securityDescriptor);
        }
    }
}
'@
        }

        function New-WorkspaceDirectorySecurity {
            param([switch] $ForGuestRoot, [switch] $ForBase)
            $security = [Security.AccessControl.DirectorySecurity]::new()
            $security.SetAccessRuleProtection($true, $false)
            $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
            $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
            $security.SetOwner($administratorSid)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            foreach ($principalSid in @($administratorSid, $systemSid)) {
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $principalSid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$security.AddAccessRule($rule)
            }
            if ($ForBase) {
                $traverse = [Security.AccessControl.FileSystemAccessRule]::new(
                    [Security.Principal.SecurityIdentifier]::new($runnerSid),
                    [Security.AccessControl.FileSystemRights]::Traverse,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$security.AddAccessRule($traverse)
            }
            if ($ForGuestRoot) {
                $identity = [Security.Principal.SecurityIdentifier]::new($runnerSid)
                $localRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
                    [Security.AccessControl.FileSystemRights]::WriteData -bor
                    [Security.AccessControl.FileSystemRights]::AppendData -bor
                    [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
                    [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
                $localRule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $identity, $localRights,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$security.AddAccessRule($localRule)
                $inheritedRule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $identity,
                    [Security.AccessControl.FileSystemRights]::Modify,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::InheritOnly,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$security.AddAccessRule($inheritedRule)
            }
            $security
        }

        $base = Join-Path $env:ProgramData 'DarkReNamerVmRuns'
        $baseSecurity = New-WorkspaceDirectorySecurity -ForBase
        if (Test-Path -LiteralPath $base) {
            $baseItem = Get-Item -LiteralPath $base -Force -ErrorAction Stop
            $baseAcl = Get-Acl -LiteralPath $base
            $ownerSid = ([Security.Principal.NTAccount]$baseAcl.Owner).Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
            if (-not $baseItem.PSIsContainer -or
                ($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $ownerSid -notin @('S-1-5-18','S-1-5-32-544')) {
                throw 'The protected VM workspace base is unsafe or has an unexpected owner.'
            }
            Set-Acl -LiteralPath $base -AclObject $baseSecurity
        }
        else {
            [void][System.IO.FileSystemAclExtensions]::CreateDirectory($baseSecurity, $base)
        }
        $path = Join-Path $base $name
        if (Test-Path -LiteralPath $path) {
            throw 'The unique VM workspace path already exists.'
        }
        $rootSecurity = New-WorkspaceDirectorySecurity -ForGuestRoot
        [void][System.IO.FileSystemAclExtensions]::CreateDirectory($rootSecurity, $path)
        function global:Get-DrVmTrustedPowerShellPath {
            $programFiles = [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::ProgramFiles
            )
            $programFilesItem = Get-Item -LiteralPath $programFiles -Force -ErrorAction Stop
            $programFilesRoot = $programFilesItem.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
            # PowerShell Direct can enter through Windows PowerShell 5.1, whose PSHOME is not pwsh.
            $enginePath = [IO.Path]::GetFullPath((Join-Path (Join-Path $programFilesRoot 'PowerShell\7') 'pwsh.exe'))
            if (-not $programFilesItem.PSIsContainer -or
                ($programFilesItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not $enginePath.StartsWith(
                    $programFilesRoot + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'PowerShell must run from the protected Program Files installation.'
            }
            $trustedPrincipals = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
            $dangerousRights = [int](
                [Security.AccessControl.FileSystemRights]::WriteData -bor
                [Security.AccessControl.FileSystemRights]::AppendData -bor
                [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
                [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
                [Security.AccessControl.FileSystemRights]::Delete -bor
                [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
                [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                [Security.AccessControl.FileSystemRights]::TakeOwnership
            )
            $cursor = Get-Item -LiteralPath $enginePath -Force -ErrorAction Stop
            if ($cursor.PSIsContainer -or
                ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The protected PowerShell executable is not an ordinary file.'
            }
            while ($null -ne $cursor) {
                if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'The protected PowerShell path traverses a reparse point.'
                }
                $acl = Get-Acl -LiteralPath $cursor.FullName -ErrorAction Stop
                $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
                if ($ownerSid -notin $trustedPrincipals) {
                    throw 'A non-administrative principal owns part of the PowerShell installation.'
                }
                foreach ($rule in @($acl.GetAccessRules(
                    $true, $true, [Security.Principal.SecurityIdentifier]
                ))) {
                    if (($rule.PropagationFlags -band
                        [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) {
                        continue
                    }
                    $mask = [int]$rule.FileSystemRights
                    if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                        ($mask -band $dangerousRights) -ne 0 -and
                        $rule.IdentityReference.Value -notin $trustedPrincipals) {
                        throw 'A non-administrative principal can modify the PowerShell installation.'
                    }
                }
                if ([string]::Equals(
                    $cursor.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar),
                    $programFilesRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )) { break }
                $cursor = if ($cursor -is [IO.FileInfo]) {
                    $cursor.Directory
                }
                else {
                    $cursor.Parent
                }
            }
            if ($null -eq $cursor) {
                throw 'The protected PowerShell executable is outside Program Files.'
            }
            $signature = Get-AuthenticodeSignature -FilePath $enginePath -ErrorAction Stop
            if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
                $signature.SignerCertificate.Subject -notmatch '(?i)(^|,\s*)CN=Microsoft Corporation(?:,|$)') {
                throw 'The Program Files PowerShell executable is not signed by Microsoft.'
            }
            $enginePath
        }
        function global:Register-DrVmTask {
            param(
                [Parameter(Mandatory)][string] $TaskName,
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId,
                [Parameter(Mandatory)][string] $GuestRoot,
                [Parameter(Mandatory)][string] $RuntimeRoot,
                [Parameter(Mandatory)][string] $ObserverPath,
                [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ObserverSha256,
                [Parameter(Mandatory)][string] $BundleSourcePath,
                [Parameter(Mandatory)][object[]] $BundleRecords,
                [string] $InputManifestPath,
                [ValidatePattern('^[0-9a-f]{64}$')][string] $InputManifestSha256,
                [Parameter(Mandatory)][string] $Execute,
                [Parameter(Mandatory)][string] $Arguments,
                [Parameter(Mandatory)][string] $WorkingDirectory,
                [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+\.json$')][string] $TrustedResultLeaf,
                [string[]] $OutputDirectoryLeaves = @(),
                [Parameter(Mandatory)][int] $ExecutionTimeLimitSeconds
            )
            if ($UserSid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$') {
                throw 'The scheduled task principal SID is invalid.'
            }
            if ($TaskName -cnotmatch '^DarkReNamerTests-[0-9a-f]{32}$' -or
                -not [IO.Path]::IsPathRooted($Execute) -or
                -not [IO.Path]::IsPathRooted($WorkingDirectory) -or
                -not [IO.Path]::IsPathRooted($GuestRoot) -or
                -not [IO.Path]::IsPathRooted($RuntimeRoot) -or
                -not [IO.Path]::IsPathRooted($ObserverPath) -or
                -not [IO.Path]::IsPathRooted($BundleSourcePath) -or
                $SessionId -le 0 -or
                $ExecutionTimeLimitSeconds -le 0) {
                throw 'The scheduled task definition is invalid.'
            }
            if ($null -eq $global:DrVmToolingRecords -or
                $global:DrVmToolingRecords.Count -eq 0 -or
                $global:DrVmToolingManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {
                throw 'The source-bound VM tooling inventory is unavailable.'
            }
            $base = Join-Path $env:ProgramData 'DarkReNamerVmRuns'
            $trustedTaskRoot = Join-Path $base ($TaskName + '-trusted')
            $trustedTaskSecurity = [Security.AccessControl.DirectorySecurity]::new()
            $trustedTaskSecurity.SetAccessRuleProtection($true, $false)
            $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
            $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
            $ownerRightsSid = [Security.Principal.SecurityIdentifier]::new('S-1-3-4')
            $runnerSidObject = [Security.Principal.SecurityIdentifier]::new($UserSid)
            $trustedTaskSecurity.SetOwner($administratorSid)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            $runnerReadRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
                [Security.AccessControl.FileSystemRights]::Synchronize
            foreach ($principalSid in @($administratorSid, $systemSid)) {
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $principalSid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$trustedTaskSecurity.AddAccessRule($rule)
            }
            foreach ($principalSid in @($runnerSidObject, $ownerRightsSid)) {
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $principalSid,
                    $runnerReadRights,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$trustedTaskSecurity.AddAccessRule($rule)
            }
            function Assert-ProtectedTaskDirectory {
                param([Parameter(Mandatory)][string] $Path)
                $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                $acl = Get-Acl -LiteralPath $Path
                $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
                    [Security.Principal.SecurityIdentifier]
                ).Value
                $rules = @($acl.GetAccessRules(
                    $true, $true, [Security.Principal.SecurityIdentifier]
                ))
                if (-not $item.PSIsContainer -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $ownerSid -cne $administratorSid.Value -or
                    -not $acl.AreAccessRulesProtected -or $rules.Count -ne 4) {
                    throw 'Protected VM task directory owner or DACL differs from the observer contract.'
                }
                foreach ($principalSid in @($administratorSid, $systemSid)) {
                    $matches = @($rules | Where-Object {
                        $_.IdentityReference.Value -ceq $principalSid.Value -and
                        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                        [int]$_.FileSystemRights -eq 0x001f01ff -and
                        $_.InheritanceFlags -eq $inheritance -and
                        $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
                        -not $_.IsInherited
                    })
                    if ($matches.Count -ne 1) {
                        throw 'Protected VM task directory administrative access changed.'
                    }
                }
                foreach ($principalSid in @($runnerSidObject, $ownerRightsSid)) {
                    $matches = @($rules | Where-Object {
                        $_.IdentityReference.Value -ceq $principalSid.Value -and
                        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                        [int]$_.FileSystemRights -eq [int]$runnerReadRights -and
                        $_.InheritanceFlags -eq $inheritance -and
                        $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
                        -not $_.IsInherited
                    })
                    if ($matches.Count -ne 1) {
                        throw 'Protected VM task directory user read access changed.'
                    }
                }
            }
            if (-not (Test-Path -LiteralPath $trustedTaskRoot)) {
                [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $trustedTaskRoot)
            }
            Assert-ProtectedTaskDirectory -Path $trustedTaskRoot
            $taskRootItem = Get-Item -LiteralPath $trustedTaskRoot -Force -ErrorAction Stop
            $trustedObserverRoot = $trustedTaskRoot
            $trustedBundleRoot = Join-Path $trustedTaskRoot 'bundle'
            $guestRootFull = [IO.Path]::GetFullPath($GuestRoot).TrimEnd(
                [IO.Path]::DirectorySeparatorChar
            )
            $bundleSourceFull = [IO.Path]::GetFullPath($BundleSourcePath).TrimEnd(
                [IO.Path]::DirectorySeparatorChar
            )
            if ([string]::Equals(
                $bundleSourceFull,
                $guestRootFull,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                # The core runner and its verified tooling files resolve from the same directory.
                $trustedBundleRoot = $trustedTaskRoot
            }
            foreach ($directoryPath in @($trustedObserverRoot, $trustedBundleRoot)) {
                if (-not (Test-Path -LiteralPath $directoryPath)) {
                    [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $directoryPath)
                }
                $directoryItem = Get-Item -LiteralPath $directoryPath -Force -ErrorAction Stop
                if (-not $directoryItem.PSIsContainer -or
                    ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'A protected VM task input directory is unsafe.'
                }
                Assert-ProtectedTaskDirectory -Path $directoryPath
            }
            $trustedOutputRoot = Join-Path $trustedTaskRoot 'out'
            if (-not (Test-Path -LiteralPath $trustedOutputRoot)) {
                [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $trustedOutputRoot)
            }
            Assert-ProtectedTaskDirectory -Path $trustedOutputRoot
            $guestPrivateRoot = Join-Path $GuestRoot 'private'
            $trustedPrivateRoot = Join-Path $trustedOutputRoot 'private'
            $quotedGuestPrivateRoot = '"' + [IO.Path]::GetFullPath($guestPrivateRoot) + '"'
            $requiresPrivateRoot = $Arguments.IndexOf(
                $quotedGuestPrivateRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
            if ($requiresPrivateRoot) {
                if (-not (Test-Path -LiteralPath $trustedPrivateRoot)) {
                    [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $trustedPrivateRoot)
                }
                Assert-ProtectedTaskDirectory -Path $trustedPrivateRoot
            }
            elseif (Test-Path -LiteralPath $trustedPrivateRoot) {
                throw 'A task without private evidence must not inherit an unexpected private output directory.'
            }
            foreach ($outputLeaf in @($OutputDirectoryLeaves)) {
                if ($outputLeaf -cnotmatch '^recovery-acceptance-[0-9a-f]{32}$') {
                    throw 'A protected VM output subdirectory name is invalid.'
                }
                $outputDirectory = Join-Path $trustedOutputRoot $outputLeaf
                if (-not (Test-Path -LiteralPath $outputDirectory)) {
                    [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $outputDirectory)
                }
                Assert-ProtectedTaskDirectory -Path $outputDirectory
            }

            function Copy-VerifiedTrustedInput {
                param(
                    [Parameter(Mandatory)][string] $Source,
                    [Parameter(Mandatory)][string] $Destination,
                    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $Sha256,
                    [Parameter(Mandatory)][long] $Bytes,
                    [Parameter(Mandatory)][string] $Label
                )
                $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
                if ($sourceItem.PSIsContainer -or
                    ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $sourceItem.Length -ne $Bytes -or
                    (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ine $Sha256) {
                    throw "$Label source does not match its host-bound hash and size."
                }
                if (Test-Path -LiteralPath $Destination) {
                    $destinationItem = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
                    if ($destinationItem.PSIsContainer -or
                        ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                        $destinationItem.Length -ne $Bytes -or
                        (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $Sha256) {
                        throw "$Label protected copy changed or has an unexpected identity."
                    }
                    return
                }
                [void](Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop)
                $destinationItem = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
                if ($destinationItem.PSIsContainer -or
                    ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $destinationItem.Length -ne $Bytes -or
                    (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $Sha256) {
                    throw "$Label protected copy failed its hash and size check."
                }
            }

            function Assert-GuestInputPath {
                param([Parameter(Mandatory)][string] $Path,[Parameter(Mandatory)][string] $Root)
                $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
                $pathItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                $rootFull = $rootItem.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
                $pathFull = [IO.Path]::GetFullPath($Path)
                if (-not $rootItem.PSIsContainer -or
                    ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    ($pathItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    ($pathFull -cne $rootFull -and
                     -not $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar,
                        [StringComparison]::OrdinalIgnoreCase))) {
                    throw 'A VM task source path is outside the ordinary guest workspace.'
                }
                if ($pathFull -ceq $rootFull) { return }
                $cursor = if ($pathItem -is [IO.FileInfo]) {
                    $pathItem.Directory
                }
                else {
                    $pathItem.Parent
                }
                while ($null -ne $cursor -and
                    -not [string]::Equals($cursor.FullName, $rootItem.FullName, [StringComparison]::OrdinalIgnoreCase)) {
                    if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw 'A VM task source path traverses a reparse point.'
                    }
                    $cursor = $cursor.Parent
                }
                if ($null -eq $cursor) { throw 'A VM task source path is not beneath its workspace.' }
            }

            function Assert-TaskInputPath {
                param([Parameter(Mandatory)][string] $Path)
                $pathFull = [IO.Path]::GetFullPath($Path)
                $trustedRootFull = [IO.Path]::GetFullPath($trustedTaskRoot).TrimEnd(
                    [IO.Path]::DirectorySeparatorChar
                )
                if ($pathFull.StartsWith(
                    $trustedRootFull + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                    Assert-GuestInputPath -Path $Path -Root $trustedTaskRoot
                    $pathItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                    $cursor = if ($pathItem -is [IO.FileInfo]) {
                        $pathItem.Directory
                    }
                    else {
                        $pathItem
                    }
                    while ($null -ne $cursor) {
                        Assert-ProtectedTaskDirectory -Path $cursor.FullName
                        if ([string]::Equals(
                            $cursor.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar),
                            $trustedRootFull,
                            [StringComparison]::OrdinalIgnoreCase
                        )) { return }
                        $cursor = $cursor.Parent
                    }
                    throw 'A protected VM task input path escaped its task root.'
                }
                Assert-GuestInputPath -Path $Path -Root $GuestRoot
            }

            $expectedRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $guestRootFull 'runtime'))
            $runtimeRootFull = [IO.Path]::GetFullPath($RuntimeRoot)
            if (-not [string]::Equals(
                    $runtimeRootFull, $expectedRuntimeRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'The VM runtime root must be the controller-created guest runtime directory.'
            }
            Assert-TaskInputPath -Path $runtimeRootFull
            function Assert-ProtectedRuntimeDirectory {
                param([Parameter(Mandatory)][string] $Path)
                $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                $acl = Get-Acl -LiteralPath $Path
                $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
                    [Security.Principal.SecurityIdentifier]
                ).Value
                $rules = @($acl.GetAccessRules(
                    $true, $true, [Security.Principal.SecurityIdentifier]
                ))
                if (-not $item.PSIsContainer -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $ownerSid -cne $administratorSid.Value -or
                    -not $acl.AreAccessRulesProtected -or $rules.Count -ne 4) {
                    throw 'The controller-created VM runtime directory owner or DACL changed.'
                }
                foreach ($principalSid in @($administratorSid, $systemSid)) {
                    $matches = @($rules | Where-Object {
                        $_.IdentityReference.Value -ceq $principalSid.Value -and
                        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                        [int]$_.FileSystemRights -eq 0x001f01ff -and
                        $_.InheritanceFlags -eq $inheritance -and
                        $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
                        -not $_.IsInherited
                    })
                    if ($matches.Count -ne 1) {
                        throw 'The controller-created VM runtime administrative access changed.'
                    }
                }
                $runnerLocalMatches = @($rules | Where-Object {
                    $_.IdentityReference.Value -ceq $runnerSidObject.Value -and
                    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                    [int]$_.FileSystemRights -eq 0x001201bf -and
                    $_.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::None -and
                    $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
                    -not $_.IsInherited
                })
                $runnerChildMatches = @($rules | Where-Object {
                    $_.IdentityReference.Value -ceq $runnerSidObject.Value -and
                    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                    [int]$_.FileSystemRights -eq 0x001301bf -and
                    $_.InheritanceFlags -eq $inheritance -and
                    $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::InheritOnly -and
                    -not $_.IsInherited
                })
                if ($runnerLocalMatches.Count -ne 1 -or $runnerChildMatches.Count -ne 1) {
                    throw 'The controller-created VM runtime user write access changed.'
                }
            }
            Assert-ProtectedRuntimeDirectory -Path $runtimeRootFull

            $toolingManifestSource = Join-Path $GuestRoot 'tooling-bundle.json'
            Assert-GuestInputPath -Path $toolingManifestSource -Root $GuestRoot
            $toolingManifestItem = Get-Item -LiteralPath $toolingManifestSource -Force -ErrorAction Stop
            if ($toolingManifestItem.PSIsContainer -or
                ($toolingManifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                (Get-FileHash -LiteralPath $toolingManifestSource -Algorithm SHA256).Hash -ine
                    $global:DrVmToolingManifestSha256) {
                throw 'The VM tooling manifest changed before protected task staging.'
            }
            Copy-VerifiedTrustedInput `
                -Source $toolingManifestSource `
                -Destination (Join-Path $trustedObserverRoot 'tooling-bundle.json') `
                -Sha256 $global:DrVmToolingManifestSha256 `
                -Bytes $toolingManifestItem.Length `
                -Label 'VM tooling manifest'
            foreach ($record in @($global:DrVmToolingRecords)) {
                if ($record.file -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
                    $record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$record.bytes -lt 0) {
                    throw 'The verified VM tooling inventory contains an invalid file record.'
                }
                $source = Join-Path $GuestRoot $record.file
                Assert-GuestInputPath -Path $source -Root $GuestRoot
                Copy-VerifiedTrustedInput `
                    -Source $source `
                    -Destination (Join-Path $trustedObserverRoot $record.file) `
                    -Sha256 $record.sha256 `
                    -Bytes ([long]$record.bytes) `
                    -Label "VM tooling module $($record.role)"
            }

            Assert-TaskInputPath -Path $ObserverPath
            $observerItem = Get-Item -LiteralPath $ObserverPath -Force -ErrorAction Stop
            $bundleSourceFull = (Get-Item -LiteralPath $BundleSourcePath -Force -ErrorAction Stop).FullName.TrimEnd(
                [IO.Path]::DirectorySeparatorChar
            )
            $observerFull = $observerItem.FullName
            $trustedObserverPath = if ($observerFull.StartsWith(
                $bundleSourceFull + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Join-Path $trustedBundleRoot $observerItem.Name
            }
            else {
                Join-Path $trustedObserverRoot $observerItem.Name
            }
            Copy-VerifiedTrustedInput `
                -Source $ObserverPath `
                -Destination $trustedObserverPath `
                -Sha256 $ObserverSha256 `
                -Bytes $observerItem.Length `
                -Label 'VM observer script'

            Assert-TaskInputPath -Path $BundleSourcePath
            $bundleSource = Get-Item -LiteralPath $BundleSourcePath -Force -ErrorAction Stop
            if (-not $bundleSource.PSIsContainer -or
                ($bundleSource.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The VM candidate bundle source is not an ordinary directory.'
            }
            $seenBundleFiles = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($record in @($BundleRecords)) {
                if ($record.file -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
                    $record.file.Contains('..') -or
                    $record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                    [long]$record.bytes -lt 0 -or -not $seenBundleFiles.Add($record.file)) {
                    throw 'The host-bound VM candidate bundle inventory is invalid.'
                }
                $source = Join-Path $BundleSourcePath $record.file
                Assert-TaskInputPath -Path $source
                Copy-VerifiedTrustedInput `
                    -Source $source `
                    -Destination (Join-Path $trustedBundleRoot $record.file) `
                    -Sha256 $record.sha256 `
                    -Bytes ([long]$record.bytes) `
                    -Label "VM candidate bundle file $($record.file)"
            }
            if ($seenBundleFiles.Count -eq 0 -or -not $seenBundleFiles.Contains('bundle.json')) {
                throw 'The trusted VM candidate bundle must include its canonical manifest.'
            }

            $trustedInputManifest = $null
            if ($InputManifestPath) {
                if ($InputManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {
                    throw 'The VM input manifest host hash is invalid.'
                }
                Assert-TaskInputPath -Path $InputManifestPath
                $inputItem = Get-Item -LiteralPath $InputManifestPath -Force -ErrorAction Stop
                $trustedInputManifest = Join-Path $trustedTaskRoot 'input-manifest.json'
                Copy-VerifiedTrustedInput `
                    -Source $InputManifestPath `
                    -Destination $trustedInputManifest `
                    -Sha256 $InputManifestSha256 `
                    -Bytes $inputItem.Length `
                    -Label 'VM input manifest'
            }
            elseif ($InputManifestSha256) {
                throw 'A VM input manifest hash was supplied without its file.'
            }

            $resultPath = Join-Path $trustedOutputRoot $TrustedResultLeaf
            [DarkReNamerVmControllerWorkspace]::CreateResultFile($resultPath, $UserSid)
            function Set-QuotedVmTaskPath {
                param(
                    [Parameter(Mandatory)][string] $CurrentArguments,
                    [Parameter(Mandatory)][string] $SourcePath,
                    [Parameter(Mandatory)][string] $DestinationPath,
                    [switch] $Optional
                )
                $sourceArgument = '"' + [IO.Path]::GetFullPath($SourcePath) + '"'
                $destinationArgument = '"' + [IO.Path]::GetFullPath($DestinationPath) + '"'
                $first = $CurrentArguments.IndexOf($sourceArgument, [StringComparison]::OrdinalIgnoreCase)
                if ($first -lt 0) {
                    if ($Optional) { return $CurrentArguments }
                    throw 'A VM task path argument is missing or ambiguous.'
                }
                if ($CurrentArguments.IndexOf(
                        $sourceArgument,
                        $first + $sourceArgument.Length,
                        [StringComparison]::OrdinalIgnoreCase
                    ) -ge 0) {
                    throw 'A VM task path argument is missing or ambiguous.'
                }
                $CurrentArguments.Replace($sourceArgument, $destinationArgument)
            }
            $taskArguments = $Arguments
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $ObserverPath `
                -DestinationPath $trustedObserverPath
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $BundleSourcePath `
                -DestinationPath $trustedBundleRoot
            # This is the sole intentionally writable guest-workspace path; test processes create isolated temporary files beneath it.
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $RuntimeRoot `
                -DestinationPath $expectedRuntimeRoot
            $guestOutputRoot = Join-Path $GuestRoot 'out'
            if ($InputManifestPath) {
                $taskArguments = Set-QuotedVmTaskPath `
                    -CurrentArguments $taskArguments `
                    -SourcePath $InputManifestPath `
                    -DestinationPath $trustedInputManifest `
                    -Optional
            }
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $guestOutputRoot `
                -DestinationPath $trustedOutputRoot `
                -Optional
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $guestPrivateRoot `
                -DestinationPath $trustedPrivateRoot `
                -Optional
            $guestRootPrefix = $guestRootFull + [IO.Path]::DirectorySeparatorChar
            $mutableCandidates = @($ObserverPath,$BundleSourcePath,$guestOutputRoot,$guestPrivateRoot)
            if ($InputManifestPath) { $mutableCandidates += $InputManifestPath }
            $mutableArguments = @($mutableCandidates | Where-Object {
                $candidateFull = [IO.Path]::GetFullPath($_)
                $candidateFull -ceq $guestRootFull -or $candidateFull.StartsWith(
                    $guestRootPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
            })
            foreach ($mutablePath in $mutableArguments) {
                $quotedMutablePath = '"' + [IO.Path]::GetFullPath($mutablePath) + '"'
                if ($taskArguments.IndexOf($quotedMutablePath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    throw 'A VM task argument retained a mutable guest workspace path.'
                }
            }
            $trustedOutputArgument = '"' + [IO.Path]::GetFullPath($trustedOutputRoot) + '"'
            $trustedOutputIndex = $taskArguments.IndexOf(
                $trustedOutputArgument,
                [StringComparison]::OrdinalIgnoreCase
            )
            if ($trustedOutputIndex -lt 0 -or
                $taskArguments.IndexOf(
                    $trustedOutputArgument,
                    $trustedOutputIndex + $trustedOutputArgument.Length,
                    [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                throw 'A VM task must bind exactly one protected output root.'
            }
            $taskArguments += ' -ElevatedObserver -TrustedResultPath "' + $resultPath + '"'
            $trustedPowerShell = Get-DrVmTrustedPowerShellPath
            if (-not [string]::Equals(
                    [IO.Path]::GetFullPath($Execute), $trustedPowerShell,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The Windows VM task executable differs from the protected PowerShell engine.'
            }
            $descriptor = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x20089;;;' + $UserSid + ')(A;;0;;;OW)'
            $service = New-Object -ComObject Schedule.Service
            $service.Connect()
            $folder = $service.GetFolder('\')
            $definition = $service.NewTask(0)
            $definition.Settings.Enabled = $true
            $definition.Settings.ExecutionTimeLimit = [Xml.XmlConvert]::ToString(
                [TimeSpan]::FromSeconds($ExecutionTimeLimitSeconds)
            )
            $definition.Principal.UserId = $UserSid
            $definition.Principal.LogonType = 3
            $definition.Principal.RunLevel = 1
            $action = $definition.Actions.Create(0)
            $action.Path = $trustedPowerShell
            $action.Arguments = $taskArguments
            $action.WorkingDirectory = $trustedTaskRoot
            $registeredTask = $folder.RegisterTaskDefinition(
                $TaskName,
                $definition,
                0x12,
                $UserSid,
                $null,
                3,
                $descriptor
            )
            $actualDefinition = $registeredTask.Definition
            if ($actualDefinition.Actions.Count -ne 1) {
                throw 'The registered VM task action count changed.'
            }
            $actualAction = $actualDefinition.Actions.Item(1)
            if (-not [string]::Equals(
                    [string]$actualAction.Path, $trustedPowerShell,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                -not [string]::Equals(
                    [string]$actualAction.Arguments, $taskArguments,
                    [StringComparison]::Ordinal
                ) -or
                -not [string]::Equals(
                    [string]$actualAction.WorkingDirectory, $trustedTaskRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'The registered VM task action differs from the requested action.'
            }
            $actualPrincipal = $actualDefinition.Principal
            $actualPrincipalSid = if (
                [string]$actualPrincipal.UserId -cmatch '^S-1-\d+(?:-\d+)+$'
            ) {
                [Security.Principal.SecurityIdentifier]::new(
                    [string]$actualPrincipal.UserId
                )
            }
            else {
                [Security.Principal.NTAccount]::new(
                    [string]$actualPrincipal.UserId
                ).Translate(
                    [Security.Principal.SecurityIdentifier]
                )
            }
            if ($actualPrincipalSid.Value -cne $UserSid -or
                [int]$actualPrincipal.LogonType -ne 3 -or
                [int]$actualPrincipal.RunLevel -ne 1) {
                throw 'The registered VM observer principal, interactive logon, or elevated run level differs from the task contract.'
            }
            $actualExecutionLimit = [Xml.XmlConvert]::ToTimeSpan(
                [string]$actualDefinition.Settings.ExecutionTimeLimit
            )
            if ($actualExecutionLimit.Ticks -ne
                [TimeSpan]::FromSeconds($ExecutionTimeLimitSeconds).Ticks) {
                throw 'The registered VM task execution limit differs from the requested limit.'
            }
            $actualDescriptor = $registeredTask.GetSecurityDescriptor(0x7)
            $actual = [Security.AccessControl.RawSecurityDescriptor]::new($actualDescriptor)
            $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
            $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
            $ownerRightsSid = [Security.Principal.SecurityIdentifier]::new('S-1-3-4')
            if (($actual.ControlFlags -band
                    [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -eq 0 -or
                $actual.DiscretionaryAcl.Count -ne 4) {
                throw 'The registered VM task did not retain its protected DACL.'
            }
            foreach ($principalSid in @($administratorSid, $systemSid)) {
                $fullAces = @($actual.DiscretionaryAcl | Where-Object {
                    $_.AceType -eq [Security.AccessControl.AceType]::AccessAllowed -and
                    $_.SecurityIdentifier -eq $principalSid -and
                    $_.AccessMask -eq [int]0x001f01ff
                })
                if ($fullAces.Count -ne 1) {
                    throw 'The VM task administrative recovery rights are missing.'
                }
            }
            $runnerReadAces = @($actual.DiscretionaryAcl | Where-Object {
                $_.AceType -eq [Security.AccessControl.AceType]::AccessAllowed -and
                $_.SecurityIdentifier -eq $runnerSidObject -and $_.AccessMask -eq 0x00020089
            })
            if ($runnerReadAces.Count -ne 1) {
                throw 'The VM observer task query rights for the configured user are missing.'
            }
            $ownerRightsAces = @($actual.DiscretionaryAcl | Where-Object {
                $_.AceType -eq [Security.AccessControl.AceType]::AccessAllowed -and
                $_.SecurityIdentifier -eq $ownerRightsSid -and $_.AccessMask -eq 0
            })
            if ($ownerRightsAces.Count -ne 1 -or @($actual.DiscretionaryAcl | Where-Object {
                $_.AceType -ne [Security.AccessControl.AceType]::AccessAllowed
            }).Count -ne 0) {
                throw 'The VM task owner must have no implicit control and its DACL must contain only SYSTEM, Administrators, the configured read-only user grant, and owner-rights grants.'
            }
            $registeredTask
        }
        function global:New-DrVmGuestDirectory {
            param(
                [Parameter(Mandatory)][string] $ParentPath,
                [Parameter(Mandatory)][string] $Leaf,
                [Parameter(Mandatory)][string] $UserSid
            )
            if ($UserSid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$' -or
                $Leaf -cnotmatch '^(?:out|runtime|recovery-acceptance-[0-9a-f]{32})$') {
                throw 'The protected guest directory identity is invalid.'
            }
            $parent = Get-Item -LiteralPath $ParentPath -Force -ErrorAction Stop
            if (-not $parent.PSIsContainer -or
                ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The protected guest directory parent is unsafe.'
            }
            $path = Join-Path $parent.FullName $Leaf
            if (Test-Path -LiteralPath $path) {
                throw 'The protected guest directory already exists.'
            }
            $security = [Security.AccessControl.DirectorySecurity]::new()
            $security.SetAccessRuleProtection($true, $false)
            $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
            $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
            $runnerSid = [Security.Principal.SecurityIdentifier]::new($UserSid)
            $security.SetOwner($administratorSid)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            foreach ($principalSid in @($administratorSid, $systemSid)) {
                [void]$security.AddAccessRule(
                    [Security.AccessControl.FileSystemAccessRule]::new(
                        $principalSid,
                        [Security.AccessControl.FileSystemRights]::FullControl,
                        $inheritance,
                        [Security.AccessControl.PropagationFlags]::None,
                        [Security.AccessControl.AccessControlType]::Allow
                    )
                )
            }
            $localRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
                [Security.AccessControl.FileSystemRights]::WriteData -bor
                [Security.AccessControl.FileSystemRights]::AppendData -bor
                [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
                [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
            [void]$security.AddAccessRule(
                [Security.AccessControl.FileSystemAccessRule]::new(
                    $runnerSid,
                    $localRights,
                    [Security.AccessControl.AccessControlType]::Allow
                )
            )
            [void]$security.AddAccessRule(
                [Security.AccessControl.FileSystemAccessRule]::new(
                    $runnerSid,
                    [Security.AccessControl.FileSystemRights]::Modify,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::InheritOnly,
                    [Security.AccessControl.AccessControlType]::Allow
                )
            )
            [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $path)
            $path
        }
        function global:Get-DrVmRunnerTasks {
            param([Parameter(Mandatory)][string] $UserSid)

            if ($UserSid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$') {
                throw 'The task inventory principal SID is invalid.'
            }
            foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
                $userId = [string]$task.Principal.UserId
                $groupId = [string]$task.Principal.GroupId
                if ([string]::IsNullOrWhiteSpace($userId) -and
                    [string]::IsNullOrWhiteSpace($groupId)) {
                    throw 'A scheduled task principal is unavailable for the runner inventory.'
                }
                $userSid = $null
                if (-not [string]::IsNullOrWhiteSpace($userId)) {
                    try {
                        if ($userId -cmatch '^S-1-\d+(?:-\d+)+$') {
                            $userSid = [Security.Principal.SecurityIdentifier]::new($userId)
                        }
                        else {
                            $userSid = [Security.Principal.NTAccount]::new($userId).Translate(
                                [Security.Principal.SecurityIdentifier])
                        }
                    }
                    catch {
                        throw 'A scheduled task user principal could not be resolved for the runner inventory.'
                    }
                }
                # Group-principal tasks are retained in the baseline as potential
                # runner resources; their membership may differ in the desktop token.
                if ($userSid -and ($userSid.Value -ceq $UserSid -or
                    -not [string]::IsNullOrWhiteSpace($groupId))) {
                    $includeTask = $true
                }
                else {
                    $includeTask = -not [string]::IsNullOrWhiteSpace($groupId)
                }
                if ($includeTask) {
                    $xml = [string](@(Export-ScheduledTask `
                        -TaskName $task.TaskName `
                        -TaskPath $task.TaskPath `
                        -ErrorAction Stop) -join "`n")
                    $algorithm = [Security.Cryptography.SHA256]::Create()
                    try {
                        $definitionSha256 = ([BitConverter]::ToString(
                            $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($xml))
                        ) -replace '-', '').ToLowerInvariant()
                    }
                    finally { $algorithm.Dispose() }
                    [pscustomobject]@{
                        identity = [string]$task.TaskPath + [string]$task.TaskName
                        task_path = [string]$task.TaskPath
                        task_name = [string]$task.TaskName
                        definition_sha256 = $definitionSha256
                    }
                }
            }
        }
        function global:Get-DrVmRunnerProcesses {
            param(
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId
            )
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $rows = [Collections.Generic.List[object]]::new()
                $complete = $true
                $sessionProcesses = @()
                try {
                    $sessionProcesses = @(Get-CimInstance Win32_Process `
                        -Filter "SessionId=$SessionId" -OperationTimeoutSec 5 -ErrorAction Stop)
                }
                catch {
                    $complete = $false
                }
                foreach ($process in $sessionProcesses) {
                    $owner = $null
                    try {
                        $owner = Invoke-CimMethod -InputObject $process `
                            -MethodName GetOwnerSid -OperationTimeoutSec 5 -ErrorAction Stop
                    }
                    catch {
                        $complete = $false
                        continue
                    }
                    if ($owner.ReturnValue -ne 0) {
                        $complete = $false
                        continue
                    }
                    if ($owner.Sid -ceq $UserSid) {
                        $created = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o')
                        $rows.Add([pscustomobject]@{
                            identity = ([string]$process.ProcessId + '|' + $created)
                            pid = [int]$process.ProcessId
                            session_id = [int]$process.SessionId
                            creation_time_utc = $created
                            executable_path = [string]$process.ExecutablePath
                        })
                    }
                }
                $snapshot = [pscustomobject]@{
                    complete = $complete
                    processes = @($rows.ToArray() | Sort-Object identity)
                    attempts = $attempt
                }
                if ($complete) { return $snapshot }
                if ($attempt -lt 3) { Start-Sleep -Milliseconds 200 }
            }
            $snapshot
        }
        function global:Get-DrVmCommandLineArguments {
            param([Parameter(Mandatory)][string] $CommandLine)

            if ($CommandLine.Length -lt 1 -or $CommandLine.Length -gt 4096) {
                throw 'A process command line is unavailable or exceeds its bound.'
            }
            if ($null -eq ('DrVmCommandLineNative' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DrVmCommandLineNative {
    [DllImport("shell32.dll", EntryPoint = "CommandLineToArgvW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

    [DllImport("kernel32.dll", EntryPoint = "LocalFree", SetLastError = true)]
    public static extern IntPtr LocalFree(IntPtr memory);
}
'@ -ErrorAction Stop
            }
            $argumentCount = 0
            $argumentVector = [DrVmCommandLineNative]::CommandLineToArgvW(
                $CommandLine, [ref]$argumentCount)
            if ($argumentVector -eq [IntPtr]::Zero -or
                $argumentCount -lt 1 -or $argumentCount -gt 32) {
                if ($argumentVector -ne [IntPtr]::Zero) {
                    [void][DrVmCommandLineNative]::LocalFree($argumentVector)
                }
                throw 'A process command line could not be parsed within its bound.'
            }
            $arguments = [Collections.Generic.List[string]]::new()
            try {
                for ($index = 0; $index -lt $argumentCount; $index++) {
                    $argument = [Runtime.InteropServices.Marshal]::ReadIntPtr(
                        $argumentVector, $index * [IntPtr]::Size)
                    $arguments.Add([Runtime.InteropServices.Marshal]::PtrToStringUni($argument))
                }
            }
            finally { [void][DrVmCommandLineNative]::LocalFree($argumentVector) }
            return ,([string[]]$arguments.ToArray())
        }
        function global:Test-DrVmCanonicalSystemBinaryPath {
            param(
                [Parameter(Mandatory)][string] $Path,
                [Parameter(Mandatory)][ValidateSet('smartscreen.exe', 'svchost.exe')][string] $Leaf
            )

            try {
                $windowsDirectory = [IO.Path]::GetFullPath([string]$env:windir).TrimEnd('\')
                if ([string]::IsNullOrWhiteSpace($windowsDirectory) -or
                    -not [string]::Equals(
                        [IO.Path]::GetFullPath($Path),
                        (Join-Path (Join-Path $windowsDirectory 'System32') $Leaf),
                        [StringComparison]::OrdinalIgnoreCase)) {
                    return $false
                }
                $entryPaths = [Collections.Generic.List[string]]::new()
                $cursor = [IO.Path]::GetPathRoot($windowsDirectory)
                $entryPaths.Add($cursor)
                foreach ($segment in $windowsDirectory.Substring($cursor.Length).Split('\')) {
                    if ([string]::IsNullOrWhiteSpace($segment)) { return $false }
                    $cursor = Join-Path $cursor $segment
                    $entryPaths.Add($cursor)
                }
                $cursor = Join-Path $cursor 'System32'
                $entryPaths.Add($cursor)
                $systemBinaryPath = Join-Path $cursor $Leaf
                $entryPaths.Add($systemBinaryPath)
                foreach ($entryPath in $entryPaths) {
                    $entry = Get-Item -LiteralPath $entryPath -Force -ErrorAction Stop
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        return $false
                    }
                    if ($entryPath -ceq $systemBinaryPath) {
                        if ($entry.PSIsContainer) { return $false }
                    }
                    elseif (-not $entry.PSIsContainer) { return $false }
                }
                return $true
            }
            catch { return $false }
        }
        function global:Get-DrVmAuthenticodeEvidence {
            param([Parameter(Mandatory)][string] $Path)

            $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
            if ($null -eq $signature -or [string]$signature.Status -cne 'Valid' -or
                $null -eq $signature.SignerCertificate) {
                throw 'A broker executable does not have a valid Authenticode signature.'
            }
            [pscustomobject]@{
                status = [string]$signature.Status
                signer_subject = [string]$signature.SignerCertificate.Subject
                signer_thumbprint = ([string]$signature.SignerCertificate.Thumbprint).ToUpperInvariant()
            }
        }
        function global:Test-DrVmSmartScreenBrokerEvidence {
            param(
                [Parameter(Mandatory)][object] $Evidence,
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId,
                [Parameter(Mandatory)][string] $CandidateIdentity
            )

            try {
                $windowsDirectory = ([string]$Evidence.windows_directory).TrimEnd('\')
                $systemDirectory = $windowsDirectory + '\System32'
                $createdPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
                $publisherPattern = '^CN=Microsoft Windows(?: Publisher)?, O=Microsoft Corporation(?:,|$)'
                if ($Evidence.process_identity -cne $CandidateIdentity -or
                    $Evidence.process_pid -isnot [int] -or
                    $Evidence.process_session_id -ne $SessionId -or
                    [string]$Evidence.process_owner_sid -cne $UserSid -or
                    $Evidence.process_path_verified -isnot [bool] -or
                    -not $Evidence.process_path_verified -or
                    [string]$Evidence.process_executable_path -ine
                        ($systemDirectory + '\smartscreen.exe') -or
                    [string]$Evidence.process_signature_status -cne 'Valid' -or
                    [string]$Evidence.process_signer_subject -cnotmatch $publisherPattern -or
                    [string]$Evidence.process_signer_thumbprint -cnotmatch '^[0-9A-F]{40}$' -or
                    [string]$Evidence.process_creation_time_utc -cnotmatch $createdPattern -or
                    $CandidateIdentity -cne ([string]$Evidence.process_pid + '|' +
                        [string]$Evidence.process_creation_time_utc)) {
                    return $false
                }
                $processArguments = [string[]]$Evidence.process_command_line_arguments
                if ($processArguments.Count -ne 2 -or
                    $processArguments[0] -ine [string]$Evidence.process_executable_path -or
                    $processArguments[1] -ine '-Embedding') {
                    return $false
                }
                if ($Evidence.parent_pid -isnot [int] -or
                    $Evidence.parent_session_id -ne 0 -or
                    [string]$Evidence.parent_owner_sid -cne 'S-1-5-18' -or
                    $Evidence.parent_path_verified -isnot [bool] -or
                    -not $Evidence.parent_path_verified -or
                    [string]$Evidence.parent_executable_path -ine
                        ($systemDirectory + '\svchost.exe') -or
                    [string]$Evidence.parent_signature_status -cne 'Valid' -or
                    [string]$Evidence.parent_signer_subject -cnotmatch $publisherPattern -or
                    [string]$Evidence.parent_signer_thumbprint -cnotmatch '^[0-9A-F]{40}$' -or
                    [string]$Evidence.parent_creation_time_utc -cnotmatch $createdPattern -or
                    [string]$Evidence.parent_identity -cne ([string]$Evidence.parent_pid + '|' +
                        [string]$Evidence.parent_creation_time_utc) -or
                    [string]$Evidence.parent_creation_time_utc -cgt
                        [string]$Evidence.process_creation_time_utc -or
                    [string]$Evidence.service_name -cne 'DcomLaunch' -or
                    $Evidence.service_process_id -ne $Evidence.parent_pid -or
                    [string]$Evidence.service_state -cne 'Running') {
                    return $false
                }
                $parentArguments = [string[]]$Evidence.parent_command_line_arguments
                if ($parentArguments.Count -lt 3 -or $parentArguments.Count -gt 6 -or
                    $parentArguments[0] -ine [string]$Evidence.parent_executable_path -or
                    $parentArguments[1] -ine '-k' -or $parentArguments[2] -ine 'DcomLaunch') {
                    return $false
                }
                $parentTailValid = $parentArguments.Count -eq 3 -or
                    ($parentArguments.Count -eq 4 -and $parentArguments[3] -ieq '-p') -or
                    ($parentArguments.Count -eq 5 -and
                        $parentArguments[3] -ieq '-s' -and
                        $parentArguments[4] -ieq 'DcomLaunch') -or
                    ($parentArguments.Count -eq 6 -and
                        $parentArguments[3] -ieq '-s' -and
                        $parentArguments[4] -ieq 'DcomLaunch' -and
                        $parentArguments[5] -ieq '-p')
                if (-not $parentTailValid) {
                    return $false
                }
                return $true
            }
            catch { return $false }
        }
        function global:Get-DrVmSmartScreenBrokerEvidence {
            param(
                [Parameter(Mandatory)][object] $Candidate,
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId
            )

            $processId = [int]$Candidate.pid
            $matches = @(Get-CimInstance Win32_Process `
                -Filter "ProcessId=$processId" -OperationTimeoutSec 5 -ErrorAction Stop)
            if ($matches.Count -ne 1) {
                throw 'The SmartScreen candidate process is no longer uniquely observable.'
            }
            $process = $matches[0]
            $created = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o')
            $identity = [string]$process.ProcessId + '|' + $created
            $processPath = [string]$process.ExecutablePath
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid `
                -OperationTimeoutSec 5 -ErrorAction Stop
            $processPathVerified = Test-DrVmCanonicalSystemBinaryPath `
                -Path $processPath -Leaf 'smartscreen.exe'
            if ($identity -cne [string]$Candidate.identity -or
                [int]$process.SessionId -ne $SessionId -or
                [string]$owner.Sid -cne $UserSid -or
                $owner.ReturnValue -ne 0 -or
                -not $processPathVerified) {
                throw 'The SmartScreen candidate process identity did not match its runner delta.'
            }
            $processArguments = [string[]](Get-DrVmCommandLineArguments `
                -CommandLine ([string]$process.CommandLine))
            $processSignature = Get-DrVmAuthenticodeEvidence -Path $processPath

            $parentPid = [int]$process.ParentProcessId
            $parentMatches = @(Get-CimInstance Win32_Process `
                -Filter "ProcessId=$parentPid" -OperationTimeoutSec 5 -ErrorAction Stop)
            if ($parentMatches.Count -ne 1) {
                throw 'The SmartScreen parent process is not uniquely observable.'
            }
            $parent = $parentMatches[0]
            $parentCreated = ([datetime]$parent.CreationDate).ToUniversalTime().ToString('o')
            $parentIdentity = [string]$parent.ProcessId + '|' + $parentCreated
            $parentPath = [string]$parent.ExecutablePath
            $parentOwner = Invoke-CimMethod -InputObject $parent -MethodName GetOwnerSid `
                -OperationTimeoutSec 5 -ErrorAction Stop
            $parentPathVerified = Test-DrVmCanonicalSystemBinaryPath `
                -Path $parentPath -Leaf 'svchost.exe'
            if ($parentOwner.ReturnValue -ne 0 -or -not $parentPathVerified) {
                throw 'The SmartScreen parent identity is not a canonical Windows service host.'
            }
            $parentArguments = [string[]](Get-DrVmCommandLineArguments `
                -CommandLine ([string]$parent.CommandLine))
            $parentSignature = Get-DrVmAuthenticodeEvidence -Path $parentPath
            $services = @(Get-CimInstance Win32_Service `
                -Filter "ProcessId=$parentPid" -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object {
                    [string]$_.Name -ceq 'DcomLaunch' -and [string]$_.State -ceq 'Running'
                })
            if ($services.Count -ne 1) {
                throw 'The SmartScreen parent does not uniquely host the running DcomLaunch service.'
            }
            $evidence = [ordered]@{
                windows_directory = [IO.Path]::GetFullPath([string]$env:windir).TrimEnd('\')
                process_identity = $identity
                process_pid = [int]$process.ProcessId
                process_creation_time_utc = $created
                process_session_id = [int]$process.SessionId
                process_owner_sid = [string]$owner.Sid
                process_executable_path = $processPath
                process_path_verified = [bool]$processPathVerified
                process_command_line_arguments = @($processArguments)
                process_signature_status = $processSignature.status
                process_signer_subject = $processSignature.signer_subject
                process_signer_thumbprint = $processSignature.signer_thumbprint
                parent_identity = $parentIdentity
                parent_pid = [int]$parent.ProcessId
                parent_creation_time_utc = $parentCreated
                parent_session_id = [int]$parent.SessionId
                parent_owner_sid = [string]$parentOwner.Sid
                parent_executable_path = $parentPath
                parent_path_verified = [bool]$parentPathVerified
                parent_command_line_arguments = @($parentArguments)
                parent_signature_status = $parentSignature.status
                parent_signer_subject = $parentSignature.signer_subject
                parent_signer_thumbprint = $parentSignature.signer_thumbprint
                service_name = [string]$services[0].Name
                service_process_id = [int]$services[0].ProcessId
                service_state = [string]$services[0].State
            }
            if (-not (Test-DrVmSmartScreenBrokerEvidence `
                -Evidence $evidence `
                -UserSid $UserSid `
                -SessionId $SessionId `
                -CandidateIdentity ([string]$Candidate.identity))) {
                throw 'The SmartScreen process failed its exact broker identity contract.'
            }
            $evidence
        }
        function global:Wait-DrVmSmartScreenNaturalExit {
            param(
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $BaselineProcessIdentities,
                [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $BaselineTasks,
                [Parameter(Mandatory)][string] $CandidateIdentity,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $OwnedRootPrefixes,
                [Parameter(Mandatory)][ValidateRange(0, 360000)][int] $TimeoutMilliseconds
            )

            $baselineProcesses = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase)
            foreach ($identity in $BaselineProcessIdentities) {
                [void]$baselineProcesses.Add([string]$identity)
            }
            $baselineTaskHashes = @{}
            foreach ($task in $BaselineTasks) {
                $baselineTaskHashes[[string]$task.identity] = [string]$task.definition_sha256
            }
            $polls = [Collections.Generic.List[object]]::new()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $status = 'rejected'
            $finalInventoryComplete = $false
            $finalProcessIdentities = @()
            $finalTaskIdentities = @()
            $finalProcessSnapshot = $null
            $finalTaskRows = @()
            $polls.Add([ordered]@{
                elapsed_ms = 0
                inventory_complete = $true
                process_delta_identities = @($CandidateIdentity)
                task_delta_identities = @()
                owned_root_process_count = 0
            })
            while ($true) {
                $processSnapshot = $null
                $taskDelta = @()
                $processDeltaIdentities = @()
                $ownedRootProcesses = @()
                try {
                    $processSnapshot = Get-DrVmRunnerProcesses `
                        -UserSid $UserSid -SessionId $SessionId
                    if (-not $processSnapshot.complete) {
                        $status = 'inventory-failed'
                        break
                    }
                    $processDeltaIdentities = @($processSnapshot.processes |
                        Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                        Sort-Object identity | ForEach-Object { [string]$_.identity })
                    $taskRows = @(Get-DrVmRunnerTasks -UserSid $UserSid)
                    $currentTaskHashes = @{}
                    $taskDeltaIdentities = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase)
                    foreach ($task in $taskRows) {
                        $identity = [string]$task.identity
                        if ([string]::IsNullOrWhiteSpace($identity) -or
                            $currentTaskHashes.ContainsKey($identity)) {
                            throw 'The scheduled-task inventory contains an invalid or duplicate identity.'
                        }
                        $currentTaskHashes[$identity] = [string]$task.definition_sha256
                        if (-not $baselineTaskHashes.ContainsKey($identity) -or
                            $currentTaskHashes[$identity] -cne
                                [string]$baselineTaskHashes[$identity]) {
                            [void]$taskDeltaIdentities.Add($identity)
                        }
                    }
                    foreach ($identity in $baselineTaskHashes.Keys) {
                        if (-not $currentTaskHashes.ContainsKey([string]$identity)) {
                            [void]$taskDeltaIdentities.Add([string]$identity)
                        }
                    }
                    $taskDelta = @($taskDeltaIdentities | Sort-Object)
                    $allProcesses = @(Get-CimInstance Win32_Process `
                        -OperationTimeoutSec 5 -ErrorAction Stop)
                    $ownedRootProcesses = @($allProcesses | Where-Object {
                        Test-ProcessExecutableInOwnedRoots `
                            -Path $_.ExecutablePath -Prefixes $OwnedRootPrefixes
                    })
                }
                catch {
                    $status = 'inventory-failed'
                    break
                }
                $pollElapsed = [int][Math]::Min(
                    [int]::MaxValue, [Math]::Floor($watch.Elapsed.TotalMilliseconds))
                $polls.Add([ordered]@{
                    elapsed_ms = $pollElapsed
                    inventory_complete = $true
                    process_delta_identities = @($processDeltaIdentities)
                    task_delta_identities = @($taskDelta)
                    owned_root_process_count = [int]$ownedRootProcesses.Count
                })
                $finalInventoryComplete = $true
                $finalProcessIdentities = @($processDeltaIdentities)
                $finalTaskIdentities = @($taskDelta)
                $finalProcessSnapshot = $processSnapshot
                $finalTaskRows = @($taskRows)
                if ($watch.Elapsed.TotalMilliseconds -ge $TimeoutMilliseconds) {
                    $status = 'timed-out'
                    break
                }
                if ($taskDelta.Count -ne 0 -or $ownedRootProcesses.Count -ne 0 -or
                    $processDeltaIdentities.Count -gt 1 -or
                    ($processDeltaIdentities.Count -eq 1 -and
                        $processDeltaIdentities[0] -cne $CandidateIdentity)) {
                    $status = 'rejected'
                    break
                }
                if ($processDeltaIdentities.Count -eq 0) {
                    $status = 'natural-exit'
                    break
                }
                if ($watch.Elapsed.TotalMilliseconds -ge $TimeoutMilliseconds) {
                    $status = 'timed-out'
                    break
                }
                $remaining = $TimeoutMilliseconds - [int][Math]::Floor($watch.Elapsed.TotalMilliseconds)
                Start-Sleep -Milliseconds ([Math]::Min(1000, [Math]::Max(1, $remaining)))
            }
            $watch.Stop()
            [pscustomobject]@{
                status = $status
                timeout_ms = $TimeoutMilliseconds
                elapsed_ms = [int][Math]::Min(
                    [int]::MaxValue, [Math]::Floor($watch.Elapsed.TotalMilliseconds))
                polls = @($polls.ToArray())
                natural_exit_observed = ($status -ceq 'natural-exit')
                final_inventory_complete = $finalInventoryComplete
                final_runner_process_delta_identities = @($finalProcessIdentities)
                final_runner_task_delta_identities = @($finalTaskIdentities)
                final_process_snapshot = $finalProcessSnapshot
                final_task_rows = @($finalTaskRows)
            }
        }

        [pscustomobject]@{
            guest_root = $path
            trusted_task_root = Join-Path $base ($name + '-trusted')
        }
    }
    $guestRoot = [string]$workspaceRoots.guest_root
    $trustedTaskRoot = [string]$workspaceRoots.trusted_task_root
    $runnerTaskBaseline = @(Invoke-Command -Session $session -ArgumentList $desktop.sid -ScriptBlock {
        param($sid)
        @(Get-DrVmRunnerTasks -UserSid $sid | Sort-Object identity)
    })
    $transport['runner_task_baseline'] = @($runnerTaskBaseline)
    $processSnapshot = Invoke-Command -Session $session -ArgumentList $desktop.sid,$desktop.session_id -ScriptBlock {
        param($sid,$sessionId)
        Get-DrVmRunnerProcesses -UserSid $sid -SessionId $sessionId
    }
    if ($null -eq $processSnapshot -or -not $processSnapshot.complete) {
        throw 'The VM runner process baseline was incomplete; refusing to start an untrackable candidate.'
    }
    $runnerProcessBaseline = @($processSnapshot.processes)
    $transport['runner_process_baseline'] = @($runnerProcessBaseline)
    $toolingTransfer = New-ControllerToolingTransferStage -VerifiedTooling $VerifiedTooling
    Copy-Item `
        -LiteralPath (Join-Path $toolingTransfer.root 'tooling-bundle.json') `
        -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'tooling-bundle.json') `
        -ToSession $session
    foreach ($record in $toolingTransfer.records) {
        Copy-Item `
            -LiteralPath (Join-Path $toolingTransfer.root $record.file) `
            -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf $record.file) `
            -ToSession $session
    }
    $transferredTooling = Invoke-Command `
        -Session $session `
        -ArgumentList $guestRoot,$toolingTransfer.manifest_sha256,$toolingTransfer.records `
        -ScriptBlock {
            param($root,$manifestSha256,$records)
            $manifestPath = Join-Path $root 'tooling-bundle.json'
            if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ine
                $manifestSha256) {
                throw 'Transferred tooling manifest hash mismatch.'
            }
            foreach ($record in @($records)) {
                $path = Join-Path $root $record.file
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ($item.PSIsContainer -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $item.Length -ne [long]$record.bytes -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $record.sha256) {
                    throw "Transferred tooling module hash mismatch: $($record.role)."
                }
            }
            $global:DrVmToolingManifestSha256 = ([string]$manifestSha256).ToLowerInvariant()
            $global:DrVmToolingRecords = @($records | ForEach-Object {
                [pscustomobject]@{
                    role = [string]$_.role
                    file = [string]$_.file
                    sha256 = ([string]$_.sha256).ToLowerInvariant()
                    bytes = [long]$_.bytes
                }
            })
            [pscustomobject]@{
                manifest_sha256 = $manifestSha256
                records = @($records | ForEach-Object {
                    [ordered]@{
                        role = $_.role
                        file = $_.file
                        sha256 = $_.sha256
                        bytes = [long]$_.bytes
                    }
                })
            }
        }
    $transport['tooling'] = $transferredTooling
    $trustedBundleRecords = @(
        foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
            $path = Join-Path $BundleRoot $name
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "VM bundle input is not an ordinary file: $name."
            }
            [pscustomobject]@{
                file = [string]$name
                bytes = [long]$item.Length
                sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
    $transport.status = 'copying'
    if ($acceptance) {
        $acceptanceStage = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid -ScriptBlock {
            param($root,$sid)
            $bundle = Join-Path $root 'bundle'
            [void](New-Item -ItemType Directory -Path $bundle)
            $runtime = New-DrVmGuestDirectory -ParentPath $root -Leaf 'runtime' -UserSid $sid
            [pscustomobject]@{ bundle = $bundle; runtime = $runtime }
        }
        $guestBundleRoot = [string]$acceptanceStage.bundle
        $guestRuntimeRoot = [string]$acceptanceStage.runtime
        $inputManifestSha256 = (Get-FileHash -LiteralPath $AcceptanceManifest -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
            $guestPath = Join-GuestWindowsPath -Root $guestBundleRoot -Leaf $name
            Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination $guestPath -ToSession $session
        }
        Copy-Item -LiteralPath (Join-Path $BundleRoot 'windows-vm-acceptance.ps1') -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'windows-vm-acceptance.ps1') -ToSession $session
        Copy-Item -LiteralPath $AcceptanceManifest -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'input-manifest.json') -ToSession $session
        $acceptanceEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$observer.sha256,$AcceptanceMode,$AcceptanceAppearance,$AcceptanceTextScalePercent,([bool]$AcceptanceHighContrast),([bool]$AcceptanceClipboard),([bool]$AcceptanceCaptureNativeMenu),([bool]$AcceptanceCaptureAdvancedAppearance),$trustedBundleRecords,$inputManifestSha256 -ScriptBlock {
            param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$observerHash,$mode,$appearance,$textScale,$highContrast,$clipboard,$captureNativeMenu,$captureAdvancedAppearance,$bundleRecords,$inputManifestHash)
            $observerPath = Join-Path $root 'windows-vm-acceptance.ps1'
            if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) { throw 'Transferred acceptance observer hash mismatch.' }
            $bundle = Join-Path $root 'bundle'
            $out = Join-Path $root 'out'
            $runtime = Join-Path $root 'runtime'
            $inputManifest = Join-Path $root 'input-manifest.json'
            $powerShell = Get-DrVmTrustedPowerShellPath
            $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
                '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell acceptance engine.' }
            $engine = $engineJson | ConvertFrom-Json
            if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
                $engine.effective_policy -cne 'RemoteSigned') {
                throw 'GUI acceptance requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
            }
            $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -RuntimeRoot "' + $runtime + '" -ExpectedScriptSha256 ' + $observerHash + ' -TimeoutSeconds ' + $testTimeout + ' -Appearance ' + $appearance
            if ($mode -cne 'current-dpi') {
                $observerArguments += ' -RegressionMode ' + $mode + ' -InputManifestPath "' + $inputManifest + '" -TextScalePercent ' + $textScale
            }
            else {
                if ($highContrast) { $observerArguments += ' -HighContrast' }
                if ($clipboard) { $observerArguments += ' -Clipboard' }
                if ($captureNativeMenu) { $observerArguments += ' -CaptureNativeMenu' }
                if ($captureAdvancedAppearance) { $observerArguments += ' -CaptureAdvancedAppearance' }
            }
            Register-DrVmTask `
                -TaskName $name `
                -UserSid $sid `
                -SessionId $desktopSession `
                -GuestRoot $root `
                -RuntimeRoot $runtime `
                -ObserverPath $observerPath `
                -ObserverSha256 $observerHash `
                -BundleSourcePath $bundle `
                -BundleRecords $bundleRecords `
                -InputManifestPath $inputManifest `
                -InputManifestSha256 $inputManifestHash `
                -Execute $powerShell `
                -Arguments $observerArguments `
                -WorkingDirectory $root `
                -TrustedResultLeaf 'acceptance-result.json' `
                -ExecutionTimeLimitSeconds ($suiteTimeout + 60) | Out-Null
            $registered = Get-ScheduledTaskInfo -TaskName $name
            $registeredTicks = [long]$registered.LastRunTime.Ticks
            Start-ScheduledTask -TaskName $name
            [pscustomobject]@{
                executable = 'pwsh.exe'
                version = [string]$engine.version
                edition = [string]$engine.edition
                effective_policy = [string]$engine.effective_policy
                registered_last_run_time_ticks = $registeredTicks
            }
        }
        $transport.acceptance_engine = [ordered]@{
            executable = [string]$acceptanceEngine.executable
            version = [string]$acceptanceEngine.version
            edition = [string]$acceptanceEngine.edition
            effective_policy = [string]$acceptanceEngine.effective_policy
        }
        $transport.status = 'running'
        $deadline = (Get-Date).AddSeconds($SuiteTimeoutSeconds)
        $state = [pscustomobject]@{result_status=$null;task_state='starting';task_result=$null}
        $pollFailure = $null
        try {
            do {
                Start-Sleep -Seconds 5
                $state = Invoke-Command -Session $session -ArgumentList $trustedTaskRoot,$taskName -ScriptBlock {
                    param($trustedRoot,$name)
                    $info = Get-ScheduledTaskInfo -TaskName $name
                    $task = Get-ScheduledTask -TaskName $name
                    $taskState = $task.State.ToString()
                    $taskResult = [long]$info.LastTaskResult
                    if ($taskState -ceq 'Ready') {
                        $terminalInfo = Get-ScheduledTaskInfo -TaskName $name
                        $taskResult = [long]$terminalInfo.LastTaskResult
                    }
            $file = Join-Path (Join-Path $trustedRoot 'out') 'acceptance-result.json'
                    $resultStatus = $null
                    if (Test-Path -LiteralPath $file) {
                        try {
                            $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                            $resultStatus = [string]$data.status
                        } catch {}
                    }
                    [pscustomobject]@{
                        result_status = $resultStatus
                        task_state = $taskState
                        task_result = $taskResult
                        last_run_time_ticks = [long]$info.LastRunTime.Ticks
                    }
                }
                $state = Resolve-ObserverTaskPollState `
                    -ResultStatus $state.result_status `
                    -TaskState $state.task_state `
                    -TaskResult $state.task_result `
                    -RegisteredLastRunTimeTicks $acceptanceEngine.registered_last_run_time_ticks `
                    -LastRunTimeTicks $state.last_run_time_ticks
                if ($state.terminal) { break }
            } while ((Get-Date) -lt $deadline)
        }
        catch { $pollFailure = $_ }
        if ($null -eq $pollFailure -and ($null -eq $state -or -not $state.terminal)) {
            $pollFailure = [InvalidOperationException]::new('GUI acceptance timed out before the scheduled task reached its terminal state.')
        }
        if ($null -eq $pollFailure -and
            $state.result_status -notin @('review_required', 'failed', 'environment_blocked', 'unsupported', 'not_run')) {
            $pollFailure = [InvalidOperationException]::new('Acceptance task reached terminal state without a bounded result document.')
        }
        if ($null -eq $pollFailure -and $state.terminal) {
            $observerProcess = [ordered]@{
                state = 'exited'
                exit_code = [long]$state.task_result
            }
            $transport.observer_process = $observerProcess
            if ($state.task_result -ne 0) {
                $transport.observer_error = 'The acceptance observer task returned a nonzero terminal result.'
            }
        }
        if ($null -ne $pollFailure) {
            $transport.observer_error = 'The acceptance observer did not return a valid terminal result; inspect transport-error.txt.'
            Invoke-AcceptancePollFailureRescue `
                -Session $session `
                -GuestRoot $guestRoot `
                -DesktopSid $desktop.sid `
                -DesktopSessionId $desktop.session_id `
                -TaskName $taskName `
                -TestTimeoutSeconds $TestTimeoutSeconds `
                -SuiteTimeoutSeconds $SuiteTimeoutSeconds `
                -ObserverSha256 $observer.sha256 `
                -BundleRecords $trustedBundleRecords `
                -InputManifestSha256 $inputManifestSha256 `
                -AcceptanceMode $AcceptanceMode `
                -Appearance $AcceptanceAppearance `
                -HighContrast ([bool]$AcceptanceHighContrast) `
                -HostOutputRoot $AcceptanceOutputRoot `
                -OriginalFailure $pollFailure
        }
        if ($AcceptanceMode -ceq 'text-scale' -and
            ($state.result_status -cne 'review_required' -or $state.task_result -ne 0)) {
            Invoke-AcceptanceTextScaleRescue `
                -Session $session `
                -GuestRoot $guestRoot `
                -DesktopSid $desktop.sid `
                -DesktopSessionId $desktop.session_id `
                -TaskName $taskName `
                -TestTimeoutSeconds $TestTimeoutSeconds `
                -SuiteTimeoutSeconds $SuiteTimeoutSeconds `
                -ObserverSha256 $observer.sha256 `
                -BundleRecords $trustedBundleRecords `
                -InputManifestSha256 $inputManifestSha256 `
                -Appearance $AcceptanceAppearance `
                -HostOutputRoot $AcceptanceOutputRoot
        }
        if ($AcceptanceHighContrast -and
            ($state.result_status -cne 'review_required' -or $state.task_result -ne 0)) {
            Invoke-AcceptanceHighContrastRescue `
                -Session $session `
                -GuestRoot $guestRoot `
                -DesktopSid $desktop.sid `
                -DesktopSessionId $desktop.session_id `
                -TaskName $taskName `
                -TestTimeoutSeconds $TestTimeoutSeconds `
                -SuiteTimeoutSeconds $SuiteTimeoutSeconds `
                -ObserverSha256 $observer.sha256 `
                -BundleRecords $trustedBundleRecords `
                -HostOutputRoot $AcceptanceOutputRoot
        }
        $inventory = @(Invoke-Command -Session $session -ArgumentList $guestRoot,$trustedTaskRoot -ScriptBlock {
            param($root,$trustedRoot)
            $out = Join-Path $trustedRoot 'out'
            $rows = @(
                Get-ChildItem -LiteralPath $out -File -Force |
                    Where-Object { $_.Name -notin @('acceptance-result.json','platform-postlaunch.json') }
            )
            $trustedResult = Join-Path $out 'acceptance-result.json'
            if (Test-Path -LiteralPath $trustedResult -PathType Leaf) {
                $rows += Get-Item -LiteralPath $trustedResult -Force
            }
            if ($rows.Count -gt 128) { throw 'Acceptance output file count exceeds its bound.' }
            $total = [long]0
            foreach ($row in $rows) {
                if (($row.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $row.Length -gt 128MB) { throw 'Acceptance output contains an unsafe file.' }
                $total += $row.Length
                if ($total -gt 512MB) {
                    throw 'Acceptance output exceeds its aggregate size bound.'
                }
                [pscustomobject]@{file=$row.Name;guest_path=$row.FullName;bytes=$row.Length;sha256=(Get-FileHash -LiteralPath $row.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
            }
        })
        foreach ($output in $inventory) {
            Assert-PlainFile $output.file
            $guestOutputPath = [string]$output.guest_path
            $hostOutputPath = Join-Path $AcceptanceOutputRoot $output.file
            if (Test-Path -LiteralPath $hostOutputPath) {
                $existing = Get-Item -LiteralPath $hostOutputPath -Force -ErrorAction Stop
                if ($existing.PSIsContainer -or
                    ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $existing.Length -ne $output.bytes -or
                    (Get-FileHash -LiteralPath $hostOutputPath -Algorithm SHA256).Hash -ine $output.sha256) {
                    throw 'Acceptance output path already exists on the host with different bytes.'
                }
                continue
            }
            Copy-Item -LiteralPath $guestOutputPath -Destination $hostOutputPath -FromSession $session
            if ((Get-Item -LiteralPath $hostOutputPath).Length -ne $output.bytes -or
                (Get-FileHash -LiteralPath $hostOutputPath -Algorithm SHA256).Hash -ine $output.sha256) {
                throw 'Collected acceptance output hash mismatch.'
            }
        }
        $acceptanceResultPath = Join-Path $AcceptanceOutputRoot 'acceptance-result.json'
        $result = if (Test-Path -LiteralPath $acceptanceResultPath -PathType Leaf) {
            Get-Content -LiteralPath $acceptanceResultPath -Raw | ConvertFrom-Json
        } else { $null }
        if ($null -ne $result) {
            Assert-ObserverResultBinding `
                -Result $result `
                -Manifest $manifest `
                -Role ui `
                -ExpectedObserverSha256 $observer.sha256
            $processJobsClosed = Test-DrControllerProcessJobCleanupLedger -Result $result
        }
        if ($null -ne $result -and $result.status -ceq 'review_required' -and
            $null -eq $pollFailure -and $state.task_result -eq 0) {
            $observationsPath = Join-Path $AcceptanceOutputRoot 'acceptance-observations.json'
            if (-not (Test-Path -LiteralPath $observationsPath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $observationsPath -Algorithm SHA256).Hash -ine
                    $result.observations.sha256) {
                throw 'Collected GUI observations do not match the protected observer result digest.'
            }
            $collectedObservations = Get-Content -LiteralPath $observationsPath -Raw | ConvertFrom-Json
            $trustedObservationJson = $result.acceptance_observations | ConvertTo-Json -Depth 12 -Compress
            $collectedObservationJson = $collectedObservations | ConvertTo-Json -Depth 12 -Compress
            if ($trustedObservationJson -cne $collectedObservationJson) {
                throw 'Collected GUI observations differ from the protected observer result object.'
            }
            $window = $result.acceptance_observations.environment.main_window
            if ($null -eq $window -or [long]$window.hwnd -le 0 -or
                [int]$window.process_id -le 0) {
                throw 'Protected acceptance observations do not identify the launched application window.'
            }
            $actualGuestId = Invoke-Command -Session $session -ScriptBlock {
                ([guid](Get-ItemProperty `
                    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' `
                    -Name VirtualMachineId).VirtualMachineId).ToString('D').ToLowerInvariant()
            }
            $expectedGuestId = ([guid]$ExpectedGuestVmId).ToString('D').ToLowerInvariant()
            if ($actualGuestId -cne $expectedGuestId) {
                throw 'Post-launch Hyper-V Guest Parameters VM identity differs from the private profile.'
            }
            $identityHash = Get-LowerTextSha256 -Value $actualGuestId
            $receipt = [ordered]@{
                schema_version = 1
                run_id = $acceptanceInput.run_id
                input_manifest_sha256 = $inputManifestSha256
                phase = 'post-launch'
                vm_identity_kind = 'hyper-v-guest-parameters-virtual-machine-id-v1'
                vm_identity_sha256 = $identityHash
                target = [ordered]@{
                    hwnd = [long]$window.hwnd
                    process_id = [int]$window.process_id
                    window_rect = $window.rect
                }
                identity_observation = [ordered]@{
                    source = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters::VirtualMachineId'
                    session = 'controller-pssession'
                    target_process_id = [int]$window.process_id
                }
            }
            $receiptPath = Join-Path $AcceptanceOutputRoot 'platform-postlaunch.json'
            if (Test-Path -LiteralPath $receiptPath) {
                throw 'Host post-launch receipt path already exists.'
            }
            [IO.File]::WriteAllText(
                $receiptPath,
                ($receipt | ConvertTo-Json -Depth 6),
                [Text.UTF8Encoding]::new($false)
            )
        }
        $acceptancePassed = $null -ne $result -and
            $result.status -ceq 'review_required' -and
            $processJobsClosed -and
            $null -eq $pollFailure -and
            $null -ne $observerProcess -and
            $observerProcess.state -ceq 'exited' -and
            $observerProcess.exit_code -eq 0
        $transport.status = 'collected'
    }
    elseif ($recovery) {
        $recoveryStage = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$taskName -ScriptBlock {
            param($root,$sid,$name)
            $bundle = Join-Path $root 'bundle'
            $runtime = New-DrVmGuestDirectory -ParentPath $root -Leaf 'runtime' -UserSid $sid
            $trustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
            $out = Join-Path $trustedRoot 'out'
            $evidenceLeaf = 'recovery-acceptance-' + [Guid]::NewGuid().ToString('N')
            $evidenceRoot = Join-Path $out $evidenceLeaf
            $private = Join-Path $root 'private'
            [void](New-Item -ItemType Directory -Path $bundle)
            [pscustomobject]@{
                bundle = $bundle
                evidence_root = $evidenceRoot
                evidence_leaf = $evidenceLeaf
                runtime = $runtime
            }
        }
        $guestBundleRoot = [string]$recoveryStage.bundle
        $recoveryEvidenceRoot = [string]$recoveryStage.evidence_root
        $recoveryRuntimeRoot = [string]$recoveryStage.runtime
        foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
            $guestPath = Join-GuestWindowsPath -Root $guestBundleRoot -Leaf $name
            Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination $guestPath -ToSession $session
        }
        Copy-Item `
            -LiteralPath (Join-Path $BundleRoot 'windows-vm-recovery-acceptance.ps1') `
            -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'windows-vm-recovery-acceptance.ps1') `
            -ToSession $session
        $recoveryEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$observer.sha256,$RecoveryMode,$RecoveryFixtureCount,([bool]$RecoveryExport),([bool]$RecoveryIntentOnlyCandidateDiscard),$recoveryEvidenceRoot,$trustedBundleRecords,$recoveryRuntimeRoot -ScriptBlock {
            param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$observerHash,$mode,$fixtureCount,$recoveryExport,$intentOnlyCandidateDiscard,$evidenceRoot,$bundleRecords,$runtimeRoot)
            $observerPath = Join-Path $root 'windows-vm-recovery-acceptance.ps1'
            if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) {
                throw 'Transferred recovery observer hash mismatch.'
            }
            $bundle = Join-Path $root 'bundle'
            $out = Join-Path $root 'out'
            $private = Join-Path $root 'private'
            $powerShell = Get-DrVmTrustedPowerShellPath
            $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
                '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell recovery engine.' }
            $engine = $engineJson | ConvertFrom-Json
            if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
                $engine.effective_policy -cne 'RemoteSigned') {
                throw 'Recovery acceptance requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
            }
            $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -EvidenceRoot "' + $evidenceRoot + '" -PrivateEvidenceRoot "' + $private + '" -RuntimeRoot "' + $runtimeRoot + '" -ExpectedScriptSha256 ' + $observerHash + ' -Mode ' + $mode + ' -FixtureCount ' + $fixtureCount + ' -TimeoutSeconds ' + $testTimeout
            if ($recoveryExport) { $observerArguments += ' -RecoveryExport' }
            if ($intentOnlyCandidateDiscard) {
                $observerArguments += ' -IntentOnlyCandidateDiscard'
            }
            Register-DrVmTask `
                -TaskName $name `
                -UserSid $sid `
                -SessionId $desktopSession `
                -GuestRoot $root `
                -RuntimeRoot $runtimeRoot `
                -ObserverPath $observerPath `
                -ObserverSha256 $observerHash `
                -BundleSourcePath $bundle `
                -BundleRecords $bundleRecords `
                -Execute $powerShell `
                -Arguments $observerArguments `
                -WorkingDirectory $root `
                -TrustedResultLeaf 'recovery-summary.json' `
                -OutputDirectoryLeaves @([string](Split-Path -Leaf $evidenceRoot)) `
                -ExecutionTimeLimitSeconds ($suiteTimeout + 60) | Out-Null
            $registered = Get-ScheduledTaskInfo -TaskName $name
            $registeredTicks = [long]$registered.LastRunTime.Ticks
            Start-ScheduledTask -TaskName $name
            [pscustomobject]@{
                executable = 'pwsh.exe'
                version = [string]$engine.version
                edition = [string]$engine.edition
                effective_policy = [string]$engine.effective_policy
                registered_last_run_time_ticks = $registeredTicks
            }
        }
        $transport.recovery_engine = [ordered]@{
            executable = [string]$recoveryEngine.executable
            version = [string]$recoveryEngine.version
            edition = [string]$recoveryEngine.edition
            effective_policy = [string]$recoveryEngine.effective_policy
        }
        $transport.status = 'running'
        $deadline = (Get-Date).AddSeconds($SuiteTimeoutSeconds)
        $state = [pscustomobject]@{result_status=$null;task_state='starting';task_result=$null}
        $pollFailure = $null
        try {
            do {
                Start-Sleep -Seconds 5
                $state = Invoke-Command -Session $session -ArgumentList $trustedTaskRoot,$taskName -ScriptBlock {
                    param($trustedRoot,$name)
                    $info = Get-ScheduledTaskInfo -TaskName $name
                    $task = Get-ScheduledTask -TaskName $name
                    $taskState = $task.State.ToString()
                    $taskResult = [long]$info.LastTaskResult
                    if ($taskState -ceq 'Ready') {
                        $terminalInfo = Get-ScheduledTaskInfo -TaskName $name
                        $taskResult = [long]$terminalInfo.LastTaskResult
                    }
                    $summaries = @(
                        Get-Item -LiteralPath (Join-Path (Join-Path $trustedRoot 'out') 'recovery-summary.json') `
                            -Force `
                            -ErrorAction SilentlyContinue |
                            Where-Object {
                                -not $_.PSIsContainer -and
                                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
                            }
                    )
                    $resultStatus = $null
                    if ($summaries.Count -eq 1) {
                        try {
                            $data = Get-Content -LiteralPath $summaries[0].FullName -Raw | ConvertFrom-Json
                            $resultStatus = [string]$data.status
                        } catch {}
                    }
                    [pscustomobject]@{
                        result_status = $resultStatus
                        task_state = $taskState
                        task_result = $taskResult
                        last_run_time_ticks = [long]$info.LastRunTime.Ticks
                    }
                }
                $state = Resolve-ObserverTaskPollState `
                    -ResultStatus $state.result_status `
                    -TaskState $state.task_state `
                    -TaskResult $state.task_result `
                    -RegisteredLastRunTimeTicks $recoveryEngine.registered_last_run_time_ticks `
                    -LastRunTimeTicks $state.last_run_time_ticks
                if ($state.terminal) { break }
            } while ((Get-Date) -lt $deadline)
        }
        catch { $pollFailure = $_ }
        if ($null -eq $pollFailure -and ($null -eq $state -or -not $state.terminal)) {
            $pollFailure = [InvalidOperationException]::new('Recovery acceptance timed out before the scheduled task reached its terminal state.')
        }
        if ($null -eq $pollFailure -and $state.result_status -notin @('passed', 'failed')) {
            $pollFailure = [InvalidOperationException]::new('Recovery task reached terminal state without one bounded result document.')
        }
        if ($null -eq $pollFailure -and $state.terminal) {
            $observerProcess = [ordered]@{
                state = 'exited'
                exit_code = [long]$state.task_result
            }
            $transport.observer_process = $observerProcess
            if ($state.task_result -ne 0) {
                $transport.observer_error = 'The recovery observer task returned a nonzero terminal result.'
            }
        }
        if ($null -ne $pollFailure) {
            $transport.observer_error = 'The recovery observer did not return a valid terminal result; inspect transport-error.txt.'
            throw $pollFailure
        }
        $inventory = @(Invoke-Command -Session $session -ArgumentList $guestRoot,$trustedTaskRoot,$recoveryEvidenceRoot -ScriptBlock {
            param($root,$trustedRoot,$recoveryEvidenceRootPath)
            $out = Join-Path $trustedRoot 'out'
            $evidenceLeaf = Split-Path -Leaf $recoveryEvidenceRootPath
            $trustedSummary = Join-Path $out 'recovery-summary.json'
            $evidenceRoots = @(
                [pscustomobject]@{ item = Get-Item -LiteralPath $recoveryEvidenceRootPath -Force; prefix = $evidenceLeaf + '/' },
                [pscustomobject]@{ item = Get-Item -LiteralPath (Join-Path $out 'private') -Force; prefix = 'private/' }
            )
            $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
            $rows = [Collections.Generic.List[object]]::new()
            $directoryCount = 0
            foreach ($rootRecord in $evidenceRoots) {
                if (($rootRecord.item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Recovery evidence root became a reparse point.'
                }
                $pending.Push($rootRecord.item)
                while ($pending.Count -gt 0) {
                    $directory = $pending.Pop()
                    foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
                        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                            throw 'Recovery output contains a reparse entry.'
                        }
                        if ($item.PSIsContainer) {
                            $directoryCount++
                            if ($directoryCount -gt 32) {
                                throw 'Recovery output directory count exceeds its bound.'
                            }
                            $pending.Push($item)
                        }
                        else {
                            $relative = $item.FullName.Substring($rootRecord.item.FullName.Length + 1).Replace('\', '/')
                            $file = $rootRecord.prefix + $relative
                            if ($file -cne ($evidenceLeaf + '/summary.json')) {
                                $rows.Add([pscustomobject]@{
                                    item = $item
                                    file = $file
                                    guest_path = $item.FullName
                                })
                            }
                            if ($rows.Count -gt 256) {
                                throw 'Recovery output file count exceeds its bound.'
                            }
                        }
                    }
                }
            }
            if (Test-Path -LiteralPath $trustedSummary -PathType Leaf) {
                $summaryItem = Get-Item -LiteralPath $trustedSummary -Force
                $rows.Add([pscustomobject]@{
                    item = $summaryItem
                    file = $evidenceLeaf + '/summary.json'
                    guest_path = $trustedSummary
                })
            }
            $total = [long]0
            foreach ($row in $rows) {
                if (($row.item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $row.item.Length -gt 128MB) {
                    throw 'Recovery output contains an unsafe file.'
                }
                $total += $row.item.Length
                if ($total -gt 512MB) {
                    throw 'Recovery output exceeds its aggregate size bound.'
                }
                [pscustomobject]@{
                    file = $row.file
                    guest_path = $row.guest_path
                    bytes = $row.item.Length
                    sha256 = (Get-FileHash -LiteralPath $row.item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        })
        $summaryRows = @($inventory | Where-Object { $_.file -cmatch '(^|/)summary\.json$' })
        if ($summaryRows.Count -ne 1 -or
            $summaryRows[0].file -cnotmatch '^[^/]+/summary\.json$') {
            throw 'Recovery output must contain exactly one session summary.'
        }
        foreach ($output in $inventory) {
            $segments = @(Get-SafeEvidencePathSegments $output.file)
            $guestOutputPath = [string]$output.guest_path
            $hostOutputPath = $RecoveryOutputRoot
            foreach ($segment in $segments) {
                $hostOutputPath = Join-Path $hostOutputPath $segment
            }
            $hostParent = Split-Path -Parent $hostOutputPath
            if (-not (Test-Path -LiteralPath $hostParent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $hostParent)
            }
            Assert-PathWithoutReparse $hostParent
            if (Test-Path -LiteralPath $hostOutputPath) {
                throw 'Recovery output collides with an already collected path.'
            }
            Copy-Item -LiteralPath $guestOutputPath -Destination $hostOutputPath -FromSession $session
            if ((Get-Item -LiteralPath $hostOutputPath).Length -ne $output.bytes -or
                (Get-FileHash -LiteralPath $hostOutputPath -Algorithm SHA256).Hash -ine
                    $output.sha256) {
                throw 'Collected recovery output hash mismatch.'
            }
        }
        $summaryPath = $RecoveryOutputRoot
        foreach ($segment in @(Get-SafeEvidencePathSegments $summaryRows[0].file)) {
            $summaryPath = Join-Path $summaryPath $segment
        }
        $result = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        Assert-ObserverResultBinding `
            -Result $result `
            -Manifest $manifest `
            -Role recovery `
            -ExpectedObserverSha256 $observer.sha256
        $processJobsClosed = Test-DrControllerProcessJobCleanupLedger `
            -Result $result -RecoveryEvidenceRoot $RecoveryOutputRoot
        $recoveryInventory = [ordered]@{
            schema_version = 1
            task_kind = 'recovery'
            observer_role = 'recovery'
            bundle_manifest_sha256 = (Get-FileHash `
                -LiteralPath (Join-Path $BundleRoot 'bundle.json') `
                -Algorithm SHA256).Hash.ToLowerInvariant()
            observer = [ordered]@{
                file = $observer.file
                sha256 = $observer.sha256
            }
            summary_file = $summaryRows[0].file
            files = @($inventory | Sort-Object file | ForEach-Object {
                [ordered]@{
                    file = $_.file
                    bytes = [long]$_.bytes
                    sha256 = $_.sha256
                }
            })
        }
        [IO.File]::WriteAllText(
            (Join-Path $RecoveryOutputRoot 'recovery-inventory.json'),
            ($recoveryInventory | ConvertTo-Json -Depth 6),
            [Text.UTF8Encoding]::new($false)
        )
        $acceptancePassed = $result.status -ceq 'passed' -and
            $processJobsClosed -and
            $null -eq $pollFailure -and
            $null -ne $observerProcess -and
            $observerProcess.state -ceq 'exited' -and
            $observerProcess.exit_code -eq 0
        $transport.status = 'collected'
    }
    else {
    $guestRuntimeRoot = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid -ScriptBlock {
        param($root,$sid)
        New-DrVmGuestDirectory -ParentPath $root -Leaf 'runtime' -UserSid $sid
    }
    foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
        $guestPath = Join-GuestWindowsPath -Root $guestRoot -Leaf $name
        Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination $guestPath -ToSession $session
    }
    if ($candidateLane) {
        Invoke-Command -Session $session -ArgumentList $guestRoot,$manifest.product.application.file,$manifest.product.application.sha256 -ScriptBlock {
            param($root,$applicationFile,$applicationHash)
            $path = Join-Path $root $applicationFile
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $applicationHash) {
                throw 'Transferred candidate executable hash mismatch.'
            }
            $signature = Get-AuthenticodeSignature -FilePath $path
            if ($signature.Status -ne 'NotSigned') {
                throw "Candidate Authenticode status differs from the current unsigned policy: $($signature.Status)."
            }
        }
    }
    $runnerArtifact = if ($candidateLane) { $manifest.harness.runner } else { $manifest.runner }
    $runnerEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$runnerArtifact.sha256,$trustedBundleRecords,$guestRuntimeRoot -ScriptBlock {
        param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$runnerHash,$bundleRecords,$runtimeRoot)
        $runner = Join-Path $root 'windows-vm-guest.ps1'
        if ((Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash -ine $runnerHash) { throw 'Transferred guest runner hash mismatch.' }
        $powerShell = Get-DrVmTrustedPowerShellPath
        $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
            '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell guest engine.' }
        $engine = $engineJson | ConvertFrom-Json
        if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
            $engine.effective_policy -cne 'RemoteSigned') {
            throw 'Native VM validation requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
        }
        $expectedRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $root 'runtime'))
        if (-not [string]::Equals(
                [IO.Path]::GetFullPath($runtimeRoot), $expectedRuntimeRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'The VM runtime root differs from the controller-created guest runtime directory.'
        }
        $runtimeRoot = $expectedRuntimeRoot
        $trustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
        $out = Join-Path $trustedRoot 'out'
        $arguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $runner + '" -BundleRoot "' + $root + '" -ExpectedSessionId ' + $desktopSession + ' -TestTimeoutSeconds ' + $testTimeout + ' -OutputRoot "' + $out + '" -RuntimeRoot "' + $runtimeRoot + '"'
        Register-DrVmTask `
            -TaskName $name `
            -UserSid $sid `
            -SessionId $desktopSession `
            -GuestRoot $root `
            -RuntimeRoot $runtimeRoot `
            -ObserverPath $runner `
            -ObserverSha256 $runnerHash `
            -BundleSourcePath $root `
            -BundleRecords $bundleRecords `
            -Execute $powerShell `
            -Arguments $arguments `
            -WorkingDirectory $root `
            -TrustedResultLeaf 'core-result.json' `
            -ExecutionTimeLimitSeconds ($suiteTimeout + 60) | Out-Null
        $registered = Get-ScheduledTaskInfo -TaskName $name
        $registeredLastRunTimeTicks = [long]$registered.LastRunTime.Ticks
        Start-ScheduledTask -TaskName $name
        [pscustomobject]@{
            executable = $powerShell
            version = [string]$engine.version
            edition = [string]$engine.edition
            effective_policy = [string]$engine.effective_policy
            registered_last_run_time_ticks = $registeredLastRunTimeTicks
        }
    }
    $transport.runner_engine = [ordered]@{
        executable = [string]$runnerEngine.executable
        version = [string]$runnerEngine.version
        edition = [string]$runnerEngine.edition
        effective_policy = [string]$runnerEngine.effective_policy
    }
    $transport.status = 'running'
    $deadline = (Get-Date).AddSeconds($SuiteTimeoutSeconds)
    $lastProgress = ''
    $registeredLastRunTimeTicks = [long]$runnerEngine.registered_last_run_time_ticks
    do {
        Start-Sleep -Seconds 5
        $polledState = Invoke-Command -Session $session -ArgumentList $trustedTaskRoot,$taskName,$coreResultMaximumBytes,$registeredLastRunTimeTicks -ScriptBlock {
            param($trustedRoot,$name,$maximumResultBytes,$registeredRunTicks)
            $task = Get-ScheduledTask -TaskName $name
            $taskState = $task.State.ToString()
            $info = Get-ScheduledTaskInfo -TaskName $name
            $lastRunTimeTicks = [long]$info.LastRunTime.Ticks
            if ($taskState -ceq 'Ready') {
                $info = Get-ScheduledTaskInfo -TaskName $name
                $lastRunTimeTicks = [long]$info.LastRunTime.Ticks
            }
            $taskCompleted = $taskState -ceq 'Ready' -and
                $lastRunTimeTicks -gt [long]$registeredRunTicks
            if (-not $taskCompleted) {
                return [pscustomobject]@{
                    result_status = $null
                    count = 0
                    task_state = $taskState
                    task_result = [long]$info.LastTaskResult
                    last_run_time_ticks = $lastRunTimeTicks
                }
            }
            $file = Join-Path (Join-Path $trustedRoot 'out') 'core-result.json'
            $resultStatus = $null
            $resultCount = 0
            if (Test-Path -LiteralPath $file) {
                $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
                if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $item.Length -lt 1 -or $item.Length -gt $maximumResultBytes) {
                    throw 'Guest result exceeds its polling size bound.'
                }
                try {
                    $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                    $resultStatus = [string]$data.status
                    $resultCount = @($data.tests).Count
                } catch {}
            }
            [pscustomobject]@{
                result_status = $resultStatus
                count = $resultCount
                task_state = $taskState
                task_result = [long]$info.LastTaskResult
                last_run_time_ticks = $lastRunTimeTicks
            }
        }
        $pollState = Resolve-ObserverTaskPollState `
            -ResultStatus $polledState.result_status `
            -TaskState $polledState.task_state `
            -TaskResult $polledState.task_result `
            -RegisteredLastRunTimeTicks $registeredLastRunTimeTicks `
            -LastRunTimeTicks $polledState.last_run_time_ticks
        $status = if ($pollState.terminal) { $pollState.result_status } else { $pollState.task_state }
        $state = [pscustomobject]@{
            status = $status
            count = [int]$polledState.count
            task_result = $pollState.task_result
        }
        $progress = [string]$state.status + ':' + $state.count
        if ($progress -ne $lastProgress) { Write-Host ('VM tests: ' + $progress); $lastProgress = $progress }
        if ($pollState.terminal) {
            if ($pollState.result_status -notin @('passed','failed')) {
                if ($pollState.task_result -ne 0) {
                    throw ('Guest test task failed before producing results: ' + $pollState.task_result)
                }
                throw 'Guest test task reached its terminal state without a bounded result document.'
            }
            if ($pollState.result_status -ceq 'passed' -and $pollState.task_result -ne 0) {
                throw 'Guest test task reported a pass with a nonzero task result.'
            }
            break
        }
        if ($state.status -eq 'Ready' -and $state.task_result -ne 0) { throw ('Guest test task failed before producing results: ' + $state.task_result) }
    } while ((Get-Date) -lt $deadline)
    if ($state.status -notin @('passed','failed')) { throw 'VM test suite timed out.' }
    $trustedOutputRoot = Join-GuestWindowsPath -Root $trustedTaskRoot -Leaf 'out'
    $guestResultPath = Join-GuestWindowsPath -Root $trustedOutputRoot -Leaf 'core-result.json'
    $guestResultBytes = Invoke-Command -Session $session -ArgumentList $guestResultPath -ScriptBlock {
        param($path)
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Guest result is not an ordinary file.'
        }
        [long]$item.Length
    }
    if ($guestResultBytes -lt 1 -or $guestResultBytes -gt $coreResultMaximumBytes) {
        throw 'Guest result exceeds its size bound.'
    }
    Copy-Item -LiteralPath $guestResultPath -Destination (Join-Path $BundleRoot 'result.json') -FromSession $session
    if ((Get-Item -LiteralPath (Join-Path $BundleRoot 'result.json')).Length -ne $guestResultBytes) {
        throw 'Collected guest result size mismatch.'
    }
    $result = Get-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Raw | ConvertFrom-Json
    if (-not (Test-DrControllerProcessJobCleanupLedger -Result $result -AllowEmpty) -or
        @($result.tests | Where-Object { $_.job_cleanup -isnot [bool] -or -not $_.job_cleanup }).Count -ne 0 -or
        $result.gui.job_cleanup -isnot [bool] -or -not $result.gui.job_cleanup) {
        throw 'Guest process jobs were not empty and closed before result collection.'
    }
    $processJobsClosed = $true
    $outputs = @()
    $testOutputBytes = [long]0
    foreach ($row in $result.tests) {
        foreach ($channel in @('stdout','stderr')) {
            if ($row.$channel) {
                $recordedBytes = $row.$channel.bytes
                if ($recordedBytes -isnot [long] -and $recordedBytes -isnot [int]) {
                    throw 'Guest test output has no exact byte count.'
                }
                $recordedBytes = [long]$recordedBytes
                if ($recordedBytes -lt 0 -or $recordedBytes -gt $coreTestChannelMaximumBytes -or
                    $testOutputBytes -gt ($coreTestOutputAggregateMaximumBytes - $recordedBytes)) {
                    throw 'Guest test output exceeds its collection bound.'
                }
                $testOutputBytes += $recordedBytes
                $outputs += $row.$channel
            }
        }
    }
    if ($result.gui -and $result.gui.PSObject.Properties.Name -contains 'screenshot' -and $result.gui.screenshot) { $outputs += $result.gui.screenshot }
    if ($result.gui -and $result.gui.flow -and $result.gui.flow.screenshots) {
        $outputs += @($result.gui.flow.screenshots)
    }
    if ($result.gui -and $result.gui.flow -and $result.gui.flow.diagnostic) {
        $outputs += $result.gui.flow.diagnostic
    }
    $failureDiagnostics = @(Get-CoreGuiFailureDiagnosticOutputs -Gui $result.gui)
    if (($outputs.Count + $failureDiagnostics.Count) -gt 256) {
        throw 'Guest output reference count exceeds its bound.'
    }
    $collectedOutputNames = @{}
    $remoteOutputSizes = @{}
    $collectionBytes = [long]0
    foreach ($output in $outputs) {
        Assert-PlainFile $output.file
        if ($collectedOutputNames.ContainsKey($output.file)) {
            throw 'Guest output contains a duplicate file reference.'
        }
        if ($names.ContainsKey($output.file) -or $output.file -in @('bundle.json','result.json','transport.json','run-windows-vm-tests.ps1')) { throw 'Guest output collides with a bundle input.' }
        $collectedOutputNames[$output.file] = $true
        $guestOutputPath = Join-GuestWindowsPath -Root $trustedOutputRoot -Leaf $output.file
        $remoteBytes = Invoke-Command -Session $session -ArgumentList $guestOutputPath -ScriptBlock {
            param($path)
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Guest output is not an ordinary file.'
            }
            [long]$item.Length
        }
        $fileMaximum = if ($output.PSObject.Properties.Name -contains 'bytes') {
            if ([long]$output.bytes -ne $remoteBytes) {
                throw 'Guest output differs from its recorded byte count.'
            }
            $coreTestChannelMaximumBytes
        } else { $coreOutputFileMaximumBytes }
        if ($remoteBytes -lt 0 -or $remoteBytes -gt $fileMaximum -or
            $collectionBytes -gt ($coreOutputAggregateMaximumBytes - $remoteBytes)) {
            throw 'Guest output exceeds its host collection bound.'
        }
        $collectionBytes += $remoteBytes
        $remoteOutputSizes[$output.file] = $remoteBytes
    }
    foreach ($diagnosticOutput in $failureDiagnostics) {
        Assert-PlainFile $diagnosticOutput.file
        if ($collectedOutputNames.ContainsKey($diagnosticOutput.file) -or
            $names.ContainsKey($diagnosticOutput.file) -or
            $diagnosticOutput.file -in @(
                'bundle.json','result.json','transport.json','run-windows-vm-tests.ps1'
            )) {
            throw 'Guest failure diagnostic collides with another output or bundle input.'
        }
        $collectedOutputNames[$diagnosticOutput.file] = $true
        $guestDiagnosticPath = Join-GuestWindowsPath -Root $trustedOutputRoot -Leaf $diagnosticOutput.file
        $remoteBytes = Invoke-Command -Session $session -ArgumentList $guestDiagnosticPath -ScriptBlock {
            param($path)
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Guest failure diagnostic is not an ordinary file.'
            }
            [long]$item.Length
        }
        if ([long]$diagnosticOutput.bytes -ne $remoteBytes -or
            $remoteBytes -lt 0 -or $remoteBytes -gt $coreOutputFileMaximumBytes -or
            $collectionBytes -gt ($coreOutputAggregateMaximumBytes - $remoteBytes)) {
            throw 'Guest failure diagnostic exceeds its host collection bound.'
        }
        $collectionBytes += $remoteBytes
        $remoteOutputSizes[$diagnosticOutput.file] = $remoteBytes
    }
    foreach ($output in $outputs) {
        $guestOutputPath = Join-GuestWindowsPath -Root $trustedOutputRoot -Leaf $output.file
        Copy-Item -LiteralPath $guestOutputPath -Destination (Join-Path $BundleRoot $output.file) -FromSession $session
        $hostOutputPath = Join-Path $BundleRoot $output.file
        if ((Get-Item -LiteralPath $hostOutputPath).Length -ne $remoteOutputSizes[$output.file] -or
            (Get-FileHash -LiteralPath $hostOutputPath -Algorithm SHA256).Hash -ine $output.sha256) {
            throw 'Collected guest output hash or size mismatch.'
        }
    }
    foreach ($diagnosticOutput in $failureDiagnostics) {
        $guestDiagnosticPath = Join-GuestWindowsPath `
            -Root $trustedOutputRoot `
            -Leaf $diagnosticOutput.file
        $hostDiagnosticPath = Join-Path $BundleRoot $diagnosticOutput.file
        if (Test-Path -LiteralPath $hostDiagnosticPath) {
            throw 'Guest failure diagnostic collides with an existing host path.'
        }
        Copy-Item `
            -LiteralPath $guestDiagnosticPath `
            -Destination $hostDiagnosticPath `
            -FromSession $session
        if ((Get-Item -LiteralPath $hostDiagnosticPath).Length -ne $remoteOutputSizes[$diagnosticOutput.file] -or
            (Get-FileHash -LiteralPath $hostDiagnosticPath -Algorithm SHA256).Hash -ine
                $diagnosticOutput.sha256) {
            throw 'Collected guest failure diagnostic hash or size mismatch.'
        }
    }
    $transport.status = 'collected'
    }
} catch {
    $transport.status = 'failed'
    $transport.error = 'VM transport failed; inspect transport-error.txt.'
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'transport-error.txt') -Encoding UTF8
} finally {
    $toolingCleanupError = Remove-ControllerToolingTransferStage -Transfer $toolingTransfer
    if ($null -ne $toolingCleanupError) {
        $transport.status = 'failed'
        $transport['tooling_cleanup_error'] = $toolingCleanupError
    }
    if ($session) {
        try {
            Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {
                param($name)
                $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                if ($task) { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $name -Confirm:$false }
            }
            if ($guestRoot) {
                $cleanupAuthorized = $transport.status -eq 'collected' -and
                    (-not $observerTask -or $acceptancePassed)
                $requiredProcessJobsClosed = $processJobsClosed
                $cleanupTaskContext = [pscustomobject]@{
                    runner_sid = [string]$desktop.sid
                    baseline_tasks = @($runnerTaskBaseline)
                    runner_session_id = [int]$desktop.session_id
                    baseline_process_identities = @(
                        $runnerProcessBaseline | ForEach-Object identity
                    )
                }
                $cleanupResult = Invoke-Command -Session $session -ArgumentList $guestRoot,$trustedTaskRoot,$taskName,$cleanupAuthorized,$requiredProcessJobsClosed,$cleanupTaskContext -ScriptBlock {
                    param($root,$trustedRoot,$name,$mayDelete,$jobsClosed,$taskContext)
                    $expectedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') $name
                    $expectedTrustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
                    if ($name -cnotmatch '^DarkReNamerTests-[0-9a-f]{32}$' -or
                        $root -cne $expectedRoot -or $trustedRoot -cne $expectedTrustedRoot) {
                        throw 'Unexpected VM cleanup root.'
                    }
                    $prefixes = @($root.TrimEnd('\') + '\', $trustedRoot.TrimEnd('\') + '\')
                    function Test-ProcessExecutableInOwnedRoots {
                        param([AllowNull()][string] $Path,[Parameter(Mandatory)][string[]] $Prefixes)
                        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
                        foreach ($candidatePrefix in $Prefixes) {
                            if ($Path.StartsWith($candidatePrefix,[StringComparison]::OrdinalIgnoreCase)) {
                                return $true
                            }
                        }
                        return $false
                    }
                    $baselineTasks = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase
                    )
                    $baselineTaskHashes = @{}
                    foreach ($task in @($taskContext.baseline_tasks)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$task.identity)) {
                            [void]$baselineTasks.Add([string]$task.identity)
                            $baselineTaskHashes[[string]$task.identity] = [string]$task.definition_sha256
                        }
                    }
                    $baselineProcesses = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase
                    )
                    foreach ($identity in @($taskContext.baseline_process_identities)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$identity)) {
                            [void]$baselineProcesses.Add([string]$identity)
                        }
                    }
                    $removedRunnerTasks = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase)
                    $runnerTasksBeforeCleanup = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                    $unexpectedRunnerTasksBeforeCleanup = @($runnerTasksBeforeCleanup |
                        Where-Object {
                            -not $baselineTasks.Contains([string]$_.identity) -or
                            [string]$_.definition_sha256 -cne [string]$baselineTaskHashes[[string]$_.identity]
                        } |
                        Sort-Object identity)
                    $runnerTaskIdentitiesBeforeCleanup = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase)
                    foreach ($task in $runnerTasksBeforeCleanup) {
                        [void]$runnerTaskIdentitiesBeforeCleanup.Add([string]$task.identity)
                    }
                    foreach ($identity in $baselineTasks) {
                        if (-not $runnerTaskIdentitiesBeforeCleanup.Contains([string]$identity)) {
                            [void]$removedRunnerTasks.Add([string]$identity)
                        }
                    }
                    $processSnapshotBeforeCleanup = Get-DrVmRunnerProcesses `
                        -UserSid $taskContext.runner_sid `
                        -SessionId $taskContext.runner_session_id
                    $unexpectedRunnerProcessesBeforeCleanup = @($processSnapshotBeforeCleanup.processes |
                        Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                        Sort-Object identity)
                    $terminatedRunnerProcesses = [Collections.Generic.List[object]]::new()
                    $cleanupResourceErrors = [Collections.Generic.List[string]]::new()
                    $ownedRootProcessCandidates = @(Get-CimInstance Win32_Process `
                        -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object {
                        Test-ProcessExecutableInOwnedRoots -Path $_.ExecutablePath -Prefixes $prefixes
                    } | Sort-Object ProcessId)
                    $smartScreenNaturalExit = [ordered]@{
                        schema_version = 1
                        status = 'rejected'
                        runner_sid = [string]$taskContext.runner_sid
                        runner_session_id = [int]$taskContext.runner_session_id
                        candidate_identity = $null
                        broker = $null
                        timeout_ms = 0
                        elapsed_ms = 0
                        polls = @()
                        natural_exit_observed = $false
                        final_inventory_complete = $false
                        final_runner_process_delta_identities = @()
                        final_runner_task_delta_identities = @()
                    }
                    if ($processSnapshotBeforeCleanup.complete -and
                        $unexpectedRunnerTasksBeforeCleanup.Count -eq 0 -and
                        $removedRunnerTasks.Count -eq 0 -and
                        $unexpectedRunnerProcessesBeforeCleanup.Count -eq 0) {
                        $smartScreenNaturalExit.status = 'not-required'
                        $smartScreenNaturalExit.final_inventory_complete = $true
                    }
                    elseif ($mayDelete -and $jobsClosed -and
                        $processSnapshotBeforeCleanup.complete -and
                        $unexpectedRunnerTasksBeforeCleanup.Count -eq 0 -and
                        $removedRunnerTasks.Count -eq 0 -and
                        $unexpectedRunnerProcessesBeforeCleanup.Count -eq 1 -and
                        $ownedRootProcessCandidates.Count -eq 0) {
                        $candidate = $unexpectedRunnerProcessesBeforeCleanup[0]
                        $smartScreenNaturalExit.candidate_identity = [string]$candidate.identity
                        try {
                            $smartScreenNaturalExit.broker = Get-DrVmSmartScreenBrokerEvidence `
                                -Candidate $candidate `
                                -UserSid $taskContext.runner_sid `
                                -SessionId $taskContext.runner_session_id
                            $smartScreenNaturalExit.status = 'pending'
                            $smartScreenNaturalExit.timeout_ms = 360000
                        }
                        catch {
                            $smartScreenNaturalExit.status = 'classification-failed'
                        }
                    }
                    if ($smartScreenNaturalExit.status -ceq 'rejected') {
                        $smartScreenNaturalExit.final_runner_process_delta_identities = @(
                            $unexpectedRunnerProcessesBeforeCleanup | ForEach-Object { [string]$_.identity })
                        $smartScreenNaturalExit.final_runner_task_delta_identities = @(
                            $unexpectedRunnerTasksBeforeCleanup | ForEach-Object { [string]$_.identity })
                    }
                    foreach ($candidateProcess in $ownedRootProcessCandidates) {
                        $owned = $null
                        $terminationRecord = $null
                        try {
                            $owned = Get-Process -Id $candidateProcess.ProcessId -ErrorAction SilentlyContinue
                            if (-not $owned) { continue }
                            $actualPath = [string]$owned.MainModule.FileName
                            if (-not (Test-ProcessExecutableInOwnedRoots -Path $actualPath -Prefixes $prefixes)) {
                                continue
                            }
                            $createdUtc = ([datetime]$candidateProcess.CreationDate).ToUniversalTime().ToString('o')
                            $identity = [string]$candidateProcess.ProcessId + '|' + $createdUtc
                            $terminationRecord = [ordered]@{
                                identity = $identity
                                pid = [int]$candidateProcess.ProcessId
                                session_id = [int]$candidateProcess.SessionId
                                executable_path = $actualPath
                                termination_requested = $false
                                exit_observed = $false
                                error = $null
                            }
                            $terminatedRunnerProcesses.Add($terminationRecord)
                            $owned.Kill()
                            $terminationRecord.termination_requested = $true
                            $exited = $owned.WaitForExit(10000)
                            $terminationRecord.exit_observed = [bool]$exited
                            if (-not $exited) {
                                $cleanupResourceErrors.Add('An owned test process did not exit after termination.')
                            }
                        }
                        catch {
                            if ($null -ne $terminationRecord) {
                                $terminationRecord.error = 'An owned test process could not be recorded or terminated.'
                            }
                            $cleanupResourceErrors.Add('An owned test process could not be recorded or terminated.')
                        }
                        finally {
                            if ($null -ne $owned) { $owned.Dispose() }
                        }
                    }
                    # Same-user process and task deltas can include unrelated desktop
                    # work. Detect them and retain the VM root for inspection; only
                    # terminate processes whose executable is inside this exact run root.
                    $processSnapshotAfterIntervention = Get-DrVmRunnerProcesses `
                        -UserSid $taskContext.runner_sid `
                        -SessionId $taskContext.runner_session_id
                    $unexpectedRunnerProcessesAfterIntervention = @($processSnapshotAfterIntervention.processes |
                        Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                        Sort-Object identity)
                    $runnerTasksAfterIntervention = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                    $unexpectedRunnerTasksAfterIntervention = @($runnerTasksAfterIntervention |
                        Where-Object {
                            -not $baselineTasks.Contains([string]$_.identity) -or
                            [string]$_.definition_sha256 -cne [string]$baselineTaskHashes[[string]$_.identity]
                        } |
                        Sort-Object identity)
                    $runnerTaskIdentitiesAfterIntervention = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase)
                    foreach ($task in $runnerTasksAfterIntervention) {
                        [void]$runnerTaskIdentitiesAfterIntervention.Add([string]$task.identity)
                    }
                    foreach ($identity in $baselineTasks) {
                        if (-not $runnerTaskIdentitiesAfterIntervention.Contains([string]$identity)) {
                            [void]$removedRunnerTasks.Add([string]$identity)
                        }
                    }
                    $ownedScheduledTasksBeforeDelete = @(Get-ScheduledTask -ErrorAction Stop |
                        Where-Object {
                            [string]$_.TaskName -ceq $name -and [string]$_.TaskPath -ceq '\'
                        })
                    $taskPresentBeforeDelete = $ownedScheduledTasksBeforeDelete.Count -gt 0
                    if ($smartScreenNaturalExit.status -ceq 'pending') {
                        if ($mayDelete -and $jobsClosed -and -not $taskPresentBeforeDelete -and
                            $processSnapshotAfterIntervention.complete -and
                            $unexpectedRunnerTasksAfterIntervention.Count -eq 0 -and
                            $unexpectedRunnerProcessesAfterIntervention.Count -le 1 -and
                            ($unexpectedRunnerProcessesAfterIntervention.Count -eq 0 -or
                                [string]$unexpectedRunnerProcessesAfterIntervention[0].identity -ceq
                                    [string]$smartScreenNaturalExit.candidate_identity) -and
                            $ownedRootProcessCandidates.Count -eq 0 -and
                            $removedRunnerTasks.Count -eq 0 -and
                            $terminatedRunnerProcesses.Count -eq 0 -and
                            $cleanupResourceErrors.Count -eq 0) {
                            $waitResult = Wait-DrVmSmartScreenNaturalExit `
                                -UserSid $taskContext.runner_sid `
                                -SessionId $taskContext.runner_session_id `
                                -BaselineProcessIdentities @($taskContext.baseline_process_identities) `
                                -BaselineTasks @($taskContext.baseline_tasks) `
                                -CandidateIdentity ([string]$smartScreenNaturalExit.candidate_identity) `
                                -OwnedRootPrefixes $prefixes `
                                -TimeoutMilliseconds 360000
                            $smartScreenNaturalExit.status = [string]$waitResult.status
                            $smartScreenNaturalExit.elapsed_ms = [int]$waitResult.elapsed_ms
                            $smartScreenNaturalExit.polls = @($waitResult.polls)
                            $smartScreenNaturalExit.natural_exit_observed = [bool]$waitResult.natural_exit_observed
                            $smartScreenNaturalExit.final_inventory_complete = [bool]$waitResult.final_inventory_complete
                            $smartScreenNaturalExit.final_runner_process_delta_identities = @(
                                $waitResult.final_runner_process_delta_identities)
                            $smartScreenNaturalExit.final_runner_task_delta_identities = @(
                                $waitResult.final_runner_task_delta_identities)
                            if ($waitResult.final_inventory_complete -and
                                $null -ne $waitResult.final_process_snapshot) {
                                $processSnapshotAfterIntervention = $waitResult.final_process_snapshot
                                $unexpectedRunnerProcessesAfterIntervention = @(
                                    $processSnapshotAfterIntervention.processes |
                                        Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                                        Sort-Object identity)
                                $finalTaskRows = @($waitResult.final_task_rows)
                                $unexpectedRunnerTasksAfterIntervention = @($finalTaskRows | Where-Object {
                                    -not $baselineTasks.Contains([string]$_.identity) -or
                                    [string]$_.definition_sha256 -cne
                                        [string]$baselineTaskHashes[[string]$_.identity]
                                } | Sort-Object identity)
                                $runnerTaskIdentitiesAfterWait = [Collections.Generic.HashSet[string]]::new(
                                    [StringComparer]::OrdinalIgnoreCase)
                                foreach ($task in $finalTaskRows) {
                                    [void]$runnerTaskIdentitiesAfterWait.Add([string]$task.identity)
                                }
                                foreach ($identity in $baselineTasks) {
                                    if (-not $runnerTaskIdentitiesAfterWait.Contains([string]$identity)) {
                                        [void]$removedRunnerTasks.Add([string]$identity)
                                    }
                                }
                            }
                        }
                        else {
                            $smartScreenNaturalExit.status = 'rejected'
                            $smartScreenNaturalExit.final_runner_process_delta_identities = @(
                                $unexpectedRunnerProcessesAfterIntervention | ForEach-Object { [string]$_.identity })
                            $smartScreenNaturalExit.final_runner_task_delta_identities = @(
                                $unexpectedRunnerTasksAfterIntervention | ForEach-Object { [string]$_.identity })
                        }
                    }
                    $guestRootPresentBeforeDelete = [bool](Test-Path -LiteralPath $root)
                    $trustedRootPresentBeforeDelete = [bool](Test-Path -LiteralPath $trustedRoot)
                    $smartScreenInitialDeltaAccepted =
                        $smartScreenNaturalExit.status -ceq 'natural-exit' -and
                        $unexpectedRunnerProcessesBeforeCleanup.Count -eq 1 -and
                        [string]$unexpectedRunnerProcessesBeforeCleanup[0].identity -ceq
                            [string]$smartScreenNaturalExit.candidate_identity -and
                        $smartScreenNaturalExit.natural_exit_observed -and
                        $smartScreenNaturalExit.final_inventory_complete -and
                        $smartScreenNaturalExit.final_runner_process_delta_identities.Count -eq 0 -and
                        $smartScreenNaturalExit.final_runner_task_delta_identities.Count -eq 0
                    if (-not $mayDelete -or -not $jobsClosed -or $taskPresentBeforeDelete -or
                        -not $processSnapshotBeforeCleanup.complete -or
                        $unexpectedRunnerTasksBeforeCleanup.Count -ne 0 -or
                        ($unexpectedRunnerProcessesBeforeCleanup.Count -ne 0 -and
                            -not $smartScreenInitialDeltaAccepted) -or
                        -not $processSnapshotAfterIntervention.complete -or
                        $unexpectedRunnerTasksAfterIntervention.Count -ne 0 -or
                        $unexpectedRunnerProcessesAfterIntervention.Count -ne 0 -or
                        $removedRunnerTasks.Count -ne 0 -or
                        $terminatedRunnerProcesses.Count -ne 0 -or
                        $cleanupResourceErrors.Count -ne 0) {
                        return [pscustomobject]@{
                            guest_cleanup = $false
                            raw_cleanup = [ordered]@{
                                scheduled_task_present = $taskPresentBeforeDelete
                                guest_root_present = $guestRootPresentBeforeDelete
                                trusted_task_root_present = $trustedRootPresentBeforeDelete
                                process_jobs_closed = [bool]$jobsClosed
                                runner_process_inventory_complete = [bool]($processSnapshotBeforeCleanup.complete -and
                                    $processSnapshotAfterIntervention.complete)
                                unexpected_runner_tasks = $unexpectedRunnerTasksBeforeCleanup
                                unexpected_runner_processes = $unexpectedRunnerProcessesBeforeCleanup
                                unexpected_runner_tasks_after_intervention = $unexpectedRunnerTasksAfterIntervention
                                unexpected_runner_processes_after_intervention = $unexpectedRunnerProcessesAfterIntervention
                                unexpected_runner_tasks_after_delete = $null
                                unexpected_runner_processes_after_delete = $null
                                removed_runner_tasks = @($removedRunnerTasks | Sort-Object)
                                terminated_runner_processes = @($terminatedRunnerProcesses)
                                resource_cleanup_errors = @($cleanupResourceErrors)
                                smart_screen_natural_exit = $smartScreenNaturalExit
                                owned_processes_after = @(Get-CimInstance Win32_Process | Where-Object {
                                    Test-ProcessExecutableInOwnedRoots -Path $_.ExecutablePath -Prefixes $prefixes
                                } | Sort-Object ProcessId | ForEach-Object {
                                    [ordered]@{ pid = [int]$_.ProcessId; session_id = [int]$_.SessionId; executable_path = [string]$_.ExecutablePath }
                                })
                            }
                        }
                    }
                    $pending = New-Object 'Collections.Generic.Stack[string]'
                    $pending.Push($root)
                    while ($pending.Count -gt 0) {
                        $directory = $pending.Pop()
                        if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse fixture remains; VM directory retained.' }
                        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
                            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse fixture remains; VM directory retained.' }
                            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
                        }
                    }
                    foreach ($ownedRoot in @($root,$trustedRoot)) {
                        if (Test-Path -LiteralPath $ownedRoot) {
                            $pending = New-Object 'Collections.Generic.Stack[string]'
                            $pending.Push($ownedRoot)
                            while ($pending.Count -gt 0) {
                                $directory = $pending.Pop()
                                if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse entry remains; VM directory retained.' }
                                foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
                                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse entry remains; VM directory retained.' }
                                    if ($item.PSIsContainer) { $pending.Push($item.FullName) }
                                }
                            }
                        }
                    }
                    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
                    if (Test-Path -LiteralPath $trustedRoot) { Remove-Item -LiteralPath $trustedRoot -Recurse -Force }
                    $rootPresent = [bool](Test-Path -LiteralPath $root)
                    $trustedRootPresent = [bool](Test-Path -LiteralPath $trustedRoot)
                    $ownedAfter = @(Get-CimInstance Win32_Process `
                        -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object {
                        Test-ProcessExecutableInOwnedRoots -Path $_.ExecutablePath -Prefixes $prefixes
                    } | Sort-Object ProcessId | ForEach-Object {
                        [ordered]@{ pid = [int]$_.ProcessId; session_id = [int]$_.SessionId; executable_path = [string]$_.ExecutablePath }
                    })
                    $ownedScheduledTasksAfterDelete = @(Get-ScheduledTask -ErrorAction Stop |
                        Where-Object {
                            [string]$_.TaskName -ceq $name -and [string]$_.TaskPath -ceq '\'
                        })
                    $taskPresent = $ownedScheduledTasksAfterDelete.Count -gt 0
                    $runnerTasksAfterDelete = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                    $unexpectedRunnerTasksAfterDelete = @($runnerTasksAfterDelete |
                        Where-Object {
                            -not $baselineTasks.Contains([string]$_.identity) -or
                            [string]$_.definition_sha256 -cne [string]$baselineTaskHashes[[string]$_.identity]
                        } |
                        Sort-Object identity)
                    $runnerTaskIdentitiesAfterDelete = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase)
                    foreach ($task in $runnerTasksAfterDelete) {
                        [void]$runnerTaskIdentitiesAfterDelete.Add([string]$task.identity)
                    }
                    foreach ($identity in $baselineTasks) {
                        if (-not $runnerTaskIdentitiesAfterDelete.Contains([string]$identity)) {
                            [void]$removedRunnerTasks.Add([string]$identity)
                        }
                    }
                    $processSnapshotAfterDelete = Get-DrVmRunnerProcesses `
                        -UserSid $taskContext.runner_sid `
                        -SessionId $taskContext.runner_session_id
                    $unexpectedRunnerProcessesAfterDelete = @($processSnapshotAfterDelete.processes |
                        Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                        Sort-Object identity)
                    [pscustomobject]@{
                        guest_cleanup = ($jobsClosed -and -not $rootPresent -and
                            -not $trustedRootPresent -and
                            -not $taskPresent -and
                            $processSnapshotBeforeCleanup.complete -and
                            $processSnapshotAfterIntervention.complete -and
                            $processSnapshotAfterDelete.complete -and
                            $unexpectedRunnerTasksBeforeCleanup.Count -eq 0 -and
                            ($unexpectedRunnerProcessesBeforeCleanup.Count -eq 0 -or
                                $smartScreenInitialDeltaAccepted) -and
                            $unexpectedRunnerTasksAfterIntervention.Count -eq 0 -and
                            $unexpectedRunnerProcessesAfterIntervention.Count -eq 0 -and
                            $unexpectedRunnerTasksAfterDelete.Count -eq 0 -and
                            $unexpectedRunnerProcessesAfterDelete.Count -eq 0 -and
                            $removedRunnerTasks.Count -eq 0 -and
                            $terminatedRunnerProcesses.Count -eq 0 -and
                            $cleanupResourceErrors.Count -eq 0 -and
                            $ownedAfter.Count -eq 0)
                        raw_cleanup = [ordered]@{
                            scheduled_task_present = $taskPresent
                            guest_root_present = $rootPresent
                            trusted_task_root_present = $trustedRootPresent
                            process_jobs_closed = [bool]$jobsClosed
                            runner_process_inventory_complete = [bool]($processSnapshotBeforeCleanup.complete -and
                                $processSnapshotAfterIntervention.complete -and
                                $processSnapshotAfterDelete.complete)
                            unexpected_runner_tasks = $unexpectedRunnerTasksBeforeCleanup
                            unexpected_runner_processes = $unexpectedRunnerProcessesBeforeCleanup
                            unexpected_runner_tasks_after_intervention = $unexpectedRunnerTasksAfterIntervention
                            unexpected_runner_processes_after_intervention = $unexpectedRunnerProcessesAfterIntervention
                            unexpected_runner_tasks_after_delete = $unexpectedRunnerTasksAfterDelete
                            unexpected_runner_processes_after_delete = $unexpectedRunnerProcessesAfterDelete
                            removed_runner_tasks = @($removedRunnerTasks | Sort-Object)
                            terminated_runner_processes = @($terminatedRunnerProcesses)
                            resource_cleanup_errors = @($cleanupResourceErrors)
                            smart_screen_natural_exit = $smartScreenNaturalExit
                            owned_processes_after = $ownedAfter
                        }
                    }
                }
                if ($null -eq $cleanupResult -or $cleanupResult.guest_cleanup -isnot [bool] -or
                    $null -eq $cleanupResult.raw_cleanup) {
                    throw 'Guest cleanup did not return its bound raw observation.'
                }
                $transport.guest_cleanup = [bool]$cleanupResult.guest_cleanup
                $transport['raw_cleanup'] = $cleanupResult.raw_cleanup
            }
        } catch {
            $transport.status='failed'; $transport.cleanup_error='Guest cleanup failed; inspect cleanup-error.txt.'; $transport.guest_cleanup=$false
            $_ | Out-String | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'cleanup-error.txt') -Encoding UTF8
        }
        if ($guestRoot -and -not $transport.guest_cleanup) { [IO.File]::WriteAllText((Join-Path $transportOutputRoot 'retained-guest-directory.txt'), $guestRoot) }
        Remove-PSSession $session
    }
    if ($credential) { $credential.Password.Dispose() }
    if ($mutexHeld) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() }
    $transport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'transport.json') -Encoding UTF8
    if ($result -and $taskSelection.kind -ceq 'core') {
        $result | Add-Member -NotePropertyName transport -NotePropertyValue $transport -Force
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Encoding UTF8
    }
}
if ($transport.status -ne 'collected' -or -not $transport.guest_cleanup -or
    ($observerTask -and -not $acceptancePassed)) {
    throw 'VM transport, acceptance, or cleanup failed; inspect transport.json.'
}
}

Export-ModuleMember -Function Invoke-DrWindowsVmController
