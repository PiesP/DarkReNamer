param([Parameter(Mandatory)][hashtable] $Libraries)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedRoles = @(
    'powershell-controller-contracts'
    'powershell-controller-transport'
    'powershell-controller-poll'
    'powershell-controller-rescue'
)
if ($Libraries.Count -ne $expectedRoles.Count) { throw 'The verified definition library set is incomplete.' }
foreach ($role in $expectedRoles) {
    if (-not $Libraries.ContainsKey($role) -or $Libraries[$role] -isnot [scriptblock]) {
        throw "Missing verified definition library: $role"
    }
    . $Libraries[$role]
}

function Invoke-DrWindowsVmController {
    [CmdletBinding(DefaultParameterSetName = 'Direct')]
    param(
    [Parameter(Mandatory = $true)][string] $BundleRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string] $VmName,
    [Parameter(ParameterSetName = 'Direct')]
    [ValidateScript({ $_ -ne [guid]::Empty })][guid] $ExpectedVmId,
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')][string] $CredentialHelper,
    [Parameter(Mandatory = $true, ParameterSetName = 'Ssh')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z')]
    [string] $SshHost,
    [ValidatePattern('^S-1-5-21-(\d+-){2}\d+-\d+$')][string] $ExpectedDesktopSid,
    [ValidateRange(10, 1800)][int] $TestTimeoutSeconds = 300,
    [ValidateRange(60, 14400)][int] $SuiteTimeoutSeconds = 2400,
    [ValidateSet('core', 'ui', 'recovery')][string] $TaskKind,
    [string] $AcceptanceOutputRoot,
    [string] $AcceptanceManifest,
    [ValidateSet('current-dpi', 'full-context', 'standard', 'text-scale', 'tooltip')]
    [string] $AcceptanceMode,
    [ValidateSet('system', 'light', 'dark')][string] $AcceptanceAppearance,
    [ValidateSet(100, 150)][int] $AcceptanceTextScalePercent = 100,
    [switch] $AcceptanceHighContrast,
    [switch] $AcceptanceClipboard,
    [switch] $AcceptanceCaptureNativeMenu,
    [switch] $AcceptanceCaptureAdvancedAppearance,
    [string] $RecoveryOutputRoot,
    [ValidateSet('ProcessCrash', 'WorkerCancellation', 'WorkerClose')]
    [string] $RecoveryMode,
    [ValidateRange(128, 10000)][int] $RecoveryFixtureCount = 4096,
    [ValidatePattern('^[0-9a-f]{64}\z')][string] $RecoveryObserverSha256,
    [switch] $RecoveryExport,
    [switch] $RecoveryIntentOnlyCandidateDiscard,
    [guid] $ExpectedGuestVmId = [guid]::Empty,
    [ValidatePattern('^[0-9a-f]{64}\z')][string] $ExpectedBundleManifestSha256
,
    [Parameter(Mandatory)][string] $EntryPointPath,
    [Parameter(Mandatory)][object] $VerifiedTooling
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'


$taskSelection = Resolve-ControllerTaskSelection `
    -RequestedKind $TaskKind `
    -HasUiOutput $PSBoundParameters.ContainsKey('AcceptanceOutputRoot') `
    -HasUiManifest $PSBoundParameters.ContainsKey('AcceptanceManifest') `
    -HasUiMode $PSBoundParameters.ContainsKey('AcceptanceMode') `
    -HasUiAppearance $PSBoundParameters.ContainsKey('AcceptanceAppearance') `
    -UiMode $AcceptanceMode `
    -UiAppearance $AcceptanceAppearance `
    -UiTextScalePercent $AcceptanceTextScalePercent `
    -HasUiTextScalePercent $PSBoundParameters.ContainsKey('AcceptanceTextScalePercent') `
    -UiHighContrast ([bool]$AcceptanceHighContrast) `
    -UiClipboard ([bool]$AcceptanceClipboard) `
    -UiCaptureNativeMenu ([bool]$AcceptanceCaptureNativeMenu) `
    -UiCaptureAdvancedAppearance ([bool]$AcceptanceCaptureAdvancedAppearance) `
    -HasRecoveryOutput $PSBoundParameters.ContainsKey('RecoveryOutputRoot') `
    -HasRecoveryMode $PSBoundParameters.ContainsKey('RecoveryMode') `
    -HasRecoveryObserverSha256 $PSBoundParameters.ContainsKey('RecoveryObserverSha256') `
    -RecoveryMode $RecoveryMode `
    -RecoveryExport ([bool]$RecoveryExport) `
    -RecoveryIntentOnlyCandidateDiscard ([bool]$RecoveryIntentOnlyCandidateDiscard) `
    -HasRecoveryFixtureCount $PSBoundParameters.ContainsKey('RecoveryFixtureCount') `
    -TimeoutSeconds $TestTimeoutSeconds

$transportKind = if ($PSCmdlet.ParameterSetName -eq 'Ssh') { 'ssh' } else { 'powershell_direct' }
$acceptance = $taskSelection.kind -ceq 'ui'
$recovery = $taskSelection.kind -ceq 'recovery'
$observerTask = [bool]$taskSelection.is_observer
if ($observerTask -and $ExpectedGuestVmId -eq [guid]::Empty) {
    throw 'Observer tasks require the expected Hyper-V guest VM identity.'
}
$hostPlatform = if ($PSVersionTable.ContainsKey('Platform')) {
    [string]$PSVersionTable.Platform
}
else {
    [Environment]::OSVersion.Platform.ToString()
}
if ($transportKind -eq 'powershell_direct') {
    $env:PSModulePath = "$PSHOME\Modules;C:\Program Files\WindowsPowerShell\Modules"
}
$BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
if ($acceptance) {
    $AcceptanceOutputRoot = [IO.Path]::GetFullPath($AcceptanceOutputRoot)
    $AcceptanceManifest = [IO.Path]::GetFullPath($AcceptanceManifest)
}
if ($recovery) {
    $RecoveryOutputRoot = [IO.Path]::GetFullPath($RecoveryOutputRoot)
}
$transport = [ordered]@{
    kind = $transportKind
    task_kind = $taskSelection.kind
    host_platform = $hostPlatform
    status = 'starting'
    guest_cleanup = $false
}
$credential = $null
$session = $null
$guestRoot = $null
$taskName = 'DarkReNamerTests-' + [guid]::NewGuid().ToString('N')
$result = $null
$acceptancePassed = $false
$observerProcess = $null
$transportOutputRoot = if ($acceptance) {
    $AcceptanceOutputRoot
} elseif ($recovery) {
    $RecoveryOutputRoot
} else {
    $BundleRoot
}
$mutex = $null
$mutexHeld = $false
$toolingTransfer = $null


try {
    Assert-PathWithoutReparse $BundleRoot
    $bundleManifestPath = Join-Path $BundleRoot 'bundle.json'
    if (-not [string]::IsNullOrEmpty($ExpectedBundleManifestSha256) -and
        (Get-FileHash -LiteralPath $bundleManifestPath -Algorithm SHA256).Hash -ine
            $ExpectedBundleManifestSha256) {
        throw 'Bundle manifest differs from the launcher-frozen input.'
    }
    $manifest = Get-Content -LiteralPath $bundleManifestPath -Raw | ConvertFrom-Json
    $candidateLane = $manifest.schema_version -eq 2 -and $manifest.lane -ceq 'candidate-gui-only'
    if ($candidateLane) {
        if ($manifest.product.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
            $manifest.product.source_state -cne 'clean' -or
            $manifest.harness.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
            $manifest.harness.source_state -cne 'clean' -or
            $manifest.product.candidate.origin_authentication -cne 'pending-hosted' -or
            @($manifest.test_binaries).Count -ne 0) {
            throw 'An exact-candidate GUI-only bundle is invalid.'
        }
        if ($ExpectedGuestVmId -eq [guid]::Empty) {
            throw 'Exact-candidate execution requires an expected guest VM identity.'
        }
        if ([string]::IsNullOrEmpty($ExpectedBundleManifestSha256)) {
            throw 'Exact-candidate execution requires a launcher-frozen bundle manifest digest.'
        }
        $artifacts = @(
            $manifest.product.application
            $manifest.product.provenance.release_handoff
            $manifest.product.provenance.run_metadata
            $manifest.product.provenance.artifact_metadata
            $manifest.harness.launcher
            $manifest.harness.controller
            $manifest.harness.runner
            @($manifest.harness.observers.PSObject.Properties | ForEach-Object Value)
            @($manifest.harness.validators.PSObject.Properties | ForEach-Object Value)
        )
        if ($manifest.harness.controller.file -cne 'run-windows-vm-tests.ps1' -or
            (Get-FileHash -LiteralPath $EntryPointPath -Algorithm SHA256).Hash -ine
                $manifest.harness.controller.sha256) {
            throw 'The invoked controller differs from the frozen candidate harness.'
        }
    }
    else {
        if ($manifest.schema_version -ne 1 -or $manifest.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
            $manifest.source_state -ne 'clean' -or @($manifest.test_binaries).Count -eq 0) {
            throw 'A clean source-bound bundle with native tests is required.'
        }
        $artifacts = @($manifest.test_binaries) + @($manifest.application, $manifest.runner)
    }
    $names = @{}
    foreach ($artifact in $artifacts) {
        Assert-PlainFile $artifact.file
        if ($names.ContainsKey($artifact.file)) { throw 'Duplicate artifact name.' }
        $names[$artifact.file] = $true
        $path = Join-Path $BundleRoot $artifact.file
        Assert-PathWithoutReparse $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $artifact.sha256) { throw 'Bundle artifact hash mismatch.' }
    }
    if ($acceptance) {
        Assert-PathWithoutReparse $AcceptanceManifest
        Assert-PathWithoutReparse $AcceptanceOutputRoot
        $outputItem = Get-Item -LiteralPath $AcceptanceOutputRoot -Force
        if (-not $outputItem.PSIsContainer -or @(Get-ChildItem -LiteralPath $outputItem.FullName -Force).Count -ne 0) {
            throw 'Acceptance output must be an existing empty ordinary directory.'
        }
        $acceptanceInput = Get-Content -LiteralPath $AcceptanceManifest -Raw | ConvertFrom-Json
        Assert-SafeAcceptanceRunId -RunId $acceptanceInput.run_id
        $expectedAcceptanceSourceSha = if ($candidateLane) {
            $manifest.product.source_sha
        } else {
            $manifest.source_sha
        }
        if ($acceptanceInput.schema_version -ne 1 -or
            $acceptanceInput.source_sha -cne $expectedAcceptanceSourceSha -or
            $acceptanceInput.request.mode -cne $AcceptanceMode -or
            $acceptanceInput.request.appearance -cne $AcceptanceAppearance -or
            $acceptanceInput.request.text_scale_percent -ne $AcceptanceTextScalePercent) {
            throw 'Acceptance arguments differ from the immutable input manifest.'
        }
        Assert-AcceptanceInputArtifactBinding `
            -InputDocument $acceptanceInput `
            -Manifest $manifest `
            -CandidateLane $candidateLane
        $observer = $acceptanceInput.artifacts.observer
        if ($observer.file -cne 'inputs/windows-vm-acceptance.ps1' -or
            (Get-FileHash -LiteralPath (Join-Path $BundleRoot 'windows-vm-acceptance.ps1') -Algorithm SHA256).Hash -ine $observer.sha256) {
            throw 'Acceptance observer differs from the immutable input manifest.'
        }
        if ($candidateLane -and
            ($manifest.harness.observers.ui.file -cne 'windows-vm-acceptance.ps1' -or
             $manifest.harness.observers.ui.sha256 -ine $observer.sha256)) {
            throw 'Acceptance observer differs from the frozen candidate harness role.'
        }
    }
    elseif ($recovery) {
        Assert-PathWithoutReparse $RecoveryOutputRoot
        $outputItem = Get-Item -LiteralPath $RecoveryOutputRoot -Force
        if (-not $outputItem.PSIsContainer -or
            @(Get-ChildItem -LiteralPath $outputItem.FullName -Force).Count -ne 0) {
            throw 'Recovery output must be an existing empty ordinary directory.'
        }
        $observer = if ($candidateLane) {
            $manifest.harness.observers.recovery
        }
        else {
            [pscustomobject]@{
                file = 'windows-vm-recovery-acceptance.ps1'
                sha256 = $RecoveryObserverSha256
            }
        }
        $observerPath = Join-Path $BundleRoot 'windows-vm-recovery-acceptance.ps1'
        Assert-PathWithoutReparse $observerPath
        if ($observer.file -cne 'windows-vm-recovery-acceptance.ps1' -or
            $observer.sha256 -cne $RecoveryObserverSha256 -or
            (Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine
                $RecoveryObserverSha256) {
            throw 'Recovery observer differs from the frozen task role.'
        }
    }
    if ($transportKind -eq 'powershell_direct') {
        $vm = Resolve-DirectControllerVm -Name $VmName -ExpectedId $ExpectedVmId
        $mutex = New-Object Threading.Mutex($false, ('Local\DarkReNamerVmTests-' + $vm.Id))
        try { $mutexHeld = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
        if (-not $mutexHeld) { throw 'Another native test controller is using this VM.' }
        $credential = & $CredentialHelper -Action Load
        if ($credential -isnot [Management.Automation.PSCredential]) { throw 'Credential helper did not return a PSCredential.' }
        $vm = Resolve-DirectControllerVm -Name $VmName -ExpectedId $vm.Id
        if ($vm.State.ToString() -ne 'Running') { throw 'Start the configured VM before testing.' }
        $session = New-DirectControllerSession -VmId $vm.Id -Credential $credential
        $transport.vm_id = $vm.Id.ToString()
    }
    else {
        $session = New-SshControllerSession -HostAlias $SshHost
    }
    $endpoint = Invoke-Command -Session $session -ScriptBlock {
        $platform = [Environment]::OSVersion.Platform.ToString()
        $isAdministrator = $false
        if ($platform -ceq 'Win32NT') {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        [pscustomobject]@{
            platform = $platform
            powershell_version = $PSVersionTable.PSVersion.ToString()
            is_administrator = $isAdministrator
            vm_id = if ($platform -ceq 'Win32NT') {
                (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -Name VirtualMachineId).VirtualMachineId
            } else { $null }
        }
    }
    if ($endpoint.platform -cne 'Win32NT') {
        throw 'The selected transport endpoint must be the configured Windows VM.'
    }
    if ($transportKind -eq 'ssh') {
        Assert-SshPowerShellVersion -Version $endpoint.powershell_version -Context 'The VM SSH PowerShell subsystem'
    }
    if (-not $endpoint.is_administrator) {
        throw 'The VM controller account must be a local administrator so it can register the limited interactive test task.'
    }
    if ($observerTask -or $candidateLane) {
        $expectedGuestId = $ExpectedGuestVmId.ToString('D').ToLowerInvariant()
        try { $actualGuestId = ([guid]$endpoint.vm_id).ToString('D').ToLowerInvariant() }
        catch { throw 'The guest did not expose a canonical Hyper-V Guest Parameters VM identity.' }
        if ($actualGuestId -cne $expectedGuestId) {
            throw 'The SSH endpoint Hyper-V VM identity differs from the private connection profile.'
        }
        $guestIdentitySha256 = Get-LowerTextSha256 $actualGuestId
        if ($acceptance -and
            ($acceptanceInput.guest_preflight.vm_identity_kind -cne 'hyper-v-guest-parameters-virtual-machine-id-v1' -or
             $acceptanceInput.guest_preflight.vm_identity_sha256 -cne $guestIdentitySha256)) {
            throw 'The post-connection guest VM identity differs from the immutable preflight.'
        }
        $transport.vm_id = $actualGuestId
        $transport.vm_identity_kind = 'hyper-v-guest-parameters-virtual-machine-id-v1'
        $transport.vm_identity_sha256 = $guestIdentitySha256
    }
    $desktop = Invoke-Command -Session $session -ArgumentList $ExpectedDesktopSid -ScriptBlock {
        param($expectedSid)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($expectedSid -and $sid -cne $expectedSid) { throw 'RDP profile and controller account differ.' }
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VmDesktopState {
    [DllImport("wtsapi32.dll", SetLastError=true)]
    static extern bool WTSQuerySessionInformation(IntPtr server, int session, int info, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
    public static bool Active(int session) {
        IntPtr buffer; int bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, session, 8, out buffer, out bytes)) return false;
        try { return bytes >= 4 && Marshal.ReadInt32(buffer) == 0; }
        finally { WTSFreeMemory(buffer); }
    }
}
'@
        $localUser = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object SID -eq $sid)
        if ($localUser.Count -ne 1) { throw 'The VM test account must be local.' }
        $deadline = (Get-Date).AddSeconds(30)
        do {
            $sessions = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid -eq $sid } | Select-Object -ExpandProperty SessionId -Unique)
            $unlocked = @($sessions | Where-Object { $candidate = $_; [VmDesktopState]::Active($candidate) -and -not (Get-Process LogonUI -ErrorAction SilentlyContinue | Where-Object SessionId -eq $candidate) })
            if ($unlocked.Count -eq 1) { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)
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
    $toolingTransfer = New-ControllerToolingTransferStage -VerifiedTooling $VerifiedTooling
    Copy-Item `
        -LiteralPath (Join-Path $toolingTransfer.root 'tooling-bundle.json') `
        -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'tooling-bundle.json') `
        -ToSession $session
    foreach ($record in $toolingTransfer.records) {
        Copy-Item `
            -LiteralPath (Join-Path $toolingTransfer.root $record.file) `
            -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf $record.file) `
            -ToSession $session
    }
    $transferredTooling = Invoke-Command `
        -Session $session `
        -ArgumentList $guestRoot,$toolingTransfer.manifest_sha256,$toolingTransfer.records `
        -ScriptBlock {
            param($root,$manifestSha256,$records)
            $manifestPath = Join-Path $root 'tooling-bundle.json'
            if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ine
                $manifestSha256) {
                throw 'Transferred tooling manifest hash mismatch.'
            }
            foreach ($record in @($records)) {
                $path = Join-Path $root $record.file
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ($item.PSIsContainer -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $item.Length -ne [long]$record.bytes -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $record.sha256) {
                    throw "Transferred tooling module hash mismatch: $($record.role)."
                }
            }
            [pscustomobject]@{
                manifest_sha256 = $manifestSha256
                records = @($records | ForEach-Object {
                    [ordered]@{
                        role = $_.role
                        file = $_.file
                        sha256 = $_.sha256
                        bytes = [long]$_.bytes
                    }
                })
            }
        }
    $transport['tooling'] = $transferredTooling
    $transport.status = 'copying'
    if ($acceptance) {
        $guestBundleRoot = Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {
            param($root)
            $bundle = Join-Path $root 'bundle'
            [void](New-Item -ItemType Directory -Path $bundle)
            $bundle
        }
        $inputManifestSha256 = (Get-FileHash -LiteralPath $AcceptanceManifest -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
            $guestPath = Join-GuestWindowsPath -Root $guestBundleRoot -Leaf $name
            Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination $guestPath -ToSession $session
        }
        Copy-Item -LiteralPath (Join-Path $BundleRoot 'windows-vm-acceptance.ps1') -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'windows-vm-acceptance.ps1') -ToSession $session
        Copy-Item -LiteralPath $AcceptanceManifest -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'input-manifest.json') -ToSession $session
        $acceptanceEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$observer.sha256,$AcceptanceMode,$AcceptanceAppearance,$AcceptanceTextScalePercent,([bool]$AcceptanceHighContrast),([bool]$AcceptanceClipboard),([bool]$AcceptanceCaptureNativeMenu),([bool]$AcceptanceCaptureAdvancedAppearance) -ScriptBlock {
            param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$observerHash,$mode,$appearance,$textScale,$highContrast,$clipboard,$captureNativeMenu,$captureAdvancedAppearance)
            $observerPath = Join-Path $root 'windows-vm-acceptance.ps1'
            if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) { throw 'Transferred acceptance observer hash mismatch.' }
            $bundle = Join-Path $root 'bundle'
            $out = Join-Path $root 'out'
            $inputManifest = Join-Path $root 'input-manifest.json'
            $stdout = Join-Path $root 'observer.stdout.txt'
            $stderr = Join-Path $root 'observer.stderr.txt'
            $powerShell = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
            $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
                '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell acceptance engine.' }
            $engine = $engineJson | ConvertFrom-Json
            if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
                $engine.effective_policy -cne 'RemoteSigned') {
                throw 'GUI acceptance requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
            }
            $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -ExpectedScriptSha256 ' + $observerHash + ' -TimeoutSeconds ' + $testTimeout + ' -Appearance ' + $appearance
            if ($mode -cne 'current-dpi') {
                $observerArguments += ' -RegressionMode ' + $mode + ' -InputManifestPath "' + $inputManifest + '" -TextScalePercent ' + $textScale
            }
            else {
                if ($highContrast) { $observerArguments += ' -HighContrast' }
                if ($clipboard) { $observerArguments += ' -Clipboard' }
                if ($captureNativeMenu) { $observerArguments += ' -CaptureNativeMenu' }
                if ($captureAdvancedAppearance) { $observerArguments += ' -CaptureAdvancedAppearance' }
            }
            $arguments = '/d /s /c ""' + $powerShell + '" ' + $observerArguments + ' 1>"' + $stdout + '" 2>"' + $stderr + '""'
            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument $arguments -WorkingDirectory $root
            $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($suiteTimeout + 60))
            Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
            $registered = Get-ScheduledTaskInfo -TaskName $name
            $registeredTicks = [long]$registered.LastRunTime.Ticks
            Start-ScheduledTask -TaskName $name
            [pscustomobject]@{
                executable = 'pwsh.exe'
                version = [string]$engine.version
                edition = [string]$engine.edition
                effective_policy = [string]$engine.effective_policy
                registered_last_run_time_ticks = $registeredTicks
            }
        }
        $transport.acceptance_engine = [ordered]@{
            executable = [string]$acceptanceEngine.executable
            version = [string]$acceptanceEngine.version
            edition = [string]$acceptanceEngine.edition
            effective_policy = [string]$acceptanceEngine.effective_policy
        }
        $transport.status = 'running'
        $deadline = (Get-Date).AddSeconds($SuiteTimeoutSeconds)
        $state = [pscustomobject]@{result_status=$null;task_state='starting';task_result=$null}
        $pollFailure = $null
        try {
            do {
                Start-Sleep -Seconds 5
                $state = Invoke-Command -Session $session -ArgumentList $guestRoot,$taskName -ScriptBlock {
                    param($root,$name)
                    $info = Get-ScheduledTaskInfo -TaskName $name
                    $task = Get-ScheduledTask -TaskName $name
                    $taskState = $task.State.ToString()
                    $taskResult = [long]$info.LastTaskResult
                    if ($taskState -ceq 'Ready') {
                        $terminalInfo = Get-ScheduledTaskInfo -TaskName $name
                        $taskResult = [long]$terminalInfo.LastTaskResult
                    }
                    $file = Join-Path (Join-Path $root 'out') 'acceptance-result.json'
                    $resultStatus = $null
                    if (Test-Path -LiteralPath $file) {
                        try {
                            $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                            $resultStatus = [string]$data.status
                        } catch {}
                    }
                    [pscustomobject]@{
                        result_status = $resultStatus
                        task_state = $taskState
                        task_result = $taskResult
                        last_run_time_ticks = [long]$info.LastRunTime.Ticks
                    }
                }
                $state = Resolve-ObserverTaskPollState `
                    -ResultStatus $state.result_status `
                    -TaskState $state.task_state `
                    -TaskResult $state.task_result `
                    -RegisteredLastRunTimeTicks $acceptanceEngine.registered_last_run_time_ticks `
                    -LastRunTimeTicks $state.last_run_time_ticks
                if ($state.terminal) { break }
            } while ((Get-Date) -lt $deadline)
        }
        catch { $pollFailure = $_ }
        if ($null -eq $pollFailure -and ($null -eq $state -or -not $state.terminal)) {
            $pollFailure = [InvalidOperationException]::new('GUI acceptance timed out before the scheduled task reached its terminal state.')
        }
        if ($null -eq $pollFailure -and
            $state.result_status -notin @('review_required', 'failed', 'environment_blocked', 'unsupported', 'not_run')) {
            $pollFailure = [InvalidOperationException]::new('Acceptance task reached terminal state without a bounded result document.')
        }
        if ($null -eq $pollFailure -and $state.terminal) {
            $observerProcess = [ordered]@{
                state = 'exited'
                exit_code = [long]$state.task_result
            }
            $transport.observer_process = $observerProcess
            if ($state.task_result -ne 0) {
                $transport.observer_error = 'The acceptance observer task returned a nonzero terminal result.'
            }
        }
        if ($null -ne $pollFailure) {
            $transport.observer_error = 'The acceptance observer did not return a valid terminal result; inspect transport-error.txt.'
            Invoke-AcceptancePollFailureRescue `
                -Session $session `
                -GuestRoot $guestRoot `
                -DesktopSid $desktop.sid `
                -DesktopSessionId $desktop.session_id `
                -TaskName $taskName `
                -TestTimeoutSeconds $TestTimeoutSeconds `
                -SuiteTimeoutSeconds $SuiteTimeoutSeconds `
                -ObserverSha256 $observer.sha256 `
                -AcceptanceMode $AcceptanceMode `
                -Appearance $AcceptanceAppearance `
                -HighContrast ([bool]$AcceptanceHighContrast) `
                -HostOutputRoot $AcceptanceOutputRoot `
                -OriginalFailure $pollFailure
        }
        if ($AcceptanceMode -ceq 'text-scale' -and
            ($state.result_status -cne 'review_required' -or $state.task_result -ne 0)) {
            Invoke-AcceptanceTextScaleRescue `
                -Session $session `
                -GuestRoot $guestRoot `
                -DesktopSid $desktop.sid `
                -DesktopSessionId $desktop.session_id `
                -TaskName $taskName `
                -TestTimeoutSeconds $TestTimeoutSeconds `
                -SuiteTimeoutSeconds $SuiteTimeoutSeconds `
                -ObserverSha256 $observer.sha256 `
                -Appearance $AcceptanceAppearance `
                -HostOutputRoot $AcceptanceOutputRoot
        }
        if ($AcceptanceHighContrast -and
            ($state.result_status -cne 'review_required' -or $state.task_result -ne 0)) {
            Invoke-AcceptanceHighContrastRescue `
                -Session $session `
                -GuestRoot $guestRoot `
                -DesktopSid $desktop.sid `
                -DesktopSessionId $desktop.session_id `
                -TaskName $taskName `
                -TestTimeoutSeconds $TestTimeoutSeconds `
                -SuiteTimeoutSeconds $SuiteTimeoutSeconds `
                -ObserverSha256 $observer.sha256 `
                -HostOutputRoot $AcceptanceOutputRoot
        }
        Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {
            param($root)
            $out = Join-Path $root 'out'
            foreach ($leaf in @('observer.stdout.txt', 'observer.stderr.txt')) {
                $source = Join-Path $root $leaf
                if (Test-Path -LiteralPath $source -PathType Leaf) {
                    Move-Item -LiteralPath $source -Destination (Join-Path $out $leaf) -Force
                }
            }
        }
        if ($state.result_status -ceq 'review_required' -and $state.task_result -eq 0) {
            Invoke-Command -Session $session -ArgumentList $guestRoot,$acceptanceInput.run_id,$inputManifestSha256,$ExpectedGuestVmId -ScriptBlock {
            param($root,$runId,$inputHash,$expectedGuestVmId)
            $out = Join-Path $root 'out'
            $observations = Get-Content -LiteralPath (Join-Path $out 'acceptance-observations.json') -Raw | ConvertFrom-Json
            $window = $observations.environment.main_window
            if ($null -eq $window -or [long]$window.hwnd -le 0 -or [int]$window.process_id -le 0) {
                throw 'Acceptance observations do not identify the launched application window.'
            }
            $actualGuestId = ([guid](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -Name VirtualMachineId).VirtualMachineId).ToString('D').ToLowerInvariant()
            $expectedGuestId = ([guid]$expectedGuestVmId).ToString('D').ToLowerInvariant()
            if ($actualGuestId -cne $expectedGuestId) {
                throw 'Post-launch Hyper-V Guest Parameters VM identity differs from the private profile.'
            }
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try {
                $identityHash = ([BitConverter]::ToString(
                    $algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($actualGuestId))
                ) -replace '-', '').ToLowerInvariant()
            }
            finally { $algorithm.Dispose() }
            $receipt = [ordered]@{
                schema_version = 1
                run_id = $runId
                input_manifest_sha256 = $inputHash
                phase = 'post-launch'
                vm_identity_kind = 'hyper-v-guest-parameters-virtual-machine-id-v1'
                vm_identity_sha256 = $identityHash
                target = [ordered]@{
                    hwnd = [long]$window.hwnd
                    process_id = [int]$window.process_id
                    window_rect = $window.rect
                }
                identity_observation = [ordered]@{
                    source = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters::VirtualMachineId'
                    session = 'controller-pssession'
                    target_process_id = [int]$window.process_id
                }
            }
            [IO.File]::WriteAllText(
                (Join-Path $out 'platform-postlaunch.json'),
                ($receipt | ConvertTo-Json -Depth 6),
                [Text.UTF8Encoding]::new($false)
            )
            }
        }
        $inventory = @(Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {
            param($root)
            $out = Join-Path $root 'out'
            $rows = @(Get-ChildItem -LiteralPath $out -File -Force)
            if ($rows.Count -gt 128) { throw 'Acceptance output file count exceeds its bound.' }
            $total = [long]0
            foreach ($row in $rows) {
                if (($row.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $row.Length -gt 128MB) { throw 'Acceptance output contains an unsafe file.' }
                $total += $row.Length
                if ($total -gt 512MB) {
                    throw 'Acceptance output exceeds its aggregate size bound.'
                }
                [pscustomobject]@{file=$row.Name;bytes=$row.Length;sha256=(Get-FileHash -LiteralPath $row.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
            }
        })
        foreach ($output in $inventory) {
            Assert-PlainFile $output.file
            $guestOutputPath = Join-GuestWindowsPath -Root (Join-GuestWindowsPath -Root $guestRoot -Leaf 'out') -Leaf $output.file
            $hostOutputPath = Join-Path $AcceptanceOutputRoot $output.file
            if (-not (Test-Path -LiteralPath $hostOutputPath)) {
                Copy-Item -LiteralPath $guestOutputPath -Destination $hostOutputPath -FromSession $session
            }
            if ((Get-Item -LiteralPath $hostOutputPath).Length -ne $output.bytes -or
                (Get-FileHash -LiteralPath $hostOutputPath -Algorithm SHA256).Hash -ine $output.sha256) {
                throw 'Collected acceptance output hash mismatch.'
            }
        }
        $acceptanceResultPath = Join-Path $AcceptanceOutputRoot 'acceptance-result.json'
        $result = if (Test-Path -LiteralPath $acceptanceResultPath -PathType Leaf) {
            Get-Content -LiteralPath $acceptanceResultPath -Raw | ConvertFrom-Json
        } else { $null }
        if ($null -ne $result) {
            Assert-ObserverResultBinding `
                -Result $result `
                -Manifest $manifest `
                -Role ui `
                -ExpectedObserverSha256 $observer.sha256
        }
        $acceptancePassed = $null -ne $result -and
            $result.status -ceq 'review_required' -and
            $null -eq $pollFailure -and
            $null -ne $observerProcess -and
            $observerProcess.state -ceq 'exited' -and
            $observerProcess.exit_code -eq 0
        $transport.status = 'collected'
    }
    elseif ($recovery) {
        $guestBundleRoot = Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {
            param($root)
            $bundle = Join-Path $root 'bundle'
            $out = Join-Path $root 'out'
            $private = Join-Path $root 'private'
            [void](New-Item -ItemType Directory -Path $bundle)
            [void](New-Item -ItemType Directory -Path $out)
            [void](New-Item -ItemType Directory -Path $private)
            $bundle
        }
        foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
            $guestPath = Join-GuestWindowsPath -Root $guestBundleRoot -Leaf $name
            Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination $guestPath -ToSession $session
        }
        Copy-Item `
            -LiteralPath (Join-Path $BundleRoot 'windows-vm-recovery-acceptance.ps1') `
            -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'windows-vm-recovery-acceptance.ps1') `
            -ToSession $session
        $recoveryEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$observer.sha256,$RecoveryMode,$RecoveryFixtureCount,([bool]$RecoveryExport),([bool]$RecoveryIntentOnlyCandidateDiscard) -ScriptBlock {
            param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$observerHash,$mode,$fixtureCount,$recoveryExport,$intentOnlyCandidateDiscard)
            $observerPath = Join-Path $root 'windows-vm-recovery-acceptance.ps1'
            if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) {
                throw 'Transferred recovery observer hash mismatch.'
            }
            $bundle = Join-Path $root 'bundle'
            $out = Join-Path $root 'out'
            $private = Join-Path $root 'private'
            $stdout = Join-Path $root 'observer.stdout.txt'
            $stderr = Join-Path $root 'observer.stderr.txt'
            $powerShell = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
            $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
                '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell recovery engine.' }
            $engine = $engineJson | ConvertFrom-Json
            if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
                $engine.effective_policy -cne 'RemoteSigned') {
                throw 'Recovery acceptance requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
            }
            $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -PrivateEvidenceRoot "' + $private + '" -ExpectedScriptSha256 ' + $observerHash + ' -Mode ' + $mode + ' -FixtureCount ' + $fixtureCount + ' -TimeoutSeconds ' + $testTimeout
            if ($recoveryExport) { $observerArguments += ' -RecoveryExport' }
            if ($intentOnlyCandidateDiscard) {
                $observerArguments += ' -IntentOnlyCandidateDiscard'
            }
            $arguments = '/d /s /c ""' + $powerShell + '" ' + $observerArguments + ' 1>"' + $stdout + '" 2>"' + $stderr + '""'
            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument $arguments -WorkingDirectory $root
            $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($suiteTimeout + 60))
            Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
            $registered = Get-ScheduledTaskInfo -TaskName $name
            $registeredTicks = [long]$registered.LastRunTime.Ticks
            Start-ScheduledTask -TaskName $name
            [pscustomobject]@{
                executable = 'pwsh.exe'
                version = [string]$engine.version
                edition = [string]$engine.edition
                effective_policy = [string]$engine.effective_policy
                registered_last_run_time_ticks = $registeredTicks
            }
        }
        $transport.recovery_engine = [ordered]@{
            executable = [string]$recoveryEngine.executable
            version = [string]$recoveryEngine.version
            edition = [string]$recoveryEngine.edition
            effective_policy = [string]$recoveryEngine.effective_policy
        }
        $transport.status = 'running'
        $deadline = (Get-Date).AddSeconds($SuiteTimeoutSeconds)
        $state = [pscustomobject]@{result_status=$null;task_state='starting';task_result=$null}
        $pollFailure = $null
        try {
            do {
                Start-Sleep -Seconds 5
                $state = Invoke-Command -Session $session -ArgumentList $guestRoot,$taskName -ScriptBlock {
                    param($root,$name)
                    $info = Get-ScheduledTaskInfo -TaskName $name
                    $task = Get-ScheduledTask -TaskName $name
                    $taskState = $task.State.ToString()
                    $taskResult = [long]$info.LastTaskResult
                    if ($taskState -ceq 'Ready') {
                        $terminalInfo = Get-ScheduledTaskInfo -TaskName $name
                        $taskResult = [long]$terminalInfo.LastTaskResult
                    }
                    $summaries = @(
                        Get-ChildItem -LiteralPath (Join-Path $root 'out') -Directory -Force -ErrorAction SilentlyContinue |
                            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } |
                            ForEach-Object {
                                Get-Item -LiteralPath (Join-Path $_.FullName 'summary.json') -Force -ErrorAction SilentlyContinue
                            } |
                            Where-Object { -not $_.PSIsContainer -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 }
                    )
                    $resultStatus = $null
                    if ($summaries.Count -eq 1) {
                        try {
                            $data = Get-Content -LiteralPath $summaries[0].FullName -Raw | ConvertFrom-Json
                            $resultStatus = [string]$data.status
                        } catch {}
                    }
                    [pscustomobject]@{
                        result_status = $resultStatus
                        task_state = $taskState
                        task_result = $taskResult
                        last_run_time_ticks = [long]$info.LastRunTime.Ticks
                    }
                }
                $state = Resolve-ObserverTaskPollState `
                    -ResultStatus $state.result_status `
                    -TaskState $state.task_state `
                    -TaskResult $state.task_result `
                    -RegisteredLastRunTimeTicks $recoveryEngine.registered_last_run_time_ticks `
                    -LastRunTimeTicks $state.last_run_time_ticks
                if ($state.terminal) { break }
            } while ((Get-Date) -lt $deadline)
        }
        catch { $pollFailure = $_ }
        if ($null -eq $pollFailure -and ($null -eq $state -or -not $state.terminal)) {
            $pollFailure = [InvalidOperationException]::new('Recovery acceptance timed out before the scheduled task reached its terminal state.')
        }
        if ($null -eq $pollFailure -and $state.result_status -notin @('passed', 'failed')) {
            $pollFailure = [InvalidOperationException]::new('Recovery task reached terminal state without one bounded result document.')
        }
        if ($null -eq $pollFailure -and $state.terminal) {
            $observerProcess = [ordered]@{
                state = 'exited'
                exit_code = [long]$state.task_result
            }
            $transport.observer_process = $observerProcess
            if ($state.task_result -ne 0) {
                $transport.observer_error = 'The recovery observer task returned a nonzero terminal result.'
            }
        }
        if ($null -ne $pollFailure) {
            $transport.observer_error = 'The recovery observer did not return a valid terminal result; inspect transport-error.txt.'
            throw $pollFailure
        }
        Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {
            param($root)
            $out = Join-Path $root 'out'
            foreach ($leaf in @('observer.stdout.txt', 'observer.stderr.txt')) {
                $source = Join-Path $root $leaf
                if (Test-Path -LiteralPath $source -PathType Leaf) {
                    Move-Item -LiteralPath $source -Destination (Join-Path $out $leaf) -Force
                }
            }
        }
        $inventory = @(Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {
            param($root)
            $evidenceRoots = @(
                [pscustomobject]@{ item = Get-Item -LiteralPath (Join-Path $root 'out') -Force; prefix = '' },
                [pscustomobject]@{ item = Get-Item -LiteralPath (Join-Path $root 'private') -Force; prefix = 'private/' }
            )
            $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
            $rows = [Collections.Generic.List[object]]::new()
            $directoryCount = 0
            foreach ($evidenceRoot in $evidenceRoots) {
                if (($evidenceRoot.item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Recovery evidence root became a reparse point.'
                }
                $pending.Push($evidenceRoot.item)
                while ($pending.Count -gt 0) {
                    $directory = $pending.Pop()
                    foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
                        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                            throw 'Recovery output contains a reparse entry.'
                        }
                        if ($item.PSIsContainer) {
                            $directoryCount++
                            if ($directoryCount -gt 32) {
                                throw 'Recovery output directory count exceeds its bound.'
                            }
                            $pending.Push($item)
                        }
                        else {
                            $relative = $item.FullName.Substring($evidenceRoot.item.FullName.Length + 1).Replace('\', '/')
                            $rows.Add([pscustomobject]@{
                                item = $item
                                file = $evidenceRoot.prefix + $relative
                            })
                            if ($rows.Count -gt 256) {
                                throw 'Recovery output file count exceeds its bound.'
                            }
                        }
                    }
                }
            }
            $total = [long]0
            foreach ($row in $rows) {
                if (($row.item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $row.item.Length -gt 128MB) {
                    throw 'Recovery output contains an unsafe file.'
                }
                $total += $row.item.Length
                if ($total -gt 512MB) {
                    throw 'Recovery output exceeds its aggregate size bound.'
                }
                [pscustomobject]@{
                    file = $row.file
                    bytes = $row.item.Length
                    sha256 = (Get-FileHash -LiteralPath $row.item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        })
        $summaryRows = @($inventory | Where-Object { $_.file -cmatch '(^|/)summary\.json$' })
        if ($summaryRows.Count -ne 1 -or
            $summaryRows[0].file -cnotmatch '^[^/]+/summary\.json$') {
            throw 'Recovery output must contain exactly one session summary.'
        }
        foreach ($output in $inventory) {
            $segments = @(Get-SafeEvidencePathSegments $output.file)
            $guestOutputPath = if ($output.file.StartsWith('private/', [StringComparison]::Ordinal)) {
                Join-GuestEvidencePath -Root $guestRoot -RelativePath $output.file
            }
            else {
                Join-GuestEvidencePath `
                    -Root (Join-GuestWindowsPath -Root $guestRoot -Leaf 'out') `
                    -RelativePath $output.file
            }
            $hostOutputPath = $RecoveryOutputRoot
            foreach ($segment in $segments) {
                $hostOutputPath = Join-Path $hostOutputPath $segment
            }
            $hostParent = Split-Path -Parent $hostOutputPath
            if (-not (Test-Path -LiteralPath $hostParent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $hostParent)
            }
            Assert-PathWithoutReparse $hostParent
            if (Test-Path -LiteralPath $hostOutputPath) {
                throw 'Recovery output collides with an already collected path.'
            }
            Copy-Item -LiteralPath $guestOutputPath -Destination $hostOutputPath -FromSession $session
            if ((Get-Item -LiteralPath $hostOutputPath).Length -ne $output.bytes -or
                (Get-FileHash -LiteralPath $hostOutputPath -Algorithm SHA256).Hash -ine
                    $output.sha256) {
                throw 'Collected recovery output hash mismatch.'
            }
        }
        $summaryPath = $RecoveryOutputRoot
        foreach ($segment in @(Get-SafeEvidencePathSegments $summaryRows[0].file)) {
            $summaryPath = Join-Path $summaryPath $segment
        }
        $result = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        Assert-ObserverResultBinding `
            -Result $result `
            -Manifest $manifest `
            -Role recovery `
            -ExpectedObserverSha256 $observer.sha256
        $recoveryInventory = [ordered]@{
            schema_version = 1
            task_kind = 'recovery'
            observer_role = 'recovery'
            bundle_manifest_sha256 = (Get-FileHash `
                -LiteralPath (Join-Path $BundleRoot 'bundle.json') `
                -Algorithm SHA256).Hash.ToLowerInvariant()
            observer = [ordered]@{
                file = $observer.file
                sha256 = $observer.sha256
            }
            summary_file = $summaryRows[0].file
            files = @($inventory | Sort-Object file | ForEach-Object {
                [ordered]@{
                    file = $_.file
                    bytes = [long]$_.bytes
                    sha256 = $_.sha256
                }
            })
        }
        [IO.File]::WriteAllText(
            (Join-Path $RecoveryOutputRoot 'recovery-inventory.json'),
            ($recoveryInventory | ConvertTo-Json -Depth 6),
            [Text.UTF8Encoding]::new($false)
        )
        $acceptancePassed = $result.status -ceq 'passed' -and
            $null -eq $pollFailure -and
            $null -ne $observerProcess -and
            $observerProcess.state -ceq 'exited' -and
            $observerProcess.exit_code -eq 0
        $transport.status = 'collected'
    }
    else {
    foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
        $guestPath = Join-GuestWindowsPath -Root $guestRoot -Leaf $name
        Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination $guestPath -ToSession $session
    }
    if ($candidateLane) {
        Invoke-Command -Session $session -ArgumentList $guestRoot,$manifest.product.application.file,$manifest.product.application.sha256 -ScriptBlock {
            param($root,$applicationFile,$applicationHash)
            $path = Join-Path $root $applicationFile
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $applicationHash) {
                throw 'Transferred candidate executable hash mismatch.'
            }
            $signature = Get-AuthenticodeSignature -FilePath $path
            if ($signature.Status -ne 'NotSigned') {
                throw "Candidate Authenticode status differs from the current unsigned policy: $($signature.Status)."
            }
        }
    }
    $runnerArtifact = if ($candidateLane) { $manifest.harness.runner } else { $manifest.runner }
    $runnerEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$runnerArtifact.sha256 -ScriptBlock {
        param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$runnerHash)
        $runner = Join-Path $root 'windows-vm-guest.ps1'
        if ((Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash -ine $runnerHash) { throw 'Transferred guest runner hash mismatch.' }
        $powerShell = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
        $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
            '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell guest engine.' }
        $engine = $engineJson | ConvertFrom-Json
        if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
            $engine.effective_policy -cne 'RemoteSigned') {
            throw 'Native VM validation requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
        }
        $arguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $runner + '" -BundleRoot "' + $root + '" -ExpectedSessionId ' + $desktopSession + ' -TestTimeoutSeconds ' + $testTimeout
        $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $root
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($suiteTimeout + 60))
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName $name
        [pscustomobject]@{
            executable = $powerShell
            version = [string]$engine.version
            edition = [string]$engine.edition
            effective_policy = [string]$engine.effective_policy
        }
    }
    $transport.runner_engine = [ordered]@{
        executable = [string]$runnerEngine.executable
        version = [string]$runnerEngine.version
        edition = [string]$runnerEngine.edition
        effective_policy = [string]$runnerEngine.effective_policy
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
    $guestResultPath = Join-GuestWindowsPath -Root $guestRoot -Leaf 'result.json'
    Copy-Item -LiteralPath $guestResultPath -Destination (Join-Path $BundleRoot 'result.json') -FromSession $session
    $result = Get-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Raw | ConvertFrom-Json
    $outputs = @()
    foreach ($row in $result.tests) {
        foreach ($channel in @('stdout','stderr')) { if ($row.$channel) { $outputs += $row.$channel } }
    }
    if ($result.gui -and $result.gui.PSObject.Properties.Name -contains 'screenshot' -and $result.gui.screenshot) { $outputs += $result.gui.screenshot }
    if ($result.gui -and $result.gui.flow -and $result.gui.flow.screenshots) {
        $outputs += @($result.gui.flow.screenshots)
    }
    if ($result.gui -and $result.gui.flow -and $result.gui.flow.diagnostic) {
        $outputs += $result.gui.flow.diagnostic
    }
    $failureDiagnostics = @(Get-CoreGuiFailureDiagnosticOutputs -Gui $result.gui)
    $collectedOutputNames = @{}
    foreach ($output in $outputs) {
        Assert-PlainFile $output.file
        if ($collectedOutputNames.ContainsKey($output.file)) {
            throw 'Guest output contains a duplicate file reference.'
        }
        if ($names.ContainsKey($output.file) -or $output.file -in @('bundle.json','result.json','transport.json','run-windows-vm-tests.ps1')) { throw 'Guest output collides with a bundle input.' }
        $collectedOutputNames[$output.file] = $true
        $guestOutputPath = Join-GuestWindowsPath -Root $guestRoot -Leaf $output.file
        Copy-Item -LiteralPath $guestOutputPath -Destination (Join-Path $BundleRoot $output.file) -FromSession $session
        if ((Get-FileHash -LiteralPath (Join-Path $BundleRoot $output.file) -Algorithm SHA256).Hash -ine $output.sha256) { throw 'Collected guest output hash mismatch.' }
    }
    foreach ($diagnosticOutput in $failureDiagnostics) {
        Assert-PlainFile $diagnosticOutput.file
        if ($collectedOutputNames.ContainsKey($diagnosticOutput.file) -or
            $names.ContainsKey($diagnosticOutput.file) -or
            $diagnosticOutput.file -in @(
                'bundle.json','result.json','transport.json','run-windows-vm-tests.ps1'
            )) {
            throw 'Guest failure diagnostic collides with another output or bundle input.'
        }
        $collectedOutputNames[$diagnosticOutput.file] = $true
        $guestDiagnosticPath = Join-GuestWindowsPath `
            -Root $guestRoot `
            -Leaf $diagnosticOutput.file
        $hostDiagnosticPath = Join-Path $BundleRoot $diagnosticOutput.file
        if (Test-Path -LiteralPath $hostDiagnosticPath) {
            throw 'Guest failure diagnostic collides with an existing host path.'
        }
        Copy-Item `
            -LiteralPath $guestDiagnosticPath `
            -Destination $hostDiagnosticPath `
            -FromSession $session
        if ((Get-Item -LiteralPath $hostDiagnosticPath).Length -ne $diagnosticOutput.bytes -or
            (Get-FileHash -LiteralPath $hostDiagnosticPath -Algorithm SHA256).Hash -ine
                $diagnosticOutput.sha256) {
            throw 'Collected guest failure diagnostic hash or size mismatch.'
        }
    }
    $transport.status = 'collected'
    }
} catch {
    $transport.status = 'failed'
    $transport.error = 'VM transport failed; inspect transport-error.txt.'
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'transport-error.txt') -Encoding UTF8
} finally {
    $toolingCleanupError = Remove-ControllerToolingTransferStage -Transfer $toolingTransfer
    if ($null -ne $toolingCleanupError) {
        $transport.status = 'failed'
        $transport['tooling_cleanup_error'] = $toolingCleanupError
    }
    if ($session) {
        try {
            Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {
                param($name)
                $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                if ($task) { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $name -Confirm:$false }
            }
            if ($guestRoot) {
                $cleanupAuthorized = $transport.status -eq 'collected' -and
                    (-not $observerTask -or $acceptancePassed)
                $cleanupResult = Invoke-Command -Session $session -ArgumentList $guestRoot,$taskName,$cleanupAuthorized -ScriptBlock {
                    param($root,$name,$mayDelete)
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
                    $taskPresentBeforeDelete = [bool](Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)
                    if (-not $mayDelete -or $taskPresentBeforeDelete) {
                        return [pscustomobject]@{
                            guest_cleanup = $false
                            raw_cleanup = [ordered]@{
                                scheduled_task_present = $taskPresentBeforeDelete
                                guest_root_present = [bool](Test-Path -LiteralPath $root)
                                owned_processes_after = @(Get-CimInstance Win32_Process | Where-Object {
                                    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
                                } | Sort-Object ProcessId | ForEach-Object {
                                    [ordered]@{ pid = [int]$_.ProcessId; session_id = [int]$_.SessionId; executable_path = [string]$_.ExecutablePath }
                                })
                            }
                        }
                    }
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
                    $rootPresent = [bool](Test-Path -LiteralPath $root)
                    $ownedAfter = @(Get-CimInstance Win32_Process | Where-Object {
                        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
                    } | Sort-Object ProcessId | ForEach-Object {
                        [ordered]@{ pid = [int]$_.ProcessId; session_id = [int]$_.SessionId; executable_path = [string]$_.ExecutablePath }
                    })
                    $taskPresent = [bool](Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)
                    [pscustomobject]@{
                        guest_cleanup = (-not $rootPresent -and -not $taskPresent -and $ownedAfter.Count -eq 0)
                        raw_cleanup = [ordered]@{
                            scheduled_task_present = $taskPresent
                            guest_root_present = $rootPresent
                            owned_processes_after = $ownedAfter
                        }
                    }
                }
                if ($null -eq $cleanupResult -or $cleanupResult.guest_cleanup -isnot [bool] -or
                    $null -eq $cleanupResult.raw_cleanup) {
                    throw 'Guest cleanup did not return its bound raw observation.'
                }
                $transport.guest_cleanup = [bool]$cleanupResult.guest_cleanup
                $transport['raw_cleanup'] = $cleanupResult.raw_cleanup
            }
        } catch {
            $transport.status='failed'; $transport.cleanup_error='Guest cleanup failed; inspect cleanup-error.txt.'; $transport.guest_cleanup=$false
            $_ | Out-String | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'cleanup-error.txt') -Encoding UTF8
        }
        if ($guestRoot -and -not $transport.guest_cleanup) { [IO.File]::WriteAllText((Join-Path $transportOutputRoot 'retained-guest-directory.txt'), $guestRoot) }
        Remove-PSSession $session
    }
    if ($credential) { $credential.Password.Dispose() }
    if ($mutexHeld) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() }
    $transport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'transport.json') -Encoding UTF8
    if ($result -and $taskSelection.kind -ceq 'core') {
        $result | Add-Member -NotePropertyName transport -NotePropertyValue $transport -Force
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Encoding UTF8
    }
}
if ($transport.status -ne 'collected' -or -not $transport.guest_cleanup -or
    ($observerTask -and -not $acceptancePassed)) {
    throw 'VM transport, acceptance, or cleanup failed; inspect transport.json.'
}
}

Export-ModuleMember -Function Invoke-DrWindowsVmController
