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


$verified = Resolve-VerifiedBundle -Root $BundleRoot -InvokedScriptPath $EntryPointPath
if ($ValidateOnly) {
    $validatedSource = if ($verified.manifest.schema_version -eq 2) {
        $verified.manifest.product.source_sha
    } else {
        $verified.manifest.source_sha
    }
    Write-Host "Validated Windows VM bundle for source $validatedSource."
    return
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    if ([Environment]::GetEnvironmentVariable('DARKRENAMER_VM_ELEVATED_OBSERVER') -ceq '1') {
        throw 'The elevated VM observer requires a protected output directory.'
    }
    $OutputRoot = $verified.root
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$elevatedObserver = [Environment]::GetEnvironmentVariable(
    'DARKRENAMER_VM_ELEVATED_OBSERVER'
) -ceq '1'
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
$fixtureParentRoot = $null
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
if (-not $RuntimeRoot -and $elevatedObserver) {
    throw 'The elevated VM observer requires a separate candidate runtime directory.'
}
if ($RuntimeRoot) {
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
try {
    Assert-VmObserverExecutionContext -ExpectedSessionId $ExpectedSessionId
}
catch {
    if ($elevatedObserver) { $result.failure_reason = 'invalid_elevated_observer' }
    else { $result.failure_reason = 'elevated_runner' }
    throw
}
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($currentSession -ne $ExpectedSessionId) {
    $result.failure_reason = 'unexpected_session'
    throw 'Windows VM guest execution is in an unexpected session.'
}

$desktopLock = $null
$previousExecutionState = $null
$runtimeRoot = $null
try {
    Protect-CurrentRunnerProcess
    Initialize-TrustedResultWriter -Root $verified.root
    $desktopLock = Enter-DesktopTestLock -SessionId $currentSession
    if ($null -eq $desktopLock) {
        $result.failure_reason = 'desktop_busy'
        throw 'Another Windows VM test runner is using this interactive desktop.'
    }
    $previousExecutionState = Enter-TestExecutionState
    $runtimeRoot = if ($RuntimeRoot) {
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
            -RuntimeRoot $runtimeRoot `
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
        -RuntimeRoot $runtimeRoot `
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
        if ($candidateLane -and $null -ne $runtimeRoot) {
            $journalAfter = $null
            $journalObserved = $false
            $runtimeRootAfter = $null
            try {
                $journalAfter = @(if ($null -ne $result.gui -and
                    $null -ne $result.gui.flow -and
                    @($result.gui.flow.raw_checkpoints).Count -gt 0) {
                    @(@($result.gui.flow.raw_checkpoints)[-1].journal_entries)
                } else {
                    @(Get-VmAutomatedJournalInventory -LocalAppData (Join-Path $runtimeRoot 'gui\localappdata'))
                })
                $journalObserved = $true
                $ownedAfter = @(Get-VmAutomatedOwnedProcessInventory -Root $verified.root)
                if ($ownedAfter.Count -ne 0) {
                    throw 'An owned candidate process remains after the GUI flow.'
                }
                [void](Assert-AcceptanceProcessJobLedgerClosed)
                if (Test-Path -LiteralPath $runtimeRoot) {
                    [void](Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot)
                    Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
                }
                $runtimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot
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
                    $runtimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot
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
