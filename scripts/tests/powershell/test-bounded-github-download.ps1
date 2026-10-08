[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
. (Join-Path $PSScriptRoot '../support/bounded_http_fixture.ps1')
$helper = Join-Path (Get-ToolingTestPaths).ScriptsRoot 'download-bounded-github-data.ps1'
. $helper -LibraryOnly
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-bounded-http-$([Guid]::NewGuid().ToString('N'))"
$output = Join-Path $root 'asset.bin'
$uri = [uri]'https://api.github.com/repos/PiesP/DarkReNamer/releases/assets/20'
$body = [byte[]]::new(70000)
[Random]::new(1234).NextBytes($body)

function Invoke-FixtureDownload {
    param([Parameter(Mandatory)][Net.Http.HttpClient] $Client)
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output }
    Save-BoundedGitHubData -ApiUri $uri -OutputPath $output `
        -ExpectedSize $body.Length -MaximumBytes $body.Length `
        -Token fixture-token -Client $Client -TimeoutSeconds 5
}

function Assert-DownloadFails {
    param([Parameter(Mandatory)][Net.Http.HttpClient] $Client,
          [Parameter(Mandatory)][string] $Expected)
    try { Invoke-FixtureDownload -Client $Client }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected bounded download failure: $Expected"
}

try {
    [void](New-Item -ItemType Directory -Path $root)
    Assert-BoundedDownloadSize -Size ([long]$body.Length) -Maximum $body.Length -Label 'fixture'
    foreach ($invalid in @('70000', [double]70000, [long]0, ([long]$body.Length + 1))) {
        try {
            Assert-BoundedDownloadSize -Size $invalid -Maximum $body.Length -Label 'fixture'
            throw 'Expected strict JSON integer size failure.'
        }
        catch {
            if ($_.Exception.Message -notlike '*positive JSON integer*') { throw }
        }
    }
    try {
        Save-BoundedGitHubData -ApiUri 'https://api.github.com:444/repos/PiesP/DarkReNamer/releases/assets/20' `
            -OutputPath $output -ExpectedSize $body.Length -MaximumBytes $body.Length `
            -Token fixture-token
        throw 'Expected off-port authenticated API rejection.'
    }
    catch {
        if ($_.Exception.Message -notlike '*exact GitHub artifact or release asset API endpoint*') { throw }
    }

    $fixture = New-BoundedHttpFixture
    try {
        $fixture.Handler.Responses.Enqueue((New-BoundedHttpResponse -Status 302 `
            -Location 'https://objects.example.test/signed-download?secret=private'))
        $fixture.Handler.Responses.Enqueue((New-BoundedHttpResponse -Status 200 `
            -Bytes $body -ContentLength $body.Length))
        Invoke-FixtureDownload -Client $fixture.Client
        if ((Get-Item -LiteralPath $output).Length -ne $body.Length -or
            $fixture.Handler.Authorization.Count -ne 2 -or
            $fixture.Handler.Authorization[0] -cne 'Bearer fixture-token' -or
            $null -ne $fixture.Handler.Authorization[1]) {
            throw 'Successful redirected readback must omit Authorization after the API request.'
        }
    }
    finally { $fixture.Client.Dispose(); $fixture.Handler.Dispose() }

    # A missing length header cannot disable the body cap. The first 64 KiB
    # remain available as a failed receipt; the overflow byte is not written.
    $oversized = $body + [byte]1
    foreach ($declaredLength in @($null, [long]$body.Length)) {
        $fixture = New-BoundedHttpFixture
        try {
            $fixture.Handler.Responses.Enqueue((New-BoundedHttpResponse -Status 200 `
                -Bytes $oversized -ContentLength $declaredLength))
            Assert-DownloadFails -Client $fixture.Client -Expected 'exceeds the approved'
            if (-not (Test-Path -LiteralPath $output) -or
                (Get-Item -LiteralPath $output).Length -ne 65536) {
                throw 'An over-cap stream must retain only its bounded partial bytes.'
            }
        }
        finally { $fixture.Client.Dispose(); $fixture.Handler.Dispose() }
    }

    $fixture = New-BoundedHttpFixture
    try {
        $fixture.Handler.Responses.Enqueue((New-BoundedHttpResponse -Status 200 `
            -Bytes $body -ContentLength ($body.Length - 1)))
        Assert-DownloadFails -Client $fixture.Client -Expected 'Content-Length differs'
        if (Test-Path -LiteralPath $output) { throw 'Wrong Content-Length must fail before writing.' }
    }
    finally { $fixture.Client.Dispose(); $fixture.Handler.Dispose() }

    $fixture = New-BoundedHttpFixture
    try {
        $fixture.Handler.Responses.Enqueue((New-BoundedHttpResponse -Status 403))
        Assert-DownloadFails -Client $fixture.Client -Expected 'HTTP 403'
        if (Test-Path -LiteralPath $output) { throw 'HTTP failure must not create an output file.' }
    }
    finally { $fixture.Client.Dispose(); $fixture.Handler.Dispose() }
    Write-Host 'Bounded GitHub data download tests passed.'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
