function Resolve-AcceptanceRescuePollState {
    param(
        [AllowNull()][string] $ResultStatus,
        [Parameter(Mandatory = $true)][string] $TaskState,
        [Parameter(Mandatory = $true)][object] $TaskResult,
        [Parameter(Mandatory = $true)][long] $RegisteredLastRunTimeTicks,
        [Parameter(Mandatory = $true)][long] $LastRunTimeTicks
    )

    if (($TaskResult -isnot [int] -and $TaskResult -isnot [long] -and
            $TaskResult -isnot [uint32]) -or
        [decimal]$TaskResult -lt 0 -or [decimal]$TaskResult -gt [uint32]::MaxValue) {
        throw 'Rescue task polling returned an invalid LastTaskResult.'
    }
    if ($RegisteredLastRunTimeTicks -lt 0 -or $LastRunTimeTicks -lt 0) {
        throw 'Rescue task polling returned an invalid LastRunTime.'
    }
    [pscustomobject][ordered]@{
        result_status = $ResultStatus
        task_state = $TaskState
        task_result = [long]$TaskResult
        last_run_time_ticks = $LastRunTimeTicks
        terminal = $TaskState -ceq 'Ready' -and
            $LastRunTimeTicks -gt $RegisteredLastRunTimeTicks
    }
}
function Resolve-ObserverTaskPollState {
    param(
        [AllowNull()][string] $ResultStatus,
        [Parameter(Mandatory = $true)][string] $TaskState,
        [Parameter(Mandatory = $true)][object] $TaskResult,
        [Parameter(Mandatory = $true)][long] $RegisteredLastRunTimeTicks,
        [Parameter(Mandatory = $true)][long] $LastRunTimeTicks
    )

    if (($TaskResult -isnot [int] -and $TaskResult -isnot [long] -and
            $TaskResult -isnot [uint32]) -or
        [decimal]$TaskResult -lt 0 -or [decimal]$TaskResult -gt [uint32]::MaxValue) {
        throw 'Observer task polling returned an invalid LastTaskResult.'
    }
    if ($RegisteredLastRunTimeTicks -lt 0 -or $LastRunTimeTicks -lt 0) {
        throw 'Observer task polling returned an invalid LastRunTime.'
    }
    [pscustomobject][ordered]@{
        result_status = $ResultStatus
        task_state = $TaskState
        task_result = [long]$TaskResult
        last_run_time_ticks = $LastRunTimeTicks
        terminal = $TaskState -ceq 'Ready' -and
            $LastRunTimeTicks -gt $RegisteredLastRunTimeTicks
    }
}
function Stop-AcceptanceObserverTaskForRescue {
    param(
        [Parameter(Mandatory = $true)][object] $Session,
        [Parameter(Mandatory = $true)][string] $GuestRoot,
        [Parameter(Mandatory = $true)][string] $TaskName,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds
    )

    Invoke-Command -Session $Session -ArgumentList $GuestRoot,$TaskName,$TimeoutSeconds -ScriptBlock {
        param($root,$name,$timeout)
        $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        if ($task.State.ToString() -cne 'Ready') {
            Stop-ScheduledTask -TaskName $name -ErrorAction Stop
        }
        $deadline = (Get-Date).AddSeconds([Math]::Max(5, [Math]::Min(60, $timeout)))
        $observerToken = '"' + (Join-Path $root 'windows-vm-acceptance.ps1') + '"'
        $rootToken = $root + '\'
        do {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            $taskState = $task.State.ToString()
            if ($taskState -cne 'Ready') {
                Stop-ScheduledTask -TaskName $name -ErrorAction Stop
            }
            $ownedObserverProcesses = @(Get-CimInstance Win32_Process | Where-Object {
                $_.Name -iin @('cmd.exe', 'pwsh.exe') -and
                $_.CommandLine -and
                $_.CommandLine.IndexOf($observerToken, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $_.CommandLine.IndexOf($rootToken, [StringComparison]::OrdinalIgnoreCase) -ge 0
            })
            if ($taskState -ceq 'Ready' -and $ownedObserverProcesses.Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 200
        } while ((Get-Date) -lt $deadline)
        if ($taskState -cne 'Ready' -or $ownedObserverProcesses.Count -ne 0) {
            throw 'Acceptance recovery timed out while stopping the original observer task.'
        }
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            throw 'Acceptance recovery could not prove the original observer task was removed.'
        }
    }
}
function Test-AcceptanceRestoreSnapshot {
    param(
        [Parameter(Mandatory = $true)][object] $Session,
        [Parameter(Mandatory = $true)][string] $GuestRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('text-scale-snapshot.json', 'high-contrast-restore.json')]
        [string] $Leaf
    )

    Invoke-Command -Session $Session -ArgumentList $GuestRoot,$Leaf -ScriptBlock {
        param($root,$leaf)
        $path = Join-Path (Join-Path $root 'out') $leaf
        if (-not (Test-Path -LiteralPath $path)) {
            return $false
        }
        $snapshot = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($snapshot.PSIsContainer -or
            ($snapshot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $snapshot.Length -gt 4MB) {
            throw 'Acceptance recovery snapshot is not one bounded ordinary file.'
        }
        $true
    }
}
function Invoke-AcceptancePollFailureRescue {
    param(
        [Parameter(Mandatory = $true)][object] $Session,
        [Parameter(Mandatory = $true)][string] $GuestRoot,
        [Parameter(Mandatory = $true)][string] $DesktopSid,
        [Parameter(Mandatory = $true)][int] $DesktopSessionId,
        [Parameter(Mandatory = $true)][string] $TaskName,
        [Parameter(Mandatory = $true)][int] $TestTimeoutSeconds,
        [Parameter(Mandatory = $true)][int] $SuiteTimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $ObserverSha256,
        [Parameter(Mandatory = $true)][string] $AcceptanceMode,
        [Parameter(Mandatory = $true)][string] $Appearance,
        [Parameter(Mandatory = $true)][bool] $HighContrast,
        [Parameter(Mandatory = $true)][string] $HostOutputRoot,
        [Parameter(Mandatory = $true)][object] $OriginalFailure
    )

    try {
        Stop-AcceptanceObserverTaskForRescue `
            -Session $Session -GuestRoot $GuestRoot -TaskName $TaskName `
            -TimeoutSeconds $TestTimeoutSeconds
        if ($AcceptanceMode -ceq 'text-scale' -and
            (Test-AcceptanceRestoreSnapshot `
                -Session $Session -GuestRoot $GuestRoot -Leaf 'text-scale-snapshot.json')) {
            Invoke-AcceptanceTextScaleRescue `
                -Session $Session `
                -GuestRoot $GuestRoot `
                -DesktopSid $DesktopSid `
                -DesktopSessionId $DesktopSessionId `
                -TaskName $TaskName `
                -TestTimeoutSeconds $TestTimeoutSeconds `
                -SuiteTimeoutSeconds $SuiteTimeoutSeconds `
                -ObserverSha256 $ObserverSha256 `
                -Appearance $Appearance `
                -HostOutputRoot $HostOutputRoot
        }
        if ($HighContrast -and
            (Test-AcceptanceRestoreSnapshot `
                -Session $Session -GuestRoot $GuestRoot -Leaf 'high-contrast-restore.json')) {
            Invoke-AcceptanceHighContrastRescue `
                -Session $Session `
                -GuestRoot $GuestRoot `
                -DesktopSid $DesktopSid `
                -DesktopSessionId $DesktopSessionId `
                -TaskName $TaskName `
                -TestTimeoutSeconds $TestTimeoutSeconds `
                -SuiteTimeoutSeconds $SuiteTimeoutSeconds `
                -ObserverSha256 $ObserverSha256 `
                -HostOutputRoot $HostOutputRoot
        }
    }
    catch {
        try {
            $_ | Out-String | Set-Content `
                -LiteralPath (Join-Path $HostOutputRoot 'observer-rescue-error.txt') `
                -Encoding UTF8
        }
        catch {}
    }
    throw $OriginalFailure
}
