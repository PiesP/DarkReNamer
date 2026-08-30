//! Pure UI activation policy for the safe rename engine.

use darknamer_core::LegacyList;

use super::{
    BackendError, EntryId, EntryKind, ExecuteError, ExecuteErrorKind, ExecutionFailure,
    ExecutionOutcome, ExecutionReport, JournalCapacityError, JournalCapacityKind, JournalRecord,
    ModelRevision, PlanError, PlanIssueKind, PlanRequest, RecoveryState, RenameIntent, RenameState,
    replay_journal,
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

/// Explains why legacy cross-parent root unification is inert in Safe v1.
#[must_use]
pub const fn safe_mode_unify_path_message() -> &'static str {
    "Safe 모드에서는 다른 폴더로 이동하는 경로 통일을 아직 지원하지 않습니다. 목록은 변경되지 않았습니다."
}

/// Builds an exact plan request from current legacy rows without changing them.
#[must_use]
pub fn build_plan_request(model: &LegacyList, revision: ModelRevision) -> PlanRequest {
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
    PlanRequest::new(revision, entries)
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

/// Formats structured plan blockers for the Korean native shell.
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
        .map(|issue| plan_issue_korean(&issue.kind))
        .collect::<Vec<_>>();
    (reasons.join("\n"), rows)
}

fn plan_issue_korean(kind: &PlanIssueKind) -> String {
    match kind {
        PlanIssueKind::RelativeSource | PlanIssueKind::RelativeDestinationParent => {
            "상대 경로는 사용할 수 없습니다.".to_owned()
        }
        PlanIssueKind::InvalidDestinationName(_) => {
            "Windows에서 사용할 수 없는 이름입니다.".to_owned()
        }
        PlanIssueKind::MissingSource => "원본 항목을 찾을 수 없습니다.".to_owned(),
        PlanIssueKind::SourceKindChanged => "원본 항목 종류가 변경되었습니다.".to_owned(),
        PlanIssueKind::ReparseSource => "재분석 지점은 변경할 수 없습니다.".to_owned(),
        PlanIssueKind::DuplicateDestination => "중복되는 대상 이름이 있습니다.".to_owned(),
        PlanIssueKind::DuplicateEntryId | PlanIssueKind::DuplicateSource => {
            "중복되는 원본 항목이 있습니다.".to_owned()
        }
        PlanIssueKind::DestinationOccupied => "대상 이름이 이미 사용 중입니다.".to_owned(),
        PlanIssueKind::CrossParent => "다른 폴더로 이동할 수 없습니다.".to_owned(),
        PlanIssueKind::SourceOverlap => "상위/하위 항목을 함께 변경할 수 없습니다.".to_owned(),
        PlanIssueKind::PathTooDeep => "경로의 폴더 깊이가 안전 한도를 초과했습니다.".to_owned(),
        PlanIssueKind::UnsupportedCaseSensitiveParent => {
            "대소문자 구분 폴더는 아직 지원하지 않습니다.".to_owned()
        }
        PlanIssueKind::UnsupportedWindowsPath => {
            "네트워크 또는 지원하지 않는 경로입니다.".to_owned()
        }
        PlanIssueKind::Backend => "파일 시스템을 안전하게 확인하지 못했습니다.".to_owned(),
        PlanIssueKind::BackendFailure(error) => backend_error_korean("계획 검사", *error),
    }
}

/// Formats a pre-mutation execution refusal with native backend details.
#[must_use]
pub fn execute_error_korean(error: &ExecuteError) -> String {
    match error.kind {
        ExecuteErrorKind::Cancelled => "파일 변경을 시작하기 전에 취소했습니다.".to_owned(),
        ExecuteErrorKind::Backend(backend) => backend_error_korean("실행 준비", backend),
        ExecuteErrorKind::Journal(journal) => {
            format!("저널을 준비하지 못했습니다. 코드 {}", journal.code)
        }
        ExecuteErrorKind::JournalCapacity(capacity) => journal_capacity_error_korean(capacity),
        ExecuteErrorKind::StaleSource => "원본 항목이 계획 이후 변경되었습니다.".to_owned(),
        ExecuteErrorKind::StaleParent => "부모 폴더가 계획 이후 변경되었습니다.".to_owned(),
        ExecuteErrorKind::DestinationChanged | ExecuteErrorKind::TemporaryOccupied => {
            "대상 이름이 계획 이후 변경되었습니다.".to_owned()
        }
        ExecuteErrorKind::TemporaryExhausted => {
            "안전한 임시 이름을 확보하지 못했습니다.".to_owned()
        }
        ExecuteErrorKind::InvalidSchedule => "안전한 실행 순서를 만들지 못했습니다.".to_owned(),
    }
}

/// Formats a journal-capacity refusal with the required and maximum values.
#[must_use]
pub fn journal_capacity_error_korean(error: JournalCapacityError) -> String {
    match error.kind {
        JournalCapacityKind::PrimitiveSteps => format!(
            "저널의 파일 이동 단계 용량을 초과했습니다. 필요 {}개, 최대 {}개입니다.",
            error.required, error.maximum
        ),
        JournalCapacityKind::IntentFrameBytes => format!(
            "저널 실행 계획 용량을 초과했습니다. 필요 {}바이트, 최대 {}바이트입니다.",
            error.required, error.maximum
        ),
    }
}

/// Formats a post-journal execution outcome without hiding partial state.
#[must_use]
pub fn execution_outcome_korean(outcome: &ExecutionOutcome) -> String {
    match outcome {
        ExecutionOutcome::Completed => "파일 이름을 변경하였습니다.".to_owned(),
        ExecutionOutcome::RolledBack {
            failure: ExecutionFailure::Cancelled { .. },
        } => "요청에 따라 변경을 취소하고 원래 상태로 복원했습니다.".to_owned(),
        ExecutionOutcome::RolledBack { failure } => format!(
            "변경에 실패하여 원래 상태로 복원했습니다. {}",
            failure_korean(*failure)
        ),
        ExecutionOutcome::RecoveryRequired {
            failure: ExecutionFailure::Cancelled { .. },
            ..
        } => "취소 요청 후 상태 확인과 복구가 필요합니다. 적용이 잠겼습니다.".to_owned(),
        ExecutionOutcome::RecoveryRequired { failure, .. } => format!(
            "상태 확인과 복구가 필요합니다. 적용이 잠겼습니다. {}",
            failure_korean(*failure)
        ),
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

fn failure_korean(failure: ExecutionFailure) -> String {
    match failure {
        ExecutionFailure::Cancelled { .. } => "요청에 따라 변경을 취소했습니다.".to_owned(),
        ExecutionFailure::Backend { error, .. } => backend_error_korean("파일 변경", error),
        ExecutionFailure::Journal { error, .. } => format!("저널 코드 {}", error.code),
    }
}

fn backend_error_korean(context: &str, error: BackendError) -> String {
    format!(
        "{context} 실패: {:?}, Windows 코드 {}",
        error.operation, error.code
    )
}

#[cfg(test)]
mod presentation_tests {
    use super::*;
    use crate::rename::{BackendOperation, JournalError, MutationCertainty};

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
