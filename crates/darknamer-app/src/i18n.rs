//! Embedded presentation text. The startup language never changes file semantics.

use std::sync::OnceLock;

#[cfg(windows)]
pub(crate) mod native_ui;
#[cfg(windows)]
pub(crate) mod runtime;

pub(crate) const LANGUAGE_SYSTEM: u16 = 0x9020;
pub(crate) const LANGUAGE_KOREAN: u16 = 0x9021;
pub(crate) const LANGUAGE_ENGLISH: u16 = 0x9022;
pub(crate) const LANGUAGE_JAPANESE: u16 = 0x9023;

impl LanguagePreference {
    pub(crate) const fn from_command(command: u16) -> Option<Self> {
        match command {
            LANGUAGE_SYSTEM => Some(Self::System),
            LANGUAGE_KOREAN => Some(Self::Korean),
            LANGUAGE_ENGLISH => Some(Self::English),
            LANGUAGE_JAPANESE => Some(Self::Japanese),
            _ => None,
        }
    }
    pub(crate) const fn command(self) -> u16 {
        match self {
            Self::System => LANGUAGE_SYSTEM,
            Self::Korean => LANGUAGE_KOREAN,
            Self::English => LANGUAGE_ENGLISH,
            Self::Japanese => LANGUAGE_JAPANESE,
        }
    }
}

/// Supported application languages, independent of Windows regional formats.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Language {
    Korean,
    English,
    Japanese,
}

/// Persisted choice; System follows Windows UI-language preferences at startup.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum LanguagePreference {
    #[default]
    System,
    Korean,
    English,
    Japanese,
}

impl LanguagePreference {
    #[must_use]
    pub const fn native_name(self) -> &'static str {
        match self {
            Self::System => "System",
            Self::Korean => "한국어",
            Self::English => "English",
            Self::Japanese => "日本語",
        }
    }

    #[must_use]
    pub fn resolve(self, preferred_ui_languages: &[&str]) -> Language {
        match self {
            Self::Korean => Language::Korean,
            Self::English => Language::English,
            Self::Japanese => Language::Japanese,
            Self::System => preferred_ui_languages
                .iter()
                .find_map(|tag| {
                    let primary = tag.split('-').next().unwrap_or_default();
                    if primary.eq_ignore_ascii_case("ko") {
                        Some(Language::Korean)
                    } else if primary.eq_ignore_ascii_case("en") {
                        Some(Language::English)
                    } else if primary.eq_ignore_ascii_case("ja") {
                        Some(Language::Japanese)
                    } else {
                        None
                    }
                })
                .unwrap_or(Language::English),
        }
    }
}

static STARTUP_LANGUAGE: OnceLock<Language> = OnceLock::new();

/// Called before app-owned startup diagnostics are formatted. Reinitializing a
/// process with a different language is intentionally unsupported.
pub(crate) fn initialize(language: Language) -> Result<(), Language> {
    match STARTUP_LANGUAGE.set(language) {
        Ok(()) => Ok(()),
        Err(attempted) if STARTUP_LANGUAGE.get() == Some(&attempted) => Ok(()),
        Err(attempted) => Err(attempted),
    }
}

#[must_use]
pub fn current_language() -> Language {
    #[cfg(test)]
    if let Some(language) = TEST_LANGUAGE.with(std::cell::Cell::get) {
        return language;
    }
    STARTUP_LANGUAGE.get().copied().unwrap_or_else(|| {
        // Existing unit fixtures describe the legacy Korean UI. Test overrides
        // are thread-local, so parallel language assertions cannot race.
        #[cfg(test)]
        {
            Language::Korean
        }
        #[cfg(not(test))]
        {
            Language::English
        }
    })
}

#[cfg(test)]
thread_local! {
    static TEST_LANGUAGE: std::cell::Cell<Option<Language>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
pub(crate) fn with_language<T>(language: Language, body: impl FnOnce() -> T) -> T {
    struct Restore(Option<Language>);
    impl Drop for Restore {
        fn drop(&mut self) {
            TEST_LANGUAGE.with(|slot| slot.set(self.0));
        }
    }
    let _restore = Restore(TEST_LANGUAGE.with(|slot| slot.replace(Some(language))));
    body()
}

// Each presentation owner keeps a small typed catalog. All three formats are
// compiled with the same named parameters: missing, extra or invalid formatting
// parameters fail the build, without a runtime parser or fallback translation.
macro_rules! catalog {
    (
        text { $( $key:ident = ($ko:literal, $en:literal, $ja:literal); )* }
        messages { $( $name:ident ( $( $arg:ident : $kind:ty ),* $(,)? ) =
            ($msg_ko:literal, $msg_en:literal, $msg_ja:literal); )* }
    ) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub(crate) enum Text { $( $key, )* }
        impl Text {
            pub(crate) const fn in_language(self, language: $crate::i18n::Language) -> &'static str {
                match (self, language) {
                    $( (Self::$key, $crate::i18n::Language::Korean) => $ko,
                       (Self::$key, $crate::i18n::Language::English) => $en,
                       (Self::$key, $crate::i18n::Language::Japanese) => $ja, )*
                }
            }
            pub(crate) fn get(self) -> &'static str {
                self.in_language($crate::i18n::current_language())
            }
        }
        $( pub(crate) fn $name( $( $arg: $kind ),* ) -> String {
            match $crate::i18n::current_language() {
                $crate::i18n::Language::Korean => format!($msg_ko, $( $arg = $arg ),*),
                $crate::i18n::Language::English => format!($msg_en, $( $arg = $arg ),*),
                $crate::i18n::Language::Japanese => format!($msg_ja, $( $arg = $arg ),*),
            }
        } )*
    };
}
pub(crate) use catalog;

#[cfg(test)]
mod tests {
    use super::{Language, LanguagePreference, with_language};

    super::catalog! {
        text { Confirm = ("확인", "OK", "OK"); }
        messages {
            files(count: usize) = ("파일: {count}개", "Files: {count}", "ファイル: {count} 件");
        }
    }

    #[test]
    fn explicit_choice_precedes_ui_preferences_and_system_has_a_stable_fallback() {
        assert_eq!(
            LanguagePreference::Japanese.resolve(&["ko-KR"]),
            Language::Japanese
        );
        assert_eq!(
            LanguagePreference::System.resolve(&["fr-FR", "ja-JP", "ko-KR"]),
            Language::Japanese
        );
        assert_eq!(
            LanguagePreference::System.resolve(&["EN-us", "ja-JP"]),
            Language::English
        );
        assert_eq!(LanguagePreference::System.resolve(&[]), Language::English);
        assert_eq!(
            LanguagePreference::System.resolve(&["fr-FR"]),
            Language::English
        );
    }

    #[test]
    fn complete_formats_handle_counts_and_locale_overrides_restore_the_caller() {
        assert_eq!(Text::Confirm.in_language(Language::Korean), "확인");
        for count in [0, 1, 2, usize::MAX] {
            for language in [Language::Korean, Language::English, Language::Japanese] {
                with_language(language, || {
                    assert!(!Text::Confirm.get().is_empty());
                    assert!(files(count).contains(&count.to_string()));
                });
            }
        }
        with_language(Language::English, || {
            with_language(Language::Japanese, || {
                assert_eq!(super::current_language(), Language::Japanese)
            });
            assert_eq!(super::current_language(), Language::English);
        });
    }
}
