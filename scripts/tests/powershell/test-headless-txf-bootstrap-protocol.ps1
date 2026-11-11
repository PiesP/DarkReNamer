[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$wrapper=Join-Path $repo 'scripts/tests/support/headless-txf-bootstrap.ps1'
$generator=Join-Path $repo 'scripts/generate-txf-diagnostic-bootstrap.py'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($wrapper,[ref]$tokens,[ref]$errors)
if($errors.Count -ne 0){throw 'Headless bootstrap syntax is invalid.'}
$embedded=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -in @('$cloneCode','$routeCode')},$true))
if($embedded.Count -ne 2){throw 'Exact embedded Git jobs are missing.'}
foreach($assignment in $embedded){
    if($assignment.Right.Expression -isnot [Management.Automation.Language.StringConstantExpressionAst]){
        throw 'Embedded Git job is not a literal script.'}
    $innerTokens=$null;$innerErrors=$null
    [void][Management.Automation.Language.Parser]::ParseInput(
        $assignment.Right.Expression.Value,[ref]$innerTokens,[ref]$innerErrors)
    if($innerErrors.Count -ne 0){throw "Embedded Git job syntax differs: $($assignment.Left.Extent.Text)"}
}
foreach($name in @('Test-HeadlessJobClean','Test-HeadlessSourcePin',
        'Get-HeadlessTerminalByteCount','Assert-HeadlessPayloadLimit',
        'Limit-HeadlessError','Assert-HeadlessCheckoutBudget',
        'Write-HeadlessTerminal','Assert-HeadlessTerminalAccepted',
        'Test-HeadlessInventoryReconciled','Set-HeadlessPrimaryAttribution',
        'Test-HeadlessUntrustedWriter','Initialize-HeadlessIdentityRuntime',
        'Assert-OrdinaryChain','New-HeadlessPrivateRoot','Get-HeadlessRootReceipt',
        'Assert-HeadlessRootUnchanged','Assert-HeadlessRouteInputs',
        'Invoke-HeadlessRouteEnvironment','Assert-HeadlessGitRoutePin',
        'Invoke-HeadlessGitEnvironment',
        'Invoke-HeadlessJob')){
    $definition=$ast.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $name},$true)
    if($null -eq $definition){throw "Actual bootstrap helper missing: $name"}
    . ([scriptblock]::Create($definition.Extent.Text))
}
Initialize-HeadlessIdentityRuntime # Compile the actual native declaration; do not call a Windows API here.
$script:maxRawBytes=1MB;$script:maxTerminalRecordBytes=1500000
function Require([bool]$Value,[string]$Case){if(-not $Value){throw "Headless protocol failed: $Case"}}
function RequireThrow([scriptblock]$Action,[string]$Case){
    $threw=$false
    try{& $Action}catch{$threw=$true}
    Require $threw $Case
}
if($IsWindows){
    $profileTemp=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'
    $private=New-HeadlessPrivateRoot $profileTemp
    $held=$private.path+'-held'
    $originalReceipt=$null;$heldReceipt=$null;$replacementReceipt=$null
    try{
        $originalReceipt=Get-HeadlessRootReceipt $private.path
        Require (-not [string]::IsNullOrEmpty($originalReceipt.file_id) -and
            $originalReceipt.protected -and $originalReceipt.rules -eq 3) `
            'native protected root identity'
        Assert-HeadlessRootUnchanged $originalReceipt $private.path
        if(Test-Path -LiteralPath $held){throw 'Exact held test path already exists.'}
        [IO.Directory]::Move($private.path,$held)
        $heldReceipt=Get-HeadlessRootReceipt $held
        Require ($heldReceipt.file_id -ceq $originalReceipt.file_id) `
            'owned empty root kept its FileID after exact rename'
        $security=[Security.AccessControl.DirectorySecurity](Get-Acl -LiteralPath $held)
        [void][IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($private.path),$security)
        $replacementReceipt=Get-HeadlessRootReceipt $private.path
        Require ($replacementReceipt.file_id -cne $originalReceipt.file_id) `
            'replacement has a distinct native FileID'
        RequireThrow {Assert-HeadlessRootUnchanged $originalReceipt $private.path} `
            'actual native FileID replacement is rejected'
    }
    finally{
        if($null -eq $replacementReceipt -and
            [IO.Directory]::Exists($private.path) -and [IO.Directory]::Exists($held)){
            throw 'Unknown replacement identity preserves both protocol-owned roots.'}
        if($null -ne $replacementReceipt -and [IO.Directory]::Exists($private.path)){
            if($null -ne $heldReceipt -and
                $replacementReceipt.file_id -ceq $heldReceipt.file_id){
                throw 'Ambiguous identical FileIDs preserve both protocol-owned roots.'}
            Assert-HeadlessRootUnchanged $replacementReceipt $private.path
            if(@([IO.Directory]::EnumerateFileSystemEntries($private.path)).Count -ne 0){
                throw 'Protocol-owned replacement acquired an unexpected entry.'}
            [IO.Directory]::Delete($private.path,$false)
        }
        elseif($null -ne $originalReceipt -and [IO.Directory]::Exists($private.path) -and
            -not [IO.Directory]::Exists($held)){
            Assert-HeadlessRootUnchanged $originalReceipt $private.path
            if(@([IO.Directory]::EnumerateFileSystemEntries($private.path)).Count -ne 0){
                throw 'Protocol-owned root acquired an unexpected entry.'}
            [IO.Directory]::Delete($private.path,$false)
        }
        if($null -ne $heldReceipt -and [IO.Directory]::Exists($held)){
            Assert-HeadlessRootUnchanged $heldReceipt $held
            if(@([IO.Directory]::EnumerateFileSystemEntries($held)).Count -ne 0){
                throw 'Protocol-owned held root acquired an unexpected entry.'}
            [IO.Directory]::Delete($held,$false)
        }
    }
}
$badPinScript=Join-Path ([IO.Path]::GetTempPath()) `
    ('dark240-headless-bad-pin-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
    [IO.File]::WriteAllText($badPinScript,
        ([IO.File]::ReadAllText($wrapper).Replace('__HEADLESS_PIN_BASE64__','%%%')),
        [Text.UTF8Encoding]::new($false))
    $start=[Diagnostics.ProcessStartInfo]::new(
        (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
    $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',$badPinScript)){
        $start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start)
    if($null -eq $process){throw 'Malformed-pin child did not start.'}
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(10000)){$process.Kill($true);throw 'Malformed-pin child timed out.'}
        if(-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),5000)){
            throw 'Malformed-pin output did not drain.'}
        $lines=@($stdout.GetAwaiter().GetResult() -split "`r?`n" |
            Where-Object {$_.StartsWith('DR_HEADLESS_TXF ')})
        Require ($process.ExitCode -ne 0 -and $lines.Count -eq 1) `
            'malformed pin has one bounded terminal and nonzero exit'
        $badReceipt=$lines[0].Substring('DR_HEADLESS_TXF '.Length) | ConvertFrom-Json -AsHashtable
        Require ($badReceipt.outcome -cne 'diagnostics-executed' -and
            $null -eq $badReceipt.retained_root) 'malformed pin does not mask original failure'
    }
    finally{$process.Dispose()}
}
finally{[IO.File]::Delete($badPinScript)}

$state=[pscustomobject]@{job_empty=$true;job_closed=$true;job_capture_complete=$true;
    job_active_processes_at_close=0;job_had_survivors=$false;
    job_forced_termination=$false;job_cleanup_error=$null}
$wait=[pscustomobject]@{failure_reason=$null}
Require (Test-HeadlessJobClean $state $wait 0) 'clean owned Job'
Require (-not (Test-HeadlessJobClean $state $wait $null)) 'missing exit code'
Require (-not (Test-HeadlessJobClean $state $wait 1)) 'nonzero exit code'
$state.job_forced_termination=$true
Require (-not (Test-HeadlessJobClean $state $wait 0)) 'forced termination cannot pass'
$state.job_forced_termination=$false;$state.job_capture_complete=$false
Require (-not (Test-HeadlessJobClean $state $wait 0)) 'capture incomplete cannot pass'
$state.job_capture_complete=$true;$state.job_empty=$false
Require (-not (Test-HeadlessJobClean $state $wait 0)) 'live Job cannot pass'
$state.job_empty=$true;$wait.failure_reason='timeout'
Require (-not (Test-HeadlessJobClean $state $wait 0)) 'timeout cannot pass'

$expected=@{head='a';tree='b';files=@{'one.ps1'='c'}}
$actual=@{head='a';tree='b';files=@{'one.ps1'='c'}}
Require (Test-HeadlessSourcePin $actual $expected) 'exact source'
$actual.files['one.ps1']='d'
Require (-not (Test-HeadlessSourcePin $actual $expected)) 'changed source file'
$actual.files['one.ps1']='c';$actual.files['extra']='e'
Require (-not (Test-HeadlessSourcePin $actual $expected)) 'extra source file'
RequireThrow {Assert-HeadlessPayloadLimit (1MB+1) 1} 'raw cap'
RequireThrow {Assert-HeadlessPayloadLimit 1 1500001} 'wire cap'
Assert-HeadlessPayloadLimit 1MB 1500000
Require ((Limit-HeadlessError ('x'*500)).Length -eq 384) 'error bound'
$aclRule=[pscustomobject]@{PropagationFlags=[Security.AccessControl.PropagationFlags]::None;
    AccessControlType=[Security.AccessControl.AccessControlType]::Allow;
    IdentityReference=[pscustomobject]@{Value='S-1-5-21-1-2-3-4'};
    FileSystemRights=[Security.AccessControl.FileSystemRights]::Write}
$trustedSids=@('S-1-5-18','S-1-5-32-544')
$unsafeRights=[int64][Security.AccessControl.FileSystemRights]::Write -bor
    0x10000000 -bor 0x40000000
Require (Test-HeadlessUntrustedWriter $aclRule $trustedSids $unsafeRights) 'custom SID writer rejected'
$aclRule.FileSystemRights=0x40000000
Require (Test-HeadlessUntrustedWriter $aclRule $trustedSids $unsafeRights) 'generic writer rejected'
$aclRule.PropagationFlags=[Security.AccessControl.PropagationFlags]::InheritOnly
Require (-not (Test-HeadlessUntrustedWriter $aclRule $trustedSids $unsafeRights)) `
    'inherit-only ACE does not grant on current object'
$aclRule.PropagationFlags=[Security.AccessControl.PropagationFlags]::None
$aclRule.IdentityReference.Value='S-1-5-18'
Require (-not (Test-HeadlessUntrustedWriter $aclRule $trustedSids $unsafeRights)) `
    'trusted SYSTEM writer admitted'
$receiptRoot=Join-Path ([IO.Path]::GetTempPath()) 'owned'
$record=[ordered]@{schema='dark240-win11-headless-diagnostic-v1';
    vm_guid='11111111-2222-4333-8444-555555555555';source_head=('a'*40);
    observed_vm_guid='11111111-2222-4333-8444-555555555555';source_tree=('b'*40);
    nonce=('c'*32);retained_root=$receiptRoot;
    root_receipt=@{file_id='root-id';volume='C:\'};
    fixture_inventory=@();failure=$null;outcome='diagnostics-executed';jobs=@()}
$script:headlessOutcome='diagnostics-executed'
$terminalBytes=Get-HeadlessTerminalByteCount ($record | ConvertTo-Json -Depth 15 -Compress)
$script:maxTerminalRecordBytes=$terminalBytes
$wire=Write-HeadlessTerminal $record 0
Require ($wire.StartsWith('DR_HEADLESS_TXF ') -and
    $script:headlessOutcome -ceq 'diagnostics-executed') 'bounded terminal success'
Assert-HeadlessTerminalAccepted
$script:maxTerminalRecordBytes=$terminalBytes-1
$script:headlessOutcome='diagnostics-executed'
$oneByteOver=Write-HeadlessTerminal $record 0
Require ($oneByteOver.Contains('payload-refused') -and
    $script:headlessOutcome -ceq 'payload-refused') 'prefix and CRLF counted at boundary'
$record.jobs=@([ordered]@{name='phase-B';start_attempted=$true;started=$true;
    pid=42;process_start_time_utc_ticks='123';
    process_create_begin_timestamp=100;process_create_end_timestamp=101;
    started_utc='start';ended_utc='end';exit_code=0;wait=@{failure_reason=$null};
    job=@{empty=$true;closed=$true;capture_complete=$true};error=$null;
    stdout_path=(Join-Path $receiptRoot 'phase-B.stdout.bin');
    stderr_path=(Join-Path $receiptRoot 'phase-B.stderr.bin');
    stdout=@{bytes=4;sha256=('f'*64);base64='SECRETBASE64'};
    stderr=$null;controller_result=$null;source_proof=$null;route_record=$null})
$record.fixture_inventory=@([ordered]@{phase='B';before=@{exists=$false;file_id=$null;entries=@()};
    after=@{exists=$true;file_id='base-id';entries=@([ordered]@{name=('c'*32);file_id='leaf-id'})};
    after_error=$null;reconciled=$false;primary_start_attempted=$true;
    primary_started=$true;unattributed=@(('c'*32))})
$script:maxTerminalRecordBytes=40
$rejected=Write-HeadlessTerminal $record 0
Require ($rejected.StartsWith('DR_HEADLESS_TXF ') -and
    $script:headlessOutcome -ceq 'payload-refused' -and
    $rejected.Contains('payload-refused') -and $rejected.Contains('root-id') -and
    $rejected.Contains('leaf-id') -and $rejected.Contains('phase-B.stdout.bin') -and
    $rejected.Contains(('f'*64)) -and -not $rejected.Contains('SECRETBASE64')) `
    'emitter refuses oversized wire terminally while retaining root identity'
RequireThrow {Assert-HeadlessTerminalAccepted} 'payload refusal cannot exit as success'
$script:maxTerminalRecordBytes=1500000

$originalTrace=[Environment]::GetEnvironmentVariable('GIT_TRACE2_EVENT','Process')
$originalGitDir=[Environment]::GetEnvironmentVariable('GIT_DIR','Process')
$originalGitCount=[Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT','Process')
$originalUnknownTrace=[Environment]::GetEnvironmentVariable('GIT_TRACE_FUTURE','Process')
$originalCurl=[Environment]::GetEnvironmentVariable('GIT_CURL_VERBOSE','Process')
$originalProxy=[Environment]::GetEnvironmentVariable('HTTPS_PROXY','Process')
try{
    [Environment]::SetEnvironmentVariable('GIT_DIR','C:\forbidden-owned-route','Process')
    $routeRan=$false
    RequireThrow {Invoke-HeadlessRouteEnvironment -Action {$routeRan=$true}} `
        'repo redirect stops before route Job action'
    Require (-not $routeRan) 'route action did not start under repository redirect'
    [Environment]::SetEnvironmentVariable('GIT_DIR',$null,'Process')
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT','1','Process')
    $routeRan=$false
    RequireThrow {Invoke-HeadlessRouteEnvironment -Action {$routeRan=$true}} `
        'inherited command-scope redirect stops before route Job action'
    Require (-not $routeRan) 'route action did not start under inherited Git config'
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT',$null,'Process')
    [Environment]::SetEnvironmentVariable('GIT_TRACE2_EVENT','/private/trace','Process')
    [Environment]::SetEnvironmentVariable('GIT_TRACE_FUTURE','/private/unknown','Process')
    [Environment]::SetEnvironmentVariable('GIT_CURL_VERBOSE','1','Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY','http://opaque-proxy.invalid','Process')
    Invoke-HeadlessRouteEnvironment -Action {
        Require ([Environment]::GetEnvironmentVariable('GIT_TRACE2_EVENT','Process') -ceq '0' -and
            [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('GIT_TRACE_FUTURE','Process')) -and
            [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('GIT_CURL_VERBOSE','Process')) -and
            [Environment]::GetEnvironmentVariable('HTTPS_PROXY','Process') -ceq
                'http://opaque-proxy.invalid') 'trace disabled while proxy unchanged'
    }
    Require ([Environment]::GetEnvironmentVariable('GIT_TRACE2_EVENT','Process') -ceq '/private/trace' -and
        [Environment]::GetEnvironmentVariable('GIT_TRACE_FUTURE','Process') -ceq '/private/unknown' -and
        [Environment]::GetEnvironmentVariable('GIT_CURL_VERBOSE','Process') -ceq '1') `
        'trace environment restored after route observation'
}
finally{
    [Environment]::SetEnvironmentVariable('GIT_DIR',$originalGitDir,'Process')
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT',$originalGitCount,'Process')
    [Environment]::SetEnvironmentVariable('GIT_TRACE2_EVENT',$originalTrace,'Process')
    [Environment]::SetEnvironmentVariable('GIT_TRACE_FUTURE',$originalUnknownTrace,'Process')
    [Environment]::SetEnvironmentVariable('GIT_CURL_VERBOSE',$originalCurl,'Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY',$originalProxy,'Process')
}

$routePin=@{backend='schannel';origin='file:C:/Program Files/Git/etc/gitconfig'}
Assert-HeadlessGitRoutePin $routePin
RequireThrow {Assert-HeadlessGitRoutePin @{backend='openssl';origin=$routePin.origin}} `
    'unreviewed backend rejected before child'
RequireThrow {Assert-HeadlessGitRoutePin @{backend='schannel';origin='file:C:/Users/User/.gitconfig'}} `
    'different config origin rejected before child'
$gitConfigNames=@('GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0')
$savedGitConfig=@{}
foreach($name in $gitConfigNames){$savedGitConfig[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$privateGitRoot=if($IsWindows){(New-HeadlessPrivateRoot `
    (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp')).path}else{
    Join-Path ([IO.Path]::GetTempPath()) ('headless-git-config-protocol-'+[guid]::NewGuid().ToString('N'))}
if(-not $IsWindows){
    $privateGitDirectory=[IO.Directory]::CreateDirectory($privateGitRoot)
    $privateGitDirectory.UnixFileMode=([IO.UnixFileMode]::UserRead -bor
        [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)}
$emptyTemplate=Join-Path $privateGitRoot 'empty-template'
$emptyConfig=Join-Path $privateGitRoot 'empty-gitconfig'
[void][IO.Directory]::CreateDirectory($emptyTemplate)
$emptyStream=[IO.FileStream]::new($emptyConfig,[IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write,[IO.FileShare]::None)
$emptyStream.Dispose()
try{
    foreach($name in $gitConfigNames){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    $actualGit=(Get-Command git -CommandType Application | Select-Object -First 1).Source
    $actualPwsh=(Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    Invoke-HeadlessGitEnvironment -PrivateRoot $privateGitRoot `
        -GitExecutable $actualGit -PwshExecutable $actualPwsh -GitRoute $routePin -Action {
        Require ([Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT','Process') -ceq '1' -and
            [Environment]::GetEnvironmentVariable('GIT_CONFIG_KEY_0','Process') -ceq 'http.sslBackend' -and
            [Environment]::GetEnvironmentVariable('GIT_CONFIG_VALUE_0','Process') -ceq 'schannel') `
            'only reviewed backend propagates to all Git children'
        $observed=@(& $actualGit config get --url=https://github.com/PiesP/DarkReNamer.git `
            --show-origin --no-show-names http.sslBackend)
        Require ($LASTEXITCODE -eq 0 -and $observed.Count -eq 1 -and
            $observed[0] -ceq "command line:`tschannel") `
            'actual Git sees command-scope backend with strict source'
    }
    foreach($name in $gitConfigNames){
        Require ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name,'Process'))) `
            'Git command-scope injection is restored after action'}
    $script:throwingGitActionRan=$false
    RequireThrow {Invoke-HeadlessGitEnvironment -PrivateRoot $privateGitRoot `
        -GitExecutable $actualGit -PwshExecutable $actualPwsh -GitRoute $routePin -Action {
            $script:throwingGitActionRan=$true
            throw 'Controlled action failure after backend injection.'}} `
        'action failure propagates'
    Require $script:throwingGitActionRan 'throwing action reached isolated environment'
    foreach($name in $gitConfigNames){
        Require ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name,'Process'))) `
            'Git command-scope injection is restored after throwing action'}
}
finally{
    foreach($name in $gitConfigNames){
        [Environment]::SetEnvironmentVariable($name,$savedGitConfig[$name],'Process')}
    if(@([IO.Directory]::EnumerateFileSystemEntries($privateGitRoot)).Count -ne 2 -or
        @([IO.Directory]::EnumerateFileSystemEntries($emptyTemplate)).Count -ne 0){
        throw 'Protocol-owned Git input root acquired an unexpected entry.'}
    [IO.File]::Delete($emptyConfig)
    [IO.Directory]::Delete($emptyTemplate,$false)
    [IO.Directory]::Delete($privateGitRoot,$false)
}

$routeAssignment=@($embedded | Where-Object {$_.Left.Extent.Text -ceq '$routeCode'})[0]
$actualRoute=[scriptblock]::Create($routeAssignment.Right.Expression.Value)
$script:fakeGitValues=@{'http.sslBackend'="file:C:/Program Files/Git/etc/gitconfig`tschannel"}
$script:fakeGitCodes=@{}
function FakeRouteGit {
    $key=[string]$args[-1]
    if($script:fakeGitValues.ContainsKey($key)){
        $global:LASTEXITCODE=if($script:fakeGitCodes.ContainsKey($key)){
            $script:fakeGitCodes[$key]}else{0}
        return $script:fakeGitValues[$key]
    }
    $global:LASTEXITCODE=1
}
$routeBase=Join-Path ([IO.Path]::GetTempPath()) ('headless-route-protocol-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($routeBase)
$checkedEnvironment=@('GIT_SSL_NO_VERIFY','GIT_SSL_CAINFO','GIT_SSL_CAPATH',
    'GIT_SSL_CERT','GIT_SSL_KEY','GIT_SSL_VERSION','GIT_SSL_CIPHER_LIST',
    'GIT_SSL_CERT_PASSWORD_PROTECTED','GIT_SSL_CERT_TYPE','GIT_SSL_KEY_TYPE',
    'CURL_CA_BUNDLE',
    'SSL_CERT_FILE','SSL_CERT_DIR','HTTPS_PROXY','https_proxy','ALL_PROXY',
    'all_proxy','NO_PROXY','no_proxy')
function Save-ProtocolEnvironment([string[]]$Names) {
    $snapshot=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $current=[Environment]::GetEnvironmentVariables('Process')
    foreach($name in $Names){
        $snapshot[$name]=@{present=$current.Contains($name);
            value=[Environment]::GetEnvironmentVariable($name,'Process')}}
    return $snapshot
}
function Restore-ProtocolEnvironment([string[]]$Names,$Snapshot) {
    foreach($name in $Names){
        if($Snapshot[$name].present){
            Set-Item -LiteralPath ('Env:'+$name) -Value $Snapshot[$name].value
        }else{Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue}}
}
if(-not $IsWindows){
    $caseNames=@('HTTPS_PROXY','https_proxy')
    $originalCase=Save-ProtocolEnvironment $caseNames
    try{
        Set-Item -LiteralPath 'Env:HTTPS_PROXY' -Value 'http://uppercase.invalid'
        Set-Item -LiteralPath 'Env:https_proxy' -Value 'http://lowercase.invalid'
        $caseSnapshot=Save-ProtocolEnvironment $caseNames
        Require ($caseSnapshot.Count -eq 2 -and $caseSnapshot['HTTPS_PROXY'].present -and
            $caseSnapshot['https_proxy'].present -and
            $caseSnapshot['HTTPS_PROXY'].value -cne $caseSnapshot['https_proxy'].value) `
            'Linux environment snapshot retains distinct proxy key casing'
        foreach($name in $caseNames){Remove-Item -LiteralPath ('Env:'+$name)}
        Restore-ProtocolEnvironment $caseNames $caseSnapshot
        Require ([Environment]::GetEnvironmentVariable('HTTPS_PROXY','Process') -ceq
                'http://uppercase.invalid' -and
            [Environment]::GetEnvironmentVariable('https_proxy','Process') -ceq
                'http://lowercase.invalid') `
            'Linux environment restore retains both distinct proxy values'
    }
    finally{Restore-ProtocolEnvironment $caseNames $originalCase}
}else{Write-Host 'Case-distinct environment control applies only to Linux.'}
$savedEnvironment=Save-ProtocolEnvironment $checkedEnvironment
try{
    foreach($name in $checkedEnvironment){Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue}
    function RunRoute([string]$Case) {
        $root=Join-Path $routeBase $Case
        [void][IO.Directory]::CreateDirectory($root)
        & $actualRoute -Git 'FakeRouteGit' -Root $root -ExpectedBackend $routePin.backend `
            -ExpectedOrigin $routePin.origin
        return Get-Content -LiteralPath (Join-Path $root 'route.json') -Raw | ConvertFrom-Json -AsHashtable
    }
    $goodRoute=RunRoute 'good'
    Require ($goodRoute.configured_git_backend -ceq 'schannel' -and
        $goodRoute.configured_git_backend_origin -ceq $routePin.origin -and
        -not $goodRoute.configured_git_proxy) 'actual route script captures reviewed backend and origin'
    $script:fakeGitValues['http.sslBackend']="file:C:/Users/User/.gitconfig`tschannel"
    RequireThrow {RunRoute 'different-origin'} 'actual route rejects changed backend origin'
    $script:fakeGitValues['http.sslBackend']="file:C:/Program Files/Git/etc/gitconfig`topenssl"
    RequireThrow {RunRoute 'different-backend'} 'actual route rejects unsupported backend'
    $script:fakeGitValues['http.sslBackend']="file:C:/Program Files/Git/etc/gitconfig`tschannel"
    $script:fakeGitValues['http.sslCAInfo']='C:/unqualified-ca.pem'
    RequireThrow {RunRoute 'custom-ca'} 'actual route rejects unqualified CA input'
    $script:fakeGitValues.Remove('http.sslCAInfo')
    $script:fakeGitValues['http.sslCAInfo']=''
    RequireThrow {RunRoute 'blank-custom-ca'} 'configured but blank CA input is not observed-unset'
    $script:fakeGitValues.Remove('http.sslCAInfo')
    $script:fakeGitValues['http.sslCAInfo']='unexpected-output-with-exit-one'
    $script:fakeGitCodes['http.sslCAInfo']=1
    RequireThrow {RunRoute 'unset-with-output'} 'unset exit with output is incomplete'
    $script:fakeGitCodes.Remove('http.sslCAInfo')
    $script:fakeGitValues.Remove('http.sslCAInfo')
    $script:fakeGitValues['http.sslCipherList']='unqualified-cipher'
    RequireThrow {RunRoute 'cipher-config'} 'actual route rejects unqualified cipher input'
    $script:fakeGitValues.Remove('http.sslCipherList')
    $script:fakeGitValues['http.pinnedPubkey']='sha256//unqualified'
    RequireThrow {RunRoute 'pinned-key'} 'actual route rejects unqualified pinned-key input'
    $script:fakeGitValues.Remove('http.pinnedPubkey')
    $script:fakeGitValues['http.sslVerify']='false'
    RequireThrow {RunRoute 'tls-disabled'} 'actual route rejects disabled TLS verification'
    $script:fakeGitValues['http.sslVerify']=''
    RequireThrow {RunRoute 'tls-blank'} 'configured blank TLS verification is not observed-unset'
    $script:fakeGitValues.Remove('http.sslVerify')
    [Environment]::SetEnvironmentVariable('GIT_SSL_NO_VERIFY','1','Process')
    RequireThrow {RunRoute 'tls-environment'} 'actual route rejects TLS environment override'
    Remove-Item -LiteralPath 'Env:GIT_SSL_NO_VERIFY' -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('GIT_SSL_CIPHER_LIST','unqualified','Process')
    RequireThrow {RunRoute 'cipher-environment'} 'actual route rejects unqualified cipher environment'
    Remove-Item -LiteralPath 'Env:GIT_SSL_CIPHER_LIST' -ErrorAction SilentlyContinue
    Set-Item -LiteralPath 'Env:GIT_SSL_CIPHER_LIST' -Value ''
    if([Environment]::GetEnvironmentVariables('Process').Contains('GIT_SSL_CIPHER_LIST')){
        RequireThrow {RunRoute 'empty-cipher-environment'} `
            'actual route rejects present empty cipher environment'
    }else{Write-Host 'Empty-present environment control unavailable on this runtime.'}
}
finally{
    Restore-ProtocolEnvironment $checkedEnvironment $savedEnvironment
    [IO.Directory]::Delete($routeBase,$true)
}

$fixtureBase=Join-Path ([IO.Path]::GetTempPath()) 'Dark180-TxfPhaseB'
$first=('a'*32);$second=('b'*32)
$before=@{exists=$true;file_id='base';entries=@([ordered]@{name=$first;file_id='id-a'})}
$after=@{exists=$true;file_id='base';entries=@([ordered]@{name=$first;file_id='id-a'},
    [ordered]@{name=$second;file_id='id-b'})}
$controller=@{trials=@(@{scope=(Join-Path $fixtureBase $second)})}
Require (Test-HeadlessInventoryReconciled $before $after $controller $fixtureBase) `
    'one reported new fixture scope'
$after.entries[1].name=('c'*32)
Require (-not (Test-HeadlessInventoryReconciled $before $after $controller $fixtureBase)) `
    'unattributed fixture scope rejected'
$after.entries[1].name=$second;$after.entries[0].file_id='changed'
Require (-not (Test-HeadlessInventoryReconciled $before $after $controller $fixtureBase)) `
    'replacement of a retained fixture scope rejected'

$phaseRow=[ordered]@{primary_start_attempted=$false;primary_started=$false}
Set-HeadlessPrimaryAttribution $phaseRow $null
Require (-not $phaseRow.primary_start_attempted -and $phaseRow.primary_started -eq $false) `
    'proof-stage skip did not attempt a primary'
$attempted=[ordered]@{start_attempted=$true;started=$null;pid=$null;
    process_start_time_utc_ticks=$null}
Set-HeadlessPrimaryAttribution $phaseRow $attempted
Require ($phaseRow.primary_start_attempted -and $null -eq $phaseRow.primary_started) `
    'factory attempt with missing lifetime remains unknown'
$attempted.pid=42;$attempted.process_start_time_utc_ticks='123';$attempted.started=$true
Set-HeadlessPrimaryAttribution $phaseRow $attempted
Require ($phaseRow.primary_start_attempted -and $phaseRow.primary_started -eq $true) `
    'observed PID and start time admit primary start'

$mockRoot=Join-Path ([IO.Path]::GetTempPath()) ('dark240-headless-start-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($mockRoot)
try{
    $script:headlessRoot=$mockRoot;$script:rootReceipt=@{}
    $script:headlessRows=[Collections.Generic.List[object]]::new()
    function Assert-HeadlessRootUnchanged {param($Expected,$Path)} # Only the unrelated native root check is stubbed.
    function Start-JobBoundProcess {
        param($FilePath,$Arguments,$WorkingDirectory,$StdoutPath,$StderrPath,$AggregateOutputLimitBytes)
        throw 'injected owned factory failure'
    }
    RequireThrow {Invoke-HeadlessJob -Name 'phase-B' -File 'never-launched' -Arguments '' `
        -Work $mockRoot -Seconds 1} 'owned factory exception stops'
    Require ($script:headlessRows.Count -eq 1 -and
        $script:headlessRows[0].start_attempted -and
        $null -eq $script:headlessRows[0].started -and
        $null -eq $script:headlessRows[0].pid) `
        'actual factory-throw path records unknown startup, not skipped or executed'
}
finally{[IO.Directory]::Delete($mockRoot,$false)}

$temporary=Join-Path ([IO.Path]::GetTempPath()) ('dark240-headless-protocol-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try{
    $checkout=Join-Path $temporary 'checkout';[void][IO.Directory]::CreateDirectory($checkout)
    [IO.File]::WriteAllBytes((Join-Path $checkout 'a.bin'),[byte[]](1,2,3))
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Assert-HeadlessCheckoutBudget $checkout $watch 10
    $large=Join-Path $checkout 'large.bin'
    $file=[IO.FileStream]::new($large,[IO.FileMode]::CreateNew)
    try{$file.SetLength(128MB+1)}finally{$file.Dispose()}
    RequireThrow {Assert-HeadlessCheckoutBudget $checkout $watch 10} 'checkout byte cap'
}
finally{[IO.Directory]::Delete($temporary,$true)}

# Call the actual generator's pure assembly path without creating or changing a Git repository.
$python=if($IsWindows){'python'}else{'python3'}
$pythonCode=@'
import importlib.util, pathlib, tempfile, json, os
spec=importlib.util.spec_from_file_location('headless_generator',r'__GENERATOR__')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temp:
    root=pathlib.Path(temp)
    for name, data in ((module.HELPER,b'function Helper {}\n'),
                       (module.WRAPPER,b'$pin="__HEADLESS_PIN_BASE64__"\n')):
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
    pin={'head':'a'*40,'tree':'b'*40,'files':{'x':'c'*64}}
    guest=module.guest_pin('S-1-5-21-1-2-3-4','TEST\\User','false',26300,
        r'C:\Program Files\Git\cmd\git.exe','d'*64,'2.56.0.windows.2','2.56.0.windows.2',
        r'C:\ProgramData\Tools\pwsh.exe','e'*64,'7.4.19.500','7.4.19')
    route=module.git_route_pin('schannel','file:C:/Program Files/Git/etc/gitconfig')
    good=module.assemble(root,pin,'11111111-2222-4333-8444-555555555555',guest,route)
    assert b'__HEADLESS_PIN_BASE64__' not in good and len(good)<module.MAX_SCRIPT_BYTES
    for bad in ('00000000-0000-0000-0000-000000000000','not-a-guid'):
        try:module.assemble(root,pin,bad,guest,route)
        except ValueError:pass
        else:raise AssertionError('invalid VM GUID accepted')
    for backend,origin in (('openssl',route['origin']),('schannel','file:C:/Users/User/.gitconfig')):
        try:module.git_route_pin(backend,origin)
        except ValueError:pass
        else:raise AssertionError('unreviewed backend or origin accepted')
    try:module.assemble(root,pin,'11111111-2222-4333-8444-555555555555',guest,
                        {'backend':'schannel','origin':route['origin'],'extra':'value'})
    except ValueError:pass
    else:raise AssertionError('extra route pin accepted')
    for name in module.SOURCE_FILES:
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
        if not path.exists():path.write_bytes(name.encode())
    committed={name:(root/name).read_bytes() for name in module.SOURCE_FILES}
    def fake_git(repo,*args):
        if args==('rev-parse','HEAD'):return b'a'*40+b'\n'
        if args==('rev-parse','HEAD^{tree}'):return b'b'*40+b'\n'
        if args[0]=='status':return b''
        if args==('ls-files','-v','-z'):return b''.join(b'H '+name.encode()+b'\0' for name in module.SOURCE_FILES)
        if args[0]=='ls-files':return ('\0'.join(module.SOURCE_FILES)+'\0').encode()
        if args[0]=='show':return committed[args[1][5:]]
        raise AssertionError(args)
    module.run_git=fake_git
    assert module.source_pin(root,'a'*40)['files'][module.HELPER]
    def hidden_index(repo,*args):
        if args==('ls-files','-v','-z'):return b'S '+module.HELPER.encode()+b'\0'
        return fake_git(repo,*args)
    module.run_git=hidden_index
    try:module.source_pin(root,'a'*40)
    except ValueError:pass
    else:raise AssertionError('hidden index path accepted')
    module.run_git=fake_git
    (root/module.HELPER).write_bytes(b'changed but status reports clean')
    try:module.source_pin(root,'a'*40)
    except ValueError:pass
    else:raise AssertionError('committed blob mismatch accepted despite clean status')
    try:module.guest_pin('bad','TEST\\User','false',26300,r'C:\git.exe','d'*64,
                         '1.0','1.0',r'C:\pwsh.exe','e'*64,'7.4','7.4')
    except ValueError:pass
    else:raise AssertionError('invalid guest SID accepted')
    try:module.guest_pin('S-1-5-21-1-2-3-4','TEST\\User','false',26300,
                         r'C:\bad"tool.exe','d'*64,'1.0','1.0',
                         r'C:\pwsh.exe','e'*64,'7.4','7.4')
    except ValueError:pass
    else:raise AssertionError('quoted guest executable path accepted')
    if os.name=='posix':
        with tempfile.TemporaryDirectory(dir=pathlib.Path.home()) as trusted_dir:
            parent=pathlib.Path(trusted_dir)
            assert module.trusted_local_path(parent,private_leaf=True)==parent
            trusted=pathlib.Path(trusted_dir)/'trusted'
            trusted.write_bytes(b'x');trusted.chmod(0o700)
            assert module.trusted_local_path(trusted)==trusted
            trusted.chmod(0o722)
            try:module.trusted_local_path(trusted)
            except ValueError:pass
            else:raise AssertionError('group/other writable local Git accepted')
            parent.chmod(0o755)
            try:module.trusted_local_path(parent,private_leaf=True)
            except ValueError:pass
            else:raise AssertionError('nonprivate output parent accepted')
            parent.chmod(0o700)
            link=parent/'link';link.symlink_to(trusted)
            try:module.trusted_local_path(link)
            except ValueError:pass
            else:raise AssertionError('local symlink accepted')
print('generator assembly controls passed')
'@
$pythonCode=$pythonCode.Replace('__GENERATOR__',$generator.Replace('\','\\'))
$output=& $python -c $pythonCode 2>&1
if($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'generator assembly controls passed'){
    throw "Actual generator assembly controls failed: $($output -join ' ')"
}
Write-Host 'Headless TxF bootstrap protocol controls passed.'
