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

function Close-DrControllerResources {
    param(
        [AllowNull()][object] $Session,
        [AllowNull()][object] $Credential,
        [AllowNull()][object] $Mutex,
        [bool] $MutexHeld
    )

    $errors = [Collections.Generic.List[string]]::new()
    if ($null -ne $Session) {
        try { Remove-PSSession -Session $Session -ErrorAction Stop }
        catch { $errors.Add('Session removal: ' + $_.Exception.Message) }
    }
    if ($null -ne $Credential) {
        try { $Credential.Password.Dispose() }
        catch { $errors.Add('Credential disposal: ' + $_.Exception.Message) }
    }
    if ($null -ne $Mutex) {
        if ($MutexHeld) {
            try { $Mutex.ReleaseMutex() }
            catch { $errors.Add('Mutex release: ' + $_.Exception.Message) }
        }
        try { $Mutex.Dispose() }
        catch { $errors.Add('Mutex disposal: ' + $_.Exception.Message) }
    }
    $errors.ToArray()
}
