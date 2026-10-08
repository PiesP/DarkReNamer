[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
. (Join-Path $PSScriptRoot '../support/bounded_http_fixture.ps1')
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
$global:mockSize = [long]$bytes.Length
$global:mockGhCalls = 0

function gh {
    if (($args -join ' ') -cne 'api repos/PiesP/DarkReNamer/actions/artifacts/20') {
        throw 'Unexpected authenticated artifact metadata endpoint.'
    }
    $global:mockGhCalls++
    $global:LASTEXITCODE = 0
    @{ id = [long]20; name = $name; expired = $false;
       size_in_bytes = $global:mockSize;
       digest = "sha256:$global:mockDigest" } | ConvertTo-Json -Compress
}

function Invoke-CandidateFixture {
    param([Parameter(Mandatory)][Net.Http.HttpClient] $Client,
          [string] $ApprovedDigest = $digest)
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
    & $helper -Repository PiesP/DarkReNamer -ArtifactId 20 `
        -ExpectedArtifactSha256 $ApprovedDigest -ExpectedArtifactName $name `
        -ArchivePath $archive -DownloadClient $Client
}

function Assert-CandidateFails {
    param([Parameter(Mandatory)][Net.Http.HttpClient] $Client,
          [Parameter(Mandatory)][string] $Expected,
          [string] $ApprovedDigest = $digest)
    try {
        Invoke-CandidateFixture -Client $Client -ApprovedDigest $ApprovedDigest
    }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected candidate download failure: $Expected"
}

try {
    [void](New-Item -ItemType Directory -Path $root)
    $fixture = New-BoundedHttpFixture
    try {
        $fixture.Handler.Responses.Enqueue((New-BoundedHttpResponse -Status 200 -Bytes $bytes `
            -ContentLength $bytes.Length))
        Invoke-CandidateFixture -Client $fixture.Client
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest) {
            throw 'Complete artifact archive digest changed.'
        }
        Assert-CandidateFails -Client $fixture.Client -Expected 'identity or digest differs' `
            -ApprovedDigest ('b' * 64)
        $global:mockSize = [long]0
        Assert-CandidateFails -Client $fixture.Client -Expected 'positive JSON integer'
        $global:mockSize = [string]$bytes.Length
        Assert-CandidateFails -Client $fixture.Client -Expected 'positive JSON integer'
        $global:mockSize = [long]512 * 1024 * 1024 + 1
        Assert-CandidateFails -Client $fixture.Client -Expected 'positive JSON integer'
        $global:mockSize = [long]$bytes.Length

        # The metadata and approved digest still describe the original ZIP. The
        # response claims the expected length but streams one extra byte.
        $altered = $bytes + [byte]1
        $fixture.Handler.Responses.Enqueue((New-BoundedHttpResponse -Status 200 -Bytes $altered `
            -ContentLength $bytes.Length))
        Assert-CandidateFails -Client $fixture.Client -Expected 'exceeds the approved'
        if (-not (Test-Path -LiteralPath $archive)) {
            throw 'A failed over-cap download must retain its partial receipt.'
        }

        $fixture.Handler.Responses.Enqueue((New-BoundedHttpResponse -Status 503))
        Assert-CandidateFails -Client $fixture.Client -Expected 'HTTP 503'
        if ($global:mockGhCalls -ne 7 -or $fixture.Handler.RequestUris.Count -ne 3) {
            throw 'Metadata must reject bad sizes before any download request.'
        }
    }
    finally {
        $fixture.Client.Dispose()
        $fixture.Handler.Dispose()
    }
    Write-Host 'Verified candidate archive download tests passed.'
}
finally {
    $env:GH_TOKEN = $previousToken
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
