Set-StrictMode -Version Latest

function Set-UInt16LittleEndian {
    param([byte[]] $Bytes, [int] $Offset, [uint16] $Value)
    $encoded = [BitConverter]::GetBytes($Value)
    [Array]::Copy($encoded, 0, $Bytes, $Offset, 2)
}

function Set-UInt32LittleEndian {
    param([byte[]] $Bytes, [int] $Offset, [uint32] $Value)
    $encoded = [BitConverter]::GetBytes($Value)
    [Array]::Copy($encoded, 0, $Bytes, $Offset, 4)
}

function Set-Section {
    param(
        [byte[]] $Bytes,
        [int] $Offset,
        [string] $Name,
        [uint32] $VirtualBytes,
        [uint32] $VirtualAddress,
        [uint32] $RawBytes,
        [uint32] $RawOffset
    )
    $encoded = [Text.Encoding]::ASCII.GetBytes($Name)
    [Array]::Copy($encoded, 0, $Bytes, $Offset, $encoded.Length)
    Set-UInt32LittleEndian -Bytes $Bytes -Offset ($Offset + 8) -Value $VirtualBytes
    Set-UInt32LittleEndian -Bytes $Bytes -Offset ($Offset + 12) -Value $VirtualAddress
    Set-UInt32LittleEndian -Bytes $Bytes -Offset ($Offset + 16) -Value $RawBytes
    Set-UInt32LittleEndian -Bytes $Bytes -Offset ($Offset + 20) -Value $RawOffset
}

function New-PeFixture {
    $bytes = [byte[]]::new(0x500)
    $bytes[0] = 0x4d
    $bytes[1] = 0x5a
    Set-UInt32LittleEndian -Bytes $bytes -Offset 0x3c -Value 0x80
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    Set-UInt16LittleEndian -Bytes $bytes -Offset 0x84 -Value 0x8664
    Set-UInt16LittleEndian -Bytes $bytes -Offset 0x86 -Value 2
    Set-UInt16LittleEndian -Bytes $bytes -Offset 0x94 -Value 0xf0
    Set-UInt16LittleEndian -Bytes $bytes -Offset 0x98 -Value 0x20b
    Set-UInt16LittleEndian -Bytes $bytes -Offset 0xdc -Value 2
    Set-UInt32LittleEndian -Bytes $bytes -Offset 0x104 -Value 16
    Set-UInt32LittleEndian -Bytes $bytes -Offset 0x138 -Value 0x2000
    Set-UInt32LittleEndian -Bytes $bytes -Offset 0x13c -Value 28
    Set-Section -Bytes $bytes -Offset 0x188 -Name '.text' -VirtualBytes 0x180 -VirtualAddress 0x1000 -RawBytes 0x200 -RawOffset 0x200
    Set-Section -Bytes $bytes -Offset 0x1b0 -Name '.rdata' -VirtualBytes 0x100 -VirtualAddress 0x2000 -RawBytes 0x100 -RawOffset 0x400
    Set-UInt32LittleEndian -Bytes $bytes -Offset 0x40c -Value 2
    Set-UInt32LittleEndian -Bytes $bytes -Offset 0x410 -Value 0x40
    Set-UInt32LittleEndian -Bytes $bytes -Offset 0x414 -Value 0x2020
    Set-UInt32LittleEndian -Bytes $bytes -Offset 0x418 -Value 0x420
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('RSDS'), 0, $bytes, 0x420, 4)
    $guidBytes = ([Guid]'4f7eddc7-cf33-b9e9-4c4c-44205044422e').ToByteArray()
    [Array]::Copy($guidBytes, 0, $bytes, 0x424, 16)
    Set-UInt32LittleEndian -Bytes $bytes -Offset 0x434 -Value 1
    $pdbName = [Text.Encoding]::UTF8.GetBytes("DarkReNamer.pdb`0")
    [Array]::Copy($pdbName, 0, $bytes, 0x438, $pdbName.Length)
    return ,$bytes
}

function New-PdbFixture {
    param(
        [Guid] $Guid = [Guid]'4f7eddc7-cf33-b9e9-4c4c-44205044422e',
        [uint32] $Age = 1
    )
    $blockSize = 0x200
    $bytes = [byte[]]::new($blockSize * 5)
    $magic = [Text.Encoding]::ASCII.GetBytes("Microsoft C/C++ MSF 7.00`r`n`u{1a}DS`0`0`0")
    [Array]::Copy($magic, 0, $bytes, 0, $magic.Length)
    Set-UInt32LittleEndian -Bytes $bytes -Offset 32 -Value $blockSize
    Set-UInt32LittleEndian -Bytes $bytes -Offset 36 -Value 1
    Set-UInt32LittleEndian -Bytes $bytes -Offset 40 -Value 5
    Set-UInt32LittleEndian -Bytes $bytes -Offset 44 -Value 16
    Set-UInt32LittleEndian -Bytes $bytes -Offset 48 -Value 0
    Set-UInt32LittleEndian -Bytes $bytes -Offset 52 -Value 1
    Set-UInt32LittleEndian -Bytes $bytes -Offset $blockSize -Value 2
    $directoryOffset = $blockSize * 2
    Set-UInt32LittleEndian -Bytes $bytes -Offset $directoryOffset -Value 2
    Set-UInt32LittleEndian -Bytes $bytes -Offset ($directoryOffset + 4) -Value ([uint32]::MaxValue)
    Set-UInt32LittleEndian -Bytes $bytes -Offset ($directoryOffset + 8) -Value 28
    Set-UInt32LittleEndian -Bytes $bytes -Offset ($directoryOffset + 12) -Value 3
    $infoOffset = $blockSize * 3
    Set-UInt32LittleEndian -Bytes $bytes -Offset $infoOffset -Value 20000404
    Set-UInt32LittleEndian -Bytes $bytes -Offset ($infoOffset + 4) -Value 123456789
    Set-UInt32LittleEndian -Bytes $bytes -Offset ($infoOffset + 8) -Value $Age
    $guidBytes = $Guid.ToByteArray()
    [Array]::Copy($guidBytes, 0, $bytes, $infoOffset + 12, 16)
    return ,$bytes
}

function Write-Bytes {
    param([string] $Path, [byte[]] $Bytes)
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function Write-WindowsBinaryFixture {
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'Windows binary fixture root must identify an existing directory.'
    }
    $executablePath = Join-Path $Root 'DarkReNamer.exe'
    $pdbPath = Join-Path $Root 'DarkReNamer.pdb'
    if ((Test-Path -LiteralPath $executablePath) -or (Test-Path -LiteralPath $pdbPath)) {
        throw 'Windows binary fixture never overwrites an existing EXE or PDB.'
    }
    Write-Bytes -Path $executablePath -Bytes (New-PeFixture)
    Write-Bytes -Path $pdbPath -Bytes (New-PdbFixture)
    [pscustomobject][ordered]@{
        executable_path = $executablePath
        pdb_path = $pdbPath
        text_raw_bytes = 0x200
        pdb_bytes = 0xa00
    }
}
