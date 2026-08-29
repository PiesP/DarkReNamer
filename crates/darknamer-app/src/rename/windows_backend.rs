//! Production Windows `RenameBackend` using retained parent and entry handles.

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
use super::windows_native::{NativeParent, entry_identity, open_entry, rename_noreplace};
use super::{
    BackendError, BackendOperation, EntryIdentity, EntryKind, MutationCertainty, PathKey,
    PathSnapshot, RenameBackend, RenameOperation,
};

const ERROR_FILE_NOT_FOUND: i32 = 2;
const ERROR_PATH_NOT_FOUND: i32 = 3;
const ERROR_ALREADY_EXISTS: u32 = 183;

/// Windows production backend with handle-relative, identity-bound mutation.
#[derive(Debug, Default)]
pub struct WindowsRenameBackend;

impl RenameBackend for WindowsRenameBackend {
    fn path_key(&self, path: &LegacyText) -> PathKey {
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
                let identity = entry_identity(&file)
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
        let (source_parent_path, source_leaf) =
            split_absolute_path(operation.source(), BackendOperation::Rename)?;
        let (destination_parent_path, destination_leaf) =
            split_absolute_path(operation.destination(), BackendOperation::Rename)?;
        let source_parent = NativeParent::open_legacy(&source_parent_path)
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        let destination_parent = NativeParent::open_legacy(&destination_parent_path)
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        let source_parent_identity = model_identity(source_parent.identity);
        let destination_parent_identity = model_identity(destination_parent.identity);
        if source_parent_identity != operation.expected_source_parent()
            || destination_parent_identity != operation.expected_destination_parent()
            || source_parent_identity != destination_parent_identity
        {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 1168,
                certainty: MutationCertainty::NotApplied,
            });
        }
        let source = open_entry(&source_parent, source_leaf.units(), true)
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
        let source_identity = entry_identity(&source)
            .map(model_identity)
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;
        if source_identity != operation.expected_source() {
            return Err(BackendError {
                operation: BackendOperation::Rename,
                code: 1168,
                certainty: MutationCertainty::NotApplied,
            });
        }
        match open_entry(&destination_parent, destination_leaf.units(), false) {
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

        rename_noreplace(&source, destination_parent.file(), destination_leaf.units())
            .map_err(|error| mutation_error(error, MutationCertainty::NotApplied))?;

        let destination = open_entry(&destination_parent, destination_leaf.units(), false)
            .map_err(|error| mutation_error(error, MutationCertainty::MayHaveApplied))?;
        let observed = entry_identity(&destination)
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
    let parent_end = if separator == 2 && units[1] == b':' as u16 {
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
