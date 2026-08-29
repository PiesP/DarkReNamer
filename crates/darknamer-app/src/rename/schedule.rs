use std::collections::BTreeSet;

use darknamer_core::LegacyText;

use super::model::PlannedEntry;
use super::{EntryId, EntryIdentity, PathKey, RenameBackend, RenamePlan};

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct ScheduleStep {
    pub entry: EntryId,
    pub source: LegacyText,
    pub destination: LegacyText,
    pub identity: EntryIdentity,
    pub temporary_destination: bool,
}

pub(super) fn build_schedule(
    plan: &RenamePlan,
    backend: &dyn RenameBackend,
) -> Option<Vec<ScheduleStep>> {
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

        let pivot = pending.iter().position(|is_pending| *is_pending)?;
        let pivot_entry = &plan.entries[pivot];
        let temporary = unique_temporary_path(plan, pivot_entry, backend, &mut reserved);
        let identity = source_identity(pivot_entry)?;
        schedule.push(ScheduleStep {
            entry: pivot_entry.id,
            source: pivot_entry.source.clone(),
            destination: temporary.clone(),
            identity,
            temporary_destination: true,
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
            temporary_destination: false,
        });
        pending[pivot] = false;
        remaining -= 1;
    }

    Some(schedule)
}

fn direct_step(entry: &PlannedEntry) -> Option<ScheduleStep> {
    Some(ScheduleStep {
        entry: entry.id,
        source: entry.source.clone(),
        destination: entry.destination.clone(),
        identity: source_identity(entry)?,
        temporary_destination: false,
    })
}

fn source_identity(entry: &PlannedEntry) -> Option<EntryIdentity> {
    entry.source_snapshot.entry.map(|source| source.identity)
}

fn unique_temporary_path(
    plan: &RenamePlan,
    pivot: &PlannedEntry,
    backend: &dyn RenameBackend,
    reserved: &mut BTreeSet<PathKey>,
) -> LegacyText {
    let parent = parent_units(pivot.source.units());
    let mut ordinal = 0_u32;
    loop {
        let leaf = format!(
            ".__darknamer_{:016x}_{:08x}_{ordinal:08x}.tmp",
            plan.id.value(),
            pivot.id.value()
        );
        let mut units = Vec::with_capacity(parent.len() + 1 + leaf.len());
        units.extend_from_slice(parent);
        units.push(b'\\' as u16);
        units.extend(leaf.encode_utf16());
        let path = LegacyText::from_units(units);
        if reserved.insert(backend.path_key(&path)) {
            return path;
        }
        ordinal = ordinal.wrapping_add(1);
    }
}

fn parent_units(path: &[u16]) -> &[u16] {
    path.iter()
        .rposition(|unit| *unit == b'\\' as u16 || *unit == b'/' as u16)
        .map_or(&[], |index| &path[..index])
}
