function Invoke-AcceptanceTextScaleRescue {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)][string] $GuestRoot,
        [Parameter(Mandatory = $true)][string] $DesktopSid,
        [Parameter(Mandatory = $true)][int] $DesktopSessionId,
        [Parameter(Mandatory = $true)][string] $TaskName,
        [Parameter(Mandatory = $true)][int] $TestTimeoutSeconds,
        [Parameter(Mandatory = $true)][int] $SuiteTimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $ObserverSha256,
        [Parameter(Mandatory = $true)][object[]] $BundleRecords,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string] $InputManifestSha256,
        [Parameter(Mandatory = $true)][string] $Appearance,
        [ValidateSet('text-scale', 'appearance-pair')][string] $RegressionMode = 'text-scale',
        [Parameter(Mandatory = $true)][string] $HostOutputRoot,
        [string] $AcceptanceProfileId = 'vm-automated-v1-win11-ntfs',
        [AllowNull()][object] $EngineEvidence
    )

    $v2 = $AcceptanceProfileId -ceq 'vm-automated-v2-owned-resources'
    if ($v2) { $script:DrVmV2RescueAttempts++ }
    $rescueTimeout = [Math]::Max(120, [Math]::Min(600, $SuiteTimeoutSeconds))
    $rescueGeneration = Invoke-Command -Session $Session -ArgumentList $GuestRoot,$DesktopSid,$DesktopSessionId,$TaskName,$TestTimeoutSeconds,$rescueTimeout,$ObserverSha256,$Appearance,$RegressionMode,$BundleRecords,$InputManifestSha256,$v2,$EngineEvidence -ScriptBlock {
        param($root,$sid,$desktopSession,$name,$testTimeout,$rescueSeconds,$observerHash,$appearance,$mode,$bundleRecords,$inputManifestHash,$v2,$preflightEngine)
        $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
        }
        $trustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
        $observerPath = Join-Path $trustedRoot 'windows-vm-acceptance.ps1'
        if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) {
            throw 'Transferred acceptance observer changed before text-scale rescue.'
        }
        $bundle = Join-Path $trustedRoot 'bundle'
        $out = Join-Path $trustedRoot 'out'
        $runtime = [IO.Path]::GetFullPath((Join-Path $root 'runtime'))
        $snapshot = Get-Item -LiteralPath (Join-Path $out 'text-scale-snapshot.json') -Force -ErrorAction Stop
        if ($snapshot.PSIsContainer -or ($snapshot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Text-scale rescue snapshot is not an ordinary file.'
        }
        $inputManifest = Join-Path $trustedRoot 'input-manifest.json'
        $powerShell = Get-DrVmTrustedPowerShellPath
        if ($v2) { $engine = $preflightEngine }
        else {
            $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
                '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell rescue engine.' }
            $engine = $engineJson | ConvertFrom-Json
        }
        if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
            $engine.effective_policy -cne 'RemoteSigned') {
            throw 'Text-scale rescue requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
        }
        $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -RuntimeRoot "' + $runtime + '" -ExpectedScriptSha256 ' + $observerHash + ' -TimeoutSeconds ' + $testTimeout + ' -Appearance ' + $appearance + ' -RegressionMode ' + $mode + ' -InputManifestPath "' + $inputManifest + '" -TextScalePercent 150 -RestoreTextScaleOnly'
        if ($v2) { $observerArguments += ' -AcceptanceProfileId vm-automated-v2-owned-resources' }
        $registeredTask = Register-DrVmTask `
            -TaskName $name `
            -UserSid $sid `
            -SessionId $desktopSession `
            -GuestRoot $root `
            -RuntimeRoot $runtime `
            -ObserverPath $observerPath `
            -ObserverSha256 $observerHash `
            -BundleSourcePath $bundle `
            -BundleRecords $bundleRecords `
            -InputManifestPath $inputManifest `
            -InputManifestSha256 $inputManifestHash `
            -Execute $powerShell `
            -Arguments $observerArguments `
            -WorkingDirectory $root `
            -TrustedResultLeaf 'text-scale-rescue-result.json' `
            -ExecutionTimeLimitSeconds ($rescueSeconds + 30)
        $actualAction = if ($v2) { $registeredTask.Definition.Actions.Item(1) } else { $null }
        $registered = Get-ScheduledTaskInfo -TaskName $name
        $registeredTicks = [long]$registered.LastRunTime.Ticks
        Start-ScheduledTask -TaskName $name | Out-Null
        [pscustomobject][ordered]@{
            registered_last_run_time_ticks = $registeredTicks
            action_executable = if ($v2) { [string]$actualAction.Path } else { $null }
            action_arguments = if ($v2) { [string]$actualAction.Arguments } else { $null }
        }
    }

    $deadline = (Get-Date).AddSeconds($rescueTimeout)
    $rescue = $null
    do {
        Start-Sleep -Seconds 2
        $observed = Invoke-Command -Session $Session -ArgumentList $GuestRoot,$TaskName -ScriptBlock {
            param($root,$name)
            $resultPath = Join-Path (Join-Path (Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')) 'out') 'text-scale-rescue-result.json'
            $info = Get-ScheduledTaskInfo -TaskName $name
            $task = Get-ScheduledTask -TaskName $name
            $taskState = $task.State.ToString()
            $taskResult = [long]$info.LastTaskResult
            if ($taskState -ceq 'Ready') {
                $terminalInfo = Get-ScheduledTaskInfo -TaskName $name
                $taskResult = [long]$terminalInfo.LastTaskResult
            }
            $resultStatus = $null
            if (Test-Path -LiteralPath $resultPath) {
                try {
                    $document = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                    $resultStatus = [string]$document.status
                } catch {}
            }
            [pscustomobject]@{
                result_status = $resultStatus
                task_state = $taskState
                task_result = $taskResult
                last_run_time_ticks = [long]$info.LastRunTime.Ticks
            }
        }
        $rescue = Resolve-ObserverTaskPollState -Label Rescue `
            -ResultStatus $observed.result_status `
            -TaskState $observed.task_state `
            -TaskResult $observed.task_result `
            -RegisteredLastRunTimeTicks $rescueGeneration.registered_last_run_time_ticks `
            -LastRunTimeTicks $observed.last_run_time_ticks
        if ($rescue.terminal) { break }
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $rescue -or -not $rescue.terminal) {
        throw 'Text-scale rescue timed out before the scheduled task reached its terminal state.'
    }

    $rescueFiles = @(Invoke-Command -Session $Session -ArgumentList $GuestRoot,$TaskName -ScriptBlock {
        param($root,$name)
        $trustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
        $out = Join-Path $trustedRoot 'out'
        foreach ($leaf in @(
            'text-scale-snapshot.json',
            'text-scale-activation.json',
            'text-scale-rescue-error.txt',
            'text-scale-rescue-result.json'
        )) {
            $path = Join-Path $out $leaf
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $item = Get-Item -LiteralPath $path -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 4MB) {
                    throw 'Text-scale rescue evidence is not an ordinary bounded file.'
                }
                [pscustomobject]@{file=$leaf;guest_path=$path;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
            }
        }
    })
    foreach ($file in $rescueFiles) {
        Assert-PlainFile $file.file
        $guestPath = [string]$file.guest_path
        $hostPath = Join-Path $HostOutputRoot $file.file
        Copy-Item -LiteralPath $guestPath -Destination $hostPath -FromSession $Session
        if ((Get-Item -LiteralPath $hostPath).Length -ne $file.bytes -or
            (Get-FileHash -LiteralPath $hostPath -Algorithm SHA256).Hash -ine $file.sha256) {
            throw 'Collected text-scale rescue evidence hash mismatch.'
        }
    }
    if ($rescue.result_status -cne 'passed' -or $rescue.task_result -ne 0) {
        throw 'Text-scale rescue did not verify exact restoration; inspect rescue evidence.'
    }
    if ($v2) {
        $document = Get-Content -LiteralPath (Join-Path $HostOutputRoot 'text-scale-rescue-result.json') `
            -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $execution = Complete-DrControllerV2TaskExecution -Session $Session -TaskName $TaskName `
            -RunnerSid $DesktopSid -SessionId $DesktopSessionId -Engine $rescueGeneration `
            -CompletedTicks $rescue.last_run_time_ticks -TaskResult $rescue.task_result -Result $document
        $script:DrVmV2RescueExecutions.Add([pscustomobject]@{
            kind='text-scale'; task_execution=$execution
            result_file='text-scale-rescue-result.json'
            result_sha256=(Get-FileHash -LiteralPath (Join-Path $HostOutputRoot 'text-scale-rescue-result.json') `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
}
function Invoke-AcceptanceHighContrastRescue {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)][string] $GuestRoot,
        [Parameter(Mandatory = $true)][string] $DesktopSid,
        [Parameter(Mandatory = $true)][int] $DesktopSessionId,
        [Parameter(Mandatory = $true)][string] $TaskName,
        [Parameter(Mandatory = $true)][int] $TestTimeoutSeconds,
        [Parameter(Mandatory = $true)][int] $SuiteTimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $ObserverSha256,
        [Parameter(Mandatory = $true)][object[]] $BundleRecords,
        [ValidatePattern('^[0-9a-f]{64}$')][string] $InputManifestSha256,
        [ValidateSet('current-dpi', 'appearance-pair')][string] $AcceptanceMode = 'current-dpi',
        [ValidateSet('system', 'light', 'dark')][string] $Appearance = 'system',
        [Parameter(Mandatory = $true)][string] $HostOutputRoot,
        [string] $AcceptanceProfileId = 'vm-automated-v1-win11-ntfs',
        [AllowNull()][object] $EngineEvidence
    )

    $v2 = $AcceptanceProfileId -ceq 'vm-automated-v2-owned-resources'
    if ($v2) { $script:DrVmV2RescueAttempts++ }
    $rescueTimeout = [Math]::Max(120, [Math]::Min(600, $SuiteTimeoutSeconds))
    $rescueGeneration = Invoke-Command -Session $Session -ArgumentList $GuestRoot,$DesktopSid,$DesktopSessionId,$TaskName,$TestTimeoutSeconds,$rescueTimeout,$ObserverSha256,$AcceptanceMode,$Appearance,$InputManifestSha256,$BundleRecords,$v2,$EngineEvidence -ScriptBlock {
        param($root,$sid,$desktopSession,$name,$testTimeout,$rescueSeconds,$observerHash,$mode,$appearance,$inputManifestHash,$bundleRecords,$v2,$preflightEngine)
        $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
        }
        $trustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
        $observerPath = Join-Path $trustedRoot 'windows-vm-acceptance.ps1'
        if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) {
            throw 'Transferred acceptance observer changed before High Contrast rescue.'
        }
        $bundle = Join-Path $trustedRoot 'bundle'
        $out = Join-Path $trustedRoot 'out'
        $runtime = [IO.Path]::GetFullPath((Join-Path $root 'runtime'))
        $snapshot = Get-Item -LiteralPath (Join-Path $out 'high-contrast-restore.json') -Force -ErrorAction Stop
        if ($snapshot.PSIsContainer -or ($snapshot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'High Contrast rescue snapshot is not an ordinary file.'
        }
        $powerShell = Get-DrVmTrustedPowerShellPath
        if ($v2) { $engine = $preflightEngine }
        else {
            $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
                '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell rescue engine.' }
            $engine = $engineJson | ConvertFrom-Json
        }
        if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
            $engine.effective_policy -cne 'RemoteSigned') {
            throw 'High Contrast rescue requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
        }
        $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -RuntimeRoot "' + $runtime + '" -ExpectedScriptSha256 ' + $observerHash + ' -TimeoutSeconds ' + $testTimeout + ' -Appearance system -HighContrast -RestoreHighContrastOnly'
        if ($mode -ceq 'appearance-pair') {
            if ($appearance -cne 'system' -or $inputManifestHash -cnotmatch '^[0-9a-f]{64}$') {
                throw 'Appearance pair High Contrast rescue request is unbound.'
            }
            $inputManifest = Join-Path $trustedRoot 'input-manifest.json'
            if ((Get-FileHash -LiteralPath $inputManifest -Algorithm SHA256).Hash -ine $inputManifestHash) {
                throw 'Appearance pair High Contrast rescue manifest changed.'
            }
            $observerArguments += ' -RegressionMode appearance-pair -InputManifestPath "' + $inputManifest + '" -TextScalePercent 100'
        }
        $manifestBinding = if ($mode -ceq 'appearance-pair') {
            @{ InputManifestPath = $inputManifest; InputManifestSha256 = $inputManifestHash }
        } else { @{} }
        if ($v2) { $observerArguments += ' -AcceptanceProfileId vm-automated-v2-owned-resources' }
        $registeredTask = Register-DrVmTask `
            -TaskName $name `
            -UserSid $sid `
            -SessionId $desktopSession `
            -GuestRoot $root `
            -RuntimeRoot $runtime `
            -ObserverPath $observerPath `
            -ObserverSha256 $observerHash `
            -BundleSourcePath $bundle `
            -BundleRecords $bundleRecords `
            @manifestBinding `
            -Execute $powerShell `
            -Arguments $observerArguments `
            -WorkingDirectory $root `
            -TrustedResultLeaf 'high-contrast-rescue-result.json' `
            -ExecutionTimeLimitSeconds ($rescueSeconds + 30)
        $actualAction = if ($v2) { $registeredTask.Definition.Actions.Item(1) } else { $null }
        $registered = Get-ScheduledTaskInfo -TaskName $name
        $registeredTicks = [long]$registered.LastRunTime.Ticks
        Start-ScheduledTask -TaskName $name | Out-Null
        [pscustomobject][ordered]@{
            registered_last_run_time_ticks = $registeredTicks
            action_executable = if ($v2) { [string]$actualAction.Path } else { $null }
            action_arguments = if ($v2) { [string]$actualAction.Arguments } else { $null }
        }
    }

    $deadline = (Get-Date).AddSeconds($rescueTimeout)
    $rescue = $null
    do {
        Start-Sleep -Seconds 2
        $observed = Invoke-Command -Session $Session -ArgumentList $GuestRoot,$TaskName -ScriptBlock {
            param($root,$name)
            $resultPath = Join-Path (Join-Path (Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')) 'out') 'high-contrast-rescue-result.json'
            $info = Get-ScheduledTaskInfo -TaskName $name
            $task = Get-ScheduledTask -TaskName $name
            $taskState = $task.State.ToString()
            $taskResult = [long]$info.LastTaskResult
            if ($taskState -ceq 'Ready') {
                $terminalInfo = Get-ScheduledTaskInfo -TaskName $name
                $taskResult = [long]$terminalInfo.LastTaskResult
            }
            $resultStatus = $null
            if (Test-Path -LiteralPath $resultPath) {
                try {
                    $document = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                    $resultStatus = [string]$document.status
                } catch {}
            }
            [pscustomobject]@{
                result_status = $resultStatus
                task_state = $taskState
                task_result = $taskResult
                last_run_time_ticks = [long]$info.LastRunTime.Ticks
            }
        }
        $rescue = Resolve-ObserverTaskPollState -Label Rescue `
            -ResultStatus $observed.result_status `
            -TaskState $observed.task_state `
            -TaskResult $observed.task_result `
            -RegisteredLastRunTimeTicks $rescueGeneration.registered_last_run_time_ticks `
            -LastRunTimeTicks $observed.last_run_time_ticks
        if ($rescue.terminal) { break }
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $rescue -or -not $rescue.terminal) {
        throw 'High Contrast rescue timed out before the scheduled task reached its terminal state.'
    }

    $rescueFiles = @(Invoke-Command -Session $Session -ArgumentList $GuestRoot,$TaskName -ScriptBlock {
        param($root,$name)
        $trustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
        $out = Join-Path $trustedRoot 'out'
        foreach ($leaf in @(
            'high-contrast-restore.json',
            'high-contrast-rescue-error.txt',
            'high-contrast-rescue-result.json'
        )) {
            $path = Join-Path $out $leaf
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $item = Get-Item -LiteralPath $path -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $item.Length -gt 4MB) {
                    throw 'High Contrast rescue evidence is not an ordinary bounded file.'
                }
                [pscustomobject]@{
                    file = $leaf
                    guest_path = $path
                    bytes = $item.Length
                    sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        }
    })
    foreach ($file in $rescueFiles) {
        Assert-PlainFile $file.file
        $guestPath = [string]$file.guest_path
        $hostPath = Join-Path $HostOutputRoot $file.file
        Copy-Item -LiteralPath $guestPath -Destination $hostPath -FromSession $Session
        if ((Get-Item -LiteralPath $hostPath).Length -ne $file.bytes -or
            (Get-FileHash -LiteralPath $hostPath -Algorithm SHA256).Hash -ine $file.sha256) {
            throw 'Collected High Contrast rescue evidence hash mismatch.'
        }
    }
    if ($rescue.result_status -cne 'passed' -or $rescue.task_result -ne 0) {
        throw 'High Contrast rescue did not verify exact restoration; inspect rescue evidence.'
    }
    if ($v2) {
        $document = Get-Content -LiteralPath (Join-Path $HostOutputRoot 'high-contrast-rescue-result.json') `
            -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $execution = Complete-DrControllerV2TaskExecution -Session $Session -TaskName $TaskName `
            -RunnerSid $DesktopSid -SessionId $DesktopSessionId -Engine $rescueGeneration `
            -CompletedTicks $rescue.last_run_time_ticks -TaskResult $rescue.task_result -Result $document
        $script:DrVmV2RescueExecutions.Add([pscustomobject]@{
            kind='high-contrast'; task_execution=$execution
            result_file='high-contrast-rescue-result.json'
            result_sha256=(Get-FileHash -LiteralPath (Join-Path $HostOutputRoot 'high-contrast-rescue-result.json') `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
}
