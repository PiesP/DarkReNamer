param([Parameter(Mandatory)][hashtable] $Libraries)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedRoles = @(
    'powershell-guest-contracts'
    'powershell-guest-process'
    'powershell-guest-native'
    'powershell-guest-platform'
    'powershell-guest-uia'
    'powershell-guest-state'
    'powershell-guest-scenario'
    'powershell-guest-runtime'
    'powershell-ui-bootstrap'
    'powershell-ui-appearance'
    'powershell-ui-native'
    'powershell-ui-menu'
    'powershell-ui-current-dpi'
    'powershell-ui-input'
    'powershell-ui-application'
    'powershell-ui-fixtures'
    'powershell-ui-context-scenarios'
    'powershell-ui-regression'
)
if ($Libraries.Count -ne $expectedRoles.Count) { throw 'The verified definition library set is incomplete.' }
foreach ($role in $expectedRoles) {
    if (-not $Libraries.ContainsKey($role) -or $Libraries[$role] -isnot [scriptblock]) {
        throw "Missing verified definition library: $role"
    }
    . $Libraries[$role]
}

function Invoke-DrWindowsVmAcceptance {
    [CmdletBinding()]
    param(
    [Parameter(Mandatory)][string] $BundleRoot,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $ExpectedSessionId,
    [Parameter(Mandatory)][string] $OutputRoot,
    [string] $RuntimeRoot,
    [Parameter(Mandatory)][string] $ExpectedScriptSha256,
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 60,
    [ValidateSet('system', 'light', 'dark')][string] $Appearance = 'system',
    [switch] $CaptureNativeMenu,
    [switch] $CaptureAdvancedAppearance,
    [switch] $Clipboard,
    [switch] $HighContrast,
    [ValidatePattern('^[0-9a-f]{32}\z')][string] $RuntimeBrokerDiagnosticRunId,
    [switch] $RestoreHighContrastOnly,
    [ValidateSet('full-context', 'standard', 'text-scale', 'tooltip', 'appearance-pair', 'performance-sample')]
    [string] $RegressionMode,
    [string] $InputManifestPath,
    [ValidateSet(100, 150)][int] $TextScalePercent = 100,
    [switch] $RestoreTextScaleOnly,
    [ValidateSet('vm-automated-v1-win11-ntfs', 'vm-automated-v2-owned-resources')]
    [string] $AcceptanceProfileId = 'vm-automated-v1-win11-ntfs',
    [switch] $ValidateOnly,
    [Parameter(Mandatory)][string] $EntryPointPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($AcceptanceProfileId -cnotin @('vm-automated-v1-win11-ntfs', 'vm-automated-v2-owned-resources')) {
    throw 'Unsupported VM acceptance profile identity.'
}
$script:VmAcceptanceProfileId = $AcceptanceProfileId
if ($AcceptanceProfileId -ceq 'vm-automated-v2-owned-resources' -and -not $ValidateOnly) {
    Initialize-DrVmObserverLifecycle -ProfileId $AcceptanceProfileId
}
$script:acceptanceForegroundObservations = [Collections.Generic.List[object]]::new()
$script:AcceptanceProcessJobCleanup = [Collections.Generic.List[object]]::new()
$script:AutomationControlInvocations = [Collections.Generic.List[object]]::new()



$bootstrap = Resolve-AcceptanceBootstrap `
    -Root $BundleRoot `
    -ScriptPath $EntryPointPath `
    -ScriptSha256 $ExpectedScriptSha256

if (-not [string]::IsNullOrEmpty($RegressionMode)) {
    if ([string]::IsNullOrEmpty($InputManifestPath)) {
        throw 'RegressionMode requires InputManifestPath.'
    }
    $null = Resolve-VerifiedBundle -Root $bootstrap.root -InvokedScriptPath $bootstrap.runner
    Invoke-GuiRegressionAcceptance
    return
}

Invoke-DrCurrentDpiAcceptanceScenario
}

Export-ModuleMember -Function Invoke-DrWindowsVmAcceptance
