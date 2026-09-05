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
    $startInfo.UseShellExecute = $false
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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);
}
'@
    }
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName UIAutomationClient
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
        failure_reason = 'process_start_failed'
    }
    $processState = [pscustomobject]@{ process = $null }
    $captureState = [pscustomobject]@{ bitmap = $null; graphics = $null }
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

try {
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
    $result.failure_reason = 'runner_error'
}
finally {
    Write-ResultDocument -Root $verified.root -Result $result
}
if ($result.status -cne 'passed') {
    throw 'Windows VM guest validation failed; inspect result.json.'
}
