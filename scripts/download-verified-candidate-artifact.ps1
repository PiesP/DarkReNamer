[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][string] $ArtifactId,
    [Parameter(Mandatory)][string] $ExpectedArtifactSha256,
    [Parameter(Mandatory)][string] $ExpectedArtifactName,
    [Parameter(Mandatory)][string] $ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The upload action emits an algorithm-qualified digest; promotion approval
# supplies the same SHA-256 as bare hex. Normalize only these two exact forms.
$digestMatch = [regex]::Match($ExpectedArtifactSha256, '^(?:sha256:)?([0-9a-f]{64})$')
if (-not $digestMatch.Success) { throw 'Verified candidate artifact download inputs are invalid.' }
$ExpectedArtifactSha256 = $digestMatch.Groups[1].Value

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
$headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $env:GH_TOKEN"
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'DarkReNamer-release-artifact-download'
}
Invoke-WebRequest `
    -Uri "https://api.github.com/repos/$Repository/actions/artifacts/$ArtifactId/zip" `
    -Headers $headers `
    -OutFile $ArchivePath `
    -MaximumRedirection 5 | Out-Null
$actualDigest = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualDigest -cne $ExpectedArtifactSha256) {
    throw 'Downloaded candidate ZIP bytes differ from the independently approved digest.'
}
