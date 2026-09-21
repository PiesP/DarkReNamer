function Initialize-AcceptanceRecoveryMenuNative {
    if ('DarkReNamerRecoveryMenuNative' -as [type]) {
        return
    }
    Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class DarkReNamerRecoveryMenuNative {
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    public sealed class KeyboardResult {
        public uint RequestedCount { get; set; }
        public uint SentCount { get; set; }
        public int ErrorCode { get; set; }
        public uint ReleaseSentCount { get; set; }
    }

    public sealed class PopupObservation {
        public long Handle { get; set; }
        public uint ProcessId { get; set; }
        public string ClassName { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Right { get; set; }
        public int Bottom { get; set; }
    }

    public sealed class PopupInventory {
        public int TotalCount { get; set; }
        public PopupObservation[] Entries { get; set; }
    }

    public sealed class RecoveryMenuItemObservation {
        public int RootPosition { get; set; }
        public int Position { get; set; }
        public string ItemType { get; set; }
        public int? CommandId { get; set; }
        public uint StateFlags { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Right { get; set; }
        public int Bottom { get; set; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MENUITEMINFO {
        public uint Size;
        public uint Mask;
        public uint Type;
        public uint State;
        public uint Id;
        public IntPtr SubMenu;
        public IntPtr CheckedBitmap;
        public IntPtr UncheckedBitmap;
        public UIntPtr ItemData;
        public IntPtr TypeData;
        public uint TextLength;
        public IntPtr ItemBitmap;
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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")]
    private static extern IntPtr GetMenu(IntPtr window);
    [DllImport("user32.dll")]
    private static extern IntPtr GetSubMenu(IntPtr menu, int position);
    [DllImport("user32.dll")]
    private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")]
    private static extern uint GetMenuState(IntPtr menu, uint item, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetMenuItemInfoW(
        IntPtr menu, uint item, bool byPosition, ref MENUITEMINFO information);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetMenuItemRect(
        IntPtr window, IntPtr menu, uint item, out RECT rect);

    private static INPUT Key(ushort virtualKey, uint flags) {
        return new INPUT {
            type = 1,
            value = new INPUTUNION {
                keyboard = new KEYBDINPUT {
                    virtualKey = virtualKey,
                    scanCode = 0,
                    flags = flags,
                    time = 0,
                    extraInfo = UIntPtr.Zero
                }
            }
        };
    }

    public static KeyboardResult SendKeyTap(ushort virtualKey) {
        INPUT[] inputs = new [] { Key(virtualKey, 0), Key(virtualKey, 2) };
        uint sent = SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
        int error = sent == 2 ? 0 : Marshal.GetLastWin32Error();
        uint released = 0;
        if (sent != 2) {
            released = SendInput(1, new [] { Key(virtualKey, 2) }, Marshal.SizeOf(typeof(INPUT)));
        }
        return new KeyboardResult {
            RequestedCount = 2,
            SentCount = sent,
            ErrorCode = error,
            ReleaseSentCount = released
        };
    }

    public static KeyboardResult SendAltR() {
        INPUT[] inputs = new [] {
            Key(0x12, 0), Key(0x52, 0), Key(0x52, 2), Key(0x12, 2)
        };
        uint sent = SendInput(4, inputs, Marshal.SizeOf(typeof(INPUT)));
        int error = sent == 4 ? 0 : Marshal.GetLastWin32Error();
        uint released = 0;
        if (sent != 4) {
            INPUT[] releases = sent <= 2
                ? new [] { Key(0x52, 2), Key(0x12, 2) }
                : new [] { Key(0x12, 2) };
            released = SendInput((uint)releases.Length, releases, Marshal.SizeOf(typeof(INPUT)));
        }
        return new KeyboardResult {
            RequestedCount = 4,
            SentCount = sent,
            ErrorCode = error,
            ReleaseSentCount = released
        };
    }

    public static PopupInventory ReadVisiblePopups(uint expectedProcessId) {
        List<PopupObservation> entries = new List<PopupObservation>(2);
        int totalCount = 0;
        int rectError = 0;
        bool completed = EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            if (!IsWindowVisible(window)) { return true; }
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) { return true; }
            StringBuilder className = new StringBuilder(32);
            if (GetClassName(window, className, className.Capacity) <= 0 ||
                !String.Equals(className.ToString(), "#32768", StringComparison.Ordinal)) {
                return true;
            }
            totalCount++;
            if (totalCount <= 2) {
                RECT rect;
                if (!GetWindowRect(window, out rect)) {
                    if (rectError == 0) { rectError = Marshal.GetLastWin32Error(); }
                    return true;
                }
                entries.Add(new PopupObservation {
                    Handle = window.ToInt64(),
                    ProcessId = processId,
                    ClassName = className.ToString(),
                    Left = rect.Left,
                    Top = rect.Top,
                    Right = rect.Right,
                    Bottom = rect.Bottom
                });
            }
            return true;
        }, IntPtr.Zero);
        if (!completed) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (rectError != 0) {
            throw new Win32Exception(rectError);
        }
        entries.Sort(delegate(PopupObservation left, PopupObservation right) {
            return left.Handle.CompareTo(right.Handle);
        });
        return new PopupInventory {
            TotalCount = totalCount,
            Entries = entries.ToArray()
        };
    }

    public static RecoveryMenuItemObservation[] ReadRecoveryMenuItems(IntPtr window) {
        const int recoveryRootPosition = 4;
        IntPtr root = GetMenu(window);
        if (root == IntPtr.Zero || GetMenuItemCount(root) != 6) {
            throw new InvalidOperationException("The application menu bar is not the exact six-item tree.");
        }
        IntPtr recovery = GetSubMenu(root, recoveryRootPosition);
        if (recovery == IntPtr.Zero || GetMenuItemCount(recovery) != 4) {
            throw new InvalidOperationException("The recovery menu is not the exact four-item subtree.");
        }
        List<RecoveryMenuItemObservation> rows = new List<RecoveryMenuItemObservation>(4);
        for (int position = 0; position < 4; position++) {
            uint state = GetMenuState(recovery, (uint)position, 0x400);
            if (state == UInt32.MaxValue) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            MENUITEMINFO information = new MENUITEMINFO {
                Size = (uint)Marshal.SizeOf(typeof(MENUITEMINFO)),
                Mask = 0x00000107
            };
            if (!GetMenuItemInfoW(recovery, (uint)position, true, ref information)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            bool separator = (information.Type & 0x800) != 0;
            bool submenu = information.SubMenu != IntPtr.Zero;
            RECT rect;
            if (!GetMenuItemRect(IntPtr.Zero, recovery, (uint)position, out rect)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            rows.Add(new RecoveryMenuItemObservation {
                RootPosition = recoveryRootPosition,
                Position = position,
                ItemType = separator ? "separator" : submenu ? "submenu" : "command",
                CommandId = separator || submenu ? (int?)null : checked((int)information.Id),
                StateFlags = state & 0xFF,
                Left = rect.Left,
                Top = rect.Top,
                Right = rect.Right,
                Bottom = rect.Bottom
            });
        }
        return rows.ToArray();
    }
}
'@
}
function Initialize-AcceptanceRecoveryWindowNative {
    if ('DarkReNamerRecoveryWindowNative' -as [type]) {
        return
    }
    Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class DarkReNamerRecoveryWindowNative {
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    public sealed class NamedWindowObservation {
        public long Handle { get; set; }
        public long OwnerHandle { get; set; }
        public uint ProcessId { get; set; }
        public uint SessionId { get; set; }
        public string Title { get; set; }
        public string ClassName { get; set; }
        public bool Visible { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Right { get; set; }
        public int Bottom { get; set; }
    }

    public sealed class NamedWindowInventory {
        public int TotalCount { get; set; }
        public NamedWindowObservation[] Entries { get; set; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLengthW(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out RECT rect);

    public static NamedWindowInventory ReadOwnedNamedWindows(
        uint expectedProcessId,
        uint expectedSessionId,
        IntPtr expectedOwner,
        string expectedTitle
    ) {
        if (expectedProcessId == 0 || expectedOwner == IntPtr.Zero || !IsWindow(expectedOwner)) {
            throw new ArgumentException("The recovery-window owner binding is invalid.");
        }
        if (String.IsNullOrEmpty(expectedTitle) || expectedTitle.Length > 256) {
            throw new ArgumentException("The recovery-window title is invalid.");
        }
        List<NamedWindowObservation> entries = new List<NamedWindowObservation>(2);
        int totalCount = 0;
        int visitedCount = 0;
        int nativeError = 0;
        bool overflow = false;
        bool completed = EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            visitedCount++;
            if (visitedCount > 256) {
                overflow = true;
                return false;
            }
            bool visible = IsWindowVisible(window);
            if (!visible) { return true; }
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) { return true; }
            uint sessionId;
            if (!ProcessIdToSessionId(processId, out sessionId)) {
                nativeError = Marshal.GetLastWin32Error();
                return false;
            }
            IntPtr owner = GetWindow(window, 4);
            if (sessionId != expectedSessionId || owner != expectedOwner) {
                return true;
            }
            StringBuilder className = new StringBuilder(32);
            if (GetClassName(window, className, className.Capacity) <= 0 ||
                !String.Equals(className.ToString(), "#32770", StringComparison.Ordinal)) {
                return true;
            }
            int titleLength = GetWindowTextLengthW(window);
            if (titleLength <= 0 || titleLength > 256) { return true; }
            StringBuilder title = new StringBuilder(titleLength + 1);
            if (GetWindowTextW(window, title, title.Capacity) != titleLength ||
                !String.Equals(title.ToString(), expectedTitle, StringComparison.Ordinal)) {
                return true;
            }
            totalCount++;
            if (totalCount <= 2) {
                RECT rect;
                if (!GetWindowRect(window, out rect)) {
                    nativeError = Marshal.GetLastWin32Error();
                    return false;
                }
                entries.Add(new NamedWindowObservation {
                    Handle = window.ToInt64(),
                    OwnerHandle = owner.ToInt64(),
                    ProcessId = processId,
                    SessionId = sessionId,
                    Title = title.ToString(),
                    ClassName = className.ToString(),
                    Visible = visible,
                    Left = rect.Left,
                    Top = rect.Top,
                    Right = rect.Right,
                    Bottom = rect.Bottom
                });
            }
            return true;
        }, IntPtr.Zero);
        if (overflow) {
            throw new InvalidOperationException("Recovery-window enumeration exceeded 256 top-level windows.");
        }
        if (nativeError != 0) {
            throw new Win32Exception(nativeError);
        }
        if (!completed) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        entries.Sort(delegate(NamedWindowObservation left, NamedWindowObservation right) {
            return left.Handle.CompareTo(right.Handle);
        });
        return new NamedWindowInventory {
            TotalCount = totalCount,
            Entries = entries.ToArray()
        };
    }
}
'@
}
function ConvertTo-AcceptanceRecoveryWindowObservation {
    param(
        [Parameter(Mandatory)][object] $Inventory,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][long] $ExpectedOwnerHandle,
        [Parameter(Mandatory)][string] $ExpectedName
    )

    if ($Inventory.TotalCount -gt 1) {
        throw 'Recovery window matched more than one exact native candidate.'
    }
    if ($Inventory.TotalCount -eq 0) {
        return $null
    }
    if ($Inventory.TotalCount -ne 1) {
        throw 'Recovery window native inventory returned an invalid count.'
    }
    $rows = @($Inventory.Entries)
    if ($rows.Count -ne 1) {
        throw 'Recovery window native inventory is internally inconsistent.'
    }
    $row = $rows[0]
    if ($row.Handle -le 0 -or $row.OwnerHandle -ne $ExpectedOwnerHandle -or
        $row.ProcessId -ne $ExpectedProcessId -or $row.SessionId -ne $ExpectedSession -or
        $row.Title -cne $ExpectedName -or $row.ClassName -cne '#32770' -or
        -not $row.Visible -or $row.Right -le $row.Left -or $row.Bottom -le $row.Top -or
        ($row.Right - $row.Left) -gt 32768 -or ($row.Bottom - $row.Top) -gt 32768 -or
        ([long]($row.Right - $row.Left) * [long]($row.Bottom - $row.Top)) -gt 100000000L) {
        throw 'Recovery window changed its exact native identity or geometry.'
    }
    [ordered]@{
        hwnd = [long]$row.Handle
        owner_hwnd = [long]$row.OwnerHandle
        process_id = [int]$row.ProcessId
        session_id = [int]$row.SessionId
        window_class = $row.ClassName
        visible = [bool]$row.Visible
        rect = [ordered]@{
            left = [int]$row.Left
            top = [int]$row.Top
            right = [int]$row.Right
            bottom = [int]$row.Bottom
        }
    }
}
function Write-AcceptanceRecoveryWindowProgress {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)]
        [ValidateSet('startup-default-cancel', 'recovery-relaunch',
            'recovery-export-relaunch', 'startup-recovery-invoke',
            'startup-recovery-cancel', 'recovery-completion',
            'recovery-export-folder-picker', 'recovery-export-completion',
            'intent-startup-notice', 'intent-relaunch-notice',
            'intent-discard-notice', 'intent-discard-cancel',
            'intent-discard-confirm', 'intent-discard-completion')]
        [string] $Purpose,
        [Parameter(Mandatory)]
        [ValidateSet('native-window-found', 'uia-window-bound')]
        [string] $Phase,
        [AllowNull()][object] $Observation
    )

    Assert-AcceptanceProcessBinding -Application $Application
    Write-AcceptanceNewUtf8Json `
        -Path (Join-Path $PrivateRoot ('recovery-window-' + $Purpose + '-' + $Phase + '.json')) `
        -Value ([ordered]@{
            schema_version = 1
            phase = $Phase
            purpose = $Purpose
            observed_utc_ticks = [DateTime]::UtcNow.Ticks.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            binding = $Application.raw_process_binding
            observation = $Observation
        })
}
function Remove-AcceptanceRecoveryWindowProgress {
    param([Parameter(Mandatory)][string] $PrivateRoot)

    $purposes = @(
        'startup-default-cancel', 'recovery-relaunch',
        'recovery-export-relaunch', 'startup-recovery-invoke',
        'startup-recovery-cancel', 'recovery-completion',
        'recovery-export-folder-picker', 'recovery-export-completion',
        'intent-startup-notice', 'intent-relaunch-notice',
        'intent-discard-notice', 'intent-discard-cancel',
        'intent-discard-confirm', 'intent-discard-completion'
    )
    $phases = @('native-window-found', 'uia-window-bound')
    $ownedPaths = [Collections.Generic.List[string]]::new()
    foreach ($purpose in $purposes) {
        $purposePaths = [Collections.Generic.List[string]]::new()
        foreach ($phase in $phases) {
            $path = Join-Path $PrivateRoot (
                'recovery-window-' + $purpose + '-' + $phase + '.json'
            )
            if (-not (Test-Path -LiteralPath $path)) {
                continue
            }
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'A recovery-window progress path is not one owned ordinary file.'
            }
            $purposePaths.Add($path)
        }
        if ($purposePaths.Count -notin @(0, 2)) {
            throw 'Recovery-window progress has an incomplete phase pair.'
        }
        foreach ($path in $purposePaths) {
            $ownedPaths.Add($path)
        }
    }
    foreach ($path in $ownedPaths) {
        Remove-Item -LiteralPath $path
        if (Test-Path -LiteralPath $path) {
            throw 'Recovery-window progress cleanup was incomplete.'
        }
    }
}
function Wait-AcceptanceRecoveryWindow {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Purpose
    )

    Assert-AcceptanceProcessBinding -Application $Application
    $process = $Application.owned.process
    $process.Refresh()
    if ($process.HasExited -or $process.SessionId -ne $ExpectedSession) {
        throw "$Label process is unavailable in the expected desktop session."
    }
    Assert-AutomationBinding `
        -Element $Application.main -Process $process -ExpectedSession $ExpectedSession `
        -Label "$Label owner" -RequireWindowHandle
    $ownerHandle = [IntPtr]$Application.main.Current.NativeWindowHandle
    Initialize-AcceptanceRecoveryWindowNative
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    $native = $null
    do {
        $inventory = [DarkReNamerRecoveryWindowNative]::ReadOwnedNamedWindows(
            [uint32]$process.Id,
            [uint32]$ExpectedSession,
            $ownerHandle,
            $Name
        )
        $native = ConvertTo-AcceptanceRecoveryWindowObservation `
            -Inventory $inventory -ExpectedProcessId $process.Id `
            -ExpectedSession $ExpectedSession -ExpectedOwnerHandle $ownerHandle.ToInt64() `
            -ExpectedName $Name
        if ($null -ne $native) {
            break
        }
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited -or $process.SessionId -ne $ExpectedSession) {
            throw "$Label was not found before the bound process left the expected session."
        }
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $native) {
        throw "$Label was not found before the bounded native deadline."
    }
    Write-AcceptanceRecoveryWindowProgress `
        -PrivateRoot $PrivateRoot -Application $Application -Purpose $Purpose `
        -Phase 'native-window-found' -Observation $native
    $window = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$native.hwnd)
    if ($null -eq $window) {
        throw "$Label exact native window is unavailable through UI Automation."
    }
    $freshInventory = [DarkReNamerRecoveryWindowNative]::ReadOwnedNamedWindows(
        [uint32]$process.Id,
        [uint32]$ExpectedSession,
        $ownerHandle,
        $Name
    )
    $fresh = ConvertTo-AcceptanceRecoveryWindowObservation `
        -Inventory $freshInventory -ExpectedProcessId $process.Id `
        -ExpectedSession $ExpectedSession -ExpectedOwnerHandle $ownerHandle.ToInt64() `
        -ExpectedName $Name
    if ($null -eq $fresh -or $fresh.hwnd -ne $native.hwnd) {
        throw "$Label changed during exact native-to-UIA binding."
    }
    Assert-AcceptanceRetainedWindowBinding `
        -Window $window -Process $process -ExpectedSession $ExpectedSession `
        -ExpectedName $Name -Label $Label
    if ([long]$window.Current.NativeWindowHandle -ne $fresh.hwnd) {
        throw "$Label UI Automation materialized a different native window."
    }
    Write-AcceptanceRecoveryWindowProgress `
        -PrivateRoot $PrivateRoot -Application $Application -Purpose $Purpose `
        -Phase 'uia-window-bound' -Observation $fresh
    $window
}
function Write-AcceptanceExportProgress {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)]
        [ValidateSet('before-startup-cancel', 'after-startup-cancel', 'before-menu-popup',
            'popup-found', 'menu-item-found', 'invoke-started', 'picker-found', 'picker-filled')]
        [string] $Phase,
        [ValidateSet('export', 'discard-cancel', 'discard-confirm')]
        [string] $Purpose
    )

    Assert-AcceptanceProcessBinding -Application $Application
    $leaf = if ([string]::IsNullOrEmpty($Purpose)) {
        'export-progress-' + $Phase + '.json'
    }
    else {
        'export-progress-' + $Purpose + '-' + $Phase + '.json'
    }
    $value = if ([string]::IsNullOrEmpty($Purpose)) {
        [ordered]@{
            schema_version = 1
            phase = $Phase
            observed_utc_ticks = [DateTime]::UtcNow.Ticks.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            binding = $Application.raw_process_binding
        }
    }
    else {
        [ordered]@{
            schema_version = 1
            phase = $Phase
            purpose = $Purpose
            observed_utc_ticks = [DateTime]::UtcNow.Ticks.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            binding = $Application.raw_process_binding
        }
    }
    Write-AcceptanceNewUtf8Json `
        -Path (Join-Path $PrivateRoot $leaf) `
        -Value $value
}
function Write-AcceptanceRecoveryMenuProgress {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)]
        [ValidateSet('export', 'discard-cancel', 'discard-confirm')]
        [string] $Purpose,
        [Parameter(Mandatory)]
        [ValidateSet('input-returned', 'native-popup-found', 'native-menu-bound',
            'navigation-1', 'navigation-2', 'navigation-3', 'navigation-4',
            'native-command-highlighted', 'native-enter-returned')]
        [string] $Phase,
        [Parameter(Mandatory)][object] $Observation
    )

    Assert-AcceptanceProcessBinding -Application $Application
    Write-AcceptanceNewUtf8Json `
        -Path (Join-Path $PrivateRoot ('recovery-menu-' + $Purpose + '-' + $Phase + '.json')) `
        -Value ([ordered]@{
            schema_version = 1
            phase = $Phase
            purpose = $Purpose
            observed_utc_ticks = [DateTime]::UtcNow.Ticks.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            binding = $Application.raw_process_binding
            observation = $Observation
        })
}
function Remove-AcceptanceRecoveryMenuProgress {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)]
        [ValidateSet('export', 'discard-cancel', 'discard-confirm')]
        [string] $Purpose
    )

    foreach ($phase in @('before-menu-popup', 'popup-found', 'menu-item-found',
            'invoke-started')) {
        Remove-Item -LiteralPath (Join-Path $PrivateRoot (
                'export-progress-' + $Purpose + '-' + $phase + '.json'
            ))
    }
    foreach ($phase in @('input-returned', 'native-popup-found', 'native-menu-bound',
            'native-command-highlighted', 'native-enter-returned')) {
        Remove-Item -LiteralPath (Join-Path $PrivateRoot (
                'recovery-menu-' + $Purpose + '-' + $phase + '.json'
            ))
    }
    foreach ($phase in @('navigation-1', 'navigation-2', 'navigation-3', 'navigation-4')) {
        $optionalPath = Join-Path $PrivateRoot (
            'recovery-menu-' + $Purpose + '-' + $phase + '.json'
        )
        if (Test-Path -LiteralPath $optionalPath -PathType Leaf) {
            Remove-Item -LiteralPath $optionalPath
        }
    }
}
function Remove-AcceptanceExportProgress {
    param([Parameter(Mandatory)][string] $PrivateRoot)

    foreach ($phase in @('before-startup-cancel', 'after-startup-cancel',
            'picker-found', 'picker-filled')) {
        Remove-Item -LiteralPath (Join-Path $PrivateRoot ('export-progress-' + $phase + '.json'))
    }
    Remove-AcceptanceRecoveryMenuProgress -PrivateRoot $PrivateRoot -Purpose 'export'
}
function ConvertTo-AcceptanceRecoveryMenuObservation {
    param(
        [Parameter(Mandatory)][object] $Inventory,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $ActualSession
    )

    if ($ActualSession -ne $ExpectedSession) {
        throw 'The recovery menu candidate process is in an unexpected desktop session.'
    }
    if ($Inventory.TotalCount -gt 1) {
        throw 'Recovery menu matched more than one candidate popup.'
    }
    if ($Inventory.TotalCount -eq 0) {
        return $null
    }
    if ($Inventory.TotalCount -ne 1) {
        throw 'Recovery menu native inventory returned an invalid count.'
    }
    $rows = @($Inventory.Entries)
    if ($rows.Count -ne 1) {
        throw 'Recovery menu native inventory is internally inconsistent.'
    }
    $row = $rows[0]
    if ($row.Handle -le 0 -or $row.ProcessId -ne $ExpectedProcessId -or
        $row.ClassName -cne '#32768' -or
        $row.Right -le $row.Left -or $row.Bottom -le $row.Top) {
        throw 'Recovery menu popup changed its native identity or geometry.'
    }
    [ordered]@{
        hwnd = [long]$row.Handle
        process_id = [int]$row.ProcessId
        session_id = [int]$ExpectedSession
        window_class = $row.ClassName
        visible = $true
        rect = [ordered]@{
            left = [int]$row.Left
            top = [int]$row.Top
            right = [int]$row.Right
            bottom = [int]$row.Bottom
        }
    }
}
function ConvertTo-AcceptanceRecoveryMenuState {
    param(
        [Parameter(Mandatory)][object[]] $Rows,
        [Parameter(Mandatory)][int] $TargetCommandId,
        [Parameter(Mandatory)][int] $TargetPosition,
        [Parameter(Mandatory)][object] $Popup,
        [switch] $RequireHighlight
    )

    if (($TargetCommandId -ne 0x9000 -or $TargetPosition -ne 1) -and
        ($TargetCommandId -ne 0x9001 -or $TargetPosition -ne 3)) {
        throw 'Recovery menu target command and position are invalid.'
    }
    if ($Popup.hwnd -le 0 -or $Popup.window_class -cne '#32768' -or
        -not $Popup.visible -or $Popup.rect.right -le $Popup.rect.left -or
        $Popup.rect.bottom -le $Popup.rect.top) {
        throw 'Recovery menu popup binding is invalid.'
    }
    $expectedTypes = @('command', 'command', 'separator', 'command')
    $expectedCommands = @(0x9002, 0x9000, $null, 0x9001)
    if ($Rows.Count -ne 4) {
        throw 'Recovery menu must contain exactly four native rows.'
    }
    $normalized = [Collections.Generic.List[object]]::new()
    $highlights = [Collections.Generic.List[object]]::new()
    for ($position = 0; $position -lt 4; $position++) {
        $matches = @($Rows | Where-Object { $_.Position -eq $position })
        if ($matches.Count -ne 1) {
            throw 'Recovery menu positions are missing or duplicated.'
        }
        $row = $matches[0]
        $commandId = if ($null -eq $row.CommandId) { $null } else { [int]$row.CommandId }
        if ($row.RootPosition -ne 4 -or $row.Position -ne $position -or
            $row.ItemType -cne $expectedTypes[$position] -or
            (($null -eq $expectedCommands[$position]) -ne ($null -eq $commandId)) -or
            ($null -ne $commandId -and $commandId -ne $expectedCommands[$position]) -or
            $row.StateFlags -lt 0 -or $row.StateFlags -gt 255 -or
            $row.Right -le $row.Left -or $row.Bottom -le $row.Top -or
            $row.Left -lt $Popup.rect.left -or $row.Top -lt $Popup.rect.top -or
            $row.Right -gt $Popup.rect.right -or $row.Bottom -gt $Popup.rect.bottom) {
            throw 'Recovery menu row identity, state, or geometry is invalid.'
        }
        $enabled = ([int]$row.StateFlags -band 0x3) -eq 0
        $item = [ordered]@{
            root_position = 4
            position = $position
            item_type = [string]$row.ItemType
            command_id = $commandId
            state_flags = [int]$row.StateFlags
            enabled = $enabled
            rect = [ordered]@{
                left = [int]$row.Left; top = [int]$row.Top
                right = [int]$row.Right; bottom = [int]$row.Bottom
            }
        }
        $normalized.Add($item)
        if (($item.state_flags -band 0x80) -ne 0) {
            $highlights.Add($item)
        }
    }
    if ($highlights.Count -gt 1) {
        throw 'Recovery menu has more than one native highlighted row.'
    }
    $highlight = if ($highlights.Count -eq 1) { $highlights[0] } else { $null }
    if ($null -ne $highlight -and
        ($highlight.item_type -cne 'command' -or -not $highlight.enabled)) {
        throw 'Recovery menu highlighted a separator, submenu, or disabled command.'
    }
    if ($RequireHighlight -and $null -eq $highlight) {
        throw 'Recovery menu has no native highlighted command.'
    }
    $target = $normalized[$TargetPosition]
    if ($target.command_id -ne $TargetCommandId -or -not $target.enabled) {
        throw 'Recovery menu target command is missing or disabled.'
    }
    [ordered]@{
        popup = $Popup
        rows = $normalized.ToArray()
        target = $target
        highlighted = $highlight
    }
}
function Get-AcceptanceRecoveryMenuState {
    param(
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][object] $Popup,
        [Parameter(Mandatory)][int] $TargetCommandId,
        [Parameter(Mandatory)][int] $TargetPosition,
        [switch] $RequireHighlight
    )

    $rows = @([DarkReNamerRecoveryMenuNative]::ReadRecoveryMenuItems($MainWindowHandle))
    ConvertTo-AcceptanceRecoveryMenuState `
        -Rows $rows `
        -TargetCommandId $TargetCommandId `
        -TargetPosition $TargetPosition `
        -Popup $Popup `
        -RequireHighlight:$RequireHighlight
}
function Wait-AcceptanceRecoveryMenuHighlightChange {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][object] $Popup,
        [Parameter(Mandatory)][int] $TargetCommandId,
        [Parameter(Mandatory)][int] $TargetPosition,
        [AllowNull()][object] $PreviousHighlight
    )

    $deadline = (Get-Date).AddSeconds(2)
    do {
        $inventory = [DarkReNamerRecoveryMenuNative]::ReadVisiblePopups([uint32]$Process.Id)
        $currentPopup = ConvertTo-AcceptanceRecoveryMenuObservation `
            -Inventory $inventory -ExpectedProcessId $Process.Id `
            -ExpectedSession $ExpectedSession -ActualSession $Process.SessionId
        if ($null -eq $currentPopup -or $currentPopup.hwnd -ne $Popup.hwnd) {
            throw 'Recovery menu popup changed while navigating its commands.'
        }
        $state = Get-AcceptanceRecoveryMenuState `
            -MainWindowHandle $MainWindowHandle -Popup $currentPopup `
            -TargetCommandId $TargetCommandId -TargetPosition $TargetPosition
        if ($null -ne $state.highlighted -and
            ($null -eq $PreviousHighlight -or
                $state.highlighted.position -ne $PreviousHighlight.position -or
                $state.highlighted.command_id -ne $PreviousHighlight.command_id)) {
            return $state
        }
        Start-Sleep -Milliseconds 50
        $Process.Refresh()
        if ($Process.HasExited -or $Process.SessionId -ne $ExpectedSession) {
            throw 'The candidate changed process state during recovery menu navigation.'
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Recovery menu highlight did not change before the bounded deadline.'
}
function Wait-AcceptanceRecoveryMenuClosed {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][long] $ExpectedPopupHandle,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [scriptblock] $ReadInventory = {
            param([uint32] $ExpectedProcessId)
            [DarkReNamerRecoveryMenuNative]::ReadVisiblePopups($ExpectedProcessId)
        }
    )

    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $inventory = & $ReadInventory ([uint32]$Process.Id)
        $Process.Refresh()
        if ($Process.HasExited -or $Process.SessionId -ne $ExpectedSession) {
            throw 'The candidate changed process state before its recovery menu closed.'
        }
        if ($inventory.TotalCount -eq 0) { return }
        if ($inventory.TotalCount -ne 1) {
            throw 'Recovery menu activation left an ambiguous native popup inventory.'
        }
        $entries = @($inventory.Entries)
        if ($entries.Count -ne 1 -or $entries[0].Handle -ne $ExpectedPopupHandle) {
            throw 'Recovery menu activation replaced the exact native popup.'
        }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    throw 'Recovery menu popup did not close before the bounded deadline.'
}
function Wait-AcceptanceRecoveryMenuPopup {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    Initialize-AcceptanceRecoveryMenuNative
    $Process.Refresh()
    if ($Process.HasExited) {
        throw 'The candidate exited before its recovery menu appeared.'
    }
    if ($Process.SessionId -ne $ExpectedSession) {
        throw 'The recovery menu candidate process is in an unexpected desktop session.'
    }
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $inventory = [DarkReNamerRecoveryMenuNative]::ReadVisiblePopups([uint32]$Process.Id)
        $observation = ConvertTo-AcceptanceRecoveryMenuObservation `
            -Inventory $inventory `
            -ExpectedProcessId $Process.Id `
            -ExpectedSession $ExpectedSession `
            -ActualSession $Process.SessionId
        if ($null -ne $observation) {
            return $observation
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) { throw 'The candidate exited before its recovery menu appeared.' }
        if ($Process.SessionId -ne $ExpectedSession) {
            throw 'The recovery menu candidate process changed desktop session.'
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Recovery menu popup was not found before the bounded deadline.'
}
function Assert-AcceptanceRecoveryMenuForegroundObservation {
    param(
        [Parameter(Mandatory)][object] $Observation,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][string] $Label
    )

    if ($Observation.hwnd -ne [long]$MainWindowHandle -or
        $Observation.process_id -ne $ExpectedProcessId -or
        $Observation.session_id -ne $ExpectedSession -or
        $Observation.window_class -cne 'DarkReNamerWindow') {
        throw "The verified application foreground binding changed before $Label."
    }
}
function Get-AcceptanceRecoveryMenuForeground {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][string] $Label
    )

    $foreground = Get-ForegroundObservation
    Assert-AcceptanceRecoveryMenuForegroundObservation `
        -Observation $foreground -ExpectedProcessId $Process.Id `
        -ExpectedSession $ExpectedSession -MainWindowHandle $MainWindowHandle -Label $Label
    $foreground
}
function Start-AcceptanceRecoveryMenuInvoke {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $ItemName,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)]
        [ValidateSet('export', 'discard-cancel', 'discard-confirm')]
        [string] $Purpose
    )

    $process = $Application.owned.process
    $main = $Application.main
    $main.SetFocus()
    $mainHandle = [IntPtr]$main.Current.NativeWindowHandle
    [void][DarkReNamerVmNative]::SetForegroundWindow($mainHandle)
    $deadline = (Get-Date).AddSeconds(5)
    while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle -and
        (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle) {
        throw "The verified application is not foreground for $Label."
    }
    $targetSpec = switch ($Purpose) {
        'export' {
            [ordered]@{
                command_id = 0x9000
                position = 1
                item_name = '복구 데이터 내보내기...'
            }
        }
        { $_ -in @('discard-cancel', 'discard-confirm') } {
            [ordered]@{
                command_id = 0x9001
                position = 3
                item_name = '시작되지 않은 작업 기록 삭제...'
            }
        }
    }
    if ($null -eq $targetSpec -or $ItemName -cne $targetSpec.item_name) {
        throw 'Recovery menu purpose and source-bound item name differ.'
    }
    $foregroundBefore = Get-AcceptanceRecoveryMenuForeground `
        -Process $process -ExpectedSession $SessionId `
        -MainWindowHandle $mainHandle -Label $Label
    Write-AcceptanceExportProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'before-menu-popup'
    Initialize-AcceptanceRecoveryMenuNative
    $inputResult = [DarkReNamerRecoveryMenuNative]::SendAltR()
    $foregroundAfter = Get-ForegroundObservation
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot `
        -Application $Application `
        -Purpose $Purpose `
        -Phase 'input-returned' `
        -Observation ([ordered]@{
            input_method = 'native-sendinput'
            virtual_keys = [int[]]@(0x12, 0x52)
            requested_event_count = [int]$inputResult.RequestedCount
            sent_event_count = [int]$inputResult.SentCount
            win32_error = [int]$inputResult.ErrorCode
            release_sent_count = [int]$inputResult.ReleaseSentCount
            foreground_before = $foregroundBefore
            foreground_after = $foregroundAfter
        })
    if ($inputResult.RequestedCount -ne 4 -or $inputResult.SentCount -ne 4) {
        throw "Native recovery-menu input was incomplete (sent $($inputResult.SentCount) of 4, error $($inputResult.ErrorCode))."
    }
    Assert-AcceptanceRecoveryMenuForegroundObservation `
        -Observation $foregroundAfter -ExpectedProcessId $process.Id `
        -ExpectedSession $SessionId -MainWindowHandle $mainHandle -Label "$Label Alt+R return"
    $nativePopup = Wait-AcceptanceRecoveryMenuPopup `
        -Process $process -ExpectedSession $SessionId -TimeoutSeconds $WaitSeconds
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'native-popup-found' -Observation $nativePopup
    $menuState = Get-AcceptanceRecoveryMenuState `
        -MainWindowHandle $mainHandle -Popup $nativePopup `
        -TargetCommandId $targetSpec.command_id -TargetPosition $targetSpec.position
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot `
        -Application $Application `
        -Purpose $Purpose `
        -Phase 'native-menu-bound' `
        -Observation ([ordered]@{
            popup = $nativePopup
            rows = $menuState.rows
            target = $menuState.target
            highlighted = $menuState.highlighted
        })
    Write-AcceptanceExportProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'popup-found'

    $navigationCount = 0
    while ($null -eq $menuState.highlighted -or
        $menuState.highlighted.command_id -ne $targetSpec.command_id) {
        if ($navigationCount -ge 4) {
            throw 'Recovery menu keyboard navigation did not reach the exact target command.'
        }
        $navigationCount++
        $downBefore = Get-AcceptanceRecoveryMenuForeground `
            -Process $process -ExpectedSession $SessionId `
            -MainWindowHandle $mainHandle -Label "$Label Down $navigationCount"
        $downResult = [DarkReNamerRecoveryMenuNative]::SendKeyTap([uint16]0x28)
        $downAfter = Get-ForegroundObservation
        Write-AcceptanceRecoveryMenuProgress `
            -PrivateRoot $PrivateRoot -Application $Application `
            -Purpose $Purpose -Phase ('navigation-' + $navigationCount) `
            -Observation ([ordered]@{
                input_method = 'native-sendinput'
                virtual_keys = [int[]]@(0x28)
                requested_event_count = [int]$downResult.RequestedCount
                sent_event_count = [int]$downResult.SentCount
                win32_error = [int]$downResult.ErrorCode
                release_sent_count = [int]$downResult.ReleaseSentCount
                foreground_before = $downBefore
                foreground_after = $downAfter
            })
        if ($downResult.RequestedCount -ne 2 -or $downResult.SentCount -ne 2) {
            throw "Recovery menu Down input $navigationCount was incomplete."
        }
        Assert-AcceptanceRecoveryMenuForegroundObservation `
            -Observation $downAfter -ExpectedProcessId $process.Id `
            -ExpectedSession $SessionId -MainWindowHandle $mainHandle `
            -Label "$Label Down $navigationCount return"
        $previousHighlight = $menuState.highlighted
        $menuState = Wait-AcceptanceRecoveryMenuHighlightChange `
            -Process $process -ExpectedSession $SessionId `
            -MainWindowHandle $mainHandle -Popup $nativePopup `
            -TargetCommandId $targetSpec.command_id -TargetPosition $targetSpec.position `
            -PreviousHighlight $previousHighlight
    }
    $menuState = Get-AcceptanceRecoveryMenuState `
        -MainWindowHandle $mainHandle -Popup $nativePopup `
        -TargetCommandId $targetSpec.command_id -TargetPosition $targetSpec.position `
        -RequireHighlight
    if ($menuState.highlighted.command_id -ne $targetSpec.command_id -or
        $menuState.highlighted.position -ne $targetSpec.position) {
        throw 'Recovery menu native highlight is not the exact target command.'
    }
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'native-command-highlighted' `
        -Observation ([ordered]@{
            popup = $nativePopup
            target = $menuState.target
            highlighted = $menuState.highlighted
            down_input_count = $navigationCount
        })
    Write-AcceptanceExportProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'menu-item-found'

    $enterBefore = Get-AcceptanceRecoveryMenuForeground `
        -Process $process -ExpectedSession $SessionId `
        -MainWindowHandle $mainHandle -Label "$Label Enter"
    $popupInventory = [DarkReNamerRecoveryMenuNative]::ReadVisiblePopups([uint32]$process.Id)
    $enterPopup = ConvertTo-AcceptanceRecoveryMenuObservation `
        -Inventory $popupInventory -ExpectedProcessId $process.Id `
        -ExpectedSession $SessionId -ActualSession $process.SessionId
    if ($null -eq $enterPopup -or $enterPopup.hwnd -ne $nativePopup.hwnd) {
        throw 'Recovery menu popup changed before exact target activation.'
    }
    $enterState = Get-AcceptanceRecoveryMenuState `
        -MainWindowHandle $mainHandle -Popup $enterPopup `
        -TargetCommandId $targetSpec.command_id -TargetPosition $targetSpec.position `
        -RequireHighlight
    if ($enterState.highlighted.command_id -ne $targetSpec.command_id -or
        $enterState.highlighted.position -ne $targetSpec.position) {
        throw 'Recovery menu highlight changed before exact target activation.'
    }
    $enterResult = [DarkReNamerRecoveryMenuNative]::SendKeyTap([uint16]0x0D)
    $enterAfter = Get-ForegroundObservation
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'native-enter-returned' `
        -Observation ([ordered]@{
            input_method = 'native-sendinput'
            virtual_keys = [int[]]@(0x0D)
            requested_event_count = [int]$enterResult.RequestedCount
            sent_event_count = [int]$enterResult.SentCount
            win32_error = [int]$enterResult.ErrorCode
            release_sent_count = [int]$enterResult.ReleaseSentCount
            foreground_before = $enterBefore
            foreground_after = $enterAfter
            target = $enterState.target
            highlighted = $enterState.highlighted
        })
    if ($enterResult.RequestedCount -ne 2 -or $enterResult.SentCount -ne 2) {
        throw 'Recovery menu Enter input was incomplete.'
    }
    if ($enterAfter.process_id -ne $process.Id -or $enterAfter.session_id -ne $SessionId) {
        throw 'Recovery menu activation changed foreground to another process or session.'
    }
    Wait-AcceptanceRecoveryMenuClosed `
        -Process $process -ExpectedSession $SessionId `
        -ExpectedPopupHandle $nativePopup.hwnd -TimeoutSeconds $WaitSeconds
    Write-AcceptanceExportProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'invoke-started'
    [pscustomobject][ordered]@{
        input = 'native-keyboard-down-enter'
        target_command_id = [int]$targetSpec.command_id
        target_position = [int]$targetSpec.position
        down_input_count = $navigationCount
        enter_sent = $true
        popup_closed = $true
    }
}
