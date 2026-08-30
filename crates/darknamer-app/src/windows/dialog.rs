use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct TaskDialogButtonSpec<'a> {
    pub(super) id: i32,
    pub(super) text: &'a str,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct TaskDialogSpec<'a> {
    pub(super) title: &'a str,
    pub(super) main_instruction: &'a str,
    pub(super) content: &'a str,
    pub(super) expanded_information: Option<&'a str>,
    pub(super) buttons: &'a [TaskDialogButtonSpec<'a>],
    pub(super) warning: bool,
}

struct OwnedTaskDialog {
    _title: Vec<u16>,
    _main_instruction: Vec<u16>,
    _content: Vec<u16>,
    _expanded_information: Option<Vec<u16>>,
    _expanded_control_text: Option<Vec<u16>>,
    _collapsed_control_text: Option<Vec<u16>>,
    _button_texts: Vec<Vec<u16>>,
    _buttons: Vec<TASKDIALOG_BUTTON>,
    config: TASKDIALOGCONFIG,
}

impl OwnedTaskDialog {
    fn new(owner: HWND, spec: TaskDialogSpec<'_>) -> io::Result<Self> {
        if owner.is_null() {
            return Err(io::Error::other("task dialog requires a live owner window"));
        }
        if spec.buttons.is_empty() {
            return Err(io::Error::other(
                "task dialog requires at least one explicit action",
            ));
        }
        for (index, button) in spec.buttons.iter().enumerate() {
            if button.id <= 0 || button.id == IDCANCEL || button.text.is_empty() {
                return Err(io::Error::other(
                    "task dialog button specification is invalid",
                ));
            }
            if spec.buttons[..index]
                .iter()
                .any(|existing| existing.id == button.id)
            {
                return Err(io::Error::other(
                    "task dialog button identifiers must be unique",
                ));
            }
        }
        let button_count = u32::try_from(spec.buttons.len())
            .map_err(|_| io::Error::other("too many task dialog buttons"))?;
        let title = wide(spec.title);
        let main_instruction = wide(spec.main_instruction);
        let content = wide(spec.content);
        let expanded_information = spec.expanded_information.map(wide);
        let expanded_control_text = expanded_information
            .as_ref()
            .map(|_| wide("진단 정보 숨기기"));
        let collapsed_control_text = expanded_information
            .as_ref()
            .map(|_| wide("진단 정보 표시"));
        let button_texts = spec
            .buttons
            .iter()
            .map(|button| wide(button.text))
            .collect::<Vec<_>>();
        let buttons = spec
            .buttons
            .iter()
            .zip(&button_texts)
            .map(|(button, text)| TASKDIALOG_BUTTON {
                nButtonID: button.id,
                pszButtonText: text.as_ptr(),
            })
            .collect::<Vec<_>>();
        let config = TASKDIALOGCONFIG {
            cbSize: size_of::<TASKDIALOGCONFIG>() as u32,
            hwndParent: owner,
            hInstance: null_mut(),
            dwFlags: TDF_ALLOW_DIALOG_CANCELLATION
                | TDF_POSITION_RELATIVE_TO_WINDOW
                | TDF_SIZE_TO_CONTENT
                | TDF_USE_COMMAND_LINKS,
            dwCommonButtons: TDCBF_CANCEL_BUTTON,
            pszWindowTitle: title.as_ptr(),
            Anonymous1: TASKDIALOGCONFIG_0 {
                pszMainIcon: if spec.warning {
                    TD_WARNING_ICON
                } else {
                    null()
                },
            },
            pszMainInstruction: main_instruction.as_ptr(),
            pszContent: content.as_ptr(),
            cButtons: button_count,
            pButtons: buttons.as_ptr(),
            nDefaultButton: IDCANCEL,
            cRadioButtons: 0,
            pRadioButtons: null(),
            nDefaultRadioButton: 0,
            pszVerificationText: null(),
            pszExpandedInformation: expanded_information
                .as_ref()
                .map_or(null(), |text| text.as_ptr()),
            pszExpandedControlText: expanded_control_text
                .as_ref()
                .map_or(null(), |text| text.as_ptr()),
            pszCollapsedControlText: collapsed_control_text
                .as_ref()
                .map_or(null(), |text| text.as_ptr()),
            Anonymous2: TASKDIALOGCONFIG_1 {
                pszFooterIcon: null(),
            },
            pszFooter: null(),
            pfCallback: None,
            lpCallbackData: 0,
            cxWidth: 0,
        };
        Ok(Self {
            _title: title,
            _main_instruction: main_instruction,
            _content: content,
            _expanded_information: expanded_information,
            _expanded_control_text: expanded_control_text,
            _collapsed_control_text: collapsed_control_text,
            _button_texts: button_texts,
            _buttons: buttons,
            config,
        })
    }
}

pub(super) fn task_dialog(owner: HWND, spec: TaskDialogSpec<'_>) -> io::Result<i32> {
    let dialog = OwnedTaskDialog::new(owner, spec)?;
    let mut selected_button = 0_i32;
    // SAFETY: config owns pointers into heap allocations retained by `dialog`
    // for this entire synchronous call. The owner is non-null, the custom-button
    // array is immutable, and the selected-button output points to live storage.
    let hresult =
        unsafe { TaskDialogIndirect(&dialog.config, &mut selected_button, null_mut(), null_mut()) };
    if hresult != 0 {
        return Err(io::Error::other(format!(
            "TaskDialogIndirect failed with HRESULT 0x{:08X}",
            hresult as u32
        )));
    }
    if selected_button == 0 {
        return Err(io::Error::other(
            "TaskDialogIndirect returned no selected button",
        ));
    }
    Ok(selected_button)
}

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
    pub(super) font: OwnedFont,
    pub(super) creation_error: Option<io::Error>,
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
        font: OwnedFont::default(),
        creation_error: None,
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
        return Err(state
            .creation_error
            .take()
            .unwrap_or_else(io::Error::last_os_error));
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
    state.font.replace(replacement);
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
    if state.font.as_raw().is_null() {
        return PromptFontMetrics::default();
    }
    let horizontal_padding = scale_dip(24, state.dpi);
    let maximum_title_width = scale_dip(520, state.dpi)
        .min(maximum_client.width.saturating_sub(horizontal_padding))
        .max(1);
    let maximum_label_width = scale_dip(138, state.dpi)
        .min(maximum_title_width.saturating_sub(scale_dip(8, state.dpi)) / 3);
    let title = measured_prompt_text(
        window,
        state.font.as_raw(),
        &state.spec.title,
        maximum_title_width,
    );
    let line = measured_prompt_text(window, state.font.as_raw(), "Mg", maximum_title_width);
    let label_one = measured_prompt_text(
        window,
        state.font.as_raw(),
        &state.spec.label_one,
        maximum_label_width,
    );
    let label_two = measured_prompt_text(
        window,
        state.font.as_raw(),
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
            let created = (|| -> io::Result<()> {
                state.title = child(window, "STATIC", &state.spec.title, 1001, SS_NOPREFIX)?;
                if !state.spec.label_one.is_empty() {
                    state.edit_one = child(
                        window,
                        "EDIT",
                        &state.spec.value_one.to_string_lossy(),
                        1004,
                        WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                    )?;
                    state.label_one =
                        child(window, "STATIC", &state.spec.label_one, 1002, SS_NOPREFIX)?;
                }
                if !state.spec.label_two.is_empty() {
                    state.edit_two = child(
                        window,
                        "EDIT",
                        &state.spec.value_two.to_string_lossy(),
                        1005,
                        WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                    )?;
                    state.label_two =
                        child(window, "STATIC", &state.spec.label_two, 1003, SS_NOPREFIX)?;
                }
                if !state.spec.choices.is_empty() {
                    let combo = child(
                        window,
                        "COMBOBOX",
                        "",
                        1006,
                        WS_TABSTOP | CBS_DROPDOWNLIST as u32,
                    )?;
                    for choice in &state.spec.choices {
                        let choice = wide(choice);
                        // SAFETY: combo is live and each choice pointer is owned terminated UTF-16 retained through synchronous SendMessageW.
                        let added = unsafe {
                            SendMessageW(combo, CB_ADDSTRING, 0, choice.as_ptr() as isize)
                        };
                        validate_combo_result(ComboOperation::AddString, added).map_err(
                            |error| {
                                io::Error::other(match error {
                                    ComboControlError::Rejected => {
                                        "combo box rejected a prompt choice"
                                    }
                                    ComboControlError::OutOfSpace => {
                                        "combo box ran out of space for prompt choices"
                                    }
                                })
                            },
                        )?;
                    }
                    // SAFETY: combo is the live dialog ComboBox and selection zero
                    // is valid because the choices collection is non-empty.
                    let selected = unsafe { SendMessageW(combo, CB_SETCURSEL, 0, 0) };
                    validate_combo_result(ComboOperation::Select, selected).map_err(|error| {
                        debug_assert_eq!(error, ComboControlError::Rejected);
                        io::Error::other("combo box could not select the first prompt choice")
                    })?;
                    state.combo = combo;
                }
                state.ok = child(
                    window,
                    "BUTTON",
                    "확인",
                    IDOK as u16,
                    WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
                )?;
                state.cancel = child(window, "BUTTON", "취소", IDCANCEL as u16, WS_TABSTOP)?;
                state.separator = child(window, "STATIC", "", 1010, SS_ETCHEDHORZ)?;
                Ok(())
            })();
            if let Err(error) = created {
                state.creation_error = Some(error);
                return -1;
            }
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
            // SAFETY: window is the active prompt HWND; clearing GWLP_USERDATA
            // ends the borrowed association before prompt_input drops its local
            // Box and its unambiguously owned font.
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
    match admit_paths(owner, state, paths) {
        Ok(()) => finalize_admission_start(state),
        Err(error) => {
            finalize_admission_start_failure(state);
            report_admission_start_error(owner, &error);
        }
    }
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

pub(super) fn import_names_dialog(owner: HWND, state: &mut AppState) -> Box<[usize]> {
    let Some(path) = modal_native_dialog(owner, || {
        native_file_dialog(owner)
            .set_title("바꿀 파일 이름 불러오기")
            .add_filter("Text Files", &["txt"])
            .add_filter("All Files", &["*"])
            .pick_file()
    }) else {
        return Box::default();
    };
    match read_legacy_text(&path) {
        Ok(text) => state.model.import_names_changed(&text),
        Err(error) => {
            message(
                owner,
                &format!("가져오기 파일을 읽지 못했습니다: {error}"),
                "DarkReNamer",
            );
            Box::default()
        }
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
    match admit_paths(owner, state, paths) {
        Ok(()) => finalize_admission_start(state),
        Err(error) => {
            finalize_admission_start_failure(state);
            report_admission_start_error(owner, &error);
        }
    }
}

pub(super) fn set_status(status: HWND, text: &str) {
    let text = wide(text);
    // SAFETY: status is a live UI-thread control and SetWindowTextW copies the
    // terminated buffer synchronously. Its ordinary invalidation paints only
    // after the caller's AppState borrow/callback boundary has ended.
    unsafe { windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(status, text.as_ptr()) };
}

pub(super) fn modal_native_dialog<T>(owner: HWND, dialog: impl FnOnce() -> T) -> T {
    let _owner_guard = OwnerEnableGuard::new(owner);
    dialog()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owned_task_dialog_keeps_cancel_default_and_all_native_buffers_live()
    -> Result<(), Box<dyn std::error::Error>> {
        let owner = 1_usize as HWND;
        let button_specs = [
            TaskDialogButtonSpec {
                id: DIRECTORY_DIRECT_BUTTON_ID,
                text: "선택한 폴더만 추가",
            },
            TaskDialogButtonSpec {
                id: DIRECTORY_RECURSE_BUTTON_ID,
                text: "하위 파일을 모두 추가",
            },
        ];
        let dialog = OwnedTaskDialog::new(
            owner,
            TaskDialogSpec {
                title: "제목",
                main_instruction: "선택",
                content: "범위",
                expanded_information: Some("진단"),
                buttons: &button_specs,
                warning: true,
            },
        )?;

        let config = dialog.config;
        let configured_owner = config.hwndParent;
        let flags = config.dwFlags;
        let common_buttons = config.dwCommonButtons;
        let default_button = config.nDefaultButton;
        let button_count = config.cButtons;
        let button_pointer = config.pButtons;
        let title_pointer = config.pszWindowTitle;
        let instruction_pointer = config.pszMainInstruction;
        let content_pointer = config.pszContent;
        let expanded_pointer = config.pszExpandedInformation;
        let expand_label_pointer = config.pszCollapsedControlText;
        let collapse_label_pointer = config.pszExpandedControlText;
        // SAFETY: Anonymous1 was initialized with the warning-icon pointer above.
        let main_icon = unsafe { config.Anonymous1.pszMainIcon };
        let first_button_id = dialog._buttons[0].nButtonID;
        let second_button_id = dialog._buttons[1].nButtonID;
        let first_button_text = dialog._buttons[0].pszButtonText;
        let second_button_text = dialog._buttons[1].pszButtonText;

        assert_eq!(configured_owner, owner);
        assert_eq!(common_buttons, TDCBF_CANCEL_BUTTON);
        assert_eq!(default_button, IDCANCEL);
        assert_eq!(button_count, 2);
        assert_eq!(button_pointer, dialog._buttons.as_ptr());
        assert_eq!(first_button_id, DIRECTORY_DIRECT_BUTTON_ID);
        assert_eq!(second_button_id, DIRECTORY_RECURSE_BUTTON_ID);
        assert_eq!(main_icon, TD_WARNING_ICON);
        assert_ne!(flags & TDF_USE_COMMAND_LINKS, 0);
        assert_ne!(flags & TDF_ALLOW_DIALOG_CANCELLATION, 0);
        assert_ne!(flags & TDF_POSITION_RELATIVE_TO_WINDOW, 0);
        assert_ne!(flags & TDF_SIZE_TO_CONTENT, 0);
        for pointer in [
            title_pointer,
            instruction_pointer,
            content_pointer,
            expanded_pointer,
            expand_label_pointer,
            collapse_label_pointer,
            first_button_text,
            second_button_text,
        ] {
            assert!(!pointer.is_null());
        }
        Ok(())
    }
}
