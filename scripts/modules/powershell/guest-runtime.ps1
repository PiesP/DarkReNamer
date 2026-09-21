function Write-ResultDocument {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][object] $Result
    )

    $resultPath = Join-Path $Root 'result.json'
    $temporaryPath = Join-Path $Root 'result.json.tmp'
    foreach ($path in @($resultPath, $temporaryPath)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The result output is unsafe.'
            }
        }
    }
    $json = $Result | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $resultPath -Force
}
function Initialize-TestExecutionState {
    if (-not ('DarkReNamerVmExecutionState' -as [type])) {
        Add-Type @'
using System.Runtime.InteropServices;

public static class DarkReNamerVmExecutionState {
    public const uint RequiredForSuite = 0x80000003;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint executionState);
}
'@
    }
}
function Enter-TestExecutionState {
    Initialize-TestExecutionState
    $previous = [DarkReNamerVmExecutionState]::SetThreadExecutionState(
        [DarkReNamerVmExecutionState]::RequiredForSuite
    )
    if ($previous -eq 0) {
        throw 'Windows refused the temporary test execution-state request.'
    }
    [uint32]$previous
}
function Exit-TestExecutionState {
    param([AllowNull()][object] $Previous)

    if ($null -eq $Previous) {
        return
    }
    if ([DarkReNamerVmExecutionState]::SetThreadExecutionState([uint32]$Previous) -eq 0) {
        throw 'Windows refused to restore the previous test execution state.'
    }
}
function Enter-DesktopTestLock {
    param([Parameter(Mandatory)][int] $SessionId)

    # Local named objects are shared by processes on this interactive desktop
    # without blocking independent test desktops in other Windows sessions.
    $name = 'Local\DarkReNamerVmDesktopTests-' + $SessionId
    $mutex = [Threading.Mutex]::new($false, $name)
    $held = $false
    try {
        try {
            $held = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $held = $true
        }
        if (-not $held) {
            $mutex.Dispose()
            return $null
        }
        [pscustomobject]@{ mutex = $mutex; held = $true; name = $name }
    }
    catch {
        if ($held) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
        throw
    }
}
function Exit-DesktopTestLock {
    param([AllowNull()][object] $Lock)

    if ($null -eq $Lock) {
        return
    }
    try {
        if ($Lock.held) {
            $Lock.mutex.ReleaseMutex()
            $Lock.held = $false
        }
    }
    finally {
        $Lock.mutex.Dispose()
    }
}
