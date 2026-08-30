use std::collections::{BTreeMap, BTreeSet};

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
    Cancelled,
    Invalid,
    Backend(BackendError),
    StaleParent(EntryId),
    TemporaryExhausted(EntryId),
}

#[cfg(test)]
pub(super) fn build_schedule(
    plan: &RenamePlan,
    backend: &mut dyn RenameBackend,
) -> Result<Vec<ScheduleStep>, ScheduleError> {
    build_schedule_cancellable(plan, backend, &|| false)
}

pub(super) fn build_schedule_cancellable(
    plan: &RenamePlan,
    backend: &mut dyn RenameBackend,
    cancellation_requested: &dyn Fn() -> bool,
) -> Result<Vec<ScheduleStep>, ScheduleError> {
    let mut source_keys = Vec::with_capacity(plan.entries.len());
    let mut destination_keys = Vec::with_capacity(plan.entries.len());
    for entry in &plan.entries {
        check_cancelled(cancellation_requested)?;
        source_keys.push(backend.path_key(&entry.source));
        destination_keys.push(backend.path_key(&entry.destination));
    }
    let mut reserved = BTreeSet::new();
    for key in source_keys.iter().chain(&destination_keys) {
        check_cancelled(cancellation_requested)?;
        reserved.insert(key.clone());
    }
    let mut source_owners = BTreeMap::new();
    for (index, key) in source_keys.iter().cloned().enumerate() {
        check_cancelled(cancellation_requested)?;
        if source_owners.insert(key, index).is_some() {
            return Err(ScheduleError::Invalid);
        }
    }
    let mut dependencies = vec![None; plan.entries.len()];
    let mut predecessors = vec![None; plan.entries.len()];
    for (index, destination) in destination_keys.iter().enumerate() {
        check_cancelled(cancellation_requested)?;
        let Some(owner) = source_owners.get(destination).copied() else {
            continue;
        };
        dependencies[index] = Some(owner);
        if predecessors[owner].replace(index).is_some() {
            return Err(ScheduleError::Invalid);
        }
    }
    let mut pending = vec![true; plan.entries.len()];
    let mut remaining = pending.len();
    let mut remaining_indices = BTreeSet::new();
    let mut ready = BTreeSet::new();
    for (index, dependency) in dependencies.iter().enumerate() {
        check_cancelled(cancellation_requested)?;
        remaining_indices.insert(index);
        if dependency.is_none() {
            ready.insert(index);
        }
    }
    let mut schedule = Vec::with_capacity(plan.entries.len().saturating_mul(2));

    while remaining > 0 {
        check_cancelled(cancellation_requested)?;
        if let Some(index) = ready.pop_first() {
            if !pending[index] {
                return Err(ScheduleError::Invalid);
            }
            schedule.push(direct_step(&plan.entries[index])?);
            pending[index] = false;
            if !remaining_indices.remove(&index) {
                return Err(ScheduleError::Invalid);
            }
            remaining -= 1;
            if let Some(predecessor) = predecessors[index]
                && pending[predecessor]
            {
                ready.insert(predecessor);
            }
            continue;
        }

        let pivot = remaining_indices
            .first()
            .copied()
            .ok_or(ScheduleError::Invalid)?;
        let pivot_entry = &plan.entries[pivot];
        let temporary = unique_temporary_path(
            plan,
            pivot_entry,
            backend,
            &mut reserved,
            cancellation_requested,
        )?;
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

        let mut freed = pivot;
        while let Some(index) = predecessors[freed] {
            check_cancelled(cancellation_requested)?;
            if index == pivot {
                break;
            }
            if !pending[index] {
                return Err(ScheduleError::Invalid);
            }
            schedule.push(direct_step(&plan.entries[index])?);
            freed = index;
            pending[index] = false;
            if !remaining_indices.remove(&index) {
                return Err(ScheduleError::Invalid);
            }
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
        if !remaining_indices.remove(&pivot) {
            return Err(ScheduleError::Invalid);
        }
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
    cancellation_requested: &dyn Fn() -> bool,
) -> Result<LegacyText, ScheduleError> {
    check_cancelled(cancellation_requested)?;
    let nonce = backend
        .next_transaction_nonce()
        .map_err(ScheduleError::Backend)?;
    let parent = parent_units(pivot.source.units());
    for ordinal in 0..MAX_TEMP_CANDIDATES {
        check_cancelled(cancellation_requested)?;
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

fn check_cancelled(cancellation_requested: &dyn Fn() -> bool) -> Result<(), ScheduleError> {
    if cancellation_requested() {
        Err(ScheduleError::Cancelled)
    } else {
        Ok(())
    }
}

fn parent_units(path: &[u16]) -> &[u16] {
    path.iter()
        .rposition(|unit| *unit == b'\\' as u16 || *unit == b'/' as u16)
        .map_or(&[], |index| &path[..index])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rename::{EntryKind, MemoryBackend, ModelRevision, PlanId};

    fn build_plan(
        backend: &MemoryBackend,
        paths: impl IntoIterator<Item = (u32, String, String)>,
    ) -> Result<RenamePlan, BackendError> {
        let entries = paths
            .into_iter()
            .map(|(id, source, destination)| {
                let source = LegacyText::from(source);
                let destination = LegacyText::from(destination);
                Ok(PlanRow {
                    id: EntryId::new(id),
                    source_snapshot: backend.observe(&source)?,
                    destination_snapshot: backend.observe(&destination)?,
                    source,
                    destination,
                    kind: EntryKind::File,
                })
            })
            .collect::<Result<Vec<_>, BackendError>>()?;
        Ok(RenamePlan {
            id: PlanId::from_fingerprint(1),
            revision: ModelRevision::new(1),
            entries: entries.into_boxed_slice(),
        })
    }

    #[test]
    fn ten_thousand_independent_entries_keep_input_order() -> Result<(), Box<dyn std::error::Error>>
    {
        const COUNT: usize = 10_000;
        let mut backend = MemoryBackend::new();
        let mut paths = Vec::with_capacity(COUNT);
        for index in 0..COUNT {
            let source = format!("C:\\work\\source-{index:05}.txt");
            let destination = format!("C:\\work\\target-{index:05}.txt");
            backend = backend.with_file(source.clone(), index as u128 + 1);
            paths.push((index as u32, source, destination));
        }
        let plan = build_plan(&backend, paths)?;

        let schedule = build_schedule(&plan, &mut backend)
            .map_err(|error| std::io::Error::other(format!("schedule failed: {error:?}")))?;

        assert_eq!(schedule.len(), COUNT);
        assert!(
            schedule
                .iter()
                .enumerate()
                .all(|(index, step)| step.entry == EntryId::new(index as u32))
        );
        Ok(())
    }

    #[test]
    fn ten_thousand_entry_chain_runs_in_reverse_dependency_order()
    -> Result<(), Box<dyn std::error::Error>> {
        const COUNT: usize = 10_000;
        let mut backend = MemoryBackend::new();
        let mut paths = Vec::with_capacity(COUNT);
        for index in 0..COUNT {
            let source = format!("C:\\work\\node-{index:05}.txt");
            let destination = if index + 1 == COUNT {
                "C:\\work\\final.txt".to_owned()
            } else {
                format!("C:\\work\\node-{:05}.txt", index + 1)
            };
            backend = backend.with_file(source.clone(), index as u128 + 1);
            paths.push((index as u32, source, destination));
        }
        let plan = build_plan(&backend, paths)?;

        let schedule = build_schedule(&plan, &mut backend)
            .map_err(|error| std::io::Error::other(format!("schedule failed: {error:?}")))?;

        assert_eq!(schedule.len(), COUNT);
        assert!(schedule.iter().enumerate().all(|(index, step)| {
            step.entry == EntryId::new(u32::try_from(COUNT - index - 1).unwrap_or_default())
        }));
        Ok(())
    }

    #[test]
    fn separate_cycles_each_use_one_temporary_hop() -> Result<(), Box<dyn std::error::Error>> {
        let mut backend = MemoryBackend::new()
            .with_file("C:\\work\\a.txt", 1)
            .with_file("C:\\work\\b.txt", 2)
            .with_file("C:\\work\\c.txt", 3)
            .with_file("C:\\work\\d.txt", 4);
        let plan = build_plan(
            &backend,
            [
                (
                    0,
                    "C:\\work\\a.txt".to_owned(),
                    "C:\\work\\b.txt".to_owned(),
                ),
                (
                    1,
                    "C:\\work\\b.txt".to_owned(),
                    "C:\\work\\a.txt".to_owned(),
                ),
                (
                    2,
                    "C:\\work\\c.txt".to_owned(),
                    "C:\\work\\d.txt".to_owned(),
                ),
                (
                    3,
                    "C:\\work\\d.txt".to_owned(),
                    "C:\\work\\c.txt".to_owned(),
                ),
            ],
        )?;

        let schedule = build_schedule(&plan, &mut backend)
            .map_err(|error| std::io::Error::other(format!("schedule failed: {error:?}")))?;

        assert_eq!(schedule.len(), 6);
        assert_eq!(
            schedule
                .iter()
                .filter(|step| step.temporary_phase == TemporaryPhase::IntoTemporary)
                .count(),
            2
        );
        assert_eq!(
            schedule
                .iter()
                .filter(|step| step.temporary_phase == TemporaryPhase::FromTemporary)
                .count(),
            2
        );
        Ok(())
    }

    #[test]
    fn ten_thousand_case_only_cycles_use_bounded_pivot_selection()
    -> Result<(), Box<dyn std::error::Error>> {
        const COUNT: usize = 10_000;
        let mut backend = MemoryBackend::new();
        let mut paths = Vec::with_capacity(COUNT);
        for index in 0..COUNT {
            let source = format!("C:\\work\\FILE-{index:05}.TXT");
            let destination = format!("C:\\work\\file-{index:05}.txt");
            backend = backend.with_file(source.clone(), index as u128 + 1);
            paths.push((index as u32, source, destination));
        }
        let plan = build_plan(&backend, paths)?;

        let schedule = build_schedule(&plan, &mut backend)
            .map_err(|error| std::io::Error::other(format!("schedule failed: {error:?}")))?;

        assert_eq!(schedule.len(), COUNT * 2);
        assert_eq!(
            schedule
                .iter()
                .filter(|step| step.temporary_phase == TemporaryPhase::IntoTemporary)
                .count(),
            COUNT
        );
        assert_eq!(
            schedule
                .iter()
                .filter(|step| step.temporary_phase == TemporaryPhase::FromTemporary)
                .count(),
            COUNT
        );
        Ok(())
    }
}
