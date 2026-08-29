use std::fs;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::ptr::null_mut;

use darknamer_core::LegacyText;
use windows_sys::Win32::Globalization::{
    CP_ACP, CSTR_GREATER_THAN, CSTR_LESS_THAN, CompareStringW, LOCALE_USER_DEFAULT,
    MultiByteToWideChar, NORM_IGNORECASE,
};

use crate::admission::{MAX_IMPORT_BYTES, read_bounded_import};

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

pub(super) fn write_legacy_text(path: &Path, text: &LegacyText) -> io::Result<()> {
    let mut bytes = Vec::with_capacity(2 + text.len() * 2);
    bytes.extend_from_slice(&[0xFF, 0xFE]);
    for unit in text.units() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    fs::write(path, bytes)
}

pub(super) fn read_legacy_text(path: &Path) -> io::Result<LegacyText> {
    if fs::metadata(path)?.len() > MAX_IMPORT_BYTES as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "가져오기 파일이 2 MiB 한도를 초과합니다",
        ));
    }
    let bytes = read_bounded_import(fs::File::open(path)?)?;
    if bytes.starts_with(&[0xFF, 0xFE]) {
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
