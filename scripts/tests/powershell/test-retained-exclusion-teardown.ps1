[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/retained-exclusion-teardown.ps1')

function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ($Actual -cne $Expected) { throw "${Label}: expected $Expected, got $Actual" }
}

function New-MockHandle([string] $Name, $Events, [bool] $Fault = $false) {
    $handle = [pscustomobject]@{ Name=$Name; Events=$Events; Fault=$Fault; Count=0 }
    $handle | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Count++
        $this.Events.Add($this.Name)
        if ($this.Fault) { throw "$($this.Name) fault" }
    }
    return $handle
}

function New-Scenario([string[]] $Faults, [bool] $RollbackFault = $false,
    [bool] $TerminalFault = $false) {
    $events = [Collections.Generic.List[string]]::new()
    $records = [Collections.Generic.List[object]]::new()
    $rollback = {
        param($handle)
        $events.Add('rollback')
        if ($RollbackFault) { return 5 }
        return 0
    }.GetNewClosure()
    $record = {
        param($case, $fields)
        $records.Add([pscustomobject]@{ case=$case; fields=$fields })
    }.GetNewClosure()
    $state = New-CandidateTeardown $rollback $record
    $handles = @{}
    foreach ($kind in @('writer', 'child', 'read', 'directory', 'transaction', 'guard')) {
        $handle = New-MockHandle $kind $events ($kind -in $Faults)
        $handles[$kind] = $handle
        $value = if ($kind -in @('writer', 'read', 'directory', 'transaction')) {
            [pscustomobject]@{ Handle=$handle; Accepted=$true }
        } else { $handle }
        $null = Register-CandidateResource $state $kind $value
    }
    $terminal = {
        $events.Add('terminal')
        if ($TerminalFault) { throw 'terminal fault' }
        $records.Add([pscustomobject]@{
            case='fixture-preserved'
            fields=@{
                gate='BLOCKED'
                settlement=$(if ($state.settlementUnknown) { 'unknown' } else { 'closed-after-rollback' })
                verification_complete=($state.failures.Count -eq 0)
                handle_status=$state.outcomes
            }
        })
    }.GetNewClosure()
    return [pscustomobject]@{ state=$state; events=$events; records=$records; handles=$handles; terminal=$terminal }
}

function Run-Failing($Scenario) {
    try { Complete-CandidateTeardown $Scenario.state $Scenario.terminal }
    catch { return $_.Exception.Message }
    throw 'Expected candidate fixture failure.'
}

function Invoke-MockAfterReleaseChildControl($Scenario, [string] $Mode) {
    $identity = {
        param($child)
        if ($Mode -eq 'identity') { throw 'identity fault' }
        if ($Mode -eq 'mismatch') { return 'different' }
        return 'expected'
    }.GetNewClosure()
    $record = {
        param($sameChild)
        $Scenario.events.Add('child-observation')
        if ($Mode -eq 'observation') { throw 'observation fault' }
        $Scenario.records.Add([pscustomobject]@{ case='child-control'; same_child=$sameChild })
    }.GetNewClosure()
    try {
        Invoke-CandidateAfterReleaseChildControl $Scenario.state $Scenario.handles.child 'expected' $identity $record
        return $false
    } catch {
        if (-not $_.Exception.Data['candidate-teardown-abort']) { throw }
        return $true
    }
}

foreach ($case in @(
    @{ mode='identity'; primary='identity fault' },
    @{ mode='observation'; primary='observation fault' },
    @{ mode='mismatch'; primary='After-release production child identity changed.' }
)) {
    $scenario = New-Scenario @('child')
    Assert-Equal (Invoke-MockAfterReleaseChildControl $scenario $case.mode) $true "$($case.mode) abort"
    $message = Run-Failing $scenario
    foreach ($part in @("primary: $($case.primary)", 'child-dispose:', 'child fault')) {
        if (-not $message.Contains($part)) { throw "Missing $part in $message" }
    }
    Assert-Equal @($scenario.state.failures | Where-Object phase -eq 'primary').Count 1 "$($case.mode) primary once"
    Assert-Equal $scenario.handles.child.Count 1 "$($case.mode) child close once"
    Assert-Equal $scenario.handles.guard.Count 1 "$($case.mode) guard close attempted"
    Assert-Equal $scenario.events[-1] 'terminal' "$($case.mode) terminal attempted"
    Assert-Equal $scenario.records[-1].fields.verification_complete $false "$($case.mode) incomplete verification"
    Assert-Equal $scenario.records[-1].fields.handle_status['child'] 'unknown' "$($case.mode) unknown child close"
}

$scenario = New-Scenario @()
Assert-Equal (Invoke-MockAfterReleaseChildControl $scenario 'identity') $true 'primary-only abort'
$message = Run-Failing $scenario
if (-not $message.Contains('primary: identity fault') -or $message.Contains('child-dispose:')) {
    throw "Primary-only outcome changed: $message"
}
Assert-Equal $scenario.handles.child.Count 1 'primary-only child close once'
Assert-Equal $scenario.records[-1].fields.handle_status['child'] 'closed' 'primary-only child closed'

$scenario = New-Scenario @('child')
Assert-Equal (Invoke-MockAfterReleaseChildControl $scenario 'normal') $true 'cleanup-only abort'
$message = Run-Failing $scenario
if (-not $message.Contains('child-dispose:') -or -not $message.Contains('child fault') -or
    $message.Contains('primary:')) {
    throw "Cleanup-only outcome changed: $message"
}
Assert-Equal $scenario.records[-1].fields.handle_status['child'] 'unknown' 'cleanup-only child unknown'

$scenario = New-Scenario @()
Assert-Equal (Invoke-MockAfterReleaseChildControl $scenario 'normal') $false 'normal child control'
Complete-CandidateTeardown $scenario.state $scenario.terminal
Assert-Equal $scenario.handles.child.Count 1 'normal child close once'
Assert-Equal $scenario.records[-1].fields.verification_complete $true 'normal verification'

$scenario = New-Scenario @('child') $false $true
Assert-Equal (Invoke-MockAfterReleaseChildControl $scenario 'identity') $true 'terminal-fault control abort'
$message = Run-Failing $scenario
foreach ($part in @('primary: identity fault', 'child-dispose:', 'child fault', 'terminal-record: terminal fault')) {
    if (-not $message.Contains($part)) { throw "Missing $part in terminal-fault result: $message" }
}
Assert-Equal $scenario.events[-1] 'terminal' 'terminal-fault attempt'

$scenario = New-Scenario @() $true
Add-CandidateFailure $scenario.state 'primary' 'primary fault'
$message = Run-Failing $scenario
foreach ($part in @('primary: primary fault', 'rollback: Fixture transaction rollback failed: 5')) {
    if (-not $message.Contains($part)) { throw "Missing $part in $message" }
}
Assert-Equal ($scenario.events -join ',') 'writer,child,read,directory,rollback,transaction,guard,terminal' 'primary and rollback ordering'
Assert-Equal $scenario.state.rollback 'failed' 'rollback result'
Assert-Equal $scenario.state.settlementUnknown $true 'unknown settlement'
Assert-Equal $scenario.records[0].case 'rollback' 'rollback observation'
Assert-Equal $scenario.records[1].case 'fixture-preserved' 'terminal observation'

$scenario = New-Scenario @() $true
try { Close-CandidateTransaction $scenario.state } catch {
    if (-not $_.Exception.Data['candidate-teardown-abort']) { throw }
}
$message = Run-Failing $scenario
Assert-Equal (@($scenario.events | Where-Object { $_ -eq 'rollback' }).Count) 1 'rollback attempted once'
Assert-Equal $scenario.handles.transaction.Count 1 'transaction closed once'
Assert-Equal ($scenario.events -join ',') 'read,directory,rollback,transaction,writer,child,guard,terminal' 'body rollback unwind order'

$scenario = New-Scenario @('writer')
$message = Run-Failing $scenario
if (-not $message.Contains('writer-dispose:')) { throw "Cleanup-only failure was lost: $message" }
Assert-Equal ($scenario.events[-1]) 'terminal' 'terminal after cleanup fault'
Assert-Equal $scenario.state.outcomes['writer'] 'unknown' 'failed close status'

$scenario = New-Scenario @('writer', 'read', 'transaction', 'guard') $true $true
$message = Run-Failing $scenario
foreach ($part in @('writer-dispose:', 'read-dispose:', 'rollback:', 'transaction-dispose:', 'guard-dispose:', 'terminal-record:')) {
    if (-not $message.Contains($part)) { throw "Missing distinct failure $part" }
}
Assert-Equal ($scenario.events -join ',') 'writer,child,read,directory,rollback,transaction,guard,terminal' 'all fault paths attempted'
Assert-Equal $scenario.state.settlementUnknown $true 'incomplete settlement'

$scenario = New-Scenario @()
Close-CandidateTransaction $scenario.state
Complete-CandidateTeardown $scenario.state $scenario.terminal
Assert-Equal ($scenario.events -join ',') 'read,directory,rollback,transaction,writer,child,guard,terminal' 'normal exact-once order'
Assert-Equal $scenario.state.rollback 'succeeded' 'normal rollback'
Assert-Equal $scenario.state.outcomes['transaction'] 'closed' 'normal transaction close'
Assert-Equal $scenario.records[-1].fields.gate 'BLOCKED' 'retained gate'
Assert-Equal $scenario.records[-1].fields.settlement 'closed-after-rollback' 'normal settlement'

$scenario = New-Scenario @()
Close-CandidateTransaction $scenario.state
$nextRead = New-MockHandle 'next-read' $scenario.events
$nextTransaction = New-MockHandle 'next-transaction' $scenario.events
$null = Register-CandidateResource $scenario.state 'read' ([pscustomobject]@{ Handle=$nextRead; Accepted=$true })
$null = Register-CandidateResource $scenario.state 'transaction' ([pscustomobject]@{ Handle=$nextTransaction; Accepted=$true })
Close-CandidateTransaction $scenario.state
Complete-CandidateTeardown $scenario.state $scenario.terminal
Assert-Equal (@($scenario.events | Where-Object { $_ -eq 'rollback' }).Count) 2 'one rollback per transaction'
Assert-Equal $nextTransaction.Count 1 'second transaction closed once'

Write-Output 'retained exclusion teardown fault cases passed'
