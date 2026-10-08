[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
$helper = Join-Path (Get-ToolingTestPaths).ScriptsRoot 'download-verified-candidate-artifact.ps1'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-artifact-archive-$([Guid]::NewGuid().ToString('N'))"
$archive = Join-Path $root 'candidate.zip'
$bytes = [Text.Encoding]::UTF8.GetBytes('original complete archive bytes')
$digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
$name = 'DarkReNamer-dry-run-10-2-windows'
$previousToken = $env:GH_TOKEN
$env:GH_TOKEN = 'fixture-token'
$global:mockDigest = $digest
$global:mockDownloadedBytes = $bytes
$global:mockGhCalls = 0
$global:mockWebCalls = 0

function gh {
    if (($args -join ' ') -cne 'api repos/PiesP/DarkReNamer/actions/artifacts/20') {
        throw 'Unexpected authenticated artifact metadata endpoint.'
    }
    $global:mockGhCalls++
    $global:LASTEXITCODE = 0
    @{ id = [long]20; name = $name; expired = $false;
       digest = "sha256:$global:mockDigest" } | ConvertTo-Json -Compress
}

function Invoke-WebRequest {
    param($Uri, $Headers, $OutFile, $MaximumRedirection)
    if ($Uri -cne 'https://api.github.com/repos/PiesP/DarkReNamer/actions/artifacts/20/zip' -or
        $Headers.Authorization -cne 'Bearer fixture-token' -or
        $MaximumRedirection -ne 5) {
        throw 'Unexpected candidate archive download request.'
    }
    $global:mockWebCalls++
    [IO.File]::WriteAllBytes($OutFile, $global:mockDownloadedBytes)
}

function Assert-Fails {
    param([string]$Expected, [string]$ApprovedDigest = $digest)
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
    try {
        & $helper -Repository PiesP/DarkReNamer -ArtifactId 20 `
            -ExpectedArtifactSha256 $ApprovedDigest -ExpectedArtifactName $name `
            -ArchivePath $archive
    }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected archive validation failure: $Expected"
}

try {
    [void](New-Item -ItemType Directory -Path $root)
    & $helper -Repository PiesP/DarkReNamer -ArtifactId 20 `
        -ExpectedArtifactSha256 $digest -ExpectedArtifactName $name `
        -ArchivePath $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest) {
        throw 'Complete artifact archive digest changed.'
    }
    Remove-Item -LiteralPath $archive
    & $helper -Repository PiesP/DarkReNamer -ArtifactId 20 `
        -ExpectedArtifactSha256 "sha256:$digest" -ExpectedArtifactName $name `
        -ArchivePath $archive
    Assert-Fails -Expected 'inputs are invalid' -ApprovedDigest "sha512:$digest"
    Assert-Fails -Expected 'identity or digest differs' -ApprovedDigest ('b' * 64)
    $global:mockDownloadedBytes = [Text.Encoding]::UTF8.GetBytes('modified archive bytes')
    Assert-Fails -Expected 'ZIP bytes differ'
    if ($global:mockGhCalls -ne 4 -or $global:mockWebCalls -ne 3) {
        throw 'Artifact mismatch should fail before download; byte mismatch must fail after download.'
    }
    Write-Host 'Verified candidate archive download tests passed.'
}
finally {
    $env:GH_TOKEN = $previousToken
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
