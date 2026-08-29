#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

fn main() -> Result<(), Box<dyn std::error::Error>> {
    dark_renamer_app::run()
}
