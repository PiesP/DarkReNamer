#![cfg_attr(windows, windows_subsystem = "windows")]

fn main() {
    if let Err(error) = darknamer_app::run() {
        show_fatal_error(&error.to_string());
    }
}

#[cfg(windows)]
fn show_fatal_error(message: &str) {
    use std::ptr::null_mut;

    use windows_sys::Win32::UI::WindowsAndMessaging::MessageBoxW;

    let message = message.encode_utf16().chain([0]).collect::<Vec<_>>();
    let caption = "DarkReNamer - 시작 실패"
        .encode_utf16()
        .chain([0])
        .collect::<Vec<_>>();
    // SAFETY: both UTF-16 buffers are NUL-terminated and remain live for the
    // synchronous call; a null owner creates a visible process-level dialog.
    unsafe { MessageBoxW(null_mut(), message.as_ptr(), caption.as_ptr(), 0) };
}

#[cfg(not(windows))]
fn show_fatal_error(message: &str) {
    eprintln!("DarkReNamer: {message}");
}
