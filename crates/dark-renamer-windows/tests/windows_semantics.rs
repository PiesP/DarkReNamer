#![cfg(windows)]

use std::ffi::OsStr;
use std::fs;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::windows::fs::symlink_file;
use std::os::windows::io::AsHandle;

use dark_renamer_windows::{
    EntryHandle, JournalAccess, ParentHandle, file_identity, open_journal_file, rename_noreplace,
};

#[test]
fn retained_handles_preserve_identity_across_rename() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source_path = directory.path().join("source.txt");
    fs::write(&source_path, b"source")?;
    let parent = ParentHandle::open(directory.path())?;
    let source = EntryHandle::open_relative(&parent, OsStr::new("source.txt"))?;
    let before = file_identity(source.as_handle())?;

    rename_noreplace(
        source.as_handle(),
        parent.as_handle(),
        OsStr::new("renamed.txt"),
    )?;

    assert_eq!(file_identity(source.as_handle())?, before);
    let reopened = EntryHandle::open_relative(&parent, OsStr::new("renamed.txt"))?;
    assert_eq!(file_identity(reopened.as_handle())?, before);
    assert!(!source_path.exists());
    Ok(())
}

#[test]
fn every_existing_destination_is_preserved() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source_path = directory.path().join("source.txt");
    let destination_path = directory.path().join("destination.txt");
    fs::write(&source_path, b"source")?;
    fs::write(&destination_path, b"occupant")?;
    let parent = ParentHandle::open(directory.path())?;
    let source = EntryHandle::open_relative(&parent, OsStr::new("source.txt"))?;

    let error = rename_noreplace(
        source.as_handle(),
        parent.as_handle(),
        OsStr::new("destination.txt"),
    )
    .err()
    .ok_or("occupied destination was replaced")?;

    assert!(matches!(
        error.kind(),
        io::ErrorKind::AlreadyExists | io::ErrorKind::PermissionDenied
    ));
    assert_eq!(fs::read(source_path)?, b"source");
    assert_eq!(fs::read(destination_path)?, b"occupant");
    Ok(())
}

#[test]
fn existing_hard_link_also_blocks_rename() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source_path = directory.path().join("source.txt");
    let linked_path = directory.path().join("linked.txt");
    fs::write(&source_path, b"shared")?;
    fs::hard_link(&source_path, &linked_path)?;
    let parent = ParentHandle::open(directory.path())?;
    let source = EntryHandle::open_relative(&parent, OsStr::new("source.txt"))?;
    let linked = EntryHandle::open_relative(&parent, OsStr::new("linked.txt"))?;
    assert_eq!(
        file_identity(source.as_handle())?,
        file_identity(linked.as_handle())?
    );

    let error = rename_noreplace(
        source.as_handle(),
        parent.as_handle(),
        OsStr::new("linked.txt"),
    )
    .err()
    .ok_or("existing hard link was replaced")?;

    assert!(matches!(
        error.kind(),
        io::ErrorKind::AlreadyExists | io::ErrorKind::PermissionDenied
    ));
    assert_eq!(fs::read(source_path)?, b"shared");
    assert_eq!(fs::read(linked_path)?, b"shared");
    Ok(())
}

#[test]
fn invalid_leaf_names_are_rejected_before_ffi() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    fs::write(directory.path().join("source.txt"), b"source")?;
    let parent = ParentHandle::open(directory.path())?;
    let source = EntryHandle::open_relative(&parent, OsStr::new("source.txt"))?;

    for invalid in ["", ".", "..", "nested\\name.txt", "stream:name"] {
        let error = rename_noreplace(source.as_handle(), parent.as_handle(), OsStr::new(invalid))
            .err()
            .ok_or("invalid leaf name reached Win32")?;
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
    Ok(())
}

#[test]
fn journal_open_rejects_a_final_file_reparse_point() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let target = directory.path().join("target.drj");
    let link = directory.path().join("journal.drj");
    fs::write(&target, b"journal")?;
    symlink_file(&target, &link)?;

    let error = open_journal_file(&link, JournalAccess::Read)
        .err()
        .ok_or("journal reparse point was followed")?;

    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    assert_eq!(fs::read(target)?, b"journal");
    Ok(())
}

#[test]
fn journal_recovery_retains_one_read_append_file() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let path = directory.path().join("journal.drj");
    fs::write(&path, b"header-tail")?;
    let mut file = open_journal_file(&path, JournalAccess::ReadAppend)?;
    let identity = file_identity(file.as_handle())?;

    file.set_len(6)?;
    file.seek(SeekFrom::End(0))?;
    file.write_all(b"-frame")?;
    file.sync_data()?;
    file.seek(SeekFrom::Start(0))?;
    let mut contents = Vec::new();
    file.read_to_end(&mut contents)?;

    assert_eq!(contents, b"header-frame");
    assert_eq!(file_identity(file.as_handle())?, identity);
    Ok(())
}

#[test]
fn retained_journal_handle_blocks_path_substitution() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let path = directory.path().join("journal.drj");
    let replacement = directory.path().join("replacement.drj");
    fs::write(&path, b"authorized")?;
    fs::write(&replacement, b"replacement")?;
    let file = open_journal_file(&path, JournalAccess::ReadAppend)?;

    assert!(fs::rename(&path, directory.path().join("moved.drj")).is_err());
    assert!(fs::rename(&replacement, &path).is_err());
    assert_eq!(fs::read(&path)?, b"authorized");
    drop(file);
    Ok(())
}
