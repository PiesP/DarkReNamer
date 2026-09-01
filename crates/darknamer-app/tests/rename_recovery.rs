use darknamer_app::rename::{
    AppendCertainty, AuthorizedJournal, BackendError, EntryId, EntryIdentity, EntryKind,
    ExecutionOutcome, JournalAuthorization, JournalDirection, JournalError, JournalRecord,
    JournalSnapshot, JournalStep, JournalStore, JournalTerminal, MemoryBackend, MemoryJournal,
    ModelRevision, PathKey, PathSnapshot, PlanId, PlanRequest, RecoveryBlockKind, RecoveryFailure,
    RecoveryOutcome, RenameBackend, RenameExecutor, RenameIntent, RenameOperation, RenamePlanner,
    RenameRecovery, TemporaryPhase,
};
use darknamer_core::LegacyText;
use std::cell::RefCell;
use std::rc::Rc;

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

struct PreparedFixtureJournal {
    inner: MemoryJournal,
}

impl JournalStore for PreparedFixtureJournal {
    fn begin(&mut self, plan: PlanId, steps: &[JournalStep]) -> Result<(), JournalError> {
        self.inner.begin(plan, steps)
    }

    fn prepared(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.inner.prepared(step, direction)?;
        Err(JournalError::may_have_appended(1_120))
    }

    fn completed(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.inner.completed(step, direction)
    }

    fn not_applied(
        &mut self,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.inner.not_applied(step, direction)
    }

    fn terminal(&mut self, terminal: JournalTerminal) -> Result<(), JournalError> {
        self.inner.terminal(terminal)
    }
}

#[derive(Clone, Copy)]
enum PreparedLocation {
    Source,
    Destination,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AuthorizedMatrixCall {
    Prepared(usize, JournalDirection),
    Completed(usize, JournalDirection),
    NotApplied(usize, JournalDirection),
    Terminal(JournalTerminal),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RecoveryMatrixEvent {
    Journal(AuthorizedMatrixCall),
    Rename(usize),
}

type RecoveryMatrixTimeline = Rc<RefCell<Vec<RecoveryMatrixEvent>>>;

struct AuthorizedMatrixJournal {
    inner: MemoryJournal,
    fault: Option<(usize, AppendCertainty)>,
    calls: Vec<AuthorizedMatrixCall>,
    timeline: RecoveryMatrixTimeline,
}

impl AuthorizedMatrixJournal {
    fn new(
        records: Vec<JournalRecord>,
        fault: Option<(usize, AppendCertainty)>,
        timeline: RecoveryMatrixTimeline,
    ) -> Self {
        Self {
            inner: MemoryJournal::from_records(records),
            fault,
            calls: Vec::new(),
            timeline,
        }
    }

    fn append(
        &mut self,
        call: AuthorizedMatrixCall,
        operation: impl FnOnce(
            &mut MemoryJournal,
            &mut JournalAuthorization,
        ) -> Result<(), JournalError>,
        authorization: &mut JournalAuthorization,
    ) -> Result<(), JournalError> {
        self.calls.push(call);
        self.timeline
            .borrow_mut()
            .push(RecoveryMatrixEvent::Journal(call));
        let ordinal = self.calls.len();
        if let Some((fault_ordinal, certainty)) = self.fault
            && fault_ordinal == ordinal
        {
            self.fault = None;
            if certainty == AppendCertainty::MayHaveAppended {
                operation(&mut self.inner, authorization)?;
            }
            return Err(JournalError {
                code: 1_120,
                certainty,
            });
        }
        operation(&mut self.inner, authorization)
    }
}

impl AuthorizedJournal for AuthorizedMatrixJournal {
    fn authorized_snapshot(&mut self) -> Result<JournalSnapshot, JournalError> {
        self.inner.authorized_snapshot()
    }

    fn authorized_prepared(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.append(
            AuthorizedMatrixCall::Prepared(step, direction),
            |inner, authorization| inner.authorized_prepared(authorization, step, direction),
            authorization,
        )
    }

    fn authorized_completed(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.append(
            AuthorizedMatrixCall::Completed(step, direction),
            |inner, authorization| inner.authorized_completed(authorization, step, direction),
            authorization,
        )
    }

    fn authorized_not_applied(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.append(
            AuthorizedMatrixCall::NotApplied(step, direction),
            |inner, authorization| inner.authorized_not_applied(authorization, step, direction),
            authorization,
        )
    }

    fn authorized_terminal(
        &mut self,
        authorization: &mut JournalAuthorization,
        terminal: JournalTerminal,
    ) -> Result<(), JournalError> {
        self.append(
            AuthorizedMatrixCall::Terminal(terminal),
            |inner, authorization| inner.authorized_terminal(authorization, terminal),
            authorization,
        )
    }
}

struct RecoveryMatrixBackend {
    inner: MemoryBackend,
    rename_attempts: usize,
    timeline: RecoveryMatrixTimeline,
}

impl RenameBackend for RecoveryMatrixBackend {
    fn validate_path_environment(&self, path: &LegacyText) -> Result<(), BackendError> {
        self.inner.validate_path_environment(path)
    }

    fn path_key(&self, path: &LegacyText) -> PathKey {
        self.inner.path_key(path)
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
        self.rename_attempts = self.rename_attempts.saturating_add(1);
        self.timeline
            .borrow_mut()
            .push(RecoveryMatrixEvent::Rename(self.rename_attempts));
        self.inner.rename_no_replace(operation)
    }
}

fn recovery_chain_intents() -> Vec<RenameIntent> {
    vec![
        intent(),
        RenameIntent::new(
            EntryId::new(1),
            "C:\\work\\b.txt",
            "C:\\work",
            "c.txt",
            EntryKind::File,
        ),
    ]
}

fn recovery_fixture(
    location: PreparedLocation,
) -> Result<(MemoryBackend, Vec<JournalRecord>, PlanId), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2)
        .with_file("C:\\work\\sentinel.txt", 99);
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        recovery_chain_intents(),
    ))?;
    let plan_id = plan.id();
    let revision = plan.revision();
    let confirmed = plan.confirm_presented(plan_id, revision)?;
    let records = match location {
        PreparedLocation::Source => {
            let mut journal = PreparedFixtureJournal {
                inner: MemoryJournal::new(),
            };
            let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;
            assert!(matches!(
                report.outcome(),
                ExecutionOutcome::RecoveryRequired { .. }
            ));
            journal.inner.records().to_vec()
        }
        PreparedLocation::Destination => {
            backend.fail_ambiguous_move_on(1, 995);
            let mut journal = MemoryJournal::new();
            let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;
            assert!(matches!(
                report.outcome(),
                ExecutionOutcome::RecoveryRequired { .. }
            ));
            journal.records().to_vec()
        }
    };
    assert_eq!(records.len(), 2);
    Ok((backend, records, plan_id))
}

struct RecoveryMatrixEvidence {
    calls: Vec<AuthorizedMatrixCall>,
    timeline: Vec<RecoveryMatrixEvent>,
}

fn run_recovery_matrix_case(
    location: PreparedLocation,
    fault: Option<(usize, AppendCertainty)>,
) -> Result<RecoveryMatrixEvidence, Box<dyn std::error::Error>> {
    let (inner, records, plan) = recovery_fixture(location)?;
    let timeline = Rc::new(RefCell::new(Vec::new()));
    let mut backend = RecoveryMatrixBackend {
        inner,
        rename_attempts: 0,
        timeline: Rc::clone(&timeline),
    };
    let mut journal = AuthorizedMatrixJournal::new(records, fault, Rc::clone(&timeline));

    let outcome = RenameRecovery::new(&mut backend, &mut journal).rollback();

    let state = [
        backend.inner.file_id("C:\\work\\a.txt"),
        backend.inner.file_id("C:\\work\\b.txt"),
        backend.inner.file_id("C:\\work\\c.txt"),
    ];
    assert_eq!(backend.inner.file_id("C:\\work\\sentinel.txt"), Some(99));
    assert_eq!(
        state.iter().filter(|file_id| **file_id == Some(1)).count(),
        1
    );
    assert_eq!(
        state.iter().filter(|file_id| **file_id == Some(2)).count(),
        1
    );
    let allowed_endpoints = ["C:\\work\\a.txt", "C:\\work\\b.txt", "C:\\work\\c.txt"];
    assert!(
        backend
            .inner
            .completed_moves()
            .iter()
            .all(|(source, destination)| {
                allowed_endpoints.contains(&source.as_str())
                    && allowed_endpoints.contains(&destination.as_str())
            })
    );
    match outcome {
        RecoveryOutcome::Recovered {
            plan: recovered_plan,
            ..
        } => {
            assert_eq!(recovered_plan, plan);
            assert_eq!(state, [Some(1), Some(2), None]);
        }
        RecoveryOutcome::RecoveryRequired {
            plan: required_plan,
            ..
        } => assert_eq!(required_plan, plan),
        RecoveryOutcome::NotRequired | RecoveryOutcome::Blocked { .. } => {
            return Err(std::io::Error::other(
                "prepared fixture did not reach the recovery transaction",
            )
            .into());
        }
    }
    if fault.is_some() {
        assert!(journal.fault.is_none(), "authorized fault was not reached");
    }
    Ok(RecoveryMatrixEvidence {
        calls: journal.calls,
        timeline: timeline.borrow().clone(),
    })
}

#[test]
fn exhaustive_recovery_append_fault_matrix_preserves_transaction_invariants()
-> Result<(), Box<dyn std::error::Error>> {
    let source = run_recovery_matrix_case(PreparedLocation::Source, None)?;
    let destination = run_recovery_matrix_case(PreparedLocation::Destination, None)?;
    let combined = source
        .calls
        .iter()
        .chain(&destination.calls)
        .copied()
        .collect::<Vec<_>>();
    assert!(
        combined
            .iter()
            .any(|call| matches!(call, AuthorizedMatrixCall::Prepared(..)))
    );
    assert!(
        combined
            .iter()
            .any(|call| matches!(call, AuthorizedMatrixCall::Completed(..)))
    );
    assert!(
        combined
            .iter()
            .any(|call| matches!(call, AuthorizedMatrixCall::NotApplied(..)))
    );
    assert!(
        combined
            .iter()
            .any(|call| matches!(call, AuthorizedMatrixCall::Terminal(..)))
    );

    for (location, baseline) in [
        (PreparedLocation::Source, source),
        (PreparedLocation::Destination, destination),
    ] {
        for ordinal in 1..=baseline.calls.len() {
            for certainty in [
                AppendCertainty::NotAppended,
                AppendCertainty::MayHaveAppended,
            ] {
                let evidence = run_recovery_matrix_case(location, Some((ordinal, certainty)))?;
                assert_eq!(evidence.calls[ordinal - 1], baseline.calls[ordinal - 1]);
                if certainty == AppendCertainty::MayHaveAppended {
                    assert_eq!(
                        evidence.timeline.last(),
                        Some(&RecoveryMatrixEvent::Journal(baseline.calls[ordinal - 1]))
                    );
                }
            }
        }
    }
    Ok(())
}
