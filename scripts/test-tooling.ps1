[CmdletBinding()]
param(
    [ValidateSet('Current', 'Ubuntu', 'Windows')]
    [string] $Platform = 'Current',
    [string[]] $Id = @(),
    [string[]] $Category = @(),
    [ValidateSet('PowerShell', 'Python')]
    [string[]] $Runner = @(),
    [switch] $List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$registryPath = Join-Path $repositoryRoot 'config/tooling-tests.json'
$actualPlatform = if ($IsWindows) {
    'Windows'
}
elseif ($IsLinux) {
    'Ubuntu'
}
else {
    throw 'Tooling tests require an actual Windows or Linux host.'
}
if ($Platform -eq 'Current') {
    $Platform = $actualPlatform
}
elseif ($Platform -ne $actualPlatform) {
    throw "Requested tooling platform $Platform does not match actual host $actualPlatform."
}

function Get-RegistryRelativePath {
    param([Parameter(Mandatory)][string] $Path)

    if ([IO.Path]::IsPathRooted($Path) -or $Path.Contains('\')) {
        throw "Registry path must be a normalized repository-relative path: $Path"
    }
    $segments = @($Path.Split('/'))
    if ($segments.Count -lt 2 -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "Registry path must be a normalized repository-relative path: $Path"
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
    $relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $fullPath).Replace('\', '/')
    if ($relativePath.StartsWith('../', [StringComparison]::Ordinal) -or
        [IO.Path]::IsPathRooted($relativePath)) {
        throw "Registry path escapes the repository: $Path"
    }
    $relativePath
}

function Assert-Properties {
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string[]] $Names,
        [Parameter(Mandatory)][string] $Label
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if ([string]::Join("`n", $actual) -cne [string]::Join("`n", $expected)) {
        throw "$Label must contain exactly these properties: $($Names -join ', ')."
    }
}

function Read-ToolingRegistry {
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        throw "Tooling registry does not exist: $registryPath"
    }
    try {
        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -Depth 20
    }
    catch {
        throw "Tooling registry is not valid JSON: $($_.Exception.Message)"
    }

    Assert-Properties -Value $registry -Names @('version', 'discovery', 'tests') -Label 'Tooling registry'
    if (($registry.version -isnot [int] -and $registry.version -isnot [long]) -or
        $registry.version -ne 1) {
        throw "Unsupported tooling registry version: $($registry.version)"
    }
    Assert-Properties `
        -Value $registry.discovery `
        -Names @('roots', 'patterns', 'exclusions') `
        -Label 'Tooling registry discovery'
    if ($registry.tests -isnot [array] -or $registry.discovery.roots -isnot [array] -or
        $registry.discovery.patterns -isnot [array] -or
        $registry.discovery.exclusions -isnot [array]) {
        throw 'Tooling registry tests, discovery roots, patterns, and exclusions must be JSON arrays.'
    }

    $roots = @($registry.discovery.roots)
    $patterns = @($registry.discovery.patterns)
    if ($roots.Count -ne 1 -or $roots[0] -cne 'scripts') {
        throw 'Tooling discovery must use the scripts root exactly once.'
    }
    if ($patterns.Count -ne 2 -or
        @($patterns | Where-Object { $_ -ceq 'test-*.ps1' }).Count -ne 1 -or
        @($patterns | Where-Object { $_ -ceq 'test-*.py' }).Count -ne 1) {
        throw 'Tooling discovery must contain test-*.ps1 and test-*.py exactly once.'
    }

    $requiredExclusions = [ordered]@{
        'scripts/test-tooling.ps1' = 'suite-entrypoint'
        'scripts/tests/support/visual-evidence-fixture.ps1' = 'fixture-helper'
        'scripts/tests/support/windows-binary-fixture.ps1' = 'fixture-helper'
        'scripts/test-windows-vm.py' = 'vm-cli'
    }
    $exclusions = @{}
    foreach ($exclusion in @($registry.discovery.exclusions)) {
        Assert-Properties -Value $exclusion -Names @('path', 'reason') -Label 'Tooling discovery exclusion'
        $path = Get-RegistryRelativePath -Path ([string] $exclusion.path)
        if ($exclusions.ContainsKey($path)) {
            throw "Duplicate tooling discovery exclusion: $path"
        }
        $exclusions[$path] = [string] $exclusion.reason
    }
    if ($exclusions.Count -ne $requiredExclusions.Count) {
        throw 'Tooling discovery exclusions must contain only the required suite, fixture, and VM CLI paths.'
    }
    foreach ($required in $requiredExclusions.GetEnumerator()) {
        if (-not $exclusions.ContainsKey($required.Key) -or
            $exclusions[$required.Key] -cne $required.Value) {
            throw "Tooling discovery must exclude $($required.Key) as $($required.Value)."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $required.Key) -PathType Leaf)) {
            throw "Tooling discovery exclusion does not exist: $($required.Key)"
        }
    }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $validated = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($registry.tests)) {
        Assert-Properties `
            -Value $entry `
            -Names @('id', 'path', 'runner', 'platforms', 'category', 'requiresVm', 'timeout') `
            -Label 'Tooling test entry'
        if ($entry.id -isnot [string] -or $entry.path -isnot [string] -or
            $entry.runner -isnot [string] -or $entry.category -isnot [string]) {
            throw 'Tooling test id, path, runner, and category must be strings.'
        }
        $entryId = [string] $entry.id
        if ($entryId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or -not $ids.Add($entryId)) {
            throw "Tooling test id is invalid or duplicated: $entryId"
        }
        $path = Get-RegistryRelativePath -Path ([string] $entry.path)
        if (-not $paths.Add($path)) {
            throw "Tooling test path is duplicated: $path"
        }
        if ($exclusions.ContainsKey($path)) {
            throw "Excluded tooling support or CLI path cannot be registered as a test: $path"
        }
        $fullPath = Join-Path $repositoryRoot $path
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Registered tooling test does not exist: $path"
        }
        $currentPath = $repositoryRoot
        foreach ($segment in $path.Split('/')) {
            $currentPath = Join-Path $currentPath $segment
            if ((Get-Item -LiteralPath $currentPath).LinkType) {
                throw "Registered tooling test cannot traverse a symbolic link: $path"
            }
        }

        $entryRunner = [string] $entry.runner
        if ($entryRunner -notin @('PowerShell', 'Python')) {
            throw "Unsupported tooling runner for ${entryId}: $entryRunner"
        }
        $expectedExtension = if ($entryRunner -ceq 'PowerShell') { '.ps1' } else { '.py' }
        if ([IO.Path]::GetExtension($path) -cne $expectedExtension) {
            throw "Tooling runner does not match the path extension for ${entryId}: $path"
        }

        $platforms = @($entry.platforms)
        if ($entry.platforms -isnot [array] -or $platforms.Count -eq 0 -or
            @($platforms | Where-Object { $_ -isnot [string] }).Count -ne 0 -or
            @($platforms | Where-Object { $_ -notin @('Ubuntu', 'Windows') }).Count -ne 0 -or
            @($platforms | Sort-Object -Unique).Count -ne $platforms.Count) {
            throw "Tooling platforms are empty, invalid, or duplicated for $entryId."
        }
        $entryCategory = [string] $entry.category
        if ($entryCategory -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw "Tooling category is invalid for ${entryId}: $entryCategory"
        }
        if ($entry.requiresVm -isnot [bool]) {
            throw "Tooling requiresVm must be boolean for $entryId."
        }
        if ($entry.timeout -isnot [int] -and $entry.timeout -isnot [long]) {
            throw "Tooling timeout must be an integer for $entryId."
        }
        $timeout = [long] $entry.timeout
        if ($timeout -lt 1 -or $timeout -gt 3600) {
            throw "Tooling timeout must be between 1 and 3600 seconds for $entryId."
        }

        $validated.Add([pscustomobject]@{
            id = $entryId
            path = $path
            fullPath = $fullPath
            runner = $entryRunner
            platforms = $platforms
            category = $entryCategory
            requiresVm = [bool] $entry.requiresVm
            timeout = [int] $timeout
        })
    }
    if ($validated.Count -eq 0) {
        throw 'Tooling registry must contain at least one test.'
    }

    $discovered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($pattern in $patterns) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts') -File -Recurse -Filter $pattern)) {
            $path = [IO.Path]::GetRelativePath($repositoryRoot, $file.FullName).Replace('\', '/')
            $null = $discovered.Add($path)
        }
    }
    $missing = @($discovered | Where-Object {
        -not $paths.Contains($_) -and -not $exclusions.ContainsKey($_)
    } | Sort-Object)
    if ($missing.Count -ne 0) {
        throw "Discovered tooling tests are missing registry entries: $($missing -join ', ')"
    }

    @($validated)
}

function Invoke-ToolingTest {
    param([Parameter(Mandatory)][object] $Test)

    if ($Test.requiresVm) {
        throw "Tooling suite refuses VM-backed test $($Test.id); run it through its explicit VM entrypoint."
    }
    $command = if ($Test.runner -ceq 'PowerShell') {
        Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
    }
    else {
        Get-Command python3 -CommandType Application -ErrorAction Stop | Select-Object -First 1
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $command.Source
    $startInfo.WorkingDirectory = $repositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($Test.runner -ceq 'PowerShell') {
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Test.fullPath)) {
            $startInfo.ArgumentList.Add($argument)
        }
    }
    else {
        $startInfo.ArgumentList.Add($Test.fullPath)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) {
            throw "Failed to start tooling test $($Test.id)."
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($Test.timeout * 1000)
        if ($timedOut) {
            try {
                $process.Kill($true)
            }
            finally {
                $process.WaitForExit()
            }
        }
        $drainMilliseconds = if ($timedOut) {
            5000
        }
        else {
            [Math]::Max(1, ($Test.timeout * 1000) - [int] $timer.ElapsedMilliseconds)
        }
        if (-not [Threading.Tasks.Task]::WaitAll(
            [Threading.Tasks.Task[]] @($stdout, $stderr),
            $drainMilliseconds
        )) {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            throw "Tooling test $($Test.id) did not close its output streams within its timeout."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($output.Length -ne 0) {
            [Console]::Out.Write($output)
        }
        if ($errorOutput.Length -ne 0) {
            [Console]::Error.Write($errorOutput)
        }
        if ($timedOut) {
            throw "Tooling test $($Test.id) timed out after $($Test.timeout) seconds."
        }
        if ($process.ExitCode -ne 0) {
            throw "Tooling test $($Test.id) failed with exit code $($process.ExitCode)."
        }
    }
    finally {
        $timer.Stop()
        $process.Dispose()
    }
}

$tests = @(Read-ToolingRegistry)
$selected = @($tests | Where-Object {
    $_.platforms -contains $Platform -and
    ($Id.Count -eq 0 -or $Id -contains $_.id) -and
    ($Category.Count -eq 0 -or $Category -contains $_.category) -and
    ($Runner.Count -eq 0 -or $Runner -contains $_.runner)
})

if ($Id.Count -ne 0) {
    $unknownIds = @($Id | Where-Object { $tests.id -notcontains $_ } | Sort-Object -Unique)
    if ($unknownIds.Count -ne 0) {
        throw "Unknown tooling test ids: $($unknownIds -join ', ')"
    }
}
if ($selected.Count -eq 0) {
    throw "No tooling tests match Platform=$Platform and the requested filters."
}

if ($List) {
    $selected | Select-Object id, path, runner, platforms, category, requiresVm, timeout | Format-Table -AutoSize
    return
}

foreach ($test in $selected) {
    Write-Host "Running $($test.id) ($($test.runner), $Platform, timeout $($test.timeout)s)"
    Invoke-ToolingTest -Test $test
}

Write-Host "Tooling tests passed for $Platform ($($selected.Count) tests)."
