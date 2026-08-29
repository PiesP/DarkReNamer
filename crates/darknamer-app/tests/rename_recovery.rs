use darknamer_app::rename::{
    EntryId, EntryKind, JournalDirection, JournalRecord, JournalStep, MemoryBackend, MemoryJournal,
    ModelRevision, PlanRequest, RecoveryBlockKind, RecoveryOutcome, RenameExecutor, RenameIntent,
    RenamePlanner, RenameRecovery, TemporaryPhase,
};
use darknamer_core::LegacyText;

fn intent() -> RenameIntent {
    RenameIntent::new(
        EntryId::new(0),
        "C:\\work\\a.txt",
        "C:\\work",
        "b.txt",
        EntryKind::File,
    )
}

#[test]
fn prepared_forward_observed_at_destination_rolls_back_to_original()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let plan = RenamePlanner::new(&backend)
        .plan(PlanRequest::new(ModelRevision::new(1), vec![intent()]))?;
    let id = plan.id();
    let revision = plan.revision();
    let confirmed = plan.confirm_presented(id, revision)?;
    backend.fail_ambiguous_move_on(1, 995);
    let mut execution_journal = MemoryJournal::new();
    let _ = RenameExecutor::new(&mut backend, &mut execution_journal).execute(confirmed)?;
    let records = execution_journal.records().to_vec();
    let mut recovery_journal = MemoryJournal::from_records(records.clone());

    let outcome = RenameRecovery::new(&mut backend, &mut recovery_journal).rollback(&records);

    assert_eq!(
        outcome,
        RecoveryOutcome::Recovered {
            plan: id,
            restored_steps: 1
        }
    );
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    assert_eq!(backend.file_id("C:\\work\\b.txt"), None);
    Ok(())
}

#[test]
fn prepared_forward_observed_at_source_is_closed_without_filesystem_mutation()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let source = LegacyText::from("C:\\work\\a.txt");
    let destination = LegacyText::from("C:\\work\\b.txt");
    let source_snapshot = darknamer_app::rename::RenameBackend::observe(&backend, &source)?;
    let destination_snapshot =
        darknamer_app::rename::RenameBackend::observe(&backend, &destination)?;
    let source_entry = source_snapshot
        .entry
        .ok_or_else(|| std::io::Error::other("test source missing"))?;
    let plan = RenamePlanner::new(&backend)
        .plan(PlanRequest::new(ModelRevision::new(1), vec![intent()]))?;
    let step = JournalStep::new(
        EntryId::new(0),
        source,
        destination,
        source_entry.identity,
        source_snapshot.parent,
        destination_snapshot.parent,
        TemporaryPhase::None,
    );
    let records = vec![
        JournalRecord::Intent {
            plan: plan.id(),
            steps: vec![step].into_boxed_slice(),
        },
        JournalRecord::Prepared {
            step: 0,
            direction: JournalDirection::Forward,
        },
    ];
    let mut journal = MemoryJournal::from_records(records.clone());

    let outcome = RenameRecovery::new(&mut backend, &mut journal).rollback(&records);

    assert_eq!(
        outcome,
        RecoveryOutcome::Recovered {
            plan: plan.id(),
            restored_steps: 0
        }
    );
    assert_eq!(backend.mutation_count(), 0);
    Ok(())
}

#[test]
fn ambiguous_identity_or_changed_parent_blocks_without_speculative_mutation()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let plan = RenamePlanner::new(&backend)
        .plan(PlanRequest::new(ModelRevision::new(1), vec![intent()]))?;
    let id = plan.id();
    let revision = plan.revision();
    let confirmed = plan.confirm_presented(id, revision)?;
    backend.fail_ambiguous_move_on(1, 995);
    let mut execution_journal = MemoryJournal::new();
    let _ = RenameExecutor::new(&mut backend, &mut execution_journal).execute(confirmed)?;
    let records = execution_journal.records().to_vec();
    backend.replace_file_id("C:\\work\\b.txt", 99);
    let before = backend.mutation_count();
    let mut recovery_journal = MemoryJournal::from_records(records.clone());

    let outcome = RenameRecovery::new(&mut backend, &mut recovery_journal).rollback(&records);

    assert!(matches!(
        outcome,
        RecoveryOutcome::Blocked {
            reason: RecoveryBlockKind::StateMismatch,
            ..
        }
    ));
    assert_eq!(backend.mutation_count(), before);

    backend.replace_file_id("C:\\work\\b.txt", 1);
    backend.replace_parent_id("C:\\work\\b.txt", 77);
    let mut parent_journal = MemoryJournal::from_records(records.clone());
    let outcome = RenameRecovery::new(&mut backend, &mut parent_journal).rollback(&records);
    assert!(matches!(
        outcome,
        RecoveryOutcome::Blocked {
            reason: RecoveryBlockKind::ParentChanged,
            ..
        }
    ));
    assert_eq!(backend.mutation_count(), before);
    Ok(())
}

#[test]
fn prepared_chain_step_reconciles_then_rolls_back_in_reverse_schedule_order()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2);
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![
            intent(),
            RenameIntent::new(
                EntryId::new(1),
                "C:\\work\\b.txt",
                "C:\\work",
                "c.txt",
                EntryKind::File,
            ),
        ],
    ))?;
    let id = plan.id();
    let revision = plan.revision();
    let confirmed = plan.confirm_presented(id, revision)?;
    backend.fail_ambiguous_move_on(2, 995);
    let mut execution_journal = MemoryJournal::new();
    let _ = RenameExecutor::new(&mut backend, &mut execution_journal).execute(confirmed)?;
    let records = execution_journal.records().to_vec();
    let mut recovery_journal = MemoryJournal::from_records(records.clone());

    let outcome = RenameRecovery::new(&mut backend, &mut recovery_journal).rollback(&records);

    assert_eq!(
        outcome,
        RecoveryOutcome::Recovered {
            plan: id,
            restored_steps: 2
        }
    );
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    assert_eq!(backend.file_id("C:\\work\\b.txt"), Some(2));
    assert_eq!(backend.file_id("C:\\work\\c.txt"), None);
    Ok(())
}
