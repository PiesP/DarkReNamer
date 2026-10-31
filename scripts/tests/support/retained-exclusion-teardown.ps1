# Teardown for the disposable TxF candidate fixture. Each registration owns one
# acquired handle until its single close attempt, including a failed attempt.
function New-CandidateTeardown([scriptblock] $Rollback, [scriptblock] $Record) {
    return [pscustomobject]@{
        resources = @{}
        outcomes = [ordered]@{ writer='not-acquired'; child='not-acquired'; read='not-acquired'; directory='not-acquired'; transaction='not-acquired'; guard='not-acquired' }
        rollback = 'not-attempted'
        settlementUnknown = $false
        failures = [Collections.Generic.List[object]]::new()
        rollbackAction = $Rollback
        recordAction = $Record
    }
}

function Add-CandidateFailure($State, [string] $Phase, $ErrorValue) {
    # There are only six owned resource slots, one rollback, and one terminal
    # record. Bound both the count and each message if a mock or host misbehaves.
    if ($State.failures.Count -lt 12) {
        $message = if ($ErrorValue -is [Exception]) { $ErrorValue.Message } else { [string]$ErrorValue }
        if ($message.Length -gt 512) { $message = $message.Substring(0, 512) }
        $State.failures.Add([pscustomobject]@{ phase=$Phase; message=$message })
    }
}

function Register-CandidateResource($State, [string] $Kind, $Value) {
    if ($State.resources.ContainsKey($Kind)) { throw "Candidate fixture $Kind is still owned." }
    if ($Kind -eq 'transaction') { $State.rollback = 'not-attempted' }
    $State.resources[$Kind] = $Value
    $State.outcomes[$Kind] = 'owned'
    return $Value
}

function Close-CandidateResource($State, [string] $Kind, [switch] $DeferError) {
    if (-not $State.resources.ContainsKey($Kind)) { return }
    $value = $State.resources[$Kind]
    $State.resources.Remove($Kind)
    $State.outcomes[$Kind] = 'attempted'
    try {
        if ($Kind -in @('writer', 'read', 'directory', 'transaction')) {
            if ($null -ne $value.Handle) { $value.Handle.Dispose() }
        } else { $value.Dispose() }
        $State.outcomes[$Kind] = 'closed'
    } catch {
        $State.outcomes[$Kind] = 'unknown'
        if ($Kind -in @('read', 'directory', 'transaction')) { $State.settlementUnknown = $true }
        Add-CandidateFailure $State "$Kind-dispose" $_.Exception
        if (-not $DeferError) {
            $abort = [InvalidOperationException]::new('Candidate fixture handle teardown failed.')
            $abort.Data['candidate-teardown-abort'] = $true
            throw $abort
        }
    }
}

function Close-CandidateTransaction($State) {
    $initialFailures = $State.failures.Count
    Close-CandidateResource $State 'read' -DeferError
    Close-CandidateResource $State 'directory' -DeferError
    if ($State.resources.ContainsKey('transaction')) {
        $transaction = $State.resources['transaction']
        if ($transaction.Accepted -and $State.rollback -eq 'not-attempted') {
            $State.rollback = 'attempted'
            $errorCode = $null
            try {
                $errorCode = & $State.rollbackAction $transaction.Handle
                if ($errorCode -ne 0) { throw "Fixture transaction rollback failed: $errorCode" }
                $State.rollback = 'succeeded'
            } catch {
                $State.rollback = 'failed'
                $State.settlementUnknown = $true
                Add-CandidateFailure $State 'rollback' $_.Exception
            }
            try {
                & $State.recordAction 'rollback' @{
                    accepted=($State.rollback -eq 'succeeded')
                    native_error=$(if ($null -ne $errorCode) { $errorCode } else { 'unknown' })
                    read_handle_closed_first=($State.outcomes['read'] -eq 'closed')
                }
            } catch { Add-CandidateFailure $State 'rollback-record' $_.Exception }
        }
        Close-CandidateResource $State 'transaction' -DeferError
    }
    if ($State.failures.Count -gt $initialFailures) {
        $abort = [InvalidOperationException]::new('Candidate fixture transaction teardown failed.')
        $abort.Data['candidate-teardown-abort'] = $true
        throw $abort
    }
}

function Complete-CandidateTeardown($State, [scriptblock] $TerminalRecord) {
    # Writer and child precede transacted reads; the transaction precedes the
    # production guard. A failure in any step must not skip a later step.
    Close-CandidateResource $State 'writer' -DeferError
    Close-CandidateResource $State 'child' -DeferError
    try { Close-CandidateTransaction $State } catch {
        if (-not $_.Exception.Data['candidate-teardown-abort']) {
            Add-CandidateFailure $State 'transaction-teardown' $_.Exception
        }
    }
    Close-CandidateResource $State 'guard' -DeferError
    try { & $TerminalRecord } catch { Add-CandidateFailure $State 'terminal-record' $_.Exception }
    if ($State.failures.Count) {
        $parts = @($State.failures | ForEach-Object { "$($_.phase): $($_.message)" })
        throw ('Candidate fixture failed: ' + ($parts -join ' | '))
    }
}
