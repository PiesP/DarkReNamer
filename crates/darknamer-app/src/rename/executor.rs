use std::fmt;

use super::journal::{JournalDirection, JournalTerminal};
use super::model::PlanRow;
use super::schedule::{ScheduleStep, build_schedule};
use super::{
    BackendError, ConfirmedPlan, EntryId, JournalError, JournalStore, PlanId, RenameBackend,
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

/// Complete result returned after journalling or mutation began.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionReport {
    plan: PlanId,
    outcome: ExecutionOutcome,
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
        let Some(schedule) = build_schedule(&plan, self.backend) else {
            return Err(ExecuteError {
                entry: None,
                kind: ExecuteErrorKind::InvalidSchedule,
            });
        };
        self.freeze(&plan.entries, &schedule)?;
        if schedule.is_empty() {
            return Ok(ExecutionReport {
                plan: plan.id,
                outcome: ExecutionOutcome::Completed,
            });
        }
        self.journal
            .begin(plan.id, schedule.len())
            .map_err(|error| ExecuteError {
                entry: None,
                kind: ExecuteErrorKind::Journal(error),
            })?;

        let mut completed = Vec::with_capacity(schedule.len());
        for (step_index, step) in schedule.iter().enumerate() {
            if let Err(error) = self.journal.prepared(step_index, JournalDirection::Forward) {
                return Ok(self.rollback(
                    plan.id,
                    ExecutionFailure::Journal {
                        step: step_index,
                        error,
                    },
                    &completed,
                ));
            }
            if let Err(error) =
                self.backend
                    .rename_no_replace(&step.source, &step.destination, step.identity)
            {
                return Ok(self.rollback(
                    plan.id,
                    ExecutionFailure::Backend {
                        step: step_index,
                        error,
                    },
                    &completed,
                ));
            }
            completed.push((step_index, step.clone()));
            if let Err(error) = self
                .journal
                .completed(step_index, JournalDirection::Forward)
            {
                return Ok(self.rollback(
                    plan.id,
                    ExecutionFailure::Journal {
                        step: step_index,
                        error,
                    },
                    &completed,
                ));
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
            });
        }
        Ok(ExecutionReport {
            plan: plan.id,
            outcome: ExecutionOutcome::Completed,
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

        for step in schedule.iter().filter(|step| step.temporary_destination) {
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
                continue;
            }
            if let Err(error) =
                self.backend
                    .rename_no_replace(&step.destination, &step.source, step.identity)
            {
                rollback_failures.push(RollbackFailure::Backend {
                    step: *step_index,
                    error,
                });
                continue;
            }
            if let Err(error) = self
                .journal
                .completed(*step_index, JournalDirection::Rollback)
            {
                rollback_failures.push(RollbackFailure::Journal {
                    step: *step_index,
                    error,
                });
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
        ExecutionReport { plan, outcome }
    }
}
