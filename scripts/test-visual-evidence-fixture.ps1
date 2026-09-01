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
        [Parameter(Mandatory)][byte[]] $Data
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
        [Parameter(Mandatory)][string] $Marker
    )
    $base = [Convert]::FromBase64String(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
    )
    $iendOffset = $base.Length - 12
    $prefix = [byte[]] $base[0..($iendOffset - 1)]
    $iend = [byte[]] $base[$iendOffset..($base.Length - 1)]
    $text = [byte[]] (
        [Text.Encoding]::ASCII.GetBytes('Comment') +
        [byte] 0 +
        [Text.Encoding]::UTF8.GetBytes($Marker)
    )
    $chunk = New-VisualFixturePngChunk -Type 'tEXt' -Data $text
    [IO.File]::WriteAllBytes($Path, [byte[]] ($prefix + $chunk + $iend))
}
