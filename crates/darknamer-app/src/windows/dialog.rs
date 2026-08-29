use super::*;

#[derive(Clone, Debug)]
pub(super) struct PromptSpec {
    pub(super) title: String,
    pub(super) label_one: String,
    pub(super) label_two: String,
    pub(super) value_one: LegacyText,
    pub(super) value_two: LegacyText,
    pub(super) choices: Vec<String>,
}

#[derive(Clone, Debug)]
pub(super) struct PromptResult {
    pub(super) value_one: LegacyText,
    pub(super) value_two: LegacyText,
    pub(super) choice: usize,
}

pub(super) struct PromptState {
    pub(super) spec: PromptSpec,
    pub(super) result: Option<PromptResult>,
    pub(super) done: bool,
    pub(super) owner: HWND,
    pub(super) title: HWND,
    pub(super) label_one: HWND,
    pub(super) label_two: HWND,
    pub(super) edit_one: HWND,
    pub(super) edit_two: HWND,
    pub(super) combo: HWND,
    pub(super) separator: HWND,
    pub(super) ok: HWND,
    pub(super) cancel: HWND,
    pub(super) font: HFONT,
    pub(super) dpi: u32,
}

pub(super) struct OwnerEnableGuard {
    pub(super) owner: HWND,
    pub(super) was_enabled: bool,
}

impl OwnerEnableGuard {
    fn new(owner: HWND) -> Self {
        // SAFETY: owner is the live top-level window supplied by the synchronous caller.
        let was_enabled = unsafe { IsWindowEnabled(owner) } != 0;
        if was_enabled {
            // SAFETY: owner is live and this guard restores its prior enabled state on every path.
            unsafe { EnableWindow(owner, 0) };
        }
        Self { owner, was_enabled }
    }
}

impl Drop for OwnerEnableGuard {
    fn drop(&mut self) {
        if self.was_enabled {
            // SAFETY: owner is the live modal-owner HWND and was enabled before this guard disabled it.
            unsafe {
                EnableWindow(self.owner, 1);
                SetForegroundWindow(self.owner);
            }
        }
    }
}

struct NativeDialogParent {
    hwnd: HWND,
}

impl HasWindowHandle for NativeDialogParent {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        let hwnd = NonZeroIsize::new(self.hwnd as isize).ok_or(HandleError::Unavailable)?;
        let raw = RawWindowHandle::Win32(Win32WindowHandle::new(hwnd));
        // SAFETY: this wrapper is borrowed only while the live owner HWND is synchronously used.
        Ok(unsafe { WindowHandle::borrow_raw(raw) })
    }
}

impl HasDisplayHandle for NativeDialogParent {
    fn display_handle(&self) -> Result<DisplayHandle<'_>, HandleError> {
        Ok(DisplayHandle::windows())
    }
}

pub(super) fn native_file_dialog(owner: HWND) -> rfd::FileDialog {
    let parent = NativeDialogParent { hwnd: owner };
    rfd::FileDialog::new().set_parent(&parent)
}

pub(super) fn prompt_input(owner: HWND, spec: PromptSpec) -> io::Result<Option<PromptResult>> {
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
        owner,
        title: null_mut(),
        label_one: null_mut(),
        label_two: null_mut(),
        edit_one: null_mut(),
        edit_two: null_mut(),
        combo: null_mut(),
        separator: null_mut(),
        ok: null_mut(),
        cancel: null_mut(),
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
    let _owner_guard = OwnerEnableGuard::new(owner);
    // SAFETY: window is the non-null top-level HWND just created and remains owned by this UI thread.
    unsafe {
        ShowWindow(dialog, SW_SHOW);
        UpdateWindow(dialog);
    }
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

pub(super) fn prompt_input_or_report(owner: HWND, spec: PromptSpec) -> Option<PromptResult> {
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

fn prompt_controls(state: &PromptState) -> [HWND; 9] {
    [
        state.title,
        state.label_one,
        state.label_two,
        state.edit_one,
        state.edit_two,
        state.combo,
        state.separator,
        state.ok,
        state.cancel,
    ]
}

fn recreate_prompt_font(state: &mut PromptState) {
    let replacement = create_message_font(state.dpi);
    if replacement.is_null() {
        return;
    }
    for control in prompt_controls(state) {
        if !control.is_null() {
            // SAFETY: control is a live child HWND and replacement remains owned by PromptState.
            unsafe { SendMessageW(control, WM_SETFONT, replacement as usize, 1) };
        }
    }
    if !state.font.is_null() {
        // SAFETY: the old font is no longer selected by any prompt child after synchronous WM_SETFONT.
        unsafe { DeleteObject(state.font) };
    }
    state.font = replacement;
}

fn measured_prompt_text(window: HWND, font: HFONT, text: &str, max_width: i32) -> LayoutRect {
    // SAFETY: window is live and GetDC returns a display context valid until ReleaseDC below.
    let dc = unsafe { GetDC(window) };
    if dc.is_null() {
        return LayoutRect::default();
    }
    // SAFETY: dc is live and font is a PromptState-owned HFONT.
    let previous = unsafe { SelectObject(dc, font) };
    let mut value = wide(text);
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: max_width.max(1),
        bottom: 0,
    };
    // SAFETY: value is mutable terminated UTF-16 and rect is writable through synchronous measurement.
    unsafe {
        DrawTextW(
            dc,
            value.as_mut_ptr(),
            -1,
            &mut rect,
            DT_CALCRECT | DT_NOPREFIX | DT_WORDBREAK,
        );
        SelectObject(dc, previous);
        ReleaseDC(window, dc);
    }
    LayoutRect {
        x: 0,
        y: 0,
        width: rect.right.saturating_sub(rect.left).max(0),
        height: rect.bottom.saturating_sub(rect.top).max(0),
    }
}

fn measure_prompt_font(
    window: HWND,
    state: &PromptState,
    maximum_client: LayoutRect,
) -> PromptFontMetrics {
    if state.font.is_null() {
        return PromptFontMetrics::default();
    }
    let horizontal_padding = scale_dip(24, state.dpi);
    let maximum_title_width = scale_dip(520, state.dpi)
        .min(maximum_client.width.saturating_sub(horizontal_padding))
        .max(1);
    let maximum_label_width = scale_dip(138, state.dpi)
        .min(maximum_title_width.saturating_sub(scale_dip(8, state.dpi)) / 3);
    let title = measured_prompt_text(window, state.font, &state.spec.title, maximum_title_width);
    let line = measured_prompt_text(window, state.font, "Mg", maximum_title_width);
    let label_one = measured_prompt_text(
        window,
        state.font,
        &state.spec.label_one,
        maximum_label_width,
    );
    let label_two = measured_prompt_text(
        window,
        state.font,
        &state.spec.label_two,
        maximum_label_width,
    );
    PromptFontMetrics {
        title_width: title.width,
        title_height: title.height,
        label_width: label_one.width.max(label_two.width),
        label_height: label_one.height.max(label_two.height),
        line_height: line.height,
    }
}

fn move_prompt_control(window: HWND, rect: LayoutRect) {
    if window.is_null() {
        return;
    }
    // The pure layout already returns pixels, so BASE_DPI keeps this shared helper at identity scale.
    move_window_dip(window, rect.x, rect.y, rect.width, rect.height, BASE_DPI);
}

fn prompt_work_area(anchor: HWND) -> Option<RECT> {
    // SAFETY: anchor is live and the nearest-monitor fallback returns its nearest monitor.
    let monitor = unsafe { MonitorFromWindow(anchor, MONITOR_DEFAULTTONEAREST) };
    if monitor.is_null() {
        return None;
    }
    let mut monitor_info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        rcMonitor: RECT::default(),
        rcWork: RECT::default(),
        dwFlags: 0,
    };
    // SAFETY: monitor is resolved from the live anchor and monitor_info is writable storage.
    (unsafe { GetMonitorInfoW(monitor, &mut monitor_info) } != 0).then_some(monitor_info.rcWork)
}

fn maximum_prompt_client(state: &PromptState, anchor: HWND) -> LayoutRect {
    let Some(work) = prompt_work_area(anchor) else {
        return LayoutRect {
            x: 0,
            y: 0,
            width: scale_dip(380, state.dpi),
            height: scale_dip(210, state.dpi),
        };
    };
    let mut nonclient = RECT::default();
    // SAFETY: nonclient is writable and the style/ex-style match this prompt window.
    let adjusted = unsafe {
        AdjustWindowRectExForDpi(
            &mut nonclient,
            WS_POPUP | WS_CAPTION | WS_SYSMENU,
            0,
            WS_EX_TOOLWINDOW,
            state.dpi,
        )
    } != 0;
    let (nonclient_width, nonclient_height) = if adjusted {
        (
            nonclient.right.saturating_sub(nonclient.left),
            nonclient.bottom.saturating_sub(nonclient.top),
        )
    } else {
        (0, 0)
    };
    LayoutRect {
        x: 0,
        y: 0,
        width: work
            .right
            .saturating_sub(work.left)
            .saturating_sub(nonclient_width)
            .max(1),
        height: work
            .bottom
            .saturating_sub(work.top)
            .saturating_sub(nonclient_height)
            .max(1),
    }
}

fn position_prompt(window: HWND, state: &PromptState, client: LayoutRect, center_on_owner: bool) {
    let mut outer = RECT {
        left: 0,
        top: 0,
        right: client.width,
        bottom: client.height,
    };
    // SAFETY: outer is writable and the style/ex-style match this prompt window.
    if unsafe {
        AdjustWindowRectExForDpi(
            &mut outer,
            WS_POPUP | WS_CAPTION | WS_SYSMENU,
            0,
            WS_EX_TOOLWINDOW,
            state.dpi,
        )
    } == 0
    {
        return;
    }
    let width = outer.right.saturating_sub(outer.left).max(1);
    let height = outer.bottom.saturating_sub(outer.top).max(1);
    let anchor = if center_on_owner { state.owner } else { window };
    let mut anchor_rect = RECT::default();
    // SAFETY: anchor is the live modal owner or prompt and anchor_rect is writable.
    if unsafe { GetWindowRect(anchor, &mut anchor_rect) } == 0 {
        return;
    }
    let Some(work) = prompt_work_area(anchor) else {
        return;
    };
    let work_width = work.right.saturating_sub(work.left).max(1);
    let work_height = work.bottom.saturating_sub(work.top).max(1);
    if width > work_width || height > work_height {
        return;
    }
    let centered_x = anchor_rect
        .left
        .saturating_add(anchor_rect.right.saturating_sub(anchor_rect.left) / 2)
        .saturating_sub(width / 2);
    let centered_y = anchor_rect
        .top
        .saturating_add(anchor_rect.bottom.saturating_sub(anchor_rect.top) / 2)
        .saturating_sub(height / 2);
    let x = centered_x.clamp(work.left, work.right.saturating_sub(width));
    let y = centered_y.clamp(work.top, work.bottom.saturating_sub(height));
    // SAFETY: window is live and the bounded geometry lies within the monitor work area.
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
}

fn arrange_prompt(window: HWND, state: &PromptState, center_on_owner: bool) {
    let fields = PromptFields {
        value_one: !state.spec.label_one.is_empty(),
        value_two: !state.spec.label_two.is_empty(),
        choice: !state.spec.choices.is_empty(),
    };
    let anchor = if center_on_owner { state.owner } else { window };
    let maximum_client = maximum_prompt_client(state, anchor);
    let layout = calculate_prompt_layout(
        state.dpi,
        measure_prompt_font(window, state, maximum_client),
        fields,
        maximum_client,
    );
    move_prompt_control(state.title, layout.title);
    if let Some(rect) = layout.edit_one {
        move_prompt_control(state.edit_one, rect);
    }
    if let Some(rect) = layout.label_one {
        move_prompt_control(state.label_one, rect);
    }
    if let Some(rect) = layout.edit_two {
        move_prompt_control(state.edit_two, rect);
    }
    if let Some(rect) = layout.label_two {
        move_prompt_control(state.label_two, rect);
    }
    if let Some(rect) = layout.choice {
        move_prompt_control(state.combo, rect);
    }
    move_prompt_control(state.separator, layout.separator);
    move_prompt_control(state.ok, layout.ok);
    move_prompt_control(state.cancel, layout.cancel);
    position_prompt(window, state, layout.client, center_on_owner);
}

pub(super) unsafe extern "system" fn prompt_proc(
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
            state.title = child(window, "STATIC", &state.spec.title, 1001, SS_NOPREFIX);
            if !state.spec.label_one.is_empty() {
                state.edit_one = child(
                    window,
                    "EDIT",
                    &state.spec.value_one.to_string_lossy(),
                    1004,
                    WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                );
                state.label_one = child(window, "STATIC", &state.spec.label_one, 1002, SS_NOPREFIX);
            }
            if !state.spec.label_two.is_empty() {
                state.edit_two = child(
                    window,
                    "EDIT",
                    &state.spec.value_two.to_string_lossy(),
                    1005,
                    WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                );
                state.label_two = child(window, "STATIC", &state.spec.label_two, 1003, SS_NOPREFIX);
            }
            if !state.spec.choices.is_empty() {
                let combo = child(
                    window,
                    "COMBOBOX",
                    "",
                    1006,
                    WS_TABSTOP | CBS_DROPDOWNLIST as u32,
                );
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
                state.combo = combo;
            }
            state.ok = child(
                window,
                "BUTTON",
                "확인",
                IDOK as u16,
                WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
            );
            state.cancel = child(window, "BUTTON", "취소", IDCANCEL as u16, WS_TABSTOP);
            state.separator = child(window, "STATIC", "", 1010, SS_ETCHEDHORZ);
            recreate_prompt_font(state);
            arrange_prompt(window, state, true);
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
        WM_DPICHANGED if !state_ptr.is_null() => {
            // SAFETY: state_ptr borrows the live prompt state on its owning UI thread.
            let state = unsafe { &mut *state_ptr };
            let next_dpi = (wparam & 0xFFFF) as u32;
            state.dpi = if next_dpi == 0 { BASE_DPI } else { next_dpi };
            let suggested = lparam as *const RECT;
            if !suggested.is_null() {
                // SAFETY: WM_DPICHANGED provides a readable suggested RECT for this live prompt.
                let suggested = unsafe { *suggested };
                // SAFETY: window is live and suggested geometry is supplied by Windows for this DPI transition.
                unsafe {
                    SetWindowPos(
                        window,
                        null_mut(),
                        suggested.left,
                        suggested.top,
                        suggested.right.saturating_sub(suggested.left),
                        suggested.bottom.saturating_sub(suggested.top),
                        SWP_NOACTIVATE | SWP_NOZORDER,
                    )
                };
            }
            recreate_prompt_font(state);
            arrange_prompt(window, state, false);
            0
        }
        WM_SETTINGCHANGE | WM_FONTCHANGE if !state_ptr.is_null() => {
            // SAFETY: state_ptr borrows the live prompt state on its owning UI thread.
            let state = unsafe { &mut *state_ptr };
            // SAFETY: window is the live prompt HWND.
            let dpi = unsafe { GetDpiForWindow(window) };
            state.dpi = if dpi == 0 { BASE_DPI } else { dpi };
            recreate_prompt_font(state);
            arrange_prompt(window, state, false);
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

pub(super) fn window_text(window: HWND) -> LegacyText {
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

pub(super) fn add_files_dialog(owner: HWND, state: &mut AppState) {
    let Some(paths) = modal_native_dialog(owner, || {
        native_file_dialog(owner)
            .set_title("이름 붙일 파일 불러오기")
            .add_filter("All Files", &["*"])
            .pick_files()
    }) else {
        return;
    };
    admit_paths(owner, state, paths);
}

pub(super) fn copy_clipboard_or_report(owner: HWND, text: &LegacyText) {
    if let Err(error) = copy_clipboard(owner, text) {
        message(
            owner,
            &format!("클립보드에 복사하지 못했습니다: {error}"),
            "DarkReNamer - 복사 실패",
        );
    }
}

pub(super) fn save_text_dialog(owner: HWND, text: LegacyText, names: bool) {
    let title = if names {
        "파일명 저장"
    } else {
        "경로명 저장"
    };
    let default_name = if names { "names.txt" } else { "paths.txt" };
    let Some(path) = modal_native_dialog(owner, || {
        native_file_dialog(owner)
            .set_title(title)
            .add_filter("Text Files", &["txt"])
            .add_filter("All Files", &["*"])
            .set_file_name(default_name)
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

pub(super) fn import_names_dialog(owner: HWND, state: &mut AppState) {
    let Some(path) = modal_native_dialog(owner, || {
        native_file_dialog(owner)
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

pub(super) fn import_paths_dialog(owner: HWND, state: &mut AppState) {
    let Some(path) = modal_native_dialog(owner, || {
        native_file_dialog(owner)
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

pub(super) fn set_status(status: HWND, text: &str) {
    let text = wide(text);
    // SAFETY: window is the non-null top-level HWND just created and remains owned by this UI thread.
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(status, text.as_ptr());
        UpdateWindow(status);
    }
}

pub(super) fn modal_native_dialog<T>(owner: HWND, dialog: impl FnOnce() -> T) -> T {
    let _owner_guard = OwnerEnableGuard::new(owner);
    dialog()
}
