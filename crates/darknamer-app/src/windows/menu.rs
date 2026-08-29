use super::*;

pub(super) fn nonclient_metrics(dpi: u32) -> Option<NONCLIENTMETRICSW> {
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

pub(super) fn create_message_font(dpi: u32) -> HFONT {
    let Some(metrics) = nonclient_metrics(dpi) else {
        return null_mut();
    };
    // SAFETY: lfMessageFont is fully initialized by SystemParametersInfoForDpi
    // and the native call copies the descriptor synchronously.
    unsafe { CreateFontIndirectW(&raw const metrics.lfMessageFont) }
}

pub(super) fn create_status_font(dpi: u32) -> HFONT {
    let Some(metrics) = nonclient_metrics(dpi) else {
        return null_mut();
    };
    // SAFETY: lfStatusFont is fully initialized by SystemParametersInfoForDpi
    // and the native call copies the descriptor synchronously.
    unsafe { CreateFontIndirectW(&raw const metrics.lfStatusFont) }
}

pub(super) fn refresh_system_fonts(state: &mut AppState) {
    let message_font = create_message_font(state.dpi);
    let status_font = create_status_font(state.dpi);
    // SAFETY: child HWNDs are live; a null font selects the control's default.
    unsafe {
        SendMessageW(state.list_window, WM_SETFONT, message_font as usize, 1);
        SendMessageW(state.status, WM_SETFONT, status_font as usize, 1);
    }
    if let Some(rail) = &state.left_rail {
        rail.apply_font(message_font);
    }
    if let Some(rail) = &state.right_rail {
        rail.apply_font(message_font);
    }
    state.font_metrics = measure_font_metrics(state.list_window, message_font, status_font);
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

pub(super) fn measure_font_metrics(
    window: HWND,
    message_font: HFONT,
    status_font: HFONT,
) -> MeasuredFontMetrics {
    let mut button_text_width = 0;
    let mut button_text_height = 0;
    for tool in LEFT_TOOLS.iter().chain(RIGHT_TOOLS.iter()) {
        if let Some((width, height)) = measure_text(window, message_font, tool.label, false) {
            button_text_width = button_text_width.max(width);
            button_text_height = button_text_height.max(height);
        }
    }
    let status_text_height =
        measure_text(window, status_font, EMPTY_LIST_STATUS, true).map_or(0, |(_, height)| height);
    MeasuredFontMetrics {
        button_text_width,
        button_text_height,
        status_text_height,
    }
}

fn measure_text(window: HWND, font: HFONT, text: &str, single_line: bool) -> Option<(i32, i32)> {
    if window.is_null() || font.is_null() || text.is_empty() {
        return None;
    }
    let text = wide(text);
    let length = i32::try_from(text.len().checked_sub(1)?).ok()?;
    // SAFETY: window and font are live UI-thread handles; the returned DC is
    // released before return and no selected object is deleted while selected.
    let dc = unsafe { GetDC(window) };
    if dc.is_null() {
        return None;
    }
    // SAFETY: dc is live and font remains AppState-owned beyond this call.
    let previous = unsafe { SelectObject(dc, font) };
    let mut rect = RECT::default();
    let mut format = DT_CALCRECT | DT_NOPREFIX;
    if single_line {
        format |= DT_SINGLELINE;
    }
    // SAFETY: text is terminated live UTF-16 storage with checked length and
    // rect remains writable throughout this synchronous measurement.
    let measured = unsafe { DrawTextW(dc, text.as_ptr(), length, &mut rect, format) };
    if !previous.is_null() {
        // SAFETY: previous is the object returned from selecting into this DC.
        unsafe { SelectObject(dc, previous) };
    }
    // SAFETY: dc was acquired from this exact window in this function.
    unsafe { ReleaseDC(window, dc) };
    (measured > 0).then_some((
        (rect.right - rect.left).max(0),
        (rect.bottom - rect.top).max(0),
    ))
}

pub(super) fn create_children(window: HWND, state: &mut AppState) -> io::Result<()> {
    // SAFETY: window is the live top-level HWND being initialized.
    let dpi = unsafe { GetDpiForWindow(window) };
    state.dpi = if dpi == 0 { BASE_DPI } else { dpi };
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
            SS_CENTERIMAGE | SS_SUNKEN | SS_NOPREFIX | SS_ENDELLIPSIS,
        )
    };
    state.left_rail = Some(CommandRail::create(window, &LEFT_RAIL, &LEFT_TOOLS)?);
    state.right_rail = Some(CommandRail::create(window, &RIGHT_RAIL, &RIGHT_TOOLS)?);
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
    Ok(())
}

pub(super) fn child(parent: HWND, class: &str, text: &str, id: u16, extra_style: u32) -> HWND {
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

pub(super) fn arrange(window: HWND, state: &AppState) {
    // SAFETY: RECT is a C-compatible integer structure for which all-zero is a valid writable initial state.
    let mut rect: RECT = unsafe { zeroed() };
    // SAFETY: window is live and rect is writable RECT storage retained until GetClientRect returns.
    unsafe { GetClientRect(window, &mut rect) };
    let width = (rect.right - rect.left).max(0);
    let height = (rect.bottom - rect.top).max(0);
    let layout = calculate_main_layout(width, height, state.dpi, state.font_metrics);
    let rails_visible = layout.rail_mode != RailMode::MenuOnly;
    if let Some(rail) = &state.left_rail {
        rail.arrange(0, &layout.left_buttons);
        rail.set_visible(rails_visible);
    }
    if let Some(rail) = &state.right_rail {
        rail.arrange(
            width.saturating_sub(layout.rail_width),
            &layout.right_buttons,
        );
        rail.set_visible(rails_visible);
    }
    // SAFETY: window plus AppState's list/status children are live on this UI
    // thread; each MoveWindow call retains no borrowed storage.
    unsafe {
        MoveWindow(
            state.list_window,
            layout.list.x,
            layout.list.y,
            layout.list.width,
            layout.list.height,
            1,
        );
        MoveWindow(
            state.status,
            layout.status.x,
            layout.status.y,
            layout.status.width,
            layout.status.height,
            1,
        );
    }
    update_primary_column_widths(state);
}

pub(super) fn move_window_dip(window: HWND, x: i32, y: i32, width: i32, height: i32, dpi: u32) {
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

pub(super) fn update_controls(state: &mut AppState) {
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

pub(super) fn apply_command_states(state: &AppState) {
    for id in LEFT_RAIL.commands() {
        if let Some(rail) = &state.left_rail {
            rail.set_enabled(id, state.command_states[usize::from(id - APPLY)]);
        }
    }
    for id in RIGHT_RAIL.commands() {
        if let Some(rail) = &state.right_rail {
            rail.set_enabled(id, state.command_states[usize::from(id - APPLY)]);
        }
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
    let can_export_journal = state.can_export_recovery_journal();
    // SAFETY: state.menu is the live application menu and the diagnostic
    // command identifier is owned by this process.
    unsafe {
        EnableMenuItem(
            state.menu,
            u32::from(EXPORT_RECOVERY_JOURNAL),
            MF_BYCOMMAND
                | if can_export_journal {
                    MF_ENABLED
                } else {
                    MF_GRAYED
                },
        );
        EnableMenuItem(
            state.menu,
            u32::from(DISCARD_STAGED_JOURNAL),
            MF_BYCOMMAND
                | if state.can_discard_staged_intent() {
                    MF_ENABLED
                } else {
                    MF_GRAYED
                },
        );
        EnableMenuItem(
            state.menu,
            u32::from(SHOW_RECOVERY_STATUS),
            MF_BYCOMMAND
                | if state.recovery_locked {
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

pub(super) fn create_menu() -> HMENU {
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
            "보존된 저널 바이트 내보내기...",
        );
        menu_item(
            recovery,
            DISCARD_STAGED_JOURNAL,
            "활성화 전 실행 계획 폐기...",
        );
        menu_item(recovery, SHOW_RECOVERY_STATUS, "복구 상태 보기...");
        append_popup(menu, recovery, "복구(&R)");
        menu_item(menu, VERSION, VERSION_MENU_LABEL);
    }
    menu
}

pub(super) fn menu_item(menu: HMENU, id: u16, label: &str) {
    let label = wide(label);
    // SAFETY: menu/popup are live HMENU values and label is owned terminated UTF-16 retained through AppendMenuW.
    unsafe { AppendMenuW(menu, MF_STRING, usize::from(id), label.as_ptr()) };
}

pub(super) fn append_popup(menu: HMENU, popup: HMENU, label: &str) {
    let label = wide(label);
    // SAFETY: menu/popup are live HMENU values and label is owned terminated UTF-16 retained through AppendMenuW.
    unsafe { AppendMenuW(menu, MF_POPUP, popup as usize, label.as_ptr()) };
}
