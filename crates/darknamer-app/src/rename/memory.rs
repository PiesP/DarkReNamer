use std::collections::BTreeMap;

use darknamer_core::LegacyText;

use super::model::ObservedEntry;
use super::{
    BackendError, BackendOperation, EntryIdentity, EntryKind, MutationCertainty, PathKey,
    PathSnapshot, RenameBackend, RenameOperation,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct MemoryEntry {
    identity: EntryIdentity,
    kind: EntryKind,
    is_reparse_point: bool,
}

/// Deterministic in-memory filesystem adapter for planner and executor tests.
#[derive(Clone, Debug, Default)]
pub struct MemoryBackend {
    entries: BTreeMap<PathKey, MemoryEntry>,
    parent_identities: BTreeMap<PathKey, EntryIdentity>,
    failures: BTreeMap<usize, (u32, MutationCertainty)>,
    move_attempts: usize,
    completed_moves: Vec<(String, String)>,
    next_transaction_nonce: u128,
}

impl MemoryBackend {
    /// Creates an empty adapter.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
            parent_identities: BTreeMap::new(),
            failures: BTreeMap::new(),
            move_attempts: 0,
            completed_moves: Vec::new(),
            next_transaction_nonce: 1,
        }
    }

    /// Adds one regular file on the default test volume.
    #[must_use]
    pub fn with_file(mut self, path: impl Into<LegacyText>, file_id: u128) -> Self {
        let path = path.into();
        let key = self.path_key(&path);
        self.entries.insert(
            key,
            MemoryEntry {
                identity: EntryIdentity::new(1, file_id),
                kind: EntryKind::File,
                is_reparse_point: false,
            },
        );
        self
    }

    /// Inserts or replaces a regular file after planning.
    pub fn insert_file(&mut self, path: impl Into<LegacyText>, file_id: u128) {
        let path = path.into();
        let key = self.path_key(&path);
        self.entries.insert(
            key,
            MemoryEntry {
                identity: EntryIdentity::new(1, file_id),
                kind: EntryKind::File,
                is_reparse_point: false,
            },
        );
    }

    /// Replaces the identity at an existing path.
    pub fn replace_file_id(&mut self, path: impl Into<LegacyText>, file_id: u128) {
        let path = path.into();
        let key = self.path_key(&path);
        if let Some(entry) = self.entries.get_mut(&key) {
            entry.identity = EntryIdentity::new(entry.identity.volume(), file_id);
        }
    }

    /// Overrides the resolved direct-parent identity for one child path.
    pub fn replace_parent_id(&mut self, child_path: impl Into<LegacyText>, file_id: u128) {
        let child_path = child_path.into();
        let parent = LegacyText::from_units(parent_units(child_path.units()).to_vec());
        self.parent_identities
            .insert(self.path_key(&parent), EntryIdentity::new(1, file_id));
    }

    /// Injects one backend failure by one-based move-attempt number.
    pub fn fail_move_on(&mut self, attempt: usize, code: u32) {
        self.failures
            .insert(attempt, (code, MutationCertainty::NotApplied));
    }

    /// Injects an error after the selected primitive move has mutated state.
    pub fn fail_ambiguous_move_on(&mut self, attempt: usize, code: u32) {
        self.failures
            .insert(attempt, (code, MutationCertainty::MayHaveApplied));
    }

    /// Sets the next deterministic transaction nonce used by tests.
    pub const fn set_next_transaction_nonce(&mut self, nonce: u128) {
        self.next_transaction_nonce = nonce;
    }

    /// Returns the file identifier currently occupying a path.
    #[must_use]
    pub fn file_id(&self, path: impl Into<LegacyText>) -> Option<u128> {
        let path = path.into();
        self.entries
            .get(&self.path_key(&path))
            .map(|entry| entry.identity.file_id())
    }

    /// Returns successful primitive moves in execution order.
    #[must_use]
    pub fn completed_moves(&self) -> &[(String, String)] {
        &self.completed_moves
    }

    /// Returns the number of successful filesystem mutations.
    #[must_use]
    pub const fn mutation_count(&self) -> usize {
        self.completed_moves.len()
    }

    fn parent_identity(&self, path: &LegacyText) -> EntryIdentity {
        let parent = LegacyText::from_units(parent_units(path.units()).to_vec());
        if let Some(identity) = self.parent_identities.get(&self.path_key(&parent)) {
            return *identity;
        }
        let mut hash = 0xcbf2_9ce4_8422_2325_u64;
        for unit in parent.units() {
            hash ^= u64::from(ascii_lower(*unit));
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        EntryIdentity::new(1, u128::from(hash))
    }
}

impl RenameBackend for MemoryBackend {
    fn path_key(&self, path: &LegacyText) -> PathKey {
        PathKey(
            path.units()
                .iter()
                .map(|unit| ascii_lower(*unit))
                .collect::<Vec<_>>()
                .into_boxed_slice(),
        )
    }

    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError> {
        let entry = self
            .entries
            .get(&self.path_key(path))
            .map(|entry| ObservedEntry {
                identity: entry.identity,
                kind: entry.kind,
                is_reparse_point: entry.is_reparse_point,
            });
        Ok(PathSnapshot {
            parent: self.parent_identity(path),
            entry,
        })
    }

    fn next_transaction_nonce(&mut self) -> Result<u128, BackendError> {
        let nonce = self.next_transaction_nonce;
        let Some(next) = nonce.checked_add(1) else {
            return Err(backend_error(
                BackendOperation::TransactionNonce,
                534,
                MutationCertainty::NotApplied,
            ));
        };
        self.next_transaction_nonce = next;
        Ok(nonce)
    }

    fn rename_no_replace(&mut self, operation: &RenameOperation) -> Result<(), BackendError> {
        self.move_attempts += 1;
        let injected = self.failures.get(&self.move_attempts).copied();
        if let Some((code, MutationCertainty::NotApplied)) = injected {
            return Err(backend_error(
                BackendOperation::Rename,
                code,
                MutationCertainty::NotApplied,
            ));
        }
        if self.parent_identity(operation.source()) != operation.expected_source_parent()
            || self.parent_identity(operation.destination())
                != operation.expected_destination_parent()
        {
            return Err(backend_error(
                BackendOperation::Rename,
                1168,
                MutationCertainty::NotApplied,
            ));
        }
        let source_key = self.path_key(operation.source());
        let destination_key = self.path_key(operation.destination());
        if self.entries.contains_key(&destination_key) {
            return Err(backend_error(
                BackendOperation::Rename,
                183,
                MutationCertainty::NotApplied,
            ));
        }
        let Some(entry) = self.entries.remove(&source_key) else {
            return Err(backend_error(
                BackendOperation::Rename,
                2,
                MutationCertainty::NotApplied,
            ));
        };
        if entry.identity != operation.expected_source() {
            self.entries.insert(source_key, entry);
            return Err(backend_error(
                BackendOperation::Rename,
                1168,
                MutationCertainty::NotApplied,
            ));
        }
        self.entries.insert(destination_key, entry);
        self.completed_moves.push((
            operation.source().to_string_lossy(),
            operation.destination().to_string_lossy(),
        ));
        if let Some((code, MutationCertainty::MayHaveApplied)) = injected {
            return Err(backend_error(
                BackendOperation::Rename,
                code,
                MutationCertainty::MayHaveApplied,
            ));
        }
        Ok(())
    }
}

const fn backend_error(
    operation: BackendOperation,
    code: u32,
    certainty: MutationCertainty,
) -> BackendError {
    BackendError {
        operation,
        code,
        certainty,
    }
}

fn parent_units(path: &[u16]) -> &[u16] {
    path.iter()
        .rposition(|unit| *unit == b'\\' as u16 || *unit == b'/' as u16)
        .map_or(&[], |index| &path[..index])
}

fn ascii_lower(unit: u16) -> u16 {
    if (b'A' as u16..=b'Z' as u16).contains(&unit) {
        unit + u16::from(b'a' - b'A')
    } else {
        unit
    }
}
