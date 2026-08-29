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

pub(super) fn high_contrast_enabled() -> bool {
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

pub(super) fn create_children(window: HWND, state: &mut AppState) -> io::Result<()> {
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

pub(super) fn create_toolbar(
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

pub(super) fn refresh_high_contrast_toolbars(window: HWND, state: &mut AppState) {
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

pub(super) const fn packed_dimensions(width: i32, height: i32) -> isize {
    ((width as u32 & 0xFFFF) | ((height as u32 & 0xFFFF) << 16)) as isize
}

pub(super) fn toolbar_accessible_name(command: CommandId) -> String {
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

pub(super) const fn toolbar_width_dip(high_contrast: bool) -> i32 {
    if high_contrast { 120 } else { TOOLBAR_WIDTH }
}

pub(super) fn arrange(window: HWND, state: &AppState) {
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

pub(super) fn set_toolbar_button_enabled(toolbar: HWND, command: CommandId, enabled: bool) {
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
        menu_item(menu, VERSION, "버전(H)");
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
