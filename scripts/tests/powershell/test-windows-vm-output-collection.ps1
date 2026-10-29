[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../support/paths.ps1')
$toolingTestPaths = Get-ToolingTestPaths
. (Join-Path $toolingTestPaths.ScriptsRoot 'tests/support/windows-vm-module-loader.ps1')
foreach ($definition in @(Get-DrTestDefinitionScriptBlocks -Kind controller)) { . $definition }

function New-Capture([string] $Name, [long] $Bytes = 100) {
    [pscustomobject]@{ file = $Name; sha256 = ('a' * 64); bytes = $Bytes }
}
function Assert-Rejected([scriptblock] $Action, [string] $Expected) {
    try { & $Action | Out-Null }
    catch {
        if (-not $_.Exception.Message.Contains($Expected, [StringComparison]::Ordinal)) {
            throw "Expected '$Expected', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected rejection containing '$Expected'."
}

$gui = [pscustomobject]@{
    flow = [pscustomobject]@{ prefix_prompt_capture = (New-Capture 'ko-prefix.png') }
    language_checks = [pscustomobject]@{
        selections = @([pscustomobject]@{
            startup_capture = (New-Capture 'en-startup.png')
            blocked_recovery = [pscustomobject]@{ notice_capture = (New-Capture 'en-blocked.png') }
        })
        flows = @([pscustomobject]@{
            flow = [pscustomobject]@{
                prefix_prompt_capture = (New-Capture 'en-prefix.png')
                screenshots = @((New-Capture 'en-cancel.png'), (New-Capture 'en-apply.png'))
            }
        })
        valid_active_recovery = [pscustomobject]@{
            observations = @([pscustomobject]@{ notice_capture = (New-Capture 'ja-recovery.png') })
        }
    }
}
$actual = @(Get-CoreLanguageCaptureOutputs -Gui $gui)
$expected = @('ko-prefix.png', 'en-startup.png', 'en-blocked.png', 'en-prefix.png',
    'en-cancel.png', 'en-apply.png', 'ja-recovery.png')
if (($actual.file -join ',') -cne ($expected -join ',') -or
    @($actual | Where-Object { $_.bytes -ne 100 -or $_.sha256 -cne ('a' * 64) }).Count -ne 0) {
    throw 'Nested language captures were omitted or changed during host selection.'
}
foreach ($empty in @($null, [pscustomobject]@{}, [pscustomobject]@{ language_checks = $null })) {
    if (@(Get-CoreLanguageCaptureOutputs -Gui $empty).Count -ne 0) {
        throw 'A legacy or partial GUI result unexpectedly selected a capture.'
    }
}
foreach ($bad in @(
        [pscustomobject]@{ file = '../escape.png'; sha256 = ('a' * 64); bytes = 100 },
        [pscustomobject]@{ file = 'CON.png'; sha256 = ('a' * 64); bytes = 100 },
        [pscustomobject]@{ file = 'text.txt'; sha256 = ('a' * 64); bytes = 100 },
        [pscustomobject]@{ file = 'bad.png'; sha256 = ('A' * 64); bytes = 100 },
        [pscustomobject]@{ file = 'bad.png'; sha256 = ('a' * 64); bytes = '100' },
        [pscustomobject]@{ file = 'bad.png'; sha256 = ('a' * 64); bytes = $true },
        (New-Capture 'empty.png' 0), (New-Capture 'large.png' (8MB + 1)))) {
    $gui.flow.prefix_prompt_capture = $bad
    $expectedFailure = if ($bad.file -in @('../escape.png', 'CON.png')) { 'Invalid' }
        else { 'reference' }
    Assert-Rejected { Get-CoreLanguageCaptureOutputs -Gui $gui } $expectedFailure
}
$gui.flow.prefix_prompt_capture = New-Capture 'en-startup.png'
Assert-Rejected { Get-CoreLanguageCaptureOutputs -Gui $gui } 'duplicate'
$gui.flow.prefix_prompt_capture = New-Capture 'ko-prefix.png' 8MB
$gui.language_checks.flows[0].flow.screenshots = @(
    1..6 | ForEach-Object { New-Capture "aggregate-$_.png" 8MB }
)
Assert-Rejected { Get-CoreLanguageCaptureOutputs -Gui $gui } 'aggregate'
$gui.language_checks.flows[0].flow.screenshots = @(
    1..33 | ForEach-Object { New-Capture "count-$_.png" }
)
Assert-Rejected { Get-CoreLanguageCaptureOutputs -Gui $gui } 'count'
Write-Host 'Core language output collection contracts passed.'
