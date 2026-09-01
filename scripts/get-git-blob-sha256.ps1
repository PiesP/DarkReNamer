[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,
    [Parameter(Mandatory)]
    [string] $Revision,
    [Parameter(Mandatory)]
    [string] $Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.4') {
    throw 'Git blob hashing requires PowerShell 7.4 or newer (pwsh).'
}
if ($Revision -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Revision must be a full lowercase 40-character Git SHA.'
}
if ($Path -cnotmatch '^[0-9A-Za-z._/-]+$' -or
    $Path.StartsWith('/') -or
    $Path.EndsWith('/') -or
    @(
        $Path -split '/' |
            Where-Object { [string]::IsNullOrEmpty($_) -or $_ -in '.', '..' }
    ).Count -ne 0) {
    throw 'Path must be a normalized repository-relative path without dot components.'
}
if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw 'SourceRoot must identify an existing directory.'
}
$resolvedRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$topLevel = @(& git -C $resolvedRoot rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0 -or $topLevel.Count -ne 1) {
    throw 'SourceRoot must identify a Git worktree root.'
}
$comparison = if ($IsWindows) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}
$canonicalRoot = [IO.Path]::GetFullPath($resolvedRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$canonicalTopLevel = [IO.Path]::GetFullPath($topLevel[0]).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
if (-not [string]::Equals($canonicalRoot, $canonicalTopLevel, $comparison)) {
    throw 'SourceRoot must identify the exact Git worktree root.'
}

$objectSpec = "${Revision}:$Path"
$objectType = @(& git -C $canonicalRoot cat-file -t $objectSpec 2>$null)
if ($LASTEXITCODE -ne 0 -or $objectType.Count -ne 1 -or $objectType[0] -cne 'blob') {
    throw 'Revision and Path must identify one Git blob.'
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'git'
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
[void] $startInfo.ArgumentList.Add('-C')
[void] $startInfo.ArgumentList.Add($canonicalRoot)
[void] $startInfo.ArgumentList.Add('cat-file')
[void] $startInfo.ArgumentList.Add('blob')
[void] $startInfo.ArgumentList.Add($objectSpec)
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) {
    $process.Dispose()
    throw 'Git blob reader could not be started.'
}
try {
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($process.StandardOutput.BaseStream)
    }
    finally {
        $sha256.Dispose()
    }
    $process.WaitForExit()
    $standardError = $standardErrorTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        throw "Git blob reader failed with exit code $($process.ExitCode): $standardError"
    }
}
finally {
    $process.Dispose()
}

[Convert]::ToHexString($hashBytes).ToLowerInvariant()
