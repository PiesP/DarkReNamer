use std::fs;
use std::io;
use std::io::Read;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::ptr::null_mut;

use darknamer_core::LegacyText;
use windows_sys::Win32::Globalization::{
    CP_ACP, CSTR_GREATER_THAN, CSTR_LESS_THAN, CompareStringW, LOCALE_USER_DEFAULT,
    MultiByteToWideChar, NORM_IGNORECASE,
};

use crate::admission::{MAX_IMPORT_BYTES, read_bounded_import};

pub(super) const TEXT_EXPORT_CLEANUP_WARNING_TITLE: &str = "DarkReNamer - 저장 후 정리 필요";

pub(super) fn legacy_path(path: &Path) -> LegacyText {
    LegacyText::from_units(path.as_os_str().encode_wide().collect::<Vec<_>>())
}

pub(super) fn compare_windows(left: &LegacyText, right: &LegacyText) -> std::cmp::Ordering {
    let left_len = i32::try_from(left.len()).unwrap_or(i32::MAX);
    let right_len = i32::try_from(right.len()).unwrap_or(i32::MAX);
    // SAFETY: both UTF-16 slices remain allocated and the checked lengths
    // describe their exact readable units.
    let result = unsafe {
        CompareStringW(
            LOCALE_USER_DEFAULT,
            NORM_IGNORECASE,
            left.units().as_ptr(),
            left_len,
            right.units().as_ptr(),
            right_len,
        )
    };
    if result == CSTR_LESS_THAN {
        std::cmp::Ordering::Less
    } else if result == CSTR_GREATER_THAN {
        std::cmp::Ordering::Greater
    } else if result == windows_sys::Win32::Globalization::CSTR_EQUAL {
        std::cmp::Ordering::Equal
    } else {
        crate::compare_utf16_fallback(left, right)
    }
}

pub(super) fn path_wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain([0]).collect()
}

#[cfg(test)]
pub(super) fn write_legacy_text(
    path: &Path,
    text: &LegacyText,
) -> io::Result<crate::rename::windows_native::TextExportOutcome> {
    let bytes = encode_legacy_text(text)?;
    crate::rename::windows_native::write_text_export(path, &bytes)
}

pub(super) fn write_legacy_text_to_target(
    target: crate::rename::windows_native::TextExportTarget,
    text: &LegacyText,
) -> io::Result<crate::rename::windows_native::TextExportOutcome> {
    let bytes = encode_legacy_text(text)?;
    crate::rename::windows_native::write_text_export_target(target, &bytes)
}

pub(super) fn text_export_cleanup_warning_korean(error: &io::Error) -> String {
    format!(
        "파일은 저장했습니다. 다만 저장 폴더의 임시 백업을 안전하게 확인하고 삭제하지 못했습니다: {error}\n\n저장 폴더에서 이름이 '.darkrenamer-text-export-backup-'로 시작하는 '.tmp' 파일을 확인해 주세요. 필요 여부를 확인한 뒤 직접 삭제할 수 있습니다."
    )
}

fn encode_legacy_text(text: &LegacyText) -> io::Result<Vec<u8>> {
    let payload_size = text
        .len()
        .checked_mul(2)
        .and_then(|length| length.checked_add(2))
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(payload_size)
        .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
    bytes.extend_from_slice(&[0xFF, 0xFE]);
    for unit in text.units() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    Ok(bytes)
}

pub(super) fn read_legacy_text(path: &Path) -> io::Result<LegacyText> {
    read_legacy_text_from(
        || fs::File::open(path),
        |file| {
            let metadata = file.metadata()?;
            Ok((metadata.is_file(), metadata.len()))
        },
    )
}

fn read_legacy_text_from<R: Read>(
    open: impl FnOnce() -> io::Result<R>,
    metadata: impl FnOnce(&R) -> io::Result<(bool, u64)>,
) -> io::Result<LegacyText> {
    let file = open()?;
    let (regular, length) = metadata(&file)?;
    if !regular {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "import is not a regular file",
        ));
    }
    if length > MAX_IMPORT_BYTES as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "가져오기 파일이 2 MiB 한도를 초과합니다",
        ));
    }
    let bytes = read_bounded_import(file)?;
    decode_legacy_text(&bytes)
}

fn decode_legacy_text(bytes: &[u8]) -> io::Result<LegacyText> {
    if bytes.starts_with(&[0xFF, 0xFE]) {
        if !(bytes.len() - 2).is_multiple_of(2) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "UTF-16LE text file has an incomplete code unit",
            ));
        }
        let units = bytes[2..]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect::<Vec<_>>();
        return Ok(LegacyText::from_units(units));
    }
    if bytes.is_empty() {
        return Ok(LegacyText::default());
    }
    let input_len =
        i32::try_from(bytes.len()).map_err(|_| io::Error::other("text file too large"))?;
    // SAFETY: bytes is readable for input_len; null output requests sizing.
    let needed =
        unsafe { MultiByteToWideChar(CP_ACP, 0, bytes.as_ptr(), input_len, null_mut(), 0) };
    if needed <= 0 {
        return Err(io::Error::last_os_error());
    }
    let mut units = vec![0_u16; needed as usize];
    // SAFETY: units is writable for exactly needed UTF-16 elements and both
    // buffers remain allocated throughout the synchronous conversion.
    let written = unsafe {
        MultiByteToWideChar(
            CP_ACP,
            0,
            bytes.as_ptr(),
            input_len,
            units.as_mut_ptr(),
            needed,
        )
    };
    if written <= 0 {
        return Err(io::Error::last_os_error());
    }
    units.truncate(written as usize);
    Ok(LegacyText::from_units(units))
}

pub(super) fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain([0]).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::sync::{Arc, Mutex, mpsc};
    use std::thread;

    #[test]
    fn import_validates_opened_regular_file_and_preserves_utf16_units() -> io::Result<()> {
        let bytes = [0xff, 0xfe, 0x00, 0xd8];
        let decoded = read_legacy_text_from(
            || Ok(Cursor::new(bytes)),
            |_| Ok((true, bytes.len() as u64)),
        )?;
        assert_eq!(decoded.units(), &[0xd800]);
        assert!(
            read_legacy_text_from(
                || Ok(Cursor::new(bytes)),
                |_| Ok((false, bytes.len() as u64)),
            )
            .is_err()
        );
        assert!(
            read_legacy_text_from(
                || Ok(Cursor::new(bytes)),
                |_| Ok((true, MAX_IMPORT_BYTES as u64 + 1)),
            )
            .is_err()
        );
        assert!(
            read_legacy_text_from(
                || Ok(Cursor::new(vec![b'a'; MAX_IMPORT_BYTES + 1])),
                |_| Ok((true, 1)),
            )
            .is_err()
        );
        assert!(
            read_legacy_text_from(|| Ok(Cursor::new([0xff, 0xfe, 0x61])), |_| Ok((true, 3)),)
                .is_err()
        );
        Ok(())
    }

    #[test]
    fn import_propagates_open_metadata_and_partial_read_errors() {
        let open_error = read_legacy_text_from(
            || Err::<Cursor<Vec<u8>>, _>(io::Error::from(io::ErrorKind::NotFound)),
            |_| Err(io::Error::other("metadata must not run after failed open")),
        );
        assert_eq!(
            open_error.err().map(|error| error.kind()),
            Some(io::ErrorKind::NotFound)
        );
        let metadata_error = read_legacy_text_from(
            || Ok(Cursor::new(vec![1_u8])),
            |_| Err(io::Error::from(io::ErrorKind::PermissionDenied)),
        );
        assert_eq!(
            metadata_error.err().map(|error| error.kind()),
            Some(io::ErrorKind::PermissionDenied)
        );

        struct PartialFailure(bool);
        impl Read for PartialFailure {
            fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
                if self.0 {
                    return Err(io::Error::from(io::ErrorKind::BrokenPipe));
                }
                self.0 = true;
                buf[0] = b'a';
                Ok(1)
            }
        }
        let read_error = read_legacy_text_from(|| Ok(PartialFailure(false)), |_| Ok((true, 1)));
        assert_eq!(
            read_error.err().map(|error| error.kind()),
            Some(io::ErrorKind::BrokenPipe)
        );
    }

    #[test]
    fn controlled_open_metadata_and_read_can_each_stall_then_fail()
    -> Result<(), Box<dyn std::error::Error>> {
        for stage in 0..3 {
            let (entered_sender, entered_receiver) = mpsc::sync_channel(0);
            let (release_sender, release_receiver) = mpsc::sync_channel(0);
            let release_receiver = Arc::new(Mutex::new(release_receiver));
            let handle = thread::spawn(move || {
                let pause = |current| {
                    if stage == current {
                        let _ = entered_sender.send(());
                        let _ = release_receiver
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .recv();
                        true
                    } else {
                        false
                    }
                };
                struct Reader<F: Fn(usize) -> bool>(F);
                impl<F: Fn(usize) -> bool> Read for Reader<F> {
                    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
                        self.0(2);
                        Err(io::Error::from(io::ErrorKind::BrokenPipe))
                    }
                }
                read_legacy_text_from(
                    || {
                        if pause(0) {
                            Err(io::Error::from(io::ErrorKind::NotFound))
                        } else {
                            Ok(Reader(&pause))
                        }
                    },
                    |_| {
                        if pause(1) {
                            Err(io::Error::from(io::ErrorKind::PermissionDenied))
                        } else {
                            Ok((true, 1))
                        }
                    },
                )
                .err()
                .map_or(io::ErrorKind::Other, |error| error.kind())
            });
            entered_receiver.recv_timeout(std::time::Duration::from_secs(5))?;
            assert!(!handle.is_finished());
            release_sender.send(())?;
            assert_eq!(
                handle
                    .join()
                    .map_err(|_| io::Error::other("controlled import stage panicked"))?,
                [
                    io::ErrorKind::NotFound,
                    io::ErrorKind::PermissionDenied,
                    io::ErrorKind::BrokenPipe,
                ][stage]
            );
        }
        Ok(())
    }
}
