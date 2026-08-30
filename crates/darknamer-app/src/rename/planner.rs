use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

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

/// Outcome that distinguishes cooperative cancellation from plan blockers.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PlanAttemptError {
    /// The caller requested cancellation before planning completed.
    Cancelled,
    /// Planning completed with structured blockers.
    Plan(PlanError),
}

impl From<PlanError> for PlanAttemptError {
    fn from(error: PlanError) -> Self {
        Self::Plan(error)
    }
}

impl fmt::Display for PlanAttemptError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Cancelled => formatter.write_str("rename planning was cancelled"),
            Self::Plan(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for PlanAttemptError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Cancelled => None,
            Self::Plan(error) => Some(error),
        }
    }
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
        match self.plan_cancellable(request, || false) {
            Ok(plan) => Ok(plan),
            Err(PlanAttemptError::Plan(error)) => Err(error),
            Err(PlanAttemptError::Cancelled) => {
                unreachable!("the non-cancellable planner cannot be cancelled")
            }
        }
    }

    /// Validates a request while polling cooperative cancellation between rows.
    ///
    /// # Errors
    ///
    /// Returns [`PlanAttemptError::Cancelled`] independently from structured
    /// plan blockers.
    pub fn plan_cancellable(
        &self,
        request: PlanRequest,
        cancellation_requested: impl Fn() -> bool,
    ) -> Result<RenamePlan, PlanAttemptError> {
        let mut changed = Vec::with_capacity(request.entries.len());
        for intent in &request.entries {
            check_cancelled(&cancellation_requested)?;
            if intent.source != intent.destination {
                changed.push(intent);
            }
        }
        let mut issues = Vec::new();
        let mut destination_owners: BTreeMap<PathKey, Vec<_>> = BTreeMap::new();
        let mut source_owners: BTreeMap<PathKey, Vec<_>> = BTreeMap::new();
        let mut entry_owners: BTreeMap<_, Vec<_>> = BTreeMap::new();

        for intent in &changed {
            check_cancelled(&cancellation_requested)?;
            validate_intent(intent, &mut issues);
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues).into());
        }
        for intent in &changed {
            check_cancelled(&cancellation_requested)?;
            for path in [&intent.source, &intent.destination] {
                check_cancelled(&cancellation_requested)?;
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
            return Err(PlanError::new(issues).into());
        }
        for intent in &changed {
            check_cancelled(&cancellation_requested)?;
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
            &cancellation_requested,
        )?;
        append_duplicate_issues(
            entry_owners.values(),
            PlanIssueKind::DuplicateEntryId,
            &mut issues,
            &cancellation_requested,
        )?;
        for owners in destination_owners
            .values()
            .filter(|owners| owners.len() > 1)
        {
            check_cancelled(&cancellation_requested)?;
            for entry in owners {
                check_cancelled(&cancellation_requested)?;
                issues.push(PlanIssue {
                    entry: *entry,
                    kind: PlanIssueKind::DuplicateDestination,
                });
            }
        }
        let mut overlap_entries = BTreeSet::new();
        for intent in &changed {
            check_cancelled(&cancellation_requested)?;
            visit_direct_ancestors(&intent.source, &cancellation_requested, |ancestor| {
                if let Some(owners) = source_owners.get(&self.backend.path_key(ancestor)) {
                    overlap_entries.insert(intent.id);
                    overlap_entries.extend(owners.iter().copied());
                }
            })?;
        }
        for entry in overlap_entries {
            check_cancelled(&cancellation_requested)?;
            issues.push(PlanIssue {
                entry,
                kind: PlanIssueKind::SourceOverlap,
            });
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues).into());
        }

        let mut entries = Vec::with_capacity(changed.len());
        let mut planned_source_keys = BTreeSet::new();
        for key in source_owners.keys() {
            check_cancelled(&cancellation_requested)?;
            planned_source_keys.insert(key.clone());
        }
        for intent in changed {
            check_cancelled(&cancellation_requested)?;
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
            check_cancelled(&cancellation_requested)?;
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
            check_cancelled(&cancellation_requested)?;
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
            return Err(PlanError::new(issues).into());
        }

        for entry in &entries {
            check_cancelled(&cancellation_requested)?;
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
            return Err(PlanError::new(issues).into());
        }

        check_cancelled(&cancellation_requested)?;
        Ok(RenamePlan {
            id: PlanId::new(plan_id_cancellable(&request, &cancellation_requested)?),
            revision: request.revision,
            entries: entries.into_boxed_slice(),
        })
    }
}

fn append_duplicate_issues<'a>(
    owner_sets: impl Iterator<Item = &'a Vec<EntryId>>,
    kind: PlanIssueKind,
    issues: &mut Vec<PlanIssue>,
    cancellation_requested: &impl Fn() -> bool,
) -> Result<(), PlanAttemptError> {
    for owners in owner_sets.filter(|owners| owners.len() > 1) {
        check_cancelled(cancellation_requested)?;
        for entry in owners {
            check_cancelled(cancellation_requested)?;
            issues.push(PlanIssue {
                entry: *entry,
                kind: kind.clone(),
            });
        }
    }
    Ok(())
}

fn visit_direct_ancestors(
    path: &darknamer_core::LegacyText,
    cancellation_requested: &impl Fn() -> bool,
    mut visit: impl FnMut(&darknamer_core::LegacyText),
) -> Result<(), PlanAttemptError> {
    let mut ancestor = path.clone();
    for _ in 0..MAX_PLAN_PATH_DEPTH {
        check_cancelled(cancellation_requested)?;
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
    Ok(())
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

fn plan_id_cancellable(
    request: &PlanRequest,
    cancellation_requested: &impl Fn() -> bool,
) -> Result<u64, PlanAttemptError> {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    hash_value(&mut hash, 0x4452_504c_414e_0001);
    hash_value(&mut hash, request.revision.value());
    hash_value(&mut hash, request.entries.len() as u64);
    for intent in &request.entries {
        check_cancelled(cancellation_requested)?;
        hash_value(&mut hash, u64::from(intent.id.value()));
        hash_value(&mut hash, intent.kind as u64);
        hash_text(&mut hash, &intent.source);
        hash_text(&mut hash, &intent.destination);
    }
    Ok(hash)
}

fn check_cancelled(cancellation_requested: &impl Fn() -> bool) -> Result<(), PlanAttemptError> {
    if cancellation_requested() {
        Err(PlanAttemptError::Cancelled)
    } else {
        Ok(())
    }
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
