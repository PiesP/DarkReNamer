[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][string] $ArtifactId,
    [Parameter(Mandatory)][string] $ExpectedArtifactSha256,
    [Parameter(Mandatory)][string] $ExpectedArtifactName,
    [Parameter(Mandatory)][string] $ArchivePath,
    [Net.Http.HttpClient] $DownloadClient
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'download-bounded-github-data.ps1') -LibraryOnly
$maximumArchiveBytes = [long]512 * 1024 * 1024

if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $ArtifactId -cnotmatch '^[1-9][0-9]*$' -or
    $ExpectedArtifactSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $ExpectedArtifactName -cnotmatch '^DarkReNamer-dry-run-[1-9][0-9]*-[1-9][0-9]*-windows$' -or
    [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw 'Verified candidate artifact download inputs are invalid.'
}
if (Test-Path -LiteralPath $ArchivePath) {
    throw 'Candidate archive output already exists.'
}
$metadataText = @(& gh api "repos/$Repository/actions/artifacts/$ArtifactId" 2>$null)
if ($LASTEXITCODE -ne 0 -or $metadataText.Count -eq 0) {
    throw 'Authenticated candidate artifact metadata retrieval failed.'
}
try {
    $artifact = ($metadataText -join "`n") | ConvertFrom-Json
}
catch {
    throw 'Authenticated candidate artifact metadata is invalid JSON.'
}
if ($artifact.id -isnot [long] -or [string]$artifact.id -cne $ArtifactId -or
    $artifact.name -cne $ExpectedArtifactName -or
    $artifact.expired -isnot [bool] -or $artifact.expired -or
    $artifact.digest -cne "sha256:$ExpectedArtifactSha256") {
    throw 'Authenticated candidate artifact identity or digest differs from approval.'
}
Assert-BoundedDownloadSize -Size $artifact.size_in_bytes `
    -Maximum $maximumArchiveBytes -Label 'Candidate artifact size_in_bytes'
Save-BoundedGitHubData `
    -ApiUri "https://api.github.com/repos/$Repository/actions/artifacts/$ArtifactId/zip" `
    -OutputPath $ArchivePath `
    -ExpectedSize $artifact.size_in_bytes `
    -MaximumBytes $maximumArchiveBytes `
    -Token $env:GH_TOKEN `
    -Accept 'application/vnd.github+json' `
    -Client $DownloadClient
$actualDigest = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualDigest -cne $ExpectedArtifactSha256) {
    throw 'Downloaded candidate ZIP bytes differ from the independently approved digest.'
}
