[CmdletBinding()]
param(
    [ValidateSet('BinarySize', 'ProfilePlanning', 'ProfileBenchmark')]
    [string] $Matrix
)

function Resolve-SourceMatrixMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('BinarySize', 'ProfilePlanning', 'ProfileBenchmark')]
        [string] $Matrix
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $sourceSha = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceSha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The selected source commit could not be resolved.'
    }
    $sourceEpoch = (git show -s --format=%ct HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceEpoch -notmatch '^[1-9][0-9]*$') {
        throw 'The selected source commit timestamp could not be resolved.'
    }
    $rustcVersion = (& rustc --version).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rustcVersion)) {
        throw 'The pinned rustc version could not be resolved.'
    }

    $profile = switch ($Matrix) {
        BinarySize {
            @{
                ArtifactPrefix = 'darkrenamer-binary-size-matrix'
                TargetPrefix = 'darkrenamer-binary-size-target'
                ExistingRootsError = 'Binary-size matrix output roots must not already exist.'
            }
        }
        ProfilePlanning {
            @{
                ArtifactPrefix = 'darkrenamer-profile-planning'
                TargetPrefix = 'darkrenamer-profile-planning-target'
                ExistingRootsError = 'Profile planning output roots must not already exist.'
            }
        }
        ProfileBenchmark {
            @{
                ArtifactPrefix = 'darkrenamer-profile-benchmark'
                TargetPrefix = 'darkrenamer-profile-target'
                ExistingRootsError = 'Profile benchmark output roots must not already exist.'
            }
        }
    }
    $artifactRoot = Join-Path `
        $env:RUNNER_TEMP `
        "$($profile.ArtifactPrefix)-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
    $targetRoot = Join-Path `
        $env:RUNNER_TEMP `
        "$($profile.TargetPrefix)-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
    if ((Test-Path -LiteralPath $artifactRoot) -or (Test-Path -LiteralPath $targetRoot)) {
        throw $profile.ExistingRootsError
    }
    New-Item -ItemType Directory -Path $artifactRoot, $targetRoot | Out-Null
    "SOURCE_SHA=$sourceSha" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "SOURCE_DATE_EPOCH=$sourceEpoch" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "RUSTC_VERSION=$rustcVersion" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "ARTIFACT_ROOT=$artifactRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "TARGET_ROOT=$targetRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

if ($MyInvocation.InvocationName -ne '.') {
    Resolve-SourceMatrixMetadata -Matrix $Matrix
}
