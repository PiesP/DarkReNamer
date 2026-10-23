#![cfg_attr(windows, windows_subsystem = "windows")]
#![forbid(unsafe_code)]

fn main() {
    if let Err(error) = darknamer_app::run() {
        show_fatal_error(&error.to_string());
    }
}

#[cfg(windows)]
fn show_fatal_error(message: &str) {
    darknamer_app::show_startup_error(message);
}

#[cfg(not(windows))]
fn show_fatal_error(message: &str) {
    eprintln!("DarkReNamer: {message}");
}
