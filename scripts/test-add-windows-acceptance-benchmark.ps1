[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$augmenter = Join-Path $PSScriptRoot 'add-windows-acceptance-benchmark.ps1'
$draftGenerator = Join-Path $PSScriptRoot 'new-windows-acceptance-draft.ps1'
$validator = Join-Path $PSScriptRoot 'validate-windows-acceptance-evidence.ps1'
foreach ($path in $augmenter, $draftGenerator, $validator) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required acceptance script is missing: $path" }
}

function Write-Utf8([string]$Path, [string]$Content) { [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false)) }
function Write-Json([string]$Path, [object]$Value) { Write-Utf8 $Path (($Value | ConvertTo-Json -Depth 20) + "`n") }
function Copy-Json([object]$Value) { return $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json }

function Write-Context([string]$Directory, [string]$StorageModel = 'Fixture SSD Model') {
    Write-Json (Join-Path $Directory 'benchmark-context.json') ([ordered]@{
        schema_version=1; windows_product='Windows 11'; windows_build='26100.4946'; architecture='x64';
        filesystem='ntfs'; storage_model=$StorageModel; connection='nvme';
        free_space_bucket='50-percent-or-more'; power_mode='balanced'
    })
}

function New-Summary([int]$Iteration, [string]$Sha, [string]$Media='ssd', [int]$Count=100) {
    $planning = @(9,1,7,3,5)[$Iteration - 1]
    $execution = @(10,2,8,4,6)[$Iteration - 1]
    return "darkrenamer_benchmark,media=$Media,count=$Count,topology=same-parent,variant=baseline,evidence_class=physical,iteration=$Iteration,recorded=true,scope=durable,source_sha=$Sha,instrumentation_revision=parent-validation-v1,planning_ms=$planning,execution_ms=$execution,planning_us=$($planning * 1000 + 321),preflight_us=44,execution_us=$($execution * 1000 + 654)"
}

function Write-Logs([string]$Directory, [string]$Sha, [string]$Media='ssd', [int]$Count=100) {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    Write-Context $Directory
    foreach ($iteration in 1..5) {
        $content = "running 1 test`nknown harness line`ndarkrenamer_benchmark_backend,known=diagnostic`ndarkrenamer_benchmark_journal,known=diagnostic`ntest benchmark_durable_production_path ... $(New-Summary $iteration $Sha $Media $Count)`ntest result: ok. 1 passed; 0 failed`n"
        Write-Utf8 (Join-Path $Directory "iteration-$iteration.log") $content
    }
}

function New-Case([string]$Name, [string]$Media='ssd', [int]$Count=100) {
    $root = Join-Path $script:testRoot $Name
    New-Item -ItemType Directory -Path $root | Out-Null
    $evidence = Join-Path $root 'input.json'
    Copy-Item -LiteralPath $script:baseEvidence -Destination $evidence
    $logs = Join-Path $root 'logs'
    Write-Logs $logs $script:sourceSha $Media $Count
    return [pscustomobject]@{ Root=$root; Evidence=$evidence; Logs=$logs; Output=(Join-Path $root 'output.json') }
}

function Assert-NoTemp([string]$Output) {
    $parent = Split-Path -Parent $Output; $leaf = [IO.Path]::GetFileName($Output)
    if ((Test-Path $parent) -and @(Get-ChildItem -LiteralPath $parent -File | Where-Object Name -Like ".$leaf.*.tmp").Count) { throw 'Augmenter left an owned temporary file.' }
}

function Assert-Fails([scriptblock]$Command, [string]$Fragment, [string]$Output, [string]$Forbidden='') {
    try { & $Command } catch {
        if ($_.Exception.Message -notlike "*$Fragment*") { throw "Expected '$Fragment', got: $($_.Exception.Message)" }
        if ($Forbidden -and $_.Exception.Message -like "*$Forbidden*") { throw "Failure echoed forbidden mutation '$Forbidden': $($_.Exception.Message)" }
        if (Test-Path -LiteralPath $Output) { throw "Failure created output: $Output" }
        Assert-NoTemp $Output
        return
    }
    throw "Expected failure containing '$Fragment'."
}

function Mutate-FirstLog([object]$Case, [scriptblock]$Mutation) {
    $path = Join-Path $Case.Logs 'iteration-1.log'
    $text = Get-Content -LiteralPath $path -Raw
    Write-Utf8 $path (& $Mutation $text)
}

function New-DirectoryLink([string]$Path, [string]$Target) {
    if ($IsWindows) { New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null }
    else { New-Item -ItemType SymbolicLink -Path $Path -Target $Target | Out-Null }
    $script:links.Add($Path)
}

$sourceRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$sourceSha = (& git -C $sourceRoot rev-parse HEAD).Trim()
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "darkrenamer-benchmark-import-$([Guid]::NewGuid())"
$links = [Collections.Generic.List[string]]::new()
$insideOutput = $null
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $exe = Join-Path $testRoot 'DarkReNamer.exe'; [IO.File]::WriteAllBytes($exe, [byte[]](0x4d,0x5a,1,2))
    $baseEvidence = Join-Path $testRoot 'base.json'
    & $draftGenerator -SourceRoot $sourceRoot -OutputPath $baseEvidence -ExecutablePath $exe | Out-Null

    $happy = New-Case 'happy'
    & $augmenter -SourceRoot $sourceRoot -EvidencePath $happy.Evidence -LogDirectory $happy.Logs -OutputPath $happy.Output | Out-Null
    $result = & $validator -EvidencePath $happy.Output -Draft -PassThru
    $row = @($result.benchmarks)[0]
    if (@($result.benchmarks).Count -ne 1 -or $row.media -cne 'ssd' -or $row.count -ne 100 -or $row.planning_ms -ne 5 -or $row.execution_ms -ne 6 -or $row.cleanup_observation -cne 'clean') { throw 'Known unsorted medians were not imported correctly.' }
    if (@($result.operator_context).Count -ne 1 -or @($result.unexecuted | Where-Object target -eq 'benchmark|ssd|100').Count -ne 0) { throw 'Context insertion or target-reason removal failed.' }
    $raw = Get-Content $happy.Output -Raw
    if ($raw.Contains($happy.Logs) -or $raw.Contains('darkrenamer_benchmark')) { throw 'Output leaked paths or raw log content.' }

    $hdd = New-Case 'hdd-happy' 'hdd' 100
    & $augmenter -SourceRoot $sourceRoot -EvidencePath $hdd.Evidence -LogDirectory $hdd.Logs -OutputPath $hdd.Output | Out-Null
    $hddResult = & $validator -EvidencePath $hdd.Output -Draft -PassThru
    if (@($hddResult.benchmarks | Where-Object { $_.media -ceq 'hdd' -and $_.count -eq 100 }).Count -ne 1 -or
        @($hddResult.unexecuted | Where-Object target -eq 'benchmark|hdd|100').Count -ne 0) {
        throw 'Valid HDD target did not replace its exact unexecuted reason.'
    }

    $standalone = New-Case 'standalone-summary'
    foreach ($log in Get-ChildItem -LiteralPath $standalone.Logs -Filter '*.log') {
        $text = Get-Content -LiteralPath $log.FullName -Raw
        Write-Utf8 $log.FullName ($text.Replace('test benchmark_durable_production_path ... darkrenamer_benchmark,','darkrenamer_benchmark,'))
    }
    & $augmenter -SourceRoot $sourceRoot -EvidencePath $standalone.Evidence -LogDirectory $standalone.Logs -OutputPath $standalone.Output | Out-Null

    $noncanonicalPrefix = New-Case 'noncanonical-prefix'
    Mutate-FirstLog $noncanonicalPrefix { param($t) $t.Replace('test benchmark_durable_production_path ... darkrenamer_benchmark,','2026-09-01T00:00:00Z job darkrenamer_benchmark,') }
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $noncanonicalPrefix.Evidence -LogDirectory $noncanonicalPrefix.Logs -OutputPath $noncanonicalPrefix.Output } 'noncanonical benchmark summary prefix' $noncanonicalPrefix.Output

    $chainRoot = Join-Path $testRoot 'chain'; New-Item -ItemType Directory $chainRoot | Out-Null
    $chainLogs = Join-Path $chainRoot 'logs'; Write-Logs $chainLogs $sourceSha 'ssd' 1000
    $chainOutput = Join-Path $chainRoot 'output.json'
    & $augmenter -SourceRoot $sourceRoot -EvidencePath $happy.Output -LogDirectory $chainLogs -OutputPath $chainOutput | Out-Null
    $chained = & $validator -EvidencePath $chainOutput -Draft -PassThru
    if (@($chained.benchmarks).Count -ne 2 -or @($chained.operator_context).Count -ne 1 -or -not (@($chained.benchmarks).media -contains 'ssd')) { throw 'Chaining did not preserve the prior row or exact context.' }

    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $happy.Output -LogDirectory $happy.Logs -OutputPath (Join-Path $happy.Root 'duplicate.json') } 'already contains this benchmark target' (Join-Path $happy.Root 'duplicate.json')

    $missingReason = New-Case 'missing-target-reason'
    $missingReasonEvidence = Get-Content $missingReason.Evidence -Raw | ConvertFrom-Json
    $missingReasonEvidence.unexecuted = @($missingReasonEvidence.unexecuted | Where-Object target -ne 'benchmark|ssd|100')
    Write-Json $missingReason.Evidence $missingReasonEvidence
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $missingReason.Evidence -LogDirectory $missingReason.Logs -OutputPath $missingReason.Output } 'must explain omitted benchmark target' $missingReason.Output

    $conflict = New-Case 'context-conflict'
    $conflictEvidence = Get-Content $conflict.Evidence -Raw | ConvertFrom-Json
    $conflictEvidence.operator_context = @([pscustomobject]@{ windows_product='Windows 11'; windows_build='22621'; architecture='x64' })
    Write-Json $conflict.Evidence $conflictEvidence
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $conflict.Evidence -LogDirectory $conflict.Logs -OutputPath $conflict.Output } 'conflicts with existing operator context' $conflict.Output

    foreach ($caseSpec in @(
        @{ N='hosted'; O='evidence_class=physical'; R='evidence_class=directional-hosted'; E='recorded physical' },
        @{ N='estimate'; O='variant=baseline'; R='variant=validation-skip-estimate'; E='recorded physical' },
        @{ N='unique'; O='topology=same-parent'; R='topology=unique-parent'; E='recorded physical' },
        @{ N='recorded'; O='recorded=true'; R='recorded=false'; E='recorded physical' },
        @{ N='scope'; O='scope=durable'; R='scope=planning'; E='recorded physical' },
        @{ N='revision'; O='instrumentation_revision=parent-validation-v1'; R='instrumentation_revision=other-v1'; E='recorded physical' },
        @{ N='mixed-media'; O='media=ssd'; R='media=hdd'; E='one media and count' },
        @{ N='mixed-count'; O='count=100'; R='count=1000'; E='one media and count' },
        @{ N='sha'; O="source_sha=$sourceSha"; R=('source_sha=' + ('a'*40)); E='source_sha does not match' },
        @{ N='malformed-key'; O='planning_ms=9'; R='plan_ms=9'; E='malformed benchmark summary' },
        @{ N='extra-key'; O='execution_us=10654'; R='execution_us=10654,extra=1'; E='malformed benchmark summary' },
        @{ N='duplicate-key'; O='execution_us=10654'; R='execution_us=10654,planning_ms=9'; E='malformed benchmark summary' },
        @{ N='ms-us'; O='planning_us=9321'; R='planning_us=10321'; E='millisecond values do not match' }
    )) {
        $c=New-Case $caseSpec.N; Mutate-FirstLog $c { param($t) $t.Replace($caseSpec.O,$caseSpec.R) }
        Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $c.Evidence -LogDirectory $c.Logs -OutputPath $c.Output } $caseSpec.E $c.Output
    }

    foreach ($hazard in '01','-1','+1',' 9','1.0','1e3','NaN','Infinity','١') {
        $c=New-Case ("numeric-" + [Guid]::NewGuid().ToString('N'))
        Mutate-FirstLog $c { param($t) [regex]::Replace($t,'planning_ms=9',"planning_ms=$hazard",1) }
        Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $c.Evidence -LogDirectory $c.Logs -OutputPath $c.Output } 'malformed benchmark summary' $c.Output
    }

    foreach ($iterationCase in @(@{N='duplicate-iteration';V='4'},@{N='warmup';V='0'})) {
        $c=New-Case $iterationCase.N
        $p=Join-Path $c.Logs 'iteration-5.log'; $t=Get-Content $p -Raw; Write-Utf8 $p ($t.Replace('iteration=5',"iteration=$($iterationCase.V)"))
        Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $c.Evidence -LogDirectory $c.Logs -OutputPath $c.Output } $(if($iterationCase.V -eq '0'){'invalid benchmark target or iteration'}else{'iterations must be exactly'}) $c.Output
    }
    $missingIteration=New-Case 'missing-iteration'
    $p=Join-Path $missingIteration.Logs 'iteration-5.log';$t=Get-Content $p -Raw;Write-Utf8 $p ($t.Replace('iteration=5','iteration=6'))
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $missingIteration.Evidence -LogDirectory $missingIteration.Logs -OutputPath $missingIteration.Output } 'invalid benchmark target or iteration' $missingIteration.Output

    $missingLog=New-Case 'missing-log'; Remove-Item (Join-Path $missingLog.Logs 'iteration-5.log')
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $missingLog.Evidence -LogDirectory $missingLog.Logs -OutputPath $missingLog.Output } 'exactly five' $missingLog.Output
    $duplicateSummary=New-Case 'duplicate-summary'; Mutate-FirstLog $duplicateSummary { param($t) $t.Replace('test result: ok.',"$(New-Summary 1 $sourceSha)`ntest result: ok.") }
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $duplicateSummary.Evidence -LogDirectory $duplicateSummary.Logs -OutputPath $duplicateSummary.Output } 'more than one' $duplicateSummary.Output
    $missingSuccess=New-Case 'missing-success'; Mutate-FirstLog $missingSuccess { param($t) $t.Replace('test result: ok.','test result: FAILED.') }
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $missingSuccess.Evidence -LogDirectory $missingSuccess.Logs -OutputPath $missingSuccess.Output } 'later successful test result' $missingSuccess.Output
    $unknown=New-Case 'unknown-prefix'; Mutate-FirstLog $unknown { param($t) "darkrenamer_benchmark_unknown,secret=raw-marker`n$t" }
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $unknown.Evidence -LogDirectory $unknown.Logs -OutputPath $unknown.Output } 'unknown benchmark diagnostic prefix' $unknown.Output 'raw-marker'

    $bom=New-Case 'utf8-bom';$p=Join-Path $bom.Logs 'iteration-1.log';$b=[Text.UTF8Encoding]::new($false).GetBytes((Get-Content $p -Raw));[IO.File]::WriteAllBytes($p,[byte[]](@(0xef,0xbb,0xbf)+$b))
    & $augmenter -SourceRoot $sourceRoot -EvidencePath $bom.Evidence -LogDirectory $bom.Logs -OutputPath $bom.Output | Out-Null
    $nul=New-Case 'nul';Mutate-FirstLog $nul {param($t)$t+[char]0};Assert-Fails {&$augmenter -SourceRoot $sourceRoot -EvidencePath $nul.Evidence -LogDirectory $nul.Logs -OutputPath $nul.Output} 'contains NUL' $nul.Output
    $long=New-Case 'long-line';Mutate-FirstLog $long {param($t)('x'*8193)+"`n"+$t};Assert-Fails {&$augmenter -SourceRoot $sourceRoot -EvidencePath $long.Evidence -LogDirectory $long.Logs -OutputPath $long.Output} 'overlong line' $long.Output
    $badUtf=New-Case 'bad-utf8';[IO.File]::WriteAllBytes((Join-Path $badUtf.Logs 'iteration-1.log'),[byte[]](0xff,0xfe));Assert-Fails {&$augmenter -SourceRoot $sourceRoot -EvidencePath $badUtf.Evidence -LogDirectory $badUtf.Logs -OutputPath $badUtf.Output} 'strict UTF-8' $badUtf.Output
    $large=New-Case 'large-log';[IO.File]::WriteAllBytes((Join-Path $large.Logs 'iteration-1.log'),[byte[]]::new(4*1024*1024+1));Assert-Fails {&$augmenter -SourceRoot $sourceRoot -EvidencePath $large.Evidence -LogDirectory $large.Logs -OutputPath $large.Output} 'byte limit' $large.Output

    $badContext=New-Case 'bad-context'; Write-Context $badContext.Logs 'Drive 192.0.2.10'
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $badContext.Evidence -LogDirectory $badContext.Logs -OutputPath $badContext.Output } 'prohibited IP address' $badContext.Output
    $extraContext=New-Case 'extra-context'; $ctx=Get-Content (Join-Path $extraContext.Logs 'benchmark-context.json') -Raw|ConvertFrom-Json; $ctx|Add-Member hostname 'private'; Write-Json (Join-Path $extraContext.Logs 'benchmark-context.json') $ctx
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $extraContext.Evidence -LogDirectory $extraContext.Logs -OutputPath $extraContext.Output } 'must contain exactly' $extraContext.Output
    $duplicateContext=New-Case 'duplicate-context';$p=Join-Path $duplicateContext.Logs 'benchmark-context.json';$t=Get-Content $p -Raw;Write-Utf8 $p ($t.Replace('"schema_version": 1','"schema_version": 1, "schema_version": 1'))
    Assert-Fails {&$augmenter -SourceRoot $sourceRoot -EvidencePath $duplicateContext.Evidence -LogDirectory $duplicateContext.Logs -OutputPath $duplicateContext.Output} 'duplicate fields' $duplicateContext.Output
    foreach ($schemaVersion in '1.0','"1"','true','1.5') {
        $c=New-Case ("context-schema-"+[Guid]::NewGuid().ToString('N'));$p=Join-Path $c.Logs 'benchmark-context.json';$t=Get-Content $p -Raw;Write-Utf8 $p ([regex]::Replace($t,'"schema_version": 1',('"schema_version": '+$schemaVersion),1))
        Assert-Fails {&$augmenter -SourceRoot $sourceRoot -EvidencePath $c.Evidence -LogDirectory $c.Logs -OutputPath $c.Output} 'schema_version must be the JSON integer 1' $c.Output
    }
    $sourceMismatch=New-Case 'evidence-source'; $ev=Get-Content $sourceMismatch.Evidence -Raw|ConvertFrom-Json; $ev.source_sha='a'*40; Write-Json $sourceMismatch.Evidence $ev
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $sourceMismatch.Evidence -LogDirectory $sourceMismatch.Logs -OutputPath $sourceMismatch.Output } 'must match current source HEAD' $sourceMismatch.Output

    $sentinelCase=New-Case 'sentinel'; [byte[]]$sentinel=1,2,3,4; [IO.File]::WriteAllBytes($sentinelCase.Output,$sentinel)
    try { & $augmenter -SourceRoot $sourceRoot -EvidencePath $sentinelCase.Evidence -LogDirectory $sentinelCase.Logs -OutputPath $sentinelCase.Output; throw 'Expected overwrite rejection.' } catch { if($_.Exception.Message -notlike '*already exists*'){throw} }
    if([Convert]::ToHexString($sentinel)-cne[Convert]::ToHexString([IO.File]::ReadAllBytes($sentinelCase.Output))){throw 'Existing output changed.'}

    $reparseBase=New-Case 'reparse'
    $evTarget=Join-Path $testRoot 'evidence-target'; New-Item -ItemType Directory $evTarget|Out-Null; Copy-Item $reparseBase.Evidence (Join-Path $evTarget 'input.json')
    $evLink=Join-Path $testRoot 'evidence-link'; New-DirectoryLink $evLink $evTarget
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath (Join-Path $evLink 'input.json') -LogDirectory $reparseBase.Logs -OutputPath (Join-Path $reparseBase.Root 'ev-link.json') } 'reparse points' (Join-Path $reparseBase.Root 'ev-link.json')
    $logLink=Join-Path $testRoot 'logs-link'; New-DirectoryLink $logLink $reparseBase.Logs
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $reparseBase.Evidence -LogDirectory $logLink -OutputPath (Join-Path $reparseBase.Root 'log-link.json') } 'reparse points' (Join-Path $reparseBase.Root 'log-link.json')
    $outTarget=Join-Path $testRoot 'output-target'; New-Item -ItemType Directory $outTarget|Out-Null
    $outLink=Join-Path $testRoot 'output-link'; New-DirectoryLink $outLink $outTarget
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $reparseBase.Evidence -LogDirectory $reparseBase.Logs -OutputPath (Join-Path $outLink 'output.json') } 'reparse points' (Join-Path $outLink 'output.json')

    $insideEvidenceOutput = Join-Path $reparseBase.Root 'inside-evidence.json'
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath (Join-Path $sourceRoot 'SAFETY.md') -LogDirectory $reparseBase.Logs -OutputPath $insideEvidenceOutput } 'EvidencePath must be outside SourceRoot' $insideEvidenceOutput
    $insideLogsOutput = Join-Path $reparseBase.Root 'inside-logs.json'
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $reparseBase.Evidence -LogDirectory (Join-Path $sourceRoot 'scripts') -OutputPath $insideLogsOutput } 'LogDirectory must be outside SourceRoot' $insideLogsOutput
    $insideOutput = Join-Path $sourceRoot '.stage-followup-inside-output.json'
    if (Test-Path -LiteralPath $insideOutput) { throw "Reserved inside output exists: $insideOutput" }
    Assert-Fails { & $augmenter -SourceRoot $sourceRoot -EvidencePath $reparseBase.Evidence -LogDirectory $reparseBase.Logs -OutputPath $insideOutput } 'OutputPath must be outside SourceRoot' $insideOutput

    Write-Host 'Windows acceptance benchmark augmenter tests passed.'
}
finally {
    for($index=$links.Count-1;$index -ge 0;$index--){$link=$links[$index];if(Test-Path -LiteralPath $link){Remove-Item -LiteralPath $link -Force}}
    if($null -ne $insideOutput -and (Test-Path -LiteralPath $insideOutput -PathType Leaf)){Remove-Item -LiteralPath $insideOutput -Force}
    if(Test-Path $testRoot){Remove-Item $testRoot -Recurse -Force}
}
