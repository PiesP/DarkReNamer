//! Read-only language selection precedes runtime/recovery message formatting.

use std::env;
use std::io;
use std::path::PathBuf;
use std::ptr::null_mut;
use windows_sys::Win32::Globalization::{GetUserPreferredUILanguages, MUI_LANGUAGE_NAME};

#[cfg(test)]
use crate::i18n::Language;
use crate::i18n::LanguagePreference;
use crate::preferences::{LanguagePreferencesLoad, load_language_or_default};

pub(super) struct StartupLanguage {
    pub(super) loaded: LanguagePreferencesLoad,
    pub(super) system_failure: Option<io::Error>,
}

pub(super) fn initialize_startup_language() -> io::Result<StartupLanguage> {
    let loaded = env::var_os("LOCALAPPDATA").map_or_else(
        || LanguagePreferencesLoad {
            preference: LanguagePreference::System,
            missing: false,
            migration_failure: None,
            failure: Some(io::Error::other("LOCALAPPDATA is unavailable")),
        },
        |root| load_language_or_default(&PathBuf::from(root).join("DarkReNamer").join("journal")),
    );
    let (languages, system_failure) = if loaded.preference == LanguagePreference::System {
        match preferred_ui_languages() {
            Ok(languages) => (languages, None),
            Err(error) => (Vec::new(), Some(error)),
        }
    } else {
        (Vec::new(), None)
    };
    let tags: Vec<&str> = languages.iter().map(String::as_str).collect();
    let language = loaded.preference.resolve(&tags);
    crate::i18n::initialize(language)
        .map_err(|_| io::Error::other("application UI language was already initialized"))?;
    Ok(StartupLanguage {
        loaded,
        system_failure,
    })
}

fn preferred_ui_languages() -> io::Result<Vec<String>> {
    let mut count = 0;
    let mut size = 0;
    // SAFETY: this first call supplies live count/size outputs and a null buffer
    // with size zero, the documented size-query contract. It changes no locale.
    if unsafe { GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &mut count, null_mut(), &mut size) }
        == 0
    {
        return Err(io::Error::last_os_error());
    }
    if !(2..=65_536).contains(&size) || count > 4096 {
        return Err(io::Error::other(
            "Windows UI-language list exceeds its buffer bound",
        ));
    }
    let mut buffer = vec![0; size as usize];
    let capacity = size;
    // SAFETY: the owned UTF-16 buffer has the queried capacity, both outputs are
    // live, and only a successful call's bounded returned length is consumed.
    if unsafe {
        GetUserPreferredUILanguages(
            MUI_LANGUAGE_NAME,
            &mut count,
            buffer.as_mut_ptr(),
            &mut size,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    if size < 2 || size > capacity || count > 4096 {
        return Err(io::Error::other(
            "Windows UI-language list returned an invalid length",
        ));
    }
    let data = &buffer[..size as usize];
    if data[data.len() - 2..] != [0, 0] {
        return Err(io::Error::other(
            "Windows UI-language list is not double-NUL terminated",
        ));
    }
    let tags: Vec<String> = data[..data.len() - 1]
        .split(|unit| *unit == 0)
        .filter(|tag| !tag.is_empty())
        .map(|tag| {
            String::from_utf16(tag)
                .map_err(|_| io::Error::other("Windows UI-language tag is not UTF-16"))
        })
        .collect::<io::Result<_>>()?;
    if tags.len() != count as usize {
        return Err(io::Error::other(
            "Windows UI-language list count does not match its entries",
        ));
    }
    Ok(tags)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_ui_language_api_supplies_supported_or_fallback_selection() -> io::Result<()> {
        let languages = preferred_ui_languages()?;
        let tags: Vec<&str> = languages.iter().map(String::as_str).collect();
        assert!(matches!(
            LanguagePreference::System.resolve(&tags),
            Language::Korean | Language::English | Language::Japanese
        ));
        Ok(())
    }
}
