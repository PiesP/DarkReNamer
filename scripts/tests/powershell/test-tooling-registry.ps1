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
        [string] $Scope = 'current',
        [string] $Runner = 'PowerShell',
        [bool] $RequiresVm = $false,
        [int] $Timeout = 10
    )
    [ordered]@{
        id = $Id
        path = $Path
        runner = $Runner
        platforms = $Platforms
        scope = $Scope
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
    Set-Content -LiteralPath (Join-Path $scripts 'tests/support/fixture-helper.ps1') -Value '# fixture helper'
    Set-Content -LiteralPath (Join-Path $scripts 'tests/support/windows-binary-fixture.ps1') -Value '# support fixture'
    Set-Content -LiteralPath (Join-Path $scripts 'test-windows-vm.py') -Value '# VM CLI'
    foreach ($item in $Files.GetEnumerator()) {
        $path = Join-Path $root $item.Key
        $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
        Set-Content -LiteralPath $path -Value $item.Value
    }
    $registry = [ordered]@{
        version = 2
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
        (New-TestEntry -Id 'diagnostic' -Path 'scripts/test-diagnostic.ps1' -Category 'smoke' -Scope 'diagnostics')
        (New-TestEntry -Id 'historical' -Path 'scripts/test-historical.ps1' -Category 'smoke' -Scope 'historical')
        (New-TestEntry -Id 'other-platform' -Path 'scripts/test-other-platform.ps1' -Platforms @($otherPlatform) -Category 'smoke')
    )
    $selectionFiles = @{
        'scripts/test-common.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'common.marker') -Value ran"
        'scripts/test-filtered.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'filtered.marker') -Value ran"
        'scripts/test-diagnostic.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'diagnostic.marker') -Value ran"
        'scripts/test-historical.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'historical.marker') -Value ran"
        'scripts/test-other-platform.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'other.marker') -Value ran"
    }
    $root = New-RegistryFixture -Entries $selectionEntries -Files $selectionFiles
    $roots.Add($root)
    $listed = Invoke-RegistryFixture -Root $root -Arguments @('-List', '-Category', 'smoke', '-Runner', 'PowerShell')
    Assert-True ($listed.exitCode -eq 0) "List/filter fixture failed: $($listed.stderr)"
    Assert-True ($listed.stdout.Contains('common', [StringComparison]::Ordinal)) 'List must show the selected test.'
    Assert-True (-not $listed.stdout.Contains('filtered', [StringComparison]::Ordinal)) 'List must apply category filters.'
    Assert-True (-not (Test-Path (Join-Path $root 'scripts/common.marker'))) 'List must not execute selected tests.'
    Assert-True (-not $listed.stdout.Contains('diagnostic', [StringComparison]::Ordinal)) 'Category must keep the default current scope.'
    Assert-True (-not $listed.stdout.Contains('historical', [StringComparison]::Ordinal)) 'Category must not opt into historical tests.'
    $runnerListed = Invoke-RegistryFixture -Root $root -Arguments @('-List', '-Runner', 'PowerShell')
    Assert-True ($runnerListed.exitCode -eq 0) "Runner selection failed: $($runnerListed.stderr)"
    Assert-True (-not $runnerListed.stdout.Contains('diagnostic', [StringComparison]::Ordinal)) 'Runner must keep the default current scope.'
    Assert-True (-not $runnerListed.stdout.Contains('historical', [StringComparison]::Ordinal)) 'Runner must not opt into historical tests.'

    $defaultReportPath = Join-Path $root 'default-results.json'
    $default = Invoke-RegistryFixture -Root $root -Arguments @('-ResultPath', $defaultReportPath)
    Assert-True ($default.exitCode -eq 0) "Default selection fixture failed: $($default.stderr)"
    Assert-True (Test-Path (Join-Path $root 'scripts/common.marker')) 'Default must execute current tests.'
    Assert-True (Test-Path (Join-Path $root 'scripts/filtered.marker')) 'Default must execute all current tests on the platform.'
    Assert-True (-not (Test-Path (Join-Path $root 'scripts/diagnostic.marker'))) 'Default must not execute diagnostic tests.'
    Assert-True (-not (Test-Path (Join-Path $root 'scripts/historical.marker'))) 'Default must not execute historical tests.'
    $defaultReport = Get-Content -LiteralPath $defaultReportPath -Raw | ConvertFrom-Json
    Assert-True ($defaultReport.status -eq 'passed') 'Successful suite report must have passed status.'
    Assert-True ($defaultReport.version -eq 1 -and $defaultReport.platform -eq $actualPlatform) 'Report must declare its format and actual platform.'
    Assert-True ($defaultReport.results -is [array] -and $defaultReport.results.Count -eq 2) 'Report must contain exactly the selected current tests.'
    foreach ($result in $defaultReport.results) {
        Assert-True ($result.status -eq 'passed' -and $result.exitCode -eq 0 -and $null -eq $result.error) 'Successful report must preserve status and exit code.'
        Assert-True ($result.elapsedSeconds -gt 0 -and $result.scope -eq 'current') 'Report must include per-script elapsed time and scope.'
        Assert-True ($result.path.StartsWith('scripts/') -and $result.runner -eq 'PowerShell') 'Report must identify the executed script and runner.'
    }
    Remove-Item -LiteralPath (Join-Path $root 'scripts/common.marker'),(Join-Path $root 'scripts/filtered.marker')
    $selected = Invoke-RegistryFixture -Root $root -Arguments @('-Id', 'common')
    Assert-True ($selected.exitCode -eq 0) "Id selection fixture failed: $($selected.stderr)"
    Assert-True (Test-Path (Join-Path $root 'scripts/common.marker')) 'Id selection did not execute its test.'
    Assert-True (-not (Test-Path (Join-Path $root 'scripts/filtered.marker'))) 'Id selection executed a filtered test.'
    Assert-True (-not (Test-Path (Join-Path $root 'scripts/other.marker'))) 'Platform selection executed the other platform.'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $root -Arguments @('-Category', 'unknown')) `
        -Fragment 'Unknown tooling test categories: unknown'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $root -Arguments @('-Id', 'unknown')) `
        -Fragment 'Unknown tooling test ids: unknown'

    $diagnostic = Invoke-RegistryFixture -Root $root -Arguments @('-Id', 'diagnostic')
    Assert-True ($diagnostic.exitCode -eq 0) "Explicit diagnostic Id failed: $($diagnostic.stderr)"
    Assert-True (Test-Path (Join-Path $root 'scripts/diagnostic.marker')) 'Id must deliberately opt into a diagnostic test when Scope is omitted.'
    $historical = Invoke-RegistryFixture -Root $root -Arguments @('-Scope', 'Historical', '-Category', 'smoke')
    Assert-True ($historical.exitCode -eq 0) "Historical scope failed: $($historical.stderr)"
    Assert-True (Test-Path (Join-Path $root 'scripts/historical.marker')) 'Explicit historical scope must execute historical tests.'
    $all = Invoke-RegistryFixture -Root $root -Arguments @('-List', '-Scope', 'All')
    Assert-True ($all.exitCode -eq 0) "All scope failed: $($all.stderr)"
    foreach ($entryId in @('common', 'filtered', 'diagnostic', 'historical')) {
        Assert-True ($all.stdout.Contains($entryId, [StringComparison]::Ordinal)) "All scope must include $entryId."
    }
    Assert-True (-not $all.stdout.Contains('other-platform', [StringComparison]::Ordinal)) 'All scope must retain platform filtering.'
    $diagnostics = Invoke-RegistryFixture -Root $root -Arguments @('-List', '-Scope', 'Diagnostics', '-Runner', 'PowerShell')
    Assert-True ($diagnostics.exitCode -eq 0 -and $diagnostics.stdout.Contains('diagnostic', [StringComparison]::Ordinal)) 'Diagnostics scope must combine with Runner.'
    Assert-True (-not $diagnostics.stdout.Contains('historical', [StringComparison]::Ordinal)) 'Diagnostics scope must exclude historical tests.'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $root -Arguments @('-Id', 'historical', '-Scope', 'Current')) `
        -Fragment 'No tooling tests match'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $root -Arguments @('-Scope', 'Current', '-Id', 'unknown')) `
        -Fragment 'Unknown tooling test ids: unknown'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $root -Arguments @('-Scope', 'All', '-Category', 'unknown')) `
        -Fragment 'Unknown tooling test categories: unknown'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $root -Arguments @('-List', '-Scope', 'Curent')) `
        -Fragment 'ValidateSet'

    foreach ($invalid in @('Diagnostics', 'diagnostic', 'all', '')) {
        $invalidRoot = New-RegistryFixture `
            -Entries @(
                (New-TestEntry -Id 'current' -Path 'scripts/test-current.ps1')
                (New-TestEntry -Id 'invalid' -Path 'scripts/test-invalid.ps1' -Scope $invalid)
            ) `
            -Files @{'scripts/test-current.ps1' = '# current'; 'scripts/test-invalid.ps1' = '# invalid'}
        $roots.Add($invalidRoot)
        Assert-FailsWith -Result (Invoke-RegistryFixture -Root $invalidRoot -Arguments @('-List', '-Id', 'current')) `
            -Fragment 'Unsupported tooling scope for invalid'
    }

    $entry = New-TestEntry -Id 'invalid' -Path 'scripts/test-invalid.ps1'
    $entry.Remove('scope')
    $invalidRoot = New-RegistryFixture -Entries @($entry) -Files @{'scripts/test-invalid.ps1' = '# invalid'}
    $roots.Add($invalidRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $invalidRoot -Arguments @('-List')) `
        -Fragment 'must contain exactly these properties'

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
        -Entries @(
            (New-TestEntry -Id 'pass' -Path 'scripts/test-pass.ps1')
            (New-TestEntry -Id 'failure' -Path 'scripts/test-failure.ps1')
            (New-TestEntry -Id 'after' -Path 'scripts/test-after.ps1')
        ) `
        -Files @{
            'scripts/test-pass.ps1' = "Write-Output 'pass diagnostic'"
            'scripts/test-failure.ps1' = "Write-Output 'failure diagnostic'; exit 7"
            'scripts/test-after.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'after.marker') -Value ran"
        }
    $roots.Add($failureRoot)
    $failureReportPath = Join-Path $failureRoot 'failure-results.json'
    $failure = Invoke-RegistryFixture -Root $failureRoot -Arguments @('-ResultPath', $failureReportPath)
    Assert-FailsWith -Result $failure -Fragment 'failed with exit code 7'
    Assert-True (($failure.stdout + $failure.stderr).Contains('failure diagnostic', [StringComparison]::Ordinal)) `
        'A failing child must preserve its diagnostic output.'

    $failureReport = Get-Content -LiteralPath $failureReportPath -Raw | ConvertFrom-Json
    Assert-True ($failureReport.status -eq 'failed') 'Failed suite report must have failed status.'
    Assert-True ($failureReport.results.Count -eq 2) 'Failed report must retain prior successes and the failure.'
    Assert-True ($failureReport.results[0].status -eq 'passed' -and $failureReport.results[1].id -eq 'failure') 'Failed report must preserve execution order.'
    $failedResult = $failureReport.results[1]
    Assert-True ($failedResult.status -eq 'failed' -and $failedResult.exitCode -eq 7 -and $failedResult.elapsedSeconds -gt 0) 'Failed report must retain child exit code, status, and elapsed time.'
    Assert-True ($failedResult.error.Contains('failed with exit code 7')) 'Failed report must retain its error.'
    Assert-True (-not (Test-Path (Join-Path $failureRoot 'scripts/after.marker'))) 'Failure must stop the suite before later tests run.'
    $preflightRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'preflight' -Path 'scripts/test-preflight.ps1')) `
        -Files @{'scripts/test-preflight.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'preflight.marker') -Value ran"}
    $roots.Add($preflightRoot)
    $unwritableReportPath = Join-Path $preflightRoot 'missing/results.json'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $preflightRoot -Arguments @('-ResultPath', $unwritableReportPath)) `
        -Fragment 'Could not find a part of the path'
    Assert-True (-not (Test-Path (Join-Path $preflightRoot 'scripts/preflight.marker'))) 'Invalid result parent must fail before tests execute.'
    $existingReportPath = Join-Path $preflightRoot 'existing-results.json'
    Set-Content -LiteralPath $existingReportPath -Value 'existing evidence'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $preflightRoot -Arguments @('-ResultPath', $existingReportPath)) `
        -Fragment 'Tooling result path must name a new file'
    Assert-True ((Get-Content -LiteralPath $existingReportPath -Raw).Trim() -ceq 'existing evidence') 'Report must preserve an existing output file.'
    Assert-True (-not (Test-Path (Join-Path $preflightRoot 'scripts/preflight.marker'))) 'Existing result path must fail before tests execute.'
    $listReportPath = Join-Path $preflightRoot 'list-results.json'
    $listReport = Invoke-RegistryFixture -Root $preflightRoot -Arguments @('-List', '-ResultPath', $listReportPath)
    Assert-True ($listReport.exitCode -eq 0 -and -not (Test-Path -LiteralPath $listReportPath)) 'List must not create execution evidence.'

    $timeoutRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'timeout' -Path 'scripts/test-timeout.ps1' -Timeout 1)) `
        -Files @{ 'scripts/test-timeout.ps1' = "Write-Output 'timeout diagnostic'; Start-Sleep -Seconds 10" }
    $roots.Add($timeoutRoot)
    $timeoutReportPath = Join-Path $timeoutRoot 'timeout-results.json'
    $timeout = Invoke-RegistryFixture -Root $timeoutRoot -Arguments @('-ResultPath', $timeoutReportPath)
    Assert-FailsWith -Result $timeout -Fragment 'timed out after 1 seconds'
    Assert-True (($timeout.stdout + $timeout.stderr).Contains('timeout diagnostic', [StringComparison]::Ordinal)) `
        'A timed-out child must preserve its diagnostic output.'
    Assert-True ($timeout.elapsed.TotalSeconds -lt 8) 'Timed-out child was not terminated promptly.'

    $timeoutReport = Get-Content -LiteralPath $timeoutReportPath -Raw | ConvertFrom-Json
    Assert-True ($timeoutReport.status -eq 'failed') 'Timed-out suite report must have failed status.'
    Assert-True ($timeoutReport.results -is [array] -and $timeoutReport.results.Count -eq 1) 'Single-result reports must retain a JSON array.'
    $timedOutResult = $timeoutReport.results[0]
    Assert-True ($timedOutResult.status -eq 'timed-out' -and $timedOutResult.elapsedSeconds -ge 1) 'Timeout report must retain timeout status and elapsed time.'
    Assert-True ($timedOutResult.error.Contains('timed out after 1 seconds')) 'Timeout report must retain its error.'

    $pythonRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'python' -Path 'scripts/test-python.py' -Runner 'Python')) `
        -Files @{
            'scripts/test-python.py' = @'
from pathlib import Path
Path(__file__).with_suffix('.marker').write_text('ran', encoding='utf-8')
print('Python subprocess ran')
'@
        }
    $roots.Add($pythonRoot)
    $pythonReportPath = Join-Path $pythonRoot 'python-results.json'
    $python = Invoke-RegistryFixture -Root $pythonRoot -Arguments @('-Runner', 'Python', '-ResultPath', $pythonReportPath)
    Assert-True ($python.exitCode -eq 0) "Actual platform Python invocation failed: $($python.stderr)"
    Assert-True (Test-Path (Join-Path $pythonRoot 'scripts/test-python.marker')) 'Python selection must execute a real interpreter on each supported platform.'
    Assert-True ($python.stdout.Contains('Python subprocess ran')) 'Python runner must propagate child output.'
    $pythonReport = Get-Content -LiteralPath $pythonReportPath -Raw | ConvertFrom-Json
    Assert-True ($pythonReport.status -eq 'passed' -and $pythonReport.results.Count -eq 1 -and
        $pythonReport.results[0].runner -eq 'Python' -and $pythonReport.results[0].exitCode -eq 0) 'Python report must preserve successful child execution.'

    $cancelledRoot = New-RegistryFixture `
        -Entries @(
            (New-TestEntry -Id 'before-cancel' -Path 'scripts/test-before-cancel.ps1')
            (New-TestEntry -Id 'cancel' -Path 'scripts/test-cancel.ps1')
            (New-TestEntry -Id 'after-cancel' -Path 'scripts/test-after-cancel.ps1')
        ) `
        -Files @{
            'scripts/test-before-cancel.ps1' = '# completes before cancellation'
            'scripts/test-cancel.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'cancel.marker') -Value running; Start-Sleep -Seconds 3"
            'scripts/test-after-cancel.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'after-cancel.marker') -Value ran"
        }
    $roots.Add($cancelledRoot)
    $cancelledReportPath = Join-Path $cancelledRoot 'cancelled-results.json'
    $pipeline = [PowerShell]::Create()
    try {
        $null = $pipeline.AddCommand((Join-Path $cancelledRoot 'scripts/test-tooling.ps1')).
            AddParameter('Platform', $actualPlatform).AddParameter('ResultPath', $cancelledReportPath)
        $invocation = $pipeline.BeginInvoke()
        $markerPath = Join-Path $cancelledRoot 'scripts/cancel.marker'
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $markerPath) -and
            -not $invocation.IsCompleted -and $deadline.Elapsed.TotalSeconds -lt 15) {
            [Threading.Thread]::Sleep(50)
        }
        Assert-True (Test-Path -LiteralPath $markerPath) 'Cancellation fixture must reach its running child before stopping.'
        $pipeline.Stop()
        try {
            $null = $pipeline.EndInvoke($invocation)
        }
        catch [Management.Automation.PipelineStoppedException] {
            # Cancellation deliberately bypasses ordinary script catch blocks.
        }
        Assert-True ($pipeline.InvocationStateInfo.State -eq [Management.Automation.PSInvocationState]::Stopped) 'Fixture must exercise an actual stopped PowerShell pipeline.'
    }
    finally {
        $pipeline.Dispose()
    }
    $cancelledReport = Get-Content -LiteralPath $cancelledReportPath -Raw | ConvertFrom-Json
    Assert-True ($cancelledReport.status -eq 'failed') 'Incomplete execution must never produce a passed report.'
    Assert-True ($cancelledReport.results.Count -eq 1 -and $cancelledReport.results[0].id -eq 'before-cancel' -and
        $cancelledReport.results[0].status -eq 'passed') 'Cancelled execution must retain the completed test without inventing success for interrupted tests.'
    Assert-True (-not (Test-Path (Join-Path $cancelledRoot 'scripts/after-cancel.marker'))) 'Cancellation must not execute later tests.'

    $missingRoot = New-RegistryFixture `
        -Entries @((New-TestEntry -Id 'registered' -Path 'scripts/test-registered.ps1')) `
        -Files @{
            'scripts/test-registered.ps1' = '# registered'
            'scripts/test-missing.ps1' = '# missing'
        }
    $roots.Add($missingRoot)
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $missingRoot -Arguments @('-List', '-Scope', 'Historical')) `
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
        -Entries @((New-TestEntry -Id 'fixture-helper' -Path 'scripts/tests/support/fixture-helper.ps1')) `
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
    $vmReportPath = Join-Path $vmRoot 'vm-results.json'
    Assert-FailsWith -Result (Invoke-RegistryFixture -Root $vmRoot -Arguments @('-ResultPath', $vmReportPath)) `
        -Fragment 'refuses VM-backed test requires-vm'
    $vmReport = Get-Content -LiteralPath $vmReportPath -Raw | ConvertFrom-Json
    Assert-True ($vmReport.status -eq 'failed' -and $vmReport.results[0].status -eq 'failed' -and $null -eq $vmReport.results[0].exitCode) 'Pre-start test rejection must be reported without inventing a child exit code.'
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
