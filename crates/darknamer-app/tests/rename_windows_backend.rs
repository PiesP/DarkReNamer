#![cfg(windows)]

use std::fs;
use std::os::windows::ffi::OsStrExt;

use darknamer_app::rename::{
    EntryId, EntryKind, ExecuteErrorKind, ExecutionOutcome, FileJournal, JournalRoot,
    MemoryJournal, ModelRevision, PlanIssueKind, PlanRequest, RenameBackend, RenameExecutor,
    RenameIntent, RenamePlanner, WindowsRenameBackend,
};
use darknamer_core::LegacyText;

fn legacy_path(path: &std::path::Path) -> LegacyText {
    LegacyText::from_units(path.as_os_str().encode_wide().collect::<Vec<_>>())
}

fn intent(id: u32, source: &std::path::Path, parent: &std::path::Path, leaf: &str) -> RenameIntent {
    RenameIntent::new(
        EntryId::new(id),
        legacy_path(source),
        legacy_path(parent),
        leaf,
        EntryKind::File,
    )
}

#[test]
fn occupied_destination_and_relative_path_are_rejected() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source = directory.path().join("a.txt");
    let occupied = directory.path().join("b.txt");
    fs::write(&source, b"a")?;
    fs::write(&occupied, b"b")?;
    let backend = WindowsRenameBackend;
    let request = PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &source, directory.path(), "b.txt")],
    );
    let error = RenamePlanner::new(&backend)
        .plan(request)
        .err()
        .ok_or_else(|| std::io::Error::other("occupied destination was accepted"))?;
    assert_eq!(error.issues()[0].kind, PlanIssueKind::DestinationOccupied);
    assert!(backend.observe(&LegacyText::from("relative.txt")).is_err());
    Ok(())
}

#[test]
fn case_only_and_swap_execute_through_handle_relative_moves()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source = directory.path().join("A.TXT");
    fs::write(&source, b"case")?;
    let mut backend = WindowsRenameBackend;
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &source, directory.path(), "a.txt")],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    let names = fs::read_dir(directory.path())?
        .filter_map(Result::ok)
        .map(|entry| entry.file_name())
        .collect::<Vec<_>>();
    assert!(names.iter().any(|name| name == "a.txt"));

    let left = directory.path().join("left.txt");
    let right = directory.path().join("right.txt");
    fs::write(&left, b"left")?;
    fs::write(&right, b"right")?;
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(2),
        vec![
            intent(1, &left, directory.path(), "right.txt"),
            intent(2, &right, directory.path(), "left.txt"),
        ],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert_eq!(fs::read(&left)?, b"right");
    assert_eq!(fs::read(&right)?, b"left");
    Ok(())
}

#[test]
fn stale_source_and_replaced_parent_fail_before_mutation() -> Result<(), Box<dyn std::error::Error>>
{
    let directory = tempfile::tempdir()?;
    let parent = directory.path().join("work");
    fs::create_dir(&parent)?;
    let source = parent.join("a.txt");
    fs::write(&source, b"old")?;
    let mut backend = WindowsRenameBackend;
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &source, &parent, "b.txt")],
    ))?;
    fs::remove_file(&source)?;
    fs::write(&source, b"replacement")?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let error = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)
        .err()
        .ok_or_else(|| std::io::Error::other("stale source was executed"))?;
    assert_eq!(error.kind, ExecuteErrorKind::StaleSource);
    assert!(!parent.join("b.txt").exists());

    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(2),
        vec![intent(1, &source, &parent, "c.txt")],
    ))?;
    let moved_parent = directory.path().join("old-work");
    fs::rename(&parent, &moved_parent)?;
    fs::create_dir(&parent)?;
    fs::write(parent.join("a.txt"), b"new-parent")?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let error = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)
        .err()
        .ok_or_else(|| std::io::Error::other("replaced parent was executed"))?;
    assert_eq!(error.kind, ExecuteErrorKind::StaleParent);
    assert!(!parent.join("c.txt").exists());
    Ok(())
}

#[test]
fn final_reparse_and_journal_root_reparse_are_rejected_when_fixture_is_available()
-> Result<(), Box<dyn std::error::Error>> {
    use std::os::windows::fs::{symlink_dir, symlink_file};

    let directory = tempfile::tempdir()?;
    let target = directory.path().join("target.txt");
    let link = directory.path().join("link.txt");
    fs::write(&target, b"target")?;
    if let Err(error) = symlink_file(&target, &link) {
        if error.kind() == std::io::ErrorKind::PermissionDenied {
            return Ok(());
        }
        return Err(error.into());
    }
    let backend = WindowsRenameBackend;
    let request = PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &link, directory.path(), "renamed.txt")],
    );
    let error = RenamePlanner::new(&backend)
        .plan(request)
        .err()
        .ok_or_else(|| std::io::Error::other("final reparse was accepted"))?;
    assert!(matches!(
        error.issues()[0].kind,
        PlanIssueKind::ReparseSource | PlanIssueKind::MissingSource
    ));

    let root_target = directory.path().join("journal-root");
    let root_link = directory.path().join("journal-link");
    fs::create_dir(&root_target)?;
    symlink_dir(&root_target, &root_link)?;
    assert!(JournalRoot::open(root_link).is_err());
    Ok(())
}

#[test]
fn journal_child_handle_is_exclusive_and_relative_to_retained_root()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let root = JournalRoot::open(directory.path())?;
    let journal = FileJournal::create_new(&root, "exclusive.drj")?;
    let competing = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(directory.path().join("exclusive.drj"));
    assert!(competing.is_err());
    assert!(
        fs::rename(
            directory.path().join("exclusive.drj"),
            directory.path().join("substituted.drj"),
        )
        .is_err()
    );
    drop(journal);
    assert!(directory.path().join("exclusive.drj").exists());
    Ok(())
}
