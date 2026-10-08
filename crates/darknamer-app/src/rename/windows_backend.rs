//! Production Windows `RenameBackend` using retained parent and entry handles.
//!
//! Safe v1 rejects per-directory case-sensitive parents and UNC/SMB paths
//! before ordinal folding or filesystem mutation.

use std::os::windows::fs::MetadataExt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use darknamer_core::{LegacyText, validate_windows_leaf_name};
use windows_sys::Win32::Globalization::{
    CSTR_EQUAL, CompareStringOrdinal, LCMAP_UPPERCASE, LCMapStringEx, LOCALE_NAME_INVARIANT,
};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT,
};

use super::model::ObservedEntry;
use super::windows_native::{
    NativeParent, NativeParentChain, file_identity, normalized_final_leaf, open_entry,
    rename_noreplace,
};
use super::{
    BackendError, BackendOperation, EntryIdentity, EntryKind, MutationCertainty, PathKey,
    PathSnapshot, RenameBackend, RenameOperation, ResolvedSource,
};

const ERROR_FILE_NOT_FOUND: i32 = 2;
const ERROR_PATH_NOT_FOUND: i32 = 3;
const ERROR_NOT_SAME_DEVICE: u32 = 17;
const ERROR_ALREADY_EXISTS: u32 = 183;

/// Windows production backend with handle-relative, identity-bound mutation.
#[derive(Debug, Default)]
pub struct WindowsRenameBackend;

impl WindowsRenameBackend {
    /// Opens and validates one exact destination-parent directory.
    ///
    /// All traversal, final-directory, filesystem, case-sensitivity, protocol,
    /// and identity checks are performed through the retained final directory
    /// handle before it is released. Volume roots are valid destination
    /// parents and therefore do not require a synthetic leaf component.
    pub fn validate_destination_parent(
        &self,
        path: &LegacyText,
    ) -> Result<EntryIdentity, BackendError> {
        NativeParent::open_legacy(path)
            .map(|parent| model_identity(parent.identity))
            .map_err(|error| observe_error(error, BackendOperation::Observe))
    }
}

impl RenameBackend for WindowsRenameBackend {
    fn validate_path_environment(&self, path: &LegacyText) -> Result<(), BackendError> {
        let (parent_path, _leaf) = split_absolute_path(path, BackendOperation::Observe)?;
        NativeParent::open_legacy(&parent_path)
            .map(|_parent| ())
            .map_err(|error| observe_error(error, BackendOperation::Observe))
    }

    fn path_key(&self, path: &LegacyText) -> PathKey {
        // Planner/executor callers must first validate the path environment;
        // safe v1 never folds a case-sensitive parent silently.
        let mut normalized = path.units().to_vec();
        for unit in &mut normalized {
            if *unit == b'/' as u16 {
                *unit = b'\\' as u16;
            }
        }
        let Some(mapped) = invariant_uppercase(&normalized) else {
            return PathKey(vec![u16::MAX].into_boxed_slice());
        };
        PathKey(mapped.into_boxed_slice())
    }

    fn resolve_source(&self, path: &LegacyText) -> Result<ResolvedSource, BackendError> {
        let (parent_path, leaf) = split_absolute_path(path, BackendOperation::Observe)?;
        let parent = NativeParent::open_legacy(&parent_path)
            .map_err(|error| observe_error(error, BackendOperation::Observe))?;
        let source = match open_entry(&parent, leaf.units(), false) {
            Ok(source) => source,
            Err(error) if is_not_found(&error) => {
                return Ok(ResolvedSource::new(
                    path.clone(),
                    PathSnapshot {
                        parent: model_identity(parent.identity),
                        entry: None,
                    },
                    None,
                ));
            }
            Err(error) => return Err(observe_error(error, BackendOperation::Observe)),
        };
        let metadata = source
            .metadata()
            .map_err(|error| observe_error(error, BackendOperation::Observe))?;
        let identity = file_identity(&source)
            .map(model_identity)
            .map_err(|error| observe_error(error, BackendOperation::Observe))?;
        let entry = ObservedEntry {
            identity,
            kind: if metadata.file_attributes() & FILE_ATTRIBUTE_DIRECTORY != 0 {
                EntryKind::Directory
            } else {
                EntryKind::File
            },
            is_reparse_point: metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0,
        };
        let normalized_leaf = normalized_final_leaf(&source)
            .map_err(|error| observe_error(error, BackendOperation::Observe))?;
        let normalized_leaf = LegacyText::from_units(normalized_leaf);
        if validate_windows_leaf_name(&normalized_leaf).is_err() {
            return Err(invalid_path_error(BackendOperation::Observe));
        }
        let parent_identity = model_identity(parent.identity);
        let entry_key = self.planned_entry_key(parent_identity, &normalized_leaf)?;
        let actual_path = join_parent_and_leaf(&parent_path, &normalized_leaf);
        Ok(ResolvedSource::new(
            actual_path,
            PathSnapshot {
                parent: parent_identity,
                entry: Some(entry),
            },
            Some(entry_key),
        ))
    }

    fn planned_entry_key(
        &self,
        parent: EntryIdentity,
        leaf: &LegacyText,
    ) -> Result<PathKey, BackendError> {
        if validate_windows_leaf_name(leaf).is_err() {
            return Err(invalid_path_error(BackendOperation::Observe));
        }
        let normalized_leaf = invariant_uppercase(leaf.units()).ok_or_else(|| BackendError {
            operation: BackendOperation::Observe,
            code: io_code(),
            certainty: MutationCertainty::NotApplied,
        })?;
        Ok(super::ports::entry_key_from_parts(parent, &normalized_leaf))
    }

    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError> {
        let (parent_path, leaf) = split_absolute_path(path, BackendOperation::Observe)?;
        let parent = NativeParent::open_legacy(&parent_path)
            .map_err(|error| observe_error(error, BackendOperation::Observe))?;
        let parent_identity = model_identity(parent.identity);
        let entry = match open_entry(&parent, leaf.units(), false) {
            Ok(file) => {
                let metadata = file
                    .metadata()
                    .map_err(|error| observe_error(error, BackendOperation::Observe))?;
                let identity = file_identity(&file)
                    .map_err(|error| observe_error(error, BackendOperation::Observe))?;
                Some(ObservedEntry {
                    identity: model_identity(identity),
                    kind: if metadata.file_attributes() & FILE_ATTRIBUTE_DIRECTORY != 0 {
                        EntryKind::Directory
                    } else {
                        EntryKind::File
                    },
                    is_reparse_point: metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT
                        != 0,
                })
            }
            Err(error) if is_not_found(&error) => None,
            Err(error) => return Err(observe_error(error, BackendOperation::Observe)),
        };
        Ok(PathSnapshot {
            parent: parent_identity,
            entry,
        })
    }

    fn is_same_or_descendant(
        &self,
        ancestor: &LegacyText,
        candidate: &LegacyText,
    ) -> Result<bool, BackendError> {
        let ancestor = path_components(ancestor);
        let candidate = path_components(candidate);
        if candidate.len() < ancestor.len() {
            return Ok(false);
        }
        for (left, right) in ancestor.iter().zip(candidate.iter()) {
            if !ordinal_equal(left, right)? {
                return Ok(false);
            }
        }
        Ok(true)
    }

    fn next_transaction_nonce(&mut self) -> Result<u128, BackendError> {
        static COUNTER: AtomicU64 = AtomicU64::new(1);
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| BackendError {
                operation: BackendOperation::TransactionNonce,
                code: 1,
                certainty: MutationCertainty::NotApplied,
            })?
            .as_nanos();
        let nonce = time ^ (u128::from(std::process::id()) << 64) ^ u128::from(counter);
        Ok(nonce.max(1))
    }

    fn rename_no_replace(&mut self, operation: &RenameOperation) -> Result<(), BackendError> {
        self.rename_with_boundaries(operation, || Ok(()), || Ok(()))
    }
}

impl WindowsRenameBackend {
    fn rename_with_boundaries<F, G>(
        &mut self,
        operation: &RenameOperation,
        before_source_open: F,
        before_native_sink: G,
    ) -> Result<(), BackendError>
    where
        F: FnOnce() -> std::io::Result<()>,
        G: FnOnce() -> std::io::Result<()>,
    {
        if let Some(error) = operation.authorization_error() {
            return Err(error);
        }
        let (source_parent_path, source_leaf) =
            split_absolute_path(operation.source(), BackendOperation::Rename)?;
        let (destination_parent_path, destination_leaf) =
            split_absolute_path(operation.destination(), BackendOperation::Rename)?;
        let source_chain = NativeParentChain::open_legacy(&source_parent_path)
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        let destination_chain = NativeParentChain::open_legacy(&destination_parent_path)
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        let source_parent = source_chain.parent();
        let destination_parent = destination_chain.parent();
        let source_parent_identity = model_identity(source_parent.identity);
        let destination_parent_identity = model_identity(destination_parent.identity);
        if source_parent_identity != operation.expected_source_parent()
            || destination_parent_identity != operation.expected_destination_parent()
        {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 1168,
                certainty: MutationCertainty::NotApplied,
            });
        }
        before_source_open()
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        let source = open_entry(source_parent, source_leaf.units(), true)
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        let metadata = source
            .metadata()
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 4390,
                certainty: MutationCertainty::NotApplied,
            });
        }
        let source_kind = if metadata.file_attributes() & FILE_ATTRIBUTE_DIRECTORY != 0 {
            EntryKind::Directory
        } else {
            EntryKind::File
        };
        if operation.kind().is_some_and(|kind| source_kind != kind) {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 1168,
                certainty: MutationCertainty::NotApplied,
            });
        }
        let source_identity = file_identity(&source)
            .map(model_identity)
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        if source_identity != operation.expected_source() {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 1168,
                certainty: MutationCertainty::NotApplied,
            });
        }
        let actual_source_leaf = normalized_final_leaf(&source)
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        if actual_source_leaf != source_leaf.units() {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 1168,
                certainty: MutationCertainty::NotApplied,
            });
        }
        match open_entry(destination_parent, destination_leaf.units(), false) {
            Ok(_occupied) => {
                return Err(BackendError {
                    operation: BackendOperation::Rename,
                    code: ERROR_ALREADY_EXISTS,
                    certainty: MutationCertainty::NotApplied,
                });
            }
            Err(error) if is_not_found(&error) => {}
            Err(error) => {
                return Err(mutation_error(error, MutationCertainty::NotApplied));
            }
        }

        if source_parent_identity.volume() != destination_parent_identity.volume() {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: ERROR_NOT_SAME_DEVICE,
                certainty: MutationCertainty::NotApplied,
            });
        }

        before_native_sink()
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        rename_noreplace(&source, destination_parent.file(), destination_leaf.units())
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;

        let destination = open_entry(destination_parent, destination_leaf.units(), false)
            .map_err(|error| mutation_error(error, MutationCertainty::MayHaveApplied))?;
        let observed = file_identity(&destination)
            .map(model_identity)
            .map_err(|error| mutation_error(error, MutationCertainty::MayHaveApplied))?;
        if observed != source_identity {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 1168,
                certainty: MutationCertainty::MayHaveApplied,
            });
        }
        Ok(())
    }
}

fn split_absolute_path(
    path: &LegacyText,
    operation: BackendOperation,
) -> Result<(LegacyText, LegacyText), BackendError> {
    let units = path.units();
    let absolute = units.len() >= 3
        && (((b'A' as u16..=b'Z' as u16).contains(&units[0])
            || (b'a' as u16..=b'z' as u16).contains(&units[0]))
            && units[1] == b':' as u16
            && is_separator(units[2])
            || units.len() >= 5 && is_separator(units[0]) && is_separator(units[1]));
    let Some(separator) = units.iter().rposition(|unit| is_separator(*unit)) else {
        return Err(invalid_path_error(operation));
    };
    if !absolute || separator + 1 >= units.len() {
        return Err(invalid_path_error(operation));
    }
    let parent_end = if is_drive_root_separator(units, separator) {
        separator + 1
    } else {
        separator
    };
    let parent = LegacyText::from_units(units[..parent_end].to_vec());
    let leaf = LegacyText::from_units(units[separator + 1..].to_vec());
    if validate_windows_leaf_name(&leaf).is_err() {
        return Err(invalid_path_error(operation));
    }
    Ok((parent, leaf))
}

fn join_parent_and_leaf(parent: &LegacyText, leaf: &LegacyText) -> LegacyText {
    let mut units = Vec::with_capacity(parent.len() + 1 + leaf.len());
    units.extend_from_slice(parent.units());
    if !parent
        .units()
        .last()
        .is_some_and(|unit| is_separator(*unit))
    {
        units.push(b'\\' as u16);
    }
    units.extend_from_slice(leaf.units());
    LegacyText::from_units(units)
}

fn is_drive_root_separator(units: &[u16], separator: usize) -> bool {
    (separator == 2 && units.get(1) == Some(&(b':' as u16)))
        || (separator == 6
            && units.starts_with(&[b'\\' as u16, b'\\' as u16, b'?' as u16, b'\\' as u16])
            && units.get(5) == Some(&(b':' as u16)))
}

fn path_components(path: &LegacyText) -> Vec<&[u16]> {
    path.units()
        .split(|unit| is_separator(*unit))
        .filter(|component| !component.is_empty())
        .collect()
}

fn is_separator(unit: u16) -> bool {
    unit == b'\\' as u16 || unit == b'/' as u16
}

fn ordinal_equal(left: &[u16], right: &[u16]) -> Result<bool, BackendError> {
    let left_len =
        i32::try_from(left.len()).map_err(|_| invalid_path_error(BackendOperation::Observe))?;
    let right_len =
        i32::try_from(right.len()).map_err(|_| invalid_path_error(BackendOperation::Observe))?;
    // SAFETY: both UTF-16 slices remain live for the synchronous comparison,
    // lengths are checked i32 values, and the API retains no pointers.
    let result =
        unsafe { CompareStringOrdinal(left.as_ptr(), left_len, right.as_ptr(), right_len, 1) };
    if result == 0 {
        Err(BackendError {
            operation: BackendOperation::Observe,
            code: io_code(),
            certainty: MutationCertainty::NotApplied,
        })
    } else {
        Ok(result == CSTR_EQUAL)
    }
}

fn invariant_uppercase(units: &[u16]) -> Option<Vec<u16>> {
    let length = i32::try_from(units.len()).ok()?;
    // SAFETY: source is a live UTF-16 slice with checked length; null output is
    // the documented sizing query and no pointer is retained.
    let needed = unsafe {
        LCMapStringEx(
            LOCALE_NAME_INVARIANT,
            LCMAP_UPPERCASE,
            units.as_ptr(),
            length,
            std::ptr::null_mut(),
            0,
            std::ptr::null(),
            std::ptr::null(),
            0,
        )
    };
    if needed <= 0 {
        return None;
    }
    let mut mapped = vec![0_u16; needed as usize];
    // SAFETY: mapped has the exact capacity returned by the sizing query;
    // source and destination remain live and are not retained.
    let written = unsafe {
        LCMapStringEx(
            LOCALE_NAME_INVARIANT,
            LCMAP_UPPERCASE,
            units.as_ptr(),
            length,
            mapped.as_mut_ptr(),
            needed,
            std::ptr::null(),
            std::ptr::null(),
            0,
        )
    };
    if written != needed {
        None
    } else {
        Some(mapped)
    }
}

fn model_identity(identity: super::windows_native::NativeIdentity) -> EntryIdentity {
    EntryIdentity::new(identity.volume, identity.file_id)
}

fn observe_error(error: std::io::Error, operation: BackendOperation) -> BackendError {
    BackendError {
        operation,
        code: error_code(&error),
        certainty: MutationCertainty::NotApplied,
    }
}

fn mutation_error(error: std::io::Error, certainty: MutationCertainty) -> BackendError {
    BackendError {
        operation: BackendOperation::Rename,
        code: error_code(&error),
        certainty,
    }
}

fn invalid_path_error(operation: BackendOperation) -> BackendError {
    BackendError {
        operation,
        code: 123,
        certainty: MutationCertainty::NotApplied,
    }
}

fn is_not_found(error: &std::io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND)
    )
}

fn error_code(error: &std::io::Error) -> u32 {
    error
        .raw_os_error()
        .and_then(|code| u32::try_from(code).ok())
        .unwrap_or(1)
}

fn io_code() -> u32 {
    error_code(&std::io::Error::last_os_error())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::io::{self, Read};
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;
    use std::process::Command;

    use super::*;
    use crate::rename::MoveScope;

    fn legacy_path(path: &Path) -> LegacyText {
        LegacyText::from_units(path.as_os_str().encode_wide().collect::<Vec<_>>())
    }

    struct OwnedNamespaceMover(std::process::Child);

    impl Drop for OwnedNamespaceMover {
        fn drop(&mut self) {
            if !matches!(self.0.try_wait(), Ok(Some(_))) {
                let _killed = self.0.kill();
            }
            let _reaped = self.0.wait();
        }
    }

    // A separate process exercises the OS sharing rule at a deterministic primitive boundary.
    #[test]
    #[ignore = "owned subprocess helper; invoked by parent_namespace_boundary_probe"]
    fn namespace_relocation_child() -> Result<(), Box<dyn std::error::Error>> {
        let Some(root) = std::env::var_os("DARKRENAMER_PARENT_PROBE_ROOT") else {
            return Ok(());
        };
        let root = Path::new(&root);
        if !root.file_name().is_some_and(|name| {
            name.to_string_lossy()
                .starts_with("darkrenamer-parent-probe-")
        }) || fs::read(root.join("owned-probe.marker"))? != b"owned parent namespace test"
        {
            return Err(io::Error::other("parent probe ownership differs").into());
        }
        let relative = std::env::var("DARKRENAMER_PARENT_PROBE_FROM")?;
        if !matches!(
            relative.replace('\\', "/").as_str(),
            "source-tree" | "source-tree/parent" | "destination-tree" | "destination-tree/parent"
        ) {
            return Err(io::Error::other("parent probe source is not a fixed fixture path").into());
        }
        let from = root.join(relative);
        let to = root.join("relocated");
        if !from.starts_with(root) || from == root || to.exists() {
            return Err(io::Error::other("parent probe paths differ").into());
        }
        let code = match fs::rename(&from, &to) {
            Ok(()) => 0,
            Err(error) => error.raw_os_error().ok_or(error)?,
        };
        if code == 0 {
            let relative = std::env::var("DARKRENAMER_PARENT_PROBE_RECREATE_PARENT")?;
            if !matches!(
                relative.replace('\\', "/").as_str(),
                "source-tree/parent" | "destination-tree/parent"
            ) {
                return Err(io::Error::other(
                    "parent probe recreation is not a fixed fixture path",
                )
                .into());
            }
            let parent = root.join(relative);
            if !parent.starts_with(root) {
                return Err(io::Error::other("parent probe recreation escapes its root").into());
            }
            fs::create_dir_all(&parent)?;
            let occupant = std::env::var("DARKRENAMER_PARENT_PROBE_OCCUPANT")?;
            if !matches!(occupant.as_str(), "source.bin" | "destination.bin") {
                return Err(
                    io::Error::other("parent probe occupant is not a fixed fixture leaf").into(),
                );
            }
            fs::write(parent.join(occupant), b"unconfirmed occupant")?;
        }
        println!("PARENT_MOVE_CODE={code}");
        Ok(())
    }

    #[test]
    fn parent_namespace_boundary_probe() -> Result<(), Box<dyn std::error::Error>> {
        for before_open in [true, false] {
            for source_side in [true, false] {
                for ancestor in [false, true] {
                    let directory = tempfile::Builder::new()
                        .prefix("darkrenamer-parent-probe-")
                        .tempdir()?;
                    let root = directory.path();
                    fs::write(
                        root.join("owned-probe.marker"),
                        b"owned parent namespace test",
                    )?;
                    let source_parent = root.join("source-tree").join("parent");
                    let destination_parent = root.join("destination-tree").join("parent");
                    fs::create_dir_all(&source_parent)?;
                    fs::create_dir_all(&destination_parent)?;
                    let source = source_parent.join("source.bin");
                    let destination = destination_parent.join("destination.bin");
                    fs::write(&source, b"confirmed source")?;
                    let mut backend = WindowsRenameBackend;
                    let original = backend.observe(&legacy_path(&source))?;
                    let vacant = backend.observe(&legacy_path(&destination))?;
                    let identity = original
                        .entry
                        .ok_or_else(|| io::Error::other("source identity missing"))?
                        .identity;
                    let operation = RenameOperation::with_authorization(
                        legacy_path(&source),
                        legacy_path(&destination),
                        identity,
                        original.parent,
                        vacant.parent,
                        EntryKind::File,
                        MoveScope::SameVolumeFilesOnly,
                    );
                    let parent = if source_side {
                        &source_parent
                    } else {
                        &destination_parent
                    };
                    let moved = if ancestor {
                        parent
                            .parent()
                            .ok_or_else(|| io::Error::other("fixture ancestor missing"))?
                    } else {
                        parent
                    };
                    let relative = moved.strip_prefix(root)?;
                    let occupant = if source_side {
                        "source.bin"
                    } else {
                        "destination.bin"
                    };
                    let mut move_code = None;
                    let mut relocate = || -> io::Result<()> {
                        let output = Command::new(std::env::current_exe()?)
                            .args([
                                "--ignored",
                                "--exact",
                                "rename::windows_backend::tests::namespace_relocation_child",
                                "--nocapture",
                            ])
                            .env("DARKRENAMER_PARENT_PROBE_ROOT", root)
                            .env("DARKRENAMER_PARENT_PROBE_FROM", relative)
                            .env(
                                "DARKRENAMER_PARENT_PROBE_RECREATE_PARENT",
                                parent.strip_prefix(root).map_err(io::Error::other)?,
                            )
                            .env("DARKRENAMER_PARENT_PROBE_OCCUPANT", occupant)
                            .stdout(std::process::Stdio::piped())
                            .stderr(std::process::Stdio::piped())
                            .spawn()?;
                        let mut child = OwnedNamespaceMover(output);
                        let deadline =
                            std::time::Instant::now() + std::time::Duration::from_secs(10);
                        let status = loop {
                            if let Some(status) = child.0.try_wait()? {
                                break status;
                            }
                            if std::time::Instant::now() >= deadline {
                                return Err(io::Error::other("owned mover exceeded its deadline"));
                            }
                            std::thread::sleep(std::time::Duration::from_millis(20));
                        };
                        if !status.success() {
                            return Err(io::Error::other("owned mover process failed"));
                        }
                        let mut stdout = String::new();
                        child
                            .0
                            .stdout
                            .take()
                            .ok_or_else(|| io::Error::other("owned mover stdout missing"))?
                            .take(65_537)
                            .read_to_string(&mut stdout)?;
                        if stdout.len() > 65_536 {
                            return Err(io::Error::other("owned mover stdout exceeds its bound"));
                        }
                        let markers = stdout
                            .match_indices("PARENT_MOVE_CODE=")
                            .collect::<Vec<_>>();
                        if markers.len() != 1 {
                            return Err(io::Error::other("native move result missing or repeated"));
                        }
                        let code = stdout[markers[0].0 + "PARENT_MOVE_CODE=".len()..]
                            .split_whitespace()
                            .next()
                            .ok_or_else(|| io::Error::other("native move result missing"))?
                            .parse::<i32>()
                            .map_err(io::Error::other)?;
                        move_code = Some(code);
                        Ok(())
                    };
                    if before_open {
                        backend.rename_with_boundaries(&operation, &mut relocate, || Ok(()))?;
                    } else {
                        backend.rename_with_boundaries(&operation, || Ok(()), &mut relocate)?;
                    }
                    let code = move_code
                        .ok_or_else(|| io::Error::other("move boundary was not reached"))?;
                    assert_ne!(code, 0, "the primitive must retain the confirmed namespace");
                    assert_eq!(
                        backend.observe(&legacy_path(&source))?.parent,
                        original.parent
                    );
                    assert_eq!(
                        backend.observe(&legacy_path(&destination))?.parent,
                        vacant.parent
                    );
                    assert!(!root.join("relocated").exists());
                    assert!(!source.exists());
                    assert_eq!(fs::read(&destination)?, b"confirmed source");
                    let actual = backend.observe(&legacy_path(&destination))?;
                    assert_eq!(
                        actual
                            .entry
                            .ok_or_else(|| io::Error::other("destination identity missing"))?
                            .identity,
                        identity
                    );
                    println!(
                        "PARENT_NAMESPACE_RESULT={{\"before_source_open\":{before_open},\"source_side\":{source_side},\"ancestor\":{ancestor},\"move_code\":{code},\"at_confirmed_destination\":true,\"source_file_id\":\"{:032x}\",\"volume_id\":\"{:016x}\",\"identity_preserved\":true,\"contents_preserved\":true,\"parents_preserved\":true,\"replacement_created\":false,\"occupant_preserved\":null}}",
                        identity.file_id(),
                        identity.volume()
                    );
                    // Handles must be released when the primitive returns, including the pinned source.
                    fs::rename(moved, root.join("released-after-primitive"))?;
                }
            }
        }
        Ok(())
    }

    #[test]
    fn parent_namespace_handles_release_after_not_applied() -> Result<(), Box<dyn std::error::Error>>
    {
        for failure in 0..3 {
            let directory = tempfile::tempdir()?;
            let source_tree = directory.path().join("source-tree");
            let destination_tree = directory.path().join("destination-tree");
            let source_parent = source_tree.join("parent");
            let destination_parent = destination_tree.join("parent");
            fs::create_dir_all(&source_parent)?;
            fs::create_dir_all(&destination_parent)?;
            let source = source_parent.join("source.bin");
            let destination = destination_parent.join("destination.bin");
            fs::write(&source, b"confirmed source")?;
            let mut backend = WindowsRenameBackend;
            let original = backend.observe(&legacy_path(&source))?;
            let vacant = backend.observe(&legacy_path(&destination))?;
            let identity = original
                .entry
                .ok_or_else(|| io::Error::other("source identity missing"))?
                .identity;
            let operation = RenameOperation::with_authorization(
                legacy_path(&source),
                legacy_path(&destination),
                identity,
                original.parent,
                vacant.parent,
                EntryKind::File,
                MoveScope::SameVolumeFilesOnly,
            );
            match failure {
                0 => fs::remove_file(&source)?,
                1 => fs::write(&destination, b"unconfirmed occupant")?,
                _ => fs::remove_dir(&destination_parent)?,
            }
            let error = backend.rename_no_replace(&operation).err().ok_or_else(|| {
                io::Error::other("stale source, parent, or occupied destination must fail closed")
            })?;
            assert_eq!(error.certainty, MutationCertainty::NotApplied);
            if failure == 1 {
                assert_eq!(fs::read(&source)?, b"confirmed source");
                assert_eq!(fs::read(&destination)?, b"unconfirmed occupant");
            } else if failure == 0 {
                assert!(!source.exists() && !destination.exists());
            } else {
                assert_eq!(fs::read(&source)?, b"confirmed source");
                assert!(!destination_parent.exists());
            }
            fs::rename(source_tree, directory.path().join("released-source"))?;
            fs::rename(
                destination_tree,
                directory.path().join("released-destination"),
            )?;
        }
        Ok(())
    }

    #[test]
    fn parent_namespace_chain_rejects_overlong_input_before_acquisition() {
        let path = LegacyText::from_units(vec![u16::from(b'a'); 32_768]);
        assert_eq!(
            NativeParentChain::open_legacy(&path)
                .err()
                .and_then(|error| error.raw_os_error()),
            Some(206)
        );
    }

    #[test]
    fn verbatim_drive_leaf_preserves_the_root_separator_in_its_parent() -> Result<(), BackendError>
    {
        let (parent, leaf) = split_absolute_path(
            &LegacyText::from(r"\\?\C:\leaf.txt"),
            BackendOperation::Observe,
        )?;

        assert_eq!(parent, LegacyText::from(r"\\?\C:\"));
        assert_eq!(leaf, LegacyText::from("leaf.txt"));
        Ok(())
    }
}
