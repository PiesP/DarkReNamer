//! Pure compatibility model for the DarkNamer 08.02.10 list workbench.
//!
//! The original application was a `_UNICODE` MFC build, so all text indexing
//! and slicing in this crate uses UTF-16 code units instead of Unicode scalar
//! values. This crate performs no filesystem, clipboard, or file I/O.

#![forbid(unsafe_code)]

use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::fmt;

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
        let selected = normalized_indices(selected, self.len());
        if selected.first() == Some(&0) {
            return selected.into_boxed_slice();
        }
        for index in &selected {
            self.items.swap(index - 1, *index);
        }
        selected
            .into_iter()
            .map(|index| index - 1)
            .collect::<Vec<_>>()
            .into_boxed_slice()
    }

    /// Moves caller-selected rows one position later.
    ///
    /// Selecting the final row makes the complete move command a no-op.
    pub fn move_rows_later(&mut self, selected: &[usize]) -> Box<[usize]> {
        let selected = normalized_indices(selected, self.len());
        if selected.last().is_some_and(|index| index + 1 == self.len()) {
            return selected.into_boxed_slice();
        }
        for index in selected.iter().rev() {
            self.items.swap(*index, index + 1);
        }
        selected
            .into_iter()
            .map(|index| index + 1)
            .collect::<Vec<_>>()
            .into_boxed_slice()
    }

    /// Resets every proposed name to its current/original name (`Ctrl+Z`).
    pub fn reset_proposals(&mut self) {
        for item in &mut self.items {
            item.proposed_name.clone_from(&item.current_name);
        }
    }

    /// Directly changes one proposed name, returning `false` for an invalid row.
    pub fn manual_change(&mut self, index: usize, proposed_name: impl Into<LegacyText>) -> bool {
        let Some(item) = self.items.get_mut(index) else {
            return false;
        };
        item.proposed_name = proposed_name.into();
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
        for item in &mut self.items {
            item.proposed_name.replace_all(from, to);
        }
    }

    /// Prepends text to the complete proposed name, including its extension.
    pub fn prefix_complete(&mut self, prefix: &LegacyText) {
        for item in &mut self.items {
            item.proposed_name.insert_front(prefix);
        }
    }

    /// Appends text immediately before a file extension.
    pub fn suffix_before_extension(&mut self, suffix: &LegacyText) {
        for item in &mut self.items {
            let (mut stem, extension) = split_stem_extension(item);
            stem.push(suffix);
            stem.push(&extension);
            item.proposed_name = stem;
        }
    }

    /// Clears the name stem while preserving the file extension.
    pub fn clear_name(&mut self) {
        for item in &mut self.items {
            let (_stem, extension) = split_stem_extension(item);
            item.proposed_name = extension;
        }
    }

    /// Deletes a 1-based inclusive range from each stem.
    ///
    /// A zero start means one and a zero end means through the final code unit.
    pub fn delete_front_range(&mut self, start: usize, end: usize) -> Result<(), LegacyInputError> {
        if start == 0 && end == 0 {
            return Ok(());
        }
        let start = start.max(1);
        if end > 0 && start > end {
            return Err(LegacyInputError::ReversedPositionRange);
        }
        for item in &mut self.items {
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
            item.proposed_name = stem;
        }
        Ok(())
    }

    /// Deletes the last `count` UTF-16 code units from each stem.
    pub fn delete_last(&mut self, count: usize) {
        for item in &mut self.items {
            let (mut stem, extension) = split_stem_extension(item);
            let count = count.min(stem.len());
            stem.units.truncate(stem.len() - count);
            stem.push(&extension);
            item.proposed_name = stem;
        }
    }

    /// Deletes the first delimiter pair, including both delimiter code units.
    ///
    /// Only the first UTF-16 code unit from each dialog value is used.
    pub fn delete_first_delimited(
        &mut self,
        start: &LegacyText,
        end: &LegacyText,
    ) -> Result<(), LegacyInputError> {
        let Some(start) = start.units().first().copied() else {
            return Err(LegacyInputError::EmptyDelimiter);
        };
        let Some(end) = end.units().first().copied() else {
            return Err(LegacyInputError::EmptyDelimiter);
        };
        for item in &mut self.items {
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
            item.proposed_name = stem;
        }
        Ok(())
    }

    /// Retains only ASCII digits in each stem.
    pub fn keep_ascii_digits(&mut self) {
        for item in &mut self.items {
            let (mut stem, extension) = split_stem_extension(item);
            stem.units
                .retain(|unit| (b'0' as u16..=b'9' as u16).contains(unit));
            stem.push(&extension);
            item.proposed_name = stem;
        }
    }

    /// Pads the last digit run selected by the original reverse scan.
    pub fn pad_last_digit_run(&mut self, width: usize) -> Result<(), LegacyInputError> {
        if width == 0 {
            return Err(LegacyInputError::NonPositiveWidth);
        }
        for item in &mut self.items {
            let (mut stem, extension) = split_stem_extension(item);
            if let Some((start, end)) = last_digit_run(stem.units()) {
                insert_zero_padding(&mut stem, start, end, width);
            }
            stem.push(&extension);
            item.proposed_name = stem;
        }
        Ok(())
    }

    /// Pads the first digit run selected by the original forward scan.
    ///
    /// The MFC loop never assigned an end index when the run reached the end of
    /// the stem, so that particular run intentionally remains unchanged.
    pub fn pad_first_digit_run(&mut self, width: usize) -> Result<(), LegacyInputError> {
        if width == 0 {
            return Err(LegacyInputError::NonPositiveWidth);
        }
        for item in &mut self.items {
            let (mut stem, extension) = split_stem_extension(item);
            if let Some((start, end)) = first_digit_run(stem.units()) {
                insert_zero_padding(&mut stem, start, end, width);
            }
            stem.push(&extension);
            item.proposed_name = stem;
        }
        Ok(())
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
        if width == 0 {
            return Err(LegacyInputError::NonPositiveWidth);
        }
        let start = start.max(0);
        let mut current = start;
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
            item.proposed_name = stem;
            current = current.wrapping_add(1);
        }
        Ok(())
    }

    /// Removes the final extension from files and leaves directories unchanged.
    pub fn delete_extension(&mut self) {
        for item in &mut self.items {
            let (stem, _extension) = split_stem_extension(item);
            item.proposed_name = stem;
        }
    }

    /// Appends an extension to every complete proposed name.
    pub fn add_extension(&mut self, extension: &LegacyText) {
        let Some(extension) = normalized_extension(extension) else {
            return;
        };
        for item in &mut self.items {
            item.proposed_name.push(&extension);
        }
    }

    /// Replaces the final file extension and appends to directory names.
    pub fn replace_extension(&mut self, extension: &LegacyText) {
        let Some(extension) = normalized_extension(extension) else {
            return;
        };
        for item in &mut self.items {
            let (mut stem, _old_extension) = split_stem_extension(item);
            stem.push(&extension);
            item.proposed_name = stem;
        }
    }

    /// Prefixes the immediate parent folder plus an underscore.
    pub fn prefix_parent_folder(&mut self) {
        for item in &mut self.items {
            if let Some(folder) = parent_folder_component(&item.root_path) {
                let mut proposed = folder;
                proposed.push_unit(b'_' as u16);
                proposed.push(&item.proposed_name);
                item.proposed_name = proposed;
            }
        }
    }

    /// Suffixes an underscore and immediate parent folder before the extension.
    pub fn suffix_parent_folder(&mut self) {
        for item in &mut self.items {
            if let Some(folder) = parent_folder_component(&item.root_path) {
                let mut suffix = LegacyText::from("_");
                suffix.push(&folder);
                let (mut stem, extension) = split_stem_extension(item);
                stem.push(&suffix);
                stem.push(&extension);
                item.proposed_name = stem;
            }
        }
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
        self.items.sort_by(|left, right| match mode {
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
            LegacySortMode::SizeAscending => compare_legacy_size(left.size, right.size),
            LegacySortMode::SizeDescending => compare_legacy_size(left.size, right.size).reverse(),
            LegacySortMode::ModifiedAscending => left.modified.cmp(&right.modified),
            LegacySortMode::ModifiedDescending => left.modified.cmp(&right.modified).reverse(),
            LegacySortMode::CreatedAscending => left.created.cmp(&right.created),
            LegacySortMode::CreatedDescending => left.created.cmp(&right.created).reverse(),
        });
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
