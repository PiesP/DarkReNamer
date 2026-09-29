param([Parameter(Mandatory)][string] $Configuration)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# This bridge is invoked only from frozen, verified bytes by the diagnostic CLI.
# Its private PSSession owns the observer job. RuntimeBroker is never assigned
# to that job and no OS process is stopped by this bridge.
function Read-DrBrokerRpc {
    param([string] $Text)
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -gt 8192) { throw 'RPC exceeds its bound.' }
    $json = [Text.Json.JsonDocument]::Parse($Text)
    try {
        function Assert-Unique([Text.Json.JsonElement] $Element) {
            if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($field in $Element.EnumerateObject()) {
                    if (-not $names.Add($field.Name)) { throw 'Duplicate RPC field.' }
                    Assert-Unique $field.Value
                }
            } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $Element.EnumerateArray()) { Assert-Unique $item }
            }
        }
        Assert-Unique $json.RootElement
    } finally { $json.Dispose() }
    $Text | ConvertFrom-Json
}

$configItem=Get-Item -LiteralPath $Configuration -Force
if($configItem.PSIsContainer -or ($configItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $configItem.Length -gt 8MB){throw 'Bridge configuration must be a bounded ordinary file.'}
$configBytes = [IO.File]::ReadAllBytes($Configuration)
if ($configBytes.Length -gt 8MB) { throw 'Bridge configuration exceeds its bound.' }
$config = [Text.UTF8Encoding]::new($false, $true).GetString($configBytes) | ConvertFrom-Json
if ($config.schema_version -ne 1 -or $config.run_id -cnotmatch '^[a-f0-9]{32}$' -or
    $config.runner_sid -cnotmatch '^S-1-5-21-(?:\d+-){2}\d+-\d+$' -or
    [int]$config.duration_seconds -lt 1 -or [int]$config.duration_seconds -gt 900 -or
    $config.ssh_host -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'Bridge configuration identity is invalid.' }
if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw 'Bridge requires PowerShell 7.4.' }
$session = $null
$sequence = 0
$staged = $false
$bridgeClock=[Diagnostics.Stopwatch]::StartNew()
try {
    $session = New-PSSession -HostName $config.ssh_host -Options @{
        BatchMode = 'yes'; StrictHostKeyChecking = 'yes'; ForwardAgent = 'no'
    }
    $config.duration_seconds=[Math]::Floor([double]$config.duration_seconds-$bridgeClock.Elapsed.TotalSeconds)
    if($config.duration_seconds -lt 1){throw 'Observer staging deadline exhausted.'}
    [void](Invoke-Command -Session $session -ArgumentList $config -ScriptBlock {
        param($config)
        $stageClock=[Diagnostics.Stopwatch]::StartNew()
        $ErrorActionPreference = 'Stop'
        function Convert-DrBrokerSource([byte[]]$Bytes) {
            # Digests bind original bytes; the parser receives text without its
            # encoding marker, which otherwise becomes part of 'function'.
            [Text.UTF8Encoding]::new($false,$true).GetString($Bytes).TrimStart([char]0xfeff)
        }
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
            $PSVersionTable.PSVersion -lt [version]'7.4') { throw 'Observer endpoint is not the configured Windows SSH subsystem.' }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $sid = $identity.User.Value
            $admin = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
        } finally { $identity.Dispose() }
        $actualVm = [guid](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -Name VirtualMachineId).VirtualMachineId
        if (-not $admin -or $sid -cne $config.runner_sid -or $actualVm -ne [guid]$config.vm_id) {
            throw 'Observer VM, elevated SSH account, or runner SID differs.'
        }
        $root = 'C:\ProgramData\DarkReNamerRuntimeBrokerDiag-' + $config.run_id
        foreach ($ancestor in @('C:\', 'C:\ProgramData')) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Observer root ancestry is not ordinary.'
            }
        }
        if (Test-Path -LiteralPath $root) { throw 'Observer root already exists; attempts cannot retry.' }
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        $administrator = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $security.SetOwner($administrator)
        $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        foreach ($principal in @('S-1-5-32-544', 'S-1-5-18')) {
            [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($principal),
                [Security.AccessControl.FileSystemRights]::FullControl, $inherit,
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        }
        [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid),
            [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inherit,
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        [void][IO.FileSystemAclExtensions]::CreateDirectory($security, $root)
        $sources = @{}
        $allowed = @('powershell-runtimebroker-observer','powershell-guest-contracts','powershell-guest-process','powershell-guest-native')
        foreach ($row in $config.files) {
            if ($row.role -cnotin $allowed -or $sources.ContainsKey($row.role) -or
                $row.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
                $row.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Collector module inventory is invalid.' }
            $bytes = [Convert]::FromBase64String($row.data)
            if ($bytes.Length -gt 8MB) { throw 'Collector module exceeds its source bound.' }
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            if ($hash -cne $row.sha256) { throw 'Collector module differs from verified bytes.' }
            $path = Join-Path $root $row.name
            $file = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            try { $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() }
            $sources[$row.role] = Convert-DrBrokerSource $bytes
        }
        if ($sources.Count -ne 4) { throw 'Collector module closure is incomplete.' }
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'phases'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'compile'))
        $global:DrBrokerBridge = [ordered]@{root=$root;run_id=$config.run_id;runner_sid=$sid;vm_id=$config.vm_id;
            module=$null;state=$null;closed=$false;clean=$false;removed=$false;inventory=$null}
        $global:DrBrokerBridge.module = New-Module -Name ('DarkReNamer.BrokerBridge.'+$config.run_id) -ArgumentList (,$sources) -ScriptBlock {
            param($sources)
            foreach ($role in @('powershell-guest-contracts','powershell-guest-native','powershell-guest-process')) {
                . ([scriptblock]::Create($sources[$role]))
            }
        }
        $oldTemp=$env:TEMP;$oldTmp=$env:TMP
        try {
            $env:TEMP=Join-Path $root 'compile';$env:TMP=$env:TEMP
            $observerRow = @($config.files | Where-Object role -CEQ 'powershell-runtimebroker-observer')[0]
            # Hash-verified source is read by an encoded bootstrap without changing
            # the configured execution policy. The PS5 observer owns its handles.
            $quote = { param([string]$value) "'"+$value.Replace("'","''")+"'" }
            $remaining=[Math]::Floor([double]$config.duration_seconds-$stageClock.Elapsed.TotalSeconds)
            if($remaining -lt 1){throw 'Observer staging deadline exhausted.'}
            $command = '$ErrorActionPreference=''Stop'';$ProgressPreference=''SilentlyContinue'';'+
                '$env:TEMP='+(& $quote (Join-Path $root 'compile'))+';$env:TMP=$env:TEMP;'+
                '$p='+(& $quote (Join-Path $root $observerRow.name))+';'+
                '$b=[IO.File]::ReadAllBytes($p);$h=[Security.Cryptography.SHA256]::Create();'+
                'try{$actual=([BitConverter]::ToString($h.ComputeHash($b))).Replace(''-'','''').ToLowerInvariant()}finally{$h.Dispose()};'+
                'if($actual -cne '+(& $quote $observerRow.sha256)+'){throw ''Observer source digest differs.''};'+
                '. ([scriptblock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($b).TrimStart([char]0xfeff)));'+
                'Invoke-DrRuntimeBrokerObserver -Root '+(& $quote $root)+' -RunId '+(& $quote $config.run_id)+
                ' -RunnerSid '+(& $quote $sid)+' -ExpectedVmId '+(& $quote $config.vm_id)+
                ' -DurationSeconds '+[int]$remaining
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $global:DrBrokerBridge.state = & $global:DrBrokerBridge.module {
                param($root,$encoded)
                Start-JobBoundProcess -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                    -Arguments ('-NoLogo -NoProfile -NonInteractive -EncodedCommand '+$encoded) -WorkingDirectory $root `
                    -StdoutPath (Join-Path $root 'observer.stdout.log') -StderrPath (Join-Path $root 'observer.stderr.log') `
                    -AggregateOutputLimitBytes 65536
            } $root $encoded
        } finally {$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
    })
    $staged = $true
    while ($null -ne ($line = [Console]::In.ReadLine())) {
        $request = $null
        try {
            $request = Read-DrBrokerRpc $line
            $fields = @($request.PSObject.Properties.Name | Sort-Object)
            if (($fields -join ',') -cne 'operation,payload,run_id,sequence' -or
                $request.run_id -cne $config.run_id -or $request.sequence -ne ($sequence+1) -or
                $request.operation -cnotin @('ready','phase','stop','inventory','read','cleanup')) {
                throw 'RPC operation, run identity, or sequence differs.'
            }
            $sequence = [int]$request.sequence
            $resultJson = Invoke-Command -Session $session -ArgumentList $request -ScriptBlock {
                param($request)
                $s=$global:DrBrokerBridge
                if($null -eq $s -or $s.run_id -cne $request.run_id -or $s.removed){throw 'Observer ownership state unavailable.'}
                $rootItem=Get-Item -LiteralPath $s.root -Force
                $rootAcl=Get-Acl -LiteralPath $s.root
                if(-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                    -not $rootAcl.AreAccessRulesProtected -or
                    $rootAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin @('S-1-5-32-544','S-1-5-18')){throw 'Observer protected root changed.'}
                function Read-Ordinary([string]$path,[long]$maximum) {
                    $item=Get-Item -LiteralPath $path -Force
                    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt $maximum){throw 'Diagnostic member is unsafe or oversized.'}
                    [IO.File]::ReadAllBytes($path)
                }
                function Write-New([string]$path,[byte[]]$bytes) {
                    $temporary=Join-Path $s.root ('bridge-publication-'+[guid]::NewGuid().ToString('N')+'.tmp')
                    $f=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                    try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
                    [IO.File]::Move($temporary,$path)
                }
                $value = switch ($request.operation) {
                    ready {
                        $s.state.process.Refresh();$alive=-not $s.state.process.HasExited
                        $readyPath=Join-Path $s.root 'ready.json'
                        $ready=$false
                        if(Test-Path -LiteralPath $readyPath){
                            $r=[Text.UTF8Encoding]::new($false,$true).GetString((Read-Ordinary $readyPath 65536))|ConvertFrom-Json
                            if($r.schema_version -ne 1 -or $r.run_id -cne $s.run_id -or $r.runner_sid -cne $s.runner_sid -or
                                [guid]$r.expected_vm_id -ne [guid]$s.vm_id -or $r.status -cne 'ready' -or
                                $r.subscriptions_started_before_snapshot -ne $true -or $r.initial_snapshot_complete -ne $true){throw 'Observer READY binding or coverage differs.'}
                            $ready=$true
                        }
                        [ordered]@{ready=$ready;alive=$alive;root=$s.root;run_id=$s.run_id;runner_sid=$s.runner_sid;vm_id=$s.vm_id}
                    }
                    phase {
                        if($s.closed){throw 'Observation already closed.'}
                        $p=$request.payload
                        if($p.phase -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or $p.state -cnotin @('begin','end','observed')){throw 'Phase label/state invalid.'}
                        $phases=Join-Path $s.root 'phases'
                        if(@(Get-ChildItem -LiteralPath $phases -File).Count -ge 191){throw 'Phase reservation exhausted.'}
                        $marker=[ordered]@{schema_version=1;run_id=$s.run_id;phase=$p.phase;state=$p.state;
                            recorded_at_utc=$p.recorded_at_utc;source='host';details=$p.details}
                        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($marker|ConvertTo-Json -Depth 8 -Compress))
                        if($bytes.Length -gt 4096){throw 'Phase marker exceeds its bound.'}
                        Write-New (Join-Path $phases ([guid]::NewGuid().ToString('N')+'.json')) $bytes
                        [ordered]@{written=$true;clock_domain='host'}
                    }
                    stop {
                        if(-not $s.closed){
                            $stop=Join-Path $s.root 'stop-request.json'
                            if(-not(Test-Path -LiteralPath $stop)){
                                Write-New $stop ([Text.Encoding]::UTF8.GetBytes((@{schema_version=1;run_id=$s.run_id}|ConvertTo-Json -Compress)))
                            }
                            [void]$s.state.process.WaitForExit(20000)
                            $s.clean=& $s.module {param($state) Close-JobBoundProcess -State $state} $s.state
                            $s.closed=$true
                        }
                        [ordered]@{clean=[bool]$s.clean;closed=[bool]$s.state.job_closed;empty=[bool]$s.state.job_empty;
                            forced_termination=[bool]$s.state.job_forced_termination;error=$s.state.job_cleanup_error}
                    }
                    inventory {
                        if(-not $s.closed -or -not $s.state.job_closed -or -not $s.state.job_empty){throw 'Observer job is not closed and empty.'}
                        $rows=[Collections.Generic.List[object]]::new()
                        foreach($name in @('ready.json','events.jsonl','result.json','observer.stdout.log','observer.stderr.log')){
                            $path=Join-Path $s.root $name
                            if(Test-Path -LiteralPath $path){
                                $bytes=Read-Ordinary $path 14MB
                                $rows.Add(@{name=$name;size=$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()})
                            }
                        }
                        foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $s.root 'phases') -Force)){
                            if($file.Name -cnotmatch '^[a-f0-9]{32}\.json$'){throw 'Unexpected phase member.'}
                            $bytes=Read-Ordinary $file.FullName 4096
                            $rows.Add(@{name='phases/'+$file.Name;size=$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()})
                        }
                        $s.inventory=@($rows.ToArray());,$s.inventory
                    }
                    read {
                        $p=$request.payload
                        $row=@($s.inventory|Where-Object name -CEQ $p.name)
                        if($row.Count -ne 1 -or $p.offset -lt 0 -or $p.count -lt 1 -or $p.count -gt 49152 -or
                            [long]$p.offset+[long]$p.count -gt $row[0].size){throw 'Diagnostic read is outside frozen inventory.'}
                        $bytes=Read-Ordinary (Join-Path $s.root $p.name.Replace('/','\')) 14MB
                        if($bytes.Length -ne $row[0].size -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $row[0].sha256){throw 'Frozen diagnostic member changed.'}
                        [Convert]::ToBase64String($bytes,[int]$p.offset,[int]$p.count)
                    }
                    cleanup {
                        if(-not $s.closed -or -not $s.state.job_closed -or -not $s.state.job_empty -or $null -eq $s.inventory){throw 'Owned observer cleanup has no closed job/collected inventory.'}
                        $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($s.root);$count=0
                        while($pending.Count -gt 0){
                            foreach($item in @(Get-ChildItem -LiteralPath $pending.Dequeue() -Force)){
                                $count++
                                if($count -gt 512){throw 'Owned observer root exceeds cleanup count bound.'}
                                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Owned observer root contains a reparse member; retained.'}
                                if($item.PSIsContainer){$pending.Enqueue($item.FullName)}
                            }
                        }
                        Remove-Item -LiteralPath $s.root -Recurse -Force
                        $s.removed=-not(Test-Path -LiteralPath $s.root)
                        [ordered]@{removed=[bool]$s.removed;root=$s.root}
                    }
                }
                # Serialize before remoting adds transport annotations.
                ConvertTo-Json -InputObject $value -Depth 10 -Compress
            }
            $result=[string]$resultJson | ConvertFrom-Json
            $response=[ordered]@{sequence=$sequence;ok=$true;result=$result;error=$null}
        } catch {
            $response=[ordered]@{sequence=if($null -ne $request){$request.sequence}else{$sequence+1};ok=$false;result=$null;error=$_.Exception.Message.Substring(0,[Math]::Min(4096,$_.Exception.Message.Length))}
        }
        [Console]::Out.WriteLine(($response|ConvertTo-Json -Depth 12 -Compress))
        [Console]::Out.Flush()
        if(-not $response.ok){break}
    }
} finally {
    if($null -ne $session){
        try {
            # EOF, malformed RPC and disconnect retain evidence and close only the
            # job containing this bridge's observer/compiler descendants.
            [void](Invoke-Command -Session $session -ScriptBlock {
                $s=$global:DrBrokerBridge
                if($null -ne $s){
                    if($null -ne $s.state){
                        try {
                            if(-not $s.closed){
                                $stop=Join-Path $s.root 'stop-request.json'
                                if(-not(Test-Path -LiteralPath $stop)){
                                    $temporary=Join-Path $s.root ('bridge-stop-'+[guid]::NewGuid().ToString('N')+'.tmp')
                                    $bytes=[Text.Encoding]::UTF8.GetBytes((@{schema_version=1;run_id=$s.run_id}|ConvertTo-Json -Compress))
                                    $file=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                                    try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
                                    [IO.File]::Move($temporary,$stop)
                                }
                                [void]$s.state.process.WaitForExit(20000)
                                [void](& $s.module {param($state) Close-JobBoundProcess -State $state} $s.state)
                            }
                        } finally {$s.state.owner.Dispose()}
                    }
                    if($null -ne $s.module){Remove-Module -ModuleInfo $s.module -Force}
                }
            })
        } finally {Remove-PSSession -Session $session -ErrorAction Stop}
    }
}
