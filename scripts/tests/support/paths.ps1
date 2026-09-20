function Get-ToolingTestPaths {
    $scriptsRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $repositoryRoot = Split-Path $scriptsRoot -Parent
    [pscustomobject]@{
        ScriptsRoot = $scriptsRoot
        RepositoryRoot = $repositoryRoot
        SupportRoot = $PSScriptRoot
        TestsRoot = Split-Path $PSScriptRoot -Parent
        SchemaRoot = Join-Path $repositoryRoot 'config/schemas'
    }
}
