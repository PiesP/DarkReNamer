use std::sync::{Arc, Mutex};

use darknamer_app::rename::{
    AppendCertainty, BackendError, CancellationToken, EntryId, EntryKind, ExecuteErrorKind,
    ExecutionControl, ExecutionFailure, ExecutionOutcome, ExecutionPhase, ExecutionProgress,
    JournalCapacityKind, JournalCorruption, JournalDirection, JournalError, JournalRecord,
    JournalStep, JournalStore, JournalTerminal, MAX_JOURNAL_FRAME_BYTES, MAX_JOURNAL_STEPS,
    MAX_TEMP_CANDIDATES, MemoryBackend, MemoryJournal, ModelRevision, MutationCertainty, PathKey,
    PathSnapshot, PlanId, PlanRequest, RecoveryReason, RecoveryState, RenameBackend,
    RenameExecutor, RenameIntent, RenameOperation, RenamePlanner, RenameState, TemporaryPhase,
    preflight_plan, preflight_plan_cancellable, replay_journal,
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
    backend: &dyn RenameBackend,
    intents: Vec<RenameIntent>,
) -> Result<darknamer_app::rename::ConfirmedPlan, Box<dyn std::error::Error>> {
    let plan =
        RenamePlanner::new(backend).plan(PlanRequest::new(ModelRevision::new(1), intents))?;
    let id = plan.id();
    let revision = plan.revision();
    Ok(plan.confirm_presented(id, revision)?)
}

struct CancelDuringRenameBackend {
    inner: MemoryBackend,
    token: Arc<CancellationToken>,
}

struct CancelDuringObserveBackend {
    inner: MemoryBackend,
    token: Arc<CancellationToken>,
    observations: std::cell::Cell<usize>,
    cancel_on_observation: usize,
}

impl RenameBackend for CancelDuringObserveBackend {
    fn validate_path_environment(
        &self,
        path: &darknamer_core::LegacyText,
    ) -> Result<(), BackendError> {
        self.inner.validate_path_environment(path)
    }

    fn path_key(&self, path: &darknamer_core::LegacyText) -> PathKey {
        self.inner.path_key(path)
    }

    fn observe(&self, path: &darknamer_core::LegacyText) -> Result<PathSnapshot, BackendError> {
        let observations = self.observations.get().saturating_add(1);
        self.observations.set(observations);
        if observations == self.cancel_on_observation {
            self.token.request();
        }
        self.inner.observe(path)
    }

    fn is_same_or_descendant(
        &self,
        ancestor: &darknamer_core::LegacyText,
        candidate: &darknamer_core::LegacyText,
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

impl RenameBackend for CancelDuringRenameBackend {
    fn validate_path_environment(
        &self,
        path: &darknamer_core::LegacyText,
    ) -> Result<(), BackendError> {
        self.inner.validate_path_environment(path)
    }

    fn path_key(&self, path: &darknamer_core::LegacyText) -> PathKey {
        self.inner.path_key(path)
    }

    fn observe(&self, path: &darknamer_core::LegacyText) -> Result<PathSnapshot, BackendError> {
        self.inner.observe(path)
    }

    fn is_same_or_descendant(
        &self,
        ancestor: &darknamer_core::LegacyText,
        candidate: &darknamer_core::LegacyText,
    ) -> Result<bool, BackendError> {
        self.inner.is_same_or_descendant(ancestor, candidate)
    }

    fn next_transaction_nonce(&mut self) -> Result<u128, BackendError> {
        self.inner.next_transaction_nonce()
    }

    fn rename_no_replace(&mut self, operation: &RenameOperation) -> Result<(), BackendError> {
        self.token.request();
        self.inner.rename_no_replace(operation)
    }
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
    assert!(
        report
            .entries()
            .iter()
            .all(|entry| entry.state() == RenameState::Applied)
    );
    let JournalRecord::Intent { steps, .. } = &journal.records()[0] else {
        return Err(std::io::Error::other("journal intent manifest missing").into());
    };
    assert_eq!(steps.len(), 2);
    assert_eq!(steps[0].entry(), EntryId::new(1));
    assert_eq!(steps[0].source().to_string_lossy(), "C:\\work\\b.txt");
    assert_eq!(steps[0].destination().to_string_lossy(), "C:\\work\\c.txt");
    assert_eq!(steps[0].expected_source().file_id(), 2);
    assert_eq!(
        steps[0].expected_source_parent(),
        steps[0].expected_destination_parent()
    );
    assert_eq!(steps[0].temporary_phase(), TemporaryPhase::None);
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
    let JournalRecord::Intent { steps, .. } = &journal.records()[0] else {
        return Err(std::io::Error::other("case-only manifest missing").into());
    };
    assert_eq!(steps[0].temporary_phase(), TemporaryPhase::IntoTemporary);
    assert_eq!(steps[1].temporary_phase(), TemporaryPhase::FromTemporary);
    Ok(())
}

#[test]
fn preflight_reports_exact_primitive_steps_for_mixed_direct_cycle_and_case_only_plan()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2)
        .with_file("C:\\work\\c.txt", 3)
        .with_file("C:\\work\\D.TXT", 4);
    let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
        ModelRevision::new(1),
        vec![
            intent(0, "a.txt", "x.txt"),
            intent(1, "b.txt", "c.txt"),
            intent(2, "c.txt", "b.txt"),
            intent(3, "D.TXT", "d.txt"),
        ],
    ))?;

    let requirements = preflight_plan(&plan, &mut backend)?;

    assert_eq!(requirements.primitive_steps(), 6);
    assert!(requirements.intent_frame_bytes() < MAX_JOURNAL_FRAME_BYTES);
    Ok(())
}

#[test]
fn cancellation_stops_schedule_preflight_without_filesystem_mutation()
-> Result<(), Box<dyn std::error::Error>> {
    let count = 128_usize;
    let mut backend = MemoryBackend::new();
    let mut intents = Vec::with_capacity(count);
    for index in 0..count {
        let source = format!("source-{index:03}.txt");
        let destination = format!("target-{index:03}.txt");
        backend = backend.with_file(format!("C:\\work\\{source}"), index as u128 + 1);
        intents.push(intent(index as u32, &source, &destination));
    }
    let plan =
        RenamePlanner::new(&backend).plan(PlanRequest::new(ModelRevision::new(1), intents))?;
    let checks = std::cell::Cell::new(0_usize);

    let error = preflight_plan_cancellable(&plan, &mut backend, || {
        let next = checks.get().saturating_add(1);
        checks.set(next);
        next >= 24
    })
    .err()
    .ok_or_else(|| std::io::Error::other("cancelled preflight completed"))?;

    assert_eq!(error.kind, ExecuteErrorKind::Cancelled);
    assert_eq!(backend.mutation_count(), 0);
    Ok(())
}

#[test]
fn case_only_plan_above_step_capacity_is_refused_before_begin_and_mutation()
-> Result<(), Box<dyn std::error::Error>> {
    const LOGICAL_RENAMES: usize = MAX_JOURNAL_STEPS / 2 + 1;
    let mut backend = MemoryBackend::new();
    let mut intents = Vec::with_capacity(LOGICAL_RENAMES);
    for index in 0..LOGICAL_RENAMES {
        let source_name = format!("A{index:04}.TXT");
        let destination_name = format!("a{index:04}.txt");
        backend.insert_file(format!("C:\\work\\{source_name}"), index as u128 + 1);
        intents.push(intent(index as u32, &source_name, &destination_name));
    }
    let plan =
        RenamePlanner::new(&backend).plan(PlanRequest::new(ModelRevision::new(1), intents))?;

    let preflight_error = match preflight_plan(&plan, &mut backend) {
        Ok(_) => {
            return Err(std::io::Error::other("capacity preflight unexpectedly passed").into());
        }
        Err(error) => error,
    };
    assert!(matches!(
        preflight_error.kind,
        ExecuteErrorKind::JournalCapacity(error)
            if error.kind == JournalCapacityKind::PrimitiveSteps
                && error.required == LOGICAL_RENAMES * 2
                && error.maximum == MAX_JOURNAL_STEPS
    ));

    let id = plan.id();
    let revision = plan.revision();
    let confirmed = plan.confirm_presented(id, revision)?;
    let mut journal = MemoryJournal::new();
    let execution_error = match RenameExecutor::new(&mut backend, &mut journal).execute(confirmed) {
        Ok(_) => {
            return Err(
                std::io::Error::other("executor capacity check unexpectedly passed").into(),
            );
        }
        Err(error) => error,
    };

    assert_eq!(execution_error, preflight_error);
    assert!(journal.records().is_empty());
    assert_eq!(backend.mutation_count(), 0);
    Ok(())
}

#[test]
fn case_only_plan_at_exact_step_capacity_passes_preflight() -> Result<(), Box<dyn std::error::Error>>
{
    const LOGICAL_RENAMES: usize = MAX_JOURNAL_STEPS / 2;
    let mut backend = MemoryBackend::new();
    let mut intents = Vec::with_capacity(LOGICAL_RENAMES);
    for index in 0..LOGICAL_RENAMES {
        let source_name = format!("B{index:04}.TXT");
        let destination_name = format!("b{index:04}.txt");
        backend.insert_file(format!("C:\\work\\{source_name}"), index as u128 + 1);
        intents.push(intent(index as u32, &source_name, &destination_name));
    }
    let plan =
        RenamePlanner::new(&backend).plan(PlanRequest::new(ModelRevision::new(1), intents))?;

    let requirements = preflight_plan(&plan, &mut backend)?;

    assert_eq!(requirements.primitive_steps(), MAX_JOURNAL_STEPS);
    assert_eq!(backend.mutation_count(), 0);
    Ok(())
}

#[test]
fn preflight_refuses_long_utf16_intent_manifest_before_confirmation()
-> Result<(), Box<dyn std::error::Error>> {
    const LOGICAL_RENAMES: usize = 128;
    let parent = format!("C:\\\u{0061}{}", "p".repeat(32_750));
    let mut backend = MemoryBackend::new();
    let mut intents = Vec::with_capacity(LOGICAL_RENAMES);
    for index in 0..LOGICAL_RENAMES {
        let source_name = format!("s{index:03}");
        let destination_name = format!("d{index:03}");
        let source = format!("{parent}\\{source_name}");
        backend.insert_file(source.as_str(), index as u128 + 1);
        intents.push(RenameIntent::new(
            EntryId::new(index as u32),
            source,
            parent.clone(),
            destination_name,
            EntryKind::File,
        ));
    }
    let plan =
        RenamePlanner::new(&backend).plan(PlanRequest::new(ModelRevision::new(1), intents))?;

    let error = match preflight_plan(&plan, &mut backend) {
        Ok(_) => {
            return Err(std::io::Error::other("oversized manifest unexpectedly passed").into());
        }
        Err(error) => error,
    };

    assert!(matches!(
        error.kind,
        ExecuteErrorKind::JournalCapacity(capacity)
            if capacity.kind == JournalCapacityKind::IntentFrameBytes
                && capacity.required > MAX_JOURNAL_FRAME_BYTES
                && capacity.maximum == MAX_JOURNAL_FRAME_BYTES
    ));
    assert_eq!(backend.mutation_count(), 0);
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
    assert!(
        report
            .entries()
            .iter()
            .all(|entry| entry.state() == RenameState::Restored)
    );
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
    assert_eq!(report.entries()[0].state(), RenameState::Indeterminate);
    assert!(matches!(
        journal.recovery_state(),
        RecoveryState::RecoveryRequired { .. }
    ));
    Ok(())
}

struct RecordingControl {
    token: Arc<CancellationToken>,
    progress: Mutex<Vec<ExecutionProgress>>,
    cancel_after_forward: Option<usize>,
    cancel_after_begin: bool,
}

impl RecordingControl {
    fn new(cancel_after_forward: Option<usize>, cancel_after_begin: bool) -> Self {
        Self {
            token: Arc::new(CancellationToken::new()),
            progress: Mutex::new(Vec::new()),
            cancel_after_forward,
            cancel_after_begin,
        }
    }

    fn events(&self) -> Result<Vec<ExecutionProgress>, std::io::Error> {
        self.progress
            .lock()
            .map(|events| events.clone())
            .map_err(|_| std::io::Error::other("progress mutex poisoned"))
    }
}

impl ExecutionControl for RecordingControl {
    fn cancellation_requested(&self) -> bool {
        self.token.is_requested()
    }

    fn begin_transaction(&self) -> bool {
        let began = ExecutionControl::begin_transaction(self.token.as_ref());
        if began && self.cancel_after_begin {
            self.token.request();
        }
        began
    }

    fn progress(&self, progress: ExecutionProgress) {
        if progress.phase == ExecutionPhase::Forward
            && self
                .cancel_after_forward
                .is_some_and(|completed| progress.completed >= completed)
        {
            self.token.request();
        }
        if let Ok(mut events) = self.progress.lock() {
            events.push(progress);
        }
    }
}

#[test]
fn cancellation_before_begin_has_no_journal_or_filesystem_mutation()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let confirmed = confirmed_plan(&backend, vec![intent(0, "a.txt", "b.txt")])?;
    let mut journal = MemoryJournal::new();
    let control = RecordingControl::new(None, false);
    control.token.request();

    let error = RenameExecutor::new(&mut backend, &mut journal)
        .execute_with_control(confirmed, &control)
        .err()
        .ok_or_else(|| std::io::Error::other("cancelled execution began"))?;

    assert_eq!(error.kind, ExecuteErrorKind::Cancelled);
    assert_eq!(backend.mutation_count(), 0);
    assert!(journal.records().is_empty());
    Ok(())
}

#[test]
fn cancellation_during_freeze_stops_before_journal_begin_or_mutation()
-> Result<(), Box<dyn std::error::Error>> {
    let planned_backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2);
    let confirmed = confirmed_plan(
        &planned_backend,
        vec![
            intent(0, "a.txt", "a-new.txt"),
            intent(1, "b.txt", "b-new.txt"),
        ],
    )?;
    let token = Arc::new(CancellationToken::new());
    let mut backend = CancelDuringObserveBackend {
        inner: planned_backend,
        token: Arc::clone(&token),
        observations: std::cell::Cell::new(0),
        cancel_on_observation: 1,
    };
    let mut journal = MemoryJournal::new();

    let error = RenameExecutor::new(&mut backend, &mut journal)
        .execute_with_control(confirmed, token.as_ref())
        .err()
        .ok_or_else(|| std::io::Error::other("cancelled freeze began execution"))?;

    assert_eq!(error.kind, ExecuteErrorKind::Cancelled);
    assert_eq!(backend.inner.mutation_count(), 0);
    assert!(journal.records().is_empty());
    assert!(backend.observations.get() < 4);
    Ok(())
}

#[test]
fn cancellation_losing_begin_race_writes_intent_then_terminal_rollback()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let confirmed = confirmed_plan(&backend, vec![intent(0, "a.txt", "b.txt")])?;
    let mut journal = MemoryJournal::new();
    let control = RecordingControl::new(None, true);

    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute_with_control(confirmed, &control)?;

    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RolledBack {
            failure: ExecutionFailure::Cancelled { step: 0 }
        }
    ));
    assert_eq!(backend.mutation_count(), 0);
    assert!(matches!(
        journal.records(),
        [
            JournalRecord::Intent { .. },
            JournalRecord::Terminal(JournalTerminal::RolledBack)
        ]
    ));
    Ok(())
}

#[test]
fn cancellation_after_middle_step_rolls_back_every_completed_step_and_ignores_repeats()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2)
        .with_file("C:\\work\\c.txt", 3);
    let confirmed = confirmed_plan(
        &backend,
        vec![
            intent(0, "a.txt", "b.txt"),
            intent(1, "b.txt", "c.txt"),
            intent(2, "c.txt", "d.txt"),
        ],
    )?;
    let mut journal = MemoryJournal::new();
    let control = RecordingControl::new(Some(2), false);

    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute_with_control(confirmed, &control)?;
    control.token.request();

    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RolledBack {
            failure: ExecutionFailure::Cancelled { step: 2 }
        }
    ));
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    assert_eq!(backend.file_id("C:\\work\\b.txt"), Some(2));
    assert_eq!(backend.file_id("C:\\work\\c.txt"), Some(3));
    assert_eq!(backend.file_id("C:\\work\\d.txt"), None);
    assert_eq!(journal.recovery_state(), RecoveryState::Clean);
    let events = control.events()?;
    assert!(events.iter().any(|event| {
        event.phase == ExecutionPhase::Rollback && event.completed == 2 && event.total == 2
    }));
    assert_eq!(
        events
            .iter()
            .filter(|event| event.phase == ExecutionPhase::Terminal)
            .count(),
        1
    );
    Ok(())
}

#[test]
fn cancellation_after_last_forward_step_rolls_back_instead_of_committing()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let confirmed = confirmed_plan(&backend, vec![intent(0, "a.txt", "b.txt")])?;
    let mut journal = MemoryJournal::new();
    let control = RecordingControl::new(Some(1), false);

    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute_with_control(confirmed, &control)?;

    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RolledBack {
            failure: ExecutionFailure::Cancelled { step: 1 }
        }
    ));
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    assert_eq!(backend.file_id("C:\\work\\b.txt"), None);
    assert_eq!(
        journal.records().last(),
        Some(&JournalRecord::Terminal(JournalTerminal::RolledBack))
    );
    Ok(())
}

#[test]
fn cancellation_during_ambiguous_primitive_never_triggers_speculative_rollback()
-> Result<(), Box<dyn std::error::Error>> {
    let control = RecordingControl::new(None, false);
    let mut inner = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    inner.fail_ambiguous_move_on(1, 995);
    let mut backend = CancelDuringRenameBackend {
        inner,
        token: Arc::clone(&control.token),
    };
    let confirmed = confirmed_plan(&backend, vec![intent(0, "a.txt", "b.txt")])?;
    let mut journal = MemoryJournal::new();

    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute_with_control(confirmed, &control)?;

    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RecoveryRequired {
            failure: ExecutionFailure::Backend { .. },
            rollback_failures,
        } if rollback_failures.is_empty()
    ));
    assert_eq!(backend.inner.mutation_count(), 1);
    assert_eq!(backend.inner.file_id("C:\\work\\b.txt"), Some(1));
    assert!(!journal.records().iter().any(|record| matches!(
        record,
        JournalRecord::Prepared {
            direction: JournalDirection::Rollback,
            ..
        }
    )));
    Ok(())
}

struct FailingAppendJournal {
    inner: MemoryJournal,
    begin_failure: Option<AppendCertainty>,
    prepared_failure: Option<(usize, AppendCertainty)>,
}

impl FailingAppendJournal {
    fn new(
        begin_failure: Option<AppendCertainty>,
        prepared_failure: Option<(usize, AppendCertainty)>,
    ) -> Self {
        Self {
            inner: MemoryJournal::new(),
            begin_failure,
            prepared_failure,
        }
    }
}

impl JournalStore for FailingAppendJournal {
    fn begin(&mut self, plan: PlanId, steps: &[JournalStep]) -> Result<(), JournalError> {
        if let Some(certainty) = self.begin_failure.take() {
            return Err(JournalError {
                code: 112,
                certainty,
            });
        }
        self.inner.begin(plan, steps)
    }

    fn prepared(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        if self.prepared_failure == Some((step, AppendCertainty::MayHaveAppended)) {
            self.prepared_failure = None;
            return Err(JournalError::may_have_appended(112));
        }
        if self.prepared_failure == Some((step, AppendCertainty::NotAppended)) {
            self.prepared_failure = None;
            return Err(JournalError::not_appended(112));
        }
        self.inner.prepared(step, direction)
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

#[test]
fn maybe_appended_intent_is_retained_as_recovery_required() -> Result<(), Box<dyn std::error::Error>>
{
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let confirmed = confirmed_plan(&backend, vec![intent(0, "a.txt", "b.txt")])?;
    let mut journal = FailingAppendJournal::new(Some(AppendCertainty::MayHaveAppended), None);

    let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;

    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RecoveryRequired { .. }
    ));
    assert_eq!(backend.mutation_count(), 0);
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    Ok(())
}

#[test]
fn maybe_appended_prepared_stops_without_speculative_rollback()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2);
    let confirmed = confirmed_plan(
        &backend,
        vec![intent(0, "a.txt", "b.txt"), intent(1, "b.txt", "c.txt")],
    )?;
    let mut journal = FailingAppendJournal::new(None, Some((1, AppendCertainty::MayHaveAppended)));

    let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;

    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RecoveryRequired { .. }
    ));
    assert_eq!(backend.mutation_count(), 1);
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    assert_eq!(backend.file_id("C:\\work\\b.txt"), None);
    assert_eq!(backend.file_id("C:\\work\\c.txt"), Some(2));
    assert!(!journal.inner.records().iter().any(|record| matches!(
        record,
        JournalRecord::Prepared {
            direction: JournalDirection::Rollback,
            ..
        }
    )));
    Ok(())
}

#[test]
fn definitely_not_appended_prepared_allows_durable_rollback()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\b.txt", 2);
    let confirmed = confirmed_plan(
        &backend,
        vec![intent(0, "a.txt", "b.txt"), intent(1, "b.txt", "c.txt")],
    )?;
    let mut journal = FailingAppendJournal::new(None, Some((1, AppendCertainty::NotAppended)));

    let report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;

    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RolledBack { .. }
    ));
    assert_eq!(backend.file_id("C:\\work\\a.txt"), Some(1));
    assert_eq!(backend.file_id("C:\\work\\b.txt"), Some(2));
    assert_eq!(backend.file_id("C:\\work\\c.txt"), None);
    assert_eq!(journal.inner.recovery_state(), RecoveryState::Clean);
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

#[test]
fn strict_replay_requires_manifest_order_and_reconciles_prepared_or_corrupt_records()
-> Result<(), Box<dyn std::error::Error>> {
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let confirmed = confirmed_plan(&backend, vec![intent(0, "a.txt", "b.txt")])?;
    backend.fail_ambiguous_move_on(1, 995);
    let mut journal = MemoryJournal::new();
    let _report = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed)?;

    assert!(matches!(
        replay_journal(journal.records()),
        RecoveryState::RecoveryRequired {
            reason: RecoveryReason::PreparedOnly { step: 0, .. },
            ..
        }
    ));

    let mut corrupt = journal.records().to_vec();
    corrupt.push(JournalRecord::Completed {
        step: 99,
        direction: darknamer_app::rename::JournalDirection::Forward,
    });
    assert!(matches!(
        replay_journal(&corrupt),
        RecoveryState::RecoveryRequired {
            reason: RecoveryReason::Corrupt(JournalCorruption::StepOutOfBounds),
            ..
        }
    ));

    let intent_record = journal.records()[0].clone();
    let invalid_order = vec![
        intent_record.clone(),
        JournalRecord::Completed {
            step: 0,
            direction: darknamer_app::rename::JournalDirection::Forward,
        },
    ];
    assert!(matches!(
        replay_journal(&invalid_order),
        RecoveryState::RecoveryRequired {
            reason: RecoveryReason::Corrupt(JournalCorruption::InvalidOrder),
            ..
        }
    ));

    let invalid_terminal = vec![
        intent_record,
        JournalRecord::Terminal(JournalTerminal::Committed),
    ];
    assert!(matches!(
        replay_journal(&invalid_terminal),
        RecoveryState::RecoveryRequired {
            reason: RecoveryReason::Corrupt(JournalCorruption::InvalidTerminal),
            ..
        }
    ));
    Ok(())
}

fn temp_path(fingerprint: u64, nonce: u128, entry: u32, ordinal: usize) -> String {
    format!("C:\\work\\.__darknamer_{fingerprint:016x}_{nonce:032x}_{entry:08x}_{ordinal:02x}.tmp")
}
