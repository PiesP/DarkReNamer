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
        [Parameter(Mandatory = $true)][string] $Appearance,
        [Parameter(Mandatory = $true)][string] $HostOutputRoot
    )

    $rescueTimeout = [Math]::Max(120, [Math]::Min(600, $SuiteTimeoutSeconds))
    $rescueGeneration = Invoke-Command -Session $Session -ArgumentList $GuestRoot,$DesktopSid,$DesktopSessionId,$TaskName,$TestTimeoutSeconds,$rescueTimeout,$ObserverSha256,$Appearance -ScriptBlock {
        param($root,$sid,$desktopSession,$name,$testTimeout,$rescueSeconds,$observerHash,$appearance)
        $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
        }
        $observerPath = Join-Path $root 'windows-vm-acceptance.ps1'
        if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) {
            throw 'Transferred acceptance observer changed before text-scale rescue.'
        }
        $bundle = Join-Path $root 'bundle'
        $out = Join-Path $root 'out'
        $snapshot = Get-Item -LiteralPath (Join-Path $out 'text-scale-snapshot.json') -Force -ErrorAction Stop
        if ($snapshot.PSIsContainer -or ($snapshot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Text-scale rescue snapshot is not an ordinary file.'
        }
        $inputManifest = Join-Path $root 'input-manifest.json'
        $stdout = Join-Path $root 'text-scale-rescue.stdout.txt'
        $stderr = Join-Path $root 'text-scale-rescue.stderr.txt'
        $powerShell = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
        $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
            '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell rescue engine.' }
        $engine = $engineJson | ConvertFrom-Json
        if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
            $engine.effective_policy -cne 'RemoteSigned') {
            throw 'Text-scale rescue requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
        }
        $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -ExpectedScriptSha256 ' + $observerHash + ' -TimeoutSeconds ' + $testTimeout + ' -Appearance ' + $appearance + ' -RegressionMode text-scale -InputManifestPath "' + $inputManifest + '" -TextScalePercent 150 -RestoreTextScaleOnly'
        $arguments = '/d /s /c ""' + $powerShell + '" ' + $observerArguments + ' 1>"' + $stdout + '" 2>"' + $stderr + '""'
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument $arguments -WorkingDirectory $root
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($rescueSeconds + 30))
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
        $registered = Get-ScheduledTaskInfo -TaskName $name
        $registeredTicks = [long]$registered.LastRunTime.Ticks
        Start-ScheduledTask -TaskName $name | Out-Null
        [pscustomobject][ordered]@{
            registered_last_run_time_ticks = $registeredTicks
        }
    }

    $deadline = (Get-Date).AddSeconds($rescueTimeout)
    $rescue = $null
    do {
        Start-Sleep -Seconds 2
        $observed = Invoke-Command -Session $Session -ArgumentList $GuestRoot,$TaskName -ScriptBlock {
            param($root,$name)
            $resultPath = Join-Path (Join-Path $root 'out') 'text-scale-rescue-result.json'
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
        $rescue = Resolve-AcceptanceRescuePollState `
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

    $rescueFiles = @(Invoke-Command -Session $Session -ArgumentList $GuestRoot -ScriptBlock {
        param($root)
        $out = Join-Path $root 'out'
        foreach ($stream in @('text-scale-rescue.stdout.txt', 'text-scale-rescue.stderr.txt')) {
            $source = Join-Path $root $stream
            if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination (Join-Path $out $stream) -Force }
        }
        foreach ($leaf in @(
            'text-scale-snapshot.json',
            'text-scale-activation.json',
            'text-scale-rescue-result.json',
            'text-scale-rescue-error.txt',
            'text-scale-rescue.stdout.txt',
            'text-scale-rescue.stderr.txt'
        )) {
            $path = Join-Path $out $leaf
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $item = Get-Item -LiteralPath $path -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 4MB) {
                    throw 'Text-scale rescue evidence is not an ordinary bounded file.'
                }
                [pscustomobject]@{file=$leaf;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
            }
        }
    })
    foreach ($file in $rescueFiles) {
        Assert-PlainFile $file.file
        $guestPath = Join-GuestWindowsPath -Root (Join-GuestWindowsPath -Root $GuestRoot -Leaf 'out') -Leaf $file.file
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
        [Parameter(Mandatory = $true)][string] $HostOutputRoot
    )

    $rescueTimeout = [Math]::Max(120, [Math]::Min(600, $SuiteTimeoutSeconds))
    $rescueGeneration = Invoke-Command -Session $Session -ArgumentList $GuestRoot,$DesktopSid,$DesktopSessionId,$TaskName,$TestTimeoutSeconds,$rescueTimeout,$ObserverSha256 -ScriptBlock {
        param($root,$sid,$desktopSession,$name,$testTimeout,$rescueSeconds,$observerHash)
        $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
        }
        $observerPath = Join-Path $root 'windows-vm-acceptance.ps1'
        if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) {
            throw 'Transferred acceptance observer changed before High Contrast rescue.'
        }
        $bundle = Join-Path $root 'bundle'
        $out = Join-Path $root 'out'
        $snapshot = Get-Item -LiteralPath (Join-Path $out 'high-contrast-restore.json') -Force -ErrorAction Stop
        if ($snapshot.PSIsContainer -or ($snapshot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'High Contrast rescue snapshot is not an ordinary file.'
        }
        $stdout = Join-Path $root 'high-contrast-rescue.stdout.txt'
        $stderr = Join-Path $root 'high-contrast-rescue.stderr.txt'
        $powerShell = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
        $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
            '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell rescue engine.' }
        $engine = $engineJson | ConvertFrom-Json
        if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
            $engine.effective_policy -cne 'RemoteSigned') {
            throw 'High Contrast rescue requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
        }
        $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -ExpectedScriptSha256 ' + $observerHash + ' -TimeoutSeconds ' + $testTimeout + ' -Appearance system -HighContrast -RestoreHighContrastOnly'
        $arguments = '/d /s /c ""' + $powerShell + '" ' + $observerArguments + ' 1>"' + $stdout + '" 2>"' + $stderr + '""'
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument $arguments -WorkingDirectory $root
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($rescueSeconds + 30))
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
        $registered = Get-ScheduledTaskInfo -TaskName $name
        $registeredTicks = [long]$registered.LastRunTime.Ticks
        Start-ScheduledTask -TaskName $name | Out-Null
        [pscustomobject][ordered]@{
            registered_last_run_time_ticks = $registeredTicks
        }
    }

    $deadline = (Get-Date).AddSeconds($rescueTimeout)
    $rescue = $null
    do {
        Start-Sleep -Seconds 2
        $observed = Invoke-Command -Session $Session -ArgumentList $GuestRoot,$TaskName -ScriptBlock {
            param($root,$name)
            $resultPath = Join-Path (Join-Path $root 'out') 'high-contrast-rescue-result.json'
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
        $rescue = Resolve-AcceptanceRescuePollState `
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

    $rescueFiles = @(Invoke-Command -Session $Session -ArgumentList $GuestRoot -ScriptBlock {
        param($root)
        $out = Join-Path $root 'out'
        foreach ($stream in @('high-contrast-rescue.stdout.txt', 'high-contrast-rescue.stderr.txt')) {
            $source = Join-Path $root $stream
            if (Test-Path -LiteralPath $source) {
                Move-Item -LiteralPath $source -Destination (Join-Path $out $stream) -Force
            }
        }
        foreach ($leaf in @(
            'high-contrast-restore.json',
            'high-contrast-rescue-result.json',
            'high-contrast-rescue-error.txt',
            'high-contrast-rescue.stdout.txt',
            'high-contrast-rescue.stderr.txt'
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
                    bytes = $item.Length
                    sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        }
    })
    foreach ($file in $rescueFiles) {
        Assert-PlainFile $file.file
        $guestPath = Join-GuestWindowsPath -Root (Join-GuestWindowsPath -Root $GuestRoot -Leaf 'out') -Leaf $file.file
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
}
