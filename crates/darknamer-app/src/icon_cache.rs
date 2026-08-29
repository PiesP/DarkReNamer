//! Stable cache keys for shell icons requested with use-file-attributes.

use darknamer_core::LegacyText;

/// Directory or case-folded extension icon class.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum IconCacheKey {
    /// Shared directory icon.
    Directory,
    /// Shared file-without-extension icon.
    FileWithoutExtension,
    /// Case-folded extension including its leading dot.
    Extension(Box<[u16]>),
}

/// Derives the bounded icon cache key from an exact legacy name.
#[must_use]
pub fn icon_cache_key(name: &LegacyText, is_directory: bool) -> IconCacheKey {
    if is_directory {
        return IconCacheKey::Directory;
    }
    let Some(dot) = name.units().iter().rposition(|unit| *unit == b'.' as u16) else {
        return IconCacheKey::FileWithoutExtension;
    };
    if dot + 1 >= name.len() {
        return IconCacheKey::FileWithoutExtension;
    }
    let mut folded = Vec::new();
    for decoded in std::char::decode_utf16(name.units()[dot..].iter().copied()) {
        match decoded {
            Ok(character) => {
                for lower in character.to_lowercase() {
                    let mut units = [0_u16; 2];
                    folded.extend_from_slice(lower.encode_utf16(&mut units));
                }
            }
            Err(error) => folded.push(error.unpaired_surrogate()),
        }
    }
    IconCacheKey::Extension(folded.into_boxed_slice())
}

impl IconCacheKey {
    /// Returns one representative exact string for `SHGetFileInfoW`.
    #[must_use]
    pub fn lookup_text(&self) -> LegacyText {
        match self {
            Self::Directory => LegacyText::from("folder"),
            Self::FileWithoutExtension => LegacyText::from("file"),
            Self::Extension(extension) => {
                let mut units = "file".encode_utf16().collect::<Vec<_>>();
                units.extend_from_slice(extension);
                LegacyText::from_units(units)
            }
        }
    }
}
