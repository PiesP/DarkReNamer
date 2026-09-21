[CmdletBinding()]
param(
    [switch] $LibraryOnly,
    [string] $Repository,
    [string] $CandidateRunId,
    [string] $CandidateRunAttempt,
    [string] $CandidateArtifactId,
    [string] $CandidateSourceSha,
    [string] $ExpectedExeSha256,
    [string] $IngressReleaseId,
    [string] $IngressAssetId,
    [string] $IngressArchiveSha256,
    [string] $IngressArchiveSize,
    [string] $ValidationRunId,
    [string] $ValidationRunAttempt,
    [string] $CandidateHandoffRoot,
    [string] $TrustedSourceRoot,
    [string] $OutputPath,
    [string] $RunnerTemp = $env:RUNNER_TEMP,
    [string] $PythonExecutable = 'python'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HostedDecimal {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $Label)
    if ($Value -cnotmatch '^[1-9][0-9]{0,18}$' -or
        [uint64]$Value -gt [uint64][long]::MaxValue) {
        throw "$Label must be a bounded positive decimal integer."
    }
}

function Assert-HostedDigest {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][ValidateSet(40, 64)][int] $Length,
        [Parameter(Mandatory)][string] $Label
    )
    if ($Value -cnotmatch ('^[0-9a-f]{' + $Length + '}$')) {
        throw "$Label must be a lowercase hexadecimal digest."
    }
}

function Invoke-HostedGhJson {
    param(
        [Parameter(Mandatory)][string] $Endpoint,
        [Parameter(Mandatory)][string] $Destination
    )
    $content = @(& gh api $Endpoint 2>$null)
    if ($LASTEXITCODE -ne 0 -or $content.Count -eq 0) {
        throw 'Authenticated GitHub metadata retrieval failed.'
    }
    [IO.File]::WriteAllLines(
        $Destination,
        [string[]]$content,
        [Text.UTF8Encoding]::new($false)
    )
}

function Read-HostedJson {
    param([Parameter(Mandatory)][string] $Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt 8MB) {
        throw 'Authenticated GitHub metadata is not one bounded ordinary file.'
    }
    Get-Content -LiteralPath $item.FullName -Raw | ConvertFrom-Json
}

function Assert-HostedRepository {
    param(
        [Parameter(Mandatory)][object] $Metadata,
        [Parameter(Mandatory)][string] $ExpectedRepository
    )
    if ($ExpectedRepository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $Metadata.full_name -cne $ExpectedRepository -or
        $Metadata.id -isnot [long] -or $Metadata.id -le 0 -or
        $Metadata.owner.id -isnot [long] -or $Metadata.owner.id -le 0 -or
        $Metadata.owner.login -cne $ExpectedRepository.Split('/')[0] -or
        $Metadata.owner.type -cne 'User') {
        throw 'Authenticated repository identity is invalid.'
    }
}

function Assert-HostedRun {
    param(
        [Parameter(Mandatory)][object] $Run,
        [Parameter(Mandatory)][string] $ExpectedPath,
        [Parameter(Mandatory)][string] $ExpectedEvent,
        [Parameter(Mandatory)][string] $ExpectedSourceSha,
        [Parameter(Mandatory)][long] $ExpectedRepositoryId,
        [string] $ExpectedRunId,
        [string] $ExpectedRunAttempt
    )
    if ($Run.id -isnot [long] -or $Run.id -le 0 -or
        $Run.run_attempt -isnot [long] -or $Run.run_attempt -le 0 -or
        $Run.path -cne $ExpectedPath -or $Run.event -cne $ExpectedEvent -or
        $Run.head_branch -cne 'master' -or $Run.head_sha -cne $ExpectedSourceSha -or
        $Run.status -cne 'completed' -or $Run.conclusion -cne 'success' -or
        $Run.repository.id -isnot [long] -or $Run.repository.id -ne $ExpectedRepositoryId -or
        $Run.head_repository.id -isnot [long] -or
        $Run.head_repository.id -ne $ExpectedRepositoryId) {
        throw 'Authenticated workflow run identity is invalid.'
    }
    if (-not [string]::IsNullOrEmpty($ExpectedRunId) -and
        [string]$Run.id -cne $ExpectedRunId) {
        throw 'Authenticated workflow run ID differs from its pin.'
    }
    if (-not [string]::IsNullOrEmpty($ExpectedRunAttempt) -and
        [string]$Run.run_attempt -cne $ExpectedRunAttempt) {
        throw 'Authenticated workflow run attempt differs from its pin.'
    }
}

function Get-HostedGateJobs {
    param(
        [Parameter(Mandatory)][object] $Document,
        [Parameter(Mandatory)][string[]] $ExpectedNames
    )
    if ($Document.total_count -isnot [long] -or
        $Document.total_count -ne $ExpectedNames.Count -or
        @($Document.jobs).Count -ne $ExpectedNames.Count) {
        throw 'Authenticated workflow job count is invalid.'
    }
    $rows = @($Document.jobs | ForEach-Object {
        if ($_.name -isnot [string] -or $_.status -cne 'completed' -or
            $_.conclusion -cne 'success') {
            throw 'Authenticated workflow job did not pass.'
        }
        [ordered]@{
            name = [string]$_.name
            status = [string]$_.status
            conclusion = [string]$_.conclusion
        }
    } | Sort-Object name)
    $actual = @($rows | ForEach-Object { $_.name })
    $expected = @($ExpectedNames | Sort-Object)
    if (Compare-Object -ReferenceObject $expected -DifferenceObject $actual) {
        throw 'Authenticated workflow job set is invalid.'
    }
    $rows
}

function New-HostedGateMetadata {
    param(
        [Parameter(Mandatory)][object] $RepositoryMetadata,
        [Parameter(Mandatory)][object] $CandidateRun,
        [Parameter(Mandatory)][object[]] $CandidateJobs,
        [Parameter(Mandatory)][object] $CandidateArtifact,
        [Parameter(Mandatory)][object] $CiRun,
        [Parameter(Mandatory)][object[]] $CiJobs
    )
    if ($CandidateArtifact.digest -isnot [string] -or
        $CandidateArtifact.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $CandidateArtifact.id -isnot [long] -or $CandidateArtifact.id -le 0 -or
        $CandidateArtifact.size_in_bytes -isnot [long] -or
        $CandidateArtifact.size_in_bytes -le 0 -or
        $CandidateArtifact.expired -isnot [bool] -or $CandidateArtifact.expired -or
        $CandidateArtifact.workflow_run.id -isnot [long] -or
        $CandidateArtifact.workflow_run.head_sha -isnot [string]) {
        throw 'Authenticated candidate artifact metadata is invalid.'
    }
    [ordered]@{
        schema_version = 1
        repository = [ordered]@{
            full_name = [string]$RepositoryMetadata.full_name
            id = [long]$RepositoryMetadata.id
            owner = [ordered]@{
                login = [string]$RepositoryMetadata.owner.login
                id = [long]$RepositoryMetadata.owner.id
                type = [string]$RepositoryMetadata.owner.type
            }
        }
        candidate = [ordered]@{
            run = [ordered]@{
                id = [long]$CandidateRun.id
                run_attempt = [long]$CandidateRun.run_attempt
                path = [string]$CandidateRun.path
                event = [string]$CandidateRun.event
                head_branch = [string]$CandidateRun.head_branch
                head_sha = [string]$CandidateRun.head_sha
                status = [string]$CandidateRun.status
                conclusion = [string]$CandidateRun.conclusion
                repository_id = [long]$CandidateRun.repository.id
            }
            jobs = @($CandidateJobs)
            artifact = [ordered]@{
                id = [long]$CandidateArtifact.id
                name = [string]$CandidateArtifact.name
                digest = [string]$CandidateArtifact.digest
                size = [long]$CandidateArtifact.size_in_bytes
                expired = [bool]$CandidateArtifact.expired
                workflow_run = [ordered]@{
                    id = [long]$CandidateArtifact.workflow_run.id
                    head_sha = [string]$CandidateArtifact.workflow_run.head_sha
                }
            }
            artifact_sha256 = ([string]$CandidateArtifact.digest).Substring(7)
        }
        ci = [ordered]@{
            run = [ordered]@{
                id = [long]$CiRun.id
                run_attempt = [long]$CiRun.run_attempt
                path = [string]$CiRun.path
                event = [string]$CiRun.event
                head_branch = [string]$CiRun.head_branch
                head_sha = [string]$CiRun.head_sha
                status = [string]$CiRun.status
                conclusion = [string]$CiRun.conclusion
                repository_id = [long]$CiRun.repository.id
            }
            jobs = @($CiJobs)
        }
    }
}

function Remove-HostedScratch {
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $RunnerRoot)
    $expectedParent = [IO.Path]::GetFullPath($RunnerRoot).TrimEnd('\', '/')
    $item = Get-Item -LiteralPath $Root -Force
    if ($item.Parent.FullName.TrimEnd('\', '/') -cne $expectedParent -or
        $item.Name -cnotmatch '^darkrenamer-vm-hosted-[0-9a-f]{32}$' -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Hosted validation scratch ownership check failed.'
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Hosted validation scratch contains a reparse entry.'
        }
    }
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
    if (Test-Path -LiteralPath $item.FullName) {
        throw 'Hosted validation scratch cleanup failed.'
    }
}

if ($LibraryOnly) { return }

try {
    foreach ($required in @{
        Repository = $Repository
        CandidateRunId = $CandidateRunId
        CandidateRunAttempt = $CandidateRunAttempt
        CandidateArtifactId = $CandidateArtifactId
        CandidateSourceSha = $CandidateSourceSha
        ExpectedExeSha256 = $ExpectedExeSha256
        IngressReleaseId = $IngressReleaseId
        IngressAssetId = $IngressAssetId
        IngressArchiveSha256 = $IngressArchiveSha256
        IngressArchiveSize = $IngressArchiveSize
        ValidationRunId = $ValidationRunId
        ValidationRunAttempt = $ValidationRunAttempt
        CandidateHandoffRoot = $CandidateHandoffRoot
        TrustedSourceRoot = $TrustedSourceRoot
        OutputPath = $OutputPath
        RunnerTemp = $RunnerTemp
    }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
            throw "$($required.Key) is required."
        }
    }
    foreach ($pin in @(
        @($CandidateRunId, 'Candidate run ID'),
        @($CandidateRunAttempt, 'Candidate run attempt'),
        @($CandidateArtifactId, 'Candidate artifact ID'),
        @($IngressReleaseId, 'Ingress release ID'),
        @($IngressAssetId, 'Ingress asset ID'),
        @($IngressArchiveSize, 'Ingress archive size'),
        @($ValidationRunId, 'Validation run ID'),
        @($ValidationRunAttempt, 'Validation run attempt')
    )) { Assert-HostedDecimal -Value $pin[0] -Label $pin[1] }
    Assert-HostedDigest -Value $CandidateSourceSha -Length 40 -Label 'Candidate source SHA'
    Assert-HostedDigest -Value $ExpectedExeSha256 -Length 64 -Label 'Expected EXE SHA256'
    Assert-HostedDigest -Value $IngressArchiveSha256 -Length 64 -Label 'Ingress archive SHA256'
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Repository must be an owner/name pair.'
    }
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        throw 'GH_TOKEN is required for authenticated hosted validation.'
    }
    $trusted = (Get-Item -LiteralPath $TrustedSourceRoot -Force).FullName
    $candidate = (Get-Item -LiteralPath $CandidateHandoffRoot -Force).FullName
    $output = [IO.Path]::GetFullPath($OutputPath)
    if (-not (Test-Path -LiteralPath $trusted -PathType Container) -or
        -not (Test-Path -LiteralPath $candidate -PathType Container) -or
        (Test-Path -LiteralPath $output)) {
        throw 'Hosted validation input or output path state is invalid.'
    }
    $sourceCommit = (& git -C $trusted rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -cne $CandidateSourceSha -or
        $env:GITHUB_SHA -cne $CandidateSourceSha -or
        $env:GITHUB_REPOSITORY -cne $Repository -or
        $env:GITHUB_REF -cne 'refs/heads/master') {
        throw 'Trusted checkout does not match the exact candidate source on master.'
    }

    $scratch = Join-Path ([IO.Path]::GetFullPath($RunnerTemp)) (
        'darkrenamer-vm-hosted-' + [guid]::NewGuid().ToString('N')
    )
    [void](New-Item -ItemType Directory -Path $scratch)
    try {
        $repositoryPath = Join-Path $scratch 'repository.json'
        $releasePath = Join-Path $scratch 'release.json'
        $assetPath = Join-Path $scratch 'asset.json'
        $candidateRunPath = Join-Path $scratch 'candidate-run.json'
        $candidateArtifactPath = Join-Path $scratch 'candidate-artifact.json'
        $candidateJobsPath = Join-Path $scratch 'candidate-jobs.json'
        $ciRunsPath = Join-Path $scratch 'ci-runs.json'
        $ciRunPath = Join-Path $scratch 'ci-run.json'
        $ciJobsPath = Join-Path $scratch 'ci-jobs.json'
        $gatePath = Join-Path $scratch 'gate-metadata.json'
        $archivePath = Join-Path $scratch 'raw-evidence.zip'

        Invoke-HostedGhJson -Endpoint "repos/$Repository" -Destination $repositoryPath
        Invoke-HostedGhJson -Endpoint "repos/$Repository/releases/$IngressReleaseId" -Destination $releasePath
        Invoke-HostedGhJson -Endpoint "repos/$Repository/releases/assets/$IngressAssetId" -Destination $assetPath
        Invoke-HostedGhJson -Endpoint "repos/$Repository/actions/runs/$CandidateRunId/attempts/$CandidateRunAttempt" -Destination $candidateRunPath
        Invoke-HostedGhJson -Endpoint "repos/$Repository/actions/artifacts/$CandidateArtifactId" -Destination $candidateArtifactPath
        Invoke-HostedGhJson -Endpoint "repos/$Repository/actions/runs/$CandidateRunId/attempts/$CandidateRunAttempt/jobs?per_page=100" -Destination $candidateJobsPath
        Invoke-HostedGhJson -Endpoint "repos/$Repository/actions/workflows/ci.yaml/runs?branch=master&event=push&status=success&per_page=100" -Destination $ciRunsPath

        $repositoryMetadata = Read-HostedJson $repositoryPath
        Assert-HostedRepository -Metadata $repositoryMetadata -ExpectedRepository $Repository
        if ($env:GITHUB_ACTOR -cne $repositoryMetadata.owner.login) {
            throw 'Hosted validation must be dispatched by the repository owner.'
        }
        $candidateRun = Read-HostedJson $candidateRunPath
        Assert-HostedRun -Run $candidateRun `
            -ExpectedPath '.github/workflows/release.yaml' `
            -ExpectedEvent 'workflow_dispatch' `
            -ExpectedSourceSha $CandidateSourceSha `
            -ExpectedRepositoryId $repositoryMetadata.id `
            -ExpectedRunId $CandidateRunId `
            -ExpectedRunAttempt $CandidateRunAttempt
        $candidateJobs = @(Get-HostedGateJobs `
            -Document (Read-HostedJson $candidateJobsPath) `
            -ExpectedNames @('candidate/build-windows'))
        $candidateArtifact = Read-HostedJson $candidateArtifactPath

        $ciList = Read-HostedJson $ciRunsPath
        $ciMatches = @($ciList.workflow_runs | Where-Object {
            $_.path -ceq '.github/workflows/ci.yaml' -and
            $_.event -ceq 'push' -and $_.head_branch -ceq 'master' -and
            $_.head_sha -ceq $CandidateSourceSha -and $_.status -ceq 'completed' -and
            $_.conclusion -ceq 'success' -and
            $_.repository.id -eq $repositoryMetadata.id -and
            $_.head_repository.id -eq $repositoryMetadata.id
        } | Sort-Object id)
        if ($ciMatches.Count -eq 0) {
            throw 'No authenticated successful exact-source CI run was found.'
        }
        $selectedCi = $ciMatches[0]
        $selectedCiId = [string]$selectedCi.id
        $selectedCiAttempt = [string]$selectedCi.run_attempt
        Assert-HostedDecimal -Value $selectedCiId -Label 'Selected CI run ID'
        Assert-HostedDecimal -Value $selectedCiAttempt -Label 'Selected CI run attempt'
        Invoke-HostedGhJson `
            -Endpoint "repos/$Repository/actions/runs/$selectedCiId/attempts/$selectedCiAttempt" `
            -Destination $ciRunPath
        $ciRun = Read-HostedJson $ciRunPath
        Assert-HostedRun -Run $ciRun `
            -ExpectedPath '.github/workflows/ci.yaml' `
            -ExpectedEvent 'push' `
            -ExpectedSourceSha $CandidateSourceSha `
            -ExpectedRepositoryId $repositoryMetadata.id `
            -ExpectedRunId $selectedCiId `
            -ExpectedRunAttempt $selectedCiAttempt
        Invoke-HostedGhJson `
            -Endpoint "repos/$Repository/actions/runs/$($ciRun.id)/attempts/$($ciRun.run_attempt)/jobs?per_page=100" `
            -Destination $ciJobsPath
        $ciJobs = @(Get-HostedGateJobs `
            -Document (Read-HostedJson $ciJobsPath) `
            -ExpectedNames @('pr-gate/quality', 'pr-gate/security', 'pr-gate/unit', 'pr-gate/windows'))

        $expectedArtifactName = "DarkReNamer-dry-run-$CandidateRunId-$CandidateRunAttempt-windows"
        if ($candidateArtifact.id -isnot [long] -or
            [string]$candidateArtifact.id -cne $CandidateArtifactId -or
            $candidateArtifact.name -cne $expectedArtifactName -or
            $candidateArtifact.workflow_run.id -isnot [long] -or
            [string]$candidateArtifact.workflow_run.id -cne $CandidateRunId -or
            $candidateArtifact.workflow_run.head_branch -cne 'master' -or
            $candidateArtifact.workflow_run.head_sha -cne $CandidateSourceSha) {
            throw 'Authenticated candidate artifact identity differs from its pins.'
        }

        $gate = New-HostedGateMetadata `
            -RepositoryMetadata $repositoryMetadata `
            -CandidateRun $candidateRun `
            -CandidateJobs $candidateJobs `
            -CandidateArtifact $candidateArtifact `
            -CiRun $ciRun `
            -CiJobs $ciJobs
        [IO.File]::WriteAllText(
            $gatePath,
            ($gate | ConvertTo-Json -Depth 8 -Compress),
            [Text.UTF8Encoding]::new($false)
        )

        $headers = @{
            Accept = 'application/octet-stream'
            Authorization = "Bearer $($env:GH_TOKEN)"
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent' = 'DarkReNamer-hosted-validator'
        }
        Invoke-WebRequest `
            -Uri "https://api.github.com/repos/$Repository/releases/assets/$IngressAssetId" `
            -Headers $headers `
            -OutFile $archivePath `
            -MaximumRedirection 5 | Out-Null

        & $PythonExecutable -I (Join-Path $trusted 'scripts/validate-vm-automated-authority.py') ingress `
            --repository-metadata $repositoryPath `
            --repository $Repository `
            --source-sha $CandidateSourceSha `
            --release-metadata $releasePath `
            --asset-metadata $assetPath `
            --release-id $IngressReleaseId `
            --asset-id $IngressAssetId `
            --asset-sha256 $IngressArchiveSha256 `
            --asset-size $IngressArchiveSize `
            --archive $archivePath *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Private ingress authority validation failed.' }

        & (Join-Path $trusted 'scripts/validate-release-candidate-metadata.ps1') `
            -RunMetadataPath $candidateRunPath `
            -ArtifactMetadataPath $candidateArtifactPath `
            -ExpectedRunId $CandidateRunId `
            -ExpectedRunAttempt $CandidateRunAttempt `
            -ExpectedArtifactId $CandidateArtifactId `
            -ExpectedSourceSha $CandidateSourceSha `
            -ExpectedArtifactName $expectedArtifactName *> $null
        $handoff = & (Join-Path $trusted 'scripts/validate-release-handoff.ps1') `
            -SourceRoot $trusted `
            -HandoffRoot $candidate `
            -PassThru
        if ($handoff.workflow_run -cne $CandidateRunId -or
            $handoff.source_sha -cne $CandidateSourceSha -or
            $handoff.executable.sha256 -cne $ExpectedExeSha256) {
            throw 'Candidate handoff differs from its explicit identity.'
        }

        & $PythonExecutable -I (Join-Path $trusted 'scripts/validate-vm-automated-evidence.py') `
            --archive $archivePath `
            --archive-sha256 $IngressArchiveSha256 `
            --archive-size $IngressArchiveSize `
            --candidate-handoff-root $candidate `
            --candidate-run-id $CandidateRunId `
            --candidate-run-attempt $CandidateRunAttempt `
            --candidate-artifact-id $CandidateArtifactId `
            --candidate-source-sha $CandidateSourceSha `
            --expected-exe-sha256 $ExpectedExeSha256 `
            --release-id $IngressReleaseId `
            --asset-id $IngressAssetId `
            --validation-run-id $ValidationRunId `
            --validation-run-attempt $ValidationRunAttempt `
            --gate-metadata $gatePath `
            --trusted-source-root $trusted `
            --output $output *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Trusted raw evidence validation failed.' }
        if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
            throw 'Trusted raw evidence validator did not create its statement.'
        }
    }
    finally {
        if ($null -ne $scratch -and (Test-Path -LiteralPath $scratch)) {
            Remove-HostedScratch -Root $scratch -RunnerRoot $RunnerTemp
        }
    }
    Write-Host 'Hosted VM evidence validated and private raw input removed.'
}
catch {
    throw 'Hosted VM evidence validation failed closed.'
}
