//! Audited, handle-bound Windows rename primitives.

#[cfg(windows)]
mod implementation;

#[cfg(windows)]
pub use implementation::{
    EntryHandle, FileIdentity, ParentHandle, file_identity, rename_noreplace,
};
