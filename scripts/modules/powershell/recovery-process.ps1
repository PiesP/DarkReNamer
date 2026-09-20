function Stop-AndDisposeAcceptanceOwnedProcess {
    param([Parameter(Mandatory)][object] $Owned)

    $process = $Owned.process
    try {
        $process.Refresh()
        if (-not $process.HasExited) {
            $process.Kill()
            if (-not $process.WaitForExit(10000)) {
                throw 'The exact owned acceptance process did not terminate.'
            }
        }
    }
    finally {
        $process.Dispose()
    }
}
function Start-AcceptanceApplication {
    param(
        [Parameter(Mandatory)][object] $Inputs,
        [Parameter(Mandatory)][int] $SessionId,
        [Parameter(Mandatory)][int] $WaitSeconds
    )

    $application = $Inputs.contract.application
    if ((Get-LowerSha256 -Path $Inputs.application_path) -cne $application.sha256) {
        throw 'The application changed after bundle verification.'
    }
    $owned = $null
    try {
        $owned = Start-OwnedProcess `
            -FilePath $Inputs.application_path `
            -Arguments '' `
            -WorkingDirectory $Inputs.verified.root
        $owned.process.Refresh()
        if ($owned.process.HasExited) {
            throw 'The source-bound application exited before creating its window.'
        }
        if ($owned.process.SessionId -ne $SessionId) {
            throw 'The application did not create a window in the expected session.'
        }
        $binding = Wait-ExactApplicationMainWindow `
            -Process $owned.process `
            -ExpectedSession $SessionId `
            -ExpectedClassName 'DarkReNamerWindow' `
            -ExpectedTitle 'DarkReNamer' `
            -TimeoutSeconds $WaitSeconds `
            -Label 'recovery acceptance main window'
        $actualProcessPath = $owned.process.MainModule.FileName
        if (-not [string]::Equals(
            $actualProcessPath,
            $Inputs.application_path,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'The owned process is not the verified application artifact.'
        }
        [pscustomobject]@{
            owned = $owned
            main = $binding.element
            main_handle = $binding.handle
            session_id = $SessionId
        }
    }
    catch {
        $startupError = $_
        if ($null -ne $owned) {
            try {
                Stop-AndDisposeAcceptanceOwnedProcess -Owned $owned
            }
            catch {
                throw "Application startup validation and exact-process cleanup both failed: $($startupError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
        }
        throw $startupError
    }
}
function Write-AcceptanceProcessStartEvidence {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][object] $Inputs,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Role
    )

    if ($Role -cnotmatch '^[a-z0-9][a-z0-9-]{0,31}$') {
        throw 'The process evidence role is invalid.'
    }
    $process = $Application.owned.process
    $process.Refresh()
    if ($process.HasExited) {
        throw 'The candidate process exited before its raw start observation.'
    }
    Assert-ExactApplicationMainWindowBinding `
        -Process $process `
        -ExpectedSession $Application.session_id `
        -MainWindowHandle $Application.main_handle `
        -MainWindow $Application.main `
        -ExpectedClassName 'DarkReNamerWindow' `
        -ExpectedTitle 'DarkReNamer' `
        -Label 'recovery start environment'
    $script:AcceptanceProcessSequence++
    $sequence = $script:AcceptanceProcessSequence
    $startUtc = $process.StartTime.ToUniversalTime()
    $environment = Get-VmAutomatedEnvironment `
        -Process $process `
        -WindowHandle $Application.main_handle `
        -FixtureRoot $FixtureRoot
    $binding = [pscustomobject][ordered]@{
        sequence = $sequence
        role = $Role
        pid = [int]$process.Id
        session_id = [int]$process.SessionId
        start_time_utc_ticks = $startUtc.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
        executable_path = $process.MainModule.FileName
        executable_sha256 = Get-LowerSha256 -Path $Inputs.application_path
    }
    $observedRootIdentity = Get-FullFileIdentity -Path $FixtureRoot
    [void](Get-AcceptanceIdentityKey -Identity $observedRootIdentity)
    [void](Get-AcceptanceIdentityKey -Identity $environment.fixture_volume.root_identity)
    if (-not (Test-AcceptanceIdentityEqual `
            -Expected $observedRootIdentity `
            -Actual $environment.fixture_volume.root_identity)) {
        throw 'The process environment fixture-root identity does not match FILE_ID_INFO.'
    }
    $observedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $lifecycle = [pscustomobject][ordered]@{
        pid = $binding.pid
        session_id = $binding.session_id
        start_time_utc_ticks = $binding.start_time_utc_ticks
        executable_path = $binding.executable_path
        executable_sha256 = $binding.executable_sha256
        start_observed = $true
        exit_observed = $false
        exit_method = $null
        exit_code = $null
    }
    $path = Join-Path $PrivateRoot ('process-{0:D2}-started.json' -f $sequence)
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = 'started'
        observed_utc_ticks = $observedUtcTicks
        binding = $binding
        lifecycle = $lifecycle
        environment = $environment
    })
    # Keep the original process object and kernel handle alive through exit.
    # SessionId is no longer queryable reliably after Refresh on an exited process.
    $Application | Add-Member -NotePropertyName raw_process_object -NotePropertyValue $process -Force
    $Application | Add-Member -NotePropertyName raw_process_handle `
        -NotePropertyValue $process.SafeHandle.DangerousGetHandle() -Force
    $Application | Add-Member -NotePropertyName raw_process_binding -NotePropertyValue $binding -Force
    $Application | Add-Member -NotePropertyName raw_process_exit_recorded -NotePropertyValue $false -Force
    $Application | Add-Member -NotePropertyName raw_process_start_reference `
        -NotePropertyValue (New-AcceptancePrivateReference `
            -Path $path -PrivateRoot $PrivateRoot -Boundary 'started') -Force
    $Application.raw_process_start_reference
}
function Assert-AcceptanceProcessBinding {
    param([Parameter(Mandatory)][object] $Application)

    $process = $Application.owned.process
    $binding = $Application.raw_process_binding
    $process.Refresh()
    if (-not [Object]::ReferenceEquals($process, $Application.raw_process_object) -or
        $process.SafeHandle.IsClosed -or $process.SafeHandle.IsInvalid -or
        $process.SafeHandle.DangerousGetHandle() -ne $Application.raw_process_handle -or
        $process.Id -ne $binding.pid -or
        (-not $process.HasExited -and $process.SessionId -ne $binding.session_id) -or
        $process.StartTime.ToUniversalTime().Ticks.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ) -cne $binding.start_time_utc_ticks) {
        throw 'The candidate process identity changed during raw observation.'
    }
}
function Write-AcceptanceProcessExitEvidence {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][ValidateSet('crash-stop', 'normal-exit', 'failure-cleanup')]
        [string] $Boundary,
        [Parameter(Mandatory)][ValidateSet('normal-close', 'forced-termination', 'worker-close')]
        [string] $ExitMethod
    )

    if ($Application.raw_process_exit_recorded) {
        throw 'The candidate process exit was already recorded.'
    }
    Assert-AcceptanceProcessBinding -Application $Application
    $process = $Application.owned.process
    if (-not $process.HasExited) {
        throw 'The candidate process is still running at an exit-evidence boundary.'
    }
    $process.WaitForExit()
    $observedUtcTicks = [DateTime]::UtcNow.Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $sequence = $Application.raw_process_binding.sequence
    $path = Join-Path $PrivateRoot ('process-{0:D2}-{1}.json' -f $sequence, $Boundary)
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = $Boundary
        observed_utc_ticks = $observedUtcTicks
        binding = $Application.raw_process_binding
        lifecycle = [ordered]@{
            pid = $Application.raw_process_binding.pid
            session_id = $Application.raw_process_binding.session_id
            start_time_utc_ticks = $Application.raw_process_binding.start_time_utc_ticks
            executable_path = $Application.raw_process_binding.executable_path
            executable_sha256 = $Application.raw_process_binding.executable_sha256
            start_observed = $true
            exit_observed = $true
            exit_method = $ExitMethod
            exit_code = [int]$process.ExitCode
        }
    })
    $Application.raw_process_exit_recorded = $true
    New-AcceptancePrivateReference -Path $path -PrivateRoot $PrivateRoot -Boundary $Boundary
}
function Write-AcceptanceForegroundEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[object]] $Observations
    )

    if ($Observations.Count -lt 1 -or $Observations.Count -gt 8) {
        throw 'Recovery screenshot foreground evidence is missing or unbounded.'
    }
    $path = Join-Path $PrivateRoot 'foreground-observations.json'
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        observations = $Observations.ToArray()
    })
    New-AcceptancePrivateReference `
        -Path $path `
        -PrivateRoot $PrivateRoot `
        -Boundary 'screenshot-foreground-observations'
}
function Write-AcceptanceWorkerPartialWitnessEvidence {
    param(
        [Parameter(Mandatory)][string] $PrivateRoot,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][object] $ExpectedRootIdentity,
        [Parameter(Mandatory)][object] $Witness
    )

    if ($Leaf -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or
        @($Witness.entries).Count -ne 2 -or
        $Witness.candidate_pid -le 0 -or
        $Witness.candidate_session_id -lt 0) {
        throw 'The worker partial witness is malformed or unbounded.'
    }
    $rootIdentity = Get-FullFileIdentity -Path $FixtureRoot
    [void](Get-AcceptanceIdentityKey -Identity $rootIdentity)
    if (-not (Test-AcceptanceIdentityEqual `
            -Expected $ExpectedRootIdentity `
            -Actual $rootIdentity)) {
        throw 'The fixture-root identity changed at the worker partial witness.'
    }
    $roles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Witness.entries)) {
        if ($entry.role -cnotin @('first-destination', 'last-original') -or
            $entry.name -isnot [string] -or
            $entry.kind -cne 'file' -or
            $entry.bytes -lt 0 -or $entry.bytes -gt 64MB -or
            $entry.content_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $entry.observed_utc_ticks -cnotmatch '^[0-9]+$') {
            throw 'The worker partial witness contains an invalid file observation.'
        }
        if (-not $roles.Add($entry.role)) {
            throw 'The worker partial witness contains a duplicate role.'
        }
        [void](Get-AcceptanceIdentityKey -Identity $entry.file_identity)
    }
    $path = Join-Path $PrivateRoot ($Leaf + '.json')
    Write-AcceptanceNewUtf8Json -Path $path -Value ([ordered]@{
        schema_version = 1
        boundary = 'worker-partial'
        candidate_pid = [int]$Witness.candidate_pid
        candidate_session_id = [int]$Witness.candidate_session_id
        fixture_root = $FixtureRoot
        root_identity = $rootIdentity
        entries = @($Witness.entries)
    })
    New-AcceptancePrivateReference `
        -Path $path -PrivateRoot $PrivateRoot -Boundary 'worker-partial'
}
function Select-AcceptanceUiDiagnosticApplication {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Applications)

    $latest = $null
    for ($index = $Applications.Count - 1; $index -ge 0; $index--) {
        $application = $Applications[$index]
        if ($null -eq $application) {
            continue
        }
        if ($null -eq $latest) {
            $latest = $application
        }
        try {
            $process = $application.owned.process
            $process.Refresh()
            if (-not $process.HasExited) {
                return $application
            }
        }
        catch {
        }
    }
    return $latest
}
function Get-AcceptanceUiDiagnostic {
    param([AllowNull()][object] $Application)

    if ($null -eq $Application) {
        return [pscustomobject]@{
            process_state = 'not-started'
            window_titles = @()
            status_message = $null
            status_count = $null
            row_count = $null
        }
    }
    $process = $Application.owned.process
    $process.Refresh()
    if ($process.HasExited) {
        return [pscustomobject]@{
            process_state = 'exited'
            exit_code = $process.ExitCode
            window_titles = @()
            status_message = $null
            status_count = $null
            row_count = $null
        }
    }
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ProcessIdProperty,
        $process.Id
    )
    $elements = [Windows.Automation.AutomationElement]::RootElement.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        $condition
    )
    $titles = [Collections.Generic.List[string]]::new()
    $statusMessage = $null
    $statusCount = $null
    $rowCount = $null
    foreach ($element in $elements) {
        try {
            if ($element.Current.ControlType -eq [Windows.Automation.ControlType]::Window -and
                -not [string]::IsNullOrEmpty($element.Current.Name)) {
                $titles.Add($element.Current.Name)
            }
            switch ($element.Current.AutomationId) {
                '1007' { $statusMessage = $element.Current.Name }
                '1008' { $statusCount = $element.Current.Name }
                '1000' {
                    $gridObject = $null
                    if ($element.TryGetCurrentPattern(
                        [Windows.Automation.GridPattern]::Pattern,
                        [ref]$gridObject
                    )) {
                        $rowCount = ([Windows.Automation.GridPattern]$gridObject).Current.RowCount
                    }
                    else {
                        $rowCount = $element.FindAll(
                            [Windows.Automation.TreeScope]::Children,
                            [Windows.Automation.Condition]::TrueCondition
                        ).Count
                    }
                }
            }
        }
        catch [Windows.Automation.ElementNotAvailableException] {
        }
    }
    [pscustomobject]@{
        process_state = 'running'
        window_titles = @($titles | Sort-Object -Unique)
        status_message = $statusMessage
        status_count = $statusCount
        row_count = $rowCount
    }
}
