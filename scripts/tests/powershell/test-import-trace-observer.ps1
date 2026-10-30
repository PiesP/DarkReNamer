[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/paths.ps1')
$source = [IO.File]::ReadAllText((Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/ui-native.ps1'))
function Get-TraceMember([string] $Signature) {
    $start = $source.IndexOf($Signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Missing production trace member: $Signature" }
    $opening = $source.IndexOf('{', $start)
    $depth = 1; $end = $opening + 1
    while ($depth -gt 0 -and $end -lt $source.Length) {
        if ($source[$end] -eq '{') { $depth++ }
        elseif ($source[$end] -eq '}') { $depth-- }
        $end++
    }
    if ($depth -ne 0) { throw 'Unbalanced production trace member.' }
    $source.Substring($start, $end - $start)
}
$frame = Get-TraceMember 'public sealed class DarkReNamerImportTraceFrame'
$members = @('private static uint Scalar(', 'private static ulong Pair(',
    'public static DarkReNamerImportTraceFrame ReadImportTraceBound(') |
    ForEach-Object { Get-TraceMember $_ }
$fixture = @'
using System;
using System.Collections.Generic;
FRAME
public static class DarkReNamerIconStatusObserver {
    private const uint StatusMessage = 0x8056;
    public static Dictionary<int, uint> Values = new Dictionary<int, uint>();
    public static bool WrongProcess, WrongThreadAfter, FailQuery, Unpublished;
    public static int OwnerCalls, ScalarCalls, RevisionReads, Changes;
    public static void Reset() {
        Values.Clear(); WrongProcess = WrongThreadAfter = FailQuery = Unpublished = false;
        OwnerCalls = ScalarCalls = RevisionReads = Changes = 0;
        ulong frequency = (ulong)System.Diagnostics.Stopwatch.Frequency;
        Values[23] = (uint)frequency; Values[24] = (uint)(frequency >> 32);
        Values[40] = 1; Values[41] = 8; Values[43] = 1; Values[45] = 7;
        Values[49] = 1; Values[51] = 121;
        for (int slot = 0; slot < 16; slot++) Values[52 + slot * 2] = (uint)(100 + slot);
    }
    private static uint GetWindowThreadProcessId(IntPtr window, out uint pid) {
        OwnerCalls++;
        pid = (uint)System.Diagnostics.Process.GetCurrentProcess().Id + (WrongProcess ? 1u : 0u);
        return WrongThreadAfter && OwnerCalls > 1 ? 78u : 77u;
    }
    private static IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wparam,
        IntPtr lparam, uint flags, uint timeout, out IntPtr result) {
        ScalarCalls++;
        int selector = wparam.ToInt32();
        if (FailQuery) { result = IntPtr.Zero; return IntPtr.Zero; }
        if (Unpublished) { result = new IntPtr(-1); return new IntPtr(1); }
        if (selector == 41) {
            RevisionReads++;
            if (RevisionReads > 1 && Changes > 0) { Values[41]++; Changes--; }
        }
        uint value; Values.TryGetValue(selector, out value);
        result = new IntPtr((long)value); return new IntPtr(1);
    }
MEMBERS
}
'@.Replace('FRAME', $frame).Replace('MEMBERS', ($members -join "`n"))
Add-Type -TypeDefinition $fixture
$process = [Diagnostics.Process]::GetCurrentProcess()
$started = $process.StartTime.ToUniversalTime().Ticks
function Read-Trace {
    [DarkReNamerIconStatusObserver]::ReadImportTraceBound($process, [IntPtr]5151, $started)
}
function Assert-Fails([scriptblock] $Action, [string] $Expected) {
    try { & $Action }
    catch { if ($_.Exception.ToString() -notlike "*$Expected*") { throw }; return }
    throw "Expected failure: $Expected"
}
[DarkReNamerIconStatusObserver]::Reset()
$actual = Read-Trace
if ($actual.SchemaVersion -ne 1 -or $actual.Revision -ne 8 -or
    $actual.OwnerThreadId -ne 77 -or $actual.Generation -ne 1 -or
    $actual.Session -ne 7 -or $actual.Events.Count -ne 16 -or
    $actual.Events[13] -ne 113 -or $actual.Events[15] -ne 115) { throw 'Production trace reader changed field/slot mapping.' }
[DarkReNamerIconStatusObserver]::Reset()
[DarkReNamerIconStatusObserver]::Changes = 1
if ((Read-Trace).Revision -ne 9 -or [DarkReNamerIconStatusObserver]::RevisionReads -ne 4) {
    throw 'A changed frame was accepted without a fresh complete revision bracket.'
}
foreach ($field in @('WrongProcess','WrongThreadAfter','FailQuery','Unpublished')) {
    [DarkReNamerIconStatusObserver]::Reset()
    [DarkReNamerIconStatusObserver].GetField($field).SetValue($null, $true)
    $expected = switch ($field) {
        WrongProcess { 'does not belong' }
        WrongThreadAfter { 'target changed' }
        FailQuery { 'timed out or failed' }
        Unpublished { 'unpublished or unstable' }
    }
    Assert-Fails { Read-Trace } $expected
    if ($field -in @('FailQuery','Unpublished') -and
        [DarkReNamerIconStatusObserver]::ScalarCalls -ne 1) {
        throw 'An unknown probe failure was retried or hidden.'
    }
}
foreach ($change in @(@(40,2), @(51,256), @(23,0))) {
    [DarkReNamerIconStatusObserver]::Reset()
    [DarkReNamerIconStatusObserver]::Values[$change[0]] = [uint32]$change[1]
    Assert-Fails { Read-Trace } 'schema, clock, or target changed'
}
[DarkReNamerIconStatusObserver]::Reset()
Assert-Fails {
    [DarkReNamerIconStatusObserver]::ReadImportTraceBound($process, [IntPtr]5151, $started - 1)
} 'target process identity changed'
Write-Host 'Import trace observer production reader contracts passed.'
