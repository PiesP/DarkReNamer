[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/windows-vm-module-loader.ps1')
$scriptsRoot = (Get-ToolingTestPaths).ScriptsRoot
$environmentNames = @(
    'DARKRENAMER_VM_ELEVATED_OBSERVER'
    'DARKRENAMER_VM_TRUSTED_RESULT_PATH'
    'DARKRENAMER_VM_EXPECTED_SESSION_ID'
)
$original = @{}
foreach ($name in $environmentNames) {
    $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('darkrenamer-observer-env-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $temporaryRoot
    foreach ($kind in @('guest', 'ui', 'recovery')) {
        $spec = Get-DrTestPowerShellModuleSpec -Kind $kind
        $filename = switch ($kind) {
            'guest' { 'windows-vm-guest.ps1' }
            'ui' { 'windows-vm-acceptance.ps1' }
            'recovery' { 'windows-vm-recovery-acceptance.ps1' }
        }
        foreach ($failure in @('none', 'module', 'bootstrap')) {
            $root = Join-Path $temporaryRoot "$kind-$failure"
            $null = New-Item -ItemType Directory -Path $root
            $entrypoint = Join-Path $root $filename
            Copy-Item -LiteralPath (Join-Path $scriptsRoot $filename) -Destination $entrypoint
            $null = New-DrTestFrozenToolingBundle -TaskRoot $root -Kind $kind -EntrypointPaths @($entrypoint)
            $body = if ($failure -ceq 'module') { "throw 'observer fixture failure'" } else {
                '[pscustomobject]@{ elevated = $env:DARKRENAMER_VM_ELEVATED_OBSERVER; trusted = $env:DARKRENAMER_VM_TRUSTED_RESULT_PATH; session = $env:DARKRENAMER_VM_EXPECTED_SESSION_ID }'
            }
            $modulePath = Join-Path $root "$kind-entry.psm1"
            [IO.File]::WriteAllText($modulePath,
                "param(`$Libraries)`nfunction $($spec.command) { $body }`nExport-ModuleMember -Function $($spec.command)`n",
                [Text.UTF8Encoding]::new($true))
            $manifestPath = Join-Path $root 'tooling-bundle.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $record = $manifest.modules | Where-Object role -CEQ "powershell-$kind-entry"
            $record.sha256 = Get-DrTestFileSha256 -Path $modulePath
            $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8
            Set-DrTestEntrypointToolingPins -EntrypointPaths @($entrypoint) `
                -ManifestSha256 (Get-DrTestFileSha256 -Path $manifestPath) `
                -LoaderSha256 (Get-DrTestFileSha256 -Path (Join-Path $root 'tooling-loader.ps1'))
            if ($failure -ceq 'bootstrap') { [IO.File]::AppendAllText($manifestPath, ' ') }
            foreach ($elevated in @($false, $true)) {
                $before = @{
                    DARKRENAMER_VM_ELEVATED_OBSERVER = 'caller-value'
                    DARKRENAMER_VM_TRUSTED_RESULT_PATH = $null
                    DARKRENAMER_VM_EXPECTED_SESSION_ID = 'caller-session'
                }
                foreach ($name in $environmentNames) {
                    if ($null -eq $before[$name]) {
                        [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
                    }
                    else {
                        [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process')
                    }
                }
                $parameters = @{
                    BundleRoot = $root
                    ExpectedSessionId = 42
                    ElevatedObserver = $elevated
                    TrustedResultPath = (Join-Path $root 'result.json')
                    ValidateOnly = $true
                }
                if ($kind -cne 'guest') {
                    $parameters.OutputRoot = $root
                    $parameters.ExpectedScriptSha256 = 'a' * 64
                }
                if ($kind -ceq 'recovery') {
                    $parameters.PrivateEvidenceRoot = (Join-Path $root 'private')
                }
                $caught = $null
                try { $observed = & $entrypoint @parameters }
                catch { $caught = $_ }
                foreach ($name in $environmentNames) {
                    if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne $before[$name]) {
                        throw "Observer $kind leaked $name after $failure (elevated=$elevated)."
                    }
                }
                if ($failure -ceq 'none') {
                    if ($null -ne $caught) { throw $caught }
                    if ($elevated) {
                        if ($observed.elevated -cne '1' -or $observed.session -cne '42' -or
                            $observed.trusted -cne $parameters.TrustedResultPath) {
                            throw 'Elevated observer did not receive its scoped environment.'
                        }
                    }
                    elseif ($observed.elevated -or $observed.trusted -or $observed.session) {
                        throw 'Ordinary observer inherited privileged environment values.'
                    }
                }
                elseif ($null -eq $caught -or
                    ($failure -ceq 'module' -and $caught.Exception.Message -cne 'observer fixture failure') -or
                    ($failure -ceq 'bootstrap' -and $caught.Exception.Message -notlike '*mismatch*')) {
                    throw "Observer $kind did not report the expected $failure failure: $caught"
                }
            }
        }
    }
}
finally {
    foreach ($name in $environmentNames) {
        if ($null -eq $original[$name]) {
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
Write-Host 'Observer environment lifecycle tests passed.'
