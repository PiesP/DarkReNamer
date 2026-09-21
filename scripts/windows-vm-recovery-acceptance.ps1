[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BundleRoot,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $ExpectedSessionId,

    [Parameter(Mandatory)]
    [string] $OutputRoot,

    [Parameter(Mandatory)]
    [string] $PrivateEvidenceRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string] $ExpectedScriptSha256,

    [ValidateSet('ProcessCrash', 'WorkerCancellation', 'WorkerClose')]
    [string] $Mode = 'ProcessCrash',

    [ValidateRange(128, 10000)]
    [int] $FixtureCount = 4096,

    [ValidateRange(10, 600)]
    [int] $TimeoutSeconds = 300,

    [switch] $RecoveryExport,

    [switch] $IntentOnlyCandidateDiscard,

    [switch] $ValidateOnly
)
Set-StrictMode -Version Latest
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

$toolingRoot = [IO.Path]::GetDirectoryName($PSCommandPath)
$manifestLocation = 'tooling-bundle.json'
$loaderContext = Initialize-DrVerifiedTooling `
    -Root $toolingRoot `
    -ManifestLocation $manifestLocation `
    -Mode 'bundle' `
    -RequiredRole 'powershell-recovery-entry'
$module = $null
try {
$verified = $loaderContext.verified
$definitionRoles = @(
    'powershell-guest-contracts'
    'powershell-guest-process'
    'powershell-guest-native'
    'powershell-guest-platform'
    'powershell-guest-uia'
    'powershell-guest-state'
    'powershell-guest-scenario'
    'powershell-guest-runtime'
    'powershell-recovery-bootstrap'
    'powershell-recovery-journal'
    'powershell-recovery-evidence'
    'powershell-recovery-process'
    'powershell-recovery-native'
    'powershell-recovery-worker'
    'powershell-recovery-scenarios'
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
} $verified 'powershell-recovery-entry'
$moduleName = 'DarkReNamer.recovery.' + [guid]::NewGuid().ToString('N')
$module = Microsoft.PowerShell.Core\New-Module -Name $moduleName -ScriptBlock $entry -ArgumentList (, $libraries)
    Microsoft.PowerShell.Core\Import-Module $module -Scope Local -Force | Microsoft.PowerShell.Core\Out-Null
    $invokeParameters = @{}
    foreach ($key in $PSBoundParameters.Keys) { $invokeParameters[$key] = $PSBoundParameters[$key] }
    $invokeParameters['EntryPointPath'] = $PSCommandPath
    & $module {
        param($CommandName,$Parameters)
        & $CommandName @Parameters
    } 'Invoke-DrWindowsVmRecoveryAcceptance' $invokeParameters
}
finally {
    if ($null -ne $module) {
        Microsoft.PowerShell.Core\Remove-Module `
            -Name $module.Name -Force -ErrorAction SilentlyContinue
    }
    Microsoft.PowerShell.Core\Remove-Module `
        -Name $loaderContext.module.Name -Force -ErrorAction SilentlyContinue
}
