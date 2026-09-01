[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$generator = Join-Path $PSScriptRoot 'new-windows-acceptance-draft.ps1'
$validator = Join-Path $PSScriptRoot 'validate-windows-acceptance-evidence.ps1'
if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) {
    throw "Windows acceptance draft generator is missing: $generator"
}
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Windows acceptance evidence validator is missing: $validator"
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Write-JsonObject {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object] $Value)
    Write-Utf8NoBom -Path $Path -Content (($Value | ConvertTo-Json -Depth 10) + "`n")
}

function Write-HandoffFixture {
    param(
        [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $HandoffRoot,
        [Parameter(Mandatory)][string] $SourceSha,
        [Parameter(Mandatory)][string] $WorkflowRun
    )

    New-Item -ItemType Directory -Path $HandoffRoot | Out-Null
    foreach ($name in 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DISTRIBUTION.md') {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination $HandoffRoot
    }
    [IO.File]::WriteAllBytes(
        (Join-Path $HandoffRoot 'DarkReNamer.exe'),
        [byte[]](0x4d, 0x5a, 0x01, 0x02, 0x03)
    )
    [IO.File]::WriteAllBytes(
        (Join-Path $HandoffRoot 'DarkReNamer.pdb'),
        [byte[]](0x50, 0x44, 0x42, 0x00)
    )
    Write-Utf8NoBom `
        -Path (Join-Path $HandoffRoot 'DarkReNamer.cdx.json') `
        -Content '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[{"type":"application","name":"darknamer-app","version":"0.1.0"}]}'
    Compress-Archive `
        -LiteralPath (Join-Path $HandoffRoot 'DarkReNamer.pdb') `
        -DestinationPath (Join-Path $HandoffRoot 'DarkReNamer-debug-symbols.zip')

    $executableHash = (Get-FileHash `
        -LiteralPath (Join-Path $HandoffRoot 'DarkReNamer.exe') `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-JsonObject `
        -Path (Join-Path $HandoffRoot 'release-handoff.json') `
        -Value ([ordered]@{
            schema_version = 1
            source_sha = $SourceSha
            workflow_run = $WorkflowRun
            executable = [ordered]@{
                filename = 'DarkReNamer.exe'
                sha256 = $executableHash
            }
        })

    $toolchain = Get-Content -LiteralPath (Join-Path $SourceRoot 'rust-toolchain.toml') -Raw
    $channelMatch = [regex]::Match($toolchain, '(?m)^\s*channel\s*=\s*"([^"]+)"')
    if (-not $channelMatch.Success) {
        throw 'Fixture could not resolve the Rust toolchain channel.'
    }
    $cargoLockPackageCount = [regex]::Matches(
        (Get-Content -LiteralPath (Join-Path $SourceRoot 'Cargo.lock') -Raw),
        '(?m)^\[\[package\]\]\s*$'
    ).Count
    Write-JsonObject `
        -Path (Join-Path $HandoffRoot 'release-metrics.json') `
        -Value ([ordered]@{
            schema_version = 1
            source_sha = $SourceSha
            rustc_version = "rustc $($channelMatch.Groups[1].Value) (fixture 2026-09-01)"
            target_triple = 'x86_64-pc-windows-msvc'
            darkrenamer_exe_bytes = (Get-Item -LiteralPath (Join-Path $HandoffRoot 'DarkReNamer.exe')).Length
            debug_symbols_zip_bytes = (Get-Item -LiteralPath (Join-Path $HandoffRoot 'DarkReNamer-debug-symbols.zip')).Length
            sbom_bytes = (Get-Item -LiteralPath (Join-Path $HandoffRoot 'DarkReNamer.cdx.json')).Length
            cargo_lock_package_count = $cargoLockPackageCount
        })

    $checksumSubjects = @(
        'DarkReNamer-debug-symbols.zip'
        'DarkReNamer.cdx.json'
        'DarkReNamer.exe'
        'DISTRIBUTION.md'
        'LICENSE'
        'release-handoff.json'
        'release-metrics.json'
        'THIRD_PARTY_NOTICES.md'
    )
    $checksumLines = foreach ($name in $checksumSubjects) {
        $hash = (Get-FileHash `
            -LiteralPath (Join-Path $HandoffRoot $name) `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash *$name"
    }
    Write-Utf8NoBom `
        -Path (Join-Path $HandoffRoot 'SHA256SUMS.txt') `
        -Content (($checksumLines -join "`n") + "`n")
}

function Assert-NoOwnedTemporaryFiles {
    param([Parameter(Mandatory)][string] $OutputPath)

    $parent = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        return
    }
    $leaf = [IO.Path]::GetFileName($OutputPath)
    $temporaryFiles = @(
        Get-ChildItem -LiteralPath $parent -File |
            Where-Object { $_.Name -like ".$leaf.*.tmp" }
    )
    if ($temporaryFiles.Count -ne 0) {
        throw "Generator left owned temporary files for $OutputPath."
    }
}

function Assert-GeneratorFails {
    param(
        [Parameter(Mandatory)][scriptblock] $Command,
        [Parameter(Mandatory)][string] $ExpectedFragment,
        [Parameter(Mandatory)][string] $OutputPath,
        [switch] $OutputMayExist
    )

    try {
        & $Command
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedFragment*") {
            throw "Expected generator failure containing '$ExpectedFragment', got: $($_.Exception.Message)"
        }
        if (-not $OutputMayExist -and (Test-Path -LiteralPath $OutputPath)) {
            throw "Generator failure left an output file: $OutputPath"
        }
        Assert-NoOwnedTemporaryFiles -OutputPath $OutputPath
        return
    }
    throw "Expected generator failure containing '$ExpectedFragment', but generation succeeded."
}

function Assert-Draft {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $SourceSha,
        [Parameter(Mandatory)][string] $Origin,
        [Parameter(Mandatory)][string] $ExecutableSha,
        [Parameter(Mandatory)][string] $ReasonCode,
        [string] $WorkflowRun,
        [string[]] $ForbiddenPaths = @()
    )

    & $validator -EvidencePath $Path -Draft | Out-Null
    $raw = Get-Content -LiteralPath $Path -Raw
    $evidence = $raw | ConvertFrom-Json
    if ($evidence.schema_version -ne 2 -or $evidence.source_sha -cne $SourceSha) {
        throw 'Generated draft source or schema provenance is incorrect.'
    }
    if ($evidence.artifact.filename -cne 'DarkReNamer.exe' -or
        $evidence.artifact.sha256 -cne $ExecutableSha -or
        $evidence.artifact.origin -cne $Origin) {
        throw 'Generated draft executable provenance is incorrect.'
    }
    if ($Origin -eq 'actions-handoff') {
        if ($evidence.artifact.workflow_run -cne $WorkflowRun) {
            throw 'Generated draft workflow provenance is incorrect.'
        }
    }
    elseif ($null -ne $evidence.artifact.PSObject.Properties['workflow_run']) {
        throw 'Local-build draft must not contain workflow_run.'
    }
    if (@($evidence.operator_context).Count -ne 0 -or
        @($evidence.ui_matrix).Count -ne 24 -or
        @($evidence.scenarios).Count -ne 20 -or
        @($evidence.benchmarks).Count -ne 0 -or
        @($evidence.durability_trials).Count -ne 4 -or
        @($evidence.unexecuted).Count -ne 54) {
        throw 'Generated draft acceptance target counts are incorrect.'
    }
    foreach ($row in @($evidence.ui_matrix) + @($evidence.scenarios) + @($evidence.durability_trials)) {
        if ($row.status -cne 'not-run' -or $row.observation_code -cne 'not-executed') {
            throw 'Generated draft contains an invented executed observation.'
        }
    }
    if (@($evidence.unexecuted | Where-Object { $_.reason_code -cne $ReasonCode }).Count -ne 0) {
        throw 'Generated draft did not apply the selected unexecuted reason uniformly.'
    }
    if (@($evidence.unexecuted | Where-Object { $_.target -like 'benchmark|*' }).Count -ne 6) {
        throw 'Generated draft does not contain all six target-bound benchmark reasons.'
    }
    $ids = @($evidence.unexecuted.id)
    if (@($ids | Sort-Object -Unique).Count -ne 54) {
        throw 'Generated draft unexecuted identifiers are not unique.'
    }
    $jsonDocument = [Text.Json.JsonDocument]::Parse($raw)
    try {
        $recordedAtUtc = $jsonDocument.RootElement.GetProperty('recorded_at_utc').GetString()
    }
    finally {
        $jsonDocument.Dispose()
    }
    if ($recordedAtUtc -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') {
        throw 'Generated draft timestamp is not canonical UTC.'
    }
    foreach ($forbiddenPath in $ForbiddenPaths) {
        if (-not [string]::IsNullOrEmpty($forbiddenPath) -and $raw.Contains($forbiddenPath)) {
            throw "Generated draft leaked an input path: $forbiddenPath"
        }
    }
    if ($raw -match '(?i)"(?:username|user_name|operator_name|hostname|computer_name|machine_name|owner_name|narrative|note|windows_build|architecture|accessibility_tool|storage_model|filesystem|planning_ms|execution_ms|connection|free_space_bucket|power_mode|cleanup_observation)"\s*:') {
        throw 'Generated draft contains invented host, tool, storage, identity, or narrative data.'
    }
}

$sourceRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$sourceSha = (& git -C $sourceRoot rev-parse HEAD).Trim()
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-acceptance-draft-$([Guid]::NewGuid())"
$insideRepositoryOutput = Join-Path $sourceRoot '.stage4-generator-test-output.json'
$reparseParent = $null
$reparseTargetOutput = $null

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    if (Test-Path -LiteralPath $insideRepositoryOutput) {
        throw "Reserved inside-repository test output already exists: $insideRepositoryOutput"
    }

    $reasonParameter = (Get-Command $generator).Parameters['DefaultUnexecutedReason']
    $validateSet = @(
        $reasonParameter.Attributes |
            Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }
    )
    $schemaReasons = @(
        (Get-Content `
            -LiteralPath (Join-Path $PSScriptRoot 'windows-acceptance-evidence.schema.json') `
            -Raw |
            ConvertFrom-Json).'$defs'.unexecuted.properties.reason_code.enum
    )
    if ($validateSet.Count -ne 1 -or
        $validateSet[0].ValidValues.Count -ne $schemaReasons.Count -or
        @($schemaReasons | Where-Object { $validateSet[0].ValidValues -cnotcontains $_ }).Count -ne 0) {
        throw 'DefaultUnexecutedReason ValidateSet does not match the schema reason enum.'
    }

    $executablePath = Join-Path $testRoot 'DarkReNamer.exe'
    [IO.File]::WriteAllBytes($executablePath, [byte[]](0x4d, 0x5a, 0x10, 0x20))
    $executableHash = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()

    $reparseParent = Join-Path $testRoot 'apparently-external-parent'
    $reparseLeaf = ".stage5-reparse-output-$([Guid]::NewGuid().ToString('N')).json"
    $reparseTargetOutput = Join-Path (Join-Path $sourceRoot 'scripts') $reparseLeaf
    if (Test-Path -LiteralPath $reparseTargetOutput) {
        throw "Reserved reparse regression target already exists: $reparseTargetOutput"
    }
    if ($IsWindows) {
        New-Item `
            -ItemType Junction `
            -Path $reparseParent `
            -Target (Join-Path $sourceRoot 'scripts') |
            Out-Null
    }
    else {
        New-Item `
            -ItemType SymbolicLink `
            -Path $reparseParent `
            -Target (Join-Path $sourceRoot 'scripts') |
            Out-Null
    }
    $reparseOutput = Join-Path $reparseParent $reparseLeaf
    Assert-GeneratorFails `
        -Command {
            & $generator `
                -SourceRoot $sourceRoot `
                -OutputPath $reparseOutput `
                -ExecutablePath $executablePath
        } `
        -ExpectedFragment 'reparse point' `
        -OutputPath $reparseOutput
    if (Test-Path -LiteralPath $reparseTargetOutput) {
        throw 'Reparse-parent rejection created an output inside SourceRoot.'
    }
    Assert-NoOwnedTemporaryFiles -OutputPath $reparseOutput

    $localOutput = Join-Path $testRoot 'local-draft.json'
    & $generator -SourceRoot $sourceRoot -OutputPath $localOutput -ExecutablePath $executablePath
    Assert-Draft `
        -Path $localOutput `
        -SourceSha $sourceSha `
        -Origin 'local-build' `
        -ExecutableSha $executableHash `
        -ReasonCode 'scheduled-later' `
        -ForbiddenPaths @($sourceRoot, $testRoot, $executablePath)
    Assert-NoOwnedTemporaryFiles -OutputPath $localOutput

    $handoffRoot = Join-Path $testRoot 'handoff'
    $workflowRun = '33257061299'
    Write-HandoffFixture `
        -SourceRoot $sourceRoot `
        -HandoffRoot $handoffRoot `
        -SourceSha $sourceSha `
        -WorkflowRun $workflowRun
    $handoffExecutableHash = (Get-FileHash `
        -LiteralPath (Join-Path $handoffRoot 'DarkReNamer.exe') `
        -Algorithm SHA256).Hash.ToLowerInvariant()

    $global:DarkReNamerTestAuthenticodeStatus = 'NotSigned'
    function global:Get-AuthenticodeSignature {
        param([string] $FilePath)
        [pscustomobject]@{ Path = $FilePath; Status = $global:DarkReNamerTestAuthenticodeStatus }
    }

    $handoffOutput = Join-Path $testRoot 'handoff-draft.json'
    & $generator `
        -SourceRoot $sourceRoot `
        -OutputPath $handoffOutput `
        -HandoffRoot $handoffRoot `
        -DefaultUnexecutedReason 'not-in-run-scope'
    Assert-Draft `
        -Path $handoffOutput `
        -SourceSha $sourceSha `
        -Origin 'actions-handoff' `
        -ExecutableSha $handoffExecutableHash `
        -ReasonCode 'not-in-run-scope' `
        -WorkflowRun $workflowRun `
        -ForbiddenPaths @($sourceRoot, $testRoot, $handoffRoot)
    Assert-NoOwnedTemporaryFiles -OutputPath $handoffOutput

    $existingOutput = Join-Path $testRoot 'existing.json'
    [byte[]] $sentinel = 0x73, 0x65, 0x6e, 0x74, 0x69, 0x6e, 0x65, 0x6c
    [IO.File]::WriteAllBytes($existingOutput, $sentinel)
    Assert-GeneratorFails `
        -Command {
            & $generator -SourceRoot $sourceRoot -OutputPath $existingOutput -ExecutablePath $executablePath
        } `
        -ExpectedFragment 'already exists' `
        -OutputPath $existingOutput `
        -OutputMayExist
    $afterSentinel = [IO.File]::ReadAllBytes($existingOutput)
    if ([Convert]::ToHexString($sentinel) -cne [Convert]::ToHexString($afterSentinel)) {
        throw 'Existing destination changed after rejected generation.'
    }

    Assert-GeneratorFails `
        -Command {
            & $generator -SourceRoot $sourceRoot -OutputPath $insideRepositoryOutput -ExecutablePath $executablePath
        } `
        -ExpectedFragment 'outside SourceRoot' `
        -OutputPath $insideRepositoryOutput

    $invalidRootOutput = Join-Path $testRoot 'invalid-root.json'
    Assert-GeneratorFails `
        -Command {
            & $generator -SourceRoot $PSScriptRoot -OutputPath $invalidRootOutput -ExecutablePath $executablePath
        } `
        -ExpectedFragment 'exact Git worktree root' `
        -OutputPath $invalidRootOutput

    $missingExecutableOutput = Join-Path $testRoot 'missing-executable.json'
    Assert-GeneratorFails `
        -Command {
            & $generator `
                -SourceRoot $sourceRoot `
                -OutputPath $missingExecutableOutput `
                -ExecutablePath (Join-Path $testRoot 'missing-DarkReNamer.exe')
        } `
        -ExpectedFragment 'existing DarkReNamer.exe' `
        -OutputPath $missingExecutableOutput

    $invalidHandoffRoot = Join-Path $testRoot 'invalid-handoff'
    Copy-Item -LiteralPath $handoffRoot -Destination $invalidHandoffRoot -Recurse
    Remove-Item -LiteralPath (Join-Path $invalidHandoffRoot 'release-metrics.json')
    $invalidHandoffOutput = Join-Path $testRoot 'invalid-handoff.json'
    Assert-GeneratorFails `
        -Command {
            & $generator `
                -SourceRoot $sourceRoot `
                -OutputPath $invalidHandoffOutput `
                -HandoffRoot $invalidHandoffRoot
        } `
        -ExpectedFragment 'Release handoff layout mismatch' `
        -OutputPath $invalidHandoffOutput

    $missingParentOutput = Join-Path (Join-Path $testRoot 'missing-parent') 'draft.json'
    Assert-GeneratorFails `
        -Command {
            & $generator -SourceRoot $sourceRoot -OutputPath $missingParentOutput -ExecutablePath $executablePath
        } `
        -ExpectedFragment 'parent directory must already exist' `
        -OutputPath $missingParentOutput

    $relativeOutput = 'relative-draft.json'
    Assert-GeneratorFails `
        -Command {
            & $generator -SourceRoot $sourceRoot -OutputPath $relativeOutput -ExecutablePath $executablePath
        } `
        -ExpectedFragment 'OutputPath must be absolute' `
        -OutputPath (Join-Path $sourceRoot $relativeOutput)

    Write-Host 'Windows acceptance draft generator tests passed.'
}
finally {
    Remove-Item Function:\global:Get-AuthenticodeSignature -ErrorAction SilentlyContinue
    Remove-Variable DarkReNamerTestAuthenticodeStatus -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $insideRepositoryOutput -PathType Leaf) {
        Remove-Item -LiteralPath $insideRepositoryOutput -Force
    }
    if ($null -ne $reparseTargetOutput -and
        (Test-Path -LiteralPath $reparseTargetOutput -PathType Leaf)) {
        Remove-Item -LiteralPath $reparseTargetOutput -Force
    }
    if ($null -ne $reparseParent -and (Test-Path -LiteralPath $reparseParent)) {
        Remove-Item -LiteralPath $reparseParent -Force
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
