use super::*;

#[derive(Debug)]
pub(super) struct ActiveRecoveryPresentation {
    pub(super) status: String,
    pub(super) completed: bool,
}

pub(super) fn confirm_startup_recovery(owner: HWND) {
    let Some(mut state_lease) = try_app_state(owner) else {
        return;
    };
    let state = state_lease.state_mut();
    if !state.can_confirm_active_recovery() {
        return;
    }
    let detail = state.active_journal.as_ref().map_or_else(
        || "보존된 active 저널 정보가 없습니다.".to_owned(),
        |journal| {
            format!(
                "저널: {}\n크기: {} bytes\n레코드: {}개",
                journal.path().display(),
                journal.byte_len(),
                journal.records().len()
            )
        },
    );
    let buttons = [TaskDialogButtonSpec {
        id: RECOVER_CONFIRM_BUTTON_ID,
        text: "이전 변경 복구",
    }];
    state.mutation_locked = true;
    state.confirmation_pending = true;
    update_controls(state);
    drop(state_lease);

    let answer = task_dialog(
        owner,
        TaskDialogSpec {
            title: "DarkReNamer - 이전 변경 복구 확인",
            main_instruction: "이전 실행에서 중단된 이름 변경을 복구하시겠습니까?",
            content: "복구를 선택하면 보존된 저널과 현재 파일 신원을 다시 검증한 뒤 필요한 역방향 이름 변경을 수행합니다. 취소하면 어떤 파일도 변경하지 않고 복구 잠금을 유지합니다.",
            expanded_information: Some(&detail),
            buttons: &buttons,
            warning: true,
        },
    );

    let Some(mut state_lease) = try_app_state(owner) else {
        return;
    };
    let state = state_lease.state_mut();
    state.mutation_locked = false;
    state.confirmation_pending = false;
    update_controls(state);
    if state.close_pending {
        drop(state_lease);
        // SAFETY: queueing WM_CLOSE carries no borrowed state. The startup
        // confirmation has released its AppState lease before reclamation.
        unsafe { PostMessageW(owner, WM_CLOSE, 0, 0) };
        return;
    }
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => {
            drop(state_lease);
            message(
                owner,
                &format!("안전 확인 대화상자를 열지 못해 복구를 시작하지 않았습니다: {error}"),
                "DarkReNamer - 복구 보류",
            );
            return;
        }
    };
    if destructive_prompt_choice(answer, RECOVER_CONFIRM_BUTTON_ID)
        != DestructivePromptChoice::Confirm
    {
        return;
    }
    if !state.can_confirm_active_recovery() {
        drop(state_lease);
        message(
            owner,
            "확인 중 복구 상태가 변경되어 어떤 파일도 변경하지 않았습니다.",
            "DarkReNamer - 복구 거부",
        );
        return;
    }

    let presentation = recover_confirmed_active_journal(state);
    update_controls(state);
    drop(state_lease);
    let caption = if presentation.completed {
        "DarkReNamer - 복구 완료"
    } else {
        "DarkReNamer - 복구 확인 필요"
    };
    message(owner, &presentation.status, caption);
}

pub(super) fn recover_confirmed_active_journal(state: &mut AppState) -> ActiveRecoveryPresentation {
    if !state.can_confirm_active_recovery() {
        return ActiveRecoveryPresentation {
            status: "현재 상태에서는 active 저널 복구를 시작할 수 없습니다.".to_owned(),
            completed: false,
        };
    }
    let Some(mut journal) = state.active_journal.take() else {
        return ActiveRecoveryPresentation {
            status: "복구할 active 저널이 없습니다.".to_owned(),
            completed: false,
        };
    };
    let mut backend = WindowsRenameBackend;
    match RenameRecovery::new(&mut backend, &mut journal).rollback() {
        outcome @ RecoveryOutcome::Recovered { .. } | outcome @ RecoveryOutcome::NotRequired => {
            let cleanup = cleanup_file_journal(journal);
            let cleanup_failed = cleanup.error.is_some();
            let recovered = matches!(outcome, RecoveryOutcome::Recovered { .. });
            let mut status = if recovered && cleanup_failed {
                "이전 변경을 검증하고 복구했지만 저널 정리가 완료되지 않았습니다.".to_owned()
            } else if recovered {
                "이전 변경을 안전하게 복구하고 저널을 정리했습니다.".to_owned()
            } else if cleanup_failed {
                "파일 상태를 안전하게 확인했지만 완료된 저널을 정리하지 못했습니다.".to_owned()
            } else {
                "파일 상태를 안전하게 확인하고 완료된 저널을 정리했습니다.".to_owned()
            };
            if let Some(error) = cleanup.error {
                status.push_str(&format!(" 저널 삭제 실패: {error}"));
            }
            state.active_journal = cleanup.retained;
            state.recovery_locked = cleanup_failed
                || state.active_journal.is_some()
                || state.staged_journal.is_some()
                || !state.blocked_journals.is_empty();
            if state.recovery_locked {
                state.ui_status.set_recovery(status.clone());
            } else {
                state.ui_status.clear_recovery();
                state.ui_status.set_transient(status.clone());
            }
            ActiveRecoveryPresentation {
                status,
                completed: !state.recovery_locked,
            }
        }
        RecoveryOutcome::Blocked { reason, .. } => {
            let status = format!(
                "현재 파일 상태와 저널을 대조한 결과 복구가 차단되었습니다: {reason:?}. active 저널을 보존하고 새 적용을 잠급니다."
            );
            state.active_journal = Some(journal);
            state.recovery_locked = true;
            state.ui_status.set_recovery(status.clone());
            ActiveRecoveryPresentation {
                status,
                completed: false,
            }
        }
        RecoveryOutcome::RecoveryRequired { reason, .. } => {
            let status = format!(
                "복구를 완료하지 못했습니다: {reason:?}. active 저널을 보존하고 새 적용을 잠급니다."
            );
            state.active_journal = Some(journal);
            state.recovery_locked = true;
            state.ui_status.set_recovery(status.clone());
            ActiveRecoveryPresentation {
                status,
                completed: false,
            }
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ValidJournalSnapshot {
    path: PathBuf,
    byte_len: u64,
    records: Vec<crate::rename::JournalRecord>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum BlockedJournalSnapshot {
    Evidence {
        role: JournalRole,
        path: PathBuf,
        byte_len: u64,
        failure: JournalOpenFailure,
    },
    Unavailable {
        role: JournalRole,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RecoveryExportSnapshot {
    active: Option<ValidJournalSnapshot>,
    staged: Option<ValidJournalSnapshot>,
    blocked: Vec<BlockedJournalSnapshot>,
}

pub(super) struct PreparedRecoveryExport {
    session: PreparedTaskDialogSession,
    snapshot: RecoveryExportSnapshot,
}

struct RecoveryExportPresentation {
    text: String,
    caption: &'static str,
}

fn valid_journal_snapshot(journal: &FileJournal) -> ValidJournalSnapshot {
    ValidJournalSnapshot {
        path: journal.path().to_path_buf(),
        byte_len: journal.byte_len(),
        records: journal.records().to_vec(),
    }
}

fn recovery_export_snapshot(state: &AppState) -> RecoveryExportSnapshot {
    RecoveryExportSnapshot {
        active: state.active_journal.as_ref().map(valid_journal_snapshot),
        staged: state.staged_journal.as_ref().map(valid_journal_snapshot),
        blocked: state
            .blocked_journals
            .iter()
            .map(|blocked| {
                let role = blocked.role();
                blocked.evidence().map_or(
                    BlockedJournalSnapshot::Unavailable { role },
                    |evidence| BlockedJournalSnapshot::Evidence {
                        role,
                        path: evidence.path().to_path_buf(),
                        byte_len: evidence.byte_len(),
                        failure: evidence.failure(),
                    },
                )
            })
            .collect(),
    }
}

pub(super) fn prepare_recovery_export(
    owner: HWND,
    state: &mut AppState,
) -> Option<PreparedRecoveryExport> {
    if !state.can_export_recovery_journal() {
        message(
            owner,
            "보존된 저널 핸들이 없어 원본을 안전하게 복사할 수 없습니다.",
            "DarkReNamer - 진단 내보내기 불가",
        );
        return None;
    }
    let snapshot = recovery_export_snapshot(state);
    let session = begin_prepared_task_dialog(state)?;
    update_controls(state);
    Some(PreparedRecoveryExport { session, snapshot })
}

pub(super) fn run_prepared_recovery_export(
    owner: HWND,
    prepared: PreparedRecoveryExport,
    select: impl FnOnce(HWND, PreparedFileDialogKind) -> PreparedFileDialogSelection,
) {
    let selection = select(owner, PreparedFileDialogKind::ExportRecoveryJournal);
    let Some(mut state_lease) = try_app_state(owner) else {
        return;
    };
    let state = state_lease.state_mut();
    let disposition = take_prepared_task_dialog(
        state,
        prepared.session,
        PreparedTaskDialogPolicy::RecoveryAllowed,
    );
    update_controls(state);
    if disposition == PreparedTaskDialogDisposition::Closed {
        try_finish_window_close(owner, state);
        return;
    }
    let PreparedFileDialogSelection::RecoveryExportDirectory(directory) = selection else {
        return;
    };
    if disposition != PreparedTaskDialogDisposition::Accepted
        || !state.can_export_recovery_journal()
        || recovery_export_snapshot(state) != prepared.snapshot
    {
        if matches!(
            disposition,
            PreparedTaskDialogDisposition::Accepted | PreparedTaskDialogDisposition::Rejected
        ) {
            state.set_transient_status(
                "진단 내보내기 창이 열린 동안 복구 상태가 바뀌어 원본을 복사하지 않았습니다.",
            );
        }
        return;
    }
    let presentation = perform_recovery_export(state, &directory);
    drop(state_lease);
    queue_deferred_message(owner, presentation.text, presentation.caption.to_owned());
}

fn perform_recovery_export(state: &mut AppState, directory: &Path) -> RecoveryExportPresentation {
    let mut results = Vec::new();
    let mut failures = 0_usize;
    if let Some(journal) = state.active_journal.as_mut() {
        export_valid_journal(
            journal,
            &directory.join("active.drj.retained"),
            &mut results,
            &mut failures,
        );
    }
    if let Some(journal) = state.staged_journal.as_mut() {
        export_valid_journal(
            journal,
            &directory.join("candidate.drj.retained"),
            &mut results,
            &mut failures,
        );
    }
    for blocked in &mut state.blocked_journals {
        let role = blocked.role();
        let Some(evidence) = blocked.evidence_mut() else {
            results.push(format!(
                "건너뜀: {role:?} 저널은 retained handle을 확보하지 못했습니다."
            ));
            continue;
        };
        let name = match role {
            JournalRole::Active => "active.drj.evidence",
            JournalRole::Candidate => "candidate.drj.evidence",
        };
        let path = directory.join(name);
        match evidence.copy_exact_to_new(&path) {
            Ok(bytes) => results.push(format!("{bytes} bytes: {}", path.display())),
            Err(error) => {
                failures = failures.saturating_add(1);
                results.push(format!("실패: {} ({error})", path.display()));
            }
        }
    }
    let caption = if failures == 0 {
        "DarkReNamer - 진단 내보내기 완료"
    } else {
        "DarkReNamer - 진단 내보내기 일부 실패"
    };
    RecoveryExportPresentation {
        text: results.join("\n"),
        caption,
    }
}

pub(super) fn export_valid_journal(
    journal: &mut FileJournal,
    path: &Path,
    results: &mut Vec<String>,
    failures: &mut usize,
) {
    match journal.copy_exact_to_new(path) {
        Ok(bytes) => results.push(format!("{bytes} bytes: {}", path.display())),
        Err(error) => {
            *failures = failures.saturating_add(1);
            results.push(format!("실패: {} ({error})", path.display()));
        }
    }
}

pub(super) struct PreparedDiscardTaskDialog {
    session: PreparedTaskDialogSession,
    spec: PreparedTaskDialogSpec,
    journal_path: PathBuf,
    journal_bytes: u64,
    journal_records: Vec<crate::rename::JournalRecord>,
}

pub(super) fn prepare_discard_staged_journal(
    owner: HWND,
    state: &mut AppState,
) -> Option<PreparedDiscardTaskDialog> {
    if !state.can_discard_staged_intent() {
        message(
            owner,
            "현재 상태에서는 활성화 전 저널을 폐기할 수 없습니다. 복구 상태를 다시 확인해 주세요.",
            "DarkReNamer - 폐기 거부",
        );
        return None;
    }
    let staged = state.staged_journal.as_ref()?;
    let journal_path = staged.path().to_path_buf();
    let journal_bytes = staged.byte_len();
    let journal_records = staged.records().to_vec();
    let detail = format!(
        "저널: {}\n크기: {} bytes\n레코드: {}개",
        journal_path.display(),
        journal_bytes,
        journal_records.len()
    );
    let session = begin_prepared_task_dialog(state)?;
    update_controls(state);
    Some(PreparedDiscardTaskDialog {
        session,
        spec: PreparedTaskDialogSpec {
            title: "DarkReNamer - 활성화 전 계획 폐기".to_owned(),
            main_instruction: "활성화 전 실행 계획을 폐기하시겠습니까?".to_owned(),
            content: "파일 변경은 시작되지 않았습니다. 폐기하면 새 적용을 다시 사용할 수 있습니다."
                .to_owned(),
            expanded_information: Some(detail),
            buttons: vec![PreparedTaskDialogButton {
                id: DISCARD_CONFIRM_BUTTON_ID,
                text: "계획 폐기".to_owned(),
            }],
            warning: true,
        },
        journal_path,
        journal_bytes,
        journal_records,
    })
}

pub(super) fn run_prepared_discard_task_dialog(
    owner: HWND,
    prepared: PreparedDiscardTaskDialog,
    select: impl FnOnce(HWND, &PreparedTaskDialogSpec) -> io::Result<i32>,
) {
    let answer = select(owner, &prepared.spec);
    let Some(mut state_lease) = try_app_state(owner) else {
        return;
    };
    let state = state_lease.state_mut();
    let disposition = take_prepared_task_dialog(
        state,
        prepared.session,
        PreparedTaskDialogPolicy::RecoveryLocked,
    );
    update_controls(state);
    if disposition == PreparedTaskDialogDisposition::Closed {
        drop(state_lease);
        // SAFETY: queueing WM_CLOSE carries no borrowed state. The current
        // prepared-dialog runner has released AppState before reclamation.
        unsafe { PostMessageW(owner, WM_CLOSE, 0, 0) };
        return;
    }
    if disposition != PreparedTaskDialogDisposition::Accepted {
        if disposition == PreparedTaskDialogDisposition::Rejected {
            message(
                owner,
                "확인 중 복구 상태가 변경되어 폐기를 중단했습니다.",
                "DarkReNamer - 폐기 거부",
            );
        }
        return;
    }
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => {
            message(
                owner,
                &format!("안전 확인 대화상자를 열지 못해 폐기를 취소했습니다: {error}"),
                "DarkReNamer - 폐기 취소",
            );
            return;
        }
    };
    if destructive_prompt_choice(answer, DISCARD_CONFIRM_BUTTON_ID)
        != DestructivePromptChoice::Confirm
    {
        return;
    }
    let journal_matches = state.staged_journal.as_ref().is_some_and(|journal| {
        journal.path() == prepared.journal_path
            && journal.byte_len() == prepared.journal_bytes
            && journal.records() == prepared.journal_records
    });
    if !state.can_discard_staged_intent() || !journal_matches {
        message(
            owner,
            "확인 중 복구 상태가 변경되어 폐기를 중단했습니다.",
            "DarkReNamer - 폐기 거부",
        );
        return;
    }
    let Some(mut staged) = state.staged_journal.take() else {
        message(owner, "폐기할 저널이 없습니다.", "DarkReNamer - 폐기 거부");
        return;
    };
    if let Err(error) = staged.mark_unactivated_intent_delete() {
        state.staged_journal = Some(staged);
        state.recovery_locked = true;
        message(
            owner,
            &format!("활성화 전 저널을 폐기하지 못했습니다: {error}"),
            "DarkReNamer - 폐기 실패",
        );
        update_controls(state);
        return;
    }
    drop(staged);
    rediscover_after_staged_discard(state);
    if state.recovery_locked {
        message(
            owner,
            "저널 폐기 후 다른 복구 상태가 관찰되어 적용 잠금을 유지합니다.",
            "DarkReNamer - 복구 상태 확인 필요",
        );
    } else {
        state.clear_recovery_status();
        state.set_transient_status(
            "활성화 전 실행 계획을 폐기했습니다. 파일은 변경되지 않았습니다.",
        );
        message(
            owner,
            "활성화 전 실행 계획을 폐기했습니다. 파일은 변경되지 않았으며 새 적용을 사용할 수 있습니다.",
            "DarkReNamer - 폐기 완료",
        );
    }
    update_controls(state);
}

pub(super) fn rediscover_after_staged_discard(state: &mut AppState) {
    let mut blocked = Vec::new();
    let active = match FileJournal::open_existing_retained(&state.journal_root, ACTIVE_JOURNAL_LEAF)
    {
        Ok(journal) => Some(journal),
        Err(error) => {
            if let Some(block) = StartupJournalBlock::from_open_error(JournalRole::Active, error) {
                blocked.push(block);
            }
            None
        }
    };
    let staged = match FileJournal::open_candidate_existing_retained(
        &state.journal_root,
        CANDIDATE_JOURNAL_LEAF,
        ACTIVE_JOURNAL_LEAF,
    ) {
        Ok(journal) => Some(journal),
        Err(error) => {
            if let Some(block) = StartupJournalBlock::from_open_error(JournalRole::Candidate, error)
            {
                blocked.push(block);
            }
            None
        }
    };
    let active_observed = active.is_some()
        || blocked
            .iter()
            .any(|entry| entry.role() == JournalRole::Active);
    let candidate_observed = staged.is_some()
        || blocked
            .iter()
            .any(|entry| entry.role() == JournalRole::Candidate);
    state.active_journal = active;
    state.staged_journal = staged;
    state.blocked_journals = blocked;
    state.collision_observed = active_observed && candidate_observed;
    state.recovery_locked = active_observed || candidate_observed;
}

pub(super) fn show_recovery_status(owner: HWND, state: &AppState) {
    let mut lines = Vec::new();
    if state.collision_observed {
        lines.push(
            "상태: active와 candidate가 동시에 관찰되어 자동 복구와 폐기를 중단했습니다."
                .to_owned(),
        );
    } else if state.recovery_locked {
        lines.push("상태: 복구 잠금".to_owned());
    } else {
        lines.push("상태: 복구 저널 없음".to_owned());
    }
    if let Some(journal) = state.active_journal.as_ref() {
        lines.push(format!(
            "Active: {} ({} bytes, {} records)",
            journal.path().display(),
            journal.byte_len(),
            journal.records().len()
        ));
    }
    if let Some(journal) = state.staged_journal.as_ref() {
        let kind = if journal.is_complete_intent_candidate() {
            "완전한 Intent-only"
        } else if journal.is_physically_empty_candidate() {
            "빈 candidate"
        } else {
            "폐기할 수 없는 candidate"
        };
        lines.push(format!(
            "Candidate: {} ({} bytes, {kind})",
            journal.path().display(),
            journal.byte_len()
        ));
    }
    lines.extend(
        state
            .blocked_journals
            .iter()
            .map(StartupJournalBlock::status_korean),
    );
    if state.can_export_recovery_journal() {
        lines.push("가능한 작업: 보존된 저널 바이트 내보내기".to_owned());
    }
    if state.can_confirm_active_recovery() {
        lines.push("시작 시 확인 가능: 이전 변경의 명시적 복구".to_owned());
    }
    if state.can_discard_staged_intent() {
        lines.push("가능한 작업: 활성화 전 실행 계획 폐기".to_owned());
    }
    message(owner, &lines.join("\n"), "DarkReNamer - 복구 상태");
}
