//! Windows ACL boundary for the production recovery-state directory.
//! All checks use retained handles; a rejected pre-existing object is never repaired.

use std::ffi::{OsStr, c_void};
use std::fs::File;
use std::io;
use std::mem::{offset_of, size_of};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::path::Path;
use std::ptr;

use windows_sys::Wdk::Storage::FileSystem::{
    FILE_CREATE, FILE_DIRECTORY_FILE, FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT,
    FILE_SYNCHRONOUS_IO_NONALERT,
};
use windows_sys::Win32::Foundation::{
    GENERIC_ALL, GENERIC_EXECUTE, GENERIC_READ, GENERIC_WRITE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo,
    SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, CreateWellKnownSid, DACL_SECURITY_INFORMATION, EqualSid,
    GetAce, GetLengthSid, GetTokenInformation, INHERIT_ONLY_ACE, OWNER_SECURITY_INFORMATION,
    TOKEN_QUERY, TOKEN_USER, TokenUser, WinBuiltinAdministratorsSid, WinLocalSystemSid,
};
use windows_sys::Win32::Storage::FileSystem::{
    DELETE, FILE_ADD_FILE, FILE_ADD_SUBDIRECTORY, FILE_ALL_ACCESS, FILE_APPEND_DATA,
    FILE_DELETE_CHILD, FILE_GENERIC_EXECUTE, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
    FILE_READ_ATTRIBUTES, FILE_READ_DATA, FILE_READ_EA, FILE_SHARE_READ, FILE_SHARE_WRITE,
    FILE_TRAVERSE, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA, FILE_WRITE_EA, READ_CONTROL,
    SYNCHRONIZE, WRITE_DAC, WRITE_OWNER,
};
use windows_sys::Win32::System::SystemServices::{
    ACCESS_ALLOWED_ACE_TYPE, ACCESS_DENIED_ACE_TYPE, SECURITY_DESCRIPTOR_REVISION,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

use super::windows_native;

const SHARE_NO_DELETE: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE;
const DIRECTORY_ACCESS: u32 = FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE;
const FILE_ACCESS: u32 =
    DELETE | FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE;
const FILE_OPTIONS: u32 =
    FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT;
const DIRECTORY_OPTIONS: u32 =
    FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT;
const TRUSTED_INSTALLER: &str = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";

fn refused() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "recovery-state owner or DACL is unsafe",
    )
}

struct LocalDescriptor(*mut c_void);
impl Drop for LocalDescriptor {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: the descriptor was allocated by a Win32 security API using LocalAlloc.
            unsafe { LocalFree(self.0) };
        }
    }
}

struct Sid(Vec<u32>);
impl Sid {
    fn ptr(&self) -> *mut c_void {
        self.0.as_ptr().cast_mut().cast()
    }
}

fn current_sid() -> io::Result<Sid> {
    let mut token = ptr::null_mut();
    // SAFETY: token is an output pointer and the current process handle is valid.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: OpenProcessToken returned one owned handle.
    let token = unsafe { std::os::windows::io::OwnedHandle::from_raw_handle(token) };
    token_sid(&token)
}

fn token_sid(token: &impl AsRawHandle) -> io::Result<Sid> {
    let mut size = 0;
    // SAFETY: the null buffer obtains the required size; token remains live.
    unsafe {
        GetTokenInformation(
            token.as_raw_handle(),
            TokenUser,
            ptr::null_mut(),
            0,
            &mut size,
        )
    };
    let words = usize::try_from(size)
        .map_err(|_| refused())?
        .div_ceil(size_of::<u64>());
    let mut buffer = vec![0_u64; words];
    // SAFETY: aligned buffer is writable for the size returned by Windows.
    if unsafe {
        GetTokenInformation(
            token.as_raw_handle(),
            TokenUser,
            buffer.as_mut_ptr().cast(),
            size,
            &mut size,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: successful TokenUser query initializes a TOKEN_USER in the aligned buffer.
    let user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
    copy_sid(user.User.Sid)
}

fn copy_sid(sid: *mut c_void) -> io::Result<Sid> {
    if sid.is_null() {
        return Err(refused());
    }
    // SAFETY: sid came from a live token or a successful Windows SID constructor.
    let len = unsafe { GetLengthSid(sid) };
    if !(8..=256).contains(&len) {
        return Err(refused());
    }
    let mut words = vec![0_u32; (len as usize).div_ceil(4)];
    // SAFETY: destination is aligned and large enough for the source SID.
    if unsafe { windows_sys::Win32::Security::CopySid(len, words.as_mut_ptr().cast(), sid) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(Sid(words))
}

fn well_known(kind: i32) -> io::Result<Sid> {
    let mut words = vec![0_u32; 64];
    let mut size = u32::try_from(words.len() * 4).map_err(|_| refused())?;
    // SAFETY: the bounded writable buffer is valid and size is initialized.
    if unsafe { CreateWellKnownSid(kind, ptr::null_mut(), words.as_mut_ptr().cast(), &mut size) }
        == 0
    {
        return Err(io::Error::last_os_error());
    }
    words.truncate((size as usize).div_ceil(4));
    Ok(Sid(words))
}

fn sid_string(sid: *mut c_void) -> io::Result<String> {
    let mut text = ptr::null_mut();
    // SAFETY: sid points into a live descriptor or owned SID; Windows allocates text.
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let text_owner = LocalDescriptor(text.cast());
    let mut len = 0;
    // SAFETY: the returned Windows string is null-terminated and remains allocated.
    while unsafe { *text.add(len) } != 0 {
        len += 1;
    }
    // SAFETY: len was counted within the returned terminated string.
    let result =
        String::from_utf16(unsafe { std::slice::from_raw_parts(text, len) }).map_err(|_| refused());
    drop(text_owner);
    result
}

fn allowed_sid(
    sid: *mut c_void,
    user: &Sid,
    system: &Sid,
    admins: &Sid,
    ancestor: bool,
) -> io::Result<bool> {
    if sid.is_null() {
        return Err(refused());
    }
    // SAFETY: every SID is backed by a live descriptor or owned storage.
    if unsafe {
        EqualSid(sid, user.ptr()) != 0
            || EqualSid(sid, system.ptr()) != 0
            || EqualSid(sid, admins.ptr()) != 0
    } {
        return Ok(true);
    }
    Ok(ancestor && sid_string(sid)? == TRUSTED_INSTALLER)
}

fn expanded_mask(mut mask: u32) -> u32 {
    if mask & GENERIC_ALL != 0 {
        mask |= FILE_ALL_ACCESS;
    }
    if mask & GENERIC_READ != 0 {
        mask |= FILE_GENERIC_READ;
    }
    if mask & GENERIC_WRITE != 0 {
        mask |= FILE_GENERIC_WRITE;
    }
    if mask & GENERIC_EXECUTE != 0 {
        mask |= FILE_GENERIC_EXECUTE;
    }
    mask & !(GENERIC_ALL | GENERIC_READ | GENERIC_WRITE | GENERIC_EXECUTE)
}

fn validate(file: &File, user: &Sid, ancestor: bool, directory: bool) -> io::Result<()> {
    let system = well_known(WinLocalSystemSid)?;
    let admins = well_known(WinBuiltinAdministratorsSid)?;
    let mut owner = ptr::null_mut();
    let mut dacl: *mut ACL = ptr::null_mut();
    let mut descriptor = ptr::null_mut();
    // SAFETY: retained handle has READ_CONTROL; outputs are writable and tied to descriptor.
    let code = unsafe {
        GetSecurityInfo(
            file.as_raw_handle(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            ptr::null_mut(),
            &mut dacl,
            ptr::null_mut(),
            &mut descriptor,
        )
    };
    if code != 0 {
        return Err(io::Error::from_raw_os_error(
            i32::try_from(code).unwrap_or(i32::MAX),
        ));
    }
    let _descriptor_owner = LocalDescriptor(descriptor);
    if owner.is_null() {
        return Err(refused());
    }
    // Application-owned state must belong to this user, even when an
    // administrator could otherwise access it.
    let owner_ok = if ancestor {
        allowed_sid(owner, user, &system, &admins, true)?
    } else {
        // SAFETY: owner and user SID are backed by live descriptor/owned storage.
        unsafe { EqualSid(owner, user.ptr()) != 0 }
    };
    if !owner_ok || dacl.is_null() {
        return Err(refused());
    }
    // SAFETY: dacl is returned inside the live descriptor by GetSecurityInfo.
    let count = unsafe { (*dacl).AceCount };
    for index in 0..count {
        let mut ace = ptr::null_mut();
        // SAFETY: index is within the ACL's declared ACE count and output is writable.
        if unsafe { GetAce(dacl, u32::from(index), &mut ace) } == 0 {
            return Err(refused());
        }
        // SAFETY: GetAce returned a valid ACE header.
        let header = unsafe { &*ace.cast::<ACE_HEADER>() };
        if usize::from(header.AceSize) < size_of::<ACCESS_ALLOWED_ACE>() {
            return Err(refused());
        }
        if u32::from(header.AceType) != ACCESS_ALLOWED_ACE_TYPE
            && u32::from(header.AceType) != ACCESS_DENIED_ACE_TYPE
        {
            return Err(refused());
        }
        if header.AceFlags & INHERIT_ONLY_ACE as u8 != 0 {
            continue;
        }
        if u32::from(header.AceType) == ACCESS_DENIED_ACE_TYPE {
            continue;
        }
        // SAFETY: standard allow ACE has fixed mask and SID offset after its header.
        let allow = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
        // SAFETY: a standard allow ACE has its SID at SidStart within the ACE.
        let sid = unsafe {
            ace.cast::<u8>()
                .add(offset_of!(ACCESS_ALLOWED_ACE, SidStart))
                .cast()
        };
        if offset_of!(ACCESS_ALLOWED_ACE, SidStart) + 8 > usize::from(header.AceSize) {
            return Err(refused());
        }
        // SAFETY: the ACE contains at least a SID header at this offset.
        let sid_len = unsafe { GetLengthSid(sid) } as usize;
        if sid_len < 8
            || offset_of!(ACCESS_ALLOWED_ACE, SidStart) + sid_len > usize::from(header.AceSize)
        {
            return Err(refused());
        }
        if allowed_sid(sid, user, &system, &admins, ancestor)? {
            continue;
        }
        let dangerous = if ancestor {
            DELETE | WRITE_DAC | WRITE_OWNER | FILE_DELETE_CHILD
        } else if directory {
            DELETE
                | WRITE_DAC
                | WRITE_OWNER
                | FILE_DELETE_CHILD
                | FILE_ADD_FILE
                | FILE_ADD_SUBDIRECTORY
                | FILE_READ_DATA
                | FILE_WRITE_DATA
                | FILE_READ_EA
                | FILE_WRITE_EA
                | FILE_WRITE_ATTRIBUTES
        } else {
            DELETE
                | WRITE_DAC
                | WRITE_OWNER
                | FILE_READ_DATA
                | FILE_WRITE_DATA
                | FILE_APPEND_DATA
                | FILE_READ_EA
                | FILE_WRITE_EA
                | FILE_WRITE_ATTRIBUTES
        };
        let granted = expanded_mask(allow.Mask);
        if granted & !FILE_ALL_ACCESS != 0 || granted & dangerous != 0 {
            return Err(refused());
        }
    }
    Ok(())
}

pub(super) struct PrivateState {
    user: Sid,
    descriptor: LocalDescriptor,
}

impl PrivateState {
    pub(super) fn new() -> io::Result<Self> {
        let user = current_sid()?;
        let user_text = sid_string(user.ptr())?;
        let sddl =
            format!("O:{user_text}D:P(A;OICI;FA;;;{user_text})(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)");
        let encoded = OsStr::new(&sddl)
            .encode_wide()
            .chain([0])
            .collect::<Vec<_>>();
        let mut descriptor = ptr::null_mut();
        // SAFETY: encoded SDDL is terminated and Windows allocates the descriptor.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                encoded.as_ptr(),
                SECURITY_DESCRIPTOR_REVISION,
                &mut descriptor,
                ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            user,
            descriptor: LocalDescriptor(descriptor),
        })
    }

    pub(super) fn validate(&self, file: &File, ancestor: bool, directory: bool) -> io::Result<()> {
        validate(file, &self.user, ancestor, directory)
    }

    pub(super) fn create_file(&self, parent: &File, leaf: &str) -> io::Result<File> {
        let encoded = leaf.encode_utf16().collect::<Vec<_>>();
        windows_native::open_relative_with_security(
            parent,
            &encoded,
            FILE_ACCESS,
            0,
            FILE_CREATE,
            FILE_OPTIONS,
            self.descriptor.0,
        )
    }

    pub(super) fn open_file(&self, parent: &File, leaf: &str) -> io::Result<File> {
        let encoded = leaf.encode_utf16().collect::<Vec<_>>();
        windows_native::open_relative(parent, &encoded, FILE_ACCESS, 0, FILE_OPEN, FILE_OPTIONS)
    }

    fn open_directory(&self, parent: &File, leaf: &OsStr, create: bool) -> io::Result<File> {
        let encoded = leaf.encode_wide().collect::<Vec<_>>();
        let opened = windows_native::open_relative(
            parent,
            &encoded,
            DIRECTORY_ACCESS,
            SHARE_NO_DELETE,
            FILE_OPEN,
            DIRECTORY_OPTIONS,
        );
        let file = match opened {
            Err(error) if create && matches!(error.raw_os_error(), Some(2 | 3)) => {
                windows_native::open_relative_with_security(
                    parent,
                    &encoded,
                    DIRECTORY_ACCESS,
                    SHARE_NO_DELETE,
                    FILE_CREATE,
                    DIRECTORY_OPTIONS,
                    self.descriptor.0,
                )?
            }
            result => result?,
        };
        windows_native::validate_directory_handle(&file)?;
        windows_native::reject_case_sensitive_directory(&file)?;
        windows_native::reject_remote_protocol_if_reported(&file)?;
        Ok(file)
    }

    pub(super) fn open_root(&self, local_app_data: &Path) -> io::Result<Vec<File>> {
        windows_native::validate_safe_local_root(local_app_data)?;
        let (drive, components) = windows_native::traversal_parts(local_app_data)?;
        let mut chain = Vec::with_capacity(components.len() + 3);
        let drive_file =
            windows_native::open_private_root_directory(&drive).inspect_err(|_error| {
                #[cfg(test)]
                eprintln!("private state drive open: {_error}");
            })?;
        windows_native::validate_directory_handle(&drive_file)?;
        windows_native::reject_case_sensitive_directory(&drive_file)?;
        windows_native::reject_remote_protocol_if_reported(&drive_file)?;
        self.validate(&drive_file, true, true)
            .inspect_err(|_error| {
                #[cfg(test)]
                eprintln!("private state drive ACL: {_error}");
            })?;
        chain.push(drive_file);
        for component in &components {
            let parent = chain.last().ok_or_else(refused)?;
            let file = self
                .open_directory(parent, component, false)
                .inspect_err(|_error| {
                    #[cfg(test)]
                    eprintln!("private state ancestor open: {_error}");
                })?;
            self.validate(&file, true, true).inspect_err(|_error| {
                #[cfg(test)]
                eprintln!("private state ancestor ACL: {_error}");
            })?;
            chain.push(file);
        }
        for leaf in [OsStr::new("DarkReNamer"), OsStr::new("journal")] {
            let parent = chain.last().ok_or_else(refused)?;
            let file = self
                .open_directory(parent, leaf, true)
                .inspect_err(|_error| {
                    #[cfg(test)]
                    eprintln!("private state owned directory open/create: {_error}");
                })?;
            self.validate(&file, false, true).inspect_err(|_error| {
                #[cfg(test)]
                eprintln!("private state owned directory ACL: {_error}");
            })?;
            chain.push(file);
        }
        windows_native::reject_unsupported_filesystem(chain.last().ok_or_else(refused)?)?;
        Ok(chain)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rename::{FileJournal, JournalRoot};
    use std::fs::{self, OpenOptions};
    use std::os::windows::fs::OpenOptionsExt;
    use std::path::Path;
    use windows_sys::Win32::Security::Authorization::SetSecurityInfo;
    use windows_sys::Win32::Security::{
        GetSecurityDescriptorDacl, GetSecurityDescriptorSacl, ImpersonateAnonymousToken,
        LABEL_SECURITY_INFORMATION, RevertToSelf, WinAnonymousSid,
    };
    use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_BACKUP_SEMANTICS;
    use windows_sys::Win32::System::Threading::{GetCurrentThread, OpenThreadToken};

    fn set_dacl(path: &Path, anonymous: bool) -> io::Result<()> {
        let extra = if anonymous {
            "(A;OICI;FA;;;AN)"
        } else {
            "(A;;FA;;;WD)"
        };
        set_dacl_with_extra(path, extra)
    }

    fn set_dacl_with_extra(path: &Path, extra: &str) -> io::Result<()> {
        let current = current_sid()?;
        let current = sid_string(current.ptr())?;
        let sddl = format!("D:P(A;;FA;;;{current})(A;;FA;;;SY)(A;;FA;;;BA){extra}");
        let encoded = OsStr::new(&sddl)
            .encode_wide()
            .chain([0])
            .collect::<Vec<_>>();
        let mut descriptor = ptr::null_mut();
        // SAFETY: encoded SDDL is terminated; Windows owns the returned descriptor.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                encoded.as_ptr(),
                SECURITY_DESCRIPTOR_REVISION,
                &mut descriptor,
                ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let _descriptor = LocalDescriptor(descriptor);
        let mut present = 0;
        let mut dacl: *mut ACL = ptr::null_mut();
        let mut defaulted = 0;
        // SAFETY: the descriptor remains live and all outputs are writable.
        if unsafe { GetSecurityDescriptorDacl(descriptor, &mut present, &mut dacl, &mut defaulted) }
            == 0
            || present == 0
            || dacl.is_null()
        {
            return Err(refused());
        }
        let file = OpenOptions::new()
            .access_mode(WRITE_DAC | READ_CONTROL)
            .share_mode(SHARE_NO_DELETE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
            .open(path)?;
        // SAFETY: the handle has WRITE_DAC and the ACL stays live through this synchronous call.
        let code = unsafe {
            SetSecurityInfo(
                file.as_raw_handle(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                ptr::null_mut(),
                ptr::null_mut(),
                dacl,
                ptr::null(),
            )
        };
        if code != 0 {
            return Err(io::Error::from_raw_os_error(
                i32::try_from(code).unwrap_or(i32::MAX),
            ));
        }
        Ok(())
    }

    fn allow_untrusted_fixture_write(path: &Path) -> io::Result<()> {
        // Only this disposable leaf loses the default medium no-write-up label.
        // Anonymous tokens otherwise cannot exercise a permissive append DACL.
        let encoded = "S:(ML;;NW;;;S-1-16-0)"
            .encode_utf16()
            .chain([0])
            .collect::<Vec<_>>();
        let mut descriptor = ptr::null_mut();
        // SAFETY: terminated SDDL and writable descriptor output remain live.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                encoded.as_ptr(),
                SECURITY_DESCRIPTOR_REVISION,
                &mut descriptor,
                ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let _descriptor = LocalDescriptor(descriptor);
        let mut present = 0;
        let mut sacl = ptr::null_mut();
        let mut defaulted = 0;
        // SAFETY: owned descriptor and writable outputs remain live.
        if unsafe { GetSecurityDescriptorSacl(descriptor, &mut present, &mut sacl, &mut defaulted) }
            == 0
            || present == 0
            || sacl.is_null()
        {
            return Err(refused());
        }
        let file = OpenOptions::new()
            .access_mode(WRITE_OWNER)
            .share_mode(SHARE_NO_DELETE)
            .open(path)?;
        // SAFETY: WRITE_OWNER permits setting only the mandatory label; no other
        // SACL entries or host policy are changed, and sacl stays live.
        let code = unsafe {
            SetSecurityInfo(
                file.as_raw_handle(),
                SE_FILE_OBJECT,
                LABEL_SECURITY_INFORMATION,
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null(),
                sacl,
            )
        };
        if code != 0 {
            return Err(io::Error::from_raw_os_error(
                i32::try_from(code).unwrap_or(i32::MAX),
            ));
        }
        Ok(())
    }

    #[test]
    fn private_root_and_unsafe_directory_or_ancestor_preserve_bytes()
    -> Result<(), Box<dyn std::error::Error>> {
        for alter_ancestor in [false, true] {
            let fixture = tempfile::tempdir()?;
            let root = JournalRoot::open_private(fixture.path())?;
            let active_path = root.path().join("active.drj");
            drop(FileJournal::create_new(&root, "active.drj")?);
            fs::write(&active_path, b"retained evidence")?;
            drop(root);
            let altered = if alter_ancestor {
                fixture.path()
            } else {
                active_path.parent().ok_or_else(refused)?
            };
            set_dacl(altered, false)?;
            assert!(JournalRoot::open_private(fixture.path()).is_err());
            assert_eq!(fs::read(&active_path)?, b"retained evidence");
            assert!(
                !fixture
                    .path()
                    .join("DarkReNamer/journal/runtime.lock")
                    .exists()
            );
        }
        Ok(())
    }

    #[test]
    fn unsafe_lock_and_journals_are_rejected_without_modification()
    -> Result<(), Box<dyn std::error::Error>> {
        for leaf in ["runtime.lock", "active.drj", "candidate.drj"] {
            let fixture = tempfile::tempdir()?;
            let root = JournalRoot::open_private(fixture.path())?;
            let path = root.path().join(leaf);
            if leaf == "runtime.lock" {
                drop(root.acquire_runtime_lock(leaf)?);
            } else {
                drop(FileJournal::create_new(&root, leaf)?);
            }
            fs::write(&path, b"retained evidence")?;
            set_dacl(&path, false)?;
            if leaf == "runtime.lock" {
                assert!(root.acquire_runtime_lock(leaf).is_err());
            } else {
                let error = FileJournal::open_existing_retained(&root, leaf)
                    .err()
                    .ok_or_else(refused)?;
                assert!(error.into_evidence().is_some());
            }
            assert_eq!(fs::read(&path)?, b"retained evidence");
        }
        Ok(())
    }

    #[test]
    fn append_only_anonymous_journal_permission_is_rejected_before_decode()
    -> Result<(), Box<dyn std::error::Error>> {
        for leaf in ["active.drj", "candidate.drj"] {
            let fixture = tempfile::tempdir()?;
            let root = JournalRoot::open_private(fixture.path())?;
            drop(FileJournal::create_new(&root, leaf)?);
            // Deliberately share this isolated parent to test the leaf ACL alone.
            // Production roots never acquire this permissive fixture policy.
            set_dacl(root.path(), true)?;
            let path = root.path().join(leaf);
            fs::write(&path, b"original evidence")?;
            set_dacl_with_extra(&path, "(A;;0x00100004;;;AN)")?;
            allow_untrusted_fixture_write(&path)?;
            // SAFETY: this test owns the thread; the guard restores its identity.
            if unsafe { ImpersonateAnonymousToken(GetCurrentThread()) } == 0 {
                return Err(io::Error::last_os_error().into());
            }
            let impersonation = AnonymousImpersonation { active: true };
            let mut append = windows_native::open_relative(
                root.retained_file_for_test(),
                &leaf.encode_utf16().collect::<Vec<_>>(),
                FILE_APPEND_DATA | SYNCHRONIZE,
                SHARE_NO_DELETE,
                FILE_OPEN,
                FILE_OPTIONS,
            )
            .map_err(|error| io::Error::other(format!("anonymous append open: {error}")))?;
            std::io::Write::write_all(&mut append, b" appended by another principal")
                .map_err(|error| io::Error::other(format!("anonymous append write: {error}")))?;
            drop(append);
            impersonation.revert()?;
            let expected = fs::read(&path)?;
            assert_eq!(expected, b"original evidence appended by another principal");
            let error = FileJournal::open_existing_retained(&root, leaf)
                .err()
                .ok_or_else(refused)?;
            assert_eq!(
                error.failure().stage,
                super::super::JournalOpenStage::Validate
            );
            assert!(error.into_evidence().is_some());
            assert_eq!(fs::read(&path)?, expected);
        }
        Ok(())
    }

    struct AnonymousImpersonation {
        active: bool,
    }
    impl AnonymousImpersonation {
        fn revert(mut self) -> io::Result<()> {
            // SAFETY: this guard owns the current test thread's impersonation.
            if unsafe { RevertToSelf() } == 0 {
                return Err(io::Error::last_os_error());
            }
            self.active = false;
            Ok(())
        }
    }
    impl Drop for AnonymousImpersonation {
        fn drop(&mut self) {
            if self.active {
                // SAFETY: a failed early test path still relinquishes impersonation.
                unsafe { RevertToSelf() };
            }
        }
    }

    #[test]
    fn anonymous_principal_cannot_open_private_journal_but_can_open_explicit_fixture()
    -> Result<(), Box<dyn std::error::Error>> {
        let fixture = tempfile::tempdir()?;
        let root = JournalRoot::open_private(fixture.path())?;
        drop(FileJournal::create_new(&root, "active.drj")?);
        drop(FileJournal::create_new(&root, "anonymous.drj")?);
        // A shared fixture parent isolates the distinct leaf ACLs from directory
        // traversal checks. The production private-parent policy is unchanged.
        set_dacl(root.path(), true)?;
        set_dacl(&root.path().join("anonymous.drj"), true)?;
        let process_sid = current_sid()?;

        // SAFETY: GetCurrentThread returns this test thread's pseudo-handle.
        let thread = unsafe { GetCurrentThread() };
        let mut preexisting = ptr::null_mut();
        // SAFETY: this read-only token query checks the test's initial identity.
        let had_token = unsafe { OpenThreadToken(thread, TOKEN_QUERY, 1, &mut preexisting) };
        assert_eq!(had_token, 0);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(1008));
        // SAFETY: impersonation is reverted by the guard on every exit path.
        if unsafe { ImpersonateAnonymousToken(thread) } == 0 {
            return Err(io::Error::last_os_error().into());
        }
        let impersonation = AnonymousImpersonation { active: true };
        // GetCurrentThreadEffectiveToken is an SDK inline returning -6; this
        // Windows 8+ pseudo-handle grants query rights without reopening the
        // anonymous token's separately protected object DACL.
        // SAFETY: the documented pseudo-handle is valid on this thread and is
        // borrowed, so it will never be passed to CloseHandle.
        let token =
            unsafe { std::os::windows::io::BorrowedHandle::borrow_raw((-6_isize) as *mut c_void) };
        let actual = token_sid(&token)?;
        let expected = well_known(WinAnonymousSid)?;
        // SAFETY: both SIDs are owned and live.
        assert_eq!(unsafe { EqualSid(actual.ptr(), process_sid.ptr()) }, 0);
        // SAFETY: both SIDs are owned and live.
        assert_eq!(unsafe { EqualSid(actual.ptr(), expected.ptr()) }, 1);
        let parent = root.retained_file_for_test();
        let access = FILE_READ_DATA | READ_CONTROL | SYNCHRONIZE;
        assert!(
            windows_native::open_relative(
                parent,
                &"active.drj".encode_utf16().collect::<Vec<_>>(),
                access,
                SHARE_NO_DELETE,
                FILE_OPEN,
                FILE_OPTIONS
            )
            .is_err()
        );
        let public = windows_native::open_relative(
            parent,
            &"anonymous.drj".encode_utf16().collect::<Vec<_>>(),
            access,
            SHARE_NO_DELETE,
            FILE_OPEN,
            FILE_OPTIONS,
        )
        .map_err(|error| io::Error::other(format!("anonymous positive open: {error}")))?;
        drop(public);
        impersonation.revert()?;
        let mut restored = ptr::null_mut();
        // SAFETY: after successful RevertToSelf this thread has no token.
        let has_token = unsafe { OpenThreadToken(thread, TOKEN_QUERY, 1, &mut restored) };
        assert_eq!(has_token, 0);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(1008));
        let after = current_sid()?;
        // SAFETY: process-token SIDs are owned and live.
        assert_eq!(unsafe { EqualSid(after.ptr(), process_sid.ptr()) }, 1);
        Ok(())
    }

    #[test]
    fn shared_new_export_denies_anonymous_stage_access_until_publication()
    -> Result<(), Box<dyn std::error::Error>> {
        let fixture = tempfile::tempdir()?;
        set_dacl(fixture.path(), true)?;
        let parent = OpenOptions::new()
            .access_mode(DIRECTORY_ACCESS)
            .share_mode(SHARE_NO_DELETE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
            .open(fixture.path())?;
        let destination = fixture.path().join("shared.txt");
        let target = windows_native::prepare_text_export_target(&destination)?;
        let bytes = b"intentionally shared final export";
        windows_native::write_text_export_target_with_before_commit(target, bytes, || {
            let entries = fs::read_dir(fixture.path())?.collect::<io::Result<Vec<_>>>()?;
            assert_eq!(entries.len(), 1);
            let stage = entries[0].file_name().encode_wide().collect::<Vec<_>>();
            // SAFETY: the test owns this thread; the guard restores impersonation.
            if unsafe { ImpersonateAnonymousToken(GetCurrentThread()) } == 0 {
                return Err(io::Error::last_os_error());
            }
            let impersonation = AnonymousImpersonation { active: true };
            for access in [FILE_READ_DATA, FILE_WRITE_DATA, DELETE] {
                assert!(
                    windows_native::open_relative(
                        &parent,
                        &stage,
                        access | SYNCHRONIZE,
                        SHARE_NO_DELETE
                            | windows_sys::Win32::Storage::FileSystem::FILE_SHARE_DELETE,
                        FILE_OPEN,
                        FILE_OPTIONS,
                    )
                    .is_err()
                );
            }
            impersonation.revert()
        })?;
        // A positive control checks the deliberately inherited final permissions
        // through the same retained directory and genuinely different principal.
        // SAFETY: the test owns this thread; the guard restores impersonation.
        if unsafe { ImpersonateAnonymousToken(GetCurrentThread()) } == 0 {
            return Err(io::Error::last_os_error().into());
        }
        let impersonation = AnonymousImpersonation { active: true };
        let mut published = windows_native::open_relative(
            &parent,
            &"shared.txt".encode_utf16().collect::<Vec<_>>(),
            FILE_READ_DATA | SYNCHRONIZE,
            SHARE_NO_DELETE | windows_sys::Win32::Storage::FileSystem::FILE_SHARE_DELETE,
            FILE_OPEN,
            FILE_OPTIONS,
        )?;
        let mut actual = Vec::new();
        std::io::Read::read_to_end(&mut published, &mut actual)?;
        assert_eq!(actual, bytes);
        drop(published);
        impersonation.revert()?;
        Ok(())
    }
}
