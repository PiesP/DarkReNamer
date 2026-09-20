$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Fails {
    param([Parameter(Mandatory)][scriptblock] $Action, [Parameter(Mandatory)][string] $Fragment)
    try { & $Action }
    catch {
        if ($_.Exception.Message.Contains($Fragment, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
        throw
    }
    throw "Expected failure containing '$Fragment'."
}

$wrapper = Join-Path $PSScriptRoot 'run-vm-automated-hosted.ps1'
. $wrapper -LibraryOnly

Assert-HostedDecimal -Value '1' -Label 'fixture'
Assert-HostedDecimal -Value ([string][long]::MaxValue) -Label 'fixture'
foreach ($value in @('0', '01', '-1', '1e2', '9223372036854775808')) {
    Assert-Fails { Assert-HostedDecimal -Value $value -Label 'fixture' } 'bounded positive'
}
Assert-HostedDigest -Value ('a' * 40) -Length 40 -Label 'source'
Assert-HostedDigest -Value ('b' * 64) -Length 64 -Label 'archive'
Assert-Fails { Assert-HostedDigest -Value ('A' * 40) -Length 40 -Label 'source' } 'lowercase'

$owner = [pscustomobject]@{ id = [long]17; login = 'PiesP'; type = 'User' }
$repoFixture = [pscustomobject]@{ id = [long]29; full_name = 'PiesP/DarkReNamer'; owner = $owner }
Assert-HostedRepository -Metadata $repoFixture -ExpectedRepository 'PiesP/DarkReNamer'
$candidateRun = [pscustomobject]@{
    id = [long]31; run_attempt = [long]2
    path = '.github/workflows/release.yaml'; event = 'workflow_dispatch'
    head_branch = 'master'; head_sha = 'a' * 40
    status = 'completed'; conclusion = 'success'
    repository = [pscustomobject]@{ id = [long]29 }
    head_repository = [pscustomobject]@{ id = [long]29 }
}
Assert-HostedRun -Run $candidateRun `
    -ExpectedPath '.github/workflows/release.yaml' `
    -ExpectedEvent 'workflow_dispatch' `
    -ExpectedSourceSha ('a' * 40) `
    -ExpectedRepositoryId 29 `
    -ExpectedRunId '31' `
    -ExpectedRunAttempt '2'

$candidateJobs = [pscustomobject]@{
    total_count = [long]1
    jobs = @([pscustomobject]@{
        name = 'candidate/build-windows'; status = 'completed'; conclusion = 'success'
    })
}
$reducedCandidateJobs = @(Get-HostedGateJobs `
    -Document $candidateJobs `
    -ExpectedNames @('candidate/build-windows'))
foreach ($mutation in @('extra', 'failed', 'wrong')) {
    $fixture = $candidateJobs | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    if ($mutation -eq 'extra') {
        $fixture.total_count = [long]2
    }
    elseif ($mutation -eq 'failed') {
        $fixture.jobs[0].conclusion = 'failure'
    }
    else {
        $fixture.jobs[0].name = 'untrusted/job'
    }
    Assert-Fails {
        Get-HostedGateJobs -Document $fixture -ExpectedNames @('candidate/build-windows')
    } 'job'
}

$artifact = [pscustomobject]@{
    id = [long]41
    name = 'DarkReNamer-dry-run-31-2-windows'
    digest = 'sha256:' + ('b' * 64)
    size_in_bytes = [long]123
    expired = $false
    workflow_run = [pscustomobject]@{ id = [long]31; head_sha = 'a' * 40 }
}
$ciRun = $candidateRun | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$ciRun.id = [long]37
$ciRun.run_attempt = [long]1
$ciRun.path = '.github/workflows/ci.yaml'
$ciRun.event = 'push'
$ciJobs = @(
    'pr-gate/quality', 'pr-gate/security', 'pr-gate/unit', 'pr-gate/windows' |
        ForEach-Object { [ordered]@{ name = $_; status = 'completed'; conclusion = 'success' } }
)
$gate = New-HostedGateMetadata `
    -RepositoryMetadata $repoFixture `
    -CandidateRun $candidateRun `
    -CandidateJobs $reducedCandidateJobs `
    -CandidateArtifact $artifact `
    -CiRun $ciRun `
    -CiJobs $ciJobs
if ($gate.candidate.artifact_sha256 -cne ('b' * 64) -or
    $gate.candidate.run.id -ne 31 -or
    @($gate.ci.jobs).Count -ne 4 -or
    $gate.repository.owner.login -cne 'PiesP') {
    throw 'Reduced hosted gate metadata omitted an authenticated binding.'
}
$artifact.digest = 'sha512:' + ('b' * 64)
Assert-Fails {
    New-HostedGateMetadata `
        -RepositoryMetadata $repoFixture `
        -CandidateRun $candidateRun `
        -CandidateJobs $reducedCandidateJobs `
        -CandidateArtifact $artifact `
        -CiRun $ciRun `
        -CiJobs $ciJobs
} 'artifact metadata'

function New-HostedInvocationFixture {
    param([Parameter(Mandatory)][string] $Root)

    $trusted = Join-Path $Root 'trusted'
    $candidate = Join-Path $Root 'candidate'
    $runner = Join-Path $Root 'runner'
    foreach ($directory in @($trusted, $candidate, $runner, (Join-Path $trusted 'scripts'))) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $mockPython = Join-Path $Root 'mock-python.ps1'
    [IO.File]::WriteAllText($mockPython, @'
param([Parameter(ValueFromRemainingArguments = $true)][object[]] $MockArguments)
$validator = [string]$MockArguments[0]
[IO.File]::AppendAllText($env:MOCK_HOSTED_LOG, "python:$validator`n")
if ($validator.EndsWith('validate-vm-automated-evidence.py', [StringComparison]::Ordinal)) {
    if ($env:MOCK_HOSTED_SCENARIO -ceq 'raw-validator-failure') {
        $global:LASTEXITCODE = 19
        return
    }
    $outputIndex = [Array]::IndexOf($MockArguments, '--output')
    if ($outputIndex -lt 0 -or $outputIndex + 1 -ge $MockArguments.Count) {
        throw 'Mock raw validator received no output path.'
    }
    [IO.File]::WriteAllText(
        [string]$MockArguments[$outputIndex + 1],
        '{"schema_version":1}',
        [Text.UTF8Encoding]::new($false)
    )
}
$global:LASTEXITCODE = 0
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $trusted 'scripts/validate-release-candidate-metadata.ps1'),
        @'
param(
    $RunMetadataPath,
    $ArtifactMetadataPath,
    $ExpectedRunId,
    $ExpectedRunAttempt,
    $ExpectedArtifactId,
    $ExpectedSourceSha,
    $ExpectedArtifactName
)
'@,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $trusted 'scripts/validate-release-handoff.ps1'),
        @"
param(`$SourceRoot, `$HandoffRoot, [switch] `$PassThru)
[pscustomobject]@{
    workflow_run = '31'
    source_sha = '$('a' * 40)'
    executable = [pscustomobject]@{ sha256 = '$('b' * 64)' }
}
"@,
        [Text.UTF8Encoding]::new($false)
    )
    [pscustomobject]@{
        trusted = $trusted
        candidate = $candidate
        runner = $runner
        python = $mockPython
        output = Join-Path $Root 'validation-statement.json'
        log = Join-Path $Root 'events.log'
    }
}

function Invoke-HostedInvocationScenario {
    param(
        [Parameter(Mandatory)][ValidateSet(
            'success', 'candidate-attestation-failure', 'raw-validator-failure', 'cleanup-failure'
        )][string] $Scenario
    )

    $root = Join-Path ([IO.Path]::GetTempPath()) (
        'darkrenamer-hosted-invocation-' + [guid]::NewGuid().ToString('N')
    )
    [void](New-Item -ItemType Directory -Path $root)
    $fixture = New-HostedInvocationFixture -Root $root
    $oldEnvironment = @{
        GH_TOKEN = $env:GH_TOKEN
        GITHUB_ACTOR = $env:GITHUB_ACTOR
        GITHUB_REF = $env:GITHUB_REF
        GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY
        GITHUB_SHA = $env:GITHUB_SHA
        MOCK_HOSTED_LOG = $env:MOCK_HOSTED_LOG
        MOCK_HOSTED_RUNNER = $env:MOCK_HOSTED_RUNNER
        MOCK_HOSTED_SCENARIO = $env:MOCK_HOSTED_SCENARIO
    }
    $env:GH_TOKEN = 'test-token'
    $env:GITHUB_ACTOR = 'PiesP'
    $env:GITHUB_REF = 'refs/heads/master'
    $env:GITHUB_REPOSITORY = 'PiesP/DarkReNamer'
    $env:GITHUB_SHA = 'a' * 40
    $env:MOCK_HOSTED_LOG = $fixture.log
    $env:MOCK_HOSTED_RUNNER = $fixture.runner
    $env:MOCK_HOSTED_SCENARIO = $Scenario
    function global:git {
        param(
            [Alias('C')][string] $RepositoryPath,
            [Parameter(ValueFromRemainingArguments = $true)][object[]] $CommandArguments
        )
        $global:LASTEXITCODE = 0
        'a' * 40
    }
    function global:gh {
        $CommandArguments = @($args)
        if ($CommandArguments[0] -ceq 'attestation') {
            $scratchCount = @(Get-ChildItem -LiteralPath $env:MOCK_HOSTED_RUNNER -Force |
                Where-Object Name -Like 'darkrenamer-vm-hosted-*').Count
            [IO.File]::AppendAllText(
                $env:MOCK_HOSTED_LOG,
                "candidate-attestation:scratch=$scratchCount`n"
            )
            $global:LASTEXITCODE = if (
                $env:MOCK_HOSTED_SCENARIO -ceq 'candidate-attestation-failure'
            ) { 23 } else { 0 }
            return
        }
        $endpoint = [string]$CommandArguments[1]
        $document = if ($endpoint -ceq 'repos/PiesP/DarkReNamer') {
            [ordered]@{
                id = [long]29
                full_name = 'PiesP/DarkReNamer'
                owner = [ordered]@{ id = [long]17; login = 'PiesP'; type = 'User' }
            }
        }
        elseif ($endpoint -like '*/actions/runs/31/attempts/2/jobs*') {
            [ordered]@{ total_count = [long]1; jobs = @(
                [ordered]@{ name = 'candidate/build-windows'; status = 'completed'; conclusion = 'success' }
            ) }
        }
        elseif ($endpoint -like '*/actions/runs/31/attempts/2') {
            [ordered]@{
                id = [long]31; run_attempt = [long]2
                path = '.github/workflows/release.yaml'; event = 'workflow_dispatch'
                head_branch = 'master'; head_sha = 'a' * 40
                status = 'completed'; conclusion = 'success'
                repository = [ordered]@{ id = [long]29 }
                head_repository = [ordered]@{ id = [long]29 }
            }
        }
        elseif ($endpoint -like '*/actions/artifacts/41') {
            [ordered]@{
                id = [long]41; name = 'DarkReNamer-dry-run-31-2-windows'
                digest = 'sha256:' + ('b' * 64); size_in_bytes = [long]123; expired = $false
                workflow_run = [ordered]@{
                    id = [long]31; head_branch = 'master'; head_sha = 'a' * 40
                }
            }
        }
        elseif ($endpoint -like '*/actions/workflows/ci.yaml/runs*') {
            [ordered]@{ workflow_runs = @([ordered]@{
                id = [long]37; run_attempt = [long]1
                path = '.github/workflows/ci.yaml'; event = 'push'
                head_branch = 'master'; head_sha = 'a' * 40
                status = 'completed'; conclusion = 'success'
                repository = [ordered]@{ id = [long]29 }
                head_repository = [ordered]@{ id = [long]29 }
            }) }
        }
        elseif ($endpoint -like '*/actions/runs/37/attempts/1/jobs*') {
            [ordered]@{ total_count = [long]4; jobs = @(
                'pr-gate/quality', 'pr-gate/security', 'pr-gate/unit', 'pr-gate/windows' |
                    ForEach-Object {
                        [ordered]@{ name = $_; status = 'completed'; conclusion = 'success' }
                    }
            ) }
        }
        elseif ($endpoint -like '*/actions/runs/37/attempts/1') {
            [ordered]@{
                id = [long]37; run_attempt = [long]1
                path = '.github/workflows/ci.yaml'; event = 'push'
                head_branch = 'master'; head_sha = 'a' * 40
                status = 'completed'; conclusion = 'success'
                repository = [ordered]@{ id = [long]29 }
                head_repository = [ordered]@{ id = [long]29 }
            }
        }
        else { [ordered]@{} }
        $global:LASTEXITCODE = 0
        $document | ConvertTo-Json -Depth 8 -Compress
    }
    function global:Invoke-WebRequest {
        param($Uri, $Headers, $OutFile, $MaximumRedirection)
        [IO.File]::WriteAllBytes([string]$OutFile, [byte[]](1, 2, 3))
    }
    function global:Remove-Item {
        param([string] $LiteralPath, [switch] $Recurse, [switch] $Force)
        if ([IO.Path]::GetFileName($LiteralPath) -like 'darkrenamer-vm-hosted-*') {
            [IO.File]::AppendAllText($env:MOCK_HOSTED_LOG, "scratch-cleanup-attempt`n")
            if ($env:MOCK_HOSTED_SCENARIO -ceq 'cleanup-failure') {
                throw 'Injected scratch cleanup failure.'
            }
        }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
    }

    $wrapperSucceeded = $false
    $candidateAttestationAttempted = $false
    $statementAttestationReached = $false
    try {
        try {
            & $wrapper `
                -Repository 'PiesP/DarkReNamer' `
                -CandidateRunId '31' `
                -CandidateRunAttempt '2' `
                -CandidateArtifactId '41' `
                -CandidateSourceSha ('a' * 40) `
                -ExpectedExeSha256 ('b' * 64) `
                -IngressReleaseId '43' `
                -IngressAssetId '47' `
                -IngressArchiveSha256 ('c' * 64) `
                -IngressArchiveSize '3' `
                -ValidationRunId '53' `
                -ValidationRunAttempt '1' `
                -CandidateHandoffRoot $fixture.candidate `
                -TrustedSourceRoot $fixture.trusted `
                -OutputPath $fixture.output `
                -RunnerTemp $fixture.runner `
                -PythonExecutable $fixture.python *> $null
            $wrapperSucceeded = $true
        }
        catch {
        }
        if ($wrapperSucceeded) {
            $candidateAttestationAttempted = $true
            & gh attestation verify 'candidate/DarkReNamer.exe' `
                --repo $env:GITHUB_REPOSITORY `
                --signer-workflow "$env:GITHUB_REPOSITORY/.github/workflows/release.yaml" `
                --source-digest ('a' * 40) `
                --source-ref 'refs/heads/master' `
                --deny-self-hosted-runners *> $null
            if ($LASTEXITCODE -ne 0) {
                throw 'Original candidate attestation verification failed.'
            }
            $statementAttestationReached = $true
            [IO.File]::AppendAllText($fixture.log, "statement-attestation-boundary`n")
        }
    }
    catch {
    }
    finally {
        $scratchCount = @(Get-ChildItem -LiteralPath $fixture.runner -Force |
            Where-Object Name -Like 'darkrenamer-vm-hosted-*').Count
        $events = if (Test-Path -LiteralPath $fixture.log -PathType Leaf) {
            @(Get-Content -LiteralPath $fixture.log)
        }
        else { @() }
        $outcome = [pscustomobject]@{
            wrapper_succeeded = $wrapperSucceeded
            output_exists = Test-Path -LiteralPath $fixture.output -PathType Leaf
            candidate_attestation_attempted = $candidateAttestationAttempted
            statement_attestation_reached = $statementAttestationReached
            scratch_count = $scratchCount
            events = $events
        }
        foreach ($name in @('git', 'gh', 'Invoke-WebRequest', 'Remove-Item')) {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath ("Function:\$name") `
                -Force -ErrorAction SilentlyContinue
        }
        foreach ($entry in $oldEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force
    }
    $outcome
}

$success = Invoke-HostedInvocationScenario -Scenario success
if (-not $success.wrapper_succeeded -or -not $success.output_exists -or
    -not $success.candidate_attestation_attempted -or
    -not $success.statement_attestation_reached -or $success.scratch_count -ne 0 -or
    $success.events -notcontains 'scratch-cleanup-attempt' -or
    $success.events -notcontains 'candidate-attestation:scratch=0') {
    throw 'Successful hosted invocation did not clean private scratch before attestation.'
}

$candidateFailure = Invoke-HostedInvocationScenario -Scenario candidate-attestation-failure
if (-not $candidateFailure.wrapper_succeeded -or -not $candidateFailure.output_exists -or
    -not $candidateFailure.candidate_attestation_attempted -or
    $candidateFailure.statement_attestation_reached -or $candidateFailure.scratch_count -ne 0 -or
    $candidateFailure.events -notcontains 'scratch-cleanup-attempt' -or
    $candidateFailure.events -notcontains 'candidate-attestation:scratch=0') {
    throw 'Candidate attestation failure reached the statement attestation boundary.'
}

$rawFailure = Invoke-HostedInvocationScenario -Scenario raw-validator-failure
if ($rawFailure.wrapper_succeeded -or $rawFailure.output_exists -or
    $rawFailure.candidate_attestation_attempted -or $rawFailure.statement_attestation_reached -or
    $rawFailure.scratch_count -ne 0 -or
    $rawFailure.events -notcontains 'scratch-cleanup-attempt' -or
    -not @($rawFailure.events | Where-Object {
        $_ -like 'python:*validate-vm-automated-evidence.py'
    }).Count) {
    throw 'Raw validator failure did not fail closed and clean private scratch.'
}

$cleanupFailure = Invoke-HostedInvocationScenario -Scenario cleanup-failure
if ($cleanupFailure.wrapper_succeeded -or -not $cleanupFailure.output_exists -or
    $cleanupFailure.candidate_attestation_attempted -or
    $cleanupFailure.statement_attestation_reached -or $cleanupFailure.scratch_count -ne 1 -or
    $cleanupFailure.events -notcontains 'scratch-cleanup-attempt') {
    throw 'Scratch cleanup failure reached a later hosted attestation boundary.'
}

$parseErrors = $null
$tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $wrapper, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Hosted wrapper has parser errors.' }
$text = $ast.Extent.Text
foreach ($required in @(
    'actions/runs/$CandidateRunId/attempts/$CandidateRunAttempt',
    'actions/workflows/ci.yaml/runs?branch=master&event=push&status=success',
    'releases/assets/$IngressAssetId',
    'validate-vm-automated-authority.py',
    'validate-release-candidate-metadata.ps1',
    'validate-release-handoff.ps1',
    'validate-vm-automated-evidence.py',
    '--gate-metadata',
    'Remove-HostedScratch'
)) {
    if (-not $text.Contains($required, [StringComparison]::Ordinal)) {
        throw "Hosted wrapper contract is missing '$required'."
    }
}
foreach ($forbidden in @('upload-artifact', 'http://', '-Uri $')) {
    if ($text.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Hosted wrapper contains forbidden transport '$forbidden'."
    }
}

$workflow = Get-Content -LiteralPath (
    Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/vm-acceptance.yaml'
) -Raw
$deriveIndex = $workflow.IndexOf('name: Derive canonical statement from private raw evidence',
    [StringComparison]::Ordinal)
$candidateAttestationIndex = $workflow.IndexOf('name: Verify original candidate provenance',
    [StringComparison]::Ordinal)
$statementAttestationIndex = $workflow.IndexOf('name: Attest only the canonical path-free statement',
    [StringComparison]::Ordinal)
if ($deriveIndex -lt 0 -or $candidateAttestationIndex -le $deriveIndex -or
    $statementAttestationIndex -le $candidateAttestationIndex) {
    throw 'Hosted workflow does not preserve derive, candidate verification, statement attestation order.'
}
foreach ($required in @(
    'gh attestation verify candidate/DarkReNamer.exe',
    "if (`$LASTEXITCODE -ne 0) { throw 'Original candidate attestation verification failed.' }",
    'uses: actions/attest@',
    'subject-path: validation-statement.json'
)) {
    if (-not $workflow.Contains($required, [StringComparison]::Ordinal)) {
        throw "Hosted workflow attestation contract is missing '$required'."
    }
}

Write-Host 'Hosted VM validation wrapper tests passed.'
