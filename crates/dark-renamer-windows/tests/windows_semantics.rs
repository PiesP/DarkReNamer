#![cfg(windows)]

use std::ffi::OsStr;
use std::fs;
use std::io;

use dark_renamer_windows::{EntryHandle, ParentHandle, file_identity, rename_noreplace};

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
