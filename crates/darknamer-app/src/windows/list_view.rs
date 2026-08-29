use super::*;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RenderedRow {
    pub(super) values: [LegacyText; 7],
    pub(super) icon: i32,
}

pub(super) fn update_column_visibility(state: &AppState, index: usize) {
    let column = index + 3;
    let width = if state.shown_columns[index] {
        scale_dip(if column == 4 { 80 } else { 120 }, state.dpi)
    } else {
        0
    };
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

pub(super) fn update_dpi_metrics(state: &AppState) {
    for (column, spec) in COLUMNS.iter().enumerate().take(3) {
        // SAFETY: list_window is live and width is a scaled integer value.
        unsafe {
            SendMessageW(
                state.list_window,
                LVM_SETCOLUMNWIDTH,
                column,
                scale_dip(spec.default_width, state.dpi) as isize,
            )
        };
    }
    for index in 0..state.shown_columns.len() {
        update_column_visibility(state, index);
    }
    let button = packed_dimensions(
        scale_dip(toolbar_width_dip(state.high_contrast), state.dpi),
        scale_dip(TOOLBAR_BUTTON_HEIGHT, state.dpi),
    );
    let bitmap = packed_dimensions(
        scale_dip(TOOLBAR_BITMAP_WIDTH, state.dpi),
        scale_dip(TOOLBAR_BITMAP_HEIGHT, state.dpi),
    );
    // SAFETY: both toolbar HWNDs are live and the packed sizes have no pointers.
    unsafe {
        SendMessageW(state.left_toolbar, TB_SETBUTTONSIZE, 0, button);
        SendMessageW(state.right_toolbar, TB_SETBUTTONSIZE, 0, button);
        SendMessageW(state.left_toolbar, TB_SETBITMAPSIZE, 0, bitmap);
        SendMessageW(state.right_toolbar, TB_SETBITMAPSIZE, 0, bitmap);
    }
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
    let rows = {
        let model = &state.model;
        let icon_cache = &mut state.icon_cache;
        model
            .items()
            .iter()
            .map(|item| rendered_row(icon_cache, item))
            .collect::<Vec<_>>()
    };
    // SAFETY: state.list_window is live and the guard restores redraw.
    let _redraw = unsafe { RedrawGuard::suspend(state.list_window) };
    let selected = selected_indices(state.list_window);
    if !apply_incremental_rows(state.list_window, &state.rendered_rows, &rows) {
        rebuild_native_rows(state.list_window, &rows);
    }
    state.rendered_rows = rows;
    select_rows(state.list_window, &selected);
    update_controls(state);
    let status = if state.model.is_empty() {
        LegacyText::default()
    } else {
        LegacyText::from(format!("{} 개", state.model.len()))
    };
    let mut status = status.units().to_vec();
    status.push(0);
    // SAFETY: status is live and the terminated text outlives this call.
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::SetWindowTextW(state.status, status.as_ptr());
    }
}

fn rendered_row(icon_cache: &mut HashMap<IconCacheKey, i32>, item: &LegacyListItem) -> RenderedRow {
    RenderedRow {
        values: [
            item.current_name().clone(),
            item.proposed_name().clone(),
            item.root_path().clone(),
            item.source_path().clone(),
            LegacyText::from(item.actual_size().to_string()),
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
        let mask = changed_column_mask(&old[row], &new[row]);
        if mask & 1 != 0 && !set_native_primary(window, row, &new[row]) {
            return false;
        }
        for column in 1..7 {
            if mask & (1 << column) != 0
                && !set_native_subitem(window, row, column, &new[row].values[column])
            {
                return false;
            }
        }
    }
    for (row, value) in new.iter().enumerate().skip(old.len()) {
        if !insert_native_row(window, row, value) {
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
    if value == 0 {
        return LegacyText::default();
    }
    let filetime = FILETIME {
        dwLowDateTime: value as u32,
        dwHighDateTime: (value >> 32) as u32,
    };
    // SAFETY: SYSTEMTIME is valid zero-initialized output storage.
    let mut system: SYSTEMTIME = unsafe { zeroed() };
    // SAFETY: both structures remain valid through the synchronous conversion.
    if unsafe { FileTimeToSystemTime(&filetime, &mut system) } == 0 {
        return LegacyText::default();
    }
    LegacyText::from(format!(
        "{}-{:02}-{:02} {:02}:{:02}:{:02}",
        system.wYear, system.wMonth, system.wDay, system.wHour, system.wMinute, system.wSecond
    ))
}
