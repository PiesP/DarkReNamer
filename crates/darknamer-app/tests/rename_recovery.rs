use darknamer_app::rename::{
    AuthorizedJournal, EntryId, EntryIdentity, EntryKind, JournalAuthorization, JournalDirection,
    JournalError, JournalRecord, JournalSnapshot, JournalStep, JournalTerminal, MemoryBackend,
    MemoryJournal, ModelRevision, PlanId, PlanRequest, RecoveryBlockKind, RecoveryFailure,
    RecoveryOutcome, RenameBackend, RenameExecutor, RenameIntent, RenamePlanner, RenameRecovery,
    TemporaryPhase,
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

    let outcome = RenameRecovery::new(&mut backend, &mut recovery_journal).rollback();

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

    let outcome = RenameRecovery::new(&mut backend, &mut journal).rollback();

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

    let outcome = RenameRecovery::new(&mut backend, &mut recovery_journal).rollback();

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
    let outcome = RenameRecovery::new(&mut backend, &mut parent_journal).rollback();
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

    let outcome = RenameRecovery::new(&mut backend, &mut recovery_journal).rollback();

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

#[test]
fn journal_generation_drift_after_snapshot_fails_before_recovery_mutation()
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
    let before = backend.mutation_count();
    let mut recovery_journal = MemoryJournal::from_records(execution_journal.records().to_vec());
    recovery_journal.invalidate_on_next_authorized_append();

    let outcome = RenameRecovery::new(&mut backend, &mut recovery_journal).rollback();

    assert!(matches!(
        outcome,
        RecoveryOutcome::RecoveryRequired {
            plan,
            reason: RecoveryFailure::Journal(_),
        } if plan == id
    ));
    assert_eq!(backend.mutation_count(), before);
    Ok(())
}

struct FailNotAppliedJournal {
    inner: MemoryJournal,
}

impl AuthorizedJournal for FailNotAppliedJournal {
    fn authorized_snapshot(&mut self) -> Result<JournalSnapshot, JournalError> {
        self.inner.authorized_snapshot()
    }

    fn authorized_prepared(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.inner
            .authorized_prepared(authorization, step, direction)
    }

    fn authorized_completed(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.inner
            .authorized_completed(authorization, step, direction)
    }

    fn authorized_not_applied(
        &mut self,
        _authorization: &mut JournalAuthorization,
        _step: usize,
        _direction: JournalDirection,
    ) -> Result<(), JournalError> {
        Err(JournalError::not_appended(88))
    }

    fn authorized_terminal(
        &mut self,
        authorization: &mut JournalAuthorization,
        terminal: JournalTerminal,
    ) -> Result<(), JournalError> {
        self.inner.authorized_terminal(authorization, terminal)
    }
}

#[test]
fn rollback_not_applied_journal_failure_is_preserved() -> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\b.txt", 1);
    let source = LegacyText::from("C:\\work\\a.txt");
    let destination = LegacyText::from("C:\\work\\b.txt");
    let source_parent = backend.observe(&source)?.parent;
    let destination_parent = backend.observe(&destination)?.parent;
    let step = JournalStep::new(
        EntryId::new(0),
        source,
        destination,
        EntryIdentity::new(1, 1),
        source_parent,
        destination_parent,
        TemporaryPhase::None,
    );
    let plan = PlanId::from_fingerprint(9);
    let records = vec![
        JournalRecord::Intent {
            plan,
            steps: vec![step].into_boxed_slice(),
        },
        JournalRecord::Prepared {
            step: 0,
            direction: JournalDirection::Forward,
        },
        JournalRecord::Completed {
            step: 0,
            direction: JournalDirection::Forward,
        },
    ];
    backend.fail_move_on(1, 32);
    let mut journal = FailNotAppliedJournal {
        inner: MemoryJournal::from_records(records),
    };

    let outcome = RenameRecovery::new(&mut backend, &mut journal).rollback();

    assert_eq!(
        outcome,
        RecoveryOutcome::RecoveryRequired {
            plan,
            reason: RecoveryFailure::Journal(JournalError::not_appended(88)),
        }
    );
    assert_eq!(backend.mutation_count(), 0);
    Ok(())
}
