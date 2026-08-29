#[path = "../resource_ids.rs"]
mod resource_ids;
#[path = "../build_support/resource_script.rs"]
mod resource_script;

use std::path::Path;

#[test]
fn windows_resource_paths_escape_backslashes() {
    let script = resource_script::render(
        Path::new(r"C:\actions\temp\target\DarkNamer.ico"),
        Path::new(r"C:\actions\temp\target\toolbar1.bmp"),
        Path::new(r"C:\actions\temp\target\toolbar2.bmp"),
    );

    assert!(script.contains(r#"1 ICON "C:\\actions\\temp\\target\\DarkNamer.ico""#));
    assert!(script.contains(r#"130 BITMAP "C:\\actions\\temp\\target\\toolbar1.bmp""#));
    assert!(script.contains(r#"132 BITMAP "C:\\actions\\temp\\target\\toolbar2.bmp""#));
}
