//! Pure compatibility model for the DarkNamer 08.02.10 list workbench.
//!
//! The original application was a `_UNICODE` MFC build, so all text indexing
//! and slicing in this crate uses UTF-16 code units instead of Unicode scalar
//! values. This crate performs no filesystem, clipboard, or file I/O.

#![forbid(unsafe_code)]

use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::fmt;
use std::mem;

mod windows_leaf_name;

pub use windows_leaf_name::{WindowsLeafNameError, validate_windows_leaf_name};

const BACKSLASH: u16 = b'\\' as u16;
const DOT: u16 = b'.' as u16;
const CR: u16 = b'\r' as u16;
const LF: u16 = b'\n' as u16;

/// An owned string with the same indexing unit as MFC `CString` in the
/// original `_UNICODE` build.
#[derive(Clone, Default, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct LegacyText {
    units: Vec<u16>,
}

impl LegacyText {
    /// Creates text from exact UTF-16 code units, including unpaired surrogates.
    #[must_use]
    pub fn from_units(units: impl Into<Vec<u16>>) -> Self {
        Self {
            units: units.into(),
        }
    }

    /// Returns the exact UTF-16 representation.
    #[must_use]
    pub fn units(&self) -> &[u16] {
        &self.units
    }

    /// Returns the number of UTF-16 code units.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.units.len()
    }

    /// Returns whether this text contains no code units.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.units.is_empty()
    }

    /// Truncates to at most `length` exact UTF-16 code units.
    pub fn truncate_units(&mut self, length: usize) {
        self.units.truncate(length);
    }

    /// Converts to displayable Unicode, replacing unpaired surrogates.
    #[must_use]
    pub fn to_string_lossy(&self) -> String {
        String::from_utf16_lossy(&self.units)
    }

    /// Compares text case-insensitively with a deterministic Unicode fallback.
    ///
    /// The original used locale-dependent `CompareString`; callers that need a
    /// Windows locale-specific order can use [`LegacyList::sort_by`] and
    /// [`LegacyList::append_batch_by`] with a platform comparator.
    #[must_use]
    pub fn case_insensitive_cmp(&self, other: &Self) -> Ordering {
        lowercase_units(&self.units).cmp(&lowercase_units(&other.units))
    }

    fn push(&mut self, other: &Self) {
        self.units.extend_from_slice(&other.units);
    }

    fn push_unit(&mut self, unit: u16) {
        self.units.push(unit);
    }

    fn insert_front(&mut self, other: &Self) {
        let mut combined = Vec::with_capacity(other.len() + self.len());
        combined.extend_from_slice(other.units());
        combined.extend_from_slice(self.units());
        self.units = combined;
    }

    fn replace_all(&mut self, needle: &Self, replacement: &Self) {
        if needle.is_empty() || needle.len() > self.len() {
            return;
        }
        let mut output = Vec::with_capacity(self.len());
        let mut index = 0;
        while index < self.len() {
            if self.units[index..].starts_with(needle.units()) {
                output.extend_from_slice(replacement.units());
                index += needle.len();
            } else {
                output.push(self.units[index]);
                index += 1;
            }
        }
        self.units = output;
    }

    fn trimmed(&self) -> Self {
        let first = self
            .units
            .iter()
            .position(|unit| !is_trim_unit(*unit))
            .unwrap_or(self.len());
        let last = self
            .units
            .iter()
            .rposition(|unit| !is_trim_unit(*unit))
            .map_or(first, |index| index + 1);
        Self::from_units(self.units[first..last].to_vec())
    }
}

impl From<&str> for LegacyText {
    fn from(value: &str) -> Self {
        Self::from_units(value.encode_utf16().collect::<Vec<_>>())
    }
}

impl From<String> for LegacyText {
    fn from(value: String) -> Self {
        Self::from(value.as_str())
    }
}

impl fmt::Debug for LegacyText {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("LegacyText")
            .field(&self.to_string_lossy())
            .finish()
    }
}

impl fmt::Display for LegacyText {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.to_string_lossy())
    }
}

/// One row from the original report-mode list.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LegacyListItem {
    source_path: LegacyText,
    current_name: LegacyText,
    proposed_name: LegacyText,
    root_path: LegacyText,
    is_directory: bool,
    size: u32,
    actual_size: u64,
    created: u64,
    modified: u64,
}

impl LegacyListItem {
    /// Creates a row from filesystem metadata already collected by the caller.
    #[must_use]
    pub fn new(
        source_path: impl Into<LegacyText>,
        is_directory: bool,
        size: u32,
        created: u64,
        modified: u64,
    ) -> Self {
        Self::new_with_actual_size(
            source_path,
            is_directory,
            size,
            u64::from(size),
            created,
            modified,
        )
    }

    /// Creates a row with both legacy 32-bit and actual 64-bit size values.
    #[must_use]
    pub fn new_with_actual_size(
        source_path: impl Into<LegacyText>,
        is_directory: bool,
        size: u32,
        actual_size: u64,
        created: u64,
        modified: u64,
    ) -> Self {
        let source_path = source_path.into();
        let current_name = path_name(&source_path);
        let root_path = path_root(&source_path);
        Self {
            source_path,
            proposed_name: current_name.clone(),
            current_name,
            root_path,
            is_directory,
            size,
            actual_size,
            created,
            modified,
        }
    }

    /// Returns the original/current full path.
    #[must_use]
    pub const fn source_path(&self) -> &LegacyText {
        &self.source_path
    }

    /// Returns the original/current final name.
    #[must_use]
    pub const fn current_name(&self) -> &LegacyText {
        &self.current_name
    }

    /// Returns the cumulative proposed name.
    #[must_use]
    pub const fn proposed_name(&self) -> &LegacyText {
        &self.proposed_name
    }

    /// Returns the destination root shown in the original list.
    #[must_use]
    pub const fn root_path(&self) -> &LegacyText {
        &self.root_path
    }

    /// Returns whether the row represents a directory.
    #[must_use]
    pub const fn is_directory(&self) -> bool {
        self.is_directory
    }

    /// Returns the original 32-bit size value.
    #[must_use]
    pub const fn size(&self) -> u32 {
        self.size
    }

    /// Returns the full 64-bit size observed at admission.
    #[must_use]
    pub const fn actual_size(&self) -> u64 {
        self.actual_size
    }

    /// Returns the original creation `FILETIME` value.
    #[must_use]
    pub const fn created(&self) -> u64 {
        self.created
    }

    /// Returns the original modification `FILETIME` value.
    #[must_use]
    pub const fn modified(&self) -> u64 {
        self.modified
    }

    /// Returns the exact destination passed to legacy `MoveFile`.
    #[must_use]
    pub fn planned_path(&self) -> LegacyText {
        let mut path = self.root_path.clone();
        path.push_unit(BACKSLASH);
        path.push(&self.proposed_name);
        path
    }
}

/// The ten sort choices exposed by DarkNamer 08.02.10.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LegacySortMode {
    /// Current name, ascending.
    NameAscending,
    /// Current name, descending.
    NameDescending,
    /// Full source path, ascending.
    FullPathAscending,
    /// Full source path, descending.
    FullPathDescending,
    /// File size, ascending.
    SizeAscending,
    /// File size, descending.
    SizeDescending,
    /// Modification time, ascending.
    ModifiedAscending,
    /// Modification time, descending.
    ModifiedDescending,
    /// Creation time, ascending.
    CreatedAscending,
    /// Creation time, descending.
    CreatedDescending,
}

/// File-size ordering policy layered over the legacy sort choices.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SortSemantics {
    /// Compare the full observed 64-bit size.
    SafeActualSize,
    /// Preserve DarkNamer 08.02.10 wrapping 32-bit subtraction.
    LegacyDarkNamer080210,
}

/// Placement and parent-folder reset behavior for legacy sequence numbering.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LegacySequenceMode {
    /// Append the number before the extension.
    Append,
    /// Prepend the number to the stem.
    Prepend,
    /// Append and restart when the adjacent parent path changes.
    AppendRestartPerFolder,
    /// Prepend and restart when the adjacent parent path changes.
    PrependRestartPerFolder,
}

/// Invalid dialog values rejected by the original command handler.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LegacyInputError {
    /// A digit width was zero.
    NonPositiveWidth,
    /// The end position preceded the start position.
    ReversedPositionRange,
    /// A delimiter input had no first UTF-16 code unit.
    EmptyDelimiter,
}

impl fmt::Display for LegacyInputError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NonPositiveWidth => formatter.write_str("digit width must be positive"),
            Self::ReversedPositionRange => formatter.write_str("position range is reversed"),
            Self::EmptyDelimiter => formatter.write_str("both delimiters must be non-empty"),
        }
    }
}

impl std::error::Error for LegacyInputError {}

/// Ordered, cumulative DarkNamer list state.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LegacyList {
    items: Vec<LegacyListItem>,
}

/// Exact outcome of moving selected rows while preserving legacy row results.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MoveRowsOutcome {
    rows: Box<[usize]>,
    changed: bool,
}

impl MoveRowsOutcome {
    /// Returns the normalized selected rows after the move attempt.
    #[must_use]
    pub fn rows(&self) -> &[usize] {
        &self.rows
    }

    /// Returns whether list order actually changed.
    #[must_use]
    pub const fn changed(&self) -> bool {
        self.changed
    }

    /// Consumes the outcome and returns the normalized selected rows.
    #[must_use]
    pub fn into_rows(self) -> Box<[usize]> {
        self.rows
    }
}

impl LegacyList {
    /// Creates an empty list.
    #[must_use]
    pub const fn new() -> Self {
        Self { items: Vec::new() }
    }

    /// Returns all rows in current list order.
    #[must_use]
    pub fn items(&self) -> &[LegacyListItem] {
        &self.items
    }

    /// Returns the number of rows.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.items.len()
    }

    /// Returns whether the list is empty.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Clears all rows and reports whether the list changed.
    pub fn clear(&mut self) -> bool {
        let changed = !self.items.is_empty();
        self.items.clear();
        changed
    }

    /// Appends one row unless its path duplicates an existing row ignoring case.
    pub fn append(&mut self, item: LegacyListItem) -> bool {
        self.append_by(item, LegacyText::case_insensitive_cmp)
    }

    /// Appends one row with a caller-provided locale comparator.
    pub fn append_by(
        &mut self,
        item: LegacyListItem,
        compare_text: impl Fn(&LegacyText, &LegacyText) -> Ordering,
    ) -> bool {
        if self.items.iter().any(|existing| {
            compare_text(existing.source_path(), item.source_path()) == Ordering::Equal
        }) {
            return false;
        }
        self.items.push(item);
        true
    }

    /// Appends a picker/drop/import batch in the source application's sorted
    /// full-path order, skipping paths already present in the list.
    pub fn append_batch(&mut self, items: impl IntoIterator<Item = LegacyListItem>) -> usize {
        self.append_batch_by(items, LegacyText::case_insensitive_cmp)
    }

    /// Appends a batch with a caller-provided locale comparator.
    pub fn append_batch_by<F>(
        &mut self,
        items: impl IntoIterator<Item = LegacyListItem>,
        compare_text: F,
    ) -> usize
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering + Copy,
    {
        let mut accepted = Vec::new();
        for item in items {
            let duplicate_existing = self.items.iter().any(|existing| {
                compare_text(existing.source_path(), item.source_path()) == Ordering::Equal
            });
            if !duplicate_existing {
                accepted.push(item);
            }
        }
        // AddFileItem inserted before existing equal keys, reversing equal
        // paths collected within one picker/drop/import batch.
        accepted.reverse();
        accepted.sort_by(|left, right| compare_text(left.source_path(), right.source_path()));
        let count = accepted.len();
        self.items.extend(accepted);
        count
    }

    /// Removes caller-selected row indices and returns the number removed.
    pub fn remove_rows(&mut self, selected: &[usize]) -> usize {
        let selected = normalized_indices(selected, self.len());
        for index in selected.iter().rev() {
            self.items.remove(*index);
        }
        selected.len()
    }

    /// Moves caller-selected rows one position earlier.
    ///
    /// As in the original ListView handler, selecting the first row makes the
    /// complete move command a no-op.
    pub fn move_rows_earlier(&mut self, selected: &[usize]) -> Box<[usize]> {
        self.move_rows_earlier_changed(selected).into_rows()
    }

    /// Moves selected rows earlier and reports exact order-change state.
    pub fn move_rows_earlier_changed(&mut self, selected: &[usize]) -> MoveRowsOutcome {
        let selected = normalized_indices(selected, self.len());
        if selected.first() == Some(&0) {
            return MoveRowsOutcome {
                rows: selected.into_boxed_slice(),
                changed: false,
            };
        }
        for index in &selected {
            self.items.swap(index - 1, *index);
        }
        let changed = !selected.is_empty();
        let rows = selected
            .into_iter()
            .map(|index| index - 1)
            .collect::<Vec<_>>()
            .into_boxed_slice();
        MoveRowsOutcome { rows, changed }
    }

    /// Moves caller-selected rows one position later.
    ///
    /// Selecting the final row makes the complete move command a no-op.
    pub fn move_rows_later(&mut self, selected: &[usize]) -> Box<[usize]> {
        self.move_rows_later_changed(selected).into_rows()
    }

    /// Moves selected rows later and reports exact order-change state.
    pub fn move_rows_later_changed(&mut self, selected: &[usize]) -> MoveRowsOutcome {
        let selected = normalized_indices(selected, self.len());
        if selected.last().is_some_and(|index| index + 1 == self.len()) {
            return MoveRowsOutcome {
                rows: selected.into_boxed_slice(),
                changed: false,
            };
        }
        for index in selected.iter().rev() {
            self.items.swap(*index, index + 1);
        }
        let changed = !selected.is_empty();
        let rows = selected
            .into_iter()
            .map(|index| index + 1)
            .collect::<Vec<_>>()
            .into_boxed_slice();
        MoveRowsOutcome { rows, changed }
    }

    /// Resets every proposed name to its current/original name (`Ctrl+Z`).
    pub fn reset_proposals(&mut self) {
        let _ = self.reset_proposals_changed();
    }

    /// Resets proposals and returns exactly which proposal rows changed.
    pub fn reset_proposals_changed(&mut self) -> Box<[usize]> {
        changed_proposals(&mut self.items, |item| item.current_name.clone())
    }

    /// Directly changes one proposed name, returning `false` for an invalid row.
    pub fn manual_change(&mut self, index: usize, proposed_name: impl Into<LegacyText>) -> bool {
        let Some(item) = self.items.get_mut(index) else {
            return false;
        };
        item.proposed_name = proposed_name.into();
        true
    }

    /// Directly changes one proposal and reports whether its value changed.
    pub fn manual_change_changed(
        &mut self,
        index: usize,
        proposed_name: impl Into<LegacyText>,
    ) -> bool {
        let Some(item) = self.items.get_mut(index) else {
            return false;
        };
        let proposed_name = proposed_name.into();
        if item.proposed_name == proposed_name {
            return false;
        }
        item.proposed_name = proposed_name;
        true
    }

    /// Records one successful legacy `MoveFile` result.
    ///
    /// The caller invokes this only after the external filesystem operation
    /// succeeds. Other rows remain untouched, preserving partial-success state.
    pub fn record_move_success(&mut self, index: usize) -> bool {
        let Some(item) = self.items.get_mut(index) else {
            return false;
        };
        let new_path = item.planned_path();
        let current_name = path_name(&new_path);
        item.root_path = path_root(&new_path);
        item.source_path = new_path;
        item.proposed_name.clone_from(&current_name);
        item.current_name = current_name;
        true
    }

    /// Replaces all non-overlapping occurrences in the complete proposed name.
    pub fn replace_complete(&mut self, from: &LegacyText, to: &LegacyText) {
        let _ = self.replace_complete_changed(from, to);
    }

    /// Replaces complete names and returns exactly which proposal rows changed.
    pub fn replace_complete_changed(&mut self, from: &LegacyText, to: &LegacyText) -> Box<[usize]> {
        changed_proposals(&mut self.items, |item| {
            let mut proposed = item.proposed_name.clone();
            proposed.replace_all(from, to);
            proposed
        })
    }

    /// Prepends text to the complete proposed name, including its extension.
    pub fn prefix_complete(&mut self, prefix: &LegacyText) {
        let _ = self.prefix_complete_changed(prefix);
    }

    /// Prefixes complete names and returns exactly which proposal rows changed.
    pub fn prefix_complete_changed(&mut self, prefix: &LegacyText) -> Box<[usize]> {
        if prefix.is_empty() {
            return Box::default();
        }
        changed_proposals(&mut self.items, |item| {
            let mut proposed = item.proposed_name.clone();
            proposed.insert_front(prefix);
            proposed
        })
    }

    /// Appends text immediately before a file extension.
    pub fn suffix_before_extension(&mut self, suffix: &LegacyText) {
        let _ = self.suffix_before_extension_changed(suffix);
    }

    /// Suffixes stems and returns exactly which proposal rows changed.
    pub fn suffix_before_extension_changed(&mut self, suffix: &LegacyText) -> Box<[usize]> {
        if suffix.is_empty() {
            return Box::default();
        }
        changed_proposals(&mut self.items, |item| {
            let (mut stem, extension) = split_stem_extension(item);
            stem.push(suffix);
            stem.push(&extension);
            stem
        })
    }

    /// Clears the name stem while preserving the file extension.
    pub fn clear_name(&mut self) {
        let _ = self.clear_name_changed();
    }

    /// Clears stems and returns exactly which proposal rows changed.
    pub fn clear_name_changed(&mut self) -> Box<[usize]> {
        changed_proposals(&mut self.items, |item| {
            let (_stem, extension) = split_stem_extension(item);
            extension
        })
    }

    /// Deletes a 1-based inclusive range from each stem.
    ///
    /// A zero start means one and a zero end means through the final code unit.
    pub fn delete_front_range(&mut self, start: usize, end: usize) -> Result<(), LegacyInputError> {
        self.delete_front_range_changed(start, end).map(drop)
    }

    /// Deletes a front range and returns exactly which proposal rows changed.
    pub fn delete_front_range_changed(
        &mut self,
        start: usize,
        end: usize,
    ) -> Result<Box<[usize]>, LegacyInputError> {
        if start == 0 && end == 0 {
            return Ok(Box::default());
        }
        let start = start.max(1);
        if end > 0 && start > end {
            return Err(LegacyInputError::ReversedPositionRange);
        }
        Ok(changed_proposals(&mut self.items, |item| {
            let (mut stem, extension) = split_stem_extension(item);
            if start <= stem.len() {
                let last = if end > 0 && end < stem.len() {
                    end
                } else {
                    stem.len()
                };
                stem.units.drain(start - 1..last);
            }
            stem.push(&extension);
            stem
        }))
    }

    /// Deletes the last `count` UTF-16 code units from each stem.
    pub fn delete_last(&mut self, count: usize) {
        let _ = self.delete_last_changed(count);
    }

    /// Deletes final code units and returns exactly which proposal rows changed.
    pub fn delete_last_changed(&mut self, count: usize) -> Box<[usize]> {
        if count == 0 {
            return Box::default();
        }
        changed_proposals(&mut self.items, |item| {
            let (mut stem, extension) = split_stem_extension(item);
            let count = count.min(stem.len());
            stem.units.truncate(stem.len() - count);
            stem.push(&extension);
            stem
        })
    }

    /// Deletes the first delimiter pair, including both delimiter code units.
    ///
    /// Only the first UTF-16 code unit from each dialog value is used.
    pub fn delete_first_delimited(
        &mut self,
        start: &LegacyText,
        end: &LegacyText,
    ) -> Result<(), LegacyInputError> {
        self.delete_first_delimited_changed(start, end).map(drop)
    }

    /// Deletes delimiter pairs and returns exactly which proposal rows changed.
    pub fn delete_first_delimited_changed(
        &mut self,
        start: &LegacyText,
        end: &LegacyText,
    ) -> Result<Box<[usize]>, LegacyInputError> {
        let Some(start) = start.units().first().copied() else {
            return Err(LegacyInputError::EmptyDelimiter);
        };
        let Some(end) = end.units().first().copied() else {
            return Err(LegacyInputError::EmptyDelimiter);
        };
        Ok(changed_proposals(&mut self.items, |item| {
            let (mut stem, extension) = split_stem_extension(item);
            if let Some(start_index) = stem.units.iter().position(|unit| *unit == start) {
                let search_start = start_index + 1;
                if let Some(relative_end) = stem.units[search_start..]
                    .iter()
                    .position(|unit| *unit == end)
                {
                    let end_index = search_start + relative_end;
                    stem.units.drain(start_index..=end_index);
                }
            }
            stem.push(&extension);
            stem
        }))
    }

    /// Retains only ASCII digits in each stem.
    pub fn keep_ascii_digits(&mut self) {
        let _ = self.keep_ascii_digits_changed();
    }

    /// Keeps ASCII digits and returns exactly which proposal rows changed.
    pub fn keep_ascii_digits_changed(&mut self) -> Box<[usize]> {
        changed_proposals(&mut self.items, |item| {
            let (mut stem, extension) = split_stem_extension(item);
            stem.units
                .retain(|unit| (b'0' as u16..=b'9' as u16).contains(unit));
            stem.push(&extension);
            stem
        })
    }

    /// Pads the last digit run selected by the original reverse scan.
    pub fn pad_last_digit_run(&mut self, width: usize) -> Result<(), LegacyInputError> {
        self.pad_last_digit_run_changed(width).map(drop)
    }

    /// Pads final digit runs and returns exactly which proposal rows changed.
    pub fn pad_last_digit_run_changed(
        &mut self,
        width: usize,
    ) -> Result<Box<[usize]>, LegacyInputError> {
        if width == 0 {
            return Err(LegacyInputError::NonPositiveWidth);
        }
        Ok(changed_proposals(&mut self.items, |item| {
            let (mut stem, extension) = split_stem_extension(item);
            if let Some((start, end)) = last_digit_run(stem.units()) {
                insert_zero_padding(&mut stem, start, end, width);
            }
            stem.push(&extension);
            stem
        }))
    }

    /// Pads the first digit run selected by the original forward scan.
    ///
    /// The MFC loop never assigned an end index when the run reached the end of
    /// the stem, so that particular run intentionally remains unchanged.
    pub fn pad_first_digit_run(&mut self, width: usize) -> Result<(), LegacyInputError> {
        self.pad_first_digit_run_changed(width).map(drop)
    }

    /// Pads first digit runs and returns exactly which proposal rows changed.
    pub fn pad_first_digit_run_changed(
        &mut self,
        width: usize,
    ) -> Result<Box<[usize]>, LegacyInputError> {
        if width == 0 {
            return Err(LegacyInputError::NonPositiveWidth);
        }
        Ok(changed_proposals(&mut self.items, |item| {
            let (mut stem, extension) = split_stem_extension(item);
            if let Some((start, end)) = first_digit_run(stem.units()) {
                insert_zero_padding(&mut stem, start, end, width);
            }
            stem.push(&extension);
            stem
        }))
    }

    /// Adds legacy sequence numbers without a separator.
    pub fn add_sequence(
        &mut self,
        width: usize,
        start: i32,
        mode: LegacySequenceMode,
    ) -> Result<(), LegacyInputError> {
        self.add_sequence_by(width, start, mode, LegacyText::case_insensitive_cmp)
    }

    /// Adds sequence numbers and returns exactly which proposal rows changed.
    pub fn add_sequence_changed(
        &mut self,
        width: usize,
        start: i32,
        mode: LegacySequenceMode,
    ) -> Result<Box<[usize]>, LegacyInputError> {
        self.add_sequence_by_changed(width, start, mode, LegacyText::case_insensitive_cmp)
    }

    /// Adds sequence numbers with a caller-provided parent-path comparator.
    pub fn add_sequence_by<F>(
        &mut self,
        width: usize,
        start: i32,
        mode: LegacySequenceMode,
        compare_text: F,
    ) -> Result<(), LegacyInputError>
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering + Copy,
    {
        self.add_sequence_by_changed(width, start, mode, compare_text)
            .map(drop)
    }

    /// Adds sequence numbers with a comparator and returns changed proposal rows.
    pub fn add_sequence_by_changed<F>(
        &mut self,
        width: usize,
        start: i32,
        mode: LegacySequenceMode,
        compare_text: F,
    ) -> Result<Box<[usize]>, LegacyInputError>
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering + Copy,
    {
        if width == 0 {
            return Err(LegacyInputError::NonPositiveWidth);
        }
        let start = start.max(0);
        let mut current = start;
        let mut changed = Vec::with_capacity(self.items.len());
        for index in 0..self.items.len() {
            if index > 0
                && matches!(
                    mode,
                    LegacySequenceMode::AppendRestartPerFolder
                        | LegacySequenceMode::PrependRestartPerFolder
                )
                && compare_text(
                    &self.items[index - 1].root_path,
                    &self.items[index].root_path,
                ) != Ordering::Equal
            {
                current = start;
            }
            let item = &mut self.items[index];
            let (mut stem, extension) = split_stem_extension(item);
            let number = padded_decimal(current, width);
            if matches!(
                mode,
                LegacySequenceMode::Append | LegacySequenceMode::AppendRestartPerFolder
            ) {
                stem.push(&number);
            } else {
                stem.insert_front(&number);
            }
            stem.push(&extension);
            if item.proposed_name != stem {
                item.proposed_name = stem;
                changed.push(index);
            }
            current = current.wrapping_add(1);
        }
        Ok(changed.into_boxed_slice())
    }

    /// Removes the final extension from files and leaves directories unchanged.
    pub fn delete_extension(&mut self) {
        let _ = self.delete_extension_changed();
    }

    /// Deletes extensions and returns exactly which proposal rows changed.
    pub fn delete_extension_changed(&mut self) -> Box<[usize]> {
        changed_proposals(&mut self.items, |item| {
            let (stem, _extension) = split_stem_extension(item);
            stem
        })
    }

    /// Appends an extension to every complete proposed name.
    pub fn add_extension(&mut self, extension: &LegacyText) {
        let _ = self.add_extension_changed(extension);
    }

    /// Adds an extension and returns exactly which proposal rows changed.
    pub fn add_extension_changed(&mut self, extension: &LegacyText) -> Box<[usize]> {
        let Some(extension) = normalized_extension(extension) else {
            return Box::default();
        };
        changed_proposals(&mut self.items, |item| {
            let mut proposed = item.proposed_name.clone();
            proposed.push(&extension);
            proposed
        })
    }

    /// Replaces the final file extension and appends to directory names.
    pub fn replace_extension(&mut self, extension: &LegacyText) {
        let _ = self.replace_extension_changed(extension);
    }

    /// Replaces extensions and returns exactly which proposal rows changed.
    pub fn replace_extension_changed(&mut self, extension: &LegacyText) -> Box<[usize]> {
        let Some(extension) = normalized_extension(extension) else {
            return Box::default();
        };
        changed_proposals(&mut self.items, |item| {
            let (mut stem, _old_extension) = split_stem_extension(item);
            stem.push(&extension);
            stem
        })
    }

    /// Prefixes the immediate parent folder plus an underscore.
    pub fn prefix_parent_folder(&mut self) {
        let _ = self.prefix_parent_folder_changed();
    }

    /// Prefixes parent folders and returns exactly which proposal rows changed.
    pub fn prefix_parent_folder_changed(&mut self) -> Box<[usize]> {
        changed_proposals(&mut self.items, |item| {
            if let Some(folder) = parent_folder_component(&item.root_path) {
                let mut proposed = folder;
                proposed.push_unit(b'_' as u16);
                proposed.push(&item.proposed_name);
                proposed
            } else {
                item.proposed_name.clone()
            }
        })
    }

    /// Suffixes an underscore and immediate parent folder before the extension.
    pub fn suffix_parent_folder(&mut self) {
        let _ = self.suffix_parent_folder_changed();
    }

    /// Suffixes parent folders and returns exactly which proposal rows changed.
    pub fn suffix_parent_folder_changed(&mut self) -> Box<[usize]> {
        changed_proposals(&mut self.items, |item| {
            if let Some(folder) = parent_folder_component(&item.root_path) {
                let mut suffix = LegacyText::from("_");
                suffix.push(&folder);
                let (mut stem, extension) = split_stem_extension(item);
                stem.push(&suffix);
                stem.push(&extension);
                stem
            } else {
                item.proposed_name.clone()
            }
        })
    }

    /// Replaces every destination root, removing one trailing backslash.
    pub fn unify_root_path(&mut self, root_path: &LegacyText) {
        let mut root_path = root_path.clone();
        if root_path.units.last() == Some(&BACKSLASH) {
            root_path.units.pop();
        }
        for item in &mut self.items {
            item.root_path.clone_from(&root_path);
        }
    }

    /// Sorts using the deterministic fallback case-insensitive text order.
    pub fn sort(&mut self, mode: LegacySortMode) {
        self.sort_by(mode, LegacyText::case_insensitive_cmp);
    }

    /// Sorts using a caller-provided replacement for Win32 `CompareString`.
    pub fn sort_by<F>(&mut self, mode: LegacySortMode, compare_text: F)
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering + Copy,
    {
        self.sort_by_with_semantics(mode, SortSemantics::LegacyDarkNamer080210, compare_text);
    }

    /// Sorts using the legacy policy and reports whether order changed.
    pub fn sort_by_changed<F>(&mut self, mode: LegacySortMode, compare_text: F) -> bool
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering + Copy,
    {
        self.sort_by_with_semantics_changed(
            mode,
            SortSemantics::LegacyDarkNamer080210,
            compare_text,
        )
    }

    /// Sorts with an explicit modern or legacy file-size policy.
    pub fn sort_by_with_semantics<F>(
        &mut self,
        mode: LegacySortMode,
        semantics: SortSemantics,
        compare_text: F,
    ) where
        F: Fn(&LegacyText, &LegacyText) -> Ordering + Copy,
    {
        let _ = self.sort_by_with_semantics_changed(mode, semantics, compare_text);
    }

    /// Sorts with explicit semantics and reports whether order changed.
    pub fn sort_by_with_semantics_changed<F>(
        &mut self,
        mode: LegacySortMode,
        semantics: SortSemantics,
        compare_text: F,
    ) -> bool
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering + Copy,
    {
        let compare_items = |left: &LegacyListItem, right: &LegacyListItem| match mode {
            LegacySortMode::NameAscending => {
                compare_text(left.current_name(), right.current_name())
            }
            LegacySortMode::NameDescending => {
                compare_text(left.current_name(), right.current_name()).reverse()
            }
            LegacySortMode::FullPathAscending => {
                compare_text(left.source_path(), right.source_path())
            }
            LegacySortMode::FullPathDescending => {
                compare_text(left.source_path(), right.source_path()).reverse()
            }
            LegacySortMode::SizeAscending => match semantics {
                SortSemantics::SafeActualSize => left.actual_size.cmp(&right.actual_size),
                SortSemantics::LegacyDarkNamer080210 => compare_legacy_size(left.size, right.size),
            },
            LegacySortMode::SizeDescending => match semantics {
                SortSemantics::SafeActualSize => left.actual_size.cmp(&right.actual_size).reverse(),
                SortSemantics::LegacyDarkNamer080210 => {
                    compare_legacy_size(left.size, right.size).reverse()
                }
            },
            LegacySortMode::ModifiedAscending => left.modified.cmp(&right.modified),
            LegacySortMode::ModifiedDescending => left.modified.cmp(&right.modified).reverse(),
            LegacySortMode::CreatedAscending => left.created.cmp(&right.created),
            LegacySortMode::CreatedDescending => left.created.cmp(&right.created).reverse(),
        };
        let mut order = (0..self.items.len()).collect::<Vec<_>>();
        order.sort_by(|left, right| compare_items(&self.items[*left], &self.items[*right]));
        if order
            .iter()
            .enumerate()
            .all(|(index, original)| index == *original)
        {
            return false;
        }

        let mut original = mem::take(&mut self.items)
            .into_iter()
            .map(Some)
            .collect::<Vec<_>>();
        self.items = Vec::with_capacity(original.len());
        for index in order {
            if let Some(item) = original[index].take() {
                self.items.push(item);
            }
        }
        true
    }

    /// Exports proposed names in list order with a trailing CRLF per row.
    #[must_use]
    pub fn export_names(&self) -> LegacyText {
        export_lines(self.items.iter().map(LegacyListItem::proposed_name))
    }

    /// Exports original source paths in list order with a trailing CRLF per row.
    #[must_use]
    pub fn export_paths(&self) -> LegacyText {
        export_lines(self.items.iter().map(LegacyListItem::source_path))
    }

    /// Imports nonblank trimmed lines into proposed names in list order.
    pub fn import_names(&mut self, text: &LegacyText) -> usize {
        let names = parse_import_lines(text);
        let count = names.len().min(self.len());
        for (item, name) in self.items.iter_mut().zip(names).take(count) {
            item.proposed_name = name;
        }
        count
    }

    /// Imports names and returns exactly which proposal rows changed.
    pub fn import_names_changed(&mut self, text: &LegacyText) -> Box<[usize]> {
        let names = parse_import_lines(text);
        let mut changed = Vec::with_capacity(names.len().min(self.len()));
        for (index, (item, name)) in self.items.iter_mut().zip(names).enumerate() {
            if item.proposed_name != name {
                item.proposed_name = name;
                changed.push(index);
            }
        }
        changed.into_boxed_slice()
    }
}

fn changed_proposals(
    items: &mut [LegacyListItem],
    mut proposal: impl FnMut(&LegacyListItem) -> LegacyText,
) -> Box<[usize]> {
    let mut changed = Vec::with_capacity(items.len());
    for (index, item) in items.iter_mut().enumerate() {
        let next = proposal(item);
        if item.proposed_name != next {
            item.proposed_name = next;
            changed.push(index);
        }
    }
    changed.into_boxed_slice()
}

/// Splits LF-delimited import text, trims each line, and skips blank lines.
#[must_use]
pub fn parse_import_lines(text: &LegacyText) -> Vec<LegacyText> {
    text.units
        .split(|unit| *unit == LF)
        .map(|units| LegacyText::from_units(units.to_vec()).trimmed())
        .filter(|line| !line.is_empty())
        .collect()
}

fn lowercase_units(units: &[u16]) -> Vec<u16> {
    let mut lowered = Vec::with_capacity(units.len());
    for decoded in char::decode_utf16(units.iter().copied()) {
        match decoded {
            Ok(character) => {
                for lower in character.to_lowercase() {
                    let mut buffer = [0; 2];
                    lowered.extend_from_slice(lower.encode_utf16(&mut buffer));
                }
            }
            Err(error) => lowered.push(error.unpaired_surrogate()),
        }
    }
    lowered
}

fn is_trim_unit(unit: u16) -> bool {
    char::from_u32(u32::from(unit)).is_some_and(char::is_whitespace)
}

fn path_root(path: &LegacyText) -> LegacyText {
    path.units
        .iter()
        .rposition(|unit| *unit == BACKSLASH)
        .map_or_else(LegacyText::default, |index| {
            LegacyText::from_units(path.units[..index].to_vec())
        })
}

fn path_name(path: &LegacyText) -> LegacyText {
    let start = path
        .units
        .iter()
        .rposition(|unit| *unit == BACKSLASH)
        .map_or(0, |index| index + 1);
    LegacyText::from_units(path.units[start..].to_vec())
}

fn split_stem_extension(item: &LegacyListItem) -> (LegacyText, LegacyText) {
    let name_start = item
        .proposed_name
        .units
        .iter()
        .rposition(|unit| *unit == BACKSLASH)
        .map_or(0, |index| index + 1);
    if item.is_directory {
        return (
            LegacyText::from_units(item.proposed_name.units[name_start..].to_vec()),
            LegacyText::default(),
        );
    }
    item.proposed_name
        .units
        .iter()
        .rposition(|unit| *unit == DOT)
        .map_or_else(
            || {
                (
                    LegacyText::from_units(item.proposed_name.units[name_start..].to_vec()),
                    LegacyText::default(),
                )
            },
            |index| {
                (
                    LegacyText::from_units(
                        item.proposed_name.units[name_start..index.max(name_start)].to_vec(),
                    ),
                    LegacyText::from_units(item.proposed_name.units[index..].to_vec()),
                )
            },
        )
}

fn normalized_extension(extension: &LegacyText) -> Option<LegacyText> {
    if extension.is_empty() {
        return None;
    }
    if extension.units.first() == Some(&DOT) {
        Some(extension.clone())
    } else {
        let mut normalized = LegacyText::from(".");
        normalized.push(extension);
        Some(normalized)
    }
}

fn parent_folder_component(root_path: &LegacyText) -> Option<LegacyText> {
    let start = root_path
        .units
        .iter()
        .rposition(|unit| *unit == BACKSLASH)
        .map_or(0, |index| index + 1);
    let component = LegacyText::from_units(root_path.units[start..].to_vec());
    (component != *root_path).then_some(component)
}

fn normalized_indices(indices: &[usize], length: usize) -> Vec<usize> {
    indices
        .iter()
        .copied()
        .filter(|index| *index < length)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn last_digit_run(units: &[u16]) -> Option<(usize, usize)> {
    let end = units.iter().rposition(|unit| is_ascii_digit(*unit))?;
    let start = units[..=end]
        .iter()
        .rposition(|unit| !is_ascii_digit(*unit))
        .map_or(0, |index| index + 1);
    Some((start, end))
}

fn first_digit_run(units: &[u16]) -> Option<(usize, usize)> {
    let start = units.iter().position(|unit| is_ascii_digit(*unit))?;
    let relative_end = units[start..]
        .iter()
        .position(|unit| !is_ascii_digit(*unit))?;
    Some((start, start + relative_end - 1))
}

const fn is_ascii_digit(unit: u16) -> bool {
    unit >= b'0' as u16 && unit <= b'9' as u16
}

fn insert_zero_padding(text: &mut LegacyText, start: usize, end: usize, width: usize) {
    let run_length = end - start + 1;
    if width > run_length {
        text.units.splice(
            start..start,
            std::iter::repeat_n(b'0' as u16, width - run_length),
        );
    }
}

fn padded_decimal(value: i32, width: usize) -> LegacyText {
    let value = value.to_string();
    let mut result = LegacyText::from_units(Vec::with_capacity(width.max(value.len())));
    for _ in value.len()..width {
        result.push_unit(b'0' as u16);
    }
    result.push(&LegacyText::from(value));
    result
}

fn compare_legacy_size(left: u32, right: u32) -> Ordering {
    (left.wrapping_sub(right) as i32).cmp(&0)
}

fn export_lines<'a>(lines: impl IntoIterator<Item = &'a LegacyText>) -> LegacyText {
    let mut exported = LegacyText::default();
    for line in lines {
        exported.push(line);
        exported.push_unit(CR);
        exported.push_unit(LF);
    }
    exported
}
