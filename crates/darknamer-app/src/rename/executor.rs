use std::collections::BTreeMap;
use std::fmt;
use std::sync::atomic::{AtomicU8, Ordering};

use super::journal::{JournalDirection, JournalTerminal};
use super::model::PlanRow;
use super::schedule::{ScheduleError, ScheduleStep, TemporaryPhase, build_schedule_cancellable};
use super::{
    AppendCertainty, BackendError, ConfirmedPlan, EntryId, JournalCapacityError, JournalError,
    JournalRequirements, JournalStep, JournalStore, MutationCertainty, PlanId, RenameBackend,
    RenameOperation, RenamePlan,
};

/// A pre-mutation reason execution refused a confirmed plan.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecuteErrorKind {
    /// Execution was cancelled before the durable transaction began.
    Cancelled,
    /// The planner produced an internally inconsistent dependency graph.
    InvalidSchedule,
    /// The immutable plan or schedule exceeds its authorized movement scope.
    UnauthorizedMove,
    /// A source entry no longer matches the planning snapshot.
    StaleSource,
    /// A resolved source or destination parent no longer matches planning.
    StaleParent,
    /// Destination occupancy or identity changed after planning.
    DestinationChanged,
    /// A generated temporary endpoint became occupied.
    TemporaryOccupied,
    /// Every bounded temporary-name candidate was occupied.
    TemporaryExhausted,
    /// A backend operation failed before mutation.
    Backend(BackendError),
    /// The durable journal could not begin before mutation.
    Journal(JournalError),
    /// The complete immutable manifest exceeds a journal codec capacity.
    JournalCapacity(JournalCapacityError),
}

/// Execution stopped before any filesystem mutation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ExecuteError {
    /// Entry associated with the refusal, when applicable.
    pub entry: Option<EntryId>,
    /// Structured refusal kind.
    pub kind: ExecuteErrorKind,
}

impl fmt::Display for ExecuteError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("confirmed rename plan is not executable")
    }
}

impl std::error::Error for ExecuteError {}

/// Failure that interrupted forward execution after journalling began.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionFailure {
    /// Cancellation was observed at a safe forward step boundary.
    Cancelled { step: usize },
    /// Filesystem primitive failed.
    Backend { step: usize, error: BackendError },
    /// Journal transition failed.
    Journal { step: usize, error: JournalError },
}

/// High-level phase reported by the executor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionPhase {
    /// Schedule construction and filesystem revalidation completed.
    Ready,
    /// Forward primitive steps are being applied.
    Forward,
    /// Completed forward primitive steps are being restored.
    Rollback,
    /// A verified terminal record was written.
    Terminal,
}

/// Coalescible execution progress at a durable step boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ExecutionProgress {
    /// Current execution phase.
    pub phase: ExecutionPhase,
    /// Completed durable steps within this phase.
    pub completed: usize,
    /// Total steps expected within this phase.
    pub total: usize,
}

/// Cooperative control observed only at safe transaction boundaries.
pub trait ExecutionControl: Send + Sync {
    /// Returns whether forward execution should stop and roll back.
    fn cancellation_requested(&self) -> bool;

    /// Atomically commits the boundary after which cancellation rolls back.
    fn begin_transaction(&self) -> bool;

    /// Receives progress after schedule preparation or a durable step boundary.
    fn progress(&self, progress: ExecutionProgress);
}

const CANCEL_REQUESTED: u8 = 0b01;
const JOURNAL_BEGIN_COMMITTED: u8 = 0b10;

/// One-shot cancellation token that linearizes cancellation against journal begin.
#[derive(Debug, Default)]
pub struct CancellationToken {
    state: AtomicU8,
}

impl CancellationToken {
    /// Creates a token before either cancellation or journal begin wins.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: AtomicU8::new(0),
        }
    }

    /// Requests cancellation. Repeated requests are idempotent.
    pub fn request(&self) {
        self.state.fetch_or(CANCEL_REQUESTED, Ordering::AcqRel);
    }

    /// Returns whether cancellation has been requested.
    #[must_use]
    pub fn is_requested(&self) -> bool {
        self.state.load(Ordering::Acquire) & CANCEL_REQUESTED != 0
    }

    fn commit_journal_begin(&self) -> bool {
        self.state
            .compare_exchange(
                0,
                JOURNAL_BEGIN_COMMITTED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }
}

impl ExecutionControl for CancellationToken {
    fn cancellation_requested(&self) -> bool {
        self.is_requested()
    }

    fn begin_transaction(&self) -> bool {
        self.commit_journal_begin()
    }

    fn progress(&self, _progress: ExecutionProgress) {}
}

struct NoopExecutionControl;

impl ExecutionControl for NoopExecutionControl {
    fn cancellation_requested(&self) -> bool {
        false
    }

    fn begin_transaction(&self) -> bool {
        true
    }

    fn progress(&self, _progress: ExecutionProgress) {}
}

/// One best-effort rollback operation that did not complete durably.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RollbackFailure {
    /// Reverse filesystem primitive failed.
    Backend { step: usize, error: BackendError },
    /// Reverse journal transition failed.
    Journal { step: usize, error: JournalError },
}

/// Observable terminal or recovery-required execution outcome.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ExecutionOutcome {
    /// Every logical destination was applied and journalled terminally.
    Completed,
    /// Forward execution failed and every completed move was restored.
    RolledBack { failure: ExecutionFailure },
    /// Filesystem/journal state requires explicit recovery before another Apply.
    RecoveryRequired {
        failure: ExecutionFailure,
        rollback_failures: Box<[RollbackFailure]>,
    },
}

/// Reconciled logical state of one plan entry.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RenameState {
    /// The entry is at its final planned destination.
    Applied,
    /// The entry is at its original source after no mutation or rollback.
    Restored,
    /// The entry requires filesystem reconciliation.
    Indeterminate,
}

/// Per-entry result keyed by the plan-scoped stable identifier.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EntryExecution {
    entry: EntryId,
    state: RenameState,
}

impl EntryExecution {
    /// Returns the plan-scoped stable entry identifier.
    #[must_use]
    pub const fn entry(&self) -> EntryId {
        self.entry
    }

    /// Returns the reconciled logical state.
    #[must_use]
    pub const fn state(&self) -> RenameState {
        self.state
    }
}

struct IndexedEntryExecutions {
    values: Vec<EntryExecution>,
    by_id: BTreeMap<EntryId, usize>,
    #[cfg(test)]
    lookups: usize,
}

impl IndexedEntryExecutions {
    fn from_plan(entries: &[PlanRow]) -> Result<Self, ExecuteError> {
        let mut values = Vec::with_capacity(entries.len());
        let mut by_id = BTreeMap::new();
        for entry in entries {
            let index = values.len();
            if by_id.insert(entry.id, index).is_some() {
                return Err(ExecuteError {
                    entry: Some(entry.id),
                    kind: ExecuteErrorKind::InvalidSchedule,
                });
            }
            values.push(EntryExecution {
                entry: entry.id,
                state: RenameState::Restored,
            });
        }
        Ok(Self {
            values,
            by_id,
            #[cfg(test)]
            lookups: 0,
        })
    }

    fn validate_schedule(&self, schedule: &[ScheduleStep]) -> Result<(), ExecuteError> {
        for step in schedule {
            if !self.by_id.contains_key(&step.entry) {
                return Err(ExecuteError {
                    entry: Some(step.entry),
                    kind: ExecuteErrorKind::InvalidSchedule,
                });
            }
        }
        Ok(())
    }

    fn plan_row<'a>(&mut self, entries: &'a [PlanRow], entry: EntryId) -> Option<&'a PlanRow> {
        #[cfg(test)]
        {
            self.lookups = self.lookups.saturating_add(1);
        }
        self.by_id.get(&entry).and_then(|index| entries.get(*index))
    }

    fn set_state(&mut self, entry: EntryId, state: RenameState) {
        #[cfg(test)]
        {
            self.lookups = self.lookups.saturating_add(1);
        }
        if let Some(index) = self.by_id.get(&entry)
            && let Some(result) = self.values.get_mut(*index)
        {
            debug_assert_eq!(result.entry, entry);
            result.state = state;
        }
    }

    fn into_boxed_slice(self) -> Box<[EntryExecution]> {
        self.values.into_boxed_slice()
    }
}

/// Complete result returned after journalling or mutation began.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionReport {
    plan: PlanId,
    outcome: ExecutionOutcome,
    entries: Box<[EntryExecution]>,
}

impl ExecutionReport {
    /// Returns the immutable plan identity that was executed.
    #[must_use]
    pub const fn plan(&self) -> PlanId {
        self.plan
    }

    /// Returns the verified execution outcome.
    #[must_use]
    pub const fn outcome(&self) -> &ExecutionOutcome {
        &self.outcome
    }

    /// Returns per-entry applied, restored, or indeterminate results.
    #[must_use]
    pub fn entries(&self) -> &[EntryExecution] {
        &self.entries
    }
}

/// Revalidates and executes one consumed confirmation token.
pub struct RenameExecutor<'a> {
    backend: &'a mut dyn RenameBackend,
    journal: &'a mut dyn JournalStore,
}

/// Computes the exact journal resources needed by the current schedule without mutation.
///
/// The executor repeats this assessment after confirmation because temporary
/// endpoint availability and filesystem observations may change.
///
/// # Errors
///
/// Returns a structured pre-mutation refusal when scheduling fails or the
/// resulting immutable manifest exceeds a journal codec capacity.
pub fn preflight_plan(
    plan: &RenamePlan,
    backend: &mut dyn RenameBackend,
) -> Result<JournalRequirements, ExecuteError> {
    preflight_plan_cancellable(plan, backend, || false)
}

/// Computes journal requirements while polling cancellation during scheduling.
///
/// # Errors
///
/// Returns [`ExecuteErrorKind::Cancelled`] before any journal or filesystem
/// mutation when cancellation is requested.
pub fn preflight_plan_cancellable(
    plan: &RenamePlan,
    backend: &mut dyn RenameBackend,
    cancellation_requested: impl Fn() -> bool,
) -> Result<JournalRequirements, ExecuteError> {
    let schedule = build_schedule_cancellable(plan, backend, &cancellation_requested)
        .map_err(schedule_error)?;
    let mut manifest = Vec::with_capacity(schedule.len());
    for step in &schedule {
        if cancellation_requested() {
            return Err(cancelled_before_begin());
        }
        manifest.push(journal_step(step));
    }
    if cancellation_requested() {
        return Err(cancelled_before_begin());
    }
    let requirements =
        super::file_journal::journal_requirements(&manifest).map_err(|error| ExecuteError {
            entry: None,
            kind: ExecuteErrorKind::JournalCapacity(error),
        })?;
    if cancellation_requested() {
        return Err(cancelled_before_begin());
    }
    Ok(requirements)
}

impl<'a> RenameExecutor<'a> {
    /// Creates an executor over filesystem and journal adapters.
    #[must_use]
    pub fn new(backend: &'a mut dyn RenameBackend, journal: &'a mut dyn JournalStore) -> Self {
        Self { backend, journal }
    }

    /// Revalidates and executes the exact plan consumed by confirmation.
    ///
    /// # Errors
    ///
    /// Returns only pre-mutation refusals. Once journalling or mutation begins,
    /// all partial state is represented by [`ExecutionReport`].
    pub fn execute(&mut self, confirmed: ConfirmedPlan) -> Result<ExecutionReport, ExecuteError> {
        self.execute_with_control(confirmed, &NoopExecutionControl)
    }

    /// Revalidates and executes with cooperative cancellation and progress.
    ///
    /// Cancellation is read before journalling and only between complete
    /// forward primitive transitions. It is deliberately ignored from a
    /// Prepared record through reconciliation and throughout rollback.
    ///
    /// # Errors
    ///
    /// Returns only pre-mutation refusals. Once journalling begins, cancellation
    /// and all partial state are represented by [`ExecutionReport`].
    pub fn execute_with_control(
        &mut self,
        confirmed: ConfirmedPlan,
        control: &dyn ExecutionControl,
    ) -> Result<ExecutionReport, ExecuteError> {
        let plan = confirmed.plan;
        if control.cancellation_requested() {
            return Err(cancelled_before_begin());
        }
        let mut entries = IndexedEntryExecutions::from_plan(&plan.entries)?;
        let schedule =
            build_schedule_cancellable(&plan, self.backend, &|| control.cancellation_requested())
                .map_err(schedule_error)?;
        entries.validate_schedule(&schedule)?;
        let mut manifest = Vec::with_capacity(schedule.len());
        for step in &schedule {
            if control.cancellation_requested() {
                return Err(cancelled_before_begin());
            }
            manifest.push(journal_step(step));
        }
        super::file_journal::journal_requirements(&manifest).map_err(|error| ExecuteError {
            entry: None,
            kind: ExecuteErrorKind::JournalCapacity(error),
        })?;
        self.freeze(&plan.entries, &schedule, &mut entries, control)?;
        if control.cancellation_requested() {
            return Err(cancelled_before_begin());
        }
        control.progress(ExecutionProgress {
            phase: ExecutionPhase::Ready,
            completed: 0,
            total: schedule.len(),
        });
        if schedule.is_empty() {
            return Ok(ExecutionReport {
                plan: plan.id,
                outcome: ExecutionOutcome::Completed,
                entries: entries.into_boxed_slice(),
            });
        }
        if !control.begin_transaction() {
            return Err(cancelled_before_begin());
        }
        if let Err(error) = self.journal.begin(plan.id, &manifest) {
            if error.certainty == AppendCertainty::MayHaveAppended {
                return Ok(ExecutionReport {
                    plan: plan.id,
                    outcome: ExecutionOutcome::RecoveryRequired {
                        failure: ExecutionFailure::Journal { step: 0, error },
                        rollback_failures: Box::new([]),
                    },
                    entries: entries.into_boxed_slice(),
                });
            }
            return Err(ExecuteError {
                entry: None,
                kind: ExecuteErrorKind::Journal(error),
            });
        }

        let mut completed = Vec::with_capacity(schedule.len());
        for (step_index, step) in schedule.iter().enumerate() {
            if control.cancellation_requested() {
                return Ok(self.rollback(
                    plan.id,
                    ExecutionFailure::Cancelled { step: step_index },
                    &completed,
                    entries,
                    control,
                ));
            }
            if let Err(error) = self.journal.prepared(step_index, JournalDirection::Forward) {
                if error.certainty == AppendCertainty::MayHaveAppended {
                    return Ok(ExecutionReport {
                        plan: plan.id,
                        outcome: ExecutionOutcome::RecoveryRequired {
                            failure: ExecutionFailure::Journal {
                                step: step_index,
                                error,
                            },
                            rollback_failures: Box::new([]),
                        },
                        entries: entries.into_boxed_slice(),
                    });
                }
                return Ok(self.rollback(
                    plan.id,
                    ExecutionFailure::Journal {
                        step: step_index,
                        error,
                    },
                    &completed,
                    entries,
                    control,
                ));
            }
            #[cfg(test)]
            super::failpoint::hit(&format!("forward-prepared-{step_index}"));
            if let Err(error) = self.backend.rename_no_replace(&forward_operation(step)) {
                if error.certainty == MutationCertainty::MayHaveApplied {
                    entries.set_state(step.entry, RenameState::Indeterminate);
                    return Ok(ExecutionReport {
                        plan: plan.id,
                        outcome: ExecutionOutcome::RecoveryRequired {
                            failure: ExecutionFailure::Backend {
                                step: step_index,
                                error,
                            },
                            rollback_failures: Box::new([]),
                        },
                        entries: entries.into_boxed_slice(),
                    });
                }
                if let Err(journal_error) = self
                    .journal
                    .not_applied(step_index, JournalDirection::Forward)
                {
                    return Ok(ExecutionReport {
                        plan: plan.id,
                        outcome: ExecutionOutcome::RecoveryRequired {
                            failure: ExecutionFailure::Backend {
                                step: step_index,
                                error,
                            },
                            rollback_failures: vec![RollbackFailure::Journal {
                                step: step_index,
                                error: journal_error,
                            }]
                            .into_boxed_slice(),
                        },
                        entries: entries.into_boxed_slice(),
                    });
                }
                return Ok(self.rollback(
                    plan.id,
                    ExecutionFailure::Backend {
                        step: step_index,
                        error,
                    },
                    &completed,
                    entries,
                    control,
                ));
            }
            #[cfg(test)]
            super::failpoint::hit(&format!("forward-rename-{step_index}"));
            entries.set_state(step.entry, forward_state(step.temporary_phase));
            completed.push((step_index, step.clone()));
            if let Err(error) = self
                .journal
                .completed(step_index, JournalDirection::Forward)
            {
                entries.set_state(step.entry, RenameState::Indeterminate);
                return Ok(ExecutionReport {
                    plan: plan.id,
                    outcome: ExecutionOutcome::RecoveryRequired {
                        failure: ExecutionFailure::Journal {
                            step: step_index,
                            error,
                        },
                        rollback_failures: Box::new([]),
                    },
                    entries: entries.into_boxed_slice(),
                });
            }
            #[cfg(test)]
            super::failpoint::hit(&format!("forward-completed-{step_index}"));
            control.progress(ExecutionProgress {
                phase: ExecutionPhase::Forward,
                completed: completed.len(),
                total: schedule.len(),
            });
        }

        if control.cancellation_requested() {
            return Ok(self.rollback(
                plan.id,
                ExecutionFailure::Cancelled {
                    step: schedule.len(),
                },
                &completed,
                entries,
                control,
            ));
        }
        if let Err(error) = self.journal.terminal(JournalTerminal::Committed) {
            return Ok(ExecutionReport {
                plan: plan.id,
                outcome: ExecutionOutcome::RecoveryRequired {
                    failure: ExecutionFailure::Journal {
                        step: schedule.len(),
                        error,
                    },
                    rollback_failures: Box::new([]),
                },
                entries: entries.into_boxed_slice(),
            });
        }
        #[cfg(test)]
        super::failpoint::hit("terminal-committed");
        control.progress(ExecutionProgress {
            phase: ExecutionPhase::Terminal,
            completed: schedule.len(),
            total: schedule.len(),
        });
        Ok(ExecutionReport {
            plan: plan.id,
            outcome: ExecutionOutcome::Completed,
            entries: entries.into_boxed_slice(),
        })
    }

    fn freeze(
        &self,
        entries: &[PlanRow],
        schedule: &[ScheduleStep],
        indexed_entries: &mut IndexedEntryExecutions,
        control: &dyn ExecutionControl,
    ) -> Result<(), ExecuteError> {
        for entry in entries {
            if control.cancellation_requested() {
                return Err(cancelled_before_begin());
            }
            let current_source =
                self.backend
                    .observe(&entry.source)
                    .map_err(|error| ExecuteError {
                        entry: Some(entry.id),
                        kind: ExecuteErrorKind::Backend(error),
                    })?;
            if control.cancellation_requested() {
                return Err(cancelled_before_begin());
            }
            if current_source.parent != entry.source_snapshot.parent {
                return Err(ExecuteError {
                    entry: Some(entry.id),
                    kind: ExecuteErrorKind::StaleParent,
                });
            }
            if current_source.entry != entry.source_snapshot.entry {
                return Err(ExecuteError {
                    entry: Some(entry.id),
                    kind: ExecuteErrorKind::StaleSource,
                });
            }
            if current_source.entry.map(|source| source.kind) != Some(entry.kind) {
                return Err(ExecuteError {
                    entry: Some(entry.id),
                    kind: ExecuteErrorKind::UnauthorizedMove,
                });
            }

            let current_destination =
                self.backend
                    .observe(&entry.destination)
                    .map_err(|error| ExecuteError {
                        entry: Some(entry.id),
                        kind: ExecuteErrorKind::Backend(error),
                    })?;
            if control.cancellation_requested() {
                return Err(cancelled_before_begin());
            }
            if current_destination.parent != entry.destination_snapshot.parent {
                return Err(ExecuteError {
                    entry: Some(entry.id),
                    kind: ExecuteErrorKind::StaleParent,
                });
            }
            if current_destination.entry != entry.destination_snapshot.entry {
                return Err(ExecuteError {
                    entry: Some(entry.id),
                    kind: ExecuteErrorKind::DestinationChanged,
                });
            }
        }

        for step in schedule
            .iter()
            .filter(|step| step.temporary_phase == TemporaryPhase::IntoTemporary)
        {
            if control.cancellation_requested() {
                return Err(cancelled_before_begin());
            }
            let temporary =
                self.backend
                    .observe(&step.destination)
                    .map_err(|error| ExecuteError {
                        entry: Some(step.entry),
                        kind: ExecuteErrorKind::Backend(error),
                    })?;
            if control.cancellation_requested() {
                return Err(cancelled_before_begin());
            }
            let planned = indexed_entries.plan_row(entries, step.entry);
            let Some(planned) = planned else {
                return Err(ExecuteError {
                    entry: Some(step.entry),
                    kind: ExecuteErrorKind::InvalidSchedule,
                });
            };
            if temporary.parent != planned.source_snapshot.parent {
                return Err(ExecuteError {
                    entry: Some(step.entry),
                    kind: ExecuteErrorKind::StaleParent,
                });
            }
            if temporary.entry.is_some() {
                return Err(ExecuteError {
                    entry: Some(step.entry),
                    kind: ExecuteErrorKind::TemporaryOccupied,
                });
            }
        }
        for step in schedule {
            if forward_operation(step).authorization_error().is_some() {
                return Err(ExecuteError {
                    entry: Some(step.entry),
                    kind: ExecuteErrorKind::UnauthorizedMove,
                });
            }
        }
        Ok(())
    }

    fn rollback(
        &mut self,
        plan: PlanId,
        failure: ExecutionFailure,
        completed: &[(usize, ScheduleStep)],
        mut entries: IndexedEntryExecutions,
        control: &dyn ExecutionControl,
    ) -> ExecutionReport {
        let mut rollback_failures = Vec::new();
        control.progress(ExecutionProgress {
            phase: ExecutionPhase::Rollback,
            completed: 0,
            total: completed.len(),
        });
        let mut restored = 0_usize;
        for (step_index, step) in completed.iter().rev() {
            if let Err(error) = self
                .journal
                .prepared(*step_index, JournalDirection::Rollback)
            {
                rollback_failures.push(RollbackFailure::Journal {
                    step: *step_index,
                    error,
                });
                entries.set_state(step.entry, RenameState::Indeterminate);
                break;
            }
            #[cfg(test)]
            super::failpoint::hit(&format!("rollback-prepared-{step_index}"));
            let operation = RenameOperation::with_authorization(
                step.destination.clone(),
                step.source.clone(),
                step.identity,
                step.destination_parent,
                step.source_parent,
                step.kind,
                step.scope,
            );
            if let Err(error) = self.backend.rename_no_replace(&operation) {
                if error.certainty == MutationCertainty::NotApplied
                    && let Err(journal_error) = self
                        .journal
                        .not_applied(*step_index, JournalDirection::Rollback)
                {
                    rollback_failures.push(RollbackFailure::Journal {
                        step: *step_index,
                        error: journal_error,
                    });
                }
                rollback_failures.push(RollbackFailure::Backend {
                    step: *step_index,
                    error,
                });
                entries.set_state(step.entry, RenameState::Indeterminate);
                break;
            }
            #[cfg(test)]
            super::failpoint::hit(&format!("rollback-rename-{step_index}"));
            entries.set_state(step.entry, rollback_state(step.temporary_phase));
            if let Err(error) = self
                .journal
                .completed(*step_index, JournalDirection::Rollback)
            {
                rollback_failures.push(RollbackFailure::Journal {
                    step: *step_index,
                    error,
                });
                entries.set_state(step.entry, RenameState::Indeterminate);
                break;
            }
            #[cfg(test)]
            super::failpoint::hit(&format!("rollback-completed-{step_index}"));
            restored = restored.saturating_add(1);
            control.progress(ExecutionProgress {
                phase: ExecutionPhase::Rollback,
                completed: restored,
                total: completed.len(),
            });
        }

        let outcome = if rollback_failures.is_empty() {
            match self.journal.terminal(JournalTerminal::RolledBack) {
                Ok(()) => {
                    #[cfg(test)]
                    super::failpoint::hit("terminal-rolled-back");
                    control.progress(ExecutionProgress {
                        phase: ExecutionPhase::Terminal,
                        completed: completed.len(),
                        total: completed.len(),
                    });
                    ExecutionOutcome::RolledBack { failure }
                }
                Err(error) => ExecutionOutcome::RecoveryRequired {
                    failure,
                    rollback_failures: vec![RollbackFailure::Journal {
                        step: completed.len(),
                        error,
                    }]
                    .into_boxed_slice(),
                },
            }
        } else {
            ExecutionOutcome::RecoveryRequired {
                failure,
                rollback_failures: rollback_failures.into_boxed_slice(),
            }
        };
        ExecutionReport {
            plan,
            outcome,
            entries: entries.into_boxed_slice(),
        }
    }
}

fn forward_operation(step: &ScheduleStep) -> RenameOperation {
    RenameOperation::with_authorization(
        step.source.clone(),
        step.destination.clone(),
        step.identity,
        step.source_parent,
        step.destination_parent,
        step.kind,
        step.scope,
    )
}

fn journal_step(step: &ScheduleStep) -> JournalStep {
    JournalStep::new(
        step.entry,
        step.source.clone(),
        step.destination.clone(),
        step.identity,
        step.source_parent,
        step.destination_parent,
        step.temporary_phase,
    )
    .with_move_authorization(step.kind, step.scope)
}

const fn forward_state(phase: TemporaryPhase) -> RenameState {
    match phase {
        TemporaryPhase::None | TemporaryPhase::FromTemporary => RenameState::Applied,
        TemporaryPhase::IntoTemporary => RenameState::Indeterminate,
    }
}

const fn rollback_state(phase: TemporaryPhase) -> RenameState {
    match phase {
        TemporaryPhase::None | TemporaryPhase::IntoTemporary => RenameState::Restored,
        TemporaryPhase::FromTemporary => RenameState::Indeterminate,
    }
}

const fn cancelled_before_begin() -> ExecuteError {
    ExecuteError {
        entry: None,
        kind: ExecuteErrorKind::Cancelled,
    }
}

fn schedule_error(error: ScheduleError) -> ExecuteError {
    match error {
        ScheduleError::Cancelled => cancelled_before_begin(),
        ScheduleError::Invalid => ExecuteError {
            entry: None,
            kind: ExecuteErrorKind::InvalidSchedule,
        },
        ScheduleError::Backend(error) => ExecuteError {
            entry: None,
            kind: ExecuteErrorKind::Backend(error),
        },
        ScheduleError::StaleParent(entry) => ExecuteError {
            entry: Some(entry),
            kind: ExecuteErrorKind::StaleParent,
        },
        ScheduleError::TemporaryExhausted(entry) => ExecuteError {
            entry: Some(entry),
            kind: ExecuteErrorKind::TemporaryExhausted,
        },
    }
}

#[cfg(test)]
mod tests {
    use darknamer_core::LegacyText;

    use super::super::model::ObservedEntry;
    use super::super::{EntryIdentity, EntryKind, PathSnapshot};
    use super::*;

    fn plan_row(id: EntryId) -> PlanRow {
        let parent = EntryIdentity::new(1, 1);
        let entry = ObservedEntry {
            identity: EntryIdentity::new(1, u128::from(id.row_index()) + 2),
            kind: EntryKind::File,
            is_reparse_point: false,
        };
        PlanRow {
            id,
            source: LegacyText::from("source"),
            destination: LegacyText::from("destination"),
            kind: EntryKind::File,
            source_snapshot: PathSnapshot {
                parent,
                entry: Some(entry),
            },
            destination_snapshot: PathSnapshot {
                parent,
                entry: None,
            },
        }
    }

    #[test]
    fn ten_thousand_execution_rows_use_one_index_lookup_per_state_update() {
        let rows = (0..10_000)
            .rev()
            .map(|value| plan_row(EntryId::new(value)))
            .collect::<Vec<_>>();
        let result = IndexedEntryExecutions::from_plan(&rows);
        assert!(result.is_ok());
        let Some(mut entries) = result.ok() else {
            return;
        };

        for value in 0..10_000 {
            entries.set_state(EntryId::new(value), RenameState::Applied);
        }

        assert_eq!(entries.lookups, 10_000);
        assert!(
            entries
                .values
                .iter()
                .all(|entry| entry.state == RenameState::Applied)
        );
        for row in &rows {
            assert_eq!(entries.plan_row(&rows, row.id), Some(row));
        }
        assert_eq!(entries.lookups, 20_000);
    }

    #[test]
    fn duplicate_execution_entry_ids_fail_before_schedule_or_journal_work() {
        let duplicate = EntryId::new(7);
        let rows = [plan_row(duplicate), plan_row(duplicate)];

        let error = IndexedEntryExecutions::from_plan(&rows).err();

        assert_eq!(
            error,
            Some(ExecuteError {
                entry: Some(duplicate),
                kind: ExecuteErrorKind::InvalidSchedule,
            })
        );
    }
}
