#![cfg_attr(windows, windows_subsystem = "windows")]
#![forbid(unsafe_code)]

fn main() {
    if let Err(error) = darknamer_app::run() {
        show_fatal_error(&error.to_string());
    }
}

#[cfg(windows)]
fn show_fatal_error(message: &str) {
    use rfd::{MessageButtons, MessageDialog, MessageLevel};

    let _result = MessageDialog::new()
        .set_level(MessageLevel::Error)
        .set_title("DarkReNamer - 시작 실패")
        .set_description(message)
        .set_buttons(MessageButtons::Ok)
        .show();
}

#[cfg(not(windows))]
fn show_fatal_error(message: &str) {
    eprintln!("DarkReNamer: {message}");
}
