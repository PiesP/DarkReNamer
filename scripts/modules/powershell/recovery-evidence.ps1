function Assert-AcceptanceExactProperties {
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string[]] $Names,
        [Parameter(Mandatory)][string] $Label
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if ($actual.Count -ne $expected.Count) {
        throw "$Label has unexpected fields."
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($actual[$index] -cne $expected[$index]) {
            throw "$Label has unexpected fields."
        }
    }
}
function Get-AcceptanceBootstrapSha256 {
    param([Parameter(Mandatory)][string] $Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-AcceptanceBootstrapBytesSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $algorithm.ComputeHash($Bytes)
        ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}
function Resolve-AcceptanceInputs {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RunnerPath,
        [Parameter(Mandatory)][string] $ObserverPath,
        [Parameter(Mandatory)][string] $ExpectedObserverSha256
    )

    $verified = Resolve-VerifiedBundle -Root $Root -InvokedScriptPath $RunnerPath
    if ($verified.contract.product_source_state -cne 'clean' -or
        $verified.contract.harness_source_state -cne 'clean') {
        throw 'Recovery acceptance requires a clean source-bound bundle.'
    }
    Assert-OrdinaryFile -Path $ObserverPath -Label 'recovery acceptance observer'
    $observerItem = Get-Item -LiteralPath $ObserverPath -Force
    $observerSha256 = Get-LowerSha256 -Path $observerItem.FullName
    if ($observerSha256 -cne $ExpectedObserverSha256) {
        throw 'The recovery acceptance observer hash does not match its staging contract.'
    }
    $observer = if ($verified.contract.lane -ceq 'candidate-gui-only') {
        $verified.contract.observers.recovery
    }
    else {
        [pscustomobject]@{
            file = 'windows-vm-recovery-acceptance.ps1'
            sha256 = $observerSha256
        }
    }
    if ($observer.file -cne 'windows-vm-recovery-acceptance.ps1' -or
        $observer.sha256 -cne $observerSha256) {
        throw 'The invoked recovery observer differs from the verified harness role.'
    }
    [pscustomobject]@{
        verified = $verified
        contract = $verified.contract
        application_path = Join-Path $verified.root $verified.contract.application.file
        observer_file = $observerItem.Name
        observer_sha256 = $observerSha256
        observer = $observer
        runner_sha256 = $verified.hashes[$verified.contract.runner.file]
    }
}
function New-AcceptanceOutputDirectory {
    param([Parameter(Mandatory)][string] $Parent)

    if (-not [IO.Path]::IsPathRooted($Parent) -or
        -not (Test-Path -LiteralPath $Parent -PathType Container)) {
        throw 'OutputRoot must be an existing absolute directory.'
    }
    $item = Get-Item -LiteralPath $Parent -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'OutputRoot must not be a reparse point.'
    }
    $leaf = 'recovery-acceptance-' + [Guid]::NewGuid().ToString('N')
    $path = Join-Path $item.FullName $leaf
    [void](New-Item -ItemType Directory -Path $path)
    $path
}
function Write-AcceptanceUtf8Json {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object] $Value)

    $json = $Value | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}
function Write-AcceptanceNewBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][byte[]] $Bytes
    )

    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    $readback = [IO.File]::ReadAllBytes($Path)
    if (-not (Test-AcceptanceBytesEqual -Expected $Bytes -Actual $readback)) {
        throw 'A no-overwrite evidence write failed exact byte readback.'
    }
}
function Write-AcceptanceNewUtf8Json {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object] $Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        ($Value | ConvertTo-Json -Depth 12)
    )
    Write-AcceptanceNewBytes -Path $Path -Bytes $bytes
}
function New-AcceptancePrivateEvidenceDirectory {
    param([Parameter(Mandatory)][string] $Parent)

    if (-not [IO.Path]::IsPathRooted($Parent) -or
        -not (Test-Path -LiteralPath $Parent -PathType Container)) {
        throw 'PrivateEvidenceRoot must be an existing absolute directory.'
    }
    $item = Get-Item -LiteralPath $Parent -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'PrivateEvidenceRoot must not be a reparse point.'
    }
    $path = Join-Path $item.FullName ('recovery-raw-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $path)
    $path
}
function New-AcceptancePrivateReference {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Boundary
    )

    if ($Boundary -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
        throw 'A private evidence reference has an invalid boundary token.'
    }
    $rootItem = Get-Item -LiteralPath $PrivateRoot -Force
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The private evidence reference root is not one ordinary directory.'
    }
    $root = $rootItem.FullName.TrimEnd([char[]]'\/') +
        [IO.Path]::DirectorySeparatorChar
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt 64MB -or
        -not $item.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A private evidence reference escaped its owned ordinary-file root.'
    }
    $relative = $item.FullName.Substring($root.Length).Replace('\', '/')
    $segments = @($relative -split '[\/]')
    if ($segments.Count -lt 1 -or @($segments | Where-Object {
            $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        }).Count -ne 0) {
        throw 'A private evidence reference has an unsafe leaf.'
    }
    [pscustomobject][ordered]@{
        bytes = [int64]$item.Length
        sha256 = Get-LowerSha256 -Path $item.FullName
        boundary = $Boundary
    }
}
function Write-AcceptanceUtf16Paths {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string[]] $Paths)

    $encoding = [Text.UnicodeEncoding]::new($false, $true)
    $text = [string]::Join("`r`n", $Paths) + "`r`n"
    $body = $encoding.GetBytes($text)
    $preamble = $encoding.GetPreamble()
    $encodedLength = $preamble.Length + $body.Length
    if ($encodedLength -gt 2MB) {
        throw "The UTF-16LE path import is $encodedLength bytes and exceeds the production 2 MiB limit. Reduce FixtureCount."
    }
    $bytes = [byte[]]::new($encodedLength)
    [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    [IO.File]::WriteAllBytes($Path, $bytes)
    $encodedLength
}
function Get-AcceptanceFixtureState {
    param([Parameter(Mandatory)][string] $FixtureRoot)

    $root = Get-Item -LiteralPath $FixtureRoot -Force
    if (-not $root.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The acceptance fixture root is not one ordinary directory.'
    }
    $items = @(Get-ChildItem -LiteralPath $root.FullName -Force | Sort-Object Name)
    if ($items.Count -lt 1 -or $items.Count -gt 10001) {
        throw 'The acceptance fixture inventory is outside the bounded file count.'
    }
    $rows = [Collections.Generic.List[object]]::new()
    $folded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $totalBytes = [long]0
    foreach ($file in $items) {
        if ($file.PSIsContainer -or
            ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $file.Length -gt 64MB) {
            throw 'The acceptance fixture contains a non-file, reparse, or oversized entry.'
        }
        $totalBytes += [long]$file.Length
        if ($totalBytes -gt 512MB) {
            throw 'The acceptance fixture exceeds the aggregate byte limit.'
        }
        if (-not $folded.Add($file.Name)) {
            throw 'The acceptance fixture contains a case-insensitive name collision.'
        }
        $rows.Add([pscustomobject][ordered]@{
            name = $file.Name
            kind = 'file'
            bytes = [int64]$file.Length
            content_sha256 = Get-LowerSha256 -Path $file.FullName
            file_identity = Get-FullFileIdentity -Path $file.FullName
        })
    }
    $rows.ToArray()
}
function Test-AcceptanceIdentityEqual {
    param(
        [Parameter(Mandatory)][object] $Expected,
        [Parameter(Mandatory)][object] $Actual
    )

    $Expected.volume_serial -is [string] -and
        $Actual.volume_serial -is [string] -and
        $Expected.file_id -is [string] -and
        $Actual.file_id -is [string] -and
        $Expected.volume_serial -ceq $Actual.volume_serial -and
        $Expected.file_id -ceq $Actual.file_id
}
function Get-AcceptanceIdentityKey {
    param([Parameter(Mandatory)][object] $Identity)

    if ($Identity.volume_serial -isnot [string] -or
        $Identity.volume_serial -cnotmatch '^[0-9a-f]{16}$' -or
        $Identity.file_id -isnot [string] -or
        $Identity.file_id -cnotmatch '^[0-9a-f]{32}$') {
        throw 'The observed FILE_ID_INFO value is malformed or truncated.'
    }
    "$($Identity.volume_serial):$($Identity.file_id)"
}
function Assert-AcceptanceStatesEqual {
    param(
        [Parameter(Mandatory)][object[]] $Expected,
        [Parameter(Mandatory)][object[]] $Actual,
        [Parameter(Mandatory)][string] $Label
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "$Label has a different file count."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Expected[$index].name -cne $Actual[$index].name -or
            $Expected[$index].kind -cne $Actual[$index].kind -or
            $Expected[$index].bytes -ne $Actual[$index].bytes -or
            $Expected[$index].content_sha256 -cne $Actual[$index].content_sha256 -or
            -not (Test-AcceptanceIdentityEqual `
                -Expected $Expected[$index].file_identity `
                -Actual $Actual[$index].file_identity)) {
            throw "$Label changed a leaf, content digest, or NTFS identity."
        }
    }
}
function Assert-AcceptancePartialState {
    param(
        [Parameter(Mandatory)][object[]] $Initial,
        [Parameter(Mandatory)][object[]] $Partial,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][int] $ExpectedCount
    )

    if ($Partial.Count -ne $Initial.Count) {
        throw 'The partial state contains an unexpected number of files.'
    }
    $initialByIdentity = @{}
    foreach ($row in $Initial) {
        $identityKey = Get-AcceptanceIdentityKey -Identity $row.file_identity
        if ($initialByIdentity.ContainsKey($identityKey)) {
            throw 'The initial fixture contains a duplicate NTFS identity.'
        }
        $initialByIdentity[$identityKey] = $row
    }
    $original = 0
    $renamed = 0
    foreach ($row in $Partial) {
        $identityKey = Get-AcceptanceIdentityKey -Identity $row.file_identity
        if (-not $initialByIdentity.ContainsKey($identityKey)) {
            throw 'The partial state contains an unknown NTFS identity.'
        }
        $before = $initialByIdentity[$identityKey]
        if ($row.kind -cne 'file' -or
            $row.bytes -ne $before.bytes -or
            $row.content_sha256 -cne $before.content_sha256) {
            throw 'The partial state changed file kind, size, or contents.'
        }
        if ($before.name -ceq 'sentinel.bin') {
            if ($row.name -cne $before.name) {
                throw 'The sentinel leaf changed.'
            }
            continue
        }
        if ($row.name -ceq $before.name) {
            $original++
        }
        elseif ($row.name -ceq ($Prefix + $before.name)) {
            $renamed++
        }
        else {
            throw 'The partial state contains an unexpected leaf.'
        }
    }
    if ($original + $renamed -ne $ExpectedCount) {
        throw 'The partial state did not account for every transaction file.'
    }
    [pscustomobject]@{ original = $original; renamed = $renamed }
}
function Get-AcceptanceStateDigest {
    param([Parameter(Mandatory)][object[]] $State)

    $parts = foreach ($row in $State) {
        $identityKey = Get-AcceptanceIdentityKey -Identity $row.file_identity
        "$($row.name)|$($row.kind)|$($row.bytes)|$($row.content_sha256)|$identityKey"
    }
    Get-LowerTextSha256 -Value ([string]::Join("`n", $parts))
}
function Write-AcceptanceStateEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][object] $RootIdentity,
        [Parameter(Mandatory)][object[]] $State
    )

    if ($Leaf -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
        throw 'The state-evidence leaf is invalid.'
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        fixture_root = $FixtureRoot
        root_identity = $RootIdentity
        fixture_entries = @($State)
    })
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}
function Write-AcceptanceObservedStateEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][object] $ExpectedRootIdentity,
        [Parameter(Mandatory)][object[]] $State
    )

    $actualRootIdentity = Get-FullFileIdentity -Path $FixtureRoot
    [void](Get-AcceptanceIdentityKey -Identity $ExpectedRootIdentity)
    [void](Get-AcceptanceIdentityKey -Identity $actualRootIdentity)
    if (-not (Test-AcceptanceIdentityEqual `
            -Expected $ExpectedRootIdentity `
            -Actual $actualRootIdentity)) {
        throw "The fixture-root FILE_ID_INFO changed at $Boundary."
    }
    Write-AcceptanceStateEvidence `
        -PrivateRoot $PrivateRoot `
        -Leaf $Leaf `
        -Boundary $Boundary `
        -FixtureRoot $FixtureRoot `
        -RootIdentity $actualRootIdentity `
        -State $State
}
function Write-AcceptanceJournalBytesEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][byte[]] $Bytes
    )

    if ($Leaf -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}\.drj$' -or
        $Bytes.Length -lt 24 -or $Bytes.Length -gt 64MB) {
        throw 'The raw journal evidence leaf or byte length is invalid.'
    }
    $path = Join-Path $PrivateRoot $Leaf
    Write-AcceptanceNewBytes -Path $path -Bytes $Bytes
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}
function Write-AcceptanceJournalInventoryEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $JournalRoot
    )

    if ($Leaf -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
        throw 'The journal-inventory leaf is invalid.'
    }
    $rows = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $JournalRoot) {
        $root = Get-Item -LiteralPath $JournalRoot -Force
        if (-not $root.PSIsContainer -or
            ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The isolated journal root is not one ordinary directory.'
        }
        $items = @(Get-ChildItem -LiteralPath $root.FullName -Force | Sort-Object Name)
        if ($items.Count -gt 3) {
            throw 'The isolated journal inventory exceeds its bounded entry count.'
        }
        foreach ($item in $items) {
            if ($item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Name -cnotin @('active.drj', 'candidate.drj', 'runtime.lock') -or
                $item.Length -gt 64MB) {
                throw 'The isolated journal root contains an unexpected entry.'
            }
            $rows.Add([pscustomobject][ordered]@{
                name = $item.Name
                kind = 'file'
                bytes = [int64]$item.Length
                sha256 = Get-LowerSha256 -Path $item.FullName
            })
        }
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        journal_entries = $rows.ToArray()
    })
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}
function Test-AcceptanceControlTargetId {
    param(
        [Parameter(Mandatory)][int] $ControlId,
        [Parameter(Mandatory)][string] $AutomationId
    )

    if ($ControlId -gt 0) {
        return $true
    }
    return $ControlId -eq 0 -and
        @('CommandButton_2', 'CommandLink_1101', 'CommandLink_1201') -ccontains $AutomationId
}
function Assert-AcceptanceControlTargetRecord {
    param([Parameter(Mandatory)][object] $Target)

    $names = @($Target.PSObject.Properties.Name)
    if ($Target -is [Collections.IDictionary]) {
        $names = @($Target.Keys)
    }
    $expectedNames = @(
        'pid', 'session_id', 'hwnd', 'root_hwnd', 'class', 'control_id',
        'automation_id', 'control_type', 'enabled', 'visible', 'focused'
    )
    if ($names.Count -ne $expectedNames.Count -or
        @($expectedNames | Where-Object { $names -cnotcontains $_ }).Count -ne 0 -or
        [int]$Target.pid -le 0 -or [int]$Target.session_id -lt 0 -or
        [int64]$Target.hwnd -le 0 -or [int64]$Target.root_hwnd -le 0 -or
        [string]$Target.class -cne 'Button' -or
        -not (Test-AcceptanceControlTargetId `
            -ControlId ([int]$Target.control_id) `
            -AutomationId ([string]$Target.automation_id)) -or
        [string]::IsNullOrWhiteSpace([string]$Target.automation_id) -or
        [string]$Target.control_type -cne 'ControlType.Button' -or
        $Target.enabled -isnot [bool] -or $Target.visible -isnot [bool] -or
        $Target.focused -isnot [bool]) {
        throw 'A control target observation is incomplete or invalid.'
    }
}
function Copy-AcceptanceControlTargetRecord {
    param([Parameter(Mandatory)][object] $Target)

    Assert-AcceptanceControlTargetRecord -Target $Target
    [ordered]@{
        pid = [int]$Target.pid
        session_id = [int]$Target.session_id
        hwnd = [int64]$Target.hwnd
        root_hwnd = [int64]$Target.root_hwnd
        class = [string]$Target.class
        control_id = [int]$Target.control_id
        automation_id = [string]$Target.automation_id
        control_type = [string]$Target.control_type
        enabled = [bool]$Target.enabled
        visible = [bool]$Target.visible
        focused = [bool]$Target.focused
    }
}
function Write-AcceptanceActionEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][string] $Action,
        [Parameter(Mandatory)][object] $Target,
        [Parameter(Mandatory)][string] $ObservedUtcTicks,
        [Parameter(Mandatory)][string] $CompletedUtcTicks
    )

    foreach ($token in @($Leaf, $Boundary, $Phase, $Action)) {
        if ($token -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
            throw 'An action-evidence token is invalid.'
        }
    }
    if ($ObservedUtcTicks -cnotmatch '^[0-9]+$' -or
        $CompletedUtcTicks -cnotmatch '^[0-9]+$' -or
        [decimal]$CompletedUtcTicks -lt [decimal]$ObservedUtcTicks) {
        throw 'Action evidence has an invalid timestamp order.'
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        phase = $Phase
        action = $Action
        dispatch_method = 'uia-invoke'
        target = Copy-AcceptanceControlTargetRecord -Target $Target
        observed_utc_ticks = $ObservedUtcTicks
        completed_utc_ticks = $CompletedUtcTicks
    })
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}
function Write-AcceptanceLockStateEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Boundary,
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][int] $CandidatePid,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][object] $Apply,
        [Parameter(Mandatory)][object] $AddFiles,
        [Parameter(Mandatory)][string] $ObservedUtcTicks
    )

    foreach ($token in @($Leaf, $Boundary, $Phase)) {
        if ($token -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
            throw 'A recovery-lock evidence token is invalid.'
        }
    }
    if ($CandidatePid -le 0 -or $SessionId -lt 0 -or $ObservedUtcTicks -cnotmatch '^[0-9]+$') {
        throw 'Recovery-lock evidence has an invalid process or timestamp.'
    }
    $applyRecord = Copy-AcceptanceControlTargetRecord -Target $Apply
    $addFilesRecord = Copy-AcceptanceControlTargetRecord -Target $AddFiles
    foreach ($control in @($applyRecord, $addFilesRecord)) {
        if ($control.pid -ne $CandidatePid -or $control.session_id -ne $SessionId -or
            $control.root_hwnd -ne $applyRecord.root_hwnd) {
            throw 'Recovery-lock controls are not bound to one process, session, and root.'
        }
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        phase = $Phase
        observed_utc_ticks = $ObservedUtcTicks
        process = [ordered]@{
            pid = $CandidatePid
            session_id = $SessionId
        }
        controls = [ordered]@{
            apply = $applyRecord
            add_files = $addFilesRecord
        }
    })
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}
function Write-AcceptancePrivateIndex {
    param([Parameter(Mandatory)][string] $PrivateRoot)

    $root = Get-Item -LiteralPath $PrivateRoot -Force
    if (-not $root.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The private evidence root is not one owned ordinary directory.'
    }
    $rows = [Collections.Generic.List[object]]::new()
    $relativeNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($directory in @(Get-ChildItem -LiteralPath $root.FullName -Directory -Recurse -Force)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The private evidence root contains a reparse directory.'
        }
    }
    $prefix = $root.FullName.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    [int64]$aggregateBytes = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $root.FullName -File -Recurse -Force | Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Name -ceq 'private-index.json' -or
            $item.Length -gt 64MB) {
            throw 'The private evidence root contains an unsafe, reserved, or oversized file.'
        }
        $relative = $item.FullName.Substring($prefix.Length).Replace('\', '/')
        $segments = @($relative -split '[\/]')
        if ($segments.Count -lt 1 -or @($segments | Where-Object {
                $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
            }).Count -ne 0) {
            throw 'The private evidence root contains an unsafe relative path.'
        }
        if (-not $relativeNames.Add($relative)) {
            throw 'The private evidence root contains a case-insensitive path collision.'
        }
        $rows.Add([ordered]@{
            file = $relative
            bytes = [int64]$item.Length
            sha256 = Get-LowerSha256 -Path $item.FullName
        })
        $aggregateBytes += [int64]$item.Length
        if ($aggregateBytes -gt 512MB) {
            throw 'The private evidence root exceeds the aggregate collection bound.'
        }
    }
    if ($rows.Count -eq 0 -or $rows.Count -gt 240) {
        throw 'The private evidence index is empty or exceeds the controller file bound.'
    }
    $path = Join-Path $root.FullName 'private-index.json'
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        classification = 'private-path-bearing-raw-recovery-evidence'
        files = $rows.ToArray()
    })
    [pscustomobject][ordered]@{
        bytes = [int64](Get-Item -LiteralPath $path -Force).Length
        sha256 = Get-LowerSha256 -Path $path
        file_count = $rows.Count
    }
}
