use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use darknamer_core::validate_windows_leaf_name;

use super::model::PlanRow;
use super::ports::path_leaf;
use super::{
    EntryId, EntryIdentity, EntryKind, MoveScope, PathKey, PathSnapshot, PlanError, PlanId,
    PlanIssue, PlanIssueKind, PlanRequest, RenameBackend, RenameIntent, RenamePlan,
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
        let has_changed_directory = changed
            .iter()
            .any(|intent| intent.kind == EntryKind::Directory);
        let mut issues = Vec::new();
        let mut destination_owners: BTreeMap<PathKey, Vec<_>> = BTreeMap::new();
        let mut source_owners: BTreeMap<PathKey, Vec<_>> = BTreeMap::new();
        let mut entry_owners: BTreeMap<_, Vec<_>> = BTreeMap::new();

        for intent in &changed {
            check_cancelled(&cancellation_requested)?;
            validate_intent(intent, &mut issues);
        }
        if !changed.is_empty() {
            for intent in request
                .entries
                .iter()
                .filter(|intent| intent.source == intent.destination)
            {
                check_cancelled(&cancellation_requested)?;
                validate_source_path(intent, &mut issues);
            }
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
                        kind: path_environment_issue(error),
                    });
                }
            }
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues).into());
        }
        for intent in &changed {
            check_cancelled(&cancellation_requested)?;
            let source_key = self.backend.path_key(&intent.source);
            source_owners.entry(source_key).or_default().push(intent.id);
            entry_owners.entry(intent.id).or_default().push(intent.id);
            destination_owners
                .entry(self.backend.path_key(&intent.destination))
                .or_default()
                .push(intent.id);
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
                Ok(false)
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
        let mut source_snapshots = BTreeMap::new();
        let mut destination_snapshots = BTreeMap::new();
        for intent in &changed {
            check_cancelled(&cancellation_requested)?;
            let resolved_source = match self.backend.resolve_source(&intent.source) {
                Ok(source) => source,
                Err(error) => {
                    issues.push(PlanIssue {
                        entry: intent.id,
                        kind: PlanIssueKind::BackendFailure(error),
                    });
                    continue;
                }
            };
            let source_snapshot = resolved_source.snapshot();
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
            let Some(source_entry_key) = resolved_source.entry_key().cloned() else {
                issues.push(PlanIssue {
                    entry: intent.id,
                    kind: PlanIssueKind::Backend,
                });
                continue;
            };
            let actual_source = resolved_source.path();
            if path_component_depth(actual_source.units()) > MAX_PLAN_PATH_DEPTH
                || !is_absolute_windows_path(actual_source.units())
            {
                issues.push(PlanIssue {
                    entry: intent.id,
                    kind: PlanIssueKind::Backend,
                });
                continue;
            }
            match self
                .backend
                .planned_entry_key(source_snapshot.parent, &path_leaf(actual_source))
            {
                Ok(key) if key == source_entry_key => {}
                Ok(_) => {
                    issues.push(PlanIssue {
                        entry: intent.id,
                        kind: PlanIssueKind::Backend,
                    });
                    continue;
                }
                Err(error) => {
                    issues.push(PlanIssue {
                        entry: intent.id,
                        kind: PlanIssueKind::BackendFailure(error),
                    });
                    continue;
                }
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
            let parents_differ = source_snapshot.parent != destination_snapshot.parent;
            let volume_differs = source_entry.identity.volume() != source_snapshot.parent.volume()
                || source_snapshot.parent.volume() != destination_snapshot.parent.volume();
            if parents_differ && request.scope == MoveScope::SameParent {
                issues.push(PlanIssue {
                    entry: intent.id,
                    kind: PlanIssueKind::CrossParent,
                });
            }
            if parents_differ
                && request.scope == MoveScope::SameVolumeFilesOnly
                && source_entry.kind == super::EntryKind::Directory
            {
                issues.push(PlanIssue {
                    entry: intent.id,
                    kind: PlanIssueKind::DirectoryMoveUnsupported,
                });
            }
            if volume_differs {
                issues.push(PlanIssue {
                    entry: intent.id,
                    kind: PlanIssueKind::CrossVolume,
                });
            }
            if (parents_differ && request.scope == MoveScope::SameParent)
                || (parents_differ
                    && request.scope == MoveScope::SameVolumeFilesOnly
                    && source_entry.kind == super::EntryKind::Directory)
                || volume_differs
            {
                continue;
            }
            let destination_entry_key = match self
                .backend
                .planned_entry_key(destination_snapshot.parent, &intent.destination_name)
            {
                Ok(key) => key,
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
                source: resolved_source.path().clone(),
                destination: intent.destination.clone(),
                kind: intent.kind,
                source_snapshot,
                destination_snapshot,
                source_entry_key,
                destination_entry_key,
            });
            if has_changed_directory {
                source_snapshots.insert(intent.id, source_snapshot);
                destination_snapshots.insert(intent.id, destination_snapshot);
            }
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues).into());
        }

        let mut actual_destination_owners: BTreeMap<PathKey, Vec<EntryId>> = BTreeMap::new();
        for entry in &entries {
            check_cancelled(&cancellation_requested)?;
            actual_destination_owners
                .entry(entry.destination_entry_key.clone())
                .or_default()
                .push(entry.id);
        }
        append_duplicate_issues(
            actual_destination_owners.values(),
            PlanIssueKind::DuplicateDestination,
            &mut issues,
            &cancellation_requested,
        )?;
        if !issues.is_empty() {
            return Err(PlanError::new(issues).into());
        }

        append_actual_duplicate_source_issues(
            self.backend,
            &request.entries,
            &entries,
            &mut issues,
            &cancellation_requested,
        )?;
        if !issues.is_empty() {
            return Err(PlanError::new(issues).into());
        }

        let mut changed_directory_identity_owners: BTreeMap<EntryIdentity, Vec<EntryId>> =
            BTreeMap::new();
        if has_changed_directory {
            for entry in &entries {
                check_cancelled(&cancellation_requested)?;
                if entry.kind == EntryKind::Directory
                    && let Some(source) = entry.source_snapshot.entry
                {
                    changed_directory_identity_owners
                        .entry(source.identity)
                        .or_default()
                        .push(entry.id);
                }
            }
        }
        if !changed_directory_identity_owners.is_empty() {
            let mut identity_overlap_entries = BTreeSet::new();
            {
                let mut inspection = DirectoryOverlapInspection {
                    backend: self.backend,
                    directory_owners: &changed_directory_identity_owners,
                    overlap_entries: &mut identity_overlap_entries,
                    issues: &mut issues,
                    cancellation_requested: &cancellation_requested,
                };
                for intent in &request.entries {
                    check_cancelled(&cancellation_requested)?;
                    let observation = if intent.source == intent.destination {
                        self.backend.observe(&intent.source)
                    } else {
                        source_snapshots
                            .get(&intent.id)
                            .copied()
                            .map_or_else(|| self.backend.observe(&intent.source), Ok)
                    };
                    inspection.inspect(&intent.source, intent.id, observation, true)?;
                }
                for intent in &changed {
                    check_cancelled(&cancellation_requested)?;
                    let observation = destination_snapshots
                        .get(&intent.id)
                        .copied()
                        .map_or_else(|| self.backend.observe(&intent.destination), Ok);
                    inspection.inspect(&intent.destination, intent.id, observation, false)?;
                }
            }
            for entry in identity_overlap_entries {
                check_cancelled(&cancellation_requested)?;
                issues.push(PlanIssue {
                    entry,
                    kind: PlanIssueKind::SourceOverlap,
                });
            }
        }
        if !issues.is_empty() {
            return Err(PlanError::new(issues).into());
        }

        let mut planned_source_keys = BTreeSet::new();
        for entry in &entries {
            check_cancelled(&cancellation_requested)?;
            planned_source_keys.insert(entry.source_entry_key.clone());
        }
        for entry in &entries {
            check_cancelled(&cancellation_requested)?;
            if entry.destination_snapshot.entry.is_some()
                && !planned_source_keys.contains(&entry.destination_entry_key)
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
            scope: request.scope,
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

struct SourceCandidate<'a> {
    id: EntryId,
    path: &'a darknamer_core::LegacyText,
    entry_key: Option<&'a PathKey>,
    changed: bool,
}

fn append_actual_duplicate_source_issues<'a>(
    backend: &dyn RenameBackend,
    request: &'a [RenameIntent],
    changed_entries: &'a [PlanRow],
    issues: &mut Vec<PlanIssue>,
    cancellation_requested: &impl Fn() -> bool,
) -> Result<(), PlanAttemptError> {
    if changed_entries.is_empty() {
        return Ok(());
    }

    let mut candidates: BTreeMap<(EntryIdentity, EntryIdentity), Vec<SourceCandidate<'a>>> =
        BTreeMap::new();
    for entry in changed_entries {
        check_cancelled(cancellation_requested)?;
        if let Some(source) = entry.source_snapshot.entry {
            candidates
                .entry((entry.source_snapshot.parent, source.identity))
                .or_default()
                .push(SourceCandidate {
                    id: entry.id,
                    path: &entry.source,
                    entry_key: Some(&entry.source_entry_key),
                    changed: true,
                });
        }
    }
    for intent in request
        .iter()
        .filter(|intent| intent.source == intent.destination)
    {
        check_cancelled(cancellation_requested)?;
        match backend.observe(&intent.source) {
            Ok(PathSnapshot {
                parent,
                entry: Some(source),
            }) => {
                candidates
                    .entry((parent, source.identity))
                    .or_default()
                    .push(SourceCandidate {
                        id: intent.id,
                        path: &intent.source,
                        entry_key: None,
                        changed: false,
                    });
            }
            Ok(PathSnapshot { entry: None, .. }) => {}
            Err(error) if is_not_found_error(error) => {}
            Err(error) => issues.push(PlanIssue {
                entry: intent.id,
                kind: PlanIssueKind::BackendFailure(error),
            }),
        }
    }
    if !issues.is_empty() {
        return Ok(());
    }

    let mut duplicates = BTreeSet::new();
    for candidate_group in candidates
        .values()
        .filter(|group| group.len() > 1 && group.iter().any(|candidate| candidate.changed))
    {
        check_cancelled(cancellation_requested)?;
        let mut normalized_owners: BTreeMap<PathKey, Vec<&SourceCandidate<'_>>> = BTreeMap::new();
        for candidate in candidate_group {
            check_cancelled(cancellation_requested)?;
            let key = if let Some(key) = candidate.entry_key {
                Some(key.clone())
            } else {
                match backend.resolve_source(candidate.path) {
                    Ok(source) => source.entry_key().cloned(),
                    Err(error) if is_not_found_error(error) => None,
                    Err(error) => {
                        issues.push(PlanIssue {
                            entry: candidate.id,
                            kind: PlanIssueKind::BackendFailure(error),
                        });
                        None
                    }
                }
            };
            if let Some(key) = key {
                normalized_owners.entry(key).or_default().push(candidate);
            }
        }
        for owners in normalized_owners
            .values()
            .filter(|owners| owners.len() > 1 && owners.iter().any(|owner| owner.changed))
        {
            check_cancelled(cancellation_requested)?;
            duplicates.extend(owners.iter().map(|owner| owner.id));
        }
    }
    for entry in duplicates {
        check_cancelled(cancellation_requested)?;
        issues.push(PlanIssue {
            entry,
            kind: PlanIssueKind::DuplicateSource,
        });
    }
    Ok(())
}

struct DirectoryOverlapInspection<'a, C> {
    backend: &'a dyn RenameBackend,
    directory_owners: &'a BTreeMap<EntryIdentity, Vec<EntryId>>,
    overlap_entries: &'a mut BTreeSet<EntryId>,
    issues: &'a mut Vec<PlanIssue>,
    cancellation_requested: &'a C,
}

impl<C: Fn() -> bool> DirectoryOverlapInspection<'_, C> {
    fn inspect(
        &mut self,
        endpoint: &darknamer_core::LegacyText,
        candidate: EntryId,
        observation: Result<PathSnapshot, super::BackendError>,
        compare_endpoint_entry: bool,
    ) -> Result<(), PlanAttemptError> {
        let endpoint_matches = match observation {
            Ok(snapshot) => {
                let entry_matches = if compare_endpoint_entry
                    && let Some(entry) = snapshot.entry
                    && entry.kind == EntryKind::Directory
                {
                    record_identity_overlap(
                        entry.identity,
                        candidate,
                        true,
                        self.directory_owners,
                        self.overlap_entries,
                    )
                } else {
                    false
                };
                let parent_matches = record_identity_overlap(
                    snapshot.parent,
                    candidate,
                    false,
                    self.directory_owners,
                    self.overlap_entries,
                );
                entry_matches || parent_matches
            }
            Err(error) if is_not_found_error(error) => false,
            Err(error) => {
                self.issues.push(PlanIssue {
                    entry: candidate,
                    kind: PlanIssueKind::BackendFailure(error),
                });
                return Ok(());
            }
        };
        if endpoint_matches {
            return Ok(());
        }

        visit_direct_ancestors(endpoint, self.cancellation_requested, |ancestor| {
            let snapshot = match self.backend.observe(ancestor) {
                Ok(snapshot) => snapshot,
                Err(error) if is_not_found_error(error) => return Ok(false),
                Err(error) => {
                    self.issues.push(PlanIssue {
                        entry: candidate,
                        kind: PlanIssueKind::BackendFailure(error),
                    });
                    return Ok(true);
                }
            };
            let entry_matches = snapshot.entry.is_some_and(|entry| {
                entry.kind == EntryKind::Directory
                    && record_identity_overlap(
                        entry.identity,
                        candidate,
                        false,
                        self.directory_owners,
                        self.overlap_entries,
                    )
            });
            let parent_matches = record_identity_overlap(
                snapshot.parent,
                candidate,
                false,
                self.directory_owners,
                self.overlap_entries,
            );
            Ok(entry_matches || parent_matches)
        })
    }
}

fn record_identity_overlap(
    identity: EntryIdentity,
    candidate: EntryId,
    exclude_candidate: bool,
    directory_owners: &BTreeMap<EntryIdentity, Vec<EntryId>>,
    overlap_entries: &mut BTreeSet<EntryId>,
) -> bool {
    let Some(owners) = directory_owners.get(&identity) else {
        return false;
    };
    if exclude_candidate && owners.iter().all(|owner| *owner == candidate) {
        return false;
    }
    overlap_entries.insert(candidate);
    overlap_entries.extend(owners.iter().copied());
    true
}

const fn is_not_found_error(error: super::BackendError) -> bool {
    matches!(error.code, 2 | 3)
}

fn path_environment_issue(error: super::BackendError) -> PlanIssueKind {
    match error.code {
        50 => PlanIssueKind::UnsupportedCaseSensitiveParent,
        53 => PlanIssueKind::UnsupportedWindowsPath,
        1005 => PlanIssueKind::UnsupportedFilesystem,
        _ => PlanIssueKind::BackendFailure(error),
    }
}

fn visit_direct_ancestors(
    path: &darknamer_core::LegacyText,
    cancellation_requested: &impl Fn() -> bool,
    mut visit: impl FnMut(&darknamer_core::LegacyText) -> Result<bool, PlanAttemptError>,
) -> Result<(), PlanAttemptError> {
    let mut ancestor = path.clone();
    let verbatim = verbatim_drive_root_separator(path.units()).is_some();
    let root_separator = verbatim_drive_root_separator(path.units()).unwrap_or(2);
    for _ in 0..MAX_PLAN_PATH_DEPTH {
        check_cancelled(cancellation_requested)?;
        let Some(separator) = ancestor
            .units()
            .iter()
            .rposition(|unit| is_ancestor_separator(*unit, verbatim))
        else {
            break;
        };
        if separator <= root_separator {
            break;
        }
        ancestor.truncate_units(separator);
        if ancestor.is_empty() {
            break;
        }
        if visit(&ancestor)? {
            break;
        }
    }
    Ok(())
}

fn validate_intent(intent: &RenameIntent, issues: &mut Vec<PlanIssue>) {
    let (source_too_deep, relative_source) = source_path_validation(intent);
    if source_too_deep
        || path_component_depth(intent.destination_parent.units()) > MAX_PLAN_PATH_DEPTH
    {
        issues.push(PlanIssue {
            entry: intent.id,
            kind: PlanIssueKind::PathTooDeep,
        });
    }
    if relative_source {
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

fn validate_source_path(intent: &RenameIntent, issues: &mut Vec<PlanIssue>) {
    let (too_deep, relative) = source_path_validation(intent);
    if too_deep {
        issues.push(PlanIssue {
            entry: intent.id,
            kind: PlanIssueKind::PathTooDeep,
        });
    }
    if relative {
        issues.push(PlanIssue {
            entry: intent.id,
            kind: PlanIssueKind::RelativeSource,
        });
    }
}

fn source_path_validation(intent: &RenameIntent) -> (bool, bool) {
    (
        path_component_depth(intent.source.units()) > MAX_PLAN_PATH_DEPTH,
        !is_absolute_windows_path(intent.source.units()),
    )
}

fn path_component_depth(units: &[u16]) -> usize {
    let (start, verbatim) = if let Some(root) = verbatim_drive_root_separator(units) {
        (root + 1, true)
    } else if units.len() >= 3 && units[1] == b':' as u16 && is_separator(units[2]) {
        (3, false)
    } else {
        (0, false)
    };
    let mut depth = 0;
    let mut in_component = false;
    for unit in &units[start..] {
        if is_ancestor_separator(*unit, verbatim) {
            in_component = false;
        } else if !in_component {
            depth += 1;
            in_component = true;
        }
    }
    depth
}

fn verbatim_drive_root_separator(units: &[u16]) -> Option<usize> {
    (units.len() >= 7
        && units[0] == b'\\' as u16
        && units[1] == b'\\' as u16
        && units[2] == b'?' as u16
        && units[3] == b'\\' as u16
        && ((b'A' as u16..=b'Z' as u16).contains(&units[4])
            || (b'a' as u16..=b'z' as u16).contains(&units[4]))
        && units[5] == b':' as u16
        && units[6] == b'\\' as u16)
        .then_some(6)
}

fn is_ancestor_separator(unit: u16, verbatim: bool) -> bool {
    unit == b'\\' as u16 || (!verbatim && unit == b'/' as u16)
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
    hash_value(&mut hash, request.scope as u64);
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
