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
        $blockMatch = [regex]::Match($lines[$index], '^(\s*)run:\s*(\||>-)\s*$')
        $inlineMatch = [regex]::Match($lines[$index], '^(\s*)run:\s*(.+?)\s*$')
        if (-not $blockMatch.Success -and -not $inlineMatch.Success) {
            continue
        }

        $match = if ($blockMatch.Success) { $blockMatch } else { $inlineMatch }
        $runIndent = $match.Groups[1].Value.Length
        $isPowerShell = $false
        for ($ancestor = $index - 1; $ancestor -ge 0; $ancestor--) {
            if ($lines[$ancestor] -match '^\s+shell:\s*pwsh\s*$') {
                $isPowerShell = $true
                break
            }
            if ((Get-LeadingSpaceCount -Line $lines[$ancestor]) -lt $runIndent) {
                break
            }
        }
        if (-not $isPowerShell) {
            continue
        }

        if ($inlineMatch.Success -and -not $blockMatch.Success) {
            $script = $inlineMatch.Groups[2].Value
            $cursor = $index + 1
        }
        else {
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

        $script = if ($blockMatch.Groups[2].Value -eq '>-') {
            (($blockLines | ForEach-Object { $_.Trim() }) -join ' ')
        }
        else {
            $blockLines -join "`n"
        }
        }
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput(
            $script,
            [ref] $tokens,
            [ref] $errors
        )
        if ($errors.Count -ne 0) {
            $details = ($errors | ForEach-Object { $_.Message }) -join '; '
            throw "PowerShell workflow syntax error at ${Path}:$($index + 1): $details"
        }
        [pscustomobject]@{
            path = $Path
            line = $index + 1
            script = $script
            ast = $ast
        }
        $index = $cursor - 1
    }
}

function Get-ActionLines {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $Name
    )

    # Rust validates these actions from parsed YAML. This only maps that checked set to
    # source lines so command blocks and action steps can share one ordering assertion.
    $escapedName = [regex]::Escape($Name)
    $lines = @(Get-Content -LiteralPath $Path)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^\s+uses:\s+$escapedName@[0-9a-f]{40}(?:\s+#.*)?$") {
            $index + 1
        }
    }
}

function Test-IsNestedDefinition {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst] $Root
    )

    $parent = $Node.Parent
    while ($null -ne $parent -and $parent -ne $Root) {
        if ($parent -is [Management.Automation.Language.FunctionDefinitionAst] -or
            $parent -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
            return $true
        }
        $parent = $parent.Parent
    }
    $false
}

function Test-IsExecutableNode {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst] $Root
    )

    $functionName = $null
    $parent = $Node.Parent
    while ($null -ne $parent -and $parent -ne $Root) {
        if ($parent -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
            return $false
        }
        if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) {
            $functionName = $parent.Name
            break
        }
        $parent = $parent.Parent
    }
    if ($null -eq $functionName) {
        return $true
    }

    $called = @(@($Root.FindAll({
        param($candidate)
        $candidate -is [Management.Automation.Language.CommandAst]
    }, $true)) | Where-Object {
        -not (Test-IsNestedDefinition -Node $_ -Root $Root) -and
        $_.GetCommandName() -ceq $functionName
    })
    $called.Count -gt 0
}

function Get-ExecutableCommands {
    param(
        [Parameter(Mandatory)]
        [object[]] $Blocks
    )

    $sequence = 0
    foreach ($block in $Blocks) {
        $commands = @($block.ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true))
        foreach ($command in $commands) {
            if (-not (Test-IsExecutableNode -Node $command -Root $block.ast)) {
                continue
            }
            [pscustomobject]@{
                path = $block.path
                line = $block.line
                sequence = $sequence
                ast = $command
            }
            $sequence++
        }
    }
}

function Test-CommandContract {
    param(
        [Parameter(Mandatory)]
        [object] $Record,
        [Parameter(Mandatory)]
        [string] $Name,
        [string] $Subcommand,
        [string[]] $BeforeDelimiter = @(),
        [string[]] $AfterDelimiter = @(),
        [string[]] $ForbiddenBeforeDelimiter = @(),
        [string[]] $ForbiddenAfterDelimiter = @(),
        [Collections.IDictionary] $RequiredOptions = @{},
        [switch] $RequireDelimiter
    )

    if ($Record.ast.GetCommandName() -cne $Name) {
        return $false
    }
    $arguments = @($Record.ast.CommandElements | Select-Object -Skip 1 | ForEach-Object {
        $_.Extent.Text.Trim("'`"")
    })
    if ($Subcommand) {
        $subcommandIndex = if ($arguments.Count -gt 0 -and $arguments[0] -ceq $Subcommand) {
            0
        }
        elseif ($arguments.Count -gt 2 -and $arguments[0] -ceq '--config' -and
            $arguments[2] -ceq $Subcommand) {
            2
        }
        else {
            -1
        }
        if ($subcommandIndex -lt 0) {
            return $false
        }
    }
    $delimiter = [Array]::IndexOf($arguments, '--')
    if ($RequireDelimiter -and $delimiter -lt 0) {
        return $false
    }
    $before = if ($delimiter -ge 0) { @($arguments[0..($delimiter - 1)]) } else { $arguments }
    $after = if ($delimiter -ge 0 -and $delimiter + 1 -lt $arguments.Count) {
        @($arguments[($delimiter + 1)..($arguments.Count - 1)])
    }
    else {
        @()
    }
    if ($BeforeDelimiter | Where-Object { $_ -cnotin $before }) {
        return $false
    }
    if ($AfterDelimiter | Where-Object { $_ -cnotin $after }) {
        return $false
    }
    if ($ForbiddenBeforeDelimiter | Where-Object { $_ -cin $before }) {
        return $false
    }
    if ($ForbiddenAfterDelimiter | Where-Object { $_ -cin $after }) {
        return $false
    }
    foreach ($option in $RequiredOptions.GetEnumerator()) {
        $indexes = @(for ($index = 0; $index -lt $before.Count; $index++) {
            if ($before[$index] -ceq $option.Key) {
                $index
            }
        })
        if ($indexes.Count -ne 1 -or $indexes[0] + 1 -ge $before.Count -or
            $before[$indexes[0] + 1] -cne $option.Value) {
            return $false
        }
    }
    $true
}

function Assert-OneCommand {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Commands,
        [Parameter(Mandatory)]
        [string] $Name,
        [string] $Subcommand,
        [string[]] $BeforeDelimiter = @(),
        [string[]] $AfterDelimiter = @(),
        [string[]] $ForbiddenBeforeDelimiter = @(),
        [string[]] $ForbiddenAfterDelimiter = @(),
        [Collections.IDictionary] $RequiredOptions = @{},
        [switch] $RequireDelimiter,
        [Parameter(Mandatory)]
        [string] $Message
    )

    $matches = @($Commands | Where-Object {
        Test-CommandContract `
            -Record $_ `
            -Name $Name `
            -Subcommand $Subcommand `
            -BeforeDelimiter $BeforeDelimiter `
            -AfterDelimiter $AfterDelimiter `
            -ForbiddenBeforeDelimiter $ForbiddenBeforeDelimiter `
            -ForbiddenAfterDelimiter $ForbiddenAfterDelimiter `
            -RequiredOptions $RequiredOptions `
            -RequireDelimiter:$RequireDelimiter
    })
    if ($matches.Count -ne 1) {
        throw "$Message Found $($matches.Count)."
    }
    $matches[0]
}

function Assert-InOrder {
    param(
        [Parameter(Mandatory)]
        [object[]] $Records,
        [Parameter(Mandatory)]
        [string] $Message
    )

    for ($index = 1; $index -lt $Records.Count; $index++) {
        if ($Records[$index - 1].sequence -ge $Records[$index].sequence) {
            throw $Message
        }
    }
}

function Assert-LineOrder {
    param(
        [Parameter(Mandatory)]
        [int[]] $Lines,
        [Parameter(Mandatory)]
        [string] $Message
    )

    for ($index = 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index - 1] -ge $Lines[$index]) {
            throw $Message
        }
    }
}

function Assert-SourceOrder {
    param(
        [Parameter(Mandatory)]
        [object[]] $Records,
        [Parameter(Mandatory)]
        [string] $Message
    )

    for ($index = 1; $index -lt $Records.Count; $index++) {
        $previous = $Records[$index - 1]
        $current = $Records[$index]
        if ($previous.line -gt $current.line -or
            ($previous.line -eq $current.line -and
            $previous.ast.Extent.StartOffset -ge $current.ast.Extent.StartOffset)) {
            throw $Message
        }
    }
}

function Assert-ImmediateNativeExitCheck {
    param(
        [Parameter(Mandatory)]
        [object] $Record,
        [Parameter(Mandatory)]
        [string] $Message
    )

    $commandOffset = $Record.ast.Extent.StartOffset
    $container = $Record.ast.Parent
    $statements = $null
    $statementIndex = -1
    while ($null -ne $container) {
        $property = $container.PSObject.Properties['Statements']
        if ($null -ne $property) {
            $candidateStatements = @($container.Statements)
            for ($index = 0; $index -lt $candidateStatements.Count; $index++) {
                $statement = $candidateStatements[$index]
                if ($statement.Extent.StartOffset -le $commandOffset -and
                    $statement.Extent.EndOffset -ge $Record.ast.Extent.EndOffset) {
                    $statements = $candidateStatements
                    $statementIndex = $index
                    break
                }
            }
        }
        if ($statementIndex -ge 0) {
            break
        }
        $container = $container.Parent
    }
    if ($statementIndex -lt 0 -or $statementIndex + 1 -ge $statements.Count) {
        throw $Message
    }
    $guard = $statements[$statementIndex + 1]
    if ($guard -isnot [Management.Automation.Language.IfStatementAst] -or
        -not $guard.Find({
            param($node)
            $node -is [Management.Automation.Language.BinaryExpressionAst] -and
            $node.Operator -eq [Management.Automation.Language.TokenKind]::Ine -and
            $node.Left.Extent.Text -ceq '$LASTEXITCODE' -and
            $node.Right.Extent.Text -ceq '0'
        }, $true) -or
        -not $guard.Find({
            param($node)
            $node -is [Management.Automation.Language.ThrowStatementAst]
        }, $true)) {
        throw $Message
    }
}

function Assert-Fails {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Action,
        [Parameter(Mandatory)]
        [string] $ExpectedFragment
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message.Contains($ExpectedFragment, [StringComparison]::Ordinal)) {
            return
        }
        throw "Expected failure containing '$ExpectedFragment', got: $($_.Exception.Message)"
    }
    throw "Expected failure containing '$ExpectedFragment'."
}

function New-FixtureBlocks {
    param(
        [Parameter(Mandatory)]
        [string] $Script,
        [string] $Name = 'policy-fixture.ps1'
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $Script,
        [ref] $tokens,
        [ref] $errors
    )
    if ($errors.Count -ne 0) {
        throw "$Name is not valid PowerShell: $(($errors.Message) -join '; ')"
    }
    , [pscustomobject]@{
        path = $Name
        line = 1
        script = $Script
        ast = $ast
    }
}

function ConvertTo-NormalizedAstText {
    param(
        [Parameter(Mandatory)]
        [string] $Text
    )

    ($Text -replace '`\r?\n', ' ' -replace '\s+', ' ').Trim()
}

function Assert-Assignment {
    param(
        [Parameter(Mandatory)]
        [object[]] $Blocks,
        [Parameter(Mandatory)]
        [string] $Left,
        [Parameter(Mandatory)]
        [string] $Right,
        [int] $ExpectedCount = 1,
        [Parameter(Mandatory)]
        [string] $Message
    )

    $matches = @()
    foreach ($block in $Blocks) {
        $assignments = @($block.ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst]
        }, $true))
        foreach ($assignment in $assignments) {
            if ((Test-IsExecutableNode -Node $assignment -Root $block.ast) -and
                (ConvertTo-NormalizedAstText -Text $assignment.Left.Extent.Text) -ceq $Left -and
                (ConvertTo-NormalizedAstText -Text $assignment.Right.Extent.Text) -ceq $Right) {
                $matches += $assignment
            }
        }
    }
    if ($matches.Count -ne $ExpectedCount) {
        throw "$Message Found $($matches.Count)."
    }
}

function Assert-SingleAssignment {
    param(
        [Parameter(Mandatory)]
        [object[]] $Blocks,
        [Parameter(Mandatory)]
        [string] $Left,
        [Parameter(Mandatory)]
        [string] $Right,
        [Parameter(Mandatory)]
        [string] $Message
    )

    $records = @()
    foreach ($block in $Blocks) {
        $assignments = @($block.ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst]
        }, $true))
        foreach ($assignment in $assignments) {
            if ((Test-IsExecutableNode -Node $assignment -Root $block.ast) -and
                (ConvertTo-NormalizedAstText -Text $assignment.Left.Extent.Text) -ceq $Left) {
                $records += [pscustomobject]@{
                    line = $block.line
                    ast = $assignment
                }
            }
        }
    }
    if ($records.Count -ne 1 -or
        (ConvertTo-NormalizedAstText -Text $records[0].ast.Right.Extent.Text) -cne $Right) {
        throw "$Message Found $($records.Count)."
    }
    $records[0]
}

function Assert-HashtableContract {
    param(
        [Parameter(Mandatory)]
        [object[]] $Blocks,
        [Parameter(Mandatory)]
        [Collections.IDictionary] $Required,
        [Parameter(Mandatory)]
        [string] $Message
    )

    $matchingTables = 0
    foreach ($block in $Blocks) {
        $tables = @($block.ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.HashtableAst]
        }, $true))
        foreach ($table in $tables) {
            if (-not (Test-IsExecutableNode -Node $table -Root $block.ast)) {
                continue
            }
            $fields = @{}
            foreach ($pair in $table.KeyValuePairs) {
                $key = $pair.Item1.Extent.Text.Trim("'`"")
                $fields[$key] = ConvertTo-NormalizedAstText -Text $pair.Item2.Extent.Text
            }
            $matches = $true
            foreach ($entry in $Required.GetEnumerator()) {
                if (-not $fields.ContainsKey($entry.Key) -or
                    $fields[$entry.Key] -cne $entry.Value) {
                    $matches = $false
                    break
                }
            }
            if ($matches) {
                $matchingTables++
            }
        }
    }
    if ($matchingTables -ne 1) {
        throw "$Message Found $matchingTables."
    }
}

function Assert-BinaryGuard {
    param(
        [Parameter(Mandatory)]
        [object[]] $Blocks,
        [Parameter(Mandatory)]
        [string] $Left,
        [Parameter(Mandatory)]
        [Management.Automation.Language.TokenKind] $Operator,
        [Parameter(Mandatory)]
        [string] $Right,
        [switch] $PassThru,
        [Parameter(Mandatory)]
        [string] $Message
    )

    $matches = @()
    foreach ($block in $Blocks) {
        $expressions = @($block.ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.BinaryExpressionAst]
        }, $true))
        foreach ($expression in $expressions) {
            if (-not (Test-IsExecutableNode -Node $expression -Root $block.ast) -or
                $expression.Operator -ne $Operator -or
                (ConvertTo-NormalizedAstText -Text $expression.Left.Extent.Text) -cne $Left -or
                (ConvertTo-NormalizedAstText -Text $expression.Right.Extent.Text) -cne $Right) {
                continue
            }
            $parent = $expression.Parent
            while ($null -ne $parent -and
                $parent -isnot [Management.Automation.Language.IfStatementAst]) {
                $parent = $parent.Parent
            }
            if ($null -ne $parent -and $parent.Find({
                param($node)
                $node -is [Management.Automation.Language.ThrowStatementAst]
            }, $true)) {
                $matches += [pscustomobject]@{
                    line = $block.line
                    ast = $expression
                }
            }
        }
    }
    if ($matches.Count -ne 1) {
        throw "$Message Found $($matches.Count)."
    }
    if ($PassThru) {
        $matches[0]
    }
}

function Assert-OutputContract {
    param(
        [Parameter(Mandatory)]
        [object[]] $Blocks,
        [Parameter(Mandatory)]
        [string] $LiteralPath,
        [string] $PathOption = '-LiteralPath',
        [Parameter(Mandatory)]
        [string[]] $RequiredText,
        [Parameter(Mandatory)]
        [string] $Message
    )

    $matches = 0
    foreach ($block in $Blocks) {
        $pipelines = @($block.ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.PipelineAst]
        }, $true))
        foreach ($pipeline in $pipelines) {
            if (-not (Test-IsExecutableNode -Node $pipeline -Root $block.ast)) {
                continue
            }
            $outputCommands = @($pipeline.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Out-File'
            }, $true))
            if ($outputCommands.Count -ne 1) {
                continue
            }
            $record = [pscustomobject]@{ ast = $outputCommands[0] }
            if (-not (Test-CommandContract `
                -Record $record `
                -Name 'Out-File' `
                -RequiredOptions @{ $PathOption = $LiteralPath })) {
                continue
            }
            $strings = @($pipeline.FindAll({
                param($node)
                $node -is [Management.Automation.Language.StringConstantExpressionAst] -or
                $node -is [Management.Automation.Language.ExpandableStringExpressionAst]
            }, $true) | ForEach-Object { $_.Value })
            $text = $strings -join "`n"
            if (-not ($RequiredText | Where-Object {
                -not $text.Contains($_, [StringComparison]::Ordinal)
            })) {
                $matches++
            }
        }
    }
    if ($matches -ne 1) {
        throw "$Message Found $matches."
    }
}

function Assert-CommonTestMembership {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst] $Ast,
        [Parameter(Mandatory)]
        [string[]] $Required
    )

    $assignments = @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$commonTests'
    }, $true))
    if ($assignments.Count -ne 1) {
        throw 'The tooling script must define the common test set exactly once.'
    }
    $members = @($assignments[0].Right.FindAll({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst]
    }, $true) | ForEach-Object { $_.Value })
    foreach ($requiredTest in $Required) {
        if (@($members | Where-Object { $_ -ceq $requiredTest }).Count -ne 1) {
            throw "The shared tooling suite must contain $requiredTest exactly once."
        }
    }
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workflows = @(
    Join-Path $repositoryRoot '.github/workflows/ci.yaml'
    Join-Path $repositoryRoot '.github/workflows/benchmark-planning.yaml'
    Join-Path $repositoryRoot '.github/workflows/binary-size-matrix.yaml'
    Join-Path $repositoryRoot '.github/workflows/profile-benchmark-matrix.yaml'
    Join-Path $repositoryRoot '.github/workflows/profile-planning-matrix.yaml'
    Join-Path $repositoryRoot '.github/workflows/release.yaml'
    Join-Path $repositoryRoot '.github/workflows/promote-release.yaml'
)

$workflowBlocks = @{}
$blockCount = 0
foreach ($workflow in $workflows) {
    $blocks = @(Get-PowerShellRunBlocks -Path $workflow)
    $workflowBlocks[$workflow] = $blocks
    $blockCount += $blocks.Count
}
if ($blockCount -le 0) {
    throw 'No PowerShell workflow run blocks were found.'
}

$ciPath = Join-Path $repositoryRoot '.github/workflows/ci.yaml'
$planningPath = Join-Path $repositoryRoot '.github/workflows/benchmark-planning.yaml'
$binarySizePath = Join-Path $repositoryRoot '.github/workflows/binary-size-matrix.yaml'
$profileBenchmarkPath = Join-Path $repositoryRoot '.github/workflows/profile-benchmark-matrix.yaml'
$profilePlanningPath = Join-Path $repositoryRoot '.github/workflows/profile-planning-matrix.yaml'
$candidatePath = Join-Path $repositoryRoot '.github/workflows/release.yaml'
$promotionPath = Join-Path $repositoryRoot '.github/workflows/promote-release.yaml'

$ciCommands = @(Get-ExecutableCommands -Blocks $workflowBlocks[$ciPath])
$planningCommands = @(Get-ExecutableCommands -Blocks $workflowBlocks[$planningPath])
$binarySizeCommands = @(Get-ExecutableCommands -Blocks $workflowBlocks[$binarySizePath])
$profileBenchmarkCommands = @(Get-ExecutableCommands -Blocks $workflowBlocks[$profileBenchmarkPath])
$profilePlanningCommands = @(Get-ExecutableCommands -Blocks $workflowBlocks[$profilePlanningPath])
$candidateCommands = @(Get-ExecutableCommands -Blocks $workflowBlocks[$candidatePath])
$promotionCommands = @(Get-ExecutableCommands -Blocks $workflowBlocks[$promotionPath])

Assert-Assignment `
    -Blocks $workflowBlocks[$ciPath] `
    -Left '$env:DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES' `
    -Right "'1'" `
    -ExpectedCount 2 `
    -Message 'Windows CI must fail closed in both backend capability lanes.'
Assert-Assignment `
    -Blocks $workflowBlocks[$candidatePath] `
    -Left '$env:DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES' `
    -Right "'1'" `
    -Message 'Candidate validation must fail closed when backend capabilities are unavailable.'

$toolingTokens = $null
$toolingErrors = $null
$toolingAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repositoryRoot 'scripts/test-tooling.ps1'),
    [ref] $toolingTokens,
    [ref] $toolingErrors
)
if ($toolingErrors.Count -ne 0) {
    throw "test-tooling.ps1 is not valid PowerShell: $(($toolingErrors.Message) -join '; ')"
}
$requiredCommonTests = @(
    'test-release-candidate-metadata-validator.ps1'
    'test-prepare-release-cyclonedx.ps1'
    'test-release-workflow-powershell-syntax.ps1'
)
Assert-CommonTestMembership -Ast $toolingAst -Required $requiredCommonTests

$null = Assert-OneCommand `
    -Commands $ciCommands `
    -Name './scripts/test-tooling.ps1' `
    -BeforeDelimiter @('-Platform', 'Ubuntu') `
    -Message 'CI must run the Ubuntu tooling suite once.'
$null = Assert-OneCommand `
    -Commands $ciCommands `
    -Name './scripts/test-tooling.ps1' `
    -BeforeDelimiter @('-Platform', 'Windows') `
    -Message 'CI must run the Windows tooling suite once.'

$null = Assert-OneCommand `
    -Commands $ciCommands `
    -Name 'cargo' `
    -Subcommand 'test' `
    -BeforeDelimiter @('test', '--workspace', '--all-targets', '--all-features', '--locked') `
    -AfterDelimiter @('--nocapture') `
    -ForbiddenBeforeDelimiter @('--release') `
    -RequireDelimiter `
    -Message 'Windows CI must run locked workspace tests with visible output.'
$null = Assert-OneCommand `
    -Commands $ciCommands `
    -Name 'cargo' `
    -Subcommand 'test' `
    -BeforeDelimiter @('test', '--release', '--workspace', '--all-targets', '--all-features', '--locked') `
    -AfterDelimiter @('--nocapture') `
    -RequireDelimiter `
    -Message 'Windows CI must run optimized locked workspace tests with visible output.'
$candidateTest = Assert-OneCommand `
    -Commands $candidateCommands `
    -Name 'cargo' `
    -Subcommand 'test' `
    -BeforeDelimiter @('test', '--workspace', '--all-targets', '--all-features', '--locked') `
    -AfterDelimiter @('--nocapture') `
    -RequireDelimiter `
    -Message 'Candidate validation must run locked workspace tests with visible output.'
$candidateBuild = Assert-OneCommand `
    -Commands $candidateCommands `
    -Name 'cargo' `
    -Subcommand 'build' `
    -BeforeDelimiter @('build', '--release', '--locked', '--package', 'darknamer-app', '--bin', 'DarkReNamer') `
    -Message 'Candidate validation must build the selected release executable.'
$null = Assert-OneCommand `
    -Commands $candidateCommands `
    -Name 'cargo' `
    -Subcommand 'install' `
    -BeforeDelimiter @('install', '--locked', 'cargo-about', '--version', '0.9.2', '--features', 'cli') `
    -RequiredOptions ([ordered]@{
        '--version' = '0.9.2'
        '--features' = 'cli'
    }) `
    -Message 'Candidate validation must install the pinned cargo-about CLI.'
$candidateLicenses = Assert-OneCommand `
    -Commands $candidateCommands `
    -Name 'cargo' `
    -Subcommand 'about' `
    -BeforeDelimiter @('about', 'generate', '--locked', '--workspace', '--fail', 'about.hbs', '--output-file', 'dist/THIRD_PARTY_LICENSES.html') `
    -RequiredOptions @{ '--output-file' = 'dist/THIRD_PARTY_LICENSES.html' } `
    -Message 'Candidate validation must generate the tracked third-party license handoff.'
$null = Assert-OneCommand `
    -Commands $planningCommands `
    -Name 'cargo' `
    -Subcommand 'test' `
    -BeforeDelimiter @('test', '--package', 'darknamer-app', '--test', 'rename_windows_backend', 'benchmark_durable_production_path', '--locked', '--release') `
    -AfterDelimiter @('--ignored', '--exact', '--nocapture', '--test-threads=1') `
    -RequireDelimiter `
    -Message 'Planning benchmark must run the exact ignored backend benchmark with visible output.'
$null = Assert-OneCommand `
    -Commands $binarySizeCommands `
    -Name 'cargo' `
    -Subcommand 'build' `
    -BeforeDelimiter @('build', '--release', '--locked', '--package', 'darknamer-app', '--bin', 'DarkReNamer') `
    -RequiredOptions @{ '--config' = '$configPath' } `
    -Message 'Binary-size workflow must build the selected release executable.'
$null = Assert-OneCommand `
    -Commands $profileBenchmarkCommands `
    -Name 'cargo' `
    -Subcommand 'test' `
    -BeforeDelimiter @('test', '--release', '--locked', '--package', 'darknamer-app', '--test', 'profile_benchmarks', '--no-run') `
    -RequiredOptions @{ '--config' = '$configPath' } `
    -Message 'Profile benchmark must compile its selected harness without running it through Cargo.'
$null = Assert-OneCommand `
    -Commands $profileBenchmarkCommands `
    -Name 'cargo' `
    -Subcommand 'test' `
    -BeforeDelimiter @('test', '--release', '--locked', '--package', 'darknamer-app', '--test', 'profile_benchmarks', 'benchmark_release_profile') `
    -AfterDelimiter @('--ignored', '--exact', '--nocapture', '--test-threads=1') `
    -RequiredOptions @{ '--config' = '$state.config_path' } `
    -RequireDelimiter `
    -Message 'Profile benchmark must execute the measured release profile with visible output.'
$null = Assert-OneCommand `
    -Commands $profilePlanningCommands `
    -Name 'cargo' `
    -Subcommand 'test' `
    -BeforeDelimiter @('test', '--release', '--locked', '--package', 'darknamer-app', '--test', 'rename_windows_backend', '--no-run') `
    -RequiredOptions @{ '--config' = '$configPath' } `
    -Message 'Profile planning workflow must compile its selected harness before direct execution.'
$null = Assert-OneCommand `
    -Commands $profilePlanningCommands `
    -Name 'cargo' `
    -Subcommand 'test' `
    -BeforeDelimiter @('test', '--release', '--locked', '--package', 'darknamer-app', '--test', 'rename_windows_backend', 'benchmark_durable_production_path') `
    -AfterDelimiter @('--ignored', '--exact', '--nocapture', '--test-threads=1') `
    -RequiredOptions @{ '--config' = '$state.config_path' } `
    -RequireDelimiter `
    -Message 'Profile planning workflow must execute the exact ignored benchmark with visible output.'

$candidateMaster = Assert-OneCommand `
    -Commands $candidateCommands `
    -Name 'git' `
    -BeforeDelimiter @('ls-remote', 'origin', 'refs/heads/master') `
    -Message 'Candidate workflow must resolve live origin/master before building.'
$candidateSource = Assert-OneCommand `
    -Commands $candidateCommands `
    -Name 'git' `
    -BeforeDelimiter @('rev-parse', 'HEAD') `
    -Message 'Candidate workflow must resolve the selected source commit.'
$candidateEpoch = Assert-OneCommand `
    -Commands $candidateCommands `
    -Name 'git' `
    -BeforeDelimiter @('show', '-s', '--format=%ct', 'HEAD') `
    -Message 'Candidate workflow must derive SOURCE_DATE_EPOCH from the source commit.'
$candidateHandoff = Assert-OneCommand `
    -Commands $candidateCommands `
    -Name './scripts/validate-release-handoff.ps1' `
    -RequiredOptions ([ordered]@{
        '-SourceRoot' = '$PWD'
        '-HandoffRoot' = '(Join-Path $PWD ''dist'')'
    }) `
    -Message 'Candidate workflow must validate its complete handoff.'
$candidateSbom = Assert-OneCommand `
    -Commands $candidateCommands `
    -Name './scripts/prepare-release-cyclonedx.ps1' `
    -RequiredOptions ([ordered]@{
        '-InputPath' = 'crates/darknamer-app/DarkReNamer_bin_x86_64-pc-windows-msvc.cdx.json'
        '-OutputPath' = 'dist/DarkReNamer.cdx.json'
        '-SerialNumber' = '$cycloneDxSerial'
    }) `
    -Message 'Candidate workflow must prepare the selected executable SBOM.'
Assert-InOrder `
    -Records @(
        $candidateSource,
        $candidateMaster,
        $candidateEpoch,
        $candidateTest,
        $candidateBuild,
        $candidateLicenses,
        $candidateSbom,
        $candidateHandoff
    ) `
    -Message 'Candidate source validation, build, and handoff validation must remain ordered.'
Assert-OutputContract `
    -Blocks $workflowBlocks[$candidatePath] `
    -LiteralPath '$env:GITHUB_ENV' `
    -PathOption '-FilePath' `
    -RequiredText @('SOURCE_DATE_EPOCH=$epoch') `
    -Message 'Candidate workflow must export its source-derived build epoch.'
Assert-BinaryGuard `
    -Blocks $workflowBlocks[$candidatePath] `
    -Left '($remoteMaster[0] -split "`t")[0]' `
    -Operator ([Management.Automation.Language.TokenKind]::Cne) `
    -Right '$sourceCommit' `
    -Message 'Candidate workflow must reject a selected source that differs from live master.'
$candidateCheckoutLines = @(Get-ActionLines -Path $candidatePath -Name 'actions/checkout')
$candidateAttestLines = @(Get-ActionLines -Path $candidatePath -Name 'actions/attest')
$candidateUploadLines = @(Get-ActionLines -Path $candidatePath -Name 'actions/upload-artifact')
if ($candidateCheckoutLines.Count -ne 1 -or $candidateAttestLines.Count -ne 2 -or
    $candidateUploadLines.Count -ne 1) {
    throw 'Candidate action line mapping must match the YAML action policy.'
}
Assert-LineOrder `
    -Lines @(
        $candidateCheckoutLines[0],
        $candidateSource.line,
        $candidateHandoff.line,
        $candidateAttestLines[0],
        $candidateAttestLines[1],
        $candidateUploadLines[0]
    ) `
    -Message 'Candidate checkout, source proof, handoff validation, attestations, and upload must remain ordered.'

$promotionMetadata = Assert-OneCommand `
    -Commands $promotionCommands `
    -Name './scripts/validate-release-candidate-metadata.ps1' `
    -RequiredOptions ([ordered]@{
        '-ExpectedRunId' = '$env:EXPECTED_RUN_ID'
        '-ExpectedRunAttempt' = '$env:EXPECTED_RUN_ATTEMPT'
        '-ExpectedArtifactId' = '$env:EXPECTED_ARTIFACT_ID'
        '-ExpectedSourceSha' = '$env:EXPECTED_SOURCE_SHA'
        '-ExpectedArtifactName' = '$env:EXPECTED_ARTIFACT_NAME'
    }) `
    -Message 'Promotion must validate candidate metadata.'
$promotionHandoff = Assert-OneCommand `
    -Commands $promotionCommands `
    -Name './scripts/validate-release-handoff.ps1' `
    -RequiredOptions ([ordered]@{
        '-SourceRoot' = '$PWD'
        '-HandoffRoot' = '(Join-Path $PWD ''dist'')'
    }) `
    -Message 'Promotion must revalidate candidate handoff bytes.'
$promotionAttestation = Assert-OneCommand `
    -Commands $promotionCommands `
    -Name 'gh' `
    -BeforeDelimiter @('attestation', 'verify', 'dist/DarkReNamer.exe', '--signer-workflow', '--source-digest', '--source-ref', 'refs/heads/master', '--deny-self-hosted-runners') `
    -RequiredOptions ([ordered]@{
        '--repo' = '$env:GITHUB_REPOSITORY'
        '--signer-workflow' = '$env:GITHUB_REPOSITORY/.github/workflows/release.yaml'
        '--source-digest' = '$env:CANDIDATE_SOURCE_SHA'
        '--source-ref' = 'refs/heads/master'
    }) `
    -Message 'Promotion must verify the original candidate attestation.'
$promotionMasterChecks = @($promotionCommands | Where-Object {
    Test-CommandContract -Record $_ -Name 'git' -BeforeDelimiter @('ls-remote', 'origin', 'refs/heads/master')
})
if ($promotionMasterChecks.Count -ne 1) {
    throw "Promotion must revalidate live origin/master exactly once. Found $($promotionMasterChecks.Count)."
}
$promotionAnnotatedTags = @($promotionCommands | Where-Object {
    Test-CommandContract `
        -Record $_ `
        -Name 'git' `
        -BeforeDelimiter @('ls-remote', 'origin', 'refs/tags/$env:RELEASE_TAG^{}')
})
$promotionLightweightTags = @($promotionCommands | Where-Object {
    Test-CommandContract `
        -Record $_ `
        -Name 'git' `
        -BeforeDelimiter @('ls-remote', 'origin', 'refs/tags/$env:RELEASE_TAG')
})
if ($promotionAnnotatedTags.Count -ne 2 -or $promotionLightweightTags.Count -ne 2) {
    throw 'Promotion must validate both annotated and lightweight release tags at authority selection and immediately before publication.'
}
$promotionAnnotatedTag = $promotionAnnotatedTags[-1]
$promotionLightweightTag = $promotionLightweightTags[-1]
$promotionPublish = Assert-OneCommand `
    -Commands $promotionCommands `
    -Name 'gh' `
    -BeforeDelimiter @('release', 'create', '$env:RELEASE_TAG', '--verify-tag', '--prerelease', '--notes-file', 'release-notes.md', 'dist/THIRD_PARTY_LICENSES.html') `
    -RequiredOptions ([ordered]@{
        '--title' = 'DarkReNamer $env:RELEASE_TAG'
        '--notes-file' = 'release-notes.md'
    }) `
    -Message 'Promotion must create the prerelease with the validated tag and release notes.'
Assert-ImmediateNativeExitCheck `
    -Record $promotionPublish `
    -Message 'Promotion must fail immediately when prerelease publication fails.'
Assert-InOrder `
    -Records @(
        $promotionMetadata,
        $promotionHandoff,
        $promotionAttestation,
        $promotionMasterChecks[0],
        $promotionAnnotatedTag,
        $promotionLightweightTag,
        $promotionPublish
    ) `
    -Message 'Promotion validation, live source recheck, and publication must remain ordered.'
Assert-BinaryGuard `
    -Blocks $workflowBlocks[$promotionPath] `
    -Left '$handoff.workflow_run' `
    -Operator ([Management.Automation.Language.TokenKind]::Cne) `
    -Right '$env:CANDIDATE_RUN_ID' `
    -Message 'Promotion must bind handoff provenance to the candidate run.'
Assert-BinaryGuard `
    -Blocks $workflowBlocks[$promotionPath] `
    -Left '$handoff.source_sha' `
    -Operator ([Management.Automation.Language.TokenKind]::Cne) `
    -Right '$env:CANDIDATE_SOURCE_SHA' `
    -Message 'Promotion must bind handoff provenance to the candidate source.'
Assert-BinaryGuard `
    -Blocks $workflowBlocks[$promotionPath] `
    -Left '$handoff.executable.sha256' `
    -Operator ([Management.Automation.Language.TokenKind]::Cne) `
    -Right '$env:EXPECTED_EXE_SHA256' `
    -Message 'Promotion must bind handoff provenance to the candidate executable digest.'
Assert-BinaryGuard `
    -Blocks $workflowBlocks[$promotionPath] `
    -Left '($remoteMaster[0] -split "`t")[0]' `
    -Operator ([Management.Automation.Language.TokenKind]::Cne) `
    -Right '$env:CANDIDATE_SOURCE_SHA' `
    -Message 'Promotion must reject a live master that differs from the candidate source.'
Assert-BinaryGuard `
    -Blocks $workflowBlocks[$promotionPath] `
    -Left '($remoteTag[0] -split "`t")[0]' `
    -Operator ([Management.Automation.Language.TokenKind]::Cne) `
    -Right '$env:CANDIDATE_SOURCE_SHA' `
    -Message 'Promotion must reject a release tag that differs from the candidate source.'
$promotionCheckoutLines = @(Get-ActionLines -Path $promotionPath -Name 'actions/checkout')
$promotionDownloadLines = @(Get-ActionLines -Path $promotionPath -Name 'actions/download-artifact')
if ($promotionCheckoutLines.Count -ne 1 -or $promotionDownloadLines.Count -ne 1) {
    throw 'Promotion action line mapping must match the YAML action policy.'
}
Assert-LineOrder `
    -Lines @(
        $promotionCheckoutLines[0],
        $promotionMetadata.line,
        $promotionDownloadLines[0],
        $promotionHandoff.line,
        $promotionAttestation.line,
        $promotionPublish.line
    ) `
    -Message 'Promotion checkout, metadata validation, download, handoff, attestation, and publication must remain ordered.'

Assert-Assignment `
    -Blocks $workflowBlocks[$planningPath] `
    -Left '$env:DARKRENAMER_BENCH_SOURCE_SHA' `
    -Right '$env:GITHUB_SHA' `
    -Message 'Planning benchmark must bind metrics to the selected workflow source SHA.'

$matrixPolicies = @(
    [pscustomobject]@{
        Path = $binarySizePath
        Commands = $binarySizeCommands
        Fields = [ordered]@{
            measurement_kind = "'release-profile-size-matrix'"
            source_sha = '$env:SOURCE_SHA'
            source_date_epoch = '[long] $env:SOURCE_DATE_EPOCH'
            cargo_toml_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path Cargo.toml'
            cargo_lock_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path Cargo.lock'
            rust_toolchain_toml_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path rust-toolchain.toml'
        }
        BlobPaths = @('Cargo.toml', 'Cargo.lock', 'rust-toolchain.toml')
        ConfigFields = [ordered]@{
            cargo_config_sha256 = '$configHash'
        }
    }
    [pscustomobject]@{
        Path = $profileBenchmarkPath
        Commands = $profileBenchmarkCommands
        Fields = [ordered]@{
            measurement_kind = "'release-profile-cpu-micro-workloads'"
            scope = "'directional-only'"
            selection_evidence = '$false'
            source_sha = '$env:SOURCE_SHA'
            source_date_epoch = '[long] $env:SOURCE_DATE_EPOCH'
            cargo_toml_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path Cargo.toml'
            cargo_lock_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path Cargo.lock'
            rust_toolchain_toml_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path rust-toolchain.toml'
            harness_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path crates/darknamer-app/tests/profile_benchmarks.rs'
        }
        BlobPaths = @(
            'Cargo.toml'
            'Cargo.lock'
            'rust-toolchain.toml'
            'crates/darknamer-app/tests/profile_benchmarks.rs'
        )
        ConfigFields = [ordered]@{
            cargo_config_sha256 = '$variantState[$variant.id].config_hash'
        }
    }
    [pscustomobject]@{
        Path = $profilePlanningPath
        Commands = $profilePlanningCommands
        Fields = [ordered]@{
            measurement_kind = "'release-profile-windows-planning'"
            evidence_class = "'directional-hosted'"
            selection_evidence = '$false'
            execution_performed = '$false'
            physical_storage_or_desktop_acceptance = '$false'
            source_sha = '$env:SOURCE_SHA'
            source_date_epoch = '[long] $env:SOURCE_DATE_EPOCH'
            instrumentation_revision = "'parent-validation-v1'"
            cargo_toml_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path Cargo.toml'
            cargo_lock_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path Cargo.lock'
            rust_toolchain_toml_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path rust-toolchain.toml'
            harness_sha256 = './scripts/get-git-blob-sha256.ps1 -SourceRoot $PWD -Revision $env:SOURCE_SHA -Path crates/darknamer-app/tests/rename_windows_backend.rs'
        }
        BlobPaths = @(
            'Cargo.toml'
            'Cargo.lock'
            'rust-toolchain.toml'
            'crates/darknamer-app/tests/rename_windows_backend.rs'
        )
        ConfigFields = [ordered]@{
            cargo_config_sha256 = '$variantState[$variant.id].config_hash'
        }
    }
)

foreach ($policy in $matrixPolicies) {
    $blocks = $workflowBlocks[$policy.Path]
    Assert-OutputContract `
        -Blocks $blocks `
        -LiteralPath '$env:GITHUB_ENV' `
        -PathOption '-FilePath' `
        -RequiredText @('SOURCE_SHA=$sourceSha') `
        -Message "$($policy.Path) must export its resolved source SHA."
    Assert-OutputContract `
        -Blocks $blocks `
        -LiteralPath '$env:GITHUB_ENV' `
        -PathOption '-FilePath' `
        -RequiredText @('SOURCE_DATE_EPOCH=$sourceEpoch') `
        -Message "$($policy.Path) must export its resolved source timestamp."
    Assert-HashtableContract `
        -Blocks $blocks `
        -Required $policy.Fields `
        -Message "$($policy.Path) must retain its source-bound matrix provenance."
    Assert-HashtableContract `
        -Blocks $blocks `
        -Required $policy.ConfigFields `
        -Message "$($policy.Path) must bind each variant's generated Cargo configuration."
    foreach ($blobPath in $policy.BlobPaths) {
        $null = Assert-OneCommand `
            -Commands $policy.Commands `
            -Name './scripts/get-git-blob-sha256.ps1' `
            -BeforeDelimiter @('-SourceRoot', '$PWD', '-Revision', '$env:SOURCE_SHA', '-Path', $blobPath) `
            -Message "$($policy.Path) must bind the Git blob for $blobPath."
    }
}

$null = Assert-OneCommand `
    -Commands $binarySizeCommands `
    -Name './scripts/measure-windows-binary.ps1' `
    -BeforeDelimiter @('-ExecutablePath', '$executablePath', '-PdbPath', '$pdbPath', '-DebugSymbolsZipPath', '$symbolsPath', '-OutputPath', '$measurementPath') `
    -Message 'Binary-size workflow must use the verified binary measurement script.'
Assert-BinaryGuard `
    -Blocks $workflowBlocks[$profileBenchmarkPath] `
    -Left "`$fields['instrumentation_revision']" `
    -Operator ([Management.Automation.Language.TokenKind]::Cne) `
    -Right "'profile-workloads-v1'" `
    -Message 'Profile benchmark must reject a mismatched instrumentation revision.'
Assert-BinaryGuard `
    -Blocks $workflowBlocks[$profilePlanningPath] `
    -Left "`$fields['instrumentation_revision']" `
    -Operator ([Management.Automation.Language.TokenKind]::Cne) `
    -Right "'parent-validation-v1'" `
    -Message 'Profile planning must reject a mismatched instrumentation revision.'

$cargoAssignment = Assert-SingleAssignment `
    -Blocks $workflowBlocks[$promotionPath] `
    -Left '$cargo' `
    -Right 'Get-Content -LiteralPath Cargo.toml -Raw' `
    -Message 'Promotion must read the selected Cargo workspace version.'
$versionAssignment = Assert-SingleAssignment `
    -Blocks $workflowBlocks[$promotionPath] `
    -Left '$versionMatches' `
    -Right '[regex]::Matches($cargo, ''(?m)^version = "([^"]+)"\r?$'')' `
    -Message 'Promotion must derive one semantic version from Cargo.toml.'
$expectedTagAssignment = Assert-SingleAssignment `
    -Blocks $workflowBlocks[$promotionPath] `
    -Left '$expectedTag' `
    -Right '"v$($versionMatches[0].Groups[1].Value)"' `
    -Message 'Promotion must derive its expected tag from the Cargo version.'
$tagGuard = Assert-BinaryGuard `
    -Blocks $workflowBlocks[$promotionPath] `
    -Left '$env:RELEASE_TAG' `
    -Operator ([Management.Automation.Language.TokenKind]::Cne) `
    -Right '$expectedTag' `
    -PassThru `
    -Message 'Promotion must reject a tag that differs from the Cargo version.'
Assert-SourceOrder `
    -Records @(
        $cargoAssignment,
        $versionAssignment,
        $expectedTagAssignment,
        $tagGuard,
        $promotionMetadata,
        $promotionPublish
    ) `
    -Message 'Cargo version parsing, tag validation, candidate validation, and publication must remain ordered.'
Assert-OutputContract `
    -Blocks $workflowBlocks[$promotionPath] `
    -LiteralPath 'release-notes.md' `
    -RequiredText @(
        'Source-complete Windows prerelease.'
        'exact immutable candidate artifact'
        'not rebuilt during promotion'
        'Desktop acceptance is not complete.'
        'Real Windows 11 interactive UI coverage'
        'physical SSD evidence remain external'
    ) `
    -Message 'Promotion must write the required source-complete and acceptance disclosure.'

# The Rust policy test owns YAML structure, step conditions, permissions, and action pins.
# These fixtures exercise the PowerShell AST boundary used for executable command semantics.
$delimiterFixture = @(New-FixtureBlocks -Script @'
# cargo test --workspace --locked -- --nocapture
Write-Host 'cargo test --workspace --locked -- --nocapture'
cargo test --workspace --locked --nocapture
'@)
$delimiterCommands = @(Get-ExecutableCommands -Blocks $delimiterFixture)
Assert-Fails -Action {
    $null = Assert-OneCommand `
        -Commands $delimiterCommands `
        -Name 'cargo' `
        -Subcommand 'test' `
        -BeforeDelimiter @('test', '--workspace', '--locked') `
        -AfterDelimiter @('--nocapture') `
        -RequireDelimiter `
        -Message 'delimiter fixture'
} -ExpectedFragment 'Found 0'

$subcommandFixture = @(New-FixtureBlocks -Script @'
cargo --locked test --workspace -- --nocapture
'@)
$subcommandCommands = @(Get-ExecutableCommands -Blocks $subcommandFixture)
Assert-Fails -Action {
    $null = Assert-OneCommand `
        -Commands $subcommandCommands `
        -Name 'cargo' `
        -Subcommand 'test' `
        -BeforeDelimiter @('test', '--workspace', '--locked') `
        -AfterDelimiter @('--nocapture') `
        -RequireDelimiter `
        -Message 'subcommand fixture'
} -ExpectedFragment 'Found 0'

$configFixture = @(New-FixtureBlocks -Script @'
cargo --config $unmeasuredPath test --release --locked --package darknamer-app --test profile_benchmarks --no-run
cargo --config $configPath test --config $unmeasuredPath --release --locked --package darknamer-app --test profile_benchmarks --no-run
'@)
$configCommands = @(Get-ExecutableCommands -Blocks $configFixture)
Assert-Fails -Action {
    $null = Assert-OneCommand `
        -Commands $configCommands `
        -Name 'cargo' `
        -Subcommand 'test' `
        -BeforeDelimiter @('test', '--release', '--locked', '--package', 'darknamer-app', '--test', 'profile_benchmarks', '--no-run') `
        -RequiredOptions @{ '--config' = '$configPath' } `
        -Message 'config fixture'
} -ExpectedFragment 'Found 0'

$uninvokedFixture = @(New-FixtureBlocks -Script @'
function Invoke-Decoy {
    cargo test --workspace --locked -- --nocapture
}
'@)
$uninvokedCommands = @(Get-ExecutableCommands -Blocks $uninvokedFixture)
Assert-Fails -Action {
    $null = Assert-OneCommand `
        -Commands $uninvokedCommands `
        -Name 'cargo' `
        -Subcommand 'test' `
        -BeforeDelimiter @('test', '--workspace', '--locked') `
        -AfterDelimiter @('--nocapture') `
        -RequireDelimiter `
        -Message 'uninvoked function fixture'
} -ExpectedFragment 'Found 0'

$invokedFixture = @(New-FixtureBlocks -Script @'
function Invoke-Test {
    cargo test --workspace --locked -- --nocapture
}
Invoke-Test
'@)
$invokedCommands = @(Get-ExecutableCommands -Blocks $invokedFixture)
$null = Assert-OneCommand `
    -Commands $invokedCommands `
    -Name 'cargo' `
    -Subcommand 'test' `
    -BeforeDelimiter @('test', '--workspace', '--locked') `
    -AfterDelimiter @('--nocapture') `
    -RequireDelimiter `
    -Message 'A directly invoked helper must expose its executable Cargo command.'

$wrongOrderFixture = @(New-FixtureBlocks -Script @'
cargo build --release --locked --package darknamer-app --bin DarkReNamer
git ls-remote origin refs/heads/master
./scripts/validate-release-handoff.ps1
'@)
$wrongOrderCommands = @(Get-ExecutableCommands -Blocks $wrongOrderFixture)
$wrongOrderBuild = Assert-OneCommand `
    -Commands $wrongOrderCommands `
    -Name 'cargo' `
    -Subcommand 'build' `
    -BeforeDelimiter @('build', '--release', '--locked') `
    -Message 'wrong-order build fixture'
$wrongOrderMaster = Assert-OneCommand `
    -Commands $wrongOrderCommands `
    -Name 'git' `
    -BeforeDelimiter @('ls-remote', 'origin', 'refs/heads/master') `
    -Message 'wrong-order source fixture'
$wrongOrderHandoff = Assert-OneCommand `
    -Commands $wrongOrderCommands `
    -Name './scripts/validate-release-handoff.ps1' `
    -Message 'wrong-order handoff fixture'
Assert-Fails -Action {
    Assert-InOrder `
        -Records @($wrongOrderMaster, $wrongOrderBuild, $wrongOrderHandoff) `
        -Message 'wrong-order fixture'
} -ExpectedFragment 'wrong-order fixture'

$provenanceFixture = @(New-FixtureBlocks -Script @'
# $env:DARKRENAMER_BENCH_SOURCE_SHA = $env:GITHUB_SHA
$env:DARKRENAMER_BENCH_SOURCE_SHA = $env:OTHER_SHA
$matrix = @{
    source_sha = $env:SOURCE_SHA
    cargo_toml_sha256 = $cargoHash
    cargo_lock_sha256 = $lockHash
    rust_toolchain_toml_sha256 = $toolchainHash
}
'@)
Assert-Fails -Action {
    Assert-Assignment `
        -Blocks $provenanceFixture `
        -Left '$env:DARKRENAMER_BENCH_SOURCE_SHA' `
        -Right '$env:GITHUB_SHA' `
        -Message 'source binding fixture'
} -ExpectedFragment 'Found 0'
Assert-Fails -Action {
    Assert-HashtableContract `
        -Blocks $provenanceFixture `
        -Required ([ordered]@{
            source_sha = '$env:SOURCE_SHA'
            source_date_epoch = '[long] $env:SOURCE_DATE_EPOCH'
            harness_sha256 = '$harnessHash'
        }) `
        -Message 'provenance fixture'
} -ExpectedFragment 'Found 0'

$tagFixture = @(New-FixtureBlocks -Script @'
$expectedTag = "v$version"
if ($env:RELEASE_TAG -cne $otherTag) {
    throw 'mismatch'
}
'@)
Assert-Fails -Action {
    Assert-BinaryGuard `
        -Blocks $tagFixture `
        -Left '$env:RELEASE_TAG' `
        -Operator ([Management.Automation.Language.TokenKind]::Cne) `
        -Right '$expectedTag' `
        -Message 'tag authority fixture'
} -ExpectedFragment 'Found 0'

$tagOverwriteFixture = @(New-FixtureBlocks -Script @'
$cargo = Get-Content -LiteralPath Cargo.toml -Raw
$versionMatches = [regex]::Matches($cargo, '(?m)^version = "([^"]+)"\r?$')
$expectedTag = "v$($versionMatches[0].Groups[1].Value)"
$expectedTag = $env:RELEASE_TAG
if ($env:RELEASE_TAG -cne $expectedTag) {
    throw 'mismatch'
}
'@)
Assert-Fails -Action {
    $null = Assert-SingleAssignment `
        -Blocks $tagOverwriteFixture `
        -Left '$expectedTag' `
        -Right '"v$($versionMatches[0].Groups[1].Value)"' `
        -Message 'tag overwrite fixture'
} -ExpectedFragment 'Found 2'

$disclosureFixture = @(New-FixtureBlocks -Script @'
$sourceComplete = 'Source-complete Windows prerelease.'
$acceptance = 'Desktop acceptance is not complete.'
Write-Host "$sourceComplete $acceptance"
'@)
Assert-Fails -Action {
    Assert-OutputContract `
        -Blocks $disclosureFixture `
        -LiteralPath 'release-notes.md' `
        -RequiredText @(
            'Source-complete Windows prerelease.'
            'exact immutable candidate artifact'
            'Desktop acceptance is not complete.'
        ) `
        -Message 'release disclosure fixture'
} -ExpectedFragment 'Found 0'

$toolingFixture = (New-FixtureBlocks -Script @'
$commonTests = @(
    'test-release-candidate-metadata-validator.ps1'
    'test-prepare-release-cyclonedx.ps1'
)
'@)[0].ast
Assert-Fails -Action {
    Assert-CommonTestMembership -Ast $toolingFixture -Required $requiredCommonTests
} -ExpectedFragment 'must contain test-release-workflow-powershell-syntax.ps1 exactly once'

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
$versionPattern = '(?m)^version = "([^"]+)"\r?$'
foreach ($newline in "`n", "`r`n") {
    $cargoFixture = "[workspace]${newline}${newline}[workspace.package]${newline}version = `"0.1.0`"${newline}"
    $matches = [regex]::Matches($cargoFixture, $versionPattern)
    if ($matches.Count -ne 1 -or $matches[0].Groups[1].Value -cne '0.1.0') {
        throw 'Release version parsing must accept exactly one LF or CRLF workspace version line.'
    }
}

Write-Host "Release workflow PowerShell syntax tests passed for $blockCount run blocks."
