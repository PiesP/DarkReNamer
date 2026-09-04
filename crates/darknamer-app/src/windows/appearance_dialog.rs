use std::io;
use std::mem::size_of;
use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, COLOR_WINDOW, DT_CALCRECT, DT_LEFT, DT_NOPREFIX, DT_SINGLELINE, DT_VCENTER,
    DT_WORDBREAK, DrawTextW, EndPaint, FillRect, FrameRect, GetDC, GetMonitorInfoW,
    GetSysColorBrush, MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromRect, MonitorFromWindow,
    PAINTSTRUCT, ReleaseDC, SelectObject, SetBkMode, SetTextColor, TRANSPARENT, UpdateWindow,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::SystemServices::{SS_EDITCONTROL, SS_NOPREFIX, SS_OWNERDRAW};
#[cfg(test)]
use windows_sys::Win32::UI::Controls::ODT_STATIC;
use windows_sys::Win32::UI::Controls::{BST_CHECKED, BST_UNCHECKED, SetScrollInfo, SetWindowTheme};
use windows_sys::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForWindow};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BM_GETCHECK, BM_SETCHECK, BN_CLICKED, BS_AUTOCHECKBOX, BS_AUTORADIOBUTTON, BS_DEFPUSHBUTTON,
    BS_GROUPBOX, BS_MULTILINE, BS_NOTIFY, BS_OWNERDRAW, CREATESTRUCTW, CS_HREDRAW, CS_VREDRAW,
    CreateWindowExW, DefWindowProcW, DestroyWindow, GWLP_USERDATA, GetScrollInfo,
    GetWindowLongPtrW, GetWindowRect, IDCANCEL, IDOK, IsWindow, PostMessageW, RegisterClassExW,
    SB_BOTTOM, SB_ENDSCROLL, SB_LINEDOWN, SB_LINEUP, SB_PAGEDOWN, SB_PAGEUP, SB_THUMBPOSITION,
    SB_THUMBTRACK, SB_TOP, SB_VERT, SCROLLINFO, SIF_PAGE, SIF_POS, SIF_RANGE, SIF_TRACKPOS,
    SW_HIDE, SW_SHOW, SWP_NOACTIVATE, SWP_NOREDRAW, SWP_NOZORDER, SendMessageW,
    SetForegroundWindow, SetWindowLongPtrW, SetWindowPos, ShowWindow, WM_CLOSE, WM_COMMAND,
    WM_CREATE, WM_CTLCOLORBTN, WM_CTLCOLORSTATIC, WM_DPICHANGED, WM_DRAWITEM, WM_ERASEBKGND,
    WM_FONTCHANGE, WM_GETFONT, WM_MOUSEWHEEL, WM_NCCREATE, WM_NCDESTROY, WM_NOTIFY, WM_PAINT,
    WM_PRINTCLIENT, WM_SETFONT, WM_SETTINGCHANGE, WM_VSCROLL, WNDCLASSEXW, WS_CAPTION,
    WS_CLIPCHILDREN, WS_CLIPSIBLINGS, WS_EX_CONTROLPARENT, WS_EX_TOOLWINDOW, WS_GROUP, WS_POPUP,
    WS_SYSMENU, WS_TABSTOP, WS_VSCROLL,
};

use super::*;

const DENSITY_AUTOMATIC_ID: u16 = 0xA101;
const DENSITY_COMFORTABLE_ID: u16 = 0xA102;
const DENSITY_COMPACT_ID: u16 = 0xA103;
const DENSITY_MENU_ONLY_ID: u16 = 0xA104;
const EMPHASIS_SUBTLE_ID: u16 = 0xA111;
const EMPHASIS_STANDARD_ID: u16 = 0xA112;
const EMPHASIS_STRONG_ID: u16 = 0xA113;
const SHOW_SEPARATORS_ID: u16 = 0xA121;
const SHOW_PREVIEW_TINT_ID: u16 = 0xA122;
const SHOW_EMPTY_SAFETY_ID: u16 = 0xA123;
const FORCED_EXPLANATION_ID: u16 = 0xA130;
const RESET_DEFAULTS_ID: u16 = 0xA140;
const APPEARANCE_FINISH_ACCEPTED: u32 = 1 << 31;
const APPEARANCE_GROUP_SUBCLASS_ID: usize = 1;
const APPEARANCE_VIEWPORT_SUBCLASS_ID: usize = 2;
const APPEARANCE_DIALOG_TITLE: &str = "DarkReNamer - 모양 설정";
const DENSITY_GROUP_LABEL: &str = "명령 버튼 배치";
const DENSITY_LABELS: [&str; 4] = ["자동 (권장)", "여유 있게", "촘촘하게", "메뉴만"];
const EMPHASIS_GROUP_LABEL: &str = "변경 후 이름 강조";
const EMPHASIS_LABELS: [&str; 3] = ["약하게", "표준", "강하게"];
const SEPARATOR_LABEL: &str = "명령 버튼 그룹 구분선 표시";
const TINT_LABEL: &str = "변경 후 이름 셀 배경 강조";
const EMPTY_SAFETY_LABEL: &str = "빈 목록에서 안전 안내 표시";
const FORCED_COLORS_EXPLANATION: &str =
    "고대비가 활성화되어 변경 후 이름의 글자와 셀 배경은 시스템 색상을 사용합니다.";
const RESET_LABEL: &str = "기본값으로 복원";
const OK_LABEL: &str = "확인";
const CANCEL_LABEL: &str = "취소";

pub(super) struct AppearanceDialogSession {
    pub(super) id: u32,
    pub(super) window: HWND,
    pub(super) baseline: UiAppearance,
    owner_guard: Option<OwnerEnableGuard>,
}

pub(super) enum PreparedAppearanceAction {
    FocusExisting {
        owner: HWND,
        session_id: u32,
        window: HWND,
    },
    Create {
        owner: HWND,
        command_session_id: u64,
        expected_revision: ModelRevision,
        appearance_session_id: u32,
        appearance: UiAppearance,
        forced_colors: ForcedColorsState,
        system_theme: Option<ResolvedTheme>,
    },
}

pub(super) trait AppearanceDialogPlatform {
    fn create(
        &mut self,
        owner: HWND,
        session_id: u32,
        appearance: UiAppearance,
        forced_colors: ForcedColorsState,
        system_theme: Option<ResolvedTheme>,
    ) -> io::Result<HWND>;
    fn arm(&mut self, window: HWND, session_id: u32) -> bool;
    fn focus(&mut self, window: HWND);
    fn owner_guard(&mut self, owner: HWND) -> OwnerEnableGuard;
    fn destroy(&mut self, window: HWND);
}

pub(super) struct NativeAppearanceDialogPlatform;

impl AppearanceDialogPlatform for NativeAppearanceDialogPlatform {
    fn create(
        &mut self,
        owner: HWND,
        session_id: u32,
        appearance: UiAppearance,
        forced_colors: ForcedColorsState,
        system_theme: Option<ResolvedTheme>,
    ) -> io::Result<HWND> {
        create_appearance_dialog_window(owner, session_id, appearance, forced_colors, system_theme)
    }

    fn arm(&mut self, window: HWND, session_id: u32) -> bool {
        // SAFETY: the runner installed this live unarmed HWND as the exact
        // AppState session and the scalar payload contains no borrowed data.
        unsafe { SendMessageW(window, WM_APP_APPEARANCE_ARM, 0, session_id as isize) != 0 }
    }

    fn focus(&mut self, window: HWND) {
        // SAFETY: the runner validated this copied live session HWND and holds
        // no AppState lease across synchronous activation/focus callbacks.
        unsafe {
            SetForegroundWindow(window);
            SetFocus(window);
        }
    }

    fn owner_guard(&mut self, owner: HWND) -> OwnerEnableGuard {
        OwnerEnableGuard::new(owner)
    }

    fn destroy(&mut self, window: HWND) {
        // SAFETY: the runner removed this exact session before destruction.
        unsafe { DestroyWindow(window) };
    }
}

impl AppearanceDialogSession {
    pub(super) fn disarm_owner_restore(&mut self) {
        if let Some(guard) = self.owner_guard.as_mut() {
            guard.disarm();
        }
    }

    #[cfg(test)]
    pub(super) fn owns_owner_guard(&self) -> bool {
        self.owner_guard.is_some()
    }
}

struct AppearanceDialogWindowState {
    owner: HWND,
    session_id: u32,
    model: AppearanceDialogModel,
    viewport: HWND,
    density_group: HWND,
    density_group_state: *mut AppearanceGroupSubclassState,
    density: [HWND; 4],
    emphasis_group: HWND,
    emphasis_group_state: *mut AppearanceGroupSubclassState,
    emphasis: [HWND; 3],
    forced_explanation: HWND,
    checkboxes: [HWND; 3],
    separator: HWND,
    reset: HWND,
    ok: HWND,
    cancel: HWND,
    font: OwnedFont,
    measured: AppearanceDialogMetrics,
    layout: Option<AppearanceDialogLayout>,
    scroll_y: i32,
    appearance_resources: Option<AppearanceResources>,
    system_theme: Option<ResolvedTheme>,
    dpi: u32,
    armed: bool,
    finished: bool,
}

impl Drop for AppearanceDialogWindowState {
    fn drop(&mut self) {
        if appearance_dialog_should_notify_cancel(self.armed, self.finished) {
            let effect = self.model.apply(AppearanceDialogAction::Cancel);
            send_effect(self, effect);
            self.finished = true;
        }
    }
}

type AppearanceDialogStateSlot = CallbackState<AppearanceDialogWindowState>;

struct AppearanceDialogInit {
    state: *mut AppearanceDialogStateSlot,
    adopted: *mut bool,
}

#[derive(Clone, Copy)]
struct AppearanceGroupStyle {
    background: HBRUSH,
    border: HBRUSH,
    text: u32,
}

struct AppearanceGroupSubclassState {
    label: &'static str,
    style: Option<AppearanceGroupStyle>,
}

pub(super) fn prepare_appearance_dialog(
    owner: HWND,
    state: &mut AppState,
) -> Option<PreparedAppearanceAction> {
    if let Some(session) = state.appearance_dialog.as_ref() {
        return Some(PreparedAppearanceAction::FocusExisting {
            owner,
            session_id: session.id,
            window: session.window,
        });
    }
    let activity = state.worker_activity();
    let worker_active = activity.admission || activity.plan || activity.apply;
    if !advanced_appearance_available(worker_active, state.confirmation_pending) {
        message(
            owner,
            "진행 중인 작업이나 확인 대화상자를 마친 뒤 모양 설정을 열어 주세요.",
            "DarkReNamer - 모양 설정",
        );
        return None;
    }
    state.next_prompt_id = state.next_prompt_id.wrapping_add(1).max(1);
    let command_session_id = state.next_prompt_id;
    state.active_prompt = Some(command_session_id);
    Some(PreparedAppearanceAction::Create {
        owner,
        command_session_id,
        expected_revision: state.revision(),
        appearance_session_id: state.next_appearance_dialog_id.wrapping_add(1).max(1),
        appearance: state.appearance,
        forced_colors: state.forced_colors,
        system_theme: state.system_theme,
    })
}

pub(super) fn run_prepared_appearance_action(
    owner: HWND,
    prepared: PreparedAppearanceAction,
    mut platform: impl AppearanceDialogPlatform,
) {
    match prepared {
        PreparedAppearanceAction::FocusExisting {
            owner: prepared_owner,
            session_id,
            window,
        } => {
            if prepared_owner != owner {
                return;
            }
            let Some(state_lease) = try_app_state(owner) else {
                return;
            };
            let current = state_lease
                .state()
                .appearance_dialog
                .as_ref()
                .is_some_and(|session| session.id == session_id && session.window == window)
                // SAFETY: both copied HWND values are non-owning identity queries.
                && unsafe { IsWindow(owner) != 0 && IsWindow(window) != 0 };
            drop(state_lease);
            if current {
                platform.focus(window);
            }
        }
        PreparedAppearanceAction::Create {
            owner: prepared_owner,
            command_session_id,
            expected_revision,
            appearance_session_id,
            appearance,
            forced_colors,
            system_theme,
        } => {
            if prepared_owner != owner {
                return;
            }
            let window = match platform.create(
                owner,
                appearance_session_id,
                appearance,
                forced_colors,
                system_theme,
            ) {
                Ok(window) => window,
                Err(error) => {
                    finish_failed_appearance_creation(
                        owner,
                        command_session_id,
                        format!(
                            "모양 설정 창을 열지 못했습니다. 현재 작업에는 영향이 없습니다: {error}"
                        ),
                    );
                    return;
                }
            };
            let Some(mut state_lease) = try_app_state(owner) else {
                platform.destroy(window);
                return;
            };
            let state = state_lease.state_mut();
            if state.active_prompt != Some(command_session_id) {
                drop(state_lease);
                platform.destroy(window);
                return;
            }
            let activity = state.worker_activity();
            let current = !state.close_pending
                && !activity.admission
                && !activity.plan
                && !activity.apply
                && !state.confirmation_pending
                && state.revision() == expected_revision
                && state.appearance_dialog.is_none()
                // SAFETY: both HWND values are copied identity queries.
                && unsafe { IsWindow(owner) != 0 && IsWindow(window) != 0 };
            state.active_prompt = None;
            if !current {
                if !state.close_pending {
                    state.set_transient_status(
                        "모양 설정 창을 준비하는 동안 작업 상태가 바뀌어 창을 열지 않았습니다.",
                    );
                } else {
                    try_finish_window_close(owner, state);
                }
                drop(state_lease);
                platform.destroy(window);
                return;
            }
            state.next_appearance_dialog_id = appearance_session_id;
            state.appearance_dialog = Some(AppearanceDialogSession {
                id: appearance_session_id,
                window,
                baseline: appearance,
                owner_guard: None,
            });
            drop(state_lease);

            if !platform.arm(window, appearance_session_id) {
                remove_failed_appearance_session(
                    owner,
                    appearance_session_id,
                    window,
                    "모양 설정 창을 활성화하지 못했습니다. 현재 작업에는 영향이 없습니다.",
                );
                platform.destroy(window);
                return;
            }
            let mut owner_guard = platform.owner_guard(owner);
            platform.focus(window);
            let Some(mut state_lease) = try_app_state(owner) else {
                owner_guard.disarm();
                platform.destroy(window);
                drop(owner_guard);
                return;
            };
            let state = state_lease.state_mut();
            let activity = state.worker_activity();
            let exact_session = state.appearance_dialog.as_ref().is_some_and(|session| {
                session.id == appearance_session_id
                    && session.window == window
                    && session.owner_guard.is_none()
            });
            let current = exact_session
                && !state.close_pending
                && !activity.admission
                && !activity.plan
                && !activity.apply
                && !state.confirmation_pending
                && state.revision() == expected_revision;
            if current {
                if let Some(session) = state.appearance_dialog.as_mut() {
                    session.owner_guard = Some(owner_guard);
                }
                return;
            }
            let removed = if exact_session {
                state.appearance_dialog.take()
            } else {
                None
            };
            if state.close_pending {
                owner_guard.disarm();
                try_finish_window_close(owner, state);
            } else {
                state.set_transient_status(
                    "모양 설정 창을 활성화하는 동안 작업 상태가 바뀌어 창을 닫았습니다.",
                );
            }
            drop(state_lease);
            platform.destroy(window);
            drop(removed);
            drop(owner_guard);
        }
    }
}

fn finish_failed_appearance_creation(owner: HWND, command_session_id: u64, error: String) {
    let Some(mut state_lease) = try_app_state(owner) else {
        return;
    };
    let state = state_lease.state_mut();
    if state.active_prompt != Some(command_session_id) {
        return;
    }
    state.active_prompt = None;
    if state.close_pending {
        try_finish_window_close(owner, state);
    } else {
        state.set_transient_status(error);
    }
}

fn remove_failed_appearance_session(owner: HWND, session_id: u32, window: HWND, error: &str) {
    let Some(mut state_lease) = try_app_state(owner) else {
        return;
    };
    let state = state_lease.state_mut();
    if state
        .appearance_dialog
        .as_ref()
        .is_some_and(|session| session.id == session_id && session.window == window)
    {
        let removed = state.appearance_dialog.take();
        drop(removed);
        if state.close_pending {
            try_finish_window_close(owner, state);
        } else {
            state.set_transient_status(error);
        }
    }
}

pub(super) fn active_appearance_dialog(state: &AppState) -> Option<HWND> {
    state
        .appearance_dialog
        .as_ref()
        .map(|session| session.window)
        // SAFETY: IsWindow is a non-owning value query for the copied HWND.
        .filter(|window| unsafe { IsWindow(*window) } != 0)
}

pub(super) fn notify_appearance_dialog_accessibility(state: &AppState) {
    let Some(session) = state.appearance_dialog.as_ref() else {
        return;
    };
    // SAFETY: the payload is a copied boolean and session ID; no pointer or
    // borrowed state crosses the asynchronous message boundary.
    unsafe {
        PostMessageW(
            session.window,
            WM_APP_APPEARANCE_ACCESSIBILITY,
            pack_appearance_environment(state.forced_colors, state.system_theme),
            session.id as isize,
        )
    };
}

const fn pack_appearance_environment(
    forced_colors: ForcedColorsState,
    system_theme: Option<ResolvedTheme>,
) -> usize {
    let forced = if matches!(forced_colors, ForcedColorsState::ActiveOrUnknown) {
        1
    } else {
        0
    };
    let system = match system_theme {
        None | Some(ResolvedTheme::NativeSystem) => 0,
        Some(ResolvedTheme::Light) => 1,
        Some(ResolvedTheme::Dark) => 2,
    };
    forced | (system << 1)
}

fn unpack_appearance_environment(packed: usize) -> (ForcedColorsState, Option<ResolvedTheme>) {
    let forced = if packed & 1 == 0 {
        ForcedColorsState::Inactive
    } else {
        ForcedColorsState::ActiveOrUnknown
    };
    let system = match (packed >> 1) & 0b11 {
        1 => Some(ResolvedTheme::Light),
        2 => Some(ResolvedTheme::Dark),
        _ => None,
    };
    (forced, system)
}

pub(super) fn handle_appearance_preview(
    state: &mut AppState,
    packed: usize,
    session_id: isize,
) -> bool {
    let Ok(session_id) = u32::try_from(session_id) else {
        return false;
    };
    if !state
        .appearance_dialog
        .as_ref()
        .is_some_and(|session| session.id == session_id)
    {
        return false;
    }
    let Ok(packed) = u32::try_from(packed) else {
        return false;
    };
    if let Some(appearance) = unpack_ui_appearance(packed) {
        state.appearance = appearance;
        true
    } else {
        false
    }
}

pub(super) fn finish_appearance_dialog(
    owner: HWND,
    state: &mut AppState,
    packed: usize,
    session_id: isize,
) -> Option<AppearanceDialogSession> {
    let Ok(session_id) = u32::try_from(session_id) else {
        return None;
    };
    let Ok(packed) = u32::try_from(packed) else {
        return None;
    };
    if !state
        .appearance_dialog
        .as_ref()
        .is_some_and(|session| session.id == session_id)
    {
        return None;
    }
    let accepted = packed & APPEARANCE_FINISH_ACCEPTED != 0;
    let payload = packed & !APPEARANCE_FINISH_ACCEPTED;
    let appearance = unpack_ui_appearance(payload)?;
    let session = state.appearance_dialog.take()?;
    state.appearance = if accepted {
        appearance
    } else {
        session.baseline
    };
    apply_native_appearance_nonblocking(owner, state);
    update_controls(state);
    arrange(owner, state);
    if accepted {
        state.persist_appearance_preferences();
    }
    Some(session)
}

pub(super) fn cancel_appearance_dialog(
    owner: HWND,
    state: &mut AppState,
) -> Option<AppearanceDialogSession> {
    let mut session = state.appearance_dialog.take()?;
    state.appearance = session.baseline;
    session.disarm_owner_restore();
    apply_native_appearance_nonblocking(owner, state);
    update_controls(state);
    arrange(owner, state);
    Some(session)
}

pub(super) fn destroy_cancelled_appearance_dialog(session: AppearanceDialogSession) {
    // SAFETY: the caller removed this exact session from AppState and released
    // its lease. The scalar dismiss ID suppresses the fail-closed callback
    // before synchronous teardown.
    unsafe {
        SendMessageW(
            session.window,
            WM_APP_APPEARANCE_DISMISS,
            0,
            session.id as isize,
        );
        DestroyWindow(session.window);
    }
    drop(session);
}

pub(super) fn create_appearance_dialog_window(
    owner: HWND,
    session_id: u32,
    appearance: UiAppearance,
    forced_colors: ForcedColorsState,
    system_theme: Option<ResolvedTheme>,
) -> io::Result<HWND> {
    // SAFETY: null requests the current process module without caller storage.
    let instance = unsafe { GetModuleHandleW(null()) };
    if instance.is_null() {
        return Err(io::Error::last_os_error());
    }
    let class_name = wide("DarkReNamerAppearanceDialog");
    // SAFETY: null instance plus IDC_ARROW requests the predefined cursor.
    let cursor = unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::LoadCursorW(
            null_mut(),
            windows_sys::Win32::UI::WindowsAndMessaging::IDC_ARROW,
        )
    };
    // SAFETY: COLOR_WINDOW returns a cached system-owned brush.
    let background = unsafe { GetSysColorBrush(COLOR_WINDOW) };
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(appearance_dialog_proc),
        hInstance: instance,
        hCursor: cursor,
        hbrBackground: background,
        lpszClassName: class_name.as_ptr(),
        ..WNDCLASSEXW::default()
    };
    // SAFETY: the class descriptor and class-name storage remain live for the
    // synchronous registration. Re-registration failure is harmless when the
    // process-local class already exists.
    unsafe { RegisterClassExW(&class) };
    let state_ptr = CallbackState::into_raw(AppearanceDialogWindowState {
        owner,
        session_id,
        model: AppearanceDialogModel::new(appearance, forced_colors),
        viewport: null_mut(),
        density_group: null_mut(),
        density_group_state: null_mut(),
        density: [null_mut(); 4],
        emphasis_group: null_mut(),
        emphasis_group_state: null_mut(),
        emphasis: [null_mut(); 3],
        forced_explanation: null_mut(),
        checkboxes: [null_mut(); 3],
        separator: null_mut(),
        reset: null_mut(),
        ok: null_mut(),
        cancel: null_mut(),
        font: OwnedFont::default(),
        measured: AppearanceDialogMetrics::default(),
        layout: None,
        scroll_y: 0,
        appearance_resources: None,
        system_theme,
        dpi: BASE_DPI,
        armed: false,
        finished: false,
    });
    let mut adopted = false;
    let mut init = AppearanceDialogInit {
        state: state_ptr,
        adopted: &mut adopted,
    };
    let title = wide(APPEARANCE_DIALOG_TITLE);
    // SAFETY: owner/instance are live; title, class, init, and the boxed state
    // remain allocated through synchronous creation and its callbacks.
    let window = unsafe {
        CreateWindowExW(
            WS_EX_TOOLWINDOW,
            class_name.as_ptr(),
            title.as_ptr(),
            WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN,
            0,
            0,
            0,
            0,
            owner,
            null_mut(),
            instance,
            (&mut init as *mut AppearanceDialogInit).cast(),
        )
    };
    if window.is_null() {
        if !adopted {
            // SAFETY: WM_NCCREATE did not adopt the allocation, so this is its
            // single Box::from_raw reclamation path.
            unsafe { drop(Box::from_raw(state_ptr)) };
        }
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the created dialog is live and ready for normal UI-thread use.
    unsafe {
        ShowWindow(window, SW_SHOW);
        UpdateWindow(window);
    }
    Ok(window)
}

#[cfg(test)]
pub(super) fn visual_custom_colors_active(window: HWND) -> Option<bool> {
    Some(
        try_appearance_dialog_state(window)?
            .state()
            .appearance_resources
            .is_some(),
    )
}

fn create_controls(window: HWND, state: &mut AppearanceDialogWindowState) -> io::Result<()> {
    let static_class = wide("STATIC");
    // SAFETY: the standard STATIC class, parent, and current module are live;
    // WS_EX_CONTROLPARENT preserves dialog-manager traversal into body controls.
    state.viewport = unsafe {
        CreateWindowExW(
            WS_EX_CONTROLPARENT,
            static_class.as_ptr(),
            null(),
            WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | WS_VSCROLL,
            0,
            0,
            0,
            0,
            window,
            0xA0F0_usize as *mut c_void,
            GetModuleHandleW(null()),
            null_mut(),
        )
    };
    if state.viewport.is_null() {
        return Err(io::Error::last_os_error());
    }
    // Store only the copied dialog HWND. The viewport callback resolves the
    // currently published dialog slot and acquires the same lease boundary.
    // SAFETY: viewport is a live UI-thread child, the callback has the required
    // ABI, and copied dialog HWND refdata contains no Rust reference.
    if unsafe {
        SetWindowSubclass(
            state.viewport,
            Some(appearance_viewport_subclass),
            APPEARANCE_VIEWPORT_SUBCLASS_ID,
            window as usize,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let body = state.viewport;
    state.density_group = child(
        body,
        "BUTTON",
        DENSITY_GROUP_LABEL,
        0xA100,
        BS_GROUPBOX as u32,
    )?;
    state.density_group_state =
        install_appearance_group_subclass(state.density_group, DENSITY_GROUP_LABEL)?;
    state.density = [
        child(
            body,
            "BUTTON",
            DENSITY_LABELS[0],
            DENSITY_AUTOMATIC_ID,
            BS_AUTORADIOBUTTON as u32
                | BS_MULTILINE as u32
                | BS_NOTIFY as u32
                | WS_GROUP
                | WS_TABSTOP,
        )?,
        child(
            body,
            "BUTTON",
            DENSITY_LABELS[1],
            DENSITY_COMFORTABLE_ID,
            BS_AUTORADIOBUTTON as u32 | BS_MULTILINE as u32 | BS_NOTIFY as u32 | WS_TABSTOP,
        )?,
        child(
            body,
            "BUTTON",
            DENSITY_LABELS[2],
            DENSITY_COMPACT_ID,
            BS_AUTORADIOBUTTON as u32 | BS_MULTILINE as u32 | BS_NOTIFY as u32 | WS_TABSTOP,
        )?,
        child(
            body,
            "BUTTON",
            DENSITY_LABELS[3],
            DENSITY_MENU_ONLY_ID,
            BS_AUTORADIOBUTTON as u32 | BS_MULTILINE as u32 | BS_NOTIFY as u32 | WS_TABSTOP,
        )?,
    ];
    state.emphasis_group = child(
        body,
        "BUTTON",
        EMPHASIS_GROUP_LABEL,
        0xA110,
        BS_GROUPBOX as u32,
    )?;
    state.emphasis_group_state =
        install_appearance_group_subclass(state.emphasis_group, EMPHASIS_GROUP_LABEL)?;
    state.emphasis = [
        child(
            body,
            "BUTTON",
            EMPHASIS_LABELS[0],
            EMPHASIS_SUBTLE_ID,
            BS_AUTORADIOBUTTON as u32
                | BS_MULTILINE as u32
                | BS_NOTIFY as u32
                | WS_GROUP
                | WS_TABSTOP,
        )?,
        child(
            body,
            "BUTTON",
            EMPHASIS_LABELS[1],
            EMPHASIS_STANDARD_ID,
            BS_AUTORADIOBUTTON as u32 | BS_MULTILINE as u32 | BS_NOTIFY as u32 | WS_TABSTOP,
        )?,
        child(
            body,
            "BUTTON",
            EMPHASIS_LABELS[2],
            EMPHASIS_STRONG_ID,
            BS_AUTORADIOBUTTON as u32 | BS_MULTILINE as u32 | BS_NOTIFY as u32 | WS_TABSTOP,
        )?,
    ];
    state.forced_explanation = child(
        body,
        "STATIC",
        FORCED_COLORS_EXPLANATION,
        FORCED_EXPLANATION_ID,
        SS_NOPREFIX | SS_EDITCONTROL,
    )?;
    state.checkboxes = [
        child(
            body,
            "BUTTON",
            SEPARATOR_LABEL,
            SHOW_SEPARATORS_ID,
            BS_AUTOCHECKBOX as u32 | BS_MULTILINE as u32 | BS_NOTIFY as u32 | WS_TABSTOP,
        )?,
        child(
            body,
            "BUTTON",
            TINT_LABEL,
            SHOW_PREVIEW_TINT_ID,
            BS_AUTOCHECKBOX as u32 | BS_MULTILINE as u32 | BS_NOTIFY as u32 | WS_TABSTOP,
        )?,
        child(
            body,
            "BUTTON",
            EMPTY_SAFETY_LABEL,
            SHOW_EMPTY_SAFETY_ID,
            BS_AUTOCHECKBOX as u32 | BS_MULTILINE as u32 | BS_NOTIFY as u32 | WS_TABSTOP,
        )?,
    ];
    state.separator = child(body, "STATIC", "", 0xA131, SS_OWNERDRAW)?;
    state.reset = child(
        window,
        "BUTTON",
        RESET_LABEL,
        RESET_DEFAULTS_ID,
        WS_TABSTOP | BS_OWNERDRAW as u32,
    )?;
    state.ok = child(
        window,
        "BUTTON",
        OK_LABEL,
        IDOK as u16,
        WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
    )?;
    state.cancel = child(
        window,
        "BUTTON",
        CANCEL_LABEL,
        IDCANCEL as u16,
        WS_TABSTOP | BS_OWNERDRAW as u32,
    )?;
    Ok(())
}

fn sync_controls(state: &AppearanceDialogWindowState) {
    let draft = state.model.draft();
    for (control, checked) in state.density.iter().zip([
        draft.density == RailDensityPreference::Automatic,
        draft.density == RailDensityPreference::Comfortable,
        draft.density == RailDensityPreference::Compact,
        draft.density == RailDensityPreference::MenuOnly,
    ]) {
        set_checked(*control, checked);
    }
    for (control, checked) in state.emphasis.iter().zip([
        draft.emphasis == PreviewEmphasis::Subtle,
        draft.emphasis == PreviewEmphasis::Standard,
        draft.emphasis == PreviewEmphasis::Strong,
    ]) {
        set_checked(*control, checked);
    }
    for (control, checked) in state.checkboxes.iter().zip([
        draft.show_separators,
        draft.show_preview_tint,
        draft.show_empty_safety,
    ]) {
        set_checked(*control, checked);
    }
    let custom = state.model.forced_colors().custom_colors_enabled();
    // SAFETY: these are live direct child controls; only color-dependent
    // controls are disabled while Forced Colors is active or unknown.
    unsafe {
        for control in state.emphasis {
            EnableWindow(control, i32::from(custom));
        }
        EnableWindow(state.checkboxes[1], i32::from(custom));
        ShowWindow(
            state.forced_explanation,
            if custom { SW_HIDE } else { SW_SHOW },
        );
    }
}

fn set_checked(control: HWND, checked: bool) {
    // SAFETY: control is a live radio/checkbox BUTTON and the integral state is copied.
    unsafe {
        SendMessageW(
            control,
            BM_SETCHECK,
            if checked { BST_CHECKED } else { BST_UNCHECKED } as usize,
            0,
        )
    };
}

fn is_checked(control: HWND) -> bool {
    // SAFETY: control is a live radio/checkbox BUTTON and returns an integral state.
    unsafe { SendMessageW(control, BM_GETCHECK, 0, 0) == BST_CHECKED as isize }
}

fn send_effect(state: &AppearanceDialogWindowState, effect: AppearanceDialogEffect) {
    if !state.armed {
        return;
    }
    let (message, payload) = match effect {
        AppearanceDialogEffect::None => return,
        AppearanceDialogEffect::Preview(appearance) => {
            (WM_APP_APPEARANCE_PREVIEW, pack_ui_appearance(appearance))
        }
        AppearanceDialogEffect::Accept(appearance) => (
            WM_APP_APPEARANCE_FINISH,
            pack_ui_appearance(appearance) | APPEARANCE_FINISH_ACCEPTED,
        ),
        AppearanceDialogEffect::Cancel(appearance) => {
            (WM_APP_APPEARANCE_FINISH, pack_ui_appearance(appearance))
        }
    };
    // SAFETY: owner is live while its session owns this dialog. Both payloads
    // are copied integers, and no AppState reference is held by this callback.
    unsafe {
        SendMessageW(
            state.owner,
            message,
            payload as usize,
            state.session_id as isize,
        )
    };
}

fn apply_action(
    window: HWND,
    state: &mut AppearanceDialogWindowState,
    action: AppearanceDialogAction,
) -> bool {
    let close = matches!(
        action,
        AppearanceDialogAction::Accept | AppearanceDialogAction::Cancel
    );
    let effect = state.model.apply(action);
    if close {
        state.finished = true;
    }
    if matches!(action, AppearanceDialogAction::ResetDefaults) {
        sync_controls(state);
    }
    if !close {
        apply_dialog_appearance(window, state);
    }
    send_effect(state, effect);
    close
}

fn apply_dialog_appearance(window: HWND, state: &mut AppearanceDialogWindowState) {
    let resolved = state
        .model
        .draft()
        .resolve(state.model.forced_colors(), state.system_theme);
    let mut replacement = semantic_palette(resolved.theme).and_then(|palette| {
        set_native_control_theme_disabled(state, true)
            .then(|| AppearanceResources::create(palette).ok())
            .flatten()
    });
    if replacement.as_ref().is_none_or(|resources| {
        !update_appearance_group_styles(
            [state.density_group_state, state.emphasis_group_state],
            Some(resources),
        )
    }) {
        set_native_control_theme_disabled(state, false);
        update_appearance_group_styles(
            [state.density_group_state, state.emphasis_group_state],
            None,
        );
        replacement = None;
    }
    state.appearance_resources = replacement;
    apply_auxiliary_dwm_title_frame(
        window,
        if state.appearance_resources.is_some() {
            resolved.theme
        } else {
            ResolvedTheme::NativeSystem
        },
    );
    // SAFETY: window is live and resources are installed before invalidation.
    unsafe {
        RedrawWindow(
            window,
            null(),
            null_mut(),
            RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
        )
    };
}

fn install_appearance_group_subclass(
    window: HWND,
    label: &'static str,
) -> io::Result<*mut AppearanceGroupSubclassState> {
    let state = Box::into_raw(Box::new(AppearanceGroupSubclassState {
        label,
        style: None,
    }));
    // SAFETY: window is a live dialog-owned group box, the callback has the
    // documented ABI, and state is reclaimed by that window's WM_NCDESTROY.
    if unsafe {
        SetWindowSubclass(
            window,
            Some(appearance_group_subclass),
            APPEARANCE_GROUP_SUBCLASS_ID,
            state as usize,
        )
    } == 0
    {
        // SAFETY: installation failed, so no callback owns this allocation.
        unsafe { drop(Box::from_raw(state)) };
        Err(io::Error::last_os_error())
    } else {
        Ok(state)
    }
}

fn update_appearance_group_styles(
    groups: [*mut AppearanceGroupSubclassState; 2],
    resources: Option<&AppearanceResources>,
) -> bool {
    let style = resources.map(|resources| AppearanceGroupStyle {
        background: resources.dialog_brush(),
        border: resources.border_brush(),
        text: resources.palette().text_primary,
    });
    let mut updated_all = true;
    for group in groups {
        if !group.is_null() {
            // SAFETY: each pointer is the callback-owned Box returned at install
            // time and remains live until its child WM_NCDESTROY. Dialog state is
            // UI-thread confined and updates it without sending a window message.
            unsafe { (*group).style = style };
        } else {
            updated_all = false;
        }
    }
    updated_all
}

unsafe extern "system" fn appearance_group_subclass(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _subclass_id: usize,
    state_ref: usize,
) -> LRESULT {
    if message == WM_NCDESTROY {
        // SAFETY: this exact callback/id pair was installed on window above.
        unsafe {
            RemoveWindowSubclass(
                window,
                Some(appearance_group_subclass),
                APPEARANCE_GROUP_SUBCLASS_ID,
            )
        };
        // SAFETY: forward final destruction while the callback state remains live.
        let result = unsafe { DefSubclassProc(window, message, wparam, lparam) };
        if state_ref != 0 {
            // SAFETY: WM_NCDESTROY is the single reclamation point for this
            // Box::into_raw allocation.
            unsafe {
                drop(Box::from_raw(
                    state_ref as *mut AppearanceGroupSubclassState,
                ))
            };
        }
        return result;
    }
    if state_ref == 0 {
        // SAFETY: no callback-owned state exists, so retain native handling.
        return unsafe { DefSubclassProc(window, message, wparam, lparam) };
    }
    // SAFETY: refdata is the live callback-owned allocation until WM_NCDESTROY.
    let state = unsafe { &*(state_ref as *const AppearanceGroupSubclassState) };
    match message {
        WM_ERASEBKGND if state.style.is_some() => 1,
        WM_PAINT if state.style.is_some() => {
            let mut paint = PAINTSTRUCT::default();
            // SAFETY: window is live and paint remains writable until EndPaint.
            let dc = unsafe { BeginPaint(window, &mut paint) };
            if !dc.is_null() {
                paint_appearance_group(window, dc, state);
            }
            // SAFETY: balance the exact BeginPaint call above.
            unsafe { EndPaint(window, &paint) };
            0
        }
        WM_PRINTCLIENT if state.style.is_some() && wparam != 0 => {
            paint_appearance_group(window, wparam as HDC, state);
            1
        }
        _ => {
            // SAFETY: every unowned message is forwarded unchanged exactly once.
            unsafe { DefSubclassProc(window, message, wparam, lparam) }
        }
    }
}

fn paint_appearance_group(window: HWND, dc: HDC, state: &AppearanceGroupSubclassState) {
    let Some(style) = state.style else {
        return;
    };
    let mut client = RECT::default();
    // SAFETY: window/DC/brushes are live and client is writable.
    unsafe {
        GetClientRect(window, &mut client);
        FillRect(dc, &client, style.background);
    }
    let label = wide(state.label);
    // SAFETY: the live group box returns its borrowed font handle.
    let font = unsafe { SendMessageW(window, WM_GETFONT, 0, 0) } as HFONT;
    let previous = if font.is_null() {
        null_mut()
    } else {
        // SAFETY: font remains control-owned for this synchronous paint.
        unsafe { SelectObject(dc, font) }
    };
    let mut measured = RECT::default();
    // SAFETY: label/DC/measured remain live for this calculation-only draw.
    unsafe {
        DrawTextW(
            dc,
            label.as_ptr(),
            i32::try_from(label.len().saturating_sub(1)).unwrap_or(i32::MAX),
            &mut measured,
            DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX,
        )
    };
    // SAFETY: window is the live group box and this value query retains nothing.
    let dpi = unsafe { GetDpiForWindow(window) }.max(BASE_DPI);
    let text_height = (measured.bottom - measured.top).max(scale_dip(12, dpi));
    let horizontal_padding = scale_dip(8, dpi);
    let label_gap = scale_dip(4, dpi);
    let mut frame = client;
    frame.top = frame.top.saturating_add(text_height / 2);
    // SAFETY: frame/DC/border are live and client-bounded.
    unsafe { FrameRect(dc, &frame, style.border) };
    let mut label_background = RECT {
        left: client.left.saturating_add(horizontal_padding),
        top: client.top,
        right: client
            .left
            .saturating_add(horizontal_padding)
            .saturating_add((measured.right - measured.left).max(0))
            .saturating_add(label_gap.saturating_mul(2)),
        bottom: client.top.saturating_add(text_height),
    };
    label_background.right = label_background.right.min(client.right);
    // SAFETY: label band and palette resources remain live for this paint.
    unsafe {
        FillRect(dc, &label_background, style.background);
        SetBkMode(dc, TRANSPARENT as i32);
        SetTextColor(dc, style.text);
    }
    let mut text = label_background;
    text.left = text.left.saturating_add(label_gap);
    text.right = text.right.saturating_sub(label_gap);
    // SAFETY: label/DC/text remain live for this synchronous draw.
    unsafe {
        DrawTextW(
            dc,
            label.as_ptr(),
            i32::try_from(label.len().saturating_sub(1)).unwrap_or(i32::MAX),
            &mut text,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
        )
    };
    if !previous.is_null() {
        // SAFETY: restore the exact object returned by SelectObject.
        unsafe { SelectObject(dc, previous) };
    }
}

fn native_themed_controls(state: &AppearanceDialogWindowState) -> impl Iterator<Item = HWND> + '_ {
    state
        .density
        .into_iter()
        .chain(state.emphasis)
        .chain(state.checkboxes)
}

fn set_native_control_theme_disabled(state: &AppearanceDialogWindowState, disabled: bool) -> bool {
    let empty = [0_u16];
    let theme = if disabled { empty.as_ptr() } else { null() };
    native_themed_controls(state).fold(true, |all_applied, control| {
        // SAFETY: every control is a live dialog child. Empty strings disable
        // visual styles so documented WM_CTLCOLOR colors remain authoritative;
        // null pointers restore the system theme.
        let applied = (unsafe { SetWindowTheme(control, theme, theme) }) >= 0;
        all_applied && applied
    })
}

fn action_for_command(
    state: &AppearanceDialogWindowState,
    id: u16,
) -> Option<AppearanceDialogAction> {
    match id {
        DENSITY_AUTOMATIC_ID => Some(AppearanceDialogAction::Density(
            RailDensityPreference::Automatic,
        )),
        DENSITY_COMFORTABLE_ID => Some(AppearanceDialogAction::Density(
            RailDensityPreference::Comfortable,
        )),
        DENSITY_COMPACT_ID => Some(AppearanceDialogAction::Density(
            RailDensityPreference::Compact,
        )),
        DENSITY_MENU_ONLY_ID => Some(AppearanceDialogAction::Density(
            RailDensityPreference::MenuOnly,
        )),
        EMPHASIS_SUBTLE_ID => Some(AppearanceDialogAction::Emphasis(PreviewEmphasis::Subtle)),
        EMPHASIS_STANDARD_ID => Some(AppearanceDialogAction::Emphasis(PreviewEmphasis::Standard)),
        EMPHASIS_STRONG_ID => Some(AppearanceDialogAction::Emphasis(PreviewEmphasis::Strong)),
        SHOW_SEPARATORS_ID => Some(AppearanceDialogAction::ShowSeparators(is_checked(
            state.checkboxes[0],
        ))),
        SHOW_PREVIEW_TINT_ID => Some(AppearanceDialogAction::ShowPreviewTint(is_checked(
            state.checkboxes[1],
        ))),
        SHOW_EMPTY_SAFETY_ID => Some(AppearanceDialogAction::ShowEmptySafety(is_checked(
            state.checkboxes[2],
        ))),
        RESET_DEFAULTS_ID => Some(AppearanceDialogAction::ResetDefaults),
        id if id == IDOK as u16 => Some(AppearanceDialogAction::Accept),
        id if id == IDCANCEL as u16 => Some(AppearanceDialogAction::Cancel),
        _ => None,
    }
}

fn recreate_font(state: &mut AppearanceDialogWindowState) {
    let font = create_message_font(state.dpi);
    if font.is_null() {
        return;
    }
    for control in controls(state) {
        // SAFETY: every child is live and the font remains state-owned until replaced.
        unsafe { SendMessageW(control, WM_SETFONT, font as usize, 1) };
    }
    state.measured = measure_appearance_dialog(window_for_control(state.density_group), font);
    state.font.replace(font);
}

fn window_for_control(control: HWND) -> HWND {
    // SAFETY: control is a live child while dialog state is live.
    unsafe { GetParent(control) }
}

fn measure_appearance_dialog(window: HWND, font: HFONT) -> AppearanceDialogMetrics {
    let measure_many = |labels: &[&str]| {
        labels
            .iter()
            .fold((0_i32, 0_i32), |(width, height), label| {
                measure_text(window, font, label, true).map_or((width, height), |measured| {
                    (width.max(measured.0), height.max(measured.1))
                })
            })
    };
    let (option_width, option_height) = measure_many(&[
        DENSITY_GROUP_LABEL,
        DENSITY_LABELS[0],
        DENSITY_LABELS[1],
        DENSITY_LABELS[2],
        DENSITY_LABELS[3],
        EMPHASIS_GROUP_LABEL,
        EMPHASIS_LABELS[0],
        EMPHASIS_LABELS[1],
        EMPHASIS_LABELS[2],
    ]);
    let (checkbox_width, checkbox_height) =
        measure_many(&[SEPARATOR_LABEL, TINT_LABEL, EMPTY_SAFETY_LABEL]);
    let (button_width, button_height) = measure_many(&[RESET_LABEL, OK_LABEL, CANCEL_LABEL]);
    AppearanceDialogMetrics {
        text_height: option_height.max(checkbox_height),
        widest_option: option_width,
        widest_checkbox: checkbox_width,
        button_text_height: button_height,
        widest_button: button_width,
        wrapped_option_height: 0,
        wrapped_checkbox_height: 0,
        forced_explanation_height: 0,
    }
}

fn measure_wrapped_text(window: HWND, font: HFONT, text: &str, width: i32) -> i32 {
    if window.is_null() || font.is_null() || text.is_empty() || width <= 0 {
        return 0;
    }
    let text = wide(text);
    let Ok(length) = i32::try_from(text.len().saturating_sub(1)) else {
        return 0;
    };
    // SAFETY: window/font are live UI-thread handles and the DC is released
    // before return. The selected state-owned font outlives this measurement.
    let dc = unsafe { GetDC(window) };
    if dc.is_null() {
        return 0;
    }
    // SAFETY: font remains state-owned for the synchronous calculation.
    let previous = unsafe { SelectObject(dc, font) };
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: width,
        bottom: 0,
    };
    // SAFETY: UTF-16 storage and rectangle remain live for this calculation.
    let measured = unsafe {
        DrawTextW(
            dc,
            text.as_ptr(),
            length,
            &mut rect,
            DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX,
        )
    };
    if !previous.is_null() {
        // SAFETY: restore the exact object returned by SelectObject.
        unsafe { SelectObject(dc, previous) };
    }
    // SAFETY: dc was acquired from this exact window above.
    unsafe { ReleaseDC(window, dc) };
    if measured > 0 {
        (rect.bottom - rect.top).max(0)
    } else {
        0
    }
}

fn measure_wrapped_appearance_dialog(
    state: &AppearanceDialogWindowState,
    layout: AppearanceDialogLayout,
) -> AppearanceDialogMetrics {
    let font = state.font.as_raw();
    let option_width = layout.density_options[0]
        .width
        .saturating_sub(scale_dip(22, state.dpi));
    let checkbox_width = layout.checkboxes[0]
        .width
        .saturating_sub(scale_dip(22, state.dpi));
    let wrapped_option_height = DENSITY_LABELS
        .iter()
        .chain(EMPHASIS_LABELS.iter())
        .map(|label| measure_wrapped_text(state.viewport, font, label, option_width))
        .max()
        .unwrap_or(0);
    let wrapped_checkbox_height = [SEPARATOR_LABEL, TINT_LABEL, EMPTY_SAFETY_LABEL]
        .iter()
        .map(|label| measure_wrapped_text(state.viewport, font, label, checkbox_width))
        .max()
        .unwrap_or(0);
    AppearanceDialogMetrics {
        wrapped_option_height,
        wrapped_checkbox_height,
        forced_explanation_height: measure_wrapped_text(
            state.viewport,
            font,
            FORCED_COLORS_EXPLANATION,
            layout.forced_explanation.width,
        ),
        ..state.measured
    }
}

fn controls(state: &AppearanceDialogWindowState) -> impl Iterator<Item = HWND> + '_ {
    [state.density_group]
        .into_iter()
        .chain(state.density)
        .chain([state.emphasis_group])
        .chain(state.emphasis)
        .chain([state.forced_explanation])
        .chain(state.checkboxes)
        .chain([state.separator, state.reset, state.ok, state.cancel])
}

fn body_controls(state: &AppearanceDialogWindowState) -> impl Iterator<Item = HWND> + '_ {
    [state.density_group]
        .into_iter()
        .chain(state.density)
        .chain([state.emphasis_group])
        .chain(state.emphasis)
        .chain([state.forced_explanation])
        .chain(state.checkboxes)
        .chain([state.separator])
}

#[derive(Clone, Copy)]
enum AppearanceDialogPlacement {
    CenterOwner,
    KeepCurrent,
    DpiSuggested(RECT),
}

fn arrange_dialog(
    window: HWND,
    state: &mut AppearanceDialogWindowState,
    placement: AppearanceDialogPlacement,
) -> bool {
    let anchor = match placement {
        AppearanceDialogPlacement::CenterOwner => state.owner,
        AppearanceDialogPlacement::KeepCurrent | AppearanceDialogPlacement::DpiSuggested(_) => {
            window
        }
    };
    // SAFETY: anchor/suggested rectangle remain live for this value query.
    let monitor = match placement {
        AppearanceDialogPlacement::DpiSuggested(suggested) => {
            // SAFETY: suggested is copied RECT storage valid for this query.
            unsafe { MonitorFromRect(&suggested, MONITOR_DEFAULTTONEAREST) }
        }
        _ => {
            // SAFETY: anchor is a live top-level owner or dialog HWND.
            unsafe { MonitorFromWindow(anchor, MONITOR_DEFAULTTONEAREST) }
        }
    };
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..MONITORINFO::default()
    };
    if monitor.is_null() {
        return false;
    }
    // SAFETY: monitor is live and info is writable with its exact size.
    if unsafe { GetMonitorInfoW(monitor, &mut info) } == 0 {
        return false;
    }
    let work_width = info.rcWork.right.saturating_sub(info.rcWork.left).max(1);
    let work_height = info.rcWork.bottom.saturating_sub(info.rcWork.top).max(1);
    let style = WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN;
    let mut chrome = RECT::default();
    // SAFETY: chrome is writable RECT storage and style/DPI are copied values.
    if unsafe { AdjustWindowRectExForDpi(&mut chrome, style, 0, WS_EX_TOOLWINDOW, state.dpi) } == 0
    {
        return false;
    }
    let maximum_client_width = work_width
        .saturating_sub(chrome.right.saturating_sub(chrome.left))
        .max(1);
    let maximum_client_height = work_height
        .saturating_sub(chrome.bottom.saturating_sub(chrome.top))
        .max(1);
    let show_forced_explanation = matches!(
        state.model.forced_colors(),
        ForcedColorsState::ActiveOrUnknown
    );
    let Some(preliminary) = calculate_appearance_dialog_layout(
        state.dpi,
        maximum_client_width,
        maximum_client_height,
        show_forced_explanation,
        state.measured,
    ) else {
        return false;
    };
    let measured = measure_wrapped_appearance_dialog(state, preliminary);
    let Some(layout) = calculate_appearance_dialog_layout(
        state.dpi,
        maximum_client_width,
        maximum_client_height,
        show_forced_explanation,
        measured,
    ) else {
        return false;
    };
    let mut outer = RECT {
        left: 0,
        top: 0,
        right: layout.client.width,
        bottom: layout.client.height,
    };
    // SAFETY: outer is writable desired-client geometry for the same style/DPI.
    if unsafe { AdjustWindowRectExForDpi(&mut outer, style, 0, WS_EX_TOOLWINDOW, state.dpi) } == 0 {
        return false;
    }
    let width = (outer.right - outer.left).min(work_width).max(1);
    let height = (outer.bottom - outer.top).min(work_height).max(1);
    let mut anchor_rect = match placement {
        AppearanceDialogPlacement::DpiSuggested(suggested) => suggested,
        _ => RECT::default(),
    };
    if !matches!(placement, AppearanceDialogPlacement::DpiSuggested(_)) {
        // SAFETY: anchor is live and anchor_rect is writable for this value query.
        if unsafe { GetWindowRect(anchor, &mut anchor_rect) } == 0 {
            return false;
        }
    }
    let x = anchor_rect
        .left
        .saturating_add((anchor_rect.right - anchor_rect.left - width) / 2)
        .clamp(info.rcWork.left, info.rcWork.right.saturating_sub(width));
    let y = anchor_rect
        .top
        .saturating_add((anchor_rect.bottom - anchor_rect.top - height) / 2)
        .clamp(info.rcWork.top, info.rcWork.bottom.saturating_sub(height));
    // SAFETY: window is live and outer geometry is clamped to the monitor work area.
    if unsafe {
        SetWindowPos(
            window,
            null_mut(),
            x,
            y,
            width,
            height,
            SWP_NOACTIVATE | SWP_NOZORDER,
        )
    } == 0
    {
        return false;
    }
    state.layout = Some(layout);
    state.scroll_y = clamp_appearance_dialog_scroll(layout, state.scroll_y);
    apply_appearance_dialog_layout(state, layout);
    true
}

fn body_rects(layout: AppearanceDialogLayout) -> [LayoutRect; 14] {
    [
        layout.density_group,
        layout.density_options[0],
        layout.density_options[1],
        layout.density_options[2],
        layout.density_options[3],
        layout.emphasis_group,
        layout.emphasis_options[0],
        layout.emphasis_options[1],
        layout.emphasis_options[2],
        layout.forced_explanation,
        layout.checkboxes[0],
        layout.checkboxes[1],
        layout.checkboxes[2],
        layout.separator,
    ]
}

fn apply_appearance_dialog_layout(
    state: &AppearanceDialogWindowState,
    layout: AppearanceDialogLayout,
) {
    // DeferWindowPos batches child coordinates relative to their shared parent.
    // Keep dialog children and viewport children in separate batches; mixing
    // parents can report success while leaving zero-sized child geometry.
    apply_appearance_deferred_layout(&[
        (state.viewport, layout.body_viewport),
        (state.reset, layout.reset),
        (state.ok, layout.ok),
        (state.cancel, layout.cancel),
    ]);
    let body_windows = body_controls(state)
        .zip(body_rects(layout))
        .map(|(window, mut rect)| {
            rect.y = rect.y.saturating_sub(state.scroll_y);
            (window, rect)
        })
        .collect::<Vec<_>>();
    apply_appearance_deferred_layout(&body_windows);
    let scroll = SCROLLINFO {
        cbSize: size_of::<SCROLLINFO>() as u32,
        fMask: SIF_RANGE | SIF_PAGE | SIF_POS,
        nMin: 0,
        nMax: layout.body_content_height.saturating_sub(1),
        nPage: u32::try_from(layout.scroll_page).unwrap_or(u32::MAX),
        nPos: state.scroll_y,
        ..SCROLLINFO::default()
    };
    // SAFETY: viewport is live and scroll contains copied bounded values.
    unsafe { SetScrollInfo(state.viewport, SB_VERT, &raw const scroll, 1) };
    // Redraw the dialog rather than only the viewport: both batches use
    // SWP_NOREDRAW, and footer controls are siblings of the viewport.
    // SAFETY: viewport is live and its direct parent is the live dialog.
    let dialog = unsafe { GetParent(state.viewport) };
    let redraw_target = if dialog.is_null() {
        state.viewport
    } else {
        dialog
    };
    // SAFETY: target and all dialog/viewport children are live after layout.
    unsafe {
        RedrawWindow(
            redraw_target,
            null(),
            null_mut(),
            RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
        )
    };
}

fn apply_appearance_deferred_layout(windows: &[(HWND, LayoutRect)]) {
    let count = i32::try_from(windows.len()).unwrap_or(i32::MAX);
    // SAFETY: count is the bounded number of live dialog controls below.
    let mut batch = unsafe { BeginDeferWindowPos(count) };
    if !batch.is_null() {
        for (window, rect) in windows {
            // SAFETY: batch/window/rect remain live through this synchronous operation.
            batch = unsafe {
                DeferWindowPos(
                    batch,
                    *window,
                    null_mut(),
                    rect.x,
                    rect.y,
                    rect.width,
                    rect.height,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW,
                )
            };
            if batch.is_null() {
                break;
            }
        }
    }
    if !batch.is_null() {
        // SAFETY: EndDeferWindowPos consumes the live final batch once.
        if unsafe { EndDeferWindowPos(batch) } != 0 {
            return;
        }
    }
    for (window, rect) in windows {
        // SAFETY: fallback applies identical bounded geometry without repaint.
        unsafe {
            SetWindowPos(
                *window,
                null_mut(),
                rect.x,
                rect.y,
                rect.width,
                rect.height,
                SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW,
            )
        };
    }
}

fn set_appearance_dialog_scroll(state: &mut AppearanceDialogWindowState, scroll_y: i32) -> bool {
    let Some(layout) = state.layout else {
        return false;
    };
    let scroll_y = clamp_appearance_dialog_scroll(layout, scroll_y);
    if scroll_y == state.scroll_y {
        return false;
    }
    state.scroll_y = scroll_y;
    apply_appearance_dialog_layout(state, layout);
    true
}

fn ensure_appearance_control_visible(
    state: &mut AppearanceDialogWindowState,
    control: HWND,
) -> bool {
    let Some(layout) = state.layout else {
        return false;
    };
    let Some((_, rect)) = body_controls(state)
        .zip(body_rects(layout))
        .find(|(candidate, _)| *candidate == control)
    else {
        return false;
    };
    let target = if rect.y < state.scroll_y {
        rect.y
    } else if rect.bottom() > state.scroll_y.saturating_add(layout.scroll_page) {
        rect.bottom().saturating_sub(layout.scroll_page)
    } else {
        state.scroll_y
    };
    set_appearance_dialog_scroll(state, target)
}

fn appearance_control_disabled_by_forced_colors(
    state: &AppearanceDialogWindowState,
    control: HWND,
) -> bool {
    state.emphasis.contains(&control) || state.checkboxes[1] == control
}

fn schedule_appearance_focus_repair(
    window: HWND,
    state: &AppearanceDialogWindowState,
    force_initial: bool,
) {
    // SAFETY: window remains owned by this dialog state and the message carries
    // only a boolean flag plus the copied session identifier.
    unsafe {
        PostMessageW(
            window,
            WM_APP_APPEARANCE_RESTORE_FOCUS,
            usize::from(force_initial),
            state.session_id as isize,
        )
    };
}

fn appearance_dialog_state_slot(window: HWND) -> *mut AppearanceDialogStateSlot {
    if window.is_null() {
        return null_mut();
    }
    // SAFETY: this value query reads only the slot pointer published for this
    // exact dialog and creates no Rust reference.
    unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) as *mut AppearanceDialogStateSlot }
}

fn try_appearance_dialog_state(
    window: HWND,
) -> Option<CallbackStateLease<AppearanceDialogWindowState>> {
    // SAFETY: dialog publication is cleared before reclamation and all callback
    // access is confined to the owning UI thread.
    unsafe { CallbackState::try_lease(appearance_dialog_state_slot(window)) }
}

unsafe extern "system" fn appearance_viewport_subclass(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _subclass_id: usize,
    dialog_ref: usize,
) -> LRESULT {
    if message == WM_NCDESTROY {
        // SAFETY: remove this exact callback/id pair before the parent-owned
        // dialog state can be reclaimed.
        unsafe {
            RemoveWindowSubclass(
                window,
                Some(appearance_viewport_subclass),
                APPEARANCE_VIEWPORT_SUBCLASS_ID,
            )
        };
        // SAFETY: the standard STATIC receives final destruction unchanged.
        return unsafe { DefSubclassProc(window, message, wparam, lparam) };
    }
    if dialog_ref == 0 {
        // SAFETY: null refdata cannot be dereferenced; retain standard handling.
        return unsafe { DefSubclassProc(window, message, wparam, lparam) };
    }
    match message {
        WM_VSCROLL => {
            let Some(mut state_lease) = try_appearance_dialog_state(dialog_ref as HWND) else {
                // SAFETY: a nested same-state entry retains standard handling
                // without constructing a second Rust state reference.
                return unsafe { DefSubclassProc(window, message, wparam, lparam) };
            };
            let state = state_lease.state_mut();
            let command = (wparam & 0xFFFF) as i32;
            let line = scale_dip(24, state.dpi).max(state.measured.text_height);
            let page = state.layout.map_or(line, |layout| {
                layout.scroll_page.saturating_sub(line).max(line)
            });
            let target = match command {
                SB_TOP => 0,
                SB_BOTTOM => i32::MAX,
                SB_LINEUP => state.scroll_y.saturating_sub(line),
                SB_LINEDOWN => state.scroll_y.saturating_add(line),
                SB_PAGEUP => state.scroll_y.saturating_sub(page),
                SB_PAGEDOWN => state.scroll_y.saturating_add(page),
                SB_THUMBPOSITION | SB_THUMBTRACK => {
                    let mut info = SCROLLINFO {
                        cbSize: size_of::<SCROLLINFO>() as u32,
                        fMask: SIF_TRACKPOS,
                        ..SCROLLINFO::default()
                    };
                    // SAFETY: viewport is live and info is exact writable storage.
                    if unsafe { GetScrollInfo(window, SB_VERT, &mut info) } != 0 {
                        info.nTrackPos
                    } else {
                        state.scroll_y
                    }
                }
                SB_ENDSCROLL => state.scroll_y,
                _ => state.scroll_y,
            };
            set_appearance_dialog_scroll(state, target);
            0
        }
        WM_MOUSEWHEEL => {
            let Some(mut state_lease) = try_appearance_dialog_state(dialog_ref as HWND) else {
                // SAFETY: retain standard handling while the dialog state is busy.
                return unsafe { DefSubclassProc(window, message, wparam, lparam) };
            };
            let state = state_lease.state_mut();
            let delta = ((wparam >> 16) as u16) as i16 as i32;
            let line = scale_dip(24, state.dpi).max(state.measured.text_height);
            let steps = delta / 120;
            set_appearance_dialog_scroll(
                state,
                state
                    .scroll_y
                    .saturating_sub(steps.saturating_mul(line).saturating_mul(3)),
            );
            0
        }
        WM_COMMAND | WM_NOTIFY | WM_CTLCOLORBTN | WM_CTLCOLORSTATIC | WM_DRAWITEM => {
            if message == WM_COMMAND && ((wparam >> 16) & 0xFFFF) as u32 == BN_SETFOCUS {
                if let Some(mut state_lease) = try_appearance_dialog_state(dialog_ref as HWND) {
                    ensure_appearance_control_visible(state_lease.state_mut(), lparam as HWND);
                } else {
                    return 0;
                }
            }
            // SAFETY: the immediate parent is the live dialog; notification
            // payloads remain valid for this synchronous forwarding call.
            let parent = unsafe { GetParent(window) };
            if parent.is_null() {
                0
            } else {
                // SAFETY: parent is live and payload lifetime is synchronous.
                unsafe { SendMessageW(parent, message, wparam, lparam) }
            }
        }
        WM_ERASEBKGND => {
            let Some(state_lease) = try_appearance_dialog_state(dialog_ref as HWND) else {
                // SAFETY: retain standard erasing while dialog state is busy.
                return unsafe { DefSubclassProc(window, message, wparam, lparam) };
            };
            let state = state_lease.state();
            let mut rect = RECT::default();
            // SAFETY: viewport/DC are live for this synchronous erase callback.
            unsafe { GetClientRect(window, &mut rect) };
            let brush = state.appearance_resources.as_ref().map_or_else(
                || {
                    // SAFETY: system color brush is process-global and cached.
                    unsafe { GetSysColorBrush(COLOR_WINDOW) }
                },
                AppearanceResources::dialog_brush,
            );
            // SAFETY: callback DC, client rectangle, and brush are live.
            unsafe { FillRect(wparam as HDC, &rect, brush) };
            1
        }
        _ => {
            // SAFETY: all unowned messages retain standard STATIC handling.
            unsafe { DefSubclassProc(window, message, wparam, lparam) }
        }
    }
}

unsafe extern "system" fn appearance_dialog_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        let create = lparam as *const CREATESTRUCTW;
        if !create.is_null() {
            // SAFETY: WM_NCCREATE supplies readable CREATESTRUCTW storage whose
            // lpCreateParams points to the live stack init for this call.
            let init = unsafe { (*create).lpCreateParams as *mut AppearanceDialogInit };
            if !init.is_null() {
                // SAFETY: init and its state/adopted pointers remain live for
                // this synchronous CreateWindowExW callback.
                unsafe {
                    *(*init).adopted = true;
                    SetWindowLongPtrW(window, GWLP_USERDATA, (*init).state as isize);
                }
            }
        }
    }
    let state_slot = appearance_dialog_state_slot(window);
    if message == WM_NCDESTROY {
        if !state_slot.is_null() {
            // SAFETY: this final callback owns the publication slot and clears
            // it before immediate or deferred unique reclamation.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
            // SAFETY: publication is cleared. State Drop performs any fail-closed
            // Cancel notification only after an outer lease/reference has ended.
            unsafe { CallbackState::request_reclaim(state_slot) };
        }
        // SAFETY: arguments are unchanged values from the final callback.
        return unsafe { DefWindowProcW(window, message, wparam, lparam) };
    }
    // SAFETY: the slot is the current UI-thread publication and remains live
    // until this callback either releases or defers reclamation of its lease.
    let Some(mut state_lease) = (unsafe { CallbackState::try_lease(state_slot) }) else {
        if message == WM_COMMAND || message == WM_CLOSE || message >= WM_APP {
            return 0;
        }
        // SAFETY: standard handling receives copied callback arguments while a
        // same-state nested entry is rejected before constructing a reference.
        return unsafe { DefWindowProcW(window, message, wparam, lparam) };
    };
    let state_ptr = state_lease.state_mut() as *mut AppearanceDialogWindowState;
    match message {
        WM_CREATE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
            let state = unsafe { &mut *state_ptr };
            if create_controls(window, state).is_err() {
                return -1;
            }
            // SAFETY: window is the live appearance dialog HWND.
            let dpi = unsafe { GetDpiForWindow(window) };
            state.dpi = dpi.max(BASE_DPI);
            recreate_font(state);
            sync_controls(state);
            apply_dialog_appearance(window, state);
            if !arrange_dialog(window, state, AppearanceDialogPlacement::CenterOwner) {
                return -1;
            }
            schedule_appearance_focus_repair(window, state, true);
            0
        }
        WM_COMMAND if !state_ptr.is_null() => {
            let id = (wparam & 0xFFFF) as u16;
            let notification = ((wparam >> 16) & 0xFFFF) as u32;
            if notification == BN_CLICKED {
                let close = {
                    // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
                    let state = unsafe { &mut *state_ptr };
                    action_for_command(state, id)
                        .is_some_and(|action| apply_action(window, state, action))
                };
                if close {
                    drop(state_lease);
                    // SAFETY: the state lease and reference ended above, so
                    // destruction can reclaim immediately without aliasing.
                    unsafe { DestroyWindow(window) };
                    return 0;
                }
            }
            0
        }
        WM_NOTIFY if !state_ptr.is_null() => {
            // SAFETY: state_ptr is live dialog state and lparam is the
            // synchronous button custom-draw notification.
            let state = unsafe { &*state_ptr };
            if let Some(result) =
                draw_custom_button(state.appearance_resources.as_ref(), state.ok, lparam)
            {
                result
            } else {
                // SAFETY: unrelated notifications retain system handling.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_ERASEBKGND if !state_ptr.is_null() => {
            // SAFETY: state_ptr and paint DC are live for this callback.
            let state = unsafe { &*state_ptr };
            let mut rect = RECT::default();
            // SAFETY: window/DC are live and rect is writable.
            unsafe { GetClientRect(window, &mut rect) };
            let brush = state.appearance_resources.as_ref().map_or_else(
                || {
                    // SAFETY: system brush is process-global and cached.
                    unsafe { GetSysColorBrush(COLOR_WINDOW) }
                },
                AppearanceResources::dialog_brush,
            );
            // SAFETY: callback DC and brush are live; rect is client-bounded.
            unsafe { FillRect(wparam as HDC, &rect, brush) };
            1
        }
        WM_DRAWITEM if !state_ptr.is_null() => {
            // SAFETY: state_ptr is live and draw payload is synchronous.
            let state = unsafe { &*state_ptr };
            let resources = state.appearance_resources.as_ref();
            if draw_owner_separator(resources, state.separator, lparam)
                || draw_owner_button(resources, lparam)
            {
                1
            } else {
                // SAFETY: unrecognized payload retains system handling.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_CTLCOLORSTATIC | WM_CTLCOLORBTN if !state_ptr.is_null() => {
            // SAFETY: state_ptr is live and the optional resources outlive this callback.
            let resources = unsafe { (*state_ptr).appearance_resources.as_ref() };
            if let Some(resources) = resources {
                let palette = resources.palette();
                // SAFETY: wparam is the callback-owned control DC.
                unsafe {
                    SetTextColor(wparam as HDC, palette.text_primary);
                    SetBkMode(wparam as HDC, TRANSPARENT as i32);
                }
                resources.dialog_brush() as LRESULT
            } else {
                // SAFETY: system mode retains standard control color handling.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_CLOSE if !state_ptr.is_null() => {
            {
                // SAFETY: state_ptr is the dialog-owned Box for this close callback.
                let state = unsafe { &mut *state_ptr };
                let _close = apply_action(window, state, AppearanceDialogAction::Cancel);
            }
            drop(state_lease);
            // SAFETY: the state lease and reference ended above, so destruction
            // may reclaim the dialog-owned slot without aliasing.
            unsafe { DestroyWindow(window) };
            0
        }
        WM_DPICHANGED if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
            let state = unsafe { &mut *state_ptr };
            state.dpi = ((wparam & 0xFFFF) as u32).max(BASE_DPI);
            recreate_font(state);
            let placement = if lparam == 0 {
                AppearanceDialogPlacement::KeepCurrent
            } else {
                // SAFETY: WM_DPICHANGED supplies a readable suggested RECT for
                // the duration of this synchronous callback.
                AppearanceDialogPlacement::DpiSuggested(unsafe { *(lparam as *const RECT) })
            };
            arrange_dialog(window, state, placement);
            schedule_appearance_focus_repair(window, state, false);
            0
        }
        WM_SETTINGCHANGE | WM_FONTCHANGE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
            let state = unsafe { &mut *state_ptr };
            // SAFETY: window is the live appearance dialog HWND.
            state.dpi = unsafe { GetDpiForWindow(window) }.max(BASE_DPI);
            recreate_font(state);
            arrange_dialog(window, state, AppearanceDialogPlacement::KeepCurrent);
            schedule_appearance_focus_repair(window, state, false);
            0
        }
        WM_APP_APPEARANCE_ACCESSIBILITY if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
            let state = unsafe { &mut *state_ptr };
            if u32::try_from(lparam).ok() == Some(state.session_id) {
                let (forced_colors, system_theme) = unpack_appearance_environment(wparam);
                // SAFETY: GetFocus returns only a borrowed HWND. Capture whether
                // Forced Colors will disable it before EnableWindow clears focus.
                let focused = unsafe { GetFocus() };
                let repair_disabled_focus = !forced_colors.custom_colors_enabled()
                    && appearance_control_disabled_by_forced_colors(state, focused);
                state.model.set_forced_colors(forced_colors);
                state.system_theme = system_theme;
                sync_controls(state);
                apply_dialog_appearance(window, state);
                arrange_dialog(window, state, AppearanceDialogPlacement::KeepCurrent);
                schedule_appearance_focus_repair(window, state, repair_disabled_focus);
            }
            0
        }
        WM_APP_APPEARANCE_RESTORE_FOCUS if !state_ptr.is_null() => {
            let session_matches = u32::try_from(lparam)
                .ok()
                // SAFETY: state_ptr is the live dialog-owned Box on this UI thread.
                .is_some_and(|session_id| session_id == unsafe { (*state_ptr).session_id });
            if !session_matches {
                return 0;
            }
            let target = {
                // SAFETY: state_ptr is uniquely borrowed only inside this block;
                // the borrow ends before any SetFocus call below.
                let state = unsafe { &mut *state_ptr };
                // SAFETY: GetFocus returns a borrowed HWND and retains no storage.
                let focused = unsafe { GetFocus() };
                let focused_is_body = body_controls(state).any(|control| control == focused);
                if focused_is_body {
                    // SAFETY: focused is one of the live body controls above.
                    if unsafe { IsWindowEnabled(focused) } != 0 {
                        ensure_appearance_control_visible(state, focused);
                        null_mut()
                    } else {
                        ensure_appearance_control_visible(state, state.density[0]);
                        state.density[0]
                    }
                } else if wparam != 0 {
                    ensure_appearance_control_visible(state, state.density[0]);
                    state.density[0]
                } else {
                    null_mut()
                }
            };
            drop(state_lease);
            if !target.is_null() {
                // SAFETY: target is a live enabled dialog child copied only after
                // the mutable state borrow ended, preventing reentrant aliasing.
                unsafe { SetFocus(target) };
            }
            0
        }
        WM_APP_APPEARANCE_DISMISS if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
            let state = unsafe { &mut *state_ptr };
            if u32::try_from(lparam).ok() == Some(state.session_id) {
                state.finished = true;
            }
            0
        }
        WM_APP_APPEARANCE_ARM if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box on this UI thread. This
            // transition never calls or posts to the owner.
            let state = unsafe { &mut *state_ptr };
            if u32::try_from(lparam).ok() == Some(state.session_id) && !state.finished {
                state.armed = true;
                1
            } else {
                0
            }
        }
        _ => {
            // SAFETY: arguments are unchanged values from the active callback.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
        }
    }
}

#[cfg(test)]
mod native_tests {
    use super::*;
    use windows_sys::Win32::Graphics::Gdi::{GetDC, ReleaseDC};
    use windows_sys::Win32::System::SystemServices::{SS_OWNERDRAW, SS_TYPEMASK};
    use windows_sys::Win32::UI::Controls::{
        CDIS_DEFAULT, GetWindowTheme, NM_CUSTOMDRAW, NMCUSTOMDRAW,
    };
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::VK_RETURN;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        BM_CLICK, BS_TYPEMASK, GWL_EXSTYLE, GWL_STYLE, GetClientRect, GetWindowLongPtrW,
        IsDialogMessageW, MSG, WM_KEYDOWN,
    };

    #[test]
    fn appearance_copy_names_the_current_settings_exactly() {
        assert_eq!(APPEARANCE_DIALOG_TITLE, "DarkReNamer - 모양 설정");
        assert_eq!(DENSITY_GROUP_LABEL, "명령 버튼 배치");
        assert_eq!(EMPHASIS_GROUP_LABEL, "변경 후 이름 강조");
        assert_eq!(SEPARATOR_LABEL, "명령 버튼 그룹 구분선 표시");
        assert_eq!(TINT_LABEL, "변경 후 이름 셀 배경 강조");
        assert_eq!(EMPTY_SAFETY_LABEL, "빈 목록에서 안전 안내 표시");
        assert_eq!(
            FORCED_COLORS_EXPLANATION,
            "고대비가 활성화되어 변경 후 이름의 글자와 셀 배경은 시스템 색상을 사용합니다."
        );
    }

    #[test]
    fn appearance_dialog_rejects_nested_state_lease() -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: null requests the current process module.
        let instance = unsafe { GetModuleHandleW(null()) };
        // SAFETY: the system STATIC class and current module remain live for
        // this hidden, test-owned top-level owner.
        let owner = unsafe {
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
                instance,
                null_mut(),
            )
        };
        if owner.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let dialog = create_appearance_dialog_window(
            owner,
            7,
            UiAppearance::default(),
            ForcedColorsState::Inactive,
            Some(ResolvedTheme::Light),
        )?;
        let outer = try_appearance_dialog_state(dialog)
            .ok_or_else(|| io::Error::other("outer appearance lease was rejected"))?;
        assert!(try_appearance_dialog_state(dialog).is_none());
        drop(outer);
        let reacquired = try_appearance_dialog_state(dialog)
            .ok_or_else(|| io::Error::other("appearance lease did not release"))?;
        drop(reacquired);
        // SAFETY: both windows are test-owned and no state lease remains.
        unsafe {
            DestroyWindow(dialog);
            DestroyWindow(owner);
        }
        Ok(())
    }

    #[test]
    fn default_ok_keeps_native_contract_and_enter_activation()
    -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: null requests the current process module.
        let instance = unsafe { GetModuleHandleW(null()) };
        // SAFETY: the system STATIC class and current module remain live for
        // this hidden test-owned top-level window.
        let owner = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                800,
                600,
                null_mut(),
                null_mut(),
                instance,
                null_mut(),
            )
        };
        if owner.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let dialog = create_appearance_dialog_window(
            owner,
            1,
            UiAppearance::default(),
            ForcedColorsState::Inactive,
            Some(ResolvedTheme::Light),
        )?;
        let Some(state_lease) = try_appearance_dialog_state(dialog) else {
            // SAFETY: both windows are test-owned and live.
            unsafe {
                DestroyWindow(dialog);
                DestroyWindow(owner);
            }
            return Err(io::Error::other("appearance dialog state is missing").into());
        };
        let (
            viewport,
            ok,
            cancel,
            radio,
            emphasis_control,
            menu_only,
            density_group,
            last_checkbox,
            separator,
        ) = {
            let state = state_lease.state();
            (
                state.viewport,
                state.ok,
                state.cancel,
                state.density[0],
                state.emphasis[0],
                state.density[3],
                state.density_group,
                state.checkboxes[2],
                state.separator,
            )
        };
        drop(state_lease);
        // SAFETY: owner/dialog/radio are live test-owned windows on this thread;
        // activation makes subsequent focus-transfer assertions meaningful.
        unsafe {
            ShowWindow(owner, SW_SHOW);
            SetForegroundWindow(dialog);
            SetFocus(radio);
        }
        // SAFETY: viewport and controls are live and these are value-only queries.
        let viewport_style = unsafe { GetWindowLongPtrW(viewport, GWL_STYLE) } as u32;
        assert_eq!(
            viewport_style & (WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS),
            WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS
        );
        // SAFETY: all queried HWNDs are live and these calls retain no storage.
        let (viewport_ex_style, density_parent, separator_parent, ok_parent, cancel_parent) = unsafe {
            (
                GetWindowLongPtrW(viewport, GWL_EXSTYLE) as u32,
                GetParent(density_group),
                GetParent(separator),
                GetParent(ok),
                GetParent(cancel),
            )
        };
        assert_ne!(viewport_ex_style & WS_EX_CONTROLPARENT, 0);
        assert_eq!(density_parent, viewport);
        assert_eq!(separator_parent, viewport);
        assert_eq!(ok_parent, dialog);
        assert_eq!(cancel_parent, dialog);
        let mut viewport_rect = RECT::default();
        let mut ok_rect = RECT::default();
        // SAFETY: viewport/OK are live and both rectangles are writable.
        assert_ne!(unsafe { GetWindowRect(viewport, &mut viewport_rect) }, 0);
        // SAFETY: same value-only query for the fixed footer OK button.
        assert_ne!(unsafe { GetWindowRect(ok, &mut ok_rect) }, 0);
        assert!(viewport_rect.right > viewport_rect.left);
        assert!(viewport_rect.bottom > viewport_rect.top);
        assert!(ok_rect.right > ok_rect.left);
        assert!(ok_rect.bottom > ok_rect.top);
        let mut viewport_scroll = SCROLLINFO {
            cbSize: size_of::<SCROLLINFO>() as u32,
            fMask: SIF_RANGE | SIF_PAGE | SIF_POS,
            ..SCROLLINFO::default()
        };
        // SAFETY: viewport is a live WS_VSCROLL window and the structure is
        // exact writable storage for its vertical window scrollbar.
        let got_scroll = unsafe { GetScrollInfo(viewport, SB_VERT, &mut viewport_scroll) };
        assert_ne!(got_scroll, 0);
        assert!(viewport_scroll.nPage > 0);
        // SAFETY: ok is a live native BUTTON and style is an integral query.
        let style = unsafe { GetWindowLongPtrW(ok, GWL_STYLE) } as u32;
        assert_eq!(style & BS_TYPEMASK as u32, BS_DEFPUSHBUTTON as u32);
        // SAFETY: density_group is a live BUTTON and style is an integral query.
        let group_style = unsafe { GetWindowLongPtrW(density_group, GWL_STYLE) } as u32;
        assert_eq!(group_style & BS_TYPEMASK as u32, BS_GROUPBOX as u32);
        // SAFETY: separator is a live STATIC and style is an integral query.
        let separator_style = unsafe { GetWindowLongPtrW(separator, GWL_STYLE) } as u32;
        assert_eq!(separator_style & SS_TYPEMASK, SS_OWNERDRAW);

        // SAFETY: separator is live and the returned DC is released below.
        let separator_dc = unsafe { GetDC(separator) };
        if separator_dc.is_null() {
            // SAFETY: both windows are test-owned and live.
            unsafe {
                DestroyWindow(dialog);
                DestroyWindow(owner);
            }
            return Err(io::Error::last_os_error().into());
        }
        let mut null_target = DRAWITEMSTRUCT {
            CtlType: ODT_STATIC,
            hDC: separator_dc,
            hwndItem: null_mut(),
            ..DRAWITEMSTRUCT::default()
        };
        let state_lease = try_appearance_dialog_state(dialog)
            .ok_or_else(|| io::Error::other("appearance dialog state is busy"))?;
        let resources = state_lease.state().appearance_resources.as_ref();
        assert!(!draw_owner_separator(
            resources,
            null_mut(),
            (&raw mut null_target) as LPARAM,
        ));
        let mut wrong_target = DRAWITEMSTRUCT {
            CtlType: ODT_STATIC,
            hDC: separator_dc,
            hwndItem: ok,
            ..DRAWITEMSTRUCT::default()
        };
        assert!(!draw_owner_separator(
            resources,
            separator,
            (&raw mut wrong_target) as LPARAM,
        ));
        let mut null_dc = DRAWITEMSTRUCT {
            CtlType: ODT_STATIC,
            hwndItem: separator,
            ..DRAWITEMSTRUCT::default()
        };
        assert!(!draw_owner_separator(
            resources,
            separator,
            (&raw mut null_dc) as LPARAM,
        ));
        let mut separator_draw = DRAWITEMSTRUCT {
            CtlType: ODT_STATIC,
            hDC: separator_dc,
            hwndItem: separator,
            ..DRAWITEMSTRUCT::default()
        };
        // SAFETY: separator is live and its client rectangle is writable.
        unsafe { GetClientRect(separator, &mut separator_draw.rcItem) };
        assert!(draw_owner_separator(
            resources,
            separator,
            (&raw mut separator_draw) as LPARAM,
        ));
        drop(state_lease);
        // SAFETY: separator_dc came from this exact live control.
        unsafe { ReleaseDC(separator, separator_dc) };

        // SAFETY: ok remains live and the returned DC is released below.
        let dc = unsafe { GetDC(ok) };
        if dc.is_null() {
            // SAFETY: both windows are test-owned and live.
            unsafe {
                DestroyWindow(dialog);
                DestroyWindow(owner);
            }
            return Err(io::Error::last_os_error().into());
        }
        let mut custom = NMCUSTOMDRAW::default();
        custom.hdr.hwndFrom = ok;
        custom.hdr.code = NM_CUSTOMDRAW;
        custom.dwDrawStage = CDDS_PREPAINT;
        custom.uItemState = CDIS_DEFAULT;
        custom.hdc = dc;
        // SAFETY: ok is live and rc is writable.
        unsafe { GetClientRect(ok, &mut custom.rc) };
        let state_lease = try_appearance_dialog_state(dialog)
            .ok_or_else(|| io::Error::other("appearance dialog state is busy"))?;
        let resources = state_lease.state().appearance_resources.as_ref();
        assert_eq!(
            draw_custom_button(
                resources,
                ok,
                (&raw mut custom as *mut NMCUSTOMDRAW) as LPARAM,
            ),
            Some(CDRF_SKIPDEFAULT as LRESULT)
        );
        drop(state_lease);
        // SAFETY: dc came from this exact live button.
        unsafe { ReleaseDC(ok, dc) };

        // SAFETY: density_group remains live and the DC is released below.
        let group_dc = unsafe { GetDC(density_group) };
        if group_dc.is_null() {
            // SAFETY: both windows are test-owned and live.
            unsafe {
                DestroyWindow(dialog);
                DestroyWindow(owner);
            }
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: the subclass copies no pointer and paints synchronously into
        // this exact live group-box DC.
        let painted = unsafe { SendMessageW(density_group, WM_PRINTCLIENT, group_dc as WPARAM, 0) };
        assert_eq!(painted, 1);
        // SAFETY: group_dc came from this exact live control.
        unsafe { ReleaseDC(density_group, group_dc) };

        assert_eq!(window_text(menu_only), LegacyText::from(DENSITY_LABELS[3]));
        // SAFETY: menu_only is live and the borrowed theme handle query retains
        // no caller storage. Custom colors require the classic paint path.
        assert_eq!(unsafe { GetWindowTheme(menu_only) }, 0);

        // Constrain the pure viewport page to exercise scrollbar commands and
        // focus visibility without relying on the host monitor dimensions.
        {
            let mut state_lease = try_appearance_dialog_state(dialog)
                .ok_or_else(|| io::Error::other("appearance dialog state is busy"))?;
            let state = state_lease.state_mut();
            let Some(mut layout) = state.layout else {
                return Err(io::Error::other("appearance layout is missing").into());
            };
            layout.body_viewport.height = scale_dip(70, state.dpi);
            layout.scroll_page = layout.body_viewport.height;
            layout.scroll_max = layout
                .body_content_height
                .saturating_sub(layout.scroll_page);
            state.layout = Some(layout);
            state.scroll_y = 0;
            apply_appearance_dialog_layout(state, layout);
        }
        // SAFETY: the constrained layout has a nonzero range, so Windows must
        // expose the vertical window scrollbar style for the live viewport.
        let constrained_style = unsafe { GetWindowLongPtrW(viewport, GWL_STYLE) } as u32;
        assert_ne!(constrained_style & WS_VSCROLL, 0);
        // SAFETY: viewport forwards scalar/null notifications synchronously.
        unsafe {
            SendMessageW(viewport, WM_NOTIFY, 0, 0);
            SendMessageW(viewport, WM_DRAWITEM, 0, 0);
            SendMessageW(viewport, WM_VSCROLL, SB_BOTTOM as WPARAM, 0);
        }
        let bottom_scroll = try_appearance_dialog_state(dialog)
            .ok_or_else(|| io::Error::other("appearance dialog state is busy"))?
            .state()
            .scroll_y;
        assert!(bottom_scroll > 0);
        // SAFETY: focusing the live last checkbox exercises the real forwarded
        // BN_SETFOCUS path. Scrolling back to the top leaves that control focused
        // but hidden so the pointer-free relayout repair message must reveal it.
        unsafe {
            SetFocus(last_checkbox);
            SendMessageW(viewport, WM_VSCROLL, SB_TOP as WPARAM, 0);
            SendMessageW(dialog, WM_APP_APPEARANCE_RESTORE_FOCUS, 0, 1);
        }
        assert!(
            try_appearance_dialog_state(dialog)
                .ok_or_else(|| io::Error::other("appearance dialog state is busy"))?
                .state()
                .scroll_y
                > 0
        );
        // Forced Colors disables emphasis, after which the repair message must
        // transfer focus to the first always-enabled density radio.
        // SAFETY: both HWNDs are live test-owned controls and messages are
        // synchronous; no state lease is held while entering either callback.
        unsafe {
            SetFocus(emphasis_control);
            SendMessageW(viewport, WM_VSCROLL, SB_BOTTOM as WPARAM, 0);
            let mut state_lease = try_appearance_dialog_state(dialog)
                .ok_or_else(|| io::Error::other("appearance dialog state is busy"))?;
            let state = state_lease.state_mut();
            let repair_disabled_focus =
                appearance_control_disabled_by_forced_colors(state, emphasis_control);
            assert!(repair_disabled_focus);
            state
                .model
                .set_forced_colors(ForcedColorsState::ActiveOrUnknown);
            sync_controls(state);
            drop(state_lease);
            SendMessageW(
                dialog,
                WM_APP_APPEARANCE_RESTORE_FOCUS,
                usize::from(repair_disabled_focus),
                1,
            );
        }
        // The forced repair branch must scroll the first enabled density radio
        // fully into the viewport even when this hidden test cannot get focus.
        let (repaired_scroll, repaired_layout) = {
            let state_lease = try_appearance_dialog_state(dialog)
                .ok_or_else(|| io::Error::other("appearance dialog state is busy"))?;
            let state = state_lease.state();
            (
                state.scroll_y,
                state
                    .layout
                    .ok_or_else(|| io::Error::other("appearance layout is missing"))?,
            )
        };
        assert!(repaired_layout.density_options[0].y >= repaired_scroll);
        assert!(
            repaired_layout.density_options[0].bottom()
                <= repaired_scroll.saturating_add(repaired_layout.scroll_page)
        );
        // SAFETY: radio remains a live test-owned BUTTON for this value query.
        assert_ne!(unsafe { IsWindowEnabled(radio) }, 0);
        // SAFETY: menu_only is the live fourth density radio. The unarmed dialog
        // scrolls the newly focused control into view, then updates only its
        // local preview model for this synchronous click.
        unsafe {
            SetFocus(menu_only);
            SendMessageW(menu_only, BM_CLICK, 0, 0);
        };
        let draft_density = try_appearance_dialog_state(dialog)
            .ok_or_else(|| io::Error::other("appearance dialog state is busy"))?
            .state()
            .model
            .draft()
            .density;
        assert_eq!(draft_density, RailDensityPreference::MenuOnly);

        let message = MSG {
            hwnd: radio,
            message: WM_KEYDOWN,
            wParam: VK_RETURN as WPARAM,
            ..MSG::default()
        };
        // SAFETY: dialog/radio/message are live and synchronous. The unarmed
        // dialog accepts locally without sending an owner state pointer.
        let handled = unsafe { IsDialogMessageW(dialog, &message) };
        assert_ne!(handled, 0);
        // SAFETY: both IsWindow calls are non-owning value queries.
        let (dialog_live, viewport_live) = unsafe { (IsWindow(dialog), IsWindow(viewport)) };
        assert_eq!(dialog_live, 0);
        assert_eq!(viewport_live, 0);
        // SAFETY: owner remains test-owned after the dialog closes.
        unsafe { DestroyWindow(owner) };
        Ok(())
    }
}
