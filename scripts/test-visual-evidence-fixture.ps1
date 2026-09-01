function Get-VisualFixtureCrc32 {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    [uint32] $crc = [Convert]::ToUInt32('FFFFFFFF', 16)
    [uint32] $polynomial = [Convert]::ToUInt32('EDB88320', 16)
    foreach ($byte in $Bytes) {
        $crc = [uint32] ($crc -bxor [uint32] $byte)
        foreach ($bit in 0..7) {
            if (($crc -band 1) -ne 0) {
                $crc = [uint32] ($polynomial -bxor ($crc -shr 1))
            }
            else {
                $crc = [uint32] ($crc -shr 1)
            }
        }
    }
    return [uint32] ($crc -bxor [Convert]::ToUInt32('FFFFFFFF', 16))
}

function ConvertTo-VisualFixtureBigEndian {
    param([Parameter(Mandatory)][uint32] $Value)
    return [byte[]] @(
        [byte] (($Value -shr 24) -band 0xff),
        [byte] (($Value -shr 16) -band 0xff),
        [byte] (($Value -shr 8) -band 0xff),
        [byte] ($Value -band 0xff)
    )
}

function New-VisualFixturePngChunk {
    param(
        [Parameter(Mandatory)][string] $Type,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Data
    )
    if ($Type.Length -ne 4) {
        throw 'PNG fixture chunk type must contain four ASCII characters.'
    }
    $typeBytes = [Text.Encoding]::ASCII.GetBytes($Type)
    $crc = Get-VisualFixtureCrc32 -Bytes ([byte[]] ($typeBytes + $Data))
    return [byte[]] (
        (ConvertTo-VisualFixtureBigEndian -Value ([uint32] $Data.Length)) +
        $typeBytes +
        $Data +
        (ConvertTo-VisualFixtureBigEndian -Value $crc)
    )
}

function Write-VisualPngFixture {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Marker,
        [Parameter(Mandatory)][int] $Width,
        [Parameter(Mandatory)][int] $Height,
        [Parameter(Mandatory)][ValidateRange(1, 255)][int] $Seed,
        [switch] $Solid,
        [switch] $Transparent,
        [switch] $TruecolorTransparency,
        [ValidateRange(0, 255)][int] $OpaquePrefixPixels = 0
    )
    if ($Width -lt 1 -or $Height -lt 1) {
        throw 'PNG fixture dimensions must be positive.'
    }
    if ($TruecolorTransparency -and ($Transparent -or $OpaquePrefixPixels -gt 0)) {
        throw 'Truecolor transparency cannot be combined with alpha-channel fixture modes.'
    }
    $colorType = if ($TruecolorTransparency) { 2 } else { 6 }
    $bytesPerPixel = if ($TruecolorTransparency) { 3 } else { 4 }
    $header = [byte[]] (
        (ConvertTo-VisualFixtureBigEndian -Value ([uint32] $Width)) +
        (ConvertTo-VisualFixtureBigEndian -Value ([uint32] $Height)) +
        [byte[]](8, $colorType, 0, 0, 0)
    )
    $colors = if ($TruecolorTransparency) {
        @(
            [byte[]]($Seed, 17, 33),
            [byte[]]($Seed, 97, 53),
            [byte[]]($Seed, 43, 173),
            [byte[]]($Seed, 211, 199)
        )
    }
    else {
        @(
            [byte[]]($Seed, 17, 33, 255),
            [byte[]]($Seed, 97, 53, 255),
            [byte[]]($Seed, 43, 173, 255),
            [byte[]]($Seed, 211, 199, 255)
        )
    }
    if ($Solid) {
        $colors = @($colors[0], $colors[0], $colors[0], $colors[0])
    }
    if ($Transparent) {
        foreach ($color in $colors) {
            $color[3] = 0
        }
    }
    $rows = @(
        [byte[]]::new(1 + ($Width * $bytesPerPixel)),
        [byte[]]::new(1 + ($Width * $bytesPerPixel))
    )
    foreach ($rowIndex in 0, 1) {
        for ($x = 0; $x -lt $Width; $x++) {
            $color = $colors[($rowIndex * 2) + [int]($x -ge [math]::Ceiling($Width / 2))]
            [Array]::Copy(
                $color,
                0,
                $rows[$rowIndex],
                1 + ($x * $bytesPerPixel),
                $bytesPerPixel
            )
        }
    }
    if ($OpaquePrefixPixels -gt 0) {
        $prefixRow = [byte[]]::new(1 + ($Width * 4))
        $transparentRow = [byte[]]::new(1 + ($Width * 4))
        for ($x = 0; $x -lt $Width; $x++) {
            $offset = 1 + ($x * 4)
            if ($x -lt $OpaquePrefixPixels) {
                $prefixRow[$offset] = [byte] $x
                $prefixRow[$offset + 1] = [byte] (($x * 3) -band 0xff)
                $prefixRow[$offset + 2] = [byte] (($x * 7) -band 0xff)
                $prefixRow[$offset + 3] = 255
            }
            else {
                $prefixRow[$offset] = [byte] $Seed
            }
            $transparentRow[$offset] = [byte] $Seed
        }
        $rows = @($prefixRow, $transparentRow)
    }
    $compressed = [IO.MemoryStream]::new()
    $encoder = [IO.Compression.ZLibStream]::new(
        $compressed,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    try {
        for ($y = 0; $y -lt $Height; $y++) {
            $rowIndex = if ($OpaquePrefixPixels -gt 0) {
                [int] ($y -ne 0)
            }
            else {
                [int] ($y -ge [math]::Ceiling($Height / 2))
            }
            $row = $rows[$rowIndex]
            $encoder.Write($row, 0, $row.Length)
        }
    }
    finally {
        $encoder.Dispose()
    }
    $text = [byte[]] (
        [Text.Encoding]::ASCII.GetBytes('Comment') +
        [byte] 0 +
        [Text.Encoding]::UTF8.GetBytes($Marker)
    )
    $signature = [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
    $transparencyChunk = if ($TruecolorTransparency) {
        New-VisualFixturePngChunk `
            -Type 'tRNS' `
            -Data ([byte[]](0, $Seed, 0, 17, 0, 33))
    }
    else {
        [byte[]]::new(0)
    }
    [IO.File]::WriteAllBytes(
        $Path,
        [byte[]] (
            $signature +
            (New-VisualFixturePngChunk -Type 'IHDR' -Data $header) +
            (New-VisualFixturePngChunk -Type 'tEXt' -Data $text) +
            $transparencyChunk +
            (New-VisualFixturePngChunk -Type 'IDAT' -Data $compressed.ToArray()) +
            (New-VisualFixturePngChunk -Type 'IEND' -Data ([byte[]]::new(0)))
        )
    )
    $compressed.Dispose()
}
