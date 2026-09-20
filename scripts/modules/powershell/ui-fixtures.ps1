function Get-ObserverControlReachability {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][IntPtr] $ExpectedRoot,
        [Parameter(Mandatory)][object] $WorkArea,
        [Parameter(Mandatory)][string] $Label
    )
    $snapshot = Get-ElementObservation -Element $Element
    $bounds = $snapshot.bounds
    $insideWorkArea = -not $snapshot.offscreen -and
        $bounds.x -ge $WorkArea.left -and $bounds.y -ge $WorkArea.top -and
        ($bounds.x + $bounds.width) -le $WorkArea.right -and
        ($bounds.y + $bounds.height) -le $WorkArea.bottom
    $mouse = $null
    $failure = $null
    if ($insideWorkArea) {
        try {
            $mouse = Get-GuiRegressionPhysicalTarget -Element $Element -Application $Application -SessionId $SessionId -ExpectedRoot $ExpectedRoot -Label $Label
        }
        catch { $failure = $_.Exception.Message }
    }
    else { $failure = 'control-bounds-outside-work-area' }
    [ordered]@{
        label = $Label
        status = if ($insideWorkArea -and $null -ne $mouse) { 'reachable' } else { 'inaccessible' }
        inside_work_area = $insideWorkArea
        automation = $snapshot
        physical_mouse_target = $mouse
        observation = $failure
    }
}
function New-ObserverRepeatedFixture {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $root = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'repeated-fixture'
    # Admission sorts these ASCII/Korean leaves in ordinal order: 0, a, 가.
    $sources = @((('0' * 101) + '.txt'), (('a' * 100) + '.txt'), (('가' * 100) + '.txt'))
    $destinations = @((('0' * 100) + '.txt'), (('a' * 101) + '.txt'), (('가' * 101) + '.txt'))
    $paths = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $sources.Count; $index++) {
        $path = Join-Path $root $sources[$index]
        [IO.File]::WriteAllText($path, "repeated-context-$index`n", [Text.UTF8Encoding]::new($false))
        $paths.Add($path)
    }
    [pscustomobject]@{
        root = $root
        paths = $paths.ToArray()
        paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths $paths.ToArray()
        source_names = $sources
        destination_names = $destinations
        destination_paths = @(
            (Join-Path $root $destinations[0]),
            (Join-Path $root $destinations[1]),
            (Join-Path $root $destinations[2])
        )
        initial = Get-ObserverFixtureState -FixtureRoot $root
    }
}
function New-ObserverMoveFixture {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $requestedRoot = 'C:\fixture'
    $fixedOccupied = Test-Path -LiteralPath $requestedRoot
    if ($fixedOccupied) {
        $root = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'fixture-equivalent'
        $ownsFixedRoot = $false
    }
    else {
        [void](New-Item -ItemType Directory -Path $requestedRoot)
        $root = (Get-Item -LiteralPath $requestedRoot -Force).FullName
        $ownsFixedRoot = $true
        $script:ownedContextFixedRoot = $root
    }
    $rootItem = Get-Item -LiteralPath $root -Force
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        @(Get-ChildItem -LiteralPath $root -Force).Count -ne 0) {
        throw 'Move fixture root is occupied, unsafe, or not empty.'
    }
    $parentA = New-PrivateDirectory -Parent $root -Leaf 'A'
    $parentB = New-PrivateDirectory -Parent $root -Leaf 'B'
    $source = Join-Path $parentA 'old.txt'
    $destination = Join-Path $parentB 'new.txt'
    [IO.File]::WriteAllText($source, "move-context-content`n", [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{
        requested_root = $requestedRoot
        root = $root
        fixed_path_occupied = $fixedOccupied
        isolated_equivalent = $fixedOccupied
        owns_fixed_root = $ownsFixedRoot
        parent_a = $parentA
        parent_b = $parentB
        source = $source
        destination = $destination
        paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths @($source)
        initial = Get-ObserverFixtureState -FixtureRoot $root
    }
}
function New-ObserverMixedFixture {
    param([Parameter(Mandatory)][string] $RuntimeRoot)
    $root = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'mixed-fixture'
    $parentA = New-PrivateDirectory -Parent $root -Leaf 'A'
    $parentD = New-PrivateDirectory -Parent $root -Leaf 'D'
    $sources = @(
        (Join-Path $parentA '01-rename.txt'),
        (Join-Path $parentA '02-rename.txt'),
        (Join-Path $parentA '03-unsampled-move.txt')
    )
    $prefix = '검증-'
    $destinations = @(
        (Join-Path $parentA ($prefix + '01-rename.txt')),
        (Join-Path $parentA ($prefix + '02-rename.txt')),
        (Join-Path $parentD ($prefix + '03-unsampled-move.txt'))
    )
    for ($index = 0; $index -lt $sources.Count; $index++) {
        [IO.File]::WriteAllText($sources[$index], "mixed-context-$index`n", [Text.UTF8Encoding]::new($false))
    }
    [pscustomobject]@{
        root = $root
        parent_a = $parentA
        parent_d = $parentD
        prefix = $prefix
        sources = $sources
        destinations = $destinations
        first_paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths @($sources[2]) -Leaf 'mixed-first-utf16le.txt'
        later_paths_file = New-ObserverPathList -RuntimeRoot $RuntimeRoot -Paths @($sources[0], $sources[1]) -Leaf 'mixed-later-utf16le.txt'
        initial = Get-ObserverFixtureState -FixtureRoot $root
    }
}
function Set-ObserverDestinationParent {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Grid,
        [Parameter(Mandatory)][string] $DestinationParent,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )
    Add-Type -AssemblyName System.Windows.Forms
    $Application.main.SetFocus()

    [void][DarkReNamerVmNative]::SetForegroundWindow([IntPtr]$Application.main_handle)

    Assert-AcceptanceForegroundBinding -Process $Application.process -ExpectedSession $SessionId `
        -MainWindowHandle ([IntPtr]$Application.main_handle) -RequireMainWindow
    [Windows.Forms.SendKeys]::SendWait('%ed{ENTER}')
    $dialog = Wait-UniqueAutomationWindow -Process $Application.process -ExpectedSession $SessionId -Owner $Application.main -Name '모든 파일을 이동할 대상 폴더 선택' -TimeoutSeconds $WaitSeconds -Label 'move destination folder picker'
    $handle = [IntPtr]$dialog.Current.NativeWindowHandle
    $dialogSnapshot = Get-ElementObservation -Element $dialog
    [Windows.Forms.SendKeys]::SendWait('^l')
    $address = Get-FocusedAcceptanceElement -Process $Application.process -ExpectedSession $SessionId -Label 'folder picker address edit'
    if ($address.Current.ControlType -ne [Windows.Automation.ControlType]::Edit) {
        throw 'Folder picker Ctrl+L did not focus an editable address control.'
    }
    Set-AutomationControlValue -Element $address -Value $DestinationParent -Label 'folder picker destination address'
    Send-AcceptanceTap -Process $Application.process -ExpectedSession $SessionId -VirtualKey 0x0D -Label 'folder picker address Enter'
    Start-Sleep -Milliseconds 300
    $choose = Find-UniqueAutomationElement -Root $dialog -Process $Application.process -ExpectedSession $SessionId -AutomationId '1' -ControlType ([Windows.Automation.ControlType]::Button) -TimeoutSeconds $WaitSeconds -Label 'folder picker Select Folder button' -RequireEnabled -RequireWindowHandle
    $chooseSnapshot = Get-ElementObservation -Element $choose
    $mouse = Get-GuiRegressionPhysicalTarget -Click -Element $choose -Application $Application -SessionId $SessionId -ExpectedRoot $handle -Label 'folder picker Select Folder button'
    Wait-WindowClosed -Handle $handle -TimeoutSeconds $WaitSeconds -Label 'move destination folder picker'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $actual = $Grid.pattern.GetItem(0, 2).Current.Name
        if ($actual -ceq $DestinationParent) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($actual -cne $DestinationParent) {
        throw 'Move preview did not expose the exact selected destination parent.'
    }
    [ordered]@{
        input = 'keyboard-menu-alt-e-d-enter-address-ctrl-l-enter-physical-select-folder'
        dialog = $dialogSnapshot
        choose_button = $chooseSnapshot
        physical_click = $mouse
        destination_parent = $DestinationParent
        preview_parent_exact = $true
    }
}
function Get-ObserverBoundedDifferenceSnippet {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int] $FocusStart,
        [Parameter(Mandatory)][int] $FocusEnd
    )
    $limit = 56
    $length = $Text.Length
    if ($length -le $limit) { return $Text }
    $focusStart = [Math]::Min($FocusStart, $length)
    $focusEnd = [Math]::Max($focusStart, [Math]::Min($FocusEnd, $length))
    $focusLength = $focusEnd - $focusStart
    if ($focusLength + 2 -le $limit) {
        $available = $limit - $focusLength - 2
        $left = [Math]::Min($focusStart, [Math]::Floor($available / 2))
        $right = [Math]::Min($length - $focusEnd, $available - $left)
        $available -= $left + $right
        if ($available -ne 0) {
            $extraLeft = [Math]::Min($focusStart - $left, $available)
            $left += $extraLeft
            $available -= $extraLeft
            $right += [Math]::Min($length - $focusEnd - $right, $available)
        }
        $shownStart = $focusStart - $left
        $shownLength = $focusLength + $left + $right
        return $(if ($shownStart -ne 0) { '…' } else { '' }) +
            $Text.Substring($shownStart, $shownLength) +
            $(if ($shownStart + $shownLength -ne $length) { '…' } else { '' })
    }
    $leadingEllipsis = [int]($focusStart -ne 0)
    $trailingEllipsis = [int]($focusEnd -ne $length)
    $visibleFocus = $limit - $leadingEllipsis - $trailingEllipsis - 1
    $leadingFocus = [Math]::Floor($visibleFocus / 2)
    $trailingFocus = $visibleFocus - $leadingFocus
    return $(if ($leadingEllipsis -ne 0) { '…' } else { '' }) +
        $Text.Substring($focusStart, $leadingFocus) +
        '…' +
        $Text.Substring($focusEnd - $trailingFocus, $trailingFocus) +
        $(if ($trailingEllipsis -ne 0) { '…' } else { '' })
}
function Get-ObserverDifferenceSnippetPair {
    param(
        [Parameter(Mandatory)][string] $Current,
        [Parameter(Mandatory)][string] $After
    )
    $prefix = 0
    while ($prefix -lt [Math]::Min($Current.Length, $After.Length) -and $Current[$prefix] -ceq $After[$prefix]) {
        $prefix++
    }
    $maximumSuffix = [Math]::Min($Current.Length - $prefix, $After.Length - $prefix)
    $suffix = 0
    while ($suffix -lt $maximumSuffix -and $Current[$Current.Length - 1 - $suffix] -ceq $After[$After.Length - 1 - $suffix]) {
        $suffix++
    }
    [ordered]@{
        current = Get-ObserverBoundedDifferenceSnippet -Text $Current -FocusStart $prefix -FocusEnd ($Current.Length - $suffix)
        after = Get-ObserverBoundedDifferenceSnippet -Text $After -FocusStart $prefix -FocusEnd ($After.Length - $suffix)
    }
}
