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
    Join-Path $repositoryRoot '.github/workflows/binary-size-matrix.yaml'
    Join-Path $repositoryRoot '.github/workflows/profile-benchmark-matrix.yaml'
    Join-Path $repositoryRoot '.github/workflows/profile-planning-matrix.yaml'
    Join-Path $repositoryRoot '.github/workflows/release.yaml'
    Join-Path $repositoryRoot '.github/workflows/promote-release.yaml'
)

$promotionWorkflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/promote-release.yaml') -Raw
$candidateWorkflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/release.yaml') -Raw
if ($promotionWorkflow -notmatch "(?m)^\s+if: github\.ref == 'refs/heads/master'\s*$") {
    throw 'The release promotion job must reject workflow dispatches from refs other than master.'
}
if ($promotionWorkflow -notmatch '(?m)^\s+environment:\s*\r?\n\s+name: release\s*$') {
    throw 'The release promotion job must use the repository release environment.'
}
if ($candidateWorkflow -notmatch '(?m)^\s+cargo install --locked cargo-about --version 0\.9\.2 --features cli\s*$') {
    throw 'The candidate workflow must install the pinned cargo-about 0.9.2 CLI from crates.io.'
}
if ($candidateWorkflow -notmatch '(?ms)^\s+cargo about generate --locked --workspace --fail about\.hbs `\r?\n\s+--output-file dist/THIRD_PARTY_LICENSES\.html\s*$') {
    throw 'The candidate workflow must generate the tracked third-party license template into the handoff.'
}
if ($promotionWorkflow -notmatch '(?m)^\s+dist/THIRD_PARTY_LICENSES\.html `\s*$') {
    throw 'The promotion workflow must publish the generated third-party license bundle.'
}

$aboutConfigPath = Join-Path $repositoryRoot 'about.toml'
if (-not (Test-Path -LiteralPath $aboutConfigPath -PathType Leaf)) {
    throw 'The tracked cargo-about configuration is missing.'
}
$aboutConfig = Get-Content -LiteralPath $aboutConfigPath -Raw
foreach ($requiredConfig in @(
    'targets = ["x86_64-pc-windows-msvc"]'
    'ignore-build-dependencies = false'
    'ignore-dev-dependencies = true'
    'ignore-transitive-dependencies = false'
    'private = { ignore = true }'
)) {
    if (-not $aboutConfig.Contains($requiredConfig, [StringComparison]::Ordinal)) {
        throw "about.toml is missing the required release graph setting: $requiredConfig"
    }
}

$aboutTemplatePath = Join-Path $repositoryRoot 'about.hbs'
if (-not (Test-Path -LiteralPath $aboutTemplatePath -PathType Leaf)) {
    throw 'The tracked cargo-about HTML template is missing.'
}
$aboutTemplate = Get-Content -LiteralPath $aboutTemplatePath -Raw
foreach ($requiredTemplateText in @(
    '<title>Third-party licenses for DarkReNamer</title>'
    '{{#each licenses}}'
    '{{#each used_by}}'
    '{{text}}'
)) {
    if (-not $aboutTemplate.Contains($requiredTemplateText, [StringComparison]::Ordinal)) {
        throw "about.hbs is missing required deterministic template content: $requiredTemplateText"
    }
}
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

$versionPattern = '(?m)^version = "([^"]+)"\r?$'
foreach ($newline in "`n", "`r`n") {
    $cargoFixture = "[workspace]${newline}${newline}[workspace.package]${newline}version = `"0.1.0`"${newline}"
    $matches = [regex]::Matches($cargoFixture, $versionPattern)
    if ($matches.Count -ne 1 -or $matches[0].Groups[1].Value -cne '0.1.0') {
        throw 'Release version parsing must accept exactly one LF or CRLF workspace version line.'
    }
}

Write-Host "Release workflow PowerShell syntax tests passed for $blockCount run blocks."
