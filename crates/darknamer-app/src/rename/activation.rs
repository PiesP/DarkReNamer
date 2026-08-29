//! Pure UI activation policy for the safe rename engine.

use darknamer_core::LegacyList;

use super::{
    BackendError, EntryId, EntryKind, ExecuteError, ExecuteErrorKind, ExecutionFailure,
    ExecutionOutcome, ExecutionReport, JournalRecord, ModelRevision, PlanError, PlanIssueKind,
    PlanRequest, RecoveryState, RenameIntent, RenameState, replay_journal,
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
        ExecuteErrorKind::Backend(backend) => backend_error_korean("실행 준비", backend),
        ExecuteErrorKind::Journal(journal) => {
            format!("저널을 준비하지 못했습니다. 코드 {}", journal.code)
        }
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

/// Formats a post-journal execution outcome without hiding partial state.
#[must_use]
pub fn execution_outcome_korean(outcome: &ExecutionOutcome) -> String {
    match outcome {
        ExecutionOutcome::Completed => "파일 이름을 변경하였습니다.".to_owned(),
        ExecutionOutcome::RolledBack { failure } => {
            format!(
                "변경에 실패하여 원래 상태로 복원했습니다. {}",
                failure_korean(*failure)
            )
        }
        ExecutionOutcome::RecoveryRequired { failure, .. } => format!(
            "상태 확인과 복구가 필요합니다. 적용이 잠겼습니다. {}",
            failure_korean(*failure)
        ),
    }
}

fn failure_korean(failure: ExecutionFailure) -> String {
    match failure {
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
