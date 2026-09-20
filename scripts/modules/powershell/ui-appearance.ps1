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
