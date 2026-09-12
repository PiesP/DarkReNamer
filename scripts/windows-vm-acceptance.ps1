[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BundleRoot,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $ExpectedSessionId,
    [Parameter(Mandatory)][string] $OutputRoot,
    [Parameter(Mandatory)][string] $ExpectedScriptSha256,
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 60,
    [ValidateSet('system', 'light', 'dark')][string] $Appearance = 'system',
    [switch] $CaptureNativeMenu,
    [switch] $CaptureAdvancedAppearance,
    [switch] $Clipboard,
    [switch] $HighContrast,
    [switch] $RestoreHighContrastOnly,
    [ValidateSet('full-context', 'standard', 'text-scale', 'tooltip')]
    [string] $RegressionMode,
    [string] $InputManifestPath,
    [ValidateSet(100, 150)][int] $TextScalePercent = 100,
    [switch] $RestoreTextScaleOnly,
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AcceptanceBootstrap {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][string] $ScriptSha256
    )

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be an absolute directory.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BundleRoot must be an ordinary directory.'
    }
    $resolvedRoot = $rootItem.FullName
    $bundleParent = [IO.Directory]::GetParent($resolvedRoot).FullName
    $expectedScriptPath = Join-Path $bundleParent 'windows-vm-acceptance.ps1'
    $scriptItem = Get-Item -LiteralPath $ScriptPath -Force -ErrorAction Stop
    if ($scriptItem.PSIsContainer -or
        ($scriptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::Equals(
            $scriptItem.FullName,
            $expectedScriptPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'The invoked acceptance script must be the task-bundled acceptance artifact.'
    }
    if ($ScriptSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        (Get-FileHash -LiteralPath $scriptItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne
            $ScriptSha256) {
        throw 'Acceptance script hash mismatch.'
    }

    $manifestPath = Join-Path $resolvedRoot 'bundle.json'
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if ($manifestItem.PSIsContainer -or
        ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $manifestItem.Length -gt 1MB) {
        throw 'bundle.json must be an ordinary bounded file.'
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw 'bundle.json is not valid JSON.'
    }
    if ($manifest.runner.file -cne 'windows-vm-guest.ps1' -or
        $manifest.runner.sha256 -isnot [string] -or
        $manifest.runner.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'bundle.json runner binding is invalid.'
    }
    $runnerPath = Join-Path $resolvedRoot 'windows-vm-guest.ps1'
    $runnerItem = Get-Item -LiteralPath $runnerPath -Force -ErrorAction Stop
    if ($runnerItem.PSIsContainer -or
        ($runnerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
            $manifest.runner.sha256) {
        throw 'Windows VM helper hash mismatch.'
    }
    [pscustomobject]@{ root = $resolvedRoot; runner = $runnerPath }
}

function Resolve-AcceptanceBundle {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][string] $ScriptSha256,
        [Parameter(Mandatory)][string] $RequestedOutputRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [switch] $AllowExistingOutput
    )

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be an absolute directory.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BundleRoot must be an ordinary directory.'
    }
    $resolvedRoot = $rootItem.FullName
    $bundleParent = [IO.Directory]::GetParent($resolvedRoot).FullName
    $expectedScriptPath = Join-Path $bundleParent 'windows-vm-acceptance.ps1'
    $actualScriptPath = (Get-Item -LiteralPath $ScriptPath -Force -ErrorAction Stop).FullName
    if (-not [string]::Equals(
        $actualScriptPath,
        $expectedScriptPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The invoked acceptance script must be the task-bundled acceptance artifact.'
    }
    if ($ScriptSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'ExpectedScriptSha256 must be a lowercase SHA-256 digest.'
    }
    Assert-OrdinaryFile -Path $actualScriptPath -Label 'acceptance script'
    if ((Get-LowerSha256 -Path $actualScriptPath) -cne $ScriptSha256) {
        throw 'Acceptance script hash mismatch.'
    }

    $runnerPath = Join-Path $resolvedRoot 'windows-vm-guest.ps1'
    Assert-OrdinaryFile -Path $runnerPath -Label 'Windows VM helper'
    . $runnerPath -BundleRoot $resolvedRoot -ExpectedSessionId $SessionId -ValidateOnly
    $verified = Resolve-VerifiedBundle -Root $resolvedRoot -InvokedScriptPath $runnerPath
    if ($verified.manifest.source_state -cne 'clean') {
        throw 'A clean source-bound bundle is required for acceptance evidence.'
    }
    if (-not [IO.Path]::IsPathRooted($RequestedOutputRoot)) {
        throw 'OutputRoot must be an absolute directory path.'
    }
    $outputRoot = [IO.Path]::GetFullPath($RequestedOutputRoot)
    $expectedOutputRoot = Join-Path $bundleParent 'out'
    if (-not [string]::Equals(
        $outputRoot,
        $expectedOutputRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'OutputRoot must be the task bundle out directory.'
    }
    $outputExists = Test-Path -LiteralPath $outputRoot
    if ($AllowExistingOutput) {
        if (-not $outputExists) {
            throw 'High Contrast rescue requires the existing task bundle out directory.'
        }
        $outputItem = Get-Item -LiteralPath $outputRoot -Force
        if (-not $outputItem.PSIsContainer -or
            ($outputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'High Contrast rescue output must be an ordinary directory.'
        }
    }
    elseif ($outputExists) {
        throw 'The acceptance output directory already exists; preserve it and use a new bundle.'
    }
    [pscustomobject]@{
        root = $resolvedRoot
        output_root = $outputRoot
        application = $verified.manifest.application
        source_sha = $verified.manifest.source_sha
        target = $verified.manifest.target
        runner_sha256 = $verified.manifest.runner.sha256
        script_sha256 = $ScriptSha256
    }
}

function Get-AcceptanceVerdict {
    param(
        [Parameter(Mandatory)][string] $KeyboardStatus,
        [Parameter(Mandatory)][string] $AccessibilityStatus,
        [Parameter(Mandatory)][string] $CaptureStatus
    )

    $statuses = @($KeyboardStatus, $AccessibilityStatus, $CaptureStatus)
    if (@($statuses | Where-Object { $_ -notin @('passed', 'failed', 'not_run') }).Count -ne 0) {
        throw 'Acceptance lane status is invalid.'
    }
    if ($statuses -contains 'failed') {
        return 'failed'
    }
    if (@($statuses | Where-Object { $_ -cne 'passed' }).Count -eq 0) {
        return 'review_required'
    }
    'not_run'
}

function Test-HighContrastSnapshotEqual {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual
    )

    if (-not (Test-HighContrastIdentityEqual -Expected $Expected -Actual $Actual)) {
        return $false
    }
    foreach ($name in @(
        'Window','WindowText','ButtonFace','ButtonText',
        'Highlight','HighlightText','GrayText','HotLight'
    )) {
        if ($Expected.$name -ne $Actual.$name) {
            return $false
        }
    }
    $true
}

function Test-HighContrastIdentityEqual {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual
    )

    if ($Expected.Flags -ne $Actual.Flags -or
        -not [string]::Equals(
            [string]$Expected.Scheme,
            [string]$Actual.Scheme,
            [StringComparison]::Ordinal
        )) {
        return $false
    }
    foreach ($name in @(
        'ThemePath','ThemeColor','ThemeSize'
    )) {
        if (-not [string]::Equals(
            [string]$Expected.$name,
            [string]$Actual.$name,
            [StringComparison]::Ordinal
        )) {
            return $false
        }
    }
    $true
}

function Test-HighContrastColorsEqual {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual
    )

    foreach ($name in @(
        'Window','WindowText','ButtonFace','ButtonText',
        'Highlight','HighlightText','GrayText','HotLight'
    )) {
        if ($Expected.$name -ne $Actual.$name) {
            return $false
        }
    }
    $true
}

function Wait-HighContrastSettlement {
    param(
        [Parameter(Mandatory)][scriptblock] $ReadSnapshot,
        [Parameter(Mandatory)][scriptblock] $AcceptSnapshot,
        [Parameter(Mandatory)][string] $Label,
        [ValidateRange(2, 64)][int] $MaximumAttempts = 50,
        [ValidateRange(0, 1000)][int] $PollMilliseconds = 200,
        [ValidateRange(2, 4)][int] $StableReads = 2
    )

    $previous = $null
    $stable = 0
    for ($attempt = 0; $attempt -lt $MaximumAttempts; $attempt++) {
        $snapshot = & $ReadSnapshot
        if (& $AcceptSnapshot $snapshot) {
            if ($null -ne $previous -and
                (Test-HighContrastSnapshotEqual -Expected $previous -Actual $snapshot)) {
                $stable++
            }
            else {
                $stable = 1
            }
            $previous = $snapshot
            if ($stable -ge $StableReads) {
                return $snapshot
            }
        }
        else {
            $previous = $null
            $stable = 0
        }
        if ($attempt + 1 -lt $MaximumAttempts -and $PollMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }
    throw "$Label did not settle within the bounded observation attempts."
}

function Wait-HighContrastRestoration {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][scriptblock] $ReadSnapshot,
        [scriptblock] $SetCapturedColors = {
            param($snapshot)
            [DarkReNamerVmAcceptanceNative]::SetHighContrastColors(
                $snapshot.Window,
                $snapshot.WindowText,
                $snapshot.ButtonFace,
                $snapshot.ButtonText,
                $snapshot.Highlight,
                $snapshot.HighlightText,
                $snapshot.GrayText,
                $snapshot.HotLight
            )
        },
        [Parameter(Mandatory)][string] $Label,
        [switch] $AllowPaletteRestore,
        [string] $DiagnosticPath,
        [ValidateRange(2, 50)][int] $MaximumAttempts = 50,
        [ValidateRange(2, 24)][int] $FallbackAttempts = 24,
        [ValidateRange(0, 1000)][int] $PollMilliseconds = 200
    )

    $restorationObservationState = [pscustomobject]@{
        read_snapshot = $ReadSnapshot
        expected = $Expected
        observed = [Collections.Generic.List[object]]::new()
        observations = [Collections.Generic.List[object]]::new()
        phase = 'initial'
        callback_error = $false
    }
    $observingRead = {
        $observedUtc = [DateTime]::UtcNow.ToString('o')
        try {
            $snapshot = & $restorationObservationState.read_snapshot
            $restorationObservationState.observed.Add($snapshot)
            $restorationObservationState.observations.Add([ordered]@{
                utc = $observedUtc
                phase = $restorationObservationState.phase
                snapshot = $snapshot
            })
            $snapshot
        }
        catch {
            $restorationObservationState.callback_error = $true
            throw
        }
    }
    $acceptExpected = {
        param($candidate)
        try {
            Test-HighContrastSnapshotEqual `
                -Expected $restorationObservationState.expected `
                -Actual $candidate
        }
        catch {
            $restorationObservationState.callback_error = $true
            throw
        }
    }
    try {
        $initialFailure = $null
        try {
            return Wait-HighContrastSettlement `
                -ReadSnapshot $observingRead `
                -AcceptSnapshot $acceptExpected `
                -Label $Label `
                -MaximumAttempts $MaximumAttempts `
                -PollMilliseconds $PollMilliseconds
        }
        catch {
            $initialFailure = $_
        }
        if ($restorationObservationState.callback_error -or
            $initialFailure.Exception.Message -cne "$Label did not settle within the bounded observation attempts." -or
            -not $AllowPaletteRestore -or
            $restorationObservationState.observed.Count -lt 2) {
            throw $initialFailure
        }
        $previous = $restorationObservationState.observed[
            $restorationObservationState.observed.Count - 2
        ]
        $last = $restorationObservationState.observed[
            $restorationObservationState.observed.Count - 1
        ]
        if (-not (Test-HighContrastSnapshotEqual -Expected $previous -Actual $last) -or
            -not (Test-HighContrastIdentityEqual -Expected $Expected -Actual $last) -or
            (Test-HighContrastColorsEqual -Expected $Expected -Actual $last)) {
            throw $initialFailure
        }
        $restorationObservationState.phase = 'palette_fallback'
        [void](& $SetCapturedColors $Expected)
        Wait-HighContrastSettlement `
            -ReadSnapshot $observingRead `
            -AcceptSnapshot {
                param($candidate)
                Test-HighContrastSnapshotEqual -Expected $Expected -Actual $candidate
            } `
            -Label "$Label palette fallback" `
            -MaximumAttempts $FallbackAttempts `
            -PollMilliseconds $PollMilliseconds
    }
    catch {
        $failure = $_
        if (-not [string]::IsNullOrWhiteSpace($DiagnosticPath)) {
            # Preserve bounded failed observations only in the existing private
            # error artifact; public acceptance records retain its hash.
            try {
                $baseException = $failure.Exception.GetBaseException()
                $observations = @($restorationObservationState.observations | ForEach-Object {
                    [ordered]@{
                        utc = $_.utc
                        phase = $_.phase
                        snapshot = ConvertTo-HighContrastDocumentSnapshot -Snapshot $_.snapshot
                    }
                })
                [ordered]@{
                    kind = 'high_contrast_restoration_observations'
                    utc = [DateTime]::UtcNow.ToString('o')
                    label = $Label
                    phase = $restorationObservationState.phase
                    expected = ConvertTo-HighContrastDocumentSnapshot -Snapshot $Expected
                    observations = $observations
                    error = [ordered]@{
                        outer_type = $failure.Exception.GetType().FullName
                        outer_hresult = $failure.Exception.HResult
                        base_type = $baseException.GetType().FullName
                        base_hresult = $baseException.HResult
                        native_error_code = if ($baseException -is [ComponentModel.Win32Exception]) {
                            $baseException.NativeErrorCode
                        }
                        else { $null }
                    }
                } | ConvertTo-Json -Depth 10 | Add-Content -LiteralPath $DiagnosticPath -Encoding UTF8
            }
            catch {
                # Diagnostic failure must not replace the original restoration error.
            }
        }
        throw $failure
    }
}

function ConvertTo-HighContrastDocumentSnapshot {
    param([Parameter(Mandatory)][object] $Snapshot)

    [ordered]@{
        flags = $Snapshot.Flags
        scheme = $Snapshot.Scheme
        colors = [ordered]@{
            window = $Snapshot.Window
            window_text = $Snapshot.WindowText
            button_face = $Snapshot.ButtonFace
            button_text = $Snapshot.ButtonText
            highlight = $Snapshot.Highlight
            highlight_text = $Snapshot.HighlightText
            gray_text = $Snapshot.GrayText
            hot_light = $Snapshot.HotLight
        }
        visual_style = [ordered]@{
            path = $Snapshot.ThemePath
            color = $Snapshot.ThemeColor
            size = $Snapshot.ThemeSize
        }
    }
}

function ConvertFrom-HighContrastDocumentSnapshot {
    param(
        [Parameter(Mandatory)][object] $Document,
        [Parameter(Mandatory)][string] $Label
    )

    $expectedNames = @('colors','flags','scheme','visual_style')
    $actualNames = @($Document.PSObject.Properties.Name | Sort-Object)
    $fieldDifferences = @(Compare-Object -CaseSensitive $expectedNames $actualNames)
    if ($actualNames.Count -ne $expectedNames.Count -or
        $fieldDifferences.Count -ne 0) {
        throw "High Contrast restore snapshot $Label fields are invalid."
    }
    if (($Document.flags -isnot [int] -and $Document.flags -isnot [long]) -or
        ($null -ne $Document.scheme -and $Document.scheme -isnot [string])) {
        throw "High Contrast restore snapshot $Label settings are invalid."
    }
    $colors = $Document.colors
    $expectedColorNames = @(
        'button_face','button_text','gray_text','highlight',
        'highlight_text','hot_light','window','window_text'
    )
    $actualColorNames = @($colors.PSObject.Properties.Name | Sort-Object)
    $colorDifferences = @(Compare-Object -CaseSensitive $expectedColorNames $actualColorNames)
    if ($actualColorNames.Count -ne $expectedColorNames.Count -or
        $colorDifferences.Count -ne 0) {
        throw "High Contrast restore snapshot $Label colors are incomplete."
    }
    foreach ($name in $expectedColorNames) {
        if ($colors.$name -isnot [int] -and $colors.$name -isnot [long]) {
            throw "High Contrast restore snapshot $Label colors are invalid."
        }
    }
    $visualStyle = $Document.visual_style
    $expectedVisualStyleNames = @('color','path','size')
    $actualVisualStyleNames = @($visualStyle.PSObject.Properties.Name | Sort-Object)
    $visualStyleDifferences = @(Compare-Object -CaseSensitive $expectedVisualStyleNames $actualVisualStyleNames)
    if ($actualVisualStyleNames.Count -ne $expectedVisualStyleNames.Count -or
        $visualStyleDifferences.Count -ne 0 -or
        $visualStyle.path -isnot [string] -or
        $visualStyle.path -cnotmatch '^(?:[A-Za-z]:\\|\\\\)' -or
        $visualStyle.path.Length -gt 510 -or $visualStyle.path -match '[\x00-\x1f]' -or
        $visualStyle.color -isnot [string] -or [string]::IsNullOrWhiteSpace($visualStyle.color) -or
        $visualStyle.color.Length -gt 126 -or $visualStyle.color -match '[\x00-\x1f]' -or
        $visualStyle.size -isnot [string] -or [string]::IsNullOrWhiteSpace($visualStyle.size) -or
        $visualStyle.size.Length -gt 126 -or $visualStyle.size -match '[\x00-\x1f]') {
        throw "High Contrast restore snapshot $Label visual style is invalid."
    }
    [pscustomobject]@{
        Flags = [uint32]$Document.flags
        Scheme = $Document.scheme
        Window = [uint32]$colors.window
        WindowText = [uint32]$colors.window_text
        ButtonFace = [uint32]$colors.button_face
        ButtonText = [uint32]$colors.button_text
        Highlight = [uint32]$colors.highlight
        HighlightText = [uint32]$colors.highlight_text
        GrayText = [uint32]$colors.gray_text
        HotLight = [uint32]$colors.hot_light
        ThemePath = $visualStyle.path
        ThemeColor = $visualStyle.color
        ThemeSize = $visualStyle.size
    }
}

function Resolve-HighContrastRestoreDocument {
    param(
        [Parameter(Mandatory)][string] $OutputDirectory,
        [Parameter(Mandatory)][string] $SourceSha,
        [Parameter(Mandatory)][string] $ScriptSha256
    )

    $path = Join-Path $OutputDirectory 'high-contrast-restore.json'
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt 1MB) {
        throw 'High Contrast restore snapshot must be an ordinary bounded file.'
    }
    try {
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        throw 'High Contrast restore snapshot is not valid JSON.'
    }
    $expectedDocumentNames = @(
        'acceptance_script_sha256','original','restoration_required',
        'restoration_verified','restored','schema_version','source_sha'
    )
    $actualDocumentNames = @($document.PSObject.Properties.Name | Sort-Object)
    $documentDifferences = @(Compare-Object -CaseSensitive $expectedDocumentNames $actualDocumentNames)
    if ($actualDocumentNames.Count -ne $expectedDocumentNames.Count -or
        $documentDifferences.Count -ne 0) {
        throw 'High Contrast restore snapshot document fields are invalid.'
    }
    if ($document.schema_version -ne 2 -or
        $document.source_sha -cne $SourceSha -or
        $document.acceptance_script_sha256 -cne $ScriptSha256) {
        throw 'High Contrast restore snapshot binding mismatch.'
    }
    if ($document.restoration_required -isnot [bool] -or
        $document.restoration_verified -isnot [bool]) {
        throw 'High Contrast restore snapshot state is invalid.'
    }
    $expected = ConvertFrom-HighContrastDocumentSnapshot `
        -Document $document.original `
        -Label 'original'
    if (($expected.Flags -band 0x1000) -ne 0) {
        throw 'High Contrast restore snapshot contains a prohibited toggle option.'
    }
    if ($document.restoration_required) {
        if ($document.restoration_verified -or $null -ne $document.restored) {
            throw 'High Contrast restore snapshot pending state is invalid.'
        }
    }
    else {
        if (-not $document.restoration_verified -or $null -eq $document.restored) {
            throw 'High Contrast restore snapshot verified state is invalid.'
        }
        $restored = ConvertFrom-HighContrastDocumentSnapshot `
            -Document $document.restored `
            -Label 'restored'
        if (-not (Test-HighContrastSnapshotEqual -Expected $expected -Actual $restored)) {
            throw 'High Contrast restore snapshot restored state differs from the original.'
        }
    }
    [pscustomobject]@{ path = $path; document = $document; expected = $expected }
}

function Invoke-HighContrastRescue {
    param(
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][int] $SessionId
    )

    $restore = Resolve-HighContrastRestoreDocument `
        -OutputDirectory $Verified.output_root `
        -SourceSha $Verified.source_sha `
        -ScriptSha256 $Verified.script_sha256
    $resultPath = Join-Path $Verified.output_root 'high-contrast-rescue-result.json'
    $errorPath = Join-Path $Verified.output_root 'high-contrast-rescue-error.txt'
    $result = [ordered]@{
        schema_version = 1
        source_sha = $Verified.source_sha
        acceptance_script_sha256 = $Verified.script_sha256
        status = 'failed'
        action = $null
        restoration_verified = $false
        snapshot_sha256 = Get-LowerSha256 -Path $restore.path
        failure_reason = 'restore_failed'
        diagnostic = $null
    }
    $lock = $null
    try {
        $lock = Enter-DesktopTestLock -SessionId $SessionId
        if ($null -eq $lock) {
            throw 'Another Windows VM test runner is using this interactive desktop.'
        }
        Initialize-AcceptanceNative
        if (-not $restore.document.restoration_required -and
            $restore.document.restoration_verified) {
            $result.status = 'passed'
            $result.action = 'no_op_already_restored'
            $result.restoration_verified = $true
            $result.failure_reason = $null
        }
        else {
            [DarkReNamerVmAcceptanceNative]::ApplyHighContrast(
                $restore.expected.Flags,
                $restore.expected.Scheme
            )
            $actual = Wait-HighContrastRestoration `
                -Expected $restore.expected `
                -ReadSnapshot { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
                -Label 'High Contrast rescue restoration' `
                -DiagnosticPath $errorPath `
                -AllowPaletteRestore
            Write-JsonUtf8Bom -Path $restore.path -Value ([ordered]@{
                schema_version = 2
                source_sha = $Verified.source_sha
                acceptance_script_sha256 = $Verified.script_sha256
                restoration_required = $false
                original = $restore.document.original
                restoration_verified = $true
                restored = ConvertTo-HighContrastDocumentSnapshot -Snapshot $actual
            })
            $result.status = 'passed'
            $result.action = 'restored'
            $result.restoration_verified = $true
            $result.snapshot_sha256 = Get-LowerSha256 -Path $restore.path
            $result.failure_reason = $null
        }
    }
    catch {
        $_ | Out-String | Add-Content -LiteralPath $errorPath -Encoding UTF8
        $result.diagnostic = [ordered]@{
            file = 'high-contrast-rescue-error.txt'
            sha256 = Get-LowerSha256 -Path $errorPath
        }
    }
    finally {
        try {
            Exit-DesktopTestLock -Lock $lock
        }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'desktop_lock_release_failed'
            $_ | Out-String | Add-Content -LiteralPath $errorPath -Encoding UTF8
            $result.diagnostic = [ordered]@{
                file = 'high-contrast-rescue-error.txt'
                sha256 = Get-LowerSha256 -Path $errorPath
            }
        }
        Write-JsonUtf8Bom -Path $resultPath -Value $result
    }
    if ($result.status -cne 'passed') {
        throw 'High Contrast rescue failed; inspect its external result and diagnostic.'
    }
    Write-Host "High Contrast rescue completed: $($result.action)."
}

function Get-AcceptanceClipboardTextEvidence {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $bytes = [Text.Encoding]::Unicode.GetBytes($Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    [ordered]@{
        utf16le_bytes = $bytes.Length
        sha256 = -join ($digest | ForEach-Object { $_.ToString('x2') })
    }
}

function Test-AcceptanceClipboardSnapshotOwned {
    param(
        [Parameter(Mandatory)][object] $Snapshot,
        [Parameter(Mandatory)][uint32] $ExpectedSequence,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ExpectedText
    )

    if ($Snapshot.SequenceNumber -ne $ExpectedSequence -or
        -not [string]::Equals(
            [string]$Snapshot.UnicodeText,
            $ExpectedText,
            [StringComparison]::Ordinal
        )) {
        return $false
    }
    $formats = @($Snapshot.Formats)
    if ($formats.Count -eq 0 -or $formats -notcontains [uint32]13) {
        return $false
    }
    @($formats | Where-Object { $_ -notin @([uint32]1, [uint32]7, [uint32]13, [uint32]16) }).Count -eq 0
}

function Initialize-AcceptanceNative {
    if ('DarkReNamerVmAcceptanceNative' -as [type]) {
        return
    }
    Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class DarkReNamerVmAcceptanceNative {
    private const int MaxHighContrastReads = 128;
    private static int highContrastReads;
    private static readonly IntPtr[] retainedSchemePointers = new IntPtr[MaxHighContrastReads];
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    public sealed class HighContrastSnapshot {
        public uint Flags { get; set; }
        public string Scheme { get; set; }
        public uint Window { get; set; }
        public uint WindowText { get; set; }
        public uint ButtonFace { get; set; }
        public uint ButtonText { get; set; }
        public uint Highlight { get; set; }
        public uint HighlightText { get; set; }
        public uint GrayText { get; set; }
        public uint HotLight { get; set; }
        public string ThemePath { get; set; }
        public string ThemeColor { get; set; }
        public string ThemeSize { get; set; }
    }

    public sealed class ClipboardSnapshot {
        public uint SequenceNumber { get; set; }
        public uint[] Formats { get; set; }
        public string UnicodeText { get; set; }
    }

    public sealed class WindowMeasurement {
        public long Handle;
        public long Owner;
        public uint ProcessId;
        public string ClassName;
        public string Title;
        public bool Visible;
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMonitorInfo {
        public uint Size;
        public Rect Monitor;
        public Rect Work;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeScrollInfo {
        public uint Size;
        public uint Mask;
        public int Minimum;
        public int Maximum;
        public uint Page;
        public int Position;
        public int TrackPosition;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT {
        public ushort virtualKey;
        public ushort scanCode;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT {
        public int x;
        public int y;
        public uint mouseData;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION {
        [FieldOffset(0)] public KEYBDINPUT keyboard;
        [FieldOffset(0)] public MOUSEINPUT mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT {
        public uint type;
        public INPUTUNION value;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct HIGHCONTRAST {
        public uint size;
        public uint flags;
        public IntPtr scheme;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RTL_OSVERSIONINFOEX {
        public uint size;
        public uint major;
        public uint minor;
        public uint build;
        public uint platform;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string servicePack;
        public ushort servicePackMajor;
        public ushort servicePackMinor;
        public ushort suiteMask;
        public byte productType;
        public byte reserved;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    private static extern bool ReadSystemWorkArea(uint action, uint parameter, out Rect value, uint flags);
    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref NativeMonitorInfo info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowTextW(IntPtr window, StringBuilder value, int capacity);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetScrollInfo(IntPtr window, int bar, ref NativeScrollInfo info);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")]
    private static extern IntPtr GetMenu(IntPtr window);
    [DllImport("user32.dll")]
    private static extern uint GetMenuState(IntPtr menu, uint item, uint flags);
    [DllImport("user32.dll")]
    private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")]
    private static extern IntPtr GetSubMenu(IntPtr menu, int position);
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
    [DllImport("user32.dll")]
    private static extern uint GetSysColor(int index);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetSysColors(int count, int[] indices, uint[] colors);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentThemeName(
        StringBuilder themeFileName,
        int maximumNameCharacters,
        StringBuilder colorName,
        int maximumColorCharacters,
        StringBuilder sizeName,
        int maximumSizeCharacters);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")]
    private static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UIntPtr GlobalSize(IntPtr memory);
    [DllImport("kernel32.dll", EntryPoint = "SetLastError")]
    private static extern void SetLastErrorNative(uint code);
    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    private static extern int RtlGetVersion(ref RTL_OSVERSIONINFOEX version);

    private static uint[] EnumerateClipboardFormats() {
        List<uint> formats = new List<uint>();
        uint previous = 0;
        while (true) {
            SetLastErrorNative(0);
            uint current = EnumClipboardFormats(previous);
            if (current == 0) {
                int error = Marshal.GetLastWin32Error();
                if (error != 0) { throw new Win32Exception(error); }
                return formats.ToArray();
            }
            formats.Add(current);
            previous = current;
            if (formats.Count > 64) {
                throw new InvalidOperationException("Clipboard format count exceeded the acceptance bound.");
            }
        }
    }

    private static string ReadClipboardUnicodeText(uint[] formats) {
        if (Array.IndexOf(formats, 13U) < 0) { return null; }
        IntPtr memory = GetClipboardData(13);
        if (memory == IntPtr.Zero) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        ulong byteCount = GlobalSize(memory).ToUInt64();
        if (byteCount < 2 || byteCount > 2 * 1024 * 1024 || (byteCount & 1) != 0) {
            throw new InvalidOperationException("Clipboard Unicode text allocation is invalid or over limit.");
        }
        IntPtr pointer = GlobalLock(memory);
        if (pointer == IntPtr.Zero) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            string allocation = Marshal.PtrToStringUni(pointer, checked((int)(byteCount / 2)));
            int terminator = allocation.IndexOf('\0');
            if (terminator < 0) {
                throw new InvalidOperationException("Clipboard Unicode text is not terminated.");
            }
            return allocation.Substring(0, terminator);
        }
        finally {
            GlobalUnlock(memory);
        }
    }

    private static ClipboardSnapshot ReadOpenClipboardSnapshot() {
        uint sequence = GetClipboardSequenceNumber();
        uint[] formats = EnumerateClipboardFormats();
        string text = ReadClipboardUnicodeText(formats);
        if (GetClipboardSequenceNumber() != sequence) {
            throw new InvalidOperationException("Clipboard changed during one acceptance observation.");
        }
        return new ClipboardSnapshot {
            SequenceNumber = sequence,
            Formats = formats,
            UnicodeText = text
        };
    }

    public static ClipboardSnapshot ReadClipboardSnapshot() {
        if (!OpenClipboard(IntPtr.Zero)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try { return ReadOpenClipboardSnapshot(); }
        finally {
            if (!CloseClipboard()) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        }
    }

    public static string ClearClipboardIfOwned(uint expectedSequence, string expectedText) {
        if (!OpenClipboard(IntPtr.Zero)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            ClipboardSnapshot snapshot = ReadOpenClipboardSnapshot();
            if (snapshot.SequenceNumber != expectedSequence) { return "sequence_changed"; }
            if (!String.Equals(snapshot.UnicodeText, expectedText, StringComparison.Ordinal)) {
                return "text_changed";
            }
            bool unicode = false;
            foreach (uint format in snapshot.Formats) {
                if (format == 13) { unicode = true; }
                else if (format != 1 && format != 7 && format != 16) {
                    return "foreign_format";
                }
            }
            if (!unicode || snapshot.Formats.Length == 0) { return "text_format_missing"; }
            if (!EmptyClipboard()) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (EnumerateClipboardFormats().Length != 0) {
                throw new InvalidOperationException("Clipboard was not empty after guarded cleanup.");
            }
            return "cleared";
        }
        finally {
            if (!CloseClipboard()) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        }
    }

    private static void Send(ushort virtualKey, ushort scanCode, uint flags) {
        INPUT input = new INPUT {
            type = 1,
            value = new INPUTUNION {
                keyboard = new KEYBDINPUT {
                    virtualKey = virtualKey,
                    scanCode = scanCode,
                    flags = flags,
                    time = 0,
                    extraInfo = UIntPtr.Zero
                }
            }
        };
        if (SendInput(1, new [] { input }, Marshal.SizeOf(typeof(INPUT))) != 1) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void KeyDown(ushort virtualKey) { Send(virtualKey, 0, 0); }
    public static void KeyUp(ushort virtualKey) { Send(virtualKey, 0, 2); }
    public static void Tap(ushort virtualKey) { KeyDown(virtualKey); KeyUp(virtualKey); }

    public static void TypeUnicode(string value) {
        foreach (char unit in value) {
            Send(0, unit, 4);
            Send(0, unit, 4 | 2);
        }
    }

    public static void ReleaseModifiers() {
        KeyUp(0x10);
        KeyUp(0x11);
        KeyUp(0x12);
    }

    private static bool TryGetMenuCommandState(IntPtr menu, uint command, out uint state) {
        state = GetMenuState(menu, command, 0);
        if (state != UInt32.MaxValue) { return true; }
        int count = GetMenuItemCount(menu);
        if (count < 0) {
            throw new InvalidOperationException("The native menu could not be inspected.");
        }
        for (int position = 0; position < count; position++) {
            IntPtr submenu = GetSubMenu(menu, position);
            if (submenu != IntPtr.Zero && TryGetMenuCommandState(submenu, command, out state)) {
                return true;
            }
        }
        return false;
    }

    public static bool IsMenuCommandEnabled(IntPtr window, uint command) {
        IntPtr root = GetMenu(window);
        if (root == IntPtr.Zero) {
            throw new InvalidOperationException("The application window has no native menu.");
        }
        uint state;
        if (!TryGetMenuCommandState(root, command, out state)) {
            throw new InvalidOperationException("The native menu command was not found.");
        }
        return (state & 3) == 0;
    }

    public static bool IsMenuCommandChecked(IntPtr window, uint command) {
        IntPtr root = GetMenu(window);
        if (root == IntPtr.Zero) {
            throw new InvalidOperationException("The application window has no native menu.");
        }
        uint state;
        if (!TryGetMenuCommandState(root, command, out state)) {
            throw new InvalidOperationException("The native menu command was not found.");
        }
        return (state & 8) != 0;
    }

    public static void SendMenuCommand(IntPtr window, uint command) {
        SendMessageW(window, 0x0111, new IntPtr(command), IntPtr.Zero);
    }

    public static IntPtr FindVisiblePopupMenu(uint expectedProcessId) {
        IntPtr match = IntPtr.Zero;
        int matches = 0;
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            if (!IsWindowVisible(window)) { return true; }
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) { return true; }
            StringBuilder className = new StringBuilder(32);
            if (GetClassName(window, className, className.Capacity) > 0 &&
                String.Equals(className.ToString(), "#32768", StringComparison.Ordinal)) {
                match = window;
                matches++;
            }
            return true;
        }, IntPtr.Zero);
        if (matches > 1) {
            throw new InvalidOperationException("More than one visible native menu popup was found.");
        }
        return match;
    }

    public static HighContrastSnapshot GetHighContrastSnapshot() {
        int slot = System.Threading.Interlocked.Increment(ref highContrastReads) - 1;
        if (slot >= MaxHighContrastReads) {
            System.Threading.Interlocked.Decrement(ref highContrastReads);
            throw new InvalidOperationException("High Contrast snapshot read limit exceeded.");
        }
        HIGHCONTRAST value = new HIGHCONTRAST();
        value.size = (uint)Marshal.SizeOf(typeof(HIGHCONTRAST));
        if (!SystemParametersInfo(0x42, value.size, ref value, 0)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        // Treat the GET pointer as borrowed in this bounded observer. Copy it
        // synchronously without freeing it; the OS reclaims any allocation at
        // process exit. Retain at most 128 pointer values for that lifetime.
        retainedSchemePointers[slot] = value.scheme;
        const int themePathCapacity = 512;
        const int themeComponentCapacity = 128;
        StringBuilder themePath = new StringBuilder(themePathCapacity);
        StringBuilder themeColor = new StringBuilder(themeComponentCapacity);
        StringBuilder themeSize = new StringBuilder(themeComponentCapacity);
        int themeResult = GetCurrentThemeName(
            themePath,
            themePathCapacity,
            themeColor,
            themeComponentCapacity,
            themeSize,
            themeComponentCapacity);
        if (themeResult != 0) { Marshal.ThrowExceptionForHR(themeResult); }
        if (themePath.Length == 0 || themePath.Length >= themePathCapacity - 1 ||
            themeColor.Length == 0 || themeColor.Length >= themeComponentCapacity - 1 ||
            themeSize.Length == 0 || themeSize.Length >= themeComponentCapacity - 1 ||
            !System.IO.Path.IsPathRooted(themePath.ToString())) {
            throw new InvalidOperationException("The active visual-style identity is unavailable or truncated.");
        }
        return new HighContrastSnapshot {
            Flags = value.flags,
            Scheme = value.scheme == IntPtr.Zero ? null : Marshal.PtrToStringUni(value.scheme),
            Window = GetSysColor(5),
            WindowText = GetSysColor(8),
            ButtonFace = GetSysColor(15),
            ButtonText = GetSysColor(18),
            Highlight = GetSysColor(13),
            HighlightText = GetSysColor(14),
            GrayText = GetSysColor(17),
            HotLight = GetSysColor(26),
            ThemePath = themePath.ToString(),
            ThemeColor = themeColor.ToString(),
            ThemeSize = themeSize.ToString()
        };
    }

    public static bool HighContrastEnabled() {
        return (GetHighContrastSnapshot().Flags & 1) != 0;
    }

    public static void ApplyHighContrast(uint flags, string scheme) {
        IntPtr schemeBuffer = IntPtr.Zero;
        try {
            if (scheme != null) { schemeBuffer = Marshal.StringToHGlobalUni(scheme); }
            HIGHCONTRAST value = new HIGHCONTRAST {
                size = (uint)Marshal.SizeOf(typeof(HIGHCONTRAST)),
                flags = flags,
                scheme = schemeBuffer
            };
            if (!SystemParametersInfo(0x43, value.size, ref value, 0x2)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally {
            if (schemeBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(schemeBuffer); }
        }
    }

    public static void SetHighContrastColors(
        uint window,
        uint windowText,
        uint buttonFace,
        uint buttonText,
        uint highlight,
        uint highlightText,
        uint grayText,
        uint hotLight) {
        int[] indices = new int[] { 5, 8, 15, 18, 13, 14, 17, 26 };
        uint[] colors = new uint[] {
            window, windowText, buttonFace, buttonText,
            highlight, highlightText, grayText, hotLight
        };
        if (!SetSysColors(indices.Length, indices, colors)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    private static bool observerClipboardHeld;

    public static Point ReadCursor() {
        Point point;
        if (!GetCursorPos(out point)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return point;
    }

    public static void MoveCursor(int x, int y) {
        if (!SetCursorPos(x, y)) throw new Win32Exception(Marshal.GetLastWin32Error());
        Point actual = ReadCursor();
        if (actual.X != x || actual.Y != y) {
            throw new InvalidOperationException("Windows did not retain the exact observer cursor position.");
        }
    }

    private static void SendMouseButton(uint flags) {
        INPUT input = new INPUT {
            type = 0,
            value = new INPUTUNION {
                mouse = new MOUSEINPUT { flags = flags, extraInfo = UIntPtr.Zero }
            }
        };
        if (SendInput(1, new [] { input }, Marshal.SizeOf(typeof(INPUT))) != 1) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void Click() { SendMouseButton(0x0002); SendMouseButton(0x0004); }
    public static void ReleaseAllButtons() {
        SendMouseButton(0x0004); SendMouseButton(0x0010); SendMouseButton(0x0040);
    }

    public static void HoldObserverClipboard() {
        if (observerClipboardHeld) throw new InvalidOperationException("Observer Clipboard hold is already active.");
        if (!OpenClipboard(IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        observerClipboardHeld = true;
    }

    public static void ReleaseObserverClipboard() {
        if (!observerClipboardHeld) return;
        if (!CloseClipboard()) throw new Win32Exception(Marshal.GetLastWin32Error());
        observerClipboardHeld = false;
    }

    public static Rect ReadWorkArea() {
        Rect value;
        if (!ReadSystemWorkArea(0x0030, 0, out value, 0)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return value;
    }

    public static Point ReadPhysicalScreenSize() {
        Point value = new Point { X = GetSystemMetrics(0), Y = GetSystemMetrics(1) };
        if (value.X <= 0 || value.Y <= 0) {
            throw new InvalidOperationException("Windows returned invalid physical screen bounds.");
        }
        return value;
    }

    public static int[] ReadMonitorInfo(IntPtr window) {
        IntPtr monitor = MonitorFromWindow(window, 2);
        if (monitor == IntPtr.Zero) throw new InvalidOperationException("MonitorFromWindow returned no target monitor.");
        NativeMonitorInfo info = new NativeMonitorInfo();
        info.Size = (uint)Marshal.SizeOf(typeof(NativeMonitorInfo));
        if (!GetMonitorInfoW(monitor, ref info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return new [] {
            info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom,
            info.Work.Left, info.Work.Top, info.Work.Right, info.Work.Bottom
        };
    }

    public static string[] DescribeWindow(IntPtr window) {
        StringBuilder className = new StringBuilder(128);
        StringBuilder title = new StringBuilder(1024);
        GetClassName(window, className, className.Capacity);
        GetWindowTextW(window, title, title.Capacity);
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        IntPtr owner = GetWindow(window, 4);
        return new [] {
            window.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture),
            owner.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture),
            processId.ToString(System.Globalization.CultureInfo.InvariantCulture),
            className.ToString(), title.ToString(), IsWindowVisible(window) ? "true" : "false"
        };
    }

    public static int[] TryReadScrollInfo(IntPtr window, int bar) {
        NativeScrollInfo info = new NativeScrollInfo();
        info.Size = (uint)Marshal.SizeOf(typeof(NativeScrollInfo));
        info.Mask = 0x17;
        if (!GetScrollInfo(window, bar, ref info)) return null;
        return new [] { info.Minimum, info.Maximum, (int)info.Page, info.Position, info.TrackPosition };
    }

    public static WindowMeasurement[] ReadProcessTopLevelWindows(uint expectedProcessId) {
        List<WindowMeasurement> windows = new List<WindowMeasurement>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) return true;
            Rect rect;
            if (!GetWindowRect(window, out rect)) rect = new Rect();
            string[] description = DescribeWindow(window);
            windows.Add(new WindowMeasurement {
                Handle = window.ToInt64(), Owner = Int64.Parse(description[1]), ProcessId = processId,
                ClassName = description[3], Title = description[4], Visible = description[5] == "true",
                Left = rect.Left, Top = rect.Top, Right = rect.Right, Bottom = rect.Bottom
            });
            if (windows.Count > 128) throw new InvalidOperationException("Process window inventory exceeded its bound.");
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }

    public static long ReadListViewTooltip(IntPtr listView) {
        return SendMessageW(listView, 0x104E, IntPtr.Zero, IntPtr.Zero).ToInt64();
    }

    public static string OsVersion() {
        RTL_OSVERSIONINFOEX value = new RTL_OSVERSIONINFOEX();
        value.size = (uint)Marshal.SizeOf(typeof(RTL_OSVERSIONINFOEX));
        int status = RtlGetVersion(ref value);
        if (status != 0) { throw new Win32Exception(status); }
        return value.major + "." + value.minor + "." + value.build;
    }
}
'@
}

function Get-ElementObservation {
    param([Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element)

    $bounds = $Element.Current.BoundingRectangle
    [ordered]@{
        automation_id = $Element.Current.AutomationId
        name = $Element.Current.Name
        control_type = $Element.Current.ControlType.ProgrammaticName
        enabled = $Element.Current.IsEnabled
        keyboard_focusable = $Element.Current.IsKeyboardFocusable
        offscreen = $Element.Current.IsOffscreen
        native_handle = $Element.Current.NativeWindowHandle
        bounds = [ordered]@{
            x = $bounds.X
            y = $bounds.Y
            width = $bounds.Width
            height = $bounds.Height
        }
    }
}

function Get-FocusedAcceptanceElement {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Label
    )

    $focused = [Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused -or $focused.Current.ProcessId -ne $Process.Id -or
        $Process.SessionId -ne $ExpectedSession) {
        throw "$Label is not focused in the expected application and desktop session."
    }
    $focused
}

function Wait-AcceptanceFocusTransition {
    param(
        [Parameter(Mandatory)][object] $Before,
        [Parameter(Mandatory)][scriptblock] $ReadFocusedElement,
        [Parameter(Mandatory)][string] $Label,
        [ValidateRange(1, 40)][int] $MaximumAttempts = 40,
        [ValidateRange(0, 50)][int] $PollMilliseconds = 50
    )

    $beforeId = [string]$Before.Current.AutomationId
    $beforeHandle = [IntPtr]$Before.Current.NativeWindowHandle
    for ($attempt = 0; $attempt -lt $MaximumAttempts; $attempt++) {
        if ($PollMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        $focused = & $ReadFocusedElement
        if ($null -eq $focused) {
            throw "$Label returned no focused automation element."
        }
        if ([string]$focused.Current.AutomationId -cne $beforeId -or
            [IntPtr]$focused.Current.NativeWindowHandle -ne $beforeHandle) {
            return $focused
        }
    }
    throw "$Label did not change focus within the bounded observation attempts."
}

function Invoke-AcceptanceNavigationStep {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][uint16] $VirtualKey,
        [Parameter(Mandatory)][string] $Label
    )

    $before = Get-FocusedAcceptanceElement `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label "$Label before input"
    [DarkReNamerVmAcceptanceNative]::Tap($VirtualKey)
    Wait-AcceptanceFocusTransition `
        -Before $before `
        -ReadFocusedElement {
            Get-FocusedAcceptanceElement `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label "$Label after input"
        } `
        -Label $Label
}

function Send-AcceptanceTap {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][uint16] $VirtualKey,
        [Parameter(Mandatory)][string] $Label
    )

    [void](Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label $Label)
    [DarkReNamerVmAcceptanceNative]::Tap($VirtualKey)
}

function Send-AcceptanceChord {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][uint16] $Modifier,
        [Parameter(Mandatory)][uint16] $VirtualKey,
        [Parameter(Mandatory)][string] $Label
    )

    [void](Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label $Label)
    try {
        [DarkReNamerVmAcceptanceNative]::KeyDown($Modifier)
        [DarkReNamerVmAcceptanceNative]::Tap($VirtualKey)
    }
    finally {
        [DarkReNamerVmAcceptanceNative]::KeyUp($Modifier)
    }
}

function Send-AcceptanceTwoModifierChord {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][uint16] $Modifier,
        [Parameter(Mandatory)][uint16] $SecondModifier,
        [Parameter(Mandatory)][uint16] $VirtualKey,
        [Parameter(Mandatory)][string] $Label
    )

    [void](Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label $Label)
    try {
        [DarkReNamerVmAcceptanceNative]::KeyDown($Modifier)
        [DarkReNamerVmAcceptanceNative]::KeyDown($SecondModifier)
        [DarkReNamerVmAcceptanceNative]::Tap($VirtualKey)
    }
    finally {
        [DarkReNamerVmAcceptanceNative]::KeyUp($SecondModifier)
        [DarkReNamerVmAcceptanceNative]::KeyUp($Modifier)
    }
}

function Assert-AcceptanceForegroundBinding {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [switch] $RequireMainWindow
    )

    $foreground = [DarkReNamerVmNative]::GetForegroundWindow()
    $foregroundProcessId = [uint32]0
    if ($foreground -eq [IntPtr]::Zero -or
        [DarkReNamerVmNative]::GetWindowThreadProcessId(
            $foreground,
            [ref]$foregroundProcessId
        ) -eq 0 -or
        $foregroundProcessId -ne $Process.Id -or
        $Process.SessionId -ne $ExpectedSession -or
        ($RequireMainWindow -and $foreground -ne $Process.MainWindowHandle)) {
        throw 'Clipboard input is not bound to the exact application foreground target and desktop session.'
    }
}

function Find-AcceptanceMenuItem {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $conditions = [Windows.Automation.Condition[]]@(
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ProcessIdProperty,
            $Process.Id
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty,
            $Name
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::MenuItem
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::IsEnabledProperty,
            $true
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::IsOffscreenProperty,
            $false
        )
    )
    $condition = [Windows.Automation.AndCondition]::new($conditions)
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $matches = [Windows.Automation.AutomationElement]::RootElement.FindAll(
            [Windows.Automation.TreeScope]::Descendants,
            $condition
        )
        if ($matches.Count -gt 1) {
            throw "Clipboard menu item '$Name' matched more than one automation element."
        }
        if ($matches.Count -eq 1) {
            $item = $matches.Item(0)
            Assert-AutomationBinding `
                -Element $item `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label "Clipboard menu item '$Name'"
            return $item
        }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    throw "Clipboard menu item '$Name' was not found before the bounded deadline."
}

function Wait-AcceptanceClipboardText {
    param(
        [Parameter(Mandatory)][uint32] $PreviousSequence,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ExpectedText,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label,
        [scriptblock] $ReadSequence = { [DarkReNamerVmAcceptanceNative]::GetClipboardSequenceNumber() },
        [scriptblock] $ReadSnapshot = { [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot() },
        [scriptblock] $GetCurrentTime = { Get-Date },
        [ValidateRange(0, 1000)][int] $PollMilliseconds = 50
    )

    if ($PreviousSequence -eq 0) {
        throw "$Label requires a nonzero baseline Clipboard sequence."
    }
    $deadline = (& $GetCurrentTime).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    $observedSequenceChange = $false
    $unexpectedClipboardMessage = "$Label changed the Clipboard to unexpected text or formats."
    do {
        try {
            $sequence = [uint32](& $ReadSequence)
            if ($sequence -ne 0 -and $sequence -ne $PreviousSequence) {
                $observedSequenceChange = $true
                $snapshot = & $ReadSnapshot
                if ($null -eq $snapshot -or
                    $snapshot.SequenceNumber -eq 0 -or
                    $snapshot.SequenceNumber -eq $PreviousSequence) {
                    $snapshot = $null
                }
                else {
                    if (-not (Test-AcceptanceClipboardSnapshotOwned `
                        -Snapshot $snapshot `
                        -ExpectedSequence $snapshot.SequenceNumber `
                        -ExpectedText $ExpectedText)) {
                        throw $unexpectedClipboardMessage
                    }
                    return $snapshot
                }
            }
        }
        catch {
            if ($_.Exception.Message -ceq $unexpectedClipboardMessage) {
                throw
            }
        }
        if ($PollMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    } while ((& $GetCurrentTime) -lt $deadline)
    if ($observedSequenceChange) {
        throw "$Label changed, but the exact expected Clipboard snapshot was not readable before the bounded deadline."
    }
    throw "$Label did not change the Clipboard sequence before the bounded deadline."
}

function Send-AcceptanceText {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Label
    )

    [void](Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label $Label)
    [DarkReNamerVmAcceptanceNative]::TypeUnicode($Value)
}

function Move-TabFocusToId {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $AutomationId,
        [ValidateRange(1, 64)][int] $MaximumSteps = 32
    )

    for ($step = 0; $step -lt $MaximumSteps; $step++) {
        $focused = Get-FocusedAcceptanceElement `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label 'keyboard Tab navigation'
        if ($focused.Current.AutomationId -ceq $AutomationId) {
            return $focused
        }
        [void](Invoke-AcceptanceNavigationStep `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -VirtualKey 0x09 `
            -Label 'keyboard Tab navigation')
    }
    throw "Keyboard Tab navigation did not reach automation ID $AutomationId."
}

function Move-RailFocusToCommand {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $AutomationId
    )

    $leftIds = @('32771','32772','32773','32774','32775','32776','32777','32778','32779','32780')
    $rightIds = @('32781','32783','65535','32784','32788','32789','32790','32785','32786')
    $railIds = if ($leftIds -contains $AutomationId) { $leftIds } else { $rightIds }
    if ($railIds -notcontains $AutomationId) { throw 'Unknown command rail automation ID.' }
    $focused = $null
    for ($step = 0; $step -lt 32; $step++) {
        $focused = Get-FocusedAcceptanceElement `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label 'keyboard command-rail navigation'
        if ($railIds -contains $focused.Current.AutomationId) {
            break
        }
        $focused = Invoke-AcceptanceNavigationStep `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -VirtualKey 0x09 `
            -Label 'keyboard command-rail Tab navigation'
    }
    if ($null -eq $focused -or $railIds -notcontains $focused.Current.AutomationId) {
        throw 'Keyboard Tab navigation did not enter the target command rail.'
    }
    for ($step = 0; $step -lt $railIds.Count; $step++) {
        if ($focused.Current.AutomationId -ceq $AutomationId) {
            return $focused
        }
        $currentIndex = [Array]::IndexOf($railIds, $focused.Current.AutomationId)
        $targetIndex = [Array]::IndexOf($railIds, $AutomationId)
        $direction = if ($currentIndex -lt $targetIndex) { 0x28 } else { 0x26 }
        $focused = Invoke-AcceptanceNavigationStep `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -VirtualKey ([uint16]$direction) `
            -Label 'keyboard command-rail arrow navigation'
    }
    throw "Keyboard rail navigation did not reach automation ID $AutomationId."
}

function Get-RailAccessibilitySnapshot {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $ids = @(
        '32771','32772','32773','32774','32775','32776','32777','32778','32779','32780',
        '32781','32783','65535','32784','32788','32789','32790','32785','32786'
    )
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $element = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId $id `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label "command rail button $id" `
            -RequireWindowHandle
        if ([string]::IsNullOrWhiteSpace($element.Current.Name)) {
            throw "Command rail button $id has no accessible name."
        }
        $invokePattern = $null
        if (-not $element.TryGetCurrentPattern(
            [Windows.Automation.InvokePattern]::Pattern,
            [ref]$invokePattern
        )) {
            throw "Command rail button $id does not expose InvokePattern."
        }
        $rows.Add((Get-ElementObservation -Element $element))
    }
    if (@($rows | ForEach-Object automation_id | Sort-Object -Unique).Count -ne 19) {
        throw 'The command rail accessibility snapshot is incomplete.'
    }
    $rows.ToArray()
}

function Get-ListPrimarySnapshot {
    param([Parameter(Mandatory)][Windows.Automation.AutomationElement] $List)

    $gridObject = $null
    if (-not $List.TryGetCurrentPattern(
        [Windows.Automation.GridPattern]::Pattern,
        [ref]$gridObject
    )) {
        throw 'The production file list does not expose GridPattern for reset observation.'
    }
    $grid = [Windows.Automation.GridPattern]$gridObject
    if ($grid.Current.RowCount -ne 1 -or $grid.Current.ColumnCount -lt 3) {
        throw 'The reset observation requires exactly one row and three primary columns.'
    }
    [ordered]@{
        current_name = $grid.GetItem(0, 0).Current.Name
        proposed_name = $grid.GetItem(0, 1).Current.Name
        destination_parent = $grid.GetItem(0, 2).Current.Name
    }
}

function Resolve-AcceptanceWindowResize {
    param(
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int] $CurrentWidth,
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int] $CurrentHeight,
        [ValidateRange(640, 16384)][int] $MinimumWidth = 640,
        [ValidateRange(360, 16384)][int] $MinimumHeight = 360
    )

    $width = [Math]::Max($CurrentWidth, $MinimumWidth)
    $height = [Math]::Max($CurrentHeight, $MinimumHeight)
    [ordered]@{
        resize_required = $width -ne $CurrentWidth -or $height -ne $CurrentHeight
        width = $width
        height = $height
    }
}

function Ensure-AcceptanceMainWindowCaptureSize {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession
    )

    Assert-AutomationBinding `
        -Element $MainWindow `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label 'acceptance main window resize' `
        -RequireWindowHandle
    $handle = [IntPtr]$MainWindow.Current.NativeWindowHandle
    $beforeDpi = [DarkReNamerVmAcceptanceNative]::GetDpiForWindow($handle)
    $rect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
        throw 'Acceptance main window bounds could not be read before capture sizing.'
    }
    $beforeWidth = $rect.Right - $rect.Left
    $beforeHeight = $rect.Bottom - $rect.Top
    $resize = Resolve-AcceptanceWindowResize `
        -CurrentWidth $beforeWidth `
        -CurrentHeight $beforeHeight
    if ($resize.resize_required) {
        $flags = 0x0002 -bor 0x0004 -bor 0x0010
        if (-not [DarkReNamerVmAcceptanceNative]::SetWindowPos(
            $handle,
            [IntPtr]::Zero,
            0,
            0,
            $resize.width,
            $resize.height,
            $flags
        )) {
            throw 'Windows refused to resize the acceptance main window for eligible capture.'
        }
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            Start-Sleep -Milliseconds 50
            if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
                throw 'Acceptance main window bounds could not be read after capture sizing.'
            }
            if (($rect.Right - $rect.Left) -ge $resize.width -and
                ($rect.Bottom - $rect.Top) -ge $resize.height) {
                break
            }
        }
    }
    if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
        throw 'Acceptance main window final capture bounds could not be read.'
    }
    $finalWidth = $rect.Right - $rect.Left
    $finalHeight = $rect.Bottom - $rect.Top
    if ($finalWidth -lt 640 -or $finalHeight -lt 360) {
        throw 'Acceptance main window did not reach the evidence-eligible capture size.'
    }
    $afterDpi = [DarkReNamerVmAcceptanceNative]::GetDpiForWindow($handle)
    if ($afterDpi -ne $beforeDpi) {
        throw 'Acceptance main window DPI changed during capture sizing.'
    }
    [ordered]@{
        resize_required = $resize.resize_required
        before_width = $beforeWidth
        before_height = $beforeHeight
        width = $finalWidth
        height = $finalHeight
        dpi = $afterDpi
    }
}

function Resolve-AcceptanceAppearance {
    param([Parameter(Mandatory)][ValidateSet('system', 'light', 'dark')][string] $Appearance)

    switch ($Appearance) {
        'system' { [ordered]@{ command_id = 0x9010; evidence_name = 'system' } }
        'light' { [ordered]@{ command_id = 0x9011; evidence_name = 'light' } }
        'dark' { [ordered]@{ command_id = 0x9012; evidence_name = 'dark' } }
    }
}

function Set-AcceptanceAppearance {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][ValidateSet('system', 'light', 'dark')][string] $Appearance
    )

    if ($Process.SessionId -ne $ExpectedSession -or $Process.MainWindowHandle -eq [IntPtr]::Zero) {
        throw 'Acceptance appearance target is not bound to the expected desktop session.'
    }
    $spec = Resolve-AcceptanceAppearance -Appearance $Appearance
    [DarkReNamerVmAcceptanceNative]::SendMenuCommand(
        $Process.MainWindowHandle,
        [uint32]$spec.command_id
    )
    $stableReads = 0
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 50
        if ([DarkReNamerVmAcceptanceNative]::IsMenuCommandChecked(
            $Process.MainWindowHandle,
            [uint32]$spec.command_id
        )) {
            $stableReads++
            if ($stableReads -eq 2) {
                return $spec
            }
        }
        else {
            $stableReads = 0
        }
    }
    throw "The $Appearance appearance did not settle within the bounded observation attempts."
}

function Wait-AcceptancePopupMenu {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Label
    )

    if ($Process.SessionId -ne $ExpectedSession) {
        throw "$Label is not bound to the expected desktop session."
    }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 50
        $popup = [DarkReNamerVmAcceptanceNative]::FindVisiblePopupMenu([uint32]$Process.Id)
        if ($popup -ne [IntPtr]::Zero) {
            return $popup
        }
    }
    throw "$Label did not appear within the bounded observation attempts."
}

function Wait-AcceptancePopupMenuClosed {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][string] $Label
    )

    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 50
        if ([DarkReNamerVmAcceptanceNative]::FindVisiblePopupMenu([uint32]$Process.Id) -eq
            [IntPtr]::Zero) {
            return
        }
    }
    throw "$Label did not close within the bounded observation attempts."
}

function Save-AcceptanceNativeMenuScreenshot {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][IntPtr] $Popup,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-SafeLeafName -Value $Leaf -Label "$Label screenshot" -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.png$'
    Assert-AutomationBinding `
        -Element $MainWindow `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label $Label `
        -RequireWindowHandle
    $mainHandle = [IntPtr]$MainWindow.Current.NativeWindowHandle
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle -or
        [DarkReNamerVmAcceptanceNative]::FindVisiblePopupMenu([uint32]$Process.Id) -ne $Popup) {
        throw "$Label is not open on the exact foreground application window."
    }
    $mainRect = [DarkReNamerVmNative+Rect]::new()
    $popupRect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($mainHandle, [ref]$mainRect) -or
        -not [DarkReNamerVmNative]::GetWindowRect($Popup, [ref]$popupRect)) {
        throw "$Label bounds could not be read."
    }
    $left = [Math]::Min($mainRect.Left, $popupRect.Left)
    $top = [Math]::Min($mainRect.Top, $popupRect.Top)
    $right = [Math]::Max($mainRect.Right, $popupRect.Right)
    $bottom = [Math]::Max($mainRect.Bottom, $popupRect.Bottom)
    $width = $right - $left
    $height = $bottom - $top
    if ($width -lt 240 -or $height -lt 120 -or
        $width -gt 16384 -or $height -gt 16384 -or
        ([long]$width * [long]$height) -gt 100000000) {
        throw "$Label bounds are invalid."
    }
    $bitmap = $null
    $graphics = $null
    try {
        $bitmap = [Drawing.Bitmap]::new(
            $width,
            $height,
            [Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen(
            $left,
            $top,
            0,
            0,
            $bitmap.Size,
            [Drawing.CopyPixelOperation]::SourceCopy
        )
        if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle -or
            [DarkReNamerVmAcceptanceNative]::FindVisiblePopupMenu([uint32]$Process.Id) -ne $Popup) {
            throw "$Label changed during screenshot capture."
        }
        $firstColor = $bitmap.GetPixel(0, 0).ToArgb()
        $hasDifferentColor = $false
        $stepX = [Math]::Max(1, [int]($width / 64))
        $stepY = [Math]::Max(1, [int]($height / 64))
        for ($y = 0; $y -lt $height -and -not $hasDifferentColor; $y += $stepY) {
            for ($x = 0; $x -lt $width; $x += $stepX) {
                if ($bitmap.GetPixel($x, $y).ToArgb() -ne $firstColor) {
                    $hasDifferentColor = $true
                    break
                }
            }
        }
        if (-not $hasDifferentColor) {
            throw "$Label screenshot is a solid image."
        }
        $path = Join-Path $Root $Leaf
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        if ((Get-Item -LiteralPath $path).Length -le 0) {
            throw "$Label screenshot is empty."
        }
        [ordered]@{
            file = $Leaf
            sha256 = Get-LowerSha256 -Path $path
            width = $width
            height = $height
        }
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
}

function Add-AcceptanceScreenshotContext {
    param(
        [Parameter(Mandatory)][object] $Screenshot,
        [Parameter(Mandatory)][ValidateSet(
            'system', 'light', 'dark', 'forced-colors'
        )][string] $Appearance,
        [Parameter(Mandatory)][ValidateSet(
            'main-workbench',
            'native-menu',
            'advanced-appearance',
            'input-prompt',
            'common-dialog',
            'confirmation-task-dialog'
        )][string] $Surface
    )

    [ordered]@{
        file = $Screenshot.file
        sha256 = $Screenshot.sha256
        width = $Screenshot.width
        height = $Screenshot.height
        appearance = $Appearance
        surface = $Surface
    }
}

function Write-JsonUtf8Bom {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object] $Value)

    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($true))
}

function Initialize-AcceptanceNativeOpen {
    if ('DarkReNamerAcceptanceNativeOpen' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DarkReNamerAcceptanceNativeOpen {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetDlgItem(IntPtr dialog, int controlId);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern int GetClassName(IntPtr window, StringBuilder className, int capacity);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern int GetWindowText(IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
}
'@
}

function Resolve-AcceptanceNativeOpen {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Dialog,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession
    )

    Initialize-AcceptanceNativeOpen
    Assert-AutomationBinding -Element $Dialog -Process $Process -ExpectedSession $ExpectedSession -Label 'keyboard file dialog' -RequireWindowHandle
    $dialogHandle = [IntPtr]$Dialog.Current.NativeWindowHandle
    $openHandle = [DarkReNamerAcceptanceNativeOpen]::GetDlgItem($dialogHandle, 1)
    if ($openHandle -eq [IntPtr]::Zero -or -not [DarkReNamerAcceptanceNativeOpen]::IsWindow($openHandle)) {
        throw 'The source-bound file dialog has no live native control ID 1.'
    }
    if ([DarkReNamerAcceptanceNativeOpen]::GetParent($openHandle) -ne $dialogHandle -or
        [DarkReNamerAcceptanceNativeOpen]::GetDlgCtrlID($openHandle) -ne 1) {
        throw 'The native Open control is not the exact direct child ID 1 of the source-bound file dialog.'
    }
    $openProcessId = [uint32]0
    $openThreadId = [DarkReNamerAcceptanceNativeOpen]::GetWindowThreadProcessId($openHandle, [ref]$openProcessId)
    if ($openThreadId -eq 0 -or $openProcessId -ne $Process.Id -or $Process.SessionId -ne $ExpectedSession) {
        throw 'The native Open control is outside the source-bound process or desktop session.'
    }
    $openClass = [Text.StringBuilder]::new(32)
    if ([DarkReNamerAcceptanceNativeOpen]::GetClassName($openHandle, $openClass, $openClass.Capacity) -le 0 -or
        $openClass.ToString() -cne 'Button') {
        throw 'The source-bound file dialog Open control is not a native Button class.'
    }
    if (-not [DarkReNamerAcceptanceNativeOpen]::IsWindowVisible($openHandle) -or
        -not [DarkReNamerAcceptanceNativeOpen]::IsWindowEnabled($openHandle)) {
        throw 'The source-bound native Open control is not visible and enabled.'
    }
    $dialogRect = [DarkReNamerAcceptanceNativeOpen+Rect]::new()
    $openRect = [DarkReNamerAcceptanceNativeOpen+Rect]::new()
    if (-not [DarkReNamerAcceptanceNativeOpen]::GetWindowRect($dialogHandle, [ref]$dialogRect) -or
        -not [DarkReNamerAcceptanceNativeOpen]::GetWindowRect($openHandle, [ref]$openRect) -or
        $dialogRect.Right -le $dialogRect.Left -or $dialogRect.Bottom -le $dialogRect.Top -or
        $openRect.Right -le $openRect.Left -or $openRect.Bottom -le $openRect.Top -or
        $openRect.Left -lt $dialogRect.Left -or $openRect.Top -lt $dialogRect.Top -or
        $openRect.Right -gt $dialogRect.Right -or $openRect.Bottom -gt $dialogRect.Bottom) {
        throw 'The source-bound native Open control bounds are invalid or outside its dialog.'
    }
    $element = [Windows.Automation.AutomationElement]::FromHandle($openHandle)
    Assert-AutomationBinding -Element $element -Process $Process -ExpectedSession $ExpectedSession -Label 'native keyboard file dialog Open control' -RequireWindowHandle
    if ([IntPtr]$element.Current.NativeWindowHandle -ne $openHandle) {
        throw 'UI Automation did not map back to the exact native Open control.'
    }
    [pscustomobject]@{
        Element = $element
        Handle = $openHandle
        ProcessId = $openProcessId
        ThreadId = $openThreadId
        ClassName = $openClass.ToString()
        DialogBounds = [ordered]@{ left = $dialogRect.Left; top = $dialogRect.Top; right = $dialogRect.Right; bottom = $dialogRect.Bottom }
        ControlBounds = [ordered]@{ left = $openRect.Left; top = $openRect.Top; right = $openRect.Right; bottom = $openRect.Bottom }
    }
}

# Four fixed GUI regression scenarios composed from the tracked acceptance helpers above.
function Normalize-ObserverText {
    param([AllowEmptyString()][string] $Value)
    if ($null -eq $Value) { return $null }
    $Value.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-ObserverWindowTree {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][string] $Label
    )
    Assert-AutomationBinding -Element $Window -Process $Process -ExpectedSession $SessionId -Label $Label -RequireWindowHandle
    $all = $Window.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.Condition]::TrueCondition
    )
    if ($all.Count -gt 512) { throw "$Label exposes an unexpectedly large automation tree." }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($element in $all) {
        if (-not [string]::IsNullOrEmpty($element.Current.Name) -or
            -not [string]::IsNullOrEmpty($element.Current.AutomationId)) {
            $rows.Add((Get-ElementObservation -Element $element))
        }
    }
    $rows.ToArray()
}

function Start-AcceptanceApplication {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $Label
    )
    $owned = Start-OwnedProcess -FilePath $FilePath -Arguments '' -WorkingDirectory $WorkingDirectory
    $process = $owned.process
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) { throw "$Label exited before creating its window." }
    } while ($process.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero -or $process.SessionId -ne $SessionId) {
        throw "$Label did not create a window in the expected session."
    }
    $window = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    Assert-AutomationBinding -Element $window -Process $process -ExpectedSession $SessionId -Label "$Label main window" -RequireWindowHandle
    $window.SetFocus()
    [void][DarkReNamerVmNative]::SetForegroundWindow($process.MainWindowHandle)
    $foregroundDeadline = (Get-Date).AddSeconds(5)
    while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $process.MainWindowHandle -and (Get-Date) -lt $foregroundDeadline) {
        Start-Sleep -Milliseconds 50
    }
    Assert-AcceptanceForegroundBinding -Process $process -ExpectedSession $SessionId -RequireMainWindow
    [pscustomobject]@{ owned = $owned; process = $process; main = $window }
}

function Get-ObserverGrid {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )
    $list = Find-UniqueAutomationElement `
        -Root $Application.main `
        -Process $Application.process `
        -ExpectedSession $SessionId `
        -AutomationId '1000' `
        -ControlType ([Windows.Automation.ControlType]::DataGrid) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'long-name UX file list' `
        -RequireWindowHandle
    $pattern = $null
    if (-not $list.TryGetCurrentPattern([Windows.Automation.GridPattern]::Pattern, [ref]$pattern)) {
        throw 'The file list does not expose GridPattern.'
    }
    [pscustomobject]@{ element = $list; pattern = [Windows.Automation.GridPattern]$pattern }
}

function Import-GuiRegressionPathList {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $PathsFile,
        [Parameter(Mandatory)][int] $ExpectedRows,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [object] $Grid
    )
    if ($null -eq $Grid) {
        $Grid = Get-ObserverGrid -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds
    }
    Add-Type -AssemblyName System.Windows.Forms
    $Application.main.SetFocus()
    [void][DarkReNamerVmNative]::SetForegroundWindow($Application.process.MainWindowHandle)
    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId -RequireMainWindow
    [Windows.Forms.SendKeys]::SendWait('^+v')
    $dialog = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Name '파일에서 경로목록 읽어 추가하기' -TimeoutSeconds $WaitSeconds -Label 'GUI regression path-list import dialog'
    $handle = [IntPtr]$dialog.Current.NativeWindowHandle
    $edit = Find-UniqueAutomationElement -Root $dialog -Process $Application.process -ExpectedSession $SessionId -AutomationId '1148' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $WaitSeconds -Label 'path-list import filename' -RequireWindowHandle
    Set-AutomationControlValue -Element $edit -Value $PathsFile -Label 'path-list import filename'
    $nativeOpen = Resolve-AcceptanceNativeOpen -Dialog $dialog -Process $Application.process -ExpectedSession $SessionId
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-AutomationControl -Element $nativeOpen.Element -Label 'path-list import Open'
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label 'path-list import dialog'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        if ($Grid.pattern.Current.RowCount -eq $ExpectedRows) { break }
        if ($Grid.pattern.Current.RowCount -gt $ExpectedRows) { throw 'Path admission produced too many rows.' }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($Grid.pattern.Current.RowCount -ne $ExpectedRows) {
        throw "Path admission did not reach $ExpectedRows rows before the bounded deadline."
    }
    [pscustomobject]@{ grid = $Grid; elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3) }
}

function Set-ObserverSelectedRow {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][int] $Row,
        [Parameter(Mandatory)][int] $SessionId
    )
    if ($Row -ge $Grid.pattern.Current.RowCount) { throw 'Requested row is outside the file list.' }
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow($Application.process.MainWindowHandle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId -RequireMainWindow
    $cell = $Grid.pattern.GetItem($Row, 0)
    $Grid.element.SetFocus()
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x24 -Label 'select first preview row'
    for ($index = 0; $index -lt $Row; $index++) {
        Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x28 -Label 'advance preview row selection'
    }
    $selection = $null
    if (-not $Grid.element.TryGetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern, [ref]$selection)) {
        throw 'The file list does not expose SelectionPattern.'
    }
    $selectionDeadline = (Get-Date).AddSeconds(3)
    do {
        $selected = @(([Windows.Automation.SelectionPattern]$selection).Current.GetSelection())
        if ($selected.Count -eq 1) { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $selectionDeadline)
    if ($selected.Count -ne 1) { throw "The scenario requires exactly one selected row; observed $($selected.Count)." }
    [ordered]@{ row = $Row; current_name = $cell.Current.Name; selected_count = $selected.Count }
}

function Set-ObserverManualName {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][int] $Row,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [string] $CaptureRoot,
        [string] $CaptureLeaf,
        [AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    [void](Set-ObserverSelectedRow -Application $Application -Grid $Grid -Row $Row -SessionId $SessionId)
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x71 -Label "manual change row $Row F2"
    $prompt = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name '선택 항목 이름 직접 변경' -TimeoutSeconds $WaitSeconds -Label "manual change row $Row prompt"
    $handle = [IntPtr]$prompt.Current.NativeWindowHandle
    $edit = Find-UniqueAutomationElement -Root $prompt -Process $Application.process -ExpectedSession $SessionId -AutomationId '1004' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $WaitSeconds -Label "manual change row $Row edit" -RequireWindowHandle
    $rasterTarget = $null
    if (-not [string]::IsNullOrEmpty($CaptureRoot) -and -not [string]::IsNullOrEmpty($CaptureLeaf)) {
        if ($null -eq $Captures) { throw 'Editable prompt capture requires the capture ledger.' }
        $rasterTarget = Get-ObserverNativeStaticRasterTarget -Window $prompt -Application $Application -SessionId $SessionId -ControlId 1002 -ExpectedText '으로' -Id 'prefix-input' -Image $CaptureLeaf
        [void]$Captures.Add((Save-WindowScreenshot -Window $prompt -Process $Application.process -ExpectedSession $SessionId -Root $CaptureRoot -Leaf $CaptureLeaf -Label "manual change row $Row prompt"))
    }
    Set-AutomationControlValue -Element $edit -Value $Name -Label "manual change row $Row edit"
    $ok = Find-UniqueAutomationElement -Root $prompt -Process $Application.process -ExpectedSession $SessionId -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label "manual change row $Row OK" -RequireEnabled -RequireWindowHandle
    Invoke-AutomationControl -Element $ok -Label "manual change row $Row OK"
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label "manual change row $Row prompt"
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $actual = $Grid.pattern.GetItem($Row, 1).Current.Name
        if ($actual -ceq $Name) { return $rasterTarget }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "Manual row $Row preview did not expose the exact requested name."
}

function Copy-GuiRegressionDocument {
    param(
        [Parameter(Mandatory)][ValidateSet('selection', 'mnemonic')][string] $Mode,
        [Parameter(Mandatory)][object] $Application,
        [Windows.Automation.AutomationElement] $Edit,
        [Parameter(Mandatory)][string] $ExpectedText,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $Label
    )
    $expectedClipboard = (Normalize-ObserverText $ExpectedText).Replace("`n", "`r`n")
    $before = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
    if ($before.SequenceNumber -eq 0 -or $before.Formats.Count -ne 0) {
        throw "$Label requires an empty Clipboard with a nonzero sequence preflight."
    }
    if ($Mode -ceq 'selection') {
        if ($null -eq $Edit) { throw 'Selection copy requires the bound read-only Edit.' }
        $Edit.SetFocus()
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x24 -Label "$Label selection start"
        Send-AcceptanceTwoModifierChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -SecondModifier 0x10 -VirtualKey 0x23 -Label "$Label select to end"
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x43 -Label "$Label Ctrl+C"
    }
    else {
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x43 -Label "$Label Alt+C"
    }
    $snapshot = $null
    try {
        $snapshot = Wait-AcceptanceClipboardText -PreviousSequence $before.SequenceNumber -ExpectedText $expectedClipboard -TimeoutSeconds $WaitSeconds -Label $Label
    }
    finally {
        if ($null -eq $snapshot) {
            try {
                $candidate = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
                if ($candidate.SequenceNumber -ne $before.SequenceNumber -and
                    (Test-AcceptanceClipboardSnapshotOwned -Snapshot $candidate -ExpectedSequence $candidate.SequenceNumber -ExpectedText $expectedClipboard)) {
                    [void][DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned([uint32]$candidate.SequenceNumber, [string]$candidate.UnicodeText)
                }
            } catch {}
        }
    }
    $cleanup = [DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned([uint32]$snapshot.SequenceNumber, [string]$snapshot.UnicodeText)
    if ($cleanup -cne 'cleared') { throw "$Label Clipboard cleanup preserved a foreign or changed value: $cleanup" }
    [ordered]@{
        input = if ($Mode -ceq 'selection') { 'native-edit-ctrl-home-ctrl-shift-end-ctrl-c' } else { 'copy-all-mnemonic-alt-c' }
        exact = (Normalize-ObserverText $snapshot.UnicodeText) -ceq (Normalize-ObserverText $expectedClipboard)
        utf8_sha256 = Get-LowerTextSha256 -Value (Normalize-ObserverText $snapshot.UnicodeText)
        length_utf16 = $snapshot.UnicodeText.Length
        cleanup = $cleanup
    }
}
function Get-ObserverProcessWindows {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)
    @([DarkReNamerVmAcceptanceNative]::ReadProcessTopLevelWindows([uint32]$Process.Id) | ForEach-Object {
        [ordered]@{
            hwnd = $_.Handle
            owner_hwnd = $_.Owner
            process_id = $_.ProcessId
            class_name = $_.ClassName
            title = $_.Title
            visible = $_.Visible
            rect = [ordered]@{ left = $_.Left; top = $_.Top; right = $_.Right; bottom = $_.Bottom; width = $_.Right - $_.Left; height = $_.Bottom - $_.Top }
        }
    })
}

function Get-ObserverEnvironmentMetadata {
    param([Parameter(Mandatory)][object] $Application)
    $handle = [IntPtr]$Application.main.Current.NativeWindowHandle
    $screen = [DarkReNamerVmAcceptanceNative]::ReadPhysicalScreenSize()
    $work = [DarkReNamerVmAcceptanceNative]::ReadWorkArea()
    $monitor = [DarkReNamerVmAcceptanceNative]::ReadMonitorInfo($handle)
    Initialize-TextScaleNative
    $textScale = [double][DarkReNamerTextScaleNative]::ReadTextScaleFactor()
    if ([double]::IsNaN($textScale) -or $textScale -lt 1.0 -or $textScale -gt 2.25) {
        throw 'UISettings.TextScaleFactor is outside the documented system range.'
    }
    $textScalePercent = [int][Math]::Round($textScale * 100.0)
    $displayModes = @('{0}x{1}@current' -f ($monitor[2] - $monitor[0]),($monitor[3] - $monitor[1]))
    [ordered]@{
        physical_screen = [ordered]@{ left = $monitor[0]; top = $monitor[1]; right = $monitor[2]; bottom = $monitor[3]; width = $monitor[2] - $monitor[0]; height = $monitor[3] - $monitor[1] }
        work_area = [ordered]@{ left = $monitor[4]; top = $monitor[5]; right = $monitor[6]; bottom = $monitor[7]; width = $monitor[6] - $monitor[4]; height = $monitor[7] - $monitor[5] }
        monitor_query = 'MonitorFromWindow(MONITOR_DEFAULTTONEAREST)+GetMonitorInfoW'
        global_metrics_diagnostic = [ordered]@{
            physical_screen = [ordered]@{ width = $screen.X; height = $screen.Y }
            work_area = [ordered]@{ left = $work.Left; top = $work.Top; right = $work.Right; bottom = $work.Bottom }
        }
        hwnd = $handle.ToInt64()
        hwnd_dpi = [DarkReNamerVmAcceptanceNative]::GetDpiForWindow($handle)
        text_scale_factor_percent = $textScalePercent
        text_scale_factor_source = [ordered]@{
            query = 'Windows.UI.ViewManagement.UISettings.TextScaleFactor'
            raw_factor = $textScale
            documented_range = '1.0..2.25'
        }
        dpi_awareness = 'per-monitor-v2-observer'
        display_mode_inventory = [ordered]@{
            query = 'GetMonitorInfoW current monitor'
            maximum_entries = 1
            values = $displayModes
        }
    }
}

function Get-ObserverNativeWindowMetrics {
    param([Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window)
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    if ($handle -eq [IntPtr]::Zero) { throw 'Top-level observer window has no native HWND.' }
    $rect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
        throw 'Top-level observer window bounds could not be read.'
    }
    $monitor = [DarkReNamerVmAcceptanceNative]::ReadMonitorInfo($handle)
    [ordered]@{
        hwnd = $handle.ToInt64()
        process_id = [int]$Window.Current.ProcessId
        hwnd_dpi = [DarkReNamerVmAcceptanceNative]::GetDpiForWindow($handle)
        coordinate_space = 'physical pixels; observer is Per-Monitor-V2 aware'
        rect = [ordered]@{ left = $rect.Left; top = $rect.Top; right = $rect.Right; bottom = $rect.Bottom; width = $rect.Right - $rect.Left; height = $rect.Bottom - $rect.Top }
        target_monitor = [ordered]@{ left = $monitor[0]; top = $monitor[1]; right = $monitor[2]; bottom = $monitor[3]; width = $monitor[2] - $monitor[0]; height = $monitor[3] - $monitor[1] }
        target_work_area = [ordered]@{ left = $monitor[4]; top = $monitor[5]; right = $monitor[6]; bottom = $monitor[7]; width = $monitor[6] - $monitor[4]; height = $monitor[7] - $monitor[5] }
        fully_inside_work_area = $rect.Left -ge $monitor[4] -and $rect.Top -ge $monitor[5] -and $rect.Right -le $monitor[6] -and $rect.Bottom -le $monitor[7]
    }
}

function Get-ObserverNativeStaticRasterTarget {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $ControlId,
        [Parameter(Mandatory)][string] $ExpectedText,
        [Parameter(Mandatory)][ValidateSet('prefix-input', 'full-details')][string] $Id,
        [Parameter(Mandatory)][string] $Image
    )

    Initialize-AcceptanceNativeOpen
    Assert-AutomationBinding -Element $Window -Process $Application.process -ExpectedSession $SessionId -Label "$Id raster window" -RequireWindowHandle
    $windowHandle = [IntPtr]$Window.Current.NativeWindowHandle
    $controlHandle = [DarkReNamerAcceptanceNativeOpen]::GetDlgItem($windowHandle, $ControlId)
    if ($controlHandle -eq [IntPtr]::Zero -or
        [DarkReNamerAcceptanceNativeOpen]::GetParent($controlHandle) -ne $windowHandle) {
        throw "$Id native STATIC is not the expected direct dialog child."
    }
    $processId = [uint32]0
    $threadId = [DarkReNamerAcceptanceNativeOpen]::GetWindowThreadProcessId($controlHandle, [ref]$processId)
    if ($threadId -eq 0 -or $processId -ne $Application.process.Id -or
        $Application.process.SessionId -ne $SessionId) {
        throw "$Id native STATIC is outside the source-bound process or desktop session."
    }
    $className = [Text.StringBuilder]::new(32)
    $text = [Text.StringBuilder]::new(256)
    if ([DarkReNamerAcceptanceNativeOpen]::GetClassName($controlHandle, $className, $className.Capacity) -le 0 -or
        $className.ToString() -cne 'Static' -or
        [DarkReNamerAcceptanceNativeOpen]::GetWindowText($controlHandle, $text, $text.Capacity) -le 0 -or
        $text.ToString() -cne $ExpectedText) {
        throw "$Id native STATIC class or text differs from the fixed label."
    }
    $controlRect = [DarkReNamerAcceptanceNativeOpen+Rect]::new()
    $windowRect = [DarkReNamerAcceptanceNativeOpen+Rect]::new()
    if (-not [DarkReNamerAcceptanceNativeOpen]::GetWindowRect($controlHandle, [ref]$controlRect) -or
        -not [DarkReNamerAcceptanceNativeOpen]::GetWindowRect($windowHandle, [ref]$windowRect) -or
        $controlRect.Right -le $controlRect.Left -or $controlRect.Bottom -le $controlRect.Top -or
        $controlRect.Left -lt $windowRect.Left -or $controlRect.Top -lt $windowRect.Top -or
        $controlRect.Right -gt $windowRect.Right -or $controlRect.Bottom -gt $windowRect.Bottom) {
        throw "$Id native STATIC bounds are invalid or outside its captured dialog."
    }
    $controlRectangle = [ordered]@{
        left = $controlRect.Left; top = $controlRect.Top
        right = $controlRect.Right; bottom = $controlRect.Bottom
        width = $controlRect.Right - $controlRect.Left
        height = $controlRect.Bottom - $controlRect.Top
    }
    $windowRectangle = [ordered]@{
        left = $windowRect.Left; top = $windowRect.Top
        right = $windowRect.Right; bottom = $windowRect.Bottom
        width = $windowRect.Right - $windowRect.Left
        height = $windowRect.Bottom - $windowRect.Top
    }
    [ordered]@{
        id = $Id
        image = $Image
        text_sha256 = Get-LowerTextSha256 -Value $ExpectedText
        control = [ordered]@{
            observation = 'native-static-v1'
            hwnd = $controlHandle.ToInt64()
            process_id = [int]$processId
            control_id = $ControlId
            class_name = $className.ToString()
            text = $text.ToString()
        }
        window = [ordered]@{
            hwnd = $windowHandle.ToInt64()
            process_id = [int]$processId
            rect = $windowRectangle
        }
        screenshot_origin = [ordered]@{ x = $windowRect.Left; y = $windowRect.Top }
        control_rect = $controlRectangle
    }
}

function Get-GuiRegressionPhysicalTarget {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][IntPtr] $ExpectedRoot,
        [Parameter(Mandatory)][string] $Label,
        [switch] $Click
    )
    Assert-AutomationBinding -Element $Element -Process $Application.process -ExpectedSession $SessionId -Label $Label
    $bounds = $Element.Current.BoundingRectangle
    if ($bounds.Width -lt 4 -or $bounds.Height -lt 4 -or [double]::IsNaN($bounds.X) -or [double]::IsNaN($bounds.Y)) {
        throw "$Label has invalid physical bounds."
    }
    $x = [int][Math]::Floor($bounds.X + $bounds.Width / 2.0)
    $y = [int][Math]::Floor($bounds.Y + $bounds.Height / 2.0)
    $point = [DarkReNamerVmAcceptanceNative+Point]::new()
    $point.X = $x; $point.Y = $y
    $hit = [DarkReNamerVmAcceptanceNative]::WindowFromPoint($point)
    $targetProcessId = [uint32]0
    $hitThreadId = if ($hit -eq [IntPtr]::Zero) { [uint32]0 } else {
        [DarkReNamerVmNative]::GetWindowThreadProcessId($hit, [ref]$targetProcessId)
    }
    $hitRoot = if ($hit -eq [IntPtr]::Zero) { [IntPtr]::Zero } else {
        [DarkReNamerVmAcceptanceNative]::GetAncestor($hit, [uint32]2)
    }
    if ($hit -eq [IntPtr]::Zero -or $hitThreadId -eq 0 -or
        $targetProcessId -ne $Application.process.Id -or
        $hitRoot -ne $ExpectedRoot) {
        throw ("$Label is not physically bound to the expected process/window tree: " +
            "hit_window=$($hit.ToInt64()); hit_process_id=$targetProcessId; " +
            "hit_root_window=$($hitRoot.ToInt64()); expected_process_id=$($Application.process.Id); " +
            "expected_root_window=$($ExpectedRoot.ToInt64()).")
    }
    $result = [ordered]@{ x = $x; y = $y; hit_window = $hit.ToInt64(); root_window = $ExpectedRoot.ToInt64() }
    if ($Click) {
        [DarkReNamerVmAcceptanceNative]::MoveCursor($x, $y)
        $foreground = [DarkReNamerVmNative]::GetForegroundWindow()
        if ($foreground -ne $ExpectedRoot -and $foreground -ne $Application.process.MainWindowHandle) {
            throw "$Label foreground does not belong to the expected modal path."
        }
        [DarkReNamerVmAcceptanceNative]::Click()
    }
    $result
}

function New-ObserverPathList {
    param(
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string[]] $Paths,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}$')][string] $Leaf = 'paths-utf16le.txt'
    )
    $text = [string]::Join("`r`n", $Paths) + "`r`n"
    $aggregateUnits = ($Paths | Measure-Object -Property Length -Sum).Sum
    if ($aggregateUnits * 2L -gt 4MB) { throw 'Fixture paths exceed the aggregate path budget.' }
    $encoding = [Text.UnicodeEncoding]::new($false, $true)
    $body = $encoding.GetBytes($text)
    $preamble = $encoding.GetPreamble()
    if ($body.Length + $preamble.Length -gt 2MB) {
        throw 'Fixture path list exceeds the import limit.'
    }
    $bytes = [byte[]]::new($body.Length + $preamble.Length)
    [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    $path = Join-Path $RuntimeRoot $Leaf
    [IO.File]::WriteAllBytes($path, $bytes)
    $path
}

function Get-ObserverFixtureState {
    param([Parameter(Mandatory)][string] $FixtureRoot)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $FixtureRoot -File -Recurse -Force | Sort-Object FullName)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Fixture contains a reparse point.'
        }
        $rows.Add([ordered]@{
            path = $file.FullName
            name = $file.Name
            content_sha256 = Get-LowerSha256 -Path $file.FullName
            identity = [DarkReNamerVmNative]::GetFileIdentity($file.FullName)
        })
    }
    $rows.ToArray()
}

function Test-ObserverFixtureStateEqual {
    param([Parameter(Mandatory)][object[]] $Expected, [Parameter(Mandatory)][object[]] $Actual)
    if ($Expected.Count -ne $Actual.Count) { return $false }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Expected[$index].path -cne $Actual[$index].path -or
            $Expected[$index].name -cne $Actual[$index].name -or
            $Expected[$index].content_sha256 -cne $Actual[$index].content_sha256 -or
            $Expected[$index].identity -cne $Actual[$index].identity) {
            return $false
        }
    }
    $true
}

function New-ObserverStandardFixture {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $fixtureRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'fixture'
    $parentA = New-PrivateDirectory -Parent $fixtureRoot -Leaf '한글-매우-긴-상위-경로-공통-자료-보관-2026-09-A-😀'
    $parentB = New-PrivateDirectory -Parent $fixtureRoot -Leaf '한글-매우-긴-상위-경로-공통-자료-보관-2026-09-B-😀'
    $common = '한글-😀-아주긴공통접두어-월별정리-원본자료-검토완료-배포대기-장기보존-최종승인-추가검증-'
    $source0 = $common + '0001-final.txt'
    $source1 = $common + '0002-final.md'
    $source2 = $source0
    $after0 = $common + '9001-approved.webp'
    $after1 = $common + '9002-approved.png'
    foreach ($leaf in @($source0, $source1, $after0, $after1)) {
        if ($leaf.Length -gt 240) { throw 'Standard fixture leaf exceeds the observer bound.' }
    }
    $paths = @(
        (Join-Path $parentA $source0),
        (Join-Path $parentA $source1),
        (Join-Path $parentB $source2)
    )
    for ($index = 0; $index -lt $paths.Count; $index++) {
        [IO.File]::WriteAllText(
            $paths[$index],
            "long-name-ux-fixture-$index`n",
            [Text.UTF8Encoding]::new($false)
        )
    }
    $destinations = @(
        (Join-Path $parentA $after0),
        (Join-Path $parentA $after1),
        $paths[2]
    )
    [pscustomobject]@{
        root = $fixtureRoot
        paths = $paths
        paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths $paths
        source_names = @($source0, $source1, $source2)
        destination_names = @($after0, $after1, $source2)
        destinations = $destinations
        initial = Get-ObserverFixtureState -FixtureRoot $fixtureRoot
    }
}

function Invoke-ObserverPrefix {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [string] $ExpectedFirstSourceName = 'item-00000.txt'
    )
    $command = Find-UniqueAutomationElement -Root $Application.main -Process $Application.process -ExpectedSession $SessionId -AutomationId '32773' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix command' -RequireEnabled -RequireWindowHandle
    $invoke = Start-AutomationControlInvoke -Element $command -Label 'large smoke prefix command'
    $prompt = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name '이름 앞에 문자열 붙이기' -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix prompt'
    $handle = [IntPtr]$prompt.Current.NativeWindowHandle
    $edit = Find-UniqueAutomationElement -Root $prompt -Process $Application.process -ExpectedSession $SessionId -AutomationId '1004' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix edit' -RequireWindowHandle
    Set-AutomationControlValue -Element $edit -Value $Prefix -Label 'large smoke prefix edit'
    $ok = Find-UniqueAutomationElement -Root $prompt -Process $Application.process -ExpectedSession $SessionId -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix OK' -RequireEnabled -RequireWindowHandle
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-AutomationControl -Element $ok -Label 'large smoke prefix OK'
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label 'large smoke prefix prompt'
    Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $WaitSeconds
    $expected = $Prefix + $ExpectedFirstSourceName
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        if ($Grid.pattern.GetItem(0, 1).Current.Name -ceq $expected) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($Grid.pattern.GetItem(0, 1).Current.Name -cne $expected) {
        throw 'Large smoke preview did not settle.'
    }
    [ordered]@{ elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3); expected_first_name = $expected }
}

function Get-ObserverReadOnlyDetails {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $ExpectedText,
        [Parameter(Mandatory)][string] $Label
    )
    $edit = Find-UniqueAutomationElement -Root $Window -Process $Application.process -ExpectedSession $SessionId -AutomationId '1004' -TimeoutSeconds $WaitSeconds -Label "$Label read-only edit" -RequireWindowHandle
    $textObject = $null
    if (-not $edit.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$textObject)) {
        throw "$Label edit does not expose TextPattern."
    }
    $text = [Windows.Automation.TextPattern]$textObject
    $readOnly = $text.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::IsReadOnlyAttribute)
    $valueText = Normalize-ObserverText $text.DocumentRange.GetText(-1)
    $documentText = Normalize-ObserverText $text.DocumentRange.GetText(-1)
    $expected = Normalize-ObserverText $ExpectedText
    if ($readOnly -ne $true -or $documentText -cne $expected) {
        throw "$Label does not expose the exact canonical read-only text."
    }
    [pscustomobject]@{
        edit = $edit
        text_pattern = $text
        evidence = [ordered]@{
            automation = Get-ElementObservation -Element $edit
            read_only = $readOnly
            value_text = $valueText
            document_text = $documentText
            exact_value = $null; value_pattern = 'not-exposed-by-native-readonly-document'
            exact_document = $true
            utf8_sha256 = Get-LowerTextSha256 -Value $valueText
            utf16_length = $text.DocumentRange.GetText(-1).Length
        }
    }
}

function Get-ObserverVisibleText {
    param([Parameter(Mandatory)][Windows.Automation.TextPattern] $TextPattern)
    $ranges = @($TextPattern.GetVisibleRanges())
    Normalize-ObserverText ([string]::Join('', @($ranges | ForEach-Object { $_.GetText(-1) })))
}

function Wait-AcceptanceMainWindowForeground {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $WaitSeconds, [Parameter(Mandatory)][string] $Label)
    $deadline = (Get-Date).AddSeconds([Math]::Min(5, $WaitSeconds))
    while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $Application.process.MainWindowHandle -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not [DarkReNamerVmAcceptanceNative]::IsWindowEnabled($Application.process.MainWindowHandle)) {
        throw "$Label did not restore the enabled owner."
    }
    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $Application.process.SessionId -RequireMainWindow
}
function Open-ObserverDiagnosticKeyboard {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId, [Parameter(Mandatory)][int] $WaitSeconds)
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow($Application.process.MainWindowHandle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId -RequireMainWindow
    Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x56 -Label 'View menu Alt+V'
    [void](Wait-AcceptancePopupMenu -Process $Application.process -ExpectedSession $SessionId -Label 'View menu for keyboard diagnostics')
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x49 -Label 'View diagnostic mnemonic I'
    Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name 'DarkReNamer - 선택 항목 진단' -TimeoutSeconds $WaitSeconds -Label 'keyboard selected-item diagnostic'
}

function Invoke-ObserverClipboardContention {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $DetailsWindow,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $CaptureLeaf,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $detailsHandle = [IntPtr]$DetailsWindow.Current.NativeWindowHandle
    $failure = $null
    [DarkReNamerVmAcceptanceNative]::HoldObserverClipboard()
    try {
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x43 -Label 'copy-all Clipboard contention Alt+C'
        $failure = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $DetailsWindow -Name 'DarkReNamer - 복사 실패' -TimeoutSeconds $WaitSeconds -Label 'copy-all Clipboard contention failure'
        [void]$Captures.Add((Save-WindowScreenshot -Window $failure -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf $CaptureLeaf -Label 'copy-all Clipboard contention failure'))
    }
    finally {
        [DarkReNamerVmAcceptanceNative]::ReleaseObserverClipboard()
    }
    if ($null -eq $failure) { throw 'Clipboard contention did not expose its failure dialog.' }
    $failureTree = Get-ObserverWindowTree -Window $failure -Process $Application.process -SessionId $SessionId -Label 'copy failure dialog'
    $failureHandle = [IntPtr]$failure.Current.NativeWindowHandle
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'dismiss copy failure dialog'
    Wait-WindowClosed -Handle $failureHandle -TimeoutSeconds $WaitSeconds -Label 'copy failure dialog'
    if (-not [DarkReNamerVmNative]::IsWindow($detailsHandle)) {
        throw 'Copy failure closed the read-only details window.'
    }
    $deadline = (Get-Date).AddSeconds(3)
    while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $detailsHandle -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $detailsHandle) {
        throw 'Read-only details did not regain foreground after copy failure.'
    }
    [ordered]@{
        hold = 'observer-process-openclipboard'
        failure_title = 'DarkReNamer - 복사 실패'
        failure_tree = $failureTree
        details_handle_preserved = $true
        details_foreground_restored = $true
        clipboard_released_in_finally = $true
    }
}

function Inspect-ObserverDiagnostic {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $ExpectedText,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][ValidateSet('escape', 'button')][string] $CloseMethod,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    $tree = Get-ObserverWindowTree -Window $Window -Process $Application.process -SessionId $SessionId -Label "$Prefix diagnostic"
    [void]$Captures.Add((Save-WindowScreenshot -Window $Window -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-diagnostic.png') -Label "$Prefix diagnostic"))
    Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-diagnostic-tree.json')) -Value $tree
    $editMatches = @($tree | Where-Object { $_.automation_id -ceq '1004' })
    $result = [ordered]@{
        title = $Window.Current.Name
        tree = $tree
        presentation = if ($editMatches.Count -eq 1) { 'read-only-multiline-edit' } else { 'message-box-baseline' }
        canonical_text = $null
        copy_selection = $null
        copy_all_mnemonic = $null
        baseline_ctrl_c = $null
        native_end_scroll = $null
        close = $null
    }
        $details = Get-ObserverReadOnlyDetails -Window $Window -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedText $ExpectedText -Label $Prefix
        $result.canonical_text = $details.evidence
        $result.copy_selection = Copy-GuiRegressionDocument -Mode selection -Application $Application -Edit $details.edit -ExpectedText $details.evidence.value_text -SessionId $SessionId -WaitSeconds $WaitSeconds -Label "$Prefix native edit selection copy"
        $result.copy_all_mnemonic = Copy-GuiRegressionDocument -Mode mnemonic -Application $Application -ExpectedText $details.evidence.value_text -SessionId $SessionId -WaitSeconds $WaitSeconds -Label "$Prefix explicit copy all"
        $details.edit.SetFocus()
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x23 -Label "$Prefix Ctrl+End"
        Start-Sleep -Milliseconds 150
        $visible = Get-ObserverVisibleText -TextPattern $details.text_pattern
        $ending = '파일 시스템 검사와 실행 확인은 변경 적용 시 별도로 수행합니다.'
        if (-not $visible.EndsWith($ending, [StringComparison]::Ordinal)) {
            throw "$Prefix did not expose the canonical ending after native scrolling."
        }
        [void]$Captures.Add((Save-WindowScreenshot -Window $Window -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-diagnostic-end.png') -Label "$Prefix diagnostic end scroll"))
        $result.native_end_scroll = [ordered]@{ input = 'native-edit-ctrl-end'; visible_text = $visible; ending_visible = $true }
    switch ($CloseMethod) {
        'escape' {
            Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label "$Prefix diagnostic Escape"
            Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label "$Prefix diagnostic"
            $result.close = [ordered]@{ input = 'keyboard-escape'; closed = $true }
        }
        'button' {
            $close = Find-UniqueAutomationElement -Root $Window -Process $Application.process -ExpectedSession $SessionId -AutomationId '2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label "$Prefix close button" -RequireEnabled -RequireWindowHandle
            Invoke-AutomationControl -Element $close -Label "$Prefix close button"
            Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label "$Prefix diagnostic"
            $result.close = [ordered]@{ input = 'close-button-id-2'; closed = $true }
        }
    }
    Wait-AcceptanceMainWindowForeground -Application $Application -WaitSeconds $WaitSeconds -Label "$Prefix diagnostic close"
    $result
}

function Get-ObserverConfirmationDefaultFocus {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId)
    $focused = Get-FocusedAcceptanceElement -Process $Application.process -ExpectedSession $SessionId -Label 'confirmation default focus'
    $snapshot = Get-ElementObservation -Element $focused
    $snapshot['is_default_cancel'] = $snapshot.automation_id -ceq 'CommandButton_2' -or $snapshot.name -ceq '취소'
    if (-not $snapshot.is_default_cancel) { throw 'Confirmation default focus is not Cancel.' }
    $snapshot
}

function Wait-ObserverConfirmation {
    param([Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId, [Parameter(Mandatory)][int] $WaitSeconds, [Parameter(Mandatory)][string] $Label)
    Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name 'DarkReNamer - 안전한 적용 확인' -TimeoutSeconds $WaitSeconds -Label $Label
}

function Start-ObserverApplyFromPublicUi {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][string] $Label
    )
    $id = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, '32771')
    $buttonType = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::Button)
    $apply = $Application.main.FindFirst(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.AndCondition]::new($id, $buttonType))
    if ($null -ne $apply -and $apply.Current.IsEnabled -and -not $apply.Current.IsOffscreen) {
        Assert-AutomationBinding -Element $apply -Process $Application.process -ExpectedSession $SessionId -Label $Label
        return [pscustomobject]@{
            input = 'visible-command-rail'
            invocation = Start-AutomationControlInvoke -Element $apply -Label $Label
            menu_entry = $null
        }
    }

    $menuType = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::MenuItem)
    $fileMenus = @($Application.main.FindAll(
        [Windows.Automation.TreeScope]::Descendants, $menuType) |
        Where-Object { $_.Current.Name -ceq '파일(F)' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($fileMenus.Count -ne 1) {
        throw "$Label has neither a visible command rail nor one public File menu."
    }
    Assert-AutomationBinding -Element $fileMenus[0] -Process $Application.process -ExpectedSession $SessionId -Label "$Label File menu fallback"
    $menu = Get-ElementObservation -Element $fileMenus[0]
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow($Application.process.MainWindowHandle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId -RequireMainWindow
    $mainHandle = [IntPtr]$Application.main.Current.NativeWindowHandle
    $fileTarget = Get-GuiRegressionPhysicalTarget -Click -Element $fileMenus[0] -Application $Application -SessionId $SessionId -ExpectedRoot $mainHandle -Label "$Label File menu"
    $popup = Wait-AcceptancePopupMenu -Process $Application.process -ExpectedSession $SessionId -Label "$Label File popup"
    $popupElement = [Windows.Automation.AutomationElement]::FromHandle($popup)
    $items = @($popupElement.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::MenuItem)))
    $matches = @($items | Where-Object { $_.Current.Name -like '*변경 사항 적용*' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($matches.Count -ne 1) { throw "$Label public File menu Apply matched $($matches.Count) items." }
    $menuItem = Get-ElementObservation -Element $matches[0]
    $itemTarget = Get-GuiRegressionPhysicalTarget -Click -Element $matches[0] -Application $Application -SessionId $SessionId -ExpectedRoot $popup -Label "$Label public File menu Apply"
    Wait-AcceptancePopupMenuClosed -Process $Application.process -Label "$Label File popup"
    [pscustomobject]@{
        input = 'physical-mouse-file-menu-public-apply'
        invocation = $null
        menu_entry = [ordered]@{
            file = $menu
            file_target = $fileTarget
            apply = $menuItem
            apply_target = $itemTarget
        }
    }
}

function Scroll-ObserverTaskDialogToEnd {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Confirmation,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $CaptureLeaf,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $scrollCondition = [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'VerticalScrollBar'),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ScrollBar))
    $scrolls = @($Confirmation.FindAll([Windows.Automation.TreeScope]::Descendants, $scrollCondition) |
        Where-Object { $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($scrolls.Count -eq 0) {
        [void]$Captures.Add((Save-WindowScreenshot -Window $Confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf $CaptureLeaf -Label "$Label fully visible"))
        return [ordered]@{
            input = 'none'
            scrollbar = $null
            physical_targets = @()
            tree = Get-ObserverWindowTree -Window $Confirmation -Process $Application.process -SessionId $SessionId -Label "$Label fully visible"
            bottom_capture = $CaptureLeaf
            visual_review_required_for_content_tail = $true
            status = 'native-scrollbar-not-present-content-fits'
        }
    }
    if ($scrolls.Count -ne 1) { throw "$Label vertical scrollbar matched $($scrolls.Count) elements." }
    $scroll = $scrolls[0]
    $buttons = @($scroll.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::Button)))
    $down = @($buttons | Where-Object { $_.Current.Name -ceq '아래쪽 스크롤 화살표' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($down.Count -ne 1) { throw "$Label down-scroll button matched $($down.Count) elements." }
    $root = [IntPtr]$Confirmation.Current.NativeWindowHandle
    $targets = [Collections.Generic.List[object]]::new()

    $rangeObject = $null
    $range = if ($scroll.TryGetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern, [ref]$rangeObject)) {
        [Windows.Automation.RangeValuePattern]$rangeObject
    } else { $null }

    $scrollPattern = $null
    if ($null -eq $range) {
        $patternCandidates = [Collections.Generic.List[Windows.Automation.AutomationElement]]::new()
        $patternCandidates.Add($Confirmation)
        foreach ($candidate in $Confirmation.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
            $patternCandidates.Add($candidate)
        }
        foreach ($candidate in $patternCandidates) {
            $candidatePattern = $null
            if ($candidate.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$candidatePattern)) {
                $typedPattern = [Windows.Automation.ScrollPattern]$candidatePattern
                if ($typedPattern.Current.VerticallyScrollable) {
                    if ($null -ne $scrollPattern) { throw "$Label exposed more than one vertically scrollable UIA container." }
                    $scrollPattern = $typedPattern
                }
            }
        }
    }

    $nativeCandidates = [Collections.Generic.List[object]]::new()
    if ($null -eq $range -and $null -eq $scrollPattern) {
        $scrollHandle = [IntPtr]$scroll.Current.NativeWindowHandle
        if ($scrollHandle -ne [IntPtr]::Zero) {
            $nativeCandidates.Add([ordered]@{ handle = $scrollHandle; bar = 2; origin = 'scrollbar-uia-hwnd'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($scrollHandle) })
        }
        $scrollRect = $scroll.Current.BoundingRectangle
        $scrollPoint = [DarkReNamerVmAcceptanceNative+Point]::new()
        $scrollPoint.X = [int][Math]::Floor($scrollRect.Left + ($scrollRect.Width / 2.0))
        $scrollPoint.Y = [int][Math]::Floor($scrollRect.Top + ($scrollRect.Height / 2.0))
        $hitHandle = [DarkReNamerVmAcceptanceNative]::WindowFromPoint($scrollPoint)
        if ($hitHandle -ne [IntPtr]::Zero -and $hitHandle -ne $scrollHandle) {
            $nativeCandidates.Add([ordered]@{ handle = $hitHandle; bar = 2; origin = 'scrollbar-center-window-from-point-sb-ctl'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($hitHandle) })
            $nativeCandidates.Add([ordered]@{ handle = $hitHandle; bar = 1; origin = 'scrollbar-center-window-from-point-sb-vert'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($hitHandle) })
        }
        $nativeCandidates.Add([ordered]@{ handle = $root; bar = 1; origin = 'taskdialog-root-sb-vert'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($root) })
        $nativeCandidates.Add([ordered]@{ handle = $root; bar = 2; origin = 'taskdialog-root-sb-ctl'; description = [DarkReNamerVmAcceptanceNative]::DescribeWindow($root) })
    }
    $native = $null
    foreach ($candidate in $nativeCandidates) {
        $values = [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo([IntPtr]$candidate.handle, [int]$candidate.bar)
        if ($null -eq $values -or $values.Count -ne 5) { continue }
        $bottomPosition = [int]$values[1] - [Math]::Max(([int]$values[2] - 1), 0)
        if ([int]$values[1] -le [int]$values[0] -or [int]$values[2] -le 0 -or [int]$values[3] -ge $bottomPosition) { continue }
        $native = [ordered]@{
            handle = ([IntPtr]$candidate.handle).ToInt64()
            bar = [int]$candidate.bar
            origin = $candidate.origin
            description = $candidate.description
            initial = [ordered]@{ minimum = [int]$values[0]; maximum = [int]$values[1]; page = [int]$values[2]; position = [int]$values[3]; bottom_position = $bottomPosition }
        }
        break
    }
    if ($null -eq $range -and $null -eq $scrollPattern -and $null -eq $native) {
        throw "$Label exposes no verifiable UIA or Win32 scroll position state."
    }

    $initialValue = if ($null -ne $range) { [double]$range.Current.Value } elseif ($null -ne $scrollPattern) { [double]$scrollPattern.Current.VerticalScrollPercent } else { [int]$native.initial.position }
    $maximum = if ($null -ne $range) { [double]$range.Current.Maximum } elseif ($null -ne $scrollPattern) { 100.0 } else { [int]$native.initial.bottom_position }
    $finalValue = $initialValue
    for ($index = 0; $index -lt 128 -and $finalValue -lt $maximum; $index++) {
        $targets.Add((Get-GuiRegressionPhysicalTarget -Click -Element $down[0] -Application $Application -SessionId $SessionId -ExpectedRoot $root -Label "$Label down-scroll arrow"))
        Start-Sleep -Milliseconds 35
        if ($null -ne $range) {
            $finalValue = [double]$range.Current.Value
        } elseif ($null -ne $scrollPattern) {
            $finalValue = [double]$scrollPattern.Current.VerticalScrollPercent
        } else {
            $values = [DarkReNamerVmAcceptanceNative]::TryReadScrollInfo([IntPtr]$native.handle, [int]$native.bar)
            if ($null -eq $values -or $values.Count -ne 5) { throw "$Label lost Win32 scroll position state during physical scrolling." }
            $expectedBottom = [int]$values[1] - [Math]::Max(([int]$values[2] - 1), 0)
            if ($expectedBottom -ne [int]$native.initial.bottom_position) { throw "$Label Win32 scroll range changed during physical scrolling." }
            $finalValue = [int]$values[3]
        }
    }
    if ($finalValue -lt $maximum) {
        throw "$Label did not reach the verified scrollbar bottom after 128 physical clicks."
    }
    $tree = Get-ObserverWindowTree -Window $Confirmation -Process $Application.process -SessionId $SessionId -Label "$Label bottom"
    [void]$Captures.Add((Save-WindowScreenshot -Window $Confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf $CaptureLeaf -Label "$Label bottom"))
    [ordered]@{
        input = 'bounded physical mouse clicks on native TaskDialog down-scroll arrow'
        scrollbar = Get-ElementObservation -Element $scroll
        physical_targets = $targets.ToArray()
        range_value = [ordered]@{
            provider = if ($null -ne $range) { 'UIAutomation.RangeValuePattern' } elseif ($null -ne $scrollPattern) { 'UIAutomation.ScrollPattern.VerticalScrollPercent' } else { 'Win32.GetScrollInfo' }
            initial = $initialValue
            final = $finalValue
            maximum = $maximum
            reached_maximum = $true
            win32 = $native
        }
        tree = $tree
        bottom_capture = $CaptureLeaf
        visual_review_required_for_content_tail = $true
        status = 'physically-scrolled-to-native-bottom'
    }
}

function Open-ObserverConfirmationDetails {
    param([Parameter(Mandatory)][Windows.Automation.AutomationElement] $Confirmation, [Parameter(Mandatory)][object] $Application, [Parameter(Mandatory)][int] $SessionId, [Parameter(Mandatory)][int] $WaitSeconds)
    $button = Find-UniqueAutomationElement -Root $Confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1102' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'confirmation full-details command link' -RequireEnabled
    if ($button.Current.Name -cne '예시 전체 정보 · 복사') { throw 'Confirmation full-details command text differs.' }
    $buttonObservation = Get-ElementObservation -Element $button
    if ($buttonObservation.automation_id -cne 'CommandLink_1102') {
        throw "Full-details command link has unexpected AutomationId $($buttonObservation.automation_id)."
    }
    $button.SetFocus()
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'confirmation full-details command link Enter'
    $details = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name 'DarkReNamer - 변경 예시 전체 정보' -TimeoutSeconds $WaitSeconds -Label 'confirmation full-details prompt'
    [pscustomobject]@{ window = $details; command_link = $buttonObservation }
}

function Get-ObserverPublicApplyState {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][string] $Label
    )
    $id = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, '32771')
    $buttonType = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
    $rail = $Application.main.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.AndCondition]::new($id, $buttonType))
    if ($null -ne $rail -and -not $rail.Current.IsOffscreen) {
        Assert-AutomationBinding -Element $rail -Process $Application.process -ExpectedSession $SessionId -Label "$Label visible rail"
        return [ordered]@{ source = 'visible-command-rail'; enabled = [bool]$rail.Current.IsEnabled; automation = Get-ElementObservation -Element $rail }
    }
    $menuType = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::MenuItem)
    $fileMenus = @($Application.main.FindAll([Windows.Automation.TreeScope]::Descendants, $menuType) | Where-Object { $_.Current.Name -ceq '파일(F)' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($fileMenus.Count -ne 1) { throw "$Label public File menu matched $($fileMenus.Count) elements." }
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow($Application.process.MainWindowHandle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId -RequireMainWindow
    $fileTarget = Get-GuiRegressionPhysicalTarget -Click -Element $fileMenus[0] -Application $Application -SessionId $SessionId -ExpectedRoot ([IntPtr]$Application.main.Current.NativeWindowHandle) -Label "$Label File menu"
    $popup = Wait-AcceptancePopupMenu -Process $Application.process -ExpectedSession $SessionId -Label "$Label File popup"
    try {
        $popupElement = [Windows.Automation.AutomationElement]::FromHandle($popup)
        $items = @($popupElement.FindAll([Windows.Automation.TreeScope]::Descendants, $menuType))
        $matches = @($items | Where-Object { $_.Current.Name -like '*변경 사항 적용*' -and -not $_.Current.IsOffscreen })
        if ($matches.Count -ne 1) { throw "$Label public File menu Apply matched $($matches.Count) items." }
        [ordered]@{ source = 'physical-file-menu'; enabled = [bool]$matches[0].Current.IsEnabled; file_target = $fileTarget; automation = Get-ElementObservation -Element $matches[0] }
    }
    finally {
        Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label "$Label close File popup"
        Wait-AcceptancePopupMenuClosed -Process $Application.process -Label "$Label File popup"
    }
}

function Invoke-ObserverBlockedChecks {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][object] $Fixture,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $status = Find-UniqueAutomationElement -Root $Application.main -Process $Application.process -ExpectedSession $SessionId -AutomationId '1007' -ControlType ([Windows.Automation.ControlType]::Text) -TimeoutSeconds $WaitSeconds -Label 'blocked-check status message' -RequireWindowHandle
    $reset = Find-UniqueAutomationElement -Root $Application.main -Process $Application.process -ExpectedSession $SessionId -AutomationId '32781' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'blocked-check reset names' -RequireWindowHandle
    Invoke-AutomationControl -Element $reset -Label 'blocked-check reset names'
    Start-Sleep -Milliseconds 200
    $applyState = Get-ObserverPublicApplyState -Application $Application -SessionId $SessionId -Label 'blocked-check no-change Apply command'
    if ($applyState.enabled) { throw 'Apply stayed enabled with no changes.' }
    [void]$Captures.Add((Save-WindowScreenshot -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-blocked-no-change.png') -Label 'no-change blocked state'))
    $noChange = [ordered]@{ apply = $applyState; status = $status.Current.Name; blocked = $true }

    $collisionName = '충돌-😀-같은-대상.txt'
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 0 -Name $collisionName -SessionId $SessionId -WaitSeconds $WaitSeconds
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 1 -Name $collisionName -SessionId $SessionId -WaitSeconds $WaitSeconds
    Start-Sleep -Milliseconds 200
    $collisionStatus = $status.Current.Name
    $applyState = Get-ObserverPublicApplyState -Application $Application -SessionId $SessionId -Label 'blocked-check collision Apply command'
    if ($applyState.enabled -or $collisionStatus.IndexOf('대상 경로 충돌', [StringComparison]::Ordinal) -lt 0) {
        throw 'Collision state did not block Apply with its existing meaning.'
    }
    [void]$Captures.Add((Save-WindowScreenshot -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-blocked-collision.png') -Label 'collision blocked state'))
    $collision = [ordered]@{ apply = $applyState; status = $collisionStatus; blocked = $true }

    Invoke-AutomationControl -Element $reset -Label 'reset collision proposals'
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 0 -Name 'bad:name.txt' -SessionId $SessionId -WaitSeconds $WaitSeconds
    Start-Sleep -Milliseconds 200
    $invalidStatus = $status.Current.Name
    $applyState = Get-ObserverPublicApplyState -Application $Application -SessionId $SessionId -Label 'blocked-check invalid-name Apply command'
    if ($applyState.enabled -or $invalidStatus.IndexOf('잘못된 대상 이름', [StringComparison]::Ordinal) -lt 0) {
        throw 'Invalid-name state did not block Apply with its existing meaning.'
    }
    [void]$Captures.Add((Save-WindowScreenshot -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-blocked-invalid.png') -Label 'invalid-name blocked blocked state'))
    $invalid = [ordered]@{ apply = $applyState; status = $invalidStatus; blocked = $true }
    Invoke-AutomationControl -Element $reset -Label 'reset invalid proposal'
    Start-Sleep -Milliseconds 200
    $actual = Get-ObserverFixtureState -FixtureRoot $Fixture.root
    if (-not (Test-ObserverFixtureStateEqual -Expected $Fixture.initial -Actual $actual)) {
        throw 'Blocking checks changed a fixture file, content digest, or NTFS identity.'
    }
    Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
    [ordered]@{ no_change = $noChange; collision = $collision; invalid_name = $invalid; disk_unchanged = $true; journal_residue_count = 0 }
}

function Invoke-ObserverActualApply {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][object] $Fixture,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 0 -Name $Fixture.destination_names[0] -SessionId $SessionId -WaitSeconds $WaitSeconds
    Set-ObserverManualName -Application $Application -Grid $Grid -Row 1 -Name $Fixture.destination_names[1] -SessionId $SessionId -WaitSeconds $WaitSeconds
    $selection = Set-ObserverSelectedRow -Application $Application -Grid $Grid -Row 0 -SessionId $SessionId
    [void]$Captures.Add((Save-WindowScreenshot -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-actual-apply-preview.png') -Label 'actual 3/1/2 Apply preview'))

    $applyTrigger = Start-ObserverApplyFromPublicUi -Application $Application -SessionId $SessionId -Label 'actual 3/1/2 Apply command'
    $applyInvocation = $applyTrigger.invocation
    $confirmation = Wait-ObserverConfirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'actual 3/1/2 Apply confirmation'
    $tree = Get-ObserverWindowTree -Window $confirmation -Process $Application.process -SessionId $SessionId -Label 'actual 3/1/2 Apply confirmation'
    if (([string]::Join("`n", @($tree | ForEach-Object { $_.name } | Where-Object { $_ }))).IndexOf('목록 전체 3개 · 선택 1개 · 실제 변경 2개', [StringComparison]::Ordinal) -lt 0) {
        throw 'Actual Apply confirmation lost the exact 3/1/2 scope.'
    }
    [void]$Captures.Add((Save-WindowScreenshot -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-actual-apply-confirmation.png') -Label 'actual 3/1/2 Apply confirmation'))
    $confirm = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1101' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'actual Apply command link' -RequireEnabled -RequireWindowHandle
    $confirmInvocation = Start-AutomationControlInvoke -Element $confirm -Label 'actual Apply command link'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $complete = -not (Test-Path -LiteralPath $Fixture.paths[0]) -and
            -not (Test-Path -LiteralPath $Fixture.paths[1]) -and
            (Test-Path -LiteralPath $Fixture.destinations[0] -PathType Leaf) -and
            (Test-Path -LiteralPath $Fixture.destinations[1] -PathType Leaf) -and
            (Test-Path -LiteralPath $Fixture.paths[2] -PathType Leaf)
        if ($complete) {
            try { Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA; break } catch {}
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    Complete-AutomationControlInvoke -State $confirmInvocation -TimeoutSeconds $WaitSeconds
    if ($null -ne $applyInvocation) { Complete-AutomationControlInvoke -State $applyInvocation -TimeoutSeconds $WaitSeconds }
    if (-not $complete) { throw 'Actual 3/1/2 Apply did not reach the exact destination paths.' }
    Wait-AcceptanceMainWindowForeground -Application $Application -WaitSeconds $WaitSeconds -Label 'actual 3/1/2 Apply'

    $initial0 = @($Fixture.initial | Where-Object { $_.path -ceq $Fixture.paths[0] })[0]
    $initial1 = @($Fixture.initial | Where-Object { $_.path -ceq $Fixture.paths[1] })[0]
    $initial2 = @($Fixture.initial | Where-Object { $_.path -ceq $Fixture.paths[2] })[0]
    $actual0 = Get-Item -LiteralPath $Fixture.destinations[0] -Force
    $actual1 = Get-Item -LiteralPath $Fixture.destinations[1] -Force
    $actual2 = Get-Item -LiteralPath $Fixture.paths[2] -Force
    $preserved = (Get-LowerSha256 -Path $actual0.FullName) -ceq $initial0.content_sha256 -and
        [DarkReNamerVmNative]::GetFileIdentity($actual0.FullName) -ceq $initial0.identity -and
        (Get-LowerSha256 -Path $actual1.FullName) -ceq $initial1.content_sha256 -and
        [DarkReNamerVmNative]::GetFileIdentity($actual1.FullName) -ceq $initial1.identity -and
        (Get-LowerSha256 -Path $actual2.FullName) -ceq $initial2.content_sha256 -and
        [DarkReNamerVmNative]::GetFileIdentity($actual2.FullName) -ceq $initial2.identity
    if (-not $preserved) { throw 'Actual 3/1/2 Apply changed content or NTFS identity.' }
    Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
    [void]$Captures.Add((Save-WindowScreenshot -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-actual-apply-complete.png') -Label 'actual 3/1/2 Apply completion'))
    [ordered]@{ scope = '3/1/2'; apply_entry = [ordered]@{ input = $applyTrigger.input; menu_entry = $applyTrigger.menu_entry }; selection = $selection; destinations_reached = $true; unchanged_row_preserved = $true; content_and_identity_preserved = $true; journal_residue_count = 0 }
}

function Close-AcceptanceApplication {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][ValidateSet('keyboard', 'ordinary')][string] $Input
    )
    $Application.process.Refresh()
    if ($Application.process.HasExited) { throw 'The acceptance application exited before normal close.' }
    if ($Input -ceq 'keyboard') {
        $Application.main.SetFocus()
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x73 -Label 'application Alt+F4 close'
    }
    elseif (-not $Application.process.CloseMainWindow()) {
        throw 'The acceptance application rejected ordinary close.'
    }
    if (-not $Application.process.WaitForExit([Math]::Min(30, $WaitSeconds) * 1000)) {
        throw 'The acceptance application did not close before the bounded deadline.'
    }
    if ($Application.process.ExitCode -ne 0) { throw 'The acceptance application returned a nonzero exit code.' }
    $Application.process.ExitCode
}

function Get-ObserverControlReachability {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][IntPtr] $ExpectedRoot,
        [Parameter(Mandatory)][object] $WorkArea,
        [Parameter(Mandatory)][string] $Label
    )
    $snapshot = Get-ElementObservation -Element $Element
    $bounds = $snapshot.bounds
    $insideWorkArea = -not $snapshot.offscreen -and
        $bounds.x -ge $WorkArea.left -and $bounds.y -ge $WorkArea.top -and
        ($bounds.x + $bounds.width) -le $WorkArea.right -and
        ($bounds.y + $bounds.height) -le $WorkArea.bottom
    $mouse = $null
    $failure = $null
    if ($insideWorkArea) {
        try {
            $mouse = Get-GuiRegressionPhysicalTarget -Element $Element -Application $Application -SessionId $SessionId -ExpectedRoot $ExpectedRoot -Label $Label
        }
        catch { $failure = $_.Exception.Message }
    }
    else { $failure = 'control-bounds-outside-work-area' }
    [ordered]@{
        label = $Label
        status = if ($insideWorkArea -and $null -ne $mouse) { 'reachable' } else { 'inaccessible' }
        inside_work_area = $insideWorkArea
        automation = $snapshot
        physical_mouse_target = $mouse
        observation = $failure
    }
}

function New-ObserverRepeatedFixture {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $root = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'repeated-fixture'
    # Admission sorts these ASCII/Korean leaves in ordinal order: 0, a, 가.
    $sources = @((('0' * 101) + '.txt'), (('a' * 100) + '.txt'), (('가' * 100) + '.txt'))
    $destinations = @((('0' * 100) + '.txt'), (('a' * 101) + '.txt'), (('가' * 101) + '.txt'))
    $paths = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $sources.Count; $index++) {
        $path = Join-Path $root $sources[$index]
        [IO.File]::WriteAllText($path, "repeated-context-$index`n", [Text.UTF8Encoding]::new($false))
        $paths.Add($path)
    }
    [pscustomobject]@{
        root = $root
        paths = $paths.ToArray()
        paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths $paths.ToArray()
        source_names = $sources
        destination_names = $destinations
        destination_paths = @(
            (Join-Path $root $destinations[0]),
            (Join-Path $root $destinations[1]),
            (Join-Path $root $destinations[2])
        )
        initial = Get-ObserverFixtureState -FixtureRoot $root
    }
}

function New-ObserverMoveFixture {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $requestedRoot = 'C:\fixture'
    $fixedOccupied = Test-Path -LiteralPath $requestedRoot
    if ($fixedOccupied) {
        $root = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'fixture-equivalent'
        $ownsFixedRoot = $false
    }
    else {
        [void](New-Item -ItemType Directory -Path $requestedRoot)
        $root = (Get-Item -LiteralPath $requestedRoot -Force).FullName
        $ownsFixedRoot = $true
        $script:ownedContextFixedRoot = $root
    }
    $rootItem = Get-Item -LiteralPath $root -Force
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        @(Get-ChildItem -LiteralPath $root -Force).Count -ne 0) {
        throw 'Move fixture root is occupied, unsafe, or not empty.'
    }
    $parentA = New-PrivateDirectory -Parent $root -Leaf 'A'
    $parentB = New-PrivateDirectory -Parent $root -Leaf 'B'
    $source = Join-Path $parentA 'old.txt'
    $destination = Join-Path $parentB 'new.txt'
    [IO.File]::WriteAllText($source, "move-context-content`n", [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{
        requested_root = $requestedRoot
        root = $root
        fixed_path_occupied = $fixedOccupied
        isolated_equivalent = $fixedOccupied
        owns_fixed_root = $ownsFixedRoot
        parent_a = $parentA
        parent_b = $parentB
        source = $source
        destination = $destination
        paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths @($source)
        initial = Get-ObserverFixtureState -FixtureRoot $root
    }
}

function New-ObserverMixedFixture {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $root = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'mixed-fixture'
    $parentA = New-PrivateDirectory -Parent $root -Leaf 'A'
    $parentD = New-PrivateDirectory -Parent $root -Leaf 'D'
    $sources = @(
        (Join-Path $parentA '01-rename.txt'),
        (Join-Path $parentA '02-rename.txt'),
        (Join-Path $parentA '03-unsampled-move.txt')
    )
    $prefix = '검증-'
    $destinations = @(
        (Join-Path $parentA ($prefix + '01-rename.txt')),
        (Join-Path $parentA ($prefix + '02-rename.txt')),
        (Join-Path $parentD ($prefix + '03-unsampled-move.txt'))
    )
    for ($index = 0; $index -lt $sources.Count; $index++) {
        [IO.File]::WriteAllText($sources[$index], "mixed-context-$index`n", [Text.UTF8Encoding]::new($false))
    }
    [pscustomobject]@{
        root = $root
        parent_a = $parentA
        parent_d = $parentD
        prefix = $prefix
        sources = $sources
        destinations = $destinations
        first_paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths @($sources[2]) -Leaf 'mixed-first-utf16le.txt'
        later_paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths @($sources[0], $sources[1]) -Leaf 'mixed-later-utf16le.txt'
        initial = Get-ObserverFixtureState -FixtureRoot $root
    }
}

function Set-ObserverDestinationParent {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][string] $DestinationParent,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )
    Add-Type -AssemblyName System.Windows.Forms
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow($Application.process.MainWindowHandle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId -RequireMainWindow
    [Windows.Forms.SendKeys]::SendWait('%ed{ENTER}')
    $dialog = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name '모든 파일을 이동할 대상 폴더 선택' -TimeoutSeconds $WaitSeconds -Label 'move destination folder picker'
    $handle = [IntPtr]$dialog.Current.NativeWindowHandle
    $dialogSnapshot = Get-ElementObservation -Element $dialog
    [Windows.Forms.SendKeys]::SendWait('^l')
    $address = Get-FocusedAcceptanceElement -Process $Application.process -ExpectedSession $SessionId -Label 'folder picker address edit'
    if ($address.Current.ControlType -ne [Windows.Automation.ControlType]::Edit) {
        throw 'Folder picker Ctrl+L did not focus an editable address control.'
    }
    Set-AutomationControlValue -Element $address -Value $DestinationParent -Label 'folder picker destination address'
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'folder picker address Enter'
    Start-Sleep -Milliseconds 300
    $choose = Find-UniqueAutomationElement -Root $dialog -Process $Application.process -ExpectedSession $SessionId -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'folder picker Select Folder button' -RequireEnabled -RequireWindowHandle
    $chooseSnapshot = Get-ElementObservation -Element $choose
    $mouse = Get-GuiRegressionPhysicalTarget -Click -Element $choose -Application $Application -SessionId $SessionId -ExpectedRoot $handle -Label 'folder picker Select Folder button'
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label 'move destination folder picker'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $actual = $Grid.pattern.GetItem(0, 2).Current.Name
        if ($actual -ceq $DestinationParent) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($actual -cne $DestinationParent) {
        throw 'Move preview did not expose the exact selected destination parent.'
    }
    [ordered]@{
        input = 'keyboard-menu-alt-e-d-enter-address-ctrl-l-enter-physical-select-folder'
        dialog = $dialogSnapshot
        choose_button = $chooseSnapshot
        physical_click = $mouse
        destination_parent = $DestinationParent
        preview_parent_exact = $true
    }
}

function Get-ObserverBoundedDifferenceSnippet {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int] $FocusStart,
        [Parameter(Mandatory)][int] $FocusEnd
    )
    $limit = 56
    $length = $Text.Length
    if ($length -le $limit) { return $Text }
    $focusStart = [Math]::Min($FocusStart, $length)
    $focusEnd = [Math]::Max($focusStart, [Math]::Min($FocusEnd, $length))
    $focusLength = $focusEnd - $focusStart
    if ($focusLength + 2 -le $limit) {
        $available = $limit - $focusLength - 2
        $left = [Math]::Min($focusStart, [Math]::Floor($available / 2))
        $right = [Math]::Min($length - $focusEnd, $available - $left)
        $available -= $left + $right
        if ($available -ne 0) {
            $extraLeft = [Math]::Min($focusStart - $left, $available)
            $left += $extraLeft
            $available -= $extraLeft
            $right += [Math]::Min($length - $focusEnd - $right, $available)
        }
        $shownStart = $focusStart - $left
        $shownLength = $focusLength + $left + $right
        return $(if ($shownStart -ne 0) { '…' } else { '' }) +
            $Text.Substring($shownStart, $shownLength) +
            $(if ($shownStart + $shownLength -ne $length) { '…' } else { '' })
    }
    $leadingEllipsis = [int]($focusStart -ne 0)
    $trailingEllipsis = [int]($focusEnd -ne $length)
    $visibleFocus = $limit - $leadingEllipsis - $trailingEllipsis - 1
    $leadingFocus = [Math]::Floor($visibleFocus / 2)
    $trailingFocus = $visibleFocus - $leadingFocus
    return $(if ($leadingEllipsis -ne 0) { '…' } else { '' }) +
        $Text.Substring($focusStart, $leadingFocus) +
        '…' +
        $Text.Substring($focusEnd - $trailingFocus, $trailingFocus) +
        $(if ($trailingEllipsis -ne 0) { '…' } else { '' })
}

function Get-ObserverDifferenceSnippetPair {
    param(
        [Parameter(Mandatory)][string] $Current,
        [Parameter(Mandatory)][string] $After
    )
    $prefix = 0
    while ($prefix -lt [Math]::Min($Current.Length, $After.Length) -and $Current[$prefix] -ceq $After[$prefix]) {
        $prefix++
    }
    $maximumSuffix = [Math]::Min($Current.Length - $prefix, $After.Length - $prefix)
    $suffix = 0
    while ($suffix -lt $maximumSuffix -and $Current[$Current.Length - 1 - $suffix] -ceq $After[$After.Length - 1 - $suffix]) {
        $suffix++
    }
    [ordered]@{
        current = Get-ObserverBoundedDifferenceSnippet -Text $Current -FocusStart $prefix -FocusEnd ($Current.Length - $suffix)
        after = Get-ObserverBoundedDifferenceSnippet -Text $After -FocusStart $prefix -FocusEnd ($After.Length - $suffix)
    }
}

function Invoke-ObserverContextConfirmation {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $ExpectedScope,
        [Parameter(Mandatory)][string] $ExpectedFullText,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ExpectedDestinationParent,
        [AllowEmptyString()][string] $ExpectedDestinationPath = '',
        [switch] $ExpectItemSpecificDestination,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][object] $WorkArea,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures,
        [switch] $PhysicalMouseActivation,
        [switch] $Standard
    )
    $tooltipProbe = [bool]$script:contract.tooltip_regression
    $preModalTooltip = $null
    if ($tooltipProbe) {
        $gridForTooltip = Get-ObserverGrid -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds
        $listViewHandle = [IntPtr]$gridForTooltip.element.Current.NativeWindowHandle
        if ($listViewHandle -eq [IntPtr]::Zero) { throw 'Context ListView has no native HWND for tooltip identity.' }
        $tooltipHandle = [DarkReNamerVmAcceptanceNative]::ReadListViewTooltip($listViewHandle)
        if ($tooltipHandle -eq 0) { throw 'LVM_GETTOOLTIPS returned no ListView infotip HWND.' }
        $mainBounds = $Application.main.Current.BoundingRectangle
        $neutralPoint = [DarkReNamerVmAcceptanceNative+Point]::new()
        $neutralPoint.X = [int][Math]::Floor($mainBounds.Left + ($mainBounds.Width / 2.0))
        $neutralPoint.Y = [int][Math]::Floor($mainBounds.Top + [Math]::Min(10.0, $mainBounds.Height / 2.0))
        [DarkReNamerVmAcceptanceNative]::MoveCursor($neutralPoint.X, $neutralPoint.Y)
        Start-Sleep -Milliseconds 600
        $neutralWindows = Get-ObserverProcessWindows -Process $Application.process
        if (@($neutralWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible }).Count -ne 0) {
            throw 'ListView infotip did not hide at the neutral title-bar point.'
        }
        $hoverColumn = 0
        $hoverCell = $gridForTooltip.pattern.GetItem(0, $hoverColumn)
        if ($hoverCell.Current.IsOffscreen) { throw 'Tooltip overlap probe current-name cell is offscreen.' }
        $rowRect = $hoverCell.Current.BoundingRectangle
        $point = [DarkReNamerVmAcceptanceNative+Point]::new()
        $point.X = [int][Math]::Floor($rowRect.Left + [Math]::Min(8.0, $rowRect.Width / 2.0))
        $point.Y = [int][Math]::Floor($rowRect.Top + ($rowRect.Height / 2.0))
        [DarkReNamerVmAcceptanceNative]::MoveCursor($point.X, $point.Y)
        $hit = [DarkReNamerVmAcceptanceNative]::WindowFromPoint($point)
        $mainRoot = [IntPtr]$Application.main.Current.NativeWindowHandle
        if ([DarkReNamerVmAcceptanceNative]::GetAncestor($hit, [uint32]2) -ne $mainRoot) {
            throw 'Tooltip overlap probe hover point did not hit the exact application root.'
        }
        $visibleTooltip = @()
        for ($attempt = 0; $attempt -lt 30 -and $visibleTooltip.Count -ne 1; $attempt++) {
            Start-Sleep -Milliseconds 100
            $hoverWindows = Get-ObserverProcessWindows -Process $Application.process
            $visibleTooltip = @($hoverWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible -and $_.rect.height -ge 100 })
        }
        if ($visibleTooltip.Count -ne 1) { throw 'Ordinary current-name hover did not expose the bound multiline ListView infotip HWND.' }
        $preModalTooltip = [ordered]@{
            input = 'physical-mouse-hover-without-click'
            neutral_point = [ordered]@{ x = $neutralPoint.X; y = $neutralPoint.Y }
            point = [ordered]@{ x = $point.X; y = $point.Y; hit_window = $hit.ToInt64(); root_window = $mainRoot.ToInt64() }
            listview_hwnd = $listViewHandle.ToInt64()
            listview_tooltip_hwnd = $tooltipHandle
            hovered_column = $hoverColumn
            hovered_cell = Get-ElementObservation -Element $hoverCell
            hover_state = 'multiline-infotip-visible-before-keyboard-apply'
            visible_before_public_apply = $true
            window = $visibleTooltip[0]
        }
    }
    $applyTrigger = if ($tooltipProbe) {
        Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x53 -Label 'context public Ctrl+S Apply with visible ListView infotip'
        [pscustomobject]@{ input = 'keyboard-ctrl-s-with-visible-listview-infotip'; invocation = $null; menu_entry = $null }
    }
    else {
        Start-ObserverApplyFromPublicUi -Application $Application -SessionId $SessionId -Label 'context Apply command'
    }
    $applyInvocation = $applyTrigger.invocation
    $confirmation = Wait-ObserverConfirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'context Apply confirmation'
    $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
    $confirmationWindowMetrics = Get-ObserverNativeWindowMetrics -Window $confirmation
    $tree = Get-ObserverWindowTree -Window $confirmation -Process $Application.process -SessionId $SessionId -Label 'context Apply confirmation'
    $treeText = [string]::Join("`n", @($tree | ForEach-Object { $_.name } | Where-Object { $_ }))
    Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-confirmation-tree.json')) -Value $tree
    [void]$Captures.Add((Save-WindowScreenshot -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-confirmation.png') -Label 'context confirmation'))
    $modalOverlay = $null
    if ($tooltipProbe) {
        $entryWindows = Get-ObserverProcessWindows -Process $Application.process
        Start-Sleep -Milliseconds 3000
        $settledWindows = Get-ObserverProcessWindows -Process $Application.process
        [void]$Captures.Add((Save-WindowScreenshot -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-confirmation-settled.png') -Label 'context confirmation after tooltip settling interval'))
        $essential = @($tree | Where-Object { $_.automation_id -cin @('ContentText', 'CommandLink_1101', 'CommandLink_1102', 'CommandButton_2') })
        $entryTooltip = @($entryWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        $settledTooltip = @($settledWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        $blocking = @($settledTooltip | Where-Object {
            $window = $_.rect
            @($essential | Where-Object {
                $control = $_.bounds
                $window.left -lt ($control.x + $control.width) -and $window.right -gt $control.x -and
                $window.top -lt ($control.y + $control.height) -and $window.bottom -gt $control.y
            }).Count -gt 0
        })
        $modalOverlay = [ordered]@{
            observation = 'process-top-level-HWND-enumeration-plus-LVM_GETTOOLTIPS'
            pre_modal = $preModalTooltip
            settling_interval_ms = 3000
            listview_hwnd = $listViewHandle.ToInt64()
            listview_tooltip_hwnd = $tooltipHandle
            owner_disabled = -not [DarkReNamerVmAcceptanceNative]::IsWindowEnabled($Application.process.MainWindowHandle)
            at_entry = $entryWindows
            at_entry_bound_tooltip_visible = $entryTooltip.Count -eq 1
            after_settling = $settledWindows
            persisted_visible_tooltip = $settledTooltip.Count -eq 1
            persisted_essential_overlap = $blocking.Count -eq 1
            settled_capture = $Prefix + '-confirmation-settled.png'
        }
        Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-modal-overlay.json')) -Value $modalOverlay
        if ($modalOverlay.at_entry_bound_tooltip_visible -or $modalOverlay.persisted_visible_tooltip -or $modalOverlay.persisted_essential_overlap) {
            throw 'ListView infotip remained visible during the modal confirmation entry or settling interval.'
        }
    }
    if ($treeText.IndexOf($ExpectedScope, [StringComparison]::Ordinal) -lt 0) {
        throw 'Context confirmation lost its exact list/selection/change scope.'
    }
    $notice = $false
    $identicalSnippetPairs = [Collections.Generic.List[object]]::new()
    $destinationPrimary = $true
    $destinationExample = $true
    $destination = $true
    if (-not $Standard) {
        $notice = $treeText.IndexOf('축약문에 차이가 드러나지 않습니다', [StringComparison]::Ordinal) -ge 0
        $currentLines = @($treeText.Split("`n") | Where-Object { $_.StartsWith('현재: ', [StringComparison]::Ordinal) })
        $changedLines = @($treeText.Split("`n") | Where-Object { $_.StartsWith('변경 후: ', [StringComparison]::Ordinal) })
        for ($index = 0; $index -lt [Math]::Min($currentLines.Count, $changedLines.Count); $index++) {
            $currentSnippet = $currentLines[$index].Substring('현재: '.Length)
            $changedSnippet = $changedLines[$index].Substring('변경 후: '.Length)
            if ($currentSnippet -ceq $changedSnippet) {
                $identicalSnippetPairs.Add([ordered]@{ example = $index; snippet = $currentSnippet })
            }
        }
        if (-not $ExpectItemSpecificDestination -and [string]::IsNullOrEmpty($ExpectedDestinationParent) -and $identicalSnippetPairs.Count -eq 0) {
            throw 'Repeated-name fixture did not reproduce an identical rendered snippet pair.'
        }
        $destinationParentSnippet = if ([string]::IsNullOrEmpty($ExpectedDestinationParent)) { '' } else {
            Get-ObserverBoundedDifferenceSnippet -Text $ExpectedDestinationParent -FocusStart $ExpectedDestinationParent.Length -FocusEnd $ExpectedDestinationParent.Length
        }
        $destinationLabel = $treeText.IndexOf('대상 폴더:', [StringComparison]::Ordinal) -ge 0 -or
            $treeText.IndexOf('대상 폴더 (축약):', [StringComparison]::Ordinal) -ge 0
        $destinationPrimary = [string]::IsNullOrEmpty($ExpectedDestinationParent) -or
            ($destinationLabel -and $treeText.IndexOf($destinationParentSnippet, [StringComparison]::Ordinal) -ge 0)
        $destinationExample = [string]::IsNullOrEmpty($ExpectedDestinationParent) -or
            (-not [string]::IsNullOrEmpty($ExpectedDestinationPath) -and $treeText.IndexOf($ExpectedDestinationPath, [StringComparison]::Ordinal) -ge 0)
        $destination = if ($ExpectItemSpecificDestination) {
            $treeText.IndexOf('대상 폴더는 항목별로 확인하세요', [StringComparison]::Ordinal) -ge 0
        } elseif ([string]::IsNullOrEmpty($ExpectedDestinationParent)) { $true } else { $destinationPrimary }
        if (-not $ExpectItemSpecificDestination -and -not $notice -and [string]::IsNullOrEmpty($ExpectedDestinationParent)) {
            throw 'Repeated-name confirmation omitted the explicit indistinguishable-snippet notice.'
        }
        if (-not $destination) { throw 'Context confirmation omitted the required destination-folder context.' }
    }
    $defaultFocus = Get-ObserverConfirmationDefaultFocus -Application $Application -SessionId $SessionId

    $cancel = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandButton_2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context Cancel button' -RequireEnabled -RequireWindowHandle
    $confirm = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1101' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context confirmation Apply link' -RequireEnabled -RequireWindowHandle
    $detailsButton = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1102' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context full-details command link' -RequireEnabled
    if ($detailsButton.Current.Name -cne '예시 전체 정보 · 복사') { throw 'Context full-details command text differs.' }
    $buttonCondition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
    $expanders = @($confirmation.FindAll([Windows.Automation.TreeScope]::Descendants, $buttonCondition) | Where-Object { $_.Current.Name -cin @('진단 정보 표시', '상세 정보 표시') })
    if ($expanders.Count -ne 1) { throw 'Context detail expander was not uniquely available.' }
    $reachability = [ordered]@{
        cancel = Get-ObserverControlReachability -Element $cancel -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'context Cancel'
        apply = Get-ObserverControlReachability -Element $confirm -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'context Apply'
        full_details = Get-ObserverControlReachability -Element $detailsButton -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'context full details'
        expander = Get-ObserverControlReachability -Element $expanders[0] -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'context expander'
    }
    Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-reachability.json')) -Value ([ordered]@{
        schema_version = 1
        controls = $reachability
    })
    $inaccessible = @($reachability.Values | Where-Object { $_.status -cne 'reachable' })
    if ($inaccessible.Count -ne 0) {
        $failedLabels = @($inaccessible | ForEach-Object { [string]$_.label })
        throw ('After context confirmation has a mouse-inaccessible required control: ' +
            [string]::Join(', ', $failedLabels) + '.')
    }
    $cancel = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandButton_2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context Cancel after default scroll' -RequireEnabled -RequireWindowHandle
    $cancel.SetFocus()

    $opened = Open-ObserverConfirmationDetails -Confirmation $confirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds
    $opened | Add-Member -NotePropertyName activation -NotePropertyValue ([ordered]@{ input = 'keyboard-enter'; target = $null })
    $detailsWindow = $opened.window
    $detailsHandle = [IntPtr]$detailsWindow.Current.NativeWindowHandle
    $detailsWindowMetrics = Get-ObserverNativeWindowMetrics -Window $detailsWindow
    $details = Get-ObserverReadOnlyDetails -Window $detailsWindow -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedText $ExpectedFullText -Label 'context full details'
    $detailsRasterTarget = $null
    $contention = $null
    $selectionCopy = $null
    $copyAll = $null
    if ($Standard) {
        $detailsRasterTarget = Get-ObserverNativeStaticRasterTarget -Window $detailsWindow -Application $Application -SessionId $SessionId -ControlId 1001 -ExpectedText '전체 이름과 경로' -Id 'full-details' -Image ($Prefix + '-full-details.png')
        $contention = Invoke-ObserverClipboardContention -DetailsWindow $detailsWindow -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -OutputRoot $OutputRoot -CaptureLeaf ($Prefix + '-copy-failure.png') -Captures $Captures
        $selectionCopy = Copy-GuiRegressionDocument -Mode selection -Application $Application -Edit $details.edit -ExpectedText $details.evidence.value_text -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'confirmation full-details native selection'
        $copyAll = Copy-GuiRegressionDocument -Mode mnemonic -Application $Application -ExpectedText $details.evidence.value_text -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'confirmation full-details retry copy all'
    }
    [void]$Captures.Add((Save-WindowScreenshot -Window $detailsWindow -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-full-details.png') -Label 'context full details'))
    Assert-AutomationBinding -Element $details.edit -Process $Application.process -ExpectedSession $SessionId -Label 'context full-details edit before end scroll'
    $details.edit.SetFocus()
    Send-AcceptanceChord -Process $Application.process -ExpectedSession $SessionId -Modifier 0x11 -VirtualKey 0x23 -Label 'context full-details Ctrl+End'
    Start-Sleep -Milliseconds 150
    $visibleEnd = Get-ObserverVisibleText -TextPattern $details.text_pattern
    $expectedEnding = (Normalize-ObserverText $ExpectedFullText).Split("`n")[-1]
    if (-not $visibleEnd.EndsWith($expectedEnding, [StringComparison]::Ordinal)) {
        throw 'Context full details did not expose the canonical ending after native scrolling.'
    }
    [void]$Captures.Add((Save-WindowScreenshot -Window $detailsWindow -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-full-details-end.png') -Label 'context full details ending'))
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label 'confirmation full-details Escape close'
    $detailsCloseTarget = $null
    $detailsCloseInput = 'keyboard-escape'
    Wait-WindowClosed -Handle $detailsHandle -TimeoutSeconds $WaitSeconds -Label 'context full-details prompt'
    $confirmation = Wait-ObserverConfirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'context confirmation after details'
    $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
    $afterDetailsFocus = Get-ObserverConfirmationDefaultFocus -Application $Application -SessionId $SessionId
    if ($tooltipProbe) {
        $afterDetailsWindows = Get-ObserverProcessWindows -Process $Application.process
        $afterDetailsTooltip = @($afterDetailsWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        [void]$Captures.Add((Save-WindowScreenshot -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-confirmation-after-details-return.png') -Label 'context confirmation after full-details return'))
        $modalOverlay['after_details_return'] = [ordered]@{
            windows = $afterDetailsWindows
            bound_tooltip_visible = $afterDetailsTooltip.Count -eq 1
            essential_overlap = $false
            capture = $Prefix + '-confirmation-after-details-return.png'
        }
        if ($modalOverlay.after_details_return.bound_tooltip_visible) {
            $modalOverlay.after_details_return.essential_overlap = $true
            throw 'ListView infotip reappeared over the confirmation after full-details return.'
        }
    }
    $expanders = @($confirmation.FindAll([Windows.Automation.TreeScope]::Descendants, $buttonCondition) | Where-Object { $_.Current.Name -cin @('진단 정보 표시', '상세 정보 표시') })
    if ($expanders.Count -ne 1) { throw 'Recreated context detail expander was not uniquely available.' }
    $reachability.expander = Get-ObserverControlReachability -Element $expanders[0] -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -WorkArea $WorkArea -Label 'recreated context expander'
    if ($reachability.expander.status -cne 'reachable') {
        throw 'After context confirmation recreated an inaccessible expander.'
    }

    $expanderInput = 'physical-mouse'
    $physicalExpander = Get-GuiRegressionPhysicalTarget -Click -Element $expanders[0] -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -Label 'context detail expander'
    Start-Sleep -Milliseconds 200
    $expandedTree = Get-ObserverWindowTree -Window $confirmation -Process $Application.process -SessionId $SessionId -Label 'expanded context confirmation'
    $expandedWindowMetrics = Get-ObserverNativeWindowMetrics -Window $confirmation
    [void]$Captures.Add((Save-WindowScreenshot -Window $confirmation -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-confirmation-expanded.png') -Label 'expanded context confirmation'))
    if ($tooltipProbe) {
        $expandedWindows = Get-ObserverProcessWindows -Process $Application.process
        $expandedTooltip = @($expandedWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        $modalOverlay['after_expansion'] = [ordered]@{
            windows = $expandedWindows
            bound_tooltip_visible = $expandedTooltip.Count -eq 1
            essential_overlap = $false
            capture = $Prefix + '-confirmation-expanded.png'
        }
        if ($modalOverlay.after_expansion.bound_tooltip_visible) {
            $modalOverlay.after_expansion.essential_overlap = $true
            throw 'ListView infotip reappeared over the expanded confirmation.'
        }
    }
    $expandedBottom = Scroll-ObserverTaskDialogToEnd -Confirmation $confirmation -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds -OutputRoot $OutputRoot -CaptureLeaf ($Prefix + '-confirmation-expanded-bottom.png') -Label 'context confirmation expanded' -Captures $Captures
    $expandedInfo = @($expandedBottom.tree | Where-Object { $_.automation_id -ceq 'ExpandedInformationText' })
    if ($expandedInfo.Count -ne 1 -or $expandedInfo[0].offscreen -or
        $expandedInfo[0].name.IndexOf('계획 지문', [StringComparison]::Ordinal) -lt 0 -or
        $expandedInfo[0].name.IndexOf('목록 버전', [StringComparison]::Ordinal) -lt 0 -or
        $expandedInfo[0].name.IndexOf(':\', [StringComparison]::Ordinal) -ge 0) {
        throw 'Expanded context diagnostic was not visibly technical-only at the native scroll bottom.'
    }
    if ($PhysicalMouseActivation) {
        $cancel = Find-UniqueAutomationElement -Root $confirmation -Process $Application.process -ExpectedSession $SessionId -AutomationId 'CommandButton_2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'context Cancel after expanded scroll' -RequireEnabled -RequireWindowHandle
        $cancelTarget = Get-GuiRegressionPhysicalTarget -Click -Element $cancel -Application $Application -SessionId $SessionId -ExpectedRoot $confirmationHandle -Label 'context confirmation Cancel'
        $cancelInput = 'physical-mouse'
    }
    else {
        Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x1B -Label 'context confirmation cancellation Escape'
        $cancelTarget = $null
        $cancelInput = 'keyboard-escape'
    }
    Wait-WindowClosed -Handle $confirmationHandle -TimeoutSeconds $WaitSeconds -Label 'context confirmation cancellation'
    if ($null -ne $applyInvocation) {
        Complete-AutomationControlInvoke -State $applyInvocation -TimeoutSeconds $WaitSeconds
    }
    Wait-AcceptanceMainWindowForeground -Application $Application -WaitSeconds $WaitSeconds -Label 'context confirmation cancellation'
    if ($tooltipProbe) {
        $gridAfterCancel = Get-ObserverGrid -Application $Application -SessionId $SessionId -WaitSeconds $WaitSeconds
        $tooltipAfterCancel = [DarkReNamerVmAcceptanceNative]::ReadListViewTooltip([IntPtr]$gridAfterCancel.element.Current.NativeWindowHandle)
        if ($tooltipAfterCancel -ne $tooltipHandle) {
            throw 'ListView infotip HWND identity changed across the confirmation modal lifecycle.'
        }
        $hoverCellAfterCancel = $gridAfterCancel.pattern.GetItem(0, 0)
        if ($hoverCellAfterCancel.Current.IsOffscreen) { throw 'Post-cancel tooltip probe current-name cell is offscreen.' }
        $postRect = $hoverCellAfterCancel.Current.BoundingRectangle
        $postPoint = [DarkReNamerVmAcceptanceNative+Point]::new()
        $postPoint.X = [int][Math]::Floor($postRect.Left + [Math]::Min(8.0, $postRect.Width / 2.0))
        $postPoint.Y = [int][Math]::Floor($postRect.Top + ($postRect.Height / 2.0))
        [DarkReNamerVmAcceptanceNative]::MoveCursor($postPoint.X, $postPoint.Y)
        $postHit = [DarkReNamerVmAcceptanceNative]::WindowFromPoint($postPoint)
        if ([DarkReNamerVmAcceptanceNative]::GetAncestor($postHit, [uint32]2) -ne [IntPtr]$Application.main.Current.NativeWindowHandle) {
            throw 'Post-cancel tooltip hover point did not hit the exact application root.'
        }
        $postVisibleTooltip = @()
        for ($attempt = 0; $attempt -lt 30 -and $postVisibleTooltip.Count -ne 1; $attempt++) {
            Start-Sleep -Milliseconds 100
            $postWindows = Get-ObserverProcessWindows -Process $Application.process
            $postVisibleTooltip = @($postWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible -and $_.rect.height -ge 100 })
        }
        if ($postVisibleTooltip.Count -ne 1) {
            throw 'Ordinary current-name hover did not restore the bound multiline ListView infotip after Cancel.'
        }
        [void]$Captures.Add((Save-WindowScreenshot -Window $Application.main -Process $Application.process -ExpectedSession $SessionId -Root $OutputRoot -Leaf ($Prefix + '-after-cancel-infotip.png') -Label 'context ListView infotip restored after Cancel'))
        [DarkReNamerVmAcceptanceNative]::MoveCursor($neutralPoint.X, $neutralPoint.Y)
        Start-Sleep -Milliseconds 600
        $postNeutralWindows = Get-ObserverProcessWindows -Process $Application.process
        $postNeutralTooltip = @($postNeutralWindows | Where-Object { $_.hwnd -eq $tooltipHandle -and $_.visible })
        $modalOverlay['after_cancel'] = [ordered]@{
            input = 'physical-mouse-hover-without-click'
            point = [ordered]@{ x = $postPoint.X; y = $postPoint.Y; hit_window = $postHit.ToInt64(); root_window = $Application.main.Current.NativeWindowHandle }
            listview_tooltip_hwnd = $tooltipAfterCancel
            bound_tooltip_reexposed = $true
            window = $postVisibleTooltip[0]
            capture = $Prefix + '-after-cancel-infotip.png'
            neutral_point = [ordered]@{ x = $neutralPoint.X; y = $neutralPoint.Y }
            neutral_hidden = $postNeutralTooltip.Count -eq 0
            after_neutral = $postNeutralWindows
        }
        if (-not $modalOverlay.after_cancel.neutral_hidden) {
            throw 'Restored ListView infotip did not hide at the neutral point after Cancel.'
        }
        Write-JsonUtf8Bom -Path (Join-Path $OutputRoot ($Prefix + '-modal-overlay.json')) -Value $modalOverlay
    }
    $result = [ordered]@{
        apply_entry = [ordered]@{ input = $applyTrigger.input; menu_entry = $applyTrigger.menu_entry }
        modal_overlay = $modalOverlay
        window = $confirmationWindowMetrics
        tree = $tree
        destination_context_visible = $destination
        default_focus = $defaultFocus
        reachability = $reachability
        expanded = [ordered]@{ window = $expandedWindowMetrics; input = $expanderInput; target = $physicalExpander; tree = $expandedTree; bottom_scroll = $expandedBottom }
        cancellation = [ordered]@{ input = $cancelInput; target = $cancelTarget; returned_to_preview = $true; default_cancel_preserved = $true }
    }
    if ($Standard) {
        $result['scope_3_1_2'] = $true
        $result['full_details'] = [ordered]@{
            text_raster_target = $detailsRasterTarget
            command_link = $opened.command_link
            canonical_text = $details.evidence
            copy_contention = $contention
            selection_copy = $selectionCopy
            copy_all_retry = $copyAll
            native_end_scroll = [ordered]@{ visible_text = $visibleEnd; ending_visible = $true }
            escape_return_default_cancel = $afterDetailsFocus
        }
    }
    else {
        $result['scope_exact'] = $true
        $result['indistinguishable_snippet_notice_visible'] = $notice
        $result['identical_rendered_snippet_pairs'] = $identicalSnippetPairs.ToArray()
        $result['item_specific_destination_notice_visible'] = [bool]$ExpectItemSpecificDestination -and $destination
        $result['destination_primary_visible'] = $destinationPrimary
        $result['destination_example_visible'] = $destinationExample
        $result['full_details'] = [ordered]@{
            window = $detailsWindowMetrics
            command_link = $opened.command_link
            activation = $opened.activation
            canonical_text = $details.evidence
            native_end_scroll = [ordered]@{ visible_text = $visibleEnd; ending_visible = $true }
            close = [ordered]@{ input = $detailsCloseInput; target = $detailsCloseTarget }
            return_default_cancel = $afterDetailsFocus
        }
    }
    $result

}

function Invoke-ObserverContextScenario {
    param(
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $Appearance,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $applicationPath = Join-Path $Verified.root $Verified.manifest.application.file
    if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.manifest.application.sha256) {
        throw 'Application changed after bundle verification.'
    }
    $repeatedFixture = New-ObserverRepeatedFixture -RuntimeRoot $RuntimeRoot
    $script:ownedContextFixedRoot = $null
    $repeatedApplication = $null
    $moveFixture = $null
    $moveApplication = $null
    $mixedFixture = $null
    $mixedApplication = $null
    try {
        $repeatedApplication = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'repeated-name GUI regression application'
        $appearanceSpec = Set-AcceptanceAppearance -Process $repeatedApplication.process -ExpectedSession $SessionId -Appearance $Appearance
        $minimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $repeatedApplication.main -Process $repeatedApplication.process -ExpectedSession $SessionId
        $environment = Get-ObserverEnvironmentMetadata -Application $repeatedApplication
        $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $repeatedApplication.main
        $requested = $script:contract.requested_small_workspace
        $requestedModePrefix = '{0}x{1}@' -f $requested.width,$requested.height
        $environment['requested_small_workspace'] = [ordered]@{
            width = [int]$requested.width
            height = [int]$requested.height
            actual_screen_matches = $environment.physical_screen.width -eq $requested.width -and $environment.physical_screen.height -eq $requested.height
            display_mode_advertised = @($environment.display_mode_inventory.values | Where-Object { $_.StartsWith($requestedModePrefix, [StringComparison]::Ordinal) }).Count -gt 0
            status = if ($environment.physical_screen.width -eq $requested.width -and $environment.physical_screen.height -eq $requested.height) { 'observed-exact' } else { 'not-available-in-current-managed-session' }
            mutation_attempted = $false
        }
        if ($minimum.dpi -ne $script:contract.expected_dpi -or $environment.hwnd_dpi -ne $script:contract.expected_dpi -or
            $environment.text_scale_factor_percent -ne $script:contract.expected_text_scale_percent -or
            -not $environment.requested_small_workspace.actual_screen_matches) {
            $environment['failure_classification'] = 'environment_blocked'
            $environment['failure_reason'] = if (-not $environment.requested_small_workspace.actual_screen_matches) {
                'requested_and_actual_target_monitor_geometry_differ'
            } elseif ($environment.text_scale_factor_percent -ne $script:contract.expected_text_scale_percent) {
                'actual_and_requested_text_scale_differ'
            } elseif ($minimum.dpi -ne $script:contract.expected_dpi) {
                'minimum_window_and_requested_dpi_differ'
            } else { 'main_hwnd_and_requested_dpi_differ' }
            $environment['requested_dpi'] = [int]$script:contract.expected_dpi
            $environment['requested_text_scale_factor_percent'] = [int]$script:contract.expected_text_scale_percent
            $environment['minimum_window_dpi'] = [int]$minimum.dpi
            Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot 'environment-preflight.json') -Value $environment
            throw ("environment_blocked: requested {0}x{1}@{2}, observed target monitor {3}x{4}, minimum DPI {5}, main HWND DPI {6}; confirmation matrix was not started." -f `
                $requested.width, $requested.height, $script:contract.expected_dpi, $environment.physical_screen.width, $environment.physical_screen.height, $minimum.dpi, $environment.hwnd_dpi)
        }
        Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot 'environment-preflight.json') -Value $environment
        $prefix = 'after-context-repeated-{0}-{1}' -f $Appearance,$minimum.dpi
        $import = Import-GuiRegressionPathList -Application $repeatedApplication -PathsFile $repeatedFixture.paths_file -ExpectedRows 3 -SessionId $SessionId -WaitSeconds $WaitSeconds
        $grid = $import.grid
        for ($index = 0; $index -lt 3; $index++) {
            Set-ObserverManualName -Application $repeatedApplication -Grid $grid -Row $index -Name $repeatedFixture.destination_names[$index] -SessionId $SessionId -WaitSeconds $WaitSeconds
        }
        $selection = Set-ObserverSelectedRow -Application $repeatedApplication -Grid $grid -Row 0 -SessionId $SessionId
        [void]$Captures.Add((Save-WindowScreenshot -Window $repeatedApplication.main -Process $repeatedApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($prefix + '-preview.png') -Label 'repeated-name preview'))
        $fullText = "변경 예시 전체 경로 (2/3개)`n`n현재 이름: $($repeatedFixture.source_names[0])`n변경 후 이름: $($repeatedFixture.destination_names[0])`n현재 전체 경로: $($repeatedFixture.paths[0])`n변경 후 전체 경로: $($repeatedFixture.destination_paths[0])`n`n현재 이름: $($repeatedFixture.source_names[1])`n변경 후 이름: $($repeatedFixture.destination_names[1])`n현재 전체 경로: $($repeatedFixture.paths[1])`n변경 후 전체 경로: $($repeatedFixture.destination_paths[1])"
        $repeatedConfirmation = Invoke-ObserverContextConfirmation -Application $repeatedApplication -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 3개' -ExpectedFullText $fullText -ExpectedDestinationParent '' -OutputRoot $EvidenceRoot -Prefix $prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures -PhysicalMouseActivation:($script:contract.mode -ceq 'context-surface')
        $afterCancel = Get-ObserverFixtureState -FixtureRoot $repeatedFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $repeatedFixture.initial -Actual $afterCancel)) {
            throw 'Repeated-name confirmation cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        if ($script:contract.mode -ceq 'context-surface') {
            $repeatedExit = Close-AcceptanceApplication -Application $repeatedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -Input ordinary
            $repeatedApplication.owned.process.Dispose()
            $repeatedApplication = $null
            return [ordered]@{
                mode = 'context-surface'
                full_context_coverage = [ordered]@{
                    status = 'covered-by-separate-full-context-cell'
                    reference = [string]$script:contract.full_context_reference
                    omitted = @('second-repeated-fixture', 'movement-actual-apply', 'mixed-destination-third-unsampled-reentry', 'default-enter-cancel', 'alt-tab-roundtrip')
                }
                environment = $environment
                appearance = $appearanceSpec.evidence_name
                minimum_window = $minimum
                surface = [ordered]@{
                    fixture = 'long-repeated-3'
                    selection = $selection
                    confirmation = $repeatedConfirmation
                    cancellation_disk_unchanged = $true
                    fixture_identity_unchanged = $true
                    journal_residue_count = 0
                    normal_exit_code = $repeatedExit
                }
            }
        }
        Set-ObserverManualName -Application $repeatedApplication -Grid $grid -Row 0 -Name $repeatedFixture.source_names[0] -SessionId $SessionId -WaitSeconds $WaitSeconds
        Set-ObserverManualName -Application $repeatedApplication -Grid $grid -Row 1 -Name $repeatedFixture.source_names[1] -SessionId $SessionId -WaitSeconds $WaitSeconds
        $remainingSelection = Set-ObserverSelectedRow -Application $repeatedApplication -Grid $grid -Row 2 -SessionId $SessionId
        $remainingPrefix = 'after-context-repeated-korean-insert-{0}-{1}' -f $Appearance,$minimum.dpi
        [void]$Captures.Add((Save-WindowScreenshot -Window $repeatedApplication.main -Process $repeatedApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($remainingPrefix + '-preview.png') -Label 'Korean repeated insertion preview'))
        $remainingFullText = "변경 예시 전체 경로 (1/1개)`n`n현재 이름: $($repeatedFixture.source_names[2])`n변경 후 이름: $($repeatedFixture.destination_names[2])`n현재 전체 경로: $($repeatedFixture.paths[2])`n변경 후 전체 경로: $($repeatedFixture.destination_paths[2])"
        $remainingConfirmation = Invoke-ObserverContextConfirmation -Application $repeatedApplication -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 1개' -ExpectedFullText $remainingFullText -ExpectedDestinationParent '' -OutputRoot $EvidenceRoot -Prefix $remainingPrefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $afterRemainingCancel = Get-ObserverFixtureState -FixtureRoot $repeatedFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $repeatedFixture.initial -Actual $afterRemainingCancel)) {
            throw 'Korean repeated-insertion confirmation cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $repeatedExit = Close-AcceptanceApplication -Application $repeatedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -Input ordinary
        $repeatedApplication.owned.process.Dispose()
        $repeatedApplication = $null

        $moveFixture = New-ObserverMoveFixture -RuntimeRoot $RuntimeRoot
        $moveApplication = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'movement GUI regression application'
        $moveAppearance = Set-AcceptanceAppearance -Process $moveApplication.process -ExpectedSession $SessionId -Appearance $Appearance
        $moveMinimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $moveApplication.main -Process $moveApplication.process -ExpectedSession $SessionId
        if ($moveMinimum.dpi -ne $script:contract.expected_dpi) { throw 'Move context HWND DPI differs from the staged contract.' }
        $movePrefix = 'after-context-move-{0}-{1}' -f $Appearance,$moveMinimum.dpi
        $moveImport = Import-GuiRegressionPathList -Application $moveApplication -PathsFile $moveFixture.paths_file -ExpectedRows 1 -SessionId $SessionId -WaitSeconds $WaitSeconds
        $moveGrid = $moveImport.grid
        $destinationInput = Set-ObserverDestinationParent -Application $moveApplication -Grid $moveGrid -DestinationParent $moveFixture.parent_b -SessionId $SessionId -WaitSeconds $WaitSeconds
        $moveOnlySelection = Set-ObserverSelectedRow -Application $moveApplication -Grid $moveGrid -Row 0 -SessionId $SessionId
        $moveOnlyPrefix = 'after-context-move-only-{0}-{1}' -f $Appearance,$moveMinimum.dpi
        [void]$Captures.Add((Save-WindowScreenshot -Window $moveApplication.main -Process $moveApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($moveOnlyPrefix + '-preview.png') -Label 'move-only preview'))
        $moveOnlyDestination = Join-Path $moveFixture.parent_b 'old.txt'
        $moveOnlySnippets = Get-ObserverDifferenceSnippetPair -Current $moveFixture.source -After $moveOnlyDestination
        $moveOnlyFullText = "변경 예시 전체 경로 (1/1개)`n`n현재 이름: old.txt`n변경 후 이름: old.txt`n현재 전체 경로: $($moveFixture.source)`n변경 후 전체 경로: $moveOnlyDestination"
        $moveOnlyConfirmation = Invoke-ObserverContextConfirmation -Application $moveApplication -ExpectedScope '목록 전체 1개 · 선택 1개 · 실제 변경 1개' -ExpectedFullText $moveOnlyFullText -ExpectedDestinationParent $moveFixture.parent_b -ExpectedDestinationPath $moveOnlySnippets.after -OutputRoot $EvidenceRoot -Prefix $moveOnlyPrefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $moveOnlyAfterCancel = Get-ObserverFixtureState -FixtureRoot $moveFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $moveFixture.initial -Actual $moveOnlyAfterCancel)) {
            throw 'Move-only confirmation cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA

        Set-ObserverManualName -Application $moveApplication -Grid $moveGrid -Row 0 -Name 'new.txt' -SessionId $SessionId -WaitSeconds $WaitSeconds
        $moveSelection = Set-ObserverSelectedRow -Application $moveApplication -Grid $moveGrid -Row 0 -SessionId $SessionId
        [void]$Captures.Add((Save-WindowScreenshot -Window $moveApplication.main -Process $moveApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($movePrefix + '-preview.png') -Label 'move-plus-rename preview'))
        $moveSnippets = Get-ObserverDifferenceSnippetPair -Current $moveFixture.source -After $moveFixture.destination
        $moveFullText = "변경 예시 전체 경로 (1/1개)`n`n현재 이름: old.txt`n변경 후 이름: new.txt`n현재 전체 경로: $($moveFixture.source)`n변경 후 전체 경로: $($moveFixture.destination)"
        $moveConfirmation = Invoke-ObserverContextConfirmation -Application $moveApplication -ExpectedScope '목록 전체 1개 · 선택 1개 · 실제 변경 1개' -ExpectedFullText $moveFullText -ExpectedDestinationParent $moveFixture.parent_b -ExpectedDestinationPath $moveSnippets.after -OutputRoot $EvidenceRoot -Prefix $movePrefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $moveAfterCancel = Get-ObserverFixtureState -FixtureRoot $moveFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $moveFixture.initial -Actual $moveAfterCancel)) {
            throw 'Move-plus-rename cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA

        $actualApplyTrigger = Start-ObserverApplyFromPublicUi -Application $moveApplication -SessionId $SessionId -Label 'actual move Apply command'
        $applyInvocation = $actualApplyTrigger.invocation
        $actualConfirmation = Wait-ObserverConfirmation -Application $moveApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'actual move confirmation'
        $actualTree = Get-ObserverWindowTree -Window $actualConfirmation -Process $moveApplication.process -SessionId $SessionId -Label 'actual move confirmation'
        $actualText = [string]::Join("`n", @($actualTree | ForEach-Object { $_.name } | Where-Object { $_ }))
        Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot ($movePrefix + '-actual-apply-confirmation-tree.json')) -Value $actualTree
        [void]$Captures.Add((Save-WindowScreenshot -Window $actualConfirmation -Process $moveApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($movePrefix + '-actual-apply-confirmation.png') -Label 'actual move confirmation'))
        if ($actualText.IndexOf('목록 전체 1개 · 선택 1개 · 실제 변경 1개', [StringComparison]::Ordinal) -lt 0) {
            throw 'Actual move confirmation lost its exact 1/1/1 scope.'
        }
        $actualParentSnippet = Get-ObserverBoundedDifferenceSnippet -Text $moveFixture.parent_b -FocusStart $moveFixture.parent_b.Length -FocusEnd $moveFixture.parent_b.Length
        $actualDestinationVisible = ($actualText.IndexOf('대상 폴더:', [StringComparison]::Ordinal) -ge 0 -or
            $actualText.IndexOf('대상 폴더 (축약):', [StringComparison]::Ordinal) -ge 0) -and
            $actualText.IndexOf($actualParentSnippet, [StringComparison]::Ordinal) -ge 0
        if (-not $actualDestinationVisible) { throw 'Actual move confirmation omitted destination context.' }
        $actualHandle = [IntPtr]$actualConfirmation.Current.NativeWindowHandle
        $confirm = Find-UniqueAutomationElement -Root $actualConfirmation -Process $moveApplication.process -ExpectedSession $SessionId -AutomationId 'CommandLink_1101' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'actual move confirmation Apply link' -RequireEnabled -RequireWindowHandle
        $actualReachability = Get-ObserverControlReachability -Element $confirm -Application $moveApplication -SessionId $SessionId -ExpectedRoot $actualHandle -WorkArea $environment.work_area -Label 'actual move Apply'
        if ($actualReachability.status -cne 'reachable') { throw 'Actual move Apply is mouse-inaccessible.' }
        if ($actualReachability.status -ceq 'reachable') {
            $actualApplyInput = 'physical-mouse'
            $physicalApply = Get-GuiRegressionPhysicalTarget -Click -Element $confirm -Application $moveApplication -SessionId $SessionId -ExpectedRoot $actualHandle -Label 'actual move Apply'
        }
        else {
            $actualApplyInput = 'keyboard-enter-fallback-after-inaccessible-mouse-observation'
            $confirm.SetFocus()
            Send-AcceptanceTap -Process $moveApplication.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'actual move Apply keyboard fallback'
            $physicalApply = $null
        }
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        do {
            $complete = -not (Test-Path -LiteralPath $moveFixture.source) -and (Test-Path -LiteralPath $moveFixture.destination -PathType Leaf)
            if ($complete) { try { Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA; break } catch {} }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        if ($null -ne $applyInvocation) {
            Complete-AutomationControlInvoke -State $applyInvocation -TimeoutSeconds $WaitSeconds
        }
        if (-not $complete) { throw 'Actual move-plus-rename did not reach the exact destination.' }
        Wait-AcceptanceMainWindowForeground -Application $moveApplication -WaitSeconds $WaitSeconds -Label 'actual move-plus-rename Apply'
        $initialMatches = @($moveFixture.initial | Where-Object { $_.path -ceq $moveFixture.source })
        if ($initialMatches.Count -ne 1) { throw 'Move source identity witness was not unique.' }
        $initial = $initialMatches[0]
        $actual = Get-Item -LiteralPath $moveFixture.destination -Force
        $contentPreserved = (Get-LowerSha256 -Path $actual.FullName) -ceq $initial.content_sha256
        $identityPreserved = [DarkReNamerVmNative]::GetFileIdentity($actual.FullName) -ceq $initial.identity
        if (-not $contentPreserved -or -not $identityPreserved) { throw 'Actual move-plus-rename changed content or NTFS identity.' }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        [void]$Captures.Add((Save-WindowScreenshot -Window $moveApplication.main -Process $moveApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($movePrefix + '-actual-apply-complete.png') -Label 'actual move completion'))
        $moveExit = Close-AcceptanceApplication -Application $moveApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -Input ordinary
        $moveApplication.owned.process.Dispose()
        $moveApplication = $null

        $mixedFixture = New-ObserverMixedFixture -RuntimeRoot $RuntimeRoot
        $mixedApplication = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'mixed GUI regression application'
        $mixedAppearance = Set-AcceptanceAppearance -Process $mixedApplication.process -ExpectedSession $SessionId -Appearance $Appearance
        $mixedMinimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $mixedApplication.main -Process $mixedApplication.process -ExpectedSession $SessionId
        if ($mixedMinimum.dpi -ne $script:contract.expected_dpi) { throw 'Mixed context HWND DPI differs from the staged contract.' }
        $mixedPrefix = 'after-context-mixed-{0}-{1}' -f $Appearance,$mixedMinimum.dpi
        $mixedImport = Import-GuiRegressionPathList -Application $mixedApplication -PathsFile $mixedFixture.first_paths_file -ExpectedRows 1 -SessionId $SessionId -WaitSeconds $WaitSeconds
        $mixedGrid = $mixedImport.grid
        if ($mixedGrid.pattern.GetItem(0, 0).Current.Name -cne '03-unsampled-move.txt') {
            throw 'Unsampled-move source was not the first admitted row.'
        }
        $mixedDestinationInput = Set-ObserverDestinationParent -Application $mixedApplication -Grid $mixedGrid -DestinationParent $mixedFixture.parent_d -SessionId $SessionId -WaitSeconds $WaitSeconds
        [void](Import-GuiRegressionPathList -Application $mixedApplication -PathsFile $mixedFixture.later_paths_file -ExpectedRows 3 -SessionId $SessionId -WaitSeconds $WaitSeconds -Grid $mixedGrid)
        $admissionOrder = @('03-unsampled-move.txt', '01-rename.txt', '02-rename.txt')
        for ($index = 0; $index -lt 3; $index++) {
            if ($mixedGrid.pattern.GetItem($index, 0).Current.Name -cne $admissionOrder[$index]) {
                throw 'Later admission altered an existing proposal or unexpected row order.'
            }
        }
        [void](Set-ObserverSelectedRow -Application $mixedApplication -Grid $mixedGrid -Row 0 -SessionId $SessionId)
        $reorderInputs = [Collections.Generic.List[object]]::new()
        foreach ($expectedOrder in @(
            ,@('01-rename.txt', '03-unsampled-move.txt', '02-rename.txt')
            ,@('01-rename.txt', '02-rename.txt', '03-unsampled-move.txt'))) {
            Send-AcceptanceChord -Process $mixedApplication.process -ExpectedSession $SessionId -Modifier 0x12 -VirtualKey 0x28 -Label 'public row Move Down Alt+Down'
            $deadline = (Get-Date).AddSeconds($WaitSeconds)
            do {
                $actualOrder = @(for ($index = 0; $index -lt 3; $index++) { $mixedGrid.pattern.GetItem($index, 0).Current.Name })
                if (@(Compare-Object -CaseSensitive $expectedOrder $actualOrder -SyncWindow 0).Count -eq 0) { break }
                Start-Sleep -Milliseconds 100
            } while ((Get-Date) -lt $deadline)
            if (@(Compare-Object -CaseSensitive $expectedOrder $actualOrder -SyncWindow 0).Count -ne 0) {
                throw 'Public Alt+Down did not establish the expected row order.'
            }
            $reorderInputs.Add([ordered]@{ input = 'physical-keyboard-alt-down'; observed_order = $actualOrder })
        }
        $prefixInput = Invoke-ObserverPrefix -Application $mixedApplication -Grid $mixedGrid -Prefix $mixedFixture.prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedFirstSourceName '01-rename.txt'
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        do {
            $mixedParentsSettled = $true
            $expectedParents = @($mixedFixture.parent_a, $mixedFixture.parent_a, $mixedFixture.parent_d)
            for ($index = 0; $index -lt 3; $index++) {
                if ($mixedGrid.pattern.GetItem($index, 2).Current.Name -cne $expectedParents[$index]) {
                    $mixedParentsSettled = $false
                    break
                }
            }
            if ($mixedParentsSettled) { break }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        if (-not $mixedParentsSettled) { throw 'Mixed preview did not preserve item-specific destination parents.' }
        $expectedStatuses = @('이름 변경 예정', '이름 변경 예정', '이동·이름 변경 예정')
        $mixedStatuses = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt 3; $index++) {
            $status = $mixedGrid.pattern.GetItem($index, 7).Current.Name
            if ($status -cne $expectedStatuses[$index]) {
                throw 'Mixed preview did not preserve two rename-only rows and one third move-plus-rename row.'
            }
            $mixedStatuses.Add([ordered]@{ row = $index; source = $mixedFixture.sources[$index]; destination = $mixedFixture.destinations[$index]; status = $status })
        }
        $mixedSelection = Set-ObserverSelectedRow -Application $mixedApplication -Grid $mixedGrid -Row 0 -SessionId $SessionId
        [void]$Captures.Add((Save-WindowScreenshot -Window $mixedApplication.main -Process $mixedApplication.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($mixedPrefix + '-preview.png') -Label 'mixed preview'))
        $mixedFullText = "변경 예시 전체 경로 (2/3개)`n`n현재 이름: 01-rename.txt`n변경 후 이름: $($mixedFixture.prefix)01-rename.txt`n현재 전체 경로: $($mixedFixture.sources[0])`n변경 후 전체 경로: $($mixedFixture.destinations[0])`n`n현재 이름: 02-rename.txt`n변경 후 이름: $($mixedFixture.prefix)02-rename.txt`n현재 전체 경로: $($mixedFixture.sources[1])`n변경 후 전체 경로: $($mixedFixture.destinations[1])"
        $mixedConfirmation = Invoke-ObserverContextConfirmation -Application $mixedApplication -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 3개' -ExpectedFullText $mixedFullText -ExpectedDestinationParent '' -ExpectItemSpecificDestination -OutputRoot $EvidenceRoot -Prefix $mixedPrefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $mixedTreeText = [string]::Join("`n", @($mixedConfirmation | ForEach-Object { $_.name } | Where-Object { $_ })).tree
        if ($mixedTreeText.IndexOf('03-unsampled-move.txt', [StringComparison]::Ordinal) -ge 0) {
            throw 'The two-of-three confirmation examples unexpectedly sampled the third moved row.'
        }
        $mixedAfterCancel = Get-ObserverFixtureState -FixtureRoot $mixedFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $mixedFixture.initial -Actual $mixedAfterCancel)) {
            throw 'Mixed confirmation cancellation changed disk state or identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $thirdSelection = Set-ObserverSelectedRow -Application $mixedApplication -Grid $mixedGrid -Row 2 -SessionId $SessionId
        $thirdDiagnosticText = "이동·이름 변경 예정`n`n현재 이름: 03-unsampled-move.txt`n변경 후 이름: $($mixedFixture.prefix)03-unsampled-move.txt`n현재 전체 경로: $($mixedFixture.sources[2])`n대상 전체 경로: $($mixedFixture.destinations[2])`n`n파일 시스템 검사와 실행 확인은 변경 적용 시 별도로 수행합니다."
        $thirdDiagnosticWindow = Open-ObserverDiagnosticKeyboard -Application $mixedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds
        $thirdDiagnostic = Inspect-ObserverDiagnostic -Window $thirdDiagnosticWindow -Application $mixedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -ExpectedText $thirdDiagnosticText -OutputRoot $EvidenceRoot -Prefix ($mixedPrefix + '-third-destination') -CloseMethod escape -Captures $Captures
        $reentryConfirmation = Invoke-ObserverContextConfirmation -Application $mixedApplication -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 3개' -ExpectedFullText $mixedFullText -ExpectedDestinationParent '' -ExpectItemSpecificDestination -OutputRoot $EvidenceRoot -Prefix ($mixedPrefix + '-reentry') -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $firstExpanded = @($mixedConfirmation.expanded.tree | Where-Object { $_.automation_id -ceq 'ExpandedInformationText' })
        $secondExpanded = @($reentryConfirmation.expanded.tree | Where-Object { $_.automation_id -ceq 'ExpandedInformationText' })
        $expandedIdentityStable = $firstExpanded.Count -eq 1 -and $secondExpanded.Count -eq 1 -and $firstExpanded[0].name -ceq $secondExpanded[0].name
        if (-not $expandedIdentityStable) { throw 'Expanded plan fingerprint/list revision changed across cancellation, selected diagnostic, and reentry.' }
        $enterTrigger = Start-ObserverApplyFromPublicUi -Application $mixedApplication -SessionId $SessionId -Label 'mixed default Enter cancellation Apply command'
        $enterConfirmation = Wait-ObserverConfirmation -Application $mixedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'mixed default Enter cancellation confirmation'
        $enterHandle = [IntPtr]$enterConfirmation.Current.NativeWindowHandle
        $enterFocus = Get-ObserverConfirmationDefaultFocus -Application $mixedApplication -SessionId $SessionId
        if ([DarkReNamerVmAcceptanceNative]::IsWindowEnabled($mixedApplication.process.MainWindowHandle)) { throw 'Default Enter confirmation owner remained enabled.' }
        Send-AcceptanceTap -Process $mixedApplication.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'mixed default Cancel Enter'
        Wait-WindowClosed -Handle $enterHandle -TimeoutSeconds $WaitSeconds -Label 'mixed default Enter cancellation confirmation'
        if ($null -ne $enterTrigger.invocation) { Complete-AutomationControlInvoke -State $enterTrigger.invocation -TimeoutSeconds $WaitSeconds }
        Wait-AcceptanceMainWindowForeground -Application $mixedApplication -WaitSeconds $WaitSeconds -Label 'mixed default Enter cancellation'
        $mixedAfterEnterCancel = Get-ObserverFixtureState -FixtureRoot $mixedFixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $mixedFixture.initial -Actual $mixedAfterEnterCancel)) { throw 'Default Enter cancellation changed mixed fixture disk state.' }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $mixedExit = Close-AcceptanceApplication -Application $mixedApplication -SessionId $SessionId -WaitSeconds $WaitSeconds -Input ordinary
        $mixedApplication.owned.process.Dispose()
        $mixedApplication = $null

        [ordered]@{
            environment = $environment
            appearance = $appearanceSpec.evidence_name
            minimum_window = $minimum
            repeated = [ordered]@{
                inputs_in_admission_order = @('0 x101 -> 0 x100', 'a x100 -> a x101', '가 x100 -> 가 x101')
                selection = $selection
                zero_deletion_and_a_insertion_confirmation = $repeatedConfirmation
                korean_insertion_selection = $remainingSelection
                korean_insertion_confirmation = $remainingConfirmation
                cancellation_disk_unchanged = $true
                journal_residue_count = 0
                normal_exit_code = $repeatedExit
            }
            movement = [ordered]@{
                requested = 'C:\fixture\A\old.txt -> C:\fixture\B\new.txt'
                actual_source = $moveFixture.source
                actual_destination = $moveFixture.destination
                fixed_path_occupied = $moveFixture.fixed_path_occupied
                isolated_private_equivalent = $moveFixture.isolated_equivalent
                destination_input = $destinationInput
                move_only_selection = $moveOnlySelection
                move_only_confirmation = $moveOnlyConfirmation
                move_only_cancellation_disk_unchanged = $true
                selection = $moveSelection
                cancellation_confirmation = $moveConfirmation
                cancellation_disk_unchanged = $true
                actual_apply = [ordered]@{
                    entry = [ordered]@{ input = $actualApplyTrigger.input; menu_entry = $actualApplyTrigger.menu_entry }
                    tree = $actualTree
                    destination_context_visible = $actualDestinationVisible
                    reachability = $actualReachability
                    input = $actualApplyInput
                    target = $physicalApply
                    destination_reached = $true
                    content_preserved = $contentPreserved
                    identity_preserved = $identityPreserved
                    journal_residue_count = 0
                }
                appearance = $moveAppearance.evidence_name
                minimum_window = $moveMinimum
                normal_exit_code = $moveExit
            }
            mixed = [ordered]@{
                statuses = $mixedStatuses.ToArray()
                common_destination_parent = $null
                destination_parents = @($mixedFixture.parent_a, $mixedFixture.parent_a, $mixedFixture.parent_d)
                destination_input = $mixedDestinationInput
                later_admission_preserved_existing_destination = $true
                reorder_inputs = $reorderInputs.ToArray()
                prefix_input = $prefixInput
                selection = $mixedSelection
                confirmation = $mixedConfirmation
                two_of_three_examples_exclude_third_move = $true
                third_selection = $thirdSelection
                third_destination_diagnostic = $thirdDiagnostic
                reentry_confirmation = $reentryConfirmation
                expanded_plan_identity_stable = $expandedIdentityStable
                default_enter_cancellation = [ordered]@{
                    apply_entry = [ordered]@{ input = $enterTrigger.input; menu_entry = $enterTrigger.menu_entry }
                    default_focus = $enterFocus
                    owner_disabled = $true
                    input = 'keyboard-enter-on-default-cancel'
                    disk_unchanged = $true
                    journal_residue_count = 0
                }
                cancellation_disk_unchanged = $true
                journal_residue_count = 0
                appearance = $mixedAppearance.evidence_name
                minimum_window = $mixedMinimum
                normal_exit_code = $mixedExit
            }
        }
    }
    finally {
        foreach ($application in @($repeatedApplication, $moveApplication, $mixedApplication)) {
            if ($null -ne $application) {
                $application.process.Refresh()
                if (-not $application.process.HasExited) {
                    Invoke-TaskkillTree -ProcessId $application.process.Id
                    [void]$application.process.WaitForExit(10000)
                }
                $application.owned.process.Dispose()
            }
        }
        if ($null -ne $script:ownedContextFixedRoot -and (Test-Path -LiteralPath $script:ownedContextFixedRoot -PathType Container)) {
            $ownedRoot = Get-Item -LiteralPath $script:ownedContextFixedRoot -Force
            if ($ownedRoot.FullName -cne 'C:\fixture' -or ($ownedRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Owned fixed fixture root failed its cleanup identity check.'
            }
            Remove-Item -LiteralPath $ownedRoot.FullName -Recurse -Force
            if (Test-Path -LiteralPath $ownedRoot.FullName) { throw 'Owned fixed fixture root cleanup failed.' }
            $script:ownedContextFixedRoot = $null
        }
    }
}

function Invoke-ObserverStandardScenario {
    param(
        [Parameter(Mandatory)][object] $Verified,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $Appearance,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Captures
    )
    $fixture = New-ObserverStandardFixture -RuntimeRoot $RuntimeRoot
    $application = $null
    try {
        $applicationPath = Join-Path $Verified.root $Verified.manifest.application.file
        if ((Get-LowerSha256 -Path $applicationPath) -cne $Verified.manifest.application.sha256) {
            throw 'Application changed after bundle verification.'
        }
        $application = Start-AcceptanceApplication -FilePath $applicationPath -WorkingDirectory $Verified.root -SessionId $SessionId -WaitSeconds $WaitSeconds -Label 'standard GUI regression application'
        $appearanceSpec = Set-AcceptanceAppearance -Process $application.process -ExpectedSession $SessionId -Appearance $Appearance
        $minimum = Ensure-AcceptanceMainWindowCaptureSize -MainWindow $application.main -Process $application.process -ExpectedSession $SessionId
        $environment = Get-ObserverEnvironmentMetadata -Application $application
        $environment['main_window'] = Get-ObserverNativeWindowMetrics -Window $application.main
        $requested = $script:contract.requested_small_workspace
        $requestedModePrefix = '{0}x{1}@' -f $requested.width,$requested.height
        $environment['requested_small_workspace'] = [ordered]@{
            width = [int]$requested.width
            height = [int]$requested.height
            actual_screen_matches = $environment.physical_screen.width -eq $requested.width -and $environment.physical_screen.height -eq $requested.height
            display_mode_advertised = @($environment.display_mode_inventory.values | Where-Object { $_.StartsWith($requestedModePrefix, [StringComparison]::Ordinal) }).Count -gt 0
            status = if ($environment.physical_screen.width -eq $requested.width -and $environment.physical_screen.height -eq $requested.height) { 'observed-exact' } else { 'not-available-in-current-managed-session' }
            mutation_attempted = $false
        }
        if ($minimum.dpi -ne $script:contract.expected_dpi -or $environment.hwnd_dpi -ne $script:contract.expected_dpi -or
            $environment.text_scale_factor_percent -ne $script:contract.expected_text_scale_percent -or
            -not $environment.requested_small_workspace.actual_screen_matches) {
            $environment['failure_classification'] = 'environment_blocked'
            $environment['failure_reason'] = if (-not $environment.requested_small_workspace.actual_screen_matches) {
                'requested_and_actual_target_monitor_geometry_differ'
            } elseif ($environment.text_scale_factor_percent -ne $script:contract.expected_text_scale_percent) {
                'actual_and_requested_text_scale_differ'
            } elseif ($minimum.dpi -ne $script:contract.expected_dpi) {
                'minimum_window_and_requested_dpi_differ'
            } else { 'main_hwnd_and_requested_dpi_differ' }
            $environment['requested_dpi'] = [int]$script:contract.expected_dpi
            $environment['requested_text_scale_factor_percent'] = [int]$script:contract.expected_text_scale_percent
            $environment['minimum_window_dpi'] = [int]$minimum.dpi
            Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot 'environment-preflight.json') -Value $environment
            throw ("environment_blocked: requested {0}x{1}@{2}, observed target monitor {3}x{4}, minimum DPI {5}, main HWND DPI {6}; standard matrix was not started." -f `
                $requested.width, $requested.height, $script:contract.expected_dpi, $environment.physical_screen.width, $environment.physical_screen.height, $minimum.dpi, $environment.hwnd_dpi)
        }
        Write-JsonUtf8Bom -Path (Join-Path $EvidenceRoot 'environment-preflight.json') -Value $environment
        $prefix = 'after-standard-{0}-{1}' -f $Appearance,$minimum.dpi
        $import = Import-GuiRegressionPathList -Application $application -PathsFile $fixture.paths_file -ExpectedRows 3 -SessionId $SessionId -WaitSeconds $WaitSeconds
        $grid = $import.grid
        $importMs = $import.elapsed_ms
        $prefixRasterTarget = Set-ObserverManualName -Application $application -Grid $grid -Row 0 -Name $fixture.destination_names[0] -SessionId $SessionId -WaitSeconds $WaitSeconds -CaptureRoot $EvidenceRoot -CaptureLeaf ($prefix + '-editable-input-prompt.png') -Captures $Captures
        Set-ObserverManualName -Application $application -Grid $grid -Row 1 -Name $fixture.destination_names[1] -SessionId $SessionId -WaitSeconds $WaitSeconds
        $selection = Set-ObserverSelectedRow -Application $application -Grid $grid -Row 0 -SessionId $SessionId
        if ($grid.pattern.GetItem(0, 1).Current.Name -cne $fixture.destination_names[0] -or
            $grid.pattern.GetItem(1, 1).Current.Name -cne $fixture.destination_names[1] -or
            $grid.pattern.GetItem(2, 1).Current.Name -cne $fixture.source_names[2]) {
            throw 'The exact 3/1/2 preview did not settle.'
        }
        [void]$Captures.Add((Save-WindowScreenshot -Window $application.main -Process $application.process -ExpectedSession $SessionId -Root $EvidenceRoot -Leaf ($prefix + '-minimum-preview.png') -Label 'minimum-size long-name preview'))
        $fullText = "변경 예시 전체 경로 (2/2개)`n`n현재 이름: $($fixture.source_names[0])`n변경 후 이름: $($fixture.destination_names[0])`n현재 전체 경로: $($fixture.paths[0])`n변경 후 전체 경로: $($fixture.destinations[0])`n`n현재 이름: $($fixture.source_names[1])`n변경 후 이름: $($fixture.destination_names[1])`n현재 전체 경로: $($fixture.paths[1])`n변경 후 전체 경로: $($fixture.destinations[1])"
        $confirmation = Invoke-ObserverContextConfirmation -Standard -Application $application -ExpectedScope '목록 전체 3개 · 선택 1개 · 실제 변경 2개' -ExpectedFullText $fullText -ExpectedDestinationParent '' -OutputRoot $EvidenceRoot -Prefix $prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -WorkArea $environment.work_area -Captures $Captures
        $afterCancel = Get-ObserverFixtureState -FixtureRoot $fixture.root
        if (-not (Test-ObserverFixtureStateEqual -Expected $fixture.initial -Actual $afterCancel)) {
            throw 'Apply cancellation changed a name, content digest, or NTFS identity.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $blocked = if ($script:contract.expected_text_scale_percent -eq 150) {
            [ordered]@{ status = 'not-run'; reason = 'covered-by-paired-text100-standard-run' }
        }
        else {
            Invoke-ObserverBlockedChecks -Application $application -Grid $grid -Fixture $fixture -OutputRoot $EvidenceRoot -Prefix $prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -Captures $Captures
        }
        $actualApply = Invoke-ObserverActualApply -Application $application -Grid $grid -Fixture $fixture -OutputRoot $EvidenceRoot -Prefix $prefix -SessionId $SessionId -WaitSeconds $WaitSeconds -Captures $Captures
        $exitCode = Close-AcceptanceApplication -Application $application -SessionId $SessionId -WaitSeconds $WaitSeconds -Input ordinary
        [ordered]@{
            environment = $environment
            fixture = [ordered]@{
                count = 3; selected = 1; changed = 2
                sources = $fixture.paths; destinations = $fixture.destinations
                same_leaf_different_parent = $fixture.paths[0].EndsWith($fixture.source_names[2], [StringComparison]::Ordinal) -and $fixture.paths[2].EndsWith($fixture.source_names[2], [StringComparison]::Ordinal)
                long_korean_supplementary = $fixture.source_names[0].IndexOf('😀', [StringComparison]::Ordinal) -ge 0
            }
            timings_ms = [ordered]@{ import = $importMs }
            appearance = $appearanceSpec.evidence_name
            minimum_window = $minimum
            selection = $selection
            confirmation = $confirmation
            text_raster_targets = @($prefixRasterTarget, $confirmation.full_details.text_raster_target)
            blocking = $blocked
            actual_apply = $actualApply
            cancellation_disk_unchanged = $true
            journal_residue_count = 0
            normal_exit_code = $exitCode
        }
    }
    finally {
        if ($null -ne $application) {
            $application.process.Refresh()
            if (-not $application.process.HasExited) {
                Invoke-TaskkillTree -ProcessId $application.process.Id
                [void]$application.process.WaitForExit(10000)
            }
            $application.owned.process.Dispose()
        }
    }
}

function Initialize-TextScaleNative {
    if ('DarkReNamerTextScaleNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DarkReNamerTextScaleNative {
    private const int RpcChangedMode = unchecked((int)0x80010106);
    private const uint RoInitMultithreaded = 1;
    private static readonly Guid IidUiSettings2 = new Guid("bad82401-2721-44f9-bb91-2bb228be442f");

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int QueryInterfaceDelegate(IntPtr instance, ref Guid iid, out IntPtr value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate uint ReleaseDelegate(IntPtr instance);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int TextScaleFactorDelegate(IntPtr instance, out double value);

    [DllImport("combase.dll")]
    private static extern int RoInitialize(uint initType);
    [DllImport("combase.dll")]
    private static extern void RoUninitialize();
    [DllImport("combase.dll", CharSet=CharSet.Unicode)]
    private static extern int WindowsCreateString(string source, uint length, out IntPtr value);
    [DllImport("combase.dll")]
    private static extern int WindowsDeleteString(IntPtr value);
    [DllImport("combase.dll")]
    private static extern int RoActivateInstance(IntPtr classId, out IntPtr instance);

    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr SendMessageTimeoutW(
        IntPtr window, uint message, UIntPtr wParam, string lParam,
        uint flags, uint timeout, out UIntPtr result);

    private static IntPtr ReadVtableMethod(IntPtr instance, int slot) {
        if (instance == IntPtr.Zero) {
            throw new ArgumentException("A COM interface pointer is required.", "instance");
        }
        return Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), slot * IntPtr.Size);
    }

    private static void Release(ref IntPtr instance) {
        if (instance == IntPtr.Zero) { return; }
        var release = (ReleaseDelegate)Marshal.GetDelegateForFunctionPointer(
            ReadVtableMethod(instance, 2), typeof(ReleaseDelegate));
        release(instance);
        instance = IntPtr.Zero;
    }

    public static double ReadTextScaleFactor() {
        int initializeResult = RoInitialize(RoInitMultithreaded);
        bool uninitialize = initializeResult >= 0;
        if (initializeResult < 0 && initializeResult != RpcChangedMode) {
            Marshal.ThrowExceptionForHR(initializeResult);
        }

        IntPtr classId = IntPtr.Zero;
        IntPtr instance = IntPtr.Zero;
        IntPtr settings2 = IntPtr.Zero;
        try {
            const string runtimeClass = "Windows.UI.ViewManagement.UISettings";
            int result = WindowsCreateString(runtimeClass, (uint)runtimeClass.Length, out classId);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }
            result = RoActivateInstance(classId, out instance);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }

            var query = (QueryInterfaceDelegate)Marshal.GetDelegateForFunctionPointer(
                ReadVtableMethod(instance, 0), typeof(QueryInterfaceDelegate));
            Guid iid = IidUiSettings2;
            result = query(instance, ref iid, out settings2);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }

            var read = (TextScaleFactorDelegate)Marshal.GetDelegateForFunctionPointer(
                ReadVtableMethod(settings2, 6), typeof(TextScaleFactorDelegate));
            double value;
            result = read(settings2, out value);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }
            return value;
        }
        finally {
            Release(ref settings2);
            Release(ref instance);
            if (classId != IntPtr.Zero) { WindowsDeleteString(classId); }
            if (uninitialize) { RoUninitialize(); }
        }
    }

    public static void NotifyAccessibilitySettingChange() {
        UIntPtr result;
        SendMessageTimeoutW(
            new IntPtr(0xffff), 0x001A, UIntPtr.Zero, "Accessibility",
            0x0002, 5000, out result);
    }
}
'@
}

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



function Invoke-GuiRegressionAcceptance {
    $resolved = Resolve-AcceptanceBundle `
        -Root $BundleRoot `
        -ScriptPath $PSCommandPath `
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
    if ($input.schema_version -ne 1 -or
        $input.source_sha -cne $bundleManifest.source_sha -or
        $input.artifacts.application.sha256 -cne $bundleManifest.application.sha256 -or
        $input.artifacts.runner.sha256 -cne $bundleManifest.runner.sha256 -or
        $input.artifacts.observer.sha256 -cne $ExpectedScriptSha256 -or
        $input.request.mode -cne $RegressionMode -or
        $input.request.appearance -cne $Appearance -or
        $input.request.text_scale_percent -ne $TextScalePercent) {
        throw 'Regression invocation differs from its immutable manifest.'
    }
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
    if (($guest | ConvertTo-Json -Compress) -cne
        ($input.guest_preflight | ConvertTo-Json -Compress)) {
        throw 'Guest platform or VM identity differs from immutable preflight.'
    }
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
    $cursor = $null
    $textOriginal = $null
    $textAcceptance = $null
    $textChanged = $false
    $resultPath = Join-Path $resolved.output_root 'acceptance-result.json'
    $observationPath = Join-Path $resolved.output_root 'acceptance-observations.json'
    $diagnosticPath = Join-Path $resolved.output_root 'acceptance-error.txt'
    $result = [ordered]@{
        schema_version = 1
        source_sha = $input.source_sha
        target = $bundleManifest.target
        application = [ordered]@{
            file = $bundleManifest.application.file
            sha256 = $bundleManifest.application.sha256
        }
        runner_sha256 = $bundleManifest.runner.sha256
        acceptance_script_sha256 = $ExpectedScriptSha256
        appearance = [ordered]@{ requested = $Appearance; observed = $null }
        status = 'failed'
        visual_review = 'required'
        keyboard = [ordered]@{ status = 'failed' }
        accessibility = [ordered]@{ status = 'failed' }
        capture = [ordered]@{ status = 'failed' }
        assertions = [ordered]@{ overall = 'failed'; scenario = $null }
        text_scale = $null
        process_cleanup = $false
        guest_cleanup = $false
        screenshots = @()
        failure_reason = 'setup_failed'
        diagnostic = $null
    }
    $observations = [ordered]@{
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
        if ($null -ne $runtimeRoot -and (Test-Path -LiteralPath $runtimeRoot)) {
            try {
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
        $result.screenshots = $captures.ToArray()
        Write-JsonUtf8Bom -Path $observationPath -Value $observations
        Write-JsonUtf8Bom -Path $resultPath -Value $result
    }
    if ($result.status -ne 'review_required') {
        throw 'GUI regression observation failed; inspect output.'
    }
    Write-Host 'Captured GUI regression evidence; visual review remains required.'
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$bootstrap = Resolve-AcceptanceBootstrap `
    -Root $BundleRoot `
    -ScriptPath $PSCommandPath `
    -ScriptSha256 $ExpectedScriptSha256

if (-not [string]::IsNullOrEmpty($RegressionMode)) {
    if ([string]::IsNullOrEmpty($InputManifestPath)) {
        throw 'RegressionMode requires InputManifestPath.'
    }
    $regressionInvocation = [pscustomobject]@{
        bundle_root = $BundleRoot
        expected_session_id = $ExpectedSessionId
        output_root = $OutputRoot
        expected_script_sha256 = $ExpectedScriptSha256
        timeout_seconds = $TimeoutSeconds
        appearance = $Appearance
        regression_mode = $RegressionMode
        input_manifest_path = $InputManifestPath
        text_scale_percent = $TextScalePercent
        restore_text_scale_only = [bool]$RestoreTextScaleOnly
        validate_only = [bool]$ValidateOnly
    }
    . $bootstrap.runner `
        -BundleRoot $bootstrap.root `
        -ExpectedSessionId $ExpectedSessionId `
        -ValidateOnly
    $BundleRoot = $regressionInvocation.bundle_root
    $ExpectedSessionId = $regressionInvocation.expected_session_id
    $OutputRoot = $regressionInvocation.output_root
    $ExpectedScriptSha256 = $regressionInvocation.expected_script_sha256
    $TimeoutSeconds = $regressionInvocation.timeout_seconds
    $Appearance = $regressionInvocation.appearance
    $RegressionMode = $regressionInvocation.regression_mode
    $InputManifestPath = $regressionInvocation.input_manifest_path
    $TextScalePercent = $regressionInvocation.text_scale_percent
    $RestoreTextScaleOnly = $regressionInvocation.restore_text_scale_only
    $ValidateOnly = $regressionInvocation.validate_only
    Invoke-GuiRegressionAcceptance
    return
}

$acceptanceInvocation = [pscustomobject]@{
    bundle_root = $BundleRoot
    expected_session_id = $ExpectedSessionId
    output_root = $OutputRoot
    expected_script_sha256 = $ExpectedScriptSha256
    timeout_seconds = $TimeoutSeconds
    appearance = $Appearance
    capture_native_menu = [bool]$CaptureNativeMenu
    capture_advanced_appearance = [bool]$CaptureAdvancedAppearance
    clipboard = [bool]$Clipboard
    high_contrast = [bool]$HighContrast
    restore_high_contrast_only = [bool]$RestoreHighContrastOnly
    validate_only = [bool]$ValidateOnly
}
. $bootstrap.runner `
    -BundleRoot $bootstrap.root `
    -ExpectedSessionId $ExpectedSessionId `
    -ValidateOnly
$BundleRoot = $acceptanceInvocation.bundle_root
$ExpectedSessionId = $acceptanceInvocation.expected_session_id
$OutputRoot = $acceptanceInvocation.output_root
$ExpectedScriptSha256 = $acceptanceInvocation.expected_script_sha256
$TimeoutSeconds = $acceptanceInvocation.timeout_seconds
$Appearance = $acceptanceInvocation.appearance
$CaptureNativeMenu = $acceptanceInvocation.capture_native_menu
$CaptureAdvancedAppearance = $acceptanceInvocation.capture_advanced_appearance
$Clipboard = $acceptanceInvocation.clipboard
$HighContrast = $acceptanceInvocation.high_contrast
$RestoreHighContrastOnly = $acceptanceInvocation.restore_high_contrast_only
$ValidateOnly = $acceptanceInvocation.validate_only
$verified = Resolve-AcceptanceBundle `
    -Root $BundleRoot `
    -ScriptPath $PSCommandPath `
    -ScriptSha256 $ExpectedScriptSha256 `
    -RequestedOutputRoot $OutputRoot `
    -SessionId $ExpectedSessionId `
    -AllowExistingOutput:$RestoreHighContrastOnly
if ($HighContrast -and $Appearance -cne 'system') {
    throw 'High Contrast acceptance uses Forced Colors and requires the system appearance input.'
}
if ($HighContrast -and $CaptureAdvancedAppearance) {
    throw 'Advanced appearance capture is unavailable during Forced Colors acceptance.'
}
if ($RestoreHighContrastOnly -and
    ($Appearance -cne 'system' -or $CaptureNativeMenu -or $CaptureAdvancedAppearance)) {
    throw 'High Contrast rescue does not accept appearance or visual-surface controls.'
}
if ($RestoreHighContrastOnly -and $Clipboard) {
    throw 'High Contrast rescue does not accept Clipboard acceptance.'
}
if ($ValidateOnly) {
    if ($RestoreHighContrastOnly) {
        [void](Resolve-HighContrastRestoreDocument `
            -OutputDirectory $verified.output_root `
            -SourceSha $verified.source_sha `
            -ScriptSha256 $verified.script_sha256)
    }
    Write-Host "Validated current-DPI acceptance bundle for source $($verified.source_sha)."
    return
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Current-DPI acceptance requires Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Current-DPI acceptance must run non-elevated.'
}
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($currentSession -ne $ExpectedSessionId) {
    throw 'Current-DPI acceptance is running in an unexpected desktop session.'
}
if ($RestoreHighContrastOnly) {
    Invoke-HighContrastRescue -Verified $verified -SessionId $ExpectedSessionId
    return
}

[void](New-Item -ItemType Directory -Path $verified.output_root)
$runtimeRoot = New-PrivateDirectory -Parent $verified.output_root -Leaf 'runtime'
$resultPath = Join-Path $verified.output_root 'acceptance-result.json'
$observationPath = Join-Path $verified.output_root 'acceptance-observations.json'
$diagnosticPath = Join-Path $verified.output_root 'acceptance-error.txt'
$processState = [pscustomobject]@{ process = $null }
$desktopLock = $null
$previousExecutionState = $null
$runtimeCleanup = $false
$lifecycle = [pscustomobject]@{ process_terminated = $true }
$highContrastState = [pscustomobject]@{
    requested = [bool]$HighContrast
    changed = $false
    original = $null
    acceptance = $null
    restored = $null
    rescue_path = $null
    restoration_verified = $false
}
$clipboardState = [pscustomobject]@{
    owned = $false
    checks_complete = $false
    expected_sequence = [uint32]0
    expected_text = $null
}
$captures = [Collections.Generic.List[object]]::new()
$keyboard = [ordered]@{
    status = 'failed'
    reset_name_enabled_after_prefix = $false
    reset_name_native_enabled_after_prefix = $false
    reset_name_menu_enabled_after_prefix = $false
    reset_name_selection_pattern_available = $false
    reset_name_selection_count_after_prefix = $null
    reset_name_proposal_only = $false
    reset_name_displayed_parent_unchanged = $false
    reset_name_disabled_after_reset = $false
    cancellation_unchanged = $false
    confirmed_disk_rename = $false
    content_preserved = $false
    identity_preserved = $false
    journal_residue_count = $null
}
$accessibility = [ordered]@{ status = 'failed'; rail_button_count = 0 }
$capture = [ordered]@{ status = 'failed'; screenshot_count = 0; visual_review = 'required' }
$highContrastResult = [ordered]@{
    requested = [bool]$HighContrast
    original_enabled = $null
    acceptance_enabled = $null
    system_colors_changed = $null
    restoration = if ($HighContrast) { 'pending' } else { 'not_required' }
    snapshot = $null
}
$clipboardResult = if ($Clipboard) {
    [ordered]@{
        status = 'failed'
        reason = 'Clipboard acceptance did not complete.'
        preflight_empty = $false
        names = $null
        paths = $null
        cleanup = 'not_required'
    }
}
else {
    [ordered]@{
        status = 'not_run'
        reason = 'Clipboard acceptance was not requested.'
    }
}
$observations = [ordered]@{
    schema_version = 1
    environment = $null
    main_window = $null
    list = $null
    rail_buttons = @()
    file_dialog = $null
    prefix_prompt = $null
    native_menu = $null
    advanced_appearance = $null
    name_reset = $null
    apply_confirmation = $null
}
$result = [ordered]@{
    schema_version = 1
    source_sha = $verified.source_sha
    target = $verified.target
    application = [ordered]@{
        file = $verified.application.file
        sha256 = $verified.application.sha256
    }
    runner_sha256 = $verified.runner_sha256
    acceptance_script_sha256 = $verified.script_sha256
    appearance = [ordered]@{
        requested = $Appearance
        observed = $null
    }
    status = 'failed'
    visual_review = 'required'
    keyboard = $keyboard
    accessibility = $accessibility
    capture = $capture
    clipboard = $clipboardResult
    high_contrast = $highContrastResult
    observations = $null
    screenshots = @()
    guest_cleanup = $false
    failure_reason = 'setup_failed'
    diagnostic = $null
}

try {
    $desktopLock = Enter-DesktopTestLock -SessionId $currentSession
    if ($null -eq $desktopLock) {
        throw 'Another Windows VM test runner is using this interactive desktop.'
    }
    $previousExecutionState = Enter-TestExecutionState
    Initialize-NativeCapture
    Initialize-AcceptanceNative
    if (-not [DarkReNamerVmNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
        throw 'Windows refused the per-monitor-v2 acceptance DPI context.'
    }
    $highContrastState.original = [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot()
    $highContrastResult.original_enabled = ($highContrastState.original.Flags -band 1) -ne 0
    if ($HighContrast) {
        $highContrastState.rescue_path = Join-Path $verified.output_root 'high-contrast-restore.json'
        Write-JsonUtf8Bom -Path $highContrastState.rescue_path -Value ([ordered]@{
            schema_version = 2
            source_sha = $verified.source_sha
            acceptance_script_sha256 = $verified.script_sha256
            restoration_required = $true
            original = ConvertTo-HighContrastDocumentSnapshot -Snapshot $highContrastState.original
            restoration_verified = $false
            restored = $null
        })
        if (-not $highContrastResult.original_enabled) {
            $highContrastState.changed = $true
            [DarkReNamerVmAcceptanceNative]::ApplyHighContrast(
                (($highContrastState.original.Flags -bor 1) -band (-bnot 0x1000)),
                $highContrastState.original.Scheme
            )
        }
        $highContrastState.acceptance = Wait-HighContrastSettlement `
            -ReadSnapshot { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
            -AcceptSnapshot {
                param($candidate)
                $enabled = ($candidate.Flags -band 1) -ne 0
                $colorsChanged = -not (Test-HighContrastColorsEqual `
                    -Expected $highContrastState.original `
                    -Actual $candidate)
                $enabled -and ($highContrastResult.original_enabled -or $colorsChanged)
            } `
            -Label 'High Contrast activation'
        $highContrastResult.acceptance_enabled = ($highContrastState.acceptance.Flags -band 1) -ne 0
        if (-not $highContrastResult.acceptance_enabled) {
            throw 'Windows did not enable High Contrast for the acceptance session.'
        }
        $highContrastResult.system_colors_changed = -not (Test-HighContrastColorsEqual `
            -Expected $highContrastState.original `
            -Actual $highContrastState.acceptance)
    }
    else {
        $highContrastState.acceptance = $highContrastState.original
        $highContrastResult.acceptance_enabled = $highContrastResult.original_enabled
        $highContrastResult.system_colors_changed = $false
    }
    $capturePrefix = if ($HighContrast) {
        'high-contrast'
    }
    elseif ($Appearance -ceq 'system') {
        'current-dpi'
    }
    else {
        "current-dpi-$Appearance"
    }

    Invoke-WithIsolatedEnvironment -RuntimeRoot $runtimeRoot -Action {
        $caseRoot = New-PrivateDirectory -Parent $runtimeRoot -Leaf 'keyboard-flow'
        $fixtureRoot = New-PrivateDirectory -Parent $caseRoot -Leaf 'fixture'
        $sourceName = 'acceptance-source.txt'
        $prefix = 'accepted-'
        $destinationName = $prefix + $sourceName
        $sourcePath = Join-Path $fixtureRoot $sourceName
        $destinationPath = Join-Path $fixtureRoot $destinationName
        [IO.File]::WriteAllText(
            $sourcePath,
            "Current-DPI keyboard acceptance fixture`n",
            [Text.UTF8Encoding]::new($false)
        )
        $beforeContent = Get-LowerSha256 -Path $sourcePath
        $beforeIdentity = [DarkReNamerVmNative]::GetFileIdentity($sourcePath)

        $applicationPath = Join-Path $verified.root $verified.application.file
        Assert-OrdinaryFile -Path $applicationPath -Label 'acceptance application'
        if ((Get-LowerSha256 -Path $applicationPath) -cne $verified.application.sha256) {
            throw 'Acceptance application changed after bundle verification.'
        }
        $application = Start-AcceptanceApplication `
            -FilePath $applicationPath `
            -WorkingDirectory $verified.root `
            -SessionId $ExpectedSessionId `
            -WaitSeconds $TimeoutSeconds `
            -Label 'current-DPI acceptance application'
        $processState.process = $application.owned
        $lifecycle.process_terminated = $false
        $process = $application.process
        $mainWindow = $application.main

        $appearanceSpec = if ($HighContrast) {
            [ordered]@{ command_id = $null; evidence_name = 'forced-colors' }
        }
        else {
            Set-AcceptanceAppearance `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Appearance $Appearance
        }
        $result.appearance.observed = $appearanceSpec.evidence_name
        $captureWindow = Ensure-AcceptanceMainWindowCaptureSize `
            -MainWindow $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId

        $observations.environment = [ordered]@{
            os_version = [DarkReNamerVmAcceptanceNative]::OsVersion()
            dpi = $captureWindow.dpi
            appearance = $appearanceSpec.evidence_name
            capture_window = $captureWindow
            high_contrast = ($highContrastState.acceptance.Flags -band 1) -ne 0
            high_contrast_flags = $highContrastState.acceptance.Flags
            high_contrast_scheme = $highContrastState.acceptance.Scheme
            high_contrast_colors = [ordered]@{
                window = $highContrastState.acceptance.Window
                window_text = $highContrastState.acceptance.WindowText
                button_face = $highContrastState.acceptance.ButtonFace
                button_text = $highContrastState.acceptance.ButtonText
                highlight = $highContrastState.acceptance.Highlight
                highlight_text = $highContrastState.acceptance.HighlightText
                gray_text = $highContrastState.acceptance.GrayText
                hot_light = $highContrastState.acceptance.HotLight
            }
            ui_automation_client = [Windows.Automation.AutomationElement].Assembly.FullName
            ui_automation_types = [Windows.Automation.AutomationProperty].Assembly.FullName
            ui_automation_providers = [UIAutomationClientsideProviders.UIAutomationClientSideProviders].Assembly.FullName
        }
        $observations.main_window = Get-ElementObservation -Element $mainWindow
        $observations.rail_buttons = Get-RailAccessibilitySnapshot `
            -MainWindow $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -TimeoutSeconds $TimeoutSeconds
        $accessibility.rail_button_count = @($observations.rail_buttons).Count
        $list = Find-UniqueAutomationElement `
            -Root $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -AutomationId '1000' `
            -ControlType ([Windows.Automation.ControlType]::DataGrid) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'acceptance file list' `
            -RequireWindowHandle
        $gridPattern = $null
        if (-not $list.TryGetCurrentPattern([Windows.Automation.GridPattern]::Pattern, [ref]$gridPattern)) {
            throw 'The production file list does not expose GridPattern.'
        }
        $observations.list = Get-ElementObservation -Element $list
        $accessibility.status = 'passed'
        $initialCapture = Save-WindowScreenshot `
            -Window $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf ($capturePrefix + '-initial.png') `
            -Label 'current-DPI initial workbench'
        $captures.Add((Add-AcceptanceScreenshotContext `
            -Screenshot $initialCapture `
            -Appearance $appearanceSpec.evidence_name `
            -Surface 'main-workbench'))

        if ($CaptureNativeMenu) {
            $result.failure_reason = 'native_menu_capture_failed'
            Send-AcceptanceChord `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Modifier 0x12 `
                -VirtualKey 0x56 `
                -Label 'native View menu accelerator'
            $popup = Wait-AcceptancePopupMenu `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Label 'native View menu'
            $nativeMenuCapture = Save-AcceptanceNativeMenuScreenshot `
                -MainWindow $mainWindow `
                -Popup $popup `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Root $verified.output_root `
                -Leaf ($capturePrefix + '-native-menu.png') `
                -Label 'current-DPI native View menu'
            $captures.Add((Add-AcceptanceScreenshotContext `
                -Screenshot $nativeMenuCapture `
                -Appearance $appearanceSpec.evidence_name `
                -Surface 'native-menu'))
            $observations.native_menu = [ordered]@{
                captured = $true
                appearance = $appearanceSpec.evidence_name
            }
            Send-AcceptanceTap `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -VirtualKey 0x1B `
                -Label 'native View menu Escape'
            Wait-AcceptancePopupMenuClosed `
                -Process $process `
                -Label 'native View menu'
        }

        if ($CaptureAdvancedAppearance) {
            $result.failure_reason = 'advanced_appearance_capture_failed'
            [DarkReNamerVmAcceptanceNative]::SendMenuCommand(
                $process.MainWindowHandle,
                [uint32]0x9013
            )
            $appearanceDialog = Wait-UniqueAutomationWindow `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Name 'DarkReNamer - 모양 설정 (미리보기)' `
                -TimeoutSeconds $TimeoutSeconds `
                -Label 'advanced appearance window'
            $appearanceDialogHandle = [IntPtr]$appearanceDialog.Current.NativeWindowHandle
            $observations.advanced_appearance = [ordered]@{
                window = Get-ElementObservation -Element $appearanceDialog
                appearance = $appearanceSpec.evidence_name
            }
            $advancedAppearanceCapture = Save-WindowScreenshot `
                -Window $appearanceDialog `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Root $verified.output_root `
                -Leaf ($capturePrefix + '-advanced-appearance.png') `
                -Label 'current-DPI advanced appearance window'
            $captures.Add((Add-AcceptanceScreenshotContext `
                -Screenshot $advancedAppearanceCapture `
                -Appearance $appearanceSpec.evidence_name `
                -Surface 'advanced-appearance'))
            Send-AcceptanceTap `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -VirtualKey 0x1B `
                -Label 'advanced appearance Escape'
            Wait-WindowClosed `
                -Handle $appearanceDialogHandle `
                -TimeoutSeconds $TimeoutSeconds `
                -Label 'advanced appearance window'
            $mainWindow.SetFocus()
            [void][DarkReNamerVmNative]::SetForegroundWindow($process.MainWindowHandle)
            $advancedReturnDeadline = (Get-Date).AddSeconds(2)
            while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $process.MainWindowHandle -and
                (Get-Date) -lt $advancedReturnDeadline) {
                Start-Sleep -Milliseconds 50
            }
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $process.MainWindowHandle) {
                throw 'The application did not regain foreground after advanced appearance capture.'
            }
        }

        $result.failure_reason = 'file_dialog_failed'
        Send-AcceptanceChord `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Modifier 0x11 `
            -VirtualKey 0x4F `
            -Label 'Ctrl+O file-add accelerator'
        $fileDialog = Wait-UniqueAutomationWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Name '이름 붙일 파일 불러오기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'keyboard file dialog'
        $fileName = Find-UniqueAutomationElement `
            -Root $fileDialog `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -AutomationId '1148' `
            -ControlType ([Windows.Automation.ControlType]::Edit) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'keyboard filename field'
        $nativeOpen = Resolve-AcceptanceNativeOpen `
            -Dialog $fileDialog `
            -Process $process `
            -ExpectedSession $ExpectedSessionId
        $open = $nativeOpen.Element
        $openHandle = $nativeOpen.Handle
        $observations.file_dialog = [ordered]@{
            window = Get-ElementObservation -Element $fileDialog
            filename = Get-ElementObservation -Element $fileName
            open = Get-ElementObservation -Element $open
            dialog_native_handle = ([IntPtr]$fileDialog.Current.NativeWindowHandle).ToInt64()
            open_native_handle = $nativeOpen.Handle.ToInt64()
            open_native_class = $nativeOpen.ClassName
            open_native_control_id = 1
            open_native_process_id = $nativeOpen.ProcessId
            open_native_thread_id = $nativeOpen.ThreadId
            dialog_native_bounds = $nativeOpen.DialogBounds
            open_native_bounds = $nativeOpen.ControlBounds
        }
        $commonDialogCapture = Save-WindowScreenshot `
            -Window $fileDialog `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf ($capturePrefix + '-common-dialog.png') `
            -Label 'current-DPI common file dialog'
        $captures.Add((Add-AcceptanceScreenshotContext `
            -Screenshot $commonDialogCapture `
            -Appearance $appearanceSpec.evidence_name `
            -Surface 'common-dialog'))
        $fileName.SetFocus()
        Send-AcceptanceChord -Process $process -ExpectedSession $ExpectedSessionId -Modifier 0x11 -VirtualKey 0x41 -Label 'filename select-all'
        Send-AcceptanceText -Process $process -ExpectedSession $ExpectedSessionId -Value $sourcePath -Label 'filename keyboard input'
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'file dialog Enter'
        Wait-ListPreviewName `
            -MainWindow $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -ExpectedName $sourceName `
            -TimeoutSeconds $TimeoutSeconds

        $result.failure_reason = 'prefix_keyboard_failed'
        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32773')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'prefix command Space'
        $prompt = Wait-UniqueAutomationWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Name '이름 앞에 문자열 붙이기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'keyboard prefix prompt'
        $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
        $promptEdit = Find-UniqueAutomationElement -Root $prompt -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1004' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $TimeoutSeconds -Label 'prefix prompt edit' -RequireWindowHandle
        $promptOk = Find-UniqueAutomationElement -Root $prompt -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $TimeoutSeconds -Label 'prefix prompt OK' -RequireWindowHandle
        if ($promptEdit.Current.Name -cne '붙일 문자열') {
            throw "The prefix Edit accessible name is '$($promptEdit.Current.Name)', expected '붙일 문자열'."
        }
        $observations.prefix_prompt = [ordered]@{
            window = Get-ElementObservation -Element $prompt
            edit = Get-ElementObservation -Element $promptEdit
            ok = Get-ElementObservation -Element $promptOk
        }
        $inputPromptCapture = Save-WindowScreenshot `
            -Window $prompt `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf ($capturePrefix + '-input-prompt.png') `
            -Label 'current-DPI input prompt'
        $captures.Add((Add-AcceptanceScreenshotContext `
            -Screenshot $inputPromptCapture `
            -Appearance $appearanceSpec.evidence_name `
            -Surface 'input-prompt'))
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1004')
        Send-AcceptanceText -Process $process -ExpectedSession $ExpectedSessionId -Value $prefix -Label 'prefix keyboard input'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'prefix prompt Enter'
        Wait-WindowClosed `
            -Handle $promptHandle `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt'
        $selectionPatternObject = $null
        if ($list.TryGetCurrentPattern(
            [Windows.Automation.SelectionPattern]::Pattern,
            [ref]$selectionPatternObject
        )) {
            $keyboard.reset_name_selection_pattern_available = $true
            $selectionPattern = [Windows.Automation.SelectionPattern]$selectionPatternObject
            $keyboard.reset_name_selection_count_after_prefix =
                @($selectionPattern.Current.GetSelection()).Count
            if ($keyboard.reset_name_selection_count_after_prefix -ne 0) {
                throw 'The no-selection name reset scenario acquired a list selection after prefix.'
            }
        }
        else {
            throw 'The production file list does not expose SelectionPattern for the no-selection reset observation.'
        }
        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $destinationName -TimeoutSeconds $TimeoutSeconds
        if ($Clipboard) {
            $result.failure_reason = 'clipboard_preflight_failed'
            $clipboardPreflight = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
            if (@($clipboardPreflight.Formats).Count -ne 0 -or
                $null -ne $clipboardPreflight.UnicodeText) {
                throw 'Clipboard acceptance requires an initially empty Clipboard and will not clear existing data.'
            }
            $clipboardResult.preflight_empty = $true
            $expectedNames = $destinationName + "`r`n"
            $expectedPaths = $sourcePath + "`r`n"

            $result.failure_reason = 'clipboard_names_failed'
            Assert-AcceptanceForegroundBinding `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -RequireMainWindow
            if (-not [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                $process.MainWindowHandle,
                [uint32]0x8018
            )) {
                throw 'The native Copy Names menu command is not enabled for the known row.'
            }
            Send-AcceptanceChord `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Modifier 0x12 `
                -VirtualKey 0x46 `
                -Label 'Clipboard native File menu accelerator'
            [void](Wait-AcceptancePopupMenu `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Label 'Clipboard native File menu')
            Send-AcceptanceTap `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -VirtualKey 0x58 `
                -Label 'Clipboard Export submenu mnemonic'
            $copyNamesItem = Find-AcceptanceMenuItem `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -Name '변경 후 이름 목록 복사' `
                -TimeoutSeconds $TimeoutSeconds
            Assert-AcceptanceForegroundBinding `
                -Process $process `
                -ExpectedSession $ExpectedSessionId
            $clipboardBeforeNames = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
            if ($clipboardBeforeNames.SequenceNumber -ne $clipboardPreflight.SequenceNumber -or
                @($clipboardBeforeNames.Formats).Count -ne 0 -or
                $null -ne $clipboardBeforeNames.UnicodeText) {
                throw 'Clipboard changed before Copy Names; preserving it without invoking the menu item.'
            }
            $invokePatternObject = $null
            if (-not $copyNamesItem.TryGetCurrentPattern(
                [Windows.Automation.InvokePattern]::Pattern,
                [ref]$invokePatternObject
            )) {
                throw 'The native Copy Names menu item does not expose InvokePattern.'
            }
            ([Windows.Automation.InvokePattern]$invokePatternObject).Invoke()
            Wait-AcceptancePopupMenuClosed -Process $process -Label 'Clipboard native File menu'
            $namesSnapshot = Wait-AcceptanceClipboardText `
                -PreviousSequence $clipboardPreflight.SequenceNumber `
                -ExpectedText $expectedNames `
                -TimeoutSeconds $TimeoutSeconds `
                -Label 'Copy Names menu command'
            $clipboardState.owned = $true
            $clipboardState.expected_sequence = $namesSnapshot.SequenceNumber
            $clipboardState.expected_text = $expectedNames
            $clipboardResult.names = Get-AcceptanceClipboardTextEvidence -Text $namesSnapshot.UnicodeText

            $result.failure_reason = 'clipboard_paths_failed'
            $mainWindow.SetFocus()
            [void][DarkReNamerVmNative]::SetForegroundWindow($process.MainWindowHandle)
            $clipboardForegroundDeadline = (Get-Date).AddSeconds(2)
            while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $process.MainWindowHandle -and
                (Get-Date) -lt $clipboardForegroundDeadline) {
                Start-Sleep -Milliseconds 50
            }
            Assert-AcceptanceForegroundBinding `
                -Process $process `
                -ExpectedSession $ExpectedSessionId `
                -RequireMainWindow
            if (-not [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                $process.MainWindowHandle,
                [uint32]0x801A
            )) {
                throw 'The native Copy Paths menu command is not enabled for the known row.'
            }
            $beforePaths = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
            if (-not (Test-AcceptanceClipboardSnapshotOwned `
                -Snapshot $beforePaths `
                -ExpectedSequence $clipboardState.expected_sequence `
                -ExpectedText $clipboardState.expected_text)) {
                throw 'Clipboard changed before Copy Paths; preserving it without invoking the shortcut.'
            }
            Send-AcceptanceTwoModifierChord -Process $process -ExpectedSession $ExpectedSessionId -Modifier 0x11 -SecondModifier 0x10 -VirtualKey 0x43 -Label 'Ctrl+Shift+C Copy Paths shortcut'
            $pathsSnapshot = Wait-AcceptanceClipboardText `
                -PreviousSequence $namesSnapshot.SequenceNumber `
                -ExpectedText $expectedPaths `
                -TimeoutSeconds $TimeoutSeconds `
                -Label 'Ctrl+Shift+C Copy Paths shortcut'
            $clipboardState.expected_sequence = $pathsSnapshot.SequenceNumber
            $clipboardState.expected_text = $expectedPaths
            $clipboardState.checks_complete = $true
            $clipboardResult.paths = Get-AcceptanceClipboardTextEvidence -Text $pathsSnapshot.UnicodeText
            $clipboardResult.status = 'pending_cleanup'
            $clipboardResult.reason = $null
            $clipboardResult.cleanup = 'pending'
        }
        $beforeReset = Get-ListPrimarySnapshot -List $list
        $reset = Find-UniqueAutomationElement `
            -Root $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -AutomationId '32781' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'name reset after prefix' `
            -RequireEnabled `
            -RequireWindowHandle
        $keyboard.reset_name_enabled_after_prefix = $reset.Current.IsEnabled
        $keyboard.reset_name_native_enabled_after_prefix =
            [DarkReNamerVmAcceptanceNative]::IsWindowEnabled(
                [IntPtr]$reset.Current.NativeWindowHandle
            )
        $keyboard.reset_name_menu_enabled_after_prefix =
            [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
                $process.MainWindowHandle,
                0x800D
            )
        if (-not $keyboard.reset_name_native_enabled_after_prefix -or
            -not $keyboard.reset_name_menu_enabled_after_prefix) {
            throw 'Name reset did not become enabled in both the native rail and menu after prefix.'
        }
        $observations.name_reset = [ordered]@{
            before = [ordered]@{
                rail = Get-ElementObservation -Element $reset
                native_enabled = $keyboard.reset_name_native_enabled_after_prefix
                menu_enabled = $keyboard.reset_name_menu_enabled_after_prefix
                selection_pattern_available = $keyboard.reset_name_selection_pattern_available
                selected_item_count = $keyboard.reset_name_selection_count_after_prefix
                row = $beforeReset
            }
            after = $null
        }
        $previewCapture = Save-WindowScreenshot -Window $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf ($capturePrefix + '-preview.png') -Label 'current-DPI rename preview before name reset'
        $captures.Add((Add-AcceptanceScreenshotContext -Screenshot $previewCapture -Appearance $appearanceSpec.evidence_name -Surface 'main-workbench'))

        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32781')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'name reset Space'
        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $sourceName -TimeoutSeconds $TimeoutSeconds
        $afterReset = Get-ListPrimarySnapshot -List $list
        $resetAfter = Find-UniqueAutomationElement `
            -Root $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -AutomationId '32781' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'name reset after reset' `
            -RequireWindowHandle
        $nativeResetDisabled = -not [DarkReNamerVmAcceptanceNative]::IsWindowEnabled(
            [IntPtr]$resetAfter.Current.NativeWindowHandle
        )
        $menuResetDisabled = -not [DarkReNamerVmAcceptanceNative]::IsMenuCommandEnabled(
            $process.MainWindowHandle,
            0x800D
        )
        $keyboard.reset_name_disabled_after_reset =
            (-not $resetAfter.Current.IsEnabled) -and $nativeResetDisabled -and $menuResetDisabled
        $keyboard.reset_name_displayed_parent_unchanged =
            $beforeReset.destination_parent -ceq $afterReset.destination_parent -and
            $afterReset.destination_parent -ceq $fixtureRoot
        $keyboard.reset_name_proposal_only =
            $afterReset.current_name -ceq $sourceName -and
            $afterReset.proposed_name -ceq $sourceName -and
            (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $destinationPath) -and
            (Get-LowerSha256 -Path $sourcePath) -ceq $beforeContent -and
            [DarkReNamerVmNative]::GetFileIdentity($sourcePath) -ceq $beforeIdentity
        if (-not $keyboard.reset_name_disabled_after_reset -or
            -not $keyboard.reset_name_displayed_parent_unchanged -or
            -not $keyboard.reset_name_proposal_only) {
            throw 'Name reset did not restore only the proposal while leaving the displayed parent and disk state unchanged.'
        }
        $observations.name_reset.after = [ordered]@{
            rail = Get-ElementObservation -Element $resetAfter
            native_enabled = -not $nativeResetDisabled
            menu_enabled = -not $menuResetDisabled
            row = $afterReset
        }
        $resetCapture = Save-WindowScreenshot -Window $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf ($capturePrefix + '-preview-after-name-reset.png') -Label 'current-DPI rename preview after name reset'
        $captures.Add((Add-AcceptanceScreenshotContext -Screenshot $resetCapture -Appearance $appearanceSpec.evidence_name -Surface 'main-workbench'))

        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32773')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'second prefix command Space'
        $prompt = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $ExpectedSessionId -Name '이름 앞에 문자열 붙이기' -TimeoutSeconds $TimeoutSeconds -Label 'second keyboard prefix prompt'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1004')
        Send-AcceptanceText -Process $process -ExpectedSession $ExpectedSessionId -Value $prefix -Label 'second prefix keyboard input'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'second prefix prompt Enter'
        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $destinationName -TimeoutSeconds $TimeoutSeconds

        $result.failure_reason = 'apply_cancellation_failed'
        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32771')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'Apply command Space'
        $confirmation = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $ExpectedSessionId -Name 'DarkReNamer - 안전한 적용 확인' -TimeoutSeconds $TimeoutSeconds -Label 'keyboard Apply confirmation'
        $cancel = Find-UniqueAutomationElement -Root $confirmation -Process $process -ExpectedSession $ExpectedSessionId -AutomationId 'CommandButton_2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $TimeoutSeconds -Label 'Apply cancellation button' -RequireWindowHandle
        $confirm = Find-UniqueAutomationElement -Root $confirmation -Process $process -ExpectedSession $ExpectedSessionId -AutomationId 'CommandLink_1101' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $TimeoutSeconds -Label 'Apply command link' -RequireWindowHandle
        $observations.apply_confirmation = [ordered]@{
            window = Get-ElementObservation -Element $confirmation
            cancel = Get-ElementObservation -Element $cancel
            confirm = Get-ElementObservation -Element $confirm
        }
        $confirmationCapture = Save-WindowScreenshot -Window $confirmation -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf ($capturePrefix + '-confirmation.png') -Label 'current-DPI Apply confirmation'
        $captures.Add((Add-AcceptanceScreenshotContext -Screenshot $confirmationCapture -Appearance $appearanceSpec.evidence_name -Surface 'confirmation-task-dialog'))
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x1B -Label 'Apply confirmation Escape'
        $cancellationDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            if ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
                -not (Test-Path -LiteralPath $destinationPath) -and
                [DarkReNamerVmNative]::GetForegroundWindow() -eq $process.MainWindowHandle) {
                break
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $cancellationDeadline)
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $keyboard.cancellation_unchanged = (
            (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $destinationPath) -and
            (Get-LowerSha256 -Path $sourcePath) -ceq $beforeContent -and
            [DarkReNamerVmNative]::GetFileIdentity($sourcePath) -ceq $beforeIdentity
        )
        if (-not $keyboard.cancellation_unchanged) {
            throw 'Escape cancellation changed the acceptance fixture.'
        }

        $result.failure_reason = 'apply_confirmation_failed'
        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32771')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'second Apply command Space'
        $confirmation = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $ExpectedSessionId -Name 'DarkReNamer - 안전한 적용 확인' -TimeoutSeconds $TimeoutSeconds -Label 'second keyboard Apply confirmation'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId 'CommandLink_1101')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'Apply confirmation Enter'
        $applyDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            if (-not (Test-Path -LiteralPath $sourcePath) -and
                (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                try { Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA; break } catch {}
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $applyDeadline)
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $keyboard.confirmed_disk_rename = (
            -not (Test-Path -LiteralPath $sourcePath) -and
            (Test-Path -LiteralPath $destinationPath -PathType Leaf)
        )
        if (-not $keyboard.confirmed_disk_rename) {
            throw 'Keyboard-confirmed Apply did not perform the expected rename.'
        }
        $keyboard.content_preserved = (Get-LowerSha256 -Path $destinationPath) -ceq $beforeContent
        $keyboard.identity_preserved = [DarkReNamerVmNative]::GetFileIdentity($destinationPath) -ceq $beforeIdentity
        if (-not $keyboard.content_preserved -or -not $keyboard.identity_preserved) {
            throw 'Keyboard-confirmed Apply did not preserve file contents and identity.'
        }
        $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
        $keyboard.journal_residue_count = if (Test-Path -LiteralPath $journalRoot) {
            @(Get-ChildItem -LiteralPath $journalRoot -Force | Where-Object Name -cne 'runtime.lock').Count
        } else { 0 }
        $keyboard.status = 'passed'
        $capture.status = 'passed'
        $capture.screenshot_count = $captures.Count

        $result.failure_reason = 'normal_close_failed'
        [void](Close-AcceptanceApplication -Application $application -SessionId $ExpectedSessionId -WaitSeconds 10 -Input keyboard)
        $lifecycle.process_terminated = $true
    }

    $result.status = Get-AcceptanceVerdict `
        -KeyboardStatus $keyboard.status `
        -AccessibilityStatus $accessibility.status `
        -CaptureStatus $capture.status
    $result.failure_reason = $null
}
catch {
    $_ | Out-String | Set-Content -LiteralPath $diagnosticPath -Encoding UTF8
    $result.diagnostic = [ordered]@{
        file = 'acceptance-error.txt'
        sha256 = Get-LowerSha256 -Path $diagnosticPath
    }
}
finally {
    try { [DarkReNamerVmAcceptanceNative]::ReleaseModifiers() } catch {}
    if ($Clipboard -and $clipboardState.owned) {
        try {
            $clipboardCleanup = [DarkReNamerVmAcceptanceNative]::ClearClipboardIfOwned(
                $clipboardState.expected_sequence,
                $clipboardState.expected_text
            )
            if ($clipboardCleanup -ceq 'cleared') {
                $clipboardResult.cleanup = 'cleared'
                if ($clipboardState.checks_complete) {
                    $clipboardResult.status = 'passed'
                    $clipboardResult.reason = $null
                }
            }
            else {
                $clipboardResult.status = 'failed'
                $clipboardResult.reason = 'Clipboard changed after acceptance; foreign data was preserved.'
                $clipboardResult.cleanup = 'preserved_foreign_change'
                $result.status = 'failed'
                if ($null -eq $result.failure_reason) {
                    $result.failure_reason = 'clipboard_cleanup_preserved_foreign_change'
                }
            }
        }
        catch {
            $clipboardResult.status = 'failed'
            $clipboardResult.reason = 'Guarded Clipboard cleanup could not be verified.'
            $clipboardResult.cleanup = 'failed'
            $result.status = 'failed'
            if ($null -eq $result.failure_reason) {
                $result.failure_reason = 'clipboard_cleanup_failed'
            }
            $_ | Out-String | Add-Content -LiteralPath $diagnosticPath -Encoding UTF8
        }
    }
    if ($null -ne $processState.process) {
        try {
            $process = $processState.process.process
            $process.Refresh()
            if (-not $process.HasExited) {
                Invoke-TaskkillTree -ProcessId $process.Id
                if (-not $process.WaitForExit(10000)) {
                    $result.status = 'failed'
                    $result.failure_reason = 'process_cleanup_failed'
                }
            }
            $lifecycle.process_terminated = $process.HasExited
        }
        finally {
            $processState.process.process.Dispose()
        }
    }
    if ($HighContrast -and $null -ne $highContrastState.original) {
        try {
            if ($highContrastState.changed) {
                [DarkReNamerVmAcceptanceNative]::ApplyHighContrast(
                    $highContrastState.original.Flags,
                    $highContrastState.original.Scheme
                )
            }
            $highContrastState.restored = Wait-HighContrastRestoration `
                -Expected $highContrastState.original `
                -ReadSnapshot { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
                -Label 'High Contrast restoration' `
                -DiagnosticPath $diagnosticPath `
                -AllowPaletteRestore:$highContrastState.changed
            $highContrastState.restoration_verified = $true
            $highContrastResult.restoration = 'verified'
            Write-JsonUtf8Bom -Path $highContrastState.rescue_path -Value ([ordered]@{
                schema_version = 2
                source_sha = $verified.source_sha
                acceptance_script_sha256 = $verified.script_sha256
                restoration_required = $false
                original = ConvertTo-HighContrastDocumentSnapshot -Snapshot $highContrastState.original
                restoration_verified = $true
                restored = ConvertTo-HighContrastDocumentSnapshot -Snapshot $highContrastState.restored
            })
        }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'high_contrast_restore_failed'
            $_ | Out-String | Add-Content -LiteralPath $diagnosticPath -Encoding UTF8
            $highContrastResult.restoration = 'failed'
        }
        if (Test-Path -LiteralPath $highContrastState.rescue_path -PathType Leaf) {
            $highContrastResult.snapshot = [ordered]@{
                file = 'high-contrast-restore.json'
                sha256 = Get-LowerSha256 -Path $highContrastState.rescue_path
            }
        }
    }
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
        $_ | Out-String | Add-Content -LiteralPath $diagnosticPath -Encoding UTF8
    }
    try {
        if (-not $lifecycle.process_terminated) {
            throw 'The owned application process is still running; runtime evidence was retained.'
        }
        if (Test-Path -LiteralPath $runtimeRoot) {
            $runtimeItem = Get-Item -LiteralPath $runtimeRoot -Force
            if (($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Acceptance runtime root became a reparse point.'
            }
            $pending = [Collections.Generic.Stack[string]]::new()
            $pending.Push($runtimeRoot)
            while ($pending.Count -gt 0) {
                $directory = $pending.Pop()
                foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw 'Acceptance runtime contains a reparse point; evidence was retained.'
                    }
                    if ($item.PSIsContainer) { $pending.Push($item.FullName) }
                }
            }
            Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
        }
        $runtimeCleanup = -not (Test-Path -LiteralPath $runtimeRoot)
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'runtime_cleanup_failed'
    }
    $result.guest_cleanup = $runtimeCleanup
    $result.screenshots = $captures.ToArray()
    if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
        $result.diagnostic = [ordered]@{
            file = 'acceptance-error.txt'
            sha256 = Get-LowerSha256 -Path $diagnosticPath
        }
    }
    Write-JsonUtf8Bom -Path $observationPath -Value $observations
    $result.observations = [ordered]@{
        file = 'acceptance-observations.json'
        sha256 = Get-LowerSha256 -Path $observationPath
    }
    Write-JsonUtf8Bom -Path $resultPath -Value $result
}

if ($result.status -eq 'failed') {
    throw 'Current-DPI acceptance failed; inspect the external result and diagnostic artifacts.'
}
Write-Host "Captured source-bound current-DPI evidence; visual review remains required."
