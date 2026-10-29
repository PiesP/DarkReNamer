//! Pure UI activation policy for the safe rename engine.

use crate::i18n::runtime::{self as text, Text as RuntimeText};
use darknamer_core::LegacyList;

use super::{
    BackendError, EntryId, EntryKind, ExecuteError, ExecuteErrorKind, ExecutionFailure,
    ExecutionOutcome, ExecutionReport, JournalCapacityError, JournalCapacityKind, JournalRecord,
    ModelRevision, MoveScope, PlanError, PlanIssueKind, PlanRequest, RecoveryState, RenameIntent,
    RenameState, replay_journal,
};

/// Advances a monotonic model revision only for an observable model change.
#[must_use]
pub const fn next_model_revision(current: u64, changed: bool) -> u64 {
    if changed {
        current.saturating_add(1)
    } else {
        current
    }
}

/// Builds an exact plan request from current legacy rows without changing them.
#[must_use]
pub fn build_plan_request(model: &LegacyList, revision: ModelRevision) -> PlanRequest {
    let scope = if model
        .items()
        .iter()
        .any(|item| item.planned_change_kind().moves())
    {
        MoveScope::SameVolumeFilesOnly
    } else {
        MoveScope::SameParent
    };
    let entries = model
        .items()
        .iter()
        .enumerate()
        .map(|(index, item)| {
            RenameIntent::new(
                EntryId::new(u32::try_from(index).unwrap_or(u32::MAX)),
                item.source_path().clone(),
                item.root_path().clone(),
                item.proposed_name().clone(),
                if item.is_directory() {
                    EntryKind::Directory
                } else {
                    EntryKind::File
                },
            )
        })
        .collect();
    PlanRequest::with_scope(revision, entries, scope)
}

/// Applies row state only when the complete report is verified `Completed/Applied`.
#[must_use]
pub fn apply_execution_report(model: &mut LegacyList, report: &ExecutionReport) -> bool {
    if report.outcome() != &ExecutionOutcome::Completed
        || report
            .entries()
            .iter()
            .any(|entry| entry.state() != RenameState::Applied)
    {
        return false;
    }
    let mut rows = report
        .entries()
        .iter()
        .map(|entry| entry.entry().row_index() as usize)
        .collect::<Vec<_>>();
    rows.sort_unstable();
    if rows.iter().any(|row| *row >= model.len()) {
        return false;
    }
    rows.into_iter().all(|row| model.record_move_success(row))
}

/// Decision for an explicitly closed active-journal file.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalCleanupDecision {
    /// Empty file created before a pre-mutation refusal may be removed.
    RemoveEmpty,
    /// Verified terminal transaction may be removed explicitly.
    RemoveTerminal,
    /// Incomplete or corrupt/recovery-required state must be retained.
    Retain,
}

/// Classifies whether an active journal may be explicitly removed.
#[must_use]
pub fn cleanup_decision(records: &[JournalRecord]) -> JournalCleanupDecision {
    if records.is_empty() {
        JournalCleanupDecision::RemoveEmpty
    } else if matches!(records.last(), Some(JournalRecord::Terminal(_)))
        && replay_journal(records) == RecoveryState::Clean
    {
        JournalCleanupDecision::RemoveTerminal
    } else {
        JournalCleanupDecision::Retain
    }
}

/// Formats structured plan blockers for the selected application language.
#[must_use]
pub fn plan_error_korean(error: &PlanError) -> (String, Vec<usize>) {
    let mut rows = error
        .issues()
        .iter()
        .map(|issue| issue.entry.row_index() as usize)
        .collect::<Vec<_>>();
    rows.sort_unstable();
    rows.dedup();
    let reasons = error
        .issues()
        .iter()
        .map(|issue| plan_issue_message(&issue.kind))
        .collect::<Vec<_>>();
    (reasons.join("\n"), rows)
}

fn plan_issue_message(kind: &PlanIssueKind) -> String {
    match kind {
        PlanIssueKind::RelativeSource | PlanIssueKind::RelativeDestinationParent => {
            RuntimeText::RelativePath.get().to_owned()
        }
        PlanIssueKind::InvalidDestinationName(_) => {
            RuntimeText::InvalidWindowsName.get().to_owned()
        }
        PlanIssueKind::MissingSource => RuntimeText::MissingSource.get().to_owned(),
        PlanIssueKind::SourceKindChanged => RuntimeText::SourceKindChanged.get().to_owned(),
        PlanIssueKind::ReparseSource => RuntimeText::ReparseSource.get().to_owned(),
        PlanIssueKind::DuplicateDestination => RuntimeText::DuplicateDestination.get().to_owned(),
        PlanIssueKind::DuplicateEntryId | PlanIssueKind::DuplicateSource => {
            RuntimeText::DuplicateSource.get().to_owned()
        }
        PlanIssueKind::DestinationOccupied => RuntimeText::DestinationOccupied.get().to_owned(),
        PlanIssueKind::CrossParent => RuntimeText::CrossParent.get().to_owned(),
        PlanIssueKind::CrossVolume => RuntimeText::CrossVolume.get().to_owned(),
        PlanIssueKind::DirectoryMoveUnsupported => {
            RuntimeText::DirectoryMoveUnsupported.get().to_owned()
        }
        PlanIssueKind::SourceOverlap => RuntimeText::SourceOverlap.get().to_owned(),
        PlanIssueKind::PathTooDeep => RuntimeText::PathTooDeep.get().to_owned(),
        PlanIssueKind::UnsupportedCaseSensitiveParent => {
            RuntimeText::CaseSensitiveParent.get().to_owned()
        }
        PlanIssueKind::UnsupportedWindowsPath => {
            RuntimeText::UnsupportedWindowsPath.get().to_owned()
        }
        PlanIssueKind::UnsupportedFilesystem => RuntimeText::UnsupportedFilesystem.get().to_owned(),
        PlanIssueKind::Backend => RuntimeText::BackendPlan.get().to_owned(),
        PlanIssueKind::BackendFailure(error) => {
            backend_error_message(RuntimeText::PlanInspection.get(), *error)
        }
    }
}

/// Formats a pre-mutation execution refusal with native backend details.
#[must_use]
pub fn execute_error_korean(error: &ExecuteError) -> String {
    match error.kind {
        ExecuteErrorKind::Cancelled => RuntimeText::CancelledBeforeMutation.get().to_owned(),
        ExecuteErrorKind::Backend(backend) => {
            backend_error_message(RuntimeText::ExecutionPreparation.get(), backend)
        }
        ExecuteErrorKind::Journal(journal) => text::journal_prepare_failed(journal.code),
        ExecuteErrorKind::JournalCapacity(capacity) => journal_capacity_error_korean(capacity),
        ExecuteErrorKind::StaleSource => RuntimeText::StaleSource.get().to_owned(),
        ExecuteErrorKind::StaleParent => RuntimeText::StaleParent.get().to_owned(),
        ExecuteErrorKind::DestinationChanged | ExecuteErrorKind::TemporaryOccupied => {
            RuntimeText::DestinationChanged.get().to_owned()
        }
        ExecuteErrorKind::TemporaryExhausted => RuntimeText::TemporaryExhausted.get().to_owned(),
        ExecuteErrorKind::InvalidSchedule => RuntimeText::InvalidSchedule.get().to_owned(),
        ExecuteErrorKind::UnauthorizedMove => RuntimeText::UnauthorizedMove.get().to_owned(),
    }
}

/// Formats a journal-capacity refusal with the required and maximum values.
#[must_use]
pub fn journal_capacity_error_korean(error: JournalCapacityError) -> String {
    match error.kind {
        JournalCapacityKind::PrimitiveSteps => {
            text::journal_step_capacity(error.required, error.maximum)
        }
        JournalCapacityKind::IntentFrameBytes => {
            text::journal_frame_capacity(error.required, error.maximum)
        }
    }
}

/// Formats a post-journal execution outcome without hiding partial state.
#[must_use]
pub fn execution_outcome_korean(outcome: &ExecutionOutcome) -> String {
    match outcome {
        ExecutionOutcome::Completed => RuntimeText::MutationCompleted.get().to_owned(),
        ExecutionOutcome::RolledBack {
            failure: ExecutionFailure::Cancelled { .. },
        } => RuntimeText::CancelledAndRestored.get().to_owned(),
        ExecutionOutcome::RolledBack { failure } => {
            text::restored_after_failure(&failure_message(*failure))
        }
        ExecutionOutcome::RecoveryRequired {
            failure: ExecutionFailure::Cancelled { .. },
            ..
        } => RuntimeText::RecoveryRequiredAfterCancellation
            .get()
            .to_owned(),
        ExecutionOutcome::RecoveryRequired { failure, .. } => {
            text::recovery_required_after_failure(&failure_message(*failure))
        }
    }
}

/// Presentation severity for a terminal execution outcome.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionOutcomePresentation {
    /// Successful completion or a user-requested, fully restored cancellation.
    NonModal,
    /// A filesystem/journal failure or an outcome requiring recovery.
    Modal,
}

/// Keeps failures modal while allowing successful and cancelled outcomes in status UI.
#[must_use]
pub const fn execution_outcome_presentation(
    outcome: &ExecutionOutcome,
) -> ExecutionOutcomePresentation {
    match outcome {
        ExecutionOutcome::Completed
        | ExecutionOutcome::RolledBack {
            failure: ExecutionFailure::Cancelled { .. },
        } => ExecutionOutcomePresentation::NonModal,
        ExecutionOutcome::RolledBack { .. } | ExecutionOutcome::RecoveryRequired { .. } => {
            ExecutionOutcomePresentation::Modal
        }
    }
}

fn failure_message(failure: ExecutionFailure) -> String {
    match failure {
        ExecutionFailure::Cancelled { .. } => RuntimeText::MutationCancelled.get().to_owned(),
        ExecutionFailure::Backend { error, .. } => {
            backend_error_message(RuntimeText::FileMutation.get(), error)
        }
        ExecutionFailure::Journal { error, .. } => text::journal_code(error.code),
    }
}

fn backend_error_message(context: &str, error: BackendError) -> String {
    text::backend_failure(context, &error.operation, error.code)
}

#[cfg(test)]
mod presentation_tests {
    use super::*;
    use crate::rename::{BackendOperation, JournalError, MutationCertainty};

    #[test]
    fn execute_backend_observe_error_retains_operation_and_windows_code() {
        let error = ExecuteError {
            entry: Some(EntryId::new(0)),
            kind: ExecuteErrorKind::Backend(BackendError {
                operation: BackendOperation::Observe,
                code: 32,
                certainty: MutationCertainty::NotApplied,
            }),
        };

        assert_eq!(
            execute_error_korean(&error),
            "실행 준비 실패: Observe, Windows 코드 32"
        );
    }

    #[test]
    fn safety_guidance_keeps_native_diagnostics_and_recovery_lock_in_each_language() {
        use crate::i18n::{Language, with_language};

        let error = ExecuteError {
            entry: Some(EntryId::new(0)),
            kind: ExecuteErrorKind::Backend(BackendError {
                operation: BackendOperation::Observe,
                code: 32,
                certainty: MutationCertainty::NotApplied,
            }),
        };
        let outcome = ExecutionOutcome::RecoveryRequired {
            failure: ExecutionFailure::Cancelled { step: 1 },
            rollback_failures: Vec::new().into_boxed_slice(),
        };
        for (language, expected_code, expected_lock) in [
            (Language::Korean, "Windows 코드 32", "적용이 잠겼습니다"),
            (Language::English, "Windows code 32", "Apply is locked"),
            (Language::Japanese, "Windows コード 32", "適用はロック"),
        ] {
            with_language(language, || {
                let diagnostic = execute_error_korean(&error);
                assert!(diagnostic.contains("Observe"));
                assert!(diagnostic.contains(expected_code));
                assert!(execution_outcome_korean(&outcome).contains(expected_lock));
            });
        }
    }

    #[test]
    fn only_success_and_fully_rolled_back_cancellation_are_nonmodal() {
        let backend = ExecutionOutcome::RolledBack {
            failure: ExecutionFailure::Backend {
                step: 1,
                error: BackendError {
                    operation: BackendOperation::Rename,
                    code: 5,
                    certainty: MutationCertainty::NotApplied,
                },
            },
        };
        let journal = ExecutionOutcome::RolledBack {
            failure: ExecutionFailure::Journal {
                step: 1,
                error: JournalError::not_appended(7),
            },
        };

        assert_eq!(
            execution_outcome_presentation(&ExecutionOutcome::Completed),
            ExecutionOutcomePresentation::NonModal
        );
        assert_eq!(
            execution_outcome_presentation(&ExecutionOutcome::RolledBack {
                failure: ExecutionFailure::Cancelled { step: 1 },
            }),
            ExecutionOutcomePresentation::NonModal
        );
        assert_eq!(
            execution_outcome_presentation(&backend),
            ExecutionOutcomePresentation::Modal
        );
        assert_eq!(
            execution_outcome_presentation(&journal),
            ExecutionOutcomePresentation::Modal
        );
    }
}
