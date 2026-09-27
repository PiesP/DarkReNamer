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
    if fs::metadata(path)?.len() > MAX_IMPORT_BYTES as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "가져오기 파일이 2 MiB 한도를 초과합니다",
        ));
    }
    let bytes = read_bounded_import(fs::File::open(path)?)?;
    if bytes.starts_with(&[0xFF, 0xFE]) {
        if (bytes.len() - 2) % 2 != 0 {
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
