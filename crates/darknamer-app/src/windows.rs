use std::collections::HashMap;
use std::env;
use std::ffi::c_void;
use std::fs;
use std::io;
use std::mem::{size_of, zeroed};
use std::os::windows::ffi::OsStringExt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::slice;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError, sync_channel};
use std::thread::{self, JoinHandle};

use crate::admission::{
    AdmissionAdapter, AdmissionMode, AdmissionReport, MAX_ADMITTED_SOURCES,
    WindowsAdmissionAdapter, bounded_import_lines, bounded_selection, collect_admission,
};
use crate::icon_cache::{IconCacheKey, icon_cache_key};
use crate::rename::{
    CancellationToken, ExecuteError, ExecutionControl, ExecutionOutcome, ExecutionPhase,
    ExecutionProgress, ExecutionReport, ExistingJournalOpenError, FileJournal, FileJournalError,
    JournalCleanupDecision, JournalOpenFailure, JournalRequirements, JournalRoot, ModelRevision,
    PlanError, RecoveryJournalEvidence, RecoveryOutcome, RenameExecutor, RenamePlan, RenamePlanner,
    RenameRecovery, WindowsRenameBackend, apply_execution_report, build_plan_request,
    cleanup_decision, execute_error_korean, execution_outcome_korean, next_model_revision,
    plan_error_korean, preflight_plan, process_is_elevated, safe_mode_unify_path_message,
};
use darknamer_core::{
    LegacyInputError, LegacyList, LegacyListItem, LegacySequenceMode, LegacySortMode, LegacyText,
    SortSemantics,
};

mod clipboard;
mod command_dispatch;
mod dialog;
mod list_view;
mod menu;
mod recovery_ui;
#[path = "../resource_ids.rs"]
mod resource_ids;
mod safe_runtime;
mod text_io;

use clipboard::copy_clipboard;
use command_dispatch::*;
use dialog::*;
#[cfg(test)]
use list_view::changed_column_mask;
use list_view::{RenderedRow, refresh, update_column_visibility, update_dpi_metrics};
use menu::*;
use recovery_ui::*;
#[cfg(test)]
use safe_runtime::initialize_safe_runtime_at;
use safe_runtime::{
    JournalRole, SafeRuntime, StartupJournalBlock, cleanup_file_journal, initialize_safe_runtime,
};
use text_io::{compare_windows, legacy_path, path_wide, read_legacy_text, wide, write_legacy_text};
use windows_sys::Win32::Foundation::{FILETIME, HWND, LPARAM, LRESULT, RECT, SYSTEMTIME, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    COLOR_WINDOW, CreateFontIndirectW, DeleteObject, HFONT, RDW_ALLCHILDREN, RDW_ERASE,
    RDW_INVALIDATE, RedrawWindow, UpdateWindow,
};
#[cfg(test)]
use windows_sys::Win32::Storage::FileSystem::MoveFileW;
use windows_sys::Win32::Storage::FileSystem::{FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL};
use windows_sys::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::SystemServices::{SS_CENTERIMAGE, SS_ETCHEDHORZ, SS_SUNKEN};
use windows_sys::Win32::System::Time::FileTimeToSystemTime;
use windows_sys::Win32::UI::Accessibility::{HCF_HIGHCONTRASTON, HIGHCONTRASTW};
use windows_sys::Win32::UI::Controls::{
    BTNS_SHOWTEXT, CCS_NOPARENTALIGN, CCS_NORESIZE, CCS_VERT, I_IMAGENONE, ICC_BAR_CLASSES,
    ICC_LISTVIEW_CLASSES, INITCOMMONCONTROLSEX, InitCommonControlsEx, LVCF_FMT, LVCF_TEXT,
    LVCF_WIDTH, LVCFMT_LEFT, LVCFMT_RIGHT, LVCOLUMNW, LVIF_IMAGE, LVIF_TEXT, LVIS_FOCUSED,
    LVIS_SELECTED, LVITEMW, LVM_DELETEALLITEMS, LVM_DELETEITEM, LVM_ENSUREVISIBLE, LVM_GETNEXTITEM,
    LVM_INSERTCOLUMNW, LVM_INSERTITEMW, LVM_SETCOLUMNWIDTH, LVM_SETEXTENDEDLISTVIEWSTYLE,
    LVM_SETIMAGELIST, LVM_SETITEMSTATE, LVM_SETITEMTEXTW, LVM_SETITEMW, LVN_ITEMCHANGED,
    LVNI_FOCUSED, LVNI_SELECTED, LVS_EX_DOUBLEBUFFER, LVS_EX_FULLROWSELECT, LVS_NOSORTHEADER,
    LVS_REPORT, LVS_SHAREIMAGELISTS, LVS_SHOWSELALWAYS, LVSIL_SMALL, NM_DBLCLK, NMHDR, NMLISTVIEW,
    TB_ADDBITMAP, TB_ADDBUTTONS, TB_ADDSTRINGW, TB_BUTTONSTRUCTSIZE, TB_ENABLEBUTTON,
    TB_SETBITMAPSIZE, TB_SETBUTTONSIZE, TB_SETMAXTEXTROWS, TBADDBITMAP, TBBUTTON, TBSTATE_ENABLED,
    TBSTYLE_BUTTON, TBSTYLE_FLAT, TBSTYLE_SEP, TBSTYLE_TOOLTIPS, TOOLBARCLASSNAMEW,
};
use windows_sys::Win32::UI::HiDpi::{GetDpiForWindow, SystemParametersInfoForDpi};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetKeyState, SetFocus, VK_CONTROL, VK_DELETE, VK_ESCAPE, VK_SHIFT,
};
use windows_sys::Win32::UI::Shell::{
    DragAcceptFiles, DragFinish, DragQueryFileW, HDROP, SHFILEINFOW, SHGFI_SMALLICON,
    SHGFI_SYSICONINDEX, SHGFI_USEFILEATTRIBUTES, SHGetFileInfoW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, BN_CLICKED, BS_DEFPUSHBUTTON, CB_ADDSTRING, CB_GETCURSEL, CB_SETCURSEL,
    CBS_DROPDOWNLIST, CREATESTRUCTW, CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, CheckMenuItem,
    CreateMenu, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW,
    DrawMenuBar, ES_AUTOHSCROLL, EnableMenuItem, GWLP_USERDATA, GetClientRect, GetMessageW,
    GetParent, GetWindowLongPtrW, GetWindowTextLengthW, GetWindowTextW, HMENU, IDC_ARROW, IDCANCEL,
    IDOK, IsDialogMessageW, KillTimer, LoadCursorW, LoadIconW, MB_OKCANCEL, MB_YESNO, MF_BYCOMMAND,
    MF_CHECKED, MF_ENABLED, MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, MF_UNCHECKED, MINMAXINFO,
    MSG, MessageBoxW, MoveWindow, NONCLIENTMETRICSW, PostMessageW, PostQuitMessage,
    RegisterClassExW, SPI_GETHIGHCONTRAST, SPI_GETNONCLIENTMETRICS, SW_SHOW, SWP_NOACTIVATE,
    SWP_NOZORDER, SendMessageW, SetForegroundWindow, SetMenu, SetTimer, SetWindowLongPtrW,
    SetWindowPos, ShowWindow, SystemParametersInfoW, TranslateMessage, WM_APP, WM_CLOSE,
    WM_COMMAND, WM_CREATE, WM_DESTROY, WM_DPICHANGED, WM_DROPFILES, WM_FONTCHANGE,
    WM_GETMINMAXINFO, WM_KEYDOWN, WM_KEYUP, WM_NCCREATE, WM_NCDESTROY, WM_NOTIFY, WM_SETFONT,
    WM_SETREDRAW, WM_SETTINGCHANGE, WM_SIZE, WM_SYSCOLORCHANGE, WM_THEMECHANGED, WM_TIMER,
    WNDCLASSEXW, WS_BORDER, WS_CAPTION, WS_CHILD, WS_CLIPCHILDREN, WS_EX_ACCEPTFILES,
    WS_EX_APPWINDOW, WS_EX_TOOLWINDOW, WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_OVERLAPPEDWINDOW,
    WS_POPUP, WS_SYSMENU, WS_TABSTOP, WS_VISIBLE,
};

use crate::*;

const LIST_ID: usize = 1000;
const LEFT_TOOLBAR_ID: usize = 1001;
const RIGHT_TOOLBAR_ID: usize = 1002;
const STATUS_ID: usize = 1007;
const CANDIDATE_JOURNAL_LEAF: &str = "candidate.drj";
const ACTIVE_JOURNAL_LEAF: &str = "active.drj";
const EXPORT_RECOVERY_JOURNAL: u16 = 0x9000;
const DISCARD_STAGED_JOURNAL: u16 = 0x9001;
const SHOW_RECOVERY_STATUS: u16 = 0x9002;
const WM_APP_APPLY_PROGRESS: u32 = WM_APP + 0x40;
const WM_APP_APPLY_COMPLETE: u32 = WM_APP + 0x41;
const WM_APP_PLAN_COMPLETE: u32 = WM_APP + 0x42;
const WM_APP_ADMISSION_COMPLETE: u32 = WM_APP + 0x43;
const APPLY_POLL_TIMER_ID: usize = 0xD4A1;

struct AppState {
    list_window: HWND,
    status: HWND,
    menu: HMENU,
    font: HFONT,
    status_font: HFONT,
    left_toolbar: HWND,
    right_toolbar: HWND,
    model: LegacyList,
    shown_columns: [bool; 4],
    dpi: u32,
    high_contrast: bool,
    command_states: [bool; 34],
    model_revision: u64,
    mutation_locked: bool,
    recovery_locked: bool,
    journal_root: JournalRoot,
    active_journal: Option<FileJournal>,
    staged_journal: Option<FileJournal>,
    blocked_journals: Vec<StartupJournalBlock>,
    collision_observed: bool,
    apply_worker: Option<ApplyWorker>,
    plan_worker: Option<PlanWorker>,
    admission_worker: Option<AdmissionWorker>,
    close_pending: bool,
    confirmation_pending: bool,
    startup_status: Option<String>,
    icon_cache: HashMap<IconCacheKey, i32>,
    rendered_rows: Vec<RenderedRow>,
    // Fields drop in declaration order. Keep the instance lock last so workers
    // and every retained journal capability close before another launch.
    _runtime_lock: fs::File,
}

struct WindowInit {
    state: *mut AppState,
    adopted: *mut bool,
}

impl AppState {
    fn new(runtime: SafeRuntime) -> Self {
        Self {
            list_window: null_mut(),
            status: null_mut(),
            menu: null_mut(),
            font: null_mut(),
            status_font: null_mut(),
            left_toolbar: null_mut(),
            right_toolbar: null_mut(),
            model: LegacyList::new(),
            shown_columns: [false; 4],
            dpi: BASE_DPI,
            high_contrast: false,
            command_states: [false; 34],
            model_revision: 0,
            mutation_locked: false,
            recovery_locked: runtime.recovery_locked,
            journal_root: runtime.root,
            _runtime_lock: runtime.runtime_lock,
            active_journal: runtime.active_journal,
            staged_journal: runtime.staged_journal,
            blocked_journals: runtime.blocked_journals,
            collision_observed: runtime.collision_observed,
            apply_worker: None,
            plan_worker: None,
            admission_worker: None,
            close_pending: false,
            confirmation_pending: false,
            startup_status: runtime.status,
            icon_cache: HashMap::new(),
            rendered_rows: Vec::new(),
        }
    }

    fn revision(&self) -> ModelRevision {
        ModelRevision::new(self.model_revision)
    }

    fn commit_model_change(&mut self, before: &LegacyList) {
        self.model_revision = next_model_revision(self.model_revision, &self.model != before);
    }

    const fn apply_locked(&self) -> bool {
        self.mutation_locked
            || self.recovery_locked
            || self.active_journal.is_some()
            || self.staged_journal.is_some()
            || !self.blocked_journals.is_empty()
            || self.apply_worker.is_some()
            || self.plan_worker.is_some()
            || self.admission_worker.is_some()
    }

    const fn read_only_locked(&self) -> bool {
        self.recovery_locked
    }

    fn can_discard_staged_intent(&self) -> bool {
        self.recovery_locked
            && !self.collision_observed
            && self.active_journal.is_none()
            && self.blocked_journals.is_empty()
            && self
                .staged_journal
                .as_ref()
                .is_some_and(FileJournal::is_complete_intent_candidate)
    }

    fn can_export_recovery_journal(&self) -> bool {
        self.active_journal.is_some()
            || self.staged_journal.is_some()
            || self
                .blocked_journals
                .iter()
                .any(|blocked| blocked.evidence().is_some())
    }
}

struct ApplyWorker {
    cancellation: Arc<CancellationToken>,
    progress: Arc<WorkerProgress>,
    receiver: Receiver<ApplyWorkerResult>,
    handle: JoinHandle<()>,
}

struct PlanWorker {
    cancellation: Arc<CancellationToken>,
    receiver: Receiver<PlanWorkerResult>,
    handle: JoinHandle<()>,
}

struct AdmissionWorker {
    cancellation: Arc<AtomicBool>,
    receiver: Receiver<AdmissionWorkerResult>,
    handle: JoinHandle<()>,
}

enum AdmissionWorkerResult {
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

enum PlanWorkerResult {
    Finished {
        revision: ModelRevision,
        plan: Result<ReadyPlan, ReadyPlanError>,
    },
    Cancelled,
    Panicked,
}

struct ReadyPlan {
    plan: RenamePlan,
    journal: JournalRequirements,
}

enum ReadyPlanError {
    Plan(PlanError),
    Preflight(ExecuteError),
}

enum ApplyWorkerResult {
    JournalCreateFailed(FileJournalError),
    Executed {
        journal: Box<FileJournal>,
        execution: Result<ExecutionReport, ExecuteError>,
    },
    Panicked,
}

struct WorkerProgress {
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

struct WorkerExecutionControl {
    cancellation: Arc<CancellationToken>,
    progress: Arc<WorkerProgress>,
}

struct CompletionWake {
    progress: Arc<WorkerProgress>,
}

struct SimpleCompletionWake {
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

const fn execution_phase_code(phase: ExecutionPhase) -> u8 {
    match phase {
        ExecutionPhase::Ready => 0,
        ExecutionPhase::Forward => 1,
        ExecutionPhase::Rollback => 2,
        ExecutionPhase::Terminal => 3,
    }
}

struct ComGuard;

impl Drop for ComGuard {
    fn drop(&mut self) {
        // SAFETY: ComGuard exists only after successful CoInitializeEx and drops on the same apartment thread.
        unsafe { CoUninitialize() };
    }
}

pub(crate) fn run() -> io::Result<()> {
    run_unsafe()
}

fn run_unsafe() -> io::Result<()> {
    if process_is_elevated()? {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "관리자 권한으로는 실행할 수 없습니다. 일반 사용자 권한으로 다시 실행해 주세요.",
        ));
    }
    // SAFETY: CoInitializeEx requires a null reserved pointer; ComGuard balances success on this same apartment thread.
    let com_status = unsafe { CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) };
    if com_status < 0 {
        return Err(io::Error::from_raw_os_error(com_status));
    }
    let _com = ComGuard;
    let controls = INITCOMMONCONTROLSEX {
        dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
        dwICC: ICC_LISTVIEW_CLASSES | ICC_BAR_CLASSES,
    };
    // SAFETY: controls is initialized with its exact structure size and lives through InitCommonControlsEx.
    unsafe { InitCommonControlsEx(&controls) };
    // SAFETY: A null module name requests the current process module and dereferences no caller memory.
    let instance = unsafe { GetModuleHandleW(null()) };
    if instance.is_null() {
        return Err(io::Error::last_os_error());
    }
    let class_name = wide("DarkReNamerWindow");
    // SAFETY: instance is the current live module and int_resource encodes the linked APP_ICON resource.
    let icon = unsafe { LoadIconW(instance, int_resource(resource_ids::APP_ICON)) };
    let window_class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(window_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        hIcon: icon,
        // SAFETY: A null instance plus IDC_ARROW is the documented predefined-cursor request.
        hCursor: unsafe { LoadCursorW(null_mut(), IDC_ARROW) },
        hbrBackground: (COLOR_WINDOW + 1) as *mut c_void,
        lpszMenuName: null(),
        lpszClassName: class_name.as_ptr(),
        hIconSm: icon,
    };
    // SAFETY: WNDCLASSEXW is initialized and its class name and callback remain valid during registration.
    if unsafe { RegisterClassExW(&window_class) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let title = wide("DarkReNamer");
    let runtime = initialize_safe_runtime()?;
    let startup_notice = runtime.status.clone();
    let state = Box::into_raw(Box::new(AppState::new(runtime)));
    let mut adopted = false;
    let mut init = WindowInit {
        state,
        adopted: &mut adopted,
    };
    // SAFETY: instance is the current module; class_name/title and stack WindowInit
    // storage remain allocated throughout this synchronous CreateWindowExW call.
    let window = unsafe {
        CreateWindowExW(
            WS_EX_ACCEPTFILES | WS_EX_APPWINDOW,
            class_name.as_ptr(),
            title.as_ptr(),
            WS_OVERLAPPEDWINDOW | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            INITIAL_WIDTH,
            INITIAL_HEIGHT,
            null_mut(),
            null_mut(),
            instance,
            (&mut init as *mut WindowInit).cast(),
        )
    };
    if window.is_null() {
        if !adopted {
            // SAFETY: WM_NCCREATE did not adopt state, so this is the sole Box::from_raw for the still-owned Box::into_raw allocation.
            unsafe { drop(Box::from_raw(state)) };
        }
        return Err(io::Error::last_os_error());
    }
    // SAFETY: window is the non-null top-level HWND just created and remains owned by this UI thread.
    unsafe {
        ShowWindow(window, SW_SHOW);
        UpdateWindow(window);
    }
    if let Some(notice) = startup_notice {
        message(window, &notice, "DarkReNamer - 복구 상태");
    }
    // SAFETY: MSG is a C-compatible structure for which all-zero is a valid pre-GetMessageW state.
    let mut message: MSG = unsafe { zeroed() };
    loop {
        // SAFETY: message is writable MSG storage outliving GetMessageW; null HWND requests this thread queue.
        let result = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if result == -1 {
            let error = io::Error::last_os_error();
            finish_apply_after_message_loop_failure(window);
            // SAFETY: window is the live top-level HWND created above and this
            // path destroys it only after any worker reached terminal handoff.
            unsafe { DestroyWindow(window) };
            return Err(error);
        }
        if result == 0 {
            break;
        }
        if handle_accelerator(window, &message) {
            continue;
        }
        // SAFETY: message was initialized by GetMessageW and remains valid through synchronous translation and dispatch.
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    Ok(())
}

unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        let create = lparam as *const CREATESTRUCTW;
        if !create.is_null() {
            // SAFETY: For WM_NCCREATE, Windows supplies a non-null CREATESTRUCTW in lparam that remains readable for this callback.
            let init = unsafe { (*create).lpCreateParams as *mut WindowInit };
            if !init.is_null() {
                // SAFETY: lpCreateParams is the live WindowInit passed to CreateWindowExW; adopted and state remain valid for this synchronous callback.
                unsafe {
                    *(*init).adopted = true;
                    SetWindowLongPtrW(window, GWLP_USERDATA, (*init).state as isize);
                }
            }
        }
    }
    // SAFETY: window is the active callback HWND; GWLP_USERDATA is read only to recover the pointer installed during creation.
    let state_ptr = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut AppState;
    match message {
        WM_CREATE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the non-null Box::into_raw AppState stored for
            // this HWND and remains exclusively owned by this callback thread.
            if create_children(window, unsafe { &mut *state_ptr }).is_err() {
                return -1;
            }
            0
        }
        WM_SIZE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is non-null window-owned AppState storage and no
            // mutable reference exists while this shared layout borrow is live.
            arrange(window, unsafe { &*state_ptr });
            0
        }
        WM_GETMINMAXINFO if !state_ptr.is_null() => {
            let info = lparam as *mut MINMAXINFO;
            if !info.is_null() {
                // SAFETY: WM_GETMINMAXINFO supplies writable MINMAXINFO storage
                // for this callback and state_ptr is the live AppState.
                unsafe {
                    (*info).ptMinTrackSize.x = scale_dip(INITIAL_WIDTH, (*state_ptr).dpi);
                    (*info).ptMinTrackSize.y = scale_dip(INITIAL_HEIGHT, (*state_ptr).dpi);
                }
            }
            0
        }
        WM_DPICHANGED if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            let state = unsafe { &mut *state_ptr };
            let dpi = u32::try_from(wparam & 0xFFFF).unwrap_or(BASE_DPI);
            state.dpi = dpi.max(BASE_DPI);
            let suggested = lparam as *const RECT;
            if !suggested.is_null() {
                // SAFETY: WM_DPICHANGED supplies a readable suggested RECT for
                // this callback and SetWindowPos consumes copied coordinates.
                let suggested = unsafe { *suggested };
                // SAFETY: window is the live callback HWND and suggested is a
                // copied RECT supplied for this WM_DPICHANGED callback.
                unsafe {
                    SetWindowPos(
                        window,
                        null_mut(),
                        suggested.left,
                        suggested.top,
                        suggested.right - suggested.left,
                        suggested.bottom - suggested.top,
                        SWP_NOZORDER | SWP_NOACTIVATE,
                    )
                };
            }
            update_dpi_metrics(state);
            refresh_system_fonts(state);
            arrange(window, state);
            0
        }
        WM_SETTINGCHANGE | WM_FONTCHANGE | WM_THEMECHANGED | WM_SYSCOLORCHANGE
            if !state_ptr.is_null() =>
        {
            // SAFETY: state_ptr is the live UI-thread AppState.
            let state = unsafe { &mut *state_ptr };
            refresh_system_fonts(state);
            refresh_high_contrast_toolbars(window, state);
            arrange(window, state);
            0
        }
        WM_APP_APPLY_PROGRESS if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            handle_apply_progress(unsafe { &mut *state_ptr });
            0
        }
        WM_APP_APPLY_COMPLETE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            handle_apply_completion(window, unsafe { &mut *state_ptr });
            0
        }
        WM_APP_PLAN_COMPLETE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            handle_plan_completion(window, unsafe { &mut *state_ptr });
            0
        }
        WM_APP_ADMISSION_COMPLETE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            handle_admission_completion(window, unsafe { &mut *state_ptr });
            0
        }
        WM_TIMER if !state_ptr.is_null() && wparam == APPLY_POLL_TIMER_ID => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            let state = unsafe { &mut *state_ptr };
            if state
                .admission_worker
                .as_ref()
                .is_some_and(|worker| worker.handle.is_finished())
            {
                handle_admission_completion(window, state);
                return 0;
            }
            if state
                .plan_worker
                .as_ref()
                .is_some_and(|worker| worker.handle.is_finished())
            {
                handle_plan_completion(window, state);
                return 0;
            }
            handle_apply_progress(state);
            if state
                .apply_worker
                .as_ref()
                .is_some_and(|worker| worker.handle.is_finished())
            {
                handle_apply_completion(window, state);
            }
            0
        }
        WM_CLOSE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live UI-thread AppState for this window.
            request_window_close(window, unsafe { &mut *state_ptr });
            0
        }
        WM_COMMAND if !state_ptr.is_null() => {
            let command = (wparam & 0xFFFF) as u16;
            // SAFETY: state_ptr is the non-null, window-thread-confined AppState
            // installed in GWLP_USERDATA and is uniquely borrowed for dispatch.
            dispatch_command(window, unsafe { &mut *state_ptr }, command);
            0
        }
        WM_DROPFILES if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the live window-thread AppState pointer.
            if unsafe { (*state_ptr).read_only_locked() || (*state_ptr).mutation_locked } {
                // SAFETY: wparam is the owned HDROP delivered with this message
                // and is released exactly once on the rejected path.
                unsafe { DragFinish(wparam as HDROP) };
                self::message(
                    window,
                    "파일 변경 또는 복구 잠금 중에는 목록을 변경할 수 없습니다.",
                    "DarkReNamer - 변경 중",
                );
                return 0;
            }
            // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
            unsafe {
                admit_drop(window, &mut *state_ptr, wparam as HDROP);
            }
            0
        }
        WM_NOTIFY if !state_ptr.is_null() => {
            let header = lparam as *const NMHDR;
            if !header.is_null()
                // SAFETY: For WM_NOTIFY, non-null lparam points to an NMHDR prefix that remains readable throughout this synchronous callback.
                && unsafe { (*header).hwndFrom } == unsafe { (*state_ptr).list_window }
            {
                // SAFETY: For WM_NOTIFY, non-null lparam points to an NMHDR prefix that remains readable throughout this synchronous callback.
                if unsafe { (*header).code } == LVN_ITEMCHANGED {
                    let notification = lparam as *const NMLISTVIEW;
                    if !notification.is_null()
                        && selection_command_state_changed(
                            // SAFETY: For WM_NOTIFY, non-null lparam points to NMLISTVIEW storage owned by the sender for this synchronous callback.
                            unsafe { (*notification).uChanged },
                            // SAFETY: For WM_NOTIFY, non-null lparam points to NMLISTVIEW storage owned by the sender for this synchronous callback.
                            unsafe { (*notification).uOldState },
                            // SAFETY: For WM_NOTIFY, non-null lparam points to NMLISTVIEW storage owned by the sender for this synchronous callback.
                            unsafe { (*notification).uNewState },
                        )
                    {
                        // SAFETY: state_ptr is non-null AppState storage owned by
                        // this callback thread and is uniquely borrowed here.
                        update_controls(unsafe { &mut *state_ptr });
                    }
                // SAFETY: For WM_NOTIFY, non-null lparam points to an NMHDR prefix that remains readable throughout this synchronous callback.
                } else if unsafe { (*header).code } == NM_DBLCLK {
                    // SAFETY: state_ptr is the non-null AppState installed for
                    // this HWND and remains exclusively callback-thread owned.
                    dispatch_command(window, unsafe { &mut *state_ptr }, MANUAL_CHANGE);
                    // SAFETY: dispatch returned, so a fresh unique borrow of the
                    // same non-null window-owned AppState is valid for refresh.
                    update_controls(unsafe { &mut *state_ptr });
                }
            }
            0
        }
        WM_KEYDOWN if !state_ptr.is_null() => {
            let command = match wparam as u32 {
                0x2E => Some(0xFFFF),
                0xBC => Some(MOVE_UP),
                0xBE => Some(MOVE_DOWN),
                0x1B => Some(2),
                _ => None,
            };
            if let Some(command) = command {
                // SAFETY: state_ptr is the checked non-null AppState owned by the
                // current window callback and is uniquely borrowed for dispatch.
                dispatch_command(window, unsafe { &mut *state_ptr }, command);
            }
            0
        }
        WM_DESTROY => {
            // SAFETY: PostQuitMessage targets the current thread queue and accepts no borrowed pointers.
            unsafe { PostQuitMessage(0) };
            0
        }
        WM_NCDESTROY => {
            if !state_ptr.is_null() {
                // SAFETY: this timer identifier is process-owned; killing an
                // absent timer is harmless during defensive teardown.
                unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
                // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
                if !unsafe { (*state_ptr).font }.is_null() {
                    // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
                    unsafe { DeleteObject((*state_ptr).font) };
                }
                // SAFETY: status_font is a distinct AppState-owned HFONT and is
                // deleted exactly once at window teardown.
                if !unsafe { (*state_ptr).status_font }.is_null() {
                    // SAFETY: the non-null AppState-owned font is deleted once
                    // at the window's single WM_NCDESTROY teardown point.
                    unsafe { DeleteObject((*state_ptr).status_font) };
                }
                // SAFETY: state_ptr is the non-null Box::into_raw AppState stored at WM_NCCREATE; WM_NCDESTROY is its single reclamation point.
                unsafe { drop(Box::from_raw(state_ptr)) };
                // SAFETY: window is the active callback HWND; GWLP_USERDATA stores or clears the process-owned pointer without transferring ownership.
                unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
            }
            // SAFETY: window, message, wparam, and lparam are unchanged values from the active Windows callback.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
        _ => {
            // SAFETY: window, message, wparam, and lparam are unchanged values from the active Windows callback.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
    }
}

fn apply_changes(window: HWND, state: &mut AppState) {
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

fn handle_ready_plan(
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
    };
    let plan = ready.plan;
    if plan.is_empty() {
        message(window, "변경할 항목이 없습니다.", "DarkReNamer");
        return;
    }
    let confirmation = format!(
        "{}개 항목의 실제 이름을 변경하시겠습니까?\n파일 이동 단계 {}개\n계획 {:016X}\n목록 버전 {}",
        plan.changed_count(),
        ready.journal.primitive_steps(),
        plan.fingerprint(),
        state.model_revision,
    );
    let prompt = wide(&confirmation);
    let caption = wide("DarkReNamer - 안전한 적용 확인");
    state.mutation_locked = true;
    state.confirmation_pending = true;
    update_controls(state);
    // SAFETY: window is the live application HWND and prompt/caption are owned
    // NUL-terminated UTF-16 buffers retained through the modal MessageBoxW call.
    let confirmed_by_user =
        unsafe { MessageBoxW(window, prompt.as_ptr(), caption.as_ptr(), MB_OKCANCEL) } == IDOK;
    state.mutation_locked = false;
    state.confirmation_pending = false;
    update_controls(state);
    if state.close_pending {
        return;
    }
    if !confirmed_by_user {
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

fn handle_completed_execution(
    window: HWND,
    state: &mut AppState,
    journal: FileJournal,
    execution: Result<ExecutionReport, ExecuteError>,
) {
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
    let outcome = report.outcome().clone();
    let text = execution_outcome_korean(&outcome);
    match outcome {
        ExecutionOutcome::Completed => {
            let before = state.model.clone();
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
            state.commit_model_change(&before);
            refresh(state);
            let cleanup = cleanup_file_journal(journal);
            state.recovery_locked = cleanup.error.is_some() || cleanup.retained.is_some();
            state.active_journal = cleanup.retained;
            if let Some(error) = cleanup.error {
                message(window, &error.to_string(), "DarkReNamer - 저널 정리 실패");
            }
        }
        ExecutionOutcome::RolledBack { .. } => {
            let cleanup = cleanup_file_journal(journal);
            state.recovery_locked = cleanup.error.is_some() || cleanup.retained.is_some();
            state.active_journal = cleanup.retained;
            if let Some(error) = cleanup.error {
                message(window, &error.to_string(), "DarkReNamer - 저널 정리 실패");
            }
        }
        ExecutionOutcome::RecoveryRequired { .. } => {
            state.recovery_locked = true;
            state.active_journal = Some(journal);
        }
    }
    {
        message(window, &text, "DarkReNamer");
        update_controls(state);
    }
}

fn start_plan_worker(
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
                let plan = RenamePlanner::new(&backend)
                    .plan(request)
                    .map_err(ReadyPlanError::Plan)
                    .and_then(|plan| {
                        preflight_plan(&plan, &mut backend)
                            .map(|journal| ReadyPlan { plan, journal })
                            .map_err(ReadyPlanError::Preflight)
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
    set_status(
        state.status,
        "파일 시스템을 확인하고 실행 계획을 만들고 있습니다...",
    );
    update_controls(state);
}

fn handle_plan_completion(window: HWND, state: &mut AppState) {
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
    let joined = worker.handle.join();
    state.mutation_locked = false;
    if state.close_pending {
        // SAFETY: planning performs no mutation and the worker has joined.
        unsafe { DestroyWindow(window) };
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
                // SAFETY: the confirmation callback has returned and no worker
                // owns state, so deferred close can now destroy the window.
                unsafe { DestroyWindow(window) };
                return;
            }
        }
        Ok(PlanWorkerResult::Cancelled) => {
            set_status(state.status, "파일 변경 계획을 취소했습니다.");
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

fn start_apply_worker(window: HWND, state: &mut AppState, confirmed: crate::rename::ConfirmedPlan) {
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
    set_status(state.status, "실행 순서를 준비하고 있습니다...");
    update_controls(state);
}

fn handle_apply_progress(state: &mut AppState) {
    let Some(worker) = state.apply_worker.as_ref() else {
        return;
    };
    let phase = worker.progress.phase.load(Ordering::Acquire);
    let completed = worker.progress.completed.load(Ordering::Acquire);
    let total = worker.progress.total.load(Ordering::Acquire);
    worker.progress.wake_pending.store(false, Ordering::Release);
    let text = match phase {
        0 => format!("실행 준비 완료: {total} 단계"),
        1 => format!("파일 이름 변경 중: {completed}/{total} 단계"),
        2 => format!("취소 또는 오류 후 복원 중: {completed}/{total} 단계"),
        3 => "저널 terminal 상태를 기록했습니다.".to_owned(),
        _ => "파일 변경 상태를 확인하고 있습니다...".to_owned(),
    };
    set_status(state.status, &text);
}

fn handle_apply_completion(window: HWND, state: &mut AppState) {
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
    finalize_apply_worker(window, state, worker);
    if state.close_pending {
        // SAFETY: terminal worker handoff is complete and AppState no longer
        // owns a running thread, so the top-level window may now be destroyed.
        unsafe { DestroyWindow(window) };
    }
}

fn finalize_apply_worker(window: HWND, state: &mut AppState, worker: ApplyWorker) {
    let joined = worker.handle.join();
    state.mutation_locked = false;
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
    update_controls(state);
}

fn finish_apply_after_message_loop_failure(window: HWND) {
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
    let Some(worker) = state.apply_worker.take() else {
        return;
    };
    worker.cancellation.request();
    // SAFETY: this exact timer belongs to the still-live top-level window.
    unsafe { KillTimer(window, APPLY_POLL_TIMER_ID) };
    finalize_apply_worker(window, state, worker);
    if state.close_pending {
        state.close_pending = false;
    }
}

fn request_window_close(window: HWND, state: &mut AppState) {
    if state.confirmation_pending {
        state.close_pending = true;
        return;
    }
    if let Some(worker) = state.admission_worker.as_ref() {
        if !state.close_pending {
            state.close_pending = true;
            worker.cancellation.store(true, Ordering::Release);
            set_status(
                state.status,
                "종료 요청을 받았습니다. 현재 경로 확인이 끝나는 즉시 종료합니다...",
            );
            update_controls(state);
        }
        return;
    }
    if let Some(worker) = state.plan_worker.as_ref() {
        if !state.close_pending {
            state.close_pending = true;
            worker.cancellation.request();
            set_status(
                state.status,
                "종료 요청을 받았습니다. 파일 시스템 확인이 끝나는 즉시 종료합니다...",
            );
            update_controls(state);
        }
        return;
    }
    if let Some(worker) = state.apply_worker.as_ref() {
        if !state.close_pending {
            state.close_pending = true;
            worker.cancellation.request();
            set_status(
                state.status,
                "종료 요청을 받았습니다. 현재 단계를 마친 뒤 안전하게 취소·복원합니다...",
            );
            update_controls(state);
        }
        return;
    }
    // SAFETY: no worker owns journal or filesystem mutation state, so the
    // top-level window can be destroyed immediately.
    unsafe { DestroyWindow(window) };
}

fn admit_drop(owner: HWND, state: &mut AppState, drop: HDROP) {
    // SAFETY: drop is the live WM_DROPFILES HDROP; any output pointer has exactly the capacity passed.
    let reported = unsafe { DragQueryFileW(drop, u32::MAX, null_mut(), 0) } as usize;
    let remaining = MAX_ADMITTED_SOURCES.saturating_sub(state.model.len());
    let bounded = bounded_selection(reported, remaining);
    let mut paths = Vec::with_capacity(bounded.take);
    for index in 0..bounded.take {
        let index = u32::try_from(index).unwrap_or(u32::MAX);
        // SAFETY: drop is the live WM_DROPFILES HDROP; any output pointer has exactly the capacity passed.
        let length = unsafe { DragQueryFileW(drop, index, null_mut(), 0) };
        let mut buffer = vec![0; length as usize + 1];
        // SAFETY: drop is the live WM_DROPFILES HDROP; any output pointer has exactly the capacity passed.
        unsafe { DragQueryFileW(drop, index, buffer.as_mut_ptr(), buffer.len() as u32) };
        buffer.truncate(length as usize);
        paths.push(PathBuf::from(std::ffi::OsString::from_wide(&buffer)));
    }
    // SAFETY: drop is the owned WM_DROPFILES HDROP and is released exactly once after extraction.
    unsafe { DragFinish(drop) };
    if bounded.truncated {
        message(
            owner,
            "선택 항목이 남은 10,000개 한도를 초과해 제한된 수만 처리합니다.",
            "DarkReNamer - 추가 한도",
        );
    }
    set_status(state.status, "처리중...");
    admit_paths(owner, state, paths);
}

fn admit_paths(owner: HWND, state: &mut AppState, paths: Vec<PathBuf>) {
    let capacity = MAX_ADMITTED_SOURCES.saturating_sub(state.model.len());
    start_admission_worker(owner, state, paths, None, capacity);
}

fn start_admission_worker(
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
                let report = collect_admission(&adapter, paths, mode, capacity, |left, right| {
                    compare_windows(&legacy_path(left), &legacy_path(right))
                });
                if worker_cancellation.load(Ordering::Acquire) {
                    AdmissionWorkerResult::Cancelled
                } else {
                    AdmissionWorkerResult::Finished { revision, report }
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
    set_status(state.status, "선택한 경로를 확인하고 있습니다...");
    update_controls(state);
}

fn handle_admission_completion(window: HWND, state: &mut AppState) {
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
    let joined = worker.handle.join();
    state.mutation_locked = false;
    if state.close_pending {
        // SAFETY: admission performs no mutation and the worker has joined.
        unsafe { DestroyWindow(window) };
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
            let text =
                wide("경로를 직접 추가하려면 YES, 경로 내 파일을 추가하려면 NO를 선택하세요.");
            let caption = path_wide(&directory);
            state.mutation_locked = true;
            state.confirmation_pending = true;
            update_controls(state);
            // SAFETY: window is the live owner and both UTF-16 buffers remain
            // allocated throughout the synchronous modal call.
            let answer = unsafe { MessageBoxW(window, text.as_ptr(), caption.as_ptr(), MB_YESNO) };
            state.mutation_locked = false;
            state.confirmation_pending = false;
            if state.close_pending {
                // SAFETY: the modal callback returned and no worker owns state.
                unsafe { DestroyWindow(window) };
                return;
            }
            let mode = if answer == windows_sys::Win32::UI::WindowsAndMessaging::IDYES {
                AdmissionMode::Direct
            } else {
                AdmissionMode::Recurse
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
                let before = state.model.clone();
                let items = std::mem::take(&mut report.items);
                let appended = state.model.append_batch_by(items, compare_windows);
                state.commit_model_change(&before);
                let summary = report.summary_korean(appended);
                set_status(state.status, &summary);
                if !report.issues.is_empty() {
                    message(window, &summary, "DarkReNamer - 일부 경로 제외");
                }
                refresh(state);
            }
        }
        Ok(AdmissionWorkerResult::Cancelled) => {
            set_status(
                state.status,
                "경로 추가를 취소했습니다. 목록은 변경되지 않았습니다.",
            );
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

fn message(owner: HWND, text: &str, caption: &str) {
    let text = wide(text);
    let caption = wide(caption);
    // SAFETY: owner is a live HWND and text/caption are owned NUL-terminated
    // UTF-16 buffers retained until the synchronous MessageBoxW call returns.
    unsafe { MessageBoxW(owner, text.as_ptr(), caption.as_ptr(), 0) };
}

#[allow(
    clippy::manual_dangling_ptr,
    reason = "Win32 MAKEINTRESOURCEW encodes a numeric resource ID in a pointer value"
)]
const fn int_resource(id: u16) -> *const u16 {
    id as usize as *const u16
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    use crate::rename::{
        BackendError, BackendOperation, EntryId, EntryKind, MutationCertainty, PathKey,
        PathSnapshot, PlanRequest, RenameBackend, RenameIntent, RenameOperation,
    };

    fn create_startup_journal_directory(
        local_app_data: &Path,
    ) -> Result<PathBuf, Box<dyn std::error::Error>> {
        let journal = local_app_data.join("DarkReNamer").join("journal");
        fs::create_dir_all(&journal)?;
        Ok(journal)
    }

    #[test]
    fn apply_worker_payloads_and_capabilities_are_send() {
        fn assert_send<T: Send>() {}
        assert_send::<JournalRoot>();
        assert_send::<FileJournal>();
        assert_send::<crate::rename::ConfirmedPlan>();
        assert_send::<ApplyWorkerResult>();
        assert_send::<PlanWorkerResult>();
        assert_send::<AdmissionWorkerResult>();
    }

    struct CrashBackend {
        inner: WindowsRenameBackend,
        fail_on_attempt: Option<usize>,
        attempts: usize,
    }

    impl RenameBackend for CrashBackend {
        fn validate_path_environment(&self, path: &LegacyText) -> Result<(), BackendError> {
            self.inner.validate_path_environment(path)
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
            self.attempts = self.attempts.saturating_add(1);
            if self.fail_on_attempt == Some(self.attempts) {
                return Err(BackendError {
                    operation: BackendOperation::Rename,
                    code: 123,
                    certainty: MutationCertainty::NotApplied,
                });
            }
            self.inner.rename_no_replace(operation)
        }
    }

    #[test]
    fn crash_recovery_child() -> Result<(), Box<dyn std::error::Error>> {
        if env::var("DARKRENAMER_TEST_CHILD_MODE").as_deref() != Ok("1") {
            return Ok(());
        }
        let Some(local_app_data) = env::var_os("DARKRENAMER_TEST_CHILD_ROOT") else {
            return Err(io::Error::other("crash child root missing").into());
        };
        let local_app_data = PathBuf::from(local_app_data);
        let nonce = env::var("DARKRENAMER_TEST_FIXTURE_NONCE")?;
        let marker = fs::read_to_string(local_app_data.join("fixture-nonce.txt"))?;
        let canonical_root = fs::canonicalize(&local_app_data)?;
        let canonical_temp = fs::canonicalize(env::temp_dir())?;
        if marker != nonce
            || !local_app_data.is_absolute()
            || !canonical_root.starts_with(&canonical_temp)
        {
            return Err(io::Error::other("crash fixture authority mismatch").into());
        }
        let journal_directory = create_startup_journal_directory(&local_app_data)?;
        let data = local_app_data.join("data");
        let source_a = data.join("a.txt");
        let source_b = data.join("b.txt");
        let mut backend = CrashBackend {
            inner: WindowsRenameBackend,
            fail_on_attempt: (env::var_os("DARKRENAMER_TEST_FORCE_ROLLBACK").is_some())
                .then_some(2),
            attempts: 0,
        };
        backend.validate_path_environment(&legacy_path(&source_a))?;
        let intents = vec![
            RenameIntent::new(
                EntryId::new(0),
                legacy_path(&source_a),
                legacy_path(&data),
                "b.txt",
                EntryKind::File,
            ),
            RenameIntent::new(
                EntryId::new(1),
                legacy_path(&source_b),
                legacy_path(&data),
                "a.txt",
                EntryKind::File,
            ),
        ];
        let plan =
            RenamePlanner::new(&backend).plan(PlanRequest::new(ModelRevision::new(1), intents))?;
        let id = plan.id();
        let revision = plan.revision();
        let root = JournalRoot::open(&journal_directory)?;
        let mut journal =
            FileJournal::create_candidate(&root, CANDIDATE_JOURNAL_LEAF, ACTIVE_JOURNAL_LEAF)?;

        let _report = RenameExecutor::new(&mut backend, &mut journal)
            .execute(plan.confirm_presented(id, revision)?)?;
        Err(io::Error::other("configured crash point was not reached").into())
    }

    fn run_crash_recovery_case(
        point: &str,
        force_rollback: bool,
        expect_swapped: bool,
        expect_staged_lock: bool,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let data = directory.path().join("data");
        fs::create_dir(&data)?;
        fs::write(data.join("a.txt"), b"a")?;
        fs::write(data.join("b.txt"), b"b")?;
        fs::write(data.join("sentinel.txt"), b"external")?;
        let nonce = format!("{}-{point}", std::process::id());
        fs::write(directory.path().join("fixture-nonce.txt"), &nonce)?;
        let mut command = Command::new(std::env::current_exe()?);
        command
            .arg("--exact")
            .arg("windows::tests::crash_recovery_child")
            .arg("--nocapture")
            .arg("--test-threads=1")
            .env("DARKRENAMER_TEST_CHILD_MODE", "1")
            .env("DARKRENAMER_TEST_CHILD_ROOT", directory.path())
            .env("DARKRENAMER_TEST_FIXTURE_NONCE", &nonce)
            .env("DARKRENAMER_TEST_CRASH_POINT", point)
            .env_remove("DARKRENAMER_TEST_FORCE_ROLLBACK");
        if force_rollback {
            command.env("DARKRENAMER_TEST_FORCE_ROLLBACK", "1");
        }

        let status = command.status()?;
        if status.code() != Some(86) {
            return Err(
                io::Error::other(format!("child did not stop at {point}: {status}")).into(),
            );
        }

        let runtime = initialize_safe_runtime_at(directory.path())?;
        if expect_staged_lock {
            assert!(runtime.recovery_locked);
            assert!(runtime.staged_journal.is_some());
        } else {
            assert!(runtime.active_journal.is_none());
        }
        drop(runtime);

        let (expected_a, expected_b) = if expect_swapped {
            (b"b".as_slice(), b"a".as_slice())
        } else {
            (b"a".as_slice(), b"b".as_slice())
        };
        assert_eq!(fs::read(data.join("a.txt"))?, expected_a);
        assert_eq!(fs::read(data.join("b.txt"))?, expected_b);
        assert_eq!(fs::read(data.join("sentinel.txt"))?, b"external");
        assert!(
            fs::read_dir(&data)?.all(|entry| {
                entry
                    .ok()
                    .and_then(|entry| entry.file_name().into_string().ok())
                    .is_none_or(|name| !name.contains(".__darknamer_"))
            }),
            "temporary rename endpoint remained after startup recovery"
        );
        let journal_directory = directory.path().join("DarkReNamer").join("journal");
        if expect_staged_lock {
            assert!(journal_directory.join(CANDIDATE_JOURNAL_LEAF).exists());
            assert!(!journal_directory.join(ACTIVE_JOURNAL_LEAF).exists());
        } else {
            assert!(!journal_directory.join(CANDIDATE_JOURNAL_LEAF).exists());
            assert!(!journal_directory.join(ACTIVE_JOURNAL_LEAF).exists());
        }
        Ok(())
    }

    #[test]
    fn crash_recovery_matrix_uses_real_windows_backend_and_file_journal()
    -> Result<(), Box<dyn std::error::Error>> {
        for (point, force_rollback, expect_swapped, expect_staged_lock) in [
            ("staged-intent-synced", false, false, true),
            ("active-intent-promoted", false, false, false),
            ("forward-prepared-0", false, false, false),
            ("forward-rename-0", false, false, false),
            ("forward-completed-0", false, false, false),
            ("rollback-prepared-0", true, false, false),
            ("rollback-rename-0", true, false, false),
            ("rollback-completed-0", true, false, false),
            ("terminal-committed", false, true, false),
            ("terminal-rolled-back", true, false, false),
        ] {
            run_crash_recovery_case(point, force_rollback, expect_swapped, expect_staged_lock)?;
        }
        Ok(())
    }

    #[test]
    fn legacy_text_files_round_trip_utf16le_bom() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("names.txt");
        let expected = LegacyText::from("첫째.txt\r\n둘째.txt\r\n");
        write_legacy_text(&path, &expected)?;
        let bytes = fs::read(&path)?;
        assert!(bytes.starts_with(&[0xFF, 0xFE]));
        assert_eq!(read_legacy_text(&path)?, expected);
        Ok(())
    }

    #[test]
    fn ttoi_compatibility_accepts_numeric_prefixes() {
        assert_eq!(legacy_atoi(&LegacyText::from("  -12suffix")), -12);
        assert_eq!(legacy_atoi(&LegacyText::from("3abc")), 3);
        assert_eq!(legacy_atoi(&LegacyText::from("abc3")), 0);
    }

    #[test]
    fn corrupt_active_journal_starts_recovery_locked_with_retained_evidence()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let journal_directory = create_startup_journal_directory(directory.path())?;
        let active = journal_directory.join(ACTIVE_JOURNAL_LEAF);
        let corrupt = vec![0_u8; 24];
        fs::write(&active, &corrupt)?;

        let runtime = initialize_safe_runtime_at(directory.path())?;

        assert!(runtime.recovery_locked);
        assert!(runtime.active_journal.is_none());
        assert_eq!(runtime.blocked_journals.len(), 1);
        assert!(matches!(
            runtime.blocked_journals[0],
            StartupJournalBlock::Evidence { .. }
        ));
        let status = runtime.status.as_deref().unwrap_or_default();
        assert!(status.contains("원본 핸들을 보존"));
        assert!(status.contains(&active.display().to_string()));
        assert!(fs::read(&active).is_err());
        drop(runtime);
        assert_eq!(fs::read(active)?, corrupt);
        Ok(())
    }

    fn startup_intent_bytes() -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let step = crate::rename::JournalStep::new(
            crate::rename::EntryId::new(0),
            LegacyText::from("C:\\work\\a.txt"),
            LegacyText::from("C:\\work\\b.txt"),
            crate::rename::EntryIdentity::new(7, 10),
            crate::rename::EntryIdentity::new(7, 1),
            crate::rename::EntryIdentity::new(7, 1),
            crate::rename::TemporaryPhase::None,
        );
        Ok(crate::rename::encode_journal_records(&[
            crate::rename::JournalRecord::Intent {
                plan: crate::rename::PlanId::from_fingerprint(77),
                steps: vec![step].into_boxed_slice(),
            },
        ])?)
    }

    #[test]
    fn physically_empty_candidate_is_deleted_and_startup_unlocks()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let journal_directory = create_startup_journal_directory(directory.path())?;
        let root = JournalRoot::open(&journal_directory)?;
        let candidate =
            FileJournal::create_candidate(&root, CANDIDATE_JOURNAL_LEAF, ACTIVE_JOURNAL_LEAF)?;
        drop(candidate);
        drop(root);

        let runtime = initialize_safe_runtime_at(directory.path())?;

        assert!(!runtime.recovery_locked);
        assert!(runtime.staged_journal.is_none());
        assert!(!journal_directory.join(CANDIDATE_JOURNAL_LEAF).exists());
        Ok(())
    }

    #[test]
    fn intent_only_candidate_exports_discards_and_unlocks_after_rediscovery()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let journal_directory = create_startup_journal_directory(directory.path())?;
        fs::write(
            journal_directory.join(CANDIDATE_JOURNAL_LEAF),
            startup_intent_bytes()?,
        )?;

        let mut state = AppState::new(initialize_safe_runtime_at(directory.path())?);

        assert!(state.recovery_locked);
        assert!(state.can_export_recovery_journal());
        assert!(state.can_discard_staged_intent());
        let mut staged = state
            .staged_journal
            .take()
            .ok_or_else(|| io::Error::other("staged journal missing"))?;
        staged.mark_unactivated_intent_delete()?;
        drop(staged);
        rediscover_after_staged_discard(&mut state);
        assert!(!state.recovery_locked);
        assert!(state.active_journal.is_none());
        assert!(state.staged_journal.is_none());
        assert!(state.blocked_journals.is_empty());
        assert!(!state.can_export_recovery_journal());
        assert!(!state.can_discard_staged_intent());
        Ok(())
    }

    #[test]
    fn active_candidate_collision_preserves_both_without_running_recovery()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let journal_directory = create_startup_journal_directory(directory.path())?;
        let bytes = startup_intent_bytes()?;
        let active = journal_directory.join(ACTIVE_JOURNAL_LEAF);
        let candidate = journal_directory.join(CANDIDATE_JOURNAL_LEAF);
        fs::write(&active, &bytes)?;
        fs::write(&candidate, &bytes)?;

        let state = AppState::new(initialize_safe_runtime_at(directory.path())?);

        assert!(state.recovery_locked);
        assert!(state.collision_observed);
        assert!(state.active_journal.is_some());
        assert!(state.staged_journal.is_some());
        assert!(state.can_export_recovery_journal());
        assert!(!state.can_discard_staged_intent());
        drop(state);
        assert_eq!(fs::read(active)?, bytes);
        assert_eq!(fs::read(candidate)?, bytes);
        Ok(())
    }

    #[test]
    fn runtime_lock_rejects_a_second_instance_until_the_first_closes()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let first = initialize_safe_runtime_at(directory.path())?;

        let second = initialize_safe_runtime_at(directory.path());
        assert!(second.is_err());

        drop(first);
        let reopened = initialize_safe_runtime_at(directory.path())?;
        drop(reopened);
        Ok(())
    }

    #[test]
    fn unavailable_active_journal_starts_locked_without_reopening_for_copy()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let journal_directory = create_startup_journal_directory(directory.path())?;
        let root = JournalRoot::open(&journal_directory)?;
        let mut held = FileJournal::create_new(&root, ACTIVE_JOURNAL_LEAF)?;
        drop(root);

        let runtime = initialize_safe_runtime_at(directory.path())?;

        assert!(runtime.recovery_locked);
        assert_eq!(runtime.blocked_journals.len(), 1);
        assert!(matches!(
            runtime.blocked_journals[0],
            StartupJournalBlock::Unavailable { .. }
        ));
        assert!(
            runtime
                .status
                .as_deref()
                .unwrap_or_default()
                .contains("경로를 다시 열어 복사하지 않")
        );
        drop(runtime);
        held.mark_delete_if_safe()?;
        drop(held);
        assert!(!journal_directory.join(ACTIVE_JOURNAL_LEAF).exists());
        Ok(())
    }

    #[test]
    fn corrupt_active_and_candidate_retain_two_exportable_handles()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let journal_directory = create_startup_journal_directory(directory.path())?;
        let active = journal_directory.join(ACTIVE_JOURNAL_LEAF);
        let candidate = journal_directory.join(CANDIDATE_JOURNAL_LEAF);
        fs::write(&active, vec![0_u8; 24])?;
        fs::write(&candidate, vec![1_u8; 24])?;

        let runtime = initialize_safe_runtime_at(directory.path())?;

        assert!(runtime.recovery_locked);
        assert_eq!(runtime.blocked_journals.len(), 2);
        assert!(
            runtime
                .blocked_journals
                .iter()
                .all(|blocked| matches!(blocked, StartupJournalBlock::Evidence { .. }))
        );
        let status = runtime.status.as_deref().unwrap_or_default();
        assert!(status.contains(&active.display().to_string()));
        assert!(status.contains(&candidate.display().to_string()));
        drop(runtime);
        assert!(active.exists());
        assert!(candidate.exists());
        Ok(())
    }

    #[test]
    fn recovery_lock_allows_only_diagnostics_about_and_exit() {
        assert!(recovery_command_allowed(EXPORT_RECOVERY_JOURNAL));
        assert!(recovery_command_allowed(DISCARD_STAGED_JOURNAL));
        assert!(recovery_command_allowed(SHOW_RECOVERY_STATUS));
        assert!(recovery_command_allowed(VERSION));
        assert!(recovery_command_allowed(2));
        for command in [APPLY, ADD_FILES, IMPORT_PATHS, REPLACE, RESET, 0xFFFF] {
            assert!(!recovery_command_allowed(command));
        }
    }

    fn rendered_test_row(label: &str, icon: i32) -> RenderedRow {
        RenderedRow {
            values: core::array::from_fn(|column| LegacyText::from(format!("{label}-{column}"))),
            icon,
        }
    }

    #[test]
    fn listview_diff_marks_only_the_changed_cell_or_icon() {
        let original = rendered_test_row("row", 7);
        let mut proposal = original.clone();
        proposal.values[1] = LegacyText::from("changed");
        assert_eq!(changed_column_mask(&original, &proposal), 1 << 1);

        let mut icon = original.clone();
        icon.icon = 8;
        assert_eq!(changed_column_mask(&original, &icon), 1);
        assert_eq!(changed_column_mask(&original, &original), 0);
    }

    #[test]
    fn listview_diff_for_ten_thousand_rows_has_one_native_row_update() {
        let old = (0..10_000)
            .map(|index| rendered_test_row(&format!("row-{index}"), 1))
            .collect::<Vec<_>>();
        let mut new = old.clone();
        new[7_654].values[1] = LegacyText::from("one changed proposal");

        let updates = old
            .iter()
            .zip(&new)
            .filter(|(old, new)| changed_column_mask(old, new) != 0)
            .collect::<Vec<_>>();

        assert_eq!(updates.len(), 1);
        assert_eq!(changed_column_mask(updates[0].0, updates[0].1), 1 << 1);
    }

    #[test]
    fn every_toolbar_command_has_single_line_accessibility_text() {
        for tool in LEFT_TOOLS.into_iter().chain(RIGHT_TOOLS) {
            let name = toolbar_accessible_name(tool.id);
            assert!(!name.is_empty());
            assert!(!name.contains('\n'));
        }
        assert!(toolbar_accessible_name(UNIFY_PATH).contains("지원하지 않음"));
        assert!(toolbar_width_dip(true) > toolbar_width_dip(false));
    }

    #[test]
    fn move_file_supports_cross_parent_file_and_directory_moves()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let source_root = directory.path().join("source");
        let target_root = directory.path().join("target");
        fs::create_dir_all(&source_root)?;
        fs::create_dir_all(&target_root)?;
        let source_file = source_root.join("old.txt");
        let target_file = target_root.join("new.txt");
        fs::write(&source_file, b"legacy")?;
        assert_ne!(
            // SAFETY: Both disposable-test paths are owned terminated UTF-16 buffers retained through MoveFileW.
            unsafe {
                MoveFileW(
                    path_wide(&source_file).as_ptr(),
                    path_wide(&target_file).as_ptr(),
                )
            },
            0
        );
        assert_eq!(fs::read(&target_file)?, b"legacy");

        let source_directory = source_root.join("old-folder");
        let target_directory = target_root.join("new-folder");
        fs::create_dir(&source_directory)?;
        assert_ne!(
            // SAFETY: Both disposable-test paths are owned terminated UTF-16 buffers retained through MoveFileW.
            unsafe {
                MoveFileW(
                    path_wide(&source_directory).as_ptr(),
                    path_wide(&target_directory).as_ptr(),
                )
            },
            0
        );
        assert!(target_directory.is_dir());
        Ok(())
    }
}
