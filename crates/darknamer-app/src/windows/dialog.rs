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
    pub(super) edit_one: HWND,
    pub(super) edit_two: HWND,
    pub(super) combo: HWND,
    pub(super) font: HFONT,
    pub(super) dpi: u32,
}

pub(super) struct OwnerEnableGuard {
    pub(super) owner: HWND,
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

pub(super) fn import_names_dialog(owner: HWND, state: &mut AppState) {
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

pub(super) fn import_paths_dialog(owner: HWND, state: &mut AppState) {
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

pub(super) fn set_status(status: HWND, text: &str) {
    let text = wide(text);
    // SAFETY: window is the non-null top-level HWND just created and remains owned by this UI thread.
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(status, text.as_ptr());
        UpdateWindow(status);
    }
}

pub(super) fn modal_native_dialog<T>(owner: HWND, dialog: impl FnOnce() -> T) -> T {
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
