// Adapted from Renamewright's MIT-licensed native adapter at commit
// e41670ae9c242f0e363d184dd960ded06e905beb. See docs/native-adapter-provenance.md.

use std::ffi::OsStr;
use std::fs::{File, Metadata, OpenOptions};
use std::io;
use std::mem::{offset_of, size_of};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::{AsHandle, AsRawHandle, BorrowedHandle, FromRawHandle};
use std::path::Path;
use std::ptr;

use windows_sys::Wdk::Foundation::OBJECT_ATTRIBUTES;
use windows_sys::Wdk::Storage::FileSystem::{
    FILE_OPEN, FILE_OPEN_REPARSE_POINT, FILE_RENAME_INFORMATION, FILE_SYNCHRONOUS_IO_NONALERT,
    FileRenameInformation, NtCreateFile, NtSetInformationFile, RtlNtStatusToDosErrorNoTeb,
};
use windows_sys::Win32::Foundation::{OBJ_CASE_INSENSITIVE, UNICODE_STRING};
use windows_sys::Win32::Storage::FileSystem::{
    DELETE, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_ID_INFO, FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    FILE_TRAVERSE, FileIdInfo, GetFileInformationByHandleEx, SYNCHRONIZE,
};
use windows_sys::Win32::System::IO::IO_STATUS_BLOCK;

const SHARE_ALL: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
const SHARE_READ: u32 = FILE_SHARE_READ;

/// Stable Windows filesystem identity read from an already-open handle.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FileIdentity {
    volume_serial_number: u64,
    file_id: [u8; 16],
}

impl FileIdentity {
    /// Returns the volume serial number that scopes the file identifier.
    #[must_use]
    pub const fn volume_serial_number(self) -> u64 {
        self.volume_serial_number
    }

    /// Returns the opaque 128-bit file identifier.
    #[must_use]
    pub const fn file_id(self) -> [u8; 16] {
        self.file_id
    }
}

/// Owned handle to a final filesystem entry opened relative to a parent.
#[derive(Debug)]
pub struct EntryHandle {
    file: File,
}

/// Owned handle to an absolute, non-reparse directory.
#[derive(Debug)]
pub struct ParentHandle {
    file: File,
}

/// Access required for a recovery journal handle.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalAccess {
    /// Parse a journal without modifying it.
    Read,
    /// Parse, truncate if needed, and append recovery frames.
    ReadAppend,
}

/// Opens one absolute journal file without following its final reparse point.
///
/// The returned [`File`] is the same owned capability callers must retain for
/// parsing and any authorized recovery writes.
pub fn open_journal_file(path: &Path, access: JournalAccess) -> io::Result<File> {
    if !path.is_absolute() || path.file_name().is_none() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "journal path must be an absolute file path",
        ));
    }
    let mut options = OpenOptions::new();
    options
        .read(true)
        .share_mode(SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    if access == JournalAccess::ReadAppend {
        options.write(true).append(true);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "journal must be a regular non-reparse file",
        ));
    }
    Ok(file)
}

impl ParentHandle {
    /// Opens an absolute directory without following a final reparse point.
    pub fn open(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "parent directory must be absolute",
            ));
        }
        let file = OpenOptions::new()
            .access_mode(FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE)
            .share_mode(SHARE_ALL)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
            .open(path)?;
        let metadata = file.metadata()?;
        if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "parent must be a non-reparse directory",
            ));
        }
        Ok(Self { file })
    }

    /// Borrows the retained native parent handle.
    #[must_use]
    pub fn as_handle(&self) -> BorrowedHandle<'_> {
        self.file.as_handle()
    }
}

impl EntryHandle {
    /// Opens one validated leaf relative to a retained parent handle.
    pub fn open_relative(parent: &ParentHandle, name: &OsStr) -> io::Result<Self> {
        open_relative(
            parent.as_handle(),
            name,
            DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        )
        .map(|file| Self { file })
    }

    /// Borrows the retained native entry handle.
    #[must_use]
    pub fn as_handle(&self) -> BorrowedHandle<'_> {
        self.file.as_handle()
    }

    /// Reads metadata from the retained, reparse-point-preserving handle.
    pub fn metadata(&self) -> io::Result<Metadata> {
        self.file.metadata()
    }
}

fn open_relative(
    parent: BorrowedHandle<'_>,
    name: &OsStr,
    desired_access: u32,
) -> io::Result<File> {
    let mut encoded_name = encode_leaf_name(name)?;
    let name_bytes = encoded_name
        .len()
        .checked_mul(size_of::<u16>())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "entry name is too large"))?;
    let name_length = u16::try_from(name_bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "entry name is too large"))?;
    let object_name = UNICODE_STRING {
        Length: name_length,
        MaximumLength: name_length,
        Buffer: encoded_name.as_mut_ptr(),
    };
    let object_attributes = OBJECT_ATTRIBUTES {
        Length: u32::try_from(size_of::<OBJECT_ATTRIBUTES>()).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "object attributes are too large",
            )
        })?,
        RootDirectory: parent.as_raw_handle(),
        ObjectName: ptr::from_ref(&object_name),
        Attributes: OBJ_CASE_INSENSITIVE,
        SecurityDescriptor: ptr::null(),
        SecurityQualityOfService: ptr::null(),
    };
    let mut status_block = IO_STATUS_BLOCK::default();
    let mut handle = ptr::null_mut();

    // SAFETY: `parent` remains borrowed for this synchronous call;
    // `object_name` references the checked UTF-16 allocation and both descriptor
    // structures remain initialized and immovable. Output pointers are writable
    // and aligned. No optional allocation or EA buffers are supplied. A
    // successful returned handle is transferred exactly once to `File` below.
    let status = unsafe {
        NtCreateFile(
            ptr::from_mut(&mut handle),
            desired_access,
            ptr::from_ref(&object_attributes),
            ptr::from_mut(&mut status_block),
            ptr::null(),
            0,
            SHARE_ALL,
            FILE_OPEN,
            FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
            ptr::null(),
            0,
        )
    };
    if status < 0 {
        // SAFETY: converting an NTSTATUS value returned by `NtCreateFile` has
        // no pointer, lifetime, or ownership preconditions.
        let os_code = unsafe { RtlNtStatusToDosErrorNoTeb(status) };
        return Err(io::Error::from_raw_os_error(
            i32::try_from(os_code).unwrap_or(i32::MAX),
        ));
    }
    if handle.is_null() {
        return Err(io::Error::other("relative entry open returned no handle"));
    }

    // SAFETY: successful `NtCreateFile` returned a new owned non-null handle.
    // This is its only ownership transfer and `File` will close it exactly once.
    Ok(unsafe { File::from_raw_handle(handle) })
}

/// Reads a volume-scoped 128-bit identity from an open handle.
pub fn file_identity(source: BorrowedHandle<'_>) -> io::Result<FileIdentity> {
    let mut info = FILE_ID_INFO::default();
    let buffer_size = u32::try_from(size_of::<FILE_ID_INFO>())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "identity buffer is too large"))?;

    // SAFETY: `source` remains borrowed and is not closed by Win32. `info` is
    // writable and aligned, and the byte count exactly matches its allocation.
    // The synchronous function does not retain the output pointer.
    let succeeded = unsafe {
        GetFileInformationByHandleEx(
            source.as_raw_handle(),
            FileIdInfo,
            ptr::from_mut(&mut info).cast(),
            buffer_size,
        )
    };
    if succeeded == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(FileIdentity {
        volume_serial_number: info.VolumeSerialNumber,
        file_id: info.FileId.Identifier,
    })
}

/// Renames an open entry relative to a retained destination parent.
///
/// Every observed destination, including another hard link to the source, is
/// rejected before the native atomic no-replace operation.
pub fn rename_noreplace(
    source: BorrowedHandle<'_>,
    destination_parent: BorrowedHandle<'_>,
    destination_name: &OsStr,
) -> io::Result<()> {
    reject_existing_destination(destination_parent, destination_name)?;
    let encoded_name = encode_leaf_name(destination_name)?;
    let name_bytes = encoded_name
        .len()
        .checked_mul(size_of::<u16>())
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "destination name is too large")
        })?;
    let file_name_length = u32::try_from(name_bytes).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidInput, "destination name is too large")
    })?;
    let terminated_name_bytes = name_bytes.checked_add(size_of::<u16>()).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "destination name is too large")
    })?;
    let buffer_bytes = offset_of!(FILE_RENAME_INFORMATION, FileName)
        .checked_add(terminated_name_bytes)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "rename buffer is too large"))?;
    let buffer_size = u32::try_from(buffer_bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "rename buffer is too large"))?;
    let element_count = buffer_bytes.div_ceil(size_of::<FILE_RENAME_INFORMATION>());
    let mut buffer = vec![FILE_RENAME_INFORMATION::default(); element_count];
    let header = &mut buffer[0];
    header.Anonymous.Flags = 0;
    header.RootDirectory = destination_parent.as_raw_handle();
    header.FileNameLength = file_name_length;

    // SAFETY: the zero-initialized vector has header alignment and covers
    // `buffer_bytes`, including the trailing UTF-16 NUL. `FileName` starts at
    // the standard-layout offset and the checked source slice fits before it.
    // The vector cannot move during this copy.
    unsafe {
        let file_name = buffer
            .as_mut_ptr()
            .cast::<u8>()
            .add(offset_of!(FILE_RENAME_INFORMATION, FileName))
            .cast::<u16>();
        ptr::copy_nonoverlapping(encoded_name.as_ptr(), file_name, encoded_name.len());
    }

    let mut status_block = IO_STATUS_BLOCK::default();
    // SAFETY: `source` and `destination_parent` remain borrowed for the
    // synchronous call. `buffer` is aligned and initialized for `buffer_size`
    // bytes with zero flags, a retained root handle, a checked byte length, and
    // one validated UTF-16 leaf. The function does not retain the buffer.
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
        // SAFETY: converting the returned NTSTATUS has no pointer, lifetime,
        // or ownership preconditions.
        let os_code = unsafe { RtlNtStatusToDosErrorNoTeb(status) };
        Err(io::Error::from_raw_os_error(
            i32::try_from(os_code).unwrap_or(i32::MAX),
        ))
    } else {
        Ok(())
    }
}

fn encode_leaf_name(name: &OsStr) -> io::Result<Vec<u16>> {
    let encoded = name.encode_wide().collect::<Vec<_>>();
    let invalid = encoded.is_empty()
        || encoded == [u16::from(b'.')]
        || encoded == [u16::from(b'.'), u16::from(b'.')]
        || encoded.iter().any(|unit| {
            *unit == 0
                || *unit == u16::from(b'/')
                || *unit == u16::from(b'\\')
                || *unit == u16::from(b':')
        });
    if invalid {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "entry name must be one native leaf component",
        ))
    } else {
        Ok(encoded)
    }
}

fn reject_existing_destination(parent: BorrowedHandle<'_>, name: &OsStr) -> io::Result<()> {
    match open_relative(parent, name, FILE_READ_ATTRIBUTES | SYNCHRONIZE) {
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "destination already exists",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}
