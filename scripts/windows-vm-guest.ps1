[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BundleRoot,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $ExpectedSessionId,

    [ValidateRange(1, 3600)]
    [int] $TestTimeoutSeconds = 300,

    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string[]] $Names,

        [Parameter(Mandatory)]
        [string] $Label
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

function Assert-SafeLeafName {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string] $Pattern
    )

    if ($Value -isnot [string] -or
        $Value.Length -gt 160 -or
        $Value -notmatch $Pattern -or
        [IO.Path]::GetFileName($Value) -cne $Value) {
        throw "$Label must be a safe leaf filename."
    }
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Label
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Label must be a lowercase SHA-256 digest."
    }
}

function Assert-OrdinaryFile {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing."
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a reparse point."
    }
}

function Get-LowerSha256 {
    param([Parameter(Mandatory)][string] $Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-LowerTextSha256 {
    param([Parameter(Mandatory)][string] $Value)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Resolve-VerifiedBundle {
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $InvokedScriptPath
    )

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be an absolute directory.'
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'BundleRoot must be an existing directory.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BundleRoot must not be a reparse point.'
    }
    $resolvedRoot = $rootItem.FullName

    $manifestPath = Join-Path $resolvedRoot 'bundle.json'
    Assert-OrdinaryFile -Path $manifestPath -Label 'bundle.json'
    if ((Get-Item -LiteralPath $manifestPath).Length -gt 1MB) {
        throw 'bundle.json is too large.'
    }
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifestText.IndexOf([char]0) -ge 0) {
        throw 'bundle.json contains NUL.'
    }
    try {
        $manifest = $manifestText | ConvertFrom-Json
    }
    catch {
        throw 'bundle.json is not valid JSON.'
    }
    if ($null -eq $manifest) {
        throw 'bundle.json must contain an object.'
    }

    Assert-ExactProperties -Value $manifest -Names @(
        'schema_version'
        'source_sha'
        'source_state'
        'target'
        'cargo_lock_sha256'
        'test_binaries'
        'application'
        'runner'
    ) -Label 'bundle.json'
    if (($manifest.schema_version -isnot [int] -and $manifest.schema_version -isnot [long]) -or
        $manifest.schema_version -ne 1) {
        throw 'bundle.json schema_version must be 1.'
    }
    if ($manifest.source_sha -isnot [string] -or $manifest.source_sha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'bundle.json source_sha must be a lowercase full Git SHA.'
    }
    if ($manifest.source_state -isnot [string] -or
        $manifest.source_state -cne 'clean' -and $manifest.source_state -cne 'dirty') {
        throw 'bundle.json source_state is invalid.'
    }
    if ($manifest.target -isnot [string] -or $manifest.target -cne 'x86_64-pc-windows-msvc') {
        throw 'bundle.json target is invalid.'
    }
    Assert-Sha256 -Value $manifest.cargo_lock_sha256 -Label 'bundle.json cargo_lock_sha256'

    if ($manifest.test_binaries -isnot [array] -or $manifest.test_binaries.Count -le 0) {
        throw 'bundle.json test_binaries must be a non-empty array.'
    }
    Assert-ExactProperties -Value $manifest.application -Names @('file', 'sha256') -Label 'bundle.json application'
    Assert-ExactProperties -Value $manifest.runner -Names @('file', 'sha256') -Label 'bundle.json runner'
    Assert-SafeLeafName -Value $manifest.application.file -Label 'application file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.exe$'
    if ($manifest.application.file -cne 'DarkReNamer.exe') {
        throw 'bundle.json application file is invalid.'
    }
    Assert-Sha256 -Value $manifest.application.sha256 -Label 'application sha256'
    Assert-SafeLeafName -Value $manifest.runner.file -Label 'runner file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.ps1$'
    if ($manifest.runner.file -cne 'windows-vm-guest.ps1') {
        throw 'bundle.json runner file is invalid.'
    }
    Assert-Sha256 -Value $manifest.runner.sha256 -Label 'runner sha256'

    $leafNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $testNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $artifacts = [Collections.Generic.List[object]]::new()
    $testRows = [Collections.Generic.List[object]]::new()
    foreach ($binary in @($manifest.test_binaries)) {
        Assert-ExactProperties -Value $binary -Names @('name', 'file', 'sha256') -Label 'bundle.json test binary'
        if ($binary.name -isnot [string] -or $binary.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            throw 'A test binary name is invalid.'
        }
        if (-not $testNames.Add($binary.name)) {
            throw 'Test binary names must be unique.'
        }
        Assert-SafeLeafName -Value $binary.file -Label 'test binary file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.exe$'
        Assert-Sha256 -Value $binary.sha256 -Label 'test binary sha256'
        if (-not $leafNames.Add($binary.file)) {
            throw 'Artifact filenames must be unique.'
        }
        $testRows.Add([pscustomobject]@{
            name = $binary.name
            file = $binary.file
            sha256 = $binary.sha256
        })
        $artifacts.Add([pscustomobject]@{
            label = 'test binary'
            file = $binary.file
            sha256 = $binary.sha256
        })
    }
    foreach ($artifact in @($manifest.application, $manifest.runner)) {
        if (-not $leafNames.Add($artifact.file)) {
            throw 'Artifact filenames must be unique.'
        }
        $artifacts.Add([pscustomobject]@{
            label = 'manifest artifact'
            file = $artifact.file
            sha256 = $artifact.sha256
        })
    }

    $runnerPath = Join-Path $resolvedRoot $manifest.runner.file
    Assert-OrdinaryFile -Path $runnerPath -Label 'runner artifact'
    $actualScriptPath = (Get-Item -LiteralPath $InvokedScriptPath -Force).FullName
    if (-not [string]::Equals($runnerPath, $actualScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The invoked runner is not the bundled runner artifact.'
    }

    $verifiedHashes = @{}
    foreach ($artifact in $artifacts) {
        $artifactPath = Join-Path $resolvedRoot $artifact.file
        Assert-OrdinaryFile -Path $artifactPath -Label $artifact.label
        $actualHash = Get-LowerSha256 -Path $artifactPath
        if ($actualHash -cne $artifact.sha256) {
            throw "$($artifact.label) hash mismatch."
        }
        $verifiedHashes[$artifact.file] = $actualHash
    }

    [pscustomobject]@{
        root = $resolvedRoot
        manifest = $manifest
        tests = $testRows.ToArray()
        hashes = $verifiedHashes
    }
}

function Read-RustTestSummary {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Stdout,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Stderr,

        [switch] $AllowZeroTests
    )

    $pattern = '(?m)^test result: (ok|FAILED)\. ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored; ([0-9]+) measured; ([0-9]+) filtered out;(?:[^\r\n]*)\r?$'
    $matches = [regex]::Matches($Stdout, $pattern)
    if ($matches.Count -eq 0) {
        throw 'Rust test stdout must contain a test result summary.'
    }
    $summary = $matches[$matches.Count - 1]
    $passed = [int]::Parse($summary.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    $failed = [int]::Parse($summary.Groups[3].Value, [Globalization.CultureInfo]::InvariantCulture)
    $ignored = [int]::Parse($summary.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture)
    $filtered = [int]::Parse($summary.Groups[6].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($filtered -ne 0) {
        throw 'The final Rust test harness must not filter tests.'
    }
    if (-not $AllowZeroTests -and ($passed + $failed + $ignored) -eq 0) {
        throw 'A non-main Rust test harness reported zero tests.'
    }

    [pscustomobject]@{
        outcome = $summary.Groups[1].Value
        passed = $passed
        failed = $failed
        ignored = $ignored
        filtered = $filtered
    }
}

function New-PrivateDirectory {
    param(
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Leaf
    )

    $path = Join-Path $Parent $Leaf
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'A runtime directory is unsafe.'
        }
    }
    else {
        [void](New-Item -ItemType Directory -Path $path)
    }
    $path
}

function Invoke-TaskkillTree {
    param([Parameter(Mandatory)][int] $ProcessId)

    & "$env:SystemRoot\System32\taskkill.exe" /PID $ProcessId /T /F 2>$null | Out-Null
}

function Invoke-WithIsolatedEnvironment {
    param(
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][scriptblock] $Action
    )

    $temporary = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'temp'
    $localAppData = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'localappdata'
    $names = @('TEMP', 'TMP', 'LOCALAPPDATA', 'DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES')
    $original = @{}
    foreach ($name in $names) {
        $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        [Environment]::SetEnvironmentVariable('TEMP', $temporary, 'Process')
        [Environment]::SetEnvironmentVariable('TMP', $temporary, 'Process')
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData, 'Process')
        [Environment]::SetEnvironmentVariable('DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES', '1', 'Process')
        & $Action
    }
    finally {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
        }
    }
}

function Start-OwnedProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Arguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [switch] $RedirectOutput
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.WorkingDirectory = $WorkingDirectory
    # Shell activation gives the GUI the same startup behavior as a user launch.
    # Test harnesses use direct creation so stdout and stderr stay redirected.
    $startInfo.UseShellExecute = -not $RedirectOutput
    $startInfo.CreateNoWindow = $RedirectOutput
    $startInfo.RedirectStandardOutput = $RedirectOutput
    $startInfo.RedirectStandardError = $RedirectOutput
    if ($RedirectOutput) {
        $encoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardOutputEncoding = $encoding
        $startInfo.StandardErrorEncoding = $encoding
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Process start returned false.'
        }
        [void]$process.Handle
        [pscustomobject]@{
            process = $process
            stdout_task = if ($RedirectOutput) { $process.StandardOutput.ReadToEndAsync() } else { $null }
            stderr_task = if ($RedirectOutput) { $process.StandardError.ReadToEndAsync() } else { $null }
            output_saved = $false
        }
    }
    catch {
        $process.Dispose()
        throw
    }
}

function Save-CapturedProcessOutput {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][string] $StdoutPath,
        [Parameter(Mandatory)][string] $StderrPath
    )

    if ($State.output_saved -or $null -eq $State.stdout_task -or $null -eq $State.stderr_task) {
        return
    }
    $stdoutText = $State.stdout_task.GetAwaiter().GetResult()
    $stderrText = $State.stderr_task.GetAwaiter().GetResult()
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($StdoutPath, $stdoutText, $encoding)
    [IO.File]::WriteAllText($StderrPath, $stderrText, $encoding)
    $State.output_saved = $true
}

function Invoke-RustTestBinary {
    param(
        [Parameter(Mandatory)][object] $Test,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][int] $Index,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $stdoutLeaf = 'test-{0:D3}.stdout.txt' -f $Index
    $stderrLeaf = 'test-{0:D3}.stderr.txt' -f $Index
    $stdoutPath = Join-Path $Root $stdoutLeaf
    $stderrPath = Join-Path $Root $stderrLeaf
    [IO.File]::WriteAllBytes($stdoutPath, [byte[]]@())
    [IO.File]::WriteAllBytes($stderrPath, [byte[]]@())
    $binaryPath = Join-Path $Root $Test.file
    $row = [ordered]@{
        file = $Test.file
        sha256 = $Test.sha256
        status = 'failed'
        exit_code = $null
        passed = $null
        failed = $null
        ignored = $null
        stdout = $null
        stderr = $null
        failure_reason = 'process_start_failed'
    }
    $processState = [pscustomobject]@{ process = $null }
    try {
        Assert-OrdinaryFile -Path $binaryPath -Label 'test binary'
        if ((Get-LowerSha256 -Path $binaryPath) -cne $Test.sha256) {
            $row.failure_reason = 'artifact_changed_after_preflight'
            return [pscustomobject]$row
        }
        $caseRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf ('test-{0:D3}' -f $Index)
        Invoke-WithIsolatedEnvironment -RuntimeRoot $caseRoot -Action {
            $ownedProcess = Start-OwnedProcess `
                -FilePath $binaryPath `
                -Arguments '--nocapture --test-threads=1' `
                -WorkingDirectory $Root `
                -RedirectOutput
            $processState.process = $ownedProcess
            $waitMilliseconds = [int]([Math]::Min([int]::MaxValue, $TimeoutSeconds * 1000L))
            $timedOut = -not $processState.process.process.WaitForExit($waitMilliseconds)
            if ($timedOut) {
                $row.failure_reason = 'timeout'
                Invoke-TaskkillTree -ProcessId $processState.process.process.Id
                if (-not $processState.process.process.WaitForExit(10000)) {
                    throw 'Timed-out test process did not terminate.'
                }
            }
            $processState.process.process.WaitForExit()
            Save-CapturedProcessOutput `
                -State $processState.process `
                -StdoutPath $stdoutPath `
                -StderrPath $stderrPath
            if ($timedOut) {
                return
            }
            $row.exit_code = $processState.process.process.ExitCode
            $stdoutText = [IO.File]::ReadAllText($stdoutPath)
            $stderrText = [IO.File]::ReadAllText($stderrPath)
            try {
                $summary = Read-RustTestSummary `
                    -Stdout $stdoutText `
                    -Stderr $stderrText `
                    -AllowZeroTests:($Test.name -ceq 'DarkReNamer')
                $row.passed = $summary.passed
                $row.failed = $summary.failed
                $row.ignored = $summary.ignored
                if ($processState.process.process.ExitCode -eq 0 -and
                    $summary.outcome -ceq 'ok' -and
                    $summary.failed -eq 0) {
                    $row.status = 'passed'
                    $row.failure_reason = $null
                }
                else {
                    $row.failure_reason = 'test_failed'
                }
            }
            catch {
                $row.failure_reason = 'invalid_test_summary'
            }
        }
    }
    catch {
        $row.failure_reason = 'process_error'
    }
    finally {
        if ($null -ne $processState.process) {
            try {
                $processState.process.process.Refresh()
                if (-not $processState.process.process.HasExited) {
                    Invoke-TaskkillTree -ProcessId $processState.process.process.Id
                    if (-not $processState.process.process.WaitForExit(10000)) {
                        throw 'Owned test process did not terminate.'
                    }
                }
                Save-CapturedProcessOutput `
                    -State $processState.process `
                    -StdoutPath $stdoutPath `
                    -StderrPath $stderrPath
            }
            catch {
                $row.status = 'failed'
                $row.failure_reason = 'process_cleanup_failed'
            }
            $processState.process.process.Dispose()
        }
        $row.stdout = [ordered]@{
            file = $stdoutLeaf
            sha256 = Get-LowerSha256 -Path $stdoutPath
        }
        $row.stderr = [ordered]@{
            file = $stderrLeaf
            sha256 = Get-LowerSha256 -Path $stderrPath
        }
    }
    [pscustomobject]$row
}

function Initialize-NativeCapture {
    if (-not ('DarkReNamerVmNative' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class DarkReNamerVmNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string path, uint access, uint share, IntPtr securityAttributes,
        uint creationDisposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        IntPtr file, out ByHandleFileInformation information);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static string GetFileIdentity(string path) {
        IntPtr file = CreateFile(path, 0x80, 1 | 2 | 4, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
        if (file == new IntPtr(-1)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(file, out information)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            ulong index = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
            return information.VolumeSerialNumber.ToString("x8") + ":" + index.ToString("x16");
        }
        finally {
            CloseHandle(file);
        }
    }
}
'@
    }
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName UIAutomationClient
}

function Assert-AutomationBinding {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Label,
        [switch] $RequireWindowHandle
    )

    if ($Element.Current.ProcessId -ne $Process.Id -or $Process.SessionId -ne $ExpectedSession) {
        throw "$Label is not bound to the expected process and desktop session."
    }
    $nativeHandle = [IntPtr]$Element.Current.NativeWindowHandle
    if ($RequireWindowHandle) {
        if ($nativeHandle -eq [IntPtr]::Zero -or -not [DarkReNamerVmNative]::IsWindow($nativeHandle)) {
            throw "$Label does not expose one live native control."
        }
        $boundProcessId = [uint32]0
        [void][DarkReNamerVmNative]::GetWindowThreadProcessId($nativeHandle, [ref]$boundProcessId)
        if ($boundProcessId -ne $Process.Id) {
            throw "$Label native control belongs to another process."
        }
    }
}

function Find-UniqueAutomationElement {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Root,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $AutomationId,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label,
        [Windows.Automation.ControlType] $ControlType,
        [Windows.Automation.TreeScope] $Scope = [Windows.Automation.TreeScope]::Descendants,
        [switch] $RequireEnabled,
        [switch] $RequireWindowHandle
    )

    $conditions = [Collections.Generic.List[Windows.Automation.Condition]]::new()
    $conditions.Add([Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ProcessIdProperty,
        $Process.Id
    ))
    $conditions.Add([Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    ))
    if ($null -ne $ControlType) {
        $conditions.Add([Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            $ControlType
        ))
    }
    if ($RequireEnabled) {
        $conditions.Add([Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::IsEnabledProperty,
            $true
        ))
    }
    $condition = [Windows.Automation.AndCondition]::new($conditions.ToArray())
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $matches = $Root.FindAll($Scope, $condition)
        if ($matches.Count -gt 1) {
            throw "$Label matched more than one automation element."
        }
        if ($matches.Count -eq 1) {
            $element = $matches.Item(0)
            Assert-AutomationBinding `
                -Element $element `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label $Label `
                -RequireWindowHandle:$RequireWindowHandle
            return $element
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Label was not found before the application exited."
        }
    } while ((Get-Date) -lt $deadline)
    $observed = @(
        $Root.FindAll($Scope, [Windows.Automation.Condition]::TrueCondition) |
            Select-Object -First 64 |
            ForEach-Object {
                [ordered]@{
                    id = $_.Current.AutomationId
                    name = $_.Current.Name
                    type = $_.Current.ControlType.ProgrammaticName
                    enabled = $_.Current.IsEnabled
                    process = $_.Current.ProcessId
                }
            }
    )
    throw "$Label was not found before the bounded deadline. Observed controls: $($observed | ConvertTo-Json -Compress -Depth 3)"
}

function Wait-UniqueAutomationWindow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label
    )

    $root = [Windows.Automation.AutomationElement]::RootElement
    $conditions = [Windows.Automation.Condition[]]@(
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ProcessIdProperty,
            $Process.Id
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty,
            $Name
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::Window
        )
    )
    $condition = [Windows.Automation.AndCondition]::new($conditions)
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $matches = $root.FindAll([Windows.Automation.TreeScope]::Children, $condition)
        if ($matches.Count -gt 1) {
            throw "$Label matched more than one top-level window."
        }
        if ($matches.Count -eq 1) {
            $element = $matches.Item(0)
            Assert-AutomationBinding `
                -Element $element `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label $Label `
                -RequireWindowHandle
            return $element
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Label was not found before the application exited."
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Label was not found before the bounded deadline."
}

function Invoke-AutomationControl {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Label
    )

    $pattern = $null
    if (-not $Element.TryGetCurrentPattern(
        [Windows.Automation.InvokePattern]::Pattern,
        [ref]$pattern
    )) {
        throw "$Label does not support UI Automation InvokePattern."
    }
    ([Windows.Automation.InvokePattern]$pattern).Invoke()
}

function Start-AutomationControlInvoke {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Label
    )

    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [Threading.ApartmentState]::MTA
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('automationElement', $Element)
    $runspace.SessionStateProxy.SetVariable('automationLabel', $Label)
    $powershell = [PowerShell]::Create()
    $powershell.Runspace = $runspace
    [void]$powershell.AddScript(@'
$invokePattern = $null
if (-not $automationElement.TryGetCurrentPattern(
    [Windows.Automation.InvokePattern]::Pattern,
    [ref]$invokePattern
)) {
    throw "$automationLabel does not support UI Automation InvokePattern."
}
([Windows.Automation.InvokePattern]$invokePattern).Invoke()
'@)
    try {
        $asyncResult = $powershell.BeginInvoke()
        [pscustomobject]@{
            powershell = $powershell
            runspace = $runspace
            async_result = $asyncResult
            label = $Label
            completed = $false
        }
    }
    catch {
        $powershell.Dispose()
        $runspace.Dispose()
        throw
    }
}

function Complete-AutomationControlInvoke {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    if ($State.completed) {
        return
    }
    $waitMilliseconds = [int]([Math]::Min(
        [int]::MaxValue,
        [Math]::Min(30, $TimeoutSeconds) * 1000L
    ))
    if (-not $State.async_result.AsyncWaitHandle.WaitOne($waitMilliseconds)) {
        throw "$($State.label) UI Automation invocation did not return before the bounded deadline."
    }
    try {
        [void]$State.powershell.EndInvoke($State.async_result)
        if ($State.powershell.HadErrors) {
            throw "$($State.label) UI Automation invocation failed."
        }
    }
    finally {
        $State.completed = $true
        $State.powershell.Dispose()
        $State.runspace.Dispose()
    }
}

function Set-AutomationControlValue {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Label
    )

    $pattern = $null
    if (-not $Element.TryGetCurrentPattern(
        [Windows.Automation.ValuePattern]::Pattern,
        [ref]$pattern
    )) {
        $editCondition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::Edit
        )
        $edits = $Element.FindAll([Windows.Automation.TreeScope]::Descendants, $editCondition)
        if ($edits.Count -ne 1 -or -not $edits.Item(0).TryGetCurrentPattern(
            [Windows.Automation.ValuePattern]::Pattern,
            [ref]$pattern
        )) {
            throw "$Label does not expose one UI Automation value control."
        }
    }
    $valuePattern = [Windows.Automation.ValuePattern]$pattern
    if ($valuePattern.Current.IsReadOnly) {
        throw "$Label is read-only."
    }
    $valuePattern.SetValue($Value)
    if ($valuePattern.Current.Value -cne $Value) {
        throw "$Label did not retain the exact requested value."
    }
}

function Wait-WindowClosed {
    param(
        [Parameter(Mandatory)][IntPtr] $Handle,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label
    )

    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    while ([DarkReNamerVmNative]::IsWindow($Handle) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ([DarkReNamerVmNative]::IsWindow($Handle)) {
        throw "$Label did not close before the bounded deadline."
    }
}

function Wait-ListPreviewName {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $ExpectedName,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $list = Find-UniqueAutomationElement `
        -Root $MainWindow `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -AutomationId '1000' `
        -TimeoutSeconds $TimeoutSeconds `
        -Label 'production file list' `
        -RequireWindowHandle
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        try {
            $gridObject = $null
            if ($list.TryGetCurrentPattern([Windows.Automation.GridPattern]::Pattern, [ref]$gridObject)) {
                $grid = [Windows.Automation.GridPattern]$gridObject
                if ($grid.Current.RowCount -eq 1 -and $grid.Current.ColumnCount -ge 2) {
                    $candidate = $grid.GetItem(0, 1)
                    if ($candidate.Current.Name -ceq $ExpectedName) {
                        return
                    }
                }
            }
        }
        catch [Windows.Automation.ElementNotAvailableException] {
        }
        $nameCondition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty,
            $ExpectedName
        )
        $matches = $list.FindAll([Windows.Automation.TreeScope]::Descendants, $nameCondition)
        if ($matches.Count -eq 1) {
            Assert-AutomationBinding `
                -Element $matches.Item(0) `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label 'production preview cell'
            return
        }
        if ($matches.Count -gt 1) {
            throw 'The expected production preview name was not unique.'
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw 'The expected production preview name was not exposed before the bounded deadline.'
}

function Save-WindowScreenshot {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-SafeLeafName -Value $Leaf -Label "$Label screenshot" -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.png$'
    Assert-AutomationBinding `
        -Element $Window `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label $Label `
        -RequireWindowHandle
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    if (-not [DarkReNamerVmNative]::IsWindowVisible($handle)) {
        throw "$Label is not visible for screenshot capture."
    }
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
        $Window.SetFocus()
        [void][DarkReNamerVmNative]::SetForegroundWindow($handle)
        $foregroundDeadline = (Get-Date).AddSeconds(5)
        while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle -and
            (Get-Date) -lt $foregroundDeadline) {
            Start-Sleep -Milliseconds 100
        }
    }
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
        throw "$Label is not the foreground window for screenshot capture."
    }
    $rect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
        throw "$Label bounds could not be read."
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0 -or
        $width -gt 16384 -or $height -gt 16384 -or
        ([long]$width * [long]$height) -gt 100000000) {
        throw "$Label bounds are invalid."
    }
    $bitmap = $null
    $graphics = $null
    try {
        $bitmap = [Drawing.Bitmap]::new(
            $width,
            $height,
            [Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen(
            $rect.Left,
            $rect.Top,
            0,
            0,
            $bitmap.Size,
            [Drawing.CopyPixelOperation]::SourceCopy
        )
        if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
            throw "$Label lost foreground during screenshot capture."
        }
        $firstColor = $bitmap.GetPixel(0, 0).ToArgb()
        $hasDifferentColor = $false
        $stepX = [Math]::Max(1, [int]($width / 64))
        $stepY = [Math]::Max(1, [int]($height / 64))
        for ($y = 0; $y -lt $height -and -not $hasDifferentColor; $y += $stepY) {
            for ($x = 0; $x -lt $width; $x += $stepX) {
                if ($bitmap.GetPixel($x, $y).ToArgb() -ne $firstColor) {
                    $hasDifferentColor = $true
                    break
                }
            }
        }
        if (-not $hasDifferentColor) {
            throw "$Label screenshot is a solid image."
        }
        $path = Join-Path $Root $Leaf
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        if ((Get-Item -LiteralPath $path).Length -le 0) {
            throw "$Label screenshot is empty."
        }
        [ordered]@{
            file = $Leaf
            sha256 = Get-LowerSha256 -Path $path
            width = $width
            height = $height
        }
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
}

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

function Invoke-ProductionRenameFlow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $sourceName = 'vm-flow-source.txt'
    $prefix = 'vm-confirmed-'
    $previewName = $prefix + $sourceName
    $sourcePath = Join-Path $FixtureRoot $sourceName
    $destinationPath = Join-Path $FixtureRoot $previewName
    $pendingInvocations = [Collections.Generic.List[object]]::new()
    $flow = [ordered]@{
        status = 'failed'
        scope = 'production-file-add-prefix-cancel-confirm'
        application_file = 'DarkReNamer.exe'
        application_sha256 = $null
        source_name = $sourceName
        preview_name = $previewName
        before_content_sha256 = $null
        after_content_sha256 = $null
        before_file_identity_sha256 = $null
        after_file_identity_sha256 = $null
        cancellation_source_present = $null
        cancellation_destination_present = $null
        confirmed_source_present = $null
        confirmed_destination_present = $null
        journal_residue_count = $null
        screenshots = @()
        diagnostic = $null
        failure_reason = 'fixture_setup_failed'
    }
    try {
        $flow.application_sha256 = Get-LowerSha256 -Path (Join-Path $Root 'DarkReNamer.exe')
        $fixtureBytes = [Text.UTF8Encoding]::new($false).GetBytes(
            "DarkReNamer production VM flow`nidentity and content must survive`n"
        )
        [IO.File]::WriteAllBytes($sourcePath, $fixtureBytes)
        $flow.before_content_sha256 = Get-LowerSha256 -Path $sourcePath
        $beforeFileIdentity = [DarkReNamerVmNative]::GetFileIdentity($sourcePath)
        $flow.before_file_identity_sha256 = Get-LowerTextSha256 -Value $beforeFileIdentity

        $flow.failure_reason = 'file_add_failed'
        $add = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8017) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'file-add command' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -Element $add -Label 'file-add command'
        $pendingInvocations.Add($invoke)

        $fileDialog = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Name '이름 붙일 파일 불러오기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'production file dialog'
        $fileDialogHandle = [IntPtr]$fileDialog.Current.NativeWindowHandle
        $fileName = Find-UniqueAutomationElement `
            -Root $fileDialog `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1148' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'file dialog filename control'
        Set-AutomationControlValue `
            -Element $fileName `
            -Value $sourcePath `
            -Label 'file dialog filename control'
        $open = Find-UniqueAutomationElement `
            -Root $fileDialog `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'file dialog open button' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $open -Label 'file dialog open button'
        Wait-WindowClosed -Handle $fileDialogHandle -TimeoutSeconds $TimeoutSeconds -Label 'production file dialog'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        Wait-ListPreviewName `
            -MainWindow $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -ExpectedName $sourceName `
            -TimeoutSeconds $TimeoutSeconds

        $flow.failure_reason = 'prefix_prompt_failed'
        $prefixCommand = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8005) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix command' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -Element $prefixCommand -Label 'prefix command'
        $pendingInvocations.Add($invoke)
        $prompt = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Name '이름 앞에 문자열 붙이기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt'
        $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
        $prefixEdit = Find-UniqueAutomationElement `
            -Root $prompt `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1004' `
            -ControlType ([Windows.Automation.ControlType]::Edit) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt edit' `
            -RequireWindowHandle
        Set-AutomationControlValue -Element $prefixEdit -Value $prefix -Label 'prefix prompt edit'
        $promptOk = Find-UniqueAutomationElement `
            -Root $prompt `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt confirmation' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $promptOk -Label 'prefix prompt confirmation'
        Wait-WindowClosed -Handle $promptHandle -TimeoutSeconds $TimeoutSeconds -Label 'prefix prompt'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        Wait-ListPreviewName `
            -MainWindow $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -ExpectedName $previewName `
            -TimeoutSeconds $TimeoutSeconds
        $flow.failure_reason = 'preview_verification_failed'
        $screenshots = [Collections.Generic.List[object]]::new()
        $screenshots.Add((Save-WindowScreenshot `
            -Window $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Root $Root `
            -Leaf 'rename-preview.png' `
            -Label 'production rename preview'))

        $flow.failure_reason = 'apply_cancellation_failed'
        $apply = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8003) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply command' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -Element $apply -Label 'apply command'
        $pendingInvocations.Add($invoke)
        $confirmation = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Name 'DarkReNamer - 안전한 적용 확인' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply confirmation task dialog'
        $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
        $screenshots.Add((Save-WindowScreenshot `
            -Window $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Root $Root `
            -Leaf 'apply-confirmation.png' `
            -Label 'apply confirmation task dialog'))
        $cancel = Find-UniqueAutomationElement `
            -Root $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '2' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply confirmation cancel button' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $cancel -Label 'apply confirmation cancel button'
        Wait-WindowClosed `
            -Handle $confirmationHandle `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'cancelled apply confirmation task dialog'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        $flow.cancellation_source_present = Test-Path -LiteralPath $sourcePath -PathType Leaf
        $flow.cancellation_destination_present = Test-Path -LiteralPath $destinationPath -PathType Leaf
        if (-not $flow.cancellation_source_present -or $flow.cancellation_destination_present -or
            (Get-LowerSha256 -Path $sourcePath) -cne $flow.before_content_sha256 -or
            [DarkReNamerVmNative]::GetFileIdentity($sourcePath) -cne $beforeFileIdentity) {
            throw 'Cancelling the production confirmation changed the fixture.'
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA

        $flow.failure_reason = 'confirmed_apply_failed'
        $apply = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8003) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply command after cancellation' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke `
            -Element $apply `
            -Label 'apply command after cancellation'
        $pendingInvocations.Add($invoke)
        $confirmation = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Name 'DarkReNamer - 안전한 적용 확인' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'second apply confirmation task dialog'
        $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
        $confirm = Find-UniqueAutomationElement `
            -Root $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1101' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'exact destructive confirmation button' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $confirm -Label 'exact destructive confirmation button'
        Wait-WindowClosed `
            -Handle $confirmationHandle `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'confirmed apply task dialog'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds

        $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
        do {
            $sourcePresent = Test-Path -LiteralPath $sourcePath -PathType Leaf
            $destinationPresent = Test-Path -LiteralPath $destinationPath -PathType Leaf
            if (-not $sourcePresent -and $destinationPresent) {
                try {
                    Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
                    break
                }
                catch {
                }
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $flow.confirmed_source_present = Test-Path -LiteralPath $sourcePath -PathType Leaf
        $flow.confirmed_destination_present = Test-Path -LiteralPath $destinationPath -PathType Leaf
        if ($flow.confirmed_source_present -or -not $flow.confirmed_destination_present) {
            throw 'The confirmed production apply did not perform the expected disk rename.'
        }
        $flow.after_content_sha256 = Get-LowerSha256 -Path $destinationPath
        $afterFileIdentity = [DarkReNamerVmNative]::GetFileIdentity($destinationPath)
        $flow.after_file_identity_sha256 = Get-LowerTextSha256 -Value $afterFileIdentity
        if ($flow.after_content_sha256 -cne $flow.before_content_sha256 -or
            $afterFileIdentity -cne $beforeFileIdentity) {
            throw 'The confirmed production rename did not preserve file contents and identity.'
        }
        $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
        $flow.journal_residue_count = if (Test-Path -LiteralPath $journalRoot) {
            @(
                Get-ChildItem -LiteralPath $journalRoot -Force |
                    Where-Object Name -cne 'runtime.lock'
            ).Count
        } else {
            0
        }
        $flow.screenshots = $screenshots.ToArray()
        $flow.status = 'passed'
        $flow.failure_reason = $null
    }
    catch {
        if ($flow.failure_reason -eq $null) {
            $flow.failure_reason = 'production_flow_error'
        }
        $diagnosticLeaf = 'gui-flow-error.txt'
        $diagnosticPath = Join-Path $Root $diagnosticLeaf
        $_ | Out-String | Set-Content -LiteralPath $diagnosticPath -Encoding UTF8
        $flow.diagnostic = [ordered]@{
            file = $diagnosticLeaf
            sha256 = Get-LowerSha256 -Path $diagnosticPath
        }
    }
    finally {
        $incomplete = @($pendingInvocations | Where-Object { -not $_.completed })
        if ($incomplete.Count -gt 0 -and -not $Process.HasExited) {
            Invoke-TaskkillTree -ProcessId $Process.Id
            [void]$Process.WaitForExit(10000)
        }
        foreach ($invocation in $incomplete) {
            try {
                if ($invocation.async_result.AsyncWaitHandle.WaitOne(10000)) {
                    [void]$invocation.powershell.EndInvoke($invocation.async_result)
                }
                else {
                    $invocation.powershell.Stop()
                }
            }
            catch {
            }
            finally {
                $invocation.completed = $true
                $invocation.powershell.Dispose()
                $invocation.runspace.Dispose()
            }
        }
    }
    [pscustomobject]$flow
}

function Invoke-GuiSmoke {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $row = [ordered]@{
        file = $Application.file
        sha256 = $Application.sha256
        status = 'failed'
        scope = 'launch-window-screenshot-normal-close'
        exit_code = $null
        window_class = $null
        window_title = $null
        screenshot = $null
        flow = $null
        failure_reason = 'process_start_failed'
    }
    $processState = [pscustomobject]@{ process = $null }
    $captureState = [pscustomobject]@{ bitmap = $null; graphics = $null }
    $flowFixtureRoot = $null
    $screenshotLeaf = 'main-workbench.png'
    $screenshotPath = Join-Path $Root $screenshotLeaf
    try {
        $applicationPath = Join-Path $Root $Application.file
        Assert-OrdinaryFile -Path $applicationPath -Label 'application'
        if ((Get-LowerSha256 -Path $applicationPath) -cne $Application.sha256) {
            $row.failure_reason = 'artifact_changed_after_preflight'
            return [pscustomobject]$row
        }
        Initialize-NativeCapture
        if (-not [DarkReNamerVmNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
            $row.failure_reason = 'dpi_awareness_failed'
            return [pscustomobject]$row
        }
        $caseRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'gui'
        Invoke-WithIsolatedEnvironment -RuntimeRoot $caseRoot -Action {
            $processState.process = Start-OwnedProcess `
                -FilePath $applicationPath `
                -Arguments '' `
                -WorkingDirectory $Root
            $windowDeadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
            do {
                Start-Sleep -Milliseconds 200
                $processState.process.process.Refresh()
                if ($processState.process.process.HasExited) {
                    $row.exit_code = $processState.process.process.ExitCode
                    $row.failure_reason = 'app_exited_before_window'
                    return
                }
            } while ($processState.process.process.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $windowDeadline)

            $handle = $processState.process.process.MainWindowHandle
            if ($handle -eq [IntPtr]::Zero) {
                $row.failure_reason = 'window_timeout'
                return
            }
            $boundProcessId = [uint32]0
            [void][DarkReNamerVmNative]::GetWindowThreadProcessId($handle, [ref]$boundProcessId)
            $classText = [Text.StringBuilder]::new(128)
            [void][DarkReNamerVmNative]::GetClassName($handle, $classText, $classText.Capacity)
            $windowClass = $classText.ToString()
            $windowTitle = $processState.process.process.MainWindowTitle
            if ($boundProcessId -ne $processState.process.process.Id -or
                $processState.process.process.SessionId -ne $ExpectedSession -or
                $windowClass -cne 'DarkReNamerWindow' -or
                $windowTitle -cne 'DarkReNamer' -or
                -not [DarkReNamerVmNative]::IsWindowVisible($handle)) {
                $row.failure_reason = 'unexpected_window'
                return
            }
            $row.window_class = $windowClass
            $row.window_title = $windowTitle

            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                try {
                    $automationElement = [Windows.Automation.AutomationElement]::FromHandle($handle)
                    if ($null -ne $automationElement) {
                        $automationElement.SetFocus()
                    }
                }
                catch {
                }
                [void][DarkReNamerVmNative]::SetForegroundWindow($handle)
                $foregroundDeadline = (Get-Date).AddSeconds(5)
                while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle -and
                    (Get-Date) -lt $foregroundDeadline) {
                    Start-Sleep -Milliseconds 100
                }
            }
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                $row.failure_reason = 'window_not_foreground'
                return
            }

            $rect = [DarkReNamerVmNative+Rect]::new()
            if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
                $row.failure_reason = 'window_bounds_failed'
                return
            }
            $width = $rect.Right - $rect.Left
            $height = $rect.Bottom - $rect.Top
            if ($width -le 0 -or $height -le 0 -or
                $width -gt 16384 -or $height -gt 16384 -or
                ([long]$width * [long]$height) -gt 100000000) {
                $row.failure_reason = 'window_bounds_invalid'
                return
            }
            $captureState.bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $captureState.graphics = [Drawing.Graphics]::FromImage($captureState.bitmap)
            $captureState.graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $captureState.bitmap.Size, [Drawing.CopyPixelOperation]::SourceCopy)
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                $row.failure_reason = 'foreground_changed_during_capture'
                return
            }
            $firstColor = $captureState.bitmap.GetPixel(0, 0).ToArgb()
            $hasDifferentColor = $false
            $stepX = [Math]::Max(1, [int]($width / 64))
            $stepY = [Math]::Max(1, [int]($height / 64))
            for ($y = 0; $y -lt $height -and -not $hasDifferentColor; $y += $stepY) {
                for ($x = 0; $x -lt $width; $x += $stepX) {
                    if ($captureState.bitmap.GetPixel($x, $y).ToArgb() -ne $firstColor) {
                        $hasDifferentColor = $true
                        break
                    }
                }
            }
            if (-not $hasDifferentColor) {
                $row.failure_reason = 'screenshot_solid'
                return
            }
            $captureState.graphics.Dispose()
            $captureState.graphics = $null
            $captureState.bitmap.Save($screenshotPath, [Drawing.Imaging.ImageFormat]::Png)
            $captureState.bitmap.Dispose()
            $captureState.bitmap = $null
            if ((Get-Item -LiteralPath $screenshotPath).Length -le 0) {
                $row.failure_reason = 'screenshot_empty'
                return
            }
            $row.screenshot = [ordered]@{
                file = $screenshotLeaf
                sha256 = Get-LowerSha256 -Path $screenshotPath
                width = $width
                height = $height
            }

            $mainAutomationWindow = [Windows.Automation.AutomationElement]::FromHandle($handle)
            if ($null -eq $mainAutomationWindow) {
                $row.failure_reason = 'main_window_automation_unavailable'
                return
            }
            Assert-AutomationBinding `
                -Element $mainAutomationWindow `
                -Process $processState.process.process `
                -ExpectedSession $ExpectedSession `
                -Label 'production main window' `
                -RequireWindowHandle
            $flowFixtureRoot = New-PrivateDirectory -Parent $caseRoot -Leaf 'rename-flow'
            $row.flow = Invoke-ProductionRenameFlow `
                -Process $processState.process.process `
                -MainWindow $mainAutomationWindow `
                -FixtureRoot $flowFixtureRoot `
                -Root $Root `
                -ExpectedSession $ExpectedSession `
                -TimeoutSeconds $TimeoutSeconds
            if ($row.flow.status -cne 'passed') {
                $row.failure_reason = 'production_rename_flow_failed'
                return
            }

            if (-not $processState.process.process.CloseMainWindow()) {
                $row.failure_reason = 'normal_close_rejected'
                return
            }
            if (-not $processState.process.process.WaitForExit(10000)) {
                $row.failure_reason = 'normal_close_timeout'
                return
            }
            $processState.process.process.WaitForExit()
            $row.exit_code = $processState.process.process.ExitCode
            if ($processState.process.process.ExitCode -ne 0) {
                $row.failure_reason = 'app_exit_failed'
                return
            }
            $row.status = 'passed'
            $row.failure_reason = $null
        }
    }
    catch {
        $row.failure_reason = 'gui_error'
    }
    finally {
        if ($null -ne $captureState.graphics) { $captureState.graphics.Dispose() }
        if ($null -ne $captureState.bitmap) { $captureState.bitmap.Dispose() }
        if ($null -ne $processState.process) {
            try {
                $processState.process.process.Refresh()
                if (-not $processState.process.process.HasExited) {
                    Invoke-TaskkillTree -ProcessId $processState.process.process.Id
                    if (-not $processState.process.process.WaitForExit(10000)) {
                        throw 'Owned application process did not terminate.'
                    }
                }
            }
            catch {
                $row.status = 'failed'
                $row.failure_reason = 'process_cleanup_failed'
            }
            $processState.process.process.Dispose()
        }
        if ($null -ne $flowFixtureRoot -and (Test-Path -LiteralPath $flowFixtureRoot)) {
            try {
                $fixtureItem = Get-Item -LiteralPath $flowFixtureRoot -Force
                if (($fixtureItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Production flow fixture became a reparse point.'
                }
                Remove-Item -LiteralPath $flowFixtureRoot -Recurse -Force
                if (Test-Path -LiteralPath $flowFixtureRoot) {
                    throw 'Production flow fixture cleanup was incomplete.'
                }
            }
            catch {
                $row.status = 'failed'
                $row.failure_reason = 'flow_fixture_cleanup_failed'
            }
        }
    }
    [pscustomobject]$row
}

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
    $json = $Result | ConvertTo-Json -Depth 8
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

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$verified = Resolve-VerifiedBundle -Root $BundleRoot -InvokedScriptPath $PSCommandPath
if ($ValidateOnly) {
    Write-Host "Validated Windows VM bundle for source $($verified.manifest.source_sha)."
    return
}

$result = [ordered]@{
    schema_version = 1
    source_sha = $verified.manifest.source_sha
    source_state = $verified.manifest.source_state
    target = $verified.manifest.target
    status = 'failed'
    tests = @()
    gui = $null
    failure_reason = $null
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    $result.failure_reason = 'unsupported_platform'
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution requires Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $result.failure_reason = 'elevated_runner'
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution must be non-elevated.'
}
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($currentSession -ne $ExpectedSessionId) {
    $result.failure_reason = 'unexpected_session'
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution is in an unexpected session.'
}

$desktopLock = $null
$previousExecutionState = $null
try {
    $desktopLock = Enter-DesktopTestLock -SessionId $currentSession
    if ($null -eq $desktopLock) {
        $result.failure_reason = 'desktop_busy'
        throw 'Another Windows VM test runner is using this interactive desktop.'
    }
    $previousExecutionState = Enter-TestExecutionState
    $runtimeRoot = New-PrivateDirectory -Parent $verified.root -Leaf 'runtime'
    $testResults = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $verified.tests.Count; $index++) {
        $testResults.Add((Invoke-RustTestBinary `
            -Test $verified.tests[$index] `
            -Root $verified.root `
            -RuntimeRoot $runtimeRoot `
            -Index ($index + 1) `
            -TimeoutSeconds $TestTimeoutSeconds))
        $result.tests = $testResults.ToArray()
    }
    $result.gui = Invoke-GuiSmoke `
        -Application $verified.manifest.application `
        -Root $verified.root `
        -RuntimeRoot $runtimeRoot `
        -ExpectedSession $ExpectedSessionId `
        -TimeoutSeconds $TestTimeoutSeconds

    $testFailures = @($result.tests | Where-Object { $_.status -cne 'passed' })
    if ($testFailures.Count -eq 0 -and $result.gui.status -ceq 'passed') {
        $result.status = 'passed'
    }
}
catch {
    $result.status = 'failed'
    if ($null -eq $result.failure_reason) {
        $result.failure_reason = 'runner_error'
    }
}
finally {
    try {
        try {
            Exit-TestExecutionState -Previous $previousExecutionState
        }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'execution_state_restore_failed'
        }
        Write-ResultDocument -Root $verified.root -Result $result
    }
    finally {
        Exit-DesktopTestLock -Lock $desktopLock
    }
}
if ($result.status -cne 'passed') {
    throw 'Windows VM guest validation failed; inspect result.json.'
}
