use std::io;
use std::mem::size_of;
use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    COLOR_WINDOW, FillRect, GetMonitorInfoW, GetSysColorBrush, MONITOR_DEFAULTTONEAREST,
    MONITORINFO, MonitorFromWindow, SetBkColor, SetTextColor, UpdateWindow,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::SystemServices::{SS_ETCHEDHORZ, SS_NOPREFIX};
use windows_sys::Win32::UI::Controls::{BST_CHECKED, BST_UNCHECKED};
use windows_sys::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForWindow};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BM_GETCHECK, BM_SETCHECK, BN_CLICKED, BS_AUTOCHECKBOX, BS_AUTORADIOBUTTON, BS_DEFPUSHBUTTON,
    BS_GROUPBOX, BS_OWNERDRAW, CREATESTRUCTW, CS_HREDRAW, CS_VREDRAW, CreateWindowExW,
    DefWindowProcW, DestroyWindow, GWLP_USERDATA, GetWindowLongPtrW, GetWindowRect, IDCANCEL, IDOK,
    IsWindow, PostMessageW, RegisterClassExW, SW_HIDE, SW_SHOW, SWP_NOACTIVATE, SWP_NOZORDER,
    SendMessageW, SetForegroundWindow, SetWindowLongPtrW, SetWindowPos, ShowWindow, WM_CLOSE,
    WM_COMMAND, WM_CREATE, WM_CTLCOLORBTN, WM_CTLCOLORSTATIC, WM_DPICHANGED, WM_DRAWITEM,
    WM_ERASEBKGND, WM_FONTCHANGE, WM_NCCREATE, WM_NCDESTROY, WM_NOTIFY, WM_SETFONT,
    WM_SETTINGCHANGE, WNDCLASSEXW, WS_CAPTION, WS_CLIPCHILDREN, WS_EX_TOOLWINDOW, WS_GROUP,
    WS_POPUP, WS_SYSMENU, WS_TABSTOP,
};

use super::*;

const DENSITY_AUTOMATIC_ID: u16 = 0xA101;
const DENSITY_COMFORTABLE_ID: u16 = 0xA102;
const DENSITY_COMPACT_ID: u16 = 0xA103;
const EMPHASIS_SUBTLE_ID: u16 = 0xA111;
const EMPHASIS_STANDARD_ID: u16 = 0xA112;
const EMPHASIS_STRONG_ID: u16 = 0xA113;
const SHOW_SEPARATORS_ID: u16 = 0xA121;
const SHOW_PREVIEW_TINT_ID: u16 = 0xA122;
const SHOW_EMPTY_SAFETY_ID: u16 = 0xA123;
const FORCED_EXPLANATION_ID: u16 = 0xA130;
const RESET_DEFAULTS_ID: u16 = 0xA140;
const APPEARANCE_FINISH_ACCEPTED: u32 = 1 << 31;
const DENSITY_GROUP_LABEL: &str = "명령 버튼 간격";
const DENSITY_LABELS: [&str; 3] = ["자동 (권장)", "여유 있게", "촘촘하게"];
const EMPHASIS_GROUP_LABEL: &str = "변경 강조";
const EMPHASIS_LABELS: [&str; 3] = ["약하게", "표준", "강하게"];
const SEPARATOR_LABEL: &str = "기능 그룹 구분선 표시";
const TINT_LABEL: &str = "변경된 이름의 배경 강조";
const EMPTY_SAFETY_LABEL: &str = "파일을 추가하기 전 안전 안내 표시";
const RESET_LABEL: &str = "기본값으로 복원";
const OK_LABEL: &str = "확인";
const CANCEL_LABEL: &str = "취소";

pub(super) struct AppearanceDialogSession {
    pub(super) id: u32,
    pub(super) window: HWND,
    pub(super) baseline: UiAppearance,
    owner_guard: Option<OwnerEnableGuard>,
}

impl AppearanceDialogSession {
    pub(super) fn disarm_owner_restore(&mut self) {
        if let Some(guard) = self.owner_guard.as_mut() {
            guard.disarm();
        }
    }
}

struct AppearanceDialogWindowState {
    owner: HWND,
    session_id: u32,
    model: AppearanceDialogModel,
    density_group: HWND,
    density: [HWND; 3],
    emphasis_group: HWND,
    emphasis: [HWND; 3],
    forced_explanation: HWND,
    checkboxes: [HWND; 3],
    separator: HWND,
    reset: HWND,
    ok: HWND,
    cancel: HWND,
    font: OwnedFont,
    measured: AppearanceDialogMetrics,
    appearance_resources: Option<AppearanceResources>,
    system_theme: Option<ResolvedTheme>,
    dpi: u32,
    armed: bool,
    finished: bool,
}

struct AppearanceDialogInit {
    state: *mut AppearanceDialogWindowState,
    adopted: *mut bool,
}

pub(super) fn open_appearance_dialog(owner: HWND, state: &mut AppState) {
    if let Some(session) = state.appearance_dialog.as_ref() {
        // SAFETY: the session owns a live top-level dialog while it remains in AppState.
        unsafe {
            SetForegroundWindow(session.window);
            SetFocus(session.window);
        }
        return;
    }
    let activity = state.worker_activity();
    let worker_active = activity.admission || activity.plan || activity.apply;
    if !advanced_appearance_available(worker_active, state.confirmation_pending) {
        message(
            owner,
            "진행 중인 작업이나 확인 대화상자를 마친 뒤 모양 설정을 열어 주세요.",
            "DarkReNamer - 모양 설정",
        );
        return;
    }
    let next = state.next_appearance_dialog_id.wrapping_add(1).max(1);
    match create_appearance_dialog_window(
        owner,
        next,
        state.appearance,
        state.forced_colors,
        state.system_theme,
    ) {
        Ok(window) => {
            state.next_appearance_dialog_id = next;
            state.appearance_dialog = Some(AppearanceDialogSession {
                id: next,
                window,
                baseline: state.appearance,
                owner_guard: None,
            });
            // SAFETY: the dialog is live, the AppState session is installed,
            // and this scalar ID cannot cause an owner callback.
            let armed =
                unsafe { SendMessageW(window, WM_APP_APPEARANCE_ARM, 0, next as isize) != 0 };
            if armed {
                let guard = OwnerEnableGuard::new(owner);
                if let Some(session) = state.appearance_dialog.as_mut() {
                    session.owner_guard = Some(guard);
                }
            } else {
                let session = state.appearance_dialog.take();
                if let Some(session) = session {
                    // SAFETY: the unarmed HWND cannot notify the owner and is
                    // destroyed before its pointer-free session is dropped.
                    unsafe { DestroyWindow(session.window) };
                    drop(session);
                }
                state.set_transient_status(
                    "모양 설정 창을 활성화하지 못했습니다. 현재 작업에는 영향이 없습니다.",
                );
            }
        }
        Err(error) => {
            state.set_transient_status(format!(
                "모양 설정 창을 열지 못했습니다. 현재 작업에는 영향이 없습니다: {error}"
            ));
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

pub(super) fn cancel_appearance_dialog(owner: HWND, state: &mut AppState) {
    let Some(mut session) = state.appearance_dialog.take() else {
        return;
    };
    state.appearance = session.baseline;
    // SAFETY: both messages target the live dialog HWND. The scalar dismiss ID
    // suppresses its fail-closed finish callback before synchronous teardown,
    // avoiding owner re-entry while this AppState borrow is active.
    unsafe {
        SendMessageW(
            session.window,
            WM_APP_APPEARANCE_DISMISS,
            0,
            session.id as isize,
        );
        DestroyWindow(session.window);
    }
    session.disarm_owner_restore();
    drop(session);
    apply_native_appearance_nonblocking(owner, state);
    update_controls(state);
    arrange(owner, state);
}

fn create_appearance_dialog_window(
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
    // SAFETY: owner is the live top-level HWND used only for its current DPI.
    let owner_dpi = unsafe { GetDpiForWindow(owner) }.max(BASE_DPI);
    let show_forced_explanation = matches!(forced_colors, ForcedColorsState::ActiveOrUnknown);
    if !appearance_dialog_fits_work_area(owner, owner_dpi, show_forced_explanation) {
        return Err(io::Error::other(
            "monitor work area is too small for the appearance dialog",
        ));
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
    let state_ptr = Box::into_raw(Box::new(AppearanceDialogWindowState {
        owner,
        session_id,
        model: AppearanceDialogModel::new(appearance, forced_colors),
        density_group: null_mut(),
        density: [null_mut(); 3],
        emphasis_group: null_mut(),
        emphasis: [null_mut(); 3],
        forced_explanation: null_mut(),
        checkboxes: [null_mut(); 3],
        separator: null_mut(),
        reset: null_mut(),
        ok: null_mut(),
        cancel: null_mut(),
        font: OwnedFont::default(),
        measured: AppearanceDialogMetrics::default(),
        appearance_resources: None,
        system_theme,
        dpi: BASE_DPI,
        armed: false,
        finished: false,
    }));
    let mut adopted = false;
    let mut init = AppearanceDialogInit {
        state: state_ptr,
        adopted: &mut adopted,
    };
    let title = wide("DarkReNamer - 고급 모양 설정");
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

fn create_controls(window: HWND, state: &mut AppearanceDialogWindowState) -> io::Result<()> {
    state.density_group = child(
        window,
        "BUTTON",
        DENSITY_GROUP_LABEL,
        0xA100,
        BS_GROUPBOX as u32,
    )?;
    state.density = [
        child(
            window,
            "BUTTON",
            DENSITY_LABELS[0],
            DENSITY_AUTOMATIC_ID,
            BS_AUTORADIOBUTTON as u32 | WS_GROUP | WS_TABSTOP,
        )?,
        child(
            window,
            "BUTTON",
            DENSITY_LABELS[1],
            DENSITY_COMFORTABLE_ID,
            BS_AUTORADIOBUTTON as u32 | WS_TABSTOP,
        )?,
        child(
            window,
            "BUTTON",
            DENSITY_LABELS[2],
            DENSITY_COMPACT_ID,
            BS_AUTORADIOBUTTON as u32 | WS_TABSTOP,
        )?,
    ];
    state.emphasis_group = child(
        window,
        "BUTTON",
        EMPHASIS_GROUP_LABEL,
        0xA110,
        BS_GROUPBOX as u32,
    )?;
    state.emphasis = [
        child(
            window,
            "BUTTON",
            EMPHASIS_LABELS[0],
            EMPHASIS_SUBTLE_ID,
            BS_AUTORADIOBUTTON as u32 | WS_GROUP | WS_TABSTOP,
        )?,
        child(
            window,
            "BUTTON",
            EMPHASIS_LABELS[1],
            EMPHASIS_STANDARD_ID,
            BS_AUTORADIOBUTTON as u32 | WS_TABSTOP,
        )?,
        child(
            window,
            "BUTTON",
            EMPHASIS_LABELS[2],
            EMPHASIS_STRONG_ID,
            BS_AUTORADIOBUTTON as u32 | WS_TABSTOP,
        )?,
    ];
    state.forced_explanation = child(
        window,
        "STATIC",
        "고대비가 활성화되어 변경 강조와 배경 강조는 시스템 색상을 사용합니다.",
        FORCED_EXPLANATION_ID,
        SS_NOPREFIX,
    )?;
    state.checkboxes = [
        child(
            window,
            "BUTTON",
            SEPARATOR_LABEL,
            SHOW_SEPARATORS_ID,
            BS_AUTOCHECKBOX as u32 | WS_TABSTOP,
        )?,
        child(
            window,
            "BUTTON",
            TINT_LABEL,
            SHOW_PREVIEW_TINT_ID,
            BS_AUTOCHECKBOX as u32 | WS_TABSTOP,
        )?,
        child(
            window,
            "BUTTON",
            EMPTY_SAFETY_LABEL,
            SHOW_EMPTY_SAFETY_ID,
            BS_AUTOCHECKBOX as u32 | WS_TABSTOP,
        )?,
    ];
    state.separator = child(window, "STATIC", "", 0xA131, SS_ETCHEDHORZ)?;
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
) {
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
    if close {
        // SAFETY: window is the live appearance dialog and closes once per terminal action.
        unsafe { DestroyWindow(window) };
    }
}

fn apply_dialog_appearance(window: HWND, state: &mut AppearanceDialogWindowState) {
    let resolved = state
        .model
        .draft()
        .resolve(state.model.forced_colors(), state.system_theme);
    state.appearance_resources = semantic_palette(resolved.theme)
        .and_then(|palette| AppearanceResources::create(palette).ok());
    apply_auxiliary_dwm_title_frame(window, resolved.theme);
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

fn appearance_dialog_fits_work_area(anchor: HWND, dpi: u32, show_forced_explanation: bool) -> bool {
    // SAFETY: anchor is a live top-level HWND and no pointer is retained.
    let monitor = unsafe { MonitorFromWindow(anchor, MONITOR_DEFAULTTONEAREST) };
    if monitor.is_null() {
        return false;
    }
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..MONITORINFO::default()
    };
    // SAFETY: monitor is live and info is writable with its exact size.
    if unsafe { GetMonitorInfoW(monitor, &mut info) } == 0 {
        return false;
    }
    let style = WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN;
    let mut chrome = RECT::default();
    // SAFETY: chrome is writable RECT storage and style/DPI are copied values.
    if unsafe { AdjustWindowRectExForDpi(&mut chrome, style, 0, WS_EX_TOOLWINDOW, dpi) } == 0 {
        return false;
    }
    let maximum_width = info
        .rcWork
        .right
        .saturating_sub(info.rcWork.left)
        .saturating_sub(chrome.right.saturating_sub(chrome.left));
    let maximum_height = info
        .rcWork
        .bottom
        .saturating_sub(info.rcWork.top)
        .saturating_sub(chrome.bottom.saturating_sub(chrome.top));
    calculate_appearance_dialog_layout(
        dpi,
        maximum_width,
        maximum_height,
        show_forced_explanation,
        AppearanceDialogMetrics::default(),
    )
    .is_some()
}

fn arrange_dialog(window: HWND, state: &AppearanceDialogWindowState, center_owner: bool) -> bool {
    let anchor = if center_owner { state.owner } else { window };
    // SAFETY: anchor is a live top-level owner/dialog HWND and no pointer is retained.
    let monitor = unsafe { MonitorFromWindow(anchor, MONITOR_DEFAULTTONEAREST) };
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
    let Some(layout) = calculate_appearance_dialog_layout(
        state.dpi,
        maximum_client_width,
        maximum_client_height,
        show_forced_explanation,
        state.measured,
    ) else {
        return false;
    };
    for (control, rect) in controls(state).zip([
        layout.density_group,
        layout.density_options[0],
        layout.density_options[1],
        layout.density_options[2],
        layout.emphasis_group,
        layout.emphasis_options[0],
        layout.emphasis_options[1],
        layout.emphasis_options[2],
        layout.forced_explanation,
        layout.checkboxes[0],
        layout.checkboxes[1],
        layout.checkboxes[2],
        layout.separator,
        layout.reset,
        layout.ok,
        layout.cancel,
    ]) {
        // SAFETY: each control is live and rect is pure bounded geometry.
        unsafe {
            SetWindowPos(
                control,
                null_mut(),
                rect.x,
                rect.y,
                rect.width,
                rect.height,
                SWP_NOACTIVATE | SWP_NOZORDER,
            )
        };
    }
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
    let mut anchor_rect = RECT::default();
    // SAFETY: anchor is live and anchor_rect is writable for this value query.
    if unsafe { GetWindowRect(anchor, &mut anchor_rect) } == 0 {
        return false;
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
    unsafe {
        SetWindowPos(
            window,
            null_mut(),
            x,
            y,
            width,
            height,
            SWP_NOACTIVATE | SWP_NOZORDER,
        )
    };
    true
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
    // SAFETY: the slot contains only the Box pointer installed above and is
    // cleared before the unique reclamation in WM_NCDESTROY.
    let state_ptr =
        unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *mut AppearanceDialogWindowState;
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
            if !arrange_dialog(window, state, true) {
                return -1;
            }
            // SAFETY: first radio is a live tab-stop native child.
            unsafe { SetFocus(state.density[0]) };
            0
        }
        WM_COMMAND if !state_ptr.is_null() => {
            let id = (wparam & 0xFFFF) as u16;
            let notification = ((wparam >> 16) & 0xFFFF) as u32;
            if notification == BN_CLICKED {
                // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
                let state = unsafe { &mut *state_ptr };
                if let Some(action) = action_for_command(state, id) {
                    apply_action(window, state, action);
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
            let resources = unsafe { (*state_ptr).appearance_resources.as_ref() };
            if draw_owner_button(resources, lparam) {
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
                    SetBkColor(wparam as HDC, palette.surface_dialog);
                }
                resources.dialog_brush() as LRESULT
            } else {
                // SAFETY: system mode retains standard control color handling.
                unsafe { DefWindowProcW(window, message, wparam, lparam) }
            }
        }
        WM_CLOSE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box for this close callback.
            let state = unsafe { &mut *state_ptr };
            apply_action(window, state, AppearanceDialogAction::Cancel);
            0
        }
        WM_DPICHANGED if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
            let state = unsafe { &mut *state_ptr };
            state.dpi = ((wparam & 0xFFFF) as u32).max(BASE_DPI);
            recreate_font(state);
            if !arrange_dialog(window, state, false) {
                apply_action(window, state, AppearanceDialogAction::Cancel);
            }
            0
        }
        WM_SETTINGCHANGE | WM_FONTCHANGE if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
            let state = unsafe { &mut *state_ptr };
            // SAFETY: window is the live appearance dialog HWND.
            state.dpi = unsafe { GetDpiForWindow(window) }.max(BASE_DPI);
            recreate_font(state);
            if !arrange_dialog(window, state, false) {
                apply_action(window, state, AppearanceDialogAction::Cancel);
            }
            0
        }
        WM_APP_APPEARANCE_ACCESSIBILITY if !state_ptr.is_null() => {
            // SAFETY: state_ptr is the dialog-owned Box on this UI thread.
            let state = unsafe { &mut *state_ptr };
            if u32::try_from(lparam).ok() == Some(state.session_id) {
                let (forced_colors, system_theme) = unpack_appearance_environment(wparam);
                state.model.set_forced_colors(forced_colors);
                state.system_theme = system_theme;
                sync_controls(state);
                apply_dialog_appearance(window, state);
                if !arrange_dialog(window, state, false) {
                    apply_action(window, state, AppearanceDialogAction::Cancel);
                }
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
        WM_NCDESTROY if !state_ptr.is_null() => {
            // SAFETY: state_ptr is still the dialog-owned Box for this final
            // callback. Unexpected destruction fails closed as Cancel.
            let state = unsafe { &mut *state_ptr };
            if appearance_dialog_should_notify_cancel(state.armed, state.finished) {
                let effect = state.model.apply(AppearanceDialogAction::Cancel);
                send_effect(state, effect);
                state.finished = true;
            }
            // SAFETY: this callback owns the userdata slot and clears it before
            // reclaiming its Box exactly once.
            unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, 0) };
            // SAFETY: state_ptr came from the single Box ownership transfer
            // adopted by this exact HWND.
            unsafe { drop(Box::from_raw(state_ptr)) };
            // SAFETY: arguments are unchanged values from the active callback.
            unsafe { DefWindowProcW(window, message, wparam, lparam) }
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
    use windows_sys::Win32::UI::Controls::{CDIS_DEFAULT, NM_CUSTOMDRAW, NMCUSTOMDRAW};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::VK_RETURN;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        BS_TYPEMASK, GWL_STYLE, GetClientRect, GetWindowLongPtrW, IsDialogMessageW, MSG, WM_KEYDOWN,
    };

    #[test]
    fn default_ok_keeps_native_contract_and_enter_activation()
    -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: null requests the current process module.
        let instance = unsafe { GetModuleHandleW(null()) };
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
        // SAFETY: dialog owns this state pointer until WM_NCDESTROY.
        let state_ptr =
            unsafe { GetWindowLongPtrW(dialog, GWLP_USERDATA) } as *mut AppearanceDialogWindowState;
        if state_ptr.is_null() {
            // SAFETY: both windows are test-owned and live.
            unsafe {
                DestroyWindow(dialog);
                DestroyWindow(owner);
            }
            return Err(io::Error::other("appearance dialog state is missing").into());
        }
        // SAFETY: state_ptr is live dialog-owned state for these copied HWNDs.
        let (ok, radio, resources) = unsafe {
            (
                (*state_ptr).ok,
                (*state_ptr).density[0],
                (*state_ptr).appearance_resources.as_ref(),
            )
        };
        // SAFETY: ok is a live native BUTTON and style is an integral query.
        let style = unsafe { GetWindowLongPtrW(ok, GWL_STYLE) } as u32;
        assert_eq!(style & BS_TYPEMASK as u32, BS_DEFPUSHBUTTON as u32);

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
        assert_eq!(
            draw_custom_button(
                resources,
                ok,
                (&raw mut custom as *mut NMCUSTOMDRAW) as LPARAM,
            ),
            Some(CDRF_SKIPDEFAULT as LRESULT)
        );
        // SAFETY: dc came from this exact live button.
        unsafe { ReleaseDC(ok, dc) };

        let mut message = MSG {
            hwnd: radio,
            message: WM_KEYDOWN,
            wParam: VK_RETURN as WPARAM,
            ..MSG::default()
        };
        // SAFETY: dialog/radio/message are live and synchronous. The unarmed
        // dialog accepts locally without sending an owner state pointer.
        let handled = unsafe { IsDialogMessageW(dialog, &mut message) };
        assert_ne!(handled, 0);
        // SAFETY: IsWindow is a non-owning value query.
        assert_eq!(unsafe { IsWindow(dialog) }, 0);
        // SAFETY: owner remains test-owned after the dialog closes.
        unsafe { DestroyWindow(owner) };
        Ok(())
    }
}
