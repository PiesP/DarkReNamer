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
    public static bool SetForegroundWindow(System.IntPtr window) { ForegroundCalls++; return true; }
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
    $action = switch ($VirtualKey) { 0x28 { 'down' } 0x27 { 'right' } 0x1B { 'escape' } default { throw 'Unexpected native navigation key.' } }
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
Write-Output 'UI traversal contracts passed: complete focus and native-menu functions with inert endpoints.'
