use std::fmt;

use darknamer_core::LegacyText;

use super::{EntryIdentity, PathKey, PathSnapshot};
use super::{JournalDirection, JournalStep, JournalTerminal, PlanId};

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
    /// Validates parent filesystem semantics before any comparison-key folding.
    fn validate_path_environment(&self, path: &LegacyText) -> Result<(), BackendError>;

    /// Builds the filesystem's comparison key for a validated complete path.
    fn path_key(&self, path: &LegacyText) -> PathKey;

    /// Observes the exact leaf and resolved direct parent.
    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError>;

    /// Returns whether `candidate` is the same entry path as `ancestor` or is
    /// nested below it according to backend-owned path comparison semantics.
    fn is_same_or_descendant(
        &self,
        ancestor: &LegacyText,
        candidate: &LegacyText,
    ) -> Result<bool, BackendError>;

    /// Returns a fresh, nonzero transaction nonce for temporary-name derivation.
    ///
    /// An adapter must not reuse a nonce while the corresponding transaction may
    /// still require recovery. The executor also observes every derived endpoint.
    fn next_transaction_nonce(&mut self) -> Result<u128, BackendError>;

    /// Atomically moves the expected source without replacing a destination.
    ///
    /// `Err(NotApplied)` guarantees no mutation. `Err(MayHaveApplied)` requires
    /// reconciliation and must never be followed by speculative rollback.
    fn rename_no_replace(&mut self, operation: &RenameOperation) -> Result<(), BackendError>;
}

/// Durable journal adapter failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AppendCertainty {
    /// The adapter guarantees that the attempted record was not appended.
    NotAppended,
    /// The adapter cannot prove whether some or all of the record was appended.
    MayHaveAppended,
}

/// Durable journal adapter failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct JournalError {
    /// Adapter-owned numeric error code.
    pub code: u32,
    /// Journal append certainty associated with the failure.
    pub certainty: AppendCertainty,
}

impl JournalError {
    /// Creates an error that guarantees the attempted record was not appended.
    #[must_use]
    pub const fn not_appended(code: u32) -> Self {
        Self {
            code,
            certainty: AppendCertainty::NotAppended,
        }
    }

    /// Creates an error for an append whose durable result is uncertain.
    #[must_use]
    pub const fn may_have_appended(code: u32) -> Self {
        Self {
            code,
            certainty: AppendCertainty::MayHaveAppended,
        }
    }
}

impl fmt::Display for JournalError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "journal operation failed with code {} ({:?})",
            self.code, self.certainty
        )
    }
}

impl std::error::Error for JournalError {}

/// Opaque retained authorization for one exact journal identity and generation.
#[derive(Debug)]
pub struct JournalAuthorization {
    pub(super) identity: u64,
    pub(super) generation: u64,
}

/// Immutable records loaded through a retained exclusive journal capability.
#[derive(Debug)]
pub struct JournalSnapshot {
    pub(super) records: Box<[super::JournalRecord]>,
    pub(super) authorization: JournalAuthorization,
}

impl JournalSnapshot {
    /// Returns the immutable authorized record snapshot.
    #[must_use]
    pub fn records(&self) -> &[super::JournalRecord] {
        &self.records
    }

    pub(super) fn into_parts(self) -> (Box<[super::JournalRecord]>, JournalAuthorization) {
        (self.records, self.authorization)
    }
}

/// Write-ahead journal used to make interrupted execution recoverable.
pub trait JournalStore {
    /// Begins one immutable transaction before filesystem mutation.
    fn begin(&mut self, plan: PlanId, steps: &[JournalStep]) -> Result<(), JournalError>;

    /// Durably records that one move is about to be attempted.
    fn prepared(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError>;

    /// Durably records that one move completed.
    fn completed(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError>;

    /// Durably records that a prepared move definitely did not mutate.
    fn not_applied(&mut self, step: usize, direction: JournalDirection)
    -> Result<(), JournalError>;

    /// Durably records a verified terminal state.
    fn terminal(&mut self, terminal: JournalTerminal) -> Result<(), JournalError>;
}

/// Journal capability retained exclusively from snapshot through recovery writes.
///
/// Implementations must identity-check the same opened journal and reject any
/// generation drift on every authorized append. Recovery must not combine a
/// snapshot from one journal with mutation authority from another.
pub trait AuthorizedJournal {
    /// Loads records and an opaque authorization from the retained capability.
    fn authorized_snapshot(&mut self) -> Result<JournalSnapshot, JournalError>;

    /// Appends a prepared transition only if authorization is still current.
    fn authorized_prepared(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError>;

    /// Appends a completed transition only if authorization is still current.
    fn authorized_completed(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError>;

    /// Appends a no-mutation transition only if authorization is still current.
    fn authorized_not_applied(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError>;

    /// Appends terminal state only if authorization is still current.
    fn authorized_terminal(
        &mut self,
        authorization: &mut JournalAuthorization,
        terminal: JournalTerminal,
    ) -> Result<(), JournalError>;
}
