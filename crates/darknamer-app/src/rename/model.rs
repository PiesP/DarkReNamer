use std::fmt;

use darknamer_core::{LegacyText, WindowsLeafNameError};

use super::ports::BackendError;

/// A row identifier scoped to one plan request.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct EntryId(u32);

impl EntryId {
    /// Creates a row identifier.
    #[must_use]
    pub const fn new(value: u32) -> Self {
        Self(value)
    }

    /// Returns the zero-based legacy-list row represented by this plan ID.
    #[must_use]
    pub const fn row_index(self) -> u32 {
        self.0
    }

    pub(super) const fn value(self) -> u32 {
        self.0
    }
}

/// Revision of the mutable list model used to build a plan.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ModelRevision(u64);

impl ModelRevision {
    /// Creates a model revision.
    #[must_use]
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    pub(super) const fn value(self) -> u64 {
        self.0
    }
}

/// Deterministic display fingerprint for an immutable plan.
///
/// Transaction uniqueness is supplied independently by the execution backend.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PlanId(u64);

impl PlanId {
    /// Reconstructs a display fingerprint from a trusted journal codec.
    #[must_use]
    pub const fn from_fingerprint(value: u64) -> Self {
        Self(value)
    }

    pub(super) const fn new(value: u64) -> Self {
        Self(value)
    }

    pub(super) const fn value(self) -> u64 {
        self.0
    }

    /// Returns the deterministic plan fingerprint shown during confirmation.
    #[must_use]
    pub const fn fingerprint(self) -> u64 {
        self.0
    }
}

/// The filesystem kind of a planned source.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EntryKind {
    /// A regular file.
    File,
    /// A directory.
    Directory,
}

/// Filesystem movement boundary explicitly authorized for one immutable plan.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum MoveScope {
    /// Only rename entries within their already observed direct parent.
    #[default]
    SameParent,
    /// Allow regular files to move between parents on the same volume.
    SameVolumeFilesOnly,
}

/// Stable filesystem identity used to detect replacement and movement.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct EntryIdentity {
    volume: u64,
    file_id: u128,
}

impl EntryIdentity {
    /// Creates a stable identity from backend-owned values.
    #[must_use]
    pub const fn new(volume: u64, file_id: u128) -> Self {
        Self { volume, file_id }
    }

    /// Returns the containing volume identifier.
    #[must_use]
    pub const fn volume(self) -> u64 {
        self.volume
    }

    /// Returns the backend-owned file identifier.
    #[must_use]
    pub const fn file_id(self) -> u128 {
        self.file_id
    }
}

/// Backend-specific comparison key for a complete path.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct PathKey(pub(super) Box<[u16]>);

impl PathKey {
    /// Creates an exact key. Backends should fold case where the filesystem does.
    #[must_use]
    pub fn exact(path: &LegacyText) -> Self {
        Self(path.units().into())
    }
}

/// One filesystem entry observed during planning or execution freeze.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ObservedEntry {
    /// Stable identity of the entry.
    pub identity: EntryIdentity,
    /// Observed filesystem kind.
    pub kind: EntryKind,
    /// Whether the final entry is a reparse point.
    pub is_reparse_point: bool,
}

/// One path observation bound to its parent identity.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PathSnapshot {
    /// Stable identity of the resolved direct parent.
    pub parent: EntryIdentity,
    /// Entry at the path, or `None` when the leaf is unoccupied.
    pub entry: Option<ObservedEntry>,
}

/// One source-to-destination intent derived from legacy list state.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenameIntent {
    pub(super) id: EntryId,
    pub(super) source: LegacyText,
    pub(super) destination_parent: LegacyText,
    pub(super) destination_name: LegacyText,
    pub(super) destination: LegacyText,
    pub(super) kind: EntryKind,
}

impl RenameIntent {
    /// Creates a rename intent without changing either exact UTF-16 path.
    #[must_use]
    pub fn new(
        id: EntryId,
        source: impl Into<LegacyText>,
        destination_parent: impl Into<LegacyText>,
        destination_name: impl Into<LegacyText>,
        kind: EntryKind,
    ) -> Self {
        let destination_parent = destination_parent.into();
        let destination_name = destination_name.into();
        let mut destination_units =
            Vec::with_capacity(destination_parent.len() + 1 + destination_name.len());
        destination_units.extend_from_slice(destination_parent.units());
        if !destination_parent
            .units()
            .last()
            .is_some_and(|unit| *unit == b'\\' as u16 || *unit == b'/' as u16)
        {
            destination_units.push(b'\\' as u16);
        }
        destination_units.extend_from_slice(destination_name.units());
        Self {
            id,
            source: source.into(),
            destination_parent,
            destination_name,
            destination: LegacyText::from_units(destination_units),
            kind,
        }
    }
}

/// Complete list state submitted for planning.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanRequest {
    pub(super) revision: ModelRevision,
    pub(super) entries: Box<[RenameIntent]>,
    pub(super) scope: MoveScope,
}

impl PlanRequest {
    /// Creates a plan request from the current list revision and intents.
    #[must_use]
    pub fn new(revision: ModelRevision, entries: Vec<RenameIntent>) -> Self {
        Self {
            revision,
            entries: entries.into_boxed_slice(),
            scope: MoveScope::SameParent,
        }
    }

    /// Creates a plan request with an explicit filesystem movement boundary.
    #[must_use]
    pub fn with_scope(
        revision: ModelRevision,
        entries: Vec<RenameIntent>,
        scope: MoveScope,
    ) -> Self {
        Self {
            revision,
            entries: entries.into_boxed_slice(),
            scope,
        }
    }

    /// Returns the explicitly authorized filesystem movement boundary.
    #[must_use]
    pub const fn scope(&self) -> MoveScope {
        self.scope
    }
}

/// A typed reason a plan cannot safely execute.
#[derive(Clone, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum PlanIssueKind {
    /// The source is not an absolute Windows path.
    RelativeSource,
    /// The destination parent is not an absolute Windows path.
    RelativeDestinationParent,
    /// The destination leaf is invalid on Windows.
    InvalidDestinationName(WindowsLeafNameError),
    /// The source no longer exists.
    MissingSource,
    /// The observed source kind differs from the request.
    SourceKindChanged,
    /// The source itself is a reparse point.
    ReparseSource,
    /// Multiple entries target the same filesystem key.
    DuplicateDestination,
    /// Multiple intents use the same plan-scoped entry identifier.
    DuplicateEntryId,
    /// Multiple intents refer to the same source path key.
    DuplicateSource,
    /// Source and destination resolve under different direct parents.
    CrossParent,
    /// Source and destination parents are on different volumes.
    CrossVolume,
    /// Cross-parent directory moves are outside the authorized file-only scope.
    DirectoryMoveUnsupported,
    /// Selected sources have an ancestor/descendant relationship.
    SourceOverlap,
    /// A source or destination parent exceeds the planner's bounded path depth.
    PathTooDeep,
    /// A parent uses per-directory case-sensitive lookup unsupported by safe v1.
    UnsupportedCaseSensitiveParent,
    /// A Windows path class such as UNC/SMB is unsupported by safe v1.
    UnsupportedWindowsPath,
    /// The parent volume is not the NTFS filesystem required by safe v1.
    UnsupportedFilesystem,
    /// A destination is occupied by an entry outside this plan.
    DestinationOccupied,
    /// A required backend observation failed.
    Backend,
    /// A backend observation failed with retained operation and native code.
    BackendFailure(BackendError),
}

/// One entry-scoped planning blocker.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanIssue {
    /// Entry associated with the blocker.
    pub entry: EntryId,
    /// Structured blocker kind.
    pub kind: PlanIssueKind,
}

/// Planning failed without mutating the backend.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanError {
    issues: Box<[PlanIssue]>,
}

impl PlanError {
    pub(super) fn new(issues: Vec<PlanIssue>) -> Self {
        Self {
            issues: issues.into_boxed_slice(),
        }
    }

    /// Returns every detected planning blocker.
    #[must_use]
    pub fn issues(&self) -> &[PlanIssue] {
        &self.issues
    }
}

impl fmt::Display for PlanError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "rename plan has {} blocker(s)",
            self.issues.len()
        )
    }
}

impl std::error::Error for PlanError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanRow {
    pub(super) id: EntryId,
    pub(super) source: LegacyText,
    pub(super) destination: LegacyText,
    pub(super) kind: EntryKind,
    pub(super) source_snapshot: PathSnapshot,
    pub(super) destination_snapshot: PathSnapshot,
}

impl PlanRow {
    /// Returns the plan-scoped stable entry identifier.
    #[must_use]
    pub const fn entry(&self) -> EntryId {
        self.id
    }

    /// Returns the exact source path submitted for planning.
    #[must_use]
    pub const fn source(&self) -> &LegacyText {
        &self.source
    }

    /// Returns the exact validated destination path.
    #[must_use]
    pub const fn destination(&self) -> &LegacyText {
        &self.destination
    }

    /// Returns the planned filesystem kind.
    #[must_use]
    pub const fn kind(&self) -> EntryKind {
        self.kind
    }
}

/// Immutable, validated rename plan.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenamePlan {
    pub(super) id: PlanId,
    pub(super) revision: ModelRevision,
    pub(super) entries: Box<[PlanRow]>,
    pub(super) scope: MoveScope,
}

impl RenamePlan {
    /// Returns the opaque plan identity.
    #[must_use]
    pub const fn id(&self) -> PlanId {
        self.id
    }

    /// Returns the deterministic display fingerprint for confirmation UI.
    #[must_use]
    pub const fn fingerprint(&self) -> u64 {
        self.id.fingerprint()
    }

    /// Returns the list revision captured by the plan.
    #[must_use]
    pub const fn revision(&self) -> ModelRevision {
        self.revision
    }

    /// Returns the filesystem movement boundary frozen into this plan.
    #[must_use]
    pub const fn scope(&self) -> MoveScope {
        self.scope
    }

    /// Returns the number of logical renames.
    #[must_use]
    pub fn changed_count(&self) -> usize {
        self.entries.len()
    }

    /// Returns whether the plan contains no filesystem mutations.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Returns safe preview rows without exposing execution snapshots or schedule internals.
    #[must_use]
    pub fn rows(&self) -> &[PlanRow] {
        &self.entries
    }

    /// Consumes this exact plan after the caller confirms its displayed identity.
    ///
    /// # Errors
    ///
    /// Returns an error when either displayed value does not match this plan.
    pub fn confirm_presented(
        self,
        displayed_id: PlanId,
        displayed_revision: ModelRevision,
    ) -> Result<ConfirmedPlan, ConfirmationError> {
        if self.id != displayed_id {
            return Err(ConfirmationError::PlanMismatch);
        }
        if self.revision != displayed_revision {
            return Err(ConfirmationError::RevisionMismatch);
        }
        Ok(ConfirmedPlan { plan: self })
    }
}

/// A one-shot ownership token for the exact plan shown to the caller.
#[derive(Debug, Eq, PartialEq)]
pub struct ConfirmedPlan {
    pub(super) plan: RenamePlan,
}

/// Confirmation did not refer to the exact immutable plan.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfirmationError {
    /// The displayed plan identifier differs.
    PlanMismatch,
    /// The displayed model revision differs.
    RevisionMismatch,
}

impl fmt::Display for ConfirmationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PlanMismatch => formatter.write_str("confirmed plan identifier does not match"),
            Self::RevisionMismatch => {
                formatter.write_str("confirmed model revision does not match")
            }
        }
    }
}

impl std::error::Error for ConfirmationError {}
