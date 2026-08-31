//! Windows leaf-name validation shared by planning adapters.

use std::fmt;

use crate::LegacyText;

/// Maximum number of UTF-16 code units in one Windows leaf name.
pub const MAX_WINDOWS_LEAF_NAME_UTF16_UNITS: usize = 255;

/// A reason an exact UTF-16 leaf name cannot be used safely on Windows.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum WindowsLeafNameError {
    /// The name contains no code units.
    Empty,
    /// The name contains a NUL code unit.
    ContainsNul,
    /// The name contains a path separator.
    ContainsSeparator,
    /// The complete name is `.` or `..`.
    DotComponent,
    /// The name contains a Win32-forbidden character or control code unit.
    InvalidCharacter,
    /// The stem is a reserved DOS device name.
    ReservedDeviceName,
    /// The name ends in a dot or space.
    TrailingDotOrSpace,
    /// The name exceeds the Windows component limit.
    TooLong,
}

impl fmt::Display for WindowsLeafNameError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::Empty => "name is empty",
            Self::ContainsNul => "name contains NUL",
            Self::ContainsSeparator => "name contains a path separator",
            Self::DotComponent => "name is a dot path component",
            Self::InvalidCharacter => "name contains a character forbidden by Windows",
            Self::ReservedDeviceName => "name is a reserved Windows device name",
            Self::TrailingDotOrSpace => "name ends in a dot or space",
            Self::TooLong => "name exceeds the Windows component limit",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for WindowsLeafNameError {}

/// Validates one exact UTF-16 Windows leaf name without normalizing it.
///
/// # Errors
///
/// Returns the first structural Windows leaf-name violation.
pub fn validate_windows_leaf_name(name: &LegacyText) -> Result<(), WindowsLeafNameError> {
    let units = name.units();
    if units.is_empty() {
        return Err(WindowsLeafNameError::Empty);
    }
    if units.len() > MAX_WINDOWS_LEAF_NAME_UTF16_UNITS {
        return Err(WindowsLeafNameError::TooLong);
    }
    if units == [b'.' as u16] || units == [b'.' as u16, b'.' as u16] {
        return Err(WindowsLeafNameError::DotComponent);
    }
    if units.contains(&0) {
        return Err(WindowsLeafNameError::ContainsNul);
    }
    if units
        .iter()
        .any(|unit| matches!(*unit, value if value == b'/' as u16 || value == b'\\' as u16))
    {
        return Err(WindowsLeafNameError::ContainsSeparator);
    }
    if units.iter().any(|unit| {
        *unit < 32
            || matches!(
                *unit,
                value if value == b'<' as u16
                    || value == b'>' as u16
                    || value == b':' as u16
                    || value == b'"' as u16
                    || value == b'|' as u16
                    || value == b'?' as u16
                    || value == b'*' as u16
            )
    }) {
        return Err(WindowsLeafNameError::InvalidCharacter);
    }
    if units
        .last()
        .is_some_and(|unit| *unit == b'.' as u16 || *unit == b' ' as u16)
    {
        return Err(WindowsLeafNameError::TrailingDotOrSpace);
    }
    if is_reserved_device_name(units) {
        return Err(WindowsLeafNameError::ReservedDeviceName);
    }
    Ok(())
}

fn is_reserved_device_name(units: &[u16]) -> bool {
    let stem_end = units
        .iter()
        .position(|unit| *unit == b'.' as u16)
        .unwrap_or(units.len());
    let stem = &units[..stem_end];
    matches_ascii_ignore_case(stem, b"CON")
        || matches_ascii_ignore_case(stem, b"PRN")
        || matches_ascii_ignore_case(stem, b"AUX")
        || matches_ascii_ignore_case(stem, b"NUL")
        || matches_ascii_ignore_case(stem, b"CLOCK$")
        || is_numbered_device(stem, b"COM")
        || is_numbered_device(stem, b"LPT")
}

fn matches_ascii_ignore_case(units: &[u16], expected: &[u8]) -> bool {
    units.len() == expected.len()
        && units.iter().zip(expected).all(|(actual, expected)| {
            ascii_upper(*actual) == u16::from(expected.to_ascii_uppercase())
        })
}

fn ascii_upper(unit: u16) -> u16 {
    if (b'a' as u16..=b'z' as u16).contains(&unit) {
        unit - u16::from(b'a' - b'A')
    } else {
        unit
    }
}

fn is_numbered_device(stem: &[u16], prefix: &[u8; 3]) -> bool {
    stem.len() == 4
        && matches_ascii_ignore_case(&stem[..3], prefix)
        && matches!(stem[3], value if (b'1' as u16..=b'9' as u16).contains(&value) || [0x00B9, 0x00B2, 0x00B3].contains(&value))
}
