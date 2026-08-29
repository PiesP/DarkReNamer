//! Bounded iterative source admission without UI concerns.

use std::cmp::Ordering;
use std::collections::{BTreeSet, VecDeque};
use std::path::{Path, PathBuf};

use darknamer_core::{LegacyListItem, LegacyText};

use crate::rename::EntryIdentity;

/// Hard limit applied before inspecting further candidate metadata.
pub const MAX_ADMITTED_SOURCES: usize = 10_000;

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
    /// Deterministic bounded children.
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
            "{}개 추가, {}개 제외/중단 (상대경로 {}, 메타데이터 {}, 폴더읽기 {}, 재분석지점 {}, 한도 {}, 반복폴더 {})",
            appended,
            self.issues.len(),
            count(AdmissionIssueKind::RelativePath),
            count(AdmissionIssueKind::Metadata),
            count(AdmissionIssueKind::ReadDirectory),
            count(AdmissionIssueKind::ReparsePoint),
            count(AdmissionIssueKind::LimitReached),
            count(AdmissionIssueKind::RepeatedDirectory),
        )
    }
}

/// Collects bounded sources iteratively in deterministic depth-first order.
pub fn collect_admission(
    adapter: &dyn AdmissionAdapter,
    mut roots: Vec<PathBuf>,
    mode: AdmissionMode,
    compare_paths: impl Fn(&Path, &Path) -> Ordering + Copy,
) -> AdmissionReport {
    roots.sort_by(|left, right| compare_paths(left, right));
    let mut report = AdmissionReport::default();
    if roots.len() > MAX_ADMITTED_SOURCES {
        report.issues.push(AdmissionIssue {
            path: roots[MAX_ADMITTED_SOURCES].clone(),
            kind: AdmissionIssueKind::LimitReached,
        });
        roots.truncate(MAX_ADMITTED_SOURCES);
    }
    let mut stack = VecDeque::new();
    for root in roots.into_iter().rev() {
        stack.push_back(root);
    }
    let mut seen_directories = BTreeSet::new();

    while let Some(path) = stack.pop_back() {
        if report.items.len() >= MAX_ADMITTED_SOURCES {
            report.issues.push(AdmissionIssue {
                path,
                kind: AdmissionIssueKind::LimitReached,
            });
            break;
        }
        if !path.is_absolute() {
            report.issues.push(AdmissionIssue {
                path,
                kind: AdmissionIssueKind::RelativePath,
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
                let remaining = MAX_ADMITTED_SOURCES
                    .saturating_sub(report.items.len())
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
                            stack.push_back(child);
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
        report.items.push(LegacyListItem::new(
            adapter.legacy_path(&path),
            metadata.is_directory,
            metadata.actual_size as u32,
            metadata.created,
            metadata.modified,
        ));
    }
    report
}

#[cfg(windows)]
mod windows {
    use std::collections::BTreeSet;
    use std::fs;
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::fs::MetadataExt;

    use crate::rename::{RenameBackend, WindowsRenameBackend};

    use super::*;

    /// Safe Windows adapter used by picker, drop, and path import.
    #[derive(Debug, Default)]
    pub struct WindowsAdmissionAdapter;

    impl AdmissionAdapter for WindowsAdmissionAdapter {
        fn metadata(&self, path: &Path) -> Result<AdmissionMetadata, AdmissionAdapterError> {
            let metadata = fs::symlink_metadata(path).map_err(|_| AdmissionAdapterError)?;
            let attributes = metadata.file_attributes();
            let is_directory = attributes & 0x10 != 0;
            let is_reparse_point = attributes & 0x400 != 0;
            let directory_identity = if is_directory && !is_reparse_point {
                WindowsRenameBackend
                    .observe(&self.legacy_path(path))
                    .map_err(|_| AdmissionAdapterError)?
                    .entry
                    .map(|entry| entry.identity)
            } else {
                None
            };
            Ok(AdmissionMetadata {
                is_directory,
                is_reparse_point,
                directory_identity,
                actual_size: metadata.file_size(),
                created: metadata.creation_time(),
                modified: metadata.last_write_time(),
            })
        }

        fn read_children(
            &self,
            path: &Path,
            limit: usize,
        ) -> Result<AdmissionChildren, AdmissionAdapterError> {
            let entries = fs::read_dir(path).map_err(|_| AdmissionAdapterError)?;
            let mut bounded = BTreeSet::new();
            let mut had_errors = false;
            let mut truncated = false;
            for entry in entries {
                match entry {
                    Ok(entry) => {
                        bounded.insert(entry.path());
                        if bounded.len() > limit {
                            bounded.pop_last();
                            truncated = true;
                        }
                    }
                    Err(_error) => had_errors = true,
                }
            }
            Ok(AdmissionChildren {
                paths: bounded.into_iter().collect(),
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
