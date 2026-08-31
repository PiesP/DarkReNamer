use std::cell::Cell;
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::io::Cursor;
use std::mem::size_of;
use std::path::{Path, PathBuf};

use darknamer_app::admission::{
    AdmissionAdapter, AdmissionAdapterError, AdmissionChildren, AdmissionIssueKind,
    AdmissionMetadata, AdmissionMode, AdmissionOperation, MAX_ADMISSION_DEPTH,
    MAX_ADMITTED_PATH_BYTES, MAX_ADMITTED_SOURCES, MAX_IMPORT_BYTES, PathBudget,
    PathBudgetReservation, bounded_import_lines, bounded_selection, collect_admission,
    collect_admission_cancellable, collect_admission_cancellable_with_budget, read_bounded_import,
};
use darknamer_app::rename::EntryIdentity;
use darknamer_core::LegacyText;

#[derive(Default)]
struct FakeAdapter {
    metadata: BTreeMap<PathBuf, AdmissionMetadata>,
    children: BTreeMap<PathBuf, Vec<PathBuf>>,
    rejected: BTreeMap<PathBuf, AdmissionAdapterError>,
    legacy_paths: BTreeMap<PathBuf, LegacyText>,
    metadata_calls: Cell<usize>,
    enumeration_calls: Cell<usize>,
}

impl AdmissionAdapter for FakeAdapter {
    fn validate_path(&self, path: &Path) -> Result<(), AdmissionAdapterError> {
        self.rejected.get(path).copied().map_or(Ok(()), Err)
    }

    fn metadata(&self, path: &Path) -> Result<AdmissionMetadata, AdmissionAdapterError> {
        self.metadata_calls.set(self.metadata_calls.get() + 1);
        self.metadata
            .get(path)
            .copied()
            .ok_or(AdmissionAdapterError::new(AdmissionOperation::Metadata))
    }

    fn read_children(
        &self,
        path: &Path,
        limit: usize,
    ) -> Result<AdmissionChildren, AdmissionAdapterError> {
        self.enumeration_calls.set(self.enumeration_calls.get() + 1);
        let children = self.children.get(path).ok_or(AdmissionAdapterError::new(
            AdmissionOperation::ReadDirectory,
        ))?;
        Ok(AdmissionChildren {
            paths: children.iter().take(limit).cloned().collect(),
            had_errors: false,
            truncated: children.len() > limit,
        })
    }

    fn read_children_cancellable(
        &self,
        path: &Path,
        limit: usize,
        cancellation_requested: &dyn Fn() -> bool,
    ) -> Result<AdmissionChildren, darknamer_app::admission::AdmissionReadError> {
        self.enumeration_calls.set(self.enumeration_calls.get() + 1);
        let children = self.children.get(path).ok_or_else(|| {
            darknamer_app::admission::AdmissionReadError::Adapter(AdmissionAdapterError::new(
                AdmissionOperation::ReadDirectory,
            ))
        })?;
        let mut paths = Vec::with_capacity(limit.min(children.len()));
        for child in children.iter().take(limit.saturating_add(1)) {
            if cancellation_requested() {
                return Err(darknamer_app::admission::AdmissionReadError::Cancelled);
            }
            paths.push(child.clone());
        }
        let truncated = paths.len() > limit;
        paths.truncate(limit);
        Ok(AdmissionChildren {
            paths,
            had_errors: false,
            truncated,
        })
    }

    fn legacy_path(&self, path: &Path) -> LegacyText {
        self.legacy_paths
            .get(path)
            .cloned()
            .unwrap_or_else(|| LegacyText::from(path.to_string_lossy().into_owned()))
    }
}

fn file() -> AdmissionMetadata {
    AdmissionMetadata {
        is_directory: false,
        is_reparse_point: false,
        directory_identity: None,
        actual_size: 7,
        created: 8,
        modified: 9,
    }
}

fn directory(id: u128) -> AdmissionMetadata {
    AdmissionMetadata {
        is_directory: true,
        is_reparse_point: false,
        directory_identity: Some(EntryIdentity::new(1, id)),
        actual_size: 0,
        created: 1,
        modified: 2,
    }
}

fn compare(left: &Path, right: &Path) -> Ordering {
    left.cmp(right)
}

fn test_root() -> PathBuf {
    #[cfg(windows)]
    {
        PathBuf::from("C:\\admission-test")
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/admission-test")
    }
}

#[test]
fn iterative_recurse_is_deterministic_and_skips_reparse_and_repeated_directories() {
    let root = test_root();
    let a = root.join("a.txt");
    let nested = root.join("nested");
    let z = root.join("z.txt");
    let loop_dir = nested.join("loop");
    let reparse = root.join("reparse");
    let mut adapter = FakeAdapter::default();
    adapter.metadata.insert(root.clone(), directory(1));
    adapter.metadata.insert(a.clone(), file());
    adapter.metadata.insert(nested.clone(), directory(2));
    adapter.metadata.insert(z.clone(), file());
    adapter.metadata.insert(loop_dir.clone(), directory(1));
    adapter.metadata.insert(
        reparse.clone(),
        AdmissionMetadata {
            is_reparse_point: true,
            ..directory(3)
        },
    );
    adapter.children.insert(
        root.clone(),
        vec![z.clone(), reparse.clone(), nested.clone(), a.clone()],
    );
    adapter.children.insert(nested, vec![loop_dir]);

    let report = collect_admission(
        &adapter,
        vec![root],
        AdmissionMode::Recurse,
        MAX_ADMITTED_SOURCES,
        compare,
    );

    let paths = report
        .items
        .iter()
        .map(|item| item.source_path().to_string_lossy())
        .collect::<Vec<_>>();
    assert_eq!(paths, vec![a.to_string_lossy(), z.to_string_lossy()]);
    assert!(
        report
            .issues
            .iter()
            .any(|issue| issue.kind == AdmissionIssueKind::ReparsePoint)
    );
    assert!(
        report
            .issues
            .iter()
            .any(|issue| issue.kind == AdmissionIssueKind::RepeatedDirectory)
    );
}

#[test]
fn hard_limit_stops_before_inspecting_additional_metadata() {
    let mut adapter = FakeAdapter::default();
    let root = test_root();
    let roots = (0..=MAX_ADMITTED_SOURCES)
        .map(|index| root.join(format!("file-{index:05}")))
        .collect::<Vec<_>>();
    for path in &roots {
        adapter.metadata.insert(path.clone(), file());
    }

    let report = collect_admission(
        &adapter,
        roots,
        AdmissionMode::Direct,
        MAX_ADMITTED_SOURCES,
        compare,
    );

    assert_eq!(report.items.len(), MAX_ADMITTED_SOURCES);
    assert!(
        report
            .issues
            .iter()
            .any(|issue| issue.kind == AdmissionIssueKind::LimitReached)
    );
}

#[test]
fn cancellation_stops_during_child_enumeration_before_descendant_metadata() {
    let root = test_root();
    let children = (0..100)
        .map(|index| root.join(format!("child-{index:03}.txt")))
        .collect::<Vec<_>>();
    let mut adapter = FakeAdapter::default();
    adapter.metadata.insert(root.clone(), directory(1));
    adapter.children.insert(root.clone(), children);
    let checks = Cell::new(0_usize);

    let result = collect_admission_cancellable(
        &adapter,
        vec![root],
        AdmissionMode::Recurse,
        MAX_ADMITTED_SOURCES,
        compare,
        || {
            let next = checks.get().saturating_add(1);
            checks.set(next);
            next >= 12
        },
    );

    assert_eq!(result, Err(darknamer_app::admission::AdmissionCancelled));
    assert_eq!(adapter.enumeration_calls.get(), 1);
    assert_eq!(adapter.metadata_calls.get(), 1);
}

#[test]
fn cancellation_stops_inside_root_sort_with_bounded_additional_comparisons() {
    let root = test_root();
    let roots = (0..MAX_ADMITTED_SOURCES)
        .rev()
        .map(|index| root.join(format!("long-sort-path-{index:05}-{}", "x".repeat(128))))
        .collect::<Vec<_>>();
    let cancelled = Cell::new(false);
    let comparisons = Cell::new(0_usize);

    let result = collect_admission_cancellable(
        &FakeAdapter::default(),
        roots,
        AdmissionMode::Direct,
        MAX_ADMITTED_SOURCES,
        |left, right| {
            let next = comparisons.get().saturating_add(1);
            comparisons.set(next);
            if next == 7 {
                cancelled.set(true);
            }
            left.cmp(right)
        },
        || cancelled.get(),
    );

    assert_eq!(result, Err(darknamer_app::admission::AdmissionCancelled));
    assert_eq!(comparisons.get(), 7);
}

#[test]
fn relative_path_is_reported_without_metadata_access() {
    let report = collect_admission(
        &FakeAdapter::default(),
        vec![PathBuf::from("relative.txt")],
        AdmissionMode::Direct,
        MAX_ADMITTED_SOURCES,
        compare,
    );
    assert!(report.items.is_empty());
    assert_eq!(report.issues[0].kind, AdmissionIssueKind::RelativePath);
}

#[cfg(windows)]
#[test]
fn windows_reparse_loop_is_not_followed_and_missing_metadata_is_reported()
-> Result<(), Box<dyn std::error::Error>> {
    use std::fs;
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::fs::symlink_dir;

    use darknamer_app::admission::WindowsAdmissionAdapter;
    use darknamer_app::rename::{RenameBackend, WindowsRenameBackend};

    let directory = tempfile::tempdir()?;
    let root = directory.path().join("root");
    fs::create_dir(&root)?;
    fs::write(root.join("file.txt"), b"file")?;
    let probe = LegacyText::from_units(
        root.join("file.txt")
            .as_os_str()
            .encode_wide()
            .collect::<Vec<_>>(),
    );
    if let Err(error) = WindowsRenameBackend.validate_path_environment(&probe)
        && matches!(error.code, 87 | 120)
    {
        return Ok(());
    }
    let loop_path = root.join("loop");
    let symlink_available = match symlink_dir(&root, &loop_path) {
        Ok(()) => true,
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => false,
        Err(error) => return Err(error.into()),
    };
    let missing = directory.path().join("missing.txt");

    let adapter = WindowsAdmissionAdapter::new();
    let report = collect_admission(
        &adapter,
        vec![root, missing],
        AdmissionMode::Recurse,
        MAX_ADMITTED_SOURCES,
        compare,
    );

    assert!(
        report
            .issues
            .iter()
            .any(|issue| issue.kind == AdmissionIssueKind::Metadata)
    );
    if symlink_available {
        assert!(
            report
                .issues
                .iter()
                .any(|issue| issue.kind == AdmissionIssueKind::ReparsePoint)
        );
    }
    assert_eq!(report.items.len(), 1);
    Ok(())
}

#[test]
fn rejected_safe_gate_performs_zero_metadata_or_enumeration_calls() {
    let rejected = test_root().join("unsupported");
    let mut adapter = FakeAdapter::default();
    adapter.rejected.insert(
        rejected.clone(),
        AdmissionAdapterError {
            operation: AdmissionOperation::Validation,
            code: Some(53),
        },
    );
    adapter.metadata.insert(rejected.clone(), directory(1));
    adapter.children.insert(rejected.clone(), Vec::new());

    let report = collect_admission(
        &adapter,
        vec![rejected],
        AdmissionMode::Recurse,
        MAX_ADMITTED_SOURCES,
        compare,
    );

    assert!(report.items.is_empty());
    assert_eq!(adapter.metadata_calls.get(), 0);
    assert_eq!(adapter.enumeration_calls.get(), 0);
    assert_eq!(
        report.issues[0].operation,
        Some(AdmissionOperation::Validation)
    );
    assert_eq!(report.issues[0].code, Some(53));
    assert!(report.summary_korean(0).contains("Validation:53"));
    assert_eq!(report.status_summary_korean(0), "파일 0개 추가 · 1개 제외");
}

#[test]
fn directory_iterator_receives_only_remaining_budget_and_stops() {
    let root = test_root();
    let mut adapter = FakeAdapter::default();
    adapter.metadata.insert(root.clone(), directory(1));
    let children = (0..10)
        .map(|index| root.join(format!("child-{index}")))
        .collect::<Vec<_>>();
    for child in &children {
        adapter.metadata.insert(child.clone(), file());
    }
    adapter.children.insert(root.clone(), children);

    let report = collect_admission(&adapter, vec![root], AdmissionMode::Recurse, 3, compare);

    assert_eq!(report.items.len(), 2);
    assert!(
        report
            .issues
            .iter()
            .any(|issue| issue.kind == AdmissionIssueKind::LimitReached)
    );
    assert_eq!(adapter.enumeration_calls.get(), 1);
}

#[test]
fn repeated_batches_respect_one_global_capacity() {
    let root = test_root();
    let mut adapter = FakeAdapter::default();
    let first = (0..6)
        .map(|index| root.join(format!("first-{index}")))
        .collect::<Vec<_>>();
    let second = (0..6)
        .map(|index| root.join(format!("second-{index}")))
        .collect::<Vec<_>>();
    for path in first.iter().chain(&second) {
        adapter.metadata.insert(path.clone(), file());
    }
    let first_report = collect_admission(&adapter, first, AdmissionMode::Direct, 10, compare);
    let remaining = 10 - first_report.items.len();
    let second_report =
        collect_admission(&adapter, second, AdmissionMode::Direct, remaining, compare);

    assert_eq!(first_report.items.len() + second_report.items.len(), 10);
    assert!(
        second_report
            .issues
            .iter()
            .any(|issue| issue.kind == AdmissionIssueKind::LimitReached)
    );
}

#[test]
fn external_selection_is_bounded_before_path_allocation() {
    assert_eq!(bounded_selection(3, 5).take, 3);
    let overflow = bounded_selection(50_000, 10);
    assert_eq!(overflow.take, 11);
    assert!(overflow.truncated);
    assert_eq!(bounded_selection(5, 0).take, 1);
}

#[test]
fn utf16_path_budget_accepts_exact_boundary_and_rejects_first_overflow() {
    let mut budget = PathBudget::new();
    assert_eq!(
        budget.reserve_utf16_units(MAX_ADMITTED_PATH_BYTES / size_of::<u16>()),
        PathBudgetReservation::Reserved
    );
    assert_eq!(budget.remaining_bytes(), 0);
    assert_eq!(
        budget.reserve_utf16_units(1),
        PathBudgetReservation::Exhausted
    );
    assert_eq!(
        PathBudget::new().reserve_utf16_units(usize::MAX),
        PathBudgetReservation::Exhausted
    );
}

#[test]
fn recursive_admission_reports_aggregate_path_budget_exhaustion() {
    let root = test_root();
    let children = [root.join("one"), root.join("two"), root.join("three")];
    let mut adapter = FakeAdapter::default();
    adapter.metadata.insert(root.clone(), directory(1));
    adapter.children.insert(root.clone(), children.to_vec());
    for path in &children {
        adapter.metadata.insert(path.clone(), file());
        adapter
            .legacy_paths
            .insert(path.clone(), LegacyText::from_units(vec![b'x' as u16; 2]));
    }

    let report = collect_admission_cancellable_with_budget(
        &adapter,
        vec![root],
        AdmissionMode::Recurse,
        MAX_ADMITTED_SOURCES,
        PathBudget::from_remaining_bytes(8),
        compare,
        || false,
    )
    .unwrap_or_default();

    assert_eq!(report.items.len(), 2);
    assert_eq!(report.issues.len(), 1);
    assert_eq!(
        report.issues[0].kind,
        AdmissionIssueKind::PathBudgetExceeded
    );
    assert!(report.summary_korean(2).contains("경로 용량 1"));
}

#[test]
fn repeated_batches_reduce_one_global_path_budget() {
    let root = test_root();
    let paths = [
        root.join("first"),
        root.join("second"),
        root.join("third"),
        root.join("fourth"),
    ];
    let mut adapter = FakeAdapter::default();
    for path in &paths {
        adapter.metadata.insert(path.clone(), file());
        adapter
            .legacy_paths
            .insert(path.clone(), LegacyText::from_units(vec![b'x' as u16; 2]));
    }

    let first = collect_admission_cancellable_with_budget(
        &adapter,
        paths[..2].to_vec(),
        AdmissionMode::Direct,
        MAX_ADMITTED_SOURCES,
        PathBudget::from_remaining_bytes(12),
        compare,
        || false,
    )
    .unwrap_or_default();
    assert_eq!(first.items.len(), 2);

    let mut remaining = PathBudget::from_remaining_bytes(12);
    for item in &first.items {
        assert_eq!(
            remaining.reserve_utf16_units(item.source_path().units().len()),
            PathBudgetReservation::Reserved
        );
    }
    let second = collect_admission_cancellable_with_budget(
        &adapter,
        paths[2..].to_vec(),
        AdmissionMode::Direct,
        MAX_ADMITTED_SOURCES,
        remaining,
        compare,
        || false,
    )
    .unwrap_or_default();

    assert_eq!(second.items.len(), 1);
    assert_eq!(second.issues.len(), 1);
    assert_eq!(
        second.issues[0].kind,
        AdmissionIssueKind::PathBudgetExceeded
    );
}

#[test]
fn import_reader_and_line_parser_are_bounded() -> Result<(), Box<dyn std::error::Error>> {
    let bytes = read_bounded_import(Cursor::new(vec![b'a'; MAX_IMPORT_BYTES]))?;
    assert_eq!(bytes.len(), MAX_IMPORT_BYTES);
    assert!(read_bounded_import(Cursor::new(vec![b'a'; MAX_IMPORT_BYTES + 1])).is_err());

    let text = LegacyText::from(" one \n\n two\nthree\nfour\n");
    let (lines, truncated) = bounded_import_lines(&text, 3);
    assert_eq!(
        lines
            .iter()
            .map(LegacyText::to_string_lossy)
            .collect::<Vec<_>>(),
        vec!["one", "two", "three"]
    );
    assert!(truncated);

    let root = test_root();
    let imported = [LegacyText::from("one"), LegacyText::from("two")];
    let paths = [root.join("one"), root.join("two")];
    let mut adapter = FakeAdapter::default();
    for (path, legacy) in paths.iter().zip(imported) {
        adapter.metadata.insert(path.clone(), file());
        adapter.legacy_paths.insert(path.clone(), legacy);
    }
    let report = collect_admission_cancellable_with_budget(
        &adapter,
        paths.to_vec(),
        AdmissionMode::Direct,
        MAX_ADMITTED_SOURCES,
        PathBudget::from_remaining_bytes(6),
        compare,
        || false,
    )?;
    assert_eq!(report.items.len(), 1);
    assert_eq!(
        report.issues[0].kind,
        AdmissionIssueKind::PathBudgetExceeded
    );
    Ok(())
}

#[test]
fn nested_directory_depth_stops_before_unbounded_enumeration() {
    let root = test_root();
    let mut adapter = FakeAdapter::default();
    let mut current = root.clone();
    for depth in 0..=MAX_ADMISSION_DEPTH {
        adapter
            .metadata
            .insert(current.clone(), directory(depth as u128 + 1));
        let child = current.join("child");
        adapter.children.insert(current, vec![child.clone()]);
        current = child;
    }

    let report = collect_admission(
        &adapter,
        vec![root],
        AdmissionMode::Recurse,
        MAX_ADMITTED_SOURCES,
        compare,
    );

    assert!(
        report
            .issues
            .iter()
            .any(|issue| issue.kind == AdmissionIssueKind::DepthExceeded)
    );
    assert!(adapter.enumeration_calls.get() <= MAX_ADMISSION_DEPTH);
}
