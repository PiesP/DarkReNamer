//! Safe, preview-first rename planning and execution.

mod executor;
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
mod windows_native;

pub use executor::{
    EntryExecution, ExecuteError, ExecuteErrorKind, ExecutionFailure, ExecutionOutcome,
    ExecutionReport, RenameExecutor, RenameState, RollbackFailure,
};
pub use file_journal::{
    FileJournal, FileJournalError, FileJournalErrorKind, JournalCodecError, JournalCodecErrorKind,
    JournalInspection, JournalRoot, JournalTailIssue, MAX_JOURNAL_FILE_BYTES,
    MAX_JOURNAL_FRAME_BYTES, MAX_JOURNAL_FRAMES, MAX_JOURNAL_STEPS, MAX_PATH_UNITS,
    decode_journal_records, encode_journal_records, inspect_journal_records,
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
    AuthorizedJournal, BackendError, BackendOperation, JournalAuthorization, JournalError,
    JournalSnapshot, JournalStore, MutationCertainty, RenameBackend, RenameOperation,
};
pub use recovery::{RecoveryBlockKind, RecoveryFailure, RecoveryOutcome, RenameRecovery};
pub use schedule::{MAX_TEMP_CANDIDATES, TemporaryPhase};
#[cfg(windows)]
pub use windows_backend::WindowsRenameBackend;
