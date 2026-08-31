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
use std::sync::{Arc, Weak};

mod windows_leaf_name;

pub use windows_leaf_name::{
    MAX_WINDOWS_LEAF_NAME_UTF16_UNITS, WindowsLeafNameError, validate_windows_leaf_name,
};

/// Maximum UTF-16 length retained for one proposed Windows leaf name.
pub const MAX_PROPOSED_NAME_UTF16_UNITS: usize = MAX_WINDOWS_LEAF_NAME_UTF16_UNITS;
/// Aggregate UTF-16 units retained for all proposed names in one model.
///
/// This is four MiB of UTF-16 storage, matching the application's aggregate
/// admitted-path byte budget while remaining independent from the per-name
/// Windows component limit.
pub const MAX_TOTAL_PROPOSED_NAME_UTF16_UNITS: usize = 2 * 1024 * 1024;

const BACKSLASH: u16 = b'\\' as u16;
const DOT: u16 = b'.' as u16;
const CR: u16 = b'\r' as u16;
const LF: u16 = b'\n' as u16;
const APPEND_INDEX_CHUNK_CAPACITY: usize = 128;

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

/// A proposal mutation rejected before any model row was changed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProposalMutationError {
    /// A legacy command parameter was invalid.
    InvalidInput(LegacyInputError),
    /// One proposed name would exceed the Windows component budget.
    NameBudgetExceeded {
        /// Zero-based row whose result exceeded the limit.
        row: usize,
        /// Exact requested UTF-16 code-unit count.
        requested_units: usize,
        /// Maximum accepted UTF-16 code-unit count.
        maximum_units: usize,
    },
    /// All proposed names together would exceed the model budget.
    AggregateBudgetExceeded {
        /// Exact requested UTF-16 code-unit count at rejection.
        requested_units: usize,
        /// Maximum accepted UTF-16 code-unit count.
        maximum_units: usize,
    },
    /// A checked proposal-size calculation overflowed `usize`.
    ArithmeticOverflow,
    /// A bounded staging allocation could not be reserved.
    AllocationFailed,
}

impl fmt::Display for ProposalMutationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput(error) => error.fmt(formatter),
            Self::NameBudgetExceeded {
                row,
                requested_units,
                maximum_units,
            } => write!(
                formatter,
                "proposal row {row} requires {requested_units} UTF-16 units; maximum is {maximum_units}"
            ),
            Self::AggregateBudgetExceeded {
                requested_units,
                maximum_units,
            } => write!(
                formatter,
                "proposals require {requested_units} UTF-16 units; maximum is {maximum_units}"
            ),
            Self::ArithmeticOverflow => formatter.write_str("proposal size calculation overflowed"),
            Self::AllocationFailed => formatter.write_str("proposal staging allocation failed"),
        }
    }
}

impl std::error::Error for ProposalMutationError {}

impl From<LegacyInputError> for ProposalMutationError {
    fn from(error: LegacyInputError) -> Self {
        Self::InvalidInput(error)
    }
}

/// A reusable, comparator-bound index for duplicate checks during list append.
///
/// The index follows one [`LegacyList`]'s source set. Proposal edits and row
/// reordering retain it, while source additions, removals, clears, and
/// successful moves cause a transparent rebuild before the next append.
pub struct LegacyAppendIndex<F> {
    compare_text: F,
    model_identity: Weak<()>,
    source_revision: u64,
    chunks: Vec<Vec<LegacyText>>,
    #[cfg(test)]
    test_metrics: AppendIndexTestMetrics,
    #[cfg(test)]
    fail_cache_update_after: Option<usize>,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct AppendIndexTestMetrics {
    source_relocations: usize,
    maximum_source_relocations: usize,
    outer_chunk_moves: usize,
}

impl<F> LegacyAppendIndex<F> {
    /// Creates an empty index permanently bound to `compare_text`.
    #[must_use]
    pub fn new(compare_text: F) -> Self {
        Self {
            compare_text,
            model_identity: Weak::new(),
            source_revision: 0,
            chunks: Vec::new(),
            #[cfg(test)]
            test_metrics: AppendIndexTestMetrics::default(),
            #[cfg(test)]
            fail_cache_update_after: None,
        }
    }

    fn is_current_for(&self, list: &LegacyList) -> bool {
        self.source_revision == list.source_revision
            && self
                .model_identity
                .upgrade()
                .is_some_and(|identity| Arc::ptr_eq(&identity, &list.identity))
    }

    fn bind_to(&mut self, list: &LegacyList) {
        self.model_identity = Arc::downgrade(&list.identity);
        self.source_revision = list.source_revision;
    }

    fn clear_binding(&mut self) {
        self.model_identity = Weak::new();
        self.source_revision = 0;
        self.chunks.clear();
    }

    #[cfg(test)]
    fn reset_test_metrics(&mut self) {
        self.test_metrics = AppendIndexTestMetrics::default();
    }

    #[cfg(test)]
    fn record_source_relocations(&mut self, relocations: usize) {
        self.test_metrics.source_relocations = self
            .test_metrics
            .source_relocations
            .saturating_add(relocations);
        self.test_metrics.maximum_source_relocations = self
            .test_metrics
            .maximum_source_relocations
            .max(relocations);
    }

    #[cfg(not(test))]
    fn record_source_relocations(&mut self, _relocations: usize) {}

    #[cfg(test)]
    fn record_outer_chunk_moves(&mut self, moves: usize) {
        self.test_metrics.outer_chunk_moves =
            self.test_metrics.outer_chunk_moves.saturating_add(moves);
    }

    #[cfg(not(test))]
    fn record_outer_chunk_moves(&mut self, _moves: usize) {}
}

impl<F> fmt::Debug for LegacyAppendIndex<F> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LegacyAppendIndex")
            .field("source_revision", &self.source_revision)
            .field("chunks", &self.chunks)
            .finish_non_exhaustive()
    }
}

impl<F> LegacyAppendIndex<F>
where
    F: Fn(&LegacyText, &LegacyText) -> Ordering,
{
    fn contains(&self, source: &LegacyText) -> bool {
        source_chunks_contain(&self.chunks, &self.compare_text, source)
    }

    fn insertion_location(&self, source: &LegacyText) -> (usize, usize) {
        let chunk_index = self.chunks.partition_point(|chunk| {
            let Some(last) = chunk.last() else {
                return true;
            };
            (self.compare_text)(last, source) == Ordering::Less
        });
        if chunk_index == self.chunks.len() {
            return self.chunks.last().map_or((0, 0), |last| {
                if last.len() < APPEND_INDEX_CHUNK_CAPACITY {
                    (self.chunks.len() - 1, last.len())
                } else {
                    (self.chunks.len(), 0)
                }
            });
        }
        let position = self.chunks[chunk_index]
            .binary_search_by(|existing| (self.compare_text)(existing, source))
            .unwrap_or_else(|position| position);
        (chunk_index, position)
    }

    fn try_insert_source(&mut self, source: LegacyText) -> Result<(), ProposalMutationError> {
        #[cfg(test)]
        if let Some(remaining) = &mut self.fail_cache_update_after {
            if *remaining == 0 {
                return Err(ProposalMutationError::AllocationFailed);
            }
            *remaining -= 1;
        }

        let (chunk_index, position) = self.insertion_location(&source);
        if chunk_index == self.chunks.len() {
            let mut chunk = Vec::new();
            chunk
                .try_reserve_exact(APPEND_INDEX_CHUNK_CAPACITY)
                .map_err(|_| ProposalMutationError::AllocationFailed)?;
            self.chunks
                .try_reserve(1)
                .map_err(|_| ProposalMutationError::AllocationFailed)?;
            chunk.push(source);
            self.chunks.push(chunk);
            return Ok(());
        }

        if self.chunks[chunk_index].len() < APPEND_INDEX_CHUNK_CAPACITY {
            let relocations = self.chunks[chunk_index].len() - position;
            self.chunks[chunk_index].insert(position, source);
            self.record_source_relocations(relocations);
            return Ok(());
        }

        let split_at = APPEND_INDEX_CHUNK_CAPACITY / 2;
        let mut right = Vec::new();
        right
            .try_reserve_exact(APPEND_INDEX_CHUNK_CAPACITY)
            .map_err(|_| ProposalMutationError::AllocationFailed)?;
        self.chunks
            .try_reserve(1)
            .map_err(|_| ProposalMutationError::AllocationFailed)?;

        right.extend(self.chunks[chunk_index].drain(split_at..));
        let split_relocations = right.len();
        let outer_moves = self.chunks.len() - chunk_index - 1;
        self.chunks.insert(chunk_index + 1, right);
        self.record_outer_chunk_moves(outer_moves);

        let (target_chunk, target_position) = if position < split_at {
            (chunk_index, position)
        } else {
            (chunk_index + 1, position - split_at)
        };
        let relocations = split_relocations + self.chunks[target_chunk].len() - target_position;
        self.chunks[target_chunk].insert(target_position, source);
        self.record_source_relocations(relocations);
        Ok(())
    }
}

fn source_chunks_contain<F>(
    chunks: &[Vec<LegacyText>],
    compare_text: &F,
    source: &LegacyText,
) -> bool
where
    F: Fn(&LegacyText, &LegacyText) -> Ordering,
{
    let chunk_index = chunks.partition_point(|chunk| {
        let Some(last) = chunk.last() else {
            return true;
        };
        compare_text(last, source) == Ordering::Less
    });
    chunks.get(chunk_index).is_some_and(|chunk| {
        chunk
            .binary_search_by(|existing| compare_text(existing, source))
            .is_ok()
    })
}

fn try_chunk_sorted_sources(
    sorted_sources: Vec<LegacyText>,
) -> Result<Vec<Vec<LegacyText>>, ProposalMutationError> {
    let chunk_count = sorted_sources.len().div_ceil(APPEND_INDEX_CHUNK_CAPACITY);
    let mut chunks = Vec::new();
    chunks
        .try_reserve_exact(chunk_count)
        .map_err(|_| ProposalMutationError::AllocationFailed)?;
    let mut sources = sorted_sources.into_iter();
    while let Some(first) = sources.next() {
        let mut chunk = Vec::new();
        chunk
            .try_reserve_exact(APPEND_INDEX_CHUNK_CAPACITY)
            .map_err(|_| ProposalMutationError::AllocationFailed)?;
        chunk.push(first);
        chunk.extend(sources.by_ref().take(APPEND_INDEX_CHUNK_CAPACITY - 1));
        chunks.push(chunk);
    }
    Ok(chunks)
}

/// Ordered, cumulative DarkNamer list state.
pub struct LegacyList {
    items: Vec<LegacyListItem>,
    proposed_name_utf16_units: usize,
    identity: Arc<()>,
    source_revision: u64,
}

impl Clone for LegacyList {
    fn clone(&self) -> Self {
        Self {
            items: self.items.clone(),
            proposed_name_utf16_units: self.proposed_name_utf16_units,
            identity: Arc::new(()),
            source_revision: 0,
        }
    }
}

impl fmt::Debug for LegacyList {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LegacyList")
            .field("items", &self.items)
            .finish()
    }
}

impl Default for LegacyList {
    fn default() -> Self {
        Self::new()
    }
}

impl PartialEq for LegacyList {
    fn eq(&self, other: &Self) -> bool {
        self.items == other.items
    }
}

impl Eq for LegacyList {}

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
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            proposed_name_utf16_units: 0,
            identity: Arc::new(()),
            source_revision: 0,
        }
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

    /// Returns the exact aggregate UTF-16 length of all proposed names.
    #[must_use]
    pub const fn proposed_name_utf16_units(&self) -> usize {
        self.proposed_name_utf16_units
    }

    /// Clears all rows and reports whether the list changed.
    pub fn clear(&mut self) -> bool {
        let changed = !self.items.is_empty();
        self.items.clear();
        self.proposed_name_utf16_units = 0;
        if changed {
            self.invalidate_source_index();
        }
        changed
    }

    fn invalidate_source_index(&mut self) {
        if let Some(next) = self.source_revision.checked_add(1) {
            self.source_revision = next;
        } else {
            self.identity = Arc::new(());
            self.source_revision = 0;
        }
    }

    /// Appends one row unless its path duplicates an existing row ignoring case.
    ///
    /// # Errors
    ///
    /// Returns [`ProposalMutationError`] if the appended proposal would exceed
    /// a name budget, checked size arithmetic overflows, or staging allocation
    /// fails. The list remains unchanged on error.
    pub fn append(&mut self, item: LegacyListItem) -> Result<bool, ProposalMutationError> {
        self.append_by(item, LegacyText::case_insensitive_cmp)
    }

    /// Appends one row with a caller-provided locale comparator.
    ///
    /// # Errors
    ///
    /// Returns [`ProposalMutationError`] under the same conditions as
    /// [`LegacyList::append_batch_by`]. The list remains unchanged on error.
    pub fn append_by<F>(
        &mut self,
        item: LegacyListItem,
        compare_text: F,
    ) -> Result<bool, ProposalMutationError>
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering,
    {
        let mut index = LegacyAppendIndex::new(compare_text);
        self.append_indexed(&mut index, item)
    }

    /// Appends a picker/drop/import batch in the source application's sorted
    /// full-path order, skipping paths already present in the list.
    ///
    /// # Errors
    ///
    /// Returns [`ProposalMutationError`] if any appended proposal would exceed
    /// a name budget, checked size arithmetic overflows, or staging allocation
    /// fails. The list remains unchanged on error.
    pub fn append_batch(
        &mut self,
        items: impl IntoIterator<Item = LegacyListItem>,
    ) -> Result<usize, ProposalMutationError> {
        self.append_batch_by(items, LegacyText::case_insensitive_cmp)
    }

    /// Appends a batch with a caller-provided locale comparator.
    ///
    /// Duplicate detection is limited to paths already in the model. Equal
    /// paths within the incoming batch remain present and retain the source
    /// application's reverse-equal ordering.
    ///
    /// # Errors
    ///
    /// Returns [`ProposalMutationError`] if any appended proposal would exceed
    /// a name budget, checked size arithmetic overflows, or staging allocation
    /// fails. Duplicate-only batches succeed without revalidating skipped rows.
    /// The list remains unchanged on error.
    pub fn append_batch_by<F>(
        &mut self,
        items: impl IntoIterator<Item = LegacyListItem>,
        compare_text: F,
    ) -> Result<usize, ProposalMutationError>
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering + Copy,
    {
        let mut index = LegacyAppendIndex::new(compare_text);
        self.append_batch_indexed(&mut index, items)
    }

    /// Appends one row through a reusable comparator-bound source index.
    ///
    /// # Errors
    ///
    /// Returns [`ProposalMutationError`] under the same conditions as
    /// [`LegacyList::append_batch_indexed`]. The list remains unchanged on
    /// error; the derived index remains valid or is cleared for a later rebuild.
    pub fn append_indexed<F>(
        &mut self,
        index: &mut LegacyAppendIndex<F>,
        item: LegacyListItem,
    ) -> Result<bool, ProposalMutationError>
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering,
    {
        self.append_batch_indexed(index, std::iter::once(item))
            .map(|appended| appended != 0)
    }

    /// Appends a batch through a reusable comparator-bound source index.
    ///
    /// Every incoming path is checked only against the source set that existed
    /// before this batch. Consequently, equal paths within the batch remain
    /// present and retain legacy reverse-equal order. All fallible staging is
    /// completed before either the list or index gains logical content.
    ///
    /// # Errors
    ///
    /// Returns [`ProposalMutationError`] if rebuilding or extending the index
    /// cannot be staged, a proposal budget would be exceeded, checked size
    /// arithmetic overflows, or another bounded allocation fails. The list
    /// remains unchanged on error. A cache-update allocation failure clears the
    /// derived index so a later call transparently rebuilds it.
    pub fn append_batch_indexed<F>(
        &mut self,
        index: &mut LegacyAppendIndex<F>,
        items: impl IntoIterator<Item = LegacyListItem>,
    ) -> Result<usize, ProposalMutationError>
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering,
    {
        let rebuilt_chunks = if index.is_current_for(self) {
            None
        } else {
            let mut rebuilt = Vec::new();
            rebuilt
                .try_reserve_exact(self.items.len())
                .map_err(|_| ProposalMutationError::AllocationFailed)?;
            for item in &self.items {
                rebuilt.push(try_clone_text(item.source_path())?);
            }
            rebuilt.sort_unstable_by(|left, right| (index.compare_text)(left, right));
            Some(try_chunk_sorted_sources(rebuilt)?)
        };

        let mut accepted = Vec::new();
        for item in items {
            let duplicate_existing = rebuilt_chunks.as_ref().map_or_else(
                || index.contains(item.source_path()),
                |chunks| source_chunks_contain(chunks, &index.compare_text, item.source_path()),
            );
            if duplicate_existing {
                continue;
            }
            accepted
                .try_reserve(1)
                .map_err(|_| ProposalMutationError::AllocationFailed)?;
            let position = accepted.len();
            accepted.push((position, item));
        }

        if accepted.is_empty() {
            if let Some(rebuilt) = rebuilt_chunks {
                index.chunks = rebuilt;
                index.bind_to(self);
            }
            return Ok(0);
        }

        // AddFileItem inserted before existing equal keys. Comparing the
        // original batch position in descending order makes that legacy
        // reverse-equal result explicit while permitting an allocation-free
        // unstable sort.
        accepted.sort_unstable_by(|(left_position, left), (right_position, right)| {
            (index.compare_text)(left.source_path(), right.source_path())
                .then_with(|| right_position.cmp(left_position))
        });

        let mut requested_units = self.proposed_name_utf16_units;
        for (batch_row, (_, item)) in accepted.iter().enumerate() {
            let row = self
                .items
                .len()
                .checked_add(batch_row)
                .ok_or(ProposalMutationError::ArithmeticOverflow)?;
            validate_proposal_units(row, item.proposed_name().len())?;
            requested_units = requested_units
                .checked_add(item.proposed_name().len())
                .ok_or(ProposalMutationError::ArithmeticOverflow)?;
        }
        if requested_units > MAX_TOTAL_PROPOSED_NAME_UTF16_UNITS {
            return Err(ProposalMutationError::AggregateBudgetExceeded {
                requested_units,
                maximum_units: MAX_TOTAL_PROPOSED_NAME_UTF16_UNITS,
            });
        }

        let count = accepted.len();
        let mut staged_sources = Vec::new();
        staged_sources
            .try_reserve_exact(count)
            .map_err(|_| ProposalMutationError::AllocationFailed)?;
        for (_, item) in &accepted {
            staged_sources.push(try_clone_text(item.source_path())?);
        }
        self.items
            .try_reserve_exact(count)
            .map_err(|_| ProposalMutationError::AllocationFailed)?;
        if let Some(rebuilt) = rebuilt_chunks {
            index.chunks = rebuilt;
        }

        for source in staged_sources {
            if let Err(error) = index.try_insert_source(source) {
                index.clear_binding();
                return Err(error);
            }
        }
        self.invalidate_source_index();
        self.items
            .extend(accepted.into_iter().map(|(_, item)| item));
        self.proposed_name_utf16_units = requested_units;
        index.bind_to(self);
        Ok(count)
    }

    /// Removes caller-selected row indices and returns the number removed.
    pub fn remove_rows(&mut self, selected: &[usize]) -> usize {
        let selected = normalized_indices(selected, self.len());
        let removed_units = selected
            .iter()
            .map(|index| self.items[*index].proposed_name.len())
            .sum::<usize>();
        for index in selected.iter().rev() {
            self.items.remove(*index);
        }
        self.proposed_name_utf16_units -= removed_units;
        if !selected.is_empty() {
            self.invalidate_source_index();
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
        changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |item| item.current_name.clone(),
        )
    }

    /// Directly changes one proposed name, returning `false` for an invalid row.
    pub fn manual_change(
        &mut self,
        index: usize,
        proposed_name: impl Into<LegacyText>,
    ) -> Result<bool, ProposalMutationError> {
        self.set_manual_proposal(index, proposed_name.into())
            .map(|changed| changed.is_some())
    }

    /// Directly changes one proposal and reports whether its value changed.
    pub fn manual_change_changed(
        &mut self,
        index: usize,
        proposed_name: impl Into<LegacyText>,
    ) -> Result<bool, ProposalMutationError> {
        self.set_manual_proposal(index, proposed_name.into())
            .map(|changed| changed.unwrap_or(false))
    }

    fn set_manual_proposal(
        &mut self,
        index: usize,
        proposed_name: LegacyText,
    ) -> Result<Option<bool>, ProposalMutationError> {
        let Some(current) = self.items.get(index) else {
            return Ok(None);
        };
        validate_proposal_units(index, proposed_name.len())?;
        let total_units = self
            .proposed_name_utf16_units
            .checked_sub(current.proposed_name.len())
            .and_then(|total| total.checked_add(proposed_name.len()))
            .ok_or(ProposalMutationError::ArithmeticOverflow)?;
        if total_units > MAX_TOTAL_PROPOSED_NAME_UTF16_UNITS {
            return Err(ProposalMutationError::AggregateBudgetExceeded {
                requested_units: total_units,
                maximum_units: MAX_TOTAL_PROPOSED_NAME_UTF16_UNITS,
            });
        }
        let changed = current.proposed_name != proposed_name;
        self.items[index].proposed_name = proposed_name;
        self.proposed_name_utf16_units = total_units;
        Ok(Some(changed))
    }

    /// Records one successful legacy `MoveFile` result.
    ///
    /// The caller invokes this only after the external filesystem operation
    /// succeeds. Other rows remain untouched, preserving partial-success state.
    pub fn record_move_success(&mut self, index: usize) -> bool {
        let (old_proposal_units, new_proposal_units) = {
            let Some(item) = self.items.get_mut(index) else {
                return false;
            };
            let old_proposal_units = item.proposed_name.len();
            let new_path = item.planned_path();
            let current_name = path_name(&new_path);
            let new_proposal_units = current_name.len();
            item.root_path = path_root(&new_path);
            item.source_path = new_path;
            item.proposed_name.clone_from(&current_name);
            item.current_name = current_name;
            (old_proposal_units, new_proposal_units)
        };
        self.proposed_name_utf16_units =
            self.proposed_name_utf16_units - old_proposal_units + new_proposal_units;
        self.invalidate_source_index();
        true
    }

    /// Replaces all non-overlapping occurrences in the complete proposed name.
    pub fn replace_complete(
        &mut self,
        from: &LegacyText,
        to: &LegacyText,
    ) -> Result<(), ProposalMutationError> {
        self.replace_complete_changed(from, to).map(drop)
    }

    /// Replaces complete names and returns exactly which proposal rows changed.
    pub fn replace_complete_changed(
        &mut self,
        from: &LegacyText,
        to: &LegacyText,
    ) -> Result<Box<[usize]>, ProposalMutationError> {
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| {
                replaced_units(
                    row,
                    items[row].proposed_name.units(),
                    from.units(),
                    to.units(),
                )
            },
        )
    }

    /// Prepends text to the complete proposed name, including its extension.
    pub fn prefix_complete(&mut self, prefix: &LegacyText) -> Result<(), ProposalMutationError> {
        self.prefix_complete_changed(prefix).map(drop)
    }

    /// Prefixes complete names and returns exactly which proposal rows changed.
    pub fn prefix_complete_changed(
        &mut self,
        prefix: &LegacyText,
    ) -> Result<Box<[usize]>, ProposalMutationError> {
        if prefix.is_empty() {
            return Ok(Box::default());
        }
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| {
                let proposed = items[row].proposed_name.units();
                let requested_units = checked_sum(&[prefix.len(), proposed.len()])?;
                try_build_proposal(row, requested_units, |output| {
                    output.extend_from_slice(prefix.units());
                    output.extend_from_slice(proposed);
                })
            },
        )
    }

    /// Appends text immediately before a file extension.
    pub fn suffix_before_extension(
        &mut self,
        suffix: &LegacyText,
    ) -> Result<(), ProposalMutationError> {
        self.suffix_before_extension_changed(suffix).map(drop)
    }

    /// Suffixes stems and returns exactly which proposal rows changed.
    pub fn suffix_before_extension_changed(
        &mut self,
        suffix: &LegacyText,
    ) -> Result<Box<[usize]>, ProposalMutationError> {
        if suffix.is_empty() {
            return Ok(Box::default());
        }
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| {
                let (stem, extension) = stem_extension_units(&items[row]);
                let requested_units = checked_sum(&[stem.len(), suffix.len(), extension.len()])?;
                try_build_proposal(row, requested_units, |output| {
                    output.extend_from_slice(stem);
                    output.extend_from_slice(suffix.units());
                    output.extend_from_slice(extension);
                })
            },
        )
    }

    /// Clears the name stem while preserving the file extension.
    pub fn clear_name(&mut self) {
        let _ = self.clear_name_changed();
    }

    /// Clears stems and returns exactly which proposal rows changed.
    pub fn clear_name_changed(&mut self) -> Box<[usize]> {
        changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |item| {
                let (_stem, extension) = split_stem_extension(item);
                extension
            },
        )
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
        Ok(changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |item| {
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
            },
        ))
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
        changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |item| {
                let (mut stem, extension) = split_stem_extension(item);
                let count = count.min(stem.len());
                stem.units.truncate(stem.len() - count);
                stem.push(&extension);
                stem
            },
        )
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
        Ok(changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |item| {
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
            },
        ))
    }

    /// Retains only ASCII digits in each stem.
    pub fn keep_ascii_digits(&mut self) {
        let _ = self.keep_ascii_digits_changed();
    }

    /// Keeps ASCII digits and returns exactly which proposal rows changed.
    pub fn keep_ascii_digits_changed(&mut self) -> Box<[usize]> {
        changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |item| {
                let (mut stem, extension) = split_stem_extension(item);
                stem.units
                    .retain(|unit| (b'0' as u16..=b'9' as u16).contains(unit));
                stem.push(&extension);
                stem
            },
        )
    }

    /// Pads the last digit run selected by the original reverse scan.
    pub fn pad_last_digit_run(&mut self, width: usize) -> Result<(), ProposalMutationError> {
        self.pad_last_digit_run_changed(width).map(drop)
    }

    /// Pads final digit runs and returns exactly which proposal rows changed.
    pub fn pad_last_digit_run_changed(
        &mut self,
        width: usize,
    ) -> Result<Box<[usize]>, ProposalMutationError> {
        if width == 0 {
            return Err(LegacyInputError::NonPositiveWidth.into());
        }
        validate_proposal_units(0, width)?;
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| padded_digit_run_proposal(&items[row], row, width, last_digit_run),
        )
    }

    /// Pads the first digit run selected by the original forward scan.
    ///
    /// The MFC loop never assigned an end index when the run reached the end of
    /// the stem, so that particular run intentionally remains unchanged.
    pub fn pad_first_digit_run(&mut self, width: usize) -> Result<(), ProposalMutationError> {
        self.pad_first_digit_run_changed(width).map(drop)
    }

    /// Pads first digit runs and returns exactly which proposal rows changed.
    pub fn pad_first_digit_run_changed(
        &mut self,
        width: usize,
    ) -> Result<Box<[usize]>, ProposalMutationError> {
        if width == 0 {
            return Err(LegacyInputError::NonPositiveWidth.into());
        }
        validate_proposal_units(0, width)?;
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| padded_digit_run_proposal(&items[row], row, width, first_digit_run),
        )
    }

    /// Adds legacy sequence numbers without a separator.
    pub fn add_sequence(
        &mut self,
        width: usize,
        start: i32,
        mode: LegacySequenceMode,
    ) -> Result<(), ProposalMutationError> {
        self.add_sequence_by(width, start, mode, LegacyText::case_insensitive_cmp)
    }

    /// Adds sequence numbers and returns exactly which proposal rows changed.
    pub fn add_sequence_changed(
        &mut self,
        width: usize,
        start: i32,
        mode: LegacySequenceMode,
    ) -> Result<Box<[usize]>, ProposalMutationError> {
        self.add_sequence_by_changed(width, start, mode, LegacyText::case_insensitive_cmp)
    }

    /// Adds sequence numbers with a caller-provided parent-path comparator.
    pub fn add_sequence_by<F>(
        &mut self,
        width: usize,
        start: i32,
        mode: LegacySequenceMode,
        compare_text: F,
    ) -> Result<(), ProposalMutationError>
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
    ) -> Result<Box<[usize]>, ProposalMutationError>
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering + Copy,
    {
        if width == 0 {
            return Err(LegacyInputError::NonPositiveWidth.into());
        }
        validate_proposal_units(0, width)?;
        let start = start.max(0);
        let mut current = start;
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| {
                if row > 0
                    && matches!(
                        mode,
                        LegacySequenceMode::AppendRestartPerFolder
                            | LegacySequenceMode::PrependRestartPerFolder
                    )
                    && compare_text(&items[row - 1].root_path, &items[row].root_path)
                        != Ordering::Equal
                {
                    current = start;
                }
                let (stem, extension) = stem_extension_units(&items[row]);
                let value = current.to_string();
                let number_units = width.max(value.len());
                let requested_units = checked_sum(&[stem.len(), number_units, extension.len()])?;
                let append = matches!(
                    mode,
                    LegacySequenceMode::Append | LegacySequenceMode::AppendRestartPerFolder
                );
                let proposal = try_build_proposal(row, requested_units, |output| {
                    if append {
                        output.extend_from_slice(stem);
                    }
                    output.extend(std::iter::repeat_n(b'0' as u16, number_units - value.len()));
                    output.extend(value.encode_utf16());
                    if !append {
                        output.extend_from_slice(stem);
                    }
                    output.extend_from_slice(extension);
                })?;
                current = current.wrapping_add(1);
                Ok(proposal)
            },
        )
    }

    /// Removes the final extension from files and leaves directories unchanged.
    pub fn delete_extension(&mut self) {
        let _ = self.delete_extension_changed();
    }

    /// Deletes extensions and returns exactly which proposal rows changed.
    pub fn delete_extension_changed(&mut self) -> Box<[usize]> {
        changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |item| {
                let (stem, _extension) = split_stem_extension(item);
                stem
            },
        )
    }

    /// Appends an extension to every complete proposed name.
    pub fn add_extension(&mut self, extension: &LegacyText) -> Result<(), ProposalMutationError> {
        self.add_extension_changed(extension).map(drop)
    }

    /// Adds an extension and returns exactly which proposal rows changed.
    pub fn add_extension_changed(
        &mut self,
        extension: &LegacyText,
    ) -> Result<Box<[usize]>, ProposalMutationError> {
        let Some(extension) = try_normalized_extension(extension)? else {
            return Ok(Box::default());
        };
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| {
                let proposed = items[row].proposed_name.units();
                let requested_units = checked_sum(&[proposed.len(), extension.len()])?;
                try_build_proposal(row, requested_units, |output| {
                    output.extend_from_slice(proposed);
                    output.extend_from_slice(extension.units());
                })
            },
        )
    }

    /// Replaces the final file extension and appends to directory names.
    pub fn replace_extension(
        &mut self,
        extension: &LegacyText,
    ) -> Result<(), ProposalMutationError> {
        self.replace_extension_changed(extension).map(drop)
    }

    /// Replaces extensions and returns exactly which proposal rows changed.
    pub fn replace_extension_changed(
        &mut self,
        extension: &LegacyText,
    ) -> Result<Box<[usize]>, ProposalMutationError> {
        let Some(extension) = try_normalized_extension(extension)? else {
            return Ok(Box::default());
        };
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| {
                let (stem, _old_extension) = stem_extension_units(&items[row]);
                let requested_units = checked_sum(&[stem.len(), extension.len()])?;
                try_build_proposal(row, requested_units, |output| {
                    output.extend_from_slice(stem);
                    output.extend_from_slice(extension.units());
                })
            },
        )
    }

    /// Prefixes the immediate parent folder plus an underscore.
    pub fn prefix_parent_folder(&mut self) -> Result<(), ProposalMutationError> {
        self.prefix_parent_folder_changed().map(drop)
    }

    /// Prefixes parent folders and returns exactly which proposal rows changed.
    pub fn prefix_parent_folder_changed(&mut self) -> Result<Box<[usize]>, ProposalMutationError> {
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| {
                let item = &items[row];
                if let Some(folder) = parent_folder_units(&item.root_path) {
                    let requested_units =
                        checked_sum(&[folder.len(), 1, item.proposed_name.len()])?;
                    try_build_proposal(row, requested_units, |output| {
                        output.extend_from_slice(folder);
                        output.push(b'_' as u16);
                        output.extend_from_slice(item.proposed_name.units());
                    })
                } else {
                    try_build_proposal(row, item.proposed_name.len(), |output| {
                        output.extend_from_slice(item.proposed_name.units());
                    })
                }
            },
        )
    }

    /// Suffixes an underscore and immediate parent folder before the extension.
    pub fn suffix_parent_folder(&mut self) -> Result<(), ProposalMutationError> {
        self.suffix_parent_folder_changed().map(drop)
    }

    /// Suffixes parent folders and returns exactly which proposal rows changed.
    pub fn suffix_parent_folder_changed(&mut self) -> Result<Box<[usize]>, ProposalMutationError> {
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| {
                let item = &items[row];
                if let Some(folder) = parent_folder_units(&item.root_path) {
                    let (stem, extension) = stem_extension_units(item);
                    let requested_units =
                        checked_sum(&[stem.len(), 1, folder.len(), extension.len()])?;
                    try_build_proposal(row, requested_units, |output| {
                        output.extend_from_slice(stem);
                        output.push(b'_' as u16);
                        output.extend_from_slice(folder);
                        output.extend_from_slice(extension);
                    })
                } else {
                    try_build_proposal(row, item.proposed_name.len(), |output| {
                        output.extend_from_slice(item.proposed_name.units());
                    })
                }
            },
        )
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
    pub fn import_names(&mut self, text: &LegacyText) -> Result<usize, ProposalMutationError> {
        let count = trimmed_import_unit_slices(text)
            .take(self.items.len())
            .count();
        self.import_names_changed(text).map(|_| count)
    }

    /// Imports names and returns exactly which proposal rows changed.
    pub fn import_names_changed(
        &mut self,
        text: &LegacyText,
    ) -> Result<Box<[usize]>, ProposalMutationError> {
        let mut lines = trimmed_import_unit_slices(text).take(self.items.len());
        try_changed_proposals(
            &mut self.items,
            &mut self.proposed_name_utf16_units,
            |items, row| {
                let Some(units) = lines.next() else {
                    return try_build_proposal(row, items[row].proposed_name.len(), |output| {
                        output.extend_from_slice(items[row].proposed_name.units());
                    });
                };
                try_build_proposal(row, units.len(), |output| {
                    output.extend_from_slice(units);
                })
            },
        )
    }
}

fn changed_proposals(
    items: &mut [LegacyListItem],
    proposed_name_utf16_units: &mut usize,
    mut proposal: impl FnMut(&LegacyListItem) -> LegacyText,
) -> Box<[usize]> {
    let mut changed = Vec::with_capacity(items.len());
    let mut total_units = 0_usize;
    for (index, item) in items.iter_mut().enumerate() {
        let next = proposal(item);
        total_units += next.len();
        if item.proposed_name != next {
            item.proposed_name = next;
            changed.push(index);
        }
    }
    *proposed_name_utf16_units = total_units;
    changed.into_boxed_slice()
}

struct StagedProposal {
    row: usize,
    value: LegacyText,
}

fn try_changed_proposals(
    items: &mut [LegacyListItem],
    proposed_name_utf16_units: &mut usize,
    mut proposal: impl FnMut(&[LegacyListItem], usize) -> Result<LegacyText, ProposalMutationError>,
) -> Result<Box<[usize]>, ProposalMutationError> {
    let mut staged = Vec::<StagedProposal>::new();
    let mut total_units = 0_usize;
    for row in 0..items.len() {
        let next = proposal(items, row)?;
        validate_proposal_units(row, next.len())?;
        total_units = total_units
            .checked_add(next.len())
            .ok_or(ProposalMutationError::ArithmeticOverflow)?;
        if total_units > MAX_TOTAL_PROPOSED_NAME_UTF16_UNITS {
            return Err(ProposalMutationError::AggregateBudgetExceeded {
                requested_units: total_units,
                maximum_units: MAX_TOTAL_PROPOSED_NAME_UTF16_UNITS,
            });
        }
        if items[row].proposed_name != next {
            staged
                .try_reserve(1)
                .map_err(|_| ProposalMutationError::AllocationFailed)?;
            staged.push(StagedProposal { row, value: next });
        }
    }

    let mut changed = Vec::new();
    changed
        .try_reserve_exact(staged.len())
        .map_err(|_| ProposalMutationError::AllocationFailed)?;
    for update in staged {
        items[update.row].proposed_name = update.value;
        changed.push(update.row);
    }
    *proposed_name_utf16_units = total_units;
    Ok(changed.into_boxed_slice())
}

fn validate_proposal_units(
    row: usize,
    requested_units: usize,
) -> Result<(), ProposalMutationError> {
    if requested_units > MAX_PROPOSED_NAME_UTF16_UNITS {
        Err(ProposalMutationError::NameBudgetExceeded {
            row,
            requested_units,
            maximum_units: MAX_PROPOSED_NAME_UTF16_UNITS,
        })
    } else {
        Ok(())
    }
}

fn try_build_proposal(
    row: usize,
    requested_units: usize,
    fill: impl FnOnce(&mut Vec<u16>),
) -> Result<LegacyText, ProposalMutationError> {
    validate_proposal_units(row, requested_units)?;
    let mut units = Vec::new();
    units
        .try_reserve_exact(requested_units)
        .map_err(|_| ProposalMutationError::AllocationFailed)?;
    fill(&mut units);
    debug_assert_eq!(units.len(), requested_units);
    Ok(LegacyText::from_units(units))
}

fn checked_sum(parts: &[usize]) -> Result<usize, ProposalMutationError> {
    parts.iter().try_fold(0_usize, |total, part| {
        total
            .checked_add(*part)
            .ok_or(ProposalMutationError::ArithmeticOverflow)
    })
}

fn try_clone_text(text: &LegacyText) -> Result<LegacyText, ProposalMutationError> {
    let mut units = Vec::new();
    units
        .try_reserve_exact(text.len())
        .map_err(|_| ProposalMutationError::AllocationFailed)?;
    units.extend_from_slice(text.units());
    Ok(LegacyText::from_units(units))
}

/// Splits LF-delimited import text, trims each line, and skips blank lines.
#[must_use]
pub fn parse_import_lines(text: &LegacyText) -> Vec<LegacyText> {
    trimmed_import_unit_slices(text)
        .map(|units| LegacyText::from_units(units.to_vec()))
        .collect()
}

fn trimmed_import_unit_slices(text: &LegacyText) -> impl Iterator<Item = &[u16]> {
    text.units.split(|unit| *unit == LF).filter_map(|units| {
        let first = units
            .iter()
            .position(|unit| !is_trim_unit(*unit))
            .unwrap_or(units.len());
        let last = units
            .iter()
            .rposition(|unit| !is_trim_unit(*unit))
            .map_or(first, |index| index + 1);
        (first < last).then_some(&units[first..last])
    })
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
    let (stem, extension) = stem_extension_units(item);
    (
        LegacyText::from_units(stem.to_vec()),
        LegacyText::from_units(extension.to_vec()),
    )
}

fn stem_extension_units(item: &LegacyListItem) -> (&[u16], &[u16]) {
    let name_start = item
        .proposed_name
        .units
        .iter()
        .rposition(|unit| *unit == BACKSLASH)
        .map_or(0, |index| index + 1);
    if item.is_directory {
        return (&item.proposed_name.units[name_start..], &[] as &[u16]);
    }
    item.proposed_name
        .units
        .iter()
        .rposition(|unit| *unit == DOT)
        .map_or_else(
            || (&item.proposed_name.units[name_start..], &[] as &[u16]),
            |index| {
                (
                    &item.proposed_name.units[name_start..index.max(name_start)],
                    &item.proposed_name.units[index..],
                )
            },
        )
}

fn replaced_units(
    row: usize,
    source: &[u16],
    needle: &[u16],
    replacement: &[u16],
) -> Result<LegacyText, ProposalMutationError> {
    if needle.is_empty() || needle.len() > source.len() {
        return try_build_proposal(row, source.len(), |output| {
            output.extend_from_slice(source);
        });
    }
    let mut requested_units = 0_usize;
    let mut index = 0_usize;
    while index < source.len() {
        let segment_units = if source[index..].starts_with(needle) {
            index = index
                .checked_add(needle.len())
                .ok_or(ProposalMutationError::ArithmeticOverflow)?;
            replacement.len()
        } else {
            index = index
                .checked_add(1)
                .ok_or(ProposalMutationError::ArithmeticOverflow)?;
            1
        };
        requested_units = requested_units
            .checked_add(segment_units)
            .ok_or(ProposalMutationError::ArithmeticOverflow)?;
        validate_proposal_units(row, requested_units)?;
    }

    try_build_proposal(row, requested_units, |output| {
        let mut index = 0_usize;
        while index < source.len() {
            if source[index..].starts_with(needle) {
                output.extend_from_slice(replacement);
                index += needle.len();
            } else {
                output.push(source[index]);
                index += 1;
            }
        }
    })
}

fn try_normalized_extension(
    extension: &LegacyText,
) -> Result<Option<LegacyText>, ProposalMutationError> {
    if extension.is_empty() {
        return Ok(None);
    }
    if extension.units.first() == Some(&DOT) {
        try_build_proposal(0, extension.len(), |output| {
            output.extend_from_slice(extension.units());
        })
        .map(Some)
    } else {
        let requested_units = checked_sum(&[1, extension.len()])?;
        try_build_proposal(0, requested_units, |output| {
            output.push(DOT);
            output.extend_from_slice(extension.units());
        })
        .map(Some)
    }
}

fn parent_folder_units(root_path: &LegacyText) -> Option<&[u16]> {
    let start = root_path
        .units
        .iter()
        .rposition(|unit| *unit == BACKSLASH)
        .map_or(0, |index| index + 1);
    (start > 0).then_some(&root_path.units[start..])
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

fn padded_digit_run_proposal(
    item: &LegacyListItem,
    row: usize,
    width: usize,
    find_run: impl FnOnce(&[u16]) -> Option<(usize, usize)>,
) -> Result<LegacyText, ProposalMutationError> {
    let (stem, extension) = stem_extension_units(item);
    let Some((start, end)) = find_run(stem) else {
        let requested_units = checked_sum(&[stem.len(), extension.len()])?;
        return try_build_proposal(row, requested_units, |output| {
            output.extend_from_slice(stem);
            output.extend_from_slice(extension);
        });
    };
    let run_length = end - start + 1;
    let padding = width.saturating_sub(run_length);
    let requested_units = checked_sum(&[stem.len(), padding, extension.len()])?;
    try_build_proposal(row, requested_units, |output| {
        output.extend_from_slice(&stem[..start]);
        output.extend(std::iter::repeat_n(b'0' as u16, padding));
        output.extend_from_slice(&stem[start..]);
        output.extend_from_slice(extension);
    })
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

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    fn item(path: String) -> LegacyListItem {
        LegacyListItem::new(path, false, 0, 0, 0)
    }

    fn assert_bounded_chunks<F>(index: &LegacyAppendIndex<F>, source_count: usize)
    where
        F: Fn(&LegacyText, &LegacyText) -> Ordering,
    {
        assert_eq!(
            index.chunks.iter().map(Vec::len).sum::<usize>(),
            source_count
        );
        assert!(
            index
                .chunks
                .iter()
                .all(|chunk| !chunk.is_empty() && chunk.len() <= APPEND_INDEX_CHUNK_CAPACITY)
        );
        let maximum_chunks = source_count
            .div_ceil(APPEND_INDEX_CHUNK_CAPACITY)
            .saturating_mul(2)
            .saturating_add(2);
        assert!(index.chunks.len() <= maximum_chunks);
        let mut previous = None;
        for source in index.chunks.iter().flatten() {
            if let Some(previous) = previous {
                assert_ne!((index.compare_text)(previous, source), Ordering::Greater);
            }
            previous = Some(source);
        }
    }

    #[test]
    fn front_batch_insertions_bound_source_relocations_to_chunk_size() {
        let comparisons = Cell::new(0_usize);
        let compare = |left: &LegacyText, right: &LegacyText| {
            comparisons.set(comparisons.get() + 1);
            left.units().cmp(right.units())
        };
        let mut index = LegacyAppendIndex::new(compare);
        let mut list = LegacyList::new();
        let existing = (0..5_000).map(|value| item(format!(r"C:\z\{value:05}.txt")));
        assert_eq!(list.append_batch_indexed(&mut index, existing), Ok(5_000));
        comparisons.set(0);
        index.reset_test_metrics();

        let incoming = (0..5_000)
            .rev()
            .map(|value| item(format!(r"C:\a\{value:05}.txt")));
        assert_eq!(list.append_batch_indexed(&mut index, incoming), Ok(5_000));

        let metrics = index.test_metrics;
        eprintln!(
            "front 5k+5k: {} comparisons, {} source relocations, {} outer chunk moves, {} chunks",
            comparisons.get(),
            metrics.source_relocations,
            metrics.outer_chunk_moves,
            index.chunks.len()
        );
        assert!(comparisons.get() < 300_000);
        assert!(metrics.maximum_source_relocations <= APPEND_INDEX_CHUNK_CAPACITY);
        assert!(
            metrics.source_relocations <= 5_000_usize.saturating_mul(APPEND_INDEX_CHUNK_CAPACITY)
        );
        assert!(metrics.outer_chunk_moves < 100_000);
        assert_bounded_chunks(&index, 10_000);
    }

    #[test]
    fn reverse_single_insertions_remain_bounded_by_chunk_size() {
        let comparisons = Cell::new(0_usize);
        let compare = |left: &LegacyText, right: &LegacyText| {
            comparisons.set(comparisons.get() + 1);
            left.units().cmp(right.units())
        };
        let mut index = LegacyAppendIndex::new(compare);
        let mut list = LegacyList::new();

        for value in (0..5_000).rev() {
            assert_eq!(
                list.append_indexed(&mut index, item(format!(r"C:\r\{value:05}.txt"))),
                Ok(true)
            );
        }

        let metrics = index.test_metrics;
        eprintln!(
            "reverse 5k singles: {} comparisons, {} source relocations, {} outer chunk moves, {} chunks",
            comparisons.get(),
            metrics.source_relocations,
            metrics.outer_chunk_moves,
            index.chunks.len()
        );
        assert!(comparisons.get() < 150_000);
        assert!(metrics.maximum_source_relocations <= APPEND_INDEX_CHUNK_CAPACITY);
        assert!(
            metrics.source_relocations <= 5_000_usize.saturating_mul(APPEND_INDEX_CHUNK_CAPACITY)
        );
        assert!(metrics.outer_chunk_moves < 100_000);
        assert_bounded_chunks(&index, 5_000);
    }

    #[test]
    fn cache_update_allocation_failure_clears_partial_index_before_retry() {
        let mut index = LegacyAppendIndex::new(LegacyText::case_insensitive_cmp);
        let mut list = LegacyList::new();
        let existing = (0..100).map(|value| item(format!(r"C:\old\{value:03}.txt")));
        assert_eq!(list.append_batch_indexed(&mut index, existing), Ok(100));
        let incoming = (0..10)
            .map(|value| item(format!(r"C:\new\{value:03}.txt")))
            .collect::<Vec<_>>();
        let before = list.clone();
        let before_units = list.proposed_name_utf16_units();
        index.fail_cache_update_after = Some(3);

        assert_eq!(
            list.append_batch_indexed(&mut index, incoming.clone()),
            Err(ProposalMutationError::AllocationFailed)
        );
        assert_eq!(list, before);
        assert_eq!(list.proposed_name_utf16_units(), before_units);
        assert!(index.chunks.is_empty());
        assert!(!index.is_current_for(&list));

        index.fail_cache_update_after = None;
        assert_eq!(list.append_batch_indexed(&mut index, incoming), Ok(10));
        assert_bounded_chunks(&index, 110);
    }
}
