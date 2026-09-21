[CmdletBinding(DefaultParameterSetName = 'Direct')]
param(
    [Parameter(Mandatory = $true)][string] $BundleRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string] $VmName,
    [Parameter(ParameterSetName = 'Direct')]
    [ValidateScript({ $_ -ne [guid]::Empty })][guid] $ExpectedVmId,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string] $CredentialHelper,
    [Parameter(Mandatory = $true, ParameterSetName = 'Ssh')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z')]
    [string] $SshHost,
    [ValidatePattern('^S-1-5-21-(\d+-){2}\d+-\d+$')][string] $ExpectedDesktopSid,
    [ValidateRange(10, 1800)][int] $TestTimeoutSeconds = 300,
    [ValidateRange(60, 14400)][int] $SuiteTimeoutSeconds = 2400,
    [ValidateSet('core', 'ui', 'recovery')][string] $TaskKind,
    [string] $AcceptanceOutputRoot,
    [string] $AcceptanceManifest,
    [ValidateSet('current-dpi', 'full-context', 'standard', 'text-scale', 'tooltip')]
    [string] $AcceptanceMode,
    [ValidateSet('system', 'light', 'dark')][string] $AcceptanceAppearance,
    [ValidateSet(100, 150)][int] $AcceptanceTextScalePercent = 100,
    [switch] $AcceptanceHighContrast,
    [switch] $AcceptanceClipboard,
    [switch] $AcceptanceCaptureNativeMenu,
    [switch] $AcceptanceCaptureAdvancedAppearance,
    [string] $RecoveryOutputRoot,
    [ValidateSet('ProcessCrash', 'WorkerCancellation', 'WorkerClose')]
    [string] $RecoveryMode,
    [ValidateRange(128, 10000)][int] $RecoveryFixtureCount = 4096,
    [ValidatePattern('^[0-9a-f]{64}\z')][string] $RecoveryObserverSha256,
    [switch] $RecoveryExport,
    [switch] $RecoveryIntentOnlyCandidateDiscard,
    [guid] $ExpectedGuestVmId = [guid]::Empty,
    [ValidatePattern('^[0-9a-f]{64}\z')][string] $ExpectedBundleManifestSha256
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ToolingManifestSha256 = 'd0d5d46eb8629adc727fa66e761120ce7fbd4bcd277a1145b0979a600c01af4d'
$ToolingLoaderSha256 = '6888561ff9a23becf279ec7d4e691b40d50d79dde2196d22c0d63e2252dd08a1'

function Get-DrBootstrapSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Assert-DrBootstrapOrdinaryPath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Label
    )
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must be an ordinary file."
    }
    $rootItem = Microsoft.PowerShell.Management\Get-Item `
        -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The tooling root must be an ordinary directory.'
    }
    $cursor = $item.Directory
    while ($null -ne $cursor -and
        -not [string]::Equals($cursor.FullName, $rootItem.FullName, [StringComparison]::OrdinalIgnoreCase)) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label must not traverse a reparse point."
        }
        $cursor = $cursor.Parent
    }
    if ($null -eq $cursor) { throw "$Label must remain beneath the tooling root." }
    return $item
}

function Read-DrBootstrapBoundedBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int] $MaximumBytes,
        [Parameter(Mandatory)][string] $Label
    )
    $buffer = [byte[]]::new($MaximumBytes + 1)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt $MaximumBytes -or $stream.ReadByte() -ne -1) {
            throw "$Label exceeds its size bound."
        }
        $result = [byte[]]::new($count)
        [Array]::Copy($buffer, 0, $result, 0, $count)
        return $result
    }
    finally { $stream.Dispose() }
}

function Initialize-DrVerifiedTooling {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ManifestLocation,
        [Parameter(Mandatory)][ValidateSet('checkout', 'bundle')][string] $Mode,
        [Parameter(Mandatory)][string] $RequiredRole
    )
    $rootPath = [IO.Path]::GetFullPath($Root)
    $manifestPath = [IO.Path]::GetFullPath([IO.Path]::Combine($rootPath, $ManifestLocation))
    $manifestItem = Assert-DrBootstrapOrdinaryPath `
        -Path $manifestPath -Root $rootPath -Label 'Tooling manifest'
    if ($manifestItem.Length -gt 512KB) { throw 'Tooling manifest exceeds its size bound.' }
    $manifestBytes = Read-DrBootstrapBoundedBytes `
        -Path $manifestPath -MaximumBytes (512KB) -Label 'Tooling manifest'
    if ($manifestBytes.Length -gt 512KB -or
        (Get-DrBootstrapSha256 -Bytes $manifestBytes) -cne $ToolingManifestSha256) {
        throw 'Tooling manifest hash mismatch.'
    }
    try {
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        $manifest = $encoding.GetString($manifestBytes) |
            Microsoft.PowerShell.Utility\ConvertFrom-Json
    }
    catch { throw "Authenticated tooling manifest is invalid UTF-8 JSON: $($_.Exception.Message)" }
    $loaders = [Collections.Generic.List[object]]::new()
    foreach ($record in @($manifest.modules)) {
        if ($record.role -ceq 'powershell-loader') { $loaders.Add($record) }
    }
    if ($loaders.Count -ne 1) { throw 'Authenticated tooling manifest must bind one PowerShell loader.' }
    $loader = $loaders[0]
    $relativeLoader = if ($Mode -ceq 'checkout') { $loader.source } else { $loader.bundle }
    if ($loader.kind -cne 'powershell' -or $null -ne $loader.module -or
        $loader.sha256 -cne $ToolingLoaderSha256 -or $relativeLoader -isnot [string]) {
        throw 'Authenticated PowerShell loader binding is invalid.'
    }
    $expectedLoader = if ($Mode -ceq 'checkout') {
        'scripts/tooling-bootstrap.ps1'
    }
    else { 'tooling-loader.ps1' }
    if ($relativeLoader -cne $expectedLoader) {
        throw 'Authenticated PowerShell loader binding does not match the selected layout.'
    }
    $loaderPath = [IO.Path]::GetFullPath([IO.Path]::Combine($rootPath, $relativeLoader))
    $loaderItem = Assert-DrBootstrapOrdinaryPath `
        -Path $loaderPath -Root $rootPath -Label 'PowerShell loader'
    if ($loaderItem.Length -gt 2MB) { throw 'PowerShell loader exceeds its size bound.' }
    $loaderBytes = Read-DrBootstrapBoundedBytes `
        -Path $loaderPath -MaximumBytes (2MB) -Label 'PowerShell loader'
    if ($loaderBytes.Length -gt 2MB -or
        (Get-DrBootstrapSha256 -Bytes $loaderBytes) -cne $ToolingLoaderSha256) {
        throw 'PowerShell loader hash mismatch.'
    }
    $loaderModule = $null
    try {
        $offset = if ($loaderBytes.Length -ge 3 -and $loaderBytes[0] -eq 0xef -and
            $loaderBytes[1] -eq 0xbb -and $loaderBytes[2] -eq 0xbf) { 3 } else { 0 }
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        $loaderText = $encoding.GetString($loaderBytes, $offset, $loaderBytes.Length - $offset)
        $loaderDefinitions = [scriptblock]::Create($loaderText)
        $loaderModule = Microsoft.PowerShell.Core\New-Module `
            -Name ('DarkReNamer.loader.' + [guid]::NewGuid().ToString('N')) `
            -ArgumentList $loaderDefinitions `
            -ScriptBlock {
                param([scriptblock] $Definitions)
                . $Definitions
                Microsoft.PowerShell.Core\Export-ModuleMember -Function @(
                    'Get-DrToolingVerifiedBundle'
                    'Get-DrToolingVerifiedBytes'
                    'New-DrToolingVerifiedScriptBlock'
                )
            }
        Microsoft.PowerShell.Core\Import-Module $loaderModule -Scope Local -Force | Microsoft.PowerShell.Core\Out-Null
        $verified = & $loaderModule {
            param($VerifiedRoot,$VerifiedManifest,$VerifiedManifestSha256,$VerifiedMode,$VerifiedRole)
            Get-DrToolingVerifiedBundle `
                -Root $VerifiedRoot `
                -ManifestLocation $VerifiedManifest `
                -ExpectedManifestSha256 $VerifiedManifestSha256 `
                -Mode $VerifiedMode `
                -RequiredRoles @($VerifiedRole)
        } $rootPath $ManifestLocation $ToolingManifestSha256 $Mode $RequiredRole
        [pscustomobject]@{ module = $loaderModule; verified = $verified }
    }
    catch {
        if ($null -ne $loaderModule) {
            Microsoft.PowerShell.Core\Remove-Module `
                -Name $loaderModule.Name -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

$scriptDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PSCommandPath))
$checkoutRootItem = [IO.Directory]::GetParent($scriptDirectory)
$checkoutRoot = if ($null -ne $checkoutRootItem) { $checkoutRootItem.FullName } else { $null }
$checkoutLayout = $null -ne $checkoutRoot -and
    [IO.File]::Exists([IO.Path]::Combine($scriptDirectory, 'tooling-bootstrap.ps1')) -and
    [IO.File]::Exists([IO.Path]::Combine($checkoutRoot, 'config', 'tooling-bundle.json'))
$bundleLayout =
    [IO.File]::Exists([IO.Path]::Combine($scriptDirectory, 'tooling-loader.ps1')) -and
    [IO.File]::Exists([IO.Path]::Combine($scriptDirectory, 'tooling-bundle.json'))
if ($checkoutLayout -eq $bundleLayout) {
    throw 'PowerShell tooling layout is missing or ambiguous.'
}
$toolingRoot = if ($checkoutLayout) { $checkoutRoot } else { $scriptDirectory }
$manifestLocation = if ($checkoutLayout) { 'config/tooling-bundle.json' } else { 'tooling-bundle.json' }
$toolingMode = if ($checkoutLayout) { 'checkout' } else { 'bundle' }
$loaderContext = Initialize-DrVerifiedTooling `
    -Root $toolingRoot `
    -ManifestLocation $manifestLocation `
    -Mode $toolingMode `
    -RequiredRole 'powershell-controller-entry'
$module = $null
try {
$verified = $loaderContext.verified
$transferRecords = [Collections.Generic.List[object]]::new()
foreach ($record in @($verified.Records)) {
    $recordBytes = & $loaderContext.module {
        param($VerifiedBundle,$RequestedRole)
        Get-DrToolingVerifiedBytes -VerifiedBundle $VerifiedBundle -Role $RequestedRole
    } $verified $record.Role
    $transferRecords.Add([pscustomobject]@{
        Role = [string]$record.Role
        Source = [string]$record.Source
        Bundle = [string]$record.Bundle
        Kind = [string]$record.Kind
        Module = $record.Module
        Sha256 = [string]$record.Sha256
        Dependencies = [string[]]@($record.Dependencies)
        FrozenBase64 = [Convert]::ToBase64String($recordBytes)
        Length = [long]$recordBytes.Length
    })
}
$manifestBytes = [Convert]::FromBase64String($verified.ManifestBase64)
if ((Get-DrBootstrapSha256 -Bytes $manifestBytes) -cne $verified.ManifestSha256) {
    throw 'The verified tooling manifest changed before transfer staging.'
}
$verifiedToolingTransfer = [pscustomobject]@{
    ManifestBase64 = [Convert]::ToBase64String($manifestBytes)
    ManifestSha256 = [string]$verified.ManifestSha256
    Records = $transferRecords.ToArray()
}
$definitionRoles = @(
    'powershell-controller-contracts'
    'powershell-controller-transport'
    'powershell-controller-poll'
    'powershell-controller-rescue'
)
$libraries = @{}
foreach ($role in $definitionRoles) {
    $libraries[$role] = & $loaderContext.module {
        param($VerifiedBundle,$RequestedRole)
        New-DrToolingVerifiedScriptBlock -VerifiedBundle $VerifiedBundle -Role $RequestedRole
    } $verified $role
}
$entry = & $loaderContext.module {
    param($VerifiedBundle,$RequestedRole)
    New-DrToolingVerifiedScriptBlock -VerifiedBundle $VerifiedBundle -Role $RequestedRole
} $verified 'powershell-controller-entry'
$moduleName = 'DarkReNamer.controller.' + [guid]::NewGuid().ToString('N')
$module = Microsoft.PowerShell.Core\New-Module -Name $moduleName -ScriptBlock $entry -ArgumentList (, $libraries)
    Microsoft.PowerShell.Core\Import-Module $module -Scope Local -Force | Microsoft.PowerShell.Core\Out-Null
    $invokeParameters = @{}
    foreach ($key in $PSBoundParameters.Keys) { $invokeParameters[$key] = $PSBoundParameters[$key] }
    $invokeParameters['EntryPointPath'] = $PSCommandPath
    $invokeParameters['VerifiedTooling'] = $verifiedToolingTransfer
    & $module {
        param($CommandName,$Parameters)
        & $CommandName @Parameters
    } 'Invoke-DrWindowsVmController' $invokeParameters
}
finally {
    if ($null -ne $module) {
        Microsoft.PowerShell.Core\Remove-Module `
            -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
    Microsoft.PowerShell.Core\Remove-Module `
        -Name $loaderContext.module.Name -Force -ErrorAction SilentlyContinue
}
