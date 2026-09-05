#[path = "../resource_ids.rs"]
mod resource_ids;
#[path = "../build_support/resource_script.rs"]
mod resource_script;
#[cfg(unix)]
#[path = "../build_support/test_source_manifest.rs"]
mod test_source_manifest;

const BUILD_SCRIPT: &str = include_str!("../build.rs");

use std::path::Path;

#[test]
fn windows_resource_paths_escape_backslashes() {
    let script = resource_script::render(
        Path::new(r"C:\actions\temp\target\DarkReNamer.ico"),
        Path::new(r"C:\actions\temp\target\DarkReNamer.manifest"),
        "0.1.0",
        [0, 1, 0, 0],
    );

    assert!(script.contains(r#"1 ICON "C:\\actions\\temp\\target\\DarkReNamer.ico""#));
    assert!(script.contains(r#"1 24 "C:\\actions\\temp\\target\\DarkReNamer.manifest""#));
    assert!(!script.contains("BITMAP"));
}

#[test]
fn windows_resource_identifies_the_unofficial_port_and_cargo_version() {
    let script = resource_script::render(
        Path::new("DarkReNamer.ico"),
        Path::new("DarkReNamer.manifest"),
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

#[test]
fn embedded_manifest_enables_common_controls_and_per_monitor_v2() {
    let manifest = resource_script::application_manifest();

    assert!(manifest.contains("Microsoft.Windows.Common-Controls"));
    assert!(manifest.contains("version=\"6.0.0.0\""));
    assert!(manifest.contains(">true/pm</dpiAware>"));
    assert!(manifest.contains(">PerMonitorV2, PerMonitor, system</dpiAwareness>"));
    assert!(BUILD_SCRIPT.contains("embed_resource::compile_for_everything"));
    assert!(BUILD_SCRIPT.contains(".manifest_required()?"));
}

#[cfg(unix)]
#[test]
fn test_source_manifest_rejects_symlink_entries() -> Result<(), Box<dyn std::error::Error>> {
    use std::fs;
    use std::os::unix::fs::symlink;

    let fixture = tempfile::tempdir()?;
    let source = fixture.path().join("source.rs");
    fs::write(&source, b"fn source() {}\n")?;
    symlink(&source, fixture.path().join("linked.rs"))?;

    let error = test_source_manifest::render(fixture.path())
        .err()
        .ok_or_else(|| std::io::Error::other("symlinked source entry was accepted"))?;

    assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
    assert!(error.to_string().contains("rejects symlink entry"));
    Ok(())
}
