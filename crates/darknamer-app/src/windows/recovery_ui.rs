use super::*;

pub(super) fn export_recovery_journal(owner: HWND, state: &mut AppState) {
    if !state.can_export_recovery_journal() {
        message(
            owner,
            "보존된 저널 핸들이 없어 원본을 안전하게 복사할 수 없습니다.",
            "DarkReNamer - 진단 내보내기 불가",
        );
        return;
    }
    let Some(directory) = modal_native_dialog(owner, || {
        rfd::FileDialog::new()
            .set_title("복구 저널 원본을 저장할 폴더 선택")
            .pick_folder()
    }) else {
        return;
    };
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
    message(owner, &results.join("\n"), caption);
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

pub(super) fn discard_staged_journal(owner: HWND, state: &mut AppState) {
    if !state.can_discard_staged_intent() {
        message(
            owner,
            "현재 상태에서는 활성화 전 저널을 폐기할 수 없습니다. 복구 상태를 다시 확인해 주세요.",
            "DarkReNamer - 폐기 거부",
        );
        return;
    }
    let prompt = wide(
        "활성화 전 실행 계획만 기록되어 있으며 파일 변경은 시작되지 않았습니다.\n이 저널을 폐기하고 새 적용을 허용하시겠습니까?",
    );
    let caption = wide("DarkReNamer - 활성화 전 계획 폐기");
    // SAFETY: owner is the live top-level HWND and both UTF-16 buffers remain
    // allocated throughout this synchronous confirmation call.
    if unsafe { MessageBoxW(owner, prompt.as_ptr(), caption.as_ptr(), MB_OKCANCEL) } != IDOK {
        return;
    }
    if !state.can_discard_staged_intent() {
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
        set_status(
            state.status,
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
    if state.can_discard_staged_intent() {
        lines.push("가능한 작업: 활성화 전 실행 계획 폐기".to_owned());
    }
    message(owner, &lines.join("\n"), "DarkReNamer - 복구 상태");
}
