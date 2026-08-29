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
}

/// A backend failure retaining its operation and native-style error code.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BackendError {
    /// Failed operation.
    pub operation: BackendOperation,
    /// Adapter-owned numeric error code.
    pub code: u32,
}

/// Filesystem adapter used by planning and execution.
pub trait RenameBackend {
    /// Builds the filesystem's comparison key for a complete path.
    fn path_key(&self, path: &LegacyText) -> PathKey;

    /// Observes the exact leaf and resolved direct parent.
    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError>;

    /// Atomically moves the expected source without replacing a destination.
    fn rename_no_replace(
        &mut self,
        source: &LegacyText,
        destination: &LegacyText,
        expected_source: EntryIdentity,
    ) -> Result<(), BackendError>;
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
