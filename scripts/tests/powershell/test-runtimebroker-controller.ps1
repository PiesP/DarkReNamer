[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/windows-vm-module-loader.ps1')
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind controller)) { . $definition }
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind ui)) { . $definition }

function Assert-Fails {
    param([scriptblock] $Action, [string] $Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure: $Message"
}
$runId = '0123456789abcdef0123456789abcdef'
$root = 'C:\ProgramData\DarkReNamerRuntimeBrokerDiag-' + $runId
$valid = @{ Root=$root; RunId=$runId; PreparationOnly=$false; TransportKind='ssh'; TaskKind='ui'
    Mode='current-dpi'; VmId=[guid]'18338a47-f647-45c4-98b8-6107331e2602'
    RunnerSid='S-1-5-21-2512583658-2963808555-1674717125-1001'; BudgetSeconds=700 }
if (-not (Test-DrRuntimeBrokerDiagnosticArguments @valid)) { throw 'Bound diagnostic was rejected.' }
if (Test-DrRuntimeBrokerDiagnosticArguments) { throw 'Normal controller enabled diagnostics.' }
foreach ($mutation in @(
    @{ Root=$root + '-other' }, @{ RunId='other' }, @{ TransportKind='powershell_direct' },
    @{ TaskKind='core' }, @{ Mode='text-scale' }, @{ VmId=[guid]::Empty },
    @{ RunnerSid='S-1-5-18' }, @{ BudgetSeconds=0 }, @{ BudgetSeconds=901 }
)) {
    $bad = @{} + $valid
    foreach ($key in $mutation.Keys) { $bad[$key]=$mutation[$key] }
    Assert-Fails { Test-DrRuntimeBrokerDiagnosticArguments @bad } 'bound SSH'
}
Assert-Fails { Test-DrRuntimeBrokerDiagnosticArguments -PreparationOnly $true } 'bound SSH'
$clock = [Diagnostics.Stopwatch]::StartNew()
$remaining = Get-DrRuntimeBrokerControllerRemainingSeconds -Clock $clock -BudgetSeconds 600 -ReserveSeconds 420
if ($remaining -lt 178 -or $remaining -gt 180) { throw 'Controller did not reserve unchanged cleanup time.' }
Assert-Fails { Get-DrRuntimeBrokerControllerRemainingSeconds -Clock $clock -BudgetSeconds 100 -ReserveSeconds 420 } 'deadline'

# Use the real ordinary-file writer with only Windows path translation replaced.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dr-runtimebroker-phase-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'phases'))
function Join-Path {
    param([string] $Path, [string] $ChildPath)
    if ($Path -ceq $root) { $Path=$testRoot }
    Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
}
try {
    Write-DrRuntimeBrokerPhaseFile -Root $root -RunId $runId -Phase 'acceptance-baseline' -State 'end'
    $rows = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'phases'))
    if ($rows.Count -ne 1) { throw 'Phase was not persisted.' }
    $record = [IO.File]::ReadAllText($rows[0].FullName) | ConvertFrom-Json
    if ($record.run_id -cne $runId -or $record.source -cne 'controller' -or $record.state -cne 'end') {
        throw 'Persisted phase lost its binding.'
    }
    $guestTime = '2026-09-30T00:00:00.1234567Z'
    Write-DrRuntimeBrokerPhaseFile -Root $root -RunId $runId -Phase 'high-contrast-restoration' `
        -State 'end' -Source 'ui-observer' -RecordedAtUtc $guestTime -Details @{ restoration_verified=$true }
    $imported = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'phases') | ForEach-Object {
        [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json
    } | Where-Object source -CEQ 'ui-observer')
    $importedTime = if ($imported[0].recorded_at_utc -is [DateTime]) {
        $imported[0].recorded_at_utc.ToUniversalTime().ToString('o')
    } else { [string]$imported[0].recorded_at_utc }
    if ($imported.Count -ne 1 -or $importedTime -cne $guestTime) {
        throw 'UI import replaced the guest observation timestamp.'
    }
    Assert-Fails { Write-DrRuntimeBrokerPhaseFile -Root $root -RunId $runId -Phase '../invalid' } 'Invalid'
    Assert-Fails { Write-DrRuntimeBrokerPhaseFile -Root $root -RunId $runId -Phase 'bounded' -Details @{ text=('x'*4096) } } 'byte limit'
    for ($i=2; $i -lt 192; $i++) {
        [IO.File]::WriteAllText((Join-Path (Join-Path $testRoot 'phases') ([guid]::NewGuid().ToString('N')+'.json')), '{}')
    }
    Assert-Fails { Write-DrRuntimeBrokerPhaseFile -Root $root -RunId $runId -Phase 'bounded' } 'count limit'
} finally {
    Remove-Item Function:\Join-Path
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

$RuntimeBrokerDiagnosticRunId = ''
$runtimeBrokerUiPhases = [Collections.Generic.List[object]]::new()
Add-DrRuntimeBrokerUiPhase -Phase 'ignored'
if ($runtimeBrokerUiPhases.Count -ne 0) { throw 'Normal UI recorded diagnostic phases.' }
$RuntimeBrokerDiagnosticRunId = $runId
Add-DrRuntimeBrokerUiPhase -Phase 'high-contrast-restoration' -State 'end' -Details @{ restoration_verified=$true }
if ($runtimeBrokerUiPhases.Count -ne 1 -or $runtimeBrokerUiPhases[0].source -cne 'ui-observer') {
    throw 'Actual UI phase recorder lost its source.'
}
Assert-Fails { Add-DrRuntimeBrokerUiPhase -Phase 'bounded' -Details @{ text=('x'*4096) } } 'byte limit'
for ($i=1; $i -lt 64; $i++) { Add-DrRuntimeBrokerUiPhase -Phase 'bounded' }
Assert-Fails { Add-DrRuntimeBrokerUiPhase -Phase 'bounded' } 'count limit'
Write-Host 'RuntimeBroker controller diagnostic contract tests passed.'
