use std::fmt;

use super::journal::{JournalDirection, JournalTerminal};
use super::model::PlanRow;
use super::schedule::{ScheduleError, ScheduleStep, TemporaryPhase, build_schedule};
use super::{
    AppendCertainty, BackendError, ConfirmedPlan, EntryId, JournalError, JournalStep, JournalStore,
    MutationCertainty, PlanId, RenameBackend, RenameOperation,
};

/// A pre-mutation reason execution refused a confirmed plan.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecuteErrorKind {
    /// The planner produced an internally inconsistent dependency graph.
    InvalidSchedule,
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
    /// Filesystem primitive failed.
    Backend { step: usize, error: BackendError },
    /// Journal transition failed.
    Journal { step: usize, error: JournalError },
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
        let plan = confirmed.plan;
        let mut entries = plan
            .entries
            .iter()
            .map(|row| EntryExecution {
                entry: row.id,
                state: RenameState::Restored,
            })
            .collect::<Vec<_>>();
        let schedule = build_schedule(&plan, self.backend).map_err(schedule_error)?;
        self.freeze(&plan.entries, &schedule)?;
        if schedule.is_empty() {
            return Ok(ExecutionReport {
                plan: plan.id,
                outcome: ExecutionOutcome::Completed,
                entries: entries.into_boxed_slice(),
            });
        }
        let manifest = schedule.iter().map(journal_step).collect::<Vec<_>>();
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
                ));
            }
            if let Err(error) = self.backend.rename_no_replace(&forward_operation(step)) {
                if error.certainty == MutationCertainty::MayHaveApplied {
                    set_state(&mut entries, step.entry, RenameState::Indeterminate);
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
                ));
            }
            set_state(
                &mut entries,
                step.entry,
                forward_state(step.temporary_phase),
            );
            completed.push((step_index, step.clone()));
            if let Err(error) = self
                .journal
                .completed(step_index, JournalDirection::Forward)
            {
                set_state(&mut entries, step.entry, RenameState::Indeterminate);
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
        Ok(ExecutionReport {
            plan: plan.id,
            outcome: ExecutionOutcome::Completed,
            entries: entries.into_boxed_slice(),
        })
    }

    fn freeze(&self, entries: &[PlanRow], schedule: &[ScheduleStep]) -> Result<(), ExecuteError> {
        for entry in entries {
            let current_source =
                self.backend
                    .observe(&entry.source)
                    .map_err(|_error| ExecuteError {
                        entry: Some(entry.id),
                        kind: ExecuteErrorKind::StaleSource,
                    })?;
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

            let current_destination =
                self.backend
                    .observe(&entry.destination)
                    .map_err(|_error| ExecuteError {
                        entry: Some(entry.id),
                        kind: ExecuteErrorKind::DestinationChanged,
                    })?;
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
            let temporary =
                self.backend
                    .observe(&step.destination)
                    .map_err(|_error| ExecuteError {
                        entry: Some(step.entry),
                        kind: ExecuteErrorKind::TemporaryOccupied,
                    })?;
            let planned = entries.iter().find(|entry| entry.id == step.entry);
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
        Ok(())
    }

    fn rollback(
        &mut self,
        plan: PlanId,
        failure: ExecutionFailure,
        completed: &[(usize, ScheduleStep)],
        mut entries: Vec<EntryExecution>,
    ) -> ExecutionReport {
        let mut rollback_failures = Vec::new();
        for (step_index, step) in completed.iter().rev() {
            if let Err(error) = self
                .journal
                .prepared(*step_index, JournalDirection::Rollback)
            {
                rollback_failures.push(RollbackFailure::Journal {
                    step: *step_index,
                    error,
                });
                set_state(&mut entries, step.entry, RenameState::Indeterminate);
                break;
            }
            let operation = RenameOperation::new(
                step.destination.clone(),
                step.source.clone(),
                step.identity,
                step.destination_parent,
                step.source_parent,
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
                set_state(&mut entries, step.entry, RenameState::Indeterminate);
                break;
            }
            set_state(
                &mut entries,
                step.entry,
                rollback_state(step.temporary_phase),
            );
            if let Err(error) = self
                .journal
                .completed(*step_index, JournalDirection::Rollback)
            {
                rollback_failures.push(RollbackFailure::Journal {
                    step: *step_index,
                    error,
                });
                set_state(&mut entries, step.entry, RenameState::Indeterminate);
                break;
            }
        }

        let outcome = if rollback_failures.is_empty() {
            match self.journal.terminal(JournalTerminal::RolledBack) {
                Ok(()) => ExecutionOutcome::RolledBack { failure },
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
    RenameOperation::new(
        step.source.clone(),
        step.destination.clone(),
        step.identity,
        step.source_parent,
        step.destination_parent,
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

fn set_state(entries: &mut [EntryExecution], entry: EntryId, state: RenameState) {
    if let Some(result) = entries.iter_mut().find(|result| result.entry == entry) {
        result.state = state;
    }
}

fn schedule_error(error: ScheduleError) -> ExecuteError {
    match error {
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
