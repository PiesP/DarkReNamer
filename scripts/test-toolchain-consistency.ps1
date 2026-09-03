Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolchainText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'rust-toolchain.toml') -Raw
$cargoText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Cargo.toml') -Raw

$channelMatch = [regex]::Match($toolchainText, '(?m)^channel\s*=\s*"([^"]+)"\s*$')
$rustVersionMatch = [regex]::Match($cargoText, '(?m)^rust-version\s*=\s*"([^"]+)"\s*$')
if (-not $channelMatch.Success -or -not $rustVersionMatch.Success) {
    throw 'The pinned toolchain channel and workspace rust-version must both be explicit.'
}

$channel = $channelMatch.Groups[1].Value
if ($rustVersionMatch.Groups[1].Value -cne $channel) {
    throw "Cargo rust-version '$($rustVersionMatch.Groups[1].Value)' differs from toolchain channel '$channel'."
}

$workflows = Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github/workflows') -File -Include '*.yaml', '*.yml'
$installCount = 0
foreach ($workflow in $workflows) {
    $text = Get-Content -LiteralPath $workflow.FullName -Raw
    foreach ($match in [regex]::Matches($text, 'rustup\s+toolchain\s+install\s+([^\s\\]+)')) {
        $installCount++
        $installed = $match.Groups[1].Value
        if ($installed -cne $channel) {
            throw "$($workflow.Name) installs Rust '$installed' instead of pinned channel '$channel'."
        }
    }
}
if ($installCount -eq 0) {
    throw 'No explicit workflow toolchain installation was found.'
}

Write-Host "Toolchain consistency tests passed for Rust $channel ($installCount workflow installs)."
