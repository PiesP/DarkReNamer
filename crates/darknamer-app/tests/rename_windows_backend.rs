#![cfg(windows)]

use std::fs;
use std::os::windows::ffi::OsStrExt;

use darknamer_app::rename::{
    EntryId, EntryKind, ExecuteErrorKind, ExecutionOutcome, FileJournal, FileJournalErrorKind,
    JournalRoot, MemoryJournal, ModelRevision, MutationCertainty, PlanIssueKind, PlanRequest,
    RenameBackend, RenameExecutor, RenameIntent, RenameOperation, RenamePlanner,
    WindowsRenameBackend, apply_execution_report, build_plan_request,
};
use darknamer_core::{LegacyList, LegacyListItem, LegacyText};

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

fn directory_intent(
    id: u32,
    source: &std::path::Path,
    parent: &std::path::Path,
    leaf: &str,
) -> RenameIntent {
    RenameIntent::new(
        EntryId::new(id),
        legacy_path(source),
        legacy_path(parent),
        leaf,
        EntryKind::Directory,
    )
}

fn case_query_supported(parent: &std::path::Path) -> Result<bool, Box<dyn std::error::Error>> {
    let backend = WindowsRenameBackend;
    match backend.validate_path_environment(&legacy_path(&parent.join("case-query-probe"))) {
        Ok(()) => Ok(true),
        Err(error) if matches!(error.code, 87 | 120) => Ok(false),
        Err(error) => Err(error.into()),
    }
}

#[test]
fn journal_root_rejects_unc_before_filesystem_access() {
    let error = JournalRoot::open("\\\\server\\share\\journal-root")
        .err()
        .and_then(|error| error.os_code);
    assert_eq!(error, Some(53));
}

#[test]
fn occupied_destination_and_relative_path_are_rejected() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source = directory.path().join("a.txt");
    let occupied = directory.path().join("b.txt");
    fs::write(&source, b"a")?;
    fs::write(&occupied, b"b")?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
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
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
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
    if !case_query_supported(&parent)? {
        return Ok(());
    }
    let mut backend = WindowsRenameBackend;
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &source, &parent, "b.txt")],
    ))?;
    fs::rename(&source, parent.join("displaced.txt"))?;
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
fn directory_normal_and_case_only_renames_use_the_same_safe_executor()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source = directory.path().join("Folder");
    fs::create_dir(&source)?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let mut backend = WindowsRenameBackend;
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![directory_intent(0, &source, directory.path(), "Renamed")],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);

    let renamed = directory.path().join("Renamed");
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(2),
        vec![directory_intent(1, &renamed, directory.path(), "RENAMED")],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert!(
        fs::read_dir(directory.path())?
            .filter_map(Result::ok)
            .any(|entry| entry.file_name() == "RENAMED")
    );
    Ok(())
}

#[test]
fn hard_link_destination_is_never_replaced() -> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let source = directory.path().join("source.txt");
    let hard_link = directory.path().join("hard-link.txt");
    fs::write(&source, b"source")?;
    fs::hard_link(&source, &hard_link)?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let mut backend = WindowsRenameBackend;
    let source_snapshot = backend.observe(&legacy_path(&source))?;
    let destination_snapshot = backend.observe(&legacy_path(&hard_link))?;
    let source_entry = source_snapshot
        .entry
        .ok_or_else(|| std::io::Error::other("source identity missing"))?;
    let operation = RenameOperation::new(
        legacy_path(&source),
        legacy_path(&hard_link),
        source_entry.identity,
        source_snapshot.parent,
        destination_snapshot.parent,
    );
    let error = backend
        .rename_no_replace(&operation)
        .err()
        .ok_or_else(|| std::io::Error::other("hard-link destination was replaced"))?;
    assert_eq!(error.certainty, MutationCertainty::NotApplied);
    assert_eq!(fs::read(&source)?, b"source");
    assert_eq!(fs::read(&hard_link)?, b"source");
    Ok(())
}

#[test]
fn intermediate_reparse_and_unsupported_prefix_are_rejected_when_available()
-> Result<(), Box<dyn std::error::Error>> {
    use std::os::windows::fs::symlink_dir;

    let directory = tempfile::tempdir()?;
    let target = directory.path().join("target-parent");
    fs::create_dir(&target)?;
    fs::write(target.join("a.txt"), b"a")?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let link = directory.path().join("junction");
    if let Err(error) = symlink_dir(&target, &link) {
        if error.kind() == std::io::ErrorKind::PermissionDenied {
            return Ok(());
        }
        return Err(error.into());
    }
    let backend = WindowsRenameBackend;
    assert!(backend.observe(&legacy_path(&link.join("a.txt"))).is_err());
    assert!(JournalRoot::open(&link).is_err());
    let unc_error = backend
        .validate_path_environment(&LegacyText::from("\\\\server\\share\\folder\\child.txt"))
        .err()
        .ok_or_else(|| std::io::Error::other("UNC path was accepted"))?;
    assert_eq!(unc_error.code, 53);
    assert!(
        backend
            .observe(&LegacyText::from("\\\\.\\C:\\unsupported.txt"))
            .is_err()
    );
    Ok(())
}

fn set_directory_case_sensitive(path: &std::path::Path, enabled: bool) -> std::io::Result<()> {
    use std::mem::size_of;
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_CASE_SENSITIVE_INFO, FILE_FLAG_BACKUP_SEMANTICS, FILE_READ_ATTRIBUTES,
        FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_WRITE_ATTRIBUTES,
        FileCaseSensitiveInfo, SetFileInformationByHandle,
    };
    use windows_sys::Win32::System::SystemServices::FILE_CS_FLAG_CASE_SENSITIVE_DIR;

    let file = fs::OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)?;
    let info = FILE_CASE_SENSITIVE_INFO {
        Flags: if enabled {
            FILE_CS_FLAG_CASE_SENSITIVE_DIR
        } else {
            0
        },
    };
    let size = u32::try_from(size_of::<FILE_CASE_SENSITIVE_INFO>())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    // SAFETY: file is a live directory handle and info is a correctly aligned,
    // fully initialized buffer of the exact checked size for this synchronous call.
    let success = unsafe {
        SetFileInformationByHandle(
            file.as_raw_handle(),
            FileCaseSensitiveInfo,
            std::ptr::from_ref(&info).cast(),
            size,
        )
    };
    if success == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

struct CaseSensitiveFixtureGuard {
    path: Option<std::path::PathBuf>,
}

impl CaseSensitiveFixtureGuard {
    fn new(path: &std::path::Path) -> Self {
        Self {
            path: Some(path.to_path_buf()),
        }
    }

    fn cleanup(&mut self) -> std::io::Result<()> {
        let Some(path) = self.path.as_deref() else {
            return Ok(());
        };
        empty_directory(path)?;
        fs::remove_dir(path)?;
        self.path = None;
        Ok(())
    }
}

impl Drop for CaseSensitiveFixtureGuard {
    fn drop(&mut self) {
        if let Some(path) = self.path.as_deref() {
            let _ = empty_directory(path);
            let _ = fs::remove_dir(path);
        }
    }
}

fn empty_directory(path: &std::path::Path) -> std::io::Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        if metadata.is_dir() && !metadata.file_type().is_symlink() {
            fs::remove_dir_all(entry.path())?;
        } else {
            fs::remove_file(entry.path())?;
        }
    }
    Ok(())
}

#[test]
fn case_sensitive_parent_is_explicitly_unsupported_when_platform_allows_fixture()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    let parent = directory.path().join("case-sensitive");
    let unrelated = directory.path().join("unrelated.txt");
    fs::create_dir(&parent)?;
    fs::write(&unrelated, b"keep")?;
    let source = parent.join("a.txt");
    if let Err(error) = set_directory_case_sensitive(&parent, true) {
        if matches!(error.raw_os_error(), Some(5 | 50 | 87)) {
            return Ok(());
        }
        return Err(error.into());
    }
    let mut fixture = CaseSensitiveFixtureGuard::new(&parent);
    fs::write(&source, b"a")?;

    let backend = WindowsRenameBackend;
    let environment_error = backend
        .validate_path_environment(&legacy_path(&source))
        .err();
    let request = PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, &source, &parent, "b.txt")],
    );
    let plan_error = RenamePlanner::new(&backend).plan(request).err();
    let root_error = JournalRoot::open(&parent).err();
    fixture.cleanup()?;

    assert!(!parent.exists());
    assert_eq!(fs::read(&unrelated)?, b"keep");
    assert!(directory.path().is_dir());

    assert_eq!(environment_error.map(|error| error.code), Some(50));
    assert!(plan_error.is_some_and(|error| {
        error
            .issues()
            .iter()
            .any(|issue| issue.kind == PlanIssueKind::UnsupportedCaseSensitiveParent)
    }));
    assert!(root_error.is_some_and(|error| {
        error.kind == FileJournalErrorKind::Io && error.os_code == Some(50)
    }));
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
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
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
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let root = JournalRoot::open(directory.path())?;
    let mut journal = FileJournal::create_new(&root, "exclusive.drj")?;
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
    journal.mark_delete_if_safe()?;
    assert!(fs::write(directory.path().join("exclusive.drj"), b"replacement").is_err());
    drop(journal);
    assert!(!directory.path().join("exclusive.drj").exists());
    fs::write(directory.path().join("exclusive.drj"), b"replacement")?;
    assert_eq!(
        fs::read(directory.path().join("exclusive.drj"))?,
        b"replacement"
    );
    Ok(())
}

#[test]
fn planner_file_journal_backend_and_model_complete_one_production_path()
-> Result<(), Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    if !case_query_supported(directory.path())? {
        return Ok(());
    }
    let source = directory.path().join("before.txt");
    fs::write(&source, b"content")?;
    let mut model = LegacyList::new();
    assert!(model.append(LegacyListItem::new(legacy_path(&source), false, 7, 8, 9,)));
    assert!(model.manual_change(0, "after.txt"));
    let mut backend = WindowsRenameBackend;
    let root = JournalRoot::open(directory.path())?;
    let substituted_root = directory.path().with_extension("substituted-root");
    if fs::rename(directory.path(), &substituted_root).is_ok() {
        let _ = fs::rename(&substituted_root, directory.path());
        return Err(std::io::Error::other("retained journal root was substituted").into());
    }
    let active_path = directory.path().join("active.drj");
    let mut journal = FileJournal::create_new(&root, "active.drj")?;
    assert!(
        fs::rename(&active_path, directory.path().join("substituted.drj")).is_err(),
        "exclusive journal child was substituted"
    );
    let plan =
        RenamePlanner::new(&backend).plan(build_plan_request(&model, ModelRevision::new(1)))?;
    let id = plan.id();
    let revision = plan.revision();

    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;

    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert!(apply_execution_report(&mut model, &report));
    assert_eq!(
        model.items()[0].source_path(),
        &legacy_path(&directory.path().join("after.txt"))
    );
    assert!(journal.is_terminal());
    Ok(())
}
