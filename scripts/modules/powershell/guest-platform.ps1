function Get-VmAutomatedEnvironment {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][IntPtr] $WindowHandle,
        [Parameter(Mandatory)][string] $FixtureRoot
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'VM-Automated environment observation requires Windows.'
    }
    Initialize-NativeCapture
    $rootPath = Get-VmAutomatedCanonicalRootPath -Path $FixtureRoot
    $Process.Refresh()
    if ($Process.HasExited -or $WindowHandle -eq [IntPtr]::Zero -or
        -not [DarkReNamerVmNative]::IsWindow($WindowHandle)) {
        throw 'VM-Automated environment requires a live candidate window.'
    }
    $windowProcessId = [uint32]0
    if ([DarkReNamerVmNative]::GetWindowThreadProcessId(
            $WindowHandle,
            [ref]$windowProcessId
        ) -eq 0 -or $windowProcessId -ne $Process.Id) {
        throw 'VM-Automated target window is outside the candidate process.'
    }
    $windowRect = [DarkReNamerVmNative+Rect]::new()
    if (-not [DarkReNamerVmNative]::GetWindowRect($WindowHandle, [ref]$windowRect)) {
        throw 'VM-Automated target window bounds are unavailable.'
    }
    $monitor = [DarkReNamerVmNative]::ReadMonitorInfo($WindowHandle)
    $dpi = [int][DarkReNamerVmNative]::GetDpiForWindow($WindowHandle)
    if ($dpi -le 0) { throw 'VM-Automated target window DPI is unavailable.' }
    $version = Get-ItemProperty `
        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
        -ErrorAction Stop
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $drivePath = if ($rootPath.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        $rootPath.Substring(4)
    } else { $rootPath }
    $drive = [IO.DriveInfo]::new($drivePath.Substring(0, 3))
    Initialize-TextScaleNative
    $textScaleFactor = [double][DarkReNamerTextScaleNative]::ReadTextScaleFactor()
    if ([double]::IsNaN($textScaleFactor) -or [double]::IsInfinity($textScaleFactor) -or
        $textScaleFactor -lt 1.0 -or $textScaleFactor -gt 2.25) {
        throw 'VM-Automated actual UISettings text scale is unavailable or invalid.'
    }
    $textScale = [int][Math]::Round($textScaleFactor * 100)
    $desktopAvailable = [bool][DarkReNamerVmNative]::InputDesktopAvailable()
    [ordered]@{
        schema_version = 1
        platform = [ordered]@{
            os_product_name = [string]$version.ProductName
            display_version = [string]$version.DisplayVersion
            build_number = [int]$version.CurrentBuildNumber
            product_type = [int]$operatingSystem.ProductType
            architecture = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq
                [Runtime.InteropServices.Architecture]::X64) { 'x86_64' } else {
                [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
            }
        }
        process = [ordered]@{
            pid = [int]$Process.Id
            session_id = [int]$Process.SessionId
            is_elevated = [bool][DarkReNamerVmNative]::IsProcessElevated([uint32]$Process.Id)
        }
        desktop = [ordered]@{
            input_desktop_active = $desktopAvailable
            locked = -not $desktopAvailable
        }
        fixture_volume = [ordered]@{
            filesystem = [string]$drive.DriveFormat
            root_path = $rootPath
            root_identity = Get-FullFileIdentity -Path $rootPath
        }
        target_display = [ordered]@{
            hwnd = [long]$WindowHandle
            process_id = [int]$windowProcessId
            session_id = [int]$Process.SessionId
            dpi_x = $dpi
            dpi_y = $dpi
            monitor_rect = [ordered]@{
                left = $monitor[0]; top = $monitor[1]
                right = $monitor[2]; bottom = $monitor[3]
            }
            work_rect = [ordered]@{
                left = $monitor[4]; top = $monitor[5]
                right = $monitor[6]; bottom = $monitor[7]
            }
            window_rect = [ordered]@{
                left = $windowRect.Left; top = $windowRect.Top
                right = $windowRect.Right; bottom = $windowRect.Bottom
            }
            text_scale_percent = [int]$textScale
            high_contrast_flags = [long][DarkReNamerVmNative]::GetHighContrastFlags()
        }
    }
}
