[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
$paths = Get-ToolingTestPaths
$helper = Join-Path $paths.ScriptsRoot 'resolve-source-matrix-metadata.ps1'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function New-Case {
    $caseRoot = Join-Path $testRoot ([Guid]::NewGuid().ToString())
    $runnerTemp = Join-Path $caseRoot 'runner temp with spaces'
    New-Item -ItemType Directory -Path $runnerTemp -Force | Out-Null
    [pscustomobject]@{
        Root = $caseRoot
        RunnerTemp = $runnerTemp
        EnvPath = Join-Path $caseRoot 'github-env'
    }
}

function Invoke-HelperCli {
    param(
        [Parameter(Mandatory)] $Case,
        [Parameter(Mandatory)][string] $Matrix,
        [hashtable] $Overrides = @{}
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $startInfo.WorkingDirectory = $paths.RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $helper, '-Matrix', $Matrix)) {
        [void] $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['PATH'] = "$binRoot$([IO.Path]::PathSeparator)$env:PATH"
    $defaults = @{
        FIXTURE_SHA = ('a' * 40)
        FIXTURE_EPOCH = '1700000000'
        FIXTURE_RUSTC = 'rustc 1.90.0 (fixture)'
        FIXTURE_SHA_EXIT = '0'
        FIXTURE_EPOCH_EXIT = '0'
        FIXTURE_RUSTC_EXIT = '0'
        RUNNER_TEMP = $Case.RunnerTemp
        GITHUB_ENV = $Case.EnvPath
        GITHUB_RUN_ID = '777'
        GITHUB_RUN_ATTEMPT = '2'
    }
    foreach ($key in $Overrides.Keys) { $defaults[$key] = $Overrides[$key] }
    foreach ($key in $defaults.Keys) { $startInfo.Environment[$key] = $defaults[$key] }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True -Condition $process.Start() -Message 'Matrix helper process did not start.'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally { $process.Dispose() }
}

function Assert-Failure {
    param(
        [Parameter(Mandatory)] $Case,
        [Parameter(Mandatory)][string] $Matrix,
        [Parameter(Mandatory)][string] $Expected,
        [hashtable] $Overrides = @{}
    )
    $result = Invoke-HelperCli -Case $Case -Matrix $Matrix -Overrides $Overrides
    Assert-True -Condition ($result.ExitCode -ne 0) -Message "$Matrix unexpectedly succeeded."
    Assert-True -Condition ($result.Stderr.Contains($Expected)) -Message (
        "Expected '$Expected' in $Matrix error: $($result.Stderr)"
    )
    Assert-True -Condition (-not (Test-Path -LiteralPath $Case.EnvPath)) -Message (
        "$Matrix wrote the environment file before rejecting metadata."
    )
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-matrix-metadata-$([Guid]::NewGuid())"
$binRoot = Join-Path $testRoot 'fixture tools'
try {
    New-Item -ItemType Directory -Path $binRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $binRoot 'git.ps1'), @'
if (($args -join ' ') -ceq 'rev-parse HEAD') {
    Write-Output $env:FIXTURE_SHA
    $global:LASTEXITCODE = [int] $env:FIXTURE_SHA_EXIT
} elseif (($args -join ' ') -ceq 'show -s --format=%ct HEAD') {
    Write-Output $env:FIXTURE_EPOCH
    $global:LASTEXITCODE = [int] $env:FIXTURE_EPOCH_EXIT
} else {
    throw "Unexpected git arguments: $args"
}
'@)
    [IO.File]::WriteAllText((Join-Path $binRoot 'rustc.ps1'), @'
if (($args -join ' ') -cne '--version') { throw "Unexpected rustc arguments: $args" }
Write-Output $env:FIXTURE_RUSTC
$global:LASTEXITCODE = [int] $env:FIXTURE_RUSTC_EXIT
'@)

    $matrixCases = @(
        @{ Matrix = 'BinarySize'; Artifact = 'darkrenamer-binary-size-matrix'; Target = 'darkrenamer-binary-size-target'; Error = 'Binary-size matrix output roots must not already exist.' }
        @{ Matrix = 'ProfilePlanning'; Artifact = 'darkrenamer-profile-planning'; Target = 'darkrenamer-profile-planning-target'; Error = 'Profile planning output roots must not already exist.' }
        @{ Matrix = 'ProfileBenchmark'; Artifact = 'darkrenamer-profile-benchmark'; Target = 'darkrenamer-profile-target'; Error = 'Profile benchmark output roots must not already exist.' }
    )
    foreach ($policy in $matrixCases) {
        $case = New-Case
        $artifactRoot = Join-Path $case.RunnerTemp "$($policy.Artifact)-777-2"
        $targetRoot = Join-Path $case.RunnerTemp "$($policy.Target)-777-2"
        $result = Invoke-HelperCli -Case $case -Matrix $policy.Matrix
        Assert-True -Condition ($result.ExitCode -eq 0) -Message "$($policy.Matrix) failed: $($result.Stderr)"
        Assert-True -Condition (Test-Path -LiteralPath $artifactRoot -PathType Container) -Message 'Artifact root was not created.'
        Assert-True -Condition (Test-Path -LiteralPath $targetRoot -PathType Container) -Message 'Target root was not created.'
        $actualLines = @(Get-Content -LiteralPath $case.EnvPath)
        $expectedLines = @(
            "SOURCE_SHA=$('a' * 40)"
            'SOURCE_DATE_EPOCH=1700000000'
            'RUSTC_VERSION=rustc 1.90.0 (fixture)'
            "ARTIFACT_ROOT=$artifactRoot"
            "TARGET_ROOT=$targetRoot"
        )
        Assert-True -Condition (($actualLines -join "`n") -ceq ($expectedLines -join "`n")) -Message (
            "$($policy.Matrix) changed the GITHUB_ENV key, order, or value contract."
        )

        $existingArtifact = New-Case
        New-Item -ItemType Directory -Path (Join-Path $existingArtifact.RunnerTemp "$($policy.Artifact)-777-2") | Out-Null
        Assert-Failure -Case $existingArtifact -Matrix $policy.Matrix -Expected $policy.Error
        $existingTarget = New-Case
        New-Item -ItemType Directory -Path (Join-Path $existingTarget.RunnerTemp "$($policy.Target)-777-2") | Out-Null
        Assert-Failure -Case $existingTarget -Matrix $policy.Matrix -Expected $policy.Error
    }

    Assert-Failure -Case (New-Case) -Matrix BinarySize -Expected 'selected source commit could not be resolved' -Overrides @{ FIXTURE_SHA = ('A' * 40) }
    Assert-Failure -Case (New-Case) -Matrix BinarySize -Expected 'selected source commit could not be resolved' -Overrides @{ FIXTURE_SHA_EXIT = '7' }
    Assert-Failure -Case (New-Case) -Matrix BinarySize -Expected 'selected source commit timestamp could not be resolved' -Overrides @{ FIXTURE_EPOCH = '0' }
    Assert-Failure -Case (New-Case) -Matrix BinarySize -Expected 'selected source commit timestamp could not be resolved' -Overrides @{ FIXTURE_EPOCH_EXIT = '8' }
    Assert-Failure -Case (New-Case) -Matrix BinarySize -Expected 'pinned rustc version could not be resolved' -Overrides @{ FIXTURE_RUSTC = '' }
    Assert-Failure -Case (New-Case) -Matrix BinarySize -Expected 'pinned rustc version could not be resolved' -Overrides @{ FIXTURE_RUSTC_EXIT = '9' }

    $badOutput = New-Case
    $outputDirectory = Join-Path $badOutput.Root 'not-an-env-file'
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
    $result = Invoke-HelperCli -Case $badOutput -Matrix BinarySize -Overrides @{ GITHUB_ENV = $outputDirectory }
    Assert-True -Condition ($result.ExitCode -ne 0) -Message 'GITHUB_ENV directory was accepted as an output file.'
    Assert-True -Condition ($result.Stderr.Contains('Out-File')) -Message 'Output path failure did not come from the environment write.'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $badOutput.RunnerTemp 'darkrenamer-binary-size-matrix-777-2')) -Message 'Output path failure happened before root creation.'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $badOutput.RunnerTemp 'darkrenamer-binary-size-target-777-2')) -Message 'Output path failure happened before target creation.'

    $importCase = New-Case
    $savedRunnerTemp = $env:RUNNER_TEMP
    $savedGithubEnv = $env:GITHUB_ENV
    try {
        $env:RUNNER_TEMP = $importCase.RunnerTemp
        $env:GITHUB_ENV = $importCase.EnvPath
        $importOutput = @(. $helper)
        Assert-True -Condition ($importOutput.Count -eq 0) -Message 'Dot-sourcing the helper produced output.'
        Assert-True -Condition (-not (Test-Path -LiteralPath $importCase.EnvPath)) -Message 'Dot-sourcing wrote GITHUB_ENV.'
        Assert-True -Condition (@(Get-ChildItem -LiteralPath $importCase.RunnerTemp).Count -eq 0) -Message 'Dot-sourcing created matrix roots.'
        Assert-True -Condition ($null -ne (Get-Command Resolve-SourceMatrixMetadata -CommandType Function)) -Message 'Dot-sourcing did not expose the helper function.'
    }
    finally {
        $env:RUNNER_TEMP = $savedRunnerTemp
        $env:GITHUB_ENV = $savedGithubEnv
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
