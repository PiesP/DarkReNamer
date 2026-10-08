. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
$toolingScriptsRoot = $toolingTestPaths.ScriptsRoot

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $toolingScriptsRoot
$toolchainText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'rust-toolchain.toml') -Raw
$cargoText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Cargo.toml') -Raw

$channelMatches = [regex]::Matches($toolchainText, '(?m)^channel\s*=\s*"([^"]+)"\s*$')
$rustVersionMatch = [regex]::Match($cargoText, '(?m)^rust-version\s*=\s*"([^"]+)"\s*$')
if ($channelMatches.Count -ne 1 -or -not $rustVersionMatch.Success) {
    throw 'The pinned toolchain channel must be unique and workspace rust-version must be explicit.'
}

$channel = $channelMatches[0].Groups[1].Value
if ($channel -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Toolchain channel '$channel' must be an exact stable Rust version."
}
if ($rustVersionMatch.Groups[1].Value -cne $channel) {
    throw "Cargo rust-version '$($rustVersionMatch.Groups[1].Value)' differs from toolchain channel '$channel'."
}

$activeToolchain = (& rustup show active-toolchain 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or
    $activeToolchain -cnotmatch "^$([regex]::Escape($channel))-[^\s]+\s+\(overridden by .*[\\/]rust-toolchain\.toml'\)$") {
    throw "rustup did not select the checked-out pinned toolchain: $activeToolchain"
}

$workflows = Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github/workflows') -File -Include '*.yaml', '*.yml'
$expectedInstallCounts = @{
    'ci.yaml' = 4
    'release.yaml' = 0
    'security.yaml' = 1
    'benchmark-planning.yaml' = 1
    'binary-size-matrix.yaml' = 1
    'profile-benchmark-matrix.yaml' = 1
    'profile-planning-matrix.yaml' = 1
}
$installCount = 0
foreach ($workflow in $workflows) {
    $text = Get-Content -LiteralPath $workflow.FullName -Raw
    $installMatches = [regex]::Matches($text, '(?m)\brustup\s+toolchain\s+install\b[^\r\n]*')
    $expected = if ($expectedInstallCounts.ContainsKey($workflow.Name)) {
        $expectedInstallCounts[$workflow.Name]
    } else { 0 }
    if ($installMatches.Count -ne $expected) {
        throw "$($workflow.Name) has $($installMatches.Count) Rust installs; expected $expected."
    }
    foreach ($match in $installMatches) {
        $installCount++
        if ($match.Value -cnotmatch '^rustup toolchain install\s*$') {
            throw "$($workflow.Name) must install the toolchain selected by rust-toolchain.toml."
        }
    }
}
if ($installCount -ne 9) {
    throw "Expected nine bootstrap workflow toolchain installations, found $installCount."
}

$candidateText = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/release.yaml') -Raw
if ([regex]::Matches($candidateText, '(?m)^\s*\./scripts/install-verified-release-tools\.ps1\s*`$').Count -ne 1 -or
    $candidateText -match '\bcargo\s+install\b') {
    throw 'Candidate builds must use the reviewed byte-verified release installer once.'
}

Write-Host "Toolchain consistency tests passed for Rust $channel ($installCount workflow installs)."
