//! Allowed locations and construct kinds for the package's native unsafe boundary.

include!(concat!(env!("OUT_DIR"), "/test_source_manifest.rs"));

const POLICY_FILE: &str = "tests/unsafe_policy.rs";

#[derive(Clone, Debug, Eq, PartialEq)]
enum RustToken {
    Identifier(String),
    Punctuation(u8),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct UnsafeCounts {
    blocks: usize,
    functions: usize,
    extern_functions: usize,
    implementations: usize,
    prohibited: usize,
}

impl UnsafeCounts {
    const fn new(
        blocks: usize,
        functions: usize,
        extern_functions: usize,
        implementations: usize,
    ) -> Self {
        Self {
            blocks,
            functions,
            extern_functions,
            implementations,
            prohibited: 0,
        }
    }

    fn from_source(source: &str) -> Self {
        let tokens = rust_tokens(source);
        let identifiers = |left: usize, right: usize, first: &str, second: &str| {
            matches!(tokens.get(left), Some(RustToken::Identifier(value)) if value == first)
                && matches!(tokens.get(right), Some(RustToken::Identifier(value)) if value == second)
        };
        let mut counts = Self::new(0, 0, 0, 0);
        for index in 0..tokens.len() {
            if !matches!(tokens.get(index), Some(RustToken::Identifier(value)) if value == "unsafe")
            {
                continue;
            }
            match tokens.get(index + 1) {
                Some(RustToken::Punctuation(b'{')) => counts.blocks += 1,
                Some(RustToken::Identifier(value)) if value == "fn" => counts.functions += 1,
                Some(RustToken::Identifier(value)) if value == "extern" => {
                    counts.extern_functions += 1;
                }
                Some(RustToken::Identifier(value)) if value == "impl" => {
                    counts.implementations += 1;
                }
                Some(RustToken::Identifier(value)) if value == "trait" => counts.prohibited += 1,
                _ => {}
            }
            if index >= 2
                && matches!(tokens.get(index - 2), Some(RustToken::Punctuation(b'#')))
                && matches!(tokens.get(index - 1), Some(RustToken::Punctuation(b'[')))
                && matches!(tokens.get(index + 1), Some(RustToken::Punctuation(b'(')))
            {
                counts.prohibited += 1;
            }
        }
        for index in 0..tokens.len().saturating_sub(1) {
            if identifiers(index, index + 1, "static", "mut") {
                counts.prohibited += 1;
            }
        }
        counts
    }

    const fn is_empty(self) -> bool {
        self.blocks == 0
            && self.functions == 0
            && self.extern_functions == 0
            && self.implementations == 0
            && self.prohibited == 0
    }
}

// Every listed location may use unsafe blocks; callback declarations are narrower.
// Counts are diagnostic only. Changes inside these boundaries still need native review.
const ALLOWED_BOUNDARIES: &[(&str, bool, bool)] = &[
    ("src/rename/windows_backend.rs", false, false),
    ("src/rename/windows_native.rs", false, false),
    ("src/rename/private_state.rs", false, false),
    ("src/windows.rs", true, true),
    ("src/windows/appearance.rs", false, false),
    ("src/windows/appearance_dialog.rs", false, true),
    ("src/windows/application.rs", false, true),
    ("src/windows/clipboard.rs", false, false),
    ("src/windows/command_dispatch.rs", false, false),
    // The UI-thread hover subclass retains only scalar refdata and forwards
    // every message to the native BUTTON exactly once.
    ("src/windows/command_rail.rs", false, true),
    ("src/windows/dialog.rs", false, true),
    ("src/windows/drag_drop.rs", true, true),
    // The sole Shell-icon worker owns its STA and pumps that thread's queue;
    // only validated system-list scalar identities cross to the UI thread.
    ("src/windows/icon_worker.rs", false, false),
    // Read-only, bounded Windows UI-language query; no locale mutation.
    ("src/windows/language.rs", false, false),
    ("src/windows/list_view.rs", true, true),
    ("src/windows/menu.rs", false, false),
    ("src/windows/popup_menu.rs", false, true),
    ("src/windows/recovery_ui.rs", false, false),
    ("src/windows/text_io.rs", false, false),
    ("src/windows/visual_capture.rs", false, false),
    ("src/windows/worker.rs", false, false),
    ("tests/rename_windows_backend.rs", false, false),
];

fn unsafe_counts_allowed(path: &str, counts: UnsafeCounts) -> bool {
    if counts.prohibited != 0 || counts.implementations != 0 {
        return false;
    }
    counts.is_empty()
        || ALLOWED_BOUNDARIES
            .iter()
            .any(|(allowed, functions, extern_functions)| {
                *allowed == path
                    && (counts.functions == 0 || *functions)
                    && (counts.extern_functions == 0 || *extern_functions)
            })
}

#[test]
fn unsafe_source_inventory_stays_within_reviewed_native_boundaries() {
    for &(relative, source) in BUILD_SOURCE_FILES {
        if relative == POLICY_FILE {
            continue;
        }
        let counts = UnsafeCounts::from_source(source);
        assert!(
            unsafe_counts_allowed(relative, counts),
            "unsafe location or construct kind is outside the reviewed native boundary: {relative}: {counts:?}"
        );
    }
}

#[test]
fn allowed_unsafe_reductions_do_not_require_count_synchronization() {
    for source in [
        "unsafe { first(); } unsafe { second(); }",
        "unsafe { first(); }",
        "",
    ] {
        assert!(unsafe_counts_allowed(
            "src/rename/windows_native.rs",
            UnsafeCounts::from_source(source)
        ));
    }
    assert!(unsafe_counts_allowed(
        "src/windows.rs",
        UnsafeCounts::from_source("unsafe fn callback() {} unsafe extern \"system\" fn other() {}")
    ));
}

#[test]
fn forbidden_locations_and_construct_kinds_are_rejected() {
    for path in [
        "src/model.rs",
        "src/windows/new_module.rs",
        "tests/new_native_test.rs",
    ] {
        assert!(!unsafe_counts_allowed(
            path,
            UnsafeCounts::from_source("unsafe {}")
        ));
        assert!(unsafe_counts_allowed(
            path,
            UnsafeCounts::from_source("fn safe() {}")
        ));
    }
    for source in [
        "unsafe fn callback() {}",
        "unsafe extern \"C\" fn callback() {}",
    ] {
        assert!(!unsafe_counts_allowed(
            "src/rename/windows_native.rs",
            UnsafeCounts::from_source(source)
        ));
    }
    for source in [
        "unsafe impl Trait for Type {}",
        "unsafe trait Trait {}",
        "#[unsafe(no_mangle)] fn export() {}",
        "static mut VALUE: usize = 0;",
    ] {
        assert!(!unsafe_counts_allowed(
            "src/windows.rs",
            UnsafeCounts::from_source(source)
        ));
    }
}

#[test]
fn build_source_manifest_is_sorted_unique_and_contains_the_policy() {
    assert!(
        BUILD_SOURCE_FILES
            .windows(2)
            .all(|pair| pair[0].0 < pair[1].0)
    );
    assert!(
        BUILD_SOURCE_FILES
            .iter()
            .any(|(path, source)| *path == POLICY_FILE
                && source.contains("const ALLOWED_BOUNDARIES"))
    );
}

#[test]
fn task_dialog_source_avoids_a_direct_task_dialog_indirect_identifier()
-> Result<(), Box<dyn std::error::Error>> {
    let dialog = BUILD_SOURCE_FILES
        .iter()
        .find(|(path, _)| *path == "src/windows/dialog.rs")
        .map(|(_, source)| *source)
        .ok_or("dialog source is absent from the reviewed manifest")?;
    assert!(BUILD_SOURCE_FILES.iter().all(|(_, source)| {
        rust_tokens(source).iter().all(
            |token| !matches!(token, RustToken::Identifier(value) if value == "TaskDialogIndirect"),
        )
    }));
    assert!(dialog.contains("GetProcAddress"));
    assert!(dialog.contains("b\"TaskDialogIndirect\\0\""));
    Ok(())
}

#[test]
fn token_scanner_ignores_literals_and_catches_comment_separated_constructs() {
    let source = r####"
        unsafe/* gap */{}
        unsafe // gap
        fn function() {}
        unsafe/* gap */extern "C" {}
        unsafe impl Trait for Type {}
        unsafe /* gap */ trait Trait {}
        #[unsafe(no_mangle)]
        static/* gap */mut VALUE: usize = 0;
        // unsafe { unsafe fn ignored() {} }
        const QUOTED: &str = "unsafe impl static mut";
        const RAW: &str = r#"unsafe extern"#;
    "####;

    assert_eq!(
        UnsafeCounts::from_source(source),
        UnsafeCounts {
            blocks: 1,
            functions: 1,
            extern_functions: 1,
            implementations: 1,
            prohibited: 3,
        }
    );
}

#[test]
fn character_literals_do_not_hide_unsafe_blocks_or_prohibited_constructs() {
    for source in [
        r#"fn sample() {
            let _quote = '"';
            let value = 7_i32;
            let pointer = &value as *const i32;
            let _read = unsafe { *pointer };
        }"#,
        r#"fn sample() {
            let _quote = b'"';
            let value = 7_i32;
            let pointer = &value as *const i32;
            let _read = unsafe { *pointer };
        }"#,
        r#"fn sample() { let _quote = '\"'; unsafe {} }"#,
        r#"fn sample() { let _quote = b'\"'; unsafe {} }"#,
        r#"fn sample() { let _quote = '\''; unsafe {} }"#,
        r#"fn sample() { let _quote = b'\''; unsafe {} }"#,
        r#"fn sample() { let _slash = '\\'; unsafe {} }"#,
        r#"fn sample() { let _slash = b'\\'; unsafe {} }"#,
        r#"fn sample() { let _letter = b'\x41'; unsafe {} }"#,
        r#"fn sample() { let _letter = 'a'; let _wide = '界'; unsafe {} }"#,
        r#"fn sample() { let _wide = '\u{754c}'; unsafe {} }"#,
    ] {
        let counts = UnsafeCounts::from_source(source);
        assert_eq!(counts, UnsafeCounts::new(1, 0, 0, 0), "{source}");
        assert!(
            !unsafe_counts_allowed("src/windows/new_module.rs", counts),
            "{source}"
        );
        assert!(
            unsafe_counts_allowed("src/rename/windows_native.rs", counts),
            "{source}"
        );
    }

    for (source, path, expected) in [
        (
            r#"const QUOTE: char = '"'; unsafe fn callback() {}"#,
            "src/rename/windows_native.rs",
            UnsafeCounts::new(0, 1, 0, 0),
        ),
        (
            r#"const QUOTE: u8 = b'"'; unsafe impl Trait for Type {}"#,
            "src/windows.rs",
            UnsafeCounts::new(0, 0, 0, 1),
        ),
        (
            r#"const QUOTE: char = '"'; unsafe trait Trait {}"#,
            "src/windows.rs",
            UnsafeCounts {
                prohibited: 1,
                ..UnsafeCounts::new(0, 0, 0, 0)
            },
        ),
        (
            r#"const QUOTE: char = '"'; #[unsafe(no_mangle)] fn export() {}"#,
            "src/windows.rs",
            UnsafeCounts {
                prohibited: 1,
                ..UnsafeCounts::new(0, 0, 0, 0)
            },
        ),
        (
            r#"const QUOTE: char = '"'; static mut VALUE: usize = 0;"#,
            "src/windows.rs",
            UnsafeCounts {
                prohibited: 1,
                ..UnsafeCounts::new(0, 0, 0, 0)
            },
        ),
    ] {
        let counts = UnsafeCounts::from_source(source);
        assert_eq!(counts, expected, "{source}");
        assert!(!unsafe_counts_allowed(path, counts), "{source}");
    }

    for source in [
        r#"const QUOTE: char = '"';"#,
        r#"const QUOTE: u8 = b'"';"#,
        "const LETTER: char = '界';",
        r#"const ESCAPED: char = '\u{754c}';"#,
    ] {
        let counts = UnsafeCounts::from_source(source);
        assert_eq!(counts, UnsafeCounts::new(0, 0, 0, 0), "{source}");
        assert!(
            unsafe_counts_allowed("src/windows/new_module.rs", counts),
            "{source}"
        );
    }
}

#[test]
fn lifetimes_and_labels_do_not_become_unsafe_policy_keywords() {
    for source in [
        "fn sample(_value: &'static mut u32) {}",
        "fn sample<'a>(value: &'a mut u32) { let _ = value; }",
        "fn sample() { 'retry: loop { break 'retry; } }",
        "fn sample<'a>(_value: &'a mut u32) { 'retry: loop { break 'retry; } }",
    ] {
        let counts = UnsafeCounts::from_source(source);
        assert_eq!(counts, UnsafeCounts::new(0, 0, 0, 0), "{source}");
        assert!(
            unsafe_counts_allowed("src/windows/new_module.rs", counts),
            "{source}"
        );
    }
}

#[test]
fn unicode_start_lifetime_stays_opaque_to_static_mut_detection() {
    #[expect(
        clippy::needless_lifetimes,
        reason = "explicit lifetime syntax is the regression"
    )]
    fn unicode_start<'한static>(_value: &'한static mut u32) {}
    let mut value = 0;
    unicode_start(&mut value);

    let source = "fn unicode_start<'한static>(_value: &'한static mut u32) {}";
    let counts = UnsafeCounts::from_source(source);
    assert_eq!(counts, UnsafeCounts::new(0, 0, 0, 0));
    assert!(unsafe_counts_allowed("src/windows/new_module.rs", counts));
}

#[test]
fn unicode_continuation_lifetime_stays_opaque_to_static_mut_detection() {
    #[expect(
        clippy::needless_lifetimes,
        reason = "explicit lifetime syntax is the regression"
    )]
    fn unicode_continue<'a한static>(_value: &'a한static mut u32) {}
    let mut value = 0;
    unicode_continue(&mut value);

    let source = "fn unicode_continue<'a한static>(_value: &'a한static mut u32) {}";
    let counts = UnsafeCounts::from_source(source);
    assert_eq!(counts, UnsafeCounts::new(0, 0, 0, 0));
    assert!(unsafe_counts_allowed("src/windows/new_module.rs", counts));
}

#[test]
fn raw_unicode_lifetimes_stay_opaque_to_static_mut_detection() {
    #[expect(
        clippy::needless_lifetimes,
        reason = "explicit lifetime syntax is the regression"
    )]
    fn raw_start<'r#한static>(_value: &'r#한static mut u32) {}
    #[expect(
        clippy::needless_lifetimes,
        reason = "explicit lifetime syntax is the regression"
    )]
    fn raw_continue<'r#a한static>(_value: &'r#a한static mut u32) {}
    let mut first = 0;
    let mut second = 0;
    raw_start(&mut first);
    raw_continue(&mut second);

    for source in [
        "fn raw_start<'r#한static>(_value: &'r#한static mut u32) {}",
        "fn raw_continue<'r#a한static>(_value: &'r#a한static mut u32) {}",
    ] {
        let counts = UnsafeCounts::from_source(source);
        assert_eq!(counts, UnsafeCounts::new(0, 0, 0, 0), "{source}");
        assert!(unsafe_counts_allowed("src/windows/new_module.rs", counts));
    }
}

#[test]
fn unicode_labels_and_identifier_continuations_stay_opaque() {
    fn unicode_labels() {
        let mut iterations = 0;
        '한9retry: loop {
            iterations += 1;
            if iterations == 1 {
                continue '한9retry;
            }
            break '한9retry;
        }
        assert_eq!(iterations, 2);
    }
    unicode_labels();

    for source in [
        "fn labels() { '한9static: loop { break '한9static; } }",
        "fn labels() { 'a한static: loop { break 'a한static; } }",
        "fn sample<'ástatic>(_value: &'ástatic mut u32) {}",
    ] {
        let counts = UnsafeCounts::from_source(source);
        assert_eq!(counts, UnsafeCounts::new(0, 0, 0, 0), "{source}");
        assert!(unsafe_counts_allowed("src/windows/new_module.rs", counts));
    }
}

#[test]
fn unicode_lifetimes_do_not_hide_following_unsafe_or_mutable_static() {
    for source in [
        "fn sample<'한static>(_value: &'한static mut u32) { unsafe {} }",
        "fn sample<'a한static>(_value: &'a한static mut u32) { unsafe {} }",
        "fn sample<'r#한static>(_value: &'r#한static mut u32) { unsafe {} }",
        "fn sample<'r#a한static>(_value: &'r#a한static mut u32) { unsafe {} }",
    ] {
        let counts = UnsafeCounts::from_source(source);
        assert_eq!(counts, UnsafeCounts::new(1, 0, 0, 0), "{source}");
        assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
        assert!(unsafe_counts_allowed(
            "src/rename/windows_native.rs",
            counts
        ));
    }

    for source in [
        "fn sample<'한static>(_value: &'한static mut u32) {} static mut VALUE: u32 = 0;",
        "fn sample<'a한static>(_value: &'a한static mut u32) {} static mut VALUE: u32 = 0;",
        "fn sample<'r#한static>(_value: &'r#한static mut u32) {} static mut VALUE: u32 = 0;",
        "fn sample<'r#a한static>(_value: &'r#a한static mut u32) {} static mut VALUE: u32 = 0;",
    ] {
        let counts = UnsafeCounts::from_source(source);
        assert_eq!(
            counts,
            UnsafeCounts {
                prohibited: 1,
                ..UnsafeCounts::new(0, 0, 0, 0)
            },
            "{source}"
        );
        assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
        assert!(!unsafe_counts_allowed(
            "src/rename/windows_native.rs",
            counts
        ));
    }
}

#[test]
fn non_identifier_unicode_separators_end_lifetimes_and_identifiers() {
    for separator in ['\u{2003}', '\u{2028}', '\u{3002}'] {
        let source = format!("'한static{separator}unsafe {{}}");
        let counts = UnsafeCounts::from_source(&source);
        assert_eq!(counts, UnsafeCounts::new(1, 0, 0, 0), "{source}");
        assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
        assert!(unsafe_counts_allowed(
            "src/rename/windows_native.rs",
            counts
        ));

        let source = format!("한static{separator}static mut VALUE: u32 = 0;");
        let counts = UnsafeCounts::from_source(&source);
        assert_eq!(
            counts,
            UnsafeCounts {
                prohibited: 1,
                ..UnsafeCounts::new(0, 0, 0, 0)
            },
            "{source}"
        );
        assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
        assert!(!unsafe_counts_allowed(
            "src/rename/windows_native.rs",
            counts
        ));
    }
}

#[test]
fn line_separator_between_unsafe_and_block_is_detected() {
    let source = "fn sample() { let value = 7_i32; let pointer = &value as *const i32; let _read = unsafe\u{2028}{ *pointer }; }";
    let counts = UnsafeCounts::from_source(source);
    assert_eq!(counts, UnsafeCounts::new(1, 0, 0, 0));
    assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
    assert!(unsafe_counts_allowed(
        "src/rename/windows_native.rs",
        counts
    ));
}

#[test]
fn line_separator_between_static_and_mut_is_detected() {
    let source = "static\u{2028}mut VALUE: u32 = 0;";
    let counts = UnsafeCounts::from_source(source);
    assert_eq!(
        counts,
        UnsafeCounts {
            prohibited: 1,
            ..UnsafeCounts::new(0, 0, 0, 0)
        }
    );
    assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
    assert!(!unsafe_counts_allowed(
        "src/rename/windows_native.rs",
        counts
    ));
}

#[test]
fn rust_source_whitespace_preserves_unsafe_block_and_mutable_static_adjacency() {
    // Rust's Pattern_White_Space set includes vertical tab and five Unicode scalars.
    for separator in [
        '\u{0009}', '\u{000A}', '\u{000B}', '\u{000C}', '\u{000D}', '\u{0020}', '\u{0085}',
        '\u{200E}', '\u{200F}', '\u{2028}', '\u{2029}',
    ] {
        let source = format!("unsafe{separator}{{}}");
        let counts = UnsafeCounts::from_source(&source);
        assert_eq!(counts, UnsafeCounts::new(1, 0, 0, 0), "{source:?}");
        assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
        assert!(unsafe_counts_allowed(
            "src/rename/windows_native.rs",
            counts
        ));

        let source = format!("static{separator}mut VALUE: u32 = 0;");
        let counts = UnsafeCounts::from_source(&source);
        assert_eq!(
            counts,
            UnsafeCounts {
                prohibited: 1,
                ..UnsafeCounts::new(0, 0, 0, 0)
            },
            "{source:?}"
        );
        assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
        assert!(!unsafe_counts_allowed(
            "src/rename/windows_native.rs",
            counts
        ));
        assert!(!unsafe_counts_allowed("src/windows.rs", counts));
    }
}

#[test]
fn rust_source_whitespace_preserves_other_unsafe_construct_permissions() {
    let cases = [
        (
            "unsafe",
            "fn callback() {}",
            UnsafeCounts::new(0, 1, 0, 0),
            true,
        ),
        (
            "unsafe",
            "extern \"C\" fn callback() {}",
            UnsafeCounts::new(0, 0, 1, 0),
            true,
        ),
        (
            "unsafe",
            "impl Trait for Type {}",
            UnsafeCounts::new(0, 0, 0, 1),
            false,
        ),
        (
            "unsafe",
            "trait Trait {}",
            UnsafeCounts {
                prohibited: 1,
                ..UnsafeCounts::new(0, 0, 0, 0)
            },
            false,
        ),
        (
            "#[unsafe",
            "(no_mangle)] fn export() {}",
            UnsafeCounts {
                prohibited: 1,
                ..UnsafeCounts::new(0, 0, 0, 0)
            },
            false,
        ),
    ];
    for separator in [
        '\u{0009}', '\u{000A}', '\u{000B}', '\u{000C}', '\u{000D}', '\u{0020}', '\u{0085}',
        '\u{200E}', '\u{200F}', '\u{2028}', '\u{2029}',
    ] {
        for (prefix, suffix, expected, allowed_in_windows) in cases {
            let source = format!("{prefix}{separator}{suffix}");
            let counts = UnsafeCounts::from_source(&source);
            assert_eq!(counts, expected, "{source:?}");
            assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
            assert!(!unsafe_counts_allowed(
                "src/rename/windows_native.rs",
                counts
            ));
            assert_eq!(
                unsafe_counts_allowed("src/windows.rs", counts),
                allowed_in_windows,
                "{source:?}"
            );
        }
    }
}

#[test]
fn non_rust_whitespace_and_punctuation_do_not_join_unsafe_tokens() {
    // These strings are scanner inputs, not valid Rust source examples.
    for separator in ['\u{00A0}', '\u{2003}', '\u{3002}'] {
        for source in [
            format!("unsafe{separator}{{}}"),
            format!("static{separator}mut VALUE: u32 = 0;"),
        ] {
            let counts = UnsafeCounts::from_source(&source);
            assert_eq!(counts, UnsafeCounts::new(0, 0, 0, 0), "{source:?}");
            assert!(unsafe_counts_allowed("src/windows/new_module.rs", counts));
        }
    }
}

#[test]
fn unicode_source_whitespace_does_not_end_line_comments() {
    for separator in [
        '\u{0009}', '\u{000B}', '\u{000C}', '\u{000D}', '\u{0020}', '\u{0085}', '\u{200E}',
        '\u{200F}', '\u{2028}', '\u{2029}',
    ] {
        let source = format!("// comment{separator}unsafe {{}} static mut VALUE: u32 = 0;");
        assert_eq!(
            UnsafeCounts::from_source(&source),
            UnsafeCounts::new(0, 0, 0, 0),
            "{source:?}"
        );

        let source = format!("{source}\nunsafe {{}} static mut VALUE: u32 = 0;");
        assert_eq!(
            UnsafeCounts::from_source(&source),
            UnsafeCounts {
                prohibited: 1,
                ..UnsafeCounts::new(1, 0, 0, 0)
            },
            "{source:?}"
        );
    }
}

#[test]
fn identifier_table_matches_the_pinned_rust_unicode_version() {
    assert_eq!(unicode_ident::UNICODE_VERSION, std::char::UNICODE_VERSION);
}

#[test]
fn strings_and_nested_comments_still_hide_only_their_own_contents() {
    for source in [
        r#"const ORDINARY: &str = "unsafe { static mut }";"#,
        r#"const BYTE: &[u8] = b"unsafe { static mut }";"#,
        r#"const C_STRING: &core::ffi::CStr = c"unsafe { static mut }";"#,
        r####"const RAW: &str = r##"unsafe { static mut }"##;"####,
        r####"const RAW_BYTE: &[u8] = br##"unsafe { static mut }"##;"####,
        "/* outer /* unsafe { static mut } */ still a comment */",
    ] {
        let counts = UnsafeCounts::from_source(source);
        assert_eq!(counts, UnsafeCounts::new(0, 0, 0, 0), "{source}");
        assert!(
            unsafe_counts_allowed("src/windows/new_module.rs", counts),
            "{source}"
        );
    }

    let source = "/* outer /* unsafe {} */ closed */ unsafe {}";
    let counts = UnsafeCounts::from_source(source);
    assert_eq!(counts, UnsafeCounts::new(1, 0, 0, 0));
    assert!(!unsafe_counts_allowed("src/windows/new_module.rs", counts));
}

fn rust_tokens(source: &str) -> Vec<RustToken> {
    let bytes = source.as_bytes();
    let mut tokens = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        let Some(character) = source.get(index..).and_then(|rest| rest.chars().next()) else {
            break;
        };
        if is_rust_source_whitespace(character) {
            index += character.len_utf8();
            continue;
        }
        if bytes[index..].starts_with(b"//") {
            index += 2;
            while index < bytes.len() && bytes[index] != b'\n' {
                index += 1;
            }
            continue;
        }
        if bytes[index..].starts_with(b"/*") {
            index = skip_block_comment(bytes, index);
            continue;
        }
        if let Some(end) = character_literal_end(source, index) {
            index = end;
            continue;
        }
        if bytes[index] == b'\''
            && let Some(end) = lifetime_end(source, index)
        {
            index = end;
            continue;
        }
        if let Some(end) = quoted_literal_end(bytes, index) {
            index = end;
            continue;
        }
        if let Some(end) = identifier_end(source, index) {
            let start = index;
            index = end;
            tokens.push(RustToken::Identifier(source[start..index].to_owned()));
            continue;
        }
        tokens.push(RustToken::Punctuation(bytes[index]));
        index += character.len_utf8();
    }
    tokens
}

fn lifetime_end(source: &str, apostrophe: usize) -> Option<usize> {
    let start = apostrophe + 1;
    let name = if source.get(start..)?.starts_with("r#") {
        start + 2
    } else {
        start
    };
    identifier_end(source, name)
}

fn identifier_end(source: &str, start: usize) -> Option<usize> {
    let mut characters = source.get(start..)?.char_indices();
    let (_, first) = characters.next()?;
    if !is_identifier_start(first) {
        return None;
    }
    let mut end = start + first.len_utf8();
    for (offset, character) in characters {
        if !is_identifier_continue(character) {
            break;
        }
        end = start + offset + character.len_utf8();
    }
    Some(end)
}

fn skip_block_comment(bytes: &[u8], mut index: usize) -> usize {
    let mut depth = 0_usize;
    while index < bytes.len() {
        if bytes[index..].starts_with(b"/*") {
            depth += 1;
            index += 2;
        } else if bytes[index..].starts_with(b"*/") {
            depth = depth.saturating_sub(1);
            index += 2;
            if depth == 0 {
                break;
            }
        } else {
            index += 1;
        }
    }
    index
}

fn character_literal_end(source: &str, index: usize) -> Option<usize> {
    let bytes = source.as_bytes();
    let quote = if bytes.get(index) == Some(&b'b') {
        index + 1
    } else {
        index
    };
    if bytes.get(quote) != Some(&b'\'') {
        return None;
    }
    let character = quote + 1;
    let end = if bytes.get(character) == Some(&b'\\') {
        let escape = character + 1;
        match bytes.get(escape)? {
            b'0' | b'n' | b'r' | b't' | b'\\' | b'\'' | b'"' => escape + 1,
            b'x' if bytes.get(escape + 1)?.is_ascii_hexdigit()
                && bytes.get(escape + 2)?.is_ascii_hexdigit() =>
            {
                escape + 3
            }
            b'u' if bytes.get(escape + 1) == Some(&b'{') => {
                let mut digit = escape + 2;
                let mut has_hex_digit = false;
                while bytes
                    .get(digit)
                    .is_some_and(|byte| byte.is_ascii_hexdigit() || *byte == b'_')
                {
                    has_hex_digit |= bytes[digit].is_ascii_hexdigit();
                    digit += 1;
                }
                if !has_hex_digit || bytes.get(digit) != Some(&b'}') {
                    return None;
                }
                digit + 1
            }
            _ => return None,
        }
    } else {
        character + source.get(character..)?.chars().next()?.len_utf8()
    };
    (bytes.get(end) == Some(&b'\'')).then_some(end + 1)
}

fn quoted_literal_end(bytes: &[u8], index: usize) -> Option<usize> {
    let mut quote = index;
    if matches!(bytes.get(index), Some(b'b' | b'c')) {
        quote += 1;
    }
    if bytes.get(quote) == Some(&b'r') {
        quote += 1;
        let mut hashes = 0_usize;
        while bytes.get(quote) == Some(&b'#') {
            hashes += 1;
            quote += 1;
        }
        if bytes.get(quote) != Some(&b'"') {
            return None;
        }
        quote += 1;
        while quote < bytes.len() {
            if bytes[quote] == b'"'
                && bytes
                    .get(quote + 1..quote + 1 + hashes)
                    .is_some_and(|suffix| suffix.iter().all(|byte| *byte == b'#'))
            {
                return Some(quote + 1 + hashes);
            }
            quote += 1;
        }
        return Some(bytes.len());
    }
    if bytes.get(quote) != Some(&b'"') {
        return None;
    }
    quote += 1;
    while quote < bytes.len() {
        match bytes[quote] {
            b'\\' => quote = (quote + 2).min(bytes.len()),
            b'"' => return Some(quote + 1),
            _ => quote += 1,
        }
    }
    Some(bytes.len())
}

fn is_identifier_start(character: char) -> bool {
    character == '_' || unicode_ident::is_xid_start(character)
}

fn is_rust_source_whitespace(character: char) -> bool {
    matches!(
        character,
        '\u{0009}'
            | '\u{000A}'
            | '\u{000B}'
            | '\u{000C}'
            | '\u{000D}'
            | '\u{0020}'
            | '\u{0085}'
            | '\u{200E}'
            | '\u{200F}'
            | '\u{2028}'
            | '\u{2029}'
    )
}

fn is_identifier_continue(character: char) -> bool {
    character == '_' || unicode_ident::is_xid_continue(character)
}
