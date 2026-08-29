//! Safe, preview-first rename planning and execution.

mod executor;
mod journal;
mod memory;
mod model;
mod planner;
mod ports;
mod schedule;

pub use executor::{
    ExecuteError, ExecuteErrorKind, ExecutionFailure, ExecutionOutcome, ExecutionReport,
    RenameExecutor, RollbackFailure,
};
pub use journal::{JournalDirection, JournalRecord, JournalTerminal, MemoryJournal, RecoveryState};
pub use memory::MemoryBackend;
pub use model::{
    ConfirmationError, ConfirmedPlan, EntryId, EntryIdentity, EntryKind, ModelRevision, PathKey,
    PathSnapshot, PlanError, PlanId, PlanIssue, PlanIssueKind, PlanRequest, RenameIntent,
    RenamePlan,
};
pub use planner::RenamePlanner;
pub use ports::{BackendError, BackendOperation, JournalError, JournalStore, RenameBackend};
