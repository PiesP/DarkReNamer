//! Safe, preview-first rename planning and execution.

mod memory;
mod model;
mod planner;
mod ports;

pub use memory::MemoryBackend;
pub use model::{
    EntryId, EntryIdentity, EntryKind, ModelRevision, PathKey, PathSnapshot, PlanError, PlanId,
    PlanIssue, PlanIssueKind, PlanRequest, RenameIntent, RenamePlan,
};
pub use planner::RenamePlanner;
pub use ports::{BackendError, BackendOperation, RenameBackend};
