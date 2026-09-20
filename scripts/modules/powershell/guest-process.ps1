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
