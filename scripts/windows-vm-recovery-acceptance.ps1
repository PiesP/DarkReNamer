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
    [string] $PrivateEvidenceRoot,

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
$script:AcceptanceProcessSequence = 0

function Assert-RecoveryBootstrapUniqueJson {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)][string] $Location
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "$Location contains a duplicate field: $($property.Name)."
            }
            Assert-RecoveryBootstrapUniqueJson `
                -Element $property.Value `
                -Location "$Location.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-RecoveryBootstrapUniqueJson -Element $item -Location "$Location[$index]"
            $index++
        }
    }
}

function Initialize-AcceptanceCrc32 {
    if ('DarkReNamerAcceptanceCrc32' -as [type]) {
        return
    }

    Add-Type @'
using System;

public static class DarkReNamerAcceptanceCrc32
{
    private static readonly uint[] Table = BuildTable();

    private static uint[] BuildTable()
    {
        uint[] table = new uint[256];
        for (uint value = 0; value < table.Length; value++)
        {
            uint remainder = value;
            for (int bit = 0; bit < 8; bit++)
            {
                remainder = (remainder >> 1) ^ ((remainder & 1) == 0 ? 0u : 0xEDB88320u);
            }
            table[value] = remainder;
        }
        return table;
    }

    public static uint Compute(byte[][] parts)
    {
        uint crc = 0xFFFFFFFFu;
        if (parts != null)
        {
            foreach (byte[] part in parts)
            {
                if (part == null) continue;
                for (int index = 0; index < part.Length; index++)
                {
                    crc = (crc >> 8) ^ Table[(crc ^ part[index]) & 0xFFu];
                }
            }
        }
        return crc ^ 0xFFFFFFFFu;
    }
}
'@
}

function Get-AcceptanceCrc32 {
    param([Parameter(Mandatory)][byte[][]] $Parts)

    Initialize-AcceptanceCrc32
    [DarkReNamerAcceptanceCrc32]::Compute($Parts)
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
        $version = [BitConverter]::ToUInt16($Bytes, $offset + 4)
        if ($version -ne 1 -and $version -ne 2) {
            throw "Journal frame $frame has an unsupported version."
        }
        $kind = [int]$Bytes[$offset + 6]
        if ($kind -lt 1 -or $kind -gt 5 -or $Bytes[$offset + 7] -ne 0) {
            throw "Journal frame $frame has an invalid kind or flags."
        }
        $sequence = [BitConverter]::ToUInt64($Bytes, $offset + 8)
        if ($sequence -ne [uint64]$frame) {
            throw "Journal frame $frame has an invalid sequence."
        }
        $payloadLength = [int64]([BitConverter]::ToUInt32($Bytes, $offset + 16))
        if ($payloadLength -gt $maximumPayloadBytes) {
            throw "Journal frame $frame exceeds the payload bound."
        }
        $frameLength = [int64]$headerBytes + $payloadLength
        if ($frameLength -gt ($Bytes.Length - $offset)) {
            $tail = 'truncated-payload'
            break
        }
        $expectedCrc = [BitConverter]::ToUInt32($Bytes, $offset + 20)
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
    $frameLength = 24L + [int64]([BitConverter]::ToUInt32($Bytes, 16))
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
        [Parameter(Mandatory)][bool] $CancelLocked,
        [Parameter(Mandatory)][bool] $RelaunchPreserved,
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
    if (-not $CancelPreserved -or -not $CancelUnchanged -or -not $CancelLocked) {
        throw 'The cancelled discard did not preserve the candidate and fixture state.'
    }
    if (-not $RelaunchPreserved) {
        throw 'The verification relaunch did not preserve the exact candidate.'
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
    $manifestDocument = $null
    try {
        $manifestDocument = [Text.Json.JsonDocument]::Parse($manifestText)
        Assert-RecoveryBootstrapUniqueJson `
            -Element $manifestDocument.RootElement `
            -Location 'bundle.json'
        $manifest = $manifestText | ConvertFrom-Json
    }
    catch {
        throw "The bootstrap bundle manifest is not valid unique-key JSON: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $manifestDocument) {
            $manifestDocument.Dispose()
        }
    }
    $candidateLane = $manifest.schema_version -eq 2
    $runner = if ($candidateLane) { $manifest.harness.runner } else { $manifest.runner }
    if ($null -eq $manifest -or $null -eq $runner) {
        throw 'The bootstrap bundle manifest has no runner object.'
    }
    Assert-AcceptanceExactProperties `
        -Value $runner `
        -Names @('file', 'sha256') `
        -Label 'bootstrap runner'
    if ($runner.file -isnot [string] -or
        $runner.file -cne 'windows-vm-guest.ps1') {
        throw 'The bootstrap runner leaf is invalid.'
    }
    if ($runner.sha256 -isnot [string] -or
        $runner.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The bootstrap runner SHA-256 is invalid.'
    }
    if ($candidateLane) {
        $recoveryObserver = $manifest.harness.observers.recovery
        if ($recoveryObserver.file -cne 'windows-vm-recovery-acceptance.ps1' -or
            $recoveryObserver.sha256 -cne $ExpectedObserverSha256) {
            throw 'The bootstrap recovery observer binding is invalid.'
        }
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
    if ($runnerSha256 -cne $runner.sha256) {
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
    if ($verified.contract.product_source_state -cne 'clean' -or
        $verified.contract.harness_source_state -cne 'clean') {
        throw 'Recovery acceptance requires a clean source-bound bundle.'
    }
    Assert-OrdinaryFile -Path $ObserverPath -Label 'recovery acceptance observer'
    $observerItem = Get-Item -LiteralPath $ObserverPath -Force
    $observerSha256 = Get-LowerSha256 -Path $observerItem.FullName
    if ($observerSha256 -cne $ExpectedObserverSha256) {
        throw 'The recovery acceptance observer hash does not match its staging contract.'
    }
    $observer = if ($verified.contract.lane -ceq 'candidate-gui-only') {
        $verified.contract.observers.recovery
    }
    else {
        [pscustomobject]@{
            file = 'windows-vm-recovery-acceptance.ps1'
            sha256 = $observerSha256
        }
    }
    if ($observer.file -cne 'windows-vm-recovery-acceptance.ps1' -or
        $observer.sha256 -cne $observerSha256) {
        throw 'The invoked recovery observer differs from the verified harness role.'
    }
    [pscustomobject]@{
        verified = $verified
        contract = $verified.contract
        application_path = Join-Path $verified.root $verified.contract.application.file
        observer_file = $observerItem.Name
        observer_sha256 = $observerSha256
        observer = $observer
        runner_sha256 = $verified.hashes[$verified.contract.runner.file]
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

function Write-AcceptanceNewBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][byte[]] $Bytes
    )

    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    $readback = [IO.File]::ReadAllBytes($Path)
    if (-not (Test-AcceptanceBytesEqual -Expected $Bytes -Actual $readback)) {
        throw 'A no-overwrite evidence write failed exact byte readback.'
    }
}

function Write-AcceptanceNewUtf8Json {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object] $Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        ($Value | ConvertTo-Json -Depth 12)
    )
    Write-AcceptanceNewBytes -Path $Path -Bytes $bytes
}

function New-AcceptancePrivateEvidenceDirectory {
    param([Parameter(Mandatory)][string] $Parent)

    if (-not [IO.Path]::IsPathRooted($Parent) -or
        -not (Test-Path -LiteralPath $Parent -PathType Container)) {
        throw 'PrivateEvidenceRoot must be an existing absolute directory.'
    }
    $item = Get-Item -LiteralPath $Parent -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'PrivateEvidenceRoot must not be a reparse point.'
    }
    $path = Join-Path $item.FullName ('recovery-raw-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $path)
    $path
}

function New-AcceptancePrivateReference {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Boundary
    )

    if ($Boundary -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
        throw 'A private evidence reference has an invalid boundary token.'
    }
    $rootItem = Get-Item -LiteralPath $PrivateRoot -Force
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The private evidence reference root is not one ordinary directory.'
    }
    $root = $rootItem.FullName.TrimEnd([char[]]'\/') +
        [IO.Path]::DirectorySeparatorChar
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt 64MB -or
        -not $item.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A private evidence reference escaped its owned ordinary-file root.'
    }
    $relative = $item.FullName.Substring($root.Length).Replace('\', '/')
    $segments = @($relative -split '[\/]')
    if ($segments.Count -lt 1 -or @($segments | Where-Object {
            $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        }).Count -ne 0) {
        throw 'A private evidence reference has an unsafe leaf.'
    }
    [pscustomobject][ordered]@{
        bytes = [int64]$item.Length
        sha256 = Get-LowerSha256 -Path $item.FullName
        boundary = $Boundary
    }
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

    $root = Get-Item -LiteralPath $FixtureRoot -Force
    if (-not $root.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The acceptance fixture root is not one ordinary directory.'
    }
    $items = @(Get-ChildItem -LiteralPath $root.FullName -Force | Sort-Object Name)
    if ($items.Count -lt 1 -or $items.Count -gt 10001) {
        throw 'The acceptance fixture inventory is outside the bounded file count.'
    }
    $rows = [Collections.Generic.List[object]]::new()
    $folded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $totalBytes = [long]0
    foreach ($file in $items) {
        if ($file.PSIsContainer -or
            ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $file.Length -gt 64MB) {
            throw 'The acceptance fixture contains a non-file, reparse, or oversized entry.'
        }
        $totalBytes += [long]$file.Length
        if ($totalBytes -gt 512MB) {
            throw 'The acceptance fixture exceeds the aggregate byte limit.'
        }
        if (-not $folded.Add($file.Name)) {
            throw 'The acceptance fixture contains a case-insensitive name collision.'
        }
        $rows.Add([pscustomobject][ordered]@{
            name = $file.Name
            kind = 'file'
            bytes = [int64]$file.Length
            content_sha256 = Get-LowerSha256 -Path $file.FullName
            file_identity = Get-FullFileIdentity -Path $file.FullName
        })
    }
    $rows.ToArray()
}

function Test-AcceptanceIdentityEqual {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual
    )

    $Expected.volume_serial -is [string] -and
        $Actual.volume_serial -is [string] -and
        $Expected.file_id -is [string] -and
        $Actual.file_id -is [string] -and
        $Expected.volume_serial -ceq $Actual.volume_serial -and
        $Expected.file_id -ceq $Actual.file_id
}

function Get-AcceptanceIdentityKey {
    param([Parameter(Mandatory)][object] $Identity)

    if ($Identity.volume_serial -isnot [string] -or
        $Identity.volume_serial -cnotmatch '^[0-9a-f]{16}$' -or
        $Identity.file_id -isnot [string] -or
        $Identity.file_id -cnotmatch '^[0-9a-f]{32}$') {
        throw 'The observed FILE_ID_INFO value is malformed or truncated.'
    }
    "$($Identity.volume_serial):$($Identity.file_id)"
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
            $Expected[$index].kind -cne $Actual[$index].kind -or
            $Expected[$index].bytes -ne $Actual[$index].bytes -or
            $Expected[$index].content_sha256 -cne $Actual[$index].content_sha256 -or
            -not (Test-AcceptanceIdentityEqual `
                -Expected $Expected[$index].file_identity `
                -Actual $Actual[$index].file_identity)) {
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
        $identityKey = Get-AcceptanceIdentityKey -Identity $row.file_identity
        if ($initialByIdentity.ContainsKey($identityKey)) {
            throw 'The initial fixture contains a duplicate NTFS identity.'
        }
        $initialByIdentity[$identityKey] = $row
    }
    $original = 0
    $renamed = 0
    foreach ($row in $Partial) {
        $identityKey = Get-AcceptanceIdentityKey -Identity $row.file_identity
        if (-not $initialByIdentity.ContainsKey($identityKey)) {
            throw 'The partial state contains an unknown NTFS identity.'
        }
        $before = $initialByIdentity[$identityKey]
        if ($row.kind -cne 'file' -or
            $row.bytes -ne $before.bytes -or
            $row.content_sha256 -cne $before.content_sha256) {
            throw 'The partial state changed file kind, size, or contents.'
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
        $identityKey = Get-AcceptanceIdentityKey -Identity $row.file_identity
        "$($row.name)|$($row.kind)|$($row.bytes)|$($row.content_sha256)|$identityKey"
    }
    Get-LowerTextSha256 -Value ([string]::Join("`n", $parts))
}

function Write-AcceptanceStateEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][object] $RootIdentity,
        [Parameter(Mandatory)][object[]] $State
    )

    if ($Leaf -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
        throw 'The state-evidence leaf is invalid.'
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        fixture_root = $FixtureRoot
        root_identity = $RootIdentity
        fixture_entries = @($State)
    })
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}

function Write-AcceptanceObservedStateEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][object] $ExpectedRootIdentity,
        [Parameter(Mandatory)][object[]] $State
    )

    $actualRootIdentity = Get-FullFileIdentity -Path $FixtureRoot
    [void](Get-AcceptanceIdentityKey -Identity $ExpectedRootIdentity)
    [void](Get-AcceptanceIdentityKey -Identity $actualRootIdentity)
    if (-not (Test-AcceptanceIdentityEqual `
            -Expected $ExpectedRootIdentity `
            -Actual $actualRootIdentity)) {
        throw "The fixture-root FILE_ID_INFO changed at $Boundary."
    }
    Write-AcceptanceStateEvidence `
        -PrivateRoot $PrivateRoot `
        -Leaf $Leaf `
        -Boundary $Boundary `
        -FixtureRoot $FixtureRoot `
        -RootIdentity $actualRootIdentity `
        -State $State
}

function Write-AcceptanceJournalBytesEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][byte[]] $Bytes
    )

    if ($Leaf -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}\.drj$' -or
        $Bytes.Length -lt 24 -or $Bytes.Length -gt 64MB) {
        throw 'The raw journal evidence leaf or byte length is invalid.'
    }
    $path = Join-Path $PrivateRoot $Leaf
    Write-AcceptanceNewBytes -Path $path -Bytes $Bytes
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}

function Write-AcceptanceJournalInventoryEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $JournalRoot
    )

    if ($Leaf -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
        throw 'The journal-inventory leaf is invalid.'
    }
    $rows = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $JournalRoot) {
        $root = Get-Item -LiteralPath $JournalRoot -Force
        if (-not $root.PSIsContainer -or
            ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The isolated journal root is not one ordinary directory.'
        }
        $items = @(Get-ChildItem -LiteralPath $root.FullName -Force | Sort-Object Name)
        if ($items.Count -gt 3) {
            throw 'The isolated journal inventory exceeds its bounded entry count.'
        }
        foreach ($item in $items) {
            if ($item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Name -cnotin @('active.drj', 'candidate.drj', 'runtime.lock') -or
                $item.Length -gt 64MB) {
                throw 'The isolated journal root contains an unexpected entry.'
            }
            $rows.Add([pscustomobject][ordered]@{
                name = $item.Name
                kind = 'file'
                bytes = [int64]$item.Length
                sha256 = Get-LowerSha256 -Path $item.FullName
            })
        }
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        journal_entries = $rows.ToArray()
    })
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}

function Test-AcceptanceControlTargetId {
    param(
        [Parameter(Mandatory)][int] $ControlId,
        [Parameter(Mandatory)][string] $AutomationId
    )

    if ($ControlId -gt 0) {
        return $true
    }
    return $ControlId -eq 0 -and
        @('CommandButton_2', 'CommandLink_1101', 'CommandLink_1201') -ccontains $AutomationId
}

function Assert-AcceptanceControlTargetRecord {
    param([Parameter(Mandatory)][object] $Target)

    $names = @($Target.PSObject.Properties.Name)
    if ($Target -is [Collections.IDictionary]) {
        $names = @($Target.Keys)
    }
    $expectedNames = @(
        'pid', 'session_id', 'hwnd', 'root_hwnd', 'class', 'control_id',
        'automation_id', 'control_type', 'enabled', 'visible', 'focused'
    )
    if ($names.Count -ne $expectedNames.Count -or
        @($expectedNames | Where-Object { $names -cnotcontains $_ }).Count -ne 0 -or
        [int]$Target.pid -le 0 -or [int]$Target.session_id -lt 0 -or
        [int64]$Target.hwnd -le 0 -or [int64]$Target.root_hwnd -le 0 -or
        [string]$Target.class -cne 'Button' -or
        -not (Test-AcceptanceControlTargetId `
            -ControlId ([int]$Target.control_id) `
            -AutomationId ([string]$Target.automation_id)) -or
        [string]::IsNullOrWhiteSpace([string]$Target.automation_id) -or
        [string]$Target.control_type -cne 'ControlType.Button' -or
        $Target.enabled -isnot [bool] -or $Target.visible -isnot [bool] -or
        $Target.focused -isnot [bool]) {
        throw 'A control target observation is incomplete or invalid.'
    }
}

function Copy-AcceptanceControlTargetRecord {
    param([Parameter(Mandatory)][object] $Target)

    Assert-AcceptanceControlTargetRecord -Target $Target
    [ordered]@{
        pid = [int]$Target.pid
        session_id = [int]$Target.session_id
        hwnd = [int64]$Target.hwnd
        root_hwnd = [int64]$Target.root_hwnd
        class = [string]$Target.class
        control_id = [int]$Target.control_id
        automation_id = [string]$Target.automation_id
        control_type = [string]$Target.control_type
        enabled = [bool]$Target.enabled
        visible = [bool]$Target.visible
        focused = [bool]$Target.focused
    }
}

function Write-AcceptanceActionEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][string] $Action,
        [Parameter(Mandatory)][object] $Target,
        [Parameter(Mandatory)][string] $ObservedUtcTicks,
        [Parameter(Mandatory)][string] $CompletedUtcTicks
    )

    foreach ($token in @($Leaf, $Boundary, $Phase, $Action)) {
        if ($token -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
            throw 'An action-evidence token is invalid.'
        }
    }
    if ($ObservedUtcTicks -cnotmatch '^[0-9]+$' -or
        $CompletedUtcTicks -cnotmatch '^[0-9]+$' -or
        [decimal]$CompletedUtcTicks -lt [decimal]$ObservedUtcTicks) {
        throw 'Action evidence has an invalid timestamp order.'
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        phase = $Phase
        action = $Action
        dispatch_method = 'uia-invoke'
        target = Copy-AcceptanceControlTargetRecord -Target $Target
        observed_utc_ticks = $ObservedUtcTicks
        completed_utc_ticks = $CompletedUtcTicks
    })
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}

function Write-AcceptanceLockStateEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][int] $CandidatePid,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][object] $Apply,
        [Parameter(Mandatory)][object] $AddFiles,
        [Parameter(Mandatory)][string] $ObservedUtcTicks
    )

    foreach ($token in @($Leaf, $Boundary, $Phase)) {
        if ($token -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
            throw 'A recovery-lock evidence token is invalid.'
        }
    }
    if ($CandidatePid -le 0 -or $SessionId -lt 0 -or $ObservedUtcTicks -cnotmatch '^[0-9]+$') {
        throw 'Recovery-lock evidence has an invalid process or timestamp.'
    }
    $applyRecord = Copy-AcceptanceControlTargetRecord -Target $Apply
    $addFilesRecord = Copy-AcceptanceControlTargetRecord -Target $AddFiles
    foreach ($control in @($applyRecord, $addFilesRecord)) {
        if ($control.pid -ne $CandidatePid -or $control.session_id -ne $SessionId -or
            $control.root_hwnd -ne $applyRecord.root_hwnd) {
            throw 'Recovery-lock controls are not bound to one process, session, and root.'
        }
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        phase = $Phase
        observed_utc_ticks = $ObservedUtcTicks
        process = [ordered]@{
            pid = $CandidatePid
            session_id = $SessionId
        }
        controls = [ordered]@{
            apply = $applyRecord
            add_files = $addFilesRecord
        }
    })
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}

function Write-AcceptancePrivateIndex {
    param([Parameter(Mandatory)][string] $PrivateRoot)

    $root = Get-Item -LiteralPath $PrivateRoot -Force
    if (-not $root.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The private evidence root is not one owned ordinary directory.'
    }
    $rows = [Collections.Generic.List[object]]::new()
    $relativeNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($directory in @(Get-ChildItem -LiteralPath $root.FullName -Directory -Recurse -Force)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The private evidence root contains a reparse directory.'
        }
    }
    $prefix = $root.FullName.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    [int64]$aggregateBytes = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $root.FullName -File -Recurse -Force | Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Name -ceq 'private-index.json' -or
            $item.Length -gt 64MB) {
            throw 'The private evidence root contains an unsafe, reserved, or oversized file.'
        }
        $relative = $item.FullName.Substring($prefix.Length).Replace('\', '/')
        $segments = @($relative -split '[\/]')
        if ($segments.Count -lt 1 -or @($segments | Where-Object {
                $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
            }).Count -ne 0) {
            throw 'The private evidence root contains an unsafe relative path.'
        }
        if (-not $relativeNames.Add($relative)) {
            throw 'The private evidence root contains a case-insensitive path collision.'
        }
        $rows.Add([ordered]@{
            file = $relative
            bytes = [int64]$item.Length
            sha256 = Get-LowerSha256 -Path $item.FullName
        })
        $aggregateBytes += [int64]$item.Length
        if ($aggregateBytes -gt 512MB) {
            throw 'The private evidence root exceeds the aggregate collection bound.'
        }
    }
    if ($rows.Count -eq 0 -or $rows.Count -gt 240) {
        throw 'The private evidence index is empty or exceeds the controller file bound.'
    }
    $path = Join-Path $root.FullName 'private-index.json'
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        classification = 'private-path-bearing-raw-recovery-evidence'
        files = $rows.ToArray()
    })
    [pscustomobject][ordered]@{
        bytes = [int64](Get-Item -LiteralPath $path -Force).Length
        sha256 = Get-LowerSha256 -Path $path
        file_count = $rows.Count
    }
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

    $application = $Inputs.contract.application
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

function Write-AcceptanceProcessStartEvidence {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Inputs,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Role
    )

    if ($Role -cnotmatch '^[a-z0-9][a-z0-9-]{0,31}$') {
        throw 'The process evidence role is invalid.'
    }
    $process = $Application.owned.process
    $process.Refresh()
    if ($process.HasExited) {
        throw 'The candidate process exited before its raw start observation.'
    }
    $script:AcceptanceProcessSequence++
    $sequence = $script:AcceptanceProcessSequence
    $startUtc = $process.StartTime.ToUniversalTime()
    $environment = Get-VmAutomatedEnvironment `
        -Process $process `
        -WindowHandle $process.MainWindowHandle `
        -FixtureRoot $FixtureRoot
    $binding = [pscustomobject][ordered]@{
        sequence = $sequence
        role = $Role
        pid = [int]$process.Id
        session_id = [int]$process.SessionId
        start_time_utc_ticks = $startUtc.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
        executable_path = $process.MainModule.FileName
        executable_sha256 = Get-LowerSha256 -Path $Inputs.application_path
    }
    $observedRootIdentity = Get-FullFileIdentity -Path $FixtureRoot
    [void](Get-AcceptanceIdentityKey -Identity $observedRootIdentity)
    [void](Get-AcceptanceIdentityKey -Identity $environment.fixture_volume.root_identity)
    if (-not (Test-AcceptanceIdentityEqual `
            -Expected $observedRootIdentity `
            -Actual $environment.fixture_volume.root_identity)) {
        throw 'The process environment fixture-root identity does not match FILE_ID_INFO.'
    }
    $observedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $lifecycle = [pscustomobject][ordered]@{
        pid = $binding.pid
        session_id = $binding.session_id
        start_time_utc_ticks = $binding.start_time_utc_ticks
        executable_path = $binding.executable_path
        executable_sha256 = $binding.executable_sha256
        start_observed = $true
        exit_observed = $false
        exit_method = $null
        exit_code = $null
    }
    $path = Join-Path $PrivateRoot ('process-{0:D2}-started.json' -f $sequence)
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = 'started'
        observed_utc_ticks = $observedUtcTicks
        binding = $binding
        lifecycle = $lifecycle
        environment = $environment
    })
    # Keep the original process object and kernel handle alive through exit.
    # SessionId is no longer queryable reliably after Refresh on an exited process.
    $Application | Add-Member -NotePropertyName raw_process_object -NotePropertyValue $process -Force
    $Application | Add-Member -NotePropertyName raw_process_handle `
        -NotePropertyValue $process.SafeHandle.DangerousGetHandle() -Force
    $Application | Add-Member -NotePropertyName raw_process_binding -NotePropertyValue $binding -Force
    $Application | Add-Member -NotePropertyName raw_process_exit_recorded -NotePropertyValue $false -Force
    $Application | Add-Member -NotePropertyName raw_process_start_reference `
        -NotePropertyValue (New-AcceptancePrivateReference `
            -Path $path -PrivateRoot $PrivateRoot -Boundary 'started') -Force
    $Application.raw_process_start_reference
}

function Assert-AcceptanceProcessBinding {
    param([Parameter(Mandatory)][object] $Application)

    $process = $Application.owned.process
    $binding = $Application.raw_process_binding
    $process.Refresh()
    if (-not [Object]::ReferenceEquals($process, $Application.raw_process_object) -or
        $process.SafeHandle.IsClosed -or $process.SafeHandle.IsInvalid -or
        $process.SafeHandle.DangerousGetHandle() -ne $Application.raw_process_handle -or
        $process.Id -ne $binding.pid -or
        (-not $process.HasExited -and $process.SessionId -ne $binding.session_id) -or
        $process.StartTime.ToUniversalTime().Ticks.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ) -cne $binding.start_time_utc_ticks) {
        throw 'The candidate process identity changed during raw observation.'
    }
}

function Write-AcceptanceProcessExitEvidence {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][ValidateSet('crash-stop', 'normal-exit', 'failure-cleanup')]
        [string] $Boundary,
        [Parameter(Mandatory)][ValidateSet('normal-close', 'forced-termination', 'worker-close')]
        [string] $ExitMethod
    )

    if ($Application.raw_process_exit_recorded) {
        throw 'The candidate process exit was already recorded.'
    }
    Assert-AcceptanceProcessBinding -Application $Application
    $process = $Application.owned.process
    if (-not $process.HasExited) {
        throw 'The candidate process is still running at an exit-evidence boundary.'
    }
    $process.WaitForExit()
    $observedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $sequence = $Application.raw_process_binding.sequence
    $path = Join-Path $PrivateRoot ('process-{0:D2}-{1}.json' -f $sequence, $Boundary)
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        observed_utc_ticks = $observedUtcTicks
        binding = $Application.raw_process_binding
        lifecycle = [ordered]@{
            pid = $Application.raw_process_binding.pid
            session_id = $Application.raw_process_binding.session_id
            start_time_utc_ticks = $Application.raw_process_binding.start_time_utc_ticks
            executable_path = $Application.raw_process_binding.executable_path
            executable_sha256 = $Application.raw_process_binding.executable_sha256
            start_observed = $true
            exit_observed = $true
            exit_method = $ExitMethod
            exit_code = [int]$process.ExitCode
        }
    })
    $Application.raw_process_exit_recorded = $true
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}

function Write-AcceptanceForegroundEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[object]] $Observations
    )

    if ($Observations.Count -lt 1 -or $Observations.Count -gt 8) {
        throw 'Recovery screenshot foreground evidence is missing or unbounded.'
    }
    $path = Join-Path $PrivateRoot 'foreground-observations.json'
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        observations = $Observations.ToArray()
    })
    New-AcceptancePrivateReference `
        -Path $path `
        -PrivateRoot $PrivateRoot `
        -Boundary 'screenshot-foreground-observations'
}

function Write-AcceptanceWorkerPartialWitnessEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][object] $ExpectedRootIdentity,
        [Parameter(Mandatory)][object] $Witness
    )

    if ($Leaf -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or
        @($Witness.entries).Count -ne 2 -or
        $Witness.candidate_pid -le 0 -or
        $Witness.candidate_session_id -lt 0) {
        throw 'The worker partial witness is malformed or unbounded.'
    }
    $rootIdentity = Get-FullFileIdentity -Path $FixtureRoot
    [void](Get-AcceptanceIdentityKey -Identity $rootIdentity)
    if (-not (Test-AcceptanceIdentityEqual `
            -Expected $ExpectedRootIdentity `
            -Actual $rootIdentity)) {
        throw 'The fixture-root identity changed at the worker partial witness.'
    }
    $roles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Witness.entries)) {
        if ($entry.role -cnotin @('first-destination', 'last-original') -or
            $entry.name -isnot [string] -or
            $entry.kind -cne 'file' -or
            $entry.bytes -lt 0 -or $entry.bytes -gt 64MB -or
            $entry.content_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $entry.observed_utc_ticks -cnotmatch '^[0-9]+$') {
            throw 'The worker partial witness contains an invalid file observation.'
        }
        if (-not $roles.Add($entry.role)) {
            throw 'The worker partial witness contains a duplicate role.'
        }
        [void](Get-AcceptanceIdentityKey -Identity $entry.file_identity)
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = 'worker-partial'
        candidate_pid = [int]$Witness.candidate_pid
        candidate_session_id = [int]$Witness.candidate_session_id
        fixture_root = $FixtureRoot
        root_identity = $rootIdentity
        entries = @($Witness.entries)
    })
    New-AcceptancePrivateReference `
        -Path $path -PrivateRoot $PrivateRoot -Boundary 'worker-partial'
}

function Select-AcceptanceUiDiagnosticApplication {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Applications)

    $latest = $null
    for ($index = $Applications.Count - 1; $index -ge 0; $index--) {
        $application = $Applications[$index]
        if ($null -eq $application) {
            continue
        }
        if ($null -eq $latest) {
            $latest = $application
        }
        try {
            $process = $application.owned.process
            $process.Refresh()
            if (-not $process.HasExited) {
                return $application
            }
        }
        catch {
        }
    }
    return $latest
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

function Initialize-AcceptanceRecoveryMenuNative {
    if ('DarkReNamerRecoveryMenuNative' -as [type]) {
        return
    }
    Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class DarkReNamerRecoveryMenuNative {
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    public sealed class KeyboardResult {
        public uint RequestedCount { get; set; }
        public uint SentCount { get; set; }
        public int ErrorCode { get; set; }
        public uint ReleaseSentCount { get; set; }
    }

    public sealed class PopupObservation {
        public long Handle { get; set; }
        public uint ProcessId { get; set; }
        public string ClassName { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Right { get; set; }
        public int Bottom { get; set; }
    }

    public sealed class PopupInventory {
        public int TotalCount { get; set; }
        public PopupObservation[] Entries { get; set; }
    }

    public sealed class RecoveryMenuItemObservation {
        public int RootPosition { get; set; }
        public int Position { get; set; }
        public string ItemType { get; set; }
        public int? CommandId { get; set; }
        public uint StateFlags { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Right { get; set; }
        public int Bottom { get; set; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MENUITEMINFO {
        public uint Size;
        public uint Mask;
        public uint Type;
        public uint State;
        public uint Id;
        public IntPtr SubMenu;
        public IntPtr CheckedBitmap;
        public IntPtr UncheckedBitmap;
        public UIntPtr ItemData;
        public IntPtr TypeData;
        public uint TextLength;
        public IntPtr ItemBitmap;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT {
        public ushort virtualKey;
        public ushort scanCode;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT {
        public int x;
        public int y;
        public uint mouseData;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION {
        [FieldOffset(0)] public KEYBDINPUT keyboard;
        [FieldOffset(0)] public MOUSEINPUT mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT {
        public uint type;
        public INPUTUNION value;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")]
    private static extern IntPtr GetMenu(IntPtr window);
    [DllImport("user32.dll")]
    private static extern IntPtr GetSubMenu(IntPtr menu, int position);
    [DllImport("user32.dll")]
    private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")]
    private static extern uint GetMenuState(IntPtr menu, uint item, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetMenuItemInfoW(
        IntPtr menu, uint item, bool byPosition, ref MENUITEMINFO information);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetMenuItemRect(
        IntPtr window, IntPtr menu, uint item, out RECT rect);

    private static INPUT Key(ushort virtualKey, uint flags) {
        return new INPUT {
            type = 1,
            value = new INPUTUNION {
                keyboard = new KEYBDINPUT {
                    virtualKey = virtualKey,
                    scanCode = 0,
                    flags = flags,
                    time = 0,
                    extraInfo = UIntPtr.Zero
                }
            }
        };
    }

    public static KeyboardResult SendKeyTap(ushort virtualKey) {
        INPUT[] inputs = new [] { Key(virtualKey, 0), Key(virtualKey, 2) };
        uint sent = SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
        int error = sent == 2 ? 0 : Marshal.GetLastWin32Error();
        uint released = 0;
        if (sent != 2) {
            released = SendInput(1, new [] { Key(virtualKey, 2) }, Marshal.SizeOf(typeof(INPUT)));
        }
        return new KeyboardResult {
            RequestedCount = 2,
            SentCount = sent,
            ErrorCode = error,
            ReleaseSentCount = released
        };
    }

    public static KeyboardResult SendAltR() {
        INPUT[] inputs = new [] {
            Key(0x12, 0), Key(0x52, 0), Key(0x52, 2), Key(0x12, 2)
        };
        uint sent = SendInput(4, inputs, Marshal.SizeOf(typeof(INPUT)));
        int error = sent == 4 ? 0 : Marshal.GetLastWin32Error();
        uint released = 0;
        if (sent != 4) {
            INPUT[] releases = sent <= 2
                ? new [] { Key(0x52, 2), Key(0x12, 2) }
                : new [] { Key(0x12, 2) };
            released = SendInput((uint)releases.Length, releases, Marshal.SizeOf(typeof(INPUT)));
        }
        return new KeyboardResult {
            RequestedCount = 4,
            SentCount = sent,
            ErrorCode = error,
            ReleaseSentCount = released
        };
    }

    public static PopupInventory ReadVisiblePopups(uint expectedProcessId) {
        List<PopupObservation> entries = new List<PopupObservation>(2);
        int totalCount = 0;
        int rectError = 0;
        bool completed = EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            if (!IsWindowVisible(window)) { return true; }
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) { return true; }
            StringBuilder className = new StringBuilder(32);
            if (GetClassName(window, className, className.Capacity) <= 0 ||
                !String.Equals(className.ToString(), "#32768", StringComparison.Ordinal)) {
                return true;
            }
            totalCount++;
            if (totalCount <= 2) {
                RECT rect;
                if (!GetWindowRect(window, out rect)) {
                    if (rectError == 0) { rectError = Marshal.GetLastWin32Error(); }
                    return true;
                }
                entries.Add(new PopupObservation {
                    Handle = window.ToInt64(),
                    ProcessId = processId,
                    ClassName = className.ToString(),
                    Left = rect.Left,
                    Top = rect.Top,
                    Right = rect.Right,
                    Bottom = rect.Bottom
                });
            }
            return true;
        }, IntPtr.Zero);
        if (!completed) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (rectError != 0) {
            throw new Win32Exception(rectError);
        }
        entries.Sort(delegate(PopupObservation left, PopupObservation right) {
            return left.Handle.CompareTo(right.Handle);
        });
        return new PopupInventory {
            TotalCount = totalCount,
            Entries = entries.ToArray()
        };
    }

    public static RecoveryMenuItemObservation[] ReadRecoveryMenuItems(IntPtr window) {
        const int recoveryRootPosition = 4;
        IntPtr root = GetMenu(window);
        if (root == IntPtr.Zero || GetMenuItemCount(root) != 6) {
            throw new InvalidOperationException("The application menu bar is not the exact six-item tree.");
        }
        IntPtr recovery = GetSubMenu(root, recoveryRootPosition);
        if (recovery == IntPtr.Zero || GetMenuItemCount(recovery) != 4) {
            throw new InvalidOperationException("The recovery menu is not the exact four-item subtree.");
        }
        List<RecoveryMenuItemObservation> rows = new List<RecoveryMenuItemObservation>(4);
        for (int position = 0; position < 4; position++) {
            uint state = GetMenuState(recovery, (uint)position, 0x400);
            if (state == UInt32.MaxValue) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            MENUITEMINFO information = new MENUITEMINFO {
                Size = (uint)Marshal.SizeOf(typeof(MENUITEMINFO)),
                Mask = 0x00000107
            };
            if (!GetMenuItemInfoW(recovery, (uint)position, true, ref information)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            bool separator = (information.Type & 0x800) != 0;
            bool submenu = information.SubMenu != IntPtr.Zero;
            RECT rect;
            if (!GetMenuItemRect(IntPtr.Zero, recovery, (uint)position, out rect)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            rows.Add(new RecoveryMenuItemObservation {
                RootPosition = recoveryRootPosition,
                Position = position,
                ItemType = separator ? "separator" : submenu ? "submenu" : "command",
                CommandId = separator || submenu ? (int?)null : checked((int)information.Id),
                StateFlags = state & 0xFF,
                Left = rect.Left,
                Top = rect.Top,
                Right = rect.Right,
                Bottom = rect.Bottom
            });
        }
        return rows.ToArray();
    }
}
'@
}

function Write-AcceptanceExportProgress {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)]
        [ValidateSet('before-startup-cancel', 'after-startup-cancel', 'before-menu-popup',
            'popup-found', 'menu-item-found', 'invoke-started', 'picker-found', 'picker-filled')]
        [string] $Phase,
        [ValidateSet('export', 'discard-cancel', 'discard-confirm')]
        [string] $Purpose
    )

    Assert-AcceptanceProcessBinding -Application $Application
    $leaf = if ([string]::IsNullOrEmpty($Purpose)) {
        'export-progress-' + $Phase + '.json'
    }
    else {
        'export-progress-' + $Purpose + '-' + $Phase + '.json'
    }
    $value = if ([string]::IsNullOrEmpty($Purpose)) {
        [ordered]@{
            schema_version = 1
            phase = $Phase
            observed_utc_ticks = [DateTime]::UtcNow.Ticks.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            binding = $Application.raw_process_binding
        }
    }
    else {
        [ordered]@{
            schema_version = 1
            phase = $Phase
            purpose = $Purpose
            observed_utc_ticks = [DateTime]::UtcNow.Ticks.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            binding = $Application.raw_process_binding
        }
    }
    Write-AcceptanceNewUtf8Json `
        -Path (Join-Path $PrivateRoot $leaf) `
        -Value $value
}

function Write-AcceptanceRecoveryMenuProgress {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)]
        [ValidateSet('export', 'discard-cancel', 'discard-confirm')]
        [string] $Purpose,
        [Parameter(Mandatory)]
        [ValidateSet('input-returned', 'native-popup-found', 'native-menu-bound',
            'navigation-1', 'navigation-2', 'navigation-3', 'navigation-4',
            'native-command-highlighted', 'native-enter-returned')]
        [string] $Phase,
        [Parameter(Mandatory)][object] $Observation
    )

    Assert-AcceptanceProcessBinding -Application $Application
    Write-AcceptanceNewUtf8Json `
        -Path (Join-Path $PrivateRoot ('recovery-menu-' + $Purpose + '-' + $Phase + '.json')) `
        -Value ([ordered]@{
            schema_version = 1
            phase = $Phase
            purpose = $Purpose
            observed_utc_ticks = [DateTime]::UtcNow.Ticks.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            binding = $Application.raw_process_binding
            observation = $Observation
        })
}

function Remove-AcceptanceRecoveryMenuProgress {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)]
        [ValidateSet('export', 'discard-cancel', 'discard-confirm')]
        [string] $Purpose
    )

    foreach ($phase in @('before-menu-popup', 'popup-found', 'menu-item-found',
            'invoke-started')) {
        Remove-Item -LiteralPath (Join-Path $PrivateRoot (
                'export-progress-' + $Purpose + '-' + $phase + '.json'
            ))
    }
    foreach ($phase in @('input-returned', 'native-popup-found', 'native-menu-bound',
            'native-command-highlighted', 'native-enter-returned')) {
        Remove-Item -LiteralPath (Join-Path $PrivateRoot (
                'recovery-menu-' + $Purpose + '-' + $phase + '.json'
            ))
    }
    foreach ($phase in @('navigation-1', 'navigation-2', 'navigation-3', 'navigation-4')) {
        $optionalPath = Join-Path $PrivateRoot (
            'recovery-menu-' + $Purpose + '-' + $phase + '.json'
        )
        if (Test-Path -LiteralPath $optionalPath -PathType Leaf) {
            Remove-Item -LiteralPath $optionalPath
        }
    }
}

function Remove-AcceptanceExportProgress {
    param([Parameter(Mandatory)][string] $PrivateRoot)

    foreach ($phase in @('before-startup-cancel', 'after-startup-cancel',
            'picker-found', 'picker-filled')) {
        Remove-Item -LiteralPath (Join-Path $PrivateRoot ('export-progress-' + $phase + '.json'))
    }
    Remove-AcceptanceRecoveryMenuProgress -PrivateRoot $PrivateRoot -Purpose 'export'
}

function ConvertTo-AcceptanceRecoveryMenuObservation {
    param(
        [Parameter(Mandatory)][object] $Inventory,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $ActualSession
    )

    if ($ActualSession -ne $ExpectedSession) {
        throw 'The recovery menu candidate process is in an unexpected desktop session.'
    }
    if ($Inventory.TotalCount -gt 1) {
        throw 'Recovery menu matched more than one candidate popup.'
    }
    if ($Inventory.TotalCount -eq 0) {
        return $null
    }
    if ($Inventory.TotalCount -ne 1) {
        throw 'Recovery menu native inventory returned an invalid count.'
    }
    $rows = @($Inventory.Entries)
    if ($rows.Count -ne 1) {
        throw 'Recovery menu native inventory is internally inconsistent.'
    }
    $row = $rows[0]
    if ($row.Handle -le 0 -or $row.ProcessId -ne $ExpectedProcessId -or
        $row.ClassName -cne '#32768' -or
        $row.Right -le $row.Left -or $row.Bottom -le $row.Top) {
        throw 'Recovery menu popup changed its native identity or geometry.'
    }
    [ordered]@{
        hwnd = [long]$row.Handle
        process_id = [int]$row.ProcessId
        session_id = [int]$ExpectedSession
        window_class = $row.ClassName
        visible = $true
        rect = [ordered]@{
            left = [int]$row.Left
            top = [int]$row.Top
            right = [int]$row.Right
            bottom = [int]$row.Bottom
        }
    }
}

function ConvertTo-AcceptanceRecoveryMenuState {
    param(
        [Parameter(Mandatory)][object[]] $Rows,
        [Parameter(Mandatory)][int] $TargetCommandId,
        [Parameter(Mandatory)][int] $TargetPosition,
        [Parameter(Mandatory)][object] $Popup,
        [switch] $RequireHighlight
    )

    if (($TargetCommandId -ne 0x9000 -or $TargetPosition -ne 1) -and
        ($TargetCommandId -ne 0x9001 -or $TargetPosition -ne 3)) {
        throw 'Recovery menu target command and position are invalid.'
    }
    if ($Popup.hwnd -le 0 -or $Popup.window_class -cne '#32768' -or
        -not $Popup.visible -or $Popup.rect.right -le $Popup.rect.left -or
        $Popup.rect.bottom -le $Popup.rect.top) {
        throw 'Recovery menu popup binding is invalid.'
    }
    $expectedTypes = @('command', 'command', 'separator', 'command')
    $expectedCommands = @(0x9002, 0x9000, $null, 0x9001)
    if ($Rows.Count -ne 4) {
        throw 'Recovery menu must contain exactly four native rows.'
    }
    $normalized = [Collections.Generic.List[object]]::new()
    $highlights = [Collections.Generic.List[object]]::new()
    for ($position = 0; $position -lt 4; $position++) {
        $matches = @($Rows | Where-Object { $_.Position -eq $position })
        if ($matches.Count -ne 1) {
            throw 'Recovery menu positions are missing or duplicated.'
        }
        $row = $matches[0]
        $commandId = if ($null -eq $row.CommandId) { $null } else { [int]$row.CommandId }
        if ($row.RootPosition -ne 4 -or $row.Position -ne $position -or
            $row.ItemType -cne $expectedTypes[$position] -or
            (($null -eq $expectedCommands[$position]) -ne ($null -eq $commandId)) -or
            ($null -ne $commandId -and $commandId -ne $expectedCommands[$position]) -or
            $row.StateFlags -lt 0 -or $row.StateFlags -gt 255 -or
            $row.Right -le $row.Left -or $row.Bottom -le $row.Top -or
            $row.Left -lt $Popup.rect.left -or $row.Top -lt $Popup.rect.top -or
            $row.Right -gt $Popup.rect.right -or $row.Bottom -gt $Popup.rect.bottom) {
            throw 'Recovery menu row identity, state, or geometry is invalid.'
        }
        $enabled = ([int]$row.StateFlags -band 0x3) -eq 0
        $item = [ordered]@{
            root_position = 4
            position = $position
            item_type = [string]$row.ItemType
            command_id = $commandId
            state_flags = [int]$row.StateFlags
            enabled = $enabled
            rect = [ordered]@{
                left = [int]$row.Left; top = [int]$row.Top
                right = [int]$row.Right; bottom = [int]$row.Bottom
            }
        }
        $normalized.Add($item)
        if (($item.state_flags -band 0x80) -ne 0) {
            $highlights.Add($item)
        }
    }
    if ($highlights.Count -gt 1) {
        throw 'Recovery menu has more than one native highlighted row.'
    }
    $highlight = if ($highlights.Count -eq 1) { $highlights[0] } else { $null }
    if ($null -ne $highlight -and
        ($highlight.item_type -cne 'command' -or -not $highlight.enabled)) {
        throw 'Recovery menu highlighted a separator, submenu, or disabled command.'
    }
    if ($RequireHighlight -and $null -eq $highlight) {
        throw 'Recovery menu has no native highlighted command.'
    }
    $target = $normalized[$TargetPosition]
    if ($target.command_id -ne $TargetCommandId -or -not $target.enabled) {
        throw 'Recovery menu target command is missing or disabled.'
    }
    [ordered]@{
        popup = $Popup
        rows = $normalized.ToArray()
        target = $target
        highlighted = $highlight
    }
}

function Get-AcceptanceRecoveryMenuState {
    param(
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][object] $Popup,
        [Parameter(Mandatory)][int] $TargetCommandId,
        [Parameter(Mandatory)][int] $TargetPosition,
        [switch] $RequireHighlight
    )

    $rows = @([DarkReNamerRecoveryMenuNative]::ReadRecoveryMenuItems($MainWindowHandle))
    ConvertTo-AcceptanceRecoveryMenuState `
        -Rows $rows `
        -TargetCommandId $TargetCommandId `
        -TargetPosition $TargetPosition `
        -Popup $Popup `
        -RequireHighlight:$RequireHighlight
}

function Wait-AcceptanceRecoveryMenuHighlightChange {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][object] $Popup,
        [Parameter(Mandatory)][int] $TargetCommandId,
        [Parameter(Mandatory)][int] $TargetPosition,
        [AllowNull()][object] $PreviousHighlight
    )

    $deadline = (Get-Date).AddSeconds(2)
    do {
        $inventory = [DarkReNamerRecoveryMenuNative]::ReadVisiblePopups([uint32]$Process.Id)
        $currentPopup = ConvertTo-AcceptanceRecoveryMenuObservation `
            -Inventory $inventory -ExpectedProcessId $Process.Id `
            -ExpectedSession $ExpectedSession -ActualSession $Process.SessionId
        if ($null -eq $currentPopup -or $currentPopup.hwnd -ne $Popup.hwnd) {
            throw 'Recovery menu popup changed while navigating its commands.'
        }
        $state = Get-AcceptanceRecoveryMenuState `
            -MainWindowHandle $MainWindowHandle -Popup $currentPopup `
            -TargetCommandId $TargetCommandId -TargetPosition $TargetPosition
        if ($null -ne $state.highlighted -and
            ($null -eq $PreviousHighlight -or
                $state.highlighted.position -ne $PreviousHighlight.position -or
                $state.highlighted.command_id -ne $PreviousHighlight.command_id)) {
            return $state
        }
        Start-Sleep -Milliseconds 50
        $Process.Refresh()
        if ($Process.HasExited -or $Process.SessionId -ne $ExpectedSession) {
            throw 'The candidate changed process state during recovery menu navigation.'
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Recovery menu highlight did not change before the bounded deadline.'
}

function Wait-AcceptanceRecoveryMenuClosed {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][long] $ExpectedPopupHandle,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [scriptblock] $ReadInventory = {
            param([uint32] $ExpectedProcessId)
            [DarkReNamerRecoveryMenuNative]::ReadVisiblePopups($ExpectedProcessId)
        }
    )

    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $inventory = & $ReadInventory ([uint32]$Process.Id)
        $Process.Refresh()
        if ($Process.HasExited -or $Process.SessionId -ne $ExpectedSession) {
            throw 'The candidate changed process state before its recovery menu closed.'
        }
        if ($inventory.TotalCount -eq 0) { return }
        if ($inventory.TotalCount -ne 1) {
            throw 'Recovery menu activation left an ambiguous native popup inventory.'
        }
        $entries = @($inventory.Entries)
        if ($entries.Count -ne 1 -or $entries[0].Handle -ne $ExpectedPopupHandle) {
            throw 'Recovery menu activation replaced the exact native popup.'
        }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    throw 'Recovery menu popup did not close before the bounded deadline.'
}

function Wait-AcceptanceRecoveryMenuPopup {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    Initialize-AcceptanceRecoveryMenuNative
    $Process.Refresh()
    if ($Process.HasExited) {
        throw 'The candidate exited before its recovery menu appeared.'
    }
    if ($Process.SessionId -ne $ExpectedSession) {
        throw 'The recovery menu candidate process is in an unexpected desktop session.'
    }
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $inventory = [DarkReNamerRecoveryMenuNative]::ReadVisiblePopups([uint32]$Process.Id)
        $observation = ConvertTo-AcceptanceRecoveryMenuObservation `
            -Inventory $inventory `
            -ExpectedProcessId $Process.Id `
            -ExpectedSession $ExpectedSession `
            -ActualSession $Process.SessionId
        if ($null -ne $observation) {
            return $observation
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) { throw 'The candidate exited before its recovery menu appeared.' }
        if ($Process.SessionId -ne $ExpectedSession) {
            throw 'The recovery menu candidate process changed desktop session.'
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Recovery menu popup was not found before the bounded deadline.'
}

function Assert-AcceptanceRecoveryMenuForegroundObservation {
    param(
        [Parameter(Mandatory)][object] $Observation,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][string] $Label
    )

    if ($Observation.hwnd -ne [long]$MainWindowHandle -or
        $Observation.process_id -ne $ExpectedProcessId -or
        $Observation.session_id -ne $ExpectedSession -or
        $Observation.window_class -cne 'DarkReNamerWindow') {
        throw "The verified application foreground binding changed before $Label."
    }
}

function Get-AcceptanceRecoveryMenuForeground {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][string] $Label
    )

    $foreground = Get-ForegroundObservation
    Assert-AcceptanceRecoveryMenuForegroundObservation `
        -Observation $foreground -ExpectedProcessId $Process.Id `
        -ExpectedSession $ExpectedSession -MainWindowHandle $MainWindowHandle -Label $Label
    $foreground
}

function Start-AcceptanceRecoveryMenuInvoke {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][string] $ItemName,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)]
        [ValidateSet('export', 'discard-cancel', 'discard-confirm')]
        [string] $Purpose
    )

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
    $targetSpec = switch ($Purpose) {
        'export' {
            [ordered]@{
                command_id = 0x9000
                position = 1
                item_name = '복구 데이터 내보내기...'
            }
        }
        { $_ -in @('discard-cancel', 'discard-confirm') } {
            [ordered]@{
                command_id = 0x9001
                position = 3
                item_name = '시작되지 않은 작업 기록 삭제...'
            }
        }
    }
    if ($null -eq $targetSpec -or $ItemName -cne $targetSpec.item_name) {
        throw 'Recovery menu purpose and source-bound item name differ.'
    }
    $foregroundBefore = Get-AcceptanceRecoveryMenuForeground `
        -Process $process -ExpectedSession $SessionId `
        -MainWindowHandle $mainHandle -Label $Label
    Write-AcceptanceExportProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'before-menu-popup'
    Initialize-AcceptanceRecoveryMenuNative
    $inputResult = [DarkReNamerRecoveryMenuNative]::SendAltR()
    $foregroundAfter = Get-ForegroundObservation
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot `
        -Application $Application `
        -Purpose $Purpose `
        -Phase 'input-returned' `
        -Observation ([ordered]@{
            input_method = 'native-sendinput'
            virtual_keys = [int[]]@(0x12, 0x52)
            requested_event_count = [int]$inputResult.RequestedCount
            sent_event_count = [int]$inputResult.SentCount
            win32_error = [int]$inputResult.ErrorCode
            release_sent_count = [int]$inputResult.ReleaseSentCount
            foreground_before = $foregroundBefore
            foreground_after = $foregroundAfter
        })
    if ($inputResult.RequestedCount -ne 4 -or $inputResult.SentCount -ne 4) {
        throw "Native recovery-menu input was incomplete (sent $($inputResult.SentCount) of 4, error $($inputResult.ErrorCode))."
    }
    Assert-AcceptanceRecoveryMenuForegroundObservation `
        -Observation $foregroundAfter -ExpectedProcessId $process.Id `
        -ExpectedSession $SessionId -MainWindowHandle $mainHandle -Label "$Label Alt+R return"
    $nativePopup = Wait-AcceptanceRecoveryMenuPopup `
        -Process $process -ExpectedSession $SessionId -TimeoutSeconds $WaitSeconds
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'native-popup-found' -Observation $nativePopup
    $menuState = Get-AcceptanceRecoveryMenuState `
        -MainWindowHandle $mainHandle -Popup $nativePopup `
        -TargetCommandId $targetSpec.command_id -TargetPosition $targetSpec.position
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot `
        -Application $Application `
        -Purpose $Purpose `
        -Phase 'native-menu-bound' `
        -Observation ([ordered]@{
            popup = $nativePopup
            rows = $menuState.rows
            target = $menuState.target
            highlighted = $menuState.highlighted
        })
    Write-AcceptanceExportProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'popup-found'

    $navigationCount = 0
    while ($null -eq $menuState.highlighted -or
        $menuState.highlighted.command_id -ne $targetSpec.command_id) {
        if ($navigationCount -ge 4) {
            throw 'Recovery menu keyboard navigation did not reach the exact target command.'
        }
        $navigationCount++
        $downBefore = Get-AcceptanceRecoveryMenuForeground `
            -Process $process -ExpectedSession $SessionId `
            -MainWindowHandle $mainHandle -Label "$Label Down $navigationCount"
        $downResult = [DarkReNamerRecoveryMenuNative]::SendKeyTap([uint16]0x28)
        $downAfter = Get-ForegroundObservation
        Write-AcceptanceRecoveryMenuProgress `
            -PrivateRoot $PrivateRoot -Application $Application `
            -Purpose $Purpose -Phase ('navigation-' + $navigationCount) `
            -Observation ([ordered]@{
                input_method = 'native-sendinput'
                virtual_keys = [int[]]@(0x28)
                requested_event_count = [int]$downResult.RequestedCount
                sent_event_count = [int]$downResult.SentCount
                win32_error = [int]$downResult.ErrorCode
                release_sent_count = [int]$downResult.ReleaseSentCount
                foreground_before = $downBefore
                foreground_after = $downAfter
            })
        if ($downResult.RequestedCount -ne 2 -or $downResult.SentCount -ne 2) {
            throw "Recovery menu Down input $navigationCount was incomplete."
        }
        Assert-AcceptanceRecoveryMenuForegroundObservation `
            -Observation $downAfter -ExpectedProcessId $process.Id `
            -ExpectedSession $SessionId -MainWindowHandle $mainHandle `
            -Label "$Label Down $navigationCount return"
        $previousHighlight = $menuState.highlighted
        $menuState = Wait-AcceptanceRecoveryMenuHighlightChange `
            -Process $process -ExpectedSession $SessionId `
            -MainWindowHandle $mainHandle -Popup $nativePopup `
            -TargetCommandId $targetSpec.command_id -TargetPosition $targetSpec.position `
            -PreviousHighlight $previousHighlight
    }
    $menuState = Get-AcceptanceRecoveryMenuState `
        -MainWindowHandle $mainHandle -Popup $nativePopup `
        -TargetCommandId $targetSpec.command_id -TargetPosition $targetSpec.position `
        -RequireHighlight
    if ($menuState.highlighted.command_id -ne $targetSpec.command_id -or
        $menuState.highlighted.position -ne $targetSpec.position) {
        throw 'Recovery menu native highlight is not the exact target command.'
    }
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'native-command-highlighted' `
        -Observation ([ordered]@{
            popup = $nativePopup
            target = $menuState.target
            highlighted = $menuState.highlighted
            down_input_count = $navigationCount
        })
    Write-AcceptanceExportProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'menu-item-found'

    $enterBefore = Get-AcceptanceRecoveryMenuForeground `
        -Process $process -ExpectedSession $SessionId `
        -MainWindowHandle $mainHandle -Label "$Label Enter"
    $popupInventory = [DarkReNamerRecoveryMenuNative]::ReadVisiblePopups([uint32]$process.Id)
    $enterPopup = ConvertTo-AcceptanceRecoveryMenuObservation `
        -Inventory $popupInventory -ExpectedProcessId $process.Id `
        -ExpectedSession $SessionId -ActualSession $process.SessionId
    if ($null -eq $enterPopup -or $enterPopup.hwnd -ne $nativePopup.hwnd) {
        throw 'Recovery menu popup changed before exact target activation.'
    }
    $enterState = Get-AcceptanceRecoveryMenuState `
        -MainWindowHandle $mainHandle -Popup $enterPopup `
        -TargetCommandId $targetSpec.command_id -TargetPosition $targetSpec.position `
        -RequireHighlight
    if ($enterState.highlighted.command_id -ne $targetSpec.command_id -or
        $enterState.highlighted.position -ne $targetSpec.position) {
        throw 'Recovery menu highlight changed before exact target activation.'
    }
    $enterResult = [DarkReNamerRecoveryMenuNative]::SendKeyTap([uint16]0x0D)
    $enterAfter = Get-ForegroundObservation
    Write-AcceptanceRecoveryMenuProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'native-enter-returned' `
        -Observation ([ordered]@{
            input_method = 'native-sendinput'
            virtual_keys = [int[]]@(0x0D)
            requested_event_count = [int]$enterResult.RequestedCount
            sent_event_count = [int]$enterResult.SentCount
            win32_error = [int]$enterResult.ErrorCode
            release_sent_count = [int]$enterResult.ReleaseSentCount
            foreground_before = $enterBefore
            foreground_after = $enterAfter
            target = $enterState.target
            highlighted = $enterState.highlighted
        })
    if ($enterResult.RequestedCount -ne 2 -or $enterResult.SentCount -ne 2) {
        throw 'Recovery menu Enter input was incomplete.'
    }
    if ($enterAfter.process_id -ne $process.Id -or $enterAfter.session_id -ne $SessionId) {
        throw 'Recovery menu activation changed foreground to another process or session.'
    }
    Wait-AcceptanceRecoveryMenuClosed `
        -Process $process -ExpectedSession $SessionId `
        -ExpectedPopupHandle $nativePopup.hwnd -TimeoutSeconds $WaitSeconds
    Write-AcceptanceExportProgress `
        -PrivateRoot $PrivateRoot -Application $Application `
        -Purpose $Purpose -Phase 'invoke-started'
    [pscustomobject][ordered]@{
        input = 'native-keyboard-down-enter'
        target_command_id = [int]$targetSpec.command_id
        target_position = [int]$targetSpec.position
        down_input_count = $navigationCount
        enter_sent = $true
        popup_closed = $true
    }
}

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
        [Windows.Automation.AutomationElement] $Window
    )

    Add-Type -AssemblyName System.Windows.Forms
    if ($null -eq $Window) {
        $Window = Wait-UniqueAutomationWindow `
            -Process $Application.owned.process `
            -ExpectedSession $SessionId `
            -Name $Name `
            -TimeoutSeconds $WaitSeconds `
            -Label $Label
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
        [Parameter(Mandatory)][int] $WaitSeconds,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[object]] $ForegroundObservations,
        [Windows.Automation.AutomationElement] $Prompt
    )

    $process = $Application.owned.process
    if ($null -eq $Prompt) {
        $Prompt = Wait-UniqueAutomationWindow `
            -Process $process `
            -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 이전 변경 복구 확인' `
            -TimeoutSeconds $WaitSeconds `
            -Label 'startup recovery confirmation'
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
        -Label 'recovery completion message'
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
        $Prompt = Wait-UniqueAutomationWindow `
            -Process $process -Owner $Application.main `
            -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 이전 변경 복구 확인' `
            -TimeoutSeconds $WaitSeconds `
            -Label 'startup recovery cancellation prompt'
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
    $dialog = Wait-UniqueAutomationWindow `
        -Process $Application.owned.process `
        -Owner $Application.main `
        -ExpectedSession $SessionId `
        -Name '복구 저널 원본을 저장할 폴더 선택' `
        -TimeoutSeconds $WaitSeconds `
        -Label 'recovery export folder picker'
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
        -Label 'recovery export completion message'
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
            -Label 'candidate discard completion message'
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
        $startupNotice = Wait-UniqueAutomationWindow `
            -Process $cancelApplication.owned.process `
            -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 복구 상태' `
            -TimeoutSeconds $WaitSeconds `
            -Label 'Intent-only startup recovery-lock notice'
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
            -Label 'Intent-only verification relaunch recovery-lock notice'
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
            -Name 'DarkReNamer - 복구 상태' -Label 'Intent-only discard recovery-lock notice'
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
        $recoveryPrompt = Wait-UniqueAutomationWindow `
            -Process $second.owned.process -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 이전 변경 복구 확인' -TimeoutSeconds $WaitSeconds `
            -Label 'startup recovery confirmation before default cancel'
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
        $relaunchPrompt = Wait-UniqueAutomationWindow `
            -Process $third.owned.process -ExpectedSession $SessionId `
            -Name 'DarkReNamer - 이전 변경 복구 확인' -TimeoutSeconds $WaitSeconds `
            -Label 'startup recovery confirmation after default cancel'
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
                -Application $third -SessionId $SessionId -WaitSeconds $WaitSeconds -Prompt $relaunchPrompt
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
            $exportRelaunchPrompt = Wait-UniqueAutomationWindow `
                -Process $fourth.owned.process -ExpectedSession $SessionId `
                -Name 'DarkReNamer - 이전 변경 복구 확인' -TimeoutSeconds $WaitSeconds `
                -Label 'startup recovery confirmation after export'
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
            -Application $recoveryApplication -EvidenceRoot $EvidenceRoot `
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
if ($MyInvocation.InvocationName -eq '.') {
    return
}

$requestedBundleRoot = $BundleRoot
$requestedExpectedSessionId = $ExpectedSessionId
$requestedPrivateEvidenceRoot = $PrivateEvidenceRoot
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
$PrivateEvidenceRoot = $requestedPrivateEvidenceRoot
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
    Write-Host "Validated recovery acceptance inputs for product source $($inputs.contract.product_source_sha) and harness source $($inputs.contract.harness_source_sha)."
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
$privateRoot = New-AcceptancePrivateEvidenceDirectory -Parent $PrivateEvidenceRoot
$runtimeRoot = New-PrivateDirectory -Parent $evidenceRoot -Leaf 'runtime'
$result = [ordered]@{
    schema_version = if ($inputs.contract.lane -ceq 'candidate-gui-only') { 2 } else { 1 }
    application = [ordered]@{
        file = $inputs.contract.application.file
        sha256 = $inputs.contract.application.sha256
    }
}
if ($inputs.contract.lane -ceq 'candidate-gui-only') {
    $result['lane'] = $inputs.contract.lane
    $result['product'] = $inputs.verified.manifest.product
    $result['harness'] = $inputs.verified.manifest.harness
    $result['observer_role'] = 'recovery'
}
else {
    $result['source_sha'] = $inputs.contract.product_source_sha
    $result['source_state'] = $inputs.contract.product_source_state
}
$result['runner_sha256'] = $inputs.runner_sha256
$result['observer'] = [ordered]@{
    file = $inputs.observer_file
    sha256 = $inputs.observer_sha256
}
$result['status'] = 'failed'
$result['scope'] = 'production-rename-worker-interruption'
$result['selected_mode'] = $Mode
$result['process_crash'] = [ordered]@{ status = 'not-run'; reason = 'mode-not-selected' }
$result['worker_cancellation'] = [ordered]@{ status = 'not-run'; reason = 'mode-not-selected' }
$result['worker_close'] = [ordered]@{ status = 'not-run'; reason = 'mode-not-selected' }
$result['recovery_export'] = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
$result['intent_only_candidate_discard'] = [ordered]@{ status = 'not-run'; reason = 'switch-not-selected' }
$result['failure_reason'] = $null
$result['diagnostic'] = $null
$result['ui_diagnostic'] = $null
$result['private_evidence'] = $null
$result['raw_cleanup'] = $null
$desktopLock = $null
$previousExecutionState = $null
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
            -PrivateRoot $privateRoot `
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
    $uiDiagnosticPath = Join-Path $privateRoot 'session-ui-diagnostic.json'
    if (Test-Path -LiteralPath $uiDiagnosticPath -PathType Leaf) {
        $result.ui_diagnostic = New-AcceptancePrivateReference `
            -Path $uiDiagnosticPath -PrivateRoot $privateRoot -Boundary 'failure-ui-diagnostic'
    }
    $diagnosticPath = Join-Path $privateRoot 'diagnostic.txt'
    $diagnosticBytes = [Text.UTF8Encoding]::new($false).GetBytes(
        ($_ | Out-String -Width 4096)
    )
    Write-AcceptanceNewBytes -Path $diagnosticPath -Bytes $diagnosticBytes
    $result.diagnostic = New-AcceptancePrivateReference `
        -Path $diagnosticPath -PrivateRoot $privateRoot -Boundary 'failure-diagnostic'
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
    $ownedProcessesAfter = $null
    $journalAfter = $null
    $runtimeRootAfter = $null
    try {
        $ownedProcessesAfter = @(
            Get-VmAutomatedOwnedProcessInventory -Root $inputs.verified.root
        )
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'owned_process_cleanup_observation_failed'
    }
    try {
        $journalAfter = @(
            Get-VmAutomatedJournalInventory `
                -LocalAppData (Join-Path $runtimeRoot 'localappdata')
        )
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'journal_cleanup_observation_failed'
    }
    if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
        try {
            $runtimeItem = Get-Item -LiteralPath $runtimeRoot -Force
            if (($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The owned runtime root became a reparse point.'
            }
            foreach ($entry in @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -Force)) {
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'The owned runtime tree contains a reparse point.'
                }
            }
            Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
            if (Test-Path -LiteralPath $runtimeRoot) {
                throw 'The owned runtime fixture cleanup was incomplete.'
            }
        }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'runtime_cleanup_refused'
        }
    }
    try {
        $runtimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot
    }
    catch {
        $result.status = 'failed'
        $result.failure_reason = 'runtime_cleanup_observation_failed'
    }
    $result.raw_cleanup = [ordered]@{
        owned_processes_after = $ownedProcessesAfter
        runtime_root_after = $runtimeRootAfter
        journal_after = [ordered]@{ entries = $journalAfter }
    }
    if ($null -eq $ownedProcessesAfter -or $ownedProcessesAfter.Count -ne 0 -or
        $null -eq $runtimeRootAfter -or $runtimeRootAfter.exists -or
        @($runtimeRootAfter.entries).Count -ne 0) {
        $result.status = 'failed'
        if ($null -eq $result.failure_reason) {
            $result.failure_reason = 'raw_cleanup_incomplete'
        }
    }
    if ($null -ne $journalAfter) {
        $unexpectedJournal = @($journalAfter | Where-Object {
            $_.name -cne 'runtime.lock' -or $_.kind -cne 'file' -or $_.bytes -ne 0
        })
        if ($unexpectedJournal.Count -ne 0 -or $journalAfter.Count -gt 1) {
            $result.status = 'failed'
            if ($null -eq $result.failure_reason) {
                $result.failure_reason = 'raw_journal_cleanup_incomplete'
            }
        }
    }
    try {
        $result.private_evidence = Write-AcceptancePrivateIndex -PrivateRoot $privateRoot
    }
    catch {
        $result.status = 'failed'
        if ($null -eq $result.failure_reason) {
            $result.failure_reason = 'private_evidence_index_failed'
        }
    }
    Write-AcceptanceUtf8Json -Path (Join-Path $evidenceRoot 'summary.json') -Value $result
}
Write-Host "Recovery acceptance evidence: $evidenceRoot"
if ($result.status -cne 'passed') {
    throw 'Recovery acceptance failed; inspect the external evidence directory.'
}
