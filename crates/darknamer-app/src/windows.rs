use std::collections::HashMap;
use std::env;
use std::ffi::c_void;
use std::fs;
use std::io;
use std::mem::{size_of, zeroed};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::slice;

use crate::admission::{
    AdmissionAdapter, AdmissionMode, MAX_ADMITTED_SOURCES, MAX_IMPORT_BYTES,
    WindowsAdmissionAdapter, bounded_import_lines, bounded_selection, collect_admission,
    read_bounded_import,
};
use crate::icon_cache::{IconCacheKey, icon_cache_key};
use crate::rename::{
    ExecutionOutcome, FileJournal, JournalCleanupDecision, JournalRoot, ModelRevision,
    RecoveryOutcome, RenameExecutor, RenamePlanner, RenameRecovery, WindowsRenameBackend,
    apply_execution_report, build_plan_request, cleanup_decision, execute_error_korean,
    execution_outcome_korean, next_model_revision, plan_error_korean, process_is_elevated,
    safe_mode_unify_path_message,
};
use darknamer_core::{
    LegacyInputError, LegacyList, LegacyListItem, LegacySequenceMode, LegacySortMode, LegacyText,
};

#[path = "../resource_ids.rs"]
mod resource_ids;
use windows_sys::Win32::Foundation::{
    FILETIME, GlobalFree, HANDLE, HWND, LPARAM, LRESULT, RECT, SYSTEMTIME, WPARAM,
};
use windows_sys::Win32::Globalization::{
    CP_ACP, CSTR_GREATER_THAN, CSTR_LESS_THAN, CompareStringW, LOCALE_USER_DEFAULT,
    MultiByteToWideChar, NORM_IGNORECASE,
};
use windows_sys::Win32::Graphics::Gdi::{
    CLIP_DEFAULT_PRECIS, COLOR_WINDOW, CreateFontW, DEFAULT_CHARSET, DEFAULT_PITCH,
    DEFAULT_QUALITY, DeleteObject, FF_DONTCARE, FW_NORMAL, HFONT, OUT_DEFAULT_PRECIS,
    RDW_ALLCHILDREN, RDW_ERASE, RDW_INVALIDATE, RedrawWindow, UpdateWindow,
};
#[cfg(test)]
use windows_sys::Win32::Storage::FileSystem::MoveFileW;
use windows_sys::Win32::Storage::FileSystem::{FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL};
use windows_sys::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize};
use windows_sys::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};
use windows_sys::Win32::System::Ole::CF_UNICODETEXT;
use windows_sys::Win32::System::SystemServices::{SS_CENTERIMAGE, SS_ETCHEDHORZ, SS_SUNKEN};
use windows_sys::Win32::System::Time::FileTimeToSystemTime;
use windows_sys::Win32::UI::Controls::{
    CCS_NOPARENTALIGN, CCS_NORESIZE, CCS_VERT, ICC_BAR_CLASSES, ICC_LISTVIEW_CLASSES,
    INITCOMMONCONTROLSEX, InitCommonControlsEx, LVCF_FMT, LVCF_TEXT, LVCF_WIDTH, LVCFMT_LEFT,
    LVCFMT_RIGHT, LVCOLUMNW, LVIF_IMAGE, LVIF_TEXT, LVIS_FOCUSED, LVIS_SELECTED, LVITEMW,
    LVM_DELETEALLITEMS, LVM_ENSUREVISIBLE, LVM_GETNEXTITEM, LVM_INSERTCOLUMNW, LVM_INSERTITEMW,
    LVM_SETCOLUMNWIDTH, LVM_SETEXTENDEDLISTVIEWSTYLE, LVM_SETIMAGELIST, LVM_SETITEMSTATE,
    LVM_SETITEMTEXTW, LVN_ITEMCHANGED, LVNI_FOCUSED, LVNI_SELECTED, LVS_EX_DOUBLEBUFFER,
    LVS_EX_FULLROWSELECT, LVS_NOSORTHEADER, LVS_REPORT, LVS_SHAREIMAGELISTS, LVS_SHOWSELALWAYS,
    LVSIL_SMALL, NM_DBLCLK, NMHDR, NMLISTVIEW, TB_ADDBITMAP, TB_ADDBUTTONS, TB_BUTTONSTRUCTSIZE,
    TB_ENABLEBUTTON, TB_SETBITMAPSIZE, TB_SETBUTTONSIZE, TBADDBITMAP, TBBUTTON, TBSTATE_ENABLED,
    TBSTYLE_BUTTON, TBSTYLE_FLAT, TBSTYLE_SEP, TBSTYLE_TOOLTIPS, TBSTYLE_WRAPABLE,
    TOOLBARCLASSNAMEW,
};
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
    IDOK, IsDialogMessageW, LoadCursorW, LoadIconW, MB_OKCANCEL, MB_YESNO, MF_BYCOMMAND,
    MF_CHECKED, MF_ENABLED, MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, MF_UNCHECKED, MSG,
    MessageBoxW, MoveWindow, PostQuitMessage, RegisterClassExW, SW_SHOW, SendMessageW,
    SetForegroundWindow, SetMenu, SetWindowLongPtrW, ShowWindow, TranslateMessage, WM_CLOSE,
    WM_COMMAND, WM_CREATE, WM_DESTROY, WM_DROPFILES, WM_KEYDOWN, WM_KEYUP, WM_NCCREATE,
    WM_NCDESTROY, WM_NOTIFY, WM_SETFONT, WM_SETREDRAW, WM_SIZE, WNDCLASSEXW, WS_BORDER, WS_CAPTION,
    WS_CHILD, WS_CLIPCHILDREN, WS_EX_ACCEPTFILES, WS_EX_APPWINDOW, WS_EX_TOOLWINDOW,
    WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_OVERLAPPEDWINDOW, WS_POPUP, WS_SYSMENU, WS_TABSTOP,
    WS_VISIBLE,
};

use crate::*;

const LIST_ID: usize = 1000;
const LEFT_TOOLBAR_ID: usize = 1001;
const RIGHT_TOOLBAR_ID: usize = 1002;
const STATUS_ID: usize = 1007;
const ACTIVE_JOURNAL_LEAF: &str = "active.drj";

struct AppState {
    list_window: HWND,
    status: HWND,
    menu: HMENU,
    font: HFONT,
    left_toolbar: HWND,
    right_toolbar: HWND,
    model: LegacyList,
    shown_columns: [bool; 4],
    directory_mode: Option<DirectoryMode>,
    command_states: [bool; 34],
    model_revision: u64,
    mutation_locked: bool,
    recovery_locked: bool,
    journal_root: JournalRoot,
    active_journal: Option<FileJournal>,
    startup_status: Option<String>,
    icon_cache: HashMap<IconCacheKey, i32>,
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
            left_toolbar: null_mut(),
            right_toolbar: null_mut(),
            model: LegacyList::new(),
            shown_columns: [false; 4],
            directory_mode: None,
            command_states: [false; 34],
            model_revision: 0,
            mutation_locked: false,
            recovery_locked: runtime.recovery_locked,
            journal_root: runtime.root,
            active_journal: runtime.active_journal,
            startup_status: runtime.status,
            icon_cache: HashMap::new(),
        }
    }

    fn revision(&self) -> ModelRevision {
        ModelRevision::new(self.model_revision)
    }

    fn commit_model_change(&mut self, before: &LegacyList) {
        self.model_revision = next_model_revision(self.model_revision, &self.model != before);
    }

    const fn apply_locked(&self) -> bool {
        self.mutation_locked || self.recovery_locked || self.active_journal.is_some()
    }
}

struct SafeRuntime {
    root: JournalRoot,
    active_journal: Option<FileJournal>,
    recovery_locked: bool,
    status: Option<String>,
}

struct JournalCleanup {
    retained: Option<FileJournal>,
    error: Option<io::Error>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DirectoryMode {
    Recurse,
    Direct,
}

struct ComGuard;

impl Drop for ComGuard {
    fn drop(&mut self) {
        // SAFETY: ComGuard exists only after successful CoInitializeEx and drops on the same apartment thread.
        unsafe { CoUninitialize() };
    }
}

fn initialize_safe_runtime() -> io::Result<SafeRuntime> {
    let local_app_data = env::var_os("LOCALAPPDATA")
        .ok_or_else(|| io::Error::other("LOCALAPPDATA 환경 변수를 찾을 수 없습니다"))?;
    let local_app_data = PathBuf::from(local_app_data);
    if !local_app_data.is_absolute() {
        return Err(io::Error::other("저널 경로가 절대 경로가 아닙니다"));
    }
    drop(JournalRoot::open(&local_app_data).map_err(io::Error::other)?);
    let app_root = local_app_data.join("DarkReNamer");
    if !app_root.exists() {
        fs::create_dir(&app_root)?;
    }
    drop(JournalRoot::open(&app_root).map_err(io::Error::other)?);
    let root_path = app_root.join("journal");
    if !root_path.exists() {
        fs::create_dir(&root_path)?;
    }
    let root = JournalRoot::open(&root_path).map_err(io::Error::other)?;
    let active_path = root_path.join(ACTIVE_JOURNAL_LEAF);
    if !active_path.exists() {
        return Ok(SafeRuntime {
            root,
            active_journal: None,
            recovery_locked: false,
            status: None,
        });
    }

    let mut journal =
        FileJournal::open_existing(&root, ACTIVE_JOURNAL_LEAF).map_err(io::Error::other)?;
    let mut backend = WindowsRenameBackend;
    let outcome = RenameRecovery::new(&mut backend, &mut journal).rollback();
    match outcome {
        RecoveryOutcome::Recovered { .. } | RecoveryOutcome::NotRequired => {
            let cleanup = cleanup_file_journal(journal);
            let cleanup_failed = cleanup.error.is_some();
            let mut status = if matches!(outcome, RecoveryOutcome::Recovered { .. }) {
                "이전 변경을 안전하게 복구했습니다.".to_owned()
            } else {
                "저널 상태를 확인했습니다.".to_owned()
            };
            if let Some(error) = cleanup.error {
                status.push_str(&format!(" 저널 삭제 실패: {error}"));
            }
            Ok(SafeRuntime {
                root,
                recovery_locked: cleanup_failed || cleanup.retained.is_some(),
                active_journal: cleanup.retained,
                status: Some(status),
            })
        }
        RecoveryOutcome::Blocked { reason, .. } => Ok(SafeRuntime {
            root,
            active_journal: Some(journal),
            recovery_locked: true,
            status: Some(format!("복구가 차단되었습니다: {reason:?}")),
        }),
        RecoveryOutcome::RecoveryRequired { reason, .. } => Ok(SafeRuntime {
            root,
            active_journal: Some(journal),
            recovery_locked: true,
            status: Some(format!("복구가 필요합니다: {reason:?}")),
        }),
    }
}

fn cleanup_file_journal(mut journal: FileJournal) -> JournalCleanup {
    if cleanup_decision(journal.records()) == JournalCleanupDecision::Retain {
        return JournalCleanup {
            retained: Some(journal),
            error: None,
        };
    }
    match journal.mark_delete_if_safe() {
        Ok(()) => {
            drop(journal);
            JournalCleanup {
                retained: None,
                error: None,
            }
        }
        Err(error) => JournalCleanup {
            retained: Some(journal),
            error: Some(io::Error::other(error)),
        },
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
    // SAFETY: MSG is a C-compatible structure for which all-zero is a valid pre-GetMessageW state.
    let mut message: MSG = unsafe { zeroed() };
    loop {
        // SAFETY: message is writable MSG storage outliving GetMessageW; null HWND requests this thread queue.
        let result = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if result == -1 {
            let error = io::Error::last_os_error();
            // SAFETY: window is the live top-level HWND created above and this
            // GetMessageW error path destroys it exactly once before returning.
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
        WM_COMMAND if !state_ptr.is_null() => {
            let command = (wparam & 0xFFFF) as u16;
            // SAFETY: state_ptr is the non-null, window-thread-confined AppState
            // installed in GWLP_USERDATA and is uniquely borrowed for dispatch.
            dispatch_command(window, unsafe { &mut *state_ptr }, command);
            0
        }
        WM_DROPFILES if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
            let before = unsafe { (*state_ptr).model.clone() };
            // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
            unsafe {
                admit_drop(window, &mut *state_ptr, wparam as HDROP);
                (*state_ptr).commit_model_change(&before);
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
                // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
                if !unsafe { (*state_ptr).font }.is_null() {
                    // SAFETY: state_ptr is the non-null Box::into_raw value in GWLP_USERDATA, confined to this window thread until WM_NCDESTROY.
                    unsafe { DeleteObject((*state_ptr).font) };
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

fn create_children(window: HWND, state: &mut AppState) -> io::Result<()> {
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
                cx: column.default_width,
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
        )?
    };
    state.right_toolbar = {
        create_toolbar(
            window,
            instance,
            RIGHT_TOOLBAR_ID,
            resource_ids::RIGHT_TOOLBAR_BITMAP,
            &RIGHT_TOOLBAR_ITEMS,
        )?
    };
    let face = wide("MS Sans Serif");
    // SAFETY: face is owned terminated UTF-16 retained through CreateFontW; the returned HFONT is kept in AppState and deleted once.
    state.font = unsafe {
        CreateFontW(
            -13,
            0,
            0,
            0,
            FW_NORMAL as i32,
            0,
            0,
            0,
            u32::from(DEFAULT_CHARSET),
            u32::from(OUT_DEFAULT_PRECIS),
            u32::from(CLIP_DEFAULT_PRECIS),
            u32::from(DEFAULT_QUALITY),
            u32::from(DEFAULT_PITCH | FF_DONTCARE),
            face.as_ptr(),
        )
    };
    if !state.font.is_null() {
        for control in [&state.list_window, &state.status] {
            // SAFETY: Each control HWND is live and font is the AppState-owned HFONT retained beyond WM_SETFONT.
            unsafe { SendMessageW(*control, WM_SETFONT, state.font as usize, 1) };
        }
    }
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
) -> io::Result<HWND> {
    let styles = WS_CHILD
        | WS_VISIBLE
        | TBSTYLE_FLAT
        | TBSTYLE_TOOLTIPS
        | TBSTYLE_WRAPABLE
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
        SendMessageW(
            toolbar,
            TB_SETBITMAPSIZE,
            0,
            packed_dimensions(TOOLBAR_BITMAP_WIDTH, TOOLBAR_BITMAP_HEIGHT),
        );
        SendMessageW(
            toolbar,
            TB_SETBUTTONSIZE,
            0,
            packed_dimensions(TOOLBAR_WIDTH, TOOLBAR_BUTTON_HEIGHT),
        );
    }
    let bitmap_count = items
        .iter()
        .filter(|item| matches!(item, ToolbarItem::Command(_)))
        .count();
    let bitmap = TBADDBITMAP {
        hInst: instance,
        nID: usize::from(resource_id),
    };
    // SAFETY: toolbar is live and resource_id identifies a linked bitmap owned by
    // instance; the TBADDBITMAP structure remains allocated through the message.
    let first_bitmap = unsafe {
        SendMessageW(
            toolbar,
            TB_ADDBITMAP,
            bitmap_count,
            (&raw const bitmap) as isize,
        )
    };
    let first_bitmap = i32::try_from(first_bitmap)
        .ok()
        .filter(|index| *index >= 0)
        .ok_or_else(|| io::Error::other("could not load native toolbar bitmap resource"))?;
    let mut image_index = 0_i32;
    let buttons = items
        .iter()
        .map(|item| match *item {
            ToolbarItem::Command(command) => {
                let button = TBBUTTON {
                    iBitmap: first_bitmap + image_index,
                    idCommand: i32::from(command),
                    fsState: TBSTATE_ENABLED as u8,
                    fsStyle: TBSTYLE_BUTTON as u8,
                    ..TBBUTTON::default()
                };
                image_index += 1;
                button
            }
            ToolbarItem::Separator => TBBUTTON {
                iBitmap: TOOLBAR_SEPARATOR_SIZE,
                fsStyle: TBSTYLE_SEP as u8,
                ..TBBUTTON::default()
            },
        })
        .collect::<Vec<_>>();
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

const fn packed_dimensions(width: i32, height: i32) -> isize {
    ((width as u32 & 0xFFFF) | ((height as u32 & 0xFFFF) << 16)) as isize
}

fn arrange(window: HWND, state: &AppState) {
    // SAFETY: RECT is a C-compatible integer structure for which all-zero is a valid writable initial state.
    let mut rect: RECT = unsafe { zeroed() };
    // SAFETY: window is live and rect is writable RECT storage retained until GetClientRect returns.
    unsafe { GetClientRect(window, &mut rect) };
    let width = rect.right.max(TOOLBAR_WIDTH * 2 + 1);
    let height = rect.bottom.max(STATUS_HEIGHT + 1);
    // SAFETY: window plus AppState's list/status/toolbars are live child HWNDs on
    // this thread; each MoveWindow call retains no borrowed storage.
    unsafe {
        MoveWindow(
            state.left_toolbar,
            0,
            0,
            TOOLBAR_WIDTH,
            height - STATUS_HEIGHT,
            1,
        );
        MoveWindow(
            state.right_toolbar,
            width - TOOLBAR_WIDTH,
            0,
            TOOLBAR_WIDTH,
            height - STATUS_HEIGHT,
            1,
        );
        MoveWindow(
            state.list_window,
            TOOLBAR_WIDTH,
            0,
            width - TOOLBAR_WIDTH * 2,
            height - STATUS_HEIGHT,
            1,
        );
        MoveWindow(
            state.status,
            0,
            height - STATUS_HEIGHT,
            width,
            STATUS_HEIGHT,
            1,
        );
    }
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
    let mut state = Box::new(PromptState {
        spec,
        result: None,
        done: false,
        edit_one: null_mut(),
        edit_two: null_mut(),
        combo: null_mut(),
        font: null_mut(),
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
            380,
            210,
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
            // SAFETY: title is the live STATIC child just created for window;
            // MoveWindow retains no borrowed storage.
            unsafe { MoveWindow(title, 12, 12, 340, 22, 1) };
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
                // SAFETY: edit and label are live children just created for this
                // prompt window; both MoveWindow calls retain no storage.
                unsafe {
                    MoveWindow(edit, 12, 48, 275, 25, 1);
                    MoveWindow(label, 294, 48, 70, 25, 1);
                }
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
                // SAFETY: edit and label are live children just created for this
                // prompt window; both MoveWindow calls retain no storage.
                unsafe {
                    MoveWindow(edit, 12, 80, 275, 25, 1);
                    MoveWindow(label, 294, 80, 70, 25, 1);
                }
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
                // SAFETY: combo is live and each choice pointer is owned terminated UTF-16 retained through synchronous SendMessageW.
                unsafe {
                    SendMessageW(combo, CB_SETCURSEL, 0, 0);
                    MoveWindow(
                        combo,
                        12,
                        if state.spec.label_one.is_empty() && state.spec.label_two.is_empty() {
                            60
                        } else {
                            126
                        },
                        185,
                        160,
                        1,
                    );
                }
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
            // SAFETY: ok/cancel/separator are live children created for this
            // prompt window; these MoveWindow calls retain no storage.
            unsafe {
                MoveWindow(ok, 205, 126, 75, 32, 1);
                MoveWindow(cancel, 285, 126, 75, 32, 1);
                MoveWindow(separator, 0, 116, 380, 2, 1);
            }
            controls.extend([ok, cancel, separator]);
            let face = wide("MS Sans Serif");
            // SAFETY: face is owned terminated UTF-16 retained through CreateFontW;
            // the returned HFONT is kept in the local PromptState and deleted once.
            state.font = unsafe {
                CreateFontW(
                    -13,
                    0,
                    0,
                    0,
                    FW_NORMAL as i32,
                    0,
                    0,
                    0,
                    u32::from(DEFAULT_CHARSET),
                    u32::from(OUT_DEFAULT_PRECIS),
                    u32::from(CLIP_DEFAULT_PRECIS),
                    u32::from(DEFAULT_QUALITY),
                    u32::from(DEFAULT_PITCH | FF_DONTCARE),
                    face.as_ptr(),
                )
            };
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
        COPY_NAMES => copy_clipboard(window, &state.model.export_names()),
        COPY_PATHS => copy_clipboard(window, &state.model.export_paths()),
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
        // SAFETY: window is the live top-level HWND owned by this UI thread and
        // command 2 destroys it exactly once on this dispatch path.
        2 => unsafe {
            DestroyWindow(window);
            return;
        },
        _ => {}
    }
    state.commit_model_change(&before);
    refresh(state);
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
        "파일 크기에 따라 오름차순",
        "파일 크기에 따라 내림차순",
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
        state.model.sort_by(*mode, compare_windows);
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
    let mut backend = WindowsRenameBackend;
    let plan = match RenamePlanner::new(&backend).plan(request) {
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
    // SAFETY: window is the live application HWND and prompt/caption are owned
    // NUL-terminated UTF-16 buffers retained through the modal MessageBoxW call.
    if unsafe { MessageBoxW(window, prompt.as_ptr(), caption.as_ptr(), MB_OKCANCEL) } != IDOK {
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
    let mut journal = match FileJournal::create_new(&state.journal_root, ACTIVE_JOURNAL_LEAF) {
        Ok(journal) => journal,
        Err(error) => {
            state.recovery_locked = true;
            message(
                window,
                &format!(
                    "활성 저널을 만들지 못했습니다. {:?}, OS {:?}",
                    error.kind, error.os_code
                ),
                "DarkReNamer - 적용 잠김",
            );
            return;
        }
    };
    state.mutation_locked = true;
    update_controls(state);
    let execution = RenameExecutor::new(&mut backend, &mut journal).execute(confirmed);
    state.mutation_locked = false;

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
    state.directory_mode = None;
    admit_paths(owner, state, paths);
    refresh(state);
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
    state.directory_mode = None;
    admit_paths(owner, state, paths);
}

fn admit_paths(owner: HWND, state: &mut AppState, paths: Vec<PathBuf>) {
    let capacity = MAX_ADMITTED_SOURCES.saturating_sub(state.model.len());
    let adapter = WindowsAdmissionAdapter::new();
    if state.directory_mode.is_none()
        && let Some(directory) = paths.iter().take(capacity).find(|path| {
            path.is_absolute()
                && adapter.validate_path(path).is_ok()
                && adapter
                    .metadata(path)
                    .is_ok_and(|metadata| metadata.is_directory && !metadata.is_reparse_point)
        })
    {
        let text = wide("경로를 직접 추가하려면 YES, 경로 내 파일을 추가하려면 NO를 선택하세요.");
        let caption = path_wide(directory);
        // SAFETY: owner is the live application HWND and text/caption are owned
        // NUL-terminated UTF-16 buffers retained through the modal MessageBoxW call.
        let answer = unsafe { MessageBoxW(owner, text.as_ptr(), caption.as_ptr(), MB_YESNO) };
        state.directory_mode = Some(
            if answer == windows_sys::Win32::UI::WindowsAndMessaging::IDYES {
                DirectoryMode::Direct
            } else {
                DirectoryMode::Recurse
            },
        );
    }
    let mode = match state.directory_mode.unwrap_or(DirectoryMode::Direct) {
        DirectoryMode::Direct => AdmissionMode::Direct,
        DirectoryMode::Recurse => AdmissionMode::Recurse,
    };
    let mut report = collect_admission(&adapter, paths, mode, capacity, |left, right| {
        compare_windows(&legacy_path(left), &legacy_path(right))
    });
    let items = std::mem::take(&mut report.items);
    let appended = state.model.append_batch_by(items, compare_windows);
    let summary = report.summary_korean(appended);
    set_status(state.status, &summary);
    if !report.issues.is_empty() {
        message(owner, &summary, "DarkReNamer - 일부 경로 제외");
    }
}

fn legacy_path(path: &Path) -> LegacyText {
    LegacyText::from_units(path.as_os_str().encode_wide().collect::<Vec<_>>())
}

fn compare_windows(left: &LegacyText, right: &LegacyText) -> std::cmp::Ordering {
    let left_len = i32::try_from(left.len()).unwrap_or(i32::MAX);
    let right_len = i32::try_from(right.len()).unwrap_or(i32::MAX);
    // SAFETY: Both UTF-16 slices remain allocated and checked i32 lengths describe their exact readable units.
    let result = unsafe {
        CompareStringW(
            LOCALE_USER_DEFAULT,
            NORM_IGNORECASE,
            left.units().as_ptr(),
            left_len,
            right.units().as_ptr(),
            right_len,
        )
    };
    if result == CSTR_LESS_THAN {
        std::cmp::Ordering::Less
    } else if result == CSTR_GREATER_THAN {
        std::cmp::Ordering::Greater
    } else {
        std::cmp::Ordering::Equal
    }
}

fn path_wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain([0]).collect()
}

fn copy_clipboard(owner: HWND, text: &LegacyText) {
    let mut units = text.units().to_vec();
    units.push(0);
    // SAFETY: owner is the live top-level HWND associated with this synchronous clipboard session.
    if unsafe { OpenClipboard(owner) } == 0 {
        return;
    }
    // SAFETY: This thread successfully opened the clipboard immediately before emptying it.
    unsafe { EmptyClipboard() };
    let bytes = units.len().saturating_mul(size_of::<u16>());
    // SAFETY: bytes is the checked UTF-16 byte count; the HGLOBAL stays owned until transfer or GlobalFree.
    let allocation = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes) };
    if !allocation.is_null() {
        // SAFETY: allocation is the non-null newly allocated HGLOBAL and stays owned while its pointer is used.
        let locked = unsafe { GlobalLock(allocation) } as *mut u16;
        if !locked.is_null() {
            // SAFETY: locked spans units.len writable u16 slots, units has that many elements, and they cannot overlap.
            unsafe {
                std::ptr::copy_nonoverlapping(units.as_ptr(), locked, units.len());
                GlobalUnlock(allocation);
            }
            let transferred =
                // SAFETY: allocation is unlocked movable HGLOBAL containing terminated UTF-16; success transfers ownership.
                unsafe { SetClipboardData(u32::from(CF_UNICODETEXT), allocation as HANDLE) };
            if transferred.is_null() {
                // SAFETY: allocation is a non-null HGLOBAL still owned here because clipboard ownership was not transferred.
                unsafe { GlobalFree(allocation) };
            }
        } else {
            // SAFETY: allocation is a non-null HGLOBAL still owned here because clipboard ownership was not transferred.
            unsafe { GlobalFree(allocation) };
        }
    }
    // SAFETY: This thread closes exactly the clipboard session successfully opened above.
    unsafe { CloseClipboard() };
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
    let _ = write_legacy_text(&path, &text);
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
    state.directory_mode = None;
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

fn write_legacy_text(path: &Path, text: &LegacyText) -> io::Result<()> {
    let mut bytes = Vec::with_capacity(2 + text.len() * 2);
    bytes.extend_from_slice(&[0xFF, 0xFE]);
    for unit in text.units() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    fs::write(path, bytes)
}

fn read_legacy_text(path: &Path) -> io::Result<LegacyText> {
    if fs::metadata(path)?.len() > MAX_IMPORT_BYTES as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "가져오기 파일이 2 MiB 한도를 초과합니다",
        ));
    }
    let bytes = read_bounded_import(fs::File::open(path)?)?;
    if bytes.starts_with(&[0xFF, 0xFE]) {
        let units = bytes[2..]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect::<Vec<_>>();
        return Ok(LegacyText::from_units(units));
    }
    if bytes.is_empty() {
        return Ok(LegacyText::default());
    }
    let input_len =
        i32::try_from(bytes.len()).map_err(|_| io::Error::other("text file too large"))?;
    let needed =
        // SAFETY: bytes is readable for input_len and any output pointer targets the previously sized UTF-16 buffer.
        unsafe { MultiByteToWideChar(CP_ACP, 0, bytes.as_ptr(), input_len, null_mut(), 0) };
    if needed <= 0 {
        return Err(io::Error::last_os_error());
    }
    let mut units = vec![0_u16; needed as usize];
    // SAFETY: bytes is readable for input_len and any output pointer targets the previously sized UTF-16 buffer.
    let written = unsafe {
        MultiByteToWideChar(
            CP_ACP,
            0,
            bytes.as_ptr(),
            input_len,
            units.as_mut_ptr(),
            needed,
        )
    };
    if written <= 0 {
        return Err(io::Error::last_os_error());
    }
    units.truncate(written as usize);
    Ok(LegacyText::from_units(units))
}

fn update_column_visibility(state: &AppState, index: usize) {
    let column = index + 3;
    let width = if state.shown_columns[index] {
        if column == 4 { 80 } else { 120 }
    } else {
        0
    };
    // SAFETY: state.list_window is live and LVM_SETCOLUMNWIDTH carries only the
    // computed column and width values, with no pointer payload.
    unsafe {
        SendMessageW(state.list_window, LVM_SETCOLUMNWIDTH, column, width);
    }
}

struct RedrawGuard {
    window: HWND,
}

impl RedrawGuard {
    unsafe fn suspend(window: HWND) -> Self {
        if !window.is_null() {
            // SAFETY: window is the non-null AppState ListView HWND; WM_SETREDRAW
            // carries no pointer payload and the guard retains this exact value.
            unsafe { SendMessageW(window, WM_SETREDRAW, 0, 0) };
        }
        Self { window }
    }
}

impl Drop for RedrawGuard {
    fn drop(&mut self) {
        if !self.window.is_null() {
            // SAFETY: self.window is the same AppState ListView HWND suspended by
            // this guard; redraw messages use null regions and retain no pointers.
            unsafe {
                SendMessageW(self.window, WM_SETREDRAW, 1, 0);
                RedrawWindow(
                    self.window,
                    null(),
                    null_mut(),
                    RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
                );
            }
        }
    }
}

fn refresh(state: &mut AppState) {
    // SAFETY: state.list_window is live and the guard restores redraw for that exact HWND on every drop path.
    let _redraw = unsafe { RedrawGuard::suspend(state.list_window) };
    let selected = { selected_indices(state.list_window) };
    // SAFETY: state.list_window is live and LVM_DELETEALLITEMS carries no pointer
    // payload; redraw remains suspended by the guard.
    unsafe { SendMessageW(state.list_window, LVM_DELETEALLITEMS, 0, 0) };
    for (row, item) in state.model.items().iter().enumerate() {
        let size = LegacyText::from(item.actual_size().to_string());
        let modified = format_filetime(item.modified());
        let created = format_filetime(item.created());
        let values = [
            item.current_name().clone(),
            item.proposed_name().clone(),
            item.root_path().clone(),
            item.source_path().clone(),
            size,
            modified,
            created,
        ];
        for (column, value) in values.iter().enumerate() {
            let mut text = value.units().to_vec();
            text.push(0);
            if column == 0 {
                let mut native = LVITEMW {
                    mask: LVIF_TEXT | LVIF_IMAGE,
                    iItem: row as i32,
                    iSubItem: 0,
                    pszText: text.as_mut_ptr(),
                    iImage: { file_icon_index(&mut state.icon_cache, item) },
                    // SAFETY: LVITEMW is C-compatible; zero initializes unused
                    // fields before text/image fields are sent synchronously.
                    ..unsafe { zeroed() }
                };
                // SAFETY: state.list_window is live; native and its terminated text
                // buffer remain allocated until LVM_INSERTITEMW returns.
                unsafe {
                    SendMessageW(
                        state.list_window,
                        LVM_INSERTITEMW,
                        0,
                        (&mut native as *mut LVITEMW) as isize,
                    )
                };
            } else {
                let mut native = LVITEMW {
                    iSubItem: column as i32,
                    pszText: text.as_mut_ptr(),
                    // SAFETY: LVITEMW is C-compatible; zero initializes optional fields before its explicit message fields are set.
                    ..unsafe { zeroed() }
                };
                // SAFETY: state.list_window is live; native and its terminated text
                // buffer remain allocated until LVM_SETITEMTEXTW returns.
                unsafe {
                    SendMessageW(
                        state.list_window,
                        LVM_SETITEMTEXTW,
                        row,
                        (&mut native as *mut LVITEMW) as isize,
                    )
                };
            }
        }
    }
    select_rows(state.list_window, &selected);
    update_controls(state);
    let status = if state.model.is_empty() {
        LegacyText::default()
    } else {
        LegacyText::from(format!("{} 개", state.model.len()))
    };
    let mut status = status.units().to_vec();
    status.push(0);
    // SAFETY: The status HWND is live and text is owned terminated UTF-16 retained through SetWindowTextW.
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(state.status, status.as_ptr());
    }
}

fn update_controls(state: &mut AppState) {
    let selected_count = { selected_indices(state.list_window) }.len();
    for id in APPLY..=VERSION {
        state.command_states[usize::from(id - APPLY)] =
            command_enabled(id, state.model.len(), selected_count)
                && !(id == APPLY && state.apply_locked());
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

fn file_icon_index(cache: &mut HashMap<IconCacheKey, i32>, item: &LegacyListItem) -> i32 {
    let key = icon_cache_key(item.current_name(), item.is_directory());
    if let Some(index) = cache.get(&key) {
        return *index;
    }
    // SAFETY: SHFILEINFOW is a C-compatible output structure whose all-zero state is valid before the shell fills it.
    let mut info: SHFILEINFOW = unsafe { zeroed() };
    let path = key.lookup_text();
    let mut path = path.units().to_vec();
    path.push(0);
    let attributes = if item.is_directory() {
        FILE_ATTRIBUTE_DIRECTORY
    } else {
        FILE_ATTRIBUTE_NORMAL
    };
    // SAFETY: The lookup path is owned terminated UTF-16 and info is writable SHFILEINFOW retained for the shell query.
    unsafe {
        SHGetFileInfoW(
            path.as_ptr(),
            attributes,
            &mut info,
            size_of::<SHFILEINFOW>() as u32,
            SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON,
        );
    }
    cache.insert(key, info.iIcon);
    info.iIcon
}

fn format_filetime(value: u64) -> LegacyText {
    if value == 0 {
        return LegacyText::default();
    }
    let filetime = FILETIME {
        dwLowDateTime: value as u32,
        dwHighDateTime: (value >> 32) as u32,
    };
    // SAFETY: SYSTEMTIME is a C-compatible integer structure whose all-zero state
    // is valid writable output before FileTimeToSystemTime fills it.
    let mut system: SYSTEMTIME = unsafe { zeroed() };
    // SAFETY: filetime is initialized and system is writable SYSTEMTIME retained through conversion.
    if unsafe { FileTimeToSystemTime(&filetime, &mut system) } == 0 {
        return LegacyText::default();
    }
    LegacyText::from(format!(
        "{}-{:02}-{:02} {:02}:{:02}:{:02}",
        system.wYear, system.wMonth, system.wDay, system.wHour, system.wMinute, system.wSecond
    ))
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
        menu_item(tools, UNIFY_PATH, "경로 통일하기");
        append_popup(menu, tools, "기능(&T)");
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

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain([0]).collect()
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
