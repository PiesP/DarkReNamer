use std::io;
use std::mem::size_of;

use darknamer_core::LegacyText;
use windows_sys::Win32::Foundation::{GetLastError, GlobalFree, HANDLE, HWND, SetLastError};
use windows_sys::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows_sys::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};
use windows_sys::Win32::System::Ole::CF_UNICODETEXT;

struct ClipboardSession {
    open: bool,
}

impl ClipboardSession {
    fn close(mut self) -> io::Result<()> {
        // SAFETY: this guard owns the one clipboard session opened by this thread.
        let closed = unsafe { CloseClipboard() };
        if closed == 0 {
            return Err(io::Error::last_os_error());
        }
        self.open = false;
        Ok(())
    }
}

impl Drop for ClipboardSession {
    fn drop(&mut self) {
        if self.open {
            // SAFETY: this guard still owns an open session. Drop is the
            // best-effort cleanup path after an earlier operation failed.
            unsafe { CloseClipboard() };
        }
    }
}

pub(super) fn copy_clipboard(owner: HWND, text: &LegacyText) -> io::Result<()> {
    let mut units = text.units().to_vec();
    units.push(0);
    // SAFETY: owner is the live top-level HWND for this clipboard session.
    if unsafe { OpenClipboard(owner) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let session = ClipboardSession { open: true };
    // SAFETY: this thread successfully opened the clipboard above.
    if unsafe { EmptyClipboard() } == 0 {
        return Err(io::Error::last_os_error());
    }
    let bytes = units.len().saturating_mul(size_of::<u16>());
    // SAFETY: bytes is the checked UTF-16 byte count.
    let allocation = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes) };
    if allocation.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: allocation is the newly allocated non-null HGLOBAL.
    let locked = unsafe { GlobalLock(allocation) } as *mut u16;
    if locked.is_null() {
        let error = io::Error::last_os_error();
        // SAFETY: ownership has not transferred.
        unsafe { GlobalFree(allocation) };
        return Err(error);
    }
    // SAFETY: locked spans units.len writable u16 slots; clearing last-error
    // disambiguates GlobalUnlock's zero success return from failure.
    let unlock_error = unsafe {
        std::ptr::copy_nonoverlapping(units.as_ptr(), locked, units.len());
        SetLastError(0);
        let unlocked = GlobalUnlock(allocation);
        let error = GetLastError();
        (unlocked == 0 && error != 0).then_some(error)
    };
    if let Some(code) = unlock_error {
        // SAFETY: ownership has not transferred.
        unsafe { GlobalFree(allocation) };
        return Err(io::Error::from_raw_os_error(
            i32::try_from(code).unwrap_or(i32::MAX),
        ));
    }
    // SAFETY: allocation is unlocked movable global memory containing
    // terminated UTF-16; success transfers ownership to the clipboard.
    let transferred = unsafe { SetClipboardData(u32::from(CF_UNICODETEXT), allocation as HANDLE) };
    if transferred.is_null() {
        let error = io::Error::last_os_error();
        // SAFETY: SetClipboardData failed, so ownership remains local.
        unsafe { GlobalFree(allocation) };
        return Err(error);
    }
    session.close()
}
