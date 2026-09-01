[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceRoot,
    [Parameter(Mandatory)][string] $EvidencePath,
    [Parameter(Mandatory)][string] $LogDirectory,
    [Parameter(Mandatory)][string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version] '7.4') {
    throw 'Windows acceptance benchmark augmentation requires PowerShell 7.4 or newer (pwsh).'
}

function Assert-AbsoluteExternalPath {
    param([string] $Path, [string] $Name, [string] $SourcePath, [StringComparison] $Comparison)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "$Name must be absolute." }
    $full = [IO.Path]::GetFullPath($Path)
    $root = $SourcePath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if ([string]::Equals($full, $root, $Comparison) -or $full.StartsWith($prefix, $Comparison)) {
        throw "$Name must be outside SourceRoot."
    }
    return $full
}

function Assert-NoReparseAncestors {
    param([string] $Path, [switch] $IncludeLeaf)
    $current = if ($IncludeLeaf) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)) }
    while ($null -ne $current) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) {
            throw 'Acceptance benchmark paths must not contain reparse points.'
        }
        $parent = [IO.Directory]::GetParent($current)
        $current = if ($null -eq $parent) { $null } else { $parent.FullName }
    }
}

function Read-StrictUtf8FileOnce {
    param([string] $Path, [long] $MaximumBytes, [string] $Label)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$Label must be a regular non-reparse file."
    }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $MaximumBytes) { throw "$Label exceeds its byte limit." }
        $bytes = [byte[]]::new([int] $stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw "$Label changed while it was being read." }
            $offset += $read
        }
    }
    finally { $stream.Dispose() }
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { $start = 3 }
    try { return [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $start, $bytes.Length - $start) }
    catch { throw "$Label must be strict UTF-8 with an optional UTF-8 BOM." }
}

function Assert-ExactObjectShape {
    param([object] $Object, [string[]] $Names, [string] $Label)
    $actualNames = if ($Object -is [pscustomobject]) { @($Object.PSObject.Properties.Name | Sort-Object) } else { @() }
    $expectedNames = @($Names | Sort-Object)
    if ($Object -isnot [pscustomobject] -or ($actualNames -join ',') -cne ($expectedNames -join ',')) {
        throw "$Label must contain exactly: $($Names -join ', ')."
    }
}

$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
$top = @(& git -C $sourcePath rev-parse --show-toplevel 2>$null)
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if ($LASTEXITCODE -ne 0 -or $top.Count -ne 1 -or -not [string]::Equals([IO.Path]::GetFullPath($top[0]), [IO.Path]::GetFullPath($sourcePath), $comparison)) {
    throw 'SourceRoot must identify the exact Git worktree root.'
}
$head = @(& git -C $sourcePath rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1 -or $head[0] -cnotmatch '^[0-9a-f]{40}$') { throw 'Source HEAD could not be resolved.' }

$evidenceFull = Assert-AbsoluteExternalPath -Path $EvidencePath -Name 'EvidencePath' -SourcePath $sourcePath -Comparison $comparison
$logsFull = Assert-AbsoluteExternalPath -Path $LogDirectory -Name 'LogDirectory' -SourcePath $sourcePath -Comparison $comparison
$outputFull = Assert-AbsoluteExternalPath -Path $OutputPath -Name 'OutputPath' -SourcePath $sourcePath -Comparison $comparison
if (-not (Test-Path -LiteralPath $evidenceFull -PathType Leaf)) { throw 'EvidencePath must identify an existing file.' }
if (-not (Test-Path -LiteralPath $logsFull -PathType Container)) { throw 'LogDirectory must identify an existing directory.' }
$outputParent = [IO.Path]::GetDirectoryName($outputFull)
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw 'OutputPath parent directory must already exist.' }
if (Test-Path -LiteralPath $outputFull) { throw 'OutputPath already exists; augmentation never overwrites a destination.' }
Assert-NoReparseAncestors -Path $evidenceFull -IncludeLeaf
Assert-NoReparseAncestors -Path $logsFull -IncludeLeaf
Assert-NoReparseAncestors -Path $outputFull

$validator = Join-Path $PSScriptRoot 'validate-windows-acceptance-evidence.ps1'
$evidence = & $validator -EvidencePath $evidenceFull -Draft -PassThru
if ($evidence.source_sha -cne $head[0]) { throw 'Evidence source_sha must match current source HEAD.' }

$entries = @(Get-ChildItem -LiteralPath $logsFull -Force)
$logFiles = @($entries | Where-Object { -not $_.PSIsContainer -and $_.Name -like '*.log' } | Sort-Object Name)
$otherEntries = @($entries | Where-Object { $_.PSIsContainer -or ($_.Name -cne 'benchmark-context.json' -and $_.Name -notlike '*.log') })
if ($logFiles.Count -ne 5 -or $otherEntries.Count -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $logsFull 'benchmark-context.json') -PathType Leaf)) {
    throw 'LogDirectory must contain exactly five *.log files plus benchmark-context.json.'
}

$contextPath = Join-Path $logsFull 'benchmark-context.json'
$contextText = Read-StrictUtf8FileOnce -Path $contextPath -MaximumBytes 65536 -Label 'benchmark-context.json'
$contextDocument = $null
try {
    $contextDocument = [Text.Json.JsonDocument]::Parse($contextText)
    if ($contextDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
        throw 'benchmark-context.json must be a JSON object.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $contextDocument.RootElement.EnumerateObject()) {
        if (-not $seen.Add($property.Name)) { throw 'benchmark-context.json contains a duplicate field.' }
    }
    $contextSchemaVersionElement = $contextDocument.RootElement.GetProperty('schema_version').Clone()
    $context = $contextText | ConvertFrom-Json
}
catch { throw 'benchmark-context.json is invalid or has duplicate fields.' }
finally { if ($null -ne $contextDocument) { $contextDocument.Dispose() } }
$contextNames = @('schema_version','windows_product','windows_build','architecture','filesystem','storage_model','connection','free_space_bucket','power_mode')
Assert-ExactObjectShape -Object $context -Names $contextNames -Label 'benchmark-context.json'
$contextSchemaVersion = [long]0
if ($contextSchemaVersionElement.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
    -not $contextSchemaVersionElement.TryGetInt64([ref]$contextSchemaVersion) -or
    $contextSchemaVersion -ne 1) {
    throw 'benchmark-context.json schema_version must be the JSON integer 1.'
}
if ($context.windows_product -cnotin @('Windows 10','Windows 11') -or $context.windows_build -isnot [string] -or $context.windows_build -notmatch '^[0-9]+(?:\.[0-9]+){0,3}$' -or $context.architecture -cnotin @('x64','arm64')) { throw 'benchmark-context.json contains invalid operator context.' }
if ($context.filesystem -cne 'ntfs') { throw 'benchmark-context.json filesystem must be ntfs.' }
if ($context.storage_model -isnot [string] -or $context.storage_model -notmatch '^(?=[A-Za-z0-9 ._()+-]{1,200}$)(?=.*[A-Za-z])[A-Za-z0-9][A-Za-z0-9 ._()+-]*$') { throw 'benchmark-context.json storage_model is invalid.' }
if ($context.connection -cnotin @('nvme','sata','usb','thunderbolt','other-physical') -or $context.free_space_bucket -cnotin @('under-10-percent','10-to-24-percent','25-to-49-percent','50-percent-or-more') -or $context.power_mode -cnotin @('power-saver','balanced','high-performance','other')) { throw 'benchmark-context.json contains invalid storage context.' }

$summaryPattern = '^darkrenamer_benchmark,media=(?<media>[^,]+),count=(?<count>0|[1-9][0-9]*),topology=(?<topology>[^,]+),variant=(?<variant>[^,]+),evidence_class=(?<evidence_class>[^,]+),iteration=(?<iteration>0|[1-9][0-9]*),recorded=(?<recorded>[^,]+),scope=(?<scope>[^,]+),source_sha=(?<source_sha>[0-9a-f]{40}),instrumentation_revision=(?<revision>[^,]+),planning_ms=(?<planning_ms>0|[1-9][0-9]*),execution_ms=(?<execution_ms>0|[1-9][0-9]*),planning_us=(?<planning_us>0|[1-9][0-9]*),preflight_us=(?<preflight_us>0|[1-9][0-9]*),execution_us=(?<execution_us>0|[1-9][0-9]*)$'
$libtestSummaryPrefix = 'test benchmark_durable_production_path ... '
$summaries = @()
$maxSafe = [uint64]9007199254740991
foreach ($file in $logFiles) {
    Assert-NoReparseAncestors -Path $file.FullName -IncludeLeaf
    $text = Read-StrictUtf8FileOnce -Path $file.FullName -MaximumBytes (4 * 1024 * 1024) -Label $file.Name
    if ($text.IndexOf([char]0) -ge 0) { throw "$($file.Name) contains NUL." }
    $lines = @([regex]::Split($text, '\r\n|\n|\r'))
    $summary = $null
    $summaryIndex = -1
    $successIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Length -gt 8192) { throw "$($file.Name) contains an overlong line." }
        $summaryText = $null
        if ($line.StartsWith('darkrenamer_benchmark,', [StringComparison]::Ordinal)) {
            $summaryText = $line
        }
        elseif ($line.StartsWith($libtestSummaryPrefix, [StringComparison]::Ordinal)) {
            $summaryText = $line.Substring($libtestSummaryPrefix.Length)
        }
        elseif ($line.IndexOf('darkrenamer_benchmark,', [StringComparison]::Ordinal) -ge 0) {
            throw "$($file.Name) contains a noncanonical benchmark summary prefix."
        }
        if ($null -ne $summaryText) {
            $match = [regex]::Match($summaryText, $summaryPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
            if (-not $match.Success) { throw "$($file.Name) contains a malformed benchmark summary." }
            if ($null -ne $summary) { throw "$($file.Name) contains more than one benchmark summary." }
            $summary = @{}
            foreach ($name in 'media','count','topology','variant','evidence_class','iteration','recorded','scope','source_sha','revision','planning_ms','execution_ms','planning_us','preflight_us','execution_us') { $summary[$name] = $match.Groups[$name].Value }
            $summaryIndex = $index
        }
        elseif ($line.StartsWith('darkrenamer_benchmark_backend,') -or $line.StartsWith('darkrenamer_benchmark_journal,')) { continue }
        elseif ($line.StartsWith('darkrenamer_benchmark')) { throw "$($file.Name) contains an unknown benchmark diagnostic prefix." }
        if ($line.StartsWith('test result: ok.')) { $successIndex = $index }
    }
    if ($null -eq $summary) { throw "$($file.Name) is missing its benchmark summary." }
    if ($successIndex -le $summaryIndex) { throw "$($file.Name) is missing a later successful test result." }
    foreach ($name in 'count','iteration','planning_ms','execution_ms','planning_us','preflight_us','execution_us') {
        $value = [uint64]0
        if (-not [uint64]::TryParse($summary[$name], [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or $value -gt $maxSafe) { throw "$($file.Name) contains an unsafe benchmark integer." }
        $summary[$name] = $value
    }
    if ($summary.topology -cne 'same-parent' -or $summary.variant -cne 'baseline' -or $summary.evidence_class -cne 'physical' -or $summary.recorded -cne 'true' -or $summary.scope -cne 'durable' -or $summary.revision -cne 'parent-validation-v1') { throw "$($file.Name) is not a recorded physical same-parent baseline summary." }
    if ($summary.media -cnotin @('ssd','hdd') -or $summary.count -notin @([uint64]100,[uint64]1000,[uint64]10000) -or $summary.iteration -lt 1 -or $summary.iteration -gt 5) { throw "$($file.Name) contains an invalid benchmark target or iteration." }
    if ($summary.source_sha -cne $evidence.source_sha) { throw "$($file.Name) source_sha does not match evidence." }
    if ([uint64][math]::Floor([decimal]$summary.planning_us / 1000) -ne $summary.planning_ms -or [uint64][math]::Floor([decimal]$summary.execution_us / 1000) -ne $summary.execution_ms) { throw "$($file.Name) millisecond values do not match microseconds." }
    $summaries += [pscustomobject]$summary
}

$iterations = @($summaries.iteration | Sort-Object)
if (($iterations -join ',') -cne '1,2,3,4,5') { throw 'Benchmark iterations must be exactly 1 through 5 once each.' }
$media = @($summaries.media | Sort-Object -Unique)
$counts = @($summaries | ForEach-Object { $_.count } | Sort-Object -Unique)
if ($media.Count -ne 1 -or $counts.Count -ne 1) { throw 'All benchmark summaries must use one media and count target.' }
$target = "benchmark|$($media[0])|$($counts[0])"
if (@($evidence.benchmarks | Where-Object { "benchmark|$($_.media)|$($_.count)" -ceq $target }).Count -ne 0) { throw 'Evidence already contains this benchmark target.' }
$reasons = @($evidence.unexecuted | Where-Object { $_.target -ceq $target })
if ($reasons.Count -ne 1) { throw "Evidence must contain exactly one unexecuted reason for benchmark target $target." }

$existingContext = @($evidence.operator_context | Where-Object { $_.windows_product -ceq $context.windows_product })
if ($existingContext.Count -eq 0) {
    $evidence.operator_context = @($evidence.operator_context) + [pscustomobject][ordered]@{ windows_product=$context.windows_product; windows_build=$context.windows_build; architecture=$context.architecture }
}
elseif ($existingContext.Count -ne 1 -or $existingContext[0].windows_build -cne $context.windows_build -or $existingContext[0].architecture -cne $context.architecture) { throw 'benchmark-context.json conflicts with existing operator context.' }

$planningMedian = @($summaries.planning_ms | Sort-Object)[2]
$executionMedian = @($summaries.execution_ms | Sort-Object)[2]
$evidence.benchmarks = @($evidence.benchmarks) + [pscustomobject][ordered]@{ media=$media[0]; filesystem='ntfs'; count=[int64]$counts[0]; planning_ms=[int64]$planningMedian; execution_ms=[int64]$executionMedian; storage_model=$context.storage_model; connection=$context.connection; free_space_bucket=$context.free_space_bucket; power_mode=$context.power_mode; cleanup_observation='clean' }
$evidence.unexecuted = @($evidence.unexecuted | Where-Object { $_.target -cne $target })
$evidence.recorded_at_utc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
$json = ($evidence | ConvertTo-Json -Depth 20) + "`n"
& $validator -EvidenceJson $json -Draft -PassThru | Out-Null

$leaf = [IO.Path]::GetFileName($outputFull)
$temp = Join-Path $outputParent ".$leaf.$([Guid]::NewGuid().ToString('N')).tmp"
$owned = $false
try {
    Assert-NoReparseAncestors -Path $outputFull
    $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $owned = $true
    try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json); $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    & $validator -EvidencePath $temp -Draft -PassThru | Out-Null
    Assert-NoReparseAncestors -Path $outputFull
    [IO.File]::Move($temp, $outputFull)
    $owned = $false
}
finally { if ($owned -and (Test-Path -LiteralPath $temp -PathType Leaf)) { Remove-Item -LiteralPath $temp -Force } }
Write-Host "Added $target benchmark medians to Windows acceptance evidence."
