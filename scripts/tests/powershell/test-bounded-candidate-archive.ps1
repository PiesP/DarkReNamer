[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
. (Join-Path $toolingTestPaths.ScriptsRoot 'expand-bounded-candidate-archive.ps1') -LibraryOnly
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.IO;
namespace CandidateArchiveFixture {
    public sealed class NonSeekableWriter : Stream {
        private readonly Stream target;
        public NonSeekableWriter(Stream target) { this.target = target; }
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => target.Flush();
        public override void Write(byte[] buffer, int offset, int count) => target.Write(buffer, offset, count);
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long length) => throw new NotSupportedException();
    }
}
'@

$root = Join-Path ([IO.Path]::GetTempPath()) ('bounded-candidate-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$script:cases = 0
function New-Fixture {
    param([string[]] $Names = @(Get-CandidateHandoffNames), [int] $Size = 4,
          [switch] $Descriptor, [switch] $Stored)
    $path = Join-Path $root ([guid]::NewGuid().ToString('N') + '.zip')
    $file = [IO.File]::Create($path)
    $archiveStream = if ($Descriptor) { [CandidateArchiveFixture.NonSeekableWriter]::new($file) } else { $file }
    $zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($name in $Names) {
            $level = if ($Stored) { [IO.Compression.CompressionLevel]::NoCompression } else { [IO.Compression.CompressionLevel]::Optimal }
            $entry = $zip.CreateEntry($name, $level)
            $entry.ExternalAttributes = [Convert]::ToInt32('81b60020', 16)
            $stream = $entry.Open()
            try { $stream.Write([byte[]]::new($Size), 0, $Size) }
            finally { $stream.Dispose() }
        }
    }
    finally { $zip.Dispose(); $archiveStream.Dispose(); $file.Dispose() }
    $path
}
function Set-ZipField {
    param([string] $Path, [int] $Offset, [byte[]] $Bytes)
    $data = [IO.File]::ReadAllBytes($Path)
    [Array]::Copy($Bytes, 0, $data, $Offset, $Bytes.Length)
    [IO.File]::WriteAllBytes($Path, $data)
}
function Get-ZipDirectoryOffset {
    param([string] $Path)
    $data = [IO.File]::ReadAllBytes($Path)
    [int][BitConverter]::ToUInt32($data, $data.Length - 6)
}
function Assert-Rejected {
    param([string] $Path, [hashtable] $Limits = @{}, [switch] $Partial)
    $destination = Join-Path $root ([guid]::NewGuid().ToString('N'))
    $rejected = $false
    try { Expand-BoundedCandidateArchive -ArchivePath $Path -DestinationPath $destination @Limits }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe candidate fixture was accepted.' }
    if (-not $Partial -and (Test-Path -LiteralPath $destination)) {
        throw 'Metadata rejection must precede destination creation.'
    }
    if ($Partial -and (Test-Path -LiteralPath $destination)) {
        $written = @(Get-ChildItem -LiteralPath $destination -File | Measure-Object Length -Sum)[0].Sum
        if ($written -gt 44) { throw 'Failed extraction wrote beyond its tiny budget.' }
    }
    $script:cases++

}
try {
    $valid = New-Fixture
    $destination = Join-Path $root 'valid'
    Expand-BoundedCandidateArchive -ArchivePath $valid -DestinationPath $destination `
        -MaximumArchiveBytes (Get-Item -LiteralPath $valid).Length -MaximumEntryBytes 4 -MaximumExpandedBytes 44
    $files = @(Get-ChildItem -LiteralPath $destination -File)
    if ($files.Count -ne 11 -or @($files | Where-Object Length -ne 4).Count -ne 0) {
        throw 'Exact reduced limits must preserve the complete normal handoff.'
    }
    $script:cases++
    foreach ($mode in @('descriptor', 'stored')) {
        $path = if ($mode -ceq 'descriptor') { New-Fixture -Descriptor } else { New-Fixture -Stored }
        $data = [IO.File]::ReadAllBytes($path)
        $central = Get-ZipDirectoryOffset $path
        if ($mode -ceq 'descriptor' -and ([BitConverter]::ToUInt16($data, $central + 8) -band 8) -eq 0) {
            throw 'Descriptor fixture must match Actions bit-3 ZIP form.'
        }
        if ($mode -ceq 'stored' -and [BitConverter]::ToUInt16($data, $central + 10) -ne 0) {
            throw 'Stored fixture must exercise uncompressed entries.'
        }
        $output = Join-Path $root $mode
        Expand-BoundedCandidateArchive $path $output -MaximumEntryBytes 4 -MaximumExpandedBytes 44
        if (@(Get-ChildItem -LiteralPath $output -File).Count -ne 11) { throw 'Normal format lost handoff files.' }
        $script:cases++
    }
    Assert-Rejected $valid @{ MaximumArchiveBytes = (Get-Item -LiteralPath $valid).Length - 1 }
    Assert-Rejected $valid @{ MaximumEntryBytes = 3 }
    Assert-Rejected $valid @{ MaximumExpandedBytes = 43 }
    Assert-Rejected $valid @{ MaximumEntryBytes = 268435457 }
    foreach ($bad in @('LICENSE', 'license', '../LICENSE', '/LICENSE', 'sub/LICENSE', 'C:\LICENSE')) {
        $names = @(Get-CandidateHandoffNames)
        $names[0] = $bad
        Assert-Rejected (New-Fixture -Names $names)
    }
    foreach ($mutation in @('count', 'directory', 'encrypt', 'link', 'zip64', 'comment', 'method')) {
        $path = New-Fixture
        $size = [int](Get-Item -LiteralPath $path).Length
        $central = Get-ZipDirectoryOffset $path
        switch ($mutation) {
            count { Set-ZipField $path ($size - 12) ([BitConverter]::GetBytes([uint16]12)) }
            directory { Set-ZipField $path ($size - 10) ([BitConverter]::GetBytes([uint32]32769)) }
            encrypt { Set-ZipField $path ($central + 8) ([BitConverter]::GetBytes([uint16]1)) }
            link { Set-ZipField $path ($central + 38) ([BitConverter]::GetBytes([Convert]::ToUInt32('a1ff0000', 16))) }
            zip64 { Set-ZipField $path ($central + 24) ([BitConverter]::GetBytes([uint32]::MaxValue)) }
            comment { Set-ZipField $path ($central + 32) ([BitConverter]::GetBytes([uint16]1025)) }
            method { Set-ZipField $path ($central + 10) ([BitConverter]::GetBytes([uint16]99)) }
        }
        Assert-Rejected $path
    }
    # Actual DEFLATE output must be counted even when both headers lie about its size.
    foreach ($declared in @(3, 5)) {
        $path = New-Fixture -Descriptor
        $central = Get-ZipDirectoryOffset $path
        Set-ZipField $path 22 ([BitConverter]::GetBytes([uint32]$declared))
        Set-ZipField $path ($central + 24) ([BitConverter]::GetBytes([uint32]$declared))
        Assert-Rejected $path @{ MaximumEntryBytes = 5; MaximumExpandedBytes = 55 } -Partial
    }
    # A ZIP64 extra tag is forbidden even when all ordinary sizes are non-sentinel.
    $path = New-Fixture
    $data = [IO.File]::ReadAllBytes($path)
    $central = Get-ZipDirectoryOffset $path
    $insert = $central + 46 + [BitConverter]::ToUInt16($data, $central + 28)
    $changed = [IO.MemoryStream]::new()
    try {
        $changed.Write($data, 0, $insert)
        $changed.Write([byte[]]@(1, 0, 0, 0), 0, 4)
        $changed.Write($data, $insert, $data.Length - $insert)
        [IO.File]::WriteAllBytes($path, $changed.ToArray())
    }
    finally { $changed.Dispose() }
    Set-ZipField $path ($central + 30) ([BitConverter]::GetBytes([uint16]4))
    $newLength = [int](Get-Item -LiteralPath $path).Length
    $oldDirectorySize = [BitConverter]::ToUInt32($data, $data.Length - 10)
    Set-ZipField $path ($newLength - 10) ([BitConverter]::GetBytes([uint32]($oldDirectorySize + 4)))
    Assert-Rejected $path
    $path = New-Fixture
    $data = [IO.File]::ReadAllBytes($path)
    [IO.File]::WriteAllBytes($path, $data[0..($data.Length - 10)])
    Assert-Rejected $path
    $existing = Join-Path $root 'existing'
    $null = New-Item -ItemType Directory -Path $existing
    $marker = Join-Path $existing 'keep.txt'
    [IO.File]::WriteAllText($marker, 'preserve')
    $rejected = $false
    try { Expand-BoundedCandidateArchive $valid $existing } catch { $rejected = $true }
    if (-not $rejected -or [IO.File]::ReadAllText($marker) -cne 'preserve') {
        throw 'Preexisting destinations must be refused without altering their files.'
    }
    $script:cases++
    Write-Host "Bounded candidate archive tests passed ($script:cases cases)."
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }
