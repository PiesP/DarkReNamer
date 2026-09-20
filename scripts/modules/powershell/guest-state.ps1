function Assert-NoJournalResidue {
    param([Parameter(Mandatory)][string] $LocalAppData)

    $journalRoot = Join-Path (Join-Path $LocalAppData 'DarkReNamer') 'journal'
    if (Test-Path -LiteralPath $journalRoot) {
        $residue = @(
            Get-ChildItem -LiteralPath $journalRoot -Force |
                Where-Object Name -cne 'runtime.lock'
        )
        if ($residue.Count -ne 0) {
            throw 'The production flow left rename-journal residue.'
        }
    }
}
function Get-FlowCheckpoint {
    param(
        [Parameter(Mandatory)][ValidateSet('initial', 'after_cancel', 'after_apply', 'post_close')]
        [string] $Phase,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $LocalAppData
    )

    $fixtureItems = @(Get-ChildItem -LiteralPath $FixtureRoot -Force | Sort-Object Name)
    if ($fixtureItems.Count -gt 8) {
        throw 'The production flow fixture inventory exceeds its bound.'
    }
    $fixtureEntries = foreach ($item in $fixtureItems) {
        $reparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        $kind = if ($reparse) { 'reparse' } elseif ($item.PSIsContainer) { 'directory' } else { 'file' }
        [ordered]@{
            name = $item.Name
            kind = $kind
            bytes = if ($kind -ceq 'file') { [long]$item.Length } else { [long]0 }
            content_sha256 = if ($kind -ceq 'file') { Get-LowerSha256 -Path $item.FullName } else { $null }
            file_identity_sha256 = if ($kind -ceq 'file') {
                Get-LowerTextSha256 -Value ([DarkReNamerVmNative]::GetFileIdentity($item.FullName))
            } else { $null }
        }
    }
    $journalRoot = Join-Path (Join-Path $LocalAppData 'DarkReNamer') 'journal'
    $journalEntries = @()
    if (Test-Path -LiteralPath $journalRoot -PathType Container) {
        $items = @(Get-ChildItem -LiteralPath $journalRoot -Force | Sort-Object Name)
        if ($items.Count -gt 16) {
            throw 'The production flow journal inventory exceeds its bound.'
        }
        $journalEntries = @($items | ForEach-Object {
            if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The production flow journal inventory contains a reparse point.'
            }
            [ordered]@{
                name = $_.Name
                kind = if ($_.PSIsContainer) { 'directory' } else { 'file' }
                bytes = if ($_.PSIsContainer) { [long]0 } else { [long]$_.Length }
            }
        })
    }
    [ordered]@{
        phase = $Phase
        fixture_entries = @($fixtureEntries)
        journal_entries = @($journalEntries)
    }
}
function Get-VmAutomatedFixtureInventory {
    param([Parameter(Mandatory)][string] $FixtureRoot)

    $root = Get-VmAutomatedCanonicalRootPath -Path $FixtureRoot
    $items = @(Get-ChildItem -LiteralPath $root -Force | Sort-Object Name)
    if ($items.Count -gt 10001) {
        throw 'The VM-Automated fixture inventory exceeds its bound.'
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    @($items | ForEach-Object {
        if (-not $names.Add($_.Name) -or
            $_.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$' -or
            $_.Name.EndsWith('.', [StringComparison]::Ordinal) -or
            $_.Name.EndsWith(' ', [StringComparison]::Ordinal) -or
            $_.Name.Split('.')[0] -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw 'The VM-Automated fixture inventory contains an unsafe name.'
        }
        if ($_.PSIsContainer -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $_ -isnot [IO.FileInfo]) {
            throw 'The VM-Automated fixture inventory requires ordinary files.'
        }
        if ($_.Length -gt 64MB) {
            throw 'The VM-Automated fixture inventory contains an oversized file.'
        }
        $total += $_.Length
        if ($total -gt 512MB) {
            throw 'The VM-Automated fixture inventory exceeds its aggregate size bound.'
        }
        [ordered]@{
            name = $_.Name
            kind = 'file'
            bytes = [long]$_.Length
            content_sha256 = Get-LowerSha256 -Path $_.FullName
            file_identity = Get-FullFileIdentity -Path $_.FullName
        }
    })
}
function Get-VmAutomatedJournalInventory {
    param([Parameter(Mandatory)][string] $LocalAppData)

    $journalRoot = Join-Path (Join-Path $LocalAppData 'DarkReNamer') 'journal'
    if (-not (Test-Path -LiteralPath $journalRoot)) { return @() }
    $root = Get-Item -LiteralPath $journalRoot -Force
    if (-not $root.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The VM-Automated journal root is not an ordinary directory.'
    }
    $items = @(Get-ChildItem -LiteralPath $root.FullName -Force | Sort-Object Name)
    if ($items.Count -gt 256) {
        throw 'The VM-Automated journal inventory exceeds its bound.'
    }
    @($items | ForEach-Object {
        if ($_.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$' -or
            $_.Name.EndsWith('.', [StringComparison]::Ordinal) -or
            $_.Name.EndsWith(' ', [StringComparison]::Ordinal) -or
            $_.Name.Split('.')[0] -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The VM-Automated journal inventory contains an unsafe entry.'
        }
        [ordered]@{
            name = $_.Name
            kind = if ($_.PSIsContainer) { 'directory' } else { 'file' }
            bytes = if ($_.PSIsContainer) { [long]0 } else { [long]$_.Length }
        }
    })
}
function Get-VmAutomatedCheckpoint {
    param(
        [Parameter(Mandatory)][ValidateSet('initial', 'after_cancel', 'after_apply', 'post_close')]
        [string] $Phase,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $LocalAppData
    )
    [ordered]@{
        phase = $Phase
        fixture_entries = @(Get-VmAutomatedFixtureInventory -FixtureRoot $FixtureRoot)
        journal_entries = @(Get-VmAutomatedJournalInventory -LocalAppData $LocalAppData)
    }
}
function Get-VmAutomatedOwnedProcessInventory {
    param([Parameter(Mandatory)][string] $Root)

    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.ExecutablePath -and
        $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object ProcessId | ForEach-Object {
        [ordered]@{
            pid = [int]$_.ProcessId
            session_id = [int]$_.SessionId
            executable_path = [string]$_.ExecutablePath
        }
    })
}
function New-VmAutomatedJournalCleanupObservation {
    param(
        [Parameter(Mandatory)][bool] $Observed,
        [AllowNull()][object[]] $Entries
    )

    if (-not $Observed) { return $null }
    [ordered]@{ entries = @($Entries) }
}
function Get-VmAutomatedRuntimeRootObservation {
    param(
        [Parameter(Mandatory)][string] $Root,
        [ValidateRange(1, 16384)][int] $MaximumEntries = 16384
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return [ordered]@{ exists = $false; entries = @() }
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The VM-Automated runtime root is unsafe.'
    }
    $entries = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootItem.FullName)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The VM-Automated runtime root contains a reparse point.'
            }
            if (-not $item.PSIsContainer -and $item -isnot [IO.FileInfo]) {
                throw 'The VM-Automated runtime root contains a non-ordinary entry.'
            }
            if ($entries.Count -ge $MaximumEntries) {
                throw 'The VM-Automated runtime root entry count exceeds its bound.'
            }
            $entries.Add([ordered]@{
                path = $item.FullName.Substring($rootItem.FullName.Length + 1).Replace('\', '/')
                kind = if ($item.PSIsContainer) { 'directory' } else { 'file' }
            })
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            }
        }
    }
    [ordered]@{ exists = $true; entries = @($entries | Sort-Object path) }
}
