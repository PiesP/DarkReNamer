function Get-DrToolingSupportedRoles {
    $roles = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $definitions = @(
        @('tooling-loader', 'python', 'darkrenamer_tooling.loader'),
        @('package-root', 'python-package', 'darkrenamer_tooling'),
        @('package-campaign', 'python-package', 'darkrenamer_tooling.campaign'),
        @('campaign-planning', 'python', 'darkrenamer_tooling.campaign.planning'),
        @('campaign-recovery', 'python', 'darkrenamer_tooling.campaign.recovery'),
        @('campaign-verifier', 'python', 'darkrenamer_tooling.campaign.verifier'),
        @('campaign-runner', 'python', 'darkrenamer_tooling.campaign.runner'),
        @('package-vm', 'python-package', 'darkrenamer_tooling.vm'),
        @('vm-launcher', 'python', 'darkrenamer_tooling.vm.launcher'),
        @('vm-gui', 'python', 'darkrenamer_tooling.vm.gui'),
        @('package-contracts', 'python-package', 'darkrenamer_tooling.contracts'),
        @('contracts-binding', 'python', 'darkrenamer_tooling.contracts.binding'),
        @('contracts-menu-layout', 'python', 'darkrenamer_tooling.contracts.menu_layout'),
        @('contracts-platform', 'python', 'darkrenamer_tooling.contracts.platform'),
        @('contracts-state', 'python', 'darkrenamer_tooling.contracts.state'),
        @('contracts-authority', 'python', 'darkrenamer_tooling.contracts.authority'),
        @('contracts-tooling', 'python', 'darkrenamer_tooling.contracts.tooling'),
        @('package-evidence', 'python-package', 'darkrenamer_tooling.evidence'),
        @('evidence-archive', 'python', 'darkrenamer_tooling.evidence.archive'),
        @('evidence-journal', 'python', 'darkrenamer_tooling.evidence.journal'),
        @('evidence-png', 'python', 'darkrenamer_tooling.evidence.png'),
        @('evidence-recovery', 'python', 'darkrenamer_tooling.evidence.recovery'),
        @('evidence-errors', 'python', 'darkrenamer_tooling.evidence.errors'),
        @('evidence-gui', 'python', 'darkrenamer_tooling.evidence.gui'),
        @('evidence-cli', 'python', 'darkrenamer_tooling.evidence.cli'),
        @('powershell-loader', 'powershell', $null),
        @('powershell-guest-contracts', 'powershell', $null),
        @('powershell-guest-process', 'powershell', $null),
        @('powershell-guest-native', 'powershell', $null),
        @('powershell-guest-platform', 'powershell', $null),
        @('powershell-guest-uia', 'powershell', $null),
        @('powershell-guest-state', 'powershell', $null),
        @('powershell-guest-scenario', 'powershell', $null),
        @('powershell-guest-runtime', 'powershell', $null),
        @('powershell-guest-entry', 'powershell', $null),
        @('powershell-ui-bootstrap', 'powershell', $null),
        @('powershell-ui-appearance', 'powershell', $null),
        @('powershell-ui-native', 'powershell', $null),
        @('powershell-ui-menu', 'powershell', $null),
        @('powershell-ui-input', 'powershell', $null),
        @('powershell-ui-application', 'powershell', $null),
        @('powershell-ui-fixtures', 'powershell', $null),
        @('powershell-ui-context-scenarios', 'powershell', $null),
        @('powershell-ui-regression', 'powershell', $null),
        @('powershell-ui-current-dpi', 'powershell', $null),
        @('powershell-ui-entry', 'powershell', $null),
        @('powershell-recovery-bootstrap', 'powershell', $null),
        @('powershell-recovery-journal', 'powershell', $null),
        @('powershell-recovery-evidence', 'powershell', $null),
        @('powershell-recovery-process', 'powershell', $null),
        @('powershell-recovery-native', 'powershell', $null),
        @('powershell-recovery-worker', 'powershell', $null),
        @('powershell-recovery-scenarios', 'powershell', $null),
        @('powershell-recovery-entry', 'powershell', $null),
        @('powershell-controller-contracts', 'powershell', $null),
        @('powershell-controller-transport', 'powershell', $null),
        @('powershell-controller-poll', 'powershell', $null),
        @('powershell-controller-rescue', 'powershell', $null),
        @('powershell-controller-entry', 'powershell', $null),
        @('powershell-common', 'powershell', $null),
        @('powershell-guest', 'powershell', $null),
        @('powershell-ui-observer', 'powershell', $null),
        @('powershell-recovery-observer', 'powershell', $null),
        @('release-tooling', 'powershell', $null)
    )
    foreach ($definition in $definitions) {
        $roles.Add($definition[0], [pscustomobject]@{
            Kind = $definition[1]
            Module = $definition[2]
        })
    }
    return $roles
}

function Get-DrToolingSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertFrom-DrToolingUtf8Bytes {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][string] $Label
    )

    $offset = 0
    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and
        $Bytes[2] -eq 0xbf) {
        $offset = 3
    }
    try {
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        return $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    }
    catch {
        throw "$Label must be strict UTF-8 with an optional UTF-8 BOM."
    }
}

function Skip-DrToolingJsonWhitespace {
    param([Parameter(Mandatory)][hashtable] $State)

    while ($State.Index -lt $State.Text.Length) {
        $code = [int] $State.Text[$State.Index]
        if ($code -notin @(0x20, 0x09, 0x0a, 0x0d)) {
            break
        }
        $State.Index++
    }
}

function Read-DrToolingJsonString {
    param([Parameter(Mandatory)][hashtable] $State)

    if ($State.Index -ge $State.Text.Length -or $State.Text[$State.Index] -cne '"') {
        throw 'JSON string expected.'
    }
    $State.Index++
    $builder = [Text.StringBuilder]::new()
    while ($State.Index -lt $State.Text.Length) {
        $character = $State.Text[$State.Index]
        $State.Index++
        if ($character -ceq '"') {
            return $builder.ToString()
        }
        if ([int] $character -lt 0x20) {
            throw 'JSON strings must not contain unescaped control characters.'
        }
        if ($character -cne '\') {
            [void] $builder.Append($character)
            continue
        }
        if ($State.Index -ge $State.Text.Length) {
            throw 'JSON string has an incomplete escape.'
        }
        $escaped = $State.Text[$State.Index]
        $State.Index++
        switch -CaseSensitive ($escaped) {
            '"' { [void] $builder.Append('"'); break }
            '\' { [void] $builder.Append('\'); break }
            '/' { [void] $builder.Append('/'); break }
            'b' { [void] $builder.Append([char] 0x08); break }
            'f' { [void] $builder.Append([char] 0x0c); break }
            'n' { [void] $builder.Append([char] 0x0a); break }
            'r' { [void] $builder.Append([char] 0x0d); break }
            't' { [void] $builder.Append([char] 0x09); break }
            'u' {
                if ($State.Index + 4 -gt $State.Text.Length) {
                    throw 'JSON string has an incomplete Unicode escape.'
                }
                $digits = $State.Text.Substring($State.Index, 4)
                if ($digits -cnotmatch '\A[0-9A-Fa-f]{4}\z') {
                    throw 'JSON string has an invalid Unicode escape.'
                }
                [void] $builder.Append([char] [Convert]::ToUInt16($digits, 16))
                $State.Index += 4
                break
            }
            default { throw "JSON string has an unsupported escape: \$escaped" }
        }
    }
    throw 'JSON string is unterminated.'
}

function Read-DrToolingJsonValue {
    param(
        [Parameter(Mandatory)][hashtable] $State,
        [Parameter(Mandatory)][int] $Depth
    )

    if ($Depth -gt 64) {
        throw 'JSON nesting exceeds the supported depth.'
    }
    Skip-DrToolingJsonWhitespace -State $State
    if ($State.Index -ge $State.Text.Length) {
        throw 'JSON value expected.'
    }
    $character = $State.Text[$State.Index]
    if ($character -ceq '"') {
        [void] (Read-DrToolingJsonString -State $State)
        return
    }
    if ($character -ceq '{') {
        $State.Index++
        Skip-DrToolingJsonWhitespace -State $State
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -ceq '}') {
            $State.Index++
            return
        }
        while ($true) {
            Skip-DrToolingJsonWhitespace -State $State
            $key = Read-DrToolingJsonString -State $State
            if (-not $keys.Add($key)) {
                throw "JSON object contains a duplicate key: $key"
            }
            Skip-DrToolingJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length -or $State.Text[$State.Index] -cne ':') {
                throw 'JSON object key must be followed by a colon.'
            }
            $State.Index++
            Read-DrToolingJsonValue -State $State -Depth ($Depth + 1)
            Skip-DrToolingJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) {
                throw 'JSON object is unterminated.'
            }
            if ($State.Text[$State.Index] -ceq '}') {
                $State.Index++
                return
            }
            if ($State.Text[$State.Index] -cne ',') {
                throw 'JSON object members must be separated by a comma.'
            }
            $State.Index++
        }
    }
    if ($character -ceq '[') {
        $State.Index++
        Skip-DrToolingJsonWhitespace -State $State
        if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -ceq ']') {
            $State.Index++
            return
        }
        while ($true) {
            Read-DrToolingJsonValue -State $State -Depth ($Depth + 1)
            Skip-DrToolingJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) {
                throw 'JSON array is unterminated.'
            }
            if ($State.Text[$State.Index] -ceq ']') {
                $State.Index++
                return
            }
            if ($State.Text[$State.Index] -cne ',') {
                throw 'JSON array members must be separated by a comma.'
            }
            $State.Index++
        }
    }

    $start = $State.Index
    while ($State.Index -lt $State.Text.Length) {
        $candidate = $State.Text[$State.Index]
        if ($candidate -ceq ',' -or $candidate -ceq ']' -or $candidate -ceq '}' -or
            [int] $candidate -in @(0x20, 0x09, 0x0a, 0x0d)) {
            break
        }
        $State.Index++
    }
    $token = $State.Text.Substring($start, $State.Index - $start)
    if ($token -cin @('true', 'false', 'null')) {
        return
    }
    if ($token -cnotmatch '\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z') {
        throw "Invalid JSON token: $token"
    }
}

function Assert-DrToolingUniqueJson {
    param([Parameter(Mandatory)][string] $Text)

    $state = @{ Text = $Text; Index = 0 }
    Read-DrToolingJsonValue -State $state -Depth 0
    Skip-DrToolingJsonWhitespace -State $state
    if ($state.Index -ne $Text.Length) {
        throw 'JSON has trailing non-whitespace content.'
    }
}

function Assert-DrToolingObjectShape {
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string[]] $Names,
        [Parameter(Mandatory)][string] $Label
    )

    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "$Label must be a JSON object."
    }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Names) {
        [void] $allowed.Add($name)
    }
    $actual = @($Value.PSObject.Properties)
    if ($actual.Count -ne $Names.Count) {
        throw "$Label has the wrong field count."
    }
    foreach ($property in $actual) {
        if (-not $allowed.Contains($property.Name)) {
            throw "$Label contains an unsupported field: $($property.Name)."
        }
    }
    foreach ($name in $Names) {
        if ($null -eq $Value.PSObject.Properties[$name]) {
            throw "$Label is missing field: $name."
        }
    }
}

function Assert-DrToolingPathComponent {
    param([Parameter(Mandatory)][string] $Component)

    if ($Component -cnotmatch '\A[A-Za-z0-9_][A-Za-z0-9._-]*\z' -or
        $Component -cin @('.', '..') -or
        $Component.EndsWith('.', [StringComparison]::Ordinal) -or
        $Component.EndsWith(' ', [StringComparison]::Ordinal) -or
        $Component.Contains('~')) {
        throw "Non-canonical tooling path component: $Component"
    }
    $stem = $Component.Split('.')[0].ToUpperInvariant()
    $reserved = @('CON', 'PRN', 'AUX', 'NUL', 'CLOCK$')
    for ($index = 1; $index -le 9; $index++) {
        $reserved += "COM$index", "LPT$index"
    }
    if ($stem -in $reserved) {
        throw "Reserved tooling path component: $Component"
    }
}

function Assert-DrToolingRelativePath {
    param(
        [Parameter(Mandatory)][object] $Value,
        [switch] $Source,
        [switch] $Flat
    )

    if ($Value -isnot [string] -or [string]::IsNullOrEmpty($Value) -or
        $Value.Contains('\') -or $Value.Contains([char] 0)) {
        throw 'Tooling paths must be non-empty canonical strings.'
    }
    $components = $Value.Split('/')
    if ($Flat -and $components.Count -ne 1) {
        throw "Bundle path must be a flat filename: $Value"
    }
    foreach ($component in $components) {
        if ([string]::IsNullOrEmpty($component)) {
            throw "Tooling path contains an empty component: $Value"
        }
        Assert-DrToolingPathComponent -Component $component
    }
    if ($Source -and ($components.Count -lt 2 -or $components[0] -cne 'scripts')) {
        throw "Tooling source must be below scripts/: $Value"
    }
}

function Resolve-DrToolingRoot {
    param([Parameter(Mandatory)][string] $Root)

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'Tooling root must be absolute.'
    }
    $fullRoot = [IO.Path]::GetFullPath($Root)
    $current = $fullRoot
    while ($null -ne $current) {
        [void] (Get-DrToolingPathSnapshot `
                -Path $current `
                -Directory `
                -Label 'tooling root ancestor')
        $parent = [IO.Directory]::GetParent($current)
        $current = if ($null -eq $parent) { $null } else { $parent.FullName }
    }
    return $fullRoot
}

function Get-DrToolingPathSnapshot {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label,
        [switch] $Directory
    )

    $item = if ($Directory) {
        [IO.DirectoryInfo]::new($Path)
    }
    else {
        [IO.FileInfo]::new($Path)
    }
    $item.Refresh()
    if (-not $item.Exists) {
        throw "$Label does not exist."
    }
    $attributes = $item.Attributes
    $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
    if ($isDirectory -ne [bool] $Directory -or
        ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must be an ordinary non-reparse $(if ($Directory) { 'directory' } else { 'file' })."
    }
    return [pscustomobject]@{
        Path = $item.FullName
        Directory = [bool] $Directory
        Attributes = [int] $attributes
        CreationTimeUtcTicks = $item.CreationTimeUtc.Ticks
        LastWriteTimeUtcTicks = $item.LastWriteTimeUtc.Ticks
        Length = if ($Directory) { [long] -1 } else { [long] $item.Length }
    }
}

function Assert-DrToolingPathSnapshotsUnchanged {
    param(
        [Parameter(Mandatory)][object[]] $Snapshots,
        [Parameter(Mandatory)][string] $Label
    )

    foreach ($expected in $Snapshots) {
        $actual = Get-DrToolingPathSnapshot `
            -Path $expected.Path `
            -Directory:$expected.Directory `
            -Label $Label
        if ($actual.Attributes -ne $expected.Attributes -or
            $actual.CreationTimeUtcTicks -ne $expected.CreationTimeUtcTicks -or
            $actual.LastWriteTimeUtcTicks -ne $expected.LastWriteTimeUtcTicks -or
            $actual.Length -ne $expected.Length) {
            throw "$Label path changed while it was read."
        }
    }
}

function Get-DrToolingFullPath {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Relative
    )

    $current = $Root
    $snapshots = [Collections.Generic.List[object]]::new()
    $snapshots.Add((Get-DrToolingPathSnapshot `
                -Path $current `
                -Directory `
                -Label "tooling path $Relative"))
    $components = $Relative.Split('/')
    for ($index = 0; $index -lt $components.Count; $index++) {
        $current = [IO.Path]::Combine($current, $components[$index])
        $snapshots.Add((Get-DrToolingPathSnapshot `
                    -Path $current `
                    -Directory:($index -lt $components.Count - 1) `
                    -Label "tooling path $Relative"))
    }
    return [pscustomobject]@{
        Path = $current
        Snapshots = [object[]] $snapshots.ToArray()
    }
}

function Read-DrToolingRegularFile {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Relative,
        [Parameter(Mandatory)][long] $MaximumBytes,
        [Parameter(Mandatory)][string] $Label
    )

    $resolved = Get-DrToolingFullPath -Root $Root -Relative $Relative
    $path = $resolved.Path
    $before = $resolved.Snapshots[$resolved.Snapshots.Count - 1]
    if ($before.Length -gt $MaximumBytes -or $before.Length -gt [int]::MaxValue) {
        throw "$Label exceeds its byte limit."
    }
    $stream = [IO.FileStream]::new(
        $path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read,
        4096,
        [IO.FileOptions]::SequentialScan
    )
    try {
        Assert-DrToolingPathSnapshotsUnchanged -Snapshots $resolved.Snapshots -Label $Label
        if ($stream.Length -ne $before.Length) {
            throw "$Label changed before it was read."
        }
        $bytes = [byte[]]::new([int] $stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) {
                throw "$Label changed while it was read."
            }
            $offset += $read
        }
        if ($stream.Length -ne $before.Length) {
            throw "$Label changed while it was read."
        }
        Assert-DrToolingPathSnapshotsUnchanged -Snapshots $resolved.Snapshots -Label $Label
    }
    finally {
        $stream.Dispose()
    }
    Assert-DrToolingPathSnapshotsUnchanged -Snapshots $resolved.Snapshots -Label $Label
    return [pscustomobject]@{ Bytes = $bytes }
}

function ConvertTo-DrToolingManifestRecords {
    param([Parameter(Mandatory)][object] $Manifest)

    Assert-DrToolingObjectShape `
        -Value $Manifest `
        -Names @('schema_version', 'modules') `
        -Label 'tooling manifest'
    if (($Manifest.schema_version -isnot [int] -and
            $Manifest.schema_version -isnot [long]) -or
        $Manifest.schema_version -ne 1) {
        throw 'Unsupported tooling manifest schema_version.'
    }
    if ($Manifest.modules -isnot [Array] -or
        $Manifest.modules.Count -lt 1 -or
        $Manifest.modules.Count -gt 128) {
        throw 'Tooling manifest modules must be a bounded non-empty array.'
    }

    $supported = Get-DrToolingSupportedRoles
    $records = [Collections.Generic.List[object]]::new()
    $roles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sourcePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $bundlePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $moduleNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $fields = @('role', 'source', 'bundle', 'kind', 'module', 'sha256', 'dependencies')
    foreach ($entry in $Manifest.modules) {
        Assert-DrToolingObjectShape -Value $entry -Names $fields -Label 'tooling module'
        if ($entry.role -isnot [string] -or -not $supported.ContainsKey($entry.role)) {
            throw "Unsupported tooling role: $($entry.role)"
        }
        if (-not $roles.Add($entry.role)) {
            throw "Duplicate tooling role: $($entry.role)"
        }
        $specification = $supported[$entry.role]
        if ($entry.kind -isnot [string] -or $entry.kind -cne $specification.Kind) {
            throw "Tooling role has the wrong kind: $($entry.role)"
        }
        if ($entry.module -cne $specification.Module) {
            throw "Tooling role has the wrong module name: $($entry.role)"
        }
        Assert-DrToolingRelativePath -Value $entry.source -Source
        Assert-DrToolingRelativePath -Value $entry.bundle -Flat
        if (-not $sourcePaths.Add($entry.source)) {
            throw "Case-colliding tooling source path: $($entry.source)"
        }
        if (-not $bundlePaths.Add($entry.bundle)) {
            throw "Case-colliding tooling bundle path: $($entry.bundle)"
        }
        if ($entry.kind -ceq 'powershell') {
            if (-not ($entry.source.EndsWith('.ps1', [StringComparison]::Ordinal) -or
                    $entry.source.EndsWith('.psm1', [StringComparison]::Ordinal)) -or
                -not ($entry.bundle.EndsWith('.ps1', [StringComparison]::Ordinal) -or
                    $entry.bundle.EndsWith('.psm1', [StringComparison]::Ordinal))) {
                throw "PowerShell role has an invalid filename: $($entry.role)"
            }
        }
        else {
            if (-not $entry.source.EndsWith('.py', [StringComparison]::Ordinal) -or
                -not $entry.bundle.EndsWith('.py', [StringComparison]::Ordinal)) {
                throw "Python role has an invalid filename: $($entry.role)"
            }
            if ($entry.module -isnot [string] -or
                $entry.module -cnotmatch '\Adarkrenamer_tooling(?:\.[a-z][a-z0-9_]*)*\z') {
                throw "Python role has an invalid module name: $($entry.role)"
            }
            if (-not $moduleNames.Add($entry.module)) {
                throw "Case-colliding Python module name: $($entry.module)"
            }
        }
        if ($entry.sha256 -isnot [string] -or
            $entry.sha256 -cnotmatch '\A[0-9a-f]{64}\z') {
            throw "Tooling role has an invalid SHA-256: $($entry.role)"
        }
        if ($entry.dependencies -isnot [Array]) {
            throw "Tooling dependencies must be an array: $($entry.role)"
        }
        $dependencies = [Collections.Generic.List[string]]::new()
        $dependencySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($dependency in $entry.dependencies) {
            if ($dependency -isnot [string] -or
                -not $dependencySet.Add($dependency) -or
                $dependency -ceq $entry.role) {
                throw "Tooling role has invalid dependencies: $($entry.role)"
            }
            $dependencies.Add($dependency)
        }
        $records.Add([pscustomobject]@{
            Role = $entry.role
            Source = $entry.source
            Bundle = $entry.bundle
            Kind = $entry.kind
            Module = $entry.module
            Sha256 = $entry.sha256
            Dependencies = [string[]] $dependencies.ToArray()
        })
    }

    $byRole = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $packages = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in $records) {
        $byRole.Add($record.Role, $record)
        if ($record.Kind -ceq 'python-package') {
            $packages.Add($record.Module, $record)
        }
    }
    $hasPython = $false
    foreach ($record in $records) {
        if ($record.Kind -cin @('python', 'python-package')) {
            $hasPython = $true
        }
        foreach ($dependency in $record.Dependencies) {
            if (-not $byRole.ContainsKey($dependency)) {
                throw "Tooling role has an unknown dependency: $($record.Role)"
            }
        }
    }
    if ($hasPython -and -not $packages.ContainsKey('darkrenamer_tooling')) {
        throw 'Python modules require the root package initializer.'
    }
    foreach ($record in $records) {
        if ($record.Kind -cin @('python', 'python-package')) {
            $parts = $record.Module.Split('.')
            for ($index = 1; $index -lt $parts.Count; $index++) {
                $ancestorName = [string]::Join('.', [string[]] $parts[0..($index - 1)])
                if (-not $packages.ContainsKey($ancestorName)) {
                    throw "Python role is missing package ${ancestorName}: $($record.Role)"
                }
                $ancestorRole = $packages[$ancestorName].Role
                if ($record.Dependencies -cnotcontains $ancestorRole) {
                    throw "Python role must depend on ${ancestorRole}: $($record.Role)"
                }
            }
        }
    }

    $states = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    function Visit-DrToolingDependency {
        param([string] $Role)
        if ($states.ContainsKey($Role)) {
            if ($states[$Role] -eq 1) {
                throw "Tooling dependency cycle includes role: $Role"
            }
            return
        }
        $states.Add($Role, 1)
        foreach ($dependency in $byRole[$Role].Dependencies) {
            Visit-DrToolingDependency -Role $dependency
        }
        $states[$Role] = 2
    }
    foreach ($record in $records) {
        Visit-DrToolingDependency -Role $record.Role
    }
    return [pscustomobject]@{
        Records = [object[]] $records.ToArray()
        ByRole = $byRole
    }
}

function Get-DrToolingVerifiedStateTable {
    $stateVariable = $ExecutionContext.SessionState.PSVariable.Get(
        'script:DrToolingBootstrapVerifiedStateTable'
    )
    if ($null -eq $stateVariable -or $null -eq $stateVariable.Value) {
        $script:DrToolingBootstrapVerifiedStateTable =
            [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
        return ,$script:DrToolingBootstrapVerifiedStateTable
    }
    if ($stateVariable.Value -isnot
        [Runtime.CompilerServices.ConditionalWeakTable[object, object]]) {
        throw 'The private tooling verifier state has an invalid type.'
    }
    return ,$stateVariable.Value
}

function Add-DrToolingVerifiedState {
    param(
        [Parameter(Mandatory)][object] $VerifiedBundle,
        [Parameter(Mandatory)][object] $State
    )

    $table = Get-DrToolingVerifiedStateTable
    $table.Add($VerifiedBundle, $State)
}

function Get-DrToolingVerifiedState {
    param([Parameter(Mandatory)][object] $VerifiedBundle)

    $table = Get-DrToolingVerifiedStateTable
    $state = $null
    if (-not $table.TryGetValue($VerifiedBundle, [ref] $state)) {
        throw 'VerifiedBundle was not produced by the tooling verifier.'
    }
    return $state
}

function Get-DrToolingVerifiedRecord {
    param(
        [Parameter(Mandatory)][object] $VerifiedBundle,
        [Parameter(Mandatory)][string] $Role
    )

    $state = Get-DrToolingVerifiedState -VerifiedBundle $VerifiedBundle
    $record = $null
    if (-not $state.Records.TryGetValue($Role, [ref] $record)) {
        throw "Role is outside the verified closure: $Role"
    }
    return $record
}

function Get-DrToolingVerifiedBundle {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ManifestLocation,
        [Parameter(Mandatory)][string] $ExpectedManifestSha256,
        [Parameter(Mandatory)][string] $Mode,
        [Parameter(Mandatory)][string[]] $RequiredRoles
    )

    if ($Mode -cne 'checkout' -and $Mode -cne 'bundle') {
        throw "Unsupported tooling mode: $Mode"
    }
    if ($ExpectedManifestSha256 -cnotmatch '\A[0-9a-f]{64}\z') {
        throw 'Trusted manifest SHA-256 must be lowercase hexadecimal.'
    }
    if ($null -eq $RequiredRoles -or $RequiredRoles.Count -eq 0) {
        throw 'At least one required tooling role must be selected.'
    }
    $requiredSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($role in $RequiredRoles) {
        if ([string]::IsNullOrEmpty($role) -or -not $requiredSet.Add($role)) {
            throw 'Required tooling roles must be unique non-empty strings.'
        }
    }

    $resolvedRoot = Resolve-DrToolingRoot -Root $Root
    Assert-DrToolingRelativePath -Value $ManifestLocation -Flat:($Mode -ceq 'bundle')
    $manifestRead = Read-DrToolingRegularFile `
        -Root $resolvedRoot `
        -Relative $ManifestLocation `
        -MaximumBytes (512 * 1024) `
        -Label 'tooling manifest'
    $manifestBytes = [byte[]] $manifestRead.Bytes
    $manifestSha256 = Get-DrToolingSha256 -Bytes $manifestBytes
    if ($manifestSha256 -cne $ExpectedManifestSha256) {
        throw 'Tooling manifest SHA-256 does not match the trusted pin.'
    }
    $manifestText = ConvertFrom-DrToolingUtf8Bytes `
        -Bytes $manifestBytes `
        -Label 'tooling manifest'
    Assert-DrToolingUniqueJson -Text $manifestText
    try {
        $manifest = $manifestText |
            Microsoft.PowerShell.Utility\ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Tooling manifest is invalid JSON: $($_.Exception.Message)"
    }
    $parsed = ConvertTo-DrToolingManifestRecords -Manifest $manifest
    foreach ($role in $RequiredRoles) {
        if (-not $parsed.ByRole.ContainsKey($role)) {
            throw "Required tooling role is absent: $role"
        }
    }

    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    function Select-DrToolingDependency {
        param([string] $Role)
        if ($selected.Contains($Role)) {
            return
        }
        foreach ($dependency in $parsed.ByRole[$Role].Dependencies) {
            Select-DrToolingDependency -Role $dependency
        }
        [void] $selected.Add($Role)
    }
    foreach ($role in $RequiredRoles) {
        Select-DrToolingDependency -Role $role
    }

    $frozen = [Collections.Generic.List[object]]::new()
    $privateRecords =
        [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $totalBytes = [long] 0
    foreach ($record in $parsed.Records) {
        if (-not $selected.Contains($record.Role)) {
            continue
        }
        $relative = if ($Mode -ceq 'checkout') { $record.Source } else { $record.Bundle }
        $read = Read-DrToolingRegularFile `
            -Root $resolvedRoot `
            -Relative $relative `
            -MaximumBytes (8 * 1024 * 1024) `
            -Label "tooling role $($record.Role)"
        $bytes = [byte[]] $read.Bytes
        if ((Get-DrToolingSha256 -Bytes $bytes) -cne $record.Sha256) {
            throw "SHA-256 mismatch for tooling role: $($record.Role)"
        }
        $totalBytes += $bytes.Length
        if ($totalBytes -gt (32 * 1024 * 1024)) {
            throw 'Selected tooling closure exceeds the aggregate size limit.'
        }
        $frozenBase64 = [Convert]::ToBase64String($bytes)
        $frozen.Add([pscustomobject]@{
            Role = $record.Role
            Source = $record.Source
            Bundle = $record.Bundle
            Kind = $record.Kind
            Module = $record.Module
            Sha256 = $record.Sha256
            Dependencies = [string[]] $record.Dependencies.Clone()
            FrozenBase64 = $frozenBase64
            Length = $bytes.Length
        })
        $privateRecords.Add($record.Role, [pscustomobject]@{
            Kind = $record.Kind
            Sha256 = $record.Sha256
            FrozenBase64 = $frozenBase64
            Length = $bytes.Length
        })
    }

    foreach ($record in $frozen) {
        if ($record.Kind -cne 'powershell') {
            continue
        }
        $bytes = [Convert]::FromBase64String($record.FrozenBase64)
        $source = ConvertFrom-DrToolingUtf8Bytes `
            -Bytes $bytes `
            -Label "tooling role $($record.Role)"
        $tokens = $null
        $errors = $null
        [void] [Management.Automation.Language.Parser]::ParseInput(
            $source,
            [ref] $tokens,
            [ref] $errors
        )
        if ($errors.Count -ne 0) {
            throw "Invalid PowerShell source for tooling role $($record.Role): $($errors[0].Message)"
        }
    }

    $result = [pscustomobject]@{
        ManifestBase64 = [Convert]::ToBase64String($manifestBytes)
        ManifestSha256 = $manifestSha256
        Mode = $Mode
        RequiredRoles = [string[]] $RequiredRoles.Clone()
        Records = [object[]] $frozen.ToArray()
    }
    $result.PSObject.TypeNames.Insert(0, 'DarkReNamer.Tooling.VerifiedBundle')
    Add-DrToolingVerifiedState `
        -VerifiedBundle $result `
        -State ([pscustomobject]@{ Records = $privateRecords })
    return $result
}

function Get-DrToolingVerifiedBytes {
    param(
        [Parameter(Mandatory)][object] $VerifiedBundle,
        [Parameter(Mandatory)][string] $Role
    )

    $record = Get-DrToolingVerifiedRecord -VerifiedBundle $VerifiedBundle -Role $Role
    $bytes = [Convert]::FromBase64String($record.FrozenBase64)
    if ($bytes.Length -ne $record.Length -or
        (Get-DrToolingSha256 -Bytes $bytes) -cne $record.Sha256) {
        throw "Frozen bytes are invalid for tooling role: $Role"
    }
    return ,$bytes
}

function New-DrToolingVerifiedScriptBlock {
    param(
        [Parameter(Mandatory)][object] $VerifiedBundle,
        [Parameter(Mandatory)][string] $Role
    )

    $record = Get-DrToolingVerifiedRecord -VerifiedBundle $VerifiedBundle -Role $Role
    if ($record.Kind -cne 'powershell') {
        throw "Role is not a PowerShell module: $Role"
    }
    $bytes = Get-DrToolingVerifiedBytes -VerifiedBundle $VerifiedBundle -Role $Role
    $source = ConvertFrom-DrToolingUtf8Bytes -Bytes $bytes -Label "tooling role $Role"
    return [ScriptBlock]::Create($source)
}
