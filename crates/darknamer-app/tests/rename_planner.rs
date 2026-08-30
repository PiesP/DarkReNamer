use std::cell::Cell;

use darknamer_app::rename::{
    BackendError, EntryId, EntryKind, MAX_PLAN_PATH_DEPTH, MemoryBackend, ModelRevision, PathKey,
    PathSnapshot, PlanAttemptError, PlanIssueKind, PlanRequest, RenameBackend, RenameIntent,
    RenameOperation, RenamePlanner,
};
use darknamer_core::{LegacyText, WindowsLeafNameError};

fn intent(id: u32, source: &str, destination_name: &str) -> RenameIntent {
    RenameIntent::new(
        EntryId::new(id),
        source,
        "C:\\work",
        destination_name,
        EntryKind::File,
    )
}

#[test]
fn unchanged_entry_produces_an_empty_execution_plan() -> Result<(), Box<dyn std::error::Error>> {
    let backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let request = PlanRequest::new(
        ModelRevision::new(7),
        vec![intent(0, "C:\\work\\a.txt", "a.txt")],
    );

    let plan = RenamePlanner::new(&backend).plan(request)?;

    assert_eq!(plan.revision(), ModelRevision::new(7));
    assert_eq!(plan.changed_count(), 0);
    assert!(plan.is_empty());
    Ok(())
}

#[test]
fn invalid_sources_and_destination_leaf_names_are_structured_blockers()
-> Result<(), Box<dyn std::error::Error>> {
    let backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let invalid_names = [
        (
            LegacyText::from_units(vec![b'a' as u16, 0]),
            WindowsLeafNameError::ContainsNul,
        ),
        (
            LegacyText::from("a/b"),
            WindowsLeafNameError::ContainsSeparator,
        ),
        (
            LegacyText::from("a\\b"),
            WindowsLeafNameError::ContainsSeparator,
        ),
        (LegacyText::from(".."), WindowsLeafNameError::DotComponent),
        (
            LegacyText::from("NUL.txt"),
            WindowsLeafNameError::ReservedDeviceName,
        ),
        (
            LegacyText::from("name."),
            WindowsLeafNameError::TrailingDotOrSpace,
        ),
        (
            LegacyText::from("name "),
            WindowsLeafNameError::TrailingDotOrSpace,
        ),
        (
            LegacyText::from("x".repeat(256)),
            WindowsLeafNameError::TooLong,
        ),
    ];

    for (index, (name, expected)) in invalid_names.into_iter().enumerate() {
        let request = PlanRequest::new(
            ModelRevision::new(index as u64),
            vec![RenameIntent::new(
                EntryId::new(index as u32),
                "C:\\work\\a.txt",
                "C:\\work",
                name,
                EntryKind::File,
            )],
        );
        let Err(error) = RenamePlanner::new(&backend).plan(request) else {
            return Err(std::io::Error::other("invalid destination was accepted").into());
        };
        assert_eq!(
            error.issues()[0].kind,
            PlanIssueKind::InvalidDestinationName(expected)
        );
    }

    let relative = PlanRequest::new(
        ModelRevision::new(99),
        vec![intent(99, "work\\a.txt", "b.txt")],
    );
    let Err(error) = RenamePlanner::new(&backend).plan(relative) else {
        return Err(std::io::Error::other("relative source was accepted").into());
    };
    assert_eq!(error.issues()[0].kind, PlanIssueKind::RelativeSource);
    Ok(())
}

#[test]
fn duplicate_and_external_occupied_destinations_are_blocked()
-> Result<(), Box<dyn std::error::Error>> {
    let backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2)
        .with_file("C:\\work\\occupied.txt", 3);

    let duplicate = PlanRequest::new(
        ModelRevision::new(1),
        vec![
            intent(0, "C:\\work\\a.txt", "same.txt"),
            intent(1, "C:\\work\\b.txt", "SAME.txt"),
        ],
    );
    let Err(duplicate_error) = RenamePlanner::new(&backend).plan(duplicate) else {
        return Err(std::io::Error::other("duplicate destinations were accepted").into());
    };
    assert!(
        duplicate_error
            .issues()
            .iter()
            .all(|issue| issue.kind == PlanIssueKind::DuplicateDestination)
    );

    let occupied = PlanRequest::new(
        ModelRevision::new(2),
        vec![intent(0, "C:\\work\\a.txt", "occupied.txt")],
    );
    let Err(occupied_error) = RenamePlanner::new(&backend).plan(occupied) else {
        return Err(std::io::Error::other("external destination was accepted").into());
    };
    assert_eq!(
        occupied_error.issues()[0].kind,
        PlanIssueKind::DestinationOccupied
    );
    Ok(())
}

#[test]
fn planner_blocks_duplicate_identity_inputs_cross_parent_and_source_overlap()
-> Result<(), Box<dyn std::error::Error>> {
    let backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\folder", 2)
        .with_file("C:\\work\\folder\\child.txt", 3);

    let duplicate_id = PlanRequest::new(
        ModelRevision::new(1),
        vec![
            intent(7, "C:\\work\\a.txt", "b.txt"),
            intent(7, "C:\\work\\folder", "renamed"),
        ],
    );
    let Err(error) = RenamePlanner::new(&backend).plan(duplicate_id) else {
        return Err(std::io::Error::other("duplicate entry id was accepted").into());
    };
    assert!(
        error
            .issues()
            .iter()
            .any(|issue| issue.kind == PlanIssueKind::DuplicateEntryId)
    );

    let duplicate_source = PlanRequest::new(
        ModelRevision::new(2),
        vec![
            intent(1, "C:\\work\\a.txt", "b.txt"),
            intent(2, "C:\\WORK\\A.TXT", "c.txt"),
        ],
    );
    let Err(error) = RenamePlanner::new(&backend).plan(duplicate_source) else {
        return Err(std::io::Error::other("duplicate source key was accepted").into());
    };
    assert!(
        error
            .issues()
            .iter()
            .all(|issue| issue.kind == PlanIssueKind::DuplicateSource)
    );

    let cross_parent = PlanRequest::new(
        ModelRevision::new(3),
        vec![RenameIntent::new(
            EntryId::new(3),
            "C:\\work\\a.txt",
            "C:\\other",
            "a.txt",
            EntryKind::File,
        )],
    );
    let Err(error) = RenamePlanner::new(&backend).plan(cross_parent) else {
        return Err(std::io::Error::other("cross-parent move was accepted").into());
    };
    assert_eq!(error.issues()[0].kind, PlanIssueKind::CrossParent);

    let overlap = PlanRequest::new(
        ModelRevision::new(4),
        vec![
            intent(4, "C:\\work\\folder", "renamed"),
            RenameIntent::new(
                EntryId::new(5),
                "C:\\work\\folder\\child.txt",
                "C:\\work\\folder",
                "child-2.txt",
                EntryKind::File,
            ),
        ],
    );
    let Err(error) = RenamePlanner::new(&backend).plan(overlap) else {
        return Err(std::io::Error::other("ancestor source overlap was accepted").into());
    };
    assert!(
        error
            .issues()
            .iter()
            .all(|issue| issue.kind == PlanIssueKind::SourceOverlap)
    );
    Ok(())
}

#[test]
fn occupied_hard_link_is_not_treated_as_a_pending_source_path()
-> Result<(), Box<dyn std::error::Error>> {
    let backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\hard-link.txt", 1);
    let request = PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, "C:\\work\\a.txt", "hard-link.txt")],
    );

    let Err(error) = RenamePlanner::new(&backend).plan(request) else {
        return Err(std::io::Error::other("occupied hard link was accepted").into());
    };
    assert_eq!(error.issues()[0].kind, PlanIssueKind::DestinationOccupied);
    Ok(())
}

#[test]
fn plan_exposes_stable_preview_rows_and_joins_root_without_double_separator()
-> Result<(), Box<dyn std::error::Error>> {
    let backend = MemoryBackend::new().with_file("C:\\a.txt", 1);
    let request = PlanRequest::new(
        ModelRevision::new(1),
        vec![RenameIntent::new(
            EntryId::new(42),
            "C:\\a.txt",
            "C:\\",
            "b.txt",
            EntryKind::File,
        )],
    );

    let plan = RenamePlanner::new(&backend).plan(request)?;
    assert_eq!(plan.rows().len(), 1);
    assert_eq!(plan.rows()[0].entry(), EntryId::new(42));
    assert_eq!(plan.rows()[0].source().to_string_lossy(), "C:\\a.txt");
    assert_eq!(plan.rows()[0].destination().to_string_lossy(), "C:\\b.txt");
    assert_eq!(plan.rows()[0].kind(), EntryKind::File);
    assert_ne!(plan.fingerprint(), 0);
    Ok(())
}

struct CanonicalKeyBackend {
    inner: MemoryBackend,
}

impl RenameBackend for CanonicalKeyBackend {
    fn validate_path_environment(&self, path: &LegacyText) -> Result<(), BackendError> {
        self.inner.validate_path_environment(path)
    }

    fn path_key(&self, path: &LegacyText) -> PathKey {
        let opaque = path
            .to_string_lossy()
            .to_lowercase()
            .chars()
            .rev()
            .collect::<String>();
        PathKey::exact(&LegacyText::from(opaque))
    }

    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError> {
        self.inner.observe(path)
    }

    fn is_same_or_descendant(
        &self,
        ancestor: &LegacyText,
        candidate: &LegacyText,
    ) -> Result<bool, BackendError> {
        self.inner.is_same_or_descendant(ancestor, candidate)
    }

    fn next_transaction_nonce(&mut self) -> Result<u128, BackendError> {
        self.inner.next_transaction_nonce()
    }

    fn rename_no_replace(&mut self, operation: &RenameOperation) -> Result<(), BackendError> {
        self.inner.rename_no_replace(operation)
    }
}

#[test]
fn ancestor_detection_does_not_interpret_backend_equality_keys_as_paths()
-> Result<(), Box<dyn std::error::Error>> {
    let backend = CanonicalKeyBackend {
        inner: MemoryBackend::new()
            .with_file("C:\\work\\folder", 1)
            .with_file("C:\\work\\folder\\child.txt", 2),
    };
    let request = PlanRequest::new(
        ModelRevision::new(1),
        vec![
            intent(1, "C:\\work\\folder", "renamed"),
            RenameIntent::new(
                EntryId::new(2),
                "C:\\work\\folder\\child.txt",
                "C:\\work\\folder",
                "child-2.txt",
                EntryKind::File,
            ),
        ],
    );

    let Err(error) = RenamePlanner::new(&backend).plan(request) else {
        return Err(std::io::Error::other("canonical keys hid source overlap").into());
    };
    assert!(
        error
            .issues()
            .iter()
            .all(|issue| issue.kind == PlanIssueKind::SourceOverlap)
    );
    Ok(())
}

struct CountingBackend {
    inner: MemoryBackend,
    validation_calls: Cell<usize>,
    key_calls: Cell<usize>,
    observe_calls: Cell<usize>,
    relationship_calls: Cell<usize>,
}

impl RenameBackend for CountingBackend {
    fn validate_path_environment(&self, path: &LegacyText) -> Result<(), BackendError> {
        self.validation_calls.set(self.validation_calls.get() + 1);
        self.inner.validate_path_environment(path)
    }

    fn path_key(&self, path: &LegacyText) -> PathKey {
        self.key_calls.set(self.key_calls.get() + 1);
        self.inner.path_key(path)
    }

    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError> {
        self.observe_calls.set(self.observe_calls.get() + 1);
        self.inner.observe(path)
    }

    fn is_same_or_descendant(
        &self,
        ancestor: &LegacyText,
        candidate: &LegacyText,
    ) -> Result<bool, BackendError> {
        self.relationship_calls
            .set(self.relationship_calls.get() + 1);
        self.inner.is_same_or_descendant(ancestor, candidate)
    }

    fn next_transaction_nonce(&mut self) -> Result<u128, BackendError> {
        self.inner.next_transaction_nonce()
    }

    fn rename_no_replace(&mut self, operation: &RenameOperation) -> Result<(), BackendError> {
        self.inner.rename_no_replace(operation)
    }
}

#[test]
fn nested_overlap_detection_has_bounded_calls_and_one_issue_per_row() {
    let count = 128_usize;
    let mut inner = MemoryBackend::new();
    let mut intents = Vec::with_capacity(count);
    let mut parent = "C:\\root".to_owned();
    for index in 0..count {
        let source = format!("{parent}\\node-{index}");
        inner = inner.with_file(source.clone(), index as u128 + 1);
        intents.push(RenameIntent::new(
            EntryId::new(index as u32),
            source.clone(),
            parent.clone(),
            format!("renamed-{index}"),
            EntryKind::File,
        ));
        parent = source;
    }
    let backend = CountingBackend {
        inner,
        validation_calls: Cell::new(0),
        key_calls: Cell::new(0),
        observe_calls: Cell::new(0),
        relationship_calls: Cell::new(0),
    };

    let error = RenamePlanner::new(&backend)
        .plan(PlanRequest::new(ModelRevision::new(1), intents))
        .err();
    let Some(error) = error else {
        return;
    };
    assert!(error.issues().len() <= count);
    assert_eq!(backend.relationship_calls.get(), 0);
    assert!(backend.key_calls.get() <= count * (MAX_PLAN_PATH_DEPTH + 8));
}

#[test]
fn direct_request_rejects_excessive_path_depth_before_backend_access()
-> Result<(), Box<dyn std::error::Error>> {
    let mut deep_path = String::from("C:\\");
    deep_path.push_str(
        &(0..=MAX_PLAN_PATH_DEPTH)
            .map(|index| format!("p{index}"))
            .collect::<Vec<_>>()
            .join("\\"),
    );
    let backend = CountingBackend {
        inner: MemoryBackend::new(),
        validation_calls: Cell::new(0),
        key_calls: Cell::new(0),
        observe_calls: Cell::new(0),
        relationship_calls: Cell::new(0),
    };
    for request in [
        RenameIntent::new(
            EntryId::new(1),
            deep_path.clone(),
            "C:\\work",
            "renamed.txt",
            EntryKind::File,
        ),
        RenameIntent::new(
            EntryId::new(2),
            "C:\\work\\source.txt",
            deep_path,
            "renamed.txt",
            EntryKind::File,
        ),
    ] {
        let Err(error) = RenamePlanner::new(&backend)
            .plan(PlanRequest::new(ModelRevision::new(1), vec![request]))
        else {
            return Err(
                std::io::Error::other("over-depth direct request did not fail closed").into(),
            );
        };
        assert_eq!(error.issues().len(), 1);
        assert_eq!(error.issues()[0].kind, PlanIssueKind::PathTooDeep);
    }
    assert_eq!(backend.validation_calls.get(), 0);
    assert_eq!(backend.key_calls.get(), 0);
    assert_eq!(backend.observe_calls.get(), 0);
    assert_eq!(backend.relationship_calls.get(), 0);
    assert_eq!(backend.inner.mutation_count(), 0);
    Ok(())
}

#[test]
fn cancellation_stops_planner_before_all_backend_observations() {
    let count = 128_usize;
    let mut inner = MemoryBackend::new();
    let mut intents = Vec::with_capacity(count);
    for index in 0..count {
        let source = format!("C:\\work\\source-{index:03}.txt");
        inner = inner.with_file(source.clone(), index as u128 + 1);
        intents.push(intent(
            index as u32,
            &source,
            &format!("target-{index:03}.txt"),
        ));
    }
    let backend = CountingBackend {
        inner,
        validation_calls: Cell::new(0),
        key_calls: Cell::new(0),
        observe_calls: Cell::new(0),
        relationship_calls: Cell::new(0),
    };
    let checks = Cell::new(0_usize);

    let result = RenamePlanner::new(&backend).plan_cancellable(
        PlanRequest::new(ModelRevision::new(1), intents),
        || {
            let next = checks.get().saturating_add(1);
            checks.set(next);
            next >= 32
        },
    );

    assert_eq!(result, Err(PlanAttemptError::Cancelled));
    assert!(backend.observe_calls.get() < count * 2);
    assert_eq!(backend.inner.mutation_count(), 0);
}
