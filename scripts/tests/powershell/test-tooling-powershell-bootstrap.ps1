. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
$toolingScriptsRoot = $toolingTestPaths.ScriptsRoot

$ErrorActionPreference = 'Stop'

$bootstrapPath = Join-Path $toolingScriptsRoot 'tooling-bootstrap.ps1'
$script:DrTestRoots = [Collections.Generic.List[string]]::new()
$script:DrTestAssertions = 0
$script:DrTestUtf8 = [Text.UTF8Encoding]::new($false)

function Assert-DrTestTrue {
    param([bool] $Condition, [string] $Message)
    $script:DrTestAssertions++
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-DrTestThrows {
    param([scriptblock] $Action, [string] $Message, [string] $ExpectedMessage)
    $script:DrTestAssertions++
    try {
        & $Action
    }
    catch {
        if ($PSBoundParameters.ContainsKey('ExpectedMessage') -and
                $_.Exception.Message -cne $ExpectedMessage) {
            throw "$Message Expected '$ExpectedMessage'; got '$($_.Exception.Message)'."
        }
        return
    }
    throw $Message
}

function Assert-DrPublicPickerBinding {
    # Execute the actual public parameter declaration with an inert body. This
    # exercises PowerShell's binder without entering the controller or guest.
    foreach ($case in @(
        [ordered]@{leaf='run-windows-vm-tests.ps1'; parameter='AcceptanceMode';
            arguments=@{BundleRoot='unused';VmName='fixture';CredentialHelper='unused'}},
        [ordered]@{leaf='windows-vm-acceptance.ps1'; parameter='RegressionMode';
            arguments=@{BundleRoot='unused';ExpectedSessionId=1;OutputRoot='unused';
                ExpectedScriptSha256=('0' * 64)}})) {
        foreach ($suffix in @('', '.in')) {
            $path = Join-Path $toolingScriptsRoot ($case.leaf + $suffix)
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                $path, [ref]$tokens, [ref]$errors)
            Assert-DrTestTrue -Condition ($null -ne $ast.ParamBlock) `
                -Message "Public $($case.leaf)$suffix parameter block is missing."
            $binder = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n'bound'")
            $arguments = @{} + $case.arguments
            $arguments[$case.parameter] = 'picker-identity-observation'
            Assert-DrTestTrue -Condition ((& $binder @arguments) -ceq 'bound') `
                -Message "Public $($case.leaf)$suffix rejected picker before its body."
            $arguments[$case.parameter] = 'unsupported-picker-mode'
            Assert-DrTestThrows -Action { & $binder @arguments | Out-Null } `
                -Message "Public $($case.leaf)$suffix accepted an unknown mode."
        }
        $generated = Get-Command -Name (Join-Path $toolingScriptsRoot $case.leaf) `
            -CommandType ExternalScript -ErrorAction Stop
        $validateSet = @($generated.Parameters[$case.parameter].Attributes |
            Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] })
        Assert-DrTestTrue -Condition ($validateSet.Count -eq 1 -and
            $validateSet[0].ValidValues -ccontains 'picker-identity-observation') `
            -Message "Generated public $($case.leaf) metadata lacks the picker mode."
    }
}

function Get-DrTestSha256 {
    param([byte[]] $Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Write-DrTestBytes {
    param([string] $Path, [byte[]] $Bytes)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($parent)) {
        [void] [IO.Directory]::CreateDirectory($parent)
    }
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function Write-DrTestText {
    param([string] $Path, [string] $Text)
    Write-DrTestBytes -Path $Path -Bytes $script:DrTestUtf8.GetBytes($Text)
}

function Get-DrTestModulePath {
    param([object] $Fixture, [object] $Entry)
    $relative = if ($Fixture.Mode -ceq 'checkout') { $Entry.source } else { $Entry.bundle }
    $path = $Fixture.Root
    foreach ($component in $relative.Split('/')) {
        $path = Join-Path $path $component
    }
    return $path
}

function Write-DrTestModules {
    param([object] $Fixture)
    foreach ($entry in $Fixture.Entries) {
        Write-DrTestBytes `
            -Path (Get-DrTestModulePath -Fixture $Fixture -Entry $entry) `
            -Bytes $Fixture.Sources[$entry.role]
    }
}

function Write-DrTestManifest {
    param([object] $Fixture, [byte[]] $RawBytes)
    $bytes = $RawBytes
    if ($null -eq $bytes) {
        $value = [ordered]@{
            schema_version = 1
            modules = [object[]] $Fixture.Entries
        }
        $bytes = $script:DrTestUtf8.GetBytes(($value | ConvertTo-Json -Depth 10) + "`n")
    }
    Write-DrTestBytes -Path $Fixture.ManifestPath -Bytes $bytes
    return Get-DrTestSha256 -Bytes $bytes
}

function New-DrTestFixture {
    param([string] $Mode = 'checkout')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-tooling-' + [guid]::NewGuid().ToString('N'))
    [void] [IO.Directory]::CreateDirectory($root)
    $script:DrTestRoots.Add($root)

    $packageBytes = $script:DrTestUtf8.GetBytes("PACKAGE_VALUE = 'verified'`n")
    $commonBytes = $script:DrTestUtf8.GetBytes(
        "`$global:DrToolingExecutionMarker = 'original'`n" +
        "function Get-DrFixtureValue { 'verified' }`n"
    )
    $guestBytes = $script:DrTestUtf8.GetBytes("function Get-DrGuestValue { 'guest' }`n")
    $loaderBytes = $script:DrTestUtf8.GetBytes(
        "function Get-DrFixtureLoaderValue { 'loader' }`n"
    )
    $sources = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::Ordinal)
    $sources.Add('package-root', $packageBytes)
    $sources.Add('powershell-controller-contracts', $commonBytes)
    $sources.Add('powershell-guest-contracts', $guestBytes)
    $sources.Add('powershell-loader', $loaderBytes)

    $entries = [Collections.Generic.List[object]]::new()
    $entries.Add([pscustomobject][ordered]@{
        role = 'package-root'
        source = 'scripts/darkrenamer_tooling/__init__.py'
        bundle = 'tooling-package-root.py'
        kind = 'python-package'
        module = 'darkrenamer_tooling'
        sha256 = Get-DrTestSha256 -Bytes $packageBytes
        dependencies = [object[]] @()
    })
    $entries.Add([pscustomobject][ordered]@{
        role = 'powershell-controller-contracts'
        source = 'scripts/tooling/common.psm1'
        bundle = 'tooling-common.psm1'
        kind = 'powershell'
        module = $null
        sha256 = Get-DrTestSha256 -Bytes $commonBytes
        dependencies = [object[]] @()
    })
    $entries.Add([pscustomobject][ordered]@{
        role = 'powershell-guest-contracts'
        source = 'scripts/tooling/guest.ps1'
        bundle = 'tooling-guest.ps1'
        kind = 'powershell'
        module = $null
        sha256 = Get-DrTestSha256 -Bytes $guestBytes
        dependencies = [object[]] @('powershell-controller-contracts')
    })
    $entries.Add([pscustomobject][ordered]@{
        role = 'powershell-loader'
        source = 'scripts/tooling-bootstrap.ps1'
        bundle = 'tooling-bootstrap.ps1'
        kind = 'powershell'
        module = $null
        sha256 = Get-DrTestSha256 -Bytes $loaderBytes
        dependencies = [object[]] @()
    })

    $manifestLocation = if ($Mode -ceq 'checkout') {
        'config/tooling-bundle.json'
    }
    else {
        'tooling-bundle.json'
    }
    $manifestPath = $root
    foreach ($component in $manifestLocation.Split('/')) {
        $manifestPath = Join-Path $manifestPath $component
    }
    $fixture = [pscustomobject]@{
        Root = $root
        Mode = $Mode
        ManifestLocation = $manifestLocation
        ManifestPath = $manifestPath
        Sources = $sources
        Entries = $entries
    }
    Write-DrTestModules -Fixture $fixture
    [void] (Write-DrTestManifest -Fixture $fixture)
    return $fixture
}

function Get-DrTestVerified {
    param([object] $Fixture, [string[]] $RequiredRoles = @('powershell-controller-contracts'))
    $digest = Write-DrTestManifest -Fixture $Fixture
    return Get-DrToolingVerifiedBundle `
        -Root $Fixture.Root `
        -ManifestLocation $Fixture.ManifestLocation `
        -ExpectedManifestSha256 $digest `
        -Mode $Fixture.Mode `
        -RequiredRoles $RequiredRoles
}

try {
    $bootstrapBytes = [IO.File]::ReadAllBytes($bootstrapPath)
    Assert-DrTestTrue `
        -Condition ($bootstrapBytes.Length -ge 3 -and
            $bootstrapBytes[0] -eq 0xef -and
            $bootstrapBytes[1] -eq 0xbb -and
            $bootstrapBytes[2] -eq 0xbf) `
        -Message 'tooling-bootstrap.ps1 must retain its UTF-8 BOM.'
    $testBytes = [IO.File]::ReadAllBytes($PSCommandPath)
    Assert-DrTestTrue `
        -Condition ($testBytes.Length -ge 3 -and
            $testBytes[0] -eq 0xef -and
            $testBytes[1] -eq 0xbb -and
            $testBytes[2] -eq 0xbf) `
        -Message 'test-tooling-powershell-bootstrap.ps1 must retain its UTF-8 BOM.'

    $tokens = $null
    $parseErrors = $null
    $bootstrapAst = [Management.Automation.Language.Parser]::ParseFile(
        $bootstrapPath,
        [ref] $tokens,
        [ref] $parseErrors
    )
    Assert-DrTestTrue -Condition ($parseErrors.Count -eq 0) -Message 'Bootstrap source must parse.'
    foreach ($statement in $bootstrapAst.EndBlock.Statements) {
        Assert-DrTestTrue `
            -Condition ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) `
            -Message 'Bootstrap import must contain function definitions only.'
    }
    $bootstrapFunctions = $bootstrapAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true)
    foreach ($functionAst in $bootstrapFunctions) {
        Assert-DrTestTrue `
            -Condition ($functionAst.Name -match '-DrTooling') `
            -Message "Bootstrap function lacks the DrTooling prefix: $($functionAst.Name)."
    }
    Assert-DrPublicPickerBinding

    # The controller transfers this verified source to the guest before using
    # either the original finalizer or the maintained read-only collector.
    . (Join-Path $toolingScriptsRoot 'modules/powershell/controller-owned-root-guard.ps1')
    Add-Type -TypeDefinition $script:DrOwnedRootGuardSource -ErrorAction Stop
    Assert-DrTestTrue `
        -Condition ($null -ne ([DarkReNamerVmOwnedRootGuard].GetMethod(
            'ContentIndex', [type[]]@([int], [long])))) `
        -Message 'Verified owned root guard lacks bounded held content indexing.'

    Remove-Variable -Name DrToolingExecutionMarker -Scope Global -ErrorAction SilentlyContinue
    . $bootstrapPath
    Assert-DrTestTrue `
        -Condition (-not (Test-Path Variable:global:DrToolingExecutionMarker)) `
        -Message 'Dot-sourcing the bootstrap executed module code.'
    foreach ($name in @(
            'Get-DrToolingVerifiedBundle',
            'Get-DrToolingVerifiedBytes',
            'New-DrToolingVerifiedScriptBlock'
        )) {
        Assert-DrTestTrue `
            -Condition ($null -ne (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) `
            -Message "Missing public bootstrap function: $name."
    }

    foreach ($mode in @('checkout', 'bundle')) {
        $fixture = New-DrTestFixture -Mode $mode
        $verified = Get-DrTestVerified `
            -Fixture $fixture `
            -RequiredRoles @('package-root', 'powershell-controller-contracts')
        Assert-DrTestTrue -Condition ($verified.Mode -ceq $mode) -Message "Wrong mode for $mode."
        Assert-DrTestTrue -Condition ($verified.Records.Count -eq 2) -Message 'Wrong closure size.'
        Assert-DrTestTrue `
            -Condition (-not (Test-Path Variable:global:DrToolingExecutionMarker)) `
            -Message 'Verification executed a PowerShell module.'
        $pythonBytes = Get-DrToolingVerifiedBytes -VerifiedBundle $verified -Role 'package-root'
        Assert-DrTestTrue `
            -Condition ((Get-DrTestSha256 -Bytes $pythonBytes) -ceq $fixture.Entries[0].sha256) `
            -Message 'Python bytes were not frozen in the verified closure.'
        $scriptBlock = New-DrToolingVerifiedScriptBlock `
            -VerifiedBundle $verified `
            -Role 'powershell-controller-contracts'
        & $scriptBlock
        Assert-DrTestTrue `
            -Condition ($global:DrToolingExecutionMarker -ceq 'original') `
            -Message 'Verified ScriptBlock did not execute frozen bytes.'
        Remove-Variable -Name DrToolingExecutionMarker -Scope Global -ErrorAction SilentlyContinue
    }

    $fixture = New-DrTestFixture
    $loaderVerified = Get-DrTestVerified -Fixture $fixture -RequiredRoles @('powershell-loader')
    Assert-DrTestTrue `
        -Condition ($loaderVerified.Records[0].Role -ceq 'powershell-loader') `
        -Message 'The definitions-only PowerShell loader role was not accepted.'

    $fixture = New-DrTestFixture
    $manifestDigest = Write-DrTestManifest -Fixture $fixture
    Remove-Item -LiteralPath (Get-DrTestModulePath -Fixture $fixture -Entry $fixture.Entries[2])
    Assert-DrTestThrows -Message 'Missing later dependency was accepted.' -Action {
        Get-DrToolingVerifiedBundle `
            -Root $fixture.Root `
            -ManifestLocation $fixture.ManifestLocation `
            -ExpectedManifestSha256 $manifestDigest `
            -Mode checkout `
            -RequiredRoles @('powershell-guest-contracts')
    }
    Assert-DrTestTrue `
        -Condition (-not (Test-Path Variable:global:DrToolingExecutionMarker)) `
        -Message 'Missing dependency caused earlier module execution.'
    Write-DrTestText `
        -Path (Get-DrTestModulePath -Fixture $fixture -Entry $fixture.Entries[2]) `
        -Text 'tampered'
    Assert-DrTestThrows -Message 'Tampered later dependency was accepted.' -Action {
        Get-DrToolingVerifiedBundle `
            -Root $fixture.Root `
            -ManifestLocation $fixture.ManifestLocation `
            -ExpectedManifestSha256 $manifestDigest `
            -Mode checkout `
            -RequiredRoles @('powershell-guest-contracts')
    }

    $fixture = New-DrTestFixture
    $invalidBytes = $script:DrTestUtf8.GetBytes('function Broken-DrToolingModule {')
    $fixture.Sources['powershell-guest-contracts'] = $invalidBytes
    $fixture.Entries[2].sha256 = Get-DrTestSha256 -Bytes $invalidBytes
    Write-DrTestModules -Fixture $fixture
    Assert-DrTestThrows -Message 'Later invalid PowerShell was accepted.' -Action {
        Get-DrTestVerified -Fixture $fixture -RequiredRoles @('powershell-guest-contracts')
    }
    Assert-DrTestTrue `
        -Condition (-not (Test-Path Variable:global:DrToolingExecutionMarker)) `
        -Message 'Later syntax failure caused earlier module execution.'

    $fixture = New-DrTestFixture
    $validDigest = Write-DrTestManifest -Fixture $fixture
    Assert-DrTestThrows -Message 'Wrong manifest digest was accepted.' -Action {
        Get-DrToolingVerifiedBundle `
            -Root $fixture.Root `
            -ManifestLocation $fixture.ManifestLocation `
            -ExpectedManifestSha256 ('0' * 64) `
            -Mode checkout `
            -RequiredRoles @('powershell-controller-contracts')
    }
    $fixture.Entries[1].role = 'unknown-role'
    Assert-DrTestThrows -Message 'Unknown role was accepted.' -Action {
        Get-DrTestVerified -Fixture $fixture
    }
    $fixture.Entries[1].role = 'powershell-controller-contracts'
    foreach ($role in @(
            'powershell-common', 'powershell-guest', 'powershell-ui-observer',
            'powershell-recovery-observer', 'release-tooling'
        )) {
        $retiredFixture = New-DrTestFixture
        $verifiedFixture = Get-DrTestVerified -Fixture $retiredFixture
        Assert-DrTestTrue `
            -Condition ($verifiedFixture.Records[0].Role -ceq 'powershell-controller-contracts') `
            -Message "Supported fixture was rejected before testing retired role $role."
        $retiredBytes = $script:DrTestUtf8.GetBytes("function Get-DrRetiredFixtureValue { 'retired' }`n")
        $retiredFixture.Sources.Add($role, $retiredBytes)
        $retiredFixture.Entries.Add([pscustomobject][ordered]@{
            role = $role
            source = 'scripts/tooling/retired.psm1'
            bundle = 'tooling-retired.psm1'
            kind = 'powershell'
            module = $null
            sha256 = Get-DrTestSha256 -Bytes $retiredBytes
            dependencies = [object[]] @()
        })
        Write-DrTestModules -Fixture $retiredFixture
        Assert-DrTestThrows `
            -Message "Retired role $role was accepted." `
            -ExpectedMessage "Unsupported tooling role: $role" `
            -Action {
                Get-DrTestVerified -Fixture $retiredFixture -RequiredRoles @($role) | Out-Null
            }
    }
    $fixture.Entries[1].dependencies = [object[]] @('missing-role')
    Assert-DrTestThrows -Message 'Unknown dependency was accepted.' -Action {
        Get-DrTestVerified -Fixture $fixture
    }
    $fixture.Entries[1].dependencies = [object[]] @()
    $fixture.Entries[1].kind = 'python'
    Assert-DrTestThrows -Message 'Wrong role kind was accepted.' -Action {
        Get-DrTestVerified -Fixture $fixture
    }
    Assert-DrTestTrue -Condition ($validDigest.Length -eq 64) -Message 'Fixture digest is invalid.'

    foreach ($case in @(
            @{ Field = 'source'; Value = '../common.psm1' },
            @{ Field = 'source'; Value = 'scripts/CON.psm1' },
            @{ Field = 'bundle'; Value = 'nested/common.psm1' },
            @{ Field = 'bundle'; Value = 'NUL.psm1' }
        )) {
        $fixture = New-DrTestFixture
        $fixture.Entries[1].($case.Field) = $case.Value
        Assert-DrTestThrows -Message "Unsafe $($case.Field) was accepted." -Action {
            Get-DrTestVerified -Fixture $fixture
        }
    }

    $fixture = New-DrTestFixture
    $collision = [pscustomobject][ordered]@{
        role = 'powershell-ui-bootstrap'
        source = $fixture.Entries[1].source.ToUpperInvariant()
        bundle = 'tooling-release.psm1'
        kind = 'powershell'
        module = $null
        sha256 = $fixture.Entries[1].sha256
        dependencies = [object[]] @()
    }
    $fixture.Entries.Add($collision)
    Assert-DrTestThrows -Message 'Case-colliding source paths were accepted.' -Action {
        Get-DrTestVerified -Fixture $fixture
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $fixture = New-DrTestFixture
        $commonPath = Get-DrTestModulePath -Fixture $fixture -Entry $fixture.Entries[1]
        $targetPath = Join-Path $fixture.Root 'outside-common.psm1'
        Write-DrTestBytes -Path $targetPath -Bytes $fixture.Sources['powershell-controller-contracts']
        Remove-Item -LiteralPath $commonPath
        [void] (New-Item -ItemType SymbolicLink -Path $commonPath -Target $targetPath)
        Assert-DrTestThrows -Message 'Linked module was accepted.' -Action {
            Get-DrTestVerified -Fixture $fixture
        }
    }

    $fixture = New-DrTestFixture
    $commonPath = Get-DrTestModulePath -Fixture $fixture -Entry $fixture.Entries[1]
    Remove-Item -LiteralPath $commonPath
    [void] [IO.Directory]::CreateDirectory($commonPath)
    Assert-DrTestThrows -Message 'Directory module was accepted as an ordinary file.' -Action {
        Get-DrTestVerified -Fixture $fixture
    }

    $fixture = New-DrTestFixture
    $realTooling = Join-Path $fixture.Root 'real-tooling'
    [void] [IO.Directory]::CreateDirectory($realTooling)
    Write-DrTestBytes `
        -Path (Join-Path $realTooling 'common.psm1') `
        -Bytes $fixture.Sources['powershell-controller-contracts']
    $linkedTooling = Join-Path (Join-Path $fixture.Root 'scripts') 'linked-tooling'
    $linkType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        'Junction'
    }
    else {
        'SymbolicLink'
    }
    [void] (New-Item -ItemType $linkType -Path $linkedTooling -Target $realTooling)
    $fixture.Entries[1].source = 'scripts/linked-tooling/common.psm1'
    Assert-DrTestThrows -Message 'Linked module ancestor was accepted.' -Action {
        Get-DrTestVerified -Fixture $fixture
    }

    $fixture = New-DrTestFixture
    $duplicateJson = $script:DrTestUtf8.GetBytes(
        '{"schema_version":1,"schema_version":1,"modules":[]}'
    )
    $duplicateDigest = Write-DrTestManifest -Fixture $fixture -RawBytes $duplicateJson
    Assert-DrTestThrows -Message 'Duplicate JSON keys were accepted.' -Action {
        Get-DrToolingVerifiedBundle `
            -Root $fixture.Root `
            -ManifestLocation $fixture.ManifestLocation `
            -ExpectedManifestSha256 $duplicateDigest `
            -Mode checkout `
            -RequiredRoles @('powershell-controller-contracts')
    }
    $escapedDuplicateJson = $script:DrTestUtf8.GetBytes(
        '{"schem\u0061_version":1,"schema_version":1,"modules":[]}'
    )
    $escapedDuplicateDigest = Write-DrTestManifest `
        -Fixture $fixture `
        -RawBytes $escapedDuplicateJson
    Assert-DrTestThrows -Message 'Escaped duplicate JSON keys were accepted.' -Action {
        Get-DrToolingVerifiedBundle `
            -Root $fixture.Root `
            -ManifestLocation $fixture.ManifestLocation `
            -ExpectedManifestSha256 $escapedDuplicateDigest `
            -Mode checkout `
            -RequiredRoles @('powershell-controller-contracts')
    }

    $fixture = New-DrTestFixture
    $extraManifest = [ordered]@{
        schema_version = 1
        modules = [object[]] $fixture.Entries
        extra = $false
    }
    $extraBytes = $script:DrTestUtf8.GetBytes(
        ($extraManifest | ConvertTo-Json -Depth 10) + "`n"
    )
    $extraDigest = Write-DrTestManifest -Fixture $fixture -RawBytes $extraBytes
    Assert-DrTestThrows -Message 'Extra manifest fields were accepted.' -Action {
        Get-DrToolingVerifiedBundle `
            -Root $fixture.Root `
            -ManifestLocation $fixture.ManifestLocation `
            -ExpectedManifestSha256 $extraDigest `
            -Mode checkout `
            -RequiredRoles @('powershell-controller-contracts')
    }

    $fixture = New-DrTestFixture
    $fixture.Entries[1].dependencies = [object[]] @('powershell-guest-contracts')
    Assert-DrTestThrows -Message 'Dependency cycle was accepted.' -Action {
        Get-DrTestVerified -Fixture $fixture -RequiredRoles @('powershell-guest-contracts')
    }

    $fixture = New-DrTestFixture
    $manifestBytes = $script:DrTestUtf8.GetBytes(
        (([ordered]@{ schema_version = 1; modules = [object[]] $fixture.Entries } |
            ConvertTo-Json -Depth 10) + (' ' * (512 * 1024)))
    )
    $oversizeDigest = Write-DrTestManifest -Fixture $fixture -RawBytes $manifestBytes
    Assert-DrTestThrows -Message 'Oversized manifest was accepted.' -Action {
        Get-DrToolingVerifiedBundle `
            -Root $fixture.Root `
            -ManifestLocation $fixture.ManifestLocation `
            -ExpectedManifestSha256 $oversizeDigest `
            -Mode checkout `
            -RequiredRoles @('powershell-controller-contracts')
    }

    $fixture = New-DrTestFixture
    $oversizedModule = [byte[]]::new((8 * 1024 * 1024) + 1)
    $fixture.Sources['powershell-controller-contracts'] = $oversizedModule
    $fixture.Entries[1].sha256 = Get-DrTestSha256 -Bytes $oversizedModule
    Write-DrTestModules -Fixture $fixture
    Assert-DrTestThrows -Message 'Oversized module was accepted.' -Action {
        Get-DrTestVerified -Fixture $fixture
    }

    $fixture = New-DrTestFixture
    $fixture.Entries[1].dependencies = [object[]] @('package-root')
    Write-DrTestText `
        -Path (Get-DrTestModulePath -Fixture $fixture -Entry $fixture.Entries[0]) `
        -Text 'tampered python initializer'
    Assert-DrTestThrows -Message 'Tampered Python dependency was accepted.' -Action {
        Get-DrTestVerified -Fixture $fixture -RequiredRoles @('powershell-controller-contracts')
    }
    Assert-DrTestTrue `
        -Condition (-not (Test-Path Variable:global:DrToolingExecutionMarker)) `
        -Message 'Tampered Python dependency caused PowerShell execution.'

    $fixture = New-DrTestFixture
    $manifestDigest = Write-DrTestManifest -Fixture $fixture
    & {
        function Get-Item { throw 'shadowed Get-Item ran' }
        function Join-Path { throw 'shadowed Join-Path ran' }
        function ConvertFrom-Json { throw 'shadowed ConvertFrom-Json ran' }
        function Where-Object { throw 'shadowed Where-Object ran' }
        function Write-Output { throw 'shadowed Write-Output ran' }

        $shadowVerified = Get-DrToolingVerifiedBundle `
            -Root $fixture.Root `
            -ManifestLocation $fixture.ManifestLocation `
            -ExpectedManifestSha256 $manifestDigest `
            -Mode checkout `
            -RequiredRoles @('powershell-controller-contracts')
        $shadowBytes = Get-DrToolingVerifiedBytes `
            -VerifiedBundle $shadowVerified `
            -Role 'powershell-controller-contracts'
        Assert-DrTestTrue `
            -Condition ((Get-DrTestSha256 -Bytes $shadowBytes) -ceq $fixture.Entries[1].sha256) `
            -Message 'A shadowed built-in command changed verified bytes.'
        $shadowScriptBlock = New-DrToolingVerifiedScriptBlock `
            -VerifiedBundle $shadowVerified `
            -Role 'powershell-controller-contracts'
        & $shadowScriptBlock
        Assert-DrTestTrue `
            -Condition ($global:DrToolingExecutionMarker -ceq 'original') `
            -Message 'A shadowed built-in command changed verified execution.'
    }
    Remove-Variable -Name DrToolingExecutionMarker -Scope Global -ErrorAction SilentlyContinue

    $fixture = New-DrTestFixture
    $verified = Get-DrTestVerified -Fixture $fixture
    $mutatedBytes = $script:DrTestUtf8.GetBytes(
        "`$global:DrToolingExecutionMarker = 'mutated-public'`n"
    )
    $verified.Records[0].FrozenBase64 = [Convert]::ToBase64String($mutatedBytes)
    $verified.Records[0].Length = $mutatedBytes.Length
    $verified.Records[0].Sha256 = Get-DrTestSha256 -Bytes $mutatedBytes
    $verified.Records[0].Kind = 'powershell'
    $verifiedBytes = Get-DrToolingVerifiedBytes `
        -VerifiedBundle $verified `
        -Role 'powershell-controller-contracts'
    Assert-DrTestTrue `
        -Condition ((Get-DrTestSha256 -Bytes $verifiedBytes) -ceq $fixture.Entries[1].sha256) `
        -Message 'Mutated public closure data changed verified bytes.'
    $scriptBlock = New-DrToolingVerifiedScriptBlock `
        -VerifiedBundle $verified `
        -Role 'powershell-controller-contracts'
    & $scriptBlock
    Assert-DrTestTrue `
        -Condition ($global:DrToolingExecutionMarker -ceq 'original') `
        -Message 'Mutated public closure data changed verified execution.'
    Remove-Variable -Name DrToolingExecutionMarker -Scope Global -ErrorAction SilentlyContinue

    $forgedBytes = $script:DrTestUtf8.GetBytes(
        "`$global:DrToolingExecutionMarker = 'forged'`n"
    )
    $forgedRecord = [pscustomobject]@{
        Role = 'powershell-controller-contracts'
        Kind = 'powershell'
        FrozenBase64 = [Convert]::ToBase64String($forgedBytes)
        Length = $forgedBytes.Length
        Sha256 = Get-DrTestSha256 -Bytes $forgedBytes
    }
    $forgedBundle = [pscustomobject]@{ Records = [object[]] @($forgedRecord) }
    $forgedBundle.PSObject.TypeNames.Insert(0, 'DarkReNamer.Tooling.VerifiedBundle')
    Assert-DrTestThrows -Message 'A forged verified-bundle handle returned bytes.' -Action {
        Get-DrToolingVerifiedBytes `
            -VerifiedBundle $forgedBundle `
            -Role 'powershell-controller-contracts'
    }
    Assert-DrTestThrows -Message 'A forged verified-bundle handle produced a ScriptBlock.' -Action {
        New-DrToolingVerifiedScriptBlock `
            -VerifiedBundle $forgedBundle `
            -Role 'powershell-controller-contracts'
    }

    $fixture = New-DrTestFixture
    $verified = Get-DrTestVerified -Fixture $fixture
    Write-DrTestText `
        -Path (Get-DrTestModulePath -Fixture $fixture -Entry $fixture.Entries[1]) `
        -Text "`$global:DrToolingExecutionMarker = 'mutated'`n"
    $scriptBlock = New-DrToolingVerifiedScriptBlock `
        -VerifiedBundle $verified `
        -Role 'powershell-controller-contracts'
    & $scriptBlock
    Assert-DrTestTrue `
        -Condition ($global:DrToolingExecutionMarker -ceq 'original') `
        -Message 'Post-verification file mutation changed executed bytes.'
    Remove-Variable -Name DrToolingExecutionMarker -Scope Global -ErrorAction SilentlyContinue

    Write-Host "PowerShell tooling bootstrap tests passed ($script:DrTestAssertions assertions)."
}
finally {
    Remove-Variable -Name DrToolingExecutionMarker -Scope Global -ErrorAction SilentlyContinue
    foreach ($root in $script:DrTestRoots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}
