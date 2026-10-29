use super::{
    ACTIVE_JOURNAL_LEAF, AppState, CANDIDATE_JOURNAL_LEAF, JournalRole, PreparedFileDialogKind,
    PreparedFileDialogSelection, PreparedRecoveryExportDirectory, PreparedTaskDialogButton,
    PreparedTaskDialogDisposition, PreparedTaskDialogPolicy, PreparedTaskDialogSession,
    PreparedTaskDialogSpec, StartupJournalBlock, TaskDialogButtonSpec, TaskDialogSpec,
    begin_prepared_task_dialog, cleanup_file_journal, message, queue_deferred_message,
    take_prepared_task_dialog, task_dialog, try_app_state, try_finish_window_close,
    update_controls,
};
use crate::DISCARD_CONFIRM_BUTTON_ID;
use crate::DestructivePromptChoice;
use crate::RECOVER_CONFIRM_BUTTON_ID;
use crate::destructive_prompt_choice;
use crate::i18n::runtime::{self as rt, Text as RT};
use crate::rename::FileJournal;
use crate::rename::JournalOpenFailure;
use crate::rename::RecoveryOutcome;
use crate::rename::RenameRecovery;
use crate::rename::WindowsRenameBackend;
use std::io;
use std::path::PathBuf;
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::PostMessageW;
use windows_sys::Win32::UI::WindowsAndMessaging::WM_CLOSE;

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
        || RT::NoRetainedActive.get().to_owned(),
        |journal| {
            rt::journal_details(
                &journal.path().display(),
                journal.byte_len(),
                journal.records().len(),
            )
        },
    );
    let buttons = [TaskDialogButtonSpec {
        id: RECOVER_CONFIRM_BUTTON_ID,
        text: RT::RecoverPrevious.get(),
    }];
    state.mutation_locked = true;
    state.confirmation_pending = true;
    update_controls(state);
    drop(state_lease);

    let answer = task_dialog(
        owner,
        TaskDialogSpec {
            title: RT::RecoveryConfirmTitle.get(),
            main_instruction: RT::RecoveryConfirmQuestion.get(),
            content: RT::RecoveryConfirmDetail.get(),
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
                &rt::recovery_dialog_failed(&error),
                RT::RecoveryDeferredTitle.get(),
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
            RT::RecoveryStateChanged.get(),
            RT::RecoveryRejectedTitle.get(),
        );
        return;
    }

    let presentation = recover_confirmed_active_journal(state);
    update_controls(state);
    drop(state_lease);
    let caption = if presentation.completed {
        RT::RecoveryCompletedTitle.get()
    } else {
        RT::RecoveryNeedsReviewTitle.get()
    };
    message(owner, &presentation.status, caption);
}

pub(super) fn recover_confirmed_active_journal(state: &mut AppState) -> ActiveRecoveryPresentation {
    if !state.can_confirm_active_recovery() {
        return ActiveRecoveryPresentation {
            status: RT::RecoveryCannotStart.get().to_owned(),
            completed: false,
        };
    }
    let Some(mut journal) = state.active_journal.take() else {
        return ActiveRecoveryPresentation {
            status: RT::NoActiveToRecover.get().to_owned(),
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
                RT::RecoveredButCleanupFailed.get().to_owned()
            } else if recovered {
                RT::RecoveredAndCleaned.get().to_owned()
            } else if cleanup_failed {
                RT::VerifiedButCleanupFailed.get().to_owned()
            } else {
                RT::VerifiedAndCleaned.get().to_owned()
            };
            if let Some(error) = cleanup.error {
                status.push_str(&rt::journal_cleanup_failed(&error));
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
            let status = rt::recovery_blocked(&reason);
            state.active_journal = Some(journal);
            state.recovery_locked = true;
            state.ui_status.set_recovery(status.clone());
            ActiveRecoveryPresentation {
                status,
                completed: false,
            }
        }
        RecoveryOutcome::RecoveryRequired { reason, .. } => {
            let status = rt::recovery_incomplete(&reason);
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
            RT::NoRetainedHandle.get(),
            RT::RecoveryExportUnavailableTitle.get(),
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
            state.set_transient_status(RT::RecoveryExportStateChanged.get());
        }
        return;
    }
    let presentation = perform_recovery_export(state, &directory);
    drop(state_lease);
    queue_deferred_message(owner, presentation.text, presentation.caption.to_owned());
}

fn perform_recovery_export(
    state: &mut AppState,
    directory: &PreparedRecoveryExportDirectory,
) -> RecoveryExportPresentation {
    let mut results = Vec::new();
    let mut failures = 0_usize;
    if let Some(journal) = state.active_journal.as_mut() {
        export_valid_journal(
            journal,
            directory,
            "active.drj.retained",
            &mut results,
            &mut failures,
        );
    }
    if let Some(journal) = state.staged_journal.as_mut() {
        export_valid_journal(
            journal,
            directory,
            "candidate.drj.retained",
            &mut results,
            &mut failures,
        );
    }
    for blocked in &mut state.blocked_journals {
        let role = blocked.role();
        let Some(evidence) = blocked.evidence_mut() else {
            failures = failures.saturating_add(1);
            results.push(rt::export_skipped_no_handle(&role));
            continue;
        };
        let name = match role {
            JournalRole::Active => "active.drj.evidence",
            JournalRole::Candidate => "candidate.drj.evidence",
        };
        let path = directory.display_path.join(name);
        let copy = directory
            .parent
            .create_new_file(std::ffi::OsStr::new(name))
            .and_then(|mut output| evidence.copy_exact_to_file(&mut output));
        match copy {
            Ok(bytes) => results.push(format!("{bytes} bytes: {}", path.display())),
            Err(error) => {
                failures = failures.saturating_add(1);
                results.push(rt::export_failed(&path.display(), &error));
            }
        }
    }
    let caption = if failures == 0 {
        RT::RecoveryExportCompleteTitle.get()
    } else {
        RT::RecoveryExportPartialTitle.get()
    };
    RecoveryExportPresentation {
        text: results.join("\n"),
        caption,
    }
}

pub(super) fn export_valid_journal(
    journal: &mut FileJournal,
    directory: &PreparedRecoveryExportDirectory,
    leaf: &str,
    results: &mut Vec<String>,
    failures: &mut usize,
) {
    let path = directory.display_path.join(leaf);
    let copy = directory
        .parent
        .create_new_file(std::ffi::OsStr::new(leaf))
        .and_then(|mut output| journal.copy_exact_to_file(&mut output));
    match copy {
        Ok(bytes) => results.push(format!("{bytes} bytes: {}", path.display())),
        Err(error) => {
            *failures = failures.saturating_add(1);
            results.push(rt::export_failed(&path.display(), &error));
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
            RT::DiscardNotAllowed.get(),
            RT::DiscardRejectedTitle.get(),
        );
        return None;
    }
    let staged = state.staged_journal.as_ref()?;
    let journal_path = staged.path().to_path_buf();
    let journal_bytes = staged.byte_len();
    let journal_records = staged.records().to_vec();
    let detail = rt::journal_details(
        &journal_path.display(),
        journal_bytes,
        journal_records.len(),
    );
    let session = begin_prepared_task_dialog(state)?;
    update_controls(state);
    Some(PreparedDiscardTaskDialog {
        session,
        spec: PreparedTaskDialogSpec {
            title: RT::DiscardConfirmTitle.get().to_owned(),
            main_instruction: RT::DiscardConfirmQuestion.get().to_owned(),
            content: RT::DiscardConfirmDetail.get().to_owned(),
            expanded_information: Some(detail),
            text_details: None,
            buttons: vec![PreparedTaskDialogButton {
                id: DISCARD_CONFIRM_BUTTON_ID,
                text: RT::DiscardButton.get().to_owned(),
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
                RT::DiscardStateChanged.get(),
                RT::DiscardRejectedTitle.get(),
            );
        }
        return;
    }
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => {
            message(
                owner,
                &rt::discard_dialog_failed(&error),
                RT::DiscardCancelledTitle.get(),
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
            RT::DiscardStateChanged.get(),
            RT::DiscardRejectedTitle.get(),
        );
        return;
    }
    let Some(mut staged) = state.staged_journal.take() else {
        message(
            owner,
            RT::NoJournalToDiscard.get(),
            RT::DiscardRejectedTitle.get(),
        );
        return;
    };
    if let Err(error) = staged.mark_unactivated_intent_delete() {
        state.staged_journal = Some(staged);
        state.recovery_locked = true;
        message(
            owner,
            &rt::discard_journal_failed(&error),
            RT::DiscardFailedTitle.get(),
        );
        update_controls(state);
        return;
    }
    drop(staged);
    rediscover_after_staged_discard(state);
    if state.recovery_locked {
        message(
            owner,
            RT::OtherRecoveryAfterDiscard.get(),
            RT::RecoveryStateReviewTitle.get(),
        );
    } else {
        state.clear_recovery_status();
        state.set_transient_status(RT::DiscardedNoChange.get());
        message(
            owner,
            RT::DiscardedApplyAvailable.get(),
            RT::DiscardCompleteTitle.get(),
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
        lines.push(RT::RecoveryCollisionStatus.get().to_owned());
    } else if state.recovery_locked {
        lines.push(RT::RecoveryLockedStatus.get().to_owned());
    } else {
        lines.push(RT::NoRecoveryJournalStatus.get().to_owned());
    }
    if let Some(journal) = state.active_journal.as_ref() {
        lines.push(rt::recovery_active_detail(
            &journal.path().display(),
            journal.byte_len(),
            journal.records().len(),
        ));
    }
    if let Some(journal) = state.staged_journal.as_ref() {
        let kind = if journal.is_complete_intent_candidate() {
            RT::CompleteIntentOnly.get()
        } else if journal.is_physically_empty_candidate() {
            RT::EmptyCandidate.get()
        } else {
            RT::UndiscardableCandidate.get()
        };
        lines.push(rt::recovery_candidate_detail(
            &journal.path().display(),
            journal.byte_len(),
            kind,
        ));
    }
    lines.extend(
        state
            .blocked_journals
            .iter()
            .map(StartupJournalBlock::status_korean),
    );
    if state.can_export_recovery_journal() {
        lines.push(RT::ExportRecoveryAvailable.get().to_owned());
    }
    if state.can_confirm_active_recovery() {
        lines.push(RT::ConfirmRecoveryAvailable.get().to_owned());
        lines.push(crate::active_recovery_status_guidance().to_owned());
    }
    if state.can_discard_staged_intent() {
        lines.push(RT::DiscardUnusedJournalAvailable.get().to_owned());
    }
    message(owner, &lines.join("\n"), RT::RecoveryStatusTitle.get());
}
