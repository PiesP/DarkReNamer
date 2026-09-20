function Invoke-ProductionRenameFlow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [switch] $RawEvidence
    )

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
        $flow.application_sha256 = Get-LowerSha256 -Path (Join-Path $Root 'DarkReNamer.exe')
        $fixtureBytes = [Text.UTF8Encoding]::new($false).GetBytes(
            "DarkReNamer production VM flow`nidentity and content must survive`n"
        )
        [IO.File]::WriteAllBytes($sourcePath, $fixtureBytes)
        $flow.before_content_sha256 = Get-LowerSha256 -Path $sourcePath
        $beforeFileIdentity = [DarkReNamerVmNative]::GetFileIdentity($sourcePath)
        $flow.before_file_identity_sha256 = Get-LowerTextSha256 -Value $beforeFileIdentity
        $flow.checkpoints = @((Get-FlowCheckpoint `
            -Phase initial `
            -FixtureRoot $FixtureRoot `
            -LocalAppData $env:LOCALAPPDATA))
        if ($RawEvidence) {
            $flow['raw_environment'] = Get-VmAutomatedEnvironment `
                -Process $Process `
                -WindowHandle ([IntPtr]$MainWindow.Current.NativeWindowHandle) `
                -FixtureRoot $FixtureRoot
            $flow['raw_checkpoints'] = @((Get-VmAutomatedCheckpoint `
                -Phase initial `
                -FixtureRoot $FixtureRoot `
                -LocalAppData $env:LOCALAPPDATA))
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
        $invoke = Start-AutomationControlInvoke -Element $add -Label 'file-add command'
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
        $invoke = Start-AutomationControlInvoke -Element $prefixCommand -Label 'prefix command'
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
            -Root $Root `
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
        $invoke = Start-AutomationControlInvoke -Element $apply -Label 'apply command'
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
            -Root $Root `
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
        $invoke = Start-AutomationControlInvoke `
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
        $diagnosticPath = Join-Path $Root $diagnosticLeaf
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
    finally {
        $incomplete = @($pendingInvocations | Where-Object { -not $_.completed })
        if ($incomplete.Count -gt 0 -and -not $Process.HasExited) {
            Invoke-TaskkillTree -ProcessId $Process.Id
            [void]$Process.WaitForExit(10000)
        }
        foreach ($invocation in $incomplete) {
            try {
                if ($invocation.async_result.AsyncWaitHandle.WaitOne(10000)) {
                    [void]$invocation.powershell.EndInvoke($invocation.async_result)
                }
                else {
                    $invocation.powershell.Stop()
                }
            }
            catch {
            }
            finally {
                $invocation.completed = $true
                $invocation.powershell.Dispose()
                $invocation.runspace.Dispose()
            }
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
function Invoke-GuiSmoke {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [switch] $RawEvidence
    )

    $row = [ordered]@{
        file = $Application.file
        sha256 = $Application.sha256
        status = 'failed'
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
        failure_reason = 'process_start_failed'
    }
    $processState = [pscustomobject]@{ process = $null }
    $captureState = [pscustomobject]@{ bitmap = $null; graphics = $null }
    $flowFixtureRoot = $null
    $screenshotLeaf = 'main-workbench.png'
    $screenshotPath = Join-Path $Root $screenshotLeaf
    try {
        $applicationPath = Join-Path $Root $Application.file
        Assert-OrdinaryFile -Path $applicationPath -Label 'application'
        if ((Get-LowerSha256 -Path $applicationPath) -cne $Application.sha256) {
            $row.failure_reason = 'artifact_changed_after_preflight'
            return [pscustomobject]$row
        }
        Initialize-NativeCapture
        if (-not [DarkReNamerVmNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
            $row.failure_reason = 'dpi_awareness_failed'
            return [pscustomobject]$row
        }
        $caseRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'gui'
        Invoke-WithIsolatedEnvironment -RuntimeRoot $caseRoot -Action {
            $processState.process = Start-OwnedProcess `
                -FilePath $applicationPath `
                -Arguments '' `
                -WorkingDirectory $Root
            if ($RawEvidence) {
                $processState.process.process.Refresh()
                $row['process_lifecycle'] = [ordered]@{
                    pid = [int]$processState.process.process.Id
                    session_id = [int]$processState.process.process.SessionId
                    start_time_utc_ticks = $processState.process.process.StartTime.ToUniversalTime().Ticks.ToString(
                        [Globalization.CultureInfo]::InvariantCulture
                    )
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
            $captureState.bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $captureState.graphics = [Drawing.Graphics]::FromImage($captureState.bitmap)
            $captureState.graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $captureState.bitmap.Size, [Drawing.CopyPixelOperation]::SourceCopy)
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                $row.foreground_activation.capture_change = Get-ForegroundObservation
                $row.failure_reason = 'foreground_changed_during_capture'
                return
            }
            $firstColor = $captureState.bitmap.GetPixel(0, 0).ToArgb()
            $hasDifferentColor = $false
            $stepX = [Math]::Max(1, [int]($width / 64))
            $stepY = [Math]::Max(1, [int]($height / 64))
            for ($y = 0; $y -lt $height -and -not $hasDifferentColor; $y += $stepY) {
                for ($x = 0; $x -lt $width; $x += $stepX) {
                    if ($captureState.bitmap.GetPixel($x, $y).ToArgb() -ne $firstColor) {
                        $hasDifferentColor = $true
                        break
                    }
                }
            }
            if (-not $hasDifferentColor) {
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
            $flowFixtureRoot = New-PrivateDirectory -Parent $caseRoot -Leaf 'rename-flow'
            $row.flow = Invoke-ProductionRenameFlow `
                -Process $processState.process.process `
                -MainWindow $mainAutomationWindow `
                -MainWindowHandle $handle `
                -FixtureRoot $flowFixtureRoot `
                -Root $Root `
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
    }
    catch {
        $row.failure_reason = 'gui_error'
    }
    finally {
        if ($null -ne $captureState.graphics) { $captureState.graphics.Dispose() }
        if ($null -ne $captureState.bitmap) { $captureState.bitmap.Dispose() }
        if ($null -ne $processState.process) {
            try {
                $processState.process.process.Refresh()
                if (-not $processState.process.process.HasExited) {
                    Invoke-TaskkillTree -ProcessId $processState.process.process.Id
                    if (-not $processState.process.process.WaitForExit(10000)) {
                        throw 'Owned application process did not terminate.'
                    }
                    if ($RawEvidence -and $row.Contains('process_lifecycle')) {
                        $row.process_lifecycle.exit_observed = $true
                        $row.process_lifecycle.exit_method = 'forced-termination'
                        $row.process_lifecycle.exit_code = [int]$processState.process.process.ExitCode
                    }
                }
            }
            catch {
                $row.status = 'failed'
                $row.failure_reason = 'process_cleanup_failed'
            }
            $processState.process.process.Dispose()
        }
        if ($null -ne $flowFixtureRoot -and (Test-Path -LiteralPath $flowFixtureRoot)) {
            try {
                $fixtureItem = Get-Item -LiteralPath $flowFixtureRoot -Force
                if (($fixtureItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Production flow fixture became a reparse point.'
                }
                Remove-Item -LiteralPath $flowFixtureRoot -Recurse -Force
                if (Test-Path -LiteralPath $flowFixtureRoot) {
                    throw 'Production flow fixture cleanup was incomplete.'
                }
            }
            catch {
                $row.status = 'failed'
                $row.failure_reason = 'flow_fixture_cleanup_failed'
            }
        }
    }
    [pscustomobject]$row
}
