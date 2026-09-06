[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BundleRoot,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $ExpectedSessionId,
    [Parameter(Mandatory)][string] $OutputRoot,
    [Parameter(Mandatory)][string] $ExpectedScriptSha256,
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 60,
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
        [Parameter(Mandatory)][int] $SessionId
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
    if (Test-Path -LiteralPath $outputRoot) {
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

function Initialize-AcceptanceNative {
    if ('DarkReNamerVmAcceptanceNative' -as [type]) {
        return
    }
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DarkReNamerVmAcceptanceNative {
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
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    private static extern int RtlGetVersion(ref RTL_OSVERSIONINFOEX version);

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

    public static bool HighContrastEnabled() {
        HIGHCONTRAST value = new HIGHCONTRAST();
        value.size = (uint)Marshal.SizeOf(typeof(HIGHCONTRAST));
        if (!SystemParametersInfo(0x42, value.size, ref value, 0)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return (value.flags & 1) != 0;
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

function Send-AcceptanceTap {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][ushort] $VirtualKey,
        [Parameter(Mandatory)][string] $Label
    )

    [void](Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label $Label)
    [DarkReNamerVmAcceptanceNative]::Tap($VirtualKey)
}

function Send-AcceptanceChord {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][ushort] $Modifier,
        [Parameter(Mandatory)][ushort] $VirtualKey,
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
        [DarkReNamerVmAcceptanceNative]::Tap(0x09)
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
    $focused = $null
    for ($step = 0; $step -lt 32; $step++) {
        $focused = Get-FocusedAcceptanceElement `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label 'keyboard command-rail navigation'
        if ($leftIds -contains $focused.Current.AutomationId) {
            break
        }
        [DarkReNamerVmAcceptanceNative]::Tap(0x09)
    }
    if ($null -eq $focused -or $leftIds -notcontains $focused.Current.AutomationId) {
        throw 'Keyboard Tab navigation did not enter the left command rail.'
    }
    for ($step = 0; $step -lt $leftIds.Count; $step++) {
        if ($focused.Current.AutomationId -ceq $AutomationId) {
            return $focused
        }
        $currentIndex = [Array]::IndexOf($leftIds, $focused.Current.AutomationId)
        $targetIndex = [Array]::IndexOf($leftIds, $AutomationId)
        $direction = if ($currentIndex -lt $targetIndex) { 0x28 } else { 0x26 }
        [DarkReNamerVmAcceptanceNative]::Tap([ushort]$direction)
        $focused = Get-FocusedAcceptanceElement `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label 'keyboard arrow navigation'
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

function Write-JsonUtf8Bom {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object] $Value)

    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($true))
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
$ValidateOnly = $acceptanceInvocation.validate_only
$verified = Resolve-AcceptanceBundle `
    -Root $BundleRoot `
    -ScriptPath $PSCommandPath `
    -ScriptSha256 $ExpectedScriptSha256 `
    -RequestedOutputRoot $OutputRoot `
    -SessionId $ExpectedSessionId
if ($ValidateOnly) {
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
$captures = [Collections.Generic.List[object]]::new()
$keyboard = [ordered]@{
    status = 'failed'
    cancellation_unchanged = $false
    confirmed_disk_rename = $false
    content_preserved = $false
    identity_preserved = $false
    journal_residue_count = $null
}
$accessibility = [ordered]@{ status = 'failed'; rail_button_count = 0 }
$capture = [ordered]@{ status = 'failed'; screenshot_count = 0; visual_review = 'required' }
$clipboard = [ordered]@{
    status = 'not_run'
    reason = 'Lossless restoration of every existing clipboard format is unavailable in this session.'
}
$observations = [ordered]@{
    schema_version = 1
    environment = $null
    main_window = $null
    list = $null
    rail_buttons = @()
    file_dialog = $null
    prefix_prompt = $null
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
    status = 'failed'
    visual_review = 'required'
    keyboard = $keyboard
    accessibility = $accessibility
    capture = $capture
    clipboard = $clipboard
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

        $observations.environment = [ordered]@{
            os_version = [DarkReNamerVmAcceptanceNative]::OsVersion()
            dpi = [DarkReNamerVmAcceptanceNative]::GetDpiForWindow($process.MainWindowHandle)
            high_contrast = [DarkReNamerVmAcceptanceNative]::HighContrastEnabled()
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
        $captures.Add((Save-WindowScreenshot `
            -Window $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf 'current-dpi-initial.png' `
            -Label 'current-DPI initial workbench'))

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
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'keyboard filename field'
        $open = Find-UniqueAutomationElement `
            -Root $fileDialog `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -AutomationId '1' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'keyboard file dialog open button' `
            -RequireWindowHandle
        $observations.file_dialog = [ordered]@{
            window = Get-ElementObservation -Element $fileDialog
            filename = Get-ElementObservation -Element $fileName
            open = Get-ElementObservation -Element $open
        }
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
        $promptEdit = Find-UniqueAutomationElement -Root $prompt -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1004' -ControlType ([Windows.Automation.ControlType]::Edit) -TimeoutSeconds $TimeoutSeconds -Label 'prefix prompt edit' -RequireWindowHandle
        $promptOk = Find-UniqueAutomationElement -Root $prompt -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $TimeoutSeconds -Label 'prefix prompt OK' -RequireWindowHandle
        $observations.prefix_prompt = [ordered]@{
            window = Get-ElementObservation -Element $prompt
            edit = Get-ElementObservation -Element $promptEdit
            ok = Get-ElementObservation -Element $promptOk
        }
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1004')
        Send-AcceptanceText -Process $process -ExpectedSession $ExpectedSessionId -Value $prefix -Label 'prefix keyboard input'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'prefix prompt Enter'
        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $destinationName -TimeoutSeconds $TimeoutSeconds
        $captures.Add((Save-WindowScreenshot -Window $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf 'current-dpi-preview.png' -Label 'current-DPI rename preview'))

        $result.failure_reason = 'apply_cancellation_failed'
        [void](Move-RailFocusToCommand -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32771')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x20 -Label 'Apply command Space'
        $confirmation = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $ExpectedSessionId -Name 'DarkReNamer - 안전한 적용 확인' -TimeoutSeconds $TimeoutSeconds -Label 'keyboard Apply confirmation'
        $cancel = Find-UniqueAutomationElement -Root $confirmation -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '2' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $TimeoutSeconds -Label 'Apply cancellation button' -RequireWindowHandle
        $confirm = Find-UniqueAutomationElement -Root $confirmation -Process $process -ExpectedSession $ExpectedSessionId -AutomationId 'CommandLink_1101' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $TimeoutSeconds -Label 'Apply command link' -RequireWindowHandle
        $observations.apply_confirmation = [ordered]@{
            window = Get-ElementObservation -Element $confirmation
            cancel = Get-ElementObservation -Element $cancel
            confirm = Get-ElementObservation -Element $confirm
        }
        $captures.Add((Save-WindowScreenshot -Window $confirmation -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf 'current-dpi-confirmation.png' -Label 'current-DPI Apply confirmation'))
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
    try {
        Exit-TestExecutionState -Previous $previousExecutionState
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'execution_state_restore_failed'
    }
    Exit-DesktopTestLock -Lock $desktopLock
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
