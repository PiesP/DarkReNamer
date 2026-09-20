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
