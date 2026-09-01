use std::cell::{Cell, UnsafeCell};
use std::collections::HashMap;
use std::env;
use std::ffi::c_void;
use std::fs;
use std::io;
use std::marker::PhantomData;
use std::mem::size_of;
use std::num::NonZeroIsize;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::ptr::NonNull;
use std::ptr::{null, null_mut};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError, sync_channel};
use std::thread::{self, JoinHandle};

use crate::admission::{
    AdmissionAdapter, AdmissionMode, AdmissionReport, MAX_ADMITTED_SOURCES, PathBudget,
    PathBudgetReservation, WindowsAdmissionAdapter, bounded_import_lines, bounded_selection,
    collect_admission_cancellable_with_budget,
};
use crate::icon_cache::{IconCacheKey, icon_cache_key};
use crate::preferences::{
    AppearancePreferencesWriter, PreferenceWriteEvent, PreferencesWriter,
    appearance_path_for_journal_root, load_appearance_or_default,
    load_or_default as load_column_preferences, path_for_journal_root, shown_columns,
};
use crate::rename::{
    CancellationToken, ExecuteError, ExecuteErrorKind, ExecutionControl, ExecutionOutcome,
    ExecutionOutcomePresentation, ExecutionPhase, ExecutionProgress, ExecutionReport,
    ExistingJournalOpenError, FileJournal, FileJournalError, JournalCleanupDecision,
    JournalOpenFailure, JournalRoot, MAX_PATH_UNITS, ModelRevision, PlanAttemptError, PlanError,
    RecoveryJournalEvidence, RecoveryOutcome, RenameBackend, RenameExecutor, RenamePlan,
    RenamePlanner, RenameRecovery, WindowsRenameBackend, apply_execution_report,
    build_plan_request, cleanup_decision, execute_error_korean, execution_outcome_korean,
    execution_outcome_presentation, next_model_revision, plan_error_korean,
    preflight_plan_cancellable, process_is_elevated, safe_mode_unify_path_message,
};
use darknamer_core::{
    LegacyAppendIndex, LegacyInputError, LegacyList, LegacyListItem, LegacySequenceMode,
    LegacySortMode, LegacyText, ProposalMutationError, SortSemantics,
};
use raw_window_handle::{
    DisplayHandle, HandleError, HasDisplayHandle, HasWindowHandle, RawWindowHandle,
    Win32WindowHandle, WindowHandle,
};
use windows_sys::core::{GUID, HRESULT, IID_IUnknown};

mod appearance;
mod appearance_dialog;
mod application;
mod clipboard;
mod command_dispatch;
mod command_rail;
mod dialog;
mod drag_drop;
mod list_view;
mod menu;
mod recovery_ui;
#[path = "../resource_ids.rs"]
mod resource_ids;
mod safe_runtime;
mod text_io;
#[cfg(test)]
mod visual_capture;
mod worker;

fn proposal_mutation_error_korean(error: ProposalMutationError) -> &'static str {
    match error {
        ProposalMutationError::InvalidInput(LegacyInputError::NonPositiveWidth) => {
            "자리수 입력이 잘못되었습니다."
        }
        ProposalMutationError::InvalidInput(_) => {
            "입력값이 올바르지 않아 목록을 변경하지 않았습니다."
        }
        ProposalMutationError::NameBudgetExceeded { .. }
        | ProposalMutationError::AggregateBudgetExceeded { .. }
        | ProposalMutationError::ArithmeticOverflow => {
            "변경 결과가 안전 한도를 초과했습니다. 목록은 변경되지 않았습니다. 입력 내용을 줄여 다시 시도하세요."
        }
        ProposalMutationError::AllocationFailed => {
            "변경 결과를 준비할 메모리가 부족합니다. 목록은 변경되지 않았습니다. 다른 프로그램을 닫고 다시 시도하세요."
        }
    }
}

use clipboard::copy_clipboard;
use command_dispatch::*;
use command_rail::CommandRail;
use dialog::*;
use drag_drop::*;
#[cfg(test)]
use list_view::changed_column_mask;
use list_view::{
    RenderedRow, handle_header_end_track, handle_list_custom_draw, handle_list_infotip,
    install_list_view_notification_subclass, refresh, refresh_all_rows, refresh_changed_rows,
    refresh_proposal_rows, remove_list_view_notification_subclass, update_column_visibility,
    update_dpi_metrics, update_primary_column_widths,
};
use menu::*;
use recovery_ui::*;
#[cfg(test)]
use safe_runtime::initialize_safe_runtime_at;
use safe_runtime::{
    JournalRole, SafeRuntime, StartupJournalBlock, cleanup_file_journal, initialize_safe_runtime,
};
use text_io::{compare_windows, legacy_path, path_wide, read_legacy_text, wide, write_legacy_text};
use windows_sys::Win32::Foundation::{
    E_FAIL, E_NOINTERFACE, E_POINTER, FILETIME, HWND, LPARAM, LRESULT, POINTL, RECT, S_OK,
    SYSTEMTIME, WPARAM,
};
use windows_sys::Win32::Globalization::{DATE_SHORTDATE, GetDateFormatEx, GetTimeFormatEx};
use windows_sys::Win32::Graphics::Gdi::{
    COLOR_WINDOW, COLOR_WINDOWTEXT, CreateFontIndirectW, DT_CALCRECT, DT_END_ELLIPSIS, DT_LEFT,
    DT_NOPREFIX, DT_RIGHT, DT_SINGLELINE, DT_VCENTER, DT_WORDBREAK, DeleteObject, DrawTextW,
    FillRect, GetDC, GetMonitorInfoW, GetSysColor, GetSysColorBrush, HBRUSH, HDC, HFONT,
    MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromWindow, RDW_ALLCHILDREN, RDW_ERASE,
    RDW_INVALIDATE, RedrawWindow, ReleaseDC, SelectObject, SetBkColor, SetBkMode, SetTextColor,
    TRANSPARENT, UpdateWindow,
};
#[cfg(test)]
use windows_sys::Win32::Graphics::Gdi::{GetBkColor, GetPixel, GetTextColor};
#[cfg(test)]
use windows_sys::Win32::Storage::FileSystem::MoveFileW;
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL, MOVEFILE_REPLACE_EXISTING,
    MOVEFILE_WRITE_THROUGH, MoveFileExW,
};
use windows_sys::Win32::System::Com::{DVASPECT_CONTENT, FORMATETC, STGMEDIUM, TYMED_HGLOBAL};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
#[cfg(test)]
use windows_sys::Win32::System::Memory::{
    MEM_COMMIT, MEM_RELEASE, MEM_RESERVE, PAGE_NOACCESS, PAGE_READWRITE, VirtualAlloc, VirtualFree,
    VirtualProtect,
};
use windows_sys::Win32::System::Ole::{
    CF_HDROP, DROPEFFECT_COPY, OleInitialize, OleUninitialize, RegisterDragDrop, ReleaseStgMedium,
    RevokeDragDrop,
};
#[cfg(test)]
use windows_sys::Win32::System::SystemInformation::{GetSystemInfo, SYSTEM_INFO};
use windows_sys::Win32::System::SystemServices::{
    SS_CENTER, SS_CENTERIMAGE, SS_ENDELLIPSIS, SS_NOPREFIX, SS_OWNERDRAW,
};
#[cfg(test)]
use windows_sys::Win32::System::SystemServices::{SS_NOTIFY, SS_SUNKEN, SS_TYPEMASK};
use windows_sys::Win32::System::Time::{FileTimeToSystemTime, SystemTimeToTzSpecificLocalTimeEx};
use windows_sys::Win32::UI::Accessibility::{HCF_HIGHCONTRASTON, HIGHCONTRASTW};
#[cfg(test)]
use windows_sys::Win32::UI::Controls::CDIS_FOCUS;
use windows_sys::Win32::UI::Controls::{
    CDDS_ITEMPREPAINT, CDDS_POSTPAINT, CDDS_PREPAINT, CDDS_SUBITEM, CDIS_HOT, CDIS_SELECTED,
    CDRF_DODEFAULT, CDRF_NEWFONT, CDRF_NOTIFYITEMDRAW, CDRF_NOTIFYPOSTPAINT,
    CDRF_NOTIFYSUBITEMDRAW, CDRF_SKIPDEFAULT, HDI_TEXT, HDI_WIDTH, HDITEMW, HDM_GETITEMCOUNT,
    HDM_GETITEMRECT, HDM_GETITEMW, HDN_DIVIDERDBLCLICKW, HDN_ENDTRACKW, HDN_ITEMCHANGEDW,
    HDN_ITEMCHANGINGW, ICC_LISTVIEW_CLASSES, ICC_WIN95_CLASSES, INITCOMMONCONTROLSEX,
    InitCommonControlsEx, LVCF_FMT, LVCF_TEXT, LVCF_WIDTH, LVCFMT_LEFT, LVCFMT_RIGHT, LVCOLUMNW,
    LVIF_IMAGE, LVIF_TEXT, LVIS_FOCUSED, LVIS_SELECTED, LVITEMW, LVM_DELETEALLITEMS,
    LVM_DELETEITEM, LVM_ENSUREVISIBLE, LVM_GETCOLUMNWIDTH, LVM_GETHEADER, LVM_GETITEMCOUNT,
    LVM_GETITEMSTATE, LVM_GETNEXTITEM, LVM_INSERTCOLUMNW, LVM_INSERTITEMW, LVM_SETCOLUMNWIDTH,
    LVM_SETEXTENDEDLISTVIEWSTYLE, LVM_SETIMAGELIST, LVM_SETITEMSTATE, LVM_SETITEMTEXTW,
    LVM_SETITEMW, LVN_GETINFOTIPW, LVN_ITEMCHANGED, LVN_MARQUEEBEGIN, LVNI_FOCUSED, LVNI_SELECTED,
    LVS_EX_DOUBLEBUFFER, LVS_EX_FULLROWSELECT, LVS_EX_INFOTIP, LVS_EX_LABELTIP, LVS_NOSORTHEADER,
    LVS_REPORT, LVS_SHAREIMAGELISTS, LVS_SHOWSELALWAYS, LVSIL_SMALL, NM_CUSTOMDRAW, NM_DBLCLK,
    NM_SETFOCUS, NMCUSTOMDRAW, NMHDR, NMHEADERW, NMLISTVIEW, NMLVCUSTOMDRAW, NMLVGETINFOTIPW,
    TASKDIALOG_BUTTON, TASKDIALOGCONFIG, TASKDIALOGCONFIG_0, TASKDIALOGCONFIG_1, TD_WARNING_ICON,
    TDCBF_CANCEL_BUTTON, TDF_ALLOW_DIALOG_CANCELLATION, TDF_POSITION_RELATIVE_TO_WINDOW,
    TDF_SIZE_TO_CONTENT, TDF_USE_COMMAND_LINKS, TaskDialogIndirect,
};
#[cfg(test)]
use windows_sys::Win32::UI::Controls::{
    DRAWITEMSTRUCT, LVM_GETITEMTEXTW, MEASUREITEMSTRUCT, ODS_DEFAULT, ODS_FOCUS, ODT_BUTTON,
    ODT_MENU,
};
use windows_sys::Win32::UI::HiDpi::{
    AdjustWindowRectExForDpi, GetDpiForWindow, SystemParametersInfoForDpi,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetFocus, IsWindowEnabled, SetFocus, VK_DELETE, VK_DOWN, VK_ESCAPE, VK_F6,
    VK_OEM_COMMA, VK_OEM_PERIOD, VK_UP,
};
use windows_sys::Win32::UI::Shell::{
    DefSubclassProc, DragQueryFileW, HDROP, RemoveWindowSubclass, SHFILEINFOW, SHGFI_SMALLICON,
    SHGFI_SYSICONINDEX, SHGFI_USEFILEATTRIBUTES, SHGetFileInfoW, SetWindowSubclass,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    ACCEL, AppendMenuW, BN_CLICKED, BN_SETFOCUS, BS_DEFPUSHBUTTON, BS_OWNERDRAW, BS_PUSHBUTTON,
    BeginDeferWindowPos, CB_ADDSTRING, CB_GETCURSEL, CB_SETCURSEL, CBS_DROPDOWNLIST, CREATESTRUCTW,
    CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, CheckMenuItem, CheckMenuRadioItem,
    CreateAcceleratorTableW, CreateMenu, CreatePopupMenu, CreateWindowExW, DefWindowProcW,
    DeferWindowPos, DestroyAcceleratorTable, DestroyMenu, DestroyWindow, DispatchMessageW,
    DrawMenuBar, ES_AUTOHSCROLL, EnableMenuItem, EndDeferWindowPos, FCONTROL, FSHIFT, FVIRTKEY,
    GWLP_USERDATA, GetClientRect, GetMenuItemCount, GetMenuItemInfoW, GetMessageW, GetParent,
    GetWindowLongPtrW, GetWindowRect, GetWindowTextLengthW, GetWindowTextW, HACCEL, HMENU,
    HWND_BOTTOM, IDC_ARROW, IDCANCEL, IDOK, IsDialogMessageW, IsWindow, IsWindowVisible, KillTimer,
    LoadCursorW, LoadIconW, MENUITEMINFOW, MF_BYCOMMAND, MF_CHECKED, MF_ENABLED, MF_GRAYED,
    MF_OWNERDRAW, MF_POPUP, MF_SEPARATOR, MF_UNCHECKED, MIIM_DATA, MIIM_STRING, MIIM_SUBMENU,
    MINMAXINFO, MNC_EXECUTE, MNC_IGNORE, MNC_SELECT, MSG, MessageBoxW, MoveWindow,
    NONCLIENTMETRICSW, PostMessageW, PostQuitMessage, RegisterClassExW, SPI_GETHIGHCONTRAST,
    SPI_GETNONCLIENTMETRICS, SW_HIDE, SW_SHOW, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOREDRAW,
    SWP_NOSIZE, SWP_NOZORDER, SendMessageW, SetForegroundWindow, SetMenu, SetMenuItemInfoW,
    SetTimer, SetWindowLongPtrW, SetWindowPos, ShowWindow, SystemParametersInfoW,
    TranslateAcceleratorW, TranslateMessage, USER_TIMER_MINIMUM, WM_APP, WM_CLOSE, WM_COMMAND,
    WM_CREATE, WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX, WM_CTLCOLORSTATIC, WM_DESTROY, WM_DPICHANGED,
    WM_DRAWITEM, WM_ERASEBKGND, WM_FONTCHANGE, WM_GETMINMAXINFO, WM_KEYDOWN, WM_MEASUREITEM,
    WM_MENUCHAR, WM_NCACTIVATE, WM_NCCREATE, WM_NCDESTROY, WM_NCPAINT, WM_NOTIFY, WM_SETFOCUS,
    WM_SETFONT, WM_SETREDRAW, WM_SETTINGCHANGE, WM_SIZE, WM_SYSCOLORCHANGE, WM_THEMECHANGED,
    WM_TIMER, WNDCLASSEXW, WS_BORDER, WS_CAPTION, WS_CHILD, WS_CLIPCHILDREN, WS_CLIPSIBLINGS,
    WS_EX_APPWINDOW, WS_EX_TOOLWINDOW, WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_OVERLAPPEDWINDOW,
    WS_POPUP, WS_SYSMENU, WS_TABSTOP, WS_VISIBLE,
};
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BM_CLICK, BS_FLAT, BS_MULTILINE, BS_TYPEMASK, GW_CHILD, GW_HWNDLAST, GW_HWNDNEXT, GWL_STYLE,
    GetClassNameW, GetDlgCtrlID, GetWindow, HWND_TOP,
};
use worker::*;

use appearance::*;
use appearance_dialog::*;

use crate::*;

const LIST_ID: usize = 1000;
const STATUS_MESSAGE_ID: usize = 1007;
const STATUS_COUNT_ID: usize = 1008;
const CANCEL_WORKER_ID: u16 = 1009;
const EMPTY_INSTRUCTION_ID: u16 = 1010;
const EMPTY_SAFETY_ID: u16 = 1011;
const EMPTY_ADD_ID: u16 = ADD_FILES;
const CANDIDATE_JOURNAL_LEAF: &str = "candidate.drj";
const ACTIVE_JOURNAL_LEAF: &str = "active.drj";
const EXPORT_RECOVERY_JOURNAL: u16 = 0x9000;
const DISCARD_STAGED_JOURNAL: u16 = 0x9001;
const SHOW_RECOVERY_STATUS: u16 = 0x9002;
const WM_APP_APPLY_PROGRESS: u32 = WM_APP + 0x40;
const WM_APP_APPLY_COMPLETE: u32 = WM_APP + 0x41;
const WM_APP_PLAN_COMPLETE: u32 = WM_APP + 0x42;
const WM_APP_ADMISSION_COMPLETE: u32 = WM_APP + 0x43;
const WM_APP_RESTORE_FOCUS: u32 = WM_APP + 0x44;
const WM_APP_PREFERENCES_WAKE: u32 = WM_APP + 0x45;
const WM_APP_ADMISSION_STARTED: u32 = WM_APP + 0x46;
const WM_APP_APPEARANCE_PREVIEW: u32 = WM_APP + 0x47;
const WM_APP_APPEARANCE_FINISH: u32 = WM_APP + 0x48;
const WM_APP_APPEARANCE_ACCESSIBILITY: u32 = WM_APP + 0x49;
const WM_APP_APPEARANCE_DISMISS: u32 = WM_APP + 0x4A;
const WM_APP_APPEARANCE_ARM: u32 = WM_APP + 0x4B;
const WM_APP_LAYOUT: u32 = WM_APP + 0x4C;
const WM_APP_EMPTY_SAFETY_COPY: u32 = WM_APP + 0x4D;
const WM_APP_APPEARANCE_RESTORE_FOCUS: u32 = WM_APP + 0x4E;
const WM_APP_FINISH_CLOSE: u32 = WM_APP + 0x4F;
const WM_APP_MENU_REDRAW: u32 = WM_APP + 0x50;
const APPLY_POLL_TIMER_ID: usize = 0xD4A1;
const PREFERENCES_POLL_TIMER_ID: usize = 0xD4A2;
const STATUS_RENDER_TIMER_ID: usize = 0xD4A3;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CallbackStateStatus {
    Available,
    Leased,
    ReclaimPending,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ReclaimDisposition {
    Reclaimed,
    Deferred,
}

/// Owns callback state separately from the lease cell used to guard it.
///
/// Windows publishes a raw pointer to this allocation. Callback entry touches
/// only `status` or a disjoint scalar sidecar; it does not create a reference to
/// `value` unless the lease changes from `Available` to `Leased`. All access is
/// confined to the UI thread.
struct CallbackState<T, R = ()> {
    status: Cell<CallbackStateStatus>,
    menu_edge_color: Cell<Option<u32>>,
    retirement: UnsafeCell<Option<R>>,
    value: UnsafeCell<T>,
}

struct CallbackStateLease<T, R = ()> {
    slot: NonNull<CallbackState<T, R>>,
    _ui_thread_only: PhantomData<Rc<()>>,
}

impl<T, R> CallbackState<T, R> {
    fn into_raw(value: T) -> *mut Self {
        Box::into_raw(Box::new(Self {
            status: Cell::new(CallbackStateStatus::Available),
            menu_edge_color: Cell::new(None),
            retirement: UnsafeCell::new(None),
            value: UnsafeCell::new(value),
        }))
    }

    unsafe fn try_lease(slot: *mut Self) -> Option<CallbackStateLease<T, R>> {
        let slot = NonNull::new(slot)?;
        // SAFETY: the caller guarantees that `slot` is either the currently
        // published allocation or a still-live allocation whose reclamation is
        // pending on its sole lease. `status` is disjoint from `value`.
        let status = unsafe { &*std::ptr::addr_of!((*slot.as_ptr()).status) };
        if status.get() != CallbackStateStatus::Available {
            return None;
        }
        status.set(CallbackStateStatus::Leased);
        Some(CallbackStateLease {
            slot,
            _ui_thread_only: PhantomData,
        })
    }

    unsafe fn menu_edge_color(slot: *mut Self) -> Option<u32> {
        let slot = NonNull::new(slot)?;
        // SAFETY: the caller guarantees that this is the live UI-thread slot.
        // This scalar Cell is disjoint from both the leased value and the
        // retirement sidecar and creates no reference to either one.
        let color = unsafe { &*std::ptr::addr_of!((*slot.as_ptr()).menu_edge_color) };
        color.get()
    }

    unsafe fn set_menu_edge_color(slot: *mut Self, color: Option<u32>) {
        let Some(slot) = NonNull::new(slot) else {
            return;
        };
        // SAFETY: all access is serialized on the owning UI thread and touches
        // only this scalar Cell, never the possibly leased value or retirement.
        let sidecar = unsafe { &*std::ptr::addr_of!((*slot.as_ptr()).menu_edge_color) };
        sidecar.set(color);
    }

    unsafe fn request_reclaim(slot: *mut Self) -> ReclaimDisposition {
        let Some(slot) = NonNull::new(slot) else {
            return ReclaimDisposition::Deferred;
        };
        // SAFETY: the caller has unpublished this UI-thread-owned allocation,
        // so no new callback can acquire it. A pending outer lease keeps the
        // allocation live until `CallbackStateLease::drop`.
        let previous = {
            // SAFETY: the slot remains live until the state transition decides
            // whether reclamation is immediate or deferred.
            let status = unsafe { &*std::ptr::addr_of!((*slot.as_ptr()).status) };
            status.replace(CallbackStateStatus::ReclaimPending)
        };
        match previous {
            CallbackStateStatus::Available => {
                // SAFETY: publication was cleared and no lease exists. This is
                // the allocation's unique immediate reclamation path.
                unsafe { drop(Box::from_raw(slot.as_ptr())) };
                ReclaimDisposition::Reclaimed
            }
            CallbackStateStatus::Leased | CallbackStateStatus::ReclaimPending => {
                ReclaimDisposition::Deferred
            }
        }
    }

    unsafe fn install_retirement(slot: *mut Self, retirement: R) -> Result<(), R> {
        let Some(slot) = NonNull::new(slot) else {
            return Err(retirement);
        };
        // SAFETY: the caller owns this UI-thread slot and accesses only the
        // sidecar UnsafeCell, which is disjoint from any leased state value.
        let sidecar = unsafe { &mut *(*slot.as_ptr()).retirement.get() };
        if sidecar.is_some() {
            Err(retirement)
        } else {
            *sidecar = Some(retirement);
            Ok(())
        }
    }

    unsafe fn take_retirement(slot: *mut Self) -> Option<R> {
        let slot = NonNull::new(slot)?;
        // SAFETY: all access is serialized on the owning UI thread and touches
        // only the sidecar UnsafeCell, never the possibly leased state value.
        unsafe { (&mut *(*slot.as_ptr()).retirement.get()).take() }
    }
}

impl<T, R> CallbackStateLease<T, R> {
    fn state(&self) -> &T {
        // SAFETY: this lease is the only lease for `value`, and shared access is
        // bounded by this borrow of the lease.
        unsafe { &*(*self.slot.as_ptr()).value.get() }
    }

    fn state_mut(&mut self) -> &mut T {
        // SAFETY: this lease is the only lease for `value`, and mutable access is
        // bounded by this exclusive borrow of the lease.
        unsafe { &mut *(*self.slot.as_ptr()).value.get() }
    }
}

impl<T, R> Drop for CallbackStateLease<T, R> {
    fn drop(&mut self) {
        // SAFETY: the slot remains live for the duration of its sole lease.
        let reclaim = {
            // SAFETY: the slot remains live until this sole lease decides
            // whether it must perform deferred reclamation.
            let status = unsafe { &*std::ptr::addr_of!((*self.slot.as_ptr()).status) };
            match status.replace(CallbackStateStatus::Available) {
                CallbackStateStatus::Leased => false,
                CallbackStateStatus::ReclaimPending => true,
                CallbackStateStatus::Available => false,
            }
        };
        if reclaim {
            // SAFETY: reclamation was requested after publication was cleared,
            // and this is the sole lease ending, so exactly one owner remains.
            unsafe { drop(Box::from_raw(self.slot.as_ptr())) };
        }
    }
}

fn run_after_callback_state_release<T, R, O>(
    lease: CallbackStateLease<T, R>,
    action: impl FnOnce() -> O,
) -> O {
    drop(lease);
    action()
}

type AppStateSlot = CallbackState<AppState, DropTargetRegistrations>;

fn app_state_slot(window: HWND) -> *mut AppStateSlot {
    if window.is_null() {
        return null_mut();
    }
    // SAFETY: this value query reads only the slot pointer published for this
    // exact window and creates no Rust reference.
    unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) as *mut AppStateSlot }
}

fn try_app_state(window: HWND) -> Option<CallbackStateLease<AppState, DropTargetRegistrations>> {
    // SAFETY: GWLP_USERDATA is cleared before reclamation, and all callbacks
    // accessing it are confined to the owning UI thread.
    unsafe { CallbackState::try_lease(app_state_slot(window)) }
}

struct AppState {
    list_window: HWND,
    status_message: HWND,
    status_count: HWND,
    cancel_worker: HWND,
    empty_instruction: HWND,
    empty_safety: HWND,
    empty_add: HWND,
    drop_overlay: HWND,
    menu: HMENU,
    pending_menu: Option<OwnedMenu>,
    font: OwnedFont,
    status_font: OwnedFont,
    left_rail: Option<CommandRail>,
    right_rail: Option<CommandRail>,
    model: LegacyList,
    append_index: LegacyAppendIndex<fn(&LegacyText, &LegacyText) -> std::cmp::Ordering>,
    shown_columns: [bool; 4],
    column_states: [ColumnState; 7],
    status_column_width_dip: i32,
    appearance: UiAppearance,
    dpi: u32,
    command_states: [bool; 34],
    model_revision: u64,
    mutation_locked: bool,
    recovery_locked: bool,
    column_preferences_path: PathBuf,
    appearance_preferences_path: PathBuf,
    journal_root: JournalRoot,
    active_journal: Option<FileJournal>,
    staged_journal: Option<FileJournal>,
    blocked_journals: Vec<StartupJournalBlock>,
    collision_observed: bool,
    apply_worker: Option<ApplyWorker>,
    plan_worker: Option<PlanWorker>,
    admission_worker: Option<AdmissionWorker>,
    preferences_writer: Option<PreferencesWriter>,
    preferences_failure_generation: Option<u64>,
    preferences_terminal_observed: bool,
    appearance_writer: Option<AppearancePreferencesWriter>,
    appearance_failure_generation: Option<u64>,
    appearance_terminal_observed: bool,
    close_pending: bool,
    confirmation_pending: bool,
    active_prompt: Option<u64>,
    next_prompt_id: u64,
    font_metrics: MeasuredFontMetrics,
    focus: FocusState,
    rails_visible: bool,
    ui_status: UiStatus,
    preview_count_cache: PreviewCountCache,
    preview_issue_cache: PreviewIssueCache,
    preview_synchronization: PreviewSynchronization,
    status_layout_input: StatusLayoutInput,
    status_chrome: StatusChromeGeometry,
    workspace_chrome: WorkspaceChromeGeometry,
    forced_colors: ForcedColorsState,
    system_theme: Option<ResolvedTheme>,
    appearance_resources: Option<AppearanceResources>,
    menu_fallback_resources: Vec<AppearanceResources>,
    appearance_dialog: Option<AppearanceDialogSession>,
    next_appearance_dialog_id: u32,
    dwm_dark_frame_requested: bool,
    icon_cache: HashMap<IconCacheKey, i32>,
    rendered_rows: Vec<RenderedRow>,
    // Fields drop in declaration order. Keep the instance lock last so workers
    // and every retained journal capability close before another launch.
    _runtime_lock: fs::File,
}

impl AppState {
    fn new(runtime: SafeRuntime) -> Self {
        let column_preferences_path = path_for_journal_root(runtime.root.path());
        let appearance_preferences_path = appearance_path_for_journal_root(runtime.root.path());
        let loaded_columns =
            load_column_preferences(&column_preferences_path, default_column_states());
        let loaded_appearance = load_appearance_or_default(&appearance_preferences_path);
        let mut ui_status = runtime
            .status
            .clone()
            .map_or_else(UiStatus::default, |status| {
                if runtime.recovery_locked {
                    UiStatus::with_recovery(status)
                } else {
                    UiStatus::with_transient(status)
                }
            });
        if let Some(error) = loaded_columns.failure {
            ui_status.set_transient(format!(
                "열 표시 설정을 불러오지 못해 안전한 기본값을 사용합니다: {error}"
            ));
        }
        if let Some(error) = loaded_appearance.failure {
            ui_status.set_transient(format!(
                "모양 설정을 불러오지 못해 안전한 기본값을 사용합니다: {error}"
            ));
        }
        let column_states = loaded_columns.columns;
        let appearance = loaded_appearance.appearance;
        Self {
            list_window: null_mut(),
            status_message: null_mut(),
            status_count: null_mut(),
            cancel_worker: null_mut(),
            empty_instruction: null_mut(),
            empty_safety: null_mut(),
            empty_add: null_mut(),
            drop_overlay: null_mut(),
            menu: null_mut(),
            pending_menu: None,
            font: OwnedFont::default(),
            status_font: OwnedFont::default(),
            left_rail: None,
            right_rail: None,
            model: LegacyList::new(),
            append_index: LegacyAppendIndex::new(
                compare_windows as fn(&LegacyText, &LegacyText) -> std::cmp::Ordering,
            ),
            shown_columns: shown_columns(&column_states),
            column_states,
            status_column_width_dip: NATIVE_STATUS_COLUMN_WIDTH_DIP,
            appearance,
            dpi: BASE_DPI,
            command_states: [false; 34],
            model_revision: 0,
            mutation_locked: false,
            recovery_locked: runtime.recovery_locked,
            column_preferences_path,
            appearance_preferences_path,
            journal_root: runtime.root,
            _runtime_lock: runtime.runtime_lock,
            active_journal: runtime.active_journal,
            staged_journal: runtime.staged_journal,
            blocked_journals: runtime.blocked_journals,
            collision_observed: runtime.collision_observed,
            apply_worker: None,
            plan_worker: None,
            admission_worker: None,
            preferences_writer: None,
            preferences_failure_generation: None,
            preferences_terminal_observed: false,
            appearance_writer: None,
            appearance_failure_generation: None,
            appearance_terminal_observed: false,
            close_pending: false,
            confirmation_pending: false,
            active_prompt: None,
            next_prompt_id: 0,
            font_metrics: MeasuredFontMetrics::default(),
            focus: FocusState::default(),
            rails_visible: true,
            ui_status,
            preview_count_cache: PreviewCountCache::default(),
            preview_issue_cache: PreviewIssueCache::default(),
            preview_synchronization: PreviewSynchronization::default(),
            status_layout_input: StatusLayoutInput::default(),
            status_chrome: StatusChromeGeometry::default(),
            workspace_chrome: WorkspaceChromeGeometry::default(),
            forced_colors: ForcedColorsState::default(),
            system_theme: None,
            appearance_resources: None,
            menu_fallback_resources: Vec::new(),
            appearance_dialog: None,
            next_appearance_dialog_id: 0,
            dwm_dark_frame_requested: false,
            icon_cache: HashMap::new(),
            rendered_rows: Vec::new(),
        }
    }

    fn revision(&self) -> ModelRevision {
        ModelRevision::new(self.model_revision)
    }

    fn resolved_appearance(&self) -> ResolvedUiAppearance {
        self.appearance
            .resolve(self.forced_colors, self.system_theme)
    }

    fn prompt_appearance(&self) -> PromptAppearance {
        PromptAppearance {
            preference: self.appearance,
            forced_colors: self.forced_colors,
            system_theme: self.system_theme,
        }
    }

    fn commit_known_model_change(&mut self, changed: bool) {
        self.model_revision = next_model_revision(self.model_revision, changed);
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

    fn preview_counts(&self, selected: usize) -> PreviewCounts {
        self.preview_count_cache.with_selected(selected)
    }

    fn presentation(&self, selected: usize) -> UiPresentation {
        let activity = self.worker_activity();
        let worker_active = activity.admission || activity.plan || activity.apply;
        UiPresentation::derive(
            self.preview_counts(selected),
            PresentationLocks {
                // ApplyPresentation::Ready is intentionally non-authorizing:
                // dispatch still enters apply_changes and its apply_locked gate.
                apply_locked: self.apply_locked()
                    || self.preview_issue_cache.has_blocker()
                    || !self.preview_synchronization.is_synchronized(),
                empty_locked: self.read_only_locked() || self.mutation_locked,
                worker_active,
            },
        )
    }

    const fn read_only_locked(&self) -> bool {
        self.recovery_locked
    }

    const fn drop_locked(&self) -> bool {
        self.apply_locked() || self.read_only_locked()
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

    fn can_confirm_active_recovery(&self) -> bool {
        self.recovery_locked
            && !self.mutation_locked
            && !self.confirmation_pending
            && !self.close_pending
            && !self.collision_observed
            && self.active_journal.is_some()
            && self.staged_journal.is_none()
            && self.blocked_journals.is_empty()
            && self.apply_worker.is_none()
            && self.plan_worker.is_none()
            && self.admission_worker.is_none()
    }

    fn can_export_recovery_journal(&self) -> bool {
        self.active_journal.is_some()
            || self.staged_journal.is_some()
            || self
                .blocked_journals
                .iter()
                .any(|blocked| blocked.evidence().is_some())
    }

    fn render_status(&self) {
        // Status mutations often occur while a window callback owns the sole
        // AppState lease. A same-HWND/ID timer coalesces repeated requests and
        // generates WM_TIMER only when no higher-priority message is queued,
        // keeping SetWindowTextW outside the mutation callback's lease.
        // SAFETY: status_message is either a live UI-thread child or null. A
        // null/retired child has no parent and deliberately installs no timer.
        let owner = unsafe { GetParent(self.status_message) };
        if !owner.is_null() {
            // SAFETY: owner is the copied parent HWND. Reusing this HWND/ID
            // replaces the existing UI-thread timer without a payload; failure
            // leaves no sticky app state, so a later mutation can retry.
            unsafe { SetTimer(owner, STATUS_RENDER_TIMER_ID, USER_TIMER_MINIMUM, None) };
        }
    }

    fn worker_activity(&self) -> WorkerActivity {
        WorkerActivity {
            admission: self.admission_worker.is_some(),
            plan: self.plan_worker.is_some(),
            apply: self.apply_worker.is_some(),
            cancellation_requested: self
                .admission_worker
                .as_ref()
                .is_some_and(AdmissionWorker::cancellation_requested)
                || self
                    .plan_worker
                    .as_ref()
                    .is_some_and(PlanWorker::cancellation_requested)
                || self
                    .apply_worker
                    .as_ref()
                    .is_some_and(ApplyWorker::cancellation_requested),
        }
    }

    fn set_status_item_count(&mut self) {
        let selected = selected_indices(self.list_window).len();
        self.ui_status
            .set_preview_counts(self.preview_counts(selected));
        self.render_status();
    }

    fn set_transient_status(&mut self, message: impl Into<String>) {
        self.ui_status.set_transient(message);
        self.render_status();
    }

    fn mark_preview_synchronized(&mut self) {
        self.preview_synchronization.mark_synchronized();
        self.ui_status.set_preview_sync_failed(false);
    }

    fn mark_preview_sync_failed(&mut self) {
        self.preview_synchronization.mark_failed();
        self.ui_status.set_preview_sync_failed(true);
    }

    fn persist_column_preferences(&mut self) {
        let result = self
            .preferences_writer
            .as_mut()
            .ok_or_else(|| io::Error::other("column preference writer is unavailable"))
            .and_then(|writer| writer.submit(self.column_states).map(|_| ()));
        if let Err(error) = result {
            self.set_transient_status(format!(
                "열 표시 설정을 저장하지 못했습니다. 현재 작업에는 영향이 없습니다: {error}"
            ));
        }
    }

    fn persist_appearance_preferences(&mut self) {
        let result = self
            .appearance_writer
            .as_mut()
            .ok_or_else(|| io::Error::other("appearance preference writer is unavailable"))
            .and_then(|writer| writer.submit(self.appearance).map(|_| ()));
        if let Err(error) = result {
            self.set_transient_status(format!(
                "모양 설정을 저장하지 못했습니다. 현재 작업에는 영향이 없습니다: {error}"
            ));
        }
    }

    fn set_progress_status(&mut self, message: impl Into<String>) {
        self.ui_status.set_progress(message);
        self.render_status();
    }

    fn set_recovery_status(&mut self, message: impl Into<String>) {
        self.ui_status.set_recovery(message);
        self.render_status();
    }

    fn clear_progress_status(&mut self) {
        self.ui_status.clear_progress();
        self.render_status();
    }

    fn clear_recovery_status(&mut self) {
        self.ui_status.clear_recovery();
        self.render_status();
    }
}

pub(crate) fn run() -> io::Result<()> {
    application::run()
}

pub(super) fn message(owner: HWND, text: &str, caption: &str) {
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

pub(crate) fn atomic_replace_preferences(source: &Path, destination: &Path) -> io::Result<()> {
    let source = source
        .as_os_str()
        .encode_wide()
        .chain(core::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(core::iter::once(0))
        .collect::<Vec<_>>();
    // SAFETY: both paths are owned, NUL-terminated UTF-16 buffers retained for
    // this synchronous call; the source is the exact same-directory temp file
    // created by this process and the destination is the settings leaf.
    if unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    } == 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EMPTY_SAFETY_COPY_PROBE_SUBCLASS_ID: usize = 0xD4B2;
    static EMPTY_SAFETY_COPY_CALLBACKS: AtomicUsize = AtomicUsize::new(0);
    static EMPTY_SAFETY_COPY_BRUSH: AtomicUsize = AtomicUsize::new(0);
    static EMPTY_SAFETY_COPY_TEXT: AtomicUsize = AtomicUsize::new(0);
    static EMPTY_SAFETY_COPY_BACKGROUND: AtomicUsize = AtomicUsize::new(0);
    const STATUS_RENDER_PROBE_SUBCLASS_ID: usize = 0xD4B3;
    static STATUS_RENDER_CALLBACKS: [AtomicUsize; 2] = [AtomicUsize::new(0), AtomicUsize::new(0)];
    static STATUS_RENDER_BRUSH: [AtomicUsize; 2] = [AtomicUsize::new(0), AtomicUsize::new(0)];
    static STATUS_RENDER_TEXT: [AtomicUsize; 2] = [AtomicUsize::new(0), AtomicUsize::new(0)];
    static STATUS_RENDER_BACKGROUND: [AtomicUsize; 2] = [AtomicUsize::new(0), AtomicUsize::new(0)];

    extern "system" fn empty_safety_copy_probe(
        window: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        subclass_id: usize,
        _ref_data: usize,
    ) -> LRESULT {
        // SAFETY: the callback forwards its original message through the
        // system subclass chain exactly once. The empty-safety branch uses the
        // live child/parent pair and releases the exact child DC synchronously.
        unsafe {
            if subclass_id == EMPTY_SAFETY_COPY_PROBE_SUBCLASS_ID
                && message == windows_sys::Win32::UI::WindowsAndMessaging::WM_SETTEXT
            {
                let owner = GetParent(window);
                let dc = GetDC(window);
                if !dc.is_null() {
                    let brush = application::window_proc(
                        owner,
                        WM_CTLCOLORSTATIC,
                        dc as WPARAM,
                        window as LPARAM,
                    );
                    EMPTY_SAFETY_COPY_CALLBACKS.fetch_add(1, Ordering::SeqCst);
                    EMPTY_SAFETY_COPY_BRUSH.store(brush as usize, Ordering::SeqCst);
                    EMPTY_SAFETY_COPY_TEXT.store(GetTextColor(dc) as usize, Ordering::SeqCst);
                    EMPTY_SAFETY_COPY_BACKGROUND.store(GetBkColor(dc) as usize, Ordering::SeqCst);
                    ReleaseDC(window, dc);
                }
            }
            DefSubclassProc(window, message, wparam, lparam)
        }
    }

    extern "system" fn status_render_probe(
        window: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        subclass_id: usize,
        _ref_data: usize,
    ) -> LRESULT {
        // SAFETY: the callback forwards its original message through the
        // system subclass chain exactly once. The status branch uses the live
        // child/parent pair and releases the exact child DC synchronously.
        unsafe {
            if subclass_id == STATUS_RENDER_PROBE_SUBCLASS_ID
                && message == windows_sys::Win32::UI::WindowsAndMessaging::WM_SETTEXT
            {
                let index = match GetDlgCtrlID(window) {
                    id if id == STATUS_MESSAGE_ID as i32 => Some(0),
                    id if id == STATUS_COUNT_ID as i32 => Some(1),
                    _ => None,
                };
                if let Some(index) = index {
                    let owner = GetParent(window);
                    let dc = GetDC(window);
                    if !dc.is_null() {
                        let brush = application::window_proc(
                            owner,
                            WM_CTLCOLORSTATIC,
                            dc as WPARAM,
                            window as LPARAM,
                        );
                        STATUS_RENDER_CALLBACKS[index].fetch_add(1, Ordering::SeqCst);
                        STATUS_RENDER_BRUSH[index].store(brush as usize, Ordering::SeqCst);
                        STATUS_RENDER_TEXT[index]
                            .store(GetTextColor(dc) as usize, Ordering::SeqCst);
                        STATUS_RENDER_BACKGROUND[index]
                            .store(GetBkColor(dc) as usize, Ordering::SeqCst);
                        ReleaseDC(window, dc);
                    }
                }
            }
            DefSubclassProc(window, message, wparam, lparam)
        }
    }

    #[test]
    fn proposal_mutation_errors_keep_failure_copy_actionable_and_path_free() {
        assert_eq!(
            proposal_mutation_error_korean(ProposalMutationError::NameBudgetExceeded {
                row: 7,
                requested_units: 256,
                maximum_units: 255,
            }),
            "변경 결과가 안전 한도를 초과했습니다. 목록은 변경되지 않았습니다. 입력 내용을 줄여 다시 시도하세요."
        );
        assert_eq!(
            proposal_mutation_error_korean(ProposalMutationError::AllocationFailed),
            "변경 결과를 준비할 메모리가 부족합니다. 목록은 변경되지 않았습니다. 다른 프로그램을 닫고 다시 시도하세요."
        );
    }

    struct CallbackDropProbe(Rc<Cell<usize>>);

    impl Drop for CallbackDropProbe {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }

    #[test]
    fn callback_state_rejects_nested_entry_and_defers_one_reclamation()
    -> Result<(), Box<dyn std::error::Error>> {
        let state_drops = Rc::new(Cell::new(0));
        let retirement_drops = Rc::new(Cell::new(0));
        let slot: *mut CallbackState<CallbackDropProbe, CallbackDropProbe> =
            CallbackState::into_raw(CallbackDropProbe(Rc::clone(&state_drops)));
        // SAFETY: the test owns the live, UI-thread-confined slot.
        let outer = unsafe { CallbackState::try_lease(slot) }
            .ok_or_else(|| io::Error::other("outer callback lease was rejected"))?;
        // SAFETY: installation touches only the sidecar disjoint from the
        // actively leased state value.
        unsafe {
            CallbackState::install_retirement(slot, CallbackDropProbe(Rc::clone(&retirement_drops)))
        }
        .map_err(|_retirement| io::Error::other("retirement sidecar was occupied"))?;

        // SAFETY: the slot remains live under `outer`; same-state nested entry
        // must inspect only the lease cell and reject value access.
        assert!(unsafe { CallbackState::try_lease(slot) }.is_none());
        // SAFETY: this models WM_NCDESTROY after publication has been cleared.
        let disposition = unsafe { CallbackState::request_reclaim(slot) };
        assert_eq!(disposition, ReclaimDisposition::Deferred);
        // SAFETY: reclaim-pending keeps the allocation live under `outer`; the
        // sidecar remains independently takeable without a state reference.
        let retirement = unsafe { CallbackState::take_retirement(slot) }
            .ok_or_else(|| io::Error::other("retirement sidecar was missing"))?;
        drop(retirement);
        // SAFETY: the first take cleared the live sidecar atomically on this UI thread.
        assert!(unsafe { CallbackState::take_retirement(slot) }.is_none());
        assert_eq!(retirement_drops.get(), 1);
        assert_eq!(state_drops.get(), 0);
        // A repeated defensive retirement while the slot is still lease-owned
        // cannot create a second reclamation path.
        // SAFETY: deferred reclamation keeps the slot live until `outer` drops.
        let disposition = unsafe { CallbackState::request_reclaim(slot) };
        assert_eq!(disposition, ReclaimDisposition::Deferred);
        assert_eq!(state_drops.get(), 0);

        drop(outer);
        assert_eq!(state_drops.get(), 1);
        assert_eq!(retirement_drops.get(), 1);
        Ok(())
    }

    #[test]
    fn callback_state_menu_edge_color_is_disjoint_from_a_value_lease()
    -> Result<(), Box<dyn std::error::Error>> {
        let slot = CallbackState::<u32>::into_raw(41);
        // SAFETY: the test solely owns this live UI-thread slot. Sidecar calls
        // touch only their scalar Cell while the sole value lease stays live;
        // publication ends before the final unique reclamation.
        let (before, initial, updated, cleared, nested_rejected, after, disposition) = unsafe {
            let lease = match CallbackState::try_lease(slot) {
                Some(lease) => lease,
                None => {
                    let disposition = CallbackState::request_reclaim(slot);
                    assert_eq!(disposition, ReclaimDisposition::Reclaimed);
                    return Err(io::Error::other("menu-edge sidecar lease was rejected").into());
                }
            };
            let before = *lease.state();
            let initial = CallbackState::menu_edge_color(slot);
            CallbackState::set_menu_edge_color(slot, Some(GRAPHITE_DARK.surface_window));
            let updated = CallbackState::menu_edge_color(slot);
            CallbackState::set_menu_edge_color(slot, None);
            let cleared = CallbackState::menu_edge_color(slot);
            let nested_rejected = CallbackState::try_lease(slot).is_none();
            let after = *lease.state();
            drop(lease);
            let disposition = CallbackState::request_reclaim(slot);
            (
                before,
                initial,
                updated,
                cleared,
                nested_rejected,
                after,
                disposition,
            )
        };

        assert_eq!(before, 41);
        assert_eq!(initial, None);
        assert_eq!(updated, Some(GRAPHITE_DARK.surface_window));
        assert_eq!(cleared, None);
        assert!(nested_rejected);
        assert_eq!(after, 41);
        assert_eq!(disposition, ReclaimDisposition::Reclaimed);
        Ok(())
    }

    #[test]
    fn close_decision_is_applied_only_after_callback_lease_ends()
    -> Result<(), Box<dyn std::error::Error>> {
        let slot: *mut CallbackState<bool> = CallbackState::into_raw(true);
        // SAFETY: the test owns the live, UI-thread-confined slot.
        let lease = unsafe { CallbackState::try_lease(slot) }
            .ok_or_else(|| io::Error::other("close-decision lease was rejected"))?;
        let close = *lease.state();
        let action_probe = run_after_callback_state_release(lease, || {
            // Applying the copied decision can reacquire the slot, proving that
            // no state lease/reference survives into the external action.
            // SAFETY: the helper ended the original lease and the slot is live.
            unsafe { CallbackState::try_lease(slot) }
                .ok_or_else(|| io::Error::other("close action ran before lease release"))
        })?;
        assert!(close);
        drop(action_probe);
        // SAFETY: no lease remains and the test is retiring its unique slot.
        let disposition = unsafe { CallbackState::request_reclaim(slot) };
        assert_eq!(disposition, ReclaimDisposition::Reclaimed);
        Ok(())
    }

    #[test]
    fn empty_safety_copy_releases_state_before_nested_static_color_callback()
    -> Result<(), Box<dyn std::error::Error>> {
        EMPTY_SAFETY_COPY_CALLBACKS.store(0, Ordering::SeqCst);
        EMPTY_SAFETY_COPY_BRUSH.store(0, Ordering::SeqCst);
        EMPTY_SAFETY_COPY_TEXT.store(0, Ordering::SeqCst);
        EMPTY_SAFETY_COPY_BACKGROUND.store(0, Ordering::SeqCst);

        let directory = tempfile::tempdir()?;
        let mut state = AppState::new(initialize_safe_runtime_at(directory.path())?);
        state.appearance_resources = Some(AppearanceResources::create(GRAPHITE_DARK)?);
        let class = wide("STATIC");
        // SAFETY: every HWND and state slot below is owned by this UI-thread
        // test. Publication is cleared and the subclass removed before the
        // owner destroys its child; the unpublished slot is then reclaimed.
        let (message_result, expected, text, disposition) = unsafe {
            let owner = CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                320,
                240,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            );
            if owner.is_null() {
                return Err(io::Error::last_os_error().into());
            }
            let safety = CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_CHILD | WS_VISIBLE,
                0,
                0,
                240,
                32,
                owner,
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            );
            if safety.is_null() {
                DestroyWindow(owner);
                return Err(io::Error::last_os_error().into());
            }
            if SetWindowSubclass(
                safety,
                Some(empty_safety_copy_probe),
                EMPTY_SAFETY_COPY_PROBE_SUBCLASS_ID,
                0,
            ) == 0
            {
                DestroyWindow(owner);
                return Err(io::Error::last_os_error().into());
            }

            state.empty_safety = safety;
            let expected = static_control_colors(&state, safety)
                .ok_or_else(|| io::Error::other("empty safety semantic colors are missing"))?;
            let state_slot: *mut AppStateSlot = CallbackState::into_raw(state);
            SetWindowLongPtrW(owner, GWLP_USERDATA, state_slot as isize);

            let message_result = application::window_proc(owner, WM_APP_EMPTY_SAFETY_COPY, 0, 0);
            let text = window_text(safety);

            RemoveWindowSubclass(
                safety,
                Some(empty_safety_copy_probe),
                EMPTY_SAFETY_COPY_PROBE_SUBCLASS_ID,
            );
            SetWindowLongPtrW(owner, GWLP_USERDATA, 0);
            DestroyWindow(owner);
            let disposition = CallbackState::request_reclaim(state_slot);
            (message_result, expected, text, disposition)
        };
        let text = text?;

        assert_eq!(message_result, 0);
        assert_eq!(EMPTY_SAFETY_COPY_CALLBACKS.load(Ordering::SeqCst), 1);
        assert_eq!(
            EMPTY_SAFETY_COPY_BRUSH.load(Ordering::SeqCst),
            expected.brush as usize
        );
        assert_eq!(
            EMPTY_SAFETY_COPY_TEXT.load(Ordering::SeqCst),
            expected.text as usize
        );
        assert_eq!(
            EMPTY_SAFETY_COPY_BACKGROUND.load(Ordering::SeqCst),
            expected.background as usize
        );
        assert_eq!(text, empty_state_safety_copy(RailMode::MenuOnly));
        assert_eq!(disposition, ReclaimDisposition::Reclaimed);
        Ok(())
    }

    #[test]
    fn status_render_timer_coalesces_and_survives_busy_callback()
    -> Result<(), Box<dyn std::error::Error>> {
        for index in 0..2 {
            STATUS_RENDER_CALLBACKS[index].store(0, Ordering::SeqCst);
            STATUS_RENDER_BRUSH[index].store(0, Ordering::SeqCst);
            STATUS_RENDER_TEXT[index].store(0, Ordering::SeqCst);
            STATUS_RENDER_BACKGROUND[index].store(0, Ordering::SeqCst);
        }

        let directory = tempfile::tempdir()?;
        let mut state = AppState::new(initialize_safe_runtime_at(directory.path())?);
        state.appearance_resources = Some(AppearanceResources::create(GRAPHITE_DARK)?);
        state.ui_status = UiStatus::with_transient("이전 상태 표시");
        // A missing child parent installs no timer and leaves no sticky state;
        // the same state can install one after controls become available.
        state.render_status();
        state.render_status();
        let class = wide("STATIC");
        // SAFETY: every HWND and state slot below is owned by this UI-thread
        // test. Publication is cleared and both subclasses are removed before
        // the owner destroys its children; the unpublished slot is reclaimed.
        let (
            synchronous_callbacks,
            first_timer_installed,
            duplicate_timer_absent,
            busy_handler_result,
            callbacks_while_busy,
            busy_timer_survived,
            handler_result,
            handler_timer_removed,
            expected,
            expected_text,
            actual_message_text,
            actual_count_text,
            disposition,
        ) = unsafe {
            let owner = CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                160,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            );
            if owner.is_null() {
                return Err(io::Error::last_os_error().into());
            }
            let (status_message, status_count, _cancel) = match create_status_controls(owner) {
                Ok(controls) => controls,
                Err(error) => {
                    DestroyWindow(owner);
                    return Err(error.into());
                }
            };
            for status in [status_message, status_count] {
                if SetWindowSubclass(
                    status,
                    Some(status_render_probe),
                    STATUS_RENDER_PROBE_SUBCLASS_ID,
                    0,
                ) == 0
                {
                    DestroyWindow(owner);
                    return Err(io::Error::last_os_error().into());
                }
            }

            state.status_message = status_message;
            state.status_count = status_count;
            let expected_message = match static_control_colors(&state, status_message) {
                Some(colors) => colors,
                None => {
                    DestroyWindow(owner);
                    return Err(
                        io::Error::other("message status semantic colors are missing").into(),
                    );
                }
            };
            let expected_count = match static_control_colors(&state, status_count) {
                Some(colors) => colors,
                None => {
                    DestroyWindow(owner);
                    return Err(io::Error::other("count status semantic colors are missing").into());
                }
            };
            let expected = [expected_message, expected_count];
            let expected_text = ["최신 상태 표시".to_owned(), state.ui_status.count_text()];
            let state_slot: *mut AppStateSlot = CallbackState::into_raw(state);
            SetWindowLongPtrW(owner, GWLP_USERDATA, state_slot as isize);

            let mut state_lease = match CallbackState::try_lease(state_slot) {
                Some(lease) => lease,
                None => {
                    SetWindowLongPtrW(owner, GWLP_USERDATA, 0);
                    DestroyWindow(owner);
                    let disposition = CallbackState::request_reclaim(state_slot);
                    assert_eq!(disposition, ReclaimDisposition::Reclaimed);
                    return Err(io::Error::other("status render state lease is unavailable").into());
                }
            };
            state_lease.state().render_status();
            state_lease
                .state_mut()
                .ui_status
                .set_transient("최신 상태 표시");
            state_lease.state().render_status();
            state_lease.state().render_status();
            let synchronous_callbacks = [
                STATUS_RENDER_CALLBACKS[0].load(Ordering::SeqCst),
                STATUS_RENDER_CALLBACKS[1].load(Ordering::SeqCst),
            ];
            drop(state_lease);

            // Reusing one HWND/ID replaces the timer. One kill succeeds and a
            // second cannot find a duplicate timer instance.
            let first_timer_installed = KillTimer(owner, STATUS_RENDER_TIMER_ID) != 0;
            let duplicate_timer_absent = KillTimer(owner, STATUS_RENDER_TIMER_ID) == 0;

            let busy_lease = match CallbackState::try_lease(state_slot) {
                Some(lease) => lease,
                None => {
                    SetWindowLongPtrW(owner, GWLP_USERDATA, 0);
                    DestroyWindow(owner);
                    let disposition = CallbackState::request_reclaim(state_slot);
                    assert_eq!(disposition, ReclaimDisposition::Reclaimed);
                    return Err(io::Error::other("busy status lease is unavailable").into());
                }
            };
            busy_lease.state().render_status();
            let busy_handler_result =
                application::window_proc(owner, WM_TIMER, STATUS_RENDER_TIMER_ID, 0);
            let callbacks_while_busy = [
                STATUS_RENDER_CALLBACKS[0].load(Ordering::SeqCst),
                STATUS_RENDER_CALLBACKS[1].load(Ordering::SeqCst),
            ];
            drop(busy_lease);
            let busy_timer_survived = KillTimer(owner, STATUS_RENDER_TIMER_ID) != 0;

            let retry_lease = match CallbackState::try_lease(state_slot) {
                Some(lease) => {
                    lease.state().render_status();
                    lease
                }
                None => {
                    SetWindowLongPtrW(owner, GWLP_USERDATA, 0);
                    DestroyWindow(owner);
                    let disposition = CallbackState::request_reclaim(state_slot);
                    assert_eq!(disposition, ReclaimDisposition::Reclaimed);
                    return Err(io::Error::other("retry status lease is unavailable").into());
                }
            };
            drop(retry_lease);
            let handler_result =
                application::window_proc(owner, WM_TIMER, STATUS_RENDER_TIMER_ID, 0);
            let handler_timer_removed = KillTimer(owner, STATUS_RENDER_TIMER_ID) == 0;
            let actual_message_text = window_text(status_message);
            let actual_count_text = window_text(status_count);

            for status in [status_message, status_count] {
                RemoveWindowSubclass(
                    status,
                    Some(status_render_probe),
                    STATUS_RENDER_PROBE_SUBCLASS_ID,
                );
            }
            SetWindowLongPtrW(owner, GWLP_USERDATA, 0);
            DestroyWindow(owner);
            let disposition = CallbackState::request_reclaim(state_slot);
            (
                synchronous_callbacks,
                first_timer_installed,
                duplicate_timer_absent,
                busy_handler_result,
                callbacks_while_busy,
                busy_timer_survived,
                handler_result,
                handler_timer_removed,
                expected,
                expected_text,
                actual_message_text,
                actual_count_text,
                disposition,
            )
        };

        let actual_text = [actual_message_text?, actual_count_text?];
        assert_eq!(
            synchronous_callbacks,
            [0, 0],
            "render_status must not synchronously enter a status control"
        );
        assert!(first_timer_installed);
        assert!(
            duplicate_timer_absent,
            "repeated renders must share one timer"
        );
        assert_eq!(busy_handler_result, 0);
        assert_eq!(callbacks_while_busy, [0, 0]);
        assert!(
            busy_timer_survived,
            "busy WM_TIMER handling must leave the retry timer installed"
        );
        assert_eq!(handler_result, 0);
        assert!(
            handler_timer_removed,
            "successful status rendering must stop the timer"
        );
        for index in 0..2 {
            assert_eq!(STATUS_RENDER_CALLBACKS[index].load(Ordering::SeqCst), 1);
            assert_eq!(
                STATUS_RENDER_BRUSH[index].load(Ordering::SeqCst),
                expected[index].brush as usize
            );
            assert_eq!(
                STATUS_RENDER_TEXT[index].load(Ordering::SeqCst),
                expected[index].text as usize
            );
            assert_eq!(
                STATUS_RENDER_BACKGROUND[index].load(Ordering::SeqCst),
                expected[index].background as usize
            );
        }
        assert_eq!(actual_text, expected_text);
        assert_eq!(disposition, ReclaimDisposition::Reclaimed);
        Ok(())
    }

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

        let mut before_startup = fs::read_dir(&data)?
            .map(|entry| {
                let entry = entry?;
                Ok((entry.file_name(), fs::read(entry.path())?))
            })
            .collect::<io::Result<Vec<_>>>()?;
        before_startup.sort_by(|left, right| left.0.cmp(&right.0));
        let runtime = initialize_safe_runtime_at(directory.path())?;
        if expect_staged_lock {
            assert!(runtime.recovery_locked);
            assert!(runtime.staged_journal.is_some());
        } else {
            assert!(runtime.recovery_locked);
            assert!(runtime.active_journal.is_some());
        }
        let mut after_startup = fs::read_dir(&data)?
            .map(|entry| {
                let entry = entry?;
                Ok((entry.file_name(), fs::read(entry.path())?))
            })
            .collect::<io::Result<Vec<_>>>()?;
        after_startup.sort_by(|left, right| left.0.cmp(&right.0));
        assert_eq!(
            before_startup, after_startup,
            "startup discovery mutated files before explicit recovery confirmation"
        );

        let mut state = AppState::new(runtime);
        if expect_staged_lock {
            assert!(!state.can_confirm_active_recovery());
        } else {
            assert!(state.can_confirm_active_recovery());
            recover_confirmed_active_journal(&mut state);
            assert!(state.active_journal.is_none());
        }
        drop(state);

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
    fn terminal_active_journal_with_torn_payload_stays_locked_retained_and_undeleted()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let journal_directory = create_startup_journal_directory(directory.path())?;
        let active = journal_directory.join(ACTIVE_JOURNAL_LEAF);
        let mut bytes = crate::rename::encode_journal_records(&[
            crate::rename::JournalRecord::Intent {
                plan: crate::rename::PlanId::from_fingerprint(78),
                steps: Vec::new().into_boxed_slice(),
            },
            crate::rename::JournalRecord::Terminal(crate::rename::JournalTerminal::Committed),
            crate::rename::JournalRecord::Prepared {
                step: 0,
                direction: crate::rename::JournalDirection::Forward,
            },
        ])?;
        bytes
            .pop()
            .ok_or_else(|| io::Error::other("startup torn-payload fixture was empty"))?;
        fs::write(&active, &bytes)?;

        let runtime = initialize_safe_runtime_at(directory.path())?;

        assert!(runtime.recovery_locked);
        let retained = runtime
            .active_journal
            .as_ref()
            .ok_or_else(|| io::Error::other("torn terminal journal was not retained"))?;
        assert_eq!(
            retained.tail_issue(),
            Some(crate::rename::JournalTailIssue::TruncatedPayload)
        );
        assert!(
            runtime
                .status
                .as_deref()
                .unwrap_or_default()
                .contains("명시적인 복구 확인이 필요")
        );
        let mut state = AppState::new(runtime);
        assert!(state.can_confirm_active_recovery());
        let presentation = recover_confirmed_active_journal(&mut state);
        assert!(!presentation.completed);
        assert!(
            presentation
                .status
                .contains("저널 삭제 실패: file journal error: UnsafeCleanupState")
        );
        assert!(state.recovery_locked);
        assert!(state.active_journal.is_some());
        drop(state);
        assert_eq!(fs::read(active)?, bytes);
        Ok(())
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
    fn app_state_loads_appearance_independently_from_columns()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let runtime = initialize_safe_runtime_at(directory.path())?;
        let path = appearance_path_for_journal_root(runtime.root.path());
        let appearance = UiAppearance {
            theme: AppThemeMode::Light,
            density: RailDensityPreference::Compact,
            emphasis: PreviewEmphasis::Subtle,
            show_separators: false,
            show_preview_tint: false,
            show_empty_safety: true,
        };
        crate::preferences::save_appearance(&path, appearance)?;

        let state = AppState::new(runtime);

        assert_eq!(state.appearance, appearance);
        assert_eq!(state.column_states, default_column_states());
        assert_eq!(state.appearance_preferences_path, path);
        Ok(())
    }

    #[test]
    fn changed_subitem_custom_draw_commits_and_contains_semantic_colors()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let mut state = AppState::new(initialize_safe_runtime_at(directory.path())?);
        state.appearance.theme = AppThemeMode::Light;
        state.forced_colors = ForcedColorsState::Inactive;
        assert_eq!(
            state
                .model
                .append(LegacyListItem::new(r"C:\work\photo01.jpg", false, 4, 0, 0,)),
            Ok(true)
        );
        assert_eq!(state.model.clear_name_changed().as_ref(), &[0]);

        let mut custom = NMLVCUSTOMDRAW::default();
        custom.nmcd.hdr.hwndFrom = state.list_window;
        custom.nmcd.hdr.code = NM_CUSTOMDRAW;
        custom.nmcd.dwDrawStage = CDDS_ITEMPREPAINT | CDDS_SUBITEM;
        custom.nmcd.dwItemSpec = 0;
        // LVS_SHOWSELALWAYS custom draw can report stale CDIS flags. The live
        // ListView item state is authoritative and this null test HWND reports
        // no LVIS selection or focus.
        custom.nmcd.uItemState = CDIS_SELECTED | CDIS_FOCUS;
        custom.iSubItem = 1;

        let result =
            handle_list_custom_draw(&state, (&raw mut custom as *mut NMLVCUSTOMDRAW) as LPARAM);
        let palette = semantic_palette(ResolvedTheme::Light)
            .ok_or_else(|| io::Error::other("Light semantic palette is missing"))?;
        assert_eq!(result, Some(CDRF_NEWFONT as LRESULT));
        assert_eq!(custom.clrText, palette.changed_standard);
        assert_eq!(custom.clrTextBk, palette.preview_tint);

        custom.iSubItem = 2;
        let result =
            handle_list_custom_draw(&state, (&raw mut custom as *mut NMLVCUSTOMDRAW) as LPARAM);
        assert_eq!(result, Some(CDRF_NEWFONT as LRESULT));
        assert_eq!(custom.clrText, palette.text_primary);
        assert_eq!(custom.clrTextBk, palette.surface_workspace);
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
    fn recovery_lock_allows_diagnostics_appearance_about_and_exit() {
        assert!(recovery_command_allowed(EXPORT_RECOVERY_JOURNAL));
        assert!(recovery_command_allowed(DISCARD_STAGED_JOURNAL));
        assert!(recovery_command_allowed(SHOW_RECOVERY_STATUS));
        assert!(recovery_command_allowed(VERSION));
        assert!(recovery_command_allowed(2));
        for command in [THEME_SYSTEM, THEME_LIGHT, THEME_DARK, APPEARANCE_ADVANCED] {
            assert!(recovery_command_allowed(command));
        }
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

        let mut status = original.clone();
        status.values[NATIVE_STATUS_COLUMN_INDEX] = LegacyText::from("차단: 충돌");
        assert_eq!(
            changed_column_mask(&original, &status),
            1 << NATIVE_STATUS_COLUMN_INDEX
        );

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
    fn native_modal_guard_restores_the_owner_enabled_state() -> io::Result<()> {
        let class = wide("STATIC");
        // SAFETY: the system STATIC class and null optional handles remain valid for this hidden owner.
        let owner = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                320,
                240,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if owner.is_null() {
            return Err(io::Error::last_os_error());
        }

        // SAFETY: owner is the live hidden test HWND.
        assert_ne!(unsafe { IsWindowEnabled(owner) }, 0);
        let disabled_during_modal = modal_native_dialog(owner, || {
            // SAFETY: owner remains live throughout this synchronous closure.
            unsafe { IsWindowEnabled(owner) == 0 }
        });
        assert!(disabled_during_modal);
        // SAFETY: owner remains live after the synchronous guard drops.
        assert_ne!(unsafe { IsWindowEnabled(owner) }, 0);

        // SAFETY: owner is live and remains intentionally disabled after the second guard drops.
        unsafe { EnableWindow(owner, 0) };
        let remained_disabled = modal_native_dialog(owner, || {
            // SAFETY: owner remains live throughout this synchronous closure.
            unsafe { IsWindowEnabled(owner) == 0 }
        });
        assert!(remained_disabled);
        // SAFETY: owner remains live and intentionally disabled.
        assert_eq!(unsafe { IsWindowEnabled(owner) }, 0);
        // SAFETY: owner is the hidden test HWND created above and is destroyed once.
        unsafe { DestroyWindow(owner) };
        Ok(())
    }

    #[test]
    fn native_command_rails_create_every_visible_button_with_expected_layout()
    -> Result<(), Box<dyn std::error::Error>> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_WIN95_CLASSES,
        };
        // SAFETY: controls has its exact structure size and remains readable for
        // the synchronous common-controls initialization call.
        unsafe { InitCommonControlsEx(&controls) };
        // SAFETY: null requests the current process module.
        let instance = unsafe { GetModuleHandleW(null()) };
        for dpi in [96, 120, 144, 192] {
            verify_native_command_rails_at_dpi(instance, dpi)?;
        }
        Ok(())
    }

    #[test]
    fn native_owner_draw_rail_button_bm_click_sends_one_command_notification()
    -> Result<(), Box<dyn std::error::Error>> {
        static COMMAND_COUNT: AtomicUsize = AtomicUsize::new(0);
        static COMMAND_WPARAM: AtomicUsize = AtomicUsize::new(0);
        static COMMAND_SOURCE: AtomicUsize = AtomicUsize::new(0);

        unsafe extern "system" fn command_probe(
            window: HWND,
            message: u32,
            wparam: WPARAM,
            lparam: LPARAM,
            _subclass_id: usize,
            _ref_data: usize,
        ) -> LRESULT {
            if message == WM_COMMAND {
                COMMAND_COUNT.fetch_add(1, Ordering::SeqCst);
                COMMAND_WPARAM.store(wparam, Ordering::SeqCst);
                COMMAND_SOURCE.store(lparam as usize, Ordering::SeqCst);
            }
            // SAFETY: the original message and scalar parameters are forwarded
            // unchanged through the system subclass chain exactly once.
            unsafe { DefSubclassProc(window, message, wparam, lparam) }
        }

        COMMAND_COUNT.store(0, Ordering::SeqCst);
        COMMAND_WPARAM.store(0, Ordering::SeqCst);
        COMMAND_SOURCE.store(0, Ordering::SeqCst);
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_WIN95_CLASSES,
        };
        // SAFETY: controls has its exact structure size for initialization.
        unsafe { InitCommonControlsEx(&controls) };
        // SAFETY: the system STATIC class and current module are process-global.
        let parent = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: parent is a live UI-thread test window and the callback uses
        // the documented SUBCLASSPROC ABI without retaining borrowed storage.
        if unsafe { SetWindowSubclass(parent, Some(command_probe), 0xD4B1, 0) } == 0 {
            // SAFETY: parent is the test-owned hidden HWND.
            unsafe { DestroyWindow(parent) };
            return Err(io::Error::last_os_error().into());
        }
        let rail = match CommandRail::create(parent, &LEFT_RAIL) {
            Ok(rail) => rail,
            Err(error) => {
                // SAFETY: removes the exact callback and ID installed above.
                unsafe { RemoveWindowSubclass(parent, Some(command_probe), 0xD4B1) };
                // SAFETY: parent is the test-owned hidden HWND.
                unsafe { DestroyWindow(parent) };
                return Err(error.into());
            }
        };
        let button = rail
            .command_hwnd(APPLY)
            .ok_or_else(|| io::Error::other("Apply rail button is missing"))?;

        let placements = calculate_command_rail_layout(
            &LEFT_RAIL,
            800,
            RailDensity::Comfortable.metrics(BASE_DPI),
        )
        .map_err(|error| io::Error::other(format!("rail layout failed: {error:?}")))?;
        rail.arrange(0, &placements, BASE_DPI);
        // SAFETY: parent/button are live test-owned windows. Giving the standard
        // button focus before BM_CLICK matches its documented interactive path;
        // the counters are reset afterward so BN_SETFOCUS is not mistaken for
        // the click notification under test.
        unsafe {
            ShowWindow(parent, SW_SHOW);
            UpdateWindow(parent);
            SetFocus(button);
        }
        COMMAND_COUNT.store(0, Ordering::SeqCst);
        COMMAND_WPARAM.store(0, Ordering::SeqCst);
        COMMAND_SOURCE.store(0, Ordering::SeqCst);

        // SAFETY: button is the live standard owner-draw BUTTON created by the
        // production rail and BM_CLICK synchronously follows native semantics.
        unsafe { SendMessageW(button, BM_CLICK, 0, 0) };

        assert_eq!(COMMAND_COUNT.load(Ordering::SeqCst), 1);
        let notification = COMMAND_WPARAM.load(Ordering::SeqCst);
        assert_eq!(notification & 0xFFFF, usize::from(APPLY));
        assert_eq!((notification >> 16) & 0xFFFF, BN_CLICKED as usize);
        assert_eq!(COMMAND_SOURCE.load(Ordering::SeqCst), button as usize);
        rail.destroy();
        // SAFETY: removes the exact callback and ID installed above.
        unsafe { RemoveWindowSubclass(parent, Some(command_probe), 0xD4B1) };
        // SAFETY: parent is the test-owned hidden HWND and is destroyed once.
        unsafe { DestroyWindow(parent) };
        Ok(())
    }

    #[test]
    fn native_apply_readiness_targets_the_existing_button_and_menu_only_hides_it()
    -> Result<(), Box<dyn std::error::Error>> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_WIN95_CLASSES,
        };
        // SAFETY: controls has its exact size for synchronous initialization.
        unsafe { InitCommonControlsEx(&controls) };
        // SAFETY: null requests the current process module.
        let instance = unsafe { GetModuleHandleW(null()) };
        let class = wide("STATIC");
        // SAFETY: the system class and current module remain valid during this
        // hidden test-window creation.
        let parent = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                instance,
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let rail = match CommandRail::create(parent, &LEFT_RAIL) {
            Ok(rail) => rail,
            Err(error) => {
                // SAFETY: parent is the hidden test window created above.
                unsafe { DestroyWindow(parent) };
                return Err(error.into());
            }
        };
        let apply = rail
            .command_hwnd(APPLY)
            .ok_or_else(|| io::Error::other("Apply button is missing"))?;
        assert_eq!(rail.active_apply_readiness_button(), None);
        rail.set_apply_readiness_visible(true);
        assert_eq!(rail.active_apply_readiness_button(), Some(apply));
        rail.set_visible(false);
        assert_eq!(rail.active_apply_readiness_button(), None);
        rail.set_visible(true);
        assert_eq!(rail.active_apply_readiness_button(), Some(apply));
        rail.set_apply_readiness_visible(false);
        assert_eq!(rail.active_apply_readiness_button(), None);

        let mut child_count = 0;
        // SAFETY: parent is live; GetWindow walks its direct-child Z-order
        // without retaining any handle beyond this synchronous count.
        let mut child = unsafe { GetWindow(parent, GW_CHILD) };
        while !child.is_null() {
            child_count += 1;
            // SAFETY: child remains live and GW_HWNDNEXT advances the same
            // direct-child chain.
            child = unsafe { GetWindow(child, GW_HWNDNEXT) };
        }
        assert_eq!(
            child_count,
            rail.button_count() + rail.separator_windows().len()
        );
        rail.destroy();
        // SAFETY: parent remains the test-owned hidden HWND.
        unsafe { DestroyWindow(parent) };
        Ok(())
    }

    #[test]
    fn owner_draw_apply_readiness_uses_custom_palette_without_replacing_focus_or_default()
    -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: the system STATIC class and current module are process-global.
        let parent = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let rail = match CommandRail::create(parent, &LEFT_RAIL) {
            Ok(rail) => rail,
            Err(error) => {
                // SAFETY: parent is the test-owned hidden HWND.
                unsafe { DestroyWindow(parent) };
                return Err(error.into());
            }
        };
        let result = (|| -> io::Result<()> {
            let dpi = BASE_DPI;
            let placements = calculate_command_rail_layout(
                &LEFT_RAIL,
                800,
                RailDensity::Comfortable.metrics(dpi),
            )
            .map_err(|error| io::Error::other(format!("rail layout failed: {error:?}")))?;
            rail.arrange(0, &placements, dpi);
            let apply = rail
                .command_hwnd(APPLY)
                .ok_or_else(|| io::Error::other("Apply button is missing"))?;
            // SAFETY: apply is live; its DC and writable client rectangle are
            // used only for synchronous owner drawing below.
            let (dc, rect) = unsafe {
                let dc = GetDC(apply);
                let mut rect = RECT::default();
                GetClientRect(apply, &mut rect);
                (dc, rect)
            };
            if dc.is_null() {
                return Err(io::Error::last_os_error());
            }
            let paint_result = (|| -> io::Result<()> {
                let indicator = calculate_apply_readiness_indicator_rect(
                    LayoutRect {
                        x: rect.left,
                        y: rect.top,
                        width: rect.right.saturating_sub(rect.left),
                        height: rect.bottom.saturating_sub(rect.top),
                    },
                    dpi,
                )
                .ok_or_else(|| io::Error::other("Apply readiness indicator is missing"))?;
                let sample_x = indicator.x.saturating_add(indicator.width / 2);
                let sample_y = indicator.y.saturating_add(indicator.height / 2);
                let resources = AppearanceResources::create(GRAPHITE_DARK)?;
                let mut draw = DRAWITEMSTRUCT {
                    CtlType: ODT_BUTTON,
                    itemState: ODS_DEFAULT | ODS_FOCUS,
                    hwndItem: apply,
                    hDC: dc,
                    rcItem: rect,
                    ..DRAWITEMSTRUCT::default()
                };
                assert!(draw_owner_rail_button(
                    Some(&resources),
                    Some(apply),
                    dpi,
                    (&raw mut draw) as LPARAM,
                ));
                // SAFETY: dc is live and the sampled point is strictly inside
                // the pure indicator after focus/default rendering.
                let indicator_pixel = unsafe { GetPixel(dc, sample_x, sample_y) };
                assert_eq!(indicator_pixel, GRAPHITE_DARK.apply_keyline);

                assert!(draw_owner_rail_button(
                    Some(&resources),
                    None,
                    dpi,
                    (&raw mut draw) as LPARAM,
                ));
                // SAFETY: the same bounded point now contains the normal custom
                // button surface because no readiness target was supplied.
                let untargeted_pixel = unsafe { GetPixel(dc, sample_x, sample_y) };
                assert_ne!(untargeted_pixel, GRAPHITE_DARK.apply_keyline);

                assert!(draw_owner_rail_button(
                    None,
                    Some(apply),
                    dpi,
                    (&raw mut draw) as LPARAM,
                ));
                // SAFETY: resources=None follows system/Forced Colors painting
                // and deliberately draws no custom palette indicator.
                let system_pixel = unsafe { GetPixel(dc, sample_x, sample_y) };
                assert_ne!(system_pixel, GRAPHITE_DARK.apply_keyline);
                Ok(())
            })();
            // SAFETY: dc came from this exact live Apply button.
            unsafe { ReleaseDC(apply, dc) };
            paint_result
        })();
        rail.destroy();
        // SAFETY: parent is the test-owned hidden HWND after rail teardown.
        unsafe { DestroyWindow(parent) };
        result.map_err(Into::into)
    }

    #[test]
    fn native_status_controls_use_ellipsized_statics_and_accessible_cancel_button()
    -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: null requests the current process module.
        let instance = unsafe { GetModuleHandleW(null()) };
        let class = wide("STATIC");
        // SAFETY: the system STATIC class and current module remain valid for
        // this hidden top-level test window.
        let parent = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                instance,
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let result = (|| -> io::Result<()> {
            let (status_message, status_count, cancel) = create_status_controls(parent)?;
            for status in [status_message, status_count] {
                // SAFETY: status is a live native STATIC and GWL_STYLE is a
                // pointer-free value query.
                let style = unsafe { GetWindowLongPtrW(status, GWL_STYLE) } as u32;
                assert_eq!(style & SS_NOPREFIX, SS_NOPREFIX);
                assert_eq!(style & SS_ENDELLIPSIS, SS_ENDELLIPSIS);
                assert_eq!(style & SS_SUNKEN, 0);
            }
            // SAFETY: cancel is a live standard BUTTON and GWL_STYLE is a
            // pointer-free value query.
            let cancel_style = unsafe { GetWindowLongPtrW(cancel, GWL_STYLE) } as u32;
            assert_ne!(cancel_style & WS_TABSTOP, 0);
            assert_eq!(cancel_style & WS_VISIBLE, 0);
            assert_eq!(window_text(cancel)?, STATUS_CANCEL_LABEL);
            // SAFETY: cancel remains live and the enabled query has no pointers.
            assert_eq!(unsafe { IsWindowEnabled(cancel) }, 0);
            Ok(())
        })();
        // SAFETY: parent is the hidden test HWND and destroys all child controls.
        unsafe { DestroyWindow(parent) };
        result.map_err(Into::into)
    }

    #[test]
    fn owner_draw_menu_preserves_alt_mnemonics() -> Result<(), Box<dyn std::error::Error>> {
        let menu = create_menu()?;

        for (position, mnemonic) in ['f', 'e', 'v', 't', 'r', 'h'].into_iter().enumerate() {
            let result = handle_owner_menu_char(mnemonic as WPARAM, menu.as_raw() as LPARAM);
            assert_eq!(result & 0xFFFF, position as LRESULT);
            assert_eq!((result >> 16) & 0xFFFF, MNC_EXECUTE as LRESULT);
        }
        Ok(())
    }

    #[test]
    fn owner_draw_top_level_menu_fits_the_parity_width_at_two_hundred_percent()
    -> Result<(), Box<dyn std::error::Error>> {
        const DPI: u32 = 192;
        let class = wide("STATIC");
        // SAFETY: the system class/current module remain live for this hidden
        // measurement owner.
        let owner = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                scale_dip(INITIAL_WIDTH, DPI),
                scale_dip(INITIAL_HEIGHT, DPI),
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if owner.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let menu = create_menu()?;
        let mut font = OwnedFont::default();
        let message_font = create_message_font(DPI);
        if message_font.is_null() {
            // SAFETY: owner is the test-owned hidden HWND.
            unsafe { DestroyWindow(owner) };
            return Err(io::Error::last_os_error().into());
        }
        font.replace(message_font);
        let mut total_width = 0_u32;
        for position in 0..6_u32 {
            let mut info = MENUITEMINFOW {
                cbSize: size_of::<MENUITEMINFOW>() as u32,
                fMask: MIIM_DATA,
                ..MENUITEMINFOW::default()
            };
            // SAFETY: menu is live, position is one of its six root items, and
            // info remains writable for the synchronous query.
            if unsafe { GetMenuItemInfoW(menu.as_raw(), position, 1, &mut info) } == 0 {
                // SAFETY: owner is the test-owned hidden HWND.
                unsafe { DestroyWindow(owner) };
                return Err(io::Error::last_os_error().into());
            }
            let mut measure = MEASUREITEMSTRUCT {
                CtlType: ODT_MENU,
                itemData: info.dwItemData,
                ..MEASUREITEMSTRUCT::default()
            };
            assert!(measure_owner_menu(
                owner,
                font.as_raw(),
                DPI,
                (&raw mut measure) as LPARAM,
            ));
            total_width = total_width.saturating_add(measure.itemWidth);
        }
        // SAFETY: owner is the test-owned hidden HWND.
        unsafe { DestroyWindow(owner) };
        let menu_budget = scale_dip(INITIAL_WIDTH.saturating_sub(80), DPI);
        assert!(
            total_width <= u32::try_from(menu_budget).unwrap_or(u32::MAX),
            "top-level menu measured {total_width}px for a {menu_budget}px content budget",
        );
        Ok(())
    }

    #[test]
    fn native_list_view_clips_siblings_and_is_placed_at_the_sibling_bottom()
    -> Result<(), Box<dyn std::error::Error>> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_LISTVIEW_CLASSES | ICC_WIN95_CLASSES,
        };
        // SAFETY: controls has its exact structure size and remains readable for
        // the synchronous common-controls initialization call.
        unsafe { InitCommonControlsEx(&controls) };
        let directory = tempfile::tempdir()?;
        let state = AppState::new(initialize_safe_runtime_at(directory.path())?);
        let class = wide("STATIC");
        // SAFETY: the system STATIC class and current module remain valid for
        // this hidden test owner.
        let parent = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let state_slot: *mut AppStateSlot = CallbackState::into_raw(state);
        // SAFETY: the hidden owner and UI-thread slot remain live until cleanup
        // clears publication and reclaims the slot below.
        unsafe { SetWindowLongPtrW(parent, GWLP_USERDATA, state_slot as isize) };
        let result = (|| -> io::Result<(u32, bool, bool)> {
            // SAFETY: the test owns the published slot and no callback lease is active.
            let mut state_lease = unsafe { CallbackState::try_lease(state_slot) }
                .ok_or_else(|| io::Error::other("test AppState lease is unavailable"))?;
            create_children(parent, state_lease.state_mut())?;
            let list_window = state_lease.state().list_window;
            // SAFETY: list_window is a live native control and the style query
            // retains no caller storage.
            let style = unsafe { GetWindowLongPtrW(list_window, GWL_STYLE) } as u32;
            drop(state_lease);

            // Put the ListView at the top first so creation order cannot make
            // the production z-order repair pass accidentally.
            // SAFETY: list_window is a live direct child and the flags alter
            // only sibling z-order without moving, resizing, or activating it.
            if unsafe {
                SetWindowPos(
                    list_window,
                    HWND_TOP,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                )
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: list_window is live and this non-owning query returns the
            // current bottom sibling without retaining state.
            let was_bottom = unsafe { GetWindow(list_window, GW_HWNDLAST) } == list_window;
            place_list_view_below_siblings(list_window)?;
            // SAFETY: same live-child z-order query after the repair.
            let is_bottom = unsafe { GetWindow(list_window, GW_HWNDLAST) } == list_window;
            Ok((style, was_bottom, is_bottom))
        })();
        // SAFETY: publication is cleared before parent teardown so child
        // callbacks cannot reach AppState during destruction.
        unsafe {
            SetWindowLongPtrW(parent, GWLP_USERDATA, 0);
            DestroyWindow(parent);
        }
        // SAFETY: no lease remains and publication has been cleared.
        let disposition = unsafe { CallbackState::request_reclaim(state_slot) };
        assert_eq!(disposition, ReclaimDisposition::Reclaimed);
        let (style, was_bottom, is_bottom) = result?;
        assert_ne!(style & WS_CLIPSIBLINGS, 0);
        assert_eq!(style & WS_BORDER, 0);
        assert!(
            !was_bottom,
            "test precondition must put the ListView above a sibling"
        );
        assert!(
            is_bottom,
            "ListView must remain behind every direct sibling"
        );
        Ok(())
    }

    #[test]
    fn empty_native_list_cancels_marquee_but_one_native_item_allows_it()
    -> Result<(), Box<dyn std::error::Error>> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_LISTVIEW_CLASSES | ICC_WIN95_CLASSES,
        };
        // SAFETY: controls has its exact structure size and remains readable for
        // the synchronous common-controls initialization call.
        unsafe { InitCommonControlsEx(&controls) };
        let class = wide("STATIC");
        // SAFETY: the system STATIC class and current module remain valid for
        // this hidden test owner.
        let parent = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let list_window = match child(parent, "SysListView32", "", LIST_ID as u16, LVS_REPORT) {
            Ok(list_window) => list_window,
            Err(error) => {
                // SAFETY: parent is the test-owned hidden HWND.
                unsafe { DestroyWindow(parent) };
                return Err(error.into());
            }
        };
        let mut notification = NMHDR {
            hwndFrom: list_window,
            idFrom: LIST_ID,
            code: LVN_MARQUEEBEGIN,
        };
        let mut row_text = wide("row");
        let mut row = LVITEMW {
            mask: LVIF_TEXT,
            iItem: 0,
            pszText: row_text.as_mut_ptr(),
            ..LVITEMW::default()
        };
        // SAFETY: list_window and both callback payloads stay live throughout
        // these synchronous messages; the inserted text buffer is writable and
        // terminated for the complete insertion call.
        let (empty_result, inserted, one_item_result, other_source_result) = unsafe {
            let empty_result = application::handle_list_marquee_begin(
                list_window,
                (&raw mut notification) as LPARAM,
            );
            let inserted = SendMessageW(list_window, LVM_INSERTITEMW, 0, (&raw mut row) as LPARAM);
            let one_item_result = application::handle_list_marquee_begin(
                list_window,
                (&raw mut notification) as LPARAM,
            );
            notification.hwndFrom = parent;
            let other_source_result = application::handle_list_marquee_begin(
                list_window,
                (&raw mut notification) as LPARAM,
            );
            (empty_result, inserted, one_item_result, other_source_result)
        };

        // SAFETY: parent is the test-owned hidden HWND and destroys its ListView.
        unsafe { DestroyWindow(parent) };
        assert_eq!(inserted, 0, "native fixture must contain exactly one item");
        assert_eq!(
            empty_result,
            Some(1),
            "empty ListView must reject marquee selection"
        );
        assert_eq!(
            one_item_result,
            Some(0),
            "nonempty ListView must retain marquee selection"
        );
        assert_eq!(
            other_source_result, None,
            "unrelated senders must not be intercepted"
        );
        Ok(())
    }

    #[test]
    fn list_view_routes_header_custom_draw_at_its_actual_notification_parent()
    -> Result<(), Box<dyn std::error::Error>> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_LISTVIEW_CLASSES | ICC_WIN95_CLASSES,
        };
        // SAFETY: controls has its exact structure size and remains readable for
        // the synchronous common-controls initialization call.
        unsafe { InitCommonControlsEx(&controls) };
        let directory = tempfile::tempdir()?;
        let state = AppState::new(initialize_safe_runtime_at(directory.path())?);
        let class = wide("STATIC");
        // SAFETY: the system STATIC class and current module remain valid for
        // this hidden test owner.
        let parent = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let state_slot: *mut AppStateSlot = CallbackState::into_raw(state);
        // SAFETY: the hidden owner and UI-thread slot remain live until the
        // paired cleanup below clears publication and reclaims the slot.
        unsafe { SetWindowLongPtrW(parent, GWLP_USERDATA, state_slot as isize) };
        let result = (|| -> io::Result<()> {
            // SAFETY: the test owns the published slot and no callback lease is active.
            let mut state_lease = unsafe { CallbackState::try_lease(state_slot) }
                .ok_or_else(|| io::Error::other("test AppState lease is unavailable"))?;
            let state = state_lease.state_mut();
            state.appearance.theme = AppThemeMode::Dark;
            state.forced_colors = ForcedColorsState::Inactive;
            state.system_theme = Some(ResolvedTheme::Dark);
            create_children(parent, state)?;
            let list_window = state.list_window;
            drop(state_lease);
            // SAFETY: the live report ListView owns one header child and returns
            // its borrowed HWND without retaining caller memory.
            let header = unsafe { SendMessageW(list_window, LVM_GETHEADER, 0, 0) } as HWND;
            if header.is_null() {
                return Err(io::Error::other("native ListView header is missing"));
            }
            // SAFETY: the live header owns a drawable client DC released below.
            let dc = unsafe { GetDC(header) };
            if dc.is_null() {
                return Err(io::Error::last_os_error());
            }
            let mut custom = NMCUSTOMDRAW::default();
            custom.hdr.hwndFrom = header;
            custom.hdr.code = NM_CUSTOMDRAW;
            custom.dwDrawStage = CDDS_PREPAINT;
            custom.hdc = dc;
            // SAFETY: list_window is the header's actual notification parent and
            // custom remains writable for the complete synchronous dispatch.
            let routed =
                unsafe { SendMessageW(list_window, WM_NOTIFY, 0, (&raw mut custom) as LPARAM) };
            assert_eq!(
                routed,
                (CDRF_NOTIFYITEMDRAW | CDRF_NOTIFYPOSTPAINT) as LRESULT
            );
            let guarded = {
                let _list_update = ProgrammaticListUpdateGuard::begin();
                // SAFETY: same live notification parent/payload. The guard must
                // delegate instead of constructing a shared AppState reference
                // during a synchronous programmatic update.
                unsafe { SendMessageW(list_window, WM_NOTIFY, 0, (&raw mut custom) as LPARAM) }
            };
            assert_eq!(guarded, 0);
            custom.dwDrawStage = CDDS_POSTPAINT;
            // SAFETY: same live notification parent and header DC for the
            // postpaint gutter pass.
            let postpaint =
                unsafe { SendMessageW(list_window, WM_NOTIFY, 0, (&raw mut custom) as LPARAM) };
            assert_eq!(postpaint, CDRF_DODEFAULT as LRESULT);
            // SAFETY: release the exact DC acquired from header above after all
            // synchronous paint-stage probes have completed.
            unsafe { ReleaseDC(header, dc) };
            Ok(())
        })();
        // SAFETY: publication is cleared before the hidden owner and its child
        // subclass are destroyed, preventing callbacks from reaching stale state.
        unsafe { SetWindowLongPtrW(parent, GWLP_USERDATA, 0) };
        // SAFETY: parent is the test-owned top-level HWND and destroys every
        // child after the state publication above was cleared.
        unsafe { DestroyWindow(parent) };
        // SAFETY: no lease remains and the test has cleared the slot publication.
        let disposition = unsafe { CallbackState::request_reclaim(state_slot) };
        assert_eq!(disposition, ReclaimDisposition::Reclaimed);
        result.map_err(Into::into)
    }

    #[test]
    fn native_input_prompt_preserves_standard_controls_ids_and_default_button()
    -> Result<(), Box<dyn std::error::Error>> {
        fn class_name(window: HWND) -> io::Result<String> {
            let mut buffer = [0_u16; 32];
            // SAFETY: window is live and buffer is writable for its full capacity.
            let copied = unsafe {
                GetClassNameW(
                    window,
                    buffer.as_mut_ptr(),
                    i32::try_from(buffer.len()).unwrap_or(i32::MAX),
                )
            };
            if copied == 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(String::from_utf16_lossy(&buffer[..copied as usize]))
            }
        }

        // SAFETY: the system STATIC class/current module remain live for this hidden owner.
        let parent = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let result = (|| -> io::Result<()> {
            let mut state = PromptState {
                spec: prompt_spec(
                    "입력",
                    "첫째",
                    "둘째",
                    LegacyText::default(),
                    LegacyText::default(),
                    &["선택"],
                ),
                result: None,
                done: false,
                owner: parent,
                title: null_mut(),
                label_one: null_mut(),
                label_two: null_mut(),
                edit_one: null_mut(),
                edit_two: null_mut(),
                combo: null_mut(),
                separator: null_mut(),
                ok: null_mut(),
                cancel: null_mut(),
                font: OwnedFont::default(),
                appearance: PromptAppearance {
                    preference: UiAppearance::default(),
                    forced_colors: ForcedColorsState::Inactive,
                    system_theme: Some(ResolvedTheme::Light),
                },
                appearance_resources: None,
                creation_error: None,
                dpi: BASE_DPI,
            };
            create_prompt_children(parent, &mut state)?;

            for (control, expected_class, expected_id) in [
                (state.edit_one, "EDIT", 1004),
                (state.edit_two, "EDIT", 1005),
                (state.combo, "COMBOBOX", 1006),
                (state.ok, "BUTTON", IDOK),
                (state.cancel, "BUTTON", IDCANCEL),
            ] {
                assert!(class_name(control)?.eq_ignore_ascii_case(expected_class));
                // SAFETY: control is live and the integral ID query retains nothing.
                assert_eq!(unsafe { GetDlgCtrlID(control) }, expected_id);
            }
            for (control, expected_id) in [
                (state.title, 1001),
                (state.label_one, 1002),
                (state.label_two, 1003),
                (state.separator, 1010),
            ] {
                assert!(class_name(control)?.eq_ignore_ascii_case("STATIC"));
                // SAFETY: control is live and the integral ID query retains nothing.
                assert_eq!(unsafe { GetDlgCtrlID(control) }, expected_id);
            }

            // SAFETY: these live controls expose integral style values only.
            let edit_style = unsafe { GetWindowLongPtrW(state.edit_one, GWL_STYLE) } as u32;
            // SAFETY: same live style query for the standard combo box.
            let combo_style = unsafe { GetWindowLongPtrW(state.combo, GWL_STYLE) } as u32;
            // SAFETY: same live style query for the default push button.
            let ok_style = unsafe { GetWindowLongPtrW(state.ok, GWL_STYLE) } as u32;
            // SAFETY: same live style query for the ordinary cancel button.
            let cancel_style = unsafe { GetWindowLongPtrW(state.cancel, GWL_STYLE) } as u32;
            // SAFETY: same live style query for the owner-drawn footer separator.
            let separator_style = unsafe { GetWindowLongPtrW(state.separator, GWL_STYLE) } as u32;
            assert_ne!(edit_style & WS_TABSTOP, 0);
            assert_ne!(edit_style & ES_AUTOHSCROLL as u32, 0);
            assert_eq!(combo_style & 0b11, CBS_DROPDOWNLIST as u32);
            assert_ne!(combo_style & WS_TABSTOP, 0);
            assert_eq!(ok_style & BS_TYPEMASK as u32, BS_DEFPUSHBUTTON as u32);
            assert_ne!(ok_style & WS_TABSTOP, 0);
            assert_eq!(cancel_style & BS_TYPEMASK as u32, BS_PUSHBUTTON as u32);
            assert_ne!(cancel_style & WS_TABSTOP, 0);
            assert_eq!(separator_style & SS_TYPEMASK, SS_OWNERDRAW);

            assert_eq!(draw_custom_button(None, state.ok, 0), None);
            let invalid_separator = DRAWITEMSTRUCT {
                CtlType: ODT_BUTTON,
                hwndItem: state.separator,
                ..DRAWITEMSTRUCT::default()
            };
            assert!(!draw_owner_separator(
                None,
                state.separator,
                (&raw const invalid_separator) as LPARAM,
            ));
            Ok(())
        })();
        // SAFETY: parent is test-owned and destroys every prompt child.
        unsafe { DestroyWindow(parent) };
        result.map_err(Into::into)
    }

    #[test]
    fn native_empty_state_uses_direct_standard_controls_and_only_cta_is_focusable()
    -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: null requests the current process module.
        let instance = unsafe { GetModuleHandleW(null()) };
        let class = wide("STATIC");
        // SAFETY: the system class and current module remain valid for this
        // hidden top-level test window.
        let parent = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                instance,
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let result = (|| -> io::Result<()> {
            let query = query_high_contrast_active();
            let forced_colors = ForcedColorsState::from_high_contrast_query(query);
            assert_eq!(
                forced_colors.custom_colors_enabled(),
                matches!(query, Some(false))
            );
            let (instruction, safety, add) = create_empty_state_controls(parent)?;
            for control in [instruction, safety, add] {
                // SAFETY: each control is a live direct child created above.
                assert_eq!(unsafe { GetParent(control) }, parent);
            }
            for text in [
                (instruction, EMPTY_STATE_INSTRUCTION),
                (
                    safety,
                    "‘변경 적용’을 누르기 전에는\r\n실제 파일을 수정하지 않습니다.",
                ),
                (add, EMPTY_STATE_ADD_LABEL),
            ] {
                assert_eq!(window_text(text.0)?, text.1);
            }
            // SAFETY: each HWND is live and GWL_STYLE is a pointer-free query.
            let instruction_style = unsafe { GetWindowLongPtrW(instruction, GWL_STYLE) } as u32;
            // SAFETY: same as above for the second STATIC.
            let safety_style = unsafe { GetWindowLongPtrW(safety, GWL_STYLE) } as u32;
            // SAFETY: same as above for the standard CTA BUTTON.
            let add_style = unsafe { GetWindowLongPtrW(add, GWL_STYLE) } as u32;
            assert_eq!(instruction_style & WS_TABSTOP, 0);
            assert_eq!(safety_style & WS_TABSTOP, 0);
            assert_eq!(instruction_style & SS_CENTERIMAGE, 0);
            assert_eq!(safety_style & SS_CENTERIMAGE, 0);
            assert_ne!(add_style & WS_TABSTOP, 0);
            assert_eq!(add_style & BS_FLAT as u32, 0);

            set_empty_state_controls(
                instruction,
                safety,
                add,
                EmptyStatePresentation::Unavailable,
                true,
            );
            for control in [instruction, safety, add] {
                // SAFETY: each HWND remains live and this reads integral style.
                let style = unsafe { GetWindowLongPtrW(control, GWL_STYLE) } as u32;
                assert_eq!(style & WS_VISIBLE, 0);
            }
            // SAFETY: add remains a live standard BUTTON.
            assert_eq!(unsafe { IsWindowEnabled(add) }, 0);

            set_empty_state_controls(
                instruction,
                safety,
                add,
                EmptyStatePresentation::ReadyToAdd,
                true,
            );
            for control in [instruction, safety, add] {
                // SAFETY: each HWND remains live and this reads integral style.
                let style = unsafe { GetWindowLongPtrW(control, GWL_STYLE) } as u32;
                assert_ne!(style & WS_VISIBLE, 0);
            }
            // SAFETY: add remains a live standard BUTTON.
            assert_ne!(unsafe { IsWindowEnabled(add) }, 0);

            set_empty_state_controls(
                instruction,
                safety,
                add,
                EmptyStatePresentation::ReadyToAdd,
                false,
            );
            // SAFETY: these live HWND style queries verify presentation only.
            let instruction_style = unsafe { GetWindowLongPtrW(instruction, GWL_STYLE) } as u32;
            // SAFETY: same live safety STATIC, intentionally hidden by preference.
            let safety_style = unsafe { GetWindowLongPtrW(safety, GWL_STYLE) } as u32;
            // SAFETY: same live CTA BUTTON, unaffected by the safety-copy toggle.
            let add_style = unsafe { GetWindowLongPtrW(add, GWL_STYLE) } as u32;
            assert_ne!(instruction_style & WS_VISIBLE, 0);
            assert_eq!(safety_style & WS_VISIBLE, 0);
            assert_ne!(add_style & WS_VISIBLE, 0);
            Ok(())
        })();
        // SAFETY: parent is the hidden test HWND and destroys all children.
        unsafe { DestroyWindow(parent) };
        result.map_err(Into::into)
    }

    #[test]
    fn native_drop_overlay_is_noninteractive_and_visible_only_during_drag()
    -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: null requests the current process module.
        let instance = unsafe { GetModuleHandleW(null()) };
        let class = wide("STATIC");
        // SAFETY: the system STATIC class/current module remain live.
        let parent = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                instance,
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let result = (|| -> io::Result<()> {
            let overlay = create_drop_overlay(parent)?;
            // SAFETY: overlay is the live direct child created above.
            assert_eq!(unsafe { GetParent(overlay) }, parent);
            // SAFETY: style and ID queries carry no pointers.
            let style = unsafe { GetWindowLongPtrW(overlay, GWL_STYLE) } as u32;
            assert_eq!(style & WS_TABSTOP, 0);
            assert_eq!(style & SS_NOTIFY, 0);
            assert_eq!(style & SS_CENTERIMAGE, 0);
            // SAFETY: overlay was deliberately created without an ID.
            assert_eq!(unsafe { GetDlgCtrlID(overlay) }, 0);
            assert_eq!(style & WS_VISIBLE, 0);

            for (presentation, text) in [
                (DropPresentation::Accepting, DROP_ACCEPTING_TEXT),
                (DropPresentation::Locked, DROP_LOCKED_TEXT),
                (DropPresentation::Unsupported, DROP_UNSUPPORTED_TEXT),
                (DropPresentation::Full, DROP_FULL_TEXT),
            ] {
                set_drop_overlay_control(overlay, presentation);
                assert_eq!(window_text(overlay)?, text);
                // SAFETY: overlay remains live and this reads integral style.
                let style = unsafe { GetWindowLongPtrW(overlay, GWL_STYLE) } as u32;
                assert_ne!(style & WS_VISIBLE, 0);
            }
            set_drop_overlay_control(overlay, DropPresentation::Inactive);
            assert_eq!(window_text(overlay)?, "");
            // SAFETY: overlay remains live and this reads integral style.
            let style = unsafe { GetWindowLongPtrW(overlay, GWL_STYLE) } as u32;
            assert_eq!(style & WS_VISIBLE, 0);
            Ok(())
        })();
        // SAFETY: parent destroys its overlay child.
        unsafe { DestroyWindow(parent) };
        result.map_err(Into::into)
    }

    #[test]
    fn native_empty_state_color_routing_uses_workspace_system_colors_only()
    -> Result<(), Box<dyn std::error::Error>> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_WIN95_CLASSES,
        };
        // SAFETY: controls has its exact size for synchronous initialization.
        unsafe { InitCommonControlsEx(&controls) };
        // SAFETY: null requests the current process module.
        let instance = unsafe { GetModuleHandleW(null()) };
        let class = wide("STATIC");
        // SAFETY: the system class/current module remain live for this hidden window.
        let parent = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                null_mut(),
                null_mut(),
                instance,
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let rail = match CommandRail::create(parent, &LEFT_RAIL) {
            Ok(rail) => rail,
            Err(error) => {
                // SAFETY: parent is the hidden test window created above.
                unsafe { DestroyWindow(parent) };
                return Err(error.into());
            }
        };
        let result = (|| -> io::Result<()> {
            let (instruction, safety, _add) = create_empty_state_controls(parent)?;
            let (status, count, _cancel) = create_status_controls(parent)?;
            let drop_overlay = create_drop_overlay(parent)?;
            // SAFETY: parent is live and the returned DC is released below.
            let dc = unsafe { GetDC(parent) };
            if dc.is_null() {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: dc is live; sentinel colors make accidental mutation visible.
            unsafe {
                SetTextColor(dc, 0x0012_3456);
                SetBkColor(dc, 0x0065_4321);
            }
            for empty in [instruction, safety] {
                assert_eq!(
                    application::route_static_control_colors(
                        None,
                        instruction,
                        safety,
                        status,
                        count,
                        empty,
                        dc,
                    ),
                    // SAFETY: this is the cached system-owned workspace brush.
                    Some(unsafe { GetSysColorBrush(COLOR_WINDOW) })
                );
                // SAFETY: route wrote current system colors to the live DC.
                assert_eq!(unsafe { GetTextColor(dc) }, unsafe {
                    GetSysColor(COLOR_WINDOWTEXT)
                });
                // SAFETY: same live DC and current workspace background color.
                assert_eq!(unsafe { GetBkColor(dc) }, unsafe {
                    GetSysColor(COLOR_WINDOW)
                });
            }

            // SAFETY: this cached system brush is process-global and stays
            // live for the complete synchronous routing test.
            let custom_brush = unsafe { GetSysColorBrush(COLOR_WINDOW) };
            let custom = StaticControlColors {
                brush: custom_brush,
                text: GRAPHITE_DARK.text_primary,
                background: GRAPHITE_DARK.surface_status,
            };
            assert_eq!(
                application::route_static_control_colors(
                    Some(custom),
                    instruction,
                    safety,
                    status,
                    count,
                    status,
                    dc,
                ),
                Some(custom_brush)
            );
            // SAFETY: custom route wrote semantic values to the live DC.
            assert_eq!(unsafe { GetTextColor(dc) }, custom.text);
            // SAFETY: same live DC and semantic background.
            assert_eq!(unsafe { GetBkColor(dc) }, custom.background);

            for system_status in [status, count] {
                assert_eq!(
                    application::route_static_control_colors(
                        None,
                        instruction,
                        safety,
                        status,
                        count,
                        system_status,
                        dc,
                    ),
                    // SAFETY: this is the cached system-owned status brush.
                    Some(unsafe { GetSysColorBrush(COLOR_WINDOW) })
                );
                // SAFETY: route wrote current system colors to the live DC.
                assert_eq!(unsafe { GetTextColor(dc) }, unsafe {
                    GetSysColor(COLOR_WINDOWTEXT)
                });
                // SAFETY: same live DC and system status background color.
                assert_eq!(unsafe { GetBkColor(dc) }, unsafe {
                    GetSysColor(COLOR_WINDOW)
                });
            }

            for unrelated in [drop_overlay, rail.separator_windows()[0]] {
                assert_eq!(
                    application::route_static_control_colors(
                        None,
                        instruction,
                        safety,
                        status,
                        count,
                        unrelated,
                        dc,
                    ),
                    None
                );
            }
            // SAFETY: dc came from this exact parent and is released once.
            unsafe { ReleaseDC(parent, dc) };
            Ok(())
        })();
        rail.destroy();
        // SAFETY: parent is the hidden test HWND and destroys remaining children.
        unsafe { DestroyWindow(parent) };
        result.map_err(Into::into)
    }

    fn verify_native_command_rails_at_dpi(
        instance: windows_sys::Win32::Foundation::HINSTANCE,
        dpi: u32,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let class = wide("STATIC");
        // SAFETY: the system STATIC class, current module, and null creation
        // parameter remain valid for this hidden top-level test window.
        let parent = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                1_000,
                1_000,
                null_mut(),
                null_mut(),
                instance,
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error().into());
        }

        let left = CommandRail::create(parent, &LEFT_RAIL)?;
        let right = match CommandRail::create(parent, &RIGHT_RAIL) {
            Ok(rail) => rail,
            Err(error) => {
                left.destroy();
                // SAFETY: parent is the hidden test window created above.
                unsafe { DestroyWindow(parent) };
                return Err(error.into());
            }
        };
        let message_font = create_message_font(dpi);
        let status_font = create_status_font(dpi);
        if message_font.is_null() || status_font.is_null() {
            left.destroy();
            right.destroy();
            // SAFETY: any non-null fonts and parent were created in this test.
            unsafe {
                if !message_font.is_null() {
                    DeleteObject(message_font);
                }
                if !status_font.is_null() {
                    DeleteObject(status_font);
                }
                DestroyWindow(parent);
            }
            return Err(io::Error::other("could not create native system fonts").into());
        }
        let measured = measure_font_metrics(parent, message_font, status_font);
        assert!(measured.button_text_width > 0);
        assert!(measured.button_text_height > 0);
        assert!(measured.status_text_height > 0);
        assert!(measured.empty_instruction_text_width > 0);
        assert!(measured.empty_instruction_text_height > 0);
        assert!(measured.empty_safety_text_width > 0);
        assert!(measured.empty_safety_text_height > 0);
        assert!(measured.empty_add_text_width > 0);
        assert!(measured.empty_add_text_height > 0);
        assert!(measured.drop_overlay_text_width > 0);
        assert!(measured.drop_overlay_text_height > 0);
        let metrics = measured.rail_metrics(RailDensity::Compact, dpi);
        let available_height =
            minimum_main_client_height(dpi, measured, RailDensityPreference::Automatic)
                .saturating_sub(measured.status_height(dpi));
        let left_placements = calculate_command_rail_layout(&LEFT_RAIL, available_height, metrics)
            .map_err(|error| io::Error::other(format!("test layout failed: {error:?}")))?;
        let right_placements =
            calculate_command_rail_layout(&RIGHT_RAIL, available_height, metrics)
                .map_err(|error| io::Error::other(format!("test layout failed: {error:?}")))?;
        assert_eq!(left.button_count(), 10);
        assert_eq!(right.button_count(), 9);
        assert_eq!(left.separator_windows().len(), 3);
        assert_eq!(right.separator_windows().len(), 3);

        let right_origin = metrics.rail_width + scale_dip(20, dpi);
        left.apply_font(message_font);
        right.apply_font(message_font);
        left.set_tab_stop(Some(0));
        right.set_tab_stop(Some(0));
        left.arrange(0, &left_placements, dpi);
        right.arrange(right_origin, &right_placements, dpi);

        let result = (|| -> io::Result<()> {
            let apply_rect = left.command_rect(APPLY)?;
            let apply_button = left
                .command_hwnd(APPLY)
                .ok_or_else(|| io::Error::other("Apply button is missing"))?;
            assert_eq!(apply_rect.left, 0);
            assert_eq!(apply_rect.right - apply_rect.left, metrics.rail_width);
            assert_eq!(left.active_apply_readiness_button(), None);
            assert_eq!(right.active_apply_readiness_button(), None);
            left.set_apply_readiness_visible(true);
            right.set_apply_readiness_visible(true);
            assert_eq!(left.active_apply_readiness_button(), Some(apply_button));
            assert_eq!(right.active_apply_readiness_button(), None);
            left.set_visible(false);
            assert_eq!(left.active_apply_readiness_button(), None);
            left.set_visible(true);
            assert_eq!(left.active_apply_readiness_button(), Some(apply_button));
            left.set_apply_readiness_visible(false);
            right.set_apply_readiness_visible(false);

            let mut actual_ids = Vec::with_capacity(19);
            for (rail, expected, origin_x) in [
                (&left, left_placements.as_slice(), 0),
                (&right, right_placements.as_slice(), right_origin),
            ] {
                for (index, placement) in expected.iter().enumerate() {
                    let button = rail
                        .command_hwnd(placement.command)
                        .ok_or_else(|| io::Error::other("native command button is missing"))?;
                    actual_ids.push(placement.command);
                    let tool = rail_tool_spec(placement.command)
                        .ok_or_else(|| io::Error::other("native command label is missing"))?;
                    assert_eq!(window_text(button)?, tool.label);
                    let rect = rail.command_rect(placement.command)?;
                    assert_eq!(rect.left, origin_x + placement.x);
                    assert_eq!(rect.top, placement.y);
                    assert_eq!(rect.right - rect.left, placement.width);
                    assert_eq!(rect.bottom - rect.top, placement.height);
                    assert!(placement.width > measured.button_text_width);
                    assert!(placement.height > measured.button_text_height);
                    // SAFETY: button is live and GWL_STYLE is a value query.
                    let style = unsafe { GetWindowLongPtrW(button, GWL_STYLE) } as u32;
                    assert_ne!(style & BS_MULTILINE as u32, 0);
                    assert_eq!(style & BS_FLAT as u32, 0);
                    assert_eq!(style & BS_TYPEMASK as u32, BS_OWNERDRAW as u32);
                    assert_eq!(style & WS_TABSTOP != 0, index == 0);
                    // SAFETY: button is live and the query has no pointers.
                    assert_ne!(unsafe { IsWindowEnabled(button) }, 0);
                    rail.set_enabled(placement.command, false);
                    // SAFETY: button remains live after EnableWindow.
                    assert_eq!(unsafe { IsWindowEnabled(button) }, 0);
                    rail.set_enabled(placement.command, true);
                }
                let separator_layout = calculate_command_rail_separator_layout(expected, dpi);
                for (index, (separator, expected_rect)) in rail
                    .separator_windows()
                    .iter()
                    .zip(separator_layout)
                    .enumerate()
                {
                    // SAFETY: separator is live and GWL_STYLE is a value query.
                    let style = unsafe { GetWindowLongPtrW(*separator, GWL_STYLE) } as u32;
                    assert_eq!(style & WS_TABSTOP, 0);
                    assert_eq!(style & SS_TYPEMASK, SS_OWNERDRAW);
                    let rect = rail.separator_rect(index)?;
                    assert_eq!(rect.left, origin_x + expected_rect.x);
                    assert_eq!(rect.top, expected_rect.y);
                    assert_eq!(rect.right - rect.left, expected_rect.width);
                    assert_eq!(rect.bottom - rect.top, expected_rect.height);
                }
                rail.set_visible(false);
                for separator in rail.separator_windows() {
                    // SAFETY: separator remains live and this reads integral style.
                    let style = unsafe { GetWindowLongPtrW(*separator, GWL_STYLE) } as u32;
                    assert_eq!(style & WS_VISIBLE, 0);
                }
                rail.set_visible(true);
                for separator in rail.separator_windows() {
                    // SAFETY: separator remains live and this reads integral style.
                    let style = unsafe { GetWindowLongPtrW(*separator, GWL_STYLE) } as u32;
                    assert_ne!(style & WS_VISIBLE, 0);
                }
                rail.set_tab_stop(Some(2));
                for (index, placement) in expected.iter().enumerate() {
                    let button = rail
                        .command_hwnd(placement.command)
                        .ok_or_else(|| io::Error::other("native command button is missing"))?;
                    // SAFETY: button remains live and GWL_STYLE is a value query.
                    let style = unsafe { GetWindowLongPtrW(button, GWL_STYLE) } as u32;
                    assert_eq!(style & WS_TABSTOP != 0, index == 2);
                }
            }
            actual_ids.sort_unstable();
            actual_ids.dedup();
            assert_eq!(actual_ids.len(), 19);
            assert!(!actual_ids.contains(&UNIFY_PATH));
            Ok(())
        })();
        left.destroy();
        right.destroy();
        // SAFETY: all command-rail controls and tooltip text relationships have
        // been torn down; their fonts and parent remain owned by this test.
        unsafe {
            DeleteObject(message_font);
            DeleteObject(status_font);
            DestroyWindow(parent);
        }
        result.map_err(Into::into)
    }

    fn window_text(window: HWND) -> io::Result<String> {
        // SAFETY: window is live and this query has no pointer payload.
        let length = unsafe { GetWindowTextLengthW(window) };
        let capacity = usize::try_from(length)
            .map_err(|_| io::Error::other("invalid native button text length"))?
            .saturating_add(1);
        let mut buffer = vec![0_u16; capacity];
        // SAFETY: buffer is writable for its checked length and retained through
        // the synchronous text copy from the live child window.
        let copied = unsafe {
            GetWindowTextW(
                window,
                buffer.as_mut_ptr(),
                i32::try_from(buffer.len())
                    .map_err(|_| io::Error::other("native button text is too long"))?,
            )
        };
        if copied < 0 {
            return Err(io::Error::last_os_error());
        }
        buffer.truncate(usize::try_from(copied).unwrap_or_default());
        Ok(String::from_utf16_lossy(&buffer))
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
