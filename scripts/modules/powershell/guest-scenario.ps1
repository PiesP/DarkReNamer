function Initialize-ProductionRenameFlowFixture {
    param(
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $ApplicationRoot,
        [Parameter(Mandatory)][string] $LocalAppData,
        [switch] $RawEvidence
    )

    $sourcePath = Join-Path $FixtureRoot 'vm-flow-source.txt'
    $fixtureBytes = [Text.UTF8Encoding]::new($false).GetBytes(
        "DarkReNamer production VM flow`nidentity and content must survive`n"
    )
    [IO.File]::WriteAllBytes($sourcePath, $fixtureBytes)
    $beforeFileIdentity = [DarkReNamerVmNative]::GetFileIdentity($sourcePath)
    [pscustomobject]@{
        application_sha256 = Get-LowerSha256 -Path (Join-Path $ApplicationRoot 'DarkReNamer.exe')
        before_content_sha256 = Get-LowerSha256 -Path $sourcePath
        before_file_identity = $beforeFileIdentity
        checkpoints = @((Get-FlowCheckpoint `
            -Phase initial `
            -FixtureRoot $FixtureRoot `
            -LocalAppData $LocalAppData))
        raw_checkpoints = @(
            if ($RawEvidence) {
                Get-VmAutomatedCheckpoint `
                    -Phase initial `
                    -FixtureRoot $FixtureRoot `
                    -LocalAppData $LocalAppData
            }
        )
    }
}

function Invoke-ProductionRenameFlow {
    param(
        [Parameter(Mandatory)][object] $OwnedProcess,
        [Parameter(Mandatory)][object] $InitialFixture,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [switch] $RawEvidence
    )

    $Process = $OwnedProcess.process
    $sourceName = 'vm-flow-source.txt'
    $prefix = 'vm-confirmed-'
    $previewName = $prefix + $sourceName
    $sourcePath = Join-Path $FixtureRoot $sourceName
    $destinationPath = Join-Path $FixtureRoot $previewName
    $pendingInvocations = [Collections.Generic.List[object]]::new()
    $foregroundObservations = [Collections.Generic.List[object]]::new()
    $flow = [ordered]@{
        status = 'failed'
        scope = 'production-file-add-prefix-cancel-confirm'
        input_mode = 'uia-functional'
        application_file = 'DarkReNamer.exe'
        application_sha256 = $null
        source_name = $sourceName
        preview_name = $previewName
        before_content_sha256 = $null
        after_content_sha256 = $null
        before_file_identity_sha256 = $null
        after_file_identity_sha256 = $null
        cancellation_source_present = $null
        cancellation_destination_present = $null
        confirmed_source_present = $null
        confirmed_destination_present = $null
        journal_residue_count = $null
        checkpoints = @()
        foreground_observations = $foregroundObservations
        screenshots = @()
        diagnostic = $null
        failure_reason = 'fixture_setup_failed'
    }
    try {
        $flow.application_sha256 = $InitialFixture.application_sha256
        $flow.before_content_sha256 = $InitialFixture.before_content_sha256
        $beforeFileIdentity = [string]$InitialFixture.before_file_identity
        $flow.before_file_identity_sha256 = Get-LowerTextSha256 -Value $beforeFileIdentity
        # Keep prelaunch evidence, but compare Cancel with the actual running application state.
        $flow['prelaunch_checkpoints'] = @($InitialFixture.checkpoints)
        $flow.checkpoints = @((Get-FlowCheckpoint `
            -Phase initial `
            -FixtureRoot $FixtureRoot `
            -LocalAppData $env:LOCALAPPDATA))
        if ($RawEvidence) {
            $flow['raw_prelaunch_checkpoints'] = @($InitialFixture.raw_checkpoints)
            $flow['raw_environment'] = Get-VmAutomatedEnvironment `
                -Process $Process `
                -WindowHandle ([IntPtr]$MainWindow.Current.NativeWindowHandle) `
                -FixtureRoot $FixtureRoot
            $flow['raw_checkpoints'] = @((Get-VmAutomatedCheckpoint `
                -Phase initial `
                -FixtureRoot $FixtureRoot `
                -LocalAppData $env:LOCALAPPDATA))
        }
        $flow.failure_reason = 'startup_fixture_changed'
        Assert-ProductionRenameFlowStartupCheckpoint `
            -Prelaunch $InitialFixture.checkpoints[0] `
            -Startup $flow.checkpoints[0]
        if ($RawEvidence) {
            Assert-ProductionRenameFlowStartupCheckpoint `
                -Prelaunch $InitialFixture.raw_checkpoints[0] `
                -Startup $flow.raw_checkpoints[0]
        }

        $flow.failure_reason = 'file_add_failed'
        $add = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8017) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'file-add command' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -OwnedProcess $OwnedProcess -Element $add -Label 'file-add command'
        $pendingInvocations.Add($invoke)

        $fileDialog = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -MainWindowHandle $MainWindowHandle `
            -Name '이름 붙일 파일 불러오기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'production file dialog'
        $fileDialogHandle = [IntPtr]$fileDialog.Current.NativeWindowHandle
        $fileName = Find-UniqueAutomationElement `
            -Root $fileDialog `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1148' `
            -ControlType ([Windows.Automation.ControlType]::Edit) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'file dialog filename control'
        Set-AutomationControlValue `
            -Element $fileName `
            -Value $sourcePath `
            -Label 'file dialog filename control'
        $open = Find-UniqueAutomationElement `
            -Root $fileDialog `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'file dialog open button' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $open -Label 'file dialog open button'
        Wait-WindowClosed -Handle $fileDialogHandle -TimeoutSeconds $TimeoutSeconds -Label 'production file dialog'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        Wait-ListPreviewName `
            -MainWindow $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -ExpectedName $sourceName `
            -TimeoutSeconds $TimeoutSeconds

        $flow.failure_reason = 'prefix_prompt_failed'
        $prefixCommand = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8005) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix command' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -OwnedProcess $OwnedProcess -Element $prefixCommand -Label 'prefix command'
        $pendingInvocations.Add($invoke)
        $prompt = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -MainWindowHandle $MainWindowHandle `
            -Name '이름 앞에 문자열 붙이기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt'
        $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
        $prefixEdit = Find-UniqueAutomationElement `
            -Root $prompt `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1004' `
            -ControlType ([Windows.Automation.ControlType]::Edit) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt edit' `
            -RequireWindowHandle
        Set-AutomationControlValue -Element $prefixEdit -Value $prefix -Label 'prefix prompt edit'
        $promptOk = Find-UniqueAutomationElement `
            -Root $prompt `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt confirmation' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $promptOk -Label 'prefix prompt confirmation'
        Wait-WindowClosed -Handle $promptHandle -TimeoutSeconds $TimeoutSeconds -Label 'prefix prompt'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        Wait-ListPreviewName `
            -MainWindow $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -ExpectedName $previewName `
            -TimeoutSeconds $TimeoutSeconds
        $flow.failure_reason = 'preview_verification_failed'
        $screenshots = [Collections.Generic.List[object]]::new()
        $screenshots.Add((Save-WindowScreenshot `
            -Window $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Root $OutputRoot `
            -Leaf 'rename-preview.png' `
            -Label 'production rename preview' `
            -ForegroundObservations $foregroundObservations))
        $flow.screenshots = $screenshots.ToArray()

        $flow.failure_reason = 'apply_cancellation_failed'
        $apply = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8003) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply command' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -OwnedProcess $OwnedProcess -Element $apply -Label 'apply command'
        $pendingInvocations.Add($invoke)
        $confirmation = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -MainWindowHandle $MainWindowHandle `
            -Name 'DarkReNamer - 안전한 적용 확인' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply confirmation task dialog'
        $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
        $screenshots.Add((Save-WindowScreenshot `
            -Window $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Root $OutputRoot `
            -Leaf 'apply-confirmation.png' `
            -Label 'apply confirmation task dialog' `
            -ForegroundObservations $foregroundObservations))
        $flow.screenshots = $screenshots.ToArray()
        $cancel = Find-UniqueAutomationElement `
            -Root $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId 'CommandButton_2' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply confirmation cancel button' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $cancel -Label 'apply confirmation cancel button'
        Wait-WindowClosed `
            -Handle $confirmationHandle `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'cancelled apply confirmation task dialog'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        $flow.cancellation_source_present = Test-Path -LiteralPath $sourcePath -PathType Leaf
        $flow.cancellation_destination_present = Test-Path -LiteralPath $destinationPath -PathType Leaf
        if (-not $flow.cancellation_source_present -or $flow.cancellation_destination_present -or
            (Get-LowerSha256 -Path $sourcePath) -cne $flow.before_content_sha256 -or
            [DarkReNamerVmNative]::GetFileIdentity($sourcePath) -cne $beforeFileIdentity) {
            throw 'Cancelling the production confirmation changed the fixture.'
        }
        $flow.checkpoints += (Get-FlowCheckpoint `
            -Phase after_cancel `
            -FixtureRoot $FixtureRoot `
            -LocalAppData $env:LOCALAPPDATA)
        if ($RawEvidence) {
            $flow.raw_checkpoints += (Get-VmAutomatedCheckpoint `
                -Phase after_cancel `
                -FixtureRoot $FixtureRoot `
                -LocalAppData $env:LOCALAPPDATA)
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA

        $flow.failure_reason = 'confirmed_apply_failed'
        $apply = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8003) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply command after cancellation' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -OwnedProcess $OwnedProcess `
            -Element $apply `
            -Label 'apply command after cancellation'
        $pendingInvocations.Add($invoke)
        $confirmation = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -MainWindowHandle $MainWindowHandle `
            -Name 'DarkReNamer - 안전한 적용 확인' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'second apply confirmation task dialog'
        $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
        $confirm = Find-UniqueAutomationElement `
            -Root $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId 'CommandLink_1101' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'exact destructive confirmation button' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $confirm -Label 'exact destructive confirmation button'
        Wait-WindowClosed `
            -Handle $confirmationHandle `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'confirmed apply task dialog'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds

        $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
        do {
            $sourcePresent = Test-Path -LiteralPath $sourcePath -PathType Leaf
            $destinationPresent = Test-Path -LiteralPath $destinationPath -PathType Leaf
            if (-not $sourcePresent -and $destinationPresent) {
                try {
                    Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
                    break
                }
                catch {
                }
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        $flow.checkpoints += (Get-FlowCheckpoint `
            -Phase after_apply `
            -FixtureRoot $FixtureRoot `
            -LocalAppData $env:LOCALAPPDATA)
        if ($RawEvidence) {
            $flow.raw_checkpoints += (Get-VmAutomatedCheckpoint `
                -Phase after_apply `
                -FixtureRoot $FixtureRoot `
                -LocalAppData $env:LOCALAPPDATA)
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $flow.confirmed_source_present = Test-Path -LiteralPath $sourcePath -PathType Leaf
        $flow.confirmed_destination_present = Test-Path -LiteralPath $destinationPath -PathType Leaf
        if ($flow.confirmed_source_present -or -not $flow.confirmed_destination_present) {
            throw 'The confirmed production apply did not perform the expected disk rename.'
        }
        $flow.after_content_sha256 = Get-LowerSha256 -Path $destinationPath
        $afterFileIdentity = [DarkReNamerVmNative]::GetFileIdentity($destinationPath)
        $flow.after_file_identity_sha256 = Get-LowerTextSha256 -Value $afterFileIdentity
        if ($flow.after_content_sha256 -cne $flow.before_content_sha256 -or
            $afterFileIdentity -cne $beforeFileIdentity) {
            throw 'The confirmed production rename did not preserve file contents and identity.'
        }
        $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
        $flow.journal_residue_count = if (Test-Path -LiteralPath $journalRoot) {
            @(
                Get-ChildItem -LiteralPath $journalRoot -Force |
                    Where-Object Name -cne 'runtime.lock'
            ).Count
        } else {
            0
        }
        $flow.screenshots = $screenshots.ToArray()
        $flow.status = 'passed'
        $flow.failure_reason = $null
    }
    catch {
        if ($flow.failure_reason -eq $null) {
            $flow.failure_reason = 'production_flow_error'
        }
        $diagnosticLeaf = 'gui-flow-error.txt'
        $diagnosticPath = Join-Path $OutputRoot $diagnosticLeaf
        $diagnosticText = $_ | Out-String -Width 4096
        foreach ($invocation in $pendingInvocations) {
            if ($invocation.completed) { continue }
            $diagnosticText += "`n$($invocation.label): completed=$($invocation.async_result.IsCompleted)`n"
            $diagnosticText += $invocation.powershell.Streams.Error | Out-String -Width 4096
        }
        [IO.File]::WriteAllText($diagnosticPath, $diagnosticText, [Text.UTF8Encoding]::new($true))
        $flow.diagnostic = [ordered]@{
            file = $diagnosticLeaf
            sha256 = Get-LowerSha256 -Path $diagnosticPath
        }
    }
    [pscustomobject]$flow
}
function Get-ForegroundObservation {
    $handle = [DarkReNamerVmNative]::GetForegroundWindow()
    $processId = [uint32]0
    $sessionId = $null
    $windowClass = ''
    if ($handle -ne [IntPtr]::Zero) {
        [void][DarkReNamerVmNative]::GetWindowThreadProcessId($handle, [ref]$processId)
        $classText = [Text.StringBuilder]::new(256)
        [void][DarkReNamerVmNative]::GetClassName($handle, $classText, $classText.Capacity)
        $windowClass = $classText.ToString()
        if ($processId -gt 0) {
            try {
                $foregroundProcess = Get-Process -Id $processId -ErrorAction Stop
                $sessionId = [int]$foregroundProcess.SessionId
                $foregroundProcess.Dispose()
            }
            catch {
                $sessionId = $null
            }
        }
    }
    [ordered]@{
        hwnd = [long]$handle
        process_id = [int]$processId
        session_id = $sessionId
        window_class = $windowClass
    }
}
function Set-GuiSmokeFailureDetail {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Row,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    $message = [string]$exception.Message
    if ($message.Length -gt 1024) {
        $message = $message.Substring(0, 1024)
    }
    $nativeError = if ($exception -is [ComponentModel.Win32Exception]) {
        [int]$exception.NativeErrorCode
    }
    else {
        $null
    }
    $detail = [ordered]@{
        exception_type = [string]$exception.GetType().FullName
        message = $message
        native_error = $nativeError
    }
    if ($null -eq $Row['error_detail']) {
        $Row['error_detail'] = $detail
    }
    else {
        if (-not $Row.Contains('additional_error_details')) { $Row['additional_error_details'] = @() }
        $Row['additional_error_details'] += $detail
    }
}
function Get-PickerModelSnapshot {
    param([Parameter(Mandatory)][Windows.Automation.GridPattern] $Grid)

    $rows = $Grid.Current.RowCount
    if ($rows -lt 0 -or $rows -gt 1) { throw 'Picker checks require at most one owned row.' }
    $snapshot = [ordered]@{ rows = $rows; cells = @() }
    if ($rows -eq 1) {
        if ($Grid.Current.ColumnCount -lt 3) { throw 'Picker checks require three primary columns.' }
        $snapshot.cells = @(0..2 | ForEach-Object { $Grid.GetItem(0, $_).Current.Name })
    }
    $snapshot
}

function Wait-FocusedPickerAddressEdit {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $DialogHandle,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][object] $EditControlType,
        [scriptblock] $ReadFocus = { [Windows.Automation.AutomationElement]::FocusedElement },
        [scriptblock] $ReadForeground = { [DarkReNamerVmNative]::GetForegroundWindow() },
        [scriptblock] $ReadRoot = {
            param($element, $processId)
            $ancestor = $element
            for ($depth = 0; $depth -lt 32 -and $null -ne $ancestor; $depth++) {
                if ($ancestor.Current.ProcessId -ne $processId) { break }
                $nativeHandle = [IntPtr]$ancestor.Current.NativeWindowHandle
                if ($nativeHandle -ne [IntPtr]::Zero) {
                    if ([DarkReNamerVmNative]::IsWindow($nativeHandle)) {
                        return [DarkReNamerVmNative]::GetAncestor($nativeHandle, [uint32]2)
                    }
                    break
                }
                $ancestor = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)
            }
            [IntPtr]::Zero
        }
    )

    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    $lastType = '<none>'
    $lastAutomationId = '<none>'
    do {
        $Process.Refresh()
        if ($Process.HasExited -or $Process.SessionId -ne $ExpectedSession) {
            throw 'Folder address focus left the expected process or desktop session.'
        }
        if ((& $ReadForeground) -ne $DialogHandle) {
            throw 'Folder picker lost foreground while waiting for its address Edit.'
        }
        $candidate = & $ReadFocus
        if ($null -ne $candidate) {
            $controlType = $candidate.Current.ControlType
            $lastType = if ($null -ne $controlType.PSObject.Properties['ProgrammaticName']) {
                [string]$controlType.ProgrammaticName
            } else { [string]$controlType }
            $lastAutomationId = [string]$candidate.Current.AutomationId
            if ($lastAutomationId.Length -gt 128) { $lastAutomationId = $lastAutomationId.Substring(0, 128) }
            if ($candidate.Current.ProcessId -eq $Process.Id -and
                $controlType -eq $EditControlType -and $lastAutomationId -cne '1148' -and
                (& $ReadRoot $candidate $Process.Id) -eq $DialogHandle) {
                return $candidate
            }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "Folder address shortcut did not focus its address Edit before the bounded deadline (type=$lastType, automation_id=$lastAutomationId)."
}

function Invoke-OwnedPickerAction {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][IntPtr] $MainHandle,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][uint16] $Command,
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][ValidateSet('cancel', 'file', 'folder')][string] $Action,
        [string] $Selection,
        [switch] $TextFilters,
        [switch] $UseDefaultExtension
    )

    Assert-ExactApplicationMainWindowBinding -Process $Process -ExpectedSession $Session `
        -MainWindowHandle $MainHandle -MainWindow $MainWindow `
        -ExpectedClassName 'DarkReNamerWindow' -ExpectedTitle 'DarkReNamer' -Label 'picker command owner'
    [DarkReNamerVmNative]::RequestMenuCommand($MainHandle, $Command)
    $dialog = Wait-UniqueAutomationWindow -Process $Process -ExpectedSession $Session `
        -MainWindowHandle $MainHandle -Name $Title -TimeoutSeconds $TimeoutSeconds -Label 'owned picker'
    $handle = [IntPtr]$dialog.Current.NativeWindowHandle
    $native = @([DarkReNamerVmNative]::ReadProcessTopLevelWindows([uint32]$Process.Id) | Where-Object {
        $_.Handle -eq $handle.ToInt64() -and $_.Owner -eq $MainHandle.ToInt64() -and
        $_.ClassName -ceq '#32770' -and $_.Title -ceq $Title -and $_.Visible
    })
    if ($native.Count -ne 1 -or [DarkReNamerVmNative]::IsWindowEnabled($MainHandle)) {
        throw 'Picker did not retain its exact disabled native owner.'
    }
    $filterNames = @()
    if ($TextFilters) {
        # Shell versions expose different control IDs. Bind the actual selected
        # filter through its UIA value/selection rather than a classic-dialog ID.
        $combos = $dialog.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::ControlTypeProperty,
                [Windows.Automation.ControlType]::ComboBox))
        if ($combos.Count -gt 8) { throw 'Picker ComboBox inventory exceeds its bound.' }
        $candidates = @()
        $comboObservations = @()
        foreach ($candidate in $combos) {
            Assert-AutomationBinding -Element $candidate -Process $Process -ExpectedSession $Session -Label 'picker ComboBox'
            $values = @($candidate.Current.Name)
            $pattern = $null
            if ($candidate.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
                $values += ([Windows.Automation.ValuePattern]$pattern).Current.Value
            }
            $pattern = $null
            if ($candidate.TryGetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern, [ref]$pattern)) {
                $values += @(([Windows.Automation.SelectionPattern]$pattern).Current.GetSelection() | ForEach-Object { $_.Current.Name })
            }
            $comboObservations += @{ id=$candidate.Current.AutomationId; values=$values }
            if ($values -ccontains 'Text Files (*.txt)' -or $values -ccontains 'Text Files') { $candidates += $candidate }
        }
        if ($candidates.Count -ne 1) {
            throw "Picker has no unique selected Text Files filter: $($comboObservations | ConvertTo-Json -Depth 4 -Compress)"
        }
        $combo = $candidates[0]
        $expand = [Windows.Automation.ExpandCollapsePattern]$combo.GetCurrentPattern(
            [Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expand.Expand()
        try {
            $items = $dialog.FindAll([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new(
                    [Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [Windows.Automation.ControlType]::ListItem))
            if ($items.Count -gt 512) { throw 'Picker ListItem inventory exceeds its bound.' }
            $filterNames = @($items | ForEach-Object { $_.Current.Name } | Where-Object {
                $_ -cin @('Text Files', 'Text Files (*.txt)', 'All Files', 'All Files (*.*)')
            })
            if ($filterNames.Count -ne 2) { throw 'Text picker did not expose both maintained filters.' }
            if ($filterNames[0] -cnotin @('Text Files', 'Text Files (*.txt)') -or
                $filterNames[1] -cnotin @('All Files', 'All Files (*.*)')) {
                throw "Text picker filters changed: $($filterNames -join ', ')."
            }
        }
        finally { $expand.Collapse() }
    }
    if ($Action -ceq 'cancel') {
        $cancel = Find-UniqueAutomationElement -Root $dialog -Process $Process -ExpectedSession $Session `
            -AutomationId '2' -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds -Label 'picker Cancel' -RequireEnabled -RequireWindowHandle
        Invoke-AutomationControl -Element $cancel -Label 'picker Cancel'
    }
    else {
        if ($Action -ceq 'folder' -or $UseDefaultExtension) {
            # Match the maintained destination-folder observer: navigate the
            # address first, then select that directory instead of merely
            # navigating on the first Select Folder invocation.
            Add-Type -AssemblyName System.Windows.Forms
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                throw 'Folder picker is not the bound foreground window.'
            }
            [Windows.Forms.SendKeys]::SendWait('^l')
            $edit = Wait-FocusedPickerAddressEdit -Process $Process -ExpectedSession $Session `
                -DialogHandle $handle -TimeoutSeconds $TimeoutSeconds `
                -EditControlType ([Windows.Automation.ControlType]::Edit)
            Assert-AutomationBinding -Element $edit -Process $Process -ExpectedSession $Session -Label 'folder address'
            $directory = if ($Action -ceq 'folder') { $Selection } else { [IO.Path]::GetDirectoryName($Selection) }
            Set-AutomationControlValue -Element $edit -Value $directory -Label 'folder address'
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                throw 'Folder picker lost foreground before address navigation.'
            }
            [Windows.Forms.SendKeys]::SendWait('{ENTER}')
            Start-Sleep -Milliseconds 300
        }
        if ($Action -ceq 'file') {
            $edit = Find-UniqueAutomationElement -Root $dialog -Process $Process -ExpectedSession $Session `
                -AutomationId '1148' -ControlType ([Windows.Automation.ControlType]::Edit) `
                -TimeoutSeconds $TimeoutSeconds -Label 'picker selection field'
            $filename = if ($UseDefaultExtension) { [IO.Path]::GetFileNameWithoutExtension($Selection) } else { $Selection }
            Set-AutomationControlValue -Element $edit -Value $filename -Label 'picker selection field'
        }
        $accept = Find-UniqueAutomationElement -Root $dialog -Process $Process -ExpectedSession $Session `
            -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds -Label 'picker acceptance' -RequireEnabled -RequireWindowHandle
        Invoke-AutomationControl -Element $accept -Label 'picker acceptance'
    }
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $TimeoutSeconds -Label "$Title ($Action)"
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $enabled = [DarkReNamerVmNative]::IsWindowEnabled($MainHandle)
        $foreground = [DarkReNamerVmNative]::GetForegroundWindow() -eq $MainHandle
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        $focusBound = $null -ne $focused -and $focused.Current.ProcessId -eq $Process.Id
        if ($enabled -and $foreground -and $focusBound) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if (-not ($enabled -and $foreground -and $focusBound)) {
        throw 'Picker did not restore its enabled owner, foreground, and process-bound focus.'
    }
    [ordered]@{
        command = [int]$Command; action = $Action; title = $Title
        process_id = $Process.Id; session_id = $Session
        dialog_handle = $handle.ToInt64(); owner_handle = $MainHandle.ToInt64()
        native_owner_disabled = $true; owner_enabled_after = $enabled
        foreground_restored = $foreground; focus_process_bound = $focusBound
        filters = $filterNames
    }
}

function Invoke-ProductionPickerChecks {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][IntPtr] $MainHandle,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Record
    )

    $root = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'picker-fixtures'
    $destination = New-PrivateDirectory -Parent $root -Leaf 'destination'
    $source = Join-Path $root '선택-😀.txt'
    $names = Join-Path $root '이름-😀.txt'
    $paths = Join-Path $root '경로-😀.txt'
    [IO.File]::WriteAllText($source, 'owned picker fixture', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($names, "변경-😀.txt`r`n", [Text.UnicodeEncoding]::new($false, $true))
    [IO.File]::WriteAllText($paths, "$source`r`n", [Text.UnicodeEncoding]::new($false, $true))
    $initialFiles = @($source, $names, $paths | ForEach-Object {
        [pscustomobject]@{ path = $_; sha256 = (Get-LowerSha256 -Path $_)
            identity = [DarkReNamerVmNative]::GetFileIdentity($_) }
    })
    $list = Find-UniqueAutomationElement -Root $MainWindow -Process $Process -ExpectedSession $Session `
        -AutomationId '1000' -TimeoutSeconds $TimeoutSeconds -Label 'picker model list' -RequireWindowHandle
    $grid = [Windows.Automation.GridPattern]$list.GetCurrentPattern([Windows.Automation.GridPattern]::Pattern)
    if ($grid.Current.RowCount -ne 0) { throw 'Picker checks require an initially empty model.' }
    $actions = [Collections.Generic.List[object]]::new()
    $Record['actions'] = $actions
    $specs = @(
        @{ command = 0x801D; title = '파일에서 경로목록 읽어 추가하기'; selection = $paths; folder = $false },
        @{ command = 0x801C; title = '바꿀 파일 이름 불러오기'; selection = $names; folder = $false },
        @{ command = 0x8013; title = '모든 파일을 이동할 대상 폴더 선택'; selection = $destination; folder = $true }
    )
    foreach ($spec in $specs) {
        $before = Get-PickerModelSnapshot -Grid $grid
        $Record['active_action'] = [ordered]@{ command=$spec.command; title=$spec.title; action='cancel' }
        $cancel = Invoke-OwnedPickerAction -Process $Process -MainWindow $MainWindow -MainHandle $MainHandle `
            -Session $Session -TimeoutSeconds $TimeoutSeconds -Command $spec.command -Title $spec.title `
            -Action cancel -TextFilters:(-not $spec.folder)
        $after = Get-PickerModelSnapshot -Grid $grid
        if (($after | ConvertTo-Json -Depth 4 -Compress) -cne
            ($before | ConvertTo-Json -Depth 4 -Compress)) { throw 'Cancel changed the picker model snapshot.' }
        $cancel['model_unchanged'] = $true
        $cancel['model_before'] = $before
        $cancel['model_after'] = $after
        $actions.Add($cancel)
        $Record['active_action'] = [ordered]@{ command=$spec.command; title=$spec.title; action='accept' }
        $accept = Invoke-OwnedPickerAction -Process $Process -MainWindow $MainWindow -MainHandle $MainHandle `
            -Session $Session -TimeoutSeconds $TimeoutSeconds -Command $spec.command -Title $spec.title `
            -Action $(if ($spec.folder) { 'folder' } else { 'file' }) -Selection $spec.selection `
            -TextFilters:(-not $spec.folder) -UseDefaultExtension:($spec.command -eq 0x801C)
        $expected = @('선택-😀.txt', $(if ($spec.command -eq 0x801D) { '선택-😀.txt' } else { '변경-😀.txt' }),
            $(if ($spec.folder) { $destination } else { $root }))
        $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
        do {
            $snapshot = Get-PickerModelSnapshot -Grid $grid
            if ($snapshot.rows -eq 1 -and ($snapshot.cells | ConvertTo-Json -Compress) -ceq
                ($expected | ConvertTo-Json -Compress)) { break }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        if ($snapshot.rows -ne 1 -or ($snapshot.cells | ConvertTo-Json -Compress) -cne
            ($expected | ConvertTo-Json -Compress)) { throw 'Picker did not apply the expected exact model result.' }
        $accept['expected_model_observed'] = $true
        $accept['default_extension_exercised'] = $spec.command -eq 0x801C
        $accept['expected_model'] = [ordered]@{ rows = 1; cells = $expected }
        $accept['observed_model'] = $snapshot
        $actions.Add($accept)
    }
    foreach ($file in $initialFiles) {
        if ((Get-LowerSha256 -Path $file.path) -cne $file.sha256 -or
            [DarkReNamerVmNative]::GetFileIdentity($file.path) -cne $file.identity) {
            throw 'Picker selection changed owned source or import-input bytes/identity.'
        }
    }
    if (@(Get-ChildItem -LiteralPath $destination -Force).Count -ne 0 -or
        @(Get-ChildItem -LiteralPath $root -Force).Count -ne 4) {
        throw 'Picker selection mutated the fixture filesystem.'
    }
    Assert-ExactApplicationMainWindowBinding -Process $Process -ExpectedSession $Session `
        -MainWindowHandle $MainHandle -MainWindow $MainWindow `
        -ExpectedClassName 'DarkReNamerWindow' -ExpectedTitle 'DarkReNamer' -Label 'picker model reset owner'
    # CLEAR_LIST is menu-only in the command catalog, with no rail Button.
    [DarkReNamerVmNative]::RequestMenuCommand($MainHandle, [uint16]0x800E)
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    while ($grid.Current.RowCount -ne 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ($grid.Current.RowCount -ne 0) { throw 'Picker model did not return to its empty starting state.' }
    $Record['status'] = 'passed'
    $Record['filesystem_unchanged'] = $true
    $Record['model_restored_empty'] = $true
    [void]$Record.Remove('active_action')
}

function Assert-GuiObserverProcessDpiResult {
    param([AllowNull()][Nullable[int]] $NativeError)

    if ($null -ne $NativeError) {
        throw [ComponentModel.Win32Exception]::new(
            $NativeError,
            "GUI observer could not establish PerMonitorV2 process DPI awareness (Win32 $NativeError)."
        )
    }
}

function Initialize-GuiObserverProcessDpi {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw [PlatformNotSupportedException]::new('GUI observer process DPI initialization requires Windows.')
    }
    if (-not ('DarkReNamerVmGuiObserverDpi' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class DarkReNamerVmGuiObserverDpi {
    private static bool configured;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    private static extern IntPtr GetDpiAwarenessContextForProcess(IntPtr process);
    [DllImport("user32.dll")]
    private static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")]
    private static extern bool AreDpiAwarenessContextsEqual(IntPtr first, IntPtr second);

    public static int? Configure() {
        if (configured) return null;
        IntPtr perMonitorV2 = new IntPtr(-4);
        bool set;
        try {
            set = SetProcessDpiAwarenessContext(perMonitorV2);
        }
        catch (EntryPointNotFoundException error) {
            throw new PlatformNotSupportedException("GUI observer requires SetProcessDpiAwarenessContext.", error);
        }
        int lastError = Marshal.GetLastWin32Error();
        if (!set) return lastError;
        IntPtr processContext = IntPtr.Zero;
        bool processReadbackSupported = true;
        try {
            processContext = GetDpiAwarenessContextForProcess(IntPtr.Zero);
        }
        catch (EntryPointNotFoundException) {
            // Process-context readback was added after process-context setting.
            processReadbackSupported = false;
        }
        if (processReadbackSupported && !AreDpiAwarenessContextsEqual(processContext, perMonitorV2)) {
            throw new InvalidOperationException("GUI observer process did not enter PerMonitorV2 DPI awareness.");
        }
        if (!AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(), perMonitorV2)) {
            throw new InvalidOperationException("GUI observer thread did not inherit PerMonitorV2 DPI awareness.");
        }
        configured = true;
        return null;
    }
}
'@
    }
    Assert-GuiObserverProcessDpiResult -NativeError ([DarkReNamerVmGuiObserverDpi]::Configure())
}

function Invoke-GuiSmoke {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [string] $FixtureParentRoot,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [switch] $RawEvidence
    )

    $row = [ordered]@{
        file = $Application.file
        sha256 = $Application.sha256
        status = 'failed'
        job_cleanup = $false
        scope = 'launch-window-screenshot-normal-close'
        exit_code = $null
        window_class = $null
        window_title = $null
        window_handle = $null
        process_id = $null
        session_id = $null
        window_dpi = $null
        foreground_activation = [ordered]@{
            initial = $null
            uia_set_focus = 'not_attempted'
            set_foreground_window = $null
            final = $null
            capture_change = $null
        }
        screenshot = $null
        flow = $null
        dialog_picker_checks = $null
        error_detail = $null
        failure_reason = 'process_start_failed'
    }
    $processState = [pscustomobject]@{ process = $null }
    $captureState = [pscustomobject]@{ bitmap = $null; graphics = $null }
    $dpiScope = $null
    $flowFixtureRoot = $null
    $screenshotLeaf = 'main-workbench.png'
    $screenshotPath = Join-Path $OutputRoot $screenshotLeaf
    try {
        do {
            $applicationPath = Join-Path $Root $Application.file
            Assert-OrdinaryFile -Path $applicationPath -Label 'application'
            if ((Get-LowerSha256 -Path $applicationPath) -cne $Application.sha256) {
                $row.failure_reason = 'artifact_changed_after_preflight'
                break
            }
            try {
                Initialize-GuiObserverProcessDpi
            }
            catch {
                $row.failure_reason = 'dpi_awareness_failed'
                Set-GuiSmokeFailureDetail -Row $row -ErrorRecord $_
                break
            }
            Initialize-NativeCapture
            try {
                $dpiScope = [DarkReNamerVmNative+DpiAwarenessScope]::Enter([IntPtr](-4))
            }
            catch {
                $row.failure_reason = 'dpi_awareness_failed'
                Set-GuiSmokeFailureDetail -Row $row -ErrorRecord $_
                break
            }
            $caseRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'gui'
            $flowFixturePath = Join-Path $caseRoot 'rename-flow'
            if (Test-Path -LiteralPath $flowFixturePath) {
                throw 'The production flow fixture already exists before application launch.'
            }
            $runnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if ($RawEvidence -and [string]::IsNullOrWhiteSpace($FixtureParentRoot)) {
                throw 'Raw production flow evidence requires a protected task-directory fixture parent.'
            }
            $flowFixtureParent = if ($FixtureParentRoot) { $FixtureParentRoot } else { $caseRoot }
            $flowFixtureRoot = New-ObserverFixtureDirectory `
                -Parent $flowFixtureParent `
                -Leaf 'production-flow-fixture' `
                -RunnerSid $runnerSid
            Invoke-WithIsolatedEnvironment -RuntimeRoot $caseRoot -Action {
                $initialFlowFixture = Initialize-ProductionRenameFlowFixture `
                    -FixtureRoot $flowFixtureRoot `
                    -ApplicationRoot $Root `
                    -LocalAppData $env:LOCALAPPDATA `
                    -RawEvidence:$RawEvidence
                $processState.process = Start-JobBoundProcess `
                    -FilePath $applicationPath `
                    -Arguments '' `
                    -WorkingDirectory $Root
                $processState.process.process.Refresh()
                $processStartTimeUtcTicks = $processState.process.process.StartTime.ToUniversalTime().Ticks.ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                )
                $row['process_lifecycle'] = [ordered]@{
                    pid = [int]$processState.process.process.Id
                    start_time_utc_ticks = $processStartTimeUtcTicks
                }
                if ($RawEvidence) {
                    $row['process_lifecycle'] = [ordered]@{
                        pid = [int]$processState.process.process.Id
                        session_id = [int]$processState.process.process.SessionId
                        start_time_utc_ticks = $processStartTimeUtcTicks
                        executable_path = $applicationPath
                        executable_sha256 = Get-LowerSha256 -Path $applicationPath
                        start_observed = $true
                        exit_observed = $false
                        exit_method = $null
                        exit_code = $null
                    }
                }
                try {
                    $mainBinding = Wait-ExactApplicationMainWindow `
                        -Process $processState.process.process `
                        -ExpectedSession $ExpectedSession `
                        -ExpectedClassName 'DarkReNamerWindow' `
                        -ExpectedTitle 'DarkReNamer' `
                        -TimeoutSeconds $TimeoutSeconds `
                        -Label 'production application'
                }
                catch {
                    $processState.process.process.Refresh()
                    if ($processState.process.process.HasExited) {
                        $row.exit_code = $processState.process.process.ExitCode
                        $row.failure_reason = 'app_exited_before_window'
                    }
                    elseif ($_.Exception.Message.IndexOf(
                        'exact native window was not found',
                        [StringComparison]::Ordinal
                    ) -ge 0) {
                        $row.failure_reason = 'window_timeout'
                    }
                    else {
                        $row.failure_reason = 'unexpected_window'
                    }
                    return
                }
                $handle = [IntPtr]$mainBinding.handle
                $mainAutomationWindow = $mainBinding.element
                $boundProcessId = [uint32]0
                [void][DarkReNamerVmNative]::GetWindowThreadProcessId($handle, [ref]$boundProcessId)
                $row.window_class = 'DarkReNamerWindow'
                $row.window_title = 'DarkReNamer'
                $row.window_handle = [long]$handle
                $row.process_id = [int]$boundProcessId
                $row.session_id = [int]$processState.process.process.SessionId
                $row.window_dpi = [int][DarkReNamerVmNative]::GetDpiForWindow($handle)

                $row.foreground_activation.initial = Get-ForegroundObservation
                if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                    try {
                        $automationElement = [Windows.Automation.AutomationElement]::FromHandle($handle)
                        if ($null -ne $automationElement) {
                            $automationElement.SetFocus()
                            $row.foreground_activation.uia_set_focus = 'succeeded'
                        }
                        else {
                            $row.foreground_activation.uia_set_focus = 'element_unavailable'
                        }
                    }
                    catch {
                        $row.foreground_activation.uia_set_focus = 'failed'
                    }
                    $row.foreground_activation.set_foreground_window = [bool][DarkReNamerVmNative]::SetForegroundWindow($handle)
                    $foregroundDeadline = (Get-Date).AddSeconds(5)
                    while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle -and
                        (Get-Date) -lt $foregroundDeadline) {
                        Start-Sleep -Milliseconds 100
                    }
                }
                $row.foreground_activation.final = Get-ForegroundObservation
                if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                    $row.failure_reason = 'window_not_foreground'
                    return
                }

                $rect = [DarkReNamerVmNative+Rect]::new()
                if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
                    $row.failure_reason = 'window_bounds_failed'
                    return
                }
                $width = $rect.Right - $rect.Left
                $height = $rect.Bottom - $rect.Top
                if ($width -le 0 -or $height -le 0 -or
                    $width -gt 16384 -or $height -gt 16384 -or
                    ([long]$width * [long]$height) -gt 100000000) {
                    $row.failure_reason = 'window_bounds_invalid'
                    return
                }
                $captureState.bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
                $captureState.graphics = [Drawing.Graphics]::FromImage($captureState.bitmap)
                $captureState.graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $captureState.bitmap.Size, [Drawing.CopyPixelOperation]::SourceCopy)
                if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                    $row.foreground_activation.capture_change = Get-ForegroundObservation
                    $row.failure_reason = 'foreground_changed_during_capture'
                    return
                }
                $sample = Measure-ScreenshotSparseVariation -Width $width -Height $height -ReadArgb {
                    param($x, $y)
                    $captureState.bitmap.GetPixel($x, $y).ToArgb()
                }
                if (-not $sample.has_sampled_variation) {
                    $row.failure_reason = 'screenshot_solid'
                    return
                }
                $captureState.graphics.Dispose()
                $captureState.graphics = $null
                $captureState.bitmap.Save($screenshotPath, [Drawing.Imaging.ImageFormat]::Png)
                $captureState.bitmap.Dispose()
                $captureState.bitmap = $null
                if ((Get-Item -LiteralPath $screenshotPath).Length -le 0) {
                    $row.failure_reason = 'screenshot_empty'
                    return
                }
                $row.screenshot = [ordered]@{
                    file = $screenshotLeaf
                    sha256 = Get-LowerSha256 -Path $screenshotPath
                    width = $width
                    height = $height
                }

                Assert-ExactApplicationMainWindowBinding `
                    -Process $processState.process.process `
                    -ExpectedSession $ExpectedSession `
                    -MainWindowHandle $handle `
                    -MainWindow $mainAutomationWindow `
                    -ExpectedClassName 'DarkReNamerWindow' `
                    -ExpectedTitle 'DarkReNamer' `
                    -Label 'production main window'
                if (-not $RawEvidence) {
                    $row.failure_reason = 'production_picker_checks_failed'
                    $row.dialog_picker_checks = [ordered]@{ schema_version=1; status='failed' }
                    Invoke-ProductionPickerChecks `
                        -Process $processState.process.process -MainWindow $mainAutomationWindow `
                        -MainHandle $handle -RuntimeRoot $caseRoot -Session $ExpectedSession `
                        -TimeoutSeconds $TimeoutSeconds -Record $row.dialog_picker_checks
                }
                $row.flow = Invoke-ProductionRenameFlow `
                    -OwnedProcess $processState.process `
                    -InitialFixture $initialFlowFixture `
                    -MainWindow $mainAutomationWindow `
                    -MainWindowHandle $handle `
                    -FixtureRoot $flowFixtureRoot `
                    -OutputRoot $OutputRoot `
                    -ExpectedSession $ExpectedSession `
                    -TimeoutSeconds $TimeoutSeconds `
                    -RawEvidence:$RawEvidence
                if ($row.flow.status -cne 'passed') {
                    $row.failure_reason = 'production_rename_flow_failed'
                    return
                }

                try {
                    Close-ExactApplicationMainWindow `
                        -Process $processState.process.process `
                        -ExpectedSession $ExpectedSession `
                        -MainWindowHandle $handle `
                        -MainWindow $mainAutomationWindow `
                        -ExpectedClassName 'DarkReNamerWindow' `
                        -ExpectedTitle 'DarkReNamer' `
                        -Label 'production application ordinary close'
                }
                catch {
                    $row.failure_reason = 'normal_close_rejected'
                    return
                }
                if (-not $processState.process.process.WaitForExit(10000)) {
                    $row.failure_reason = 'normal_close_timeout'
                    return
                }
                $processState.process.process.WaitForExit()
                $row.exit_code = $processState.process.process.ExitCode
                if ($RawEvidence) {
                    $row.process_lifecycle.exit_observed = $true
                    $row.process_lifecycle.exit_method = 'normal-close'
                    $row.process_lifecycle.exit_code = [int]$row.exit_code
                }
                if ($processState.process.process.ExitCode -ne 0) {
                    $row.failure_reason = 'app_exit_failed'
                    return
                }
                $jobCleanup = Complete-AcceptanceOwnedProcessJob -Owned $processState.process
                $row.job_cleanup = $jobCleanup.status -ceq 'clean'
                if (-not $row.job_cleanup) {
                    $row.failure_reason = 'process_job_cleanup_failed'
                    return
                }
                $row.flow.checkpoints += (Get-FlowCheckpoint `
                    -Phase post_close `
                    -FixtureRoot $flowFixtureRoot `
                    -LocalAppData $env:LOCALAPPDATA)
                if ($RawEvidence) {
                    $row.flow.raw_checkpoints += (Get-VmAutomatedCheckpoint `
                        -Phase post_close `
                        -FixtureRoot $flowFixtureRoot `
                        -LocalAppData $env:LOCALAPPDATA)
                }
                $row.status = 'passed'
                $row.failure_reason = $null
            }
        } while ($false)
    }
    catch {
        $row.failure_reason = 'gui_error'
        Set-GuiSmokeFailureDetail -Row $row -ErrorRecord $_
    }
    finally {
        if ($null -ne $dpiScope) {
            try { $dpiScope.Dispose() }
            catch {
                $row.status = 'failed'
                Set-ProcessCleanupFailureReason -Row $row -Reason 'dpi_restore_failed'
                Set-GuiSmokeFailureDetail -Row $row -ErrorRecord $_
            }
        }
        if ($null -ne $captureState.graphics) { $captureState.graphics.Dispose() }
        if ($null -ne $captureState.bitmap) { $captureState.bitmap.Dispose() }
        if ($null -ne $processState.process) {
            try {
                $processState.process.process.Refresh()
                if (-not $processState.process.job_closed) {
                    $jobCleanup = Complete-AcceptanceOwnedProcessJob `
                        -Owned $processState.process -StopActive
                    $row.job_cleanup = $jobCleanup.status -ceq 'clean'
                    if ($jobCleanup.status -cne 'clean' -or -not $jobCleanup.job_empty -or -not $jobCleanup.job_closed) {
                        throw 'The production GUI process job did not close cleanly.'
                    }
                    if ($RawEvidence -and $row.Contains('process_lifecycle')) {
                        if ($jobCleanup.forced_termination -and -not $row.process_lifecycle.exit_observed) {
                            $row.process_lifecycle.exit_observed = $true
                            $row.process_lifecycle.exit_method = 'forced-termination'
                            $row.process_lifecycle.exit_code = [int]$processState.process.process.ExitCode
                        }
                    }
                }
            }
            catch {
                $row.status = 'failed'
                Set-ProcessCleanupFailureReason -Row $row -Reason 'process_cleanup_failed'
                Set-GuiSmokeFailureDetail -Row $row -ErrorRecord $_
            }
            try { $processState.process.process.Dispose() } catch {}
        }
        else {
            $row.job_cleanup = $true
        }
        if ($null -ne $flowFixtureRoot -and (Test-Path -LiteralPath $flowFixtureRoot)) {
            try {
                if ($null -ne $processState.process -and -not $processState.process.job_closed) {
                    throw 'The production flow fixture cannot be removed before its process job is closed.'
                }
                if ($null -ne $processState.process -and
                    (-not $processState.process.job_cleanup_recorded -or
                        $processState.process.job_cleanup_record.status -cne 'clean')) {
                    throw 'The production flow fixture cannot be removed after unclean process job cleanup.'
                }
                Assert-OrdinaryDirectoryTree -Path $flowFixtureRoot
                Remove-Item -LiteralPath $flowFixtureRoot -Recurse -Force
                if (Test-Path -LiteralPath $flowFixtureRoot) {
                    throw 'Production flow fixture cleanup was incomplete.'
                }
            }
            catch {
                $row.status = 'failed'
                Set-ProcessCleanupFailureReason -Row $row -Reason 'flow_fixture_cleanup_failed'
                Set-GuiSmokeFailureDetail -Row $row -ErrorRecord $_
            }
        }
    }
    [pscustomobject]$row
}
