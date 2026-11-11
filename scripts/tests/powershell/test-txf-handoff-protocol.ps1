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
    $item.Name -in @('Hash-File','Assert-Preserved','Assert-PhaseACompletedCases')},$true)) {
    $definitions[$node.Name]=$node
}
if ($definitions.Count -ne 3) { throw 'Expected protocol functions are absent or ambiguous.' }
. ([scriptblock]::Create($definitions['Hash-File'].Extent.Text))
. ([scriptblock]::Create($definitions['Assert-Preserved'].Extent.Text))
. ([scriptblock]::Create($definitions['Assert-PhaseACompletedCases'].Extent.Text))

function Assert-Throws([scriptblock]$Action,[string]$Expected) {
    $caught=$false
    try { & $Action }
    catch {
        $caught=$true
        if ($_.Exception.Message -notlike ('*' + $Expected + '*')) { throw }
    }
    if (-not $caught) { throw "Expected preservation rejection: $Expected" }
}
function New-CompletedCases {
    $cases=@('overlap','mismatch','close-first','commit-first','abort','late-child')
    foreach ($name in $cases) {
        [ordered]@{case=$name;exited=$true;timed_out=$false;
            exit_code=$(if($name -eq 'abort'){71}else{0});controller_error=$null}
    }
}

$completed=@(New-CompletedCases)
Assert-PhaseACompletedCases -Results $completed
$fromJson=$completed | ConvertTo-Json -Depth 4 | ConvertFrom-Json
Assert-PhaseACompletedCases -Results @($fromJson)
$bad=@(New-CompletedCases);$bad[0].controller_error='retained failure'
Assert-Throws { Assert-PhaseACompletedCases -Results $bad } 'wrong identity, exit or closure'
$bad=@(New-CompletedCases);$bad[0].Remove('controller_error')
Assert-Throws { Assert-PhaseACompletedCases -Results $bad } 'lacks required receipt field controller_error'
$bad=@(New-CompletedCases);$bad[0].case='mismatch'
Assert-Throws { Assert-PhaseACompletedCases -Results $bad } 'wrong identity, exit or closure'
$bad=@(New-CompletedCases);$swap=$bad[0];$bad[0]=$bad[1];$bad[1]=$swap
Assert-Throws { Assert-PhaseACompletedCases -Results $bad } 'wrong identity, exit or closure'
$bad=@(New-CompletedCases);$bad[2].Remove('exit_code')
Assert-Throws { Assert-PhaseACompletedCases -Results $bad } 'lacks required receipt field exit_code'
$bad=@(New-CompletedCases);$bad[4].exit_code=0
Assert-Throws { Assert-PhaseACompletedCases -Results $bad } 'wrong identity, exit or closure'
$bad=@(New-CompletedCases);$bad[2].timed_out=$true
Assert-Throws { Assert-PhaseACompletedCases -Results $bad } 'wrong identity, exit or closure'
$bad=@(New-CompletedCases);$bad[3].exited=$false
Assert-Throws { Assert-PhaseACompletedCases -Results $bad } 'wrong identity, exit or closure'
$bad=@(New-CompletedCases)
Assert-Throws { Assert-PhaseACompletedCases -Results @($bad[0..4]) } 'case count is incomplete'

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
