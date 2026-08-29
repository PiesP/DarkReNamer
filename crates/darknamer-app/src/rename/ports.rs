use std::fmt;

use darknamer_core::LegacyText;

use super::{EntryIdentity, PathKey, PathSnapshot};
use super::{JournalDirection, JournalTerminal, PlanId};

/// Backend operation associated with a structured error.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BackendOperation {
    /// Inspect a path and its parent.
    Observe,
    /// Rename one entry without replacing another.
    Rename,
    /// Allocate a fresh transaction nonce.
    TransactionNonce,
}

/// Whether a failed mutation definitely left the filesystem unchanged.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MutationCertainty {
    /// The adapter guarantees that the primitive move did not occur.
    NotApplied,
    /// The adapter cannot prove whether the primitive move occurred.
    MayHaveApplied,
}

/// A backend failure retaining its operation and native-style error code.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BackendError {
    /// Failed operation.
    pub operation: BackendOperation,
    /// Adapter-owned numeric error code.
    pub code: u32,
    /// Filesystem mutation certainty associated with the failure.
    pub certainty: MutationCertainty,
}

impl fmt::Display for BackendError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "rename backend {:?} failed with code {}",
            self.operation, self.code
        )
    }
}

impl std::error::Error for BackendError {}

/// One identity-bound, no-replace primitive rename.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenameOperation {
    source: LegacyText,
    destination: LegacyText,
    expected_source: EntryIdentity,
    expected_source_parent: EntryIdentity,
    expected_destination_parent: EntryIdentity,
}

impl RenameOperation {
    /// Creates a primitive operation with all identities frozen before mutation.
    #[must_use]
    pub fn new(
        source: LegacyText,
        destination: LegacyText,
        expected_source: EntryIdentity,
        expected_source_parent: EntryIdentity,
        expected_destination_parent: EntryIdentity,
    ) -> Self {
        Self {
            source,
            destination,
            expected_source,
            expected_source_parent,
            expected_destination_parent,
        }
    }

    /// Returns the exact source path.
    #[must_use]
    pub const fn source(&self) -> &LegacyText {
        &self.source
    }

    /// Returns the exact destination path.
    #[must_use]
    pub const fn destination(&self) -> &LegacyText {
        &self.destination
    }

    /// Returns the expected source identity.
    #[must_use]
    pub const fn expected_source(&self) -> EntryIdentity {
        self.expected_source
    }

    /// Returns the expected resolved source-parent identity.
    #[must_use]
    pub const fn expected_source_parent(&self) -> EntryIdentity {
        self.expected_source_parent
    }

    /// Returns the expected resolved destination-parent identity.
    #[must_use]
    pub const fn expected_destination_parent(&self) -> EntryIdentity {
        self.expected_destination_parent
    }
}

/// Filesystem adapter used by planning and execution.
pub trait RenameBackend {
    /// Builds the filesystem's comparison key for a complete path.
    fn path_key(&self, path: &LegacyText) -> PathKey;

    /// Observes the exact leaf and resolved direct parent.
    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError>;

    /// Returns a transaction nonce suitable for bounded temporary-name derivation.
    fn next_transaction_nonce(&mut self) -> Result<u128, BackendError>;

    /// Atomically moves the expected source without replacing a destination.
    ///
    /// `Err(NotApplied)` guarantees no mutation. `Err(MayHaveApplied)` requires
    /// reconciliation and must never be followed by speculative rollback.
    fn rename_no_replace(&mut self, operation: &RenameOperation) -> Result<(), BackendError>;
}

/// Durable journal adapter failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct JournalError {
    /// Adapter-owned numeric error code.
    pub code: u32,
}

/// Write-ahead journal used to make interrupted execution recoverable.
pub trait JournalStore {
    /// Begins one immutable transaction before filesystem mutation.
    fn begin(&mut self, plan: PlanId, step_count: usize) -> Result<(), JournalError>;

    /// Durably records that one move is about to be attempted.
    fn prepared(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError>;

    /// Durably records that one move completed.
    fn completed(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError>;

    /// Durably records a verified terminal state.
    fn terminal(&mut self, terminal: JournalTerminal) -> Result<(), JournalError>;
}
