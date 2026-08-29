#[path = "../resource_ids.rs"]
mod resource_ids;
#[path = "../build_support/resource_script.rs"]
mod resource_script;

use std::path::Path;

#[test]
fn windows_resource_paths_escape_backslashes() {
    let script = resource_script::render(
        Path::new(r"C:\actions\temp\target\DarkReNamer.ico"),
        Path::new(r"C:\actions\temp\target\toolbar1.bmp"),
        Path::new(r"C:\actions\temp\target\toolbar2.bmp"),
        "0.1.0",
        [0, 1, 0, 0],
    );

    assert!(script.contains(r#"1 ICON "C:\\actions\\temp\\target\\DarkReNamer.ico""#));
    assert!(script.contains(r#"130 BITMAP "C:\\actions\\temp\\target\\toolbar1.bmp""#));
    assert!(script.contains(r#"132 BITMAP "C:\\actions\\temp\\target\\toolbar2.bmp""#));
}

#[test]
fn windows_resource_identifies_the_unofficial_port_and_cargo_version() {
    let script = resource_script::render(
        Path::new("DarkReNamer.ico"),
        Path::new("toolbar1.bmp"),
        Path::new("toolbar2.bmp"),
        "0.1.0",
        [0, 1, 0, 0],
    );

    assert!(script.contains("FILEVERSION 0,1,0,0"));
    assert!(script.contains("PRODUCTVERSION 0,1,0,0"));
    assert!(script.contains(
        r#"VALUE "FileDescription", "DarkReNamer - unofficial Rust port of DarkNamer\0""#
    ));
    assert!(script.contains(r#"VALUE "FileVersion", "0.1.0\0""#));
    assert!(script.contains(r#"VALUE "InternalName", "DarkReNamer\0""#));
    assert!(script.contains(r#"VALUE "OriginalFilename", "DarkReNamer.exe\0""#));
    assert!(script.contains(r#"VALUE "ProductName", "DarkReNamer\0""#));
    assert!(script.contains("Copyright (c) 2018 Seo, Jang-won"));
    assert!(script.contains("Copyright (c) 2026 PiesP"));
    assert!(!script.contains("MFC"));
}
