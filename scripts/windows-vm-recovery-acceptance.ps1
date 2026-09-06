[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BundleRoot,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $ExpectedSessionId,

    [Parameter(Mandatory)]
    [string] $OutputRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string] $ExpectedScriptSha256,

    [ValidateSet('ProcessCrash', 'WorkerCancellation', 'WorkerClose')]
    [string] $Mode = 'ProcessCrash',

    [ValidateRange(128, 10000)]
    [int] $FixtureCount = 4096,

    [ValidateRange(10, 600)]
    [int] $TimeoutSeconds = 300,

    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AcceptanceUInt16 {
    param([Parameter(Mandatory)][byte[]] $Bytes, [Parameter(Mandatory)][int] $Offset)

    [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Get-AcceptanceUInt32 {
    param([Parameter(Mandatory)][byte[]] $Bytes, [Parameter(Mandatory)][int] $Offset)

    [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Get-AcceptanceUInt64 {
    param([Parameter(Mandatory)][byte[]] $Bytes, [Parameter(Mandatory)][int] $Offset)

    [BitConverter]::ToUInt64($Bytes, $Offset)
}

function Get-AcceptanceCrc32 {
    param([Parameter(Mandatory)][byte[][]] $Parts)

    [uint64]$crc = 0xFFFFFFFFL
    foreach ($part in $Parts) {
        foreach ($byte in $part) {
            $crc = $crc -bxor [uint64]$byte
            for ($bit = 0; $bit -lt 8; $bit++) {
                [uint64]$mask = 0
                if (($crc -band 1) -ne 0) {
                    $mask = 0xFFFFFFFFL
                }
                $crc = (($crc -shr 1) -bxor (0xEDB88320L -band $mask)) -band 0xFFFFFFFFL
            }
        }
    }
    [uint32](($crc -bxor 0xFFFFFFFFL) -band 0xFFFFFFFFL)
}

function Get-AcceptanceJournalInspection {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $headerBytes = 24
    $maximumPayloadBytes = 16MB
    $offset = 0
    $frame = 0
    $kinds = [Collections.Generic.List[int]]::new()
    $tail = 'none'
    while ($offset -lt $Bytes.Length) {
        if ($frame -ge 40004) {
            throw 'Journal exceeds the bounded frame count.'
        }
        if (($Bytes.Length - $offset) -lt $headerBytes) {
            $tail = 'truncated-header'
            break
        }
        if ($Bytes[$offset] -ne 0x44 -or
            $Bytes[$offset + 1] -ne 0x52 -or
            $Bytes[$offset + 2] -ne 0x4A -or
            $Bytes[$offset + 3] -ne 0x31) {
            throw "Journal frame $frame has invalid magic."
        }
        $version = Get-AcceptanceUInt16 -Bytes $Bytes -Offset ($offset + 4)
        if ($version -ne 1 -and $version -ne 2) {
            throw "Journal frame $frame has an unsupported version."
        }
        $kind = [int]$Bytes[$offset + 6]
        if ($kind -lt 1 -or $kind -gt 5 -or $Bytes[$offset + 7] -ne 0) {
            throw "Journal frame $frame has an invalid kind or flags."
        }
        $sequence = Get-AcceptanceUInt64 -Bytes $Bytes -Offset ($offset + 8)
        if ($sequence -ne [uint64]$frame) {
            throw "Journal frame $frame has an invalid sequence."
        }
        $payloadLength = [int64](Get-AcceptanceUInt32 -Bytes $Bytes -Offset ($offset + 16))
        if ($payloadLength -gt $maximumPayloadBytes) {
            throw "Journal frame $frame exceeds the payload bound."
        }
        $frameLength = [int64]$headerBytes + $payloadLength
        if ($frameLength -gt ($Bytes.Length - $offset)) {
            $tail = 'truncated-payload'
            break
        }
        $expectedCrc = Get-AcceptanceUInt32 -Bytes $Bytes -Offset ($offset + 20)
        $crcHeader = [byte[]]::new(16)
        [Array]::Copy($Bytes, $offset + 4, $crcHeader, 0, 16)
        $payload = [byte[]]::new([int]$payloadLength)
        if ($payloadLength -gt 0) {
            [Array]::Copy($Bytes, $offset + $headerBytes, $payload, 0, [int]$payloadLength)
        }
        if (($kind -eq 1 -and $payloadLength -lt 12) -or
            ($kind -ge 2 -and $kind -le 4 -and $payloadLength -ne 5) -or
            ($kind -eq 5 -and $payloadLength -ne 1)) {
            throw "Journal frame $frame has an invalid payload length for its record kind."
        }
        $actualCrc = Get-AcceptanceCrc32 -Parts @($crcHeader, $payload)
        if ($actualCrc -ne $expectedCrc) {
            throw "Journal frame $frame has a checksum mismatch."
        }
        $kinds.Add($kind)
        $offset += [int]$frameLength
        $frame++
    }
    if ($kinds.Count -eq 0 -or $kinds[0] -ne 1) {
        throw 'Journal does not contain one complete leading Intent frame.'
    }
    [pscustomobject]@{
        complete_frames = $kinds.Count
        last_kind = $kinds[$kinds.Count - 1]
        terminal = $kinds[$kinds.Count - 1] -eq 5
        tail = $tail
        valid_prefix_bytes = $offset
        total_bytes = $Bytes.Length
    }
}

function Get-AcceptanceCrashClassification {
    param(
        [Parameter(Mandatory)][int] $OriginalCount,
        [Parameter(Mandatory)][int] $RenamedCount,
        [Parameter(Mandatory)][int] $ExpectedCount,
        [Parameter(Mandatory)][bool] $ActiveJournalExists,
        [Parameter(Mandatory)][bool] $CandidateJournalExists,
        [Parameter(Mandatory)][object] $JournalInspection
    )

    if ($ExpectedCount -le 1 -or $RenamedCount -le 0 -or $RenamedCount -ge $ExpectedCount) {
        throw 'The observed rename boundary was not genuinely partial.'
    }
    if ($OriginalCount + $RenamedCount -ne $ExpectedCount) {
        throw 'The partial disk state has missing or unexpected transaction entries.'
    }
    if (-not $ActiveJournalExists -or $CandidateJournalExists) {
        throw 'The partial disk state does not have one unambiguous active journal.'
    }
    if ($JournalInspection.complete_frames -le 0 -or $JournalInspection.terminal) {
        throw 'The active journal is empty or already terminal.'
    }
    'partial-active-nonterminal'
}

function Get-AcceptanceWorkerBoundaryClassification {
    param(
        [Parameter(Mandatory)][int] $OriginalCount,
        [Parameter(Mandatory)][int] $RenamedCount,
        [Parameter(Mandatory)][int] $ExpectedCount,
        [Parameter(Mandatory)][bool] $ActiveJournalExists,
        [Parameter(Mandatory)][bool] $CandidateJournalExists,
        [Parameter(Mandatory)][bool] $CancelEnabled,
        [Parameter(Mandatory)][bool] $CancelVisible
    )

    if ($ExpectedCount -le 1 -or $RenamedCount -le 0 -or $RenamedCount -ge $ExpectedCount) {
        throw 'The observed worker boundary was not genuinely partial.'
    }
    if ($OriginalCount + $RenamedCount -ne $ExpectedCount) {
        throw 'The worker boundary has missing or unexpected transaction entries.'
    }
    if (-not $ActiveJournalExists -or $CandidateJournalExists) {
        throw 'The worker boundary does not have one unambiguous active journal.'
    }
    if (-not $CancelEnabled -or -not $CancelVisible) {
        throw 'The worker boundary does not expose one active cancellation control.'
    }
    'partial-active-worker'
}

function Get-AcceptanceGuestHelperPath {
    param([Parameter(Mandatory)][string] $Root)

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be absolute.'
    }
    $runnerPath = Join-Path $Root 'windows-vm-guest.ps1'
    if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
        throw 'The frozen guest helper is missing.'
    }
    $runnerItem = Get-Item -LiteralPath $runnerPath -Force
    if (($runnerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The frozen guest helper must not be a reparse point.'
    }
    $runnerItem.FullName
}

function Resolve-AcceptanceInputs {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RunnerPath,
        [Parameter(Mandatory)][string] $ObserverPath,
        [Parameter(Mandatory)][string] $ExpectedObserverSha256
    )

    $verified = Resolve-VerifiedBundle -Root $Root -InvokedScriptPath $RunnerPath
    if ($verified.manifest.source_state -cne 'clean') {
        throw 'Recovery acceptance requires a clean source-bound bundle.'
    }
    Assert-OrdinaryFile -Path $ObserverPath -Label 'recovery acceptance observer'
    $observerItem = Get-Item -LiteralPath $ObserverPath -Force
    $observerSha256 = Get-LowerSha256 -Path $observerItem.FullName
    if ($observerSha256 -cne $ExpectedObserverSha256) {
        throw 'The recovery acceptance observer hash does not match its staging contract.'
    }
    [pscustomobject]@{
        verified = $verified
        application_path = Join-Path $verified.root $verified.manifest.application.file
        observer_file = $observerItem.Name
        observer_sha256 = $observerSha256
        runner_sha256 = $verified.hashes[$verified.manifest.runner.file]
    }
}

function New-AcceptanceOutputDirectory {
    param([Parameter(Mandatory)][string] $Parent)

    if (-not [IO.Path]::IsPathRooted($Parent) -or
        -not (Test-Path -LiteralPath $Parent -PathType Container)) {
        throw 'OutputRoot must be an existing absolute directory.'
    }
    $item = Get-Item -LiteralPath $Parent -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'OutputRoot must not be a reparse point.'
    }
    $leaf = 'recovery-acceptance-' + [Guid]::NewGuid().ToString('N')
    $path = Join-Path $item.FullName $leaf
    [void](New-Item -ItemType Directory -Path $path)
    $path
}

function Write-AcceptanceUtf8Json {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object] $Value)

    $json = $Value | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Write-AcceptanceUtf16Paths {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string[]] $Paths)

    $encoding = [Text.UnicodeEncoding]::new($false, $true)
    $text = [string]::Join("`r`n", $Paths) + "`r`n"
    $body = $encoding.GetBytes($text)
    $preamble = $encoding.GetPreamble()
    $encodedLength = $preamble.Length + $body.Length
    if ($encodedLength -gt 2MB) {
        throw "The UTF-16LE path import is $encodedLength bytes and exceeds the production 2 MiB limit. Reduce FixtureCount."
    }
    $bytes = [byte[]]::new($encodedLength)
    [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    [IO.File]::WriteAllBytes($Path, $bytes)
    $encodedLength
}

function Get-AcceptanceFixtureState {
    param([Parameter(Mandatory)][string] $FixtureRoot)

    $rows = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $FixtureRoot -File -Force | Sort-Object Name)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The acceptance fixture contains a reparse point.'
        }
        $identity = [DarkReNamerVmNative]::GetFileIdentity($file.FullName)
        $rows.Add([pscustomobject]@{
            name = $file.Name
            content_sha256 = Get-LowerSha256 -Path $file.FullName
            identity = $identity
        })
    }
    $rows.ToArray()
}

function Assert-AcceptanceStatesEqual {
    param(
        [Parameter(Mandatory)][object[]] $Expected,
        [Parameter(Mandatory)][object[]] $Actual,
        [Parameter(Mandatory)][string] $Label
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "$Label has a different file count."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Expected[$index].name -cne $Actual[$index].name -or
            $Expected[$index].content_sha256 -cne $Actual[$index].content_sha256 -or
            $Expected[$index].identity -cne $Actual[$index].identity) {
            throw "$Label changed a leaf, content digest, or NTFS identity."
        }
    }
}

function Assert-AcceptancePartialState {
    param(
        [Parameter(Mandatory)][object[]] $Initial,
        [Parameter(Mandatory)][object[]] $Partial,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $ExpectedCount
    )

    if ($Partial.Count -ne $Initial.Count) {
        throw 'The partial state contains an unexpected number of files.'
    }
    $initialByIdentity = @{}
    foreach ($row in $Initial) {
        if ($initialByIdentity.ContainsKey($row.identity)) {
            throw 'The initial fixture contains a duplicate NTFS identity.'
        }
        $initialByIdentity[$row.identity] = $row
    }
    $original = 0
    $renamed = 0
    foreach ($row in $Partial) {
        if (-not $initialByIdentity.ContainsKey($row.identity)) {
            throw 'The partial state contains an unknown NTFS identity.'
        }
        $before = $initialByIdentity[$row.identity]
        if ($row.content_sha256 -cne $before.content_sha256) {
            throw 'The partial state changed file contents.'
        }
        if ($before.name -ceq 'sentinel.bin') {
            if ($row.name -cne $before.name) {
                throw 'The sentinel leaf changed.'
            }
            continue
        }
        if ($row.name -ceq $before.name) {
            $original++
        }
        elseif ($row.name -ceq ($Prefix + $before.name)) {
            $renamed++
        }
        else {
            throw 'The partial state contains an unexpected leaf.'
        }
    }
    if ($original + $renamed -ne $ExpectedCount) {
        throw 'The partial state did not account for every transaction file.'
    }
    [pscustomobject]@{ original = $original; renamed = $renamed }
}

function Get-AcceptanceStateDigest {
    param([Parameter(Mandatory)][object[]] $State)

    $parts = foreach ($row in $State) {
        $identityDigest = Get-LowerTextSha256 -Value $row.identity
        "$($row.name)|$($row.content_sha256)|$identityDigest"
    }
    Get-LowerTextSha256 -Value ([string]::Join("`n", $parts))
}

function Stop-AcceptanceFailedStartupProcess {
    param([Parameter(Mandatory)][object] $Owned)

    $process = $Owned.process
    try {
        $process.Refresh()
        if (-not $process.HasExited) {
            $process.Kill()
            if (-not $process.WaitForExit(10000)) {
                throw 'The exact process from failed startup validation did not terminate.'
            }
        }
    }
    finally {
        $process.Dispose()
    }
}

function Start-AcceptanceApplication {
    param(
        [Parameter(Mandatory)][object] $Inputs,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $application = $Inputs.verified.manifest.application
    if ((Get-LowerSha256 -Path $Inputs.application_path) -cne $application.sha256) {
        throw 'The application changed after bundle verification.'
    }
    $owned = $null
    try {
        $owned = Start-OwnedProcess `
            -FilePath $Inputs.application_path `
            -Arguments '' `
            -WorkingDirectory $Inputs.verified.root
        $deadline = (Get-Date).AddSeconds([Math]::Min(30, $WaitSeconds))
        do {
            Start-Sleep -Milliseconds 100
            $owned.process.Refresh()
            if ($owned.process.HasExited) {
                throw 'The source-bound application exited before creating its window.'
            }
        } while ($owned.process.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)
        if ($owned.process.MainWindowHandle -eq [IntPtr]::Zero -or
            $owned.process.SessionId -ne $SessionId) {
            throw 'The application did not create a window in the expected session.'
        }
        $main = [Windows.Automation.AutomationElement]::FromHandle($owned.process.MainWindowHandle)
        if ($null -eq $main) {
            throw 'The application main window is unavailable through UI Automation.'
        }
        Assert-AutomationBinding `
            -Element $main `
            -Process $owned.process `
            -ExpectedSession $SessionId `
            -Label 'recovery acceptance main window' `
            -RequireWindowHandle
        $actualProcessPath = $owned.process.MainModule.FileName
        if (-not [string]::Equals(
            $actualProcessPath,
            $Inputs.application_path,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'The owned process is not the verified application artifact.'
        }
        [pscustomobject]@{ owned = $owned; main = $main }
    }
    catch {
        $startupError = $_
        if ($null -ne $owned) {
            try {
                Stop-AcceptanceFailedStartupProcess -Owned $owned
            }
            catch {
                throw "Application startup validation and exact-process cleanup both failed: $($startupError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
        }
        throw $startupError
    }
}

function Get-AcceptanceUiDiagnostic {
    param([AllowNull()][object] $Application)

    if ($null -eq $Application) {
        return [pscustomobject]@{
            process_state = 'not-started'
            window_titles = @()
            status_message = $null
            status_count = $null
            row_count = $null
        }
    }
    $process = $Application.owned.process
    $process.Refresh()
    if ($process.HasExited) {
        return [pscustomobject]@{
            process_state = 'exited'
            exit_code = $process.ExitCode
            window_titles = @()
            status_message = $null
            status_count = $null
            row_count = $null
        }
    }
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ProcessIdProperty,
        $process.Id
    )
    $elements = [Windows.Automation.AutomationElement]::RootElement.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        $condition
    )
    $titles = [Collections.Generic.List[string]]::new()
    $statusMessage = $null
    $statusCount = $null
    $rowCount = $null
    foreach ($element in $elements) {
        try {
            if ($element.Current.ControlType -eq [Windows.Automation.ControlType]::Window -and
                -not [string]::IsNullOrEmpty($element.Current.Name)) {
                $titles.Add($element.Current.Name)
            }
            switch ($element.Current.AutomationId) {
                '1007' { $statusMessage = $element.Current.Name }
                '1008' { $statusCount = $element.Current.Name }
                '1000' {
                    $gridObject = $null
                    if ($element.TryGetCurrentPattern(
                        [Windows.Automation.GridPattern]::Pattern,
                        [ref]$gridObject
                    )) {
                        $rowCount = ([Windows.Automation.GridPattern]$gridObject).Current.RowCount
                    }
                    else {
                        $rowCount = $element.FindAll(
                            [Windows.Automation.TreeScope]::Children,
                            [Windows.Automation.Condition]::TrueCondition
                        ).Count
                    }
                }
            }
        }
        catch [Windows.Automation.ElementNotAvailableException] {
        }
    }
    [pscustomobject]@{
        process_state = 'running'
        window_titles = @($titles | Sort-Object -Unique)
        status_message = $statusMessage
        status_count = $statusCount
        row_count = $rowCount
    }
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
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][string] $LocalAppData,
        [Parameter(Mandatory)][int] $ExpectedCount,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $process = $Application.owned.process
    $cancel = Find-UniqueAutomationElement `
        -Root $Application.main `
        -Process $process `
        -ExpectedSession $SessionId `
        -AutomationId '1009' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'active worker cancellation control' `
        -RequireEnabled `
        -RequireWindowHandle
    $cancelVisible = -not $cancel.Current.IsOffscreen
    if ($cancel.Current.Name -cne '취소') {
        throw 'The active worker cancellation control has unexpected text.'
    }
    $renamed = [IO.Directory]::GetFiles(
        $FixtureRoot,
        ($Prefix + '*.txt'),
        [IO.SearchOption]::TopDirectoryOnly
    ).Length
    $original = [IO.Directory]::GetFiles(
        $FixtureRoot,
        'item-*.txt',
        [IO.SearchOption]::TopDirectoryOnly
    ).Length
    $journalRoot = Join-Path (Join-Path $LocalAppData 'DarkReNamer') 'journal'
    $activeExists = Test-Path -LiteralPath (Join-Path $journalRoot 'active.drj') -PathType Leaf
    $candidateExists = Test-Path -LiteralPath (Join-Path $journalRoot 'candidate.drj') -PathType Leaf
    $classification = Get-AcceptanceWorkerBoundaryClassification `
        -OriginalCount $original `
        -RenamedCount $renamed `
        -ExpectedCount $ExpectedCount `
        -ActiveJournalExists $activeExists `
        -CandidateJournalExists $candidateExists `
        -CancelEnabled $cancel.Current.IsEnabled `
        -CancelVisible $cancelVisible
    [pscustomobject]@{
        classification = $classification
        original = $original
        renamed = $renamed
        cancel = $cancel
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
    if ($process.HasExited -or -not $process.CloseMainWindow()) {
        throw 'The acceptance application rejected ordinary window close.'
    }
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
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $process = $Application.owned.process
    $prompt = Wait-UniqueAutomationWindow `
        -Process $process `
        -ExpectedSession $SessionId `
        -Name 'DarkReNamer - 이전 변경 복구 확인' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'startup recovery confirmation'
    $screenshot = Save-WindowScreenshot `
        -Window $prompt `
        -Process $process `
        -ExpectedSession $SessionId `
        -Root $EvidenceRoot `
        -Leaf 'startup-recovery-confirmation.png' `
        -Label 'startup recovery confirmation'
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
    $completed = Wait-UniqueAutomationWindow `
        -Process $process `
        -ExpectedSession $SessionId `
        -Name 'DarkReNamer - 복구 완료' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'recovery completion message'
    $completed.SetFocus()
    [void][DarkReNamerVmNative]::SetForegroundWindow([IntPtr]$completed.Current.NativeWindowHandle)
    [Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $WaitSeconds
    $screenshot
}

function Invoke-AcceptanceSession {
    param(
        [Parameter(Mandatory)][object] $Inputs,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][int] $Count,
        [Parameter(Mandatory)][ValidateSet('ProcessCrash', 'WorkerCancellation', 'WorkerClose')]
        [string] $Mode,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
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
    $initial = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
    if ($initial.Count -ne $Count + 1) {
        throw 'The initial fixture count is incorrect.'
    }

    $first = $null
    $second = $null
    try {
        $first = Start-AcceptanceApplication `
            -Inputs $Inputs `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds
        Invoke-AcceptanceImportAndPrefix `
            -Application $first `
            -PathsFile $pathsFile `
            -Prefix $prefix `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds
        Invoke-AcceptanceApply -Application $first -SessionId $SessionId -WaitSeconds $WaitSeconds

        $boundaryDeadline = (Get-Date).AddSeconds($WaitSeconds)
        $renamedObserved = 0
        do {
            $renamedObserved = [IO.Directory]::GetFiles(
                $fixtureRoot,
                ($prefix + '*.txt'),
                [IO.SearchOption]::TopDirectoryOnly
            ).Length
            if ($renamedObserved -gt 0 -and $renamedObserved -lt $Count) {
                break
            }
            if ($renamedObserved -ge $Count) {
                throw 'The rename completed before a genuine partial boundary was captured.'
            }
            Start-Sleep -Milliseconds 1
        } while ((Get-Date) -lt $boundaryDeadline)
        if ($renamedObserved -le 0 -or $renamedObserved -ge $Count) {
            throw 'No genuine partial rename boundary was observed before timeout.'
        }

        if ($Mode -ne 'ProcessCrash') {
            $workerBoundary = Get-AcceptanceActiveWorkerBoundary `
                -Application $first `
                -FixtureRoot $fixtureRoot `
                -Prefix $prefix `
                -LocalAppData $env:LOCALAPPDATA `
                -ExpectedCount $Count `
                -SessionId $SessionId `
                -WaitSeconds $WaitSeconds
            if ($Mode -eq 'WorkerCancellation') {
                Invoke-AutomationControl `
                    -Element $workerBoundary.cancel `
                    -Label 'active worker cancellation control'
                $restored = Wait-AcceptanceWorkerRollback `
                    -FixtureRoot $fixtureRoot `
                    -LocalAppData $env:LOCALAPPDATA `
                    -Initial $initial `
                    -WaitSeconds $WaitSeconds
                $screenshot = Save-WindowScreenshot `
                    -Window $first.main `
                    -Process $first.owned.process `
                    -ExpectedSession $SessionId `
                    -Root $EvidenceRoot `
                    -Leaf 'worker-cancellation-restored.png' `
                    -Label 'worker cancellation restored state'
                $exitCode = Close-AcceptanceApplicationNormally `
                    -Application $first `
                    -WaitSeconds $WaitSeconds
                return [pscustomobject]@{
                    status = 'passed'
                    mode = $Mode
                    classification = $workerBoundary.classification
                    fixture_count = $Count
                    import_bytes = $importBytes
                    partial_original_count = $workerBoundary.original
                    partial_renamed_count = $workerBoundary.renamed
                    initial_state_sha256 = Get-AcceptanceStateDigest -State $initial
                    restored_state_sha256 = Get-AcceptanceStateDigest -State $restored
                    journal_residue_count = 0
                    screenshot = $screenshot
                    normal_exit_code = $exitCode
                }
            }

            $exitCode = Close-AcceptanceApplicationNormally `
                -Application $first `
                -WaitSeconds $WaitSeconds
            Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
            $restored = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
            Assert-AcceptanceStatesEqual `
                -Expected $initial `
                -Actual $restored `
                -Label 'Worker-close rollback fixture'
            return [pscustomobject]@{
                status = 'passed'
                mode = $Mode
                classification = $workerBoundary.classification
                fixture_count = $Count
                import_bytes = $importBytes
                partial_original_count = $workerBoundary.original
                partial_renamed_count = $workerBoundary.renamed
                initial_state_sha256 = Get-AcceptanceStateDigest -State $initial
                restored_state_sha256 = Get-AcceptanceStateDigest -State $restored
                journal_residue_count = 0
                screenshot = $null
                normal_exit_code = $exitCode
            }
        }

        Stop-AcceptanceOwnedProcess -Application $first

        $partial = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
        $partialCounts = Assert-AcceptancePartialState `
            -Initial $initial `
            -Partial $partial `
            -Prefix $prefix `
            -ExpectedCount $Count
        $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
        $activePath = Join-Path $journalRoot 'active.drj'
        $candidatePath = Join-Path $journalRoot 'candidate.drj'
        $activeExists = Test-Path -LiteralPath $activePath -PathType Leaf
        $candidateExists = Test-Path -LiteralPath $candidatePath -PathType Leaf
        if (-not $activeExists) {
            throw 'The stopped partial transaction has no active journal.'
        }
        $activeItem = Get-Item -LiteralPath $activePath -Force
        if (($activeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $activeItem.Length -lt 24 -or $activeItem.Length -gt 64MB) {
            throw 'The stopped active journal is unsafe or outside the acceptance bound.'
        }
        $journalBytes = [IO.File]::ReadAllBytes($activePath)
        $inspection = Get-AcceptanceJournalInspection -Bytes $journalBytes
        $classification = Get-AcceptanceCrashClassification `
            -OriginalCount $partialCounts.original `
            -RenamedCount $partialCounts.renamed `
            -ExpectedCount $Count `
            -ActiveJournalExists $activeExists `
            -CandidateJournalExists $candidateExists `
            -JournalInspection $inspection
        $rawJournalPath = Join-Path $EvidenceRoot 'interrupted-active.drj'
        [IO.File]::WriteAllBytes($rawJournalPath, $journalBytes)

        $beforeRestart = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
        $second = Start-AcceptanceApplication `
            -Inputs $Inputs `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds
        $recoveryPrompt = Wait-UniqueAutomationWindow `
            -Process $second.owned.process `
            -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 이전 변경 복구 확인' `
            -TimeoutSeconds $WaitSeconds `
            -Label 'startup recovery confirmation before disk check'
        Assert-AutomationBinding `
            -Element $recoveryPrompt `
            -Process $second.owned.process `
            -ExpectedSession $SessionId `
            -Label 'startup recovery confirmation before disk check' `
            -RequireWindowHandle
        $afterRestart = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $beforeRestart `
            -Actual $afterRestart `
            -Label 'Startup before explicit recovery confirmation'
        $recoveryScreenshot = Invoke-AcceptanceRecovery `
            -Application $second `
            -EvidenceRoot $EvidenceRoot `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds

        $restoreDeadline = (Get-Date).AddSeconds($WaitSeconds)
        do {
            try {
                Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
                $restored = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
                Assert-AcceptanceStatesEqual `
                    -Expected $initial `
                    -Actual $restored `
                    -Label 'Recovered fixture'
                break
            }
            catch {
                Start-Sleep -Milliseconds 100
            }
        } while ((Get-Date) -lt $restoreDeadline)
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $restored = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
        Assert-AcceptanceStatesEqual -Expected $initial -Actual $restored -Label 'Recovered fixture'

        $second.owned.process.Refresh()
        if (-not $second.owned.process.CloseMainWindow() -or
            -not $second.owned.process.WaitForExit(10000)) {
            throw 'The recovered application did not close normally.'
        }
        $second.owned.process.WaitForExit()
        if ($second.owned.process.ExitCode -ne 0) {
            throw 'The recovered application returned a nonzero exit code.'
        }

        [pscustomobject]@{
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
            journal = [ordered]@{
                file = 'interrupted-active.drj'
                sha256 = Get-LowerSha256 -Path $rawJournalPath
                complete_frames = $inspection.complete_frames
                last_kind = $inspection.last_kind
                terminal = $inspection.terminal
                tail = $inspection.tail
                bytes = $inspection.total_bytes
            }
            startup_before_confirmation_unchanged = $true
            recovery_screenshot = $recoveryScreenshot
            normal_exit_code = $second.owned.process.ExitCode
        }
    }
    catch {
        $sessionError = $_
        try {
            $uiDiagnostic = Get-AcceptanceUiDiagnostic -Application $first
            Write-AcceptanceUtf8Json `
                -Path (Join-Path $EvidenceRoot 'session-ui-diagnostic.json') `
                -Value $uiDiagnostic
        }
        catch {
        }
        throw $sessionError
    }
    finally {
        foreach ($application in @($first, $second)) {
            if ($null -eq $application) { continue }
            try {
                $application.owned.process.Refresh()
                if (-not $application.owned.process.HasExited) {
                    $application.owned.process.Kill()
                    [void]$application.owned.process.WaitForExit(10000)
                }
            }
            catch {
            }
            finally {
                $application.owned.process.Dispose()
            }
        }
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$requestedBundleRoot = $BundleRoot
$requestedExpectedSessionId = $ExpectedSessionId
$requestedValidateOnly = [bool]$ValidateOnly
$guestHelperPath = Get-AcceptanceGuestHelperPath -Root $requestedBundleRoot
. $guestHelperPath -BundleRoot $requestedBundleRoot -ExpectedSessionId 1 -ValidateOnly
$BundleRoot = $requestedBundleRoot
$ExpectedSessionId = $requestedExpectedSessionId
$ValidateOnly = $requestedValidateOnly
$inputs = Resolve-AcceptanceInputs `
    -Root $BundleRoot `
    -RunnerPath $guestHelperPath `
    -ObserverPath $PSCommandPath `
    -ExpectedObserverSha256 $ExpectedScriptSha256
if ($ValidateOnly) {
    Write-Host "Validated recovery acceptance inputs for source $($inputs.verified.manifest.source_sha)."
    return
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Recovery acceptance execution requires Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Recovery acceptance must run with a non-elevated token.'
}
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($currentSession -ne $ExpectedSessionId) {
    throw 'Recovery acceptance is in an unexpected desktop session.'
}

$evidenceRoot = New-AcceptanceOutputDirectory -Parent $OutputRoot
$runtimeRoot = New-PrivateDirectory -Parent $evidenceRoot -Leaf 'runtime'
$result = [ordered]@{
    schema_version = 1
    source_sha = $inputs.verified.manifest.source_sha
    source_state = $inputs.verified.manifest.source_state
    application = [ordered]@{
        file = $inputs.verified.manifest.application.file
        sha256 = $inputs.verified.manifest.application.sha256
    }
    runner_sha256 = $inputs.runner_sha256
    observer = [ordered]@{
        file = $inputs.observer_file
        sha256 = $inputs.observer_sha256
    }
    status = 'failed'
    scope = 'production-rename-worker-interruption'
    selected_mode = $Mode
    process_crash = [ordered]@{ status = 'not-run'; reason = 'mode-not-selected' }
    worker_cancellation = [ordered]@{ status = 'not-run'; reason = 'mode-not-selected' }
    worker_close = [ordered]@{ status = 'not-run'; reason = 'mode-not-selected' }
    recovery_export = [ordered]@{ status = 'not-run'; reason = 'optional-flow-not-implemented' }
    failure_reason = $null
    diagnostic = $null
    ui_diagnostic = $null
}
$desktopLock = $null
$previousExecutionState = $null
$succeeded = $false
try {
    Initialize-NativeCapture
    if (-not [DarkReNamerVmNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
        throw 'The observer could not enable per-monitor DPI awareness.'
    }
    $desktopLock = Enter-DesktopTestLock -SessionId $currentSession
    if ($null -eq $desktopLock) {
        throw 'Another Windows VM test runner is using this interactive desktop.'
    }
    $previousExecutionState = Enter-TestExecutionState
    Invoke-WithIsolatedEnvironment -RuntimeRoot $runtimeRoot -Action {
        $modeResult = Invoke-AcceptanceSession `
            -Inputs $inputs `
            -EvidenceRoot $evidenceRoot `
            -RuntimeRoot $runtimeRoot `
            -Count $FixtureCount `
            -Mode $Mode `
            -SessionId $currentSession `
            -WaitSeconds $TimeoutSeconds
        switch ($Mode) {
            'ProcessCrash' { $result.process_crash = $modeResult }
            'WorkerCancellation' { $result.worker_cancellation = $modeResult }
            'WorkerClose' { $result.worker_close = $modeResult }
        }
    }
    $result.status = 'passed'
    $succeeded = $true
}
catch {
    $result.failure_reason = 'recovery_acceptance_error'
    $uiDiagnosticPath = Join-Path $evidenceRoot 'session-ui-diagnostic.json'
    if (Test-Path -LiteralPath $uiDiagnosticPath -PathType Leaf) {
        $result.ui_diagnostic = [ordered]@{
            file = 'session-ui-diagnostic.json'
            sha256 = Get-LowerSha256 -Path $uiDiagnosticPath
        }
    }
    $diagnosticPath = Join-Path $evidenceRoot 'diagnostic.txt'
    [IO.File]::WriteAllText(
        $diagnosticPath,
        ($_ | Out-String -Width 4096),
        [Text.UTF8Encoding]::new($true)
    )
    $result.diagnostic = [ordered]@{
        file = 'diagnostic.txt'
        sha256 = Get-LowerSha256 -Path $diagnosticPath
    }
}
finally {
    try {
        Exit-TestExecutionState -Previous $previousExecutionState
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'execution_state_restore_failed'
    }
    try {
        Exit-DesktopTestLock -Lock $desktopLock
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'desktop_lock_release_failed'
    }
    Write-AcceptanceUtf8Json -Path (Join-Path $evidenceRoot 'summary.json') -Value $result
    if ($succeeded -and (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
        try {
            $runtimeItem = Get-Item -LiteralPath $runtimeRoot -Force
            if (($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The successful runtime root became a reparse point.'
            }
            Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
            if (Test-Path -LiteralPath $runtimeRoot) {
                throw 'The successful runtime fixture cleanup was incomplete.'
            }
        }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'runtime_cleanup_refused'
            Write-AcceptanceUtf8Json -Path (Join-Path $evidenceRoot 'summary.json') -Value $result
        }
    }
}
Write-Host "Recovery acceptance evidence: $evidenceRoot"
if ($result.status -cne 'passed') {
    throw 'Recovery acceptance failed; inspect the external evidence directory.'
}
