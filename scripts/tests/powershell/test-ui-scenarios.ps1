[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/windows-vm-module-loader.ps1')
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind ui)) { . $definition }
function Assert-Equal {
    param($Actual, $Expected, [string] $Label)
    if ($Actual -cne $Expected) { throw "$Label expected <$Expected>, observed <$Actual>." }
}
function Assert-Fails {
    param([scriptblock] $Action, [string] $Expected)
    try { & $Action }
    catch { if ($_.Exception.ToString() -notlike "*$Expected*") { throw }; return }
    throw "Expected failure: $Expected"
}

# All platform endpoints are inert. Production PowerShell functions execute
# intact against these type-compatible UIA/native adapters in this subprocess.
Add-Type @'
using System;
using System.Collections.Generic;
public static class DarkReNamerVmAcceptanceNative {
    public static List<string> Calls = new List<string>();
    public static Queue<object> Snapshots = new Queue<object>();
    public static uint DisabledCommand;
    public static string InputFailure = "", Cleanup = "cleared";
    public static bool IsMenuCommandChecked(IntPtr window, uint command) {
        Calls.Add("checked:" + window + ":" + command); return command == 0x9011;
    }
    public static bool IsMenuCommandEnabled(IntPtr window, uint command) {
        Calls.Add("enabled:" + command); return command != DisabledCommand;
    }
    public static void Tap(ushort key) { Calls.Add("tap:" + key); if (InputFailure == "tap") throw new Exception("fixture tap failure"); }
    public static object ReadClipboardSnapshot() { Calls.Add("clipboard-read"); return Snapshots.Dequeue(); }
    public static string ClearClipboardIfOwned(uint sequence, string text) {
        Calls.Add("clear:" + sequence + ":" + text);
        if (Cleanup == "error") throw new Exception("fixture guarded cleanup failure"); return Cleanup;
    }
    public static void ReleaseModifiers() {}
    public static void ReleaseObserverClipboard() {}
    public static void ReleaseAllButtons() {}
    public static string OsVersion() { return "fixture OS"; }
}
public static class DarkReNamerVmNative {
    public static IntPtr GetForegroundWindow() { DarkReNamerVmAcceptanceNative.Calls.Add("foreground-read"); return new IntPtr(101); }
    public static bool SetForegroundWindow(IntPtr window) { DarkReNamerVmAcceptanceNative.Calls.Add("foreground:" + window); return true; }
}
namespace Windows.Automation {
    public class AutomationProperty {}
    public static class ControlType { public static string Button = "Button", Edit = "Edit", DataGrid = "DataGrid"; }
    public static class TreeScope { public static string Descendants = "Descendants"; }
    public class PropertyCondition { public PropertyCondition(object property, object value) {} }
    public class GridPattern { public static string Pattern = "grid"; }
    public class InvokePattern {
        public static string Pattern = "invoke";
        public void Invoke() { DarkReNamerVmAcceptanceNative.Calls.Add("invoke-names"); }
    }
    public class SelectionPattern {
        public static string Pattern = "selection";
        public class Information { public int Count; public object[] GetSelection() {
            DarkReNamerVmAcceptanceNative.Calls.Add("selection-read"); return new object[Count];
        } }
        public Information Current = new Information();
    }
    public class AutomationElement {
        public static object ControlTypeProperty = new object();
        public class Information { public int NativeWindowHandle = 101; public string Name = "fixture"; }
        public Information Current = new Information();
        public bool PatternAvailable = true;
        public object PatternValue = new GridPattern();
        public AutomationElement[] Children = new AutomationElement[0];
        public void SetFocus() { DarkReNamerVmAcceptanceNative.Calls.Add("focus:" + Current.NativeWindowHandle); }
        public bool TryGetCurrentPattern(object pattern, out object value) {
            DarkReNamerVmAcceptanceNative.Calls.Add("pattern:" + pattern); value = PatternValue; return PatternAvailable;
        }
        public AutomationElement[] FindAll(object scope, object condition) { return Children; }
    }
}
namespace UIAutomationClientsideProviders { public class UIAutomationClientSideProviders {} }
'@

$process = [Diagnostics.Process]::GetCurrentProcess()
$window = [Windows.Automation.AutomationElement]::new()
$root = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-ui-scenarios-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$clipboardCases = [Collections.Generic.List[object]]::new()
try {
    & {
        foreach ($case in @(@(96, '900,900,260'), @(120, '1125,1125,325'), @(144, '1350,1350,390'), @(192, '1800,1800,520'))) {
            Assert-Equal ((Get-ObserverAppearanceColumnWidthsPx -Dpi $case[0]) -join ',') $case[1] 'Scaled persisted column widths'
        }
        $expectedHex = '4452434f4c53000001070000010184030000010184030000010104010000000078000000000050000000000078000000000078000000fd60733e'
        $bytes = Get-ObserverAppearanceColumnPreferenceBytes
        Assert-Equal $bytes.Length 58 'Appearance column preference length'
        Assert-Equal ([Convert]::ToHexString($bytes).ToLowerInvariant()) $expectedHex 'Exact supported v1 column preference bytes and checksum'
        $isolated = Join-Path $root 'pair-settings'
        $localData = Join-Path $isolated 'localappdata'
        [void](New-Item -ItemType Directory -Path $localData -Force)
        $priorLocalData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localData, 'Process')
            $seed = New-ObserverAppearanceColumnPreference -RuntimeRoot $isolated
            Assert-Equal $seed.source 'isolated-persisted-user-settings' 'Appearance preference source'
            Assert-Equal (Assert-ObserverAppearanceColumnPreference -Path $seed.path -ExpectedBytes $bytes) $seed.sha256 'Unchanged seeded preference'
            $changed = [byte[]]$bytes.Clone(); $changed[14] = 0
            [IO.File]::WriteAllBytes($seed.path, $changed)
            Assert-Fails { Assert-ObserverAppearanceColumnPreference -Path $seed.path -ExpectedBytes $bytes } 'Appearance column preference changed'
            $malformed = [byte[]]$bytes.Clone(); $malformed[57] = $malformed[57] -bxor 1
            [IO.File]::WriteAllBytes($seed.path, $malformed)
            Assert-Fails { Assert-ObserverAppearanceColumnPreference -Path $seed.path -ExpectedBytes $bytes } 'Appearance column preference changed'
            Assert-Fails { New-ObserverAppearanceColumnPreference -RuntimeRoot $isolated } 'already exists'
            [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $root, 'Process')
            Assert-Fails { New-ObserverAppearanceColumnPreference -RuntimeRoot $isolated } 'isolated LOCALAPPDATA'
        }
        finally { [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $priorLocalData, 'Process') }
    }
    & {
        function New-PrivateDirectory {
            param($Parent, $Leaf)
            Assert-Equal $Leaf 'appearance-fixture' 'Appearance pair first fixture directory'
            throw 'appearance pair entered with initially empty captures'
        }
        $initialCaptures = [Collections.Generic.List[object]]::new()
        Assert-Fails {
            Invoke-ObserverAppearancePairScenario -Verified @{} -RuntimeRoot $root `
                -EvidenceRoot $root -SessionId 1 -WaitSeconds 2 -Captures $initialCaptures
        } 'appearance pair entered with initially empty captures'
        Assert-Equal $initialCaptures.Count 0 'Appearance pair empty captures before first screenshot'
    }
    & {
        $bindingFailure = $false
        function Assert-AutomationBinding {
            param($Element, $Process, $ExpectedSession, $Label, [switch] $RequireWindowHandle)
            if ($bindingFailure) { throw 'fixture appearance binding failure' }
            Assert-Equal $Element.Current.NativeWindowHandle 101 'Pinned appearance HWND'
            Assert-Equal $RequireWindowHandle.IsPresent $true 'Appearance native binding'
        }
        [DarkReNamerVmAcceptanceNative]::Calls.Clear()
        $appearance = Get-VmAutomatedAppearance -Window $window -Process $process -ExpectedSession 1
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') 'checked:101:36880,checked:101:36881,checked:101:36882' 'Appearance command reads'
        Assert-Equal $appearance.hwnd 101 'Appearance HWND receipt'
        Assert-Equal $appearance.pid $process.Id 'Appearance PID receipt'
        Assert-Equal $appearance.session_id $process.SessionId 'Appearance session receipt'
        Assert-Equal ($appearance.menu_checked.command_id -join ',') '36880,36881,36882' 'Appearance command receipt'
        Assert-Equal ($appearance.menu_checked.checked -join ',') 'False,True,False' 'Appearance state receipt'
        foreach ($item in $appearance.menu_checked) { if ($item.checked -isnot [bool]) { throw 'Appearance state was not Boolean.' } }
        [DarkReNamerVmAcceptanceNative]::Calls.Clear(); $bindingFailure = $true
        Assert-Fails { Get-VmAutomatedAppearance -Window $window -Process $process -ExpectedSession 1 } 'fixture appearance binding failure'
        Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls.Count) 0 'No appearance reads after binding failure'
    }
    & {
        $observations = [ordered]@{}
        $failure = ''
        function Move-RailFocusToCommand {
            param($Process,$ExpectedSession,$AutomationId)
            Assert-Equal $AutomationId '32773' 'Prefix rail command'
            [DarkReNamerVmAcceptanceNative]::Calls.Add('rail-focus')
        }
        function Get-AcceptanceCommandActivationAttempt {
            param($Process,$ExpectedSession,$ExpectedAutomationId)
            Assert-Equal $ExpectedAutomationId '32773' 'Prefix activation command'
            [DarkReNamerVmAcceptanceNative]::Calls.Add('attempt-read')
            [ordered]@{ input_sent = $false }
        }
        function Assert-AcceptanceCommandActivationBinding {
            param($Attempt,$ExpectedProcessId,$ExpectedSession,$ExpectedMainWindow,$ExpectedAutomationId)
            if (-not $observations.Contains('prefix_activation_attempt') -or $observations.prefix_activation_attempt -ne $Attempt) { throw 'Attempt not persisted before binding.' }
            Assert-Equal $Attempt.input_sent $false 'Unsent prefix attempt'
            Assert-Equal $ExpectedMainWindow 101 'Prefix pinned owner'
            Assert-Equal $ExpectedProcessId $process.Id 'Prefix process binding'
            [DarkReNamerVmAcceptanceNative]::Calls.Add('attempt-bind')
            if ($failure -ceq 'binding') { throw 'fixture prefix binding failure' }
        }
        function Wait-AcceptanceOwnedInputWindow {
            param($Process,$ExpectedSession,$Owner,$Name,$TimeoutSeconds,$Label)
            Assert-Equal $Owner $window 'Prefix exact owner'
            Assert-Equal $Name '이름 앞에 문자열 붙이기' 'Prefix prompt name'
            Assert-Equal $observations.prefix_activation_attempt.input_sent $true 'Sent prefix diagnostic survives prompt wait'
            [DarkReNamerVmAcceptanceNative]::Calls.Add('owner-prompt')
            if ($failure -ceq 'prompt') { throw 'fixture owner prompt failure' }
            $window
        }
        foreach ($failure in @('','binding','tap','prompt')) {
            $observations.Clear(); [DarkReNamerVmAcceptanceNative]::Calls.Clear()
            [DarkReNamerVmAcceptanceNative]::InputFailure = $failure
            $action = { Invoke-CurrentDpiPrefixActivation -Process $process -MainWindow $window -ExpectedSessionId 1 -TimeoutSeconds 2 -Observations $observations }
            if ($failure -ceq '') {
                Assert-Equal (& $action) $window 'Prefix prompt returned'
                Assert-Equal $observations.Contains('prefix_activation_attempt') $false 'Successful prefix diagnostic removal'
                Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') 'rail-focus,attempt-read,attempt-bind,tap:32,owner-prompt' 'Prefix activation sequence'
            }
            else {
                Assert-Fails $action $(switch ($failure) { 'binding' { 'fixture prefix binding failure' } 'tap' { 'fixture tap failure' } 'prompt' { 'fixture owner prompt failure' } })
                Assert-Equal $observations.Contains('prefix_activation_attempt') $true 'Failed prefix diagnostic retention'
                Assert-Equal $observations.prefix_activation_attempt.input_sent ($failure -ceq 'prompt') 'Prefix input receipt after failure'
                if ($failure -ceq 'binding' -and [DarkReNamerVmAcceptanceNative]::Calls.Contains('tap:32')) { throw 'Prefix input bypassed binding.' }
            }
        }
    }
    & {
        function Wait-ListPreviewName { param($MainWindow,$Process,$ExpectedSession,$ExpectedName,$TimeoutSeconds)
            Assert-Equal $ExpectedName 'accepted-source.txt' 'Prefix preview target'
            [DarkReNamerVmAcceptanceNative]::Calls.Add('preview-wait')
        }
        $list = [Windows.Automation.AutomationElement]::new()
        $selection = [Windows.Automation.SelectionPattern]::new()
        $list.PatternValue = $selection
        foreach ($mode in @('empty','selected','missing')) {
            $list.PatternAvailable = $mode -cne 'missing'; $selection.Current.Count = $(if ($mode -ceq 'selected') { 1 } else { 0 })
            $keyboard = [ordered]@{}
            [DarkReNamerVmAcceptanceNative]::Calls.Clear()
            $action = { Wait-CurrentDpiPrefixPreview -List $list -Keyboard $keyboard -MainWindow $window -Process $process `
                -ExpectedSessionId 1 -TimeoutSeconds 2 -DestinationName 'accepted-source.txt' }
            if ($mode -ceq 'empty') {
                & $action
                Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') 'pattern:selection,selection-read,preview-wait' 'Selection observation before preview/reset preparation'
                Assert-Equal $keyboard.reset_name_selection_count_after_prefix 0 'No-selection receipt'
            } else {
                Assert-Fails $action $(if ($mode -ceq 'missing') { 'does not expose SelectionPattern' } else { 'acquired a list selection' })
                if ([DarkReNamerVmAcceptanceNative]::Calls.Contains('preview-wait')) { throw 'Invalid selection reached preview/reset preparation.' }
            }
        }
        function Find-UniqueAutomationElement {
            param($Root,$Process,$ExpectedSession,$AutomationId,$ControlType,$TimeoutSeconds,$Label)
            Assert-Equal $AutomationId '1148' 'Native file picker field ID'
            Assert-Equal $ControlType 'Edit' 'Native file picker field type'
            Assert-Equal $Root $window 'Native file picker owner'
            $window
        }
        Assert-Equal (Get-CurrentDpiFileNameField -FileDialog $window -Process $process -ExpectedSessionId 1 -TimeoutSeconds 2) $window 'Native file picker target'
    }
    & {
        function Find-UniqueAutomationElement {
            param($Root,$Process,$ExpectedSession,$AutomationId,$ControlType,$TimeoutSeconds,$Label,[switch]$RequireEnabled,[switch]$RequireWindowHandle)
            Assert-Equal $Root $window 'Context target root'
            Assert-Equal $ControlType 'Button' 'Context target type'
            Assert-Equal $RequireEnabled.IsPresent $true 'Context enabled target'
            if ($AutomationId -cin @('CommandButton_2','CommandLink_1101')) { Assert-Equal $RequireWindowHandle.IsPresent $true 'Context bound target HWND' }
            [DarkReNamerVmAcceptanceNative]::Calls.Add('target:'+$AutomationId)
            $element = [Windows.Automation.AutomationElement]::new()
            if ($AutomationId -ceq 'CommandLink_1102') { $element.Current.Name = '예시 전체 정보 · 복사' }
            $element
        }
        function Get-ObserverControlReachability {
            param($Element,$Application,$SessionId,$ExpectedRoot,$WorkArea,$Label)
            Assert-Equal $ExpectedRoot ([IntPtr]101) 'Context reachability owner'
            [ordered]@{ status = if ($Label -ceq $failedLabel) { 'outside-work-area' } else { 'reachable' }; label = $Label }
        }
        function Write-JsonUtf8Bom {
            param($Path,$Value)
            [DarkReNamerVmAcceptanceNative]::Calls.Add('receipt-write')
            [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
        }
        $expander = [Windows.Automation.AutomationElement]::new(); $expander.Current.Name = '진단 정보 표시'
        $window.Children = [Windows.Automation.AutomationElement[]]@($expander)
        foreach ($failedLabel in @('','context Cancel','context Apply','context full details','context expander')) {
            [DarkReNamerVmAcceptanceNative]::Calls.Clear()
            $path = Join-Path $root 'context-reachability.json'
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
            $action = { Get-ObserverContextConfirmationReachability -Confirmation $window -Application @{process=$process} `
                -SessionId 1 -WaitSeconds 2 -ConfirmationHandle ([IntPtr]101) -WorkArea @{} -OutputRoot $root -Prefix context }
            if ($failedLabel -ceq '') {
                $controls = & $action
                Assert-Equal $controls.reachability.Count 4 'Context receipt controls'
            } else { Assert-Fails $action $failedLabel }
            Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') 'target:CommandButton_2,target:CommandLink_1101,target:CommandLink_1102,receipt-write' 'Context target IDs and persisted receipt'
            if (-not (Test-Path -LiteralPath $path)) { throw 'Rejected reachability lost its receipt.' }
            $receipt = [IO.File]::ReadAllText($path)|ConvertFrom-Json
            Assert-Equal $receipt.schema_version 1 'Context receipt schema'
            if ($failedLabel -cne '') {
                Assert-Equal (@($receipt.controls.PSObject.Properties.Value|Where-Object status -cne 'reachable').Count) 1 'Retained failed reachability row'
            }
        }
    }
    & {
        function New-ClipboardSnapshot {
            param([uint32]$Sequence,[AllowNull()][string]$Text,[uint32[]]$Formats)
            [pscustomobject]@{ SequenceNumber=$Sequence; UnicodeText=$Text; Formats=$Formats }
        }
        function Assert-AcceptanceForegroundBinding { param($Process,$ExpectedSession,$MainWindowHandle,[switch]$RequireMainWindow)
            Assert-Equal $MainWindowHandle ([IntPtr]101) 'Clipboard pinned main HWND'
            [DarkReNamerVmAcceptanceNative]::Calls.Add('foreground-bind')
        }
        function Send-AcceptanceChord { param($Process,$ExpectedSession,$Modifier,$VirtualKey,$Label)
            Assert-Equal $Modifier 0x12 'Names menu modifier'; Assert-Equal $VirtualKey 0x46 'Names menu accelerator'
            [DarkReNamerVmAcceptanceNative]::Calls.Add('alt-f')
        }
        function Wait-AcceptancePopupMenu { param($Process,$ExpectedSession,$Label)
            [DarkReNamerVmAcceptanceNative]::Calls.Add('popup-wait')
        }
        function Send-AcceptanceTap { param($Process,$ExpectedSession,$VirtualKey,$Label)
            Assert-Equal $VirtualKey 0x58 'Export submenu mnemonic'
            [DarkReNamerVmAcceptanceNative]::Calls.Add('export-x')
        }
        function Find-AcceptanceMenuItem { param($Process,$ExpectedSession,$Name,$TimeoutSeconds)
            Assert-Equal $Name '변경 후 이름 목록 복사' 'Copy Names menu item'
            $item = [Windows.Automation.AutomationElement]::new()
            $item.PatternValue = [Windows.Automation.InvokePattern]::new()
            $item.PatternAvailable = $mode -cne 'names-pattern'
            $item
        }
        function Wait-AcceptancePopupMenuClosed { param($Process,$Label)
            [DarkReNamerVmAcceptanceNative]::Calls.Add('popup-closed')
        }
        function Send-AcceptanceTwoModifierChord { param($Process,$ExpectedSession,$Modifier,$SecondModifier,$VirtualKey,$Label)
            Assert-Equal $Modifier 0x11 'Paths Control modifier'; Assert-Equal $SecondModifier 0x10 'Paths Shift modifier'; Assert-Equal $VirtualKey 0x43 'Paths C key'
            [DarkReNamerVmAcceptanceNative]::Calls.Add('ctrl-shift-c')
        }
        function Wait-AcceptanceClipboardText { param($PreviousSequence,$ExpectedText,$TimeoutSeconds,$Label)
            [DarkReNamerVmAcceptanceNative]::Calls.Add('wait-copy:'+$PreviousSequence)
            if (($PreviousSequence -eq 42 -and $mode -ceq 'names-wait') -or ($PreviousSequence -eq 43 -and $mode -ceq 'paths-wait')) { throw 'fixture copy observation failure' }
            [pscustomobject]@{SequenceNumber=[uint32]($PreviousSequence+1);UnicodeText=$ExpectedText;Formats=[uint32[]]@(13)}
        }
        foreach ($mode in @('success','preflight-foreign','names-disabled','names-changed','names-pattern','names-wait','paths-disabled','paths-changed','paths-wait')) {
            $names = "accepted-source.txt`r`n"; $paths = "/fixture/source.txt`r`n"
            $result = [ordered]@{failure_reason=$null}
            $clipboardResult = [ordered]@{preflight_empty=$false;names=$null;paths=$null;status='failed';reason='initial';cleanup='not-owned'}
            $clipboardState = [pscustomobject]@{owned=$false;expected_sequence=[uint32]0;expected_text=$null;checks_complete=$false}
            [DarkReNamerVmAcceptanceNative]::Calls.Clear(); [DarkReNamerVmAcceptanceNative]::Snapshots.Clear()
            [DarkReNamerVmAcceptanceNative]::DisabledCommand = $(switch ($mode) {'names-disabled' {0x8018} 'paths-disabled' {0x801A} default {0}})
            # Construct empty snapshots directly: string parameter conversion must
            # not manufacture empty text where the native adapter observed null.
            $preflight = [pscustomobject]@{SequenceNumber=[uint32]42;UnicodeText=$null;Formats=[uint32[]]@()}
            $beforeNames = [pscustomobject]@{SequenceNumber=[uint32]42;UnicodeText=$null;Formats=[uint32[]]@()}
            if ($mode -ceq 'preflight-foreign') { $preflight.UnicodeText = 'foreign'; $preflight.Formats = [uint32[]]@(13) }
            if ($mode -ceq 'names-changed') { $beforeNames.SequenceNumber = [uint32]99 }
            $beforePaths = New-ClipboardSnapshot -Sequence 43 -Text $names -Formats ([uint32[]]@(13))
            if ($mode -ceq 'paths-changed') { $beforePaths.UnicodeText = 'foreign' }
            foreach ($snapshot in @($preflight,$beforeNames,$beforePaths)) { [DarkReNamerVmAcceptanceNative]::Snapshots.Enqueue($snapshot) }
            $action = { Invoke-CurrentDpiClipboardAcceptance -Process $process -MainWindow $window -MainHandle ([IntPtr]101) `
                -ExpectedSessionId 1 -TimeoutSeconds 2 -DestinationName 'accepted-source.txt' -SourcePath '/fixture/source.txt' `
                -Result $result -ClipboardResult $clipboardResult -ClipboardState $clipboardState }
            if ($mode -ceq 'success') {
                & $action
                Assert-Equal $clipboardResult.status 'pending_cleanup' 'Clipboard waits for guarded cleanup'
                Assert-Equal $clipboardState.expected_sequence 44 'Owned final paths sequence'
                Assert-Equal $clipboardState.expected_text $paths 'Owned final paths text'
                Assert-Equal $clipboardState.checks_complete $true 'Clipboard checks receipt'
                Assert-Equal ($clipboardResult.names|ConvertTo-Json -Compress) (Get-AcceptanceClipboardTextEvidence -Text $names|ConvertTo-Json -Compress) 'Names evidence'
                Assert-Equal ($clipboardResult.paths|ConvertTo-Json -Compress) (Get-AcceptanceClipboardTextEvidence -Text $paths|ConvertTo-Json -Compress) 'Paths evidence'
                Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') `
                    'clipboard-read,foreground-bind,enabled:32792,alt-f,popup-wait,export-x,foreground-bind,clipboard-read,pattern:invoke,invoke-names,popup-closed,wait-copy:42,focus:101,foreground:101,foreground-read,foreground-bind,enabled:32794,clipboard-read,ctrl-shift-c,wait-copy:43' 'Clipboard phase calls'
            }
            else {
                $expected = switch ($mode) {
                    'preflight-foreign' {'initially empty Clipboard'}
                    'names-disabled' {'Copy Names menu command is not enabled'}
                    'names-changed' {'changed before Copy Names'}
                    'names-pattern' {'does not expose InvokePattern'}
                    'paths-disabled' {'Copy Paths menu command is not enabled'}
                    'paths-changed' {'changed before Copy Paths'}
                    default {'fixture copy observation failure'}
                }
                Assert-Fails $action $expected
                $phase = if ($mode -ceq 'preflight-foreign') {'clipboard_preflight_failed'} elseif ($mode.StartsWith('names-')) {'clipboard_names_failed'} else {'clipboard_paths_failed'}
                Assert-Equal $result.failure_reason $phase 'Exact failed Clipboard phase'
                Assert-Equal $clipboardState.owned ($mode.StartsWith('paths-')) 'Ownership only after successful names observation'
                Assert-Equal $clipboardState.checks_complete $false 'Failed checks cannot complete'
                if ($mode -in @('names-changed','names-disabled','names-pattern','preflight-foreign') -and [DarkReNamerVmAcceptanceNative]::Calls.Contains('invoke-names')) { throw 'Copy Names invoked after failed guard.' }
                if ($mode -in @('paths-changed','paths-disabled') -and [DarkReNamerVmAcceptanceNative]::Calls.Contains('ctrl-shift-c')) { throw 'Copy Paths invoked after failed ownership guard.' }
                if ($mode.StartsWith('paths-')) { Assert-Equal $clipboardState.expected_sequence 43 'Names ownership retained on failed paths'; Assert-Equal $clipboardState.expected_text $names 'Names text retained on failed paths' }
            }
            $clipboardCases.Add([pscustomobject]@{mode=$mode;state=$clipboardState;evidence=$clipboardResult;failure=$result.failure_reason})
            if (@([DarkReNamerVmAcceptanceNative]::Calls|Where-Object { $_ -like 'clear:*' }).Count -ne 0) { throw 'Clipboard phase cleared data before guarded finalization.' }
        }
    }
    & {
        function Ensure-AcceptanceMainWindowCaptureSize { param($MainWindow,$Process,$ExpectedSession)
            [DarkReNamerVmAcceptanceNative]::Calls.Add('size')
            if ($sizingFailure) { throw 'fixture sizing failure' }
            [ordered]@{dpi=96;width=640;height=508}
        }
        function Get-VmAutomatedAppearance { param($Window,$Process,$ExpectedSession) [ordered]@{hwnd=101} }
        function Get-VmAutomatedEnvironment { param($Process,$WindowHandle,$FixtureRoot) [ordered]@{hwnd_dpi=96} }
        function Get-VmAutomatedControlObservation { param($Element,$Process,$ExpectedSession,$Label) [ordered]@{label=$Label} }
        function Get-ObserverNativeWindowMetrics { param($Window) [ordered]@{hwnd=101} }
        function Get-ElementObservation { param($Element) [ordered]@{hwnd=$Element.Current.NativeWindowHandle} }
        function Get-RailAccessibilitySnapshot { param($MainWindow,$Process,$ExpectedSession,$TimeoutSeconds) @('one','two') }
        function Find-UniqueAutomationElement { param($Root,$Process,$ExpectedSession,$AutomationId,$ControlType,$TimeoutSeconds,$Label,[switch]$RequireWindowHandle)
            [DarkReNamerVmAcceptanceNative]::Calls.Add('find:'+$AutomationId)
            if ($AutomationId -ceq '1000') { Assert-Equal $ControlType 'DataGrid' 'Workbench list type' }
            $window
        }
        function Save-WindowScreenshot { param($ForegroundObservations,$Window,$Process,$ExpectedSession,$Root,$Leaf,$Label)
            [DarkReNamerVmAcceptanceNative]::Calls.Add('capture')
            [ordered]@{file=$Leaf;width=640;height=508}
        }
        function Add-AcceptanceScreenshotContext { param($Screenshot,$Appearance,$Surface) $Screenshot }
        $script:acceptanceForegroundObservations = [Collections.Generic.List[object]]::new()
        foreach ($raw in @($false,$true)) {
            foreach ($sizingFailure in @($false,$true)) {
                [DarkReNamerVmAcceptanceNative]::Calls.Clear()
                $rawControls = [Collections.Generic.List[object]]::new(); $captures = [Collections.Generic.List[object]]::new()
                $observations = [ordered]@{}; $accessibility = [ordered]@{}
                $colors = [pscustomobject]@{Flags=0;Scheme='';Window=1;WindowText=2;ButtonFace=3;ButtonText=4;Highlight=5;HighlightText=6;GrayText=7;HotLight=8}
                $action = { Get-CurrentDpiWorkbenchObservation -MainWindow $window -Process $process -ExpectedSessionId 1 -TimeoutSeconds 2 `
                    -RawCandidate $raw -Verified @{output_root=$root} -FixtureRoot $root -AppearanceSpec @{evidence_name='system'} `
                    -HighContrastState @{acceptance=$colors} -Result ([ordered]@{}) -Observations $observations -Accessibility $accessibility `
                    -RawControls $rawControls -Captures $captures -CapturePrefix current-dpi }
                if ($sizingFailure) {
                    Assert-Fails $action 'fixture sizing failure'
                    Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls -join ',') 'size' 'Sizing failure blocks observations and first capture'
                    Assert-Equal $captures.Count 0 'No first capture after failed sizing'
                } else {
                    $workbench = & $action
                    Assert-Equal $workbench.list $window 'Returned actual workbench list'
                    Assert-Equal $captures.Count 1 'Exactly one first workbench capture'
                    Assert-Equal $captures[0].file 'current-dpi-initial.png' 'First capture leaf'
                    Assert-Equal $observations.environment.capture_window.width 640 'Sizing receipt bound into environment'
                    Assert-Equal $accessibility.rail_button_count 2 'Observed accessibility count'
                    Assert-Equal $rawControls.Count $(if ($raw) {21} else {0}) 'Raw controls observation count'
                    Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls[0]) 'size' 'Size before first workbench action'
                    Assert-Equal ([DarkReNamerVmAcceptanceNative]::Calls[([DarkReNamerVmAcceptanceNative]::Calls.Count-1)]) 'capture' 'First capture after workbench observation'
                }
            }
        }
    }
    # Execute each complete publishing finalizer, including the actual process-job
    # ledger guard and runtime-tree observer before real fixture deletion. AST
    # extraction selects a whole lifecycle boundary, never individual statements.
    $tokens=$null; $errors=$null
    $combined = Get-DrTestCombinedPowerShellSource -Kind ui
    $ast = [Management.Automation.Language.Parser]::ParseInput($combined,[ref]$tokens,[ref]$errors)
    if ($errors.Count -ne 0) { throw 'Scenario production sources cannot be parsed.' }
    function Get-ScenarioFinalizer {
        param([string]$Name)
        $functionAst = $ast.Find({param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
        },$true)
        $finalizers = @($functionAst.FindAll({param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and $null -ne $node.Finally -and
            $node.Finally.Extent.Text.Contains('Write-ResultDocument')
        },$true))
        if ($finalizers.Count -ne 1) { throw "Missing complete publishing finalizer: $Name" }
        $body=$finalizers[0].Finally.Extent.Text
        [scriptblock]::Create($body.Substring(1,$body.Length-2))
    }
    $finalizers=@{
        'current-dpi'=Get-ScenarioFinalizer 'Invoke-DrCurrentDpiAcceptanceScenario'
        'regression'=Get-ScenarioFinalizer 'Invoke-GuiRegressionAcceptance'
        'rescue'=Get-ScenarioFinalizer 'Invoke-HighContrastRescue'
    }
    function Invoke-ScenarioFinalizerFixture {
        param([string]$Mode,[string]$Ledger='clean',[bool]$LockFailure=$false,[AllowNull()][string]$InitialFailure,
            [bool]$ClipboardOwned=$false,[string]$ClipboardCleanup='cleared',[bool]$ChecksComplete=$true,
            [uint32]$ClipboardSequence=44,[AllowNull()][string]$ClipboardText='owned paths',[object]$ClipboardEvidence=$null)
        & {
            $caseRoot = Join-Path $root ([guid]::NewGuid().ToString('N'))
            $null=New-Item -ItemType Directory -Path $caseRoot
            $runtimeRoot=Join-Path $caseRoot 'runtime'; $effectiveRuntimeRoot=$runtimeRoot
            $null=New-Item -ItemType Directory -Path $runtimeRoot
            $ownedLeaf=Join-Path $runtimeRoot 'owned.txt'; [IO.File]::WriteAllText($ownedLeaf,'owned fixture')
            $resultPath=Join-Path $caseRoot 'acceptance-result.json'
            $observationPath=Join-Path $caseRoot 'acceptance-observations.json'
            $diagnosticPath=Join-Path $caseRoot 'acceptance-error.txt'; $errorPath=$diagnosticPath
            if (-not [string]::IsNullOrEmpty($InitialFailure)) { [IO.File]::WriteAllText($diagnosticPath,'original scenario diagnostic') }
            function Exit-DesktopTestLock {param($Lock) if ($LockFailure) {throw 'fixture desktop lock release failure'} }
            function Exit-TestExecutionState {param($Previous) }
            function Get-CimInstance {param($ClassName) @() }
            function Get-VmAutomatedJournalInventory {param($LocalAppData) @() }
            function Get-Item {
                [CmdletBinding()]
                param($LiteralPath,[switch]$Force)
                if ($Ledger -ceq 'reparse' -and $LiteralPath -ceq $ownedLeaf) {
                    # Simulate only the OS attribute result. The actual tree
                    # observer enumerates the real owned fixture directory.
                    [pscustomobject]@{FullName=$LiteralPath;PSIsContainer=$false;Attributes=[IO.FileAttributes]::ReparsePoint}
                } else { Microsoft.PowerShell.Management\Get-Item @PSBoundParameters }
            }
            function Write-JsonUtf8Bom {param($Path,$Value)
                [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
            }
            function Write-ResultDocument {param($Root,$Path,$Result) Write-JsonUtf8Bom -Path $Path -Value $Result }
            $script:AcceptanceProcessJobCleanup=[Collections.Generic.List[object]]::new()
            if ($Ledger -ceq 'missing') { $script:AcceptanceProcessJobCleanup=$null }
            if ($null -ne $script:AcceptanceProcessJobCleanup -and $Ledger -cne 'empty') {
                $script:AcceptanceProcessJobCleanup.Add([pscustomobject]@{
                    status='clean';job_empty=$true;job_closed=($Ledger -cne 'open');capture_complete=$true
                    active_processes_at_close=0;had_survivors=$false;error='fixture open job'
                })
            }
            $result=[ordered]@{status=if ([string]::IsNullOrEmpty($InitialFailure)) {'review_required'} else {'failed'}
                failure_reason=if ([string]::IsNullOrEmpty($InitialFailure)) {$null} else {$InitialFailure}
                raw_cleanup=$null;process_cleanup=$false;guest_cleanup=$false;screenshots=@();diagnostic=$null;observations=$null}
            $verified=[pscustomobject]@{root=$caseRoot}; $resolved=[pscustomobject]@{root=$caseRoot}
            $rawCandidate=$Mode -ceq 'current-dpi';$rawRegression=$Mode -ceq 'regression'
            $lifecycle=[pscustomobject]@{process_terminated=$true}; $processState=[pscustomobject]@{process=$null}
            $rawCheckpoints=[Collections.Generic.List[object]]::new();$captures=[Collections.Generic.List[object]]::new()
            $observations=[ordered]@{fixture=$Mode};$Clipboard=$ClipboardOwned
            $clipboardState=[pscustomobject]@{owned=$ClipboardOwned;expected_sequence=$ClipboardSequence;expected_text=$ClipboardText;checks_complete=$ChecksComplete}
            $clipboardResult=if ($null -eq $ClipboardEvidence) { [ordered]@{status='pending_cleanup';reason=$null;cleanup='pending'} } else { $ClipboardEvidence }
            [DarkReNamerVmAcceptanceNative]::Cleanup=$ClipboardCleanup
            [DarkReNamerVmAcceptanceNative]::Calls.Clear()
            $HighContrast=$false;$highContrastState=[pscustomobject]@{original=$null}
            $previousExecutionState=$null;$executionState=$null;$desktopLock=$null;$lock=$null
            $runtimeCleanup=$false;$runtimeCleaned=$false
            $rawRegressionJournalAfter=$null;$rawRegressionJournalObserved=$false;$rawRegressionRuntimeRootAfter=$null
            $RegressionMode='standard';$textOriginal=$null;$textChanged=$false;$cursor=$null
            if ($Mode -ceq 'rescue' -and [string]::IsNullOrEmpty($InitialFailure)) {$result.status='passed'}
            . $finalizers[$Mode]
            $published=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json
            $diagnostic=if (Test-Path -LiteralPath $diagnosticPath) {[IO.File]::ReadAllText($diagnosticPath)} else {$null}
            [pscustomobject]@{result=$published;runtime_exists=(Test-Path -LiteralPath $runtimeRoot);owned_exists=[IO.File]::Exists($ownedLeaf)
                diagnostic=$diagnostic;diagnostic_path=$diagnosticPath;observation_path=$observationPath;clipboard=$clipboardResult
                calls=@([DarkReNamerVmAcceptanceNative]::Calls)}
        }
    }
    foreach ($mode in @('current-dpi','regression')) {
        foreach ($ledger in @('clean','open','missing','empty','reparse')) {
            $published=Invoke-ScenarioFinalizerFixture -Mode $mode -Ledger $ledger
            Assert-Equal $published.runtime_exists ($ledger -cne 'clean') 'Guarded runtime root retention'
            Assert-Equal $published.owned_exists ($ledger -cne 'clean') 'Guarded owned fixture retention'
            Assert-Equal $published.result.guest_cleanup ($ledger -ceq 'clean') 'Guarded cleanup receipt'
            if ($ledger -ceq 'clean') {
                Assert-Equal $published.result.status 'review_required' 'Clean finalizer status'
                Assert-Equal $published.result.raw_cleanup.runtime_root_after.exists $false 'Observed removed runtime'
            } else {
                Assert-Equal $published.result.status 'failed' 'Unproven cleanup fails finalizer'
                Assert-Equal $published.result.failure_reason $(if ($mode -ceq 'current-dpi') {'runtime_cleanup_failed'} else {'raw_cleanup_failed'}) 'Cleanup boundary failure receipt'
                if ($ledger -cne 'reparse') {Assert-Equal $published.result.raw_cleanup.runtime_root_after.exists $true 'Observed retained runtime'}
            }
            $separate=[IO.File]::ReadAllText($published.observation_path)|ConvertFrom-Json
            Assert-Equal ($published.result.acceptance_observations|ConvertTo-Json -Depth 12 -Compress) ($separate|ConvertTo-Json -Depth 12 -Compress) 'Finalizer embedded observations'
            Assert-Equal $published.result.observations.sha256 (Get-LowerSha256 -Path $published.observation_path) 'Finalizer observation byte binding'
        }
    }
    foreach ($mode in @('current-dpi','regression','rescue')) {
        foreach ($initial in @($null,'original_scenario_failure')) {
            $published=Invoke-ScenarioFinalizerFixture -Mode $mode -LockFailure $true -InitialFailure $initial
            Assert-Equal $published.result.status 'failed' 'Lock-release failure status'
            Assert-Equal $published.result.failure_reason $(if ($null -eq $initial) {'desktop_lock_release_failed'} else {$initial}) 'Primary failure preserved after lock release failure'
            if (-not $published.diagnostic.Contains('fixture desktop lock release failure')) {throw 'Lock-release error missing from retained diagnostic.'}
            if ($null -ne $initial -and -not $published.diagnostic.StartsWith('original scenario diagnostic')) {throw 'Lock-release failure replaced original diagnostic.'}
            Assert-Equal $published.result.diagnostic.sha256 (Get-LowerSha256 -Path $published.diagnostic_path) 'Lock-release diagnostic byte binding'
        }
    }
    # Pass the actual phase-produced ownership and evidence into the complete
    # finalizer. Failed names never own cleanup; failed paths clean only names;
    # successful paths become passed only after guarded cleanup succeeds.
    foreach ($case in $clipboardCases) {
        $initial=if ($case.mode -ceq 'success') {$null} else {$case.failure}
        $published=Invoke-ScenarioFinalizerFixture -Mode current-dpi -InitialFailure $initial `
            -ClipboardOwned $case.state.owned -ChecksComplete $case.state.checks_complete `
            -ClipboardSequence $case.state.expected_sequence -ClipboardText $case.state.expected_text -ClipboardEvidence $case.evidence
        if ($case.state.owned) {
            Assert-Equal ($published.calls -join ',') ("clear:{0}:{1}" -f $case.state.expected_sequence,$case.state.expected_text) 'Phase-produced exact cleanup ownership'
            Assert-Equal $published.clipboard.cleanup 'cleared' 'Phase-produced guarded cleanup'
        } else { Assert-Equal $published.calls.Count 0 'Failed names phase owns no cleanup' }
        Assert-Equal $published.clipboard.status $(if ($case.mode -ceq 'success') {'passed'} else {'failed'}) 'Full phase/finalizer Clipboard outcome'
    }
    foreach ($cleanup in @('cleared','sequence_changed','error')) {
        foreach ($initial in @($null,'clipboard_paths_failed')) {
            $published=Invoke-ScenarioFinalizerFixture -Mode current-dpi -ClipboardOwned $true -ClipboardCleanup $cleanup -InitialFailure $initial
            Assert-Equal ($published.calls -join ',') 'clear:44:owned paths' 'Exact guarded Clipboard cleanup ownership'
            Assert-Equal $published.clipboard.cleanup $(switch ($cleanup) {'cleared' {'cleared'} 'error' {'failed'} default {'preserved_foreign_change'}}) 'Guarded Clipboard cleanup receipt'
            if ($cleanup -ceq 'cleared') {
                Assert-Equal $published.clipboard.status 'passed' 'Completed Clipboard checks plus cleanup'
            } else {
                Assert-Equal $published.clipboard.status 'failed' 'Unverified Clipboard cleanup fails'
                Assert-Equal $published.result.failure_reason $(if ($null -ne $initial) {$initial} elseif ($cleanup -ceq 'error') {'clipboard_cleanup_failed'} else {'clipboard_cleanup_preserved_foreign_change'}) 'Clipboard cleanup preserves failed phase'
            }
        }
    }
    $published=Invoke-ScenarioFinalizerFixture -Mode current-dpi -ClipboardOwned $false
    Assert-Equal $published.calls.Count 0 'No cleanup of unowned Clipboard'
    $published=Invoke-ScenarioFinalizerFixture -Mode current-dpi -ClipboardOwned $true -ChecksComplete $false -InitialFailure clipboard_paths_failed
    Assert-Equal $published.clipboard.status 'pending_cleanup' 'Incomplete checks never become passed through cleanup'
    Assert-Equal $published.result.failure_reason 'clipboard_paths_failed' 'Incomplete phase failure retained'
}
finally {
    $process.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Output 'UI scenario behavior contracts passed.'
