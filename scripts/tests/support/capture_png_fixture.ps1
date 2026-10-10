[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The System.Drawing PNG encoder fixture requires Windows.' }
. (Join-Path $PSScriptRoot 'paths.ps1')
Add-Type -AssemblyName System.Drawing.Common
$width = 2
$height = 2
$rows = foreach ($filename in @('guest-uia.ps1', 'ui-input.ps1', 'guest-scenario.ps1', 'legacy-default')) {
    $bitmap = $null
    $stream = $null
    try {
        if ($filename -ceq 'legacy-default') {
            $bitmap = [Drawing.Bitmap]::new($width, $height)
        }
        else {
            $source = Join-Path (Get-ToolingTestPaths).ScriptsRoot ('modules/powershell/' + $filename)
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
            if ($errors.Count -ne 0) { throw "Capture source cannot be parsed: $filename" }
            $constructors = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Static -and
                $node.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                $node.Expression.TypeName.FullName -ceq 'Drawing.Bitmap' -and
                $node.Member.Value -ceq 'new'
            }, $true))
            if ($constructors.Count -ne 1) { throw "Expected one capture bitmap constructor: $filename" }
            # Execute the production constructor, without activating a desktop or window.
            $bitmap = & ([scriptblock]::Create($constructors[0].Extent.Text))
        }
        # Model GDI RGB data with an explicit zero-alpha pixel; an RGB bitmap discards alpha.
        $bitmap.SetPixel(0, 0, [Drawing.Color]::Red)
        $bitmap.SetPixel(1, 0, [Drawing.Color]::Lime)
        $bitmap.SetPixel(0, 1, [Drawing.Color]::Blue)
        $bitmap.SetPixel(1, 1, [Drawing.Color]::FromArgb(0, 0, 0, 0))
        $stream = [IO.MemoryStream]::new()
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        [ordered]@{ source = $filename; png = [Convert]::ToBase64String($stream.ToArray()) }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
}
ConvertTo-Json -InputObject @($rows) -Compress
