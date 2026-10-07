[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../support/paths.ps1')
$paths = Get-ToolingTestPaths
$helper = Join-Path $paths.ScriptsRoot 'get-release-product-notes.ps1'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-product-notes-$([Guid]::NewGuid())"
$cargoPath = Join-Path $root 'Cargo.toml'
$policyPath = Join-Path $root 'DISTRIBUTION.md'
function Assert-Rejected {
    param([string] $Policy, [string] $Expected, [string] $Tag = 'v0.1.7')
    [IO.File]::WriteAllText($policyPath, $Policy)
    try { $null = & $helper -SourceRoot $root -ReleaseTag $Tag }
    catch {
        if (-not $_.Exception.Message.Contains($Expected)) { throw }
        return
    }
    throw "Product notes unexpectedly accepted: $Expected"
}
try {
    [void](New-Item -ItemType Directory -Path $root)
    [IO.File]::WriteAllText($cargoPath, "[workspace.package]`nversion = `"0.1.7`"`n")
    $policy = "# Policy`n`n## Prepared 0.1.7 release notes`n`nReset proposed names; retain preferences.`n`n### Details`n`nCancel remains the default.`n`n## Historical 0.1.6 observations`n`nOld measurements.`n"
    [IO.File]::WriteAllText($policyPath, $policy)
    foreach ($tag in @('', 'v0.1.7')) {
        $notes = & $helper -SourceRoot $root -ReleaseTag $tag
        if ($notes -cne "Reset proposed names; retain preferences.`n`n### Details`n`nCancel remains the default.") {
            throw 'Product notes must preserve the selected body and exclude historical observations.'
        }
    }
    [IO.File]::WriteAllText($policyPath, $policy.Replace("`n", "`r`n"))
    $notes = & $helper -SourceRoot $root -ReleaseTag 'v0.1.7'
    if (-not $notes.Contains('Cancel remains the default.') -or $notes.Contains('Old measurements.')) {
        throw 'CRLF product notes selected the wrong body.'
    }
    Assert-Rejected -Policy $policy -Expected 'selected release tag' -Tag 'v0.1.6'
    Assert-Rejected -Policy $policy.Replace('0.1.7 release notes', '0.1.6 release notes') -Expected 'exact-version'
    Assert-Rejected -Policy ($policy + "`n## Prepared 0.1.7 release notes`nDuplicate.`n") -Expected 'exact-version'
    Assert-Rejected -Policy "## Prepared 0.1.7 release notes`n `n## Historical`nOld.`n" -Expected 'must not be empty'
    [IO.File]::WriteAllText($cargoPath, "[workspace.package]`nversion = `"0.1.7`"`nversion = `"0.1.8`"`n")
    Assert-Rejected -Policy $policy -Expected 'one Cargo workspace version'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
