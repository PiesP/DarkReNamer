function Resolve-ControllerTaskSelection {
    param(
        [AllowEmptyString()][string] $RequestedKind,
        [bool] $HasUiOutput,
        [bool] $HasUiManifest,
        [bool] $HasUiMode,
        [bool] $HasUiAppearance,
        [string] $UiMode,
        [string] $UiAppearance,
        [int] $UiTextScalePercent,
        [bool] $HasUiTextScalePercent,
        [bool] $UiHighContrast,
        [bool] $UiClipboard,
        [bool] $UiCaptureNativeMenu,
        [bool] $UiCaptureAdvancedAppearance,
        [bool] $HasRecoveryOutput,
        [bool] $HasRecoveryMode,
        [bool] $HasRecoveryObserverSha256,
        [string] $RecoveryMode,
        [bool] $RecoveryExport,
        [bool] $RecoveryIntentOnlyCandidateDiscard,
        [bool] $HasRecoveryFixtureCount,
        [int] $TimeoutSeconds
    )

    $uiPrimary = @($HasUiOutput, $HasUiManifest, $HasUiMode, $HasUiAppearance)
    $uiConfigured = $uiPrimary -contains $true -or $HasUiTextScalePercent -or
        $UiHighContrast -or $UiClipboard -or
        $UiCaptureNativeMenu -or $UiCaptureAdvancedAppearance
    $recoveryPrimary = @($HasRecoveryOutput, $HasRecoveryMode, $HasRecoveryObserverSha256)
    $recoveryConfigured = $recoveryPrimary -contains $true -or $RecoveryExport -or
        $RecoveryIntentOnlyCandidateDiscard -or $HasRecoveryFixtureCount
    if ($uiConfigured -and $recoveryConfigured) {
        throw 'UI and recovery observer arguments cannot be combined.'
    }

    $kind = if ([string]::IsNullOrEmpty($RequestedKind)) {
        if ($uiConfigured) { 'ui' }
        elseif ($recoveryConfigured) { 'recovery' }
        else { 'core' }
    }
    else { $RequestedKind }

    switch ($kind) {
        'core' {
            if ($uiConfigured -or $recoveryConfigured) {
                throw 'Core tasks do not accept observer arguments.'
            }
        }
        'ui' {
            if ($TimeoutSeconds -gt 600) {
                throw 'Observer task timeout must not exceed 600 seconds.'
            }
            if ($uiPrimary -contains $false) {
                throw 'UI tasks require acceptance output, manifest, mode, and appearance.'
            }
            if ($recoveryConfigured) {
                throw 'UI tasks do not accept recovery arguments.'
            }
            if (($UiMode -ceq 'text-scale' -and $UiTextScalePercent -ne 150) -or
                ($UiTextScalePercent -eq 150 -and
                    ($UiMode -cnotin @('text-scale', 'appearance-pair') -or $UiHighContrast))) {
                throw 'Only text-scale or non-High-Contrast appearance-pair may request 150 percent text.'
            }
            if ($UiHighContrast -and $UiMode -cnotin @('current-dpi', 'appearance-pair')) {
                throw 'High Contrast UI options require current-dpi or appearance-pair mode.'
            }
            if (($UiClipboard -or $UiCaptureNativeMenu -or $UiCaptureAdvancedAppearance) -and
                $UiMode -cne 'current-dpi') {
                throw 'Current-DPI UI options require the current-dpi mode.'
            }
            if ($UiHighContrast -and $UiAppearance -cne 'system') {
                throw 'High Contrast UI tasks require the system appearance.'
            }
            if ($UiHighContrast -and $UiCaptureAdvancedAppearance) {
                throw 'Advanced appearance capture is unavailable during High Contrast.'
            }
        }
        'recovery' {
            if ($TimeoutSeconds -gt 600) {
                throw 'Observer task timeout must not exceed 600 seconds.'
            }
            if ($recoveryPrimary -contains $false) {
                throw 'Recovery tasks require output, mode, and a frozen observer SHA-256.'
            }
            if ($uiConfigured) {
                throw 'Recovery tasks do not accept UI arguments.'
            }
            if (($RecoveryExport -or $RecoveryIntentOnlyCandidateDiscard) -and
                $RecoveryMode -cne 'ProcessCrash') {
                throw 'Recovery export and intent-only discard require ProcessCrash mode.'
            }
        }
        default { throw 'The VM task kind is invalid.' }
    }
    [pscustomobject]@{ kind = $kind; is_observer = $kind -in @('ui', 'recovery') }
}
function Assert-PlainFile([string] $Name) {
    if ($Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$') {
        throw 'Invalid bundle file name.'
    }
    $baseName = $Name.Split('.')[0]
    if ($Name.EndsWith('.', [StringComparison]::Ordinal) -or
        $Name.EndsWith(' ', [StringComparison]::Ordinal) -or
        $baseName -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        throw 'Invalid Windows ordinary file name.'
    }
}
function Get-CoreGuiFailureDiagnosticOutputs {
    param([AllowNull()][object] $Gui)

    $outputs = [Collections.Generic.List[object]]::new()
    if ($null -eq $Gui -or
        $Gui.PSObject.Properties.Name -cnotcontains 'flow' -or
        $null -eq $Gui.flow -or
        $Gui.flow.PSObject.Properties.Name -cnotcontains 'foreground_observations') {
        return $outputs.ToArray()
    }
    $seen = @{}
    foreach ($observation in @($Gui.flow.foreground_observations)) {
        if ($null -eq $observation -or
            $observation.PSObject.Properties.Name -cnotcontains 'solid_image_diagnostic') {
            continue
        }
        $diagnostic = $observation.solid_image_diagnostic
        $required = @('classification', 'scope', 'file', 'sha256', 'bytes')
        if ($null -eq $diagnostic -or
            @($required | Where-Object {
                $diagnostic.PSObject.Properties.Name -cnotcontains $_
            }).Count -ne 0 -or
            $diagnostic.classification -cne 'sampled-grid-uniform' -or
            $diagnostic.scope -cne 'sparse-samples-only' -or
            $diagnostic.file -isnot [string] -or
            $diagnostic.sha256 -isnot [string] -or
            $diagnostic.sha256 -cnotmatch '^[0-9a-f]{64}\z' -or
            ($diagnostic.bytes -isnot [int] -and $diagnostic.bytes -isnot [long]) -or
            $diagnostic.bytes -le 0 -or $diagnostic.bytes -gt 128MB) {
            throw 'Core GUI failure diagnostic has a malformed reference.'
        }
        Assert-PlainFile $diagnostic.file
        if ($diagnostic.file -cnotmatch '\.solid-diagnostic\.png\z') {
            throw 'Core GUI failure diagnostic has a malformed reference.'
        }
        if ($seen.ContainsKey($diagnostic.file)) {
            throw 'Core GUI failure diagnostic has a duplicate file reference.'
        }
        $seen[$diagnostic.file] = $true
        $outputs.Add([pscustomobject]@{
            file = [string]$diagnostic.file
            sha256 = [string]$diagnostic.sha256
            bytes = [long]$diagnostic.bytes
        })
    }
    $outputs.ToArray()
}
function Join-GuestWindowsPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Leaf
    )

    Assert-PlainFile $Leaf
    if ($Root.EndsWith('\', [StringComparison]::Ordinal) -or
        $Root.EndsWith('/', [StringComparison]::Ordinal)) {
        return $Root + $Leaf
    }
    $Root + '\' + $Leaf
}
function Get-SafeEvidencePathSegments([string] $RelativePath) {
    if ([string]::IsNullOrEmpty($RelativePath) -or $RelativePath.Length -gt 512 -or
        $RelativePath.Contains('\') -or $RelativePath.StartsWith('/', [StringComparison]::Ordinal)) {
        throw 'Invalid relative evidence path.'
    }
    $segments = @($RelativePath.Split('/'))
    if ($segments.Count -eq 0 -or $segments.Count -gt 8) {
        throw 'Invalid relative evidence path depth.'
    }
    foreach ($segment in $segments) {
        if ($segment -in @('.', '..')) { throw 'Invalid relative evidence path segment.' }
        Assert-PlainFile $segment
    }
    $segments
}
function Join-GuestEvidencePath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )
    $path = $Root
    foreach ($segment in @(Get-SafeEvidencePathSegments $RelativePath)) {
        $path = Join-GuestWindowsPath -Root $path -Leaf $segment
    }
    $path
}
function Assert-PathWithoutReparse([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse paths are not supported for VM test bundles.' }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}
function Assert-AcceptanceInputArtifactBinding {
    param(
        [Parameter(Mandatory = $true)][object] $InputDocument,
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][bool] $CandidateLane
    )

    if (-not $CandidateLane) { return }
    if ($InputDocument.artifacts.application.sha256 -cne
            $Manifest.product.application.sha256 -or
        $InputDocument.artifacts.runner.sha256 -cne
            $Manifest.harness.runner.sha256) {
        throw 'Acceptance input candidate application or runner differs from the frozen bundle.'
    }
    if ($Manifest.lane -ceq 'focused-preserved-source-built-product-v1' -and
        ($InputDocument.request.mode -cne 'focused-10k-clear' -or
         $InputDocument.source_sha -cne $Manifest.product.source_sha -or
         $InputDocument.source_tree -cne $Manifest.product.source_tree -or
         $InputDocument.tooling_source_sha -cne $Manifest.harness.source_sha -or
         $InputDocument.tooling_source_tree -cne $Manifest.harness.source_tree -or
         $InputDocument.prepared_bundle.original_bundle_manifest_sha256 -cne
            $Manifest.product.provenance.original_bundle_manifest.sha256 -or
         $InputDocument.prepared_bundle.tooling_record_sha256 -cne
            $Manifest.harness.tooling_record.sha256 -or
         $InputDocument.artifacts.observer.sha256 -cne
            $Manifest.harness.observers.ui.sha256)) {
        throw 'Focused preserved product or current tooling source differs from the frozen input.'
    }
}
function Assert-SafeAcceptanceRunId {
    param([AllowNull()][object] $RunId)

    if ($RunId -isnot [string] -or
        $RunId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
        $RunId.EndsWith('.', [StringComparison]::Ordinal) -or
        $RunId.EndsWith(' ', [StringComparison]::Ordinal)) {
        throw 'Acceptance input run_id must be a bounded safe token.'
    }
}
function Assert-ObserverResultBinding {
    param(
        [Parameter(Mandatory = $true)][object] $Result,
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][ValidateSet('ui', 'recovery')][string] $Role,
        [Parameter(Mandatory = $true)][string] $ExpectedObserverSha256
    )

    if ($Result.schema_version -isnot [long] -or
        $Manifest.schema_version -isnot [long] -or
        $Result.schema_version -ne $Manifest.schema_version) {
        throw 'Observer result schema version differs from the bundle.'
    }
    $candidate = $Manifest.schema_version -eq 2
    if ($candidate) {
        if ($Result.lane -cne $Manifest.lane -or
            $Result.lane -cnotin @('candidate-gui-only',
                'focused-preserved-source-built-product-v1') -or
            $Result.observer_role -cne $Role -or
            $null -eq $Result.product -or $null -eq $Result.harness) {
            throw 'Candidate observer result role or provenance shape is invalid.'
        }
        $manifestProduct = $Manifest.product | ConvertTo-Json -Depth 12 -Compress
        $resultProduct = $Result.product | ConvertTo-Json -Depth 12 -Compress
        $manifestHarness = $Manifest.harness | ConvertTo-Json -Depth 12 -Compress
        $resultHarness = $Result.harness | ConvertTo-Json -Depth 12 -Compress
        if ($resultProduct -cne $manifestProduct -or $resultHarness -cne $manifestHarness) {
            throw 'Candidate observer result product or harness provenance differs from the bundle.'
        }
        $application = $Manifest.product.application
        $runner = $Manifest.harness.runner
        $observer = $Manifest.harness.observers.$Role
    }
    elseif ($Manifest.schema_version -eq 1) {
        foreach ($forbidden in @('lane', 'product', 'harness', 'observer_role')) {
            if ($Result.PSObject.Properties.Name -ccontains $forbidden) {
                throw 'Legacy observer result contains candidate-only provenance fields.'
            }
        }
        if ($Result.source_sha -cne $Manifest.source_sha) {
            throw 'Legacy observer result source differs from the bundle.'
        }
        if ($Role -ceq 'recovery' -and $Result.source_state -cne $Manifest.source_state) {
            throw 'Legacy recovery result source state differs from the bundle.'
        }
        $application = $Manifest.application
        $runner = $Manifest.runner
        $observer = [pscustomobject]@{
            file = if ($Role -ceq 'ui') {
                'windows-vm-acceptance.ps1'
            } else {
                'windows-vm-recovery-acceptance.ps1'
            }
            sha256 = $ExpectedObserverSha256
        }
    }
    else {
        throw 'Observer result bundle schema is unsupported.'
    }
    $expectedObserverFile = if ($Role -ceq 'ui') {
        'windows-vm-acceptance.ps1'
    } else {
        'windows-vm-recovery-acceptance.ps1'
    }
    if ($observer.file -cne $expectedObserverFile -or
        $observer.sha256 -cne $ExpectedObserverSha256 -or
        $Result.application.file -cne $application.file -or
        $Result.application.sha256 -cne $application.sha256 -or
        $Result.runner_sha256 -cne $runner.sha256) {
        throw 'Observer result executable or script binding differs from the frozen task.'
    }
    if ($Role -ceq 'ui') {
        if ($Result.acceptance_script_sha256 -cne $ExpectedObserverSha256) {
            throw 'UI observer result script binding differs from the frozen task.'
        }
    }
    elseif ($Result.observer.file -cne $observer.file -or
        $Result.observer.sha256 -cne $ExpectedObserverSha256) {
        throw 'Recovery observer result script binding differs from the frozen task.'
    }
}
function Get-LowerTextSha256([string] $Value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString(
            $algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Value))
        ) -replace '-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Get-ControllerFileSha256 {
    param([Parameter(Mandatory)][string] $Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-ControllerToolingTransferStage {
    param([Parameter(Mandatory)][object] $VerifiedTooling)

    if ($VerifiedTooling.ManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $VerifiedTooling.ManifestBase64 -isnot [string]) {
        throw 'The verified tooling manifest is unavailable for transfer.'
    }
    $root = Join-Path ([IO.Path]::GetTempPath()) (
        'darkrenamer-tooling-' + [guid]::NewGuid().ToString('N')
    )
    [void](New-Item -ItemType Directory -Path $root)
    try {
        $manifestBytes = [Convert]::FromBase64String($VerifiedTooling.ManifestBase64)
        $manifestPath = Join-Path $root 'tooling-bundle.json'
        [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
        if ((Get-ControllerFileSha256 -Path $manifestPath) -cne
            $VerifiedTooling.ManifestSha256) {
            throw 'The frozen tooling manifest changed while materializing the transfer.'
        }

        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $records = [Collections.Generic.List[object]]::new()
        foreach ($record in @($VerifiedTooling.Records)) {
            Assert-PlainFile -Name $record.Bundle
            if (-not $seen.Add($record.Bundle) -or
                $record.Role -isnot [string] -or
                $record.Sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $record.FrozenBase64 -isnot [string]) {
                throw 'The verified tooling transfer contains an invalid record.'
            }
            $bytes = [Convert]::FromBase64String($record.FrozenBase64)
            if ($bytes.Length -ne [long]$record.Length) {
                throw "The frozen tooling length changed for role $($record.Role)."
            }
            $path = Join-Path $root $record.Bundle
            [IO.File]::WriteAllBytes($path, $bytes)
            if ((Get-ControllerFileSha256 -Path $path) -cne $record.Sha256) {
                throw "The frozen tooling hash changed for role $($record.Role)."
            }
            $records.Add([pscustomobject]@{
                role = [string]$record.Role
                file = [string]$record.Bundle
                sha256 = [string]$record.Sha256
                bytes = [long]$record.Length
            })
        }
        if ($records.Count -eq 0) {
            throw 'The verified tooling transfer closure is empty.'
        }
        [pscustomobject]@{
            root = $root
            manifest_sha256 = [string]$VerifiedTooling.ManifestSha256
            records = $records.ToArray()
        }
    }
    catch {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
        throw
    }
}

function Remove-ControllerToolingTransferStage {
    param([AllowNull()][object] $Transfer)

    try {
        if ($null -ne $Transfer -and
            (Test-Path -LiteralPath $Transfer.root)) {
            Remove-Item -LiteralPath $Transfer.root -Recurse -Force
        }
        return $null
    }
    catch {
        return 'Local frozen-tooling transfer cleanup failed.'
    }
}

function Test-DrRuntimeBrokerDiagnosticArguments {
    param([string] $Root, [string] $RunId, [bool] $PreparationOnly,
        [string] $TransportKind, [string] $TaskKind, [string] $Mode,
        [guid] $VmId, [string] $RunnerSid, [int] $BudgetSeconds)
    $enabled = -not [string]::IsNullOrEmpty($Root) -or -not [string]::IsNullOrEmpty($RunId)
    if (-not $enabled -and -not $PreparationOnly -and $BudgetSeconds -eq 0) { return $false }
    if ($RunId -cnotmatch '^[0-9a-f]{32}$' -or
        $Root -cne ('C:\ProgramData\DarkReNamerRuntimeBrokerDiag-' + $RunId) -or
        $TransportKind -cne 'ssh' -or $TaskKind -cne 'ui' -or $Mode -cne 'current-dpi' -or
        $VmId -eq [guid]::Empty -or $RunnerSid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$' -or
        $BudgetSeconds -lt 1 -or $BudgetSeconds -gt 900) {
        throw 'RuntimeBroker diagnostics require a bound SSH current-DPI attempt and observer root.'
    }
    return $true
}

function Get-DrRuntimeBrokerControllerRemainingSeconds {
    param([Parameter(Mandatory)][Diagnostics.Stopwatch] $Clock,
        [Parameter(Mandatory)][int] $BudgetSeconds, [int] $ReserveSeconds = 0)
    $remaining = [int][Math]::Floor($BudgetSeconds - $Clock.Elapsed.TotalSeconds - $ReserveSeconds)
    if ($remaining -le 0) { throw 'RuntimeBroker diagnostic controller deadline reached.' }
    return $remaining
}

function Write-DrRuntimeBrokerPhaseFile {
    param([Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $Phase,
        [ValidateSet('begin','end','observed')][string] $State = 'observed',
        [ValidateSet('controller','ui-observer')][string] $Source = 'controller',
        [string] $RecordedAtUtc = [DateTime]::UtcNow.ToString('o'),
        [System.Collections.IDictionary] $Details = @{})
    if ($RunId -cnotmatch '^[0-9a-f]{32}$' -or
        $Root -cne ('C:\ProgramData\DarkReNamerRuntimeBrokerDiag-' + $RunId) -or
        $Phase -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or
        $RecordedAtUtc -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{1,7}Z$') {
        throw 'Invalid RuntimeBroker phase identity or guest timestamp.'
    }
    [void][DateTime]::Parse($RecordedAtUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
    $directory = Join-Path $Root 'phases'
    $cursor = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    while ($null -ne $cursor) {
        if ($cursor -isnot [IO.DirectoryInfo] -or
            ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'RuntimeBroker phase directory ancestry is not ordinary.'
        }
        $cursor = $cursor.Parent
    }
    # A fixed partition avoids racing the collector's independent output budget.
    $rows = @(Get-ChildItem -LiteralPath $directory -Force)
    if ($rows.Count -ge 192) { throw 'RuntimeBroker phase count limit reached.' }
    foreach ($row in $rows) {
        if ($row.PSIsContainer -or ($row.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $row.Name -cnotmatch '^[0-9a-f]{32}\.json$' -or $row.Length -gt 4096) {
            throw 'RuntimeBroker phase inventory is invalid.'
        }
    }
    $record = [ordered]@{ schema_version=1; run_id=$RunId; phase=$Phase; state=$State
        recorded_at_utc=$RecordedAtUtc; source=$Source; details=$Details }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($record | ConvertTo-Json -Depth 5 -Compress))
    if ($bytes.Length -gt 4096) { throw 'RuntimeBroker phase byte limit reached.' }
    $leaf = [guid]::NewGuid().ToString('N')
    $path = Join-Path $directory ($leaf + '.json')
    $staging = Join-Path $Root ('phase-' + $leaf + '.tmp')
    $stream = [IO.File]::Open($staging, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        # The observer can only discover a complete, closed immutable JSON file.
        [IO.File]::Move($staging, $path)
    } finally { if ([IO.File]::Exists($staging)) { [IO.File]::Delete($staging) } }
}

function Initialize-DrRuntimeBrokerControllerDiagnostic {
    param([Parameter(Mandatory)][object] $Session,
        [Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $RunnerSid, [Parameter(Mandatory)][guid] $VmId)
    Invoke-Command -Session $Session -ArgumentList $Root,$RunId,$RunnerSid,$VmId,
        (${function:Write-DrRuntimeBrokerPhaseFile}.ToString()) -ScriptBlock {
        param($root,$runId,$sid,$vmId,$phaseDefinition)
        $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'RuntimeBroker diagnostic root is not ordinary.'
        }
        $acl = Get-Acl -LiteralPath $root
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if (-not $acl.AreAccessRulesProtected -or $owner -notin @('S-1-5-18','S-1-5-32-544')) {
            throw 'RuntimeBroker diagnostic root is not protected.'
        }
        foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and
                ([long]$rule.FileSystemRights -band 0x000D0156) -ne 0) {
                throw 'RuntimeBroker diagnostic root grants untrusted mutation rights.'
            }
        }
        $path = Join-Path $root 'ready.json'
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -gt 4096) { throw 'RuntimeBroker READY record is invalid.' }
        $ready = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($ready.schema_version -ne 1 -or $ready.status -cne 'ready' -or
            $ready.run_id -cne $runId -or $ready.runner_sid -cne $sid -or
            [guid]$ready.expected_vm_id -ne $vmId -or
            $ready.subscriptions_started_before_snapshot -isnot [bool] -or
            -not $ready.subscriptions_started_before_snapshot -or
            $ready.initial_snapshot_complete -isnot [bool] -or -not $ready.initial_snapshot_complete) {
            throw 'RuntimeBroker READY is not bound to this diagnostic attempt.'
        }
        Set-Item -Path Function:\global:Write-DrRuntimeBrokerPhaseFile -Value ([scriptblock]::Create($phaseDefinition))
        $global:DrRuntimeBrokerDiagnostic = @{ Root=$root; RunId=$runId }
        $global:DrRuntimeBrokerPhaseErrors = [Collections.Generic.List[string]]::new()
        function global:Write-DrRuntimeBrokerControllerPhase {
            param([string] $Phase, [string] $State='observed', [hashtable] $Details=@{})
            try { Write-DrRuntimeBrokerPhaseFile @global:DrRuntimeBrokerDiagnostic -Phase $Phase -State $State -Details $Details }
            catch {
                if ($global:DrRuntimeBrokerPhaseErrors.Count -lt 32) {
                    $global:DrRuntimeBrokerPhaseErrors.Add($Phase + ': ' + $_.Exception.GetType().Name)
                }
            }
        }
        Write-DrRuntimeBrokerControllerPhase -Phase 'controller-connected'
    }
}
