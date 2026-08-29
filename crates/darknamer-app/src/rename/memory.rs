use std::collections::BTreeMap;

use darknamer_core::LegacyText;

use super::model::ObservedEntry;
use super::{
    BackendError, BackendOperation, EntryIdentity, EntryKind, PathKey, PathSnapshot, RenameBackend,
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
}

impl MemoryBackend {
    /// Creates an empty adapter.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
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

    fn parent_identity(&self, path: &LegacyText) -> EntryIdentity {
        let mut hash = 0xcbf2_9ce4_8422_2325_u64;
        for unit in parent_units(path.units()) {
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

    fn rename_no_replace(
        &mut self,
        source: &LegacyText,
        destination: &LegacyText,
        expected_source: EntryIdentity,
    ) -> Result<(), BackendError> {
        let source_key = self.path_key(source);
        let destination_key = self.path_key(destination);
        if self.entries.contains_key(&destination_key) {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 183,
            });
        }
        let Some(entry) = self.entries.remove(&source_key) else {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 2,
            });
        };
        if entry.identity != expected_source {
            self.entries.insert(source_key, entry);
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 1168,
            });
        }
        self.entries.insert(destination_key, entry);
        Ok(())
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
