function Assert-RecoveryBootstrapUniqueJson {
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
            Assert-RecoveryBootstrapUniqueJson `
                -Element $property.Value `
                -Location "$Location.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-RecoveryBootstrapUniqueJson -Element $item -Location "$Location[$index]"
            $index++
        }
    }
}
function Resolve-AcceptanceBootstrap {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ObserverPath,
        [Parameter(Mandatory)][string] $ExpectedObserverSha256
    )

    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw 'BundleRoot must be absolute.'
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'BundleRoot must be an existing directory.'
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BundleRoot must not be a reparse point.'
    }
    $manifestPath = Join-Path $rootItem.FullName 'bundle.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The bootstrap bundle manifest is missing.'
    }
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force
    if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $manifestItem.Length -gt 1MB) {
        throw 'The bootstrap bundle manifest is unsafe or too large.'
    }
    $manifestText = [IO.File]::ReadAllText($manifestItem.FullName)
    if ($manifestText.IndexOf([char]0) -ge 0) {
        throw 'The bootstrap bundle manifest contains NUL.'
    }
    $manifestDocument = $null
    try {
        $manifestDocument = [Text.Json.JsonDocument]::Parse($manifestText)
        Assert-RecoveryBootstrapUniqueJson `
            -Element $manifestDocument.RootElement `
            -Location 'bundle.json'
        $manifest = $manifestText | ConvertFrom-Json
    }
    catch {
        throw "The bootstrap bundle manifest is not valid unique-key JSON: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $manifestDocument) {
            $manifestDocument.Dispose()
        }
    }
    $candidateLane = $manifest.schema_version -eq 2
    $runner = if ($candidateLane) { $manifest.harness.runner } else { $manifest.runner }
    if ($null -eq $manifest -or $null -eq $runner) {
        throw 'The bootstrap bundle manifest has no runner object.'
    }
    Assert-AcceptanceExactProperties `
        -Value $runner `
        -Names @('file', 'sha256') `
        -Label 'bootstrap runner'
    if ($runner.file -isnot [string] -or
        $runner.file -cne 'windows-vm-guest.ps1') {
        throw 'The bootstrap runner leaf is invalid.'
    }
    if ($runner.sha256 -isnot [string] -or
        $runner.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The bootstrap runner SHA-256 is invalid.'
    }
    if ($candidateLane) {
        $recoveryObserver = $manifest.harness.observers.recovery
        if ($recoveryObserver.file -cne 'windows-vm-recovery-acceptance.ps1' -or
            $recoveryObserver.sha256 -cne $ExpectedObserverSha256) {
            throw 'The bootstrap recovery observer binding is invalid.'
        }
    }
    $runnerPath = Join-Path $rootItem.FullName 'windows-vm-guest.ps1'
    if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
        throw 'The frozen guest helper is missing.'
    }
    $runnerItem = Get-Item -LiteralPath $runnerPath -Force
    if (($runnerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $runnerItem.Length -gt 2MB) {
        throw 'The frozen guest helper must be an ordinary bounded file.'
    }
    $runnerBytes = [IO.File]::ReadAllBytes($runnerItem.FullName)
    $runnerSha256 = Get-AcceptanceBootstrapBytesSha256 -Bytes $runnerBytes
    if ($runnerSha256 -cne $runner.sha256) {
        throw 'The bootstrap runner hash does not match bundle.json.'
    }
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $runnerText = $strictUtf8.GetString($runnerBytes)
    }
    catch {
        throw 'The authenticated guest helper is not valid UTF-8.'
    }
    if ($runnerText.Length -gt 0 -and $runnerText[0] -eq [char]0xFEFF) {
        $runnerText = $runnerText.Substring(1)
    }
    try {
        $runnerScript = [scriptblock]::Create($runnerText)
    }
    catch {
        throw 'The authenticated guest helper has parser errors.'
    }

    if ($ExpectedObserverSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        -not (Test-Path -LiteralPath $ObserverPath -PathType Leaf)) {
        throw 'The recovery acceptance observer bootstrap input is invalid.'
    }
    $observerItem = Get-Item -LiteralPath $ObserverPath -Force
    if ($observerItem.Name -cne 'windows-vm-recovery-acceptance.ps1' -or
        ($observerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The recovery acceptance observer bootstrap file is invalid.'
    }
    $observerSha256 = Get-AcceptanceBootstrapSha256 -Path $observerItem.FullName
    if ($observerSha256 -cne $ExpectedObserverSha256) {
        throw 'The recovery acceptance observer hash does not match its staging contract.'
    }
    [pscustomobject]@{
        root = $rootItem.FullName
        runner_path = $runnerItem.FullName
        runner_script = $runnerScript
        runner_sha256 = $runnerSha256
        observer_sha256 = $observerSha256
    }
}
