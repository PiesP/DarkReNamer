function Initialize-RecoveryLockNative {
    if (-not ('DarkReNamerRecoveryLockNative' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class DarkReNamerRecoveryLockNative
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetDlgItem(IntPtr parent, int controlId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr window);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr window, uint flags);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);

    [DllImport("user32.dll")]
    public static extern int GetDlgCtrlID(IntPtr window);
}
'@
    }
}
function Get-AcceptanceControlTargetObservation {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Root,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][string] $ExpectedAutomationId,
        [Parameter(Mandatory)][int] $ExpectedControlId,
        [Parameter(Mandatory)][string] $Label
    )

    Initialize-RecoveryLockNative
    Assert-AcceptanceProcessBinding -Application $Application
    $process = $Application.owned.process
    Assert-AutomationBinding `
        -Element $Root -Process $process -ExpectedSession $SessionId `
        -Label "$Label root" -RequireWindowHandle
    Assert-AutomationBinding `
        -Element $Element -Process $process -ExpectedSession $SessionId `
        -Label $Label -RequireWindowHandle
    $handle = [IntPtr]$Element.Current.NativeWindowHandle
    $expectedRootHandle = [IntPtr]$Root.Current.NativeWindowHandle
    $rootHandle = [DarkReNamerRecoveryLockNative]::GetAncestor($handle, [uint32]2)
    if ($handle -eq [IntPtr]::Zero -or $rootHandle -eq [IntPtr]::Zero -or
        $rootHandle -ne $expectedRootHandle) {
        throw "$Label is not rooted in the exact owned automation window."
    }
    $controlProcessId = [uint32]0
    [void][DarkReNamerVmNative]::GetWindowThreadProcessId($handle, [ref]$controlProcessId)
    $rootProcessId = [uint32]0
    [void][DarkReNamerVmNative]::GetWindowThreadProcessId($rootHandle, [ref]$rootProcessId)
    if ($controlProcessId -ne [uint32]$process.Id -or
        $rootProcessId -ne [uint32]$process.Id -or
        $process.SessionId -ne $SessionId) {
        throw "$Label is not owned by the bound process and session."
    }
    $classText = [Text.StringBuilder]::new(64)
    if ([DarkReNamerVmNative]::GetClassName($handle, $classText, $classText.Capacity) -le 0 -or
        $classText.ToString() -cne 'Button') {
        throw "$Label is not the expected native Button class."
    }
    $controlId = [DarkReNamerRecoveryLockNative]::GetDlgCtrlID($handle)
    $automationId = $Element.Current.AutomationId
    $controlType = $Element.Current.ControlType.ProgrammaticName
    # TaskDialog exposes these logical commands through UIA while the owned
    # native Button can have control ID zero. Ordinary application controls and
    # other command links keep their exact native ID requirement.
    $zeroTaskDialogId = $controlId -eq 0 -and
        (Test-AcceptanceControlTargetId `
            -ControlId $controlId `
            -AutomationId $ExpectedAutomationId)
    $rootClass = $Root.Current.ClassName
    if (($controlId -ne $ExpectedControlId -and -not $zeroTaskDialogId) -or
        ($zeroTaskDialogId -and $rootClass -cne '#32770') -or
        $automationId -cne $ExpectedAutomationId -or
        $controlType -cne 'ControlType.Button') {
        throw "$Label identity mismatch: control_id=$controlId expected_control_id=$ExpectedControlId automation_id=$automationId expected_automation_id=$ExpectedAutomationId control_type=$controlType."
    }
    $focused = $false
    $focusedElement = [Windows.Automation.AutomationElement]::FocusedElement
    if ($null -ne $focusedElement) {
        try {
            $focused = [IntPtr]$focusedElement.Current.NativeWindowHandle -eq $handle -and
                $focusedElement.Current.ProcessId -eq $process.Id
        }
        catch [Windows.Automation.ElementNotAvailableException] {
            throw "$Label focus ownership became unavailable during observation."
        }
    }
    [ordered]@{
        pid = [int]$process.Id
        session_id = [int]$process.SessionId
        hwnd = [int64]$handle.ToInt64()
        root_hwnd = [int64]$rootHandle.ToInt64()
        class = $classText.ToString()
        control_id = [int]$controlId
        automation_id = $automationId
        control_type = $controlType
        enabled = [bool][DarkReNamerRecoveryLockNative]::IsWindowEnabled($handle)
        visible = [bool][DarkReNamerVmNative]::IsWindowVisible($handle)
        focused = [bool]$focused
    }
}
function Assert-AcceptanceRecoveryLockedControls {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][bool] $ExpectLocked
    )

    $apply = Find-UniqueAutomationElement `
        -Root $Application.main `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -AutomationId '32771' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -Scope ([Windows.Automation.TreeScope]::Children) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'Apply while Intent-only recovery is locked' `
        -RequireWindowHandle
    if ($ExpectLocked -and $apply.Current.IsEnabled) {
        throw 'Intent-only startup did not disable Apply under recovery lock.'
    }

    Initialize-RecoveryLockNative
    $process = $Application.owned.process
    Assert-AutomationBinding `
        -Element $Application.main `
        -Process $process `
        -ExpectedSession $SessionId `
        -Label 'Intent-only recovery main window' `
        -RequireWindowHandle
    $mainHandle = [IntPtr]$Application.main.Current.NativeWindowHandle
    $addHandle = [DarkReNamerRecoveryLockNative]::GetDlgItem($mainHandle, 32791)
    if ($addHandle -eq [IntPtr]::Zero -or -not [DarkReNamerVmNative]::IsWindow($addHandle)) {
        throw 'Intent-only recovery Add Files is not one live native control.'
    }
    if ([DarkReNamerRecoveryLockNative]::GetParent($addHandle) -ne $mainHandle) {
        throw 'Intent-only recovery Add Files is not a direct child of the bound main window.'
    }
    $addProcessId = [uint32]0
    [void][DarkReNamerVmNative]::GetWindowThreadProcessId($addHandle, [ref]$addProcessId)
    if ($addProcessId -ne [uint32]$process.Id -or $process.SessionId -ne $SessionId) {
        throw 'Intent-only recovery Add Files belongs to another process or desktop session.'
    }
    $addClass = [Text.StringBuilder]::new(64)
    if ([DarkReNamerVmNative]::GetClassName($addHandle, $addClass, $addClass.Capacity) -le 0 -or
        $addClass.ToString() -cne 'Button') {
        throw 'Intent-only recovery Add Files is not the expected native Button class.'
    }
    if ([DarkReNamerRecoveryLockNative]::GetDlgCtrlID($addHandle) -ne 32791) {
        throw 'Intent-only recovery Add Files has the wrong native control ID.'
    }
    $addEnabled = [DarkReNamerRecoveryLockNative]::IsWindowEnabled($addHandle)
    $addVisible = [DarkReNamerVmNative]::IsWindowVisible($addHandle)
    if ($ExpectLocked -and ($addEnabled -or $addVisible)) {
        throw 'Intent-only startup did not keep Add Files disabled and hidden under recovery lock.'
    }
    if (-not $ExpectLocked -and (-not $addEnabled -or -not $addVisible)) {
        throw 'Intent-only discard did not restore enabled and visible Add Files.'
    }
    $add = [Windows.Automation.AutomationElement]::FromHandle($addHandle)
    if ($null -eq $add) {
        throw 'Intent-only recovery Add Files is unavailable through UI Automation.'
    }
    $applyTarget = Get-AcceptanceControlTargetObservation `
        -Application $Application -Root $Application.main -Element $apply `
        -SessionId $SessionId -ExpectedAutomationId '32771' -ExpectedControlId 32771 `
        -Label 'Apply recovery-lock observation'
    $addTarget = Get-AcceptanceControlTargetObservation `
        -Application $Application -Root $Application.main -Element $add `
        -SessionId $SessionId -ExpectedAutomationId '32791' -ExpectedControlId 32791 `
        -Label 'Add Files recovery-lock observation'
    $observedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $reference = Write-AcceptanceLockStateEvidence `
        -PrivateRoot $PrivateRoot -Leaf $Leaf -Boundary $Boundary -Phase $Phase `
        -CandidatePid $process.Id -SessionId $SessionId -Apply $applyTarget -AddFiles $addTarget `
        -ObservedUtcTicks $observedUtcTicks
    [pscustomobject][ordered]@{
        locked = [bool]$ExpectLocked
        reference = $reference
    }
}
function Invoke-AcceptanceDiscardChoice {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][bool] $Confirm
    )

    $menuAction = Start-AcceptanceRecoveryMenuInvoke `
        -Application $Application `
        -PrivateRoot $PrivateRoot `
        -Purpose $(if ($Confirm) { 'discard-confirm' } else { 'discard-cancel' }) `
        -SessionId $SessionId `
        -WaitSeconds $WaitSeconds `
        -ItemName '시작되지 않은 작업 기록 삭제...' `
        -Label 'Intent-only candidate discard menu item'
    if ($menuAction.target_command_id -ne 0x9001 -or
        -not $menuAction.enter_sent -or -not $menuAction.popup_closed) {
        throw 'Intent-only discard menu action did not bind the exact native command.'
    }
    $prompt = Wait-AcceptanceRecoveryWindow `
        -Application $Application `
        -ExpectedSession $SessionId `
        -Name 'DarkReNamer - 활성화 전 계획 폐기' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'Intent-only candidate discard confirmation' `
        -PrivateRoot $PrivateRoot `
        -Purpose $(if ($Confirm) { 'intent-discard-confirm' } else { 'intent-discard-cancel' })
    $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
    $button = Find-UniqueAutomationElement `
        -Root $prompt `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -AutomationId $(if ($Confirm) { 'CommandLink_1201' } else { 'CommandButton_2' }) `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label $(if ($Confirm) { 'exact candidate discard confirmation' } else { 'candidate discard cancellation' }) `
        -RequireEnabled `
        -RequireWindowHandle
    $expectedAutomationId = if ($Confirm) { 'CommandLink_1201' } else { 'CommandButton_2' }
    $expectedControlId = if ($Confirm) { 1201 } else { 2 }
    $phase = if ($Confirm) { 'intent-discard-confirm' } else { 'intent-discard-cancel' }
    $action = if ($Confirm) { 'confirm-candidate-discard' } else { 'cancel-candidate-discard' }
    $boundary = if ($Confirm) { 'intent-discard-confirm-action' } else { 'intent-discard-cancel-action' }
    $leaf = if ($Confirm) { 'intent-discard-confirm-action' } else { 'intent-discard-cancel-action' }
    $target = Get-AcceptanceControlTargetObservation `
        -Application $Application -Root $prompt -Element $button `
        -SessionId $SessionId -ExpectedAutomationId $expectedAutomationId `
        -ExpectedControlId $expectedControlId `
        -Label $(if ($Confirm) { 'exact candidate discard confirmation' } else { 'candidate discard cancellation' })
    if (-not $target.enabled -or -not $target.visible) {
        throw 'The Intent-only discard action target is not enabled and visible.'
    }
    $observedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    Invoke-AutomationControl `
        -Element $button `
        -Label $(if ($Confirm) { 'exact candidate discard confirmation' } else { 'candidate discard cancellation' })
    Wait-WindowClosed `
        -Handle $promptHandle `
        -TimeoutSeconds $WaitSeconds `
        -Label 'Intent-only candidate discard confirmation'
    if ($Confirm) {
        Dismiss-AcceptanceMessage `
            -Application $Application `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds `
            -Name 'DarkReNamer - 폐기 완료' `
            -Label 'candidate discard completion message' `
            -PrivateRoot $PrivateRoot `
            -Purpose 'intent-discard-completion'
    }
    $completedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $actionEvidence = Write-AcceptanceActionEvidence `
        -PrivateRoot $PrivateRoot -Leaf $leaf -Boundary $boundary -Phase $phase `
        -Action $action -Target $target -ObservedUtcTicks $observedUtcTicks `
        -CompletedUtcTicks $completedUtcTicks
    Remove-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot `
        -Purpose $(if ($Confirm) { 'discard-confirm' } else { 'discard-cancel' })
    $actionEvidence
}
function Invoke-AcceptanceIntentOnlyCandidateDiscard {
    param(
        [Parameter(Mandatory)][object] $Inputs,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][object] $RootIdentity,
        [Parameter(Mandatory)][object[]] $Initial,
        [Parameter(Mandatory)][byte[]] $IntentBytes,
        [Parameter(Mandatory)][object] $InterruptedJournalReference,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $inspection = Get-AcceptanceJournalInspection -Bytes $IntentBytes
    $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
    $candidatePath = Join-Path $journalRoot 'candidate.drj'
    $activePath = Join-Path $journalRoot 'active.drj'
    if (@(Get-Process -Name 'DarkReNamer' -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'Intent-only staging requires the product process to be normally exited.'
    }
    if ((Test-Path -LiteralPath $candidatePath) -or
        (Test-Path -LiteralPath $activePath)) {
        throw 'Intent-only staging requires a clean isolated journal profile.'
    }
    $states = [ordered]@{}
    $journals = [ordered]@{}
    $lockStates = [ordered]@{}
    $processes = [Collections.Generic.List[object]]::new()
    $states.pre_stage = Write-AcceptanceObservedStateEvidence `
        -PrivateRoot $PrivateRoot -Leaf 'intent-state-pre-stage' -Boundary 'intent-pre-stage' `
        -FixtureRoot $FixtureRoot -ExpectedRootIdentity $RootIdentity -State $Initial
    $journals.pre_stage = Write-AcceptanceJournalInventoryEvidence `
        -PrivateRoot $PrivateRoot -Leaf 'intent-journal-pre-stage' -Boundary 'intent-pre-stage' `
        -JournalRoot $journalRoot
    $candidateSource = Write-AcceptanceJournalBytesEvidence `
        -PrivateRoot $PrivateRoot -Leaf 'intent-authentic-source.drj' `
        -Boundary 'authentic-first-intent-frame' -Bytes $IntentBytes
    Write-AcceptanceNewBytes -Path $candidatePath -Bytes $IntentBytes
    if (-not (Test-AcceptanceBytesEqual `
            -Expected $IntentBytes `
            -Actual ([IO.File]::ReadAllBytes($candidatePath)))) {
        throw 'The staged Intent-only candidate differs from the authentic first frame.'
    }
    $stagedState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
    Assert-AcceptanceStatesEqual -Expected $Initial -Actual $stagedState -Label 'Intent-only staging fixture'
    $states.staged = Write-AcceptanceObservedStateEvidence `
        -PrivateRoot $PrivateRoot -Leaf 'intent-state-staged' -Boundary 'intent-staged' `
        -FixtureRoot $FixtureRoot -ExpectedRootIdentity $RootIdentity -State $stagedState
    $journals.staged = Write-AcceptanceJournalInventoryEvidence `
        -PrivateRoot $PrivateRoot -Leaf 'intent-journal-staged' -Boundary 'intent-staged' `
        -JournalRoot $journalRoot

    $cancelApplication = $null
    $relaunchApplication = $null
    $discardApplication = $null
    $scenarioError = $null
    try {
        $cancelApplication = Start-AcceptanceApplication `
            -Inputs $Inputs `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds
        $processes.Add((Write-AcceptanceProcessStartEvidence `
            -Application $cancelApplication -Inputs $Inputs -FixtureRoot $FixtureRoot `
            -PrivateRoot $PrivateRoot -Role 'intent-cancel'))
        $startupNotice = Wait-AcceptanceRecoveryWindow `
            -Application $cancelApplication `
            -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 복구 상태' `
            -TimeoutSeconds $WaitSeconds `
            -Label 'Intent-only startup recovery-lock notice' `
            -PrivateRoot $PrivateRoot `
            -Purpose 'intent-startup-notice'
        $startupState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $Initial `
            -Actual $startupState `
            -Label 'Intent-only startup fixture'
        $states.startup = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-state-startup' -Boundary 'intent-startup' `
            -FixtureRoot $FixtureRoot -ExpectedRootIdentity $RootIdentity -State $startupState
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf) -or
            (Test-Path -LiteralPath $activePath)) {
            throw 'Intent-only startup did not preserve one candidate without an active journal.'
        }
        Dismiss-AcceptanceMessage `
            -Application $cancelApplication `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds `
            -Name 'DarkReNamer - 복구 상태' `
            -Label 'Intent-only startup recovery-lock notice' `
            -PrivateRoot $PrivateRoot `
            -Purpose 'intent-startup-notice' `
            -Window $startupNotice
        $startupLock = Assert-AcceptanceRecoveryLockedControls `
            -Application $cancelApplication -PrivateRoot $PrivateRoot `
            -Leaf 'intent-startup-lock' -Boundary 'intent-startup-lock' `
            -Phase 'intent-startup' -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -ExpectLocked $true
        $startupLocked = $startupLock.locked
        $lockStates.startup = $startupLock.reference

        $cancelDiscardAction = Invoke-AcceptanceDiscardChoice `
            -Application $cancelApplication -PrivateRoot $PrivateRoot `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds `
            -Confirm $false
        $cancelState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $Initial `
            -Actual $cancelState `
            -Label 'Cancelled Intent-only discard fixture'
        $postCancelLock = Assert-AcceptanceRecoveryLockedControls `
            -Application $cancelApplication -PrivateRoot $PrivateRoot `
            -Leaf 'intent-post-cancel-lock' -Boundary 'intent-post-cancel-lock' `
            -Phase 'intent-post-cancel' -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -ExpectLocked $true
        $cancelLocked = $postCancelLock.locked
        $lockStates.post_cancel = $postCancelLock.reference
        $states.post_cancel = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-state-post-cancel' -Boundary 'intent-post-cancel' `
            -FixtureRoot $FixtureRoot -ExpectedRootIdentity $RootIdentity -State $cancelState
        $cancelPreserved = (Test-Path -LiteralPath $candidatePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $activePath)
        if (-not $cancelPreserved) {
            throw 'Cancelling Intent-only discard did not preserve only candidate.drj.'
        }
        [void](Close-AcceptanceApplicationNormally `
            -Application $cancelApplication `
            -WaitSeconds $WaitSeconds)
        $processes.Add((Write-AcceptanceProcessExitEvidence `
            -Application $cancelApplication -PrivateRoot $PrivateRoot `
            -Boundary 'normal-exit' -ExitMethod 'normal-close'))
        $preservedBytes = [IO.File]::ReadAllBytes($candidatePath)
        if (-not (Test-AcceptanceBytesEqual -Expected $IntentBytes -Actual $preservedBytes)) {
            throw 'Cancelling Intent-only discard did not preserve the exact candidate bytes.'
        }
        $candidateAfterCancel = Write-AcceptanceJournalBytesEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-after-cancel.drj' `
            -Boundary 'intent-post-cancel-normal-exit' -Bytes $preservedBytes
        $postCancelExitState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual -Expected $Initial -Actual $postCancelExitState `
            -Label 'Intent-only post-cancel normal-exit fixture'
        $states.post_cancel_exit = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-state-post-cancel-exit' `
            -Boundary 'intent-post-cancel-normal-exit' -FixtureRoot $FixtureRoot `
            -ExpectedRootIdentity $RootIdentity -State $postCancelExitState
        $journals.post_cancel_exit = Write-AcceptanceJournalInventoryEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-journal-post-cancel-exit' `
            -Boundary 'intent-post-cancel-normal-exit' -JournalRoot $journalRoot

        $relaunchApplication = Start-AcceptanceApplication `
            -Inputs $Inputs `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds
        $processes.Add((Write-AcceptanceProcessStartEvidence `
            -Application $relaunchApplication -Inputs $Inputs -FixtureRoot $FixtureRoot `
            -PrivateRoot $PrivateRoot -Role 'intent-relaunch'))
        Dismiss-AcceptanceMessage `
            -Application $relaunchApplication `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds `
            -Name 'DarkReNamer - 복구 상태' `
            -Label 'Intent-only verification relaunch recovery-lock notice' `
            -PrivateRoot $PrivateRoot `
            -Purpose 'intent-relaunch-notice'
        $relaunchLock = Assert-AcceptanceRecoveryLockedControls `
            -Application $relaunchApplication -PrivateRoot $PrivateRoot `
            -Leaf 'intent-relaunch-lock' -Boundary 'intent-relaunch-lock' `
            -Phase 'intent-relaunch' -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -ExpectLocked $true
        $lockStates.relaunch = $relaunchLock.reference
        $relaunchState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $Initial `
            -Actual $relaunchState `
            -Label 'Intent-only verification relaunch fixture'
        $states.relaunch = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-state-relaunch' -Boundary 'intent-relaunch' `
            -FixtureRoot $FixtureRoot -ExpectedRootIdentity $RootIdentity -State $relaunchState
        [void](Close-AcceptanceApplicationNormally `
            -Application $relaunchApplication -WaitSeconds $WaitSeconds)
        $processes.Add((Write-AcceptanceProcessExitEvidence `
            -Application $relaunchApplication -PrivateRoot $PrivateRoot `
            -Boundary 'normal-exit' -ExitMethod 'normal-close'))
        $relaunchBytes = [IO.File]::ReadAllBytes($candidatePath)
        if (-not (Test-AcceptanceBytesEqual -Expected $IntentBytes -Actual $relaunchBytes)) {
            throw 'Intent-only verification relaunch did not preserve the exact candidate bytes.'
        }
        $candidateAfterRelaunch = Write-AcceptanceJournalBytesEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-after-relaunch.drj' `
            -Boundary 'intent-post-relaunch-normal-exit' -Bytes $relaunchBytes
        $relaunchExitState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual -Expected $Initial -Actual $relaunchExitState `
            -Label 'Intent-only verification relaunch normal-exit fixture'
        $states.relaunch_exit = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-state-relaunch-exit' `
            -Boundary 'intent-post-relaunch-normal-exit' -FixtureRoot $FixtureRoot `
            -ExpectedRootIdentity $RootIdentity -State $relaunchExitState
        $journals.relaunch_exit = Write-AcceptanceJournalInventoryEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-journal-relaunch-exit' `
            -Boundary 'intent-post-relaunch-normal-exit' -JournalRoot $journalRoot

        $discardApplication = Start-AcceptanceApplication `
            -Inputs $Inputs -SessionId $SessionId -WaitSeconds $WaitSeconds
        $processes.Add((Write-AcceptanceProcessStartEvidence `
            -Application $discardApplication -Inputs $Inputs -FixtureRoot $FixtureRoot `
            -PrivateRoot $PrivateRoot -Role 'intent-discard'))
        Dismiss-AcceptanceMessage `
            -Application $discardApplication -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -Name 'DarkReNamer - 복구 상태' -Label 'Intent-only discard recovery-lock notice' `
            -PrivateRoot $PrivateRoot -Purpose 'intent-discard-notice'
        $discardStartupLock = Assert-AcceptanceRecoveryLockedControls `
            -Application $discardApplication -PrivateRoot $PrivateRoot `
            -Leaf 'intent-discard-startup-lock' -Boundary 'intent-discard-startup-lock' `
            -Phase 'intent-discard-startup' -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -ExpectLocked $true
        $lockStates.discard_startup = $discardStartupLock.reference
        $discardStartupState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual -Expected $Initial -Actual $discardStartupState `
            -Label 'Intent-only discard startup fixture'
        $states.discard_startup = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-state-discard-startup' `
            -Boundary 'intent-discard-startup' -FixtureRoot $FixtureRoot `
            -ExpectedRootIdentity $RootIdentity -State $discardStartupState
        $confirmDiscardAction = Invoke-AcceptanceDiscardChoice `
            -Application $discardApplication -PrivateRoot $PrivateRoot `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds `
            -Confirm $true
        $candidateRemoved = -not (Test-Path -LiteralPath $candidatePath)
        $activeAbsent = -not (Test-Path -LiteralPath $activePath)
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $postDiscardLock = Assert-AcceptanceRecoveryLockedControls `
            -Application $discardApplication -PrivateRoot $PrivateRoot `
            -Leaf 'intent-post-discard-unlock' -Boundary 'intent-post-discard-unlock' `
            -Phase 'intent-post-discard' -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -ExpectLocked $false
        $discardUnlocked = -not $postDiscardLock.locked
        $lockStates.post_discard = $postDiscardLock.reference
        $discardState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $Initial `
            -Actual $discardState `
            -Label 'Confirmed Intent-only discard fixture'
        $states.discarded = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-state-discarded' -Boundary 'intent-discarded' `
            -FixtureRoot $FixtureRoot -ExpectedRootIdentity $RootIdentity -State $discardState
        $classification = Get-AcceptanceIntentCandidateClassification `
            -JournalInspection $inspection `
            -StartupLocked $startupLocked `
            -StartupUnchanged $true `
            -CancelPreserved $cancelPreserved `
            -CancelUnchanged $true `
            -CancelLocked $cancelLocked `
            -RelaunchPreserved $true `
            -CandidateRemoved $candidateRemoved `
            -ActiveAbsent $activeAbsent `
            -DiscardUnlocked $discardUnlocked `
            -DiscardUnchanged $true
        $exitCode = Close-AcceptanceApplicationNormally `
            -Application $discardApplication `
            -WaitSeconds $WaitSeconds
        $processes.Add((Write-AcceptanceProcessExitEvidence `
            -Application $discardApplication -PrivateRoot $PrivateRoot `
            -Boundary 'normal-exit' -ExitMethod 'normal-close'))
        $finalState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual -Expected $Initial -Actual $finalState `
            -Label 'Intent-only final normal-exit fixture'
        $states.final_exit = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-state-final-exit' `
            -Boundary 'intent-final-normal-exit' -FixtureRoot $FixtureRoot `
            -ExpectedRootIdentity $RootIdentity -State $finalState
        $journals.final_exit = Write-AcceptanceJournalInventoryEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'intent-journal-final-exit' `
            -Boundary 'intent-final-normal-exit' -JournalRoot $journalRoot
        [pscustomobject]@{
            status = 'passed'
            classification = $classification
            candidate = [ordered]@{
                bytes = $IntentBytes.Length
                sha256 = Get-AcceptanceBootstrapBytesSha256 -Bytes $IntentBytes
                complete_frames = $inspection.complete_frames
                last_kind = $inspection.last_kind
                tail = $inspection.tail
                source_active_journal = $InterruptedJournalReference
                injected_candidate = $candidateSource
                after_cancel = $candidateAfterCancel
                after_relaunch = $candidateAfterRelaunch
            }
            startup_locked = $startupLocked
            startup_state_sha256 = Get-AcceptanceStateDigest -State $startupState
            cancel_preserved_exact_bytes = $true
            relaunch_preserved_exact_bytes = $true
            cancel_state_sha256 = Get-AcceptanceStateDigest -State $cancelState
            candidate_removed = $candidateRemoved
            active_absent = $activeAbsent
            discard_unlocked = $discardUnlocked
            fixture_name_content_identity_unchanged = $true
            discard_state_sha256 = Get-AcceptanceStateDigest -State $discardState
            normal_exit_code = $exitCode
            states = $states
            journals = $journals
            actions = [ordered]@{
                cancel_discard = $cancelDiscardAction
                confirm_discard = $confirmDiscardAction
            }
            lock_states = $lockStates
            processes = $processes.ToArray()
        }
    }
    catch {
        $scenarioError = $_
        throw
    }
    finally {
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        foreach ($application in @($cancelApplication, $relaunchApplication, $discardApplication)) {
            if ($null -eq $application) { continue }
            try {
                $process = $application.owned.process
                $process.Refresh()
                if (-not $process.HasExited) {
                    $process.Kill()
                    if (-not $process.WaitForExit(10000)) {
                        throw 'The exact Intent-only process did not terminate during cleanup.'
                    }
                }
                $bindingProperty = $application.PSObject.Properties['raw_process_binding']
                $exitProperty = $application.PSObject.Properties['raw_process_exit_recorded']
                if ($null -ne $bindingProperty -and $null -ne $exitProperty -and
                    -not [bool]$exitProperty.Value) {
                    $processes.Add((Write-AcceptanceProcessExitEvidence `
                        -Application $application -PrivateRoot $PrivateRoot `
                        -Boundary 'failure-cleanup' -ExitMethod 'forced-termination'))
                }
                $process.Dispose()
            }
            catch {
                $cleanupErrors.Add($_.Exception.Message)
            }
        }
        if ($cleanupErrors.Count -gt 0) {
            $cleanupMessage = [string]::Join(' | ', $cleanupErrors)
            if ($null -ne $scenarioError) {
                throw "Intent-only scenario and exact-process cleanup both failed: $($scenarioError.Exception.Message) Cleanup: $cleanupMessage"
            }
            throw "Intent-only exact-process cleanup failed: $cleanupMessage"
        }
    }
}
function Invoke-AcceptanceSession {
    param(
        [Parameter(Mandatory)][object] $Inputs,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][int] $Count,
        [Parameter(Mandatory)][ValidateSet('ProcessCrash', 'WorkerCancellation', 'WorkerClose')]
        [string] $Mode,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][bool] $RunRecoveryExport,
        [Parameter(Mandatory)][bool] $RunIntentOnlyCandidateDiscard
    )

    $prefix = 'vm-recovered-'
    $fixtureRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'fixture'
    $paths = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Count; $index++) {
        $name = 'item-{0:D5}.txt' -f $index
        $path = Join-Path $fixtureRoot $name
        $content = [Text.UTF8Encoding]::new($false).GetBytes("fixture-$index`n")
        [IO.File]::WriteAllBytes($path, $content)
        $paths.Add($path)
    }
    [IO.File]::WriteAllBytes(
        (Join-Path $fixtureRoot 'sentinel.bin'),
        [Text.UTF8Encoding]::new($false).GetBytes("sentinel`n")
    )
    $pathsFile = Join-Path $RuntimeRoot 'paths-utf16le.txt'
    $importBytes = Write-AcceptanceUtf16Paths -Path $pathsFile -Paths $paths.ToArray()
    $rootIdentity = Get-FullFileIdentity -Path $fixtureRoot
    [void](Get-AcceptanceIdentityKey -Identity $rootIdentity)
    $initial = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
    if ($initial.Count -ne $Count + 1) {
        throw 'The initial fixture count is incorrect.'
    }
    $initialReference = Write-AcceptanceObservedStateEvidence `
        -PrivateRoot $PrivateRoot -Leaf 'state-initial' -Boundary 'initial' `
        -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity -State $initial
    $initialFirst = @($initial | Where-Object name -CEQ 'item-00000.txt')
    $initialLastName = 'item-{0:D5}.txt' -f ($Count - 1)
    $initialLast = @($initial | Where-Object name -CEQ $initialLastName)
    if ($initialFirst.Count -ne 1 -or $initialLast.Count -ne 1) {
        throw 'The initial fixture does not contain unique boundary witnesses.'
    }

    $applications = [Collections.Generic.List[object]]::new()
    $processes = [Collections.Generic.List[object]]::new()
    $foregroundObservations = [Collections.Generic.List[object]]::new()
    $first = $null
    $sessionError = $null
    $recoveryExportResult = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
    $intentDiscardResult = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
    try {
        $first = Start-AcceptanceApplication `
            -Inputs $Inputs -SessionId $SessionId -WaitSeconds $WaitSeconds
        $applications.Add($first)
        $processes.Add((Write-AcceptanceProcessStartEvidence `
            -Application $first -Inputs $Inputs -FixtureRoot $fixtureRoot `
            -PrivateRoot $PrivateRoot -Role 'rename-worker'))
        Invoke-AcceptanceImportAndPrefix `
            -Application $first -PathsFile $pathsFile -Prefix $prefix `
            -SessionId $SessionId -WaitSeconds $WaitSeconds
        Invoke-AcceptanceApply -Application $first -SessionId $SessionId -WaitSeconds $WaitSeconds

        $boundaryDeadline = (Get-Date).AddSeconds($WaitSeconds)
        $renamedObserved = 0
        do {
            $renamedObserved = [IO.Directory]::GetFiles(
                $fixtureRoot,
                ($prefix + '*.txt'),
                [IO.SearchOption]::TopDirectoryOnly
            ).Length
            if ($renamedObserved -gt 0 -and $renamedObserved -lt $Count) { break }
            if ($renamedObserved -ge $Count) {
                throw 'The rename completed before a genuine partial boundary was captured.'
            }
            Start-Sleep -Milliseconds 1
        } while ((Get-Date) -lt $boundaryDeadline)
        if ($renamedObserved -le 0 -or $renamedObserved -ge $Count) {
            throw 'No genuine partial rename boundary was observed before timeout.'
        }

        if ($Mode -ne 'ProcessCrash') {
            $workerCancel = Find-UniqueAutomationElement `
                -Root $first.main -Process $first.owned.process -ExpectedSession $SessionId `
                -AutomationId '1009' -ControlType ([Windows.Automation.ControlType]::Button) `
                -TimeoutSeconds $WaitSeconds -Label 'visible worker cancellation control' `
                -Scope ([Windows.Automation.TreeScope]::Children) -RequireEnabled -RequireWindowHandle
            $workerBoundary = Get-AcceptanceActiveWorkerBoundary `
                -Application $first -Cancel $workerCancel -FixtureRoot $fixtureRoot -Prefix $prefix `
                -LocalAppData $env:LOCALAPPDATA -InitialFirst $initialFirst[0] `
                -InitialLast $initialLast[0] -ExpectedCount $Count -SessionId $SessionId
            $partialWitnessReference = Write-AcceptanceWorkerPartialWitnessEvidence `
                -PrivateRoot $PrivateRoot `
                -Leaf ('worker-' + $Mode.ToLowerInvariant() + '-partial-witness') `
                -FixtureRoot $fixtureRoot `
                -ExpectedRootIdentity $rootIdentity `
                -Witness $workerBoundary.partial_witness
            $screenshot = $null
            $workerCancelAction = $null
            if ($Mode -eq 'WorkerCancellation') {
                $workerCancelTarget = Get-AcceptanceControlTargetObservation `
                    -Application $first -Root $first.main -Element $workerBoundary.cancel `
                    -SessionId $SessionId -ExpectedAutomationId '1009' -ExpectedControlId 1009 `
                    -Label 'active worker cancellation control'
                if (-not $workerCancelTarget.enabled -or -not $workerCancelTarget.visible) {
                    throw 'The active worker cancellation target is not enabled and visible.'
                }
                $workerCancelObservedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                )
                Invoke-AutomationControl `
                    -Element $workerBoundary.cancel -Label 'active worker cancellation control'
                $restored = Wait-AcceptanceWorkerRollback `
                    -FixtureRoot $fixtureRoot -LocalAppData $env:LOCALAPPDATA `
                    -Initial $initial -WaitSeconds $WaitSeconds
                $workerCancelCompletedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                )
                $workerCancelAction = Write-AcceptanceActionEvidence `
                    -PrivateRoot $PrivateRoot -Leaf 'worker-cancellation-action' `
                    -Boundary 'worker-cancellation-action' -Phase 'worker-cancellation' `
                    -Action 'cancel-active-worker' -Target $workerCancelTarget `
                    -ObservedUtcTicks $workerCancelObservedUtcTicks `
                    -CompletedUtcTicks $workerCancelCompletedUtcTicks
                $screenshot = Save-WindowScreenshot `
                    -Window $first.main -Process $first.owned.process -ExpectedSession $SessionId `
                    -Root $EvidenceRoot -Leaf 'worker-cancellation-restored.png' `
                    -Label 'worker cancellation restored state' `
                    -ForegroundObservations $foregroundObservations
            }
            else {
                [void](Close-AcceptanceApplicationNormally `
                    -Application $first -WaitSeconds $WaitSeconds)
                $restored = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
                Assert-AcceptanceStatesEqual `
                    -Expected $initial -Actual $restored -Label 'Worker-close rollback fixture'
            }
            if ($Mode -eq 'WorkerCancellation') {
                $exitCode = Close-AcceptanceApplicationNormally `
                    -Application $first -WaitSeconds $WaitSeconds
            }
            else {
                $exitCode = $first.owned.process.ExitCode
            }
            $exitMethod = if ($Mode -ceq 'WorkerClose') { 'worker-close' } else { 'normal-close' }
            $processes.Add((Write-AcceptanceProcessExitEvidence `
                -Application $first -PrivateRoot $PrivateRoot `
                -Boundary 'normal-exit' -ExitMethod $exitMethod))
            Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
            $restoredReference = Write-AcceptanceObservedStateEvidence `
                -PrivateRoot $PrivateRoot -Leaf ('state-' + $Mode.ToLowerInvariant() + '-restored') `
                -Boundary ($Mode.ToLowerInvariant() + '-restored-normal-exit') `
                -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity -State $restored
            $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
            $journalReference = Write-AcceptanceJournalInventoryEvidence `
                -PrivateRoot $PrivateRoot -Leaf ('journal-' + $Mode.ToLowerInvariant() + '-post-rollback') `
                -Boundary ($Mode.ToLowerInvariant() + '-post-rollback-normal-exit') `
                -JournalRoot $journalRoot
            $foregroundReference = $null
            if ($foregroundObservations.Count -gt 0) {
                $foregroundReference = Write-AcceptanceForegroundEvidence `
                    -PrivateRoot $PrivateRoot -Observations $foregroundObservations
            }
            return [pscustomobject]@{
                mode_result = [pscustomobject]@{
                    status = 'passed'
                    mode = $Mode
                    classification = $workerBoundary.classification
                    fixture_count = $Count
                    import_bytes = $importBytes
                    observed_partial_rename = $workerBoundary.observed_partial_rename
                    witnesses = [ordered]@{
                        count = $workerBoundary.witness_count
                        first_destination_name_sha256 = $workerBoundary.first_destination_name_sha256
                        last_original_name_sha256 = $workerBoundary.last_original_name_sha256
                        first_destination_content_sha256 = $workerBoundary.first_destination_content_sha256
                        last_original_content_sha256 = $workerBoundary.last_original_content_sha256
                        first_destination_identity_sha256 = $workerBoundary.first_destination_identity_sha256
                        last_original_identity_sha256 = $workerBoundary.last_original_identity_sha256
                    }
                    initial_state_sha256 = Get-AcceptanceStateDigest -State $initial
                    restored_state_sha256 = Get-AcceptanceStateDigest -State $restored
                    raw_states = [ordered]@{
                        initial = $initialReference
                        restored = $restoredReference
                    }
                    partial_witness = $partialWitnessReference
                    journal_inventory = $journalReference
                    actions = [ordered]@{
                        worker_cancel = $workerCancelAction
                    }
                    processes = $processes.ToArray()
                    foreground_observations = $foregroundReference
                    journal_residue_count = 0
                    screenshot = $screenshot
                    normal_exit_code = $exitCode
                }
                recovery_export = $recoveryExportResult
                intent_only_candidate_discard = $intentDiscardResult
            }
        }

        Stop-AcceptanceOwnedProcess -Application $first
        $processes.Add((Write-AcceptanceProcessExitEvidence `
            -Application $first -PrivateRoot $PrivateRoot `
            -Boundary 'crash-stop' -ExitMethod 'forced-termination'))
        $partial = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
        $partialCounts = Assert-AcceptancePartialState `
            -Initial $initial -Partial $partial -Prefix $prefix -ExpectedCount $Count
        $partialReference = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'state-crash-partial' -Boundary 'crash-partial' `
            -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity -State $partial
        $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
        $activePath = Join-Path $journalRoot 'active.drj'
        $candidatePath = Join-Path $journalRoot 'candidate.drj'
        $activeExists = Test-Path -LiteralPath $activePath -PathType Leaf
        $candidateExists = Test-Path -LiteralPath $candidatePath -PathType Leaf
        if (-not $activeExists) { throw 'The stopped partial transaction has no active journal.' }
        $activeItem = Get-Item -LiteralPath $activePath -Force
        if (($activeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $activeItem.Length -lt 24 -or $activeItem.Length -gt 64MB) {
            throw 'The stopped active journal is unsafe or outside the acceptance bound.'
        }
        $journalBytes = [IO.File]::ReadAllBytes($activePath)
        $inspection = Get-AcceptanceJournalInspection -Bytes $journalBytes
        $intentBytes = $null
        if ($RunIntentOnlyCandidateDiscard) {
            $intentBytes = Get-AcceptanceLeadingIntentFrame -Bytes $journalBytes -Inspection $inspection
        }
        $classification = Get-AcceptanceCrashClassification `
            -OriginalCount $partialCounts.original -RenamedCount $partialCounts.renamed `
            -ExpectedCount $Count -ActiveJournalExists $activeExists `
            -CandidateJournalExists $candidateExists -JournalInspection $inspection
        $interruptedJournalReference = Write-AcceptanceJournalBytesEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'interrupted-active.drj' `
            -Boundary 'crash-stop-active-journal' -Bytes $journalBytes
        $crashJournalInventory = Write-AcceptanceJournalInventoryEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'journal-crash-stop' -Boundary 'crash-stop' `
            -JournalRoot $journalRoot

        $second = Start-AcceptanceApplication `
            -Inputs $Inputs -SessionId $SessionId -WaitSeconds $WaitSeconds
        $applications.Add($second)
        $processes.Add((Write-AcceptanceProcessStartEvidence `
            -Application $second -Inputs $Inputs -FixtureRoot $fixtureRoot `
            -PrivateRoot $PrivateRoot -Role 'startup-default-cancel'))
        $recoveryPrompt = Wait-AcceptanceRecoveryWindow `
            -Application $second -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 이전 변경 복구 확인' -TimeoutSeconds $WaitSeconds `
            -Label 'startup recovery confirmation before default cancel' `
            -PrivateRoot $PrivateRoot -Purpose 'startup-default-cancel'
        Assert-AutomationBinding `
            -Element $recoveryPrompt -Process $second.owned.process -ExpectedSession $SessionId `
            -Label 'startup recovery confirmation before default cancel' -RequireWindowHandle
        $startupState = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $partial -Actual $startupState -Label 'Startup before default cancel'
        $startupReference = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'state-startup-before-cancel' `
            -Boundary 'startup-before-default-cancel' -FixtureRoot $fixtureRoot `
            -ExpectedRootIdentity $rootIdentity -State $startupState
        $defaultCancelAction = Dismiss-AcceptanceStartupRecovery `
            -Application $second -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -Prompt $recoveryPrompt `
            -PrivateRoot $PrivateRoot
        $cancelState = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $partial -Actual $cancelState -Label 'Default-cancel fixture'
        $cancelReference = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'state-default-cancel' `
            -Boundary 'default-cancel' -FixtureRoot $fixtureRoot `
            -ExpectedRootIdentity $rootIdentity -State $cancelState
        [void](Close-AcceptanceApplicationNormally -Application $second -WaitSeconds $WaitSeconds)
        $processes.Add((Write-AcceptanceProcessExitEvidence `
            -Application $second -PrivateRoot $PrivateRoot `
            -Boundary 'normal-exit' -ExitMethod 'normal-close'))
        $afterCancelBytes = [IO.File]::ReadAllBytes($activePath)
        if (-not (Test-AcceptanceBytesEqual -Expected $journalBytes -Actual $afterCancelBytes)) {
            throw 'Default cancellation and normal exit changed the active journal bytes.'
        }
        $afterCancelJournalReference = Write-AcceptanceJournalBytesEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'active-after-default-cancel.drj' `
            -Boundary 'default-cancel-normal-exit' -Bytes $afterCancelBytes
        $afterCancelInventory = Write-AcceptanceJournalInventoryEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'journal-after-default-cancel' `
            -Boundary 'default-cancel-normal-exit' -JournalRoot $journalRoot

        $third = Start-AcceptanceApplication `
            -Inputs $Inputs -SessionId $SessionId -WaitSeconds $WaitSeconds
        $applications.Add($third)
        $processes.Add((Write-AcceptanceProcessStartEvidence `
            -Application $third -Inputs $Inputs -FixtureRoot $fixtureRoot `
            -PrivateRoot $PrivateRoot -Role 'recovery-relaunch'))
        $relaunchPrompt = Wait-AcceptanceRecoveryWindow `
            -Application $third -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 이전 변경 복구 확인' -TimeoutSeconds $WaitSeconds `
            -Label 'startup recovery confirmation after default cancel' `
            -PrivateRoot $PrivateRoot -Purpose 'recovery-relaunch'
        Assert-AutomationBinding `
            -Element $relaunchPrompt -Process $third.owned.process -ExpectedSession $SessionId `
            -Label 'startup recovery confirmation after default cancel' -RequireWindowHandle
        $relaunchState = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $partial -Actual $relaunchState -Label 'Recovery relaunch fixture'
        $relaunchReference = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'state-relaunch' -Boundary 'recovery-relaunch' `
            -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity -State $relaunchState

        $recoveryApplication = $third
        $recoveryPromptForAction = $relaunchPrompt
        $afterExportJournalReference = $null
        $afterExportInventory = $null
        $afterExportStateReference = $null
        $exportRelaunchStateReference = $null
        if ($RunRecoveryExport) {
            Write-AcceptanceExportProgress -PrivateRoot $PrivateRoot -Application $third -Phase 'before-startup-cancel'
            Dismiss-AcceptanceStartupRecovery `
                -Application $third -SessionId $SessionId -WaitSeconds $WaitSeconds `
                -Prompt $relaunchPrompt
            Write-AcceptanceExportProgress -PrivateRoot $PrivateRoot -Application $third -Phase 'after-startup-cancel'
            $recoveryExportResult = Invoke-AcceptanceRecoveryExport `
                -Application $third -PrivateRoot $PrivateRoot -ExpectedBytes $journalBytes `
                -SourceActiveJournalReference $interruptedJournalReference `
                -SessionId $SessionId -WaitSeconds $WaitSeconds
            $afterExport = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
            Assert-AcceptanceStatesEqual `
                -Expected $partial -Actual $afterExport -Label 'Recovery export fixture'
            $afterExportStateReference = Write-AcceptanceObservedStateEvidence `
                -PrivateRoot $PrivateRoot -Leaf 'state-after-export' -Boundary 'recovery-after-export' `
                -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity -State $afterExport
            $recoveryExportResult | Add-Member `
                -NotePropertyName fixture_name_content_identity_unchanged -NotePropertyValue $true
            [void](Close-AcceptanceApplicationNormally -Application $third -WaitSeconds $WaitSeconds)
            $processes.Add((Write-AcceptanceProcessExitEvidence `
                -Application $third -PrivateRoot $PrivateRoot `
                -Boundary 'normal-exit' -ExitMethod 'normal-close'))
            $afterExportBytes = [IO.File]::ReadAllBytes($activePath)
            if (-not (Test-AcceptanceBytesEqual -Expected $journalBytes -Actual $afterExportBytes)) {
                throw 'Recovery export and normal exit changed the active journal bytes.'
            }
            $afterExportJournalReference = Write-AcceptanceJournalBytesEvidence `
                -PrivateRoot $PrivateRoot -Leaf 'active-after-export.drj' `
                -Boundary 'recovery-export-normal-exit' -Bytes $afterExportBytes
            $afterExportInventory = Write-AcceptanceJournalInventoryEvidence `
                -PrivateRoot $PrivateRoot -Leaf 'journal-after-export' `
                -Boundary 'recovery-export-normal-exit' -JournalRoot $journalRoot
            $fourth = Start-AcceptanceApplication `
                -Inputs $Inputs -SessionId $SessionId -WaitSeconds $WaitSeconds
            $applications.Add($fourth)
            $processes.Add((Write-AcceptanceProcessStartEvidence `
                -Application $fourth -Inputs $Inputs -FixtureRoot $fixtureRoot `
                -PrivateRoot $PrivateRoot -Role 'recovery-after-export'))
            $exportRelaunchPrompt = Wait-AcceptanceRecoveryWindow `
                -Application $fourth -ExpectedSession $SessionId `
                -Name 'DarkReNamer - 이전 변경 복구 확인' -TimeoutSeconds $WaitSeconds `
                -Label 'startup recovery confirmation after export' `
                -PrivateRoot $PrivateRoot -Purpose 'recovery-export-relaunch'
            Assert-AutomationBinding `
                -Element $exportRelaunchPrompt -Process $fourth.owned.process `
                -ExpectedSession $SessionId -Label 'startup recovery confirmation after export' `
                -RequireWindowHandle
            $exportRelaunchState = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
            Assert-AcceptanceStatesEqual `
                -Expected $partial -Actual $exportRelaunchState -Label 'Startup after recovery export'
            $exportRelaunchStateReference = Write-AcceptanceObservedStateEvidence `
                -PrivateRoot $PrivateRoot -Leaf 'state-export-relaunch' -Boundary 'recovery-export-relaunch' `
                -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity -State $exportRelaunchState
            $recoveryApplication = $fourth
            $recoveryPromptForAction = $exportRelaunchPrompt
        }

        $recoveryScreenshot = Invoke-AcceptanceRecovery `
            -Application $recoveryApplication -EvidenceRoot $EvidenceRoot -PrivateRoot $PrivateRoot `
            -SessionId $SessionId -WaitSeconds $WaitSeconds `
            -ForegroundObservations $foregroundObservations `
            -Prompt $recoveryPromptForAction
        $restoreDeadline = (Get-Date).AddSeconds($WaitSeconds)
        do {
            try {
                Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
                $restored = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
                Assert-AcceptanceStatesEqual `
                    -Expected $initial -Actual $restored -Label 'Recovered fixture'
                break
            }
            catch { Start-Sleep -Milliseconds 100 }
        } while ((Get-Date) -lt $restoreDeadline)
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $restored = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
        Assert-AcceptanceStatesEqual -Expected $initial -Actual $restored -Label 'Recovered fixture'
        $restoredReference = Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'state-restored' -Boundary 'recovered' `
            -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity -State $restored
        $recoveryExitCode = Close-AcceptanceApplicationNormally `
            -Application $recoveryApplication -WaitSeconds $WaitSeconds
        $processes.Add((Write-AcceptanceProcessExitEvidence `
            -Application $recoveryApplication -PrivateRoot $PrivateRoot `
            -Boundary 'normal-exit' -ExitMethod 'normal-close'))
        $finalJournalInventory = Write-AcceptanceJournalInventoryEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'journal-final-recovered' `
            -Boundary 'recovered-normal-exit' -JournalRoot $journalRoot

        if ($RunIntentOnlyCandidateDiscard) {
            $intentDiscardResult = Invoke-AcceptanceIntentOnlyCandidateDiscard `
                -Inputs $Inputs -FixtureRoot $fixtureRoot -RootIdentity $rootIdentity `
                -Initial $initial -IntentBytes $intentBytes `
                -InterruptedJournalReference $interruptedJournalReference `
                -PrivateRoot $PrivateRoot `
                -SessionId $SessionId -WaitSeconds $WaitSeconds
        }
        $foregroundReference = Write-AcceptanceForegroundEvidence `
            -PrivateRoot $PrivateRoot -Observations $foregroundObservations
        [pscustomobject]@{
            mode_result = [pscustomobject]@{
                status = 'passed'
                mode = $Mode
                classification = $classification
                fixture_count = $Count
                import_bytes = $importBytes
                partial_original_count = $partialCounts.original
                partial_renamed_count = $partialCounts.renamed
                initial_state_sha256 = Get-AcceptanceStateDigest -State $initial
                partial_state_sha256 = Get-AcceptanceStateDigest -State $partial
                restored_state_sha256 = Get-AcceptanceStateDigest -State $restored
                raw_states = [ordered]@{
                    initial = $initialReference
                    crash_partial = $partialReference
                    startup_before_default_cancel = $startupReference
                    default_cancel = $cancelReference
                    relaunch = $relaunchReference
                    after_export = $afterExportStateReference
                    export_relaunch = $exportRelaunchStateReference
                    restored = $restoredReference
                }
                journal = [ordered]@{
                    bytes = $inspection.total_bytes
                    sha256 = Get-AcceptanceBootstrapBytesSha256 -Bytes $journalBytes
                    complete_frames = $inspection.complete_frames
                    last_kind = $inspection.last_kind
                    terminal = $inspection.terminal
                    tail = $inspection.tail
                    interrupted = $interruptedJournalReference
                    after_default_cancel = $afterCancelJournalReference
                    after_export = $afterExportJournalReference
                }
                journal_inventories = [ordered]@{
                    crash_stop = $crashJournalInventory
                    after_default_cancel = $afterCancelInventory
                    after_export = $afterExportInventory
                    final_recovered = $finalJournalInventory
                }
                actions = [ordered]@{
                    default_cancel = $defaultCancelAction
                }
                startup_before_confirmation_unchanged = $true
                default_cancel_unchanged = $true
                relaunch_preserved = $true
                processes = $processes.ToArray()
                foreground_observations = $foregroundReference
                recovery_screenshot = $recoveryScreenshot
                normal_exit_code = $recoveryExitCode
            }
            recovery_export = $recoveryExportResult
            intent_only_candidate_discard = $intentDiscardResult
        }
    }
    catch {
        $sessionError = $_
        try {
            $diagnosticApplication = Select-AcceptanceUiDiagnosticApplication `
                -Applications $applications.ToArray()
            $uiDiagnostic = Get-AcceptanceUiDiagnostic -Application $diagnosticApplication
            Write-AcceptanceNewUtf8Json `
                -Path (Join-Path $PrivateRoot 'session-ui-diagnostic.json') -Value $uiDiagnostic
        }
        catch {
        }
        throw $sessionError
    }
    finally {
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        foreach ($application in $applications) {
            try {
                $process = $application.owned.process
                $process.Refresh()
                if (-not $process.HasExited) {
                    $process.Kill()
                    if (-not $process.WaitForExit(10000)) {
                        throw 'The exact acceptance process did not terminate during cleanup.'
                    }
                }
                $bindingProperty = $application.PSObject.Properties['raw_process_binding']
                $exitProperty = $application.PSObject.Properties['raw_process_exit_recorded']
                if ($null -ne $bindingProperty -and $null -ne $exitProperty -and
                    -not [bool]$exitProperty.Value) {
                    $processes.Add((Write-AcceptanceProcessExitEvidence `
                        -Application $application -PrivateRoot $PrivateRoot `
                        -Boundary 'failure-cleanup' -ExitMethod 'forced-termination'))
                }
                $process.Dispose()
            }
            catch {
                $cleanupErrors.Add($_.Exception.Message)
            }
        }
        if ($cleanupErrors.Count -gt 0) {
            $cleanupMessage = [string]::Join(' | ', $cleanupErrors)
            if ($null -ne $sessionError) {
                throw "Acceptance session and exact-process cleanup both failed: $($sessionError.Exception.Message) Cleanup: $cleanupMessage"
            }
            throw "Acceptance exact-process cleanup failed: $cleanupMessage"
        }
    }
}
