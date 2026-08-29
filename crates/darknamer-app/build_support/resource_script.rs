use std::path::Path;

use crate::resource_ids;

pub(crate) fn render(
    icon: &Path,
    toolbar1: &Path,
    toolbar2: &Path,
    package_version: &str,
    version_numbers: [u16; 4],
) -> String {
    let icon = escape_path(icon);
    let toolbar1 = escape_path(toolbar1);
    let toolbar2 = escape_path(toolbar2);
    format!(
        "{} ICON \"{}\"\n{} BITMAP \"{}\"\n{} BITMAP \"{}\"\n1 VERSIONINFO\n FILEVERSION {},{},{},{}\n PRODUCTVERSION {},{},{},{}\n FILEOS 0x4L\n FILETYPE 0x1L\nBEGIN\n BLOCK \"StringFileInfo\"\n BEGIN\n  BLOCK \"041204b0\"\n  BEGIN\n   VALUE \"FileDescription\", \"DarkReNamer - unofficial Rust port of DarkNamer\\0\"\n   VALUE \"FileVersion\", \"{}\\0\"\n   VALUE \"InternalName\", \"DarkReNamer\\0\"\n   VALUE \"LegalCopyright\", \"Copyright (c) 2018 Seo, Jang-won; Copyright (c) 2026 PiesP\\0\"\n   VALUE \"OriginalFilename\", \"DarkReNamer.exe\\0\"\n   VALUE \"ProductName\", \"DarkReNamer\\0\"\n   VALUE \"ProductVersion\", \"{}\\0\"\n  END\n END\n BLOCK \"VarFileInfo\"\n BEGIN\n  VALUE \"Translation\", 0x412, 1200\n END\nEND\n",
        resource_ids::APP_ICON,
        icon,
        resource_ids::LEFT_TOOLBAR_BITMAP,
        toolbar1,
        resource_ids::RIGHT_TOOLBAR_BITMAP,
        toolbar2,
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

fn escape_path(path: &Path) -> String {
    path.display().to_string().replace('\\', "\\\\")
}
