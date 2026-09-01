[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,
    [Parameter(Mandatory)]
    [string] $HandoffRoot,
    [Parameter(Mandatory)]
    [string] $EvidencePath,
    [Parameter(Mandatory)]
    [string] $VisualEvidenceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$handoffValidator = Join-Path $PSScriptRoot 'validate-release-handoff.ps1'
$evidenceValidator = Join-Path $PSScriptRoot 'validate-windows-acceptance-evidence.ps1'
foreach ($validator in $handoffValidator, $evidenceValidator) {
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw "Required validator is missing: $validator"
    }
}

& $handoffValidator -SourceRoot $SourceRoot -HandoffRoot $HandoffRoot
$evidence = & $evidenceValidator `
    -EvidencePath $EvidencePath `
    -VisualEvidenceRoot $VisualEvidenceRoot `
    -PassThru

$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
$handoffPath = (Resolve-Path -LiteralPath $HandoffRoot).Path

$sourceHead = @(& git -C $sourcePath rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $sourceHead.Count -ne 1 -or $sourceHead[0] -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Source HEAD could not be resolved as a full Git SHA.'
}

$provenance = Get-Content -LiteralPath (Join-Path $handoffPath 'release-handoff.json') -Raw | ConvertFrom-Json

if (-not [string]::Equals($evidence.source_sha, $sourceHead[0], [StringComparison]::Ordinal)) {
    throw 'Acceptance evidence source_sha does not match checkout HEAD.'
}
if (-not [string]::Equals($evidence.source_sha, $provenance.source_sha, [StringComparison]::Ordinal)) {
    throw 'Acceptance evidence source_sha does not match release handoff provenance.'
}
if (-not [string]::Equals($evidence.artifact.origin, 'actions-handoff', [StringComparison]::Ordinal)) {
    throw 'Release acceptance evidence must identify artifact.origin as actions-handoff.'
}
if (-not [string]::Equals($evidence.artifact.workflow_run, $provenance.workflow_run, [StringComparison]::Ordinal)) {
    throw 'Acceptance evidence artifact.workflow_run does not match release handoff provenance.'
}
if (-not [string]::Equals($evidence.artifact.filename, $provenance.executable.filename, [StringComparison]::Ordinal)) {
    throw 'Acceptance evidence artifact.filename does not match release handoff provenance.'
}
if (-not [string]::Equals($evidence.artifact.sha256, $provenance.executable.sha256, [StringComparison]::Ordinal)) {
    throw 'Acceptance evidence artifact.sha256 does not match release handoff provenance.'
}

$actualExeHash = (Get-FileHash `
        -LiteralPath (Join-Path $handoffPath $provenance.executable.filename) `
        -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not [string]::Equals($evidence.artifact.sha256, $actualExeHash, [StringComparison]::Ordinal)) {
    throw 'Acceptance evidence artifact.sha256 does not match the release handoff executable bytes.'
}

$hddBenchmarkRows = @($evidence.benchmarks | Where-Object { $_.media -ceq 'hdd' })
$limitation = if ($hddBenchmarkRows.Count -eq 0) {
    ' with HDD-unavailable limitation'
}
else {
    ''
}
Write-Host "Validated complete Windows acceptance$limitation against release handoff run $($provenance.workflow_run) at source $($sourceHead[0])."
