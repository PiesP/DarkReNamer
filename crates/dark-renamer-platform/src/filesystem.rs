use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
#[cfg(not(windows))]
use std::time::UNIX_EPOCH;

use crate::{AdmissionRejection, PlatformError, io_error, validate_persisted_path};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub(crate) struct FileIdentity {
    pub(crate) volume: u64,
    pub(crate) file: [u8; 16],
}

impl FileIdentity {
    #[cfg(any(not(windows), test))]
    pub(crate) const fn from_u64(volume: u64, file: u64) -> Self {
        let source = file.to_le_bytes();
        let mut value = [0_u8; 16];
        let mut index = 0;
        while index < source.len() {
            value[index] = source[index];
            index += 1;
        }
        Self {
            volume,
            file: value,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EntryKind {
    RegularFile,
    Directory,
    SymbolicLink,
    Other,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Fingerprint {
    pub(crate) identity: FileIdentity,
    pub(crate) kind: EntryKind,
    pub(crate) length: u64,
    pub(crate) modified_nanos: u128,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MoveFailureKind {
    Definite,
    Ambiguous,
}

#[derive(Debug)]
pub(crate) struct MoveFailure {
    pub(crate) kind: MoveFailureKind,
    pub(crate) operation: &'static str,
}

pub(crate) trait FileSystem {
    fn ensure_mutation_supported(&self) -> Result<(), PlatformError>;
    fn fingerprint(&self, path: &Path) -> Result<Option<Fingerprint>, PlatformError>;
    fn siblings(&self, parent: &Path) -> Result<Vec<PathBuf>, PlatformError>;
    fn move_no_replace(
        &mut self,
        from: &Path,
        to: &Path,
        expected_parent: FileIdentity,
        expected: FileIdentity,
    ) -> Result<(), MoveFailure>;
}

#[derive(Debug, Default)]
pub(crate) struct LocalFileSystem;

impl FileSystem for LocalFileSystem {
    fn ensure_mutation_supported(&self) -> Result<(), PlatformError> {
        if cfg!(windows) {
            Ok(())
        } else {
            Err(PlatformError::Unsupported {
                operation: "handle-bound atomic no-replace regular-file move",
            })
        }
    }

    fn fingerprint(&self, path: &Path) -> Result<Option<Fingerprint>, PlatformError> {
        #[cfg(windows)]
        {
            windows_fingerprint(path)
        }
        #[cfg(not(windows))]
        {
            local_fingerprint(path)
        }
    }

    fn siblings(&self, parent: &Path) -> Result<Vec<PathBuf>, PlatformError> {
        let entries =
            fs::read_dir(parent).map_err(|error| io_error("enumerate siblings", error))?;
        let mut paths = Vec::new();
        for entry in entries {
            paths.push(
                entry
                    .map_err(|error| io_error("read sibling entry", error))?
                    .path(),
            );
        }
        paths.sort();
        Ok(paths)
    }

    fn move_no_replace(
        &mut self,
        from: &Path,
        to: &Path,
        expected_parent: FileIdentity,
        expected: FileIdentity,
    ) -> Result<(), MoveFailure> {
        #[cfg(windows)]
        {
            windows_move_no_replace(from, to, expected_parent, expected)
        }
        #[cfg(not(windows))]
        {
            let _ = (from, to, expected_parent, expected);
            Err(MoveFailure {
                kind: MoveFailureKind::Definite,
                operation: "handle-bound atomic no-replace regular-file move is unsupported",
            })
        }
    }
}

#[cfg(not(windows))]
fn local_fingerprint(path: &Path) -> Result<Option<Fingerprint>, PlatformError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(io_error("inspect filesystem entry", error)),
    };
    let file_type = metadata.file_type();
    let kind = if file_type.is_symlink() {
        EntryKind::SymbolicLink
    } else if file_type.is_file() {
        EntryKind::RegularFile
    } else if file_type.is_dir() {
        EntryKind::Directory
    } else {
        EntryKind::Other
    };
    let modified_nanos = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |duration| duration.as_nanos());
    Ok(Some(Fingerprint {
        identity: local_identity(path, &metadata),
        kind,
        length: metadata.len(),
        modified_nanos,
    }))
}

#[cfg(unix)]
fn local_identity(_path: &Path, metadata: &fs::Metadata) -> FileIdentity {
    use std::os::unix::fs::MetadataExt;

    FileIdentity::from_u64(metadata.dev(), metadata.ino())
}

#[cfg(not(any(unix, windows)))]
fn local_identity(path: &Path, metadata: &fs::Metadata) -> FileIdentity {
    use std::hash::{Hash, Hasher};

    // Read-only preview fallback. Mutation is unavailable on this target.
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut hasher);
    metadata.len().hash(&mut hasher);
    FileIdentity::from_u64(0, hasher.finish())
}

#[cfg(windows)]
fn windows_fingerprint(path: &Path) -> Result<Option<Fingerprint>, PlatformError> {
    use std::os::windows::fs::MetadataExt;

    use dark_renamer_windows::{EntryHandle, ParentHandle, file_identity};
    use windows_metadata::{metadata_kind, modified_nanos};

    let result = if let (Some(parent_path), Some(name)) = (path.parent(), path.file_name()) {
        let parent = match ParentHandle::open(parent_path) {
            Ok(parent) => parent,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(io_error("open parent identity handle", error)),
        };
        let entry = match EntryHandle::open_relative(&parent, name) {
            Ok(entry) => entry,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(io_error("open entry identity handle", error)),
        };
        let metadata = entry
            .metadata()
            .map_err(|error| io_error("inspect entry handle", error))?;
        let identity = file_identity(entry.as_handle())
            .map_err(|error| io_error("read entry identity", error))?;
        Fingerprint {
            identity: FileIdentity {
                volume: identity.volume_serial_number(),
                file: identity.file_id(),
            },
            kind: metadata_kind(&metadata),
            length: metadata.file_size(),
            modified_nanos: modified_nanos(&metadata),
        }
    } else {
        let parent = match ParentHandle::open(path) {
            Ok(parent) => parent,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(io_error("open parent identity handle", error)),
        };
        let identity = file_identity(parent.as_handle())
            .map_err(|error| io_error("read parent identity", error))?;
        Fingerprint {
            identity: FileIdentity {
                volume: identity.volume_serial_number(),
                file: identity.file_id(),
            },
            kind: EntryKind::Directory,
            length: 0,
            modified_nanos: 0,
        }
    };
    Ok(Some(result))
}

#[cfg(windows)]
mod windows_metadata {
    use std::fs::Metadata;
    use std::os::windows::fs::MetadataExt;

    use super::EntryKind;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;

    pub(super) fn metadata_kind(metadata: &Metadata) -> EntryKind {
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            EntryKind::SymbolicLink
        } else if metadata.is_file() {
            EntryKind::RegularFile
        } else if metadata.is_dir() {
            EntryKind::Directory
        } else {
            EntryKind::Other
        }
    }

    pub(super) fn modified_nanos(metadata: &Metadata) -> u128 {
        u128::from(metadata.last_write_time()) * 100
    }
}

#[cfg(windows)]
fn windows_move_no_replace(
    from: &Path,
    to: &Path,
    expected_parent: FileIdentity,
    expected: FileIdentity,
) -> Result<(), MoveFailure> {
    use dark_renamer_windows::{EntryHandle, ParentHandle, file_identity, rename_noreplace};

    let Some(parent_path) = from.parent() else {
        return Err(definite("source has no parent"));
    };
    if to.parent() != Some(parent_path) {
        return Err(definite("cross-parent move is unsupported"));
    }
    let (Some(source_name), Some(target_name)) = (from.file_name(), to.file_name()) else {
        return Err(definite("move path has no leaf name"));
    };
    let parent = ParentHandle::open(parent_path).map_err(|_| definite("open retained parent"))?;
    let parent_identity = file_identity(parent.as_handle())
        .map(to_file_identity)
        .map_err(|_| definite("read retained parent identity"))?;
    if parent_identity != expected_parent {
        return Err(definite("parent identity changed"));
    }
    let source = EntryHandle::open_relative(&parent, source_name)
        .map_err(|_| definite("open retained source"))?;
    let metadata = source
        .metadata()
        .map_err(|_| definite("inspect retained source"))?;
    if windows_metadata::metadata_kind(&metadata) != EntryKind::RegularFile {
        return Err(definite("source is not a regular non-reparse file"));
    }
    let source_identity = file_identity(source.as_handle())
        .map(to_file_identity)
        .map_err(|_| definite("read retained source identity"))?;
    if source_identity != expected {
        return Err(definite("source identity changed"));
    }

    rename_noreplace(source.as_handle(), parent.as_handle(), target_name)
        .map_err(|_| definite("native no-replace rename"))?;

    let retained_parent = file_identity(parent.as_handle())
        .map(to_file_identity)
        .map_err(|_| ambiguous("post-rename parent identity unavailable"))?;
    let retained_source = file_identity(source.as_handle())
        .map(to_file_identity)
        .map_err(|_| ambiguous("post-rename source identity unavailable"))?;
    if retained_parent != expected_parent || retained_source != expected {
        return Err(ambiguous("post-rename retained identity mismatch"));
    }
    let reopened = EntryHandle::open_relative(&parent, target_name)
        .map_err(|_| ambiguous("post-rename destination unavailable"))?;
    let reopened_identity = file_identity(reopened.as_handle())
        .map(to_file_identity)
        .map_err(|_| ambiguous("post-rename destination identity unavailable"))?;
    if reopened_identity != expected {
        return Err(ambiguous("post-rename destination identity mismatch"));
    }
    let path_parent = windows_fingerprint(parent_path)
        .map_err(|_| ambiguous("post-rename parent path identity unavailable"))?
        .ok_or_else(|| ambiguous("post-rename parent path unavailable"))?;
    if path_parent.identity != expected_parent || path_parent.kind != EntryKind::Directory {
        return Err(ambiguous("post-rename parent path identity mismatch"));
    }
    let path_destination = windows_fingerprint(to)
        .map_err(|_| ambiguous("post-rename destination path identity unavailable"))?
        .ok_or_else(|| ambiguous("post-rename destination path unavailable"))?;
    if path_destination.identity != expected || path_destination.kind != EntryKind::RegularFile {
        return Err(ambiguous("post-rename destination path identity mismatch"));
    }
    Ok(())
}

#[cfg(windows)]
fn to_file_identity(identity: dark_renamer_windows::FileIdentity) -> FileIdentity {
    FileIdentity {
        volume: identity.volume_serial_number(),
        file: identity.file_id(),
    }
}

#[cfg(windows)]
const fn definite(operation: &'static str) -> MoveFailure {
    MoveFailure {
        kind: MoveFailureKind::Definite,
        operation,
    }
}

#[cfg(windows)]
const fn ambiguous(operation: &'static str) -> MoveFailure {
    MoveFailure {
        kind: MoveFailureKind::Ambiguous,
        operation,
    }
}

pub(crate) fn validate_admitted_file(
    path: &Path,
    source: Option<Fingerprint>,
    parent: Option<Fingerprint>,
) -> Result<(Fingerprint, Fingerprint), PlatformError> {
    validate_persisted_path(path)?;
    let source = source.ok_or_else(|| PlatformError::AdmissionRejected {
        path: path.to_path_buf(),
        reason: AdmissionRejection::NotRegularFile,
    })?;
    let reason = match source.kind {
        EntryKind::RegularFile => None,
        EntryKind::SymbolicLink => Some(AdmissionRejection::SymbolicLink),
        EntryKind::Directory | EntryKind::Other => Some(AdmissionRejection::NotRegularFile),
    };
    if let Some(reason) = reason {
        return Err(PlatformError::AdmissionRejected {
            path: path.to_path_buf(),
            reason,
        });
    }
    let parent = parent.ok_or_else(|| PlatformError::AdmissionRejected {
        path: path.to_path_buf(),
        reason: AdmissionRejection::MissingParent,
    })?;
    if parent.kind != EntryKind::Directory {
        return Err(PlatformError::AdmissionRejected {
            path: path.to_path_buf(),
            reason: AdmissionRejection::InvalidParent,
        });
    }
    Ok((source, parent))
}

pub(crate) fn has_duplicate_identities(
    fingerprints: impl IntoIterator<Item = Fingerprint>,
) -> bool {
    let mut identities = BTreeSet::new();
    fingerprints
        .into_iter()
        .any(|fingerprint| !identities.insert(fingerprint.identity))
}
