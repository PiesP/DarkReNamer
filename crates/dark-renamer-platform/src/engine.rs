use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use dark_renamer_core::{PlanningRequest, RenameRule, plan};

use crate::filesystem::{
    FileIdentity, FileSystem, Fingerprint, LocalFileSystem, MoveFailureKind,
    has_duplicate_identities, validate_admitted_file,
};
use crate::journal::{
    CompletedTransaction, JournalHeader, JournalItem, JournalStore, TransactionJournal,
};
use crate::{
    AdmissionRejection, Generation, MAX_SOURCES, PlanId, PlatformError, Preview, SourceId,
    TransactionId, TransactionKind, TransactionSummary, validate_persisted_path,
};

#[derive(Clone, Debug)]
struct AdmittedSource {
    id: SourceId,
    path: PathBuf,
    fingerprint: Fingerprint,
    parent: PathBuf,
    parent_fingerprint: Fingerprint,
}

#[derive(Clone, Debug)]
struct FrozenItem {
    source: AdmittedSource,
    target: PathBuf,
    destination: Option<Fingerprint>,
}

#[derive(Clone, Debug)]
struct FrozenPlan {
    id: PlanId,
    generation: Generation,
    preview: Preview,
    changed: Box<[FrozenItem]>,
}

#[derive(Clone, Debug)]
struct ScheduledMove {
    from: PathBuf,
    to: PathBuf,
    identity: FileIdentity,
}

#[derive(Debug)]
struct Engine<F> {
    filesystem: F,
    journals: JournalStore,
    admitted: Box<[AdmittedSource]>,
    generation: Generation,
    next_source_id: u64,
    next_plan_id: u64,
    next_transaction_id: u64,
    current_plan: Option<FrozenPlan>,
    latest: Option<CompletedTransaction>,
    recovery_required: bool,
}

/// Deep platform module for safe regular-file preview, apply, and undo.
#[derive(Debug)]
pub struct RenameEngine {
    inner: Engine<LocalFileSystem>,
}

impl RenameEngine {
    /// Constructs an engine with a backend-owned durable journal root.
    ///
    /// Existing incomplete, torn, oversized, or corrupt journals put the
    /// engine into recovery-required state instead of being ignored.
    ///
    /// # Errors
    ///
    /// Returns an error if the journal root cannot be created, is a symlink,
    /// or cannot be scanned.
    pub fn new(journal_root: impl AsRef<Path>) -> Result<Self, PlatformError> {
        Ok(Self {
            inner: Engine::new(journal_root.as_ref(), LocalFileSystem)?,
        })
    }

    /// Replaces admission with ordered regular, non-symlink files.
    ///
    /// # Errors
    ///
    /// Rejects missing paths, directories, symlinks, duplicate identities,
    /// non-Unicode paths, oversized batches, and invalid parents.
    pub fn admit(
        &mut self,
        paths: impl IntoIterator<Item = PathBuf>,
    ) -> Result<Box<[SourceId]>, PlatformError> {
        self.inner.admit(paths)
    }

    /// Produces a deterministic preview from ordered core rules.
    ///
    /// Sibling occupancy and every proposed destination are frozen internally;
    /// the returned core plan is display-only and carries no execution authority.
    ///
    /// # Errors
    ///
    /// Returns an error when no sources are admitted or filesystem inspection
    /// fails.
    pub fn preview(&mut self, rules: &[RenameRule]) -> Result<Preview, PlatformError> {
        self.inner.preview(rules)
    }

    /// Applies only the current engine-owned plan after exact-count confirmation.
    ///
    /// # Errors
    ///
    /// Fails closed for stale sources, parents, or destinations, blocked plans,
    /// confirmation mismatch, unsupported targets, I/O failure, or recovery state.
    pub fn apply_confirmed(
        &mut self,
        plan_id: PlanId,
        exact_changed_count: usize,
    ) -> Result<TransactionId, PlatformError> {
        self.inner.apply_confirmed(plan_id, exact_changed_count)
    }

    /// Returns a path-free summary of the latest completed transaction.
    ///
    /// # Errors
    ///
    /// Returns [`PlatformError::NoCompletedTransaction`] if none exists.
    pub fn latest_transaction(&self) -> Result<TransactionSummary, PlatformError> {
        self.inner.latest_transaction()
    }

    /// Revalidates and reverses the latest apply as a new journaled transaction.
    ///
    /// # Errors
    ///
    /// Fails if the latest transaction is absent or already an undo, an original
    /// destination is occupied unexpectedly, a final identity changed, or the
    /// engine requires recovery.
    pub fn undo_latest(&mut self) -> Result<TransactionId, PlatformError> {
        self.inner.undo_latest()
    }

    /// Reports whether explicit recovery is required before any mutation.
    #[must_use]
    pub const fn recovery_required(&self) -> bool {
        self.inner.recovery_required
    }
}

impl<F: FileSystem> Engine<F> {
    fn new(journal_root: &Path, filesystem: F) -> Result<Self, PlatformError> {
        let (journals, scan) = JournalStore::open(journal_root)?;
        Ok(Self {
            filesystem,
            journals,
            admitted: Box::default(),
            generation: Generation(0),
            next_source_id: 1,
            next_plan_id: 1,
            next_transaction_id: scan.maximum_transaction_id.saturating_add(1),
            current_plan: None,
            latest: scan.latest,
            recovery_required: scan.recovery_required,
        })
    }

    fn admit(
        &mut self,
        paths: impl IntoIterator<Item = PathBuf>,
    ) -> Result<Box<[SourceId]>, PlatformError> {
        let paths: Vec<PathBuf> = paths.into_iter().collect();
        if paths.is_empty() {
            return Err(PlatformError::NoSources);
        }
        if paths.len() > MAX_SOURCES {
            return Err(PlatformError::BoundExceeded {
                field: "source count",
                maximum: MAX_SOURCES,
            });
        }

        let mut admitted = Vec::with_capacity(paths.len());
        for path in paths {
            let parent = path
                .parent()
                .ok_or_else(|| PlatformError::AdmissionRejected {
                    path: path.clone(),
                    reason: AdmissionRejection::MissingParent,
                })?
                .to_path_buf();
            let (fingerprint, parent_fingerprint) = validate_admitted_file(
                &path,
                self.filesystem.fingerprint(&path)?,
                self.filesystem.fingerprint(&parent)?,
            )?;
            let id = SourceId(self.next_source_id);
            self.next_source_id = self.next_source_id.saturating_add(1);
            admitted.push(AdmittedSource {
                id,
                path,
                fingerprint,
                parent,
                parent_fingerprint,
            });
        }
        if has_duplicate_identities(admitted.iter().map(|source| source.fingerprint)) {
            let path = admitted
                .last()
                .map_or_else(PathBuf::new, |source| source.path.clone());
            return Err(PlatformError::AdmissionRejected {
                path,
                reason: AdmissionRejection::DuplicateIdentity,
            });
        }

        self.generation = Generation(self.generation.0.saturating_add(1));
        self.current_plan = None;
        let ids = admitted.iter().map(|source| source.id).collect();
        self.admitted = admitted.into();
        Ok(ids)
    }

    fn preview(&mut self, rules: &[RenameRule]) -> Result<Preview, PlatformError> {
        if self.admitted.is_empty() {
            return Err(PlatformError::NoSources);
        }
        let mut occupied = Vec::new();
        let mut parents = BTreeSet::new();
        for source in &self.admitted {
            if parents.insert(source.parent.clone()) {
                occupied.extend(self.filesystem.siblings(&source.parent)?);
            }
        }
        let request = PlanningRequest::new(self.admitted.iter().map(|source| source.path.clone()))
            .with_rules(rules.iter().cloned())
            .with_occupied_paths(occupied);
        let core_plan = plan(&request);
        let mut changed = Vec::with_capacity(core_plan.changed_count());
        for row in core_plan.rows().iter().filter(|row| row.is_changed()) {
            validate_persisted_path(row.target_path())?;
            if row.proposed_name().len() > 255 {
                return Err(PlatformError::BoundExceeded {
                    field: "filename",
                    maximum: 255,
                });
            }
            let source = self
                .admitted
                .get(row.index())
                .ok_or(PlatformError::StalePlan)?
                .clone();
            changed.push(FrozenItem {
                source,
                target: row.target_path().to_path_buf(),
                destination: self.filesystem.fingerprint(row.target_path())?,
            });
        }
        let id = PlanId(self.next_plan_id);
        self.next_plan_id = self.next_plan_id.saturating_add(1);
        let preview = Preview {
            id,
            generation: self.generation,
            source_ids: self.admitted.iter().map(|source| source.id).collect(),
            plan: core_plan,
        };
        self.current_plan = Some(FrozenPlan {
            id,
            generation: self.generation,
            preview: preview.clone(),
            changed: changed.into(),
        });
        Ok(preview)
    }

    fn apply_confirmed(
        &mut self,
        plan_id: PlanId,
        exact_changed_count: usize,
    ) -> Result<TransactionId, PlatformError> {
        self.ensure_mutation_available()?;
        let frozen = self.current_plan.clone().ok_or(PlatformError::StalePlan)?;
        if frozen.id != plan_id || frozen.generation != self.generation {
            return Err(PlatformError::StalePlan);
        }
        if !frozen.preview.plan.can_apply() {
            return Err(PlatformError::PlanNotApplicable);
        }
        let expected = frozen.preview.plan.changed_count();
        if exact_changed_count != expected {
            return Err(PlatformError::ConfirmationMismatch {
                expected,
                actual: exact_changed_count,
            });
        }
        self.revalidate_frozen(&frozen.changed)?;
        let id =
            self.execute_transaction(TransactionKind::Apply, frozen.generation, &frozen.changed)?;
        self.current_plan = None;
        Ok(id)
    }

    fn latest_transaction(&self) -> Result<TransactionSummary, PlatformError> {
        let latest = self
            .latest
            .as_ref()
            .ok_or(PlatformError::NoCompletedTransaction)?;
        Ok(TransactionSummary {
            id: latest.header.transaction_id,
            kind: latest.header.kind,
            changed_count: latest.header.items.len(),
        })
    }

    fn undo_latest(&mut self) -> Result<TransactionId, PlatformError> {
        self.ensure_mutation_available()?;
        let latest = self
            .latest
            .clone()
            .ok_or(PlatformError::NoCompletedTransaction)?;
        if latest.header.kind != TransactionKind::Apply {
            return Err(PlatformError::LatestTransactionNotUndoable);
        }

        let mut final_occupants = BTreeMap::new();
        for item in &latest.header.items {
            final_occupants.insert(item.final_path.clone(), item.fingerprint);
        }
        let mut changed = Vec::with_capacity(latest.header.items.len());
        for item in &latest.header.items {
            let final_fingerprint = self.filesystem.fingerprint(&item.final_path)?;
            if final_fingerprint != Some(item.fingerprint) {
                return Err(PlatformError::StaleSource {
                    source_id: item.source_id,
                });
            }
            let parent = item.final_path.parent().ok_or(PlatformError::StaleParent {
                source_id: item.source_id,
            })?;
            if !same_identity(
                self.filesystem.fingerprint(parent)?,
                item.parent_fingerprint,
            ) {
                return Err(PlatformError::StaleParent {
                    source_id: item.source_id,
                });
            }
            let expected_destination = final_occupants.get(&item.original).copied();
            if self.filesystem.fingerprint(&item.original)? != expected_destination {
                return Err(PlatformError::DestinationChanged {
                    path: item.original.clone(),
                });
            }
            changed.push(FrozenItem {
                source: AdmittedSource {
                    id: item.source_id,
                    path: item.final_path.clone(),
                    fingerprint: item.fingerprint,
                    parent: parent.to_path_buf(),
                    parent_fingerprint: item.parent_fingerprint,
                },
                target: item.original.clone(),
                destination: expected_destination,
            });
        }
        self.execute_transaction(TransactionKind::Undo, self.generation, &changed)
    }

    fn ensure_mutation_available(&self) -> Result<(), PlatformError> {
        if self.recovery_required {
            return Err(PlatformError::RecoveryRequired);
        }
        #[cfg(windows)]
        {
            Err(PlatformError::Unsupported {
                operation: "handle-atomic no-replace rename on Windows",
            })
        }
        #[cfg(not(windows))]
        Ok(())
    }

    fn revalidate_frozen(&self, changed: &[FrozenItem]) -> Result<(), PlatformError> {
        for item in changed {
            if self.filesystem.fingerprint(&item.source.path)? != Some(item.source.fingerprint) {
                return Err(PlatformError::StaleSource {
                    source_id: item.source.id,
                });
            }
            if !same_identity(
                self.filesystem.fingerprint(&item.source.parent)?,
                item.source.parent_fingerprint,
            ) {
                return Err(PlatformError::StaleParent {
                    source_id: item.source.id,
                });
            }
            if self.filesystem.fingerprint(&item.target)? != item.destination {
                return Err(PlatformError::DestinationChanged {
                    path: item.target.clone(),
                });
            }
        }
        Ok(())
    }

    fn execute_transaction(
        &mut self,
        kind: TransactionKind,
        generation: Generation,
        changed: &[FrozenItem],
    ) -> Result<TransactionId, PlatformError> {
        let transaction_id = TransactionId(self.next_transaction_id);
        self.next_transaction_id = self.next_transaction_id.saturating_add(1);
        let header = JournalHeader {
            transaction_id,
            kind,
            generation,
            items: changed
                .iter()
                .map(|item| JournalItem {
                    source_id: item.source.id,
                    original: item.source.path.clone(),
                    final_path: item.target.clone(),
                    fingerprint: item.source.fingerprint,
                    parent_fingerprint: item.source.parent_fingerprint,
                })
                .collect(),
        };
        let temporary = self.temporary_paths(transaction_id, changed)?;
        let mut schedule = Vec::with_capacity(changed.len() * 2);
        schedule.extend(
            changed
                .iter()
                .zip(&temporary)
                .map(|(item, temporary)| ScheduledMove {
                    from: item.source.path.clone(),
                    to: temporary.clone(),
                    identity: item.source.fingerprint.identity,
                }),
        );
        schedule.extend(
            changed
                .iter()
                .zip(&temporary)
                .map(|(item, temporary)| ScheduledMove {
                    from: temporary.clone(),
                    to: item.target.clone(),
                    identity: item.source.fingerprint.identity,
                }),
        );

        let mut journal = match self.journals.create(&header) {
            Ok(journal) => journal,
            Err(_error) => {
                // Creation may have persisted the magic or a partial header.
                // Treat its outcome as ambiguous until an operator inspects it.
                self.recovery_required = true;
                return Err(PlatformError::RecoveryRequired);
            }
        };
        let mut completed = Vec::with_capacity(schedule.len());
        for scheduled in schedule {
            let ordinal =
                u32::try_from(completed.len()).map_err(|_error| PlatformError::BoundExceeded {
                    field: "journal move count",
                    maximum: MAX_SOURCES * 4,
                })?;
            if journal
                .intent(ordinal, &scheduled.from, &scheduled.to, scheduled.identity)
                .is_err()
            {
                self.recovery_required = true;
                return Err(PlatformError::RecoveryRequired);
            }
            match self.filesystem.move_no_replace(
                &scheduled.from,
                &scheduled.to,
                scheduled.identity,
            ) {
                Ok(()) => {
                    completed.push(scheduled);
                    if journal.complete(ordinal).is_err() {
                        self.recovery_required = true;
                        return Err(PlatformError::RecoveryRequired);
                    }
                }
                Err(failure) if failure.kind == MoveFailureKind::Ambiguous => {
                    self.recovery_required = true;
                    return Err(PlatformError::RecoveryRequired);
                }
                Err(failure) => {
                    if journal.failed(ordinal).is_err() {
                        self.recovery_required = true;
                        return Err(PlatformError::RecoveryRequired);
                    }
                    return self.rollback_failure(&mut journal, completed, failure.operation);
                }
            }
        }
        if journal.commit().is_err() {
            self.recovery_required = true;
            return Err(PlatformError::RecoveryRequired);
        }
        self.latest = Some(CompletedTransaction { header });
        Ok(transaction_id)
    }

    fn temporary_paths(
        &self,
        transaction_id: TransactionId,
        changed: &[FrozenItem],
    ) -> Result<Vec<PathBuf>, PlatformError> {
        let mut paths = Vec::with_capacity(changed.len());
        for (index, item) in changed.iter().enumerate() {
            let name = format!(".dark-renamer-{:016x}-{index:04x}.tmp", transaction_id.0);
            let path = item.source.parent.join(name);
            validate_persisted_path(&path)?;
            if self.filesystem.fingerprint(&path)?.is_some() {
                return Err(PlatformError::DestinationChanged { path });
            }
            paths.push(path);
        }
        Ok(paths)
    }

    fn rollback_failure(
        &mut self,
        journal: &mut TransactionJournal,
        completed: Vec<ScheduledMove>,
        operation: &'static str,
    ) -> Result<TransactionId, PlatformError> {
        let mut ordinal = u32::try_from(completed.len()).unwrap_or(u32::MAX);
        for move_to_reverse in completed.iter().rev() {
            ordinal = ordinal.saturating_add(1);
            if journal
                .intent(
                    ordinal,
                    &move_to_reverse.to,
                    &move_to_reverse.from,
                    move_to_reverse.identity,
                )
                .is_err()
            {
                self.recovery_required = true;
                return Err(PlatformError::RecoveryRequired);
            }
            if self
                .filesystem
                .move_no_replace(
                    &move_to_reverse.to,
                    &move_to_reverse.from,
                    move_to_reverse.identity,
                )
                .is_err()
                || journal.complete(ordinal).is_err()
            {
                self.recovery_required = true;
                return Err(PlatformError::RecoveryRequired);
            }
        }
        if journal.abort().is_err() {
            self.recovery_required = true;
            return Err(PlatformError::RecoveryRequired);
        }
        Err(PlatformError::ExecutionFailed {
            rolled_back: true,
            operation,
        })
    }
}

fn same_identity(actual: Option<Fingerprint>, expected: Fingerprint) -> bool {
    actual
        .is_some_and(|actual| actual.identity == expected.identity && actual.kind == expected.kind)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::rc::Rc;
    use std::sync::atomic::{AtomicU64, Ordering};

    use dark_renamer_core::RenameRule;

    use super::*;
    use crate::filesystem::{EntryKind, MoveFailure};
    use crate::journal::journal_has_pending_intent;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new() -> Result<Self, std::io::Error> {
            let id = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir()
                .join(format!("dark-renamer-platform-{}-{id}", std::process::id()));
            fs::create_dir_all(&root)?;
            Ok(Self { root })
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[derive(Clone, Copy, Debug)]
    enum InjectedFailure {
        DefiniteBefore(usize),
        AmbiguousAfter(usize),
        DestinationRace(usize),
    }

    #[derive(Debug)]
    struct MemoryState {
        entries: BTreeMap<PathBuf, Fingerprint>,
        next_identity: u64,
        move_calls: usize,
        failure: Option<InjectedFailure>,
        journal_root: PathBuf,
        every_move_had_intent: bool,
    }

    impl MemoryState {
        fn new(journal_root: PathBuf) -> Self {
            let mut state = Self {
                entries: BTreeMap::new(),
                next_identity: 1,
                move_calls: 0,
                failure: None,
                journal_root,
                every_move_had_intent: true,
            };
            state.insert(Path::new("/work"), EntryKind::Directory);
            state
        }

        fn insert(&mut self, path: &Path, kind: EntryKind) -> Fingerprint {
            let fingerprint = Fingerprint {
                identity: FileIdentity {
                    volume: 1,
                    file: self.next_identity,
                },
                kind,
                length: 10,
                modified_nanos: 20,
            };
            self.next_identity = self.next_identity.saturating_add(1);
            self.entries.insert(path.to_path_buf(), fingerprint);
            fingerprint
        }

        fn latest_journal_has_intent(&self) -> bool {
            let Ok(entries) = fs::read_dir(&self.journal_root) else {
                return false;
            };
            let mut paths: Vec<PathBuf> = entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|value| value == "drj"))
                .collect();
            paths.sort();
            paths
                .last()
                .is_some_and(|path| journal_has_pending_intent(path))
        }
    }

    #[derive(Clone, Debug)]
    struct MemoryFileSystem {
        state: Rc<RefCell<MemoryState>>,
    }

    impl FileSystem for MemoryFileSystem {
        fn fingerprint(&self, path: &Path) -> Result<Option<Fingerprint>, PlatformError> {
            Ok(self.state.borrow().entries.get(path).copied())
        }

        fn siblings(&self, parent: &Path) -> Result<Vec<PathBuf>, PlatformError> {
            Ok(self
                .state
                .borrow()
                .entries
                .keys()
                .filter(|path| path.parent() == Some(parent))
                .cloned()
                .collect())
        }

        fn move_no_replace(
            &mut self,
            from: &Path,
            to: &Path,
            expected: FileIdentity,
        ) -> Result<(), MoveFailure> {
            let mut state = self.state.borrow_mut();
            state.move_calls = state.move_calls.saturating_add(1);
            let call = state.move_calls;
            if !state.latest_journal_has_intent() {
                state.every_move_had_intent = false;
            }
            if matches!(state.failure, Some(InjectedFailure::DefiniteBefore(at)) if at == call) {
                return Err(MoveFailure {
                    kind: MoveFailureKind::Definite,
                    operation: "injected definite failure",
                });
            }
            if matches!(state.failure, Some(InjectedFailure::DestinationRace(at)) if at == call) {
                state.insert(to, EntryKind::RegularFile);
            }
            if state.entries.contains_key(to) {
                return Err(MoveFailure {
                    kind: MoveFailureKind::Definite,
                    operation: "destination occupied",
                });
            }
            let Some(fingerprint) = state.entries.get(from).copied() else {
                return Err(MoveFailure {
                    kind: MoveFailureKind::Definite,
                    operation: "source missing",
                });
            };
            if fingerprint.identity != expected {
                return Err(MoveFailure {
                    kind: MoveFailureKind::Definite,
                    operation: "source identity changed",
                });
            }
            state.entries.remove(from);
            state.entries.insert(to.to_path_buf(), fingerprint);
            if matches!(state.failure, Some(InjectedFailure::AmbiguousAfter(at)) if at == call) {
                return Err(MoveFailure {
                    kind: MoveFailureKind::Ambiguous,
                    operation: "injected ambiguous failure",
                });
            }
            Ok(())
        }
    }

    fn memory_engine(
        fixture: &Fixture,
        names: &[&str],
    ) -> Result<(Engine<MemoryFileSystem>, Rc<RefCell<MemoryState>>), PlatformError> {
        let state = Rc::new(RefCell::new(MemoryState::new(fixture.root.clone())));
        for name in names {
            state
                .borrow_mut()
                .insert(&Path::new("/work").join(name), EntryKind::RegularFile);
        }
        let filesystem = MemoryFileSystem {
            state: Rc::clone(&state),
        };
        Ok((Engine::new(&fixture.root, filesystem)?, state))
    }

    fn replace(from: &str, to: &str) -> RenameRule {
        RenameRule::LiteralReplace {
            from: from.into(),
            to: to.into(),
        }
    }

    #[test]
    fn stale_source_and_destination_race_fail_before_journaling() -> Result<(), PlatformError> {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, state) = memory_engine(&fixture, &["a.txt"])?;
        engine.admit([PathBuf::from("/work/a.txt")])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        if let Some(source) = state.borrow_mut().entries.get_mut(Path::new("/work/a.txt")) {
            source.length = source.length.saturating_add(1);
        }
        assert!(matches!(
            engine.apply_confirmed(preview.id(), 1),
            Err(PlatformError::StaleSource { .. })
        ));
        assert_eq!(fs::read_dir(&fixture.root).map_or(0, Iterator::count), 0);

        let (mut engine, state) = memory_engine(&fixture, &["b.txt"])?;
        engine.admit([PathBuf::from("/work/b.txt")])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        state
            .borrow_mut()
            .insert(Path::new("/work/new-b.txt"), EntryKind::RegularFile);
        assert!(matches!(
            engine.apply_confirmed(preview.id(), 1),
            Err(PlatformError::DestinationChanged { .. })
        ));
        assert_eq!(fs::read_dir(&fixture.root).map_or(0, Iterator::count), 0);

        let (mut engine, state) = memory_engine(&fixture, &["c.txt"])?;
        engine.admit([PathBuf::from("/work/c.txt")])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        if let Some(parent) = state.borrow_mut().entries.get_mut(Path::new("/work")) {
            parent.identity.file = parent.identity.file.saturating_add(10_000);
        }
        assert!(matches!(
            engine.apply_confirmed(preview.id(), 1),
            Err(PlatformError::StaleParent { .. })
        ));
        Ok(())
    }

    #[test]
    fn destination_race_after_journaling_never_overwrites() -> Result<(), PlatformError> {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, state) = memory_engine(&fixture, &["a.txt"])?;
        engine.admit([PathBuf::from("/work/a.txt")])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        state.borrow_mut().failure = Some(InjectedFailure::DestinationRace(2));
        assert!(matches!(
            engine.apply_confirmed(preview.id(), 1),
            Err(PlatformError::ExecutionFailed {
                rolled_back: true,
                ..
            })
        ));
        let state = state.borrow();
        assert!(state.entries.contains_key(Path::new("/work/a.txt")));
        assert!(state.entries.contains_key(Path::new("/work/new-a.txt")));
        assert_eq!(state.entries.len(), 3);
        Ok(())
    }

    #[test]
    fn exact_confirmation_and_current_plan_are_required() -> Result<(), PlatformError> {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, _state) = memory_engine(&fixture, &["a.txt"])?;
        engine.admit([PathBuf::from("/work/a.txt")])?;
        let first = engine.preview(&[RenameRule::Prefix("one-".into())])?;
        assert!(matches!(
            engine.apply_confirmed(first.id(), 2),
            Err(PlatformError::ConfirmationMismatch {
                expected: 1,
                actual: 2
            })
        ));
        let second = engine.preview(&[RenameRule::Prefix("two-".into())])?;
        assert!(matches!(
            engine.apply_confirmed(first.id(), 1),
            Err(PlatformError::StalePlan)
        ));
        engine.admit([PathBuf::from("/work/a.txt")])?;
        assert!(matches!(
            engine.apply_confirmed(second.id(), 1),
            Err(PlatformError::StalePlan)
        ));
        Ok(())
    }

    #[test]
    fn admission_accepts_only_unique_regular_non_symlink_files() -> Result<(), PlatformError> {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, state) = memory_engine(&fixture, &["a.txt"])?;
        assert!(matches!(
            engine.admit([PathBuf::from("/work/a.txt"), PathBuf::from("/work/a.txt")]),
            Err(PlatformError::AdmissionRejected {
                reason: AdmissionRejection::DuplicateIdentity,
                ..
            })
        ));

        if let Some(entry) = state.borrow_mut().entries.get_mut(Path::new("/work/a.txt")) {
            entry.kind = EntryKind::SymbolicLink;
        }
        assert!(matches!(
            engine.admit([PathBuf::from("/work/a.txt")]),
            Err(PlatformError::AdmissionRejected {
                reason: AdmissionRejection::SymbolicLink,
                ..
            })
        ));

        if let Some(entry) = state.borrow_mut().entries.get_mut(Path::new("/work/a.txt")) {
            entry.kind = EntryKind::Directory;
        }
        assert!(matches!(
            engine.admit([PathBuf::from("/work/a.txt")]),
            Err(PlatformError::AdmissionRejected {
                reason: AdmissionRejection::NotRegularFile,
                ..
            })
        ));
        Ok(())
    }

    #[test]
    fn three_way_cycle_uses_two_phases_and_journals_before_every_move() -> Result<(), PlatformError>
    {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, state) = memory_engine(&fixture, &["a.txt", "b.txt", "c.txt"])?;
        engine.admit([
            PathBuf::from("/work/a.txt"),
            PathBuf::from("/work/b.txt"),
            PathBuf::from("/work/c.txt"),
        ])?;
        let preview = engine.preview(&[
            replace("a", "__a__"),
            replace("b", "a"),
            replace("c", "b"),
            replace("__a__", "c"),
        ])?;
        assert!(preview.plan().can_apply());
        engine.apply_confirmed(preview.id(), 3)?;

        let state = state.borrow();
        assert_eq!(state.move_calls, 6);
        assert!(state.every_move_had_intent);
        assert!(state.entries.contains_key(Path::new("/work/a.txt")));
        assert!(state.entries.contains_key(Path::new("/work/b.txt")));
        assert!(state.entries.contains_key(Path::new("/work/c.txt")));
        assert!(
            state
                .entries
                .keys()
                .all(|path| !path.to_string_lossy().contains(".dark-renamer-"))
        );
        Ok(())
    }

    #[test]
    fn definite_failure_rolls_back_completed_moves() -> Result<(), PlatformError> {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, state) = memory_engine(&fixture, &["a.txt", "b.txt"])?;
        engine.admit([PathBuf::from("/work/a.txt"), PathBuf::from("/work/b.txt")])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        state.borrow_mut().failure = Some(InjectedFailure::DefiniteBefore(2));
        assert!(matches!(
            engine.apply_confirmed(preview.id(), 2),
            Err(PlatformError::ExecutionFailed {
                rolled_back: true,
                ..
            })
        ));
        let state = state.borrow();
        assert!(state.entries.contains_key(Path::new("/work/a.txt")));
        assert!(state.entries.contains_key(Path::new("/work/b.txt")));
        assert_eq!(state.entries.len(), 3);
        assert!(!engine.recovery_required);
        Ok(())
    }

    #[test]
    fn ambiguous_failure_requires_recovery() -> Result<(), PlatformError> {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, state) = memory_engine(&fixture, &["a.txt"])?;
        engine.admit([PathBuf::from("/work/a.txt")])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        state.borrow_mut().failure = Some(InjectedFailure::AmbiguousAfter(1));
        assert!(matches!(
            engine.apply_confirmed(preview.id(), 1),
            Err(PlatformError::RecoveryRequired)
        ));
        assert!(engine.recovery_required);
        Ok(())
    }

    #[test]
    fn undo_revalidates_occupied_destination_and_final_identity() -> Result<(), PlatformError> {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, state) = memory_engine(&fixture, &["a.txt"])?;
        engine.admit([PathBuf::from("/work/a.txt")])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        engine.apply_confirmed(preview.id(), 1)?;
        state
            .borrow_mut()
            .insert(Path::new("/work/a.txt"), EntryKind::RegularFile);
        assert!(matches!(
            engine.undo_latest(),
            Err(PlatformError::DestinationChanged { .. })
        ));

        state.borrow_mut().entries.remove(Path::new("/work/a.txt"));
        state
            .borrow_mut()
            .entries
            .remove(Path::new("/work/new-a.txt"));
        state
            .borrow_mut()
            .insert(Path::new("/work/new-a.txt"), EntryKind::RegularFile);
        assert!(matches!(
            engine.undo_latest(),
            Err(PlatformError::StaleSource { .. })
        ));
        Ok(())
    }

    #[test]
    fn undo_is_a_new_completed_transaction() -> Result<(), PlatformError> {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, state) = memory_engine(&fixture, &["a.txt"])?;
        engine.admit([PathBuf::from("/work/a.txt")])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        let apply_id = engine.apply_confirmed(preview.id(), 1)?;
        let undo_id = engine.undo_latest()?;
        assert_ne!(apply_id, undo_id);
        assert_eq!(engine.latest_transaction()?.kind(), TransactionKind::Undo);
        assert!(matches!(
            engine.undo_latest(),
            Err(PlatformError::LatestTransactionNotUndoable)
        ));
        assert!(
            state
                .borrow()
                .entries
                .contains_key(Path::new("/work/a.txt"))
        );
        Ok(())
    }

    #[test]
    fn completed_transaction_is_inspectable_and_undoable_after_restart() -> Result<(), PlatformError>
    {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let (mut engine, state) = memory_engine(&fixture, &["a.txt"])?;
        engine.admit([PathBuf::from("/work/a.txt")])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        let apply_id = engine.apply_confirmed(preview.id(), 1)?;
        drop(engine);

        let mut restarted = Engine::new(
            &fixture.root,
            MemoryFileSystem {
                state: Rc::clone(&state),
            },
        )?;
        assert_eq!(restarted.latest_transaction()?.id(), apply_id);
        assert_eq!(
            restarted.latest_transaction()?.kind(),
            TransactionKind::Apply
        );
        restarted.undo_latest()?;
        assert!(
            state
                .borrow()
                .entries
                .contains_key(Path::new("/work/a.txt"))
        );
        Ok(())
    }

    #[test]
    fn corrupt_and_torn_journals_fail_closed() -> Result<(), PlatformError> {
        let corrupt = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        fs::write(corrupt.root.join("0000000000000001.drj"), b"not-a-journal").map_err(
            |source| PlatformError::Io {
                operation: "write corrupt journal fixture",
                source,
            },
        )?;
        let corrupt_engine = Engine::new(
            &corrupt.root,
            MemoryFileSystem {
                state: Rc::new(RefCell::new(MemoryState::new(corrupt.root.clone()))),
            },
        )?;
        assert!(corrupt_engine.recovery_required);

        let torn = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let mut bytes = b"DRJNL001".to_vec();
        bytes.extend_from_slice(&8_u32.to_le_bytes());
        fs::write(torn.root.join("0000000000000001.drj"), bytes).map_err(|source| {
            PlatformError::Io {
                operation: "write torn journal fixture",
                source,
            }
        })?;
        let torn_engine = Engine::new(
            &torn.root,
            MemoryFileSystem {
                state: Rc::new(RefCell::new(MemoryState::new(torn.root.clone()))),
            },
        )?;
        assert!(torn_engine.recovery_required);
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn local_adapter_applies_and_undoes_without_replacement() -> Result<(), PlatformError> {
        let fixture = Fixture::new().map_err(|source| PlatformError::Io {
            operation: "create test fixture",
            source,
        })?;
        let files = fixture.root.join("files");
        let journals = fixture.root.join("journals");
        fs::create_dir_all(&files).map_err(|source| PlatformError::Io {
            operation: "create local files fixture",
            source,
        })?;
        let original = files.join("a.txt");
        let renamed = files.join("new-a.txt");
        fs::write(&original, b"content").map_err(|source| PlatformError::Io {
            operation: "write local source fixture",
            source,
        })?;
        let mut engine = RenameEngine::new(&journals)?;
        engine.admit([original.clone()])?;
        let preview = engine.preview(&[RenameRule::Prefix("new-".into())])?;
        engine.apply_confirmed(preview.id(), 1)?;
        assert!(!original.exists());
        assert!(renamed.exists());
        engine.undo_latest()?;
        assert!(original.exists());
        assert!(!renamed.exists());
        Ok(())
    }
}
