[CmdletBinding()]
param()

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
    @{ Text = $menuSource; Value = 'recovery.item(EXPORT_RECOVERY_JOURNAL, "복구 데이터 내보내기...")?' },
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
. $acceptance `
    -BundleRoot $PSScriptRoot `
    -ExpectedSessionId 1 `
    -OutputRoot $PSScriptRoot `
    -ExpectedScriptSha256 ('0' * 64)

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
        -CandidateRemoved $true `
        -ActiveAbsent $true `
        -DiscardUnlocked $true `
        -DiscardUnchanged $true
} 'cancelled discard did not preserve'
Assert-Fails {
    Get-AcceptanceIntentCandidateClassification `
        -JournalInspection $inspection `
        -StartupLocked $true `
        -StartupUnchanged $true `
        -CancelPreserved $true `
        -CancelUnchanged $true `
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
        -ExpectedScriptSha256 $observerHash `
        -Mode WorkerCancellation `
        -ValidateOnly

    & $acceptance `
        -BundleRoot $valid.root `
        -ExpectedSessionId 1 `
        -OutputRoot $temporaryRoot `
        -ExpectedScriptSha256 $observerHash `
        -Mode ProcessCrash `
        -RecoveryExport `
        -IntentOnlyCandidateDiscard `
        -ValidateOnly

    Assert-Fails {
        & $acceptance `
            -BundleRoot $valid.root `
            -ExpectedSessionId 1 `
            -OutputRoot $temporaryRoot `
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
                -ExpectedScriptSha256 $observerHash `
                -Mode WorkerClose
        } 'execution requires Windows'
    }

    Assert-Fails {
        & $acceptance `
            -BundleRoot $valid.root `
            -ExpectedSessionId 1 `
            -OutputRoot $temporaryRoot `
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
    $invocation = "`$ErrorActionPreference = 'Stop'; & '" + $PSCommandPath.Replace("'", "''") + "'"
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
            throw 'Windows PowerShell recovery tooling test did not start.'
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {
            throw 'Windows PowerShell recovery tooling test exceeded its 90-second deadline.'
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Windows PowerShell recovery tooling test failed: $($stderr.GetAwaiter().GetResult())"
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
