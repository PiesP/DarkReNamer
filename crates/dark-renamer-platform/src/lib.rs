//! Filesystem admission and journaled transaction execution.
//!
//! [`RenameEngine`] owns path authority. The planning core is used only to
//! produce a preview; execution always uses the engine's frozen admission and
//! revalidates it before creating a durable transaction journal.

#![forbid(unsafe_code)]

mod engine;
mod filesystem;
mod journal;

use std::error::Error as StdError;
use std::fmt;
use std::path::{Path, PathBuf};

pub use engine::RenameEngine;

/// Maximum number of files admitted in one batch.
pub const MAX_SOURCES: usize = 256;

/// Opaque identity assigned to an admitted source by the engine.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct SourceId(u64);

/// Opaque identity assigned to the current preview by the engine.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct PlanId(u64);

/// Opaque identity assigned to a durable transaction by the engine.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct TransactionId(u64);

/// Opaque admission generation used to invalidate stale previews.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct Generation(u64);

/// A preview paired with the engine-owned authority needed for later apply.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Preview {
    id: PlanId,
    generation: Generation,
    source_ids: Box<[SourceId]>,
    plan: dark_renamer_core::RenamePlan,
}

impl Preview {
    /// Returns the opaque plan identity required by confirmed apply.
    #[must_use]
    pub const fn id(&self) -> PlanId {
        self.id
    }

    /// Returns the admission generation represented by this preview.
    #[must_use]
    pub const fn generation(&self) -> Generation {
        self.generation
    }

    /// Returns opaque source identities in deterministic planning order.
    #[must_use]
    pub fn source_ids(&self) -> &[SourceId] {
        &self.source_ids
    }

    /// Returns the read-only portable planning result.
    #[must_use]
    pub const fn plan(&self) -> &dark_renamer_core::RenamePlan {
        &self.plan
    }
}

/// Whether a completed transaction applied a preview or undid an apply.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum TransactionKind {
    /// A confirmed preview was applied.
    Apply,
    /// The latest eligible apply was reversed.
    Undo,
}

/// Path-free summary of the latest completed transaction.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TransactionSummary {
    id: TransactionId,
    kind: TransactionKind,
    changed_count: usize,
}

impl TransactionSummary {
    /// Returns the transaction identity.
    #[must_use]
    pub const fn id(self) -> TransactionId {
        self.id
    }

    /// Returns whether this was an apply or undo transaction.
    #[must_use]
    pub const fn kind(self) -> TransactionKind {
        self.kind
    }

    /// Returns the number of files moved to final names.
    #[must_use]
    pub const fn changed_count(self) -> usize {
        self.changed_count
    }
}

/// Why an admission request was rejected.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum AdmissionRejection {
    /// The path is a symbolic link.
    SymbolicLink,
    /// The path does not identify a regular file.
    NotRegularFile,
    /// The source has no parent directory.
    MissingParent,
    /// The parent is not a real directory.
    InvalidParent,
    /// The path cannot be represented without lossy conversion.
    NonUnicodePath,
    /// The same filesystem object was admitted more than once.
    DuplicateIdentity,
}

/// A structured platform failure.
#[derive(Debug)]
#[non_exhaustive]
pub enum PlatformError {
    /// A filesystem operation is not supported by this adapter or target.
    Unsupported {
        /// Operation that is unavailable.
        operation: &'static str,
    },
    /// A source was not eligible for regular-file admission.
    AdmissionRejected {
        /// Rejected path.
        path: PathBuf,
        /// Structured reason.
        reason: AdmissionRejection,
    },
    /// A configured bound was exceeded.
    BoundExceeded {
        /// Bounded field.
        field: &'static str,
        /// Maximum accepted value.
        maximum: usize,
    },
    /// No files have been admitted.
    NoSources,
    /// The requested plan is not the current engine-owned preview.
    StalePlan,
    /// The preview contains a blocking diagnostic or no changes.
    PlanNotApplicable,
    /// The caller's exact-count confirmation did not match the frozen plan.
    ConfirmationMismatch {
        /// Exact changed count frozen into the plan.
        expected: usize,
        /// Count supplied by the caller.
        actual: usize,
    },
    /// A source changed since admission.
    StaleSource {
        /// Opaque source identity.
        source_id: SourceId,
    },
    /// A source parent changed since admission.
    StaleParent {
        /// Opaque source identity.
        source_id: SourceId,
    },
    /// A frozen destination occupancy observation changed.
    DestinationChanged {
        /// Destination that no longer matches the preview snapshot.
        path: PathBuf,
    },
    /// An incomplete or corrupt journal requires explicit recovery.
    RecoveryRequired,
    /// There is no completed transaction to inspect or undo.
    NoCompletedTransaction,
    /// The latest completed transaction cannot be undone.
    LatestTransactionNotUndoable,
    /// A definite move failure occurred; completed moves were rolled back when possible.
    ExecutionFailed {
        /// Whether every completed move was rolled back durably.
        rolled_back: bool,
        /// Stable operation description.
        operation: &'static str,
    },
    /// A journal was malformed or exceeded a persisted-data bound.
    CorruptJournal {
        /// Journal path, retained for operator diagnostics.
        path: PathBuf,
    },
    /// An operating-system I/O operation failed.
    Io {
        /// Operation being performed.
        operation: &'static str,
        /// Original I/O error.
        source: std::io::Error,
    },
}

impl fmt::Display for PlatformError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported { operation } => {
                write!(formatter, "unsupported operation: {operation}")
            }
            Self::AdmissionRejected { path, reason } => {
                write!(
                    formatter,
                    "source admission rejected for {}: {reason:?}",
                    path.display()
                )
            }
            Self::BoundExceeded { field, maximum } => {
                write!(formatter, "{field} exceeds the maximum of {maximum}")
            }
            Self::NoSources => formatter.write_str("no sources are admitted"),
            Self::StalePlan => formatter.write_str("the preview is stale"),
            Self::PlanNotApplicable => formatter.write_str("the preview cannot be applied"),
            Self::ConfirmationMismatch { expected, actual } => {
                write!(
                    formatter,
                    "confirmation mismatch: expected {expected}, received {actual}"
                )
            }
            Self::StaleSource { source_id } => write!(formatter, "source {source_id:?} changed"),
            Self::StaleParent { source_id } => {
                write!(formatter, "parent of source {source_id:?} changed")
            }
            Self::DestinationChanged { path } => {
                write!(
                    formatter,
                    "destination observation changed: {}",
                    path.display()
                )
            }
            Self::RecoveryRequired => formatter.write_str("transaction recovery is required"),
            Self::NoCompletedTransaction => formatter.write_str("no completed transaction exists"),
            Self::LatestTransactionNotUndoable => {
                formatter.write_str("the latest transaction is not undoable")
            }
            Self::ExecutionFailed {
                rolled_back,
                operation,
            } => write!(
                formatter,
                "{operation} failed (completed moves rolled back: {rolled_back})"
            ),
            Self::CorruptJournal { path } => {
                write!(formatter, "journal is corrupt: {}", path.display())
            }
            Self::Io { operation, source } => write!(formatter, "{operation}: {source}"),
        }
    }
}

impl StdError for PlatformError {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

fn io_error(operation: &'static str, source: std::io::Error) -> PlatformError {
    PlatformError::Io { operation, source }
}

fn validate_persisted_path(path: &Path) -> Result<(), PlatformError> {
    const MAX_PATH_BYTES: usize = 4_096;
    let value = path
        .to_str()
        .ok_or_else(|| PlatformError::AdmissionRejected {
            path: path.to_path_buf(),
            reason: AdmissionRejection::NonUnicodePath,
        })?;
    if value.len() > MAX_PATH_BYTES {
        return Err(PlatformError::BoundExceeded {
            field: "path",
            maximum: MAX_PATH_BYTES,
        });
    }
    Ok(())
}

/// Returns the linked planning-core version.
#[must_use]
pub const fn core_version() -> &'static str {
    dark_renamer_core::version()
}
