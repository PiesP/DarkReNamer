function Initialize-DrVmObserverLifecycle {
    param([Parameter(Mandatory)][string] $ProfileId)
    if ($ProfileId -ceq 'vm-automated-v1-win11-ntfs') { return }
    if ($ProfileId -cne 'vm-automated-v2-owned-resources' -or
        [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The observer profile or native process lifetime is unavailable.'
    }
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $commandLine = [Environment]::CommandLine
        $image = $process.MainModule.FileName
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ([string]::IsNullOrWhiteSpace($image) -or
            [string]::IsNullOrWhiteSpace($commandLine) -or
            $commandLine.Length -gt 4096) {
            throw 'The observer image or execution scope is unavailable.'
        }
        $script:VmObserverLifecycle = [ordered]@{
            pid = [int]$process.Id
            start_time_utc_ticks = $process.StartTime.ToUniversalTime().Ticks.ToString(
                [Globalization.CultureInfo]::InvariantCulture)
            session_id = [int]$process.SessionId
            image_path = [string]$image
            command_line = [string]$commandLine
            owner_sid = [string]$sid
        }
    }
    finally { $process.Dispose() }
}

function Write-ResultDocument {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][object] $Result,
        [string] $Path
    )

    $writer = $script:VmTrustedResultWriter
    if ($null -eq $writer -or
        [IO.Path]::GetFullPath($Root) -cne $script:VmTrustedResultRoot) {
        throw 'The trusted result writer is not initialized for this bundle.'
    }
    $expectedPath = if ($Path) { [IO.Path]::GetFullPath($Path) } else {
        Join-Path $script:VmTrustedResultRoot 'result.json'
    }
    if ($expectedPath -cne $script:VmTrustedResultPath) {
        throw 'The trusted result writer is not initialized for this result path.'
    }
    if ($null -ne $script:AcceptanceProcessJobCleanup) {
        $jobCleanup = @($script:AcceptanceProcessJobCleanup.ToArray())
        $Result['process_job_cleanup'] = $jobCleanup
        if (@($jobCleanup | Where-Object { $_.status -cne 'clean' }).Count -ne 0 -and
            $Result['status'] -cne 'failed') {
            $Result['status'] = 'failed'
            $Result['failure_reason'] = 'process_job_cleanup_failed'
        }
    }
    if ($script:VmAcceptanceProfileId -ceq 'vm-automated-v2-owned-resources') {
        if ($null -eq $script:VmObserverLifecycle) {
            throw 'The v2 observer did not retain its original process lifetime.'
        }
        $Result['observer_lifecycle'] = $script:VmObserverLifecycle
    }
    try {
        $json = $Result | ConvertTo-Json -Depth 16
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $writer.SetLength(0)
        $writer.Position = 0
        $writer.Write($bytes, 0, $bytes.Length)
        $writer.Flush($true)
    }
    finally {
        if ($writer) { $writer.Dispose() }
        $script:VmTrustedResultWriter = $null
        $script:VmTrustedResultRoot = $null
        $script:VmTrustedResultPath = $null
    }
}

$script:VmTrustedResultWriter = $null
$script:VmTrustedResultRoot = $null
$script:VmTrustedResultPath = $null
$script:AcceptanceProcessJobCleanup = $null
$script:VmAcceptanceProfileId = 'vm-automated-v1-win11-ntfs'
$script:VmObserverLifecycle = $null

function Initialize-TrustedResultWriter {
    param(
        [Parameter(Mandatory)][string] $Root,
        [string] $Path,
        [string] $ResultRoot,
        [string] $WriterPath
    )

    if ($null -ne $script:VmTrustedResultWriter) {
        throw 'The trusted result writer is already initialized.'
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $resultPath = if ($Path) { [IO.Path]::GetFullPath($Path) } else {
        Join-Path $rootPath 'result.json'
    }
    $resultRootPath = if ($ResultRoot) { [IO.Path]::GetFullPath($ResultRoot) } else { $rootPath }
    $rootPrefix = $resultRootPath.TrimEnd([IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resultPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The trusted result path must remain beneath its verified output root.'
    }
    $environmentPath = [Environment]::GetEnvironmentVariable(
        'DARKRENAMER_VM_TRUSTED_RESULT_PATH'
    )
    $elevatedObserver = [Environment]::GetEnvironmentVariable(
        'DARKRENAMER_VM_ELEVATED_OBSERVER'
    ) -ceq '1'
    $trustedPath = if ($WriterPath) {
        [IO.Path]::GetFullPath($WriterPath)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($environmentPath)) {
        [IO.Path]::GetFullPath($environmentPath)
    }
    else {
        $resultPath
    }
    if ($elevatedObserver -and
        ([string]::IsNullOrWhiteSpace($environmentPath) -or
         $environmentPath -cne $trustedPath)) {
        throw 'The elevated observer trusted result path is missing or differs from its task contract.'
    }
    if (-not $elevatedObserver -and ($WriterPath -or $environmentPath)) {
        throw 'A separate trusted result path is allowed only for an elevated VM observer.'
    }
    $writer = $null
    $safeHandle = $null
    try {
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            Initialize-JobBoundProcessRuntime
            $safeHandle = [DarkReNamerVmRunnerSecurity]::CreateTrustedResultFile(
                $trustedPath, -not $elevatedObserver)
            $writer = [IO.FileStream]::new($safeHandle, [IO.FileAccess]::ReadWrite, 4096, $false)
            $safeHandle = $null
            $runnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            [DarkReNamerVmRunnerSecurity]::ProtectResultFile($writer.SafeFileHandle, $runnerSid)
        }
        else {
            $writer = [IO.FileStream]::new(
                $trustedPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::Read,
                4096,
                [IO.FileOptions]::WriteThrough
            )
        }
        $writer.SetLength(0)
        $script:VmTrustedResultWriter = $writer
        $script:VmTrustedResultRoot = $rootPath
        $script:VmTrustedResultPath = $resultPath
    }
    catch {
        if ($writer) { $writer.Dispose() }
        if ($safeHandle) { $safeHandle.Dispose() }
        throw
    }
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
