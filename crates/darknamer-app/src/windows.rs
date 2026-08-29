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
mod drag_drop;
mod list_view;
mod menu;
mod recovery_ui;
#[path = "../resource_ids.rs"]
mod resource_ids;
mod safe_runtime;
mod text_io;
mod worker;

use clipboard::copy_clipboard;
use command_dispatch::*;
use dialog::*;
use drag_drop::*;
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
use worker::*;

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
