use darknamer_app::rename::{
    EntryId, EntryKind, ExecuteErrorKind, ExecutionOutcome, JournalRecord, JournalTerminal,
    MAX_TEMP_CANDIDATES, MemoryBackend, MemoryJournal, ModelRevision, MutationCertainty,
    PlanRequest, RecoveryState, RenameBackend, RenameExecutor, RenameIntent, RenameOperation,
    RenamePlanner,
};

fn intent(id: u32, source_name: &str, destination_name: &str) -> RenameIntent {
    RenameIntent::new(
        EntryId::new(id),
        format!("C:\\work\\{source_name}"),
        "C:\\work",
        destination_name,
        EntryKind::File,
    )
}

fn confirmed_plan(
    backend: &MemoryBackend,
    intents: Vec<RenameIntent>,
) -> Result<darknamer_app::rename::ConfirmedPlan, Box<dyn std::error::Error>> {
    let plan =
        RenamePlanner::new(backend).plan(PlanRequest::new(ModelRevision::new(1), intents))?;
    let id = plan.id();
    let revision = plan.revision();
    Ok(plan.confirm_presented(id, revision)?)
}

#[test]
fn chain_executes_in_reverse_dependency_order_without_a_temporary_name()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2);
    let confirmed = confirmed_plan(
        &backend,
        vec![intent(0, "a.txt", "b.txt"), intent(1, "b.txt", "c.txt")],
    )?;
    let mut journal = MemoryJournal::new();

    let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;

    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert_eq!(
        backend.completed_moves(),
        &[
            ("C:\\work\\b.txt".to_owned(), "C:\\work\\c.txt".to_owned()),
            ("C:\\work\\a.txt".to_owned(), "C:\\work\\b.txt".to_owned()),
        ]
    );
    assert_eq!(backend.file_id("C:\\work\\b.txt"), Some(1));
    assert_eq!(backend.file_id("C:\\work\\c.txt"), Some(2));
    Ok(())
}

#[test]
fn case_only_rename_uses_one_same_parent_temporary_hop() -> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\A.TXT", 1);
    let confirmed = confirmed_plan(&backend, vec![intent(0, "A.TXT", "a.txt")])?;
    let mut journal = MemoryJournal::new();

    let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;

    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert_eq!(backend.completed_moves().len(), 2);
    assert!(backend.completed_moves()[0].1.contains(".__darknamer_"));
    assert_eq!(backend.completed_moves()[1].1, "C:\\work\\a.txt");
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    Ok(())
}

#[test]
fn two_and_three_entry_cycles_use_one_temporary_hop_each() -> Result<(), Box<dyn std::error::Error>>
{
    let mut two = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2);
    let confirmed = confirmed_plan(
        &two,
        vec![intent(0, "a.txt", "b.txt"), intent(1, "b.txt", "a.txt")],
    )?;
    let mut two_journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut two, &mut two_journal).execute(confirmed)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert_eq!(two.completed_moves().len(), 3);
    assert_eq!(two.file_id("C:\\work\\a.txt"), Some(2));
    assert_eq!(two.file_id("C:\\work\\b.txt"), Some(1));

    let mut three = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2)
        .with_file("C:\\work\\c.txt", 3);
    let confirmed = confirmed_plan(
        &three,
        vec![
            intent(0, "a.txt", "b.txt"),
            intent(1, "b.txt", "c.txt"),
            intent(2, "c.txt", "a.txt"),
        ],
    )?;
    let mut three_journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut three, &mut three_journal).execute(confirmed)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert_eq!(three.completed_moves().len(), 4);
    assert_eq!(three.file_id("C:\\work\\a.txt"), Some(3));
    assert_eq!(three.file_id("C:\\work\\b.txt"), Some(1));
    assert_eq!(three.file_id("C:\\work\\c.txt"), Some(2));
    Ok(())
}

#[test]
fn stale_source_parent_or_destination_refuses_before_journal_and_mutation()
-> Result<(), Box<dyn std::error::Error>> {
    let mut source_backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let source_plan = confirmed_plan(&source_backend, vec![intent(0, "a.txt", "b.txt")])?;
    source_backend.replace_file_id("C:\\work\\a.txt", 99);
    let mut source_journal = MemoryJournal::new();
    let source_error = RenameExecutor::new(&mut source_backend, &mut source_journal)
        .execute(source_plan)
        .err()
        .ok_or_else(|| std::io::Error::other("stale source was executed"))?;
    assert_eq!(source_error.kind, ExecuteErrorKind::StaleSource);
    assert_eq!(source_backend.mutation_count(), 0);
    assert!(source_journal.records().is_empty());

    let mut parent_backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let parent_plan = confirmed_plan(&parent_backend, vec![intent(0, "a.txt", "b.txt")])?;
    parent_backend.replace_parent_id("C:\\work\\a.txt", 99);
    let mut parent_journal = MemoryJournal::new();
    let parent_error = RenameExecutor::new(&mut parent_backend, &mut parent_journal)
        .execute(parent_plan)
        .err()
        .ok_or_else(|| std::io::Error::other("stale parent was executed"))?;
    assert_eq!(parent_error.kind, ExecuteErrorKind::StaleParent);
    assert_eq!(parent_backend.mutation_count(), 0);
    assert!(parent_journal.records().is_empty());

    let mut destination_backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let destination_plan = confirmed_plan(&destination_backend, vec![intent(0, "a.txt", "b.txt")])?;
    destination_backend.insert_file("C:\\work\\b.txt", 2);
    let mut destination_journal = MemoryJournal::new();
    let destination_error = RenameExecutor::new(&mut destination_backend, &mut destination_journal)
        .execute(destination_plan)
        .err()
        .ok_or_else(|| std::io::Error::other("occupied destination was executed"))?;
    assert_eq!(destination_error.kind, ExecuteErrorKind::DestinationChanged);
    assert_eq!(destination_backend.mutation_count(), 0);
    assert!(destination_journal.records().is_empty());
    Ok(())
}

#[test]
fn forward_failure_rolls_completed_moves_back_in_reverse_order()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2);
    let confirmed = confirmed_plan(
        &backend,
        vec![intent(0, "a.txt", "b.txt"), intent(1, "b.txt", "c.txt")],
    )?;
    backend.fail_move_on(2, 5);
    let mut journal = MemoryJournal::new();

    let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;

    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RolledBack { .. }
    ));
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    assert_eq!(backend.file_id("C:\\work\\b.txt"), Some(2));
    assert_eq!(backend.file_id("C:\\work\\c.txt"), None);
    assert_eq!(journal.recovery_state(), RecoveryState::Clean);
    assert_eq!(
        journal.records().last(),
        Some(&JournalRecord::Terminal(JournalTerminal::RolledBack))
    );
    Ok(())
}

#[test]
fn rollback_failure_is_structured_and_journal_replays_as_recovery_required()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2);
    let confirmed = confirmed_plan(
        &backend,
        vec![intent(0, "a.txt", "b.txt"), intent(1, "b.txt", "c.txt")],
    )?;
    backend.fail_move_on(2, 5);
    backend.fail_move_on(3, 32);
    let mut journal = MemoryJournal::new();

    let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;

    let ExecutionOutcome::RecoveryRequired {
        rollback_failures, ..
    } = report.outcome()
    else {
        return Err(std::io::Error::other("rollback failure was hidden").into());
    };
    assert_eq!(rollback_failures.len(), 1);
    assert!(matches!(
        journal.recovery_state(),
        RecoveryState::RecoveryRequired {
            completed_forward: 1,
            completed_rollback: 0,
            ..
        }
    ));
    assert!(
        !journal
            .records()
            .iter()
            .any(|record| matches!(record, JournalRecord::Terminal(_)))
    );
    Ok(())
}

#[test]
fn backend_enforces_expected_parent_identities_at_the_mutation_seam()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let source = darknamer_core::LegacyText::from("C:\\work\\a.txt");
    let destination = darknamer_core::LegacyText::from("C:\\work\\b.txt");
    let source_snapshot = backend.observe(&source)?;
    let destination_snapshot = backend.observe(&destination)?;
    backend.replace_parent_id("C:\\work\\a.txt", 99);
    let source_entry = source_snapshot
        .entry
        .ok_or_else(|| std::io::Error::other("test source missing"))?;
    let operation = RenameOperation::new(
        source,
        destination,
        source_entry.identity,
        source_snapshot.parent,
        destination_snapshot.parent,
    );

    let error = backend
        .rename_no_replace(&operation)
        .err()
        .ok_or_else(|| std::io::Error::other("stale parent mutation succeeded"))?;

    assert_eq!(error.certainty, MutationCertainty::NotApplied);
    assert_eq!(backend.mutation_count(), 0);
    Ok(())
}

#[test]
fn ambiguous_backend_error_stops_without_rollback_and_requires_recovery()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let confirmed = confirmed_plan(&backend, vec![intent(0, "a.txt", "b.txt")])?;
    backend.fail_ambiguous_move_on(1, 995);
    let mut journal = MemoryJournal::new();

    let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;

    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RecoveryRequired { .. }
    ));
    assert_eq!(backend.mutation_count(), 1);
    assert_eq!(backend.file_id("C:\\work\\b.txt"), Some(1));
    assert!(matches!(
        journal.recovery_state(),
        RecoveryState::RecoveryRequired { .. }
    ));
    Ok(())
}

#[test]
fn temporary_selection_retries_occupied_names_and_fails_closed_when_exhausted()
-> Result<(), Box<dyn std::error::Error>> {
    let nonce = 7_u128;
    let mut retry_backend = MemoryBackend::new().with_file("C:\\work\\A.TXT", 1);
    let plan = RenamePlanner::new(&retry_backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, "A.TXT", "a.txt")],
    ))?;
    let fingerprint = plan.fingerprint();
    retry_backend.set_next_transaction_nonce(nonce);
    retry_backend.insert_file(temp_path(fingerprint, nonce, 0, 0), 50);
    let id = plan.id();
    let revision = plan.revision();
    let confirmed = plan.confirm_presented(id, revision)?;
    let mut retry_journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut retry_backend, &mut retry_journal).execute(confirmed)?;
    assert_eq!(report.outcome(), &ExecutionOutcome::Completed);
    assert!(retry_backend.completed_moves()[0].1.ends_with("_01.tmp"));

    let mut exhausted_backend = MemoryBackend::new().with_file("C:\\work\\A.TXT", 1);
    let plan = RenamePlanner::new(&exhausted_backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![intent(0, "A.TXT", "a.txt")],
    ))?;
    let fingerprint = plan.fingerprint();
    exhausted_backend.set_next_transaction_nonce(nonce);
    for ordinal in 0..MAX_TEMP_CANDIDATES {
        exhausted_backend.insert_file(
            temp_path(fingerprint, nonce, 0, ordinal),
            100 + ordinal as u128,
        );
    }
    let id = plan.id();
    let revision = plan.revision();
    let confirmed = plan.confirm_presented(id, revision)?;
    let mut exhausted_journal = MemoryJournal::new();
    let error = RenameExecutor::new(&mut exhausted_backend, &mut exhausted_journal)
        .execute(confirmed)
        .err()
        .ok_or_else(|| std::io::Error::other("temporary exhaustion was ignored"))?;
    assert_eq!(error.kind, ExecuteErrorKind::TemporaryExhausted);
    assert_eq!(exhausted_backend.mutation_count(), 0);
    assert!(exhausted_journal.records().is_empty());
    Ok(())
}

fn temp_path(fingerprint: u64, nonce: u128, entry: u32, ordinal: usize) -> String {
    format!("C:\\work\\.__darknamer_{fingerprint:016x}_{nonce:032x}_{entry:08x}_{ordinal:02x}.tmp")
}
