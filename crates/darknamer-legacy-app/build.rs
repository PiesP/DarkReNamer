use std::env;
use std::fs;
use std::path::PathBuf;

use base64::Engine as _;

const ICON_BASE64: &str = "AAABAAIAICAQAAAAAADoAgAAJgAAABAQEAAAAAAAKAEAAA4DAAAoAAAAIAAAAEAAAAABAAQAAAAAAIACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAgAAAAICAAIAAAACAAIAAgIAAAMDAwACAgIAAAAD/AAD/AAAA//8A/wAAAP8A/wD//wAA////AAAAAAAAAAAAAAAAAAAAAAAACZmZmZmZmZmZmZmZmZAAAJmZmZmZmZmZmZmZmZmZAAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZmZmZmZmZmZmZmZmZmZkACZmZmZmZmZmZmZmZmZmQAAAAAAAAAAAAAAAAAAAAAAAJmZmZmZmZmZmZmZmZmZAAmZmZmZmZmZmZmZmZmZmZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQCZ/////////////////5kAmf////////////////+ZAJn/////////////////mQAJmZmZmZmZmZmZmZmZmZAAAJmZmZmZmZmZmZmZmZkAAAAAAAAAAAAAAAAAAAAAAA/////+AAAAfAAAADgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABwAAAA//////AAAADgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAGAAAABgAAAAYAAAAHAAAAD4AAAB/////8oAAAAEAAAACAAAAABAAQAAAAAAMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAgAAAAICAAIAAAACAAIAAgIAAAMDAwACAgIAAAAD/AAD/AAAA//8A/wAAAP8A/wD//wAA////AAAAAAAAAAAACZmZmZmZmZCf////////kJ////////+Qn////////5Cf////////kJ////////+QmZmZmZmZmZAAAAAAAAAAAJmZmZmZmZmQn////////5Cf////////kJ////////+Qn////////5Cf////////kAmZmZmZmZkA//8AAIABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAD//wAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAgAMAAA==";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=RC");
    if env::var_os("CARGO_CFG_WINDOWS").is_none() {
        return Ok(());
    }
    let output = PathBuf::from(env::var_os("OUT_DIR").ok_or("Cargo did not provide OUT_DIR")?);
    let icon = output.join("DarkNamer.ico");
    let resource = output.join("DarkNamer.rc");
    let bytes = base64::engine::general_purpose::STANDARD.decode(ICON_BASE64)?;
    fs::write(&icon, bytes)?;
    fs::write(&resource, format!("1 ICON \"{}\"\n", icon.display()))?;
    embed_resource::compile(resource, embed_resource::NONE).manifest_optional()?;
    Ok(())
}
