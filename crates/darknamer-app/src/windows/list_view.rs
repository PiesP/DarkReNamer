use super::*;

const LIST_VIEW_NOTIFICATION_SUBCLASS_ID: usize = 1;
const STATUS_COLUMN_TEXT_PADDING_DIP: i32 = 24;
const STATUS_COLUMN_TEXT_SAMPLES: [&str; 7] = [
    NATIVE_STATUS_COLUMN.label,
    "이름 변경 예정",
    "이동 예정",
    "이동·이름 변경 예정",
    "주의: 이름 본체",
    "차단: 이름",
    "차단: 충돌",
];

pub(super) fn install_list_view_notification_subclass(state: &AppState) -> io::Result<()> {
    // Store only the copied owner HWND. Each callback resolves and leases the
    // owner's currently published state instead of retaining an AppState pointer.
    // SAFETY: list_window is a live direct child during installation.
    let owner_ref = unsafe { GetParent(state.list_window) } as usize;
    // SAFETY: list_window is a live UI-thread ListView, the callback has the
    // documented SUBCLASSPROC ABI, and owner_ref is a copied HWND value.
    if unsafe {
        SetWindowSubclass(
            state.list_window,
            Some(list_view_notification_subclass),
            LIST_VIEW_NOTIFICATION_SUBCLASS_ID,
            owner_ref,
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
    owner_ref: usize,
) -> LRESULT {
    if message == WM_NCDESTROY {
        remove_list_view_notification_subclass(window);
        // SAFETY: the original parameters are forwarded exactly once after the
        // subclass has stopped retaining AppState refdata.
        return unsafe { DefSubclassProc(window, message, wparam, lparam) };
    }
    if message == WM_NOTIFY && owner_ref != 0 && !programmatic_list_update_active() {
        let notification = lparam as *const NMHDR;
        // Validate the pointer-free native routing boundary before borrowing
        // AppState. Programmatic SendMessage callers retain their existing
        // mutable borrow and are deliberately delegated to DefSubclassProc.
        if !notification.is_null() {
            // SAFETY: window is the live ListView and this value query retains no
            // caller storage.
            let header = unsafe { SendMessageW(window, LVM_GETHEADER, 0, 0) } as HWND;
            let owner = owner_ref as HWND;
            let Some(mut state_lease) = try_app_state(owner) else {
                // SAFETY: same-state reentry must not reconstruct AppState;
                // preserve the common-control chain unchanged instead.
                return unsafe { DefSubclassProc(window, message, wparam, lparam) };
            };
            let state = state_lease.state_mut();
            if let Some(result) = handle_status_header_double_click(
                state.list_window,
                header,
                state.font.as_raw(),
                state.dpi,
                lparam,
            ) {
                state.status_column_width_dip = NATIVE_STATUS_COLUMN_WIDTH_DIP;
                update_primary_column_widths(state);
                return result;
            }
            // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix synchronously.
            let is_header_draw = !header.is_null()
                && unsafe {
                    (*notification).hwndFrom == header && (*notification).code == NM_CUSTOMDRAW
                };
            if is_header_draw && let Some(result) = handle_header_custom_draw(state, lparam) {
                return result;
            }
        }
    }
    // SAFETY: every notification not owned by the header painter is forwarded
    // unchanged through the common-controls subclass chain exactly once.
    unsafe { DefSubclassProc(window, message, wparam, lparam) }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RenderedRow {
    pub(super) values: [LegacyText; NATIVE_LIST_COLUMN_COUNT],
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
    set_native_status_column_width(state);
}

fn set_native_status_column_width(state: &AppState) {
    set_native_status_column_width_for(state.list_window, native_status_column_width_px(state));
}

fn set_native_status_column_width_for(list_window: HWND, width: i32) {
    // SAFETY: list_window is live and the fixed native-only column index and
    // DPI-scaled width are integral values retained by the control.
    unsafe {
        SendMessageW(
            list_window,
            LVM_SETCOLUMNWIDTH,
            NATIVE_STATUS_COLUMN_INDEX,
            width.max(0) as isize,
        )
    };
}

pub(super) fn native_status_column_minimum_px(state: &AppState) -> i32 {
    native_status_column_minimum_px_for(state.list_window, state.font.as_raw(), state.dpi)
}

fn native_status_column_minimum_px_for(list_window: HWND, font: HFONT, dpi: u32) -> i32 {
    let measured = STATUS_COLUMN_TEXT_SAMPLES
        .into_iter()
        .filter_map(|text| measure_text(list_window, font, text, true))
        .map(|(width, _height)| width)
        .max()
        .unwrap_or_default()
        .saturating_add(scale_dip(STATUS_COLUMN_TEXT_PADDING_DIP, dpi));
    scale_dip(NATIVE_STATUS_COLUMN_WIDTH_DIP, dpi).max(measured)
}

fn native_status_column_width_px(state: &AppState) -> i32 {
    scale_dip(state.status_column_width_dip, state.dpi).max(native_status_column_minimum_px(state))
}

fn reset_native_status_column_width(state: &mut AppState) {
    state.status_column_width_dip = NATIVE_STATUS_COLUMN_WIDTH_DIP;
    set_native_status_column_width(state);
    update_primary_column_widths(state);
}

fn handle_status_header_double_click(
    list_window: HWND,
    header_window: HWND,
    font: HFONT,
    dpi: u32,
    lparam: LPARAM,
) -> Option<LRESULT> {
    let header = lparam as *const NMHDR;
    if header.is_null() || header_window.is_null() {
        return None;
    }
    // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix synchronously.
    let (source_window, code) = unsafe { ((*header).hwndFrom, (*header).code) };
    if source_window != header_window || code != HDN_DIVIDERDBLCLICKW {
        return None;
    }
    let notification = lparam as *const NMHEADERW;
    // SAFETY: HDN_DIVIDERDBLCLICKW supplies NMHEADERW storage with an NMHDR prefix.
    let Ok(column) = usize::try_from(unsafe { (*notification).iItem }) else {
        return None;
    };
    if column != NATIVE_STATUS_COLUMN_INDEX {
        return None;
    }
    let _list_update = ProgrammaticListUpdateGuard::begin();
    set_native_status_column_width_for(
        list_window,
        native_status_column_minimum_px_for(list_window, font, dpi),
    );
    // Returning nonzero to the Header control's direct parent replaces default
    // auto-sizing with the measured minimum for this native-only column.
    Some(1)
}

fn list_column_width(list_window: HWND, column: usize) -> i32 {
    // SAFETY: the live ListView returns one integral column width and retains no
    // caller storage.
    unsafe { SendMessageW(list_window, LVM_GETCOLUMNWIDTH, column, 0) as i32 }
}

pub(super) fn native_list_header_height_px(list_window: HWND) -> i32 {
    // SAFETY: list_window is a live ListView and returns its borrowed Header child HWND.
    let header = unsafe { SendMessageW(list_window, LVM_GETHEADER, 0, 0) } as HWND;
    if header.is_null() {
        return 0;
    }
    let mut rect = RECT::default();
    // SAFETY: header is live and rect remains writable for this synchronous query.
    if unsafe { GetWindowRect(header, &mut rect) } == 0 {
        return 0;
    }
    rect.bottom.saturating_sub(rect.top).max(0)
}

pub(super) fn update_primary_column_widths(state: &AppState) {
    let mut rect = RECT::default();
    // SAFETY: list_window is live and rect remains writable through this call.
    if unsafe { GetClientRect(state.list_window, &mut rect) } == 0 {
        return;
    }
    // Fall back only if the native control has no usable status-column width.
    let current_status_width = list_column_width(state.list_window, NATIVE_STATUS_COLUMN_INDEX);
    let status_width = if current_status_width > 0 {
        current_status_width
    } else {
        native_status_column_width_px(state)
    };
    let widths = allocate_primary_column_widths(
        rect.right.saturating_sub(rect.left),
        status_width,
        state.dpi,
        &state.column_states,
    );
    let _list_update = ProgrammaticListUpdateGuard::begin();
    for (column, width) in widths.into_iter().enumerate() {
        let current = list_column_width(state.list_window, column);
        if current != width {
            // SAFETY: same live ListView and checked primary-column index.
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
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HeaderColumnNotification {
    EndTrack(Option<usize>),
    DividerDoubleClick(Option<usize>),
}

fn header_column_notification(
    header_window: HWND,
    list_window: HWND,
    lparam: LPARAM,
) -> Option<HeaderColumnNotification> {
    let header = lparam as *const NMHDR;
    if header.is_null() {
        return None;
    }
    // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix for this synchronous
    // callback; the pointer has been checked above.
    let (source_window, code) = unsafe { ((*header).hwndFrom, (*header).code) };
    // Depending on the common-controls version, the ListView can forward the
    // embedded header notification while retaining either source HWND.
    let from_header = source_window == header_window || source_window == list_window;
    if header_window.is_null()
        || !from_header
        || !matches!(code, HDN_ENDTRACKW | HDN_DIVIDERDBLCLICKW)
    {
        return None;
    }
    let notification = lparam as *const NMHEADERW;
    // SAFETY: the source and notification code were narrowed above to the two
    // Header contracts that supply NMHEADERW storage. In particular, ListView
    // notifications such as NM_SETFOCUS expose only the NMHDR prefix and return
    // before this extended-field read.
    let column = usize::try_from(unsafe { (*notification).iItem }).ok();
    Some(if code == HDN_DIVIDERDBLCLICKW {
        HeaderColumnNotification::DividerDoubleClick(column)
    } else {
        HeaderColumnNotification::EndTrack(column)
    })
}

pub(super) fn handle_header_end_track(state: &mut AppState, lparam: LPARAM) -> bool {
    // SAFETY: the ListView is live and LVM_GETHEADER returns its borrowed
    // header child HWND without dereferencing caller memory.
    let header_window = unsafe { SendMessageW(state.list_window, LVM_GETHEADER, 0, 0) } as HWND;
    let Some(notification) = header_column_notification(header_window, state.list_window, lparam)
    else {
        return false;
    };
    let column = match notification {
        HeaderColumnNotification::EndTrack(None) => return true,
        HeaderColumnNotification::DividerDoubleClick(None) => return false,
        HeaderColumnNotification::EndTrack(Some(column))
        | HeaderColumnNotification::DividerDoubleClick(Some(column)) => column,
    };
    if matches!(
        notification,
        HeaderColumnNotification::DividerDoubleClick(_)
    ) {
        if column == NATIVE_STATUS_COLUMN_INDEX {
            let _list_update = ProgrammaticListUpdateGuard::begin();
            reset_native_status_column_width(state);
            return true;
        }
        return false;
    }
    if column == NATIVE_STATUS_COLUMN_INDEX {
        let requested_width = {
            let header_fields = lparam as *const NMHEADERW;
            // SAFETY: header_column_notification established a live NMHEADERW;
            // its non-null pitem advertises cxy through HDI_WIDTH. Otherwise the
            // live ListView returns the current integral width without retaining
            // caller memory.
            unsafe {
                let item = (*header_fields).pitem;
                if !item.is_null() && (*item).mask & HDI_WIDTH != 0 {
                    (*item).cxy
                } else {
                    SendMessageW(
                        state.list_window,
                        LVM_GETCOLUMNWIDTH,
                        NATIVE_STATUS_COLUMN_INDEX,
                        0,
                    ) as i32
                }
            }
        };
        let minimum = native_status_column_minimum_px(state);
        state.status_column_width_dip =
            status_column_width_after_resize(requested_width, minimum, state.dpi);
        let _list_update = ProgrammaticListUpdateGuard::begin();
        set_native_status_column_width(state);
        update_primary_column_widths(state);
        return true;
    }
    if column >= state.column_states.len() {
        return true;
    }
    // SAFETY: header_column_notification established that this callback carries
    // live NMHEADERW storage; pitem, when non-null, points to its readable
    // HDITEMW payload.
    let header_fields = lparam as *const NMHEADERW;
    // SAFETY: the validated synchronous callback owns live NMHEADERW storage.
    let item = unsafe { (*header_fields).pitem };
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
        let mut item_right_edges = Vec::with_capacity(usize::try_from(item_count).unwrap_or(0));
        for item in 0..usize::try_from(item_count).unwrap_or(0) {
            let mut rect = RECT::default();
            // SAFETY: every index is below the queried live item count and rect
            // remains writable for the synchronous rectangle query.
            if unsafe {
                SendMessageW(
                    header_window,
                    HDM_GETITEMRECT,
                    item,
                    (&raw mut rect) as LPARAM,
                )
            } != 0
            {
                item_right_edges.push(rect.right);
            }
        }
        let chrome = calculate_header_chrome(
            LayoutRect {
                x: client.left,
                y: client.top,
                width: client.right.saturating_sub(client.left),
                height: client.bottom.saturating_sub(client.top),
            },
            &item_right_edges,
        );
        let to_rect = |rect: LayoutRect| RECT {
            left: rect.x,
            top: rect.y,
            right: rect.right(),
            bottom: rect.bottom(),
        };
        // SAFETY: callback DC and resource brushes remain live through
        // postpaint; calculated rectangles stay within the header client.
        unsafe {
            let gutter = to_rect(chrome.gutter);
            if gutter.left < gutter.right && gutter.top < gutter.bottom {
                FillRect((*custom).hdc, &gutter, resources.header_brush());
            }
            let bottom = to_rect(chrome.bottom_line);
            if bottom.left < bottom.right && bottom.top < bottom.bottom {
                FillRect((*custom).hdc, &bottom, resources.border_brush());
            }
            for divider in chrome.item_dividers {
                let divider = to_rect(divider);
                if divider.left < divider.right && divider.top < divider.bottom {
                    FillRect((*custom).hdc, &divider, resources.border_brush());
                }
            }
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
    if !item.planned_change_kind().renames() {
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
    let change = item.planned_change_kind();
    let preview = match state.preview_issue_cache.issue(row) {
        PreviewRowIssue::InvalidName(error) => format!(
            "잘못된 대상 이름: {} · Windows에서 사용할 수 있는 이름으로 수정하세요.",
            windows_leaf_name_error_korean(error)
        ),
        PreviewRowIssue::DuplicateDestination => {
            "대상 경로 충돌 · 이름이나 대상 위치를 수정하세요.".to_owned()
        }
        PreviewRowIssue::EmptyStem => "이름 본체가 비어 있음 · 변경 전 확인 필요".to_owned(),
        PreviewRowIssue::None if change.is_changed() => {
            preview_status_label(PreviewRowIssue::None, change).to_owned()
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
        let issue_cache = &state.preview_issue_cache;
        let icon_cache = &mut state.icon_cache;
        model
            .items()
            .iter()
            .enumerate()
            .map(|(row, item)| rendered_row(icon_cache, item, issue_cache.issue(row)))
            .collect::<Vec<_>>()
    };
    let _list_update = ProgrammaticListUpdateGuard::begin();
    // SAFETY: state.list_window is live and the guard restores redraw.
    let _redraw = unsafe { RedrawGuard::suspend(state.list_window) };
    let selected = selected_indices(state.list_window);
    let synchronized = if state.preview_synchronization.is_synchronized() {
        apply_incremental_rows(state.list_window, &state.rendered_rows, &rows)
            || rebuild_native_rows(state.list_window, &rows)
    } else {
        rebuild_native_rows(state.list_window, &rows)
    };
    if !synchronized {
        state.mark_preview_sync_failed();
        return;
    }
    state.rendered_rows = rows;
    state.mark_preview_synchronized();
    select_rows(state.list_window, &selected);
    update_primary_column_widths(state);
}

pub(super) fn refresh_changed_rows(state: &mut AppState, changed: &[usize]) {
    if state.rendered_rows.len() != state.model.len() {
        refresh(state);
        return;
    }
    refresh_preview_count_cache(state);
    let Some(status_rows) = status_delta_rows(state) else {
        refresh(state);
        return;
    };
    let mut changed = changed
        .iter()
        .copied()
        .filter(|index| *index < state.model.len())
        .collect::<Vec<_>>();
    changed.sort_unstable();
    changed.dedup();
    let rows = {
        let model = &state.model;
        let issue_cache = &state.preview_issue_cache;
        let icon_cache = &mut state.icon_cache;
        changed
            .iter()
            .map(|index| {
                (
                    *index,
                    rendered_row(
                        icon_cache,
                        &model.items()[*index],
                        issue_cache.issue(*index),
                    ),
                )
            })
            .collect::<Vec<_>>()
    };
    let _list_update = ProgrammaticListUpdateGuard::begin();
    // SAFETY: state.list_window is live and the guard restores redraw.
    let _redraw = unsafe { RedrawGuard::suspend(state.list_window) };
    for (index, row) in rows {
        if !apply_rendered_row(state.list_window, index, &state.rendered_rows[index], &row) {
            state.mark_preview_sync_failed();
            drop(_redraw);
            refresh(state);
            return;
        }
        state.rendered_rows[index] = row;
    }
    if !update_status_rows(state, &status_rows) {
        state.mark_preview_sync_failed();
        drop(_redraw);
        refresh(state);
    }
}

pub(super) fn refresh_proposal_rows(state: &mut AppState, changed: &[usize]) {
    let Some(plan) = proposal_refresh_plan(state.model.len(), state.rendered_rows.len(), changed)
    else {
        refresh(state);
        return;
    };
    let status_rows = if let [row] = plan.rows.as_ref() {
        let item = &state.model.items()[*row];
        let update = state.preview_issue_cache.refresh_one_by(
            state.model.len(),
            *row,
            (
                item.root_path(),
                item.current_name(),
                item.proposed_name(),
                item.is_directory(),
                item.planned_change_kind(),
            ),
            preview_destination_key,
        );
        let Some(update) = update else {
            refresh(state);
            return;
        };
        if !state.preview_count_cache.refresh_one(
            state.model.len(),
            update.previous_changed,
            update.current_changed,
        ) {
            refresh(state);
            return;
        }
        state
            .ui_status
            .set_preview_notice(state.preview_issue_cache.notice());
        update.affected_rows
    } else {
        refresh_preview_count_cache(state);
        let Some(status_rows) = status_delta_rows(state) else {
            refresh(state);
            return;
        };
        status_rows
    };
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
            state.mark_preview_sync_failed();
            drop(_redraw);
            refresh(state);
            return;
        }
        state.rendered_rows[row].values[1].clone_from(proposed);
    }
    if !update_status_rows(state, &status_rows) {
        state.mark_preview_sync_failed();
        drop(_redraw);
        refresh(state);
    }
}

fn status_delta_rows(state: &AppState) -> Option<Box<[usize]>> {
    preview_status_delta_rows(
        state
            .rendered_rows
            .iter()
            .map(|row| &row.values[NATIVE_STATUS_COLUMN_INDEX]),
        state.model.items().iter().enumerate().map(|(row, item)| {
            (
                state.preview_issue_cache.issue(row),
                item.planned_change_kind(),
            )
        }),
    )
}

fn update_status_rows(state: &mut AppState, rows: &[usize]) -> bool {
    for &row in rows {
        let Some(item) = state.model.items().get(row) else {
            return false;
        };
        let value = LegacyText::from(preview_status_label(
            state.preview_issue_cache.issue(row),
            item.planned_change_kind(),
        ));
        if state.rendered_rows[row].values[NATIVE_STATUS_COLUMN_INDEX] == value {
            continue;
        }
        if !set_native_subitem(state.list_window, row, NATIVE_STATUS_COLUMN_INDEX, &value) {
            return false;
        }
        state.rendered_rows[row].values[NATIVE_STATUS_COLUMN_INDEX].clone_from(&value);
    }
    true
}

fn refresh_preview_count_cache(state: &mut AppState) {
    state.preview_count_cache.refresh(
        state
            .model
            .items()
            .iter()
            .map(LegacyListItem::planned_change_kind),
    );
    state.preview_issue_cache.refresh_by(
        state.model.items().iter().map(|item| {
            (
                item.root_path(),
                item.current_name(),
                item.proposed_name(),
                item.is_directory(),
                item.planned_change_kind(),
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

fn rendered_row(
    icon_cache: &mut HashMap<IconCacheKey, i32>,
    item: &LegacyListItem,
    issue: PreviewRowIssue,
) -> RenderedRow {
    RenderedRow {
        values: [
            item.current_name().clone(),
            item.proposed_name().clone(),
            item.root_path().clone(),
            item.source_path().clone(),
            LegacyText::from(format_iec_file_size(item.actual_size())),
            format_filetime(item.modified()),
            format_filetime(item.created()),
            LegacyText::from(preview_status_label(issue, item.planned_change_kind())),
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
    for column in 1..NATIVE_LIST_COLUMN_COUNT {
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
    for column in 0..NATIVE_LIST_COLUMN_COUNT {
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
        ..LVITEMW::default()
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
    (1..NATIVE_LIST_COLUMN_COUNT)
        .all(|column| set_native_subitem(window, row, column, &value.values[column]))
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
        ..LVITEMW::default()
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
        ..LVITEMW::default()
    };
    // SAFETY: window is live; native and text outlive the synchronous message.
    unsafe {
        SendMessageW(
            window,
            LVM_SETITEMTEXTW,
            row,
            (&mut native as *mut LVITEMW) as isize,
        ) != 0
    }
}

fn rebuild_native_rows(window: HWND, rows: &[RenderedRow]) -> bool {
    // SAFETY: window is live and the message carries no pointer.
    if unsafe { SendMessageW(window, LVM_DELETEALLITEMS, 0, 0) } == 0 {
        return false;
    }
    rows.iter()
        .enumerate()
        .all(|(row, value)| insert_native_row(window, row, value))
}

fn file_icon_index(cache: &mut HashMap<IconCacheKey, i32>, item: &LegacyListItem) -> i32 {
    let key = icon_cache_key(item.current_name(), item.is_directory());
    if let Some(index) = cache.get(&key) {
        return *index;
    }
    let mut info = SHFILEINFOW::default();
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
    let mut utc = SYSTEMTIME::default();
    // SAFETY: filetime is readable UTC input and utc remains writable through
    // this synchronous representation conversion.
    if unsafe { FileTimeToSystemTime(&filetime, &mut utc) } == 0 {
        return None;
    }
    let mut local = SYSTEMTIME::default();
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
    use std::process::Command;

    use super::*;

    #[test]
    fn native_default_columns_leave_no_horizontal_scroll_range() -> io::Result<()> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_LISTVIEW_CLASSES,
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
                800,
                600,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the initialized report ListView class retains no caller-owned
        // creation data and parent remains live until the test completes.
        let list = unsafe {
            CreateWindowExW(
                0,
                wide("SysListView32").as_ptr(),
                null(),
                WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_SHOWSELALWAYS | LVS_NOSORTHEADER,
                0,
                0,
                640,
                480,
                parent,
                LIST_ID as *mut c_void,
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if list.is_null() {
            // SAFETY: parent is the test-owned hidden HWND.
            unsafe { DestroyWindow(parent) };
            return Err(io::Error::last_os_error());
        }
        let result = (|| -> io::Result<()> {
            // SAFETY: list is live and the query returns one scalar DPI value.
            let dpi = unsafe { GetDpiForWindow(list) }.max(BASE_DPI);
            for (index, label) in COLUMNS
                .iter()
                .map(|column| column.label)
                .chain(core::iter::once(NATIVE_STATUS_COLUMN.label))
                .enumerate()
            {
                let mut label = wide(label);
                let mut column = LVCOLUMNW {
                    mask: LVCF_TEXT | LVCF_WIDTH | LVCF_FMT,
                    fmt: LVCFMT_LEFT,
                    cx: 0,
                    pszText: label.as_mut_ptr(),
                    ..LVCOLUMNW::default()
                };
                // SAFETY: list is live and column/label outlive this synchronous message.
                if unsafe {
                    SendMessageW(
                        list,
                        LVM_INSERTCOLUMNW,
                        index,
                        (&mut column as *mut LVCOLUMNW) as isize,
                    )
                } < 0
                {
                    return Err(io::Error::other("could not insert native test column"));
                }
            }
            let mut message_font = OwnedFont::default();
            message_font.replace(create_message_font(dpi));
            if message_font.as_raw().is_null() {
                return Err(io::Error::other("could not create native test font"));
            }
            let status_width =
                native_status_column_minimum_px_for(list, message_font.as_raw(), dpi);
            assert!(status_width > scale_dip(NATIVE_STATUS_COLUMN_WIDTH_DIP, dpi));
            let baseline_rails = RailDensity::Comfortable
                .metrics(dpi)
                .rail_width
                .saturating_mul(2);
            let client_width =
                minimum_content_width_px(dpi, status_width).saturating_sub(baseline_rails);
            // SAFETY: list is a live child and the test changes only its size.
            unsafe {
                SetWindowPos(
                    list,
                    null_mut(),
                    0,
                    0,
                    client_width,
                    scale_dip(240, dpi),
                    SWP_NOZORDER | SWP_NOACTIVATE,
                )
            };
            assert!(native_list_header_height_px(list) > 0);
            let widths = allocate_primary_column_widths(
                client_width,
                status_width,
                dpi,
                &default_column_states(),
            );
            for (column, width) in widths.into_iter().enumerate() {
                // SAFETY: list is live and the column indices were inserted above.
                unsafe { SendMessageW(list, LVM_SETCOLUMNWIDTH, column, width as isize) };
            }
            for column in 3..NATIVE_STATUS_COLUMN_INDEX {
                // SAFETY: list is live and the optional column indices were inserted above.
                unsafe { SendMessageW(list, LVM_SETCOLUMNWIDTH, column, 0) };
            }
            set_native_status_column_width_for(list, status_width);

            let mut scroll = SCROLLINFO {
                cbSize: u32::try_from(size_of::<SCROLLINFO>())
                    .map_err(|_| io::Error::other("invalid scroll info size"))?,
                fMask: SIF_RANGE | SIF_PAGE,
                ..SCROLLINFO::default()
            };
            // SAFETY: list is live and scroll has its exact ABI size and remains writable.
            if unsafe { GetScrollInfo(list, SB_HORZ, &mut scroll) } == 0 {
                return Err(io::Error::last_os_error());
            }
            let range = scroll.nMax.saturating_sub(scroll.nMin).saturating_add(1);
            assert!(range <= i32::try_from(scroll.nPage).unwrap_or(i32::MAX));
            Ok(())
        })();
        // SAFETY: the child and parent are test-owned live windows.
        unsafe {
            DestroyWindow(list);
            DestroyWindow(parent);
        }
        result
    }

    #[test]
    fn header_notification_type_is_narrowed_before_extended_fields_are_read()
    -> Result<(), Box<dyn std::error::Error>> {
        const CHILD_MODE: &str = "DARKRENAMER_TEST_NMHDR_BOUNDARY_CHILD";
        if env::var_os(CHILD_MODE).is_some() {
            let mut system_info = SYSTEM_INFO::default();
            // SAFETY: this source-bound child probe owns both virtual-memory
            // pages. NMHDR ends at the first committed page boundary and the
            // next page is made inaccessible, so the production parser can
            // prove that NM_SETFOCUS never reaches NMHEADERW::iItem. All memory
            // is released before the child emits its success sentinel.
            unsafe {
                GetSystemInfo(&mut system_info);
                let page_size = usize::try_from(system_info.dwPageSize)?;
                let allocation_size = page_size
                    .checked_mul(2)
                    .ok_or_else(|| io::Error::other("test allocation size overflow"))?;
                let allocation = VirtualAlloc(
                    null(),
                    allocation_size,
                    MEM_RESERVE | MEM_COMMIT,
                    PAGE_READWRITE,
                );
                if allocation.is_null() {
                    return Err(io::Error::last_os_error().into());
                }
                let inaccessible = allocation.cast::<u8>().add(page_size);
                let mut old_protection = 0;
                if VirtualProtect(
                    inaccessible.cast(),
                    page_size,
                    PAGE_NOACCESS,
                    &mut old_protection,
                ) == 0
                {
                    let error = io::Error::last_os_error();
                    VirtualFree(allocation, 0, MEM_RELEASE);
                    return Err(error.into());
                }
                let payload = inaccessible.sub(size_of::<NMHDR>()).cast::<NMHDR>();
                payload.write(NMHDR {
                    hwndFrom: 2_usize as HWND,
                    idFrom: 0,
                    code: NM_SETFOCUS,
                });
                let rejected =
                    header_column_notification(1_usize as HWND, 2_usize as HWND, payload as LPARAM)
                        .is_none();
                if VirtualFree(allocation, 0, MEM_RELEASE) == 0 {
                    return Err(io::Error::last_os_error().into());
                }
                if rejected {
                    std::process::exit(86);
                }
                return Err(io::Error::other("NMHDR-only notification was accepted").into());
            }
        }

        let status = Command::new(std::env::current_exe()?)
            .arg("--exact")
            .arg("windows::list_view::native_tests::header_notification_type_is_narrowed_before_extended_fields_are_read")
            .arg("--nocapture")
            .arg("--test-threads=1")
            .env(CHILD_MODE, "1")
            .status()?;
        assert_eq!(status.code(), Some(86));

        let header_window = 1_usize as HWND;
        let list_window = 2_usize as HWND;
        let mut focus = NMHDR {
            hwndFrom: list_window,
            idFrom: 0,
            code: NM_SETFOCUS,
        };

        assert_eq!(
            header_column_notification(header_window, list_window, (&raw mut focus) as LPARAM,),
            None,
        );

        let mut end_track = NMHEADERW {
            hdr: NMHDR {
                hwndFrom: header_window,
                idFrom: 0,
                code: HDN_ENDTRACKW,
            },
            iItem: 3,
            ..NMHEADERW::default()
        };
        assert_eq!(
            header_column_notification(header_window, list_window, (&raw mut end_track) as LPARAM,),
            Some(HeaderColumnNotification::EndTrack(Some(3))),
        );
        let mut double_click = NMHEADERW {
            hdr: NMHDR {
                hwndFrom: list_window,
                idFrom: 0,
                code: HDN_DIVIDERDBLCLICKW,
            },
            iItem: NATIVE_STATUS_COLUMN_INDEX as i32,
            ..NMHEADERW::default()
        };
        assert_eq!(
            header_column_notification(
                header_window,
                list_window,
                (&raw mut double_click) as LPARAM,
            ),
            Some(HeaderColumnNotification::DividerDoubleClick(Some(
                NATIVE_STATUS_COLUMN_INDEX,
            ))),
        );
        Ok(())
    }

    #[test]
    fn native_selected_row_exposes_status_through_listview_text_api() -> io::Result<()> {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_LISTVIEW_CLASSES,
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
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the initialized report ListView class retains no caller-owned
        // creation data and parent remains live until the test completes.
        let list = unsafe {
            CreateWindowExW(
                0,
                wide("SysListView32").as_ptr(),
                null(),
                WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_SHOWSELALWAYS,
                0,
                0,
                640,
                480,
                parent,
                LIST_ID as *mut c_void,
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if list.is_null() {
            // SAFETY: parent is the test-owned hidden HWND.
            unsafe { DestroyWindow(parent) };
            return Err(io::Error::last_os_error());
        }
        let result = (|| -> io::Result<()> {
            for (index, label) in COLUMNS
                .iter()
                .map(|column| column.label)
                .chain(core::iter::once(NATIVE_STATUS_COLUMN.label))
                .enumerate()
            {
                let mut label = wide(label);
                let mut column = LVCOLUMNW {
                    mask: LVCF_TEXT | LVCF_WIDTH | LVCF_FMT,
                    fmt: LVCFMT_LEFT,
                    cx: 112,
                    pszText: label.as_mut_ptr(),
                    ..LVCOLUMNW::default()
                };
                // SAFETY: list is live and column/label outlive this synchronous message.
                if unsafe {
                    SendMessageW(
                        list,
                        LVM_INSERTCOLUMNW,
                        index,
                        (&mut column as *mut LVCOLUMNW) as isize,
                    )
                } < 0
                {
                    return Err(io::Error::other("could not insert native test column"));
                }
            }
            // SAFETY: list is live and the message carries only integral width data.
            unsafe { SendMessageW(list, LVM_SETCOLUMNWIDTH, NATIVE_STATUS_COLUMN_INDEX, 400) };
            // SAFETY: list is live and returns its borrowed Header child HWND.
            let header = unsafe { SendMessageW(list, LVM_GETHEADER, 0, 0) } as HWND;
            let mut double_click = NMHEADERW {
                hdr: NMHDR {
                    hwndFrom: header,
                    idFrom: 0,
                    code: HDN_DIVIDERDBLCLICKW,
                },
                iItem: NATIVE_STATUS_COLUMN_INDEX as i32,
                ..NMHEADERW::default()
            };
            assert_eq!(
                handle_status_header_double_click(
                    list,
                    header,
                    null_mut(),
                    192,
                    (&raw mut double_click) as LPARAM,
                ),
                Some(1)
            );
            // SAFETY: list is live and the message returns one integral width.
            let restored_width =
                unsafe { SendMessageW(list, LVM_GETCOLUMNWIDTH, NATIVE_STATUS_COLUMN_INDEX, 0) };
            assert_eq!(
                restored_width,
                scale_dip(NATIVE_STATUS_COLUMN_WIDTH_DIP, 192) as isize
            );
            let row = RenderedRow {
                values: core::array::from_fn(|column| {
                    if column == NATIVE_STATUS_COLUMN_INDEX {
                        LegacyText::from("차단: 충돌")
                    } else {
                        LegacyText::from(format!("value-{column}"))
                    }
                }),
                icon: 0,
            };
            if !rebuild_native_rows(list, &[]) {
                return Err(io::Error::other("could not rebuild an empty native list"));
            }

            assert!(!set_native_subitem(null_mut(), 0, 1, &row.values[1]));
            assert!(!rebuild_native_rows(
                null_mut(),
                core::slice::from_ref(&row)
            ));
            if !rebuild_native_rows(list, core::slice::from_ref(&row)) {
                return Err(io::Error::other("could not rebuild native test rows"));
            }
            let mut selected = LVITEMW {
                stateMask: LVIS_SELECTED | LVIS_FOCUSED,
                state: LVIS_SELECTED | LVIS_FOCUSED,
                ..LVITEMW::default()
            };
            // SAFETY: list and selected remain live for this synchronous state update.
            if unsafe {
                SendMessageW(
                    list,
                    LVM_SETITEMSTATE,
                    0,
                    (&mut selected as *mut LVITEMW) as isize,
                )
            } == 0
            {
                return Err(io::Error::other("could not select native test row"));
            }
            let mut buffer = [0_u16; 64];
            let mut query = LVITEMW {
                iSubItem: NATIVE_STATUS_COLUMN_INDEX as i32,
                pszText: buffer.as_mut_ptr(),
                cchTextMax: i32::try_from(buffer.len()).unwrap_or(i32::MAX),
                ..LVITEMW::default()
            };
            // SAFETY: list is live and query/buffer are writable for this
            // synchronous native text retrieval.
            let copied = unsafe {
                SendMessageW(
                    list,
                    LVM_GETITEMTEXTW,
                    0,
                    (&mut query as *mut LVITEMW) as isize,
                )
            };
            let copied = usize::try_from(copied).unwrap_or_default();
            assert_eq!(String::from_utf16_lossy(&buffer[..copied]), "차단: 충돌");
            assert_eq!(selected_indices(list), vec![0]);
            Ok(())
        })();
        // SAFETY: parent owns and destroys the native ListView child exactly once.
        unsafe { DestroyWindow(parent) };
        result
    }

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
    #[ignore = "manual Windows release-mode measurement with the production path key"]
    fn measure_preview_validation_with_production_windows_path_keys() {
        let parent = LegacyText::from(r"C:\work");
        for count in [100_usize, 1_000, 10_000] {
            let names = (0..count)
                .map(|row| {
                    let name = LegacyText::from(format!("항목-{row:05}-İ-ß.txt"));
                    (name.clone(), name)
                })
                .collect::<Vec<_>>();
            let mut cache = PreviewIssueCache::default();
            let started = std::time::Instant::now();

            cache.refresh_by(
                names
                    .iter()
                    .map(|(current, proposed)| (&parent, current, proposed, false)),
                preview_destination_key,
            );

            println!(
                "darkrenamer_preview_path_key,count={count},validation_us={}",
                started.elapsed().as_micros(),
            );
            assert_eq!(cache.issue(count - 1), PreviewRowIssue::None);
            assert!(cache.blocker_rows().is_empty());
        }
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
