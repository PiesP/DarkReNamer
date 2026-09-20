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
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution requires Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $result.failure_reason = 'elevated_runner'
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution must be non-elevated.'
}
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($currentSession -ne $ExpectedSessionId) {
    $result.failure_reason = 'unexpected_session'
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution is in an unexpected session.'
}

$desktopLock = $null
$previousExecutionState = $null
$runtimeRoot = $null
try {
    $desktopLock = Enter-DesktopTestLock -SessionId $currentSession
    if ($null -eq $desktopLock) {
        $result.failure_reason = 'desktop_busy'
        throw 'Another Windows VM test runner is using this interactive desktop.'
    }
    $previousExecutionState = Enter-TestExecutionState
    $runtimeRoot = New-PrivateDirectory -Parent $verified.root -Leaf 'runtime'
    $testResults = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $verified.tests.Count; $index++) {
        $testResults.Add((Invoke-RustTestBinary `
            -Test $verified.tests[$index] `
            -Root $verified.root `
            -RuntimeRoot $runtimeRoot `
            -Index ($index + 1) `
            -TimeoutSeconds $TestTimeoutSeconds))
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
        -RuntimeRoot $runtimeRoot `
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
