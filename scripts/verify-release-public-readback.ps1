[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][string] $ReleaseTag,
    [Parameter(Mandatory)][string] $CandidateRoot,
    [Parameter(Mandatory)][string] $StatementPath,
    [Parameter(Mandatory)][string] $ScratchRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'download-bounded-github-data.ps1') -LibraryOnly
$maximumPublicBytes = [long]512 * 1024 * 1024

if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $ReleaseTag -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$' -or
    [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw 'Public release readback inputs are invalid.'
}
if (Test-Path -LiteralPath $ScratchRoot) {
    throw 'Public readback scratch path already exists.'
}
[void](New-Item -ItemType Directory -Path $ScratchRoot)
$releasePath = Join-Path $ScratchRoot 'release.json'
$downloadedRoot = Join-Path $ScratchRoot 'assets'
[void](New-Item -ItemType Directory -Path $downloadedRoot)
$releaseText = @(& gh api "repos/$Repository/releases/tags/$ReleaseTag" 2>$null)
if ($LASTEXITCODE -ne 0 -or $releaseText.Count -eq 0) {
    throw 'Public release metadata could not be retrieved.'
}
[IO.File]::WriteAllLines($releasePath, [string[]]$releaseText,
    [Text.UTF8Encoding]::new($false))
$release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
if ($release.tag_name -cne $ReleaseTag -or $release.draft -isnot [bool] -or $release.draft) {
    throw 'Public release tag or state differs from the selected release.'
}
$names = @(python -I (Join-Path $PSScriptRoot 'validate-release-publication.py') list `
    --candidate-root $CandidateRoot)
if ($LASTEXITCODE -ne 0 -or $names.Count -eq 0) {
    throw 'Candidate publication list could not be loaded.'
}
$expectedNames = @($names | ForEach-Object { [IO.Path]::GetFileName($_) }) +
    @('validation-statement.json')
$assets = @($release.assets)
if ($assets.Count -ne $expectedNames.Count -or
    @($assets | Where-Object { $_.name -cnotin $expectedNames }).Count -ne 0 -or
    @($assets | Select-Object -ExpandProperty name -Unique).Count -ne $assets.Count) {
    throw 'Public release asset names differ from the exact publication list.'
}
$expectedSizes = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
$totalExpected = [long]0
foreach ($name in $expectedNames) {
    $source = if ($name -ceq 'validation-statement.json') {
        $StatementPath
    }
    else {
        Join-Path $CandidateRoot $name
    }
    $file = Get-Item -LiteralPath $source -ErrorAction Stop
    if ($file.PSIsContainer -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $file.Length -le 0 -or $file.Length -gt $maximumPublicBytes) {
        throw "Verified publication input is missing, unsupported or too large: $name"
    }
    $totalExpected += $file.Length
    if ($totalExpected -gt $maximumPublicBytes) {
        throw 'Verified publication input set exceeds the public readback byte budget.'
    }
    $expectedSizes.Add($name, [long]$file.Length)
}
foreach ($asset in $assets) {
    if ($asset.id -isnot [long] -or $asset.id -le 0 -or
        $asset.state -cne 'uploaded') {
        throw 'Public release asset metadata is incomplete.'
    }
    Assert-BoundedDownloadSize -Size $asset.size `
        -Maximum $maximumPublicBytes -Label "Public asset $($asset.name) size"
    if ($asset.size -ne $expectedSizes[$asset.name]) {
        throw "Public release asset metadata size differs from verified input: $($asset.name)"
    }
}
foreach ($asset in $assets) {
    Save-BoundedGitHubData `
        -ApiUri "https://api.github.com/repos/$Repository/releases/assets/$($asset.id)" `
        -OutputPath (Join-Path $downloadedRoot $asset.name) `
        -ExpectedSize $asset.size `
        -MaximumBytes $maximumPublicBytes `
        -Token $env:GH_TOKEN `
        -Accept 'application/octet-stream'
}
python -I (Join-Path $PSScriptRoot 'validate-release-publication.py') verify-public-readback `
    --candidate-root $CandidateRoot `
    --statement $StatementPath `
    --release-metadata $releasePath `
    --downloaded-root $downloadedRoot `
    --release-tag $ReleaseTag
if ($LASTEXITCODE -ne 0) {
    throw 'Public release asset readback differs from verified publication inputs.'
}
