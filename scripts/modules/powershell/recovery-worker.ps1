function Assert-AcceptanceRetainedWindowBinding {
    param(
        [Parameter(Mandatory)][object] $Window,
        [Parameter(Mandatory)][object] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $ExpectedName,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-AutomationBinding `
        -Element $Window `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label $Label `
        -RequireWindowHandle
    if ($Window.Current.Name -cne $ExpectedName -or
        $Window.Current.ControlType.ProgrammaticName -cne 'ControlType.Window') {
        throw "$Label name or control type changed after its exact lookup."
    }
}
function Dismiss-AcceptanceMessage {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Purpose,
        [Windows.Automation.AutomationElement] $Window
    )

    Add-Type -AssemblyName System.Windows.Forms
    if ($null -eq $Window) {
        $Window = Wait-AcceptanceRecoveryWindow `
            -Application $Application `
            -ExpectedSession $SessionId `
            -Name $Name `
            -TimeoutSeconds $WaitSeconds `
            -Label $Label `
            -PrivateRoot $PrivateRoot `
            -Purpose $Purpose
    }
    Assert-AcceptanceRetainedWindowBinding `
        -Window $Window `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -ExpectedName $Name `
        -Label $Label
    $handle = [IntPtr]$window.Current.NativeWindowHandle
    $window.SetFocus()
    $deadline = (Get-Date).AddSeconds([Math]::Min(5, $WaitSeconds))
    do {
        [void][DarkReNamerVmNative]::SetForegroundWindow($handle)
        if ([DarkReNamerVmNative]::GetForegroundWindow() -eq $handle) {
            break
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
        throw "$Label did not become the exact foreground window before the bounded deadline."
    }
    [Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label $Label
}
function Invoke-AcceptanceImportAndPrefix {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $PathsFile,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    Add-Type -AssemblyName System.Windows.Forms
    $process = $Application.owned.process
    $main = $Application.main
    $main.SetFocus()
    [void][DarkReNamerVmNative]::SetForegroundWindow([IntPtr]$main.Current.NativeWindowHandle)
    $foregroundDeadline = (Get-Date).AddSeconds(5)
    while ([DarkReNamerVmNative]::GetForegroundWindow() -ne
        [IntPtr]$main.Current.NativeWindowHandle -and (Get-Date) -lt $foregroundDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne [IntPtr]$main.Current.NativeWindowHandle) {
        throw 'The verified application is not foreground for Ctrl+Shift+V.'
    }
    [Windows.Forms.SendKeys]::SendWait('^+v')
    $dialog = Wait-UniqueAutomationWindow `
        -Process $process `
        -ExpectedSession $SessionId `
        -MainWindowHandle $Application.main_handle `
        -Name '파일에서 경로목록 읽어 추가하기' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'path-list import dialog'
    $dialogHandle = [IntPtr]$dialog.Current.NativeWindowHandle
    $edit = Find-UniqueAutomationElement `
        -Root $dialog `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId '1148' `
        -ControlType ([Windows.Automation.ControlType]::Edit) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'path-list import filename' `
        -RequireWindowHandle
    Set-AutomationControlValue -Element $edit -Value $PathsFile -Label 'path-list import filename'
    $open = Find-UniqueAutomationElement `
        -Root $dialog `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId '1' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'path-list import open button' `
        -RequireEnabled `
        -RequireWindowHandle
    Invoke-AutomationControl -Element $open -Label 'path-list import open button'
    Wait-WindowClosed -Handle $dialogHandle -TimeoutSeconds $WaitSeconds -Label 'path-list import dialog'

    $prefixCommand = Find-UniqueAutomationElement `
        -Root $main `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId '32773' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'prefix command after path import' `
        -RequireEnabled `
        -RequireWindowHandle
    $prefixInvocation = Start-AutomationControlInvoke -Element $prefixCommand -Label 'prefix command'
    $prompt = Wait-UniqueAutomationWindow `
        -Process $process `
        -ExpectedSession $SessionId `
        -Owner $Application.main `
        -Name '이름 앞에 문자열 붙이기' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'prefix prompt'
    $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
    $prefixEdit = Find-UniqueAutomationElement `
        -Root $prompt `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId '1004' `
        -ControlType ([Windows.Automation.ControlType]::Edit) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'prefix prompt edit' `
        -RequireWindowHandle
    Set-AutomationControlValue -Element $prefixEdit -Value $Prefix -Label 'prefix prompt edit'
    $ok = Find-UniqueAutomationElement `
        -Root $prompt `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId '1' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'prefix prompt confirmation' `
        -RequireEnabled `
        -RequireWindowHandle
    Invoke-AutomationControl -Element $ok -Label 'prefix prompt confirmation'
    Wait-WindowClosed -Handle $promptHandle -TimeoutSeconds $WaitSeconds -Label 'prefix prompt'
    Complete-AutomationControlInvoke -State $prefixInvocation -TimeoutSeconds $WaitSeconds
}
function Invoke-AcceptanceApply {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $process = $Application.owned.process
    $apply = Find-UniqueAutomationElement `
        -Root $Application.main `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId '32771' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'apply command after prefix' `
        -RequireEnabled `
        -RequireWindowHandle
    $applyInvocation = Start-AutomationControlInvoke -Element $apply -Label 'apply command'
    $confirmation = Wait-UniqueAutomationWindow `
        -Process $process `
        -ExpectedSession $SessionId `
        -Owner $Application.main `
        -Name 'DarkReNamer - 안전한 적용 확인' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'apply confirmation'
    $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
    $confirm = Find-UniqueAutomationElement `
        -Root $confirmation `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId 'CommandLink_1101' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'exact apply confirmation' `
        -RequireEnabled `
        -RequireWindowHandle
    Invoke-AutomationControl -Element $confirm -Label 'exact apply confirmation'
    Wait-WindowClosed -Handle $confirmationHandle -TimeoutSeconds $WaitSeconds -Label 'apply confirmation'
    Complete-AutomationControlInvoke -State $applyInvocation -TimeoutSeconds $WaitSeconds
}
function Stop-AcceptanceOwnedProcess {
    param([Parameter(Mandatory)][object] $Application)

    $process = $Application.owned.process
    $process.Refresh()
    if ($process.HasExited) {
        throw 'The application exited before the observer stopped it.'
    }
    $process.Kill()
    if (-not $process.WaitForExit(10000)) {
        throw 'The exact owned application process did not terminate.'
    }
}
function Get-AcceptanceActiveWorkerBoundary {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Cancel,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][string] $LocalAppData,
        [Parameter(Mandatory)][object] $InitialFirst,
        [Parameter(Mandatory)][object] $InitialLast,
        [Parameter(Mandatory)][int] $ExpectedCount,
        [Parameter(Mandatory)][int] $SessionId
    )

    $process = $Application.owned.process
    Assert-AutomationBinding `
        -Element $Cancel `
        -Process $process `
        -ExpectedSession $SessionId `
        -Label 'active worker cancellation control' `
        -RequireWindowHandle
    if ($Cancel.Current.AutomationId -cne '1009' -or
        $Cancel.Current.ControlType -ne [Windows.Automation.ControlType]::Button -or
        $Cancel.Current.Name -cne '취소') {
        throw 'The cached worker cancellation control changed identity or text.'
    }
    $cancelVisible = -not $Cancel.Current.IsOffscreen
    $firstOriginalName = 'item-00000.txt'
    $firstRenamedName = $Prefix + $firstOriginalName
    $lastOriginalName = 'item-{0:D5}.txt' -f ($ExpectedCount - 1)
    $firstRenamedPath = Join-Path $FixtureRoot $firstRenamedName
    $lastOriginalPath = Join-Path $FixtureRoot $lastOriginalName
    $firstDestinationObserved = Test-Path -LiteralPath $firstRenamedPath -PathType Leaf
    $lastOriginalObserved = Test-Path -LiteralPath $lastOriginalPath -PathType Leaf
    if (-not $firstDestinationObserved -or -not $lastOriginalObserved) {
        throw 'The worker boundary does not expose the required first-destination and last-original witnesses.'
    }
    if ($InitialFirst.name -cne $firstOriginalName -or
        $InitialLast.name -cne $lastOriginalName) {
        throw 'The initial state does not contain unique worker boundary witnesses.'
    }
    $firstItem = Get-Item -LiteralPath $firstRenamedPath -Force
    $lastItem = Get-Item -LiteralPath $lastOriginalPath -Force
    if (($firstItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($lastItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'A worker boundary witness became a reparse point.'
    }
    $firstIdentity = Get-FullFileIdentity -Path $firstItem.FullName
    $firstContent = Get-LowerSha256 -Path $firstItem.FullName
    $firstObservedTicks = [DateTime]::UtcNow.Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $lastIdentity = Get-FullFileIdentity -Path $lastItem.FullName
    $lastContent = Get-LowerSha256 -Path $lastItem.FullName
    $lastObservedTicks = [DateTime]::UtcNow.Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    if (-not (Test-AcceptanceIdentityEqual `
            -Expected $InitialFirst.file_identity -Actual $firstIdentity) -or
        -not (Test-AcceptanceIdentityEqual `
            -Expected $InitialLast.file_identity -Actual $lastIdentity) -or
        $firstContent -cne $InitialFirst.content_sha256 -or
        $lastContent -cne $InitialLast.content_sha256) {
        throw 'A worker boundary witness changed content or NTFS identity.'
    }
    $witnessesRechecked =
        (Test-Path -LiteralPath $firstRenamedPath -PathType Leaf) -and
        (Test-Path -LiteralPath $lastOriginalPath -PathType Leaf)
    $journalRoot = Join-Path (Join-Path $LocalAppData 'DarkReNamer') 'journal'
    $activeExists = Test-Path -LiteralPath (Join-Path $journalRoot 'active.drj') -PathType Leaf
    $candidateExists = Test-Path -LiteralPath (Join-Path $journalRoot 'candidate.drj') -PathType Leaf
    $classification = Get-AcceptanceWorkerBoundaryClassification `
        -FirstDestinationObserved $firstDestinationObserved `
        -LastOriginalObserved $lastOriginalObserved `
        -WitnessesRechecked $witnessesRechecked `
        -ActiveJournalExists $activeExists `
        -CandidateJournalExists $candidateExists `
        -CancelEnabled $Cancel.Current.IsEnabled `
        -CancelVisible $cancelVisible
    [pscustomobject]@{
        classification = $classification
        observed_partial_rename = $true
        witness_count = 2
        first_destination_name_sha256 = Get-LowerTextSha256 -Value $firstRenamedName
        last_original_name_sha256 = Get-LowerTextSha256 -Value $lastOriginalName
        first_destination_content_sha256 = $firstContent
        last_original_content_sha256 = $lastContent
        first_destination_identity_sha256 = Get-LowerTextSha256 `
            -Value (Get-AcceptanceIdentityKey -Identity $firstIdentity)
        last_original_identity_sha256 = Get-LowerTextSha256 `
            -Value (Get-AcceptanceIdentityKey -Identity $lastIdentity)
        partial_witness = [ordered]@{
            candidate_pid = [int]$process.Id
            candidate_session_id = [int]$process.SessionId
            entries = @(
                [ordered]@{
                    role = 'first-destination'
                    name = $firstItem.Name
                    kind = 'file'
                    bytes = [int64]$firstItem.Length
                    content_sha256 = $firstContent
                    file_identity = $firstIdentity
                    observed_utc_ticks = $firstObservedTicks
                },
                [ordered]@{
                    role = 'last-original'
                    name = $lastItem.Name
                    kind = 'file'
                    bytes = [int64]$lastItem.Length
                    content_sha256 = $lastContent
                    file_identity = $lastIdentity
                    observed_utc_ticks = $lastObservedTicks
                }
            )
        }
        cancel = $Cancel
    }
}
function Wait-AcceptanceWorkerRollback {
    param(
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $LocalAppData,
        [Parameter(Mandatory)][object[]] $Initial,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        try {
            Assert-NoJournalResidue -LocalAppData $LocalAppData
            break
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    } while ((Get-Date) -lt $deadline)
    Assert-NoJournalResidue -LocalAppData $LocalAppData
    $state = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
    Assert-AcceptanceStatesEqual -Expected $Initial -Actual $state -Label 'Worker rollback fixture'
    $state
}
function Close-AcceptanceApplicationNormally {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $process = $Application.owned.process
    $process.Refresh()
    if ($process.HasExited) {
        throw 'The acceptance application rejected ordinary window close.'
    }
    Close-ExactApplicationMainWindow `
        -Process $process `
        -ExpectedSession $Application.session_id `
        -MainWindowHandle $Application.main_handle `
        -MainWindow $Application.main `
        -ExpectedClassName 'DarkReNamerWindow' `
        -ExpectedTitle 'DarkReNamer' `
        -Label 'recovery ordinary window close'
    $waitMilliseconds = [int]([Math]::Min([int]::MaxValue, [int64]$WaitSeconds * 1000L))
    if (-not $process.WaitForExit($waitMilliseconds)) {
        throw 'The acceptance application did not close before the bounded deadline.'
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw 'The acceptance application returned a nonzero exit code.'
    }
    $process.ExitCode
}
function Invoke-AcceptanceRecovery {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[object]] $ForegroundObservations,
        [Windows.Automation.AutomationElement] $Prompt
    )

    $process = $Application.owned.process
    if ($null -eq $Prompt) {
        $Prompt = Wait-AcceptanceRecoveryWindow `
            -Application $Application `
            -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 이전 변경 복구 확인' `
            -TimeoutSeconds $WaitSeconds `
            -Label 'startup recovery confirmation' `
            -PrivateRoot $PrivateRoot `
            -Purpose 'startup-recovery-invoke'
    }
    Assert-AcceptanceRetainedWindowBinding `
        -Window $Prompt `
        -Process $process `
        -ExpectedSession $SessionId `
        -ExpectedName 'DarkReNamer - 이전 변경 복구 확인' `
        -Label 'startup recovery confirmation'
    $screenshot = Save-WindowScreenshot `
        -Window $prompt `
        -Process $process `
        -ExpectedSession $SessionId `
        -Root $EvidenceRoot `
        -Leaf 'startup-recovery-confirmation.png' `
        -Label 'startup recovery confirmation' `
        -ForegroundObservations $ForegroundObservations
    $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
    $confirm = Find-UniqueAutomationElement `
        -Root $prompt `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId 'CommandLink_1202' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'exact recovery confirmation' `
        -RequireEnabled `
        -RequireWindowHandle
    $invoke = Start-AutomationControlInvoke -Element $confirm -Label 'exact recovery confirmation'
    Wait-WindowClosed -Handle $promptHandle -TimeoutSeconds $WaitSeconds -Label 'startup recovery confirmation'
    Dismiss-AcceptanceMessage `
        -Application $Application `
        -SessionId $SessionId `
        -WaitSeconds $WaitSeconds `
        -Name 'DarkReNamer - 복구 완료' `
        -Label 'recovery completion message' `
        -PrivateRoot $PrivateRoot `
        -Purpose 'recovery-completion'
    Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $WaitSeconds
    $screenshot
}
function Dismiss-AcceptanceStartupRecovery {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [string] $PrivateRoot,
        [Windows.Automation.AutomationElement] $Prompt
    )

    $process = $Application.owned.process
    if ($null -eq $Prompt) {
        if ([string]::IsNullOrEmpty($PrivateRoot)) {
            throw 'Startup recovery cancellation discovery requires private evidence.'
        }
        $Prompt = Wait-AcceptanceRecoveryWindow `
            -Application $Application `
            -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 이전 변경 복구 확인' `
            -TimeoutSeconds $WaitSeconds `
            -Label 'startup recovery cancellation prompt' `
            -PrivateRoot $PrivateRoot `
            -Purpose 'startup-recovery-cancel'
    }
    Assert-AutomationBinding -Element $Prompt -Process $process -ExpectedSession $SessionId `
        -Label 'startup recovery cancellation prompt' -RequireWindowHandle
    if ($Prompt.Current.Name -cne 'DarkReNamer - 이전 변경 복구 확인') {
        throw 'The retained startup cancellation prompt has a different name.'
    }
    $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
    $cancel = Find-UniqueAutomationElement `
        -Root $prompt `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId 'CommandButton_2' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'startup recovery cancellation button' `
        -RequireEnabled `
        -RequireWindowHandle
    $target = $null
    $observedUtcTicks = $null
    if (-not [string]::IsNullOrEmpty($PrivateRoot)) {
        $target = Get-AcceptanceControlTargetObservation `
            -Application $Application -Root $prompt -Element $cancel `
            -SessionId $SessionId -ExpectedAutomationId 'CommandButton_2' `
            -ExpectedControlId 2 -Label 'startup recovery cancellation button'
        if (-not $target.enabled -or -not $target.visible -or -not $target.focused) {
            throw 'The startup recovery cancellation target is not the enabled, visible default focus.'
        }
        $observedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    Invoke-AutomationControl -Element $cancel -Label 'startup recovery cancellation button'
    Wait-WindowClosed `
        -Handle $promptHandle `
        -TimeoutSeconds $WaitSeconds `
        -Label 'startup recovery cancellation prompt'
    if ($null -ne $target) {
        $completedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )
        Write-AcceptanceActionEvidence `
            -PrivateRoot $PrivateRoot -Leaf 'startup-default-cancel-action' `
            -Boundary 'startup-default-cancel-action' -Phase 'startup-default-cancel' `
            -Action 'cancel-startup-recovery' -Target $target `
            -ObservedUtcTicks $observedUtcTicks -CompletedUtcTicks $completedUtcTicks
    }
}
function Invoke-AcceptanceRecoveryExport {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][byte[]] $ExpectedBytes,
        [Parameter(Mandatory)][object] $SourceActiveJournalReference,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $exportRoot = New-PrivateDirectory -Parent $PrivateRoot -Leaf 'recovery-export'
    $menuAction = Start-AcceptanceRecoveryMenuInvoke `
        -Application $Application `
        -SessionId $SessionId `
        -WaitSeconds $WaitSeconds `
        -ItemName '복구 데이터 내보내기...' `
        -Label 'recovery export menu item' `
        -PrivateRoot $PrivateRoot `
        -Purpose 'export'
    if ($menuAction.target_command_id -ne 0x9000 -or
        -not $menuAction.enter_sent -or -not $menuAction.popup_closed) {
        throw 'Recovery export menu action did not bind the exact native command.'
    }
    $dialog = Wait-AcceptanceRecoveryWindow `
        -Application $Application `
        -ExpectedSession $SessionId `
        -Name '복구 저널 원본을 저장할 폴더 선택' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'recovery export folder picker' `
        -PrivateRoot $PrivateRoot `
        -Purpose 'recovery-export-folder-picker'
    Write-AcceptanceExportProgress -PrivateRoot $PrivateRoot -Application $Application -Phase 'picker-found'
    $dialogHandle = [IntPtr]$dialog.Current.NativeWindowHandle
    $folder = Find-UniqueAutomationElement `
        -Root $dialog `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -AutomationId '1152' `
        -ControlType ([Windows.Automation.ControlType]::Edit) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'recovery export folder path' `
        -RequireWindowHandle
    Set-AutomationControlValue `
        -Element $folder `
        -Value $exportRoot `
        -Label 'recovery export folder path'
    Write-AcceptanceExportProgress -PrivateRoot $PrivateRoot -Application $Application -Phase 'picker-filled'
    $select = Find-UniqueAutomationElement `
        -Root $dialog `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -AutomationId '1' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'recovery export folder confirmation' `
        -RequireEnabled `
        -RequireWindowHandle
    Invoke-AutomationControl -Element $select -Label 'recovery export folder confirmation'
    Wait-WindowClosed `
        -Handle $dialogHandle `
        -TimeoutSeconds $WaitSeconds `
        -Label 'recovery export folder picker'
    Dismiss-AcceptanceMessage `
        -Application $Application `
        -SessionId $SessionId `
        -WaitSeconds $WaitSeconds `
        -Name 'DarkReNamer - 진단 내보내기 완료' `
        -Label 'recovery export completion message' `
        -PrivateRoot $PrivateRoot `
        -Purpose 'recovery-export-completion'
    $exportItem = Get-AcceptanceRecoveryExportFile -Root $exportRoot
    $leaves = @($exportItem.Name)
    $exportPath = $exportItem.FullName
    $exportedBytes = [IO.File]::ReadAllBytes($exportPath)
    $classification = Get-AcceptanceRecoveryExportClassification `
        -ExpectedBytes $ExpectedBytes `
        -ExportedBytes $exportedBytes `
        -ExportedLeaves $leaves
    Remove-AcceptanceExportProgress -PrivateRoot $PrivateRoot
    [pscustomobject]@{
        status = 'passed'
        classification = $classification
        bytes = $exportedBytes.Length
        sha256 = Get-LowerSha256 -Path $exportPath
        captured_active_sha256 = Get-AcceptanceBootstrapBytesSha256 -Bytes $ExpectedBytes
        exact_bytes = $true
        source_active_journal = $SourceActiveJournalReference
        raw = New-AcceptancePrivateReference `
            -Path $exportPath `
            -PrivateRoot $PrivateRoot `
            -Boundary 'recovery-export'
    }
}
