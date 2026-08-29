#![cfg_attr(windows, windows_subsystem = "windows")]

fn main() -> Result<(), Box<dyn std::error::Error>> {
    darknamer_legacy_app::run()
}
