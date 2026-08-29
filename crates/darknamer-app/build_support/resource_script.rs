use std::path::Path;

use crate::resource_ids;

pub(crate) fn render(icon: &Path, toolbar1: &Path, toolbar2: &Path) -> String {
    let icon = escape_path(icon);
    let toolbar1 = escape_path(toolbar1);
    let toolbar2 = escape_path(toolbar2);
    format!(
        "{} ICON \"{}\"\n{} BITMAP \"{}\"\n{} BITMAP \"{}\"\n1 VERSIONINFO\n FILEVERSION 1,0,0,1\n PRODUCTVERSION 1,0,0,1\n FILEOS 0x4L\n FILETYPE 0x1L\nBEGIN\n BLOCK \"StringFileInfo\"\n BEGIN\n  BLOCK \"041204b0\"\n  BEGIN\n   VALUE \"FileDescription\", \"DarkNamer MFC 응용 프로그램\\0\"\n   VALUE \"FileVersion\", \"1, 0, 0, 1\\0\"\n   VALUE \"InternalName\", \"DarkNamer\\0\"\n   VALUE \"LegalCopyright\", \"Copyright (C) 2008\\0\"\n   VALUE \"OriginalFilename\", \"DarkNamer.EXE\\0\"\n   VALUE \"ProductName\", \"DarkNamer 응용 프로그램\\0\"\n   VALUE \"ProductVersion\", \"1, 0, 0, 1\\0\"\n  END\n END\n BLOCK \"VarFileInfo\"\n BEGIN\n  VALUE \"Translation\", 0x412, 1200\n END\nEND\n",
        resource_ids::APP_ICON,
        icon,
        resource_ids::LEFT_TOOLBAR_BITMAP,
        toolbar1,
        resource_ids::RIGHT_TOOLBAR_BITMAP,
        toolbar2,
    )
}

fn escape_path(path: &Path) -> String {
    path.display().to_string().replace('\\', "\\\\")
}
