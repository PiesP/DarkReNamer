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
        [ValidateRange(2, 50)][int] $MaximumAttempts = 50,
        [ValidateRange(2, 24)][int] $FallbackAttempts = 24,
        [ValidateRange(0, 1000)][int] $PollMilliseconds = 200
    )

    $restorationObservationState = [pscustomobject]@{
        read_snapshot = $ReadSnapshot
        expected = $Expected
        observed = [Collections.Generic.List[object]]::new()
        callback_error = $false
    }
    $observingRead = {
        try {
            $snapshot = & $restorationObservationState.read_snapshot
            $restorationObservationState.observed.Add($snapshot)
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
    [void](& $SetCapturedColors $Expected)
    Wait-HighContrastSettlement `
        -ReadSnapshot $ReadSnapshot `
        -AcceptSnapshot {
            param($candidate)
            Test-HighContrastSnapshotEqual -Expected $Expected -Actual $candidate
        } `
        -Label "$Label palette fallback" `
        -MaximumAttempts $FallbackAttempts `
        -PollMilliseconds $PollMilliseconds
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
        $_ | Out-String | Set-Content -LiteralPath $errorPath -Encoding UTF8
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
    private static extern uint GetClipboardSequenceNumber();
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
        [Parameter(Mandatory)][string] $Label
    )

    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        try {
            $snapshot = [DarkReNamerVmAcceptanceNative]::ReadClipboardSnapshot()
            if ($snapshot.SequenceNumber -ne $PreviousSequence) {
                if (-not (Test-AcceptanceClipboardSnapshotOwned `
                    -Snapshot $snapshot `
                    -ExpectedSequence $snapshot.SequenceNumber `
                    -ExpectedText $ExpectedText)) {
                    throw "$Label changed the Clipboard to unexpected text or formats."
                }
                return $snapshot
            }
        }
        catch {
            if ($_.Exception.Message.IndexOf('unexpected text or formats', [StringComparison]::Ordinal) -ge 0) {
                throw
            }
        }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    throw "$Label did not produce the exact expected Clipboard text before the bounded deadline."
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

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$bootstrap = Resolve-AcceptanceBootstrap `
    -Root $BundleRoot `
    -ScriptPath $PSCommandPath `
    -ScriptSha256 $ExpectedScriptSha256
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
        $processState.process = Start-OwnedProcess `
            -FilePath $applicationPath `
            -Arguments '' `
            -WorkingDirectory $verified.root
        $lifecycle.process_terminated = $false
        $process = $processState.process.process
        $windowDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            $process.Refresh()
            if ($process.HasExited) { throw 'Application exited before its acceptance window appeared.' }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $windowDeadline)
        if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
            throw 'Application window did not appear before the bounded deadline.'
        }
        $mainWindow = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        Assert-AutomationBinding `
            -Element $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Label 'acceptance main window' `
            -RequireWindowHandle
        $mainWindow.SetFocus()
        [void][DarkReNamerVmNative]::SetForegroundWindow($process.MainWindowHandle)
        $foregroundDeadline = (Get-Date).AddSeconds(5)
        while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $process.MainWindowHandle -and
            (Get-Date) -lt $foregroundDeadline) {
            Start-Sleep -Milliseconds 100
        }
        if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $process.MainWindowHandle) {
            throw 'Application window did not become the exact foreground target.'
        }

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
        $mainWindow.SetFocus()
        Send-AcceptanceChord -Process $process -ExpectedSession $ExpectedSessionId -Modifier 0x12 -VirtualKey 0x73 -Label 'application Alt+F4 close'
        if (-not $process.WaitForExit(10000)) {
            throw 'Application did not exit after the keyboard close command.'
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw 'Application returned a nonzero exit code after normal close.'
        }
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
