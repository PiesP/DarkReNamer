use std::collections::{BTreeMap, BTreeSet};

use darknamer_core::validate_windows_leaf_name;

use super::model::PlannedEntry;
use super::{
    PathKey, PlanError, PlanId, PlanIssue, PlanIssueKind, PlanRequest, RenameBackend, RenameIntent,
    RenamePlan,
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

        for intent in &changed {
            validate_intent(intent, &mut issues);
            destination_owners
                .entry(self.backend.path_key(&intent.destination))
                .or_default()
                .push(intent.id);
        }
        for owners in destination_owners
            .values()
            .filter(|owners| owners.len() > 1)
        {
            issues.extend(owners.iter().map(|entry| PlanIssue {
                entry: *entry,
                kind: PlanIssueKind::DuplicateDestination,
            }));
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues));
        }

        let mut entries = Vec::with_capacity(changed.len());
        let mut planned_source_identities = BTreeSet::new();
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
            planned_source_identities.insert(source_entry.identity);
            entries.push(PlannedEntry {
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
            if entry.destination_snapshot.entry.is_some_and(|destination| {
                !planned_source_identities.contains(&destination.identity)
            }) {
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
