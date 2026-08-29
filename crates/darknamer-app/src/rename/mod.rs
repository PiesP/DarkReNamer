//! Safe, preview-first rename planning and execution.

mod activation;
mod executor;
#[cfg(test)]
pub(crate) mod failpoint;
mod file_journal;
mod journal;
mod memory;
mod model;
mod planner;
mod ports;
mod recovery;
mod schedule;
#[cfg(windows)]
mod windows_backend;
#[cfg(windows)]
pub(crate) mod windows_native;

pub use activation::{
    JournalCleanupDecision, apply_execution_report, build_plan_request, cleanup_decision,
    execute_error_korean, execution_outcome_korean, journal_capacity_error_korean,
    next_model_revision, plan_error_korean, safe_mode_unify_path_message,
};
pub use executor::{
    CancellationToken, EntryExecution, ExecuteError, ExecuteErrorKind, ExecutionControl,
    ExecutionFailure, ExecutionOutcome, ExecutionPhase, ExecutionProgress, ExecutionReport,
    RenameExecutor, RenameState, RollbackFailure, preflight_plan,
};
pub use file_journal::{
    ExistingJournalOpenError, FileJournal, FileJournalError, FileJournalErrorKind,
    JournalCapacityError, JournalCapacityKind, JournalCodecError, JournalCodecErrorKind,
    JournalInspection, JournalOpenFailure, JournalOpenStage, JournalRequirements, JournalRoot,
    JournalTailIssue, MAX_JOURNAL_FILE_BYTES, MAX_JOURNAL_FRAME_BYTES, MAX_JOURNAL_FRAMES,
    MAX_JOURNAL_STEPS, MAX_PATH_UNITS, RecoveryJournalEvidence, decode_journal_records,
    encode_journal_records, inspect_journal_records,
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
pub use planner::{MAX_PLAN_PATH_DEPTH, RenamePlanner};
pub use ports::{
    AppendCertainty, AuthorizedJournal, BackendError, BackendOperation, JournalAuthorization,
    JournalError, JournalSnapshot, JournalStore, MutationCertainty, RenameBackend, RenameOperation,
};
pub use recovery::{RecoveryBlockKind, RecoveryFailure, RecoveryOutcome, RenameRecovery};
pub use schedule::{MAX_TEMP_CANDIDATES, TemporaryPhase};
#[cfg(windows)]
pub use windows_backend::WindowsRenameBackend;
#[cfg(windows)]
pub(crate) use windows_native::process_is_elevated;
