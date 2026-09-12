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
    [string] $AcceptanceOutputRoot,
    [string] $AcceptanceManifest,
    [ValidateSet('full-context', 'standard', 'text-scale', 'tooltip')]
    [string] $AcceptanceMode,
    [ValidateSet('light', 'dark')][string] $AcceptanceAppearance,
    [ValidateSet(100, 150)][int] $AcceptanceTextScalePercent = 100,
    [guid] $ExpectedGuestVmId = [guid]::Empty
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$transportKind = if ($PSCmdlet.ParameterSetName -eq 'Ssh') { 'ssh' } else { 'powershell_direct' }
$acceptance = -not [string]::IsNullOrEmpty($AcceptanceOutputRoot)
if ($acceptance -ne (-not [string]::IsNullOrEmpty($AcceptanceManifest)) -or
    $acceptance -ne (-not [string]::IsNullOrEmpty($AcceptanceMode)) -or
    $acceptance -ne (-not [string]::IsNullOrEmpty($AcceptanceAppearance))) {
    throw 'Acceptance output, manifest, mode, and appearance must be supplied together.'
}
if (($AcceptanceMode -ceq 'text-scale') -ne ($AcceptanceTextScalePercent -eq 150)) {
    throw 'Only the text-scale acceptance mode may request 150 percent text.'
}
if ($acceptance -and $ExpectedGuestVmId -eq [guid]::Empty) {
    throw 'Acceptance requires the expected Hyper-V guest VM identity.'
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
$transport = [ordered]@{
    kind = $transportKind
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
$transportOutputRoot = if ($acceptance) { $AcceptanceOutputRoot } else { $BundleRoot }
$mutex = $null
$mutexHeld = $false

function Assert-PlainFile([string] $Name) {
    if ($Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$') { throw 'Invalid bundle file name.' }
}
function Join-GuestWindowsPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Leaf
    )

    Assert-PlainFile $Leaf
    if ($Root.EndsWith('\', [StringComparison]::Ordinal) -or
        $Root.EndsWith('/', [StringComparison]::Ordinal)) {
        return $Root + $Leaf
    }
    $Root + '\' + $Leaf
}
function Assert-PathWithoutReparse([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse paths are not supported for VM test bundles.' }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}

function Get-LowerTextSha256([string] $Value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString(
            $algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Value))
        ) -replace '-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Assert-SshPowerShellVersion {
    param([AllowNull()][object] $Version, [string] $Context)

    $versionText = [string] $Version
    if ($versionText -cnotmatch '^\d+\.\d+(?:\.\d+){0,2}$') {
        throw "$Context must report a numeric PowerShell version."
    }
    if ([version] $versionText -lt [version] '7.4') {
        throw "$Context requires PowerShell 7.4 or newer."
    }
}

function New-SshControllerSession([string] $HostAlias) {
    Assert-SshPowerShellVersion -Version $PSVersionTable.PSVersion.ToString() -Context 'SSH transport controller host'
    $options = @{
        BatchMode = 'yes'
        StrictHostKeyChecking = 'yes'
        ForwardAgent = 'no'
    }
    New-PSSession -HostName $HostAlias -Options $options
}

function Resolve-DirectControllerVm {
    param([string] $Name, [guid] $ExpectedId = [guid]::Empty)
    $matches = if ($ExpectedId -ne [guid]::Empty) {
        @(Get-VM -Id $ExpectedId -ErrorAction Stop)
    }
    else {
        @(Get-VM -Name $Name -ErrorAction Stop)
    }
    if (@($matches).Count -ne 1) { throw 'The configured VM must resolve to exactly one VM.' }
    $vm = @($matches)[0]
    if ($vm.Name -cne $Name -or
        ($ExpectedId -ne [guid]::Empty -and $vm.Id -ne $ExpectedId)) {
        throw 'The configured VM GUID and exact name do not match.'
    }
    return $vm
}

function New-DirectControllerSession {
    param([guid] $VmId, [Management.Automation.PSCredential] $Credential)
    New-PSSession -VMId $VmId -Credential $Credential
}

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
    Invoke-Command -Session $Session -ArgumentList $GuestRoot,$DesktopSid,$DesktopSessionId,$TaskName,$TestTimeoutSeconds,$rescueTimeout,$ObserverSha256,$Appearance -ScriptBlock {
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
        Start-ScheduledTask -TaskName $name
    }

    $deadline = (Get-Date).AddSeconds($rescueTimeout)
    do {
        Start-Sleep -Seconds 2
        $rescue = Invoke-Command -Session $Session -ArgumentList $GuestRoot,$TaskName -ScriptBlock {
            param($root,$name)
            $resultPath = Join-Path (Join-Path $root 'out') 'text-scale-rescue-result.json'
            if (Test-Path -LiteralPath $resultPath) {
                try {
                    $document = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                    [pscustomobject]@{status=[string]$document.status;task_result=0}
                    return
                } catch {}
            }
            $task = Get-ScheduledTask -TaskName $name
            $info = Get-ScheduledTaskInfo -TaskName $name
            [pscustomobject]@{status=$task.State.ToString();task_result=$info.LastTaskResult}
        }
        if ($rescue.status -in @('passed', 'failed')) { break }
        if ($rescue.status -eq 'Ready' -and $rescue.task_result -ne 0) { break }
    } while ((Get-Date) -lt $deadline)

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
        $guestPath = Join-GuestWindowsPath -Root (Join-Path $GuestRoot 'out') -Leaf $file.file
        $hostPath = Join-Path $HostOutputRoot $file.file
        Copy-Item -LiteralPath $guestPath -Destination $hostPath -FromSession $Session
        if ((Get-Item -LiteralPath $hostPath).Length -ne $file.bytes -or
            (Get-FileHash -LiteralPath $hostPath -Algorithm SHA256).Hash -ine $file.sha256) {
            throw 'Collected text-scale rescue evidence hash mismatch.'
        }
    }
    if ($rescue.status -cne 'passed') {
        throw 'Text-scale rescue did not verify exact restoration; inspect rescue evidence.'
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
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
    if ($acceptance) {
        Assert-PathWithoutReparse $AcceptanceManifest
        Assert-PathWithoutReparse $AcceptanceOutputRoot
        $outputItem = Get-Item -LiteralPath $AcceptanceOutputRoot -Force
        if (-not $outputItem.PSIsContainer -or @(Get-ChildItem -LiteralPath $outputItem.FullName -Force).Count -ne 0) {
            throw 'Acceptance output must be an existing empty ordinary directory.'
        }
        $acceptanceInput = Get-Content -LiteralPath $AcceptanceManifest -Raw | ConvertFrom-Json
        if ($acceptanceInput.schema_version -ne 1 -or
            $acceptanceInput.source_sha -cne $manifest.source_sha -or
            $acceptanceInput.request.mode -cne $AcceptanceMode -or
            $acceptanceInput.request.appearance -cne $AcceptanceAppearance -or
            $acceptanceInput.request.text_scale_percent -ne $AcceptanceTextScalePercent) {
            throw 'Acceptance arguments differ from the immutable input manifest.'
        }
        $observer = $acceptanceInput.artifacts.observer
        if ($observer.file -cne 'inputs/windows-vm-acceptance.ps1' -or
            (Get-FileHash -LiteralPath (Join-Path $BundleRoot 'windows-vm-acceptance.ps1') -Algorithm SHA256).Hash -ine $observer.sha256) {
            throw 'Acceptance observer differs from the immutable input manifest.'
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
    if ($acceptance) {
        $expectedGuestId = $ExpectedGuestVmId.ToString('D').ToLowerInvariant()
        try { $actualGuestId = ([guid]$endpoint.vm_id).ToString('D').ToLowerInvariant() }
        catch { throw 'The guest did not expose a canonical Hyper-V Guest Parameters VM identity.' }
        if ($actualGuestId -cne $expectedGuestId) {
            throw 'The SSH endpoint Hyper-V VM identity differs from the private connection profile.'
        }
        $guestIdentitySha256 = Get-LowerTextSha256 $actualGuestId
        if ($acceptanceInput.guest_preflight.vm_identity_kind -cne 'hyper-v-guest-parameters-virtual-machine-id-v1' -or
            $acceptanceInput.guest_preflight.vm_identity_sha256 -cne $guestIdentitySha256) {
            throw 'The post-connection guest VM identity differs from the immutable preflight.'
        }
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
        $acceptanceEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$observer.sha256,$AcceptanceMode,$AcceptanceAppearance,$AcceptanceTextScalePercent -ScriptBlock {
            param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$observerHash,$mode,$appearance,$textScale)
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
            $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -ExpectedScriptSha256 ' + $observerHash + ' -TimeoutSeconds ' + $testTimeout + ' -Appearance ' + $appearance + ' -RegressionMode ' + $mode + ' -InputManifestPath "' + $inputManifest + '" -TextScalePercent ' + $textScale
            $arguments = '/d /s /c ""' + $powerShell + '" ' + $observerArguments + ' 1>"' + $stdout + '" 2>"' + $stderr + '""'
            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument $arguments -WorkingDirectory $root
            $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($suiteTimeout + 60))
            Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
            Start-ScheduledTask -TaskName $name
            [pscustomobject]@{
                executable = 'pwsh.exe'
                version = [string]$engine.version
                edition = [string]$engine.edition
                effective_policy = [string]$engine.effective_policy
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
                    $file = Join-Path (Join-Path $root 'out') 'acceptance-result.json'
                    $resultStatus = $null
                    if (Test-Path -LiteralPath $file) {
                        try {
                            $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                            $resultStatus = [string]$data.status
                        } catch {}
                    }
                    $task = Get-ScheduledTask -TaskName $name
                    $info = Get-ScheduledTaskInfo -TaskName $name
                    [pscustomobject]@{
                        result_status = $resultStatus
                        task_state = $task.State.ToString()
                        task_result = [int]$info.LastTaskResult
                    }
                }
                if ($state.task_state -ceq 'Ready') { break }
            } while ((Get-Date) -lt $deadline)
        }
        catch { $pollFailure = $_ }
        if ($null -eq $pollFailure -and $state.task_state -cne 'Ready') {
            $pollFailure = [InvalidOperationException]::new('GUI acceptance timed out before the scheduled task reached its terminal state.')
        }
        if ($null -eq $pollFailure -and
            $state.result_status -notin @('review_required', 'failed', 'environment_blocked', 'unsupported', 'not_run')) {
            $pollFailure = [InvalidOperationException]::new('Acceptance task reached terminal state without a bounded result document.')
        }
        if ($state.task_state -ceq 'Ready') {
            $observerProcess = [ordered]@{
                state = 'exited'
                exit_code = [int]$state.task_result
            }
            $transport.observer_process = $observerProcess
            if ($state.task_result -ne 0) {
                $transport.observer_error = 'The acceptance observer task returned a nonzero terminal result.'
            }
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
                [pscustomobject]@{file=$row.Name;bytes=$row.Length;sha256=(Get-FileHash -LiteralPath $row.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
            }
            if ($total -gt 512MB) { throw 'Acceptance output exceeds its aggregate size bound.' }
        })
        foreach ($output in $inventory) {
            Assert-PlainFile $output.file
            $guestOutputPath = Join-GuestWindowsPath -Root (Join-Path $guestRoot 'out') -Leaf $output.file
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
        $acceptancePassed = $null -ne $result -and
            $result.status -ceq 'review_required' -and
            $null -ne $observerProcess -and
            $observerProcess.state -ceq 'exited' -and
            $observerProcess.exit_code -eq 0
        $transport.status = 'collected'
        if ($null -ne $pollFailure) {
            $transport.observer_error = 'The acceptance observer did not return a valid terminal result; inspect transport-error.txt.'
            $pollFailure | Out-String | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'transport-error.txt') -Encoding UTF8
        }
    }
    else {
    foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
        $guestPath = Join-GuestWindowsPath -Root $guestRoot -Leaf $name
        Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination $guestPath -ToSession $session
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
    foreach ($output in $outputs) {
        Assert-PlainFile $output.file
        if ($names.ContainsKey($output.file) -or $output.file -in @('bundle.json','result.json','transport.json','run-windows-vm-tests.ps1')) { throw 'Guest output collides with a bundle input.' }
        $guestOutputPath = Join-GuestWindowsPath -Root $guestRoot -Leaf $output.file
        Copy-Item -LiteralPath $guestOutputPath -Destination (Join-Path $BundleRoot $output.file) -FromSession $session
        if ((Get-FileHash -LiteralPath (Join-Path $BundleRoot $output.file) -Algorithm SHA256).Hash -ine $output.sha256) { throw 'Collected guest output hash mismatch.' }
    }
    $transport.status = 'collected'
    }
} catch {
    $transport.status = 'failed'
    $transport.error = 'VM transport failed; inspect transport-error.txt.'
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'transport-error.txt') -Encoding UTF8
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
            $_ | Out-String | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'cleanup-error.txt') -Encoding UTF8
        }
        if ($guestRoot -and -not $transport.guest_cleanup) { [IO.File]::WriteAllText((Join-Path $transportOutputRoot 'retained-guest-directory.txt'), $guestRoot) }
        Remove-PSSession $session
    }
    if ($credential) { $credential.Password.Dispose() }
    if ($mutexHeld) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() }
    $transport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'transport.json') -Encoding UTF8
    if ($result -and -not $acceptance) {
        $result | Add-Member -NotePropertyName transport -NotePropertyValue $transport -Force
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Encoding UTF8
    }
}
if ($transport.status -ne 'collected' -or -not $transport.guest_cleanup -or ($acceptance -and -not $acceptancePassed)) { throw 'VM transport, acceptance, or cleanup failed; inspect transport.json.' }
