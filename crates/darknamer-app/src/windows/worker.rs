use super::{
    ACTIVE_JOURNAL_LEAF, APPLY_POLL_TIMER_ID, AppState, CANCEL_WORKER_ID, CANDIDATE_JOURNAL_LEAF,
    GuiAcceptanceClock, PREFERENCES_POLL_TIMER_ID, PreparedTaskDialogButton,
    PreparedTaskDialogDisposition, PreparedTaskDialogPolicy, PreparedTaskDialogSession,
    PreparedTaskDialogSpec, PreparedTextDetails, TEXT_DETAILS_BUTTON_ID, WM_APP_ADMISSION_COMPLETE,
    WM_APP_APPLY_COMPLETE, WM_APP_APPLY_PROGRESS, WM_APP_FINISH_CLOSE, WM_APP_IMPORT_COMPLETE,
    WM_APP_PLAN_COMPLETE, WM_APP_PREFERENCES_WAKE, apply_cancel_control_state,
    begin_prepared_task_dialog, cleanup_file_journal, clear_selection, compare_windows,
    finish_import_worker_result, legacy_path, message, path_wide, proposal_mutation_error_message,
    read_legacy_text_cancellable, refresh, schedule_focus_target, schedule_icon_poll, select_rows,
    selected_indices, take_prepared_task_dialog, try_app_state, update_controls,
};
use crate::APPLY_CONFIRM_BUTTON_ID;
use crate::ActiveWorkerKind;
use crate::ApplyConfirmationSummary;
use crate::DIRECTORY_DIRECT_BUTTON_ID;
use crate::DIRECTORY_RECURSE_BUTTON_ID;
use crate::DestructivePromptChoice;
use crate::DirectoryPromptChoice;
use crate::i18n::runtime::{self as rt, Text as RT};

use crate::active_worker_kind;
use crate::admission::AdmissionAdapter;
use crate::admission::AdmissionMode;
use crate::admission::AdmissionReport;
use crate::admission::MAX_ADMITTED_SOURCES;
use crate::admission::PathBudget;
use crate::admission::PathBudgetReservation;
use crate::admission::WindowsAdmissionAdapter;
use crate::apply_confirmation_detail;
use crate::apply_confirmation_examples;
use crate::apply_confirmation_primary;
use crate::apply_confirmation_scope;
use crate::cancel_control_state;
use crate::destructive_prompt_choice;
use crate::directory_prompt_choice;
use crate::preferences::AppearancePreferencesWriter;
use crate::preferences::PreferencesWriter;
use crate::preferences::lifecycle::PreferencePersistence;
use crate::rename::CancellationToken;
use crate::rename::ExecuteError;
use crate::rename::ExecuteErrorKind;
use crate::rename::ExecutionControl;
use crate::rename::ExecutionOutcome;
use crate::rename::ExecutionOutcomePresentation;
use crate::rename::ExecutionPhase;
use crate::rename::ExecutionProgress;
use crate::rename::ExecutionReport;
use crate::rename::FileJournal;
use crate::rename::FileJournalError;
use crate::rename::ModelRevision;
use crate::rename::PlanAttemptError;
use crate::rename::PlanError;
use crate::rename::RenameBackend;
use crate::rename::RenameExecutor;
use crate::rename::RenamePlan;
use crate::rename::RenamePlanner;
use crate::rename::WindowsRenameBackend;
use crate::rename::apply_execution_report;
use crate::rename::build_plan_request;
use crate::rename::execute_error_korean;
use crate::rename::execution_outcome_korean;
use crate::rename::execution_outcome_presentation;
use crate::rename::plan_error_korean;
use crate::rename::preflight_plan_cancellable;
use darknamer_core::LegacyText;
use std::io;
use std::os::windows::io::AsRawHandle;
use std::panic::AssertUnwindSafe;
use std::panic::catch_unwind;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::Ordering;
use std::sync::mpsc::Receiver;
use std::sync::mpsc::TryRecvError;
use std::sync::mpsc::sync_channel;
use std::thread;
use std::thread::JoinHandle;
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::System::IO::CancelSynchronousIo;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::IsWindowEnabled;
use windows_sys::Win32::UI::WindowsAndMessaging::GetDlgCtrlID;
use windows_sys::Win32::UI::WindowsAndMessaging::GetParent;
use windows_sys::Win32::UI::WindowsAndMessaging::IsWindowVisible;
use windows_sys::Win32::UI::WindowsAndMessaging::KillTimer;
use windows_sys::Win32::UI::WindowsAndMessaging::PostMessageW;
use windows_sys::Win32::UI::WindowsAndMessaging::SetTimer;

use crate::apply_progress::ApplyProgress;

pub(super) struct ApplyWorker {
    cancellation: Arc<CancellationToken>,
    progress: Arc<WorkerProgress>,
    receiver: Receiver<ApplyWorkerResult>,
    pub(super) handle: JoinHandle<()>,
}

pub(super) struct PlanWorker {
    cancellation: Arc<CancellationToken>,
    receiver: Receiver<PlanWorkerResult>,
    pub(super) handle: JoinHandle<()>,
}

pub(super) struct AdmissionWorker {
    cancellation: Arc<AtomicBool>,
    progress: Arc<AdmissionProgress>,
    last_rendered_progress: Option<usize>,
    receiver: Receiver<AdmissionWorkerResult>,
    pub(super) handle: JoinHandle<()>,
}

#[derive(Clone, Copy)]
pub(super) enum ImportKind {
    Names,
    Paths,
}

pub(super) struct ImportWorker {
    cancellation: Arc<AtomicBool>,
    session_id: u64,
    revision: ModelRevision,
    kind: ImportKind,
    receiver: Receiver<io::Result<LegacyText>>,
    pub(super) handle: JoinHandle<()>,
}

impl ImportWorker {
    pub(super) fn cancellation_requested(&self) -> bool {
        self.cancellation.load(Ordering::Acquire)
    }

    fn request_cancel(&self) {
        self.cancellation.store(true, Ordering::Release);
        // SAFETY: JoinHandle owns the live thread handle until retirement. This
        // requests cancellation of pending synchronous I/O; completion remains
        // asynchronous and the result is always discarded after a request.
        unsafe { CancelSynchronousIo(self.handle.as_raw_handle()) };
    }
}

pub(super) fn import_cancel_control_ready(owner: HWND, cancel: HWND) -> bool {
    if owner.is_null() || cancel.is_null() {
        return false;
    }
    // SAFETY: these are pointer-free queries of the live UI-thread owner and
    // its copied child HWND; invalid or foreign controls fail the exact parent
    // and ID checks before their availability can qualify feedback.
    unsafe {
        GetParent(cancel) == owner
            && GetDlgCtrlID(cancel) == i32::from(CANCEL_WORKER_ID)
            && IsWindowVisible(cancel) != 0
            && IsWindowEnabled(cancel) != 0
    }
}

pub(super) fn start_import_worker(
    window: HWND,
    state: &mut AppState,
    session_id: u64,
    revision: ModelRevision,
    path: PathBuf,
    kind: ImportKind,
) -> io::Result<()> {
    start_import_worker_from(
        window,
        state,
        session_id,
        revision,
        kind,
        move |cancellation| read_legacy_text_cancellable(&path, cancellation),
    )
}

pub(super) fn start_import_worker_from(
    window: HWND,
    state: &mut AppState,
    session_id: u64,
    revision: ModelRevision,
    kind: ImportKind,
    read: impl FnOnce(&AtomicBool) -> io::Result<LegacyText> + Send + 'static,
) -> io::Result<()> {
    if state.import_worker.is_some() {
        return Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            crate::i18n::runtime::Text::ImportAlreadyActive.get(),
        ));
    }
    let cancellation = Arc::new(AtomicBool::new(false));
    let (sender, receiver) = sync_channel(1);
    // SAFETY: the callback-free timer polls the live UI window if a posted
    // completion wake is lost. No worker-owned pointer crosses the boundary.
    if unsafe { SetTimer(window, APPLY_POLL_TIMER_ID, 100, None) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let window_value = window as usize;
    let worker_cancellation = Arc::clone(&cancellation);
    let handle = match thread::Builder::new()
        .name("darkrenamer-import".to_owned())
        .spawn(move || {
            let _wake = SimpleCompletionWake {
                window: window_value,
                message: WM_APP_IMPORT_COMPLETE,
            };
            let result = read(&worker_cancellation);
            let _sent = sender.send(result);
        }) {
        Ok(handle) => handle,
        Err(error) => {
            // SAFETY: no import worker is active and this is the timer we set.
            unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
            return Err(error);
        }
    };
    state.import_worker = Some(ImportWorker {
        cancellation,
        session_id,
        revision,
        kind,
        receiver,
        handle,
    });
    state.mutation_locked = true;
    state.set_progress_status(RT::ImportReading.get());
    update_controls(state);
    if matches!(kind, ImportKind::Paths) {
        // The cancel button's native visible/enabled state is a functional
        // import acknowledgment even if the transient status text is coalesced
        // away. Only the same registered Paths session may latch this event.
        let ready = state.import_worker.as_ref().is_some_and(|worker| {
            worker.session_id == session_id && matches!(worker.kind, ImportKind::Paths)
        }) && import_cancel_control_ready(window, state.cancel_worker);
        state
            .acceptance_clock
            .record_import_feedback_at(ready.then(GuiAcceptanceClock::read_tick).flatten());
    }
    Ok(())
}

pub(super) fn handle_import_completion(window: HWND, state: &mut AppState) {
    let Some(worker) = state.import_worker.as_ref() else {
        return;
    };
    if !worker.handle.is_finished() {
        if worker.cancellation_requested() {
            // Reissue on the existing 100ms poll to cover cancellation between
            // the worker's flag check and the next native synchronous call.
            worker.request_cancel();
        }
        return;
    }
    let Some(worker) = state.import_worker.take() else {
        return;
    };
    // SAFETY: this worker reached its terminal state and owns this timer.
    unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
    let joined = worker.handle.join();
    state.clear_progress_status();
    state.mutation_locked = state.close_pending
        || state.admission_worker.is_some()
        || state.plan_worker.is_some()
        || state.apply_worker.is_some();
    let cancelled = worker.cancellation.load(Ordering::Acquire);
    let result = if joined.is_err() {
        Err(io::Error::other(
            crate::i18n::runtime::Text::ImportWorkerTerminated.get(),
        ))
    } else {
        worker.receiver.try_recv().unwrap_or_else(|_| {
            Err(io::Error::other(
                crate::i18n::runtime::Text::ImportWorkerNoResult.get(),
            ))
        })
    };
    finish_import_worker_result(
        window,
        state,
        worker.session_id,
        worker.revision,
        worker.kind,
        cancelled,
        result,
    );
    update_controls(state);
    try_finish_window_close(window, state);
}

impl ApplyWorker {
    pub(super) fn is_finishing(&self) -> bool {
        self.progress.updates.is_finishing()
    }

    pub(super) fn cancellation_requested(&self) -> bool {
        self.cancellation.is_requested()
    }
}

#[cfg(test)]
pub(super) fn start_held_apply_worker_for_test(
    window: HWND,
    state: &mut AppState,
    wait: impl FnOnce() + Send + 'static,
) -> io::Result<()> {
    let journal = FileJournal::create_candidate(
        &state.journal_root,
        CANDIDATE_JOURNAL_LEAF,
        ACTIVE_JOURNAL_LEAF,
    )
    .map_err(|error| io::Error::other(error.to_string()))?;
    let cancellation = Arc::new(CancellationToken::new());
    let progress = Arc::new(WorkerProgress::new(window));
    let (sender, receiver) = sync_channel(1);
    // SAFETY: this test owns the live top-level window and the callback-free
    // timer has the same owner and lifetime as a production Apply timer.
    if unsafe { SetTimer(window, APPLY_POLL_TIMER_ID, 100, None) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let handle = match thread::Builder::new()
        .name("darkrenamer-test-held-apply".to_owned())
        .spawn(move || {
            wait();
            let result = ApplyWorkerResult::Executed {
                journal: Box::new(journal),
                execution: Err(ExecuteError {
                    entry: None,
                    kind: ExecuteErrorKind::Cancelled,
                }),
            };
            let _sent = sender.send(result);
        }) {
        Ok(handle) => handle,
        Err(error) => {
            // SAFETY: this exact test timer was installed above.
            unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
            return Err(error);
        }
    };
    state.apply_worker = Some(ApplyWorker {
        cancellation,
        progress,
        receiver,
        handle,
    });
    state.mutation_locked = true;
    Ok(())
}

impl PlanWorker {
    pub(super) fn cancellation_requested(&self) -> bool {
        self.cancellation.is_requested()
    }
}

impl AdmissionWorker {
    pub(super) fn cancellation_requested(&self) -> bool {
        self.cancellation.load(Ordering::Acquire)
    }
}

const ADMISSION_PROGRESS_COLLECTING_FLAG: usize = 1 << (usize::BITS - 1);
const ADMISSION_PROGRESS_COUNT_MASK: usize = !ADMISSION_PROGRESS_COLLECTING_FLAG;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum AdmissionProgressPhase {
    SelectingMode,
    Collecting,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct AdmissionProgressSnapshot {
    phase: AdmissionProgressPhase,
    inspected: usize,
}

pub(super) struct AdmissionProgress {
    snapshot: AtomicUsize,
}

impl AdmissionProgress {
    fn new(phase: AdmissionProgressPhase) -> Self {
        Self {
            snapshot: AtomicUsize::new(Self::encode(phase, 0)),
        }
    }

    const fn encode(phase: AdmissionProgressPhase, inspected: usize) -> usize {
        let inspected = inspected & ADMISSION_PROGRESS_COUNT_MASK;
        match phase {
            AdmissionProgressPhase::SelectingMode => inspected,
            AdmissionProgressPhase::Collecting => ADMISSION_PROGRESS_COLLECTING_FLAG | inspected,
        }
    }

    const fn decode(snapshot: usize) -> AdmissionProgressSnapshot {
        AdmissionProgressSnapshot {
            phase: if snapshot & ADMISSION_PROGRESS_COLLECTING_FLAG == 0 {
                AdmissionProgressPhase::SelectingMode
            } else {
                AdmissionProgressPhase::Collecting
            },
            inspected: snapshot & ADMISSION_PROGRESS_COUNT_MASK,
        }
    }

    fn publish(&self, phase: AdmissionProgressPhase, inspected: usize) {
        self.snapshot
            .store(Self::encode(phase, inspected), Ordering::Release);
    }

    fn load(&self) -> (usize, AdmissionProgressSnapshot) {
        let encoded = self.snapshot.load(Ordering::Acquire);
        (encoded, Self::decode(encoded))
    }
}

pub(super) fn start_preferences_writers(window: HWND, state: &mut AppState) {
    let columns = if state.column_preferences_authorized {
        let window_value = window as usize;
        match PreferencesWriter::spawn(state.column_preferences_path.clone(), move || {
            // SAFETY: this scalar HWND carries no borrowed data in the wake.
            unsafe { PostMessageW(window_value as HWND, WM_APP_PREFERENCES_WAKE, 0, 0) };
        }) {
            Ok(writer) => Some(writer),
            Err(error) => {
                state.set_transient_status(rt::column_writer_start_failed(&error));
                None
            }
        }
    } else {
        None
    };
    let appearance = if state.appearance_preferences_authorized {
        let window_value = window as usize;
        match AppearancePreferencesWriter::spawn(
            state.appearance_preferences_path.clone(),
            move || {
                // SAFETY: this scalar HWND carries no borrowed data in the wake.
                unsafe { PostMessageW(window_value as HWND, WM_APP_PREFERENCES_WAKE, 0, 0) };
            },
        ) {
            Ok(writer) => Some(writer),
            Err(error) => {
                state.set_transient_status(rt::appearance_writer_start_failed(&error));
                None
            }
        }
    } else {
        None
    };
    state.preference_persistence = PreferencePersistence::new(columns, appearance);
    if state.preference_persistence.is_joined() {
        return;
    }
    // SAFETY: the timer belongs to the live top-level window and supplies a
    // loss-safe completion poll if a coalesced PostMessageW wake is missed.
    if unsafe { SetTimer(window, PREFERENCES_POLL_TIMER_ID, 250, None) } == 0 {
        state.set_transient_status(rt::column_writer_timer_failed(&io::Error::last_os_error()));
    }
}

fn drain_preferences_events(state: &mut AppState) {
    for message in state.preference_persistence.drain(state.close_pending) {
        state.set_transient_status(message);
    }
    if let Some(preference) = state.preference_persistence.take_saved_language() {
        state.language_preference = preference;
        update_controls(state);
    }
}

pub(super) fn handle_preferences_wake(window: HWND, state: &mut AppState) {
    drain_preferences_events(state);
    try_finish_window_close(window, state);
}

pub(super) enum AdmissionWorkerResult {
    NeedsDirectoryMode {
        revision: ModelRevision,
        paths: Vec<PathBuf>,
        capacity: usize,
        directory: PathBuf,
    },
    Finished {
        revision: ModelRevision,
        report: AdmissionReport,
    },
    Cancelled,
    Panicked,
}

pub(super) enum PlanWorkerResult {
    Finished {
        revision: ModelRevision,
        plan: Result<ReadyPlan, ReadyPlanError>,
    },
    Cancelled,
    Panicked,
}

pub(super) struct ReadyPlan {
    plan: RenamePlan,
    summary: ApplyConfirmationSummary,
}

pub(super) enum ReadyPlanError {
    Plan(PlanError),
    Preflight(ExecuteError),
    Summary,
}

pub(super) enum PreparedWorkerTaskDialog {
    Apply(PreparedApplyTaskDialog),
    Directory(PreparedDirectoryTaskDialog),
}

pub(super) struct PreparedApplyTaskDialog {
    session: PreparedTaskDialogSession,
    spec: PreparedTaskDialogSpec,
    revision: ModelRevision,
    fingerprint: u64,
    plan: RenamePlan,
}

pub(super) struct PreparedDirectoryTaskDialog {
    session: PreparedTaskDialogSession,
    spec: PreparedTaskDialogSpec,
    revision: ModelRevision,
    paths: Vec<PathBuf>,
    capacity: usize,
}

pub(super) enum ApplyWorkerResult {
    JournalCreateFailed(FileJournalError),
    Executed {
        journal: Box<FileJournal>,
        execution: Result<ExecutionReport, ExecuteError>,
    },
    Panicked,
}

pub(super) struct WorkerProgress {
    updates: ApplyProgress,
    window: usize,
}

impl WorkerProgress {
    fn new(window: HWND) -> Self {
        Self {
            updates: ApplyProgress::new(),
            window: window as usize,
        }
    }

    fn publish(&self, progress: ExecutionProgress) {
        if self.updates.publish(progress) {
            self.post(WM_APP_APPLY_PROGRESS);
        }
    }

    fn post(&self, message: u32) {
        // SAFETY: window is the integer form of the top-level HWND captured
        // before spawning. The message carries no pointer payload.
        unsafe { PostMessageW(self.window as HWND, message, 0, 0) };
    }
}

pub(super) struct WorkerExecutionControl {
    cancellation: Arc<CancellationToken>,
    progress: Arc<WorkerProgress>,
}

pub(super) struct CompletionWake {
    progress: Arc<WorkerProgress>,
}

pub(super) struct SimpleCompletionWake {
    window: usize,
    message: u32,
}

impl Drop for SimpleCompletionWake {
    fn drop(&mut self) {
        // SAFETY: window is the integer form of the top-level HWND captured
        // before spawning. The message carries no pointer payload.
        unsafe { PostMessageW(self.window as HWND, self.message, 0, 0) };
    }
}

impl Drop for CompletionWake {
    fn drop(&mut self) {
        self.progress.post(WM_APP_APPLY_COMPLETE);
    }
}

impl ExecutionControl for WorkerExecutionControl {
    fn cancellation_requested(&self) -> bool {
        self.cancellation.is_requested()
    }

    fn begin_transaction(&self) -> bool {
        ExecutionControl::begin_transaction(self.cancellation.as_ref())
    }

    fn progress(&self, progress: ExecutionProgress) {
        self.progress.publish(progress);
    }
}

fn preview_is_ready_for_apply(window: HWND, state: &AppState) -> bool {
    if !state.preview_synchronization.is_synchronized() {
        message(
            window,
            crate::i18n::common::Text::PreviewSyncBlocked.get(),
            RT::ApplyBlockedTitle.get(),
        );
        false
    } else {
        true
    }
}

pub(super) fn apply_changes(window: HWND, state: &mut AppState) {
    // Capture entry before validation, but publish only for a command admitted
    // to planning; a busy/rejected click must not erase a live operation's clock.
    let entered_at = GuiAcceptanceClock::read_tick();
    if !preview_is_ready_for_apply(window, state) {
        return;
    }
    if state.preview_issue_cache.has_blocker() {
        let blocker_explanation = state
            .preview_issue_cache
            .blocker_explanation()
            .unwrap_or(RT::FixDisplayedDestination.get());
        clear_selection(state.list_window);
        select_rows(state.list_window, &state.preview_issue_cache.blocker_rows());
        update_controls(state);
        message(window, blocker_explanation, RT::ApplyBlockedTitle.get());
        return;
    }
    if state.apply_locked() {
        message(window, RT::ApplyBusy.get(), "DarkReNamer");
        return;
    }
    state.acceptance_clock.record_apply_at(entered_at);
    let revision = state.revision();
    let request = build_plan_request(&state.model, revision);
    start_plan_worker(window, state, revision, request);
}

pub(super) fn handle_ready_plan(
    window: HWND,
    state: &mut AppState,
    revision: ModelRevision,
    plan: Result<ReadyPlan, ReadyPlanError>,
) -> Option<PreparedWorkerTaskDialog> {
    let ready = match plan {
        Ok(ready) => ready,
        Err(ReadyPlanError::Plan(error)) => {
            let (message_text, rows) = plan_error_korean(&error);
            {
                clear_selection(state.list_window);
                select_rows(state.list_window, &rows);
                update_controls(state);
                message(window, &message_text, RT::ApplyBlockedTitle.get());
            }
            return None;
        }
        Err(ReadyPlanError::Preflight(error)) => {
            message(
                window,
                &execute_error_korean(&error),
                RT::ApplyBlockedTitle.get(),
            );
            return None;
        }
        Err(ReadyPlanError::Summary) => {
            message(
                window,
                RT::PlanSummaryMismatch.get(),
                RT::ApplyBlockedTitle.get(),
            );
            return None;
        }
    };
    if !preview_is_ready_for_apply(window, state) {
        return None;
    }
    let plan = ready.plan;
    if plan.is_empty() {
        message(window, RT::NothingToChange.get(), "DarkReNamer");
        return None;
    }
    let primary = rt::apply_confirmation_content(
        &apply_confirmation_scope(
            state.model.items().len(),
            selected_indices(state.list_window).len(),
            ready.summary.logical_changed(),
        ),
        &apply_confirmation_primary(&ready.summary),
        &apply_confirmation_examples(&plan, false),
    );
    let detail =
        apply_confirmation_detail(&ready.summary, plan.fingerprint(), state.model_revision);
    let text_details = PreparedTextDetails {
        caption: RT::ApplyFullDetailsTitle.get().to_owned(),
        text: apply_confirmation_examples(&plan, true),
        appearance: state.prompt_appearance(),
    };
    let fingerprint = plan.fingerprint();
    let session = begin_prepared_task_dialog(state)?;
    update_controls(state);
    Some(PreparedWorkerTaskDialog::Apply(PreparedApplyTaskDialog {
        session,
        spec: PreparedTaskDialogSpec {
            title: RT::ApplyConfirmTitle.get().to_owned(),
            main_instruction: RT::ApplyConfirmQuestion.get().to_owned(),
            content: primary,
            expanded_information: Some(detail),
            text_details: Some(text_details),
            buttons: vec![
                PreparedTaskDialogButton {
                    id: APPLY_CONFIRM_BUTTON_ID,
                    text: RT::ApplyButton.get().to_owned(),
                },
                PreparedTaskDialogButton {
                    id: TEXT_DETAILS_BUTTON_ID,
                    text: RT::ApplyFullDetailsButton.get().to_owned(),
                },
            ],
            warning: true,
        },
        revision,
        fingerprint,
        plan,
    }))
}

fn run_prepared_apply_task_dialog(
    window: HWND,
    prepared: PreparedApplyTaskDialog,
    select: impl FnOnce(HWND, &PreparedTaskDialogSpec) -> io::Result<i32>,
) {
    let answer = select(window, &prepared.spec);
    // The native choice has returned to the owner thread here. This is not
    // the button callback time; the exact live session is checked below.
    let returned_at = GuiAcceptanceClock::read_tick();
    let Some(mut state_lease) = try_app_state(window) else {
        return;
    };
    let state = state_lease.state_mut();
    let disposition =
        take_prepared_task_dialog(state, prepared.session, PreparedTaskDialogPolicy::Mutable);
    if disposition == PreparedTaskDialogDisposition::Accepted
        && answer.as_ref().is_ok_and(|answer| {
            destructive_prompt_choice(*answer, APPLY_CONFIRM_BUTTON_ID)
                == DestructivePromptChoice::Confirm
        })
    {
        state.acceptance_clock.record_confirmation_at(returned_at);
    }
    update_controls(state);
    if disposition == PreparedTaskDialogDisposition::Closed {
        try_finish_window_close(window, state);
        return;
    }
    if disposition != PreparedTaskDialogDisposition::Accepted {
        if disposition == PreparedTaskDialogDisposition::Rejected {
            state.set_transient_status(RT::ApplyStateChanged.get());
        }
        return;
    }
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => {
            message(
                window,
                &rt::apply_dialog_failed(&error),
                RT::ApplyCancelledTitle.get(),
            );
            return;
        }
    };
    if destructive_prompt_choice(answer, APPLY_CONFIRM_BUTTON_ID)
        != DestructivePromptChoice::Confirm
    {
        state.set_result_status(RT::ApplyNotStarted.get());
        return;
    }
    if !preview_is_ready_for_apply(window, state) {
        return;
    }
    if state.apply_locked() {
        state.set_transient_status(RT::ApplyRecoveryChanged.get());
        return;
    }
    if state.revision() != prepared.revision
        || prepared.plan.revision() != prepared.revision
        || prepared.plan.fingerprint() != prepared.fingerprint
    {
        {
            message(window, RT::ApplyListChanged.get(), "DarkReNamer")
        }
        return;
    }
    let id = prepared.plan.id();
    let plan_revision = prepared.plan.revision();
    let confirmed = match prepared.plan.confirm_presented(id, plan_revision) {
        Ok(confirmed) => confirmed,
        Err(error) => {
            message(window, &error.to_string(), "DarkReNamer");
            return;
        }
    };
    start_apply_worker(window, state, confirmed);
}

pub(super) fn run_prepared_worker_task_dialog(
    window: HWND,
    prepared: PreparedWorkerTaskDialog,
    select: impl FnOnce(HWND, &PreparedTaskDialogSpec) -> io::Result<i32>,
) {
    match prepared {
        PreparedWorkerTaskDialog::Apply(prepared) => {
            run_prepared_apply_task_dialog(window, prepared, select);
        }
        PreparedWorkerTaskDialog::Directory(prepared) => {
            run_prepared_directory_task_dialog(window, prepared, select);
        }
    }
}

pub(super) fn handle_completed_execution(
    window: HWND,
    state: &mut AppState,
    journal: FileJournal,
    execution: Result<ExecutionReport, ExecuteError>,
) {
    state.clear_progress_status();
    let report = match execution {
        Ok(report) => report,
        Err(error) => {
            let text = execute_error_korean(&error);
            let cleanup = cleanup_file_journal(journal);
            state.recovery_locked = cleanup.error.is_some() || cleanup.retained.is_some();
            state.active_journal = cleanup.retained;
            if let Some(cleanup_error) = cleanup.error {
                message(
                    window,
                    &cleanup_error.to_string(),
                    RT::JournalCleanupFailedTitle.get(),
                );
            }
            if matches!(error.kind, crate::rename::ExecuteErrorKind::Cancelled)
                && !state.recovery_locked
            {
                state.set_result_status(text);
            } else {
                if !state.recovery_locked {
                    state.set_result_status(RT::PreApplyRefused.get());
                }
                message(window, &text, RT::ExecutionRefusedTitle.get());
            }
            update_controls(state);
            return;
        }
    };
    let text = if matches!(report.outcome(), ExecutionOutcome::Completed) {
        rt::apply_completed_rows(report.entries().len())
    } else {
        execution_outcome_korean(report.outcome())
    };
    match report.outcome() {
        ExecutionOutcome::Completed => {
            let changed = !report.entries().is_empty();
            if !apply_execution_report(&mut state.model, &report) {
                state.recovery_locked = true;
                state.active_journal = Some(journal);
                message(
                    window,
                    RT::OutcomeMismatch.get(),
                    RT::ReviewNeededTitle.get(),
                );
                update_controls(state);
                return;
            }
            state.commit_known_model_change(changed);
            refresh(state);
            let cleanup = cleanup_file_journal(journal);
            state.recovery_locked = cleanup.error.is_some() || cleanup.retained.is_some();
            state.active_journal = cleanup.retained;
            if let Some(error) = cleanup.error {
                message(
                    window,
                    &error.to_string(),
                    RT::JournalCleanupFailedTitle.get(),
                );
            } else {
                state.set_result_status(text);
            }
        }
        ExecutionOutcome::RolledBack { .. } => {
            let cleanup = cleanup_file_journal(journal);
            state.recovery_locked = cleanup.error.is_some() || cleanup.retained.is_some();
            state.active_journal = cleanup.retained;
            if let Some(error) = cleanup.error {
                message(
                    window,
                    &error.to_string(),
                    RT::JournalCleanupFailedTitle.get(),
                );
            } else {
                match execution_outcome_presentation(report.outcome()) {
                    ExecutionOutcomePresentation::NonModal => state.set_result_status(text),
                    ExecutionOutcomePresentation::Modal => {
                        state.set_result_status(text.clone());
                        message(window, &text, RT::ExecutionFailedTitle.get());
                    }
                }
            }
        }
        ExecutionOutcome::RecoveryRequired { .. } => {
            state.recovery_locked = true;
            state.active_journal = Some(journal);
            message(window, &text, RT::RecoveryNeededTitle.get());
        }
    }
    update_controls(state);
}

pub(super) fn start_plan_worker(
    window: HWND,
    state: &mut AppState,
    revision: ModelRevision,
    request: crate::rename::PlanRequest,
) {
    let cancellation = Arc::new(CancellationToken::new());
    let worker_cancellation = Arc::clone(&cancellation);
    let (sender, receiver) = sync_channel(1);
    // SAFETY: window is the live top-level HWND and the timer has no callback.
    if unsafe { SetTimer(window, APPLY_POLL_TIMER_ID, 100, None) } == 0 {
        message(
            window,
            &rt::planner_timer_failed(&io::Error::last_os_error()),
            RT::ExecutionFailedTitle.get(),
        );
        return;
    }
    let window_value = window as usize;
    let handle = match thread::Builder::new()
        .name("darkrenamer-plan".to_owned())
        .spawn(move || {
            let _completion_wake = SimpleCompletionWake {
                window: window_value,
                message: WM_APP_PLAN_COMPLETE,
            };
            let result = catch_unwind(AssertUnwindSafe(|| {
                if worker_cancellation.is_requested() {
                    return PlanWorkerResult::Cancelled;
                }
                let mut backend = WindowsRenameBackend;
                let plan = match RenamePlanner::new(&backend)
                    .plan_cancellable(request, || worker_cancellation.is_requested())
                {
                    Ok(plan) => plan,
                    Err(PlanAttemptError::Cancelled) => return PlanWorkerResult::Cancelled,
                    Err(PlanAttemptError::Plan(error)) => {
                        return PlanWorkerResult::Finished {
                            revision,
                            plan: Err(ReadyPlanError::Plan(error)),
                        };
                    }
                };
                let journal = match preflight_plan_cancellable(&plan, &mut backend, || {
                    worker_cancellation.is_requested()
                }) {
                    Ok(journal) => journal,
                    Err(error) if error.kind == ExecuteErrorKind::Cancelled => {
                        return PlanWorkerResult::Cancelled;
                    }
                    Err(error) => {
                        return PlanWorkerResult::Finished {
                            revision,
                            plan: Err(ReadyPlanError::Preflight(error)),
                        };
                    }
                };
                let plan = ApplyConfirmationSummary::from_plan(
                    &plan,
                    journal.primitive_steps(),
                    |source, destination| backend.path_key(source) == backend.path_key(destination),
                )
                .map_or(Err(ReadyPlanError::Summary), |summary| {
                    Ok(ReadyPlan { plan, summary })
                });
                if worker_cancellation.is_requested() {
                    PlanWorkerResult::Cancelled
                } else {
                    PlanWorkerResult::Finished { revision, plan }
                }
            }))
            .unwrap_or(PlanWorkerResult::Panicked);
            let _sent = sender.send(result);
        }) {
        Ok(handle) => handle,
        Err(error) => {
            // SAFETY: this exact timer was installed above for the live window.
            unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
            message(
                window,
                &rt::planner_start_failed(&error),
                RT::ExecutionFailedTitle.get(),
            );
            return;
        }
    };
    state.mutation_locked = true;
    state.plan_worker = Some(PlanWorker {
        cancellation,
        receiver,
        handle,
    });
    state.set_progress_status(RT::PlanningProgress.get());
    update_controls(state);
}

pub(super) fn handle_plan_completion(
    window: HWND,
    state: &mut AppState,
) -> Option<PreparedWorkerTaskDialog> {
    let worker = state.plan_worker.as_ref()?;
    if !worker.handle.is_finished() {
        return None;
    }
    // SAFETY: this exact timer belongs to the live top-level window and the
    // planning thread has reached its terminal state.
    unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
    let worker = state.plan_worker.take()?;
    apply_cancel_control_state(state);
    let joined = worker.handle.join();
    state.mutation_locked = false;
    state.clear_progress_status();
    if state.close_pending {
        try_finish_window_close(window, state);
        return None;
    }
    if joined.is_err() {
        message(
            window,
            RT::PlannerCrashed.get(),
            RT::PlanningErrorTitle.get(),
        );
        update_controls(state);
        return None;
    }
    let prepared = match worker.receiver.try_recv() {
        Ok(PlanWorkerResult::Finished { revision, plan }) => {
            let prepared = handle_ready_plan(window, state, revision, plan);
            if state.close_pending {
                try_finish_window_close(window, state);
                return None;
            }
            prepared
        }
        Ok(PlanWorkerResult::Cancelled) => {
            state.set_transient_status(RT::PlanningCancelled.get());
            None
        }
        Ok(PlanWorkerResult::Panicked) => {
            message(
                window,
                RT::PlannerInternalError.get(),
                RT::PlanningErrorTitle.get(),
            );
            None
        }
        Err(TryRecvError::Empty | TryRecvError::Disconnected) => {
            message(
                window,
                RT::PlannerNoResult.get(),
                RT::PlanningNoResultTitle.get(),
            );
            None
        }
    };
    update_controls(state);
    prepared
}

pub(super) fn start_apply_worker(
    window: HWND,
    state: &mut AppState,
    confirmed: crate::rename::ConfirmedPlan,
) {
    let root = match state.journal_root.try_clone() {
        Ok(root) => root,
        Err(error) => {
            state.recovery_locked = true;
            message(
                window,
                &rt::journal_root_transfer_failed(&error),
                RT::ApplyLockedTitle.get(),
            );
            update_controls(state);
            return;
        }
    };
    let cancellation = Arc::new(CancellationToken::new());
    let progress = Arc::new(WorkerProgress::new(window));
    let control = WorkerExecutionControl {
        cancellation: Arc::clone(&cancellation),
        progress: Arc::clone(&progress),
    };
    let (sender, receiver) = sync_channel(1);
    let worker_progress = Arc::clone(&progress);
    // SAFETY: window is the live top-level HWND and the timer carries no
    // callback pointer; WM_TIMER is handled on this UI thread.
    if unsafe { SetTimer(window, APPLY_POLL_TIMER_ID, 100, None) } == 0 {
        message(
            window,
            &rt::apply_worker_timer_failed(&io::Error::last_os_error()),
            RT::ExecutionFailedTitle.get(),
        );
        return;
    }
    let handle = match thread::Builder::new()
        .name("darkrenamer-apply".to_owned())
        .spawn(move || {
            let _completion_wake = CompletionWake {
                progress: Arc::clone(&worker_progress),
            };
            let result = catch_unwind(AssertUnwindSafe(|| {
                match FileJournal::create_candidate(
                    &root,
                    CANDIDATE_JOURNAL_LEAF,
                    ACTIVE_JOURNAL_LEAF,
                ) {
                    Ok(mut journal) => {
                        let mut backend = WindowsRenameBackend;
                        let execution = RenameExecutor::new(&mut backend, &mut journal)
                            .execute_with_control(confirmed, &control);
                        ApplyWorkerResult::Executed {
                            journal: Box::new(journal),
                            execution,
                        }
                    }
                    Err(error) => ApplyWorkerResult::JournalCreateFailed(error),
                }
            }))
            .unwrap_or(ApplyWorkerResult::Panicked);
            let _sent = sender.send(result);
        }) {
        Ok(handle) => handle,
        Err(error) => {
            // SAFETY: this exact timer was installed above for the live window.
            unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
            message(
                window,
                &rt::apply_worker_start_failed(&error),
                RT::ExecutionFailedTitle.get(),
            );
            return;
        }
    };
    state.mutation_locked = true;
    state.apply_worker = Some(ApplyWorker {
        cancellation,
        progress,
        receiver,
        handle,
    });
    state.set_progress_status(RT::ExecutionOrderProgress.get());
    update_controls(state);
}

pub(super) fn handle_apply_progress(state: &mut AppState) {
    let Some(worker) = state.apply_worker.as_ref() else {
        return;
    };
    let ExecutionProgress {
        phase,
        completed,
        total,
    } = worker.progress.updates.take_update();
    let cancellation_requested = worker.cancellation.is_requested();
    let text = match (phase, cancellation_requested) {
        (ExecutionPhase::Ready | ExecutionPhase::Forward, true) => {
            rt::apply_cancel_requested(completed, total)
        }
        (ExecutionPhase::Ready, _) => rt::apply_ready(total),
        (ExecutionPhase::Forward, _) => rt::apply_forward(completed, total),
        (ExecutionPhase::Rollback, _) => rt::apply_rollback(completed, total),
        (ExecutionPhase::Terminal, _) => RT::ReflectingResult.get().to_owned(),
        (ExecutionPhase::Finalizing, _) => RT::FinalizingResult.get().to_owned(),
    };
    state.set_progress_status(text);
    if matches!(
        phase,
        ExecutionPhase::Rollback | ExecutionPhase::Terminal | ExecutionPhase::Finalizing
    ) {
        apply_cancel_control_state(state);
    }
}

pub(super) fn handle_apply_completion(window: HWND, state: &mut AppState) {
    let Some(worker) = state.apply_worker.as_ref() else {
        return;
    };
    if !worker.handle.is_finished() {
        return;
    }
    // SAFETY: this exact timer belongs to the live top-level window and the
    // worker has reached its terminal thread state.
    unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
    let Some(worker) = state.apply_worker.take() else {
        return;
    };
    apply_cancel_control_state(state);
    finalize_apply_worker(window, state, worker);
    if state.close_pending {
        try_finish_window_close(window, state);
    }
}

pub(super) fn finalize_apply_worker(window: HWND, state: &mut AppState, worker: ApplyWorker) {
    let joined = worker.handle.join();
    state.mutation_locked = false;
    state.clear_progress_status();
    if joined.is_err() {
        state.recovery_locked = true;
        message(
            window,
            RT::ApplyWorkerCrashed.get(),
            RT::WorkerErrorTitle.get(),
        );
    } else {
        match worker.receiver.try_recv() {
            Ok(ApplyWorkerResult::JournalCreateFailed(error)) => {
                state.recovery_locked = true;
                message(
                    window,
                    &rt::active_journal_create_failed(&error),
                    RT::ApplyLockedTitle.get(),
                );
            }
            Ok(ApplyWorkerResult::Executed { journal, execution }) => {
                handle_completed_execution(window, state, *journal, execution);
            }
            Ok(ApplyWorkerResult::Panicked) => {
                state.recovery_locked = true;
                message(
                    window,
                    RT::ApplyWorkerInternalError.get(),
                    RT::WorkerPanicTitle.get(),
                );
            }
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => {
                state.recovery_locked = true;
                message(
                    window,
                    RT::ApplyWorkerNoTerminal.get(),
                    RT::WorkerNoResultTitle.get(),
                );
            }
        }
    }
    if state.recovery_locked {
        state.set_recovery_status(RT::RecoveryLockedForReview.get());
    }
    update_controls(state);
}

/// Prompt cancellation is separate from the terminal joins below: a blocked
/// Shell lookup must not postpone cancellation of an active rename operation.
pub(super) fn request_worker_shutdown_after_message_loop_failure(window: HWND) {
    let Some(mut state_lease) = try_app_state(window) else {
        return;
    };
    let state = state_lease.state_mut();
    state.close_pending = true;
    state.mutation_locked = true;
    if let Some(shared) = &state.icon_shared {
        shared.request_retire();
    }
    if let Some(worker) = &state.admission_worker {
        worker.cancellation.store(true, Ordering::Release);
    }
    if let Some(worker) = &state.import_worker {
        worker.request_cancel();
    }
    if let Some(worker) = &state.plan_worker {
        worker.cancellation.request();
    }
    if let Some(worker) = &state.apply_worker {
        worker.cancellation.request();
    }
    let _messages = state
        .preference_persistence
        .shutdown(state.column_states, state.appearance);
}

pub(super) fn finish_apply_after_message_loop_failure(window: HWND) {
    let Some(mut state_lease) = try_app_state(window) else {
        return;
    };
    let state = state_lease.state_mut();
    if let Some(worker) = state.admission_worker.take() {
        worker.cancellation.store(true, Ordering::Release);
        // SAFETY: this exact timer belongs to the still-live top-level window.
        unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
        let _joined = worker.handle.join();
        state.mutation_locked = false;
    }
    if let Some(worker) = state.import_worker.take() {
        worker.request_cancel();
        // If the message pump failed, an import provider may never return.
        // Abort this already-failed process rather than block the UI thread or
        // release the runtime lock while that thread still runs. Process exit
        // terminates every thread and closes the lock together.
        if !worker.handle.is_finished() {
            std::process::abort();
        }
        let _joined = worker.handle.join();
    }
    if let Some(worker) = state.plan_worker.take() {
        worker.cancellation.request();
        // SAFETY: this exact timer belongs to the still-live top-level window.
        unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
        let _joined = worker.handle.join();
        state.mutation_locked = false;
    }
    if let Some(worker) = state.apply_worker.take() {
        worker.cancellation.request();
        // SAFETY: this exact timer belongs to the still-live top-level window.
        unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
        finalize_apply_worker(window, state, worker);
    }
    state
        .preference_persistence
        .shutdown_and_join(state.column_states, state.appearance);
    // SAFETY: this exact timer belongs to the still-live top-level window.
    unsafe { KillTimer(window, PREFERENCES_POLL_TIMER_ID) };
    if state.close_pending {
        state.close_pending = false;
    }
}

fn request_preferences_shutdown(state: &mut AppState) {
    for message in state
        .preference_persistence
        .shutdown(state.column_states, state.appearance)
    {
        state.set_transient_status(message);
    }
}

pub(super) fn try_finish_window_close(window: HWND, state: &mut AppState) {
    if !state.close_pending
        || state
            .icon_shared
            .as_ref()
            .is_some_and(|shared| !shared.is_joined())
        || state.confirmation_pending
        || state.active_prompt.is_some()
        || state.admission_worker.is_some()
        || state.import_worker.is_some()
        || state.plan_worker.is_some()
        || state.apply_worker.is_some()
    {
        return;
    }
    if !state.preference_persistence.finish_if_ready() {
        return;
    }
    // SAFETY: the message carries no pointer. The later callback rechecks the
    // close decision and releases its AppState lease before DestroyWindow.
    if unsafe { PostMessageW(window, WM_APP_FINISH_CLOSE, 0, 0) } == 0 {
        state.set_transient_status(rt::close_message_failed(&io::Error::last_os_error()));
    }
}

pub(super) fn prepare_window_close(window: HWND, state: &mut AppState) -> bool {
    if !state.close_pending
        || state
            .icon_shared
            .as_ref()
            .is_some_and(|shared| !shared.is_joined())
        || state.confirmation_pending
        || state.active_prompt.is_some()
        || state.admission_worker.is_some()
        || state.import_worker.is_some()
        || state.plan_worker.is_some()
        || state.apply_worker.is_some()
        || !state.preference_persistence.is_joined()
    {
        return false;
    }
    // SAFETY: all workers are absent and this exact timer belongs to the live
    // top-level window. The caller applies the copied decision after its lease.
    unsafe { KillTimer(window, PREFERENCES_POLL_TIMER_ID) };
    true
}

pub(super) fn request_window_close(window: HWND, state: &mut AppState) {
    if !state.close_pending {
        state.close_pending = true;
        state.mutation_locked = true;
        if let Some(shared) = &state.icon_shared {
            shared.request_retire();
            if !shared.is_joined() {
                state.set_progress_status(RT::IconShutdownProgress.get());
            }
        }
        schedule_icon_poll(state);
        request_preferences_shutdown(state);
        update_controls(state);
    }
    if state.confirmation_pending {
        return;
    }
    if let Some(worker) = state.admission_worker.as_ref() {
        if !worker.cancellation_requested() {
            worker.cancellation.store(true, Ordering::Release);
            state.set_progress_status(RT::CloseAfterPathCheck.get());
            update_controls(state);
        }
        return;
    }
    if let Some(worker) = state.import_worker.as_ref() {
        if !worker.cancellation_requested() {
            worker.request_cancel();
            state.set_progress_status(RT::CloseAfterImport.get());
            update_controls(state);
        }
        return;
    }
    if let Some(worker) = state.plan_worker.as_ref() {
        if !worker.cancellation_requested() {
            worker.cancellation.request();
            state.set_progress_status(RT::CloseAfterPlanning.get());
            update_controls(state);
        }
        return;
    }
    if let Some(worker) = state.apply_worker.as_ref() {
        if worker.is_finishing() {
            state.set_progress_status(RT::CloseAfterResult.get());
        } else if !worker.cancellation_requested() {
            worker.cancellation.request();
            state.set_progress_status(RT::CloseAndCancel.get());
            update_controls(state);
        }
        return;
    }
    try_finish_window_close(window, state);
}

pub(super) fn request_active_worker_cancel(state: &mut AppState) {
    if !cancel_control_state(state.worker_activity()).is_enabled() {
        return;
    }
    // Kind values are 1=admission, 2=import, 3=plan, 4=Apply.
    let progress = match active_worker_kind(state.worker_activity()) {
        Some(ActiveWorkerKind::Admission) => state.admission_worker.as_ref().map(|worker| {
            worker.cancellation.store(true, Ordering::Release);
            let accepted_at = GuiAcceptanceClock::read_tick();
            let (_, snapshot) = worker.progress.load();
            (1, accepted_at, admission_cancellation_status(snapshot))
        }),
        Some(ActiveWorkerKind::Import) => state.import_worker.as_ref().map(|worker| {
            worker.request_cancel();
            let accepted_at = GuiAcceptanceClock::read_tick();
            (
                2,
                accepted_at,
                RT::ImportCancellationProgress.get().to_owned(),
            )
        }),
        Some(ActiveWorkerKind::Plan) => state.plan_worker.as_ref().map(|worker| {
            worker.cancellation.request();
            let accepted_at = GuiAcceptanceClock::read_tick();
            (
                3,
                accepted_at,
                RT::PlanCancellationProgress.get().to_owned(),
            )
        }),
        Some(ActiveWorkerKind::Apply) => state.apply_worker.as_ref().map(|worker| {
            worker.cancellation.request();
            let accepted_at = GuiAcceptanceClock::read_tick();
            (
                4,
                accepted_at,
                RT::ApplyCancellationProgress.get().to_owned(),
            )
        }),
        None => None,
    };
    if let Some((kind, accepted_at, progress)) = progress {
        state
            .acceptance_clock
            .record_cancellation_at(kind, accepted_at);
        state.set_progress_status(progress);
        update_controls(state);
    }
}

pub(super) fn admit_paths(
    owner: HWND,
    state: &mut AppState,
    paths: Vec<PathBuf>,
) -> io::Result<()> {
    let capacity = MAX_ADMITTED_SOURCES.saturating_sub(state.model.len());
    start_admission_worker(owner, state, paths, None, capacity)
}

pub(super) fn start_admission_worker(
    window: HWND,
    state: &mut AppState,
    paths: Vec<PathBuf>,
    mode: Option<AdmissionMode>,
    capacity: usize,
) -> io::Result<()> {
    let revision = state.revision();
    let mut path_budget = PathBudget::new();
    for item in state.model.items() {
        if path_budget.reserve_utf16_units(item.source_path().units().len())
            == PathBudgetReservation::Exhausted
        {
            break;
        }
    }
    let cancellation = Arc::new(AtomicBool::new(false));
    let worker_cancellation = Arc::clone(&cancellation);
    let initial_progress_phase = if mode.is_some() {
        AdmissionProgressPhase::Collecting
    } else {
        AdmissionProgressPhase::SelectingMode
    };
    let progress = Arc::new(AdmissionProgress::new(initial_progress_phase));
    let worker_progress = Arc::clone(&progress);
    let (sender, receiver) = sync_channel(1);
    // SAFETY: window is the live top-level HWND and the timer has no callback.
    if unsafe { SetTimer(window, APPLY_POLL_TIMER_ID, 100, None) } == 0 {
        return Err(io::Error::other(rt::admission_timer_failed(
            &io::Error::last_os_error(),
        )));
    }
    let window_value = window as usize;
    let handle = match thread::Builder::new()
        .name("darkrenamer-admission".to_owned())
        .spawn(move || {
            let _completion_wake = SimpleCompletionWake {
                window: window_value,
                message: WM_APP_ADMISSION_COMPLETE,
            };
            let result = catch_unwind(AssertUnwindSafe(|| {
                if worker_cancellation.load(Ordering::Acquire) {
                    return AdmissionWorkerResult::Cancelled;
                }
                let adapter = WindowsAdmissionAdapter::new();
                let mode = if let Some(mode) = mode {
                    mode
                } else {
                    let mut directory = None;
                    for (index, path) in paths.iter().take(capacity).enumerate() {
                        if worker_cancellation.load(Ordering::Acquire) {
                            return AdmissionWorkerResult::Cancelled;
                        }
                        worker_progress.publish(AdmissionProgressPhase::SelectingMode, index + 1);
                        if path.is_absolute()
                            && adapter.validate_path(path).is_ok()
                            && adapter.metadata(path).is_ok_and(|metadata| {
                                metadata.is_directory && !metadata.is_reparse_point
                            })
                        {
                            directory = Some(path.clone());
                            break;
                        }
                    }
                    if let Some(directory) = directory {
                        return AdmissionWorkerResult::NeedsDirectoryMode {
                            revision,
                            paths,
                            capacity,
                            directory,
                        };
                    }
                    worker_progress.publish(AdmissionProgressPhase::Collecting, 0);
                    AdmissionMode::Direct
                };
                match crate::admission::collect_admission_cancellable_with_budget_and_progress(
                    &adapter,
                    paths,
                    mode,
                    capacity,
                    path_budget,
                    |left, right| compare_windows(&legacy_path(left), &legacy_path(right)),
                    (
                        || worker_cancellation.load(Ordering::Acquire),
                        |inspected| {
                            worker_progress.publish(AdmissionProgressPhase::Collecting, inspected);
                        },
                    ),
                ) {
                    Ok(report) => AdmissionWorkerResult::Finished { revision, report },
                    Err(_cancelled) => AdmissionWorkerResult::Cancelled,
                }
            }))
            .unwrap_or(AdmissionWorkerResult::Panicked);
            let _sent = sender.send(result);
        }) {
        Ok(handle) => handle,
        Err(error) => {
            // SAFETY: this exact timer was installed above for the live window.
            unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
            return Err(io::Error::other(rt::admission_worker_start_failed(&error)));
        }
    };
    state.mutation_locked = true;
    state.admission_worker = Some(AdmissionWorker {
        cancellation,
        progress,
        last_rendered_progress: None,
        receiver,
        handle,
    });
    Ok(())
}

pub(super) fn finalize_admission_start(state: &mut AppState) {
    let Some(worker) = state.admission_worker.as_ref() else {
        return;
    };
    let (_, snapshot) = worker.progress.load();
    state.set_progress_status(admission_progress_status(AdmissionProgressSnapshot {
        inspected: 0,
        ..snapshot
    }));
    update_controls(state);
}

pub(super) fn handle_admission_progress(state: &mut AppState) {
    if state.close_pending {
        return;
    }
    let snapshot = {
        let Some(worker) = state.admission_worker.as_mut() else {
            return;
        };
        if worker.cancellation_requested() || worker.handle.is_finished() {
            return;
        }
        let (encoded, snapshot) = worker.progress.load();
        if worker.last_rendered_progress == Some(encoded) {
            return;
        }
        worker.last_rendered_progress = Some(encoded);
        snapshot
    };
    state.set_progress_status(admission_progress_status(snapshot));
}

fn admission_progress_status(snapshot: AdmissionProgressSnapshot) -> String {
    let phase = match snapshot.phase {
        AdmissionProgressPhase::SelectingMode => RT::SelectingModeProgress.get(),
        AdmissionProgressPhase::Collecting => RT::CollectingProgress.get(),
    };
    if snapshot.inspected == 0 {
        rt::admission_progress_cancellable(phase)
    } else {
        rt::admission_progress_inspected(phase, snapshot.inspected)
    }
}

fn admission_cancellation_status(snapshot: AdmissionProgressSnapshot) -> String {
    let phase = match snapshot.phase {
        AdmissionProgressPhase::SelectingMode => RT::SelectingModeShort.get(),
        AdmissionProgressPhase::Collecting => RT::CollectingShort.get(),
    };
    if snapshot.inspected == 0 {
        RT::AdmissionCancellationProgress.get().to_owned()
    } else {
        rt::admission_cancellation_inspected(phase, snapshot.inspected)
    }
}

#[cfg(test)]
pub(super) fn install_controlled_admission_worker(
    state: &mut AppState,
    phase: AdmissionProgressPhase,
) -> std::sync::mpsc::SyncSender<()> {
    assert!(state.admission_worker.is_none());
    let cancellation = Arc::new(AtomicBool::new(false));
    let progress = Arc::new(AdmissionProgress::new(phase));
    let (sender, receiver) = sync_channel(1);
    let (release_sender, release_receiver) = sync_channel(0);
    let handle = thread::spawn(move || {
        let _released = release_receiver.recv();
        let _sent = sender.send(AdmissionWorkerResult::Cancelled);
    });
    state.mutation_locked = true;
    state.admission_worker = Some(AdmissionWorker {
        cancellation,
        progress,
        last_rendered_progress: None,
        receiver,
        handle,
    });
    release_sender
}

#[cfg(test)]
pub(super) fn publish_controlled_admission_progress(
    state: &AppState,
    phase: AdmissionProgressPhase,
    inspected: usize,
) {
    assert!(
        state.admission_worker.is_some(),
        "controlled admission worker should be installed"
    );
    if let Some(worker) = state.admission_worker.as_ref() {
        worker.progress.publish(phase, inspected);
    }
}

pub(super) fn finalize_admission_start_failure(state: &mut AppState) {
    update_controls(state);
}

pub(super) fn report_admission_start_error(owner: HWND, error: &io::Error) {
    message(owner, &error.to_string(), RT::AdmissionFailedTitle.get());
}

fn run_prepared_directory_task_dialog(
    window: HWND,
    prepared: PreparedDirectoryTaskDialog,
    select: impl FnOnce(HWND, &PreparedTaskDialogSpec) -> io::Result<i32>,
) {
    let answer = select(window, &prepared.spec);
    let Some(mut state_lease) = try_app_state(window) else {
        return;
    };
    let state = state_lease.state_mut();
    let disposition =
        take_prepared_task_dialog(state, prepared.session, PreparedTaskDialogPolicy::Mutable);
    update_controls(state);
    if disposition == PreparedTaskDialogDisposition::Closed {
        try_finish_window_close(window, state);
        return;
    }
    if disposition != PreparedTaskDialogDisposition::Accepted
        || state.revision() != prepared.revision
    {
        if disposition == PreparedTaskDialogDisposition::Rejected {
            state.set_transient_status(RT::AddFolderStateChanged.get());
        }
        return;
    }
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => {
            message(
                window,
                &rt::folder_mode_dialog_failed(&error),
                RT::FolderAddCancelledTitle.get(),
            );
            return;
        }
    };
    let mode = match directory_prompt_choice(answer) {
        DirectoryPromptChoice::Direct => AdmissionMode::Direct,
        DirectoryPromptChoice::Recurse => AdmissionMode::Recurse,
        DirectoryPromptChoice::Cancel => {
            state.set_transient_status(RT::FolderModeCancelled.get());
            update_controls(state);
            return;
        }
    };
    match start_admission_worker(window, state, prepared.paths, Some(mode), prepared.capacity) {
        Ok(()) => finalize_admission_start(state),
        Err(error) => {
            finalize_admission_start_failure(state);
            report_admission_start_error(window, &error);
        }
    }
}

pub(super) fn handle_admission_completion(
    window: HWND,
    state: &mut AppState,
) -> Option<PreparedWorkerTaskDialog> {
    let worker = state.admission_worker.as_ref()?;
    if !worker.handle.is_finished() {
        return None;
    }
    // SAFETY: this timer belongs to the live window and the admission thread
    // has reached its terminal state.
    unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
    let worker = state.admission_worker.take()?;
    apply_cancel_control_state(state);
    let joined = worker.handle.join();
    state.mutation_locked = false;
    state.clear_progress_status();
    if state.close_pending {
        try_finish_window_close(window, state);
        return None;
    }
    if joined.is_err() {
        message(
            window,
            RT::AdmissionWorkerCrashed.get(),
            RT::AdmissionErrorTitle.get(),
        );
        update_controls(state);
        return None;
    }
    match worker.receiver.try_recv() {
        Ok(AdmissionWorkerResult::NeedsDirectoryMode {
            revision,
            paths,
            capacity,
            directory,
        }) => {
            if state.revision() != revision {
                message(
                    window,
                    RT::AdmissionStaleResult.get(),
                    RT::StaleResultTitle.get(),
                );
                update_controls(state);
                return None;
            }
            let directory_units = path_wide(&directory);
            let directory_text = String::from_utf16_lossy(
                directory_units
                    .strip_suffix(&[0])
                    .unwrap_or(&directory_units),
            );
            let directory_detail = rt::selected_directory(&directory_text);
            let session = begin_prepared_task_dialog(state)?;
            update_controls(state);
            return Some(PreparedWorkerTaskDialog::Directory(
                PreparedDirectoryTaskDialog {
                    session,
                    spec: PreparedTaskDialogSpec {
                        title: RT::FolderModeTitle.get().to_owned(),
                        main_instruction: RT::FolderModeQuestion.get().to_owned(),
                        content: RT::FolderModeDetail.get().to_owned(),
                        expanded_information: Some(directory_detail),
                        text_details: None,
                        buttons: vec![
                            PreparedTaskDialogButton {
                                id: DIRECTORY_DIRECT_BUTTON_ID,
                                text: RT::AddSelectedFolderButton.get().to_owned(),
                            },
                            PreparedTaskDialogButton {
                                id: DIRECTORY_RECURSE_BUTTON_ID,
                                text: RT::AddSubfilesButton.get().to_owned(),
                            },
                        ],
                        warning: false,
                    },
                    revision,
                    paths,
                    capacity,
                },
            ));
        }
        Ok(AdmissionWorkerResult::Finished {
            revision,
            mut report,
        }) => {
            if state.revision() != revision {
                message(
                    window,
                    RT::AdmissionStaleResult.get(),
                    RT::StaleResultTitle.get(),
                );
            } else {
                let items = std::mem::take(&mut report.items);
                match state
                    .model
                    .append_batch_indexed(&mut state.append_index, items)
                {
                    Ok(appended) => {
                        state.commit_known_model_change(appended > 0);
                        let status_summary = report.status_summary_korean(appended);
                        state.set_transient_status(status_summary);
                        if !report.issues.is_empty() {
                            message(
                                window,
                                &report.summary_korean(appended),
                                RT::SomePathsSkippedTitle.get(),
                            );
                        }
                        refresh(state);
                        if appended > 0 {
                            schedule_focus_target(window, state.list_window);
                        }
                    }
                    Err(error) => {
                        let error_message = proposal_mutation_error_message(error);
                        state.set_transient_status(rt::admission_result_unchanged(error_message));
                        message(
                            window,
                            &rt::admission_result_not_applied(error_message),
                            RT::AdmissionErrorTitle.get(),
                        );
                    }
                }
            }
        }
        Ok(AdmissionWorkerResult::Cancelled) => {
            state.set_transient_status(RT::PathAddCancelled.get());
        }
        Ok(AdmissionWorkerResult::Panicked) => {
            message(
                window,
                RT::AdmissionWorkerInternalError.get(),
                RT::AdmissionErrorTitle.get(),
            );
        }
        Err(TryRecvError::Empty | TryRecvError::Disconnected) => {
            message(
                window,
                RT::AdmissionWorkerNoResult.get(),
                RT::AdmissionNoResultTitle.get(),
            );
        }
    }
    update_controls(state);
    None
}
