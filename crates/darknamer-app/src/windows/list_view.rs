#[cfg(test)]
use crate::ApplyPresentation;
#[cfg(test)]
use crate::BASE_DPI;
#[cfg(test)]
use crate::COLUMNS;
#[cfg(test)]
use crate::GRAPHITE_DARK;
use crate::LayoutRect;
use crate::NATIVE_LIST_COLUMN_COUNT;
use crate::NATIVE_STATUS_COLUMN;
use crate::NATIVE_STATUS_COLUMN_INDEX;
use crate::NATIVE_STATUS_COLUMN_WIDTH_DIP;
#[cfg(test)]
use crate::PreviewIssueCache;
use crate::PreviewRowIssue;
use crate::ProposedNameVisualContext;
#[cfg(test)]
use crate::RailDensity;
use crate::ResolvedTheme;
use crate::SemanticPalette;
use crate::allocate_primary_column_widths;
use crate::calculate_blank_list_body_rect;
use crate::calculate_header_chrome;
use crate::calculate_scrollbar_parts;
#[cfg(test)]
use crate::default_column_states;
use crate::format_exact_bytes;
use crate::format_iec_file_size;
use crate::format_timestamp_fallback;
#[cfg(test)]
use ::windows::Win32::System::Com::CoInitializeEx;
#[cfg(test)]
use ::windows::Win32::System::Com::CoUninitialize;

use crate::icon_cache::IconCacheKey;
use crate::icon_cache::cache_icon_index;
use crate::icon_cache::icon_cache_key;
#[cfg(test)]
use crate::minimum_content_width_px;
#[cfg(test)]
use crate::preferences::PreferencesWriter;
#[cfg(test)]
use crate::preferences::lifecycle::PreferencePersistence;
use crate::preview_item_details;
use crate::preview_status_delta_rows;
use crate::preview_status_label;
use crate::proposal_refresh_plan;
use crate::proposed_name_colors;
use crate::proposed_name_visual_decision;

use crate::rename::RenameBackend;
use crate::rename::WindowsRenameBackend;
use crate::scale_dip;
use crate::semantic_palette;
use crate::status_column_width_after_resize;
#[cfg(test)]
use darknamer_core::LegacyList;
use darknamer_core::LegacyListItem;
#[cfg(test)]
use darknamer_core::LegacySortMode;
use darknamer_core::LegacyText;
#[cfg(test)]
use std::cell::Cell;
#[cfg(test)]
use std::cell::RefCell;
use std::collections::HashMap;
#[cfg(test)]
use std::env;
#[cfg(test)]
use std::ffi::c_void;
#[cfg(test)]
use std::fs;
use std::io;
use std::mem::size_of;
#[cfg(test)]
use std::panic::AssertUnwindSafe;
#[cfg(test)]
use std::panic::catch_unwind;
#[cfg(test)]
use std::path::Path;
use std::ptr::null;
use std::ptr::null_mut;
use std::sync::Arc;
#[cfg(test)]
use std::sync::Mutex;
#[cfg(test)]
use std::sync::atomic::AtomicBool;
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
#[cfg(test)]
use std::sync::atomic::Ordering;
#[cfg(test)]
use std::thread;
use windows_sys::Win32::Foundation::FILETIME;
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Foundation::LPARAM;
use windows_sys::Win32::Foundation::LRESULT;
use windows_sys::Win32::Foundation::RECT;
use windows_sys::Win32::Foundation::SYSTEMTIME;
use windows_sys::Win32::Foundation::WPARAM;
use windows_sys::Win32::Globalization::DATE_SHORTDATE;
use windows_sys::Win32::Globalization::GetDateFormatEx;
use windows_sys::Win32::Globalization::GetTimeFormatEx;
use windows_sys::Win32::Graphics::Gdi::DT_END_ELLIPSIS;
use windows_sys::Win32::Graphics::Gdi::DT_LEFT;
use windows_sys::Win32::Graphics::Gdi::DT_NOPREFIX;
use windows_sys::Win32::Graphics::Gdi::DT_RIGHT;
use windows_sys::Win32::Graphics::Gdi::DT_SINGLELINE;
use windows_sys::Win32::Graphics::Gdi::DT_VCENTER;
use windows_sys::Win32::Graphics::Gdi::DrawTextW;
use windows_sys::Win32::Graphics::Gdi::FillRect;
use windows_sys::Win32::Graphics::Gdi::HBRUSH;
use windows_sys::Win32::Graphics::Gdi::HDC;
use windows_sys::Win32::Graphics::Gdi::HFONT;
use windows_sys::Win32::Graphics::Gdi::RDW_ALLCHILDREN;
use windows_sys::Win32::Graphics::Gdi::RDW_ERASE;
use windows_sys::Win32::Graphics::Gdi::RDW_INVALIDATE;
use windows_sys::Win32::Graphics::Gdi::RedrawWindow;
use windows_sys::Win32::Graphics::Gdi::ReleaseDC;
use windows_sys::Win32::Graphics::Gdi::SelectObject;
use windows_sys::Win32::Graphics::Gdi::SetBkMode;
use windows_sys::Win32::Graphics::Gdi::SetTextColor;
use windows_sys::Win32::Graphics::Gdi::TRANSPARENT;
#[cfg(test)]
use windows_sys::Win32::Graphics::Gdi::UpdateWindow;
#[cfg(test)]
use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_DIRECTORY;
#[cfg(test)]
use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_NORMAL;
#[cfg(test)]
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
#[cfg(test)]
use windows_sys::Win32::System::Memory::MEM_COMMIT;
#[cfg(test)]
use windows_sys::Win32::System::Memory::MEM_RELEASE;
#[cfg(test)]
use windows_sys::Win32::System::Memory::MEM_RESERVE;
#[cfg(test)]
use windows_sys::Win32::System::Memory::PAGE_NOACCESS;
#[cfg(test)]
use windows_sys::Win32::System::Memory::PAGE_READWRITE;
#[cfg(test)]
use windows_sys::Win32::System::Memory::VirtualAlloc;
#[cfg(test)]
use windows_sys::Win32::System::Memory::VirtualFree;
#[cfg(test)]
use windows_sys::Win32::System::Memory::VirtualProtect;
#[cfg(test)]
use windows_sys::Win32::System::Ole::OleInitialize;
#[cfg(test)]
use windows_sys::Win32::System::Ole::OleUninitialize;
#[cfg(test)]
use windows_sys::Win32::System::SystemInformation::GetSystemInfo;
#[cfg(test)]
use windows_sys::Win32::System::SystemInformation::SYSTEM_INFO;
use windows_sys::Win32::System::Time::FileTimeToSystemTime;
use windows_sys::Win32::System::Time::SystemTimeToTzSpecificLocalTimeEx;
use windows_sys::Win32::UI::Controls::CDDS_ITEMPREPAINT;
use windows_sys::Win32::UI::Controls::CDDS_POSTPAINT;
use windows_sys::Win32::UI::Controls::CDDS_PREPAINT;
use windows_sys::Win32::UI::Controls::CDDS_SUBITEM;
use windows_sys::Win32::UI::Controls::CDIS_HOT;
use windows_sys::Win32::UI::Controls::CDIS_SELECTED;
use windows_sys::Win32::UI::Controls::CDRF_DODEFAULT;
use windows_sys::Win32::UI::Controls::CDRF_NEWFONT;
use windows_sys::Win32::UI::Controls::CDRF_NOTIFYITEMDRAW;
use windows_sys::Win32::UI::Controls::CDRF_NOTIFYPOSTPAINT;
use windows_sys::Win32::UI::Controls::CDRF_NOTIFYSUBITEMDRAW;
use windows_sys::Win32::UI::Controls::CDRF_SKIPDEFAULT;
use windows_sys::Win32::UI::Controls::HDI_TEXT;
use windows_sys::Win32::UI::Controls::HDI_WIDTH;
use windows_sys::Win32::UI::Controls::HDITEMW;
use windows_sys::Win32::UI::Controls::HDM_GETITEMCOUNT;
use windows_sys::Win32::UI::Controls::HDM_GETITEMRECT;
use windows_sys::Win32::UI::Controls::HDM_GETITEMW;
use windows_sys::Win32::UI::Controls::HDN_DIVIDERDBLCLICKW;
use windows_sys::Win32::UI::Controls::HDN_ENDTRACKW;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::ICC_LISTVIEW_CLASSES;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::ICC_WIN95_CLASSES;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::INITCOMMONCONTROLSEX;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::InitCommonControlsEx;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVCF_FMT;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVCF_TEXT;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVCF_WIDTH;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVCFMT_LEFT;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVCOLUMNW;
use windows_sys::Win32::UI::Controls::LVIF_IMAGE;
use windows_sys::Win32::UI::Controls::LVIF_TEXT;
use windows_sys::Win32::UI::Controls::LVIR_BOUNDS;
use windows_sys::Win32::UI::Controls::LVIS_FOCUSED;
use windows_sys::Win32::UI::Controls::LVIS_SELECTED;
use windows_sys::Win32::UI::Controls::LVITEMW;
use windows_sys::Win32::UI::Controls::LVM_DELETEALLITEMS;
use windows_sys::Win32::UI::Controls::LVM_DELETEITEM;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVM_ENSUREVISIBLE;
use windows_sys::Win32::UI::Controls::LVM_GETCOLUMNWIDTH;
use windows_sys::Win32::UI::Controls::LVM_GETHEADER;
use windows_sys::Win32::UI::Controls::LVM_GETITEMCOUNT;
use windows_sys::Win32::UI::Controls::LVM_GETITEMRECT;
use windows_sys::Win32::UI::Controls::LVM_GETITEMSTATE;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVM_GETITEMTEXTW;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVM_GETTOOLTIPS;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVM_INSERTCOLUMNW;
use windows_sys::Win32::UI::Controls::LVM_INSERTITEMW;
use windows_sys::Win32::UI::Controls::LVM_SETCOLUMNWIDTH;
use windows_sys::Win32::UI::Controls::LVM_SETEXTENDEDLISTVIEWSTYLE;
use windows_sys::Win32::UI::Controls::LVM_SETIMAGELIST;
use windows_sys::Win32::UI::Controls::LVM_SETITEMSTATE;
use windows_sys::Win32::UI::Controls::LVM_SETITEMTEXTW;
use windows_sys::Win32::UI::Controls::LVM_SETITEMW;
use windows_sys::Win32::UI::Controls::LVN_GETINFOTIPW;
use windows_sys::Win32::UI::Controls::LVS_EX_DOUBLEBUFFER;
use windows_sys::Win32::UI::Controls::LVS_EX_FULLROWSELECT;
use windows_sys::Win32::UI::Controls::LVS_EX_INFOTIP;
use windows_sys::Win32::UI::Controls::LVS_EX_LABELTIP;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVS_NOSORTHEADER;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVS_REPORT;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::LVS_SHOWSELALWAYS;
use windows_sys::Win32::UI::Controls::LVSIL_SMALL;
use windows_sys::Win32::UI::Controls::NM_CUSTOMDRAW;
#[cfg(test)]
use windows_sys::Win32::UI::Controls::NM_SETFOCUS;
use windows_sys::Win32::UI::Controls::NMCUSTOMDRAW;
use windows_sys::Win32::UI::Controls::NMHDR;
use windows_sys::Win32::UI::Controls::NMHEADERW;
use windows_sys::Win32::UI::Controls::NMLVCUSTOMDRAW;
use windows_sys::Win32::UI::Controls::NMLVGETINFOTIPW;
#[cfg(test)]
use windows_sys::Win32::UI::HiDpi::GetDpiForWindow;
use windows_sys::Win32::UI::Shell::DefSubclassProc;
use windows_sys::Win32::UI::Shell::RemoveWindowSubclass;
#[cfg(test)]
use windows_sys::Win32::UI::Shell::SHFILEINFOW;
#[cfg(test)]
use windows_sys::Win32::UI::Shell::SHGFI_SMALLICON;
#[cfg(test)]
use windows_sys::Win32::UI::Shell::SHGFI_SYSICONINDEX;
#[cfg(test)]
use windows_sys::Win32::UI::Shell::SHGFI_USEFILEATTRIBUTES;
#[cfg(test)]
use windows_sys::Win32::UI::Shell::SHGetFileInfoW;
use windows_sys::Win32::UI::Shell::SetWindowSubclass;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::CreateWindowExW;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::DestroyWindow;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::DispatchMessageW;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::GWLP_USERDATA;
use windows_sys::Win32::UI::WindowsAndMessaging::GetClientRect;
use windows_sys::Win32::UI::WindowsAndMessaging::GetParent;
use windows_sys::Win32::UI::WindowsAndMessaging::GetWindowRect;
use windows_sys::Win32::UI::WindowsAndMessaging::IsWindow;
use windows_sys::Win32::UI::WindowsAndMessaging::KillTimer;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::MSG;
use windows_sys::Win32::UI::WindowsAndMessaging::PostMessageW;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::SIF_PAGE;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::SIF_RANGE;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::SWP_NOACTIVATE;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::SWP_NOZORDER;
use windows_sys::Win32::UI::WindowsAndMessaging::SendMessageW;
use windows_sys::Win32::UI::WindowsAndMessaging::SetTimer;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::SetWindowLongPtrW;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::SetWindowPos;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::TranslateMessage;

#[cfg(test)]
use super::initialize_safe_runtime_at;
use super::{
    AppState, ICON_POLL_TIMER_ID, IconShared, ProgrammaticListUpdateGuard, WM_APP_ICON_CONTINUE,
    focused_index, icon_worker, measure_text, programmatic_list_update_active, selected_indices,
    try_app_state, update_controls,
};
#[cfg(test)]
use super::{
    AppStateSlot, AppearanceResources, CallbackReclaimHold, CallbackState, LIST_ID,
    NativeThemeTarget, OwnedFont, ReclaimDisposition, WM_APP_ICON_WAKE, WinRtGuard,
    app_callback_is_busy, app_state_slot, application, apply_native_control_theme, compare_windows,
    create_children, create_message_font, discard_deferred_messages, select_rows,
    select_rows_with_focus, wide, worker,
};
use crate::preview::{PREVIEW_STATUS_LABELS, PreviewRowInput};
use windows_sys::Win32::Foundation::POINT;
use windows_sys::Win32::Graphics::Gdi::{
    ClientToScreen, DC_BRUSH, ExcludeClipRect, GetStockObject, GetWindowDC, NULL_PEN, Polygon,
    RestoreDC, SaveDC, SetDCBrushColor,
};
#[cfg(test)]
use windows_sys::Win32::System::Time::DYNAMIC_TIME_ZONE_INFORMATION;
use windows_sys::Win32::UI::Controls::{
    I_IMAGENONE, LVM_GETTOPINDEX, LVM_SCROLL, STATE_SYSTEM_INVISIBLE, STATE_SYSTEM_OFFSCREEN,
    STATE_SYSTEM_PRESSED,
};
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::WM_CLOSE;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::WM_DESTROY;
use windows_sys::Win32::UI::WindowsAndMessaging::WM_NCDESTROY;
use windows_sys::Win32::UI::WindowsAndMessaging::WM_NCPAINT;
use windows_sys::Win32::UI::WindowsAndMessaging::WM_NOTIFY;
use windows_sys::Win32::UI::WindowsAndMessaging::WM_SETREDRAW;
use windows_sys::Win32::UI::WindowsAndMessaging::WM_SIZE;
use windows_sys::Win32::UI::WindowsAndMessaging::WM_THEMECHANGED;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::WS_CHILD;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::WS_OVERLAPPEDWINDOW;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::WS_VISIBLE;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetScrollBarInfo, GetScrollInfo, OBJID_HSCROLL, OBJID_VSCROLL, SB_HORZ,
    SCROLLBARINFO, SCROLLINFO, SIF_POS, WM_HSCROLL, WM_MOUSEMOVE, WM_NCLBUTTONDOWN, WM_NCLBUTTONUP,
    WM_NCMOUSELEAVE, WM_NCMOUSEMOVE, WM_PAINT, WM_VSCROLL,
};

const LIST_VIEW_NOTIFICATION_SUBCLASS_ID: usize = 1;
const STATUS_COLUMN_TEXT_PADDING_DIP: i32 = 24;
pub(super) const LIST_VIEW_EXTENDED_STYLES: u32 =
    LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_LABELTIP | LVS_EX_INFOTIP;

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
    let result = unsafe { DefSubclassProc(window, message, wparam, lparam) };
    if owner_ref != 0
        && matches!(
            message,
            WM_NCPAINT
                | WM_PAINT
                | WM_HSCROLL
                | WM_VSCROLL
                | WM_SIZE
                | WM_NCMOUSEMOVE
                | WM_NCMOUSELEAVE
                | WM_NCLBUTTONDOWN
                | WM_NCLBUTTONUP
                | WM_MOUSEMOVE
                | WM_THEMECHANGED
        )
    {
        // Resolve after default processing, without retaining a lease across the
        // native scroll tracking loop. A failed/reentrant lease keeps native paint.
        let palette = try_app_state(owner_ref as HWND).and_then(|lease| {
            let state = lease.state();
            let resolved = state.resolved_appearance();
            (state.list_window == window
                && resolved.theme == ResolvedTheme::Dark
                && resolved.custom_colors_enabled)
                .then(|| semantic_palette(resolved.theme))
                .flatten()
        });
        if let Some(palette) = palette {
            paint_native_list_scrollbars(window, palette);
        }
    }
    result
}

/// A synchronous window DC; never retained by the subclass or native control.
struct ListWindowDc {
    window: HWND,
    dc: HDC,
    saved: i32,
}
impl Drop for ListWindowDc {
    fn drop(&mut self) {
        // SAFETY: these values belong to this successful GetWindowDC/SaveDC pair.
        unsafe {
            RestoreDC(self.dc, self.saved);
            ReleaseDC(self.window, self.dc);
        }
    }
}

fn paint_native_list_scrollbars(window: HWND, palette: SemanticPalette) {
    let mut bounds = RECT::default();
    let mut client = RECT::default();
    let mut origin = POINT::default();
    let mut cursor = POINT::default();
    // SAFETY: synchronous value-only queries on the current UI-thread ListView.
    let geometry_known = unsafe {
        IsWindow(window) != 0
            && GetWindowRect(window, &mut bounds) != 0
            && GetClientRect(window, &mut client) != 0
            && ClientToScreen(window, &mut origin) != 0
    };
    if !geometry_known {
        return;
    }
    // SAFETY: writable local POINT storage, no retained pointer.
    let cursor_known = unsafe { GetCursorPos(&mut cursor) } != 0;
    // SAFETY: the live ListView owns this window DC until ReleaseDC below.
    let dc = unsafe { GetWindowDC(window) };
    if dc.is_null() {
        return;
    }
    // SAFETY: SaveDC copies this newly acquired DC's state.
    let saved = unsafe { SaveDC(dc) };
    if saved == 0 {
        // SAFETY: release the exact acquired DC even when saving fails.
        unsafe { ReleaseDC(window, dc) };
        return;
    }
    let _dc = ListWindowDc { window, dc, saved };
    let dx = bounds.left;
    let dy = bounds.top;
    // Exclude every client pixel, including rows and the header. All remaining
    // fills also use native scrollbar rectangles, never the whole window frame.
    // SAFETY: local coordinates of the same live window DC; guard restores state.
    if unsafe {
        ExcludeClipRect(
            dc,
            origin.x - dx,
            origin.y - dy,
            origin.x - dx + client.right,
            origin.y - dy + client.bottom,
        )
    } == 0
    {
        return;
    }
    // SAFETY: stock objects are process-owned; SaveDC restores prior selections.
    unsafe {
        SelectObject(dc, GetStockObject(DC_BRUSH));
        SelectObject(dc, GetStockObject(NULL_PEN));
    }
    let mut bars = [None, None];
    for (index, object) in [OBJID_HSCROLL, OBJID_VSCROLL].into_iter().enumerate() {
        let mut info = SCROLLBARINFO {
            cbSize: size_of::<SCROLLBARINFO>() as u32,
            ..Default::default()
        };
        // SAFETY: OBJID selects native nonclient chrome; writable local storage.
        if unsafe { GetScrollBarInfo(window, object, &mut info) } == 0
            || info.rgstate[0] & (STATE_SYSTEM_INVISIBLE | STATE_SYSTEM_OFFSCREEN) != 0
        {
            continue;
        }
        let native = info.rcScrollBar;
        if native.left < bounds.left
            || native.top < bounds.top
            || native.right > bounds.right
            || native.bottom > bounds.bottom
        {
            continue;
        }
        let bar = LayoutRect {
            x: native.left - dx,
            y: native.top - dy,
            width: native.right - native.left,
            height: native.bottom - native.top,
        };
        let vertical = index == 1;
        let Some(parts) = calculate_scrollbar_parts(
            bar,
            vertical,
            info.dxyLineButton,
            info.xyThumbTop,
            info.xyThumbBottom,
        ) else {
            continue;
        };
        paint_scrollbar_rect(dc, bar, palette.surface_window);
        for (part_index, rect) in parts.into_iter().enumerate() {
            let state = info.rgstate[[1, 3, 5][part_index]] | info.rgstate[0];
            let disabled = state & windows_sys::Win32::UI::Controls::STATE_SYSTEM_UNAVAILABLE != 0;
            let hot = cursor_known
                && cursor.x - dx >= rect.x
                && cursor.x - dx < rect.right()
                && cursor.y - dy >= rect.y
                && cursor.y - dy < rect.bottom();
            // The thumb is the persistent position affordance; give it the
            // stronger outline/foreground ramp, rather than an arrow surface.
            let color = if part_index == 1 {
                if disabled {
                    palette.divider_subtle
                } else if state & STATE_SYSTEM_PRESSED != 0 {
                    palette.text_secondary
                } else if hot {
                    palette.text_disabled
                } else {
                    palette.control_outline
                }
            } else if disabled {
                palette.control_disabled
            } else if state & STATE_SYSTEM_PRESSED != 0 {
                palette.control_pressed
            } else if hot {
                palette.control_hover
            } else {
                palette.control_normal
            };
            paint_scrollbar_rect(dc, rect, color);
            if part_index != 1 {
                paint_scrollbar_arrow(
                    dc,
                    rect,
                    vertical,
                    part_index == 2,
                    if disabled {
                        palette.text_disabled
                    } else {
                        palette.text_primary
                    },
                );
            }
        }
        bars[index] = Some(bar);
    }
    if let [Some(horizontal), Some(vertical)] = bars {
        let corner = LayoutRect {
            x: vertical.x,
            y: horizontal.y,
            width: vertical.width,
            height: horizontal.height,
        };
        paint_scrollbar_rect(dc, corner, palette.surface_window);
    }
}

fn paint_scrollbar_rect(dc: HDC, rect: LayoutRect, color: u32) {
    if rect.width <= 0 || rect.height <= 0 {
        return;
    }
    let native = RECT {
        left: rect.x,
        top: rect.y,
        right: rect.right(),
        bottom: rect.bottom(),
    };
    // SAFETY: synchronous guarded window DC and nonclient-bounded local rectangle.
    unsafe {
        SetDCBrushColor(dc, color);
        FillRect(dc, &native, GetStockObject(DC_BRUSH));
    }
}

fn paint_scrollbar_arrow(dc: HDC, rect: LayoutRect, vertical: bool, forward: bool, color: u32) {
    let radius = (rect.width.min(rect.height) / 5).max(1);
    if rect.width < 3 || rect.height < 3 {
        return;
    }
    let cx = rect.x + rect.width / 2;
    let cy = rect.y + rect.height / 2;
    let direction = if forward { 1 } else { -1 };
    let points = if vertical {
        [
            POINT {
                x: cx - radius,
                y: cy - direction * radius / 2,
            },
            POINT {
                x: cx + radius,
                y: cy - direction * radius / 2,
            },
            POINT {
                x: cx,
                y: cy + direction * radius,
            },
        ]
    } else {
        [
            POINT {
                x: cx - direction * radius / 2,
                y: cy - radius,
            },
            POINT {
                x: cx - direction * radius / 2,
                y: cy + radius,
            },
            POINT {
                x: cx + direction * radius,
                y: cy,
            },
        ]
    };
    // SAFETY: three local points stay inside the native arrow button; DC restored.
    unsafe {
        SetDCBrushColor(dc, color);
        Polygon(dc, points.as_ptr(), points.len() as i32);
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RenderedRow {
    pub(super) values: [LegacyText; NATIVE_LIST_COLUMN_COUNT],
    pub(super) icon: i32,
    pub(super) icon_key: IconCacheKey,
    pub(super) icon_resolved: bool,
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
        // Header painting during the synchronous column change cannot borrow
        // AppState. Queue a repaint after this lease ends so newly shown cells
        // use the custom-draw palette instead of retaining the system colors.
        RedrawWindow(
            state.list_window,
            null(),
            null_mut(),
            RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
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
    let measured = PREVIEW_STATUS_LABELS
        .into_iter()
        .chain(core::iter::once(NATIVE_STATUS_COLUMN.label))
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
    #[cfg(test)]
    let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Widths);
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
                FillRect((*custom).hdc, &bottom, resources.divider_brush());
            }
            for divider in chrome.item_dividers {
                let divider = to_rect(divider);
                if divider.left < divider.right && divider.top < divider.bottom {
                    FillRect((*custom).hdc, &divider, resources.divider_brush());
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

fn paint_dark_blank_list_body(state: &AppState, dc: HDC) {
    let Some(resources) = state.appearance_resources.as_ref() else {
        return;
    };
    if state.resolved_appearance().theme != ResolvedTheme::Dark {
        return;
    }
    paint_blank_list_body(
        state.list_window,
        dc,
        resources.workspace_brush(),
        state.model.len(),
    );
}

fn paint_blank_list_body(list: HWND, dc: HDC, brush: HBRUSH, expected_rows: usize) {
    if list.is_null() || dc.is_null() || brush.is_null() {
        return;
    }
    let mut client = RECT::default();
    // SAFETY: this is the validated app-owned notification source; the native
    // value/rectangle queries retain no storage beyond their synchronous call.
    if unsafe { GetClientRect(list, &mut client) } == 0 {
        return;
    }
    // SAFETY: the count query has no pointer payload and state is UI-thread leased.
    let count = unsafe { SendMessageW(list, LVM_GETITEMCOUNT, 0, 0) };
    let Ok(count) = usize::try_from(count) else {
        return;
    };
    if count != expected_rows {
        return;
    }
    let header_bottom = native_list_header_height_px(list);
    let last_row_bottom = if count == 0 {
        header_bottom
    } else {
        let mut row = RECT {
            left: LVIR_BOUNDS as i32,
            ..RECT::default()
        };
        // SAFETY: count comes from the same live control, the final index is
        // valid, and row is writable for this non-retaining native query.
        if unsafe { SendMessageW(list, LVM_GETITEMRECT, count - 1, (&raw mut row) as LPARAM) } == 0
        {
            return;
        }
        row.bottom
    };
    let Some(body) = calculate_blank_list_body_rect(
        LayoutRect {
            x: client.left,
            y: client.top,
            width: client.right.saturating_sub(client.left),
            height: client.bottom.saturating_sub(client.top),
        },
        header_bottom,
        last_row_bottom,
    ) else {
        return;
    };
    let body = RECT {
        left: body.x,
        top: body.y,
        right: body.right(),
        bottom: body.bottom(),
    };
    // SAFETY: the callback DC and owned workspace brush stay live. Pure bounds
    // exclude the header, every occupied row and both non-client scrollbars.
    unsafe { FillRect(dc, &body, brush) };
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
        let postpaint = if state.resolved_appearance().theme == ResolvedTheme::Dark {
            CDRF_NOTIFYPOSTPAINT
        } else {
            0
        };
        return Some((CDRF_NOTIFYITEMDRAW | postpaint) as LRESULT);
    }
    if stage == CDDS_POSTPAINT {
        // SAFETY: same validated synchronous ListView payload; only the copied
        // live drawing handle is passed to the bounded blank-body painter.
        paint_dark_blank_list_body(state, unsafe { (*custom).nmcd.hdc });
        return Some(CDRF_DODEFAULT as LRESULT);
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
    let text = format!(
        "{}\n정확한 크기: {}",
        preview_item_details(item, state.preview_issue_cache.issue(row)),
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
    #[cfg(test)]
    refresh_profile::record(|counters| counters.last_filetime = None);
    refresh_preview_count_cache(state);
    if state.icon_image_list.is_some()
        && let Some(shared) = &state.icon_shared
        && shared.advance_generation()
    {
        state.icon_delivery_batch.clear();
        state.icon_delivery_ack_count = 0;
    }
    let _list_update = ProgrammaticListUpdateGuard::begin();
    // SAFETY: state.list_window is live and the guard restores redraw.
    let _redraw = unsafe { RedrawGuard::suspend(state.list_window) };
    let (selected, focused, viewport) = {
        #[cfg(test)]
        let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Selection);
        (
            selected_indices(state.list_window),
            focused_index(state.list_window),
            RefreshViewport::capture(state.list_window),
        )
    };
    // SAFETY: scalar count query on the owned live ListView. A count mismatch
    // requires an authoritative rebuild even if cached row values are equal.
    let native_count = unsafe { SendMessageW(state.list_window, LVM_GETITEMCOUNT, 0, 0) };
    let synchronized = state.preview_synchronization.is_synchronized()
        && native_count == state.rendered_rows.len() as isize
        && apply_incremental_rows(state);
    let synchronized = if synchronized {
        true
    } else {
        state.mark_preview_sync_failed();
        rebuild_rows_from_model(state)
    };
    if !synchronized {
        state.mark_preview_sync_failed();
        return;
    }
    state.icon_unresolved_rows = state
        .rendered_rows
        .iter()
        .filter(|row| !row.icon_resolved)
        .count();
    state.icon_scan_cursor = 0;
    // Keep a pinned batch until its next ACK, but no current row needs a
    // reconciliation sweep when every rendered icon is already resolved.
    state.icon_reconcile_remaining =
        if state.icon_unresolved_rows != 0 && state.icon_delivery_ack_count != 0 {
            state.rendered_rows.len()
        } else {
            0
        };
    // Terminal no-image rows need no demand pass even with a nonempty model.
    state.icon_demand_scan_remaining = if state.icon_unresolved_rows == 0 {
        0
    } else {
        state.rendered_rows.len()
    };
    state.icon_continue_posted = false;
    state.mark_preview_synchronized();
    {
        #[cfg(test)]
        let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Selection);
        restore_refresh_selection(state.list_window, &selected, focused, state.model.len());
    }
    update_primary_column_widths(state);
    {
        #[cfg(test)]
        let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Selection);
        viewport.restore(state.list_window, state.model.len());
    }
    schedule_icon_poll(state);
}

#[derive(Clone, Copy)]
struct RefreshViewport {
    top: isize,
    horizontal: Option<i32>,
}

impl RefreshViewport {
    fn capture(window: HWND) -> Self {
        // SAFETY: the owned ListView is live; the top-index message is scalar.
        let top = unsafe { SendMessageW(window, LVM_GETTOPINDEX, 0, 0) };
        let mut info = SCROLLINFO {
            cbSize: size_of::<SCROLLINFO>() as u32,
            fMask: SIF_POS,
            ..SCROLLINFO::default()
        };
        // SAFETY: info has the documented size and writable position field.
        let horizontal =
            (unsafe { GetScrollInfo(window, SB_HORZ, &mut info) } != 0).then_some(info.nPos);
        Self { top, horizontal }
    }

    fn restore(self, window: HWND, rows: usize) {
        if rows != 0 {
            let target = self.top.max(0).min((rows - 1) as isize);
            // SAFETY: scalar top-index query on the same live ListView.
            let current = unsafe { SendMessageW(window, LVM_GETTOPINDEX, 0, 0) };
            if current != target {
                let mut rect = RECT {
                    left: LVIR_BOUNDS as i32,
                    ..RECT::default()
                };
                // SAFETY: row zero exists and rect is writable for this
                // synchronous bounds query.
                if unsafe {
                    SendMessageW(
                        window,
                        LVM_GETITEMRECT,
                        0,
                        (&mut rect as *mut RECT) as isize,
                    )
                } != 0
                {
                    let height = rect.bottom.saturating_sub(rect.top);
                    if height > 0 {
                        let dy = (target - current).saturating_mul(height as isize);
                        // SAFETY: scalar pixel delta on the live report ListView.
                        unsafe { SendMessageW(window, LVM_SCROLL, 0, dy) };
                    }
                }
            }
        }
        if let Some(target) = self.horizontal
            && let Some(current) = Self::capture(window).horizontal
            && current != target
        {
            let dx = target.saturating_sub(current) as isize;
            // SAFETY: signed pixel delta is passed by bit pattern through
            // WPARAM; the live ListView retains no caller storage.
            unsafe { SendMessageW(window, LVM_SCROLL, dx as usize, 0) };
        }
    }
}

fn restore_refresh_selection(
    window: HWND,
    selected: &[usize],
    focused: Option<usize>,
    rows: usize,
) {
    let current_selected = selected_indices(window);
    if current_selected
        .iter()
        .copied()
        .ne(selected.iter().copied().filter(|row| *row < rows))
    {
        let mut clear = LVITEMW {
            stateMask: LVIS_SELECTED,
            ..LVITEMW::default()
        };
        // SAFETY: the special all-items index and writable state item clear
        // only selection on this live ListView; focus is independent.
        unsafe {
            SendMessageW(
                window,
                LVM_SETITEMSTATE,
                usize::MAX,
                (&mut clear as *mut LVITEMW) as isize,
            )
        };
        for row in selected.iter().copied().filter(|row| *row < rows) {
            let mut item = LVITEMW {
                stateMask: LVIS_SELECTED,
                state: LVIS_SELECTED,
                ..LVITEMW::default()
            };
            // SAFETY: row exists and item remains writable through the
            // synchronous state update; no ensure-visible message is sent.
            unsafe {
                SendMessageW(
                    window,
                    LVM_SETITEMSTATE,
                    row,
                    (&mut item as *mut LVITEMW) as isize,
                )
            };
        }
    }
    let target = focused.filter(|row| *row < rows);
    if let Some(current) = focused_index(window)
        && Some(current) != target
    {
        let mut item = LVITEMW {
            stateMask: LVIS_FOCUSED,
            ..LVITEMW::default()
        };
        // SAFETY: native reported current as a live focused row.
        unsafe {
            SendMessageW(
                window,
                LVM_SETITEMSTATE,
                current,
                (&mut item as *mut LVITEMW) as isize,
            )
        };
    }
    if let Some(target) = target
        && focused_index(window) != Some(target)
    {
        let mut item = LVITEMW {
            stateMask: LVIS_FOCUSED,
            state: LVIS_FOCUSED,
            ..LVITEMW::default()
        };
        // SAFETY: target remains a live in-range row through this call.
        unsafe {
            SendMessageW(
                window,
                LVM_SETITEMSTATE,
                target,
                (&mut item as *mut LVITEMW) as isize,
            )
        };
    }
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
        let icon_shared = state.icon_shared.as_deref();
        changed
            .iter()
            .map(|index| {
                (
                    *index,
                    rendered_row(
                        icon_cache,
                        icon_shared,
                        state.rendered_rows.get(*index),
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
    state.icon_unresolved_rows = state
        .rendered_rows
        .iter()
        .filter(|row| !row.icon_resolved)
        .count();
    // A changed text row cannot create icon work when every icon is resolved.
    state.icon_reconcile_remaining = if state.icon_unresolved_rows == 0 {
        0
    } else {
        state.rendered_rows.len()
    };
    state.icon_scan_cursor = 0;
    state.icon_demand_scan_remaining = if state.icon_unresolved_rows == 0 {
        0
    } else {
        state.rendered_rows.len()
    };
    schedule_icon_poll(state);
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
        #[cfg(test)]
        let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Issues);
        #[cfg(test)]
        refresh_profile::record(|counters| counters.issue_count_input_rows_visited += 1);
        let item = &state.model.items()[*row];
        let update = state.preview_issue_cache.refresh_one_by(
            state.model.len(),
            *row,
            PreviewRowInput {
                parent: item.root_path(),
                current: item.current_name(),
                proposed: item.proposed_name(),
                is_directory: item.is_directory(),
                change: item.planned_change_kind(),
            },
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
    #[cfg(test)]
    let _native_clock = refresh_profile::Clock::begin(refresh_profile::Stage::Native);
    debug_assert_eq!(plan.proposal_cells, plan.rows.len());
    debug_assert_eq!(plan.immutable_cells, 0);
    debug_assert_eq!(plan.full_row_formats, 0);
    let _list_update = ProgrammaticListUpdateGuard::begin();
    // SAFETY: state.list_window is live and the guard restores redraw.
    let _redraw = unsafe { RedrawGuard::suspend(state.list_window) };
    for row in plan.rows {
        #[cfg(test)]
        refresh_profile::record(|counters| counters.native_rows_visited += 1);
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
    #[cfg(test)]
    let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Issues);
    #[cfg(test)]
    refresh_profile::record(|counters| {
        counters.issue_count_input_rows_visited += state.model.len() * 2
    });
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
        #[cfg(test)]
        refresh_profile::record(|counters| counters.native_rows_visited += 1);
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
    #[cfg(test)]
    let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Issues);
    #[cfg(test)]
    refresh_profile::record(|counters| {
        counters.issue_count_input_rows_visited += state.model.len() * 2
    });
    state.preview_count_cache.refresh(
        state
            .model
            .items()
            .iter()
            .map(LegacyListItem::planned_change_kind),
    );
    state.preview_issue_cache.refresh_by(
        state.model.items().iter().map(|item| PreviewRowInput {
            parent: item.root_path(),
            current: item.current_name(),
            proposed: item.proposed_name(),
            is_directory: item.is_directory(),
            change: item.planned_change_kind(),
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
    icon_shared: Option<&IconShared>,
    previous: Option<&RenderedRow>,
    item: &LegacyListItem,
    issue: PreviewRowIssue,
) -> RenderedRow {
    #[cfg(test)]
    let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Rows);
    #[cfg(test)]
    refresh_profile::record(|counters| counters.rows_formatted += 1);
    let key = icon_cache_key(item.current_name(), item.is_directory());
    let (icon, icon_resolved) = if let Some(index) = icon_cache.get(&key) {
        #[cfg(test)]
        refresh_profile::record(|counters| counters.render_icon_cache_hits += 1);
        (*index, true)
    } else {
        #[cfg(test)]
        refresh_profile::record(|counters| counters.render_icon_cache_misses += 1);
        if let Some(previous) = previous.filter(|row| {
            row.icon_resolved
                && row.icon_key == key
                && row.values[0] == *item.current_name()
                && row.values[2] == *item.root_path()
                && row.values[3] == *item.source_path()
        }) {
            (previous.icon, true)
        } else if let Some(shared) = icon_shared {
            #[cfg(test)]
            refresh_profile::record(|counters| counters.icon_request_submissions += 1);
            let _ = shared.submit(key.clone());
            (I_IMAGENONE, shared.is_unavailable())
        } else {
            (I_IMAGENONE, true)
        }
    };
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
        icon,
        icon_key: key,
        icon_resolved,
    }
}

pub(super) fn schedule_icon_poll(state: &AppState) {
    let Some(shared) = &state.icon_shared else {
        return;
    };
    if shared.owner_destroyed() {
        return;
    }
    if state.list_window.is_null() {
        return;
    }
    // SAFETY: the list is a live child while its AppState is leased.
    let owner = unsafe { GetParent(state.list_window) };
    if owner.is_null() {
        return;
    }
    if (state.close_pending && !shared.is_joined())
        || (!state.close_pending
            && (state.icon_unresolved_rows != 0 || shared.pending_count() != 0))
    {
        // SAFETY: this pointer-free timer belongs to the live owner. The
        // worker sends a thread wake, while this timer covers lost/modal wakes.
        unsafe { SetTimer(owner, ICON_POLL_TIMER_ID, 250, None) };
    } else {
        // SAFETY: killing an absent timer for this live owner is harmless.
        unsafe { KillTimer(owner, ICON_POLL_TIMER_ID) };
    }
}

/// Processes at most one bounded completion batch and 256 current rows.
pub(super) fn poll_icon_work(state: &mut AppState) {
    let Some(shared) = state.icon_shared.as_ref().map(Arc::clone) else {
        return;
    };
    if shared.owner_destroyed() {
        return;
    }
    if state.close_pending || !state.preview_synchronization.is_synchronized() {
        schedule_icon_poll(state);
        return;
    }
    if state.icon_delivery_ack_count != 0 && state.icon_reconcile_remaining == 0 {
        if shared.acknowledge_completions(state.icon_delivery_ack_count) {
            state.icon_delivery_batch.clear();
            state.icon_delivery_ack_count = 0;
            state.icon_demand_scan_remaining = state.rendered_rows.len();
        } else {
            schedule_icon_poll(state);
            return;
        }
    }
    let mut had_completions = false;
    if state.icon_delivery_ack_count == 0
        && let Some(completions) = shared.snapshot_completions()
    {
        had_completions = !completions.is_empty();
        #[cfg(test)]
        refresh_profile::record(|counters| counters.icon_results_drained += completions.len());
        state.icon_delivery_ack_count = completions.len();
        for completion in completions {
            match completion.result {
                icon_worker::IconResult::Bootstrap(Some(list)) => {
                    if state.icon_image_list.is_none() {
                        // SAFETY: the Shell thread validated this borrowed
                        // process-shared image list. The ListView is live and
                        // LVM_SETIMAGELIST transfers only its scalar handle.
                        unsafe {
                            SendMessageW(
                                state.list_window,
                                LVM_SETIMAGELIST,
                                LVSIL_SMALL as usize,
                                list.raw(),
                            )
                        };
                        if shared.owner_destroyed() {
                            return;
                        }
                        state.icon_image_list = Some(list);
                    }
                }
                icon_worker::IconResult::Bootstrap(None) => {}
                icon_worker::IconResult::Class { list, index } => {
                    let resolved = if list == state.icon_image_list && index >= 0 {
                        index
                    } else {
                        I_IMAGENONE
                    };
                    if let crate::icon_requests::RequestKey::Class(key) = completion.request.key {
                        cache_icon_index(&mut state.icon_cache, key.clone(), resolved);
                        state.icon_delivery_batch.push((key, resolved));
                    }
                }
            }
        }
    }
    if had_completions {
        // A completed class stays in the existing 256-entry cache until every
        // current row has had a bounded chance to consume it. Do not admit a
        // newer batch that could evict it during this sweep.
        state.icon_reconcile_remaining = state.rendered_rows.len();
        state.icon_scan_cursor = 0;
    }
    if state.model.len() != state.rendered_rows.len() {
        state.mark_preview_sync_failed();
        schedule_icon_poll(state);
        return;
    }
    // A full queue blocked in Shell has no new capacity to fill. The worker
    // wake drives the next chunk; the slower timer only rescues lost wakes.
    let reconciling = state.icon_reconcile_remaining != 0;
    let visits = if reconciling {
        state.icon_reconcile_remaining.min(256)
    } else if !had_completions
        && shared.pending_count() == crate::icon_requests::MAX_PENDING_ICON_REQUESTS
    {
        0
    } else {
        state.icon_demand_scan_remaining.min(256)
    };
    let mut productive = had_completions;
    let mut admission_busy = false;
    for _ in 0..visits {
        let row_index = state.icon_scan_cursor;
        state.icon_scan_cursor = (row_index + 1) % state.rendered_rows.len();
        if reconciling {
            state.icon_reconcile_remaining -= 1;
        } else {
            state.icon_demand_scan_remaining = state.icon_demand_scan_remaining.saturating_sub(1);
        }
        let row = &mut state.rendered_rows[row_index];
        if row.icon_resolved {
            continue;
        }
        let Some(item) = state.model.items().get(row_index) else {
            state.mark_preview_sync_failed();
            break;
        };
        if row.icon_key != icon_cache_key(item.current_name(), item.is_directory())
            || row.values[0] != *item.current_name()
            || row.values[2] != *item.root_path()
            || row.values[3] != *item.source_path()
        {
            state.mark_preview_sync_failed();
            break;
        }
        let value = state
            .icon_delivery_batch
            .iter()
            .find(|(key, _)| *key == row.icon_key)
            .map(|(_, index)| *index)
            .or_else(|| state.icon_cache.get(&row.icon_key).copied());
        let value = value.or_else(|| shared.is_unavailable().then_some(I_IMAGENONE));
        if let Some(value) = value {
            if row.icon != value {
                let applied = set_native_icon(state.list_window, row_index, value);
                if shared.owner_destroyed() {
                    return;
                }
                if !applied {
                    state.mark_preview_sync_failed();
                    #[cfg(test)]
                    ICON_TEST_NATIVE_FAILURE_APPLY_BLOCKED.with(|observed| {
                        observed
                            .set(state.presentation(0).apply == crate::ApplyPresentation::Blocked);
                    });
                    break;
                }
            }
            row.icon = value;
            row.icon_resolved = true;
            state.icon_unresolved_rows -= 1;
            productive = true;
        } else if !reconciling {
            match shared.submit(row.icon_key.clone()) {
                icon_worker::IconSubmit::State(crate::icon_requests::SubmitDisposition::Queued) => {
                    productive = true
                }
                icon_worker::IconSubmit::Busy => admission_busy = true,
                _ => {}
            }
        }
    }
    if shared.owner_destroyed() {
        return;
    }
    if state.icon_reconcile_remaining == 0
        && state.icon_delivery_ack_count != 0
        && shared.acknowledge_completions(state.icon_delivery_ack_count)
    {
        state.icon_delivery_batch.clear();
        state.icon_delivery_ack_count = 0;
        state.icon_demand_scan_remaining = state.rendered_rows.len();
    }
    if !state.preview_synchronization.is_synchronized() {
        refresh(state);
    }
    if shared.owner_destroyed() {
        return;
    }
    let mut retry_after_exhaustion = false;
    if state.icon_unresolved_rows == 0 {
        state.icon_demand_scan_remaining = 0;
    } else if state.icon_reconcile_remaining == 0
        && state.icon_demand_scan_remaining == 0
        && shared.pending_count() == 0
    {
        // One bounded pass can observe a transient busy submit. Retry from
        // the slower fallback timer when no request can free capacity.
        state.icon_demand_scan_remaining = state.rendered_rows.len();
        retry_after_exhaustion = true;
    }
    let demand_can_advance = state.icon_demand_scan_remaining != 0
        && (shared.pending_count() < crate::icon_requests::MAX_PENDING_ICON_REQUESTS
            || shared.is_unavailable());
    if !admission_busy
        && !retry_after_exhaustion
        && (productive || state.icon_reconcile_remaining != 0 || demand_can_advance)
        && state.icon_unresolved_rows != 0
        && !state.icon_continue_posted
    {
        // SAFETY: the current live ListView remains a child of this owner; the
        // private message carries no pointer and is coalesced in AppState.
        let owner = unsafe { GetParent(state.list_window) };
        if !owner.is_null()
            // SAFETY: the owner is live on this UI thread, and failed posts
            // are covered by the slower timer while demand remains.
            && unsafe { PostMessageW(owner, WM_APP_ICON_CONTINUE, 0, 0) } != 0
        {
            state.icon_continue_posted = true;
        }
    }
    schedule_icon_poll(state);
}

fn set_native_icon(window: HWND, row: usize, icon: i32) -> bool {
    #[cfg(test)]
    if ICON_TEST_FAIL_NEXT_NATIVE_SET.with(|failure| failure.replace(false)) {
        return false;
    }
    let mut native = LVITEMW {
        mask: LVIF_IMAGE,
        iItem: i32::try_from(row).unwrap_or(i32::MAX),
        iImage: icon,
        ..LVITEMW::default()
    };
    // SAFETY: this live ListView consumes only the image field of writable
    // LVITEMW during the synchronous call; no text or model pointer is lent.
    unsafe {
        SendMessageW(
            window,
            LVM_SETITEMW,
            0,
            (&mut native as *mut LVITEMW) as isize,
        ) != 0
    }
}

#[cfg(test)]
thread_local! {
    static ICON_TEST_FAIL_NEXT_NATIVE_SET: Cell<bool> = const { Cell::new(false) };
    static ICON_TEST_NATIVE_FAILURE_APPLY_BLOCKED: Cell<bool> = const { Cell::new(false) };
}

fn apply_incremental_rows(state: &mut AppState) -> bool {
    #[cfg(test)]
    if FAIL_NATIVE_INCREMENTAL_FOR_TEST.with(|slot| slot.replace(false)) {
        return false;
    }
    let window = state.list_window;
    let new_len = state.model.len();
    let old_len = state.rendered_rows.len();
    #[cfg(test)]
    let previous_capacity = state.rendered_rows.capacity();
    if new_len > old_len
        && state
            .rendered_rows
            .try_reserve_exact(new_len - old_len)
            .is_err()
    {
        return false;
    }
    #[cfg(test)]
    refresh_profile::record(|counters| {
        let capacity = state.rendered_rows.capacity();
        counters.rendered_vec_growth_events += usize::from(capacity > previous_capacity);
        counters.rendered_vec_capacity_bytes_peak = counters
            .rendered_vec_capacity_bytes_peak
            .max(capacity * size_of::<RenderedRow>());
    });
    for row in (new_len..old_len).rev() {
        let deleted = {
            #[cfg(test)]
            let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Native);
            // SAFETY: window is live and row is a current trailing item.
            unsafe { SendMessageW(window, LVM_DELETEITEM, row, 0) }
        };
        if deleted == 0 {
            return false;
        }
        #[cfg(test)]
        refresh_profile::record(|counters| counters.native_deletions += 1);
    }
    state.rendered_rows.truncate(new_len);
    for row in 0..new_len {
        // These borrows end before native dispatch. The owned row is the only
        // transient full-row payload; prior identity still gates icon reuse.
        let value = rendered_row(
            &mut state.icon_cache,
            state.icon_shared.as_deref(),
            state.rendered_rows.get(row),
            &state.model.items()[row],
            state.preview_issue_cache.issue(row),
        );
        #[cfg(test)]
        refresh_profile::record(|counters| {
            let bytes = value.values.iter().map(|text| text.len() * 2).sum();
            counters.normal_staged_rows_peak = counters.normal_staged_rows_peak.max(1);
            counters.normal_logical_staged_payload_bytes_peak =
                counters.normal_logical_staged_payload_bytes_peak.max(bytes);
            if old_len != 0 {
                counters.extra_staged_rows_peak = counters.extra_staged_rows_peak.max(1);
                counters.logical_staged_payload_bytes_peak =
                    counters.logical_staged_payload_bytes_peak.max(bytes);
            }
        });
        if row < state.rendered_rows.len() {
            let mask = changed_column_mask(&state.rendered_rows[row], &value);
            let applied = {
                #[cfg(test)]
                let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Native);
                apply_rendered_row_with_mask(window, row, &value, mask)
            };
            if !applied {
                return false;
            }
            state.rendered_rows[row] = value;
        } else {
            let inserted = {
                #[cfg(test)]
                let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Native);
                insert_native_row(window, row, &value)
            };
            if !inserted {
                return false;
            }
            state.rendered_rows.push(value);
        }
    }
    if new_len == 0 {
        state.rendered_rows.shrink_to_fit();
    }
    true
}

fn rebuild_rows_from_model(state: &mut AppState) -> bool {
    let mut rows = Vec::new();
    if rows.try_reserve_exact(state.model.len()).is_err() {
        return false;
    }
    for (row, item) in state.model.items().iter().enumerate() {
        rows.push(rendered_row(
            &mut state.icon_cache,
            state.icon_shared.as_deref(),
            state.rendered_rows.get(row),
            item,
            state.preview_issue_cache.issue(row),
        ));
    }
    #[cfg(test)]
    refresh_profile::record(|counters| {
        let payload = rows
            .iter()
            .flat_map(|row| &row.values)
            .map(|text| text.len() * 2)
            .sum();
        counters.fallback_staged_rows_peak = counters.fallback_staged_rows_peak.max(rows.len());
        counters.fallback_logical_staged_payload_bytes_peak = counters
            .fallback_logical_staged_payload_bytes_peak
            .max(payload);
        if !state.rendered_rows.is_empty() {
            counters.extra_staged_rows_peak = counters.extra_staged_rows_peak.max(rows.len());
            counters.logical_staged_payload_bytes_peak =
                counters.logical_staged_payload_bytes_peak.max(payload);
        }
        counters.rendered_vec_capacity_bytes_peak = counters
            .rendered_vec_capacity_bytes_peak
            .max(rows.capacity() * size_of::<RenderedRow>());
    });
    if !rebuild_native_rows(state.list_window, &rows) {
        return false;
    }
    state.rendered_rows = rows;
    true
}

fn apply_rendered_row(window: HWND, row: usize, old: &RenderedRow, new: &RenderedRow) -> bool {
    apply_rendered_row_with_mask(window, row, new, changed_column_mask(old, new))
}

fn apply_rendered_row_with_mask(window: HWND, row: usize, new: &RenderedRow, mask: u8) -> bool {
    #[cfg(test)]
    refresh_profile::record(|counters| counters.native_rows_visited += 1);
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
    #[cfg(test)]
    refresh_profile::record(|counters| {
        counters.native_rows_visited += 1;
    });
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
    #[cfg(test)]
    refresh_profile::record(|counters| {
        counters.native_insertions += 1;
        counters.native_cells += 1;
    });
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
    let applied = unsafe {
        SendMessageW(
            window,
            LVM_SETITEMW,
            0,
            (&mut native as *mut LVITEMW) as isize,
        ) != 0
    };
    #[cfg(test)]
    if applied {
        refresh_profile::record(|counters| counters.native_cells += 1);
    }
    applied
}

fn set_native_subitem(window: HWND, row: usize, column: usize, value: &LegacyText) -> bool {
    #[cfg(test)]
    if fail_native_refresh_cell_for_test() {
        return false;
    }
    let mut text = value.units().to_vec();
    text.push(0);
    let mut native = LVITEMW {
        iSubItem: i32::try_from(column).unwrap_or(i32::MAX),
        pszText: text.as_mut_ptr(),
        ..LVITEMW::default()
    };
    // SAFETY: window is live; native and text outlive the synchronous message.
    let applied = unsafe {
        SendMessageW(
            window,
            LVM_SETITEMTEXTW,
            row,
            (&mut native as *mut LVITEMW) as isize,
        ) != 0
    };
    #[cfg(test)]
    if applied {
        refresh_profile::record(|counters| counters.native_cells += 1);
    }
    applied
}

fn rebuild_native_rows(window: HWND, rows: &[RenderedRow]) -> bool {
    #[cfg(test)]
    let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Native);
    #[cfg(test)]
    refresh_profile::record(|counters| counters.full_rebuilds += 1);
    #[cfg(test)]
    if FAIL_NATIVE_REBUILD_FOR_TEST.with(Cell::get) {
        return false;
    }
    // SAFETY: window is live and the message carries no pointer.
    if unsafe { SendMessageW(window, LVM_DELETEALLITEMS, 0, 0) } == 0 {
        return false;
    }
    rows.iter()
        .enumerate()
        .all(|(row, value)| insert_native_row(window, row, value))
}

#[cfg(test)]
thread_local! {
    // Reject the next native update before dispatch on a live test-owned HWND.
    static FAIL_NATIVE_INCREMENTAL_FOR_TEST: Cell<bool> = const { Cell::new(false) };
    static FAIL_NATIVE_REBUILD_FOR_TEST: Cell<bool> = const { Cell::new(false) };
    static FAIL_NATIVE_CELL_AFTER_FOR_TEST: Cell<Option<usize>> = const { Cell::new(None) };
}

#[cfg(test)]
fn fail_native_refresh_cell_for_test() -> bool {
    FAIL_NATIVE_CELL_AFTER_FOR_TEST.with(|slot| match slot.get() {
        Some(0) => {
            slot.set(None);
            true
        }
        Some(remaining) => {
            slot.set(Some(remaining - 1));
            false
        }
        None => false,
    })
}

#[cfg(test)]
fn cached_file_icon_index(
    cache: &mut HashMap<IconCacheKey, i32>,
    item: &LegacyListItem,
    query: impl FnOnce(&IconCacheKey, bool) -> (usize, i32),
) -> i32 {
    let key = icon_cache_key(item.current_name(), item.is_directory());
    if let Some(index) = cache.get(&key) {
        return *index;
    }
    let (result, index) = query(&key, item.is_directory());
    // A failed query leaves SHFILEINFOW unusable. Cache a known no-image
    // fallback so a failing class cannot repeatedly block each row refresh.
    // I_IMAGECALLBACK (-1) would instead request a parent callback.
    let index = if result != 0 && index >= 0 {
        index
    } else {
        I_IMAGENONE
    };
    cache_icon_index(cache, key, index);
    index
}

#[cfg(test)]
fn query_shell_icon_index(key: &IconCacheKey, is_directory: bool) -> (usize, i32) {
    let mut info = SHFILEINFOW::default();
    let path = key.lookup_text();
    let mut path = path.units().to_vec();
    path.push(0);
    let attributes = if is_directory {
        FILE_ATTRIBUTE_DIRECTORY
    } else {
        FILE_ATTRIBUTE_NORMAL
    };
    // SAFETY: path is terminated and info is writable for the shell query.
    let result = {
        #[cfg(test)]
        let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Shell);
        #[cfg(test)]
        refresh_profile::record(|counters| counters.ui_shell_calls += 1);
        // SAFETY: path is terminated and info remains writable through the call.
        unsafe {
            SHGetFileInfoW(
                path.as_ptr(),
                attributes,
                &mut info,
                size_of::<SHFILEINFOW>() as u32,
                SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON,
            )
        }
    };
    (result, info.iIcon)
}

fn format_filetime(value: u64) -> LegacyText {
    #[cfg(test)]
    let _clock = refresh_profile::Clock::begin(refresh_profile::Stage::Timestamps);
    #[cfg(test)]
    refresh_profile::record(|counters| {
        counters.timestamp_values += 1;
        if value != 0 && counters.last_filetime == Some(value) {
            counters.repeated_nonzero_filetime_inputs += 1;
        }
        counters.last_filetime = (value != 0).then_some(value);
    });
    #[cfg(test)]
    if let Some(formatted) = DATE_ENVIRONMENT_FOR_TEST.with(|slot| {
        slot.borrow()
            .as_ref()
            .map(|(locale, zone)| format_filetime_with_environment(value, locale.as_ptr(), zone))
    }) {
        return formatted;
    }
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

#[cfg(test)]
fn format_filetime_with_environment(
    value: u64,
    locale: *const u16,
    zone: *const DYNAMIC_TIME_ZONE_INFORMATION,
) -> LegacyText {
    let Some(system) = local_systemtime_from_filetime_in_zone(value, zone) else {
        return LegacyText::default();
    };
    if let Some(localized) = format_local_systemtime_in_locale(&system, locale) {
        return LegacyText::from(localized);
    }
    LegacyText::from(format_timestamp_fallback(
        [system.wYear, system.wMonth, system.wDay],
        [system.wHour, system.wMinute, system.wSecond],
    ))
}

#[cfg(test)]
fn local_systemtime_from_filetime_in_zone(
    value: u64,
    zone: *const DYNAMIC_TIME_ZONE_INFORMATION,
) -> Option<SYSTEMTIME> {
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
    // SAFETY: zone is null for the current dynamic Windows time zone or points
    // to a live test-owned zone; utc is readable and local writable.
    if unsafe { SystemTimeToTzSpecificLocalTimeEx(zone, &utc, &mut local) } == 0 {
        return None;
    }
    Some(local)
}

#[cfg(test)]
fn format_local_systemtime_in_locale(system: &SYSTEMTIME, locale: *const u16) -> Option<String> {
    let date = format_locale_part(|buffer, capacity| {
        // SAFETY: locale is null for the user's default or points to a live
        // test-owned name; system and the supplied output storage are valid.
        unsafe {
            GetDateFormatEx(
                locale,
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
        // SAFETY: locale has the same lifetime as above; system and output
        // storage follow the GetTimeFormatEx contract.
        unsafe { GetTimeFormatEx(locale, 0, system, null(), buffer, capacity) }
    })?;
    Some(format!("{date} {time}"))
}

#[cfg(test)]
thread_local! {
    // Explicit NLS inputs keep native date tests independent of OS settings.
    static DATE_ENVIRONMENT_FOR_TEST: std::cell::RefCell<Option<(Vec<u16>, DYNAMIC_TIME_ZONE_INFORMATION)>> = const { std::cell::RefCell::new(None) };
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
mod refresh_profile {
    #![forbid(unsafe_code)]

    use std::cell::RefCell;
    use std::time::Instant;

    #[derive(Clone, Copy)]
    pub(super) enum Stage {
        Issues,
        Rows,
        Timestamps,
        Shell,
        Native,
        Selection,
        Widths,
    }

    #[derive(Default)]
    pub(super) struct Counters {
        // Input model/cache rows handed to count, issue and status-delta passes;
        // internal cached destination-group visits are timed, not counted here.
        pub(super) issue_count_input_rows_visited: usize,
        pub(super) native_rows_visited: usize,
        pub(super) rows_formatted: usize,
        pub(super) timestamp_values: usize,
        pub(super) ui_shell_calls: usize,
        pub(super) render_icon_cache_hits: usize,
        pub(super) render_icon_cache_misses: usize,
        pub(super) icon_request_submissions: usize,
        pub(super) icon_results_drained: usize,
        pub(super) native_cells: usize,
        pub(super) native_insertions: usize,
        pub(super) native_deletions: usize,
        pub(super) full_rebuilds: usize,
        pub(super) extra_staged_rows_peak: usize,
        pub(super) logical_staged_payload_bytes_peak: usize,
        pub(super) normal_staged_rows_peak: usize,
        pub(super) normal_logical_staged_payload_bytes_peak: usize,
        pub(super) fallback_staged_rows_peak: usize,
        pub(super) fallback_logical_staged_payload_bytes_peak: usize,
        pub(super) rendered_vec_growth_events: usize,
        pub(super) rendered_vec_capacity_bytes_peak: usize,
        pub(super) repeated_nonzero_filetime_inputs: usize,
        pub(super) last_filetime: Option<u64>,
        times_ns: [u128; 7],
        maximum_shell_ns: u128,
    }

    thread_local! {
        static COUNTERS: RefCell<Option<Counters>> = const { RefCell::new(None) };
    }

    pub(super) fn record(action: impl FnOnce(&mut Counters)) {
        COUNTERS.with(|slot| {
            if let Some(counters) = slot.borrow_mut().as_mut() {
                action(counters);
            }
        });
    }

    pub(super) struct Clock {
        stage: Stage,
        started: Option<Instant>,
    }

    impl Clock {
        pub(super) fn begin(stage: Stage) -> Self {
            let active = COUNTERS.with(|slot| slot.borrow().is_some());
            Self {
                stage,
                started: active.then(Instant::now),
            }
        }
    }

    impl Drop for Clock {
        fn drop(&mut self) {
            if let Some(started) = self.started {
                let elapsed = started.elapsed().as_nanos();
                record(|counters| {
                    counters.times_ns[self.stage as usize] += elapsed;
                    if matches!(self.stage, Stage::Shell) {
                        counters.maximum_shell_ns = counters.maximum_shell_ns.max(elapsed);
                    }
                });
            }
        }
    }

    pub(super) struct Collection {
        started: Instant,
    }

    impl Collection {
        pub(super) fn begin() -> Self {
            COUNTERS.with(|slot| {
                assert!(slot.borrow().is_none(), "refresh collection cannot nest");
                *slot.borrow_mut() = Some(Counters::default());
            });
            Self {
                started: Instant::now(),
            }
        }

        pub(super) fn finish(self, scenario: &str, rows: usize) -> Counters {
            // Capture both boundaries and detach counters before any output.
            let elapsed_ns = self.started.elapsed().as_nanos();
            let counters = COUNTERS
                .with(|slot| slot.borrow_mut().take())
                .unwrap_or_default();
            let [
                issues,
                inclusive_rows,
                timestamps,
                shell,
                native,
                selection,
                widths,
            ] = counters.times_ns;
            assert!(timestamps + shell <= inclusive_rows);
            let exclusive_rows = inclusive_rows - timestamps - shell;
            assert_eq!(shell, 0, "detached UI fixture made a Shell call");
            assert_eq!(counters.maximum_shell_ns, 0);
            assert_eq!(counters.ui_shell_calls, 0);
            println!(
                "{{\"kind\":\"refresh-stages-icon-async-streaming-test-build\",\"schema_version\":3,\"icon_worker_attached\":false,\"scenario\":\"{scenario}\",\"rows\":{rows},\"scenario_envelope_ns\":{elapsed_ns},\"issue_count_ns\":{issues},\"row_values_inclusive_ns\":{inclusive_rows},\"row_values_exclusive_ns\":{exclusive_rows},\"timestamps_nested_ns\":{timestamps},\"ui_shell_nested_ns\":{shell},\"ui_shell_max_ns\":{},\"native_apply_rebuild_ns\":{native},\"selection_ns\":{selection},\"column_widths_ns\":{widths},\"issue_count_input_rows_visited\":{},\"native_rows_visited\":{},\"rows_formatted\":{},\"timestamp_values\":{},\"ui_shell_calls\":{},\"render_icon_cache_hits\":{},\"render_icon_cache_misses\":{},\"icon_request_submissions\":{},\"icon_results_drained\":{},\"native_cell_updates\":{},\"native_row_insertions\":{},\"native_row_deletions\":{},\"full_rebuilds\":{},\"extra_staged_rows_peak\":{},\"logical_staged_payload_bytes_peak\":{},\"normal_staged_rows_peak\":{},\"normal_logical_staged_payload_bytes_peak\":{},\"fallback_staged_rows_peak\":{},\"fallback_logical_staged_payload_bytes_peak\":{},\"rendered_vec_growth_events\":{},\"rendered_vec_capacity_bytes_peak\":{},\"repeated_nonzero_filetime_inputs\":{}}}",
                counters.maximum_shell_ns,
                counters.issue_count_input_rows_visited,
                counters.native_rows_visited,
                counters.rows_formatted,
                counters.timestamp_values,
                counters.ui_shell_calls,
                counters.render_icon_cache_hits,
                counters.render_icon_cache_misses,
                counters.icon_request_submissions,
                counters.icon_results_drained,
                counters.native_cells,
                counters.native_insertions,
                counters.native_deletions,
                counters.full_rebuilds,
                counters.extra_staged_rows_peak,
                counters.logical_staged_payload_bytes_peak,
                counters.normal_staged_rows_peak,
                counters.normal_logical_staged_payload_bytes_peak,
                counters.fallback_staged_rows_peak,
                counters.fallback_logical_staged_payload_bytes_peak,
                counters.rendered_vec_growth_events,
                counters.rendered_vec_capacity_bytes_peak,
                counters.repeated_nonzero_filetime_inputs,
            );
            counters
        }
    }

    impl Drop for Collection {
        fn drop(&mut self) {
            COUNTERS.with(|slot| {
                slot.borrow_mut().take();
            });
        }
    }
}

#[cfg(test)]
mod native_tests {
    use std::fs::File;
    use std::io::Read;
    use std::process::Command;
    use std::process::{Child, Stdio};
    use std::sync::Condvar;
    use std::sync::mpsc::{self, Sender};
    use std::time::{Duration, Instant};

    use super::super::visual_capture::capture_window_pixels;
    use super::*;
    use windows_sys::Win32::Foundation::{
        ERROR_NO_MORE_ITEMS, ERROR_SUCCESS, ERROR_TIMEOUT, GetLastError, SetLastError,
    };
    use windows_sys::Win32::System::Time::EnumDynamicTimeZoneInformation;
    use windows_sys::Win32::UI::Controls::{
        LVIR_BOUNDS, LVM_GETBKCOLOR, LVM_GETIMAGELIST, LVM_GETITEMRECT, LVM_GETITEMW,
        LVM_GETTOPINDEX, LVM_SCROLL, LVM_SETBKCOLOR, LVM_SETTEXTBKCOLOR, LVM_SETTEXTCOLOR,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        PM_REMOVE, PeekMessageW, SIF_POS, SMTO_ABORTIFHUNG, SMTO_BLOCK, SendMessageTimeoutW,
        WM_APP, WM_NULL, WM_QUIT,
    };

    const TEST_LIST_BACKGROUND_COLORREF: u32 = 0x001c_1917;

    fn registered_test_zone(key: &str) -> io::Result<DYNAMIC_TIME_ZONE_INFORMATION> {
        let expected = wide(key);
        let expected = &expected[..expected.len() - 1];
        for index in 0..1024 {
            let mut zone = DYNAMIC_TIME_ZONE_INFORMATION::default();
            // SAFETY: zone is writable for this synchronous registry enumeration.
            match unsafe { EnumDynamicTimeZoneInformation(index, &mut zone) } {
                ERROR_SUCCESS => {
                    let end = zone
                        .TimeZoneKeyName
                        .iter()
                        .position(|unit| *unit == 0)
                        .unwrap_or(zone.TimeZoneKeyName.len());
                    if &zone.TimeZoneKeyName[..end] == expected {
                        return Ok(zone);
                    }
                }
                ERROR_NO_MORE_ITEMS => break,
                error => return Err(io::Error::from_raw_os_error(error as i32)),
            }
        }
        Err(io::Error::other(format!(
            "test time zone {key} is unavailable"
        )))
    }

    #[test]
    fn failed_shell_lookup_caches_no_image_instead_of_unvalidated_index() {
        let mut cache = HashMap::new();
        let item = LegacyListItem::new("one.TXT", false, 0, 0, 0);
        assert_eq!(
            cached_file_icon_index(&mut cache, &item, |_, _| (0, 42)),
            I_IMAGENONE
        );
        let same_class = LegacyListItem::new("two.txt", false, 0, 0, 0);
        let mut queries = 0;
        assert_eq!(
            cached_file_icon_index(&mut cache, &same_class, |_, _| {
                queries += 1;
                (1, 42)
            }),
            I_IMAGENONE
        );
        assert_eq!(queries, 0);
    }

    #[test]
    fn shell_lookup_rejects_callback_index_but_accepts_image_zero() {
        let item = LegacyListItem::new("one.txt", false, 0, 0, 0);
        for index in [-1, -2, i32::MIN] {
            assert_eq!(
                cached_file_icon_index(&mut HashMap::new(), &item, |_, _| (1, index)),
                I_IMAGENONE
            );
        }
        let mut cache = HashMap::new();
        assert_eq!(cached_file_icon_index(&mut cache, &item, |_, _| (1, 0)), 0);
        let mut queries = 0;
        assert_eq!(
            cached_file_icon_index(&mut cache, &item, |_, _| {
                queries += 1;
                (1, 42)
            }),
            0
        );
        assert_eq!(queries, 0);
    }

    #[test]
    fn shell_icon_cache_queries_exact_classes_across_two_clear_boundaries() {
        let hot = icon_cache_key(&LegacyText::from("one.TXT"), false);
        let failed = icon_cache_key(&LegacyText::from("one.BAD"), false);
        let zero = icon_cache_key(&LegacyText::from("one.ZERO"), false);
        let mut expected_queries = vec![hot.clone(), failed.clone(), zero.clone()];
        expected_queries.extend(
            (0..253).map(|index| icon_cache_key(&LegacyText::from(format!("f.x{index}")), false)),
        );
        expected_queries.push(icon_cache_key(&LegacyText::from("f.x253"), false));
        expected_queries.extend([hot.clone(), failed.clone(), zero.clone()]);
        expected_queries.extend(
            (254..506).map(|index| icon_cache_key(&LegacyText::from(format!("f.x{index}")), false)),
        );
        expected_queries.push(icon_cache_key(&LegacyText::from("f.x506"), false));
        expected_queries.extend([hot.clone(), failed.clone(), zero.clone()]);

        let mut cache = HashMap::new();
        let mut actual_queries = Vec::new();
        let mut accesses = 0;
        {
            let mut visit = |name: &str, expected_index: i32, should_query: bool| {
                let item = LegacyListItem::new(name, false, 0, 0, 0);
                let before = actual_queries.len();
                let index = cached_file_icon_index(&mut cache, &item, |key, is_directory| {
                    assert!(!is_directory);
                    actual_queries.push(key.clone());
                    if *key == failed {
                        (0, 42)
                    } else if *key == zero {
                        (1, 0)
                    } else if *key == hot {
                        (1, 17)
                    } else {
                        (1, 31)
                    }
                });
                accesses += 1;
                assert_eq!(index, expected_index, "access {accesses}: {name}");
                assert_eq!(
                    actual_queries.len(),
                    before + usize::from(should_query),
                    "access {accesses}: {name}"
                );
                assert!(cache.len() <= 256, "access {accesses}: {name}");
                cache.len()
            };

            assert_eq!(visit("one.TXT", 17, true), 1);
            assert_eq!(visit("one.BAD", I_IMAGENONE, true), 2);
            assert_eq!(visit("one.ZERO", 0, true), 3);
            for index in 0..253 {
                visit(&format!("f.x{index}"), 31, true);
            }
            for (name, expected) in [("two.txt", 17), ("two.bad", I_IMAGENONE), ("two.zero", 0)] {
                assert_eq!(visit(name, expected, false), 256);
            }
            assert_eq!(visit("f.x253", 31, true), 1);
            for (name, expected) in [
                ("three.TXT", 17),
                ("three.BAD", I_IMAGENONE),
                ("three.ZERO", 0),
            ] {
                visit(name, expected, true);
            }
            for index in 254..506 {
                visit(&format!("f.x{index}"), 31, true);
            }
            for (name, expected) in [
                ("four.txt", 17),
                ("four.bad", I_IMAGENONE),
                ("four.zero", 0),
            ] {
                assert_eq!(visit(name, expected, false), 256);
            }
            assert_eq!(visit("f.x506", 31, true), 1);
            for (name, expected) in [
                ("five.TXT", 17),
                ("five.BAD", I_IMAGENONE),
                ("five.ZERO", 0),
            ] {
                visit(name, expected, true);
            }
        }
        assert_eq!(accesses, 522);
        assert_eq!(actual_queries.len(), 516);
        assert_eq!(actual_queries, expected_queries);
        for key in [hot, failed, zero] {
            assert_eq!(
                actual_queries.iter().filter(|query| *query == &key).count(),
                3
            );
        }
        assert_eq!(
            cache.get(&icon_cache_key(&LegacyText::from("six.bad"), false)),
            Some(&I_IMAGENONE)
        );
    }

    struct RefreshTestOle {
        winrt: Option<WinRtGuard>,
    }

    impl RefreshTestOle {
        fn initialize() -> io::Result<Self> {
            // SAFETY: null is reserved; Drop balances successful OLE setup on
            // this native-test thread.
            if unsafe { OleInitialize(null()) } < 0 {
                return Err(io::Error::other("refresh test COM initialization failed"));
            }
            let mut apartment = Self { winrt: None };
            apartment.winrt = WinRtGuard::initialize();
            if apartment.winrt.is_none() {
                return Err(io::Error::other("refresh test WinRT initialization failed"));
            }
            Ok(apartment)
        }
    }

    impl Drop for RefreshTestOle {
        fn drop(&mut self) {
            drop(self.winrt.take());
            // SAFETY: OLE initialization succeeded on this same test thread.
            unsafe { OleUninitialize() };
        }
    }

    // The native fixture publishes the ordinary callback lease and owns all
    // children. Timing uses only safe Rust; these calls create/retire the HWNDs.
    struct RefreshTestApp {
        owner: HWND,
        slot: *mut AppStateSlot,
        _directory: tempfile::TempDir,
    }

    impl RefreshTestApp {
        fn new() -> Result<Self, Box<dyn std::error::Error>> {
            let directory = tempfile::tempdir()?;
            let state = AppState::new(initialize_safe_runtime_at(directory.path())?);
            let controls = INITCOMMONCONTROLSEX {
                dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
                dwICC: ICC_LISTVIEW_CLASSES | ICC_WIN95_CLASSES,
            };
            // SAFETY: controls has the exact ABI size and outlives initialization.
            unsafe { InitCommonControlsEx(&controls) };
            let class = wide("STATIC");
            // SAFETY: the system class/current module and null creation data are
            // valid; this UI thread owns the resulting hidden parent window.
            let owner = unsafe {
                CreateWindowExW(
                    0,
                    class.as_ptr(),
                    null(),
                    WS_OVERLAPPEDWINDOW,
                    0,
                    0,
                    1366,
                    768,
                    null_mut(),
                    null_mut(),
                    GetModuleHandleW(null()),
                    null_mut(),
                )
            };
            if owner.is_null() {
                return Err(io::Error::last_os_error().into());
            }
            let slot = CallbackState::into_raw(state);
            // SAFETY: owner and slot remain owned until close unpublishes them.
            unsafe { SetWindowLongPtrW(owner, GWLP_USERDATA, slot as isize) };
            let app = Self {
                owner,
                slot,
                _directory: directory,
            };
            app.with_state(|state| create_children(owner, state))??;
            Ok(app)
        }

        fn with_state<R>(&self, action: impl FnOnce(&mut AppState) -> R) -> io::Result<R> {
            // SAFETY: this test owns the published slot; leases end before this
            // function returns and cannot escape into native callbacks.
            let mut lease = unsafe { CallbackState::try_lease(self.slot) }
                .ok_or_else(|| io::Error::other("refresh test lease is unavailable"))?;
            Ok(action(lease.state_mut()))
        }

        fn attach_test_image_list(
            &self,
            image_list: icon_worker::BorrowedSystemImageList,
        ) -> io::Result<()> {
            self.with_state(|state| {
                // SAFETY: the test owns this live ListView. Both calls carry
                // only scalar image-list identities; the separate owner
                // outlives the ListView's confirmed destruction.
                let existing = unsafe {
                    SendMessageW(state.list_window, LVM_GETIMAGELIST, LVSIL_SMALL as usize, 0)
                };
                if existing != 0 {
                    return Err(io::Error::other(
                        "refresh test ListView already has an image list",
                    ));
                }
                // SAFETY: LVS_SHAREIMAGELISTS keeps ownership with this test;
                // the borrowed scalar remains live until parent destruction.
                unsafe {
                    SendMessageW(
                        state.list_window,
                        LVM_SETIMAGELIST,
                        LVSIL_SMALL as usize,
                        image_list.raw(),
                    )
                };
                // SAFETY: scalar readback on the same live ListView.
                let attached = unsafe {
                    SendMessageW(state.list_window, LVM_GETIMAGELIST, LVSIL_SMALL as usize, 0)
                };
                if attached != image_list.raw() {
                    return Err(io::Error::other("refresh test image list was not attached"));
                }
                state.icon_image_list = Some(image_list);
                Ok(())
            })?
        }

        fn close(&mut self) -> io::Result<()> {
            if self.owner.is_null() {
                return Ok(());
            }
            self.with_state(|state| {
                remove_list_view_notification_subclass(state.list_window);
                if let Some(rail) = state.left_rail.take() {
                    rail.destroy();
                }
                if let Some(rail) = state.right_rail.take() {
                    rail.destroy();
                }
            })?;
            // SAFETY: no lease remains. Remove publication before synchronous
            // child destruction, then reclaim only after confirmed destruction.
            let destroyed = unsafe {
                SetWindowLongPtrW(self.owner, GWLP_USERDATA, 0);
                DestroyWindow(self.owner)
            };
            if destroyed == 0 {
                return Err(io::Error::last_os_error());
            }
            discard_deferred_messages(self.owner);
            self.owner = null_mut();
            // SAFETY: no lease/publication or child HWND remains for this slot.
            let reclaimed = unsafe { CallbackState::request_reclaim(self.slot) };
            if reclaimed != ReclaimDisposition::Reclaimed {
                return Err(io::Error::other("refresh test state was not reclaimed"));
            }
            Ok(())
        }
    }

    impl Drop for RefreshTestApp {
        fn drop(&mut self) {
            // A controlled image list may still be attached. Do not let its
            // outer owner drop after uncertain native window destruction.
            if let Err(error) = self.close() {
                eprintln!("refresh test native teardown failed: {error}");
                std::process::abort();
            }
        }
    }

    #[derive(Clone)]
    struct IconTestGate(Arc<(Mutex<bool>, Condvar)>);

    impl IconTestGate {
        fn held() -> Self {
            Self(Arc::new((Mutex::new(false), Condvar::new())))
        }

        fn wait(&self) {
            let (locked, ready) = &*self.0;
            let mut released = locked.lock().unwrap_or_else(|error| error.into_inner());
            while !*released {
                released = ready
                    .wait(released)
                    .unwrap_or_else(|error| error.into_inner());
            }
        }

        fn release(&self) {
            let (locked, ready) = &*self.0;
            *locked.lock().unwrap_or_else(|error| error.into_inner()) = true;
            ready.notify_all();
        }
    }

    struct ReleaseIconGate(IconTestGate);

    impl Drop for ReleaseIconGate {
        fn drop(&mut self) {
            self.0.release();
        }
    }

    fn with_icon_native_window(
        action: impl FnOnce(HWND, icon_worker::BorrowedSystemImageList) -> io::Result<()>,
    ) -> io::Result<()> {
        struct TestOle;
        impl Drop for TestOle {
            fn drop(&mut self) {
                // SAFETY: this same test thread balances its successful OLE init.
                unsafe { OleUninitialize() };
            }
        }
        // SAFETY: null is the reserved argument; TestOle balances success.
        if unsafe { OleInitialize(null()) } < 0 {
            return Err(io::Error::other("icon test OLE initialization failed"));
        }
        let _ole = TestOle;
        let _winrt = WinRtGuard::initialize()
            .ok_or_else(|| io::Error::other("icon test WinRT initialization failed"))?;
        // This owner is outside the popup action: its native list survives
        // normal return, errors, and unwinding until the popup guard has
        // destroyed every attached child and each local guardian has joined.
        let image_list = icon_worker::OwnedTestImageList::new()?;
        let root = tempfile::tempdir()?;
        application::with_production_popup_window_for_test(root.path(), false, |window| {
            action(window, image_list.borrowed())
        })
    }

    fn install_icon_test_guardian(
        window: HWND,
        guardian: &icon_worker::IconRunGuardian,
    ) -> io::Result<()> {
        let slot = app_state_slot(window);
        // SAFETY: the production test window still publishes the exact slot;
        // this separate sidecar remains live through its run-scope test hold.
        if !unsafe { CallbackState::install_icon_retirement(slot, Arc::clone(&guardian.shared)) } {
            return Err(io::Error::other("icon test sidecar installation failed"));
        }
        let Some(mut lease) = try_app_state(window) else {
            return Err(io::Error::other("icon test AppState lease unavailable"));
        };
        lease.state_mut().icon_shared = Some(Arc::clone(&guardian.shared));
        schedule_icon_poll(lease.state());
        Ok(())
    }

    fn pump_icon_test_until(
        window: HWND,
        timeout: Duration,
        mut condition: impl FnMut() -> bool,
    ) -> io::Result<()> {
        let deadline = Instant::now() + timeout;
        let mut message = MSG::default();
        loop {
            if condition() && Instant::now() < deadline {
                return Ok(());
            }
            // SAFETY: this test owns the UI thread queue and writable MSG.
            while unsafe { PeekMessageW(&mut message, null_mut(), 0, 0, PM_REMOVE) } != 0 {
                if message.hwnd.is_null() && message.message == WM_APP_ICON_WAKE {
                    // Production run handles this thread wake outside
                    // DispatchMessageW. Mirror that path on the test UI thread.
                    if let Some(mut lease) = try_app_state(window) {
                        poll_icon_work(lease.state_mut());
                    }
                } else if message.message != WM_QUIT {
                    // SAFETY: the copied OS message remains live for dispatch.
                    unsafe {
                        TranslateMessage(&message);
                        DispatchMessageW(&message);
                    }
                }
            }
            // A completion dispatched above counts only when observed before
            // the deadline; do not wait for another loop or accept a late ACK.
            if condition() && Instant::now() < deadline {
                return Ok(());
            }
            if Instant::now() >= deadline {
                let progress = try_app_state(window).map(|lease| {
                    let state = lease.state();
                    let pending = state
                        .icon_shared
                        .as_ref()
                        .map_or(0, |shared| shared.pending_count());
                    let unavailable = state
                        .icon_shared
                        .as_ref()
                        .is_none_or(|shared| shared.is_unavailable());
                    format!(
                        "rows={} image_list={} unavailable={} unresolved={} pending={} reconcile={} batch={} demand={} cursor={}",
                        state.rendered_rows.len(),
                        state.icon_image_list.is_some(),
                        unavailable,
                        state.icon_unresolved_rows,
                        pending,
                        state.icon_reconcile_remaining,
                        state.icon_delivery_ack_count,
                        state.icon_demand_scan_remaining,
                        state.icon_scan_cursor,
                    )
                });
                return Err(io::Error::other(format!(
                    "icon test observer deadline expired: {}",
                    progress.as_deref().unwrap_or("owner unavailable")
                )));
            }
            thread::sleep(Duration::from_millis(5));
        }
    }

    const ICON_TEST_ACK_MESSAGE: u32 = WM_APP + 0x60;
    const ICON_TEST_ACK_SUBCLASS: usize = 0xD4B0;
    const ICON_TEST_DESTROY_SUBCLASS: usize = 0xD4B1;
    const ICON_TEST_CLOSE_JOIN_SUBCLASS: usize = 0xD4B2;
    thread_local! {
        static ICON_TEST_ACKED: Cell<bool> = const { Cell::new(false) };
        static ICON_TEST_DESTROY_BUSY: Cell<bool> = const { Cell::new(false) };
    }

    unsafe extern "system" fn icon_test_ack_subclass(
        window: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        _subclass_id: usize,
        _ref_data: usize,
    ) -> LRESULT {
        if message == ICON_TEST_ACK_MESSAGE {
            ICON_TEST_ACKED.with(|observed| observed.set(true));
            return 1;
        }
        if message == WM_NCDESTROY {
            // SAFETY: this exact test-owned subclass is removed before the
            // production owner finishes its terminal callback.
            unsafe {
                RemoveWindowSubclass(window, Some(icon_test_ack_subclass), ICON_TEST_ACK_SUBCLASS)
            };
        }
        // SAFETY: every other message retains the native subclass chain.
        unsafe { DefSubclassProc(window, message, wparam, lparam) }
    }

    unsafe extern "system" fn icon_test_destroy_on_icon_subclass(
        window: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        _subclass_id: usize,
        ref_data: usize,
    ) -> LRESULT {
        if message == LVM_SETITEMW {
            let owner = ref_data as HWND;
            ICON_TEST_DESTROY_BUSY.with(|observed| observed.set(app_callback_is_busy(owner)));
            // SAFETY: the test registered this subclass on the live child;
            // destroying its exact owner synchronously exercises nested
            // WM_DESTROY/WM_NCDESTROY during the parent's AppState lease.
            unsafe { DestroyWindow(owner) };
            return 0;
        }
        if message == WM_NCDESTROY {
            // SAFETY: this exact test subclass is removed as the child dies.
            unsafe {
                RemoveWindowSubclass(
                    window,
                    Some(icon_test_destroy_on_icon_subclass),
                    ICON_TEST_DESTROY_SUBCLASS,
                )
            };
        }
        // SAFETY: every other message retains the native subclass chain.
        unsafe { DefSubclassProc(window, message, wparam, lparam) }
    }

    struct IconCloseJoinObservation {
        shared: Arc<IconShared>,
        saw_destroy: AtomicBool,
        joined_at_destroy: AtomicBool,
        detached_at_nc_destroy: AtomicBool,
    }

    struct IconCloseJoinSubclass {
        window: HWND,
        observation: Option<Box<IconCloseJoinObservation>>,
    }

    impl IconCloseJoinSubclass {
        fn install(window: HWND, shared: Arc<IconShared>) -> io::Result<Self> {
            let observation = Box::new(IconCloseJoinObservation {
                shared,
                saw_destroy: AtomicBool::new(false),
                joined_at_destroy: AtomicBool::new(false),
                detached_at_nc_destroy: AtomicBool::new(false),
            });
            // SAFETY: this UI thread owns the live window. The guard owns the
            // stable allocation published as refdata until confirmed removal
            // or window destruction.
            if unsafe {
                SetWindowSubclass(
                    window,
                    Some(icon_test_close_join_subclass),
                    ICON_TEST_CLOSE_JOIN_SUBCLASS,
                    (&*observation as *const IconCloseJoinObservation) as usize,
                )
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(Self {
                window,
                observation: Some(observation),
            })
        }

        fn observation(&self) -> &IconCloseJoinObservation {
            self.observation
                .as_deref()
                .expect("installed close-join observation")
        }
    }

    impl Drop for IconCloseJoinSubclass {
        fn drop(&mut self) {
            let Some(observation) = self.observation.take() else {
                return;
            };
            // SAFETY: this test's UI thread is the only callback dispatcher.
            // A live window can still retain refdata on an early return.
            if unsafe { IsWindow(self.window) } != 0 {
                let removed = unsafe {
                    RemoveWindowSubclass(
                        self.window,
                        Some(icon_test_close_join_subclass),
                        ICON_TEST_CLOSE_JOIN_SUBCLASS,
                    )
                };
                if removed == 0 {
                    // Native detach is uncertain. Retain at most this one
                    // inert test context instead of freeing reachable refdata.
                    eprintln!("close-join test subclass detach failed; retaining observation");
                    Box::leak(observation);
                }
            }
        }
    }

    unsafe extern "system" fn icon_test_close_join_subclass(
        window: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        _subclass_id: usize,
        ref_data: usize,
    ) -> LRESULT {
        if message == WM_DESTROY {
            // SAFETY: IconCloseJoinSubclass removes this callback before the
            // boxed observation is dropped, including every error path.
            let observation = unsafe { &*(ref_data as *const IconCloseJoinObservation) };
            observation
                .joined_at_destroy
                .store(observation.shared.is_joined(), Ordering::Release);
            observation.saw_destroy.store(true, Ordering::Release);
        }
        if message == WM_NCDESTROY {
            // SAFETY: the guard still owns this boxed refdata until callback
            // completion; record whether exact native removal succeeded.
            let observation = unsafe { &*(ref_data as *const IconCloseJoinObservation) };
            let removed = unsafe {
                RemoveWindowSubclass(
                    window,
                    Some(icon_test_close_join_subclass),
                    ICON_TEST_CLOSE_JOIN_SUBCLASS,
                )
            };
            observation
                .detached_at_nc_destroy
                .store(removed != 0, Ordering::Release);
        }
        // SAFETY: all other messages keep the native subclass chain.
        unsafe { DefSubclassProc(window, message, wparam, lparam) }
    }

    fn assert_ui_ack_while_icon_blocked(window: HWND) -> io::Result<()> {
        ICON_TEST_ACKED.with(|observed| observed.set(false));
        // SAFETY: the production owner is live; this callback carries no
        // context pointer and is removed below or by WM_NCDESTROY.
        if unsafe {
            SetWindowSubclass(
                window,
                Some(icon_test_ack_subclass),
                ICON_TEST_ACK_SUBCLASS,
                0,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: this test-owned live HWND receives a pointer-free posted
        // message; the subclass records actual queued dispatch.
        let posted = unsafe { PostMessageW(window, ICON_TEST_ACK_MESSAGE, 0, 0) } != 0;
        let observed = if posted {
            pump_icon_test_until(window, Duration::from_secs(1), || {
                ICON_TEST_ACKED.with(Cell::get)
            })
        } else {
            Err(io::Error::last_os_error())
        };
        // SAFETY: this exact subclass is still installed on the live owner;
        // if it was already removed during destruction, WM_NCDESTROY owned it.
        let removed = unsafe {
            RemoveWindowSubclass(window, Some(icon_test_ack_subclass), ICON_TEST_ACK_SUBCLASS)
        };
        observed?;
        if removed == 0 {
            return Err(io::Error::other("icon test ack subclass did not retire"));
        }
        Ok(())
    }

    fn icon_view_state(
        owner: HWND,
        list: HWND,
    ) -> io::Result<(Vec<usize>, bool, isize, i32, isize, ResolvedTheme)> {
        let mut horizontal = SCROLLINFO {
            cbSize: size_of::<SCROLLINFO>() as u32,
            fMask: SIF_POS,
            ..SCROLLINFO::default()
        };
        // SAFETY: the test owns this live ListView and exact writable ABI
        // storage for its scalar horizontal scroll position.
        if unsafe { GetScrollInfo(list, SB_HORZ, &mut horizontal) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let theme = try_app_state(owner)
            .ok_or_else(|| io::Error::other("icon view state unavailable"))?
            .state()
            .resolved_appearance()
            .theme;
        // SAFETY: these are synchronous scalar queries on the live test list.
        let (focused, top, background) = unsafe {
            (
                SendMessageW(list, LVM_GETITEMSTATE, 501, LVIS_FOCUSED as isize),
                SendMessageW(list, LVM_GETTOPINDEX, 0, 0),
                SendMessageW(list, LVM_GETBKCOLOR, 0, 0),
            )
        };
        Ok((
            selected_indices(list),
            focused & LVIS_FOCUSED as isize != 0,
            top,
            horizontal.nPos,
            background,
            theme,
        ))
    }

    #[test]
    fn icon_worker_bootstrap_and_miss_keep_ui_responsive() -> io::Result<()> {
        with_icon_native_window(|window, image_list| {
            let slot = app_state_slot(window);
            // SAFETY: this live production test slot remains held until the
            // worker reaches terminal join, including forced HWND destruction.
            let _hold = unsafe { CallbackReclaimHold::new(slot) }
                .ok_or_else(|| io::Error::other("icon test reclaim hold failed"))?;
            let bootstrap_gate = IconTestGate::held();
            let worker_bootstrap_gate = bootstrap_gate.clone();
            let miss_gate = IconTestGate::held();
            let worker_miss_gate = miss_gate.clone();
            let miss_entered = Arc::new(AtomicBool::new(false));
            let worker_miss_entered = Arc::clone(&miss_entered);
            let (entered_tx, entered_rx) = mpsc::sync_channel(1);
            let mut guardian = icon_worker::IconRunGuardian::start_with(
                // SAFETY: this scalar identifies the UI thread owning the test.
                unsafe { windows_sys::Win32::System::Threading::GetCurrentThreadId() },
                move || {
                    let lookup = icon_worker::ControlledIconLookup::initialize(image_list)?;
                    Some(
                        move |key: &crate::icon_requests::RequestKey<IconCacheKey>| {
                            if matches!(key, crate::icon_requests::RequestKey::Bootstrap) {
                                let _ = entered_tx.send(());
                                worker_bootstrap_gate.wait();
                            } else {
                                worker_miss_entered.store(true, Ordering::Release);
                                worker_miss_gate.wait();
                            }
                            lookup.query(key)
                        },
                    )
                },
            )?;
            let _release_bootstrap = ReleaseIconGate(bootstrap_gate.clone());
            let _release_miss = ReleaseIconGate(miss_gate.clone());
            install_icon_test_guardian(window, &guardian)?;
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("icon test state unavailable"))?;
                let state = lease.state_mut();
                state
                    .model
                    .append_batch_by(
                        refresh_fixture_rows(r"C:\icon-test", "held", 0, 2),
                        compare_windows,
                    )
                    .map_err(|error| io::Error::other(error.to_string()))?;
                refresh_all_rows(state);
                assert_eq!(state.rendered_rows.len(), 2);
                assert!(
                    state
                        .rendered_rows
                        .iter()
                        .all(|row| row.icon == I_IMAGENONE)
                );
                assert!(state.rendered_rows.iter().all(|row| !row.icon_resolved));
                assert_native_refresh_values(state);
            }
            entered_rx
                .recv_timeout(Duration::from_secs(2))
                .map_err(|_| io::Error::other("bootstrap did not enter the worker"))?;
            assert_ui_ack_while_icon_blocked(window)?;
            bootstrap_gate.release();
            pump_icon_test_until(window, Duration::from_secs(5), || {
                miss_entered.load(Ordering::Acquire)
            })
            .map_err(|error| {
                io::Error::other(format!(
                    "bootstrap-to-miss wait: {error}; miss_entered={}",
                    miss_entered.load(Ordering::Acquire)
                ))
            })?;
            assert_ui_ack_while_icon_blocked(window)?;
            guardian.shared.lose_next_ui_wake_for_test();
            miss_gate.release();
            pump_icon_test_until(window, Duration::from_secs(10), || {
                try_app_state(window).is_some_and(|lease| {
                    lease.state().icon_image_list.is_some()
                        && lease.state().icon_unresolved_rows == 0
                        && guardian.shared.pending_count() == 0
                })
            })
            .map_err(|error| {
                io::Error::other(format!(
                    "miss-to-settlement wait: {error}; miss_entered={}",
                    miss_entered.load(Ordering::Acquire)
                ))
            })?;
            assert!(!guardian.shared.test_ui_wake_loss_pending());
            let lease = try_app_state(window)
                .ok_or_else(|| io::Error::other("icon test state disappeared"))?;
            assert_native_refresh_values(lease.state());
            drop(lease);
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("icon test state unavailable"))?;
                let state = lease.state_mut();
                assert!(state.model.move_rows_earlier_changed(&[1]).changed());
                refresh_all_rows(state);
                assert_native_refresh_values(state);
                assert!(state.model.clear());
                refresh_all_rows(state);
                assert_eq!(state.rendered_rows.len(), 0);
                // SAFETY: this scalar count queries the live test ListView.
                assert_eq!(
                    // SAFETY: the live test-owned ListView receives only
                    // scalar parameters and returns its item count.
                    unsafe { SendMessageW(state.list_window, LVM_GETITEMCOUNT, 0, 0) },
                    0
                );
                state
                    .model
                    .append_batch_by(
                        [
                            LegacyListItem::new(r"C:\icon-test\fresh.alpha", false, 0, 0, 0),
                            LegacyListItem::new(r"C:\icon-test\fresh.beta", false, 0, 0, 0),
                        ],
                        compare_windows,
                    )
                    .map_err(|error| io::Error::other(error.to_string()))?;
                refresh_all_rows(state);
                assert_native_refresh_values(state);
                assert_eq!(state.model.remove_rows(&[0]), 1);
                assert_eq!(
                    state.model.append(LegacyListItem::new(
                        r"C:\icon-test\renamed.gamma",
                        false,
                        0,
                        0,
                        0,
                    )),
                    Ok(true)
                );
                refresh_all_rows(state);
                assert_native_refresh_values(state);
            }
            pump_icon_test_until(window, Duration::from_secs(10), || {
                try_app_state(window).is_some_and(|lease| {
                    lease.state().icon_unresolved_rows == 0 && guardian.shared.pending_count() == 0
                })
            })?;
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("icon test state unavailable"))?;
                let state = lease.state_mut();
                assert_eq!(
                    state.model.append(LegacyListItem::new(
                        r"C:\icon-test\native-fault.fault",
                        false,
                        0,
                        0,
                        0,
                    )),
                    Ok(true)
                );
                state
                    .model
                    .prefix_complete(&LegacyText::from("test-"))
                    .map_err(|error| io::Error::other(error.to_string()))?;
                refresh_all_rows(state);
                assert_eq!(state.icon_unresolved_rows, 1);
                assert_eq!(state.presentation(0).apply, crate::ApplyPresentation::Ready);
                ICON_TEST_NATIVE_FAILURE_APPLY_BLOCKED.with(|observed| observed.set(false));
                ICON_TEST_FAIL_NEXT_NATIVE_SET.with(|failure| failure.set(true));
            }
            pump_icon_test_until(window, Duration::from_secs(10), || {
                try_app_state(window).is_some_and(|lease| {
                    lease.state().preview_synchronization.is_synchronized()
                        && lease.state().icon_unresolved_rows == 0
                        && guardian.shared.pending_count() == 0
                })
            })?;
            assert!(!ICON_TEST_FAIL_NEXT_NATIVE_SET.with(Cell::get));
            assert!(ICON_TEST_NATIVE_FAILURE_APPLY_BLOCKED.with(Cell::get));
            {
                let lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("icon test state disappeared"))?;
                assert_native_refresh_values(lease.state());
            }
            // SAFETY: this exact live production owner handles the ordinary
            // close message after the AppState lease has ended.
            unsafe { SendMessageW(window, WM_CLOSE, 0, 0) };
            pump_icon_test_until(window, Duration::from_secs(10), || {
                guardian.poll_join();
                // SAFETY: this scalar liveness query does not borrow AppState.
                unsafe { IsWindow(window) == 0 }
            })?;
            assert!(guardian.shared.is_joined());
            Ok(())
        })
    }

    #[test]
    fn icon_worker_bounds_eviction_and_stale_results() -> io::Result<()> {
        with_icon_native_window(|window, image_list| {
            let slot = app_state_slot(window);
            // SAFETY: this held production slot outlives the worker's actual
            // terminal join, even if native teardown reenters during the test.
            let _hold = unsafe { CallbackReclaimHold::new(slot) }
                .ok_or_else(|| io::Error::other("icon test reclaim hold failed"))?;
            let gate = IconTestGate::held();
            let worker_gate = gate.clone();
            let stale_gate = IconTestGate::held();
            let worker_stale_gate = stale_gate.clone();
            let stale_entered = Arc::new(AtomicBool::new(false));
            let worker_stale_entered = Arc::clone(&stale_entered);
            let (entered_tx, entered_rx) = mpsc::sync_channel(1);
            let calls = Arc::new(AtomicUsize::new(0));
            let worker_calls = Arc::clone(&calls);
            let bad_calls = Arc::new(AtomicUsize::new(0));
            let worker_bad_calls = Arc::clone(&bad_calls);
            let mut guardian = icon_worker::IconRunGuardian::start_with(
                // SAFETY: this scalar identifies the UI thread owning the test.
                unsafe { windows_sys::Win32::System::Threading::GetCurrentThreadId() },
                move || {
                    let lookup = icon_worker::ControlledIconLookup::initialize(image_list)?;
                    let mut first_class = true;
                    Some(
                        move |key: &crate::icon_requests::RequestKey<IconCacheKey>| match key {
                            crate::icon_requests::RequestKey::Bootstrap => lookup.query(key),
                            crate::icon_requests::RequestKey::Class(class) => {
                                let stale = *class
                                    == icon_cache_key(&LegacyText::from("zzzzzz.xstale"), false);
                                if stale {
                                    worker_stale_entered.store(true, Ordering::Release);
                                    worker_stale_gate.wait();
                                }
                                if first_class {
                                    first_class = false;
                                    let _ = entered_tx.send(());
                                    worker_gate.wait();
                                }
                                worker_calls.fetch_add(1, Ordering::AcqRel);
                                let bad =
                                    *class == icon_cache_key(&LegacyText::from("case.BAD"), false);
                                if bad {
                                    worker_bad_calls.fetch_add(1, Ordering::AcqRel);
                                }
                                icon_worker::IconResult::Class {
                                    list: Some(lookup.image_list()),
                                    index: if bad {
                                        I_IMAGENONE
                                    } else if stale {
                                        1
                                    } else {
                                        0
                                    },
                                }
                            }
                        },
                    )
                },
            )?;
            let _release = ReleaseIconGate(gate.clone());
            let _release_stale = ReleaseIconGate(stale_gate.clone());
            install_icon_test_guardian(window, &guardian)?;
            pump_icon_test_until(window, Duration::from_secs(5), || {
                try_app_state(window).is_some_and(|lease| lease.state().icon_image_list.is_some())
            })?;
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("icon test state unavailable"))?;
                let state = lease.state_mut();
                let mut rows = (0..10_000)
                    .map(|index| {
                        LegacyListItem::new_with_actual_size(
                            format!(r"C:\icon-test\file-{index}.x{index}"),
                            false,
                            24,
                            24,
                            0,
                            0,
                        )
                    })
                    .collect::<Vec<_>>();
                rows.push(LegacyListItem::new(
                    r"C:\icon-test\case.BAD",
                    false,
                    0,
                    0,
                    0,
                ));
                rows.push(LegacyListItem::new(
                    r"C:\icon-test\case.bad",
                    false,
                    0,
                    0,
                    0,
                ));
                state
                    .model
                    .append_batch_by(rows, compare_windows)
                    .map_err(|error| io::Error::other(error.to_string()))?;
                refresh_all_rows(state);
                assert_eq!(state.icon_unresolved_rows, 10_002);
                assert!(state.icon_cache.len() <= 256);
                assert_eq!(state.rendered_rows[0].icon, I_IMAGENONE);
            }
            entered_rx
                .recv_timeout(Duration::from_secs(2))
                .map_err(|_| io::Error::other("class query did not enter the worker"))?;
            assert_eq!(guardian.shared.pending_count(), 64);
            assert_ui_ack_while_icon_blocked(window)?;
            let list = try_app_state(window)
                .ok_or_else(|| io::Error::other("icon test state unavailable"))?
                .state()
                .list_window;
            select_rows(list, &[500]);
            let mut focus = LVITEMW {
                stateMask: LVIS_FOCUSED,
                state: LVIS_FOCUSED,
                ..LVITEMW::default()
            };
            // SAFETY: the live ListView receives one writable state item;
            // focus on row 501 deliberately remains outside selection.
            assert_ne!(
                // SAFETY: focus storage remains live through this synchronous
                // native state change on the test-owned ListView.
                unsafe {
                    SendMessageW(
                        list,
                        LVM_SETITEMSTATE,
                        501,
                        (&mut focus as *mut LVITEMW) as isize,
                    )
                },
                0
            );
            // SAFETY: these scalar operations create nonzero horizontal and
            // vertical viewport positions before icon-only reconciliation.
            unsafe {
                SendMessageW(list, LVM_SETCOLUMNWIDTH, 0, 900);
                SendMessageW(list, LVM_SCROLL, 160, 0);
                SendMessageW(list, LVM_ENSUREVISIBLE, 5000, 0);
            }
            let view_before = icon_view_state(window, list)?;
            assert_eq!(view_before.0, vec![500]);
            assert!(view_before.1, "unselected row did not retain focus");
            assert!(view_before.2 > 0, "vertical viewport did not move");
            assert!(view_before.3 > 0, "horizontal viewport did not move");
            gate.release();
            pump_icon_test_until(window, Duration::from_secs(45), || {
                try_app_state(window).is_some_and(|lease| {
                    lease.state().icon_unresolved_rows == 0 && guardian.shared.pending_count() == 0
                })
            })?;
            let lease = try_app_state(window)
                .ok_or_else(|| io::Error::other("icon test state disappeared"))?;
            let state = lease.state();
            assert_eq!(state.rendered_rows.len(), 10_002);
            assert!(state.rendered_rows.iter().all(|row| row.icon_resolved));
            assert!(state.icon_cache.len() <= 256);
            assert_eq!(calls.load(Ordering::Acquire), 10_001);
            assert_eq!(bad_calls.load(Ordering::Acquire), 1);
            let bad_key = icon_cache_key(&LegacyText::from("case.BAD"), false);
            let mut no_image_rows = 0;
            for (item, row) in state.model.items().iter().zip(&state.rendered_rows) {
                let expected =
                    if icon_cache_key(item.current_name(), item.is_directory()) == bad_key {
                        no_image_rows += 1;
                        I_IMAGENONE
                    } else {
                        0
                    };
                assert_eq!(row.icon, expected, "{}", item.current_name());
            }
            assert_eq!(no_image_rows, 2);
            assert_native_refresh_values(state);
            drop(lease);
            assert_eq!(icon_view_state(window, list)?, view_before);
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("icon test state unavailable"))?;
                let state = lease.state_mut();
                assert_eq!(
                    state.model.append(LegacyListItem::new(
                        r"C:\icon-test\zzzzzz.xstale",
                        false,
                        0,
                        0,
                        0,
                    )),
                    Ok(true)
                );
                refresh_all_rows(state);
                assert_eq!(state.icon_unresolved_rows, 1);
            }
            pump_icon_test_until(window, Duration::from_secs(5), || {
                stale_entered.load(Ordering::Acquire)
            })?;
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("icon test state unavailable"))?;
                let state = lease.state_mut();
                assert_eq!(state.model.remove_rows(&[10_002]), 1);
                assert_eq!(
                    state.model.append(LegacyListItem::new(
                        r"C:\icon-test\zzzzzz.xreplacement",
                        false,
                        0,
                        0,
                        0,
                    )),
                    Ok(true)
                );
                refresh_all_rows(state);
                assert_eq!(state.rendered_rows[10_002].icon, I_IMAGENONE);
                assert!(!state.rendered_rows[10_002].icon_resolved);
            }
            stale_gate.release();
            pump_icon_test_until(window, Duration::from_secs(10), || {
                try_app_state(window).is_some_and(|lease| {
                    lease.state().icon_unresolved_rows == 0 && guardian.shared.pending_count() == 0
                })
            })?;
            let lease = try_app_state(window)
                .ok_or_else(|| io::Error::other("icon test state disappeared"))?;
            assert_eq!(lease.state().rendered_rows[10_002].icon, 0);
            assert_eq!(calls.load(Ordering::Acquire), 10_003);
            assert_native_refresh_values(lease.state());
            drop(lease);
            guardian.retire_and_join_responsively();
            assert!(guardian.shared.is_joined());
            Ok(())
        })
    }

    fn assert_ordinary_close_waits_for_icon_join(
        image_list: icon_worker::BorrowedSystemImageList,
    ) -> io::Result<()> {
        let root = tempfile::tempdir()?;
        application::with_production_popup_window_for_test(root.path(), false, |window| {
            let gate = IconTestGate::held();
            let worker_gate = gate.clone();
            let (entered_tx, entered_rx) = mpsc::sync_channel(1);
            let class_calls = Arc::new(AtomicUsize::new(0));
            let worker_class_calls = Arc::clone(&class_calls);
            let mut guardian = icon_worker::IconRunGuardian::start_with(
                // SAFETY: the production test window belongs to this UI thread.
                unsafe { windows_sys::Win32::System::Threading::GetCurrentThreadId() },
                move || {
                    let lookup = icon_worker::ControlledIconLookup::initialize(image_list)?;
                    Some(
                        move |key: &crate::icon_requests::RequestKey<IconCacheKey>| {
                            if matches!(key, crate::icon_requests::RequestKey::Class(_)) {
                                if worker_class_calls.fetch_add(1, Ordering::AcqRel) == 0 {
                                    let _ = entered_tx.send(());
                                    worker_gate.wait();
                                }
                            }
                            lookup.query(key)
                        },
                    )
                },
            )?;
            // On every error path, release the controlled provider before the
            // guardian's Drop joins its tracked worker.
            let _release = ReleaseIconGate(gate.clone());
            install_icon_test_guardian(window, &guardian)?;
            let close_join_subclass =
                IconCloseJoinSubclass::install(window, Arc::clone(&guardian.shared))?;
            pump_icon_test_until(window, Duration::from_secs(5), || {
                try_app_state(window).is_some_and(|lease| lease.state().icon_image_list.is_some())
            })?;
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("ordinary close state unavailable"))?;
                let state = lease.state_mut();
                assert_eq!(
                    state.model.append(LegacyListItem::new(
                        r"C:\icon-test\ordinary.pending",
                        false,
                        0,
                        0,
                        0,
                    )),
                    Ok(true)
                );
                refresh_all_rows(state);
            }
            entered_rx
                .recv_timeout(Duration::from_secs(2))
                .map_err(|_| io::Error::other("ordinary close icon lookup did not block"))?;
            // SAFETY: the live production owner handles its ordinary close
            // message after the preceding AppState lease has ended.
            unsafe { SendMessageW(window, WM_CLOSE, 0, 0) };
            assert_ne!(unsafe { IsWindow(window) }, 0);
            {
                let lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("ordinary close state disappeared early"))?;
                let state = lease.state();
                assert!(state.close_pending && state.mutation_locked);
                assert_eq!(
                    state.ui_status.message_text(),
                    "아이콘 정보 조회를 마치는 중입니다. 완료되면 창이 닫힙니다."
                );
                assert!(!guardian.shared.is_joined());
            }
            assert_ui_ack_while_icon_blocked(window)?;
            gate.release();
            pump_icon_test_until(window, Duration::from_secs(10), || {
                guardian.poll_join();
                // The WM_DESTROY callback records the worker state at the
                // actual lifetime boundary, before this later observer runs.
                unsafe { IsWindow(window) == 0 }
            })?;
            let observation = close_join_subclass.observation();
            assert!(observation.saw_destroy.load(Ordering::Acquire));
            assert!(observation.joined_at_destroy.load(Ordering::Acquire));
            assert!(observation.detached_at_nc_destroy.load(Ordering::Acquire));
            assert!(guardian.shared.is_joined());
            assert!(guardian.shared.owner_destroyed());
            assert_eq!(class_calls.load(Ordering::Acquire), 1);
            Ok(())
        })
    }

    #[test]
    fn icon_worker_close_and_forced_destroy_retire() -> io::Result<()> {
        with_icon_native_window(|window, image_list| {
            assert_ordinary_close_waits_for_icon_join(image_list)?;
            let slot = app_state_slot(window);
            // SAFETY: the test owns the published slot; the hold outlives the
            // actual worker join and the deliberately nested owner teardown.
            let hold = unsafe { CallbackReclaimHold::new(slot) }
                .ok_or_else(|| io::Error::other("icon test reclaim hold failed"))?;
            let gate = IconTestGate::held();
            let worker_gate = gate.clone();
            let (entered_tx, entered_rx) = mpsc::sync_channel(1);
            let class_calls = Arc::new(AtomicUsize::new(0));
            let worker_class_calls = Arc::clone(&class_calls);
            let mut guardian = icon_worker::IconRunGuardian::start_with(
                // SAFETY: this exact scalar identifies the owning UI thread.
                unsafe { windows_sys::Win32::System::Threading::GetCurrentThreadId() },
                move || {
                    let lookup = icon_worker::ControlledIconLookup::initialize(image_list)?;
                    Some(
                        move |key: &crate::icon_requests::RequestKey<IconCacheKey>| {
                            if matches!(key, crate::icon_requests::RequestKey::Class(_)) {
                                let call = worker_class_calls.fetch_add(1, Ordering::AcqRel);
                                if call == 0 {
                                    let _ = entered_tx.send(());
                                    worker_gate.wait();
                                }
                            }
                            lookup.query(key)
                        },
                    )
                },
            )?;
            let _release = ReleaseIconGate(gate.clone());
            install_icon_test_guardian(window, &guardian)?;
            pump_icon_test_until(window, Duration::from_secs(5), || {
                try_app_state(window).is_some_and(|lease| lease.state().icon_image_list.is_some())
            })?;
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("icon test state unavailable"))?;
                let state = lease.state_mut();
                state
                    .model
                    .append_batch_by(
                        [
                            LegacyListItem::new(r"C:\icon-test\first.one", false, 0, 0, 0),
                            LegacyListItem::new(r"C:\icon-test\second.two", false, 0, 0, 0),
                        ],
                        compare_windows,
                    )
                    .map_err(|error| io::Error::other(error.to_string()))?;
                refresh_all_rows(state);
                assert_eq!(state.icon_unresolved_rows, 2);
            }
            let queue_deadline = Instant::now() + Duration::from_secs(2);
            entered_rx
                .recv_timeout(queue_deadline.saturating_duration_since(Instant::now()))
                .map_err(|_| io::Error::other("first class query did not block"))?;
            // The second render may find the request lock busy while the first
            // class enters the worker. Pump its normal UI demand retry before
            // checking the queue, while the first class remains gate-held.
            pump_icon_test_until(
                window,
                queue_deadline.saturating_duration_since(Instant::now()),
                || guardian.shared.pending_count() == 2,
            )?;
            assert_eq!(guardian.shared.pending_count(), 2);
            assert_ui_ack_while_icon_blocked(window)?;
            let outer_lease = try_app_state(window)
                .ok_or_else(|| io::Error::other("outer icon test lease unavailable"))?;
            // SAFETY: the live owner is destroyed while the test holds an
            // outer AppState lease and the first Shell call remains blocked.
            assert_ne!(unsafe { DestroyWindow(window) }, 0);
            assert!(guardian.shared.owner_destroyed());
            // SAFETY: WM_NCDESTROY unpublished the exact slot, and the
            // run-scope hold keeps it allocated until the worker is terminal.
            assert!(unsafe { CallbackState::try_lease(slot) }.is_none());
            gate.release();
            guardian.retire_and_join_responsively();
            assert!(guardian.shared.is_joined());
            assert_eq!(class_calls.load(Ordering::Acquire), 1);
            drop(outer_lease);
            drop(hold);
            let nested_root = tempfile::tempdir()?;
            application::with_production_popup_window_for_test(
                nested_root.path(),
                false,
                |nested| {
                    let nested_slot = app_state_slot(nested);
                    // SAFETY: this second slot is published until the
                    // synchronized native icon update destroys its owner.
                    let nested_hold = unsafe { CallbackReclaimHold::new(nested_slot) }
                        .ok_or_else(|| io::Error::other("nested icon hold failed"))?;
                    let nested_gate = IconTestGate::held();
                    let worker_nested_gate = nested_gate.clone();
                    let (nested_tx, nested_rx) = mpsc::sync_channel(1);
                    let mut nested_guardian = icon_worker::IconRunGuardian::start_with(
                        // SAFETY: this is the current owner UI thread ID.
                        unsafe { windows_sys::Win32::System::Threading::GetCurrentThreadId() },
                        move || {
                            let lookup = icon_worker::ControlledIconLookup::initialize(image_list)?;
                            Some(
                                move |key: &crate::icon_requests::RequestKey<IconCacheKey>| {
                                    if matches!(key, crate::icon_requests::RequestKey::Class(_)) {
                                        let _ = nested_tx.send(());
                                        worker_nested_gate.wait();
                                    }
                                    lookup.query(key)
                                },
                            )
                        },
                    )?;
                    let _nested_release = ReleaseIconGate(nested_gate.clone());
                    install_icon_test_guardian(nested, &nested_guardian)?;
                    pump_icon_test_until(nested, Duration::from_secs(5), || {
                        try_app_state(nested)
                            .is_some_and(|lease| lease.state().icon_image_list.is_some())
                    })?;
                    let list = {
                        let mut lease = try_app_state(nested)
                            .ok_or_else(|| io::Error::other("nested icon state unavailable"))?;
                        let state = lease.state_mut();
                        assert_eq!(
                            state.model.append(LegacyListItem::new(
                                r"C:\icon-test\nested.icon",
                                false,
                                0,
                                0,
                                0,
                            )),
                            Ok(true)
                        );
                        refresh_all_rows(state);
                        state.list_window
                    };
                    // A busy first submit is retried by the ordinary UI poll.
                    // Keep servicing that poll while awaiting the real worker
                    // entry, under the original two-second bound.
                    pump_icon_test_until(nested, Duration::from_secs(2), || {
                        nested_rx.try_recv().is_ok()
                    })
                    .map_err(|error| {
                        io::Error::other(format!("nested class query did not block: {error}"))
                    })?;
                    ICON_TEST_DESTROY_BUSY.with(|observed| observed.set(false));
                    // SAFETY: the test owns this live child; the exact
                    // subclass removes itself in its WM_NCDESTROY callback.
                    assert_ne!(
                        // SAFETY: the live child and owning UI thread remain
                        // valid until the synchronized callback below.
                        unsafe {
                            SetWindowSubclass(
                                list,
                                Some(icon_test_destroy_on_icon_subclass),
                                ICON_TEST_DESTROY_SUBCLASS,
                                nested as usize,
                            )
                        },
                        0
                    );
                    nested_gate.release();
                    pump_icon_test_until(nested, Duration::from_secs(10), || {
                        // SAFETY: this query observes only HWND liveness.
                        unsafe { IsWindow(nested) == 0 }
                    })?;
                    assert!(ICON_TEST_DESTROY_BUSY.with(Cell::get));
                    assert!(nested_guardian.shared.owner_destroyed());
                    nested_guardian.retire_and_join_responsively();
                    assert!(nested_guardian.shared.is_joined());
                    drop(nested_hold);
                    Ok(())
                },
            )?;
            Ok(())
        })
    }

    #[derive(Clone, Copy)]
    enum IconTerminalCause {
        BootstrapFailure,
        WorkerQuit,
    }

    fn assert_live_rows_settle_after_icon_terminal(
        cause: IconTerminalCause,
        image_list: icon_worker::BorrowedSystemImageList,
    ) -> io::Result<()> {
        let root = tempfile::tempdir()?;
        application::with_production_popup_window_for_test(root.path(), false, |window| {
            let slot = app_state_slot(window);
            // SAFETY: this production slot remains held until the worker is
            // terminal, including any nested native callback during settling.
            let _hold = unsafe { CallbackReclaimHold::new(slot) }
                .ok_or_else(|| io::Error::other("terminal icon hold failed"))?;
            let gate = IconTestGate::held();
            let worker_gate = gate.clone();
            let (entered_tx, entered_rx) = mpsc::sync_channel(1);
            let class_calls = Arc::new(AtomicUsize::new(0));
            let worker_class_calls = Arc::clone(&class_calls);
            let mut guardian = icon_worker::IconRunGuardian::start_with(
                // SAFETY: this scalar identifies the current test UI thread.
                unsafe { windows_sys::Win32::System::Threading::GetCurrentThreadId() },
                move || {
                    let lookup = icon_worker::ControlledIconLookup::initialize(image_list)?;
                    Some(
                        move |key: &crate::icon_requests::RequestKey<IconCacheKey>| match key {
                            crate::icon_requests::RequestKey::Bootstrap => {
                                let _ = entered_tx.send(());
                                worker_gate.wait();
                                if matches!(cause, IconTerminalCause::BootstrapFailure) {
                                    icon_worker::IconResult::Bootstrap(None)
                                } else {
                                    lookup.query(key)
                                }
                            }
                            crate::icon_requests::RequestKey::Class(_) => {
                                worker_class_calls.fetch_add(1, Ordering::AcqRel);
                                lookup.query(key)
                            }
                        },
                    )
                },
            )?;
            let _release = ReleaseIconGate(gate.clone());
            install_icon_test_guardian(window, &guardian)?;
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("terminal icon state unavailable"))?;
                let state = lease.state_mut();
                state
                    .model
                    .append_batch_by(
                        refresh_fixture_rows(r"C:\icon-terminal", "held", 0, 2),
                        compare_windows,
                    )
                    .map_err(|error| io::Error::other(error.to_string()))?;
                refresh_all_rows(state);
                assert_eq!(state.icon_unresolved_rows, 2);
                assert_native_refresh_values(state);
            }
            entered_rx
                .recv_timeout(Duration::from_secs(2))
                .map_err(|_| io::Error::other("terminal bootstrap did not block"))?;
            gate.release();
            if matches!(cause, IconTerminalCause::WorkerQuit) {
                pump_icon_test_until(window, Duration::from_secs(5), || {
                    try_app_state(window).is_some_and(|lease| {
                        lease.state().icon_image_list.is_some()
                            && lease.state().icon_unresolved_rows == 0
                            && guardian.shared.pending_count() == 0
                    })
                })?;
                assert!(guardian.shared.post_quit_for_test());
                pump_icon_test_until(window, Duration::from_secs(5), || guardian.poll_join())?;
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("post-bootstrap icon state unavailable"))?;
                let state = lease.state_mut();
                assert!(state.model.clear());
                refresh_all_rows(state);
                state
                    .model
                    .append_batch_by(
                        [
                            LegacyListItem::new(
                                r"C:\icon-after-quit\first.afterquit",
                                false,
                                0,
                                0,
                                0,
                            ),
                            LegacyListItem::new(
                                r"C:\icon-after-quit\second.afterquit",
                                false,
                                0,
                                0,
                                0,
                            ),
                        ],
                        compare_windows,
                    )
                    .map_err(|error| io::Error::other(error.to_string()))?;
                refresh_all_rows(state);
                assert!(state.icon_image_list.is_some());
            }
            pump_icon_test_until(window, Duration::from_secs(5), || {
                guardian.poll_join();
                try_app_state(window).is_some_and(|lease| {
                    let state = lease.state();
                    guardian.shared.is_joined()
                        && guardian.shared.is_unavailable()
                        && guardian.shared.pending_count() == 0
                        && state.icon_unresolved_rows == 0
                        && state
                            .rendered_rows
                            .iter()
                            .all(|row| row.icon_resolved && row.icon == I_IMAGENONE)
                })
            })?;
            if matches!(cause, IconTerminalCause::BootstrapFailure) {
                assert_eq!(class_calls.load(Ordering::Acquire), 0);
            }
            let lease = try_app_state(window)
                .ok_or_else(|| io::Error::other("terminal icon state disappeared"))?;
            assert_eq!(lease.state().icon_demand_scan_remaining, 0);
            assert_eq!(lease.state().icon_status_value(11), Some(1));
            assert_eq!(lease.state().icon_status_value(21), Some(1));
            if matches!(cause, IconTerminalCause::WorkerQuit) {
                assert_eq!(lease.state().icon_status_value(5), Some(1));
            }
            assert_native_refresh_values(lease.state());
            drop(lease);
            let mut lease = try_app_state(window)
                .ok_or_else(|| io::Error::other("terminal icon state disappeared"))?;
            let state = lease.state_mut();
            let changed = state
                .model
                .prefix_complete_changed(&LegacyText::from("proposed-"))
                .map_err(|error| io::Error::other(error.to_string()))?;
            assert_eq!(changed.len(), 2);
            refresh_changed_rows(state, &changed);
            assert_eq!(state.icon_unresolved_rows, 0);
            assert_eq!(state.icon_reconcile_remaining, 0);
            assert_eq!(state.icon_demand_scan_remaining, 0);
            assert_eq!(state.icon_status_value(11), Some(1));
            assert_native_refresh_values(state);
            Ok(())
        })
    }

    #[test]
    fn icon_worker_failures_and_message_loop_retire() -> io::Result<()> {
        with_icon_native_window(|window, image_list| {
            let slot = app_state_slot(window);
            // SAFETY: the test owns this published production slot and retains
            // it until the worker's terminal join is observed.
            let _hold = unsafe { CallbackReclaimHold::new(slot) }
                .ok_or_else(|| io::Error::other("icon test reclaim hold failed"))?;
            let gate = IconTestGate::held();
            let worker_gate = gate.clone();
            let (entered_tx, entered_rx) = mpsc::sync_channel(1);
            let mut failed = icon_worker::IconRunGuardian::start_with(
                // SAFETY: this scalar identifies the owning UI thread.
                unsafe { windows_sys::Win32::System::Threading::GetCurrentThreadId() },
                move || {
                    let _ = entered_tx.send(());
                    worker_gate.wait();
                    None::<
                        fn(
                            &crate::icon_requests::RequestKey<IconCacheKey>,
                        ) -> icon_worker::IconResult,
                    >
                },
            )?;
            let _release = ReleaseIconGate(gate.clone());
            install_icon_test_guardian(window, &failed)?;
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("icon test state unavailable"))?;
                let state = lease.state_mut();
                state
                    .model
                    .append_batch_by(
                        refresh_fixture_rows(r"C:\icon-test", "failure", 0, 2),
                        compare_windows,
                    )
                    .map_err(|error| io::Error::other(error.to_string()))?;
                refresh_all_rows(state);
                assert_eq!(state.icon_unresolved_rows, 2);
                assert!(state.rendered_rows.iter().all(|row| !row.icon_resolved));
            }
            entered_rx
                .recv_timeout(Duration::from_secs(2))
                .map_err(|_| io::Error::other("failed worker did not enter startup"))?;
            assert_ui_ack_while_icon_blocked(window)?;
            gate.release();
            pump_icon_test_until(window, Duration::from_secs(5), || {
                failed.poll_join();
                try_app_state(window).is_some_and(|lease| {
                    let state = lease.state();
                    failed.shared.is_joined()
                        && failed.shared.is_unavailable()
                        && failed.shared.pending_count() == 0
                        && state.icon_unresolved_rows == 0
                        && state
                            .rendered_rows
                            .iter()
                            .all(|row| row.icon_resolved && row.icon == I_IMAGENONE)
                })
            })?;
            {
                let lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("failed icon state disappeared"))?;
                let state = lease.state();
                assert_native_refresh_values(state);
                assert_eq!(state.icon_demand_scan_remaining, 0);
                assert_eq!(state.icon_status_value(11), Some(1));
                assert_eq!(state.icon_status_value(12), Some(1));
            }
            // Keep OLE/WinRT initialized on this UI thread while exercising
            // both other terminal causes on separate real production owners.
            assert_live_rows_settle_after_icon_terminal(
                IconTerminalCause::BootstrapFailure,
                image_list,
            )?;
            assert_live_rows_settle_after_icon_terminal(IconTerminalCause::WorkerQuit, image_list)?;
            let failed_spawn_root = tempfile::tempdir()?;
            application::with_production_popup_window_for_test(
                failed_spawn_root.path(),
                false,
                |failed_spawn_window| {
                    icon_worker::IconRunGuardian::fail_next_spawn_for_test();
                    // SAFETY: this scalar identifies the current test UI
                    // thread; the injected failure creates no worker handle.
                    let launch = icon_worker::IconRunGuardian::start(unsafe {
                        windows_sys::Win32::System::Threading::GetCurrentThreadId()
                    });
                    assert!(launch.is_err());
                    let no_guardian = launch.ok();
                    assert!(no_guardian.is_none());
                    let mut lease = try_app_state(failed_spawn_window)
                        .ok_or_else(|| io::Error::other("failed-spawn state unavailable"))?;
                    let state = lease.state_mut();
                    state
                        .model
                        .append_batch_by(
                            refresh_fixture_rows(r"C:\icon-spawn-failure", "held", 0, 2),
                            compare_windows,
                        )
                        .map_err(|error| io::Error::other(error.to_string()))?;
                    refresh_all_rows(state);
                    assert!(
                        state
                            .rendered_rows
                            .iter()
                            .all(|row| { row.icon_resolved && row.icon == I_IMAGENONE })
                    );
                    assert_eq!(state.icon_status_value(1), Some(0));
                    assert_eq!(state.icon_status_value(5), Some(2));
                    assert_eq!(state.icon_status_value(11), Some(1));
                    assert_eq!(state.icon_status_value(12), Some(0));
                    assert_eq!(state.icon_status_value(21), Some(1));
                    assert_native_refresh_values(state);
                    state
                        .model
                        .append_batch_by(
                            refresh_fixture_rows(r"C:\icon-spawn-failure", "later", 2, 1),
                            compare_windows,
                        )
                        .map_err(|error| io::Error::other(error.to_string()))?;
                    refresh_all_rows(state);
                    poll_icon_work(state);
                    assert_eq!(state.icon_status_value(1), Some(0));
                    assert_eq!(state.icon_status_value(12), Some(0));
                    assert_eq!(state.icon_unresolved_rows, 0);
                    assert_native_refresh_values(state);
                    Ok(())
                },
            )?;
            assert_injected_message_loop_failure_shutdown_order(image_list)?;
            Ok(())
        })
    }

    struct IconEmergencyTestCleanup {
        window: HWND,
        guardian: icon_worker::IconRunGuardian,
        icon_gate: IconTestGate,
        import_gate: IconTestGate,
        apply_gate: IconTestGate,
        preferences_gate: IconTestGate,
        finished: bool,
    }

    impl IconEmergencyTestCleanup {
        fn release_workers(&self) {
            self.icon_gate.release();
            self.import_gate.release();
            self.apply_gate.release();
            self.preferences_gate.release();
        }

        fn finish(&mut self) {
            if self.finished {
                return;
            }
            worker::request_worker_shutdown_after_message_loop_failure(self.window);
            self.release_workers();
            self.guardian.retire_and_join_responsively();
            // The import emergency finalizer deliberately aborts if its
            // provider remains live. Test-owned barriers are released above;
            // observe that provider's real terminal state before invoking it.
            let deadline = Instant::now() + Duration::from_secs(5);
            while try_app_state(self.window).is_some_and(|lease| {
                lease
                    .state()
                    .import_worker
                    .as_ref()
                    .is_some_and(|worker| !worker.handle.is_finished())
            }) {
                assert!(Instant::now() < deadline, "held test import did not retire");
                thread::sleep(Duration::from_millis(5));
            }
            worker::finish_apply_after_message_loop_failure(self.window);
            self.finished = true;
        }
    }

    impl Drop for IconEmergencyTestCleanup {
        fn drop(&mut self) {
            self.finish();
        }
    }

    fn assert_injected_message_loop_failure_shutdown_order(
        image_list: icon_worker::BorrowedSystemImageList,
    ) -> io::Result<()> {
        let root = tempfile::tempdir()?;
        application::with_production_popup_window_for_test(root.path(), false, |window| {
            let slot = app_state_slot(window);
            // SAFETY: this test owns the published slot; the hold remains
            // until the icon guardian has observed the actual thread join.
            let _hold = unsafe { CallbackReclaimHold::new(slot) }
                .ok_or_else(|| io::Error::other("emergency test reclaim hold failed"))?;
            let icon_gate = IconTestGate::held();
            let import_gate = IconTestGate::held();
            let apply_gate = IconTestGate::held();
            let preferences_gate = IconTestGate::held();
            let worker_icon_gate = icon_gate.clone();
            let (icon_entered_tx, icon_entered_rx) = mpsc::sync_channel(1);
            let guardian = icon_worker::IconRunGuardian::start_with(
                // SAFETY: the test UI thread owns the product window.
                unsafe { windows_sys::Win32::System::Threading::GetCurrentThreadId() },
                move || {
                    let lookup = icon_worker::ControlledIconLookup::initialize(image_list)?;
                    Some(
                        move |key: &crate::icon_requests::RequestKey<IconCacheKey>| {
                            if matches!(key, crate::icon_requests::RequestKey::Class(_)) {
                                let _ = icon_entered_tx.send(());
                                worker_icon_gate.wait();
                            }
                            lookup.query(key)
                        },
                    )
                },
            )?;
            let mut cleanup = IconEmergencyTestCleanup {
                window,
                guardian,
                icon_gate,
                import_gate: import_gate.clone(),
                apply_gate: apply_gate.clone(),
                preferences_gate: preferences_gate.clone(),
                finished: false,
            };
            install_icon_test_guardian(window, &cleanup.guardian)?;
            let (import_entered_tx, import_entered_rx) = mpsc::sync_channel(1);
            let worker_import_gate = import_gate.clone();
            let (apply_entered_tx, apply_entered_rx) = mpsc::sync_channel(1);
            let worker_apply_gate = apply_gate.clone();
            let (preferences_entered_tx, preferences_entered_rx) = mpsc::sync_channel(1);
            let worker_preferences_gate = preferences_gate.clone();
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("emergency test state unavailable"))?;
                let state = lease.state_mut();
                state
                    .model
                    .append_batch_by(
                        refresh_fixture_rows(r"C:\icon-emergency", "held", 0, 1),
                        compare_windows,
                    )
                    .map_err(|error| io::Error::other(error.to_string()))?;
                refresh_all_rows(state);
                let revision = state.revision();
                worker::start_import_worker_from(
                    window,
                    state,
                    1,
                    revision,
                    worker::ImportKind::Names,
                    move |_| {
                        let _ = import_entered_tx.send(());
                        worker_import_gate.wait();
                        Err(io::Error::other("cancelled test import"))
                    },
                )?;
                worker::start_held_apply_worker_for_test(window, state, move || {
                    let _ = apply_entered_tx.send(());
                    worker_apply_gate.wait();
                })?;
                let writer = PreferencesWriter::spawn_with_for_test(
                    root.path().join("held-preferences"),
                    move |_, _| {
                        let _ = preferences_entered_tx.try_send(());
                        worker_preferences_gate.wait();
                        Ok(())
                    },
                )?;
                state.preference_persistence = PreferencePersistence::new(Some(writer), None);
                state
                    .preference_persistence
                    .submit_columns(state.column_states)?;
            }
            for (label, receiver) in [
                ("icon", icon_entered_rx),
                ("import", import_entered_rx),
                ("apply", apply_entered_rx),
                ("preferences", preferences_entered_rx),
            ] {
                receiver
                    .recv_timeout(Duration::from_secs(5))
                    .map_err(|_| io::Error::other(format!("held {label} worker did not enter")))?;
            }
            assert_ui_ack_while_icon_blocked(window)?;
            assert!(initialize_safe_runtime_at(root.path()).is_err());
            // This injects the production error *handler* after all four
            // workers entered. No OS-issued GetMessageW failure is claimed.
            worker::request_worker_shutdown_after_message_loop_failure(window);
            {
                let lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("emergency state disappeared"))?;
                let state = lease.state();
                assert!(state.close_pending && state.mutation_locked);
                assert!(
                    state
                        .import_worker
                        .as_ref()
                        .is_some_and(worker::ImportWorker::cancellation_requested)
                );
                assert!(
                    state
                        .apply_worker
                        .as_ref()
                        .is_some_and(worker::ApplyWorker::cancellation_requested)
                );
                assert!(
                    state
                        .icon_shared
                        .as_ref()
                        .is_some_and(|shared| shared.is_unavailable())
                );
                assert!(!cleanup.guardian.shared.is_joined());
                assert!(!state.preference_persistence.is_joined());
            }
            {
                let mut lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("emergency state disappeared"))?;
                let state = lease.state_mut();
                assert!(
                    state
                        .preference_persistence
                        .submit_columns(state.column_states)
                        .is_err()
                );
            }
            cleanup.icon_gate.release();
            cleanup.guardian.retire_and_join_responsively();
            assert!(cleanup.guardian.shared.is_joined());
            {
                let lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("emergency state disappeared"))?;
                let state = lease.state();
                assert!(state.import_worker.is_some());
                assert!(state.apply_worker.is_some());
                assert!(!state.preference_persistence.is_joined());
            }
            assert!(initialize_safe_runtime_at(root.path()).is_err());
            cleanup.finish();
            {
                let lease = try_app_state(window)
                    .ok_or_else(|| io::Error::other("emergency state disappeared"))?;
                let state = lease.state();
                assert!(state.import_worker.is_none());
                assert!(state.apply_worker.is_none());
                assert!(state.preference_persistence.is_joined());
                assert!(
                    state
                        .icon_shared
                        .as_ref()
                        .is_some_and(|shared| shared.is_joined())
                );
            }
            assert!(initialize_safe_runtime_at(root.path()).is_err());
            Ok(())
        })?;
        let reopened = initialize_safe_runtime_at(root.path())?;
        drop(reopened);
        Ok(())
    }

    fn refresh_fixture_rows(
        parent: &str,
        kind: &str,
        first: usize,
        count: usize,
    ) -> Vec<LegacyListItem> {
        (first..first + count)
            .map(|index| {
                let name = if kind == "ordinary" {
                    format!("ordinary-{index:05}.txt")
                } else {
                    format!("long-{index:04}.txt")
                };
                LegacyListItem::new_with_actual_size(
                    format!("{parent}\\{name}"),
                    false,
                    24,
                    24,
                    133_497_936_000_000_000,
                    133_497_936_000_000_000,
                )
            })
            .collect()
    }

    fn assert_native_refresh_values(state: &AppState) {
        assert_eq!(state.rendered_rows.len(), state.model.len());
        for row in [
            0,
            state.model.len() / 2,
            state.model.len().saturating_sub(1),
        ] {
            let Some(item) = state.model.items().get(row) else {
                continue;
            };
            let expected_values = [
                item.current_name().clone(),
                item.proposed_name().clone(),
                item.root_path().clone(),
                item.source_path().clone(),
                LegacyText::from(format_iec_file_size(item.actual_size())),
                format_filetime(item.modified()),
                format_filetime(item.created()),
                LegacyText::from(preview_status_label(
                    state.preview_issue_cache.issue(row),
                    item.planned_change_kind(),
                )),
            ];
            assert_eq!(state.rendered_rows[row].values, expected_values);
            for (column, value) in expected_values.iter().enumerate() {
                let mut text = vec![0_u16; value.len() + 1];
                let mut query = LVITEMW {
                    iItem: row as i32,
                    iSubItem: column as i32,
                    pszText: text.as_mut_ptr(),
                    cchTextMax: text.len() as i32,
                    ..LVITEMW::default()
                };
                // SAFETY: the owned query/buffer are writable for synchronous
                // text readback from this test-owned live ListView.
                let copied = unsafe {
                    SendMessageW(
                        state.list_window,
                        LVM_GETITEMTEXTW,
                        row,
                        (&raw mut query) as isize,
                    )
                };
                assert_eq!(copied, value.len() as isize);
                assert_eq!(&text[..value.len()], value.units());
            }
            let mut query = LVITEMW {
                mask: LVIF_IMAGE,
                iItem: row as i32,
                ..LVITEMW::default()
            };
            // SAFETY: this live ListView synchronously writes the owned query;
            // no caller storage or model reference is retained by the control.
            let found = unsafe {
                SendMessageW(
                    state.list_window,
                    LVM_GETITEMW,
                    0,
                    (&raw mut query) as isize,
                )
            };
            assert_ne!(found, 0);
            // The requested class result is asserted by each native test;
            // this checks that the scalar image applied to the native row is
            // the same one retained for that exact current model row.
            assert_eq!(query.iImage, state.rendered_rows[row].icon);
        }
    }

    fn measure_refresh(
        state: &mut AppState,
        label: &str,
        action: impl FnOnce(&mut AppState),
    ) -> refresh_profile::Counters {
        // This fixture has no icon worker. Its clocks attribute only text,
        // issue-count, and native-row UI staging, never async Shell latency.
        assert!(state.icon_shared.is_none());
        let collection = refresh_profile::Collection::begin();
        action(state);
        let counters = collection.finish(label, state.model.len());
        assert!(state.preview_synchronization.is_synchronized());
        assert_eq!(state.rendered_rows.len(), state.model.len());
        // SAFETY: this scalar query addresses the live test-owned ListView.
        let native_count = unsafe { SendMessageW(state.list_window, LVM_GETITEMCOUNT, 0, 0) };
        assert_eq!(native_count, state.model.len() as isize);
        assert_eq!(counters.timestamp_values, counters.rows_formatted * 2);
        assert_eq!(
            counters.render_icon_cache_hits + counters.render_icon_cache_misses,
            counters.rows_formatted
        );
        assert_eq!(counters.ui_shell_calls, 0);
        assert_eq!(counters.icon_request_submissions, 0);
        assert_eq!(counters.icon_results_drained, 0);
        assert_native_refresh_values(state);
        counters
    }

    fn distinct_refresh_rows() -> Vec<LegacyListItem> {
        let base = 133_497_936_000_000_000_u64;
        [
            (
                r"C:\refresh-fixture\normal",
                "ordinary-00000.txt",
                false,
                0_u64,
            ),
            (r"C:\refresh-fixture\other", "ordinary-00001.png", false, 1),
            (r"C:\refresh-fixture\normal", "ordinary-00002", false, 1_024),
            (r"C:\refresh-fixture\other", "ordinary-00003", true, 4_096),
            (
                r"C:\refresh-fixture\normal",
                "ordinary-00004.zip",
                false,
                12_345,
            ),
            (
                r"C:\refresh-fixture\other",
                "ordinary-00005.log",
                false,
                5_000_000_000,
            ),
        ]
        .into_iter()
        .enumerate()
        .map(|(index, (parent, name, is_directory, size))| {
            let hour = index as u64 * 36_000_000_000;
            LegacyListItem::new_with_actual_size(
                format!("{parent}\\{name}"),
                is_directory,
                size.min(u32::MAX as u64) as u32,
                size,
                base + hour,
                base + hour + 18_000_000_000,
            )
        })
        .collect()
    }

    fn assert_model_native_rows(state: &AppState) {
        assert!(state.preview_synchronization.is_synchronized());
        assert_eq!(state.rendered_rows.len(), state.model.len());
        assert!(
            state.icon_shared.is_none(),
            "this fixture has no icon worker"
        );
        // SAFETY: scalar count query on the live test-owned ListView.
        let native_count = unsafe { SendMessageW(state.list_window, LVM_GETITEMCOUNT, 0, 0) };
        assert_eq!(native_count, state.model.len() as isize);
        for (row, item) in state.model.items().iter().enumerate() {
            let rendered = &state.rendered_rows[row];
            let expected = [
                item.current_name().clone(),
                item.proposed_name().clone(),
                item.root_path().clone(),
                item.source_path().clone(),
                LegacyText::from(format_iec_file_size(item.actual_size())),
                format_filetime(item.modified()),
                format_filetime(item.created()),
                LegacyText::from(preview_status_label(
                    state.preview_issue_cache.issue(row),
                    item.planned_change_kind(),
                )),
            ];
            assert_eq!(rendered.values, expected, "model row {row}");
            assert_eq!(
                rendered.icon_key,
                icon_cache_key(item.current_name(), item.is_directory())
            );
            assert!(rendered.icon_resolved);
            assert_eq!(
                rendered.icon,
                state
                    .icon_cache
                    .get(&rendered.icon_key)
                    .copied()
                    .unwrap_or(I_IMAGENONE)
            );
            for (column, value) in expected.iter().enumerate() {
                let mut text = vec![0_u16; value.len() + 1];
                let mut query = LVITEMW {
                    iItem: row as i32,
                    iSubItem: column as i32,
                    pszText: text.as_mut_ptr(),
                    cchTextMax: text.len() as i32,
                    ..LVITEMW::default()
                };
                // SAFETY: query and UTF-16 buffer are writable through the
                // synchronous text readback from this live ListView.
                let copied = unsafe {
                    SendMessageW(
                        state.list_window,
                        LVM_GETITEMTEXTW,
                        row,
                        (&raw mut query) as isize,
                    )
                };
                assert_eq!(copied, value.len() as isize, "row {row} column {column}");
                assert_eq!(
                    &text[..value.len()],
                    value.units(),
                    "row {row} column {column}"
                );
            }
            let mut query = LVITEMW {
                mask: LVIF_IMAGE,
                iItem: row as i32,
                ..LVITEMW::default()
            };
            // SAFETY: query is writable through the synchronous image readback.
            let found = unsafe {
                SendMessageW(
                    state.list_window,
                    LVM_GETITEMW,
                    0,
                    (&raw mut query) as isize,
                )
            };
            assert_ne!(found, 0);
            assert_eq!(query.iImage, rendered.icon, "model row {row} image");
        }
    }

    fn assert_normal_refresh(state: &mut AppState, label: &str) -> refresh_profile::Counters {
        assert!(state.preview_synchronization.is_synchronized());
        // SAFETY: scalar count query on the live test-owned ListView.
        let native_count = unsafe { SendMessageW(state.list_window, LVM_GETITEMCOUNT, 0, 0) };
        assert_eq!(native_count, state.rendered_rows.len() as isize);
        let counters = measure_refresh(state, label, refresh_all_rows);
        assert_model_native_rows(state);
        assert_eq!(counters.full_rebuilds, 0, "{label}");
        assert!(counters.normal_staged_rows_peak <= 1, "{label}");
        assert_eq!(counters.fallback_staged_rows_peak, 0, "{label}");
        assert_eq!(
            counters.fallback_logical_staged_payload_bytes_peak, 0,
            "{label}"
        );
        counters
    }

    struct NativeRefreshChild(Child);

    impl Drop for NativeRefreshChild {
        fn drop(&mut self) {
            if !matches!(self.0.try_wait(), Ok(Some(_))) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
    }

    fn forward_native_refresh_child_log(
        case: &str,
        stream: &str,
        path: &Path,
    ) -> io::Result<(usize, bool)> {
        const MAX_CAPTURE_BYTES: u64 = 1024 * 1024;
        const MAX_FORWARDED_LINES: usize = 4096;
        let mut contents = Vec::new();
        File::open(path)?
            .take(MAX_CAPTURE_BYTES + 1)
            .read_to_end(&mut contents)?;
        let truncated = contents.len() as u64 > MAX_CAPTURE_BYTES;
        contents.truncate(MAX_CAPTURE_BYTES as usize);
        let output = String::from_utf8_lossy(&contents);
        let completion = format!("DARKRENAMER_NATIVE_REFRESH_CHILD_COMPLETE:{case}");
        let mut forwarded = 0;
        let mut total_lines = 0;
        let mut completions = 0;
        for line in output.lines() {
            total_lines += 1;
            if line == completion {
                completions += 1;
            }
            if forwarded < MAX_FORWARDED_LINES || line == completion {
                eprintln!("[native-refresh-child:{case}:{stream}] {line}");
                forwarded += 1;
            }
        }
        if truncated || total_lines > MAX_FORWARDED_LINES {
            eprintln!("[native-refresh-child:{case}:{stream}] output truncated");
        }
        Ok((completions, truncated))
    }

    fn isolated_native_refresh_case(
        case: &'static str,
        run: impl FnOnce() -> Result<(), Box<dyn std::error::Error>>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        const CHILD_MODE: &str = "DARKRENAMER_TEST_NATIVE_REFRESH_CHILD";
        const MAX_CAPTURE_BYTES: u64 = 1024 * 1024;
        const DEADLINE: Duration = Duration::from_secs(60);
        let exact_name = format!("windows::list_view::native_tests::full_refresh_{case}");
        if let Some(requested) = std::env::var_os(CHILD_MODE) {
            if requested != std::ffi::OsStr::new(&exact_name) {
                return Err(io::Error::other("unexpected native-refresh child case").into());
            }
            run()?;
            eprintln!("DARKRENAMER_NATIVE_REFRESH_CHILD_COMPLETE:{case}");
            return Ok(());
        }

        // These cases exercise process-cached WinRT factories. Keep each real
        // native fixture in one exact-named child, including its full teardown.
        let directory = tempfile::Builder::new()
            .prefix("darkrenamer-native-refresh-")
            .tempdir()?;
        let stdout_path = directory.path().join("stdout.txt");
        let stderr_path = directory.path().join("stderr.txt");
        let mut child = NativeRefreshChild(
            Command::new(std::env::current_exe()?)
                .arg("--exact")
                .arg(&exact_name)
                .arg("--nocapture")
                .arg("--test-threads=1")
                .env(CHILD_MODE, &exact_name)
                .stdout(Stdio::from(File::create(&stdout_path)?))
                .stderr(Stdio::from(File::create(&stderr_path)?))
                .spawn()?,
        );
        let started = Instant::now();
        let outcome = loop {
            let captured = fs::metadata(&stdout_path).and_then(|stdout| {
                fs::metadata(&stderr_path).map(|stderr| stdout.len().saturating_add(stderr.len()))
            });
            let captured = match captured {
                Ok(captured) => captured,
                Err(error) => {
                    let _ = child.0.kill();
                    let _ = child.0.wait();
                    break Err(error);
                }
            };
            if captured > 2 * MAX_CAPTURE_BYTES {
                let _ = child.0.kill();
                let _ = child.0.wait();
                break Err(io::Error::other(
                    "native-refresh child output exceeded 2 MiB",
                ));
            }
            match child.0.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Ok(None) => {}
                Err(error) => {
                    let _ = child.0.kill();
                    let _ = child.0.wait();
                    break Err(error);
                }
            }
            if started.elapsed() >= DEADLINE {
                let _ = child.0.kill();
                let _ = child.0.wait();
                break Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "native-refresh child exceeded the 60-second deadline",
                ));
            }
            thread::sleep(Duration::from_millis(25));
        };
        let (stdout_completions, stdout_truncated) =
            forward_native_refresh_child_log(case, "stdout", &stdout_path)?;
        let (stderr_completions, stderr_truncated) =
            forward_native_refresh_child_log(case, "stderr", &stderr_path)?;
        let status = outcome?;
        if stdout_truncated || stderr_truncated {
            return Err(io::Error::other("native-refresh child log was truncated").into());
        }
        if !status.success() {
            return Err(
                io::Error::other(format!("native-refresh child {case} failed: {status}")).into(),
            );
        }
        if stdout_completions + stderr_completions != 1 {
            return Err(io::Error::other(format!(
                "native-refresh child {case} did not complete exactly once"
            ))
            .into());
        }
        Ok(())
    }

    fn run_native_rows_and_proposals() -> Result<(), Box<dyn std::error::Error>> {
        let _ole = RefreshTestOle::initialize()?;
        let image_list = icon_worker::OwnedTestImageList::new()?;
        let mut app = RefreshTestApp::new()?;
        app.attach_test_image_list(image_list.borrowed())?;
        app.with_state(|state| -> Result<(), Box<dyn std::error::Error>> {
            let parent = r"C:\refresh-fixture\normal";
            assert_eq!(state.model.len(), 0);
            refresh_all_rows(state);
            assert_model_native_rows(state);
            let rows = distinct_refresh_rows();
            let source_icons = rows
                .iter()
                .enumerate()
                .map(|(index, item)| (item.source_path().clone(), (index % 2) as i32))
                .collect::<Vec<_>>();
            for (index, item) in rows.iter().enumerate() {
                state.icon_cache.insert(
                    icon_cache_key(item.current_name(), item.is_directory()),
                    (index % 2) as i32,
                );
            }
            assert_eq!(state.icon_cache.len(), rows.len());
            state.model.append_batch_by(rows, compare_windows)?;
            let assert_source_icons = |state: &AppState| {
                assert_eq!(state.model.len(), source_icons.len());
                for (index, (item, rendered)) in state
                    .model
                    .items()
                    .iter()
                    .zip(&state.rendered_rows)
                    .enumerate()
                {
                    assert!(
                        state.model.items()[..index]
                            .iter()
                            .all(|prior| prior.source_path() != item.source_path())
                    );
                    let mut matches = source_icons
                        .iter()
                        .filter(|(source, _)| source == item.source_path());
                    assert_eq!(
                        matches.next().map(|(_, icon)| *icon),
                        Some(rendered.icon),
                        "model row {index} source/icon mismatch"
                    );
                    assert!(matches.next().is_none(), "fixture source is ambiguous");
                }
            };
            // The empty ListView and model were synchronized before insertion.
            let first = assert_normal_refresh(state, "regression-first-insertion");
            assert_eq!(first.normal_staged_rows_peak, 1);
            assert!(first.normal_logical_staged_payload_bytes_peak > 0);
            assert!(first.rendered_vec_growth_events > 0);
            assert!(
                first.rendered_vec_capacity_bytes_peak
                    >= state.model.len() * size_of::<RenderedRow>()
            );
            assert_source_icons(state);
            let unchanged = assert_normal_refresh(state, "regression-unchanged");
            assert_eq!(unchanged.rendered_vec_growth_events, 0);
            assert!(unchanged.rendered_vec_capacity_bytes_peak > 0);

            assert!(
                state
                    .model
                    .manual_change_changed(0, "unique-proposal.txt")?
            );
            refresh_proposal_rows(state, &[0]);
            let before = state
                .model
                .items()
                .iter()
                .map(|item| item.current_name().clone())
                .collect::<Vec<_>>();
            assert!(
                state
                    .model
                    .sort_by_changed(LegacySortMode::NameDescending, compare_windows)
            );
            let after = state
                .model
                .items()
                .iter()
                .map(|item| item.current_name().clone())
                .collect::<Vec<_>>();
            assert_ne!(after, before);
            assert_normal_refresh(state, "regression-equal-length-reordered");
            assert_source_icons(state);
            state.model.append_batch_by(
                refresh_fixture_rows(parent, "ordinary", 6, 2),
                compare_windows,
            )?;
            assert_normal_refresh(state, "regression-added");
            assert_eq!(state.model.remove_rows(&[2]), 1);
            assert_normal_refresh(state, "regression-middle-removed");
            assert_eq!(state.model.remove_rows(&[state.model.len() - 1]), 1);
            assert_normal_refresh(state, "regression-trailing-removed");
            state.model.append_batch_by(
                refresh_fixture_rows(parent, "long", 0, 128),
                compare_windows,
            )?;
            assert_normal_refresh(state, "regression-before-bulk-clear");
            let removed = state.model.len();
            assert!(state.model.clear());
            let cleared = assert_normal_refresh(state, "regression-cleared");
            assert_eq!(cleared.native_deletions, removed);
            assert_eq!(cleared.full_rebuilds, 0);
            state.model.append_batch_by(
                refresh_fixture_rows(parent, "ordinary", 20, 4),
                compare_windows,
            )?;
            assert_normal_refresh(state, "regression-repopulated");

            let metadata = state.rendered_rows[0].values[2..7].to_vec();
            assert_eq!(
                state.model.items()[0].destination_parent(),
                state.model.items()[1].destination_parent()
            );
            let duplicate = state.model.items()[1].current_name().clone();
            assert!(state.model.manual_change_changed(0, duplicate)?);
            refresh_proposal_rows(state, &[0]);
            assert_eq!(
                state.model.items()[0].planned_path(),
                state.model.items()[1].planned_path()
            );
            assert_eq!(
                state.preview_issue_cache.issue(0),
                PreviewRowIssue::DuplicateDestination
            );
            assert_eq!(state.preview_issue_cache.issue(1), PreviewRowIssue::None);
            assert_eq!(state.rendered_rows[0].values[2..7], metadata);
            assert_model_native_rows(state);

            let shared = LegacyText::from("shared-proposal.txt");
            assert!(state.model.manual_change_changed(0, shared.clone())?);
            refresh_proposal_rows(state, &[0]);
            assert_eq!(state.preview_issue_cache.issue(0), PreviewRowIssue::None);
            assert!(state.model.manual_change_changed(1, shared)?);
            refresh_proposal_rows(state, &[1]);
            assert_eq!(
                state.model.items()[0].planned_path(),
                state.model.items()[1].planned_path()
            );
            assert_eq!(
                state.preview_issue_cache.issue(0),
                PreviewRowIssue::DuplicateDestination
            );
            assert_eq!(
                state.preview_issue_cache.issue(1),
                PreviewRowIssue::DuplicateDestination
            );
            assert_model_native_rows(state);
            state.model.reset_proposals()?;
            refresh_proposal_rows(state, &[0, 1]);
            assert_eq!(state.preview_issue_cache.issue(0), PreviewRowIssue::None);
            assert_eq!(state.preview_issue_cache.issue(1), PreviewRowIssue::None);
            let changed = state
                .model
                .prefix_complete_changed(&LegacyText::from("x_"))?;
            refresh_proposal_rows(state, &changed);
            assert_model_native_rows(state);
            let changed = state.model.reset_proposals_changed()?;
            refresh_proposal_rows(state, &changed);
            assert_model_native_rows(state);
            assert_eq!(state.rendered_rows[0].values[2..7], metadata);

            for column in 0..4 {
                state.shown_columns[column] = true;
                update_column_visibility(state, column);
            }
            assert_normal_refresh(state, "regression-auxiliary-visible");
            assert!(
                state
                    .rendered_rows
                    .iter()
                    .all(|row| { row.values[2..7].iter().all(|value| !value.is_empty()) })
            );
            Ok(())
        })??;
        app.close()?;
        Ok(())
    }

    #[test]
    fn full_refresh_native_rows_and_proposals() -> Result<(), Box<dyn std::error::Error>> {
        isolated_native_refresh_case("native_rows_and_proposals", run_native_rows_and_proposals)
    }

    fn run_native_fallback_and_apply_lock() -> Result<(), Box<dyn std::error::Error>> {
        struct ResetFault;
        impl Drop for ResetFault {
            fn drop(&mut self) {
                FAIL_NATIVE_CELL_AFTER_FOR_TEST.with(|slot| slot.set(None));
                FAIL_NATIVE_REBUILD_FOR_TEST.with(|slot| slot.set(false));
                FAIL_NATIVE_INCREMENTAL_FOR_TEST.with(|slot| slot.set(false));
            }
        }
        let _reset = ResetFault;
        let _ole = RefreshTestOle::initialize()?;
        let mut app = RefreshTestApp::new()?;
        app.with_state(|state| -> Result<(), Box<dyn std::error::Error>> {
            refresh_all_rows(state);
            state.model.append_batch_by(
                refresh_fixture_rows(r"C:\refresh-fixture\fault", "ordinary", 0, 4),
                compare_windows,
            )?;
            assert_normal_refresh(state, "regression-fault-initial");

            let changed = state
                .model
                .prefix_complete_changed(&LegacyText::from("first_"))?;
            assert_eq!(changed.len(), 4);
            FAIL_NATIVE_CELL_AFTER_FOR_TEST.with(|slot| slot.set(Some(3)));
            let recovered = measure_refresh(state, "regression-partial-rebuilt", refresh_all_rows);
            assert_model_native_rows(state);
            assert_eq!(recovered.full_rebuilds, 1);
            assert_eq!(recovered.fallback_staged_rows_peak, 4);
            assert!(recovered.normal_staged_rows_peak <= 1);
            assert!(recovered.native_cells >= 3);

            state
                .model
                .prefix_complete_changed(&LegacyText::from("second_"))?;
            FAIL_NATIVE_CELL_AFTER_FOR_TEST.with(|slot| slot.set(Some(2)));
            FAIL_NATIVE_REBUILD_FOR_TEST.with(|slot| slot.set(true));
            let collection = refresh_profile::Collection::begin();
            refresh_all_rows(state);
            let failed = collection.finish("regression-partial-rebuild-failed", state.model.len());
            assert_eq!(failed.full_rebuilds, 1);
            assert_eq!(failed.fallback_staged_rows_peak, 4);
            assert!(!state.preview_synchronization.is_synchronized());
            assert_eq!(state.presentation(0).apply, ApplyPresentation::Blocked);
            FAIL_NATIVE_REBUILD_FOR_TEST.with(|slot| slot.set(false));
            let recovered =
                measure_refresh(state, "regression-rebuild-after-failure", refresh_all_rows);
            assert_model_native_rows(state);
            assert_eq!(recovered.full_rebuilds, 1);

            // The real control has fewer rows than the retained cache.
            // SAFETY: row zero exists in this test-owned live ListView.
            let deleted = unsafe { SendMessageW(state.list_window, LVM_DELETEITEM, 0, 0) };
            assert_ne!(deleted, 0);
            let mismatch =
                measure_refresh(state, "regression-native-count-mismatch", refresh_all_rows);
            assert_model_native_rows(state);
            assert_eq!(mismatch.full_rebuilds, 1);
            assert_eq!(mismatch.fallback_staged_rows_peak, 4);

            state.mark_preview_sync_failed();
            let unsynchronized = measure_refresh(
                state,
                "regression-explicitly-unsynchronized",
                refresh_all_rows,
            );
            assert_model_native_rows(state);
            assert_eq!(unsynchronized.full_rebuilds, 1);
            assert_eq!(unsynchronized.fallback_staged_rows_peak, 4);

            // Reject only the next incremental pass before native dispatch.
            // The authoritative rebuild must then clear the real control.
            FAIL_NATIVE_INCREMENTAL_FOR_TEST.with(|slot| slot.set(true));
            assert!(state.model.clear());
            let recovered = measure_refresh(
                state,
                "regression-incremental-clear-rebuilt",
                refresh_all_rows,
            );
            assert_model_native_rows(state);
            assert_eq!(recovered.native_deletions, 0);
            assert_eq!(recovered.full_rebuilds, 1);
            assert_eq!(recovered.fallback_staged_rows_peak, 0);

            state.model.append_batch_by(
                refresh_fixture_rows(r"C:\refresh-fixture\fault", "ordinary", 10, 4),
                compare_windows,
            )?;
            assert_normal_refresh(state, "regression-after-incremental-clear-rebuild");
            FAIL_NATIVE_INCREMENTAL_FOR_TEST.with(|slot| slot.set(true));
            FAIL_NATIVE_REBUILD_FOR_TEST.with(|slot| slot.set(true));
            assert!(state.model.clear());
            let collection = refresh_profile::Collection::begin();
            refresh_all_rows(state);
            let failed = collection.finish("regression-incremental-clear-rebuild-failed", 0);
            assert_eq!(failed.native_deletions, 0);
            assert_eq!(failed.full_rebuilds, 1);
            assert_eq!(failed.fallback_staged_rows_peak, 0);
            assert!(!state.preview_synchronization.is_synchronized());
            assert_eq!(state.rendered_rows.len(), 4);
            // SAFETY: the test-owned ListView is still live and no native
            // delete ran in either fault-injected path.
            let native_count = unsafe { SendMessageW(state.list_window, LVM_GETITEMCOUNT, 0, 0) };
            assert_eq!(native_count, 4);
            state.model.append_batch_by(
                refresh_fixture_rows(r"C:\refresh-fixture\fault", "ordinary", 20, 1),
                compare_windows,
            )?;
            assert!(
                state
                    .model
                    .manual_change_changed(0, "renamed-after-failed-clear.txt")?
            );
            refresh_preview_count_cache(state);
            // A changed row would be Apply-ready without the retained
            // synchronization failure, so this checks the actual gate.
            assert_eq!(state.presentation(0).apply, ApplyPresentation::Blocked);
            FAIL_NATIVE_REBUILD_FOR_TEST.with(|slot| slot.set(false));
            let recovered = measure_refresh(
                state,
                "regression-incremental-clear-rebuild-after-failure",
                refresh_all_rows,
            );
            assert_model_native_rows(state);
            assert_eq!(recovered.full_rebuilds, 1);
            Ok(())
        })??;
        app.close()?;
        Ok(())
    }

    #[test]
    fn full_refresh_native_fallback_and_apply_lock() -> Result<(), Box<dyn std::error::Error>> {
        isolated_native_refresh_case(
            "native_fallback_and_apply_lock",
            run_native_fallback_and_apply_lock,
        )
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    struct RefreshViewport {
        top: isize,
        horizontal: Option<i32>,
    }

    impl RefreshViewport {
        fn capture(window: HWND) -> Self {
            // SAFETY: scalar top-index query against the live test-owned ListView.
            let top = unsafe { SendMessageW(window, LVM_GETTOPINDEX, 0, 0) };
            let mut info = SCROLLINFO {
                cbSize: size_of::<SCROLLINFO>() as u32,
                fMask: SIF_POS,
                ..SCROLLINFO::default()
            };
            // SAFETY: writable ScrollInfo for the synchronous native query.
            let horizontal =
                (unsafe { GetScrollInfo(window, SB_HORZ, &mut info) } != 0).then_some(info.nPos);
            Self { top, horizontal }
        }
    }

    fn run_native_dates_follow_locale_and_timezone() -> Result<(), Box<dyn std::error::Error>> {
        struct ResetDateEnvironment;
        impl Drop for ResetDateEnvironment {
            fn drop(&mut self) {
                DATE_ENVIRONMENT_FOR_TEST.with(|slot| *slot.borrow_mut() = None);
            }
        }
        let _reset = ResetDateEnvironment;
        let _ole = RefreshTestOle::initialize()?;
        let mut app = RefreshTestApp::new()?;
        app.with_state(|state| -> Result<(), Box<dyn std::error::Error>> {
            refresh_all_rows(state);
            state.model.append_batch_by(
                refresh_fixture_rows(r"C:\refresh-fixture\dates", "ordinary", 0, 2),
                compare_windows,
            )?;
            let utc = registered_test_zone("UTC")?;
            let utc_time = local_systemtime_from_filetime_in_zone(133_497_936_000_000_000, &utc)
                .ok_or("registered UTC conversion failed")?;
            assert_eq!(
                (
                    utc_time.wYear,
                    utc_time.wMonth,
                    utc_time.wDay,
                    utc_time.wHour
                ),
                (2024, 1, 15, 12)
            );
            DATE_ENVIRONMENT_FOR_TEST.with(|slot| {
                *slot.borrow_mut() = Some((wide("en-US"), utc));
            });
            assert_normal_refresh(state, "regression-en-us-utc");
            let utc_dates = state.rendered_rows[0].values[5..7].to_vec();
            assert!(utc_dates.iter().all(|date| !date.is_empty()));

            let tokyo = registered_test_zone("Tokyo Standard Time")?;
            DATE_ENVIRONMENT_FOR_TEST.with(|slot| {
                *slot.borrow_mut() = Some((wide("en-US"), tokyo));
            });
            assert_eq!(
                local_systemtime_from_filetime_in_zone(133_497_936_000_000_000, &tokyo)
                    .ok_or("explicit time-zone conversion failed")?
                    .wHour,
                21
            );
            assert_normal_refresh(state, "regression-en-us-tokyo");
            assert_ne!(state.rendered_rows[0].values[5..7], utc_dates);
            let tokyo_dates = state.rendered_rows[0].values[5..7].to_vec();

            DATE_ENVIRONMENT_FOR_TEST.with(|slot| {
                *slot.borrow_mut() = Some((wide("ko-KR"), tokyo));
            });
            assert_normal_refresh(state, "regression-ko-kr-tokyo");
            assert_ne!(state.rendered_rows[0].values[5..7], tokyo_dates);
            assert!(
                state.rendered_rows[0].values[5..7]
                    .iter()
                    .all(|date| !date.is_empty())
            );
            Ok(())
        })??;
        app.close()?;
        Ok(())
    }

    #[test]
    fn full_refresh_native_dates_follow_locale_and_timezone()
    -> Result<(), Box<dyn std::error::Error>> {
        isolated_native_refresh_case(
            "native_dates_follow_locale_and_timezone",
            run_native_dates_follow_locale_and_timezone,
        )
    }

    fn run_native_viewport_focus_and_close() -> Result<(), Box<dyn std::error::Error>> {
        let _ole = RefreshTestOle::initialize()?;
        let mut app = RefreshTestApp::new()?;
        app.with_state(|state| -> Result<(), Box<dyn std::error::Error>> {
            refresh_all_rows(state);
            state.model.append_batch_by(
                refresh_fixture_rows(r"C:\refresh-fixture\view", "ordinary", 0, 100),
                compare_windows,
            )?;
            assert_normal_refresh(state, "regression-view-initial");
            assert!(apply_native_control_theme(
                state.list_window,
                NativeThemeTarget::FileList,
                ResolvedTheme::Dark,
            ));
            for column in 0..4 {
                state.shown_columns[column] = true;
                update_column_visibility(state, column);
                // SAFETY: this live ListView owns the optional columns and
                // receives only a scalar width for a horizontal overflow.
                unsafe { SendMessageW(state.list_window, LVM_SETCOLUMNWIDTH, column + 3, 500) };
            }
            select_rows_with_focus(state.list_window, &[80, 81], Some(81));
            let mut focus = LVITEMW {
                stateMask: LVIS_FOCUSED,
                state: LVIS_FOCUSED,
                ..LVITEMW::default()
            };
            // SAFETY: row 79 exists and focus is writable storage through the
            // synchronous state change on this test-owned ListView.
            unsafe {
                SendMessageW(
                    state.list_window,
                    LVM_SETITEMSTATE,
                    79,
                    (&mut focus as *mut LVITEMW) as isize,
                )
            };
            // SAFETY: the live ListView accepts scalar vertical and horizontal
            // scroll requests; row 20 exists in the 100-row fixture.
            unsafe {
                SendMessageW(state.list_window, LVM_ENSUREVISIBLE, 20, 0);
                SendMessageW(state.list_window, LVM_SCROLL, 250, 0);
            }
            assert_eq!(selected_indices(state.list_window), vec![80, 81]);
            assert_eq!(focused_index(state.list_window), Some(79));
            let before = RefreshViewport::capture(state.list_window);
            assert!(
                before.top > 0,
                "fixture requires a nonzero vertical viewport"
            );
            assert!(
                before.horizontal.unwrap_or_default() > 0,
                "fixture requires a nonzero horizontal viewport"
            );
            assert_normal_refresh(state, "regression-view-normal");
            assert_eq!(selected_indices(state.list_window), vec![80, 81]);
            assert_eq!(focused_index(state.list_window), Some(79));
            assert_eq!(RefreshViewport::capture(state.list_window), before);

            state.mark_preview_sync_failed();
            let rebuilt = measure_refresh(state, "regression-view-fallback", refresh_all_rows);
            assert_model_native_rows(state);
            assert_eq!(rebuilt.full_rebuilds, 1);
            assert_eq!(selected_indices(state.list_window), vec![80, 81]);
            assert_eq!(focused_index(state.list_window), Some(79));
            assert_eq!(RefreshViewport::capture(state.list_window), before);
            assert!(apply_native_control_theme(
                state.list_window,
                NativeThemeTarget::FileList,
                ResolvedTheme::NativeSystem,
            ));
            Ok(())
        })??;
        app.close()?;
        Ok(())
    }

    #[test]
    fn full_refresh_native_viewport_focus_and_close() -> Result<(), Box<dyn std::error::Error>> {
        isolated_native_refresh_case(
            "native_viewport_focus_and_close",
            run_native_viewport_focus_and_close,
        )
    }

    #[test]
    #[ignore = "diagnostic: optimized native refresh attribution on the prepared VM"]
    fn profile_refresh_stages() -> Result<(), Box<dyn std::error::Error>> {
        struct TestOle;
        impl Drop for TestOle {
            fn drop(&mut self) {
                // SAFETY: paired successful initialization on this same thread.
                unsafe { OleUninitialize() };
            }
        }
        // SAFETY: null is the reserved parameter; the guard balances success.
        let status = unsafe { OleInitialize(null()) };
        if status < 0 {
            return Err(io::Error::other("refresh diagnostic COM initialization failed").into());
        }
        let _ole = TestOle;
        let order = std::env::var("DARKRENAMER_REFRESH_PROFILE_ORDER")?;
        let visible_first = match order.as_str() {
            "hidden-visible" => false,
            "visible-hidden" => true,
            _ => return Err(io::Error::other("invalid frozen refresh column order").into()),
        };
        let mut app = RefreshTestApp::new()?;
        app.with_state(|state| -> Result<(), Box<dyn std::error::Error>> {
            assert_eq!(state.dpi, 96, "fixed refresh diagnostic requires 96 DPI");
            assert_eq!(state.shown_columns, [false; 4]);
            // Frozen metadata snapshots follow the performance fixture names,
            // one extension and 3x42-character long-path segments. File I/O,
            // admission and delivery are deliberately outside this diagnostic.
            let ordinary = r"C:\refresh-fixture\ordinary";
            state.model.append_batch_by(
                refresh_fixture_rows(ordinary, "ordinary", 0, 100),
                compare_windows,
            )?;
            let small = measure_refresh(state, "ordinary-100", refresh_all_rows);
            assert_eq!(small.rows_formatted, 100);
            assert_eq!(small.normal_staged_rows_peak, 1);
            assert_eq!(small.fallback_staged_rows_peak, 0);
            assert_eq!(small.repeated_nonzero_filetime_inputs, 199);
            state.model.append_batch_by(
                refresh_fixture_rows(ordinary, "ordinary", 100, 900),
                compare_windows,
            )?;
            let medium = measure_refresh(state, "ordinary-1000", refresh_all_rows);
            assert_eq!(medium.rows_formatted, 1000);
            assert_eq!(medium.normal_staged_rows_peak, 1);
            assert_eq!(medium.fallback_staged_rows_peak, 0);
            assert_eq!(medium.repeated_nonzero_filetime_inputs, 1999);
            assert!(state.icon_shared.is_none());
            let collection = refresh_profile::Collection::begin();
            // Keep the historical ordinary-10000 operation shape. Model append
            // is outside each stage clock but inside this scenario's envelope.
            for batch in 0..4 {
                state.model.append_batch_by(
                    refresh_fixture_rows(ordinary, "ordinary", 1000 + batch * 2250, 2250),
                    compare_windows,
                )?;
                refresh_all_rows(state);
                assert!(state.preview_synchronization.is_synchronized());
            }
            let large = collection.finish("ordinary-10000", state.model.len());
            assert_eq!(large.rows_formatted, 3250 + 5500 + 7750 + 10000);
            assert_eq!(large.timestamp_values, large.rows_formatted * 2);
            assert_eq!(
                large.render_icon_cache_hits + large.render_icon_cache_misses,
                large.rows_formatted
            );
            assert_eq!(large.ui_shell_calls, 0);
            assert_eq!(large.icon_request_submissions, 0);
            assert_eq!(large.icon_results_drained, 0);
            assert_eq!(large.native_insertions, 9000);
            assert_eq!(large.normal_staged_rows_peak, 1);
            assert_eq!(large.fallback_staged_rows_peak, 0);
            assert_eq!(large.repeated_nonzero_filetime_inputs, 52_996);
            select_rows(state.list_window, &[4999]);
            let unchanged = measure_refresh(state, "ordinary-10000-unchanged", refresh_all_rows);
            assert_eq!(selected_indices(state.list_window), vec![4999]);
            assert_eq!(unchanged.rows_formatted, 10000);
            assert_eq!(unchanged.native_cells, 0);
            assert_eq!(unchanged.native_insertions, 0);
            assert_eq!(unchanged.full_rebuilds, 0);
            assert_eq!(unchanged.normal_staged_rows_peak, 1);
            assert_eq!(unchanged.fallback_staged_rows_peak, 0);
            assert_eq!(unchanged.repeated_nonzero_filetime_inputs, 19_999);
            assert!(state.model.manual_change_changed(4999, "manual.txt")?);
            let one = measure_refresh(state, "one-row-proposal-edit", |state| {
                refresh_proposal_rows(state, &[4999])
            });
            assert_eq!(one.rows_formatted, 0);
            assert_eq!(one.issue_count_input_rows_visited, 1);
            assert_eq!(one.native_cells, 2);
            state.model.reset_proposals()?;
            refresh_proposal_rows(state, &[4999]);
            let changed = state
                .model
                .prefix_complete_changed(&LegacyText::from("x_"))?;
            let whole = measure_refresh(state, "whole-list-proposal-edit", |state| {
                refresh_proposal_rows(state, &changed)
            });
            assert_eq!(whole.rows_formatted, 0);
            assert_eq!(whole.native_cells, 20000);
            let changed = state.model.reset_proposals_changed()?;
            let reset = measure_refresh(state, "whole-list-proposal-reset", |state| {
                refresh_proposal_rows(state, &changed)
            });
            assert_eq!(reset.rows_formatted, 0);
            assert_eq!(reset.native_cells, 20000);
            let long = format!(
                "C:\\refresh-fixture\\long\\{}\\{}\\{}",
                "a".repeat(42),
                "b".repeat(42),
                "c".repeat(42)
            );
            for visible in [visible_first, !visible_first] {
                state.model = LegacyList::new();
                refresh_all_rows(state);
                for column in 0..4 {
                    state.shown_columns[column] = visible;
                    update_column_visibility(state, column);
                }
                state.model.append_batch_by(
                    refresh_fixture_rows(&long, "long", 0, 1000),
                    compare_windows,
                )?;
                let label = if visible {
                    "long-visible"
                } else {
                    "long-hidden"
                };
                let counters = measure_refresh(state, label, refresh_all_rows);
                assert_eq!(counters.rows_formatted, 1000);
                let label = if visible {
                    "long-visible-unchanged"
                } else {
                    "long-hidden-unchanged"
                };
                let counters = measure_refresh(state, label, refresh_all_rows);
                assert_eq!(counters.native_cells, 0);
                assert_eq!(counters.rows_formatted, 1000);
                assert!(state.rendered_rows.iter().all(|row| {
                    row.values[..NATIVE_STATUS_COLUMN_INDEX]
                        .iter()
                        .all(|text| !text.is_empty())
                        && row.values[NATIVE_STATUS_COLUMN_INDEX].is_empty()
                }));
            }
            Ok(())
        })??;
        app.close()?;
        Ok(())
    }

    const SLOW_ICON_TEST_MESSAGE: u32 = WM_APP + 27;
    const SLOW_ICON_TEST_SUBCLASS_ID: usize = 27;

    struct SlowIconTestContext {
        entered: Sender<()>,
        ready: mpsc::Receiver<()>,
        cache: RefCell<HashMap<IconCacheKey, i32>>,
        result: Cell<i32>,
        failed: Cell<bool>,
        retired: Cell<bool>,
        delay_started: Cell<Option<Instant>>,
        delay_finished: Cell<Option<Instant>>,
    }

    struct SlowIconTestWindow {
        window: HWND,
        context: Option<Box<SlowIconTestContext>>,
    }

    impl SlowIconTestWindow {
        fn close(&mut self) -> io::Result<()> {
            if self.window.is_null() {
                return Ok(());
            }
            // SAFETY: this HWND is test-owned on the current thread. Its
            // WM_NCDESTROY callback retires the subclass synchronously.
            let destroyed = unsafe { DestroyWindow(self.window) };
            self.window = null_mut();
            if destroyed == 0 {
                let error = io::Error::last_os_error();
                if let Some(context) = self.context.take() {
                    Box::leak(context);
                }
                return Err(error);
            }
            if !self
                .context
                .as_ref()
                .is_some_and(|context| context.retired.get())
            {
                if let Some(context) = self.context.take() {
                    Box::leak(context);
                }
                return Err(io::Error::other("test HWND subclass was not retired"));
            }
            self.context.take();
            Ok(())
        }
    }

    impl Drop for SlowIconTestWindow {
        fn drop(&mut self) {
            // A failed cleanup leaks the context instead of releasing memory
            // that a still-installed native callback could reference.
            let _ = self.close();
        }
    }

    unsafe extern "system" fn slow_icon_test_subclass(
        window: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        _subclass_id: usize,
        context_ref: usize,
    ) -> LRESULT {
        if message == WM_NCDESTROY {
            // SAFETY: this copied reference points to the boxed context until
            // destruction returns to the owning test thread.
            let context = unsafe { &*(context_ref as *const SlowIconTestContext) };
            // SAFETY: this exact test-owned subclass is removed while its
            // context remains live, before the HWND is destroyed.
            let removed = unsafe {
                RemoveWindowSubclass(
                    window,
                    Some(slow_icon_test_subclass),
                    SLOW_ICON_TEST_SUBCLASS_ID,
                )
            };
            context.retired.set(removed != 0);
            // SAFETY: the native destruction message is forwarded once.
            return unsafe { DefSubclassProc(window, message, wparam, lparam) };
        }
        if message == SLOW_ICON_TEST_MESSAGE && context_ref != 0 {
            // SAFETY: only the owning UI thread dispatches this message. The
            // boxed context remains live until DestroyWindow returns.
            let context = unsafe { &*(context_ref as *const SlowIconTestContext) };
            let outcome = catch_unwind(AssertUnwindSafe(|| {
                if context.entered.send(()).is_err()
                    || context.ready.recv_timeout(Duration::from_secs(1)).is_err()
                {
                    context.failed.set(true);
                    return;
                }
                let item = LegacyListItem::new("injected.BAD", false, 0, 0, 0);
                let Ok(mut cache) = context.cache.try_borrow_mut() else {
                    context.failed.set(true);
                    return;
                };
                let result = cached_file_icon_index(&mut cache, &item, |_, _| {
                    // Deliberate test delay; no filesystem or shell provider is involved.
                    context.delay_started.set(Some(Instant::now()));
                    thread::sleep(Duration::from_millis(150));
                    context.delay_finished.set(Some(Instant::now()));
                    (0, 42)
                });
                context.result.set(result);
            }));
            if outcome.is_err() {
                context.failed.set(true);
            }
            return 0;
        }
        // SAFETY: all other messages retain the native subclass chain.
        unsafe { DefSubclassProc(window, message, wparam, lparam) }
    }

    #[test]
    #[ignore = "diagnostic: controlled 150 ms UI-thread shell-lookup delay"]
    fn injected_slow_icon_lookup_blocks_owned_hwnd_dispatch() -> io::Result<()> {
        // SAFETY: STATIC is a system class; this hidden HWND belongs to the
        // calling test thread and is destroyed on that same thread below.
        let window = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                1,
                1,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if window.is_null() {
            return Err(io::Error::last_os_error());
        }
        let (entered_tx, entered_rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        let (result_tx, result_rx) = mpsc::channel();
        let context = Box::new(SlowIconTestContext {
            entered: entered_tx,
            ready: ready_rx,
            cache: RefCell::new(HashMap::new()),
            result: Cell::new(i32::MIN),
            failed: Cell::new(false),
            retired: Cell::new(false),
            delay_started: Cell::new(None),
            delay_finished: Cell::new(None),
        });
        // SAFETY: the test-owned context has a stable boxed address until
        // confirmed window destruction removes the exact subclass.
        if unsafe {
            SetWindowSubclass(
                window,
                Some(slow_icon_test_subclass),
                SLOW_ICON_TEST_SUBCLASS_ID,
                (&*context as *const SlowIconTestContext) as usize,
            )
        } == 0
        {
            let error = io::Error::last_os_error();
            // SAFETY: failed subclass installation retained no context pointer.
            if unsafe { DestroyWindow(window) } == 0 {
                return Err(io::Error::other(format!(
                    "subclass installation failed ({error}); test HWND cleanup also failed: {}",
                    io::Error::last_os_error()
                )));
            }
            return Err(error);
        }
        let mut owned = SlowIconTestWindow {
            window,
            context: Some(context),
        };
        let window_value = window as usize;
        let probe = thread::Builder::new()
            .name("slow-icon-wm-null-probe".to_owned())
            .spawn(move || {
                if entered_rx.recv_timeout(Duration::from_secs(1)).is_err() {
                    let _ = result_tx.send(None);
                    return;
                }
                let _ = ready_tx.send(());
                let mut reply = 0;
                let started = Instant::now();
                // SAFETY: the copied HWND belongs to this test and remains live
                // until the worker joins. Reset the worker's last-error slot
                // directly before the timed call and read it directly after.
                let status = unsafe {
                    SetLastError(0);
                    SendMessageTimeoutW(
                        window_value as HWND,
                        WM_NULL,
                        0,
                        0,
                        SMTO_ABORTIFHUNG | SMTO_BLOCK,
                        50,
                        &mut reply,
                    )
                };
                let probe_error = if status == 0 {
                    // SAFETY: GetLastError reads only this worker's error slot.
                    unsafe { GetLastError() }
                } else {
                    0
                };
                let _ = result_tx.send(Some((status, probe_error, started, Instant::now())));
            })?;

        // SAFETY: the test HWND dispatches this scalar message on its owner
        // thread. The subclass calls the real cache seam with an injected delay.
        unsafe { SendMessageW(window, SLOW_ICON_TEST_MESSAGE, 0, 0) };
        let probe_result = result_rx.recv_timeout(Duration::from_secs(2));
        // The worker has only a one-second channel wait and a 50 ms native
        // message timeout. Retire it before destroying or recycling its HWND.
        let probe_join = probe.join();
        let mut recovered_reply = 0;
        // SAFETY: the owning thread makes this value-only probe after dispatch.
        let recovered = unsafe {
            SendMessageTimeoutW(
                window,
                WM_NULL,
                0,
                0,
                SMTO_ABORTIFHUNG | SMTO_BLOCK,
                50,
                &mut recovered_reply,
            )
        };
        let context = owned
            .context
            .as_ref()
            .ok_or_else(|| io::Error::other("missing test context"))?;
        let failed = context.failed.get();
        let index = context.result.get();
        let cached_failure = context
            .cache
            .borrow()
            .get(&icon_cache_key(&LegacyText::from("another.bad"), false))
            .copied();
        let delay_started = context.delay_started.get();
        let delay_finished = context.delay_finished.get();
        owned.close()?;
        probe_join.map_err(|_| io::Error::other("probe thread panicked"))?;
        let (blocked, probe_error, probe_started, probe_finished) = probe_result
            .map_err(|_| io::Error::other("bounded cross-thread WM_NULL probe did not finish"))?
            .ok_or_else(|| io::Error::other("injected lookup callback did not start"))?;
        let delay_started =
            delay_started.ok_or_else(|| io::Error::other("injected delay did not start"))?;
        let delay_finished =
            delay_finished.ok_or_else(|| io::Error::other("injected delay did not finish"))?;
        let duration_ms = probe_finished.duration_since(probe_started).as_millis();
        let overlaps_delay = probe_started < delay_finished
            && probe_finished > delay_started
            && probe_finished <= delay_finished;
        let probe_status = if blocked != 0 {
            "success"
        } else if probe_error == ERROR_TIMEOUT {
            "timeout"
        } else {
            "failure_unknown"
        };
        let conclusive = overlaps_delay && probe_status != "failure_unknown";
        let conclusion = if conclusive {
            "measured"
        } else {
            "inconclusive"
        };
        println!(
            "{{\"kind\":\"injected-ui-thread-delay\",\"conclusion\":\"{conclusion}\",\"delay_ms\":150,\"probe_timeout_ms\":50,\"probe_elapsed_ms\":{duration_ms},\"overlaps_delay\":{overlaps_delay},\"probe_status\":\"{probe_status}\",\"probe_error\":{probe_error},\"blocked_status\":{blocked},\"recovered_status\":{recovered}}}"
        );
        if !conclusive {
            return Err(io::Error::other(
                "inconclusive: WM_NULL probe did not time out with a classified result during injected delay",
            ));
        }
        assert!(!failed);
        assert_eq!(index, I_IMAGENONE);
        assert_eq!(cached_failure, Some(I_IMAGENONE));
        assert_eq!(probe_status, "timeout");
        assert_ne!(recovered, 0);
        Ok(())
    }

    #[test]
    #[ignore = "diagnostic: live Shell queries and machine-dependent timings"]
    fn live_shell_icon_lookup_reports_bounded_query_cost() -> io::Result<()> {
        use ::windows::Win32::System::Com::COINIT_APARTMENTTHREADED;

        struct TestCom;
        impl Drop for TestCom {
            fn drop(&mut self) {
                // SAFETY: this guard drops on the same thread after successful COM initialization.
                unsafe { CoUninitialize() };
            }
        }

        // SAFETY: None is the documented reserved argument. The guard balances
        // this thread's successful STA initialization after all shell queries.
        let status = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
        if status.is_err() {
            return Err(io::Error::other(format!(
                "COM STA initialization failed: {status:?}"
            )));
        }
        let _com = TestCom;
        let mut cache = HashMap::new();
        let mut queries = 0_u32;
        let mut cumulative_ns = 0_u128;
        let mut maximum_ns = 0_u128;
        // Use the same fixed miss/hit/clear schedule as the deterministic
        // cache test. The actual Shell decides whether each class resolves;
        // this probe measures real query costs without simulating outcomes.
        let mut names = vec![
            "one.TXT".to_owned(),
            "one.BAD".to_owned(),
            "one.ZERO".to_owned(),
        ];
        names.extend((0..253).map(|index| format!("f.x{index}")));
        names.extend(["two.txt", "two.bad", "two.zero"].map(str::to_owned));
        names.push("f.x253".to_owned());
        names.extend(["three.TXT", "three.BAD", "three.ZERO"].map(str::to_owned));
        names.extend((254..506).map(|index| format!("f.x{index}")));
        names.extend(["four.txt", "four.bad", "four.zero"].map(str::to_owned));
        names.push("f.x506".to_owned());
        names.extend(["five.TXT", "five.BAD", "five.ZERO"].map(str::to_owned));
        assert_eq!(names.len(), 522);
        for name in names {
            let item = LegacyListItem::new(name, false, 0, 0, 0);
            cached_file_icon_index(&mut cache, &item, |key, directory| {
                let started = Instant::now();
                let result = query_shell_icon_index(key, directory);
                let elapsed_ns = started.elapsed().as_nanos();
                queries += 1;
                cumulative_ns += elapsed_ns;
                maximum_ns = maximum_ns.max(elapsed_ns);
                result
            });
            assert!(cache.len() <= 256);
        }
        assert_eq!(queries, 516);
        assert_eq!(cache.len(), 4);
        println!(
            "{{\"kind\":\"live-shell-test-build\",\"accesses\":522,\"queries\":{queries},\"hits\":6,\"cumulative_query_ns\":{cumulative_ns},\"maximum_query_ns\":{maximum_ns}}}"
        );
        Ok(())
    }

    struct BlankBodyTestContext {
        list: HWND,
        resources: AppearanceResources,
        theme: Cell<ResolvedTheme>,
        rows: Cell<usize>,
        postpaints: Cell<usize>,
    }

    unsafe extern "system" fn blank_body_test_parent(
        window: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        _id: usize,
        context: usize,
    ) -> LRESULT {
        if message == WM_NOTIFY && context != 0 && lparam != 0 {
            // SAFETY: the test keeps this boxed context alive through confirmed
            // parent destruction. All mutable callback observations are Cells.
            let context = unsafe { &*(context as *const BlankBodyTestContext) };
            // SAFETY: synchronous WM_NOTIFY carries a readable NMHDR prefix.
            let header = unsafe { &*(lparam as *const NMHDR) };
            if header.hwndFrom == context.list && header.code == NM_CUSTOMDRAW {
                // SAFETY: the exact native ListView source owns this payload.
                let custom = unsafe { &*(lparam as *const NMLVCUSTOMDRAW) };
                if custom.nmcd.dwDrawStage == CDDS_PREPAINT
                    && context.theme.get() == ResolvedTheme::Dark
                {
                    return CDRF_NOTIFYPOSTPAINT as LRESULT;
                }
                if custom.nmcd.dwDrawStage == CDDS_POSTPAINT
                    && context.theme.get() == ResolvedTheme::Dark
                {
                    paint_blank_list_body(
                        context.list,
                        custom.nmcd.hdc,
                        context.resources.workspace_brush(),
                        context.rows.get(),
                    );
                    context.postpaints.set(context.postpaints.get() + 1);
                    return CDRF_DODEFAULT as LRESULT;
                }
            }
        }
        // SAFETY: unhandled native messages are delegated exactly once.
        unsafe { DefSubclassProc(window, message, wparam, lparam) }
    }

    fn apply_test_list_appearance(
        context: &BlankBodyTestContext,
        list: HWND,
        theme: ResolvedTheme,
    ) {
        context.theme.set(theme);

        apply_native_control_theme(list, NativeThemeTarget::FileList, theme);
        // SAFETY: list is the live test-owned ListView. These synchronous
        // messages copy only integral COLORREF values, matching production.
        unsafe {
            SendMessageW(
                list,
                LVM_SETBKCOLOR,
                0,
                TEST_LIST_BACKGROUND_COLORREF as isize,
            );
            SendMessageW(
                list,
                LVM_SETTEXTBKCOLOR,
                0,
                TEST_LIST_BACKGROUND_COLORREF as isize,
            );
            SendMessageW(list, LVM_SETTEXTCOLOR, 0, 0x00f0_f0f0);
        }
    }

    fn blank_list_body_mismatch_count(list: HWND, top: i32) -> io::Result<usize> {
        let mut client = RECT::default();
        // SAFETY: list is live, client remains writable, and redraw is completed
        // before the same HWND is synchronously captured.
        unsafe {
            RedrawWindow(
                list,
                null(),
                null_mut(),
                RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
            );
            UpdateWindow(list);
            if GetClientRect(list, &mut client) == 0 {
                return Err(io::Error::last_os_error());
            }
        }
        let capture = capture_window_pixels(list)?;
        let measurement = capture.measurement();
        if measurement.width < client.right || measurement.height < client.bottom {
            return Err(io::Error::other(
                "native ListView capture does not cover its client area",
            ));
        }
        let bottom = top.saturating_add(48).min(client.bottom.saturating_sub(2));
        capture.solid_color_mismatch_count(
            2,
            top,
            client.right.saturating_sub(2),
            bottom,
            TEST_LIST_BACKGROUND_COLORREF,
        )
    }

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
            // Install the production style set before appearance code queries
            // the ListView-owned infotip Tooltip.
            // SAFETY: list is live and both messages carry only scalar values.
            let tooltip = unsafe {
                SendMessageW(
                    list,
                    LVM_SETEXTENDEDLISTVIEWSTYLE,
                    0,
                    LIST_VIEW_EXTENDED_STYLES as isize,
                );
                SendMessageW(list, LVM_GETTOOLTIPS, 0, 0) as HWND
            };
            assert!(!tooltip.is_null());

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
    fn native_list_body_stays_solid_and_selected_row_retains_status() -> io::Result<()> {
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
        let resources = match AppearanceResources::create(GRAPHITE_DARK) {
            Ok(resources) => resources,
            Err(error) => {
                // SAFETY: parent owns the exact test ListView and no subclass exists yet.
                unsafe { DestroyWindow(parent) };
                return Err(error);
            }
        };
        let context = Box::new(BlankBodyTestContext {
            list,
            resources,
            theme: Cell::new(ResolvedTheme::NativeSystem),
            rows: Cell::new(0),
            postpaints: Cell::new(0),
        });
        // SAFETY: the boxed UI-thread context stays at a stable address through
        // the confirmed parent destruction at the test's single cleanup point.
        if unsafe {
            SetWindowSubclass(
                parent,
                Some(blank_body_test_parent),
                18,
                (&*context as *const BlankBodyTestContext) as usize,
            )
        } == 0
        {
            let error = io::Error::last_os_error();
            // SAFETY: subclass registration failed and retains no context share.
            unsafe { DestroyWindow(parent) };
            return Err(error);
        }
        let result = (|| -> io::Result<()> {
            // SAFETY: list is live and the production extended-style mask is scalar.
            unsafe {
                SendMessageW(
                    list,
                    LVM_SETEXTENDEDLISTVIEWSTYLE,
                    0,
                    LIST_VIEW_EXTENDED_STYLES as isize,
                )
            };
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
                icon_key: IconCacheKey::FileWithoutExtension,
                icon_resolved: true,
            };
            if !rebuild_native_rows(list, &[]) {
                return Err(io::Error::other("could not rebuild an empty native list"));
            }

            // Exercise every live column boundary, including zero-width hidden
            // columns and widths that deliberately require horizontal scrolling.
            for (column, width) in [180, 160, 220].into_iter().enumerate() {
                // SAFETY: list is live and each primary column was inserted above.
                unsafe { SendMessageW(list, LVM_SETCOLUMNWIDTH, column, width as isize) };
            }
            for column in 3..NATIVE_STATUS_COLUMN_INDEX {
                // SAFETY: list is live and each optional column was inserted above.
                unsafe { SendMessageW(list, LVM_SETCOLUMNWIDTH, column, 0) };
            }
            // SAFETY: list is live and the message carries scalar width data.
            unsafe { SendMessageW(list, LVM_SETCOLUMNWIDTH, NATIVE_STATUS_COLUMN_INDEX, 300) };

            // Keep one explicit dark background through every native association
            // transition so these pixel comparisons isolate style decoration
            // instead of conflating it with the production palette transition.
            let mut pixel_results = Vec::with_capacity(6);
            apply_test_list_appearance(&context, list, ResolvedTheme::Dark);
            pixel_results.push((
                "empty-dark",
                blank_list_body_mismatch_count(
                    list,
                    native_list_header_height_px(list).saturating_add(8),
                )?,
            ));

            assert!(!set_native_subitem(null_mut(), 0, 1, &row.values[1]));
            assert!(!rebuild_native_rows(
                null_mut(),
                core::slice::from_ref(&row)
            ));
            if !rebuild_native_rows(list, &[row.clone(), row.clone()]) {
                return Err(io::Error::other("could not rebuild native test rows"));
            }
            context.rows.set(2);
            // Some common-control builds do not expose a movable scroll range
            // until the report contains an item. Scroll only after adding rows.
            // SAFETY: list is live and the message carries scalar scroll data.
            unsafe { SendMessageW(list, LVM_SCROLL, 96, 0) };
            let mut horizontal_scroll = SCROLLINFO {
                cbSize: u32::try_from(size_of::<SCROLLINFO>())
                    .map_err(|_| io::Error::other("invalid scroll info size"))?,
                fMask: SIF_POS,
                ..SCROLLINFO::default()
            };
            // SAFETY: list is live and horizontal_scroll is exact writable ABI storage.
            if unsafe { GetScrollInfo(list, SB_HORZ, &mut horizontal_scroll) } == 0 {
                return Err(io::Error::last_os_error());
            }
            assert!(
                horizontal_scroll.nPos > 0,
                "native ListView did not scroll horizontally"
            );
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
            let status_width = list_column_width(list, NATIVE_STATUS_COLUMN_INDEX);
            let mut last_row = RECT {
                left: LVIR_BOUNDS as i32,
                ..RECT::default()
            };
            // SAFETY: list is live and last_row remains writable for this exact
            // report-view item rectangle query.
            if unsafe {
                SendMessageW(
                    list,
                    LVM_GETITEMRECT,
                    1,
                    (&mut last_row as *mut RECT) as isize,
                )
            } == 0
            {
                return Err(io::Error::other(
                    "could not query the last native row bounds",
                ));
            }
            let blank_body_top = last_row.bottom.saturating_add(8);
            for (label, theme) in [
                ("rows-dark-initial", ResolvedTheme::Dark),
                ("rows-light", ResolvedTheme::Light),
                ("rows-dark-restored", ResolvedTheme::Dark),
                ("rows-native-system", ResolvedTheme::NativeSystem),
            ] {
                apply_test_list_appearance(&context, list, theme);
                pixel_results.push((label, blank_list_body_mismatch_count(list, blank_body_top)?));
                buffer.fill(0);
                // SAFETY: list is live and query/buffer are writable for this
                // synchronous native text retrieval after the theme transition.
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
                assert_eq!(
                    list_column_width(list, NATIVE_STATUS_COLUMN_INDEX),
                    status_width
                );
            }
            if !rebuild_native_rows(list, &[]) {
                return Err(io::Error::other(
                    "could not remove all native rows after theme transitions",
                ));
            }
            context.rows.set(0);
            apply_test_list_appearance(&context, list, ResolvedTheme::Dark);
            pixel_results.push((
                "empty-after-remove-dark",
                blank_list_body_mismatch_count(
                    list,
                    native_list_header_height_px(list).saturating_add(8),
                )?,
            ));
            assert!(
                context.postpaints.get() > 0,
                "real ListView postpaint notification was not routed"
            );
            assert!(
                pixel_results.iter().all(|(_, mismatches)| *mismatches == 0),
                "native ListView blank body contains non-background pixels: {pixel_results:?}",
            );
            Ok(())
        })();
        // SAFETY: parent owns the exact child and its callback context remains
        // live through all synchronous destruction messages. A failed destroy
        // retains the bounded context/brush rather than dangling native refdata.
        if unsafe { DestroyWindow(parent) } == 0 {
            let _retained = Box::into_raw(context);
            return Err(io::Error::last_os_error());
        }
        drop(context);
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
                names.iter().map(|(current, proposed)| PreviewRowInput {
                    parent: &parent,
                    current,
                    proposed,
                    is_directory: false,
                    change: if current == proposed {
                        darknamer_core::PlannedChangeKind::None
                    } else {
                        darknamer_core::PlannedChangeKind::Rename
                    },
                }),
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
