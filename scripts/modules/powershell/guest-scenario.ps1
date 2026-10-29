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

function Get-ProductionLanguageSpec {
    param([Parameter(Mandatory)][ValidateSet('ko', 'en', 'ja')][string] $Language)
    switch ($Language) {
        'ko' { [ordered]@{
            picker = '이름 붙일 파일 불러오기'; prefix = '이름 앞에 문자열 붙이기'
            apply = 'DarkReNamer - 안전한 적용 확인'; empty = '파일이나 폴더를 여기에 끌어오세요'
            menu = '언어(&L) · 다음 실행부터'; rail = '이름 앞에 문자열 붙이기...'
            system = '시스템 언어'; question = '계획된 파일 변경을 적용하시겠습니까?'
            no_overwrite = '기존 파일을 덮어쓰지 않습니다.'
            recovery = 'DarkReNamer - 복구 상태'; recovery_locked = '새 적용은 잠겼습니다.'
            recovery_confirm = 'DarkReNamer - 이전 변경 복구 확인'
            recovery_question = '이전 실행에서 중단된 이름 변경을 복구하시겠습니까?'
            recovery_detail = '복구를 선택하면 보존된 저널과 현재 파일 신원을 다시 검증한 뒤 필요한 역방향 이름 변경을 수행합니다. 취소하면 어떤 파일도 변경하지 않고 복구 잠금을 유지합니다.'
            blocked_apply = 'DarkReNamer - 적용 차단'; occupied = '대상 이름이 이미 사용 중입니다.'
            command = [int]0x9021; value = 1
        } }
        'en' { [ordered]@{
            picker = 'Select files to rename'; prefix = 'Add a name prefix'
            apply = 'DarkReNamer - Confirm safe Apply'; empty = 'Drop files or folders here'
            menu = '&Language · next startup'; rail = 'Add a name prefix...'
            system = 'System language'; question = 'Apply the planned file changes?'
            no_overwrite = 'Existing files will not be overwritten.'
            recovery = 'DarkReNamer - Recovery status'; recovery_locked = 'Apply is locked.'
            recovery_confirm = 'DarkReNamer - Confirm recovery'
            recovery_question = 'Recover name changes interrupted in the previous run?'
            recovery_detail = 'Recover checks the retained journal and current file identities again before reversing changes as needed. Cancel changes no files and keeps recovery locked.'
            blocked_apply = 'DarkReNamer - Apply blocked'; occupied = 'The destination name is already in use.'
            command = [int]0x9022; value = 2
        } }
        'ja' { [ordered]@{
            picker = '名前を変更するファイルを選択'; prefix = '名前の先頭に文字列を追加'
            apply = 'DarkReNamer - 安全な適用の確認'; empty = 'ファイルやフォルダーをここにドロップ'
            menu = '言語(&L) · 次回起動から'; rail = '名前の先頭に文字列を追加...'
            system = 'システム言語'; question = '計画されたファイル変更を適用しますか？'
            no_overwrite = '既存のファイルは上書きしません。'
            recovery = 'DarkReNamer - 復旧状態'; recovery_locked = '適用をロックしました。'
            recovery_confirm = 'DarkReNamer - 復旧の確認'
            recovery_question = '前回の実行で中断された名前変更を復旧しますか？'
            recovery_detail = '復旧を選ぶと、保持されたジャーナルと現在のファイル識別情報を再検証して必要な逆方向の名前変更を行います。キャンセルするとファイルは変更されず、復旧ロックが維持されます。'
            blocked_apply = 'DarkReNamer - 適用をブロック'; occupied = '変更先の名前はすでに使用されています。'
            command = [int]0x9023; value = 3
        } }
    }
}

function Select-ProductionMessageBoxOkCandidate {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Candidates)
    $nativeButtons = @($Candidates | Where-Object {
        $_.native_handle -gt 0 -and $_.native_live -eq $true -and
        $_.native_parent_bound -eq $true -and $_.native_class -ceq 'Button'
    })
    if ($nativeButtons.Count -gt 1) {
        throw 'The exact MessageBox has more than one live native Button child.'
    }
    if ($nativeButtons.Count -eq 1) {
        if ($nativeButtons[0].native_control_id -le 0) {
            throw 'The sole native MessageBox Button has an invalid control ID.'
        }
        if ($nativeButtons[0].enabled -ne $true) {
            throw 'The sole native MessageBox Button is disabled.'
        }
        return $nativeButtons[0]
    }
    $null
}

function Find-ProductionMessageBoxOk {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label
    )
    Initialize-ProductionLanguageMenuReader
    Assert-AutomationBinding -Element $Window -Process $Process `
        -ExpectedSession $ExpectedSession -Label "$Label dialog" -RequireWindowHandle
    if ($Window.Current.ClassName -cne '#32770') {
        throw "$Label is not the exact native MessageBox dialog class."
    }
    $dialogHandle = [IntPtr]$Window.Current.NativeWindowHandle
    $conditions = [Windows.Automation.AndCondition]::new([Windows.Automation.Condition[]]@(
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ProcessIdProperty, $Process.Id),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::Button)
    ))
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    $lastMetadata = @()
    do {
        Assert-AutomationBinding -Element $Window -Process $Process `
            -ExpectedSession $ExpectedSession -Label "$Label dialog" -RequireWindowHandle
        if ([IntPtr]$Window.Current.NativeWindowHandle -ne $dialogHandle) {
            throw "$Label dialog HWND changed during native IDOK lookup."
        }
        $buttons = $Window.FindAll([Windows.Automation.TreeScope]::Descendants, $conditions)
        if ($buttons.Count -gt 32) { throw "$Label has too many owned Button descendants." }
        $candidates = [Collections.Generic.List[object]]::new()
        $metadata = [Collections.Generic.List[object]]::new()
        foreach ($button in $buttons) {
            $handle = [IntPtr]$button.Current.NativeWindowHandle
            $classText = [Text.StringBuilder]::new(64)
            $nativeClass = if ($handle -ne [IntPtr]::Zero) {
                [void][DarkReNamerVmNative]::GetClassName($handle, $classText, $classText.Capacity)
                $classText.ToString()
            } else { '' }
            $id = if ($handle -ne [IntPtr]::Zero) {
                [DarkReNamerLanguageMenuReader]::GetDlgCtrlID($handle)
            } else { 0 }
            $parentBound = $handle -ne [IntPtr]::Zero -and
                [DarkReNamerLanguageMenuReader]::IsChild($dialogHandle, $handle)
            $automationId = [string]$button.Current.AutomationId
            if ($automationId.Length -gt 128) { $automationId = $automationId.Substring(0, 128) }
            $candidate = [ordered]@{
                element = $button
                native_handle = [long]$handle
                native_live = [bool]($handle -ne [IntPtr]::Zero -and
                    [DarkReNamerVmNative]::IsWindow($handle))
                native_parent_bound = [bool]$parentBound
                native_control_id = [int]$id
                native_class = [string]$nativeClass
                enabled = [bool]$button.Current.IsEnabled
                automation_id = $automationId
                selection_contract = 'sole-native-messagebox-button'
                native_button_count = 1
            }
            $candidates.Add($candidate)
            $metadata.Add([ordered]@{
                native_handle = $candidate.native_handle
                native_live = $candidate.native_live
                native_parent_bound = $candidate.native_parent_bound
                native_control_id = $candidate.native_control_id
                native_class = $candidate.native_class
                enabled = $candidate.enabled
                automation_id = $candidate.automation_id
            })
        }
        $lastMetadata = $metadata.ToArray()
        $selected = Select-ProductionMessageBoxOkCandidate -Candidates $candidates.ToArray()
        if ($null -ne $selected) {
            Assert-AutomationBinding -Element $selected.element -Process $Process `
                -ExpectedSession $ExpectedSession -Label $Label -RequireWindowHandle
            $recheckedClass = [Text.StringBuilder]::new(64)
            [void][DarkReNamerVmNative]::GetClassName(
                [IntPtr]$selected.native_handle, $recheckedClass, $recheckedClass.Capacity)
            if (-not $selected.element.Current.IsEnabled -or
                [IntPtr]$selected.element.Current.NativeWindowHandle -ne
                    [IntPtr]$selected.native_handle -or
                $recheckedClass.ToString() -cne $selected.native_class -or
                -not [DarkReNamerLanguageMenuReader]::IsChild($dialogHandle,
                    [IntPtr]$selected.native_handle) -or
                [DarkReNamerLanguageMenuReader]::GetDlgCtrlID(
                    [IntPtr]$selected.native_handle) -ne $selected.native_control_id) {
                throw "$Label sole native Button binding changed before invocation."
            }
            return $selected
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited -or $Process.SessionId -ne $ExpectedSession) {
            throw "$Label was not found before the bound application left its session."
        }
    } while ((Get-Date) -lt $deadline)
    $summary = ConvertTo-Json -InputObject @($lastMetadata) -Depth 3 -Compress
    if ($summary.Length -gt 4096) { $summary = $summary.Substring(0, 4096) }
    throw "$Label sole native MessageBox Button was not found before the bounded deadline; button metadata: $summary"
}

function Assert-ProductionApplyCopy {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][string] $Language
    )
    $labels = Get-ProductionLanguageSpec -Language $Language
    Assert-AutomationBinding -Element $Window -Process $Process -ExpectedSession $Session `
        -Label "$Language Apply confirmation" -RequireWindowHandle
    $bounds = $Window.Current.BoundingRectangle
    if ($bounds.Width -le 0 -or $bounds.Height -le 0 -or
        $bounds.Width -gt 16384 -or $bounds.Height -gt 16384) {
        throw "$Language Apply confirmation has invalid native bounds."
    }
    $children = $Window.FindAll([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.Condition]::TrueCondition)
    if ($children.Count -gt 512) { throw "$Language Apply confirmation tree exceeds its bound." }
    $names = [Collections.Generic.List[string]]::new()
    foreach ($element in $children) {
        if ($element.Current.ProcessId -eq $Process.Id -and
            -not [string]::IsNullOrEmpty($element.Current.Name)) {
            $names.Add([string]$element.Current.Name)
        }
    }
    $copy = [string]::Join("`n", $names)
    if ($copy.Length -gt 32768 -or
        $copy.IndexOf($labels.question, [StringComparison]::Ordinal) -lt 0 -or
        $copy.IndexOf($labels.no_overwrite, [StringComparison]::Ordinal) -lt 0) {
        throw "$Language Apply confirmation lost its localized question or no-overwrite guidance."
    }
    [ordered]@{
        title = [string]$Window.Current.Name
        question = $labels.question
        no_overwrite = $labels.no_overwrite
        bounds = [ordered]@{ width = $bounds.Width; height = $bounds.Height }
    }
}

function Invoke-ProductionOccupiedDestinationCheck {
    param(
        [Parameter(Mandatory)][object] $OwnedProcess,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $DestinationPath,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][ValidateSet('ko', 'en', 'ja')][string] $Language
    )
    $labels = Get-ProductionLanguageSpec -Language $Language
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf) -or
        (Test-Path -LiteralPath $DestinationPath)) {
        throw 'Occupied-destination check requires an untouched source and absent target.'
    }
    $sourceHash = Get-LowerSha256 -Path $SourcePath
    $sourceIdentity = [DarkReNamerVmNative]::GetFileIdentity($SourcePath)
    [IO.File]::WriteAllBytes($DestinationPath,
        [Text.Encoding]::ASCII.GetBytes('Existing destination must never be overwritten'))
    $destinationHash = Get-LowerSha256 -Path $DestinationPath
    $destinationIdentity = [DarkReNamerVmNative]::GetFileIdentity($DestinationPath)
    $sourceIdentityHash = Get-LowerTextSha256 -Value $sourceIdentity
    $destinationIdentityHash = Get-LowerTextSha256 -Value $destinationIdentity
    $passed = $false
    try {
        $process = $OwnedProcess.process
        $apply = Find-UniqueAutomationElement -Root $MainWindow -Process $process `
            -ExpectedSession $Session -AutomationId ([string]0x8003) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds -Label "$Language occupied-destination Apply" `
            -RequireEnabled -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -OwnedProcess $OwnedProcess -Element $apply `
            -Label "$Language occupied-destination Apply"
        $blocked = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $Session `
            -MainWindowHandle $MainWindowHandle -Name $labels.blocked_apply `
            -TimeoutSeconds $TimeoutSeconds -Label "$Language occupied-destination refusal"
        $blockedHandle = [IntPtr]$blocked.Current.NativeWindowHandle
        $bounds = $blocked.Current.BoundingRectangle
        if ($bounds.Width -le 0 -or $bounds.Height -le 0 -or
            $bounds.Width -gt 16384 -or $bounds.Height -gt 16384) {
            throw "$Language occupied-destination refusal has invalid bounds."
        }
        $children = $blocked.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.Condition]::TrueCondition)
        if ($children.Count -gt 512) { throw 'Occupied-destination refusal tree exceeds its bound.' }
        $names = [Collections.Generic.List[string]]::new()
        foreach ($element in $children) {
            if ($element.Current.ProcessId -eq $process.Id -and $element.Current.Name) {
                $names.Add([string]$element.Current.Name)
            }
        }
        $copy = [string]::Join("`n", $names)
        if ($copy.Length -gt 32768 -or
            $copy.IndexOf($labels.occupied, [StringComparison]::Ordinal) -lt 0) {
            throw "$Language occupied-destination refusal lost its localized safety reason."
        }
        $ok = Find-ProductionMessageBoxOk -Window $blocked -Process $process `
            -ExpectedSession $Session -TimeoutSeconds $TimeoutSeconds `
            -Label "$Language occupied-destination OK"
        Invoke-AutomationControl -Element $ok.element -Label "$Language occupied-destination OK"
        Wait-WindowClosed -Handle $blockedHandle -TimeoutSeconds $TimeoutSeconds `
            -Label "$Language occupied-destination refusal"
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        if ((Get-LowerSha256 -Path $SourcePath) -cne $sourceHash -or
            [DarkReNamerVmNative]::GetFileIdentity($SourcePath) -cne $sourceIdentity -or
            (Get-LowerSha256 -Path $DestinationPath) -cne $destinationHash -or
            [DarkReNamerVmNative]::GetFileIdentity($DestinationPath) -cne $destinationIdentity) {
            throw "$Language occupied-destination refusal changed source or existing target."
        }
        $passed = $true
        [ordered]@{
            title = $labels.blocked_apply; reason = $labels.occupied
            bounds = [ordered]@{ width = $bounds.Width; height = $bounds.Height }
            ok_control = [ordered]@{
                selection_contract = $ok.selection_contract
                native_button_count = $ok.native_button_count
                automation_id = $ok.automation_id; native_control_id = $ok.native_control_id
                native_parent_bound = $ok.native_parent_bound; native_class = $ok.native_class
                enabled = $ok.enabled
            }
            source_unchanged = $true; destination_unchanged = $true
            source_before_sha256 = $sourceHash
            source_after_sha256 = Get-LowerSha256 -Path $SourcePath
            source_before_file_identity_sha256 = $sourceIdentityHash
            source_after_file_identity_sha256 = Get-LowerTextSha256 -Value ([DarkReNamerVmNative]::GetFileIdentity($SourcePath))
            destination_before_sha256 = $destinationHash
            destination_after_sha256 = Get-LowerSha256 -Path $DestinationPath
            destination_before_file_identity_sha256 = $destinationIdentityHash
            destination_after_file_identity_sha256 = Get-LowerTextSha256 -Value ([DarkReNamerVmNative]::GetFileIdentity($DestinationPath))
            journal_residue_count = 0
        }
    }
    finally {
        if ($passed) {
            if ((Get-LowerSha256 -Path $DestinationPath) -cne $destinationHash -or
                [DarkReNamerVmNative]::GetFileIdentity($DestinationPath) -cne $destinationIdentity) {
                throw 'Owned collision fixture changed before exact cleanup.'
            }
            Remove-Item -LiteralPath $DestinationPath -Force
            if (Test-Path -LiteralPath $DestinationPath) {
                throw 'Owned collision fixture cleanup was incomplete.'
            }
        }
    }
}

function Set-ProductionCaptureByteCount {
    param(
        [Parameter(Mandatory)][object] $Capture,
        [Parameter(Mandatory)][string] $Root
    )
    $item = Get-Item -LiteralPath (Join-Path $Root $Capture.file) -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 45 -or $item.Length -gt (8 * 1024 * 1024)) {
        throw 'Language PNG capture exceeds its ordinary-file byte bound.'
    }
    $Capture['bytes'] = [long]$item.Length
}

function Complete-ProductionLanguageFlowCaptureReferences {
    param(
        [Parameter(Mandatory)][object] $Flow,
        [Parameter(Mandatory)][string] $Root
    )
    $captures = @($Flow.screenshots)
    if ($captures.Count -ne 2) {
        throw 'Language production flow requires both screenshot references.'
    }
    foreach ($capture in $captures) {
        Set-ProductionCaptureByteCount -Capture $capture -Root $Root
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
        [switch] $RawEvidence,
        [switch] $ExpectExistingRuntimeLock,
        [ValidateSet('ko', 'en', 'ja')][string] $Language = 'ko'
    )

    if ($ExpectExistingRuntimeLock -and ($RawEvidence -or $Language -ceq 'ko')) {
        throw 'Only non-raw English and Japanese flows may reuse the runtime lock.'
    }

    $Process = $OwnedProcess.process
    $labels = Get-ProductionLanguageSpec -Language $Language
    $artifactPrefix = if ($Language -ceq 'ko') { '' } else { "$Language-" }
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
        process_id = [int]$Process.Id
        session_id = [int]$ExpectedSession
        window_handle = [long]$MainWindowHandle
        process_start_time_utc_ticks = $Process.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
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
            -Startup $flow.checkpoints[0] `
            -ExpectExistingRuntimeLock:$ExpectExistingRuntimeLock
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
            -Name $labels.picker `
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
            -Name $labels.prefix `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt'
        $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
        $flow['prefix_prompt_hwnd'] = [long]$promptHandle
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
        if (-not $RawEvidence) {
            $flow['prefix_prompt_capture'] = Save-WindowScreenshot `
                -Window $prompt -Process $Process -ExpectedSession $ExpectedSession `
                -Root $OutputRoot -Leaf "$Language-prefix-prompt.png" `
                -Label 'prefix prompt' -ForegroundObservations $foregroundObservations
            Set-ProductionCaptureByteCount -Capture $flow.prefix_prompt_capture -Root $OutputRoot
        }
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
            -Leaf "${artifactPrefix}rename-preview.png" `
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
            -Name $labels.apply `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply confirmation task dialog'
        $flow['localized_confirmation'] = Assert-ProductionApplyCopy `
            -Window $confirmation -Process $Process -Session $ExpectedSession -Language $Language
        $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
        $screenshots.Add((Save-WindowScreenshot `
            -Window $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Root $OutputRoot `
            -Leaf "${artifactPrefix}apply-confirmation.png" `
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

        if (-not $RawEvidence) {
            $flow.failure_reason = 'occupied_destination_refusal_failed'
            $flow['occupied_destination'] = Invoke-ProductionOccupiedDestinationCheck `
                -OwnedProcess $OwnedProcess -MainWindow $MainWindow `
                -MainWindowHandle $MainWindowHandle -SourcePath $sourcePath `
                -DestinationPath $destinationPath -Session $ExpectedSession `
                -TimeoutSeconds $TimeoutSeconds -Language $Language
        }

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
            -Name $labels.apply `
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
        if (-not $RawEvidence -and $Language -cne 'ko') {
            $flow.failure_reason = 'language_capture_reference_failed'
            Complete-ProductionLanguageFlowCaptureReferences -Flow $flow -Root $OutputRoot
        }
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
            if ($values -ccontains '텍스트 파일 (*.txt)' -or $values -ccontains '텍스트 파일') { $candidates += $candidate }
        }
        if ($candidates.Count -ne 1) {
            throw "Picker has no unique selected text-file filter: $($comboObservations | ConvertTo-Json -Depth 4 -Compress)"
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
                $_ -cin @('텍스트 파일', '텍스트 파일 (*.txt)', '모든 파일', '모든 파일 (*.*)')
            })
            if ($filterNames.Count -ne 2) { throw 'Text picker did not expose both maintained filters.' }
            if ($filterNames[0] -cnotin @('텍스트 파일', '텍스트 파일 (*.txt)') -or
                $filterNames[1] -cnotin @('모든 파일', '모든 파일 (*.*)')) {
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

function Initialize-ProductionLanguageMenuReader {
    if ('DarkReNamerLanguageMenuReader' -as [type]) {
        [DarkReNamerLanguageMenuReader]::AssertInputLayout()
        return
    }
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class DarkReNamerLanguageMenuReader {
    [StructLayout(LayoutKind.Sequential)] private struct KeyInput {
        public ushort VirtualKey, ScanCode;
        public uint Flags, Time;
        public UIntPtr ExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput {
        public int X, Y;
        public uint MouseData, Flags, Time;
        public UIntPtr ExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion {
        [FieldOffset(0)] public KeyInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Input {
        public uint Type;
        public InputUnion Value;
    }
    [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
    public static int[] InputLayout() {
        return new [] {
            Marshal.SizeOf(typeof(KeyInput)), Marshal.SizeOf(typeof(MouseInput)),
            Marshal.SizeOf(typeof(InputUnion)), Marshal.SizeOf(typeof(Input)),
            Marshal.OffsetOf(typeof(Input), "Value").ToInt32()
        };
    }
    public static void AssertInputLayout() {
        int[] actual = InputLayout();
        int[] expected = IntPtr.Size == 8 ? new [] { 24, 32, 32, 40, 8 } :
            IntPtr.Size == 4 ? new [] { 16, 24, 24, 28, 4 } : null;
        if (expected == null) throw new InvalidOperationException("Unsupported native INPUT pointer size.");
        for (int index = 0; index < expected.Length; index++) {
            if (actual[index] != expected[index])
                throw new InvalidOperationException("Native INPUT layout differs from the SendInput ABI.");
        }
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetUserPreferredUILanguages(uint flags, out uint count, [Out] char[] buffer, ref uint size);
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr GetMenu(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr GetSubMenu(IntPtr menu, int position);
    [DllImport("user32.dll", SetLastError=true)] private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint GetMenuItemID(IntPtr menu, int position);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint GetMenuState(IntPtr menu, uint position, uint flags);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetDlgCtrlID(IntPtr control);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern int GetMenuStringW(IntPtr menu, uint position, StringBuilder text, int capacity, uint flags);

    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct GuiThreadInfo {
        public uint Size, Flags;
        public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public Rect CaretRect;
    }
    public sealed class MenuStage {
        public uint ThreadId, ProcessId, GuiFlags;
        public long MenuOwner, LanguageHandle;
        public uint ViewLanguageState;
        public uint[] Commands, States, TopStates, ViewStates;
    }

    private static Input KeyboardPacket(ushort virtualKey, uint flags) {
        return new Input { Type = 1, Value = new InputUnion {
            Keyboard = new KeyInput { VirtualKey = virtualKey, ScanCode = 0,
                Flags = flags, Time = 0, ExtraInfo = UIntPtr.Zero }
        } };
    }
    public static uint[] InspectTapPackets(ushort virtualKey, bool extended) {
        Input down = KeyboardPacket(virtualKey, extended ? 1u : 0u);
        Input up = KeyboardPacket(virtualKey, extended ? 3u : 2u);
        return new uint[] { down.Type, down.Value.Keyboard.VirtualKey,
            down.Value.Keyboard.Flags, up.Type, up.Value.Keyboard.VirtualKey,
            up.Value.Keyboard.Flags };
    }
    private static void SendKey(ushort virtualKey, uint flags) {
        AssertInputLayout();
        Input input = KeyboardPacket(virtualKey, flags);
        if (SendInput(1, new [] { input }, Marshal.SizeOf(typeof(Input))) != 1)
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static void KeyDown(ushort virtualKey) { SendKey(virtualKey, 0); }
    public static void KeyUp(ushort virtualKey) { SendKey(virtualKey, 2); }
    public static void Tap(ushort virtualKey) {
        try { KeyDown(virtualKey); }
        finally { KeyUp(virtualKey); }
    }
    public static void TapExtended(ushort virtualKey) {
        try { SendKey(virtualKey, 1); }
        finally { SendKey(virtualKey, 3); }
    }

    private static IntPtr Child(IntPtr parent, int position) {
        IntPtr value = GetSubMenu(parent, position);
        if (value == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        return value;
    }
    private static string Text(IntPtr menu, int position) {
        StringBuilder text = new StringBuilder(256);
        int length = GetMenuStringW(menu, (uint)position, text, text.Capacity, 0x400);
        if (length <= 0 || length >= text.Capacity - 1) throw new InvalidOperationException("Language menu text is empty or over bound.");
        return text.ToString();
    }
    public static string[] Read(IntPtr window) {
        IntPtr bar = GetMenu(window);
        if (bar == IntPtr.Zero || GetMenuItemCount(bar) != 6) throw new InvalidOperationException("Language menu has no fixed source-bound menu bar.");
        IntPtr view = Child(bar, 2);
        if (GetMenuItemCount(view) != 10) throw new InvalidOperationException("View menu layout changed.");
        IntPtr language = Child(view, 9);
        if (GetMenuItemCount(language) != 4) throw new InvalidOperationException("Language menu layout changed.");
        string[] rows = new string[6];
        rows[0] = Text(view, 9);
        for (int index = 0; index < 4; index++) {
            uint command = GetMenuItemID(language, index);
            uint state = GetMenuState(language, (uint)index, 0x400);
            if (command != 0x9020 + index || state == UInt32.MaxValue)
                throw new InvalidOperationException("Language menu command identity changed.");
            rows[index + 1] = Text(language, index);
            if ((state & 0x8) != 0) rows[5] = command.ToString();
        }
        if (rows[5] == null) throw new InvalidOperationException("Language menu has no selected preference.");
        return rows;
    }
    public static MenuStage Observe(IntPtr window, uint expectedProcessId) {
        uint processId;
        uint thread = GetWindowThreadProcessId(window, out processId);
        if (thread == 0 || processId != expectedProcessId)
            throw new InvalidOperationException("Language menu thread differs from the bound application.");
        GuiThreadInfo gui = new GuiThreadInfo();
        gui.Size = (uint)Marshal.SizeOf(typeof(GuiThreadInfo));
        if (!GetGUIThreadInfo(thread, ref gui)) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr bar = GetMenu(window);
        if (bar == IntPtr.Zero || GetMenuItemCount(bar) != 6)
            throw new InvalidOperationException("Language menu bar changed during keyboard navigation.");
        IntPtr view = Child(bar, 2);
        if (GetMenuItemCount(view) != 10)
            throw new InvalidOperationException("View menu changed during keyboard navigation.");
        IntPtr language = Child(view, 9);
        if (GetMenuItemCount(language) != 4)
            throw new InvalidOperationException("Language submenu changed during keyboard navigation.");
        MenuStage stage = new MenuStage {
            ThreadId = thread, ProcessId = processId, GuiFlags = gui.Flags,
            MenuOwner = gui.MenuOwner.ToInt64(), LanguageHandle = language.ToInt64(),
            ViewLanguageState = GetMenuState(view, 9, 0x400),
            Commands = new uint[4], States = new uint[4],
            TopStates = new uint[6], ViewStates = new uint[10]
        };
        if (stage.ViewLanguageState == UInt32.MaxValue)
            throw new InvalidOperationException("View Language item state is unreadable.");
        for (int index = 0; index < 6; index++) {
            stage.TopStates[index] = GetMenuState(bar, (uint)index, 0x400);
            if (stage.TopStates[index] == UInt32.MaxValue)
                throw new InvalidOperationException("Top-level menu item state is unreadable.");
        }
        for (int index = 0; index < 10; index++) {
            stage.ViewStates[index] = GetMenuState(view, (uint)index, 0x400);
            if (stage.ViewStates[index] == UInt32.MaxValue)
                throw new InvalidOperationException("View menu item state is unreadable.");
        }
        for (int index = 0; index < 4; index++) {
            stage.Commands[index] = GetMenuItemID(language, index);
            stage.States[index] = GetMenuState(language, (uint)index, 0x400);
            if (stage.Commands[index] != 0x9020 + index || stage.States[index] == UInt32.MaxValue)
                throw new InvalidOperationException("Language command or state changed during keyboard navigation.");
        }
        return stage;
    }
    public static string[] PreferredLanguages() {
        uint count, size = 0;
        if (!GetUserPreferredUILanguages(0x8, out count, null, ref size))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (size < 2 || size > 65536 || count > 4096)
            throw new InvalidOperationException("Windows preferred UI-language list exceeds its bound.");
        char[] buffer = new char[size];
        uint capacity = size;
        if (!GetUserPreferredUILanguages(0x8, out count, buffer, ref size))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (size < 2 || size > capacity || count > 4096 ||
            buffer[size - 1] != '\0' || buffer[size - 2] != '\0')
            throw new InvalidOperationException("Windows preferred UI-language list is malformed.");
        var tags = new System.Collections.Generic.List<string>();
        int start = 0;
        for (int index = 0; index < size - 1; index++) {
            if (buffer[index] == '\0') {
                if (index > start) tags.Add(new string(buffer, start, index - start));
                start = index + 1;
            }
        }
        if (tags.Count != count)
            throw new InvalidOperationException("Windows preferred UI-language count differs from its tags.");
        return tags.ToArray();
    }
}
'@
    [DarkReNamerLanguageMenuReader]::AssertInputLayout()
}

function Resolve-ProductionSystemLanguage {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Tags)
    foreach ($tag in $Tags) {
        if ($tag -match '^(ko|en|ja)(-|$)') {
            return [ordered]@{
                language = $Matches[1].ToLowerInvariant()
                selected_tag = $tag
                preferred_tags = @($Tags)
            }
        }
    }
    [ordered]@{ language = 'en'; selected_tag = $null; preferred_tags = @($Tags) }
}

function Read-ProductionLanguagePreference {
    param([Parameter(Mandatory)][string] $LocalAppData)
    $path = Join-Path (Join-Path $LocalAppData 'DarkReNamer') 'ui-language-v1'
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -ne 20) { throw 'The owned language preference is not an ordinary 20-byte record.' }
    $share = [IO.FileShare]([int][IO.FileShare]::ReadWrite -bor [int][IO.FileShare]::Delete)
    $bytes = [byte[]]::new(20)
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, $share)
    try {
        if ($stream.Length -ne 20) {
            throw 'The owned language preference is not an ordinary 20-byte record.'
        }
        $count = 0
        while ($count -lt $bytes.Length) {
            $read = $stream.Read($bytes, $count, $bytes.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -ne 20 -or $stream.ReadByte() -ne -1) {
            throw 'The owned language preference changed during its bounded read.'
        }
    }
    finally { $stream.Dispose() }
    if (
        [Text.Encoding]::ASCII.GetString($bytes, 0, 8) -cne "DRLANG`0`0" -or
        $bytes[8] -ne 1 -or $bytes[9] -ne 0 -or $bytes[10] -ne 0 -or $bytes[11] -ne 0 -or
        $bytes[13] -ne 0 -or $bytes[14] -ne 0 -or $bytes[15] -ne 0 -or
        $bytes[12] -gt 3) { throw 'The owned language preference has an invalid header.' }
    $hash = [uint32]2166136261
    foreach ($index in 0..15) {
        $hash = [uint32]((([uint64]($hash -bxor [uint32]$bytes[$index])) * [uint64]16777619) -band [uint64]4294967295)
    }
    if ([BitConverter]::ToUInt32($bytes, 16) -ne $hash) {
        throw 'The owned language preference checksum is invalid.'
    }
    $digest = [Security.Cryptography.SHA256]::HashData($bytes)
    [ordered]@{
        value = [int]$bytes[12]
        sha256 = [Convert]::ToHexString($digest).ToLowerInvariant()
    }
}

function Read-ProductionLanguageMenu {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][string] $Language
    )
    Initialize-ProductionLanguageMenuReader
    $labels = Get-ProductionLanguageSpec -Language $Language
    $handle = [IntPtr]$MainWindow.Current.NativeWindowHandle
    Assert-ExactApplicationMainWindowBinding -Process $Process -ExpectedSession $Session `
        -MainWindowHandle $handle -MainWindow $MainWindow -ExpectedClassName 'DarkReNamerWindow' `
        -ExpectedTitle 'DarkReNamer' -Label 'language menu owner'
    $items = [DarkReNamerLanguageMenuReader]::Read($handle)
    if ($items[0] -cne $labels.menu -or $items[1] -cne $labels.system -or
        $items[2] -cne '한국어' -or $items[3] -cne 'English' -or $items[4] -cne '日本語') {
        throw "Language menu text differs from $Language catalog."
    }
    [ordered]@{ parent = $items[0]; options = @($items[1..4]); checked_command = [int]$items[5] }
}

function Get-ProductionLanguageRail {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Language
    )
    $labels = Get-ProductionLanguageSpec -Language $Language
    $rail = Find-UniqueAutomationElement -Root $MainWindow -Process $Process `
        -ExpectedSession $Session -AutomationId ([string]0x8005) `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $TimeoutSeconds -Label "$Language prefix rail" -RequireWindowHandle
    $bounds = $rail.Current.BoundingRectangle
    $ownerBounds = $MainWindow.Current.BoundingRectangle
    if ($rail.Current.Name -cne $labels.rail -or $rail.Current.IsOffscreen -or
        $bounds.Width -le 0 -or $bounds.Height -le 0 -or
        $bounds.Width -gt 4096 -or $bounds.Height -gt 4096 -or
        $bounds.Left -lt $ownerBounds.Left -or $bounds.Top -lt $ownerBounds.Top -or
        $bounds.Right -gt $ownerBounds.Right -or $bounds.Bottom -gt $ownerBounds.Bottom) {
        throw "$Language prefix rail has unexpected accessible text or bounds."
    }
    [ordered]@{
        automation_id = [string]$rail.Current.AutomationId
        name = [string]$rail.Current.Name
        bounds = [ordered]@{ x = $bounds.X; y = $bounds.Y; width = $bounds.Width; height = $bounds.Height }
    }
}

function Assert-ProductionLanguageMenuForeground {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][int] $Session
    )
    Assert-AutomationBinding -Element $MainWindow -Process $Process `
        -ExpectedSession $Session -Label 'language menu owner' -RequireWindowHandle
    $foreground = Get-ForegroundObservation
    if ($foreground.hwnd -ne [long]$MainWindow.Current.NativeWindowHandle -or
        $foreground.process_id -ne $Process.Id -or
        $foreground.session_id -ne $Session -or
        $foreground.window_class -cne 'DarkReNamerWindow') {
        throw 'Language menu owner lost exact foreground process, window, or session binding.'
    }
}

function Get-ProductionLanguageKeyPacket {
    param([Parameter(Mandatory)][ValidateSet('language-mnemonic', 'down', 'enter')][string] $Action)
    switch ($Action) {
        'language-mnemonic' { return [ordered]@{ virtual_key = 0x4C; extended = $false } }
        'down'              { return [ordered]@{ virtual_key = 0x28; extended = $true } }
        'enter'             { return [ordered]@{ virtual_key = 0x0D; extended = $false } }
    }
}

function Send-ProductionLanguageNativeInput {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][ValidateSet('alt-v', 'language-mnemonic', 'down', 'enter')][string] $Action
    )
    Assert-ProductionLanguageMenuForeground -Process $Process -MainWindow $MainWindow -Session $Session
    if ($Action -ceq 'alt-v') {
        try {
            [DarkReNamerLanguageMenuReader]::KeyDown([uint16]0x12)
            [DarkReNamerLanguageMenuReader]::Tap([uint16]0x56)
        }
        finally {
            [DarkReNamerLanguageMenuReader]::KeyUp([uint16]0x12)
        }
        return
    }
    $packet = Get-ProductionLanguageKeyPacket -Action $Action
    if ($packet.extended) {
        [DarkReNamerLanguageMenuReader]::TapExtended([uint16]$packet.virtual_key)
    }
    else {
        [DarkReNamerLanguageMenuReader]::Tap([uint16]$packet.virtual_key)
    }
}

function Get-ProductionLanguageMenuStage {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][string] $Phase
    )
    Assert-ProductionLanguageMenuForeground -Process $Process -MainWindow $MainWindow -Session $Session
    $handle = [IntPtr]$MainWindow.Current.NativeWindowHandle
    $native = [DarkReNamerLanguageMenuReader]::Observe($handle, [uint32]$Process.Id)
    $popups = @([DarkReNamerVmNative]::ReadProcessTopLevelWindows([uint32]$Process.Id) |
        Where-Object { $_.Visible -and $_.ClassName -ceq '#32768' } |
        ForEach-Object {
            [ordered]@{
                hwnd = [long]$_.Handle; owner = [long]$_.Owner
                process_id = [int]$_.ProcessId; class = [string]$_.ClassName
                visible = [bool]$_.Visible
                bounds = [ordered]@{
                    left = [int]$_.Left; top = [int]$_.Top
                    right = [int]$_.Right; bottom = [int]$_.Bottom
                }
            }
        })
    if ($popups.Count -gt 2) { throw 'Language menu has more than two owned visible native popups.' }
    $states = @($native.States | ForEach-Object { [int64]$_ })
    $highlighted = @(0..3 | Where-Object { ($states[$_] -band 0x80) -ne 0 })
    [ordered]@{
        phase = $Phase; pid = [int]$native.ProcessId; session_id = [int]$Session
        hwnd = [long]$handle; thread_id = [long]$native.ThreadId
        menu_owner = [long]$native.MenuOwner; language_handle = [long]$native.LanguageHandle
        gui_flags = [long]$native.GuiFlags
        view_language_state = [long]$native.ViewLanguageState
        top_states = @($native.TopStates | ForEach-Object { [int64]$_ })
        view_states = @($native.ViewStates | ForEach-Object { [int64]$_ })
        popup_count = [int]$popups.Count
        popups = $popups
        commands = @($native.Commands | ForEach-Object { [int]$_ })
        states = $states
        highlighted_indices = $highlighted
    }
}

function Test-ProductionLanguageMenuStage {
    param(
        [Parameter(Mandatory)][object] $Stage,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][long] $ExpectedWindow,
        [int] $ExpectedHighlight = -1,
        [switch] $RequireViewLanguageHighlight
    )
    if ($Stage.pid -ne $ExpectedProcessId -or $Stage.session_id -ne $ExpectedSession -or
        $Stage.hwnd -ne $ExpectedWindow -or $Stage.menu_owner -ne $ExpectedWindow -or
        $Stage.thread_id -le 0 -or $Stage.language_handle -le 0 -or
        ($Stage.gui_flags -band 0x4) -ne 0x4 -or
        @($Stage.top_states).Count -ne 6 -or
        @($Stage.view_states).Count -ne 10 -or
        $Stage.view_states[9] -ne $Stage.view_language_state -or
        ($Stage.top_states[2] -band 0x80) -eq 0 -or
        $Stage.popup_count -ne @($Stage.popups).Count -or
        @($Stage.popups).Count -ne $(if ($Stage.phase -ceq 'alt-v') { 1 } else { 2 }) -or
        @($Stage.commands).Count -ne 4 -or
        (@($Stage.commands) -join ',') -cne '36896,36897,36898,36899' -or
        @($Stage.states).Count -ne 4) {
        return $false
    }
    foreach ($popup in $Stage.popups) {
        if ($popup.hwnd -le 0 -or $popup.process_id -ne $ExpectedProcessId -or
            $popup.class -cne '#32768' -or $popup.visible -ne $true -or
            $popup.bounds.right -le $popup.bounds.left -or
            $popup.bounds.bottom -le $popup.bounds.top -or
            ($popup.bounds.right - $popup.bounds.left) -gt 4096 -or
            ($popup.bounds.bottom - $popup.bounds.top) -gt 4096) {
            return $false
        }
    }
    if (@($Stage.popups).Count -eq 2 -and $Stage.popups[0].hwnd -eq $Stage.popups[1].hwnd) {
        return $false
    }
    if ($RequireViewLanguageHighlight -and ($Stage.view_language_state -band 0x80) -eq 0) {
        return $false
    }
    if ($ExpectedHighlight -ge 0) {
        if (@($Stage.highlighted_indices).Count -ne 1 -or
            $Stage.highlighted_indices[0] -ne $ExpectedHighlight -or
            ($Stage.states[$ExpectedHighlight] -band 0x3) -ne 0) {
            return $false
        }
    }
    $true
}

function Assert-ProductionLanguagePopupContinuity {
    param([Parameter(Mandatory)][object] $Open, [Parameter(Mandatory)][object] $Stage)
    $openHandles = @($Open.popups | ForEach-Object { [long]$_.hwnd } | Sort-Object)
    $stageHandles = @($Stage.popups | ForEach-Object { [long]$_.hwnd } | Sort-Object)
    if ($Stage.language_handle -ne $Open.language_handle -or
        $openHandles.Count -ne 2 -or $stageHandles.Count -ne 2 -or
        ($openHandles -join ',') -cne ($stageHandles -join ',')) {
        throw 'Language submenu or its exact owned native popup handles changed during navigation.'
    }
}

function Wait-ProductionLanguageMenuStage {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][string] $Phase,
        [int] $ExpectedHighlight = -1,
        [switch] $RequireViewLanguageHighlight
    )
    $handle = [long]$MainWindow.Current.NativeWindowHandle
    $deadline = (Get-Date).AddSeconds(3)
    $stage = $null
    do {
        $stage = Get-ProductionLanguageMenuStage -Process $Process -MainWindow $MainWindow `
            -Session $Session -Phase $Phase
        if (Test-ProductionLanguageMenuStage -Stage $stage -ExpectedProcessId $Process.Id `
            -ExpectedSession $Session -ExpectedWindow $handle `
            -ExpectedHighlight $ExpectedHighlight `
            -RequireViewLanguageHighlight:$RequireViewLanguageHighlight) {
            return $stage
        }
        Start-Sleep -Milliseconds 75
    } while ((Get-Date) -lt $deadline)
    $summary = $stage | ConvertTo-Json -Depth 3 -Compress
    if ($summary.Length -gt 2048) { $summary = $summary.Substring(0, 2048) }
    throw "Language menu $Phase did not reach its exact native stage: $summary"
}

function Get-ProductionLanguageChoiceObservation {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Status,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][string] $CurrentLanguage
    )
    $handle = [IntPtr]$MainWindow.Current.NativeWindowHandle
    Assert-ExactApplicationMainWindowBinding -Process $Process -ExpectedSession $Session `
        -MainWindowHandle $handle -MainWindow $MainWindow -ExpectedClassName 'DarkReNamerWindow' `
        -ExpectedTitle 'DarkReNamer' -Label 'language post-selection owner'
    Assert-AutomationBinding -Element $Status -Process $Process -ExpectedSession $Session `
        -Label 'language post-selection status' -RequireWindowHandle
    $message = [string]$Status.Current.Name
    if ($message.Length -gt 512) { $message = $message.Substring(0, 512) }
    $preference = $null
    $readError = $null
    try { $preference = Read-ProductionLanguagePreference -LocalAppData $env:LOCALAPPDATA }
    catch { $readError = [ordered]@{
        kind = $_.Exception.GetType().Name
        native_error = [int]($_.Exception.HResult -band 0xffff)
    } }
    $menu = $null
    $menuError = $null
    try {
        $menu = Read-ProductionLanguageMenu -Process $Process -MainWindow $MainWindow `
            -Session $Session -Language $CurrentLanguage
    }
    catch { $menuError = $_.Exception.GetType().Name }
    $modals = @([DarkReNamerVmNative]::ReadProcessTopLevelWindows([uint32]$Process.Id) |
        Where-Object { $_.Owner -eq [long]$handle -and $_.Visible -and
            $_.ClassName -ceq '#32770' } | Select-Object -First 4 | ForEach-Object {
            [ordered]@{ hwnd = [long]$_.Handle; class = [string]$_.ClassName
                title = ([string]$_.Title).Substring(0, [Math]::Min(128, ([string]$_.Title).Length)) }
        })
    [ordered]@{
        status = $message
        preference = $preference
        preference_read_error = $readError
        checked_command = if ($null -eq $menu) { $null } else { $menu.checked_command }
        menu_read_error = $menuError
        owned_modals = $modals
    }
}

function Get-ProductionLanguageModelSnapshot {
    param([Parameter(Mandatory)][Windows.Automation.GridPattern] $Grid)
    $rows = $Grid.Current.RowCount
    if ($rows -lt 0 -or $rows -gt 1 -or $Grid.Current.ColumnCount -lt 4) {
        throw 'Language model requires at most one owned row and four path/name columns.'
    }
    [ordered]@{
        rows = [int]$rows
        cells = @(
            if ($rows -eq 1) {
                0..3 | ForEach-Object { [string]$Grid.GetItem(0, $_).Current.Name }
            }
        )
    }
}

function Set-ProductionPendingPrefix {
    param(
        [Parameter(Mandatory)][object] $OwnedProcess,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][ValidateSet('ko', 'en', 'ja')][string] $Language
    )
    $process = $OwnedProcess.process
    $gridElement = Find-UniqueAutomationElement -Root $MainWindow -Process $process `
        -ExpectedSession $Session -AutomationId '1000' -TimeoutSeconds $TimeoutSeconds `
        -Label 'pending language model grid' -RequireWindowHandle
    $grid = [Windows.Automation.GridPattern]$gridElement.GetCurrentPattern(
        [Windows.Automation.GridPattern]::Pattern)
    $before = Get-ProductionLanguageModelSnapshot -Grid $grid
    if ($before.rows -ne 1) { throw 'Pending language selection requires the applied owned row.' }
    $button = Find-UniqueAutomationElement -Root $MainWindow -Process $process `
        -ExpectedSession $Session -AutomationId ([string]0x8005) `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $TimeoutSeconds -Label 'pending prefix command' `
        -RequireEnabled -RequireWindowHandle
    $invoke = Start-AutomationControlInvoke -OwnedProcess $OwnedProcess -Element $button `
        -Label 'pending prefix command'
    $labels = Get-ProductionLanguageSpec -Language $Language
    $prompt = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $Session `
        -MainWindowHandle $MainWindowHandle -Name $labels.prefix `
        -TimeoutSeconds $TimeoutSeconds -Label 'pending prefix prompt'
    $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
    $edit = Find-UniqueAutomationElement -Root $prompt -Process $process `
        -ExpectedSession $Session -AutomationId '1004' `
        -ControlType ([Windows.Automation.ControlType]::Edit) `
        -TimeoutSeconds $TimeoutSeconds -Label 'pending prefix edit' -RequireWindowHandle
    Set-AutomationControlValue -Element $edit -Value 'pending-' -Label 'pending prefix edit'
    $ok = Find-UniqueAutomationElement -Root $prompt -Process $process `
        -ExpectedSession $Session -AutomationId '1' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $TimeoutSeconds -Label 'pending prefix OK' `
        -RequireEnabled -RequireWindowHandle
    Invoke-AutomationControl -Element $ok -Label 'pending prefix OK'
    Wait-WindowClosed -Handle $promptHandle -TimeoutSeconds $TimeoutSeconds `
        -Label 'pending prefix prompt'
    Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $after = Get-ProductionLanguageModelSnapshot -Grid $grid
        if ($after.rows -eq 1 -and $after.cells[1] -cne $before.cells[1]) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($after.rows -ne 1 -or $after.cells[0] -cne $before.cells[0] -or
        $after.cells[2] -cne $before.cells[2] -or
        $after.cells[3] -cne $before.cells[3] -or
        $after.cells[1] -cne ('pending-' + $before.cells[1])) {
        throw 'Pending prefix did not create an exact unapplied name proposal.'
    }
    $after
}

function Invoke-ProductionLanguageMenuChoice {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][string] $CurrentLanguage,
        [Parameter(Mandatory)][ValidateSet('system', 'ko', 'en', 'ja')][string] $NextPreference,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [object] $PendingBefore
    )
    $before = Read-ProductionLanguageMenu -Process $Process -MainWindow $MainWindow `
        -Session $Session -Language $CurrentLanguage
    $target = if ($NextPreference -ceq 'system') { [int]0x9020 } else {
        (Get-ProductionLanguageSpec -Language $NextPreference).command
    }
    $grid = Find-UniqueAutomationElement -Root $MainWindow -Process $Process -ExpectedSession $Session `
        -AutomationId '1000' -TimeoutSeconds $TimeoutSeconds -Label 'language model grid' -RequireWindowHandle
    $rowsBefore = ([Windows.Automation.GridPattern]$grid.GetCurrentPattern(
        [Windows.Automation.GridPattern]::Pattern)).Current.RowCount
    $cellsBefore = Get-ProductionLanguageModelSnapshot -Grid ([Windows.Automation.GridPattern]$grid.GetCurrentPattern(
        [Windows.Automation.GridPattern]::Pattern))
    if ($null -ne $PendingBefore -and
        ($cellsBefore | ConvertTo-Json -Depth 4 -Compress) -cne
        ($PendingBefore | ConvertTo-Json -Depth 4 -Compress)) {
        throw 'Pending proposal changed before the language menu selection.'
    }
    $railBefore = Get-ProductionLanguageRail -Process $Process -MainWindow $MainWindow `
        -Session $Session -TimeoutSeconds $TimeoutSeconds -Language $CurrentLanguage
    $handle = [IntPtr]$MainWindow.Current.NativeWindowHandle
    $MainWindow.SetFocus()
    [void][DarkReNamerVmNative]::SetForegroundWindow($handle)
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
        throw 'Language menu owner is not the exact foreground application.'
    }
    Assert-ProductionLanguageMenuForeground -Process $Process -MainWindow $MainWindow -Session $Session
    $saved = $null
    $trace = [Collections.Generic.List[object]]::new()
    $postEnter = [Collections.Generic.List[object]]::new()
    $status = Find-UniqueAutomationElement -Root $MainWindow -Process $Process `
        -ExpectedSession $Session -AutomationId '1007' `
        -ControlType ([Windows.Automation.ControlType]::Text) `
        -TimeoutSeconds $TimeoutSeconds -Label 'language save status' -RequireWindowHandle
    $statusBefore = [string]$status.Current.Name
    if ($statusBefore.Length -gt 512) { $statusBefore = $statusBefore.Substring(0, 512) }
    Send-ProductionLanguageNativeInput -Process $Process -MainWindow $MainWindow `
        -Session $Session -Action 'alt-v'
    $viewOpen = Wait-ProductionLanguageMenuStage -Process $Process -MainWindow $MainWindow `
        -Session $Session -Phase 'alt-v'
    $trace.Add($viewOpen)
    # Win32 standard menu keys include access keys and arrows, not End/Home:
    # https://learn.microsoft.com/en-us/windows/win32/menurc/about-menus
    Send-ProductionLanguageNativeInput -Process $Process -MainWindow $MainWindow `
        -Session $Session -Action 'language-mnemonic'
    $languageOpen = Wait-ProductionLanguageMenuStage -Process $Process -MainWindow $MainWindow `
        -Session $Session -Phase 'language-open' -RequireViewLanguageHighlight -ExpectedHighlight 0
    if ($languageOpen.language_handle -ne $viewOpen.language_handle -or
        @($languageOpen.popups | Where-Object { $_.hwnd -eq $viewOpen.popups[0].hwnd }).Count -ne 1) {
        throw 'Language mnemonic opened a different native View menu.'
    }
    $trace.Add($languageOpen)
    $current = 0
    $step = 0
    while ($current -ne ($target - 0x9020)) {
        if ($step -ge 4) { throw 'Language submenu navigation exceeded four native Down inputs.' }
        $next = ($current + 1) % 4
        $step++
        Send-ProductionLanguageNativeInput -Process $Process -MainWindow $MainWindow `
            -Session $Session -Action 'down'
        $moved = Wait-ProductionLanguageMenuStage -Process $Process -MainWindow $MainWindow `
            -Session $Session -Phase "down-$step" -ExpectedHighlight $next
        Assert-ProductionLanguagePopupContinuity -Open $languageOpen -Stage $moved
        $trace.Add($moved)
        $current = $next
    }
    $preEnter = Wait-ProductionLanguageMenuStage -Process $Process -MainWindow $MainWindow `
        -Session $Session -Phase 'pre-enter' -ExpectedHighlight ($target - 0x9020)
    Assert-ProductionLanguagePopupContinuity -Open $languageOpen -Stage $preEnter
    $trace.Add($preEnter)
    Send-ProductionLanguageNativeInput -Process $Process -MainWindow $MainWindow `
        -Session $Session -Action 'enter'
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $observation = Get-ProductionLanguageChoiceObservation -Process $Process `
            -MainWindow $MainWindow -Status $status -Session $Session `
            -CurrentLanguage $CurrentLanguage
        if ($postEnter.Count -eq 0 -or
            ($postEnter[$postEnter.Count - 1] | ConvertTo-Json -Depth 5 -Compress) -cne
            ($observation | ConvertTo-Json -Depth 5 -Compress)) {
            if ($postEnter.Count -ge 16) { $postEnter.RemoveAt(0) }
            $postEnter.Add($observation)
        }
        $saved = $observation.preference
        if ($null -ne $saved -and $saved.value -eq ($target - 0x9020)) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $saved -or $saved.value -ne ($target - 0x9020)) {
        $diagnostic = [ordered]@{
            target = [int]$target; input_trace = $trace.ToArray()
            status_before = $statusBefore; post_enter = $postEnter.ToArray()
        } | ConvertTo-Json -Depth 7 -Compress
        if ($diagnostic.Length -gt 8192) { $diagnostic = $diagnostic.Substring(0, 8192) }
        throw "Language preference was not durably saved after the real menu selection: $diagnostic"
    }
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        Assert-ProductionLanguageMenuForeground -Process $Process -MainWindow $MainWindow -Session $Session
        $after = Read-ProductionLanguageMenu -Process $Process -MainWindow $MainWindow `
            -Session $Session -Language $CurrentLanguage
        if ($after.parent -cne $before.parent -or
            ($after.options | ConvertTo-Json -Compress) -cne
            ($before.options | ConvertTo-Json -Compress)) {
            throw 'Language menu changed visible current-language labels before restart.'
        }
        if ($after.checked_command -eq $target) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    $Process.Refresh()
    $railAfter = Get-ProductionLanguageRail -Process $Process -MainWindow $MainWindow `
        -Session $Session -TimeoutSeconds $TimeoutSeconds -Language $CurrentLanguage
    $rowsAfter = ([Windows.Automation.GridPattern]$grid.GetCurrentPattern(
        [Windows.Automation.GridPattern]::Pattern)).Current.RowCount
    $cellsAfter = Get-ProductionLanguageModelSnapshot -Grid ([Windows.Automation.GridPattern]$grid.GetCurrentPattern(
        [Windows.Automation.GridPattern]::Pattern))
    if ($Process.HasExited -or $after.checked_command -ne $target -or
        $rowsAfter -ne $rowsBefore -or $railAfter.name -cne $railBefore.name -or
        ($cellsAfter | ConvertTo-Json -Depth 4 -Compress) -cne
        ($cellsBefore | ConvertTo-Json -Depth 4 -Compress)) {
        throw 'Language choice restarted the application, reset the model, or changed the current UI.'
    }
    [ordered]@{
        input = 'native-menu-keyboard'; pid = [int]$Process.Id; session_id = [int]$Session
        hwnd = [long]$handle; before = $before; after = $after
        model_rows_before = [int]$rowsBefore; model_rows_after = [int]$rowsAfter
        model_before = $cellsBefore; model_after = $cellsAfter
        rail_before = $railBefore; rail_after = $railAfter
        preference = $saved
        input_trace = $trace.ToArray(); status_before = $statusBefore
        post_enter = $postEnter.ToArray()
    }
}

function Get-ProductionJournalCheckpoint {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][long] $MinimumBytes,
        [switch] $LiveJournal
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt $MinimumBytes -or $item.Length -gt 64MB) {
        throw 'Retained journal is not one bounded ordinary file.'
    }
    $identityHash = Get-LowerTextSha256 -Value ([DarkReNamerVmNative]::GetFileIdentity($item.FullName))
    if (-not $LiveJournal) {
        return [ordered]@{
            bytes = [long]$item.Length
            sha256 = Get-LowerSha256 -Path $item.FullName
            file_identity_sha256 = $identityHash
        }
    }
    $stream = $null
    $probeShare = [IO.FileShare]([int][IO.FileShare]::ReadWrite -bor [int][IO.FileShare]::Delete)
    try {
        $stream = [IO.FileStream]::new($item.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, $probeShare)
        throw 'Live retained journal unexpectedly allowed a content read handle.'
    }
    catch [IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -ne 32) {
            throw 'Live retained journal content read failed for a reason other than sharing violation 32.'
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    [ordered]@{
        bytes = [long]$item.Length
        file_identity_sha256 = $identityHash
        content_read_status = 'sharing-denied'
        native_error = 32
        probe_access = 'read'
        probe_share_mode = 'read-write-delete'
    }
}

function Assert-ProductionLiveJournalCheckpoint {
    param([Parameter(Mandatory)][object] $Expected,
          [Parameter(Mandatory)][object] $Actual)
    if ($Actual.bytes -ne $Expected.bytes -or
        $Actual.file_identity_sha256 -cne $Expected.file_identity_sha256 -or
        $Actual.content_read_status -cne 'sharing-denied' -or $Actual.native_error -ne 32 -or
        $Actual.probe_access -cne 'read' -or
        $Actual.probe_share_mode -cne 'read-write-delete' -or
        $Actual.Contains('sha256')) {
        throw 'Live retained journal metadata or exclusive content lock changed.'
    }
}

function Get-ProductionBlockedRecoveryJournalCheckpoint {
    param(
        [Parameter(Mandatory)][string] $JournalRoot,
        [switch] $LiveJournal
    )
    $root = Get-Item -LiteralPath $JournalRoot -Force -ErrorAction Stop
    $entries = @(Get-ChildItem -LiteralPath $JournalRoot -Force)
    $active = @($entries | Where-Object Name -ceq 'active.drj')
    $others = @($entries | Where-Object Name -cne 'active.drj')
    if (-not $root.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $active.Count -ne 1 -or $others.Count -gt 1 -or
        ($others.Count -eq 1 -and ($others[0].Name -cne 'runtime.lock' -or
            $others[0].PSIsContainer -or
            ($others[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $others[0].Length -ne 0))) {
        throw 'Blocked recovery journal inventory changed.'
    }
    Get-ProductionJournalCheckpoint -Path $active[0].FullName -MinimumBytes 1 `
        -LiveJournal:$LiveJournal
}

function Invoke-ProductionBlockedRecoveryCheck {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][ValidateSet('ko', 'en', 'ja')][string] $Language
    )
    $labels = Get-ProductionLanguageSpec -Language $Language
    $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
    $journal = Get-Item -LiteralPath $journalRoot -Force -ErrorAction Stop
    $journalEntries = @(Get-ChildItem -LiteralPath $journalRoot -Force)
    if (-not $journal.PSIsContainer -or
        ($journal.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $journalEntries.Count -gt 1 -or
        ($journalEntries.Count -eq 1 -and (
            $journalEntries[0].Name -cne 'runtime.lock' -or $journalEntries[0].PSIsContainer -or
            ($journalEntries[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $journalEntries[0].Length -ne 0))) {
        throw 'Blocked recovery requires a task-isolated journal root with no prior transaction.'
    }
    $activePath = Join-Path $journalRoot 'active.drj'
    $marker = [Text.Encoding]::ASCII.GetBytes('DarkReNamer bounded invalid active journal fixture')
    [IO.File]::WriteAllBytes($activePath, $marker)
    $beforeCheckpoint = Get-ProductionBlockedRecoveryJournalCheckpoint -JournalRoot $journalRoot
    $before = $beforeCheckpoint.sha256
    $identity = [DarkReNamerVmNative]::GetFileIdentity($activePath)
    $owned = $null
    $passed = $false
    try {
        $applicationPath = Join-Path $Root $Application.file
        if ((Get-LowerSha256 -Path $applicationPath) -cne $Application.sha256) {
            throw 'Blocked recovery application changed after source-bound preflight.'
        }
        $owned = Start-JobBoundProcess -FilePath $applicationPath -Arguments '' -WorkingDirectory $Root
        $process = $owned.process
        $binding = Wait-ExactApplicationMainWindow -Process $process -ExpectedSession $Session `
            -ExpectedClassName 'DarkReNamerWindow' -ExpectedTitle 'DarkReNamer' `
            -TimeoutSeconds $TimeoutSeconds -Label "$Language blocked recovery startup"
        $main = $binding.element
        $handle = [IntPtr]$binding.handle
        $notice = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $Session `
            -MainWindowHandle $handle -Name $labels.recovery -TimeoutSeconds $TimeoutSeconds `
            -Label "$Language blocked recovery notice"
        $noticeHandle = [IntPtr]$notice.Current.NativeWindowHandle
        $bounds = $notice.Current.BoundingRectangle
        if ($bounds.Width -le 0 -or $bounds.Height -le 0 -or
            $bounds.Width -gt 16384 -or $bounds.Height -gt 16384) {
            throw "$Language blocked recovery notice has invalid bounds."
        }
        $children = $notice.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.Condition]::TrueCondition)
        if ($children.Count -gt 512) { throw 'Blocked recovery notice tree exceeds its bound.' }
        $names = [Collections.Generic.List[string]]::new()
        foreach ($element in $children) {
            if ($element.Current.ProcessId -eq $process.Id -and $element.Current.Name) {
                $names.Add([string]$element.Current.Name)
            }
        }
        $copy = [string]::Join("`n", $names)
        if ($copy.Length -gt 32768 -or
            $copy.IndexOf('active.drj', [StringComparison]::Ordinal) -lt 0 -or
            $copy.IndexOf($labels.recovery_locked, [StringComparison]::Ordinal) -lt 0) {
            throw "$Language blocked recovery notice lost its localized lock guidance."
        }
        $captureObservations = [Collections.Generic.List[object]]::new()
        $noticeCapture = Save-WindowScreenshot -Window $notice -Process $process `
            -ExpectedSession $Session -Root $OutputRoot `
            -Leaf "$Language-blocked-recovery.png" `
            -Label "$Language blocked recovery notice" `
            -ForegroundObservations $captureObservations
        Set-ProductionCaptureByteCount -Capture $noticeCapture -Root $OutputRoot
        $ok = Find-ProductionMessageBoxOk -Window $notice -Process $process `
            -ExpectedSession $Session -TimeoutSeconds $TimeoutSeconds `
            -Label "$Language recovery notice OK"
        Invoke-AutomationControl -Element $ok.element -Label "$Language recovery notice OK"
        Wait-WindowClosed -Handle $noticeHandle -TimeoutSeconds $TimeoutSeconds `
            -Label "$Language blocked recovery notice"
        $apply = Find-UniqueAutomationElement -Root $main -Process $process -ExpectedSession $Session `
            -AutomationId ([string]0x8003) -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds -Label "$Language recovery-locked Apply" -RequireWindowHandle
        $grid = Find-UniqueAutomationElement -Root $main -Process $process -ExpectedSession $Session `
            -AutomationId '1000' -TimeoutSeconds $TimeoutSeconds -Label "$Language recovery-locked model" `
            -RequireWindowHandle
        $rows = ([Windows.Automation.GridPattern]$grid.GetCurrentPattern(
            [Windows.Automation.GridPattern]::Pattern)).Current.RowCount
        $liveCheckpoint = Get-ProductionBlockedRecoveryJournalCheckpoint `
            -JournalRoot $journalRoot -LiveJournal
        Assert-ProductionLiveJournalCheckpoint -Expected $beforeCheckpoint -Actual $liveCheckpoint
        if ($apply.Current.IsEnabled -or $rows -ne 0) {
            throw "$Language blocked recovery changed the retained journal or unlocked Apply."
        }
        Close-ExactApplicationMainWindow -Process $process -ExpectedSession $Session `
            -MainWindowHandle $handle -MainWindow $main -ExpectedClassName 'DarkReNamerWindow' `
            -ExpectedTitle 'DarkReNamer' -Label "$Language blocked recovery normal close"
        if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) {
            throw "$Language blocked recovery application did not close normally."
        }
        $job = Complete-AcceptanceOwnedProcessJob -Owned $owned
        $afterCloseCheckpoint = Get-ProductionBlockedRecoveryJournalCheckpoint -JournalRoot $journalRoot
        if ($job.status -cne 'clean' -or -not $job.job_empty -or -not $job.job_closed -or
            ($afterCloseCheckpoint | ConvertTo-Json -Compress) -cne
                ($beforeCheckpoint | ConvertTo-Json -Compress)) {
            throw "$Language blocked recovery did not retain exact journal bytes on close."
        }
        $passed = $true
        [ordered]@{
            language = $Language; pid = [int]$process.Id; session_id = [int]$Session
            hwnd = [long]$handle; title = $labels.recovery
            notice_hwnd = [long]$noticeHandle
            lock_guidance = $labels.recovery_locked
            ok_control = [ordered]@{
                selection_contract = $ok.selection_contract
                native_button_count = $ok.native_button_count
                automation_id = $ok.automation_id; native_control_id = $ok.native_control_id
                native_parent_bound = $ok.native_parent_bound; native_class = $ok.native_class
                enabled = $ok.enabled
            }
            notice_bounds = [ordered]@{ width = $bounds.Width; height = $bounds.Height }
            notice_capture = $noticeCapture
            notice_capture_foreground = $captureObservations[0]
            apply_enabled = $false; model_rows = [int]$rows
            journal_sha256 = $before; journal_unchanged = $true
            journal_before = $beforeCheckpoint
            journal_live = $liveCheckpoint
            journal_after_close = $afterCloseCheckpoint
            normal_close = $true; process_job_clean = $true
        }
    }
    finally {
        if ($null -ne $owned) {
            try {
                if (-not $owned.job_closed) {
                    $cleanup = Complete-AcceptanceOwnedProcessJob -Owned $owned -StopActive
                    if ($cleanup.status -cne 'clean' -or -not $cleanup.job_empty -or -not $cleanup.job_closed) {
                        throw 'Blocked recovery process job cleanup failed.'
                    }
                }
            }
            finally { $owned.process.Dispose() }
        }
        if ($passed) {
            $active = Get-Item -LiteralPath $activePath -Force -ErrorAction Stop
            if ($active.PSIsContainer -or
                ($active.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                (Get-LowerSha256 -Path $activePath) -cne $before -or
                [DarkReNamerVmNative]::GetFileIdentity($activePath) -cne $identity) {
                throw 'Owned corrupt journal changed before exact cleanup.'
            }
            Remove-Item -LiteralPath $activePath -Force
            if (Test-Path -LiteralPath $activePath) { throw 'Owned corrupt journal cleanup was incomplete.' }
        }
    }
}

function Get-ProductionValidActiveCheckpoint {
    param([Parameter(Mandatory)][string] $FixtureRoot,
          [switch] $LiveJournal)
    $work = Join-Path (Join-Path $FixtureRoot 'data') 'work'
    $workItem = Get-Item -LiteralPath $work -Force -ErrorAction Stop
    if (-not $workItem.PSIsContainer -or
        ($workItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Valid-active data root is not an ordinary owned directory.'
    }
    $items = @(Get-ChildItem -LiteralPath $work -Force | Sort-Object Name)
    if ($items.Count -ne 3) { throw 'Valid-active swap fixture lost its three files.' }
    $files = @($items | ForEach-Object {
        if ($_.PSIsContainer -or $_ -isnot [IO.FileInfo] -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $_.Name.Length -gt 160 -or $_.Length -gt 64) {
            throw 'Valid-active swap fixture has an unsafe file.'
        }
        [ordered]@{
            name = [string]$_.Name
            bytes = [long]$_.Length
            content_sha256 = Get-LowerSha256 -Path $_.FullName
            file_identity_sha256 = Get-LowerTextSha256 -Value ([DarkReNamerVmNative]::GetFileIdentity($_.FullName))
        }
    })
    $journalRoot = Join-Path (Join-Path $FixtureRoot 'DarkReNamer') 'journal'
    $entries = @(Get-ChildItem -LiteralPath $journalRoot -Force)
    $others = @($entries | Where-Object Name -cne 'active.drj')
    if ($others.Count -gt 1 -or
        ($others.Count -eq 1 -and ($others[0].Name -cne 'runtime.lock' -or
            $others[0].PSIsContainer -or $others[0].Length -ne 0 -or
            ($others[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) -or
        @($entries | Where-Object Name -ceq 'active.drj').Count -ne 1 -or
        (Test-Path -LiteralPath (Join-Path $journalRoot 'candidate.drj'))) {
        throw 'Valid-active fixture has an unexpected journal inventory.'
    }
    [ordered]@{
        files = $files
        journal = Get-ProductionJournalCheckpoint -Path (Join-Path $journalRoot 'active.drj') `
            -MinimumBytes 24 -LiveJournal:$LiveJournal
    }
}

function Assert-ProductionValidActiveCheckpoint {
    param([Parameter(Mandatory)][object] $Expected,
          [Parameter(Mandatory)][object] $Actual)
    if (($Expected | ConvertTo-Json -Depth 8 -Compress) -cne
        ($Actual | ConvertTo-Json -Depth 8 -Compress)) {
        throw 'Valid-active startup or default Cancel changed partial files or retained journal.'
    }
}

function Assert-ProductionValidActiveLiveCheckpoint {
    param([Parameter(Mandatory)][object] $Expected,
          [Parameter(Mandatory)][object] $Actual)
    if (($Expected.files | ConvertTo-Json -Depth 8 -Compress) -cne
        ($Actual.files | ConvertTo-Json -Depth 8 -Compress)) {
        throw 'Valid-active live startup changed partial swap files.'
    }
    Assert-ProductionLiveJournalCheckpoint -Expected $Expected.journal -Actual $Actual.journal
}

function Get-ProductionCrashChildEnvironmentSnapshot {
    $current = [Environment]::GetEnvironmentVariables('Process')
    $saved = [ordered]@{}
    foreach ($name in @(
        'DARKRENAMER_TEST_CHILD_MODE', 'DARKRENAMER_TEST_CHILD_ROOT',
        'DARKRENAMER_TEST_FIXTURE_NONCE', 'DARKRENAMER_TEST_GRAPH',
        'DARKRENAMER_TEST_CRASH_POINT', 'DARKRENAMER_TEST_FORCE_ROLLBACK',
        'DARKRENAMER_TEST_FAILURE_ROLLBACK', 'DARKRENAMER_TEST_RECOVERY_MODE'
    )) {
        $present = $current.Contains($name)
        $saved[$name] = [ordered]@{
            present = $present
            value = if ($present) { [string]$current[$name] } else { $null }
        }
    }
    $saved
}

function Clear-ProductionCrashChildOptionalFlags {
    foreach ($name in @(
        'DARKRENAMER_TEST_FORCE_ROLLBACK', 'DARKRENAMER_TEST_FAILURE_ROLLBACK',
        'DARKRENAMER_TEST_RECOVERY_MODE'
    )) {
        [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        if ([Environment]::GetEnvironmentVariables('Process').Contains($name)) {
            throw "Crash child optional flag $name remains present."
        }
    }
}

function Restore-ProductionCrashChildEnvironmentSnapshot {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Snapshot)
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($name in $Snapshot.Keys) {
        try {
            if ($Snapshot[$name].present) {
                [Environment]::SetEnvironmentVariable($name, $Snapshot[$name].value, 'Process')
            }
            else {
                [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
            }
            $restored = [Environment]::GetEnvironmentVariables('Process')
            if ($restored.Contains($name) -ne $Snapshot[$name].present -or
                ($Snapshot[$name].present -and
                    [string]$restored[$name] -cne $Snapshot[$name].value)) {
                throw 'The original presence or value was not restored.'
            }
        }
        catch { $errors.Add("$name restore: $($_.Exception.Message)") }
    }
    if ($errors.Count -gt 0) {
        throw ('Crash child environment restoration failed: ' +
            [string]::Join(' | ', $errors))
    }
}

function Invoke-ProductionValidActiveRecoveryCheck {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $TestBinary,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )
    if ($TestBinary.name -cne 'darknamer_app' -or
        $TestBinary.file -cnotmatch '^darknamer_app-[0-9a-f]{16}\.exe$') {
        throw 'Valid-active crash child requires the manifest-bound app library test binary.'
    }
    $binaryPath = Join-Path $Root $TestBinary.file
    Assert-OrdinaryFile -Path $binaryPath -Label 'valid-active crash child binary'
    if ((Get-LowerSha256 -Path $binaryPath) -cne $TestBinary.sha256) {
        throw 'Valid-active crash child differs from its verified bundle digest.'
    }
    $fixtureRoot = New-PrivateDirectory -Parent $env:TEMP -Leaf 'valid-active-language'
    $dataRoot = New-PrivateDirectory -Parent $fixtureRoot -Leaf 'data'
    $work = New-PrivateDirectory -Parent $dataRoot -Leaf 'work'
    foreach ($item in @(
        @{ name='a.txt'; content='entry-a' },
        @{ name='b.txt'; content='entry-b' },
        @{ name='sentinel.txt'; content='sentinel-work' }
    )) {
        [IO.File]::WriteAllBytes((Join-Path $work $item.name),
            [Text.Encoding]::ASCII.GetBytes($item.content))
    }
    $originalContentHashes = @(@('a.txt', 'b.txt', 'sentinel.txt') |
        ForEach-Object { Get-LowerSha256 -Path (Join-Path $work $_) } | Sort-Object)
    $nonce = [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'fixture-nonce.txt'),
        $nonce, [Text.UTF8Encoding]::new($false))
    $originalLocalAppData = $env:LOCALAPPDATA
    $originalChildVariables = Get-ProductionCrashChildEnvironmentSnapshot
    $child = $null
    $fullyVerified = $false
    $observations = [Collections.Generic.List[object]]::new()
    try {
        $env:LOCALAPPDATA = $fixtureRoot
        [Environment]::SetEnvironmentVariable('DARKRENAMER_TEST_CHILD_MODE', '1', 'Process')
        [Environment]::SetEnvironmentVariable('DARKRENAMER_TEST_CHILD_ROOT', $fixtureRoot, 'Process')
        [Environment]::SetEnvironmentVariable('DARKRENAMER_TEST_FIXTURE_NONCE', $nonce, 'Process')
        [Environment]::SetEnvironmentVariable('DARKRENAMER_TEST_GRAPH', 'swap', 'Process')
        [Environment]::SetEnvironmentVariable('DARKRENAMER_TEST_CRASH_POINT', 'forward-completed-0', 'Process')
        $stdoutPath = Join-Path $fixtureRoot 'crash-child.stdout.txt'
        $stderrPath = Join-Path $fixtureRoot 'crash-child.stderr.txt'
        $arguments = '--exact windows::tests::crash_recovery_child --nocapture --test-threads=1'
        Clear-ProductionCrashChildOptionalFlags
        $child = Start-JobBoundProcess -FilePath $binaryPath -Arguments $arguments `
            -WorkingDirectory $Root -StdoutPath $stdoutPath -StderrPath $stderrPath `
            -SingleProcessOnly -AggregateOutputLimitBytes 65536
        $childStart = [string]$child.process_start_time_utc_ticks
        $childPid = [int]$child.process.Id
        $wait = Wait-JobBoundProcessWithOutputLimit -State $child `
            -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds
        if ($null -ne $wait.failure_reason -or $child.process.ExitCode -ne 86 -or
            $child.job_had_survivors -or $child.job_forced_termination) {
            throw 'Source-built crash child did not exit at the exact durable forward step.'
        }
        $job = Complete-AcceptanceOwnedProcessJob -Owned $child
        if ($job.status -cne 'clean' -or -not $job.job_empty -or -not $job.job_closed -or
            $job.had_survivors -or $job.forced_termination) {
            throw 'Source-built crash child Job did not close cleanly.'
        }
        $childRecord = [ordered]@{
            test_name = 'windows::tests::crash_recovery_child'
            test_file = $TestBinary.file; test_sha256 = $TestBinary.sha256
            arguments = $arguments; graph = 'swap'; crash_point = 'forward-completed-0'
            exit_code = 86; pid = $childPid; process_start_time_utc_ticks = $childStart
            exit_semantics = 'expected-abrupt-crash-point'; single_process_job = $true
            job_clean = $true; job_had_survivors = $false; job_forced_termination = $false
        }
        Restore-ProductionCrashChildEnvironmentSnapshot -Snapshot $originalChildVariables
        $partial = Get-ProductionValidActiveCheckpoint -FixtureRoot $fixtureRoot
        $contentHashes = @($partial.files | ForEach-Object { $_.content_sha256 } | Sort-Object)
        $partialNames = @($partial.files | ForEach-Object { $_.name })
        if (($contentHashes -join ',') -cne ($originalContentHashes -join ',') -or
            @($partialNames | Where-Object { $_ -ceq 'sentinel.txt' }).Count -ne 1 -or
            @($partialNames | Where-Object { $_ -cin @('a.txt', 'b.txt') }).Count -ne 1 -or
            @($partialNames | Where-Object {
                $_ -cmatch '^\.__darknamer_[0-9a-f]{16}_[0-9a-f]{32}_[0-9a-f]{8}_[0-9a-f]{2}\.tmp$'
            }).Count -ne 1) {
            throw 'Crash child did not leave an authentic partial swap file state.'
        }
        foreach ($step in @(
            @{ language='ko'; preference=0; next='en' },
            @{ language='en'; preference=2; next='ja' },
            @{ language='ja'; preference=3; next=$null }
        )) {
            $owned = $null
            try {
                if ((Get-LowerSha256 -Path (Join-Path $Root $Application.file)) -cne $Application.sha256) {
                    throw 'Valid-active application changed after source-bound preflight.'
                }
                $before = Get-ProductionValidActiveCheckpoint -FixtureRoot $fixtureRoot
                Assert-ProductionValidActiveCheckpoint -Expected $partial -Actual $before
                $owned = Start-JobBoundProcess -FilePath (Join-Path $Root $Application.file) `
                    -Arguments '' -WorkingDirectory $Root -SingleProcessOnly
                $process = $owned.process
                $binding = Wait-ExactApplicationMainWindow -Process $process -ExpectedSession $Session `
                    -ExpectedClassName 'DarkReNamerWindow' -ExpectedTitle 'DarkReNamer' `
                    -TimeoutSeconds $TimeoutSeconds -Label "$($step.language) valid-active startup"
                $main = $binding.element
                $mainHandle = [IntPtr]$binding.handle
                $labels = Get-ProductionLanguageSpec -Language $step.language
                $notice = Wait-UniqueAutomationWindow -Process $process -ExpectedSession $Session `
                    -MainWindowHandle $mainHandle -Name $labels.recovery_confirm `
                    -TimeoutSeconds $TimeoutSeconds -Label "$($step.language) active recovery confirmation"
                $noticeHandle = [IntPtr]$notice.Current.NativeWindowHandle
                $noticeBounds = $notice.Current.BoundingRectangle
                if ($noticeBounds.Width -le 0 -or $noticeBounds.Height -le 0 -or
                    $noticeBounds.Width -gt 16384 -or $noticeBounds.Height -gt 16384) {
                    throw 'Active recovery confirmation has invalid window bounds.'
                }
                $saved = Read-ProductionLanguagePreference -LocalAppData $env:LOCALAPPDATA
                if ($saved.value -ne $step.preference) {
                    throw 'Valid-active startup did not reload its selected language.'
                }
                $children = $notice.FindAll([Windows.Automation.TreeScope]::Descendants,
                    [Windows.Automation.Condition]::TrueCondition)
                if ($children.Count -gt 512) { throw 'Active recovery confirmation tree exceeds its bound.' }
                $names = @($children | Where-Object { $_.Current.ProcessId -eq $process.Id -and $_.Current.Name } |
                    ForEach-Object { [string]$_.Current.Name })
                $copy = [string]::Join("`n", $names)
                if ($copy.Length -gt 32768 -or
                    $copy.IndexOf($labels.recovery_question, [StringComparison]::Ordinal) -lt 0 -or
                    $copy.IndexOf($labels.recovery_detail, [StringComparison]::Ordinal) -lt 0) {
                    throw 'Active recovery confirmation lost its localized question or Cancel safety guidance.'
                }
                $cancel = Find-UniqueAutomationElement -Root $notice -Process $process `
                    -ExpectedSession $Session -AutomationId 'CommandButton_2' `
                    -ControlType ([Windows.Automation.ControlType]::Button) `
                    -TimeoutSeconds $TimeoutSeconds -Label "$($step.language) recovery default Cancel" `
                    -RequireEnabled -RequireWindowHandle
                $foreground = [Collections.Generic.List[object]]::new()
                $capture = Save-WindowScreenshot -Window $notice -Process $process `
                    -ExpectedSession $Session -Root $OutputRoot `
                    -Leaf "$($step.language)-valid-active-recovery.png" `
                    -Label "$($step.language) valid-active recovery confirmation" `
                    -ForegroundObservations $foreground
                Set-ProductionCaptureByteCount -Capture $capture -Root $OutputRoot
                Assert-AutomationBinding -Element $cancel -Process $process `
                    -ExpectedSession $Session -Label 'recovery default Cancel after foreground capture' `
                    -RequireWindowHandle
                if (-not $cancel.Current.HasKeyboardFocus) {
                    throw 'Active recovery Cancel was not the default focused choice.'
                }
                $cancelBounds = $cancel.Current.BoundingRectangle
                if ($cancelBounds.Width -le 0 -or $cancelBounds.Height -le 0 -or
                    $cancelBounds.Left -lt $noticeBounds.Left -or
                    $cancelBounds.Top -lt $noticeBounds.Top -or
                    $cancelBounds.Right -gt $noticeBounds.Right -or
                    $cancelBounds.Bottom -gt $noticeBounds.Bottom) {
                    throw 'Active recovery default Cancel is clipped or outside its dialog.'
                }
                $atStartup = Get-ProductionValidActiveCheckpoint -FixtureRoot $fixtureRoot -LiveJournal
                Assert-ProductionValidActiveLiveCheckpoint -Expected $partial -Actual $atStartup
                Invoke-AutomationControl -Element $cancel -Label "$($step.language) recovery default Cancel"
                Wait-WindowClosed -Handle $noticeHandle -TimeoutSeconds $TimeoutSeconds `
                    -Label "$($step.language) active recovery confirmation"
                $afterCancel = Get-ProductionValidActiveCheckpoint -FixtureRoot $fixtureRoot -LiveJournal
                Assert-ProductionValidActiveLiveCheckpoint -Expected $partial -Actual $afterCancel
                $apply = Find-UniqueAutomationElement -Root $main -Process $process `
                    -ExpectedSession $Session -AutomationId ([string]0x8003) `
                    -ControlType ([Windows.Automation.ControlType]::Button) `
                    -TimeoutSeconds $TimeoutSeconds -Label "$($step.language) recovery-locked Apply" `
                    -RequireWindowHandle
                if ($apply.Current.IsEnabled) { throw 'Default Cancel unlocked Apply.' }
                $choice = if ($null -eq $step.next) { $null } else {
                    Invoke-ProductionLanguageMenuChoice -Process $process -MainWindow $main `
                        -Session $Session -CurrentLanguage $step.language `
                        -NextPreference $step.next -TimeoutSeconds $TimeoutSeconds
                }
                if ($apply.Current.IsEnabled) {
                    throw 'Language selection enabled Apply while valid-active recovery remained pending.'
                }
                $afterChoice = Get-ProductionValidActiveCheckpoint -FixtureRoot $fixtureRoot -LiveJournal
                Assert-ProductionValidActiveLiveCheckpoint -Expected $partial -Actual $afterChoice
                Close-ExactApplicationMainWindow -Process $process -ExpectedSession $Session `
                    -MainWindowHandle $mainHandle -MainWindow $main `
                    -ExpectedClassName 'DarkReNamerWindow' -ExpectedTitle 'DarkReNamer' `
                    -Label "$($step.language) valid-active normal close"
                if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) {
                    throw 'Valid-active application did not close normally after default Cancel.'
                }
                $job = Complete-AcceptanceOwnedProcessJob -Owned $owned
                if ($job.status -cne 'clean' -or -not $job.job_empty -or -not $job.job_closed) {
                    throw 'Valid-active application Job did not close cleanly.'
                }
                $afterClose = Get-ProductionValidActiveCheckpoint -FixtureRoot $fixtureRoot
                Assert-ProductionValidActiveCheckpoint -Expected $partial -Actual $afterClose
                $observations.Add([ordered]@{
                    language = $step.language; startup_preference = $saved
                    pid = [int]$process.Id; session_id = [int]$Session
                    process_start_time_utc_ticks = [string]$owned.process_start_time_utc_ticks
                    main_hwnd = [long]$mainHandle; notice_hwnd = [long]$noticeHandle
                    title = $labels.recovery_confirm; question = $labels.recovery_question
                    cancel_guidance = $labels.recovery_detail
                    notice_bounds = [ordered]@{ x=$noticeBounds.X; y=$noticeBounds.Y
                        width=$noticeBounds.Width; height=$noticeBounds.Height }
                    cancel_bounds = [ordered]@{ x=$cancelBounds.X; y=$cancelBounds.Y
                        width=$cancelBounds.Width; height=$cancelBounds.Height }
                    cancel_default_focused = $true; apply_locked_after_cancel = $true
                    apply_locked_after_choice = $true
                    before = $before; at_startup = $atStartup; after_cancel = $afterCancel
                    after_choice = $afterChoice; after_close = $afterClose
                    choice = $choice; normal_close = $true; process_job_clean = $true
                    notice_capture = $capture; notice_capture_foreground = $foreground[0]
                })
            }
            finally {
                if ($null -ne $owned) {
                    try {
                        if (-not $owned.job_closed) {
                            $job = Complete-AcceptanceOwnedProcessJob -Owned $owned -StopActive
                            if ($job.status -cne 'clean' -or -not $job.job_empty -or -not $job.job_closed) {
                                throw 'Valid-active owned process cleanup failed.'
                            }
                        }
                    }
                    finally { $owned.process.Dispose() }
                }
            }
        }
        $final = Get-ProductionValidActiveCheckpoint -FixtureRoot $fixtureRoot
        Assert-ProductionValidActiveCheckpoint -Expected $partial -Actual $final
        $fullyVerified = $true
        [ordered]@{
            schema_version = 1; status = 'passed'; scope = 'authentic-crash-child-three-language-default-cancel'
            child = $childRecord; partial = $partial; observations = $observations.ToArray()
            final = $final
            fixture_cleanup = 'verified-owned-root'
        }
    }
    finally {
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        try { Restore-ProductionCrashChildEnvironmentSnapshot -Snapshot $originalChildVariables }
        catch { $cleanupErrors.Add($_.Exception.Message) }
        try { $env:LOCALAPPDATA = $originalLocalAppData }
        catch { $cleanupErrors.Add("LOCALAPPDATA restore: $($_.Exception.Message)") }
        if ($null -ne $child) {
            try {
                if (-not $child.job_closed) {
                    $job = Complete-AcceptanceOwnedProcessJob -Owned $child -StopActive
                    if ($job.status -cne 'clean' -or -not $job.job_empty -or -not $job.job_closed) {
                        throw 'Crash child owned Job cleanup failed.'
                    }
                }
            }
            catch { $cleanupErrors.Add($_.Exception.Message) }
            finally {
                try { $child.process.Dispose() }
                catch { $cleanupErrors.Add($_.Exception.Message) }
            }
        }
        if ($cleanupErrors.Count -gt 0) {
            throw ('Valid-active environment or process cleanup failed: ' +
                [string]::Join(' | ', $cleanupErrors))
        }
        if ($fullyVerified -and (Test-Path -LiteralPath $fixtureRoot)) {
            Assert-OrdinaryDirectoryTree -Path $fixtureRoot
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
            if (Test-Path -LiteralPath $fixtureRoot) {
                throw 'Valid-active fixture cleanup was incomplete.'
            }
        }
    }
}

function Invoke-ProductionLanguageCycle {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $TestBinary,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $CaseRoot,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][int] $Session,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )
    $applicationPath = Join-Path $Root $Application.file
    Initialize-ProductionLanguageMenuReader
    $systemResolution = Resolve-ProductionSystemLanguage `
        -Tags @([DarkReNamerLanguageMenuReader]::PreferredLanguages())
    if ($systemResolution.language -cne 'ko') {
        throw 'The maintained Korean VM baseline differs from the first supported Windows UI language.'
    }
    $observations = [Collections.Generic.List[object]]::new()
    $flows = [Collections.Generic.List[object]]::new()
    foreach ($step in @(
        @{ language='ko'; preference=0; next='en' },
        @{ language='en'; preference=2; next='ja' },
        @{ language='ja'; preference=3; next='ko' },
        @{ language='ko'; preference=1; next='system' },
        @{ language=$systemResolution.language; preference=0; next=$null }
    )) {
        if ((Get-LowerSha256 -Path $applicationPath) -cne $Application.sha256) {
            throw 'Language acceptance application changed after source-bound preflight.'
        }
        $owned = $null
        $ownedCleanupClean = $false
        $fixture = $null
        $blocked = $null
        try {
            if ($step.preference -in @(0, 2, 3) -and $null -ne $step.next) {
                $blocked = Invoke-ProductionBlockedRecoveryCheck -Application $Application `
                    -Root $Root -OutputRoot $OutputRoot -Session $Session -TimeoutSeconds $TimeoutSeconds `
                    -Language $step.language
            }
            if ($step.language -cin @('en', 'ja')) {
                $fixture = New-PrivateDirectory -Parent $CaseRoot -Leaf ("language-$($step.language)")
                $initial = Initialize-ProductionRenameFlowFixture -FixtureRoot $fixture `
                    -ApplicationRoot $Root -LocalAppData $env:LOCALAPPDATA
            }
            $owned = Start-JobBoundProcess -FilePath $applicationPath -Arguments '' -WorkingDirectory $Root
            $process = $owned.process
            $binding = Wait-ExactApplicationMainWindow -Process $process -ExpectedSession $Session `
                -ExpectedClassName 'DarkReNamerWindow' -ExpectedTitle 'DarkReNamer' `
                -TimeoutSeconds $TimeoutSeconds -Label "$($step.language) language startup"
            $main = $binding.element
            $handle = [IntPtr]$binding.handle
            $saved = Read-ProductionLanguagePreference -LocalAppData $env:LOCALAPPDATA
            if ($saved.value -ne $step.preference) {
                throw "$($step.language) startup did not reload the exact prior menu selection."
            }
            $menu = Read-ProductionLanguageMenu -Process $process -MainWindow $main `
                -Session $Session -Language $step.language
            if ($menu.checked_command -ne (0x9020 + $step.preference)) {
                throw "$($step.language) startup did not restore the selected menu radio item."
            }
            $rail = Get-ProductionLanguageRail -Process $process -MainWindow $main `
                -Session $Session -TimeoutSeconds $TimeoutSeconds -Language $step.language
            $startupCapture = $null
            $startupCaptureForeground = $null
            if ($step.preference -in @(0, 2, 3) -and $null -ne $step.next) {
                $captureObservations = [Collections.Generic.List[object]]::new()
                $startupCapture = Save-WindowScreenshot -Window $main -Process $process `
                    -ExpectedSession $Session -Root $OutputRoot `
                    -Leaf "$($step.language)-language-main.png" `
                    -Label "$($step.language) language main workbench" `
                    -ForegroundObservations $captureObservations
                Set-ProductionCaptureByteCount -Capture $startupCapture -Root $OutputRoot
                $startupCaptureForeground = $captureObservations[0]
            }
            $flow = $null
            if ($null -ne $fixture) {
                $flow = Invoke-ProductionRenameFlow -OwnedProcess $owned -InitialFixture $initial `
                    -MainWindow $main -MainWindowHandle $handle -FixtureRoot $fixture `
                    -OutputRoot $OutputRoot -ExpectedSession $Session -TimeoutSeconds $TimeoutSeconds `
                    -Language $step.language -ExpectExistingRuntimeLock
                if ($flow.status -cne 'passed') {
                    throw "$($step.language) production rename flow failed: $($flow.failure_reason)"
                }
                $flows.Add([ordered]@{ language=$step.language; flow=$flow })
            }
            $pendingBefore = $null
            $pendingFileBefore = $null
            if ($step.language -ceq 'en' -and $step.next -ceq 'ja') {
                $pendingBefore = Set-ProductionPendingPrefix -OwnedProcess $owned `
                    -MainWindow $main -MainWindowHandle $handle -Session $Session `
                    -TimeoutSeconds $TimeoutSeconds -Language $step.language
                $pendingPath = Join-Path $fixture 'vm-confirmed-vm-flow-source.txt'
                $pendingFileBefore = [ordered]@{
                    content_sha256 = Get-LowerSha256 -Path $pendingPath
                    file_identity_sha256 = Get-LowerTextSha256 -Value ([DarkReNamerVmNative]::GetFileIdentity($pendingPath))
                }
                Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
            }
            $choice = if ($null -eq $step.next) { $null } else {
                Invoke-ProductionLanguageMenuChoice -Process $process -MainWindow $main `
                    -Session $Session -CurrentLanguage $step.language `
                    -NextPreference $step.next -TimeoutSeconds $TimeoutSeconds `
                    -PendingBefore $pendingBefore
            }
            if ($null -ne $pendingFileBefore) {
                $choice['pending_file_before'] = $pendingFileBefore
                $choice['pending_file_after'] = [ordered]@{
                    content_sha256 = Get-LowerSha256 -Path $pendingPath
                    file_identity_sha256 = Get-LowerTextSha256 -Value ([DarkReNamerVmNative]::GetFileIdentity($pendingPath))
                }
                if (($choice.pending_file_before | ConvertTo-Json -Compress) -cne
                    ($choice.pending_file_after | ConvertTo-Json -Compress)) {
                    throw 'Language selection changed the pending proposal file.'
                }
                Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
            }
            $observations.Add([ordered]@{
                language = $step.language; pid = [int]$process.Id; hwnd = [long]$handle
                session_id = [int]$Session
                process_start_time_utc_ticks = $process.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
                startup_preference = $saved
                startup_menu = $menu; startup_rail = $rail; choice = $choice
                startup_capture = $startupCapture
                startup_capture_foreground = $startupCaptureForeground
                blocked_recovery = $blocked
            })
            Close-ExactApplicationMainWindow -Process $process -ExpectedSession $Session `
                -MainWindowHandle $handle -MainWindow $main -ExpectedClassName 'DarkReNamerWindow' `
                -ExpectedTitle 'DarkReNamer' -Label "$($step.language) language normal close"
            if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) {
                throw "$($step.language) language application did not close normally."
            }
            $job = Complete-AcceptanceOwnedProcessJob -Owned $owned
            if ($job.status -cne 'clean' -or -not $job.job_empty -or -not $job.job_closed) {
                throw "$($step.language) language application process job did not close cleanly."
            }
            $ownedCleanupClean = $true
            if ($null -ne $flow) {
                $flow.checkpoints += (Get-FlowCheckpoint -Phase post_close -FixtureRoot $fixture `
                    -LocalAppData $env:LOCALAPPDATA)
            }
            Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        }
        finally {
            if ($null -ne $owned) {
                try {
                    if (-not $owned.job_closed) {
                        $cleanup = Complete-AcceptanceOwnedProcessJob -Owned $owned -StopActive
                        if ($cleanup.status -cne 'clean' -or -not $cleanup.job_empty -or -not $cleanup.job_closed) {
                            throw 'Language acceptance process job cleanup failed.'
                        }
                        $ownedCleanupClean = $true
                    }
                }
                finally { $owned.process.Dispose() }
            }
            if ($ownedCleanupClean -and $null -ne $fixture -and (Test-Path -LiteralPath $fixture)) {
                Assert-OrdinaryDirectoryTree -Path $fixture
                Remove-Item -LiteralPath $fixture -Recurse -Force
                if (Test-Path -LiteralPath $fixture) { throw 'Language fixture cleanup was incomplete.' }
            }
        }
    }
    $validActive = Invoke-ProductionValidActiveRecoveryCheck `
        -Application $Application -TestBinary $TestBinary -Root $Root `
        -OutputRoot $OutputRoot -Session $Session -TimeoutSeconds $TimeoutSeconds
    [ordered]@{
        schema_version = 1; status = 'passed'; scope = 'source-built-three-language-native-menu'
        application_sha256 = $Application.sha256
        selections = $observations.ToArray(); flows = $flows.ToArray()
        system_resolution = $systemResolution
        restored_preference = Read-ProductionLanguagePreference -LocalAppData $env:LOCALAPPDATA
        valid_active_recovery = $validActive
    }
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
        language_checks = $null
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
                if (-not $RawEvidence) {
                    $row.failure_reason = 'production_language_checks_failed'
                    $verifiedAgain = Resolve-VerifiedBundle -Root $Root `
                        -InvokedScriptPath (Join-Path $Root 'windows-vm-guest.ps1')
                    $appTests = @($verifiedAgain.manifest.test_binaries |
                        Where-Object name -ceq 'darknamer_app')
                    if ($verifiedAgain.manifest.schema_version -ne 1 -or
                        $appTests.Count -ne 1 -or
                        $verifiedAgain.manifest.application.sha256 -cne $Application.sha256) {
                        throw 'Valid-active source test binary is not uniquely bound to the verified GUI bundle.'
                    }
                    $row.language_checks = Invoke-ProductionLanguageCycle `
                        -Application $Application -TestBinary $appTests[0] `
                        -Root $Root -CaseRoot $caseRoot `
                        -OutputRoot $OutputRoot -Session $ExpectedSession `
                        -TimeoutSeconds $TimeoutSeconds
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
