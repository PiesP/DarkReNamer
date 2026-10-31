function Get-DrMaintainedAuthorityDigest {
    param([string] $VmId, [string] $RunName, [object] $Roots)
    $fields = @('1', '4fb282cd357fca8f7eecc4c8d97fa803f1ca68be',
        '11ce058fdbb51614ac519fabe37fa587fde284fcba4e76ea5e423570243c494f',
        'e01797d6dfaa69f989565eb3afdbc2d2da4708b98c2e24ccbd4df1ce5fd3ced6',
        $VmId, 'gui-apply-feedback-v1-owned-r3-1366x768-96-text100-success-10000', $RunName)
    foreach ($role in @('guest', 'trusted')) {
        $row = $Roots.$role
        $fields += @($row.path, $row.base_file_id, $row.file_id,
            $row.owner_sid, $row.acl_sddl)
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $bytes = [Collections.Generic.List[byte]]::new()
    $bytes.AddRange([Text.Encoding]::ASCII.GetBytes("DarkReNamer-236-authority-v1`0"))
    foreach ($field in $fields) {
        if ($null -eq $field -or $field -isnot [string] -or $field.Contains([char]0)) {
            throw 'Original authority field is missing or contains NUL.'
        }
        $encoded = $utf8.GetBytes($field)
        if ($encoded.Length -gt 1MB) { throw 'Original authority field is oversized.' }
        $length = [BitConverter]::GetBytes([uint32]$encoded.Length)
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($length) }
        $bytes.AddRange($length)
        $bytes.AddRange($encoded)
    }
    [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes.ToArray())).ToLowerInvariant()
}

function Assert-DrMaintainedOriginalTarget {
    param([Parameter(Mandatory)][string] $OutputRoot)
    Assert-PathWithoutReparse $OutputRoot
    $expected = [ordered]@{
        'original-transport.json' = 'eae10bc051efaace0f2de7f4d25a4ea0a413adb44c4cd226e746b6226858312c'
        'owned-cleanup-strict-failure-preservation.json' = 'a02ae4237ca0c0b3887117ace9498c04fea788af07f6b4e53827dcc312ff6226'
        'acceptance-observations.json' = '23bf5c279af322de0cd270983b779c136c5a0bb1ba06f3df95fade456a106909'
        'acceptance-result.json' = 'bf0676ef3138163328070a7250b15472e4ab5f95c05015829965d0501a7f52c6'
        'bundle.json' = 'e01797d6dfaa69f989565eb3afdbc2d2da4708b98c2e24ccbd4df1ce5fd3ced6'
        'gui-apply-final.json' = '1a5af3bff459ecc2b83cc48fe9338623e755802a221d6699bb05402dae410071'
        'gui-apply-imported.png' = '7115bf204e1a8a3129e2c984145269f02cb1d977a93b59e4ad4a313d8a0048b8'
        'gui-apply-initial.json' = 'b7dc9713e3cf295693036f87a974c0583a14067ef7ce15efa95cbdefaa11d6a2'
        'owned-performance-input-manifest.json' = 'd58a0d99890bda888cbbbe48e5a782aaa94d5f3391ddffc932a9183335f239c0'
        'owned-performance-profile.json' = '11ce058fdbb51614ac519fabe37fa587fde284fcba4e76ea5e423570243c494f'
        'platform-postlaunch.json' = '3b3f424f19b93d572504ae9131e17eecaf0ceef966b290a415df13b1070918e8'
        'platform-preflight.json' = 'ded05932bc2b018b14d08a5c8ebd9a96459a23dc5e6c536d70c92fb656f6eaf7'
        'retained-guest-directory.txt' = 'c8c28c4b9e916c84d5b276c1b71d04c906cd1d1a2c5368b3b5d1f5fd78a2cf91'
        'owned-cleanup-desktop-closed.json' = '2f5efbd0c83e33fb08bb65cc6f5268a2345817c5641d213932b2d66505302049'
        'desktop-lease.json' = 'fb039b93500295bac05c6b15043cdf753083af57325d38e176c1f90c5736c145'
        'owned-performance-predelete.json' = '844a6d9441221e6d64ef4f50c54be74ba2d8da3beb11768ce1dd36eadcea58df'
        'desktop-stop-response.json' = '6406f08bf3ffbbeb7fd3a72e0cfa6b36d51b8a36d942c902e419033ca5209f3a'
    }
    $verified = @{}
    $total = [long]0
    foreach ($name in $expected.Keys) {
        $path = Join-Path $OutputRoot $name
        if ($name -ceq 'desktop-lease.json' -and -not (Test-Path -LiteralPath $path)) {
            $path = Join-Path (Split-Path -Parent $OutputRoot) $name
        }
        Assert-PathWithoutReparse $path
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -lt 1 -or $item.Length -gt 4MB) {
            throw 'The immutable retained target has a missing or unsafe original.'
        }
        $total += $item.Length
        if ($total -gt 16MB -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$name]) {
            throw 'The immutable retained target has a changed or oversized original.'
        }
        $verified[$name] = $path
    }
    $transport = Get-Content -LiteralPath $verified['original-transport.json'] -Raw |
        ConvertFrom-Json -ErrorAction Stop
    $preservation = Get-Content -LiteralPath $verified['owned-cleanup-strict-failure-preservation.json'] -Raw |
        ConvertFrom-Json -ErrorAction Stop
    $observations = Get-Content -LiteralPath $verified['acceptance-observations.json'] -Raw |
        ConvertFrom-Json -ErrorAction Stop
    $lease = Get-Content -LiteralPath $verified['desktop-lease.json'] -Raw |
        ConvertFrom-Json -ErrorAction Stop
    $signal = Get-Content -LiteralPath $verified['owned-cleanup-desktop-closed.json'] -Raw |
        ConvertFrom-Json -ErrorAction Stop
    $predelete = Get-Content -LiteralPath $verified['owned-performance-predelete.json'] -Raw |
        ConvertFrom-Json -ErrorAction Stop
    $run = [string]$preservation.run_name
    $vm = [string]$transport.vm_id
    $source = '4fb282cd357fca8f7eecc4c8d97fa803f1ca68be'
    $profile = '11ce058fdbb51614ac519fabe37fa587fde284fcba4e76ea5e423570243c494f'
    if ($run -cnotmatch '^DarkReNamerTests-[0-9a-f]{32}$' -or
        $vm -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        $transport.status -cne 'failed' -or $transport.guest_cleanup -ne $false -or
        $transport.owned_cleanup_failure_context.source_sha -cne $source -or
        $transport.owned_cleanup_failure_context.bundle.sha256 -cne $expected['bundle.json'] -or
        $transport.owned_cleanup_failure_context.output_preservation_verified -ne $true -or
        $preservation.kind -cne 'owned_cleanup_strict_failure_preservation' -or
        $preservation.run_name -cne $run -or $preservation.vm_id -cne $vm -or
        $preservation.profile_sha256 -cne $profile -or
        $preservation.original_transport.sha256 -cne $expected['original-transport.json'] -or
        $signal.preservation_sha256 -cne $expected['owned-cleanup-strict-failure-preservation.json'] -or
        $signal.desktop_lease_sha256 -cne $expected['desktop-lease.json'] -or
        $lease.stop_status -cne 'stopped' -or $lease.cleanup_observed -ne $true -or
        $observations.text_scale_restoration.snapshot_equal -ne $true -or
        $observations.text_scale_restoration.final.ui_settings_percent -ne 100 -or
        $predelete.kind -cne 'owned_performance_predelete_restoration' -or
        $predelete.run_name -cne $run -or $predelete.roots.guest.file_id -cne
            $preservation.root_records.guest.file_id -or
        $predelete.roots.trusted.file_id -cne $preservation.root_records.trusted.file_id -or
        (Get-DrMaintainedAuthorityDigest -VmId $vm -RunName $run `
            -Roots $preservation.root_records) -cne
            'c5ee37c55a8dc80020d0781de62b424148da968f36e2a9c0d6e35184e220129b' -or
        $transport.raw_cleanup.process_jobs_closed -ne $true -or
        $transport.raw_cleanup.scheduled_task_present -ne $false -or
        @($transport.raw_cleanup.owned_processes_after).Count -ne 0) {
        throw 'The immutable target does not prove original failure, restoration, or owned lifetimes.'
    }
    if (@($preservation.files).Count -ne 12 -or
        @($preservation.files | Where-Object {
            -not $expected.Contains($_.file) -or $_.sha256 -cne $expected[$_.file] -or
            $_.bytes -ne (Get-Item -LiteralPath $verified[$_.file]).Length
        }).Count -ne 0) {
        throw 'The original preserved output index is incomplete or inconsistent.'
    }
    $owned = $transport.raw_cleanup.owned_resource_evidence
    if ($owned.runner_sid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$' -or
        $owned.runner_session_id -le 0 -or
        $owned.task_execution.task_name -cne $run -or
        $owned.task_execution.observer_lifetime_absent -ne $true -or
        $owned.preflight_child.exact_lifetime_absent -ne $true -or
        $owned.engine_child.exact_lifetime_absent -ne $true) {
        throw 'Original declared runner lifetimes or task scope are incomplete.'
    }
    $declaredPids = @(
        @($owned.declared_processes | ForEach-Object { [int]$_.pid })
        [int]$owned.task_execution.observer_lifecycle.pid
        [int]$owned.preflight_child.pid
        [int]$owned.engine_child.pid
    )
    if ($declaredPids.Count -ne 4 -or @($declaredPids | Where-Object { $_ -le 0 }).Count -ne 0) {
        throw 'Original declared process identities are incomplete.'
    }
    [pscustomobject]@{
        vm_id = $vm
        run_name = $run
        roots = $preservation.root_records
        runner_sid = [string]$owned.runner_sid
        runner_session_id = [int]$owned.runner_session_id
        declared_pids = $declaredPids
    }
}

function Invoke-DrMaintainedRootProofCollection {
    [CmdletBinding(DefaultParameterSetName='Direct')]
    param(
        [Parameter(Mandatory)][string] $OriginalOutputRoot,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory, ParameterSetName='Direct')][string] $VmName,
        [Parameter(Mandatory, ParameterSetName='Direct')][guid] $ExpectedVmId,
        [Parameter(Mandatory, ParameterSetName='Direct')][string] $CredentialHelper,
        [Parameter(Mandatory, ParameterSetName='Ssh')]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z')][string] $SshHost,
        [Parameter(Mandatory)][guid] $ExpectedGuestVmId,
        [Parameter(Mandatory)][string] $EntryPointPath,
        [Parameter(Mandatory)][object] $VerifiedTooling
    )
    if ($ExpectedGuestVmId -eq [guid]::Empty) { throw 'Maintained disposition requires exact VM identity.' }
    $original = Assert-DrMaintainedOriginalTarget -OutputRoot $OriginalOutputRoot
    Assert-PathWithoutReparse $OutputRoot
    $output = Get-Item -LiteralPath $OutputRoot -Force -ErrorAction Stop
    if (-not $output.PSIsContainer -or
        ($output.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        @(Get-ChildItem -LiteralPath $OutputRoot -Force).Count -ne 0) {
        throw 'Maintained proof output must be a new empty ordinary directory.'
    }
    $expectedVm = $original.vm_id
    if ($ExpectedGuestVmId.ToString('D').ToLowerInvariant() -cne $expectedVm) {
        throw 'Maintained proof VM differs from the immutable failed run.'
    }
    $session = $null; $credential = $null; $mutex = $null; $mutexHeld = $false
    $nonce = [guid]::NewGuid().ToString('N')
    $receipt = [ordered]@{
        schema_version = 1; kind = 'maintained_retained_root_collection'
        operation_nonce = $nonce; original_transport_sha256 =
            'eae10bc051efaace0f2de7f4d25a4ea0a413adb44c4cd226e746b6226858312c'
        original_preservation_sha256 =
            'a02ae4237ca0c0b3887117ace9498c04fea788af07f6b4e53827dcc312ff6226'
        vm_id = $expectedVm; run_name = $original.run_name
        tooling_manifest_sha256 = [string]$VerifiedTooling.ManifestSha256
        status = 'incomplete'; observed_at_utc = [DateTime]::UtcNow.ToString('o')
        current = $null; errors = @()
    }
    try {
        if ($PSCmdlet.ParameterSetName -ceq 'Direct') {
            $vm = Resolve-DirectControllerVm -Name $VmName -ExpectedId $ExpectedVmId
            if ($vm.Id -ne $ExpectedGuestVmId -or $vm.State.ToString() -cne 'Running') {
                throw 'Maintained proof selected a different or stopped VM.'
            }
            $mutex = [Threading.Mutex]::new($false,('Local\DarkReNamerVmTests-' + $vm.Id))
            try { $mutexHeld = $mutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
            if (-not $mutexHeld) { throw 'Another VM controller is active.' }
            $credential = & $CredentialHelper -Action Load
            if ($credential -isnot [Management.Automation.PSCredential]) {
                throw 'Credential helper did not return a PSCredential.'
            }
            $session = New-DirectControllerSession -VmId $vm.Id -Credential $credential
        } else {
            $session = New-SshControllerSession -HostAlias $SshHost
        }
        $receipt.current = Invoke-Command -Session $session -ArgumentList @(
            $expectedVm,$nonce,$original,$script:DrOwnedRootGuardSource) -ScriptBlock {
            param($vmId,$operationNonce,$originalTarget,$guardSource)
            # Rebuild the source-pinned tuple inside the guest. Serialized host
            # target objects and caller-supplied VM parameters are not authority.
            $fields = @('1', '4fb282cd357fca8f7eecc4c8d97fa803f1ca68be',
                '11ce058fdbb51614ac519fabe37fa587fde284fcba4e76ea5e423570243c494f',
                'e01797d6dfaa69f989565eb3afdbc2d2da4708b98c2e24ccbd4df1ce5fd3ced6',
                [string]$originalTarget.vm_id,
                'gui-apply-feedback-v1-owned-r3-1366x768-96-text100-success-10000',
                [string]$originalTarget.run_name)
            $roots = $originalTarget.roots
            foreach ($role in @('guest', 'trusted')) {
                $record = $roots.$role
                $fields += @($record.path, $record.base_file_id, $record.file_id,
                    $record.owner_sid, $record.acl_sddl)
            }
            $utf8 = [Text.UTF8Encoding]::new($false, $true)
            $bytes = [Collections.Generic.List[byte]]::new()
            $bytes.AddRange([Text.Encoding]::ASCII.GetBytes("DarkReNamer-236-authority-v1`0"))
            foreach ($field in $fields) {
                if ($null -eq $field -or $field -isnot [string] -or $field.Contains([char]0)) {
                    throw 'Guest authority field is missing or contains NUL.'
                }
                $encoded = $utf8.GetBytes($field)
                if ($encoded.Length -gt 1MB) { throw 'Guest authority field is oversized.' }
                $length = [BitConverter]::GetBytes([uint32]$encoded.Length)
                if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($length) }
                $bytes.AddRange($length)
                $bytes.AddRange($encoded)
            }
            if ([Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($bytes.ToArray())).ToLowerInvariant() -cne
                'c5ee37c55a8dc80020d0781de62b424148da968f36e2a9c0d6e35184e220129b' -or
                $vmId -cne $originalTarget.vm_id) {
                throw 'Guest retained target authority differs from the source pin.'
            }
            $actualVm = ([guid](Get-ItemProperty -LiteralPath `
                'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' `
                -Name VirtualMachineId).VirtualMachineId).ToString('D').ToLowerInvariant()
            if ($actualVm -cne $vmId -or
                -not ([Security.Principal.WindowsPrincipal]::new(
                    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
                        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'Maintained proof VM or administrator identity differs.'
            }
            if (-not ('DarkReNamerVmOwnedRootGuard' -as [type])) {
                Add-Type -TypeDefinition $guardSource -ErrorAction Stop
            }
            $guards = @{}
            try {
                $observed = [ordered]@{}
                $remainingEntries = 20000
                $remainingBytes = [long](512MB)
                foreach ($role in @('guest','trusted')) {
                    $record = $roots.$role
                    $guard = [DarkReNamerVmOwnedRootGuard]::new([string]$record.path,$false)
                    $guards[$role] = $guard
                    $guard.Assert([string]$record.base_file_id,[string]$record.file_id)
                    $security = $guard.Security()
                    if ($security[0] -cne $record.owner_sid -or
                        $security[1] -cne $record.acl_sddl) {
                        throw 'Maintained root owner or ACL differs from its original.'
                    }
                    $index = @($guard.ContentIndex([int]$remainingEntries,[long]$remainingBytes))
                    $remainingEntries -= $index.Count
                    $indexedBytes = [long]0
                    foreach ($entry in $index) {
                        if ($entry['kind'] -ceq 'file') { $indexedBytes += [long]$entry['bytes'] }
                    }
                    $remainingBytes -= $indexedBytes
                    if ($remainingEntries -lt 0 -or $remainingBytes -lt 0) {
                        throw 'Maintained roots exceed their aggregate index allowance.'
                    }
                    $observed[$role] = [ordered]@{
                        path = $record.path; base_file_id = $guard.BaseId
                        file_id = $guard.RootId; owner_sid = $security[0]
                        acl_sddl = $security[1]; index = $index
                    }
                }
                $allProcesses = @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
                $processes = @($allProcesses | ForEach-Object {
                    $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction Stop
                    if ($owner.ReturnValue -ne 0 -or
                        [string]::IsNullOrWhiteSpace([string]$owner.Sid) -or
                        [string]::IsNullOrWhiteSpace([string]$_.CreationDate)) {
                        throw 'A current process owner or creation identity is incomplete.'
                    }
                    [ordered]@{ pid = [int]$_.ProcessId; creation_date = [string]$_.CreationDate
                        name = [string]$_.Name; executable_path = [string]$_.ExecutablePath
                        command_line = [string]$_.CommandLine; owner_sid = [string]$owner.Sid }
                })
                $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                if ($sid -cne $originalTarget.runner_sid) {
                    throw 'Current controller principal differs from original runner scope.'
                }
                $tasks = @(Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
                    $userId = [string]$_.Principal.UserId
                    $groupId = [string]$_.Principal.GroupId
                    if ([string]::IsNullOrWhiteSpace($userId) -and
                        [string]::IsNullOrWhiteSpace($groupId)) {
                        throw 'A current task principal is unavailable.'
                    }
                    $resolvedUserSid = ''
                    if (-not [string]::IsNullOrWhiteSpace($userId)) {
                        if ($userId -cmatch '^S-1-\d+(?:-\d+)+$') {
                            $resolvedUserSid = ([Security.Principal.SecurityIdentifier]::new($userId)).Value
                        } else {
                            $resolvedUserSid = ([Security.Principal.NTAccount]::new($userId).Translate(
                                [Security.Principal.SecurityIdentifier])).Value
                        }
                    }
                    $xml = [string](@(Export-ScheduledTask -TaskName $_.TaskName `
                        -TaskPath $_.TaskPath -ErrorAction Stop) -join "`n")
                    $bytes = [Text.Encoding]::UTF8.GetBytes($xml)
                    if ($bytes.Length -gt 1MB) {
                        throw 'A current task definition exceeds its bound.'
                    }
                    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                    [ordered]@{ identity = [string]$_.TaskPath + [string]$_.TaskName
                        principal_user_id = $userId
                        principal_group_id = $groupId
                        resolved_user_sid = $resolvedUserSid
                        definition_sha256 = $hash; definition_xml = [string]$xml }
                })
                $prefixes = @($roots.guest.path,$roots.trusted.path)
                $runName = [string]$originalTarget.run_name
                $owned = @($processes | Where-Object {
                    $text = $_.executable_path + "`n" + $_.command_line
                    $text.Contains($runName,[StringComparison]::OrdinalIgnoreCase) -or
                    $text.Contains($prefixes[0],[StringComparison]::OrdinalIgnoreCase) -or
                    $text.Contains($prefixes[1],[StringComparison]::OrdinalIgnoreCase)
                })
                $ownedTasks = @($tasks | Where-Object {
                    $_.identity.Contains($runName,[StringComparison]::OrdinalIgnoreCase) -or
                    $_.definition_xml.Contains($runName,[StringComparison]::OrdinalIgnoreCase) -or
                    $_.definition_xml.Contains($prefixes[0],[StringComparison]::OrdinalIgnoreCase) -or
                    $_.definition_xml.Contains($prefixes[1],[StringComparison]::OrdinalIgnoreCase)
                })
                $opaqueProcesses = @($processes | Where-Object {
                    [string]::IsNullOrWhiteSpace($_.executable_path) -or
                    [string]::IsNullOrWhiteSpace($_.command_line)
                })
                [ordered]@{ vm_id = $actualVm; operation_nonce = $operationNonce
                    principal_sid = $sid; principal_name = $account
                    roots = $observed; process_inventory_complete = $true
                    task_inventory_complete = $true; processes = $processes; tasks = $tasks
                    owned_processes = $owned; owned_tasks = $ownedTasks
                    opaque_processes = $opaqueProcesses
                    principal_task_map = @($tasks | Where-Object {
                        $_.resolved_user_sid -ceq $sid -or
                        -not [string]::IsNullOrWhiteSpace($_.principal_group_id)
                    } | ForEach-Object {
                        [ordered]@{ identity = $_.identity; definition_sha256 = $_.definition_sha256 }
                    }) }
            } finally {
                foreach ($guard in $guards.Values) { $guard.Dispose() }
            }
        }
        if (@($receipt.current.owned_processes).Count -ne 0 -or
            @($receipt.current.owned_tasks).Count -ne 0) {
            throw 'Original owned process or task reference still exists.'
        }
        if (@($receipt.current.processes | Where-Object {
            $original.declared_pids -contains $_.pid
        }).Count -ne 0) {
            throw 'A declared original owned process PID is still present or reused.'
        }
        $receipt.status = 'collected';
    } catch {
        $receipt.errors = @($_.Exception.Message)
    } finally {
        $errors = @(Close-DrControllerResources -Session $session -Credential $credential `
            -Mutex $mutex -MutexHeld $mutexHeld)
        if ($errors.Count -gt 0) {
            $receipt.errors += $errors
            $receipt.status = 'incomplete'
        }
        Write-DrControllerExclusiveJson -Path (Join-Path $OutputRoot 'maintained-root-collection.json') `
            -Value $receipt -MaximumBytes 16MB
    }
    if ($receipt.status -cne 'collected') {
        throw 'Maintained root collection is incomplete; inspect its retained receipt.'
    }
    $receipt
}
