function Assert-AcceptanceBootstrapUniqueJson {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)][string] $Location
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "$Location contains a duplicate field: $($property.Name)."
            }
            Assert-AcceptanceBootstrapUniqueJson `
                -Element $property.Value `
                -Location "$Location.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-AcceptanceBootstrapUniqueJson -Element $item -Location "$Location[$index]"
            $index++
        }
    }
}
function Resolve-AcceptanceBootstrap {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][string] $ScriptSha256
    )

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be an absolute directory.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BundleRoot must be an ordinary directory.'
    }
    $resolvedRoot = $rootItem.FullName
    $bundleParent = [IO.Directory]::GetParent($resolvedRoot).FullName
    $expectedScriptPath = Join-Path $bundleParent 'windows-vm-acceptance.ps1'
    $scriptItem = Get-Item -LiteralPath $ScriptPath -Force -ErrorAction Stop
    if ($scriptItem.PSIsContainer -or
        ($scriptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::Equals(
            $scriptItem.FullName,
            $expectedScriptPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'The invoked acceptance script must be the task-bundled acceptance artifact.'
    }
    if ($ScriptSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        (Get-FileHash -LiteralPath $scriptItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne
            $ScriptSha256) {
        throw 'Acceptance script hash mismatch.'
    }

    $manifestPath = Join-Path $resolvedRoot 'bundle.json'
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if ($manifestItem.PSIsContainer -or
        ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $manifestItem.Length -gt 1MB) {
        throw 'bundle.json must be an ordinary bounded file.'
    }
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    $manifestDocument = $null
    try {
        $manifestDocument = [Text.Json.JsonDocument]::Parse($manifestText)
        Assert-AcceptanceBootstrapUniqueJson `
            -Element $manifestDocument.RootElement `
            -Location 'bundle.json'
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
    $candidateLane = $manifest.schema_version -eq 2
    $runner = if ($candidateLane) { $manifest.harness.runner } else { $manifest.runner }
    if ($runner.file -cne 'windows-vm-guest.ps1' -or
        $runner.sha256 -isnot [string] -or
        $runner.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'bundle.json runner binding is invalid.'
    }
    if ($candidateLane) {
        $uiObserver = $manifest.harness.observers.ui
        if ($uiObserver.file -cne 'windows-vm-acceptance.ps1' -or
            $uiObserver.sha256 -cne $ScriptSha256) {
            throw 'bundle.json UI observer binding is invalid.'
        }
    }
    $runnerPath = Join-Path $resolvedRoot 'windows-vm-guest.ps1'
    $runnerItem = Get-Item -LiteralPath $runnerPath -Force -ErrorAction Stop
    if ($runnerItem.PSIsContainer -or
        ($runnerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
            $runner.sha256) {
        throw 'Windows VM helper hash mismatch.'
    }
    [pscustomobject]@{ root = $resolvedRoot; runner = $runnerPath }
}
function Resolve-AcceptanceBundle {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][string] $ScriptSha256,
        [Parameter(Mandatory)][string] $RequestedOutputRoot,
        [Parameter(Mandatory)][int] $SessionId,
        [switch] $AllowExistingOutput
    )

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be an absolute directory.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BundleRoot must be an ordinary directory.'
    }
    $resolvedRoot = $rootItem.FullName
    $bundleParent = [IO.Directory]::GetParent($resolvedRoot).FullName
    $expectedScriptPath = Join-Path $bundleParent 'windows-vm-acceptance.ps1'
    $actualScriptPath = (Get-Item -LiteralPath $ScriptPath -Force -ErrorAction Stop).FullName
    if (-not [string]::Equals(
        $actualScriptPath,
        $expectedScriptPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The invoked acceptance script must be the task-bundled acceptance artifact.'
    }
    if ($ScriptSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'ExpectedScriptSha256 must be a lowercase SHA-256 digest.'
    }
    Assert-OrdinaryFile -Path $actualScriptPath -Label 'acceptance script'
    if ((Get-LowerSha256 -Path $actualScriptPath) -cne $ScriptSha256) {
        throw 'Acceptance script hash mismatch.'
    }

    $runnerPath = Join-Path $resolvedRoot 'windows-vm-guest.ps1'
    Assert-OrdinaryFile -Path $runnerPath -Label 'Windows VM helper'
    $verified = Resolve-VerifiedBundle -Root $resolvedRoot -InvokedScriptPath $runnerPath
    if ($verified.contract.product_source_state -cne 'clean' -or
        $verified.contract.harness_source_state -cne 'clean') {
        throw 'A clean source-bound bundle is required for acceptance evidence.'
    }
    $observer = if ($verified.contract.lane -ceq 'candidate-gui-only') {
        $verified.contract.observers.ui
    }
    else {
        [pscustomobject]@{
            file = 'windows-vm-acceptance.ps1'
            sha256 = $ScriptSha256
        }
    }
    if ($observer.file -cne 'windows-vm-acceptance.ps1' -or
        $observer.sha256 -cne $ScriptSha256) {
        throw 'The invoked UI observer differs from the verified harness role.'
    }
    if (-not [IO.Path]::IsPathRooted($RequestedOutputRoot)) {
        throw 'OutputRoot must be an absolute directory path.'
    }
    $outputRoot = [IO.Path]::GetFullPath($RequestedOutputRoot)
    $expectedOutputRoot = Join-Path $bundleParent 'out'
    if (-not [string]::Equals(
        $outputRoot,
        $expectedOutputRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'OutputRoot must be the task bundle out directory.'
    }
    $outputExists = Test-Path -LiteralPath $outputRoot
    if ($AllowExistingOutput) {
        if (-not $outputExists) {
            throw 'High Contrast rescue requires the existing task bundle out directory.'
        }
        $outputItem = Get-Item -LiteralPath $outputRoot -Force
        if (-not $outputItem.PSIsContainer -or
            ($outputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'High Contrast rescue output must be an ordinary directory.'
        }
    }
    elseif ($outputExists) {
        throw 'The acceptance output directory already exists; preserve it and use a new bundle.'
    }
    [pscustomobject]@{
        root = $resolvedRoot
        output_root = $outputRoot
        lane = $verified.contract.lane
        application = $verified.contract.application
        source_sha = $verified.contract.product_source_sha
        product_source_state = $verified.contract.product_source_state
        harness_source_sha = $verified.contract.harness_source_sha
        harness_source_state = $verified.contract.harness_source_state
        product = if ($verified.contract.lane -ceq 'candidate-gui-only') {
            $verified.manifest.product
        } else { $null }
        harness = if ($verified.contract.lane -ceq 'candidate-gui-only') {
            $verified.manifest.harness
        } else { $null }
        target = $verified.manifest.target
        runner = $verified.contract.runner
        observer = $observer
        runner_sha256 = $verified.contract.runner.sha256
        script_sha256 = $ScriptSha256
    }
}
