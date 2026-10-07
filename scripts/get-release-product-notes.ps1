[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceRoot,
    [string] $ReleaseTag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cargo = Get-Content -LiteralPath (Join-Path $SourceRoot 'Cargo.toml') -Raw
$versions = [regex]::Matches($cargo, '(?m)^version = "(\d+\.\d+\.\d+)"\r?$')
if ($versions.Count -ne 1) {
    throw 'Product release notes require one Cargo workspace version.'
}
$version = $versions[0].Groups[1].Value
if ($ReleaseTag -and $ReleaseTag -cne "v$version") {
    throw 'Product release notes must match the selected release tag.'
}
$policy = Get-Content -LiteralPath (Join-Path $SourceRoot 'DISTRIBUTION.md') -Raw
$heading = '(?m)^## Prepared ' + [regex]::Escape($version) + ' release notes\r?$'
$matches = [regex]::Matches($policy, $heading)
if ($matches.Count -ne 1) {
    throw 'Product release notes require one exact-version prepared section.'
}
$remaining = $policy.Substring($matches[0].Index + $matches[0].Length)
$nextHeading = [regex]::Match($remaining, '(?m)^## ')
$notes = if ($nextHeading.Success) {
    $remaining.Substring(0, $nextHeading.Index).Trim()
}
else { $remaining.Trim() }
if ([string]::IsNullOrWhiteSpace($notes)) {
    throw 'Product release notes must not be empty.'
}
$notes
