[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $BundleRoot,
    [Parameter(Mandatory = $true)][string] $VmName,
    [Parameter(Mandatory = $true)][string] $CredentialHelper,
    [ValidateRange(10, 1800)][int] $TestTimeoutSeconds = 300,
    [ValidateRange(60, 14400)][int] $SuiteTimeoutSeconds = 2400
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:PSModulePath = "$PSHOME\Modules;C:\Program Files\WindowsPowerShell\Modules"
$BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
$transport = [ordered]@{status = 'starting'; guest_cleanup = $false}
$credential = $null
$session = $null
$guestRoot = $null
$taskName = 'DarkReNamerTests-' + [guid]::NewGuid().ToString('N')
$result = $null
$mutex = $null
$mutexHeld = $false

function Assert-PlainFile([string] $Name) {
    if ($Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$') { throw 'Invalid bundle file name.' }
}
function Assert-PathWithoutReparse([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse paths are not supported for VM test bundles.' }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}
try {
    Assert-PathWithoutReparse $BundleRoot
    $manifest = Get-Content -LiteralPath (Join-Path $BundleRoot 'bundle.json') -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.source_sha -cnotmatch '^[0-9a-f]{40}$' -or $manifest.source_state -ne 'clean') { throw 'A clean source-bound bundle is required.' }
    $artifacts = @($manifest.test_binaries) + @($manifest.application, $manifest.runner)
    $names = @{}
    foreach ($artifact in $artifacts) {
        Assert-PlainFile $artifact.file
        if ($names.ContainsKey($artifact.file)) { throw 'Duplicate artifact name.' }
        $names[$artifact.file] = $true
        $path = Join-Path $BundleRoot $artifact.file
        Assert-PathWithoutReparse $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $artifact.sha256) { throw 'Bundle artifact hash mismatch.' }
    }
    $vm = Get-VM -Name $VmName
    $mutex = New-Object Threading.Mutex($false, ('Local\DarkReNamerVmTests-' + $vm.Id))
    try { $mutexHeld = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
    if (-not $mutexHeld) { throw 'Another native test controller is using this VM.' }
    $credential = & $CredentialHelper -Action Load
    if ($credential -isnot [Management.Automation.PSCredential]) { throw 'Credential helper did not return a PSCredential.' }
    if ((Get-VM -Name $VmName).State.ToString() -ne 'Running') { throw 'Start the configured VM before testing.' }
    $session = New-PSSession -VMName $VmName -Credential $credential
    $desktop = Invoke-Command -Session $session -ScriptBlock {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $localUser = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object SID -eq $sid)
        if ($localUser.Count -ne 1) { throw 'The VM test account must be local.' }
        $sessions = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid -eq $sid } | Select-Object -ExpandProperty SessionId -Unique)
        $unlocked = @($sessions | Where-Object { $candidate = $_; -not (Get-Process LogonUI -ErrorAction SilentlyContinue | Where-Object SessionId -eq $candidate) })
        if ($unlocked.Count -ne 1 -or $unlocked[0] -le 0) { throw 'Log in to one unlocked desktop with the configured VM test account.' }
        if (-not (Test-Path "$env:SystemRoot\System32\VCRUNTIME140.dll")) { throw 'Install the Microsoft x64 Visual C++ runtime in the VM before testing.' }
        [pscustomobject]@{sid = $sid; session_id = $unlocked[0]}
    }
    $guestRoot = Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {
        param($name)
        $path = Join-Path $env:TEMP $name
        New-Item -ItemType Directory -Path $path | Out-Null
        $path
    }
    $transport.status = 'copying'
    foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
        Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination (Join-Path $guestRoot $name) -ToSession $session
    }
    Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$manifest.runner.sha256 -ScriptBlock {
        param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$runnerHash)
        $runner = Join-Path $root 'windows-vm-guest.ps1'
        if ((Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash -ine $runnerHash) { throw 'Transferred guest runner hash mismatch.' }
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Normal -File "' + $runner + '" -BundleRoot "' + $root + '" -ExpectedSessionId ' + $desktopSession + ' -TestTimeoutSeconds ' + $testTimeout
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments -WorkingDirectory $root
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($suiteTimeout + 60))
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName $name
    }
    $transport.status = 'running'
    $deadline = (Get-Date).AddSeconds($SuiteTimeoutSeconds)
    $lastProgress = ''
    do {
        Start-Sleep -Seconds 5
        $state = Invoke-Command -Session $session -ArgumentList $guestRoot,$taskName -ScriptBlock {
            param($root,$name)
            $file = Join-Path $root 'result.json'
            if (Test-Path -LiteralPath $file) {
                try {
                    $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                    [pscustomobject]@{status=$data.status;count=@($data.tests).Count;task_result=0}
                    return
                } catch {}
            }
            $task = Get-ScheduledTask -TaskName $name
            $info = Get-ScheduledTaskInfo -TaskName $name
            [pscustomobject]@{status=$task.State.ToString();count=0;task_result=$info.LastTaskResult}
        }
        $progress = [string]$state.status + ':' + $state.count
        if ($progress -ne $lastProgress) { Write-Host ('VM tests: ' + $progress); $lastProgress = $progress }
        if ($state.status -in @('passed','failed')) { break }
        if ($state.status -eq 'Ready' -and $state.task_result -ne 0) { throw ('Guest test task failed before producing results: ' + $state.task_result) }
    } while ((Get-Date) -lt $deadline)
    if ($state.status -notin @('passed','failed')) { throw 'VM test suite timed out.' }
    Copy-Item -LiteralPath (Join-Path $guestRoot 'result.json') -Destination (Join-Path $BundleRoot 'result.json') -FromSession $session
    $result = Get-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Raw | ConvertFrom-Json
    $outputs = @()
    foreach ($row in $result.tests) {
        foreach ($channel in @('stdout','stderr')) { if ($row.$channel) { $outputs += $row.$channel } }
    }
    if ($result.gui -and $result.gui.PSObject.Properties.Name -contains 'screenshot' -and $result.gui.screenshot) { $outputs += $result.gui.screenshot }
    foreach ($output in $outputs) {
        Assert-PlainFile $output.file
        if ($names.ContainsKey($output.file) -or $output.file -in @('bundle.json','result.json','transport.json','run-windows-vm-tests.ps1')) { throw 'Guest output collides with a bundle input.' }
        Copy-Item -LiteralPath (Join-Path $guestRoot $output.file) -Destination (Join-Path $BundleRoot $output.file) -FromSession $session
        if ((Get-FileHash -LiteralPath (Join-Path $BundleRoot $output.file) -Algorithm SHA256).Hash -ine $output.sha256) { throw 'Collected guest output hash mismatch.' }
    }
    $transport.status = 'collected'
} catch {
    $transport.status = 'failed'
    $transport.error = 'VM transport failed; inspect transport-error.txt.'
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $BundleRoot 'transport-error.txt') -Encoding UTF8
} finally {
    if ($session) {
        try {
            Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {
                param($name)
                $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                if ($task) { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $name -Confirm:$false }
            }
            if ($guestRoot) {
                $cleanupResult = Invoke-Command -Session $session -ArgumentList $guestRoot,$taskName,($transport.status -eq 'collected') -ScriptBlock {
                    param($root,$name,$hasResult)
                    if ($name -cnotmatch '^DarkReNamerTests-[0-9a-f]{32}$' -or $root -cne (Join-Path $env:TEMP $name)) { throw 'Unexpected guest cleanup root.' }
                    $prefix = $root + '\'
                    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) } | ForEach-Object {
                        $owned = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
                        if ($owned -and $owned.MainModule.FileName.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                            $owned.Kill()
                            if (-not $owned.WaitForExit(10000)) { throw 'An owned test process did not exit.' }
                            $owned.Dispose()
                        }
                    }
                    if (-not $hasResult) { return $false }
                    $pending = New-Object 'Collections.Generic.Stack[string]'
                    $pending.Push($root)
                    while ($pending.Count -gt 0) {
                        $directory = $pending.Pop()
                        if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse fixture remains; guest directory retained.' }
                        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
                            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse fixture remains; guest directory retained.' }
                            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
                        }
                    }
                    Remove-Item -LiteralPath $root -Recurse -Force
                    -not (Test-Path -LiteralPath $root)
                }
                if ($cleanupResult -isnot [bool]) { throw 'Guest cleanup did not return a boolean.' }
                $transport.guest_cleanup = [bool]$cleanupResult
            }
        } catch {
            $transport.status='failed'; $transport.cleanup_error='Guest cleanup failed; inspect cleanup-error.txt.'; $transport.guest_cleanup=$false
            $_ | Out-String | Set-Content -LiteralPath (Join-Path $BundleRoot 'cleanup-error.txt') -Encoding UTF8
        }
        if ($guestRoot -and -not $transport.guest_cleanup) { [IO.File]::WriteAllText((Join-Path $BundleRoot 'retained-guest-directory.txt'), $guestRoot) }
        Remove-PSSession $session
    }
    if ($credential) { $credential.Password.Dispose() }
    if ($mutexHeld) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() }
    $transport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $BundleRoot 'transport.json') -Encoding UTF8
    if ($result) {
        $result | Add-Member -NotePropertyName transport -NotePropertyValue $transport -Force
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Encoding UTF8
    }
}
if ($transport.status -ne 'collected' -or -not $transport.guest_cleanup) { throw 'VM transport or cleanup failed; inspect transport.json.' }
