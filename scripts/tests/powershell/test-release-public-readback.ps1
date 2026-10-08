[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
$scriptPath = Join-Path (Get-ToolingTestPaths).ScriptsRoot 'verify-release-public-readback.ps1'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-public-readback-$([Guid]::NewGuid().ToString('N'))"
$candidate = Join-Path $root 'candidate'
$statement = Join-Path $root 'validation-statement.json'
$names = @(
    'DarkReNamer.exe', 'DarkReNamer.cdx.json', 'DarkReNamer-debug-symbols.zip',
    'SHA256SUMS.txt', 'LICENSE', 'THIRD_PARTY_LICENSES.html',
    'THIRD_PARTY_NOTICES.md', 'DISTRIBUTION.md', 'release-handoff.json',
    'release-metrics.json', 'validation-statement.json'
)
$previousToken = $env:GH_TOKEN
$env:GH_TOKEN = 'fixture-token'
$global:mockAssets = @()

function gh {
    if (($args -join ' ') -cne 'api repos/PiesP/DarkReNamer/releases/tags/v0.2.0') {
        throw 'Unexpected public release metadata endpoint.'
    }
    $global:LASTEXITCODE = 0
    @{ tag_name = 'v0.2.0'; draft = $false; assets = $global:mockAssets } |
        ConvertTo-Json -Compress -Depth 5
}

function python {
    $global:LASTEXITCODE = 0
    if ($args -contains 'list') {
        foreach ($name in $names | Where-Object { $_ -cne 'validation-statement.json' }) {
            Join-Path $candidate $name
        }
        return
    }
    throw 'Public byte verification must not run after rejected metadata.'
}

function Assert-ReadbackFails {
    param([Parameter(Mandatory)][string] $Expected)
    $scratch = Join-Path $root ([guid]::NewGuid().ToString('N'))
    try {
        & $scriptPath -Repository PiesP/DarkReNamer -ReleaseTag v0.2.0 `
            -CandidateRoot $candidate -StatementPath $statement -ScratchRoot $scratch
    }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        if (@(Get-ChildItem -LiteralPath (Join-Path $scratch 'assets')).Count -ne 0) {
            throw 'Public metadata rejection must occur before downloading any asset.'
        }
        return
    }
    throw "Expected public readback rejection: $Expected"
}

try {
    [void](New-Item -ItemType Directory -Path $candidate -Force)
    foreach ($name in $names) {
        $path = if ($name -ceq 'validation-statement.json') { $statement } else { Join-Path $candidate $name }
        [IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3))
    }
    $global:mockAssets = @(
        for ($index = 0; $index -lt $names.Count; $index++) {
            @{ id = [long]($index + 1); name = $names[$index]; state = 'uploaded'; size = [long]3 }
        }
    )
    $global:mockAssets[0].size = [long]4
    Assert-ReadbackFails -Expected 'metadata size differs from verified input'
    $global:mockAssets[0].size = '3'
    Assert-ReadbackFails -Expected 'positive JSON integer'
    $global:mockAssets[0].size = [long]3
    $global:mockAssets[-1].size = [long]512 * 1024 * 1024 + 1
    Assert-ReadbackFails -Expected 'positive JSON integer'
    Write-Host 'Public release readback metadata tests passed.'
}
finally {
    $env:GH_TOKEN = $previousToken
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
