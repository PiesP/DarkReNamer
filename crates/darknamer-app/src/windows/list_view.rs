use super::*;

const LIST_VIEW_NOTIFICATION_SUBCLASS_ID: usize = 1;

pub(super) fn install_list_view_notification_subclass(state: &AppState) -> io::Result<()> {
    // AppState is allocated in its final Box before child creation. The subclass
    // is removed during owner teardown before that Box is reclaimed.
    let state_ref = state as *const AppState as usize;
    // SAFETY: list_window is a live UI-thread ListView, the callback has the
    // documented SUBCLASSPROC ABI, and state_ref follows the lifetime contract
    // described above.
    if unsafe {
        SetWindowSubclass(
            state.list_window,
            Some(list_view_notification_subclass),
            LIST_VIEW_NOTIFICATION_SUBCLASS_ID,
            state_ref,
        )
    } == 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

pub(super) fn remove_list_view_notification_subclass(list_window: HWND) {
    if list_window.is_null() {
        return;
    }
    // SAFETY: removal is idempotent for the exact live-or-destroying ListView,
    // callback, and identifier installed above.
    unsafe {
        RemoveWindowSubclass(
            list_window,
            Some(list_view_notification_subclass),
            LIST_VIEW_NOTIFICATION_SUBCLASS_ID,
        )
    };
}

unsafe extern "system" fn list_view_notification_subclass(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _subclass_id: usize,
    state_ref: usize,
) -> LRESULT {
    if message == WM_NCDESTROY {
        remove_list_view_notification_subclass(window);
        // SAFETY: the original parameters are forwarded exactly once after the
        // subclass has stopped retaining AppState refdata.
        return unsafe { DefSubclassProc(window, message, wparam, lparam) };
    }
    if message == WM_NOTIFY && state_ref != 0 && !programmatic_list_update_active() {
        let notification = lparam as *const NMHDR;
        // Validate the pointer-free native routing boundary before borrowing
        // AppState. Programmatic SendMessage callers retain their existing
        // mutable borrow and are deliberately delegated to DefSubclassProc.
        if !notification.is_null() {
            // SAFETY: window is the live ListView and this value query retains no
            // caller storage.
            let header = unsafe { SendMessageW(window, LVM_GETHEADER, 0, 0) } as HWND;
            // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix synchronously.
            let is_header_draw = !header.is_null()
                && unsafe {
                    (*notification).hwndFrom == header && (*notification).code == NM_CUSTOMDRAW
                };
            if is_header_draw {
                // SAFETY: the owner removes this subclass before reclaiming the
                // stable Box<AppState>. The programmatic re-entry guard above
                // excludes synchronous callers that retain &mut AppState.
                let state = unsafe { &*(state_ref as *const AppState) };
                if let Some(result) = handle_header_custom_draw(state, lparam) {
                    return result;
                }
            }
        }
    }
    // SAFETY: every notification not owned by the header painter is forwarded
    // unchanged through the common-controls subclass chain exactly once.
    unsafe { DefSubclassProc(window, message, wparam, lparam) }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RenderedRow {
    pub(super) values: [LegacyText; 7],
    pub(super) icon: i32,
}

pub(super) fn update_column_visibility(state: &mut AppState, index: usize) {
    let column = index + 3;
    state.column_states[column].set_visible(state.shown_columns[index]);
    let width = if state.column_states[column].visible {
        state.column_states[column].width_px(state.dpi)
    } else {
        0
    };
    let _list_update = ProgrammaticListUpdateGuard::begin();
    // SAFETY: state.list_window is live and the message carries scaled integers.
    unsafe {
        SendMessageW(
            state.list_window,
            LVM_SETCOLUMNWIDTH,
            column,
            width as isize,
        );
    }
}

pub(super) fn update_dpi_metrics(state: &mut AppState) {
    for index in 0..state.shown_columns.len() {
        update_column_visibility(state, index);
    }
}

pub(super) fn update_primary_column_widths(state: &AppState) {
    // SAFETY: RECT is a C-compatible integer structure with valid zero state.
    let mut rect: RECT = unsafe { zeroed() };
    // SAFETY: list_window is live and rect remains writable through this call.
    if unsafe { GetClientRect(state.list_window, &mut rect) } == 0 {
        return;
    }
    // SAFETY: this system-metric query has no pointer parameters and uses the
    // live window's normalized DPI.
    let scrollbar_allowance = unsafe { GetSystemMetricsForDpi(SM_CXVSCROLL, state.dpi) }
        .max(scale_dip(LIST_SCROLLBAR_ALLOWANCE_DIP, state.dpi));
    let widths = allocate_primary_column_widths(
        rect.right - rect.left,
        state.dpi,
        &state.column_states,
        scrollbar_allowance,
    );
    let _list_update = ProgrammaticListUpdateGuard::begin();
    for (column, width) in widths.into_iter().enumerate() {
        // SAFETY: list_window is live and the message carries a checked column
        // index and an adaptive pixel width without a pointer payload.
        unsafe {
            SendMessageW(
                state.list_window,
                LVM_SETCOLUMNWIDTH,
                column,
                width as isize,
            )
        };
    }
}

pub(super) fn handle_header_end_track(state: &mut AppState, lparam: LPARAM) -> bool {
    let header = lparam as *const NMHDR;
    if header.is_null() {
        return false;
    }
    // SAFETY: the ListView is live and LVM_GETHEADER returns its borrowed
    // header child HWND without dereferencing caller memory.
    let header_window = unsafe { SendMessageW(state.list_window, LVM_GETHEADER, 0, 0) } as HWND;
    // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix for this synchronous
    // callback; the pointer has been checked above.
    let (source_window, code) = unsafe { ((*header).hwndFrom, (*header).code) };
    // Depending on the common-controls version, the ListView can forward the
    // embedded header notification while retaining either source HWND.
    let from_header = source_window == header_window || source_window == state.list_window;
    if header_window.is_null() || !from_header || code != HDN_ENDTRACKW {
        return false;
    }
    let notification = lparam as *const NMHEADERW;
    // SAFETY: HDN_ENDTRACKW supplies NMHEADERW storage with an NMHDR prefix.
    let Ok(column) = usize::try_from(unsafe { (*notification).iItem }) else {
        return true;
    };
    if column >= state.column_states.len() {
        return true;
    }
    // SAFETY: notification is live NMHEADERW storage for this synchronous
    // callback; pitem, when non-null, points to its readable HDITEMW payload.
    let item = unsafe { (*notification).pitem };
    // SAFETY: a non-null pitem points to the live HDITEMW payload owned by the
    // header control for this synchronous notification.
    let item_has_width = !item.is_null() && unsafe { (*item).mask & HDI_WIDTH != 0 };
    let width = if item_has_width {
        // SAFETY: the checked pitem contains the width field advertised by its
        // HDI_WIDTH mask.
        unsafe { (*item).cxy }
    } else {
        // SAFETY: the ListView is live and this message returns one integer
        // column width without retaining caller memory.
        unsafe { SendMessageW(state.list_window, LVM_GETCOLUMNWIDTH, column, 0) as i32 }
    };
    state.column_states[column].record_user_resize(width, state.dpi);
    state.persist_column_preferences();
    true
}

pub(super) fn handle_header_custom_draw(state: &AppState, lparam: LPARAM) -> Option<LRESULT> {
    let resources = state.appearance_resources.as_ref()?;
    let header = lparam as *const NMHDR;
    if header.is_null() {
        return None;
    }
    // SAFETY: list_window is live and returns its borrowed Header child.
    let header_window = unsafe { SendMessageW(state.list_window, LVM_GETHEADER, 0, 0) } as HWND;
    // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix synchronously.
    let (source, code) = unsafe { ((*header).hwndFrom, (*header).code) };
    if header_window.is_null() || source != header_window || code != NM_CUSTOMDRAW {
        return None;
    }
    let custom = lparam as *const NMCUSTOMDRAW;
    if custom.is_null() {
        return Some(CDRF_DODEFAULT as LRESULT);
    }
    // SAFETY: Header NM_CUSTOMDRAW supplies NMCUSTOMDRAW storage.
    let stage = unsafe { (*custom).dwDrawStage };
    if stage == CDDS_PREPAINT {
        let mut rect = RECT::default();
        // SAFETY: header/DC are live and rect is writable for this paint.
        unsafe {
            GetClientRect(header_window, &mut rect);
            FillRect((*custom).hdc, &rect, resources.header_brush());
        }
        return Some((CDRF_NOTIFYITEMDRAW | CDRF_NOTIFYPOSTPAINT) as LRESULT);
    }
    if stage == CDDS_POSTPAINT {
        let mut client = RECT::default();
        // SAFETY: header/DC are live and client is writable for this paint.
        unsafe { GetClientRect(header_window, &mut client) };
        // SAFETY: this value query retains no caller storage.
        let item_count = unsafe { SendMessageW(header_window, HDM_GETITEMCOUNT, 0, 0) };
        if item_count > 0 {
            let mut last = RECT::default();
            // SAFETY: item_count-1 names the final live header item and last is
            // writable for this synchronous rectangle query.
            if unsafe {
                SendMessageW(
                    header_window,
                    HDM_GETITEMRECT,
                    usize::try_from(item_count - 1).unwrap_or_default(),
                    (&raw mut last) as LPARAM,
                )
            } != 0
            {
                client.left = last.right.clamp(client.left, client.right);
            }
        }
        if client.left < client.right {
            // SAFETY: callback DC and header brush remain live through postpaint.
            unsafe { FillRect((*custom).hdc, &client, resources.header_brush()) };
        }
        return Some(CDRF_DODEFAULT as LRESULT);
    }
    if stage != CDDS_ITEMPREPAINT {
        return Some(CDRF_DODEFAULT as LRESULT);
    }
    // SAFETY: item spec/state/rect/DC belong to this live Header callback.
    let item = unsafe { (*custom).dwItemSpec };
    let mut label = vec![0_u16; 256];
    let mut header_item = HDITEMW {
        mask: HDI_TEXT,
        pszText: label.as_mut_ptr(),
        cchTextMax: i32::try_from(label.len()).unwrap_or(i32::MAX),
        ..HDITEMW::default()
    };
    // SAFETY: header_item and label remain writable through the synchronous query.
    if unsafe {
        SendMessageW(
            header_window,
            HDM_GETITEMW,
            item,
            (&mut header_item as *mut HDITEMW) as LPARAM,
        )
    } == 0
    {
        return Some(CDRF_DODEFAULT as LRESULT);
    }
    let length = label
        .iter()
        .position(|unit| *unit == 0)
        .unwrap_or(label.len());
    let palette = resources.palette();
    // SAFETY: same live callback fields as above.
    let state_flags = unsafe { (*custom).uItemState };
    let background = if state_flags & CDIS_SELECTED != 0 {
        resources.control_brush(true, false, false)
    } else if state_flags & CDIS_HOT != 0 {
        resources.control_brush(false, true, false)
    } else {
        resources.header_brush()
    };
    // SAFETY: the item rectangle is copied from the same live callback storage.
    let mut rect = unsafe { (*custom).rc };
    // SAFETY: the callback DC and resource-owned brushes remain live for this draw.
    unsafe {
        FillRect((*custom).hdc, &rect, background);
        FrameRect((*custom).hdc, &rect, resources.border_brush());
        SetBkMode((*custom).hdc, TRANSPARENT as i32);
        SetTextColor((*custom).hdc, palette.text_primary);
    }
    rect.left = rect.left.saturating_add(scale_dip(8, state.dpi));
    rect.right = rect.right.saturating_sub(scale_dip(8, state.dpi));
    let alignment = if item == 4 { DT_RIGHT } else { DT_LEFT };
    // SAFETY: label/rect/DC remain live for synchronous text drawing.
    unsafe {
        DrawTextW(
            (*custom).hdc,
            label.as_ptr(),
            i32::try_from(length).unwrap_or(i32::MAX),
            &mut rect,
            alignment | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX,
        )
    };
    Some(CDRF_SKIPDEFAULT as LRESULT)
}

/// Applies restrained colors only to an unselected changed proposed-name cell.
/// Every other stage and state remains under the native ListView renderer.
pub(super) fn handle_list_custom_draw(state: &AppState, lparam: LPARAM) -> Option<LRESULT> {
    let header = lparam as *const NMHDR;
    if header.is_null()
        // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix for this
        // synchronous callback; the pointer was checked above.
        || unsafe { (*header).hwndFrom } != state.list_window
        // SAFETY: same live NMHDR storage as the source-window read above.
        || unsafe { (*header).code } != NM_CUSTOMDRAW
    {
        return None;
    }
    let custom = lparam as *mut NMLVCUSTOMDRAW;
    if custom.is_null() {
        return Some(CDRF_DODEFAULT as LRESULT);
    }
    // SAFETY: NM_CUSTOMDRAW from a ListView supplies NMLVCUSTOMDRAW storage for
    // the duration of this synchronous notification.
    let stage = unsafe { (*custom).nmcd.dwDrawStage };
    if stage == CDDS_PREPAINT {
        return Some(CDRF_NOTIFYITEMDRAW as LRESULT);
    }
    if stage == CDDS_ITEMPREPAINT {
        return Some(CDRF_NOTIFYSUBITEMDRAW as LRESULT);
    }
    if stage != (CDDS_ITEMPREPAINT | CDDS_SUBITEM) {
        return Some(CDRF_DODEFAULT as LRESULT);
    }

    // SAFETY: same live NMLVCUSTOMDRAW payload validated above.
    let row = unsafe { (*custom).nmcd.dwItemSpec };
    // SAFETY: same payload; iSubItem is an integral field.
    let subitem = unsafe { (*custom).iSubItem };
    if subitem < 1 {
        return Some(CDRF_DODEFAULT as LRESULT);
    }
    let Some(item) = state.model.items().get(row) else {
        return Some(CDRF_DODEFAULT as LRESULT);
    };
    // NMCUSTOMDRAW.uItemState can report stale CDIS_SELECTED state for a
    // ListView using LVS_SHOWSELALWAYS. Query the control's authoritative item
    // state so native selection/focus rendering always takes precedence.
    // SAFETY: list_window is the live notification source, row names an item
    // already validated against the synchronized model, and the message uses
    // only integral parameters without retaining caller memory.
    let item_state = unsafe {
        SendMessageW(
            state.list_window,
            LVM_GETITEMSTATE,
            row,
            (LVIS_SELECTED | LVIS_FOCUSED) as LPARAM,
        )
    } as u32;
    let selected = item_state & LVIS_SELECTED != 0;
    let focused = item_state & LVIS_FOCUSED != 0;
    if selected {
        return Some(CDRF_DODEFAULT as LRESULT);
    }
    if item.current_name() == item.proposed_name() {
        return Some(CDRF_DODEFAULT as LRESULT);
    }
    // Resolve cached system state only after every cheaper semantic/native
    // precedence gate. Forced Colors and unknown queries disable custom colors.
    let resolved = state.resolved_appearance();
    let visual = proposed_name_visual_decision(ProposedNameVisualContext {
        row: Some(row),
        row_count: state.model.len(),
        subitem,
        changed: true,
        issue: state.preview_issue_cache.issue(row),
        selected,
        focused,
        custom_colors_enabled: resolved.custom_colors_enabled,
    });
    if let Some(colors) = proposed_name_colors(resolved, visual) {
        // SAFETY: this callback owns writable NMLVCUSTOMDRAW fields until it
        // returns. Default drawing consumes the colors; no font/text/focus
        // rendering is replaced and no caller pointer is retained.
        unsafe {
            (*custom).clrText = colors.text;
            if let Some(background) = colors.background {
                (*custom).clrTextBk = background;
            }
        }
        // ListView custom draw requires this protocol return after changing
        // subitem font or color fields.
        return Some(CDRF_NEWFONT as LRESULT);
    }
    // The ListView reuses NMLVCUSTOMDRAW color fields across later subitems in
    // the same row. Once subitem 1 was accented, explicitly restore semantic
    // defaults so the proposed-name styling cannot leak into path/metadata.
    if subitem > 1
        && resolved.custom_colors_enabled
        && let Some(palette) = semantic_palette(resolved.theme)
    {
        // SAFETY: same writable callback payload as the target-cell branch.
        unsafe {
            (*custom).clrText = palette.text_primary;
            (*custom).clrTextBk = palette.surface_workspace;
        }
        return Some(CDRF_NEWFONT as LRESULT);
    }
    Some(CDRF_DODEFAULT as LRESULT)
}

pub(super) fn handle_list_infotip(state: &AppState, lparam: LPARAM) -> bool {
    let header = lparam as *const NMHDR;
    if header.is_null()
        // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix for this
        // synchronous callback; the pointer was checked above.
        || unsafe { (*header).hwndFrom } != state.list_window
        // SAFETY: same live NMHDR storage as the hwndFrom read above.
        || unsafe { (*header).code } != LVN_GETINFOTIPW
    {
        return false;
    }
    let notification = lparam as *mut NMLVGETINFOTIPW;
    // SAFETY: LVN_GETINFOTIPW supplies writable NMLVGETINFOTIPW storage.
    let Ok(row) = usize::try_from(unsafe { (*notification).iItem }) else {
        return true;
    };
    let Some(item) = state.model.items().get(row) else {
        return true;
    };
    let preview = match state.preview_issue_cache.issue(row) {
        PreviewRowIssue::InvalidName(error) => format!(
            "잘못된 대상 이름: {} · Windows에서 사용할 수 있는 이름으로 수정하세요.",
            windows_leaf_name_error_korean(error)
        ),
        PreviewRowIssue::DuplicateDestination => {
            "대상 이름 충돌 · 같은 폴더의 대상 이름과 다르게 수정하세요.".to_owned()
        }
        PreviewRowIssue::EmptyStem => "이름 본체가 비어 있음 · 변경 전 확인 필요".to_owned(),
        PreviewRowIssue::None if item.current_name() != item.proposed_name() => {
            "변경 예정".to_owned()
        }
        PreviewRowIssue::None => "변경 없음".to_owned(),
    };
    let text = format!(
        "{preview}\n{}\n{}\n정확한 크기: {}",
        item.current_name(),
        item.source_path(),
        format_exact_bytes(item.actual_size())
    );
    let mut text = text.encode_utf16().collect::<Vec<_>>();
    // SAFETY: notification is live writable storage and its buffer/count pair
    // belongs to the ListView for this synchronous callback.
    let destination = unsafe { (*notification).pszText };
    // SAFETY: same NMLVGETINFOTIPW storage as destination.
    let capacity = unsafe { (*notification).cchTextMax };
    if destination.is_null() || capacity <= 0 {
        return true;
    }
    let copy_len = text
        .len()
        .min(usize::try_from(capacity - 1).unwrap_or_default());
    text.truncate(copy_len);
    // SAFETY: destination has capacity UTF-16 units, copy_len is at most one
    // less, source is live and non-overlapping, and the terminator is in-bounds.
    unsafe {
        destination.copy_from_nonoverlapping(text.as_ptr(), copy_len);
        *destination.add(copy_len) = 0;
    }
    true
}

struct RedrawGuard {
    window: HWND,
}

impl RedrawGuard {
    unsafe fn suspend(window: HWND) -> Self {
        if !window.is_null() {
            // SAFETY: window is a live ListView and the message has no pointer.
            unsafe { SendMessageW(window, WM_SETREDRAW, 0, 0) };
        }
        Self { window }
    }
}

impl Drop for RedrawGuard {
    fn drop(&mut self) {
        if !self.window.is_null() {
            // SAFETY: this is the same live ListView suspended by the guard.
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

pub(super) fn refresh(state: &mut AppState) {
    update_dpi_metrics(state);
    let infotip_styles = LVS_EX_LABELTIP | LVS_EX_INFOTIP;
    // SAFETY: state.list_window is live and the masked extended-style update
    // carries no pointer while preserving unrelated ListView styles.
    unsafe {
        SendMessageW(
            state.list_window,
            LVM_SETEXTENDEDLISTVIEWSTYLE,
            infotip_styles as usize,
            infotip_styles as isize,
        )
    };
    refresh_all_rows(state);
    update_controls(state);
    state.set_status_item_count();
}

pub(super) fn refresh_all_rows(state: &mut AppState) {
    refresh_preview_count_cache(state);
    let rows = {
        let model = &state.model;
        let icon_cache = &mut state.icon_cache;
        model
            .items()
            .iter()
            .map(|item| rendered_row(icon_cache, item))
            .collect::<Vec<_>>()
    };
    let _list_update = ProgrammaticListUpdateGuard::begin();
    // SAFETY: state.list_window is live and the guard restores redraw.
    let _redraw = unsafe { RedrawGuard::suspend(state.list_window) };
    let selected = selected_indices(state.list_window);
    if !apply_incremental_rows(state.list_window, &state.rendered_rows, &rows) {
        rebuild_native_rows(state.list_window, &rows);
    }
    state.rendered_rows = rows;
    select_rows(state.list_window, &selected);
}

pub(super) fn refresh_changed_rows(state: &mut AppState, changed: &[usize]) {
    if state.rendered_rows.len() != state.model.len() {
        refresh(state);
        return;
    }
    refresh_preview_count_cache(state);
    let mut changed = changed
        .iter()
        .copied()
        .filter(|index| *index < state.model.len())
        .collect::<Vec<_>>();
    changed.sort_unstable();
    changed.dedup();
    let rows = {
        let model = &state.model;
        let icon_cache = &mut state.icon_cache;
        changed
            .iter()
            .map(|index| (*index, rendered_row(icon_cache, &model.items()[*index])))
            .collect::<Vec<_>>()
    };
    let _list_update = ProgrammaticListUpdateGuard::begin();
    // SAFETY: state.list_window is live and the guard restores redraw.
    let _redraw = unsafe { RedrawGuard::suspend(state.list_window) };
    for (index, row) in rows {
        if !apply_rendered_row(state.list_window, index, &state.rendered_rows[index], &row) {
            drop(_redraw);
            refresh(state);
            return;
        }
        state.rendered_rows[index] = row;
    }
}

pub(super) fn refresh_proposal_rows(state: &mut AppState, changed: &[usize]) {
    let Some(plan) = proposal_refresh_plan(state.model.len(), state.rendered_rows.len(), changed)
    else {
        refresh(state);
        return;
    };
    refresh_preview_count_cache(state);
    debug_assert_eq!(plan.proposal_cells, plan.rows.len());
    debug_assert_eq!(plan.immutable_cells, 0);
    debug_assert_eq!(plan.full_row_formats, 0);
    let _list_update = ProgrammaticListUpdateGuard::begin();
    // SAFETY: state.list_window is live and the guard restores redraw.
    let _redraw = unsafe { RedrawGuard::suspend(state.list_window) };
    for row in plan.rows {
        let proposed = state.model.items()[row].proposed_name();
        if state.rendered_rows[row].values[1] == *proposed {
            continue;
        }
        if !set_native_subitem(state.list_window, row, 1, proposed) {
            drop(_redraw);
            refresh(state);
            return;
        }
        state.rendered_rows[row].values[1].clone_from(proposed);
    }
}

fn refresh_preview_count_cache(state: &mut AppState) {
    state.preview_count_cache.refresh(
        state
            .model
            .items()
            .iter()
            .map(|item| (item.current_name(), item.proposed_name())),
    );
    state.preview_issue_cache.refresh_by(
        state.model.items().iter().map(|item| {
            (
                item.root_path(),
                item.current_name(),
                item.proposed_name(),
                item.is_directory(),
            )
        }),
        preview_destination_key,
    );
    state
        .ui_status
        .set_preview_notice(state.preview_issue_cache.notice());
}

fn preview_destination_key(
    destination_parent: &LegacyText,
    destination_leaf: &LegacyText,
) -> crate::rename::PathKey {
    let mut destination_units =
        Vec::with_capacity(destination_parent.len() + 1 + destination_leaf.len());
    destination_units.extend_from_slice(destination_parent.units());
    if !destination_parent
        .units()
        .last()
        .is_some_and(|unit| *unit == b'\\' as u16 || *unit == b'/' as u16)
    {
        destination_units.push(b'\\' as u16);
    }
    destination_units.extend_from_slice(destination_leaf.units());
    let destination = LegacyText::from_units(destination_units);
    RenameBackend::path_key(&WindowsRenameBackend, &destination)
}

fn rendered_row(icon_cache: &mut HashMap<IconCacheKey, i32>, item: &LegacyListItem) -> RenderedRow {
    RenderedRow {
        values: [
            item.current_name().clone(),
            item.proposed_name().clone(),
            item.root_path().clone(),
            item.source_path().clone(),
            LegacyText::from(format_iec_file_size(item.actual_size())),
            format_filetime(item.modified()),
            format_filetime(item.created()),
        ],
        icon: file_icon_index(icon_cache, item),
    }
}

fn apply_incremental_rows(window: HWND, old: &[RenderedRow], new: &[RenderedRow]) -> bool {
    for row in (new.len()..old.len()).rev() {
        // SAFETY: window is live and row is a current trailing item.
        if unsafe { SendMessageW(window, LVM_DELETEITEM, row, 0) } == 0 {
            return false;
        }
    }
    let shared = old.len().min(new.len());
    for row in 0..shared {
        if !apply_rendered_row(window, row, &old[row], &new[row]) {
            return false;
        }
    }
    for (row, value) in new.iter().enumerate().skip(old.len()) {
        if !insert_native_row(window, row, value) {
            return false;
        }
    }
    true
}

fn apply_rendered_row(window: HWND, row: usize, old: &RenderedRow, new: &RenderedRow) -> bool {
    let mask = changed_column_mask(old, new);
    if mask & 1 != 0 && !set_native_primary(window, row, new) {
        return false;
    }
    for column in 1..7 {
        if mask & (1 << column) != 0
            && !set_native_subitem(window, row, column, &new.values[column])
        {
            return false;
        }
    }
    true
}

pub(super) fn changed_column_mask(old: &RenderedRow, new: &RenderedRow) -> u8 {
    let mut mask = u8::from(old.icon != new.icon);
    for column in 0..7 {
        if old.values[column] != new.values[column] {
            mask |= 1 << column;
        }
    }
    mask
}

fn insert_native_row(window: HWND, row: usize, value: &RenderedRow) -> bool {
    let mut text = value.values[0].units().to_vec();
    text.push(0);
    let mut native = LVITEMW {
        mask: LVIF_TEXT | LVIF_IMAGE,
        iItem: i32::try_from(row).unwrap_or(i32::MAX),
        iSubItem: 0,
        pszText: text.as_mut_ptr(),
        iImage: value.icon,
        // SAFETY: LVITEMW is C-compatible and zero is valid for unused fields.
        ..unsafe { zeroed() }
    };
    // SAFETY: window is live; native and text outlive the synchronous message.
    if unsafe {
        SendMessageW(
            window,
            LVM_INSERTITEMW,
            0,
            (&mut native as *mut LVITEMW) as isize,
        )
    } < 0
    {
        return false;
    }
    (1..7).all(|column| set_native_subitem(window, row, column, &value.values[column]))
}

fn set_native_primary(window: HWND, row: usize, value: &RenderedRow) -> bool {
    let mut text = value.values[0].units().to_vec();
    text.push(0);
    let mut native = LVITEMW {
        mask: LVIF_TEXT | LVIF_IMAGE,
        iItem: i32::try_from(row).unwrap_or(i32::MAX),
        iSubItem: 0,
        pszText: text.as_mut_ptr(),
        iImage: value.icon,
        // SAFETY: LVITEMW is C-compatible and zero is valid for unused fields.
        ..unsafe { zeroed() }
    };
    // SAFETY: window is live; native and text outlive the synchronous message.
    unsafe {
        SendMessageW(
            window,
            LVM_SETITEMW,
            0,
            (&mut native as *mut LVITEMW) as isize,
        ) != 0
    }
}

fn set_native_subitem(window: HWND, row: usize, column: usize, value: &LegacyText) -> bool {
    let mut text = value.units().to_vec();
    text.push(0);
    let mut native = LVITEMW {
        iSubItem: i32::try_from(column).unwrap_or(i32::MAX),
        pszText: text.as_mut_ptr(),
        // SAFETY: LVITEMW is C-compatible and zero is valid for unused fields.
        ..unsafe { zeroed() }
    };
    // SAFETY: window is live; native and text outlive the synchronous message.
    unsafe {
        SendMessageW(
            window,
            LVM_SETITEMTEXTW,
            row,
            (&mut native as *mut LVITEMW) as isize,
        )
    };
    true
}

fn rebuild_native_rows(window: HWND, rows: &[RenderedRow]) {
    // SAFETY: window is live and the message carries no pointer.
    unsafe { SendMessageW(window, LVM_DELETEALLITEMS, 0, 0) };
    for (row, value) in rows.iter().enumerate() {
        if !insert_native_row(window, row, value) {
            break;
        }
    }
}

fn file_icon_index(cache: &mut HashMap<IconCacheKey, i32>, item: &LegacyListItem) -> i32 {
    let key = icon_cache_key(item.current_name(), item.is_directory());
    if let Some(index) = cache.get(&key) {
        return *index;
    }
    // SAFETY: SHFILEINFOW is a valid output structure when zero initialized.
    let mut info: SHFILEINFOW = unsafe { zeroed() };
    let path = key.lookup_text();
    let mut path = path.units().to_vec();
    path.push(0);
    let attributes = if item.is_directory() {
        FILE_ATTRIBUTE_DIRECTORY
    } else {
        FILE_ATTRIBUTE_NORMAL
    };
    // SAFETY: path is terminated and info is writable for the shell query.
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
    let Some(system) = local_systemtime_from_filetime(value) else {
        return LegacyText::default();
    };
    if let Some(localized) = format_local_systemtime(&system) {
        return LegacyText::from(localized);
    }
    LegacyText::from(format_timestamp_fallback(
        [system.wYear, system.wMonth, system.wDay],
        [system.wHour, system.wMinute, system.wSecond],
    ))
}

fn local_systemtime_from_filetime(value: u64) -> Option<SYSTEMTIME> {
    if value == 0 {
        return None;
    }
    let filetime = FILETIME {
        dwLowDateTime: value as u32,
        dwHighDateTime: (value >> 32) as u32,
    };
    // SAFETY: SYSTEMTIME has a valid all-zero representation for output.
    let mut utc: SYSTEMTIME = unsafe { zeroed() };
    // SAFETY: filetime is readable UTC input and utc remains writable through
    // this synchronous representation conversion.
    if unsafe { FileTimeToSystemTime(&filetime, &mut utc) } == 0 {
        return None;
    }
    // SAFETY: SYSTEMTIME has a valid all-zero representation for output.
    let mut local: SYSTEMTIME = unsafe { zeroed() };
    // SAFETY: null selects the current dynamic Windows time zone, including
    // its date-specific transition rules; utc is readable and local writable.
    if unsafe { SystemTimeToTzSpecificLocalTimeEx(null(), &utc, &mut local) } == 0 {
        return None;
    }
    Some(local)
}

fn format_local_systemtime(system: &SYSTEMTIME) -> Option<String> {
    let date = format_locale_part(|buffer, capacity| {
        // SAFETY: null locale selects the user's default locale, system is
        // readable, and buffer/capacity are either the documented size query
        // pair or writable storage supplied by format_locale_part.
        unsafe {
            GetDateFormatEx(
                null(),
                DATE_SHORTDATE,
                system,
                null(),
                buffer,
                capacity,
                null(),
            )
        }
    })?;
    let time = format_locale_part(|buffer, capacity| {
        // SAFETY: null locale selects the user's default locale, system is
        // readable, and buffer/capacity follow the GetTimeFormatEx contract.
        unsafe { GetTimeFormatEx(null(), 0, system, null(), buffer, capacity) }
    })?;
    Some(format!("{date} {time}"))
}

fn format_locale_part(mut format: impl FnMut(*mut u16, i32) -> i32) -> Option<String> {
    let required = format(null_mut(), 0);
    let capacity = usize::try_from(required).ok()?;
    if capacity <= 1 {
        return None;
    }
    let mut buffer = vec![0_u16; capacity];
    let written = format(buffer.as_mut_ptr(), required);
    if written <= 1 {
        return None;
    }
    let text_len = usize::try_from(written - 1).ok()?;
    String::from_utf16(buffer.get(..text_len)?).ok()
}

#[cfg(test)]
mod native_tests {
    use super::*;

    #[test]
    fn preview_destination_key_matches_planner_windows_path_policy() {
        let backend = WindowsRenameBackend;
        for (parent, leaf, expected) in [
            (r"C:\work", "item.txt", r"C:\work\item.txt"),
            (r"C:\work\", "item.txt", r"C:\work\item.txt"),
            ("C:/work/", "item.txt", "C:/work/item.txt"),
        ] {
            assert_eq!(
                preview_destination_key(&LegacyText::from(parent), &LegacyText::from(leaf)),
                RenameBackend::path_key(&backend, &LegacyText::from(expected))
            );
        }

        assert_eq!(
            preview_destination_key(&LegacyText::from(r"C:\Locale"), &LegacyText::from("I.txt"),),
            preview_destination_key(&LegacyText::from("c:/locale"), &LegacyText::from("i.TXT"),),
            "invariant Windows folding must not depend on the user's locale",
        );
    }

    #[test]
    fn known_utc_filetime_uses_current_dynamic_timezone_without_mutation() {
        // 2024-01-15 12:00:00 UTC. Every Windows time zone maps this to
        // January 15 or 16, while the exact local clock remains environment-owned.
        let local = local_systemtime_from_filetime(133_497_936_000_000_000);

        assert!(local.is_some());
        if let Some(local) = local {
            assert_eq!(local.wYear, 2024);
            assert_eq!(local.wMonth, 1);
            assert!((15..=16).contains(&local.wDay));
            assert!(local.wHour < 24);
            assert!(!format_filetime(133_497_936_000_000_000).units().is_empty());
        }
    }
}
