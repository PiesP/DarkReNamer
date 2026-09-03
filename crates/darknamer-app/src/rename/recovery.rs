//! Strict journal reconciliation and safe rollback.

use std::collections::{BTreeMap, BTreeSet};

use super::{
    AuthorizedJournal, BackendError, EntryIdentity, JournalDirection, JournalError, JournalRecord,
    JournalStep, MutationCertainty, PathKey, PlanId, RecoveryReason, RecoveryState, RenameBackend,
    RenameOperation, replay_journal,
};

/// A condition that prevents recovery from making any speculative mutation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryBlockKind {
    /// The journal record stream is corrupt or has no usable manifest.
    JournalCorrupt,
    /// A manifest step exceeds its persisted movement authorization.
    UnauthorizedOperation,
    /// Observed endpoint identities match neither safe transition state.
    StateMismatch,
    /// A resolved direct-parent identity changed.
    ParentChanged,
    /// Backend observation failed.
    Backend(BackendError),
    /// The retained journal capability could not load an authorized snapshot.
    Journal(JournalError),
}

/// A failure after a recovery transaction began appending records.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryFailure {
    /// Identity-bound rollback primitive failed.
    Backend(BackendError),
    /// Durable recovery transition could not be appended.
    Journal(JournalError),
}

/// Observable recovery outcome.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryOutcome {
    /// No incomplete transaction exists.
    NotRequired,
    /// Every applied primitive was restored to its original state.
    Recovered { plan: PlanId, restored_steps: usize },
    /// Reconciliation found unsafe or ambiguous state and made no mutation.
    Blocked {
        plan: Option<PlanId>,
        reason: RecoveryBlockKind,
    },
    /// Recovery began but could not reach a verified terminal state.
    RecoveryRequired {
        plan: PlanId,
        reason: RecoveryFailure,
    },
}

/// Reconciles one strict journal and rolls all applied steps back safely.
pub struct RenameRecovery<'a> {
    backend: &'a mut dyn RenameBackend,
    journal: &'a mut dyn AuthorizedJournal,
}

impl<'a> RenameRecovery<'a> {
    /// Creates a recovery module over the same backend and durable journal.
    #[must_use]
    pub fn new(backend: &'a mut dyn RenameBackend, journal: &'a mut dyn AuthorizedJournal) -> Self {
        Self { backend, journal }
    }

    /// Loads and reconciles the retained journal before performing reverse moves.
    ///
    /// Records cannot be supplied separately: snapshot and append authority are
    /// obtained from the same exclusively retained journal capability.
    #[must_use]
    pub fn rollback(&mut self) -> RecoveryOutcome {
        let snapshot = match self.journal.authorized_snapshot() {
            Ok(snapshot) => snapshot,
            Err(error) => {
                return RecoveryOutcome::Blocked {
                    plan: None,
                    reason: RecoveryBlockKind::Journal(error),
                };
            }
        };
        let (records, mut authorization) = snapshot.into_parts();
        let replay = replay_journal(&records);
        if replay == RecoveryState::Clean {
            return RecoveryOutcome::NotRequired;
        }
        if matches!(
            replay,
            RecoveryState::RecoveryRequired {
                reason: RecoveryReason::Corrupt(_),
                ..
            }
        ) {
            return RecoveryOutcome::Blocked {
                plan: replay_plan(&replay),
                reason: RecoveryBlockKind::JournalCorrupt,
            };
        }
        let Some(JournalRecord::Intent { plan, steps }) = records.first() else {
            return RecoveryOutcome::Blocked {
                plan: None,
                reason: RecoveryBlockKind::JournalCorrupt,
            };
        };
        let plan = *plan;
        if steps
            .iter()
            .any(|step| forward_operation(step).authorization_error().is_some())
        {
            return RecoveryOutcome::Blocked {
                plan: Some(plan),
                reason: RecoveryBlockKind::UnauthorizedOperation,
            };
        }
        let mut transitions = match transition_state(&records, steps, self.backend) {
            Ok(state) => state,
            Err(reason) => {
                return RecoveryOutcome::Blocked {
                    plan: Some(plan),
                    reason,
                };
            }
        };

        if let Some(prepared) = transitions.prepared {
            let result = if prepared.applied {
                self.journal.authorized_completed(
                    &mut authorization,
                    prepared.step,
                    prepared.direction,
                )
            } else {
                self.journal.authorized_not_applied(
                    &mut authorization,
                    prepared.step,
                    prepared.direction,
                )
            };
            if let Err(error) = result {
                return RecoveryOutcome::RecoveryRequired {
                    plan,
                    reason: RecoveryFailure::Journal(error),
                };
            }
            match prepared.direction {
                JournalDirection::Forward if prepared.applied => {
                    transitions.forward.insert(prepared.step);
                }
                JournalDirection::Rollback if prepared.applied => {
                    transitions.rollback.insert(prepared.step);
                }
                _ => {}
            }
        }

        let mut remaining = transitions
            .forward
            .difference(&transitions.rollback)
            .copied()
            .collect::<Vec<_>>();
        remaining.reverse();
        for step_index in &remaining {
            let Some(step) = steps.get(*step_index) else {
                return RecoveryOutcome::Blocked {
                    plan: Some(plan),
                    reason: RecoveryBlockKind::JournalCorrupt,
                };
            };
            if let Err(error) = self.journal.authorized_prepared(
                &mut authorization,
                *step_index,
                JournalDirection::Rollback,
            ) {
                return RecoveryOutcome::RecoveryRequired {
                    plan,
                    reason: RecoveryFailure::Journal(error),
                };
            }
            let operation = reverse_operation(step);
            if let Err(error) = self.backend.rename_no_replace(&operation) {
                if error.certainty == MutationCertainty::NotApplied
                    && let Err(journal_error) = self.journal.authorized_not_applied(
                        &mut authorization,
                        *step_index,
                        JournalDirection::Rollback,
                    )
                {
                    return RecoveryOutcome::RecoveryRequired {
                        plan,
                        reason: RecoveryFailure::Journal(journal_error),
                    };
                }
                return RecoveryOutcome::RecoveryRequired {
                    plan,
                    reason: RecoveryFailure::Backend(error),
                };
            }
            if let Err(error) = self.journal.authorized_completed(
                &mut authorization,
                *step_index,
                JournalDirection::Rollback,
            ) {
                return RecoveryOutcome::RecoveryRequired {
                    plan,
                    reason: RecoveryFailure::Journal(error),
                };
            }
        }
        if let Err(error) = self
            .journal
            .authorized_terminal(&mut authorization, super::JournalTerminal::RolledBack)
        {
            return RecoveryOutcome::RecoveryRequired {
                plan,
                reason: RecoveryFailure::Journal(error),
            };
        }
        RecoveryOutcome::Recovered {
            plan,
            restored_steps: remaining.len(),
        }
    }
}

#[derive(Clone, Copy)]
struct PreparedState {
    step: usize,
    direction: JournalDirection,
    applied: bool,
}

struct TransitionState {
    forward: BTreeSet<usize>,
    rollback: BTreeSet<usize>,
    prepared: Option<PreparedState>,
}

fn transition_state(
    records: &[JournalRecord],
    steps: &[JournalStep],
    backend: &dyn RenameBackend,
) -> Result<TransitionState, RecoveryBlockKind> {
    let mut forward = BTreeSet::new();
    let mut rollback = BTreeSet::new();
    let mut prepared = None;
    for record in records.iter().skip(1) {
        match record {
            JournalRecord::Prepared { step, direction } => {
                prepared = Some((*step, *direction));
            }
            JournalRecord::Completed { step, direction } => {
                match direction {
                    JournalDirection::Forward => {
                        forward.insert(*step);
                    }
                    JournalDirection::Rollback => {
                        rollback.insert(*step);
                    }
                }
                prepared = None;
            }
            JournalRecord::NotApplied { .. } => prepared = None,
            JournalRecord::Intent { .. } | JournalRecord::Terminal(_) => {}
        }
    }

    let mut expected = initial_occupancy(steps, backend);
    for record in records.iter().skip(1) {
        if let JournalRecord::Completed { step, direction } = record {
            apply_step(
                &mut expected,
                &steps[*step],
                backend,
                *direction == JournalDirection::Rollback,
            )?;
        }
    }
    let observed = observe_all(steps, backend)?;
    let prepared = if let Some((step_index, direction)) = prepared {
        let step = &steps[step_index];
        let mut applied_candidate = expected.clone();
        apply_step(
            &mut applied_candidate,
            step,
            backend,
            direction == JournalDirection::Rollback,
        )?;
        let base_matches = occupancy_matches(&expected, &observed);
        let applied_matches = occupancy_matches(&applied_candidate, &observed);
        match (base_matches, applied_matches) {
            (true, false) => Some(PreparedState {
                step: step_index,
                direction,
                applied: false,
            }),
            (false, true) => Some(PreparedState {
                step: step_index,
                direction,
                applied: true,
            }),
            _ => return Err(RecoveryBlockKind::StateMismatch),
        }
    } else {
        if !occupancy_matches(&expected, &observed) {
            return Err(RecoveryBlockKind::StateMismatch);
        }
        None
    };
    Ok(TransitionState {
        forward,
        rollback,
        prepared,
    })
}

fn initial_occupancy(
    steps: &[JournalStep],
    backend: &dyn RenameBackend,
) -> BTreeMap<PathKey, Option<EntryIdentity>> {
    let mut occupancy = BTreeMap::new();
    let mut seen_entries = BTreeSet::new();
    for step in steps {
        occupancy
            .entry(backend.path_key(step.source()))
            .or_insert(None);
        occupancy
            .entry(backend.path_key(step.destination()))
            .or_insert(None);
        if seen_entries.insert(step.entry()) {
            occupancy.insert(
                backend.path_key(step.source()),
                Some(step.expected_source()),
            );
        }
    }
    occupancy
}

fn apply_step(
    occupancy: &mut BTreeMap<PathKey, Option<EntryIdentity>>,
    step: &JournalStep,
    backend: &dyn RenameBackend,
    reverse: bool,
) -> Result<(), RecoveryBlockKind> {
    let (source, destination) = if reverse {
        (step.destination(), step.source())
    } else {
        (step.source(), step.destination())
    };
    let source_key = backend.path_key(source);
    let destination_key = backend.path_key(destination);
    if occupancy.get(&source_key) != Some(&Some(step.expected_source()))
        || occupancy.get(&destination_key) != Some(&None)
    {
        return Err(RecoveryBlockKind::JournalCorrupt);
    }
    occupancy.insert(source_key, None);
    occupancy.insert(destination_key, Some(step.expected_source()));
    Ok(())
}

fn observe_all(
    steps: &[JournalStep],
    backend: &dyn RenameBackend,
) -> Result<BTreeMap<PathKey, Option<EntryIdentity>>, RecoveryBlockKind> {
    let mut observed = BTreeMap::new();
    for step in steps {
        observe_endpoint(
            backend,
            step.source(),
            step.expected_source_parent(),
            step.expected_source(),
            step.kind(),
            &mut observed,
        )?;
        observe_endpoint(
            backend,
            step.destination(),
            step.expected_destination_parent(),
            step.expected_source(),
            step.kind(),
            &mut observed,
        )?;
    }
    Ok(observed)
}

fn observe_endpoint(
    backend: &dyn RenameBackend,
    path: &darknamer_core::LegacyText,
    expected_parent: EntryIdentity,
    expected_source: EntryIdentity,
    expected_kind: Option<super::EntryKind>,
    observed: &mut BTreeMap<PathKey, Option<EntryIdentity>>,
) -> Result<(), RecoveryBlockKind> {
    let snapshot = backend.observe(path).map_err(RecoveryBlockKind::Backend)?;
    if snapshot.parent != expected_parent {
        return Err(RecoveryBlockKind::ParentChanged);
    }
    if snapshot.entry.is_some_and(|entry| entry.is_reparse_point) {
        return Err(RecoveryBlockKind::StateMismatch);
    }
    if snapshot.entry.is_some_and(|entry| {
        entry.identity == expected_source && expected_kind.is_some_and(|kind| entry.kind != kind)
    }) {
        return Err(RecoveryBlockKind::StateMismatch);
    }
    observed.insert(
        backend.path_key(path),
        snapshot.entry.map(|entry| entry.identity),
    );
    Ok(())
}

fn occupancy_matches(
    expected: &BTreeMap<PathKey, Option<EntryIdentity>>,
    observed: &BTreeMap<PathKey, Option<EntryIdentity>>,
) -> bool {
    expected == observed
}

fn reverse_operation(step: &JournalStep) -> RenameOperation {
    operation(step, true)
}

fn forward_operation(step: &JournalStep) -> RenameOperation {
    operation(step, false)
}

fn operation(step: &JournalStep, reverse: bool) -> RenameOperation {
    let (source, destination, source_parent, destination_parent) = if reverse {
        (
            step.destination().clone(),
            step.source().clone(),
            step.expected_destination_parent(),
            step.expected_source_parent(),
        )
    } else {
        (
            step.source().clone(),
            step.destination().clone(),
            step.expected_source_parent(),
            step.expected_destination_parent(),
        )
    };
    if let Some(kind) = step.kind() {
        RenameOperation::with_authorization(
            source,
            destination,
            step.expected_source(),
            source_parent,
            destination_parent,
            kind,
            step.scope(),
        )
    } else {
        RenameOperation::with_legacy_same_parent_authorization(
            source,
            destination,
            step.expected_source(),
            source_parent,
            destination_parent,
        )
    }
}

const fn replay_plan(state: &RecoveryState) -> Option<PlanId> {
    match state {
        RecoveryState::RecoveryRequired { plan, .. } => *plan,
        RecoveryState::Clean => None,
    }
}
