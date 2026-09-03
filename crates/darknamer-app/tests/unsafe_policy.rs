//! Exact lexical budget for the package's explicitly allowed native unsafe code.

use std::collections::BTreeMap;

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

const EXPECTED: &[(&str, UnsafeCounts)] = &[
    (
        "src/rename/windows_backend.rs",
        UnsafeCounts::new(3, 0, 0, 0),
    ),
    (
        "src/rename/windows_native.rs",
        UnsafeCounts::new(18, 0, 0, 0),
    ),
    ("src/windows.rs", UnsafeCounts::new(179, 7, 1, 0)),
    ("src/windows/appearance.rs", UnsafeCounts::new(59, 0, 0, 0)),
    (
        "src/windows/appearance_dialog.rs",
        UnsafeCounts::new(153, 0, 3, 0),
    ),
    (
        "src/windows/application.rs",
        UnsafeCounts::new(128, 0, 1, 0),
    ),
    ("src/windows/clipboard.rs", UnsafeCounts::new(11, 0, 0, 0)),
    (
        "src/windows/command_dispatch.rs",
        UnsafeCounts::new(10, 0, 0, 0),
    ),
    (
        "src/windows/command_rail.rs",
        UnsafeCounts::new(20, 0, 0, 0),
    ),
    ("src/windows/dialog.rs", UnsafeCounts::new(75, 0, 1, 0)),
    ("src/windows/drag_drop.rs", UnsafeCounts::new(103, 5, 38, 0)),
    ("src/windows/list_view.rs", UnsafeCounts::new(79, 1, 1, 0)),
    ("src/windows/menu.rs", UnsafeCounts::new(63, 0, 0, 0)),
    ("src/windows/recovery_ui.rs", UnsafeCounts::new(2, 0, 0, 0)),
    ("src/windows/text_io.rs", UnsafeCounts::new(3, 0, 0, 0)),
    (
        "src/windows/visual_capture.rs",
        UnsafeCounts::new(21, 0, 0, 0),
    ),
    ("src/windows/worker.rs", UnsafeCounts::new(20, 0, 0, 0)),
    (
        "tests/rename_windows_backend.rs",
        UnsafeCounts::new(1, 0, 0, 0),
    ),
];

#[test]
fn unsafe_source_inventory_matches_the_reviewed_budget() -> Result<(), Box<dyn std::error::Error>> {
    let mut actual = BTreeMap::new();
    for &(relative, source) in BUILD_SOURCE_FILES {
        if relative == POLICY_FILE {
            continue;
        }
        let counts = UnsafeCounts::from_source(source);
        if !counts.is_empty() {
            actual.insert(relative.to_owned(), counts);
        }
    }

    let expected = EXPECTED
        .iter()
        .map(|(path, counts)| ((*path).to_owned(), *counts))
        .collect::<BTreeMap<_, _>>();
    assert_eq!(
        actual, expected,
        "unsafe inventory changed; review the native boundary and update exact budgets for both increases and reductions"
    );
    Ok(())
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
            .any(|(path, source)| *path == POLICY_FILE && source.contains("const EXPECTED"))
    );
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
