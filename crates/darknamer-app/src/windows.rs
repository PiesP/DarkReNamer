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
    JournalCleanupDecision, JournalOpenFailure, JournalRoot, ModelRevision, PlanError,
    RecoveryJournalEvidence, RecoveryOutcome, RenameExecutor, RenamePlan, RenamePlanner,
    RenameRecovery, WindowsRenameBackend, apply_execution_report, build_plan_request,
    cleanup_decision, execute_error_korean, execution_outcome_korean, next_model_revision,
    plan_error_korean, process_is_elevated, safe_mode_unify_path_message,
};
use darknamer_core::{
    LegacyInputError, LegacyList, LegacyListItem, LegacySequenceMode, LegacySortMode, LegacyText,
    SortSemantics,
};

mod clipboard;
mod list_view;
#[path = "../resource_ids.rs"]
mod resource_ids;
mod safe_runtime;
mod text_io;

use clipboard::copy_clipboard;
#[cfg(test)]
use list_view::changed_column_mask;
use list_view::{RenderedRow, refresh, update_column_visibility, update_dpi_metrics};
#[cfg(test)]
use safe_runtime::initialize_safe_runtime_at;
use safe_runtime::{
    SafeRuntime, StartupJournalBlock, cleanup_file_journal, initialize_safe_runtime,
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
    apply_worker: Option<ApplyWorker>,
    plan_worker: Option<PlanWorker>,
    admission_worker: Option<AdmissionWorker>,
    close_pending: bool,
    confirmation_pending: bool,
    startup_status: Option<String>,
    icon_cache: HashMap<IconCacheKey, i32>,
    rendered_rows: Vec<RenderedRow>,
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
            active_journal: runtime.active_journal,
            staged_journal: runtime.staged_journal,
            blocked_journals: runtime.blocked_journals,
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
        plan: Result<RenamePlan, PlanError>,
    },
    Cancelled,
    Panicked,
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

fn nonclient_metrics(dpi: u32) -> Option<NONCLIENTMETRICSW> {
    let mut metrics = NONCLIENTMETRICSW {
        cbSize: u32::try_from(size_of::<NONCLIENTMETRICSW>()).ok()?,
        ..NONCLIENTMETRICSW::default()
    };
    // SAFETY: metrics is writable NONCLIENTMETRICSW storage with the exact
    // checked size; no pointer is retained after the synchronous call.
    let success = unsafe {
        SystemParametersInfoForDpi(
            SPI_GETNONCLIENTMETRICS,
            metrics.cbSize,
            (&mut metrics as *mut NONCLIENTMETRICSW).cast(),
            0,
            dpi.max(BASE_DPI),
        )
    };
    (success != 0).then_some(metrics)
}

fn create_message_font(dpi: u32) -> HFONT {
    let Some(metrics) = nonclient_metrics(dpi) else {
        return null_mut();
    };
    // SAFETY: lfMessageFont is fully initialized by SystemParametersInfoForDpi
    // and the native call copies the descriptor synchronously.
    unsafe { CreateFontIndirectW(&raw const metrics.lfMessageFont) }
}

fn create_status_font(dpi: u32) -> HFONT {
    let Some(metrics) = nonclient_metrics(dpi) else {
        return null_mut();
    };
    // SAFETY: lfStatusFont is fully initialized by SystemParametersInfoForDpi
    // and the native call copies the descriptor synchronously.
    unsafe { CreateFontIndirectW(&raw const metrics.lfStatusFont) }
}

fn refresh_system_fonts(state: &mut AppState) {
    let message_font = create_message_font(state.dpi);
    let status_font = create_status_font(state.dpi);
    // SAFETY: child HWNDs are live; a null font selects the control's default.
    unsafe {
        SendMessageW(state.list_window, WM_SETFONT, message_font as usize, 1);
        SendMessageW(state.status, WM_SETFONT, status_font as usize, 1);
    }
    if !state.font.is_null() {
        // SAFETY: AppState owns this font and replaces it exactly once here.
        unsafe { DeleteObject(state.font) };
    }
    if !state.status_font.is_null() {
        // SAFETY: AppState owns this distinct font and replaces it once here.
        unsafe { DeleteObject(state.status_font) };
    }
    state.font = message_font;
    state.status_font = status_font;
}

fn high_contrast_enabled() -> bool {
    let mut contrast = HIGHCONTRASTW {
        cbSize: u32::try_from(size_of::<HIGHCONTRASTW>()).unwrap_or(0),
        ..HIGHCONTRASTW::default()
    };
    // SAFETY: contrast is writable HIGHCONTRASTW storage with its checked size.
    let success = unsafe {
        SystemParametersInfoW(
            SPI_GETHIGHCONTRAST,
            contrast.cbSize,
            (&mut contrast as *mut HIGHCONTRASTW).cast(),
            0,
        )
    };
    success != 0 && contrast.dwFlags & HCF_HIGHCONTRASTON != 0
}

fn create_children(window: HWND, state: &mut AppState) -> io::Result<()> {
    // SAFETY: window is the live top-level HWND being initialized.
    let dpi = unsafe { GetDpiForWindow(window) };
    state.dpi = if dpi == 0 { BASE_DPI } else { dpi };
    state.high_contrast = high_contrast_enabled();
    // SAFETY: A null module name requests the current process module and dereferences no caller memory.
    let instance = unsafe { GetModuleHandleW(null()) };
    let list_class = wide("SysListView32");
    // SAFETY: window and instance are the live top-level HWND/module; the static
    // ListView class and null creation parameter require no borrowed storage.
    state.list_window = unsafe {
        CreateWindowExW(
            0,
            list_class.as_ptr(),
            null(),
            WS_CHILD
                | WS_VISIBLE
                | WS_BORDER
                | WS_TABSTOP
                | LVS_REPORT
                | LVS_SHOWSELALWAYS
                | LVS_SHAREIMAGELISTS
                | LVS_NOSORTHEADER,
            0,
            0,
            0,
            0,
            window,
            LIST_ID as *mut c_void,
            instance,
            null_mut(),
        )
    };
    if state.list_window.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: state.list_window is live; each zeroed LVCOLUMNW is populated
    // before its synchronous message and its mutable text buffer stays allocated.
    unsafe {
        SendMessageW(
            state.list_window,
            LVM_SETEXTENDEDLISTVIEWSTYLE,
            0,
            (LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER) as isize,
        );
        for (index, column) in COLUMNS.iter().enumerate() {
            let mut text = wide(column.label);
            let mut native = LVCOLUMNW {
                mask: LVCF_TEXT | LVCF_WIDTH | LVCF_FMT,
                fmt: if index == 4 {
                    LVCFMT_RIGHT
                } else {
                    LVCFMT_LEFT
                },
                cx: scale_dip(column.default_width, state.dpi),
                pszText: text.as_mut_ptr(),
                ..zeroed()
            };
            SendMessageW(
                state.list_window,
                LVM_INSERTCOLUMNW,
                index,
                (&mut native as *mut LVCOLUMNW) as isize,
            );
        }
    }
    state.status = {
        child(
            window,
            "STATIC",
            "",
            STATUS_ID as u16,
            SS_CENTERIMAGE | SS_SUNKEN,
        )
    };
    state.left_toolbar = {
        create_toolbar(
            window,
            instance,
            LEFT_TOOLBAR_ID,
            resource_ids::LEFT_TOOLBAR_BITMAP,
            &LEFT_TOOLBAR_ITEMS,
            state.dpi,
            state.high_contrast,
        )?
    };
    state.right_toolbar = {
        create_toolbar(
            window,
            instance,
            RIGHT_TOOLBAR_ID,
            resource_ids::RIGHT_TOOLBAR_BITMAP,
            &RIGHT_TOOLBAR_ITEMS,
            state.dpi,
            state.high_contrast,
        )?
    };
    refresh_system_fonts(state);
    // SAFETY: window is the live top-level HWND and DragAcceptFiles stores no borrowed pointer.
    unsafe { DragAcceptFiles(window, 1) };
    let menu = { create_menu() };
    state.menu = menu;
    // SAFETY: window and menu are live HWND/HMENU values; SetMenu attaches the owned menu to that window.
    unsafe { SetMenu(window, menu) };
    // SAFETY: SHFILEINFOW is a C-compatible output structure whose all-zero state is valid before the shell fills it.
    let mut shell_info: SHFILEINFOW = unsafe { zeroed() };
    let empty = wide("");
    // SAFETY: The lookup path is owned terminated UTF-16 and info is writable SHFILEINFOW retained for the shell query.
    let image_list = unsafe {
        SHGetFileInfoW(
            empty.as_ptr(),
            0,
            &mut shell_info,
            size_of::<SHFILEINFOW>() as u32,
            SHGFI_SYSICONINDEX | SHGFI_SMALLICON,
        )
    };
    if image_list != 0 {
        // SAFETY: state.list_window is live and LVM_SETIMAGELIST carries the
        // shell-owned image-list handle without a caller pointer payload.
        unsafe {
            SendMessageW(
                state.list_window,
                LVM_SETIMAGELIST,
                LVSIL_SMALL as usize,
                image_list as isize,
            )
        };
    }
    arrange(window, state);
    refresh(state);
    if let Some(status) = state.startup_status.as_deref() {
        set_status(state.status, status);
    }
    Ok(())
}

fn child(parent: HWND, class: &str, text: &str, id: u16, extra_style: u32) -> HWND {
    let class = wide(class);
    let text = wide(text);
    // SAFETY: parent is a live HWND and the owned terminated class/text buffers
    // remain allocated through this synchronous child CreateWindowExW call.
    unsafe {
        CreateWindowExW(
            0,
            class.as_ptr(),
            text.as_ptr(),
            WS_CHILD | WS_VISIBLE | extra_style,
            0,
            0,
            0,
            0,
            parent,
            id as usize as *mut c_void,
            GetModuleHandleW(null()),
            null_mut(),
        )
    }
}

fn create_toolbar(
    parent: HWND,
    instance: windows_sys::Win32::Foundation::HINSTANCE,
    control_id: usize,
    resource_id: u16,
    items: &[ToolbarItem],
    dpi: u32,
    high_contrast: bool,
) -> io::Result<HWND> {
    let styles = WS_CHILD
        | WS_VISIBLE
        | TBSTYLE_FLAT
        | TBSTYLE_TOOLTIPS
        | CCS_VERT as u32
        | CCS_NORESIZE as u32
        | CCS_NOPARENTALIGN as u32;
    // SAFETY: parent/instance are live HWND/module values and TOOLBARCLASSNAMEW
    // plus the null creation parameter require no caller-owned string storage.
    let toolbar = unsafe {
        CreateWindowExW(
            0,
            TOOLBARCLASSNAMEW,
            null(),
            styles,
            0,
            0,
            0,
            0,
            parent,
            control_id as *mut c_void,
            instance,
            null_mut(),
        )
    };
    if toolbar.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: toolbar is live and TBBUTTON's structure size is passed by value;
    // TB_BUTTONSTRUCTSIZE carries no pointer payload.
    unsafe {
        SendMessageW(toolbar, TB_BUTTONSTRUCTSIZE, size_of::<TBBUTTON>(), 0);
        SendMessageW(toolbar, TB_SETMAXTEXTROWS, 0, 0);
        SendMessageW(
            toolbar,
            TB_SETBITMAPSIZE,
            0,
            packed_dimensions(
                scale_dip(TOOLBAR_BITMAP_WIDTH, dpi),
                scale_dip(TOOLBAR_BITMAP_HEIGHT, dpi),
            ),
        );
        SendMessageW(
            toolbar,
            TB_SETBUTTONSIZE,
            0,
            packed_dimensions(
                scale_dip(toolbar_width_dip(high_contrast), dpi),
                scale_dip(TOOLBAR_BUTTON_HEIGHT, dpi),
            ),
        );
    }
    let first_bitmap = if high_contrast {
        0
    } else {
        let bitmap_count = items
            .iter()
            .filter(|item| matches!(item, ToolbarItem::Command(_)))
            .count();
        let bitmap = TBADDBITMAP {
            hInst: instance,
            nID: usize::from(resource_id),
        };
        // SAFETY: toolbar is live and resource_id identifies a linked bitmap;
        // the structure remains allocated through the synchronous message.
        let first = unsafe {
            SendMessageW(
                toolbar,
                TB_ADDBITMAP,
                bitmap_count,
                (&raw const bitmap) as isize,
            )
        };
        i32::try_from(first)
            .ok()
            .filter(|index| *index >= 0)
            .ok_or_else(|| io::Error::other("could not load native toolbar bitmap resource"))?
    };
    let mut image_index = 0_i32;
    let mut buttons = Vec::with_capacity(items.len());
    for item in items {
        let button = match *item {
            ToolbarItem::Command(command) => {
                let mut name = toolbar_accessible_name(command)
                    .encode_utf16()
                    .chain([0, 0])
                    .collect::<Vec<_>>();
                // SAFETY: toolbar copies the double-NUL-terminated string pool
                // synchronously before this owned buffer is dropped.
                let string_index =
                    unsafe { SendMessageW(toolbar, TB_ADDSTRINGW, 0, name.as_mut_ptr() as isize) };
                if string_index < 0 {
                    return Err(io::Error::other("could not add toolbar accessibility text"));
                }
                let button = TBBUTTON {
                    iBitmap: if high_contrast {
                        I_IMAGENONE
                    } else {
                        first_bitmap + image_index
                    },
                    idCommand: i32::from(command),
                    fsState: TBSTATE_ENABLED as u8,
                    fsStyle: u8::try_from(
                        TBSTYLE_BUTTON | if high_contrast { BTNS_SHOWTEXT } else { 0 },
                    )
                    .unwrap_or(TBSTYLE_BUTTON as u8),
                    iString: string_index,
                    ..TBBUTTON::default()
                };
                image_index += 1;
                button
            }
            ToolbarItem::Separator => TBBUTTON {
                iBitmap: scale_dip(TOOLBAR_SEPARATOR_SIZE, dpi),
                fsStyle: TBSTYLE_SEP as u8,
                ..TBBUTTON::default()
            },
        };
        buttons.push(button);
    }
    // SAFETY: toolbar is live and buttons is readable for exactly added entries;
    // its TBBUTTON storage remains allocated until TB_ADDBUTTONSW returns.
    let added = unsafe {
        SendMessageW(
            toolbar,
            TB_ADDBUTTONS,
            buttons.len(),
            buttons.as_ptr() as isize,
        )
    };
    if added == 0 {
        return Err(io::Error::other("could not add native toolbar buttons"));
    }
    Ok(toolbar)
}

fn refresh_high_contrast_toolbars(window: HWND, state: &mut AppState) {
    let high_contrast = high_contrast_enabled();
    if high_contrast == state.high_contrast {
        return;
    }
    // SAFETY: null requests the current process module.
    let instance = unsafe { GetModuleHandleW(null()) };
    let left = match create_toolbar(
        window,
        instance,
        LEFT_TOOLBAR_ID,
        resource_ids::LEFT_TOOLBAR_BITMAP,
        &LEFT_TOOLBAR_ITEMS,
        state.dpi,
        high_contrast,
    ) {
        Ok(toolbar) => toolbar,
        Err(error) => {
            message(
                window,
                &format!("고대비 도구 모음을 만들지 못했습니다: {error}"),
                "DarkReNamer - 표시 설정",
            );
            return;
        }
    };
    let right = match create_toolbar(
        window,
        instance,
        RIGHT_TOOLBAR_ID,
        resource_ids::RIGHT_TOOLBAR_BITMAP,
        &RIGHT_TOOLBAR_ITEMS,
        state.dpi,
        high_contrast,
    ) {
        Ok(toolbar) => toolbar,
        Err(error) => {
            // SAFETY: left was created above but not adopted into AppState.
            unsafe { DestroyWindow(left) };
            message(
                window,
                &format!("고대비 도구 모음을 만들지 못했습니다: {error}"),
                "DarkReNamer - 표시 설정",
            );
            return;
        }
    };
    // SAFETY: replacement toolbars are live; old child windows are destroyed
    // only after both replacements succeeded.
    unsafe {
        DestroyWindow(state.left_toolbar);
        DestroyWindow(state.right_toolbar);
    }
    state.left_toolbar = left;
    state.right_toolbar = right;
    state.high_contrast = high_contrast;
    apply_command_states(state);
}

const fn packed_dimensions(width: i32, height: i32) -> isize {
    ((width as u32 & 0xFFFF) | ((height as u32 & 0xFFFF) << 16)) as isize
}

fn toolbar_accessible_name(command: CommandId) -> String {
    if command == UNIFY_PATH {
        return "경로 통일하기 - 현재 지원하지 않음".to_owned();
    }
    LEFT_TOOLS
        .iter()
        .chain(&RIGHT_TOOLS)
        .find(|tool| tool.id == command)
        .map_or_else(
            || format!("명령 {command}"),
            |tool| tool.label.replace('\n', " "),
        )
}

const fn toolbar_width_dip(high_contrast: bool) -> i32 {
    if high_contrast { 120 } else { TOOLBAR_WIDTH }
}

fn arrange(window: HWND, state: &AppState) {
    // SAFETY: RECT is a C-compatible integer structure for which all-zero is a valid writable initial state.
    let mut rect: RECT = unsafe { zeroed() };
    // SAFETY: window is live and rect is writable RECT storage retained until GetClientRect returns.
    unsafe { GetClientRect(window, &mut rect) };
    let toolbar_width = scale_dip(toolbar_width_dip(state.high_contrast), state.dpi);
    let status_height = scale_dip(STATUS_HEIGHT, state.dpi);
    let width = rect.right.max(toolbar_width * 2 + 1);
    let height = rect.bottom.max(status_height + 1);
    // SAFETY: window plus AppState's list/status/toolbars are live child HWNDs on
    // this thread; each MoveWindow call retains no borrowed storage.
    unsafe {
        MoveWindow(
            state.left_toolbar,
            0,
            0,
            toolbar_width,
            height - status_height,
            1,
        );
        MoveWindow(
            state.right_toolbar,
            width - toolbar_width,
            0,
            toolbar_width,
            height - status_height,
            1,
        );
        MoveWindow(
            state.list_window,
            toolbar_width,
            0,
            width - toolbar_width * 2,
            height - status_height,
            1,
        );
        MoveWindow(
            state.status,
            0,
            height - status_height,
            width,
            status_height,
            1,
        );
    }
}

fn move_window_dip(window: HWND, x: i32, y: i32, width: i32, height: i32, dpi: u32) {
    // SAFETY: callers pass a live child HWND and this helper forwards only
    // scaled integer geometry without borrowed pointers.
    unsafe {
        MoveWindow(
            window,
            scale_dip(x, dpi),
            scale_dip(y, dpi),
            scale_dip(width, dpi),
            scale_dip(height, dpi),
            1,
        )
    };
}

#[derive(Clone, Debug)]
struct PromptSpec {
    title: String,
    label_one: String,
    label_two: String,
    value_one: LegacyText,
    value_two: LegacyText,
    choices: Vec<String>,
}

#[derive(Clone, Debug)]
struct PromptResult {
    value_one: LegacyText,
    value_two: LegacyText,
    choice: usize,
}

struct PromptState {
    spec: PromptSpec,
    result: Option<PromptResult>,
    done: bool,
    edit_one: HWND,
    edit_two: HWND,
    combo: HWND,
    font: HFONT,
    dpi: u32,
}

struct OwnerEnableGuard {
    owner: HWND,
}

impl Drop for OwnerEnableGuard {
    fn drop(&mut self) {
        // SAFETY: owner is the live modal-owner HWND; OwnerEnableGuard restores that same window on every path.
        unsafe {
            EnableWindow(self.owner, 1);
            SetForegroundWindow(self.owner);
        }
    }
}

fn prompt_input(owner: HWND, spec: PromptSpec) -> io::Result<Option<PromptResult>> {
    // SAFETY: A null module name requests the current process module and dereferences no caller memory.
    let instance = unsafe { GetModuleHandleW(null()) };
    let class_name = wide("DarkReNamerInputWindow");
    let caption = wide("입력창");
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(prompt_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        hIcon: null_mut(),
        // SAFETY: A null instance plus IDC_ARROW is the documented predefined-cursor request.
        hCursor: unsafe { LoadCursorW(null_mut(), IDC_ARROW) },
        hbrBackground: (COLOR_WINDOW + 1) as *mut c_void,
        lpszMenuName: null(),
        lpszClassName: class_name.as_ptr(),
        hIconSm: null_mut(),
    };
    // SAFETY: WNDCLASSEXW is initialized and its class name and callback remain valid during registration.
    unsafe { RegisterClassExW(&class) };
    // SAFETY: owner is the live top-level window for this modal prompt.
    let owner_dpi = unsafe { GetDpiForWindow(owner) };
    let dpi = if owner_dpi == 0 { BASE_DPI } else { owner_dpi };
    let mut state = Box::new(PromptState {
        spec,
        result: None,
        done: false,
        edit_one: null_mut(),
        edit_two: null_mut(),
        combo: null_mut(),
        font: null_mut(),
        dpi,
    });
    let state_ptr: *mut PromptState = &mut *state;
    // SAFETY: owner/instance are live and class_name/title plus stack PromptState
    // remain allocated for the complete synchronous prompt CreateWindowExW call.
    let dialog = unsafe {
        CreateWindowExW(
            WS_EX_TOOLWINDOW,
            class_name.as_ptr(),
            caption.as_ptr(),
            WS_POPUP | WS_CAPTION | WS_SYSMENU,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            scale_dip(380, dpi),
            scale_dip(210, dpi),
            owner,
            null_mut(),
            instance,
            state_ptr.cast(),
        )
    };
    if dialog.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: window is the non-null top-level HWND just created and remains owned by this UI thread.
    unsafe {
        EnableWindow(owner, 0);
        ShowWindow(dialog, SW_SHOW);
        UpdateWindow(dialog);
    }
    let _owner_guard = OwnerEnableGuard { owner };
    // SAFETY: MSG is a C-compatible structure for which all-zero is a valid pre-GetMessageW state.
    let mut message: MSG = unsafe { zeroed() };
    while !state.done {
        // SAFETY: message is writable MSG storage outliving GetMessageW; null HWND requests this thread queue.
        let status = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if status == -1 {
            let error = io::Error::last_os_error();
            // SAFETY: dialog is the live prompt HWND created above and has not
            // been destroyed on this GetMessageW error path.
            unsafe { DestroyWindow(dialog) };
            state.done = true;
            return Err(error);
        }
        if status == 0 {
            // SAFETY: dialog is the live prompt HWND; it is destroyed once before
            // the original WM_QUIT code is reposted to the same thread.
            unsafe {
                DestroyWindow(dialog);
                PostQuitMessage(message.wParam as i32);
            }
            state.done = true;
            return Ok(None);
        }
        // SAFETY: dialog is the live prompt HWND and message is initialized MSG storage from GetMessageW.
        if unsafe { IsDialogMessageW(dialog, &message) } == 0 {
            // SAFETY: message was initialized by GetMessageW and remains valid through synchronous translation and dispatch.
            unsafe {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }
    Ok(state.result.take())
}

fn prompt_input_or_report(owner: HWND, spec: PromptSpec) -> Option<PromptResult> {
    match prompt_input(owner, spec) {
        Ok(result) => result,
        Err(error) => {
            message(
                owner,
                &format!(
                    "입력창을 처리하지 못했습니다. OS {:?}",
                    error.raw_os_error()
                ),
                "DarkReNamer",
            );
            None
        }
    }
}

unsafe extern "system" fn prompt_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        let create = lparam as *const CREATESTRUCTW;
        if !create.is_null() {
            // SAFETY: WM_NCCREATE supplies a readable CREATESTRUCTW whose
            // lpCreateParams is the borrowed pointer to prompt_input's live local Box.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, (*create).lpCreateParams as isize) };
        }
    }
    // SAFETY: GWLP_USERDATA holds the borrowed pointer to prompt_input's local
    // PromptState Box, which remains live until this modal dialog is destroyed.
    let state_ptr = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut PromptState;
    match message {
        WM_CREATE if !state_ptr.is_null() => {
            // SAFETY: state_ptr borrows prompt_input's live local Box and is
            // confined to this modal callback thread until WM_NCDESTROY clears it.
            let state = unsafe { &mut *state_ptr };
            let title = { child(window, "STATIC", &state.spec.title, 1001, 0) };
            move_window_dip(title, 12, 12, 340, 22, state.dpi);
            let mut controls = vec![title];
            if !state.spec.label_one.is_empty() {
                let edit = {
                    child(
                        window,
                        "EDIT",
                        &state.spec.value_one.to_string_lossy(),
                        1004,
                        WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                    )
                };
                let label = { child(window, "STATIC", &state.spec.label_one, 1002, 0) };
                move_window_dip(edit, 12, 48, 275, 25, state.dpi);
                move_window_dip(label, 294, 48, 70, 25, state.dpi);
                state.edit_one = edit;
                controls.extend([edit, label]);
            }
            if !state.spec.label_two.is_empty() {
                let edit = {
                    child(
                        window,
                        "EDIT",
                        &state.spec.value_two.to_string_lossy(),
                        1005,
                        WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                    )
                };
                let label = { child(window, "STATIC", &state.spec.label_two, 1003, 0) };
                move_window_dip(edit, 12, 80, 275, 25, state.dpi);
                move_window_dip(label, 294, 80, 70, 25, state.dpi);
                state.edit_two = edit;
                controls.extend([edit, label]);
            }
            if !state.spec.choices.is_empty() {
                let combo = {
                    child(
                        window,
                        "COMBOBOX",
                        "",
                        1006,
                        WS_TABSTOP | CBS_DROPDOWNLIST as u32,
                    )
                };
                for choice in &state.spec.choices {
                    let choice = wide(choice);
                    // SAFETY: combo is live and each choice pointer is owned terminated UTF-16 retained through synchronous SendMessageW.
                    unsafe {
                        SendMessageW(combo, CB_ADDSTRING, 0, choice.as_ptr() as isize);
                    }
                }
                // SAFETY: combo is the live dialog ComboBox and selection zero
                // is valid because the choices collection is non-empty.
                unsafe {
                    SendMessageW(combo, CB_SETCURSEL, 0, 0);
                }
                move_window_dip(
                    combo,
                    12,
                    if state.spec.label_one.is_empty() && state.spec.label_two.is_empty() {
                        60
                    } else {
                        126
                    },
                    185,
                    160,
                    state.dpi,
                );
                state.combo = combo;
                controls.push(combo);
            }
            let ok = {
                child(
                    window,
                    "BUTTON",
                    "확인",
                    IDOK as u16,
                    WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
                )
            };
            let cancel = { child(window, "BUTTON", "취소", IDCANCEL as u16, WS_TABSTOP) };
            let separator = { child(window, "STATIC", "", 1010, SS_ETCHEDHORZ) };
            move_window_dip(ok, 205, 126, 75, 32, state.dpi);
            move_window_dip(cancel, 285, 126, 75, 32, state.dpi);
            move_window_dip(separator, 0, 116, 380, 2, state.dpi);
            controls.extend([ok, cancel, separator]);
            state.font = create_message_font(state.dpi);
            if !state.font.is_null() {
                for control in controls {
                    // SAFETY: Each prompt control HWND is live and font is the
                    // PromptState-owned HFONT retained beyond WM_SETFONT.
                    unsafe { SendMessageW(control, WM_SETFONT, state.font as usize, 1) };
                }
            }
            let first = if !state.edit_one.is_null() {
                state.edit_one
            } else {
                state.combo
            };
            if !first.is_null() {
                // SAFETY: first is a non-null child HWND created for this active dialog and remains live while focus is assigned.
                unsafe { SetFocus(first) };
            }
            0
        }
        WM_COMMAND if !state_ptr.is_null() => {
            let id = (wparam & 0xFFFF) as i32;
            let notification = ((wparam >> 16) & 0xFFFF) as u32;
            if notification == BN_CLICKED && id == IDOK {
                // SAFETY: state_ptr borrows prompt_input's live local Box and is
                // confined to this modal callback thread until WM_NCDESTROY clears it.
                let state = unsafe { &mut *state_ptr };
                state.result = Some(PromptResult {
                    value_one: { window_text(state.edit_one) },
                    value_two: { window_text(state.edit_two) },
                    choice: if state.combo.is_null() {
                        0
                    } else {
                        // SAFETY: combo is live and each choice pointer is owned terminated UTF-16 retained through synchronous SendMessageW.
                        usize::try_from(unsafe { SendMessageW(state.combo, CB_GETCURSEL, 0, 0) })
                            .unwrap_or(0)
                    },
                });
                state.done = true;
                // SAFETY: window is the live prompt HWND and IDOK has not yet
                // destroyed it on this callback path.
                unsafe { DestroyWindow(window) };
            } else if notification == BN_CLICKED && id == IDCANCEL {
                // SAFETY: state_ptr is the non-null borrowed pointer to the live
                // local PromptState Box for this modal callback.
                unsafe { (*state_ptr).done = true };
                // SAFETY: window is the live prompt HWND and IDCANCEL destroys it
                // exactly once after recording completion.
                unsafe { DestroyWindow(window) };
            }
            0
        }
        WM_CLOSE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the non-null borrowed pointer to the live local
            // PromptState Box for this modal callback.
            unsafe { (*state_ptr).done = true };
            // SAFETY: window is the live prompt HWND and WM_CLOSE destroys it once
            // after marking the local boxed PromptState complete.
            unsafe { DestroyWindow(window) };
            0
        }
        WM_NCDESTROY if !state_ptr.is_null() => {
            // SAFETY: state_ptr borrows prompt_input's local PromptState Box,
            // which remains live while WM_NCDESTROY releases its owned HFONT.
            if !unsafe { (*state_ptr).font }.is_null() {
                // SAFETY: font is the non-null HFONT stored in the still-live
                // borrowed PromptState and is deleted exactly once here.
                unsafe { DeleteObject((*state_ptr).font) };
                // SAFETY: state_ptr still borrows the live local PromptState Box;
                // clearing font prevents reuse after its single DeleteObject.
                unsafe { (*state_ptr).font = null_mut() };
            }
            // SAFETY: window is the active prompt HWND; clearing GWLP_USERDATA
            // ends the borrowed association before prompt_input drops its local Box.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
            // SAFETY: window, message, wparam, and lparam are unchanged values from the active Windows callback.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
        // SAFETY: window, message, wparam, and lparam are unchanged values from the active Windows callback.
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
}

fn window_text(window: HWND) -> LegacyText {
    if window.is_null() {
        return LegacyText::default();
    }
    // SAFETY: window is a live edit HWND and this call uses no caller output pointer.
    let length = unsafe { GetWindowTextLengthW(window) };
    if length <= 0 {
        return LegacyText::default();
    }
    let mut value = vec![0_u16; length as usize + 1];
    // SAFETY: value owns length-plus-terminator writable u16 capacity and remains allocated through GetWindowTextW.
    let copied = unsafe { GetWindowTextW(window, value.as_mut_ptr(), value.len() as i32) };
    value.truncate(copied.max(0) as usize);
    LegacyText::from_units(value)
}

fn handle_accelerator(window: HWND, message: &MSG) -> bool {
    // SAFETY: The virtual-key constant is defined and GetKeyState dereferences no caller pointer.
    let ctrl = unsafe { GetKeyState(VK_CONTROL as i32) } < 0;
    // SAFETY: The virtual-key constant is defined and GetKeyState dereferences no caller pointer.
    let shift = unsafe { GetKeyState(VK_SHIFT as i32) } < 0;
    let command = if message.message == WM_KEYDOWN {
        match message.wParam as u32 {
            value if value == u32::from(VK_DELETE) => Some(0xFFFF),
            0xBC => Some(MOVE_UP),
            0xBE => Some(MOVE_DOWN),
            value if value == u32::from(VK_ESCAPE) => Some(2),
            _ => None,
        }
    } else if message.message == WM_KEYUP && ctrl {
        match message.wParam as u32 {
            0x4F => Some(ADD_FILES),
            0x53 => Some(APPLY),
            0x5A => Some(RESET),
            0x4C => Some(CLEAR_LIST),
            0x41 => Some(SORT),
            0x43 => Some(if shift { COPY_PATHS } else { COPY_NAMES }),
            0x58 => Some(if shift { SAVE_PATHS } else { SAVE_NAMES }),
            0x56 => Some(if shift { IMPORT_PATHS } else { IMPORT_NAMES }),
            _ => None,
        }
    } else {
        None
    };
    if let Some(command) = command {
        // SAFETY: window is the active callback HWND; GWLP_USERDATA is read only to recover the pointer installed during creation.
        let state = unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut AppState;
        if (APPLY..=VERSION).contains(&command) && !state.is_null() {
            // SAFETY: state is the checked non-null AppState pointer from this HWND's GWLP_USERDATA and remains window-thread confined.
            let enabled = unsafe { (*state).command_states[usize::from(command - APPLY)] };
            if !enabled {
                return true;
            }
        }
        // SAFETY: window is the live top-level HWND; WM_COMMAND carries only the
        // validated resource command value and no pointer payload.
        unsafe { SendMessageW(window, WM_COMMAND, usize::from(command), 0) };
        if command != 2 && !state.is_null() {
            // SAFETY: state is the checked non-null Box::into_raw AppState read
            // from this HWND and remains confined to the current window thread.
            update_controls(unsafe { &mut *state });
        }
        true
    } else {
        false
    }
}

fn selected_indices(list: HWND) -> Vec<usize> {
    let mut indices = Vec::new();
    let mut index = -1_i32;
    loop {
        // SAFETY: list is the live AppState ListView HWND and LVM_GETNEXTITEM uses
        // only index/state values, with no pointer payload.
        index = unsafe {
            SendMessageW(
                list,
                LVM_GETNEXTITEM,
                index as usize,
                LVNI_SELECTED as isize,
            ) as i32
        };
        if index < 0 {
            break;
        }
        indices.push(index as usize);
    }
    indices
}

fn select_rows(list: HWND, rows: &[usize]) {
    select_rows_with_focus(list, rows, rows.first().copied());
}

fn focused_index(list: HWND) -> Option<usize> {
    // SAFETY: list is the live AppState ListView HWND and LVM_GETNEXTITEM carries
    // only the focused-state mask, with no pointer payload.
    let index = unsafe { SendMessageW(list, LVM_GETNEXTITEM, usize::MAX, LVNI_FOCUSED as isize) };
    (index >= 0).then_some(index as usize)
}

fn select_rows_with_focus(list: HWND, rows: &[usize], focused: Option<usize>) {
    for row in rows {
        let mut item = LVITEMW {
            stateMask: LVIS_SELECTED | LVIS_FOCUSED,
            state: LVIS_SELECTED
                | if Some(*row) == focused {
                    LVIS_FOCUSED
                } else {
                    0
                },
            // SAFETY: LVITEMW is C-compatible; zero initializes the unused pointer
            // fields before stateMask/state are passed synchronously for this row.
            ..unsafe { zeroed() }
        };
        // SAFETY: list is live and item is writable LVITEMW storage retained until
        // synchronous LVM_SETITEMSTATE returns.
        unsafe {
            SendMessageW(
                list,
                LVM_SETITEMSTATE,
                *row,
                (&mut item as *mut LVITEMW) as isize,
            );
        }
    }
    if let Some(row) = rows.first() {
        // SAFETY: list is live and LVM_ENSUREVISIBLE carries only the validated
        // row index, with no pointer payload.
        unsafe { SendMessageW(list, LVM_ENSUREVISIBLE, *row, 0) };
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SelectionToken {
    path: LegacyText,
    occurrence: usize,
}

fn selection_tokens(model: &LegacyList, selected: &[usize]) -> Vec<SelectionToken> {
    selected
        .iter()
        .filter_map(|index| model.items().get(*index).map(|item| (*index, item)))
        .map(|(index, item)| SelectionToken {
            path: item.source_path().clone(),
            occurrence: model.items()[..index]
                .iter()
                .filter(|previous| previous.source_path() == item.source_path())
                .count(),
        })
        .collect()
}

fn selection_token(model: &LegacyList, index: usize) -> Option<SelectionToken> {
    model.items().get(index).map(|item| SelectionToken {
        path: item.source_path().clone(),
        occurrence: model.items()[..index]
            .iter()
            .filter(|previous| previous.source_path() == item.source_path())
            .count(),
    })
}

fn rows_for_tokens(model: &LegacyList, tokens: &[SelectionToken]) -> Vec<usize> {
    tokens
        .iter()
        .filter_map(|token| {
            model
                .items()
                .iter()
                .enumerate()
                .filter(|(_index, item)| item.source_path() == &token.path)
                .nth(token.occurrence)
                .map(|(index, _item)| index)
        })
        .collect()
}

fn dispatch_command(window: HWND, state: &mut AppState, command: u16) {
    if state.read_only_locked() && !recovery_command_allowed(command) {
        message(
            window,
            "복구 잠금 상태에서는 진단 저널 내보내기, 정보 보기, 종료만 사용할 수 있습니다.",
            "DarkReNamer - 읽기 전용",
        );
        return;
    }
    if state.mutation_locked && !matches!(command, VERSION | 2) {
        message(
            window,
            "파일 변경이 끝날 때까지 정보 보기와 종료 요청만 사용할 수 있습니다.",
            "DarkReNamer - 변경 중",
        );
        return;
    }
    let selected = { selected_indices(state.list_window) };
    let before = state.model.clone();
    match command {
        APPLY => apply_changes(window, state),
        RESET => state.model.reset_proposals(),
        CLEAR_LIST => state.model = LegacyList::new(),
        0xFFFF => {
            clear_selection(state.list_window);
            state.model.remove_rows(&selected);
        }
        MOVE_UP => {
            let focused_position = { focused_index(state.list_window) }
                .and_then(|focused| selected.iter().position(|index| *index == focused));
            clear_selection(state.list_window);
            let moved = state.model.move_rows_earlier(&selected);
            state.commit_model_change(&before);
            refresh(state);
            let focused = focused_position.and_then(|position| moved.get(position).copied());
            {
                select_rows_with_focus(state.list_window, &moved, focused);
                update_controls(state);
            }
            return;
        }
        MOVE_DOWN => {
            let focused_position = { focused_index(state.list_window) }
                .and_then(|focused| selected.iter().position(|index| *index == focused));
            clear_selection(state.list_window);
            let moved = state.model.move_rows_later(&selected);
            state.commit_model_change(&before);
            refresh(state);
            let focused = focused_position.and_then(|position| moved.get(position).copied());
            {
                select_rows_with_focus(state.list_window, &moved, focused);
                update_controls(state);
            }
            return;
        }
        MANUAL_CHANGE => {
            if let Some(index) = selected.first().copied() {
                let current = state.model.items()[index].proposed_name().clone();
                if let Some(result) = {
                    prompt_input_or_report(
                        window,
                        prompt_spec(
                            format!("{} 를", current.to_string_lossy()),
                            "으로",
                            "",
                            current,
                            LegacyText::default(),
                            &[],
                        ),
                    )
                } {
                    state.model.manual_change(index, result.value_one);
                }
            }
        }
        REPLACE => {
            if let Some(result) = {
                prompt_input_or_report(
                    window,
                    prompt_spec(
                        "이름에 들어있는 문자열을 바꿉니다.",
                        "를",
                        "으로",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state
                    .model
                    .replace_complete(&result.value_one, &result.value_two);
            }
        }
        PREFIX => {
            if let Some(result) = {
                prompt_input_or_report(
                    window,
                    prompt_spec(
                        "이름의 앞에 지정한 문자열을 붙여줍니다.",
                        "붙일 문자열",
                        "",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state.model.prefix_complete(&result.value_one);
            }
        }
        SUFFIX => {
            if let Some(result) = {
                prompt_input_or_report(
                    window,
                    prompt_spec(
                        "이름의 뒤에 지정한 문자열을 붙여줍니다.",
                        "붙일 문자열",
                        "",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state.model.suffix_before_extension(&result.value_one);
            }
        }
        CLEAR_NAME => state.model.clear_name(),
        DELETE_POSITION => delete_position_command(window, state),
        DELETE_DELIMITED => delete_delimited_command(window, state),
        KEEP_DIGITS => state.model.keep_ascii_digits(),
        PAD_DIGITS => pad_digits_command(window, state),
        SEQUENCE => sequence_command(window, state),
        SORT => {
            if sort_command(window, state) {
                state.commit_model_change(&before);
                return;
            }
        }
        EXT_DELETE => state.model.delete_extension(),
        EXT_ADD => {
            if let Some(result) = {
                prompt_input_or_report(
                    window,
                    prompt_spec(
                        "확장자를 뒤에 붙입니다.",
                        "붙일 확장자",
                        "",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state.model.add_extension(&result.value_one);
            }
        }
        EXT_REPLACE => {
            if let Some(result) = {
                prompt_input_or_report(
                    window,
                    prompt_spec(
                        "확장자를 바꿔 줍니다.",
                        "바꿀 확장자",
                        "",
                        LegacyText::default(),
                        LegacyText::default(),
                        &[],
                    ),
                )
            } {
                state.model.replace_extension(&result.value_one);
            }
        }
        PARENT_PREFIX => state.model.prefix_parent_folder(),
        PARENT_SUFFIX => state.model.suffix_parent_folder(),
        UNIFY_PATH => message(
            window,
            safe_mode_unify_path_message(),
            "DarkReNamer - Safe 모드",
        ),
        ADD_FILES => add_files_dialog(window, state),
        COPY_NAMES => copy_clipboard_or_report(window, &state.model.export_names()),
        COPY_PATHS => copy_clipboard_or_report(window, &state.model.export_paths()),
        SAVE_NAMES => save_text_dialog(window, state.model.export_names(), true),
        SAVE_PATHS => save_text_dialog(window, state.model.export_paths(), false),
        IMPORT_NAMES => import_names_dialog(window, state),
        IMPORT_PATHS => import_paths_dialog(window, state),
        SHOW_FULL_PATH | SHOW_SIZE | SHOW_MODIFIED | SHOW_CREATED => {
            let index = usize::from(command - SHOW_FULL_PATH);
            state.shown_columns[index] = !state.shown_columns[index];
            update_column_visibility(state, index);
        }
        VERSION => message(window, &super::about_text(), "DarkReNamer 정보"),
        EXPORT_RECOVERY_JOURNAL => export_recovery_journal(window, state),
        2 => {
            request_window_close(window, state);
            return;
        }
        _ => {}
    }
    state.commit_model_change(&before);
    refresh(state);
}

const fn recovery_command_allowed(command: u16) -> bool {
    matches!(command, VERSION | EXPORT_RECOVERY_JOURNAL | 2)
}

fn prompt_spec(
    title: impl Into<String>,
    label_one: &str,
    label_two: &str,
    value_one: LegacyText,
    value_two: LegacyText,
    choices: &[&str],
) -> PromptSpec {
    PromptSpec {
        title: title.into(),
        label_one: label_one.to_owned(),
        label_two: label_two.to_owned(),
        value_one,
        value_two,
        choices: choices.iter().map(|choice| (*choice).to_owned()).collect(),
    }
}

fn legacy_atoi(text: &LegacyText) -> i32 {
    let value = text.to_string_lossy();
    let mut characters = value.trim_start().chars().peekable();
    let sign = match characters.peek().copied() {
        Some('-') => {
            characters.next();
            -1_i64
        }
        Some('+') => {
            characters.next();
            1_i64
        }
        _ => 1_i64,
    };
    let mut found = false;
    let mut number = 0_i64;
    while let Some(character) = characters.peek().copied() {
        if !character.is_ascii_digit() {
            break;
        }
        let digit = u32::from(character as u8 - b'0');
        found = true;
        characters.next();
        number = number.saturating_mul(10).saturating_add(i64::from(digit));
    }
    if !found {
        0
    } else {
        i32::try_from(number.saturating_mul(sign)).unwrap_or(if sign < 0 {
            i32::MIN
        } else {
            i32::MAX
        })
    }
}

fn pad_digits_command(window: HWND, state: &mut AppState) {
    let Some(result) = ({
        prompt_input_or_report(
            window,
            prompt_spec(
                "숫자부분의 자리수를 맞춰 0을 붙입니다.",
                "자리수",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &["제일 뒷번호 맞춤", "제일 앞번호 맞춤"],
            ),
        )
    }) else {
        return;
    };
    let width = legacy_atoi(&result.value_one);
    if width <= 0 {
        message(window, "자리수 입력이 잘못되었습니다.", "DarkReNamer");
        return;
    }
    let outcome = if result.choice == 0 {
        state.model.pad_last_digit_run(width as usize)
    } else {
        state.model.pad_first_digit_run(width as usize)
    };
    if outcome.is_err() {
        message(window, "자리수 입력이 잘못되었습니다.", "DarkReNamer");
    }
}

fn sequence_command(window: HWND, state: &mut AppState) {
    let Some(result) = ({
        prompt_input_or_report(
            window,
            prompt_spec(
                "붙일 숫자의 자리수와 시작값을 지정합니다.",
                "자리수",
                "시작값",
                LegacyText::default(),
                LegacyText::default(),
                &[
                    "이름뒤에 번호붙임",
                    "이름앞에 번호붙임",
                    "폴더별로 뒤 번호붙임",
                    "폴더별로 앞 번호붙임",
                ],
            ),
        )
    }) else {
        return;
    };
    let width = legacy_atoi(&result.value_one);
    if width <= 0 {
        message(window, "자리수 입력이 잘못되었습니다.", "DarkReNamer");
        return;
    }
    let mode = match result.choice {
        0 => LegacySequenceMode::Append,
        1 => LegacySequenceMode::Prepend,
        2 => LegacySequenceMode::AppendRestartPerFolder,
        _ => LegacySequenceMode::PrependRestartPerFolder,
    };
    let _ = state.model.add_sequence_by(
        width as usize,
        legacy_atoi(&result.value_two),
        mode,
        compare_windows,
    );
}

fn delete_position_command(window: HWND, state: &mut AppState) {
    let Some(result) = ({
        prompt_input_or_report(
            window,
            prompt_spec(
                "지정위치를 삭제합니다.(첫글자는 1번째)",
                "번째부터",
                "번째까지",
                LegacyText::default(),
                LegacyText::default(),
                &["앞에서부터 삭제", "제일 뒤부터 삭제"],
            ),
        )
    }) else {
        return;
    };
    let start = legacy_atoi(&result.value_one);
    let end = legacy_atoi(&result.value_two);
    if start < 0 || end < 0 {
        message(
            window,
            "음수값이나 잘못된 값이 입력되었습니다.",
            "DarkReNamer",
        );
        return;
    }
    if result.choice == 0 && end > 0 && start > end {
        message(window, "시작점이 끝점보다 뒤에 있습니다.", "DarkReNamer");
        return;
    }
    if result.choice == 1 && start != 0 {
        message(
            window,
            "맨 뒤에서부터 삭제할때는 '~까지'만 필요합니다.",
            "DarkReNamer",
        );
        return;
    }
    if result.choice == 0 {
        let _ = state.model.delete_front_range(start as usize, end as usize);
    } else {
        state.model.delete_last(end as usize);
    }
}

fn delete_delimited_command(window: HWND, state: &mut AppState) {
    let Some(result) = ({
        prompt_input_or_report(
            window,
            prompt_spec(
                "지정된 문자로 묶인 부분을 삭제합니다.",
                ":시작문자",
                ":끝문자",
                LegacyText::default(),
                LegacyText::default(),
                &[],
            ),
        )
    }) else {
        return;
    };
    if state
        .model
        .delete_first_delimited(&result.value_one, &result.value_two)
        == Err(LegacyInputError::EmptyDelimiter)
    {
        message(
            window,
            "시작/끝 문자가 정확하게 지정되지 않았습니다.",
            "DarkReNamer",
        );
    }
}

fn sort_command(window: HWND, state: &mut AppState) -> bool {
    let choices = [
        "파일 이름에 따라 오름차순",
        "파일 이름에 따라 내림차순",
        "전체경로에 따라 오름차순",
        "전체경로에 따라 내림차순",
        "실제 파일 크기에 따라 오름차순",
        "실제 파일 크기에 따라 내림차순",
        "수정한 시각에 따라 오름차순",
        "수정한 시각에 따라 내림차순",
        "만든 시각에 따라 오름차순",
        "만든 시각에 따라 내림차순",
    ];
    let Some(result) = ({
        prompt_input_or_report(
            window,
            prompt_spec(
                "정렬 기준 설정",
                "",
                "",
                LegacyText::default(),
                LegacyText::default(),
                &choices,
            ),
        )
    }) else {
        return false;
    };
    let modes = [
        LegacySortMode::NameAscending,
        LegacySortMode::NameDescending,
        LegacySortMode::FullPathAscending,
        LegacySortMode::FullPathDescending,
        LegacySortMode::SizeAscending,
        LegacySortMode::SizeDescending,
        LegacySortMode::ModifiedAscending,
        LegacySortMode::ModifiedDescending,
        LegacySortMode::CreatedAscending,
        LegacySortMode::CreatedDescending,
    ];
    if let Some(mode) = modes.get(result.choice) {
        let selected = { selected_indices(state.list_window) };
        let tokens = selection_tokens(&state.model, &selected);
        let focused = { focused_index(state.list_window) }
            .and_then(|index| selection_token(&state.model, index));
        clear_selection(state.list_window);
        state
            .model
            .sort_by_with_semantics(*mode, SortSemantics::SafeActualSize, compare_windows);
        refresh(state);
        let moved = rows_for_tokens(&state.model, &tokens);
        let focused = focused.as_ref().and_then(|token| {
            rows_for_tokens(&state.model, slice::from_ref(token))
                .first()
                .copied()
        });
        {
            select_rows_with_focus(state.list_window, &moved, focused);
            update_controls(state);
        }
        return true;
    }
    false
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
    plan: Result<RenamePlan, PlanError>,
) {
    let plan = match plan {
        Ok(plan) => plan,
        Err(error) => {
            let (message_text, rows) = plan_error_korean(&error);
            {
                clear_selection(state.list_window);
                select_rows(state.list_window, &rows);
                message(window, &message_text, "DarkReNamer - 적용 차단");
            }
            return;
        }
    };
    if plan.is_empty() {
        message(window, "변경할 항목이 없습니다.", "DarkReNamer");
        return;
    }
    let confirmation = format!(
        "{}개 항목의 실제 이름을 변경하시겠습니까?\n계획 {:016X}\n목록 버전 {}",
        plan.changed_count(),
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
                let backend = WindowsRenameBackend;
                let plan = RenamePlanner::new(&backend).plan(request);
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

fn clear_selection(list: HWND) {
    let mut item = LVITEMW {
        stateMask: LVIS_SELECTED | LVIS_FOCUSED,
        state: 0,
        // SAFETY: LVITEMW is C-compatible; zero initializes optional fields before its explicit message fields are set.
        ..unsafe { zeroed() }
    };
    // SAFETY: list is live and item remains writable LVITEMW storage through the
    // synchronous all-items LVM_SETITEMSTATE call.
    unsafe {
        SendMessageW(
            list,
            LVM_SETITEMSTATE,
            usize::MAX,
            (&mut item as *mut LVITEMW) as isize,
        );
    }
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

fn add_files_dialog(owner: HWND, state: &mut AppState) {
    let Some(paths) = modal_native_dialog(owner, || {
        rfd::FileDialog::new()
            .set_title("이름 붙일 파일 불러오기")
            .add_filter("All Files", &["*"])
            .pick_files()
    }) else {
        return;
    };
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

fn copy_clipboard_or_report(owner: HWND, text: &LegacyText) {
    if let Err(error) = copy_clipboard(owner, text) {
        message(
            owner,
            &format!("클립보드에 복사하지 못했습니다: {error}"),
            "DarkReNamer - 복사 실패",
        );
    }
}

fn save_text_dialog(owner: HWND, text: LegacyText, names: bool) {
    let title = if names {
        "파일명 저장"
    } else {
        "경로명 저장"
    };
    let Some(path) = modal_native_dialog(owner, || {
        rfd::FileDialog::new()
            .set_title(title)
            .add_filter("Text Files", &["txt"])
            .add_filter("All Files", &["*"])
            .set_file_name("*.txt")
            .save_file()
    }) else {
        return;
    };
    if let Err(error) = write_legacy_text(&path, &text) {
        message(
            owner,
            &format!("파일을 저장하지 못했습니다: {error}"),
            "DarkReNamer - 저장 실패",
        );
    }
}

fn export_recovery_journal(owner: HWND, state: &mut AppState) {
    let evidence_count = state
        .blocked_journals
        .iter()
        .filter(|blocked| matches!(blocked, StartupJournalBlock::Evidence(_)))
        .count();
    if evidence_count == 0 {
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
    let mut results = Vec::with_capacity(evidence_count);
    let mut failures = 0_usize;
    for evidence in state
        .blocked_journals
        .iter_mut()
        .filter_map(StartupJournalBlock::evidence_mut)
    {
        let name = evidence
            .path()
            .file_name()
            .and_then(|name| name.to_str())
            .map_or_else(
                || "recovery-journal.drj.evidence".to_owned(),
                |name| format!("{name}.evidence"),
            );
        let path = directory.join(name);
        match evidence.copy_exact_to_new(&path) {
            Ok(bytes) => results.push(format!("{bytes} bytes: {}", path.display())),
            Err(error) => {
                failures += 1;
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

fn import_names_dialog(owner: HWND, state: &mut AppState) {
    let Some(path) = modal_native_dialog(owner, || {
        rfd::FileDialog::new()
            .set_title("바꿀 파일 이름 불러오기")
            .add_filter("Text Files", &["txt"])
            .add_filter("All Files", &["*"])
            .pick_file()
    }) else {
        return;
    };
    match read_legacy_text(&path) {
        Ok(text) => {
            state.model.import_names(&text);
        }
        Err(error) => message(
            owner,
            &format!("가져오기 파일을 읽지 못했습니다: {error}"),
            "DarkReNamer",
        ),
    }
}

fn import_paths_dialog(owner: HWND, state: &mut AppState) {
    let Some(path) = modal_native_dialog(owner, || {
        rfd::FileDialog::new()
            .set_title("파일에서 경로목록 읽어 추가하기")
            .add_filter("Text Files", &["txt"])
            .add_filter("All Files", &["*"])
            .pick_file()
    }) else {
        return;
    };
    let text = match read_legacy_text(&path) {
        Ok(text) => text,
        Err(error) => {
            message(
                owner,
                &format!("경로 목록을 읽지 못했습니다: {error}"),
                "DarkReNamer",
            );
            return;
        }
    };
    set_status(state.status, "처리중...");
    let remaining = MAX_ADMITTED_SOURCES.saturating_sub(state.model.len());
    let (lines, truncated) = bounded_import_lines(&text, remaining.saturating_add(1));
    if truncated || lines.len() > remaining {
        message(
            owner,
            "경로 목록이 남은 10,000개 한도를 초과해 제한된 수만 처리합니다.",
            "DarkReNamer - 가져오기 한도",
        );
    }
    let paths = lines
        .into_iter()
        .map(|line| PathBuf::from(std::ffi::OsString::from_wide(line.units())))
        .collect();
    admit_paths(owner, state, paths);
}

fn set_status(status: HWND, text: &str) {
    let text = wide(text);
    // SAFETY: window is the non-null top-level HWND just created and remains owned by this UI thread.
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(status, text.as_ptr());
        UpdateWindow(status);
    }
}

fn modal_native_dialog<T>(owner: HWND, dialog: impl FnOnce() -> T) -> T {
    // SAFETY: owner is the live modal-owner HWND; OwnerEnableGuard restores that same window on every path.
    unsafe { EnableWindow(owner, 0) };
    let result = dialog();
    // SAFETY: owner is the live modal-owner HWND; OwnerEnableGuard restores that same window on every path.
    unsafe {
        EnableWindow(owner, 1);
        SetForegroundWindow(owner);
    }
    result
}

fn update_controls(state: &mut AppState) {
    let selected_count = { selected_indices(state.list_window) }.len();
    for id in APPLY..=VERSION {
        state.command_states[usize::from(id - APPLY)] =
            if state.read_only_locked() || state.mutation_locked {
                id == VERSION
            } else {
                command_enabled(id, state.model.len(), selected_count)
                    && !(id == APPLY && state.apply_locked())
            };
    }
    apply_command_states(state);
}

fn apply_command_states(state: &AppState) {
    for tool in LEFT_TOOLS {
        set_toolbar_button_enabled(
            state.left_toolbar,
            tool.id,
            state.command_states[usize::from(tool.id - APPLY)],
        );
    }
    for tool in RIGHT_TOOLS {
        set_toolbar_button_enabled(
            state.right_toolbar,
            tool.id,
            state.command_states[usize::from(tool.id - APPLY)],
        );
    }
    for id in APPLY..=VERSION {
        let enabled = state.command_states[usize::from(id - APPLY)];
        // SAFETY: AppState's menu and parent HWND are live and command IDs are validated resource values.
        unsafe {
            EnableMenuItem(
                state.menu,
                u32::from(id),
                MF_BYCOMMAND | if enabled { MF_ENABLED } else { MF_GRAYED },
            );
        }
    }
    let can_export_evidence = state
        .blocked_journals
        .iter()
        .any(|blocked| matches!(blocked, StartupJournalBlock::Evidence(_)));
    // SAFETY: state.menu is the live application menu and the diagnostic
    // command identifier is owned by this process.
    unsafe {
        EnableMenuItem(
            state.menu,
            u32::from(EXPORT_RECOVERY_JOURNAL),
            MF_BYCOMMAND
                | if can_export_evidence {
                    MF_ENABLED
                } else {
                    MF_GRAYED
                },
        );
    }
    for (index, id) in [SHOW_FULL_PATH, SHOW_SIZE, SHOW_MODIFIED, SHOW_CREATED]
        .into_iter()
        .enumerate()
    {
        // SAFETY: AppState's menu and parent HWND are live and command IDs are validated resource values.
        unsafe {
            CheckMenuItem(
                state.menu,
                u32::from(id),
                MF_BYCOMMAND
                    | if state.shown_columns[index] {
                        MF_CHECKED
                    } else {
                        MF_UNCHECKED
                    },
            );
        }
    }
    if !state.menu.is_null() {
        // SAFETY: AppState's menu and parent HWND are live and command IDs are validated resource values.
        unsafe { DrawMenuBar(GetParent(state.list_window)) };
    }
}

fn set_toolbar_button_enabled(toolbar: HWND, command: CommandId, enabled: bool) {
    if !toolbar.is_null() {
        // SAFETY: toolbar is the live left/right AppState toolbar HWND and command
        // is a validated resource ID passed by value to TB_ENABLEBUTTON.
        unsafe {
            SendMessageW(
                toolbar,
                TB_ENABLEBUTTON,
                usize::from(command),
                enabled as isize,
            )
        };
    }
}

fn create_menu() -> HMENU {
    // SAFETY: CreateMenu takes no pointers; the returned HMENU stays owned until attached to the top-level window.
    let menu = unsafe { CreateMenu() };
    // SAFETY: CreatePopupMenu takes no pointers; the returned HMENU stays owned until appended to its parent.
    let file = unsafe { CreatePopupMenu() };
    // SAFETY: CreatePopupMenu takes no pointers; the returned HMENU stays owned until appended to its parent.
    unsafe {
        menu_item(file, ADD_FILES, "경로목록에 파일 추가하기\tCtrl+O");
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, APPLY, "실제 파일 변경\tCtrl+S");
        menu_item(file, RESET, "원래 이름으로\tCtrl+Z");
        menu_item(file, CLEAR_LIST, "경로목록 지우기\tCtrl+L");
        menu_item(file, SORT, "경로목록 정렬\tCtrl+A");
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, COPY_NAMES, "클립보드로 바꿀이름 복사\tCtrl+C");
        menu_item(file, SAVE_NAMES, "문서파일로 바꿀이름 저장\tCtrl+X");
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, COPY_PATHS, "클립보드로 경로목록 복사\tCtrl+Shift+C");
        menu_item(file, SAVE_PATHS, "문서파일로 경로목록 저장\tCtrl+Shift+X");
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, IMPORT_NAMES, "바꿀이름 불러오기\tCtrl+V");
        menu_item(file, IMPORT_PATHS, "경로목록 불러오기\tCtrl+Shift+V");
        AppendMenuW(file, MF_SEPARATOR, 0, null());
        menu_item(file, 2, "종료(&X)\tEsc");
        append_popup(menu, file, "파일(&F)");
        let edit = CreatePopupMenu();
        menu_item(edit, MOVE_UP, "위로 올림\t<");
        menu_item(edit, MOVE_DOWN, "아래로 내림\t>");
        AppendMenuW(edit, MF_SEPARATOR, 0, null());
        menu_item(edit, MANUAL_CHANGE, "직접 바꾸기");
        append_popup(menu, edit, "편집(&E)");
        let view = CreatePopupMenu();
        menu_item(view, SHOW_FULL_PATH, "전체 경로 표시");
        menu_item(view, SHOW_SIZE, "파일 크기 표시");
        menu_item(view, SHOW_MODIFIED, "변경 시각 표시");
        menu_item(view, SHOW_CREATED, "생성 시각 표시");
        append_popup(menu, view, "보기(&V)");
        let tools = CreatePopupMenu();
        menu_item(tools, REPLACE, "문자열 바꾸기");
        menu_item(tools, PREFIX, "앞이름 붙이기");
        menu_item(tools, SUFFIX, "뒷이름 붙이기");
        AppendMenuW(tools, MF_SEPARATOR, 0, null());
        menu_item(tools, CLEAR_NAME, "이름 지우기");
        menu_item(tools, DELETE_POSITION, "위치 지우기");
        menu_item(tools, DELETE_DELIMITED, "묶인곳 지우기");
        AppendMenuW(tools, MF_SEPARATOR, 0, null());
        menu_item(tools, KEEP_DIGITS, "숫자만 남기기");
        menu_item(tools, PAD_DIGITS, "자리수 맞추기");
        menu_item(tools, SEQUENCE, "번호 붙이기");
        AppendMenuW(tools, MF_SEPARATOR, 0, null());
        menu_item(tools, EXT_DELETE, "확장자 삭제");
        menu_item(tools, EXT_ADD, "확장자 추가");
        menu_item(tools, EXT_REPLACE, "확장자 변경");
        AppendMenuW(tools, MF_SEPARATOR, 0, null());
        menu_item(tools, PARENT_PREFIX, "경로명 앞에");
        menu_item(tools, PARENT_SUFFIX, "경로명 뒤에");
        menu_item(tools, UNIFY_PATH, "경로 통일하기 (미지원)");
        append_popup(menu, tools, "기능(&T)");
        let recovery = CreatePopupMenu();
        menu_item(
            recovery,
            EXPORT_RECOVERY_JOURNAL,
            "보존된 모든 저널 원본 내보내기...",
        );
        append_popup(menu, recovery, "복구(&R)");
        menu_item(menu, VERSION, "버전(H)");
    }
    menu
}

fn menu_item(menu: HMENU, id: u16, label: &str) {
    let label = wide(label);
    // SAFETY: menu/popup are live HMENU values and label is owned terminated UTF-16 retained through AppendMenuW.
    unsafe { AppendMenuW(menu, MF_STRING, usize::from(id), label.as_ptr()) };
}

fn append_popup(menu: HMENU, popup: HMENU, label: &str) {
    let label = wide(label);
    // SAFETY: menu/popup are live HMENU values and label is owned terminated UTF-16 retained through AppendMenuW.
    unsafe { AppendMenuW(menu, MF_POPUP, popup as usize, label.as_ptr()) };
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
            StartupJournalBlock::Evidence(_)
        ));
        let status = runtime.status.as_deref().unwrap_or_default();
        assert!(status.contains("원본 핸들을 보존"));
        assert!(status.contains(&active.display().to_string()));
        assert!(fs::read(&active).is_err());
        drop(runtime);
        assert_eq!(fs::read(active)?, corrupt);
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
                .all(|blocked| matches!(blocked, StartupJournalBlock::Evidence(_)))
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
