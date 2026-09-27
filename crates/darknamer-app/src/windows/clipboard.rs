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

fn prepare_clipboard_allocation<H: Copy>(
    units: &[u16],
    allocate: impl FnOnce(usize) -> io::Result<H>,
    populate: impl FnOnce(H, &[u16]) -> io::Result<()>,
    release: impl FnOnce(H),
) -> io::Result<H> {
    let bytes = units
        .len()
        .checked_mul(size_of::<u16>())
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let allocation = allocate(bytes)?;
    if let Err(error) = populate(allocation, units) {
        release(allocation);
        return Err(error);
    }
    Ok(allocation)
}

fn allocate_clipboard_memory(bytes: usize) -> io::Result<HANDLE> {
    // SAFETY: bytes is the checked UTF-16 byte count.
    let allocation = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes) };
    if allocation.is_null() {
        Err(io::Error::last_os_error())
    } else {
        Ok(allocation)
    }
}

fn populate_clipboard_memory(allocation: HANDLE, units: &[u16]) -> io::Result<()> {
    // SAFETY: allocation is the newly allocated non-null HGLOBAL.
    let locked = unsafe { GlobalLock(allocation) } as *mut u16;
    if locked.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: locked spans units.len writable u16 slots; clearing last-error
    // disambiguates GlobalUnlock's zero success return.
    let unlock_error = unsafe {
        std::ptr::copy_nonoverlapping(units.as_ptr(), locked, units.len());
        SetLastError(0);
        let unlocked = GlobalUnlock(allocation);
        let error = GetLastError();
        (unlocked == 0 && error != 0).then_some(error)
    };
    if let Some(code) = unlock_error {
        Err(io::Error::from_raw_os_error(
            i32::try_from(code).unwrap_or(i32::MAX),
        ))
    } else {
        Ok(())
    }
}

fn release_clipboard_memory(allocation: HANDLE) {
    // SAFETY: failed preparation leaves ownership with this caller.
    unsafe { GlobalFree(allocation) };
}

fn publish_clipboard_memory(owner: HWND, allocation: HANDLE) -> io::Result<()> {
    // SAFETY: owner is the live top-level HWND for this clipboard session.
    if unsafe { OpenClipboard(owner) } == 0 {
        let error = io::Error::last_os_error();
        // SAFETY: the clipboard has not taken ownership of this allocation.
        unsafe { GlobalFree(allocation) };
        return Err(error);
    }
    let session = ClipboardSession { open: true };
    // SAFETY: this thread successfully opened the clipboard above.
    if unsafe { EmptyClipboard() } == 0 {
        let error = io::Error::last_os_error();
        // SAFETY: ownership has not transferred.
        unsafe { GlobalFree(allocation) };
        return Err(error);
    }
    // SAFETY: allocation is unlocked movable global memory containing
    // terminated UTF-16; success transfers ownership to the clipboard.
    let transferred = unsafe { SetClipboardData(u32::from(CF_UNICODETEXT), allocation) };
    if transferred.is_null() {
        let error = io::Error::last_os_error();
        // SAFETY: SetClipboardData failed, so ownership remains local.
        unsafe { GlobalFree(allocation) };
        return Err(error);
    }
    session.close()
}

fn publish_prepared_clipboard_data<H>(
    prepare: impl FnOnce() -> io::Result<H>,
    publish: impl FnOnce(H) -> io::Result<()>,
) -> io::Result<()> {
    publish(prepare()?)
}

pub(super) fn copy_clipboard(owner: HWND, text: &LegacyText) -> io::Result<()> {
    let mut units = text.units().to_vec();
    units.push(0);
    // Prepare the complete movable block before opening or emptying the
    // clipboard so allocation, lock, or unlock failures preserve old contents.
    publish_prepared_clipboard_data(
        || {
            prepare_clipboard_allocation(
                &units,
                allocate_clipboard_memory,
                populate_clipboard_memory,
                release_clipboard_memory,
            )
        },
        |allocation| publish_clipboard_memory(owner, allocation),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocation_lock_and_unlock_failures_do_not_empty_the_clipboard() {
        for failure in ["allocation", "lock", "unlock"] {
            let mut empty_calls = 0;
            let mut release_calls = 0;
            let result = publish_prepared_clipboard_data(
                || {
                    prepare_clipboard_allocation(
                        &[65, 0],
                        |_| {
                            if failure == "allocation" {
                                Err(io::Error::from(io::ErrorKind::OutOfMemory))
                            } else {
                                Ok(7_usize)
                            }
                        },
                        |_, _| {
                            Err(io::Error::from(if failure == "lock" {
                                io::ErrorKind::PermissionDenied
                            } else {
                                io::ErrorKind::InvalidData
                            }))
                        },
                        |_| release_calls += 1,
                    )
                },
                |_| {
                    empty_calls += 1;
                    Ok(())
                },
            );

            assert!(result.is_err(), "{failure} failure must be reported");
            assert_eq!(empty_calls, 0, "{failure} failure must not empty old data");
            assert_eq!(release_calls, if failure == "allocation" { 0 } else { 1 });
        }
    }
}
