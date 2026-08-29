use darknamer_app::rename::{
    BackendError, BackendOperation, ExecutionOutcome, JournalCleanupDecision, JournalRecord,
    JournalTerminal, MemoryBackend, MemoryJournal, ModelRevision, MutationCertainty, PathKey,
    PathSnapshot, RenameBackend, RenameExecutor, RenameOperation, RenamePlanner,
    apply_execution_report, build_plan_request, cleanup_decision, next_model_revision,
    plan_error_korean, safe_mode_unify_path_message,
};
use darknamer_core::{LegacyList, LegacyListItem, LegacyText};

fn model() -> LegacyList {
    let mut model = LegacyList::new();
    assert!(model.append(LegacyListItem::new("C:\\work\\a.txt", false, 1, 2, 3)));
    assert!(model.manual_change(0, "b.txt"));
    model
}

#[test]
fn request_and_completed_report_update_the_exact_stable_row()
-> Result<(), Box<dyn std::error::Error>> {
    let mut model = model();
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let plan =
        RenamePlanner::new(&backend).plan(build_plan_request(&model, ModelRevision::new(9)))?;
    assert_eq!(plan.rows()[0].entry().row_index(), 0);
    assert_eq!(plan.revision(), ModelRevision::new(9));
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;

    assert!(apply_execution_report(&mut model, &report));
    assert_eq!(
        model.items()[0].source_path(),
        &LegacyText::from("C:\\work\\b.txt")
    );
    Ok(())
}

#[test]
fn rolled_back_report_leaves_model_and_incomplete_journal_is_retained()
-> Result<(), Box<dyn std::error::Error>> {
    let mut model = model();
    let original = model.clone();
    let mut backend = MemoryBackend::new().with_file("C:\\work\\a.txt", 1);
    let plan =
        RenamePlanner::new(&backend).plan(build_plan_request(&model, ModelRevision::new(1)))?;
    backend.fail_move_on(1, 5);
    let id = plan.id();
    let revision = plan.revision();
    let mut journal = MemoryJournal::new();
    let report = RenameExecutor::new(&mut backend, &mut journal)
        .execute(plan.confirm_presented(id, revision)?)?;
    assert!(matches!(
        report.outcome(),
        ExecutionOutcome::RolledBack { .. }
    ));
    assert!(!apply_execution_report(&mut model, &report));
    assert_eq!(model, original);
    assert_eq!(
        cleanup_decision(journal.records()),
        JournalCleanupDecision::RemoveTerminal
    );

    let incomplete = &journal.records()[..journal.records().len() - 1];
    assert_eq!(cleanup_decision(incomplete), JournalCleanupDecision::Retain);
    assert_eq!(cleanup_decision(&[]), JournalCleanupDecision::RemoveEmpty);
    assert!(matches!(
        journal.records().last(),
        Some(JournalRecord::Terminal(JournalTerminal::RolledBack))
    ));
    Ok(())
}

#[test]
fn blocker_message_is_structured_and_selects_affected_rows() {
    let mut model = model();
    assert!(model.append(LegacyListItem::new("C:\\work\\c.txt", false, 1, 2, 3)));
    assert!(model.manual_change(1, "b.txt"));
    let backend = MemoryBackend::new()
        .with_file("C:\\work\\a.txt", 1)
        .with_file("C:\\work\\c.txt", 2);
    let error = RenamePlanner::new(&backend)
        .plan(build_plan_request(&model, ModelRevision::new(1)))
        .err();
    let Some(error) = error else {
        return;
    };
    let (message, rows) = plan_error_korean(&error);
    assert!(message.contains("중복"));
    assert_eq!(rows, vec![0, 1]);
}

#[test]
fn model_revision_is_monotonic_and_changes_only_with_the_model() {
    assert_eq!(next_model_revision(7, false), 7);
    assert_eq!(next_model_revision(7, true), 8);
    assert_eq!(next_model_revision(u64::MAX, true), u64::MAX);
}

#[test]
fn safe_mode_unify_path_is_explicitly_inert() {
    assert!(safe_mode_unify_path_message().contains("지원하지"));
    assert!(safe_mode_unify_path_message().contains("변경되지"));
}

struct FailingBackend {
    inner: MemoryBackend,
}

impl RenameBackend for FailingBackend {
    fn validate_path_environment(&self, _path: &LegacyText) -> Result<(), BackendError> {
        Err(BackendError {
            operation: BackendOperation::Observe,
            code: 1234,
            certainty: MutationCertainty::NotApplied,
        })
    }

    fn path_key(&self, path: &LegacyText) -> PathKey {
        self.inner.path_key(path)
    }

    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError> {
        self.inner.observe(path)
    }

    fn is_same_or_descendant(
        &self,
        ancestor: &LegacyText,
        candidate: &LegacyText,
    ) -> Result<bool, BackendError> {
        self.inner.is_same_or_descendant(ancestor, candidate)
    }

    fn next_transaction_nonce(&mut self) -> Result<u128, BackendError> {
        self.inner.next_transaction_nonce()
    }

    fn rename_no_replace(&mut self, operation: &RenameOperation) -> Result<(), BackendError> {
        self.inner.rename_no_replace(operation)
    }
}

#[test]
fn backend_blocker_message_retains_operation_and_native_code() {
    let model = model();
    let backend = FailingBackend {
        inner: MemoryBackend::new().with_file("C:\\work\\a.txt", 1),
    };
    let error = RenamePlanner::new(&backend)
        .plan(build_plan_request(&model, ModelRevision::new(1)))
        .err();
    let Some(error) = error else {
        return;
    };
    let (message, rows) = plan_error_korean(&error);
    assert!(message.contains("Observe"));
    assert!(message.contains("1234"));
    assert_eq!(rows, vec![0]);
}
