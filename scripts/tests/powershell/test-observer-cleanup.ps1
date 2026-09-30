[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/windows-vm-module-loader.ps1')
foreach ($kind in @('guest', 'recovery', 'controller')) {
    foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind $kind)) { . $definition }
}

function Assert-Fails {
    param([scriptblock] $Action, [string] $Expected)
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure: $Expected"
}

# Reject case variants at real public boundaries before source or VM acquisition.
foreach ($entry in @(
    @{file='run-windows-vm-tests.ps1';args=@{BundleRoot='unused';SshHost='fixture'}},
    @{file='windows-vm-guest.ps1';args=@{BundleRoot='unused';ExpectedSessionId=1;ValidateOnly=$true}},
    @{file='windows-vm-acceptance.ps1';args=@{BundleRoot='unused';ExpectedSessionId=1;OutputRoot='unused';ExpectedScriptSha256=('a'*64);ValidateOnly=$true}},
    @{file='windows-vm-recovery-acceptance.ps1';args=@{BundleRoot='unused';ExpectedSessionId=1;OutputRoot='unused';PrivateEvidenceRoot='unused';ExpectedScriptSha256=('a'*64);ValidateOnly=$true}}
)) {
    $entryPath=Join-Path $PSScriptRoot ('../../'+$entry.file)
    foreach ($profile in @('VM-AUTOMATED-V1-WIN11-NTFS','VM-AUTOMATED-V2-OWNED-RESOURCES')) {
        $arguments=$entry.args.Clone()
        $arguments.AcceptanceProfileId=$profile
        Assert-Fails { & $entryPath @arguments } 'Unsupported VM acceptance profile identity.'
    }
}

# A rescue descendant is owned even when its image and command omit run paths.
& {
    $source=Join-Path $PSScriptRoot '../../modules/powershell/controller-entry.psm1'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
    foreach ($functionName in @('Get-V2OwnedScopeProcesses','Assert-V2Inventory')) {
        $definitions=@($ast.FindAll({param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
        },$true))
        if($errors.Count -or $definitions.Count -ne 1){throw 'V2 owned inventory function is not unique.'}
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $name='unique-run';$root='C:\owned\run';$trustedRoot='C:\owned\run-trusted'
    $roots=@{guest=@{path=$root};trusted=@{path=$trustedRoot}}
    $sid='fixture';$desktopSession=2
    $taskContext=@{declared_processes=@();baseline_tasks=@();preflight_child=@{pid=1};engine_child=@{pid=2}
        task_execution=@{observer_lifecycle=@{pid=3}}
        rescue_executions=@(@{task_execution=@{observer_lifecycle=@{pid=777}}})}
    $v2Evidence=$taskContext
    $owned=[pscustomobject]@{pid=900;parent_pid=777;identity='900|start';owner_sid=$sid;session_id=2
        executable_path='C:\Windows\helper.exe';command_line='C:\Windows\helper.exe -Embedding'}
    $ambient=[pscustomobject]@{pid=901;parent_pid=0;identity='901|start';owner_sid=$sid;session_id=2
        executable_path='C:\Windows\ambient.exe';command_line='C:\Windows\ambient.exe -Embedding'}
    $found=@(Get-V2OwnedScopeProcesses @{processes=@($owned,$ambient)})
    if($found.Count -ne 1 -or $found[0].pid -ne 900){throw 'Rescue descendant escaped normal owned scope.'}
    Assert-V2Inventory @{tasks=@();processes=@($ambient)} @{processes=@()}
    Assert-Fails { Assert-V2Inventory @{tasks=@();processes=@($owned)} @{processes=@()} } 'protected execution scope'
}

# Exercise the host binding through the authenticated guest's native argv decoder.
& {
    $source=Join-Path $PSScriptRoot '../../modules/powershell/controller-entry.psm1'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
    $definition=@($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Complete-DrControllerV2TaskExecution'
    },$true))
    if($errors.Count -or $definition.Count -ne 1){throw 'V2 task binding function is not unique.'}
    . ([scriptblock]::Create($definition[0].Extent.Text))
    function Invoke-Command {
        param($Session,[object[]]$ArgumentList,$ScriptBlock)
        if($ArgumentList.Count -eq 1){return $true}
        & $ScriptBlock @ArgumentList
    }
    function Get-DrVmCommandLineArguments {
        param($CommandLine)
        if($CommandLine -ceq ('task.exe ' + $registeredArguments)) {
            return ,([string[]]$registeredArgv)
        }
        if($CommandLine -ceq $observedLine) {
            if($null -eq $observedArgv){throw 'Native argv parse failed.'}
            return ,([string[]]$observedArgv)
        }
        throw 'Unexpected native argv input.'
    }
    if($IsWindows) {
        $nativeDefinition=@($ast.FindAll({param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'global:Get-DrVmCommandLineArguments'
        },$true))
        if($nativeDefinition.Count -ne 1){throw 'Native Windows argv parser is not unique.'}
        . ([scriptblock]::Create($nativeDefinition[0].Extent.Text.Replace(
            'function global:Get-DrVmCommandLineArguments',
            'function Get-DrVmCommandLineArguments')))
        $quoted='-Value "a\"b" -Path "C:\space dir\\"'
        $adjacent='-Value "a""b" -Path "C:\space dir\\"'
        $registeredNative=[string[]](Get-DrVmCommandLineArguments -CommandLine ('task.exe '+$quoted))
        $observedNative=[string[]](Get-DrVmCommandLineArguments -CommandLine ('"C:\Program Files\PowerShell\7\pwsh.dll" '+$adjacent))
        if($registeredNative.Count -ne 5 -or $observedNative.Count -ne 5 -or
            $registeredNative[1] -cne '-Value' -or $registeredNative[2] -cne 'a"b' -or
            $registeredNative[4] -cne 'C:\space dir\') {
            throw 'Native argv parsing changed adjacent quote or backslash semantics.'
        }
        for($index=1;$index -lt $registeredNative.Count;$index++) {
            if($registeredNative[$index] -cne $observedNative[$index]) {
                throw 'Native argv parsing changed adjacent quote or backslash semantics.'
            }
        }
    }
    $exe='C:\Program Files\PowerShell\7\pwsh.exe'
    $dll='C:\Program Files\PowerShell\7\pwsh.dll'
    $name='DarkReNamerTests-1234'
    $root='C:\ProgramData\DarkReNamerVmRuns\'+$name+'-trusted'
    foreach($rescue in @($false,$true)) {
        $switch=if($rescue){' -RestoreTextScaleOnly'}else{''}
        $registeredArguments='-NoProfile -File "'+$root+'\windows-vm-guest.ps1" '+
            '-AcceptanceProfileId vm-automated-v2-owned-resources -ElevatedObserver '+
            '-TrustedResultPath "'+$root+'\out\core-result.json"'+$switch
        $observedLine='"'+$dll+'" -NoProfile -File '+$root+'\windows-vm-guest.ps1 '+
            '-AcceptanceProfileId vm-automated-v2-owned-resources -ElevatedObserver '+
            '-TrustedResultPath '+$root+'\out\core-result.json'+$switch
        $registeredArgv=@('task.exe','-NoProfile','-File',($root+'\windows-vm-guest.ps1'),
            '-AcceptanceProfileId','vm-automated-v2-owned-resources','-ElevatedObserver',
            '-TrustedResultPath',($root+'\out\core-result.json'))
        if($rescue){$registeredArgv+= '-RestoreTextScaleOnly'}
        $observedArgv=@($dll)+@($registeredArgv[1..($registeredArgv.Count-1)])
        $lifecycle=[pscustomobject]@{pid=[long]901;start_time_utc_ticks='134041000000000003';
            session_id=2;owner_sid='fixture';image_path=$exe;command_line=$observedLine}
        $engine=[pscustomobject]@{action_executable=$exe;action_arguments=$registeredArguments;
            registered_last_run_time_ticks=[long]10}
        $values=@{Session='fixture';TaskName=$name;RunnerSid='fixture';SessionId=2;
            Engine=$engine;CompletedTicks=[long]11;TaskResult=[long]0;
            Result=[pscustomobject]@{observer_lifecycle=$lifecycle}}
        $bound=Complete-DrControllerV2TaskExecution @values
        if(-not $bound.terminal -or $bound.observer_lifecycle.pid -ne 901){
            throw 'Equivalent v2 task argv failed its lifetime binding.'
        }
        foreach($mutation in @(
            @{label='extra flag';line=$observedLine+' -Unexpected';argv=@($observedArgv)+@('-Unexpected')},
            @{label='duplicate flag';line=$observedLine+' -ElevatedObserver';argv=@($observedArgv)+@('-ElevatedObserver')},
            @{label='changed profile';line=$observedLine.Replace('vm-automated-v2-owned-resources','other-profile');
                argv=@($observedArgv | ForEach-Object {if($_ -ceq 'vm-automated-v2-owned-resources'){'other-profile'}else{$_}})},
            @{label='changed path';line=$observedLine.Replace('core-result.json','other-result.json');
                argv=@($observedArgv | ForEach-Object {if($_ -like '*core-result.json'){$_.Replace('core-result.json','other-result.json')}else{$_}})},
            @{label='unrelated argv0';line=$observedLine.Replace('pwsh.dll','other.dll');
                argv=@('C:\Program Files\PowerShell\7\other.dll')+@($observedArgv[1..($observedArgv.Count-1)])},
            @{label='extra prefix';line='"C:\Other\launcher.exe" '+$observedLine;
                argv=@('C:\Other\launcher.exe')+@($observedArgv)},
            @{label='malformed quote';line=$observedLine+' "unterminated';argv=$null}
        )) {
            $observedLine=$mutation.line
            $observedArgv=$mutation.argv
            $lifecycle.command_line=$observedLine
            $failure=if($null -eq $observedArgv -and -not $IsWindows){'Native argv parse failed.'}else{'did not bind'}
            Assert-Fails { Complete-DrControllerV2TaskExecution @values } $failure
        }
    }
}

# Exercise the production atomic replacement expression with actual files.
$replaceRoot = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-proof-replace-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($replaceRoot)
try {
    $proofPath = Join-Path $replaceRoot 'proof.json'
    $temporaryProof = $proofPath + '.tmp'
    [IO.File]::WriteAllText($proofPath, '{"status":"incomplete"}')
    [IO.File]::WriteAllText($temporaryProof, '{"status":"complete"}')
    $controllerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../modules/powershell/controller-entry.psm1') -Raw
    $replacement = [regex]::Matches($controllerSource, '(?m)^\s*\[IO\.File\]::Replace\(\$temporaryProof,\$proofPath,[^\r\n]+')
    if ($replacement.Count -ne 1) { throw 'The production proof replacement expression was not unique.' }
    & ([scriptblock]::Create($replacement[0].Value.Trim()))
    if ([IO.File]::ReadAllText($proofPath) -cne '{"status":"complete"}' -or
        (Test-Path -LiteralPath $temporaryProof) -or
        @(Get-ChildItem -LiteralPath $replaceRoot).Count -ne 1) {
        throw 'Atomic proof replacement did not publish the complete proof without residue.'
    }
}
finally { Remove-Item -LiteralPath $replaceRoot -Recurse -Force }

# Execute the finalizer's actual inventory predicate against owned and adjacent paths.
& {
    $roots = @{guest=@{path='C:\owned\run'};trusted=@{path='C:\owned\run-trusted'}}
    $sid = 'fixture'; $desktopSession = 2; $name = 'fixture'; $v2 = $false
    function Get-DrVmRunnerProcesses { param($UserSid,$SessionId,[switch]$IncludeExecutionScope); @{complete=$true;processes=@()} }
    function Get-DrVmRunnerTasks { param($UserSid) }
    function Get-ScheduledTask { param($ErrorAction) }
    function Get-CimInstance {
        param($ClassName,$OperationTimeoutSec,$ErrorAction)
        $paths = @('C:\owned\run\app.exe','c:\OWNED\run-trusted\app.exe',
            'C:\Windows\system32\DllHost.exe','C:\owned\run-other\app.exe',
            'C:\owned\run-trusted-other\app.exe',$null)
        for ($i=0; $i -lt $paths.Count; $i++) {
            [pscustomobject]@{ProcessId=$i+1;SessionId=2;ExecutablePath=$paths[$i]}
        }
    }
    $source = Join-Path $PSScriptRoot '../../modules/powershell/controller-entry.psm1'
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
    $inventory=@($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Get-CurrentOwnedInventory'
    },$true))
    if ($errors.Count -ne 0 -or $inventory.Count -ne 1) { throw 'Finalizer inventory definition is unavailable.' }
    . ([scriptblock]::Create($inventory[0].Extent.Text))
    $observed=Get-CurrentOwnedInventory
    if (-not $observed.complete -or $observed.owned_processes.Count -ne 2 -or
        $observed.owned_processes[0].pid -ne 1 -or $observed.owned_processes[1].pid -ne 2) {
        throw 'Finalizer inventory classified unrelated, adjacent, or unknown paths as owned.'
    }
}

# Remoting annotations must not alter the exact independent proof schema.
Invoke-DrTestPowerShellModuleScope -Kind controller -Action {
    foreach ($shape in @('object','dictionary','deserialized-dictionary')) {
        $proof = if ($shape -ceq 'object') { [pscustomobject]@{status='incomplete';errors=@('retained');unexpected='retained'} }
            else { [ordered]@{status='incomplete';errors=@('retained');unexpected='retained'} }
        if ($shape -ceq 'deserialized-dictionary') {
            $proof = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($proof))
        }
        foreach ($name in @('PSComputerName','RunspaceId','PSShowComputerName')) {
            $proof | Add-Member -NotePropertyName $name -NotePropertyValue 'transport' -Force
        }
        Remove-DrControllerProofRemotingMetadata -Proof $proof
        $json = $proof | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json
        if ($json.status -cne 'incomplete' -or $json.errors[0] -cne 'retained' -or
            $json.unexpected -cne 'retained' -or @($json.PSObject.Properties.Name).Count -ne 3) {
            throw "Proof payload changed or remoting annotations leaked for $shape."
        }
    }
    $proof = @{status='incomplete';PSComputerName='transport';RunspaceId='transport';PSShowComputerName=$true}
    Remove-DrControllerProofRemotingMetadata -Proof $proof
    if ($proof.Count -ne 1 -or $proof.status -cne 'incomplete') { throw 'Dictionary annotation keys remained.' }
}

# Test the same completion predicate serialized into the guest cleanup command.
Invoke-DrTestPowerShellModuleScope -Kind controller -Action {
    foreach ($result in @($null, [pscustomobject]@{guest_cleanup=$true},
        [pscustomobject]@{owned_cleanup_after_strict_failure_eligible=$false},
        [pscustomobject]@{owned_cleanup_after_strict_failure_eligible='true'},
        [pscustomobject]@{owned_cleanup_after_strict_failure_eligible=1})) {
        if (Test-DrControllerOwnedCleanupFailureEligible -CleanupResult $result) {
            throw 'Absent or unknown failure context must not authorize owned cleanup.'
        }
    }
    if (-not (Test-DrControllerOwnedCleanupFailureEligible -CleanupResult (
        [pscustomobject]@{owned_cleanup_after_strict_failure_eligible=$true}))) {
        throw 'An explicit typed eligibility result was not recognized.'
    }
    function New-CleanObservation {
        [pscustomobject]@{
            scheduled_task_present = $false; guest_root_present = $false; trusted_task_root_present = $false
            process_jobs_closed = $true; runner_process_inventory_complete = $true
            unexpected_runner_tasks = @(); unexpected_runner_processes = @()
            unexpected_runner_tasks_after_intervention = @(); unexpected_runner_processes_after_intervention = @()
            unexpected_runner_tasks_after_delete = @(); unexpected_runner_processes_after_delete = @()
            removed_runner_tasks = @(); terminated_runner_processes = @(); resource_cleanup_errors = @()
            owned_processes_after = @(); runner_process_natural_exit = [pscustomobject]@{
                schema_version=2;process_class=$null;native_exit=$null;initial_native_observations=@()
                status='not-required';candidate_identity=$null;natural_exit_observed=$false
                final_inventory_complete=$true;final_runner_process_delta_identities=@();final_runner_task_delta_identities=@()
            }
        }
    }
    $completion = [scriptblock]::Create(${function:Test-DrControllerCleanupObservation}.ToString())
    $clean = New-CleanObservation
    if (-not (& $completion -Observation $clean)) { throw 'Observed-empty cleanup did not pass.' }
    if (& $completion -Observation $null) { throw 'Missing cleanup evidence passed.' }
    foreach ($field in $clean.PSObject.Properties.Name) {

        foreach ($mutation in @('missing', 'null', 'residue', 'wrong-type')) {
            $raw = New-CleanObservation
            switch ($mutation) {
                'missing' { $raw.PSObject.Properties.Remove($field) }
                'null' { $raw.$field = $null }
                'wrong-type' { $raw.$field = 'false' }
                'residue' {
                    $raw.$field = if ($field -in @('process_jobs_closed', 'runner_process_inventory_complete')) { $false } `
                        elseif ($field -like '*present') { $true } else { @([pscustomobject]@{ identity = 'residue' }) }
                }
            }
            if (& $completion -Observation $raw) { throw "Cleanup accepted $mutation evidence for $field." }
        }
    }
    $raw = New-CleanObservation
    $raw.unexpected_runner_processes = @([pscustomobject]@{ identity = 'broker' })
    $raw.runner_process_natural_exit = [pscustomobject]@{
        schema_version=2;process_class='smart-screen';native_exit=$null;initial_native_observations=@();status = 'natural-exit'; candidate_identity = 'broker'; natural_exit_observed = $true
        final_inventory_complete = $true; final_runner_process_delta_identities = @()
        final_runner_task_delta_identities = @()
    }
    if (-not (& $completion -Observation $raw)) { throw 'The observed SmartScreen natural exit lost its existing exception.' }
    foreach ($field in $raw.runner_process_natural_exit.PSObject.Properties.Name) {
        $changed = New-CleanObservation
        $changed.unexpected_runner_processes = $raw.unexpected_runner_processes
        $changed.runner_process_natural_exit = $raw.runner_process_natural_exit.PSObject.Copy()
        $changed.runner_process_natural_exit.PSObject.Properties.Remove($field)
        if (& $completion -Observation $changed) { throw "Incomplete SmartScreen $field evidence passed." }
    }
    # A nonzero OS exit code is evidence of exit, not an acceptance failure.
    $desktop=New-CleanObservation
    $desktop.unexpected_runner_processes=@([pscustomobject]@{identity='desktop'})
    $desktop.runner_process_natural_exit=[pscustomobject]@{
        schema_version=2;process_class='desktop-spotlight';status='natural-exit';candidate_identity='desktop'
        initial_native_observations=@([pscustomobject]@{attempt=1})
        broker=[pscustomobject]@{native_identity=[pscustomobject]@{pid=9468;creation_filetime_100ns='134351408602899385'}}
        native_exit=[pscustomobject]@{pid=9468;creation_filetime_100ns='134351408602899385';exit_filetime_100ns='134351409203675720'
            wait_result=0;times_succeeded=$true;times_win32_error=0;exit_code_succeeded=$true;exit_code_win32_error=0
            exit_code=[uint32]1;handle_closed=$true;close_win32_error=0}
        natural_exit_observed=$true;final_inventory_complete=$true;final_runner_process_delta_identities=@();final_runner_task_delta_identities=@()
    }
    if(-not(& $completion -Observation $desktop)){throw 'Exact same-handle exit code1 was rejected.'}
    foreach($field in $desktop.runner_process_natural_exit.native_exit.PSObject.Properties.Name){
        $saved=$desktop.runner_process_natural_exit.native_exit.$field
        $desktop.runner_process_natural_exit.native_exit.$field=$null
        if(& $completion -Observation $desktop){throw "Missing native exit field $field accepted."}
        $desktop.runner_process_natural_exit.native_exit.$field=$saved
    }
    $desktop.runner_process_natural_exit.native_exit.close_win32_error=5
    if(& $completion -Observation $desktop){throw 'Native close failure accepted.'}
    $desktop.runner_process_natural_exit.native_exit.close_win32_error=0
    $desktop.runner_process_natural_exit.initial_native_observations+=@([pscustomobject]@{attempt=2})
    if(& $completion -Observation $desktop){throw 'Two initial native observations accepted.'}
    $raw.runner_process_natural_exit.candidate_identity = 'foreign'
    if (& $completion -Observation $raw) { throw 'Another process inherited the SmartScreen exception.' }
}

& {
    $events = [Collections.Generic.List[string]]::new()
    $failure = ''
    function Invoke-AcceptanceTextScaleRescue {
        param($Session, $GuestRoot, $DesktopSid, $DesktopSessionId, $TaskName, $TestTimeoutSeconds,
            $SuiteTimeoutSeconds, $ObserverSha256, $BundleRecords, $InputManifestSha256, $Appearance, $HostOutputRoot)
        $events.Add('text-scale')
        if ($failure -ceq 'text-scale') { throw 'injected text-scale rescue failure' }
        if ($InputManifestSha256 -cne ('c' * 64) -or $Appearance -cne 'system') { throw 'Text-scale rescue lost its input binding.' }
    }
    function Invoke-AcceptanceHighContrastRescue {
        param($Session, $GuestRoot, $DesktopSid, $DesktopSessionId, $TaskName, $TestTimeoutSeconds,
            $SuiteTimeoutSeconds, $ObserverSha256, $BundleRecords, $HostOutputRoot)
        $events.Add('high-contrast')
        if ($failure -ceq 'high-contrast') { throw 'injected high-contrast rescue failure' }
    }
    $parameters = @{
        Session = [pscustomobject]@{}; GuestRoot = 'owned'; DesktopSid = 'runner'; DesktopSessionId = 7
        TaskName = 'owned'; TestTimeoutSeconds = 60; SuiteTimeoutSeconds = 120; ObserverSha256 = 'a' * 64
        BundleRecords = @([pscustomobject]@{file='fixture'}); InputManifestSha256 = 'c' * 64
        Appearance = 'system'; HostOutputRoot = 'output'
    }
    foreach ($mode in @('current-dpi', 'text-scale')) {
        foreach ($hc in @($false, $true)) {
            foreach ($status in @('review_required', 'failed', 'environment_blocked', 'unsupported', 'not_run')) {
                foreach ($exitCode in @(0, 1)) {
                    $events.Clear()
                    $state = [pscustomobject]@{ terminal = $true; result_status = $status; task_result = $exitCode }
                    Invoke-AcceptanceTerminalFailureRescue -State $state -AcceptanceMode $mode -HighContrast $hc -RescueParameters $parameters
                    $expected = @()
                    if ($status -cne 'review_required' -or $exitCode -ne 0) {
                        if ($mode -ceq 'text-scale') { $expected += 'text-scale' }
                        if ($hc) { $expected += 'high-contrast' }
                    }
                    if (($events -join ',') -cne ($expected -join ',')) { throw "Incorrect terminal rescue dispatch for $mode/$hc/$status/$exitCode." }
                }
            }
        }
    }
    foreach ($failure in @('text-scale', 'high-contrast')) {
        $events.Clear()
        $state = [pscustomobject]@{ terminal = $true; result_status = 'failed'; task_result = 0 }
        Assert-Fails {
            Invoke-AcceptanceTerminalFailureRescue -State $state -AcceptanceMode 'text-scale' -HighContrast $true -RescueParameters $parameters
        } "injected $failure rescue failure"
        $expected = if ($failure -ceq 'text-scale') { 'text-scale' } else { 'text-scale,high-contrast' }
        if (($events -join ',') -cne $expected) { throw 'A failed rescue was swallowed or dispatched again.' }
    }
    $state.terminal = $false
    $events.Clear()
    Assert-Fails {
        Invoke-AcceptanceTerminalFailureRescue -State $state -AcceptanceMode 'text-scale' -HighContrast $true -RescueParameters $parameters
    } 'requires a terminal task observation'
    if ($events.Count -ne 0) { throw 'Rescue started before terminal observation.' }
    if ($parameters.Count -ne 12) { throw 'High Contrast dispatch mutated the shared rescue parameters.' }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-observer-cleanup-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $root
    Invoke-DrTestPowerShellModuleScope -Kind controller -ArgumentList @($root) -Action {
        param($FixtureRoot)
        $output = Join-Path $FixtureRoot 'preserved-output'
        [void](New-Item -ItemType Directory -Path $output)
        $source = 'a' * 40
        $observer = 'b' * 64
        $terminal = [pscustomobject]@{ state = 'exited'; exit_code = 1 }
        function Write-PreservedFixture {
            param([string] $Leaf, [object] $Value)
            $path = Join-Path $output $Leaf
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
            $Value | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
            [pscustomobject]@{
                file = $Leaf; bytes = (Get-Item -LiteralPath $path).Length
                sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        $ui = [pscustomobject]@{
            schema_version = 1; source_sha = $source; status = 'failed'
            failure_reason = 'gui_regression_observer_failed'; high_contrast = $null; text_scale = $null
        }
        $uiSummary = Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui
        $args = @{
            Role = 'ui'; Result = $ui; Inventory = @($uiSummary); OutputRoot = $output
            ObserverSha256 = $observer; AcceptanceMode = 'current-dpi'
            HighContrastRequested = $false; ProcessJobsClosed = $true
            ObserverProcess = $terminal; PollFailure = $null
        }
        if (-not (Test-DrControllerPreservedOutputCleanupAuthorization @args)) {
            throw 'A collected failed UI result with closed jobs was not cleanup eligible.'
        }
        $args.Inventory = @()
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'Missing copied output authorized cleanup.'
        }
        $args.Inventory = @($uiSummary)
        $args.ProcessJobsClosed = $false
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'Open process jobs authorized cleanup.'
        }
        $args.ProcessJobsClosed = $true
        $args.ObserverProcess = $null
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'A nonterminal observer authorized cleanup.'
        }
        $args.ObserverProcess = $terminal
        $args.ObserverProcess = [pscustomobject]@{ state = 'exited'; exit_code = $null }
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'An observer without an exact terminal exit code authorized cleanup.'
        }
        $args.ObserverProcess = $terminal
        $args.PollFailure = [Exception]::new('poll failed')
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'An uncertain task poll authorized cleanup.'
        }
        $args.PollFailure = $null
        $ui.failure_reason = 'execution_state_restore_failed'
        $args.Inventory = @(Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui)
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'Uncertain execution-state restoration authorized cleanup.'
        }
        $ui.failure_reason = 'gui_regression_observer_failed'

        $snapshot = [ordered]@{
            schema_version = 2; source_sha = $source; acceptance_script_sha256 = $observer
            restoration_required = $false; restoration_verified = $true
            original = [ordered]@{ flags = 1; scheme = 'fixture' }
            restored = [ordered]@{ flags = 1; scheme = 'fixture' }
        }
        $snapshotRow = Write-PreservedFixture -Leaf 'high-contrast-restore.json' -Value $snapshot
        $ui.high_contrast = [pscustomobject]@{
            snapshot = [pscustomobject]@{ file = $snapshotRow.file; sha256 = $snapshotRow.sha256 }
        }
        $args.HighContrastRequested = $true
        $args.Inventory = @($snapshotRow, (Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui))
        if (-not (Test-DrControllerPreservedOutputCleanupAuthorization @args)) {
            throw 'Copied failed UI evidence with verified High Contrast restoration was rejected.'
        }
        $snapshot.original.scheme = $null
        $snapshot.restored.scheme = ''
        $snapshotRow = Write-PreservedFixture -Leaf 'high-contrast-restore.json' -Value $snapshot
        $ui.high_contrast.snapshot.sha256 = $snapshotRow.sha256
        $args.Inventory = @($snapshotRow, (Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui))
        if (-not (Test-DrControllerPreservedOutputCleanupAuthorization @args)) {
            throw 'Observer-equivalent null/empty High Contrast Scheme was rejected.'
        }
        $ui.failure_reason = 'high_contrast_restore_failed'
        $rescue = [ordered]@{
            status = 'passed'; restoration_verified = $true; source_sha = $source
            acceptance_script_sha256 = $observer; snapshot_sha256 = $snapshotRow.sha256
        }
        $rescueRow = Write-PreservedFixture -Leaf 'high-contrast-rescue-result.json' -Value $rescue
        $args.Inventory = @($snapshotRow, $rescueRow,
            (Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui))
        if (-not (Test-DrControllerPreservedOutputCleanupAuthorization @args)) {
            throw 'A verified rescue did not authorize preservation of failed UI evidence.'
        }
        $rescue.restoration_verified = $false
        $args.Inventory = @($snapshotRow,
            (Write-PreservedFixture -Leaf 'high-contrast-rescue-result.json' -Value $rescue),
            $args.Inventory[-1])
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'An uncertain rescue authorized cleanup.'
        }
        $ui.failure_reason = 'gui_regression_observer_failed'
        $args.Inventory = @($snapshotRow, (Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui))
        foreach ($change in @('missing', 'pending', 'source', 'different', 'hash')) {
            $savedSource = $snapshot.source_sha
            $savedVerified = $snapshot.restoration_verified
            $savedScheme = $snapshot.restored.scheme
            switch ($change) {
                'pending' { $snapshot.restoration_verified = $false }
                'source' { $snapshot.source_sha = 'c' * 40 }
                'different' { $snapshot.restored.scheme = 'different' }
            }
            if ($change -ne 'missing' -and $change -ne 'hash') {
                [void](Write-PreservedFixture -Leaf 'high-contrast-restore.json' -Value $snapshot)
            }
            if ($change -ceq 'hash') {
                [IO.File]::AppendAllText((Join-Path $output $snapshotRow.file), 'partial')
            }
            $args.Inventory = if ($change -ceq 'missing') { @($args.Inventory[1]) } else { @($snapshotRow, $args.Inventory[1]) }
            if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
                throw "Incomplete $change restoration evidence authorized cleanup."
            }
            $snapshot.source_sha = $savedSource
            $snapshot.restoration_verified = $savedVerified
            $snapshot.restored.scheme = $savedScheme
            $snapshotRow = Write-PreservedFixture -Leaf 'high-contrast-restore.json' -Value $snapshot
            $args.Inventory = @($snapshotRow, $args.Inventory[-1])
        }
        $args.HighContrastRequested = $false
        $args.AcceptanceMode = 'text-scale'
        $scale = [ordered]@{
            schema_version = 1; source_sha = $source; acceptance_script_sha256 = $observer
            restoration_required = $true; restoration_verified = $true
            original = [ordered]@{ ui_settings_percent = 100; ui_settings_raw_factor = 1.0 }
            restored = [ordered]@{ ui_settings_percent = 100; ui_settings_raw_factor = 1.0000005 }
        }
        $scaleRow = Write-PreservedFixture -Leaf 'text-scale-snapshot.json' -Value $scale
        $ui.text_scale = [pscustomobject]@{
            snapshot = [pscustomobject]@{ file = $scaleRow.file; sha256 = $scaleRow.sha256 }
        }
        $args.Inventory = @($scaleRow, (Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui))
        if (-not (Test-DrControllerPreservedOutputCleanupAuthorization @args)) {
            throw 'Verified text-scale restoration did not authorize failed evidence cleanup.'
        }
        $scale.restored.ui_settings_raw_factor = 1.000002
        $args.Inventory = @((Write-PreservedFixture -Leaf 'text-scale-snapshot.json' -Value $scale),
            (Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui))
        $ui.text_scale.snapshot.sha256 = $args.Inventory[0].sha256
        $args.Inventory[-1] = Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'Out-of-tolerance UISettings restoration authorized cleanup.'
        }
        $scale.restored.ui_settings_raw_factor = 1.0000005
        $scaleRow = Write-PreservedFixture -Leaf 'text-scale-snapshot.json' -Value $scale
        $ui.text_scale.snapshot.sha256 = $scaleRow.sha256
        $ui.status = 'review_required'
        $args.Inventory = @($scaleRow, (Write-PreservedFixture -Leaf 'acceptance-result.json' -Value $ui))
        if (-not (Test-DrControllerPreservedOutputCleanupAuthorization @args)) {
            throw 'Review-required UI evidence lost cleanup eligibility.'
        }
        $ui.status = 'failed'
        $scale.restoration_verified = $false
        $args.Inventory = @((Write-PreservedFixture -Leaf 'text-scale-snapshot.json' -Value $scale), $args.Inventory[-1])
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'Pending text-scale restoration authorized cleanup.'
        }

        $recovery = [pscustomobject]@{
            schema_version = 1; source_sha = $source; status = 'failed'
            failure_reason = 'recovery_acceptance_error'
        }
        $recoveryRow = Write-PreservedFixture -Leaf 'recovery-fixture/summary.json' -Value $recovery
        $args.Role = 'recovery'; $args.Result = $recovery; $args.Inventory = @($recoveryRow)
        $args.AcceptanceMode = $null
        if (-not (Test-DrControllerPreservedOutputCleanupAuthorization @args)) {
            throw 'A collected failed recovery result with closed jobs was not cleanup eligible.'
        }
        [IO.File]::AppendAllText((Join-Path $output $recoveryRow.file), 'partial')
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'Partial recovery copy authorized cleanup.'
        }
        $args.Inventory = @(Write-PreservedFixture -Leaf $recoveryRow.file -Value $recovery)
        $recovery.failure_reason = 'execution_state_restore_failed'
        $args.Inventory = @(Write-PreservedFixture -Leaf $recoveryRow.file -Value $recovery)
        if (Test-DrControllerPreservedOutputCleanupAuthorization @args) {
            throw 'Recovery restoration uncertainty authorized cleanup.'
        }
    }
    Invoke-DrTestPowerShellModuleScope -Kind controller -ArgumentList @($root) -Action {
        param($FixtureRoot)
        $hashed = [Collections.Generic.List[string]]::new()
        $copied = [Collections.Generic.List[string]]::new()
        function Get-FileHash {
            param($LiteralPath, $Algorithm)
            $hashed.Add($LiteralPath)
            [pscustomobject]@{ Hash = 'a' * 64 }
        }
        function Copy-Item { param($LiteralPath); $copied.Add($LiteralPath); throw 'Unexpected copy during inventory.' }
        function Assert-RejectedInventory {
            param([scriptblock] $Action, [string] $Expected)
            $hashed.Clear(); $copied.Clear()
            try { & $Action; throw 'Invalid output inventory passed.' }
            catch {
                if ($_.Exception.Message -notlike "*$Expected*") { throw }
            }
            if ($hashed.Count -ne 0 -or $copied.Count -ne 0) {
                throw 'An invalid complete output inventory began hashing or copying.'
            }
        }
        function Write-SparseFile {
            param([string] $Path, [long] $Bytes)
            $stream = [IO.File]::Create($Path)
            try { $stream.SetLength($Bytes) } finally { $stream.Dispose() }
        }
        foreach ($kind in @('ui', 'recovery')) {
            foreach ($case in @('valid', 'per-file', 'aggregate', 'private-per-file', 'private-aggregate', 'file-count', 'reparse', 'summary-reparse', 'summary-directory', 'directory', 'directory-count')) {
                if ($kind -ceq 'ui' -and $case -in @('directory-count', 'private-per-file', 'private-aggregate')) { continue }
                $caseRoot = Join-Path $FixtureRoot ("inventory-$kind-$case")
                $trustedRoot = Join-Path $caseRoot 'trusted'
                $out = Join-Path $trustedRoot 'out'
                $private = Join-Path $out 'private'
                $evidence = Join-Path $out 'recovery-fixture'
                [void](New-Item -ItemType Directory -Path $out -Force)
                if ($kind -ceq 'recovery') {
                    [void](New-Item -ItemType Directory -Path $private,$evidence)
                }
                $filesRoot = if ($kind -ceq 'ui') { $out } else { $evidence }
                $summary = Join-Path $out $(if ($kind -ceq 'ui') { 'acceptance-result.json' } else { 'recovery-summary.json' })
                Write-SparseFile -Path $summary -Bytes 0
                Write-SparseFile -Path (Join-Path $filesRoot 'a.bin') -Bytes 0
                $read = if ($kind -ceq 'ui') {
                    { Get-DrControllerUiOutputInventory -root $caseRoot -trustedRoot $trustedRoot }
                } else {
                    { Get-DrControllerRecoveryOutputInventory -root $caseRoot -trustedRoot $trustedRoot -recoveryEvidenceRootPath $evidence }
                }
                $expected = 'unsafe file'
                switch ($case) {
                    'per-file' { Write-SparseFile -Path (Join-Path $filesRoot 'z.bin') -Bytes (128MB + 1) }
                    'aggregate' {
                        foreach ($index in 1..5) { Write-SparseFile -Path (Join-Path $filesRoot "$index.bin") -Bytes 128MB }
                        $expected = 'aggregate size bound'
                    }
                    'private-per-file' { Write-SparseFile -Path (Join-Path $private 'z.bin') -Bytes (128MB + 1) }
                    'private-aggregate' {
                        foreach ($index in 1..4) { Write-SparseFile -Path (Join-Path $filesRoot "$index.bin") -Bytes 128MB }
                        Write-SparseFile -Path (Join-Path $private 'z.bin') -Bytes 1
                        $expected = 'aggregate size bound'
                    }
                    'file-count' {
                        $limit = if ($kind -ceq 'ui') { 128 } else { 256 }
                        # Exactly the file cap before appending the protected summary.
                        foreach ($index in 1..($limit - 1)) { Write-SparseFile -Path (Join-Path $filesRoot "$index.bin") -Bytes 0 }
                        $expected = 'file count exceeds its bound'
                    }
                    'reparse' {
                        [void](New-Item -ItemType SymbolicLink -Path (Join-Path $filesRoot 'z-link.bin') -Target (Join-Path $filesRoot 'a.bin'))
                        if ($kind -ceq 'recovery') { $expected = 'reparse entry' }
                    }
                    'summary-reparse' {
                        Remove-Item -LiteralPath $summary
                        [void](New-Item -ItemType SymbolicLink -Path $summary -Target (Join-Path $filesRoot 'a.bin'))
                    }
                    'summary-directory' {
                        Remove-Item -LiteralPath $summary
                        [void](New-Item -ItemType Directory -Path $summary)
                    }
                    'directory' {
                        [void](New-Item -ItemType Directory -Path (Join-Path $filesRoot 'z-directory'))
                        if ($kind -ceq 'recovery') {
                            [void](New-Item -ItemType SymbolicLink -Path (Join-Path $private 'z-link') -Target (Join-Path $filesRoot 'z-directory'))
                            $expected = 'reparse entry'
                        }
                    }
                    'directory-count' {
                        foreach ($index in 1..33) { [void](New-Item -ItemType Directory -Path (Join-Path $filesRoot "$index-dir")) }
                        $expected = 'directory count exceeds its bound'
                    }
                }
                if ($case -ceq 'valid') {
                    # Candidate-writable output/private data must never enter the protected inventory.
                    $mutable = Join-Path $caseRoot 'out'
                    [void](New-Item -ItemType Directory -Path $mutable)
                    Write-SparseFile -Path (Join-Path $mutable 'mutable.bin') -Bytes (128MB + 1)
                    if ($kind -ceq 'recovery') {
                        Write-SparseFile -Path (Join-Path $private 'index.json') -Bytes 1
                        Write-SparseFile -Path (Join-Path $evidence 'summary.json') -Bytes 1
                    }
                    $hashed.Clear(); $copied.Clear()
                    $rows = @(& $read)
                    $expectedNames = if ($kind -ceq 'ui') { @('a.bin', 'acceptance-result.json') } `
                        else { @('recovery-fixture/a.bin', 'recovery-fixture/summary.json', 'private/index.json') }
                    if ((($rows.file | Sort-Object) -join ',') -cne (($expectedNames | Sort-Object) -join ',') -or
                        $hashed.Count -ne $expectedNames.Count -or $copied.Count -ne 0) {
                        throw "The $kind inventory lost its protected files or summary mapping."
                    }
                    foreach ($row in $rows) {
                        if ($row.sha256 -cne ('a' * 64) -or $row.guest_path -notlike "$trustedRoot*" -or
                            (($row.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'bytes,file,guest_path,sha256') {
                            throw 'The bounded inventory changed its source-bound record contract.'
                        }
                    }
                }
                else { Assert-RejectedInventory -Action $read -Expected $expected }
                Remove-Item -LiteralPath $caseRoot -Recurse -Force
            }
        }
    }
    & {
        # Construct a typed, unopened session; Invoke-Command is intercepted below.
        # No connection, desktop, task, or privilege mutation is performed.
        $connection = [Management.Automation.Runspaces.SSHConnectionInfo]::new('fixture', 'unused.invalid', 'fixture')
        $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($connection)
        $constructor = [Management.Automation.Runspaces.PSSession].GetConstructors([Reflection.BindingFlags]'Instance,NonPublic')[0]
        $session = $constructor.Invoke(@($runspace))
        $oldProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $root 'rescue-programdata'
        try {
            function Invoke-Command {
                param($Session, $ArgumentList, $ScriptBlock)
                & $ScriptBlock @ArgumentList
            }
            function Get-DrVmTrustedPowerShellPath { 'Get-FixtureRescueEngine' }
            function Get-FixtureRescueEngine {
                $global:LASTEXITCODE = 0
                '{"version":"7.4.0","edition":"Core","effective_policy":"RemoteSigned"}'
            }
            function Get-ScheduledTask {
                param($TaskName, $ErrorAction)
                if (-not $probe.registered) { return $null }
                [pscustomobject]@{ State = $(if ($probe.polls -le 1) { 'Running' } else { 'Ready' }) }
            }
            function Get-ScheduledTaskInfo {
                param($TaskName)
                if (-not $probe.started) { return [pscustomobject]@{ LastRunTime = [datetime]::new(10); LastTaskResult = 0 } }
                $probe.polls++
                [pscustomobject]@{
                    LastRunTime = [datetime]::new(11)
                    LastTaskResult = $(if ($probe.mode -ceq 'nonzero' -and $probe.polls -ge 3) { 7 } else { 0 })
                }
            }
            function Register-DrVmTask {
                param($TaskName, $UserSid, $SessionId, $GuestRoot, $RuntimeRoot, $ObserverPath, $ObserverSha256,
                    $BundleSourcePath, $BundleRecords, $InputManifestPath, $InputManifestSha256, $Execute,
                    $Arguments, $WorkingDirectory, $TrustedResultLeaf, $ExecutionTimeLimitSeconds)
                $probe.registered = $true
                $probe.arguments = $Arguments
                $probe.result_leaf = $TrustedResultLeaf
                $probe.observer_path = $ObserverPath
                $probe.bundle_path = $BundleSourcePath
                $probe.input_sha256 = $InputManifestSha256
                $actions = [pscustomobject]@{
                    Path = $Execute
                    Arguments = ($Arguments + ' -ElevatedObserver -TrustedResultPath "' +
                        (Join-Path $out $TrustedResultLeaf) + '"')
                }
                $actions | Add-Member -MemberType ScriptMethod -Name Item -Value {
                    param($index)
                    [pscustomobject]@{Path=$this.Path;Arguments=$this.Arguments}
                }
                [pscustomobject]@{Definition=[pscustomobject]@{Actions=$actions}}
            }
            function Start-ScheduledTask {
                param($TaskName)
                $probe.started = $true
                $resultText = if ($probe.mode -ceq 'failed-result') { '{"status":"failed"}' }
                    elseif ($probe.mode -ceq 'v2-passed') {
                        '{"status":"passed","observer_lifecycle":{"pid":901}}'
                    } else { '{"status":"passed"}' }
                [IO.File]::WriteAllText((Join-Path $out $probe.result_leaf),$resultText)
            }
            function Complete-DrControllerV2TaskExecution {
                param($Session,$TaskName,$RunnerSid,$SessionId,$Engine,$CompletedTicks,$TaskResult,$Result)
                if ($Result.observer_lifecycle.pid -ne 901 -or
                    $Engine.action_arguments -notlike '*-ElevatedObserver -TrustedResultPath*' -or
                    $Engine.action_arguments -notlike '*-AcceptanceProfileId vm-automated-v2-owned-resources*') {
                    throw 'The v2 rescue did not pass registered action and exact observer evidence.'
                }
                [ordered]@{observer_lifecycle=$Result.observer_lifecycle;terminal=$true;exit_code=[long]$TaskResult}
            }
            function Start-Sleep { param($Seconds); $probe.sleeps++ }
            function Get-Date {
                if ($probe.mode -cne 'timeout') { return Microsoft.PowerShell.Utility\Get-Date }
                $probe.clock_reads++
                [datetime]::new(2000, 1, 1).AddSeconds($(if ($probe.clock_reads -eq 1) { 0 } else { 121 }))
            }
            function Copy-Item {
                param($LiteralPath, $Destination, $FromSession)
                if ($probe.polls -lt 3) { throw 'Rescue evidence copy preceded terminal task confirmation.' }
                if (-not $LiteralPath.StartsWith($out + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
                    throw 'Rescue evidence escaped its protected output root.'
                }
                $probe.copies++
                [IO.File]::Copy($LiteralPath, $Destination)
            }
            foreach ($kind in @('text-scale', 'high-contrast')) {
                foreach ($mode in @('passed', 'failed-result', 'nonzero', 'timeout')) {
                    $probe = [pscustomobject]@{
                        registered = $false; started = $false; polls = 0; copies = 0; sleeps = 0; clock_reads = 0
                        mode = $mode; arguments = ''; result_leaf = ''; observer_path = ''; bundle_path = ''; input_sha256 = ''
                    }
                    $name = "rescue-$kind-$mode"
                    $trusted = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
                    $out = Join-Path $trusted 'out'
                    [void](New-Item -ItemType Directory -Path $out -Force)
                    $observer = Join-Path $trusted 'windows-vm-acceptance.ps1'
                    [IO.File]::WriteAllText($observer, 'source-bound observer fixture')
                    $hostOut = Join-Path $root ("rescue-host-$kind-$mode")
                    [void](New-Item -ItemType Directory -Path $hostOut)
                    $snapshotLeaf = if ($kind -ceq 'text-scale') { 'text-scale-snapshot.json' } else { 'high-contrast-restore.json' }
                    [IO.File]::WriteAllText((Join-Path $out $snapshotLeaf), '{}')
                    $arguments = @{
                        Session = $session; GuestRoot = (Join-Path $root 'rescue-guest'); DesktopSid = 'fixture-sid'
                        DesktopSessionId = 7; TaskName = $name; TestTimeoutSeconds = 60; SuiteTimeoutSeconds = 120
                        ObserverSha256 = Get-LowerSha256 -Path $observer
                        BundleRecords = @([pscustomobject]@{file='fixture';sha256=('a' * 64)})
                        HostOutputRoot = $hostOut
                    }
                    $command = if ($kind -ceq 'text-scale') { 'Invoke-AcceptanceTextScaleRescue' } else { 'Invoke-AcceptanceHighContrastRescue' }
                    if ($kind -ceq 'text-scale') {
                        $arguments.InputManifestSha256 = 'c' * 64
                        $arguments.Appearance = 'system'
                    }
                    if ($mode -ceq 'passed') { & $command @arguments }
                    elseif ($mode -ceq 'timeout') {
                        Assert-Fails { & $command @arguments } 'timed out before the scheduled task reached its terminal state'
                        if ($probe.copies -ne 0 -or $probe.polls -ne 1) { throw 'A nonterminal rescue copied evidence or lost its timeout.' }
                        continue
                    }
                    else { Assert-Fails { & $command @arguments } 'did not verify exact restoration' }
                    $switch = if ($kind -ceq 'text-scale') { '-RestoreTextScaleOnly' } else { '-RestoreHighContrastOnly' }
                    if ($probe.copies -ne 2 -or $probe.sleeps -ne 2 -or $probe.polls -ne 3 -or
                        $probe.result_leaf -cne ($kind + '-rescue-result.json') -or
                        $probe.observer_path -cne $observer -or $probe.bundle_path -cne (Join-Path $trusted 'bundle') -or
                        $probe.arguments -notlike "*$switch*" -or
                        $probe.arguments -notlike ('*-OutputRoot "' + $out + '"*')) {
                        throw 'The real rescue lost its restore-only, protected-output, terminal, or evidence collection contract.'
                    }
                    if ($kind -ceq 'text-scale' -and $probe.input_sha256 -cne ('c' * 64)) {
                        throw 'Text-scale rescue lost the input manifest source binding.'
                    }
                }
            }
            $script:DrVmV2RescueAttempts = 0
            $script:DrVmV2RescueExecutions = [Collections.Generic.List[object]]::new()
            $probe = [pscustomobject]@{
                registered=$false;started=$false;polls=0;copies=0;sleeps=0;clock_reads=0
                mode='v2-passed';arguments='';result_leaf='';observer_path='';bundle_path='';input_sha256=''
            }
            $name = 'rescue-v2-text-scale'
            $trusted = Join-Path (Join-Path $env:ProgramData 'DarkReNamerVmRuns') ($name + '-trusted')
            $out = Join-Path $trusted 'out'
            [void](New-Item -ItemType Directory -Path $out -Force)
            $observer = Join-Path $trusted 'windows-vm-acceptance.ps1'
            [IO.File]::WriteAllText($observer,'source-bound observer fixture')
            [IO.File]::WriteAllText((Join-Path $out 'text-scale-snapshot.json'),'{}')
            $hostOut = Join-Path $root 'rescue-host-v2'
            [void](New-Item -ItemType Directory -Path $hostOut)
            Invoke-AcceptanceTextScaleRescue -Session $session -GuestRoot (Join-Path $root 'rescue-guest') `
                -DesktopSid 'fixture-sid' -DesktopSessionId 7 -TaskName $name -TestTimeoutSeconds 60 `
                -SuiteTimeoutSeconds 120 -ObserverSha256 (Get-LowerSha256 -Path $observer) `
                -BundleRecords @([pscustomobject]@{file='fixture';sha256=('a' * 64)}) `
                -InputManifestSha256 ('c' * 64) -Appearance system -HostOutputRoot $hostOut `
                -AcceptanceProfileId vm-automated-v2-owned-resources `
                -EngineEvidence ([pscustomobject]@{version='7.4.0';edition='Core';effective_policy='RemoteSigned'})
            if ($script:DrVmV2RescueAttempts -ne 1 -or
                $script:DrVmV2RescueExecutions.Count -ne 1 -or
                $script:DrVmV2RescueExecutions[0].kind -cne 'text-scale' -or
                $script:DrVmV2RescueExecutions[0].task_execution.observer_lifecycle.pid -ne 901) {
                throw 'V2 rescue lost its separate task execution receipt.'
            }
            if ($runspace.RunspaceStateInfo.State -ne [Management.Automation.Runspaces.RunspaceState]::BeforeOpen) {
                throw 'The rescue fixture unexpectedly opened a remote session.'
            }
        }
        finally {
            $env:ProgramData = $oldProgramData
            $runspace.Dispose()
        }
    }
    Invoke-DrTestPowerShellModuleScope -Kind controller -ArgumentList @($root) -Action {
        param($FixtureRoot)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/controller-entry.psm1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count -ne 0) { throw 'Controller cleanup source did not parse.' }
        $preservationCalls = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Test-DrControllerPreservedOutputCleanupAuthorization'
        }, $true))
        if ($preservationCalls.Count -ne 2 -or
            @($preservationCalls | Where-Object { $_.Extent.Text -notmatch '-Role (ui|recovery)' }).Count -ne 0) {
            throw 'UI and recovery collection no longer use the preserved-output predicate.'
        }
        $authorization = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$cleanupAuthorized'
        }, $true))
        if ($authorization.Count -lt 1 -or
            $authorization[0].Right.Extent.Text -notmatch '\$outputPreservedForCleanup' -or
            $authorization[0].Right.Extent.Text -match '\$acceptancePassed') {
            throw 'Guest deletion authorization is still coupled to acceptance success.'
        }
        if ($ast.Extent.Text -notmatch '\(\$observerTask -and -not \$acceptancePassed\)') {
            throw 'The final acceptance rejection was weakened.'
        }
        $assignment = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Extent.Text -match '^\$cleanupResult\s*=\s*Invoke-Command\b'
        }, $true))
        if ($assignment.Count -ne 1) { throw 'The controller cleanup command is ambiguous.' }
        $remoteBody = $assignment[0].Find({ param($node)
            $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true).ScriptBlock.GetScriptBlock()
        $completionDefinition = ${function:Test-DrControllerCleanupObservation}.ToString()
        foreach($name in @('New-DrVmSpotlightCaptureContext','Close-DrVmSpotlightCaptureContext')){
            $definition=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq ('global:'+$name)}.GetNewClosure(),$true))
            . ([scriptblock]::Create($definition[0].Extent.Text.Replace('function global:','function ')))
        }
        $oldProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $FixtureRoot 'cleanup-programdata'
        try {
            function Get-ScheduledTask {
                param($ErrorAction)
                $probe.task_reads++
                if ($probe.task_reads -eq 2 -and $probe.mode -ceq 'task') {
                    [pscustomobject]@{ TaskName = $taskName; TaskPath = '\' }
                }
            }
            function Get-DrVmRunnerTasks {
                param($UserSid)
                if ($UserSid -cne 'runner-sid') { throw 'Runner task observation escaped its identity.' }
                $probe.runner_task_reads++
                if ($probe.runner_task_reads -eq 3 -and $probe.mode -ceq 'removed-baseline-task') { return }
                $hash = if ($probe.runner_task_reads -eq 3 -and $probe.mode -ceq 'changed-baseline-task') { 'b' * 64 } else { 'a' * 64 }
                [pscustomobject]@{ identity = 'baseline-task'; definition_sha256 = $hash }
            }
            function Get-DrVmRunnerProcesses {
                param($UserSid, $SessionId, $CaptureContext)
                if ($UserSid -cne 'runner-sid' -or $SessionId -ne 7) { throw 'Runner process observation escaped its identity.' }
                $probe.process_reads++
                if($probe.process_reads -eq 1 -and $probe.mode -ceq 'failed-capture'){
                    $CaptureContext.failed=$true
                    $CaptureContext.observations.Add([ordered]@{attempt=1;cim_row=$null;native_identity=$null;capture_error=[ordered]@{error_type='System.Exception';hresult=-1}})
                }
                [pscustomobject]@{
                    complete = -not ($probe.process_reads -eq 3 -and $probe.mode -ceq 'incomplete')
                    processes = @($(if ($probe.process_reads -eq 3 -and $probe.mode -ceq 'runner-process') {
                        [pscustomobject]@{ identity = 'foreign-process'; pid = 99 }
                    }))
                }
            }
            function Get-CimInstance {
                param($ClassName, $OperationTimeoutSec, $ErrorAction)
                if ($probe.deletes -eq 2 -and $probe.mode -ceq 'owned-process') {
                    [pscustomobject]@{ ExecutablePath = $guestRoot + '\fixture.exe'; ProcessId = 99; SessionId = 7 }
                }
            }
            function Remove-Item {
                param($LiteralPath, [switch] $Recurse, [switch] $Force)
                $probe.deletes++
                if (($probe.mode -ceq 'guest-root' -and $LiteralPath -ceq $guestRoot) -or
                    ($probe.mode -ceq 'trusted-root' -and $LiteralPath -ceq $trustedRoot)) { return }
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse -Force
            }
            foreach ($mode in @('clean', 'task', 'guest-root', 'trusted-root', 'runner-process', 'owned-process', 'incomplete', 'removed-baseline-task', 'changed-baseline-task','failed-capture')) {
                $probe = [pscustomobject]@{ mode = $mode; task_reads = 0; runner_task_reads = 0; process_reads = 0; deletes = 0 }
                $taskName = 'DarkReNamerTests-' + [guid]::NewGuid().ToString('N')
                $base = Join-Path $env:ProgramData 'DarkReNamerVmRuns'
                $guestRoot = Join-Path $base $taskName
                $trustedRoot = Join-Path $base ($taskName + '-trusted')
                [void](New-Item -ItemType Directory -Path $guestRoot,$trustedRoot -Force)
                $global:DrVmOwnedRootRecords = [ordered]@{
                    guest = [pscustomobject]@{ path = $guestRoot }
                    trusted = [pscustomobject]@{ path = $trustedRoot }
                }
                $context = [pscustomobject]@{
                    runner_sid = 'runner-sid'; runner_session_id = 7
                    baseline_tasks = @([pscustomobject]@{ identity = 'baseline-task'; definition_sha256 = 'a' * 64 })
                    baseline_process_identities = @()
                }
                $observed = & $remoteBody $guestRoot $trustedRoot $taskName $true $true $context $completionDefinition
                if ($mode -ceq 'clean' -and
                    (Test-DrControllerOwnedCleanupFailureEligible -CleanupResult $observed)) {
                    throw 'A normal successful cleanup must bypass the strict-failure finalizer.'
                }
                if ($null -ne $observed.PSObject.Properties['owned_cleanup_after_strict_failure_eligible']) {
                    if ($observed.guest_cleanup -or $probe.deletes -ne 0 -or
                        $null -ne $observed.raw_cleanup.unexpected_runner_tasks_after_delete -or
                        $null -ne $observed.raw_cleanup.unexpected_runner_processes_after_delete -or
                        -not $observed.raw_cleanup.guest_root_present -or
                        -not $observed.raw_cleanup.trusted_task_root_present) {
                        throw 'Strict failure changed its raw observation or deleted owned roots.'
                    }
                    foreach ($ownedRoot in @($guestRoot,$trustedRoot)) {
                        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $ownedRoot -Recurse -Force
                    }
                    continue
                }
                if($mode -ceq 'failed-capture'){
                    if($observed.guest_cleanup -or $probe.deletes -ne 0 -or
                        -not $observed.raw_cleanup.guest_root_present -or -not $observed.raw_cleanup.trusted_task_root_present -or
                        $observed.raw_cleanup.runner_process_natural_exit.status -cne 'rejected'){
                        throw 'A sticky failed capture and empty retry deleted retained roots.'
                    }
                    foreach($ownedRoot in @($guestRoot,$trustedRoot)){Microsoft.PowerShell.Management\Remove-Item -LiteralPath $ownedRoot -Recurse -Force}
                    continue
                }
                if ($observed.guest_cleanup -isnot [bool] -or $observed.guest_cleanup -ne ($mode -ceq 'clean') -or
                    $probe.deletes -ne 2 -or $probe.process_reads -ne 3 -or $probe.runner_task_reads -ne 3 -or
                    $null -eq $observed.raw_cleanup.unexpected_runner_tasks_after_delete -or
                    $null -eq $observed.raw_cleanup.unexpected_runner_processes_after_delete) {
                    throw ("The actual cleanup producer misclassified or lost final $mode observations: " + ($observed | ConvertTo-Json -Depth 5 -Compress) + "; probe=" + ($probe | ConvertTo-Json -Compress))
                }
                if ($mode -ceq 'task' -and -not $observed.raw_cleanup.scheduled_task_present) { throw 'Task residue was fabricated as absent.' }
                if ($mode -ceq 'guest-root' -and -not $observed.raw_cleanup.guest_root_present) { throw 'Guest directory residue was fabricated as absent.' }
                if ($mode -ceq 'trusted-root' -and -not $observed.raw_cleanup.trusted_task_root_present) { throw 'Trusted directory residue was fabricated as absent.' }
                if ($mode -ceq 'incomplete' -and $observed.raw_cleanup.runner_process_inventory_complete) { throw 'Incomplete process observation was fabricated as complete.' }
                foreach ($ownedRoot in @($guestRoot, $trustedRoot)) {
                    if (Test-Path -LiteralPath $ownedRoot) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $ownedRoot -Recurse -Force }
                }
            }
        }
        finally { $env:ProgramData = $oldProgramData }
    }
    $binaryPath = Join-Path $root 'fixture.exe'
    [IO.File]::WriteAllText($binaryPath, 'not an executable')
    $changedArtifact = [pscustomobject]@{ file = 'fixture.exe'; sha256 = '0' * 64 }
    foreach ($budget in @(0, 1024)) {
        $row = Invoke-RustTestBinary -Test $changedArtifact -Root $root -OutputRoot $root `
            -RuntimeRoot $root -Index $budget -TimeoutSeconds 1 -OutputBudgetBytes $budget
        $expectedReason = if ($budget -eq 0) { 'suite_output_limit_exceeded' } else { 'artifact_changed_after_preflight' }
        if ($row.status -cne 'failed' -or $row.failure_reason -cne $expectedReason -or
            -not $row.job_cleanup -or $row.stdout.bytes -ne 0 -or $row.stderr.bytes -ne 0 -or
            $row.stdout.sha256 -cne 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' -or
            $row.stderr.sha256 -cne $row.stdout.sha256) {
            throw 'A rejected test launch lost its final output or cleanup evidence.'
        }
    }
    $gui = Invoke-GuiSmoke -Application $changedArtifact -Root $root -OutputRoot $root `
        -RuntimeRoot $root -ExpectedSession 1 -TimeoutSeconds 1
    if ($gui.status -cne 'failed' -or $gui.failure_reason -cne 'artifact_changed_after_preflight' -or
        -not $gui.job_cleanup) {
        throw 'A rejected GUI launch lost its final cleanup evidence.'
    }
    $details = [ordered]@{ error_detail = $null }
    foreach ($message in @('original GUI failure', 'process cleanup failed', 'fixture retained')) {
        try { throw $message }
        catch { Set-GuiSmokeFailureDetail -Row $details -ErrorRecord $_ }
    }
    if ($details.error_detail.message -cne 'original GUI failure' -or
        ($details.additional_error_details.message -join ',') -cne 'process cleanup failed,fixture retained') {
        throw 'Cleanup diagnostics must preserve the original GUI error and each later failure.'
    }
    Assert-OrdinaryDirectoryTree -Path $root
    Assert-Fails { Assert-OrdinaryDirectoryTree -Path (Join-Path $root 'absent') } 'does not exist'

    foreach ($failure in @('query', 'terminate', 'wait', 'close', 'capture', 'none')) {
        $owner = [pscustomobject]@{
            failure = $failure
            closed = 0
            captured = 0
        }
        $owner | Add-Member ScriptProperty ActiveProcessCount {
            if ($this.failure -ceq 'query') { throw 'query failed' }
            if ($this.failure -ceq 'terminate') { return 1 }
            return 0
        }
        $owner | Add-Member ScriptMethod Terminate { param($code); throw 'terminate failed' }
        $owner | Add-Member ScriptMethod WaitForEmpty {
            param($milliseconds)
            if ($this.failure -ceq 'wait') { throw 'wait failed' }
            return $true
        }
        $owner | Add-Member ScriptMethod CloseJob {
            $this.closed++
            if ($this.failure -ceq 'close') { throw 'close failed' }
            return $true
        }
        $owner | Add-Member ScriptMethod WaitForCapture {
            param($milliseconds)
            $this.captured++
            if ($this.failure -ceq 'capture') { throw 'capture failed' }
        }
        $state = [pscustomobject]@{
            owner = $owner; job_active_processes_at_close = $null; job_had_survivors = $false
            job_forced_termination = $false; job_empty = $false; job_closed = $false
            job_capture_complete = $false; job_cleanup_error = $null
        }
        if ($failure -ceq 'none') {
            if (-not (Close-JobBoundProcess -State $state)) { throw 'Ordinary job cleanup failed.' }
        }
        else {
            $expected = if ($failure -ceq 'query') { 'active-process count could not be observed' } else { "$failure failed" }
            Assert-Fails { Close-JobBoundProcess -State $state } $expected
        }
        if ($owner.closed -ne 1 -or $owner.captured -ne 1 -or
            ($failure -cin @('query', 'terminate', 'wait') -and $state.job_empty)) {
            throw 'A cleanup failure skipped remaining resources or fabricated job emptiness.'
        }
    }

    $initial = foreach ($index in 1..3) {
        [pscustomobject]@{
            name = if ($index -eq 3) { 'sentinel.bin' } else { "$index.txt" }
            kind = 'file'; bytes = 1; content_sha256 = 'a' * 64
            file_identity = [pscustomobject]@{
                volume_serial = '1' * 16; file_id = $index.ToString('x32')
            }
        }
    }
    $renamed = $initial[1].PSObject.Copy()
    $renamed.name = 'new-' + $renamed.name
    $partial = @($initial[0], $renamed, $initial[2])
    $counts = Assert-AcceptancePartialState -Initial $initial -Partial $partial -Prefix 'new-' -ExpectedCount 2
    if ($counts.original -ne 1 -or $counts.renamed -ne 1) { throw 'A genuine partial state was rejected.' }
    $duplicate = $initial[0].PSObject.Copy()
    $duplicate.name = 'new-' + $duplicate.name
    Assert-Fails {
        Assert-AcceptancePartialState -Initial $initial -Partial @($initial[0], $duplicate, $initial[2]) `
            -Prefix 'new-' -ExpectedCount 2
    } 'duplicate NTFS identity'
    Assert-Fails {
        Assert-AcceptancePartialState -Initial $initial -Partial @($initial[0], $initial[2], $initial[2]) `
            -Prefix 'new-' -ExpectedCount 2
    } 'duplicate NTFS identity'
    $unknown = $initial[1].PSObject.Copy()
    $unknown.file_identity = [pscustomobject]@{ volume_serial = '1' * 16; file_id = 'f' * 32 }
    Assert-Fails {
        Assert-AcceptancePartialState -Initial $initial -Partial @($initial[0], $unknown, $initial[2]) `
            -Prefix 'new-' -ExpectedCount 2
    } 'unknown NTFS identity'

    & {
        function New-TestRecoveryApplication {
            param([int] $Sequence, [string] $Mode)
            $safe = [pscustomobject]@{ IsClosed = $false; IsInvalid = $false }
            $safe | Add-Member ScriptMethod DangerousGetHandle { [IntPtr]42 }
            $process = [pscustomobject]@{
                Id = 100 + $Sequence; SessionId = 2; StartTime = [DateTime]::UtcNow
                SafeHandle = $safe; HasExited = $Mode -in @('exited', 'recorded')
                ExitCode = if ($Mode -ceq 'exited') { 37 } else { 0 }; disposed = 0
                mode = $Mode; refresh_calls = 0
            }
            $process | Add-Member ScriptMethod Refresh {
                $this.refresh_calls++
                if ($this.mode -ceq 'race' -and $this.refresh_calls -eq 2) {
                    $this.HasExited = $true; $this.ExitCode = 37
                }
            }
            $process | Add-Member ScriptMethod WaitForExit { param($timeout); return $this.HasExited }
            $process | Add-Member ScriptMethod Dispose { $this.disposed++ }
            $binding = [pscustomobject]@{
                sequence = $Sequence; role = 'rename-worker'; pid = $process.Id; session_id = 2
                start_time_utc_ticks = $process.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
                executable_path = 'fixture.exe'; executable_sha256 = 'a' * 64
            }
            [pscustomobject]@{
                owned = [pscustomobject]@{ process = $process; mode = $Mode; receipt = $null; stop_calls = 0; close_calls = 0 }
                main_handle = [IntPtr]4096; session_id = 2
                raw_process_object = $process; raw_process_handle = [IntPtr]42
                raw_process_binding = $binding; raw_process_exit_recorded = $Mode -ceq 'recorded'
            }
        }
        function Complete-AcceptanceOwnedProcessJob {
            param($Owned, [switch] $StopActive, [switch] $RequireSolePrimary)
            if ($null -ne $Owned.receipt) { return $Owned.receipt }
            $Owned.close_calls++
            if ($StopActive) {
                $Owned.stop_calls++
                if (-not $RequireSolePrimary) { throw 'Failure cleanup omitted exact primary termination.' }
                $Owned.process.HasExited = $true
                $Owned.process.ExitCode = 12345
            }
            $failed = $Owned.mode -in @('survivors', 'close-failure')
            $exact = $StopActive -and -not $failed
            $Owned.receipt = [pscustomobject]@{
                status = if ($failed) { 'failed' } else { 'clean' }
                job_empty = $true; job_closed = $Owned.mode -cne 'close-failure'
                forced_termination = [bool]$exact; active_processes_at_stop = if ($exact) { 1 } else { 0 }
                active_process_ids_at_stop = [int[]]@(if ($exact) { $Owned.process.Id })
                total_processes_at_stop = if ($exact) { 1 } else { 0 }
                primary_process_active_at_stop = [bool]$exact
                termination_exit_code = if ($exact) { 12345 } else { $null }
                had_survivors = $Owned.mode -ceq 'survivors'
            }
            $Owned.receipt
        }
        $private = Join-Path $root 'failure-processes'
        $null = New-Item -ItemType Directory -Path $private
        $sequence = 0
        foreach ($mode in @('live', 'exited', 'recorded', 'race', 'survivors', 'close-failure')) {
            $sequence++
            $application = New-TestRecoveryApplication -Sequence $sequence -Mode $mode
            $references = [Collections.Generic.List[object]]::new()
            if ($mode -in @('race', 'survivors', 'close-failure')) {
                Assert-Fails {
                    Complete-AcceptanceFailureProcessCleanup -Application $application -PrivateRoot $private -Processes $references
                } $(if ($mode -ceq 'race') { 'exited before' } else { 'Job Object' })
            }
            else {
                Complete-AcceptanceFailureProcessCleanup -Application $application -PrivateRoot $private -Processes $references
            }
            if ($application.owned.close_calls -ne 1 -or
                $application.owned.stop_calls -ne [int]($mode -notin @('exited', 'recorded', 'race'))) {
                throw 'Failure cleanup selected the wrong live/exited job dispatch.'
            }
            if ($mode -ceq 'recorded') {
                if ($references.Count -ne 0) { throw 'Failure cleanup duplicated recorded process exit.' }
                continue
            }
            $exit = Get-Content -LiteralPath (Join-Path $private ('process-{0:D2}-failure-cleanup.json' -f $sequence)) -Raw | ConvertFrom-Json
            $method = if ($mode -ceq 'live') { 'forced-termination' } else { 'observed-exit' }
            if ($references.Count -ne 1 -or $exit.lifecycle.exit_method -cne $method -or
                $exit.lifecycle.exit_code -ne $application.owned.process.ExitCode -or
                ($method -ceq 'observed-exit' -and $null -ne $exit.termination)) {
                throw 'Failure cleanup fabricated an exit method, code or termination receipt.'
            }
        }
        $application = New-TestRecoveryApplication -Sequence 20 -Mode exited
        Assert-Fails {
            Write-AcceptanceProcessExitEvidence -Application $application -PrivateRoot $private `
                -Boundary normal-exit -ExitMethod observed-exit
        } 'restricted to failure cleanup'

        $source = Get-DrTestCombinedPowerShellSource -Kind recovery
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @('Invoke-AcceptanceSession', 'Invoke-AcceptanceIntentOnlyCandidateDiscard')) {
            $function = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $true)
            $finally = @($function.Body.FindAll({ param($node)
                $node -is [Management.Automation.Language.TryStatementAst] -and
                    $null -ne $node.Finally -and $node.Finally.Extent.Text.Contains('Complete-AcceptanceFailureProcessCleanup')
            }, $true))[0].Finally.Extent.Text
            $cleanupBlock = [scriptblock]::Create($finally.Substring(1, $finally.Length - 2))
            $cancelApplication = New-TestRecoveryApplication -Sequence 30 -Mode survivors
            $relaunchApplication = New-TestRecoveryApplication -Sequence 31 -Mode live
            $discardApplication = $null
            $applications = @($cancelApplication, $relaunchApplication)
            $processes = [Collections.Generic.List[object]]::new()
            $PrivateRoot = $private
            $sessionError = $null; $scenarioError = $null
            Assert-Fails {
                try { throw 'original scenario failure' }
                catch { $sessionError = $_; $scenarioError = $_; throw }
                finally { . $cleanupBlock }
            } 'original scenario failure'
            if ($cancelApplication.owned.process.disposed -ne 1 -or
                $relaunchApplication.owned.process.disposed -ne 1 -or
                $relaunchApplication.owned.stop_calls -ne 1) {
                throw 'A scenario cleanup failure skipped another owned application or its disposal.'
            }
            Remove-Item -LiteralPath (Join-Path $private 'process-30-failure-cleanup.json'), (Join-Path $private 'process-31-failure-cleanup.json')
        }

        $application = New-TestRecoveryApplication -Sequence 40 -Mode live
        $pattern = [pscustomobject]@{ calls = 0 }
        $pattern | Add-Member ScriptMethod Invoke { $this.calls++ }
        $element = [pscustomobject]@{}
        $element | Add-Member ScriptProperty Current { throw 'No late UIA property lookup is allowed at the worker boundary.' }
        $binding = [pscustomobject]@{
            hwnd = [IntPtr]4097; main_handle = $application.main_handle
            pid = $application.raw_process_binding.pid; session_id = 2
            start_time_utc_ticks = $application.raw_process_binding.start_time_utc_ticks
            pattern = $pattern; element = $element
        }
        $native = [pscustomobject]@{
            live = $true; child = [IntPtr]4097; parent = [IntPtr]4096; root = [IntPtr]4096
            pid = $binding.pid; root_pid = $binding.pid; class = 'Button'; name = '취소'
            root_class = 'DarkReNamerWindow'; root_name = 'DarkReNamer'; control_id = 1009
            enabled = $true; visible = $true; main_enabled = $true; focused = $false
        }
        function Read-AcceptanceWorkerControlState { param($Binding); $native }
        function Find-UniqueAutomationElement { throw 'No late UIA discovery is allowed at the worker boundary.' }
        & {
            # Keep the real binding function; only substitute the unavailable
            # framework's opaque pattern identifier at the API boundary.
            $bindingFunction = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'New-AcceptanceWorkerCancelBinding'
            }, $true)
            $bindingText = $bindingFunction.Extent.Text.Replace(
                '[Windows.Automation.InvokePattern]::Pattern', "'test-invoke-pattern'"
            )
            . ([scriptblock]::Create($bindingText))
            $factoryCalls = [Collections.Generic.List[long]]::new()
            function Get-AcceptanceWorkerCancelHandle {
                param($MainHandle)
                if ($MainHandle -ne [IntPtr]4096) { throw 'Native lookup received an unpinned main window.' }
                [IntPtr]4097
            }
            $provider = [pscustomobject]@{
                Current = [pscustomobject]@{
                    ProcessId = $binding.pid; NativeWindowHandle = 4097
                    AutomationId = '1009'; Name = '취소'
                    ControlType = [pscustomobject]@{ ProgrammaticName = 'ControlType.Button' }
                    IsEnabled = $false; IsOffscreen = $true
                }
                Pattern = $pattern; SupportsInvoke = $true
            }
            $provider | Add-Member ScriptMethod TryGetCurrentPattern {
                param($identifier, [ref]$result)
                if ($identifier -cne 'test-invoke-pattern') { throw 'Wrong pattern identifier.' }
                $result.Value = $this.Pattern
                return $this.SupportsInvoke
            }
            function Get-AcceptanceWorkerCancelAutomationElement {
                param($Handle)
                $factoryCalls.Add([long]$Handle)
                $provider
            }
            # The child is absent from the UIA tree, yet its HWND provider exists.
            function Find-UniqueAutomationElement { throw 'Hidden child is absent from the UIA tree.' }
            $native.enabled = $false; $native.visible = $false
            $hiddenBinding = New-AcceptanceWorkerCancelBinding -Application $application -SessionId 2
            if ($factoryCalls.Count -ne 1 -or $factoryCalls[0] -ne 4097 -or
                $hiddenBinding.hwnd -ne [IntPtr]4097 -or
                -not [object]::ReferenceEquals($hiddenBinding.element, $provider) -or
                -not [object]::ReferenceEquals($hiddenBinding.pattern, $pattern) -or $pattern.calls -ne 0) {
                throw 'Hidden child HWND binding did not retain its real provider element and pattern.'
            }
            foreach ($invalid in @(
                @{ name = 'pid'; value = 99 }, @{ name = 'parent'; value = [IntPtr]99 }
                @{ name = 'root'; value = [IntPtr]99 }, @{ name = 'class'; value = 'Edit' }
                @{ name = 'control_id'; value = 1010 }
            )) {
                $saved = $native.($invalid.name)
                $native.($invalid.name) = $invalid.value
                Assert-Fails { New-AcceptanceWorkerCancelBinding -Application $application -SessionId 2 } 'native child or root identity'
                $native.($invalid.name) = $saved
            }
            if ($factoryCalls.Count -ne 1) { throw 'Invalid native ownership reached FromHandle.' }
            foreach ($invalid in @(
                @{ name = 'ProcessId'; value = 99 }, @{ name = 'NativeWindowHandle'; value = 99 }
                @{ name = 'AutomationId'; value = '1010' }, @{ name = 'Name'; value = 'wrong' }
                @{ name = 'ControlType'; value = [pscustomobject]@{ ProgrammaticName = 'ControlType.Edit' } }
            )) {
                $saved = $provider.Current.($invalid.name)
                $provider.Current.($invalid.name) = $invalid.value
                Assert-Fails { New-AcceptanceWorkerCancelBinding -Application $application -SessionId 2 } 'unexpected UIA identity'
                $provider.Current.($invalid.name) = $saved
            }
            $provider.SupportsInvoke = $false
            Assert-Fails { New-AcceptanceWorkerCancelBinding -Application $application -SessionId 2 } 'no UIA InvokePattern'
            $provider.SupportsInvoke = $true
            $provider.Pattern = $null
            Assert-Fails { New-AcceptanceWorkerCancelBinding -Application $application -SessionId 2 } 'no UIA InvokePattern'
            $provider.Pattern = $pattern
            $native.enabled = $true; $native.visible = $true
        }

        $fixture = Join-Path $root 'worker-boundary'
        $localData = Join-Path $root 'worker-local'
        $journal = Join-Path $localData 'DarkReNamer/journal'
        $null = New-Item -ItemType Directory -Path $fixture, $journal -Force
        $first = Join-Path $fixture 'new-item-00000.txt'
        $last = Join-Path $fixture 'item-00127.txt'
        $active = Join-Path $journal 'active.drj'
        foreach ($path in @($first, $last, $active)) { [IO.File]::WriteAllText($path, 'fixture') }
        function Get-FullFileIdentity { param($Path); [pscustomobject]@{ volume_serial = '1' * 16; file_id = '2' * 32 } }
        $initialFirst = [pscustomobject]@{
            name = 'item-00000.txt'; file_identity = Get-FullFileIdentity -Path $first; content_sha256 = Get-LowerSha256 -Path $first
        }
        $initialLast = [pscustomobject]@{
            name = 'item-00127.txt'; file_identity = Get-FullFileIdentity -Path $last; content_sha256 = Get-LowerSha256 -Path $last
        }
        $boundary = Get-AcceptanceActiveWorkerBoundary -Application $application -Cancel $binding `
            -FixtureRoot $fixture -Prefix 'new-' -LocalAppData $localData -InitialFirst $initialFirst `
            -InitialLast $initialLast -ExpectedCount 128 -SessionId 2
        $interruption = Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
            -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerCancellation
        if ($pattern.calls -ne 1 -or $interruption.target.control_id -ne 1009) {
            throw 'The live partial worker did not use its retained real invocation path.'
        }
        foreach ($invalid in @(
            @{ name = 'live'; value = $false }, @{ name = 'child'; value = [IntPtr]99 }
            @{ name = 'parent'; value = [IntPtr]99 }, @{ name = 'root'; value = [IntPtr]99 }
            @{ name = 'pid'; value = 99 }, @{ name = 'root_pid'; value = 99 }
            @{ name = 'class'; value = 'Edit' }, @{ name = 'name'; value = 'wrong' }
            @{ name = 'root_class'; value = 'OtherWindow' }, @{ name = 'root_name'; value = 'wrong' }
            @{ name = 'control_id'; value = 1010 }, @{ name = 'main_enabled'; value = $false }
            @{ name = 'enabled'; value = $false }, @{ name = 'visible'; value = $false }
        )) {
            $saved = $native.($invalid.name)
            $native.($invalid.name) = $invalid.value
            Assert-Fails {
                Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
                    -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerCancellation
            } 'cancellation'
            $native.($invalid.name) = $saved
        }
        foreach ($path in @($first, $last, $active)) {
            Remove-Item -LiteralPath $path
            Assert-Fails {
                Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
                    -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerCancellation
            } 'witnesses or active journal'
            [IO.File]::WriteAllText($path, 'fixture')
        }
        $candidate = Join-Path $journal 'candidate.drj'
        [IO.File]::WriteAllText($candidate, 'fixture')
        Assert-Fails {
            Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
                -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerCancellation
        } 'witnesses or active journal'
        Remove-Item -LiteralPath $candidate
        foreach ($field in @('pid', 'session_id', 'start_time_utc_ticks', 'main_handle')) {
            $saved = $binding.$field
            $binding.$field = if ($field -ceq 'start_time_utc_ticks') { '0' } else { 99 }
            Assert-Fails { Get-AcceptanceWorkerCancelTarget -Application $application -Binding $binding -RequireActive } 'binding changed'
            $binding.$field = $saved
        }
        if ($pattern.calls -ne 1) { throw 'A stale native binding or lost witness still invoked cancellation.' }
        $closeCalls = [Collections.Generic.List[long]]::new()
        function Request-AcceptanceWorkerWindowClose { param($Handle); $closeCalls.Add([long]$Handle) }
        [void](Invoke-AcceptanceWorkerInterruption -Application $application -Binding $binding -Boundary $boundary `
            -FixtureRoot $fixture -LocalAppData $localData -Mode WorkerClose)
        if ($closeCalls.Count -ne 1 -or $closeCalls[0] -ne 4096 -or $pattern.calls -ne 1) {
            throw 'Worker close did not dispatch ordinary close to the exact retained native main window.'
        }
    }

    $controllerPath = Join-Path (Get-ToolingTestPaths).ScriptsRoot 'modules/powershell/controller-entry.psm1'
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($controllerPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw $errors[0] }
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-DrControllerRecoveryProcessIdentities'
    }, $false)
    . ([scriptblock]::Create($function.Extent.Text))
    $private = Join-Path $root 'private'
    $null = New-Item -ItemType Directory -Path $private
    $references = @()
    $files = foreach ($processId in @(101, 102)) {
        $leaf = "start-$processId.json"
        $path = Join-Path $private $leaf
        [IO.File]::WriteAllText($path, (@{
            boundary = 'started'
            binding = @{ pid = $processId; start_time_utc_ticks = [string]$processId }
        } | ConvertTo-Json))
        $reference = [pscustomobject]@{
            boundary = 'started'; sha256 = Get-LowerSha256 -Path $path
            bytes = (Get-Item -LiteralPath $path).Length
        }
        $references += $reference, [pscustomobject]@{ boundary = 'exited' }
        @{ file = $leaf; sha256 = $reference.sha256; bytes = $reference.bytes }
    }
    $indexPath = Join-Path $private 'private-index.json'
    [IO.File]::WriteAllText($indexPath, (@{
        classification = 'private-path-bearing-raw-recovery-evidence'; files = @($files)
    } | ConvertTo-Json -Depth 6))
    $result = [pscustomobject]@{
        selected_mode = 'ProcessCrash'
        process_crash = [pscustomobject]@{ processes = $references[0..1] }
        intent_only_candidate_discard = [pscustomobject]@{ status = 'not-run'; reason = 'switch-not-selected' }
        private_evidence = [pscustomobject]@{
            sha256 = Get-LowerSha256 -Path $indexPath; bytes = (Get-Item -LiteralPath $indexPath).Length
        }
    }
    $identities = Get-DrControllerRecoveryProcessIdentities -Result $result -EvidenceRoot $root
    if ($identities.Count -ne 1 -or -not $identities.Contains('101|101')) {
        throw 'Default ProcessCrash lost its required process binding.'
    }
    $result.intent_only_candidate_discard = [pscustomobject]@{ status = 'passed'; processes = $references[2..3] }
    $identities = Get-DrControllerRecoveryProcessIdentities -Result $result -EvidenceRoot $root
    if ($identities.Count -ne 2 -or -not $identities.Contains('102|102')) {
        throw 'Selected intent evidence lost its additional process binding.'
    }
    $result.intent_only_candidate_discard = [pscustomobject]@{ status = 'not-run'; reason = 'interrupted' }
    Assert-Fails { Get-DrControllerRecoveryProcessIdentities -Result $result -EvidenceRoot $root } 'invalid status'

    & {
        $script:resourceCalls = [Collections.Generic.List[string]]::new()
        function Remove-PSSession {
            [CmdletBinding()]param([object] $Session)
            $script:resourceCalls.Add('session')
            throw 'session failure'
        }
        $password = [pscustomobject]@{}
        $password | Add-Member ScriptMethod Dispose { $script:resourceCalls.Add('password'); throw 'password failure' }
        $mutex = [pscustomobject]@{}
        $mutex | Add-Member ScriptMethod ReleaseMutex { $script:resourceCalls.Add('release'); throw 'release failure' }
        $mutex | Add-Member ScriptMethod Dispose { $script:resourceCalls.Add('mutex'); throw 'mutex failure' }
        $failures = @(Close-DrControllerResources -Session 1 `
            -Credential ([pscustomobject]@{ Password = $password }) -Mutex $mutex -MutexHeld $true)
        if (($script:resourceCalls -join ',') -cne 'session,password,release,mutex' -or $failures.Count -ne 4) {
            throw 'Controller teardown must attempt every independent resource and retain every failure.'
        }
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Host 'Observer cleanup contracts passed.'
