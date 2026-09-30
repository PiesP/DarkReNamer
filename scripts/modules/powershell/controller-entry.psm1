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

function Get-DrControllerUiOutputInventory {
    param($root, $trustedRoot)
    $out = Join-Path $trustedRoot 'out'
    $rows = @(
        Get-ChildItem -LiteralPath $out -Force |
            Where-Object { $_.Name -notin @('acceptance-result.json','platform-postlaunch.json') }
    )
    $trustedResult = Join-Path $out 'acceptance-result.json'
    if (Test-Path -LiteralPath $trustedResult) {
        $rows += Get-Item -LiteralPath $trustedResult -Force
    }
    if ($rows.Count -gt 128) { throw 'Acceptance output file count exceeds its bound.' }
    $total = [long]0
    foreach ($row in $rows) {
        if ($row.PSIsContainer -or
            ($row.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $row.Length -gt 128MB) {
            throw 'Acceptance output contains an unsafe file.'
        }
        $total += $row.Length
        if ($total -gt 512MB) {
            throw 'Acceptance output exceeds its aggregate size bound.'
        }
    }
    # Validate the complete inventory before hashing any of its files.
    foreach ($row in $rows) {
        [pscustomobject]@{
            file = $row.Name; guest_path = $row.FullName; bytes = $row.Length
            sha256 = (Get-FileHash -LiteralPath $row.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}
function Get-DrControllerRecoveryOutputInventory {
    param($root, $trustedRoot, $recoveryEvidenceRootPath)
    $out = Join-Path $trustedRoot 'out'
    $evidenceLeaf = Split-Path -Leaf $recoveryEvidenceRootPath
    $trustedSummary = Join-Path $out 'recovery-summary.json'
    $evidenceRoots = @(
        [pscustomobject]@{ item = Get-Item -LiteralPath $recoveryEvidenceRootPath -Force; prefix = $evidenceLeaf + '/' },
        [pscustomobject]@{ item = Get-Item -LiteralPath (Join-Path $out 'private') -Force; prefix = 'private/' }
    )
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $rows = [Collections.Generic.List[object]]::new()
    $directoryCount = 0
    foreach ($rootRecord in $evidenceRoots) {
        if (($rootRecord.item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Recovery evidence root became a reparse point.'
        }
        $pending.Push($rootRecord.item)
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
                    $relative = $item.FullName.Substring($rootRecord.item.FullName.Length + 1).Replace('\', '/')
                    $file = $rootRecord.prefix + $relative
                    if ($file -cne ($evidenceLeaf + '/summary.json')) {
                        $rows.Add([pscustomobject]@{
                            item = $item
                            file = $file
                            guest_path = $item.FullName
                        })
                    }
                    if ($rows.Count -gt 256) {
                        throw 'Recovery output file count exceeds its bound.'
                    }
                }
            }
        }
    }
    if (Test-Path -LiteralPath $trustedSummary) {
        $summaryItem = Get-Item -LiteralPath $trustedSummary -Force
        $rows.Add([pscustomobject]@{
            item = $summaryItem
            file = $evidenceLeaf + '/summary.json'
            guest_path = $trustedSummary
        })
    }
    if ($rows.Count -gt 256) { throw 'Recovery output file count exceeds its bound.' }
    $total = [long]0
    foreach ($row in $rows) {
        if ($row.item.PSIsContainer -or ($row.item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $row.item.Length -gt 128MB) {
            throw 'Recovery output contains an unsafe file.'
        }
        $total += $row.item.Length
        if ($total -gt 512MB) {
            throw 'Recovery output exceeds its aggregate size bound.'
        }
    }
    # Validate the complete inventory before hashing any of its files.
    foreach ($row in $rows) {
        [pscustomobject]@{
            file = $row.file
            guest_path = $row.guest_path
            bytes = $row.item.Length
            sha256 = (Get-FileHash -LiteralPath $row.item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}

function Write-DrControllerExclusiveJson {
    param([Parameter(Mandatory)][string] $Path,[Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][int] $MaximumBytes)
    $bytes = [Text.UTF8Encoding]::new($false,$true).GetBytes(
        ($Value | ConvertTo-Json -Depth 24 -Compress) + "`n")
    if ($bytes.Length -gt $MaximumBytes) {
        throw 'Exclusive evidence JSON exceeds its byte bound; owned roots are retained.'
    }
    if (Test-Path -LiteralPath $Path) { throw 'Exclusive evidence path already exists.' }
    $temporary = $Path + '.new-' + [guid]::NewGuid().ToString('N')
    $stream = [IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    [IO.File]::Move($temporary,$Path)
}

function Get-DrControllerPreservedFiles {
    param([Parameter(Mandatory)][string] $Root)
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'External evidence root is not an ordinary directory.'
    }
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push($rootItem)
    $files = [Collections.Generic.List[object]]::new()
    $total = [long]0
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'External evidence contains a reparse entry.'
            }
            if ($item.PSIsContainer) { $pending.Push($item); continue }
            $relative = $item.FullName.Substring($rootItem.FullName.Length + 1).Replace('\','/')
            if ($relative -ceq 'desktop-lease.json') { continue }
            $total += $item.Length
            if ($files.Count -ge 1024 -or $total -gt 512MB) {
                throw 'External evidence inventory exceeds its bound.'
            }
            $files.Add([ordered]@{
                file = $relative
                bytes = [long]$item.Length
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
    }
    @($files.ToArray() | Sort-Object file)
}

function Remove-DrControllerProofRemotingMetadata {
    param([Parameter(Mandatory)] $Proof)
    # These are transport annotations added by PowerShell remoting, not proof fields.
    foreach ($name in @('PSComputerName','RunspaceId','PSShowComputerName')) {
        if ($Proof -is [Collections.IDictionary] -and $Proof.Contains($name)) {
            $Proof.Remove($name)
        }
        $Proof.PSObject.Properties.Remove($name)
    }
}

function Copy-DrControllerV2TaskBaseline {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Baseline)
    foreach ($record in $Baseline) {
        if ($null -eq $record) { throw 'V2 task baseline contains an unavailable record.' }
        # Preserve the original remoted rows in transport; only the v2 proof copy
        # excludes transport annotations. Unknown data properties remain rejectable.
        $copy = $record | ConvertTo-Json -Depth 16 -Compress | ConvertFrom-Json
        Remove-DrControllerProofRemotingMetadata -Proof $copy
        $copy
    }
}

function Invoke-DrControllerOwnedCleanupAfterFailure {
    param($Session,$TaskName,$RunnerSid,$SessionId,$ExpectedVmId,$Frozen,$Roots,$V2Evidence,$ProfileSha256)
    Invoke-Command -Session $Session -ArgumentList $TaskName,$RunnerSid,$SessionId,$ExpectedVmId,$Frozen,$Roots,$V2Evidence,$ProfileSha256 -ScriptBlock {
        param($name,$sid,$desktopSession,$expectedVmId,$frozen,$roots,$v2Evidence,$profileSha256)
        $v2 = $null -ne $v2Evidence
        $proof = [ordered]@{
            schema_version = if ($v2) { 2 } else { 1 }
            kind = 'owned_cleanup_after_strict_failure'
            run_name = $name
            vm_id = $null
            status = 'incomplete'
            pre = $null
            post = $null
            roots = [ordered]@{ guest = $roots.guest; trusted = $roots.trusted }
            observed_roots_before = $null
            observed_roots_after = $null
            errors = @()
        }
        if ($v2) {
            $proof['profile_id'] = 'vm-automated-v2-owned-resources'
            $proof['profile_sha256'] = [string]$profileSha256
        }
        $guestGuard = $null
        $trustedGuard = $null
        function Assert-SubsetInventory {
            param($Previous,$Current,$Type)
            $known = @{}
            foreach ($row in @($Previous)) {
                $identity = [string]$row.identity
                $binding = if ($Type -ceq 'process') { [string]$row.executable_path } else { [string]$row.definition_sha256 }
                if ([string]::IsNullOrWhiteSpace($identity) -or
                    [string]::IsNullOrWhiteSpace($binding) -or $known.ContainsKey($identity)) {
                    throw "Frozen $Type identity or binding is unavailable."
                }
                $known[$identity] = $binding
            }
            foreach ($row in @($Current)) {
                $identity = [string]$row.identity
                $binding = if ($Type -ceq 'process') { [string]$row.executable_path } else { [string]$row.definition_sha256 }
                if ([string]::IsNullOrWhiteSpace($identity) -or
                    [string]::IsNullOrWhiteSpace($binding) -or
                    -not $known.ContainsKey($identity) -or
                    $known[$identity] -cne $binding) {
                    throw "New or unknown $Type identity appeared after the frozen failure."
                }
            }
        }
        function Get-CurrentOwnedInventory {
            $processes = Get-DrVmRunnerProcesses -UserSid $sid -SessionId $desktopSession -IncludeExecutionScope:$v2
            $tasks = @(Get-DrVmRunnerTasks -UserSid $sid)
            $ownedTasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
                [string]$_.TaskName -ceq $name -and [string]$_.TaskPath -ceq '\'
            })
            $allProcesses = @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
            $prefixes = @(($roots.guest.path.TrimEnd('\')+'\'), ($roots.trusted.path.TrimEnd('\')+'\'))
            $ownedProcesses = @($allProcesses | Where-Object {
                $path = [string]$_.ExecutablePath
                $path.StartsWith($prefixes[0],[StringComparison]::OrdinalIgnoreCase) -or
                $path.StartsWith($prefixes[1],[StringComparison]::OrdinalIgnoreCase)
            } | ForEach-Object {
                [ordered]@{ pid = [int]$_.ProcessId; session_id = [int]$_.SessionId; executable_path = [string]$_.ExecutablePath }
            })
            [ordered]@{
                complete = [bool]$processes.complete
                processes = @($processes.processes)
                tasks = @($tasks)
                owned_processes = @($ownedProcesses)
                owned_tasks = @($ownedTasks | ForEach-Object { [string]$_.TaskPath+[string]$_.TaskName })
            }
        }
        function Assert-V2Inventory {
            param($Inventory,$Earlier)
            $expectedTasks = @{}
            foreach ($task in @($v2Evidence.baseline_tasks)) {
                if ($expectedTasks.ContainsKey([string]$task.identity)) { throw 'V2 baseline task repeats.' }
                $expectedTasks[[string]$task.identity] = [string]$task.definition_sha256
            }
            if (@($Inventory.tasks).Count -ne $expectedTasks.Count) {
                throw 'V2 task inventory changed from the baseline.'
            }
            foreach ($task in @($Inventory.tasks)) {
                if (-not $expectedTasks.ContainsKey([string]$task.identity) -or
                    $expectedTasks[[string]$task.identity] -cne [string]$task.definition_sha256) {
                    throw 'V2 task definition changed from the baseline.'
                }
            }
            $ownedPids = [Collections.Generic.HashSet[int]]::new()
            foreach ($row in @($v2Evidence.declared_processes)) { [void]$ownedPids.Add([int]$row.pid) }
            [void]$ownedPids.Add([int]$v2Evidence.preflight_child.pid)
            [void]$ownedPids.Add([int]$v2Evidence.engine_child.pid)
            [void]$ownedPids.Add([int]$v2Evidence.task_execution.observer_lifecycle.pid)
            foreach ($rescue in @($v2Evidence.rescue_executions)) {
                [void]$ownedPids.Add([int]$rescue.task_execution.observer_lifecycle.pid)
            }
            $known = @{}
            foreach ($row in @($Earlier.processes)) { $known[[int]$row.pid] = $row }
            foreach ($row in @($Inventory.processes)) {
                $scope = ([string]$row.executable_path + ' ' + [string]$row.command_line)
                if ($row.owner_sid -cne $sid -or [int]$row.session_id -ne $desktopSession -or
                    [string]::IsNullOrWhiteSpace([string]$row.identity) -or
                    [string]::IsNullOrWhiteSpace([string]$row.executable_path) -or
                    [string]::IsNullOrWhiteSpace([string]$row.command_line) -or
                    $scope.IndexOf($name,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $scope.IndexOf([string]$roots.guest.path,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $scope.IndexOf([string]$roots.trusted.path,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $ownedPids.Contains([int]$row.pid) -or $ownedPids.Contains([int]$row.parent_pid)) {
                    throw 'V2 process has unknown identity or protected execution scope.'
                }
                if ($known.ContainsKey([int]$row.pid) -and
                    ($known[[int]$row.pid].identity -cne $row.identity -or
                     $known[[int]$row.pid].executable_path -cne $row.executable_path -or
                     $known[[int]$row.pid].command_line -cne $row.command_line -or
                     $known[[int]$row.pid].parent_pid -ne $row.parent_pid)) {
                    throw 'V2 process PID was reused or its lifetime changed.'
                }
            }
        }
        try {
            if ($name -cnotmatch '^DarkReNamerTests-[0-9a-f]{32}$' -or
                $sid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$' -or
                $frozen.complete -isnot [bool] -or -not $frozen.complete -or
                @($frozen.owned_processes).Count -ne 0) {
                throw 'Frozen owned cleanup context is incomplete.'
            }
            $actualVmId = ([guid](Get-ItemProperty `
                -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' `
                -Name VirtualMachineId).VirtualMachineId).ToString('D').ToLowerInvariant()
            if ($actualVmId -cne $expectedVmId) { throw 'Owned cleanup VM identity changed.' }
            $proof.vm_id = $actualVmId
            $base = Join-Path $env:ProgramData 'DarkReNamerVmRuns'
            if ($roots.guest.path -cne (Join-Path $base $name) -or
                $roots.trusted.path -cne (Join-Path $base ($name+'-trusted')) -or
                $roots.guest.base_file_id -cne $roots.trusted.base_file_id) {
                throw 'Owned cleanup run or root path differs from creation.'
            }
            $pre = Get-CurrentOwnedInventory
            $proof.pre = $pre
            if (-not $pre.complete -or $pre.owned_processes.Count -ne 0 -or
                $pre.owned_tasks.Count -ne 0) {
                throw 'Owned process, job, task, or complete process inventory is unavailable.'
            }
            if ($v2) {
                if ($profileSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                    $v2Evidence.schema_version -ne 2 -or
                    $v2Evidence.run_name -cne $name -or
                    $v2Evidence.runner_sid -cne $sid -or
                    $v2Evidence.runner_session_id -ne $desktopSession -or
                    $v2Evidence.root_records.guest.file_id -cne $roots.guest.file_id -or
                    $v2Evidence.root_records.trusted.file_id -cne $roots.trusted.file_id) {
                    throw 'V2 frozen resource evidence differs from the cleanup target.'
                }
                Assert-V2Inventory -Inventory $frozen -Earlier $frozen
                Assert-V2Inventory -Inventory $pre -Earlier $frozen
            } else {
                Assert-SubsetInventory -Previous $frozen.processes -Current $pre.processes -Type process
                Assert-SubsetInventory -Previous $frozen.tasks -Current $pre.tasks -Type task
            }
            $guestGuard = [DarkReNamerVmOwnedRootGuard]::new($roots.guest.path)
            $trustedGuard = [DarkReNamerVmOwnedRootGuard]::new($roots.trusted.path)
            $beforeRoots = [ordered]@{}
            foreach ($pair in @(@($guestGuard,$roots.guest),@($trustedGuard,$roots.trusted))) {
                $guard = $pair[0]; $record = $pair[1]
                $guard.Assert([string]$record.base_file_id,[string]$record.file_id)
                $security = $guard.Security()
                $owner = $security[0]
                $sddl = $security[1]
                $role = if ($record.path -ceq $roots.guest.path) { 'guest' } else { 'trusted' }
                $beforeRoots[$role] = [ordered]@{
                    path = $record.path; base_file_id = $guard.BaseId
                    file_id = $guard.RootId; owner_sid = $owner; acl_sddl = $sddl
                    ordinary_directory = $true
                }
                if ($owner -cne $record.owner_sid -or $owner -cne 'S-1-5-32-544' -or
                    $sddl -cne $record.acl_sddl) {
                    throw 'Owned root owner or ACL changed since creation.'
                }
            }
            $proof.observed_roots_before = $beforeRoots
            $guestGuard.Delete()
            $trustedGuard.Delete()
        }
        catch { $proof.errors = @($_.Exception.Message) }
        finally {
            if ($null -ne $trustedGuard) { $trustedGuard.Dispose() }
            if ($null -ne $guestGuard) { $guestGuard.Dispose() }
        }
        try {
            $rootPresence = [DarkReNamerVmOwnedRootGuard]::ObserveRoots(
                (Join-Path $env:ProgramData 'DarkReNamerVmRuns'),
                [string]$roots.guest.base_file_id,$name,$name+'-trusted')
            $proof.observed_roots_after = [ordered]@{
                guest_present = [bool]$rootPresence[0]
                trusted_present = [bool]$rootPresence[1]
            }
            $proof.post = Get-CurrentOwnedInventory
            if ($proof.errors.Count -eq 0 -and $proof.post.complete -and
                $proof.post.owned_processes.Count -eq 0 -and
                $proof.post.owned_tasks.Count -eq 0 -and
                -not $proof.observed_roots_after.guest_present -and
                -not $proof.observed_roots_after.trusted_present) {
                if ($v2) {
                    Assert-V2Inventory -Inventory $proof.post -Earlier $frozen
                    Assert-V2Inventory -Inventory $proof.post -Earlier $pre
                } else {
                    Assert-SubsetInventory -Previous $frozen.processes -Current $proof.post.processes -Type process
                    Assert-SubsetInventory -Previous $frozen.tasks -Current $proof.post.tasks -Type task
                }
                $proof.status = 'owned-clean'
            }
        } catch { $proof.errors += $_.Exception.Message }
        [pscustomobject]$proof
    }
}

function Test-DrControllerCleanupObservation {
    param([AllowNull()][object] $Observation)

    try {
    if ($null -eq $Observation) { return $false }
    $raw = [pscustomobject]$Observation
    foreach ($field in @('scheduled_task_present', 'guest_root_present', 'trusted_task_root_present')) {
        $property = $raw.PSObject.Properties[$field]
        if ($null -eq $property -or $property.Value -isnot [bool] -or $property.Value) { return $false }
    }
    foreach ($field in @('process_jobs_closed', 'runner_process_inventory_complete')) {
        $property = $raw.PSObject.Properties[$field]
        if ($null -eq $property -or $property.Value -isnot [bool] -or -not $property.Value) { return $false }
    }
    foreach ($field in @(
        'unexpected_runner_tasks', 'unexpected_runner_tasks_after_intervention',
        'unexpected_runner_processes_after_intervention', 'unexpected_runner_tasks_after_delete',
        'unexpected_runner_processes_after_delete', 'removed_runner_tasks',
        'terminated_runner_processes', 'resource_cleanup_errors', 'owned_processes_after'
    )) {
        $property = $raw.PSObject.Properties[$field]
        if ($null -eq $property -or $null -eq $property.Value -or
            $property.Value -isnot [array] -or $property.Value.Count -ne 0) { return $false }
    }
    $processes = $raw.PSObject.Properties['unexpected_runner_processes']
    if ($null -eq $processes -or $null -eq $processes.Value -or
        $processes.Value -isnot [array]) { return $false }
    # Every class shares a complete, closed natural-exit receipt.
    $screen = $raw.PSObject.Properties['runner_process_natural_exit']
    if ($null -eq $screen -or $null -eq $screen.Value) { return $false }
    $receipt = [pscustomobject]$screen.Value
    foreach ($field in @('schema_version','process_class','native_exit','initial_native_observations',
        'status', 'candidate_identity', 'natural_exit_observed',
        'final_inventory_complete', 'final_runner_process_delta_identities',
        'final_runner_task_delta_identities')) {
        if ($null -eq $receipt.PSObject.Properties[$field]) { return $false }
    }
    if ($receipt.schema_version -ne 2 -or $receipt.initial_native_observations -isnot [array]) { return $false }
    if ($processes.Value.Count -eq 0) {
        return $receipt.status -ceq 'not-required' -and $null -eq $receipt.process_class -and
            $null -eq $receipt.native_exit -and $receipt.initial_native_observations.Count -eq 0
    }
    if ($receipt.process_class -ceq 'smart-screen') {
        if ($null -ne $receipt.native_exit -or $receipt.initial_native_observations.Count -ne 0) { return $false }
    } elseif ($receipt.process_class -ceq 'desktop-spotlight') {
        if ($receipt.initial_native_observations.Count -ne 1 -or $null -eq $receipt.native_exit) { return $false }
        $exit = $receipt.native_exit
        if ($null -eq $exit.pid -or $exit.pid -ne $receipt.broker.native_identity.pid -or $exit.wait_result -ne 0 -or $exit.times_succeeded -isnot [bool] -or -not $exit.times_succeeded -or
            $exit.exit_code_succeeded -isnot [bool] -or -not $exit.exit_code_succeeded -or
            $exit.handle_closed -isnot [bool] -or -not $exit.handle_closed -or
            $exit.times_win32_error -ne 0 -or $exit.exit_code_win32_error -ne 0 -or $exit.close_win32_error -ne 0 -or
            $null -eq $exit.exit_code -or $null -eq $exit.exit_filetime_100ns -or
            $exit.creation_filetime_100ns -cne $receipt.broker.native_identity.creation_filetime_100ns -or
            [long]$exit.exit_filetime_100ns -lt [long]$exit.creation_filetime_100ns) { return $false }
    } else { return $false }
    $processIdentity = $processes.Value[0].PSObject.Properties['identity']
    $processes.Value.Count -eq 1 -and $null -ne $processIdentity -and
        $processIdentity.Value -is [string] -and -not [string]::IsNullOrEmpty($processIdentity.Value) -and
        $receipt.status -ceq 'natural-exit' -and
        $processIdentity.Value -ceq $receipt.candidate_identity -and
        $receipt.natural_exit_observed -is [bool] -and $receipt.natural_exit_observed -and
        $receipt.final_inventory_complete -is [bool] -and $receipt.final_inventory_complete -and
        $receipt.final_runner_process_delta_identities -is [array] -and
        $receipt.final_runner_process_delta_identities.Count -eq 0 -and
        $receipt.final_runner_task_delta_identities -is [array] -and
        $receipt.final_runner_task_delta_identities.Count -eq 0
    } catch { return $false }
}

function Add-DrControllerLifecycleIdentity {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]] $Identities,
        [ValidateRange(0, 32)][int] $Depth = 0
    )

    if ($null -eq $Value) { return }
    if ($Depth -gt 32) { throw 'Observer result nesting exceeds its bound.' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        foreach ($item in $Value) {
            Add-DrControllerLifecycleIdentity -Value $item -Identities $Identities -Depth ($Depth + 1)
        }
        return
    }
    $properties = $Value.PSObject.Properties
    $lifecycleProperty = $properties['process_lifecycle']
    if ($null -ne $lifecycleProperty -and $null -ne $lifecycleProperty.Value) {
        $lifecycle = $lifecycleProperty.Value
        $pidValue = $lifecycle.pid
        $ticks = $lifecycle.start_time_utc_ticks
        if (($pidValue -isnot [int] -and $pidValue -isnot [long]) -or
            [long]$pidValue -lt 1 -or [long]$pidValue -gt 4294967295 -or
            $ticks -isnot [string] -or $ticks -cnotmatch '^[1-9][0-9]{0,18}$' -or
            [decimal]$ticks -gt 3155378975999999999) {
            throw 'A result process lifecycle has an invalid PID or creation time.'
        }
        $identity = ([long]$pidValue).ToString([Globalization.CultureInfo]::InvariantCulture) + '|' + $ticks
        [void]$Identities.Add($identity)
    }
    foreach ($property in $properties) {
        if ($property.Name -cne 'process_lifecycle') {
            Add-DrControllerLifecycleIdentity -Value $property.Value `
                -Identities $Identities -Depth ($Depth + 1)
        }
    }
}

function Get-DrControllerRecoveryProcessIdentities {
    param(
        [Parameter(Mandatory)][object] $Result,
        [Parameter(Mandatory)][string] $EvidenceRoot
    )

    $references = @()
    switch ([string]$Result.selected_mode) {
        'ProcessCrash' {
            $crash = $Result.PSObject.Properties['process_crash']
            $intent = $Result.PSObject.Properties['intent_only_candidate_discard']
            if ($null -eq $crash -or $null -eq $intent) { throw 'Recovery process references are missing.' }
            $references = @($crash.Value.processes)
            if ($intent.Value.status -ceq 'passed') {
                $references += @($intent.Value.processes)
            }
            elseif ($intent.Value.status -cne 'not-run' -or
                $intent.Value.reason -cne 'switch-not-selected') {
                throw 'Optional recovery intent evidence has an invalid status.'
            }
        }
        'WorkerCancellation' { $references = @($Result.worker_cancellation.processes) }
        'WorkerClose' { $references = @($Result.worker_close.processes) }
        default { throw 'Recovery process mode is unavailable.' }
    }
    if ($references.Count -lt 2 -or $references.Count -gt 14 -or $references.Count % 2 -ne 0) {
        throw 'Recovery process reference count is invalid.'
    }
    $privateEvidence = $Result.PSObject.Properties['private_evidence']
    if ($null -eq $privateEvidence -or
        $privateEvidence.Value.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        ($privateEvidence.Value.bytes -isnot [int] -and $privateEvidence.Value.bytes -isnot [long])) {
        throw 'Recovery private index reference is invalid.'
    }
    $privateRoot = Join-Path $EvidenceRoot 'private'
    Assert-PathWithoutReparse $privateRoot
    $indexFiles = @(Get-ChildItem -LiteralPath $privateRoot -Filter 'private-index.json' -File -Recurse -Force)
    $indexMatches = @($indexFiles | Where-Object {
        $_.Length -eq [long]$privateEvidence.Value.bytes -and
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -ieq $privateEvidence.Value.sha256
    })
    if ($indexMatches.Count -ne 1) { throw 'Recovery private index does not match its protected reference.' }
    Assert-PathWithoutReparse $indexMatches[0].FullName
    $index = Get-Content -LiteralPath $indexMatches[0].FullName -Raw | ConvertFrom-Json
    if ($index.classification -cne 'private-path-bearing-raw-recovery-evidence' -or
        @($index.files).Count -lt 1 -or @($index.files).Count -gt 240) {
        throw 'Recovery private index classification or size is invalid.'
    }
    $privateDirectory = Split-Path -Parent $indexMatches[0].FullName
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($offset = 0; $offset -lt $references.Count; $offset += 2) {
        $reference = $references[$offset]
        if ($reference.boundary -cne 'started' -or
            $reference.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            ($reference.bytes -isnot [int] -and $reference.bytes -isnot [long])) {
            throw 'Recovery process start reference is invalid.'
        }
        $members = @($index.files | Where-Object {
            $_.bytes -eq [long]$reference.bytes -and $_.sha256 -ceq $reference.sha256
        })
        if ($members.Count -ne 1) { throw 'Recovery process start is absent or ambiguous in its private index.' }
        $segments = @(Get-SafeEvidencePathSegments ([string]$members[0].file))
        $rawPath = $privateDirectory
        foreach ($segment in $segments) { $rawPath = Join-Path $rawPath $segment }
        Assert-PathWithoutReparse $rawPath
        $rawLength = (Get-Item -LiteralPath $rawPath -Force).Length
        $actualDigest = (Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($rawLength -ne [long]$reference.bytes -or $actualDigest -cne $reference.sha256) {
            throw 'Recovery process start bytes differ from their digest reference.'
        }
        $start = Get-Content -LiteralPath $rawPath -Raw | ConvertFrom-Json
        if ($start.boundary -cne 'started' -or $null -eq $start.binding) {
            throw 'Recovery process start document has the wrong boundary.'
        }
        $pidValue = $start.binding.pid
        $ticks = $start.binding.start_time_utc_ticks
        if (($pidValue -isnot [int] -and $pidValue -isnot [long]) -or
            [long]$pidValue -lt 1 -or [long]$pidValue -gt 4294967295 -or
            $ticks -isnot [string] -or $ticks -cnotmatch '^[1-9][0-9]{0,18}$' -or
            [decimal]$ticks -gt 3155378975999999999) {
            throw 'Recovery process start binding has an invalid identity.'
        }
        $identity = ([long]$pidValue).ToString([Globalization.CultureInfo]::InvariantCulture) + '|' + $ticks
        if (-not $identities.Add($identity)) { throw 'Recovery process start identity is duplicated.' }
    }
    return ,$identities
}

function Test-DrControllerOwnedCleanupFailureEligible {
    param([AllowNull()][object] $CleanupResult)

    if ($null -eq $CleanupResult) { return $false }
    $property = $CleanupResult.PSObject.Properties['owned_cleanup_after_strict_failure_eligible']
    if ($null -eq $property -or $property.Value -isnot [bool]) { return $false }
    return $property.Value
}

function Test-DrControllerProcessJobCleanupLedger {
    param(
        [Parameter(Mandatory)][object] $Result,
        [string] $RecoveryEvidenceRoot,
        [switch] $AllowEmpty
    )

    try {
    $ledgerProperty = $Result.PSObject.Properties['process_job_cleanup']
    if ($null -eq $ledgerProperty) { return $false }
    $rows = @($ledgerProperty.Value)
    if ($rows.Count -gt 64) { return $false }
    if ($rows.Count -eq 0) {
        if (-not $AllowEmpty) { return $false }
        $guiProperty = $Result.PSObject.Properties['gui']
        if ($null -eq $guiProperty -or $null -eq $guiProperty.Value) { return $false }
        $gui = $guiProperty.Value
        $errorDetailProperty = $gui.PSObject.Properties['error_detail']
        if ($gui.status -cne 'failed' -or
            $gui.job_cleanup -isnot [bool] -or -not $gui.job_cleanup -or
            $null -ne $gui.process_id -or
            $gui.PSObject.Properties.Name -ccontains 'process_lifecycle' -or
            $gui.failure_reason -cne 'gui_error' -or
            $null -eq $errorDetailProperty -or $null -eq $errorDetailProperty.Value) {
            return $false
        }
        $errorDetail = $errorDetailProperty.Value
        $errorFields = @($errorDetail.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        $expectedErrorFields = @('exception_type', 'message', 'native_error') | Sort-Object -CaseSensitive
        if (($errorFields -join "`n") -cne ($expectedErrorFields -join "`n") -or
            $errorDetail.exception_type -isnot [string] -or
            [string]::IsNullOrWhiteSpace($errorDetail.exception_type) -or
            $errorDetail.exception_type.Length -gt 256 -or
            $errorDetail.message -isnot [string] -or $errorDetail.message.Length -gt 1024 -or
            ($null -ne $errorDetail.native_error -and
                ($errorDetail.native_error -isnot [int] -and $errorDetail.native_error -isnot [long]))) {
            return $false
        }
        return $true
    }
    $expectedFields = @(
        'active_process_ids_at_stop', 'active_processes_at_close',
        'active_processes_at_primary_exit', 'active_processes_at_stop',
        'capture_complete', 'error', 'forced_termination', 'had_survivors',
        'job_closed', 'job_empty', 'pid', 'primary_process_active_at_stop',
        'process_start_time_utc_ticks', 'status', 'termination_exit_code',
        'total_processes_at_stop'
    )
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        if ($null -eq $row) { return $false }
        $fields = @($row.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        $expected = @($expectedFields | Sort-Object -CaseSensitive)
        if (($fields -join "`n") -cne ($expected -join "`n")) { return $false }
        if ($row.pid -isnot [int] -and $row.pid -isnot [long]) { return $false }
        if ([long]$row.pid -lt 1 -or [long]$row.pid -gt 4294967295 -or
            $row.process_start_time_utc_ticks -isnot [string] -or
            $row.process_start_time_utc_ticks -cnotmatch '^[1-9][0-9]{0,18}$' -or
            [decimal]$row.process_start_time_utc_ticks -gt 3155378975999999999) { return $false }
        $identity = ([long]$row.pid).ToString([Globalization.CultureInfo]::InvariantCulture) + '|' +
            $row.process_start_time_utc_ticks
        if (-not $identities.Add($identity)) { return $false }
        if ($row.status -cne 'clean' -or $row.job_empty -isnot [bool] -or -not $row.job_empty -or
            $row.job_closed -isnot [bool] -or -not $row.job_closed -or
            $row.capture_complete -isnot [bool] -or -not $row.capture_complete -or
            $row.had_survivors -isnot [bool] -or $row.had_survivors -or
            $row.forced_termination -isnot [bool] -or
            $row.error -ne $null -or
            $row.active_processes_at_close -isnot [int] -and $row.active_processes_at_close -isnot [long] -or
            [long]$row.active_processes_at_close -ne 0) { return $false }
        $activeIds = @()
        if ($null -ne $row.active_process_ids_at_stop) {
            $activeIds = @($row.active_process_ids_at_stop)
        }
        if ($activeIds.Count -gt 64) { return $false }
        foreach ($field in @('active_processes_at_primary_exit', 'active_processes_at_stop',
                             'total_processes_at_stop')) {
            $value = $row.$field
            if ($null -ne $value -and
                (($value -isnot [int] -and $value -isnot [long]) -or
                 [long]$value -lt 0 -or [long]$value -gt 4294967295)) { return $false }
        }
        foreach ($processId in $activeIds) {
            if (($processId -isnot [int] -and $processId -isnot [long]) -or
                [long]$processId -lt 1 -or [long]$processId -gt 4294967295) { return $false }
        }
        if ($null -ne $row.primary_process_active_at_stop) {
            if ($row.primary_process_active_at_stop -isnot [bool]) { return $false }
            if ($row.primary_process_active_at_stop) {
                if ($row.forced_termination -isnot [bool] -or -not $row.forced_termination -or
                    $row.active_processes_at_stop -isnot [int] -and $row.active_processes_at_stop -isnot [long] -or
                    [long]$row.active_processes_at_stop -ne 1 -or
                    $row.total_processes_at_stop -isnot [int] -and $row.total_processes_at_stop -isnot [long] -or
                    [long]$row.total_processes_at_stop -ne 1 -or
                    $activeIds.Count -ne 1 -or [long]$activeIds[0] -ne [long]$row.pid -or
                    $row.termination_exit_code -isnot [int] -and $row.termination_exit_code -isnot [long] -or
                    [long]$row.termination_exit_code -lt 2 -or
                    [long]$row.termination_exit_code -gt 2147483647 -or
                    [long]$row.termination_exit_code -eq 259) { return $false }
            }
            elseif ($row.forced_termination -or $row.termination_exit_code -ne $null) {
                return $false
            }
        }
        else {
            if ($row.forced_termination -or $row.termination_exit_code -ne $null) { return $false }
        }
    }
    $expectedIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if (-not [string]::IsNullOrWhiteSpace($RecoveryEvidenceRoot)) {
        $expectedIdentities = Get-DrControllerRecoveryProcessIdentities `
            -Result $Result -EvidenceRoot $RecoveryEvidenceRoot
    }
    else {
        Add-DrControllerLifecycleIdentity -Value $Result -Identities $expectedIdentities
    }
    if ($expectedIdentities.Count -lt 1 -or $expectedIdentities.Count -ne $identities.Count) {
        return $false
    }
    foreach ($identity in $expectedIdentities) {
        if (-not $identities.Contains($identity)) { return $false }
    }
    return $true
    }
    catch { return $false }
}

function Test-DrControllerPreservedOutputCleanupAuthorization {
    param(
        [Parameter(Mandatory)][ValidateSet('ui', 'recovery')][string] $Role,
        [Parameter(Mandatory)][object] $Result,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Inventory,
        [Parameter(Mandatory)][string] $OutputRoot,
        [Parameter(Mandatory)][string] $ObserverSha256,
        [string] $AcceptanceMode,
        [bool] $HighContrastRequested,
        [bool] $ProcessJobsClosed,
        [AllowNull()][object] $ObserverProcess,
        [AllowNull()][object] $PollFailure
    )

    try {
        if (-not $ProcessJobsClosed -or $null -ne $PollFailure -or
            $null -eq $ObserverProcess -or $ObserverProcess.state -cne 'exited' -or
            ($ObserverProcess.exit_code -isnot [int] -and
                $ObserverProcess.exit_code -isnot [long]) -or
            $Result.status -cnotin $(if ($Role -ceq 'ui') {
                @('review_required', 'failed', 'environment_blocked', 'unsupported', 'not_run')
            } else { @('passed', 'failed') }) -or
            $Result.failure_reason -cin @('execution_state_restore_failed', 'desktop_lock_release_failed')) {
            return $false
        }
        # Some observer finally blocks assign a later cleanup failure after an
        # execution-state restore failure. Those final reasons cannot prove restore.
        $ambiguousRestorationFailures = if ($Role -ceq 'recovery') {
            @('owned_process_cleanup_observation_failed', 'journal_cleanup_observation_failed',
                'process_job_cleanup_failed', 'runtime_cleanup_refused',
                'runtime_cleanup_observation_failed', 'candidate_export_cleanup_observation_failed')
        } else {
            @('runtime_cleanup_failed', 'raw_cleanup_failed', 'raw_cleanup_observation_failed')
        }
        if ($Result.failure_reason -cin $ambiguousRestorationFailures) { return $false }

        $summaryLeaf = if ($Role -ceq 'ui') { 'acceptance-result.json' } else { 'summary.json' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $summaryCount = 0
        $summaryPath = $null
        if ($Inventory.Count -eq 0 -or $Inventory.Count -gt 256) { return $false }
        foreach ($row in $Inventory) {
            if ($null -eq $row -or $row.file -isnot [string] -or
                $row.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                ($row.bytes -isnot [int] -and $row.bytes -isnot [long]) -or
                [long]$row.bytes -lt 0 -or -not $seen.Add($row.file)) { return $false }
            $segments = @(Get-SafeEvidencePathSegments $row.file)
            if ($segments.Count -eq 0) { return $false }
            if ($Role -ceq 'ui' -and $segments.Count -ne 1) { return $false }
            $path = $OutputRoot
            foreach ($segment in $segments) { $path = Join-Path $path $segment }
            if ($segments[-1] -ceq $summaryLeaf) {
                $summaryCount++
                $summaryPath = $path
            }
            Assert-PathWithoutReparse $path
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item.Length -ne [long]$row.bytes -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $row.sha256) {
                return $false
            }
        }
        if ($summaryCount -ne 1) { return $false }
        $copiedResult = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        if (($copiedResult | ConvertTo-Json -Depth 32 -Compress) -cne
            ($Result | ConvertTo-Json -Depth 32 -Compress)) { return $false }
        if ($Role -ceq 'recovery') { return $true }

        # A failed observer can still have changed desktop settings. The result status
        # alone cannot certify restoration; use the copied raw restore document.
        $sourceSha = if ($Result.schema_version -eq 2) {
            $Result.product.source_sha
        } else { $Result.source_sha }
        foreach ($kind in @(
            $(if ($HighContrastRequested) { 'high-contrast' }),
            $(if ($AcceptanceMode -ceq 'text-scale') { 'text-scale' })
        )) {
            if (-not $kind) { continue }
            $snapshotLeaf = $kind + '-snapshot.json'
            if ($kind -ceq 'high-contrast') { $snapshotLeaf = 'high-contrast-restore.json' }
            $rescueLeaf = $kind + '-rescue-result.json'
            if (-not $seen.Contains($snapshotLeaf)) { return $false }
            $snapshotPath = Join-Path $OutputRoot $snapshotLeaf
            $snapshotHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $reference = if ($kind -ceq 'high-contrast') {
                $Result.high_contrast.snapshot
            } else { $Result.text_scale.snapshot }
            if ($seen.Contains($rescueLeaf)) {
                $rescue = Get-Content -LiteralPath (Join-Path $OutputRoot $rescueLeaf) -Raw | ConvertFrom-Json
                if ($rescue.status -cne 'passed' -or $rescue.restoration_verified -isnot [bool] -or
                    -not $rescue.restoration_verified -or $rescue.source_sha -cne $sourceSha -or
                    $rescue.acceptance_script_sha256 -cne $ObserverSha256 -or
                    $rescue.snapshot_sha256 -cne $snapshotHash) { return $false }
            }
            elseif ($null -eq $reference -or $reference.file -cne $snapshotLeaf -or
                $reference.sha256 -cne $snapshotHash) { return $false }
            $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json
            $expectedSchema = if ($kind -ceq 'high-contrast') { 2 } else { 1 }
            $required = if ($kind -ceq 'high-contrast') { $false } else { $true }
            if ($snapshot.schema_version -ne $expectedSchema -or
                $snapshot.source_sha -cne $sourceSha -or
                $snapshot.acceptance_script_sha256 -cne $ObserverSha256 -or
                $snapshot.restoration_required -isnot [bool] -or
                $snapshot.restoration_required -ne $required -or
                $snapshot.restoration_verified -isnot [bool] -or
                -not $snapshot.restoration_verified -or $null -eq $snapshot.original -or
                $null -eq $snapshot.restored) { return $false }
            # Match the observer's established equality rules without modifying
            # the retained raw document. Null and empty Scheme are equivalent;
            # UISettings float samples have the observer's existing tolerance.
            $original = $snapshot.original | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $restored = $snapshot.restored | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            if ($kind -ceq 'high-contrast') {
                if (-not [string]::Equals([string]$original.scheme, [string]$restored.scheme,
                    [StringComparison]::Ordinal)) { return $false }
                $restored.scheme = $original.scheme
            } else {
                if (($original.ui_settings_raw_factor -isnot [double] -and
                        $original.ui_settings_raw_factor -isnot [long]) -or
                    ($restored.ui_settings_raw_factor -isnot [double] -and
                        $restored.ui_settings_raw_factor -isnot [long]) -or
                    -not ([Math]::Abs([double]$original.ui_settings_raw_factor -
                        [double]$restored.ui_settings_raw_factor) -lt 0.000001)) { return $false }
                $restored.ui_settings_raw_factor = $original.ui_settings_raw_factor
            }
            if (($original | ConvertTo-Json -Depth 20 -Compress) -cne
                ($restored | ConvertTo-Json -Depth 20 -Compress)) { return $false }
        }
        return $true
    } catch { return $false }
}

function ConvertFrom-DrControllerSpotlightPreflightJson {
    param([AllowNull()][AllowEmptyCollection()][object[]] $Values)

    if ($null -eq $Values -or $Values.Count -ne 1 -or
        $Values[0] -isnot [string] -or [string]::IsNullOrWhiteSpace($Values[0])) {
        throw 'Registration preflight must return one nonempty JSON string.'
    }
    $text = [string]$Values[0]
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    if ($text.Length -gt 65536 -or $utf8.GetByteCount($text) -gt 65536) {
        throw 'Registration preflight exceeds 65536 UTF-8 bytes.'
    }
    try { $record = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    catch { throw 'Registration preflight returned invalid JSON.' }
    if ($null -eq $record) {
        if ($text.Trim() -cne 'null') { throw 'Registration preflight requires a JSON object or null.' }
        return $null
    }
    if ($record -isnot [pscustomobject] -or -not $text.TrimStart().StartsWith('{')) {
        throw 'Registration preflight requires a JSON object or null.'
    }
    # Preserve every data field; the independent verifier enforces closed keys.
    $record
}

function Complete-DrControllerV2TaskExecution {
    param($Session,$TaskName,$RunnerSid,$SessionId,$Engine,$CompletedTicks,$TaskResult,$Result)
    $lifecycle = $Result.observer_lifecycle
    if ($null -eq $Engine -or $null -eq $lifecycle -or
        $lifecycle.pid -isnot [long] -or $lifecycle.pid -le 0 -or
        $lifecycle.pid -gt [uint32]::MaxValue -or
        $lifecycle.start_time_utc_ticks -isnot [string] -or
        $lifecycle.start_time_utc_ticks -cnotmatch '^[1-9][0-9]{0,18}$' -or
        $lifecycle.session_id -ne $SessionId -or
        $lifecycle.owner_sid -cne $RunnerSid -or
        $lifecycle.image_path -isnot [string] -or
        $lifecycle.image_path -ine $Engine.action_executable -or
        $lifecycle.command_line -isnot [string] -or
        $lifecycle.command_line.Length -gt 4096 -or
        -not $lifecycle.command_line.Contains($TaskName) -or
        -not $lifecycle.command_line.Contains('-AcceptanceProfileId vm-automated-v2-owned-resources') -or
        $CompletedTicks -le $Engine.registered_last_run_time_ticks) {
        throw 'The v2 observer did not bind its original process lifetime to the task action.'
    }
    # The process reports pwsh.dll and may omit optional path quotes. Decode both
    # sides on the authenticated guest with its existing native Windows parser.
    $actionBound = Invoke-Command -Session $Session -ArgumentList `
        $lifecycle.command_line, $Engine.action_executable, $Engine.action_arguments -ScriptBlock {
        param($commandLine,$actionExecutable,$actionArguments)
        $observed = [string[]](Get-DrVmCommandLineArguments -CommandLine $commandLine)
        $registered = [string[]](Get-DrVmCommandLineArguments -CommandLine ('task.exe ' + $actionArguments))
        if ($observed.Count -lt 2 -or $observed.Count -ne $registered.Count) { return $false }
        $siblingDll = [IO.Path]::ChangeExtension($actionExecutable, '.dll')
        if (-not [string]::Equals($observed[0],$actionExecutable,[StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::Equals($observed[0],$siblingDll,[StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        for ($index = 1; $index -lt $observed.Count; $index++) {
            if (-not [string]::Equals($observed[$index],$registered[$index],
                [StringComparison]::Ordinal)) { return $false }
        }
        return $true
    }
    if ($actionBound -isnot [bool] -or -not $actionBound) {
        throw 'The v2 observer did not bind its original process lifetime to the task action.'
    }
    $absent = Invoke-Command -Session $Session -ArgumentList ([int]$lifecycle.pid) -ScriptBlock {
        param($processId)
        @(Get-CimInstance Win32_Process -Filter "ProcessId=$processId" `
            -OperationTimeoutSec 5 -ErrorAction Stop).Count -eq 0
    }
    if ($absent -isnot [bool] -or -not $absent) {
        throw 'The exact v2 observer PID remains or was reused after task termination.'
    }
    [ordered]@{
        task_name = $TaskName
        terminal = $true
        exit_code = [long]$TaskResult
        registered_last_run_time_ticks = [long]$Engine.registered_last_run_time_ticks
        completed_last_run_time_ticks = [long]$CompletedTicks
        action_executable = [string]$Engine.action_executable
        action_arguments = [string]$Engine.action_arguments
        observer_lifecycle = $lifecycle
        observer_lifetime_absent = $true
    }
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
    [string] $RuntimeBrokerDiagnosticRoot,
    [ValidatePattern('^[0-9a-f]{32}\z')][string] $RuntimeBrokerDiagnosticRunId,
    [ValidateRange(1, 900)][int] $RuntimeBrokerDiagnosticBudgetSeconds,
    [switch] $RuntimeBrokerPreparationOnly,
    [guid] $ExpectedGuestVmId = [guid]::Empty,
    [ValidatePattern('^[0-9a-f]{64}\z')][string] $ExpectedBundleManifestSha256,
    [ValidateSet('vm-automated-v1-win11-ntfs', 'vm-automated-v2-owned-resources')]
    [string] $AcceptanceProfileId = 'vm-automated-v1-win11-ntfs',
    [ValidatePattern('^[0-9a-f]{64}\z')][string] $AcceptanceProfileSha256,
    [Parameter(Mandatory)][string] $EntryPointPath,
    [Parameter(Mandatory)][object] $VerifiedTooling
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$coreResultMaximumBytes = 4MB
$coreTestChannelMaximumBytes = 4MB
$coreTestOutputAggregateMaximumBytes = 64MB
$coreOutputFileMaximumBytes = 128MB
$coreOutputAggregateMaximumBytes = 256MB


if ($AcceptanceProfileId -cnotin @('vm-automated-v1-win11-ntfs', 'vm-automated-v2-owned-resources')) {
    throw 'Unsupported VM acceptance profile identity.'
}
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

$ownedV2 = $AcceptanceProfileId -ceq 'vm-automated-v2-owned-resources'
$v2Engine = $null
$engineChild = $null
if ($ownedV2 -and -not $PSBoundParameters.ContainsKey('AcceptanceProfileSha256')) {
    throw 'V2 cleanup requires the launcher-frozen profile digest.'
}
if (-not $ownedV2 -and $PSBoundParameters.ContainsKey('AcceptanceProfileSha256')) {
    throw 'V1 cleanup does not accept a v2 profile digest.'
}
$transportKind = if ($PSCmdlet.ParameterSetName -eq 'Ssh') { 'ssh' } else { 'powershell_direct' }
$runtimeBrokerEnabled = Test-DrRuntimeBrokerDiagnosticArguments -Root $RuntimeBrokerDiagnosticRoot `
    -RunId $RuntimeBrokerDiagnosticRunId -PreparationOnly ([bool]$RuntimeBrokerPreparationOnly) `
    -TransportKind $transportKind -TaskKind $taskSelection.kind -Mode $AcceptanceMode `
    -VmId $ExpectedGuestVmId -RunnerSid $ExpectedDesktopSid -BudgetSeconds $RuntimeBrokerDiagnosticBudgetSeconds
$runtimeBrokerClock = [Diagnostics.Stopwatch]::StartNew()
$runtimeBrokerPrepared = $false
$runtimeBrokerErrors = [Collections.Generic.List[string]]::new()
function Write-DrDiagnosticPhase {
    param([string] $Phase, [string] $State='observed', [hashtable] $Details=@{})
    if (-not $runtimeBrokerEnabled -or $null -eq $session) { return }
    try {
        Invoke-Command -Session $session -ArgumentList $Phase,$State,$Details -ScriptBlock {
            param($phase,$state,$details)
            Write-DrRuntimeBrokerControllerPhase -Phase $phase -State $state -Details $details
        }
    } catch {
        if ($runtimeBrokerErrors.Count -lt 32) { $runtimeBrokerErrors.Add($Phase + ': ' + $_.Exception.GetType().Name) }
    }
}
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
$trustedTaskRoot = $null
$taskName = 'DarkReNamerTests-' + [guid]::NewGuid().ToString('N')
$runnerTaskBaseline = @()
$runnerProcessBaseline = @()
$spotlightPreflight = $null
$preflightChild = $null
$taskExecution = $null
$script:DrVmV2RescueExecutions = [Collections.Generic.List[object]]::new()
$script:DrVmV2RescueAttempts = 0
$result = $null
$processJobsClosed = $false
$acceptancePassed = $false
$outputPreservedForCleanup = $false
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
$originalTransportFrozen = $false
$cleanupResult = $null


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
    if ($runtimeBrokerEnabled) {
        Initialize-DrRuntimeBrokerControllerDiagnostic -Session $session -Root $RuntimeBrokerDiagnosticRoot `
            -RunId $RuntimeBrokerDiagnosticRunId -RunnerSid $desktop.sid -VmId $ExpectedGuestVmId
        Write-DrDiagnosticPhase -Phase 'desktop-session-bound' -Details @{ session_id=[int]$desktop.session_id; runner_sid=[string]$desktop.sid }
    }
    $workspaceRoots = Invoke-Command -Session $session -ArgumentList $taskName,$desktop.sid -ScriptBlock {
        param($name,$runnerSid)
        if ($name -cnotmatch '^DarkReNamerTests-[0-9a-f]{32}$' -or
            $runnerSid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$') {
            throw 'The VM workspace identity is invalid.'
        }
        if (-not ('DarkReNamerVmOwnedRootGuard' -as [type])) {
            Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class DarkReNamerVmOwnedRootGuard : IDisposable {
    const uint READ_ATTRIBUTES = 0x80, LIST_DIRECTORY = 1, READ_CONTROL = 0x20000;
    const uint DELETE = 0x10000, SYNCHRONIZE = 0x100000;
    const uint SHARE_READ = 1, OPEN_EXISTING = 3, FILE_OPEN = 1;
    const uint BACKUP_SEMANTICS = 0x02000000, OPEN_REPARSE_POINT = 0x00200000;
    const uint FILE_OPEN_REPARSE_POINT = 0x00200000, FILE_SYNCHRONOUS_IO_NONALERT = 0x20;
    const uint OBJ_CASE_INSENSITIVE = 0x40, OBJ_DONT_REPARSE = 0x1000;
    const int FILE_ATTRIBUTE_DIRECTORY = 0x10, FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
    const int FILE_ID_INFO = 18, FILE_ATTRIBUTE_TAG_INFO = 9, FILE_DISPOSITION_INFO = 4;
    const int FILE_ID_EXTD_DIRECTORY_INFO = 19, FILE_ID_EXTD_DIRECTORY_RESTART_INFO = 20;
    readonly List<SafeFileHandle> chain = new List<SafeFileHandle>();
    int nodes, enumerated;
    public string BaseId { get; private set; }
    public string RootId { get; private set; }

    [StructLayout(LayoutKind.Sequential)] struct UnicodeString {
        public ushort Length, MaximumLength;
        public IntPtr Buffer;
    }
    [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes {
        public uint Length;
        public IntPtr RootDirectory, ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor, SecurityQualityOfService;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoStatusBlock {
        public IntPtr Status, Information;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr templateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int info,
        byte[] buffer, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file, int info,
        byte[] buffer, uint size);
    [DllImport("ntdll.dll")]
    static extern int NtCreateFile(out SafeFileHandle file, uint access,
        ref ObjectAttributes attributes, out IoStatusBlock status, IntPtr allocation,
        uint fileAttributes, uint share, uint disposition, uint options,
        IntPtr ea, uint eaLength);
    [DllImport("advapi32.dll")]
    static extern uint GetSecurityInfo(SafeFileHandle file, int objectType, uint requested,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl,
        out IntPtr descriptor);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
        IntPtr descriptor, uint revision, uint requested, out IntPtr text, out uint length);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr text);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);

    static SafeFileHandle OpenDrive(string name) {
        SafeFileHandle result = CreateFileW(name,
            READ_ATTRIBUTES | LIST_DIRECTORY | READ_CONTROL | SYNCHRONIZE,
            SHARE_READ, IntPtr.Zero, OPEN_EXISTING,
            BACKUP_SEMANTICS | OPEN_REPARSE_POINT, IntPtr.Zero);
        if (result.IsInvalid) {
            int error = Marshal.GetLastWin32Error(); result.Dispose();
            throw new Win32Exception(error, "Owned cleanup handle could not be opened.");
        }
        return result;
    }
    static SafeFileHandle OpenRelative(SafeFileHandle parent, string name, bool delete) {
        if (name.Length == 0 || name.Length > 255 || name == "." || name == ".." ||
            name.IndexOfAny(new char[] {'\\', '/', ':', '\0'}) >= 0)
            throw new InvalidOperationException("Owned cleanup encountered an unsafe relative name.");
        IntPtr characters = IntPtr.Zero, unicode = IntPtr.Zero;
        try {
            characters = Marshal.StringToHGlobalUni(name);
            UnicodeString value = new UnicodeString();
            value.Length = checked((ushort)(name.Length * 2));
            value.MaximumLength = checked((ushort)((name.Length + 1) * 2));
            value.Buffer = characters;
            unicode = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
            Marshal.StructureToPtr(value, unicode, false);
            ObjectAttributes attributes = new ObjectAttributes();
            attributes.Length = (uint)Marshal.SizeOf(typeof(ObjectAttributes));
            attributes.RootDirectory = parent.DangerousGetHandle();
            attributes.ObjectName = unicode;
            attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
            IoStatusBlock status;
            SafeFileHandle result;
            int code = NtCreateFile(out result,
                READ_ATTRIBUTES | LIST_DIRECTORY | READ_CONTROL | SYNCHRONIZE | (delete ? DELETE : 0),
                ref attributes, out status, IntPtr.Zero, 0, SHARE_READ, FILE_OPEN,
                FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
                IntPtr.Zero, 0);
            if (code != 0 || result == null || result.IsInvalid) {
                if (result != null) result.Dispose();
                throw new InvalidOperationException("Relative owned cleanup open failed: NTSTATUS " +
                    ((uint)code).ToString("x8"));
            }
            return result;
        }
        finally {
            if (unicode != IntPtr.Zero) Marshal.FreeHGlobal(unicode);
            if (characters != IntPtr.Zero) Marshal.FreeHGlobal(characters);
        }
    }
    static byte[] Info(SafeFileHandle file, int kind, int size) {
        byte[] data = new byte[size];
        if (!GetFileInformationByHandleEx(file, kind, data, (uint)size))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return data;
    }
    static int Attributes(SafeFileHandle file) {
        return BitConverter.ToInt32(Info(file, FILE_ATTRIBUTE_TAG_INFO, 8), 0);
    }
    static string Identity(SafeFileHandle file) {
        return BitConverter.ToString(Info(file, FILE_ID_INFO, 24)).Replace("-", "").ToLowerInvariant();
    }
    static void Ordinary(SafeFileHandle file, bool directory) {
        int attributes = Attributes(file);
        if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
            ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory)
            throw new InvalidOperationException("Owned cleanup encountered a reparse or changed entry kind.");
    }
    public string[] Security() {
        IntPtr owner, group, dacl, sacl, descriptor;
        uint error = GetSecurityInfo(chain[chain.Count - 1], 1, 7,
            out owner, out group, out dacl, out sacl, out descriptor);
        if (error != 0) throw new Win32Exception((int)error, "Held root security query failed.");
        IntPtr ownerText = IntPtr.Zero, sddlText = IntPtr.Zero;
        try {
            uint length;
            if (!ConvertSidToStringSidW(owner, out ownerText) ||
                !ConvertSecurityDescriptorToStringSecurityDescriptorW(
                    descriptor, 1, 7, out sddlText, out length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Held root descriptor conversion failed.");
            return new string[] { Marshal.PtrToStringUni(ownerText), Marshal.PtrToStringUni(sddlText) };
        }
        finally {
            if (ownerText != IntPtr.Zero) LocalFree(ownerText);
            if (sddlText != IntPtr.Zero) LocalFree(sddlText);
            if (descriptor != IntPtr.Zero) LocalFree(descriptor);
        }
    }
    sealed class ChildEntry {
        public string Name;
        public string Id;
        public int Attributes;
    }
    static List<ChildEntry> Names(SafeFileHandle directory, int maximumEntries) {
        Ordinary(directory, true);
        List<ChildEntry> names = new List<ChildEntry>();
        byte[] buffer = new byte[65536];
        bool first = true;
        while (true) {
            Array.Clear(buffer, 0, buffer.Length);
            if (!GetFileInformationByHandleEx(directory,
                    first ? FILE_ID_EXTD_DIRECTORY_RESTART_INFO : FILE_ID_EXTD_DIRECTORY_INFO,
                    buffer, (uint)buffer.Length)) {
                int error = Marshal.GetLastWin32Error();
                if (error == 18) break; // ERROR_NO_MORE_FILES
                throw new Win32Exception(error, "Held directory enumeration failed.");
            }
            first = false;
            int offset = 0;
            while (true) {
                if (offset > buffer.Length - 88)
                    throw new InvalidOperationException("Held directory enumeration returned an invalid frame.");
                uint next = BitConverter.ToUInt32(buffer, offset);
                uint byteLength = BitConverter.ToUInt32(buffer, offset + 60);
                if (byteLength == 0 || (byteLength & 1) != 0 ||
                    byteLength > buffer.Length - offset - 88 ||
                    (next != 0 && (next < 88 + byteLength || next > buffer.Length - offset)))
                    throw new InvalidOperationException("Held directory name length is invalid.");
                char[] units = new char[byteLength / 2];
                Buffer.BlockCopy(buffer, offset + 88, units, 0, (int)byteLength);
                string name = new string(units);
                if (name != "." && name != "..") {
                    if (names.Count >= maximumEntries || name.Length > 255 ||
                        name.IndexOfAny(new char[] {'\\', '/', ':', '\0'}) >= 0)
                        throw new InvalidOperationException("Held directory contains an unsafe or oversized entry.");
                    byte[] identifier = new byte[16];
                    Buffer.BlockCopy(buffer, offset + 72, identifier, 0, 16);
                    if (Array.TrueForAll(identifier, value => value == 0))
                        throw new InvalidOperationException("Held directory did not report a child file identity.");
                    names.Add(new ChildEntry {
                        Name = name,
                        Id = BitConverter.ToString(identifier).Replace("-", "").ToLowerInvariant(),
                        Attributes = BitConverter.ToInt32(buffer, offset + 56)
                    });
                }
                if (next == 0) break;
                offset += (int)next;
            }
        }
        return names;
    }
    public static bool[] ObserveRoots(string basePath, string expectedBaseId,
        string guestName, string trustedName) {
        string path = Path.GetFullPath(basePath);
        string drive = Path.GetPathRoot(path);
        if (drive == null || drive.Length != 3 ||
            !path.EndsWith("\\DarkReNamerVmRuns", StringComparison.Ordinal) ||
            guestName.Length == 0 || trustedName.Length == 0)
            throw new InvalidOperationException("Owned cleanup post-observation base is invalid.");
        string[] parts = path.Substring(drive.Length).Split(Path.DirectorySeparatorChar);
        List<SafeFileHandle> handles = new List<SafeFileHandle>();
        try {
            handles.Add(OpenDrive(drive));
            Ordinary(handles[0], true);
            foreach (string part in parts) {
                SafeFileHandle child = OpenRelative(handles[handles.Count - 1], part, false);
                try { Ordinary(child, true); handles.Add(child); }
                catch { child.Dispose(); throw; }
            }
            SafeFileHandle parent = handles[handles.Count - 1];
            if (Identity(parent) != expectedBaseId)
                throw new InvalidOperationException("Owned cleanup base changed after disposition.");
            bool guest = false, trusted = false;
            foreach (ChildEntry child in Names(parent, 20000)) {
                if (String.Equals(child.Name, guestName, StringComparison.OrdinalIgnoreCase)) guest = true;
                if (String.Equals(child.Name, trustedName, StringComparison.OrdinalIgnoreCase)) trusted = true;
            }
            return new bool[] { guest, trusted };
        }
        finally {
            for (int index = handles.Count - 1; index >= 0; --index) handles[index].Dispose();
        }
    }
    public DarkReNamerVmOwnedRootGuard(string root) {
        string path = Path.GetFullPath(root);
        string drive = Path.GetPathRoot(path);
        if (drive == null || drive.Length != 3 || path.Length <= drive.Length)
            throw new InvalidOperationException("Owned cleanup root must be drive absolute.");
        string[] parts = path.Substring(drive.Length).Split(Path.DirectorySeparatorChar);
        if (parts.Length < 3 || parts[parts.Length - 2] != "DarkReNamerVmRuns")
            throw new InvalidOperationException("Owned cleanup path is outside its exact base.");
        try {
            chain.Add(OpenDrive(drive));
            Ordinary(chain[0], true);
            foreach (string part in parts) {
                if (part.Length == 0 || part == "." || part == "..")
                    throw new InvalidOperationException("Owned cleanup path contains an alias.");
                SafeFileHandle handle = OpenRelative(chain[chain.Count - 1], part,
                    part == parts[parts.Length - 1]);
                try { Ordinary(handle, true); chain.Add(handle); }
                catch { handle.Dispose(); throw; }
                if (part == "DarkReNamerVmRuns") BaseId = Identity(handle);
            }
            if (BaseId == null) throw new InvalidOperationException("Owned cleanup base is unavailable.");
            RootId = Identity(chain[chain.Count - 1]);
        } catch { Dispose(); throw; }
    }
    public void Assert(string expectedBaseId, string expectedRootId) {
        if (BaseId != expectedBaseId || RootId != expectedRootId ||
            Identity(chain[chain.Count - 2]) != expectedBaseId ||
            Identity(chain[chain.Count - 1]) != expectedRootId)
            throw new InvalidOperationException("Owned cleanup root or base identity changed.");
    }
    List<ChildEntry> Children(SafeFileHandle directory) {
        List<ChildEntry> entries = Names(directory, 20000 - enumerated);
        enumerated += entries.Count;
        return entries;
    }
    void DeleteEntry(SafeFileHandle parent, ChildEntry child, int depth) {
        if (depth > 64 || ++nodes > 20000)
            throw new InvalidOperationException("Owned cleanup tree exceeds its bound.");
        using (SafeFileHandle entry = OpenRelative(parent, child.Name, true)) {
            int attributes = Attributes(entry);
            if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                (child.Attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                ((attributes ^ child.Attributes) & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
                Identity(entry).Substring(16) != child.Id)
                throw new InvalidOperationException("Owned cleanup child changed or became a reparse entry.");
            if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                foreach (ChildEntry nested in Children(entry)) DeleteEntry(entry, nested, depth + 1);
            }
            if (!SetFileInformationByHandle(entry, FILE_DISPOSITION_INFO,
                    new byte[] { 1 }, 1))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Owned cleanup disposition failed.");
        }
    }
    public void Delete() {
        nodes = 0;
        enumerated = 0;
        SafeFileHandle root = chain[chain.Count - 1];
        Ordinary(root, true);
        if (Identity(root) != RootId)
            throw new InvalidOperationException("Owned cleanup root changed before disposition.");
        foreach (ChildEntry child in Children(root)) DeleteEntry(root, child, 1);
        if (!SetFileInformationByHandle(root, FILE_DISPOSITION_INFO,
                new byte[] { 1 }, 1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Owned root disposition failed.");
    }
    public void Dispose() {
        for (int index = chain.Count - 1; index >= 0; --index) chain[index].Dispose();
        chain.Clear();
    }
}
'@
        }
        function global:Get-DrVmOwnedRootRecord {
            param([Parameter(Mandatory)][string] $Path)
            $guard = [DarkReNamerVmOwnedRootGuard]::new($Path)
            try {
                $security = $guard.Security()
                [pscustomobject]@{
                    path = $Path
                    base_file_id = $guard.BaseId
                    file_id = $guard.RootId
                    owner_sid = $security[0]
                    acl_sddl = $security[1]
                }
            } finally { $guard.Dispose() }
        }
        if (-not ('DarkReNamerVmControllerWorkspace' -as [type])) {
            Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class DarkReNamerVmControllerWorkspace {
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes {
        public int Length;
        public IntPtr SecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string descriptor, uint revision, out IntPtr securityDescriptor, out uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string path, uint access, uint share, ref SecurityAttributes attributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static void CreateResultFile(string path, string runnerSid) {
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint WRITE_DAC = 0x00040000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint CREATE_NEW = 1;
        const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        string descriptor = "O:BA G:BA D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;" + runnerSid +")(A;;FR;;;OW)";
        IntPtr securityDescriptor = IntPtr.Zero;
        try {
            uint size;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    descriptor, 1, out securityDescriptor, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            SecurityAttributes attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            attributes.SecurityDescriptor = securityDescriptor;
            attributes.InheritHandle = false;
            using (SafeFileHandle file = CreateFileW(path,
                    GENERIC_READ | GENERIC_WRITE | WRITE_DAC, FILE_SHARE_READ,
                    ref attributes, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero)) {
                if (file == null || file.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally {
            if (securityDescriptor != IntPtr.Zero) LocalFree(securityDescriptor);
        }
    }
}
'@
        }

        function New-WorkspaceDirectorySecurity {
            param([switch] $ForGuestRoot, [switch] $ForBase)
            $security = [Security.AccessControl.DirectorySecurity]::new()
            $security.SetAccessRuleProtection($true, $false)
            $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
            $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
            $security.SetOwner($administratorSid)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            foreach ($principalSid in @($administratorSid, $systemSid)) {
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $principalSid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$security.AddAccessRule($rule)
            }
            if ($ForBase) {
                $traverse = [Security.AccessControl.FileSystemAccessRule]::new(
                    [Security.Principal.SecurityIdentifier]::new($runnerSid),
                    [Security.AccessControl.FileSystemRights]::Traverse,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$security.AddAccessRule($traverse)
            }
            if ($ForGuestRoot) {
                $identity = [Security.Principal.SecurityIdentifier]::new($runnerSid)
                $localRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
                    [Security.AccessControl.FileSystemRights]::WriteData -bor
                    [Security.AccessControl.FileSystemRights]::AppendData -bor
                    [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
                    [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
                $localRule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $identity, $localRights,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$security.AddAccessRule($localRule)
                $inheritedRule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $identity,
                    [Security.AccessControl.FileSystemRights]::Modify,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::InheritOnly,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$security.AddAccessRule($inheritedRule)
            }
            $security
        }

        $base = Join-Path $env:ProgramData 'DarkReNamerVmRuns'
        $baseSecurity = New-WorkspaceDirectorySecurity -ForBase
        if (Test-Path -LiteralPath $base) {
            $baseItem = Get-Item -LiteralPath $base -Force -ErrorAction Stop
            $baseAcl = Get-Acl -LiteralPath $base
            $ownerSid = ([Security.Principal.NTAccount]$baseAcl.Owner).Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
            if (-not $baseItem.PSIsContainer -or
                ($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $ownerSid -notin @('S-1-5-18','S-1-5-32-544')) {
                throw 'The protected VM workspace base is unsafe or has an unexpected owner.'
            }
            Set-Acl -LiteralPath $base -AclObject $baseSecurity
        }
        else {
            [void][System.IO.FileSystemAclExtensions]::CreateDirectory($baseSecurity, $base)
        }
        $path = Join-Path $base $name
        if (Test-Path -LiteralPath $path) {
            throw 'The unique VM workspace path already exists.'
        }
        $rootSecurity = New-WorkspaceDirectorySecurity -ForGuestRoot
        [void][System.IO.FileSystemAclExtensions]::CreateDirectory($rootSecurity, $path)
        $global:DrVmOwnedRootRecords = @{
            guest = Get-DrVmOwnedRootRecord -Path $path
        }
        function global:Get-DrVmTrustedPowerShellPath {
            $programFiles = [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::ProgramFiles
            )
            $programFilesItem = Get-Item -LiteralPath $programFiles -Force -ErrorAction Stop
            $programFilesRoot = $programFilesItem.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
            # PowerShell Direct can enter through Windows PowerShell 5.1, whose PSHOME is not pwsh.
            $enginePath = [IO.Path]::GetFullPath((Join-Path (Join-Path $programFilesRoot 'PowerShell\7') 'pwsh.exe'))
            if (-not $programFilesItem.PSIsContainer -or
                ($programFilesItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not $enginePath.StartsWith(
                    $programFilesRoot + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'PowerShell must run from the protected Program Files installation.'
            }
            $trustedPrincipals = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
            $dangerousRights = [int](
                [Security.AccessControl.FileSystemRights]::WriteData -bor
                [Security.AccessControl.FileSystemRights]::AppendData -bor
                [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
                [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
                [Security.AccessControl.FileSystemRights]::Delete -bor
                [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
                [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                [Security.AccessControl.FileSystemRights]::TakeOwnership
            )
            $cursor = Get-Item -LiteralPath $enginePath -Force -ErrorAction Stop
            if ($cursor.PSIsContainer -or
                ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The protected PowerShell executable is not an ordinary file.'
            }
            while ($null -ne $cursor) {
                if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'The protected PowerShell path traverses a reparse point.'
                }
                $acl = Get-Acl -LiteralPath $cursor.FullName -ErrorAction Stop
                $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
                if ($ownerSid -notin $trustedPrincipals) {
                    throw 'A non-administrative principal owns part of the PowerShell installation.'
                }
                foreach ($rule in @($acl.GetAccessRules(
                    $true, $true, [Security.Principal.SecurityIdentifier]
                ))) {
                    if (($rule.PropagationFlags -band
                        [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) {
                        continue
                    }
                    $mask = [int]$rule.FileSystemRights
                    if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                        ($mask -band $dangerousRights) -ne 0 -and
                        $rule.IdentityReference.Value -notin $trustedPrincipals) {
                        throw 'A non-administrative principal can modify the PowerShell installation.'
                    }
                }
                if ([string]::Equals(
                    $cursor.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar),
                    $programFilesRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )) { break }
                $cursor = if ($cursor -is [IO.FileInfo]) {
                    $cursor.Directory
                }
                else {
                    $cursor.Parent
                }
            }
            if ($null -eq $cursor) {
                throw 'The protected PowerShell executable is outside Program Files.'
            }
            $signature = Get-AuthenticodeSignature -FilePath $enginePath -ErrorAction Stop
            if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
                $signature.SignerCertificate.Subject -notmatch '(?i)(^|,\s*)CN=Microsoft Corporation(?:,|$)') {
                throw 'The Program Files PowerShell executable is not signed by Microsoft.'
            }
            $enginePath
        }
        function global:Register-DrVmTask {
            param(
                [Parameter(Mandatory)][string] $TaskName,
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId,
                [Parameter(Mandatory)][string] $GuestRoot,
                [Parameter(Mandatory)][string] $RuntimeRoot,
                [Parameter(Mandatory)][string] $ObserverPath,
                [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ObserverSha256,
                [Parameter(Mandatory)][string] $BundleSourcePath,
                [Parameter(Mandatory)][object[]] $BundleRecords,
                [string] $InputManifestPath,
                [ValidatePattern('^[0-9a-f]{64}$')][string] $InputManifestSha256,
                [Parameter(Mandatory)][string] $Execute,
                [Parameter(Mandatory)][string] $Arguments,
                [Parameter(Mandatory)][string] $WorkingDirectory,
                [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+\.json$')][string] $TrustedResultLeaf,
                [string[]] $OutputDirectoryLeaves = @(),
                [Parameter(Mandatory)][int] $ExecutionTimeLimitSeconds
            )
            if ($UserSid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$') {
                throw 'The scheduled task principal SID is invalid.'
            }
            if ($TaskName -cnotmatch '^DarkReNamerTests-[0-9a-f]{32}$' -or
                -not [IO.Path]::IsPathRooted($Execute) -or
                -not [IO.Path]::IsPathRooted($WorkingDirectory) -or
                -not [IO.Path]::IsPathRooted($GuestRoot) -or
                -not [IO.Path]::IsPathRooted($RuntimeRoot) -or
                -not [IO.Path]::IsPathRooted($ObserverPath) -or
                -not [IO.Path]::IsPathRooted($BundleSourcePath) -or
                $SessionId -le 0 -or
                $ExecutionTimeLimitSeconds -le 0) {
                throw 'The scheduled task definition is invalid.'
            }
            if ($null -eq $global:DrVmToolingRecords -or
                $global:DrVmToolingRecords.Count -eq 0 -or
                $global:DrVmToolingManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {
                throw 'The source-bound VM tooling inventory is unavailable.'
            }
            $base = Join-Path $env:ProgramData 'DarkReNamerVmRuns'
            $trustedTaskRoot = Join-Path $base ($TaskName + '-trusted')
            $trustedTaskSecurity = [Security.AccessControl.DirectorySecurity]::new()
            $trustedTaskSecurity.SetAccessRuleProtection($true, $false)
            $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
            $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
            $ownerRightsSid = [Security.Principal.SecurityIdentifier]::new('S-1-3-4')
            $runnerSidObject = [Security.Principal.SecurityIdentifier]::new($UserSid)
            $trustedTaskSecurity.SetOwner($administratorSid)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            $runnerReadRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
                [Security.AccessControl.FileSystemRights]::Synchronize
            foreach ($principalSid in @($administratorSid, $systemSid)) {
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $principalSid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$trustedTaskSecurity.AddAccessRule($rule)
            }
            foreach ($principalSid in @($runnerSidObject, $ownerRightsSid)) {
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $principalSid,
                    $runnerReadRights,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$trustedTaskSecurity.AddAccessRule($rule)
            }
            function Assert-ProtectedTaskDirectory {
                param([Parameter(Mandatory)][string] $Path)
                $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                $acl = Get-Acl -LiteralPath $Path
                $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
                    [Security.Principal.SecurityIdentifier]
                ).Value
                $rules = @($acl.GetAccessRules(
                    $true, $true, [Security.Principal.SecurityIdentifier]
                ))
                if (-not $item.PSIsContainer -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $ownerSid -cne $administratorSid.Value -or
                    -not $acl.AreAccessRulesProtected -or $rules.Count -ne 4) {
                    throw 'Protected VM task directory owner or DACL differs from the observer contract.'
                }
                foreach ($principalSid in @($administratorSid, $systemSid)) {
                    $matches = @($rules | Where-Object {
                        $_.IdentityReference.Value -ceq $principalSid.Value -and
                        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                        [int]$_.FileSystemRights -eq 0x001f01ff -and
                        $_.InheritanceFlags -eq $inheritance -and
                        $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
                        -not $_.IsInherited
                    })
                    if ($matches.Count -ne 1) {
                        throw 'Protected VM task directory administrative access changed.'
                    }
                }
                foreach ($principalSid in @($runnerSidObject, $ownerRightsSid)) {
                    $matches = @($rules | Where-Object {
                        $_.IdentityReference.Value -ceq $principalSid.Value -and
                        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                        [int]$_.FileSystemRights -eq [int]$runnerReadRights -and
                        $_.InheritanceFlags -eq $inheritance -and
                        $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
                        -not $_.IsInherited
                    })
                    if ($matches.Count -ne 1) {
                        throw 'Protected VM task directory user read access changed.'
                    }
                }
            }
            if (-not (Test-Path -LiteralPath $trustedTaskRoot)) {
                [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $trustedTaskRoot)
            }
            Assert-ProtectedTaskDirectory -Path $trustedTaskRoot
            if ($null -eq $global:DrVmOwnedRootRecords.trusted) {
                $global:DrVmOwnedRootRecords.trusted = Get-DrVmOwnedRootRecord -Path $trustedTaskRoot
            }
            $taskRootItem = Get-Item -LiteralPath $trustedTaskRoot -Force -ErrorAction Stop
            $trustedObserverRoot = $trustedTaskRoot
            $trustedBundleRoot = Join-Path $trustedTaskRoot 'bundle'
            $guestRootFull = [IO.Path]::GetFullPath($GuestRoot).TrimEnd(
                [IO.Path]::DirectorySeparatorChar
            )
            $bundleSourceFull = [IO.Path]::GetFullPath($BundleSourcePath).TrimEnd(
                [IO.Path]::DirectorySeparatorChar
            )
            if ([string]::Equals(
                $bundleSourceFull,
                $guestRootFull,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                # The core runner and its verified tooling files resolve from the same directory.
                $trustedBundleRoot = $trustedTaskRoot
            }
            foreach ($directoryPath in @($trustedObserverRoot, $trustedBundleRoot)) {
                if (-not (Test-Path -LiteralPath $directoryPath)) {
                    [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $directoryPath)
                }
                $directoryItem = Get-Item -LiteralPath $directoryPath -Force -ErrorAction Stop
                if (-not $directoryItem.PSIsContainer -or
                    ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'A protected VM task input directory is unsafe.'
                }
                Assert-ProtectedTaskDirectory -Path $directoryPath
            }
            $trustedOutputRoot = Join-Path $trustedTaskRoot 'out'
            if (-not (Test-Path -LiteralPath $trustedOutputRoot)) {
                [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $trustedOutputRoot)
            }
            Assert-ProtectedTaskDirectory -Path $trustedOutputRoot
            $guestPrivateRoot = Join-Path $GuestRoot 'private'
            $trustedPrivateRoot = Join-Path $trustedOutputRoot 'private'
            $quotedGuestPrivateRoot = '"' + [IO.Path]::GetFullPath($guestPrivateRoot) + '"'
            $requiresPrivateRoot = $Arguments.IndexOf(
                $quotedGuestPrivateRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
            if ($requiresPrivateRoot) {
                if (-not (Test-Path -LiteralPath $trustedPrivateRoot)) {
                    [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $trustedPrivateRoot)
                }
                Assert-ProtectedTaskDirectory -Path $trustedPrivateRoot
            }
            elseif (Test-Path -LiteralPath $trustedPrivateRoot) {
                throw 'A task without private evidence must not inherit an unexpected private output directory.'
            }
            foreach ($outputLeaf in @($OutputDirectoryLeaves)) {
                if ($outputLeaf -cnotmatch '^recovery-acceptance-[0-9a-f]{32}$') {
                    throw 'A protected VM output subdirectory name is invalid.'
                }
                $outputDirectory = Join-Path $trustedOutputRoot $outputLeaf
                if (-not (Test-Path -LiteralPath $outputDirectory)) {
                    [void][System.IO.FileSystemAclExtensions]::CreateDirectory($trustedTaskSecurity, $outputDirectory)
                }
                Assert-ProtectedTaskDirectory -Path $outputDirectory
            }

            function Copy-VerifiedTrustedInput {
                param(
                    [Parameter(Mandatory)][string] $Source,
                    [Parameter(Mandatory)][string] $Destination,
                    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $Sha256,
                    [Parameter(Mandatory)][long] $Bytes,
                    [Parameter(Mandatory)][string] $Label
                )
                $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
                if ($sourceItem.PSIsContainer -or
                    ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $sourceItem.Length -ne $Bytes -or
                    (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ine $Sha256) {
                    throw "$Label source does not match its host-bound hash and size."
                }
                if (Test-Path -LiteralPath $Destination) {
                    $destinationItem = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
                    if ($destinationItem.PSIsContainer -or
                        ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                        $destinationItem.Length -ne $Bytes -or
                        (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $Sha256) {
                        throw "$Label protected copy changed or has an unexpected identity."
                    }
                    return
                }
                [void](Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop)
                $destinationItem = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
                if ($destinationItem.PSIsContainer -or
                    ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $destinationItem.Length -ne $Bytes -or
                    (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $Sha256) {
                    throw "$Label protected copy failed its hash and size check."
                }
            }

            function Assert-GuestInputPath {
                param([Parameter(Mandatory)][string] $Path,[Parameter(Mandatory)][string] $Root)
                $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
                $pathItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                $rootFull = $rootItem.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
                $pathFull = [IO.Path]::GetFullPath($Path)
                if (-not $rootItem.PSIsContainer -or
                    ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    ($pathItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    ($pathFull -cne $rootFull -and
                     -not $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar,
                        [StringComparison]::OrdinalIgnoreCase))) {
                    throw 'A VM task source path is outside the ordinary guest workspace.'
                }
                if ($pathFull -ceq $rootFull) { return }
                $cursor = if ($pathItem -is [IO.FileInfo]) {
                    $pathItem.Directory
                }
                else {
                    $pathItem.Parent
                }
                while ($null -ne $cursor -and
                    -not [string]::Equals($cursor.FullName, $rootItem.FullName, [StringComparison]::OrdinalIgnoreCase)) {
                    if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw 'A VM task source path traverses a reparse point.'
                    }
                    $cursor = $cursor.Parent
                }
                if ($null -eq $cursor) { throw 'A VM task source path is not beneath its workspace.' }
            }

            function Assert-TaskInputPath {
                param([Parameter(Mandatory)][string] $Path)
                $pathFull = [IO.Path]::GetFullPath($Path)
                $trustedRootFull = [IO.Path]::GetFullPath($trustedTaskRoot).TrimEnd(
                    [IO.Path]::DirectorySeparatorChar
                )
                if ($pathFull.StartsWith(
                    $trustedRootFull + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                    Assert-GuestInputPath -Path $Path -Root $trustedTaskRoot
                    $pathItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                    $cursor = if ($pathItem -is [IO.FileInfo]) {
                        $pathItem.Directory
                    }
                    else {
                        $pathItem
                    }
                    while ($null -ne $cursor) {
                        Assert-ProtectedTaskDirectory -Path $cursor.FullName
                        if ([string]::Equals(
                            $cursor.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar),
                            $trustedRootFull,
                            [StringComparison]::OrdinalIgnoreCase
                        )) { return }
                        $cursor = $cursor.Parent
                    }
                    throw 'A protected VM task input path escaped its task root.'
                }
                Assert-GuestInputPath -Path $Path -Root $GuestRoot
            }

            $expectedRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $guestRootFull 'runtime'))
            $runtimeRootFull = [IO.Path]::GetFullPath($RuntimeRoot)
            if (-not [string]::Equals(
                    $runtimeRootFull, $expectedRuntimeRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'The VM runtime root must be the controller-created guest runtime directory.'
            }
            Assert-TaskInputPath -Path $runtimeRootFull
            function Assert-ProtectedRuntimeDirectory {
                param([Parameter(Mandatory)][string] $Path)
                $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                $acl = Get-Acl -LiteralPath $Path
                $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
                    [Security.Principal.SecurityIdentifier]
                ).Value
                $rules = @($acl.GetAccessRules(
                    $true, $true, [Security.Principal.SecurityIdentifier]
                ))
                if (-not $item.PSIsContainer -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $ownerSid -cne $administratorSid.Value -or
                    -not $acl.AreAccessRulesProtected -or $rules.Count -ne 4) {
                    throw 'The controller-created VM runtime directory owner or DACL changed.'
                }
                foreach ($principalSid in @($administratorSid, $systemSid)) {
                    $matches = @($rules | Where-Object {
                        $_.IdentityReference.Value -ceq $principalSid.Value -and
                        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                        [int]$_.FileSystemRights -eq 0x001f01ff -and
                        $_.InheritanceFlags -eq $inheritance -and
                        $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
                        -not $_.IsInherited
                    })
                    if ($matches.Count -ne 1) {
                        throw 'The controller-created VM runtime administrative access changed.'
                    }
                }
                $runnerLocalMatches = @($rules | Where-Object {
                    $_.IdentityReference.Value -ceq $runnerSidObject.Value -and
                    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                    [int]$_.FileSystemRights -eq 0x001201bf -and
                    $_.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::None -and
                    $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
                    -not $_.IsInherited
                })
                $runnerChildMatches = @($rules | Where-Object {
                    $_.IdentityReference.Value -ceq $runnerSidObject.Value -and
                    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                    [int]$_.FileSystemRights -eq 0x001301bf -and
                    $_.InheritanceFlags -eq $inheritance -and
                    $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::InheritOnly -and
                    -not $_.IsInherited
                })
                if ($runnerLocalMatches.Count -ne 1 -or $runnerChildMatches.Count -ne 1) {
                    throw 'The controller-created VM runtime user write access changed.'
                }
            }
            Assert-ProtectedRuntimeDirectory -Path $runtimeRootFull

            $toolingManifestSource = Join-Path $GuestRoot 'tooling-bundle.json'
            Assert-GuestInputPath -Path $toolingManifestSource -Root $GuestRoot
            $toolingManifestItem = Get-Item -LiteralPath $toolingManifestSource -Force -ErrorAction Stop
            if ($toolingManifestItem.PSIsContainer -or
                ($toolingManifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                (Get-FileHash -LiteralPath $toolingManifestSource -Algorithm SHA256).Hash -ine
                    $global:DrVmToolingManifestSha256) {
                throw 'The VM tooling manifest changed before protected task staging.'
            }
            Copy-VerifiedTrustedInput `
                -Source $toolingManifestSource `
                -Destination (Join-Path $trustedObserverRoot 'tooling-bundle.json') `
                -Sha256 $global:DrVmToolingManifestSha256 `
                -Bytes $toolingManifestItem.Length `
                -Label 'VM tooling manifest'
            foreach ($record in @($global:DrVmToolingRecords)) {
                if ($record.file -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
                    $record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$record.bytes -lt 0) {
                    throw 'The verified VM tooling inventory contains an invalid file record.'
                }
                $source = Join-Path $GuestRoot $record.file
                Assert-GuestInputPath -Path $source -Root $GuestRoot
                Copy-VerifiedTrustedInput `
                    -Source $source `
                    -Destination (Join-Path $trustedObserverRoot $record.file) `
                    -Sha256 $record.sha256 `
                    -Bytes ([long]$record.bytes) `
                    -Label "VM tooling module $($record.role)"
            }

            Assert-TaskInputPath -Path $ObserverPath
            $observerItem = Get-Item -LiteralPath $ObserverPath -Force -ErrorAction Stop
            $bundleSourceFull = (Get-Item -LiteralPath $BundleSourcePath -Force -ErrorAction Stop).FullName.TrimEnd(
                [IO.Path]::DirectorySeparatorChar
            )
            $observerFull = $observerItem.FullName
            $trustedObserverPath = if ($observerFull.StartsWith(
                $bundleSourceFull + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Join-Path $trustedBundleRoot $observerItem.Name
            }
            else {
                Join-Path $trustedObserverRoot $observerItem.Name
            }
            Copy-VerifiedTrustedInput `
                -Source $ObserverPath `
                -Destination $trustedObserverPath `
                -Sha256 $ObserverSha256 `
                -Bytes $observerItem.Length `
                -Label 'VM observer script'

            Assert-TaskInputPath -Path $BundleSourcePath
            $bundleSource = Get-Item -LiteralPath $BundleSourcePath -Force -ErrorAction Stop
            if (-not $bundleSource.PSIsContainer -or
                ($bundleSource.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The VM candidate bundle source is not an ordinary directory.'
            }
            $seenBundleFiles = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($record in @($BundleRecords)) {
                if ($record.file -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
                    $record.file.Contains('..') -or
                    $record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                    [long]$record.bytes -lt 0 -or -not $seenBundleFiles.Add($record.file)) {
                    throw 'The host-bound VM candidate bundle inventory is invalid.'
                }
                $source = Join-Path $BundleSourcePath $record.file
                Assert-TaskInputPath -Path $source
                Copy-VerifiedTrustedInput `
                    -Source $source `
                    -Destination (Join-Path $trustedBundleRoot $record.file) `
                    -Sha256 $record.sha256 `
                    -Bytes ([long]$record.bytes) `
                    -Label "VM candidate bundle file $($record.file)"
            }
            if ($seenBundleFiles.Count -eq 0 -or -not $seenBundleFiles.Contains('bundle.json')) {
                throw 'The trusted VM candidate bundle must include its canonical manifest.'
            }

            $trustedInputManifest = $null
            if ($InputManifestPath) {
                if ($InputManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {
                    throw 'The VM input manifest host hash is invalid.'
                }
                Assert-TaskInputPath -Path $InputManifestPath
                $inputItem = Get-Item -LiteralPath $InputManifestPath -Force -ErrorAction Stop
                $trustedInputManifest = Join-Path $trustedTaskRoot 'input-manifest.json'
                Copy-VerifiedTrustedInput `
                    -Source $InputManifestPath `
                    -Destination $trustedInputManifest `
                    -Sha256 $InputManifestSha256 `
                    -Bytes $inputItem.Length `
                    -Label 'VM input manifest'
            }
            elseif ($InputManifestSha256) {
                throw 'A VM input manifest hash was supplied without its file.'
            }

            $resultPath = Join-Path $trustedOutputRoot $TrustedResultLeaf
            [DarkReNamerVmControllerWorkspace]::CreateResultFile($resultPath, $UserSid)
            function Set-QuotedVmTaskPath {
                param(
                    [Parameter(Mandatory)][string] $CurrentArguments,
                    [Parameter(Mandatory)][string] $SourcePath,
                    [Parameter(Mandatory)][string] $DestinationPath,
                    [switch] $Optional
                )
                $sourceArgument = '"' + [IO.Path]::GetFullPath($SourcePath) + '"'
                $destinationArgument = '"' + [IO.Path]::GetFullPath($DestinationPath) + '"'
                $first = $CurrentArguments.IndexOf($sourceArgument, [StringComparison]::OrdinalIgnoreCase)
                if ($first -lt 0) {
                    if ($Optional) { return $CurrentArguments }
                    throw 'A VM task path argument is missing or ambiguous.'
                }
                if ($CurrentArguments.IndexOf(
                        $sourceArgument,
                        $first + $sourceArgument.Length,
                        [StringComparison]::OrdinalIgnoreCase
                    ) -ge 0) {
                    throw 'A VM task path argument is missing or ambiguous.'
                }
                $CurrentArguments.Replace($sourceArgument, $destinationArgument)
            }
            $taskArguments = $Arguments
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $ObserverPath `
                -DestinationPath $trustedObserverPath
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $BundleSourcePath `
                -DestinationPath $trustedBundleRoot
            # This is the sole intentionally writable guest-workspace path; test processes create isolated temporary files beneath it.
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $RuntimeRoot `
                -DestinationPath $expectedRuntimeRoot
            $guestOutputRoot = Join-Path $GuestRoot 'out'
            if ($InputManifestPath) {
                $taskArguments = Set-QuotedVmTaskPath `
                    -CurrentArguments $taskArguments `
                    -SourcePath $InputManifestPath `
                    -DestinationPath $trustedInputManifest `
                    -Optional
            }
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $guestOutputRoot `
                -DestinationPath $trustedOutputRoot `
                -Optional
            $taskArguments = Set-QuotedVmTaskPath `
                -CurrentArguments $taskArguments `
                -SourcePath $guestPrivateRoot `
                -DestinationPath $trustedPrivateRoot `
                -Optional
            $guestRootPrefix = $guestRootFull + [IO.Path]::DirectorySeparatorChar
            $mutableCandidates = @($ObserverPath,$BundleSourcePath,$guestOutputRoot,$guestPrivateRoot)
            if ($InputManifestPath) { $mutableCandidates += $InputManifestPath }
            $mutableArguments = @($mutableCandidates | Where-Object {
                $candidateFull = [IO.Path]::GetFullPath($_)
                $candidateFull -ceq $guestRootFull -or $candidateFull.StartsWith(
                    $guestRootPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
            })
            foreach ($mutablePath in $mutableArguments) {
                $quotedMutablePath = '"' + [IO.Path]::GetFullPath($mutablePath) + '"'
                if ($taskArguments.IndexOf($quotedMutablePath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    throw 'A VM task argument retained a mutable guest workspace path.'
                }
            }
            $trustedOutputArgument = '"' + [IO.Path]::GetFullPath($trustedOutputRoot) + '"'
            $trustedOutputIndex = $taskArguments.IndexOf(
                $trustedOutputArgument,
                [StringComparison]::OrdinalIgnoreCase
            )
            if ($trustedOutputIndex -lt 0 -or
                $taskArguments.IndexOf(
                    $trustedOutputArgument,
                    $trustedOutputIndex + $trustedOutputArgument.Length,
                    [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                throw 'A VM task must bind exactly one protected output root.'
            }
            $taskArguments += ' -ElevatedObserver -TrustedResultPath "' + $resultPath + '"'
            $trustedPowerShell = Get-DrVmTrustedPowerShellPath
            if (-not [string]::Equals(
                    [IO.Path]::GetFullPath($Execute), $trustedPowerShell,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The Windows VM task executable differs from the protected PowerShell engine.'
            }
            $descriptor = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x20089;;;' + $UserSid + ')(A;;0;;;OW)'
            $service = New-Object -ComObject Schedule.Service
            $service.Connect()
            $folder = $service.GetFolder('\')
            $definition = $service.NewTask(0)
            $definition.Settings.Enabled = $true
            $definition.Settings.ExecutionTimeLimit = [Xml.XmlConvert]::ToString(
                [TimeSpan]::FromSeconds($ExecutionTimeLimitSeconds)
            )
            $definition.Principal.UserId = $UserSid
            $definition.Principal.LogonType = 3
            $definition.Principal.RunLevel = 1
            $action = $definition.Actions.Create(0)
            $action.Path = $trustedPowerShell
            $action.Arguments = $taskArguments
            $action.WorkingDirectory = $trustedTaskRoot
            $registeredTask = $folder.RegisterTaskDefinition(
                $TaskName,
                $definition,
                0x12,
                $UserSid,
                $null,
                3,
                $descriptor
            )
            $actualDefinition = $registeredTask.Definition
            if ($actualDefinition.Actions.Count -ne 1) {
                throw 'The registered VM task action count changed.'
            }
            $actualAction = $actualDefinition.Actions.Item(1)
            if (-not [string]::Equals(
                    [string]$actualAction.Path, $trustedPowerShell,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                -not [string]::Equals(
                    [string]$actualAction.Arguments, $taskArguments,
                    [StringComparison]::Ordinal
                ) -or
                -not [string]::Equals(
                    [string]$actualAction.WorkingDirectory, $trustedTaskRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'The registered VM task action differs from the requested action.'
            }
            $actualPrincipal = $actualDefinition.Principal
            $actualPrincipalSid = if (
                [string]$actualPrincipal.UserId -cmatch '^S-1-\d+(?:-\d+)+$'
            ) {
                [Security.Principal.SecurityIdentifier]::new(
                    [string]$actualPrincipal.UserId
                )
            }
            else {
                [Security.Principal.NTAccount]::new(
                    [string]$actualPrincipal.UserId
                ).Translate(
                    [Security.Principal.SecurityIdentifier]
                )
            }
            if ($actualPrincipalSid.Value -cne $UserSid -or
                [int]$actualPrincipal.LogonType -ne 3 -or
                [int]$actualPrincipal.RunLevel -ne 1) {
                throw 'The registered VM observer principal, interactive logon, or elevated run level differs from the task contract.'
            }
            $actualExecutionLimit = [Xml.XmlConvert]::ToTimeSpan(
                [string]$actualDefinition.Settings.ExecutionTimeLimit
            )
            if ($actualExecutionLimit.Ticks -ne
                [TimeSpan]::FromSeconds($ExecutionTimeLimitSeconds).Ticks) {
                throw 'The registered VM task execution limit differs from the requested limit.'
            }
            $actualDescriptor = $registeredTask.GetSecurityDescriptor(0x7)
            $actual = [Security.AccessControl.RawSecurityDescriptor]::new($actualDescriptor)
            $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
            $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
            $ownerRightsSid = [Security.Principal.SecurityIdentifier]::new('S-1-3-4')
            if (($actual.ControlFlags -band
                    [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -eq 0 -or
                $actual.DiscretionaryAcl.Count -ne 4) {
                throw 'The registered VM task did not retain its protected DACL.'
            }
            foreach ($principalSid in @($administratorSid, $systemSid)) {
                $fullAces = @($actual.DiscretionaryAcl | Where-Object {
                    $_.AceType -eq [Security.AccessControl.AceType]::AccessAllowed -and
                    $_.SecurityIdentifier -eq $principalSid -and
                    $_.AccessMask -eq [int]0x001f01ff
                })
                if ($fullAces.Count -ne 1) {
                    throw 'The VM task administrative recovery rights are missing.'
                }
            }
            $runnerReadAces = @($actual.DiscretionaryAcl | Where-Object {
                $_.AceType -eq [Security.AccessControl.AceType]::AccessAllowed -and
                $_.SecurityIdentifier -eq $runnerSidObject -and $_.AccessMask -eq 0x00020089
            })
            if ($runnerReadAces.Count -ne 1) {
                throw 'The VM observer task query rights for the configured user are missing.'
            }
            $ownerRightsAces = @($actual.DiscretionaryAcl | Where-Object {
                $_.AceType -eq [Security.AccessControl.AceType]::AccessAllowed -and
                $_.SecurityIdentifier -eq $ownerRightsSid -and $_.AccessMask -eq 0
            })
            if ($ownerRightsAces.Count -ne 1 -or @($actual.DiscretionaryAcl | Where-Object {
                $_.AceType -ne [Security.AccessControl.AceType]::AccessAllowed
            }).Count -ne 0) {
                throw 'The VM task owner must have no implicit control and its DACL must contain only SYSTEM, Administrators, the configured read-only user grant, and owner-rights grants.'
            }
            $registeredTask
        }
        function global:New-DrVmGuestDirectory {
            param(
                [Parameter(Mandatory)][string] $ParentPath,
                [Parameter(Mandatory)][string] $Leaf,
                [Parameter(Mandatory)][string] $UserSid
            )
            if ($UserSid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$' -or
                $Leaf -cnotmatch '^(?:out|runtime|recovery-acceptance-[0-9a-f]{32})$') {
                throw 'The protected guest directory identity is invalid.'
            }
            $parent = Get-Item -LiteralPath $ParentPath -Force -ErrorAction Stop
            if (-not $parent.PSIsContainer -or
                ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The protected guest directory parent is unsafe.'
            }
            $path = Join-Path $parent.FullName $Leaf
            if (Test-Path -LiteralPath $path) {
                throw 'The protected guest directory already exists.'
            }
            $security = [Security.AccessControl.DirectorySecurity]::new()
            $security.SetAccessRuleProtection($true, $false)
            $administratorSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
            $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
            $runnerSid = [Security.Principal.SecurityIdentifier]::new($UserSid)
            $security.SetOwner($administratorSid)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            foreach ($principalSid in @($administratorSid, $systemSid)) {
                [void]$security.AddAccessRule(
                    [Security.AccessControl.FileSystemAccessRule]::new(
                        $principalSid,
                        [Security.AccessControl.FileSystemRights]::FullControl,
                        $inheritance,
                        [Security.AccessControl.PropagationFlags]::None,
                        [Security.AccessControl.AccessControlType]::Allow
                    )
                )
            }
            $localRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
                [Security.AccessControl.FileSystemRights]::WriteData -bor
                [Security.AccessControl.FileSystemRights]::AppendData -bor
                [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
                [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
            [void]$security.AddAccessRule(
                [Security.AccessControl.FileSystemAccessRule]::new(
                    $runnerSid,
                    $localRights,
                    [Security.AccessControl.AccessControlType]::Allow
                )
            )
            [void]$security.AddAccessRule(
                [Security.AccessControl.FileSystemAccessRule]::new(
                    $runnerSid,
                    [Security.AccessControl.FileSystemRights]::Modify,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::InheritOnly,
                    [Security.AccessControl.AccessControlType]::Allow
                )
            )
            [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $path)
            $path
        }
        function global:Get-DrVmRunnerTasks {
            param([Parameter(Mandatory)][string] $UserSid)

            if ($UserSid -cnotmatch '^S-1-5-21-(\d+-){2}\d+-\d+$') {
                throw 'The task inventory principal SID is invalid.'
            }
            foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
                $userId = [string]$task.Principal.UserId
                $groupId = [string]$task.Principal.GroupId
                if ([string]::IsNullOrWhiteSpace($userId) -and
                    [string]::IsNullOrWhiteSpace($groupId)) {
                    throw 'A scheduled task principal is unavailable for the runner inventory.'
                }
                $userSid = $null
                if (-not [string]::IsNullOrWhiteSpace($userId)) {
                    try {
                        if ($userId -cmatch '^S-1-\d+(?:-\d+)+$') {
                            $userSid = [Security.Principal.SecurityIdentifier]::new($userId)
                        }
                        else {
                            $userSid = [Security.Principal.NTAccount]::new($userId).Translate(
                                [Security.Principal.SecurityIdentifier])
                        }
                    }
                    catch {
                        throw 'A scheduled task user principal could not be resolved for the runner inventory.'
                    }
                }
                # Group-principal tasks are retained in the baseline as potential
                # runner resources; their membership may differ in the desktop token.
                if ($userSid -and ($userSid.Value -ceq $UserSid -or
                    -not [string]::IsNullOrWhiteSpace($groupId))) {
                    $includeTask = $true
                }
                else {
                    $includeTask = -not [string]::IsNullOrWhiteSpace($groupId)
                }
                if ($includeTask) {
                    $xml = [string](@(Export-ScheduledTask `
                        -TaskName $task.TaskName `
                        -TaskPath $task.TaskPath `
                        -ErrorAction Stop) -join "`n")
                    $algorithm = [Security.Cryptography.SHA256]::Create()
                    try {
                        $definitionSha256 = ([BitConverter]::ToString(
                            $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($xml))
                        ) -replace '-', '').ToLowerInvariant()
                    }
                    finally { $algorithm.Dispose() }
                    [pscustomobject]@{
                        identity = [string]$task.TaskPath + [string]$task.TaskName
                        task_path = [string]$task.TaskPath
                        task_name = [string]$task.TaskName
                        definition_sha256 = $definitionSha256
                    }
                }
            }
        }
        function global:Initialize-DrVmSpotlightNative {
            if ($null -ne ('DrVmSpotlightNative' -as [type])) { return }
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class DrVmSpotlightHandle : SafeHandleZeroOrMinusOneIsInvalid {
    public DrVmSpotlightHandle() : base(true) { }
    public int CloseError { get; private set; }
    protected override bool ReleaseHandle() {
        bool ok = DrVmSpotlightNative.CloseHandle(handle);
        CloseError = ok ? 0 : Marshal.GetLastWin32Error();
        return ok;
    }
}
public sealed class DrVmSpotlightLifetime : IDisposable {
    private readonly DrVmSpotlightHandle handle;
    public Dictionary<string, object> Identity { get; private set; }
    public int CloseError { get { return handle.CloseError; } }
    public bool Closed { get { return handle.IsClosed; } }
    internal DrVmSpotlightLifetime(DrVmSpotlightHandle handle, Dictionary<string, object> identity) {
        this.handle = handle; Identity = identity;
    }
    public Dictionary<string, object> Poll() {
        if (handle.IsClosed) throw new ObjectDisposedException("DrVmSpotlightLifetime");
        uint wait = DrVmSpotlightNative.WaitForSingleObject(handle, 0);
        if (wait == uint.MaxValue) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        if (wait != 0 && wait != 258) throw new InvalidDataException("Unexpected process wait status.");
        var row = new Dictionary<string, object> {
            {"pid", Identity["pid"]}, {"creation_filetime_100ns", Identity["creation_filetime_100ns"]},
            {"exit_filetime_100ns", null}, {"wait_result", wait}, {"times_succeeded", false},
            {"times_win32_error", 0}, {"exit_code_succeeded", false}, {"exit_code_win32_error", 0},
            {"exit_code", null}, {"handle_closed", false}, {"close_win32_error", 0}
        };
        if (wait == 0) {
            DrVmSpotlightNative.FileTime creation, exit, kernel, user;
            bool ok = DrVmSpotlightNative.GetProcessTimes(handle, out creation, out exit, out kernel, out user);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            row["times_succeeded"] = ok; row["times_win32_error"] = error;
            if (ok) {
                if (creation.Value.ToString(CultureInfo.InvariantCulture) != (string)Identity["creation_filetime_100ns"])
                    throw new InvalidDataException("Same-handle process creation time changed.");
                row["exit_filetime_100ns"] = exit.Value.ToString(CultureInfo.InvariantCulture);
            }
            uint code;
            ok = DrVmSpotlightNative.GetExitCodeProcess(handle, out code);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            row["exit_code_succeeded"] = ok; row["exit_code_win32_error"] = error;
            if (ok) row["exit_code"] = code;
        }
        return row;
    }
    public void Dispose() { handle.Dispose(); }
}
public static class DrVmSpotlightNative {
    public const uint ProcessAccess = 0x00101000; // Limited query and synchronize only.
    public const uint TokenAccess = 8; // TOKEN_QUERY only; no privilege changes.
    [StructLayout(LayoutKind.Sequential)] public struct FileTime {
        public uint Low, High;
        public ulong Value { get { return ((ulong)High << 32) | Low; } }
    }
    [StructLayout(LayoutKind.Sequential)] public struct PackageId {
        public uint Reserved, Architecture;
        public ulong Version;
        public IntPtr Name, Publisher, ResourceId, PublisherId;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PackageInfo {
        public uint Reserved, Flags;
        public IntPtr Path, FullName, FamilyName;
        public PackageId Id;
    }
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    private static extern DrVmSpotlightHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint pid);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    private static extern uint GetProcessId(DrVmSpotlightHandle handle);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetProcessTimes(DrVmSpotlightHandle handle, out FileTime creation, out FileTime exit, out FileTime kernel, out FileTime user);
    [DllImport("kernel32.dll", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryFullProcessImageNameW(DrVmSpotlightHandle handle, uint flags, StringBuilder text, ref uint chars);
    [DllImport("kernel32.dll", ExactSpelling=true, CharSet=CharSet.Unicode)]
    private static extern int GetPackageFullName(DrVmSpotlightHandle handle, ref uint chars, StringBuilder text);
    [DllImport("kernel32.dll", ExactSpelling=true, CharSet=CharSet.Unicode)]
    private static extern int GetApplicationUserModelId(DrVmSpotlightHandle handle, ref uint chars, StringBuilder text);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    public static extern uint WaitForSingleObject(DrVmSpotlightHandle handle, uint milliseconds);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetExitCodeProcess(DrVmSpotlightHandle handle, out uint code);
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenProcessToken(DrVmSpotlightHandle process, uint access, out DrVmSpotlightHandle token);
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetTokenInformation(DrVmSpotlightHandle token, int kind, IntPtr buffer, uint bytes, out uint required);
    [DllImport("kernel32.dll", ExactSpelling=true, CharSet=CharSet.Unicode)]
    private static extern int OpenPackageInfoByFullName(string name, uint reserved, out IntPtr reference);
    [DllImport("kernel32.dll", ExactSpelling=true)]
    private static extern int GetPackageInfo(IntPtr reference, uint flags, ref uint bytes, IntPtr buffer, out uint count);
    [DllImport("kernel32.dll", ExactSpelling=true)]
    private static extern int ClosePackageInfo(IntPtr reference);

    private static void WindowsOnly() {
        if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
            throw new PlatformNotSupportedException("Spotlight interop requires native x64 Windows.");
    }
    private delegate int NameQuery(ref uint length, StringBuilder text);
    private static void Name(DrVmSpotlightHandle handle, bool package, Dictionary<string, object> row) {
        string prefix = package ? "package" : "aumid";
        string key = package ? "package_full_name" : "aumid";
        uint required = 0;
        NameQuery query = package ? new NameQuery(delegate(ref uint n, StringBuilder b) { return GetPackageFullName(handle, ref n, b); })
                                 : new NameQuery(delegate(ref uint n, StringBuilder b) { return GetApplicationUserModelId(handle, ref n, b); });
        int first = query(ref required, null); row[prefix + "_first_status"] = first;
        row[prefix + "_status"] = null; row[key] = null;
        if (first != 122 || required < 2 || required > (package ? 128 : 130)) return;
        uint length = required; var text = new StringBuilder((int)length);
        int second = query(ref length, text); row[prefix + "_status"] = second;
        if (second == 0 && length >= 2 && length <= required && text.Length == length - 1 && text.ToString().IndexOf('\0') < 0)
            row[key] = text.ToString();
    }
    private static void Token(DrVmSpotlightHandle process, Dictionary<string, object> row) {
        DrVmSpotlightHandle token;
        bool ok = OpenProcessToken(process, TokenAccess, out token);
        int openError = ok ? 0 : Marshal.GetLastWin32Error();
        row["token_error"] = openError;
        try {
            if (!ok) return;
            uint required;
            ok = GetTokenInformation(token, 1, IntPtr.Zero, 0, out required);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            if (ok || error != 122 || required < 16 || required > 4096) {
                row["token_sid_error"] = error == 0 ? 13 : error; return;
            }
            IntPtr buffer = Marshal.AllocHGlobal((int)required);
            try {
                uint returned;
                ok = GetTokenInformation(token, 1, buffer, required, out returned);
                error = ok ? 0 : Marshal.GetLastWin32Error();
                row["token_sid_error"] = error;
                if (!ok) return;
                if (returned > required || returned < 16) throw new InvalidDataException("Token user buffer size invalid.");
                IntPtr sid = Marshal.ReadIntPtr(buffer);
                long offset = sid.ToInt64() - buffer.ToInt64();
                if (offset < 16 || offset > returned - 8) throw new InvalidDataException("Token SID pointer outside buffer.");
                int subs = Marshal.ReadByte(sid, 1);
                int length = 8 + 4 * subs;
                if (subs > 15 || offset + length > returned) throw new InvalidDataException("Token SID size outside buffer.");
                byte[] bytes = new byte[length]; Marshal.Copy(sid, bytes, 0, length);
                row["owner_sid"] = new SecurityIdentifier(bytes, 0).Value;
            } finally { Marshal.FreeHGlobal(buffer); }
            uint sessionBytes;
            IntPtr session = Marshal.AllocHGlobal(4);
            try {
                ok = GetTokenInformation(token, 12, session, 4, out sessionBytes);
                error = ok ? 0 : Marshal.GetLastWin32Error(); row["token_session_error"] = error;
                if (ok && sessionBytes == 4) row["session_id"] = unchecked((uint)Marshal.ReadInt32(session));
                else if (ok) row["token_session_error"] = 13;
            } finally { Marshal.FreeHGlobal(session); }
        } finally {
            if (token != null) {
                token.Dispose();
                if (token.CloseError != 0) row["token_error"] = token.CloseError;
            }
        }
    }
    public static DrVmSpotlightLifetime Open(uint pid, bool package) {
        WindowsOnly(); if (pid == 0) throw new ArgumentOutOfRangeException("pid");
        DrVmSpotlightHandle handle = OpenProcess(ProcessAccess, false, pid);
        int openError = handle.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        try {
            var row = new Dictionary<string, object> {
                {"pid", 0u}, {"creation_filetime_100ns", null}, {"owner_sid", null}, {"session_id", null}, {"image_path", null},
                {"open_error", openError}, {"pid_error", 0}, {"times_error", 0}, {"image_error", 0},
                {"token_error", 0}, {"token_sid_error", 0}, {"token_session_error", 0}
            };
            if (package) { row["package_first_status"] = null; row["package_status"] = null; row["aumid_first_status"] = null; row["aumid_status"] = null; row["package_full_name"] = null; row["aumid"] = null; }
            if (!handle.IsInvalid) {
                uint actual = GetProcessId(handle); int error = actual == 0 ? Marshal.GetLastWin32Error() : 0;
                row["pid"] = actual; row["pid_error"] = error;
                FileTime creation, exit, kernel, user;
                bool ok = GetProcessTimes(handle, out creation, out exit, out kernel, out user);
                error = ok ? 0 : Marshal.GetLastWin32Error(); row["times_error"] = error;
                if (ok) row["creation_filetime_100ns"] = creation.Value.ToString(CultureInfo.InvariantCulture);
                Token(handle, row);
                var image = new StringBuilder(32768); uint chars = 32768;
                ok = QueryFullProcessImageNameW(handle, 0, image, ref chars);
                error = ok ? 0 : Marshal.GetLastWin32Error(); row["image_error"] = error;
                if (ok && chars > 0 && chars < 32768 && image.Length == chars && image.ToString().IndexOf('\0') < 0) row["image_path"] = image.ToString();
                if (package) { Name(handle, true, row); Name(handle, false, row); }
            }
            return new DrVmSpotlightLifetime(handle, row);
        } catch { handle.Dispose(); throw; }
    }
    private static string Wide(string field, IntPtr pointer, IntPtr buffer, uint bytes, int maximum, bool empty) {
        long offset = pointer.ToInt64() - buffer.ToInt64();
        if (pointer == IntPtr.Zero || offset < 0 || (offset & 1) != 0 || offset >= bytes)
            throw new InvalidDataException(String.Format(CultureInfo.InvariantCulture, "Package field {0} pointer invalid: null={1}, relative_offset={2}, returned_bytes={3}.", field, pointer == IntPtr.Zero, pointer == IntPtr.Zero ? 0 : offset, bytes));
        int available = (int)Math.Min(maximum + 1, (bytes - offset) / 2);
        for (int length = 0; length < available; length++) {
            if (Marshal.ReadInt16(pointer, length * 2) == 0) {
                if (!empty && length == 0) throw new InvalidDataException("Package string empty.");
                return Marshal.PtrToStringUni(pointer, length);
            }
        }
        throw new InvalidDataException("Package string exceeds bound or has no terminator.");
    }
    public static Dictionary<string, object> Package(string fullName) {
        WindowsOnly(); if (fullName == null || fullName.Length < 1 || fullName.Length > 127) throw new ArgumentException("Package full name invalid.");
        IntPtr reference = IntPtr.Zero;
        string callerSid;
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) { callerSid = identity.User.Value; }
        var row = new Dictionary<string, object> { {"open_status", 0}, {"first_status", 0}, {"second_status", 0}, {"close_status", 0},
            {"required_bytes", 0u}, {"returned_bytes", 0u}, {"count", 0u}, {"request_flags", 0x110u}, {"property_flags", 0u},
            {"caller_sid", callerSid}, {"name", ""}, {"package_full_name", ""}, {"package_family_name", ""},
            {"publisher", ""}, {"publisher_id", ""}, {"version", ""}, {"architecture", ""}, {"resource_id", ""}, {"path", ""} };
        int opened = OpenPackageInfoByFullName(fullName, 0, out reference);
        row["open_status"] = opened;
        if (opened != 0) return row;
        try {
            uint bytes = 0, count;
            int first = GetPackageInfo(reference, 0x110, ref bytes, IntPtr.Zero, out count);
            row["first_status"] = first; row["required_bytes"] = bytes;
            if (first != 122 || bytes < Marshal.SizeOf(typeof(PackageInfo)) || bytes > 65536) return row;
            uint allocated = bytes; IntPtr buffer = Marshal.AllocHGlobal((int)bytes);
            try {
                int second = GetPackageInfo(reference, 0x110, ref bytes, buffer, out count);
                row["second_status"] = second; row["returned_bytes"] = bytes; row["count"] = count;
                if (second != 0 || count != 1 || bytes > allocated || bytes < Marshal.SizeOf(typeof(PackageInfo))) return row;
                PackageInfo info = (PackageInfo)Marshal.PtrToStructure(buffer, typeof(PackageInfo));
                row["property_flags"] = info.Flags;
                row["name"] = Wide("name", info.Id.Name, buffer, bytes, 50, false);
                row["package_full_name"] = Wide("package_full_name", info.FullName, buffer, bytes, 127, false);
                row["package_family_name"] = Wide("package_family_name", info.FamilyName, buffer, bytes, 64, false);
                row["publisher"] = Wide("publisher", info.Id.Publisher, buffer, bytes, 8192, false);
                row["publisher_id"] = Wide("publisher_id", info.Id.PublisherId, buffer, bytes, 13, false);
                row["resource_id"] = info.Id.ResourceId == IntPtr.Zero ? null : Wide("resource_id", info.Id.ResourceId, buffer, bytes, 30, true);
                row["path"] = Wide("path", info.Path, buffer, bytes, 32767, false);
                ulong version = info.Id.Version;
                row["version"] = String.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}.{3}", (version >> 48) & 65535, (version >> 32) & 65535, (version >> 16) & 65535, version & 65535);
                string[] architectures = {"x86","arm","x64","neutral","arm64"};
                switch (info.Id.Architecture) { case 0: row["architecture"] = architectures[0]; break; case 5: row["architecture"] = architectures[1]; break; case 9: row["architecture"] = architectures[2]; break; case 11: row["architecture"] = architectures[3]; break; case 12: row["architecture"] = architectures[4]; break; default: throw new InvalidDataException("Unsupported package architecture."); }
            } finally { Marshal.FreeHGlobal(buffer); }
        } finally { row["close_status"] = ClosePackageInfo(reference); }
        return row;
    }
}
'@ -ErrorAction Stop
        }
        function global:Open-DrVmSpotlightLifetime {
            param([Parameter(Mandatory)][uint32] $ProcessId, [switch] $Parent)
            Initialize-DrVmSpotlightNative
            [DrVmSpotlightNative]::Open($ProcessId, -not $Parent)
        }
        function global:New-DrVmSpotlightCaptureContext {
            param([AllowEmptyCollection()][string[]] $BaselineIdentities)
            $baseline = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($identity in $BaselineIdentities) { [void]$baseline.Add($identity) }
            [pscustomobject]@{
                baseline = $baseline
                observations = [Collections.Generic.List[object]]::new()
                lifetimes = @{}
                initial_rows = @{}
                failed = $false
            }
        }
        function global:Test-DrVmSpotlightNativeIdentity {
            param([object] $Native, [object] $Candidate, [string] $UserSid, [int] $SessionId)
            try {
                foreach ($key in @('open_error','pid_error','times_error','image_error',
                    'token_error','token_sid_error','token_session_error')) {
                    if ($Native[$key] -ne 0) { return $false }
                }
                if ($Native['pid'] -ne $Candidate.pid -or $Native['owner_sid'] -cne $UserSid -or
                    $Native['session_id'] -ne $SessionId -or
                    $Native['image_path'] -ine $Candidate.executable_path -or
                    [string]$Native['creation_filetime_100ns'] -cnotmatch '^[1-9][0-9]{0,19}$') { return $false }
                $nativeTicks = [long]::Parse($Native['creation_filetime_100ns'], [Globalization.CultureInfo]::InvariantCulture)
                $cimTicks = [datetime]::Parse($Candidate.creation_time_utc,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind).ToFileTimeUtc()
                $difference = $nativeTicks - $cimTicks
                $difference -ge 0 -and $difference -le 9 -and $cimTicks % 10 -eq 0
            } catch { return $false }
        }
        function global:Add-DrVmSpotlightInitialObservation {
            param([object] $Context, [object] $Process, [int] $Attempt)
            $created = ([datetime]$Process.CreationDate).ToUniversalTime().ToString('o')
            $identity = [string]$Process.ProcessId + '|' + $created
            if ($Context.baseline.Contains($identity) -or $Context.lifetimes.ContainsKey($identity)) { return }
            if ($Context.observations.Count -ge 2) { $Context.failed = $true; return }
            $row = [pscustomobject]@{
                identity = $identity; pid = [int]$Process.ProcessId; session_id = [int]$Process.SessionId
                creation_time_utc = $created; executable_path = [string]$Process.ExecutablePath
            }
            $observation = [ordered]@{attempt=$Attempt; cim_row=$row; native_identity=$null; capture_error=$null}
            $Context.observations.Add($observation)
            $lifetime = $null
            try {
                $lifetime = Open-DrVmSpotlightLifetime -ProcessId $row.pid
                $Context.lifetimes[$identity] = $lifetime
                $observation.native_identity = $lifetime.Identity
                if (-not (Test-DrVmSpotlightNativeIdentity -Native $lifetime.Identity -Candidate $row `
                    -UserSid $lifetime.Identity['owner_sid'] -SessionId $row.session_id)) {
                    throw 'The initial native process identity was incomplete or mismatched.'
                }
                # Capture a signaled exit without reopening the PID later.
                $Context.lifetimes[$identity] = [pscustomobject]@{
                    owner=$lifetime; exit=$lifetime.Poll(); process=$Process
                }
            } catch {
                $Context.failed = $true
                $observation.capture_error = [ordered]@{
                    error_type=$_.Exception.GetType().FullName; hresult=[int]$_.Exception.HResult
                }
            }
        }
        function global:Close-DrVmSpotlightCaptureContext {
            param([object] $Context)
            $errors = [Collections.Generic.List[string]]::new()
            foreach ($identity in @($Context.lifetimes.Keys)) {
                $entry = $Context.lifetimes[$identity]
                $owner = if ($null -ne $entry.PSObject.Properties['owner']) { $entry.owner } else { $entry }
                try {
                    $owner.Dispose()
                    if (-not $owner.Closed -or $owner.CloseError -ne 0) { throw 'Native handle close failed.' }
                    if ($null -ne $entry.PSObject.Properties['exit']) {
                        $entry.exit['handle_closed'] = $owner.Closed
                        $entry.exit['close_win32_error'] = $owner.CloseError
                    }
                } catch { $errors.Add('A retained native process handle could not be closed.') }
            }
            if ($errors.Count -ne 0) { throw ($errors -join ' ') }
        }
        function global:Get-DrVmSpotlightManifest {
            param([Parameter(Mandatory)][string] $InstallLocation)
            $windows = [IO.Path]::GetFullPath($env:windir).TrimEnd('\')
            if ($windows -cnotmatch '^[A-Za-z]:\\[^\\]+$') { throw 'DesktopSpotlight requires a direct drive-child Windows directory.' }
            $family = Join-Path (Join-Path $windows 'SystemApps') 'MicrosoftWindows.Client.CBS_cw5n1h2txyewy'
            if ($InstallLocation -ine $family) { throw 'CBS must be registered at its exact protected SystemApps path.' }
            $path = Join-Path $family 'AppxManifest.xml'
            $objects = [Collections.Generic.List[object]]::new()
            $trusted = @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
            $risk = [uint32]0x500D0156
            $paths = @([IO.Path]::GetPathRoot($windows),$windows,(Join-Path $windows 'SystemApps'),$family,$path)
            foreach ($objectPath in $paths) {
                $item = Get-Item -LiteralPath $objectPath -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $item.PSIsContainer -ne ($objectPath -ine $path)) { throw 'CBS manifest path contains an unexpected object.' }
                $acl = Get-Acl -LiteralPath $objectPath -ErrorAction Stop
                $raw = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0)
                if (($raw.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -eq 0 -or
                    $null -eq $raw.DiscretionaryAcl -or $raw.DiscretionaryAcl.Count -lt 1 -or
                    $raw.DiscretionaryAcl.Count -gt 64 -or $raw.Owner.Value -cnotin $trusted) { throw 'CBS manifest path security descriptor is incomplete or untrusted.' }
                $aces = [Collections.Generic.List[object]]::new()
                foreach ($ace in $raw.DiscretionaryAcl) {
                    $type = [int]$ace.AceType
                    if ($type -notin @(0,1,9,10) -or $ace -isnot [Security.AccessControl.QualifiedAce]) { throw 'CBS path contains an unsupported ACE.' }
                    $mask = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ace.AccessMask),0)
                    $sid = $ace.SecurityIdentifier.Value
                    $flags = [int]$ace.AceFlags
                    $effectiveRisk = $risk
                    if ($objectPath -ieq $paths[0]) { $effectiveRisk = $risk -band (-bnot [uint32]4) }
                    if ($type -in @(0,9) -and ($flags -band 8) -eq 0 -and
                        $sid -cnotin $trusted -and ($mask -band $effectiveRisk) -ne 0) { throw 'CBS manifest path grants untrusted effective write access.' }
                    $aces.Add([ordered]@{ace_type=$type;ace_flags=$flags;access_mask=$mask;sid=$sid})
                }
                $objects.Add([ordered]@{path=$objectPath;is_directory=[bool]$item.PSIsContainer
                    attributes=[int]$item.Attributes;owner_sid=$raw.Owner.Value;dacl_present=$true;aces=@($aces.ToArray())})
            }
            $stream = [IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {
                $length = $stream.Length
                if ($length -lt 1 -or $length -gt 1MB) { throw 'CBS manifest exceeds its byte bound.' }
                $bytes = [byte[]]::new([int]$length)
                $offset = 0
                while ($offset -lt $bytes.Length) {
                    $count = $stream.Read($bytes,$offset,$bytes.Length-$offset)
                    if ($count -le 0) { throw 'CBS manifest ended early.' }
                    $offset += $count
                }
                if ($stream.ReadByte() -ne -1 -or $stream.Length -ne $length) { throw 'CBS manifest changed length.' }
            } finally { $stream.Dispose() }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() }
            finally { $sha.Dispose() }
            [ordered]@{path=$path;byte_length=$bytes.Length;sha256=$hash;data_base64=[Convert]::ToBase64String($bytes);path_objects=@($objects.ToArray())}
        }
        function global:Test-DrVmSpotlightRegistration {
            param([object] $Preflight,[object] $Current,[object] $Native,[string] $UserSid)
            try {
                if ($null -eq $Preflight -or $Preflight.runner_sid -cne $UserSid -or
                    $Preflight.name -cne 'MicrosoftWindows.Client.CBS' -or
                    $Preflight.package_family_name -cne 'MicrosoftWindows.Client.CBS_cw5n1h2txyewy' -or
                    $Preflight.publisher_id -cne 'cw5n1h2txyewy' -or
                    $Preflight.publisher -cne 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' -or
                    $Preflight.resource_id -cne '' -or $Preflight.signature_kind -cne 'System' -or
                    $Preflight.status -cne 'Ok' -or $Preflight.is_development_mode -isnot [bool] -or
                    $Preflight.is_development_mode -or $Current['caller_sid'] -cne $UserSid -or
                    $Current['open_status'] -ne 0 -or $Current['first_status'] -ne 122 -or
                    $Current['second_status'] -ne 0 -or $Current['close_status'] -ne 0 -or
                    $Current['required_bytes'] -lt 80 -or $Current['required_bytes'] -gt 65536 -or
                    $Current['returned_bytes'] -gt $Current['required_bytes'] -or $Current['returned_bytes'] -lt 80 -or
                    $null -ne $Current['resource_id'] -or $Current['count'] -ne 1 -or $Current['request_flags'] -ne 0x110 -or
                    ($Current['property_flags'] -band 0x1000f) -ne 0) { return $false }
                foreach ($key in @('name','package_full_name','package_family_name','publisher','publisher_id','version','architecture')) {
                    if ($Current[$key] -cne $Preflight.$key) { return $false }
                }
                if ($Current['path'] -ine $Preflight.install_location -or
                    $Current['package_full_name'] -cne $Native['package_full_name']) { return $false }
                $child = $Preflight.child_lifecycle
                if ($child.exit_code -ne 0 -or -not $child.exited -or -not $child.streams_complete -or
                    -not $child.exact_lifetime_absent -or -not $child.process_job_closed -or
                    [long]$child.start_time_utc_ticks - 504911232000000000 -ge [long]$Native['creation_filetime_100ns']) { return $false }
                return $true
            } catch { return $false }
        }
        function global:Test-DrVmSpotlightManifestIdentity {
            param([object] $Manifest,[object] $Registration)
            $settings = [Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $settings.MaxCharactersInDocument = 1MB
            $bytes = [Convert]::FromBase64String($Manifest.data_base64)
            $stream = [IO.MemoryStream]::new($bytes,$false)
            $reader = $null
            try {
                $reader = [Xml.XmlReader]::Create($stream,$settings)
                $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver=$null; $xml.Load($reader)
                $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
                $ns.AddNamespace('f','http://schemas.microsoft.com/appx/manifest/foundation/windows10')
                $ns.AddNamespace('u','http://schemas.microsoft.com/appx/manifest/uap/windows10')
                $ns.AddNamespace('u3','http://schemas.microsoft.com/appx/manifest/uap/windows10/3')
                $ids = $xml.SelectNodes('/f:Package/f:Identity',$ns)
                $apps = $xml.SelectNodes('/f:Package/f:Applications/f:Application[@Id="Global.DesktopSpotlight"]',$ns)
                if ($ids.Count -ne 1 -or $apps.Count -ne 1) { return $false }
                $id = $ids[0];$app=$apps[0]
                if ($id.GetAttribute('Name') -cne $Registration.name -or $id.GetAttribute('Publisher') -cne $Registration.publisher -or
                    $id.GetAttribute('Version') -cne $Registration.version -or $id.GetAttribute('ProcessorArchitecture') -cne $Registration.architecture -or
                    $id.GetAttribute('ResourceId') -cne '') { return $false }
                $expected = @{
                    'DesktopSpotlight.BackgroundTask.UpdateTimer'='timer'
                    'DesktopSpotlight.BackgroundTask.RegistrationStatusCheck'='systemEvent'
                    'DesktopSpotlight.BackgroundTask.OnlineIdChange'='systemEvent'
                    'DesktopSpotlight.BackgroundTask.Maintenance'='systemEvent'
                }
                $tasks = $app.SelectNodes('f:Extensions/f:Extension[@Category="windows.backgroundTasks"]',$ns)
                if ($tasks.Count -ne 4) { return $false }
                foreach ($task in $tasks) {
                    $entry=$task.GetAttribute('EntryPoint')
                    $types=$task.SelectNodes('f:BackgroundTasks/f:Task',$ns)
                    if (-not $expected.ContainsKey($entry) -or $types.Count -ne 1 -or
                        $types[0].GetAttribute('Type') -cne $expected[$entry]) { return $false }
                    $expected.Remove($entry)
                }
                $service = $app.SelectNodes('f:Extensions/u:Extension[@Category="windows.appService"]',$ns)
                $names = $app.SelectNodes('f:Extensions/u:Extension[@Category="windows.appService"]/u3:AppService',$ns)
                $service.Count -eq 1 -and $service[0].GetAttribute('EntryPoint') -ceq 'DesktopSpotlight.BackgroundTask.AppService' -and
                    $names.Count -eq 1 -and $names[0].GetAttribute('Name') -ceq 'com.microsoft.desktopspotlight'
            } finally { if ($null -ne $reader) {$reader.Dispose()};$stream.Dispose() }
        }
        function global:Read-DrVmBoundedOrdinaryBytes {
            param([Parameter(Mandatory)][string] $Path,[Parameter(Mandatory)][ValidateRange(0,2097152)][int] $MaximumBytes,
                [long] $ExpectedBytes = -1)
            $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Preflight input or output is not an ordinary file.'
            }
            $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {
                $length=$stream.Length
                if ($length -gt $MaximumBytes -or ($ExpectedBytes -ge 0 -and $length -ne $ExpectedBytes)) {
                    throw 'Preflight byte length exceeds or mismatches its bound.'
                }
                $bytes=[byte[]]::new([int]$length);$offset=0
                while ($offset -lt $bytes.Length) {
                    $count=$stream.Read($bytes,$offset,$bytes.Length-$offset)
                    if($count -le 0){throw 'Preflight file ended early.'};$offset+=$count
                }
                if($stream.ReadByte() -ne -1 -or $stream.Length -ne $length){throw 'Preflight file changed length.'}
                return ,$bytes
            } finally {$stream.Dispose()}
        }
        function global:Read-DrVmVerifiedPreflightLoaderBytes {
            param([Parameter(Mandatory)][string] $Path,[Parameter(Mandatory)][object] $Record)
            if($Record.bytes -lt 1 -or $Record.bytes -gt 2MB){throw 'Registration preflight loader bound is invalid.'}
            $bytes=Read-DrVmBoundedOrdinaryBytes -Path $Path -MaximumBytes 2MB -ExpectedBytes $Record.bytes
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}
            finally{$sha.Dispose()}
            if($hash -cne $Record.sha256){throw 'Registration preflight loader hash mismatch.'}
            return ,$bytes
        }
        function global:Get-DrVmSpotlightCurrentRegistration {
            param([Parameter(Mandatory)][string] $PackageFullName)
            Initialize-DrVmSpotlightNative
            [DrVmSpotlightNative]::Package($PackageFullName)
        }
        function global:Get-DrVmSpotlightBrokerEvidence {
            param([object] $Candidate,[object] $Capture,[object] $Preflight,[string] $UserSid,[int] $SessionId)
            $held = $Capture.lifetimes[[string]$Candidate.identity].owner
            if ($Capture.failed -or $Capture.observations.Count -ne 1 -or
                -not (Test-DrVmSpotlightNativeIdentity -Native $held.Identity -Candidate $Candidate -UserSid $UserSid -SessionId $SessionId)) { throw 'DesktopSpotlight initial capture was not a complete singleton.' }
            $native = $held.Identity
            if ($native['package_first_status'] -ne 122 -or $native['package_status'] -ne 0 -or
                $native['aumid_first_status'] -ne 122 -or $native['aumid_status'] -ne 0 -or
                $native['aumid'] -cne 'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!Global.DesktopSpotlight' -or
                -not (Test-DrVmCanonicalSystemBinaryPath -Path $Candidate.executable_path -Leaf 'backgroundTaskHost.exe')) { throw 'DesktopSpotlight native application identity was not authenticated.' }
            # Retain first-snapshot metadata with the held lifetime; the child may
            # already have exited before slow owner/signature inventories finish.
            $process=$Capture.lifetimes[[string]$Candidate.identity].process
            if ($null -eq $process) { throw 'DesktopSpotlight initial CIM metadata is missing.' }
            if (([string]$process.ProcessId+'|'+([datetime]$process.CreationDate).ToUniversalTime().ToString('o')) -cne $Candidate.identity) { throw 'DesktopSpotlight PID was reused.' }
            $args=[string[]](Get-DrVmCommandLineArguments -CommandLine $process.CommandLine)
            if ($args.Count -ne 2 -or $args[0] -ine $Candidate.executable_path -or
                $args[1] -cne '-ServerName:Global.DesktopSpotlight.AppXz2j21w56bgxkgsjhtn7zkjsepq96erz2.mca') { throw 'DesktopSpotlight command identity mismatched.' }
            $signature=Get-DrVmAuthenticodeEvidence -Path $Candidate.executable_path
            $parentHeld=$null
            try {
                $parentHeld=Open-DrVmSpotlightLifetime -ProcessId ([uint32]$process.ParentProcessId) -Parent
                $parentMatches=@(Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ParentProcessId)" -OperationTimeoutSec 5 -ErrorAction Stop)
                if ($parentMatches.Count -ne 1) { throw 'DesktopSpotlight parent metadata unavailable.' }
                $parent=$parentMatches[0];$parentCreated=([datetime]$parent.CreationDate).ToUniversalTime().ToString('o')
                $parentRow=[pscustomobject]@{pid=[int]$parent.ProcessId;executable_path=[string]$parent.ExecutablePath;creation_time_utc=$parentCreated}
                if (-not (Test-DrVmSpotlightNativeIdentity -Native $parentHeld.Identity -Candidate $parentRow -UserSid 'S-1-5-18' -SessionId 0) -or
                    [long]$parentHeld.Identity['creation_filetime_100ns'] -gt [long]$native['creation_filetime_100ns'] -or
                    -not (Test-DrVmCanonicalSystemBinaryPath -Path $parentRow.executable_path -Leaf 'svchost.exe')) { throw 'DesktopSpotlight parent native identity mismatched.' }
                $parentArgs=[string[]](Get-DrVmCommandLineArguments -CommandLine $parent.CommandLine)
                $parentSignature=Get-DrVmAuthenticodeEvidence -Path $parentRow.executable_path
                $services=@(Get-CimInstance Win32_Service -Filter "ProcessId=$($parent.ProcessId)" -OperationTimeoutSec 5 -ErrorAction Stop)
                if ($services.Count -gt 64) { throw 'Parent service inventory exceeded its bound.' }
                $dcom=@($services|Where-Object { $_.Name -ceq 'DcomLaunch' -and $_.State -ceq 'Running' })
                if ($dcom.Count -ne 1 -or $parentHeld.Poll()['wait_result'] -ne 258) { throw 'DcomLaunch parent was not uniquely running.' }
                $current=Get-DrVmSpotlightCurrentRegistration -PackageFullName $native['package_full_name']
                if (-not (Test-DrVmSpotlightRegistration -Preflight $Preflight -Current $current -Native $native -UserSid $UserSid)) { throw 'DesktopSpotlight current registration mismatched its preflight.' }
                $manifest=Get-DrVmSpotlightManifest -InstallLocation $Preflight.install_location
                if (-not (Test-DrVmSpotlightManifestIdentity -Manifest $manifest -Registration $Preflight)) { throw 'DesktopSpotlight protected manifest application mismatched.' }
                $broker=[ordered]@{
                    windows_directory=[IO.Path]::GetFullPath($env:windir).TrimEnd('\')
                    process_identity=[string]$Candidate.identity;process_pid=[int]$Candidate.pid
                    process_creation_time_utc=[string]$Candidate.creation_time_utc;process_session_id=$SessionId
                    process_owner_sid=$UserSid;process_executable_path=[string]$Candidate.executable_path;process_path_verified=$true
                    process_command_line_arguments=@($args);process_signature_status=$signature.status
                    process_signer_subject=$signature.signer_subject;process_signer_thumbprint=$signature.signer_thumbprint
                    parent_identity=([string]$parent.ProcessId+'|'+$parentCreated);parent_pid=[int]$parent.ProcessId
                    parent_creation_time_utc=$parentCreated;parent_session_id=[int]$parent.SessionId
                    parent_owner_sid='S-1-5-18';parent_executable_path=$parentRow.executable_path;parent_path_verified=$true
                    parent_command_line_arguments=@($parentArgs);parent_signature_status=$parentSignature.status
                    parent_signer_subject=$parentSignature.signer_subject;parent_signer_thumbprint=$parentSignature.signer_thumbprint
                    service_name=[string]$dcom[0].Name;service_process_id=[int]$dcom[0].ProcessId;service_state=[string]$dcom[0].State
                    native_identity=$native;parent_native_identity=$parentHeld.Identity
                    registration=[ordered]@{preflight=$Preflight;current=$current};manifest=$manifest
                }
                # Reuse every existing parent and signature predicate without changing SmartScreen.
                $screen=[ordered]@{};foreach($key in $broker.Keys){$screen[$key]=$broker[$key]}
                $screen.process_executable_path=$broker.windows_directory+'\System32\smartscreen.exe'
                $screen.process_command_line_arguments=@($screen.process_executable_path,'-Embedding')
                if (-not (Test-DrVmSmartScreenBrokerEvidence -Evidence $screen -UserSid $UserSid -SessionId $SessionId -CandidateIdentity $Candidate.identity)) { throw 'DesktopSpotlight signed service broker failed authentication.' }
                $broker
            } finally {
                if ($null -ne $parentHeld) {
                    $parentHeld.Dispose()
                    if (-not $parentHeld.Closed -or $parentHeld.CloseError -ne 0) { throw 'DesktopSpotlight parent handle close failed.' }
                }
            }
        }
        function global:Get-DrVmRunnerProcesses {
            param(
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId,
                [AllowNull()][object] $CaptureContext = $null,
                [switch] $IncludeExecutionScope
            )
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $rows = [Collections.Generic.List[object]]::new()
                $complete = $true
                $sessionProcesses = @()
                try {
                    $sessionProcesses = @(Get-CimInstance Win32_Process `
                        -Filter "SessionId=$SessionId" -OperationTimeoutSec 5 -ErrorAction Stop)
                }
                catch {
                    $complete = $false
                }
                # Open only new canonical targets before any potentially slow owner query.
                if ($null -ne $CaptureContext) {
                    foreach ($process in $sessionProcesses) {
                        if ([string]$process.ExecutablePath -ieq ($env:windir.TrimEnd('\') + '\System32\backgroundTaskHost.exe')) {
                            Add-DrVmSpotlightInitialObservation -Context $CaptureContext -Process $process -Attempt $attempt
                        }
                    }
                }
                foreach ($process in $sessionProcesses) {
                    $created = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o')
                    $identity = [string]$process.ProcessId + '|' + $created
                    $owner = $null
                    try {
                        if ($null -ne $CaptureContext -and $CaptureContext.lifetimes.ContainsKey($identity)) {
                            $entry = $CaptureContext.lifetimes[$identity]
                            $held = if ($null -ne $entry.PSObject.Properties['owner']) { $entry.owner } else { $entry }
                            if (-not (Test-DrVmSpotlightNativeIdentity -Native $held.Identity -Candidate ([pscustomobject]@{
                                pid=[int]$process.ProcessId; executable_path=[string]$process.ExecutablePath
                                creation_time_utc=$created
                            }) -UserSid $UserSid -SessionId $SessionId)) { throw 'Native owner evidence invalid.' }
                            $owner = [pscustomobject]@{ReturnValue=0; Sid=$held.Identity['owner_sid']}
                        } else {
                            $owner = Invoke-CimMethod -InputObject $process `
                                -MethodName GetOwnerSid -OperationTimeoutSec 5 -ErrorAction Stop
                        }
                    }
                    catch {
                        $complete = $false
                        continue
                    }
                    if ($owner.ReturnValue -ne 0) {
                        $complete = $false
                        continue
                    }
                    if ($owner.Sid -ceq $UserSid) {
                        $created = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o')
                        $record = [ordered]@{
                            identity = ([string]$process.ProcessId + '|' + $created)
                            pid = [int]$process.ProcessId
                            session_id = [int]$process.SessionId
                            creation_time_utc = $created
                            executable_path = [string]$process.ExecutablePath
                        }
                        if ($IncludeExecutionScope) {
                            $commandLine = [string]$process.CommandLine
                            if ([string]::IsNullOrWhiteSpace($record.executable_path) -or
                                [string]::IsNullOrWhiteSpace($commandLine) -or
                                $commandLine.Length -gt 4096 -or
                                $null -eq $process.ParentProcessId) {
                                $complete = $false
                                continue
                            }
                            $record['command_line'] = $commandLine
                            $record['parent_pid'] = [int]$process.ParentProcessId
                            $record['owner_sid'] = [string]$owner.Sid
                        }
                        $rows.Add([pscustomobject]$record)
                    }
                }
                if ($null -ne $CaptureContext) {
                    foreach ($row in $rows) {
                        if (-not $CaptureContext.baseline.Contains($row.identity)) { $CaptureContext.initial_rows[$row.identity] = $row }
                    }
                    foreach ($row in $CaptureContext.initial_rows.Values) {
                        if (@($rows | Where-Object identity -CEQ $row.identity).Count -eq 0) { $rows.Add($row) }
                    }
                }
                $snapshot = [pscustomobject]@{
                    complete = $complete
                    processes = @($rows.ToArray() | Sort-Object identity)
                    attempts = $attempt
                }
                if ($complete) { return $snapshot }
                if ($attempt -lt 3) { Start-Sleep -Milliseconds 200 }
            }
            $snapshot
        }
        function global:Get-DrVmCommandLineArguments {
            param([Parameter(Mandatory)][string] $CommandLine)

            if ($CommandLine.Length -lt 1 -or $CommandLine.Length -gt 4096) {
                throw 'A process command line is unavailable or exceeds its bound.'
            }
            if ($null -eq ('DrVmCommandLineNative' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DrVmCommandLineNative {
    [DllImport("shell32.dll", EntryPoint = "CommandLineToArgvW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

    [DllImport("kernel32.dll", EntryPoint = "LocalFree", SetLastError = true)]
    public static extern IntPtr LocalFree(IntPtr memory);
}
'@ -ErrorAction Stop
            }
            $argumentCount = 0
            $argumentVector = [DrVmCommandLineNative]::CommandLineToArgvW(
                $CommandLine, [ref]$argumentCount)
            if ($argumentVector -eq [IntPtr]::Zero -or
                $argumentCount -lt 1 -or $argumentCount -gt 64) {
                if ($argumentVector -ne [IntPtr]::Zero) {
                    [void][DrVmCommandLineNative]::LocalFree($argumentVector)
                }
                throw 'A process command line could not be parsed within its bound.'
            }
            $arguments = [Collections.Generic.List[string]]::new()
            try {
                for ($index = 0; $index -lt $argumentCount; $index++) {
                    $argument = [Runtime.InteropServices.Marshal]::ReadIntPtr(
                        $argumentVector, $index * [IntPtr]::Size)
                    $arguments.Add([Runtime.InteropServices.Marshal]::PtrToStringUni($argument))
                }
            }
            finally { [void][DrVmCommandLineNative]::LocalFree($argumentVector) }
            return ,([string[]]$arguments.ToArray())
        }
        function global:Test-DrVmCanonicalSystemBinaryPath {
            param(
                [Parameter(Mandatory)][string] $Path,
                [Parameter(Mandatory)][ValidateSet('smartscreen.exe', 'svchost.exe', 'backgroundTaskHost.exe')][string] $Leaf
            )

            try {
                $windowsDirectory = [IO.Path]::GetFullPath([string]$env:windir).TrimEnd('\')
                if ([string]::IsNullOrWhiteSpace($windowsDirectory) -or
                    -not [string]::Equals(
                        [IO.Path]::GetFullPath($Path),
                        (Join-Path (Join-Path $windowsDirectory 'System32') $Leaf),
                        [StringComparison]::OrdinalIgnoreCase)) {
                    return $false
                }
                $entryPaths = [Collections.Generic.List[string]]::new()
                $cursor = [IO.Path]::GetPathRoot($windowsDirectory)
                $entryPaths.Add($cursor)
                foreach ($segment in $windowsDirectory.Substring($cursor.Length).Split('\')) {
                    if ([string]::IsNullOrWhiteSpace($segment)) { return $false }
                    $cursor = Join-Path $cursor $segment
                    $entryPaths.Add($cursor)
                }
                $cursor = Join-Path $cursor 'System32'
                $entryPaths.Add($cursor)
                $systemBinaryPath = Join-Path $cursor $Leaf
                $entryPaths.Add($systemBinaryPath)
                foreach ($entryPath in $entryPaths) {
                    $entry = Get-Item -LiteralPath $entryPath -Force -ErrorAction Stop
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        return $false
                    }
                    if ($entryPath -ceq $systemBinaryPath) {
                        if ($entry.PSIsContainer) { return $false }
                    }
                    elseif (-not $entry.PSIsContainer) { return $false }
                }
                return $true
            }
            catch { return $false }
        }
        function global:Get-DrVmAuthenticodeEvidence {
            param([Parameter(Mandatory)][string] $Path)

            $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
            if ($null -eq $signature -or [string]$signature.Status -cne 'Valid' -or
                $null -eq $signature.SignerCertificate) {
                throw 'A broker executable does not have a valid Authenticode signature.'
            }
            [pscustomobject]@{
                status = [string]$signature.Status
                signer_subject = [string]$signature.SignerCertificate.Subject
                signer_thumbprint = ([string]$signature.SignerCertificate.Thumbprint).ToUpperInvariant()
            }
        }
        function global:Test-DrVmSmartScreenBrokerEvidence {
            param(
                [Parameter(Mandatory)][object] $Evidence,
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId,
                [Parameter(Mandatory)][string] $CandidateIdentity
            )

            try {
                $windowsDirectory = ([string]$Evidence.windows_directory).TrimEnd('\')
                $systemDirectory = $windowsDirectory + '\System32'
                $createdPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
                $publisherPattern = '^CN=Microsoft Windows(?: Publisher)?, O=Microsoft Corporation(?:,|$)'
                if ($Evidence.process_identity -cne $CandidateIdentity -or
                    $Evidence.process_pid -isnot [int] -or
                    $Evidence.process_session_id -ne $SessionId -or
                    [string]$Evidence.process_owner_sid -cne $UserSid -or
                    $Evidence.process_path_verified -isnot [bool] -or
                    -not $Evidence.process_path_verified -or
                    [string]$Evidence.process_executable_path -ine
                        ($systemDirectory + '\smartscreen.exe') -or
                    [string]$Evidence.process_signature_status -cne 'Valid' -or
                    [string]$Evidence.process_signer_subject -cnotmatch $publisherPattern -or
                    [string]$Evidence.process_signer_thumbprint -cnotmatch '^[0-9A-F]{40}$' -or
                    [string]$Evidence.process_creation_time_utc -cnotmatch $createdPattern -or
                    $CandidateIdentity -cne ([string]$Evidence.process_pid + '|' +
                        [string]$Evidence.process_creation_time_utc)) {
                    return $false
                }
                $processArguments = [string[]]$Evidence.process_command_line_arguments
                if ($processArguments.Count -ne 2 -or
                    $processArguments[0] -ine [string]$Evidence.process_executable_path -or
                    $processArguments[1] -ine '-Embedding') {
                    return $false
                }
                if ($Evidence.parent_pid -isnot [int] -or
                    $Evidence.parent_session_id -ne 0 -or
                    [string]$Evidence.parent_owner_sid -cne 'S-1-5-18' -or
                    $Evidence.parent_path_verified -isnot [bool] -or
                    -not $Evidence.parent_path_verified -or
                    [string]$Evidence.parent_executable_path -ine
                        ($systemDirectory + '\svchost.exe') -or
                    [string]$Evidence.parent_signature_status -cne 'Valid' -or
                    [string]$Evidence.parent_signer_subject -cnotmatch $publisherPattern -or
                    [string]$Evidence.parent_signer_thumbprint -cnotmatch '^[0-9A-F]{40}$' -or
                    [string]$Evidence.parent_creation_time_utc -cnotmatch $createdPattern -or
                    [string]$Evidence.parent_identity -cne ([string]$Evidence.parent_pid + '|' +
                        [string]$Evidence.parent_creation_time_utc) -or
                    [string]$Evidence.parent_creation_time_utc -cgt
                        [string]$Evidence.process_creation_time_utc -or
                    [string]$Evidence.service_name -cne 'DcomLaunch' -or
                    $Evidence.service_process_id -ne $Evidence.parent_pid -or
                    [string]$Evidence.service_state -cne 'Running') {
                    return $false
                }
                $parentArguments = [string[]]$Evidence.parent_command_line_arguments
                if ($parentArguments.Count -lt 3 -or $parentArguments.Count -gt 6 -or
                    $parentArguments[0] -ine [string]$Evidence.parent_executable_path -or
                    $parentArguments[1] -ine '-k' -or $parentArguments[2] -ine 'DcomLaunch') {
                    return $false
                }
                $parentTailValid = $parentArguments.Count -eq 3 -or
                    ($parentArguments.Count -eq 4 -and $parentArguments[3] -ieq '-p') -or
                    ($parentArguments.Count -eq 5 -and
                        $parentArguments[3] -ieq '-s' -and
                        $parentArguments[4] -ieq 'DcomLaunch') -or
                    ($parentArguments.Count -eq 6 -and
                        $parentArguments[3] -ieq '-s' -and
                        $parentArguments[4] -ieq 'DcomLaunch' -and
                        $parentArguments[5] -ieq '-p')
                if (-not $parentTailValid) {
                    return $false
                }
                return $true
            }
            catch { return $false }
        }
        function global:Get-DrVmSmartScreenBrokerEvidence {
            param(
                [Parameter(Mandatory)][object] $Candidate,
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId
            )

            $processId = [int]$Candidate.pid
            $matches = @(Get-CimInstance Win32_Process `
                -Filter "ProcessId=$processId" -OperationTimeoutSec 5 -ErrorAction Stop)
            if ($matches.Count -ne 1) {
                throw 'The SmartScreen candidate process is no longer uniquely observable.'
            }
            $process = $matches[0]
            $created = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o')
            $identity = [string]$process.ProcessId + '|' + $created
            $processPath = [string]$process.ExecutablePath
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid `
                -OperationTimeoutSec 5 -ErrorAction Stop
            $processPathVerified = Test-DrVmCanonicalSystemBinaryPath `
                -Path $processPath -Leaf 'smartscreen.exe'
            if ($identity -cne [string]$Candidate.identity -or
                [int]$process.SessionId -ne $SessionId -or
                [string]$owner.Sid -cne $UserSid -or
                $owner.ReturnValue -ne 0 -or
                -not $processPathVerified) {
                throw 'The SmartScreen candidate process identity did not match its runner delta.'
            }
            $processArguments = [string[]](Get-DrVmCommandLineArguments `
                -CommandLine ([string]$process.CommandLine))
            $processSignature = Get-DrVmAuthenticodeEvidence -Path $processPath

            $parentPid = [int]$process.ParentProcessId
            $parentMatches = @(Get-CimInstance Win32_Process `
                -Filter "ProcessId=$parentPid" -OperationTimeoutSec 5 -ErrorAction Stop)
            if ($parentMatches.Count -ne 1) {
                throw 'The SmartScreen parent process is not uniquely observable.'
            }
            $parent = $parentMatches[0]
            $parentCreated = ([datetime]$parent.CreationDate).ToUniversalTime().ToString('o')
            $parentIdentity = [string]$parent.ProcessId + '|' + $parentCreated
            $parentPath = [string]$parent.ExecutablePath
            $parentOwner = Invoke-CimMethod -InputObject $parent -MethodName GetOwnerSid `
                -OperationTimeoutSec 5 -ErrorAction Stop
            $parentPathVerified = Test-DrVmCanonicalSystemBinaryPath `
                -Path $parentPath -Leaf 'svchost.exe'
            if ($parentOwner.ReturnValue -ne 0 -or -not $parentPathVerified) {
                throw 'The SmartScreen parent identity is not a canonical Windows service host.'
            }
            $parentArguments = [string[]](Get-DrVmCommandLineArguments `
                -CommandLine ([string]$parent.CommandLine))
            $parentSignature = Get-DrVmAuthenticodeEvidence -Path $parentPath
            $services = @(Get-CimInstance Win32_Service `
                -Filter "ProcessId=$parentPid" -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object {
                    [string]$_.Name -ceq 'DcomLaunch' -and [string]$_.State -ceq 'Running'
                })
            if ($services.Count -ne 1) {
                throw 'The SmartScreen parent does not uniquely host the running DcomLaunch service.'
            }
            $evidence = [ordered]@{
                windows_directory = [IO.Path]::GetFullPath([string]$env:windir).TrimEnd('\')
                process_identity = $identity
                process_pid = [int]$process.ProcessId
                process_creation_time_utc = $created
                process_session_id = [int]$process.SessionId
                process_owner_sid = [string]$owner.Sid
                process_executable_path = $processPath
                process_path_verified = [bool]$processPathVerified
                process_command_line_arguments = @($processArguments)
                process_signature_status = $processSignature.status
                process_signer_subject = $processSignature.signer_subject
                process_signer_thumbprint = $processSignature.signer_thumbprint
                parent_identity = $parentIdentity
                parent_pid = [int]$parent.ProcessId
                parent_creation_time_utc = $parentCreated
                parent_session_id = [int]$parent.SessionId
                parent_owner_sid = [string]$parentOwner.Sid
                parent_executable_path = $parentPath
                parent_path_verified = [bool]$parentPathVerified
                parent_command_line_arguments = @($parentArguments)
                parent_signature_status = $parentSignature.status
                parent_signer_subject = $parentSignature.signer_subject
                parent_signer_thumbprint = $parentSignature.signer_thumbprint
                service_name = [string]$services[0].Name
                service_process_id = [int]$services[0].ProcessId
                service_state = [string]$services[0].State
            }
            if (-not (Test-DrVmSmartScreenBrokerEvidence `
                -Evidence $evidence `
                -UserSid $UserSid `
                -SessionId $SessionId `
                -CandidateIdentity ([string]$Candidate.identity))) {
                throw 'The SmartScreen process failed its exact broker identity contract.'
            }
            $evidence
        }
        function global:Wait-DrVmSmartScreenNaturalExit {
            param(
                [Parameter(Mandatory)][string] $UserSid,
                [Parameter(Mandatory)][int] $SessionId,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $BaselineProcessIdentities,
                [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $BaselineTasks,
                [Parameter(Mandatory)][string] $CandidateIdentity,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $OwnedRootPrefixes,
                [Parameter(Mandatory)][ValidateRange(0, 360000)][int] $TimeoutMilliseconds,
                [AllowNull()][object] $NativeCapture = $null
            )

            $baselineProcesses = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase)
            foreach ($identity in $BaselineProcessIdentities) {
                [void]$baselineProcesses.Add([string]$identity)
            }
            $baselineTaskHashes = @{}
            foreach ($task in $BaselineTasks) {
                $baselineTaskHashes[[string]$task.identity] = [string]$task.definition_sha256
            }
            $polls = [Collections.Generic.List[object]]::new()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $status = 'rejected'
            $finalInventoryComplete = $false
            $finalProcessIdentities = @()
            $finalTaskIdentities = @()
            $finalProcessSnapshot = $null
            $finalTaskRows = @()
            $polls.Add([ordered]@{
                elapsed_ms = 0
                inventory_complete = $true
                process_delta_identities = @($CandidateIdentity)
                task_delta_identities = @()
                owned_root_process_count = 0
            })
            while ($true) {
                $processSnapshot = $null
                $taskDelta = @()
                $processDeltaIdentities = @()
                $ownedRootProcesses = @()
                try {
                    if ($null -ne $NativeCapture) {
                        $entry = $NativeCapture.lifetimes[$CandidateIdentity]
                        if ($entry.exit['wait_result'] -ne 0) { $entry.exit = $entry.owner.Poll() }
                        if ($entry.exit['wait_result'] -eq 0 -and
                            (-not $entry.exit['times_succeeded'] -or -not $entry.exit['exit_code_succeeded'])) {
                            throw 'Same-handle exit evidence was incomplete.'
                        }
                    }
                    $processSnapshot = Get-DrVmRunnerProcesses `
                        -UserSid $UserSid -SessionId $SessionId
                    if (-not $processSnapshot.complete) {
                        $status = 'inventory-failed'
                        break
                    }
                    $processDeltaIdentities = @($processSnapshot.processes |
                        Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                        Sort-Object identity | ForEach-Object { [string]$_.identity })
                    $taskRows = @(Get-DrVmRunnerTasks -UserSid $UserSid)
                    $currentTaskHashes = @{}
                    $taskDeltaIdentities = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase)
                    foreach ($task in $taskRows) {
                        $identity = [string]$task.identity
                        if ([string]::IsNullOrWhiteSpace($identity) -or
                            $currentTaskHashes.ContainsKey($identity)) {
                            throw 'The scheduled-task inventory contains an invalid or duplicate identity.'
                        }
                        $currentTaskHashes[$identity] = [string]$task.definition_sha256
                        if (-not $baselineTaskHashes.ContainsKey($identity) -or
                            $currentTaskHashes[$identity] -cne
                                [string]$baselineTaskHashes[$identity]) {
                            [void]$taskDeltaIdentities.Add($identity)
                        }
                    }
                    foreach ($identity in $baselineTaskHashes.Keys) {
                        if (-not $currentTaskHashes.ContainsKey([string]$identity)) {
                            [void]$taskDeltaIdentities.Add([string]$identity)
                        }
                    }
                    $taskDelta = @($taskDeltaIdentities | Sort-Object)
                    $allProcesses = @(Get-CimInstance Win32_Process `
                        -OperationTimeoutSec 5 -ErrorAction Stop)
                    $ownedRootProcesses = @($allProcesses | Where-Object {
                        Test-ProcessExecutableInOwnedRoots `
                            -Path $_.ExecutablePath -Prefixes $OwnedRootPrefixes
                    })
                }
                catch {
                    $status = 'inventory-failed'
                    break
                }
                # A signal obtained after the inventory needs another complete inventory.
                # Do not erase an earlier task/process/owned-root failure to obtain it.
                if ($null -ne $NativeCapture -and $processDeltaIdentities.Count -eq 0 -and
                    $NativeCapture.lifetimes[$CandidateIdentity].exit['wait_result'] -ne 0 -and
                    $taskDelta.Count -eq 0 -and $ownedRootProcesses.Count -eq 0 -and
                    $watch.Elapsed.TotalMilliseconds -lt $TimeoutMilliseconds) {
                    try {
                        $entry = $NativeCapture.lifetimes[$CandidateIdentity]
                        $entry.exit = $entry.owner.Poll()
                        if ($entry.exit['wait_result'] -eq 0) {
                            if (-not $entry.exit['times_succeeded'] -or -not $entry.exit['exit_code_succeeded']) {
                                throw 'Same-handle exit evidence was incomplete after disappearance.'
                            }
                            continue
                        }
                    } catch { $status='inventory-failed'; break }
                }
                $pollElapsed = [int][Math]::Min(
                    [int]::MaxValue, [Math]::Floor($watch.Elapsed.TotalMilliseconds))
                $polls.Add([ordered]@{
                    elapsed_ms = $pollElapsed
                    inventory_complete = $true
                    process_delta_identities = @($processDeltaIdentities)
                    task_delta_identities = @($taskDelta)
                    owned_root_process_count = [int]$ownedRootProcesses.Count
                })
                $finalInventoryComplete = $true
                $finalProcessIdentities = @($processDeltaIdentities)
                $finalTaskIdentities = @($taskDelta)
                $finalProcessSnapshot = $processSnapshot
                $finalTaskRows = @($taskRows)
                if ($watch.Elapsed.TotalMilliseconds -ge $TimeoutMilliseconds) {
                    $status = 'timed-out'
                    break
                }
                if ($taskDelta.Count -ne 0 -or $ownedRootProcesses.Count -ne 0 -or
                    $processDeltaIdentities.Count -gt 1 -or
                    ($processDeltaIdentities.Count -eq 1 -and
                        $processDeltaIdentities[0] -cne $CandidateIdentity)) {
                    $status = 'rejected'
                    break
                }
                if ($processDeltaIdentities.Count -eq 0) {
                    if ($null -ne $NativeCapture -and $NativeCapture.lifetimes[$CandidateIdentity].exit['wait_result'] -ne 0) {
                        $status = 'inventory-failed'; break
                    }
                    $status = 'natural-exit'
                    break
                }
                if ($watch.Elapsed.TotalMilliseconds -ge $TimeoutMilliseconds) {
                    $status = 'timed-out'
                    break
                }
                if ($polls.Count -ge 362) { $status = 'timed-out'; break }
                $remaining = $TimeoutMilliseconds - [int][Math]::Floor($watch.Elapsed.TotalMilliseconds)
                Start-Sleep -Milliseconds ([Math]::Min(1000, [Math]::Max(1, $remaining)))
            }
            $watch.Stop()
            [pscustomobject]@{
                status = $status
                timeout_ms = $TimeoutMilliseconds
                elapsed_ms = [int][Math]::Min(
                    [int]::MaxValue, [Math]::Floor($watch.Elapsed.TotalMilliseconds))
                polls = @($polls.ToArray())
                natural_exit_observed = ($status -ceq 'natural-exit')
                final_inventory_complete = $finalInventoryComplete
                final_runner_process_delta_identities = @($finalProcessIdentities)
                final_runner_task_delta_identities = @($finalTaskIdentities)
                final_process_snapshot = $finalProcessSnapshot
                final_task_rows = @($finalTaskRows)
            }
        }

        [pscustomobject]@{
            guest_root = $path
            trusted_task_root = Join-Path $base ($name + '-trusted')
        }
    }
    $guestRoot = [string]$workspaceRoots.guest_root
    $trustedTaskRoot = [string]$workspaceRoots.trusted_task_root
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
            $global:DrVmToolingManifestSha256 = ([string]$manifestSha256).ToLowerInvariant()
            $global:DrVmToolingRecords = @($records | ForEach-Object {
                [pscustomobject]@{
                    role = [string]$_.role
                    file = [string]$_.file
                    sha256 = ([string]$_.sha256).ToLowerInvariant()
                    bytes = [long]$_.bytes
                }
            })
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
    if ($runtimeBrokerEnabled) {
        [void](Get-DrRuntimeBrokerControllerRemainingSeconds -Clock $runtimeBrokerClock -BudgetSeconds $RuntimeBrokerDiagnosticBudgetSeconds -ReserveSeconds 420)
    }
    Write-DrDiagnosticPhase -Phase 'cbs-registration-preflight' -State 'begin'
    # A narrow, fully owned PS5 registration query finishes before either baseline.
    $spotlightPreflightJson = @(Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$ownedV2 -ScriptBlock {
        param($root,$sid,$v2)
        $loaderRecord=@($global:DrVmToolingRecords|Where-Object role -CEQ 'powershell-loader')
        if ($loaderRecord.Count -ne 1) { throw 'Registration preflight loader binding is missing.' }
        $loaderPath=Join-Path $root $loaderRecord[0].file
        $loaderBytes=Read-DrVmVerifiedPreflightLoaderBytes -Path $loaderPath -Record $loaderRecord[0]
        $loaderModule=$null;$guestModule=$null
        try {
            $loaderOffset=if($loaderBytes.Length -ge 3 -and $loaderBytes[0] -eq 0xef -and $loaderBytes[1] -eq 0xbb -and $loaderBytes[2] -eq 0xbf){3}else{0}
            $loaderText=[Text.UTF8Encoding]::new($false,$true).GetString($loaderBytes,$loaderOffset,$loaderBytes.Length-$loaderOffset)
            $loaderModule=New-Module -Name ('DarkReNamer.preflight.loader.'+[guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($loaderText))
            $verified=& $loaderModule {
                param($r,$h)
                Get-DrToolingVerifiedBundle -Root $r -ManifestLocation 'tooling-bundle.json' -ExpectedManifestSha256 $h -Mode bundle -RequiredRoles @('powershell-guest-entry')
            } $root $global:DrVmToolingManifestSha256
            $roles=@('powershell-guest-contracts','powershell-guest-process','powershell-guest-native','powershell-guest-platform',
                'powershell-guest-uia','powershell-guest-state','powershell-guest-scenario','powershell-guest-runtime')
            $libraries=@{}
            foreach($role in $roles){$libraries[$role]=& $loaderModule {param($v,$r) New-DrToolingVerifiedScriptBlock -VerifiedBundle $v -Role $r} $verified $role}
            $entry=& $loaderModule {param($v) New-DrToolingVerifiedScriptBlock -VerifiedBundle $v -Role 'powershell-guest-entry'} $verified
            $guestModule=New-Module -Name ('DarkReNamer.preflight.guest.'+[guid]::NewGuid().ToString('N')) -ScriptBlock $entry -ArgumentList (,$libraries)
            & $guestModule {
                param($r,$expectedSid,$v2)
                $ps5=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (-not (Test-Path -LiteralPath $ps5 -PathType Leaf)) { throw 'Registration preflight requires native Windows PowerShell 5.1.' }
                $command=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$items=@(Get-AppxPackage -Name MicrosoftWindows.Client.CBS)
if($items.Count -gt 1){throw 'CBS registration is ambiguous.'}
if($items.Count -eq 0){'null';exit 0}
$p=$items[0]
[ordered]@{name=[string]$p.Name;package_full_name=[string]$p.PackageFullName;package_family_name=[string]$p.PackageFamilyName;
publisher=[string]$p.Publisher;publisher_id=[string]$p.PublisherId;version=[string]$p.Version;architecture=([string]$p.Architecture).ToLowerInvariant();
resource_id=[string]$p.ResourceId;install_location=[string]$p.InstallLocation;signature_kind=[string]$p.SignatureKind;status=[string]$p.Status;
is_development_mode=[bool]$p.IsDevelopmentMode}|ConvertTo-Json -Compress
'@
                $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                $stdout=Join-Path $r 'cbs-preflight.stdout.json';$stderr=Join-Path $r 'cbs-preflight.stderr.txt'
                $state=$null;$closed=$false;$record=$null;$childLifecycle=$null
                try {
                    $state=Start-JobBoundProcess -FilePath $ps5 -Arguments ('-NoLogo -NoProfile -NonInteractive -EncodedCommand '+$encoded) `
                        -WorkingDirectory $r -StdoutPath $stdout -StderrPath $stderr -SingleProcessOnly -AggregateOutputLimitBytes 65536
                    $wait=Wait-JobBoundProcessWithOutputLimit -State $state -StdoutPath $stdout -StderrPath $stderr -TimeoutSeconds 30
                    if ($wait.failure_reason -or -not $state.process.HasExited -or $state.process.ExitCode -ne 0) { throw 'CBS registration preflight failed.' }
                    $state.owner.WaitForCapture(10000)
                    $closed=Close-JobBoundProcess -State $state
                    if (-not $closed -or $state.owner.OutputLimitExceeded) { throw 'CBS registration preflight job or streams did not close.' }
                    $nativePid=$state.process.Id;$ticks=$state.process_start_time_utc_ticks
                    $remaining=Get-Process -Id $nativePid -ErrorAction SilentlyContinue
                    try {
                        if ($null -ne $remaining -and $remaining.StartTime.ToUniversalTime().Ticks.ToString() -ceq $ticks) { throw 'CBS registration preflight exact child lifetime remains.' }
                    } finally { if($null -ne $remaining){$remaining.Dispose()} }
                    $stdoutBytes=Read-DrVmBoundedOrdinaryBytes -Path $stdout -MaximumBytes 65536
                    $stderrBytes=Read-DrVmBoundedOrdinaryBytes -Path $stderr -MaximumBytes 0
                    $record=[Text.UTF8Encoding]::new($false,$true).GetString($stdoutBytes)|ConvertFrom-Json
                    $childLifecycle = [ordered]@{
                        pid=$nativePid;start_time_utc_ticks=$ticks;exit_code=$state.process.ExitCode
                        exited=$true;streams_complete=$true;exact_lifetime_absent=$true;process_job_closed=$closed
                    }
                    if($null -ne $record){
                        $record|Add-Member -NotePropertyName runner_sid -NotePropertyValue $expectedSid
                        $record|Add-Member -NotePropertyName child_lifecycle -NotePropertyValue $childLifecycle
                    }
                } finally {
                    if ($null -ne $state) {
                        try { if(-not $closed){[void](Close-JobBoundProcess -State $state)} }
                        finally {$state.owner.Dispose()}
                    }
                }
                $engineRecord=$null;$engineChild=$null
                if ($v2) {
                    $powerShell=Get-DrVmTrustedPowerShellPath
                    $engineCommand='[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
                    $engineEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($engineCommand))
                    $engineStdout=Join-Path $r 'engine-preflight.stdout.json'
                    $engineStderr=Join-Path $r 'engine-preflight.stderr.txt'
                    $engineState=$null;$engineClosed=$false
                    try {
                        $engineState=Start-JobBoundProcess -FilePath $powerShell `
                            -Arguments ('-NoLogo -NoProfile -NonInteractive -EncodedCommand '+$engineEncoded) `
                            -WorkingDirectory $r -StdoutPath $engineStdout -StderrPath $engineStderr `
                            -SingleProcessOnly -AggregateOutputLimitBytes 65536
                        $engineWait=Wait-JobBoundProcessWithOutputLimit -State $engineState `
                            -StdoutPath $engineStdout -StderrPath $engineStderr -TimeoutSeconds 30
                        if ($engineWait.failure_reason -or -not $engineState.process.HasExited -or
                            $engineState.process.ExitCode -ne 0) { throw 'V2 PowerShell engine preflight failed.' }
                        $engineState.owner.WaitForCapture(10000)
                        $engineClosed=Close-JobBoundProcess -State $engineState
                        if (-not $engineClosed -or $engineState.owner.OutputLimitExceeded) {
                            throw 'V2 PowerShell engine Job or streams did not close.'
                        }
                        $enginePid=$engineState.process.Id
                        $engineTicks=$engineState.process_start_time_utc_ticks
                        $remaining=Get-Process -Id $enginePid -ErrorAction SilentlyContinue
                        try {
                            if ($null -ne $remaining -and
                                $remaining.StartTime.ToUniversalTime().Ticks.ToString() -ceq $engineTicks) {
                                throw 'V2 PowerShell engine child lifetime remains.'
                            }
                        } finally { if ($null -ne $remaining) { $remaining.Dispose() } }
                        $engineBytes=Read-DrVmBoundedOrdinaryBytes -Path $engineStdout -MaximumBytes 65536
                        $null=Read-DrVmBoundedOrdinaryBytes -Path $engineStderr -MaximumBytes 0
                        $engineRecord=[Text.UTF8Encoding]::new($false,$true).GetString($engineBytes)|ConvertFrom-Json
                        $engineChild=[ordered]@{
                            pid=$enginePid;start_time_utc_ticks=$engineTicks;exit_code=$engineState.process.ExitCode
                            exited=$true;streams_complete=$true;exact_lifetime_absent=$true;process_job_closed=$engineClosed
                        }
                    } finally {
                        if ($null -ne $engineState) {
                            try { if (-not $engineClosed) { [void](Close-JobBoundProcess -State $engineState) } }
                            finally { $engineState.owner.Dispose() }
                        }
                    }
                }
                # Serialize before remoting can annotate the registration object.
                if ($v2) {
                    [ordered]@{ schema_version=2; registration=$record; child_lifecycle=$childLifecycle
                        engine=$engineRecord; engine_child=$engineChild } |
                        ConvertTo-Json -Depth 8 -Compress
                }
                else { $record | ConvertTo-Json -Depth 8 -Compress }
            } $root $sid $v2
        } finally {
            if($null -ne $guestModule){Remove-Module -ModuleInfo $guestModule -Force -ErrorAction Stop}
            if($null -ne $loaderModule){Remove-Module -ModuleInfo $loaderModule -Force -ErrorAction Stop}
        }
    })
    $preflightDocument = ConvertFrom-DrControllerSpotlightPreflightJson -Values $spotlightPreflightJson
    if ($ownedV2) {
        if ($preflightDocument.schema_version -ne 2 -or
            $null -eq $preflightDocument.child_lifecycle -or
            $null -eq $preflightDocument.engine_child -or
            $null -eq $preflightDocument.engine) {
            throw 'V2 preflight helper lifetimes are unavailable.'
        }
        $spotlightPreflight = $preflightDocument.registration
        $preflightChild = $preflightDocument.child_lifecycle
        $v2Engine = $preflightDocument.engine
        $engineChild = $preflightDocument.engine_child
    }
    else { $spotlightPreflight = $preflightDocument }
    Write-DrDiagnosticPhase -Phase 'cbs-registration-preflight' -State 'end'
    Write-DrDiagnosticPhase -Phase 'acceptance-baseline' -State 'begin'
    $runnerTaskBaseline = @(Invoke-Command -Session $session -ArgumentList $desktop.sid -ScriptBlock {
        param($sid)
        @(Get-DrVmRunnerTasks -UserSid $sid | Sort-Object identity)
    })
    $transport['runner_task_baseline'] = @($runnerTaskBaseline)
    $processSnapshot = Invoke-Command -Session $session -ArgumentList $desktop.sid,$desktop.session_id,$ownedV2 -ScriptBlock {
        param($sid,$sessionId,$v2)
        Get-DrVmRunnerProcesses -UserSid $sid -SessionId $sessionId -IncludeExecutionScope:$v2
    }
    if ($null -eq $processSnapshot -or -not $processSnapshot.complete) {
        throw 'The VM runner process baseline was incomplete; refusing to start an untrackable candidate.'
    }
    $runnerProcessBaseline = @($processSnapshot.processes)
    $transport['runner_process_baseline'] = @($runnerProcessBaseline)
    Write-DrDiagnosticPhase -Phase 'acceptance-baseline' -State 'end' -Details @{ task_count=$runnerTaskBaseline.Count; process_count=$runnerProcessBaseline.Count }
    if ($RuntimeBrokerPreparationOnly) {
        # The preflight child has closed; no candidate task/job has been created.
        $runtimeBrokerPrepared = $true
        $transport.status = 'diagnostic-prepared'
        Write-DrDiagnosticPhase -Phase 'preparation-only-complete'
    } else {
    if ($runtimeBrokerEnabled) {
        $candidateSeconds = Get-DrRuntimeBrokerControllerRemainingSeconds -Clock $runtimeBrokerClock `
            -BudgetSeconds $RuntimeBrokerDiagnosticBudgetSeconds -ReserveSeconds 420
        if ($candidateSeconds -lt $TestTimeoutSeconds) { throw 'Insufficient diagnostic time for the candidate and unchanged cleanup.' }
        $SuiteTimeoutSeconds = [Math]::Min($SuiteTimeoutSeconds, $candidateSeconds)
    }
    Write-DrDiagnosticPhase -Phase 'candidate-task' -State 'begin'

    $trustedBundleRecords = @(
        foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
            $path = Join-Path $BundleRoot $name
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "VM bundle input is not an ordinary file: $name."
            }
            [pscustomobject]@{
                file = [string]$name
                bytes = [long]$item.Length
                sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
    $transport.status = 'copying'
    if ($acceptance) {
        $acceptanceStage = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid -ScriptBlock {
            param($root,$sid)
            $bundle = Join-Path $root 'bundle'
            [void](New-Item -ItemType Directory -Path $bundle)
            $runtime = New-DrVmGuestDirectory -ParentPath $root -Leaf 'runtime' -UserSid $sid
            [pscustomobject]@{ bundle = $bundle; runtime = $runtime }
        }
        $guestBundleRoot = [string]$acceptanceStage.bundle
        $guestRuntimeRoot = [string]$acceptanceStage.runtime
        $inputManifestSha256 = (Get-FileHash -LiteralPath $AcceptanceManifest -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
            $guestPath = Join-GuestWindowsPath -Root $guestBundleRoot -Leaf $name
            Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination $guestPath -ToSession $session
        }
        Copy-Item -LiteralPath (Join-Path $BundleRoot 'windows-vm-acceptance.ps1') -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'windows-vm-acceptance.ps1') -ToSession $session
        Copy-Item -LiteralPath $AcceptanceManifest -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'input-manifest.json') -ToSession $session
        if ($runtimeBrokerEnabled) {
            $candidateSeconds = Get-DrRuntimeBrokerControllerRemainingSeconds -Clock $runtimeBrokerClock `
                -BudgetSeconds $RuntimeBrokerDiagnosticBudgetSeconds -ReserveSeconds 420
            if ($candidateSeconds -lt $TestTimeoutSeconds) { throw 'Insufficient diagnostic time after candidate staging.' }
            $SuiteTimeoutSeconds = [Math]::Min($SuiteTimeoutSeconds, $candidateSeconds)
        }
        $acceptanceEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$observer.sha256,$AcceptanceMode,$AcceptanceAppearance,$AcceptanceTextScalePercent,([bool]$AcceptanceHighContrast),([bool]$AcceptanceClipboard),([bool]$AcceptanceCaptureNativeMenu),([bool]$AcceptanceCaptureAdvancedAppearance),$trustedBundleRecords,$inputManifestSha256,$RuntimeBrokerDiagnosticRunId,$ownedV2,$v2Engine -ScriptBlock {
            param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$observerHash,$mode,$appearance,$textScale,$highContrast,$clipboard,$captureNativeMenu,$captureAdvancedAppearance,$bundleRecords,$inputManifestHash,$runtimeBrokerRunId,$v2,$preflightEngine)
            $observerPath = Join-Path $root 'windows-vm-acceptance.ps1'
            if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) { throw 'Transferred acceptance observer hash mismatch.' }
            $bundle = Join-Path $root 'bundle'
            $out = Join-Path $root 'out'
            $runtime = Join-Path $root 'runtime'
            $inputManifest = Join-Path $root 'input-manifest.json'
            $powerShell = Get-DrVmTrustedPowerShellPath
            if ($v2) { $engine = $preflightEngine }
            else {
                $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
                    '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
                if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell acceptance engine.' }
                $engine = $engineJson | ConvertFrom-Json
            }
            if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
                $engine.effective_policy -cne 'RemoteSigned') {
                throw 'GUI acceptance requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
            }
            $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -RuntimeRoot "' + $runtime + '" -ExpectedScriptSha256 ' + $observerHash + ' -TimeoutSeconds ' + $testTimeout + ' -Appearance ' + $appearance
            if ($mode -cne 'current-dpi') {
                $observerArguments += ' -RegressionMode ' + $mode + ' -InputManifestPath "' + $inputManifest + '" -TextScalePercent ' + $textScale
            }
            else {
                if ($highContrast) { $observerArguments += ' -HighContrast' }
                if ($clipboard) { $observerArguments += ' -Clipboard' }
                if ($captureNativeMenu) { $observerArguments += ' -CaptureNativeMenu' }
                if ($captureAdvancedAppearance) { $observerArguments += ' -CaptureAdvancedAppearance' }
            }
            if ($runtimeBrokerRunId) { $observerArguments += ' -RuntimeBrokerDiagnosticRunId ' + $runtimeBrokerRunId }
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
                -TrustedResultLeaf 'acceptance-result.json' `
                -ExecutionTimeLimitSeconds ($suiteTimeout + 60)
            $actualAction = if ($v2) { $registeredTask.Definition.Actions.Item(1) } else { $null }
            $registered = Get-ScheduledTaskInfo -TaskName $name
            $registeredTicks = [long]$registered.LastRunTime.Ticks
            Start-ScheduledTask -TaskName $name
            [pscustomobject]@{
                executable = 'pwsh.exe'
                version = [string]$engine.version
                edition = [string]$engine.edition
                effective_policy = [string]$engine.effective_policy
                registered_last_run_time_ticks = $registeredTicks
                action_executable = if ($v2) { [string]$actualAction.Path } else { $powerShell }
                action_arguments = if ($v2) { [string]$actualAction.Arguments } else { $observerArguments }
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
                $state = Invoke-Command -Session $session -ArgumentList $trustedTaskRoot,$taskName -ScriptBlock {
                    param($trustedRoot,$name)
                    $info = Get-ScheduledTaskInfo -TaskName $name
                    $task = Get-ScheduledTask -TaskName $name
                    $taskState = $task.State.ToString()
                    $taskResult = [long]$info.LastTaskResult
                    if ($taskState -ceq 'Ready') {
                        $terminalInfo = Get-ScheduledTaskInfo -TaskName $name
                        $taskResult = [long]$terminalInfo.LastTaskResult
                    }
            $file = Join-Path (Join-Path $trustedRoot 'out') 'acceptance-result.json'
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
                if ($runtimeBrokerEnabled) {
                    [void](Get-DrRuntimeBrokerControllerRemainingSeconds -Clock $runtimeBrokerClock `
                        -BudgetSeconds $RuntimeBrokerDiagnosticBudgetSeconds -ReserveSeconds 420)
                }
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
                -BundleRecords $trustedBundleRecords `
                -InputManifestSha256 $inputManifestSha256 `
                -AcceptanceMode $AcceptanceMode `
                -Appearance $AcceptanceAppearance `
                -HighContrast ([bool]$AcceptanceHighContrast) `
                -HostOutputRoot $AcceptanceOutputRoot `
                -AcceptanceProfileId $AcceptanceProfileId `
                -EngineEvidence $v2Engine `
                -OriginalFailure $pollFailure
        }
        Invoke-AcceptanceTerminalFailureRescue -State $state `
            -AcceptanceMode $AcceptanceMode -HighContrast ([bool]$AcceptanceHighContrast) `
            -RescueParameters @{
                Session = $session; GuestRoot = $guestRoot; DesktopSid = $desktop.sid
                DesktopSessionId = $desktop.session_id; TaskName = $taskName
                TestTimeoutSeconds = $TestTimeoutSeconds; SuiteTimeoutSeconds = $SuiteTimeoutSeconds
                ObserverSha256 = $observer.sha256; BundleRecords = $trustedBundleRecords
                InputManifestSha256 = $inputManifestSha256; Appearance = $AcceptanceAppearance
                HostOutputRoot = $AcceptanceOutputRoot
                AcceptanceProfileId = $AcceptanceProfileId; EngineEvidence = $v2Engine
            }
        $inventory = @(Invoke-Command -Session $session -ArgumentList $guestRoot,$trustedTaskRoot -ScriptBlock ${function:Get-DrControllerUiOutputInventory})
        foreach ($output in $inventory) {
            Assert-PlainFile $output.file
            $guestOutputPath = [string]$output.guest_path
            $hostOutputPath = Join-Path $AcceptanceOutputRoot $output.file
            if (Test-Path -LiteralPath $hostOutputPath) {
                $existing = Get-Item -LiteralPath $hostOutputPath -Force -ErrorAction Stop
                if ($existing.PSIsContainer -or
                    ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $existing.Length -ne $output.bytes -or
                    (Get-FileHash -LiteralPath $hostOutputPath -Algorithm SHA256).Hash -ine $output.sha256) {
                    throw 'Acceptance output path already exists on the host with different bytes.'
                }
                continue
            }
            Copy-Item -LiteralPath $guestOutputPath -Destination $hostOutputPath -FromSession $session
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
            $processJobsClosed = Test-DrControllerProcessJobCleanupLedger -Result $result
            if ($ownedV2 -and $state.terminal) {
                $taskExecution = Complete-DrControllerV2TaskExecution `
                    -Session $session -TaskName $taskName -RunnerSid $desktop.sid `
                    -SessionId $desktop.session_id -Engine $acceptanceEngine `
                    -CompletedTicks $state.last_run_time_ticks -TaskResult $state.task_result `
                    -Result $result
            }
        }
        if ($null -ne $result -and $result.status -ceq 'review_required' -and
            $null -eq $pollFailure -and $state.task_result -eq 0) {
            $observationsPath = Join-Path $AcceptanceOutputRoot 'acceptance-observations.json'
            if (-not (Test-Path -LiteralPath $observationsPath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $observationsPath -Algorithm SHA256).Hash -ine
                    $result.observations.sha256) {
                throw 'Collected GUI observations do not match the protected observer result digest.'
            }
            $collectedObservations = Get-Content -LiteralPath $observationsPath -Raw | ConvertFrom-Json
            $trustedObservationJson = $result.acceptance_observations | ConvertTo-Json -Depth 12 -Compress
            $collectedObservationJson = $collectedObservations | ConvertTo-Json -Depth 12 -Compress
            if ($trustedObservationJson -cne $collectedObservationJson) {
                throw 'Collected GUI observations differ from the protected observer result object.'
            }
            $window = $result.acceptance_observations.environment.main_window
            if ($null -eq $window -or [long]$window.hwnd -le 0 -or
                [int]$window.process_id -le 0) {
                throw 'Protected acceptance observations do not identify the launched application window.'
            }
            $actualGuestId = Invoke-Command -Session $session -ScriptBlock {
                ([guid](Get-ItemProperty `
                    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' `
                    -Name VirtualMachineId).VirtualMachineId).ToString('D').ToLowerInvariant()
            }
            $expectedGuestId = ([guid]$ExpectedGuestVmId).ToString('D').ToLowerInvariant()
            if ($actualGuestId -cne $expectedGuestId) {
                throw 'Post-launch Hyper-V Guest Parameters VM identity differs from the private profile.'
            }
            $identityHash = Get-LowerTextSha256 -Value $actualGuestId
            $receipt = [ordered]@{
                schema_version = 1
                run_id = $acceptanceInput.run_id
                input_manifest_sha256 = $inputManifestSha256
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
            $receiptPath = Join-Path $AcceptanceOutputRoot 'platform-postlaunch.json'
            if (Test-Path -LiteralPath $receiptPath) {
                throw 'Host post-launch receipt path already exists.'
            }
            [IO.File]::WriteAllText(
                $receiptPath,
                ($receipt | ConvertTo-Json -Depth 6),
                [Text.UTF8Encoding]::new($false)
            )
        }
        $acceptancePassed = $null -ne $result -and
            $result.status -ceq 'review_required' -and
            $processJobsClosed -and
            $null -eq $pollFailure -and
            $null -ne $observerProcess -and
            $observerProcess.state -ceq 'exited' -and
            $observerProcess.exit_code -eq 0
        if ($null -ne $result) {
            $outputPreservedForCleanup = Test-DrControllerPreservedOutputCleanupAuthorization `
                -Role ui -Result $result -Inventory $inventory -OutputRoot $AcceptanceOutputRoot `
                -ObserverSha256 $observer.sha256 -AcceptanceMode $AcceptanceMode `
                -HighContrastRequested ([bool]$AcceptanceHighContrast) `
                -ProcessJobsClosed $processJobsClosed -ObserverProcess $observerProcess `
                -PollFailure $pollFailure
        }
        $transport.status = 'collected'
    }
    elseif ($recovery) {
        $recoveryStage = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$taskName -ScriptBlock {
            param($root,$sid,$name)
            $bundle = Join-Path $root 'bundle'
            $runtime = New-DrVmGuestDirectory -ParentPath $root -Leaf 'runtime' -UserSid $sid
            $trustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
            $out = Join-Path $trustedRoot 'out'
            $evidenceLeaf = 'recovery-acceptance-' + [Guid]::NewGuid().ToString('N')
            $evidenceRoot = Join-Path $out $evidenceLeaf
            $private = Join-Path $root 'private'
            [void](New-Item -ItemType Directory -Path $bundle)
            [pscustomobject]@{
                bundle = $bundle
                evidence_root = $evidenceRoot
                evidence_leaf = $evidenceLeaf
                runtime = $runtime
            }
        }
        $guestBundleRoot = [string]$recoveryStage.bundle
        $recoveryEvidenceRoot = [string]$recoveryStage.evidence_root
        $recoveryRuntimeRoot = [string]$recoveryStage.runtime
        foreach ($name in @('bundle.json') + @($artifacts | ForEach-Object { $_.file })) {
            $guestPath = Join-GuestWindowsPath -Root $guestBundleRoot -Leaf $name
            Copy-Item -LiteralPath (Join-Path $BundleRoot $name) -Destination $guestPath -ToSession $session
        }
        Copy-Item `
            -LiteralPath (Join-Path $BundleRoot 'windows-vm-recovery-acceptance.ps1') `
            -Destination (Join-GuestWindowsPath -Root $guestRoot -Leaf 'windows-vm-recovery-acceptance.ps1') `
            -ToSession $session
        $recoveryEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$observer.sha256,$RecoveryMode,$RecoveryFixtureCount,([bool]$RecoveryExport),([bool]$RecoveryIntentOnlyCandidateDiscard),$recoveryEvidenceRoot,$trustedBundleRecords,$recoveryRuntimeRoot,$ownedV2,$v2Engine -ScriptBlock {
            param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$observerHash,$mode,$fixtureCount,$recoveryExport,$intentOnlyCandidateDiscard,$evidenceRoot,$bundleRecords,$runtimeRoot,$v2,$preflightEngine)
            $observerPath = Join-Path $root 'windows-vm-recovery-acceptance.ps1'
            if ((Get-FileHash -LiteralPath $observerPath -Algorithm SHA256).Hash -ine $observerHash) {
                throw 'Transferred recovery observer hash mismatch.'
            }
            $bundle = Join-Path $root 'bundle'
            $out = Join-Path $root 'out'
            $private = Join-Path $root 'private'
            $powerShell = Get-DrVmTrustedPowerShellPath
            if ($v2) { $engine = $preflightEngine }
            else {
                $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
                    '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
                if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell recovery engine.' }
                $engine = $engineJson | ConvertFrom-Json
            }
            if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
                $engine.effective_policy -cne 'RemoteSigned') {
                throw 'Recovery acceptance requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
            }
            $observerArguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $observerPath + '" -BundleRoot "' + $bundle + '" -ExpectedSessionId ' + $desktopSession + ' -OutputRoot "' + $out + '" -EvidenceRoot "' + $evidenceRoot + '" -PrivateEvidenceRoot "' + $private + '" -RuntimeRoot "' + $runtimeRoot + '" -ExpectedScriptSha256 ' + $observerHash + ' -Mode ' + $mode + ' -FixtureCount ' + $fixtureCount + ' -TimeoutSeconds ' + $testTimeout
            if ($recoveryExport) { $observerArguments += ' -RecoveryExport' }
            if ($intentOnlyCandidateDiscard) {
                $observerArguments += ' -IntentOnlyCandidateDiscard'
            }
            if ($v2) { $observerArguments += ' -AcceptanceProfileId vm-automated-v2-owned-resources' }
            $registeredTask = Register-DrVmTask `
                -TaskName $name `
                -UserSid $sid `
                -SessionId $desktopSession `
                -GuestRoot $root `
                -RuntimeRoot $runtimeRoot `
                -ObserverPath $observerPath `
                -ObserverSha256 $observerHash `
                -BundleSourcePath $bundle `
                -BundleRecords $bundleRecords `
                -Execute $powerShell `
                -Arguments $observerArguments `
                -WorkingDirectory $root `
                -TrustedResultLeaf 'recovery-summary.json' `
                -OutputDirectoryLeaves @([string](Split-Path -Leaf $evidenceRoot)) `
                -ExecutionTimeLimitSeconds ($suiteTimeout + 60)
            $actualAction = if ($v2) { $registeredTask.Definition.Actions.Item(1) } else { $null }
            $registered = Get-ScheduledTaskInfo -TaskName $name
            $registeredTicks = [long]$registered.LastRunTime.Ticks
            Start-ScheduledTask -TaskName $name
            [pscustomobject]@{
                executable = 'pwsh.exe'
                version = [string]$engine.version
                edition = [string]$engine.edition
                effective_policy = [string]$engine.effective_policy
                registered_last_run_time_ticks = $registeredTicks
                action_executable = if ($v2) { [string]$actualAction.Path } else { $powerShell }
                action_arguments = if ($v2) { [string]$actualAction.Arguments } else { $observerArguments }
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
                $state = Invoke-Command -Session $session -ArgumentList $trustedTaskRoot,$taskName -ScriptBlock {
                    param($trustedRoot,$name)
                    $info = Get-ScheduledTaskInfo -TaskName $name
                    $task = Get-ScheduledTask -TaskName $name
                    $taskState = $task.State.ToString()
                    $taskResult = [long]$info.LastTaskResult
                    if ($taskState -ceq 'Ready') {
                        $terminalInfo = Get-ScheduledTaskInfo -TaskName $name
                        $taskResult = [long]$terminalInfo.LastTaskResult
                    }
                    $summaries = @(
                        Get-Item -LiteralPath (Join-Path (Join-Path $trustedRoot 'out') 'recovery-summary.json') `
                            -Force `
                            -ErrorAction SilentlyContinue |
                            Where-Object {
                                -not $_.PSIsContainer -and
                                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
                            }
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
        $inventory = @(Invoke-Command -Session $session -ArgumentList $guestRoot,$trustedTaskRoot,$recoveryEvidenceRoot -ScriptBlock ${function:Get-DrControllerRecoveryOutputInventory})
        $summaryRows = @($inventory | Where-Object { $_.file -cmatch '(^|/)summary\.json$' })
        if ($summaryRows.Count -ne 1 -or
            $summaryRows[0].file -cnotmatch '^[^/]+/summary\.json$') {
            throw 'Recovery output must contain exactly one session summary.'
        }
        foreach ($output in $inventory) {
            $segments = @(Get-SafeEvidencePathSegments $output.file)
            $guestOutputPath = [string]$output.guest_path
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
        $processJobsClosed = Test-DrControllerProcessJobCleanupLedger `
            -Result $result -RecoveryEvidenceRoot $RecoveryOutputRoot
        if ($ownedV2 -and $state.terminal) {
            $taskExecution = Complete-DrControllerV2TaskExecution `
                -Session $session -TaskName $taskName -RunnerSid $desktop.sid `
                -SessionId $desktop.session_id -Engine $recoveryEngine `
                -CompletedTicks $state.last_run_time_ticks -TaskResult $state.task_result `
                -Result $result
        }
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
            $processJobsClosed -and
            $null -eq $pollFailure -and
            $null -ne $observerProcess -and
            $observerProcess.state -ceq 'exited' -and
            $observerProcess.exit_code -eq 0
        $outputPreservedForCleanup = Test-DrControllerPreservedOutputCleanupAuthorization `
            -Role recovery -Result $result -Inventory $inventory -OutputRoot $RecoveryOutputRoot `
            -ObserverSha256 $observer.sha256 -ProcessJobsClosed $processJobsClosed `
            -ObserverProcess $observerProcess -PollFailure $pollFailure
        $transport.status = 'collected'
    }
    else {
    $guestRuntimeRoot = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid -ScriptBlock {
        param($root,$sid)
        New-DrVmGuestDirectory -ParentPath $root -Leaf 'runtime' -UserSid $sid
    }
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
    $runnerEngine = Invoke-Command -Session $session -ArgumentList $guestRoot,$desktop.sid,$desktop.session_id,$taskName,$TestTimeoutSeconds,$SuiteTimeoutSeconds,$runnerArtifact.sha256,$trustedBundleRecords,$guestRuntimeRoot,$ownedV2,$v2Engine -ScriptBlock {
        param($root,$sid,$desktopSession,$name,$testTimeout,$suiteTimeout,$runnerHash,$bundleRecords,$runtimeRoot,$v2,$preflightEngine)
        $runner = Join-Path $root 'windows-vm-guest.ps1'
        if ((Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash -ine $runnerHash) { throw 'Transferred guest runner hash mismatch.' }
        $powerShell = Get-DrVmTrustedPowerShellPath
        if ($v2) { $engine = $preflightEngine }
        else {
            $engineJson = & $powerShell -NoLogo -NoProfile -NonInteractive -Command `
                '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress'
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the configured PowerShell guest engine.' }
            $engine = $engineJson | ConvertFrom-Json
        }
        if ([version]$engine.version -lt [version]'7.4' -or $engine.edition -cne 'Core' -or
            $engine.effective_policy -cne 'RemoteSigned') {
            throw 'Native VM validation requires the configured PowerShell 7.4+ Core engine under its existing RemoteSigned policy.'
        }
        $expectedRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $root 'runtime'))
        if (-not [string]::Equals(
                [IO.Path]::GetFullPath($runtimeRoot), $expectedRuntimeRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'The VM runtime root differs from the controller-created guest runtime directory.'
        }
        $runtimeRoot = $expectedRuntimeRoot
        $trustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
        $out = Join-Path $trustedRoot 'out'
        $arguments = '-NoProfile -NonInteractive -WindowStyle Normal -File "' + $runner + '" -BundleRoot "' + $root + '" -ExpectedSessionId ' + $desktopSession + ' -TestTimeoutSeconds ' + $testTimeout + ' -OutputRoot "' + $out + '" -RuntimeRoot "' + $runtimeRoot + '"'
        if ($v2) { $arguments += ' -AcceptanceProfileId vm-automated-v2-owned-resources' }
        $registeredTask = Register-DrVmTask `
            -TaskName $name `
            -UserSid $sid `
            -SessionId $desktopSession `
            -GuestRoot $root `
            -RuntimeRoot $runtimeRoot `
            -ObserverPath $runner `
            -ObserverSha256 $runnerHash `
            -BundleSourcePath $root `
            -BundleRecords $bundleRecords `
            -Execute $powerShell `
            -Arguments $arguments `
            -WorkingDirectory $root `
            -TrustedResultLeaf 'core-result.json' `
            -ExecutionTimeLimitSeconds ($suiteTimeout + 60)
        $actualAction = if ($v2) { $registeredTask.Definition.Actions.Item(1) } else { $null }
        $registered = Get-ScheduledTaskInfo -TaskName $name
        $registeredLastRunTimeTicks = [long]$registered.LastRunTime.Ticks
        Start-ScheduledTask -TaskName $name
        [pscustomobject]@{
            executable = $powerShell
            version = [string]$engine.version
            edition = [string]$engine.edition
            effective_policy = [string]$engine.effective_policy
            registered_last_run_time_ticks = $registeredLastRunTimeTicks
            action_executable = if ($v2) { [string]$actualAction.Path } else { $powerShell }
            action_arguments = if ($v2) { [string]$actualAction.Arguments } else { $arguments }
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
    $registeredLastRunTimeTicks = [long]$runnerEngine.registered_last_run_time_ticks
    do {
        Start-Sleep -Seconds 5
        $polledState = Invoke-Command -Session $session -ArgumentList $trustedTaskRoot,$taskName,$coreResultMaximumBytes,$registeredLastRunTimeTicks -ScriptBlock {
            param($trustedRoot,$name,$maximumResultBytes,$registeredRunTicks)
            $task = Get-ScheduledTask -TaskName $name
            $taskState = $task.State.ToString()
            $info = Get-ScheduledTaskInfo -TaskName $name
            $lastRunTimeTicks = [long]$info.LastRunTime.Ticks
            if ($taskState -ceq 'Ready') {
                $info = Get-ScheduledTaskInfo -TaskName $name
                $lastRunTimeTicks = [long]$info.LastRunTime.Ticks
            }
            $taskCompleted = $taskState -ceq 'Ready' -and
                $lastRunTimeTicks -gt [long]$registeredRunTicks
            if (-not $taskCompleted) {
                return [pscustomobject]@{
                    result_status = $null
                    count = 0
                    task_state = $taskState
                    task_result = [long]$info.LastTaskResult
                    last_run_time_ticks = $lastRunTimeTicks
                }
            }
            $file = Join-Path (Join-Path $trustedRoot 'out') 'core-result.json'
            $resultStatus = $null
            $resultCount = 0
            if (Test-Path -LiteralPath $file) {
                $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
                if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $item.Length -lt 1 -or $item.Length -gt $maximumResultBytes) {
                    throw 'Guest result exceeds its polling size bound.'
                }
                try {
                    $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                    $resultStatus = [string]$data.status
                    $resultCount = @($data.tests).Count
                } catch {}
            }
            [pscustomobject]@{
                result_status = $resultStatus
                count = $resultCount
                task_state = $taskState
                task_result = [long]$info.LastTaskResult
                last_run_time_ticks = $lastRunTimeTicks
            }
        }
        $pollState = Resolve-ObserverTaskPollState `
            -ResultStatus $polledState.result_status `
            -TaskState $polledState.task_state `
            -TaskResult $polledState.task_result `
            -RegisteredLastRunTimeTicks $registeredLastRunTimeTicks `
            -LastRunTimeTicks $polledState.last_run_time_ticks
        $status = if ($pollState.terminal) { $pollState.result_status } else { $pollState.task_state }
        $state = [pscustomobject]@{
            status = $status
            count = [int]$polledState.count
            task_result = $pollState.task_result
        }
        $progress = [string]$state.status + ':' + $state.count
        if ($progress -ne $lastProgress) { Write-Host ('VM tests: ' + $progress); $lastProgress = $progress }
        if ($pollState.terminal) {
            if ($pollState.result_status -notin @('passed','failed')) {
                if ($pollState.task_result -ne 0) {
                    throw ('Guest test task failed before producing results: ' + $pollState.task_result)
                }
                throw 'Guest test task reached its terminal state without a bounded result document.'
            }
            if ($pollState.result_status -ceq 'passed' -and $pollState.task_result -ne 0) {
                throw 'Guest test task reported a pass with a nonzero task result.'
            }
            break
        }
        if ($state.status -eq 'Ready' -and $state.task_result -ne 0) { throw ('Guest test task failed before producing results: ' + $state.task_result) }
    } while ((Get-Date) -lt $deadline)
    if ($state.status -notin @('passed','failed')) { throw 'VM test suite timed out.' }
    $trustedOutputRoot = Join-GuestWindowsPath -Root $trustedTaskRoot -Leaf 'out'
    $guestResultPath = Join-GuestWindowsPath -Root $trustedOutputRoot -Leaf 'core-result.json'
    $guestResultBytes = Invoke-Command -Session $session -ArgumentList $guestResultPath -ScriptBlock {
        param($path)
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Guest result is not an ordinary file.'
        }
        [long]$item.Length
    }
    if ($guestResultBytes -lt 1 -or $guestResultBytes -gt $coreResultMaximumBytes) {
        throw 'Guest result exceeds its size bound.'
    }
    Copy-Item -LiteralPath $guestResultPath -Destination (Join-Path $BundleRoot 'result.json') -FromSession $session
    if ((Get-Item -LiteralPath (Join-Path $BundleRoot 'result.json')).Length -ne $guestResultBytes) {
        throw 'Collected guest result size mismatch.'
    }
    $result = Get-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Raw | ConvertFrom-Json
    if ($ownedV2 -and $pollState.terminal) {
        $taskExecution = Complete-DrControllerV2TaskExecution `
            -Session $session -TaskName $taskName -RunnerSid $desktop.sid `
            -SessionId $desktop.session_id -Engine $runnerEngine `
            -CompletedTicks $polledState.last_run_time_ticks -TaskResult $polledState.task_result `
            -Result $result
    }
    if (-not (Test-DrControllerProcessJobCleanupLedger -Result $result -AllowEmpty) -or
        @($result.tests | Where-Object { $_.job_cleanup -isnot [bool] -or -not $_.job_cleanup }).Count -ne 0 -or
        $result.gui.job_cleanup -isnot [bool] -or -not $result.gui.job_cleanup) {
        throw 'Guest process jobs were not empty and closed before result collection.'
    }
    $processJobsClosed = $true
    $outputs = @()
    $testOutputBytes = [long]0
    foreach ($row in $result.tests) {
        foreach ($channel in @('stdout','stderr')) {
            if ($row.$channel) {
                $recordedBytes = $row.$channel.bytes
                if ($recordedBytes -isnot [long] -and $recordedBytes -isnot [int]) {
                    throw 'Guest test output has no exact byte count.'
                }
                $recordedBytes = [long]$recordedBytes
                if ($recordedBytes -lt 0 -or $recordedBytes -gt $coreTestChannelMaximumBytes -or
                    $testOutputBytes -gt ($coreTestOutputAggregateMaximumBytes - $recordedBytes)) {
                    throw 'Guest test output exceeds its collection bound.'
                }
                $testOutputBytes += $recordedBytes
                $outputs += $row.$channel
            }
        }
    }
    if ($result.gui -and $result.gui.PSObject.Properties.Name -contains 'screenshot' -and $result.gui.screenshot) { $outputs += $result.gui.screenshot }
    if ($result.gui -and $result.gui.flow -and $result.gui.flow.screenshots) {
        $outputs += @($result.gui.flow.screenshots)
    }
    if ($result.gui -and $result.gui.flow -and $result.gui.flow.diagnostic) {
        $outputs += $result.gui.flow.diagnostic
    }
    $failureDiagnostics = @(Get-CoreGuiFailureDiagnosticOutputs -Gui $result.gui)
    if (($outputs.Count + $failureDiagnostics.Count) -gt 256) {
        throw 'Guest output reference count exceeds its bound.'
    }
    $collectedOutputNames = @{}
    $remoteOutputSizes = @{}
    $collectionBytes = [long]0
    foreach ($output in $outputs) {
        Assert-PlainFile $output.file
        if ($collectedOutputNames.ContainsKey($output.file)) {
            throw 'Guest output contains a duplicate file reference.'
        }
        if ($names.ContainsKey($output.file) -or $output.file -in @('bundle.json','result.json','transport.json','run-windows-vm-tests.ps1')) { throw 'Guest output collides with a bundle input.' }
        $collectedOutputNames[$output.file] = $true
        $guestOutputPath = Join-GuestWindowsPath -Root $trustedOutputRoot -Leaf $output.file
        $remoteBytes = Invoke-Command -Session $session -ArgumentList $guestOutputPath -ScriptBlock {
            param($path)
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Guest output is not an ordinary file.'
            }
            [long]$item.Length
        }
        $fileMaximum = if ($output.PSObject.Properties.Name -contains 'bytes') {
            if ([long]$output.bytes -ne $remoteBytes) {
                throw 'Guest output differs from its recorded byte count.'
            }
            $coreTestChannelMaximumBytes
        } else { $coreOutputFileMaximumBytes }
        if ($remoteBytes -lt 0 -or $remoteBytes -gt $fileMaximum -or
            $collectionBytes -gt ($coreOutputAggregateMaximumBytes - $remoteBytes)) {
            throw 'Guest output exceeds its host collection bound.'
        }
        $collectionBytes += $remoteBytes
        $remoteOutputSizes[$output.file] = $remoteBytes
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
        $guestDiagnosticPath = Join-GuestWindowsPath -Root $trustedOutputRoot -Leaf $diagnosticOutput.file
        $remoteBytes = Invoke-Command -Session $session -ArgumentList $guestDiagnosticPath -ScriptBlock {
            param($path)
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Guest failure diagnostic is not an ordinary file.'
            }
            [long]$item.Length
        }
        if ([long]$diagnosticOutput.bytes -ne $remoteBytes -or
            $remoteBytes -lt 0 -or $remoteBytes -gt $coreOutputFileMaximumBytes -or
            $collectionBytes -gt ($coreOutputAggregateMaximumBytes - $remoteBytes)) {
            throw 'Guest failure diagnostic exceeds its host collection bound.'
        }
        $collectionBytes += $remoteBytes
        $remoteOutputSizes[$diagnosticOutput.file] = $remoteBytes
    }
    foreach ($output in $outputs) {
        $guestOutputPath = Join-GuestWindowsPath -Root $trustedOutputRoot -Leaf $output.file
        Copy-Item -LiteralPath $guestOutputPath -Destination (Join-Path $BundleRoot $output.file) -FromSession $session
        $hostOutputPath = Join-Path $BundleRoot $output.file
        if ((Get-Item -LiteralPath $hostOutputPath).Length -ne $remoteOutputSizes[$output.file] -or
            (Get-FileHash -LiteralPath $hostOutputPath -Algorithm SHA256).Hash -ine $output.sha256) {
            throw 'Collected guest output hash or size mismatch.'
        }
    }
    foreach ($diagnosticOutput in $failureDiagnostics) {
        $guestDiagnosticPath = Join-GuestWindowsPath `
            -Root $trustedOutputRoot `
            -Leaf $diagnosticOutput.file
        $hostDiagnosticPath = Join-Path $BundleRoot $diagnosticOutput.file
        if (Test-Path -LiteralPath $hostDiagnosticPath) {
            throw 'Guest failure diagnostic collides with an existing host path.'
        }
        Copy-Item `
            -LiteralPath $guestDiagnosticPath `
            -Destination $hostDiagnosticPath `
            -FromSession $session
        if ((Get-Item -LiteralPath $hostDiagnosticPath).Length -ne $remoteOutputSizes[$diagnosticOutput.file] -or
            (Get-FileHash -LiteralPath $hostDiagnosticPath -Algorithm SHA256).Hash -ine
                $diagnosticOutput.sha256) {
            throw 'Collected guest failure diagnostic hash or size mismatch.'
        }
    }
    $transport.status = 'collected'
    }
    Write-DrDiagnosticPhase -Phase 'candidate-task' -State 'end'
    }
} catch {
    $transport.status = 'failed'
    $transport.error = 'VM transport failed; inspect transport-error.txt.'
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'transport-error.txt') -Encoding UTF8
} finally {
    Write-DrDiagnosticPhase -Phase 'controller-cleanup' -State 'begin'
    $toolingCleanupError = Remove-ControllerToolingTransferStage -Transfer $toolingTransfer
    if ($null -ne $toolingCleanupError) {
        $transport.status = 'failed'
        $transport['tooling_cleanup_error'] = $toolingCleanupError
    }
    try {
        if ($session) {
            try {
                Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {
                    param($name)
                    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                    if ($task) { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $name -Confirm:$false }
                }
                if ($runtimeBrokerEnabled -and -not $RuntimeBrokerPreparationOnly -and $trustedTaskRoot) {
                    try {
                        Invoke-Command -Session $session -ArgumentList $trustedTaskRoot,$RuntimeBrokerDiagnosticRunId -ScriptBlock {
                            param($trustedRoot,$runId)
                            try {
                                $path = Join-Path (Join-Path $trustedRoot 'out') ('runtimebroker-' + $runId + '-phases.json')
                                $bytes = Read-DrVmBoundedOrdinaryBytes -Path $path -MaximumBytes 262144
                                $rows = @([Text.UTF8Encoding]::new($false,$true).GetString($bytes) | ConvertFrom-Json)
                                if ($rows.Count -gt 64) { throw 'RuntimeBroker UI phase count exceeded.' }
                                foreach ($row in $rows) {
                                    if ($row.schema_version -ne 1 -or $row.run_id -cne $runId -or $row.source -cne 'ui-observer') {
                                        throw 'RuntimeBroker UI phase binding mismatch.'
                                    }
                                    $details = @{}
                                    foreach ($property in $row.details.PSObject.Properties) { $details[$property.Name]=$property.Value }
                                    $recordedAt = if ($row.recorded_at_utc -is [DateTime]) {
                                        $row.recorded_at_utc.ToUniversalTime().ToString('o')
                                    } else { [string]$row.recorded_at_utc }
                                    Write-DrRuntimeBrokerPhaseFile @global:DrRuntimeBrokerDiagnostic -Phase $row.phase `
                                        -State $row.state -Source 'ui-observer' -RecordedAtUtc $recordedAt -Details $details
                                }
                            } catch {
                                if ($global:DrRuntimeBrokerPhaseErrors.Count -lt 32) {
                                    $global:DrRuntimeBrokerPhaseErrors.Add('ui-phase-import: ' + $_.Exception.GetType().Name)
                                }
                            }
                        }
                    } catch { $runtimeBrokerErrors.Add('UI phase import remoting failed.') }
                }
                if ($guestRoot) {
                    $cleanupAuthorized = $transport.status -eq 'collected' -and
                        (-not $observerTask -or $outputPreservedForCleanup)
                    # Preparation-only owns only the completed registration preflight.
                    if ($runtimeBrokerPrepared -and $transport.status -ceq 'diagnostic-prepared') { $cleanupAuthorized = $true }
                    $requiredProcessJobsClosed = $processJobsClosed -or $runtimeBrokerPrepared
                    $cleanupTaskContext = [pscustomobject]@{
                        diagnostic_enabled = $runtimeBrokerEnabled
                        runner_sid = [string]$desktop.sid
                        baseline_tasks = @($runnerTaskBaseline)
                        spotlight_preflight = $spotlightPreflight
                        runner_session_id = [int]$desktop.session_id
                        baseline_process_identities = @(
                            $runnerProcessBaseline | ForEach-Object identity
                        )
                    }
                    if ($ownedV2) {
                        $cleanupTaskContext.baseline_tasks = @(
                            Copy-DrControllerV2TaskBaseline -Baseline @($runnerTaskBaseline)
                        )
                        $declared = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                        if ($null -ne $result) {
                            if ($recovery) {
                                $declared = Get-DrControllerRecoveryProcessIdentities `
                                    -Result $result -EvidenceRoot $RecoveryOutputRoot
                            }
                            else {
                                Add-DrControllerLifecycleIdentity -Value $result -Identities $declared
                            }
                        }
                        $cleanupTaskContext | Add-Member -NotePropertyName v2 -NotePropertyValue $true
                        $cleanupTaskContext | Add-Member -NotePropertyName profile_sha256 -NotePropertyValue $AcceptanceProfileSha256
                        $cleanupTaskContext | Add-Member -NotePropertyName baseline_processes -NotePropertyValue @($runnerProcessBaseline)
                        $cleanupTaskContext | Add-Member -NotePropertyName task_execution -NotePropertyValue $taskExecution
                        $cleanupTaskContext | Add-Member -NotePropertyName preflight_child -NotePropertyValue $preflightChild
                        $cleanupTaskContext | Add-Member -NotePropertyName engine_child -NotePropertyValue $engineChild
                        $cleanupTaskContext | Add-Member -NotePropertyName rescue_attempts -NotePropertyValue $script:DrVmV2RescueAttempts
                        $cleanupTaskContext | Add-Member -NotePropertyName rescue_executions -NotePropertyValue @($script:DrVmV2RescueExecutions.ToArray())
                        $cleanupTaskContext | Add-Member -NotePropertyName process_job_cleanup -NotePropertyValue @($result.process_job_cleanup)
                        $cleanupTaskContext | Add-Member -NotePropertyName declared_processes -NotePropertyValue @(
                            $declared | Sort-Object | ForEach-Object {
                                $parts = $_.Split('|')
                                [ordered]@{ pid = [int]$parts[0]; start_time_utc_ticks = [string]$parts[1] }
                            })
                    }
                    $cleanupResult = Invoke-Command -Session $session -ArgumentList $guestRoot,$trustedTaskRoot,$taskName,$cleanupAuthorized,$requiredProcessJobsClosed,$cleanupTaskContext,(${function:Test-DrControllerCleanupObservation}.ToString()) -ScriptBlock {
                        param($root,$trustedRoot,$name,$mayDelete,$jobsClosed,$taskContext,$completionDefinition)
                        $diagnosticEnabled = $null -ne $taskContext.PSObject.Properties['diagnostic_enabled'] -and
                            $taskContext.diagnostic_enabled -is [bool] -and $taskContext.diagnostic_enabled
                        $expectedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') $name
                        $expectedTrustedRoot = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
                        if ($name -cnotmatch '^DarkReNamerTests-[0-9a-f]{32}$' -or
                            $root -cne $expectedRoot -or $trustedRoot -cne $expectedTrustedRoot) {
                            throw 'Unexpected VM cleanup root.'
                        }
                        $prefixes = @(($root.TrimEnd('\') + '\'), ($trustedRoot.TrimEnd('\') + '\'))
                        if ($null -ne $taskContext.PSObject.Properties['v2'] -and $taskContext.v2) {
                            $baselineProcesses = @($taskContext.baseline_processes)
                            $baselineTasks = @($taskContext.baseline_tasks)
                            $baselineIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                            foreach ($row in $baselineProcesses) { [void]$baselineIds.Add([string]$row.identity) }
                            $taskMap = @{}
                            foreach ($row in $baselineTasks) {
                                $identity = [string]$row.identity
                                if ([string]::IsNullOrWhiteSpace($identity) -or
                                    $taskMap.ContainsKey($identity)) { throw 'V2 task baseline is ambiguous.' }
                                $taskMap[$identity] = [string]$row.definition_sha256
                            }
                            function Get-V2ProcessSnapshot {
                                $snapshot = Get-DrVmRunnerProcesses -UserSid $taskContext.runner_sid `
                                    -SessionId $taskContext.runner_session_id -IncludeExecutionScope
                                [ordered]@{complete=[bool]$snapshot.complete;processes=@($snapshot.processes)}
                            }
                            function Get-V2TaskDelta {
                                param($Current)
                                $changed = @($Current | Where-Object {
                                    -not $taskMap.ContainsKey([string]$_.identity) -or
                                    [string]$_.definition_sha256 -cne $taskMap[[string]$_.identity]
                                } | Sort-Object identity)
                                $currentIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                                foreach ($row in $Current) { [void]$currentIds.Add([string]$row.identity) }
                                $removed = @($taskMap.Keys | Where-Object { -not $currentIds.Contains([string]$_) } | Sort-Object)
                                [ordered]@{changed=$changed;removed=$removed}
                            }
                            function Get-V2ProcessDelta {
                                param($Snapshot)
                                @($Snapshot.processes | Where-Object {
                                    -not $baselineIds.Contains([string]$_.identity)
                                } | Sort-Object identity)
                            }
                            function Get-V2OwnedScopeProcesses {
                                param($Snapshot)
                                $ownedPids = [Collections.Generic.HashSet[int]]::new()
                                foreach ($row in @($taskContext.declared_processes)) {
                                    [void]$ownedPids.Add([int]$row.pid)
                                }
                                [void]$ownedPids.Add([int]$taskContext.preflight_child.pid)
                                [void]$ownedPids.Add([int]$taskContext.engine_child.pid)
                                [void]$ownedPids.Add([int]$taskContext.task_execution.observer_lifecycle.pid)
                                foreach ($rescue in @($taskContext.rescue_executions)) {
                                    [void]$ownedPids.Add([int]$rescue.task_execution.observer_lifecycle.pid)
                                }
                                @($Snapshot.processes | Where-Object {
                                    $scope = ([string]$_.executable_path + ' ' + [string]$_.command_line)
                                    $scope.IndexOf($name,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                                    $scope.IndexOf($root,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                                    $scope.IndexOf($trustedRoot,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                                    $ownedPids.Contains([int]$_.pid) -or
                                    $ownedPids.Contains([int]$_.parent_pid)
                                })
                            }
                            $before = $null; $intervention = $null; $after = $null
                            $tasksBefore = $null; $tasksIntervention = $null; $tasksAfter = $null
                            $observedRootsBefore = $null; $observedRootsAfter = $null
                            $rootRecords = [ordered]@{
                                guest = $global:DrVmOwnedRootRecords.guest
                                trusted = $global:DrVmOwnedRootRecords.trusted
                            }
                            $errors = [Collections.Generic.List[string]]::new()
                            $ownedAfter = @()
                            $deleted = $false
                            try {
                                if (-not $mayDelete -or -not $jobsClosed -or
                                    $null -eq $taskContext.task_execution -or
                                    -not $taskContext.task_execution.terminal -or
                                    -not $taskContext.task_execution.observer_lifetime_absent -or
                                    $null -eq $taskContext.preflight_child -or
                                    -not $taskContext.preflight_child.process_job_closed -or
                                    $null -eq $taskContext.engine_child -or
                                    -not $taskContext.engine_child.process_job_closed -or
                                    $taskContext.rescue_attempts -ne @($taskContext.rescue_executions).Count -or
                                    $null -eq $rootRecords.guest -or $null -eq $rootRecords.trusted) {
                                    throw 'V2 declared task, helper, Job or root closure is unavailable.'
                                }
                                if (@($taskContext.declared_processes).Count -ne
                                    @($taskContext.process_job_cleanup).Count) {
                                    throw 'V2 declared process lifetimes differ from Job cleanup.'
                                }
                                $before = Get-V2ProcessSnapshot
                                $tasksBefore = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                                $taskDeltaBefore = Get-V2TaskDelta -Current $tasksBefore
                                $intervention = Get-V2ProcessSnapshot
                                $tasksIntervention = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                                $taskDeltaIntervention = Get-V2TaskDelta -Current $tasksIntervention
                                $ownedTask = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
                                    [string]$_.TaskName -ceq $name -and [string]$_.TaskPath -ceq '\'
                                })
                                $allProcesses = @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
                                $globalOwned = @($allProcesses | Where-Object {
                                    $path = [string]$_.ExecutablePath
                                    $path.StartsWith($prefixes[0],[StringComparison]::OrdinalIgnoreCase) -or
                                    $path.StartsWith($prefixes[1],[StringComparison]::OrdinalIgnoreCase)
                                })
                                if ($taskContext.task_execution.exit_code -ne 0 -or
                                    -not $before.complete -or -not $intervention.complete -or
                                    $taskDeltaBefore.changed.Count -ne 0 -or $taskDeltaBefore.removed.Count -ne 0 -or
                                    $taskDeltaIntervention.changed.Count -ne 0 -or $taskDeltaIntervention.removed.Count -ne 0 -or
                                    $ownedTask.Count -ne 0 -or $globalOwned.Count -ne 0 -or
                                    @(Get-V2OwnedScopeProcesses -Snapshot $before).Count -ne 0 -or
                                    @(Get-V2OwnedScopeProcesses -Snapshot $intervention).Count -ne 0) {
                                    throw 'V2 observer exit, owned scope, task definition, or process enumeration is incomplete.'
                                }
                                $guestGuard = $null; $trustedGuard = $null
                                try {
                                    $guestGuard = [DarkReNamerVmOwnedRootGuard]::new($root)
                                    $trustedGuard = [DarkReNamerVmOwnedRootGuard]::new($trustedRoot)
                                    $observedRootsBefore = [ordered]@{}
                                    foreach ($pair in @(@($guestGuard,$rootRecords.guest),@($trustedGuard,$rootRecords.trusted))) {
                                        $guard = $pair[0]; $record = $pair[1]
                                        $guard.Assert([string]$record.base_file_id,[string]$record.file_id)
                                        $security = $guard.Security()
                                        if ($security[0] -cne $record.owner_sid -or
                                            $security[0] -cne 'S-1-5-32-544' -or
                                            $security[1] -cne $record.acl_sddl) {
                                            throw 'V2 owned root owner or ACL changed since creation.'
                                        }
                                        $role = if ($guard.RootId -ceq $rootRecords.guest.file_id) { 'guest' } else { 'trusted' }
                                        $observedRootsBefore[$role] = [ordered]@{
                                            path=$record.path; base_file_id=$guard.BaseId; file_id=$guard.RootId
                                            owner_sid=$security[0]; acl_sddl=$security[1]; ordinary_directory=$true
                                        }
                                    }
                                    $guestGuard.Delete()
                                    $trustedGuard.Delete()
                                    $deleted = $true
                                }
                                finally {
                                    if ($null -ne $trustedGuard) { $trustedGuard.Dispose() }
                                    if ($null -ne $guestGuard) { $guestGuard.Dispose() }
                                }
                            }
                            catch { $errors.Add($_.Exception.Message) }
                            try {
                                if ($null -ne $rootRecords.guest -and $null -ne $rootRecords.trusted) {
                                    $present = [DarkReNamerVmOwnedRootGuard]::ObserveRoots(
                                        (Join-Path $env:ProgramData 'DarkReNamerVmRuns'),
                                        [string]$rootRecords.guest.base_file_id,$name,$name+'-trusted')
                                    $observedRootsAfter = [ordered]@{
                                        guest_present=[bool]$present[0]; trusted_present=[bool]$present[1]
                                    }
                                }
                                if ($deleted) {
                                    $after = Get-V2ProcessSnapshot
                                    $tasksAfter = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                                    $taskDeltaAfter = Get-V2TaskDelta -Current $tasksAfter
                                    $ownedAfter = @(Get-CimInstance Win32_Process `
                                        -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object {
                                        $path = [string]$_.ExecutablePath
                                        $path.StartsWith($prefixes[0],[StringComparison]::OrdinalIgnoreCase) -or
                                        $path.StartsWith($prefixes[1],[StringComparison]::OrdinalIgnoreCase)
                                    } | ForEach-Object {
                                        [ordered]@{ pid=[int]$_.ProcessId; session_id=[int]$_.SessionId
                                            executable_path=[string]$_.ExecutablePath }
                                    })
                                    if (-not $after.complete -or $taskDeltaAfter.changed.Count -ne 0 -or
                                        $taskDeltaAfter.removed.Count -ne 0 -or
                                        $ownedAfter.Count -ne 0 -or
                                        @(Get-V2OwnedScopeProcesses -Snapshot $after).Count -ne 0 -or
                                        $observedRootsAfter.guest_present -or
                                        $observedRootsAfter.trusted_present) {
                                        throw 'V2 post-cleanup owned scope, tasks, or roots remain.'
                                    }
                                }
                            }
                            catch { $errors.Add($_.Exception.Message) }
                            $deltaBefore = if ($null -ne $before) { ,@(Get-V2ProcessDelta -Snapshot $before) } else { $null }
                            $deltaIntervention = if ($null -ne $intervention) { ,@(Get-V2ProcessDelta -Snapshot $intervention) } else { $null }
                            $deltaAfter = if ($null -ne $after) { ,@(Get-V2ProcessDelta -Snapshot $after) } else { $null }
                            $taskDeltaBefore = if ($null -ne $tasksBefore) { Get-V2TaskDelta -Current $tasksBefore } else { $null }
                            $taskDeltaIntervention = if ($null -ne $tasksIntervention) { Get-V2TaskDelta -Current $tasksIntervention } else { $null }
                            $taskDeltaAfter = if ($null -ne $tasksAfter) { Get-V2TaskDelta -Current $tasksAfter } else { $null }
                            $removedTasks = [Collections.Generic.List[string]]::new()
                            foreach ($delta in @($taskDeltaBefore,$taskDeltaIntervention,$taskDeltaAfter)) {
                                if ($null -ne $delta) {
                                    foreach ($identity in @($delta.removed)) {
                                        $removedTasks.Add([string]$identity)
                                    }
                                }
                            }
                            $complete = $deleted -and $errors.Count -eq 0 -and
                                $null -ne $after -and $after.complete -and
                                $null -ne $observedRootsAfter -and
                                -not $observedRootsAfter.guest_present -and
                                -not $observedRootsAfter.trusted_present
                            $raw = [ordered]@{
                                scheduled_task_present = [bool]($null -ne $ownedTask -and $ownedTask.Count -gt 0)
                                guest_root_present = [bool]($null -eq $observedRootsAfter -or $observedRootsAfter.guest_present)
                                trusted_task_root_present = [bool]($null -eq $observedRootsAfter -or $observedRootsAfter.trusted_present)
                                process_jobs_closed = [bool]$jobsClosed
                                runner_process_inventory_complete = [bool]($null -ne $before -and $before.complete -and
                                    $null -ne $intervention -and $intervention.complete -and
                                    $null -ne $after -and $after.complete)
                                unexpected_runner_tasks = if ($null -ne $taskDeltaBefore) { ,@($taskDeltaBefore.changed) } else { $null }
                                unexpected_runner_processes = $deltaBefore
                                unexpected_runner_tasks_after_intervention = if ($null -ne $taskDeltaIntervention) { ,@($taskDeltaIntervention.changed) } else { $null }
                                unexpected_runner_processes_after_intervention = $deltaIntervention
                                unexpected_runner_tasks_after_delete = if ($null -ne $taskDeltaAfter) { ,@($taskDeltaAfter.changed) } else { $null }
                                unexpected_runner_processes_after_delete = $deltaAfter
                                removed_runner_tasks = @($removedTasks.ToArray() | Sort-Object -Unique)
                                terminated_runner_processes = @()
                                resource_cleanup_errors = @($errors.ToArray())
                                runner_process_natural_exit = [ordered]@{schema_version=2;status='v2-owned-resources'}
                                owned_processes_after = @($ownedAfter)
                                schema_version = 2
                                profile_id = 'vm-automated-v2-owned-resources'
                                profile_sha256 = [string]$taskContext.profile_sha256
                                owned_resource_evidence = [ordered]@{
                                    schema_version = 2
                                    run_name = $name
                                    runner_sid = [string]$taskContext.runner_sid
                                    runner_session_id = [int]$taskContext.runner_session_id
                                    root_records = $rootRecords
                                    baseline_processes = $baselineProcesses
                                    baseline_tasks = $baselineTasks
                                    process_snapshots = [ordered]@{before=$before;after_intervention=$intervention;after_delete=$after}
                                    task_snapshots = [ordered]@{before=$tasksBefore;after_intervention=$tasksIntervention;after_delete=$tasksAfter}
                                    declared_processes = @($taskContext.declared_processes)
                                    process_job_cleanup = @($taskContext.process_job_cleanup)
                                    preflight_child = $taskContext.preflight_child
                                    engine_child = $taskContext.engine_child
                                    rescue_attempts = [int]$taskContext.rescue_attempts
                                    rescue_executions = @($taskContext.rescue_executions)
                                    task_execution = $taskContext.task_execution
                                    observed_roots_before = $observedRootsBefore
                                    observed_roots_after = $observedRootsAfter
                                }
                            }
                            return [pscustomobject]@{
                                guest_cleanup = [bool]$complete
                                owned_cleanup_after_strict_failure_eligible = [bool](
                                    -not $deleted -and $mayDelete -and $jobsClosed -and
                                    $null -ne $before -and $before.complete -and
                                    $null -ne $intervention -and $intervention.complete -and
                                    $null -ne $tasksIntervention -and
                                    $null -ne $observedRootsAfter -and
                                    $observedRootsAfter.guest_present -and
                                    $observedRootsAfter.trusted_present -and
                                    $null -ne $taskContext.task_execution -and
                                    $taskContext.task_execution.terminal -and
                                    $taskContext.task_execution.observer_lifetime_absent -and
                                    $null -ne $taskContext.preflight_child -and
                                    $taskContext.preflight_child.process_job_closed -and
                                    $null -ne $taskContext.engine_child -and
                                    $taskContext.engine_child.process_job_closed -and
                                    $ownedAfter.Count -eq 0 -and $ownedTask.Count -eq 0)
                                failed_snapshot = if ($null -ne $intervention -and $null -ne $tasksIntervention) {
                                    [ordered]@{complete=[bool]$intervention.complete
                                        processes=@($intervention.processes);tasks=@($tasksIntervention)
                                        owned_processes=@($ownedAfter)}
                                } else { $null }
                                root_records = $rootRecords
                                raw_cleanup = $raw
                            }
                        }
                        function Test-ProcessExecutableInOwnedRoots {
                            param([AllowNull()][string] $Path,[Parameter(Mandatory)][string[]] $Prefixes)
                            if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
                            foreach ($candidatePrefix in $Prefixes) {
                                if ($Path.StartsWith($candidatePrefix,[StringComparison]::OrdinalIgnoreCase)) {
                                    return $true
                                }
                            }
                            return $false
                        }
                        $baselineTasks = [Collections.Generic.HashSet[string]]::new(
                            [StringComparer]::OrdinalIgnoreCase
                        )
                        $baselineTaskHashes = @{}
                        foreach ($task in @($taskContext.baseline_tasks)) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$task.identity)) {
                                [void]$baselineTasks.Add([string]$task.identity)
                                $baselineTaskHashes[[string]$task.identity] = [string]$task.definition_sha256
                            }
                        }
                        $baselineProcesses = [Collections.Generic.HashSet[string]]::new(
                            [StringComparer]::OrdinalIgnoreCase
                        )
                        foreach ($identity in @($taskContext.baseline_process_identities)) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$identity)) {
                                [void]$baselineProcesses.Add([string]$identity)
                            }
                        }
                        $removedRunnerTasks = [Collections.Generic.HashSet[string]]::new(
                            [StringComparer]::OrdinalIgnoreCase)
                        if ($diagnosticEnabled) { Write-DrRuntimeBrokerControllerPhase -Phase 'cleanup-initial-inventory' -State 'begin' }
                        $runnerTasksBeforeCleanup = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                        $unexpectedRunnerTasksBeforeCleanup = @($runnerTasksBeforeCleanup |
                            Where-Object {
                                -not $baselineTasks.Contains([string]$_.identity) -or
                                [string]$_.definition_sha256 -cne [string]$baselineTaskHashes[[string]$_.identity]
                            } |
                            Sort-Object identity)
                        $runnerTaskIdentitiesBeforeCleanup = [Collections.Generic.HashSet[string]]::new(
                            [StringComparer]::OrdinalIgnoreCase)
                        foreach ($task in $runnerTasksBeforeCleanup) {
                            [void]$runnerTaskIdentitiesBeforeCleanup.Add([string]$task.identity)
                        }
                        foreach ($identity in $baselineTasks) {
                            if (-not $runnerTaskIdentitiesBeforeCleanup.Contains([string]$identity)) {
                                [void]$removedRunnerTasks.Add([string]$identity)
                            }
                        }
                        $nativeCapture = New-DrVmSpotlightCaptureContext -BaselineIdentities @($taskContext.baseline_process_identities)
                        try {
                        $processSnapshotBeforeCleanup = Get-DrVmRunnerProcesses `
                            -UserSid $taskContext.runner_sid `
                            -SessionId $taskContext.runner_session_id -CaptureContext $nativeCapture
                        $unexpectedRunnerProcessesBeforeCleanup = @($processSnapshotBeforeCleanup.processes |
                            Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                            Sort-Object identity)
                        if ($diagnosticEnabled) {
                            Write-DrRuntimeBrokerControllerPhase -Phase 'cleanup-initial-inventory' -State 'end' -Details @{ unexpected_process_count=$unexpectedRunnerProcessesBeforeCleanup.Count }
                            Write-DrRuntimeBrokerControllerPhase -Phase 'cleanup-classification' -State 'begin'
                        }
                        $terminatedRunnerProcesses = [Collections.Generic.List[object]]::new()
                        $cleanupResourceErrors = [Collections.Generic.List[string]]::new()
                        $ownedRootProcessCandidates = @(Get-CimInstance Win32_Process `
                            -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object {
                            Test-ProcessExecutableInOwnedRoots -Path $_.ExecutablePath -Prefixes $prefixes
                        } | Sort-Object ProcessId)
                        $runnerProcessNaturalExit = [ordered]@{
                            schema_version = 2
                            status = 'rejected'
                            process_class = $null
                            native_exit = $null
                            initial_native_observations = @($nativeCapture.observations.ToArray())
                            runner_sid = [string]$taskContext.runner_sid
                            runner_session_id = [int]$taskContext.runner_session_id
                            candidate_identity = $null
                            broker = $null
                            timeout_ms = 0
                            elapsed_ms = 0
                            polls = @()
                            natural_exit_observed = $false
                            final_inventory_complete = $false
                            final_runner_process_delta_identities = @()
                            final_runner_task_delta_identities = @()
                        }
                        if ($processSnapshotBeforeCleanup.complete -and
                            $unexpectedRunnerTasksBeforeCleanup.Count -eq 0 -and
                            $removedRunnerTasks.Count -eq 0 -and
                            $unexpectedRunnerProcessesBeforeCleanup.Count -eq 0 -and -not $nativeCapture.failed -and
                            $nativeCapture.observations.Count -eq 0) {
                            $runnerProcessNaturalExit.status = 'not-required'
                            $runnerProcessNaturalExit.final_inventory_complete = $true
                        }
                        elseif ($mayDelete -and $jobsClosed -and
                            $processSnapshotBeforeCleanup.complete -and
                            $unexpectedRunnerTasksBeforeCleanup.Count -eq 0 -and
                            $removedRunnerTasks.Count -eq 0 -and
                            $unexpectedRunnerProcessesBeforeCleanup.Count -eq 1 -and
                            $ownedRootProcessCandidates.Count -eq 0) {
                            $candidate = $unexpectedRunnerProcessesBeforeCleanup[0]
                            $runnerProcessNaturalExit.candidate_identity = [string]$candidate.identity
                            try {
                                if ([string]$candidate.executable_path -ieq ($env:windir.TrimEnd('\')+'\System32\backgroundTaskHost.exe')) {
                                    $runnerProcessNaturalExit.process_class = 'desktop-spotlight'
                                    $runnerProcessNaturalExit.broker = Get-DrVmSpotlightBrokerEvidence -Candidate $candidate `
                                        -Capture $nativeCapture -Preflight $taskContext.spotlight_preflight `
                                        -UserSid $taskContext.runner_sid -SessionId $taskContext.runner_session_id
                                } else {
                                    if ($nativeCapture.failed -or $nativeCapture.observations.Count -ne 0) { throw 'Sticky native observations forbid another process class.' }
                                    $runnerProcessNaturalExit.process_class = 'smart-screen'
                                    $runnerProcessNaturalExit.broker = Get-DrVmSmartScreenBrokerEvidence `
                                        -Candidate $candidate -UserSid $taskContext.runner_sid -SessionId $taskContext.runner_session_id
                                }
                                $runnerProcessNaturalExit.status = 'pending'
                                $runnerProcessNaturalExit.timeout_ms = 360000
                            }
                            catch {
                                $runnerProcessNaturalExit.status = 'classification-failed'
                                $cleanupResourceErrors.Add('Runner process identity or native resource authentication failed.')
                            }
                        }
                        if ($runnerProcessNaturalExit.status -ceq 'rejected') {
                            $runnerProcessNaturalExit.final_runner_process_delta_identities = @(
                                $unexpectedRunnerProcessesBeforeCleanup | ForEach-Object { [string]$_.identity })
                            $runnerProcessNaturalExit.final_runner_task_delta_identities = @(
                                $unexpectedRunnerTasksBeforeCleanup | ForEach-Object { [string]$_.identity })
                        }
                        if ($diagnosticEnabled) { Write-DrRuntimeBrokerControllerPhase -Phase 'cleanup-classification' -State 'end' -Details @{ status=[string]$runnerProcessNaturalExit.status } }
                        foreach ($candidateProcess in $ownedRootProcessCandidates) {
                            $owned = $null
                            $terminationRecord = $null
                            try {
                                $owned = Get-Process -Id $candidateProcess.ProcessId -ErrorAction SilentlyContinue
                                if (-not $owned) { continue }
                                $actualPath = [string]$owned.MainModule.FileName
                                if (-not (Test-ProcessExecutableInOwnedRoots -Path $actualPath -Prefixes $prefixes)) {
                                    continue
                                }
                                $createdUtc = ([datetime]$candidateProcess.CreationDate).ToUniversalTime().ToString('o')
                                $identity = [string]$candidateProcess.ProcessId + '|' + $createdUtc
                                $terminationRecord = [ordered]@{
                                    identity = $identity
                                    pid = [int]$candidateProcess.ProcessId
                                    session_id = [int]$candidateProcess.SessionId
                                    executable_path = $actualPath
                                    termination_requested = $false
                                    exit_observed = $false
                                    error = $null
                                }
                                $terminatedRunnerProcesses.Add($terminationRecord)
                                $owned.Kill()
                                $terminationRecord.termination_requested = $true
                                $exited = $owned.WaitForExit(10000)
                                $terminationRecord.exit_observed = [bool]$exited
                                if (-not $exited) {
                                    $cleanupResourceErrors.Add('An owned test process did not exit after termination.')
                                }
                            }
                            catch {
                                if ($null -ne $terminationRecord) {
                                    $terminationRecord.error = 'An owned test process could not be recorded or terminated.'
                                }
                                $cleanupResourceErrors.Add('An owned test process could not be recorded or terminated.')
                            }
                            finally {
                                if ($null -ne $owned) { $owned.Dispose() }
                            }
                        }
                        # Same-user process and task deltas can include unrelated desktop
                        # work. Detect them and retain the VM root for inspection; only
                        # terminate processes whose executable is inside this exact run root.
                        if ($diagnosticEnabled) { Write-DrRuntimeBrokerControllerPhase -Phase 'cleanup-reinventory' -State 'begin' }
                        $processSnapshotAfterIntervention = Get-DrVmRunnerProcesses `
                            -UserSid $taskContext.runner_sid `
                            -SessionId $taskContext.runner_session_id
                        $unexpectedRunnerProcessesAfterIntervention = @($processSnapshotAfterIntervention.processes |
                            Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                            Sort-Object identity)
                        $runnerTasksAfterIntervention = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                        $unexpectedRunnerTasksAfterIntervention = @($runnerTasksAfterIntervention |
                            Where-Object {
                                -not $baselineTasks.Contains([string]$_.identity) -or
                                [string]$_.definition_sha256 -cne [string]$baselineTaskHashes[[string]$_.identity]
                            } |
                            Sort-Object identity)
                        $runnerTaskIdentitiesAfterIntervention = [Collections.Generic.HashSet[string]]::new(
                            [StringComparer]::OrdinalIgnoreCase)
                        foreach ($task in $runnerTasksAfterIntervention) {
                            [void]$runnerTaskIdentitiesAfterIntervention.Add([string]$task.identity)
                        }
                        foreach ($identity in $baselineTasks) {
                            if (-not $runnerTaskIdentitiesAfterIntervention.Contains([string]$identity)) {
                                [void]$removedRunnerTasks.Add([string]$identity)
                            }
                        }
                        $ownedScheduledTasksBeforeDelete = @(Get-ScheduledTask -ErrorAction Stop |
                            Where-Object {
                                [string]$_.TaskName -ceq $name -and [string]$_.TaskPath -ceq '\'
                            })
                        $taskPresentBeforeDelete = $ownedScheduledTasksBeforeDelete.Count -gt 0
                        if ($diagnosticEnabled) { Write-DrRuntimeBrokerControllerPhase -Phase 'cleanup-reinventory' -State 'end' -Details @{ unexpected_process_count=$unexpectedRunnerProcessesAfterIntervention.Count } }
                        if ($runnerProcessNaturalExit.status -ceq 'pending') {
                            if ($mayDelete -and $jobsClosed -and -not $taskPresentBeforeDelete -and
                                $processSnapshotAfterIntervention.complete -and
                                $unexpectedRunnerTasksAfterIntervention.Count -eq 0 -and
                                $unexpectedRunnerProcessesAfterIntervention.Count -le 1 -and
                                ($unexpectedRunnerProcessesAfterIntervention.Count -eq 0 -or
                                    [string]$unexpectedRunnerProcessesAfterIntervention[0].identity -ceq
                                        [string]$runnerProcessNaturalExit.candidate_identity) -and
                                $ownedRootProcessCandidates.Count -eq 0 -and
                                $removedRunnerTasks.Count -eq 0 -and
                                $terminatedRunnerProcesses.Count -eq 0 -and
                                $cleanupResourceErrors.Count -eq 0) {
                                $nativeWait = if ($runnerProcessNaturalExit.process_class -ceq 'desktop-spotlight') { $nativeCapture } else { $null }
                                if ($diagnosticEnabled) { Write-DrRuntimeBrokerControllerPhase -Phase 'cleanup-timed-polling' -State 'begin' }
                                $waitResult = Wait-DrVmSmartScreenNaturalExit `
                                    -UserSid $taskContext.runner_sid `
                                    -SessionId $taskContext.runner_session_id `
                                    -BaselineProcessIdentities @($taskContext.baseline_process_identities) `
                                    -BaselineTasks @($taskContext.baseline_tasks) `
                                    -CandidateIdentity ([string]$runnerProcessNaturalExit.candidate_identity) `
                                    -OwnedRootPrefixes $prefixes `
                                    -TimeoutMilliseconds 360000 -NativeCapture $nativeWait
                                if ($diagnosticEnabled) { Write-DrRuntimeBrokerControllerPhase -Phase 'cleanup-timed-polling' -State 'end' -Details @{ status=[string]$waitResult.status } }
                                $runnerProcessNaturalExit.status = [string]$waitResult.status
                                $runnerProcessNaturalExit.elapsed_ms = [int]$waitResult.elapsed_ms
                                $runnerProcessNaturalExit.polls = @($waitResult.polls)
                                $runnerProcessNaturalExit.natural_exit_observed = [bool]$waitResult.natural_exit_observed
                                $runnerProcessNaturalExit.final_inventory_complete = [bool]$waitResult.final_inventory_complete
                                $runnerProcessNaturalExit.final_runner_process_delta_identities = @(
                                    $waitResult.final_runner_process_delta_identities)
                                $runnerProcessNaturalExit.final_runner_task_delta_identities = @(
                                    $waitResult.final_runner_task_delta_identities)
                                if ($waitResult.final_inventory_complete -and
                                    $null -ne $waitResult.final_process_snapshot) {
                                    $processSnapshotAfterIntervention = $waitResult.final_process_snapshot
                                    $unexpectedRunnerProcessesAfterIntervention = @(
                                        $processSnapshotAfterIntervention.processes |
                                            Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                                            Sort-Object identity)
                                    $finalTaskRows = @($waitResult.final_task_rows)
                                    $unexpectedRunnerTasksAfterIntervention = @($finalTaskRows | Where-Object {
                                        -not $baselineTasks.Contains([string]$_.identity) -or
                                        [string]$_.definition_sha256 -cne
                                            [string]$baselineTaskHashes[[string]$_.identity]
                                    } | Sort-Object identity)
                                    $runnerTaskIdentitiesAfterWait = [Collections.Generic.HashSet[string]]::new(
                                        [StringComparer]::OrdinalIgnoreCase)
                                    foreach ($task in $finalTaskRows) {
                                        [void]$runnerTaskIdentitiesAfterWait.Add([string]$task.identity)
                                    }
                                    foreach ($identity in $baselineTasks) {
                                        if (-not $runnerTaskIdentitiesAfterWait.Contains([string]$identity)) {
                                            [void]$removedRunnerTasks.Add([string]$identity)
                                        }
                                    }
                                }
                            }
                            else {
                                $runnerProcessNaturalExit.status = 'rejected'
                                $runnerProcessNaturalExit.final_runner_process_delta_identities = @(
                                    $unexpectedRunnerProcessesAfterIntervention | ForEach-Object { [string]$_.identity })
                                $runnerProcessNaturalExit.final_runner_task_delta_identities = @(
                                    $unexpectedRunnerTasksAfterIntervention | ForEach-Object { [string]$_.identity })
                            }
                        }
                        try { Close-DrVmSpotlightCaptureContext -Context $nativeCapture }
                        catch { $cleanupResourceErrors.Add('Retained native handle cleanup failed.'); $runnerProcessNaturalExit.status='classification-failed' }
                        if ($runnerProcessNaturalExit.process_class -ceq 'desktop-spotlight' -and
                            $nativeCapture.lifetimes.ContainsKey([string]$runnerProcessNaturalExit.candidate_identity) -and
                            $null -ne $nativeCapture.lifetimes[[string]$runnerProcessNaturalExit.candidate_identity].PSObject.Properties['exit']) {
                            $runnerProcessNaturalExit.native_exit = $nativeCapture.lifetimes[[string]$runnerProcessNaturalExit.candidate_identity].exit
                        }
                        $guestRootPresentBeforeDelete = [bool](Test-Path -LiteralPath $root)
                        $trustedRootPresentBeforeDelete = [bool](Test-Path -LiteralPath $trustedRoot)
                        $runnerProcessInitialDeltaAccepted =
                            $runnerProcessNaturalExit.status -ceq 'natural-exit' -and
                            $unexpectedRunnerProcessesBeforeCleanup.Count -eq 1 -and
                            [string]$unexpectedRunnerProcessesBeforeCleanup[0].identity -ceq
                                [string]$runnerProcessNaturalExit.candidate_identity -and
                            $runnerProcessNaturalExit.natural_exit_observed -and
                            $runnerProcessNaturalExit.final_inventory_complete -and
                            $runnerProcessNaturalExit.final_runner_process_delta_identities.Count -eq 0 -and
                            $runnerProcessNaturalExit.final_runner_task_delta_identities.Count -eq 0 -and
                            ($runnerProcessNaturalExit.process_class -cne 'desktop-spotlight' -or
                                ($null -ne $runnerProcessNaturalExit.native_exit -and
                                    $runnerProcessNaturalExit.native_exit['wait_result'] -eq 0 -and
                                    $runnerProcessNaturalExit.native_exit['times_succeeded'] -and
                                    $runnerProcessNaturalExit.native_exit['exit_code_succeeded'] -and
                                    $runnerProcessNaturalExit.native_exit['handle_closed'] -and
                                    $runnerProcessNaturalExit.native_exit['times_win32_error'] -eq 0 -and
                                    $runnerProcessNaturalExit.native_exit['exit_code_win32_error'] -eq 0 -and
                                    $runnerProcessNaturalExit.native_exit['close_win32_error'] -eq 0))
                        if (-not $mayDelete -or -not $jobsClosed -or $taskPresentBeforeDelete -or
                            -not $processSnapshotBeforeCleanup.complete -or
                            $unexpectedRunnerTasksBeforeCleanup.Count -ne 0 -or
                            -not (($unexpectedRunnerProcessesBeforeCleanup.Count -eq 0 -and
                                $runnerProcessNaturalExit.status -ceq 'not-required' -and
                                -not $nativeCapture.failed -and $nativeCapture.observations.Count -eq 0) -or
                                $runnerProcessInitialDeltaAccepted) -or
                            -not $processSnapshotAfterIntervention.complete -or
                            $unexpectedRunnerTasksAfterIntervention.Count -ne 0 -or
                            $unexpectedRunnerProcessesAfterIntervention.Count -ne 0 -or
                            $removedRunnerTasks.Count -ne 0 -or
                            $terminatedRunnerProcesses.Count -ne 0 -or
                            $cleanupResourceErrors.Count -ne 0) {
                            $frozenProcesses = Get-DrVmRunnerProcesses `
                                -UserSid $taskContext.runner_sid `
                                -SessionId $taskContext.runner_session_id
                            $frozenTasks = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                            $ownedAfterFailure = @(Get-CimInstance Win32_Process `
                                -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object {
                                    Test-ProcessExecutableInOwnedRoots -Path $_.ExecutablePath -Prefixes $prefixes
                                } | Sort-Object ProcessId | ForEach-Object {
                                    [ordered]@{ pid = [int]$_.ProcessId; session_id = [int]$_.SessionId; executable_path = [string]$_.ExecutablePath }
                                })
                            $knownFailure = $mayDelete -and $jobsClosed -and
                                -not $taskPresentBeforeDelete -and
                                $processSnapshotBeforeCleanup.complete -and
                                $processSnapshotAfterIntervention.complete -and
                                $frozenProcesses.complete -and
                                $removedRunnerTasks.Count -eq 0 -and
                                $terminatedRunnerProcesses.Count -eq 0 -and
                                $cleanupResourceErrors.Count -eq 0 -and
                                $ownedAfterFailure.Count -eq 0 -and
                                $guestRootPresentBeforeDelete -and $trustedRootPresentBeforeDelete -and
                                $null -ne $global:DrVmOwnedRootRecords.guest -and
                                $null -ne $global:DrVmOwnedRootRecords.trusted -and
                                @($frozenProcesses.processes | Where-Object {
                                    [string]::IsNullOrWhiteSpace([string]$_.identity) -or
                                    [string]::IsNullOrWhiteSpace([string]$_.executable_path)
                                }).Count -eq 0 -and
                                @($frozenTasks | Where-Object {
                                    [string]::IsNullOrWhiteSpace([string]$_.identity) -or
                                    [string]::IsNullOrWhiteSpace([string]$_.definition_sha256)
                                }).Count -eq 0 -and
                                ($unexpectedRunnerTasksBeforeCleanup.Count -gt 0 -or
                                    $unexpectedRunnerProcessesBeforeCleanup.Count -gt 0 -or
                                    $unexpectedRunnerTasksAfterIntervention.Count -gt 0 -or
                                    $unexpectedRunnerProcessesAfterIntervention.Count -gt 0)
                            return [pscustomobject]@{
                                guest_cleanup = $false
                                owned_cleanup_after_strict_failure_eligible = [bool]$knownFailure
                                failed_snapshot = [ordered]@{
                                    complete = [bool]$frozenProcesses.complete
                                    processes = @($frozenProcesses.processes)
                                    tasks = @($frozenTasks)
                                    owned_processes = @($ownedAfterFailure)
                                }
                                root_records = [ordered]@{
                                    guest = $global:DrVmOwnedRootRecords.guest
                                    trusted = $global:DrVmOwnedRootRecords.trusted
                                }
                                raw_cleanup = [ordered]@{
                                    scheduled_task_present = $taskPresentBeforeDelete
                                    guest_root_present = $guestRootPresentBeforeDelete
                                    trusted_task_root_present = $trustedRootPresentBeforeDelete
                                    process_jobs_closed = [bool]$jobsClosed
                                    runner_process_inventory_complete = [bool]($processSnapshotBeforeCleanup.complete -and
                                        $processSnapshotAfterIntervention.complete)
                                    unexpected_runner_tasks = $unexpectedRunnerTasksBeforeCleanup
                                    unexpected_runner_processes = $unexpectedRunnerProcessesBeforeCleanup
                                    unexpected_runner_tasks_after_intervention = $unexpectedRunnerTasksAfterIntervention
                                    unexpected_runner_processes_after_intervention = $unexpectedRunnerProcessesAfterIntervention
                                    unexpected_runner_tasks_after_delete = $null
                                    unexpected_runner_processes_after_delete = $null
                                    removed_runner_tasks = @($removedRunnerTasks | Sort-Object)
                                    terminated_runner_processes = @($terminatedRunnerProcesses)
                                    resource_cleanup_errors = @($cleanupResourceErrors)
                                    runner_process_natural_exit = $runnerProcessNaturalExit
                                    owned_processes_after = @($ownedAfterFailure)
                                }
                            }
                        }
                        foreach ($ownedRoot in @($root,$trustedRoot)) {
                            if (Test-Path -LiteralPath $ownedRoot) {
                                $pending = New-Object 'Collections.Generic.Stack[string]'
                                $pending.Push($ownedRoot)
                                while ($pending.Count -gt 0) {
                                    $directory = $pending.Pop()
                                    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse entry remains; VM directory retained.' }
                                    foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
                                        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse entry remains; VM directory retained.' }
                                        if ($item.PSIsContainer) { $pending.Push($item.FullName) }
                                    }
                                }
                            }
                        }
                        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
                        if (Test-Path -LiteralPath $trustedRoot) { Remove-Item -LiteralPath $trustedRoot -Recurse -Force }
                        $rootPresent = [bool](Test-Path -LiteralPath $root)
                        $trustedRootPresent = [bool](Test-Path -LiteralPath $trustedRoot)
                        $ownedAfter = @(Get-CimInstance Win32_Process `
                            -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object {
                            Test-ProcessExecutableInOwnedRoots -Path $_.ExecutablePath -Prefixes $prefixes
                        } | Sort-Object ProcessId | ForEach-Object {
                            [ordered]@{ pid = [int]$_.ProcessId; session_id = [int]$_.SessionId; executable_path = [string]$_.ExecutablePath }
                        })
                        $ownedScheduledTasksAfterDelete = @(Get-ScheduledTask -ErrorAction Stop |
                            Where-Object {
                                [string]$_.TaskName -ceq $name -and [string]$_.TaskPath -ceq '\'
                            })
                        $taskPresent = $ownedScheduledTasksAfterDelete.Count -gt 0
                        $runnerTasksAfterDelete = @(Get-DrVmRunnerTasks -UserSid $taskContext.runner_sid)
                        $unexpectedRunnerTasksAfterDelete = @($runnerTasksAfterDelete |
                            Where-Object {
                                -not $baselineTasks.Contains([string]$_.identity) -or
                                [string]$_.definition_sha256 -cne [string]$baselineTaskHashes[[string]$_.identity]
                            } |
                            Sort-Object identity)
                        $runnerTaskIdentitiesAfterDelete = [Collections.Generic.HashSet[string]]::new(
                            [StringComparer]::OrdinalIgnoreCase)
                        foreach ($task in $runnerTasksAfterDelete) {
                            [void]$runnerTaskIdentitiesAfterDelete.Add([string]$task.identity)
                        }
                        foreach ($identity in $baselineTasks) {
                            if (-not $runnerTaskIdentitiesAfterDelete.Contains([string]$identity)) {
                                [void]$removedRunnerTasks.Add([string]$identity)
                            }
                        }
                        $processSnapshotAfterDelete = Get-DrVmRunnerProcesses `
                            -UserSid $taskContext.runner_sid `
                            -SessionId $taskContext.runner_session_id
                        $unexpectedRunnerProcessesAfterDelete = @($processSnapshotAfterDelete.processes |
                            Where-Object { -not $baselineProcesses.Contains([string]$_.identity) } |
                            Sort-Object identity)
                        $rawCleanup = [ordered]@{
                            scheduled_task_present = $taskPresent
                            guest_root_present = $rootPresent
                            trusted_task_root_present = $trustedRootPresent
                            process_jobs_closed = [bool]$jobsClosed
                            runner_process_inventory_complete = [bool]($processSnapshotBeforeCleanup.complete -and
                                $processSnapshotAfterIntervention.complete -and
                                $processSnapshotAfterDelete.complete)
                            unexpected_runner_tasks = $unexpectedRunnerTasksBeforeCleanup
                            unexpected_runner_processes = $unexpectedRunnerProcessesBeforeCleanup
                            unexpected_runner_tasks_after_intervention = $unexpectedRunnerTasksAfterIntervention
                            unexpected_runner_processes_after_intervention = $unexpectedRunnerProcessesAfterIntervention
                            unexpected_runner_tasks_after_delete = $unexpectedRunnerTasksAfterDelete
                            unexpected_runner_processes_after_delete = $unexpectedRunnerProcessesAfterDelete
                            removed_runner_tasks = @($removedRunnerTasks | Sort-Object)
                            terminated_runner_processes = @($terminatedRunnerProcesses)
                            resource_cleanup_errors = @($cleanupResourceErrors)
                            runner_process_natural_exit = $runnerProcessNaturalExit
                            owned_processes_after = $ownedAfter
                        }
                        [pscustomobject]@{
                            guest_cleanup = & ([scriptblock]::Create($completionDefinition)) -Observation $rawCleanup
                            raw_cleanup = $rawCleanup
                        }
                        } finally { Close-DrVmSpotlightCaptureContext -Context $nativeCapture }
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
            if ($guestRoot -and -not $transport.guest_cleanup) {
                $retainedPath = Join-Path $transportOutputRoot 'retained-guest-directory.txt'
                $retainedBytes = [Text.UTF8Encoding]::new($false).GetBytes($guestRoot)
                $retainedStream = [IO.FileStream]::new($retainedPath,[IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,[IO.FileShare]::None)
                try {
                    $retainedStream.Write($retainedBytes,0,$retainedBytes.Length)
                    $retainedStream.Flush($true)
                } finally { $retainedStream.Dispose() }
            }
            $ownedHandshake = $null
            try {
                $binding = $env:DR_VM_OWNED_CLEANUP_HANDSHAKE | ConvertFrom-Json -ErrorAction Stop
                $pendingLease = Get-Content -LiteralPath (Join-Path $BundleRoot 'desktop-lease.json') `
                    -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($binding.nonce -cmatch '^[0-9a-f]{32}$' -and
                    $binding.lease_id -cmatch '^[0-9a-f]{32}$' -and
                    $binding.sid -ceq $ExpectedDesktopSid -and
                    $pendingLease.lease_id -ceq $binding.lease_id -and
                    $pendingLease.mode -ceq 'managed-rdp' -and
                    $pendingLease.start_status -ceq 'ready' -and
                    $pendingLease.stop_status -ceq 'failed') {
                    $ownedHandshake = $binding
                }
            } catch { }
            if ((Test-DrControllerOwnedCleanupFailureEligible -CleanupResult $cleanupResult) -and
                $transport.status -ceq 'collected' -and
                $transport.guest_cleanup -eq $false -and
                $processJobsClosed -and
                (-not $observerTask -or $outputPreservedForCleanup) -and
                -not [string]::IsNullOrWhiteSpace($ExpectedDesktopSid) -and
                $ExpectedGuestVmId -ne [guid]::Empty -and
                $null -ne $ownedHandshake) {
                # Freeze the original strict failure and every collected output byte before
                # granting any later owned-root deletion authority.
                $sourceResultLeaf = if ($taskSelection.kind -ceq 'core') {
                    'original-result.json'
                } elseif ($taskSelection.kind -ceq 'ui') {
                    'acceptance-result.json'
                } else {
                    [string]$recoveryInventory.summary_file
                }
                $sourceResultPath = Join-Path $transportOutputRoot $sourceResultLeaf
                if ($taskSelection.kind -ceq 'core') {
                    [IO.File]::Copy((Join-Path $BundleRoot 'result.json'),$sourceResultPath)
                }
                $sourceResultItem = Get-Item -LiteralPath $sourceResultPath -Force -ErrorAction Stop
                $bundleItem = Get-Item -LiteralPath (Join-Path $BundleRoot 'bundle.json') -Force -ErrorAction Stop
                $transport['owned_cleanup_failure_context'] = [ordered]@{
                    task_kind = [string]$taskSelection.kind
                    failed_snapshot = $cleanupResult.failed_snapshot
                    root_records = $cleanupResult.root_records
                    source_result = [ordered]@{
                        file = $sourceResultLeaf; bytes = [long]$sourceResultItem.Length
                        sha256 = (Get-FileHash -LiteralPath $sourceResultPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                    bundle = [ordered]@{
                        file = 'bundle.json'; bytes = [long]$bundleItem.Length
                        sha256 = (Get-FileHash -LiteralPath $bundleItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                    source_sha = if ($manifest.schema_version -eq 2) {
                        [string]$manifest.product.source_sha
                    } else { [string]$manifest.source_sha }
                    observer_sha256 = if ($observerTask) { [string]$observer.sha256 } else { $null }
                    acceptance_mode = if ($taskSelection.kind -ceq 'ui') { [string]$AcceptanceMode } else { $null }
                    high_contrast_requested = [bool]($taskSelection.kind -ceq 'ui' -and $AcceptanceHighContrast)
                    output_preservation_verified = [bool](-not $observerTask -or $outputPreservedForCleanup)
                }
                $transport.status = 'failed'
                $transport['cleanup_error'] = 'Strict OS cleanup delta failed; original raw cleanup is retained.'
                $transportPath = Join-Path $transportOutputRoot 'original-transport.json'
                Write-DrControllerExclusiveJson -Path $transportPath -Value $transport -MaximumBytes 4MB
                if ($result -and $taskSelection.kind -ceq 'core') {
                    $result | Add-Member -NotePropertyName transport -NotePropertyValue $transport -Force
                    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Encoding UTF8
                }
                $originalTransportFrozen = $true
                $transportItem = Get-Item -LiteralPath $transportPath -Force
                $transportHash = (Get-FileHash -LiteralPath $transportPath -Algorithm SHA256).Hash.ToLowerInvariant()
                $nonce = [string]$ownedHandshake.nonce
                $receipt = [ordered]@{
                    schema_version = if ($ownedV2) { 2 } else { 1 }
                    kind = 'owned_cleanup_strict_failure_preservation'
                    run_name = $taskName
                    vm_id = ([guid]$transport.vm_id).ToString('D').ToLowerInvariant()
                    nonce = $nonce
                    desktop_lease_id = [string]$ownedHandshake.lease_id
                    original_transport = [ordered]@{
                        file = 'original-transport.json'; bytes = [long]$transportItem.Length; sha256 = $transportHash
                    }
                    files = @(Get-DrControllerPreservedFiles -Root $transportOutputRoot)
                    failed_snapshot = $cleanupResult.failed_snapshot
                    root_records = $cleanupResult.root_records
                }
                if ($ownedV2) {
                    $receipt['profile_id'] = $AcceptanceProfileId
                    $receipt['profile_sha256'] = $AcceptanceProfileSha256
                }
                $receiptPath = Join-Path $transportOutputRoot 'owned-cleanup-strict-failure-preservation.json'
                # Preflight two complete inventory snapshots and two copies of the root
                # descriptors before any finalizer can delete an owned root. The post
                # snapshot is required to be a subset of this frozen inventory.
                $utf8 = [Text.UTF8Encoding]::new($false,$true)
                $snapshotBytes = $utf8.GetByteCount(($receipt.failed_snapshot | ConvertTo-Json -Depth 24 -Compress))
                $rootBytes = $utf8.GetByteCount(($receipt.root_records | ConvertTo-Json -Depth 24 -Compress))
                if ((2L * $snapshotBytes + 2L * $rootBytes + 32768L) -gt 1MB) {
                    throw 'Owned cleanup proof could exceed its byte bound; owned roots are retained.'
                }
                Write-DrControllerExclusiveJson -Path $receiptPath -Value $receipt -MaximumBytes 1MB
                $receiptHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
                $proofPath = Join-Path $transportOutputRoot 'owned-cleanup-after-strict-failure.json'
                Write-DrControllerExclusiveJson -Path $proofPath -Value ([ordered]@{
                    schema_version=if ($ownedV2) { 2 } else { 1 }
                    kind='owned_cleanup_after_strict_failure'; status='incomplete'
                    run_name=$taskName; vm_id=$receipt.vm_id; errors=@('Finalizer did not complete.')
                }) -MaximumBytes 1MB
                $proof = $null
                $leaseHash = $null
                try {
                    $signalPath = Join-Path $transportOutputRoot 'owned-cleanup-desktop-closed.json'
                    $deadline = [DateTime]::UtcNow.AddSeconds(180)
                    while (-not (Test-Path -LiteralPath $signalPath) -and [DateTime]::UtcNow -lt $deadline) {
                        Start-Sleep -Milliseconds 250
                    }
                    if (-not (Test-Path -LiteralPath $signalPath)) { throw 'Managed desktop closure was not signaled.' }
                    $signal = Get-Content -LiteralPath $signalPath -Raw -ErrorAction Stop | ConvertFrom-Json
                    $leasePath = Join-Path $BundleRoot 'desktop-lease.json'
                    if ($transportOutputRoot -cne $BundleRoot) {
                        $leasePath = Join-Path (Split-Path -Parent $transportOutputRoot) 'desktop-lease.json'
                    }
                    $lease = Get-Content -LiteralPath $leasePath -Raw -ErrorAction Stop | ConvertFrom-Json
                    $leaseHash = (Get-FileHash -LiteralPath $leasePath -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($signal.schema_version -ne $receipt.schema_version -or
                        ($ownedV2 -and ($signal.profile_id -cne $AcceptanceProfileId -or
                            $signal.profile_sha256 -cne $AcceptanceProfileSha256)) -or
                        $signal.nonce -cne $nonce -or
                        $signal.preservation_sha256 -cne $receiptHash -or
                        $signal.desktop_lease_sha256 -cne $leaseHash -or
                        $lease.mode -cne 'managed-rdp' -or $lease.stop_status -cne 'stopped' -or
                        $lease.cleanup_observed -isnot [bool] -or -not $lease.cleanup_observed -or
                        (Get-FileHash -LiteralPath $transportPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $transportHash -or
                        (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $receiptHash) {
                        throw 'Frozen failure evidence or managed desktop closure differs from its receipt.'
                    }
                    $proof = Invoke-DrControllerOwnedCleanupAfterFailure `
                        -Session $session -TaskName $taskName -RunnerSid $desktop.sid `
                        -SessionId $desktop.session_id -ExpectedVmId $receipt.vm_id `
                        -Frozen $receipt.failed_snapshot -Roots $receipt.root_records `
                        -V2Evidence $(if ($ownedV2) { $transport.raw_cleanup.owned_resource_evidence } else { $null }) `
                        -ProfileSha256 $(if ($ownedV2) { $AcceptanceProfileSha256 } else { $null })
                }
                catch {
                    $proof = [pscustomobject]@{
                        schema_version=if ($ownedV2) { 2 } else { 1 }
                        kind='owned_cleanup_after_strict_failure'
                        run_name=$taskName; vm_id=$receipt.vm_id; status='incomplete'
                        pre=$null; post=$null; roots=$receipt.root_records
                        observed_roots_before=$null; observed_roots_after=$null
                        errors=@($_.Exception.Message)
                    }
                }
                Remove-DrControllerProofRemotingMetadata -Proof $proof
                if ($ownedV2) {
                    $proof | Add-Member -NotePropertyName profile_id -NotePropertyValue $AcceptanceProfileId -Force
                    $proof | Add-Member -NotePropertyName profile_sha256 -NotePropertyValue $AcceptanceProfileSha256 -Force
                }
                $proof | Add-Member -NotePropertyName preservation_sha256 -NotePropertyValue $receiptHash -Force
                $proof | Add-Member -NotePropertyName original_transport_sha256 -NotePropertyValue $transportHash -Force
                $proof | Add-Member -NotePropertyName desktop_lease_sha256 -NotePropertyValue $leaseHash -Force
                $proof | Add-Member -NotePropertyName nonce -NotePropertyValue $nonce -Force
                $temporaryProof = $proofPath + '.tmp'
                Write-DrControllerExclusiveJson -Path $temporaryProof -Value $proof -MaximumBytes 1MB
                # PowerShell coerces $null to an empty string for this string overload.
                [IO.File]::Replace($temporaryProof,$proofPath,[NullString]::Value)
            }
        }
    }
    finally {
        Write-DrDiagnosticPhase -Phase 'controller-cleanup' -State 'end' -Details @{ guest_cleanup=[bool]$transport.guest_cleanup }
        if ($runtimeBrokerEnabled) {
            try {
                $remotePhaseErrors = @(Invoke-Command -Session $session -ScriptBlock { @($global:DrRuntimeBrokerPhaseErrors.ToArray()) })
                foreach ($phaseError in $remotePhaseErrors) { if ($runtimeBrokerErrors.Count -lt 64) { $runtimeBrokerErrors.Add([string]$phaseError) } }
            } catch { $runtimeBrokerErrors.Add('Controller phase error collection failed.') }
        }
        $controllerCleanupErrors = @(Close-DrControllerResources `
            -Session $session -Credential $credential -Mutex $mutex -MutexHeld $mutexHeld)
        if ($controllerCleanupErrors.Count -gt 0) {
            $transport.status = 'failed'
            $transport['controller_cleanup_errors'] = $controllerCleanupErrors
        }
        $transport | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'transport.json') -Encoding UTF8
        if ($runtimeBrokerEnabled) {
            [ordered]@{ schema_version=1; run_id=$RuntimeBrokerDiagnosticRunId; preparation_only=[bool]$RuntimeBrokerPreparationOnly
                preparation_completed=$runtimeBrokerPrepared; acceptance_claim=$false; controller_status=[string]$transport.status
                guest_cleanup=[bool]$transport.guest_cleanup; phase_errors=@($runtimeBrokerErrors.ToArray())
                controller_elapsed_ms=$runtimeBrokerClock.ElapsedMilliseconds; controller_budget_seconds=$RuntimeBrokerDiagnosticBudgetSeconds
                controller_deadline_exceeded=($runtimeBrokerClock.Elapsed.TotalSeconds -gt $RuntimeBrokerDiagnosticBudgetSeconds)
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $transportOutputRoot 'runtimebroker-controller.json') -Encoding UTF8
        }
        if (-not $originalTransportFrozen -and $result -and $taskSelection.kind -ceq 'core') {
            $result | Add-Member -NotePropertyName transport -NotePropertyValue $transport -Force
            $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $BundleRoot 'result.json') -Encoding UTF8
        }
    }
}
if ($RuntimeBrokerPreparationOnly) {
    if (-not $runtimeBrokerPrepared -or $transport.status -cne 'diagnostic-prepared' -or -not $transport.guest_cleanup) {
        throw 'RuntimeBroker preparation-only diagnostic or cleanup failed; inspect transport.json.'
    }
    return
}
if ($transport.status -ne 'collected' -or -not $transport.guest_cleanup -or
    ($observerTask -and -not $acceptancePassed)) {
    throw 'VM transport, acceptance, or cleanup failed; inspect transport.json.'
}
}

Export-ModuleMember -Function Invoke-DrWindowsVmController
