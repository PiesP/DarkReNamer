use std::collections::{BTreeMap, BTreeSet};

use darknamer_core::validate_windows_leaf_name;

use super::model::PlanRow;
use super::{
    EntryId, PathKey, PlanError, PlanId, PlanIssue, PlanIssueKind, PlanRequest, RenameBackend,
    RenameIntent, RenamePlan,
};

/// Builds immutable plans without mutating the filesystem adapter.
pub struct RenamePlanner<'a> {
    backend: &'a dyn RenameBackend,
}

impl<'a> RenamePlanner<'a> {
    /// Creates a planner over one filesystem adapter.
    #[must_use]
    pub const fn new(backend: &'a dyn RenameBackend) -> Self {
        Self { backend }
    }

    /// Validates a request and freezes its filesystem observations.
    ///
    /// # Errors
    ///
    /// Returns structured blockers without mutating the backend.
    pub fn plan(&self, request: PlanRequest) -> Result<RenamePlan, PlanError> {
        let changed = request
            .entries
            .iter()
            .filter(|intent| intent.source != intent.destination)
            .collect::<Vec<_>>();
        let mut issues = Vec::new();
        let mut destination_owners: BTreeMap<PathKey, Vec<_>> = BTreeMap::new();
        let mut source_owners: BTreeMap<PathKey, Vec<_>> = BTreeMap::new();
        let mut entry_owners: BTreeMap<_, Vec<_>> = BTreeMap::new();

        for intent in &changed {
            validate_intent(intent, &mut issues);
            source_owners
                .entry(self.backend.path_key(&intent.source))
                .or_default()
                .push(intent.id);
            entry_owners.entry(intent.id).or_default().push(intent.id);
            destination_owners
                .entry(self.backend.path_key(&intent.destination))
                .or_default()
                .push(intent.id);
            if self.backend.path_key(&parent_path(&intent.source))
                != self.backend.path_key(&parent_path(&intent.destination))
            {
                issues.push(PlanIssue {
                    entry: intent.id,
                    kind: PlanIssueKind::CrossParent,
                });
            }
        }
        append_duplicate_issues(
            source_owners.values(),
            PlanIssueKind::DuplicateSource,
            &mut issues,
        );
        append_duplicate_issues(
            entry_owners.values(),
            PlanIssueKind::DuplicateEntryId,
            &mut issues,
        );
        for owners in destination_owners
            .values()
            .filter(|owners| owners.len() > 1)
        {
            issues.extend(owners.iter().map(|entry| PlanIssue {
                entry: *entry,
                kind: PlanIssueKind::DuplicateDestination,
            }));
        }
        let ordered_sources = source_owners.iter().collect::<Vec<_>>();
        for pair in ordered_sources.windows(2) {
            if is_ancestor_key(pair[0].0, pair[1].0) {
                issues.push(PlanIssue {
                    entry: pair[0].1[0],
                    kind: PlanIssueKind::SourceOverlap,
                });
                issues.push(PlanIssue {
                    entry: pair[1].1[0],
                    kind: PlanIssueKind::SourceOverlap,
                });
            }
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues));
        }

        let mut entries = Vec::with_capacity(changed.len());
        let planned_source_keys = source_owners.keys().cloned().collect::<BTreeSet<_>>();
        for intent in changed {
            let source_snapshot = match self.backend.observe(&intent.source) {
                Ok(snapshot) => snapshot,
                Err(_error) => {
                    issues.push(PlanIssue {
                        entry: intent.id,
                        kind: PlanIssueKind::Backend,
                    });
                    continue;
                }
            };
            let Some(source_entry) = source_snapshot.entry else {
                issues.push(PlanIssue {
                    entry: intent.id,
                    kind: PlanIssueKind::MissingSource,
                });
                continue;
            };
            if source_entry.kind != intent.kind {
                issues.push(PlanIssue {
                    entry: intent.id,
                    kind: PlanIssueKind::SourceKindChanged,
                });
                continue;
            }
            if source_entry.is_reparse_point {
                issues.push(PlanIssue {
                    entry: intent.id,
                    kind: PlanIssueKind::ReparseSource,
                });
                continue;
            }
            let destination_snapshot = match self.backend.observe(&intent.destination) {
                Ok(snapshot) => snapshot,
                Err(_error) => {
                    issues.push(PlanIssue {
                        entry: intent.id,
                        kind: PlanIssueKind::Backend,
                    });
                    continue;
                }
            };
            entries.push(PlanRow {
                id: intent.id,
                source: intent.source.clone(),
                destination: intent.destination.clone(),
                kind: intent.kind,
                source_snapshot,
                destination_snapshot,
            });
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues));
        }

        for entry in &entries {
            if entry.destination_snapshot.entry.is_some()
                && !planned_source_keys.contains(&self.backend.path_key(&entry.destination))
            {
                issues.push(PlanIssue {
                    entry: entry.id,
                    kind: PlanIssueKind::DestinationOccupied,
                });
            }
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues));
        }

        Ok(RenamePlan {
            id: PlanId::new(plan_id(&request)),
            revision: request.revision,
            entries: entries.into_boxed_slice(),
        })
    }
}

fn append_duplicate_issues<'a>(
    owner_sets: impl Iterator<Item = &'a Vec<EntryId>>,
    kind: PlanIssueKind,
    issues: &mut Vec<PlanIssue>,
) {
    for owners in owner_sets.filter(|owners| owners.len() > 1) {
        issues.extend(owners.iter().map(|entry| PlanIssue {
            entry: *entry,
            kind: kind.clone(),
        }));
    }
}

fn parent_path(path: &darknamer_core::LegacyText) -> darknamer_core::LegacyText {
    let units = path.units();
    let end = units
        .iter()
        .rposition(|unit| is_separator(*unit))
        .unwrap_or(0);
    darknamer_core::LegacyText::from_units(units[..end].to_vec())
}

fn is_ancestor_key(ancestor: &PathKey, descendant: &PathKey) -> bool {
    descendant.units().len() > ancestor.units().len()
        && descendant.units().starts_with(ancestor.units())
        && descendant
            .units()
            .get(ancestor.units().len())
            .is_some_and(|unit| is_separator(*unit))
}

fn validate_intent(intent: &RenameIntent, issues: &mut Vec<PlanIssue>) {
    if !is_absolute_windows_path(intent.source.units()) {
        issues.push(PlanIssue {
            entry: intent.id,
            kind: PlanIssueKind::RelativeSource,
        });
    }
    if !is_absolute_windows_path(intent.destination_parent.units()) {
        issues.push(PlanIssue {
            entry: intent.id,
            kind: PlanIssueKind::RelativeDestinationParent,
        });
    }
    if let Err(error) = validate_windows_leaf_name(&intent.destination_name) {
        issues.push(PlanIssue {
            entry: intent.id,
            kind: PlanIssueKind::InvalidDestinationName(error),
        });
    }
}

fn is_absolute_windows_path(units: &[u16]) -> bool {
    let drive_absolute = units.len() >= 3
        && ((b'A' as u16..=b'Z' as u16).contains(&units[0])
            || (b'a' as u16..=b'z' as u16).contains(&units[0]))
        && units[1] == b':' as u16
        && is_separator(units[2]);
    let unc_absolute = units.len() >= 2 && is_separator(units[0]) && is_separator(units[1]);
    drive_absolute || unc_absolute
}

fn is_separator(unit: u16) -> bool {
    unit == b'\\' as u16 || unit == b'/' as u16
}

fn plan_id(request: &PlanRequest) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for intent in &request.entries {
        for unit in intent
            .source
            .units()
            .iter()
            .chain(intent.destination.units())
        {
            hash ^= u64::from(*unit);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    hash
}
