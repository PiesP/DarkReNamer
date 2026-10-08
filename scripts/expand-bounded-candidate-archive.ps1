[CmdletBinding()]
param(
    [string] $ArchivePath,
    [string] $DestinationPath,
    [switch] $LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CandidateHandoffNames {
    @(
        'DarkReNamer-debug-symbols.zip', 'DarkReNamer.cdx.json',
        'DarkReNamer.exe', 'DarkReNamer.pdb', 'DISTRIBUTION.md', 'LICENSE',
        'release-handoff.json', 'release-metrics.json', 'SHA256SUMS.txt',
        'THIRD_PARTY_LICENSES.html', 'THIRD_PARTY_NOTICES.md'
    )
}

function Read-CandidateBytes {
    param([IO.Stream] $Stream, [int] $Count)
    $bytes = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($bytes, $offset, $Count - $offset)
        if ($read -eq 0) { throw 'Candidate ZIP is truncated.' }
        $offset += $read
    }
    ,$bytes
}

function Assert-CandidateExtraFields {
    param([byte[]] $Bytes)
    $offset = 0
    while ($offset -lt $Bytes.Length) {
        if ($Bytes.Length - $offset -lt 4) { throw 'Malformed candidate ZIP extra field.' }
        $tag = [BitConverter]::ToUInt16($Bytes, $offset)
        $length = [BitConverter]::ToUInt16($Bytes, $offset + 2)
        $offset += 4
        if ($length -gt $Bytes.Length - $offset -or $tag -in @(1, 0x9901)) {
            throw 'Unsupported candidate ZIP extra field (ZIP64/encryption or malformed).'
        }
        $offset += $length
    }
}

function Get-BoundedCandidateDirectory {
    param([IO.FileStream] $Stream, [long] $MaximumEntryBytes, [long] $MaximumExpandedBytes)
    # Bound metadata before materializing entries or opening any decompressor.
    $tailLength = [int][Math]::Min(65557, $Stream.Length)
    if ($tailLength -lt 22) { throw 'Candidate ZIP has no complete end record.' }
    $Stream.Position = $Stream.Length - $tailLength
    $tail = Read-CandidateBytes $Stream $tailLength
    $end = -1
    for ($index = $tail.Length - 22; $index -ge 0; $index--) {
        if ([BitConverter]::ToUInt32($tail, $index) -eq 0x06054b50 -and
            $index + 22 + [BitConverter]::ToUInt16($tail, $index + 20) -eq $tail.Length) {
            $end = $index
            break
        }
    }
    if ($end -lt 0) { throw 'Candidate ZIP end record is missing or has trailing data.' }
    $count = [BitConverter]::ToUInt16($tail, $end + 10)
    $directorySize = [long][BitConverter]::ToUInt32($tail, $end + 12)
    $directoryOffset = [long][BitConverter]::ToUInt32($tail, $end + 16)
    $endOffset = $Stream.Length - $tailLength + $end
    $names = @(Get-CandidateHandoffNames)
    if ([BitConverter]::ToUInt16($tail, $end + 4) -ne 0 -or
        [BitConverter]::ToUInt16($tail, $end + 6) -ne 0 -or
        [BitConverter]::ToUInt16($tail, $end + 8) -ne $count -or
        $count -ne $names.Count -or $directorySize -gt 32768 -or
        $directoryOffset -eq [uint32]::MaxValue -or $directorySize -eq [uint32]::MaxValue -or
        $directoryOffset -gt $endOffset -or $directorySize -ne $endOffset - $directoryOffset -or
        [BitConverter]::ToUInt16($tail, $end + 20) -gt 1024) {
        throw 'Candidate ZIP directory exceeds its fixed layout or metadata budget.'
    }
    $Stream.Position = $directoryOffset
    $directory = [IO.MemoryStream]::new((Read-CandidateBytes $Stream ([int]$directorySize)), $false)
    $allowed = [Collections.Generic.HashSet[string]]::new([string[]]$names, [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $entries = [Collections.Generic.List[object]]::new()
    [long]$total = 0
    try {
        for ($index = 0; $index -lt $count; $index++) {
            $header = Read-CandidateBytes $directory 46
            $version = [BitConverter]::ToUInt16($header, 6)
            $flags = [BitConverter]::ToUInt16($header, 8)
            $method = [BitConverter]::ToUInt16($header, 10)
            $compressed = [long][BitConverter]::ToUInt32($header, 20)
            $expanded = [long][BitConverter]::ToUInt32($header, 24)
            $nameLength = [BitConverter]::ToUInt16($header, 28)
            $extraLength = [BitConverter]::ToUInt16($header, 30)
            $commentLength = [BitConverter]::ToUInt16($header, 32)
            $attributes = [BitConverter]::ToUInt32($header, 38)
            $localOffset = [long][BitConverter]::ToUInt32($header, 42)
            $mode = ($attributes -shr 16) -band 0xf000
            if ([BitConverter]::ToUInt32($header, 0) -ne 0x02014b50 -or
                $version -gt 20 -or ($flags -band 0xf7f1) -ne 0 -or $method -notin @(0, 8) -or
                $nameLength -lt 1 -or $nameLength -gt 64 -or $extraLength -gt 1024 -or
                $commentLength -gt 1024 -or [BitConverter]::ToUInt16($header, 34) -ne 0 -or
                $mode -notin @(0, 0x8000) -or ($attributes -band 0x410) -ne 0 -or
                $compressed -eq [uint32]::MaxValue -or $localOffset -eq [uint32]::MaxValue -or
                $expanded -le 0 -or $expanded -gt $MaximumEntryBytes -or
                $expanded -gt $MaximumExpandedBytes - $total) {
                throw 'Unsupported candidate ZIP entry or declared expansion exceeds budget.'
            }
            $nameBytes = Read-CandidateBytes $directory $nameLength
            if (@($nameBytes | Where-Object { $_ -gt 127 }).Count -ne 0) {
                throw 'Candidate ZIP names must use the fixed ASCII layout.'
            }
            $name = [Text.Encoding]::ASCII.GetString($nameBytes)
            if (-not $allowed.Contains($name) -or -not $seen.Add($name)) {
                throw 'Candidate ZIP contains an unexpected, colliding or duplicate name.'
            }
            Assert-CandidateExtraFields (Read-CandidateBytes $directory $extraLength)
            $null = Read-CandidateBytes $directory $commentLength
            $total += $expanded
            $entries.Add([pscustomobject]@{
                Name = $name; Flags = $flags; Method = $method; Crc = [BitConverter]::ToUInt32($header, 16)
                Compressed = $compressed; Expanded = $expanded; LocalOffset = $localOffset
            })
        }
        if ($directory.Position -ne $directory.Length -or -not $seen.SetEquals($allowed)) {
            throw 'Candidate ZIP directory does not match the complete fixed layout.'
        }
    }
    finally { $directory.Dispose() }
    [long]$previousEnd = 0
    foreach ($entry in @($entries | Sort-Object LocalOffset)) {
        if ($entry.LocalOffset -lt $previousEnd -or $entry.LocalOffset -gt $directoryOffset - 30) {
            throw 'Candidate ZIP local records overlap or exceed the data area.'
        }
        $Stream.Position = $entry.LocalOffset
        $header = Read-CandidateBytes $Stream 30
        $nameLength = [BitConverter]::ToUInt16($header, 26)
        $extraLength = [BitConverter]::ToUInt16($header, 28)
        if ([BitConverter]::ToUInt32($header, 0) -ne 0x04034b50 -or
            [BitConverter]::ToUInt16($header, 4) -gt 20 -or
            [BitConverter]::ToUInt16($header, 6) -ne $entry.Flags -or
            [BitConverter]::ToUInt16($header, 8) -ne $entry.Method -or
            $nameLength -ne $entry.Name.Length -or $extraLength -gt 1024) {
            throw 'Candidate ZIP local header disagrees with its bounded directory.'
        }
        if ([Text.Encoding]::ASCII.GetString((Read-CandidateBytes $Stream $nameLength)) -cne $entry.Name) {
            throw 'Candidate ZIP local name disagrees with its bounded directory.'
        }
        Assert-CandidateExtraFields (Read-CandidateBytes $Stream $extraLength)
        if (($entry.Flags -band 8) -eq 0 -and
            ([BitConverter]::ToUInt32($header, 14) -ne $entry.Crc -or
             [BitConverter]::ToUInt32($header, 18) -ne $entry.Compressed -or
             [BitConverter]::ToUInt32($header, 22) -ne $entry.Expanded)) {
            throw 'Candidate ZIP local lengths or CRC disagree with its directory.'
        }
        if ($entry.Compressed -gt $directoryOffset - $Stream.Position) {
            throw 'Candidate ZIP compressed data exceeds its data area.'
        }
        $entry | Add-Member -NotePropertyName DataOffset -NotePropertyValue $Stream.Position
        $previousEnd = $Stream.Position + $entry.Compressed
    }
    $entries.ToArray()
}

function Initialize-CandidateSliceStream {
    if ('DarkReNamer.Tooling.CandidateSliceStream' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
namespace DarkReNamer.Tooling {
    // Limits compressed reads without retaining the compressed member in memory.
    public sealed class CandidateSliceStream : Stream {
        private readonly Stream source;
        private readonly long length;
        private long consumed;
        public CandidateSliceStream(Stream source, long offset, long length) {
            this.source = source;
            this.length = length;
            source.Position = offset;
        }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => length;
        public override long Position { get => consumed; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) {
            int read = source.Read(buffer, offset, (int)Math.Min(count, length - consumed));
            consumed += read;
            return read;
        }
        public override int Read(Span<byte> buffer) {
            int read = source.Read(buffer.Slice(0, (int)Math.Min(buffer.Length, length - consumed)));
            consumed += read;
            return read;
        }
        public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) {
            int read = await source.ReadAsync(buffer, offset, (int)Math.Min(count, length - consumed), token);
            consumed += read;
            return read;
        }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default) {
            int read = await source.ReadAsync(buffer.Slice(0, (int)Math.Min(buffer.Length, length - consumed)), token);
            consumed += read;
            return read;
        }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long length) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
'@
}

function Expand-BoundedCandidateArchive {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $DestinationPath,
        [long] $MaximumArchiveBytes = 536870912,
        [long] $MaximumEntryBytes = 268435456,
        [long] $MaximumExpandedBytes = 536870912,
        [int] $DeadlineSeconds = 300
    )
    if ($MaximumArchiveBytes -le 0 -or $MaximumArchiveBytes -gt 536870912 -or
        $MaximumEntryBytes -le 0 -or $MaximumEntryBytes -gt 268435456 -or
        $MaximumExpandedBytes -le 0 -or $MaximumExpandedBytes -gt 536870912 -or
        $DeadlineSeconds -le 0 -or $DeadlineSeconds -gt 300) {
        throw 'Candidate extraction limits may only reduce the source-owned policy.'
    }
    $inputFile = Get-Item -LiteralPath $ArchivePath -Force
    if ($inputFile.PSIsContainer -or ($inputFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Candidate ZIP must be an ordinary file.'
    }
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    if (Test-Path -LiteralPath $destination) { throw 'Candidate destination must be new.' }
    $parent = Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($destination)) -Force
    if (-not $parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Candidate destination parent must be an ordinary directory.'
    }
    $inputStream = [IO.FileStream]::new($inputFile.FullName, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($DeadlineSeconds))
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($inputStream.Length -le 0 -or $inputStream.Length -gt $MaximumArchiveBytes) {
            throw 'Candidate ZIP compressed bytes exceed budget.'
        }
        $directory = @(Get-BoundedCandidateDirectory $inputStream $MaximumEntryBytes $MaximumExpandedBytes)
        Initialize-CandidateSliceStream
        # Never merge into existing files. A failure retains only this new task-owned directory.
        $null = New-Item -ItemType Directory -Path $destination -ErrorAction Stop
        $buffer = [byte[]]::new(65536)
        [long]$total = 0
        for ($index = 0; $index -lt $directory.Count; $index++) {
            $expected = $directory[$index]
            $compressedStream = [DarkReNamer.Tooling.CandidateSliceStream]::new(
                $inputStream, $expected.DataOffset, $expected.Compressed)
            # ZipArchive.Open may hide excess output by truncating to declared Length.
            # Direct DEFLATE decoding lets the actual-byte check see one byte beyond it.
            $entryStream = if ($expected.Method -eq 8) {
                [IO.Compression.DeflateStream]::new($compressedStream, [IO.Compression.CompressionMode]::Decompress, $true)
            }
            else { $compressedStream }
            $outputStream = $null
            [long]$written = 0
            try {
                $outputStream = [IO.FileStream]::new((Join-Path $destination $expected.Name),
                    [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                while ($true) {
                    if ($clock.Elapsed.TotalSeconds -ge $DeadlineSeconds) { throw 'Candidate extraction deadline exceeded.' }
                    $remaining = [Math]::Min($MaximumEntryBytes - $written, $MaximumExpandedBytes - $total)
                    $remaining = [Math]::Min($remaining, $expected.Expanded - $written)
                    $readSize = [int][Math]::Min($buffer.Length, $remaining + 1)
                    $read = $entryStream.ReadAsync($buffer, 0, $readSize, $cancellation.Token).GetAwaiter().GetResult()
                    if ($read -eq 0) { break }
                    if ($read -gt $remaining) { throw 'Candidate ZIP actual expansion exceeds declared size or byte budget.' }
                    $outputStream.Write($buffer, 0, $read)
                    $written += $read
                    $total += $read
                }
                if ($written -ne $expected.Expanded) { throw 'Candidate ZIP actual length disagrees with its directory.' }
            }
            finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                $entryStream.Dispose()
                $compressedStream.Dispose()
            }
        }
        Write-Host "Extracted $($directory.Count) fixed candidate files ($total bytes) within resource limits."
    }
    finally {
        $inputStream.Dispose()
        $cancellation.Dispose()
    }
}

if (-not $LibraryOnly) {
    if (-not $ArchivePath -or -not $DestinationPath) { throw 'ArchivePath and DestinationPath are required.' }
    Expand-BoundedCandidateArchive -ArchivePath $ArchivePath -DestinationPath $DestinationPath
}
