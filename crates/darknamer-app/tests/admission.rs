use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use darknamer_app::admission::{
    AdmissionAdapter, AdmissionAdapterError, AdmissionChildren, AdmissionIssueKind,
    AdmissionMetadata, AdmissionMode, MAX_ADMITTED_SOURCES, collect_admission,
};
use darknamer_app::rename::EntryIdentity;
use darknamer_core::LegacyText;

#[derive(Default)]
struct FakeAdapter {
    metadata: BTreeMap<PathBuf, AdmissionMetadata>,
    children: BTreeMap<PathBuf, Vec<PathBuf>>,
}

impl AdmissionAdapter for FakeAdapter {
    fn metadata(&self, path: &Path) -> Result<AdmissionMetadata, AdmissionAdapterError> {
        self.metadata
            .get(path)
            .copied()
            .ok_or(AdmissionAdapterError)
    }

    fn read_children(
        &self,
        path: &Path,
        limit: usize,
    ) -> Result<AdmissionChildren, AdmissionAdapterError> {
        let children = self.children.get(path).ok_or(AdmissionAdapterError)?;
        Ok(AdmissionChildren {
            paths: children.iter().take(limit).cloned().collect(),
            had_errors: false,
            truncated: children.len() > limit,
        })
    }

    fn legacy_path(&self, path: &Path) -> LegacyText {
        LegacyText::from(path.to_string_lossy().into_owned())
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

#[test]
fn iterative_recurse_is_deterministic_and_skips_reparse_and_repeated_directories() {
    let root = PathBuf::from("/root");
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

    let report = collect_admission(&adapter, vec![root], AdmissionMode::Recurse, compare);

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
    let roots = (0..=MAX_ADMITTED_SOURCES)
        .map(|index| PathBuf::from(format!("/file-{index:05}")))
        .collect::<Vec<_>>();
    for path in &roots {
        adapter.metadata.insert(path.clone(), file());
    }

    let report = collect_admission(&adapter, roots, AdmissionMode::Direct, compare);

    assert_eq!(report.items.len(), MAX_ADMITTED_SOURCES);
    assert!(
        report
            .issues
            .iter()
            .any(|issue| issue.kind == AdmissionIssueKind::LimitReached)
    );
}

#[test]
fn relative_path_is_reported_without_metadata_access() {
    let report = collect_admission(
        &FakeAdapter::default(),
        vec![PathBuf::from("relative.txt")],
        AdmissionMode::Direct,
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

    let report = collect_admission(
        &WindowsAdmissionAdapter,
        vec![root, missing],
        AdmissionMode::Recurse,
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
