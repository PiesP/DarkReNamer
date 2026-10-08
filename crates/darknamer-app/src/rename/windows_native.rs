//! Audited Windows handle-relative filesystem primitives.

use std::ffi::OsStr;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::mem::{align_of, offset_of, size_of};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::{Component, Path, PathBuf, Prefix};
use std::ptr;
use std::sync::Arc;

use darknamer_core::{LegacyText, MAX_WINDOWS_LEAF_NAME_UTF16_UNITS};
use windows_sys::Wdk::Foundation::OBJECT_ATTRIBUTES;
use windows_sys::Wdk::Storage::FileSystem::{
    FILE_CREATE, FILE_DIRECTORY_FILE, FILE_ID_BOTH_DIR_INFORMATION, FILE_INTERNAL_INFORMATION,
    FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT, FILE_RENAME_INFORMATION,
    FILE_RENAME_INFORMATION_0, FILE_SYNCHRONOUS_IO_NONALERT, FileIdBothDirectoryInformation,
    FileInternalInformation, FileRenameInformation, NtCreateFile, NtQueryDirectoryFile,
    NtQueryInformationFile, NtSetInformationFile, RtlNtStatusToDosErrorNoTeb,
};
use windows_sys::Win32::Foundation::{
    HANDLE, OBJ_CASE_INSENSITIVE, STATUS_NO_MORE_FILES, UNICODE_STRING,
};
use windows_sys::Win32::Security::{
    GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation,
};
use windows_sys::Win32::Storage::FileSystem::{
    DELETE, FILE_ATTRIBUTE_REPARSE_POINT, FILE_CASE_SENSITIVE_INFO, FILE_DISPOSITION_INFO,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_ID_DESCRIPTOR, FILE_ID_INFO,
    FILE_NAME_NORMALIZED, FILE_READ_ATTRIBUTES, FILE_READ_DATA, FILE_REMOTE_PROTOCOL_INFO,
    FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_STANDARD_INFO, FILE_TRAVERSE,
    FILE_WRITE_DATA, FileCaseSensitiveInfo, FileDispositionInfo, FileIdInfo, FileIdType,
    FileRemoteProtocolInfo, FileStandardInfo, GetDriveTypeW, GetFileInformationByHandleEx,
    GetFinalPathNameByHandleW, GetVolumeInformationByHandleW, OpenFileById, SYNCHRONIZE,
    SetFileInformationByHandle, VOLUME_NAME_GUID, VOLUME_NAME_NONE,
};
use windows_sys::Win32::System::IO::IO_STATUS_BLOCK;
use windows_sys::Win32::System::SystemServices::FILE_CS_FLAG_CASE_SENSITIVE_DIR;
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows_sys::Win32::System::WindowsProgramming::{DRIVE_FIXED, DRIVE_REMOVABLE};

const SHARE_ALL: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
const SHARE_READ_WRITE: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE;
const ERROR_UNRECOGNIZED_VOLUME: i32 = 1005;
const ERROR_FILENAME_EXCED_RANGE: i32 = 206;
const FILESYSTEM_NAME_CAPACITY: usize = 32;
const MAX_NORMALIZED_FINAL_PATH_UTF16_UNITS: u32 = 32_768;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NativeIdentity {
    pub volume: u64,
    pub file_id: u128,
}

#[derive(Debug)]
pub(crate) struct NativeParent {
    file: File,
    pub identity: NativeIdentity,
}

/// Pins the current namespace from the local drive root through one parent.
/// Dropping this value releases every sharing restriction together.
#[derive(Debug)]
pub(crate) struct NativeParentChain {
    _ancestors: Vec<NativeParent>,
    parent: NativeParent,
}

impl NativeParentChain {
    pub(crate) fn open_legacy(path: &LegacyText) -> io::Result<Self> {
        // Bound the number of retained components by the supported native path limit.
        if path.units().len() >= MAX_NORMALIZED_FINAL_PATH_UTF16_UNITS as usize {
            return Err(io::Error::from_raw_os_error(ERROR_FILENAME_EXCED_RANGE));
        }
        let path = std::ffi::OsString::from_wide(path.units());
        let path = Path::new(&path);
        reject_unsupported_drive_type(path)?;
        let (root, components) = traversal_parts(path)?;
        let capacity = components
            .len()
            .checked_add(1)
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
        let mut directories = Vec::new();
        directories
            .try_reserve_exact(capacity)
            .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;

        let root_file = open_root_directory(&root, SHARE_READ_WRITE)?;
        validate_directory_handle(&root_file)?;
        reject_case_sensitive_directory(&root_file)?;
        reject_remote_protocol_if_reported(&root_file)?;
        reject_unsupported_filesystem(&root_file)?;
        let root_identity = file_identity(&root_file)?;
        directories.push(NativeParent {
            file: root_file,
            identity: root_identity,
        });
        for component in components {
            let leaf = component.encode_wide().collect::<Vec<_>>();
            let previous = directories
                .last()
                .ok_or_else(|| io::Error::other("mutation directory chain is empty"))?;
            let file = open_relative(
                previous.file(),
                &leaf,
                FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                SHARE_READ_WRITE,
                FILE_OPEN,
                FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
            )?;
            validate_directory_handle(&file)?;
            reject_case_sensitive_directory(&file)?;
            reject_remote_protocol_if_reported(&file)?;
            let identity = file_identity(&file)?;
            directories.push(NativeParent { file, identity });
        }
        let parent = directories
            .pop()
            .ok_or_else(|| io::Error::other("mutation directory chain is empty"))?;
        reject_unsupported_filesystem(parent.file())?;
        Ok(Self {
            _ancestors: directories,
            parent,
        })
    }

    pub(crate) fn parent(&self) -> &NativeParent {
        &self.parent
    }
}

#[derive(Debug)]
pub(crate) struct TextExportTarget {
    parents: Arc<Vec<NativeParent>>,
    leaf: Vec<u16>,
}

#[derive(Clone, Debug)]
pub(crate) struct TextExportParent {
    directories: Arc<Vec<NativeParent>>,
}

pub(crate) fn validate_safe_local_root(path: &Path) -> io::Result<()> {
    reject_unsupported_drive_type(path)?;
    traversal_parts(path).map(|_parts| ())
}

impl NativeParent {
    pub(crate) fn open_legacy(path: &LegacyText) -> io::Result<Self> {
        let path = std::ffi::OsString::from_wide(path.units());
        Self::open_path(Path::new(&path))
    }

    pub(crate) fn open_path(path: &Path) -> io::Result<Self> {
        Self::open_path_with_final_share(path, SHARE_ALL)
    }

    pub(crate) fn open_path_without_delete_share(path: &Path) -> io::Result<Self> {
        Self::open_path_with_final_share(path, SHARE_READ_WRITE)
    }

    fn open_path_with_final_share(path: &Path, final_share: u32) -> io::Result<Self> {
        reject_unsupported_drive_type(path)?;
        let (root, components) = traversal_parts(path)?;
        let root_share = if components.is_empty() {
            final_share
        } else {
            SHARE_ALL
        };
        let mut file = open_root_directory(&root, root_share)?;
        validate_directory_handle(&file)?;
        reject_case_sensitive_directory(&file)?;
        reject_remote_protocol_if_reported(&file)?;
        let component_count = components.len();
        for (index, component) in components.into_iter().enumerate() {
            let encoded = component.encode_wide().collect::<Vec<_>>();
            let share = if index + 1 == component_count {
                final_share
            } else {
                SHARE_ALL
            };
            file = open_relative(
                &file,
                &encoded,
                FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                share,
                FILE_OPEN,
                FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
            )?;
            validate_directory_handle(&file)?;
            reject_case_sensitive_directory(&file)?;
            reject_remote_protocol_if_reported(&file)?;
        }
        reject_unsupported_filesystem(&file)?;
        let identity = file_identity(&file)?;
        Ok(Self { file, identity })
    }

    pub(crate) fn file(&self) -> &File {
        &self.file
    }

    pub(crate) fn into_file(self) -> File {
        self.file
    }
}

pub(super) fn reject_case_sensitive_directory(file: &File) -> io::Result<()> {
    let mut info = FILE_CASE_SENSITIVE_INFO::default();
    let size = u32::try_from(size_of::<FILE_CASE_SENSITIVE_INFO>())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: file is a retained directory handle and info is a writable,
    // correctly aligned buffer with its exact checked size.
    let success = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle(),
            FileCaseSensitiveInfo,
            ptr::from_mut(&mut info).cast(),
            size,
        )
    };
    if success == 0 {
        return Err(io::Error::last_os_error());
    }
    if case_sensitive_flags_unsupported(info.Flags) {
        Err(io::Error::from_raw_os_error(50))
    } else {
        Ok(())
    }
}

pub(crate) const fn case_sensitive_flags_unsupported(flags: u32) -> bool {
    flags & FILE_CS_FLAG_CASE_SENSITIVE_DIR != 0
}

pub(super) fn reject_unsupported_filesystem(file: &File) -> io::Result<()> {
    let mut filesystem_name = [u16::MAX; FILESYSTEM_NAME_CAPACITY];
    let filesystem_name_capacity = u32::try_from(filesystem_name.len())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: file is the retained final directory handle; unused output
    // pointers are null, filesystem_name is writable for its checked length,
    // and the synchronous API retains no pointers.
    let success = unsafe {
        GetVolumeInformationByHandleW(
            file.as_raw_handle(),
            ptr::null_mut(),
            0,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            filesystem_name.as_mut_ptr(),
            filesystem_name_capacity,
        )
    };
    let query_result = if success == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    };
    validate_ntfs_query_result(query_result, &filesystem_name)
}

fn validate_ntfs_query_result(query_result: io::Result<()>, buffer: &[u16]) -> io::Result<()> {
    query_result?;
    let nul = buffer
        .iter()
        .position(|unit| *unit == 0)
        .ok_or_else(unsupported_filesystem_error)?;
    let name = &buffer[..nul];
    let expected = b"NTFS";
    if name.len() == expected.len()
        && name.iter().zip(expected).all(|(unit, expected)| {
            u8::try_from(*unit).is_ok_and(|unit| unit.eq_ignore_ascii_case(expected))
        })
    {
        Ok(())
    } else {
        Err(unsupported_filesystem_error())
    }
}

fn unsupported_filesystem_error() -> io::Error {
    io::Error::from_raw_os_error(ERROR_UNRECOGNIZED_VOLUME)
}

fn reject_unsupported_drive_type(path: &Path) -> io::Result<()> {
    let Some(Component::Prefix(prefix)) = path.components().next() else {
        return Err(io::Error::from_raw_os_error(53));
    };
    let letter = match prefix.kind() {
        Prefix::Disk(letter) | Prefix::VerbatimDisk(letter) => letter,
        _ => return Err(io::Error::from_raw_os_error(53)),
    };
    let root = [u16::from(letter), b':' as u16, b'\\' as u16, 0];
    // SAFETY: root is a fixed NUL-terminated UTF-16 drive-root buffer retained
    // for the synchronous call; GetDriveTypeW stores no pointer.
    let drive_type = unsafe { GetDriveTypeW(root.as_ptr()) };
    if drive_type_supported(drive_type) {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(53))
    }
}

pub(crate) const fn drive_type_supported(drive_type: u32) -> bool {
    matches!(drive_type, DRIVE_FIXED | DRIVE_REMOVABLE)
}

pub(crate) const fn token_elevation_is_unsafe(value: u32) -> bool {
    value != 0
}

/// Returns whether the current process token is elevated.
///
/// # Errors
///
/// Returns the native token-query failure when elevation cannot be determined.
pub fn process_is_elevated() -> io::Result<bool> {
    let mut token = ptr::null_mut();
    // SAFETY: GetCurrentProcess returns the current pseudo-handle and token is
    // a writable output pointer retained only for this synchronous call.
    let opened = unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) };
    if opened == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: successful OpenProcessToken produced one owned real handle.
    // The GetCurrentProcess pseudo-handle remains borrowed and is never adopted.
    let token = unsafe { OwnedHandle::from_raw_handle(token) };
    let mut elevation = TOKEN_ELEVATION::default();
    let mut returned = 0_u32;
    let size = u32::try_from(size_of::<TOKEN_ELEVATION>())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: token remains owned by the guard and elevation/returned are
    // writable buffers with the exact checked size for this synchronous query.
    let success = unsafe {
        GetTokenInformation(
            token.as_raw_handle(),
            TokenElevation,
            ptr::from_mut(&mut elevation).cast(),
            size,
            ptr::from_mut(&mut returned),
        )
    };
    if success == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(token_elevation_is_unsafe(elevation.TokenIsElevated))
    }
}

pub(crate) fn mark_file_delete(file: &File) -> io::Result<()> {
    let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
    let size = u32::try_from(size_of::<FILE_DISPOSITION_INFO>())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: file is a retained handle opened with DELETE access and
    // disposition is a fully initialized buffer of the exact checked size.
    let success = unsafe {
        SetFileInformationByHandle(
            file.as_raw_handle(),
            FileDispositionInfo,
            ptr::from_ref(&disposition).cast(),
            size,
        )
    };
    if success == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

pub(super) fn reject_remote_protocol_if_reported(file: &File) -> io::Result<()> {
    let mut info = FILE_REMOTE_PROTOCOL_INFO::default();
    let size = u32::try_from(size_of::<FILE_REMOTE_PROTOCOL_INFO>())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: file is a retained directory handle and info is a writable,
    // correctly aligned buffer of the exact checked size.
    let success = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle(),
            FileRemoteProtocolInfo,
            ptr::from_mut(&mut info).cast(),
            size,
        )
    };
    if success != 0 && info.Protocol != 0 {
        Err(io::Error::from_raw_os_error(53))
    } else {
        Ok(())
    }
}

pub(super) fn traversal_parts(path: &Path) -> io::Result<(PathBuf, Vec<std::ffi::OsString>)> {
    let mut components = path.components();
    let Some(Component::Prefix(prefix)) = components.next() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "parent path must start at a local drive root",
        ));
    };
    match prefix.kind() {
        Prefix::Disk(_) | Prefix::VerbatimDisk(_) => {}
        Prefix::UNC(_, _) | Prefix::VerbatimUNC(_, _) => {
            return Err(io::Error::from_raw_os_error(53));
        }
        _ => return Err(io::Error::from_raw_os_error(53)),
    }
    let Some(Component::RootDir) = components.next() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "parent path is not rooted",
        ));
    };
    let mut root = PathBuf::new();
    root.push(prefix.as_os_str());
    root.push(Component::RootDir.as_os_str());
    let mut normal = Vec::new();
    for component in components {
        match component {
            Component::Normal(value) => normal.push(value.to_os_string()),
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "parent path contains unsupported components",
                ));
            }
        }
    }
    Ok((root, normal))
}

fn open_root_directory(path: &Path, share: u32) -> io::Result<File> {
    OpenOptions::new()
        .access_mode(FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE)
        .share_mode(share)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
}

pub(super) fn open_private_root_directory(path: &Path) -> io::Result<File> {
    use windows_sys::Win32::Storage::FileSystem::READ_CONTROL;
    OpenOptions::new()
        .access_mode(FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE)
        .share_mode(SHARE_READ_WRITE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
}

pub(super) fn validate_directory_handle(file: &File) -> io::Result<()> {
    let metadata = file.metadata()?;
    if metadata.is_dir() && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0 {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "parent component must be a non-reparse directory",
        ))
    }
}

pub(crate) fn open_entry(
    parent: &NativeParent,
    leaf: &[u16],
    delete_access: bool,
) -> io::Result<File> {
    let access = FILE_READ_ATTRIBUTES | SYNCHRONIZE | if delete_access { DELETE } else { 0 };
    let share = if delete_access {
        SHARE_READ_WRITE
    } else {
        SHARE_ALL
    };
    open_relative(
        parent.file(),
        leaf,
        access,
        share,
        FILE_OPEN,
        FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
    )
}

/// Retains the selected parent directory while the save dialog is still
/// active, so later writes cannot be redirected by replacing a path component
/// after the dialog returns.
#[cfg(test)]
pub(crate) fn prepare_text_export_target(path: &Path) -> io::Result<TextExportTarget> {
    let parent_path = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "text export destination must have a parent directory",
        )
    })?;
    let leaf = path.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "text export destination must have a file name",
        )
    })?;
    prepare_text_export_parent_from_path(parent_path)?.target_for_test_leaf(leaf)
}

pub(crate) fn prepare_text_export_parent(
    path: &Path,
    shell_volume_id: u128,
    shell_file_reference: u64,
) -> io::Result<TextExportParent> {
    prepare_text_export_parent_impl(path, Some((shell_volume_id, shell_file_reference)))
}

#[cfg(test)]
pub(crate) fn prepare_text_export_parent_from_path(path: &Path) -> io::Result<TextExportParent> {
    prepare_text_export_parent_impl(path, None)
}

fn prepare_text_export_parent_impl(
    path: &Path,
    shell_identity: Option<(u128, u64)>,
) -> io::Result<TextExportParent> {
    reject_unsupported_drive_type(path)?;
    let (root, components) = traversal_parts(path)?;
    let capacity = components
        .len()
        .checked_add(1)
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let mut directories = Vec::new();
    directories
        .try_reserve_exact(capacity)
        .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;

    let root_file = open_root_directory(&root, SHARE_READ_WRITE)?;
    validate_directory_handle(&root_file)?;
    reject_case_sensitive_directory(&root_file)?;
    reject_remote_protocol_if_reported(&root_file)?;
    reject_unsupported_filesystem(&root_file)?;
    let root_identity = file_identity(&root_file)?;
    let shell_directory = shell_identity
        .map(|(volume_id, file_reference)| {
            if ntfs_volume_id(&root_file)? != volume_id {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "the save folder volume no longer matches the selected shell volume",
                ));
            }
            open_directory_by_file_reference(&root_file, file_reference)
        })
        .transpose()?;
    let shell_identity = shell_directory.as_ref().map(file_identity).transpose()?;
    directories.push(NativeParent {
        file: root_file,
        identity: root_identity,
    });

    for component in components {
        let leaf = component.encode_wide().collect::<Vec<_>>();
        let parent = directories
            .last()
            .ok_or_else(|| io::Error::other("text export directory chain is empty"))?;
        let file = open_relative(
            parent.file(),
            &leaf,
            FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            SHARE_READ_WRITE,
            FILE_OPEN,
            FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
        )?;
        validate_directory_handle(&file)?;
        reject_case_sensitive_directory(&file)?;
        reject_remote_protocol_if_reported(&file)?;
        let identity = file_identity(&file)?;
        directories.push(NativeParent { file, identity });
    }
    let final_directory = directories
        .last()
        .ok_or_else(|| io::Error::other("text export directory chain is empty"))?;
    reject_unsupported_filesystem(final_directory.file())?;
    if let Some(shell_identity) = shell_identity
        && final_directory.identity != shell_identity
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "the save folder path no longer identifies the selected shell folder",
        ));
    }
    Ok(TextExportParent {
        directories: Arc::new(directories),
    })
}

impl TextExportParent {
    pub(crate) fn ntfs_file_reference_number(&self) -> io::Result<u64> {
        let final_directory = self
            .directories
            .last()
            .ok_or_else(|| io::Error::other("text export directory chain is empty"))?;
        ntfs_file_reference_number(final_directory.file())
    }

    /// Creates a new export file relative to the retained directory chain.
    ///
    /// The leaf must be a single Windows name. The open is exclusive and does
    /// not follow a reparse point, so the selected directory cannot be
    /// replaced through its former path while the file is created or written.
    pub(crate) fn create_new_file(&self, leaf: &OsStr) -> io::Result<File> {
        let leaf = validated_text_export_leaf(leaf)?;
        let parent = self
            .directories
            .last()
            .ok_or_else(|| io::Error::other("text export directory chain is empty"))?;
        let file = open_relative(
            parent.file(),
            &leaf,
            DELETE | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            0,
            FILE_CREATE,
            FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
        )?;
        if let Err(error) = validate_text_export_file(&file) {
            let _ = mark_file_delete(&file);
            return Err(error);
        }
        Ok(file)
    }

    pub(crate) fn target_for_leaf(
        &self,
        leaf: &OsStr,
        shell_identity: Option<(u128, u64)>,
    ) -> io::Result<TextExportTarget> {
        self.target_for_leaf_impl(leaf, shell_identity, true)
    }

    #[cfg(test)]
    fn target_for_test_leaf(&self, leaf: &OsStr) -> io::Result<TextExportTarget> {
        self.target_for_leaf_impl(leaf, None, false)
    }

    fn target_for_leaf_impl(
        &self,
        leaf: &OsStr,
        shell_identity: Option<(u128, u64)>,
        require_shell_identity: bool,
    ) -> io::Result<TextExportTarget> {
        let leaf = validated_text_export_leaf(leaf)?;
        let parent = self
            .directories
            .last()
            .ok_or_else(|| io::Error::other("text export directory chain is empty"))?;
        // This check improves the dialog error; only the final handle-relative
        // no-replace rename authorizes creation, even after a namespace change.
        if require_shell_identity && shell_identity.is_some() {
            return Err(text_export_existing_target_error());
        }
        match open_relative(
            parent.file(),
            &leaf,
            FILE_READ_ATTRIBUTES,
            SHARE_ALL,
            FILE_OPEN,
            FILE_OPEN_REPARSE_POINT,
        ) {
            Ok(_) => return Err(text_export_existing_target_error()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        };
        Ok(TextExportTarget {
            parents: Arc::clone(&self.directories),
            leaf,
        })
    }
}

fn validated_text_export_leaf(leaf: &OsStr) -> io::Result<Vec<u16>> {
    let leaf = leaf.encode_wide().collect::<Vec<_>>();
    if leaf.is_empty()
        || leaf.len() > MAX_WINDOWS_LEAF_NAME_UTF16_UNITS
        || leaf
            .iter()
            .any(|unit| matches!(*unit, 0 | 0x2F | 0x5C | 0x3A))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "text export destination has an invalid file name",
        ));
    }
    Ok(leaf)
}

fn text_export_existing_target_error() -> io::Error {
    io::Error::new(
        io::ErrorKind::AlreadyExists,
        "기존 파일은 덮어쓰지 않습니다. 사용하지 않는 새 파일 이름을 선택해 주세요.",
    )
}

fn open_directory_by_file_reference(volume: &File, file_reference: u64) -> io::Result<File> {
    let descriptor = FILE_ID_DESCRIPTOR {
        dwSize: u32::try_from(size_of::<FILE_ID_DESCRIPTOR>())
            .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?,
        Type: FileIdType,
        Anonymous: windows_sys::Win32::Storage::FileSystem::FILE_ID_DESCRIPTOR_0 {
            FileId: i64::from_ne_bytes(file_reference.to_ne_bytes()),
        },
    };
    // SAFETY: volume is a retained handle on the selected NTFS volume;
    // descriptor is a live, correctly sized 64-bit FileId descriptor; the
    // returned handle is checked before its single ownership transfer.
    let file = unsafe {
        let handle = OpenFileById(
            volume.as_raw_handle(),
            ptr::from_ref(&descriptor),
            FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            SHARE_READ_WRITE,
            ptr::null(),
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        );
        if handle == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        File::from_raw_handle(handle)
    };
    validate_directory_handle(&file)?;
    reject_case_sensitive_directory(&file)?;
    reject_remote_protocol_if_reported(&file)?;
    reject_unsupported_filesystem(&file)?;
    Ok(file)
}

fn ntfs_file_reference_number(file: &File) -> io::Result<u64> {
    let mut status_block = IO_STATUS_BLOCK::default();
    let mut information = FILE_INTERNAL_INFORMATION::default();
    let length = u32::try_from(size_of::<FILE_INTERNAL_INFORMATION>())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: file is the retained final NTFS directory handle, and both
    // output buffers are writable, correctly aligned, and exactly sized for
    // this synchronous FileInternalInformation query.
    let (status, error_code) = unsafe {
        let status = NtQueryInformationFile(
            file.as_raw_handle(),
            ptr::from_mut(&mut status_block),
            ptr::from_mut(&mut information).cast(),
            length,
            FileInternalInformation,
        );
        let error_code = (status < 0).then(|| RtlNtStatusToDosErrorNoTeb(status));
        (status, error_code)
    };
    if status < 0 {
        let code = error_code.ok_or_else(|| io::Error::other("missing native error code"))?;
        return Err(io::Error::from_raw_os_error(
            i32::try_from(code).unwrap_or(i32::MAX),
        ));
    }
    Ok(file_reference_number_from_index_number(
        information.IndexNumber,
    ))
}

const fn file_reference_number_from_index_number(index_number: i64) -> u64 {
    u64::from_ne_bytes(index_number.to_ne_bytes())
}

fn ntfs_volume_id(root: &File) -> io::Result<u128> {
    parse_volume_guid_path(&normalized_final_path(
        root,
        FILE_NAME_NORMALIZED | VOLUME_NAME_GUID,
    )?)
}

fn parse_volume_guid_path(path: &[u16]) -> io::Result<u128> {
    const PREFIX: &[u8] = br"\\?\Volume{";
    if path.len() < PREFIX.len() + 37
        || !path
            .iter()
            .zip(PREFIX)
            .all(|(unit, expected)| *unit == u16::from(*expected))
    {
        return Err(io::Error::from(io::ErrorKind::InvalidData));
    }
    let guid = &path[PREFIX.len()..PREFIX.len() + 36];
    if path[PREFIX.len() + 36] != b'}' as u16 {
        return Err(io::Error::from(io::ErrorKind::InvalidData));
    }
    let mut value = 0_u128;
    for (index, unit) in guid.iter().copied().enumerate() {
        if matches!(index, 8 | 13 | 18 | 23) {
            if unit != b'-' as u16 {
                return Err(io::Error::from(io::ErrorKind::InvalidData));
            }
            continue;
        }
        let digit = match unit {
            0x30..=0x39 => u128::from(unit - 0x30),
            0x41..=0x46 => u128::from(unit - 0x41 + 10),
            0x61..=0x66 => u128::from(unit - 0x61 + 10),
            _ => return Err(io::Error::from(io::ErrorKind::InvalidData)),
        };
        value = value
            .checked_mul(16)
            .and_then(|value| value.checked_add(digit))
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?;
    }
    Ok(value)
}

pub(crate) fn write_text_export_target(target: TextExportTarget, bytes: &[u8]) -> io::Result<()> {
    write_text_export_target_inner(target, bytes, || Ok(()))
}

#[cfg(test)]
pub(crate) fn write_text_export_target_with_before_commit<F>(
    target: TextExportTarget,
    bytes: &[u8],
    before_commit: F,
) -> io::Result<()>
where
    F: FnOnce() -> io::Result<()>,
{
    write_text_export_target_inner(target, bytes, before_commit)
}

fn write_text_export_target_inner<F>(
    target: TextExportTarget,
    bytes: &[u8],
    before_commit: F,
) -> io::Result<()>
where
    F: FnOnce() -> io::Result<()>,
{
    let parent = target
        .parents
        .last()
        .ok_or_else(|| io::Error::other("text export directory chain is empty"))?;
    let (_stage_leaf, mut stage) = create_text_export_stage(parent.file())?;
    let result = (|| {
        validate_text_export_file(&stage)?;
        stage.write_all(bytes)?;
        stage.flush()?;
        stage.sync_all()?;
        before_commit()?;
        validate_text_export_file(&stage)?;
        // Keep the exclusive staging handle live through the native operation.
        // Its inherited DACL is also the intended new destination's DACL;
        // no protected existing file is replaced or borrowed for its metadata.
        rename_noreplace(&stage, parent.file(), &target.leaf)
    })();
    if result.is_err() {
        // The retained handle is the owned stage, even if its name changed.
        // Never reopen a temporary pathname to delete a possible substitute.
        mark_file_delete(&stage).map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("내보내기를 완료하지 못했고 임시 파일도 정리하지 못했습니다: {error}"),
            )
        })?;
    }
    result
}

fn create_text_export_stage(parent: &File) -> io::Result<(Vec<u16>, File)> {
    for _ in 0..4 {
        let leaf = text_export_temporary_leaf("stage")?;
        match open_relative(
            parent,
            &leaf,
            FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | DELETE | SYNCHRONIZE,
            0,
            FILE_CREATE,
            FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
        ) {
            Ok(file) => return Ok((leaf, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not reserve a unique text export staging file",
    ))
}

fn text_export_temporary_leaf(kind: &str) -> io::Result<Vec<u16>> {
    let guid = windows_core::GUID::new().map_err(|error| io::Error::other(error.to_string()))?;
    let leaf = format!(".darkrenamer-text-export-{kind}-{guid:?}.tmp");
    let leaf = leaf.encode_utf16().collect::<Vec<_>>();
    if leaf.len() > MAX_WINDOWS_LEAF_NAME_UTF16_UNITS {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "text export temporary name exceeds the Windows leaf limit",
        ));
    }
    Ok(leaf)
}

/// Writes complete output to an exclusively held sibling, then commits a
/// new destination with a handle-relative no-replace rename.
#[cfg(test)]
pub(crate) fn write_text_export(path: &Path, bytes: &[u8]) -> io::Result<()> {
    write_text_export_target(prepare_text_export_target(path)?, bytes)
}

pub(crate) fn file_is_single_linked(file: &File) -> io::Result<bool> {
    let info = file_standard_info(file)?;
    Ok(!info.Directory && !info.DeletePending && info.NumberOfLinks == 1)
}

fn file_standard_info(file: &File) -> io::Result<FILE_STANDARD_INFO> {
    let mut info = FILE_STANDARD_INFO::default();
    let size = u32::try_from(size_of::<FILE_STANDARD_INFO>())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: file is a retained handle and info is a writable,
    // correctly aligned FILE_STANDARD_INFO buffer of its checked size.
    let success = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle(),
            FileStandardInfo,
            ptr::from_mut(&mut info).cast(),
            size,
        )
    };
    if success == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(info)
}

fn validate_text_export_file(file: &File) -> io::Result<()> {
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "text export destination must be a regular, unlinked file",
        ));
    }
    if !file_is_single_linked(file)? {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "text export destination must be a regular, unlinked file",
        ));
    }
    Ok(())
}

pub(crate) fn normalized_final_leaf(file: &File) -> io::Result<Vec<u16>> {
    normalized_leaf_from_final_path(&normalized_final_path(
        file,
        FILE_NAME_NORMALIZED | VOLUME_NAME_NONE,
    )?)
}

fn normalized_final_path(file: &File, flags: u32) -> io::Result<Vec<u16>> {
    let mut capacity = checked_final_path_capacity(query_final_path(file, &mut [], flags))?;
    for _ in 0..2 {
        let mut path = Vec::new();
        path.try_reserve_exact(capacity)
            .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
        path.resize(capacity, 0);
        let written = query_final_path(file, &mut path, flags);
        if written == 0 {
            return Err(io::Error::last_os_error());
        }
        let written = usize::try_from(written)
            .map_err(|_| io::Error::from_raw_os_error(ERROR_FILENAME_EXCED_RANGE))?;
        if written < capacity {
            path.truncate(written);
            return Ok(path);
        }
        capacity = checked_final_path_capacity(
            u32::try_from(written)
                .map_err(|_| io::Error::from_raw_os_error(ERROR_FILENAME_EXCED_RANGE))?,
        )?;
    }
    Err(io::Error::from_raw_os_error(ERROR_FILENAME_EXCED_RANGE))
}

fn query_final_path(file: &File, buffer: &mut [u16], flags: u32) -> u32 {
    let capacity = u32::try_from(buffer.len()).unwrap_or(0);
    let output = if buffer.is_empty() {
        ptr::null_mut()
    } else {
        buffer.as_mut_ptr()
    };
    // SAFETY: file remains live for the synchronous query; output is either
    // null with zero capacity or writable for the exact checked slice length.
    unsafe { GetFinalPathNameByHandleW(file.as_raw_handle(), output, capacity, flags) }
}

fn checked_final_path_capacity(required: u32) -> io::Result<usize> {
    if required == 0 {
        return Err(io::Error::last_os_error());
    }
    if required > MAX_NORMALIZED_FINAL_PATH_UTF16_UNITS {
        return Err(io::Error::from_raw_os_error(ERROR_FILENAME_EXCED_RANGE));
    }
    usize::try_from(required).map_err(|_| io::Error::from_raw_os_error(ERROR_FILENAME_EXCED_RANGE))
}

fn normalized_leaf_from_final_path(path: &[u16]) -> io::Result<Vec<u16>> {
    let separator = path
        .iter()
        .rposition(|unit| *unit == b'\\' as u16)
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?;
    let leaf = &path[separator + 1..];
    if leaf.is_empty() || leaf.len() > MAX_WINDOWS_LEAF_NAME_UTF16_UNITS || leaf.contains(&0) {
        return Err(io::Error::from(io::ErrorKind::InvalidData));
    }
    let mut normalized = Vec::new();
    normalized
        .try_reserve_exact(leaf.len())
        .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
    normalized.extend_from_slice(leaf);
    Ok(normalized)
}

pub(crate) fn open_directory_entry(parent: &NativeParent, leaf: &[u16]) -> io::Result<File> {
    open_relative(
        parent.file(),
        leaf,
        FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        SHARE_ALL,
        FILE_OPEN,
        FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
    )
}

pub(crate) fn query_directory_names(
    directory: &File,
    limit: usize,
    path_prefix_units: usize,
    remaining_path_bytes: usize,
) -> io::Result<(Vec<Vec<u16>>, bool, bool)> {
    match query_directory_names_cancellable(
        directory,
        limit,
        path_prefix_units,
        remaining_path_bytes,
        &|| false,
    ) {
        Ok(result) => Ok(result),
        Err(DirectoryQueryError::Io(error)) => Err(error),
        Err(DirectoryQueryError::Cancelled) => {
            unreachable!("the non-cancellable directory query cannot be cancelled")
        }
    }
}

pub(crate) enum DirectoryQueryError {
    Cancelled,
    Io(io::Error),
}

fn validated_directory_name_units(
    bytes_written: usize,
    buffer_bytes: usize,
    file_name_bytes: u32,
    name_capacity: usize,
) -> io::Result<usize> {
    let fixed_bytes = offset_of!(FILE_ID_BOTH_DIR_INFORMATION, FileName);
    let file_name_bytes = usize::try_from(file_name_bytes)
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
    let returned_name_bytes = bytes_written
        .checked_sub(fixed_bytes)
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?;
    let maximum_name_bytes = name_capacity
        .checked_mul(size_of::<u16>())
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?;
    if bytes_written > buffer_bytes
        || file_name_bytes == 0
        || file_name_bytes % size_of::<u16>() != 0
        || file_name_bytes > returned_name_bytes
        || file_name_bytes > maximum_name_bytes
    {
        return Err(io::Error::from(io::ErrorKind::InvalidData));
    }
    Ok(file_name_bytes / size_of::<u16>())
}

fn reserve_complete_child_path_bytes(
    path_prefix_units: usize,
    name_units: usize,
    remaining_path_bytes: &mut usize,
) -> bool {
    let Some(path_bytes) = path_prefix_units
        .checked_add(name_units)
        .and_then(|units| units.checked_mul(size_of::<u16>()))
    else {
        return false;
    };
    if path_bytes > *remaining_path_bytes {
        return false;
    }
    *remaining_path_bytes -= path_bytes;
    true
}

impl From<io::Error> for DirectoryQueryError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

// Own the complete flexible-array storage as a Rust field. The SDK record's
// one-element FileName cannot be used to form a longer Rust slice.
#[repr(C)]
struct DirectoryNameBuffer {
    next_entry_offset: u32,
    file_index: u32,
    creation_time: i64,
    last_access_time: i64,
    last_write_time: i64,
    change_time: i64,
    end_of_file: i64,
    allocation_size: i64,
    file_attributes: u32,
    file_name_length: u32,
    ea_size: u32,
    short_name_length: i8,
    short_name: [u16; 12],
    file_id: i64,
    file_name: [u16; MAX_WINDOWS_LEAF_NAME_UTF16_UNITS],
}

impl DirectoryNameBuffer {
    fn empty() -> Self {
        Self {
            next_entry_offset: 0,
            file_index: 0,
            creation_time: 0,
            last_access_time: 0,
            last_write_time: 0,
            change_time: 0,
            end_of_file: 0,
            allocation_size: 0,
            file_attributes: 0,
            file_name_length: 0,
            ea_size: 0,
            short_name_length: 0,
            short_name: [0; 12],
            file_id: 0,
            file_name: [0; MAX_WINDOWS_LEAF_NAME_UTF16_UNITS],
        }
    }

    fn name(&self, bytes_written: usize) -> io::Result<&[u16]> {
        if self.next_entry_offset != 0 {
            return Err(io::Error::from(io::ErrorKind::InvalidData));
        }
        let units = validated_directory_name_units(
            bytes_written,
            Self::os_bytes(),
            self.file_name_length,
            self.file_name.len(),
        )?;
        Ok(&self.file_name[..units])
    }

    const fn os_bytes() -> usize {
        offset_of!(Self, file_name) + MAX_WINDOWS_LEAF_NAME_UTF16_UNITS * size_of::<u16>()
    }
}

const _: () = {
    assert!(align_of::<DirectoryNameBuffer>() == align_of::<FILE_ID_BOTH_DIR_INFORMATION>());
    assert!(
        offset_of!(DirectoryNameBuffer, next_entry_offset)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, NextEntryOffset)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, file_index)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, FileIndex)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, creation_time)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, CreationTime)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, last_access_time)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, LastAccessTime)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, last_write_time)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, LastWriteTime)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, change_time)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, ChangeTime)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, end_of_file)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, EndOfFile)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, allocation_size)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, AllocationSize)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, file_attributes)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, FileAttributes)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, file_name_length)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, FileNameLength)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, ea_size)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, EaSize)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, short_name_length)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, ShortNameLength)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, short_name)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, ShortName)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, file_id)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, FileId)
    );
    assert!(
        offset_of!(DirectoryNameBuffer, file_name)
            == offset_of!(FILE_ID_BOTH_DIR_INFORMATION, FileName)
    );
    assert!(DirectoryNameBuffer::os_bytes() <= size_of::<DirectoryNameBuffer>());
};

pub(crate) fn query_directory_names_cancellable(
    directory: &File,
    limit: usize,
    path_prefix_units: usize,
    mut remaining_path_bytes: usize,
    cancellation_requested: &dyn Fn() -> bool,
) -> Result<(Vec<Vec<u16>>, bool, bool), DirectoryQueryError> {
    let bytes = DirectoryNameBuffer::os_bytes();
    let buffer_size =
        u32::try_from(bytes).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let mut names = Vec::new();
    let maximum_budgeted_names = path_prefix_units
        .checked_add(1)
        .and_then(|units| units.checked_mul(size_of::<u16>()))
        .map_or(0, |minimum_path_bytes| {
            remaining_path_bytes / minimum_path_bytes
        });
    names
        .try_reserve(limit.min(maximum_budgeted_names))
        .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
    let mut restart = true;
    loop {
        // Clear each result so short or inconsistent output cannot reuse stale data.
        let mut buffer = DirectoryNameBuffer::empty();
        if cancellation_requested() {
            return Err(DirectoryQueryError::Cancelled);
        }
        let mut status_block = IO_STATUS_BLOCK::default();
        // SAFETY: directory is a retained directory handle; buffer and status
        // block are writable and correctly sized. Single-entry mode bounds each
        // result and the call retains no pointers.
        let status = unsafe {
            NtQueryDirectoryFile(
                directory.as_raw_handle(),
                ptr::null_mut(),
                None,
                ptr::null(),
                ptr::from_mut(&mut status_block),
                ptr::from_mut(&mut buffer).cast(),
                buffer_size,
                FileIdBothDirectoryInformation,
                true,
                ptr::null(),
                restart,
            )
        };
        if cancellation_requested() {
            return Err(DirectoryQueryError::Cancelled);
        }
        restart = false;
        if status == STATUS_NO_MORE_FILES {
            return Ok((names, false, false));
        }
        if status < 0 {
            // SAFETY: status came directly from NtQueryDirectoryFile.
            let code = unsafe { RtlNtStatusToDosErrorNoTeb(status) };
            return Err(DirectoryQueryError::Io(io::Error::from_raw_os_error(
                i32::try_from(code).unwrap_or(i32::MAX),
            )));
        }
        let name = buffer.name(status_block.Information)?;
        let name_units = name.len();
        if name == [b'.' as u16] || name == [b'.' as u16, b'.' as u16] {
            continue;
        }
        if names.len() >= limit {
            return Ok((names, true, false));
        }
        if !reserve_complete_child_path_bytes(
            path_prefix_units,
            name_units,
            &mut remaining_path_bytes,
        ) {
            return Ok((names, false, true));
        }
        let mut retained_name = Vec::new();
        retained_name
            .try_reserve_exact(name_units)
            .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
        retained_name.extend_from_slice(name);
        names.push(retained_name);
    }
}

pub(crate) fn create_file_relative_exclusive(root: &File, leaf: &str) -> io::Result<File> {
    let encoded = leaf.encode_utf16().collect::<Vec<_>>();
    open_relative(
        root,
        &encoded,
        DELETE | FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        0,
        FILE_CREATE,
        FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
    )
}

pub(crate) fn open_file_relative_exclusive(root: &File, leaf: &str) -> io::Result<File> {
    let encoded = leaf.encode_utf16().collect::<Vec<_>>();
    open_relative(
        root,
        &encoded,
        DELETE | FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        0,
        FILE_OPEN,
        FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
    )
}

pub(super) fn open_relative(
    parent: &File,
    leaf: &[u16],
    desired_access: u32,
    share_access: u32,
    disposition: u32,
    options: u32,
) -> io::Result<File> {
    open_relative_with_security(
        parent,
        leaf,
        desired_access,
        share_access,
        disposition,
        options,
        ptr::null(),
    )
}

pub(super) fn open_relative_with_security(
    parent: &File,
    leaf: &[u16],
    desired_access: u32,
    share_access: u32,
    disposition: u32,
    options: u32,
    security_descriptor: *const std::ffi::c_void,
) -> io::Result<File> {
    if leaf.is_empty() || leaf.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "relative leaf is invalid",
        ));
    }
    let name_bytes = leaf
        .len()
        .checked_mul(size_of::<u16>())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "leaf is too large"))?;
    let name_length = u16::try_from(name_bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "leaf is too large"))?;
    let mut encoded = leaf.to_vec();
    let object_name = UNICODE_STRING {
        Length: name_length,
        MaximumLength: name_length,
        Buffer: encoded.as_mut_ptr(),
    };
    let object_attributes = OBJECT_ATTRIBUTES {
        Length: u32::try_from(size_of::<OBJECT_ATTRIBUTES>())
            .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?,
        RootDirectory: parent.as_raw_handle(),
        ObjectName: ptr::from_ref(&object_name),
        Attributes: OBJ_CASE_INSENSITIVE,
        SecurityDescriptor: security_descriptor.cast(),
        SecurityQualityOfService: ptr::null(),
    };
    let mut status_block = IO_STATUS_BLOCK::default();
    let mut handle = ptr::null_mut();

    // SAFETY: the retained parent handle, UTF-16 leaf buffer, object name, and
    // object attributes remain valid and immovable for this synchronous call.
    // Output pointers are writable and ownership transfers only on success.
    let status = unsafe {
        NtCreateFile(
            ptr::from_mut(&mut handle),
            desired_access,
            ptr::from_ref(&object_attributes),
            ptr::from_mut(&mut status_block),
            ptr::null(),
            0,
            share_access,
            disposition,
            options,
            ptr::null(),
            0,
        )
    };
    if status < 0 {
        // SAFETY: the status value came directly from NtCreateFile and has no
        // pointer or lifetime preconditions for conversion.
        let code = unsafe { RtlNtStatusToDosErrorNoTeb(status) };
        return Err(io::Error::from_raw_os_error(
            i32::try_from(code).unwrap_or(i32::MAX),
        ));
    }
    if handle.is_null() {
        return Err(io::Error::other("relative open returned no handle"));
    }
    // SAFETY: successful NtCreateFile returned one new owned handle, checked
    // non-null above, and this is its only ownership transfer.
    Ok(unsafe { File::from_raw_handle(handle) })
}

pub(crate) fn file_identity(file: &File) -> io::Result<NativeIdentity> {
    let mut info = FILE_ID_INFO::default();
    let size = u32::try_from(size_of::<FILE_ID_INFO>())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: the borrowed file handle remains live, and info is a writable,
    // correctly aligned FILE_ID_INFO buffer of the exact declared size.
    let success = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle(),
            FileIdInfo,
            ptr::from_mut(&mut info).cast(),
            size,
        )
    };
    if success == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(NativeIdentity {
        volume: info.VolumeSerialNumber,
        file_id: u128::from_le_bytes(info.FileId.Identifier),
    })
}

// Keep the SDK union and header ABI, but give the bounded leaf real storage.
#[repr(C)]
struct RenameBuffer {
    flags: FILE_RENAME_INFORMATION_0,
    root_directory: HANDLE,
    file_name_length: u32,
    file_name: [u16; MAX_WINDOWS_LEAF_NAME_UTF16_UNITS],
}

impl RenameBuffer {
    fn new(root_directory: HANDLE, leaf: &[u16]) -> io::Result<Self> {
        if leaf.is_empty() || leaf.len() > MAX_WINDOWS_LEAF_NAME_UTF16_UNITS || leaf.contains(&0) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "relative leaf is invalid",
            ));
        }
        let name_bytes = leaf
            .len()
            .checked_mul(size_of::<u16>())
            .and_then(|bytes| u32::try_from(bytes).ok())
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
        let mut buffer = Self {
            flags: FILE_RENAME_INFORMATION_0 { Flags: 0 },
            root_directory,
            file_name_length: name_bytes,
            file_name: [0; MAX_WINDOWS_LEAF_NAME_UTF16_UNITS],
        };
        buffer.file_name[..leaf.len()].copy_from_slice(leaf);
        Ok(buffer)
    }

    fn os_bytes(&self) -> io::Result<u32> {
        offset_of!(Self, file_name)
            .checked_add(self.file_name_length as usize)
            .and_then(|bytes| u32::try_from(bytes).ok())
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))
    }
}

const _: () = {
    assert!(align_of::<RenameBuffer>() == align_of::<FILE_RENAME_INFORMATION>());
    assert!(offset_of!(RenameBuffer, flags) == offset_of!(FILE_RENAME_INFORMATION, Anonymous));
    assert!(
        offset_of!(RenameBuffer, root_directory)
            == offset_of!(FILE_RENAME_INFORMATION, RootDirectory)
    );
    assert!(
        offset_of!(RenameBuffer, file_name_length)
            == offset_of!(FILE_RENAME_INFORMATION, FileNameLength)
    );
    assert!(offset_of!(RenameBuffer, file_name) == offset_of!(FILE_RENAME_INFORMATION, FileName));
    assert!(
        offset_of!(RenameBuffer, file_name) + MAX_WINDOWS_LEAF_NAME_UTF16_UNITS * size_of::<u16>()
            <= size_of::<RenameBuffer>()
    );
};

pub(crate) fn rename_noreplace(
    source: &File,
    destination_parent: &File,
    destination_leaf: &[u16],
) -> io::Result<()> {
    let buffer = RenameBuffer::new(destination_parent.as_raw_handle(), destination_leaf)?;
    let buffer_size = buffer.os_bytes()?;
    let mut status_block = IO_STATUS_BLOCK::default();
    // SAFETY: source and destination-parent handles remain live, buffer fields
    // and size are checked, flags omit replacement, and the native API is synchronous.
    let status = unsafe {
        NtSetInformationFile(
            source.as_raw_handle(),
            ptr::from_mut(&mut status_block),
            ptr::from_ref(&buffer).cast(),
            buffer_size,
            FileRenameInformation,
        )
    };
    if status < 0 {
        // SAFETY: the status value came directly from NtSetInformationFile.
        let code = unsafe { RtlNtStatusToDosErrorNoTeb(status) };
        Err(io::Error::from_raw_os_error(
            i32::try_from(code).unwrap_or(i32::MAX),
        ))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rename_buffer_bounds_preserve_exact_units_and_os_length() -> io::Result<()> {
        for leaf in [
            vec![0xd800],
            vec![0xdc00; MAX_WINDOWS_LEAF_NAME_UTF16_UNITS],
        ] {
            let buffer = RenameBuffer::new(ptr::null_mut(), &leaf)?;
            assert_eq!(&buffer.file_name[..leaf.len()], leaf);
            assert_eq!(
                buffer.file_name_length as usize,
                leaf.len() * size_of::<u16>()
            );
            assert_eq!(
                buffer.os_bytes()? as usize,
                offset_of!(FILE_RENAME_INFORMATION, FileName) + leaf.len() * size_of::<u16>()
            );
            assert!(buffer.os_bytes()? as usize <= size_of::<RenameBuffer>());
        }
        for leaf in [
            vec![],
            vec![0],
            vec![65; MAX_WINDOWS_LEAF_NAME_UTF16_UNITS + 1],
        ] {
            assert!(matches!(RenameBuffer::new(ptr::null_mut(), &leaf),
                Err(error) if error.kind() == io::ErrorKind::InvalidInput));
        }
        Ok(())
    }

    #[test]
    fn directory_buffer_rejects_inconsistent_results_and_preserves_surrogates() -> io::Result<()> {
        let fixed_bytes = offset_of!(FILE_ID_BOTH_DIR_INFORMATION, FileName);
        let mut buffer = DirectoryNameBuffer::empty();
        assert!(buffer.name(0).is_err());
        for units in [1, MAX_WINDOWS_LEAF_NAME_UTF16_UNITS] {
            buffer.file_name.fill(0xd800);
            buffer.file_name_length = (units * size_of::<u16>()) as u32;
            assert_eq!(
                buffer.name(fixed_bytes + units * size_of::<u16>())?,
                vec![0xd800; units]
            );
            assert!(
                buffer
                    .name(fixed_bytes + units * size_of::<u16>() - 1)
                    .is_err()
            );
        }
        buffer.file_name_length = 2;
        buffer.next_entry_offset = 8;
        assert!(buffer.name(fixed_bytes + 2).is_err());
        buffer.next_entry_offset = 0;
        buffer.file_name_length = 3;
        assert!(buffer.name(fixed_bytes + 3).is_err());
        buffer.file_name_length =
            ((MAX_WINDOWS_LEAF_NAME_UTF16_UNITS + 1) * size_of::<u16>()) as u32;
        assert!(buffer.name(DirectoryNameBuffer::os_bytes()).is_err());
        buffer.file_name_length = 2;
        assert!(buffer.name(DirectoryNameBuffer::os_bytes() + 1).is_err());
        Ok(())
    }

    #[test]
    fn ntfs_file_reference_preserves_the_64_bit_index_number_bit_pattern() {
        assert_eq!(
            file_reference_number_from_index_number(0x1234_5678_9abc_def0),
            0x1234_5678_9abc_def0
        );
        assert_eq!(file_reference_number_from_index_number(-1), u64::MAX);
    }

    #[test]
    fn retained_export_parent_creates_a_new_leaf_without_reopening_its_path()
    -> Result<(), Box<dyn std::error::Error>> {
        let temporary = tempfile::tempdir()?;
        let selected = temporary.path().join("selected");
        let moved = temporary.path().join("moved");
        std::fs::create_dir(&selected)?;
        let parent = prepare_text_export_parent_from_path(&selected)?;

        assert!(std::fs::rename(&selected, &moved).is_err());

        let leaf = OsStr::new("active.drj.retained");
        let mut output = parent.create_new_file(leaf)?;
        output.write_all(b"retained journal bytes")?;
        output.sync_all()?;
        drop(output);

        assert_eq!(
            std::fs::read(selected.join(leaf))?,
            b"retained journal bytes"
        );
        assert!(matches!(
            parent.create_new_file(leaf),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists
        ));
        assert!(matches!(
            parent.create_new_file(OsStr::new("../outside.drj")),
            Err(error) if error.kind() == io::ErrorKind::InvalidInput
        ));
        Ok(())
    }

    #[test]
    fn volume_guid_parser_accepts_canonical_guid_paths_and_rejects_other_values() -> io::Result<()>
    {
        let path = r"\\?\Volume{01234567-89ab-cdef-0123-456789abcdef}\"
            .encode_utf16()
            .collect::<Vec<_>>();
        assert_eq!(
            parse_volume_guid_path(&path)?,
            0x01234567_89ab_cdef_0123_456789abcdef
        );
        assert!(parse_volume_guid_path(&"C:\\".encode_utf16().collect::<Vec<_>>()).is_err());
        Ok(())
    }

    #[test]
    fn normalized_final_path_capacity_is_bounded() -> Result<(), Box<dyn std::error::Error>> {
        assert_eq!(
            checked_final_path_capacity(MAX_NORMALIZED_FINAL_PATH_UTF16_UNITS)?,
            MAX_NORMALIZED_FINAL_PATH_UTF16_UNITS as usize
        );
        let Err(error) =
            checked_final_path_capacity(MAX_NORMALIZED_FINAL_PATH_UTF16_UNITS.saturating_add(1))
        else {
            return Err(io::Error::other("oversized normalized path was accepted").into());
        };
        assert_eq!(error.raw_os_error(), Some(ERROR_FILENAME_EXCED_RANGE));
        Ok(())
    }

    #[test]
    fn normalized_final_path_preserves_the_complete_path() -> io::Result<()> {
        let directory = tempfile::tempdir()?;
        let file_path = directory.path().join("normalized-path.txt");
        let file = File::create(&file_path)?;

        let normalized_path =
            normalized_final_path(&file, FILE_NAME_NORMALIZED | VOLUME_NAME_GUID)?;
        let normalized_path = String::from_utf16(&normalized_path)
            .map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;

        assert!(normalized_path.starts_with(r"\\?\Volume{"));
        assert!(normalized_path.ends_with(r"\normalized-path.txt"));
        Ok(())
    }

    #[test]
    fn normalized_final_path_extracts_one_bounded_leaf() -> Result<(), Box<dyn std::error::Error>> {
        let path = r"\parent\normalized-name.txt"
            .encode_utf16()
            .collect::<Vec<_>>();
        assert_eq!(
            normalized_leaf_from_final_path(&path)?,
            "normalized-name.txt".encode_utf16().collect::<Vec<_>>()
        );
        for invalid in [
            Vec::new(),
            r"\parent\".encode_utf16().collect::<Vec<_>>(),
            format!(
                r"\parent\{}",
                "x".repeat(MAX_WINDOWS_LEAF_NAME_UTF16_UNITS + 1)
            )
            .encode_utf16()
            .collect::<Vec<_>>(),
        ] {
            assert!(normalized_leaf_from_final_path(&invalid).is_err());
        }
        Ok(())
    }
    use windows_sys::Win32::System::WindowsProgramming::{
        DRIVE_NO_ROOT_DIR, DRIVE_REMOTE, DRIVE_UNKNOWN,
    };

    #[test]
    fn directory_name_length_rejects_zero_byte_success_and_stale_buffer_content() {
        let fixed_bytes = offset_of!(FILE_ID_BOTH_DIR_INFORMATION, FileName);
        assert!(validated_directory_name_units(0, 1024, 8, 255).is_err());
        assert!(validated_directory_name_units(fixed_bytes, 1024, 0, 255).is_err());
        assert!(validated_directory_name_units(fixed_bytes + 2, 1024, 4, 255).is_err());
    }

    #[test]
    fn directory_name_length_accepts_only_complete_bounded_utf16_names() -> io::Result<()> {
        let fixed_bytes = offset_of!(FILE_ID_BOTH_DIR_INFORMATION, FileName);
        assert_eq!(
            validated_directory_name_units(fixed_bytes + 8, 1024, 8, 255)?,
            4
        );
        assert!(validated_directory_name_units(fixed_bytes + 3, 1024, 3, 255).is_err());
        assert!(validated_directory_name_units(fixed_bytes + 512, 1024, 512, 255).is_err());
        assert!(validated_directory_name_units(1025, 1024, 2, 255).is_err());
        Ok(())
    }

    #[test]
    fn complete_child_path_budget_is_checked_before_reservation() {
        let mut remaining = 20;
        assert!(reserve_complete_child_path_bytes(4, 6, &mut remaining));
        assert_eq!(remaining, 0);
        assert!(!reserve_complete_child_path_bytes(0, 1, &mut remaining));
        assert_eq!(remaining, 0);

        let mut overflow_budget = usize::MAX;
        assert!(!reserve_complete_child_path_bytes(
            usize::MAX,
            1,
            &mut overflow_budget,
        ));
        assert_eq!(overflow_budget, usize::MAX);
    }

    #[test]
    fn case_sensitive_flag_interpretation_is_fail_closed() {
        assert!(!case_sensitive_flags_unsupported(0));
        assert!(case_sensitive_flags_unsupported(
            FILE_CS_FLAG_CASE_SENSITIVE_DIR
        ));
        assert!(case_sensitive_flags_unsupported(
            FILE_CS_FLAG_CASE_SENSITIVE_DIR | 0x8000_0000
        ));
    }

    #[test]
    fn filesystem_name_classifier_accepts_only_case_insensitive_ntfs() -> io::Result<()> {
        for name in ["NTFS", "ntfs", "NtFs"] {
            let mut buffer = [u16::MAX; FILESYSTEM_NAME_CAPACITY];
            for (target, source) in buffer.iter_mut().zip(name.encode_utf16()) {
                *target = source;
            }
            buffer[name.len()] = 0;
            validate_ntfs_query_result(Ok(()), &buffer)?;
        }
        Ok(())
    }

    #[test]
    fn filesystem_name_classifier_rejects_non_ntfs_empty_and_malformed_buffers()
    -> Result<(), Box<dyn std::error::Error>> {
        for buffer in [
            "ReFS\0".encode_utf16().collect::<Vec<_>>(),
            "exFAT\0".encode_utf16().collect::<Vec<_>>(),
            "FAT32\0".encode_utf16().collect::<Vec<_>>(),
            vec![0],
            "NTFS".encode_utf16().collect::<Vec<_>>(),
            vec![b'N' as u16, b'T' as u16, 0xd800, b'S' as u16, 0],
        ] {
            let Err(error) = validate_ntfs_query_result(Ok(()), &buffer) else {
                return Err(io::Error::other("unsupported filesystem data was accepted").into());
            };
            assert_eq!(error.raw_os_error(), Some(ERROR_UNRECOGNIZED_VOLUME));
        }
        Ok(())
    }

    #[test]
    fn filesystem_query_preserves_native_api_failure() -> Result<(), Box<dyn std::error::Error>> {
        let Err(error) = validate_ntfs_query_result(
            Err(io::Error::from_raw_os_error(5)),
            &[b'N' as u16, b'T' as u16, b'F' as u16, b'S' as u16, 0],
        ) else {
            return Err(io::Error::other("the filesystem query failure was ignored").into());
        };
        assert_eq!(error.raw_os_error(), Some(5));
        Ok(())
    }

    #[test]
    fn traversal_accepts_local_drive_and_rejects_unc_or_device_prefixes() {
        let local = traversal_parts(Path::new("C:\\parent\\child"));
        assert!(local.is_ok_and(|(root, components)| root.is_absolute() && components.len() == 2));
        assert_eq!(
            traversal_parts(Path::new("\\\\server\\share\\folder"))
                .err()
                .and_then(|error| error.raw_os_error()),
            Some(53)
        );
        assert_eq!(
            traversal_parts(Path::new("\\\\.\\C:\\folder"))
                .err()
                .and_then(|error| error.raw_os_error()),
            Some(53)
        );
    }

    #[test]
    fn drive_type_policy_rejects_remote_unknown_and_missing_roots() {
        assert!(drive_type_supported(DRIVE_FIXED));
        assert!(drive_type_supported(DRIVE_REMOVABLE));
        assert!(!drive_type_supported(DRIVE_REMOTE));
        assert!(!drive_type_supported(DRIVE_UNKNOWN));
        assert!(!drive_type_supported(DRIVE_NO_ROOT_DIR));
        assert!(!drive_type_supported(5));
        assert!(!drive_type_supported(6));
    }

    #[test]
    fn token_elevation_flag_is_fail_closed() {
        assert!(!token_elevation_is_unsafe(0));
        assert!(token_elevation_is_unsafe(1));
        assert!(token_elevation_is_unsafe(u32::MAX));
    }

    #[test]
    fn process_elevation_query_returns_a_structured_flag() {
        assert!(process_is_elevated().is_ok());
    }

    #[test]
    fn retained_delete_handle_cannot_delete_a_later_path_replacement()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("delete-by-handle.drj");
        std::fs::write(&path, b"journal")?;
        let file = OpenOptions::new()
            .access_mode(DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE)
            .share_mode(0)
            .open(&path)?;

        mark_file_delete(&file)?;
        assert!(std::fs::write(&path, b"replacement").is_err());
        drop(file);
        assert!(!path.exists());
        std::fs::write(&path, b"replacement")?;
        assert_eq!(std::fs::read(&path)?, b"replacement");
        Ok(())
    }

    #[test]
    fn rename_source_handle_blocks_competing_delete_share_changes_but_allows_reads()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let source_path = directory.path().join("source.txt");
        let moved_path = directory.path().join("moved.txt");
        std::fs::write(&source_path, b"source")?;
        let parent = NativeParent::open_path(directory.path())?;
        let leaf = "source.txt".encode_utf16().collect::<Vec<_>>();

        let source = open_entry(&parent, &leaf, true)?;
        let reader = File::open(&source_path)?;
        let rename_error = std::fs::rename(&source_path, &moved_path)
            .err()
            .ok_or_else(|| io::Error::other("competing rename bypassed source handle"))?;
        assert_eq!(rename_error.raw_os_error(), Some(32));
        let delete_error = std::fs::remove_file(&source_path)
            .err()
            .ok_or_else(|| io::Error::other("competing delete bypassed source handle"))?;
        assert_eq!(delete_error.raw_os_error(), Some(32));
        assert_eq!(std::fs::read(&source_path)?, b"source");

        drop(reader);
        drop(source);
        std::fs::rename(&source_path, &moved_path)?;
        assert_eq!(std::fs::read(&moved_path)?, b"source");
        Ok(())
    }
}
