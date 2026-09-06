[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Fails {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $Expected
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) {
            throw "Expected failure containing '$Expected', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected failure containing '$Expected'."
}

function Get-Sha256([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8Json {
    param([string] $Path, [object] $Value)

    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}

function New-AcceptanceFixture {
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $SourceState = 'clean'
    )

    $taskRoot = Join-Path $script:temporaryRoot $Name
    $bundleRoot = Join-Path $taskRoot 'bundle'
    [void](New-Item -ItemType Directory -Path $bundleRoot)
    $acceptancePath = Join-Path $taskRoot 'windows-vm-acceptance.ps1'
    $runnerPath = Join-Path $bundleRoot 'windows-vm-guest.ps1'
    Copy-Item -LiteralPath $script:acceptance -Destination $acceptancePath
    Copy-Item -LiteralPath $script:runner -Destination $runnerPath
    [IO.File]::WriteAllText((Join-Path $bundleRoot 'DarkReNamer.exe'), 'application fixture')
    [IO.File]::WriteAllText((Join-Path $bundleRoot 'fixture-tests.exe'), 'test fixture')
    $manifest = [ordered]@{
        schema_version = 1
        source_sha = '0123456789abcdef0123456789abcdef01234567'
        source_state = $SourceState
        target = 'x86_64-pc-windows-msvc'
        cargo_lock_sha256 = '1' * 64
        test_binaries = @(
            [ordered]@{
                name = 'fixture-tests'
                file = 'fixture-tests.exe'
                sha256 = Get-Sha256 (Join-Path $bundleRoot 'fixture-tests.exe')
            }
        )
        application = [ordered]@{
            file = 'DarkReNamer.exe'
            sha256 = Get-Sha256 (Join-Path $bundleRoot 'DarkReNamer.exe')
        }
        runner = [ordered]@{
            file = 'windows-vm-guest.ps1'
            sha256 = Get-Sha256 $runnerPath
        }
    }
    Write-Utf8Json -Path (Join-Path $bundleRoot 'bundle.json') -Value $manifest
    [pscustomobject]@{
        task_root = $taskRoot
        bundle_root = $bundleRoot
        output_root = Join-Path $taskRoot 'out'
        acceptance = $acceptancePath
        acceptance_sha256 = Get-Sha256 $acceptancePath
        runner = $runnerPath
        manifest = $manifest
    }
}

function Invoke-ValidateOnly([object] $Fixture) {
    & $Fixture.acceptance `
        -BundleRoot $Fixture.bundle_root `
        -ExpectedSessionId 1 `
        -OutputRoot $Fixture.output_root `
        -ExpectedScriptSha256 $Fixture.acceptance_sha256 `
        -ValidateOnly
}

$acceptance = Join-Path $PSScriptRoot 'windows-vm-acceptance.ps1'
$runner = Join-Path $PSScriptRoot 'windows-vm-guest.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'darkrenamer-vm-acceptance-' + [Guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $temporaryRoot)
try {
    foreach ($path in @($acceptance, $MyInvocation.MyCommand.Path)) {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or
            $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
            throw "$([IO.Path]::GetFileName($path)) must retain its UTF-8 BOM for Windows PowerShell 5.1."
        }
        $parseErrors = $null
        $parseTokens = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$parseTokens,
            [ref]$parseErrors
        )
        if ($parseErrors.Count -ne 0) {
            throw "$([IO.Path]::GetFileName($path)) has PowerShell parser errors."
        }
    }

    . $acceptance `
        -BundleRoot 'unused' `
        -ExpectedSessionId 1 `
        -OutputRoot 'unused' `
        -ExpectedScriptSha256 ('0' * 64) `
        -ValidateOnly
    if ((Get-AcceptanceVerdict -KeyboardStatus passed -AccessibilityStatus passed -CaptureStatus passed) -cne 'review_required') {
        throw 'Complete technical evidence must retain the visual-review requirement.'
    }
    if ((Get-AcceptanceVerdict -KeyboardStatus failed -AccessibilityStatus passed -CaptureStatus passed) -cne 'failed') {
        throw 'A failed technical lane must fail the acceptance verdict.'
    }
    if ((Get-AcceptanceVerdict -KeyboardStatus passed -AccessibilityStatus not_run -CaptureStatus passed) -cne 'not_run') {
        throw 'Incomplete technical evidence must remain not-run.'
    }
    Assert-Fails {
        Get-AcceptanceVerdict -KeyboardStatus unknown -AccessibilityStatus passed -CaptureStatus passed
    } 'status is invalid'

    $valid = New-AcceptanceFixture -Name 'valid'
    Invoke-ValidateOnly $valid
    if (Test-Path -LiteralPath $valid.output_root) {
        throw 'ValidateOnly must not create acceptance output.'
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Assert-Fails {
            & $valid.acceptance `
                -BundleRoot $valid.bundle_root `
                -ExpectedSessionId 1 `
                -OutputRoot $valid.output_root `
                -ExpectedScriptSha256 $valid.acceptance_sha256
        } 'acceptance requires Windows'
        if (Test-Path -LiteralPath $valid.output_root) {
            throw 'The unsupported-platform guard must run before creating acceptance output.'
        }
    }

    Assert-Fails {
        & $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 ('0' * 64) `
            -ValidateOnly
    } 'Acceptance script hash mismatch'

    Assert-Fails {
        & $valid.acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot (Join-Path $valid.task_root 'different-output') `
            -ExpectedScriptSha256 $valid.acceptance_sha256 `
            -ValidateOnly
    } 'task bundle out directory'

    Assert-Fails {
        & $acceptance `
            -BundleRoot $valid.bundle_root `
            -ExpectedSessionId 1 `
            -OutputRoot $valid.output_root `
            -ExpectedScriptSha256 (Get-Sha256 $acceptance) `
            -ValidateOnly
    } 'task-bundled acceptance artifact'

    $dirty = New-AcceptanceFixture -Name 'dirty' -SourceState 'dirty'
    Assert-Fails { Invoke-ValidateOnly $dirty } 'clean source-bound bundle'

    $changedRunner = New-AcceptanceFixture -Name 'changed-runner'
    [IO.File]::AppendAllText($changedRunner.runner, "`n# changed")
    Assert-Fails { Invoke-ValidateOnly $changedRunner } 'Windows VM helper hash mismatch'

    $occupiedOutput = New-AcceptanceFixture -Name 'occupied-output'
    [void](New-Item -ItemType Directory -Path $occupiedOutput.output_root)
    Assert-Fails { Invoke-ValidateOnly $occupiedOutput } 'already exists'

    Write-Host 'Windows VM current-DPI acceptance contract tests passed.'
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}
