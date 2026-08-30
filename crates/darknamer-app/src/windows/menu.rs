use super::*;

#[derive(Debug)]
pub(super) struct OwnedFont(HFONT);

impl Default for OwnedFont {
    fn default() -> Self {
        Self(null_mut())
    }
}

impl OwnedFont {
    pub(super) fn as_raw(&self) -> HFONT {
        self.0
    }

    pub(super) fn replace(&mut self, replacement: HFONT) {
        let previous = std::mem::replace(&mut self.0, replacement);
        if !previous.is_null() {
            // SAFETY: previous was the distinct font owned by this wrapper and
            // no control uses it after every child received the replacement.
            unsafe { DeleteObject(previous) };
        }
    }
}

impl Drop for OwnedFont {
    fn drop(&mut self) {
        self.replace(null_mut());
    }
}

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
        SendMessageW(state.status_message, WM_SETFONT, status_font as usize, 1);
        SendMessageW(state.status_count, WM_SETFONT, status_font as usize, 1);
        SendMessageW(state.cancel_worker, WM_SETFONT, message_font as usize, 1);
    }
    if let Some(rail) = &state.left_rail {
        rail.apply_font(message_font);
    }
    if let Some(rail) = &state.right_rail {
        rail.apply_font(message_font);
    }
    state.font_metrics = measure_font_metrics(state.list_window, message_font, status_font);
    state.font.replace(message_font);
    state.status_font.replace(status_font);
}

pub(super) fn measure_font_metrics(
    window: HWND,
    message_font: HFONT,
    status_font: HFONT,
) -> MeasuredFontMetrics {
    let mut button_text_width = 0;
    let mut button_text_height = 0;
    for tool in rail_tool_specs(LEFT_RAIL).chain(rail_tool_specs(RIGHT_RAIL)) {
        if let Some((width, height)) = measure_text(window, message_font, tool.label, false) {
            button_text_width = button_text_width.max(width);
            button_text_height = button_text_height.max(height);
        }
    }
    let status_text_height =
        measure_text(window, status_font, EMPTY_LIST_STATUS, true).map_or(0, |(_, height)| height);
    let status_count_text_width =
        measure_text(window, status_font, STATUS_COUNT_SAMPLE, true).map_or(0, |(width, _)| width);
    let (cancel_text_width, cancel_text_height) =
        measure_text(window, message_font, STATUS_CANCEL_LABEL, true).unwrap_or_default();
    MeasuredFontMetrics {
        button_text_width,
        button_text_height,
        status_text_height,
        status_count_text_width,
        cancel_text_width,
        cancel_text_height,
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
    (
        state.status_message,
        state.status_count,
        state.cancel_worker,
    ) = create_status_controls(window)?;
    state.left_rail = Some(CommandRail::create(window, &LEFT_RAIL)?);
    state.right_rail = Some(CommandRail::create(window, &RIGHT_RAIL)?);
    refresh_system_fonts(state);
    // SAFETY: window is the live top-level HWND and DragAcceptFiles stores no borrowed pointer.
    unsafe { DragAcceptFiles(window, 1) };
    state.menu = create_menu()?.attach(window)?;
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

pub(super) fn create_status_controls(parent: HWND) -> io::Result<(HWND, HWND, HWND)> {
    let message = child(
        parent,
        "STATIC",
        "",
        STATUS_MESSAGE_ID as u16,
        SS_CENTERIMAGE | SS_SUNKEN | SS_NOPREFIX | SS_ENDELLIPSIS,
    )?;
    let count = child(
        parent,
        "STATIC",
        "",
        STATUS_COUNT_ID as u16,
        SS_CENTERIMAGE | SS_SUNKEN | SS_NOPREFIX | SS_ENDELLIPSIS,
    )?;
    let cancel = child(
        parent,
        "BUTTON",
        STATUS_CANCEL_LABEL,
        CANCEL_WORKER_ID,
        WS_TABSTOP,
    )?;
    // SAFETY: cancel is the newly created live worker-control HWND. It remains
    // hidden and disabled until one of the three cancellable workers is active.
    unsafe {
        EnableWindow(cancel, 0);
        ShowWindow(cancel, SW_HIDE);
    }
    Ok((message, count, cancel))
}

pub(super) fn child(
    parent: HWND,
    class: &str,
    text: &str,
    id: u16,
    extra_style: u32,
) -> io::Result<HWND> {
    let class = wide(class);
    let text = wide(text);
    // SAFETY: parent is a live HWND and the owned terminated class/text buffers
    // remain allocated through this synchronous child CreateWindowExW call.
    let child = unsafe {
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
    };
    if child.is_null() {
        Err(io::Error::last_os_error())
    } else {
        Ok(child)
    }
}

pub(super) fn arrange(window: HWND, state: &mut AppState) {
    // SAFETY: RECT is a C-compatible integer structure for which all-zero is a valid writable initial state.
    let mut rect: RECT = unsafe { zeroed() };
    // SAFETY: window is live and rect is writable RECT storage retained until GetClientRect returns.
    unsafe { GetClientRect(window, &mut rect) };
    let width = (rect.right - rect.left).max(0);
    let height = (rect.bottom - rect.top).max(0);
    let layout = calculate_main_layout(width, height, state.dpi, state.font_metrics);
    let rails_visible = layout.rail_mode != RailMode::MenuOnly;
    let previously_focused = focused_child(state);
    let mut windows = Vec::with_capacity(main_layout_window_count(&layout));
    if let Some(rail) = &state.left_rail {
        rail.append_placements(0, &layout.left_buttons, &mut windows);
    }
    if let Some(rail) = &state.right_rail {
        rail.append_placements(
            width.saturating_sub(layout.rail_width),
            &layout.right_buttons,
            &mut windows,
        );
    }
    windows.push((state.list_window, layout.list));
    windows.push((state.status_message, layout.status_message));
    windows.push((state.status_count, layout.status_count));
    windows.push((state.cancel_worker, layout.cancel));
    apply_deferred_layout(&windows);
    if state.rails_visible != rails_visible {
        if let Some(rail) = &state.left_rail {
            rail.set_visible(rails_visible);
        }
        if let Some(rail) = &state.right_rail {
            rail.set_visible(rails_visible);
        }
    }
    state.rails_visible = rails_visible;
    repair_focus_state(state);
    if !rails_visible && previously_focused.is_some_and(|(child, _)| child != FocusChild::List) {
        schedule_focus_restore(state);
    }
    update_primary_column_widths(state);
    // SAFETY: one parent invalidation repaints the completed child batch,
    // column sizing, and any visibility changes without per-control immediate
    // repaint requests.
    unsafe {
        RedrawWindow(
            window,
            null(),
            null_mut(),
            RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
        )
    };
}

fn apply_deferred_layout(windows: &[(HWND, LayoutRect)]) {
    let count = i32::try_from(windows.len()).unwrap_or(i32::MAX);
    // SAFETY: count is the bounded number of live child windows supplied below.
    let mut batch = unsafe { BeginDeferWindowPos(count) };
    if !batch.is_null() {
        for (window, rect) in windows {
            // SAFETY: batch is the current live HDWP and every window/rectangle
            // remains valid for this synchronous deferred-position operation.
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
        // SAFETY: batch is the live handle returned by the final successful
        // DeferWindowPos call and is consumed exactly once here.
        if unsafe { EndDeferWindowPos(batch) } != 0 {
            return;
        }
    }
    for (window, rect) in windows {
        // SAFETY: fallback applies the same checked child geometry without
        // repaint; the caller performs one parent redraw after the full batch.
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
    let previously_focused = focused_child(state);
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
    apply_cancel_control_state(state);
    repair_focus_state(state);
    let focused_target_changed = match previously_focused {
        Some((FocusChild::LeftRail, Some(index))) => {
            focus_index(state, FocusChild::LeftRail) != Some(index)
        }
        Some((FocusChild::RightRail, Some(index))) => {
            focus_index(state, FocusChild::RightRail) != Some(index)
        }
        _ => false,
    };
    if focused_target_changed {
        schedule_focus_restore(state);
    }
}

pub(super) fn apply_cancel_control_state(state: &AppState) {
    let control = cancel_control_state(state.worker_activity());
    // SAFETY: this UI-thread query returns a non-owning HWND value only.
    let cancel_had_focus = unsafe { GetFocus() == state.cancel_worker };
    // SAFETY: cancel_worker is the live standard BUTTON owned by AppState.
    // Visibility follows worker lifetime; a repeated request stays visible but
    // disabled until terminal handoff removes the worker from AppState.
    unsafe {
        EnableWindow(state.cancel_worker, i32::from(control.is_enabled()));
        ShowWindow(
            state.cancel_worker,
            if control.is_visible() {
                SW_SHOW
            } else {
                SW_HIDE
            },
        );
    }
    if cancel_had_focus && !control.is_enabled() {
        // Disabling a focused native control clears focus. Restore it through a
        // posted message so SetFocus runs only after this AppState borrow ends.
        // SAFETY: list_window is a live direct child while AppState exists.
        let parent = unsafe { GetParent(state.list_window) };
        schedule_focus_target(parent, state.list_window);
    }
}

fn rail_enabled_states(state: &AppState, spec: CommandRailSpec) -> Vec<bool> {
    spec.commands()
        .map(|command| state.command_states[usize::from(command - APPLY)])
        .collect()
}

fn focus_index(state: &AppState, child: FocusChild) -> Option<usize> {
    let enabled = match child {
        FocusChild::List => return None,
        FocusChild::LeftRail => rail_enabled_states(state, LEFT_RAIL),
        FocusChild::RightRail => rail_enabled_states(state, RIGHT_RAIL),
    };
    state
        .focus
        .active_index(child, &enabled, state.rails_visible)
}

fn repair_focus_state(state: &mut AppState) {
    let left = rail_enabled_states(state, LEFT_RAIL);
    let right = rail_enabled_states(state, RIGHT_RAIL);
    state.focus.repair(&left, &right, state.rails_visible);
    if let Some(rail) = &state.left_rail {
        rail.set_tab_stop(state.focus.active_index(
            FocusChild::LeftRail,
            &left,
            state.rails_visible,
        ));
    }
    if let Some(rail) = &state.right_rail {
        rail.set_tab_stop(state.focus.active_index(
            FocusChild::RightRail,
            &right,
            state.rails_visible,
        ));
    }
}

fn focus_window(state: &AppState, action: FocusAction) -> Option<HWND> {
    match action {
        FocusAction::List => (!state.list_window.is_null()).then_some(state.list_window),
        FocusAction::LeftRail(index) => state.left_rail.as_ref()?.hwnd_at(index),
        FocusAction::RightRail(index) => state.right_rail.as_ref()?.hwnd_at(index),
    }
}

fn focus_target(state: &mut AppState) -> Option<HWND> {
    repair_focus_state(state);
    focus_window(state, state.focus.action())
        .or_else(|| (!state.list_window.is_null()).then_some(state.list_window))
}

fn schedule_focus_restore(state: &AppState) {
    // SAFETY: list_window is a live direct child while AppState exists. Posting
    // is non-reentrant; the handler re-resolves and validates state and target.
    let parent = unsafe { GetParent(state.list_window) };
    if !parent.is_null() {
        schedule_focus_target(parent, null_mut());
    }
}

pub(super) fn schedule_focus_target(window: HWND, target: HWND) {
    if window.is_null() {
        return;
    }
    // SAFETY: window is the live top-level owner at the call site. The HWND is
    // copied as a non-owning request and revalidated when the message runs.
    unsafe { PostMessageW(window, WM_APP_RESTORE_FOCUS, target as usize, 0) };
}

fn focused_child(state: &AppState) -> Option<(FocusChild, Option<usize>)> {
    // SAFETY: this query reads the current UI-thread focus HWND only.
    let focused = unsafe { GetFocus() };
    if focused.is_null() {
        return None;
    }
    if focused == state.list_window {
        return Some((FocusChild::List, None));
    }
    if let Some(index) = state
        .left_rail
        .as_ref()
        .and_then(|rail| rail.index_for_hwnd(focused))
    {
        return Some((FocusChild::LeftRail, Some(index)));
    }
    state
        .right_rail
        .as_ref()
        .and_then(|rail| rail.index_for_hwnd(focused))
        .map(|index| (FocusChild::RightRail, Some(index)))
}

pub(super) fn record_child_focus(state: &mut AppState, focused: HWND) -> bool {
    let focused_child = if focused == state.list_window {
        Some((FocusChild::List, None))
    } else if let Some(index) = state
        .left_rail
        .as_ref()
        .and_then(|rail| rail.index_for_hwnd(focused))
    {
        Some((FocusChild::LeftRail, Some(index)))
    } else {
        state
            .right_rail
            .as_ref()
            .and_then(|rail| rail.index_for_hwnd(focused))
            .map(|index| (FocusChild::RightRail, Some(index)))
    };
    let Some((child, index)) = focused_child else {
        return false;
    };
    state.focus.record(child, index);
    repair_focus_state(state);
    true
}

pub(super) fn restore_child_focus(state: &mut AppState) -> Option<HWND> {
    focus_target(state)
}

pub(super) fn handle_focus_navigation(state: &mut AppState, message: &MSG) -> Option<HWND> {
    if message.message != WM_KEYDOWN {
        return None;
    }
    if let Some((child, index)) = focused_child(state) {
        state.focus.record(child, index);
    }
    let left = rail_enabled_states(state, LEFT_RAIL);
    let right = rail_enabled_states(state, RIGHT_RAIL);
    let target = match u16::try_from(message.wParam).ok() {
        Some(VK_F6) => Some(state.focus.cycle_major(&left, &right, state.rails_visible)),
        Some(VK_UP) => state
            .focus
            .move_within_rail(false, &left, &right, state.rails_visible)
            .map(|(child, _)| child),
        Some(VK_DOWN) => state
            .focus
            .move_within_rail(true, &left, &right, state.rails_visible)
            .map(|(child, _)| child),
        _ => return None,
    };
    let target = target?;
    repair_focus_state(state);
    let action = match target {
        FocusChild::List => FocusAction::List,
        FocusChild::LeftRail => FocusAction::LeftRail(state.focus.left_rail_index),
        FocusChild::RightRail => FocusAction::RightRail(state.focus.right_rail_index),
    };
    focus_window(state, action)
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

#[derive(Debug)]
pub(super) struct OwnedMenu(HMENU);

impl OwnedMenu {
    fn new_bar() -> io::Result<Self> {
        // SAFETY: CreateMenu takes no pointers and returns a newly owned menu.
        let menu = unsafe { CreateMenu() };
        (!menu.is_null())
            .then_some(Self(menu))
            .ok_or_else(io::Error::last_os_error)
    }

    fn new_popup() -> io::Result<Self> {
        // SAFETY: CreatePopupMenu takes no pointers and returns a newly owned menu.
        let menu = unsafe { CreatePopupMenu() };
        (!menu.is_null())
            .then_some(Self(menu))
            .ok_or_else(io::Error::last_os_error)
    }

    fn as_raw(&self) -> HMENU {
        self.0
    }

    fn release(&mut self) -> HMENU {
        std::mem::replace(&mut self.0, null_mut())
    }

    pub(super) fn attach(mut self, window: HWND) -> io::Result<HMENU> {
        // SAFETY: window and this unattached menu are live; successful SetMenu
        // transfers menu destruction to the top-level window.
        if unsafe { SetMenu(window, self.0) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(self.release())
    }
}

impl Drop for OwnedMenu {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: only unattached menus remain non-null in this owner. Child
            // popups already transferred to this menu are destroyed recursively.
            unsafe { DestroyMenu(self.0) };
            self.0 = null_mut();
        }
    }
}

struct MenuBuilder {
    menu: OwnedMenu,
}

impl MenuBuilder {
    fn bar() -> io::Result<Self> {
        OwnedMenu::new_bar().map(|menu| Self { menu })
    }

    fn popup() -> io::Result<Self> {
        OwnedMenu::new_popup().map(|menu| Self { menu })
    }

    fn item(&mut self, id: u16, label: &str) -> io::Result<()> {
        let label = wide(label);
        // SAFETY: the menu is live and label is retained terminated UTF-16 for
        // the complete synchronous AppendMenuW call.
        if unsafe {
            AppendMenuW(
                self.menu.as_raw(),
                MF_STRING,
                usize::from(id),
                label.as_ptr(),
            )
        } == 0
        {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    fn separator(&mut self) -> io::Result<()> {
        // SAFETY: the menu is live and separators carry no pointer payload.
        if unsafe { AppendMenuW(self.menu.as_raw(), MF_SEPARATOR, 0, null()) } == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    fn popup_child(&mut self, mut popup: Self, label: &str) -> io::Result<()> {
        let label = wide(label);
        // SAFETY: both menus are unattached and live; success transfers popup
        // ownership into the parent menu's recursive ownership tree.
        if unsafe {
            AppendMenuW(
                self.menu.as_raw(),
                MF_POPUP,
                popup.menu.as_raw() as usize,
                label.as_ptr(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        popup.menu.release();
        Ok(())
    }

    fn finish(self) -> OwnedMenu {
        self.menu
    }
}

pub(super) fn create_menu() -> io::Result<OwnedMenu> {
    let mut menu = MenuBuilder::bar()?;
    append_catalog_popup(&mut menu, MenuGroup::File, "파일(&F)")?;
    append_catalog_popup(&mut menu, MenuGroup::Edit, "편집(&E)")?;
    append_catalog_popup(&mut menu, MenuGroup::View, "보기(&V)")?;
    append_catalog_popup(&mut menu, MenuGroup::Tools, "기능(&T)")?;
    let mut recovery = MenuBuilder::popup()?;
    recovery.item(EXPORT_RECOVERY_JOURNAL, "보존된 저널 바이트 내보내기...")?;
    recovery.item(DISCARD_STAGED_JOURNAL, "활성화 전 실행 계획 폐기...")?;
    recovery.item(SHOW_RECOVERY_STATUS, "복구 상태 보기...")?;
    menu.popup_child(recovery, "복구(&R)")?;
    append_catalog_items(&mut menu, MenuGroup::About)?;
    Ok(menu.finish())
}

fn append_catalog_popup(menu: &mut MenuBuilder, group: MenuGroup, label: &str) -> io::Result<()> {
    let mut popup = MenuBuilder::popup()?;
    append_catalog_items(&mut popup, group)?;
    menu.popup_child(popup, label)
}

fn append_catalog_items(menu: &mut MenuBuilder, group: MenuGroup) -> io::Result<()> {
    let mut specs = COMMAND_UI_SPECS
        .iter()
        .filter(|spec| spec.menu.group == group)
        .collect::<Vec<_>>();
    specs.sort_by_key(|spec| (spec.menu.section, spec.menu.order));
    let mut previous_section = None;
    for spec in specs {
        if previous_section.is_some_and(|section| section != spec.menu.section) {
            menu.separator()?;
        }
        previous_section = Some(spec.menu.section);
        menu.item(spec.id, &command_menu_label(spec))?;
    }
    if group == MenuGroup::File {
        // Exit is an auxiliary shell command outside the contiguous catalog.
        menu.separator()?;
        let label = legacy_command_shortcut(EXIT_COMMAND).map_or_else(
            || "종료(&X)".to_owned(),
            |shortcut| format!("종료(&X)\t{}", shortcut.display),
        );
        menu.item(EXIT_COMMAND, &label)?;
    }
    Ok(())
}
