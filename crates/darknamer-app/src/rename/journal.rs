use super::{JournalError, JournalStore, PlanId};

/// Direction of a journalled primitive move.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalDirection {
    /// Apply the immutable plan.
    Forward,
    /// Reverse an already-completed forward move.
    Rollback,
}

/// Verified terminal transaction state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalTerminal {
    /// Every planned destination was verified.
    Committed,
    /// Every completed forward move was restored.
    RolledBack,
}

/// One durable state-machine record.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalRecord {
    /// Immutable transaction intent persisted before mutation.
    Intent { plan: PlanId, step_count: usize },
    /// One primitive move is about to run.
    Prepared {
        step: usize,
        direction: JournalDirection,
    },
    /// One primitive move completed.
    Completed {
        step: usize,
        direction: JournalDirection,
    },
    /// The transaction reached a verified terminal state.
    Terminal(JournalTerminal),
}

/// Replay classification for the current journal contents.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryState {
    /// No incomplete transaction exists.
    Clean,
    /// A transaction exists without a verified terminal record.
    RecoveryRequired {
        /// Interrupted plan identity.
        plan: PlanId,
        /// Number of completed forward primitive moves.
        completed_forward: usize,
        /// Number of completed rollback primitive moves.
        completed_rollback: usize,
    },
}

/// In-memory journal adapter with the same append-only state machine as production.
#[derive(Clone, Debug, Default)]
pub struct MemoryJournal {
    records: Vec<JournalRecord>,
}

impl MemoryJournal {
    /// Creates an empty journal.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            records: Vec::new(),
        }
    }

    /// Returns append-only records for behavior-level tests.
    #[must_use]
    pub fn records(&self) -> &[JournalRecord] {
        &self.records
    }

    /// Replays the journal into its startup recovery classification.
    #[must_use]
    pub fn recovery_state(&self) -> RecoveryState {
        let Some(JournalRecord::Intent { plan, .. }) = self.records.first().copied() else {
            return RecoveryState::Clean;
        };
        if self
            .records
            .iter()
            .any(|record| matches!(record, JournalRecord::Terminal(_)))
        {
            return RecoveryState::Clean;
        }
        let completed_forward = self
            .records
            .iter()
            .filter(|record| {
                matches!(
                    record,
                    JournalRecord::Completed {
                        direction: JournalDirection::Forward,
                        ..
                    }
                )
            })
            .count();
        let completed_rollback = self
            .records
            .iter()
            .filter(|record| {
                matches!(
                    record,
                    JournalRecord::Completed {
                        direction: JournalDirection::Rollback,
                        ..
                    }
                )
            })
            .count();
        RecoveryState::RecoveryRequired {
            plan,
            completed_forward,
            completed_rollback,
        }
    }
}

impl JournalStore for MemoryJournal {
    fn begin(&mut self, plan: PlanId, step_count: usize) -> Result<(), JournalError> {
        if self.recovery_state() != RecoveryState::Clean || !self.records.is_empty() {
            return Err(JournalError { code: 1 });
        }
        self.records
            .push(JournalRecord::Intent { plan, step_count });
        Ok(())
    }

    fn prepared(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.records
            .push(JournalRecord::Prepared { step, direction });
        Ok(())
    }

    fn completed(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.records
            .push(JournalRecord::Completed { step, direction });
        Ok(())
    }

    fn terminal(&mut self, terminal: JournalTerminal) -> Result<(), JournalError> {
        self.records.push(JournalRecord::Terminal(terminal));
        Ok(())
    }
}
