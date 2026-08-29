use std::collections::{BTreeMap, BTreeSet};

use darknamer_core::validate_windows_leaf_name;

use super::model::PlanRow;
use super::{
    EntryId, PathKey, PlanError, PlanId, PlanIssue, PlanIssueKind, PlanRequest, RenameBackend,
    RenameIntent, RenamePlan,
};

/// Maximum number of path components accepted by one direct plan request.
///
/// This is a planner safety bound, independent of admission traversal depth.
pub const MAX_PLAN_PATH_DEPTH: usize = 256;

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
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues));
        }
        for intent in &changed {
            for path in [&intent.source, &intent.destination] {
                if let Err(error) = self.backend.validate_path_environment(path) {
                    issues.push(PlanIssue {
                        entry: intent.id,
                        kind: match error.code {
                            50 => PlanIssueKind::UnsupportedCaseSensitiveParent,
                            53 => PlanIssueKind::UnsupportedWindowsPath,
                            _ => PlanIssueKind::BackendFailure(error),
                        },
                    });
                }
            }
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues));
        }
        for intent in &changed {
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
        let mut overlap_entries = BTreeSet::new();
        for intent in &changed {
            visit_direct_ancestors(&intent.source, |ancestor| {
                if let Some(owners) = source_owners.get(&self.backend.path_key(ancestor)) {
                    overlap_entries.insert(intent.id);
                    overlap_entries.extend(owners.iter().copied());
                }
            });
        }
        issues.extend(overlap_entries.into_iter().map(|entry| PlanIssue {
            entry,
            kind: PlanIssueKind::SourceOverlap,
        }));
        if !issues.is_empty() {
            return Err(PlanError::new(issues));
        }

        let mut entries = Vec::with_capacity(changed.len());
        let planned_source_keys = source_owners.keys().cloned().collect::<BTreeSet<_>>();
        for intent in changed {
            let source_snapshot = match self.backend.observe(&intent.source) {
                Ok(snapshot) => snapshot,
                Err(error) => {
                    issues.push(PlanIssue {
                        entry: intent.id,
                        kind: PlanIssueKind::BackendFailure(error),
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
                Err(error) => {
                    issues.push(PlanIssue {
                        entry: intent.id,
                        kind: PlanIssueKind::BackendFailure(error),
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

fn visit_direct_ancestors(
    path: &darknamer_core::LegacyText,
    mut visit: impl FnMut(&darknamer_core::LegacyText),
) {
    let mut ancestor = path.clone();
    for _ in 0..MAX_PLAN_PATH_DEPTH {
        let Some(separator) = ancestor
            .units()
            .iter()
            .rposition(|unit| is_separator(*unit))
        else {
            break;
        };
        if separator <= 2 && ancestor.units().get(1) == Some(&(b':' as u16)) {
            break;
        }
        ancestor.truncate_units(separator);
        if ancestor.is_empty() {
            break;
        }
        visit(&ancestor);
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

fn validate_intent(intent: &RenameIntent, issues: &mut Vec<PlanIssue>) {
    if path_component_depth(intent.source.units()) > MAX_PLAN_PATH_DEPTH
        || path_component_depth(intent.destination_parent.units()) > MAX_PLAN_PATH_DEPTH
    {
        issues.push(PlanIssue {
            entry: intent.id,
            kind: PlanIssueKind::PathTooDeep,
        });
    }
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

fn path_component_depth(units: &[u16]) -> usize {
    let start = if units.len() >= 7
        && is_separator(units[0])
        && is_separator(units[1])
        && units[2] == b'?' as u16
        && is_separator(units[3])
        && units[5] == b':' as u16
        && is_separator(units[6])
    {
        7
    } else if units.len() >= 3 && units[1] == b':' as u16 && is_separator(units[2]) {
        3
    } else {
        0
    };
    let mut depth = 0;
    let mut in_component = false;
    for unit in &units[start..] {
        if is_separator(*unit) {
            in_component = false;
        } else if !in_component {
            depth += 1;
            in_component = true;
        }
    }
    depth
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
    hash_value(&mut hash, 0x4452_504c_414e_0001);
    hash_value(&mut hash, request.revision.value());
    hash_value(&mut hash, request.entries.len() as u64);
    for intent in &request.entries {
        hash_value(&mut hash, u64::from(intent.id.value()));
        hash_value(&mut hash, intent.kind as u64);
        hash_text(&mut hash, &intent.source);
        hash_text(&mut hash, &intent.destination);
    }
    hash
}

fn hash_text(hash: &mut u64, text: &darknamer_core::LegacyText) {
    hash_value(hash, text.len() as u64);
    for unit in text.units() {
        hash_value(hash, u64::from(*unit));
    }
}

fn hash_value(hash: &mut u64, value: u64) {
    for byte in value.to_le_bytes() {
        *hash ^= u64::from(byte);
        *hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
}
