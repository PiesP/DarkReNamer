//! Bounded iterative source admission without UI concerns.

use std::cmp::Ordering;
use std::collections::{BTreeSet, VecDeque};
use std::fmt;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use darknamer_core::{LegacyListItem, LegacyText};

use crate::rename::EntryIdentity;

/// Hard limit applied before inspecting further candidate metadata.
pub const MAX_ADMITTED_SOURCES: usize = 10_000;
/// Maximum directory nesting inspected or enumerated by admission.
pub const MAX_ADMISSION_DEPTH: usize = 256;
/// Maximum imported text bytes read into memory.
pub const MAX_IMPORT_BYTES: usize = 2 * 1024 * 1024;

/// Bounded count selected from an external picker/drop report.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BoundedSelection {
    /// Number of entries to extract, including at most one overflow witness.
    pub take: usize,
    /// Whether the reported count exceeded remaining capacity.
    pub truncated: bool,
}

/// Bounds external selection extraction before per-path allocation.
#[must_use]
pub fn bounded_selection(reported: usize, remaining: usize) -> BoundedSelection {
    let witness_bound = remaining.saturating_add(1);
    BoundedSelection {
        take: reported.min(witness_bound),
        truncated: reported > remaining,
    }
}

/// Reads at most [`MAX_IMPORT_BYTES`] and rejects an oversized stream.
pub fn read_bounded_import(mut reader: impl Read) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .by_ref()
        .take((MAX_IMPORT_BYTES as u64).saturating_add(1))
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_IMPORT_BYTES {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "import text exceeds byte limit",
        ))
    } else {
        Ok(bytes)
    }
}

/// Parses at most `limit` nonblank trimmed LF-delimited lines plus one witness.
#[must_use]
pub fn bounded_import_lines(text: &LegacyText, limit: usize) -> (Vec<LegacyText>, bool) {
    let mut lines = Vec::with_capacity(limit.min(1024));
    for units in text.units().split(|unit| *unit == b'\n' as u16) {
        let first = units
            .iter()
            .position(|unit| !is_trim_unit(*unit))
            .unwrap_or(units.len());
        let last = units
            .iter()
            .rposition(|unit| !is_trim_unit(*unit))
            .map_or(first, |index| index + 1);
        if first == last {
            continue;
        }
        lines.push(LegacyText::from_units(units[first..last].to_vec()));
        if lines.len() > limit {
            lines.truncate(limit);
            return (lines, true);
        }
    }
    (lines, false)
}

fn is_trim_unit(unit: u16) -> bool {
    char::from_u32(u32::from(unit)).is_some_and(char::is_whitespace)
}

/// Whether selected directories are rows or traversal roots.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdmissionMode {
    /// Admit the selected directory itself.
    Direct,
    /// Admit bounded descendants and not the traversal root.
    Recurse,
}

/// Structured reason one candidate was not admitted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdmissionIssueKind {
    /// Input was not an absolute path.
    RelativePath,
    /// Metadata or stable-identity inspection failed.
    Metadata,
    /// Directory enumeration failed wholly or partially.
    ReadDirectory,
    /// Final entry is a reparse point and was not followed.
    ReparsePoint,
    /// The hard admission bound stopped further inspection.
    LimitReached,
    /// The same stable directory identity was encountered again.
    RepeatedDirectory,
    /// Directory nesting exceeded the bounded admission depth.
    DepthExceeded,
}

/// One path-scoped admission issue.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdmissionIssue {
    /// Candidate associated with the issue.
    pub path: PathBuf,
    /// Structured issue kind.
    pub kind: AdmissionIssueKind,
    /// Adapter operation that failed, when applicable.
    pub operation: Option<AdmissionOperation>,
    /// Native error code retained without a path, when available.
    pub code: Option<u32>,
}

/// Metadata needed to construct one legacy-compatible row.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdmissionMetadata {
    /// Whether the candidate is a directory.
    pub is_directory: bool,
    /// Whether the final entry is a reparse point.
    pub is_reparse_point: bool,
    /// Stable identity for directory-loop detection, when available.
    pub directory_identity: Option<EntryIdentity>,
    /// Exact 64-bit file size observed by the platform.
    pub actual_size: u64,
    /// Original creation time.
    pub created: u64,
    /// Original modification time.
    pub modified: u64,
}

/// Bounded directory read result.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdmissionChildren {
    /// Bounded children; the collector sorts the returned subset.
    pub paths: Vec<PathBuf>,
    /// At least one directory-entry read failed.
    pub had_errors: bool,
    /// More children existed than the supplied bound.
    pub truncated: bool,
}

/// Adapter operation failure without leaking native paths or error strings.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum AdmissionOperation {
    /// Safe path and parent policy validation.
    Validation,
    /// Entry metadata or identity observation.
    Metadata,
    /// Retained-handle directory enumeration.
    ReadDirectory,
}

/// Structured adapter failure preserving operation and native code.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdmissionAdapterError {
    /// Failed operation.
    pub operation: AdmissionOperation,
    /// Native OS error code, when available.
    pub code: Option<u32>,
}

/// Cooperative cancellation observed while collecting admission sources.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdmissionCancelled;

/// One directory-read outcome kept separate from filesystem failures.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdmissionReadError {
    /// The caller requested cooperative cancellation.
    Cancelled,
    /// The platform adapter could not enumerate the directory.
    Adapter(AdmissionAdapterError),
}

impl fmt::Display for AdmissionCancelled {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("source admission was cancelled")
    }
}

impl std::error::Error for AdmissionCancelled {}

impl fmt::Display for AdmissionReadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Cancelled => formatter.write_str("directory admission was cancelled"),
            Self::Adapter(error) => write!(
                formatter,
                "directory admission {:?} failed with code {:?}",
                error.operation, error.code
            ),
        }
    }
}

impl std::error::Error for AdmissionReadError {}

impl From<AdmissionAdapterError> for AdmissionReadError {
    fn from(error: AdmissionAdapterError) -> Self {
        Self::Adapter(error)
    }
}

impl AdmissionAdapterError {
    /// Creates an adapter error without a native code.
    #[must_use]
    pub const fn new(operation: AdmissionOperation) -> Self {
        Self {
            operation,
            code: None,
        }
    }

    #[cfg(windows)]
    fn from_io(operation: AdmissionOperation, error: &io::Error) -> Self {
        Self {
            operation,
            code: error
                .raw_os_error()
                .and_then(|code| u32::try_from(code).ok()),
        }
    }
}

/// Local filesystem seam used by iterative admission and focused tests.
pub trait AdmissionAdapter {
    /// Validates path policy and retains any parent authority needed later.
    fn validate_path(&self, path: &Path) -> Result<(), AdmissionAdapterError>;

    /// Inspects one candidate without following its final component.
    fn metadata(&self, path: &Path) -> Result<AdmissionMetadata, AdmissionAdapterError>;

    /// Reads at most `limit` deterministic children.
    fn read_children(
        &self,
        path: &Path,
        limit: usize,
    ) -> Result<AdmissionChildren, AdmissionAdapterError>;

    /// Reads children while polling cancellation between platform entries.
    ///
    /// The default keeps existing adapters source-compatible; production
    /// adapters with incremental enumeration should override this method.
    fn read_children_cancellable(
        &self,
        path: &Path,
        limit: usize,
        cancellation_requested: &dyn Fn() -> bool,
    ) -> Result<AdmissionChildren, AdmissionReadError> {
        if cancellation_requested() {
            return Err(AdmissionReadError::Cancelled);
        }
        let children = self.read_children(path, limit)?;
        if cancellation_requested() {
            Err(AdmissionReadError::Cancelled)
        } else {
            Ok(children)
        }
    }

    /// Converts a platform path into exact legacy text.
    fn legacy_path(&self, path: &Path) -> LegacyText;
}

/// Complete accepted rows plus visible issues.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AdmissionReport {
    /// Accepted legacy-compatible rows.
    pub items: Vec<LegacyListItem>,
    /// Rejected/skipped candidates and reasons.
    pub issues: Vec<AdmissionIssue>,
}

impl AdmissionReport {
    /// Returns a concise Korean summary for the native status/message surface.
    #[must_use]
    pub fn summary_korean(&self, appended: usize) -> String {
        let count = |kind| {
            self.issues
                .iter()
                .filter(|issue| issue.kind == kind)
                .count()
        };
        let mut summary = format!(
            "{}개 추가, {}개 제외/중단 (상대경로 {}, 메타데이터 {}, 폴더읽기 {}, 재분석지점 {}, 한도 {}, 반복폴더 {}, 깊이 {})",
            appended,
            self.issues.len(),
            count(AdmissionIssueKind::RelativePath),
            count(AdmissionIssueKind::Metadata),
            count(AdmissionIssueKind::ReadDirectory),
            count(AdmissionIssueKind::ReparsePoint),
            count(AdmissionIssueKind::LimitReached),
            count(AdmissionIssueKind::RepeatedDirectory),
            count(AdmissionIssueKind::DepthExceeded),
        );
        let codes = self
            .issues
            .iter()
            .filter_map(|issue| Some((issue.operation?, issue.code?)))
            .collect::<BTreeSet<_>>();
        if !codes.is_empty() {
            let codes = codes
                .into_iter()
                .map(|(operation, code)| format!("{operation:?}:{code}"))
                .collect::<Vec<_>>()
                .join(", ");
            summary.push_str(&format!(" 코드 {codes}"));
        }
        summary
    }
}

fn issue(
    path: PathBuf,
    kind: AdmissionIssueKind,
    error: Option<AdmissionAdapterError>,
) -> AdmissionIssue {
    AdmissionIssue {
        path,
        kind,
        operation: error.map(|error| error.operation),
        code: error.and_then(|error| error.code),
    }
}

/// Collects sources iteratively in bounded depth-first order, sorting each
/// bounded root/child subset without claiming a global lexical capped subset.
pub fn collect_admission(
    adapter: &dyn AdmissionAdapter,
    roots: Vec<PathBuf>,
    mode: AdmissionMode,
    capacity: usize,
    compare_paths: impl Fn(&Path, &Path) -> Ordering + Copy,
) -> AdmissionReport {
    match collect_admission_cancellable(adapter, roots, mode, capacity, compare_paths, || false) {
        Ok(report) => report,
        Err(AdmissionCancelled) => {
            unreachable!("the non-cancellable admission wrapper cannot be cancelled")
        }
    }
}

/// Collects sources while polling cooperative cancellation throughout traversal.
///
/// # Errors
///
/// Returns [`AdmissionCancelled`] without manufacturing a path-scoped issue
/// when the caller requests cancellation.
pub fn collect_admission_cancellable(
    adapter: &dyn AdmissionAdapter,
    mut roots: Vec<PathBuf>,
    mode: AdmissionMode,
    capacity: usize,
    compare_paths: impl Fn(&Path, &Path) -> Ordering + Copy,
    cancellation_requested: impl Fn() -> bool,
) -> Result<AdmissionReport, AdmissionCancelled> {
    let capacity = capacity.min(MAX_ADMITTED_SOURCES);
    let mut report = AdmissionReport::default();
    if cancellation_requested() {
        return Err(AdmissionCancelled);
    }
    if roots.len() > capacity {
        report.issues.push(issue(
            roots[capacity].clone(),
            AdmissionIssueKind::LimitReached,
            None,
        ));
        roots.truncate(capacity);
    }
    roots.sort_by(|left, right| compare_paths(left, right));
    if cancellation_requested() {
        return Err(AdmissionCancelled);
    }
    let mut stack = VecDeque::new();
    for root in roots.into_iter().rev() {
        if cancellation_requested() {
            return Err(AdmissionCancelled);
        }
        stack.push_back((root, 0_usize));
    }
    let mut seen_directories = BTreeSet::new();
    let mut inspected = 0_usize;

    while let Some((path, depth)) = stack.pop_back() {
        if cancellation_requested() {
            return Err(AdmissionCancelled);
        }
        if inspected >= capacity {
            report
                .issues
                .push(issue(path, AdmissionIssueKind::LimitReached, None));
            break;
        }
        inspected += 1;
        if !path.is_absolute() {
            report
                .issues
                .push(issue(path, AdmissionIssueKind::RelativePath, None));
            continue;
        }
        if let Err(error) = adapter.validate_path(&path) {
            report
                .issues
                .push(issue(path, AdmissionIssueKind::Metadata, Some(error)));
            continue;
        }
        if cancellation_requested() {
            return Err(AdmissionCancelled);
        }
        let metadata = match adapter.metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) => {
                report
                    .issues
                    .push(issue(path, AdmissionIssueKind::Metadata, Some(error)));
                continue;
            }
        };
        if cancellation_requested() {
            return Err(AdmissionCancelled);
        }
        if metadata.is_reparse_point {
            report
                .issues
                .push(issue(path, AdmissionIssueKind::ReparsePoint, None));
            continue;
        }
        if metadata.is_directory {
            if let Some(identity) = metadata.directory_identity
                && !seen_directories.insert(identity)
            {
                report
                    .issues
                    .push(issue(path, AdmissionIssueKind::RepeatedDirectory, None));
                continue;
            }
            if mode == AdmissionMode::Recurse {
                if depth >= MAX_ADMISSION_DEPTH {
                    report
                        .issues
                        .push(issue(path, AdmissionIssueKind::DepthExceeded, None));
                    continue;
                }
                let remaining = capacity
                    .saturating_sub(inspected)
                    .saturating_sub(stack.len());
                if remaining == 0 {
                    report
                        .issues
                        .push(issue(path, AdmissionIssueKind::LimitReached, None));
                    break;
                }
                match adapter.read_children_cancellable(&path, remaining, &cancellation_requested) {
                    Ok(mut children) => {
                        children
                            .paths
                            .sort_by(|left, right| compare_paths(left, right));
                        for child in children.paths.into_iter().rev() {
                            if cancellation_requested() {
                                return Err(AdmissionCancelled);
                            }
                            stack.push_back((child, depth + 1));
                        }
                        if children.had_errors {
                            report.issues.push(issue(
                                path.clone(),
                                AdmissionIssueKind::ReadDirectory,
                                None,
                            ));
                        }
                        if children.truncated {
                            report
                                .issues
                                .push(issue(path, AdmissionIssueKind::LimitReached, None));
                        }
                    }
                    Err(AdmissionReadError::Cancelled) => return Err(AdmissionCancelled),
                    Err(AdmissionReadError::Adapter(error)) => report.issues.push(issue(
                        path,
                        AdmissionIssueKind::ReadDirectory,
                        Some(error),
                    )),
                }
                continue;
            }
        }
        report.items.push(LegacyListItem::new_with_actual_size(
            adapter.legacy_path(&path),
            metadata.is_directory,
            metadata.actual_size as u32,
            metadata.actual_size,
            metadata.created,
            metadata.modified,
        ));
    }
    Ok(report)
}

#[cfg(windows)]
mod windows {
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::fs::File;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use std::os::windows::fs::MetadataExt;

    use darknamer_core::validate_windows_leaf_name;

    use crate::rename::windows_native::{
        DirectoryQueryError, NativeParent, file_identity, open_directory_entry, open_entry,
        query_directory_names, query_directory_names_cancellable,
    };

    use super::*;

    /// Safe Windows adapter used by picker, drop, and path import.
    #[derive(Debug, Default)]
    pub struct WindowsAdmissionAdapter {
        parents: RefCell<BTreeMap<PathBuf, NativeParent>>,
        directories: RefCell<BTreeMap<PathBuf, File>>,
        metadata_cache: RefCell<BTreeMap<PathBuf, AdmissionMetadata>>,
    }

    impl WindowsAdmissionAdapter {
        /// Creates an empty retained-handle admission session.
        #[must_use]
        pub fn new() -> Self {
            Self::default()
        }

        fn parent_and_leaf(path: &Path) -> Result<(PathBuf, Vec<u16>), AdmissionAdapterError> {
            let parent = path
                .parent()
                .ok_or(AdmissionAdapterError::new(AdmissionOperation::Validation))?
                .to_path_buf();
            let leaf = path
                .file_name()
                .ok_or(AdmissionAdapterError::new(AdmissionOperation::Validation))?
                .encode_wide()
                .collect::<Vec<_>>();
            if validate_windows_leaf_name(&LegacyText::from_units(leaf.clone())).is_err() {
                return Err(AdmissionAdapterError::new(AdmissionOperation::Validation));
            }
            Ok((parent, leaf))
        }
    }

    impl AdmissionAdapter for WindowsAdmissionAdapter {
        fn validate_path(&self, path: &Path) -> Result<(), AdmissionAdapterError> {
            let (parent, _leaf) = Self::parent_and_leaf(path)?;
            if !self.parents.borrow().contains_key(&parent) {
                let handle = NativeParent::open_path(&parent).map_err(|error| {
                    AdmissionAdapterError::from_io(AdmissionOperation::Validation, &error)
                })?;
                self.parents.borrow_mut().insert(parent, handle);
            }
            Ok(())
        }

        fn metadata(&self, path: &Path) -> Result<AdmissionMetadata, AdmissionAdapterError> {
            if let Some(metadata) = self.metadata_cache.borrow().get(path).copied() {
                return Ok(metadata);
            }
            let (parent_path, leaf) = Self::parent_and_leaf(path)?;
            let parents = self.parents.borrow();
            let parent = parents
                .get(&parent_path)
                .ok_or(AdmissionAdapterError::new(AdmissionOperation::Metadata))?;
            let file = open_entry(parent, &leaf, false).map_err(|error| {
                AdmissionAdapterError::from_io(AdmissionOperation::Metadata, &error)
            })?;
            let metadata = file.metadata().map_err(|error| {
                AdmissionAdapterError::from_io(AdmissionOperation::Metadata, &error)
            })?;
            let attributes = metadata.file_attributes();
            let is_directory = attributes & 0x10 != 0;
            let is_reparse_point = attributes & 0x400 != 0;
            let directory_identity = if is_directory && !is_reparse_point {
                let identity = file_identity(&file).map_err(|error| {
                    AdmissionAdapterError::from_io(AdmissionOperation::Metadata, &error)
                })?;
                let directory = open_directory_entry(parent, &leaf).map_err(|error| {
                    AdmissionAdapterError::from_io(AdmissionOperation::Metadata, &error)
                })?;
                self.directories
                    .borrow_mut()
                    .insert(path.to_path_buf(), directory);
                Some(EntryIdentity::new(identity.volume, identity.file_id))
            } else {
                None
            };
            let admitted = AdmissionMetadata {
                is_directory,
                is_reparse_point,
                directory_identity,
                actual_size: metadata.file_size(),
                created: metadata.creation_time(),
                modified: metadata.last_write_time(),
            };
            self.metadata_cache
                .borrow_mut()
                .insert(path.to_path_buf(), admitted);
            Ok(admitted)
        }

        fn read_children(
            &self,
            path: &Path,
            limit: usize,
        ) -> Result<AdmissionChildren, AdmissionAdapterError> {
            let directories = self.directories.borrow();
            let directory = directories.get(path).ok_or(AdmissionAdapterError::new(
                AdmissionOperation::ReadDirectory,
            ))?;
            let (names, truncated) = query_directory_names(directory, limit).map_err(|error| {
                AdmissionAdapterError::from_io(AdmissionOperation::ReadDirectory, &error)
            })?;
            let mut paths = Vec::with_capacity(names.len());
            let mut had_errors = false;
            for name in names {
                let text = LegacyText::from_units(name.clone());
                if validate_windows_leaf_name(&text).is_err() {
                    had_errors = true;
                    continue;
                }
                paths.push(path.join(std::ffi::OsString::from_wide(&name)));
            }
            Ok(AdmissionChildren {
                paths,
                had_errors,
                truncated,
            })
        }

        fn read_children_cancellable(
            &self,
            path: &Path,
            limit: usize,
            cancellation_requested: &dyn Fn() -> bool,
        ) -> Result<AdmissionChildren, AdmissionReadError> {
            let directories = self.directories.borrow();
            let directory = directories
                .get(path)
                .ok_or_else(|| AdmissionAdapterError::new(AdmissionOperation::ReadDirectory))?;
            let (names, truncated) =
                query_directory_names_cancellable(directory, limit, cancellation_requested)
                    .map_err(|error| match error {
                        DirectoryQueryError::Cancelled => AdmissionReadError::Cancelled,
                        DirectoryQueryError::Io(error) => {
                            AdmissionReadError::Adapter(AdmissionAdapterError::from_io(
                                AdmissionOperation::ReadDirectory,
                                &error,
                            ))
                        }
                    })?;
            let mut paths = Vec::with_capacity(names.len());
            let mut had_errors = false;
            for name in names {
                if cancellation_requested() {
                    return Err(AdmissionReadError::Cancelled);
                }
                let text = LegacyText::from_units(name.clone());
                if validate_windows_leaf_name(&text).is_err() {
                    had_errors = true;
                    continue;
                }
                paths.push(path.join(std::ffi::OsString::from_wide(&name)));
            }
            Ok(AdmissionChildren {
                paths,
                had_errors,
                truncated,
            })
        }

        fn legacy_path(&self, path: &Path) -> LegacyText {
            LegacyText::from_units(path.as_os_str().encode_wide().collect::<Vec<_>>())
        }
    }
}

#[cfg(windows)]
pub use windows::WindowsAdmissionAdapter;
