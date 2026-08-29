//! Bounded iterative source admission without UI concerns.

use std::cmp::Ordering;
use std::collections::{BTreeSet, VecDeque};
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
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdmissionAdapterError;

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
        format!(
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
        )
    }
}

/// Collects sources iteratively in bounded depth-first order, sorting each
/// bounded root/child subset without claiming a global lexical capped subset.
pub fn collect_admission(
    adapter: &dyn AdmissionAdapter,
    mut roots: Vec<PathBuf>,
    mode: AdmissionMode,
    capacity: usize,
    compare_paths: impl Fn(&Path, &Path) -> Ordering + Copy,
) -> AdmissionReport {
    let capacity = capacity.min(MAX_ADMITTED_SOURCES);
    let mut report = AdmissionReport::default();
    if roots.len() > capacity {
        report.issues.push(AdmissionIssue {
            path: roots[capacity].clone(),
            kind: AdmissionIssueKind::LimitReached,
        });
        roots.truncate(capacity);
    }
    roots.sort_by(|left, right| compare_paths(left, right));
    let mut stack = VecDeque::new();
    for root in roots.into_iter().rev() {
        stack.push_back((root, 0_usize));
    }
    let mut seen_directories = BTreeSet::new();
    let mut inspected = 0_usize;

    while let Some((path, depth)) = stack.pop_back() {
        if inspected >= capacity {
            report.issues.push(AdmissionIssue {
                path,
                kind: AdmissionIssueKind::LimitReached,
            });
            break;
        }
        inspected += 1;
        if !path.is_absolute() {
            report.issues.push(AdmissionIssue {
                path,
                kind: AdmissionIssueKind::RelativePath,
            });
            continue;
        }
        if adapter.validate_path(&path).is_err() {
            report.issues.push(AdmissionIssue {
                path,
                kind: AdmissionIssueKind::Metadata,
            });
            continue;
        }
        let metadata = match adapter.metadata(&path) {
            Ok(metadata) => metadata,
            Err(_error) => {
                report.issues.push(AdmissionIssue {
                    path,
                    kind: AdmissionIssueKind::Metadata,
                });
                continue;
            }
        };
        if metadata.is_reparse_point {
            report.issues.push(AdmissionIssue {
                path,
                kind: AdmissionIssueKind::ReparsePoint,
            });
            continue;
        }
        if metadata.is_directory {
            if let Some(identity) = metadata.directory_identity
                && !seen_directories.insert(identity)
            {
                report.issues.push(AdmissionIssue {
                    path,
                    kind: AdmissionIssueKind::RepeatedDirectory,
                });
                continue;
            }
            if mode == AdmissionMode::Recurse {
                if depth >= MAX_ADMISSION_DEPTH {
                    report.issues.push(AdmissionIssue {
                        path,
                        kind: AdmissionIssueKind::DepthExceeded,
                    });
                    continue;
                }
                let remaining = capacity
                    .saturating_sub(inspected)
                    .saturating_sub(stack.len());
                if remaining == 0 {
                    report.issues.push(AdmissionIssue {
                        path,
                        kind: AdmissionIssueKind::LimitReached,
                    });
                    break;
                }
                match adapter.read_children(&path, remaining) {
                    Ok(mut children) => {
                        children
                            .paths
                            .sort_by(|left, right| compare_paths(left, right));
                        for child in children.paths.into_iter().rev() {
                            stack.push_back((child, depth + 1));
                        }
                        if children.had_errors {
                            report.issues.push(AdmissionIssue {
                                path: path.clone(),
                                kind: AdmissionIssueKind::ReadDirectory,
                            });
                        }
                        if children.truncated {
                            report.issues.push(AdmissionIssue {
                                path,
                                kind: AdmissionIssueKind::LimitReached,
                            });
                        }
                    }
                    Err(_error) => report.issues.push(AdmissionIssue {
                        path,
                        kind: AdmissionIssueKind::ReadDirectory,
                    }),
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
    report
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
        NativeParent, file_identity, open_directory_entry, open_entry, query_directory_names,
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
            let parent = path.parent().ok_or(AdmissionAdapterError)?.to_path_buf();
            let leaf = path
                .file_name()
                .ok_or(AdmissionAdapterError)?
                .encode_wide()
                .collect::<Vec<_>>();
            if validate_windows_leaf_name(&LegacyText::from_units(leaf.clone())).is_err() {
                return Err(AdmissionAdapterError);
            }
            Ok((parent, leaf))
        }
    }

    impl AdmissionAdapter for WindowsAdmissionAdapter {
        fn validate_path(&self, path: &Path) -> Result<(), AdmissionAdapterError> {
            let (parent, _leaf) = Self::parent_and_leaf(path)?;
            if !self.parents.borrow().contains_key(&parent) {
                let handle = NativeParent::open_path(&parent).map_err(|_| AdmissionAdapterError)?;
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
            let parent = parents.get(&parent_path).ok_or(AdmissionAdapterError)?;
            let file = open_entry(parent, &leaf, false).map_err(|_| AdmissionAdapterError)?;
            let metadata = file.metadata().map_err(|_| AdmissionAdapterError)?;
            let attributes = metadata.file_attributes();
            let is_directory = attributes & 0x10 != 0;
            let is_reparse_point = attributes & 0x400 != 0;
            let directory_identity = if is_directory && !is_reparse_point {
                let identity = file_identity(&file).map_err(|_| AdmissionAdapterError)?;
                let directory =
                    open_directory_entry(parent, &leaf).map_err(|_| AdmissionAdapterError)?;
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
            let directory = directories.get(path).ok_or(AdmissionAdapterError)?;
            let (names, truncated) =
                query_directory_names(directory, limit).map_err(|_| AdmissionAdapterError)?;
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

        fn legacy_path(&self, path: &Path) -> LegacyText {
            LegacyText::from_units(path.as_os_str().encode_wide().collect::<Vec<_>>())
        }
    }
}

#[cfg(windows)]
pub use windows::WindowsAdmissionAdapter;
