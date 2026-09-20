function Get-ElementObservation {
    param([Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element)

    $bounds = $Element.Current.BoundingRectangle
    [ordered]@{
        automation_id = $Element.Current.AutomationId
        name = $Element.Current.Name
        control_type = $Element.Current.ControlType.ProgrammaticName
        enabled = $Element.Current.IsEnabled
        keyboard_focusable = $Element.Current.IsKeyboardFocusable
        offscreen = $Element.Current.IsOffscreen
        native_handle = $Element.Current.NativeWindowHandle
        bounds = [ordered]@{
            x = $bounds.X
            y = $bounds.Y
            width = $bounds.Width
            height = $bounds.Height
        }
    }
}
function Get-FocusedAcceptanceElement {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Label
    )

    $focused = [Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused -or $focused.Current.ProcessId -ne $Process.Id -or
        $Process.SessionId -ne $ExpectedSession) {
        throw "$Label is not focused in the expected application and desktop session."
    }
    $focused
}
function Get-VmAutomatedControlObservation {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-AutomationBinding -Element $Element -Process $Process -ExpectedSession $ExpectedSession -Label $Label
    $nativeHandle = [IntPtr]$Element.Current.NativeWindowHandle
    $bindingHandle = $nativeHandle
    $ancestor = $Element
    while ($bindingHandle -eq [IntPtr]::Zero -and $null -ne $ancestor) {
        $ancestor = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)
        if ($null -ne $ancestor -and $ancestor.Current.ProcessId -eq $Process.Id) {
            $bindingHandle = [IntPtr]$ancestor.Current.NativeWindowHandle
        }
    }
    $rootHandle = if ($bindingHandle -ne [IntPtr]::Zero) {
        [DarkReNamerVmNative]::GetAncestor($bindingHandle, 2)
    } else { [IntPtr]::Zero }
    $bounds = $Element.Current.BoundingRectangle
    [ordered]@{
        automation_id = [string]$Element.Current.AutomationId
        control_type = [string]$Element.Current.ControlType.ProgrammaticName
        visible = -not [bool]$Element.Current.IsOffscreen
        enabled = [bool]$Element.Current.IsEnabled
        keyboard_focusable = [bool]$Element.Current.IsKeyboardFocusable
        bounds = [ordered]@{
            left = [int][Math]::Round($bounds.Left)
            top = [int][Math]::Round($bounds.Top)
            right = [int][Math]::Round($bounds.Right)
            bottom = [int][Math]::Round($bounds.Bottom)
        }
        pid = [int]$Element.Current.ProcessId
        session_id = [int]$Process.SessionId
        root_hwnd = [long]$rootHandle
    }
}
function New-VmAutomatedFocusReachabilityControl {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Observation,
        [Parameter(Mandatory)][ValidateSet('list', 'left', 'right')][string] $Rail,
        [AllowNull()][object] $RailGroup
    )

    if (-not [bool]$Observation.visible) {
        throw "Raw focus reachability control $($Observation.automation_id) is not visible."
    }
    $expectedReachable = [bool]$Observation.enabled
    [ordered]@{
        automation_id = [string]$Observation.automation_id
        control_type = [string]$Observation.control_type
        visible = [bool]$Observation.visible
        enabled = [bool]$Observation.enabled
        keyboard_focusable = [bool]$Observation.keyboard_focusable
        bounds = $Observation.bounds
        pid = [int]$Observation.pid
        session_id = [int]$Observation.session_id
        root_hwnd = [long]$Observation.root_hwnd
        rail = $Rail
        rail_group = if ($null -eq $RailGroup) { $null } else { [int]$RailGroup }
        expected_reachable = $expectedReachable
        exclusion_reason = if ($expectedReachable) { $null } else { 'disabled' }
    }
}
function Get-VmAutomatedFocusBinding {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Label
    )

    $binding = Get-VmAutomatedControlObservation `
        -Element $Element -Process $Process -ExpectedSession $ExpectedSession -Label $Label
    if (-not $binding.visible -or -not $binding.enabled -or -not $binding.keyboard_focusable) {
        throw "$Label is not an enabled, visible, keyboard-focusable control."
    }
    $binding
}
function Get-VmAutomatedFocusState {
    param(
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $LocalAppData
    )

    [ordered]@{
        fixture_root = Get-VmAutomatedCanonicalRootPath -Path $FixtureRoot
        root_identity = Get-FullFileIdentity -Path $FixtureRoot
        fixture_entries = @(Get-VmAutomatedFixtureInventory -FixtureRoot $FixtureRoot)
        journal_entries = @(Get-VmAutomatedJournalInventory -LocalAppData $LocalAppData)
    }
}
function Assert-VmAutomatedNativeMenuPathSegment {
    param([Parameter(Mandatory)][string] $Segment)

    if ([string]::IsNullOrEmpty($Segment) -or $Segment.Length -gt 240 -or
        $Segment -cin @('.', '..') -or
        $Segment.EndsWith('.', [StringComparison]::Ordinal) -or
        $Segment.EndsWith(' ', [StringComparison]::Ordinal) -or
        $Segment.IndexOfAny([char[]]'<>:"/\|?*') -ge 0 -or
        $Segment.Split('.')[0] -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        throw 'The native menu fixture inventory contains an unsafe path segment.'
    }
    for ($index = 0; $index -lt $Segment.Length; $index++) {
        $character = $Segment[$index]
        if ([int]$character -lt 32) {
            throw 'The native menu fixture inventory contains an unsafe path segment.'
        }
        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $Segment.Length -or
                -not [char]::IsLowSurrogate($Segment[$index + 1])) {
                throw 'The native menu fixture inventory contains invalid UTF-16.'
            }
            $index++
        }
        elseif ([char]::IsLowSurrogate($character)) {
            throw 'The native menu fixture inventory contains invalid UTF-16.'
        }
    }
}
function ConvertTo-VmAutomatedNativeMenuRelativePath {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ParentSegments,
        [Parameter(Mandatory)][string] $Leaf
    )

    $segments = @($ParentSegments) + @($Leaf)
    if ($segments.Count -gt 3) {
        throw 'The native menu fixture inventory exceeds depth three.'
    }
    foreach ($segment in $segments) {
        Assert-VmAutomatedNativeMenuPathSegment -Segment $segment
    }
    $segments -join '/'
}
function Get-VmAutomatedNativeMenuState {
    param(
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $LocalAppData
    )

    $root = Get-VmAutomatedCanonicalRootPath -Path $FixtureRoot
    $rootIdentity = Get-FullFileIdentity -Path $root
    $entries = [Collections.Generic.List[object]]::new()
    $relativePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $bounds = [pscustomobject]@{ total_bytes = [long]0 }
    $visit = {
        param(
            [Parameter(Mandatory)][string] $CurrentPath,
            [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ParentSegments
        )

        $enumerator = [IO.Directory]::EnumerateFileSystemEntries($CurrentPath).GetEnumerator()
        try {
            while ($enumerator.MoveNext()) {
                if ($entries.Count -ge 16) {
                    throw 'The native menu fixture inventory exceeds sixteen entries.'
                }
                $item = Get-Item -LiteralPath ([string]$enumerator.Current) -Force -ErrorAction Stop
                $relativePath = ConvertTo-VmAutomatedNativeMenuRelativePath `
                    -ParentSegments $ParentSegments -Leaf $item.Name
                if (-not $relativePaths.Add($relativePath)) {
                    throw 'The native menu fixture inventory contains a case-alias path.'
                }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'The native menu fixture inventory contains a reparse point.'
                }
                if ($item.PSIsContainer) {
                    $entries.Add([ordered]@{
                        relative_path = $relativePath
                        kind = 'directory'
                        bytes = [long]0
                        content_sha256 = $null
                        file_identity = Get-FullFileIdentity -Path $item.FullName
                    })
                    & $visit `
                        -CurrentPath $item.FullName `
                        -ParentSegments (@($ParentSegments) + @($item.Name))
                    continue
                }
                if ($item -isnot [IO.FileInfo]) {
                    throw 'The native menu fixture inventory requires ordinary files or directories.'
                }
                if ($item.Length -gt 64MB) {
                    throw 'The native menu fixture inventory contains an oversized file.'
                }
                $bounds.total_bytes += [long]$item.Length
                if ($bounds.total_bytes -gt 512MB) {
                    throw 'The native menu fixture inventory exceeds its aggregate size bound.'
                }
                $entries.Add([ordered]@{
                    relative_path = $relativePath
                    kind = 'file'
                    bytes = [long]$item.Length
                    content_sha256 = Get-LowerSha256 -Path $item.FullName
                    file_identity = Get-FullFileIdentity -Path $item.FullName
                })
            }
        }
        finally {
            if ($enumerator -is [IDisposable]) { $enumerator.Dispose() }
        }
    }
    & $visit -CurrentPath $root -ParentSegments ([string[]]@())
    $sortedEntries = [object[]]$entries.ToArray()
    [Array]::Sort($sortedEntries, [Comparison[object]]{
        param($left, $right)
        [StringComparer]::Ordinal.Compare(
            [string]$left.relative_path,
            [string]$right.relative_path
        )
    })
    [ordered]@{
        fixture_root = $root
        root_identity = $rootIdentity
        fixture_entries = @($sortedEntries)
        journal_entries = @(Get-VmAutomatedJournalInventory -LocalAppData $LocalAppData)
    }
}
function Get-VmAutomatedNativeMenuCommandSpec {
    @(
        [ordered]@{ command_id = 32771; menu_path = [int[]]@(0); position = 2; expected_enabled = $false }
        [ordered]@{ command_id = 32772; menu_path = [int[]]@(3,0); position = 0; expected_enabled = $true }
        [ordered]@{ command_id = 32773; menu_path = [int[]]@(3,0); position = 1; expected_enabled = $true }
        [ordered]@{ command_id = 32774; menu_path = [int[]]@(3,0); position = 2; expected_enabled = $true }
        [ordered]@{ command_id = 32775; menu_path = [int[]]@(3,1); position = 0; expected_enabled = $true }
        [ordered]@{ command_id = 32776; menu_path = [int[]]@(3,1); position = 1; expected_enabled = $true }
        [ordered]@{ command_id = 32777; menu_path = [int[]]@(3,1); position = 2; expected_enabled = $true }
        [ordered]@{ command_id = 32778; menu_path = [int[]]@(3,2); position = 0; expected_enabled = $true }
        [ordered]@{ command_id = 32779; menu_path = [int[]]@(3,2); position = 1; expected_enabled = $true }
        [ordered]@{ command_id = 32780; menu_path = [int[]]@(3,2); position = 2; expected_enabled = $true }
        [ordered]@{ command_id = 32781; menu_path = [int[]]@(1); position = 7; expected_enabled = $false }
        [ordered]@{ command_id = 32783; menu_path = [int[]]@(1); position = 0; expected_enabled = $false }
        [ordered]@{ command_id = 65535; menu_path = [int[]]@(1); position = 1; expected_enabled = $false }
        [ordered]@{ command_id = 32784; menu_path = [int[]]@(1); position = 5; expected_enabled = $true }
        [ordered]@{ command_id = 32788; menu_path = [int[]]@(3,3); position = 0; expected_enabled = $true }
        [ordered]@{ command_id = 32789; menu_path = [int[]]@(3,3); position = 1; expected_enabled = $true }
        [ordered]@{ command_id = 32790; menu_path = [int[]]@(3,3); position = 2; expected_enabled = $true }
        [ordered]@{ command_id = 32785; menu_path = [int[]]@(3,4); position = 0; expected_enabled = $true }
        [ordered]@{ command_id = 32786; menu_path = [int[]]@(3,4); position = 1; expected_enabled = $true }
    )
}
function ConvertTo-VmAutomatedMenuPathKey {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $MenuPath)
    if ($MenuPath.Count -eq 0) { return '<root>' }
    ($MenuPath | ForEach-Object { ([int]$_).ToString([Globalization.CultureInfo]::InvariantCulture) }) -join '/'
}
function Test-VmAutomatedMenuPathEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Right
    )
    if ($Left.Count -ne $Right.Count) { return $false }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ([int]$Left[$index] -ne [int]$Right[$index]) { return $false }
    }
    $true
}
function Get-VmAutomatedNativeMenuTree {
    param([Parameter(Mandatory)][IntPtr] $MainWindowHandle)

    $rows = @([DarkReNamerVmAcceptanceNative]::ReadNativeMenuTree($MainWindowHandle))
    if ($rows.Count -lt 1 -or $rows.Count -gt 128) {
        throw 'Native menu tree count is missing or over limit.'
    }
    @($rows | ForEach-Object {
        [ordered]@{
            menu_path = [int[]]@($_.MenuPath)
            position = [int]$_.Position
            item_type = [string]$_.ItemType
            command_id = if ($null -eq $_.CommandId) { $null } else { [int]$_.CommandId }
            state_flags = [int]$_.StateFlags
            enabled = [bool]$_.Enabled
            checked = [bool]$_.Checked
        }
    })
}
function Assert-VmAutomatedNativeMenuTree {
    param([Parameter(Mandatory)][object[]] $MenuTree)

    if ($MenuTree.Count -lt 1 -or $MenuTree.Count -gt 128) {
        throw 'Native menu tree count is missing or over limit.'
    }
    $positions = @{}
    $rowsBySlot = @{}
    $commandIds = [Collections.Generic.HashSet[int]]::new()
    $expectedKeys = @(
        'menu_path','position','item_type','command_id','state_flags','enabled','checked'
    )
    foreach ($row in $MenuTree) {
        if ($row -isnot [Collections.IDictionary]) {
            throw 'Native menu tree row is malformed.'
        }
        $keys = @($row.Keys | ForEach-Object { [string]$_ })
        $path = @($row.menu_path)
        if ($keys.Count -ne $expectedKeys.Count -or
            @(Compare-Object -CaseSensitive $expectedKeys $keys).Count -ne 0 -or
            $row.menu_path -isnot [array] -or
            $path.Count -gt 2 -or @($path | Where-Object {
            $_ -isnot [byte] -and $_ -isnot [int16] -and $_ -isnot [int32] -and $_ -isnot [int64]
        }).Count -ne 0 -or @($path | Where-Object { $_ -lt 0 -or $_ -gt 31 }).Count -ne 0 -or
            $row.position -isnot [int] -or $row.position -lt 0 -or $row.position -gt 31 -or
            $row.item_type -cnotin @('command','submenu','separator') -or
            $row.state_flags -isnot [int] -or $row.state_flags -lt 0 -or $row.state_flags -gt 255 -or
            $row.enabled -isnot [bool] -or $row.checked -isnot [bool] -or
            $row.enabled -ne (($row.state_flags -band 0x3) -eq 0) -or
            $row.checked -ne (($row.state_flags -band 0x8) -ne 0)) {
            throw 'Native menu tree row is malformed.'
        }
        if ($row.item_type -ceq 'command') {
            if ($row.command_id -isnot [int] -or $row.command_id -le 0 -or
                -not $commandIds.Add($row.command_id)) {
                throw 'Native menu command identity is missing or duplicated.'
            }
        }
        elseif ($null -ne $row.command_id) {
            throw 'Native menu non-command unexpectedly has a command identity.'
        }
        $key = ConvertTo-VmAutomatedMenuPathKey -MenuPath $path
        if (-not $positions.ContainsKey($key)) {
            $positions[$key] = [Collections.Generic.List[int]]::new()
        }
        $positions[$key].Add([int]$row.position)
        $slot = "$key`:$([int]$row.position)"
        if ($rowsBySlot.ContainsKey($slot)) {
            throw 'Native menu position is duplicated.'
        }
        $rowsBySlot[$slot] = $row
    }
    if (-not $positions.ContainsKey('<root>')) {
        throw 'Native menu tree is missing its menu bar.'
    }
    foreach ($key in @($positions.Keys)) {
        $actual = @($positions[$key] | Sort-Object)
        for ($index = 0; $index -lt $actual.Count; $index++) {
            if ($actual[$index] -ne $index) {
                throw 'Native menu positions are not complete and contiguous.'
            }
        }
    }
    foreach ($row in $MenuTree) {
        $path = @($row.menu_path)
        if ($path.Count -gt 0) {
            $parentKey = if ($path.Count -eq 1) {
                '<root>'
            }
            else {
                ConvertTo-VmAutomatedMenuPathKey -MenuPath @($path[0..($path.Count - 2)])
            }
            $parentSlot = "$parentKey`:$([int]$path[-1])"
            if (-not $rowsBySlot.ContainsKey($parentSlot) -or
                $rowsBySlot[$parentSlot].item_type -cne 'submenu') {
                throw 'Native menu path is not owned by its parent submenu.'
            }
        }
        if ($row.item_type -ceq 'submenu') {
            $childPath = @($path) + @([int]$row.position)
            if (-not $positions.ContainsKey(
                    (ConvertTo-VmAutomatedMenuPathKey -MenuPath $childPath)
                )) {
                throw 'Native menu submenu has no bounded child inventory.'
            }
        }
    }
    $required = @(Get-VmAutomatedNativeMenuCommandSpec)
    foreach ($spec in $required) {
        $matches = @($MenuTree | Where-Object {
            $_.item_type -ceq 'command' -and $_.command_id -eq $spec.command_id -and
            $_.position -eq $spec.position -and
            (Test-VmAutomatedMenuPathEqual -Left @($_.menu_path) -Right @($spec.menu_path))
        })
        if ($matches.Count -ne 1 -or $matches[0].enabled -ne $spec.expected_enabled) {
            throw "Native menu command $($spec.command_id) path or enabled state differs from the fixed fixture."
        }
    }
    $required
}
function Get-VmAutomatedHiddenRailControls {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][object[]] $MenuTree
    )

    Initialize-AcceptanceNativeOpen
    $mainHandle = [IntPtr]$Application.main_handle
    $rootHandle = [DarkReNamerVmNative]::GetAncestor($mainHandle, 2)
    if ($rootHandle -ne $mainHandle -or $Application.process.SessionId -ne $ExpectedSession) {
        throw 'Native menu-only workbench ownership is invalid.'
    }
    $seenHandles = [Collections.Generic.HashSet[long]]::new()
    @(
        foreach ($spec in @(Assert-VmAutomatedNativeMenuTree -MenuTree $MenuTree)) {
            $handle = [DarkReNamerAcceptanceNativeOpen]::GetDlgItem($mainHandle, [int]$spec.command_id)
            if ($handle -eq [IntPtr]::Zero -or
                -not [DarkReNamerAcceptanceNativeOpen]::IsWindow($handle) -or
                [DarkReNamerAcceptanceNativeOpen]::GetParent($handle) -ne $mainHandle -or
                [DarkReNamerAcceptanceNativeOpen]::GetDlgCtrlID($handle) -ne $spec.command_id -or
                -not $seenHandles.Add($handle.ToInt64())) {
                throw "Native hidden rail $($spec.command_id) is missing, misbound, or duplicated."
            }
            $processId = [uint32]0
            if ([DarkReNamerAcceptanceNativeOpen]::GetWindowThreadProcessId($handle, [ref]$processId) -eq 0 -or
                $processId -ne $Application.process.Id) {
                throw "Native hidden rail $($spec.command_id) belongs to another process."
            }
            $className = [Text.StringBuilder]::new(32)
            if ([DarkReNamerAcceptanceNativeOpen]::GetClassName($handle, $className, $className.Capacity) -le 0 -or
                $className.ToString() -cne 'Button' -or
                [DarkReNamerAcceptanceNativeOpen]::IsWindowVisible($handle)) {
                throw "Native hidden rail $($spec.command_id) class or visibility is invalid."
            }
            $menuRow = @($MenuTree | Where-Object { $_.command_id -eq $spec.command_id })
            $enabled = [DarkReNamerAcceptanceNativeOpen]::IsWindowEnabled($handle)
            if ($menuRow.Count -ne 1 -or $enabled -ne [bool]$menuRow[0].enabled) {
                throw "Native hidden rail $($spec.command_id) enabled state differs from its menu command."
            }
            $rect = [DarkReNamerAcceptanceNativeOpen+Rect]::new()
            if (-not [DarkReNamerAcceptanceNativeOpen]::GetWindowRect($handle, [ref]$rect) -or
                $rect.Right -lt $rect.Left -or $rect.Bottom -lt $rect.Top) {
                throw "Native hidden rail $($spec.command_id) bounds are invalid."
            }
            [ordered]@{
                command_id = [int]$spec.command_id
                hwnd = [long]$handle
                control_id = [int][DarkReNamerAcceptanceNativeOpen]::GetDlgCtrlID($handle)
                window_class = $className.ToString()
                visible = $false
                enabled = [bool]$enabled
                pid = [int]$processId
                session_id = [int]$Application.process.SessionId
                parent_hwnd = [long]$mainHandle
                root_hwnd = [long]$rootHandle
                rect = [ordered]@{
                    left = [int]$rect.Left; top = [int]$rect.Top
                    right = [int]$rect.Right; bottom = [int]$rect.Bottom
                }
            }
        }
    )
}
function Get-VmAutomatedVisibleMenuPopups {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $OpenMenuPaths,
        [Parameter(Mandatory)][Collections.IDictionary] $PathHandles
    )

    if ($OpenMenuPaths.Count -gt 2 -or $Process.SessionId -ne $ExpectedSession) {
        throw 'Native menu popup request is invalid or outside the expected session.'
    }
    $native = @([DarkReNamerVmAcceptanceNative]::ReadVisibleNativeMenuPopups([uint32]$Process.Id))
    if ($native.Count -ne $OpenMenuPaths.Count) {
        throw 'Native menu popup count differs from the keyboard traversal state.'
    }
    $liveHandles = [Collections.Generic.HashSet[long]]::new()
    foreach ($row in $native) { [void]$liveHandles.Add([long]$row.Handle) }
    foreach ($key in @($PathHandles.Keys)) {
        if (-not $liveHandles.Contains([long]$PathHandles[$key])) {
            $PathHandles.Remove($key)
        }
    }
    $unassignedRows = [Collections.Generic.List[object]]::new()
    foreach ($row in $native) {
        if (@($PathHandles.Values | Where-Object { [long]$_ -eq [long]$row.Handle }).Count -eq 0) {
            $unassignedRows.Add($row)
        }
    }
    $unassignedPaths = [Collections.Generic.List[object]]::new()
    foreach ($path in $OpenMenuPaths) {
        $key = ConvertTo-VmAutomatedMenuPathKey -MenuPath @($path)
        if (-not $PathHandles.Contains($key)) { $unassignedPaths.Add([int[]]@($path)) }
    }
    if ($unassignedRows.Count -ne $unassignedPaths.Count -or $unassignedRows.Count -gt 1) {
        throw 'Native menu popup identities changed ambiguously during traversal.'
    }
    if ($unassignedRows.Count -eq 1) {
        $PathHandles[(ConvertTo-VmAutomatedMenuPathKey -MenuPath @($unassignedPaths[0]))] =
            [long]$unassignedRows[0].Handle
    }
    @(
        foreach ($path in $OpenMenuPaths) {
            $key = ConvertTo-VmAutomatedMenuPathKey -MenuPath @($path)
            $handle = [long]$PathHandles[$key]
            $matches = @($native | Where-Object { [long]$_.Handle -eq $handle })
            if ($matches.Count -ne 1 -or $matches[0].ClassName -cne '#32768' -or
                $matches[0].ProcessId -ne $Process.Id -or
                $matches[0].Right -le $matches[0].Left -or
                $matches[0].Bottom -le $matches[0].Top) {
                throw 'Native menu popup ownership, class, or bounds are invalid.'
            }
            [ordered]@{
                menu_path = [int[]]@($path)
                hwnd = $handle
                pid = [int]$matches[0].ProcessId
                session_id = [int]$Process.SessionId
                window_class = [string]$matches[0].ClassName
                rect = [ordered]@{
                    left = [int]$matches[0].Left; top = [int]$matches[0].Top
                    right = [int]$matches[0].Right; bottom = [int]$matches[0].Bottom
                }
            }
        }
    )
}
function Get-VmAutomatedMenuHighlight {
    param(
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $OpenMenuPaths,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Popups
    )

    $native = @([DarkReNamerVmAcceptanceNative]::ReadHighlightedNativeMenuItems($MainWindowHandle))
    $mainRect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($MainWindowHandle, [ref]$mainRect)) {
        throw 'Native menu highlight could not bind the candidate window bounds.'
    }
    ConvertTo-VmAutomatedMenuHighlight `
        -NativeHighlights $native -OpenMenuPaths $OpenMenuPaths -Popups $Popups `
        -MainRect $mainRect
}
function ConvertTo-VmAutomatedMenuHighlight {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $NativeHighlights,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $OpenMenuPaths,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Popups,
        [Parameter(Mandatory)][object] $MainRect
    )

    $native = @($NativeHighlights)
    if ($OpenMenuPaths.Count -eq 0) {
        if ($Popups.Count -ne 0) { throw 'Closed native menu paths retain popup windows.' }
        if ($native.Count -eq 0) { return $null }
        if ($native.Count -ne 1 -or @($native[0].MenuPath).Count -ne 0 -or
            $null -ne $native[0].CommandId) {
            $observed = $native | ConvertTo-Json -Compress -Depth 4
            throw "Closed native popups retained an ambiguous highlight: $observed"
        }
        $matches = @($native)
        $bounds = $MainRect
    }
    else {
        $deepest = $OpenMenuPaths[0]
        foreach ($path in $OpenMenuPaths) {
            if (@($path).Count -gt @($deepest).Count) { $deepest = $path }
        }
        $matches = @($native | Where-Object {
            Test-VmAutomatedMenuPathEqual -Left @($_.MenuPath) -Right @($deepest)
        })
        if ($matches.Count -eq 0) { return $null }
        $popup = @($Popups | Where-Object {
            Test-VmAutomatedMenuPathEqual -Left @($_.menu_path) -Right @($deepest)
        })
        if ($popup.Count -ne 1) { throw 'Native menu highlight has no exact owned popup.' }
        $bounds = $popup[0].rect
    }
    if ($matches.Count -ne 1 -or (($matches[0].StateFlags -band 0x80) -eq 0) -or
        $matches[0].Right -le $matches[0].Left -or $matches[0].Bottom -le $matches[0].Top) {
        throw 'Native menu highlight is duplicated, unmarked, or has invalid bounds.'
    }
    if ($matches[0].Left -lt $bounds.left -or
        $matches[0].Top -lt $bounds.top -or
        $matches[0].Right -gt $bounds.right -or
        $matches[0].Bottom -gt $bounds.bottom) {
        throw 'Native menu highlight is outside its exact owned window.'
    }
    [ordered]@{
        menu_path = [int[]]@($matches[0].MenuPath)
        position = [int]$matches[0].Position
        command_id = if ($null -eq $matches[0].CommandId) { $null } else { [int]$matches[0].CommandId }
        item_rect = [ordered]@{
            left = [int]$matches[0].Left; top = [int]$matches[0].Top
            right = [int]$matches[0].Right; bottom = [int]$matches[0].Bottom
        }
        state_flags = [int]$matches[0].StateFlags
    }
}
function Get-VmAutomatedMenuEndpoint {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $List,
        [Parameter(Mandatory)][int] $ExpectedSession
    )

    $popups = @([DarkReNamerVmAcceptanceNative]::ReadVisibleNativeMenuPopups(
        [uint32]$Application.process.Id
    ))
    if ($popups.Count -ne 0) { throw 'Native menu endpoint retained an open popup.' }
    $foreground = Get-ForegroundObservation
    $mainHandle = [long]$Application.main.Current.NativeWindowHandle
    if ($foreground.hwnd -ne $mainHandle -or
        $foreground.process_id -ne $Application.process.Id -or
        $foreground.session_id -ne $ExpectedSession -or
        $foreground.window_class -cne 'DarkReNamerWindow') {
        throw 'Native menu endpoint foreground differs from the candidate workbench.'
    }
    $focused = Get-FocusedAcceptanceElement `
        -Process $Application.process -ExpectedSession $ExpectedSession `
        -Label 'native menu endpoint focus'
    $binding = Get-VmAutomatedFocusBinding `
        -Element $focused -Process $Application.process -ExpectedSession $ExpectedSession `
        -Label 'native menu endpoint focus'
    if ($binding.automation_id -cne '1000' -or
        $binding.root_hwnd -ne $mainHandle -or
        [IntPtr]$List.Current.NativeWindowHandle -ne [IntPtr]$focused.Current.NativeWindowHandle) {
        throw 'Native menu endpoint focus is not the exact file list.'
    }
    [ordered]@{
        foreground = $foreground
        focused = $binding
        open_menu_paths = @()
        popups = @()
    }
}
function Invoke-VmAutomatedMenuKey {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][ValidateSet('alt-f','alt-e','alt-t','down','right','left','escape')][string] $KeyAction,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $OpenMenuPaths,
        [Parameter(Mandatory)][Collections.IDictionary] $PathHandles,
        [AllowNull()][object] $PreviousHighlight,
        [Parameter(Mandatory)][ValidateRange(1, 128)][int] $Sequence
    )

    $virtualKeys = @(switch ($KeyAction) {
        'alt-f' { [int[]]@(0x12, 0x46) }
        'alt-e' { [int[]]@(0x12, 0x45) }
        'alt-t' { [int[]]@(0x12, 0x54) }
        'down' { [int[]]@(0x28) }
        'right' { [int[]]@(0x27) }
        'left' { [int[]]@(0x25) }
        'escape' { [int[]]@(0x1B) }
    })
    if ($KeyAction.StartsWith('alt-', [StringComparison]::Ordinal)) {
        Send-AcceptanceChord `
            -Process $Application.process -ExpectedSession $ExpectedSession `
            -Modifier ([uint16]$virtualKeys[0]) -VirtualKey ([uint16]$virtualKeys[1]) `
            -Label "native menu $KeyAction"
    }
    else {
        Send-AcceptanceTap `
            -Process $Application.process -ExpectedSession $ExpectedSession `
            -VirtualKey ([uint16]$virtualKeys[0]) -Label "native menu $KeyAction"
    }
    $popups = $null
    $highlight = $null
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 50
        $actual = @([DarkReNamerVmAcceptanceNative]::ReadVisibleNativeMenuPopups(
            [uint32]$Application.process.Id
        ))
        if ($actual.Count -eq $OpenMenuPaths.Count) {
            $popups = @(Get-VmAutomatedVisibleMenuPopups `
                -Process $Application.process -ExpectedSession $ExpectedSession `
                -OpenMenuPaths $OpenMenuPaths -PathHandles $PathHandles)
            $highlight = Get-VmAutomatedMenuHighlight `
                -MainWindowHandle ([IntPtr]$Application.main.Current.NativeWindowHandle) `
                -OpenMenuPaths $OpenMenuPaths -Popups $popups
            if ($KeyAction -ceq 'down' -and (
                $null -eq $highlight -or
                ($null -ne $PreviousHighlight -and
                    $highlight.position -eq $PreviousHighlight.position -and
                    (Test-VmAutomatedMenuPathEqual `
                        -Left @($highlight.menu_path) -Right @($PreviousHighlight.menu_path))))) {
                $popups = $null
                continue
            }
            break
        }
    }
    if ($null -eq $popups) { throw "Native menu $KeyAction did not reach its expected popup state." }
    $foreground = Get-ForegroundObservation
    $mainHandle = [long]$Application.main.Current.NativeWindowHandle
    if ($foreground.hwnd -ne $mainHandle -or
        $foreground.process_id -ne $Application.process.Id -or
        $foreground.session_id -ne $ExpectedSession -or
        $foreground.window_class -cne 'DarkReNamerWindow') {
        throw "Native menu $KeyAction lost the exact candidate foreground binding."
    }
    [ordered]@{
        sequence = $Sequence
        input = $KeyAction
        virtual_keys = $virtualKeys
        open_menu_paths = [object[]]@($OpenMenuPaths | ForEach-Object {
            ,([int[]]@($_))
        })
        highlighted = $highlight
        popups = $popups
        foreground = $foreground
    }
}
function Assert-VmAutomatedMenuHighlightBinding {
    param(
        [AllowNull()][object] $Highlight,
        [Parameter(Mandatory)][object[]] $MenuTree
    )

    if ($null -eq $Highlight) { return }
    $matches = @($MenuTree | Where-Object {
        $_.position -eq $Highlight.position -and
        (Test-VmAutomatedMenuPathEqual -Left @($_.menu_path) -Right @($Highlight.menu_path))
    })
    if ($matches.Count -ne 1 -or
        $matches[0].command_id -ne $Highlight.command_id -or
        (($Highlight.state_flags -band 0x80) -eq 0) -or
        (($Highlight.state_flags -band 0x7F) -ne ($matches[0].state_flags -band 0x7F))) {
        throw 'Native menu highlight differs from the immutable menu tree row.'
    }
}
function Invoke-VmAutomatedNativeMenuOnlyReachability {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $List,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][object[]] $MenuTree
    )

    $mainHandle = [IntPtr]$Application.main.Current.NativeWindowHandle
    $List.SetFocus()
    [void][DarkReNamerVmNative]::SetForegroundWindow($mainHandle)
    Assert-AcceptanceForegroundBinding `
        -Process $Application.process -ExpectedSession $ExpectedSession `
        -MainWindowHandle $mainHandle -RequireMainWindow
    $initial = Get-VmAutomatedMenuEndpoint `
        -Application $Application -List $List -ExpectedSession $ExpectedSession
    $stateBefore = Get-VmAutomatedNativeMenuState `
        -FixtureRoot $FixtureRoot -LocalAppData $env:LOCALAPPDATA
    $events = [Collections.Generic.List[object]]::new()
    $visited = [Collections.Generic.HashSet[int]]::new()
    $navigation = [pscustomobject]@{ sequence = 0 }
    $addEvent = {
        param(
            [string] $KeyAction,
            [object[]] $OpenMenuPaths,
            [Collections.IDictionary] $PathHandles
        )
        if ($events.Count -ge 128) {
            throw 'Native menu keyboard event count exceeds its bound.'
        }
        $navigation.sequence++
        $previousHighlight = if ($events.Count -eq 0) {
            $null
        }
        else {
            $events[$events.Count - 1].highlighted
        }
        $event = Invoke-VmAutomatedMenuKey `
            -Application $Application -ExpectedSession $ExpectedSession `
            -KeyAction $KeyAction -OpenMenuPaths $OpenMenuPaths `
            -PathHandles $PathHandles -PreviousHighlight $previousHighlight `
            -Sequence $navigation.sequence
        Assert-VmAutomatedMenuHighlightBinding `
            -Highlight $event.highlighted -MenuTree $MenuTree
        if ($null -ne $event.highlighted -and $null -ne $event.highlighted.command_id) {
            $required = @(Get-VmAutomatedNativeMenuCommandSpec | Where-Object {
                $_.command_id -eq $event.highlighted.command_id -and $_.expected_enabled
            })
            if ($required.Count -eq 1) { [void]$visited.Add([int]$event.highlighted.command_id) }
        }
        $events.Add($event)
        $event
    }
    $visitSession = {
        param(
            [string] $OpenInput,
            [int] $RootPosition,
            [AllowNull()][object] $ChildPosition,
            [int[]] $RequiredCommandIds
        )
        $pathHandles = @{}
        $paths = [Collections.Generic.List[object]]::new()
        $paths.Add([int[]]@($RootPosition))
        $current = & $addEvent $OpenInput $paths.ToArray() $pathHandles
        if ($null -ne $ChildPosition) {
            $selected = $false
            for ($attempt = 0; $attempt -lt 16; $attempt++) {
                if ($null -ne $current.highlighted -and
                    $null -eq $current.highlighted.command_id -and
                    $current.highlighted.position -eq [int]$ChildPosition -and
                    (Test-VmAutomatedMenuPathEqual `
                        -Left @($current.highlighted.menu_path) -Right @($RootPosition))) {
                    $selected = $true
                    break
                }
                $current = & $addEvent 'down' $paths.ToArray() $pathHandles
            }
            if (-not $selected) {
                throw "Native Transform submenu $ChildPosition was not reached by bounded Down input."
            }
            $paths.Add([int[]]@($RootPosition, [int]$ChildPosition))
            $current = & $addEvent 'right' $paths.ToArray() $pathHandles
        }
        for ($attempt = 0; $attempt -lt 32; $attempt++) {
            $missing = @($RequiredCommandIds | Where-Object { -not $visited.Contains($_) })
            if ($missing.Count -eq 0) { break }
            $current = & $addEvent 'down' $paths.ToArray() $pathHandles
        }
        $missing = @($RequiredCommandIds | Where-Object { -not $visited.Contains($_) })
        if ($missing.Count -ne 0) {
            throw "Native menu keyboard traversal missed enabled commands: $($missing -join ', ')."
        }
        while ($paths.Count -gt 0) {
            $paths.RemoveAt($paths.Count - 1)
            $current = & $addEvent 'escape' $paths.ToArray() $pathHandles
        }
        if ($null -eq $current.highlighted -or
            @($current.highlighted.menu_path).Count -ne 0 -or
            $current.highlighted.position -ne $RootPosition -or
            $null -ne $current.highlighted.command_id) {
            throw 'Closing the root popup did not return to its exact menu-bar item.'
        }
        $current = & $addEvent 'escape' $paths.ToArray() $pathHandles
        if ($null -ne $current.highlighted) {
            throw 'The second Escape did not leave the candidate menu bar.'
        }
    }

    & $visitSession 'alt-f' 0 $null ([int[]]@())
    & $visitSession 'alt-e' 1 $null ([int[]]@(32784))
    & $visitSession 'alt-t' 3 0 ([int[]]@(32772,32773,32774))
    & $visitSession 'alt-t' 3 1 ([int[]]@(32775,32776,32777))
    & $visitSession 'alt-t' 3 2 ([int[]]@(32778,32779,32780))
    & $visitSession 'alt-t' 3 3 ([int[]]@(32788,32789,32790))
    & $visitSession 'alt-t' 3 4 ([int[]]@(32785,32786))

    $expectedEnabled = @(Get-VmAutomatedNativeMenuCommandSpec | Where-Object expected_enabled |
        ForEach-Object command_id)
    $missingAll = @($expectedEnabled | Where-Object { -not $visited.Contains($_) })
    if ($missingAll.Count -ne 0 -or $visited.Count -ne 15) {
        throw "Native menu keyboard traversal did not cover the exact enabled commands: $($missingAll -join ', ')."
    }
    $final = Get-VmAutomatedMenuEndpoint `
        -Application $Application -List $List -ExpectedSession $ExpectedSession
    $stateAfter = Get-VmAutomatedNativeMenuState `
        -FixtureRoot $FixtureRoot -LocalAppData $env:LOCALAPPDATA
    if (($stateBefore | ConvertTo-Json -Compress -Depth 12) -cne
        ($stateAfter | ConvertTo-Json -Compress -Depth 12)) {
        throw 'Native menu keyboard traversal changed the fixture or journal state.'
    }
    [ordered]@{
        schema_version = 1
        variant = 'native-menu-only'
        initial = $initial
        events = $events.ToArray()
        final = $final
        state_before = $stateBefore
        state_after = $stateAfter
    }
}
function Invoke-VmAutomatedFocusReachability {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $List,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $specs = @(
        [ordered]@{ automation_id = '1000'; rail = 'list'; rail_group = $null }
        [ordered]@{ automation_id = '32771'; rail = 'left'; rail_group = 0 }
        [ordered]@{ automation_id = '32772'; rail = 'left'; rail_group = 1 }
        [ordered]@{ automation_id = '32773'; rail = 'left'; rail_group = 1 }
        [ordered]@{ automation_id = '32774'; rail = 'left'; rail_group = 1 }
        [ordered]@{ automation_id = '32775'; rail = 'left'; rail_group = 2 }
        [ordered]@{ automation_id = '32776'; rail = 'left'; rail_group = 2 }
        [ordered]@{ automation_id = '32777'; rail = 'left'; rail_group = 2 }
        [ordered]@{ automation_id = '32778'; rail = 'left'; rail_group = 3 }
        [ordered]@{ automation_id = '32779'; rail = 'left'; rail_group = 3 }
        [ordered]@{ automation_id = '32780'; rail = 'left'; rail_group = 3 }
        [ordered]@{ automation_id = '32781'; rail = 'right'; rail_group = 0 }
        [ordered]@{ automation_id = '32783'; rail = 'right'; rail_group = 1 }
        [ordered]@{ automation_id = '65535'; rail = 'right'; rail_group = 1 }
        [ordered]@{ automation_id = '32784'; rail = 'right'; rail_group = 1 }
        [ordered]@{ automation_id = '32788'; rail = 'right'; rail_group = 2 }
        [ordered]@{ automation_id = '32789'; rail = 'right'; rail_group = 2 }
        [ordered]@{ automation_id = '32790'; rail = 'right'; rail_group = 2 }
        [ordered]@{ automation_id = '32785'; rail = 'right'; rail_group = 3 }
        [ordered]@{ automation_id = '32786'; rail = 'right'; rail_group = 3 }
    )
    $mainHandle = [long]$Application.main_handle
    $controls = [Collections.Generic.List[object]]::new()
    foreach ($spec in $specs) {
        $element = if ($spec.rail -ceq 'list') {
            $List
        }
        else {
            Find-UniqueAutomationElement `
                -Root $Application.main -Process $Application.process `
                -ExpectedSession $ExpectedSession -AutomationId $spec.automation_id `
                -ControlType ([Windows.Automation.ControlType]::Button) `
                -TimeoutSeconds $TimeoutSeconds `
                -Label "raw focus reachability command $($spec.automation_id)" `
                -RequireWindowHandle
        }
        $observation = Get-VmAutomatedControlObservation `
            -Element $element -Process $Application.process -ExpectedSession $ExpectedSession `
            -Label "raw focus reachability control $($spec.automation_id)"
        $controls.Add((New-VmAutomatedFocusReachabilityControl `
            -Observation $observation -Rail $spec.rail -RailGroup $spec.rail_group))
    }

    $stateBefore = Get-VmAutomatedFocusState `
        -FixtureRoot $FixtureRoot -LocalAppData $env:LOCALAPPDATA
    $focused = Get-FocusedAcceptanceElement `
        -Process $Application.process -ExpectedSession $ExpectedSession `
        -Label 'raw focus reachability initial control'
    $initial = Get-VmAutomatedFocusBinding `
        -Element $focused -Process $Application.process -ExpectedSession $ExpectedSession `
        -Label 'raw focus reachability initial control'
    $navigation = [ordered]@{ current = $focused }
    $transitions = [Collections.Generic.List[object]]::new()
    $step = {
        param([string] $NavigationInput, [uint16] $VirtualKey)

        if ($transitions.Count -ge 256) {
            throw 'Raw focus reachability transition count exceeds its bound.'
        }
        $from = Get-VmAutomatedFocusBinding `
            -Element $navigation.current -Process $Application.process `
            -ExpectedSession $ExpectedSession -Label 'raw focus transition source'
        $next = Invoke-AcceptanceNavigationStep `
            -Process $Application.process -ExpectedSession $ExpectedSession `
            -VirtualKey $VirtualKey -Label "raw focus $NavigationInput navigation"
        $to = Get-VmAutomatedFocusBinding `
            -Element $next -Process $Application.process `
            -ExpectedSession $ExpectedSession -Label 'raw focus transition destination'
        $transitions.Add([ordered]@{
            sequence = [int]$transitions.Count + 1
            input = $NavigationInput
            from = $from
            to = $to
        })
        $navigation.current = $next
        $next
    }
    $moveToScope = {
        param([string[]] $AutomationIds, [string] $Label)

        for ($attempt = 0; $attempt -lt 32; $attempt++) {
            if ($AutomationIds -ccontains [string]$navigation.current.Current.AutomationId) {
                return
            }
            [void](& $step 'tab' 0x09)
        }
        throw "Raw keyboard focus did not reach the $Label scope."
    }

    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($scope in @('list', 'left', 'right')) {
        $requiredIds = @($controls | Where-Object {
            $_.rail -ceq $scope -and $_.expected_reachable
        } | ForEach-Object automation_id)
        if ($requiredIds.Count -eq 0) { continue }
        & $moveToScope $requiredIds $scope
        $currentId = [string]$navigation.current.Current.AutomationId
        if (-not $visited.Add($currentId) -and $scope -cne 'list') {
            throw "Raw keyboard focus revisited $currentId before traversing the $scope rail."
        }
        if ($scope -cne 'list') {
            while (@($requiredIds | Where-Object { -not $visited.Contains($_) }).Count -gt 0) {
                [void](& $step 'down' 0x28)
                $currentId = [string]$navigation.current.Current.AutomationId
                if ($requiredIds -cnotcontains $currentId) {
                    throw "Raw keyboard focus left the $scope rail during arrow navigation."
                }
                if (-not $visited.Add($currentId)) {
                    throw "Raw keyboard focus cycled before visiting every enabled $scope command."
                }
            }
        }
    }
    & $moveToScope @('1000') 'list'

    $requiredAll = @($controls | Where-Object expected_reachable | ForEach-Object automation_id)
    $missing = @($requiredAll | Where-Object { -not $visited.Contains($_) })
    if ($missing.Count -ne 0 -or $visited.Count -ne $requiredAll.Count) {
        throw "Raw keyboard focus did not visit the exact required controls: $($missing -join ', ')."
    }
    $final = Get-VmAutomatedFocusBinding `
        -Element $navigation.current -Process $Application.process -ExpectedSession $ExpectedSession `
        -Label 'raw focus reachability final control'
    $stateAfter = Get-VmAutomatedFocusState `
        -FixtureRoot $FixtureRoot -LocalAppData $env:LOCALAPPDATA
    if (($stateBefore | ConvertTo-Json -Compress -Depth 12) -cne
        ($stateAfter | ConvertTo-Json -Compress -Depth 12)) {
        throw 'Raw keyboard focus traversal changed the fixture or journal state.'
    }
    [ordered]@{
        schema_version = 1
        input_method = 'keyboard'
        initial = $initial
        transitions = $transitions.ToArray()
        final = $final
        controls = $controls.ToArray()
        state_before = $stateBefore
        state_after = $stateAfter
    }
}
function Get-VmAutomatedKeyboardEventStart {
    param(
        [Parameter(Mandatory)][ValidateSet('escape', 'enter')][string] $Action,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Confirmation,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $ExpectedAutomationId,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $targetHandle = [IntPtr]$Confirmation.Current.NativeWindowHandle
    Assert-AutomationBinding -Element $Confirmation -Process $Process -ExpectedSession $ExpectedSession -Label "$Action confirmation target" -RequireWindowHandle
    $targetProcessId = [uint32]0
    if ([DarkReNamerVmNative]::GetWindowThreadProcessId($targetHandle, [ref]$targetProcessId) -eq 0) {
        throw "$Action confirmation target process is unavailable."
    }
    $targetClass = [Text.StringBuilder]::new(128)
    [void][DarkReNamerVmNative]::GetClassName($targetHandle, $targetClass, $targetClass.Capacity)
    $focusDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $focused = Get-FocusedAcceptanceElement -Process $Process -ExpectedSession $ExpectedSession -Label "$Action confirmation control"
        if ($focused.Current.AutomationId -ceq $ExpectedAutomationId) { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $focusDeadline)
    $focusedHandle = [IntPtr]$focused.Current.NativeWindowHandle
    $focusedClass = [Text.StringBuilder]::new(128)
    [void][DarkReNamerVmNative]::GetClassName($focusedHandle, $focusedClass, $focusedClass.Capacity)
    $rootHandle = [DarkReNamerVmNative]::GetAncestor($focusedHandle, 2)
    $foreground = Get-ForegroundObservation
    $event = [ordered]@{
        action = $Action
        input_method = 'keyboard'
        target = [ordered]@{
            hwnd = [long]$targetHandle
            pid = [int]$targetProcessId
            session_id = [int]$Process.SessionId
            class = $targetClass.ToString()
        }
        focused_before = [ordered]@{
            hwnd = [long]$focusedHandle
            pid = [int]$focused.Current.ProcessId
            session_id = [int]$Process.SessionId
            class = $focusedClass.ToString()
            automation_id = [string]$focused.Current.AutomationId
            control_type = [string]$focused.Current.ControlType.ProgrammaticName
            root_hwnd = [long]$rootHandle
        }
        foreground_before = $foreground
        foreground_after = $null
    }
    if ($event.target.class -cne '#32770' -or
        $event.target.pid -ne $Process.Id -or
        $event.target.session_id -ne $ExpectedSession -or
        $event.focused_before.class -cne 'Button' -or
        $event.focused_before.automation_id -cne $ExpectedAutomationId -or
        $event.focused_before.control_type -cne 'ControlType.Button' -or
        $event.focused_before.root_hwnd -ne $event.target.hwnd -or
        $foreground.hwnd -ne $event.target.hwnd -or
        $foreground.process_id -ne $Process.Id -or
        $foreground.session_id -ne $ExpectedSession -or
        $foreground.window_class -cne '#32770') {
        throw "$Action keyboard target or focus binding is invalid."
    }
    $event
}
function Complete-VmAutomatedKeyboardEvent {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Event,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $foreground = Get-ForegroundObservation
        if ($foreground.hwnd -eq [long]$MainWindowHandle -and
            $foreground.process_id -eq $Process.Id -and
            $foreground.session_id -eq $ExpectedSession -and
            $foreground.window_class -ceq 'DarkReNamerWindow') {
            $Event.foreground_after = $foreground
            return
        }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    $Event.foreground_after = Get-ForegroundObservation
    throw 'Keyboard action did not return foreground ownership to the candidate workbench.'
}
