[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LeadingSpaceCount {
    param(
        [Parameter(Mandatory)]
        [string] $Line
    )

    $Line.Length - $Line.TrimStart(' ').Length
}

function Get-PowerShellRunBlocks {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $lines = @(Get-Content -LiteralPath $Path)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = [regex]::Match($lines[$index], '^(\s*)run:\s*(\||>-)\s*$')
        if (-not $match.Success) {
            continue
        }

        $runIndent = $match.Groups[1].Value.Length
        $blockIndent = $runIndent + 2
        $blockLines = [Collections.Generic.List[string]]::new()
        $cursor = $index + 1
        while ($cursor -lt $lines.Count) {
            $line = $lines[$cursor]
            if ([string]::IsNullOrWhiteSpace($line)) {
                $blockLines.Add('')
                $cursor++
                continue
            }
            if ((Get-LeadingSpaceCount -Line $line) -le $runIndent) {
                break
            }
            if ($line.Length -lt $blockIndent) {
                throw "Workflow run block has invalid indentation at ${Path}:$($cursor + 1)."
            }
            $blockLines.Add($line.Substring($blockIndent))
            $cursor++
        }
        if ($blockLines.Count -eq 0) {
            throw "Workflow run block is empty at ${Path}:$($index + 1)."
        }

        $script = if ($match.Groups[2].Value -eq '>-') {
            (($blockLines | ForEach-Object { $_.Trim() }) -join ' ')
        }
        else {
            $blockLines -join "`n"
        }
        [pscustomobject]@{
            path = $Path
            line = $index + 1
            script = $script
        }
        $index = $cursor - 1
    }
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workflows = @(
    Join-Path $repositoryRoot '.github/workflows/release.yaml'
    Join-Path $repositoryRoot '.github/workflows/promote-release.yaml'
)
$blockCount = 0
foreach ($workflow in $workflows) {
    foreach ($block in Get-PowerShellRunBlocks -Path $workflow) {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseInput(
            $block.script,
            [ref] $tokens,
            [ref] $errors
        ) | Out-Null
        if ($errors.Count -ne 0) {
            $details = ($errors | ForEach-Object { $_.Message }) -join '; '
            throw "PowerShell workflow syntax error at $($block.path):$($block.line): $details"
        }
        $blockCount++
    }
}
if ($blockCount -le 0) {
    throw 'No PowerShell workflow run blocks were found.'
}

Write-Host "Release workflow PowerShell syntax tests passed for $blockCount run blocks."
