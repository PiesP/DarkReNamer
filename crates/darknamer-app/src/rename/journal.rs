use std::collections::BTreeSet;
use std::sync::atomic::{AtomicU64, Ordering};

use darknamer_core::LegacyText;

use super::{
    AuthorizedJournal, EntryId, EntryIdentity, JournalAuthorization, JournalError, JournalSnapshot,
    JournalStore, PlanId, TemporaryPhase,
};

/// Immutable identity-bound primitive step persisted before mutation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JournalStep {
    entry: EntryId,
    source: LegacyText,
    destination: LegacyText,
    expected_source: EntryIdentity,
    expected_source_parent: EntryIdentity,
    expected_destination_parent: EntryIdentity,
    temporary_phase: TemporaryPhase,
}

impl JournalStep {
    /// Creates one immutable schedule-manifest entry.
    #[must_use]
    pub fn new(
        entry: EntryId,
        source: LegacyText,
        destination: LegacyText,
        expected_source: EntryIdentity,
        expected_source_parent: EntryIdentity,
        expected_destination_parent: EntryIdentity,
        temporary_phase: TemporaryPhase,
    ) -> Self {
        Self {
            entry,
            source,
            destination,
            expected_source,
            expected_source_parent,
            expected_destination_parent,
            temporary_phase,
        }
    }

    /// Returns the plan-scoped stable entry identifier.
    #[must_use]
    pub const fn entry(&self) -> EntryId {
        self.entry
    }

    /// Returns the exact source endpoint.
    #[must_use]
    pub const fn source(&self) -> &LegacyText {
        &self.source
    }

    /// Returns the exact destination endpoint.
    #[must_use]
    pub const fn destination(&self) -> &LegacyText {
        &self.destination
    }

    /// Returns the source identity required by the mutation.
    #[must_use]
    pub const fn expected_source(&self) -> EntryIdentity {
        self.expected_source
    }

    /// Returns the required source-parent identity.
    #[must_use]
    pub const fn expected_source_parent(&self) -> EntryIdentity {
        self.expected_source_parent
    }

    /// Returns the required destination-parent identity.
    #[must_use]
    pub const fn expected_destination_parent(&self) -> EntryIdentity {
        self.expected_destination_parent
    }

    /// Returns the temporary-endpoint phase.
    #[must_use]
    pub const fn temporary_phase(&self) -> TemporaryPhase {
        self.temporary_phase
    }
}

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
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum JournalRecord {
    /// Complete immutable schedule persisted before mutation.
    Intent {
        plan: PlanId,
        steps: Box<[JournalStep]>,
    },
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
    /// A prepared primitive definitely did not mutate the filesystem.
    NotApplied {
        step: usize,
        direction: JournalDirection,
    },
    /// The transaction reached a verified terminal state.
    Terminal(JournalTerminal),
}

/// Strict journal-format or transition violation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalCorruption {
    /// The first record was not exactly one intent manifest.
    MissingIntent,
    /// A transition referenced a nonexistent manifest step.
    StepOutOfBounds,
    /// A transition violated forward or reverse ordering.
    InvalidOrder,
    /// Records appeared after a terminal state.
    RecordsAfterTerminal,
    /// A terminal record contradicted observed transitions.
    InvalidTerminal,
}

/// Why an incomplete transaction requires reconciliation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryReason {
    /// A prepared operation has no durable completion or no-mutation record.
    PreparedOnly {
        step: usize,
        direction: JournalDirection,
    },
    /// The journal is valid but has no verified terminal record.
    Incomplete,
    /// The journal cannot be trusted as a valid transition sequence.
    Corrupt(JournalCorruption),
}

/// Pure replay classification for journal contents.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RecoveryState {
    /// No incomplete transaction exists.
    Clean,
    /// Reconciliation is required before another Apply.
    RecoveryRequired {
        /// Plan identity when a valid intent manifest was available.
        plan: Option<PlanId>,
        /// Number of completed forward primitive moves.
        completed_forward: usize,
        /// Number of completed rollback primitive moves.
        completed_rollback: usize,
        /// Exact replay reason.
        reason: RecoveryReason,
    },
}

/// Strictly replays journal records without filesystem access.
#[must_use]
pub fn replay_journal(records: &[JournalRecord]) -> RecoveryState {
    if records.is_empty() {
        return RecoveryState::Clean;
    }
    let JournalRecord::Intent { plan, steps } = &records[0] else {
        return recovery(
            None,
            0,
            0,
            RecoveryReason::Corrupt(JournalCorruption::MissingIntent),
        );
    };
    let plan = *plan;
    let step_count = steps.len();
    let mut forward_prepared = None;
    let mut rollback_prepared = None;
    let mut next_forward = 0_usize;
    let mut completed_forward = BTreeSet::new();
    let mut completed_rollback = BTreeSet::new();
    let mut rollback_started = false;
    let mut terminal = None;

    for record in &records[1..] {
        if terminal.is_some() {
            return corrupt(
                plan,
                &completed_forward,
                &completed_rollback,
                JournalCorruption::RecordsAfterTerminal,
            );
        }
        let transition = match record {
            JournalRecord::Intent { .. } => Err(JournalCorruption::InvalidOrder),
            JournalRecord::Prepared { step, direction } => validate_step(*step, step_count)
                .and_then(|()| match direction {
                    JournalDirection::Forward
                        if !rollback_started
                            && forward_prepared.is_none()
                            && *step == next_forward =>
                    {
                        forward_prepared = Some(*step);
                        Ok(())
                    }
                    JournalDirection::Rollback
                        if rollback_prepared.is_none() && forward_prepared.is_none() =>
                    {
                        rollback_started = true;
                        let expected = completed_forward
                            .iter()
                            .rev()
                            .find(|candidate| !completed_rollback.contains(candidate));
                        if expected == Some(step) {
                            rollback_prepared = Some(*step);
                            Ok(())
                        } else {
                            Err(JournalCorruption::InvalidOrder)
                        }
                    }
                    _ => Err(JournalCorruption::InvalidOrder),
                }),
            JournalRecord::Completed { step, direction } => validate_step(*step, step_count)
                .and_then(|()| match direction {
                    JournalDirection::Forward if forward_prepared == Some(*step) => {
                        forward_prepared = None;
                        completed_forward.insert(*step);
                        next_forward += 1;
                        Ok(())
                    }
                    JournalDirection::Rollback if rollback_prepared == Some(*step) => {
                        rollback_prepared = None;
                        completed_rollback.insert(*step);
                        Ok(())
                    }
                    _ => Err(JournalCorruption::InvalidOrder),
                }),
            JournalRecord::NotApplied { step, direction } => validate_step(*step, step_count)
                .and_then(|()| match direction {
                    JournalDirection::Forward if forward_prepared == Some(*step) => {
                        forward_prepared = None;
                        rollback_started = true;
                        next_forward += 1;
                        Ok(())
                    }
                    JournalDirection::Rollback if rollback_prepared == Some(*step) => {
                        rollback_prepared = None;
                        Ok(())
                    }
                    _ => Err(JournalCorruption::InvalidOrder),
                }),
            JournalRecord::Terminal(value) => {
                terminal = Some(*value);
                Ok(())
            }
        };
        if let Err(error) = transition {
            return corrupt(plan, &completed_forward, &completed_rollback, error);
        }
    }

    if let Some(terminal) = terminal {
        let valid = match terminal {
            JournalTerminal::Committed => {
                completed_forward.len() == step_count
                    && completed_rollback.is_empty()
                    && forward_prepared.is_none()
                    && rollback_prepared.is_none()
            }
            JournalTerminal::RolledBack => {
                completed_forward == completed_rollback
                    && forward_prepared.is_none()
                    && rollback_prepared.is_none()
            }
        };
        return if valid {
            RecoveryState::Clean
        } else {
            corrupt(
                plan,
                &completed_forward,
                &completed_rollback,
                JournalCorruption::InvalidTerminal,
            )
        };
    }
    if let Some(step) = forward_prepared {
        return recovery(
            Some(plan),
            completed_forward.len(),
            completed_rollback.len(),
            RecoveryReason::PreparedOnly {
                step,
                direction: JournalDirection::Forward,
            },
        );
    }
    if let Some(step) = rollback_prepared {
        return recovery(
            Some(plan),
            completed_forward.len(),
            completed_rollback.len(),
            RecoveryReason::PreparedOnly {
                step,
                direction: JournalDirection::Rollback,
            },
        );
    }
    recovery(
        Some(plan),
        completed_forward.len(),
        completed_rollback.len(),
        RecoveryReason::Incomplete,
    )
}

fn validate_step(step: usize, step_count: usize) -> Result<(), JournalCorruption> {
    if step < step_count {
        Ok(())
    } else {
        Err(JournalCorruption::StepOutOfBounds)
    }
}

fn corrupt(
    plan: PlanId,
    forward: &BTreeSet<usize>,
    rollback: &BTreeSet<usize>,
    corruption: JournalCorruption,
) -> RecoveryState {
    recovery(
        Some(plan),
        forward.len(),
        rollback.len(),
        RecoveryReason::Corrupt(corruption),
    )
}

const fn recovery(
    plan: Option<PlanId>,
    completed_forward: usize,
    completed_rollback: usize,
    reason: RecoveryReason,
) -> RecoveryState {
    RecoveryState::RecoveryRequired {
        plan,
        completed_forward,
        completed_rollback,
        reason,
    }
}

/// In-memory journal adapter with the same append-only state machine as production.
#[derive(Debug)]
pub struct MemoryJournal {
    records: Vec<JournalRecord>,
    identity: u64,
    generation: u64,
    invalidate_next_authorized_append: bool,
}

impl MemoryJournal {
    /// Creates an empty journal.
    #[must_use]
    pub fn new() -> Self {
        Self {
            records: Vec::new(),
            identity: next_journal_identity(),
            generation: 0,
            invalidate_next_authorized_append: false,
        }
    }

    /// Creates an appendable in-memory journal from previously loaded records.
    #[must_use]
    pub fn from_records(records: Vec<JournalRecord>) -> Self {
        Self {
            generation: records.len() as u64,
            records,
            identity: next_journal_identity(),
            invalidate_next_authorized_append: false,
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
        replay_journal(&self.records)
    }

    /// Simulates journal drift after authorization for fail-closed tests.
    pub const fn invalidate_on_next_authorized_append(&mut self) {
        self.invalidate_next_authorized_append = true;
    }

    fn push(&mut self, record: JournalRecord) {
        self.records.push(record);
        self.generation = self.generation.saturating_add(1);
    }

    fn authorized_push(
        &mut self,
        authorization: &mut JournalAuthorization,
        record: JournalRecord,
    ) -> Result<(), JournalError> {
        if self.invalidate_next_authorized_append {
            self.invalidate_next_authorized_append = false;
            self.generation = self.generation.saturating_add(1);
        }
        if authorization.identity != self.identity || authorization.generation != self.generation {
            return Err(JournalError { code: 2 });
        }
        self.push(record);
        authorization.generation = self.generation;
        Ok(())
    }
}

impl Default for MemoryJournal {
    fn default() -> Self {
        Self::new()
    }
}

impl JournalStore for MemoryJournal {
    fn begin(&mut self, plan: PlanId, steps: &[JournalStep]) -> Result<(), JournalError> {
        if !self.records.is_empty() {
            return Err(JournalError { code: 1 });
        }
        self.push(JournalRecord::Intent {
            plan,
            steps: steps.into(),
        });
        Ok(())
    }

    fn prepared(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.push(JournalRecord::Prepared { step, direction });
        Ok(())
    }

    fn completed(&mut self, step: usize, direction: JournalDirection) -> Result<(), JournalError> {
        self.push(JournalRecord::Completed { step, direction });
        Ok(())
    }

    fn not_applied(
        &mut self,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.push(JournalRecord::NotApplied { step, direction });
        Ok(())
    }

    fn terminal(&mut self, terminal: JournalTerminal) -> Result<(), JournalError> {
        self.push(JournalRecord::Terminal(terminal));
        Ok(())
    }
}

impl AuthorizedJournal for MemoryJournal {
    fn authorized_snapshot(&mut self) -> Result<JournalSnapshot, JournalError> {
        Ok(JournalSnapshot {
            records: self.records.clone().into_boxed_slice(),
            authorization: JournalAuthorization {
                identity: self.identity,
                generation: self.generation,
            },
        })
    }

    fn authorized_prepared(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.authorized_push(authorization, JournalRecord::Prepared { step, direction })
    }

    fn authorized_completed(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.authorized_push(authorization, JournalRecord::Completed { step, direction })
    }

    fn authorized_not_applied(
        &mut self,
        authorization: &mut JournalAuthorization,
        step: usize,
        direction: JournalDirection,
    ) -> Result<(), JournalError> {
        self.authorized_push(authorization, JournalRecord::NotApplied { step, direction })
    }

    fn authorized_terminal(
        &mut self,
        authorization: &mut JournalAuthorization,
        terminal: JournalTerminal,
    ) -> Result<(), JournalError> {
        self.authorized_push(authorization, JournalRecord::Terminal(terminal))
    }
}

fn next_journal_identity() -> u64 {
    static NEXT_IDENTITY: AtomicU64 = AtomicU64::new(1);
    NEXT_IDENTITY.fetch_add(1, Ordering::Relaxed)
}
