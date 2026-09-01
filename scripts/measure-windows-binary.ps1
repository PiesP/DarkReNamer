[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ExecutablePath,
    [Parameter(Mandatory)]
    [string] $PdbPath,
    [Parameter(Mandatory)]
    [string] $DebugSymbolsZipPath,
    [Parameter(Mandatory)]
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.4') {
    throw 'Windows binary measurement requires PowerShell 7.4 or newer (pwsh).'
}

$maximumPeBytes = 268435456
$maximumPdbBytes = 134217728
$maximumSymbolsZipBytes = 134217728

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label must identify an existing file: $Path"
    }
    (Resolve-Path -LiteralPath $Path).Path
}

function Read-UInt16LittleEndian {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,
        [Parameter(Mandatory)]
        [long] $Offset,
        [Parameter(Mandatory)]
        [string] $Location
    )

    if ($Offset -lt 0 -or $Offset + 2 -gt $Bytes.LongLength) {
        throw "$Location is outside the executable."
    }
    [BitConverter]::ToUInt16($Bytes, [int] $Offset)
}

function Read-UInt32LittleEndian {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,
        [Parameter(Mandatory)]
        [long] $Offset,
        [Parameter(Mandatory)]
        [string] $Location
    )

    if ($Offset -lt 0 -or $Offset + 4 -gt $Bytes.LongLength) {
        throw "$Location is outside the executable."
    }
    [BitConverter]::ToUInt32($Bytes, [int] $Offset)
}

function Get-SectionName {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,
        [Parameter(Mandatory)]
        [long] $Offset
    )

    if ($Offset -lt 0 -or $Offset + 8 -gt $Bytes.LongLength) {
        throw 'A PE section name is outside the executable.'
    }
    $nameBytes = [Collections.Generic.List[byte]]::new(8)
    foreach ($index in 0..7) {
        $value = $Bytes[[int] ($Offset + $index)]
        if ($value -eq 0) {
            break
        }
        if ($value -lt 0x21 -or $value -gt 0x7e) {
            throw 'A PE section name contains unsupported bytes.'
        }
        $nameBytes.Add($value)
    }
    if ($nameBytes.Count -eq 0) {
        throw 'A PE section name is empty.'
    }
    [Text.Encoding]::ASCII.GetString($nameBytes.ToArray())
}

function Get-PdbIdentity {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $pdbBytes = [IO.File]::ReadAllBytes($Path)
    $magic = [Text.Encoding]::ASCII.GetBytes("Microsoft C/C++ MSF 7.00`r`n`u{1a}DS`0`0`0")
    if ($pdbBytes.LongLength -lt 56 -or $magic.Length -ne 32) {
        throw 'PDB is too small for an MSF 7.00 superblock.'
    }
    for ($index = 0; $index -lt $magic.Length; $index++) {
        if ($pdbBytes[$index] -ne $magic[$index]) {
            throw 'PDB must use the MSF 7.00 container format.'
        }
    }

    $blockSize = [long] (Read-UInt32LittleEndian -Bytes $pdbBytes -Offset 32 -Location 'PDB block size')
    if ($blockSize -lt 512 -or $blockSize -gt 65536 -or ($blockSize -band ($blockSize - 1)) -ne 0) {
        throw 'PDB block size must be a power of two from 512 through 65536.'
    }
    $blockCount = [long] (Read-UInt32LittleEndian -Bytes $pdbBytes -Offset 40 -Location 'PDB block count')
    $directoryBytes = [long] (Read-UInt32LittleEndian -Bytes $pdbBytes -Offset 44 -Location 'PDB directory size')
    $blockMapIndex = [long] (Read-UInt32LittleEndian -Bytes $pdbBytes -Offset 52 -Location 'PDB block-map index')
    if ($blockCount -le 0 -or $blockCount * $blockSize -gt $pdbBytes.LongLength) {
        throw 'PDB block count exceeds the file length.'
    }
    if ($directoryBytes -lt 4 -or $directoryBytes -gt 67108864) {
        throw 'PDB stream directory size is invalid or exceeds 64 MiB.'
    }
    $directoryBlockCount = [long] [Math]::Ceiling($directoryBytes / [double] $blockSize)
    $blockMapOffset = $blockMapIndex * $blockSize
    if ($blockMapIndex -ge $blockCount -or
        $blockMapOffset + ($directoryBlockCount * 4) -gt $pdbBytes.LongLength) {
        throw 'PDB stream-directory block map exceeds the file length.'
    }

    $directory = [byte[]]::new([int] $directoryBytes)
    $directoryWritten = 0
    foreach ($index in 0..([int] $directoryBlockCount - 1)) {
        $blockIndex = [long] (Read-UInt32LittleEndian `
            -Bytes $pdbBytes `
            -Offset ($blockMapOffset + ([long] $index * 4)) `
            -Location 'PDB stream-directory block index')
        if ($blockIndex -ge $blockCount) {
            throw 'PDB stream-directory block index exceeds the block count.'
        }
        $copyCount = [Math]::Min([int] $blockSize, $directory.Length - $directoryWritten)
        [Array]::Copy(
            $pdbBytes,
            [int] ($blockIndex * $blockSize),
            $directory,
            $directoryWritten,
            $copyCount
        )
        $directoryWritten += $copyCount
    }

    $streamCount = [long] (Read-UInt32LittleEndian -Bytes $directory -Offset 0 -Location 'PDB stream count')
    if ($streamCount -lt 2 -or $streamCount -gt 1048576) {
        throw 'PDB must contain an Info stream at index 1.'
    }
    $sizeTableEnd = 4 + ($streamCount * 4)
    if ($sizeTableEnd -gt $directory.LongLength) {
        throw 'PDB stream-size table exceeds the stream directory.'
    }
    $streamSizes = [Collections.Generic.List[long]]::new([int] $streamCount)
    foreach ($index in 0..([int] $streamCount - 1)) {
        $size = [long] (Read-UInt32LittleEndian `
            -Bytes $directory `
            -Offset (4 + ([long] $index * 4)) `
            -Location 'PDB stream size')
        $streamSizes.Add($size)
    }
    $infoSize = $streamSizes[1]
    if ($infoSize -eq [uint32]::MaxValue -or $infoSize -lt 28 -or $infoSize -gt 67108864) {
        throw 'PDB Info stream size is invalid.'
    }

    $blockCursor = $sizeTableEnd
    $infoBlocks = $null
    foreach ($streamIndex in 0..([int] $streamCount - 1)) {
        $streamSize = $streamSizes[$streamIndex]
        $streamBlockCount = if ($streamSize -eq [uint32]::MaxValue -or $streamSize -eq 0) {
            0
        }
        else {
            [long] [Math]::Ceiling($streamSize / [double] $blockSize)
        }
        $blockListBytes = $streamBlockCount * 4
        if ($blockCursor + $blockListBytes -gt $directory.LongLength) {
            throw 'PDB stream block list exceeds the stream directory.'
        }
        if ($streamIndex -eq 1) {
            $infoBlocks = [long[]]::new([int] $streamBlockCount)
            foreach ($blockIndexPosition in 0..([int] $streamBlockCount - 1)) {
                $infoBlocks[$blockIndexPosition] = [long] (Read-UInt32LittleEndian `
                    -Bytes $directory `
                    -Offset ($blockCursor + ([long] $blockIndexPosition * 4)) `
                    -Location 'PDB Info stream block index')
            }
        }
        $blockCursor += $blockListBytes
    }
    if ($null -eq $infoBlocks -or $infoBlocks.Length -eq 0) {
        throw 'PDB Info stream has no blocks.'
    }

    $info = [byte[]]::new([int] $infoSize)
    $infoWritten = 0
    foreach ($blockIndex in $infoBlocks) {
        if ($blockIndex -ge $blockCount) {
            throw 'PDB Info stream block index exceeds the block count.'
        }
        $copyCount = [Math]::Min([int] $blockSize, $info.Length - $infoWritten)
        [Array]::Copy(
            $pdbBytes,
            [int] ($blockIndex * $blockSize),
            $info,
            $infoWritten,
            $copyCount
        )
        $infoWritten += $copyCount
    }
    $age = [long] (Read-UInt32LittleEndian -Bytes $info -Offset 8 -Location 'PDB Info age')
    $guidBytes = [byte[]]::new(16)
    [Array]::Copy($info, 12, $guidBytes, 0, 16)
    [pscustomobject][ordered]@{
        guid = ([Guid]::new($guidBytes)).ToString('D').ToLowerInvariant()
        age = $age
    }
}

$resolvedExecutable = Resolve-RequiredFile -Path $ExecutablePath -Label 'ExecutablePath'
$resolvedPdb = Resolve-RequiredFile -Path $PdbPath -Label 'PdbPath'
$resolvedSymbols = Resolve-RequiredFile -Path $DebugSymbolsZipPath -Label 'DebugSymbolsZipPath'
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$outputParent = Split-Path -Parent $resolvedOutput
if ([string]::IsNullOrEmpty($outputParent) -or
    -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw 'OutputPath parent directory must already exist.'
}
if (Test-Path -LiteralPath $resolvedOutput) {
    throw 'OutputPath already exists; binary measurement never overwrites a destination.'
}
foreach ($input in $resolvedExecutable, $resolvedPdb, $resolvedSymbols) {
    if ([string]::Equals($input, $resolvedOutput, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputPath must differ from every input path.'
    }
}

$executableInfo = Get-Item -LiteralPath $resolvedExecutable
if ($executableInfo.Length -le 0 -or $executableInfo.Length -gt $maximumPeBytes) {
    throw "Executable size must be from 1 through $maximumPeBytes bytes."
}
$bytes = [IO.File]::ReadAllBytes($resolvedExecutable)
if ($bytes.LongLength -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
    throw 'Executable must begin with an MZ header.'
}

$peOffset = [long] (Read-UInt32LittleEndian -Bytes $bytes -Offset 0x3c -Location 'DOS e_lfanew')
if ($peOffset + 24 -gt $bytes.LongLength) {
    throw 'The PE header is outside the executable.'
}
if ($bytes[[int] $peOffset] -ne 0x50 -or
    $bytes[[int] ($peOffset + 1)] -ne 0x45 -or
    $bytes[[int] ($peOffset + 2)] -ne 0 -or
    $bytes[[int] ($peOffset + 3)] -ne 0) {
    throw 'Executable does not contain a valid PE signature.'
}

$machine = Read-UInt16LittleEndian -Bytes $bytes -Offset ($peOffset + 4) -Location 'COFF machine'
if ($machine -ne 0x8664) {
    throw 'Executable machine must be x86_64 (0x8664).'
}
$sectionCount = [int] (Read-UInt16LittleEndian -Bytes $bytes -Offset ($peOffset + 6) -Location 'COFF section count')
if ($sectionCount -le 0 -or $sectionCount -gt 96) {
    throw 'PE section count must be from 1 through 96.'
}
$optionalHeaderSize = [long] (Read-UInt16LittleEndian -Bytes $bytes -Offset ($peOffset + 20) -Location 'COFF optional-header size')
if ($optionalHeaderSize -lt 112) {
    throw 'PE optional header is too small for the fixed PE32+ fields.'
}
$optionalHeaderOffset = $peOffset + 24
if ($optionalHeaderOffset + $optionalHeaderSize -gt $bytes.LongLength) {
    throw 'The PE optional header is outside the executable.'
}
$optionalMagic = Read-UInt16LittleEndian -Bytes $bytes -Offset $optionalHeaderOffset -Location 'PE optional-header magic'
if ($optionalMagic -ne 0x20b) {
    throw 'Executable optional header must be PE32+ (0x20b).'
}
$subsystem = Read-UInt16LittleEndian -Bytes $bytes -Offset ($optionalHeaderOffset + 68) -Location 'PE subsystem'
if ($subsystem -ne 2) {
    throw 'Executable subsystem must be Windows GUI (2).'
}

$sectionTableOffset = $optionalHeaderOffset + $optionalHeaderSize
$sectionTableBytes = [long] $sectionCount * 40
if ($sectionTableOffset + $sectionTableBytes -gt $bytes.LongLength) {
    throw 'The PE section table is outside the executable.'
}
$observedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$sections = [Collections.Generic.List[object]]::new($sectionCount)
$sectionRecords = [Collections.Generic.List[object]]::new($sectionCount)
foreach ($index in 0..($sectionCount - 1)) {
    $offset = $sectionTableOffset + ([long] $index * 40)
    $name = Get-SectionName -Bytes $bytes -Offset $offset
    if (-not $observedNames.Add($name)) {
        throw "PE section names must be unique; duplicate: $name"
    }
    $virtualBytes = [long] (Read-UInt32LittleEndian -Bytes $bytes -Offset ($offset + 8) -Location "PE section $name virtual size")
    $virtualAddress = [long] (Read-UInt32LittleEndian -Bytes $bytes -Offset ($offset + 12) -Location "PE section $name virtual address")
    $rawBytes = [long] (Read-UInt32LittleEndian -Bytes $bytes -Offset ($offset + 16) -Location "PE section $name raw size")
    $rawOffset = [long] (Read-UInt32LittleEndian -Bytes $bytes -Offset ($offset + 20) -Location "PE section $name raw offset")
    if ($rawBytes -gt 0 -and ($rawOffset -le 0 -or $rawOffset + $rawBytes -gt $bytes.LongLength)) {
        throw "PE section $name raw data is outside the executable."
    }
    $sections.Add([pscustomobject][ordered]@{
        name = $name
        virtual_bytes = $virtualBytes
        raw_bytes = $rawBytes
    })
    $sectionRecords.Add([pscustomobject]@{
        name = $name
        virtual_bytes = $virtualBytes
        virtual_address = $virtualAddress
        raw_bytes = $rawBytes
        raw_offset = $rawOffset
    })
}
$textSections = @($sections | Where-Object name -ceq '.text')
if ($textSections.Count -ne 1) {
    throw "Executable must contain exactly one .text section; observed $($textSections.Count)."
}
if ($textSections[0].raw_bytes -le 0) {
    throw 'Executable .text section must contain raw data.'
}

$dataDirectoryCount = [long] (Read-UInt32LittleEndian `
    -Bytes $bytes `
    -Offset ($optionalHeaderOffset + 108) `
    -Location 'PE data-directory count')
if ($dataDirectoryCount -lt 7 -or $optionalHeaderSize -lt 168) {
    throw 'Executable must contain a PE debug data-directory entry.'
}
$debugDirectoryRva = [long] (Read-UInt32LittleEndian `
    -Bytes $bytes `
    -Offset ($optionalHeaderOffset + 160) `
    -Location 'PE debug-directory RVA')
$debugDirectoryBytes = [long] (Read-UInt32LittleEndian `
    -Bytes $bytes `
    -Offset ($optionalHeaderOffset + 164) `
    -Location 'PE debug-directory size')
if ($debugDirectoryRva -le 0 -or $debugDirectoryBytes -lt 28 -or $debugDirectoryBytes % 28 -ne 0) {
    throw 'PE debug directory must contain complete entries.'
}
$debugDirectoryOffset = $null
foreach ($section in $sectionRecords) {
    $mappedBytes = [Math]::Max($section.virtual_bytes, $section.raw_bytes)
    if ($debugDirectoryRva -ge $section.virtual_address -and
        $debugDirectoryRva + $debugDirectoryBytes -le $section.virtual_address + $mappedBytes) {
        $sectionDelta = $debugDirectoryRva - $section.virtual_address
        $candidateOffset = $section.raw_offset + $sectionDelta
        if ($sectionDelta + $debugDirectoryBytes -le $section.raw_bytes -and
            $candidateOffset + $debugDirectoryBytes -le $bytes.LongLength) {
            $debugDirectoryOffset = $candidateOffset
            break
        }
    }
}
if ($null -eq $debugDirectoryOffset) {
    throw 'PE debug directory is not backed by executable section data.'
}
$codeViewIdentities = [Collections.Generic.List[object]]::new()
foreach ($index in 0..([int] ($debugDirectoryBytes / 28) - 1)) {
    $entryOffset = [long] $debugDirectoryOffset + ([long] $index * 28)
    $type = Read-UInt32LittleEndian -Bytes $bytes -Offset ($entryOffset + 12) -Location 'PE debug-directory type'
    if ($type -ne 2) {
        continue
    }
    $dataBytes = [long] (Read-UInt32LittleEndian -Bytes $bytes -Offset ($entryOffset + 16) -Location 'PE CodeView size')
    $dataOffset = [long] (Read-UInt32LittleEndian -Bytes $bytes -Offset ($entryOffset + 24) -Location 'PE CodeView file offset')
    if ($dataBytes -lt 24 -or $dataOffset -le 0 -or $dataOffset + $dataBytes -gt $bytes.LongLength) {
        throw 'PE CodeView record is outside the executable.'
    }
    if ($bytes[[int] $dataOffset] -ne 0x52 -or
        $bytes[[int] ($dataOffset + 1)] -ne 0x53 -or
        $bytes[[int] ($dataOffset + 2)] -ne 0x44 -or
        $bytes[[int] ($dataOffset + 3)] -ne 0x53) {
        throw 'PE CodeView record must use the RSDS format.'
    }
    $guidBytes = [byte[]]::new(16)
    [Array]::Copy($bytes, [int] ($dataOffset + 4), $guidBytes, 0, 16)
    $codeViewIdentities.Add([pscustomobject][ordered]@{
        guid = ([Guid]::new($guidBytes)).ToString('D').ToLowerInvariant()
        age = [long] (Read-UInt32LittleEndian -Bytes $bytes -Offset ($dataOffset + 20) -Location 'PE CodeView age')
    })
}
if ($codeViewIdentities.Count -ne 1) {
    throw "Executable must contain exactly one RSDS CodeView identity; observed $($codeViewIdentities.Count)."
}

$pdbInfo = Get-Item -LiteralPath $resolvedPdb
$symbolsInfo = Get-Item -LiteralPath $resolvedSymbols
if ($pdbInfo.Length -le 0) {
    throw 'PdbPath must not be empty.'
}
if ($pdbInfo.Length -gt $maximumPdbBytes) {
    throw "PdbPath must not exceed $maximumPdbBytes bytes."
}
if ($symbolsInfo.Length -le 0) {
    throw 'DebugSymbolsZipPath must not be empty.'
}
if ($symbolsInfo.Length -gt $maximumSymbolsZipBytes) {
    throw "DebugSymbolsZipPath must not exceed $maximumSymbolsZipBytes bytes."
}
$pdbHash = (Get-FileHash -LiteralPath $resolvedPdb -Algorithm SHA256).Hash.ToLowerInvariant()
$pdbIdentity = Get-PdbIdentity -Path $resolvedPdb
if ($pdbIdentity.guid -cne $codeViewIdentities[0].guid -or
    $pdbIdentity.age -ne $codeViewIdentities[0].age) {
    throw 'PDB GUID and age do not match the executable CodeView identity.'
}
$archive = [IO.Compression.ZipFile]::OpenRead($resolvedSymbols)
try {
    $entries = @($archive.Entries)
    if ($entries.Count -ne 1 -or $entries[0].FullName -cne 'DarkReNamer.pdb') {
        throw 'Debug-symbol archive must contain exactly DarkReNamer.pdb at its root.'
    }
    if ($entries[0].Length -ne $pdbInfo.Length) {
        throw 'Debug-symbol archive PDB length does not match PdbPath.'
    }
    $entryStream = $entries[0].Open()
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $entryHashBytes = $sha256.ComputeHash($entryStream)
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $entryStream.Dispose()
    }
}
finally {
    $archive.Dispose()
}
$entryHash = [Convert]::ToHexString($entryHashBytes).ToLowerInvariant()
if ($entryHash -cne $pdbHash) {
    throw 'Debug-symbol archive does not contain the PdbPath bytes.'
}

$measurement = [pscustomobject][ordered]@{
    schema_version = 1
    executable = [pscustomobject][ordered]@{
        filename = $executableInfo.Name
        sha256 = (Get-FileHash -LiteralPath $resolvedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = $executableInfo.Length
    }
    pe = [pscustomobject][ordered]@{
        format = 'pe32-plus'
        machine = 'x86_64'
        subsystem = 'windows-gui'
        text_raw_bytes = $textSections[0].raw_bytes
        text_virtual_bytes = $textSections[0].virtual_bytes
        sections = $sections.ToArray()
    }
    debug_symbols = [pscustomobject][ordered]@{
        guid = $pdbIdentity.guid
        age = $pdbIdentity.age
        pdb_sha256 = $pdbHash
        pdb_bytes = $pdbInfo.Length
        zip_sha256 = (Get-FileHash -LiteralPath $resolvedSymbols -Algorithm SHA256).Hash.ToLowerInvariant()
        zip_bytes = $symbolsInfo.Length
    }
}

$stream = $null
$writer = $null
try {
    $stream = [IO.File]::Open(
        $resolvedOutput,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    $stream = $null
    $writer.Write(($measurement | ConvertTo-Json -Depth 8) + "`n")
    $writer.Flush()
}
finally {
    if ($null -ne $writer) {
        $writer.Dispose()
    }
    elseif ($null -ne $stream) {
        $stream.Dispose()
    }
}

Write-Host "Measured x64 Windows GUI binary at $resolvedExecutable."
