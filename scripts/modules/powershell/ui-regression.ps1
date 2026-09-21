function Get-TextScaleSnapshot {
    Initialize-TextScaleNative
    $registryPath = 'HKCU:\Software\Microsoft\Accessibility'
    $valueName = 'TextScaleFactor'
    $keyExists = Test-Path -LiteralPath $registryPath -PathType Container
    $valueExists = $false
    $valueKind = $null
    $value = $null
    if ($keyExists) {
        $key = Get-Item -LiteralPath $registryPath -Force -ErrorAction Stop
        $valueExists = $key.GetValueNames() -ccontains $valueName
        if ($valueExists) {
            $valueKind = $key.GetValueKind($valueName).ToString()
            $value = [int64]$key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    }
    $rawFactor = [double][DarkReNamerTextScaleNative]::ReadTextScaleFactor()
    if ([double]::IsNaN($rawFactor) -or $rawFactor -lt 1.0 -or $rawFactor -gt 2.25) {
        throw 'UISettings.TextScaleFactor is outside the documented system range.'
    }
    [pscustomobject]@{
        KeyExists = [bool]$keyExists
        ValueExists = [bool]$valueExists
        ValueKind = $valueKind
        Value = $value
        UiFactor = $rawFactor
        UiPercent = [int][Math]::Round($rawFactor * 100.0)
    }
}
function ConvertTo-TextScaleDocumentSnapshot {
    param([Parameter(Mandatory)][object] $Snapshot)
    [ordered]@{
        registry_key_existed = [bool]$Snapshot.KeyExists
        registry_value_existed = [bool]$Snapshot.ValueExists
        registry_value_kind = $Snapshot.ValueKind
        registry_value = $Snapshot.Value
        ui_settings_raw_factor = [double]$Snapshot.UiFactor
        ui_settings_percent = [int]$Snapshot.UiPercent
    }
}
function Test-TextScaleSnapshotEqual {
    param([Parameter(Mandatory)][object] $Expected, [Parameter(Mandatory)][object] $Actual)
    $Expected.KeyExists -eq $Actual.KeyExists -and
        $Expected.ValueExists -eq $Actual.ValueExists -and
        [string]::Equals([string]$Expected.ValueKind, [string]$Actual.ValueKind, [StringComparison]::Ordinal) -and
        $Expected.Value -eq $Actual.Value -and
        [Math]::Abs([double]$Expected.UiFactor - [double]$Actual.UiFactor) -lt 0.000001 -and
        $Expected.UiPercent -eq $Actual.UiPercent
}
function Wait-TextScaleSnapshot {
    param(
        [Parameter(Mandatory)][scriptblock] $Accept,
        [Parameter(Mandatory)][string] $Label,
        [string] $ObservationPath,
        [string] $SourceSha,
        [string] $ScriptSha256,
        [ValidateRange(2, 60)][int] $MaximumAttempts = 50
    )
    $previous = $null
    $attempts = [Collections.Generic.List[object]]::new()
    for ($attempt = 0; $attempt -lt $MaximumAttempts; $attempt++) {
        $current = Get-TextScaleSnapshot
        $accepted = [bool](& $Accept $current)
        $attempts.Add([ordered]@{
            attempt = $attempt + 1
            accepted = $accepted
            observed = ConvertTo-TextScaleDocumentSnapshot -Snapshot $current
        })
        if (-not [string]::IsNullOrEmpty($ObservationPath)) {
            Write-JsonUtf8Bom -Path $ObservationPath -Value ([ordered]@{
                schema_version = 1
                source_sha = $SourceSha
                acceptance_script_sha256 = $ScriptSha256
                target = [ordered]@{ registry_value = 150; ui_settings_raw_factor = 1.5; ui_settings_percent = 150 }
                settled = $false
                attempts = $attempts.ToArray()
            })
        }
        if ($accepted -and $null -ne $previous -and (Test-TextScaleSnapshotEqual -Expected $previous -Actual $current)) {
            if (-not [string]::IsNullOrEmpty($ObservationPath)) {
                Write-JsonUtf8Bom -Path $ObservationPath -Value ([ordered]@{
                    schema_version = 1
                    source_sha = $SourceSha
                    acceptance_script_sha256 = $ScriptSha256
                    target = [ordered]@{ registry_value = 150; ui_settings_raw_factor = 1.5; ui_settings_percent = 150 }
                    settled = $true
                    attempts = $attempts.ToArray()
                })
            }
            return $current
        }
        $previous = if ($accepted) { $current } else { $null }
        if ($attempt + 1 -lt $MaximumAttempts) { Start-Sleep -Milliseconds 200 }
    }
    $last = $attempts[$attempts.Count - 1].observed
    throw "$Label did not settle; last registry value=$($last.registry_value), UISettings factor=$($last.ui_settings_raw_factor)."
}
function Set-TextScale150 {
    param([Parameter(Mandatory)][object] $Original)
    if (-not $Original.KeyExists) {
        throw 'The existing Windows accessibility registry key is required; this observer will not create profile structure.'
    }
    if ($Original.ValueExists -and $Original.ValueKind -cne 'DWord') {
        throw 'The existing TextScaleFactor value is not DWORD and will not be modified.'
    }
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Accessibility' -Name 'TextScaleFactor' -Value 150 -Type DWord
    [DarkReNamerTextScaleNative]::NotifyAccessibilitySettingChange()
}
function Restore-TextScaleSnapshot {
    param([Parameter(Mandatory)][object] $Expected)
    if (-not $Expected.KeyExists) { throw 'A missing original accessibility key is outside this observer contract.' }
    $path = 'HKCU:\Software\Microsoft\Accessibility'
    if ($Expected.ValueExists) {
        if ($Expected.ValueKind -cne 'DWord') { throw 'The saved TextScaleFactor value kind is unsupported.' }
        Set-ItemProperty -LiteralPath $path -Name 'TextScaleFactor' -Value ([int64]$Expected.Value) -Type DWord
    }
    else {
        Remove-ItemProperty -LiteralPath $path -Name 'TextScaleFactor' -ErrorAction SilentlyContinue
    }
    [DarkReNamerTextScaleNative]::NotifyAccessibilitySettingChange()
    Wait-TextScaleSnapshot -Label 'System text-scale restoration' -Accept {
        param($candidate)
        Test-TextScaleSnapshotEqual -Expected $Expected -Actual $candidate
    }
}
function ConvertFrom-TextScaleDocumentSnapshot {
    param([Parameter(Mandatory)][object] $Document, [Parameter(Mandatory)][string] $Label)
    $names = @($Document.PSObject.Properties.Name | Sort-Object)
    $expectedNames = @('registry_key_existed','registry_value','registry_value_existed','registry_value_kind','ui_settings_percent','ui_settings_raw_factor')
    if (@(Compare-Object -CaseSensitive $expectedNames $names).Count -ne 0 -or $names.Count -ne $expectedNames.Count) {
        throw "Text-scale restore snapshot $Label fields are invalid."
    }
    if ($Document.registry_key_existed -isnot [bool] -or -not $Document.registry_key_existed -or
        $Document.registry_value_existed -isnot [bool] -or
        $Document.ui_settings_raw_factor -isnot [double] -or
        $Document.ui_settings_percent -isnot [long]) {
        throw "Text-scale restore snapshot $Label types are invalid."
    }
    if ($Document.registry_value_existed) {
        if ($Document.registry_value_kind -cne 'DWord' -or $Document.registry_value -isnot [long] -or
            [int64]$Document.registry_value -lt 0 -or [int64]$Document.registry_value -gt [uint32]::MaxValue) {
            throw "Text-scale restore snapshot $Label registry value is invalid."
        }
    }
    elseif ($null -ne $Document.registry_value_kind -or $null -ne $Document.registry_value) {
        throw "Text-scale restore snapshot $Label absent registry value is invalid."
    }
    if ($Document.ui_settings_raw_factor -lt 1.0 -or $Document.ui_settings_raw_factor -gt 2.25 -or
        $Document.ui_settings_percent -ne [int][Math]::Round($Document.ui_settings_raw_factor * 100.0)) {
        throw "Text-scale restore snapshot $Label UISettings value is invalid."
    }
    [pscustomobject]@{
        KeyExists = $true
        ValueExists = [bool]$Document.registry_value_existed
        ValueKind = $Document.registry_value_kind
        Value = $Document.registry_value
        UiFactor = [double]$Document.ui_settings_raw_factor
        UiPercent = [int]$Document.ui_settings_percent
    }
}
function Resolve-TextScaleRestoreDocument {
    param([Parameter(Mandatory)][string] $OutputDirectory, [Parameter(Mandatory)][string] $SourceSha, [Parameter(Mandatory)][string] $ScriptSha256)
    $path = Join-Path $OutputDirectory 'text-scale-snapshot.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Text-scale snapshot is missing.'
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 1MB) {
        throw 'Text-scale snapshot must be an ordinary bounded file.'
    }
    try { $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { throw 'Text-scale snapshot is not valid JSON.' }
    $names = @($document.PSObject.Properties.Name | Sort-Object)
    $expectedNames = @('acceptance_script_sha256','original','restoration_required','restoration_verified','restored','schema_version','source_sha')
    if (@(Compare-Object -CaseSensitive $expectedNames $names).Count -ne 0 -or $names.Count -ne $expectedNames.Count) { throw 'Text-scale restore document fields are invalid.' }
    if ($document.schema_version -isnot [long] -or $document.schema_version -ne 1 -or
        $document.source_sha -cne $SourceSha -or
        $document.acceptance_script_sha256 -cne $ScriptSha256) {
        throw 'Text-scale restore binding mismatch.'
    }
    if ($document.restoration_required -isnot [bool] -or $document.restoration_verified -isnot [bool]) { throw 'Text-scale restore state is invalid.' }
    $expected = ConvertFrom-TextScaleDocumentSnapshot -Document $document.original -Label 'original'
    if (-not $document.restoration_required) { throw 'Text-scale snapshot must retain its restoration instruction.' }
    if (-not $document.restoration_verified) {
        if ($null -ne $document.restored) { throw 'Text-scale restore pending state is invalid.' }
    }
    else {
        if ($null -eq $document.restored) { throw 'Text-scale restore verified state is invalid.' }
        $restored = ConvertFrom-TextScaleDocumentSnapshot -Document $document.restored -Label 'restored'
        if (-not (Test-TextScaleSnapshotEqual -Expected $expected -Actual $restored)) { throw 'Restored text scale differs from the original snapshot.' }
    }
    [pscustomobject]@{ path = $path; document = $document; expected = $expected }
}
function Invoke-TextScaleRescue {
    param([Parameter(Mandatory)][object] $Verified, [Parameter(Mandatory)][int] $SessionId)
    $restore = Resolve-TextScaleRestoreDocument -OutputDirectory $Verified.output_root -SourceSha $Verified.source_sha -ScriptSha256 $Verified.script_sha256
    $resultPath = Join-Path $Verified.output_root 'text-scale-rescue-result.json'
    $errorPath = Join-Path $Verified.output_root 'text-scale-rescue-error.txt'
    $result = [ordered]@{ schema_version = 1; source_sha = $Verified.source_sha; acceptance_script_sha256 = $Verified.script_sha256; status = 'failed'; action = $null; restoration_verified = $false; snapshot_sha256 = Get-LowerSha256 -Path $restore.path; failure_reason = 'restore_failed'; diagnostic = $null }
    $lock = $null
    try {
        $lock = Enter-DesktopTestLock -SessionId $SessionId
        if ($null -eq $lock) { throw 'Another Windows VM test runner is using this interactive desktop.' }
        Initialize-TextScaleNative
        $current = Get-TextScaleSnapshot
        if ($restore.document.restoration_verified -and
            (Test-TextScaleSnapshotEqual -Expected $restore.expected -Actual $current)) {
            $result.status = 'passed'; $result.action = 'no_op_already_restored'; $result.restoration_verified = $true; $result.failure_reason = $null
        }
        else {
            $restored = Restore-TextScaleSnapshot -Expected $restore.expected
            Write-JsonUtf8Bom -Path $restore.path -Value ([ordered]@{ schema_version = 1; source_sha = $Verified.source_sha; acceptance_script_sha256 = $Verified.script_sha256; restoration_required = $true; original = ConvertTo-TextScaleDocumentSnapshot $restore.expected; restoration_verified = $true; restored = ConvertTo-TextScaleDocumentSnapshot $restored })
            $result.status = 'passed'; $result.action = 'restored_original_text_scale'; $result.restoration_verified = $true; $result.snapshot_sha256 = Get-LowerSha256 -Path $restore.path; $result.failure_reason = $null
        }
    }
    catch {
        $_ | Out-String -Width 4096 | Set-Content -LiteralPath $errorPath -Encoding UTF8
        $result.diagnostic = [ordered]@{ file = 'text-scale-rescue-error.txt'; sha256 = Get-LowerSha256 -Path $errorPath }
        throw
    }
    finally {
        if ($null -ne $lock) { Exit-DesktopTestLock -Lock $lock }
        Write-JsonUtf8Bom -Path $resultPath -Value $result
    }
}
function Assert-GuiRegressionInvocationBinding {
    param(
        [Parameter(Mandatory)][object] $ManifestInput,
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RegressionMode,
        [Parameter(Mandatory)][string] $Appearance,
        [Parameter(Mandatory)][int] $TextScalePercent,
        [Parameter(Mandatory)][string] $ExpectedScriptSha256
    )

    if ($ManifestInput.schema_version -ne 1 -or
        $ManifestInput.source_sha -cne $Verified.source_sha -or
        $ManifestInput.artifacts.application.sha256 -cne $Verified.application.sha256 -or
        $ManifestInput.artifacts.runner.sha256 -cne $Verified.runner.sha256 -or
        $ManifestInput.artifacts.observer.sha256 -cne $ExpectedScriptSha256 -or
        $ManifestInput.request.mode -cne $RegressionMode -or
        $ManifestInput.request.appearance -cne $Appearance -or
        $ManifestInput.request.text_scale_percent -ne $TextScalePercent) {
        throw 'Regression invocation differs from its immutable manifest.'
    }
    [void](Resolve-GuiRegressionLayoutVariant `
        -ManifestInput $ManifestInput `
        -Verified $Verified `
        -RegressionMode $RegressionMode `
        -Appearance $Appearance `
        -TextScalePercent $TextScalePercent)
}
function Resolve-GuiRegressionLayoutVariant {
    param(
        [Parameter(Mandatory)][object] $ManifestInput,
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RegressionMode,
        [Parameter(Mandatory)][string] $Appearance,
        [Parameter(Mandatory)][int] $TextScalePercent
    )

    $property = $ManifestInput.request.PSObject.Properties['layout_variant']
    if ($null -eq $property) {
        return 'command-rails'
    }
    if ($property.Value -isnot [string] -or
        $property.Value -cnotin @('command-rails', 'native-menu-only')) {
        throw 'Regression layout variant is invalid.'
    }
    $variant = [string]$property.Value
    if ($variant -ceq 'native-menu-only') {
        $desktop = $ManifestInput.request.PSObject.Properties['desktop']
        if ($Verified.lane -cne 'candidate-gui-only' -or
            $RegressionMode -cne 'text-scale' -or
            $Appearance -cne 'light' -or
            $TextScalePercent -ne 150 -or
            $null -eq $desktop -or
            $desktop.Value.width -ne 800 -or
            $desktop.Value.height -ne 600 -or
            $desktop.Value.dpi -ne 96) {
            throw 'Native-menu-only is restricted to the fixed text-150 cell.'
        }
    }
    $variant
}
function Assert-GuiRegressionGuestPreflightBinding {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual
    )

    $expectedNames = @(
        'architecture', 'build', 'os_version', 'product_caption', 'system',
        'vm_identity_kind', 'vm_identity_sha256'
    )
    $normalize = {
        param([object] $Record)

        $names = if ($Record -is [Collections.IDictionary]) {
            @($Record.Keys | ForEach-Object { [string]$_ })
        }
        else {
            @($Record.PSObject.Properties.Name)
        }
        if ($names.Count -ne $expectedNames.Count -or
            @(Compare-Object -CaseSensitive $expectedNames $names).Count -ne 0) {
            throw 'Guest platform or VM identity differs from immutable preflight.'
        }
        $normalized = [ordered]@{}
        foreach ($name in $expectedNames) {
            $value = if ($Record -is [Collections.IDictionary]) {
                $Record[$name]
            }
            else {
                $Record.PSObject.Properties[$name].Value
            }
            if ($value -isnot [string]) {
                throw 'Guest platform or VM identity differs from immutable preflight.'
            }
            $normalized[$name] = $value
        }
        [pscustomobject]$normalized
    }
    $expectedRecord = & $normalize $Expected
    $actualRecord = & $normalize $Actual
    foreach ($name in $expectedNames) {
        if (-not [string]::Equals(
                $expectedRecord.$name,
                $actualRecord.$name,
                [StringComparison]::Ordinal
            )) {
            throw 'Guest platform or VM identity differs from immutable preflight.'
        }
    }
}
function New-GuiRegressionResult {
    param(
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $Appearance
    )

    $result = [ordered]@{
        schema_version = if ($Verified.lane -ceq 'candidate-gui-only') { 2 } else { 1 }
        target = $Verified.target
        application = [ordered]@{
            file = $Verified.application.file
            sha256 = $Verified.application.sha256
        }
    }
    if ($Verified.lane -ceq 'candidate-gui-only') {
        $result['lane'] = $Verified.lane
        $result['product'] = $Verified.product
        $result['harness'] = $Verified.harness
        $result['observer_role'] = 'ui'
        $result['raw_layout_runs'] = @()
        $result['raw_text_scale'] = $null
        $result['raw_cleanup'] = $null
    }
    else {
        $result['source_sha'] = $Verified.source_sha
    }
    $result['runner_sha256'] = $Verified.runner_sha256
    $result['acceptance_script_sha256'] = $Verified.script_sha256
    $result['appearance'] = [ordered]@{ requested = $Appearance; observed = $null }
    $result['status'] = 'failed'
    $result['visual_review'] = 'required'
    $result['keyboard'] = [ordered]@{ status = 'failed' }
    $result['accessibility'] = [ordered]@{ status = 'failed' }
    $result['capture'] = [ordered]@{ status = 'failed' }
    $result['assertions'] = [ordered]@{ overall = 'failed'; scenario = $null }
    $result['text_scale'] = $null
    $result['process_cleanup'] = $false
    $result['guest_cleanup'] = $false
    $result['screenshots'] = @()
    $result['failure_reason'] = 'setup_failed'
    $result['diagnostic'] = $null
    $result
}
function Invoke-GuiRegressionAcceptance {
    $resolved = Resolve-AcceptanceBundle `
        -Root $BundleRoot `
        -ScriptPath $EntryPointPath `
        -ScriptSha256 $ExpectedScriptSha256 `
        -RequestedOutputRoot $OutputRoot `
        -SessionId $ExpectedSessionId `
        -AllowExistingOutput:$RestoreTextScaleOnly
    $bundleManifest = Get-Content `
        -LiteralPath (Join-Path $resolved.root 'bundle.json') `
        -Raw | ConvertFrom-Json
    $verified = [pscustomobject]@{
        root = $resolved.root
        output_root = $resolved.output_root
        manifest = $bundleManifest
        application = $resolved.application
        lane = $resolved.lane
    }
    $inputItem = Get-Item -LiteralPath $InputManifestPath -Force -ErrorAction Stop
    $expectedInput = Join-Path (Split-Path -Parent $resolved.root) 'input-manifest.json'
    if ($inputItem.PSIsContainer -or
        ($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::Equals(
            $inputItem.FullName,
            $expectedInput,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Regression input manifest is not the staged ordinary manifest.'
    }
    $input = Get-Content -LiteralPath $inputItem.FullName -Raw | ConvertFrom-Json
    $inputHash = Get-LowerSha256 -Path $inputItem.FullName
    Assert-GuiRegressionInvocationBinding `
        -ManifestInput $input `
        -Verified $resolved `
        -RegressionMode $RegressionMode `
        -Appearance $Appearance `
        -TextScalePercent $TextScalePercent `
        -ExpectedScriptSha256 $ExpectedScriptSha256
    if ($ValidateOnly) {
        Write-Host "Validated GUI regression observer for source $($input.source_sha)."
        return
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'GUI regression observation requires Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'GUI regression observation must run non-elevated.'
    }
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($session -ne $ExpectedSessionId) {
        throw 'GUI regression observer is running in an unexpected desktop session.'
    }
    if ($RestoreTextScaleOnly) {
        Invoke-TextScaleRescue `
            -Verified ([pscustomobject]@{
                output_root = $resolved.output_root
                source_sha = $input.source_sha
                script_sha256 = $ExpectedScriptSha256
            }) `
            -SessionId $session
        return
    }

    [void](New-Item -ItemType Directory -Path $resolved.output_root)
    $guestId = ([guid](Get-ItemProperty `
        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' `
        -Name VirtualMachineId).VirtualMachineId).ToString('D').ToLowerInvariant()
    $guest = [ordered]@{
        system = 'windows'
        product_caption = (Get-CimInstance Win32_OperatingSystem).Caption
        os_version = [Environment]::OSVersion.VersionString
        build = [Environment]::OSVersion.Version.Build.ToString()
        architecture = 'x86_64'
        vm_identity_kind = 'hyper-v-guest-parameters-virtual-machine-id-v1'
        vm_identity_sha256 = Get-LowerTextSha256 -Value $guestId
    }
    Assert-GuiRegressionGuestPreflightBinding `
        -Expected $input.guest_preflight `
        -Actual $guest
    Write-JsonUtf8Bom `
        -Path (Join-Path $resolved.output_root 'platform-preflight.json') `
        -Value ([ordered]@{
            schema_version = 1
            run_id = $input.run_id
            input_manifest_sha256 = $inputHash
            phase = 'pre-launch'
            source_sha = $input.source_sha
            application_sha256 = $input.artifacts.application.sha256
            runner_sha256 = $input.artifacts.runner.sha256
            observer_sha256 = $input.artifacts.observer.sha256
            guest_platform = $guest
        })

    $scenarioMode = if ($RegressionMode -eq 'full-context') {
        'context'
    }
    elseif ($RegressionMode -eq 'tooltip') {
        'context-surface'
    }
    else {
        'standard'
    }
    $fullContextReference = if ($RegressionMode -eq 'tooltip') {
        [string]$input.full_context_reference.run_id
    }
    else {
        ''
    }
    $script:contract = [pscustomobject]@{
        role = 'after'
        mode = $scenarioMode
        observer = $Appearance
        expected_dpi = [int]$input.request.desktop.dpi
        expected_text_scale_percent = $TextScalePercent
        layout_variant = Resolve-GuiRegressionLayoutVariant `
            -ManifestInput $input `
            -Verified $resolved `
            -RegressionMode $RegressionMode `
            -Appearance $Appearance `
            -TextScalePercent $TextScalePercent
        requested_small_workspace = $input.request.desktop
        tooltip_regression = $RegressionMode -eq 'tooltip'
        source_sha = $input.source_sha
        application_sha256 = $input.artifacts.application.sha256
        runner_sha256 = $input.artifacts.runner.sha256
        full_context_reference = $fullContextReference
        fixture_variant = 'canonical'
    }
    $captures = [Collections.Generic.List[object]]::new()
    $desktopLock = $null
    $executionState = $null
    $runtimeRoot = $null
    $runtimeCleaned = $false
    $rawRegressionJournalAfter = $null
    $rawRegressionJournalObserved = $false
    $rawRegressionRuntimeRootAfter = $null
    $cursor = $null
    $textOriginal = $null
    $textAcceptance = $null
    $textChanged = $false
    $resultPath = Join-Path $resolved.output_root 'acceptance-result.json'
    $observationPath = Join-Path $resolved.output_root 'acceptance-observations.json'
    $diagnosticPath = Join-Path $resolved.output_root 'acceptance-error.txt'
    $result = New-GuiRegressionResult -Verified $resolved -Appearance $Appearance
    $rawRegression = $resolved.lane -ceq 'candidate-gui-only'
    $observations = [ordered]@{
        foreground_activation = $script:acceptanceForegroundObservations
        schema_version = 1
        run_id = $input.run_id
        environment = $null
        scenario = $null
    }
    try {
        $desktopLock = Enter-DesktopTestLock -SessionId $session
        if ($null -eq $desktopLock) {
            throw 'Interactive desktop lock is held.'
        }
        $executionState = Enter-TestExecutionState
        Initialize-NativeCapture
        Initialize-AcceptanceNative
        if (-not [DarkReNamerVmNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
            throw 'Windows refused Per-Monitor-V2 awareness.'
        }
        if ($RegressionMode -eq 'text-scale') {
            Initialize-TextScaleNative
            $textOriginal = Get-TextScaleSnapshot
            $snapshotPath = Join-Path $resolved.output_root 'text-scale-snapshot.json'
            $activationPath = Join-Path $resolved.output_root 'text-scale-activation.json'
            Write-JsonUtf8Bom -Path $snapshotPath -Value ([ordered]@{
                schema_version = 1
                source_sha = $input.source_sha
                acceptance_script_sha256 = $ExpectedScriptSha256
                restoration_required = $true
                original = ConvertTo-TextScaleDocumentSnapshot $textOriginal
                restoration_verified = $false
                restored = $null
            })
            $textChanged = $true
            Set-TextScale150 -Original $textOriginal
            $textAcceptance = Wait-TextScaleSnapshot `
                -Label '150 percent text activation' `
                -ObservationPath $activationPath `
                -SourceSha $input.source_sha `
                -ScriptSha256 $ExpectedScriptSha256 `
                -Accept { param($value) $value.UiPercent -eq 150 }
        }
        $cursor = [DarkReNamerVmAcceptanceNative]::ReadCursor()
        $runtimeRoot = New-PrivateDirectory `
            -Parent (Split-Path -Parent $resolved.output_root) `
            -Leaf 'observer-runtime'
        Invoke-WithIsolatedEnvironment -RuntimeRoot $runtimeRoot -Action {
            if ($RegressionMode -in @('standard', 'text-scale')) {
                $scenario = Invoke-ObserverStandardScenario `
                    -Verified $verified `
                    -RuntimeRoot $runtimeRoot `
                    -EvidenceRoot $resolved.output_root `
                    -Appearance $Appearance `
                    -SessionId $session `
                    -WaitSeconds $TimeoutSeconds `
                    -Captures $captures
            }
            else {
                $scenario = Invoke-ObserverContextScenario `
                    -Verified $verified `
                    -RuntimeRoot $runtimeRoot `
                    -EvidenceRoot $resolved.output_root `
                    -Appearance $Appearance `
                    -SessionId $session `
                    -WaitSeconds $TimeoutSeconds `
                    -Captures $captures
            }
            if ($RegressionMode -eq 'text-scale') {
                $scenario['limitations'] = @('native-taskdialog-text-scale-not-observed')
            }
            if ($scenario -is [Collections.IDictionary]) {
                if ($rawRegression) {
                    $result.raw_layout_runs = @($scenario.raw_layout_runs)
                }
                [void]$scenario.Remove('raw_layout_runs')
            }
            $observations.environment = $scenario.environment
            $observations.scenario = $scenario
            if ($RegressionMode -in @('standard', 'text-scale')) {
                $observations['text_raster_targets'] = $scenario.text_raster_targets
            }
            $result.appearance.observed = $scenario.appearance
            $result.assertions.scenario = $scenario
        }
        $result.keyboard.status = 'passed'
        $result.accessibility.status = 'passed'
        $result.capture.status = 'passed'
        $result.assertions.overall = 'passed'
        $result.status = 'review_required'
        $result.failure_reason = $null
    }
    catch {
        $result.failure_reason = 'gui_regression_observer_failed'
        [IO.File]::WriteAllText(
            $diagnosticPath,
            ($_ | Out-String -Width 4096),
            [Text.UTF8Encoding]::new($true)
        )
        $result.diagnostic = [ordered]@{
            file = 'acceptance-error.txt'
            sha256 = Get-LowerSha256 -Path $diagnosticPath
        }
    }
    finally {
        try { [DarkReNamerVmAcceptanceNative]::ReleaseObserverClipboard() } catch {}
        try { [DarkReNamerVmAcceptanceNative]::ReleaseAllButtons() } catch {}
        if ($null -ne $cursor) {
            try { [DarkReNamerVmAcceptanceNative]::MoveCursor($cursor.X, $cursor.Y) } catch {}
        }
        if ($rawRegression -and $null -ne $runtimeRoot) {
            try {
                $rawRegressionJournalAfter = @(Get-VmAutomatedJournalInventory `
                    -LocalAppData (Join-Path $runtimeRoot 'localappdata'))
                $rawRegressionJournalObserved = $true
            }
            catch {
                $result.status = 'failed'
                $result.failure_reason = 'raw_journal_observation_failed'
            }
        }
        if ($null -ne $runtimeRoot -and (Test-Path -LiteralPath $runtimeRoot)) {
            try {
                [void](Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot)
                Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
                $runtimeCleaned = -not (Test-Path -LiteralPath $runtimeRoot)
            }
            catch {
                $result.status = 'failed'
                $result.failure_reason = 'runtime_cleanup_failed'
            }
        }
        if ($RegressionMode -eq 'text-scale' -and $null -ne $textOriginal) {
            try {
                $textRestored = if ($textChanged) {
                    Restore-TextScaleSnapshot -Expected $textOriginal
                }
                else {
                    Get-TextScaleSnapshot
                }
                $original = [ordered]@{
                    registry_value_present = [bool]$textOriginal.ValueExists
                    percent = if ($textOriginal.ValueExists) { [int]$textOriginal.UiPercent } else { $null }
                }
                $restored = [ordered]@{
                    registry_value_present = [bool]$textRestored.ValueExists
                    percent = if ($textRestored.ValueExists) { [int]$textRestored.UiPercent } else { $null }
                }
                Write-JsonUtf8Bom -Path $snapshotPath -Value ([ordered]@{
                    schema_version = 1
                    source_sha = $input.source_sha
                    acceptance_script_sha256 = $ExpectedScriptSha256
                    restoration_required = $true
                    original = ConvertTo-TextScaleDocumentSnapshot $textOriginal
                    restoration_verified = $true
                    restored = ConvertTo-TextScaleDocumentSnapshot $textRestored
                })
                $snapshot = [ordered]@{
                    file = 'text-scale-snapshot.json'
                    sha256 = Get-LowerSha256 -Path $snapshotPath
                }
                $activation = [ordered]@{
                    file = 'text-scale-activation.json'
                    sha256 = Get-LowerSha256 -Path $activationPath
                }
                Write-JsonUtf8Bom `
                    -Path (Join-Path $resolved.output_root 'text-scale-restoration.json') `
                    -Value ([ordered]@{
                        schema_version = 1
                        run_id = $input.run_id
                        input_manifest_sha256 = $inputHash
                        status = 'verified'
                        original = $original
                        restored = $restored
                        snapshot = $snapshot
                        activation_attempt = $activation
                    })
                $result.text_scale = [ordered]@{
                    requested_percent = 150
                    registry_percent = 150
                    acceptance_percent = [int]$textAcceptance.UiPercent
                    original = $original
                    restoration = 'verified'
                    snapshot = $snapshot
                    activation_attempt = $activation
                }
                if ($rawRegression) {
                    $restorationArtifact = [ordered]@{
                        file = 'text-scale-restoration.json'
                        sha256 = Get-LowerSha256 -Path (Join-Path $resolved.output_root 'text-scale-restoration.json')
                    }
                    $result.raw_text_scale = [ordered]@{
                        original = ConvertTo-TextScaleDocumentSnapshot $textOriginal
                        active = ConvertTo-TextScaleDocumentSnapshot $textAcceptance
                        active_winrt_percent = [int]$observations.scenario.environment.text_scale_factor_percent
                        restored = ConvertTo-TextScaleDocumentSnapshot $textRestored
                        snapshot = $snapshot
                        activation = $activation
                        restoration = $restorationArtifact
                    }
                }
            }
            catch {
                $result.status = 'failed'
                $result.failure_reason = 'text_scale_restore_failed'
            }
        }
        try { Exit-TestExecutionState -Previous $executionState }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'execution_state_restore_failed'
        }
        try { Exit-DesktopTestLock -Lock $desktopLock }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'desktop_lock_release_failed'
        }
        $result.process_cleanup = $runtimeCleaned
        $result.guest_cleanup = $runtimeCleaned
        if ($rawRegression) {
            $ownedAfter = @(Get-VmAutomatedOwnedProcessInventory -Root $resolved.root)
            try {
                $rawRegressionRuntimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot
            }
            catch {
                $result.status = 'failed'
                $result.failure_reason = 'raw_cleanup_observation_failed'
            }
            $result.raw_cleanup = [ordered]@{
                owned_processes_after = $ownedAfter
                runtime_root_after = $rawRegressionRuntimeRootAfter
                journal_after = (New-VmAutomatedJournalCleanupObservation `
                    -Observed $rawRegressionJournalObserved `
                    -Entries $rawRegressionJournalAfter)
            }
            if ($ownedAfter.Count -ne 0 -or -not $runtimeCleaned) {
                $result.status = 'failed'
                $result.failure_reason = 'raw_cleanup_failed'
            }
        }
        $result.screenshots = $captures.ToArray()
        Write-JsonUtf8Bom -Path $observationPath -Value $observations
        Write-JsonUtf8Bom -Path $resultPath -Value $result
    }
    if ($result.status -ne 'review_required') {
        throw 'GUI regression observation failed; inspect output.'
    }
    Write-Host 'Captured GUI regression evidence; visual review remains required.'
}
