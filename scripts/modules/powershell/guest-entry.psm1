param([Parameter(Mandatory)][hashtable] $Libraries)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedRoles = @(
    'powershell-guest-contracts'
    'powershell-guest-process'
    'powershell-guest-native'
    'powershell-guest-platform'
    'powershell-guest-uia'
    'powershell-guest-state'
    'powershell-guest-scenario'
    'powershell-guest-runtime'
)
if ($Libraries.Count -ne $expectedRoles.Count) { throw 'The verified definition library set is incomplete.' }
foreach ($role in $expectedRoles) {
    if (-not $Libraries.ContainsKey($role) -or $Libraries[$role] -isnot [scriptblock]) {
        throw "Missing verified definition library: $role"
    }
    . $Libraries[$role]
}
$script:AcceptanceProcessJobCleanup = [Collections.Generic.List[object]]::new()

function Invoke-DrWindowsVmGuest {
    [CmdletBinding()]
    param(
    [Parameter(Mandatory)]
    [string] $BundleRoot,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $ExpectedSessionId,

    [ValidateRange(1, 3600)]
    [int] $TestTimeoutSeconds = 300,

    [string] $OutputRoot,

    [string] $RuntimeRoot,

    [switch] $ValidateOnly
,
    [Parameter(Mandatory)][string] $EntryPointPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


$elevatedObserver = [Environment]::GetEnvironmentVariable(
    'DARKRENAMER_VM_ELEVATED_OBSERVER'
) -ceq '1'
$verified = $null
if ($ValidateOnly) {
    $verified = Resolve-VerifiedBundle -Root $BundleRoot -InvokedScriptPath $EntryPointPath
    $validatedSource = if ($verified.manifest.schema_version -eq 2) {
        $verified.manifest.product.source_sha
    } else {
        $verified.manifest.source_sha
    }
    Write-Host "Validated Windows VM bundle for source $validatedSource."
    return
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    if ($elevatedObserver) {
        throw 'The elevated VM observer requires a protected output directory.'
    }
    $verified = Resolve-VerifiedBundle -Root $BundleRoot -InvokedScriptPath $EntryPointPath
    $OutputRoot = $verified.root
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$outputItem = Get-Item -LiteralPath $OutputRoot -Force -ErrorAction Stop
if (-not $outputItem.PSIsContainer -or
    ($outputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The VM result output root must be an ordinary directory.'
}
if ($elevatedObserver) {
    $trustedResultPath = [Environment]::GetEnvironmentVariable(
        'DARKRENAMER_VM_TRUSTED_RESULT_PATH'
    )
    if (-not $trustedResultPath -or
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($trustedResultPath)) -cne $OutputRoot) {
        throw 'The elevated VM output root must be the directory containing its controller-created result.'
    }
}
$bootstrapDiagnosticPath = Join-Path $OutputRoot 'observer-bootstrap-failure.txt'
$writeBootstrapDiagnostic = {
    param([string] $Stage, [string] $Message = '')
    if (-not $elevatedObserver) { return }
    try {
        if ($Message.Length -gt 4096) { $Message = $Message.Substring(0, 4096) }
        $content = "stage=$Stage`n"
        if ($Message) { $content += "detail=$Message`n" }
        [IO.File]::WriteAllText(
            $bootstrapDiagnosticPath,
            $content,
            [Text.UTF8Encoding]::new($false)
        )
    }
    catch {}
}.GetNewClosure()
if ($null -eq $verified) {
    & $writeBootstrapDiagnostic 'bundle-verification'
    try {
        $verified = Resolve-VerifiedBundle -Root $BundleRoot -InvokedScriptPath $EntryPointPath
    }
    catch {
        $message = '{0}: {1}' -f $_.Exception.GetType().FullName, $_.Exception.Message
        & $writeBootstrapDiagnostic 'bundle-verification-failed' $message
        throw
    }
}
$fixtureParentRoot = $null
& $writeBootstrapDiagnostic 'fixture-root-validation'
try {
    if ($elevatedObserver) {
        $fixtureParentRoot = [IO.Path]::GetDirectoryName($OutputRoot)
        $verifiedRootPath = [IO.Path]::GetFullPath($verified.root)
        $taskRootPath = [IO.Path]::GetFullPath($fixtureParentRoot)
        $verifiedRootParent = [IO.Path]::GetDirectoryName($verifiedRootPath)
        $bundleRootLayout = [string]::Equals(
            $verifiedRootParent,
            $taskRootPath,
            [StringComparison]::OrdinalIgnoreCase
        ) -and [IO.Path]::GetFileName($verifiedRootPath) -ceq 'bundle'
        if (-not [string]::Equals(
            $verifiedRootPath,
            $taskRootPath,
            [StringComparison]::OrdinalIgnoreCase
        ) -and -not $bundleRootLayout) {
            throw 'The production fixture parent must be the protected task directory beside OutputRoot.'
        }
        $fixtureParentItem = Get-Item -LiteralPath $fixtureParentRoot -Force -ErrorAction Stop
        if (-not $fixtureParentItem.PSIsContainer -or
            ($fixtureParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The production fixture parent must be an ordinary protected directory.'
        }
    }
}
catch {
    $message = '{0}: {1}' -f $_.Exception.GetType().FullName, $_.Exception.Message
    & $writeBootstrapDiagnostic 'fixture-root-validation-failed' $message
    throw
}
if (-not $RuntimeRoot -and $elevatedObserver) {
    $message = 'The elevated VM observer requires a separate candidate runtime directory.'
    & $writeBootstrapDiagnostic 'runtime-root-validation-failed' $message
    throw $message
}
& $writeBootstrapDiagnostic 'runtime-root-validation'
if ($RuntimeRoot) {
    try {
        if (-not [IO.Path]::IsPathRooted($RuntimeRoot)) {
            throw 'The VM candidate runtime root must be absolute.'
        }
        $runtimeItem = Get-Item -LiteralPath $RuntimeRoot -Force -ErrorAction Stop
        if (-not $runtimeItem.PSIsContainer -or
            ($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The VM candidate runtime root must be an existing ordinary directory.'
        }
        $RuntimeRoot = $runtimeItem.FullName
        $runtimeCursor = $runtimeItem
        while ($null -ne $runtimeCursor) {
            if (($runtimeCursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The VM candidate runtime path traverses a reparse point.'
            }
            $runtimeCursor = $runtimeCursor.Parent
        }
    }
    catch {
        $message = '{0}: {1}' -f $_.Exception.GetType().FullName, $_.Exception.Message
        & $writeBootstrapDiagnostic 'runtime-root-validation-failed' $message
        throw
    }
}
$candidateLane = $verified.manifest.schema_version -eq 2
$result = if ($candidateLane) {
    [ordered]@{
        schema_version = 2
        lane = $verified.manifest.lane
        target = $verified.manifest.target
        product = $verified.manifest.product
        harness = $verified.manifest.harness
        status = 'failed'
        tests = @()
        gui = $null
        failure_reason = $null
    }
} else {
    [ordered]@{
        schema_version = 1
        source_sha = $verified.manifest.source_sha
        source_state = $verified.manifest.source_state
        target = $verified.manifest.target
        status = 'failed'
        tests = @()
        gui = $null
        failure_reason = $null
    }
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    $result.failure_reason = 'unsupported_platform'
    Initialize-TrustedResultWriter -Root $verified.root
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution requires Windows.'
}
$elevatedObserver = [Environment]::GetEnvironmentVariable(
    'DARKRENAMER_VM_ELEVATED_OBSERVER'
) -ceq '1'
& $writeBootstrapDiagnostic 'execution-context-check'
try {
    Assert-VmObserverExecutionContext -ExpectedSessionId $ExpectedSessionId
}
catch {
    $message = '{0}: {1}' -f $_.Exception.GetType().FullName, $_.Exception.Message
    & $writeBootstrapDiagnostic 'execution-context-check-failed' $message
    if ($elevatedObserver) { $result.failure_reason = 'invalid_elevated_observer' }
    else { $result.failure_reason = 'elevated_runner' }
    throw
}
& $writeBootstrapDiagnostic 'execution-context-check-passed'
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($currentSession -ne $ExpectedSessionId) {
    $result.failure_reason = 'unexpected_session'
    & $writeBootstrapDiagnostic 'desktop-session-check-failed' (
        'actual={0}; expected={1}' -f $currentSession, $ExpectedSessionId
    )
    throw 'Windows VM guest execution is in an unexpected session.'
}
& $writeBootstrapDiagnostic 'desktop-session-check-passed'

$desktopLock = $null
$previousExecutionState = $null
$effectiveRuntimeRoot = $null
try {
    & $writeBootstrapDiagnostic 'runner-protection-started'
    Protect-CurrentRunnerProcess
    & $writeBootstrapDiagnostic 'runner-protection-passed'
    & $writeBootstrapDiagnostic 'trusted-result-writer-initialization-started'
    Initialize-TrustedResultWriter -Root $verified.root
    if (Test-Path -LiteralPath $bootstrapDiagnosticPath) {
        Remove-Item -LiteralPath $bootstrapDiagnosticPath -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $bootstrapDiagnosticPath) {
        throw 'The VM observer bootstrap diagnostic remained after result-writer initialization.'
    }
    $desktopLock = Enter-DesktopTestLock -SessionId $currentSession
    if ($null -eq $desktopLock) {
        $result.failure_reason = 'desktop_busy'
        throw 'Another Windows VM test runner is using this interactive desktop.'
    }
    $previousExecutionState = Enter-TestExecutionState
    $effectiveRuntimeRoot = if ($RuntimeRoot) {
        $RuntimeRoot
    } else {
        New-PrivateDirectory -Parent $verified.root -Leaf 'runtime'
    }
    $testResults = [Collections.Generic.List[object]]::new()
    $remainingSuiteOutputBytes = [long]$script:VmTestOutputSuiteLimitBytes
    for ($index = 0; $index -lt $verified.tests.Count; $index++) {
        $testOutputBudgetBytes = [Math]::Min(
            [long]$script:VmTestOutputAggregateLimitBytes,
            $remainingSuiteOutputBytes
        )
        $testResult = Invoke-RustTestBinary `
            -Test $verified.tests[$index] `
            -Root $verified.root `
            -OutputRoot $OutputRoot `
            -RuntimeRoot $effectiveRuntimeRoot `
            -Index ($index + 1) `
            -TimeoutSeconds $TestTimeoutSeconds `
            -OutputBudgetBytes $testOutputBudgetBytes
        $testOutputBytes = [long]0
        foreach ($channel in @('stdout', 'stderr')) {
            if ($testResult.$channel) {
                $testOutputBytes += [long]$testResult.$channel.bytes
            }
        }
        if ($testOutputBytes -gt $remainingSuiteOutputBytes) {
            throw 'Guest test output exceeded the remaining suite budget.'
        }
        $remainingSuiteOutputBytes -= $testOutputBytes
        $testResults.Add($testResult)
        $result.tests = $testResults.ToArray()
    }
    $applicationArtifact = if ($candidateLane) {
        $verified.manifest.product.application
    } else {
        $verified.manifest.application
    }
    $result.gui = Invoke-GuiSmoke `
        -Application $applicationArtifact `
        -Root $verified.root `
        -OutputRoot $OutputRoot `
        -RuntimeRoot $effectiveRuntimeRoot `
        -FixtureParentRoot $fixtureParentRoot `
        -ExpectedSession $ExpectedSessionId `
        -TimeoutSeconds $TestTimeoutSeconds `
        -RawEvidence:$candidateLane

    $testFailures = @($result.tests | Where-Object { $_.status -cne 'passed' })
    if ($testFailures.Count -eq 0 -and $result.gui.status -ceq 'passed' -and
        ($candidateLane -or $result.tests.Count -gt 0)) {
        $result.status = 'passed'
    }
}
catch {
    if ($null -eq $script:VmTrustedResultWriter) {
        $errorRecord = $_
        $messageParts = [Collections.Generic.List[string]]::new()
        $exception = $errorRecord.Exception
        for ($depth = 0; $null -ne $exception -and $depth -lt 4; $depth++) {
            $nativeError = if ($exception -is [ComponentModel.Win32Exception]) {
                '; native_error=' + $exception.NativeErrorCode
            }
            else { '' }
            $exceptionMessage = [string]$exception.Message
            if ($exceptionMessage.Length -gt 1024) {
                $exceptionMessage = $exceptionMessage.Substring(0, 1024)
            }
            $messageParts.Add((
                '{0}; HRESULT=0x{1:X8}{2}; message={3}' -f
                    $exception.GetType().FullName,
                    $exception.HResult,
                    $nativeError,
                    $exceptionMessage
            ))
            $exception = $exception.InnerException
        }
        $scriptStackTrace = [string]$errorRecord.ScriptStackTrace
        if ($scriptStackTrace.Length -gt 2048) {
            $scriptStackTrace = $scriptStackTrace.Substring(0, 2048)
        }
        if ($scriptStackTrace) { $messageParts.Add('script_stack=' + $scriptStackTrace) }
        $message = $messageParts -join ' | '
        if ($message.Length -gt 4096) { $message = $message.Substring(0, 4096) }
        & $writeBootstrapDiagnostic 'runner-bootstrap-failed' $message
    }
    $result.status = 'failed'
    if ($null -eq $result.failure_reason) {
        $result.failure_reason = 'runner_error'
    }
}
finally {
    try {
        try {
            Exit-TestExecutionState -Previous $previousExecutionState
        }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'execution_state_restore_failed'
        }
        if ($candidateLane -and $null -ne $effectiveRuntimeRoot) {
            $journalAfter = $null
            $journalObserved = $false
            $runtimeRootAfter = $null
            try {
                $journalAfter = @(if ($null -ne $result.gui -and
                    $null -ne $result.gui.flow -and
                    @($result.gui.flow.raw_checkpoints).Count -gt 0) {
                    @(@($result.gui.flow.raw_checkpoints)[-1].journal_entries)
                } else {
                    @(Get-VmAutomatedJournalInventory -LocalAppData (Join-Path $effectiveRuntimeRoot 'gui\localappdata'))
                })
                $journalObserved = $true
                $ownedAfter = @(Get-VmAutomatedOwnedProcessInventory -Root $verified.root)
                if ($ownedAfter.Count -ne 0) {
                    throw 'An owned candidate process remains after the GUI flow.'
                }
                [void](Assert-AcceptanceProcessJobLedgerClosed)
                if (Test-Path -LiteralPath $effectiveRuntimeRoot) {
                    [void](Get-VmAutomatedRuntimeRootObservation -Root $effectiveRuntimeRoot)
                    Remove-Item -LiteralPath $effectiveRuntimeRoot -Recurse -Force
                }
                $runtimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $effectiveRuntimeRoot
                $result['raw_cleanup'] = [ordered]@{
                    owned_processes_after = $ownedAfter
                    runtime_root_after = $runtimeRootAfter
                    journal_after = (New-VmAutomatedJournalCleanupObservation `
                        -Observed $journalObserved -Entries $journalAfter)
                }
            }
            catch {
                $result.status = 'failed'
                $result.failure_reason = 'raw_cleanup_failed'
                try {
                    $runtimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $effectiveRuntimeRoot
                }
                catch {
                    $runtimeRootAfter = $null
                }
                $result['raw_cleanup'] = [ordered]@{
                    owned_processes_after = @(Get-VmAutomatedOwnedProcessInventory -Root $verified.root)
                    runtime_root_after = $runtimeRootAfter
                    journal_after = (New-VmAutomatedJournalCleanupObservation `
                        -Observed $journalObserved -Entries $journalAfter)
                }
            }
        }
        Write-ResultDocument -Root $verified.root -Result $result
    }
    finally {
        Exit-DesktopTestLock -Lock $desktopLock
    }
}
if ($result.status -cne 'passed') {
    throw 'Windows VM guest validation failed; inspect result.json.'
}
}

Export-ModuleMember -Function Invoke-DrWindowsVmGuest
