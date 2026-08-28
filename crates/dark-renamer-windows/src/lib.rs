//! Audited, handle-bound Windows rename primitives.

#[cfg(windows)]
mod implementation;

#[cfg(windows)]
pub use implementation::{
    EntryHandle, FileIdentity, JournalAccess, ParentHandle, file_identity, open_journal_file,
    rename_noreplace,
};
