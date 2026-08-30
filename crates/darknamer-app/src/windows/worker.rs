use super::*;

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
    receiver: Receiver<AdmissionWorkerResult>,
    pub(super) handle: JoinHandle<()>,
}

impl ApplyWorker {
    pub(super) fn cancellation_requested(&self) -> bool {
        self.cancellation.is_requested()
    }
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

pub(super) fn start_preferences_writer(window: HWND, state: &mut AppState) {
    let window_value = window as usize;
    let writer = PreferencesWriter::spawn(state.column_preferences_path.clone(), move || {
        // SAFETY: the integer value is the top-level HWND captured before the
        // writer starts. The wake contains no pointer payload or borrowed data.
        unsafe { PostMessageW(window_value as HWND, WM_APP_PREFERENCES_WAKE, 0, 0) };
    });
    match writer {
        Ok(writer) => state.preferences_writer = Some(writer),
        Err(error) => {
            state.set_transient_status(format!(
                "열 표시 설정 writer를 시작하지 못했습니다. 현재 작업에는 영향이 없습니다: {error}"
            ));
            return;
        }
    }
    // SAFETY: the timer belongs to the live top-level window and supplies a
    // loss-safe completion poll if a coalesced PostMessageW wake is missed.
    if unsafe { SetTimer(window, PREFERENCES_POLL_TIMER_ID, 250, None) } == 0 {
        state.set_transient_status(format!(
            "열 표시 설정 완료 감시 timer를 시작하지 못했습니다: {}",
            io::Error::last_os_error()
        ));
    }
}

fn apply_preferences_events(state: &mut AppState, events: Vec<PreferenceWriteEvent>) {
    for event in events {
        match event {
            PreferenceWriteEvent::Saved { generation } => {
                if state
                    .preferences_failure_generation
                    .is_some_and(|failed| generation >= failed)
                {
                    state.preferences_failure_generation = None;
                    if !state.close_pending {
                        state.set_transient_status("열 표시 설정을 다시 저장했습니다.");
                    }
                }
            }
            PreferenceWriteEvent::Stopped => state.preferences_terminal_observed = true,
            PreferenceWriteEvent::Failed { generation, error } => {
                state.preferences_failure_generation = Some(generation);
                if !state.close_pending {
                    state.set_transient_status(format!(
                        "열 표시 설정을 저장하지 못했습니다. 현재 작업에는 영향이 없습니다: {error}"
                    ));
                }
            }
            PreferenceWriteEvent::Panicked => {
                state.preferences_terminal_observed = true;
                if !state.close_pending {
                    state.set_transient_status(
                        "열 표시 설정 writer가 비정상 종료되었습니다. 현재 작업에는 영향이 없습니다.",
                    );
                }
            }
        }
    }
}

fn drain_preferences_events(state: &mut AppState) {
    let events = state
        .preferences_writer
        .as_ref()
        .map(PreferencesWriter::drain_events)
        .unwrap_or_default();
    apply_preferences_events(state, events);
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

pub(super) enum ApplyWorkerResult {
    JournalCreateFailed(FileJournalError),
    Executed {
        journal: Box<FileJournal>,
        execution: Result<ExecutionReport, ExecuteError>,
    },
    Panicked,
}

pub(super) struct WorkerProgress {
    phase: AtomicU8,
    completed: AtomicUsize,
    total: AtomicUsize,
    wake_pending: AtomicBool,
    window: usize,
}

impl WorkerProgress {
    fn new(window: HWND) -> Self {
        Self {
            phase: AtomicU8::new(execution_phase_code(ExecutionPhase::Ready)),
            completed: AtomicUsize::new(0),
            total: AtomicUsize::new(0),
            wake_pending: AtomicBool::new(false),
            window: window as usize,
        }
    }

    fn publish(&self, progress: ExecutionProgress) {
        self.phase
            .store(execution_phase_code(progress.phase), Ordering::Release);
        self.completed.store(progress.completed, Ordering::Release);
        self.total.store(progress.total, Ordering::Release);
        if !self.wake_pending.swap(true, Ordering::AcqRel) {
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

pub(super) const fn execution_phase_code(phase: ExecutionPhase) -> u8 {
    match phase {
        ExecutionPhase::Ready => 0,
        ExecutionPhase::Forward => 1,
        ExecutionPhase::Rollback => 2,
        ExecutionPhase::Terminal => 3,
    }
}

pub(super) fn apply_changes(window: HWND, state: &mut AppState) {
    if state.apply_locked() {
        message(
            window,
            "복구 또는 다른 변경이 진행 중이어서 적용할 수 없습니다.",
            "DarkReNamer",
        );
        return;
    }
    let revision = state.revision();
    let request = build_plan_request(&state.model, revision);
    start_plan_worker(window, state, revision, request);
}

pub(super) fn handle_ready_plan(
    window: HWND,
    state: &mut AppState,
    revision: ModelRevision,
    plan: Result<ReadyPlan, ReadyPlanError>,
) {
    let ready = match plan {
        Ok(ready) => ready,
        Err(ReadyPlanError::Plan(error)) => {
            let (message_text, rows) = plan_error_korean(&error);
            {
                clear_selection(state.list_window);
                select_rows(state.list_window, &rows);
                update_controls(state);
                message(window, &message_text, "DarkReNamer - 적용 차단");
            }
            return;
        }
        Err(ReadyPlanError::Preflight(error)) => {
            message(
                window,
                &execute_error_korean(&error),
                "DarkReNamer - 적용 차단",
            );
            return;
        }
        Err(ReadyPlanError::Summary) => {
            message(
                window,
                "실행 계획 요약이 내부 실행 단계와 일치하지 않습니다. 파일 변경은 시작되지 않았습니다.",
                "DarkReNamer - 적용 차단",
            );
            return;
        }
    };
    let plan = ready.plan;
    if plan.is_empty() {
        message(window, "변경할 항목이 없습니다.", "DarkReNamer");
        return;
    }
    let primary = apply_confirmation_primary(ready.summary);
    let detail = apply_confirmation_detail(plan.fingerprint(), state.model_revision);
    let buttons = [TaskDialogButtonSpec {
        id: APPLY_CONFIRM_BUTTON_ID,
        text: "변경 적용",
    }];
    state.mutation_locked = true;
    state.confirmation_pending = true;
    update_controls(state);
    let answer = task_dialog(
        window,
        TaskDialogSpec {
            title: "DarkReNamer - 안전한 적용 확인",
            main_instruction: "실제 파일 이름 변경을 적용하시겠습니까?",
            content: &primary,
            expanded_information: Some(&detail),
            buttons: &buttons,
            warning: true,
        },
    );
    state.mutation_locked = false;
    state.confirmation_pending = false;
    update_controls(state);
    if state.close_pending {
        try_finish_window_close(window, state);
        return;
    }
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => {
            message(
                window,
                &format!("안전 확인 대화상자를 열지 못해 적용을 취소했습니다: {error}"),
                "DarkReNamer - 적용 취소",
            );
            return;
        }
    };
    if destructive_prompt_choice(answer, APPLY_CONFIRM_BUTTON_ID)
        != DestructivePromptChoice::Confirm
    {
        return;
    }
    if state.revision() != revision {
        {
            message(
                window,
                "확인 후 목록이 변경되었습니다. 다시 계획하고 확인해 주세요.",
                "DarkReNamer",
            )
        }
        return;
    }
    let id = plan.id();
    let plan_revision = plan.revision();
    let confirmed = match plan.confirm_presented(id, plan_revision) {
        Ok(confirmed) => confirmed,
        Err(error) => {
            message(window, &error.to_string(), "DarkReNamer");
            return;
        }
    };
    start_apply_worker(window, state, confirmed);
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
                    "DarkReNamer - 저널 정리 실패",
                );
            }
            message(window, &text, "DarkReNamer - 실행 거부");
            update_controls(state);
            return;
        }
    };
    let text = execution_outcome_korean(report.outcome());
    match report.outcome() {
        ExecutionOutcome::Completed => {
            let changed = !report.entries().is_empty();
            if !apply_execution_report(&mut state.model, &report) {
                state.recovery_locked = true;
                state.active_journal = Some(journal);
                message(
                    window,
                    "완료 결과를 목록과 일치시키지 못했습니다. 저널을 보존하고 적용을 잠급니다.",
                    "DarkReNamer - 확인 필요",
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
                message(window, &error.to_string(), "DarkReNamer - 저널 정리 실패");
            } else {
                state.set_transient_status(text);
            }
        }
        ExecutionOutcome::RolledBack { .. } => {
            let cleanup = cleanup_file_journal(journal);
            state.recovery_locked = cleanup.error.is_some() || cleanup.retained.is_some();
            state.active_journal = cleanup.retained;
            if let Some(error) = cleanup.error {
                message(window, &error.to_string(), "DarkReNamer - 저널 정리 실패");
            } else {
                match execution_outcome_presentation(report.outcome()) {
                    ExecutionOutcomePresentation::NonModal => state.set_transient_status(text),
                    ExecutionOutcomePresentation::Modal => {
                        message(window, &text, "DarkReNamer - 실행 실패");
                    }
                }
            }
        }
        ExecutionOutcome::RecoveryRequired { .. } => {
            state.recovery_locked = true;
            state.active_journal = Some(journal);
            message(window, &text, "DarkReNamer - 복구 필요");
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
            &format!(
                "planning worker 완료 감시 timer를 시작하지 못했습니다: {}",
                io::Error::last_os_error()
            ),
            "DarkReNamer - 실행 실패",
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
                &format!("planning worker를 시작하지 못했습니다: {error}"),
                "DarkReNamer - 실행 실패",
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
    state.set_progress_status("파일 시스템을 확인하고 실행 계획을 만들고 있습니다...");
    update_controls(state);
}

pub(super) fn handle_plan_completion(window: HWND, state: &mut AppState) {
    let Some(worker) = state.plan_worker.as_ref() else {
        return;
    };
    if !worker.handle.is_finished() {
        return;
    }
    // SAFETY: this exact timer belongs to the live top-level window and the
    // planning thread has reached its terminal state.
    unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
    let Some(worker) = state.plan_worker.take() else {
        return;
    };
    apply_cancel_control_state(state);
    let joined = worker.handle.join();
    state.mutation_locked = false;
    state.clear_progress_status();
    if state.close_pending {
        try_finish_window_close(window, state);
        return;
    }
    if joined.is_err() {
        message(
            window,
            "planning worker가 비정상 종료되었습니다. 파일 변경은 시작되지 않았습니다.",
            "DarkReNamer - 계획 오류",
        );
        update_controls(state);
        return;
    }
    match worker.receiver.try_recv() {
        Ok(PlanWorkerResult::Finished { revision, plan }) => {
            handle_ready_plan(window, state, revision, plan);
            if state.close_pending {
                try_finish_window_close(window, state);
                return;
            }
        }
        Ok(PlanWorkerResult::Cancelled) => {
            state.set_transient_status("파일 변경 계획을 취소했습니다.");
        }
        Ok(PlanWorkerResult::Panicked) => {
            message(
                window,
                "planning worker 내부 오류가 발생했습니다. 파일 변경은 시작되지 않았습니다.",
                "DarkReNamer - 계획 오류",
            );
        }
        Err(TryRecvError::Empty | TryRecvError::Disconnected) => {
            message(
                window,
                "planning worker가 결과를 전달하지 못했습니다. 파일 변경은 시작되지 않았습니다.",
                "DarkReNamer - 계획 결과 없음",
            );
        }
    }
    update_controls(state);
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
                &format!(
                    "저널 루트 권한을 worker로 전달하지 못했습니다. {:?}, OS {:?}",
                    error.kind, error.os_code
                ),
                "DarkReNamer - 적용 잠김",
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
            &format!(
                "worker 완료 감시 timer를 시작하지 못했습니다: {}",
                io::Error::last_os_error()
            ),
            "DarkReNamer - 실행 실패",
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
                &format!("적용 worker를 시작하지 못했습니다: {error}"),
                "DarkReNamer - 실행 실패",
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
    state.set_progress_status("실행 순서를 준비하고 있습니다...");
    update_controls(state);
}

pub(super) fn handle_apply_progress(state: &mut AppState) {
    let Some(worker) = state.apply_worker.as_ref() else {
        return;
    };
    let phase = worker.progress.phase.load(Ordering::Acquire);
    let completed = worker.progress.completed.load(Ordering::Acquire);
    let total = worker.progress.total.load(Ordering::Acquire);
    worker.progress.wake_pending.store(false, Ordering::Release);
    let cancellation_requested = worker.cancellation.is_requested();
    let text = match (phase, cancellation_requested) {
        (0 | 1, true) => {
            format!("취소 요청됨: 현재 원시 변경 경계를 마치는 중 ({completed}/{total} 단계)")
        }
        (0, _) => format!("실행 준비 완료: {total} 단계"),
        (1, _) => format!("파일 이름 변경 중: {completed}/{total} 단계"),
        (2, _) => format!("취소 또는 오류 후 복원 중: {completed}/{total} 단계"),
        (3, _) => "저널 terminal 상태를 기록했습니다.".to_owned(),
        _ => "파일 변경 상태를 확인하고 있습니다...".to_owned(),
    };
    state.set_progress_status(text);
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
            "적용 worker가 비정상 종료되었습니다. 남은 저널을 다음 시작에서 복구하도록 적용을 잠급니다.",
            "DarkReNamer - worker 오류",
        );
    } else {
        match worker.receiver.try_recv() {
            Ok(ApplyWorkerResult::JournalCreateFailed(error)) => {
                state.recovery_locked = true;
                message(
                    window,
                    &format!(
                        "활성 저널을 만들지 못했습니다. {:?}, OS {:?}",
                        error.kind, error.os_code
                    ),
                    "DarkReNamer - 적용 잠김",
                );
            }
            Ok(ApplyWorkerResult::Executed { journal, execution }) => {
                handle_completed_execution(window, state, *journal, execution);
            }
            Ok(ApplyWorkerResult::Panicked) => {
                state.recovery_locked = true;
                message(
                    window,
                    "적용 worker 내부 오류가 발생했습니다. 남은 저널을 다음 시작에서 복구하도록 적용을 잠급니다.",
                    "DarkReNamer - worker panic",
                );
            }
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => {
                state.recovery_locked = true;
                message(
                    window,
                    "적용 worker가 terminal 결과를 전달하지 못했습니다. 다음 시작 복구를 위해 적용을 잠급니다.",
                    "DarkReNamer - worker 결과 없음",
                );
            }
        }
    }
    if state.recovery_locked {
        state.set_recovery_status(
            "복구 확인이 필요해 적용을 잠갔습니다. 복구 상태 메뉴에서 저널을 확인하세요.",
        );
    }
    update_controls(state);
}

pub(super) fn finish_apply_after_message_loop_failure(window: HWND) {
    // SAFETY: window is still live and GWLP_USERDATA retains the UI-owned
    // AppState until the subsequent DestroyWindow call.
    let state_ptr = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut AppState;
    if state_ptr.is_null() {
        return;
    }
    // SAFETY: the message loop has failed on this same UI thread, so this is
    // the sole mutable access to the still-live AppState.
    let state = unsafe { &mut *state_ptr };
    if let Some(worker) = state.admission_worker.take() {
        worker.cancellation.store(true, Ordering::Release);
        // SAFETY: this exact timer belongs to the still-live top-level window.
        unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
        let _joined = worker.handle.join();
        state.mutation_locked = false;
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
    if let Some(mut writer) = state.preferences_writer.take() {
        let _shutdown = writer.shutdown_with(state.column_states);
        let _joined = writer.join();
    }
    // SAFETY: this exact timer belongs to the still-live top-level window.
    unsafe { KillTimer(window, PREFERENCES_POLL_TIMER_ID) };
    if state.close_pending {
        state.close_pending = false;
    }
}

fn request_preferences_shutdown(state: &mut AppState) {
    let result = state
        .preferences_writer
        .as_mut()
        .map(|writer| writer.shutdown_with(state.column_states));
    if let Some(Err(error)) = result {
        state.set_transient_status(format!(
            "종료 전 열 표시 설정을 저장하도록 요청하지 못했습니다: {error}"
        ));
    }
}

pub(super) fn try_finish_window_close(window: HWND, state: &mut AppState) {
    if !state.close_pending
        || state.confirmation_pending
        || state.admission_worker.is_some()
        || state.plan_worker.is_some()
        || state.apply_worker.is_some()
    {
        return;
    }
    drain_preferences_events(state);
    if state
        .preferences_writer
        .as_ref()
        .is_some_and(|writer| !state.preferences_terminal_observed && !writer.is_finished())
    {
        return;
    }
    if let Some(mut writer) = state.preferences_writer.take() {
        let _joined = writer.join();
        apply_preferences_events(state, writer.drain_events());
    }
    // SAFETY: the preference writer is terminal and this timer belongs to the
    // live top-level window. No worker retains UI-owned state at this point.
    unsafe { KillTimer(window, PREFERENCES_POLL_TIMER_ID) };
    // SAFETY: all worker handles are joined and modal callbacks have returned,
    // so the top-level window can reclaim its AppState.
    unsafe { DestroyWindow(window) };
}

pub(super) fn request_window_close(window: HWND, state: &mut AppState) {
    if !state.close_pending {
        state.close_pending = true;
        state.mutation_locked = true;
        request_preferences_shutdown(state);
        update_controls(state);
    }
    if state.confirmation_pending {
        return;
    }
    if let Some(worker) = state.admission_worker.as_ref() {
        if !worker.cancellation_requested() {
            worker.cancellation.store(true, Ordering::Release);
            state.set_progress_status(
                "종료 요청을 받았습니다. 현재 경로 확인이 끝나는 즉시 종료합니다...",
            );
            update_controls(state);
        }
        return;
    }
    if let Some(worker) = state.plan_worker.as_ref() {
        if !worker.cancellation_requested() {
            worker.cancellation.request();
            state.set_progress_status(
                "종료 요청을 받았습니다. 파일 시스템 확인이 끝나는 즉시 종료합니다...",
            );
            update_controls(state);
        }
        return;
    }
    if let Some(worker) = state.apply_worker.as_ref() {
        if !worker.cancellation_requested() {
            worker.cancellation.request();
            state.set_progress_status(
                "종료 요청을 받았습니다. 현재 단계를 마친 뒤 안전하게 취소·복원합니다...",
            );
            update_controls(state);
        }
        return;
    }
    try_finish_window_close(window, state);
}

pub(super) fn request_active_worker_cancel(state: &mut AppState) {
    let progress = match active_worker_kind(state.worker_activity()) {
        Some(ActiveWorkerKind::Admission) => state.admission_worker.as_ref().map(|worker| {
            worker.cancellation.store(true, Ordering::Release);
            "경로 추가 취소를 요청했습니다. 현재 확인 경계가 끝나면 중단합니다..."
        }),
        Some(ActiveWorkerKind::Plan) => state.plan_worker.as_ref().map(|worker| {
            worker.cancellation.request();
            "파일 변경 계획 취소를 요청했습니다. 현재 파일 시스템 확인 경계가 끝나면 중단합니다..."
        }),
        Some(ActiveWorkerKind::Apply) => state.apply_worker.as_ref().map(|worker| {
            worker.cancellation.request();
            "적용 취소를 요청했습니다. 현재 원시 변경 경계가 끝나면 안전하게 복원합니다..."
        }),
        None => None,
    };
    if let Some(progress) = progress {
        state.set_progress_status(progress);
        update_controls(state);
    }
}

pub(super) fn admit_paths(owner: HWND, state: &mut AppState, paths: Vec<PathBuf>) {
    let capacity = MAX_ADMITTED_SOURCES.saturating_sub(state.model.len());
    start_admission_worker(owner, state, paths, None, capacity);
}

pub(super) fn start_admission_worker(
    window: HWND,
    state: &mut AppState,
    paths: Vec<PathBuf>,
    mode: Option<AdmissionMode>,
    capacity: usize,
) {
    let revision = state.revision();
    let cancellation = Arc::new(AtomicBool::new(false));
    let worker_cancellation = Arc::clone(&cancellation);
    let (sender, receiver) = sync_channel(1);
    // SAFETY: window is the live top-level HWND and the timer has no callback.
    if unsafe { SetTimer(window, APPLY_POLL_TIMER_ID, 100, None) } == 0 {
        message(
            window,
            &format!(
                "admission worker 완료 감시 timer를 시작하지 못했습니다: {}",
                io::Error::last_os_error()
            ),
            "DarkReNamer - 추가 실패",
        );
        update_controls(state);
        return;
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
                    for path in paths.iter().take(capacity) {
                        if worker_cancellation.load(Ordering::Acquire) {
                            return AdmissionWorkerResult::Cancelled;
                        }
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
                    AdmissionMode::Direct
                };
                match collect_admission_cancellable(
                    &adapter,
                    paths,
                    mode,
                    capacity,
                    |left, right| compare_windows(&legacy_path(left), &legacy_path(right)),
                    || worker_cancellation.load(Ordering::Acquire),
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
            message(
                window,
                &format!("admission worker를 시작하지 못했습니다: {error}"),
                "DarkReNamer - 추가 실패",
            );
            update_controls(state);
            return;
        }
    };
    state.mutation_locked = true;
    state.admission_worker = Some(AdmissionWorker {
        cancellation,
        receiver,
        handle,
    });
    state.set_progress_status("선택한 경로를 확인하고 있습니다...");
    update_controls(state);
}

pub(super) fn handle_admission_completion(window: HWND, state: &mut AppState) {
    let Some(worker) = state.admission_worker.as_ref() else {
        return;
    };
    if !worker.handle.is_finished() {
        return;
    }
    // SAFETY: this timer belongs to the live window and the admission thread
    // has reached its terminal state.
    unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
    let Some(worker) = state.admission_worker.take() else {
        return;
    };
    apply_cancel_control_state(state);
    let joined = worker.handle.join();
    state.mutation_locked = false;
    state.clear_progress_status();
    if state.close_pending {
        try_finish_window_close(window, state);
        return;
    }
    if joined.is_err() {
        message(
            window,
            "경로 확인 worker가 비정상 종료되었습니다. 목록은 변경되지 않았습니다.",
            "DarkReNamer - 추가 오류",
        );
        update_controls(state);
        return;
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
                    "경로 확인 중 목록이 변경되어 결과를 적용하지 않았습니다.",
                    "DarkReNamer - 오래된 결과",
                );
                update_controls(state);
                return;
            }
            let directory_units = path_wide(&directory);
            let directory_text = String::from_utf16_lossy(
                directory_units
                    .strip_suffix(&[0])
                    .unwrap_or(&directory_units),
            );
            let directory_detail = format!("선택한 폴더: {directory_text}");
            let buttons = [
                TaskDialogButtonSpec {
                    id: DIRECTORY_DIRECT_BUTTON_ID,
                    text: "선택한 폴더만 추가",
                },
                TaskDialogButtonSpec {
                    id: DIRECTORY_RECURSE_BUTTON_ID,
                    text: "하위 파일을 모두 추가",
                },
            ];
            state.mutation_locked = true;
            state.confirmation_pending = true;
            update_controls(state);
            let answer = task_dialog(
                window,
                TaskDialogSpec {
                    title: "DarkReNamer - 폴더 추가 방식",
                    main_instruction: "선택한 폴더를 어떻게 추가할까요?",
                    content: "목록에 추가할 범위를 선택하세요.",
                    expanded_information: Some(&directory_detail),
                    buttons: &buttons,
                    warning: false,
                },
            );
            state.mutation_locked = false;
            state.confirmation_pending = false;
            if state.close_pending {
                try_finish_window_close(window, state);
                return;
            }
            let answer = match answer {
                Ok(answer) => answer,
                Err(error) => {
                    message(
                        window,
                        &format!(
                            "폴더 추가 방식 대화상자를 열지 못해 추가를 취소했습니다: {error}"
                        ),
                        "DarkReNamer - 폴더 추가 취소",
                    );
                    update_controls(state);
                    return;
                }
            };
            let mode = match directory_prompt_choice(answer) {
                DirectoryPromptChoice::Direct => AdmissionMode::Direct,
                DirectoryPromptChoice::Recurse => AdmissionMode::Recurse,
                DirectoryPromptChoice::Cancel => {
                    state.set_transient_status(
                        "폴더 추가 방식을 취소했습니다. 목록은 변경되지 않았습니다.",
                    );
                    update_controls(state);
                    return;
                }
            };
            start_admission_worker(window, state, paths, Some(mode), capacity);
            return;
        }
        Ok(AdmissionWorkerResult::Finished {
            revision,
            mut report,
        }) => {
            if state.revision() != revision {
                message(
                    window,
                    "경로 확인 중 목록이 변경되어 결과를 적용하지 않았습니다.",
                    "DarkReNamer - 오래된 결과",
                );
            } else {
                let items = std::mem::take(&mut report.items);
                let appended = state.model.append_batch_by(items, compare_windows);
                state.commit_known_model_change(appended > 0);
                let summary = report.summary_korean(appended);
                state.set_transient_status(summary.clone());
                if !report.issues.is_empty() {
                    message(window, &summary, "DarkReNamer - 일부 경로 제외");
                }
                refresh(state);
                if appended > 0 {
                    schedule_focus_target(window, state.list_window);
                }
            }
        }
        Ok(AdmissionWorkerResult::Cancelled) => {
            state.set_transient_status("경로 추가를 취소했습니다. 목록은 변경되지 않았습니다.");
        }
        Ok(AdmissionWorkerResult::Panicked) => {
            message(
                window,
                "경로 확인 worker 내부 오류가 발생했습니다. 목록은 변경되지 않았습니다.",
                "DarkReNamer - 추가 오류",
            );
        }
        Err(TryRecvError::Empty | TryRecvError::Disconnected) => {
            message(
                window,
                "경로 확인 worker가 결과를 전달하지 못했습니다. 목록은 변경되지 않았습니다.",
                "DarkReNamer - 추가 결과 없음",
            );
        }
    }
    update_controls(state);
}
