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

fn prepare_clipboard_allocation<H>(
    units: &[u16],
    allocate: impl FnOnce(usize) -> io::Result<H>,
    populate: impl FnOnce(&H, &[u16]) -> io::Result<()>,
) -> io::Result<H> {
    let bytes = units
        .len()
        .checked_mul(size_of::<u16>())
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let allocation = allocate(bytes)?;
    populate(&allocation, units)?;
    Ok(allocation)
}

// HGLOBAL has GlobalFree ownership, not CloseHandle ownership. This owner
// remains local through preparation and failed publication, and cannot be copied.
struct PreparedClipboardMemory {
    allocation: HANDLE,
    capacity_bytes: usize,
}

impl PreparedClipboardMemory {
    fn allocate(bytes: usize) -> io::Result<Self> {
        // SAFETY: bytes is the checked UTF-16 byte count.
        let allocation = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes) };
        if allocation.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self {
                allocation,
                capacity_bytes: bytes,
            })
        }
    }

    fn populate(&self, units: &[u16]) -> io::Result<()> {
        if units
            .len()
            .checked_mul(size_of::<u16>())
            .is_none_or(|bytes| bytes > self.capacity_bytes)
        {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        // SAFETY: this owner retains the newly allocated non-null HGLOBAL.
        let locked = unsafe { GlobalLock(self.allocation) } as *mut u16;
        if locked.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the checked allocation spans units.len writable u16 slots;
        // clearing last-error disambiguates GlobalUnlock's zero success return.
        let unlock_error = unsafe {
            std::ptr::copy_nonoverlapping(units.as_ptr(), locked, units.len());
            SetLastError(0);
            let unlocked = GlobalUnlock(self.allocation);
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

    fn transfer(mut self, publish: impl FnOnce(HANDLE) -> io::Result<()>) -> io::Result<()> {
        publish(self.allocation)?;
        // Only successful SetClipboardData relinquishes our ownership. A later
        // CloseClipboard failure cannot return that ownership to the application.
        self.allocation = std::ptr::null_mut();
        Ok(())
    }
}

impl Drop for PreparedClipboardMemory {
    fn drop(&mut self) {
        if !self.allocation.is_null() {
            // SAFETY: this owner retains the exact allocation unless successful
            // publication transferred it; no other local owner can free it.
            unsafe { GlobalFree(self.allocation) };
        }
    }
}

fn publish_clipboard_memory(owner: HWND, allocation: PreparedClipboardMemory) -> io::Result<()> {
    // SAFETY: owner is the live top-level HWND for this clipboard session.
    if unsafe { OpenClipboard(owner) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let session = ClipboardSession { open: true };
    // SAFETY: this thread successfully opened the clipboard above.
    if unsafe { EmptyClipboard() } == 0 {
        return Err(io::Error::last_os_error());
    }
    allocation.transfer(|raw| {
        // SAFETY: raw is this owner's unlocked movable global memory containing
        // terminated UTF-16; success transfers ownership to the clipboard.
        let transferred = unsafe { SetClipboardData(u32::from(CF_UNICODETEXT), raw) };
        if transferred.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    })?;
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
                PreparedClipboardMemory::allocate,
                PreparedClipboardMemory::populate,
            )
        },
        |allocation| publish_clipboard_memory(owner, allocation),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use windows_sys::Win32::System::Memory::GlobalSize;

    struct TestAllocation<'a>(&'a Cell<usize>);

    impl Drop for TestAllocation<'_> {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }

    #[test]
    fn allocation_lock_and_unlock_failures_do_not_empty_the_clipboard() {
        for failure in ["allocation", "lock", "unlock"] {
            let mut empty_calls = 0;
            let release_calls = Cell::new(0);
            let result = publish_prepared_clipboard_data(
                || {
                    prepare_clipboard_allocation(
                        &[65, 0],
                        |_| {
                            if failure == "allocation" {
                                Err(io::Error::from(io::ErrorKind::OutOfMemory))
                            } else {
                                Ok(TestAllocation(&release_calls))
                            }
                        },
                        |_, _| {
                            Err(io::Error::from(if failure == "lock" {
                                io::ErrorKind::PermissionDenied
                            } else {
                                io::ErrorKind::InvalidData
                            }))
                        },
                    )
                },
                |_| {
                    empty_calls += 1;
                    Ok(())
                },
            );

            assert!(result.is_err(), "{failure} failure must be reported");
            assert_eq!(empty_calls, 0, "{failure} failure must not empty old data");
            assert_eq!(
                release_calls.get(),
                if failure == "allocation" { 0 } else { 1 }
            );
        }
    }
    #[test]
    fn prepared_memory_checks_capacity_and_preserves_exact_utf16() -> io::Result<()> {
        let units = [65, 0xd800, 0xdc00, 0];
        let memory = prepare_clipboard_allocation(
            &units,
            PreparedClipboardMemory::allocate,
            PreparedClipboardMemory::populate,
        )?;
        assert!(memory.populate(&[65; 5]).is_err());
        // SAFETY: the owner keeps this populated allocation live and unlocked.
        let locked = unsafe { GlobalLock(memory.allocation) } as *const u16;
        assert!(!locked.is_null());
        // SAFETY: the block contains exactly units.len initialized UTF-16 units.
        let copied = unsafe { std::slice::from_raw_parts(locked, units.len()) };
        assert_eq!(copied, units);
        // SAFETY: balances this test's one successful lock.
        unsafe { GlobalUnlock(memory.allocation) };
        Ok(())
    }

    #[test]
    fn failed_publication_frees_memory_and_success_relinquishes_it() -> io::Result<()> {
        let failed = PreparedClipboardMemory::allocate(4)?;
        let failed_raw = failed.allocation;
        assert!(
            failed
                .transfer(|_| Err(io::Error::from(io::ErrorKind::PermissionDenied)))
                .is_err()
        );
        // SAFETY: GlobalSize reports zero for the invalid freed handle.
        assert_eq!(unsafe { GlobalSize(failed_raw) }, 0);

        let successful = PreparedClipboardMemory::allocate(4)?;
        let successful_raw = successful.allocation;
        successful.transfer(|_| Ok(()))?;
        // SAFETY: successful transfer left this fake publisher owning the block.
        assert!(unsafe { GlobalSize(successful_raw) } >= 4);
        // SAFETY: the fake publisher owns the exact block after transfer.
        unsafe { GlobalFree(successful_raw) };
        Ok(())
    }
}
