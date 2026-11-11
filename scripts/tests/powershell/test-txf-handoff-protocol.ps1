[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load the actual guarded functions without executing the Windows-only native
# fixture. This protocol check is intentionally runnable on both CI platforms.
$fixtureSource=Join-Path $PSScriptRoot 'test-txf-identity-handoff-phase-a.ps1'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile(
    $fixtureSource,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'TxF fixture did not parse.' }
$definitions=@{}
foreach ($node in $ast.FindAll({param($item)
    $item -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $item.Name -in @('Hash-File','Assert-Preserved')},$true)) {
    $definitions[$node.Name]=$node
}
if ($definitions.Count -ne 2) { throw 'Expected preservation functions are absent or ambiguous.' }
. ([scriptblock]::Create($definitions['Hash-File'].Extent.Text))
. ([scriptblock]::Create($definitions['Assert-Preserved'].Extent.Text))

function Assert-Throws([scriptblock]$Action,[string]$Expected) {
    $caught=$false
    try { & $Action }
    catch {
        $caught=$true
        if ($_.Exception.Message -notlike ('*' + $Expected + '*')) { throw }
    }
    if (-not $caught) { throw "Expected preservation rejection: $Expected" }
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('dark180-txf-protocol-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$snapshot=Join-Path $root 'approved-before.bin'
$approved=Join-Path $root 'approved.bin'
$sentinel=Join-Path $root 'sentinel.bin'
$child=Join-Path $root 'late-child.bin'
try {
    [IO.File]::WriteAllBytes($snapshot,[byte[]](9,18,27,36,45,54))
    [IO.File]::WriteAllBytes($approved,[byte[]](9,18,27,36,45,54))
    [IO.File]::WriteAllBytes($sentinel,[byte[]](72,63,54,45,36,27))
    $fixture=[ordered]@{snapshot=$snapshot;approved=$approved;sentinel=$sentinel;
        approved_sha=(Hash-File $approved);sentinel_sha=(Hash-File $sentinel)}

    # Null typed [string] arguments become empty strings in PowerShell.
    Assert-Preserved $fixture $null $null
    Assert-Preserved $fixture '' ''

    [IO.File]::WriteAllBytes($child,[byte[]](81))
    $knownSha=Hash-File $child
    Assert-Preserved $fixture $child $knownSha
    Assert-Throws { Assert-Preserved $fixture $child $null } 'must be paired'
    Assert-Throws { Assert-Preserved $fixture $null $knownSha } 'must be paired'
    Assert-Throws { Assert-Preserved $fixture $child 'invalid' } 'changed or disappeared'
    [IO.File]::WriteAllBytes($child,[byte[]](82))
    Assert-Throws { Assert-Preserved $fixture $child $knownSha } 'changed or disappeared'
    [IO.File]::Delete($child)
    Assert-Throws { Assert-Preserved $fixture $child $knownSha } 'changed or disappeared'

    [IO.File]::Delete($sentinel)
    Assert-Throws { Assert-Preserved $fixture $null $null } 'sentinel changed or disappeared'
    Write-Host 'TxF handoff preservation protocol tests passed.'
} finally {
    foreach ($path in @($child,$sentinel,$approved,$snapshot)) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    [IO.Directory]::Delete($root,$false)
}
