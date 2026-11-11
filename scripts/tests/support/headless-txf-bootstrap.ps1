# This file is inserted after the exact tracked guest-process.ps1 by the prepare-only generator.
# It is a diagnostic transport, not a product admission or release gate.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$pin = @{schema=$null;vm_guid=$null;head=$null;tree=$null;guest=$null}
$script:headlessRows = [Collections.Generic.List[object]]::new()
$script:headlessRoot = $null
$script:rootReceipt = $null
$script:fixtureInventory = [Collections.Generic.List[object]]::new()
$script:headlessFailure = $null
$script:headlessOutcome = 'not-started'
$private = $null
$trust = $null
$route = $null
$actualGuid = $null
$script:maxRawBytes = 1MB
$script:maxTerminalRecordBytes = 1500000

function Test-HeadlessJobClean($State, $Wait, $ExitCode) {
    return $null -ne $State -and $null -ne $Wait -and
        $null -eq $Wait.failure_reason -and $ExitCode -is [int] -and $ExitCode -eq 0 -and
        $State.job_empty -and $State.job_closed -and $State.job_capture_complete -and
        $State.job_active_processes_at_close -eq 0 -and
        -not $State.job_had_survivors -and -not $State.job_forced_termination -and
        [string]::IsNullOrEmpty([string]$State.job_cleanup_error)
}

function Test-HeadlessSourcePin($Actual, $Expected) {
    if ($null -eq $Actual -or $null -eq $Expected -or
        $Actual.head -cne $Expected.head -or $Actual.tree -cne $Expected.tree -or
        $null -eq $Actual.files -or $null -eq $Expected.files -or
        $Actual.files.Count -ne $Expected.files.Count) { return $false }
    foreach ($name in $Expected.files.Keys) {
        if (-not $Actual.files.ContainsKey($name) -or
            $Actual.files[$name] -cne $Expected.files[$name]) { return $false }
    }
    return $true
}

function Get-HeadlessTerminalByteCount([string]$Json) {
    return [Text.Encoding]::UTF8.GetByteCount('DR_HEADLESS_TXF '+$Json+"`r`n")
}

function Assert-HeadlessPayloadLimit([long]$RawBytes, [long]$TerminalRecordBytes) {
    if ($RawBytes -lt 0 -or $RawBytes -gt $script:maxRawBytes -or
        $TerminalRecordBytes -lt 0 -or
        $TerminalRecordBytes -gt $script:maxTerminalRecordBytes) {
        throw 'Headless diagnostic evidence exceeds its guest terminal record bound.'
    }
}

function Limit-HeadlessError([string]$Value) {
    if ($Value.Length -gt 384) { return $Value.Substring(0,384) }
    return $Value
}

function Write-HeadlessTerminal($Record,[long]$RawBytes) {
    try {
        $wire=$Record | ConvertTo-Json -Depth 15 -Compress
        Assert-HeadlessPayloadLimit $RawBytes (Get-HeadlessTerminalByteCount $wire)
        return ('DR_HEADLESS_TXF '+$wire)
    }
    catch {
        $script:headlessOutcome='payload-refused'
        $script:headlessFailure=[ordered]@{type=$_.Exception.GetType().FullName;
            message=Limit-HeadlessError $_.Exception.Message}
        $smallJobs=[Collections.Generic.List[object]]::new()
        foreach($job in @($Record.jobs)){
            $outputs=[ordered]@{}
            foreach($key in @('stdout','stderr','controller_result','source_proof','route_record')){
                $evidence=$job[$key]
                if($null -eq $evidence){continue}
                $leaf=switch($key){
                    'stdout'{"$($job.name).stdout.bin"}
                    'stderr'{"$($job.name).stderr.bin"}
                    'controller_result'{"$($job.name)-controller.json"}
                    'route_record'{'route.json'}
                    'source_proof'{if($job.name -ceq 'clone'){'source-proof-clone.json'}
                        else {"source-$($job.name).json"}}
                }
                $outputs[$key]=[ordered]@{path=(Join-Path $Record.retained_root $leaf);
                    bytes=$evidence.bytes;sha256=$evidence.sha256}
            }
            $smallJobs.Add([ordered]@{name=$job.name;start_attempted=$job.start_attempted;
                started=$job.started;pid=$job.pid;
                process_start_time_utc_ticks=$job.process_start_time_utc_ticks;
                process_create_begin_timestamp=$job.process_create_begin_timestamp;
                process_create_end_timestamp=$job.process_create_end_timestamp;
                started_utc=$job.started_utc;ended_utc=$job.ended_utc;
                exit_code=$job.exit_code;wait=$job.wait;job=$job.job;
                error=$job.error;stdout_path=$job.stdout_path;
                stderr_path=$job.stderr_path;outputs=$outputs})
        }
        $inventories=[Collections.Generic.List[object]]::new()
        foreach($inventory in @($Record.fixture_inventory)){
            $snapshots=[ordered]@{}
            foreach($name in @('before','after')){
                $snapshot=$inventory[$name]
                if($null -ne $snapshot){$snapshots[$name]=[ordered]@{
                    exists=$snapshot.exists;file_id=$snapshot.file_id;
                    entries=@($snapshot.entries | ForEach-Object {
                        [ordered]@{name=$_.name;file_id=$_.file_id}})}}
            }
            $inventories.Add([ordered]@{phase=$inventory.phase;snapshots=$snapshots;
                after_error=$inventory.after_error;reconciled=$inventory.reconciled;
                primary_start_attempted=$inventory.primary_start_attempted;
                primary_started=$inventory.primary_started;unattributed=$inventory.unattributed})
        }
        $fallback=[ordered]@{schema='dark240-win11-headless-diagnostic-v1';
            outcome='payload-refused';vm_guid=$Record.vm_guid;
            observed_vm_guid=$Record.observed_vm_guid;source_head=$Record.source_head;
            source_tree=$Record.source_tree;nonce=$Record.nonce;
            retained_root=$Record.retained_root;root_receipt=$Record.root_receipt;
            fixture_inventory=@($inventories.ToArray());jobs=@($smallJobs.ToArray());
            prior_failure=$Record.failure;error=$script:headlessFailure.message;
            cleanup='all diagnostic roots and raw files retained; exact-root cleanup pending';
            gate1='unverified';product=0;vm_campaign=0}
        $fallbackWire=$fallback | ConvertTo-Json -Depth 12 -Compress
        if((Get-HeadlessTerminalByteCount $fallbackWire) -gt 65536){
            throw 'Bounded failure receipt exceeded 64 KiB; retained files need local recovery.'}
        return ('DR_HEADLESS_TXF '+$fallbackWire)
    }
}

function Assert-HeadlessTerminalAccepted {
    if($script:headlessOutcome -cne 'diagnostics-executed'){
        throw 'Headless TxF diagnostic did not complete.'
    }
}

function Assert-OrdinaryChain([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not [IO.Path]::IsPathRooted($full)){throw 'Diagnostic path is not rooted.'}
    $chain=[Collections.Generic.List[string]]::new()
    for($current=$full;$null -ne $current;$current=[IO.Path]::GetDirectoryName($current)){
        $chain.Add($current)
        if([IO.Path]::GetPathRoot($current) -ceq $current){break}
    }
    for($index=$chain.Count-1;$index -ge 0;$index--){
        $item = Get-Item -LiteralPath $chain[$index] -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'A headless diagnostic ancestor is a reparse point.'
        }
        if($index -gt 0 -and $item -isnot [IO.DirectoryInfo]){
            throw 'A headless diagnostic ancestor is not a directory.'}
    }
}

function Test-HeadlessUntrustedWriter($Rule,[string[]]$Trusted,$UnsafeRights) {
    if(($Rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0){
        return $false
    }
    return $Rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        $Rule.IdentityReference.Value -notin $Trusted -and
        (([int64]$Rule.FileSystemRights -band [int64]$UnsafeRights) -ne 0)
}

function Assert-TrustedExecutable([string]$Path,$Expected) {
    Assert-OrdinaryChain $Path
    if(-not [string]::Equals([IO.Path]::GetFullPath($Path),$Expected.path,
            [StringComparison]::OrdinalIgnoreCase)){
        throw 'Diagnostic executable path differs from the prepared pin.'}
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 1 -or $item.Length -gt 64MB) {
        throw 'A diagnostic executable is not an ordinary file.'
    }
    Assert-OrdinaryChain $item.DirectoryName
    $unsafeLeafRights = [int64][Security.AccessControl.FileSystemRights]::Write -bor
        [int64][Security.AccessControl.FileSystemRights]::Delete -bor
        [int64][Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [int64][Security.AccessControl.FileSystemRights]::TakeOwnership -bor
        0x10000000 -bor 0x40000000
    $unsafeAncestorRights = [int64][Security.AccessControl.FileSystemRights]::Delete -bor
        [int64][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [int64][Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [int64][Security.AccessControl.FileSystemRights]::TakeOwnership -bor
        0x10000000 -bor 0x40000000
    $trusted=@('S-1-5-18','S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $current = $item
    while ($null -ne $current) {
        $unsafeRights = if($current -is [IO.FileInfo]){$unsafeLeafRights}else{$unsafeAncestorRights}
        $acl=Get-Acl -LiteralPath $current.FullName -ErrorAction Stop
        if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){
            throw 'A diagnostic executable or ancestor has an untrusted owner.'}
        $rules = $acl.GetAccessRules(
            $true, $true, [Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            if (Test-HeadlessUntrustedWriter $rule $trusted $unsafeRights) {
                throw 'A diagnostic executable or ancestor permits an untrusted writer.'
            }
        }
        $current = if($current -is [IO.FileInfo]){$current.Directory}else{$current.Parent}
    }
    $hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash -cne $Expected.sha256){throw 'Diagnostic executable SHA-256 differs from the prepared pin.'}
    $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName)
    if($version.FileVersion -cne $Expected.file_version -or
        ($Expected.ContainsKey('product_version') -and
            $version.ProductVersion -cne $Expected.product_version)){
        throw 'Diagnostic executable version differs from the prepared pin.'}
    return [ordered]@{path=$item.FullName;bytes=$item.Length;sha256=$hash;
        file_version=$version.FileVersion;product_version=$version.ProductVersion;
        owner=(Get-Acl -LiteralPath $item.FullName).GetOwner([Security.Principal.SecurityIdentifier]).Value}
}

function New-HeadlessPrivateRoot([string]$LocalTemp) {
    $nonce = [Guid]::NewGuid().ToString('N')
    $path = Join-Path $LocalTemp "Dark180-Headless-$nonce"
    if (Test-Path -LiteralPath $path) { throw 'The new diagnostic root already exists.' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true,$false)
    $security.SetOwner($sid)
    foreach ($ownerSid in @($sid,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $ownerSid,[Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    [void][IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($path),$security)
    $readback = Get-Acl -LiteralPath $path -ErrorAction Stop
    if (-not $readback.AreAccessRulesProtected -or
        $readback.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value) {
        throw 'Private diagnostic DACL or owner readback differs.'
    }
    $allowed = @($sid.Value,'S-1-5-18','S-1-5-32-544')
    $rules=@($readback.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if($rules.Count -ne 3 -or @($rules.IdentityReference.Value | Sort-Object -Unique).Count -ne 3){
        throw 'Private diagnostic DACL rule count or trustee uniqueness differs.'}
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.IdentityReference.Value -notin $allowed -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or
            $rule.IsInherited) {throw 'Private diagnostic DACL rule differs.'}
    }
    Assert-OrdinaryChain $path
    return [ordered]@{path=$path;nonce=$nonce}
}

function Initialize-HeadlessIdentityRuntime {
    if('Dark240HeadlessIdentity' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class Dark240HeadlessIdentity {
    [DllImport("kernel32.dll",EntryPoint="CreateFileW",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
    static extern IntPtr Open(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(IntPtr handle,int kind,byte[] output,uint size);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool CloseHandle(IntPtr handle);
    public static string Read(string path) {
        IntPtr h=Open(path,0x80,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        if(h==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error(),"Exact directory identity open failed.");
        byte[] bytes=new byte[24];Exception error=null;bool closed=false;int closeError=0;
        try {if(!GetFileInformationByHandleEx(h,18,bytes,(uint)bytes.Length))
                error=new Win32Exception(Marshal.GetLastWin32Error(),"Exact directory FileID query failed.");}
        finally {closed=CloseHandle(h);if(!closed)closeError=Marshal.GetLastWin32Error();}
        if(error!=null)throw error;
        if(!closed)throw new Win32Exception(closeError,"Exact directory identity handle close failed.");
        return BitConverter.ToString(bytes).Replace("-","").ToLowerInvariant();
    }
}
'@
}

function Get-HeadlessRootReceipt([string]$Path) {
    Assert-OrdinaryChain $Path
    $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if(-not $acl.AreAccessRulesProtected -or
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid -or
        $rules.Count -ne 3){throw 'Headless root ACL readback differs.'}
    $daclHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::Unicode.GetBytes($acl.GetSecurityDescriptorSddlForm('Access')))).ToLowerInvariant()
    return [ordered]@{path=$Path;file_id=[Dark240HeadlessIdentity]::Read($Path);
        volume=[IO.Path]::GetPathRoot($Path);owner_sid=$sid;dacl_sha256=$daclHash;
        protected=$acl.AreAccessRulesProtected;rules=$rules.Count}
}

function Assert-HeadlessRootUnchanged($Expected,[string]$Path) {
    $actual=Get-HeadlessRootReceipt $Path
    if($actual.file_id -cne $Expected.file_id -or
        $actual.dacl_sha256 -cne $Expected.dacl_sha256 -or
        $actual.owner_sid -cne $Expected.owner_sid -or
        $actual.volume -cne $Expected.volume){throw 'Headless private root identity or ACL changed.'}
}

function Get-HeadlessFixtureInventory([string]$Base) {
    if(-not [IO.Directory]::Exists($Base)){
        if(Test-Path -LiteralPath $Base){throw 'Fixed fixture base is not an ordinary directory.'}
        return [ordered]@{exists=$false;path=$Base;file_id=$null;entries=@()}
    }
    Assert-OrdinaryChain $Base
    $entries=[Collections.Generic.List[object]]::new()
    foreach($path in [IO.Directory]::EnumerateFileSystemEntries($Base)){
        if($entries.Count -ge 9){throw 'Fixed fixture base contains too many entries.'}
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item -isnot [IO.DirectoryInfo] -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
            throw 'Fixed fixture base has a non-directory or reparse entry.'}
        $entries.Add([ordered]@{name=$item.Name;path=$item.FullName;
            file_id=[Dark240HeadlessIdentity]::Read($item.FullName)})
    }
    return [ordered]@{exists=$true;path=$Base;
        file_id=[Dark240HeadlessIdentity]::Read($Base);entries=@($entries.ToArray())}
}

function Test-HeadlessInventoryReconciled($Before,$After,$Controller,[string]$Base) {
    if($null -eq $Before -or $null -eq $After -or $null -eq $Controller -or
        $null -eq $Controller.trials -or
        ($Before.exists -and (-not $After.exists -or $Before.file_id -cne $After.file_id))){return $false}
    $known=@{}
    foreach($entry in @($Before.entries)){$known[$entry.name]=$entry.file_id}
    foreach($trial in @($Controller.trials)){
        $scope=[string]$trial.scope
        if(-not [string]::Equals([IO.Path]::GetDirectoryName($scope),$Base,
                [StringComparison]::OrdinalIgnoreCase)){return $false}
        $name=[IO.Path]::GetFileName($scope)
        if($name -cnotmatch '^[0-9a-f]{32}$' -or $known.ContainsKey($name)){return $false}
        $known[$name]=$null
    }
    if($known.Count -ne @($After.entries).Count){return $false}
    foreach($entry in @($After.entries)){
        if(-not $known.ContainsKey($entry.name)){return $false}
        if($null -ne $known[$entry.name] -and $known[$entry.name] -cne $entry.file_id){return $false}
    }
    return $true
}

function Set-HeadlessPrimaryAttribution($InventoryRow,$JobRow) {
    if($null -eq $JobRow){return}
    $InventoryRow.primary_start_attempted=[bool]$JobRow.start_attempted
    $InventoryRow.primary_started=$JobRow.started
}

function Assert-HeadlessCheckoutBudget([string]$Checkout,[Diagnostics.Stopwatch]$Watch,
        [int]$DeadlineSeconds) {
    if (-not [IO.Directory]::Exists($Checkout)) { return }
    $stack=[Collections.Generic.Stack[object]]::new()
    $stack.Push([ordered]@{path=$Checkout;depth=0})
    [long]$count=0;[long]$bytes=0
    while($stack.Count -ne 0) {
        if($Watch.Elapsed.TotalSeconds -ge $DeadlineSeconds){throw 'Owned clone deadline elapsed during inventory.'}
        $node=$stack.Pop()
        if($node.depth -gt 32){throw 'Owned checkout depth cap exceeded.'}
        foreach($path in [IO.Directory]::EnumerateFileSystemEntries($node.path)) {
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
                throw 'Owned checkout contains a reparse entry.'}
            $count++
            if($count -gt 10000){throw 'Owned checkout file-count cap exceeded.'}
            if($item -is [IO.DirectoryInfo]){$stack.Push([ordered]@{path=$item.FullName;depth=$node.depth+1})}
            elseif($item -is [IO.FileInfo]){$bytes += $item.Length}
            else{throw 'Owned checkout entry is not ordinary.'}
            if($bytes -gt 128MB){throw 'Owned checkout byte cap exceeded.'}
        }
    }
}

function Write-HeadlessFile([string]$Path,[string]$Content) {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Content)
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function New-HeadlessEvidence([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt $script:maxRawBytes) { throw 'A captured output is unsafe or too large.' }
    $bytes=[IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -ne $item.Length) { throw 'Captured output size changed.' }
    return [ordered]@{bytes=$bytes.Length;sha256=[Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();base64=[Convert]::ToBase64String($bytes)}
}

function Invoke-HeadlessJob([string]$Name,[string]$File,[string]$Arguments,
        [string]$Work,[int]$Seconds,[switch]$WatchCheckout) {
    $stdout=Join-Path $script:headlessRoot "$Name.stdout.bin"
    $stderr=Join-Path $script:headlessRoot "$Name.stderr.bin"
    $row=[ordered]@{name=$Name;started_utc=[DateTime]::UtcNow.ToString('o');
        ended_utc=$null;start_attempted=$false;started=$false;
        pid=$null;process_start_time_utc_ticks=$null;
        process_create_begin_timestamp=$null;process_create_end_timestamp=$null;
        exit_code=$null;wait=$null;job=$null;
        stdout_path=$stdout;stderr_path=$stderr;
        stdout=$null;stderr=$null;error=$null}
    $script:headlessRows.Add($row)
    $state=$null
    try {
        Assert-HeadlessRootUnchanged $script:rootReceipt $script:headlessRoot
        $row.start_attempted=$true
        $row.started=$null # A thrown factory call cannot prove the primary never started.
        $state=Start-JobBoundProcess -FilePath $File -Arguments $Arguments -WorkingDirectory $Work `
            -StdoutPath $stdout -StderrPath $stderr -AggregateOutputLimitBytes $script:maxRawBytes
        $row.pid=$state.process.Id
        $row.process_start_time_utc_ticks=$state.process_start_time_utc_ticks
        if($null -ne $row.pid -and -not [string]::IsNullOrEmpty(
                [string]$row.process_start_time_utc_ticks)){$row.started=$true}
        $row.process_create_begin_timestamp=$state.ProcessCreateBeginTimestamp
        $row.process_create_end_timestamp=$state.ProcessCreateEndTimestamp
        if ($WatchCheckout) {
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while (-not $state.process.WaitForExit(250)) {
                if ($watch.Elapsed.TotalSeconds -ge $Seconds) { throw 'Owned clone deadline elapsed.' }
                $checkout=Join-Path $script:headlessRoot 'checkout'
                Assert-HeadlessCheckoutBudget $checkout $watch $Seconds
                if ($state.owner.OutputLimitExceeded) { throw 'Owned clone output cap elapsed.' }
            }
            $remaining=[Math]::Max(1,$Seconds-[int][Math]::Floor($watch.Elapsed.TotalSeconds))
            $row.wait=Wait-JobBoundProcessWithOutputLimit -State $state -StdoutPath $stdout `
                -StderrPath $stderr -TimeoutSeconds $remaining
        }
        else {
            $row.wait=Wait-JobBoundProcessWithOutputLimit -State $state -StdoutPath $stdout `
                -StderrPath $stderr -TimeoutSeconds $Seconds
        }
        $row.exit_code=$state.process.ExitCode
    }
    catch { $row.error=Limit-HeadlessError $_.Exception.Message }
    finally {
        if ($null -ne $state) {
            try { [void](Close-JobBoundProcess -State $state) }
            catch { $row.error=Limit-HeadlessError ("$($row.error); close: $($_.Exception.Message)") }
            $row.job=[ordered]@{empty=$state.job_empty;closed=$state.job_closed;
                capture_complete=$state.job_capture_complete;forced=$state.job_forced_termination;
                survivors=$state.job_had_survivors;active_at_close=$state.job_active_processes_at_close;
                cleanup_error=Limit-HeadlessError ([string]$state.job_cleanup_error)}
        }
        try {Assert-HeadlessRootUnchanged $script:rootReceipt $script:headlessRoot}
        catch {$row.error=Limit-HeadlessError ("$($row.error); root: $($_.Exception.Message)")}
        foreach ($entry in @(@('stdout',$stdout),@('stderr',$stderr))) {
            if (Test-Path -LiteralPath $entry[1]) {
                try { $row[$entry[0]]=New-HeadlessEvidence $entry[1] }
                catch { $row.error=Limit-HeadlessError ("$($row.error); capture: $($_.Exception.Message)") }
            }
        }
        $row.ended_utc=[DateTime]::UtcNow.ToString('o')
    }
    if ($null -eq $state -or -not (Test-HeadlessJobClean $state $row.wait $row.exit_code) -or
        $null -ne $row.error -or $null -eq $row.stdout -or $null -eq $row.stderr) {
        throw "Headless $Name job did not finish with complete owned output and closure."
    }
    return $row
}

function Assert-HeadlessRouteInputs {
    $redirect=@('GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE',
        'GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES','GIT_NAMESPACE',
        'GIT_REPLACE_REF_BASE','GIT_GRAFT_FILE','GIT_SHALLOW_FILE')
    foreach($name in [Environment]::GetEnvironmentVariables('Process').Keys){
        if(($name -in $redirect -or $name -like 'GIT_CONFIG_*') -and
            -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name,'Process'))){
            throw 'Inherited Git repository or config redirect needs separate route qualification.'
        }
    }
}

function Assert-HeadlessGitRoutePin($Pin) {
    if($null -eq $Pin -or $Pin.Count -ne 2 -or
        $Pin.backend -cne 'schannel' -or
        $Pin.origin -cne 'file:C:/Program Files/Git/etc/gitconfig') {
        throw 'Git backend or system-config origin differs from the reviewed route.'
    }
}

function Invoke-HeadlessRouteEnvironment([scriptblock]$Action) {
    Assert-HeadlessRouteInputs # Reject before any Git process can read redirected locations.
    $names=@(@([Environment]::GetEnvironmentVariables('Process').Keys | Where-Object {
        $_ -like 'GIT_TRACE*' -or $_ -ieq 'GIT_CURL_VERBOSE'}) +
        @('GIT_TRACE','GIT_TRACE2','GIT_TRACE2_EVENT','GIT_TRACE2_PERF') |
        Select-Object -Unique)
    $original=@{}
    foreach($name in $names){$original[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    try{
        foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
        # Trace2 targets ignore command-line -c; explicit environment 0 defeats global/system targets.
        foreach($name in @('GIT_TRACE','GIT_TRACE2','GIT_TRACE2_EVENT','GIT_TRACE2_PERF')){
            [Environment]::SetEnvironmentVariable($name,'0','Process')}
        & $Action
    }
    finally{foreach($name in $names){
        [Environment]::SetEnvironmentVariable($name,$original[$name],'Process')}}
}

function Invoke-HeadlessGitEnvironment([scriptblock]$Action,[string]$PrivateRoot,
        [string]$GitExecutable,[string]$PwshExecutable,$GitRoute) {
    Assert-HeadlessGitRoutePin $GitRoute
    foreach($name in @('GIT_SSL_CAINFO','GIT_SSL_CAPATH')){
        if(-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name,'Process'))){
            throw 'A Git-specific TLS trust input needs separate route qualification.'
        }
    }
    $original=@{}
    $names=@([Environment]::GetEnvironmentVariables('Process').Keys |
        Where-Object { $_ -like 'GIT_*' }) + @('GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL',
        'GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0',
        'GIT_TERMINAL_PROMPT','GIT_TEMPLATE_DIR','GIT_NO_REPLACE_OBJECTS',
        'GIT_OPTIONAL_LOCKS','SSH_ASKPASS','PATH')
    $names=@($names | Select-Object -Unique)
    foreach ($name in $names) { $original[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
    try {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_NOSYSTEM','1','Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL',
            (Join-Path $PrivateRoot 'empty-gitconfig'),'Process')
        [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT','0','Process')
        [Environment]::SetEnvironmentVariable('GIT_NO_REPLACE_OBJECTS','1','Process')
        [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS','0','Process')
        [Environment]::SetEnvironmentVariable('GIT_TEMPLATE_DIR',
            (Join-Path $PrivateRoot 'empty-template'),'Process')
        # Command-scope configuration reaches the clone and each later proof/fixture Git child.
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT','1','Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_0','http.sslBackend','Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_0',$GitRoute.backend,'Process')
        $trustedPath=@([IO.Path]::GetDirectoryName($GitExecutable),
            [IO.Path]::GetDirectoryName($PwshExecutable),$original['PATH']) -join ';'
        [Environment]::SetEnvironmentVariable('PATH',$trustedPath,'Process')
        & $Action
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$original[$name],'Process') }
    }
}

function Assert-HeadlessClonePin([string]$Root,[string]$Leaf,$Expected) {
    $proof=Join-Path $Root $Leaf
    $item=Get-Item -LiteralPath $proof -Force -ErrorAction Stop
    if ($item.Length -gt 16384 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Clone source proof is unsafe.'
    }
    $actual=Get-Content -LiteralPath $proof -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
    if (-not (Test-HeadlessSourcePin $actual $Expected) -or -not $actual.clean) {
        throw 'Cloned source identity, tree, clean state or runtime file hash differs.'
    }
    if($null -eq $actual.isolated_git_route -or
        $actual.isolated_git_route.configured_backend -cne $Expected.git_route.backend -or
        $actual.isolated_git_route.effective_backend -cne $Expected.git_route.backend -or
        $actual.isolated_git_route.effective_origin -cne 'command line:') {
        throw 'Isolated Git backend readback differs from the reviewed route.'
    }
}

function Read-HeadlessController($Row,[string]$Phase,[string]$Root) {
    if($null -eq $Row -or $null -eq $Row.stdout){return $null}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString(
        [Convert]::FromBase64String($Row.stdout.base64))
    $prefix="DR_PHASE_${Phase}_CONTROLLER "
    $lines=@($text -split "`r?`n" | Where-Object { $_.StartsWith($prefix) })
    if($lines.Count -ne 1){return $null}
    $json=$lines[0].Substring($prefix.Length)
    $controller=$json | ConvertFrom-Json -AsHashtable
    $result=Join-Path $Root ("phase-$Phase-controller.json")
    Write-HeadlessFile $result $json
    $Row.controller_result=New-HeadlessEvidence $result
    return $controller
}

function Get-HeadlessUnattributed($Before,$After,$Controller) {
    if($null -eq $After){return @('inventory-unavailable')}
    $known=@{}
    if($null -ne $Before){foreach($entry in @($Before.entries)){$known[$entry.name]=$true}}
    if($null -ne $Controller -and $null -ne $Controller.trials){
        foreach($trial in @($Controller.trials)){
            $known[[IO.Path]::GetFileName([string]$trial.scope)]=$true}}
    return @($After.entries | Where-Object {-not $known.ContainsKey($_.name)} |
        ForEach-Object {$_.name})
}

try {
    $pin = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__HEADLESS_PIN_BASE64__')) |
        ConvertFrom-Json -AsHashtable
    if (-not $IsWindows -or $pin.schema -cne 'dark240-win11-headless-bootstrap-pin-v1' -or
        [guid]$pin.vm_guid -eq [guid]::Empty) { throw 'Headless diagnostic platform or pin is invalid.' }
    Assert-HeadlessGitRoutePin $pin.git_route
    $actualGuid=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' `
        -ErrorAction Stop).VirtualMachineId
    if ([guid]$actualGuid -ne [guid]$pin.vm_guid) { throw 'Guest VM GUID differs from prepared pin.' }
    $token=[Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin=[Security.Principal.WindowsPrincipal]::new($token).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if($null -eq $pin.guest -or $token.User.Value -cne $pin.guest.sid -or
        $token.Name -cne $pin.guest.account -or $isAdmin -ne [bool]$pin.guest.admin -or
        [Environment]::OSVersion.Version.Build -ne [int]$pin.guest.os_build -or
        [Environment]::OSVersion.Version.Major -ne 10 -or
        $PSVersionTable.PSVersion.ToString() -cne $pin.guest.ps_version){
        throw 'Guest token, account or Windows 11 cohort differs from prepared pin.'}
    if ([Environment]::GetEnvironmentVariable('DARKRENAMER_VM_ELEVATED_OBSERVER') -eq '1') {
        throw 'Elevated observer environment is forbidden for this diagnostic.'
    }
    $profileTemp=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'
    if (-not [string]::Equals([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\'),
            [IO.Path]::GetFullPath($profileTemp).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase)) { throw 'Profile Temp route differs.' }
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($profileTemp))
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed -or
        $drive.DriveFormat -cne 'NTFS') { throw 'Profile Temp is not fixed NTFS.' }
    Assert-OrdinaryChain $profileTemp
    $pwsh=(Get-Command pwsh.exe -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $git=(Get-Command git.exe -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $trust=[ordered]@{pwsh=Assert-TrustedExecutable $pwsh $pin.guest.pwsh;
        git=Assert-TrustedExecutable $git $pin.guest.git;
        token_sid=$token.User.Value;account=$token.Name;administrator=$isAdmin;
        os_build=[Environment]::OSVersion.Version.Build}
    Initialize-HeadlessIdentityRuntime
    $private=New-HeadlessPrivateRoot $profileTemp
    $script:headlessRoot=$private.path
    $script:rootReceipt=Get-HeadlessRootReceipt $script:headlessRoot
    [void][IO.Directory]::CreateDirectory((Join-Path $script:headlessRoot 'empty-template'))
    Write-HeadlessFile (Join-Path $script:headlessRoot 'empty-gitconfig') ''
    $checkout=Join-Path $script:headlessRoot 'checkout'
    $gitScript=Join-Path $script:headlessRoot 'clone-and-prove.ps1'
    $pinLiteral=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        ($pin | ConvertTo-Json -Depth 8 -Compress)))
    $cloneCode=@'
param([string]$Git,[string]$Root,[string]$PinBase64,[string]$ProofLeaf,[switch]$ProofOnly)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$pin=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PinBase64)) | ConvertFrom-Json -AsHashtable
$checkout=Join-Path $Root 'checkout'
$url='https://github.com/PiesP/DarkReNamer.git'
$backendLines=@(& $Git config get --url=$url --show-origin --no-show-names http.sslBackend)
if($LASTEXITCODE -ne 0 -or $backendLines.Count -ne 1 -or
    $backendLines[0] -cne ("command line:`t"+$pin.git_route.backend)){
    throw 'Isolated Git backend command-scope readback differs before clone or proof.'}
$isolated=[ordered]@{configured_backend=$pin.git_route.backend;
    effective_backend=$pin.git_route.backend;effective_origin='command line:'}
Write-Output ('DR_HEADLESS_GIT_ISOLATED_ROUTE '+($isolated | ConvertTo-Json -Compress))
if(-not $ProofOnly){
    & $Git -c core.fsmonitor=false -c http.sslVerify=true -c credential.helper= -c core.hooksPath=NUL clone --depth=1 --single-branch --branch master https://github.com/PiesP/DarkReNamer.git $checkout
    if($LASTEXITCODE -ne 0){throw 'Exact public clone failed.'}
}
$head=(& $Git -c core.fsmonitor=false -C $checkout rev-parse HEAD);if($LASTEXITCODE -ne 0){throw 'Clone HEAD failed.'}
$tree=(& $Git -c core.fsmonitor=false -C $checkout rev-parse 'HEAD^{tree}');if($LASTEXITCODE -ne 0){throw 'Clone tree failed.'}
$status=(& $Git -c core.fsmonitor=false -C $checkout status --porcelain=v1 --untracked-files=all)
if($LASTEXITCODE -ne 0){throw 'Clone clean status failed.'}
$indexFlags=@(& $Git -c core.fsmonitor=false -C $checkout ls-files -v)
if($LASTEXITCODE -ne 0 -or @($indexFlags | Where-Object { -not $_.StartsWith('H ') }).Count -ne 0){
    throw 'Clone index contains hidden or unsupported worktree flags.'}
$hashes=@{}
foreach($relative in $pin.files.Keys){$path=Join-Path $checkout $relative
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Runtime file not ordinary.'}
    $hashes[$relative]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
$actual=[ordered]@{head=([string]$head).Trim();tree=([string]$tree).Trim();clean=([string]::IsNullOrWhiteSpace(($status -join '')));files=$hashes;
    isolated_git_route=$isolated}
$json=$actual | ConvertTo-Json -Depth 8 -Compress
$bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
$stream=[IO.FileStream]::new((Join-Path $Root $ProofLeaf),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
if(-not $actual.clean -or $actual.head -cne $pin.head -or $actual.tree -cne $pin.tree){throw 'Clone exact source differs.'}
foreach($key in $pin.files.Keys){if($actual.files[$key] -cne $pin.files[$key]){throw 'Clone runtime file differs.'}}
'@
    Write-HeadlessFile $gitScript $cloneCode
    $routeScript=Join-Path $script:headlessRoot 'route-check.ps1'
$routeCode=@'
param([string]$Git,[string]$Root,[string]$ExpectedBackend,[string]$ExpectedOrigin)
$ErrorActionPreference='Stop'
$url='https://github.com/PiesP/DarkReNamer.git'
$backendLines=@(& $Git config get --url=$url --show-origin --no-show-names http.sslBackend)
if($LASTEXITCODE -ne 0 -or $backendLines.Count -ne 1 -or
    $backendLines[0] -cne ($ExpectedOrigin+"`t"+$ExpectedBackend)){
    throw 'Effective Git backend or origin differs from the prepared route.'}
foreach($key in @('http.proxy','http.sslCAInfo','http.sslCAPath','http.sslCert','http.sslKey',
        'http.schannelCheckRevoke','http.schannelUseSSLCAInfo','http.pinnedPubkey',
        'http.sslCertType','http.sslKeyType','http.sslCertPasswordProtected',
        'http.sslVersion','http.sslCipherList')){
    $value=(& $Git config get --url=$url --no-show-names $key)
    $code=$LASTEXITCODE
    if($code -ne 1 -or @($value).Count -ne 0){
        throw "Configured Git $key input needs separate route qualification under isolated Git config."}
}
$verification=(& $Git config get --url=$url --no-show-names http.sslVerify)
if($LASTEXITCODE -ne 1 -or @($verification).Count -ne 0){
    throw 'Existing Git TLS verification input differs from the observed route.'}
$environmentNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($name in [Environment]::GetEnvironmentVariables('Process').Keys){
    [void]$environmentNames.Add([string]$name)}
$unexpectedEnv=@('GIT_SSL_NO_VERIFY','GIT_SSL_CAINFO','GIT_SSL_CAPATH',
    'GIT_SSL_CERT','GIT_SSL_KEY','GIT_SSL_VERSION','GIT_SSL_CIPHER_LIST',
    'GIT_SSL_CERT_PASSWORD_PROTECTED','GIT_SSL_CERT_TYPE','GIT_SSL_KEY_TYPE',
    'CURL_CA_BUNDLE',
    'SSL_CERT_FILE','SSL_CERT_DIR','HTTPS_PROXY','https_proxy',
    'ALL_PROXY','all_proxy','NO_PROXY','no_proxy') | Where-Object {
    $environmentNames.Contains($_)}
if(@($unexpectedEnv).Count -ne 0){throw 'A TLS, certificate or proxy environment input differs from the observed route.'}
$route=[ordered]@{schema='dark240-headless-git-route-v1';
    configured_git_proxy=$false;proxy_environment_present=$false;
    configured_git_backend=$ExpectedBackend;configured_git_backend_origin=$ExpectedOrigin;
    route='ordinary HTTPS with observed system Schannel setting; strict verification and no proxy or custom trust input'}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($route | ConvertTo-Json -Compress))
$stream=[IO.FileStream]::new((Join-Path $Root 'route.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
'@
    Write-HeadlessFile $routeScript $routeCode
    $routeArguments="-NoLogo -NoProfile -NonInteractive -File `"$routeScript`" -Git `"$git`" -Root `"$script:headlessRoot`" -ExpectedBackend $($pin.git_route.backend) -ExpectedOrigin `"$($pin.git_route.origin)`""
    $routeRow=Invoke-HeadlessRouteEnvironment -Action {
        Invoke-HeadlessJob -Name 'git-route' -File $pwsh -Arguments $routeArguments `
            -Work $script:headlessRoot -Seconds 10
    }
    $route=Get-Content -LiteralPath (Join-Path $script:headlessRoot 'route.json') -Raw |
        ConvertFrom-Json -AsHashtable
    if($route.schema -cne 'dark240-headless-git-route-v1' -or $route.configured_git_proxy -or
        $route.configured_git_backend -cne $pin.git_route.backend -or
        $route.configured_git_backend_origin -cne $pin.git_route.origin){
        throw 'Git route preflight differs.'
    }
    $routeRow.route_record=New-HeadlessEvidence (Join-Path $script:headlessRoot 'route.json')
    $gitArguments="-NoLogo -NoProfile -NonInteractive -File `"$gitScript`" -Git `"$git`" -Root `"$script:headlessRoot`" -PinBase64 $pinLiteral -ProofLeaf source-proof-clone.json"
    Invoke-HeadlessGitEnvironment -PrivateRoot $script:headlessRoot -GitExecutable $git `
            -PwshExecutable $pwsh -GitRoute $pin.git_route -Action {
        $cloneRow=Invoke-HeadlessJob -Name 'clone' -File $pwsh -Arguments $gitArguments `
            -Work $script:headlessRoot -Seconds 120 -WatchCheckout
        Assert-HeadlessCheckoutBudget $checkout ([Diagnostics.Stopwatch]::StartNew()) 15
        Assert-HeadlessClonePin $script:headlessRoot 'source-proof-clone.json' $pin
        $cloneRow.source_proof=New-HeadlessEvidence (Join-Path $script:headlessRoot 'source-proof-clone.json')
        $fixtureBase=Join-Path $profileTemp 'Dark180-TxfPhaseB'
        $priorInventory=$null
        foreach($phase in @(@('B','exact-manifest-txf-phase-b',210),
                @('C','exact-manifest-txf-phase-c',90))) {
            $phaseName=[string]$phase[0]
            $inventoryRow=[ordered]@{phase=$phaseName;before=$null;after=$null;
                after_error=$null;controller_observed=$false;reconciled=$false;
                unattributed=@();primary_start_attempted=$false;
                primary_started=$false;failure=$null}
            $inventoryRow.before=Get-HeadlessFixtureInventory $fixtureBase
            $script:fixtureInventory.Add($inventoryRow)
            if($phaseName -ceq 'B' -and @($inventoryRow.before.entries).Count -ne 0){
                throw 'Fixed Phase B fixture base already contains retained entries.'}
            if($phaseName -ceq 'C' -and ($null -eq $priorInventory -or
                -not (Test-HeadlessInventoryReconciled $priorInventory `
                    $inventoryRow.before @{trials=@()} $fixtureBase) -or
                @($inventoryRow.before.entries).Count -ne 7)){
                throw 'Phase C fixture base does not match completed Phase B inventory.'}
            $phaseFailure=$null;$controller=$null;$row=$null
            try {
                $proofLeaf="source-proof-before-$phaseName.json"
                $proofArguments="-NoLogo -NoProfile -NonInteractive -File `"$gitScript`" -Git `"$git`" -Root `"$script:headlessRoot`" -PinBase64 $pinLiteral -ProofLeaf $proofLeaf -ProofOnly"
                $proofRow=Invoke-HeadlessJob -Name "proof-before-$phaseName" -File $pwsh `
                    -Arguments $proofArguments -Work $script:headlessRoot -Seconds 15
                Assert-HeadlessClonePin $script:headlessRoot $proofLeaf $pin
                $proofRow.source_proof=New-HeadlessEvidence (Join-Path $script:headlessRoot $proofLeaf)
                Assert-HeadlessRootUnchanged $script:rootReceipt $script:headlessRoot
                $fixture=Join-Path $checkout ("scripts/tests/powershell/test-exact-manifest-txf-phase-$($phaseName.ToLowerInvariant()).ps1")
                $arguments="-NoLogo -NoProfile -NonInteractive -File `"$fixture`""
                $row=Invoke-HeadlessJob -Name "phase-$phaseName" -File $pwsh `
                    -Arguments $arguments -Work $checkout -Seconds ([int]$phase[2])
            }
            catch {$phaseFailure=Limit-HeadlessError $_.Exception.Message}
            if($null -eq $row){
                $matches=@($script:headlessRows.ToArray() | Where-Object { $_.name -ceq "phase-$phaseName" })
                if($matches.Count -eq 1){$row=$matches[0]}
            }
            Set-HeadlessPrimaryAttribution $inventoryRow $row
            try {$controller=Read-HeadlessController $row $phaseName $script:headlessRoot}
            catch {$phaseFailure=Limit-HeadlessError ("$phaseFailure; controller: $($_.Exception.Message)")}
            try {$inventoryRow.after=Get-HeadlessFixtureInventory $fixtureBase}
            catch {$inventoryRow.after_error=Limit-HeadlessError $_.Exception.Message}
            $inventoryRow.controller_observed=$null -ne $controller
            $inventoryRow.unattributed=@(Get-HeadlessUnattributed $inventoryRow.before $inventoryRow.after $controller)
            if($null -ne $inventoryRow.after -and $null -ne $controller){
                $inventoryRow.reconciled=Test-HeadlessInventoryReconciled `
                    $inventoryRow.before $inventoryRow.after $controller $fixtureBase}
            if($null -ne $phaseFailure -or $null -ne $inventoryRow.after_error -or
                -not $inventoryRow.reconciled -or $inventoryRow.unattributed.Count -ne 0 -or
                $null -eq $controller -or $controller.gate1 -cne 'unverified' -or
                $controller.error -or $controller.source.commit -cne $pin.head -or
                @($controller.trials).Count -ne $(if($phaseName -ceq 'B'){7}else{2})){
                $inventoryRow.failure=if($phaseFailure){$phaseFailure}else{'Phase fixture inventory or controller is incomplete.'}
                throw "Phase $phaseName diagnostic or exact fixture attribution is incomplete."}
            $priorInventory=$inventoryRow.after
        }
        $proofLeaf='source-proof-after-C.json'
        $proofArguments="-NoLogo -NoProfile -NonInteractive -File `"$gitScript`" -Git `"$git`" -Root `"$script:headlessRoot`" -PinBase64 $pinLiteral -ProofLeaf $proofLeaf -ProofOnly"
        $proofRow=Invoke-HeadlessJob -Name 'proof-after-C' -File $pwsh `
            -Arguments $proofArguments -Work $script:headlessRoot -Seconds 15
        Assert-HeadlessClonePin $script:headlessRoot $proofLeaf $pin
        $proofRow.source_proof=New-HeadlessEvidence (Join-Path $script:headlessRoot $proofLeaf)
    }
    $script:headlessOutcome='diagnostics-executed'
}
catch {
    if($pin -isnot [System.Collections.IDictionary]){
        $pin=@{schema=$null;vm_guid=$null;head=$null;tree=$null;guest=$null}}
    $script:headlessOutcome='failed-or-incomplete'
    $script:headlessFailure=[ordered]@{type=$_.Exception.GetType().FullName;
        message=Limit-HeadlessError $_.Exception.Message}
}
finally {
    try {if($null -ne $script:rootReceipt){
        Assert-HeadlessRootUnchanged $script:rootReceipt $script:headlessRoot}}
    catch {$script:headlessOutcome='failed-or-incomplete';
        $script:headlessFailure=[ordered]@{type=$_.Exception.GetType().FullName;
            message=Limit-HeadlessError $_.Exception.Message}}
    if($pin -isnot [System.Collections.IDictionary]){
        $pin=@{schema=$null;vm_guid=$null;head=$null;tree=$null;guest=$null}}
    $record=[ordered]@{schema='dark240-win11-headless-diagnostic-v1';
        utc=[DateTime]::UtcNow.ToString('o');vm_guid=if($pin.ContainsKey('vm_guid')){$pin['vm_guid']}else{$null};
        observed_vm_guid=$actualGuid;
        source_head=if($pin.ContainsKey('head')){$pin['head']}else{$null};
        source_tree=if($pin.ContainsKey('tree')){$pin['tree']}else{$null};
        nonce=if($private){$private.nonce}else{$null};
        retained_root=$script:headlessRoot;root_receipt=$script:rootReceipt;
        fixture_inventory=@($script:fixtureInventory.ToArray());
        guest_exec_outer_timeout_floor_seconds=780;outcome=$script:headlessOutcome;
        guest_terminal_record_cap_bytes=$script:maxTerminalRecordBytes;
        gate1='unverified';product=0;vm_campaign=0;
        trust=if($trust){$trust}else{$null};
        route=if($route){$route}else{$null};jobs=@($script:headlessRows.ToArray());
        failure=$script:headlessFailure;cleanup='retained; independently verified exact-root cleanup pending';
        host_capture_cap='unverified outside this guest payload'}
    $raw=0L
    foreach($row in $record.jobs){foreach($key in @('stdout','stderr','controller_result',
                'source_proof','route_record')){
        if($null -ne $row[$key]){$raw += [long]$row[$key].bytes}}}
    Write-Output (Write-HeadlessTerminal $record $raw)
}
Assert-HeadlessTerminalAccepted
