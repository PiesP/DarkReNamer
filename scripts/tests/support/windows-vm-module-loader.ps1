. (Join-Path $PSScriptRoot 'paths.ps1')

Set-StrictMode -Version Latest

function Get-DrTestPowerShellModuleSpec {
    param([Parameter(Mandatory)][ValidateSet('guest', 'ui', 'recovery', 'controller')][string] $Kind)

    $sharedGuest = @(
        'guest-contracts.ps1'
        'guest-process.ps1'
        'guest-native.ps1'
        'guest-platform.ps1'
        'guest-uia.ps1'
        'guest-state.ps1'
        'guest-scenario.ps1'
        'guest-runtime.ps1'
    )
    $definitions = switch ($Kind) {
        'guest' { $sharedGuest }
        'ui' {
            $sharedGuest + @(
                'ui-bootstrap.ps1'
                'ui-appearance.ps1'
                'ui-native.ps1'
                'ui-menu.ps1'
                'ui-current-dpi.ps1'
                'ui-input.ps1'
                'ui-application.ps1'
                'ui-fixtures.ps1'
                'ui-context-scenarios.ps1'
                'ui-regression.ps1'
            )
        }
        'recovery' {
            $sharedGuest + @(
                'recovery-bootstrap.ps1'
                'recovery-journal.ps1'
                'recovery-evidence.ps1'
                'recovery-process.ps1'
                'recovery-native.ps1'
                'recovery-worker.ps1'
                'recovery-scenarios.ps1'
            )
        }
        'controller' {
            @(
                'controller-contracts.ps1'
                'controller-transport.ps1'
                'controller-poll.ps1'
                'controller-rescue.ps1'
            )
        }
    }
    $moduleRoot = Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell'
    [pscustomobject]@{
        kind = $Kind
        definitions = @($definitions | ForEach-Object { Join-Path $moduleRoot $_ })
        entry = Join-Path $moduleRoot "$Kind-entry.psm1"
        command = switch ($Kind) {
            'guest' { 'Invoke-DrWindowsVmGuest' }
            'ui' { 'Invoke-DrWindowsVmAcceptance' }
            'recovery' { 'Invoke-DrWindowsVmRecoveryAcceptance' }
            'controller' { 'Invoke-DrWindowsVmController' }
        }
    }
}

function Get-DrTestDefinitionScriptBlocks {
    param([Parameter(Mandatory)][string] $Kind)

    $spec = Get-DrTestPowerShellModuleSpec -Kind $Kind
    foreach ($path in $spec.definitions) {
        [scriptblock]::Create([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
    }
}

function Get-DrTestCombinedPowerShellSource {
    param([Parameter(Mandatory)][string] $Kind)

    $spec = Get-DrTestPowerShellModuleSpec -Kind $Kind
    [string]::Join("`n", @($spec.definitions + $spec.entry | ForEach-Object {
        [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8)
    }))
}

function Get-DrTestFileSha256 {
    param([Parameter(Mandatory)][string] $Path)

    (Microsoft.PowerShell.Utility\Get-FileHash `
        -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-DrTestFrozenToolingBundle {
    param(
        [Parameter(Mandatory)][string] $TaskRoot,
        [Parameter(Mandatory)][ValidateSet('guest', 'ui', 'recovery')][string] $Kind,
        [Parameter(Mandatory)][string[]] $EntrypointPaths
    )

    $spec = Get-DrTestPowerShellModuleSpec -Kind $Kind
    $records = [Collections.Generic.List[object]]::new()
    $loaderSource = Join-Path (Get-ToolingTestPaths).ScriptsRoot 'tooling-bootstrap.ps1'
    $loaderDestination = Join-Path $TaskRoot 'tooling-bootstrap.ps1'
    Copy-Item -LiteralPath $loaderSource -Destination $loaderDestination
    $loaderHash = Get-DrTestFileSha256 -Path $loaderDestination
    $records.Add([ordered]@{
        role = 'powershell-loader'
        source = 'scripts/tooling-bootstrap.ps1'
        bundle = 'tooling-bootstrap.ps1'
        kind = 'powershell'
        module = $null
        sha256 = $loaderHash
        dependencies = @()
    })

    $definitionRoles = [Collections.Generic.List[string]]::new()
    foreach ($source in $spec.definitions) {
        $leaf = [IO.Path]::GetFileName($source)
        $role = 'powershell-' + [IO.Path]::GetFileNameWithoutExtension($source)
        $destination = Join-Path $TaskRoot $leaf
        Copy-Item -LiteralPath $source -Destination $destination
        $definitionRoles.Add($role)
        $records.Add([ordered]@{
            role = $role
            source = 'scripts/modules/powershell/' + $leaf
            bundle = $leaf
            kind = 'powershell'
            module = $null
            sha256 = Get-DrTestFileSha256 -Path $destination
            dependencies = @()
        })
    }
    $entryLeaf = [IO.Path]::GetFileName($spec.entry)
    $entryDestination = Join-Path $TaskRoot $entryLeaf
    Copy-Item -LiteralPath $spec.entry -Destination $entryDestination
    $records.Add([ordered]@{
        role = "powershell-$Kind-entry"
        source = "scripts/modules/powershell/$entryLeaf"
        bundle = $entryLeaf
        kind = 'powershell'
        module = $null
        sha256 = Get-DrTestFileSha256 -Path $entryDestination
        dependencies = @('powershell-loader') + $definitionRoles.ToArray()
    })
    $manifestPath = Join-Path $TaskRoot 'tooling-bundle.json'
    [IO.File]::WriteAllText(
        $manifestPath,
        ([ordered]@{ schema_version = 1; modules = $records.ToArray() } |
            ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    $manifestHash = Get-DrTestFileSha256 -Path $manifestPath
    foreach ($entrypointPath in $EntrypointPaths) {
        $text = [IO.File]::ReadAllText($entrypointPath, [Text.Encoding]::UTF8)
        foreach ($pin in @{
            ToolingManifestSha256 = $manifestHash
            ToolingLoaderSha256 = $loaderHash
        }.GetEnumerator()) {
            $pattern = '(?m)^\$' + $pin.Key + " = '[0-9a-f]{64}'$"
            if ([regex]::Matches($text, $pattern).Count -ne 1) {
                throw "Expected one generated fixture pin: $($pin.Key)"
            }
            $text = [regex]::Replace($text, $pattern, ('$' + $pin.Key + " = '" + $pin.Value + "'"))
        }
        [IO.File]::WriteAllText($entrypointPath, $text, [Text.UTF8Encoding]::new($true))
    }
    [pscustomobject]@{
        manifest_sha256 = $manifestHash
        loader_sha256 = $loaderHash
        records = $records.ToArray()
    }
}

function Invoke-DrTestPowerShellEntrypoint {
    param(
        [Parameter(Mandatory)][ValidateSet('guest', 'ui', 'recovery', 'controller')][string] $Kind,
        [Parameter(Mandatory)][string] $EntryPointPath,
        [Parameter(Mandatory)][hashtable] $Parameters
    )

    $spec = Get-DrTestPowerShellModuleSpec -Kind $Kind
    $libraries = @{}
    foreach ($path in $spec.definitions) {
        $name = [IO.Path]::GetFileNameWithoutExtension($path)
        $libraries["powershell-$name"] = [scriptblock]::Create(
            [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        )
    }
    $entry = [scriptblock]::Create([IO.File]::ReadAllText($spec.entry, [Text.Encoding]::UTF8))
    $module = New-Module `
        -Name ('DarkReNamer.test.' + $Kind + '.' + [guid]::NewGuid().ToString('N')) `
        -ScriptBlock $entry `
        -ArgumentList (, $libraries)
    try {
        Import-Module $module -Scope Local -Force | Out-Null
        $invokeParameters = @{} + $Parameters
        $invokeParameters['EntryPointPath'] = $EntryPointPath
        & $spec.command @invokeParameters
    }
    finally {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
}
