use darknamer_app::rename::{
    EntryId, EntryKind, MemoryBackend, ModelRevision, PlanIssueKind, PlanRequest, RenameIntent,
    RenamePlanner,
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
