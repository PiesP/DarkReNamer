//! Audited Windows handle-relative filesystem primitives.

use std::fs::{File, OpenOptions};
use std::io;
use std::mem::{offset_of, size_of};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::path::{Component, Path, PathBuf, Prefix};
use std::ptr;

use darknamer_core::LegacyText;
use windows_sys::Wdk::Foundation::OBJECT_ATTRIBUTES;
use windows_sys::Wdk::Storage::FileSystem::{
    FILE_CREATE, FILE_DIRECTORY_FILE, FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT,
    FILE_RENAME_INFORMATION, FILE_SYNCHRONOUS_IO_NONALERT, FileRenameInformation, NtCreateFile,
    NtSetInformationFile, RtlNtStatusToDosErrorNoTeb,
};
use windows_sys::Win32::Foundation::{OBJ_CASE_INSENSITIVE, UNICODE_STRING};
use windows_sys::Win32::Storage::FileSystem::{
    DELETE, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_ID_INFO, FILE_READ_ATTRIBUTES, FILE_READ_DATA, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, FILE_TRAVERSE, FILE_WRITE_DATA, FileIdInfo, GetFileInformationByHandleEx,
    SYNCHRONIZE,
};
use windows_sys::Win32::System::IO::IO_STATUS_BLOCK;

const SHARE_ALL: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

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

impl NativeParent {
    pub(crate) fn open_legacy(path: &LegacyText) -> io::Result<Self> {
        let path = std::ffi::OsString::from_wide(path.units());
        Self::open_path(Path::new(&path))
    }

    pub(crate) fn open_path(path: &Path) -> io::Result<Self> {
        Self::open_path_with_final_share(path, SHARE_ALL)
    }

    pub(crate) fn open_path_exclusive(path: &Path) -> io::Result<Self> {
        Self::open_path_with_final_share(path, 0)
    }

    fn open_path_with_final_share(path: &Path, final_share: u32) -> io::Result<Self> {
        let (root, components) = traversal_parts(path)?;
        let root_share = if components.is_empty() {
            final_share
        } else {
            SHARE_ALL
        };
        let mut file = open_root_directory(&root, root_share)?;
        validate_directory_handle(&file)?;
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
        }
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

fn traversal_parts(path: &Path) -> io::Result<(PathBuf, Vec<std::ffi::OsString>)> {
    let mut components = path.components();
    let Some(Component::Prefix(prefix)) = components.next() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "parent path must start at a drive or UNC share",
        ));
    };
    match prefix.kind() {
        Prefix::Disk(_)
        | Prefix::VerbatimDisk(_)
        | Prefix::UNC(_, _)
        | Prefix::VerbatimUNC(_, _) => {}
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "parent path prefix is unsupported",
            ));
        }
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

fn validate_directory_handle(file: &File) -> io::Result<()> {
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
    open_relative(
        parent.file(),
        leaf,
        access,
        SHARE_ALL,
        FILE_OPEN,
        FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
    )
}

pub(crate) fn create_file_relative_exclusive(root: &File, leaf: &str) -> io::Result<File> {
    let encoded = leaf.encode_utf16().collect::<Vec<_>>();
    open_relative(
        root,
        &encoded,
        FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
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
        FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        0,
        FILE_OPEN,
        FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
    )
}

fn open_relative(
    parent: &File,
    leaf: &[u16],
    desired_access: u32,
    share_access: u32,
    disposition: u32,
    options: u32,
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
        SecurityDescriptor: ptr::null(),
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

pub(crate) fn rename_noreplace(
    source: &File,
    destination_parent: &File,
    destination_leaf: &[u16],
) -> io::Result<()> {
    let name_bytes = destination_leaf
        .len()
        .checked_mul(size_of::<u16>())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "leaf is too large"))?;
    let file_name_length = u32::try_from(name_bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "leaf is too large"))?;
    let buffer_bytes = offset_of!(FILE_RENAME_INFORMATION, FileName)
        .checked_add(name_bytes)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "rename is too large"))?;
    let buffer_size = u32::try_from(buffer_bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "rename is too large"))?;
    let elements = buffer_bytes.div_ceil(size_of::<FILE_RENAME_INFORMATION>());
    let mut buffer = vec![FILE_RENAME_INFORMATION::default(); elements];
    buffer[0].Anonymous.Flags = 0;
    buffer[0].RootDirectory = destination_parent.as_raw_handle();
    buffer[0].FileNameLength = file_name_length;

    // SAFETY: buffer is aligned for FILE_RENAME_INFO and sized through the
    // checked flexible-array offset. The UTF-16 leaf fits exactly within it.
    unsafe {
        let target = buffer
            .as_mut_ptr()
            .cast::<u8>()
            .add(offset_of!(FILE_RENAME_INFORMATION, FileName))
            .cast::<u16>();
        ptr::copy_nonoverlapping(destination_leaf.as_ptr(), target, destination_leaf.len());
    }
    let mut status_block = IO_STATUS_BLOCK::default();
    // SAFETY: source and destination-parent handles remain live, buffer fields
    // and size are checked, flags omit replacement, and the native API is synchronous.
    let status = unsafe {
        NtSetInformationFile(
            source.as_raw_handle(),
            ptr::from_mut(&mut status_block),
            buffer.as_ptr().cast(),
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
