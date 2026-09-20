[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BundleRoot,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $ExpectedSessionId,

    [ValidateRange(1, 3600)]
    [int] $TestTimeoutSeconds = 300,

    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string[]] $Names,

        [Parameter(Mandatory)]
        [string] $Label
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if ($actual.Count -ne $expected.Count) {
        throw "$Label has unexpected fields."
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($actual[$index] -cne $expected[$index]) {
            throw "$Label has unexpected fields."
        }
    }
}

function Assert-UniqueJsonProperties {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)][string] $Location
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $observed.Add($property.Name)) {
                throw "$Location contains a duplicate field: $($property.Name)."
            }
            Assert-UniqueJsonProperties -Element $property.Value -Location "$Location.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-UniqueJsonProperties -Element $item -Location "$Location[$index]"
            $index++
        }
    }
}

function Read-UniqueJsonObject {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-OrdinaryFile -Path $Path -Label $Label
    if ((Get-Item -LiteralPath $Path -Force).Length -gt 4MB) {
        throw "$Label is too large."
    }
    $text = Get-Content -LiteralPath $Path -Raw
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($text)
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw "$Label must be a JSON object."
        }
        Assert-UniqueJsonProperties -Element $document.RootElement -Location $Label
        $text | ConvertFrom-Json
    }
    catch {
        throw "$Label is not valid unique-key JSON: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

function Assert-SafeLeafName {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string] $Pattern
    )

    if ($Value -isnot [string] -or
        $Value.Length -gt 160 -or
        $Value -notmatch $Pattern -or
        [IO.Path]::GetFileName($Value) -cne $Value) {
        throw "$Label must be a safe leaf filename."
    }
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory)]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Label
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Label must be a lowercase SHA-256 digest."
    }
}

function Assert-OrdinaryFile {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing."
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a reparse point."
    }
}

function Get-LowerSha256 {
    param([Parameter(Mandatory)][string] $Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-LowerTextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Resolve-VerifiedBundle {
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $InvokedScriptPath
    )

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be an absolute directory.'
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'BundleRoot must be an existing directory.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BundleRoot must not be a reparse point.'
    }
    $resolvedRoot = $rootItem.FullName

    $manifestPath = Join-Path $resolvedRoot 'bundle.json'
    Assert-OrdinaryFile -Path $manifestPath -Label 'bundle.json'
    if ((Get-Item -LiteralPath $manifestPath).Length -gt 1MB) {
        throw 'bundle.json is too large.'
    }
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifestText.IndexOf([char]0) -ge 0) {
        throw 'bundle.json contains NUL.'
    }
    $manifestDocument = $null
    try {
        $manifestDocument = [Text.Json.JsonDocument]::Parse($manifestText)
        Assert-UniqueJsonProperties -Element $manifestDocument.RootElement -Location 'bundle.json'
        $manifest = $manifestText | ConvertFrom-Json
    }
    catch {
        throw "bundle.json is not valid unique-key JSON: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $manifestDocument) {
            $manifestDocument.Dispose()
        }
    }
    if ($null -eq $manifest) {
        throw 'bundle.json must contain an object.'
    }

    $candidateLane = $manifest.schema_version -eq 2
    if ($candidateLane) {
        if ($manifest.schema_version -isnot [int] -and $manifest.schema_version -isnot [long]) {
            throw 'bundle.json candidate schema_version must be the JSON integer 2.'
        }
        Assert-ExactProperties -Value $manifest -Names @(
            'schema_version'
            'lane'
            'target'
            'product'
            'harness'
            'test_binaries'
        ) -Label 'bundle.json'
        if ($manifest.lane -cne 'candidate-gui-only') {
            throw 'bundle.json candidate lane is invalid.'
        }
        Assert-ExactProperties -Value $manifest.product -Names @(
            'source_sha'
            'source_state'
            'candidate'
            'application'
            'provenance'
        ) -Label 'bundle.json product'
        Assert-ExactProperties -Value $manifest.product.candidate -Names @(
            'workflow_run'
            'run_attempt'
            'artifact_id'
            'artifact_name'
            'origin_authentication'
        ) -Label 'bundle.json product candidate'
        Assert-ExactProperties -Value $manifest.product.provenance -Names @(
            'release_handoff'
            'run_metadata'
            'artifact_metadata'
        ) -Label 'bundle.json product provenance'
        Assert-ExactProperties -Value $manifest.harness -Names @(
            'source_sha'
            'source_state'
            'launcher'
            'controller'
            'runner'
            'observers'
            'validators'
        ) -Label 'bundle.json harness'
        Assert-ExactProperties -Value $manifest.harness.observers -Names @(
            'ui'
            'recovery'
        ) -Label 'bundle.json harness observers'
        Assert-ExactProperties -Value $manifest.harness.validators -Names @(
            'release_handoff'
            'candidate_metadata'
            'binary_measurement'
        ) -Label 'bundle.json harness validators'
        foreach ($binding in @($manifest.product, $manifest.harness)) {
            if ($binding.source_sha -isnot [string] -or $binding.source_sha -cnotmatch '^[0-9a-f]{40}$' -or
                $binding.source_state -cne 'clean') {
                throw 'bundle.json source binding is invalid.'
            }
        }
        foreach ($name in @('workflow_run', 'run_attempt', 'artifact_id')) {
            if ($manifest.product.candidate.$name -isnot [string] -or
                $manifest.product.candidate.$name -cnotmatch '^[1-9][0-9]*$') {
                throw "bundle.json product candidate $name is invalid."
            }
        }
        $expectedArtifactName = "DarkReNamer-dry-run-$($manifest.product.candidate.workflow_run)-$($manifest.product.candidate.run_attempt)-windows"
        if ($manifest.product.candidate.artifact_name -cne $expectedArtifactName) {
            throw 'bundle.json product candidate artifact name is invalid.'
        }
        if ($manifest.product.candidate.origin_authentication -cne 'pending-hosted') {
            throw 'bundle.json product candidate origin authentication scope is invalid.'
        }
        if (@($manifest.test_binaries).Count -ne 0) {
            throw 'bundle.json candidate GUI-only lane must not contain test binaries.'
        }
        $application = $manifest.product.application
        $runner = $manifest.harness.runner
        $testBinaryRows = @()
        $candidateArtifacts = @(
            @($manifest.product.provenance.PSObject.Properties | ForEach-Object Value) +
            @($manifest.harness.launcher, $manifest.harness.controller) +
            @($manifest.harness.observers.PSObject.Properties | ForEach-Object Value) +
            @($manifest.harness.validators.PSObject.Properties | ForEach-Object Value)
        )
    }
    else {
        Assert-ExactProperties -Value $manifest -Names @(
            'schema_version'
            'source_sha'
            'source_state'
            'target'
            'cargo_lock_sha256'
            'test_binaries'
            'application'
            'runner'
        ) -Label 'bundle.json'
        if (($manifest.schema_version -isnot [int] -and $manifest.schema_version -isnot [long]) -or
            $manifest.schema_version -ne 1) {
            throw 'bundle.json schema_version must be 1 or the exact candidate schema 2.'
        }
        if ($manifest.source_sha -isnot [string] -or $manifest.source_sha -cnotmatch '^[0-9a-f]{40}$') {
            throw 'bundle.json source_sha must be a lowercase full Git SHA.'
        }
        if ($manifest.source_state -isnot [string] -or
            $manifest.source_state -cne 'clean' -and $manifest.source_state -cne 'dirty') {
            throw 'bundle.json source_state is invalid.'
        }
        Assert-Sha256 -Value $manifest.cargo_lock_sha256 -Label 'bundle.json cargo_lock_sha256'
        if ($manifest.test_binaries -isnot [array] -or $manifest.test_binaries.Count -le 0) {
            throw 'bundle.json test_binaries must be a non-empty array.'
        }
        $application = $manifest.application
        $runner = $manifest.runner
        $testBinaryRows = @($manifest.test_binaries)
        $candidateArtifacts = @()
    }
    if ($manifest.target -isnot [string] -or $manifest.target -cne 'x86_64-pc-windows-msvc') {
        throw 'bundle.json target is invalid.'
    }
    Assert-ExactProperties -Value $application -Names @('file', 'sha256') -Label 'bundle.json application'
    Assert-ExactProperties -Value $runner -Names @('file', 'sha256') -Label 'bundle.json runner'
    Assert-SafeLeafName -Value $application.file -Label 'application file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.exe$'
    if ($application.file -cne 'DarkReNamer.exe') {
        throw 'bundle.json application file is invalid.'
    }
    Assert-Sha256 -Value $application.sha256 -Label 'application sha256'
    Assert-SafeLeafName -Value $runner.file -Label 'runner file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.ps1$'
    if ($runner.file -cne 'windows-vm-guest.ps1') {
        throw 'bundle.json runner file is invalid.'
    }
    Assert-Sha256 -Value $runner.sha256 -Label 'runner sha256'

    $leafNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $testNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $artifacts = [Collections.Generic.List[object]]::new()
    $testRows = [Collections.Generic.List[object]]::new()
    foreach ($binary in @($testBinaryRows)) {
        Assert-ExactProperties -Value $binary -Names @('name', 'file', 'sha256') -Label 'bundle.json test binary'
        if ($binary.name -isnot [string] -or $binary.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            throw 'A test binary name is invalid.'
        }
        if (-not $testNames.Add($binary.name)) {
            throw 'Test binary names must be unique.'
        }
        Assert-SafeLeafName -Value $binary.file -Label 'test binary file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.exe$'
        Assert-Sha256 -Value $binary.sha256 -Label 'test binary sha256'
        if (-not $leafNames.Add($binary.file)) {
            throw 'Artifact filenames must be unique.'
        }
        $testRows.Add([pscustomobject]@{
            name = $binary.name
            file = $binary.file
            sha256 = $binary.sha256
        })
        $artifacts.Add([pscustomobject]@{
            label = 'test binary'
            file = $binary.file
            sha256 = $binary.sha256
        })
    }
    foreach ($artifact in @($application, $runner) + $candidateArtifacts) {
        Assert-ExactProperties -Value $artifact -Names @('file', 'sha256') -Label 'bundle.json artifact'
        Assert-SafeLeafName -Value $artifact.file -Label 'artifact file' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*$'
        Assert-Sha256 -Value $artifact.sha256 -Label 'artifact sha256'
        if (-not $leafNames.Add($artifact.file)) {
            throw 'Artifact filenames must be unique.'
        }
        $artifacts.Add([pscustomobject]@{
            label = 'manifest artifact'
            file = $artifact.file
            sha256 = $artifact.sha256
        })
    }

    $runnerPath = Join-Path $resolvedRoot $runner.file
    Assert-OrdinaryFile -Path $runnerPath -Label 'runner artifact'
    $actualScriptPath = (Get-Item -LiteralPath $InvokedScriptPath -Force).FullName
    if (-not [string]::Equals($runnerPath, $actualScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The invoked runner is not the bundled runner artifact.'
    }

    $verifiedHashes = @{}
    foreach ($artifact in $artifacts) {
        $artifactPath = Join-Path $resolvedRoot $artifact.file
        Assert-OrdinaryFile -Path $artifactPath -Label $artifact.label
        $actualHash = Get-LowerSha256 -Path $artifactPath
        if ($actualHash -cne $artifact.sha256) {
            throw "$($artifact.label) hash mismatch."
        }
        $verifiedHashes[$artifact.file] = $actualHash
    }

    if ($candidateLane) {
        $expectedFiles = [ordered]@{
            release_handoff = 'release-handoff.json'
            run_metadata = 'candidate-run.json'
            artifact_metadata = 'candidate-artifact.json'
        }
        foreach ($name in $expectedFiles.Keys) {
            if ($manifest.product.provenance.$name.file -cne $expectedFiles[$name]) {
                throw "bundle.json product provenance $name file is invalid."
            }
        }
        if ($manifest.harness.launcher.file -cne 'test-windows-vm.py' -or
            $manifest.harness.controller.file -cne 'run-windows-vm-tests.ps1') {
            throw 'bundle.json candidate harness filenames are invalid.'
        }
        $expectedObservers = [ordered]@{
            ui = 'windows-vm-acceptance.ps1'
            recovery = 'windows-vm-recovery-acceptance.ps1'
        }
        foreach ($name in $expectedObservers.Keys) {
            if ($manifest.harness.observers.$name.file -cne $expectedObservers[$name]) {
                throw "bundle.json candidate harness observer $name file is invalid."
            }
        }
        $expectedValidators = [ordered]@{
            release_handoff = 'validate-release-handoff.ps1'
            candidate_metadata = 'validate-release-candidate-metadata.ps1'
            binary_measurement = 'measure-windows-binary.ps1'
        }
        foreach ($name in $expectedValidators.Keys) {
            if ($manifest.harness.validators.$name.file -cne $expectedValidators[$name]) {
                throw "bundle.json candidate harness validator $name file is invalid."
            }
        }
        $handoff = Read-UniqueJsonObject `
            -Path (Join-Path $resolvedRoot 'release-handoff.json') `
            -Label 'release-handoff.json'
        if ($handoff.source_sha -cne $manifest.product.source_sha -or
            $handoff.workflow_run -cne $manifest.product.candidate.workflow_run -or
            $handoff.executable.filename -cne $application.file -or
            $handoff.executable.sha256 -cne $application.sha256) {
            throw 'Frozen release handoff metadata differs from the candidate identity.'
        }
        $runMetadata = Read-UniqueJsonObject `
            -Path (Join-Path $resolvedRoot 'candidate-run.json') `
            -Label 'candidate-run.json'
        $artifactMetadata = Read-UniqueJsonObject `
            -Path (Join-Path $resolvedRoot 'candidate-artifact.json') `
            -Label 'candidate-artifact.json'
        if ([string]$runMetadata.id -cne $manifest.product.candidate.workflow_run -or
            [string]$runMetadata.run_attempt -cne $manifest.product.candidate.run_attempt -or
            $runMetadata.head_sha -cne $manifest.product.source_sha -or
            [string]$artifactMetadata.id -cne $manifest.product.candidate.artifact_id -or
            $artifactMetadata.name -cne $manifest.product.candidate.artifact_name -or
            [string]$artifactMetadata.workflow_run.id -cne $manifest.product.candidate.workflow_run -or
            $artifactMetadata.workflow_run.head_sha -cne $manifest.product.source_sha) {
            throw 'Frozen GitHub metadata differs from the candidate identity.'
        }
    }

    $contract = if ($candidateLane) {
        [pscustomobject]@{
            lane = 'candidate-gui-only'
            product_source_sha = $manifest.product.source_sha
            product_source_state = $manifest.product.source_state
            application = $application
            harness_source_sha = $manifest.harness.source_sha
            harness_source_state = $manifest.harness.source_state
            runner = $runner
            observers = $manifest.harness.observers
            validators = $manifest.harness.validators
        }
    } else {
        [pscustomobject]@{
            lane = 'source-built-native'
            product_source_sha = $manifest.source_sha
            product_source_state = $manifest.source_state
            application = $application
            harness_source_sha = $manifest.source_sha
            harness_source_state = $manifest.source_state
            runner = $runner
            observers = $null
            validators = $null
        }
    }
    [pscustomobject]@{
        root = $resolvedRoot
        manifest = $manifest
        contract = $contract
        tests = $testRows.ToArray()
        hashes = $verifiedHashes
    }
}

function Read-RustTestSummary {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Stdout,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Stderr,

        [switch] $AllowZeroTests
    )

    $pattern = '(?m)^test result: (ok|FAILED)\. ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored; ([0-9]+) measured; ([0-9]+) filtered out;(?:[^\r\n]*)\r?$'
    $matches = [regex]::Matches($Stdout, $pattern)
    if ($matches.Count -eq 0) {
        throw 'Rust test stdout must contain a test result summary.'
    }
    $summary = $matches[$matches.Count - 1]
    $passed = [int]::Parse($summary.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    $failed = [int]::Parse($summary.Groups[3].Value, [Globalization.CultureInfo]::InvariantCulture)
    $ignored = [int]::Parse($summary.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture)
    $filtered = [int]::Parse($summary.Groups[6].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($filtered -ne 0) {
        throw 'The final Rust test harness must not filter tests.'
    }
    if (-not $AllowZeroTests -and ($passed + $failed + $ignored) -eq 0) {
        throw 'A non-main Rust test harness reported zero tests.'
    }

    [pscustomobject]@{
        outcome = $summary.Groups[1].Value
        passed = $passed
        failed = $failed
        ignored = $ignored
        filtered = $filtered
    }
}

function New-PrivateDirectory {
    param(
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Leaf
    )

    $path = Join-Path $Parent $Leaf
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'A runtime directory is unsafe.'
        }
    }
    else {
        [void](New-Item -ItemType Directory -Path $path)
    }
    $path
}

function Invoke-TaskkillTree {
    param([Parameter(Mandatory)][int] $ProcessId)

    & "$env:SystemRoot\System32\taskkill.exe" /PID $ProcessId /T /F 2>$null | Out-Null
}

function Invoke-WithIsolatedEnvironment {
    param(
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][scriptblock] $Action
    )

    $temporary = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'temp'
    $localAppData = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'localappdata'
    $names = @('TEMP', 'TMP', 'LOCALAPPDATA', 'DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES')
    $original = @{}
    foreach ($name in $names) {
        $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        [Environment]::SetEnvironmentVariable('TEMP', $temporary, 'Process')
        [Environment]::SetEnvironmentVariable('TMP', $temporary, 'Process')
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData, 'Process')
        [Environment]::SetEnvironmentVariable('DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES', '1', 'Process')
        & $Action
    }
    finally {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
        }
    }
}

function Start-OwnedProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Arguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [switch] $RedirectOutput
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.WorkingDirectory = $WorkingDirectory
    # Shell activation gives the GUI the same startup behavior as a user launch.
    # Test harnesses use direct creation so stdout and stderr stay redirected.
    $startInfo.UseShellExecute = -not $RedirectOutput
    $startInfo.CreateNoWindow = $RedirectOutput
    $startInfo.RedirectStandardOutput = $RedirectOutput
    $startInfo.RedirectStandardError = $RedirectOutput
    if ($RedirectOutput) {
        $encoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardOutputEncoding = $encoding
        $startInfo.StandardErrorEncoding = $encoding
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Process start returned false.'
        }
        [void]$process.Handle
        [pscustomobject]@{
            process = $process
            stdout_task = if ($RedirectOutput) { $process.StandardOutput.ReadToEndAsync() } else { $null }
            stderr_task = if ($RedirectOutput) { $process.StandardError.ReadToEndAsync() } else { $null }
            output_saved = $false
        }
    }
    catch {
        $process.Dispose()
        throw
    }
}

function Save-CapturedProcessOutput {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][string] $StdoutPath,
        [Parameter(Mandatory)][string] $StderrPath
    )

    if ($State.output_saved -or $null -eq $State.stdout_task -or $null -eq $State.stderr_task) {
        return
    }
    $stdoutText = $State.stdout_task.GetAwaiter().GetResult()
    $stderrText = $State.stderr_task.GetAwaiter().GetResult()
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($StdoutPath, $stdoutText, $encoding)
    [IO.File]::WriteAllText($StderrPath, $stderrText, $encoding)
    $State.output_saved = $true
}

function Invoke-RustTestBinary {
    param(
        [Parameter(Mandatory)][object] $Test,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][int] $Index,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $stdoutLeaf = 'test-{0:D3}.stdout.txt' -f $Index
    $stderrLeaf = 'test-{0:D3}.stderr.txt' -f $Index
    $stdoutPath = Join-Path $Root $stdoutLeaf
    $stderrPath = Join-Path $Root $stderrLeaf
    [IO.File]::WriteAllBytes($stdoutPath, [byte[]]@())
    [IO.File]::WriteAllBytes($stderrPath, [byte[]]@())
    $binaryPath = Join-Path $Root $Test.file
    $row = [ordered]@{
        file = $Test.file
        sha256 = $Test.sha256
        status = 'failed'
        exit_code = $null
        passed = $null
        failed = $null
        ignored = $null
        stdout = $null
        stderr = $null
        failure_reason = 'process_start_failed'
    }
    $processState = [pscustomobject]@{ process = $null }
    try {
        Assert-OrdinaryFile -Path $binaryPath -Label 'test binary'
        if ((Get-LowerSha256 -Path $binaryPath) -cne $Test.sha256) {
            $row.failure_reason = 'artifact_changed_after_preflight'
            return [pscustomobject]$row
        }
        $caseRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf ('test-{0:D3}' -f $Index)
        Invoke-WithIsolatedEnvironment -RuntimeRoot $caseRoot -Action {
            $ownedProcess = Start-OwnedProcess `
                -FilePath $binaryPath `
                -Arguments '--nocapture --test-threads=1' `
                -WorkingDirectory $Root `
                -RedirectOutput
            $processState.process = $ownedProcess
            $waitMilliseconds = [int]([Math]::Min([int]::MaxValue, $TimeoutSeconds * 1000L))
            $timedOut = -not $processState.process.process.WaitForExit($waitMilliseconds)
            if ($timedOut) {
                $row.failure_reason = 'timeout'
                Invoke-TaskkillTree -ProcessId $processState.process.process.Id
                if (-not $processState.process.process.WaitForExit(10000)) {
                    throw 'Timed-out test process did not terminate.'
                }
            }
            $processState.process.process.WaitForExit()
            Save-CapturedProcessOutput `
                -State $processState.process `
                -StdoutPath $stdoutPath `
                -StderrPath $stderrPath
            if ($timedOut) {
                return
            }
            $row.exit_code = $processState.process.process.ExitCode
            $stdoutText = [IO.File]::ReadAllText($stdoutPath)
            $stderrText = [IO.File]::ReadAllText($stderrPath)
            try {
                $summary = Read-RustTestSummary `
                    -Stdout $stdoutText `
                    -Stderr $stderrText `
                    -AllowZeroTests:($Test.name -ceq 'DarkReNamer')
                $row.passed = $summary.passed
                $row.failed = $summary.failed
                $row.ignored = $summary.ignored
                if ($processState.process.process.ExitCode -eq 0 -and
                    $summary.outcome -ceq 'ok' -and
                    $summary.failed -eq 0) {
                    $row.status = 'passed'
                    $row.failure_reason = $null
                }
                else {
                    $row.failure_reason = 'test_failed'
                }
            }
            catch {
                $row.failure_reason = 'invalid_test_summary'
            }
        }
    }
    catch {
        $row.failure_reason = 'process_error'
    }
    finally {
        if ($null -ne $processState.process) {
            try {
                $processState.process.process.Refresh()
                if (-not $processState.process.process.HasExited) {
                    Invoke-TaskkillTree -ProcessId $processState.process.process.Id
                    if (-not $processState.process.process.WaitForExit(10000)) {
                        throw 'Owned test process did not terminate.'
                    }
                }
                Save-CapturedProcessOutput `
                    -State $processState.process `
                    -StdoutPath $stdoutPath `
                    -StderrPath $stderrPath
            }
            catch {
                $row.status = 'failed'
                $row.failure_reason = 'process_cleanup_failed'
            }
            $processState.process.process.Dispose()
        }
        $row.stdout = [ordered]@{
            file = $stdoutLeaf
            sha256 = Get-LowerSha256 -Path $stdoutPath
        }
        $row.stderr = [ordered]@{
            file = $stderrLeaf
            sha256 = Get-LowerSha256 -Path $stderrPath
        }
    }
    [pscustomobject]$row
}

function Initialize-NativeCapture {
    if (-not ('DarkReNamerVmNative' -as [type])) {
        Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DarkReNamerVmNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }

    public sealed class WindowMeasurement {
        public long Handle;
        public long Owner;
        public uint ProcessId;
        public string ClassName;
        public string Title;
        public bool Visible;
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo {
        public uint Size;
        public Rect Monitor;
        public Rect Work;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HighContrast {
        public uint Size;
        public uint Flags;
        public IntPtr DefaultScheme;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileId128 {
        public ulong LowPart;
        public ulong HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInfo {
        public ulong VolumeSerialNumber;
        public FileId128 FileId;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo information);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HighContrast value, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SwitchDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseDesktop(IntPtr desktop);

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string path, uint access, uint share, IntPtr securityAttributes,
        uint creationDisposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        IntPtr file, out ByHandleFileInformation information);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(
        IntPtr file, int informationClass, out FileIdInfo information, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr token, int informationClass, out int information, uint length, out uint returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static string GetFileIdentity(string path) {
        IntPtr file = CreateFile(path, 0x80, 1 | 2 | 4, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
        if (file == new IntPtr(-1)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(file, out information)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            ulong index = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
            return information.VolumeSerialNumber.ToString("x8") + ":" + index.ToString("x16");
        }
        finally {
            CloseHandle(file);
        }
    }

    public static WindowMeasurement[] ReadProcessTopLevelWindows(uint expectedProcessId) {
        List<WindowMeasurement> windows = new List<WindowMeasurement>();
        bool exceededBound = false;
        bool completed = EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != expectedProcessId) return true;
            if (windows.Count >= 128) {
                exceededBound = true;
                return false;
            }
            Rect rect;
            if (!GetWindowRect(window, out rect)) rect = new Rect();
            System.Text.StringBuilder className = new System.Text.StringBuilder(128);
            System.Text.StringBuilder title = new System.Text.StringBuilder(1024);
            GetClassName(window, className, className.Capacity);
            GetWindowTextW(window, title, title.Capacity);
            windows.Add(new WindowMeasurement {
                Handle = window.ToInt64(),
                Owner = GetWindow(window, 4).ToInt64(),
                ProcessId = processId,
                ClassName = className.ToString(),
                Title = title.ToString(),
                Visible = IsWindowVisible(window),
                Left = rect.Left,
                Top = rect.Top,
                Right = rect.Right,
                Bottom = rect.Bottom
            });
            return true;
        }, IntPtr.Zero);
        if (exceededBound) {
            throw new InvalidOperationException("Process window inventory exceeded its bound.");
        }
        if (!completed) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        return windows.ToArray();
    }

    public static void RequestWindowClose(IntPtr window) {
        if (!PostMessageW(window, 0x0010, IntPtr.Zero, IntPtr.Zero)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static string[] GetFullFileIdentity(string path) {
        IntPtr file = CreateFile(path, 0x80, 1 | 2 | 4, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (file == new IntPtr(-1)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            FileIdInfo information;
            if (!GetFileInformationByHandleEx(
                    file, 18, out information, (uint)Marshal.SizeOf(typeof(FileIdInfo)))) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            return new string[] {
                information.VolumeSerialNumber.ToString("x16"),
                FormatFileIdNumeric(information.FileId.LowPart, information.FileId.HighPart)
            };
        }
        finally {
            CloseHandle(file);
        }
    }

    public static string FormatFileIdNumeric(ulong lowPart, ulong highPart) {
        // FILE_ID_128 stores the little-endian bytes of the product's u128.
        // Render the numeric value so this matches u128::from_le_bytes.
        return highPart.ToString("x16") + lowPart.ToString("x16");
    }

    public static int[] ReadMonitorInfo(IntPtr window) {
        IntPtr monitor = MonitorFromWindow(window, 2);
        if (monitor == IntPtr.Zero) {
            throw new InvalidOperationException("MonitorFromWindow returned no target monitor.");
        }
        MonitorInfo information = new MonitorInfo();
        information.Size = (uint)Marshal.SizeOf(typeof(MonitorInfo));
        if (!GetMonitorInfoW(monitor, ref information)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        return new int[] {
            information.Monitor.Left, information.Monitor.Top,
            information.Monitor.Right, information.Monitor.Bottom,
            information.Work.Left, information.Work.Top,
            information.Work.Right, information.Work.Bottom
        };
    }

    public static uint GetHighContrastFlags() {
        HighContrast value = new HighContrast();
        value.Size = (uint)Marshal.SizeOf(typeof(HighContrast));
        if (!SystemParametersInfo(0x42, value.Size, ref value, 0)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        return value.Flags;
    }

    public static bool InputDesktopAvailable() {
        IntPtr desktop = OpenInputDesktop(0, false, 0x0100);
        if (desktop == IntPtr.Zero) return false;
        try { return SwitchDesktop(desktop); }
        finally { CloseDesktop(desktop); }
    }

    public static bool IsProcessElevated(uint processId) {
        IntPtr process = OpenProcess(0x1000, false, processId);
        if (process == IntPtr.Zero) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            IntPtr token;
            if (!OpenProcessToken(process, 0x0008, out token)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            try {
                int elevation;
                uint returned;
                if (!GetTokenInformation(token, 20, out elevation, 4, out returned) || returned != 4) {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
                return elevation != 0;
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }
}
'@
    }
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName UIAutomationClientsideProviders
    if (-not ('DarkReNamerVmAutomation' -as [type])) {
        $automationReferences = @(
            [Windows.Automation.AutomationElement].Assembly.Location
            [Windows.Automation.AutomationProperty].Assembly.Location
            [UIAutomationClientsideProviders.UIAutomationClientSideProviders].Assembly.Location
        )
        Add-Type -ReferencedAssemblies $automationReferences -TypeDefinition @'
public static class DarkReNamerVmAutomation {
    // UIA's default-proxy stack walk cannot inspect PowerShell dynamic frames.
    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    public static void Initialize() {
        var providerType = typeof(UIAutomationClientsideProviders.UIAutomationClientSideProviders);
        var providerName = providerType.Assembly.GetName();
        // .NET 8 changed the assembly name's Side casing while the namespace stayed stable.
        providerName.Name = providerType.Namespace;
        System.Windows.Automation.ClientSettings.RegisterClientSideProviderAssembly(providerName);
    }
}
'@
    }
    [DarkReNamerVmAutomation]::Initialize()
}

function Get-VmAutomatedCanonicalRootPath {
    param([Parameter(Mandatory)][string] $Path)

    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw 'VM-Automated fixture root must be drive-absolute.'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'VM-Automated fixture root must be an ordinary directory.'
    }
    $full = $item.FullName
    $ordinaryDrive = $full -cmatch '^[A-Za-z]:\\.'
    $verbatimDrive = $full -cmatch '^\\\\\?\\[A-Za-z]:\\.'
    if ((-not $ordinaryDrive -and -not $verbatimDrive) -or
        $full.StartsWith('\\\\.\\', [StringComparison]::Ordinal) -or
        $full -cmatch '^\\\\(?!\?\\)') {
        throw 'VM-Automated fixture root must use a canonical local drive path.'
    }
    $relative = if ($verbatimDrive) { $full.Substring(7) } else { $full.Substring(3) }
    $components = @($relative.Split([char]92))
    if ([string]::IsNullOrEmpty($relative) -or $components -contains '' -or
        @($components | Where-Object {
            $_ -in @('.', '..') -or $_.EndsWith('.', [StringComparison]::Ordinal) -or
            $_.EndsWith(' ', [StringComparison]::Ordinal) -or
            $_.IndexOfAny([char[]]'<>:"/|?*') -ge 0 -or
            $_.Split('.')[0] -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
        }).Count -ne 0) {
        throw 'VM-Automated fixture root must not be a drive root or contain dot segments.'
    }
    $full
}

function Get-FullFileIdentity {
    param([Parameter(Mandatory)][string] $Path)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'FILE_ID_INFO observation requires Windows.'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (-not $item.PSIsContainer -and $item -isnot [IO.FileInfo])) {
        throw 'FILE_ID_INFO observation requires an ordinary file or directory.'
    }
    Initialize-NativeCapture
    $identity = [DarkReNamerVmNative]::GetFullFileIdentity($item.FullName)
    if ($identity.Count -ne 2 -or
        $identity[0] -cnotmatch '^[0-9a-f]{16}$' -or
        $identity[1] -cnotmatch '^[0-9a-f]{32}$') {
        throw 'FILE_ID_INFO observation returned a malformed identity.'
    }
    [ordered]@{
        volume_serial = $identity[0]
        file_id = $identity[1]
    }
}

function Initialize-TextScaleNative {
    if ('DarkReNamerTextScaleNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DarkReNamerTextScaleNative {
    private const int RpcChangedMode = unchecked((int)0x80010106);
    private const uint RoInitMultithreaded = 1;
    private static readonly Guid IidUiSettings2 = new Guid("bad82401-2721-44f9-bb91-2bb228be442f");

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int QueryInterfaceDelegate(IntPtr instance, ref Guid iid, out IntPtr value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate uint ReleaseDelegate(IntPtr instance);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int TextScaleFactorDelegate(IntPtr instance, out double value);

    [DllImport("combase.dll")]
    private static extern int RoInitialize(uint initType);
    [DllImport("combase.dll")]
    private static extern void RoUninitialize();
    [DllImport("combase.dll", CharSet=CharSet.Unicode)]
    private static extern int WindowsCreateString(string source, uint length, out IntPtr value);
    [DllImport("combase.dll")]
    private static extern int WindowsDeleteString(IntPtr value);
    [DllImport("combase.dll")]
    private static extern int RoActivateInstance(IntPtr classId, out IntPtr instance);

    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr SendMessageTimeoutW(
        IntPtr window, uint message, UIntPtr wParam, string lParam,
        uint flags, uint timeout, out UIntPtr result);

    private static IntPtr ReadVtableMethod(IntPtr instance, int slot) {
        if (instance == IntPtr.Zero) {
            throw new ArgumentException("A COM interface pointer is required.", "instance");
        }
        return Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), slot * IntPtr.Size);
    }

    private static void Release(ref IntPtr instance) {
        if (instance == IntPtr.Zero) { return; }
        var release = (ReleaseDelegate)Marshal.GetDelegateForFunctionPointer(
            ReadVtableMethod(instance, 2), typeof(ReleaseDelegate));
        release(instance);
        instance = IntPtr.Zero;
    }

    public static double ReadTextScaleFactor() {
        int initializeResult = RoInitialize(RoInitMultithreaded);
        bool uninitialize = initializeResult >= 0;
        if (initializeResult < 0 && initializeResult != RpcChangedMode) {
            Marshal.ThrowExceptionForHR(initializeResult);
        }

        IntPtr classId = IntPtr.Zero;
        IntPtr instance = IntPtr.Zero;
        IntPtr settings2 = IntPtr.Zero;
        try {
            const string runtimeClass = "Windows.UI.ViewManagement.UISettings";
            int result = WindowsCreateString(runtimeClass, (uint)runtimeClass.Length, out classId);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }
            result = RoActivateInstance(classId, out instance);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }

            var query = (QueryInterfaceDelegate)Marshal.GetDelegateForFunctionPointer(
                ReadVtableMethod(instance, 0), typeof(QueryInterfaceDelegate));
            Guid iid = IidUiSettings2;
            result = query(instance, ref iid, out settings2);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }

            var read = (TextScaleFactorDelegate)Marshal.GetDelegateForFunctionPointer(
                ReadVtableMethod(settings2, 6), typeof(TextScaleFactorDelegate));
            double value;
            result = read(settings2, out value);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }
            return value;
        }
        finally {
            Release(ref settings2);
            Release(ref instance);
            if (classId != IntPtr.Zero) { WindowsDeleteString(classId); }
            if (uninitialize) { RoUninitialize(); }
        }
    }

    public static void NotifyAccessibilitySettingChange() {
        UIntPtr result;
        SendMessageTimeoutW(
            new IntPtr(0xffff), 0x001A, UIntPtr.Zero, "Accessibility",
            0x0002, 5000, out result);
    }
}
'@
}

function Get-VmAutomatedEnvironment {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][IntPtr] $WindowHandle,
        [Parameter(Mandatory)][string] $FixtureRoot
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'VM-Automated environment observation requires Windows.'
    }
    Initialize-NativeCapture
    $rootPath = Get-VmAutomatedCanonicalRootPath -Path $FixtureRoot
    $Process.Refresh()
    if ($Process.HasExited -or $WindowHandle -eq [IntPtr]::Zero -or
        -not [DarkReNamerVmNative]::IsWindow($WindowHandle)) {
        throw 'VM-Automated environment requires a live candidate window.'
    }
    $windowProcessId = [uint32]0
    if ([DarkReNamerVmNative]::GetWindowThreadProcessId(
            $WindowHandle,
            [ref]$windowProcessId
        ) -eq 0 -or $windowProcessId -ne $Process.Id) {
        throw 'VM-Automated target window is outside the candidate process.'
    }
    $windowRect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($WindowHandle, [ref]$windowRect)) {
        throw 'VM-Automated target window bounds are unavailable.'
    }
    $monitor = [DarkReNamerVmNative]::ReadMonitorInfo($WindowHandle)
    $dpi = [int][DarkReNamerVmNative]::GetDpiForWindow($WindowHandle)
    if ($dpi -le 0) { throw 'VM-Automated target window DPI is unavailable.' }
    $version = Get-ItemProperty `
        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
        -ErrorAction Stop
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $drivePath = if ($rootPath.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        $rootPath.Substring(4)
    } else { $rootPath }
    $drive = [IO.DriveInfo]::new($drivePath.Substring(0, 3))
    Initialize-TextScaleNative
    $textScaleFactor = [double][DarkReNamerTextScaleNative]::ReadTextScaleFactor()
    if ([double]::IsNaN($textScaleFactor) -or [double]::IsInfinity($textScaleFactor) -or
        $textScaleFactor -lt 1.0 -or $textScaleFactor -gt 2.25) {
        throw 'VM-Automated actual UISettings text scale is unavailable or invalid.'
    }
    $textScale = [int][Math]::Round($textScaleFactor * 100)
    $desktopAvailable = [bool][DarkReNamerVmNative]::InputDesktopAvailable()
    [ordered]@{
        schema_version = 1
        platform = [ordered]@{
            os_product_name = [string]$version.ProductName
            display_version = [string]$version.DisplayVersion
            build_number = [int]$version.CurrentBuildNumber
            product_type = [int]$operatingSystem.ProductType
            architecture = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq
                [Runtime.InteropServices.Architecture]::X64) { 'x86_64' } else {
                [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
            }
        }
        process = [ordered]@{
            pid = [int]$Process.Id
            session_id = [int]$Process.SessionId
            is_elevated = [bool][DarkReNamerVmNative]::IsProcessElevated([uint32]$Process.Id)
        }
        desktop = [ordered]@{
            input_desktop_active = $desktopAvailable
            locked = -not $desktopAvailable
        }
        fixture_volume = [ordered]@{
            filesystem = [string]$drive.DriveFormat
            root_path = $rootPath
            root_identity = Get-FullFileIdentity -Path $rootPath
        }
        target_display = [ordered]@{
            hwnd = [long]$WindowHandle
            process_id = [int]$windowProcessId
            session_id = [int]$Process.SessionId
            dpi_x = $dpi
            dpi_y = $dpi
            monitor_rect = [ordered]@{
                left = $monitor[0]; top = $monitor[1]
                right = $monitor[2]; bottom = $monitor[3]
            }
            work_rect = [ordered]@{
                left = $monitor[4]; top = $monitor[5]
                right = $monitor[6]; bottom = $monitor[7]
            }
            window_rect = [ordered]@{
                left = $windowRect.Left; top = $windowRect.Top
                right = $windowRect.Right; bottom = $windowRect.Bottom
            }
            text_scale_percent = [int]$textScale
            high_contrast_flags = [long][DarkReNamerVmNative]::GetHighContrastFlags()
        }
    }
}

function Assert-AutomationBinding {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Label,
        [switch] $RequireWindowHandle
    )

    if ($Element.Current.ProcessId -ne $Process.Id -or $Process.SessionId -ne $ExpectedSession) {
        throw "$Label is not bound to the expected process and desktop session."
    }
    $nativeHandle = [IntPtr]$Element.Current.NativeWindowHandle
    if ($RequireWindowHandle) {
        if ($nativeHandle -eq [IntPtr]::Zero -or -not [DarkReNamerVmNative]::IsWindow($nativeHandle)) {
            throw "$Label does not expose one live native control."
        }
        $boundProcessId = [uint32]0
        [void][DarkReNamerVmNative]::GetWindowThreadProcessId($nativeHandle, [ref]$boundProcessId)
        if ($boundProcessId -ne $Process.Id) {
            throw "$Label native control belongs to another process."
        }
    }
}

function Resolve-ExactApplicationMainWindowCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Windows,
        [Parameter(Mandatory)][int] $ExpectedProcessId,
        [Parameter(Mandatory)][string] $ExpectedClassName,
        [Parameter(Mandatory)][string] $ExpectedTitle
    )

    $matches = @($Windows | Where-Object {
        [long]$_.Handle -gt 0 -and
        [long]$_.Owner -eq 0 -and
        [int]$_.ProcessId -eq $ExpectedProcessId -and
        [string]$_.ClassName -ceq $ExpectedClassName -and
        [string]$_.Title -ceq $ExpectedTitle -and
        [bool]$_.Visible -and
        [int]$_.Right -gt [int]$_.Left -and
        [int]$_.Bottom -gt [int]$_.Top -and
        ([long]$_.Right - [long]$_.Left) -le 32768L -and
        ([long]$_.Bottom - [long]$_.Top) -le 32768L -and
        (([long]$_.Right - [long]$_.Left) *
            ([long]$_.Bottom - [long]$_.Top)) -le 100000000L
    })
    if ($matches.Count -gt 1) {
        throw 'Application main window matched more than one exact native window.'
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}

function Assert-ExactApplicationMainWindowBinding {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][string] $ExpectedClassName,
        [Parameter(Mandatory)][string] $ExpectedTitle,
        [Parameter(Mandatory)][string] $Label
    )

    $Process.Refresh()
    if ($Process.HasExited -or $Process.SessionId -ne $ExpectedSession -or
        $MainWindowHandle -eq [IntPtr]::Zero) {
        throw "$Label is not bound to the expected process and desktop session."
    }
    $native = Resolve-ExactApplicationMainWindowCandidate `
        -Windows @([DarkReNamerVmNative]::ReadProcessTopLevelWindows([uint32]$Process.Id)) `
        -ExpectedProcessId $Process.Id `
        -ExpectedClassName $ExpectedClassName `
        -ExpectedTitle $ExpectedTitle
    if ($null -eq $native -or [long]$native.Handle -ne $MainWindowHandle.ToInt64()) {
        throw "$Label does not retain the exact pinned native main window."
    }
    if ($null -ne $MainWindow) {
        Assert-AutomationBinding `
            -Element $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label $Label `
            -RequireWindowHandle
        if ([long]$MainWindow.Current.NativeWindowHandle -ne $MainWindowHandle.ToInt64() -or
            $MainWindow.Current.Name -cne $ExpectedTitle -or
            $MainWindow.Current.ControlType -ne [Windows.Automation.ControlType]::Window) {
            throw "$Label does not retain the exact pinned UI Automation main window."
        }
    }
}

function Wait-ExactApplicationMainWindow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $ExpectedClassName,
        [Parameter(Mandatory)][string] $ExpectedTitle,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label
    )

    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    $nativeFound = $false
    $uiaIdentityMismatch = $false
    do {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Label exited before creating its main window."
        }
        if ($Process.SessionId -ne $ExpectedSession) {
            throw "$Label left the expected desktop session."
        }
        $native = Resolve-ExactApplicationMainWindowCandidate `
            -Windows @([DarkReNamerVmNative]::ReadProcessTopLevelWindows([uint32]$Process.Id)) `
            -ExpectedProcessId $Process.Id `
            -ExpectedClassName $ExpectedClassName `
            -ExpectedTitle $ExpectedTitle
        if ($null -ne $native) {
            $nativeFound = $true
            try {
                $window = [Windows.Automation.AutomationElement]::FromHandle(
                    [IntPtr][long]$native.Handle
                )
            }
            catch {
                $window = $null
            }
            if ($null -ne $window) {
                $fresh = Resolve-ExactApplicationMainWindowCandidate `
                    -Windows @([DarkReNamerVmNative]::ReadProcessTopLevelWindows([uint32]$Process.Id)) `
                    -ExpectedProcessId $Process.Id `
                    -ExpectedClassName $ExpectedClassName `
                    -ExpectedTitle $ExpectedTitle
                if ($null -eq $fresh -or [long]$fresh.Handle -ne [long]$native.Handle) {
                    throw "$Label changed during exact native-to-UIA binding."
                }
                try {
                    $uiaProcessId = [int]$window.Current.ProcessId
                    $uiaHandle = [long]$window.Current.NativeWindowHandle
                    $uiaName = [string]$window.Current.Name
                    $uiaControlType = $window.Current.ControlType
                }
                catch {
                    $uiaIdentityMismatch = $true
                    $uiaProcessId = 0
                    $uiaHandle = 0L
                    $uiaName = ''
                    $uiaControlType = $null
                }
                if ($uiaProcessId -ne 0 -and $uiaProcessId -ne $Process.Id) {
                    throw "$Label UI Automation provider is bound to a foreign process."
                }
                if ($uiaHandle -ne 0 -and $uiaHandle -ne [long]$fresh.Handle) {
                    throw "$Label UI Automation provider changed from the exact native window."
                }
                if ($uiaProcessId -ne $Process.Id -or $uiaHandle -ne [long]$fresh.Handle -or
                    $uiaName -cne $ExpectedTitle -or
                    $uiaControlType -ne [Windows.Automation.ControlType]::Window) {
                    $uiaIdentityMismatch = $true
                }
                else {
                    return [pscustomobject]@{
                        handle = [IntPtr][long]$fresh.Handle
                        element = $window
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if ($uiaIdentityMismatch) {
        throw "$Label exact native window did not publish the expected UI Automation identity before the bounded deadline."
    }
    if ($nativeFound) {
        throw "$Label exact native window did not become available through UI Automation before the bounded deadline."
    }
    throw "$Label exact native window was not found before the bounded deadline."
}

function Close-ExactApplicationMainWindow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][string] $ExpectedClassName,
        [Parameter(Mandatory)][string] $ExpectedTitle,
        [Parameter(Mandatory)][string] $Label
    )

    Assert-ExactApplicationMainWindowBinding `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -MainWindowHandle $MainWindowHandle `
        -MainWindow $MainWindow `
        -ExpectedClassName $ExpectedClassName `
        -ExpectedTitle $ExpectedTitle `
        -Label $Label
    if (-not [DarkReNamerVmNative]::IsWindowEnabled($MainWindowHandle)) {
        throw "$Label did not expose an enabled main window for ordinary close."
    }
    [DarkReNamerVmNative]::RequestWindowClose($MainWindowHandle)
}

function Find-UniqueAutomationElement {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Root,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $AutomationId,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label,
        [Windows.Automation.ControlType] $ControlType,
        [Windows.Automation.TreeScope] $Scope = [Windows.Automation.TreeScope]::Descendants,
        [switch] $RequireEnabled,
        [switch] $RequireWindowHandle
    )

    $conditions = [Collections.Generic.List[Windows.Automation.Condition]]::new()
    $conditions.Add([Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ProcessIdProperty,
        $Process.Id
    ))
    $conditions.Add([Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    ))
    if ($null -ne $ControlType) {
        $conditions.Add([Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            $ControlType
        ))
    }
    if ($RequireEnabled) {
        $conditions.Add([Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::IsEnabledProperty,
            $true
        ))
    }
    $condition = [Windows.Automation.AndCondition]::new($conditions.ToArray())
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $matches = $Root.FindAll($Scope, $condition)
        if ($matches.Count -gt 1) {
            throw "$Label matched more than one automation element."
        }
        if ($matches.Count -eq 1) {
            $element = $matches.Item(0)
            Assert-AutomationBinding `
                -Element $element `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label $Label `
                -RequireWindowHandle:$RequireWindowHandle
            return $element
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Label was not found before the application exited."
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Label was not found before the bounded deadline."
}

function Resolve-UniqueAutomationWindowCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $TopLevelCandidates,
        [AllowNull()][scriptblock] $FallbackQuery,
        [Parameter(Mandatory)][string] $Label
    )

    $candidates = @($TopLevelCandidates)
    if ($candidates.Count -eq 0 -and $null -ne $FallbackQuery) {
        $candidates = @(& $FallbackQuery)
    }
    $windows = @{}
    foreach ($candidate in $candidates) {
        $windows[[string]$candidate.Current.NativeWindowHandle] = $candidate
    }
    $matches = @($windows.Values)
    if ($matches.Count -gt 1) {
        throw "$Label matched more than one top-level window."
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}

function Wait-UniqueAutomationWindow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label,
        [Windows.Automation.AutomationElement] $Owner,
        [IntPtr] $MainWindowHandle = [IntPtr]::Zero
    )

    if ($null -ne $Owner) {
        Assert-AutomationBinding `
            -Element $Owner `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Label "$Label owner" `
            -RequireWindowHandle
    }
    elseif ($MainWindowHandle -eq [IntPtr]::Zero) {
        throw "$Label requires the exact pinned main-window handle when no owner is supplied."
    }
    $root = [Windows.Automation.AutomationElement]::RootElement
    $conditions = [Windows.Automation.Condition[]]@(
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ProcessIdProperty,
            $Process.Id
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty,
            $Name
        ),
        [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::Window
        )
    )
    $condition = [Windows.Automation.AndCondition]::new($conditions)
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    do {
        $main = if ($null -eq $Owner) {
            $candidateMain = [Windows.Automation.AutomationElement]::FromHandle($MainWindowHandle)
            if ($null -ne $candidateMain) {
                Assert-ExactApplicationMainWindowBinding `
                    -Process $Process `
                    -ExpectedSession $ExpectedSession `
                    -MainWindowHandle $MainWindowHandle `
                    -MainWindow $candidateMain `
                    -ExpectedClassName 'DarkReNamerWindow' `
                    -ExpectedTitle 'DarkReNamer' `
                    -Label "$Label main window"
            }
            $candidateMain
        }
        else {
            $null
        }
        $candidates = @($root.FindAll([Windows.Automation.TreeScope]::Children, $condition))
        if ($null -ne $Owner) {
            $candidates += @($Owner.FindAll([Windows.Automation.TreeScope]::Children, $condition))
        }
        $fallbackQuery = if ($null -eq $Owner -and $null -ne $main) {
            # Managed Win32 providers place owned dialogs below their owner.
            {
                @($main.FindAll([Windows.Automation.TreeScope]::Descendants, $condition))
            }.GetNewClosure()
        }
        else {
            $null
        }
        $element = Resolve-UniqueAutomationWindowCandidate `
            -TopLevelCandidates $candidates `
            -FallbackQuery $fallbackQuery `
            -Label $Label
        if ($null -ne $element) {
            Assert-AutomationBinding `
                -Element $element `
                -Process $Process `
                -ExpectedSession $ExpectedSession `
                -Label $Label `
                -RequireWindowHandle
            return $element
        }
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Label was not found before the application exited."
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Label was not found before the bounded deadline."
}

function Invoke-AutomationControl {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Label
    )

    $pattern = $null
    if (-not $Element.TryGetCurrentPattern(
        [Windows.Automation.InvokePattern]::Pattern,
        [ref]$pattern
    )) {
        throw "$Label does not support UI Automation InvokePattern."
    }
    ([Windows.Automation.InvokePattern]$pattern).Invoke()
}

function Start-AutomationControlInvoke {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Label
    )

    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [Threading.ApartmentState]::MTA
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('automationElement', $Element)
    $runspace.SessionStateProxy.SetVariable('automationLabel', $Label)
    $powershell = [PowerShell]::Create()
    $powershell.Runspace = $runspace
    [void]$powershell.AddScript(@'
$invokePattern = $null
if (-not $automationElement.TryGetCurrentPattern(
    [Windows.Automation.InvokePattern]::Pattern,
    [ref]$invokePattern
)) {
    throw "$automationLabel does not support UI Automation InvokePattern."
}
([Windows.Automation.InvokePattern]$invokePattern).Invoke()
'@)
    try {
        $asyncResult = $powershell.BeginInvoke()
        [pscustomobject]@{
            powershell = $powershell
            runspace = $runspace
            async_result = $asyncResult
            label = $Label
            completed = $false
        }
    }
    catch {
        $powershell.Dispose()
        $runspace.Dispose()
        throw
    }
}

function Complete-AutomationControlInvoke {
    param(
        [Parameter(Mandatory)][object] $State,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    if ($State.completed) {
        return
    }
    $waitMilliseconds = [int]([Math]::Min(
        [int]::MaxValue,
        [Math]::Min(30, $TimeoutSeconds) * 1000L
    ))
    if (-not $State.async_result.AsyncWaitHandle.WaitOne($waitMilliseconds)) {
        throw "$($State.label) UI Automation invocation did not return before the bounded deadline."
    }
    try {
        [void]$State.powershell.EndInvoke($State.async_result)
        if ($State.powershell.HadErrors) {
            throw "$($State.label) UI Automation invocation failed."
        }
    }
    finally {
        $State.completed = $true
        $State.powershell.Dispose()
        $State.runspace.Dispose()
    }
}

function Set-AutomationControlValue {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Label
    )

    $pattern = $null
    if (-not $Element.TryGetCurrentPattern(
        [Windows.Automation.ValuePattern]::Pattern,
        [ref]$pattern
    )) {
        $editCondition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty,
            [Windows.Automation.ControlType]::Edit
        )
        $edits = $Element.FindAll([Windows.Automation.TreeScope]::Descendants, $editCondition)
        if ($edits.Count -ne 1 -or -not $edits.Item(0).TryGetCurrentPattern(
            [Windows.Automation.ValuePattern]::Pattern,
            [ref]$pattern
        )) {
            throw "$Label does not expose one UI Automation value control."
        }
    }
    $valuePattern = [Windows.Automation.ValuePattern]$pattern
    if ($valuePattern.Current.IsReadOnly) {
        throw "$Label is read-only."
    }
    $valuePattern.SetValue($Value)
    if ($valuePattern.Current.Value -cne $Value) {
        throw "$Label did not retain the exact requested value."
    }
}

function Wait-WindowClosed {
    param(
        [Parameter(Mandatory)][IntPtr] $Handle,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $Label
    )

    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    while ([DarkReNamerVmNative]::IsWindow($Handle) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ([DarkReNamerVmNative]::IsWindow($Handle)) {
        throw "$Label did not close before the bounded deadline."
    }
}

function Wait-ListPreviewName {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $ExpectedName,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $list = Find-UniqueAutomationElement `
        -Root $MainWindow `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -AutomationId '1000' `
        -TimeoutSeconds $TimeoutSeconds `
        -Label 'production file list' `
        -RequireWindowHandle
    $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
    # The row and original-name cell can share the preview name.
    # Wait for the preview column instead of requiring unique descendant names.
    do {
        try {
            $gridObject = $null
            if ($list.TryGetCurrentPattern([Windows.Automation.GridPattern]::Pattern, [ref]$gridObject)) {
                $grid = [Windows.Automation.GridPattern]$gridObject
                if ($grid.Current.RowCount -eq 1 -and $grid.Current.ColumnCount -ge 2) {
                    $candidate = $grid.GetItem(0, 1)
                    if ($candidate.Current.Name -ceq $ExpectedName) {
                        return
                    }
                }
            }
        }
        catch [Windows.Automation.ElementNotAvailableException] {
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw 'The expected production preview name was not exposed before the bounded deadline.'
}

function Measure-ScreenshotSparseVariation {
    param(
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int] $Width,
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int] $Height,
        [Parameter(Mandatory)][scriptblock] $ReadArgb
    )

    if (([long]$Width * [long]$Height) -gt 100000000L) {
        throw 'Screenshot sample bounds exceed the resource limit.'
    }
    $stepX = [Math]::Max(1, [int]($Width / 64))
    $stepY = [Math]::Max(1, [int]($Height / 64))
    $firstArgb = [int]0
    $sampleCount = 0
    for ($y = 0; $y -lt $Height; $y += $stepY) {
        for ($x = 0; $x -lt $Width; $x += $stepX) {
            $argb = [int](& $ReadArgb $x $y)
            $sampleCount++
            if ($sampleCount -eq 1) {
                $firstArgb = $argb
            }
            elseif ($argb -ne $firstArgb) {
                return [pscustomobject][ordered]@{
                    first_argb = $firstArgb
                    step_x = $stepX
                    step_y = $stepY
                    sample_count = $sampleCount
                    distinct_sample_count = 2
                    has_sampled_variation = $true
                }
            }
        }
    }
    [pscustomobject][ordered]@{
        first_argb = $firstArgb
        step_x = $stepX
        step_y = $stepY
        sample_count = $sampleCount
        distinct_sample_count = 1
        has_sampled_variation = $false
    }
}

function Save-WindowScreenshot {
    param(
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $Window,
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[object]] $ForegroundObservations
    )

    Assert-SafeLeafName -Value $Leaf -Label "$Label screenshot" -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.png$'
    Assert-AutomationBinding `
        -Element $Window `
        -Process $Process `
        -ExpectedSession $ExpectedSession `
        -Label $Label `
        -RequireWindowHandle
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    if (-not [DarkReNamerVmNative]::IsWindowVisible($handle)) {
        throw "$Label is not visible for screenshot capture."
    }
    $activation = [ordered]@{
        label = $Label
        target_hwnd = [long]$handle
        initial = Get-ForegroundObservation
        uia_set_focus = 'not_attempted'
        set_foreground_window = $null
        final = $null
        capture_complete = $null
        capture_change = $null
    }
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
        try {
            $Window.SetFocus()
            $activation.uia_set_focus = 'succeeded'
        }
        catch {
            $activation.uia_set_focus = 'failed'
        }
        $activation.set_foreground_window = [bool][DarkReNamerVmNative]::SetForegroundWindow($handle)
        $foregroundDeadline = (Get-Date).AddSeconds(5)
        while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle -and
            (Get-Date) -lt $foregroundDeadline) {
            Start-Sleep -Milliseconds 100
        }
    }
    $activation.final = Get-ForegroundObservation
    $activationObservation = [pscustomobject]$activation
    $ForegroundObservations.Add($activationObservation)
    if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
        throw "$Label is not the foreground window for screenshot capture."
    }
    $rect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
        throw "$Label bounds could not be read."
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0 -or
        $width -gt 16384 -or $height -gt 16384 -or
        ([long]$width * [long]$height) -gt 100000000) {
        throw "$Label bounds are invalid."
    }
    $bitmap = $null
    $graphics = $null
    try {
        $bitmap = [Drawing.Bitmap]::new(
            $width,
            $height,
            [Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen(
            $rect.Left,
            $rect.Top,
            0,
            0,
            $bitmap.Size,
            [Drawing.CopyPixelOperation]::SourceCopy
        )
        $activationObservation.capture_complete = Get-ForegroundObservation
        if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
            $activationObservation.capture_change = Get-ForegroundObservation
            throw "$Label lost foreground during screenshot capture."
        }
        $sampleObservation = Measure-ScreenshotSparseVariation `
            -Width $width `
            -Height $height `
            -ReadArgb {
                param($x, $y)
                $bitmap.GetPixel($x, $y).ToArgb()
            }.GetNewClosure()
        if (-not $sampleObservation.has_sampled_variation) {
            $diagnosticLeaf = $Leaf.Substring(0, $Leaf.Length - 4) +
                '.solid-diagnostic.png'
            Assert-SafeLeafName `
                -Value $diagnosticLeaf `
                -Label "$Label solid-image diagnostic" `
                -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*\.png$'
            $diagnosticPath = Join-Path $Root $diagnosticLeaf
            if (Test-Path -LiteralPath $diagnosticPath) {
                throw "$Label solid-image diagnostic path already exists."
            }
            $bitmap.Save($diagnosticPath, [Drawing.Imaging.ImageFormat]::Png)
            $diagnosticItem = Get-Item -LiteralPath $diagnosticPath
            if ($diagnosticItem.Length -le 0) {
                throw "$Label solid-image diagnostic is empty."
            }
            $activationObservation | Add-Member `
                -NotePropertyName solid_image_diagnostic `
                -NotePropertyValue ([ordered]@{
                    classification = 'sampled-grid-uniform'
                    scope = 'sparse-samples-only'
                    file = $diagnosticLeaf
                    sha256 = Get-LowerSha256 -Path $diagnosticPath
                    bytes = [long]$diagnosticItem.Length
                    rect = [ordered]@{
                        left = [int]$rect.Left
                        top = [int]$rect.Top
                        right = [int]$rect.Right
                        bottom = [int]$rect.Bottom
                        width = $width
                        height = $height
                    }
                    first_argb = [int]$sampleObservation.first_argb
                    step_x = [int]$sampleObservation.step_x
                    step_y = [int]$sampleObservation.step_y
                    sample_count = [int]$sampleObservation.sample_count
                    distinct_sample_count = [int]$sampleObservation.distinct_sample_count
                    has_sampled_variation = $false
                    foreground = $activationObservation.capture_complete
                })
            throw "$Label screenshot is a solid image."
        }
        $path = Join-Path $Root $Leaf
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        if ((Get-Item -LiteralPath $path).Length -le 0) {
            throw "$Label screenshot is empty."
        }
        [ordered]@{
            file = $Leaf
            sha256 = Get-LowerSha256 -Path $path
            width = $width
            height = $height
        }
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
}

function Assert-NoJournalResidue {
    param([Parameter(Mandatory)][string] $LocalAppData)

    $journalRoot = Join-Path (Join-Path $LocalAppData 'DarkReNamer') 'journal'
    if (Test-Path -LiteralPath $journalRoot) {
        $residue = @(
            Get-ChildItem -LiteralPath $journalRoot -Force |
                Where-Object Name -cne 'runtime.lock'
        )
        if ($residue.Count -ne 0) {
            throw 'The production flow left rename-journal residue.'
        }
    }
}

function Get-FlowCheckpoint {
    param(
        [Parameter(Mandatory)][ValidateSet('initial', 'after_cancel', 'after_apply', 'post_close')]
        [string] $Phase,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $LocalAppData
    )

    $fixtureItems = @(Get-ChildItem -LiteralPath $FixtureRoot -Force | Sort-Object Name)
    if ($fixtureItems.Count -gt 8) {
        throw 'The production flow fixture inventory exceeds its bound.'
    }
    $fixtureEntries = foreach ($item in $fixtureItems) {
        $reparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        $kind = if ($reparse) { 'reparse' } elseif ($item.PSIsContainer) { 'directory' } else { 'file' }
        [ordered]@{
            name = $item.Name
            kind = $kind
            bytes = if ($kind -ceq 'file') { [long]$item.Length } else { [long]0 }
            content_sha256 = if ($kind -ceq 'file') { Get-LowerSha256 -Path $item.FullName } else { $null }
            file_identity_sha256 = if ($kind -ceq 'file') {
                Get-LowerTextSha256 -Value ([DarkReNamerVmNative]::GetFileIdentity($item.FullName))
            } else { $null }
        }
    }
    $journalRoot = Join-Path (Join-Path $LocalAppData 'DarkReNamer') 'journal'
    $journalEntries = @()
    if (Test-Path -LiteralPath $journalRoot -PathType Container) {
        $items = @(Get-ChildItem -LiteralPath $journalRoot -Force | Sort-Object Name)
        if ($items.Count -gt 16) {
            throw 'The production flow journal inventory exceeds its bound.'
        }
        $journalEntries = @($items | ForEach-Object {
            if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The production flow journal inventory contains a reparse point.'
            }
            [ordered]@{
                name = $_.Name
                kind = if ($_.PSIsContainer) { 'directory' } else { 'file' }
                bytes = if ($_.PSIsContainer) { [long]0 } else { [long]$_.Length }
            }
        })
    }
    [ordered]@{
        phase = $Phase
        fixture_entries = @($fixtureEntries)
        journal_entries = @($journalEntries)
    }
}

function Get-VmAutomatedFixtureInventory {
    param([Parameter(Mandatory)][string] $FixtureRoot)

    $root = Get-VmAutomatedCanonicalRootPath -Path $FixtureRoot
    $items = @(Get-ChildItem -LiteralPath $root -Force | Sort-Object Name)
    if ($items.Count -gt 10001) {
        throw 'The VM-Automated fixture inventory exceeds its bound.'
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    @($items | ForEach-Object {
        if (-not $names.Add($_.Name) -or
            $_.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$' -or
            $_.Name.EndsWith('.', [StringComparison]::Ordinal) -or
            $_.Name.EndsWith(' ', [StringComparison]::Ordinal) -or
            $_.Name.Split('.')[0] -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw 'The VM-Automated fixture inventory contains an unsafe name.'
        }
        if ($_.PSIsContainer -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $_ -isnot [IO.FileInfo]) {
            throw 'The VM-Automated fixture inventory requires ordinary files.'
        }
        if ($_.Length -gt 64MB) {
            throw 'The VM-Automated fixture inventory contains an oversized file.'
        }
        $total += $_.Length
        if ($total -gt 512MB) {
            throw 'The VM-Automated fixture inventory exceeds its aggregate size bound.'
        }
        [ordered]@{
            name = $_.Name
            kind = 'file'
            bytes = [long]$_.Length
            content_sha256 = Get-LowerSha256 -Path $_.FullName
            file_identity = Get-FullFileIdentity -Path $_.FullName
        }
    })
}

function Get-VmAutomatedJournalInventory {
    param([Parameter(Mandatory)][string] $LocalAppData)

    $journalRoot = Join-Path (Join-Path $LocalAppData 'DarkReNamer') 'journal'
    if (-not (Test-Path -LiteralPath $journalRoot)) { return @() }
    $root = Get-Item -LiteralPath $journalRoot -Force
    if (-not $root.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The VM-Automated journal root is not an ordinary directory.'
    }
    $items = @(Get-ChildItem -LiteralPath $root.FullName -Force | Sort-Object Name)
    if ($items.Count -gt 256) {
        throw 'The VM-Automated journal inventory exceeds its bound.'
    }
    @($items | ForEach-Object {
        if ($_.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$' -or
            $_.Name.EndsWith('.', [StringComparison]::Ordinal) -or
            $_.Name.EndsWith(' ', [StringComparison]::Ordinal) -or
            $_.Name.Split('.')[0] -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The VM-Automated journal inventory contains an unsafe entry.'
        }
        [ordered]@{
            name = $_.Name
            kind = if ($_.PSIsContainer) { 'directory' } else { 'file' }
            bytes = if ($_.PSIsContainer) { [long]0 } else { [long]$_.Length }
        }
    })
}

function Get-VmAutomatedCheckpoint {
    param(
        [Parameter(Mandatory)][ValidateSet('initial', 'after_cancel', 'after_apply', 'post_close')]
        [string] $Phase,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $LocalAppData
    )
    [ordered]@{
        phase = $Phase
        fixture_entries = @(Get-VmAutomatedFixtureInventory -FixtureRoot $FixtureRoot)
        journal_entries = @(Get-VmAutomatedJournalInventory -LocalAppData $LocalAppData)
    }
}

function Get-VmAutomatedOwnedProcessInventory {
    param([Parameter(Mandatory)][string] $Root)

    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.ExecutablePath -and
        $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object ProcessId | ForEach-Object {
        [ordered]@{
            pid = [int]$_.ProcessId
            session_id = [int]$_.SessionId
            executable_path = [string]$_.ExecutablePath
        }
    })
}

function New-VmAutomatedJournalCleanupObservation {
    param(
        [Parameter(Mandatory)][bool] $Observed,
        [AllowNull()][object[]] $Entries
    )

    if (-not $Observed) { return $null }
    [ordered]@{ entries = @($Entries) }
}

function Get-VmAutomatedRuntimeRootObservation {
    param(
        [Parameter(Mandatory)][string] $Root,
        [ValidateRange(1, 16384)][int] $MaximumEntries = 16384
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return [ordered]@{ exists = $false; entries = @() }
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The VM-Automated runtime root is unsafe.'
    }
    $entries = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootItem.FullName)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The VM-Automated runtime root contains a reparse point.'
            }
            if (-not $item.PSIsContainer -and $item -isnot [IO.FileInfo]) {
                throw 'The VM-Automated runtime root contains a non-ordinary entry.'
            }
            if ($entries.Count -ge $MaximumEntries) {
                throw 'The VM-Automated runtime root entry count exceeds its bound.'
            }
            $entries.Add([ordered]@{
                path = $item.FullName.Substring($rootItem.FullName.Length + 1).Replace('\', '/')
                kind = if ($item.PSIsContainer) { 'directory' } else { 'file' }
            })
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            }
        }
    }
    [ordered]@{ exists = $true; entries = @($entries | Sort-Object path) }
}

function Invoke-ProductionRenameFlow {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Windows.Automation.AutomationElement] $MainWindow,
        [Parameter(Mandatory)][IntPtr] $MainWindowHandle,
        [Parameter(Mandatory)][string] $FixtureRoot,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [switch] $RawEvidence
    )

    $sourceName = 'vm-flow-source.txt'
    $prefix = 'vm-confirmed-'
    $previewName = $prefix + $sourceName
    $sourcePath = Join-Path $FixtureRoot $sourceName
    $destinationPath = Join-Path $FixtureRoot $previewName
    $pendingInvocations = [Collections.Generic.List[object]]::new()
    $foregroundObservations = [Collections.Generic.List[object]]::new()
    $flow = [ordered]@{
        status = 'failed'
        scope = 'production-file-add-prefix-cancel-confirm'
        input_mode = 'uia-functional'
        application_file = 'DarkReNamer.exe'
        application_sha256 = $null
        source_name = $sourceName
        preview_name = $previewName
        before_content_sha256 = $null
        after_content_sha256 = $null
        before_file_identity_sha256 = $null
        after_file_identity_sha256 = $null
        cancellation_source_present = $null
        cancellation_destination_present = $null
        confirmed_source_present = $null
        confirmed_destination_present = $null
        journal_residue_count = $null
        checkpoints = @()
        foreground_observations = $foregroundObservations
        screenshots = @()
        diagnostic = $null
        failure_reason = 'fixture_setup_failed'
    }
    try {
        $flow.application_sha256 = Get-LowerSha256 -Path (Join-Path $Root 'DarkReNamer.exe')
        $fixtureBytes = [Text.UTF8Encoding]::new($false).GetBytes(
            "DarkReNamer production VM flow`nidentity and content must survive`n"
        )
        [IO.File]::WriteAllBytes($sourcePath, $fixtureBytes)
        $flow.before_content_sha256 = Get-LowerSha256 -Path $sourcePath
        $beforeFileIdentity = [DarkReNamerVmNative]::GetFileIdentity($sourcePath)
        $flow.before_file_identity_sha256 = Get-LowerTextSha256 -Value $beforeFileIdentity
        $flow.checkpoints = @((Get-FlowCheckpoint `
            -Phase initial `
            -FixtureRoot $FixtureRoot `
            -LocalAppData $env:LOCALAPPDATA))
        if ($RawEvidence) {
            $flow['raw_environment'] = Get-VmAutomatedEnvironment `
                -Process $Process `
                -WindowHandle ([IntPtr]$MainWindow.Current.NativeWindowHandle) `
                -FixtureRoot $FixtureRoot
            $flow['raw_checkpoints'] = @((Get-VmAutomatedCheckpoint `
                -Phase initial `
                -FixtureRoot $FixtureRoot `
                -LocalAppData $env:LOCALAPPDATA))
        }

        $flow.failure_reason = 'file_add_failed'
        $add = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8017) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'file-add command' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -Element $add -Label 'file-add command'
        $pendingInvocations.Add($invoke)

        $fileDialog = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -MainWindowHandle $MainWindowHandle `
            -Name '이름 붙일 파일 불러오기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'production file dialog'
        $fileDialogHandle = [IntPtr]$fileDialog.Current.NativeWindowHandle
        $fileName = Find-UniqueAutomationElement `
            -Root $fileDialog `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1148' `
            -ControlType ([Windows.Automation.ControlType]::Edit) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'file dialog filename control'
        Set-AutomationControlValue `
            -Element $fileName `
            -Value $sourcePath `
            -Label 'file dialog filename control'
        $open = Find-UniqueAutomationElement `
            -Root $fileDialog `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'file dialog open button' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $open -Label 'file dialog open button'
        Wait-WindowClosed -Handle $fileDialogHandle -TimeoutSeconds $TimeoutSeconds -Label 'production file dialog'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        Wait-ListPreviewName `
            -MainWindow $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -ExpectedName $sourceName `
            -TimeoutSeconds $TimeoutSeconds

        $flow.failure_reason = 'prefix_prompt_failed'
        $prefixCommand = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8005) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix command' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -Element $prefixCommand -Label 'prefix command'
        $pendingInvocations.Add($invoke)
        $prompt = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -MainWindowHandle $MainWindowHandle `
            -Name '이름 앞에 문자열 붙이기' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt'
        $promptHandle = [IntPtr]$prompt.Current.NativeWindowHandle
        $prefixEdit = Find-UniqueAutomationElement `
            -Root $prompt `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1004' `
            -ControlType ([Windows.Automation.ControlType]::Edit) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt edit' `
            -RequireWindowHandle
        Set-AutomationControlValue -Element $prefixEdit -Value $prefix -Label 'prefix prompt edit'
        $promptOk = Find-UniqueAutomationElement `
            -Root $prompt `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId '1' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'prefix prompt confirmation' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $promptOk -Label 'prefix prompt confirmation'
        Wait-WindowClosed -Handle $promptHandle -TimeoutSeconds $TimeoutSeconds -Label 'prefix prompt'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        Wait-ListPreviewName `
            -MainWindow $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -ExpectedName $previewName `
            -TimeoutSeconds $TimeoutSeconds
        $flow.failure_reason = 'preview_verification_failed'
        $screenshots = [Collections.Generic.List[object]]::new()
        $screenshots.Add((Save-WindowScreenshot `
            -Window $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Root $Root `
            -Leaf 'rename-preview.png' `
            -Label 'production rename preview' `
            -ForegroundObservations $foregroundObservations))
        $flow.screenshots = $screenshots.ToArray()

        $flow.failure_reason = 'apply_cancellation_failed'
        $apply = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8003) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply command' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke -Element $apply -Label 'apply command'
        $pendingInvocations.Add($invoke)
        $confirmation = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -MainWindowHandle $MainWindowHandle `
            -Name 'DarkReNamer - 안전한 적용 확인' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply confirmation task dialog'
        $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
        $screenshots.Add((Save-WindowScreenshot `
            -Window $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -Root $Root `
            -Leaf 'apply-confirmation.png' `
            -Label 'apply confirmation task dialog' `
            -ForegroundObservations $foregroundObservations))
        $flow.screenshots = $screenshots.ToArray()
        $cancel = Find-UniqueAutomationElement `
            -Root $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId 'CommandButton_2' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply confirmation cancel button' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $cancel -Label 'apply confirmation cancel button'
        Wait-WindowClosed `
            -Handle $confirmationHandle `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'cancelled apply confirmation task dialog'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds
        $flow.cancellation_source_present = Test-Path -LiteralPath $sourcePath -PathType Leaf
        $flow.cancellation_destination_present = Test-Path -LiteralPath $destinationPath -PathType Leaf
        if (-not $flow.cancellation_source_present -or $flow.cancellation_destination_present -or
            (Get-LowerSha256 -Path $sourcePath) -cne $flow.before_content_sha256 -or
            [DarkReNamerVmNative]::GetFileIdentity($sourcePath) -cne $beforeFileIdentity) {
            throw 'Cancelling the production confirmation changed the fixture.'
        }
        $flow.checkpoints += (Get-FlowCheckpoint `
            -Phase after_cancel `
            -FixtureRoot $FixtureRoot `
            -LocalAppData $env:LOCALAPPDATA)
        if ($RawEvidence) {
            $flow.raw_checkpoints += (Get-VmAutomatedCheckpoint `
                -Phase after_cancel `
                -FixtureRoot $FixtureRoot `
                -LocalAppData $env:LOCALAPPDATA)
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA

        $flow.failure_reason = 'confirmed_apply_failed'
        $apply = Find-UniqueAutomationElement `
            -Root $MainWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId ([string]0x8003) `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'apply command after cancellation' `
            -RequireEnabled `
            -RequireWindowHandle
        $invoke = Start-AutomationControlInvoke `
            -Element $apply `
            -Label 'apply command after cancellation'
        $pendingInvocations.Add($invoke)
        $confirmation = Wait-UniqueAutomationWindow `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -MainWindowHandle $MainWindowHandle `
            -Name 'DarkReNamer - 안전한 적용 확인' `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'second apply confirmation task dialog'
        $confirmationHandle = [IntPtr]$confirmation.Current.NativeWindowHandle
        $confirm = Find-UniqueAutomationElement `
            -Root $confirmation `
            -Process $Process `
            -ExpectedSession $ExpectedSession `
            -AutomationId 'CommandLink_1101' `
            -ControlType ([Windows.Automation.ControlType]::Button) `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'exact destructive confirmation button' `
            -RequireEnabled `
            -RequireWindowHandle
        Invoke-AutomationControl -Element $confirm -Label 'exact destructive confirmation button'
        Wait-WindowClosed `
            -Handle $confirmationHandle `
            -TimeoutSeconds $TimeoutSeconds `
            -Label 'confirmed apply task dialog'
        Complete-AutomationControlInvoke -State $invoke -TimeoutSeconds $TimeoutSeconds

        $deadline = (Get-Date).AddSeconds([Math]::Min(30, $TimeoutSeconds))
        do {
            $sourcePresent = Test-Path -LiteralPath $sourcePath -PathType Leaf
            $destinationPresent = Test-Path -LiteralPath $destinationPath -PathType Leaf
            if (-not $sourcePresent -and $destinationPresent) {
                try {
                    Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
                    break
                }
                catch {
                }
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        $flow.checkpoints += (Get-FlowCheckpoint `
            -Phase after_apply `
            -FixtureRoot $FixtureRoot `
            -LocalAppData $env:LOCALAPPDATA)
        if ($RawEvidence) {
            $flow.raw_checkpoints += (Get-VmAutomatedCheckpoint `
                -Phase after_apply `
                -FixtureRoot $FixtureRoot `
                -LocalAppData $env:LOCALAPPDATA)
        }
        Assert-NoJournalResidue -LocalAppData $env:LOCALAPPDATA
        $flow.confirmed_source_present = Test-Path -LiteralPath $sourcePath -PathType Leaf
        $flow.confirmed_destination_present = Test-Path -LiteralPath $destinationPath -PathType Leaf
        if ($flow.confirmed_source_present -or -not $flow.confirmed_destination_present) {
            throw 'The confirmed production apply did not perform the expected disk rename.'
        }
        $flow.after_content_sha256 = Get-LowerSha256 -Path $destinationPath
        $afterFileIdentity = [DarkReNamerVmNative]::GetFileIdentity($destinationPath)
        $flow.after_file_identity_sha256 = Get-LowerTextSha256 -Value $afterFileIdentity
        if ($flow.after_content_sha256 -cne $flow.before_content_sha256 -or
            $afterFileIdentity -cne $beforeFileIdentity) {
            throw 'The confirmed production rename did not preserve file contents and identity.'
        }
        $journalRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'DarkReNamer') 'journal'
        $flow.journal_residue_count = if (Test-Path -LiteralPath $journalRoot) {
            @(
                Get-ChildItem -LiteralPath $journalRoot -Force |
                    Where-Object Name -cne 'runtime.lock'
            ).Count
        } else {
            0
        }
        $flow.screenshots = $screenshots.ToArray()
        $flow.status = 'passed'
        $flow.failure_reason = $null
    }
    catch {
        if ($flow.failure_reason -eq $null) {
            $flow.failure_reason = 'production_flow_error'
        }
        $diagnosticLeaf = 'gui-flow-error.txt'
        $diagnosticPath = Join-Path $Root $diagnosticLeaf
        $diagnosticText = $_ | Out-String -Width 4096
        foreach ($invocation in $pendingInvocations) {
            if ($invocation.completed) { continue }
            $diagnosticText += "`n$($invocation.label): completed=$($invocation.async_result.IsCompleted)`n"
            $diagnosticText += $invocation.powershell.Streams.Error | Out-String -Width 4096
        }
        [IO.File]::WriteAllText($diagnosticPath, $diagnosticText, [Text.UTF8Encoding]::new($true))
        $flow.diagnostic = [ordered]@{
            file = $diagnosticLeaf
            sha256 = Get-LowerSha256 -Path $diagnosticPath
        }
    }
    finally {
        $incomplete = @($pendingInvocations | Where-Object { -not $_.completed })
        if ($incomplete.Count -gt 0 -and -not $Process.HasExited) {
            Invoke-TaskkillTree -ProcessId $Process.Id
            [void]$Process.WaitForExit(10000)
        }
        foreach ($invocation in $incomplete) {
            try {
                if ($invocation.async_result.AsyncWaitHandle.WaitOne(10000)) {
                    [void]$invocation.powershell.EndInvoke($invocation.async_result)
                }
                else {
                    $invocation.powershell.Stop()
                }
            }
            catch {
            }
            finally {
                $invocation.completed = $true
                $invocation.powershell.Dispose()
                $invocation.runspace.Dispose()
            }
        }
    }
    [pscustomobject]$flow
}

function Get-ForegroundObservation {
    $handle = [DarkReNamerVmNative]::GetForegroundWindow()
    $processId = [uint32]0
    $sessionId = $null
    $windowClass = ''
    if ($handle -ne [IntPtr]::Zero) {
        [void][DarkReNamerVmNative]::GetWindowThreadProcessId($handle, [ref]$processId)
        $classText = [Text.StringBuilder]::new(256)
        [void][DarkReNamerVmNative]::GetClassName($handle, $classText, $classText.Capacity)
        $windowClass = $classText.ToString()
        if ($processId -gt 0) {
            try {
                $foregroundProcess = Get-Process -Id $processId -ErrorAction Stop
                $sessionId = [int]$foregroundProcess.SessionId
                $foregroundProcess.Dispose()
            }
            catch {
                $sessionId = $null
            }
        }
    }
    [ordered]@{
        hwnd = [long]$handle
        process_id = [int]$processId
        session_id = $sessionId
        window_class = $windowClass
    }
}

function Invoke-GuiSmoke {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [Parameter(Mandatory)][int] $ExpectedSession,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [switch] $RawEvidence
    )

    $row = [ordered]@{
        file = $Application.file
        sha256 = $Application.sha256
        status = 'failed'
        scope = 'launch-window-screenshot-normal-close'
        exit_code = $null
        window_class = $null
        window_title = $null
        window_handle = $null
        process_id = $null
        session_id = $null
        window_dpi = $null
        foreground_activation = [ordered]@{
            initial = $null
            uia_set_focus = 'not_attempted'
            set_foreground_window = $null
            final = $null
            capture_change = $null
        }
        screenshot = $null
        flow = $null
        failure_reason = 'process_start_failed'
    }
    $processState = [pscustomobject]@{ process = $null }
    $captureState = [pscustomobject]@{ bitmap = $null; graphics = $null }
    $flowFixtureRoot = $null
    $screenshotLeaf = 'main-workbench.png'
    $screenshotPath = Join-Path $Root $screenshotLeaf
    try {
        $applicationPath = Join-Path $Root $Application.file
        Assert-OrdinaryFile -Path $applicationPath -Label 'application'
        if ((Get-LowerSha256 -Path $applicationPath) -cne $Application.sha256) {
            $row.failure_reason = 'artifact_changed_after_preflight'
            return [pscustomobject]$row
        }
        Initialize-NativeCapture
        if (-not [DarkReNamerVmNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
            $row.failure_reason = 'dpi_awareness_failed'
            return [pscustomobject]$row
        }
        $caseRoot = New-PrivateDirectory -Parent $RuntimeRoot -Leaf 'gui'
        Invoke-WithIsolatedEnvironment -RuntimeRoot $caseRoot -Action {
            $processState.process = Start-OwnedProcess `
                -FilePath $applicationPath `
                -Arguments '' `
                -WorkingDirectory $Root
            if ($RawEvidence) {
                $processState.process.process.Refresh()
                $row['process_lifecycle'] = [ordered]@{
                    pid = [int]$processState.process.process.Id
                    session_id = [int]$processState.process.process.SessionId
                    start_time_utc_ticks = $processState.process.process.StartTime.ToUniversalTime().Ticks.ToString(
                        [Globalization.CultureInfo]::InvariantCulture
                    )
                    executable_path = $applicationPath
                    executable_sha256 = Get-LowerSha256 -Path $applicationPath
                    start_observed = $true
                    exit_observed = $false
                    exit_method = $null
                    exit_code = $null
                }
            }
            try {
                $mainBinding = Wait-ExactApplicationMainWindow `
                    -Process $processState.process.process `
                    -ExpectedSession $ExpectedSession `
                    -ExpectedClassName 'DarkReNamerWindow' `
                    -ExpectedTitle 'DarkReNamer' `
                    -TimeoutSeconds $TimeoutSeconds `
                    -Label 'production application'
            }
            catch {
                $processState.process.process.Refresh()
                if ($processState.process.process.HasExited) {
                    $row.exit_code = $processState.process.process.ExitCode
                    $row.failure_reason = 'app_exited_before_window'
                }
                elseif ($_.Exception.Message.IndexOf(
                    'exact native window was not found',
                    [StringComparison]::Ordinal
                ) -ge 0) {
                    $row.failure_reason = 'window_timeout'
                }
                else {
                    $row.failure_reason = 'unexpected_window'
                }
                return
            }
            $handle = [IntPtr]$mainBinding.handle
            $mainAutomationWindow = $mainBinding.element
            $boundProcessId = [uint32]0
            [void][DarkReNamerVmNative]::GetWindowThreadProcessId($handle, [ref]$boundProcessId)
            $row.window_class = 'DarkReNamerWindow'
            $row.window_title = 'DarkReNamer'
            $row.window_handle = [long]$handle
            $row.process_id = [int]$boundProcessId
            $row.session_id = [int]$processState.process.process.SessionId
            $row.window_dpi = [int][DarkReNamerVmNative]::GetDpiForWindow($handle)

            $row.foreground_activation.initial = Get-ForegroundObservation
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                try {
                    $automationElement = [Windows.Automation.AutomationElement]::FromHandle($handle)
                    if ($null -ne $automationElement) {
                        $automationElement.SetFocus()
                        $row.foreground_activation.uia_set_focus = 'succeeded'
                    }
                    else {
                        $row.foreground_activation.uia_set_focus = 'element_unavailable'
                    }
                }
                catch {
                    $row.foreground_activation.uia_set_focus = 'failed'
                }
                $row.foreground_activation.set_foreground_window = [bool][DarkReNamerVmNative]::SetForegroundWindow($handle)
                $foregroundDeadline = (Get-Date).AddSeconds(5)
                while ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle -and
                    (Get-Date) -lt $foregroundDeadline) {
                    Start-Sleep -Milliseconds 100
                }
            }
            $row.foreground_activation.final = Get-ForegroundObservation
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                $row.failure_reason = 'window_not_foreground'
                return
            }

            $rect = [DarkReNamerVmNative+Rect]::new()
            if (-not [DarkReNamerVmNative]::GetWindowRect($handle, [ref]$rect)) {
                $row.failure_reason = 'window_bounds_failed'
                return
            }
            $width = $rect.Right - $rect.Left
            $height = $rect.Bottom - $rect.Top
            if ($width -le 0 -or $height -le 0 -or
                $width -gt 16384 -or $height -gt 16384 -or
                ([long]$width * [long]$height) -gt 100000000) {
                $row.failure_reason = 'window_bounds_invalid'
                return
            }
            $captureState.bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $captureState.graphics = [Drawing.Graphics]::FromImage($captureState.bitmap)
            $captureState.graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $captureState.bitmap.Size, [Drawing.CopyPixelOperation]::SourceCopy)
            if ([DarkReNamerVmNative]::GetForegroundWindow() -ne $handle) {
                $row.foreground_activation.capture_change = Get-ForegroundObservation
                $row.failure_reason = 'foreground_changed_during_capture'
                return
            }
            $firstColor = $captureState.bitmap.GetPixel(0, 0).ToArgb()
            $hasDifferentColor = $false
            $stepX = [Math]::Max(1, [int]($width / 64))
            $stepY = [Math]::Max(1, [int]($height / 64))
            for ($y = 0; $y -lt $height -and -not $hasDifferentColor; $y += $stepY) {
                for ($x = 0; $x -lt $width; $x += $stepX) {
                    if ($captureState.bitmap.GetPixel($x, $y).ToArgb() -ne $firstColor) {
                        $hasDifferentColor = $true
                        break
                    }
                }
            }
            if (-not $hasDifferentColor) {
                $row.failure_reason = 'screenshot_solid'
                return
            }
            $captureState.graphics.Dispose()
            $captureState.graphics = $null
            $captureState.bitmap.Save($screenshotPath, [Drawing.Imaging.ImageFormat]::Png)
            $captureState.bitmap.Dispose()
            $captureState.bitmap = $null
            if ((Get-Item -LiteralPath $screenshotPath).Length -le 0) {
                $row.failure_reason = 'screenshot_empty'
                return
            }
            $row.screenshot = [ordered]@{
                file = $screenshotLeaf
                sha256 = Get-LowerSha256 -Path $screenshotPath
                width = $width
                height = $height
            }

            Assert-ExactApplicationMainWindowBinding `
                -Process $processState.process.process `
                -ExpectedSession $ExpectedSession `
                -MainWindowHandle $handle `
                -MainWindow $mainAutomationWindow `
                -ExpectedClassName 'DarkReNamerWindow' `
                -ExpectedTitle 'DarkReNamer' `
                -Label 'production main window'
            $flowFixtureRoot = New-PrivateDirectory -Parent $caseRoot -Leaf 'rename-flow'
            $row.flow = Invoke-ProductionRenameFlow `
                -Process $processState.process.process `
                -MainWindow $mainAutomationWindow `
                -MainWindowHandle $handle `
                -FixtureRoot $flowFixtureRoot `
                -Root $Root `
                -ExpectedSession $ExpectedSession `
                -TimeoutSeconds $TimeoutSeconds `
                -RawEvidence:$RawEvidence
            if ($row.flow.status -cne 'passed') {
                $row.failure_reason = 'production_rename_flow_failed'
                return
            }

            try {
                Close-ExactApplicationMainWindow `
                    -Process $processState.process.process `
                    -ExpectedSession $ExpectedSession `
                    -MainWindowHandle $handle `
                    -MainWindow $mainAutomationWindow `
                    -ExpectedClassName 'DarkReNamerWindow' `
                    -ExpectedTitle 'DarkReNamer' `
                    -Label 'production application ordinary close'
            }
            catch {
                $row.failure_reason = 'normal_close_rejected'
                return
            }
            if (-not $processState.process.process.WaitForExit(10000)) {
                $row.failure_reason = 'normal_close_timeout'
                return
            }
            $processState.process.process.WaitForExit()
            $row.exit_code = $processState.process.process.ExitCode
            if ($RawEvidence) {
                $row.process_lifecycle.exit_observed = $true
                $row.process_lifecycle.exit_method = 'normal-close'
                $row.process_lifecycle.exit_code = [int]$row.exit_code
            }
            if ($processState.process.process.ExitCode -ne 0) {
                $row.failure_reason = 'app_exit_failed'
                return
            }
            $row.flow.checkpoints += (Get-FlowCheckpoint `
                -Phase post_close `
                -FixtureRoot $flowFixtureRoot `
                -LocalAppData $env:LOCALAPPDATA)
            if ($RawEvidence) {
                $row.flow.raw_checkpoints += (Get-VmAutomatedCheckpoint `
                    -Phase post_close `
                    -FixtureRoot $flowFixtureRoot `
                    -LocalAppData $env:LOCALAPPDATA)
            }
            $row.status = 'passed'
            $row.failure_reason = $null
        }
    }
    catch {
        $row.failure_reason = 'gui_error'
    }
    finally {
        if ($null -ne $captureState.graphics) { $captureState.graphics.Dispose() }
        if ($null -ne $captureState.bitmap) { $captureState.bitmap.Dispose() }
        if ($null -ne $processState.process) {
            try {
                $processState.process.process.Refresh()
                if (-not $processState.process.process.HasExited) {
                    Invoke-TaskkillTree -ProcessId $processState.process.process.Id
                    if (-not $processState.process.process.WaitForExit(10000)) {
                        throw 'Owned application process did not terminate.'
                    }
                    if ($RawEvidence -and $row.Contains('process_lifecycle')) {
                        $row.process_lifecycle.exit_observed = $true
                        $row.process_lifecycle.exit_method = 'forced-termination'
                        $row.process_lifecycle.exit_code = [int]$processState.process.process.ExitCode
                    }
                }
            }
            catch {
                $row.status = 'failed'
                $row.failure_reason = 'process_cleanup_failed'
            }
            $processState.process.process.Dispose()
        }
        if ($null -ne $flowFixtureRoot -and (Test-Path -LiteralPath $flowFixtureRoot)) {
            try {
                $fixtureItem = Get-Item -LiteralPath $flowFixtureRoot -Force
                if (($fixtureItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Production flow fixture became a reparse point.'
                }
                Remove-Item -LiteralPath $flowFixtureRoot -Recurse -Force
                if (Test-Path -LiteralPath $flowFixtureRoot) {
                    throw 'Production flow fixture cleanup was incomplete.'
                }
            }
            catch {
                $row.status = 'failed'
                $row.failure_reason = 'flow_fixture_cleanup_failed'
            }
        }
    }
    [pscustomobject]$row
}

function Write-ResultDocument {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][object] $Result
    )

    $resultPath = Join-Path $Root 'result.json'
    $temporaryPath = Join-Path $Root 'result.json.tmp'
    foreach ($path in @($resultPath, $temporaryPath)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The result output is unsafe.'
            }
        }
    }
    $json = $Result | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $resultPath -Force
}

function Initialize-TestExecutionState {
    if (-not ('DarkReNamerVmExecutionState' -as [type])) {
        Add-Type @'
using System.Runtime.InteropServices;

public static class DarkReNamerVmExecutionState {
    public const uint RequiredForSuite = 0x80000003;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint executionState);
}
'@
    }
}

function Enter-TestExecutionState {
    Initialize-TestExecutionState
    $previous = [DarkReNamerVmExecutionState]::SetThreadExecutionState(
        [DarkReNamerVmExecutionState]::RequiredForSuite
    )
    if ($previous -eq 0) {
        throw 'Windows refused the temporary test execution-state request.'
    }
    [uint32]$previous
}

function Exit-TestExecutionState {
    param([AllowNull()][object] $Previous)

    if ($null -eq $Previous) {
        return
    }
    if ([DarkReNamerVmExecutionState]::SetThreadExecutionState([uint32]$Previous) -eq 0) {
        throw 'Windows refused to restore the previous test execution state.'
    }
}

function Enter-DesktopTestLock {
    param([Parameter(Mandatory)][int] $SessionId)

    # Local named objects are shared by processes on this interactive desktop
    # without blocking independent test desktops in other Windows sessions.
    $name = 'Local\DarkReNamerVmDesktopTests-' + $SessionId
    $mutex = [Threading.Mutex]::new($false, $name)
    $held = $false
    try {
        try {
            $held = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $held = $true
        }
        if (-not $held) {
            $mutex.Dispose()
            return $null
        }
        [pscustomobject]@{ mutex = $mutex; held = $true; name = $name }
    }
    catch {
        if ($held) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
        throw
    }
}

function Exit-DesktopTestLock {
    param([AllowNull()][object] $Lock)

    if ($null -eq $Lock) {
        return
    }
    try {
        if ($Lock.held) {
            $Lock.mutex.ReleaseMutex()
            $Lock.held = $false
        }
    }
    finally {
        $Lock.mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$verified = Resolve-VerifiedBundle -Root $BundleRoot -InvokedScriptPath $PSCommandPath
if ($ValidateOnly) {
    $validatedSource = if ($verified.manifest.schema_version -eq 2) {
        $verified.manifest.product.source_sha
    } else {
        $verified.manifest.source_sha
    }
    Write-Host "Validated Windows VM bundle for source $validatedSource."
    return
}

$candidateLane = $verified.manifest.schema_version -eq 2
$result = if ($candidateLane) {
    [ordered]@{
        schema_version = 2
        lane = $verified.manifest.lane
        target = $verified.manifest.target
        product = $verified.manifest.product
        harness = $verified.manifest.harness
        status = 'failed'
        tests = @()
        gui = $null
        failure_reason = $null
    }
} else {
    [ordered]@{
        schema_version = 1
        source_sha = $verified.manifest.source_sha
        source_state = $verified.manifest.source_state
        target = $verified.manifest.target
        status = 'failed'
        tests = @()
        gui = $null
        failure_reason = $null
    }
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    $result.failure_reason = 'unsupported_platform'
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution requires Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $result.failure_reason = 'elevated_runner'
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution must be non-elevated.'
}
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($currentSession -ne $ExpectedSessionId) {
    $result.failure_reason = 'unexpected_session'
    Write-ResultDocument -Root $verified.root -Result $result
    throw 'Windows VM guest execution is in an unexpected session.'
}

$desktopLock = $null
$previousExecutionState = $null
$runtimeRoot = $null
try {
    $desktopLock = Enter-DesktopTestLock -SessionId $currentSession
    if ($null -eq $desktopLock) {
        $result.failure_reason = 'desktop_busy'
        throw 'Another Windows VM test runner is using this interactive desktop.'
    }
    $previousExecutionState = Enter-TestExecutionState
    $runtimeRoot = New-PrivateDirectory -Parent $verified.root -Leaf 'runtime'
    $testResults = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $verified.tests.Count; $index++) {
        $testResults.Add((Invoke-RustTestBinary `
            -Test $verified.tests[$index] `
            -Root $verified.root `
            -RuntimeRoot $runtimeRoot `
            -Index ($index + 1) `
            -TimeoutSeconds $TestTimeoutSeconds))
        $result.tests = $testResults.ToArray()
    }
    $applicationArtifact = if ($candidateLane) {
        $verified.manifest.product.application
    } else {
        $verified.manifest.application
    }
    $result.gui = Invoke-GuiSmoke `
        -Application $applicationArtifact `
        -Root $verified.root `
        -RuntimeRoot $runtimeRoot `
        -ExpectedSession $ExpectedSessionId `
        -TimeoutSeconds $TestTimeoutSeconds `
        -RawEvidence:$candidateLane

    $testFailures = @($result.tests | Where-Object { $_.status -cne 'passed' })
    if ($testFailures.Count -eq 0 -and $result.gui.status -ceq 'passed' -and
        ($candidateLane -or $result.tests.Count -gt 0)) {
        $result.status = 'passed'
    }
}
catch {
    $result.status = 'failed'
    if ($null -eq $result.failure_reason) {
        $result.failure_reason = 'runner_error'
    }
}
finally {
    try {
        try {
            Exit-TestExecutionState -Previous $previousExecutionState
        }
        catch {
            $result.status = 'failed'
            $result.failure_reason = 'execution_state_restore_failed'
        }
        if ($candidateLane -and $null -ne $runtimeRoot) {
            $journalAfter = $null
            $journalObserved = $false
            $runtimeRootAfter = $null
            try {
                $journalAfter = @(if ($null -ne $result.gui -and
                    $null -ne $result.gui.flow -and
                    @($result.gui.flow.raw_checkpoints).Count -gt 0) {
                    @(@($result.gui.flow.raw_checkpoints)[-1].journal_entries)
                } else {
                    @(Get-VmAutomatedJournalInventory -LocalAppData (Join-Path $runtimeRoot 'gui\localappdata'))
                })
                $journalObserved = $true
                $ownedAfter = @(Get-VmAutomatedOwnedProcessInventory -Root $verified.root)
                if ($ownedAfter.Count -ne 0) {
                    throw 'An owned candidate process remains after the GUI flow.'
                }
                if (Test-Path -LiteralPath $runtimeRoot) {
                    [void](Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot)
                    Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
                }
                $runtimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot
                $result['raw_cleanup'] = [ordered]@{
                    owned_processes_after = $ownedAfter
                    runtime_root_after = $runtimeRootAfter
                    journal_after = (New-VmAutomatedJournalCleanupObservation `
                        -Observed $journalObserved -Entries $journalAfter)
                }
            }
            catch {
                $result.status = 'failed'
                $result.failure_reason = 'raw_cleanup_failed'
                try {
                    $runtimeRootAfter = Get-VmAutomatedRuntimeRootObservation -Root $runtimeRoot
                }
                catch {
                    $runtimeRootAfter = $null
                }
                $result['raw_cleanup'] = [ordered]@{
                    owned_processes_after = @(Get-VmAutomatedOwnedProcessInventory -Root $verified.root)
                    runtime_root_after = $runtimeRootAfter
                    journal_after = (New-VmAutomatedJournalCleanupObservation `
                        -Observed $journalObserved -Entries $journalAfter)
                }
            }
        }
        Write-ResultDocument -Root $verified.root -Result $result
    }
    finally {
        Exit-DesktopTestLock -Lock $desktopLock
    }
}
if ($result.status -cne 'passed') {
    throw 'Windows VM guest validation failed; inspect result.json.'
}
