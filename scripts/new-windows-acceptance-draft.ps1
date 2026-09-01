[CmdletBinding(DefaultParameterSetName = 'LocalBuild')]
param(
    [Parameter(Mandatory, ParameterSetName = 'LocalBuild')]
    [Parameter(Mandatory, ParameterSetName = 'ActionsHandoff')]
    [string] $SourceRoot,

    [Parameter(Mandatory, ParameterSetName = 'LocalBuild')]
    [Parameter(Mandatory, ParameterSetName = 'ActionsHandoff')]
    [string] $OutputPath,

    [Parameter(Mandatory, ParameterSetName = 'LocalBuild')]
    [string] $ExecutablePath,

    [Parameter(Mandatory, ParameterSetName = 'ActionsHandoff')]
    [string] $HandoffRoot,

    [ValidateSet(
        'environment-unavailable',
        'hardware-unavailable',
        'authorization-not-granted',
        'scheduled-later',
        'blocked-by-failed-prerequisite',
        'not-in-run-scope'
    )]
    [string] $DefaultUnexecutedReason = 'scheduled-later'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version] '7.4') {
    throw 'Windows acceptance draft generation requires PowerShell 7.4 or newer (pwsh).'
}

function Get-StableUnexecutedId {
    param(
        [Parameter(Mandatory)]
        [string] $Target
    )

    $id = [regex]::Replace($Target.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
    if ($id.Length -eq 0 -or $id.Length -gt 64) {
        throw "Acceptance target cannot be represented as a stable unexecuted id: $Target"
    }
    return $id
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)]
        [string] $Candidate,
        [Parameter(Mandatory)]
        [string] $Root,
        [Parameter(Mandatory)]
        [StringComparison] $Comparison
    )

    $rootWithSeparator = $Root.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    return [string]::Equals($Candidate, $Root, $Comparison) -or
        $Candidate.StartsWith($rootWithSeparator, $Comparison)
}

function Assert-NoReparsePointInOutputAncestors {
    param(
        [Parameter(Mandatory)]
        [string] $ParentPath
    )

    $currentPath = [IO.Path]::GetFullPath($ParentPath)
    while ($null -ne $currentPath) {
        $item = Get-Item -LiteralPath $currentPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq
            [IO.FileAttributes]::ReparsePoint) {
            throw "OutputPath parent chain contains a reparse point: $currentPath"
        }
        $parent = [IO.Directory]::GetParent($currentPath)
        $currentPath = if ($null -eq $parent) { $null } else { $parent.FullName }
    }
}

$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
$sourceTopLevel = @(& git -C $sourcePath rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or $sourceTopLevel.Count -ne 1) {
    throw 'SourceRoot must identify a Git worktree root.'
}
$comparison = if ($IsWindows) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}
$resolvedSourceRoot = [IO.Path]::GetFullPath($sourcePath).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$resolvedTopLevel = [IO.Path]::GetFullPath($sourceTopLevel[0]).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
if (-not [string]::Equals($resolvedSourceRoot, $resolvedTopLevel, $comparison)) {
    throw 'SourceRoot must identify the exact Git worktree root.'
}
$sourceHead = @(& git -C $resolvedSourceRoot rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or $sourceHead.Count -ne 1 -or $sourceHead[0] -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Source HEAD could not be resolved as a full Git SHA.'
}

if (-not [IO.Path]::IsPathFullyQualified($OutputPath)) {
    throw 'OutputPath must be absolute.'
}
$requestedOutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputLeaf = [IO.Path]::GetFileName($requestedOutputPath)
if ([string]::IsNullOrEmpty($outputLeaf)) {
    throw 'OutputPath must identify a file.'
}
$requestedParent = [IO.Path]::GetDirectoryName($requestedOutputPath)
if ([string]::IsNullOrEmpty($requestedParent) -or
    -not (Test-Path -LiteralPath $requestedParent -PathType Container)) {
    throw 'OutputPath parent directory must already exist.'
}
$resolvedOutputParent = (Resolve-Path -LiteralPath $requestedParent).Path
$resolvedOutputPath = [IO.Path]::GetFullPath((Join-Path $resolvedOutputParent $outputLeaf))
Assert-NoReparsePointInOutputAncestors -ParentPath $requestedParent
if (Test-PathWithinRoot `
        -Candidate $resolvedOutputPath `
        -Root $resolvedSourceRoot `
        -Comparison $comparison) {
    throw 'OutputPath must be outside SourceRoot.'
}
if (Test-Path -LiteralPath $resolvedOutputPath) {
    throw 'OutputPath already exists; draft generation never overwrites a destination.'
}

$artifact = $null
$evidenceSourceSha = $null
if ($PSCmdlet.ParameterSetName -eq 'ActionsHandoff') {
    $handoffValidator = Join-Path $PSScriptRoot 'validate-release-handoff.ps1'
    if (-not (Test-Path -LiteralPath $handoffValidator -PathType Leaf)) {
        throw "Release handoff validator is missing: $handoffValidator"
    }
    $resolvedHandoffRoot = (Resolve-Path -LiteralPath $HandoffRoot).Path
    $handoff = & $handoffValidator `
        -SourceRoot $resolvedSourceRoot `
        -HandoffRoot $resolvedHandoffRoot `
        -PassThru
    $evidenceSourceSha = $handoff.source_sha
    $artifact = [ordered]@{
        filename = $handoff.executable.filename
        sha256 = $handoff.executable.sha256
        origin = 'actions-handoff'
        workflow_run = $handoff.workflow_run
    }
}
else {
    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        throw 'ExecutablePath must identify an existing DarkReNamer.exe file.'
    }
    $resolvedExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
    if (-not [string]::Equals(
            [IO.Path]::GetFileName($resolvedExecutablePath),
            'DarkReNamer.exe',
            [StringComparison]::Ordinal
        )) {
        throw 'ExecutablePath filename must be DarkReNamer.exe.'
    }
    if ((Get-Item -LiteralPath $resolvedExecutablePath).Length -le 0) {
        throw 'ExecutablePath must not be empty.'
    }
    $evidenceSourceSha = $sourceHead[0]
    $artifact = [ordered]@{
        filename = 'DarkReNamer.exe'
        sha256 = (Get-FileHash -LiteralPath $resolvedExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
        origin = 'local-build'
    }
}

$schemaPath = Join-Path $PSScriptRoot 'windows-acceptance-evidence.schema.json'
$evidenceValidator = Join-Path $PSScriptRoot 'validate-windows-acceptance-evidence.ps1'
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Windows acceptance evidence schema is missing: $schemaPath"
}
if (-not (Test-Path -LiteralPath $evidenceValidator -PathType Leaf)) {
    throw "Windows acceptance evidence validator is missing: $evidenceValidator"
}
$schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
$definitions = $schema.'$defs'
$allowedReasons = @($definitions.unexecuted.properties.reason_code.enum)
if ($allowedReasons -cnotcontains $DefaultUnexecutedReason) {
    throw 'DefaultUnexecutedReason is not allowed by the Windows acceptance evidence schema.'
}

$windowsProducts = @($definitions.operatorContext.properties.windows_product.enum)
$dpiValues = @($definitions.uiCell.properties.dpi_percent.enum)
$contrastValues = @($definitions.uiCell.properties.contrast.enum)
$scenarioKinds = @($definitions.scenario.properties.kind.enum)
$mediaKinds = @($definitions.benchmark.properties.media.enum)
$benchmarkCounts = @($definitions.benchmark.properties.count.enum)
$durabilityKinds = @($definitions.durabilityTrial.properties.kind.enum)

$unexecuted = [Collections.Generic.List[object]]::new()
$uiMatrix = [Collections.Generic.List[object]]::new()
foreach ($product in $windowsProducts) {
    foreach ($dpi in $dpiValues) {
        foreach ($contrast in $contrastValues) {
            $target = "ui|$product|$dpi|$contrast"
            $id = Get-StableUnexecutedId -Target $target
            $uiMatrix.Add([pscustomobject][ordered]@{
                windows_product = $product
                dpi_percent = $dpi
                contrast = $contrast
                status = 'not-run'
                observation_code = 'not-executed'
                unexecuted_id = $id
            })
            $unexecuted.Add([pscustomobject][ordered]@{
                id = $id
                target = $target
                reason_code = $DefaultUnexecutedReason
            })
        }
    }
}

$scenarios = [Collections.Generic.List[object]]::new()
foreach ($product in $windowsProducts) {
    foreach ($kind in $scenarioKinds) {
        $target = "scenario|$product|$kind"
        $id = Get-StableUnexecutedId -Target $target
        $scenarios.Add([pscustomobject][ordered]@{
            windows_product = $product
            kind = $kind
            status = 'not-run'
            observation_code = 'not-executed'
            unexecuted_id = $id
        })
        $unexecuted.Add([pscustomobject][ordered]@{
            id = $id
            target = $target
            reason_code = $DefaultUnexecutedReason
        })
    }
}

foreach ($media in $mediaKinds) {
    foreach ($count in $benchmarkCounts) {
        $target = "benchmark|$media|$count"
        $unexecuted.Add([pscustomobject][ordered]@{
            id = (Get-StableUnexecutedId -Target $target)
            target = $target
            reason_code = $DefaultUnexecutedReason
        })
    }
}

$durabilityTrials = [Collections.Generic.List[object]]::new()
foreach ($kind in $durabilityKinds) {
    $target = "durability|$kind"
    $id = Get-StableUnexecutedId -Target $target
    $durabilityTrials.Add([pscustomobject][ordered]@{
        kind = $kind
        status = 'not-run'
        observation_code = 'not-executed'
        unexecuted_id = $id
    })
    $unexecuted.Add([pscustomobject][ordered]@{
        id = $id
        target = $target
        reason_code = $DefaultUnexecutedReason
    })
}

$evidence = [ordered]@{
    schema_version = $schema.properties.schema_version.const
    source_sha = $evidenceSourceSha
    artifact = $artifact
    recorded_at_utc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
    operator_context = @()
    ui_matrix = @($uiMatrix)
    visual_captures = @()
    scenarios = @($scenarios)
    benchmarks = @()
    durability_trials = @($durabilityTrials)
    unexecuted = @($unexecuted)
}
$json = ($evidence | ConvertTo-Json -Depth 10) + "`n"

$temporaryPath = Join-Path `
    $resolvedOutputParent `
    ".$outputLeaf.$([Guid]::NewGuid().ToString('N')).tmp"
$temporaryOwned = $false
try {
    Assert-NoReparsePointInOutputAncestors -ParentPath $requestedParent
    $stream = [IO.FileStream]::new(
        $temporaryPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $temporaryOwned = $true
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }

    & $evidenceValidator -EvidencePath $temporaryPath -Draft
    Assert-NoReparsePointInOutputAncestors -ParentPath $requestedParent
    [IO.File]::Move($temporaryPath, $resolvedOutputPath)
    $temporaryOwned = $false
}
finally {
    if ($temporaryOwned -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

Write-Host "Created Windows acceptance draft at $resolvedOutputPath."
