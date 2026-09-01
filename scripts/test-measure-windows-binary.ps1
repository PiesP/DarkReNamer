[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$measurer = Join-Path $PSScriptRoot 'measure-windows-binary.ps1'
if (-not (Test-Path -LiteralPath $measurer -PathType Leaf)) {
    throw "Windows binary measurer is missing: $measurer"
}

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

function Assert-MeasurerFails {
    param(
        [Parameter(Mandatory)][string] $ExpectedFragment,
        [Parameter(Mandatory)][string] $ExecutablePath,
        [Parameter(Mandatory)][string] $PdbPath,
        [Parameter(Mandatory)][string] $SymbolsPath,
        [Parameter(Mandatory)][string] $OutputPath
    )
    try {
        & $measurer `
            -ExecutablePath $ExecutablePath `
            -PdbPath $PdbPath `
            -DebugSymbolsZipPath $SymbolsPath `
            -OutputPath $OutputPath
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedFragment*") {
            throw "Expected measurer failure containing '$ExpectedFragment', got: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected measurer failure containing '$ExpectedFragment', but measurement succeeded."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-binary-measurement-$([Guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $executable = Join-Path $testRoot 'DarkReNamer.exe'
    $pdb = Join-Path $testRoot 'DarkReNamer.pdb'
    $symbols = Join-Path $testRoot 'DarkReNamer-debug-symbols.zip'
    $output = Join-Path $testRoot 'measurement.json'
    Write-Bytes -Path $executable -Bytes (New-PeFixture)
    Write-Bytes -Path $pdb -Bytes (New-PdbFixture)
    Compress-Archive -LiteralPath $pdb -DestinationPath $symbols

    & $measurer `
        -ExecutablePath $executable `
        -PdbPath $pdb `
        -DebugSymbolsZipPath $symbols `
        -OutputPath $output
    $measurement = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    $outputBytes = [IO.File]::ReadAllBytes($output)
    $expectedExecutableHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedPdbHash = (Get-FileHash -LiteralPath $pdb -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedSymbolsHash = (Get-FileHash -LiteralPath $symbols -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($measurement.schema_version -ne 1 -or
        $measurement.executable.filename -cne 'DarkReNamer.exe' -or
        $measurement.executable.bytes -ne 0x500 -or
        $measurement.executable.sha256 -cne $expectedExecutableHash -or
        $measurement.pe.format -cne 'pe32-plus' -or
        $measurement.pe.machine -cne 'x86_64' -or
        $measurement.pe.subsystem -cne 'windows-gui' -or
        $measurement.pe.text_raw_bytes -ne 0x200 -or
        $measurement.pe.text_virtual_bytes -ne 0x180 -or
        @($measurement.pe.sections).Count -ne 2 -or
        $measurement.pe.sections[0].name -cne '.text' -or
        $measurement.pe.sections[0].raw_bytes -ne 0x200 -or
        $measurement.pe.sections[1].name -cne '.rdata' -or
        $measurement.pe.sections[1].raw_bytes -ne 0x100 -or
        $measurement.debug_symbols.guid -cne '4f7eddc7-cf33-b9e9-4c4c-44205044422e' -or
        $measurement.debug_symbols.age -ne 1 -or
        $measurement.debug_symbols.pdb_bytes -ne 0xa00 -or
        $measurement.debug_symbols.pdb_sha256 -cne $expectedPdbHash -or
        $measurement.debug_symbols.zip_sha256 -cne $expectedSymbolsHash -or
        $measurement.debug_symbols.zip_bytes -le 0 -or
        $outputBytes[0] -eq 0xef -or
        $outputBytes[$outputBytes.Length - 1] -ne 0x0a) {
        throw 'Measured fixture fields do not match the exact PE and symbol inputs.'
    }

    Assert-MeasurerFails `
        -ExpectedFragment 'OutputPath already exists' `
        -ExecutablePath $executable -PdbPath $pdb -SymbolsPath $symbols -OutputPath $output

    $badMz = Join-Path $testRoot 'bad-mz.exe'
    $badMzBytes = New-PeFixture
    $badMzBytes[0] = 0
    Write-Bytes -Path $badMz -Bytes $badMzBytes
    Assert-MeasurerFails `
        -ExpectedFragment 'MZ header' `
        -ExecutablePath $badMz -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'bad-mz.json')

    $wrongMachine = Join-Path $testRoot 'wrong-machine.exe'
    $wrongMachineBytes = New-PeFixture
    Set-UInt16LittleEndian -Bytes $wrongMachineBytes -Offset 0x84 -Value 0x14c
    Write-Bytes -Path $wrongMachine -Bytes $wrongMachineBytes
    Assert-MeasurerFails `
        -ExpectedFragment 'machine must be x86_64' `
        -ExecutablePath $wrongMachine -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'wrong-machine.json')

    $wrongMagic = Join-Path $testRoot 'wrong-magic.exe'
    $wrongMagicBytes = New-PeFixture
    Set-UInt16LittleEndian -Bytes $wrongMagicBytes -Offset 0x98 -Value 0x10b
    Write-Bytes -Path $wrongMagic -Bytes $wrongMagicBytes
    Assert-MeasurerFails `
        -ExpectedFragment 'optional header must be PE32+' `
        -ExecutablePath $wrongMagic -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'wrong-magic.json')

    $shortOptional = Join-Path $testRoot 'short-optional.exe'
    $shortOptionalBytes = New-PeFixture
    Set-UInt16LittleEndian -Bytes $shortOptionalBytes -Offset 0x94 -Value 100
    Write-Bytes -Path $shortOptional -Bytes $shortOptionalBytes
    Assert-MeasurerFails `
        -ExpectedFragment 'too small for the fixed PE32+ fields' `
        -ExecutablePath $shortOptional -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'short-optional.json')

    $wrongSubsystem = Join-Path $testRoot 'wrong-subsystem.exe'
    $wrongSubsystemBytes = New-PeFixture
    Set-UInt16LittleEndian -Bytes $wrongSubsystemBytes -Offset 0xdc -Value 3
    Write-Bytes -Path $wrongSubsystem -Bytes $wrongSubsystemBytes
    Assert-MeasurerFails `
        -ExpectedFragment 'subsystem must be Windows GUI' `
        -ExecutablePath $wrongSubsystem -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'wrong-subsystem.json')

    $virtualTailDebug = Join-Path $testRoot 'virtual-tail-debug.exe'
    $baseVirtualTailBytes = New-PeFixture
    $virtualTailBytes = [byte[]]::new(0x600)
    [Array]::Copy($baseVirtualTailBytes, 0, $virtualTailBytes, 0, $baseVirtualTailBytes.Length)
    Set-UInt32LittleEndian -Bytes $virtualTailBytes -Offset (0x1b0 + 8) -Value 0x200
    Set-UInt32LittleEndian -Bytes $virtualTailBytes -Offset 0x138 -Value 0x2100
    Write-Bytes -Path $virtualTailDebug -Bytes $virtualTailBytes
    Assert-MeasurerFails `
        -ExpectedFragment 'debug directory is not backed by executable section data' `
        -ExecutablePath $virtualTailDebug -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'virtual-tail-debug.json')

    $duplicateText = Join-Path $testRoot 'duplicate-text.exe'
    $duplicateTextBytes = New-PeFixture
    [Array]::Clear($duplicateTextBytes, 0x1b0, 8)
    Set-Section -Bytes $duplicateTextBytes -Offset 0x1b0 -Name '.text' -VirtualBytes 0x100 -VirtualAddress 0x2000 -RawBytes 0x100 -RawOffset 0x400
    Write-Bytes -Path $duplicateText -Bytes $duplicateTextBytes
    Assert-MeasurerFails `
        -ExpectedFragment 'section names must be unique' `
        -ExecutablePath $duplicateText -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'duplicate-text.json')

    $missingText = Join-Path $testRoot 'missing-text.exe'
    $missingTextBytes = New-PeFixture
    [Array]::Clear($missingTextBytes, 0x188, 8)
    Set-Section -Bytes $missingTextBytes -Offset 0x188 -Name '.code' -VirtualBytes 0x180 -VirtualAddress 0x1000 -RawBytes 0x200 -RawOffset 0x200
    Write-Bytes -Path $missingText -Bytes $missingTextBytes
    Assert-MeasurerFails `
        -ExpectedFragment 'exactly one .text section' `
        -ExecutablePath $missingText -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'missing-text.json')

    $emptyText = Join-Path $testRoot 'empty-text.exe'
    $emptyTextBytes = New-PeFixture
    Set-UInt32LittleEndian -Bytes $emptyTextBytes -Offset (0x188 + 16) -Value 0
    Set-UInt32LittleEndian -Bytes $emptyTextBytes -Offset (0x188 + 20) -Value 0
    Write-Bytes -Path $emptyText -Bytes $emptyTextBytes
    Assert-MeasurerFails `
        -ExpectedFragment '.text section must contain raw data' `
        -ExecutablePath $emptyText -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'empty-text.json')

    $rawOverrun = Join-Path $testRoot 'raw-overrun.exe'
    $rawOverrunBytes = New-PeFixture
    Set-UInt32LittleEndian -Bytes $rawOverrunBytes -Offset (0x188 + 16) -Value 0x400
    Write-Bytes -Path $rawOverrun -Bytes $rawOverrunBytes
    Assert-MeasurerFails `
        -ExpectedFragment 'raw data is outside' `
        -ExecutablePath $rawOverrun -PdbPath $pdb -SymbolsPath $symbols `
        -OutputPath (Join-Path $testRoot 'raw-overrun.json')

    $differentPdb = Join-Path $testRoot 'different.pdb'
    $differentSymbols = Join-Path $testRoot 'different-symbols.zip'
    Write-Bytes `
        -Path $differentPdb `
        -Bytes (New-PdbFixture -Guid ([Guid]'11111111-2222-3333-4444-555555555555'))
    Compress-Archive -LiteralPath $differentPdb -DestinationPath $differentSymbols
    Assert-MeasurerFails `
        -ExpectedFragment 'PDB GUID and age do not match' `
        -ExecutablePath $executable -PdbPath $differentPdb -SymbolsPath $differentSymbols `
        -OutputPath (Join-Path $testRoot 'different-pdb.json')
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Windows binary measurement tests passed.'
