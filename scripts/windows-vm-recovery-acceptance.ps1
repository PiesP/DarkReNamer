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

    [switch] $RecoveryExport,

    [switch] $IntentOnlyCandidateDiscard,

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

function Test-AcceptanceBytesEqual {
    param(
        [Parameter(Mandatory)][byte[]] $Expected,
        [Parameter(Mandatory)][byte[]] $Actual
    )

    if ($Expected.Length -ne $Actual.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            return $false
        }
    }
    $true
}

function Get-AcceptanceLeadingIntentFrame {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][object] $Inspection
    )

    if ($Inspection.total_bytes -ne $Bytes.Length -or
        $Inspection.valid_prefix_bytes -gt $Bytes.Length -or
        $Inspection.complete_frames -lt 1 -or
        $Bytes[6] -ne 1) {
        throw 'Journal does not contain one complete leading Intent frame.'
    }
    $frameLength = 24L + [int64](Get-AcceptanceUInt32 -Bytes $Bytes -Offset 16)
    if ($frameLength -gt $Bytes.Length -or $frameLength -gt [int]::MaxValue) {
        throw 'The leading Intent frame length is outside the captured journal.'
    }
    $intent = [byte[]]::new([int]$frameLength)
    [Array]::Copy($Bytes, 0, $intent, 0, $intent.Length)
    $intent
}

function Get-AcceptanceRecoveryExportClassification {
    param(
        [Parameter(Mandatory)][byte[]] $ExpectedBytes,
        [Parameter(Mandatory)][byte[]] $ExportedBytes,
        [Parameter(Mandatory)][string[]] $ExportedLeaves
    )

    if ($ExportedLeaves.Count -ne 1 -or $ExportedLeaves[0] -cne 'active.drj.retained') {
        throw 'Recovery export created unexpected retained files.'
    }
    if (-not (Test-AcceptanceBytesEqual -Expected $ExpectedBytes -Actual $ExportedBytes)) {
        throw 'The exported retained journal differs from the captured active journal.'
    }
    'active-retained-exact'
}

function Get-AcceptanceRecoveryExportFile {
    param([Parameter(Mandatory)][string] $Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'The recovery export directory is unavailable.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The recovery export directory became a reparse point.'
    }
    $items = @(Get-ChildItem -LiteralPath $rootItem.FullName -Force)
    if ($items.Count -ne 1) {
        throw 'The recovery export must contain exactly one ordinary file.'
    }
    $item = $items[0]
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Name -cne 'active.drj.retained' -or
        $item.Length -gt 64MB) {
        throw 'The recovery export must contain exactly one ordinary file named active.drj.retained.'
    }
    $item
}

function Get-AcceptanceIntentCandidateClassification {
    param(
        [Parameter(Mandatory)][object] $JournalInspection,
        [Parameter(Mandatory)][bool] $StartupLocked,
        [Parameter(Mandatory)][bool] $StartupUnchanged,
        [Parameter(Mandatory)][bool] $CancelPreserved,
        [Parameter(Mandatory)][bool] $CancelUnchanged,
        [Parameter(Mandatory)][bool] $CandidateRemoved,
        [Parameter(Mandatory)][bool] $ActiveAbsent,
        [Parameter(Mandatory)][bool] $DiscardUnlocked,
        [Parameter(Mandatory)][bool] $DiscardUnchanged
    )

    if ($JournalInspection.complete_frames -ne 1 -or
        $JournalInspection.last_kind -ne 1 -or
        $JournalInspection.terminal -or
        $JournalInspection.tail -cne 'none' -or
        $JournalInspection.valid_prefix_bytes -ne $JournalInspection.total_bytes) {
        throw 'The staged candidate is not one exact complete Intent-only frame.'
    }
    if (-not $StartupLocked -or -not $StartupUnchanged) {
        throw 'Intent-only startup did not remain recovery-locked and mutation-free.'
    }
    if (-not $CancelPreserved -or -not $CancelUnchanged) {
        throw 'The cancelled discard did not preserve the candidate and fixture state.'
    }
    if (-not $CandidateRemoved -or -not $ActiveAbsent -or -not $DiscardUnlocked -or
        -not $DiscardUnchanged) {
        throw 'The confirmed discard did not remove only the candidate, unlock, and preserve the fixture.'
    }
    'intent-only-cancel-preserved-discard-unlocked'
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
        [Parameter(Mandatory)][bool] $FirstDestinationObserved,
        [Parameter(Mandatory)][bool] $LastOriginalObserved,
        [Parameter(Mandatory)][bool] $WitnessesRechecked,
        [Parameter(Mandatory)][bool] $ActiveJournalExists,
        [Parameter(Mandatory)][bool] $CandidateJournalExists,
        [Parameter(Mandatory)][bool] $CancelEnabled,
        [Parameter(Mandatory)][bool] $CancelVisible
    )

    if (-not $FirstDestinationObserved -or
        -not $LastOriginalObserved -or
        -not $WitnessesRechecked) {
        throw 'The worker boundary does not have stable partial-rename witnesses.'
    }
    if (-not $ActiveJournalExists -or $CandidateJournalExists) {
        throw 'The worker boundary does not have one unambiguous active journal.'
    }
    if (-not $CancelEnabled -or -not $CancelVisible) {
        throw 'The worker boundary does not expose one active cancellation control.'
    }
    'partial-active-worker'
}

function Assert-AcceptanceExactProperties {
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string[]] $Names,
        [Parameter(Mandatory)][string] $Label
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if ($actual.Count -ne $expected.Count) {
        throw "$Label has unexpected fields."
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($actual[$index] -cne $expected[$index]) {
            throw "$Label has unexpected fields."
        }
    }
}

function Get-AcceptanceBootstrapSha256 {
    param([Parameter(Mandatory)][string] $Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AcceptanceBootstrapBytesSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $algorithm.ComputeHash($Bytes)
        ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Resolve-AcceptanceBootstrap {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ObserverPath,
        [Parameter(Mandatory)][string] $ExpectedObserverSha256
    )

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be absolute.'
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'BundleRoot must be an existing directory.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BundleRoot must not be a reparse point.'
    }
    $manifestPath = Join-Path $rootItem.FullName 'bundle.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The bootstrap bundle manifest is missing.'
    }
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force
    if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $manifestItem.Length -gt 1MB) {
        throw 'The bootstrap bundle manifest is unsafe or too large.'
    }
    $manifestText = [IO.File]::ReadAllText($manifestItem.FullName)
    if ($manifestText.IndexOf([char]0) -ge 0) {
        throw 'The bootstrap bundle manifest contains NUL.'
    }
    try {
        $manifest = $manifestText | ConvertFrom-Json
    }
    catch {
        throw 'The bootstrap bundle manifest is not valid JSON.'
    }
    if ($null -eq $manifest -or $null -eq $manifest.runner) {
        throw 'The bootstrap bundle manifest has no runner object.'
    }
    Assert-AcceptanceExactProperties `
        -Value $manifest.runner `
        -Names @('file', 'sha256') `
        -Label 'bootstrap runner'
    if ($manifest.runner.file -isnot [string] -or
        $manifest.runner.file -cne 'windows-vm-guest.ps1') {
        throw 'The bootstrap runner leaf is invalid.'
    }
    if ($manifest.runner.sha256 -isnot [string] -or
        $manifest.runner.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The bootstrap runner SHA-256 is invalid.'
    }
    $runnerPath = Join-Path $rootItem.FullName 'windows-vm-guest.ps1'
    if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
        throw 'The frozen guest helper is missing.'
    }
    $runnerItem = Get-Item -LiteralPath $runnerPath -Force
    if (($runnerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $runnerItem.Length -gt 2MB) {
        throw 'The frozen guest helper must be an ordinary bounded file.'
    }
    $runnerBytes = [IO.File]::ReadAllBytes($runnerItem.FullName)
    $runnerSha256 = Get-AcceptanceBootstrapBytesSha256 -Bytes $runnerBytes
    if ($runnerSha256 -cne $manifest.runner.sha256) {
        throw 'The bootstrap runner hash does not match bundle.json.'
    }
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $runnerText = $strictUtf8.GetString($runnerBytes)
    }
    catch {
        throw 'The authenticated guest helper is not valid UTF-8.'
    }
    if ($runnerText.Length -gt 0 -and $runnerText[0] -eq [char]0xFEFF) {
        $runnerText = $runnerText.Substring(1)
    }
    try {
        $runnerScript = [scriptblock]::Create($runnerText)
    }
    catch {
        throw 'The authenticated guest helper has parser errors.'
    }

    if ($ExpectedObserverSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        -not (Test-Path -LiteralPath $ObserverPath -PathType Leaf)) {
        throw 'The recovery acceptance observer bootstrap input is invalid.'
    }
    $observerItem = Get-Item -LiteralPath $ObserverPath -Force
    if ($observerItem.Name -cne 'windows-vm-recovery-acceptance.ps1' -or
        ($observerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The recovery acceptance observer bootstrap file is invalid.'
    }
    $observerSha256 = Get-AcceptanceBootstrapSha256 -Path $observerItem.FullName
    if ($observerSha256 -cne $ExpectedObserverSha256) {
        throw 'The recovery acceptance observer hash does not match its staging contract.'
    }
    [pscustomobject]@{
        root = $rootItem.FullName
        runner_path = $runnerItem.FullName
        runner_script = $runnerScript
        runner_sha256 = $runnerSha256
        observer_sha256 = $observerSha256
    }
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

function Stop-AndDisposeAcceptanceOwnedProcess {
    param([Parameter(Mandatory)][object] $Owned)

    $process = $Owned.process
    try {
        $process.Refresh()
        if (-not $process.HasExited) {
            $process.Kill()
            if (-not $process.WaitForExit(10000)) {
                throw 'The exact owned acceptance process did not terminate.'
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
                Stop-AndDisposeAcceptanceOwnedProcess -Owned $owned
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

function Find-AcceptanceAutomationElementByName {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Root,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][Windows.Automation.ControlType] $ControlType,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label,
        [switch] $RequireEnabled,
        [switch] $RequireVisible
    )

    $conditions = [Windows.Automation.Condition[]]@(
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ProcessIdProperty,
            $Process.Id
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty,
            $Name
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            $ControlType
        )
    )
    $condition = [Windows.Automation.AndCondition]::new($conditions)
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $matches = $Root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
        if ($matches.Count -gt 1) {
            throw "$Label matched more than one automation element."
        }
        if ($matches.Count -eq 1) {
            $element = $matches.Item(0)
            Assert-AutomationBinding `
                -Element $element `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label $Label
            if ($RequireEnabled -and -not $element.Current.IsEnabled) {
                throw "$Label is not enabled."
            }
            if ($RequireVisible -and $element.Current.IsOffscreen) {
                throw "$Label is not visible."
            }
            return $element
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Label was not found before the application exited."
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Label was not found before the bounded deadline."
}

function Start-AcceptanceRecoveryMenuInvoke {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $ItemName,
        [Parameter(Mandatory)][string] $Label
    )

    Add-Type -AssemblyName System.Windows.Forms
    $process = $Application.owned.process
    $main = $Application.main
    $main.SetFocus()
    $mainHandle = [IntPtr]$main.Current.NativeWindowHandle
    [void][DarkReNamerVmNative]::SetForegroundWindow($mainHandle)
    $deadline = (Get-Date).AddSeconds(5)
    while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle -and
        (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $mainHandle) {
        throw "The verified application is not foreground for $Label."
    }
    [Windows.Forms.SendKeys]::SendWait('%r')
    $item = Find-AcceptanceAutomationElementByName `
        -Root ([Windows.Automation.AutomationElement]::RootElement) `
        -Process $process `
        -ExpectedSession $SessionId `
        -Name $ItemName `
        -ControlType ([Windows.Automation.ControlType]::MenuItem) `
        -TimeoutSeconds $WaitSeconds `
        -Label $Label `
        -RequireEnabled `
        -RequireVisible
    Start-AutomationControlInvoke -Element $item -Label $Label
}

function Dismiss-AcceptanceMessage {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Label
    )

    Add-Type -AssemblyName System.Windows.Forms
    $window = Wait-UniqueAutomationWindow `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -Name $Name `
        -TimeoutSeconds $WaitSeconds `
        -Label $Label
    Assert-AutomationBinding `
        -Element $window `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -Label $Label `
        -RequireWindowHandle
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
    $firstIdentity = [DarkReNamerVmNative]::GetFileIdentity($firstItem.FullName)
    $lastIdentity = [DarkReNamerVmNative]::GetFileIdentity($lastItem.FullName)
    $firstContent = Get-LowerSha256 -Path $firstItem.FullName
    $lastContent = Get-LowerSha256 -Path $lastItem.FullName
    if ($firstIdentity -cne $InitialFirst.identity -or
        $lastIdentity -cne $InitialLast.identity -or
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
        first_destination_identity_sha256 = Get-LowerTextSha256 -Value $firstIdentity
        last_original_identity_sha256 = Get-LowerTextSha256 -Value $lastIdentity
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

function Dismiss-AcceptanceStartupRecovery {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $process = $Application.owned.process
    $prompt = Wait-UniqueAutomationWindow `
        -Process $process `
        -ExpectedSession $SessionId `
        -Name 'DarkReNamer - 이전 변경 복구 확인' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'startup recovery cancellation prompt'
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
    Invoke-AutomationControl -Element $cancel -Label 'startup recovery cancellation button'
    Wait-WindowClosed `
        -Handle $promptHandle `
        -TimeoutSeconds $WaitSeconds `
        -Label 'startup recovery cancellation prompt'
}

function Invoke-AcceptanceRecoveryExport {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][byte[]] $ExpectedBytes,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $exportRoot = New-PrivateDirectory -Parent $EvidenceRoot -Leaf 'recovery-export'
    $invoke = Start-AcceptanceRecoveryMenuInvoke `
        -Application $Application `
        -SessionId $SessionId `
        -WaitSeconds $WaitSeconds `
        -ItemName '복구 데이터 내보내기...' `
        -Label 'recovery export menu item'
    $dialog = Wait-UniqueAutomationWindow `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -Name '복구 저널 원본을 저장할 폴더 선택' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'recovery export folder picker'
    $dialogHandle = [IntPtr]$dialog.Current.NativeWindowHandle
    $folder = Find-UniqueAutomationElement `
        -Root $dialog `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -AutomationId '1148' `
        -ControlType ([Windows.Automation.ControlType]::Edit) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'recovery export folder path' `
        -RequireWindowHandle
    Set-AutomationControlValue `
        -Element $folder `
        -Value $exportRoot `
        -Label 'recovery export folder path'
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
        -Label 'recovery export completion message'
    Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $WaitSeconds

    $exportItem = Get-AcceptanceRecoveryExportFile -Root $exportRoot
    $leaves = @($exportItem.Name)
    $exportPath = $exportItem.FullName
    $exportedBytes = [IO.File]::ReadAllBytes($exportPath)
    $classification = Get-AcceptanceRecoveryExportClassification `
        -ExpectedBytes $ExpectedBytes `
        -ExportedBytes $exportedBytes `
        -ExportedLeaves $leaves
    [pscustomobject]@{
        status = 'passed'
        classification = $classification
        directory = 'recovery-export'
        file = 'active.drj.retained'
        bytes = $exportedBytes.Length
        sha256 = Get-LowerSha256 -Path $exportPath
        captured_active_sha256 = Get-AcceptanceBootstrapBytesSha256 -Bytes $ExpectedBytes
        exact_bytes = $true
    }
}

function Assert-AcceptanceRecoveryLockedControls {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $apply = Find-UniqueAutomationElement `
        -Root $Application.main `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -AutomationId '32771' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'Apply while Intent-only recovery is locked' `
        -RequireWindowHandle
    $add = Find-UniqueAutomationElement `
        -Root $Application.main `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -AutomationId '32791' `
        -ControlType ([Windows.Automation.ControlType]::Button) `
        -TimeoutSeconds $WaitSeconds `
        -Label 'Add Files while Intent-only recovery is locked' `
        -RequireWindowHandle
    if ($apply.Current.IsEnabled -or $add.Current.IsEnabled) {
        throw 'Intent-only startup did not disable Apply and Add Files under recovery lock.'
    }
    $true
}

function Invoke-AcceptanceDiscardChoice {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][bool] $Confirm
    )

    $invoke = Start-AcceptanceRecoveryMenuInvoke `
        -Application $Application `
        -SessionId $SessionId `
        -WaitSeconds $WaitSeconds `
        -ItemName '시작되지 않은 작업 기록 삭제...' `
        -Label 'Intent-only candidate discard menu item'
    $prompt = Wait-UniqueAutomationWindow `
        -Process $Application.owned.process `
        -ExpectedSession $SessionId `
        -Name 'DarkReNamer - 활성화 전 계획 폐기' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'Intent-only candidate discard confirmation'
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
            -Label 'candidate discard completion message'
    }
    Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $WaitSeconds
}

function Invoke-AcceptanceIntentOnlyCandidateDiscard {
    param(
        [Parameter(Mandatory)][object] $Inputs,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][object[]] $Initial,
        [Parameter(Mandatory)][byte[]] $IntentBytes,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $inspection = Get-AcceptanceJournalInspection -Bytes $IntentBytes
    $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
    $candidatePath = Join-Path $journalRoot 'candidate.drj'
    $activePath = Join-Path $journalRoot 'active.drj'
    if ((Test-Path -LiteralPath $candidatePath) -or
        (Test-Path -LiteralPath $activePath)) {
        throw 'Intent-only staging requires a clean isolated journal profile.'
    }
    [IO.File]::WriteAllBytes($candidatePath, $IntentBytes)
    $stagedState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
    Assert-AcceptanceStatesEqual -Expected $Initial -Actual $stagedState -Label 'Intent-only staging fixture'

    $cancelApplication = $null
    $discardApplication = $null
    $scenarioError = $null
    try {
        $cancelApplication = Start-AcceptanceApplication `
            -Inputs $Inputs `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds
        $startupNotice = Wait-UniqueAutomationWindow `
            -Process $cancelApplication.owned.process `
            -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 복구 상태' `
            -TimeoutSeconds $WaitSeconds `
            -Label 'Intent-only startup recovery-lock notice'
        $null = $startupNotice
        $startupState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $Initial `
            -Actual $startupState `
            -Label 'Intent-only startup fixture'
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf) -or
            (Test-Path -LiteralPath $activePath)) {
            throw 'Intent-only startup did not preserve one candidate without an active journal.'
        }
        Dismiss-AcceptanceMessage `
            -Application $cancelApplication `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds `
            -Name 'DarkReNamer - 복구 상태' `
            -Label 'Intent-only startup recovery-lock notice'
        $startupLocked = Assert-AcceptanceRecoveryLockedControls `
            -Application $cancelApplication `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds

        Invoke-AcceptanceDiscardChoice `
            -Application $cancelApplication `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds `
            -Confirm $false
        $cancelState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $Initial `
            -Actual $cancelState `
            -Label 'Cancelled Intent-only discard fixture'
        $cancelPreserved = (Test-Path -LiteralPath $candidatePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $activePath)
        if (-not $cancelPreserved) {
            throw 'Cancelling Intent-only discard did not preserve only candidate.drj.'
        }
        [void](Close-AcceptanceApplicationNormally `
            -Application $cancelApplication `
            -WaitSeconds $WaitSeconds)
        $preservedBytes = [IO.File]::ReadAllBytes($candidatePath)
        if (-not (Test-AcceptanceBytesEqual -Expected $IntentBytes -Actual $preservedBytes)) {
            throw 'Cancelling Intent-only discard did not preserve the exact candidate bytes.'
        }

        $discardApplication = Start-AcceptanceApplication `
            -Inputs $Inputs `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds
        Dismiss-AcceptanceMessage `
            -Application $discardApplication `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds `
            -Name 'DarkReNamer - 복구 상태' `
            -Label 'Intent-only discard relaunch recovery-lock notice'
        [void](Assert-AcceptanceRecoveryLockedControls `
            -Application $discardApplication `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds)
        $beforeConfirm = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $Initial `
            -Actual $beforeConfirm `
            -Label 'Intent-only discard relaunch fixture'
        Invoke-AcceptanceDiscardChoice `
            -Application $discardApplication `
            -SessionId $SessionId `
            -WaitSeconds $WaitSeconds `
            -Confirm $true
        $candidateRemoved = -not (Test-Path -LiteralPath $candidatePath)
        $activeAbsent = -not (Test-Path -LiteralPath $activePath)
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $add = Find-UniqueAutomationElement `
            -Root $discardApplication.main `
            -Process $discardApplication.owned.process `
            -ExpectedSession $SessionId `
            -AutomationId '32791' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $WaitSeconds `
            -Label 'Add Files after Intent-only candidate discard' `
            -RequireEnabled `
            -RequireWindowHandle
        $discardUnlocked = $add.Current.IsEnabled
        $discardState = Get-AcceptanceFixtureState -FixtureRoot $FixtureRoot
        Assert-AcceptanceStatesEqual `
            -Expected $Initial `
            -Actual $discardState `
            -Label 'Confirmed Intent-only discard fixture'
        $classification = Get-AcceptanceIntentCandidateClassification `
            -JournalInspection $inspection `
            -StartupLocked $startupLocked `
            -StartupUnchanged $true `
            -CancelPreserved $cancelPreserved `
            -CancelUnchanged $true `
            -CandidateRemoved $candidateRemoved `
            -ActiveAbsent $activeAbsent `
            -DiscardUnlocked $discardUnlocked `
            -DiscardUnchanged $true
        $exitCode = Close-AcceptanceApplicationNormally `
            -Application $discardApplication `
            -WaitSeconds $WaitSeconds
        [pscustomobject]@{
            status = 'passed'
            classification = $classification
            candidate = [ordered]@{
                source = 'interrupted-active.drj:first-intent-frame'
                file = 'candidate.drj'
                bytes = $IntentBytes.Length
                sha256 = Get-AcceptanceBootstrapBytesSha256 -Bytes $IntentBytes
                complete_frames = $inspection.complete_frames
                last_kind = $inspection.last_kind
                tail = $inspection.tail
            }
            startup_locked = $startupLocked
            startup_state_sha256 = Get-AcceptanceStateDigest -State $startupState
            cancel_preserved_exact_bytes = $true
            cancel_state_sha256 = Get-AcceptanceStateDigest -State $cancelState
            candidate_removed = $candidateRemoved
            active_absent = $activeAbsent
            discard_unlocked = $discardUnlocked
            fixture_name_content_identity_unchanged = $true
            discard_state_sha256 = Get-AcceptanceStateDigest -State $discardState
            normal_exit_code = $exitCode
        }
    }
    catch {
        $scenarioError = $_
        throw
    }
    finally {
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        foreach ($application in @($cancelApplication, $discardApplication)) {
            if ($null -eq $application) { continue }
            try {
                Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned
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
    $initial = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
    if ($initial.Count -ne $Count + 1) {
        throw 'The initial fixture count is incorrect.'
    }
    $initialFirst = @($initial | Where-Object name -CEQ 'item-00000.txt')
    $initialLastName = 'item-{0:D5}.txt' -f ($Count - 1)
    $initialLast = @($initial | Where-Object name -CEQ $initialLastName)
    if ($initialFirst.Count -ne 1 -or $initialLast.Count -ne 1) {
        throw 'The initial fixture does not contain unique boundary witnesses.'
    }

    $first = $null
    $second = $null
    $third = $null
    $sessionError = $null
    $recoveryExportResult = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
    $intentDiscardResult = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
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
            $workerCancel = Find-UniqueAutomationElement `
                -Root $first.main `
                -Process $first.owned.process `
                -ExpectedSession $SessionId `
                -AutomationId '1009' `
                -ControlType ([Windows.Automation.ControlType]::Button) `
                -TimeoutSeconds $WaitSeconds `
                -Label 'visible worker cancellation control' `
                -Scope ([Windows.Automation.TreeScope]::Children) `
                -RequireEnabled `
                -RequireWindowHandle
            $workerBoundary = Get-AcceptanceActiveWorkerBoundary `
                -Application $first `
                -Cancel $workerCancel `
                -FixtureRoot $fixtureRoot `
                -Prefix $prefix `
                -LocalAppData $env:LOCALAPPDATA `
                -InitialFirst $initialFirst[0] `
                -InitialLast $initialLast[0] `
                -ExpectedCount $Count `
                -SessionId $SessionId
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
                        journal_residue_count = 0
                        screenshot = $screenshot
                        normal_exit_code = $exitCode
                    }
                    recovery_export = $recoveryExportResult
                    intent_only_candidate_discard = $intentDiscardResult
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
                    journal_residue_count = 0
                    screenshot = $null
                    normal_exit_code = $exitCode
                }
                recovery_export = $recoveryExportResult
                intent_only_candidate_discard = $intentDiscardResult
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
        $intentBytes = $null
        if ($RunIntentOnlyCandidateDiscard) {
            $intentBytes = Get-AcceptanceLeadingIntentFrame `
                -Bytes $journalBytes `
                -Inspection $inspection
        }
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

        $recoveryApplication = $second
        if ($RunRecoveryExport) {
            Dismiss-AcceptanceStartupRecovery `
                -Application $second `
                -SessionId $SessionId `
                -WaitSeconds $WaitSeconds
            $recoveryExportResult = Invoke-AcceptanceRecoveryExport `
                -Application $second `
                -EvidenceRoot $EvidenceRoot `
                -ExpectedBytes $journalBytes `
                -SessionId $SessionId `
                -WaitSeconds $WaitSeconds
            $afterExport = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
            Assert-AcceptanceStatesEqual `
                -Expected $beforeRestart `
                -Actual $afterExport `
                -Label 'Recovery export fixture'
            $recoveryExportResult | Add-Member `
                -NotePropertyName fixture_name_content_identity_unchanged `
                -NotePropertyValue $true
            [void](Close-AcceptanceApplicationNormally `
                -Application $second `
                -WaitSeconds $WaitSeconds)
            $third = Start-AcceptanceApplication `
                -Inputs $Inputs `
                -SessionId $SessionId `
                -WaitSeconds $WaitSeconds
            $recoveryPrompt = Wait-UniqueAutomationWindow `
                -Process $third.owned.process `
                -ExpectedSession $SessionId `
                -Name 'DarkReNamer - 이전 변경 복구 확인' `
                -TimeoutSeconds $WaitSeconds `
                -Label 'startup recovery confirmation after export'
            Assert-AutomationBinding `
                -Element $recoveryPrompt `
                -Process $third.owned.process `
                -ExpectedSession $SessionId `
                -Label 'startup recovery confirmation after export' `
                -RequireWindowHandle
            $afterExportRestart = Get-AcceptanceFixtureState -FixtureRoot $fixtureRoot
            Assert-AcceptanceStatesEqual `
                -Expected $beforeRestart `
                -Actual $afterExportRestart `
                -Label 'Startup after recovery export'
            $recoveryApplication = $third
        }
        $recoveryScreenshot = Invoke-AcceptanceRecovery `
            -Application $recoveryApplication `
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

        $recoveryExitCode = Close-AcceptanceApplicationNormally `
            -Application $recoveryApplication `
            -WaitSeconds $WaitSeconds

        if ($RunIntentOnlyCandidateDiscard) {
            $intentDiscardResult = Invoke-AcceptanceIntentOnlyCandidateDiscard `
                -Inputs $Inputs `
                -FixtureRoot $fixtureRoot `
                -Initial $initial `
                -IntentBytes $intentBytes `
                -SessionId $SessionId `
                -WaitSeconds $WaitSeconds
        }

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
                normal_exit_code = $recoveryExitCode
            }
            recovery_export = $recoveryExportResult
            intent_only_candidate_discard = $intentDiscardResult
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
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        foreach ($application in @($first, $second, $third)) {
            if ($null -eq $application) { continue }
            try {
                Stop-AndDisposeAcceptanceOwnedProcess -Owned $application.owned
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

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$requestedBundleRoot = $BundleRoot
$requestedExpectedSessionId = $ExpectedSessionId
$requestedValidateOnly = [bool]$ValidateOnly
$requestedRecoveryExport = [bool]$RecoveryExport
$requestedIntentOnlyCandidateDiscard = [bool]$IntentOnlyCandidateDiscard
$bootstrap = Resolve-AcceptanceBootstrap `
    -Root $requestedBundleRoot `
    -ObserverPath $PSCommandPath `
    -ExpectedObserverSha256 $ExpectedScriptSha256
. $bootstrap.runner_script -BundleRoot $requestedBundleRoot -ExpectedSessionId 1 -ValidateOnly
$BundleRoot = $requestedBundleRoot
$ExpectedSessionId = $requestedExpectedSessionId
$ValidateOnly = $requestedValidateOnly
$RecoveryExport = $requestedRecoveryExport
$IntentOnlyCandidateDiscard = $requestedIntentOnlyCandidateDiscard
$inputs = Resolve-AcceptanceInputs `
    -Root $BundleRoot `
    -RunnerPath $bootstrap.runner_path `
    -ObserverPath $PSCommandPath `
    -ExpectedObserverSha256 $ExpectedScriptSha256
if ($inputs.runner_sha256 -cne $bootstrap.runner_sha256 -or
    $inputs.observer_sha256 -cne $bootstrap.observer_sha256) {
    throw 'Authenticated bootstrap hashes changed during full bundle verification.'
}
if (($RecoveryExport -or $IntentOnlyCandidateDiscard) -and $Mode -cne 'ProcessCrash') {
    throw 'RecoveryExport and IntentOnlyCandidateDiscard require Mode ProcessCrash.'
}
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
    recovery_export = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
    intent_only_candidate_discard = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
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
        $sessionResult = Invoke-AcceptanceSession `
            -Inputs $inputs `
            -EvidenceRoot $evidenceRoot `
            -RuntimeRoot $runtimeRoot `
            -Count $FixtureCount `
            -Mode $Mode `
            -SessionId $currentSession `
            -WaitSeconds $TimeoutSeconds `
            -RunRecoveryExport ([bool]$RecoveryExport) `
            -RunIntentOnlyCandidateDiscard ([bool]$IntentOnlyCandidateDiscard)
        switch ($Mode) {
            'ProcessCrash' { $result.process_crash = $sessionResult.mode_result }
            'WorkerCancellation' { $result.worker_cancellation = $sessionResult.mode_result }
            'WorkerClose' { $result.worker_close = $sessionResult.mode_result }
        }
        $result.recovery_export = $sessionResult.recovery_export
        $result.intent_only_candidate_discard = $sessionResult.intent_only_candidate_discard
    }
    $result.status = 'passed'
    $succeeded = $true
}
catch {
    $result.failure_reason = 'recovery_acceptance_error'
    $modeFailure = [ordered]@{
        status = 'failed'
        reason = 'recovery_acceptance_error'
    }
    switch ($Mode) {
        'ProcessCrash' { $result.process_crash = $modeFailure }
        'WorkerCancellation' { $result.worker_cancellation = $modeFailure }
        'WorkerClose' { $result.worker_close = $modeFailure }
    }
    if ($RecoveryExport) {
        $result.recovery_export = $modeFailure
    }
    if ($IntentOnlyCandidateDiscard) {
        $result.intent_only_candidate_discard = $modeFailure
    }
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
