[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $EvidencePath,

    [switch] $Draft
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

if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
    throw "Evidence file does not exist: $EvidencePath"
}
try {
    $evidenceJson = Get-Content -LiteralPath $EvidencePath -Raw
    $jsonDocument = [Text.Json.JsonDocument]::Parse($evidenceJson)
    try {
        if ($jsonDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'Evidence root must be a JSON object.'
        }
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
        'operator_context', 'ui_matrix', 'scenarios', 'benchmarks',
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
if ($contextsByProduct.Count -eq 0) {
    throw 'operator_context must identify at least one Windows test host.'
}
if (-not $Draft) {
    foreach ($product in $windowsProducts) {
        if (-not $contextsByProduct.ContainsKey($product)) {
            throw "Complete evidence requires operator context for $product."
        }
    }
}

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
    if (-not $contextsByProduct.ContainsKey($row.windows_product)) {
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
    if (-not $contextsByProduct.ContainsKey($row.windows_product)) {
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

$benchmarkByTarget = @{}
$benchmarkIndex = 0
foreach ($row in @($evidence.benchmarks)) {
    $location = "benchmarks[$benchmarkIndex]"
    Assert-ObjectShape `
        -Object $row `
        -Required @(
            'media', 'count', 'planning_ms', 'execution_ms', 'storage_model',
            'connection', 'free_space_bucket', 'power_mode', 'cleanup_observation'
        ) `
        -Location $location
    Assert-Enum -Value $row.media -Allowed $mediaKinds -Location "$location.media"
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
Assert-TargetCoverage -Expected $expectedBenchmarkTargets -Observed $benchmarkByTarget -Label 'benchmark'
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

$mode = if ($Draft) { 'draft' } else { 'complete release-gate' }
Write-Host "Validated $mode Windows acceptance evidence for source $($evidence.source_sha)."
