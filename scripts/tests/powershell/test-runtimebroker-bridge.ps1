$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$path=Join-Path $root 'scripts/modules/powershell/runtimebroker-bridge.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count -ne 0){throw 'RuntimeBroker bridge has parse errors.'}
$functions=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-DrBrokerRpc'
},$true))
if($functions.Count -ne 1){throw 'Bridge RPC parser must be uniquely defined.'}
. ([scriptblock]::Create($functions[0].Extent.Text))

$valid='{"sequence":1,"operation":"ready","run_id":"0123456789abcdef0123456789abcdef","payload":null}'
$actual=Read-DrBrokerRpc $valid
if($actual.sequence -ne 1 -or $actual.operation -cne 'ready'){throw 'RPC parser changed ordinary command.'}
foreach($invalid in @(
    '{"sequence":1,"sequence":2}',
    '{"payload":{"phase":"a","phase":"b"}}',
    '{"payload":[{"run_id":"a","run_id":"b"}]}',
    ('{"payload":"'+('x'*8192)+'"}'),
    '{malformed'
)){
    $rejected=$false
    try{[void](Read-DrBrokerRpc $invalid)}catch{$rejected=$true}
    if(-not $rejected){throw 'Malformed, duplicate or oversized RPC was accepted.'}
}
'RuntimeBroker bridge portable RPC checks passed.'

$sourceFunctions=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Convert-DrBrokerSource'
},$true))
if($sourceFunctions.Count -ne 1){throw 'Verified source decoder is not uniquely defined.'}
. ([scriptblock]::Create($sourceFunctions[0].Extent.Text))
$sources=@{}
foreach($name in @('guest-contracts','guest-native','guest-process')){
    $bytes=[IO.File]::ReadAllBytes((Join-Path $root ('scripts/modules/powershell/'+$name+'.ps1')))
    $sources[$name]=Convert-DrBrokerSource $bytes
}
$module=New-Module -ArgumentList (,$sources) -ScriptBlock {
    param($sources)
    foreach($name in @('guest-contracts','guest-native','guest-process')){. ([scriptblock]::Create($sources[$name]))}
}
try{
    & $module {
        foreach($name in @('Assert-ExactProperties','Start-JobBoundProcess','Close-JobBoundProcess')){
            if($null -eq(Get-Command -Name $name -CommandType Function -ErrorAction Stop)){throw 'Verified source function did not load.'}
        }
    }
}finally{Remove-Module -ModuleInfo $module -Force}
'RuntimeBroker bridge verified BOM source reconstruction passed.'

$readers=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-Ordinary'
},$true))
if($readers.Count -ne 1){throw 'Bridge ordinary reader is not uniquely defined.'}
. ([scriptblock]::Create($readers[0].Extent.Text))
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('broker-reader-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    foreach($sample in @(@{name='empty';bytes=[byte[]]@()},@{name='one';bytes=[byte[]]@(7)},@{name='many';bytes=[byte[]]@(1,2,3)})){
        $file=Join-Path $temporary $sample.name
        [IO.File]::WriteAllBytes($file,$sample.bytes)
        $bytes=Read-Ordinary $file 64
        if($bytes -isnot [byte[]] -or $bytes.Length -ne $sample.bytes.Length){throw 'Bridge reader changed the byte-array shape.'}
        $actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        $expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sample.bytes))
        if($actual -cne $expected){throw 'Bridge reader changed frozen bytes.'}
    }
}finally{[IO.Directory]::Delete($temporary,$true)}
'RuntimeBroker bridge empty and short file collection checks passed.'
