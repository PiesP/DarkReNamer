use std::cell::Cell;

use darknamer_app::rename::{
    BackendError, BackendOperation, ExecutionOutcome, JournalCapacityError, JournalCapacityKind,
    JournalCleanupDecision, JournalRecord, JournalTerminal, MemoryBackend, MemoryJournal,
    ModelRevision, MoveScope, MutationCertainty, PathKey, PathSnapshot, RenameBackend,
    RenameExecutor, RenameOperation, RenamePlanner, apply_execution_report, build_plan_request,
    cleanup_decision, journal_capacity_error_korean, next_model_revision, plan_error_korean,
};
use darknamer_core::{LegacyList, LegacyListItem, LegacyText};

fn model() -> LegacyList {
    let mut model = LegacyList::new();
    assert_eq!(
        model.append(LegacyListItem::new("C:\\work\\a.txt", false, 1, 2, 3)),
        Ok(true)
    );
    assert_eq!(model.manual_change(0, "b.txt"), Ok(true));
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
    assert_eq!(
        model.append(LegacyListItem::new("C:\\work\\c.txt", false, 1, 2, 3)),
        Ok(true)
    );
    assert_eq!(model.manual_change(1, "b.txt"), Ok(true));
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
fn plan_request_authorizes_same_volume_files_only_for_destination_parent_proposals()
-> Result<(), Box<dyn std::error::Error>> {
    let mut model = model();
    assert_eq!(
        build_plan_request(&model, ModelRevision::new(1)).scope(),
        MoveScope::SameParent
    );

    let changed = model.unify_destination_parent_changed(&LegacyText::from(r"C:\archive"))?;
    assert_eq!(&*changed, &[0]);
    assert_eq!(
        build_plan_request(&model, ModelRevision::new(2)).scope(),
        MoveScope::SameVolumeFilesOnly
    );

    let reset = model.reset_destination_parents()?;
    assert_eq!(&*reset, &[0]);
    assert_eq!(model.items()[0].proposed_name(), &LegacyText::from("b.txt"));
    assert_eq!(
        build_plan_request(&model, ModelRevision::new(3)).scope(),
        MoveScope::SameParent
    );
    Ok(())
}

#[test]
fn capacity_messages_name_the_resource_and_required_and_maximum_values() {
    let steps = journal_capacity_error_korean(JournalCapacityError {
        kind: JournalCapacityKind::PrimitiveSteps,
        required: 10_002,
        maximum: 10_000,
    });
    assert!(steps.contains("파일 이동 단계"));
    assert!(steps.contains("10002"));
    assert!(steps.contains("10000"));

    let frame = journal_capacity_error_korean(JournalCapacityError {
        kind: JournalCapacityKind::IntentFrameBytes,
        required: 16_777_217,
        maximum: 16_777_216,
    });
    assert!(frame.contains("실행 계획 용량"));
    assert!(frame.contains("16777217"));
    assert!(frame.contains("16777216"));
}

struct FailingBackend {
    inner: MemoryBackend,
    code: u32,
    observe_calls: Cell<usize>,
}

impl RenameBackend for FailingBackend {
    fn validate_path_environment(&self, _path: &LegacyText) -> Result<(), BackendError> {
        Err(BackendError {
            operation: BackendOperation::Observe,
            code: self.code,
            certainty: MutationCertainty::NotApplied,
        })
    }

    fn path_key(&self, path: &LegacyText) -> PathKey {
        self.inner.path_key(path)
    }

    fn observe(&self, path: &LegacyText) -> Result<PathSnapshot, BackendError> {
        self.observe_calls.set(self.observe_calls.get() + 1);
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
        code: 1234,
        observe_calls: Cell::new(0),
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
    assert_eq!(backend.observe_calls.get(), 0);
    assert_eq!(backend.inner.mutation_count(), 0);
}

#[test]
fn unsupported_filesystem_blocker_has_clear_korean_message_without_observation_or_mutation()
-> Result<(), Box<dyn std::error::Error>> {
    let model = model();
    let backend = FailingBackend {
        inner: MemoryBackend::new().with_file("C:\\work\\a.txt", 1),
        code: 1005,
        observe_calls: Cell::new(0),
    };

    let Err(error) =
        RenamePlanner::new(&backend).plan(build_plan_request(&model, ModelRevision::new(1)))
    else {
        return Err(std::io::Error::other("a non-NTFS parent was accepted").into());
    };
    let (message, rows) = plan_error_korean(&error);

    assert!(message.contains("NTFS"));
    assert!(message.contains("지원"));
    assert_eq!(rows, vec![0]);
    assert_eq!(backend.observe_calls.get(), 0);
    assert_eq!(backend.inner.mutation_count(), 0);
    Ok(())
}
