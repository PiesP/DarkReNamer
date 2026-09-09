[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BundleRoot,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $ExpectedSessionId,
    [Parameter(Mandatory)][string] $OutputRoot,
    [Parameter(Mandatory)][string] $ExpectedScriptSha256,
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 60,
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

    if ($Expected.Flags -ne $Actual.Flags -or
        -not [string]::Equals(
            [string]$Expected.Scheme,
            [string]$Actual.Scheme,
            [StringComparison]::Ordinal
        )) {
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
    if ($document.schema_version -ne 1 -or
        $document.source_sha -cne $SourceSha -or
        $document.acceptance_script_sha256 -cne $ScriptSha256) {
        throw 'High Contrast restore snapshot binding mismatch.'
    }
    if ($document.restoration_required -isnot [bool] -or
        $document.restoration_verified -isnot [bool]) {
        throw 'High Contrast restore snapshot state is invalid.'
    }
    if (($document.original.flags -isnot [int] -and
        $document.original.flags -isnot [long]) -or
        ($null -ne $document.original.scheme -and
        $document.original.scheme -isnot [string])) {
        throw 'High Contrast restore snapshot settings are invalid.'
    }
    $colors = $document.original.colors
    $expectedColorNames = @(
        'button_face','button_text','gray_text','highlight',
        'highlight_text','hot_light','window','window_text'
    )
    $actualColorNames = @($colors.PSObject.Properties.Name | Sort-Object)
    if ($actualColorNames.Count -ne $expectedColorNames.Count) {
        throw 'High Contrast restore snapshot colors are incomplete.'
    }
    for ($index = 0; $index -lt $expectedColorNames.Count; $index++) {
        $name = $expectedColorNames[$index]
        if ($actualColorNames[$index] -cne $name -or
            ($colors.$name -isnot [int] -and $colors.$name -isnot [long])) {
            throw 'High Contrast restore snapshot colors are invalid.'
        }
    }
    $expected = [pscustomobject]@{
        Flags = [uint32]$document.original.flags
        Scheme = $document.original.scheme
        Window = [uint32]$colors.window
        WindowText = [uint32]$colors.window_text
        ButtonFace = [uint32]$colors.button_face
        ButtonText = [uint32]$colors.button_text
        Highlight = [uint32]$colors.highlight
        HighlightText = [uint32]$colors.highlight_text
        GrayText = [uint32]$colors.gray_text
        HotLight = [uint32]$colors.hot_light
    }
    if (($expected.Flags -band 0x1000) -ne 0) {
        throw 'High Contrast restore snapshot contains a prohibited toggle option.'
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
            $actual = Wait-HighContrastSettlement `
                -ReadSnapshot { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
                -AcceptSnapshot {
                    param($candidate)
                    Test-HighContrastSnapshotEqual -Expected $restore.expected -Actual $candidate
                } `
                -Label 'High Contrast rescue restoration'
            Write-JsonUtf8Bom -Path $restore.path -Value ([ordered]@{
                schema_version = 1
                source_sha = $Verified.source_sha
                acceptance_script_sha256 = $Verified.script_sha256
                restoration_required = $false
                original = $restore.document.original
                restoration_verified = $true
                restored = [ordered]@{
                    flags = $actual.Flags
                    scheme = $actual.Scheme
                    colors_match = $true
                }
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

function Initialize-AcceptanceNative {
    if ('DarkReNamerVmAcceptanceNative' -as [type]) {
        return
    }
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DarkReNamerVmAcceptanceNative {
    private const int MaxHighContrastReads = 128;
    private static int highContrastReads;
    private static readonly IntPtr[] retainedSchemePointers = new IntPtr[MaxHighContrastReads];

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
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
    [DllImport("user32.dll")]
    private static extern uint GetSysColor(int index);
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
            HotLight = GetSysColor(26)
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
        [DarkReNamerVmAcceptanceNative]::Tap([uint16]$direction)
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
$captures = [Collections.Generic.List[object]]::new()
$keyboard = [ordered]@{
    status = 'failed'
    reset_name_enabled_after_prefix = $false
    reset_name_native_enabled_after_prefix = $false
    reset_name_menu_enabled_after_prefix = $false
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
    status = 'failed'
    visual_review = 'required'
    keyboard = $keyboard
    accessibility = $accessibility
    capture = $capture
    clipboard = $clipboard
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
            schema_version = 1
            source_sha = $verified.source_sha
            acceptance_script_sha256 = $verified.script_sha256
            restoration_required = $true
            original = [ordered]@{
                flags = $highContrastState.original.Flags
                scheme = $highContrastState.original.Scheme
                colors = [ordered]@{
                    window = $highContrastState.original.Window
                    window_text = $highContrastState.original.WindowText
                    button_face = $highContrastState.original.ButtonFace
                    button_text = $highContrastState.original.ButtonText
                    highlight = $highContrastState.original.Highlight
                    highlight_text = $highContrastState.original.HighlightText
                    gray_text = $highContrastState.original.GrayText
                    hot_light = $highContrastState.original.HotLight
                }
            }
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
    $capturePrefix = if ($HighContrast) { 'high-contrast' } else { 'current-dpi' }

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
        $captures.Add((Save-WindowScreenshot `
            -Window $mainWindow `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf ($capturePrefix + '-initial.png') `
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
            -ControlType ([Windows.Automation.ControlType]::Edit) `
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
        $captures.Add((Save-WindowScreenshot `
            -Window $fileDialog `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf ($capturePrefix + '-common-dialog.png') `
            -Label 'current-DPI common file dialog'))
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
        if ($promptEdit.Current.Name -cne '붙일 문자열') {
            throw "The prefix Edit accessible name is '$($promptEdit.Current.Name)', expected '붙일 문자열'."
        }
        $observations.prefix_prompt = [ordered]@{
            window = Get-ElementObservation -Element $prompt
            edit = Get-ElementObservation -Element $promptEdit
            ok = Get-ElementObservation -Element $promptOk
        }
        $captures.Add((Save-WindowScreenshot `
            -Window $prompt `
            -Process $process `
            -ExpectedSession $ExpectedSessionId `
            -Root $verified.output_root `
            -Leaf ($capturePrefix + '-input-prompt.png') `
            -Label 'current-DPI input prompt'))
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1004')
        Send-AcceptanceText -Process $process -ExpectedSession $ExpectedSessionId -Value $prefix -Label 'prefix keyboard input'
        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '1')
        Send-AcceptanceTap -Process $process -ExpectedSession $ExpectedSessionId -VirtualKey 0x0D -Label 'prefix prompt Enter'
        Wait-ListPreviewName -MainWindow $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -ExpectedName $destinationName -TimeoutSeconds $TimeoutSeconds
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
                row = $beforeReset
            }
            after = $null
        }
        $captures.Add((Save-WindowScreenshot -Window $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf ($capturePrefix + '-preview.png') -Label 'current-DPI rename preview before name reset'))

        [void](Move-TabFocusToId -Process $process -ExpectedSession $ExpectedSessionId -AutomationId '32781')
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
        $captures.Add((Save-WindowScreenshot -Window $mainWindow -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf ($capturePrefix + '-preview-after-name-reset.png') -Label 'current-DPI rename preview after name reset'))

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
        $captures.Add((Save-WindowScreenshot -Window $confirmation -Process $process -ExpectedSession $ExpectedSessionId -Root $verified.output_root -Leaf ($capturePrefix + '-confirmation.png') -Label 'current-DPI Apply confirmation'))
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
    if ($HighContrast -and $null -ne $highContrastState.original) {
        try {
            if ($highContrastState.changed) {
                [DarkReNamerVmAcceptanceNative]::ApplyHighContrast(
                    $highContrastState.original.Flags,
                    $highContrastState.original.Scheme
                )
            }
            $highContrastState.restored = Wait-HighContrastSettlement `
                -ReadSnapshot { [DarkReNamerVmAcceptanceNative]::GetHighContrastSnapshot() } `
                -AcceptSnapshot {
                    param($candidate)
                    Test-HighContrastSnapshotEqual `
                        -Expected $highContrastState.original `
                        -Actual $candidate
                } `
                -Label 'High Contrast restoration'
            $highContrastState.restoration_verified = $true
            $highContrastResult.restoration = 'verified'
            Write-JsonUtf8Bom -Path $highContrastState.rescue_path -Value ([ordered]@{
                schema_version = 1
                source_sha = $verified.source_sha
                acceptance_script_sha256 = $verified.script_sha256
                restoration_required = $false
                original = [ordered]@{
                    flags = $highContrastState.original.Flags
                    scheme = $highContrastState.original.Scheme
                    colors = [ordered]@{
                        window = $highContrastState.original.Window
                        window_text = $highContrastState.original.WindowText
                        button_face = $highContrastState.original.ButtonFace
                        button_text = $highContrastState.original.ButtonText
                        highlight = $highContrastState.original.Highlight
                        highlight_text = $highContrastState.original.HighlightText
                        gray_text = $highContrastState.original.GrayText
                        hot_light = $highContrastState.original.HotLight
                    }
                }
                restoration_verified = $true
                restored = [ordered]@{
                    flags = $highContrastState.restored.Flags
                    scheme = $highContrastState.restored.Scheme
                    colors_match = $true
                }
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
