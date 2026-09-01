[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Path')]
    [string] $EvidencePath,

    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [AllowEmptyString()]
    [string] $EvidenceJson,

    [string] $VisualEvidenceRoot,

    [switch] $Draft,

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version] '7.4') {
    throw 'Windows acceptance evidence validation requires PowerShell 7.4 or newer (pwsh).'
}

function Test-Property {
    param(
        [Parameter(Mandatory)]
        [object] $Object,
        [Parameter(Mandatory)]
        [string] $Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-ObjectShape {
    param(
        [Parameter(Mandatory)]
        [object] $Object,
        [Parameter(Mandatory)]
        [string[]] $Required,
        [string[]] $Optional = @(),
        [Parameter(Mandatory)]
        [string] $Location
    )

    if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
        throw "$Location must be a JSON object."
    }

    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @($Required) + @($Optional)) {
        [void] $allowed.Add($name)
    }
    foreach ($property in $Object.PSObject.Properties) {
        if (-not $allowed.Contains($property.Name)) {
            throw "$Location contains an unsupported field: $($property.Name)."
        }
    }
    foreach ($name in $Required) {
        if (-not (Test-Property -Object $Object -Name $name) -or $null -eq $Object.$name) {
            throw "$Location is missing required field: $name."
        }
    }
}

function Assert-UniqueJsonProperties {
    param([Text.Json.JsonElement] $Element, [string] $Location)
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $observed.Add($property.Name)) {
                throw "$Location contains a duplicate field: $($property.Name)."
            }
            Assert-UniqueJsonProperties -Element $property.Value -Location "$Location.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-UniqueJsonProperties -Element $item -Location "$Location[$index]"
            $index++
        }
    }
}

function Assert-String {
    param(
        [AllowEmptyString()]
        [object] $Value,
        [Parameter(Mandatory)]
        [string] $Location,
        [int] $MaximumLength = 2000
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Location must be a non-empty string."
    }
    if ($Value.Length -gt $MaximumLength) {
        throw "$Location exceeds the $MaximumLength character limit."
    }
}

function Assert-Enum {
    param(
        [object] $Value,
        [Parameter(Mandatory)]
        [object[]] $Allowed,
        [Parameter(Mandatory)]
        [string] $Location
    )

    $matched = $false
    foreach ($candidate in $Allowed) {
        if ($Value -is [string] -and $candidate -is [string]) {
            if ([string]::Equals($Value, $candidate, [StringComparison]::Ordinal)) {
                $matched = $true
                break
            }
            continue
        }
        $valueIsNumber = $Value -is [byte] -or $Value -is [sbyte] -or
            $Value -is [int16] -or $Value -is [uint16] -or
            $Value -is [int32] -or $Value -is [uint32] -or
            $Value -is [int64] -or $Value -is [uint64] -or
            $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
        $candidateIsNumber = $candidate -is [byte] -or $candidate -is [sbyte] -or
            $candidate -is [int16] -or $candidate -is [uint16] -or
            $candidate -is [int32] -or $candidate -is [uint32] -or
            $candidate -is [int64] -or $candidate -is [uint64] -or
            $candidate -is [single] -or $candidate -is [double] -or $candidate -is [decimal]
        if ($valueIsNumber -and $candidateIsNumber -and [decimal] $Value -eq [decimal] $candidate) {
            $matched = $true
            break
        }
    }
    if (-not $matched) {
        throw "$Location must be one of: $($Allowed -join ', ')."
    }
}

function Assert-ObservationCode {
    param(
        [Parameter(Mandatory)]
        [string] $Status,
        [Parameter(Mandatory)]
        [string] $Code,
        [Parameter(Mandatory)]
        [hashtable] $Codes,
        [Parameter(Mandatory)]
        [string] $Location
    )

    $expected = $Codes[$Status]
    if (-not [string]::Equals($Code, $expected, [StringComparison]::Ordinal)) {
        throw "$Location must be $expected when status is $Status."
    }
}

function Assert-NonNegativeNumber {
    param(
        [object] $Value,
        [Parameter(Mandatory)]
        [string] $Location
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        throw "$Location must be a non-negative number."
    }
    try {
        $number = [double] $Value
    }
    catch {
        throw "$Location must be a non-negative number."
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) {
        throw "$Location must be a non-negative number."
    }
}

function Assert-Privacy {
    param(
        [AllowNull()]
        [object] $Value,
        [Parameter(Mandatory)]
        [string] $Location
    )

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match '^(?i:user(?:_?name)?|operator_?name|account(?:_?name)?|owner(?:_?name)?|host(?:_?name)?|computer_?name|machine_?name|volume_?serial(?:_?number)?)$') {
                throw "$Location contains a prohibited identity or volume field: $($property.Name)."
            }
            Assert-Privacy -Value $property.Value -Location "$Location.$($property.Name)"
        }
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            Assert-Privacy -Value $Value[$key] -Location "$Location.$key"
        }
        return
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $index = 0
        foreach ($item in $Value) {
            Assert-Privacy -Value $item -Location "$Location[$index]"
            $index++
        }
        return
    }
    if ($Value -isnot [string]) {
        return
    }

    $pathPatterns = @(
        '(?i)(?:^|[\s"''(])(?:[a-z]:[\\/])',
        '(?:^|[\s"''(])\\\\[^\\/\s]+[\\/]',
        '(?i)\bfile:(?://|\\\\)',
        '(?i)(?:^|[\s"''(])/(?:home|users)/[^/\s]+(?:/|$)',
        '(?i)(?:^|[\s"''(])/root(?:/|$)',
        '(?i)(?:%USERPROFILE%|\$\{?HOME\}?|\$env:USERPROFILE|~[\\/])'
    )
    foreach ($pattern in $pathPatterns) {
        if ($Value -match $pattern) {
            throw "$Location contains a prohibited absolute or profile path."
        }
    }
    if ($Value -match '(?i)\b(?:user(?:name)?|host(?:name)?|computer(?:name)?|machine(?:name)?|volume\s*serial(?:\s*number)?)\s*[:=]\s*\S+') {
        throw "$Location contains prohibited identity or volume-serial data."
    }
    $ipv4Octet = '(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    if ($Value -match "(?<![0-9])$ipv4Octet(?:\.$ipv4Octet){3}(?![0-9])") {
        throw "$Location contains a prohibited IP address."
    }
}

function Resolve-VisualEvidenceRoot {
    param([string] $Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'VisualEvidenceRoot must identify an existing directory.'
    }
    foreach ($start in [IO.Path]::GetFullPath($Root), (Resolve-Path -LiteralPath $Root).Path) {
        $currentPath = $start
        while ($null -ne $currentPath) {
            $current = Get-Item -LiteralPath $currentPath -Force
            if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq
                [IO.FileAttributes]::ReparsePoint) {
                throw 'VisualEvidenceRoot and its ancestor chain must not contain reparse points.'
            }
            $parent = [IO.Directory]::GetParent($currentPath)
            $currentPath = if ($null -eq $parent) { $null } else { $parent.FullName }
        }
    }
    $resolved = (Resolve-Path -LiteralPath $Root).Path
    $resolvedItem = Get-Item -LiteralPath $resolved -Force
    if (($resolvedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq
            [IO.FileAttributes]::ReparsePoint) {
        throw 'VisualEvidenceRoot must not resolve to a reparse point.'
    }
    return $resolved
}

if ($null -eq ('DarkReNamerAcceptance.StrictPngValidator' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace DarkReNamerAcceptance
{
    public sealed class PngDimensions
    {
        public uint Width { get; private set; }
        public uint Height { get; private set; }
        public string RasterSha256 { get; private set; }
        public int DistinctColors { get; private set; }

        public PngDimensions(uint width, uint height, string rasterSha256, int distinctColors)
        {
            Width = width;
            Height = height;
            RasterSha256 = rasterSha256;
            DistinctColors = distinctColors;
        }
    }

    public static class StrictPngValidator
    {
        private const long MaximumEncodedBytes = 64L * 1024L * 1024L;
        private const long MaximumDecodedBytes = 256L * 1024L * 1024L;
        private const int MaximumChunkBytes = 16 * 1024 * 1024;
        private static readonly byte[] Signature =
            { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
        private static readonly uint[] CrcTable = BuildCrcTable();

        public static PngDimensions Validate(string path)
        {
            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                4096,
                FileOptions.SequentialScan))
            {
                if (stream.Length < 57 || stream.Length > MaximumEncodedBytes)
                    throw new InvalidDataException("PNG encoded size is outside the 57-byte through 64-MiB limit.");

                byte[] signature = ReadExactly(stream, Signature.Length);
                for (int index = 0; index < Signature.Length; index++)
                    if (signature[index] != Signature[index])
                        throw new InvalidDataException("PNG signature is invalid.");

                bool seenHeader = false;
                bool seenData = false;
                bool endedData = false;
                bool seenEnd = false;
                int chunkCount = 0;
                uint width = 0;
                uint height = 0;
                int bytesPerPixel = 0;
                int colorType = -1;
                byte[] headerData = null;
                using (MemoryStream compressed = new MemoryStream())
                {
                    while (stream.Position < stream.Length)
                    {
                        chunkCount++;
                        if (chunkCount > 4096)
                            throw new InvalidDataException("PNG contains more than 4096 chunks.");
                        uint declaredLength = ReadBigEndianUInt32(ReadExactly(stream, 4), 0);
                        if (declaredLength > MaximumChunkBytes ||
                            declaredLength > stream.Length - stream.Position - 8)
                            throw new InvalidDataException("PNG chunk length is invalid or exceeds 16 MiB.");
                        int length = checked((int)declaredLength);
                        byte[] typeBytes = ReadExactly(stream, 4);
                        string type = Encoding.ASCII.GetString(typeBytes);
                        byte[] data = ReadExactly(stream, length);
                        uint storedCrc = ReadBigEndianUInt32(ReadExactly(stream, 4), 0);
                        if (ComputeCrc(typeBytes, data) != storedCrc)
                            throw new InvalidDataException("PNG chunk CRC is invalid.");

                        if (!seenHeader && type != "IHDR")
                            throw new InvalidDataException("PNG IHDR must be the first chunk.");
                        if (type == "IHDR")
                        {
                            if (seenHeader || length != 13)
                                throw new InvalidDataException("PNG must contain one 13-byte IHDR chunk.");
                            width = ReadBigEndianUInt32(data, 0);
                            height = ReadBigEndianUInt32(data, 4);
                            if (width == 0 || height == 0 || width > 16384 || height > 16384)
                                throw new InvalidDataException("PNG dimensions are outside the supported range.");
                            if (data[8] != 8 || data[10] != 0 || data[11] != 0 || data[12] != 0)
                                throw new InvalidDataException("PNG must be non-interlaced 8-bit lossless data.");
                            colorType = data[9];
                            switch (colorType)
                            {
                                case 0: bytesPerPixel = 1; break;
                                case 2: bytesPerPixel = 3; break;
                                case 4: bytesPerPixel = 2; break;
                                case 6: bytesPerPixel = 4; break;
                                default: throw new InvalidDataException("PNG color type is unsupported.");
                            }
                            seenHeader = true;
                            headerData = data;
                        }
                        else if (type == "IDAT")
                        {
                            if (!seenHeader || endedData)
                                throw new InvalidDataException("PNG IDAT chunks must be consecutive after IHDR.");
                            if (compressed.Length + length > MaximumEncodedBytes)
                                throw new InvalidDataException("PNG compressed image data exceeds 64 MiB.");
                            compressed.Write(data, 0, data.Length);
                            seenData = true;
                        }
                        else if (type == "IEND")
                        {
                            if (!seenData || length != 0 || seenEnd)
                                throw new InvalidDataException("PNG IEND is missing, duplicated, or malformed.");
                            seenEnd = true;
                            if (stream.Position != stream.Length)
                                throw new InvalidDataException("PNG contains trailing bytes after IEND.");
                            break;
                        }
                        else
                        {
                            if (seenData) endedData = true;
                            if ((typeBytes[0] & 0x20) == 0)
                                throw new InvalidDataException("PNG contains an unsupported critical chunk.");
                        }
                    }

                    if (!seenHeader || !seenData || !seenEnd)
                        throw new InvalidDataException("PNG is missing IHDR, IDAT, or IEND.");

                    long rowBytes = checked((long)width * bytesPerPixel);
                    long decodedBytes = checked((rowBytes + 1L) * height);
                    if (decodedBytes > MaximumDecodedBytes)
                        throw new InvalidDataException("PNG decoded data exceeds 256 MiB.");
                    int rowLength = checked((int)rowBytes);
                    byte[] filtered = new byte[rowLength + 1];
                    byte[] row = new byte[rowLength];
                    byte[] previousRow = new byte[rowLength];
                    HashSet<uint> colors = new HashSet<uint>();
                    compressed.Position = 0;
                    using (IncrementalHash rasterHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
                    using (ZLibStream decoder = new ZLibStream(compressed, CompressionMode.Decompress, true))
                    {
                        rasterHash.AppendData(headerData);
                        for (uint y = 0; y < height; y++)
                        {
                            ReadExactly(decoder, filtered, 0, filtered.Length);
                            if (filtered[0] > 4)
                                throw new InvalidDataException("PNG scanline uses an invalid filter.");
                            Unfilter(filtered[0], filtered, row, previousRow, bytesPerPixel);
                            rasterHash.AppendData(row);
                            if (colors.Count <= 64)
                            {
                                for (int offset = 0; offset < row.Length; offset += bytesPerPixel)
                                {
                                    if ((colorType == 4 && row[offset + 1] != 255) ||
                                        (colorType == 6 && row[offset + 3] != 255))
                                        throw new InvalidDataException("PNG screenshot pixels must be fully opaque.");
                                    uint color = 0;
                                    for (int channel = 0; channel < bytesPerPixel; channel++)
                                        color = (color << 8) | row[offset + channel];
                                    colors.Add(color);
                                    if (colors.Count > 64) break;
                                }
                            }
                            byte[] swap = previousRow;
                            previousRow = row;
                            row = swap;
                        }
                        if (decoder.ReadByte() != -1)
                            throw new InvalidDataException("PNG decoded data exceeds the IHDR dimensions.");
                        string rasterSha = Convert.ToHexString(rasterHash.GetHashAndReset()).ToLowerInvariant();
                        return new PngDimensions(width, height, rasterSha, colors.Count);
                    }
                }
            }
        }

        private static void Unfilter(
            byte filter,
            byte[] filtered,
            byte[] row,
            byte[] previous,
            int bytesPerPixel)
        {
            for (int index = 0; index < row.Length; index++)
            {
                int left = index >= bytesPerPixel ? row[index - bytesPerPixel] : 0;
                int up = previous[index];
                int upperLeft = index >= bytesPerPixel ? previous[index - bytesPerPixel] : 0;
                int predictor;
                switch (filter)
                {
                    case 0: predictor = 0; break;
                    case 1: predictor = left; break;
                    case 2: predictor = up; break;
                    case 3: predictor = (left + up) / 2; break;
                    case 4: predictor = Paeth(left, up, upperLeft); break;
                    default: throw new InvalidDataException("PNG scanline uses an invalid filter.");
                }
                row[index] = unchecked((byte)(filtered[index + 1] + predictor));
            }
        }

        private static int Paeth(int left, int up, int upperLeft)
        {
            int estimate = left + up - upperLeft;
            int leftDistance = Math.Abs(estimate - left);
            int upDistance = Math.Abs(estimate - up);
            int upperLeftDistance = Math.Abs(estimate - upperLeft);
            if (leftDistance <= upDistance && leftDistance <= upperLeftDistance) return left;
            return upDistance <= upperLeftDistance ? up : upperLeft;
        }

        private static byte[] ReadExactly(Stream stream, int count)
        {
            byte[] buffer = new byte[count];
            ReadExactly(stream, buffer, 0, count);
            return buffer;
        }

        private static void ReadExactly(Stream stream, byte[] buffer, int offset, int count)
        {
            int total = 0;
            while (total < count)
            {
                int read = stream.Read(buffer, offset + total, count - total);
                if (read == 0) throw new EndOfStreamException("PNG ended before the declared data was available.");
                total += read;
            }
        }

        private static uint ReadBigEndianUInt32(byte[] bytes, int offset)
        {
            return ((uint)bytes[offset] << 24) |
                   ((uint)bytes[offset + 1] << 16) |
                   ((uint)bytes[offset + 2] << 8) |
                   bytes[offset + 3];
        }

        private static uint ComputeCrc(byte[] type, byte[] data)
        {
            uint crc = 0xffffffffu;
            for (int index = 0; index < type.Length; index++)
                crc = CrcTable[(crc ^ type[index]) & 0xff] ^ (crc >> 8);
            for (int index = 0; index < data.Length; index++)
                crc = CrcTable[(crc ^ data[index]) & 0xff] ^ (crc >> 8);
            return crc ^ 0xffffffffu;
        }

        private static uint[] BuildCrcTable()
        {
            uint[] table = new uint[256];
            for (uint value = 0; value < table.Length; value++)
            {
                uint crc = value;
                for (int bit = 0; bit < 8; bit++)
                    crc = (crc & 1) != 0 ? 0xedb88320u ^ (crc >> 1) : crc >> 1;
                table[value] = crc;
            }
            return table;
        }
    }
}
'@
}

function Get-PngDimensions {
    param([Parameter(Mandatory)][string] $Path)
    try {
        $dimensions = [DarkReNamerAcceptance.StrictPngValidator]::Validate($Path)
    }
    catch {
        $detail = if ($null -ne $_.Exception.InnerException) {
            $_.Exception.InnerException.Message
        }
        else {
            $_.Exception.Message
        }
        throw "Visual capture is not a bounded decodable PNG: $detail"
    }
    return [pscustomobject]@{
        width = [uint64] $dimensions.Width
        height = [uint64] $dimensions.Height
        raster_sha256 = $dimensions.RasterSha256
        distinct_colors = $dimensions.DistinctColors
    }
}

function Get-UiTarget {
    param($Row)
    return "ui|$($Row.windows_product)|$($Row.dpi_percent)|$($Row.contrast)"
}

function Get-ScenarioTarget {
    param($Row)
    return "scenario|$($Row.windows_product)|$($Row.kind)"
}

function Get-BenchmarkTarget {
    param($Row)
    return "benchmark|$($Row.media)|$($Row.count)"
}

function Get-DurabilityTarget {
    param($Row)
    return "durability|$($Row.kind)"
}

$schemaPath = Join-Path $PSScriptRoot 'windows-acceptance-evidence.schema.json'
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Windows acceptance evidence schema is missing: $schemaPath"
}
$schemaDocument = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
if ($schemaDocument.'$schema' -ne 'https://json-schema.org/draft/2020-12/schema') {
    throw 'Windows acceptance evidence schema must declare JSON Schema 2020-12.'
}
$expectedSchemaVersion = $schemaDocument.properties.schema_version.const
$schemaDefinitions = $schemaDocument.'$defs'
$resolvedVisualEvidenceRoot = Resolve-VisualEvidenceRoot -Root $VisualEvidenceRoot
if (-not $Draft -and $null -eq $resolvedVisualEvidenceRoot) {
    throw 'Complete evidence validation requires VisualEvidenceRoot.'
}

if ($PSCmdlet.ParameterSetName -eq 'Path') {
    if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
        throw "Evidence file does not exist: $EvidencePath"
    }
    $evidenceJson = Get-Content -LiteralPath $EvidencePath -Raw
}
try {
    $jsonDocument = [Text.Json.JsonDocument]::Parse($evidenceJson)
    try {
        if ($jsonDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'Evidence root must be a JSON object.'
        }
        Assert-UniqueJsonProperties -Element $jsonDocument.RootElement -Location 'evidence'
        $recordedAtElement = [Text.Json.JsonElement]::new()
        if (-not $jsonDocument.RootElement.TryGetProperty('recorded_at_utc', [ref] $recordedAtElement) -or
            $recordedAtElement.ValueKind -ne [Text.Json.JsonValueKind]::String) {
            throw 'recorded_at_utc must be a JSON string.'
        }
        $recordedAtUtc = $recordedAtElement.GetString()
    }
    finally {
        $jsonDocument.Dispose()
    }
    $evidence = $evidenceJson | ConvertFrom-Json
}
catch {
    throw "Evidence is not valid JSON: $($_.Exception.Message)"
}

Assert-ObjectShape `
    -Object $evidence `
    -Required @(
        'schema_version', 'source_sha', 'artifact', 'recorded_at_utc',
        'operator_context', 'ui_matrix', 'visual_captures', 'scenarios', 'benchmarks',
        'durability_trials', 'unexecuted'
    ) `
    -Location 'evidence'
Assert-Privacy -Value $evidence -Location 'evidence'

if ($evidence.schema_version -is [string] -or [decimal] $evidence.schema_version -ne [decimal] $expectedSchemaVersion) {
    throw "schema_version must be $expectedSchemaVersion."
}
if ($evidence.source_sha -isnot [string] -or $evidence.source_sha -cnotmatch $schemaDocument.properties.source_sha.pattern) {
    throw 'source_sha must be a full lowercase 40-character Git SHA.'
}
if ($recordedAtUtc -cnotmatch $schemaDocument.properties.recorded_at_utc.pattern) {
    throw 'recorded_at_utc must use UTC form YYYY-MM-DDTHH:mm:ssZ.'
}
$parsedTimestamp = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParseExact(
        $recordedAtUtc,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref] $parsedTimestamp
    )) {
    throw 'recorded_at_utc is not a valid UTC timestamp.'
}

$artifact = $evidence.artifact
Assert-ObjectShape -Object $artifact -Required @('filename', 'sha256', 'origin') -Optional @('workflow_run') -Location 'artifact'
if ($artifact.filename -isnot [string] -or $artifact.filename -cnotmatch $schemaDefinitions.artifact.properties.filename.pattern) {
    throw 'artifact.filename must be a filename only, without a path.'
}
if ($artifact.sha256 -isnot [string] -or $artifact.sha256 -cnotmatch $schemaDefinitions.artifact.properties.sha256.pattern) {
    throw 'artifact.sha256 must be a lowercase 64-character SHA-256 digest.'
}
Assert-Enum -Value $artifact.origin -Allowed @($schemaDefinitions.artifact.properties.origin.enum) -Location 'artifact.origin'
if ($artifact.origin -eq 'actions-handoff') {
    if (-not (Test-Property -Object $artifact -Name 'workflow_run') -or $artifact.workflow_run -isnot [string] -or $artifact.workflow_run -notmatch '^[1-9][0-9]*$') {
        throw 'artifact.workflow_run is required as a numeric run ID for actions-handoff evidence.'
    }
}
elseif (Test-Property -Object $artifact -Name 'workflow_run') {
    throw 'artifact.workflow_run is only allowed for actions-handoff evidence.'
}

$windowsProducts = @($schemaDefinitions.operatorContext.properties.windows_product.enum)
$dpiValues = @($schemaDefinitions.uiCell.properties.dpi_percent.enum)
$contrastValues = @($schemaDefinitions.uiCell.properties.contrast.enum)
$scenarioKinds = @($schemaDefinitions.scenario.properties.kind.enum)
$mediaKinds = @($schemaDefinitions.benchmark.properties.media.enum)
$filesystemKinds = @($schemaDefinitions.benchmark.properties.filesystem.enum)
$benchmarkCounts = @($schemaDefinitions.benchmark.properties.count.enum)
$durabilityKinds = @($schemaDefinitions.durabilityTrial.properties.kind.enum)
$statuses = @($schemaDefinitions.status.enum)

$expectedTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$expectedUiTargets = @(
    foreach ($product in $windowsProducts) {
        foreach ($dpi in $dpiValues) {
            foreach ($contrast in $contrastValues) {
                "ui|$product|$dpi|$contrast"
            }
        }
    }
)
$expectedScenarioTargets = @(
    foreach ($product in $windowsProducts) {
        foreach ($kind in $scenarioKinds) {
            "scenario|$product|$kind"
        }
    }
)
$expectedBenchmarkTargets = @(
    foreach ($media in $mediaKinds) {
        foreach ($count in $benchmarkCounts) {
            "benchmark|$media|$count"
        }
    }
)
$expectedDurabilityTargets = @($durabilityKinds | ForEach-Object { "durability|$_" })
foreach ($target in $expectedUiTargets + $expectedScenarioTargets + $expectedBenchmarkTargets + $expectedDurabilityTargets) {
    [void] $expectedTargets.Add($target)
}

$unexecutedById = @{}
$unexecutedByTarget = @{}
foreach ($item in @($evidence.unexecuted)) {
    $location = "unexecuted[$($unexecutedById.Count)]"
    Assert-ObjectShape -Object $item -Required @('id', 'target', 'reason_code') -Location $location
    if ($item.id -isnot [string] -or $item.id -cnotmatch $schemaDefinitions.unexecuted.properties.id.pattern) {
        throw "$location.id must be a lowercase stable identifier."
    }
    Assert-String -Value $item.target -Location "$location.target" -MaximumLength 200
    Assert-Enum -Value $item.reason_code -Allowed @($schemaDefinitions.unexecuted.properties.reason_code.enum) -Location "$location.reason_code"
    if (-not $expectedTargets.Contains($item.target)) {
        throw "$location.target does not identify a required acceptance target: $($item.target)."
    }
    if ($unexecutedById.ContainsKey($item.id)) {
        throw "Duplicate unexecuted id: $($item.id)."
    }
    if ($unexecutedByTarget.ContainsKey($item.target)) {
        throw "Duplicate unexecuted target: $($item.target)."
    }
    $unexecutedById[$item.id] = $item
    $unexecutedByTarget[$item.target] = $item
}
$usedUnexecutedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

function Assert-NotRunReference {
    param(
        [Parameter(Mandatory)]
        [object] $Row,
        [Parameter(Mandatory)]
        [string] $Target,
        [Parameter(Mandatory)]
        [string] $Location
    )

    if ($Row.status -eq 'not-run') {
        if (-not (Test-Property -Object $Row -Name 'unexecuted_id')) {
            throw "$Location with status not-run must reference unexecuted_id."
        }
        if (-not $unexecutedById.ContainsKey($Row.unexecuted_id)) {
            throw "$Location references an unknown unexecuted_id: $($Row.unexecuted_id)."
        }
        $reason = $unexecutedById[$Row.unexecuted_id]
        if ($reason.target -ne $Target) {
            throw "$Location unexecuted_id targets $($reason.target), expected $Target."
        }
        [void] $usedUnexecutedIds.Add($Row.unexecuted_id)
    }
    elseif (Test-Property -Object $Row -Name 'unexecuted_id') {
        throw "$Location may reference unexecuted_id only when status is not-run."
    }
}

$contextsByProduct = @{}
$contextIndex = 0
foreach ($context in @($evidence.operator_context)) {
    $location = "operator_context[$contextIndex]"
    Assert-ObjectShape -Object $context -Required @('windows_product', 'windows_build', 'architecture') -Location $location
    Assert-Enum -Value $context.windows_product -Allowed $windowsProducts -Location "$location.windows_product"
    if ($context.windows_build -isnot [string] -or $context.windows_build -notmatch $schemaDefinitions.operatorContext.properties.windows_build.pattern) {
        throw "$location.windows_build must contain only numeric build components."
    }
    Assert-Enum -Value $context.architecture -Allowed @($schemaDefinitions.operatorContext.properties.architecture.enum) -Location "$location.architecture"
    if ($contextsByProduct.ContainsKey($context.windows_product)) {
        throw "Duplicate operator context for $($context.windows_product)."
    }
    $contextsByProduct[$context.windows_product] = $context
    $contextIndex++
}
if (-not $Draft) {
    foreach ($product in $windowsProducts) {
        if (-not $contextsByProduct.ContainsKey($product)) {
            throw "Complete evidence requires operator context for $product."
        }
    }
}

$hasExecutedRows = $false
$uiByTarget = @{}
$uiIndex = 0
foreach ($row in @($evidence.ui_matrix)) {
    $location = "ui_matrix[$uiIndex]"
    Assert-ObjectShape -Object $row -Required @('windows_product', 'dpi_percent', 'contrast', 'status', 'observation_code') -Optional @('unexecuted_id') -Location $location
    Assert-Enum -Value $row.windows_product -Allowed $windowsProducts -Location "$location.windows_product"
    Assert-Enum -Value $row.dpi_percent -Allowed $dpiValues -Location "$location.dpi_percent"
    Assert-Enum -Value $row.contrast -Allowed $contrastValues -Location "$location.contrast"
    Assert-Enum -Value $row.status -Allowed $statuses -Location "$location.status"
    Assert-Enum -Value $row.observation_code -Allowed @($schemaDefinitions.uiCell.properties.observation_code.enum) -Location "$location.observation_code"
    Assert-ObservationCode `
        -Status $row.status `
        -Code $row.observation_code `
        -Codes @{ pass = 'layout-verified'; fail = 'layout-defect'; 'not-run' = 'not-executed' } `
        -Location "$location.observation_code"
    if ($row.status -ne 'not-run') {
        $hasExecutedRows = $true
    }
    if ($row.status -ne 'not-run' -and
        $contextsByProduct.Count -gt 0 -and
        -not $contextsByProduct.ContainsKey($row.windows_product)) {
        throw "$location has no matching operator_context for $($row.windows_product)."
    }
    $target = Get-UiTarget $row
    if ($uiByTarget.ContainsKey($target)) {
        throw "Duplicate UI matrix cell: $target."
    }
    $uiByTarget[$target] = $row
    Assert-NotRunReference -Row $row -Target $target -Location $location
    $uiIndex++
}

$scenarioByTarget = @{}
$scenarioIndex = 0
foreach ($row in @($evidence.scenarios)) {
    $location = "scenarios[$scenarioIndex]"
    Assert-ObjectShape -Object $row -Required @('windows_product', 'kind', 'status', 'observation_code') -Optional @('accessibility_tool', 'unexecuted_id') -Location $location
    Assert-Enum -Value $row.windows_product -Allowed $windowsProducts -Location "$location.windows_product"
    Assert-Enum -Value $row.kind -Allowed $scenarioKinds -Location "$location.kind"
    Assert-Enum -Value $row.status -Allowed $statuses -Location "$location.status"
    Assert-Enum -Value $row.observation_code -Allowed @($schemaDefinitions.scenario.properties.observation_code.enum) -Location "$location.observation_code"
    Assert-ObservationCode `
        -Status $row.status `
        -Code $row.observation_code `
        -Codes @{ pass = 'interaction-verified'; fail = 'interaction-defect'; 'not-run' = 'not-executed' } `
        -Location "$location.observation_code"
    if ($row.status -ne 'not-run') {
        $hasExecutedRows = $true
    }
    if ($row.status -ne 'not-run' -and
        $contextsByProduct.Count -gt 0 -and
        -not $contextsByProduct.ContainsKey($row.windows_product)) {
        throw "$location has no matching operator_context for $($row.windows_product)."
    }
    $hasTool = Test-Property -Object $row -Name 'accessibility_tool'
    if ($row.kind -eq 'accessibility' -and $row.status -ne 'not-run') {
        if (-not $hasTool) {
            throw "$location requires accessibility_tool name and version."
        }
        Assert-ObjectShape -Object $row.accessibility_tool -Required @('name', 'version') -Location "$location.accessibility_tool"
        if ($row.accessibility_tool.name -isnot [string] -or
            $row.accessibility_tool.name -cnotmatch $schemaDefinitions.tool.properties.name.pattern) {
            throw "$location.accessibility_tool.name contains unsupported characters."
        }
        if ($row.accessibility_tool.version -isnot [string] -or
            $row.accessibility_tool.version -cnotmatch $schemaDefinitions.tool.properties.version.pattern) {
            throw "$location.accessibility_tool.version contains unsupported characters."
        }
    }
    elseif ($hasTool) {
        throw "$location may include accessibility_tool only for an executed accessibility scenario."
    }
    $target = Get-ScenarioTarget $row
    if ($scenarioByTarget.ContainsKey($target)) {
        throw "Duplicate scenario row: $target."
    }
    $scenarioByTarget[$target] = $row
    Assert-NotRunReference -Row $row -Target $target -Location $location
    $scenarioIndex++
}

$captureIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$captureFilenames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$captureHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$captureRasterHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$capturedMainTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$capturedNormalMainAppearances = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$capturedSurfaces = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$captureIndex = 0
foreach ($capture in @($evidence.visual_captures)) {
    $location = "visual_captures[$captureIndex]"
    Assert-ObjectShape `
        -Object $capture `
        -Required @('id', 'image', 'executable_sha256', 'ui_target', 'appearance', 'surface') `
        -Optional @('scenario_target') `
        -Location $location
    if ($capture.id -isnot [string] -or
        $capture.id -cnotmatch $schemaDefinitions.visualCapture.properties.id.pattern) {
        throw "$location.id must be a lowercase stable identifier."
    }
    if (-not $captureIds.Add($capture.id)) {
        throw "Duplicate visual capture id: $($capture.id)."
    }
    Assert-ObjectShape `
        -Object $capture.image `
        -Required @('filename', 'sha256', 'pixel_width', 'pixel_height') `
        -Location "$location.image"
    if ($capture.image.filename -isnot [string] -or
        $capture.image.filename -cnotmatch $schemaDefinitions.imageArtifact.properties.filename.pattern) {
        throw "$location.image.filename must be a filename only, without a path."
    }
    if ($capture.image.filename -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
        throw "$location.image.filename must not use a reserved Windows device name."
    }
    if (-not $captureFilenames.Add($capture.image.filename)) {
        throw "Duplicate visual capture filename: $($capture.image.filename)."
    }
    if ($capture.image.sha256 -isnot [string] -or
        $capture.image.sha256 -cnotmatch $schemaDefinitions.imageArtifact.properties.sha256.pattern) {
        throw "$location.image.sha256 must be a lowercase 64-character SHA-256 digest."
    }
    if (-not $captureHashes.Add($capture.image.sha256)) {
        throw "Duplicate visual capture image digest: $($capture.image.sha256)."
    }
    foreach ($dimension in 'pixel_width', 'pixel_height') {
        $value = $capture.image.$dimension
        if ($value -is [string] -or $value -is [bool] -or
            [decimal] $value -ne [decimal]::Truncate([decimal] $value) -or
            [decimal] $value -lt 1 -or [decimal] $value -gt 16384) {
            throw "$location.image.$dimension must be an integer from 1 through 16384."
        }
    }
    if (-not [string]::Equals(
            $capture.executable_sha256,
            $artifact.sha256,
            [StringComparison]::Ordinal
        )) {
        throw "$location.executable_sha256 must match artifact.sha256."
    }
    $uiTargetObserved = $uiByTarget.ContainsKey($capture.ui_target)
    $uiTargetStatus = if ($uiTargetObserved) { $uiByTarget[$capture.ui_target].status } else { '<missing>' }
    if ($expectedUiTargets -cnotcontains $capture.ui_target -or
        -not $uiTargetObserved -or
        $uiTargetStatus -ne 'pass') {
        throw "$location.ui_target must reference a passed UI matrix cell."
    }
    Assert-Enum `
        -Value $capture.appearance `
        -Allowed @($schemaDefinitions.visualCapture.properties.appearance.enum) `
        -Location "$location.appearance"
    Assert-Enum `
        -Value $capture.surface `
        -Allowed @($schemaDefinitions.visualCapture.properties.surface.enum) `
        -Location "$location.surface"
    $uiParts = $capture.ui_target -split '\|'
    $contrast = $uiParts[3]
    if (($contrast -eq 'normal' -and $capture.appearance -eq 'forced-colors') -or
        ($contrast -eq 'high-contrast' -and $capture.appearance -ne 'forced-colors')) {
        throw "$location.appearance does not match its UI contrast target."
    }
    if (Test-Property -Object $capture -Name 'scenario_target') {
        if ($expectedScenarioTargets -cnotcontains $capture.scenario_target -or
            -not $scenarioByTarget.ContainsKey($capture.scenario_target) -or
            $scenarioByTarget[$capture.scenario_target].status -ne 'pass') {
            throw "$location.scenario_target must reference a passed scenario."
        }
        $scenarioParts = $capture.scenario_target -split '\|'
        if ($scenarioParts[1] -cne $uiParts[1]) {
            throw "$location scenario and UI targets must use the same Windows product."
        }
    }
    if ($capture.surface -eq 'common-dialog' -and
        (-not (Test-Property -Object $capture -Name 'scenario_target') -or
         $capture.scenario_target -cnotlike 'scenario|Windows *|common-dialog')) {
        throw "$location common-dialog capture must bind the common-dialog scenario."
    }
    if ($capture.surface -eq 'recovery-window' -and
        (-not (Test-Property -Object $capture -Name 'scenario_target') -or
         ($capture.scenario_target -cnotlike 'scenario|Windows *|startup-recovery' -and
          $capture.scenario_target -cnotlike 'scenario|Windows *|recovery-export'))) {
        throw "$location recovery-window capture must bind a recovery scenario."
    }
    if ($null -ne $resolvedVisualEvidenceRoot) {
        $imagePath = Join-Path $resolvedVisualEvidenceRoot $capture.image.filename
        if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
            throw "$location image file is missing from VisualEvidenceRoot."
        }
        $imageItem = Get-Item -LiteralPath $imagePath -Force
        if (($imageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq
            [IO.FileAttributes]::ReparsePoint) {
            throw "$location image file must not be a reparse point."
        }
        $dimensions = Get-PngDimensions -Path $imagePath
        $minimumWidth = if ($capture.surface -eq 'main-workbench') { 640 } else { 240 }
        $minimumHeight = if ($capture.surface -eq 'main-workbench') { 360 } else { 120 }
        if ($dimensions.width -lt $minimumWidth -or $dimensions.height -lt $minimumHeight) {
            throw "$location PNG dimensions are too small for surface $($capture.surface)."
        }
        if ($dimensions.distinct_colors -lt 4) {
            throw "$location PNG must contain at least four distinct decoded colors."
        }
        if (-not $captureRasterHashes.Add($dimensions.raster_sha256)) {
            throw "Duplicate visual capture decoded raster: $($dimensions.raster_sha256)."
        }
        if ($dimensions.width -ne [uint64] $capture.image.pixel_width -or
            $dimensions.height -ne [uint64] $capture.image.pixel_height) {
            throw "$location PNG dimensions do not match the recorded pixel dimensions."
        }
        $actualImageHash = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals($actualImageHash, $capture.image.sha256, [StringComparison]::Ordinal)) {
            throw "$location image SHA-256 does not match VisualEvidenceRoot bytes."
        }
    }
    if ($capture.surface -eq 'main-workbench') {
        [void] $capturedMainTargets.Add($capture.ui_target)
        if ($contrast -eq 'normal') {
            [void] $capturedNormalMainAppearances.Add($capture.appearance)
        }
    }
    [void] $capturedSurfaces.Add($capture.surface)
    $captureIndex++
}

$benchmarkByTarget = @{}
$benchmarkIndex = 0
foreach ($row in @($evidence.benchmarks)) {
    $location = "benchmarks[$benchmarkIndex]"
    Assert-ObjectShape `
        -Object $row `
        -Required @(
            'media', 'filesystem', 'count', 'planning_ms', 'execution_ms', 'storage_model',
            'connection', 'free_space_bucket', 'power_mode', 'cleanup_observation'
        ) `
        -Location $location
    $hasExecutedRows = $true
    Assert-Enum -Value $row.media -Allowed $mediaKinds -Location "$location.media"
    Assert-Enum -Value $row.filesystem -Allowed $filesystemKinds -Location "$location.filesystem"
    Assert-Enum -Value $row.count -Allowed $benchmarkCounts -Location "$location.count"
    Assert-NonNegativeNumber -Value $row.planning_ms -Location "$location.planning_ms"
    Assert-NonNegativeNumber -Value $row.execution_ms -Location "$location.execution_ms"
    if ($row.storage_model -isnot [string] -or
        $row.storage_model -cnotmatch $schemaDefinitions.benchmark.properties.storage_model.pattern) {
        throw "$location.storage_model must be a model family using only safe characters."
    }
    Assert-Enum -Value $row.connection -Allowed @($schemaDefinitions.benchmark.properties.connection.enum) -Location "$location.connection"
    Assert-Enum -Value $row.free_space_bucket -Allowed @($schemaDefinitions.benchmark.properties.free_space_bucket.enum) -Location "$location.free_space_bucket"
    Assert-Enum -Value $row.power_mode -Allowed @($schemaDefinitions.benchmark.properties.power_mode.enum) -Location "$location.power_mode"
    Assert-Enum -Value $row.cleanup_observation -Allowed @($schemaDefinitions.benchmark.properties.cleanup_observation.enum) -Location "$location.cleanup_observation"
    $target = Get-BenchmarkTarget $row
    if ($benchmarkByTarget.ContainsKey($target)) {
        throw "Duplicate benchmark row: $target."
    }
    $benchmarkByTarget[$target] = $row
    $benchmarkIndex++
}

$durabilityByTarget = @{}
$durabilityIndex = 0
foreach ($row in @($evidence.durability_trials)) {
    $location = "durability_trials[$durabilityIndex]"
    Assert-ObjectShape -Object $row -Required @('kind', 'status', 'observation_code') -Optional @('authorization', 'unexecuted_id') -Location $location
    Assert-Enum -Value $row.kind -Allowed $durabilityKinds -Location "$location.kind"
    Assert-Enum -Value $row.status -Allowed $statuses -Location "$location.status"
    Assert-Enum -Value $row.observation_code -Allowed @($schemaDefinitions.durabilityTrial.properties.observation_code.enum) -Location "$location.observation_code"
    Assert-ObservationCode `
        -Status $row.status `
        -Code $row.observation_code `
        -Codes @{ pass = 'recovery-verified'; fail = 'recovery-defect'; 'not-run' = 'not-executed' } `
        -Location "$location.observation_code"
    if ($row.status -ne 'not-run') {
        $hasExecutedRows = $true
    }
    $hasAuthorization = Test-Property -Object $row -Name 'authorization'
    $requiresAuthorization = $row.kind -ne 'process-crash' -and $row.status -ne 'not-run'
    if ($requiresAuthorization) {
        if (-not $hasAuthorization -or
            $row.authorization -isnot [string] -or
            -not [string]::Equals($row.authorization, 'operator-authorized', [StringComparison]::Ordinal)) {
            throw "$location requires operator-authorized scope for an executed disruptive trial."
        }
    }
    elseif ($hasAuthorization) {
        throw "$location may include authorization only for an executed disruptive trial."
    }
    $target = Get-DurabilityTarget $row
    if ($durabilityByTarget.ContainsKey($target)) {
        throw "Duplicate durability trial class: $target."
    }
    $durabilityByTarget[$target] = $row
    Assert-NotRunReference -Row $row -Target $target -Location $location
    $durabilityIndex++
}

if ($Draft -and $contextsByProduct.Count -eq 0 -and $hasExecutedRows) {
    throw 'Draft evidence may omit operator_context only when no acceptance rows are executed.'
}

function Assert-TargetCoverage {
    param(
        [Parameter(Mandatory)]
        [string[]] $Expected,
        [Parameter(Mandatory)]
        [hashtable] $Observed,
        [Parameter(Mandatory)]
        [string] $Label,
        [switch] $AllowCompleteUnexecuted
    )

    foreach ($target in $Expected) {
        if ($Observed.ContainsKey($target)) {
            continue
        }
        if (-not $Draft -and -not $AllowCompleteUnexecuted) {
            throw "Complete evidence is missing $Label target: $target."
        }
        if (-not $unexecutedByTarget.ContainsKey($target)) {
            throw "Evidence must explain omitted $Label target in unexecuted: $target."
        }
        [void] $usedUnexecutedIds.Add($unexecutedByTarget[$target].id)
    }
}

Assert-TargetCoverage -Expected $expectedUiTargets -Observed $uiByTarget -Label 'UI matrix'
Assert-TargetCoverage -Expected $expectedScenarioTargets -Observed $scenarioByTarget -Label 'scenario'
$completeHddUnavailable = $false
if ($Draft) {
    Assert-TargetCoverage -Expected $expectedBenchmarkTargets -Observed $benchmarkByTarget -Label 'benchmark'
}
else {
    $expectedSsdBenchmarkTargets = @(
        $expectedBenchmarkTargets | Where-Object { $_ -clike 'benchmark|ssd|*' }
    )
    $expectedHddBenchmarkTargets = @(
        $expectedBenchmarkTargets | Where-Object { $_ -clike 'benchmark|hdd|*' }
    )
    Assert-TargetCoverage `
        -Expected $expectedSsdBenchmarkTargets `
        -Observed $benchmarkByTarget `
        -Label 'SSD benchmark'

    $observedHddBenchmarkTargets = @(
        $expectedHddBenchmarkTargets | Where-Object { $benchmarkByTarget.ContainsKey($_) }
    )
    if ($observedHddBenchmarkTargets.Count -eq 0) {
        $completeHddUnavailable = $true
        foreach ($target in $expectedHddBenchmarkTargets) {
            if (-not $unexecutedByTarget.ContainsKey($target)) {
                throw "Complete evidence must explain unavailable HDD benchmark target in unexecuted: $target."
            }
            $reason = $unexecutedByTarget[$target]
            if (-not [string]::Equals(
                    $reason.reason_code,
                    'hardware-unavailable',
                    [StringComparison]::Ordinal
                )) {
                throw "Complete evidence must use reason_code hardware-unavailable for omitted HDD benchmark target: $target."
            }
            [void] $usedUnexecutedIds.Add($reason.id)
        }
    }
    elseif ($observedHddBenchmarkTargets.Count -ne $expectedHddBenchmarkTargets.Count) {
        throw 'Complete evidence requires all three HDD benchmark rows or no HDD benchmark rows with hardware-unavailable reasons.'
    }
}
Assert-TargetCoverage `
    -Expected $expectedDurabilityTargets `
    -Observed $durabilityByTarget `
    -Label 'durability' `
    -AllowCompleteUnexecuted

foreach ($id in $unexecutedById.Keys) {
    if (-not $usedUnexecutedIds.Contains($id)) {
        throw "Unexecuted reason is not referenced by a not-run or omitted target: $id."
    }
}

if (-not $Draft) {
    foreach ($target in $expectedUiTargets) {
        if (-not $capturedMainTargets.Contains($target)) {
            throw "Complete evidence is missing a main-workbench visual capture for $target."
        }
    }
    foreach ($appearance in 'system', 'light', 'dark') {
        if (-not $capturedNormalMainAppearances.Contains($appearance)) {
            throw "Complete evidence is missing normal main-workbench appearance coverage: $appearance."
        }
    }
    foreach ($surface in @($schemaDefinitions.visualCapture.properties.surface.enum)) {
        if (-not $capturedSurfaces.Contains($surface)) {
            throw "Complete evidence is missing visual surface coverage: $surface."
        }
    }
    foreach ($row in $uiByTarget.Values) {
        if ($row.status -ne 'pass') {
            throw 'Complete evidence requires every UI matrix cell to pass.'
        }
    }
    foreach ($row in $scenarioByTarget.Values) {
        if ($row.status -ne 'pass') {
            throw 'Complete evidence requires every required scenario to pass.'
        }
    }
    foreach ($row in $benchmarkByTarget.Values) {
        if ($row.filesystem -ne 'ntfs') {
            throw 'Complete evidence requires NTFS for every benchmark row.'
        }
        if ($row.cleanup_observation -ne 'clean') {
            throw 'Complete evidence requires clean benchmark cleanup observations.'
        }
    }
    if (-not $durabilityByTarget.ContainsKey('durability|process-crash') -or $durabilityByTarget['durability|process-crash'].status -ne 'pass') {
        throw 'Complete evidence requires a passing process-crash durability trial.'
    }
    $hasAuthorizedDisruptiveTrial = (
        $durabilityByTarget.ContainsKey('durability|vm-hard-reset') -and
        $durabilityByTarget['durability|vm-hard-reset'].status -eq 'pass'
    ) -or (
        $durabilityByTarget.ContainsKey('durability|storage-fault') -and
        $durabilityByTarget['durability|storage-fault'].status -eq 'pass'
    )
    if (-not $hasAuthorizedDisruptiveTrial) {
        throw 'Complete evidence requires a passing authorized VM hard-reset or storage-fault trial.'
    }
    foreach ($row in $durabilityByTarget.Values) {
        if ($row.status -eq 'fail') {
            throw 'Complete evidence cannot contain a failed durability trial.'
        }
    }
}

$schemaErrors = @()
$conformsToSchema = Test-Json `
    -Json $evidenceJson `
    -SchemaFile $schemaPath `
    -ErrorAction SilentlyContinue `
    -ErrorVariable +schemaErrors
if (-not $conformsToSchema) {
    throw 'Evidence does not conform to windows-acceptance-evidence.schema.json.'
}

$mode = if ($Draft) {
    'draft'
}
elseif ($completeHddUnavailable) {
    'complete release-gate with HDD-unavailable limitation'
}
else {
    'complete release-gate'
}
if ($PassThru) {
    return $evidence
}
Write-Host "Validated $mode Windows acceptance evidence for source $($evidence.source_sha)."
