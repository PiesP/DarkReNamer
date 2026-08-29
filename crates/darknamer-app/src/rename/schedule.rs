use std::collections::BTreeSet;

use darknamer_core::LegacyText;

use super::model::PlanRow;
use super::{BackendError, EntryId, EntryIdentity, PathKey, RenameBackend, RenamePlan};

/// Maximum temporary-name probes for one cycle pivot.
pub const MAX_TEMP_CANDIDATES: usize = 32;

/// Whether a primitive step enters or leaves a temporary endpoint.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TemporaryPhase {
    /// Direct source-to-final-destination move.
    None,
    /// Source-to-temporary move opening a cycle.
    IntoTemporary,
    /// Temporary-to-final move closing a cycle.
    FromTemporary,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct ScheduleStep {
    pub entry: EntryId,
    pub source: LegacyText,
    pub destination: LegacyText,
    pub identity: EntryIdentity,
    pub source_parent: EntryIdentity,
    pub destination_parent: EntryIdentity,
    pub temporary_phase: TemporaryPhase,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ScheduleError {
    Invalid,
    Backend(BackendError),
    StaleParent(EntryId),
    TemporaryExhausted(EntryId),
}

pub(super) fn build_schedule(
    plan: &RenamePlan,
    backend: &mut dyn RenameBackend,
) -> Result<Vec<ScheduleStep>, ScheduleError> {
    let source_keys = plan
        .entries
        .iter()
        .map(|entry| backend.path_key(&entry.source))
        .collect::<Vec<_>>();
    let destination_keys = plan
        .entries
        .iter()
        .map(|entry| backend.path_key(&entry.destination))
        .collect::<Vec<_>>();
    let mut reserved = source_keys
        .iter()
        .chain(&destination_keys)
        .cloned()
        .collect::<BTreeSet<_>>();
    let mut pending = vec![true; plan.entries.len()];
    let mut remaining = pending.len();
    let mut schedule = Vec::new();

    while remaining > 0 {
        let movable = pending.iter().enumerate().find_map(|(index, is_pending)| {
            if !is_pending {
                return None;
            }
            let destination_is_pending_source =
                pending
                    .iter()
                    .enumerate()
                    .any(|(source_index, source_pending)| {
                        *source_pending && source_keys[source_index] == destination_keys[index]
                    });
            (!destination_is_pending_source).then_some(index)
        });
        if let Some(index) = movable {
            schedule.push(direct_step(&plan.entries[index])?);
            pending[index] = false;
            remaining -= 1;
            continue;
        }

        let pivot = pending
            .iter()
            .position(|is_pending| *is_pending)
            .ok_or(ScheduleError::Invalid)?;
        let pivot_entry = &plan.entries[pivot];
        let temporary = unique_temporary_path(plan, pivot_entry, backend, &mut reserved)?;
        let identity = source_identity(pivot_entry)?;
        schedule.push(ScheduleStep {
            entry: pivot_entry.id,
            source: pivot_entry.source.clone(),
            destination: temporary.clone(),
            identity,
            source_parent: pivot_entry.source_snapshot.parent,
            destination_parent: pivot_entry.source_snapshot.parent,
            temporary_phase: TemporaryPhase::IntoTemporary,
        });

        let mut freed_key = source_keys[pivot].clone();
        loop {
            let predecessor = pending.iter().enumerate().find_map(|(index, is_pending)| {
                (*is_pending && index != pivot && destination_keys[index] == freed_key)
                    .then_some(index)
            });
            let Some(index) = predecessor else {
                break;
            };
            schedule.push(direct_step(&plan.entries[index])?);
            freed_key.clone_from(&source_keys[index]);
            pending[index] = false;
            remaining -= 1;
        }

        schedule.push(ScheduleStep {
            entry: pivot_entry.id,
            source: temporary,
            destination: pivot_entry.destination.clone(),
            identity,
            source_parent: pivot_entry.source_snapshot.parent,
            destination_parent: pivot_entry.destination_snapshot.parent,
            temporary_phase: TemporaryPhase::FromTemporary,
        });
        pending[pivot] = false;
        remaining -= 1;
    }

    Ok(schedule)
}

fn direct_step(entry: &PlanRow) -> Result<ScheduleStep, ScheduleError> {
    Ok(ScheduleStep {
        entry: entry.id,
        source: entry.source.clone(),
        destination: entry.destination.clone(),
        identity: source_identity(entry)?,
        source_parent: entry.source_snapshot.parent,
        destination_parent: entry.destination_snapshot.parent,
        temporary_phase: TemporaryPhase::None,
    })
}

fn source_identity(entry: &PlanRow) -> Result<EntryIdentity, ScheduleError> {
    entry
        .source_snapshot
        .entry
        .map(|source| source.identity)
        .ok_or(ScheduleError::Invalid)
}

fn unique_temporary_path(
    plan: &RenamePlan,
    pivot: &PlanRow,
    backend: &mut dyn RenameBackend,
    reserved: &mut BTreeSet<PathKey>,
) -> Result<LegacyText, ScheduleError> {
    let nonce = backend
        .next_transaction_nonce()
        .map_err(ScheduleError::Backend)?;
    let parent = parent_units(pivot.source.units());
    for ordinal in 0..MAX_TEMP_CANDIDATES {
        let leaf = format!(
            ".__darknamer_{:016x}_{nonce:032x}_{:08x}_{ordinal:02x}.tmp",
            plan.id.value(),
            pivot.id.value()
        );
        let mut units = Vec::with_capacity(parent.len() + 1 + leaf.len());
        units.extend_from_slice(parent);
        units.push(b'\\' as u16);
        units.extend(leaf.encode_utf16());
        let path = LegacyText::from_units(units);
        let key = backend.path_key(&path);
        if reserved.contains(&key) {
            continue;
        }
        let snapshot = backend.observe(&path).map_err(ScheduleError::Backend)?;
        if snapshot.parent != pivot.source_snapshot.parent {
            return Err(ScheduleError::StaleParent(pivot.id));
        }
        if snapshot.entry.is_none() {
            reserved.insert(key);
            return Ok(path);
        }
    }
    Err(ScheduleError::TemporaryExhausted(pivot.id))
}

fn parent_units(path: &[u16]) -> &[u16] {
    path.iter()
        .rposition(|unit| *unit == b'\\' as u16 || *unit == b'/' as u16)
        .map_or(&[], |index| &path[..index])
}
