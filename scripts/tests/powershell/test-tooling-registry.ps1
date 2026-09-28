. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
$toolingScriptsRoot = $toolingTestPaths.ScriptsRoot

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $toolingScriptsRoot '..')).Path
$suitePath = Join-Path $toolingScriptsRoot 'test-tooling.ps1'
$actualPlatform = if ($IsWindows) { 'Windows' } else { 'Ubuntu' }
$otherPlatform = if ($IsWindows) { 'Ubuntu' } else { 'Windows' }

function Assert-True {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw $Message }
}

function New-TestEntry {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Path,
        [string[]] $Platforms = @($actualPlatform),
        [string] $Category = 'fixture',
        [bool] $RequiresVm = $false,
        [int] $Timeout = 10
    )
    [ordered]@{
        id = $Id
        path = $Path
        runner = 'PowerShell'
        platforms = $Platforms
        category = $Category
        requiresVm = $RequiresVm
        timeout = $Timeout
    }
}

function New-RegistryFixture {
    param(
        [Parameter(Mandatory)][object[]] $Entries,
        [Parameter(Mandatory)][hashtable] $Files
    )

    $root = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-tooling-$([Guid]::NewGuid().ToString('N'))"
    $scripts = Join-Path $root 'scripts'
    $config = Join-Path $root 'config'
    $null = New-Item -ItemType Directory -Path $scripts,$config
    Copy-Item -LiteralPath $suitePath -Destination (Join-Path $scripts 'test-tooling.ps1')
    $null = New-Item -ItemType Directory -Path (Join-Path $scripts 'tests/support')
    Set-Content -LiteralPath (Join-Path $scripts 'tests/support/visual-evidence-fixture.ps1') -Value '# fixture helper'
    Set-Content -LiteralPath (Join-Path $scripts 'tests/support/windows-binary-fixture.ps1') -Value '# support fixture'
    Set-Content -LiteralPath (Join-Path $scripts 'test-windows-vm.py') -Value '# VM CLI'
    foreach ($item in $Files.GetEnumerator()) {
        $path = Join-Path $root $item.Key
        $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
        Set-Content -LiteralPath $path -Value $item.Value
    }
    $registry = [ordered]@{
        version = 1
        discovery = [ordered]@{
            roots = @('scripts')
            patterns = @('test-*.ps1', 'test-*.py')
            exclusions = @(
                [ordered]@{ path = 'scripts/test-tooling.ps1'; reason = 'suite-entrypoint' }
                [ordered]@{ path = 'scripts/test-windows-vm.py'; reason = 'vm-cli' }
            )
        }
        tests = $Entries
    }
    $registry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $config 'tooling-tests.json')
    $root
}

function Invoke-RegistryFixture {
    param(
        [Parameter(Mandatory)][string] $Root,
        [string[]] $Arguments = @()
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $startInfo.WorkingDirectory = $Root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
        (Join-Path $Root 'scripts/test-tooling.ps1'), '-Platform', $actualPlatform
    ) + $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $timer.Stop()
        [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdout.GetAwaiter().GetResult()
            stderr = $stderr.GetAwaiter().GetResult()
            elapsed = $timer.Elapsed
        }
    }
    finally {
        $process.Dispose()
    }
}

function Assert-FailsWith {
    param(
        [Parameter(Mandatory)][object] $Result,
        [Parameter(Mandatory)][string] $Fragment
    )
    Assert-True ($Result.exitCode -ne 0) "Expected fixture to fail with: $Fragment"
    $combined = $Result.stdout + $Result.stderr
    Assert-True ($combined.Contains($Fragment, [StringComparison]::Ordinal)) `
        "Expected failure fragment '$Fragment', received:`n$combined"
}

$listed = Invoke-RegistryFixture -Root $repositoryRoot -Arguments @('-List')
Assert-True ($listed.exitCode -eq 0) "Repository registry failed discovery: $($listed.stderr)"

$roots = [Collections.Generic.List[string]]::new()
try {
    $selectionEntries = @(
        (New-TestEntry -Id 'common' -Path 'scripts/test-common.ps1' -Category 'smoke')
        (New-TestEntry -Id 'filtered' -Path 'scripts/test-filtered.ps1' -Category 'other')
        (New-TestEntry -Id 'other-platform' -Path 'scripts/test-other-platform.ps1' -Platforms @($otherPlatform) -Category 'smoke')
    )
    $selectionFiles = @{
        'scripts/test-common.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'common.marker') -Value ran"
        'scripts/test-filtered.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'filtered.marker') -Value ran"
        'scripts/test-other-platform.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'other.marker') -Value ran"
    }
    $root = New-RegistryFixture -Entries $selectionEntries -Files $selectionFiles
    $roots.Add($root)
    $listed = Invoke-RegistryFixture -Root $root -Arguments @('-List', '-Category', 'smoke', '-Runner', 'PowerShell')
    Assert-True ($listed.exitCode -eq 0) "List/filter fixture failed: $($listed.stderr)"
    Assert-True ($listed.stdout.Contains('common', [StringComparison]::Ordinal)) 'List must show the selected test.'
    Assert-True (-not $listed.stdout.Contains('filtered', [StringComparison]::Ordinal)) 'List must apply category filters.'
    Assert-True (-not (Test-Path (Join-Path $root 'scripts/common.marker'))) 'List must not execute selected tests.'
    $selected = Invoke-RegistryFixture -Root $root -Arguments @('-Id', 'common')
    Assert-True ($selected.exitCode -eq 0) "Id selection fixture failed: $($selected.stderr)"
    Assert-True (Test-Path (Join-Path $root 'scripts/common.marker')) 'Id selection did not execute its test.'
    Assert-True (-not (Test-Path (Join-Path $root 'scripts/filtered.marker'))) 'Id selection executed a filtered test.'
    Assert-True (-not (Test-Path (Join-Path $root 'scripts/other.marker'))) 'Platform selection executed the other platform.'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $root -Arguments @('-Category', 'unknown')) `
        -Fragment 'Unknown tooling test categories: unknown'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $root -Arguments @('-Id', 'unknown')) `
        -Fragment 'Unknown tooling test ids: unknown'

    foreach ($invalid in @(
        @{ Field = 'runner'; Value = 'powershell'; Fragment = 'Unsupported tooling runner' }
        @{ Field = 'platforms'; Value = @('ubuntu'); Fragment = 'Tooling platforms are empty, invalid, or duplicated' }
    )) {
        $entry = New-TestEntry -Id 'invalid' -Path 'scripts/test-invalid.ps1'
        $entry[$invalid.Field] = $invalid.Value
        $invalidRoot = New-RegistryFixture -Entries @($entry) `
            -Files @{ 'scripts/test-invalid.ps1' = '# never executed' }
        $roots.Add($invalidRoot)
        Assert-FailsWith -Result (Invoke-RegistryFixture -Root $invalidRoot -Arguments @('-List')) `
            -Fragment $invalid.Fragment
    }

    $failureRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'failure' -Path 'scripts/test-failure.ps1')) `
        -Files @{ 'scripts/test-failure.ps1' = "Write-Output 'failure diagnostic'; exit 7" }
    $roots.Add($failureRoot)
    $failure = Invoke-RegistryFixture -Root $failureRoot
    Assert-FailsWith -Result $failure -Fragment 'failed with exit code 7'
    Assert-True (($failure.stdout + $failure.stderr).Contains('failure diagnostic', [StringComparison]::Ordinal)) `
        'A failing child must preserve its diagnostic output.'

    $timeoutRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'timeout' -Path 'scripts/test-timeout.ps1' -Timeout 1)) `
        -Files @{ 'scripts/test-timeout.ps1' = "Write-Output 'timeout diagnostic'; Start-Sleep -Seconds 10" }
    $roots.Add($timeoutRoot)
    $timeout = Invoke-RegistryFixture -Root $timeoutRoot
    Assert-FailsWith -Result $timeout -Fragment 'timed out after 1 seconds'
    Assert-True (($timeout.stdout + $timeout.stderr).Contains('timeout diagnostic', [StringComparison]::Ordinal)) `
        'A timed-out child must preserve its diagnostic output.'
    Assert-True ($timeout.elapsed.TotalSeconds -lt 8) 'Timed-out child was not terminated promptly.'

    $missingRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'registered' -Path 'scripts/test-registered.ps1')) `
        -Files @{
            'scripts/test-registered.ps1' = '# registered'
            'scripts/test-missing.ps1' = '# missing'
        }
    $roots.Add($missingRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $missingRoot -Arguments @('-List')) `
        -Fragment 'scripts/test-missing.ps1'

    $duplicateIdRoot = New-RegistryFixture `
        -Entries @(
            (New-TestEntry -Id 'duplicate' -Path 'scripts/test-one.ps1')
            (New-TestEntry -Id 'duplicate' -Path 'scripts/test-two.ps1')
        ) `
        -Files @{'scripts/test-one.ps1' = '# one'; 'scripts/test-two.ps1' = '# two'}
    $roots.Add($duplicateIdRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $duplicateIdRoot -Arguments @('-List')) `
        -Fragment 'id is invalid or duplicated: duplicate'

    $duplicatePathRoot = New-RegistryFixture `
        -Entries @(
            (New-TestEntry -Id 'one' -Path 'scripts/test-shared.ps1')
            (New-TestEntry -Id 'two' -Path 'scripts/test-shared.ps1')
        ) `
        -Files @{'scripts/test-shared.ps1' = '# shared'}
    $roots.Add($duplicatePathRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $duplicatePathRoot -Arguments @('-List')) `
        -Fragment 'path is duplicated: scripts/test-shared.ps1'

    $unsafeRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'unsafe' -Path '../outside.ps1')) `
        -Files @{}
    $roots.Add($unsafeRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $unsafeRoot -Arguments @('-List')) `
        -Fragment '../outside.ps1'

    $excludedRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'vm-cli' -Path 'scripts/test-windows-vm.py')) `
        -Files @{}
    $roots.Add($excludedRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $excludedRoot -Arguments @('-List')) `
        -Fragment 'scripts/test-windows-vm.py'

    $fixtureHelperRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'fixture-helper' -Path 'scripts/tests/support/visual-evidence-fixture.ps1')) `
        -Files @{}
    $roots.Add($fixtureHelperRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $fixtureHelperRoot -Arguments @('-List')) `
        -Fragment 'discoverable test-*'

    $outsideScriptsRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'outside' -Path 'elsewhere/test-outside.ps1')) `
        -Files @{ 'elsewhere/test-outside.ps1' = '# outside discovery root' }
    $roots.Add($outsideScriptsRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $outsideScriptsRoot -Arguments @('-List')) `
        -Fragment 'discoverable test-*'

    $vmRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'requires-vm' -Path 'scripts/test-requires-vm.ps1' -RequiresVm $true)) `
        -Files @{ 'scripts/test-requires-vm.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'vm.marker') -Value ran" }
    $roots.Add($vmRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $vmRoot) `
        -Fragment 'refuses VM-backed test requires-vm'
    Assert-True (-not (Test-Path (Join-Path $vmRoot 'scripts/vm.marker'))) 'VM-backed test was executed.'
}
finally {
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Write-Host 'Tooling registry behavior tests passed.'
