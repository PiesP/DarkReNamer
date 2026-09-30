[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Owned root guard runtime tests require Windows.' }
$source = Join-Path $PSScriptRoot '../../modules/powershell/controller-entry.psm1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Controller source did not parse.' }
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString -and
    $node.Value.Contains('public sealed class DarkReNamerVmOwnedRootGuard')
}, $true))
if ($definitions.Count -ne 1) { throw 'Expected exactly one source-bound owned root guard.' }
Add-Type -TypeDefinition $definitions[0].Value
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DrOwnedGuardTestNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool RemoveDirectoryW(string name);
}
'@

function Assert-Rejected([scriptblock] $Action, [string] $Expected) {
    try { & $Action }
    catch {
        if ($_.Exception.ToString() -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected rejection: $Expected"
}

$base = Join-Path $env:ProgramData 'DarkReNamerVmRuns'
$baseCreated = $false
if (-not (Test-Path -LiteralPath $base -PathType Container)) {
    [IO.Directory]::CreateDirectory($base) | Out-Null
    $baseCreated = $true
}
$fixtures = [Collections.Generic.List[string]]::new()
function New-Fixture {
    $path = Join-Path $base ('DarkReNamerTests-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $path) { throw 'Fresh fixture already exists.' }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $fixtures.Add($path)
    return $path
}
$guard = $null
$junction = $null
try {
    $nested = New-Fixture
    [IO.Directory]::CreateDirectory((Join-Path $nested 'nested')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $nested 'nested/sentinel.txt'), 'owned')
    $guard = [DarkReNamerVmOwnedRootGuard]::new($nested)
    Assert-Rejected { $guard.Assert($guard.BaseId, ('0' * 48)) } 'identity changed'
    $guard.Assert($guard.BaseId, $guard.RootId)
    if (@($guard.Security()).Count -ne 2) { throw 'Held root descriptor was not observed.' }
    $guard.Delete()
    $guard.Dispose(); $guard = $null
    if (Test-Path -LiteralPath $nested) { throw 'Nested fixture remains.' }

    $replaced = New-Fixture
    $child = Join-Path $replaced 'child.txt'
    [IO.File]::WriteAllText($child, 'original')
    $guard = [DarkReNamerVmOwnedRootGuard]::new($replaced)
    $flags = [Reflection.BindingFlags]'NonPublic,Instance,Static'
    $chain = [DarkReNamerVmOwnedRootGuard].GetField('chain', $flags).GetValue($guard)
    $parent = $chain[$chain.Count - 1]
    $enumerate = [DarkReNamerVmOwnedRootGuard].GetMethod('Names', $flags)
    Assert-Rejected { $enumerate.Invoke($null, @($parent, 0)) } 'oversized entry'
    $names = $enumerate.Invoke($null, @($parent, 20000))
    if ($names.Count -ne 1) { throw 'Replacement fixture enumeration was incomplete.' }
    [IO.File]::Delete($child)
    [IO.File]::WriteAllText($child, 'replacement')
    $delete = [DarkReNamerVmOwnedRootGuard].GetMethod('DeleteEntry', $flags)
    Assert-Rejected { $delete.Invoke($guard, @($parent, $names[0], 1)) } 'child changed'
    if ([IO.File]::ReadAllText($child) -cne 'replacement') { throw 'Replacement was deleted or changed.' }
    $guard.Delete()
    $guard.Dispose(); $guard = $null

    $target = New-Fixture
    $sentinel = Join-Path $target 'sentinel.txt'
    [IO.File]::WriteAllText($sentinel, 'outside')
    $linked = New-Fixture
    $junction = Join-Path $linked 'junction'
    New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
    $guard = [DarkReNamerVmOwnedRootGuard]::new($linked)
    Assert-Rejected { $guard.Delete() } 'reparse'
    if ([IO.File]::ReadAllText($sentinel) -cne 'outside') { throw 'Junction target changed.' }
    $guard.Dispose(); $guard = $null
    $item = Get-Item -LiteralPath $junction -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        @($item.Target).Count -ne 1 -or $item.Target -cne $target) {
        throw 'Test junction changed before exact unlink.'
    }
    if (-not [DrOwnedGuardTestNative]::RemoveDirectoryW($junction)) { throw 'Exact junction unlink failed.' }
    $junction = $null
    $guard = [DarkReNamerVmOwnedRootGuard]::new($linked)
    $guard.Delete(); $guard.Dispose(); $guard = $null

    $utf16 = New-Fixture
    $name = 'raw-' + [char]0xd800 + '.txt'
    [IO.File]::WriteAllText((Join-Path $utf16 $name), 'raw UTF-16')
    $guard = [DarkReNamerVmOwnedRootGuard]::new($utf16)
    $chain = [DarkReNamerVmOwnedRootGuard].GetField('chain', $flags).GetValue($guard)
    $names = $enumerate.Invoke($null, @($chain[$chain.Count - 1], 20000))
    if ($names.Count -ne 1 -or $names[0].Name -cne $name -or [int]$names[0].Name[4] -ne 0xd800) {
        throw 'Enumeration changed raw UTF-16 code units.'
    }
    $guard.Delete(); $guard.Dispose(); $guard = $null
} finally {
    if ($null -ne $guard) { $guard.Dispose() }
    # Never recursively traverse a failed reparse fixture. Retain it for inspection.
    foreach ($path in $fixtures) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if ($null -ne $junction -and $path -ceq (Split-Path -Parent $junction)) { continue }
        $cleanup = [DarkReNamerVmOwnedRootGuard]::new($path)
        try { $cleanup.Delete() } finally { $cleanup.Dispose() }
    }
    if ($baseCreated) { [IO.Directory]::Delete($base, $false) }
}
foreach ($path in $fixtures) {
    if (Test-Path -LiteralPath $path) { throw 'Owned fixture cleanup is incomplete.' }
}
Write-Output 'Source-bound owned root guard runtime tests passed.'
