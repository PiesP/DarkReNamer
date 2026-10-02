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
    assert!(BUILD_SOURCE_FILES.iter().all(|(_, source)| rust_tokens(source)
        .iter()
        .all(|token| !matches!(token, RustToken::Identifier(value) if value == "TaskDialogIndirect"))));
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

fn rust_tokens(source: &str) -> Vec<RustToken> {
    let bytes = source.as_bytes();
    let mut tokens = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index].is_ascii_whitespace() {
            index += 1;
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
        if let Some(end) = quoted_literal_end(bytes, index) {
            index = end;
            continue;
        }
        if is_identifier_start(bytes[index]) {
            let start = index;
            index += 1;
            while index < bytes.len() && is_identifier_continue(bytes[index]) {
                index += 1;
            }
            tokens.push(RustToken::Identifier(source[start..index].to_owned()));
            continue;
        }
        tokens.push(RustToken::Punctuation(bytes[index]));
        index += 1;
    }
    tokens
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

const fn is_identifier_start(byte: u8) -> bool {
    byte == b'_' || byte.is_ascii_alphabetic()
}

const fn is_identifier_continue(byte: u8) -> bool {
    is_identifier_start(byte) || byte.is_ascii_digit()
}
