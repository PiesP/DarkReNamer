use std::env;
use std::fs;
use std::path::PathBuf;

use base64::Engine as _;

#[path = "resource_ids.rs"]
mod resource_ids;
#[path = "build_support/resource_script.rs"]
mod resource_script;
#[path = "build_support/test_source_manifest.rs"]
mod test_source_manifest;

const ICON_BASE64: &str = "AAABAAIAICAQAAAAAADoAgAAJgAAABAQEAAAAAAAKAEAAA4DAAAoAAAAIAAAAEAAAAABAAQAAAAAAIACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAgAAAAICAAIAAAACAAIAAgIAAAMDAwACAgIAAAAD/AAD/AAAA//8A/wAAAP8A/wD//wAA////AAAAAAAAAAAAAAAAAAAAAAAACZmZmZmZmZmZmZmZmZAAAJmZmZmZmZmZmZmZmZmZAAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZmZmZmZmZmZmZmZmZmZkACZmZmZmZmZmZmZmZmZmQAAAAAAAAAAAAAAAAAAAAAAAJmZmZmZmZmZmZmZmZmZAAmZmZmZmZmZmZmZmZmZmZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQAJmZmZmZmZmZmZmZmZmZAAAJmZmZmZmZmZmZmZmZkAAAAAAAAAAAAAAAAAAAAAAA/////+AAAAfAAAADgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABwAAAA//////AAAADgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAHAAAAD4AAAB/////8oAAAAEAAAACAAAAABAAQAAAAAAMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAgAAAAICAAIAAAACAAIAAgIAAAMDAwACAgIAAAAD/AAD/AAAA//8A/wAAAP8A/wD//wAA////AAAAAAAAAAAACZmZmZmZmZCf////////kJ////////+Qn////////5Cf////////kJ////////+QmZmZmZmZmZAAAAAAAAAAAJmZmZmZmZmQn////////5Cf////////kJ////////+Qn////////5Cf////////kAmZmZmZmZkA//8AAIABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAD//wAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAgAMAAA==";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=RC");
    let manifest_dir = PathBuf::from(
        env::var_os("CARGO_MANIFEST_DIR").ok_or("Cargo did not provide CARGO_MANIFEST_DIR")?,
    );
    println!("cargo:rerun-if-changed={}", manifest_dir.display());
    let output = PathBuf::from(env::var_os("OUT_DIR").ok_or("Cargo did not provide OUT_DIR")?);
    fs::write(
        output.join("test_source_manifest.rs"),
        test_source_manifest::render(&manifest_dir)?,
    )?;
    if env::var_os("CARGO_CFG_WINDOWS").is_none() {
        return Ok(());
    }
    let icon = output.join("DarkReNamer.ico");
    let manifest = output.join("DarkReNamer.manifest");
    let resource = output.join("DarkReNamer.rc");
    let package_version = env::var("CARGO_PKG_VERSION")?;
    let version_numbers = [
        env::var("CARGO_PKG_VERSION_MAJOR")?.parse::<u16>()?,
        env::var("CARGO_PKG_VERSION_MINOR")?.parse::<u16>()?,
        env::var("CARGO_PKG_VERSION_PATCH")?.parse::<u16>()?,
        0,
    ];
    let bytes = base64::engine::general_purpose::STANDARD.decode(ICON_BASE64)?;
    fs::write(&icon, bytes)?;
    fs::write(&manifest, resource_script::application_manifest())?;
    fs::write(
        &resource,
        resource_script::render(&icon, &manifest, &package_version, version_numbers),
    )?;
    // Every executable artifact that can reach the native module requires the
    // same v6 Common Controls activation. In particular, unit-test harnesses
    // import the documented subclass APIs before main starts; linking only the
    // product binary would bind those tests to classic System32 comctl32.
    embed_resource::compile_for_everything(resource, embed_resource::NONE).manifest_required()?;
    Ok(())
}
