[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/paths.ps1')

# These inert types expose only the UIA/native endpoints used by the complete
# production traversal functions. They never load desktop APIs or send input.
Add-Type -TypeDefinition @'
namespace Windows.Automation {
    public sealed class AutomationElement {
        public object Current;
        public static AutomationElement FocusedElement;
        public void SetFocus() { FocusedElement = this; }
    }
    public static class ControlType { public static object Button = new object(); }
}
public static class DarkReNamerVmAcceptanceNative {
    public static int PopupCount, PopupReads;
    public static object[] ReadVisibleNativeMenuPopups(uint processId) { PopupReads++; return new object[PopupCount]; }
}
public static class DarkReNamerVmNative {
    public static int ForegroundCalls;
    public static uint ProcessId, ThreadId = 1;
    public static System.IntPtr Root = new System.IntPtr(10);
    public static string DialogClass = "#32770", FocusClass = "Button";
    public static uint GetWindowThreadProcessId(System.IntPtr window, out uint processId) { processId = ProcessId; return ThreadId; }
    public static int GetClassName(System.IntPtr window, System.Text.StringBuilder value, int capacity) {
        value.Append(window.ToInt64() == 20 ? DialogClass : FocusClass); return value.Length;
    }
    public static System.IntPtr GetAncestor(System.IntPtr window, uint flags) { return Root; }
    public static bool SetForegroundWindow(System.IntPtr window) { ForegroundCalls++; return true; }
}
public static class DarkReNamerAcceptanceNativeOpen {
    public struct Rect { public int Left, Top, Right, Bottom; }
    public static string Mode = "normal";
    public static uint ProcessId;
    public static int Reads, CurrentCommand;
    private static bool Selected(System.IntPtr window) { return window.ToInt64() == 33772; }
    public static System.IntPtr GetDlgItem(System.IntPtr parent, int command) {
        Reads++; CurrentCommand = command;
        if (command == 32772 && Mode == "missing") return System.IntPtr.Zero;
        return new System.IntPtr(command == 32772 && Mode == "duplicate" ? 33771 : command + 1000);
    }
    public static bool IsWindow(System.IntPtr window) { return !(Selected(window) && Mode == "dead"); }
    public static System.IntPtr GetParent(System.IntPtr window) { return new System.IntPtr(Selected(window) && Mode == "parent" ? 99 : 10); }
    public static int GetDlgCtrlID(System.IntPtr window) { return Mode == "duplicate" ? CurrentCommand : (int)window.ToInt64() - 1000 + (Selected(window) && Mode == "control-id" ? 1 : 0); }
    public static uint GetWindowThreadProcessId(System.IntPtr window, out uint processId) {
        processId = ProcessId + (uint)(Selected(window) && Mode == "pid" ? 1 : 0);
        return (uint)(Selected(window) && Mode == "thread" ? 0 : 1);
    }
    public static int GetClassName(System.IntPtr window, System.Text.StringBuilder value, int capacity) {
        value.Append(Selected(window) && Mode == "class" ? "Edit" : "Button"); return value.Length;
    }
    public static bool IsWindowVisible(System.IntPtr window) { return Selected(window) && Mode == "visible"; }
    public static bool IsWindowEnabled(System.IntPtr window) {
        long command = Mode == "duplicate" ? CurrentCommand : window.ToInt64() - 1000;
        return !(command == 32771 || command == 32781 || command == 32783 || command == 65535 || (Selected(window) && Mode == "enabled"));
    }
    public static bool GetWindowRect(System.IntPtr window, out Rect rect) {
        rect = new Rect { Left = 1, Top = 2, Right = Selected(window) && Mode == "bounds" ? 0 : 3, Bottom = 4 };
        return !(Selected(window) && Mode == "rect-read");
    }
}
'@
. (Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/ui-menu.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string] $Label)
    if (($Actual | ConvertTo-Json -Compress -Depth 16) -cne
        ($Expected | ConvertTo-Json -Compress -Depth 16)) { throw "$Label differs." }
}
function Assert-Fails {
    param([scriptblock] $Action, [string] $Expected)
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.ToString() -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure: $Expected"
}
function New-Element {
    param([string] $Id)
    $element = [Windows.Automation.AutomationElement]::new()
    $element.Current = [pscustomobject]@{ AutomationId = $Id; NativeWindowHandle = 10 }
    $element
}
$process = [Diagnostics.Process]::GetCurrentProcess()
$list = New-Element '1000'
$application = [pscustomobject]@{ process = $process; main = New-Element 'main'; main_handle = 10 }

# UIA observation/input adapters. Control classification and focus binding remain
# production functions, as do the traversal, exact coverage and state checks.
$leftIds = @('32771','32772','32773','32774','32775','32776','32777','32778','32779','32780')
$rightIds = @('32781','32783','65535','32784','32788','32789','32790','32785','32786')
function Reset-FocusFixture {
    param([string] $Mode = 'normal')
    $script:focus = [pscustomobject]@{
        mode = $Mode; current = $list; inputs = [Collections.Generic.List[int]]::new()
        states = 0; observations = [Collections.Generic.List[string]]::new()
        disabled = @('32771','32781','32783','65535')
    }
}
function Find-UniqueAutomationElement {
    param($Root, $Process, $ExpectedSession, $AutomationId, $ControlType, $TimeoutSeconds, $Label, [switch] $RequireWindowHandle)
    New-Element $AutomationId
}
function Get-VmAutomatedControlObservation {
    param($Element, $Process, $ExpectedSession, $Label)
    $id = [string]$Element.Current.AutomationId
    $focus.observations.Add($id)
    [ordered]@{
        automation_id = $id; control_type = if ($id -ceq '1000') { 'ControlType.List' } else { 'ControlType.Button' }
        visible = -not ($focus.mode -ceq 'hidden' -and $id -ceq '32772')
        enabled = $focus.disabled -cnotcontains $id; keyboard_focusable = $true
        bounds = [ordered]@{ left = 1; top = 1; right = 20; bottom = 20 }
        pid = $Process.Id; session_id = $ExpectedSession; root_hwnd = 10
    }
}
function Get-FocusedAcceptanceElement { param($Process, $ExpectedSession, $Label); $focus.current }
function Invoke-AcceptanceNavigationStep {
    param($Process, $ExpectedSession, $VirtualKey, $Label)
    $focus.inputs.Add([int]$VirtualKey)
    $id = [string]$focus.current.Current.AutomationId
    $left = @($leftIds | Where-Object { $focus.disabled -cnotcontains $_ })
    $right = @($rightIds | Where-Object { $focus.disabled -cnotcontains $_ })
    if ($VirtualKey -eq 0x09) {
        if ($focus.mode -ceq 'tab-bound') { return $focus.current }
        $next = if ($id -ceq '1000') { $left[0] } elseif ($left -ccontains $id) { $right[0] } else { '1000' }
    }
    elseif ($VirtualKey -eq 0x28) {
        if ($focus.mode -ceq 'cycle') { return $focus.current }
        if ($focus.mode -ceq 'foreign-rail') { $next = '1000' }
        elseif ($focus.mode -ceq 'disabled-destination') { $next = '32771' }
        else {
            $rail = if ($left -ccontains $id) { $left } else { $right }
            $next = $rail[([Array]::IndexOf($rail, $id) + 1) % $rail.Count]
        }
    }
    else { throw 'Unexpected navigation key.' }
    $focus.current = New-Element $next
    $focus.current
}
function Get-VmAutomatedFocusState {
    param($FixtureRoot, $LocalAppData)
    $focus.states++
    [ordered]@{
        fixture_entries = @([ordered]@{ relative_path = 'a.txt'; content_sha256 = if ($focus.states -eq 2 -and $focus.mode -ceq 'fixture-mutation') { 'changed' } else { 'original' } })
        journal_entries = @(if ($focus.states -eq 2 -and $focus.mode -ceq 'journal-mutation') { 'new-journal' })
    }
}
function Invoke-FocusCase {
    Invoke-VmAutomatedFocusReachability -Application $application -List $list `
        -FixtureRoot 'fixture' -ExpectedSession $process.SessionId -TimeoutSeconds 1
}
Reset-FocusFixture
$result = Invoke-FocusCase
$expectedEnabled = @('1000','32772','32773','32774','32775','32776','32777','32778','32779','32780','32784','32788','32789','32790','32785','32786')
Assert-Equal @($result.controls | Where-Object expected_reachable | ForEach-Object automation_id) $expectedEnabled 'Complete enabled controls'
Assert-Equal @($result.controls | Where-Object { -not $_.expected_reachable } | ForEach-Object exclusion_reason) @('disabled','disabled','disabled','disabled') 'Disabled exclusions'
Assert-Equal $result.final.automation_id '1000' 'Final list focus'
Assert-Equal @($result.transitions | ForEach-Object { $_.to.automation_id }) @($expectedEnabled[1..15] + '1000') 'Full ordered rail traversal'
Assert-Equal @($result.transitions | ForEach-Object input) (@('tab') + @('down') * 8 + @('tab') + @('down') * 5 + @('tab')) 'Navigation inputs'
for ($index = 0; $index -lt $result.transitions.Count; $index++) {
    Assert-Equal $result.transitions[$index].sequence ($index + 1) 'Focus receipt sequence'
    $previous = if ($index -eq 0) { $result.initial } else { $result.transitions[$index - 1].to }
    Assert-Equal $result.transitions[$index].from $previous 'Focus receipt continuity'
}
Assert-Equal $focus.states 2 'State observations'
Reset-FocusFixture
$focus.disabled = @()
$allEnabled = Invoke-FocusCase
Assert-Equal @($allEnabled.controls | Where-Object expected_reachable).Count 20 'All enabled controls'
Assert-Equal $allEnabled.final.automation_id '1000' 'All enabled traversal returns to list'
Assert-Equal @($allEnabled.transitions | ForEach-Object { $_.to.automation_id } | Sort-Object -Unique).Count 20 'All enabled controls visited'
foreach ($case in @(
    @{ mode = 'cycle'; message = 'cycled before visiting' },
    @{ mode = 'foreign-rail'; message = 'left the left rail' },
    @{ mode = 'disabled-destination'; message = 'not an enabled, visible' },
    @{ mode = 'hidden'; message = 'not visible' },
    @{ mode = 'fixture-mutation'; message = 'changed the fixture or journal' },
    @{ mode = 'journal-mutation'; message = 'changed the fixture or journal' },
    @{ mode = 'tab-bound'; message = 'did not reach the left scope' }
)) {
    Reset-FocusFixture $case.mode
    Assert-Fails { Invoke-FocusCase } $case.message
    if ($case.mode -ceq 'tab-bound') { Assert-Equal $focus.inputs.Count 32 'Tab exploration bound' }
    if ($case.mode -ceq 'hidden') { Assert-Equal $focus.inputs.Count 0 'Hidden control rejects before input' }
}

# A menu endpoint model owns the current open path and highlighted slot. The
# production function decides all input, coverage, escaping and failure policy.
$menuTree = @(
    foreach ($rootPosition in @(0,1,3)) {
        [ordered]@{ menu_path = [int[]]@(); position = $rootPosition; command_id = $null; state_flags = 0 }
    }
    foreach ($child in 0..4) {
        [ordered]@{ menu_path = [int[]]@(3); position = $child; command_id = $null; state_flags = 0 }
    }
    foreach ($spec in @(Get-VmAutomatedNativeMenuCommandSpec)) {
        [ordered]@{ menu_path = $spec.menu_path; position = $spec.position; command_id = $spec.command_id; state_flags = if ($spec.expected_enabled) { 0 } else { 3 } }
    }
)
function Reset-MenuFixture {
    param([string] $Mode = 'normal')
    $script:menu = [pscustomobject]@{
        mode = $Mode; root = -1; child = $null; position = -1; menu_bar = $false
        childDowns = 0; states = 0; endpoints = 0
        inputs = [Collections.Generic.List[string]]::new(); keys = [Collections.Generic.List[object]]::new()
        lastHighlight = $null; paths = [object[]]@()
    }
}
function Assert-AcceptanceForegroundBinding { param($Process, $ExpectedSession, $MainWindowHandle, [switch] $RequireMainWindow) }
function Get-VmAutomatedMenuEndpoint {
    param($Application, $List, $ExpectedSession)
    $menu.endpoints++
    if ($menu.root -ne -1 -or $menu.menu_bar) { throw 'Fixture endpoint retained an open menu.' }
    [ordered]@{ focused = [ordered]@{ automation_id = '1000' }; open_menu_paths = @() }
}
function Get-VmAutomatedNativeMenuState {
    param($FixtureRoot, $LocalAppData)
    $menu.states++
    [ordered]@{
        fixture_entries = @(if ($menu.states -eq 2 -and $menu.mode -ceq 'fixture-mutation') { 'changed' } else { 'original' })
        journal_entries = @(if ($menu.states -eq 2 -and $menu.mode -ceq 'journal-mutation') { 'new-journal' })
    }
}
function Invoke-MenuEndpointInput {
    param([string] $KeyAction)
    $menu.inputs.Add($KeyAction)
    [DarkReNamerVmAcceptanceNative]::PopupReads = 0
    $highlight = $null
    switch ($KeyAction) {
        { $_ -like 'alt-*' } {
            if ($menu.root -ne -1 -or $menu.menu_bar) { throw 'Previous menu session was not closed.' }
            $menu.root = switch ($KeyAction) { 'alt-f' { 0 } 'alt-e' { 1 } 'alt-t' { 3 } }
            $menu.position = if ($menu.root -eq 1) { 5 } else { 0 }
        }
        'down' {
            if ($null -ne $menu.child) {
                $menu.childDowns++
                $rows = @($menuTree | Where-Object { $_.menu_path.Count -eq 2 -and $_.menu_path[1] -eq $menu.child } | Sort-Object position)
                if ($menu.mode -ceq 'down-no-progress') { }
                elseif ($menu.mode -ceq 'missing-command') { $menu.position = $menu.childDowns % 2 }
                elseif ($menu.mode -ceq 'event-bound' -and $rows.Count -eq 3 -and $menu.childDowns -lt 30) { $menu.position = $menu.childDowns % 2 }
                else { $menu.position = ($menu.position + 1) % $rows.Count }
            }
            elseif ($menu.root -eq 3) {
                if ($menu.mode -ceq 'submenu-bound') { $menu.position = if ($menu.position -eq 0) { 2 } else { 0 } }
                else { $menu.position = ($menu.position + 1) % 5 }
            }
            else { throw 'Unexpected root Down.' }
        }
        'right' {
            $menu.child = $menu.position; $menu.position = 0; $menu.childDowns = 0
        }
        'left' {
            if ($null -eq $menu.child) { throw 'Fixture Left requires an open submenu.' }
            $menu.position = $menu.child; $menu.child = $null
        }
        'escape' {
            if ($null -ne $menu.child) { $menu.position = $menu.child; $menu.child = $null }
            elseif ($menu.root -ne -1) {
                $menu.position = $menu.root; $menu.root = -1; $menu.menu_bar = $true
                if ($menu.mode -ceq 'escape-root') { $menu.position = 99 }
            }
            elseif ($menu.mode -cne 'escape-bar') { $menu.menu_bar = $false }
        }
        default { throw "Unexpected menu action $KeyAction" }
    }
    $actualPaths = @(
        if ($menu.root -ne -1) {
            ,([int[]]@($menu.root))
            if ($null -ne $menu.child) { ,([int[]]@($menu.root, $menu.child)) }
        }
    )
    $menu.paths = $actualPaths
    [DarkReNamerVmAcceptanceNative]::PopupCount = $actualPaths.Count
    if ($menu.mode -ceq 'popup-mismatch') { [DarkReNamerVmAcceptanceNative]::PopupCount++ }
    $path = [int[]]@()
    if (-not $menu.menu_bar) {
        $path = if ($null -ne $menu.child) { [int[]]@($menu.root,$menu.child) } else { [int[]]@($menu.root) }
    }
    if ($menu.menu_bar -or ($menu.root -ne -1 -and $menu.root -ne 0)) {
        $row = @($menuTree | Where-Object { (Test-VmAutomatedMenuPathEqual $_.menu_path $path) -and $_.position -eq $menu.position })
        # An intentionally foreign Escape slot reaches the production rejection,
        # while keeping highlight identity checking independently exercised.
        if ($menu.mode -ceq 'escape-root' -and $menu.menu_bar) {
            $highlight = [ordered]@{ menu_path = [int[]]@(); position = 1; command_id = $null; state_flags = 0x80 }
        }
        else {
            if ($row.Count -ne 1) { throw 'Fixture highlight is ambiguous.' }
            $highlight = [ordered]@{ menu_path = $path; position = $row[0].position; command_id = $row[0].command_id; state_flags = $row[0].state_flags -bor 0x80 }
        }
        if ($menu.mode -ceq 'wrong-binding') { $highlight.command_id = 999 }
    }
    $menu.lastHighlight = $highlight
}
function Send-AcceptanceChord {
    param($Process, $ExpectedSession, $Modifier, $VirtualKey, $Label)
    $menu.keys.Add([int[]]@($Modifier, $VirtualKey))
    if ($Modifier -ne 0x12) { throw 'Expected native Alt accelerator.' }
    $action = switch ($VirtualKey) { 0x46 { 'alt-f' } 0x45 { 'alt-e' } 0x54 { 'alt-t' } default { throw 'Unexpected accelerator.' } }
    Invoke-MenuEndpointInput $action
}
function Send-AcceptanceTap {
    param($Process, $ExpectedSession, $VirtualKey, $Label)
    $menu.keys.Add([int[]]@($VirtualKey))
    $action = switch ($VirtualKey) { 0x28 { 'down' } 0x27 { 'right' } 0x25 { 'left' } 0x1B { 'escape' } default { throw 'Unexpected native navigation key.' } }
    Invoke-MenuEndpointInput $action
}
function Get-VmAutomatedVisibleMenuPopups {
    param($Process, $ExpectedSession, $OpenMenuPaths, $PathHandles)
    Assert-Equal $OpenMenuPaths $menu.paths 'Requested native popup paths'
    @($menu.paths | ForEach-Object { [ordered]@{ menu_path = $_ } })
}
function Get-VmAutomatedMenuHighlight {
    param($MainWindowHandle, $OpenMenuPaths, $Popups)
    $menu.lastHighlight
}
function Get-ForegroundObservation {
    [ordered]@{ hwnd = if ($menu.mode -ceq 'foreground-loss') { 99 } else { 10 }; process_id = $process.Id; session_id = $process.SessionId; window_class = 'DarkReNamerWindow' }
}
function Start-Sleep { param($Milliseconds) }

function Invoke-MenuCase {
    Invoke-VmAutomatedNativeMenuOnlyReachability -Application $application -List $list `
        -FixtureRoot 'fixture' -ExpectedSession $process.SessionId -MenuTree $menuTree
}
Reset-MenuFixture
$result = Invoke-MenuCase
Assert-Equal @($result.events | Where-Object { $_.input -like 'alt-*' } | ForEach-Object input) @('alt-f','alt-e','alt-t','alt-t','alt-t','alt-t','alt-t') 'Root accelerators'
Assert-Equal @($result.events | Where-Object { $_.input -ceq 'right' }).Count 5 'Transform submenus'
Assert-Equal @($result.events | Where-Object { $_.input -ceq 'escape' }).Count 19 'Popup and menu-bar Escape'
$visitedCommands = @($result.events | Where-Object { $null -ne $_.highlighted -and $null -ne $_.highlighted.command_id } | ForEach-Object { $_.highlighted.command_id } | Sort-Object -Unique)
Assert-Equal $visitedCommands @(32772,32773,32774,32775,32776,32777,32778,32779,32780,32784,32785,32786,32788,32789,32790) 'Exact 15 enabled commands'
for ($index = 0; $index -lt $result.events.Count; $index++) { Assert-Equal $result.events[$index].sequence ($index + 1) 'Menu receipt sequence' }
Assert-Equal $menu.endpoints 2 'Initial and final list endpoints'
for ($index = 0; $index -lt $result.events.Count; $index++) {
    Assert-Equal $result.events[$index].virtual_keys $menu.keys[$index] 'Actual native input and receipt keys'
}
Assert-Equal @($result.events | Where-Object { $_.input -like 'alt-*' } | ForEach-Object { ,($_.virtual_keys) }) @([int[]]@(18,70),[int[]]@(18,69),[int[]]@(18,84),[int[]]@(18,84),[int[]]@(18,84),[int[]]@(18,84),[int[]]@(18,84)) 'Native accelerator keys'
Assert-Equal $menu.states 2 'Menu state observations'
# Left is a supported low-level input even though the complete coverage flow
# closes submenus with Escape. Execute that remaining native key branch too.
Reset-MenuFixture
$rootPaths = [object[]]@(,([int[]]@(3)))
$childPaths = [object[]]@(,([int[]]@(3)); ,([int[]]@(3,0)))
$handles = @{}
$opened = Invoke-VmAutomatedMenuKey -Application $application -ExpectedSession $process.SessionId `
    -KeyAction 'alt-t' -OpenMenuPaths $rootPaths -PathHandles $handles -Sequence 1
$childOpened = Invoke-VmAutomatedMenuKey -Application $application -ExpectedSession $process.SessionId `
    -KeyAction 'right' -OpenMenuPaths $childPaths -PathHandles $handles -PreviousHighlight $opened.highlighted -Sequence 2
$leftClosed = Invoke-VmAutomatedMenuKey -Application $application -ExpectedSession $process.SessionId `
    -KeyAction 'left' -OpenMenuPaths $rootPaths -PathHandles $handles -PreviousHighlight $childOpened.highlighted -Sequence 3
Assert-Equal $leftClosed.virtual_keys @(0x25) 'Native Left key'
Assert-Equal $leftClosed.highlighted.menu_path @(3) 'Left returns to parent menu'
foreach ($case in @(
    @{ mode = 'missing-command'; message = 'missed enabled commands' },
    @{ mode = 'submenu-bound'; message = 'not reached by bounded Down' },
    @{ mode = 'event-bound'; message = 'event count exceeds its bound' },
    @{ mode = 'escape-root'; message = 'exact menu-bar item' },
    @{ mode = 'escape-bar'; message = 'second Escape' },
    @{ mode = 'wrong-binding'; message = 'immutable menu tree' },
    @{ mode = 'foreground-loss'; message = 'lost the exact candidate foreground' },
    @{ mode = 'popup-mismatch'; message = 'expected popup state' },
    @{ mode = 'down-no-progress'; message = 'expected popup state' },
    @{ mode = 'fixture-mutation'; message = 'changed the fixture or journal' },
    @{ mode = 'journal-mutation'; message = 'changed the fixture or journal' }
)) {
    Reset-MenuFixture $case.mode
    Assert-Fails { Invoke-MenuCase } $case.message
    if ($case.mode -in @('popup-mismatch','down-no-progress')) { Assert-Equal ([DarkReNamerVmAcceptanceNative]::PopupReads) 40 'Native popup polling bound' }
    if ($case.mode -ceq 'event-bound') { Assert-Equal $menu.inputs.Count 128 'Total keyboard event bound' }
    if ($case.mode -ceq 'missing-command') { Assert-Equal @($menu.inputs | Where-Object { $_ -ceq 'down' }).Count 32 'Command Down bound' }
}

# Raw keyboard events retain the real focused-element process/session check.
& {
    . (Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/ui-menu.ps1')
    function Assert-AutomationBinding { param($Element, $Process, $ExpectedSession, $Label, [switch] $RequireWindowHandle) }
    function Get-Date { $keyboard.clock = $keyboard.clock.AddSeconds(2); $keyboard.clock }
    function Start-Sleep { param($Milliseconds) }
    function Get-ForegroundObservation { $keyboard.foreground }
    foreach ($action in @('escape','enter')) {
        $expectedId = if ($action -ceq 'escape') { 'CommandButton_2' } else { 'CommandLink_1101' }
        foreach ($case in @('normal','target-pid','target-thread','target-class','focused-pid','focused-class','focused-id','focused-type','root','foreground-hwnd','foreground-pid','foreground-session','foreground-class')) {
            $confirmation = New-Element 'confirmation'; $confirmation.Current.NativeWindowHandle = 20
            $button = New-Element $expectedId; $button.Current.NativeWindowHandle = 21
            $button.Current | Add-Member NoteProperty ProcessId $process.Id
            $button.Current | Add-Member NoteProperty ControlType ([pscustomobject]@{ ProgrammaticName = 'ControlType.Button' })
            $button.SetFocus()
            [DarkReNamerVmNative]::ProcessId = $process.Id; [DarkReNamerVmNative]::ThreadId = 1
            [DarkReNamerVmNative]::Root = [IntPtr]20
            [DarkReNamerVmNative]::DialogClass = '#32770'; [DarkReNamerVmNative]::FocusClass = 'Button'
            $keyboard = @{ clock = [DateTime]::UtcNow; foreground = [ordered]@{ hwnd = 20; process_id = $process.Id; session_id = $process.SessionId; window_class = '#32770' } }
            switch ($case) {
                'target-pid' { [DarkReNamerVmNative]::ProcessId++ }
                'target-thread' { [DarkReNamerVmNative]::ThreadId = 0 }
                'target-class' { [DarkReNamerVmNative]::DialogClass = 'other' }
                'focused-pid' { $button.Current.ProcessId++ }
                'focused-class' { [DarkReNamerVmNative]::FocusClass = 'Edit' }
                'focused-id' { $button.Current.AutomationId = 'wrong' }
                'focused-type' { $button.Current.ControlType.ProgrammaticName = 'ControlType.Edit' }
                'root' { [DarkReNamerVmNative]::Root = [IntPtr]99 }
                'foreground-hwnd' { $keyboard.foreground.hwnd = 10 }
                'foreground-pid' { $keyboard.foreground.process_id++ }
                'foreground-session' { $keyboard.foreground.session_id++ }
                'foreground-class' { $keyboard.foreground.window_class = 'other' }
            }
            $arguments = @{ Action = $action; Confirmation = $confirmation; Process = $process; ExpectedSession = $process.SessionId; ExpectedAutomationId = $expectedId; TimeoutSeconds = 1 }
            if ($case -cne 'normal') {
                $message = if ($case -ceq 'target-thread') { 'target process is unavailable' } elseif ($case -ceq 'focused-pid') { 'expected application and desktop session' } else { 'target or focus binding is invalid' }
                Assert-Fails { Get-VmAutomatedKeyboardEventStart @arguments } $message
                continue
            }
            $event = Get-VmAutomatedKeyboardEventStart @arguments
            Assert-Equal $event.action $action 'Keyboard event action'
            Assert-Equal $event.input_method 'keyboard' 'Keyboard event method'
            Assert-Equal $event.target ([ordered]@{ hwnd = 20L; pid = $process.Id; session_id = $process.SessionId; class = '#32770' }) 'Keyboard target observation'
            Assert-Equal $event.focused_before ([ordered]@{ hwnd = 21L; pid = $process.Id; session_id = $process.SessionId; class = 'Button'; automation_id = $expectedId; control_type = 'ControlType.Button'; root_hwnd = 20L }) 'Keyboard focused observation'
            Assert-Equal $event.foreground_before $keyboard.foreground 'Keyboard foreground observation'
            Assert-Equal $event.foreground_after $null 'Unfinished keyboard event'
            $keyboard.foreground = [ordered]@{ hwnd = 10; process_id = $process.Id; session_id = $process.SessionId; window_class = 'DarkReNamerWindow' }
            Complete-VmAutomatedKeyboardEvent -Event $event -Process $process -ExpectedSession $process.SessionId -MainWindowHandle ([IntPtr]10) -TimeoutSeconds 1
            Assert-Equal $event.foreground_after $keyboard.foreground 'Completed keyboard foreground observation'
            foreach ($field in @('hwnd','process_id','session_id','window_class')) {
                $bad = [ordered]@{ hwnd = 10; process_id = $process.Id; session_id = $process.SessionId; window_class = 'DarkReNamerWindow' }
                $bad[$field] = if ($field -ceq 'window_class') { 'other' } else { [int]$bad[$field] + 1 }
                $keyboard.foreground = $bad
                Assert-Fails { Complete-VmAutomatedKeyboardEvent -Event $event -Process $process -ExpectedSession $process.SessionId -MainWindowHandle ([IntPtr]10) -TimeoutSeconds 1 } 'did not return foreground ownership'
                Assert-Equal $event.foreground_after $bad 'Failed completion preserves final observation'
            }
        }
    }
}

# A complete fixed menu tree is independent of the native HWND observations.
# Separators fill unused positions; the production validator owns all validity
# and command-state decisions before the actual hidden-rail producer runs.
$validMenuTree = [Collections.Generic.List[object]]::new()
function Add-MenuFixtureRow {
    param([int[]] $Path, [int] $Position, [string] $Type, $Command = $null, [bool] $Enabled = $true)
    $validMenuTree.Add([ordered]@{
        menu_path = $Path; position = $Position; item_type = $Type; command_id = $Command
        state_flags = if ($Enabled) { 0 } else { 3 }; enabled = $Enabled; checked = $false
    })
}
foreach ($root in 0..3) { Add-MenuFixtureRow @() $root 'submenu' }
foreach ($child in 0..4) { Add-MenuFixtureRow @(3) $child 'submenu' }
foreach ($spec in @(Get-VmAutomatedNativeMenuCommandSpec)) {
    Add-MenuFixtureRow $spec.menu_path $spec.position 'command' $spec.command_id $spec.expected_enabled
}
foreach ($position in @(0,1)) { Add-MenuFixtureRow @(0) $position 'separator' }
foreach ($position in @(2,3,4,6)) { Add-MenuFixtureRow @(1) $position 'separator' }
Add-MenuFixtureRow @(2) 0 'separator'
[void](Assert-VmAutomatedNativeMenuTree -MenuTree $validMenuTree.ToArray())
function Initialize-AcceptanceNativeOpen { }
[DarkReNamerVmNative]::Root = [IntPtr]10
[DarkReNamerAcceptanceNativeOpen]::ProcessId = $process.Id
$rails = @(Get-VmAutomatedHiddenRailControls -Application $application -ExpectedSession $process.SessionId -MenuTree $validMenuTree.ToArray())
Assert-Equal $rails.Count 19 'Complete hidden rail inventory'
Assert-Equal @($rails | ForEach-Object command_id) @(32771,32772,32773,32774,32775,32776,32777,32778,32779,32780,32781,32783,65535,32784,32788,32789,32790,32785,32786) 'Hidden rail command identities'
Assert-Equal $rails[1] ([ordered]@{
    command_id = 32772; hwnd = 33772L; control_id = 32772; window_class = 'Button'; visible = $false; enabled = $true
    pid = $process.Id; session_id = $process.SessionId; parent_hwnd = 10L; root_hwnd = 10L
    rect = [ordered]@{ left = 1; top = 2; right = 3; bottom = 4 }
}) 'Complete hidden rail observation'
Assert-Equal @($rails | Where-Object { -not $_.enabled }).Count 4 'Hidden disabled menu commands'
foreach ($case in @('missing','dead','duplicate','parent','control-id','pid','thread','class','visible','enabled','bounds','rect-read','root','session')) {
    [DarkReNamerAcceptanceNativeOpen]::Mode = $case
    [DarkReNamerAcceptanceNativeOpen]::Reads = 0
    [DarkReNamerVmNative]::Root = if ($case -ceq 'root') { [IntPtr]99 } else { [IntPtr]10 }
    $session = if ($case -ceq 'session') { $process.SessionId + 1 } else { $process.SessionId }
    $message = if ($case -cin @('root','session')) { 'workbench ownership is invalid' } elseif ($case -cin @('pid','thread')) { 'another process' } elseif ($case -cin @('class','visible')) { 'class or visibility' } elseif ($case -ceq 'enabled') { 'enabled state differs' } elseif ($case -cin @('bounds','rect-read')) { 'bounds are invalid' } else { 'missing, misbound, or duplicated' }
    Assert-Fails { Get-VmAutomatedHiddenRailControls -Application $application -ExpectedSession $session -MenuTree $validMenuTree.ToArray() } $message
    if ($case -cin @('root','session')) { Assert-Equal ([DarkReNamerAcceptanceNativeOpen]::Reads) 0 'Ownership rejection precedes hidden HWND reads' }
}
[DarkReNamerAcceptanceNativeOpen]::Mode = 'normal'; [DarkReNamerVmNative]::Root = [IntPtr]10
[DarkReNamerAcceptanceNativeOpen]::Reads = 0
$incompleteTree = @($validMenuTree.ToArray() | Where-Object { $_.command_id -ne 32786 })
Assert-Fails { Get-VmAutomatedHiddenRailControls -Application $application -ExpectedSession $process.SessionId -MenuTree $incompleteTree } 'command 32786 path or enabled state differs'
Assert-Equal ([DarkReNamerAcceptanceNativeOpen]::Reads) 0 'Incomplete menu rejects before hidden HWND reads'

# Layout producers run against the already exercised complete traversal functions.
# Platform environment and appearance observations are boundary canaries here;
# the Windows environment reader retains its registry/CIM/WinRT runtime gate.
& {
    . (Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/ui-current-dpi.ps1')
    . (Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/ui-application.ps1')
    function Get-VmAutomatedAppearance {
        param($Window, $Process, $ExpectedSession)
        if ($Window -ne $application.main -or $Process -ne $process -or $ExpectedSession -ne $process.SessionId) { throw 'Layout appearance observation lost its pinned window.' }
        $layoutProbe.appearanceCalls++
        [ordered]@{ hwnd = 10; pid = $process.Id; session_id = $process.SessionId; menu_checked = @('appearance-canary') }
    }
    function Get-VmAutomatedEnvironment {
        param($Process, $WindowHandle, $FixtureRoot)
        if ($Process -ne $process -or $WindowHandle -ne [IntPtr]10 -or $FixtureRoot -cne 'fixture') { throw 'Layout environment observation lost its bound input.' }
        $layoutProbe.environmentCalls++
        [ordered]@{ schema_version = 1; target_display = [ordered]@{ hwnd = 10; dpi_x = 144; text_scale_percent = 150 }; fixture_volume = [ordered]@{ root_identity = 'environment-canary' } }
    }
    function Get-VmAutomatedNativeMenuTree {
        param($MainWindowHandle)
        if ($MainWindowHandle -ne [IntPtr]10) { throw 'Layout native tree read lost its pinned window.' }
        $validMenuTree.ToArray()
    }
    $application | Add-Member NoteProperty owned ([pscustomobject]@{ process_start_time_utc_ticks = '639000000000000201' })
    $application | Add-Member NoteProperty process_lifecycle $null
    $grid = [pscustomobject]@{ element = $list }
    $menuTree = $validMenuTree.ToArray()
    foreach ($variant in @('command-rails','native-menu-only')) {
        Reset-FocusFixture; Reset-MenuFixture
        $layoutProbe = @{ environmentCalls = 0; appearanceCalls = 0 }
        $application.process_lifecycle = New-AcceptanceProcessLifecycle -Application $application -ApplicationPath 'candidate.exe' -ExecutableSha256 ('d' * 64)
        $run = New-VmAutomatedLayoutRun -Application $application -ApplicationPath 'candidate.exe' -FixtureRoot 'fixture' -Grid $grid -ExpectedSession $process.SessionId -TimeoutSeconds 1 -LayoutVariant $variant
        Assert-Equal $layoutProbe.environmentCalls 1 'Layout environment read count'
        Assert-Equal $layoutProbe.appearanceCalls 1 'Layout appearance read count'
        Assert-Equal $run.raw_environment.fixture_volume.root_identity 'environment-canary' 'Layout environment projection'
        Assert-Equal $run.raw_environment.target_display ([ordered]@{ hwnd = 10; dpi_x = 144; text_scale_percent = 150 }) 'Layout target display projection'
        Assert-Equal $run.raw_appearance.menu_checked @('appearance-canary') 'Layout appearance projection'
        Assert-Equal $run.process_lifecycle ([ordered]@{
            pid = $process.Id; session_id = $process.SessionId; start_time_utc_ticks = '639000000000000201'
            executable_path = 'candidate.exe'; executable_sha256 = 'd' * 64; start_observed = $true
            exit_observed = $false; exit_method = $null; exit_code = $null
        }) 'Layout lifecycle projection'
        Assert-Equal $run.layout_observations.screenshots.Count 0 'Pending layout screenshots'
        Assert-Equal $run.layout_observations.focus[0].automation_id '1000' 'Layout focused file list'
        if ($variant -ceq 'command-rails') {
            Assert-Equal $run.layout_observations.controls.Count 21 'Layout main/list/nineteen rails'
            Assert-Equal $run.layout_observations.focus_reachability.final.automation_id '1000' 'Layout full focus traversal projection'
            Assert-Equal $run.layout_observations.Contains('native_menu_only') $false 'Command rail layout variant'
        }
        else {
            Assert-Equal $run.layout_observations.controls.Count 2 'Menu-only main/list controls'
            $native = $run.layout_observations.native_menu_only
            Assert-Equal $native.variant 'native-menu-only' 'Layout native variant'
            Assert-Equal $native.hidden_rail_controls $rails 'Layout full hidden control projection'
            Assert-Equal $native.menu_tree $menuTree 'Layout immutable menu tree projection'
            Assert-Equal $native.events.Count $menu.inputs.Count 'Layout native keyboard traversal projection'
            Assert-Equal @($native.events | Where-Object { $null -ne $_.highlighted -and $null -ne $_.highlighted.command_id } | ForEach-Object { $_.highlighted.command_id } | Sort-Object -Unique).Count 15 'Layout native enabled command receipts'
            Assert-Equal $native.state_before $native.state_after 'Layout unchanged native traversal state'
            Assert-Equal $run.layout_observations.Contains('focus_reachability') $false 'Menu-only layout variant'
        }
        foreach ($code in @(0,1)) {
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
            $start.UseShellExecute = $false
            foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-Command',"exit $code")) { $start.ArgumentList.Add($argument) }
            $child = [Diagnostics.Process]::Start($start)
            try {
                if (-not $child.WaitForExit(15000)) { throw 'Owned layout fixture child did not exit.' }
                $screenshots = @([ordered]@{ image = 'layout.png'; sha256 = 'e' * 64 })
                if ($code -eq 0) {
                    Assert-Fails { Complete-VmAutomatedLayoutRun -Run $run -Process $child -ExitCode 1 -Screenshots $screenshots } 'normal zero exit'
                    Complete-VmAutomatedLayoutRun -Run $run -Process $child -ExitCode 0 -Screenshots $screenshots
                    Assert-Equal $run.process_lifecycle.exit_observed $true 'Completed layout lifecycle observation'
                    Assert-Equal $run.process_lifecycle.exit_method 'normal-close' 'Completed layout lifecycle method'
                    Assert-Equal $run.process_lifecycle.exit_code 0 'Completed layout exit'
                    Assert-Equal $run.layout_observations.screenshots $screenshots 'Completed layout captures'
                }
                else {
                    $before = $run | ConvertTo-Json -Compress -Depth 20
                    foreach ($reportedExit in @(0,1)) {
                        Assert-Fails { Complete-VmAutomatedLayoutRun -Run $run -Process $child -ExitCode $reportedExit -Screenshots $screenshots } 'normal zero exit'
                    }
                    Assert-Equal ($run | ConvertTo-Json -Compress -Depth 20) $before 'Rejected layout completion preserves run'
                }
            }
            finally {
                if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
                $child.Dispose()
            }
        }
    }
    # A live child is blocked on its owned input pipe until this test releases it.
    # Completion must reject it before reading ExitCode or publishing success.
    $pending = [ordered]@{ process_lifecycle = [ordered]@{ exit_observed = $false; exit_method = $null; exit_code = $null }; layout_observations = [ordered]@{ screenshots = @() } }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $start.UseShellExecute = $false; $start.RedirectStandardInput = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-Command','[Console]::ReadLine() | Out-Null; exit 0')) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($start)
    try {
        Assert-Fails { Complete-VmAutomatedLayoutRun -Run $pending -Process $child -ExitCode 0 -Screenshots @([ordered]@{ image = 'pending.png' }) } 'normal zero exit'
        Assert-Equal $pending.process_lifecycle.exit_observed $false 'Live layout did not publish exit'
        Assert-Equal $pending.layout_observations.screenshots.Count 0 'Live layout did not publish captures'
    }
    finally {
        $child.StandardInput.WriteLine('finish'); $child.StandardInput.Close()
        if (-not $child.WaitForExit(15000)) { $child.Kill(); $child.WaitForExit() }
        $child.Dispose()
    }
    # Ownership must be checked before either expensive traversal or OS metadata.
    function Get-VmAutomatedControlObservation {
        param($Element, $Process, $ExpectedSession, $Label)
        $corrupt = ($layoutProbe.target -ceq 'focus' -and $Label -ceq 'raw layout focused control') -or
            ($layoutProbe.target -ceq 'control' -and $Label -ceq 'raw layout main workbench')
        [ordered]@{
            automation_id = $Element.Current.AutomationId
            pid = if ($corrupt -and $layoutProbe.badField -ceq 'pid') { $Process.Id + 1 } else { $Process.Id }
            session_id = if ($corrupt -and $layoutProbe.badField -ceq 'session_id') { $ExpectedSession + 1 } else { $ExpectedSession }
            root_hwnd = if ($corrupt -and $layoutProbe.badField -ceq 'root_hwnd') { 99 } else { 10 }
        }
    }
    foreach ($target in @('focus','control')) {
        foreach ($field in @('pid','session_id','root_hwnd')) {
            foreach ($variant in @('command-rails','native-menu-only')) {
                Reset-FocusFixture; Reset-MenuFixture
                $layoutProbe = @{ target = $target; badField = $field; environmentCalls = 0; appearanceCalls = 0 }
                Assert-Fails { New-VmAutomatedLayoutRun -Application $application -ApplicationPath 'candidate.exe' -FixtureRoot 'fixture' -Grid $grid -ExpectedSession $process.SessionId -TimeoutSeconds 1 -LayoutVariant $variant } 'control or focus ownership differs'
                Assert-Equal $focus.inputs.Count 0 'Misbound layout did not navigate controls'
                Assert-Equal $menu.inputs.Count 0 'Misbound layout did not navigate menus'
                Assert-Equal $layoutProbe.environmentCalls 0 'Misbound layout did not read environment'
            }
        }
    }
}
Write-Output 'UI traversal and raw producer contracts passed with inert desktop endpoints.'
