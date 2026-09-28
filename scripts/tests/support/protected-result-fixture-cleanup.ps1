function Remove-ProtectedResultFixtures {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Paths
    )

    # Restore deletion only on the exact parents owned by this test, after assertions.
    # Protected result files keep their production DACL until they are deleted.
    $rootPath = [IO.Path]::GetFullPath($Root)
    $rootPrefix = $rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    foreach ($registeredPath in $Paths) {
        $resultPath = [IO.Path]::GetFullPath($registeredPath)
        if (-not $resultPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Protected result fixture cleanup must remain beneath its owned temporary root.'
        }
        $parentPath = [IO.Path]::GetDirectoryName($resultPath)
        $cursor = $rootPath
        $relativeParent = [IO.Path]::GetRelativePath($rootPath, $parentPath)
        $components = @($relativeParent.Split([IO.Path]::DirectorySeparatorChar))
        foreach ($component in @('.') + $components) {
            if ($component -cne '.') { $cursor = Join-Path $cursor $component }
            $directory = Get-Item -LiteralPath $cursor -Force
            if (-not $directory.PSIsContainer -or
                ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Protected result fixture cleanup must not traverse a reparse point.'
            }
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $security = [IO.FileSystemAclExtensions]::GetAccessControl(
                [IO.DirectoryInfo]::new($parentPath),
                [Security.AccessControl.AccessControlSections]::Access
            )
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.WindowsIdentity]::GetCurrent().User,
                [Security.AccessControl.FileSystemRights]::Delete -bor
                    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
                [Security.AccessControl.AccessControlType]::Allow
            ))
            [IO.FileSystemAclExtensions]::SetAccessControl(
                [IO.DirectoryInfo]::new($parentPath), $security
            )
        }
        if (Test-Path -LiteralPath $resultPath) {
            $file = Get-Item -LiteralPath $resultPath -Force
            if ($file.PSIsContainer -or
                ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Protected result fixture cleanup requires an ordinary result file.'
            }
            [IO.File]::Delete($resultPath)
        }
    }
}
