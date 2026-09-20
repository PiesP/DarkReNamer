[CmdletBinding()]
param([switch] $ParserOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Fails {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $Expected
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) {
            throw "Expected failure containing '$Expected', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected failure containing '$Expected'."
}

function Get-TestSha256 {
    param([Parameter(Mandatory)][string] $Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-TestJson {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object] $Value)

    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}

function Join-TestBytes {
    param([Parameter(Mandatory)][byte[][]] $Parts)

    $length = 0
    foreach ($part in $Parts) { $length += $part.Length }
    $result = [byte[]]::new($length)
    $offset = 0
    foreach ($part in $Parts) {
        [Array]::Copy($part, 0, $result, $offset, $part.Length)
        $offset += $part.Length
    }
    $result
}

function Get-TestCrc32Reference {
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

function Assert-TestCrc32 {
    param(
        [Parameter(Mandatory)][byte[][]] $Parts,
        [Parameter(Mandatory)][uint32] $Expected,
        [Parameter(Mandatory)][string] $Label
    )

    $actual = Get-AcceptanceCrc32 -Parts $Parts
    if ($actual -ne $Expected) {
        throw "$Label CRC mismatch: actual=$('{0:x8}' -f $actual) expected=$('{0:x8}' -f $Expected)."
    }
}

function New-TestJournalFrame {
    param(
        [Parameter(Mandatory)][uint64] $Sequence,
        [Parameter(Mandatory)][ValidateRange(1, 5)][int] $Kind,
        [Parameter(Mandatory)][byte[]] $Payload
    )

    $header = [byte[]]::new(24)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('DRJ1'), 0, $header, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint16]2), 0, $header, 4, 2)
    $header[6] = [byte]$Kind
    [Array]::Copy([BitConverter]::GetBytes($Sequence), 0, $header, 8, 8)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$Payload.Length), 0, $header, 16, 4)
    $crcHeader = [byte[]]::new(16)
    [Array]::Copy($header, 4, $crcHeader, 0, 16)
    $crc = Get-AcceptanceCrc32 -Parts @($crcHeader, $Payload)
    [Array]::Copy([BitConverter]::GetBytes($crc), 0, $header, 20, 4)
    Join-TestBytes -Parts @($header, $Payload)
}

function New-TestBundle {
    param([Parameter(Mandatory)][string] $Root)

    [void](New-Item -ItemType Directory -Path $Root)
    $runnerPath = Join-Path $Root 'windows-vm-guest.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-vm-guest.ps1') -Destination $runnerPath
    [IO.File]::WriteAllText((Join-Path $Root 'DarkReNamer.exe'), 'application fixture')
    [IO.File]::WriteAllText((Join-Path $Root 'fixture-tests.exe'), 'test fixture')
    $manifest = [ordered]@{
        schema_version = 1
        source_sha = '0123456789abcdef0123456789abcdef01234567'
        source_state = 'clean'
        target = 'x86_64-pc-windows-msvc'
        cargo_lock_sha256 = '1' * 64
        test_binaries = @(
            [ordered]@{
                name = 'fixture-tests'
                file = 'fixture-tests.exe'
                sha256 = Get-TestSha256 -Path (Join-Path $Root 'fixture-tests.exe')
            }
        )
        application = [ordered]@{
            file = 'DarkReNamer.exe'
            sha256 = Get-TestSha256 -Path (Join-Path $Root 'DarkReNamer.exe')
        }
        runner = [ordered]@{
            file = 'windows-vm-guest.ps1'
            sha256 = Get-TestSha256 -Path $runnerPath
        }
    }
    Write-TestJson -Path (Join-Path $Root 'bundle.json') -Value $manifest
    [pscustomobject]@{ root = $Root; manifest = $manifest; runner = $runnerPath }
}

function New-CandidateTestBundle {
    param([Parameter(Mandatory)][string] $Root)

    $fixture = New-TestBundle -Root $Root
    Remove-Item -LiteralPath (Join-Path $Root 'fixture-tests.exe')
    Copy-Item -LiteralPath $script:acceptance `
        -Destination (Join-Path $Root 'windows-vm-recovery-acceptance.ps1')
    foreach ($row in @(
        @{ name = 'test-windows-vm.py'; content = 'launcher fixture' }
        @{ name = 'run-windows-vm-tests.ps1'; content = 'controller fixture' }
        @{ name = 'windows-vm-acceptance.ps1'; content = 'ui observer fixture' }
        @{ name = 'validate-release-handoff.ps1'; content = 'handoff validator fixture' }
        @{ name = 'validate-release-candidate-metadata.ps1'; content = 'metadata validator fixture' }
        @{ name = 'measure-windows-binary.ps1'; content = 'binary measurement fixture' }
        @{ name = 'release-handoff.json'; content = '{"source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","workflow_run":"10","executable":{"filename":"DarkReNamer.exe","sha256":"APP_HASH"}}' }
        @{ name = 'candidate-run.json'; content = '{"id":10,"run_attempt":1,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' }
        @{ name = 'candidate-artifact.json'; content = '{"id":20,"name":"DarkReNamer-dry-run-10-1-windows","workflow_run":{"id":10,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' }
    )) {
        [IO.File]::WriteAllText((Join-Path $Root $row.name), $row.content)
    }
    $applicationHash = Get-TestSha256 -Path (Join-Path $Root 'DarkReNamer.exe')
    $handoffPath = Join-Path $Root 'release-handoff.json'
    [IO.File]::WriteAllText(
        $handoffPath,
        ([IO.File]::ReadAllText($handoffPath).Replace('APP_HASH', $applicationHash))
    )
    $artifact = {
        param([string] $Leaf)
        [ordered]@{ file = $Leaf; sha256 = Get-TestSha256 -Path (Join-Path $Root $Leaf) }
    }
    $fixture.manifest = [ordered]@{
        schema_version = 2
        lane = 'candidate-gui-only'
        target = 'x86_64-pc-windows-msvc'
        product = [ordered]@{
            source_sha = 'a' * 40
            source_state = 'clean'
            candidate = [ordered]@{
                workflow_run = '10'; run_attempt = '1'; artifact_id = '20'
                artifact_name = 'DarkReNamer-dry-run-10-1-windows'
                origin_authentication = 'pending-hosted'
            }
            application = & $artifact 'DarkReNamer.exe'
            provenance = [ordered]@{
                release_handoff = & $artifact 'release-handoff.json'
                run_metadata = & $artifact 'candidate-run.json'
                artifact_metadata = & $artifact 'candidate-artifact.json'
            }
        }
        harness = [ordered]@{
            source_sha = 'b' * 40
            source_state = 'clean'
            launcher = & $artifact 'test-windows-vm.py'
            controller = & $artifact 'run-windows-vm-tests.ps1'
            runner = & $artifact 'windows-vm-guest.ps1'
            observers = [ordered]@{
                ui = & $artifact 'windows-vm-acceptance.ps1'
                recovery = & $artifact 'windows-vm-recovery-acceptance.ps1'
            }
            validators = [ordered]@{
                release_handoff = & $artifact 'validate-release-handoff.ps1'
                candidate_metadata = & $artifact 'validate-release-candidate-metadata.ps1'
                binary_measurement = & $artifact 'measure-windows-binary.ps1'
            }
        }
        test_binaries = @()
    }
    Write-TestJson -Path (Join-Path $Root 'bundle.json') -Value $fixture.manifest
    $fixture
}

$acceptance = Join-Path $PSScriptRoot 'windows-vm-recovery-acceptance.ps1'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$admissionSource = [IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'crates/darknamer-app/src/admission.rs')
)
if ($admissionSource.IndexOf(
    'pub const MAX_IMPORT_BYTES: usize = 2 * 1024 * 1024;',
    [StringComparison]::Ordinal
) -lt 0) {
    throw 'The observer import-byte bound no longer matches the production source contract.'
}
$windowsSource = [IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'crates/darknamer-app/src/windows.rs')
)
$menuSource = [IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'crates/darknamer-app/src/windows/menu.rs')
)
$dialogSource = [IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'crates/darknamer-app/src/windows/dialog.rs')
)
$librarySource = [IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'crates/darknamer-app/src/lib.rs')
)
$recoveryUiSource = [IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'crates/darknamer-app/src/windows/recovery_ui.rs')
)
foreach ($contract in @(
    @{ Text = $windowsSource; Value = 'const EXPORT_RECOVERY_JOURNAL: u16 = 0x9000;' },
    @{ Text = $windowsSource; Value = 'const DISCARD_STAGED_JOURNAL: u16 = 0x9001;' },
    @{ Text = $windowsSource; Value = 'const SHOW_RECOVERY_STATUS: u16 = 0x9002;' },
    @{ Text = $menuSource; Value = 'recovery.item(SHOW_RECOVERY_STATUS, "복구 상태 및 문제 확인...")?' },
    @{ Text = $menuSource; Value = 'recovery.item(EXPORT_RECOVERY_JOURNAL, "복구 데이터 내보내기...")?' },
    @{ Text = $menuSource; Value = 'recovery.separator()?' },
    @{ Text = $menuSource; Value = 'recovery.item(DISCARD_STAGED_JOURNAL, "시작되지 않은 작업 기록 삭제...")?' },
    @{ Text = $dialogSource; Value = '.set_title("복구 저널 원본을 저장할 폴더 선택")' },
    @{ Text = $librarySource; Value = 'pub(crate) const DISCARD_CONFIRM_BUTTON_ID: i32 = 1_201;' },
    @{ Text = $librarySource; Value = 'pub(crate) const RECOVER_CONFIRM_BUTTON_ID: i32 = 1_202;' },
    @{ Text = $recoveryUiSource; Value = '&directory.join("active.drj.retained")' },
    @{ Text = $recoveryUiSource; Value = 'if !state.can_discard_staged_intent() || !journal_matches {' },
    @{ Text = $recoveryUiSource; Value = '"DarkReNamer - 진단 내보내기 완료"' },
    @{ Text = $recoveryUiSource; Value = '"DarkReNamer - 활성화 전 계획 폐기".to_owned()' },
    @{ Text = $recoveryUiSource; Value = '"DarkReNamer - 폐기 완료"' }
)) {
    if ($contract.Text.IndexOf($contract.Value, [StringComparison]::Ordinal) -lt 0) {
        throw "The recovery observer UI contract drifted from production source: $($contract.Value)"
    }
}
$recoveryStatusIndex = $menuSource.IndexOf(
    'recovery.item(SHOW_RECOVERY_STATUS', [StringComparison]::Ordinal
)
$recoveryExportIndex = $menuSource.IndexOf(
    'recovery.item(EXPORT_RECOVERY_JOURNAL', [StringComparison]::Ordinal
)
$recoverySeparatorIndex = $menuSource.IndexOf(
    'recovery.separator()', $recoveryExportIndex, [StringComparison]::Ordinal
)
$recoveryDiscardIndex = $menuSource.IndexOf(
    'recovery.item(DISCARD_STAGED_JOURNAL', [StringComparison]::Ordinal
)
if ($recoveryStatusIndex -lt 0 -or $recoveryExportIndex -le $recoveryStatusIndex -or
    $recoverySeparatorIndex -le $recoveryExportIndex -or
    $recoveryDiscardIndex -le $recoverySeparatorIndex) {
    throw 'The recovery observer native menu positions drifted from production source.'
}
. $acceptance `
    -BundleRoot $PSScriptRoot `
    -ExpectedSessionId 1 `
    -OutputRoot $PSScriptRoot `
    -PrivateEvidenceRoot $PSScriptRoot `
    -ExpectedScriptSha256 ('0' * 64)

$validMenuInventory = [pscustomobject]@{
    TotalCount = 1
    Entries = @([pscustomobject]@{
        Handle = 4242L
        ProcessId = [uint32]123
        ClassName = '#32768'
        Left = 10
        Top = 20
        Right = 210
        Bottom = 120
    })
}
$menuObservation = ConvertTo-AcceptanceRecoveryMenuObservation `
    -Inventory $validMenuInventory `
    -ExpectedProcessId 123 `
    -ExpectedSession 7 `
    -ActualSession 7
if ($menuObservation.hwnd -ne 4242L -or
    $menuObservation.process_id -ne 123 -or
    $menuObservation.session_id -ne 7 -or
    $menuObservation.window_class -cne '#32768' -or
    -not $menuObservation.visible -or
    $menuObservation.rect.left -ne 10 -or
    $menuObservation.rect.bottom -ne 120) {
    throw 'The native recovery-menu inventory did not retain its exact binding.'
}
foreach ($case in @(
    @{ Inventory = [pscustomobject]@{ TotalCount = 2; Entries = $validMenuInventory.Entries };
        Session = 7; Expected = 'more than one candidate popup' },
    @{ Inventory = [pscustomobject]@{ TotalCount = -1; Entries = @() };
        Session = 7; Expected = 'invalid count' },
    @{ Inventory = $validMenuInventory; Session = 8; Expected = 'unexpected desktop session' },
    @{ Inventory = [pscustomobject]@{ TotalCount = 1; Entries = @([pscustomobject]@{
            Handle = 4242L; ProcessId = [uint32]124; ClassName = '#32768'
            Left = 10; Top = 20; Right = 210; Bottom = 120
        }) }; Session = 7; Expected = 'native identity or geometry' },
    @{ Inventory = [pscustomobject]@{ TotalCount = 1; Entries = @([pscustomobject]@{
            Handle = 4242L; ProcessId = [uint32]123; ClassName = 'OtherPopup'
            Left = 10; Top = 20; Right = 210; Bottom = 120
        }) }; Session = 7; Expected = 'native identity or geometry' },
    @{ Inventory = [pscustomobject]@{ TotalCount = 1; Entries = @([pscustomobject]@{
            Handle = 4242L; ProcessId = [uint32]123; ClassName = '#32768'
            Left = 10; Top = 20; Right = 10; Bottom = 120
        }) }; Session = 7; Expected = 'native identity or geometry' },
    @{ Inventory = [pscustomobject]@{ TotalCount = 1; Entries = @() };
        Session = 7; Expected = 'internally inconsistent' }
)) {
    Assert-Fails -Expected $case.Expected -Action {
        ConvertTo-AcceptanceRecoveryMenuObservation `
            -Inventory $case.Inventory `
            -ExpectedProcessId 123 `
            -ExpectedSession 7 `
            -ActualSession $case.Session
    }
}
$emptyMenuObservation = ConvertTo-AcceptanceRecoveryMenuObservation `
    -Inventory ([pscustomobject]@{ TotalCount = 0; Entries = @() }) `
    -ExpectedProcessId 123 `
    -ExpectedSession 7 `
    -ActualSession 7
if ($null -ne $emptyMenuObservation) {
    throw 'An empty native recovery-menu inventory produced a popup observation.'
}

function New-TestRecoveryMenuRows {
    param(
        [ValidateRange(-1, 3)][int] $HighlightPosition = -1,
        [ValidateRange(-1, 3)][int] $DisabledPosition = -1
    )

    $types = @('command', 'command', 'separator', 'command')
    $commands = @(0x9002, 0x9000, $null, 0x9001)
    @(
        for ($position = 0; $position -lt 4; $position++) {
            [pscustomobject]@{
                RootPosition = 4
                Position = $position
                ItemType = $types[$position]
                CommandId = $commands[$position]
                StateFlags = [uint32](
                    $(if ($position -eq $HighlightPosition) { 0x80 } else { 0 }) -bor
                    $(if ($position -eq $DisabledPosition) { 0x3 } else { 0 })
                )
                Left = 20
                Top = 20 + (20 * $position)
                Right = 220
                Bottom = 40 + (20 * $position)
            }
        }
    )
}

$testRecoveryPopup = [ordered]@{
    hwnd = 4242L
    process_id = 123
    session_id = 7
    window_class = '#32768'
    visible = $true
    rect = [ordered]@{ left = 10; top = 10; right = 230; bottom = 110 }
}
$exportMenuState = ConvertTo-AcceptanceRecoveryMenuState `
    -Rows @(New-TestRecoveryMenuRows -HighlightPosition 0) `
    -TargetCommandId 0x9000 `
    -TargetPosition 1 `
    -Popup $testRecoveryPopup `
    -RequireHighlight
if ($exportMenuState.rows.Count -ne 4 -or
    $exportMenuState.target.command_id -ne 0x9000 -or
    $exportMenuState.target.position -ne 1 -or
    -not $exportMenuState.target.enabled -or
    $exportMenuState.highlighted.command_id -ne 0x9002) {
    throw 'The exact recovery export menu state was not retained.'
}
$discardMenuState = ConvertTo-AcceptanceRecoveryMenuState `
    -Rows @(New-TestRecoveryMenuRows -HighlightPosition 3) `
    -TargetCommandId 0x9001 `
    -TargetPosition 3 `
    -Popup $testRecoveryPopup `
    -RequireHighlight
if ($discardMenuState.target.command_id -ne 0x9001 -or
    $discardMenuState.highlighted.command_id -ne 0x9001) {
    throw 'The exact recovery discard menu state was not retained.'
}
$menuStateFailures = @(
    @{ Mutate = { param($rows) $rows[0].RootPosition = 3 };
        Expected = 'identity, state, or geometry' },
    @{ Mutate = { param($rows) $rows[1].CommandId = 0x9001 };
        Expected = 'identity, state, or geometry' },
    @{ Mutate = { param($rows) $rows[1].Position = 0 };
        Expected = 'positions are missing or duplicated' },
    @{ Mutate = { param($rows) $rows[1].StateFlags = [uint32]3 };
        Expected = 'target command is missing or disabled' },
    @{ Mutate = { param($rows) $rows[0].StateFlags = [uint32]0x80; $rows[1].StateFlags = [uint32]0x80 };
        Expected = 'more than one native highlighted row' },
    @{ Mutate = { param($rows) $rows[1].Right = 240 };
        Expected = 'identity, state, or geometry' }
)
foreach ($case in $menuStateFailures) {
    $rows = @(New-TestRecoveryMenuRows -HighlightPosition -1)
    & $case.Mutate $rows
    Assert-Fails -Expected $case.Expected -Action {
        ConvertTo-AcceptanceRecoveryMenuState `
            -Rows $rows -TargetCommandId 0x9000 -TargetPosition 1 `
            -Popup $testRecoveryPopup
    }
}
Assert-Fails -Expected 'has no native highlighted command' -Action {
    ConvertTo-AcceptanceRecoveryMenuState `
        -Rows @(New-TestRecoveryMenuRows -HighlightPosition -1) `
        -TargetCommandId 0x9000 -TargetPosition 1 `
        -Popup $testRecoveryPopup -RequireHighlight
}
Assert-Fails -Expected 'target command and position are invalid' -Action {
    ConvertTo-AcceptanceRecoveryMenuState `
        -Rows @(New-TestRecoveryMenuRows -HighlightPosition 0) `
        -TargetCommandId 0x9000 -TargetPosition 3 `
        -Popup $testRecoveryPopup
}
$testRecoveryForeground = [ordered]@{
    hwnd = 5151L
    process_id = 123
    session_id = 7
    window_class = 'DarkReNamerWindow'
}
Assert-AcceptanceRecoveryMenuForegroundObservation `
    -Observation $testRecoveryForeground -ExpectedProcessId 123 `
    -ExpectedSession 7 -MainWindowHandle ([IntPtr]5151) -Label 'fixture'
foreach ($foreignForeground in @(
    [ordered]@{ hwnd = 5152L; process_id = 123; session_id = 7; window_class = 'DarkReNamerWindow' },
    [ordered]@{ hwnd = 5151L; process_id = 124; session_id = 7; window_class = 'DarkReNamerWindow' },
    [ordered]@{ hwnd = 5151L; process_id = 123; session_id = 8; window_class = 'DarkReNamerWindow' },
    [ordered]@{ hwnd = 5151L; process_id = 123; session_id = 7; window_class = 'OtherWindow' }
)) {
    Assert-Fails -Expected 'foreground binding changed' -Action {
        Assert-AcceptanceRecoveryMenuForegroundObservation `
            -Observation $foreignForeground -ExpectedProcessId 123 `
            -ExpectedSession 7 -MainWindowHandle ([IntPtr]5151) -Label 'fixture'
    }
}

$exitedProcess = [Diagnostics.Process]::new()
$exitedProcess.StartInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$exitedProcess.StartInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -Command exit'
$exitedProcess.StartInfo.UseShellExecute = $false
$exitedProcess.StartInfo.CreateNoWindow = $true
$exitedProcessStarted = $false
try {
    $exitedProcessStarted = $exitedProcess.Start()
    if (-not $exitedProcessStarted) {
        throw 'The exited-process recovery menu fixture did not start.'
    }
    $exitedProcess.WaitForExit()
    $exitedProcessId = $exitedProcess.Id
    $zeroInventoryRead = [pscustomobject]@{ count = 0; process_id = 0 }
    Assert-Fails -Expected 'changed process state before its recovery menu closed' -Action {
        Wait-AcceptanceRecoveryMenuClosed `
            -Process $exitedProcess `
            -ExpectedSession 0 `
            -ExpectedPopupHandle 4242 `
            -TimeoutSeconds 1 `
            -ReadInventory {
                param([uint32] $ExpectedProcessId)
                $zeroInventoryRead.count++
                $zeroInventoryRead.process_id = $ExpectedProcessId
                [pscustomobject]@{ TotalCount = 0; Entries = @() }
            }
    }
    if ($zeroInventoryRead.count -ne 1 -or
        $zeroInventoryRead.process_id -ne $exitedProcessId) {
        throw 'The exited-process recovery menu fixture did not observe its exact zero inventory.'
    }
}
finally {
    if ($exitedProcessStarted -and -not $exitedProcess.HasExited) {
        $exitedProcess.Kill()
        $exitedProcess.WaitForExit()
    }
    $exitedProcess.Dispose()
}

if ('DarkReNamerAcceptanceCrc32' -as [type]) {
    throw 'The recovery observer initialized CRC support before its first checksum operation.'
}

$knownCrcBytes = [Text.Encoding]::ASCII.GetBytes('123456789')
Assert-TestCrc32 `
    -Parts (, $knownCrcBytes) `
    -Expected ([uint32]3421780262) `
    -Label 'IEEE known vector'
if (-not ('DarkReNamerAcceptanceCrc32' -as [type])) {
    throw 'The recovery observer did not initialize CRC support on first use.'
}
Assert-TestCrc32 `
    -Parts ([byte[][]]@(,[byte[]]::new(0))) `
    -Expected ([uint32]0) `
    -Label 'Empty input'
$splitKnownCrcBytes = [byte[][]]@(
    [Text.Encoding]::ASCII.GetBytes('123'),
    [byte[]]::new(0),
    [Text.Encoding]::ASCII.GetBytes('456'),
    [Text.Encoding]::ASCII.GetBytes('789')
)
Assert-TestCrc32 `
    -Parts $splitKnownCrcBytes `
    -Expected ([uint32]3421780262) `
    -Label 'Split IEEE known vector'
$allByteValues = [byte[]](0..255)
Assert-TestCrc32 `
    -Parts (, $allByteValues) `
    -Expected ([uint32]688229491) `
    -Label 'All byte values'

$crcRandom = New-Object Random(171337)
for ($case = 0; $case -lt 48; $case++) {
    $length = $crcRandom.Next(0, 513)
    $bytes = [byte[]]::new($length)
    $crcRandom.NextBytes($bytes)
    $parts = [Collections.Generic.List[byte[]]]::new()
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $partLength = [Math]::Min($bytes.Length - $offset, $crcRandom.Next(1, 65))
        $part = [byte[]]::new($partLength)
        [Array]::Copy($bytes, $offset, $part, 0, $partLength)
        $parts.Add($part)
        $offset += $partLength
    }
    if ($parts.Count -eq 0 -or ($case % 3) -eq 0) {
        $parts.Add([byte[]]::new(0))
    }
    [byte[][]]$splitParts = $parts.ToArray()
    Assert-TestCrc32 `
        -Parts $splitParts `
        -Expected (Get-TestCrc32Reference -Parts (, $bytes)) `
        -Label "Deterministic split case $case"
}

$largeZeroBytes = [byte[]]::new(4MB)
Assert-TestCrc32 `
    -Parts (, $largeZeroBytes) `
    -Expected ([uint32]289882218) `
    -Label 'Four MiB zero vector'

foreach ($path in @($acceptance, $PSCommandPath)) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 3 -or
        $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "$(Split-Path -Leaf $path) must retain its UTF-8 BOM for Windows PowerShell 5.1."
    }
}

$intentPayload = [byte[]]::new(12)
$preparedPayload = [byte[]](0, 0, 0, 0, 0)
$terminalPayload = [byte[]](0)
$intent = New-TestJournalFrame -Sequence 0 -Kind 1 -Payload $intentPayload
$prepared = New-TestJournalFrame -Sequence 1 -Kind 2 -Payload $preparedPayload
$stream = Join-TestBytes -Parts @($intent, $prepared)
$inspection = Get-AcceptanceJournalInspection -Bytes $stream
if ($inspection.complete_frames -ne 2 -or
    $inspection.last_kind -ne 2 -or
    $inspection.terminal -or
    $inspection.tail -cne 'none') {
    throw 'The nonterminal journal inspection was classified incorrectly.'
}
$leadingIntent = Get-AcceptanceLeadingIntentFrame -Bytes $stream -Inspection $inspection
if ($leadingIntent.Length -ne $intent.Length -or
    -not [Linq.Enumerable]::SequenceEqual([byte[]]$leadingIntent, [byte[]]$intent)) {
    throw 'The exact leading Intent frame was not extracted from the genuine journal stream.'
}
$intentInspection = Get-AcceptanceJournalInspection -Bytes $leadingIntent
$intentClassification = Get-AcceptanceIntentCandidateClassification `
    -JournalInspection $intentInspection `
    -StartupLocked $true `
    -StartupUnchanged $true `
    -CancelPreserved $true `
    -CancelUnchanged $true `
    -CancelLocked $true `
    -RelaunchPreserved $true `
    -CandidateRemoved $true `
    -ActiveAbsent $true `
    -DiscardUnlocked $true `
    -DiscardUnchanged $true
if ($intentClassification -cne 'intent-only-cancel-preserved-discard-unlocked') {
    throw 'The complete Intent-only candidate scenario was classified incorrectly.'
}
Assert-Fails {
    Get-AcceptanceIntentCandidateClassification `
        -JournalInspection $intentInspection `
        -StartupLocked $true `
        -StartupUnchanged $true `
        -CancelPreserved $false `
        -CancelUnchanged $true `
        -CancelLocked $true `
        -RelaunchPreserved $true `
        -CandidateRemoved $true `
        -ActiveAbsent $true `
        -DiscardUnlocked $true `
        -DiscardUnchanged $true
} 'cancelled discard did not preserve'
Assert-Fails {
    Get-AcceptanceIntentCandidateClassification `
        -JournalInspection $intentInspection `
        -StartupLocked $true `
        -StartupUnchanged $true `
        -CancelPreserved $true `
        -CancelUnchanged $true `
        -CancelLocked $false `
        -RelaunchPreserved $true `
        -CandidateRemoved $true `
        -ActiveAbsent $true `
        -DiscardUnlocked $true `
        -DiscardUnchanged $true
} 'cancelled discard did not preserve'
Assert-Fails {
    Get-AcceptanceIntentCandidateClassification `
        -JournalInspection $intentInspection `
        -StartupLocked $true `
        -StartupUnchanged $true `
        -CancelPreserved $true `
        -CancelUnchanged $true `
        -CancelLocked $true `
        -RelaunchPreserved $false `
        -CandidateRemoved $true `
        -ActiveAbsent $true `
        -DiscardUnlocked $true `
        -DiscardUnchanged $true
} 'verification relaunch did not preserve'
Assert-Fails {
    Get-AcceptanceIntentCandidateClassification `
        -JournalInspection $inspection `
        -StartupLocked $true `
        -StartupUnchanged $true `
        -CancelPreserved $true `
        -CancelUnchanged $true `
        -CancelLocked $true `
        -RelaunchPreserved $true `
        -CandidateRemoved $true `
        -ActiveAbsent $true `
        -DiscardUnlocked $true `
        -DiscardUnchanged $true
} 'not one exact complete Intent-only frame'
$exportClassification = Get-AcceptanceRecoveryExportClassification `
    -ExpectedBytes $stream `
    -ExportedBytes ([byte[]]$stream.Clone()) `
    -ExportedLeaves @('active.drj.retained')
if ($exportClassification -cne 'active-retained-exact') {
    throw 'The exact retained active-journal export was classified incorrectly.'
}
$wrongExport = [byte[]]$stream.Clone()
$wrongExport[$wrongExport.Length - 1] = $wrongExport[$wrongExport.Length - 1] -bxor 1
Assert-Fails {
    Get-AcceptanceRecoveryExportClassification `
        -ExpectedBytes $stream `
        -ExportedBytes $wrongExport `
        -ExportedLeaves @('active.drj.retained')
} 'differs from the captured active journal'
Assert-Fails {
    Get-AcceptanceRecoveryExportClassification `
        -ExpectedBytes $stream `
        -ExportedBytes $stream `
        -ExportedLeaves @('active.drj.retained', 'candidate.drj.retained')
} 'unexpected retained files'
$classification = Get-AcceptanceCrashClassification `
    -OriginalCount 7 `
    -RenamedCount 3 `
    -ExpectedCount 10 `
    -ActiveJournalExists $true `
    -CandidateJournalExists $false `
    -JournalInspection $inspection
if ($classification -cne 'partial-active-nonterminal') {
    throw 'The genuine partial crash boundary was classified incorrectly.'
}
$workerClassification = Get-AcceptanceWorkerBoundaryClassification `
    -FirstDestinationObserved $true `
    -LastOriginalObserved $true `
    -WitnessesRechecked $true `
    -ActiveJournalExists $true `
    -CandidateJournalExists $false `
    -CancelEnabled $true `
    -CancelVisible $true
if ($workerClassification -cne 'partial-active-worker') {
    throw 'The genuine active worker boundary was classified incorrectly.'
}
Assert-Fails {
    Get-AcceptanceWorkerBoundaryClassification `
        -FirstDestinationObserved $true `
        -LastOriginalObserved $true `
        -WitnessesRechecked $true `
        -ActiveJournalExists $true `
        -CandidateJournalExists $false `
        -CancelEnabled $false `
        -CancelVisible $true
} 'active cancellation control'
Assert-Fails {
    Get-AcceptanceWorkerBoundaryClassification `
        -FirstDestinationObserved $true `
        -LastOriginalObserved $false `
        -WitnessesRechecked $false `
        -ActiveJournalExists $true `
        -CandidateJournalExists $false `
        -CancelEnabled $true `
        -CancelVisible $true
} 'partial-rename witnesses'
Assert-Fails {
    Get-AcceptanceWorkerBoundaryClassification `
        -FirstDestinationObserved $true `
        -LastOriginalObserved $true `
        -WitnessesRechecked $true `
        -ActiveJournalExists $true `
        -CandidateJournalExists $true `
        -CancelEnabled $true `
        -CancelVisible $true
} 'unambiguous active journal'

$fakeProcess = [pscustomobject]@{
    HasExited = $false
    MainWindowHandle = [IntPtr]1
    SessionId = 99
    killed = $false
    disposed = $false
}
$fakeProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
$fakeProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
    $this.killed = $true
    $this.HasExited = $true
}
$fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param([int] $Milliseconds)
    $null = $Milliseconds
    $this.HasExited
}
$fakeProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
    $this.disposed = $true
}
$script:fakeStartupOwned = [pscustomobject]@{ process = $fakeProcess }
function Get-LowerSha256 {
    param([string] $Path)
    $null = $Path
    'a' * 64
}
function Start-OwnedProcess {
    param(
        [string] $FilePath,
        [string] $Arguments,
        [string] $WorkingDirectory,
        [switch] $RedirectOutput
    )
    $null = @($FilePath, $Arguments, $WorkingDirectory, $RedirectOutput)
    $script:fakeStartupOwned
}
try {
    $startupInputs = [pscustomobject]@{
        application_path = 'fixture.exe'
        contract = [pscustomobject]@{
            application = [pscustomobject]@{ sha256 = 'a' * 64 }
        }
        verified = [pscustomobject]@{
            root = '.'
            manifest = [pscustomobject]@{
                application = [pscustomobject]@{ sha256 = 'a' * 64 }
            }
        }
    }
    Assert-Fails {
        Start-AcceptanceApplication -Inputs $startupInputs -SessionId 1 -WaitSeconds 10
    } 'expected session'
    if (-not $fakeProcess.killed -or -not $fakeProcess.disposed) {
        throw 'A process rejected during startup validation was not killed and disposed.'
    }
}
finally {
    Remove-Item Function:\Get-LowerSha256
    Remove-Item Function:\Start-OwnedProcess
}
$timeoutProcess = [pscustomobject]@{
    HasExited = $false
    killed = $false
    disposed = $false
}
$timeoutProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
$timeoutProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
    $this.killed = $true
}
$timeoutProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param([int] $Milliseconds)
    $null = $Milliseconds
    $false
}
$timeoutProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
    $this.disposed = $true
}
Assert-Fails {
    Stop-AndDisposeAcceptanceOwnedProcess `
        -Owned ([pscustomobject]@{ process = $timeoutProcess })
} 'exact owned acceptance process did not terminate'
if (-not $timeoutProcess.killed -or -not $timeoutProcess.disposed) {
    throw 'A timed-out owned-process cleanup did not attempt Kill and Dispose.'
}

$torn = Join-TestBytes -Parts @($stream, [byte[]](0x44, 0x52, 0x4A))
$tornInspection = Get-AcceptanceJournalInspection -Bytes $torn
if ($tornInspection.complete_frames -ne 2 -or $tornInspection.tail -cne 'truncated-header') {
    throw 'A final torn journal header was not retained as a complete recoverable prefix.'
}

$terminal = New-TestJournalFrame -Sequence 2 -Kind 5 -Payload $terminalPayload
$terminalInspection = Get-AcceptanceJournalInspection -Bytes (Join-TestBytes -Parts @($stream, $terminal))
Assert-Fails {
    Get-AcceptanceCrashClassification `
        -OriginalCount 7 `
        -RenamedCount 3 `
        -ExpectedCount 10 `
        -ActiveJournalExists $true `
        -CandidateJournalExists $false `
        -JournalInspection $terminalInspection
} 'already terminal'
Assert-Fails {
    Get-AcceptanceCrashClassification `
        -OriginalCount 10 `
        -RenamedCount 0 `
        -ExpectedCount 10 `
        -ActiveJournalExists $true `
        -CandidateJournalExists $false `
        -JournalInspection $inspection
} 'not genuinely partial'
Assert-Fails {
    Get-AcceptanceCrashClassification `
        -OriginalCount 7 `
        -RenamedCount 3 `
        -ExpectedCount 10 `
        -ActiveJournalExists $false `
        -CandidateJournalExists $false `
        -JournalInspection $inspection
} 'unambiguous active journal'

$badChecksum = [byte[]]$stream.Clone()
$badChecksum[$badChecksum.Length - 1] = $badChecksum[$badChecksum.Length - 1] -bxor 1
Assert-Fails {
    Get-AcceptanceJournalInspection -Bytes $badChecksum
} 'checksum mismatch'

$largeIntentPayload = [byte[]]::new(3MB + 257)
$largeIntentFrame = New-TestJournalFrame `
    -Sequence 0 `
    -Kind 1 `
    -Payload $largeIntentPayload
$largeInspection = Get-AcceptanceJournalInspection -Bytes $largeIntentFrame
if ($largeInspection.complete_frames -ne 1 -or
    $largeInspection.last_kind -ne 1 -or
    $largeInspection.terminal -or
    $largeInspection.tail -cne 'none' -or
    $largeInspection.total_bytes -ne $largeIntentFrame.Length) {
    throw 'The large nonterminal Intent frame was classified incorrectly.'
}
$largeBadChecksum = [byte[]]$largeIntentFrame.Clone()
$largeBadChecksum[$largeBadChecksum.Length - 1] =
    $largeBadChecksum[$largeBadChecksum.Length - 1] -bxor 1
Assert-Fails {
    Get-AcceptanceJournalInspection -Bytes $largeBadChecksum
} 'checksum mismatch'

$manyFrameParts = [Collections.Generic.List[byte[]]]::new()
$manyFrameParts.Add($largeIntentFrame)
for ($sequence = 1; $sequence -le 2300; $sequence++) {
    $manyFrameParts.Add((New-TestJournalFrame `
        -Sequence ([uint64]$sequence) `
        -Kind 2 `
        -Payload $preparedPayload))
}
$manyFrameJournal = Join-TestBytes -Parts $manyFrameParts.ToArray()
$manyFrameInspection = Get-AcceptanceJournalInspection -Bytes $manyFrameJournal
if ($manyFrameInspection.complete_frames -ne 2301 -or
    $manyFrameInspection.last_kind -ne 2 -or
    $manyFrameInspection.terminal -or
    $manyFrameInspection.tail -cne 'none' -or
    $manyFrameInspection.total_bytes -ne $manyFrameJournal.Length) {
    throw 'The large many-frame journal was classified incorrectly.'
}
$manyFrameBadChecksum = [byte[]]$manyFrameJournal.Clone()
$manyFrameBadChecksum[$manyFrameBadChecksum.Length - 1] =
    $manyFrameBadChecksum[$manyFrameBadChecksum.Length - 1] -bxor 1
Assert-Fails {
    Get-AcceptanceJournalInspection -Bytes $manyFrameBadChecksum
} 'checksum mismatch'

if ($ParserOnly) {
    Write-Host 'Windows PowerShell journal parser tests passed.'
    return
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-recovery-script-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temporaryRoot)
try {
    $exportRoot = Join-Path $temporaryRoot 'export-shape'
    [void](New-Item -ItemType Directory -Path $exportRoot)
    [IO.File]::WriteAllBytes((Join-Path $exportRoot 'active.drj.retained'), $stream)
    $exportItem = Get-AcceptanceRecoveryExportFile -Root $exportRoot
    if ($exportItem.Name -cne 'active.drj.retained' -or $exportItem.Length -ne $stream.Length) {
        throw 'The exact recovery export file was not selected.'
    }
    [void](New-Item -ItemType Directory -Path (Join-Path $exportRoot 'unexpected-child'))
    Assert-Fails {
        Get-AcceptanceRecoveryExportFile -Root $exportRoot
    } 'exactly one ordinary file'

    $smallImport = Join-Path $temporaryRoot 'small-import.txt'
    $smallImportBytes = Write-AcceptanceUtf16Paths -Path $smallImport -Paths @('A')
    if ($smallImportBytes -ne 8 -or (Get-Item -LiteralPath $smallImport).Length -ne 8) {
        throw 'The UTF-16LE import writer did not include its BOM and CRLF in the byte count.'
    }
    $oversizedImport = Join-Path $temporaryRoot 'oversized-import.txt'
    Assert-Fails {
        Write-AcceptanceUtf16Paths `
            -Path $oversizedImport `
            -Paths @(('x' * 1048575))
    } 'exceeds the production 2 MiB limit'
    if (Test-Path -LiteralPath $oversizedImport) {
        throw 'The oversized import writer created a rejected file.'
    }

    $valid = New-TestBundle -Root (Join-Path $temporaryRoot 'valid')
    $observerHash = Get-TestSha256 -Path $acceptance
    & $acceptance `
        -BundleRoot $valid.root `
        -ExpectedSessionId 1 `
        -OutputRoot $temporaryRoot `
        -PrivateEvidenceRoot $temporaryRoot `
        -ExpectedScriptSha256 $observerHash `
        -Mode WorkerCancellation `
        -ValidateOnly

    & $acceptance `
        -BundleRoot $valid.root `
        -ExpectedSessionId 1 `
        -OutputRoot $temporaryRoot `
        -PrivateEvidenceRoot $temporaryRoot `
        -ExpectedScriptSha256 $observerHash `
        -Mode ProcessCrash `
        -RecoveryExport `
        -IntentOnlyCandidateDiscard `
        -ValidateOnly

    $candidateValid = New-CandidateTestBundle `
        -Root (Join-Path $temporaryRoot 'candidate-valid')
    & $acceptance `
        -BundleRoot $candidateValid.root `
        -ExpectedSessionId 1 `
        -OutputRoot $temporaryRoot `
        -PrivateEvidenceRoot $temporaryRoot `
        -ExpectedScriptSha256 $observerHash `
        -Mode ProcessCrash `
        -RecoveryExport `
        -IntentOnlyCandidateDiscard `
        -ValidateOnly

    $candidateSwappedObserver = New-CandidateTestBundle `
        -Root (Join-Path $temporaryRoot 'candidate-swapped-observer')
    $candidateSwappedObserver.manifest.harness.observers.recovery =
        $candidateSwappedObserver.manifest.harness.observers.ui
    Write-TestJson `
        -Path (Join-Path $candidateSwappedObserver.root 'bundle.json') `
        -Value $candidateSwappedObserver.manifest
    Assert-Fails {
        & $acceptance `
            -BundleRoot $candidateSwappedObserver.root `
            -ExpectedSessionId 1 `
            -OutputRoot $temporaryRoot `
            -PrivateEvidenceRoot $temporaryRoot `
            -ExpectedScriptSha256 $observerHash `
            -ValidateOnly
    } 'recovery observer binding is invalid'

    $candidateFalseAlias = New-CandidateTestBundle `
        -Root (Join-Path $temporaryRoot 'candidate-false-alias')
    $candidateFalseAlias.manifest['runner'] = $candidateFalseAlias.manifest.harness.runner
    Write-TestJson `
        -Path (Join-Path $candidateFalseAlias.root 'bundle.json') `
        -Value $candidateFalseAlias.manifest
    Assert-Fails {
        & $acceptance `
            -BundleRoot $candidateFalseAlias.root `
            -ExpectedSessionId 1 `
            -OutputRoot $temporaryRoot `
            -PrivateEvidenceRoot $temporaryRoot `
            -ExpectedScriptSha256 $observerHash `
            -ValidateOnly
    } 'unexpected fields'

    $candidateDuplicate = New-CandidateTestBundle `
        -Root (Join-Path $temporaryRoot 'candidate-duplicate')
    $candidateManifestPath = Join-Path $candidateDuplicate.root 'bundle.json'
    $candidateManifestText = [IO.File]::ReadAllText($candidateManifestPath)
    [IO.File]::WriteAllText(
        $candidateManifestPath,
        $candidateManifestText.Replace('"schema_version": 2,', '"schema_version": 2, "schema_version": 2,'),
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Fails {
        & $acceptance `
            -BundleRoot $candidateDuplicate.root `
            -ExpectedSessionId 1 `
            -OutputRoot $temporaryRoot `
            -PrivateEvidenceRoot $temporaryRoot `
            -ExpectedScriptSha256 $observerHash `
            -ValidateOnly
    } 'duplicate field: schema_version'

    Assert-Fails {
        & $acceptance `
            -BundleRoot $valid.root `
            -ExpectedSessionId 1 `
            -OutputRoot $temporaryRoot `
            -PrivateEvidenceRoot $temporaryRoot `
            -ExpectedScriptSha256 $observerHash `
            -Mode WorkerCancellation `
            -RecoveryExport `
            -ValidateOnly
    } 'require Mode ProcessCrash'

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Assert-Fails {
            & $acceptance `
                -BundleRoot $valid.root `
                -ExpectedSessionId 7 `
                -OutputRoot $temporaryRoot `
                -PrivateEvidenceRoot $temporaryRoot `
                -ExpectedScriptSha256 $observerHash `
                -Mode WorkerClose
        } 'execution requires Windows'
    }

    Assert-Fails {
        & $acceptance `
            -BundleRoot $valid.root `
            -ExpectedSessionId 1 `
            -OutputRoot $temporaryRoot `
            -PrivateEvidenceRoot $temporaryRoot `
            -ExpectedScriptSha256 ('f' * 64) `
            -ValidateOnly
    } 'observer hash does not match'

    $changedRunner = New-TestBundle -Root (Join-Path $temporaryRoot 'changed-runner')
    [IO.File]::AppendAllText($changedRunner.runner, "`n# changed")
    Assert-Fails {
        & $acceptance `
            -BundleRoot $changedRunner.root `
            -ExpectedSessionId 1 `
            -OutputRoot $temporaryRoot `
            -PrivateEvidenceRoot $temporaryRoot `
            -ExpectedScriptSha256 $observerHash `
            -ValidateOnly
    } 'bootstrap runner hash does not match'

    $maliciousRunner = New-TestBundle -Root (Join-Path $temporaryRoot 'malicious-runner')
    $markerPath = Join-Path $temporaryRoot 'malicious-helper-executed.txt'
    $originalMarker = [Environment]::GetEnvironmentVariable(
        'DARKRENAMER_BOOTSTRAP_MARKER',
        'Process'
    )
    try {
        [Environment]::SetEnvironmentVariable(
            'DARKRENAMER_BOOTSTRAP_MARKER',
            $markerPath,
            'Process'
        )
        $runnerText = [IO.File]::ReadAllText($maliciousRunner.runner)
        $bootstrapBoundary = "if (`$MyInvocation.InvocationName -eq '.') {"
        $maliciousBody = @'
function Resolve-VerifiedBundle {
    [IO.File]::WriteAllText($env:DARKRENAMER_BOOTSTRAP_MARKER, 'forged verifier executed')
    throw 'forged verifier executed'
}
[IO.File]::WriteAllText($env:DARKRENAMER_BOOTSTRAP_MARKER, 'malicious helper executed')
'@
        if ($runnerText.IndexOf($bootstrapBoundary, [StringComparison]::Ordinal) -lt 0) {
            throw 'The malicious helper fixture could not find its execution boundary.'
        }
        $runnerText = $runnerText.Replace(
            $bootstrapBoundary,
            $maliciousBody + "`r`n" + $bootstrapBoundary
        )
        [IO.File]::WriteAllText(
            $maliciousRunner.runner,
            $runnerText,
            [Text.UTF8Encoding]::new($true)
        )
        Assert-Fails {
            & $acceptance `
                -BundleRoot $maliciousRunner.root `
                -ExpectedSessionId 1 `
                -OutputRoot $temporaryRoot `
                -PrivateEvidenceRoot $temporaryRoot `
                -ExpectedScriptSha256 $observerHash `
                -ValidateOnly
        } 'bootstrap runner hash does not match'
        if (Test-Path -LiteralPath $markerPath) {
            throw 'An unauthenticated guest helper executed before bootstrap verification.'
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'DARKRENAMER_BOOTSTRAP_MARKER',
            $originalMarker,
            'Process'
        )
    }

    $valid.manifest.source_state = 'dirty'
    Write-TestJson -Path (Join-Path $valid.root 'bundle.json') -Value $valid.manifest
    Assert-Fails {
        & $acceptance `
            -BundleRoot $valid.root `
            -ExpectedSessionId 1 `
            -OutputRoot $temporaryRoot `
            -PrivateEvidenceRoot $temporaryRoot `
            -ExpectedScriptSha256 $observerHash `
            -ValidateOnly
    } 'requires a clean source-bound bundle'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $item = Get-Item -LiteralPath $temporaryRoot -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The test fixture root became a reparse point.'
        }
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

$rawTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'darkrenamer-recovery-raw-' + [Guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $rawTestRoot)
try {
    function Get-LowerSha256 {
        param([Parameter(Mandatory)][string] $Path)
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    function Get-LowerTextSha256 {
        param([Parameter(Mandatory)][string] $Value)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $algorithm.ComputeHash($bytes)
        }
        finally {
            $algorithm.Dispose()
        }
        ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }

    function Get-FullFileIdentity {
        param([Parameter(Mandatory)][string] $Path)

        $item = Get-Item -LiteralPath $Path -Force
        $digest = Get-LowerTextSha256 -Value $item.FullName
        [pscustomobject][ordered]@{
            volume_serial = '0123456789abcdef'
            file_id = $digest.Substring(0, 32)
        }
    }

    $fixtureRoot = Join-Path $rawTestRoot 'fixture'
    $privateRoot = Join-Path $rawTestRoot 'private'
    $journalRoot = Join-Path $rawTestRoot 'journal'
    [void](New-Item -ItemType Directory -Path $fixtureRoot)
    [void](New-Item -ItemType Directory -Path $privateRoot)
    [void](New-Item -ItemType Directory -Path $journalRoot)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'b.txt'), 'bravo')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'a.txt'), 'alpha')
    $fixtureState = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
    & {
        $hashCalls = [Collections.Generic.List[string]]::new()
        function Get-Item {
            param([string] $LiteralPath, [switch] $Force)
            [pscustomobject]@{ PSIsContainer = $true; Attributes = [IO.FileAttributes]::Directory; FullName = 'C:\bounded-fixture' }
        }
        function Get-ChildItem {
            param([string] $LiteralPath, [switch] $Force)
            foreach ($number in 1..9) {
                [pscustomobject]@{
                    PSIsContainer = $false; Attributes = [IO.FileAttributes]::Normal
                    Name = "file-$number.txt"; FullName = "C:\bounded-fixture\file-$number.txt"; Length = [long]64MB
                }
            }
        }
        function Get-LowerSha256 {
            param([string] $Path)
            $hashCalls.Add($Path)
            'a' * 64
        }
        function Get-FullFileIdentity {
            param([string] $Path)
            [pscustomobject]@{ volume_serial = '1' * 16; file_id = '2' * 32 }
        }
        Assert-Fails { Get-AcceptanceFixtureState -FixtureRoot 'C:\bounded-fixture' } 'aggregate byte limit'
        if ($hashCalls.Count -ne 8 -or $hashCalls.Contains('C:\bounded-fixture\file-9.txt')) {
            throw 'Over-limit fixture content was hashed before aggregate rejection.'
        }
    }
    if ($fixtureState.Count -ne 2 -or
        $fixtureState[0].name -cne 'a.txt' -or
        $fixtureState[0].kind -cne 'file' -or
        $fixtureState[0].bytes -ne 5 -or
        $fixtureState[0].file_identity.file_id -cnotmatch '^[0-9a-f]{32}$') {
        throw 'The raw fixture inventory omitted an exact ordinary-file field.'
    }
    [void](New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'child'))
    Assert-Fails {
        Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
    } 'non-file, reparse, or oversized entry'
    Remove-Item -LiteralPath (Join-Path $fixtureRoot 'child')

    $rootIdentity = Get-FullFileIdentity -Path $fixtureRoot
    $stateReference = Write-AcceptanceObservedStateEvidence `
        -PrivateRoot $privateRoot -Leaf 'state-test' -Boundary 'test-state' `
        -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity -State $fixtureState
    $referenceNames = @($stateReference.PSObject.Properties.Name | Sort-Object)
    if ([string]::Join(',', $referenceNames) -cne 'boundary,bytes,sha256') {
        throw 'A public raw reference exposes a private path or an unknown field.'
    }
    $stateRaw = Get-Content -LiteralPath (Join-Path $privateRoot 'state-test.json') -Raw |
        ConvertFrom-Json
    if ($stateRaw.fixture_entries.Count -ne 2 -or
        $stateRaw.root_identity.file_id -cne $rootIdentity.file_id -or
        $stateRaw.fixture_root -cne $fixtureRoot) {
        throw 'The private state evidence omitted its root identity, path, or full inventory.'
    }
    Assert-Fails {
        Write-AcceptanceObservedStateEvidence `
            -PrivateRoot $privateRoot -Leaf 'state-test' -Boundary 'duplicate' `
            -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity -State $fixtureState
    } 'already exists'

    [IO.File]::WriteAllBytes((Join-Path $journalRoot 'active.drj'), $stream)
    $journalReference = Write-AcceptanceJournalInventoryEvidence `
        -PrivateRoot $privateRoot -Leaf 'journal-test' -Boundary 'test-journal' `
        -JournalRoot $journalRoot
    if ($journalReference.bytes -le 0 -or $journalReference.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The journal inventory reference is not digest and size bound.'
    }
    $journalRaw = Get-Content -LiteralPath (Join-Path $privateRoot 'journal-test.json') -Raw |
        ConvertFrom-Json
    if ($journalRaw.journal_entries.Count -ne 1 -or
        $journalRaw.journal_entries[0].name -cne 'active.drj' -or
        $journalRaw.journal_entries[0].bytes -ne $stream.Length -or
        $journalRaw.journal_entries[0].sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The post-process journal inventory omitted exact basename, bytes, or digest.'
    }
    [IO.File]::WriteAllText((Join-Path $journalRoot 'unexpected.txt'), 'unexpected')
    Assert-Fails {
        Write-AcceptanceJournalInventoryEvidence `
            -PrivateRoot $privateRoot -Leaf 'journal-invalid' -Boundary 'invalid' `
            -JournalRoot $journalRoot
    } 'unexpected entry'
    Remove-Item -LiteralPath (Join-Path $journalRoot 'unexpected.txt')

    $workerWitness = [ordered]@{
        candidate_pid = 101
        candidate_session_id = 1
        entries = @(
            [ordered]@{
                role = 'first-destination'
                name = 'vm-recovered-item-00000.txt'
                kind = 'file'
                bytes = $fixtureState[0].bytes
                content_sha256 = $fixtureState[0].content_sha256
                file_identity = $fixtureState[0].file_identity
                observed_utc_ticks = '638940000000000001'
            },
            [ordered]@{
                role = 'last-original'
                name = 'item-04095.txt'
                kind = 'file'
                bytes = $fixtureState[1].bytes
                content_sha256 = $fixtureState[1].content_sha256
                file_identity = $fixtureState[1].file_identity
                observed_utc_ticks = '638940000000000002'
            }
        )
    }
    $witnessReference = Write-AcceptanceWorkerPartialWitnessEvidence `
        -PrivateRoot $privateRoot -Leaf 'worker-partial-test' `
        -FixtureRoot $fixtureRoot -ExpectedRootIdentity $rootIdentity `
        -Witness $workerWitness
    if ($witnessReference.boundary -cne 'worker-partial') {
        throw 'The worker partial witness did not expose its typed raw boundary.'
    }
    $witnessRaw = Get-Content `
        -LiteralPath (Join-Path $privateRoot 'worker-partial-test.json') -Raw |
        ConvertFrom-Json
    if ($witnessRaw.entries.Count -ne 2 -or
        $witnessRaw.entries[0].name -cne 'vm-recovered-item-00000.txt' -or
        $witnessRaw.entries[1].name -cne 'item-04095.txt' -or
        $witnessRaw.candidate_pid -ne 101 -or
        $witnessRaw.root_identity.file_id -cne $rootIdentity.file_id) {
        throw 'The worker partial witness omitted actual names, process binding, or root identity.'
    }

    $exitedDiagnosticProcess = [pscustomobject]@{ HasExited = $true }
    $exitedDiagnosticProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
    $runningDiagnosticProcess = [pscustomobject]@{ HasExited = $false }
    $runningDiagnosticProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
    $exitedDiagnosticApplication = [pscustomobject]@{
        owned = [pscustomobject]@{ process = $exitedDiagnosticProcess }
    }
    $runningDiagnosticApplication = [pscustomobject]@{
        owned = [pscustomobject]@{ process = $runningDiagnosticProcess }
    }
    $diagnosticApplication = Select-AcceptanceUiDiagnosticApplication `
        -Applications @($exitedDiagnosticApplication, $runningDiagnosticApplication)
    if (-not [object]::ReferenceEquals(
            $diagnosticApplication,
            $runningDiagnosticApplication
        )) {
        throw 'Failure diagnostics did not select the latest live acceptance application.'
    }

    $actionTarget = [ordered]@{
        pid = 101
        session_id = 1
        hwnd = 4097
        root_hwnd = 4096
        class = 'Button'
        control_id = 0
        automation_id = 'CommandButton_2'
        control_type = 'ControlType.Button'
        enabled = $true
        visible = $true
        focused = $true
    }
    foreach ($automationId in @('CommandButton_2', 'CommandLink_1101', 'CommandLink_1201')) {
        if (-not (Test-AcceptanceControlTargetId `
                -ControlId 0 `
                -AutomationId $automationId)) {
            throw "TaskDialog control ID zero was rejected for $automationId."
        }
    }
    foreach ($invalid in @(
            @{ control_id = 0; automation_id = 'CommandLink_9999' }
            @{ control_id = 0; automation_id = '32771' }
            @{ control_id = 0; automation_id = 'commandbutton_2' }
            @{ control_id = -1; automation_id = 'CommandButton_2' }
        )) {
        if (Test-AcceptanceControlTargetId `
                -ControlId $invalid.control_id `
                -AutomationId $invalid.automation_id) {
            throw "Invalid control target ID was accepted: $($invalid | ConvertTo-Json -Compress)"
        }
    }
    $actionReference = Write-AcceptanceActionEvidence `
        -PrivateRoot $privateRoot -Leaf 'action-test' `
        -Boundary 'startup-default-cancel-action' -Phase 'startup-default-cancel' `
        -Action 'cancel-startup-recovery' -Target $actionTarget `
        -ObservedUtcTicks '638940000000000010' -CompletedUtcTicks '638940000000000011'
    $actionRaw = Get-Content -LiteralPath (Join-Path $privateRoot 'action-test.json') -Raw |
        ConvertFrom-Json
    if ([string]::Join(',', @($actionRaw.PSObject.Properties.Name | Sort-Object)) -cne
        'action,boundary,completed_utc_ticks,dispatch_method,observed_utc_ticks,phase,schema_version,target' -or
        $actionRaw.dispatch_method -cne 'uia-invoke' -or
        $actionRaw.target.control_id -ne 0 -or
        $actionRaw.target.focused -ne $true -or
        $actionReference.boundary -cne 'startup-default-cancel-action') {
        throw 'Raw action evidence omitted its exact target, timestamps, or typed reference.'
    }
    $applyConfirmationTarget = [ordered]@{}
    foreach ($property in $actionTarget.GetEnumerator()) {
        $applyConfirmationTarget[$property.Key] = $property.Value
    }
    $applyConfirmationTarget.automation_id = 'CommandLink_1101'
    Assert-AcceptanceControlTargetRecord -Target $applyConfirmationTarget
    $discardConfirmationTarget = [ordered]@{}
    foreach ($property in $actionTarget.GetEnumerator()) {
        $discardConfirmationTarget[$property.Key] = $property.Value
    }
    $discardConfirmationTarget.automation_id = 'CommandLink_1201'
    $discardConfirmationTarget.focused = $false
    $discardReference = Write-AcceptanceActionEvidence `
        -PrivateRoot $privateRoot -Leaf 'discard-confirm-action-test' `
        -Boundary 'intent-discard-confirm-action' -Phase 'intent-discard-confirm' `
        -Action 'confirm-candidate-discard' -Target $discardConfirmationTarget `
        -ObservedUtcTicks '638940000000000012' -CompletedUtcTicks '638940000000000013'
    $discardRaw = Get-Content `
        -LiteralPath (Join-Path $privateRoot 'discard-confirm-action-test.json') -Raw |
        ConvertFrom-Json
    if ($discardRaw.target.control_id -ne 0 -or
        $discardRaw.target.automation_id -cne 'CommandLink_1201' -or
        $discardRaw.action -cne 'confirm-candidate-discard' -or
        $discardReference.boundary -cne 'intent-discard-confirm-action') {
        throw 'Intent-only discard confirmation did not retain its exact zero-ID target.'
    }
    foreach ($invalid in @(
            @{ control_id = 0; automation_id = 'CommandLink_9999' }
            @{ control_id = 0; automation_id = '32771' }
            @{ control_id = 0; automation_id = 'commandbutton_2' }
            @{ control_id = -1; automation_id = 'CommandButton_2' }
        )) {
        $invalidTarget = [ordered]@{}
        foreach ($property in $actionTarget.GetEnumerator()) {
            $invalidTarget[$property.Key] = $property.Value
        }
        $invalidTarget.control_id = $invalid.control_id
        $invalidTarget.automation_id = $invalid.automation_id
        Assert-Fails {
            Assert-AcceptanceControlTargetRecord -Target $invalidTarget
        } 'incomplete or invalid'
    }
    Assert-Fails {
        Write-AcceptanceActionEvidence `
            -PrivateRoot $privateRoot -Leaf 'action-invalid-order' `
            -Boundary 'startup-default-cancel-action' -Phase 'startup-default-cancel' `
            -Action 'cancel-startup-recovery' -Target $actionTarget `
            -ObservedUtcTicks '638940000000000012' -CompletedUtcTicks '638940000000000011'
    } 'timestamp order'

    $addFilesTarget = [ordered]@{}
    foreach ($property in $actionTarget.GetEnumerator()) {
        $addFilesTarget[$property.Key] = $property.Value
    }
    $addFilesTarget.hwnd = 4098
    $addFilesTarget.control_id = 32791
    $addFilesTarget.automation_id = '32791'
    $addFilesTarget.enabled = $false
    $addFilesTarget.visible = $false
    $addFilesTarget.focused = $false
    $applyTarget = [ordered]@{}
    foreach ($property in $addFilesTarget.GetEnumerator()) {
        $applyTarget[$property.Key] = $property.Value
    }
    $applyTarget.hwnd = 4099
    $applyTarget.control_id = 32771
    $applyTarget.automation_id = '32771'
    $lockReference = Write-AcceptanceLockStateEvidence `
        -PrivateRoot $privateRoot -Leaf 'lock-test' -Boundary 'intent-startup-lock' `
        -Phase 'intent-startup' -CandidatePid 101 -SessionId 1 `
        -Apply $applyTarget -AddFiles $addFilesTarget `
        -ObservedUtcTicks '638940000000000020'
    $lockRaw = Get-Content -LiteralPath (Join-Path $privateRoot 'lock-test.json') -Raw |
        ConvertFrom-Json
    if ([string]::Join(',', @($lockRaw.PSObject.Properties.Name | Sort-Object)) -cne
        'boundary,controls,observed_utc_ticks,phase,process,schema_version' -or
        $lockRaw.process.pid -ne 101 -or
        $lockRaw.controls.apply.control_id -ne 32771 -or
        $lockRaw.controls.add_files.control_id -ne 32791 -or
        $lockReference.boundary -cne 'intent-startup-lock') {
        throw 'Raw recovery lock evidence omitted exact process or control observations.'
    }
    $foreignAddFilesTarget = [ordered]@{}
    foreach ($property in $addFilesTarget.GetEnumerator()) {
        $foreignAddFilesTarget[$property.Key] = $property.Value
    }
    $foreignAddFilesTarget.pid = 202
    Assert-Fails {
        Write-AcceptanceLockStateEvidence `
            -PrivateRoot $privateRoot -Leaf 'lock-foreign' -Boundary 'intent-startup-lock' `
            -Phase 'intent-startup' -CandidatePid 101 -SessionId 1 `
            -Apply $applyTarget -AddFiles $foreignAddFilesTarget `
            -ObservedUtcTicks '638940000000000021'
    } 'one process, session, and root'

    $nestedRoot = Join-Path $privateRoot 'nested'
    [void](New-Item -ItemType Directory -Path $nestedRoot)
    $nestedPath = Join-Path $nestedRoot 'raw.bin'
    [IO.File]::WriteAllBytes($nestedPath, [byte[]](1, 2, 3))
    $nestedReference = New-AcceptancePrivateReference `
        -Path $nestedPath -PrivateRoot $privateRoot -Boundary 'nested-test'
    if ([string]::Join(',', @($nestedReference.PSObject.Properties.Name | Sort-Object)) -cne
        'boundary,bytes,sha256') {
        throw 'A nested private reference exposed its relative path.'
    }

    $indexReference = Write-AcceptancePrivateIndex -PrivateRoot $privateRoot
    if ($indexReference.file_count -ne 7 -or
        $indexReference.bytes -le 0 -or
        $indexReference.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The private index does not bind every pre-index raw file.'
    }
    $indexPath = Join-Path $privateRoot 'private-index.json'
    $indexBytes = [IO.File]::ReadAllBytes($indexPath)
    if ($indexBytes.Length -ge 3 -and
        $indexBytes[0] -eq 0xEF -and $indexBytes[1] -eq 0xBB -and $indexBytes[2] -eq 0xBF) {
        throw 'The private evidence index must be BOM-free UTF-8.'
    }
    $indexRaw = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    if (@($indexRaw.files | Where-Object file -CEQ 'nested/raw.bin').Count -ne 1) {
        throw 'The private evidence index did not canonicalize its nested relative path.'
    }
    foreach ($row in $indexRaw.files) {
        $segments = @($row.file -split '/')
        if ($row.file.Contains('\') -or $segments.Count -lt 1 -or
            @($segments | Where-Object {
                $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
            }).Count -ne 0 -or
            $row.bytes -le 0 -or $row.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'The private evidence index contains an unsafe or unbound row.'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $rawTestRoot -PathType Container) {
        Remove-Item -LiteralPath $rawTestRoot -Recurse -Force
    }
}

$tokens = $null
$errors = $null
$fromFile = [Management.Automation.Language.Parser]::ParseFile(
    $acceptance,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) {
    throw 'The recovery acceptance script has parser errors.'
}
$fixtureCountParameter = @(
    $fromFile.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -ceq 'FixtureCount' }
)
if ($fixtureCountParameter.Count -ne 1 -or
    $fixtureCountParameter[0].DefaultValue.SafeGetValue() -ne 4096) {
    throw 'The recovery acceptance default fixture count must remain within the import bound.'
}
$privateRootParameter = @(
    $fromFile.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -ceq 'PrivateEvidenceRoot' }
)
if ($privateRootParameter.Count -ne 1 -or
    @($privateRootParameter[0].Attributes | Where-Object {
        $_.TypeName.Name -ceq 'Parameter' -and
        @($_.NamedArguments | Where-Object ArgumentName -CEQ 'Mandatory').Count -eq 1
    }).Count -ne 1) {
    throw 'PrivateEvidenceRoot must remain one mandatory observer parameter.'
}
foreach ($switchName in @('RecoveryExport', 'IntentOnlyCandidateDiscard')) {
    $switchParameter = @(
        $fromFile.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -ceq $switchName }
    )
    if ($switchParameter.Count -ne 1 -or
        $switchParameter[0].StaticType.FullName -cne 'System.Management.Automation.SwitchParameter') {
        throw "The recovery acceptance observer is missing opt-in switch $switchName."
    }
}
$screenshotCalls = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Save-WindowScreenshot'
}, $true))
if ($screenshotCalls.Count -ne 2) {
    throw 'The recovery observer must retain exactly two bounded screenshot boundaries.'
}
foreach ($call in $screenshotCalls) {
    $parameterNames = @($call.CommandElements | Where-Object {
        $_ -is [Management.Automation.Language.CommandParameterAst]
    } | ForEach-Object ParameterName)
    if ($parameterNames -cnotcontains 'ForegroundObservations') {
        throw 'Every recovery screenshot must persist the mandatory foreground observation.'
    }
}
$fixtureStateFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Get-AcceptanceFixtureState'
}, $true))
if ($fixtureStateFunction.Count -ne 1 -or
    $fixtureStateFunction[0].Extent.Text.IndexOf(
        'Get-FullFileIdentity', [StringComparison]::Ordinal
    ) -lt 0 -or
    $fixtureStateFunction[0].Extent.Text.IndexOf(
        '[DarkReNamerVmNative]::GetFileIdentity', [StringComparison]::Ordinal
    ) -ge 0) {
    throw 'Fixture inventories must use full FILE_ID_INFO identities only.'
}
$workerBoundaryFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Get-AcceptanceActiveWorkerBoundary'
}, $true))
foreach ($fragment in @(
    "'item-00000.txt'",
    '$firstRenamedName = $Prefix + $firstOriginalName',
    "'first-destination'",
    "'last-original'",
    'observed_utc_ticks',
    'file_identity'
)) {
    if ($workerBoundaryFunction.Count -ne 1 -or
        $workerBoundaryFunction[0].Extent.Text.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "The active worker boundary is missing raw witness material: $fragment"
    }
}
$processExitFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Write-AcceptanceProcessExitEvidence'
}, $true))
foreach ($fragment in @(
    "ValidateSet('normal-close', 'forced-termination', 'worker-close')",
    'start_time_utc_ticks',
    'observed_utc_ticks',
    'exit_observed',
    'exit_method',
    'exit_code'
)) {
    if ($processExitFunction.Count -ne 1 -or
        $processExitFunction[0].Extent.Text.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Raw process-exit evidence is missing lifecycle field or bound: $fragment"
    }
}
$processStartFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Write-AcceptanceProcessStartEvidence'
}, $true))
if ($processStartFunction.Count -ne 1 -or
    $processStartFunction[0].Extent.Text.IndexOf(
        'observed_utc_ticks', [StringComparison]::Ordinal
    ) -lt 0) {
    throw 'Raw process-start evidence is missing its actual observation timestamp.'
}
# The retained kernel handle identifies an exited process even when SessionId
# can no longer be queried after Process.Refresh().
$bindingFunction = $fromFile.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Assert-AcceptanceProcessBinding'
}, $true)
& {
    . ([scriptblock]::Create($bindingFunction.Extent.Text))
    $handle = [pscustomobject]@{ IsClosed = $false; IsInvalid = $false }
    $handle | Add-Member ScriptMethod DangerousGetHandle { [IntPtr]42 }
    $started = [DateTime]::UtcNow
    $process = [pscustomobject]@{ Id = 123; HasExited = $true; StartTime = $started; SafeHandle = $handle }
    $process | Add-Member ScriptMethod Refresh {}
    $process | Add-Member ScriptProperty SessionId { throw 'Exited SessionId must not be read.' }
    $binding = [pscustomobject]@{
        pid = 123; session_id = 2
        start_time_utc_ticks = $started.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $application = [pscustomobject]@{
        owned = [pscustomobject]@{ process = $process }
        raw_process_object = $process; raw_process_handle = [IntPtr]42
        raw_process_binding = $binding
    }
    Assert-AcceptanceProcessBinding -Application $application
    $application.raw_process_handle = [IntPtr]43
    Assert-Fails { Assert-AcceptanceProcessBinding -Application $application } 'identity changed'
    $application.raw_process_handle = [IntPtr]42
    $handle.IsClosed = $true
    Assert-Fails { Assert-AcceptanceProcessBinding -Application $application } 'identity changed'
}
$controlObservationFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Get-AcceptanceControlTargetObservation'
}, $true))
foreach ($fragment in @(
    'Assert-AcceptanceProcessBinding',
    'GetAncestor',
    'GetWindowThreadProcessId',
    'GetDlgCtrlID',
    'FocusedElement',
    'ControlType.Button'
)) {
    if ($controlObservationFunction.Count -ne 1 -or
        $controlObservationFunction[0].Extent.Text.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Raw control observations are missing an ownership or identity field: $fragment"
    }
}
$sessionFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Invoke-AcceptanceSession'
}, $true))
foreach ($fragment in @(
    'startup-before-default-cancel',
    'default-cancel-normal-exit',
    'recovery-relaunch',
    'journal-final-recovered',
    'actions = [ordered]@{',
    'default_cancel = $defaultCancelAction',
    'worker_cancel = $workerCancelAction',
    "-Leaf 'worker-cancellation-action'",
    "-ExitMethod 'forced-termination'"
)) {
    if ($sessionFunction.Count -ne 1 -or
        $sessionFunction[0].Extent.Text.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "The recovery session is missing a raw lifecycle boundary: $fragment"
    }
}
$sessionText = $sessionFunction[0].Extent.Text
$workerObservedIndex = $sessionText.IndexOf('$workerCancelObservedUtcTicks', [StringComparison]::Ordinal)
$workerInvokeIndex = $sessionText.IndexOf(
    "-Element `$workerBoundary.cancel -Label 'active worker cancellation control'",
    [StringComparison]::Ordinal
)
$workerCompletedIndex = $sessionText.IndexOf('$workerCancelCompletedUtcTicks', [StringComparison]::Ordinal)
if ($workerObservedIndex -lt 0 -or $workerInvokeIndex -le $workerObservedIndex -or
    $workerCompletedIndex -le $workerInvokeIndex) {
    throw 'Worker cancellation raw evidence does not bracket the actual owned control invocation.'
}
$observerText = $fromFile.Extent.Text
foreach ($fragment in @(
    "`$result['raw_cleanup']",
    'Get-VmAutomatedOwnedProcessInventory',
    'Get-VmAutomatedJournalInventory',
    'Get-VmAutomatedRuntimeRootObservation',
    'owned_processes_after',
    'runtime_root_after',
    'journal_after'
)) {
    if ($observerText.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "The recovery observer is missing an actual raw cleanup observation: $fragment"
    }
}
$intentScenarioFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Invoke-AcceptanceIntentOnlyCandidateDiscard'
}, $true))
foreach ($fragment in @(
    'InterruptedJournalReference',
    'source_active_journal',
    'injected_candidate',
    'intent-journal-final-exit',
    'actions = [ordered]@{',
    'cancel_discard = $cancelDiscardAction',
    'confirm_discard = $confirmDiscardAction',
    'lock_states = $lockStates'
)) {
    if ($intentScenarioFunction.Count -ne 1 -or
        $intentScenarioFunction[0].Extent.Text.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Intent-only evidence is missing an authenticated raw boundary: $fragment"
    }
}
foreach ($fragment in @(
    "-Leaf 'intent-startup-lock' -Boundary 'intent-startup-lock'",
    "-Leaf 'intent-post-cancel-lock' -Boundary 'intent-post-cancel-lock'",
    "-Leaf 'intent-relaunch-lock' -Boundary 'intent-relaunch-lock'",
    "-Leaf 'intent-discard-startup-lock' -Boundary 'intent-discard-startup-lock'",
    "-Leaf 'intent-post-discard-unlock' -Boundary 'intent-post-discard-unlock'",
    '-ExpectLocked $false'
)) {
    if ($intentScenarioFunction[0].Extent.Text.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Intent-only raw lock evidence is missing a required phase: $fragment"
    }
}
$startupCancelFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Dismiss-AcceptanceStartupRecovery'
}, $true))
foreach ($fragment in @(
    "-Leaf 'startup-default-cancel-action'",
    "-ExpectedAutomationId 'CommandButton_2'",
    '-ExpectedControlId 2',
    "-Action 'cancel-startup-recovery'"
)) {
    if ($startupCancelFunction.Count -ne 1 -or
        $startupCancelFunction[0].Extent.Text.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Startup default-cancel action evidence differs from its fixed contract: $fragment"
    }
}
$discardChoiceFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Invoke-AcceptanceDiscardChoice'
}, $true))
foreach ($fragment in @(
    "'intent-discard-confirm-action'",
    "'intent-discard-cancel-action'",
    '-PrivateRoot $PrivateRoot',
    "'discard-confirm'",
    "'discard-cancel'",
    'Remove-AcceptanceRecoveryMenuProgress',
    "'CommandLink_1201'",
    "'CommandButton_2'",
    "'confirm-candidate-discard'",
    "'cancel-candidate-discard'"
)) {
    if ($discardChoiceFunction.Count -ne 1 -or
        $discardChoiceFunction[0].Extent.Text.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Intent discard action evidence differs from its fixed contract: $fragment"
    }
}
$discardText = $discardChoiceFunction[0].Extent.Text
$discardActionEvidence = $discardText.IndexOf(
    '$actionEvidence = Write-AcceptanceActionEvidence', [StringComparison]::Ordinal
)
$discardProgressRemoval = $discardText.IndexOf(
    'Remove-AcceptanceRecoveryMenuProgress', [StringComparison]::Ordinal
)
if ($discardActionEvidence -lt 0 -or $discardProgressRemoval -le $discardActionEvidence) {
    throw 'Intent discard menu progress is removed before its action evidence is verified.'
}
if ($discardText.IndexOf(
        'Complete-AutomationControlInvoke -State $menuAction',
        [StringComparison]::Ordinal
    ) -ge 0) {
    throw 'Intent discard retained obsolete asynchronous menu invocation completion.'
}
$exportScenarioFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Invoke-AcceptanceRecoveryExport'
}, $true))
if ($exportScenarioFunction.Count -ne 1 -or
    $exportScenarioFunction[0].Extent.Text.IndexOf(
        'source_active_journal', [StringComparison]::Ordinal
    ) -lt 0) {
    throw 'Recovery export must retain the interrupted active-journal source reference.'
}
foreach ($contract in @(
    @{ Name = 'Wait-AcceptanceRecoveryMenuPopup'; Required = @(
        'ReadVisiblePopups', 'ConvertTo-AcceptanceRecoveryMenuObservation',
        '-ActualSession $Process.SessionId',
        '[Math]::Min(30, $TimeoutSeconds)'
    ); Forbidden = @('::RootElement', '.FindAll(', '[Windows.Automation.TreeScope]') },
    @{ Name = 'ConvertTo-AcceptanceRecoveryMenuObservation'; Required = @(
        '$ActualSession -ne $ExpectedSession', '$Inventory.TotalCount -gt 1',
        '$row.ProcessId -ne $ExpectedProcessId', "'#32768'",
        '$row.Right -le $row.Left', '$row.Bottom -le $row.Top'
    ); Forbidden = @('::RootElement', '.FindAll(', '[Windows.Automation.TreeScope]') },
    @{ Name = 'ConvertTo-AcceptanceRecoveryMenuState'; Required = @(
        '$Rows.Count -ne 4', '$row.RootPosition -ne 4',
        '$expectedCommands = @(0x9002, 0x9000, $null, 0x9001)',
        '$highlights.Count -gt 1', '$target.enabled', '$RequireHighlight'
    ); Forbidden = @('::RootElement', '.FindAll(', 'SendMenuCommand') },
    @{ Name = 'Assert-AcceptanceRecoveryMenuForegroundObservation'; Required = @(
        '$Observation.hwnd -ne [long]$MainWindowHandle',
        '$Observation.process_id -ne $ExpectedProcessId',
        '$Observation.session_id -ne $ExpectedSession',
        '$Observation.window_class -cne ''DarkReNamerWindow'''
    ); Forbidden = @('SetForegroundWindow') },
    @{ Name = 'Wait-AcceptanceRecoveryMenuHighlightChange'; Required = @(
        'ReadVisiblePopups', 'Get-AcceptanceRecoveryMenuState',
        '$Process.SessionId -ne $ExpectedSession', 'AddSeconds(2)'
    ); Forbidden = @('::RootElement', '.FindAll(', 'SendMenuCommand') },
    @{ Name = 'Wait-AcceptanceRecoveryMenuClosed'; Required = @(
        'ReadVisiblePopups', '$inventory.TotalCount -eq 0',
        '[Math]::Min(30, $TimeoutSeconds)', '$Process.SessionId -ne $ExpectedSession',
        '$entries[0].Handle -ne $ExpectedPopupHandle'
    ); Forbidden = @('::RootElement', '.FindAll(', 'SendMenuCommand') },
    @{ Name = 'Start-AcceptanceRecoveryMenuInvoke'; Required = @(
        'SendAltR', 'SendKeyTap([uint16]0x28)', 'SendKeyTap([uint16]0x0D)',
        '-Purpose $Purpose', '$navigationCount -ge 4',
        'Wait-AcceptanceRecoveryMenuPopup', "-Phase 'input-returned'",
        "-Phase 'native-popup-found'", "-Phase 'native-menu-bound'",
        "-Phase 'native-command-highlighted'", "-Phase 'native-enter-returned'",
        "-Phase 'popup-found'",
        "-Phase 'menu-item-found'", "-Phase 'invoke-started'"
    ); Forbidden = @('::RootElement', 'SendWait',
        '[Windows.Automation.AutomationElement]::FromHandle',
        'Find-AcceptanceAutomationElementByName', 'Start-AutomationControlInvoke',
        'SendMenuCommand', '0x0111') },
    @{ Name = 'Invoke-AcceptanceRecoveryExport'; Required = @(
        '-Owner $Application.main', "-Phase 'picker-found'", "-Phase 'picker-filled'",
        "-Purpose 'export'", 'Remove-AcceptanceExportProgress'
    ); Forbidden = @('Complete-AutomationControlInvoke -State $menuAction') },
    @{ Name = 'Dismiss-AcceptanceStartupRecovery'; Required = @(
        '[Windows.Automation.AutomationElement] $Prompt', 'if ($null -eq $Prompt)',
        '-Owner $Application.main', 'Assert-AutomationBinding'
    ); Forbidden = @() },
    @{ Name = 'Write-AcceptanceExportProgress'; Required = @(
        'Assert-AcceptanceProcessBinding', 'Write-AcceptanceNewUtf8Json',
        '$Application.raw_process_binding', "'export-progress-' + `$Purpose", 'ValidateSet('
    ); Forbidden = @('WriteAllText') },
    @{ Name = 'Write-AcceptanceRecoveryMenuProgress'; Required = @(
        'Assert-AcceptanceProcessBinding', 'Write-AcceptanceNewUtf8Json',
        '$Application.raw_process_binding', '$Observation', 'ValidateSet('
    ); Forbidden = @('WriteAllText', 'window_title', '.Current.Name') }
)) {
    $functions = @($fromFile.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $contract.Name
    }, $true))
    if ($functions.Count -ne 1) { throw "Missing unique recovery lookup contract: $($contract.Name)" }
    $text = $functions[0].Extent.Text
    foreach ($fragment in $contract.Required) {
        if (-not $text.Contains($fragment)) {
            throw "Recovery lookup contract $($contract.Name) omits $fragment"
        }
    }
    foreach ($fragment in $contract.Forbidden) {
        if ($text.Contains($fragment)) {
            throw "Recovery lookup contract $($contract.Name) contains forbidden $fragment"
        }
    }
}
$menuInvokeFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Start-AcceptanceRecoveryMenuInvoke'
}, $true))
if ($menuInvokeFunction.Count -ne 1) {
    throw 'The recovery menu invocation function is missing or ambiguous.'
}
$menuInvokeText = $menuInvokeFunction[0].Extent.Text
$inputMarker = $menuInvokeText.IndexOf("-Phase 'input-returned'", [StringComparison]::Ordinal)
$inputRejection = $menuInvokeText.IndexOf(
    '$inputResult.RequestedCount -ne 4', [StringComparison]::Ordinal
)
$nativeMarker = $menuInvokeText.IndexOf("-Phase 'native-popup-found'", [StringComparison]::Ordinal)
$menuBoundMarker = $menuInvokeText.IndexOf("-Phase 'native-menu-bound'", [StringComparison]::Ordinal)
$highlightMarker = $menuInvokeText.IndexOf(
    "-Phase 'native-command-highlighted'", [StringComparison]::Ordinal
)
$enterSend = $menuInvokeText.IndexOf('SendKeyTap([uint16]0x0D)', [StringComparison]::Ordinal)
$enterMarker = $menuInvokeText.IndexOf("-Phase 'native-enter-returned'", [StringComparison]::Ordinal)
if ($inputMarker -lt 0 -or $inputRejection -le $inputMarker -or
    $nativeMarker -lt 0 -or $menuBoundMarker -le $nativeMarker -or
    $highlightMarker -le $menuBoundMarker -or $enterSend -le $highlightMarker -or
    $enterMarker -le $enterSend) {
    throw 'Recovery menu diagnostics do not bracket input, native discovery, highlight, and Enter.'
}
if ($exportScenarioFunction[0].Extent.Text.IndexOf('Remove-AcceptanceExportProgress', [StringComparison]::Ordinal) -lt
    $exportScenarioFunction[0].Extent.Text.IndexOf('Get-AcceptanceRecoveryExportClassification', [StringComparison]::Ordinal)) {
    throw 'Export progress diagnostics must survive until exact exported bytes are verified.'
}
$dismissFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Dismiss-AcceptanceMessage'
}, $true))
if ($dismissFunction.Count -ne 1) {
    throw 'The recovery message dismissal function is missing or ambiguous.'
}
foreach ($fragment in @('GetForegroundWindow', 'bounded deadline', 'SetForegroundWindow')) {
    if ($dismissFunction[0].Extent.Text.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Recovery message dismissal does not enforce exact foreground handling: $fragment"
    }
}
$sendKeys = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -ceq 'SendWait'
}, $true))
if ($sendKeys.Count -ne 2) { throw 'Recovery input sites changed without an ownership audit.' }
foreach ($inputCall in $sendKeys) {
    $owner = $inputCall.Parent
    while ($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
    if ($null -eq $owner -or $owner.Name -cnotin @(
            'Dismiss-AcceptanceMessage', 'Invoke-AcceptanceImportAndPrefix'
        ) -or $owner.Extent.Text.IndexOf('GetForegroundWindow', [StringComparison]::Ordinal) -lt 0) {
        throw 'Recovery input bypasses the audited exact-foreground helpers.'
    }
}
$nativeInitializer = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Initialize-AcceptanceRecoveryMenuNative'
}, $true))
if ($nativeInitializer.Count -ne 1) {
    throw 'The bounded native recovery-menu initializer is missing or ambiguous.'
}
$nativeText = $nativeInitializer[0].Extent.Text
foreach ($fragment in @(
    'public static KeyboardResult SendAltR()',
    'public static KeyboardResult SendKeyTap(ushort virtualKey)',
    'public static PopupInventory ReadVisiblePopups(uint expectedProcessId)',
    'public static RecoveryMenuItemObservation[] ReadRecoveryMenuItems(IntPtr window)',
    'SendInput(4, inputs',
    'SendInput(2, inputs',
    'Key(0x12, 0)',
    'Key(0x52, 0)',
    'Key(0x52, 2)',
    'Key(0x12, 2)',
    'EnumWindows',
    'IsWindowVisible',
    'processId != expectedProcessId',
    'String.Equals(className.ToString(), "#32768", StringComparison.Ordinal)',
    'if (totalCount <= 2)',
    'const int recoveryRootPosition = 4',
    'GetMenuItemCount(root) != 6',
    'GetMenuItemCount(recovery) != 4',
    'GetMenuState(recovery, (uint)position, 0x400)',
    'GetMenuItemInfoW(recovery',
    'GetMenuItemRect(IntPtr.Zero, recovery'
)) {
    if ($nativeText.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Native recovery-menu helper omits its bounded contract: $fragment"
    }
}
if ($nativeText.IndexOf('GetWindowText', [StringComparison]::Ordinal) -ge 0 -or
    $nativeText.IndexOf('Title', [StringComparison]::Ordinal) -ge 0) {
    throw 'Native recovery-menu diagnostics must not capture window titles.'
}
Initialize-AcceptanceRecoveryMenuNative
$nativeType = 'DarkReNamerRecoveryMenuNative' -as [type]
if ($null -eq $nativeType -or
    $null -eq $nativeType.GetMethod('SendAltR') -or
    $null -eq $nativeType.GetMethod('SendKeyTap') -or
    $null -eq $nativeType.GetMethod('ReadVisiblePopups') -or
    $null -eq $nativeType.GetMethod('ReadRecoveryMenuItems')) {
    throw 'The native recovery-menu helper did not compile with its callable API.'
}
$keyboardProperties = @(
    $nativeType.GetNestedType('KeyboardResult').GetProperties().Name | Sort-Object
)
if ([string]::Join(',', $keyboardProperties) -cne
    'ErrorCode,ReleaseSentCount,RequestedCount,SentCount') {
    throw 'The native recovery-menu keyboard result shape changed.'
}
$inventoryProperties = @(
    $nativeType.GetNestedType('PopupInventory').GetProperties().Name | Sort-Object
)
if ([string]::Join(',', $inventoryProperties) -cne 'Entries,TotalCount') {
    throw 'The native recovery-menu popup inventory shape changed.'
}
$menuItemProperties = @(
    $nativeType.GetNestedType('RecoveryMenuItemObservation').GetProperties().Name | Sort-Object
)
if ([string]::Join(',', $menuItemProperties) -cne
    'Bottom,CommandId,ItemType,Left,Position,Right,RootPosition,StateFlags,Top') {
    throw 'The native recovery-menu item observation shape changed.'
}
$removeProgressFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Remove-AcceptanceExportProgress'
}, $true))
if ($removeProgressFunction.Count -ne 1) {
    throw 'The recovery progress cleanup function is missing or ambiguous.'
}
$removeMenuProgressFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Remove-AcceptanceRecoveryMenuProgress'
}, $true))
if ($removeMenuProgressFunction.Count -ne 1 -or
    $removeProgressFunction[0].Extent.Text.IndexOf(
        "-Purpose 'export'", [StringComparison]::Ordinal
    ) -lt 0) {
    throw 'Purpose-bound recovery menu progress cleanup is missing or ambiguous.'
}
foreach ($phase in @('input-returned', 'native-popup-found', 'native-menu-bound',
        'navigation-1', 'navigation-2', 'navigation-3', 'navigation-4',
        'native-command-highlighted', 'native-enter-returned')) {
    if ($removeMenuProgressFunction[0].Extent.Text.IndexOf($phase, [StringComparison]::Ordinal) -lt 0) {
        throw "Recovery menu progress cleanup omits $phase."
    }
}
$intentFunction = @($fromFile.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Get-AcceptanceLeadingIntentFrame'
}, $true))
if ($intentFunction.Count -ne 1 -or
    $intentFunction[0].Extent.Text.IndexOf(
        'Get-AcceptanceJournalInspection',
        [StringComparison]::Ordinal
    ) -ge 0) {
    throw 'Leading Intent extraction must reuse the caller validated journal inspection.'
}
$fromUtf8 = [Management.Automation.Language.Parser]::ParseInput(
    [IO.File]::ReadAllText($acceptance, [Text.Encoding]::UTF8),
    [ref]$tokens,
    [ref]$errors
)
$stringNode = { param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }
$fileStrings = @($fromFile.FindAll($stringNode, $true) | ForEach-Object Value)
$utf8Strings = @($fromUtf8.FindAll($stringNode, $true) | ForEach-Object Value)
if ($fileStrings.Count -ne $utf8Strings.Count) {
    throw 'Recovery acceptance string decoding differs from explicit UTF-8 parsing.'
}
for ($index = 0; $index -lt $fileStrings.Count; $index++) {
    if ($fileStrings[$index] -cne $utf8Strings[$index]) {
        throw 'Recovery acceptance string decoding differs from explicit UTF-8 parsing.'
    }
}

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
    $PSVersionTable.PSVersion.Major -ge 7) {
    # Mandatory array argument binding scales differently in Windows PowerShell
    # 5.1, the observer runtime. Exercise the many-frame case there as well.
    $invocation = "`$ErrorActionPreference = 'Stop'; & '" + $PSCommandPath.Replace("'", "''") + "' -ParserOnly"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process.StartInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -EncodedCommand $encoded"
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) {
            throw 'Windows PowerShell journal parser test did not start.'
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {
            throw 'Windows PowerShell journal parser test exceeded its 90-second deadline.'
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Windows PowerShell journal parser test failed: $($stderr.GetAwaiter().GetResult())"
        }
        Write-Host $stdout.GetAwaiter().GetResult().TrimEnd()
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(10000)
        }
        $process.Dispose()
    }
}

Write-Host 'Windows VM recovery acceptance script tests passed.'
