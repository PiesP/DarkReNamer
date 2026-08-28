use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::{AdmissionRejection, PlatformError, io_error, validate_persisted_path};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub(crate) struct FileIdentity {
    pub(crate) volume: u64,
    pub(crate) file: u64,
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
    fn fingerprint(&self, path: &Path) -> Result<Option<Fingerprint>, PlatformError>;
    fn siblings(&self, parent: &Path) -> Result<Vec<PathBuf>, PlatformError>;
    fn move_no_replace(
        &mut self,
        from: &Path,
        to: &Path,
        expected: FileIdentity,
    ) -> Result<(), MoveFailure>;
}

#[derive(Debug, Default)]
pub(crate) struct LocalFileSystem;

impl FileSystem for LocalFileSystem {
    fn fingerprint(&self, path: &Path) -> Result<Option<Fingerprint>, PlatformError> {
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

    #[cfg(unix)]
    fn move_no_replace(
        &mut self,
        from: &Path,
        to: &Path,
        expected: FileIdentity,
    ) -> Result<(), MoveFailure> {
        // The destination hard link is an atomic no-replace operation. Its
        // identity is checked before unlinking the source. If unlink fails, the
        // new link is removed; a failed compensation is ambiguous.
        fs::hard_link(from, to).map_err(|_error| MoveFailure {
            kind: MoveFailureKind::Definite,
            operation: "create no-replace destination link",
        })?;

        let destination_matches = self
            .fingerprint(to)
            .ok()
            .flatten()
            .is_some_and(|fingerprint| fingerprint.identity == expected);
        let source_matches = self
            .fingerprint(from)
            .ok()
            .flatten()
            .is_some_and(|fingerprint| fingerprint.identity == expected);
        if !destination_matches || !source_matches {
            return match fs::remove_file(to) {
                Ok(()) => Err(MoveFailure {
                    kind: MoveFailureKind::Definite,
                    operation: "revalidate linked source identity",
                }),
                Err(_error) => Err(MoveFailure {
                    kind: MoveFailureKind::Ambiguous,
                    operation: "compensate linked source identity failure",
                }),
            };
        }

        if fs::remove_file(from).is_ok() {
            return Ok(());
        }

        match fs::remove_file(to) {
            Ok(()) => Err(MoveFailure {
                kind: MoveFailureKind::Definite,
                operation: "remove source after linking destination",
            }),
            Err(_error) => Err(MoveFailure {
                kind: MoveFailureKind::Ambiguous,
                operation: "compensate failed source removal",
            }),
        }
    }

    #[cfg(not(unix))]
    fn move_no_replace(
        &mut self,
        _from: &Path,
        _to: &Path,
        _expected: FileIdentity,
    ) -> Result<(), MoveFailure> {
        Err(MoveFailure {
            kind: MoveFailureKind::Definite,
            operation: "atomic no-replace regular-file move is unsupported on this target",
        })
    }
}

#[cfg(unix)]
fn local_identity(_path: &Path, metadata: &fs::Metadata) -> FileIdentity {
    use std::os::unix::fs::MetadataExt;

    FileIdentity {
        volume: metadata.dev(),
        file: metadata.ino(),
    }
}

#[cfg(not(unix))]
fn local_identity(path: &Path, metadata: &fs::Metadata) -> FileIdentity {
    use std::hash::{Hash, Hasher};

    // Read-only preview fallback. Mutation is unavailable on this target.
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut hasher);
    metadata.len().hash(&mut hasher);
    FileIdentity {
        volume: 0,
        file: hasher.finish(),
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
