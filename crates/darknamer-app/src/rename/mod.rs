//! Safe, preview-first rename planning and execution.

mod executor;
mod journal;
mod memory;
mod model;
mod planner;
mod ports;
mod schedule;

pub use executor::{
    EntryExecution, ExecuteError, ExecuteErrorKind, ExecutionFailure, ExecutionOutcome,
    ExecutionReport, RenameExecutor, RenameState, RollbackFailure,
};
pub use journal::{
    JournalCorruption, JournalDirection, JournalRecord, JournalStep, JournalTerminal,
    MemoryJournal, RecoveryReason, RecoveryState, replay_journal,
};
pub use memory::MemoryBackend;
pub use model::{
    ConfirmationError, ConfirmedPlan, EntryId, EntryIdentity, EntryKind, ModelRevision, PathKey,
    PathSnapshot, PlanError, PlanId, PlanIssue, PlanIssueKind, PlanRequest, PlanRow, RenameIntent,
    RenamePlan,
};
pub use planner::RenamePlanner;
pub use ports::{
    BackendError, BackendOperation, JournalError, JournalStore, MutationCertainty, RenameBackend,
    RenameOperation,
};
pub use schedule::{MAX_TEMP_CANDIDATES, TemporaryPhase};
