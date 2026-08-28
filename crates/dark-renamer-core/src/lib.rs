//! Portable, deterministic rename rules and safety-first batch planning.
//!
//! This crate transforms file names only. It never reads or mutates the file
//! system. Callers provide occupied paths observed at admission time, then use
//! the immutable [`RenamePlan`] as input to a separately revalidated executor.

#![forbid(unsafe_code)]

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

/// Maximum accepted padding width for a generated digit run or sequence.
///
/// This matches the conventional Windows maximum filename-component length and
/// prevents untrusted rule input from requesting unbounded allocation.
pub const MAX_GENERATED_WIDTH: usize = 255;

/// Selects where a sequence number is inserted in the file stem.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SequencePlacement {
    /// Insert the number and separator before the stem.
    Prefix,
    /// Insert the separator and number after the stem.
    Suffix,
}

/// Selects a case transformation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CaseStyle {
    /// Convert every Unicode scalar to its lowercase mapping.
    Lower,
    /// Convert every Unicode scalar to its uppercase mapping.
    Upper,
    /// Uppercase the first alphanumeric scalar of each word and lowercase the rest.
    Title,
}

/// Selects the filename component affected by case conversion.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CaseTarget {
    /// Convert the stem but preserve extension case.
    Stem,
    /// Convert the extension but preserve stem case.
    Extension,
    /// Convert both stem and extension independently.
    StemAndExtension,
}

/// An ordered, portable filename transformation.
///
/// Text rules operate on the stem. Extension rules are explicit so ordinary
/// replacements cannot accidentally rewrite an extension.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RenameRule {
    /// Replace every case-sensitive occurrence of `from` in the stem.
    LiteralReplace {
        /// Text to find. An empty value produces a blocking diagnostic.
        from: String,
        /// Replacement text.
        to: String,
    },
    /// Add text before the stem.
    Prefix(String),
    /// Add text after the stem and before the extension.
    Suffix(String),
    /// Remove the complete stem while retaining the extension.
    ClearStem,
    /// Remove `count` Unicode scalar values from the stem at zero-based `start`.
    RemoveCharacterRange {
        /// Zero-based Unicode scalar-value position.
        start: usize,
        /// Number of Unicode scalar values to remove.
        count: usize,
    },
    /// Retain only ASCII decimal digits in the stem.
    KeepDigits,
    /// Left-pad every contiguous ASCII digit run to at least `width` digits.
    PadDigitRuns {
        /// Minimum width of each run. Zero leaves runs unchanged.
        width: usize,
    },
    /// Add a deterministic sequence number based on source input order.
    Sequence {
        /// Value assigned to the first source.
        start: u64,
        /// Increment between consecutive sources.
        step: u64,
        /// Minimum decimal width, padded with zeroes.
        width: usize,
        /// Text placed between the sequence and stem.
        separator: String,
        /// Whether the sequence precedes or follows the stem.
        placement: SequencePlacement,
    },
    /// Remove the final extension, if one exists.
    RemoveExtension,
    /// Append an extension, retaining the previous extension as part of the stem.
    AddExtension(String),
    /// Replace the final extension, or add it if none exists.
    ReplaceExtension(String),
    /// Convert case for the selected filename component.
    ConvertCase {
        /// Case mapping to apply.
        style: CaseStyle,
        /// Filename component to transform.
        target: CaseTarget,
    },
}

/// A structured reason that a plan row cannot be executed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Diagnostic {
    /// The source path has no final filename component.
    MissingFileName,
    /// The filename cannot be represented as Unicode for text transformations.
    NonUnicodeFileName,
    /// A literal replacement rule has an empty search value.
    EmptyLiteralSearch {
        /// Zero-based position of the invalid rule.
        rule_index: usize,
    },
    /// An extension rule has no extension after optional leading periods.
    EmptyExtension {
        /// Zero-based position of the invalid rule.
        rule_index: usize,
    },
    /// Sequence arithmetic exceeded the supported unsigned range.
    SequenceOverflow {
        /// Zero-based position of the sequence rule.
        rule_index: usize,
    },
    /// A digit-padding or sequence width exceeds [`MAX_GENERATED_WIDTH`].
    GeneratedWidthTooLarge {
        /// Zero-based position of the invalid rule.
        rule_index: usize,
        /// Requested minimum width.
        width: usize,
        /// Maximum accepted minimum width.
        maximum: usize,
    },
    /// The proposed filename is empty.
    EmptyName,
    /// The proposed filename contains a character Windows forbids.
    InvalidCharacter {
        /// First invalid character found.
        character: char,
    },
    /// The proposed filename ends in a period or space.
    TrailingDotOrSpace,
    /// The proposed filename resolves to a reserved Windows device name.
    ReservedDeviceName {
        /// Reserved base name as proposed by the rules.
        name: OsString,
    },
    /// Multiple participant rows propose the same Windows-equivalent target.
    DuplicateTarget {
        /// Proposed filename for this row.
        name: OsString,
        /// All zero-based participant row indices sharing the target.
        rows: Box<[usize]>,
    },
    /// A nonparticipant sibling already occupies the proposed target.
    OccupiedTarget {
        /// Occupied path supplied by the caller.
        path: PathBuf,
    },
}

/// Execution eligibility of one plan row.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RowState {
    /// The proposed filename is byte-for-byte identical to the original filename.
    Unchanged,
    /// The row changes and has no known blocker.
    Ready,
    /// At least one structured diagnostic blocks the row.
    Blocked,
}

/// Immutable input to deterministic planning.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct PlanningRequest {
    sources: Box<[PathBuf]>,
    rules: Box<[RenameRule]>,
    occupied_paths: Box<[PathBuf]>,
}

impl PlanningRequest {
    /// Creates a request whose source order defines sequence-number order.
    #[must_use]
    pub fn new(sources: impl IntoIterator<Item = PathBuf>) -> Self {
        Self {
            sources: sources.into_iter().collect(),
            rules: Box::default(),
            occupied_paths: Box::default(),
        }
    }

    /// Replaces the ordered rule list.
    #[must_use]
    pub fn with_rules(mut self, rules: impl IntoIterator<Item = RenameRule>) -> Self {
        self.rules = rules.into_iter().collect();
        self
    }

    /// Replaces the paths known to be occupied at admission time.
    ///
    /// Participant source paths may be included. They are removed from the
    /// occupied set so swaps and longer cycles remain eligible for staged
    /// execution.
    #[must_use]
    pub fn with_occupied_paths(mut self, paths: impl IntoIterator<Item = PathBuf>) -> Self {
        self.occupied_paths = paths.into_iter().collect();
        self
    }

    /// Returns source paths in deterministic planning order.
    #[must_use]
    pub fn sources(&self) -> &[PathBuf] {
        &self.sources
    }

    /// Returns ordered filename rules.
    #[must_use]
    pub fn rules(&self) -> &[RenameRule] {
        &self.rules
    }

    /// Returns paths observed as occupied by the caller.
    #[must_use]
    pub fn occupied_paths(&self) -> &[PathBuf] {
        &self.occupied_paths
    }
}

/// One immutable before/after planning result.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanRow {
    index: usize,
    source_path: PathBuf,
    target_path: PathBuf,
    original_name: OsString,
    proposed_name: OsString,
    state: RowState,
    diagnostics: Box<[Diagnostic]>,
}

impl PlanRow {
    /// Returns this row's stable position within the plan.
    #[must_use]
    pub const fn index(&self) -> usize {
        self.index
    }

    /// Returns the caller-provided source path.
    #[must_use]
    pub fn source_path(&self) -> &Path {
        &self.source_path
    }

    /// Returns the proposed sibling target path.
    #[must_use]
    pub fn target_path(&self) -> &Path {
        &self.target_path
    }

    /// Returns the original final filename without lossy conversion.
    #[must_use]
    pub fn original_name(&self) -> &OsStr {
        &self.original_name
    }

    /// Returns the proposed final filename without lossy conversion.
    #[must_use]
    pub fn proposed_name(&self) -> &OsStr {
        &self.proposed_name
    }

    /// Returns whether this row is unchanged, ready, or blocked.
    #[must_use]
    pub const fn state(&self) -> RowState {
        self.state
    }

    /// Returns all blocking diagnostics for this row.
    #[must_use]
    pub fn diagnostics(&self) -> &[Diagnostic] {
        &self.diagnostics
    }

    /// Returns whether this row proposes a different filename.
    #[must_use]
    pub fn is_changed(&self) -> bool {
        self.original_name != self.proposed_name
    }

    /// Returns whether this row has any blocker.
    #[must_use]
    pub const fn is_blocked(&self) -> bool {
        matches!(self.state, RowState::Blocked)
    }
}

/// Immutable result of planning a complete batch.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RenamePlan {
    rows: Box<[PlanRow]>,
}

impl RenamePlan {
    /// Returns rows in source input order.
    #[must_use]
    pub fn rows(&self) -> &[PlanRow] {
        &self.rows
    }

    /// Returns the number of rows that propose a different filename.
    #[must_use]
    pub fn changed_count(&self) -> usize {
        self.rows.iter().filter(|row| row.is_changed()).count()
    }

    /// Returns whether at least one row changes and no row is blocked.
    #[must_use]
    pub fn can_apply(&self) -> bool {
        self.changed_count() > 0 && self.rows.iter().all(|row| !row.is_blocked())
    }
}

#[derive(Debug)]
struct NameParts {
    stem: String,
    extension: Option<String>,
}

impl NameParts {
    fn parse(name: &str) -> Self {
        let extension_start = name.rfind('.').filter(|position| *position > 0);
        match extension_start {
            Some(position) => Self {
                stem: name[..position].to_owned(),
                extension: Some(name[position + 1..].to_owned()),
            },
            None => Self {
                stem: name.to_owned(),
                extension: None,
            },
        }
    }

    fn render(&self) -> String {
        match &self.extension {
            Some(extension) => {
                let mut rendered = String::with_capacity(self.stem.len() + extension.len() + 1);
                rendered.push_str(&self.stem);
                rendered.push('.');
                rendered.push_str(extension);
                rendered
            }
            None => self.stem.clone(),
        }
    }
}

/// Builds a deterministic immutable rename plan without filesystem access.
#[must_use]
pub fn plan(request: &PlanningRequest) -> RenamePlan {
    let mut rows = Vec::with_capacity(request.sources.len());

    for (index, source_path) in request.sources.iter().enumerate() {
        rows.push(plan_row(index, source_path, &request.rules));
    }

    add_duplicate_diagnostics(&mut rows);
    add_occupied_diagnostics(&mut rows, &request.occupied_paths);
    settle_states(&mut rows);

    RenamePlan { rows: rows.into() }
}

fn plan_row(index: usize, source_path: &Path, rules: &[RenameRule]) -> PlanRow {
    let original_name = source_path
        .file_name()
        .map_or_else(OsString::new, OsStr::to_os_string);
    let mut diagnostics = Vec::new();

    if source_path.file_name().is_none() {
        diagnostics.push(Diagnostic::MissingFileName);
    }

    let proposed_name = match original_name.to_str() {
        Some(name) => {
            let mut parts = NameParts::parse(name);
            apply_rules(&mut parts, rules, index, &mut diagnostics);
            let proposed = parts.render();
            validate_windows_name(&proposed, &mut diagnostics);
            OsString::from(proposed)
        }
        None => {
            diagnostics.push(Diagnostic::NonUnicodeFileName);
            original_name.clone()
        }
    };

    let target_path = source_path.with_file_name(&proposed_name);

    PlanRow {
        index,
        source_path: source_path.to_path_buf(),
        target_path,
        original_name,
        proposed_name,
        state: RowState::Unchanged,
        diagnostics: diagnostics.into(),
    }
}

fn apply_rules(
    parts: &mut NameParts,
    rules: &[RenameRule],
    row_index: usize,
    diagnostics: &mut Vec<Diagnostic>,
) {
    for (rule_index, rule) in rules.iter().enumerate() {
        match rule {
            RenameRule::LiteralReplace { from, to } => {
                if from.is_empty() {
                    diagnostics.push(Diagnostic::EmptyLiteralSearch { rule_index });
                } else {
                    parts.stem = parts.stem.replace(from, to);
                }
            }
            RenameRule::Prefix(prefix) => parts.stem.insert_str(0, prefix),
            RenameRule::Suffix(suffix) => parts.stem.push_str(suffix),
            RenameRule::ClearStem => parts.stem.clear(),
            RenameRule::RemoveCharacterRange { start, count } => {
                parts.stem = remove_character_range(&parts.stem, *start, *count);
            }
            RenameRule::KeepDigits => parts.stem.retain(|character| character.is_ascii_digit()),
            RenameRule::PadDigitRuns { width } => {
                if *width > MAX_GENERATED_WIDTH {
                    diagnostics.push(Diagnostic::GeneratedWidthTooLarge {
                        rule_index,
                        width: *width,
                        maximum: MAX_GENERATED_WIDTH,
                    });
                } else {
                    parts.stem = pad_digit_runs(&parts.stem, *width);
                }
            }
            RenameRule::Sequence {
                start,
                step,
                width,
                separator,
                placement,
            } if *width > MAX_GENERATED_WIDTH => {
                diagnostics.push(Diagnostic::GeneratedWidthTooLarge {
                    rule_index,
                    width: *width,
                    maximum: MAX_GENERATED_WIDTH,
                });
            }
            RenameRule::Sequence {
                start,
                step,
                width,
                separator,
                placement,
            } => match sequence_value(*start, *step, row_index) {
                Some(value) => {
                    let number = padded_number(value, *width);
                    match placement {
                        SequencePlacement::Prefix => {
                            let mut stem = String::with_capacity(
                                number.len() + separator.len() + parts.stem.len(),
                            );
                            stem.push_str(&number);
                            stem.push_str(separator);
                            stem.push_str(&parts.stem);
                            parts.stem = stem;
                        }
                        SequencePlacement::Suffix => {
                            parts.stem.reserve(separator.len() + number.len());
                            parts.stem.push_str(separator);
                            parts.stem.push_str(&number);
                        }
                    }
                }
                None => diagnostics.push(Diagnostic::SequenceOverflow { rule_index }),
            },
            RenameRule::RemoveExtension => parts.extension = None,
            RenameRule::AddExtension(extension) => {
                if let Some(extension) = normalized_extension(extension) {
                    parts.stem = parts.render();
                    parts.extension = Some(extension.to_owned());
                } else {
                    diagnostics.push(Diagnostic::EmptyExtension { rule_index });
                }
            }
            RenameRule::ReplaceExtension(extension) => {
                if let Some(extension) = normalized_extension(extension) {
                    parts.extension = Some(extension.to_owned());
                } else {
                    diagnostics.push(Diagnostic::EmptyExtension { rule_index });
                }
            }
            RenameRule::ConvertCase { style, target } => match target {
                CaseTarget::Stem => parts.stem = convert_case(&parts.stem, *style),
                CaseTarget::Extension => {
                    if let Some(extension) = &mut parts.extension {
                        *extension = convert_case(extension, *style);
                    }
                }
                CaseTarget::StemAndExtension => {
                    parts.stem = convert_case(&parts.stem, *style);
                    if let Some(extension) = &mut parts.extension {
                        *extension = convert_case(extension, *style);
                    }
                }
            },
        }
    }
}

fn normalized_extension(extension: &str) -> Option<&str> {
    let normalized = extension.trim_start_matches('.');
    (!normalized.is_empty()).then_some(normalized)
}

fn remove_character_range(value: &str, start: usize, count: usize) -> String {
    let end = start.saturating_add(count);
    value
        .chars()
        .enumerate()
        .filter_map(|(index, character)| (!(start..end).contains(&index)).then_some(character))
        .collect()
}

fn pad_digit_runs(value: &str, width: usize) -> String {
    let mut padded = String::with_capacity(value.len());
    let mut characters = value.chars().peekable();

    while let Some(character) = characters.next() {
        if character.is_ascii_digit() {
            let mut run = String::from(character);
            while characters.peek().is_some_and(char::is_ascii_digit) {
                if let Some(digit) = characters.next() {
                    run.push(digit);
                }
            }
            padded.extend(std::iter::repeat_n('0', width.saturating_sub(run.len())));
            padded.push_str(&run);
        } else {
            padded.push(character);
        }
    }

    padded
}

fn sequence_value(start: u64, step: u64, row_index: usize) -> Option<u64> {
    let index = u64::try_from(row_index).ok()?;
    step.checked_mul(index)
        .and_then(|increment| start.checked_add(increment))
}

fn padded_number(value: u64, width: usize) -> String {
    let value = value.to_string();
    let mut padded = String::with_capacity(width.max(value.len()));
    padded.extend(std::iter::repeat_n('0', width.saturating_sub(value.len())));
    padded.push_str(&value);
    padded
}

fn convert_case(value: &str, style: CaseStyle) -> String {
    match style {
        CaseStyle::Lower => value.chars().flat_map(char::to_lowercase).collect(),
        CaseStyle::Upper => value.chars().flat_map(char::to_uppercase).collect(),
        CaseStyle::Title => title_case(value),
    }
}

fn title_case(value: &str) -> String {
    let mut converted = String::with_capacity(value.len());
    let mut begins_word = true;

    for character in value.chars() {
        if character.is_alphanumeric() {
            if begins_word {
                converted.extend(character.to_uppercase());
                begins_word = false;
            } else {
                converted.extend(character.to_lowercase());
            }
        } else {
            converted.push(character);
            begins_word = true;
        }
    }

    converted
}

fn validate_windows_name(name: &str, diagnostics: &mut Vec<Diagnostic>) {
    if name.is_empty() {
        diagnostics.push(Diagnostic::EmptyName);
        return;
    }

    if let Some(character) = name.chars().find(|character| {
        character.is_ascii_control()
            || matches!(
                character,
                '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
            )
    }) {
        diagnostics.push(Diagnostic::InvalidCharacter { character });
    }

    if name.ends_with(['.', ' ']) {
        diagnostics.push(Diagnostic::TrailingDotOrSpace);
    }

    if is_reserved_device_name(name) {
        diagnostics.push(Diagnostic::ReservedDeviceName {
            name: OsString::from(name),
        });
    }
}

fn is_reserved_device_name(name: &str) -> bool {
    let base = name
        .split_once('.')
        .map_or(name, |(base, _extension)| base)
        .trim_end_matches([' ', '.'])
        .to_ascii_uppercase();

    matches!(
        base.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || device_number(&base, "COM")
        || device_number(&base, "LPT")
}

fn device_number(base: &str, prefix: &str) -> bool {
    base.strip_prefix(prefix).is_some_and(|suffix| {
        matches!(
            suffix,
            "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
        )
    })
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum ParentKey {
    Unicode(String),
    Native(OsString),
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct WindowsPathKey {
    parent: ParentKey,
    file_name: String,
}

fn add_duplicate_diagnostics(rows: &mut [PlanRow]) {
    let mut targets: BTreeMap<WindowsPathKey, Vec<usize>> = BTreeMap::new();
    for row in rows.iter() {
        if let Some(key) = windows_path_key(&row.target_path) {
            targets.entry(key).or_default().push(row.index);
        }
    }

    for indices in targets.into_values().filter(|indices| indices.len() > 1) {
        let shared_rows: Box<[usize]> = indices.clone().into();
        for index in indices {
            if let Some(row) = rows.get_mut(index) {
                row.diagnostics = append_diagnostic(
                    &row.diagnostics,
                    Diagnostic::DuplicateTarget {
                        name: row.proposed_name.clone(),
                        rows: shared_rows.clone(),
                    },
                );
            }
        }
    }
}

fn add_occupied_diagnostics(rows: &mut [PlanRow], occupied_paths: &[PathBuf]) {
    let participant_keys: BTreeSet<WindowsPathKey> = rows
        .iter()
        .filter_map(|row| windows_path_key(&row.source_path))
        .collect();

    let occupied: BTreeMap<WindowsPathKey, &PathBuf> = occupied_paths
        .iter()
        .filter_map(|path| windows_path_key(path).map(|key| (key, path)))
        .filter(|(key, _path)| !participant_keys.contains(key))
        .collect();

    for row in rows {
        if let Some(path) = windows_path_key(&row.target_path).and_then(|key| occupied.get(&key)) {
            row.diagnostics = append_diagnostic(
                &row.diagnostics,
                Diagnostic::OccupiedTarget {
                    path: (*path).clone(),
                },
            );
        }
    }
}

fn append_diagnostic(existing: &[Diagnostic], diagnostic: Diagnostic) -> Box<[Diagnostic]> {
    let mut diagnostics = Vec::with_capacity(existing.len() + 1);
    diagnostics.extend_from_slice(existing);
    diagnostics.push(diagnostic);
    diagnostics.into()
}

fn windows_path_key(path: &Path) -> Option<WindowsPathKey> {
    let parent = path.parent().unwrap_or_else(|| Path::new(""));
    let parent = match parent.to_str() {
        Some(parent) => ParentKey::Unicode(windows_case_key(parent)),
        None => ParentKey::Native(parent.as_os_str().to_os_string()),
    };
    let file_name = windows_case_key(path.file_name()?.to_str()?);
    Some(WindowsPathKey { parent, file_name })
}

fn windows_case_key(value: &str) -> String {
    value.chars().flat_map(char::to_uppercase).collect()
}

fn settle_states(rows: &mut [PlanRow]) {
    for row in rows {
        row.state = if !row.diagnostics.is_empty() {
            RowState::Blocked
        } else if row.is_changed() {
            RowState::Ready
        } else {
            RowState::Unchanged
        };
    }
}

/// Returns the workspace version of the core crate.
#[must_use]
pub const fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_workspace_version() {
        assert_eq!(version(), "0.1.0");
    }

    #[test]
    fn title_case_has_explicit_word_boundaries() {
        assert_eq!(title_case("hELLO-world 42TEST"), "Hello-World 42test");
    }

    #[test]
    fn dotfiles_have_a_stem_and_no_implicit_extension() {
        let parts = NameParts::parse(".env");
        assert_eq!(parts.stem, ".env");
        assert_eq!(parts.extension, None);
    }
}
