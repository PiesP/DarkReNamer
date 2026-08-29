use std::path::Path;

use crate::resource_ids;

pub(crate) fn render(
    icon: &Path,
    manifest: &Path,
    package_version: &str,
    version_numbers: [u16; 4],
) -> String {
    let icon = escape_path(icon);
    let manifest = escape_path(manifest);
    format!(
        "{} ICON \"{}\"\n1 24 \"{}\"\n1 VERSIONINFO\n FILEVERSION {},{},{},{}\n PRODUCTVERSION {},{},{},{}\n FILEOS 0x4L\n FILETYPE 0x1L\nBEGIN\n BLOCK \"StringFileInfo\"\n BEGIN\n  BLOCK \"041204b0\"\n  BEGIN\n   VALUE \"FileDescription\", \"DarkReNamer - unofficial Rust port of DarkNamer\\0\"\n   VALUE \"FileVersion\", \"{}\\0\"\n   VALUE \"InternalName\", \"DarkReNamer\\0\"\n   VALUE \"LegalCopyright\", \"Copyright (c) 2018 Seo, Jang-won; Copyright (c) 2026 PiesP\\0\"\n   VALUE \"OriginalFilename\", \"DarkReNamer.exe\\0\"\n   VALUE \"ProductName\", \"DarkReNamer\\0\"\n   VALUE \"ProductVersion\", \"{}\\0\"\n  END\n END\n BLOCK \"VarFileInfo\"\n BEGIN\n  VALUE \"Translation\", 0x412, 1200\n END\nEND\n",
        resource_ids::APP_ICON,
        icon,
        manifest,
        version_numbers[0],
        version_numbers[1],
        version_numbers[2],
        version_numbers[3],
        version_numbers[0],
        version_numbers[1],
        version_numbers[2],
        version_numbers[3],
        package_version,
        package_version,
    )
}

pub(crate) const fn application_manifest() -> &'static str {
    r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*" />
    </dependentAssembly>
  </dependency>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2, PerMonitor, system</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>
"#
}

fn escape_path(path: &Path) -> String {
    path.display().to_string().replace('\\', "\\\\")
}
