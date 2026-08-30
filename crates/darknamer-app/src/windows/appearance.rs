use std::ffi::c_void;
use std::io;
use std::mem::size_of;
use std::ptr::{null, null_mut};

use ::windows::UI::ViewManagement::{UIColorType, UISettings};
use ::windows::Win32::System::WinRT::{RO_INIT_SINGLETHREADED, RoInitialize, RoUninitialize};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DwmSetWindowAttribute};
use windows_sys::Win32::Graphics::Gdi::{
    COLOR_3DSHADOW, COLOR_BTNFACE, COLOR_BTNTEXT, COLOR_GRAYTEXT, COLOR_HIGHLIGHT,
    COLOR_HIGHLIGHTTEXT, COLOR_MENU, COLOR_MENUTEXT, COLOR_WINDOW, COLOR_WINDOWFRAME,
    COLOR_WINDOWTEXT, CreateSolidBrush, DT_CALCRECT, DT_CENTER, DT_HIDEPREFIX, DT_LEFT,
    DT_NOPREFIX, DT_RIGHT, DT_SINGLELINE, DT_VCENTER, DT_WORDBREAK, DeleteObject, DrawFocusRect,
    DrawTextW, FillRect, FrameRect, GetDC, GetSysColor, GetSysColorBrush, HBRUSH, RDW_ALLCHILDREN,
    RDW_ERASE, RDW_INVALIDATE, RedrawWindow, ReleaseDC, SelectObject, SetBkMode, SetTextColor,
    TRANSPARENT,
};
use windows_sys::Win32::UI::Controls::{
    DRAWITEMSTRUCT, MEASUREITEMSTRUCT, ODS_CHECKED, ODS_DISABLED, ODS_FOCUS, ODS_GRAYED,
    ODS_HOTLIGHT, ODS_NOACCEL, ODS_SELECTED, ODT_BUTTON, ODT_MENU,
};
use windows_sys::Win32::UI::Controls::{LVM_SETBKCOLOR, LVM_SETTEXTBKCOLOR, LVM_SETTEXTCOLOR};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetWindowTextLengthW, GetWindowTextW, MENUINFO, MIM_APPLYTOSUBMENUS, MIM_BACKGROUND,
    SendMessageW, SetMenuInfo,
};

use super::*;

/// Balances a successful WinRT initialization on the native UI thread.
pub(super) struct WinRtGuard;

impl WinRtGuard {
    pub(super) fn initialize() -> Option<Self> {
        // SAFETY: the UI thread was initialized as STA by OleInitialize. A
        // successful S_OK or S_FALSE result is balanced by this guard's Drop.
        unsafe { RoInitialize(RO_INIT_SINGLETHREADED) }
            .ok()
            .map(|()| Self)
    }
}

impl Drop for WinRtGuard {
    fn drop(&mut self) {
        // SAFETY: this guard exists only for a successful RoInitialize call and
        // drops on the same UI thread after every UISettings query is complete.
        unsafe { RoUninitialize() };
    }
}

#[derive(Debug)]
struct OwnedSolidBrush(HBRUSH);

impl OwnedSolidBrush {
    fn create(color: u32) -> io::Result<Self> {
        // SAFETY: color is a semantic COLORREF value and ownership of the new
        // brush transfers directly into this wrapper.
        let brush = unsafe { CreateSolidBrush(color) };
        if brush.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self(brush))
        }
    }

    const fn as_raw(&self) -> HBRUSH {
        self.0
    }
}

impl Drop for OwnedSolidBrush {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: this wrapper solely owns the unselected solid brush.
            unsafe { DeleteObject(self.0) };
            self.0 = null_mut();
        }
    }
}

/// GDI resources for the app-owned native surfaces only.
pub(super) struct AppearanceResources {
    window: OwnedSolidBrush,
    panel: OwnedSolidBrush,
    workspace: OwnedSolidBrush,
    status: OwnedSolidBrush,
    drop_overlay: OwnedSolidBrush,
    header: OwnedSolidBrush,
    dialog: OwnedSolidBrush,
    control_normal: OwnedSolidBrush,
    control_hover: OwnedSolidBrush,
    control_pressed: OwnedSolidBrush,
    control_disabled: OwnedSolidBrush,
    border: OwnedSolidBrush,
    palette: SemanticPalette,
}

impl AppearanceResources {
    pub(super) fn create(palette: SemanticPalette) -> io::Result<Self> {
        Ok(Self {
            window: OwnedSolidBrush::create(palette.surface_window)?,
            panel: OwnedSolidBrush::create(palette.surface_panel)?,
            workspace: OwnedSolidBrush::create(palette.surface_workspace)?,
            status: OwnedSolidBrush::create(palette.surface_status)?,
            drop_overlay: OwnedSolidBrush::create(palette.surface_drop)?,
            header: OwnedSolidBrush::create(palette.surface_header)?,
            dialog: OwnedSolidBrush::create(palette.surface_dialog)?,
            control_normal: OwnedSolidBrush::create(palette.control_normal)?,
            control_hover: OwnedSolidBrush::create(palette.control_hover)?,
            control_pressed: OwnedSolidBrush::create(palette.control_pressed)?,
            control_disabled: OwnedSolidBrush::create(palette.control_disabled)?,
            border: OwnedSolidBrush::create(palette.border)?,
            palette,
        })
    }

    pub(super) const fn palette(&self) -> SemanticPalette {
        self.palette
    }

    pub(super) const fn window_brush(&self) -> HBRUSH {
        self.window.as_raw()
    }

    pub(super) const fn header_brush(&self) -> HBRUSH {
        self.header.as_raw()
    }

    pub(super) const fn dialog_brush(&self) -> HBRUSH {
        self.dialog.as_raw()
    }

    pub(super) const fn control_brush(&self, pressed: bool, hot: bool, disabled: bool) -> HBRUSH {
        if disabled {
            self.control_disabled.as_raw()
        } else if pressed {
            self.control_pressed.as_raw()
        } else if hot {
            self.control_hover.as_raw()
        } else {
            self.control_normal.as_raw()
        }
    }

    pub(super) const fn border_brush(&self) -> HBRUSH {
        self.border.as_raw()
    }
}

#[derive(Clone, Copy)]
pub(super) struct StaticControlColors {
    pub(super) brush: HBRUSH,
    pub(super) text: u32,
    pub(super) background: u32,
}

pub(super) fn query_system_theme() -> Option<ResolvedTheme> {
    let settings = UISettings::new().ok()?;
    let foreground = settings.GetColorValue(UIColorType::Foreground).ok()?;
    Some(theme_from_foreground(
        foreground.R,
        foreground.G,
        foreground.B,
    ))
}

pub(super) fn refresh_system_theme(state: &mut AppState) {
    state.system_theme = query_system_theme();
}

pub(super) fn static_control_colors(state: &AppState, child: HWND) -> Option<StaticControlColors> {
    let resources = state.appearance_resources.as_ref()?;
    if child == state.status_message {
        Some(StaticControlColors {
            brush: resources.status.as_raw(),
            text: resources.palette.text_primary,
            background: resources.palette.surface_status,
        })
    } else if child == state.status_count {
        Some(StaticControlColors {
            brush: resources.status.as_raw(),
            text: resources.palette.text_secondary,
            background: resources.palette.surface_status,
        })
    } else if child == state.empty_instruction {
        Some(StaticControlColors {
            brush: resources.workspace.as_raw(),
            text: resources.palette.text_primary,
            background: resources.palette.surface_workspace,
        })
    } else if child == state.empty_safety {
        Some(StaticControlColors {
            brush: resources.workspace.as_raw(),
            text: resources.palette.text_secondary,
            background: resources.palette.surface_workspace,
        })
    } else if child == state.drop_overlay {
        Some(StaticControlColors {
            brush: resources.drop_overlay.as_raw(),
            text: resources.palette.text_primary,
            background: resources.palette.surface_drop,
        })
    } else if state
        .left_rail
        .as_ref()
        .is_some_and(|rail| rail.is_separator(child))
        || state
            .right_rail
            .as_ref()
            .is_some_and(|rail| rail.is_separator(child))
    {
        Some(StaticControlColors {
            brush: resources.panel.as_raw(),
            text: resources.palette.text_secondary,
            background: resources.palette.surface_panel,
        })
    } else {
        None
    }
}

pub(super) fn erase_themed_background(
    window: HWND,
    dc: HDC,
    resources: Option<&AppearanceResources>,
) {
    let mut rect = windows_sys::Win32::Foundation::RECT::default();
    // SAFETY: window/dc are live for WM_ERASEBKGND and rect is writable.
    if unsafe { windows_sys::Win32::UI::WindowsAndMessaging::GetClientRect(window, &mut rect) } == 0
    {
        return;
    }
    let brush = resources.map_or_else(
        || {
            // SAFETY: COLOR_WINDOW is a process-global cached system brush.
            unsafe { GetSysColorBrush(COLOR_WINDOW) }
        },
        AppearanceResources::window_brush,
    );
    // SAFETY: dc and brush are live; rect is bounded to the client area.
    unsafe { FillRect(dc, &rect, brush) };
}

pub(super) fn draw_owner_button(resources: Option<&AppearanceResources>, lparam: LPARAM) -> bool {
    let draw = lparam as *const DRAWITEMSTRUCT;
    if draw.is_null() {
        return false;
    }
    // SAFETY: WM_DRAWITEM supplies readable DRAWITEMSTRUCT storage synchronously.
    let draw = unsafe { &*draw };
    if draw.CtlType != ODT_BUTTON || draw.hwndItem.is_null() || draw.hDC.is_null() {
        return false;
    }
    let disabled = draw.itemState & (ODS_DISABLED | ODS_GRAYED) != 0;
    let pressed = draw.itemState & ODS_SELECTED != 0;
    let hot = draw.itemState & ODS_HOTLIGHT != 0;
    let (background, border, text) = if let Some(resources) = resources {
        let palette = resources.palette;
        let background = resources.control_brush(pressed, hot, disabled);
        (
            background,
            resources.border.as_raw(),
            if disabled {
                palette.text_disabled
            } else {
                palette.text_primary
            },
        )
    } else {
        // SAFETY: system color/brush queries return cached process-global values.
        unsafe {
            (
                GetSysColorBrush(if pressed {
                    COLOR_3DSHADOW
                } else {
                    COLOR_BTNFACE
                }),
                GetSysColorBrush(COLOR_WINDOWFRAME),
                GetSysColor(if disabled {
                    COLOR_GRAYTEXT
                } else {
                    COLOR_BTNTEXT
                }),
            )
        }
    };
    // SAFETY: draw fields and GDI objects remain live through this synchronous paint.
    unsafe {
        FillRect(draw.hDC, &draw.rcItem, background);
        FrameRect(draw.hDC, &draw.rcItem, border);
        SetBkMode(draw.hDC, TRANSPARENT as i32);
        SetTextColor(draw.hDC, text);
    }
    // SAFETY: hwndItem is the live owner-draw button.
    let length = unsafe { GetWindowTextLengthW(draw.hwndItem) };
    if length > 0 {
        let capacity = usize::try_from(length)
            .unwrap_or_default()
            .saturating_add(1);
        let mut label = vec![0_u16; capacity];
        // SAFETY: label has length+1 writable units and hwndItem remains live.
        let copied = unsafe { GetWindowTextW(draw.hwndItem, label.as_mut_ptr(), length + 1) };
        if copied > 0 {
            let mut text_rect = draw.rcItem;
            if pressed {
                text_rect.left = text_rect.left.saturating_add(1);
                text_rect.top = text_rect.top.saturating_add(1);
            }
            // SAFETY: label contains copied readable UTF-16 and text_rect is writable.
            unsafe {
                DrawTextW(
                    draw.hDC,
                    label.as_ptr(),
                    copied,
                    &mut text_rect,
                    DT_CENTER | DT_VCENTER | DT_WORDBREAK | DT_NOPREFIX,
                )
            };
        }
    }
    if draw.itemState & ODS_FOCUS != 0 {
        let mut focus = draw.rcItem;
        focus.left = focus.left.saturating_add(3);
        focus.top = focus.top.saturating_add(3);
        focus.right = focus.right.saturating_sub(3);
        focus.bottom = focus.bottom.saturating_sub(3);
        // SAFETY: dc is live and focus remains inside the item rectangle.
        unsafe { DrawFocusRect(draw.hDC, &focus) };
    }
    true
}

pub(super) fn draw_owner_menu(resources: Option<&AppearanceResources>, lparam: LPARAM) -> bool {
    let draw = lparam as *const DRAWITEMSTRUCT;
    if draw.is_null() {
        return false;
    }
    // SAFETY: WM_DRAWITEM supplies readable DRAWITEMSTRUCT storage synchronously.
    let draw = unsafe { &*draw };
    if draw.CtlType != ODT_MENU || draw.hDC.is_null() {
        return false;
    }
    let Some(label) = owner_menu_label(draw.itemData) else {
        return false;
    };
    let disabled = draw.itemState & (ODS_DISABLED | ODS_GRAYED) != 0;
    let selected = draw.itemState & ODS_SELECTED != 0;
    let (background, text) = if let Some(resources) = resources {
        let palette = resources.palette();
        (
            if selected {
                resources.control_brush(false, true, disabled)
            } else {
                resources.window_brush()
            },
            if disabled {
                palette.text_disabled
            } else {
                palette.text_primary
            },
        )
    } else {
        // SAFETY: system color/brush queries return cached process-global values.
        unsafe {
            (
                GetSysColorBrush(if selected {
                    COLOR_HIGHLIGHT
                } else {
                    COLOR_MENU
                }),
                GetSysColor(if disabled {
                    COLOR_GRAYTEXT
                } else if selected {
                    COLOR_HIGHLIGHTTEXT
                } else {
                    COLOR_MENUTEXT
                }),
            )
        }
    };
    // SAFETY: draw DC/item rect and selected brush remain live for this callback.
    unsafe {
        FillRect(draw.hDC, &draw.rcItem, background);
        SetBkMode(draw.hDC, TRANSPARENT as i32);
        SetTextColor(draw.hDC, text);
    }
    let item_height = (draw.rcItem.bottom - draw.rcItem.top).max(1);
    let padding = item_height / 3;
    let mut content = draw.rcItem;
    content.left = content
        .left
        .saturating_add(item_height)
        .saturating_add(padding);
    content.right = content.right.saturating_sub(padding);
    let prefix = if draw.itemState & ODS_NOACCEL != 0 {
        DT_HIDEPREFIX
    } else {
        0
    };
    let (primary, shortcut) = label
        .split_once('\t')
        .map_or((label.as_str(), None), |parts| (parts.0, Some(parts.1)));
    let primary = wide(primary);
    // SAFETY: text buffers and rect remain live for synchronous menu drawing.
    unsafe {
        DrawTextW(
            draw.hDC,
            primary.as_ptr(),
            i32::try_from(primary.len().saturating_sub(1)).unwrap_or(i32::MAX),
            &mut content,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | prefix,
        )
    };
    if let Some(shortcut) = shortcut {
        let shortcut = wide(shortcut);
        // SAFETY: same live DC/rect and terminated shortcut buffer.
        unsafe {
            DrawTextW(
                draw.hDC,
                shortcut.as_ptr(),
                i32::try_from(shortcut.len().saturating_sub(1)).unwrap_or(i32::MAX),
                &mut content,
                DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
            )
        };
    }
    if draw.itemState & ODS_CHECKED != 0 {
        let check = wide("✓");
        let mut check_rect = draw.rcItem;
        check_rect.right = check_rect.left.saturating_add(item_height);
        // SAFETY: same live DC/rect and one-glyph terminated buffer.
        unsafe {
            DrawTextW(
                draw.hDC,
                check.as_ptr(),
                1,
                &mut check_rect,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
            )
        };
    }
    true
}

pub(super) fn measure_owner_menu(window: HWND, font: HFONT, dpi: u32, lparam: LPARAM) -> bool {
    let measure = lparam as *mut MEASUREITEMSTRUCT;
    if measure.is_null() {
        return false;
    }
    // SAFETY: WM_MEASUREITEM supplies writable storage synchronously.
    let measure = unsafe { &mut *measure };
    if measure.CtlType != ODT_MENU {
        return false;
    }
    let Some(label) = owner_menu_label(measure.itemData) else {
        return false;
    };
    let label = wide(&label);
    // SAFETY: window/font are live UI resources; the DC is released below.
    let dc = unsafe { GetDC(window) };
    let mut rect = windows_sys::Win32::Foundation::RECT::default();
    if !dc.is_null() {
        // SAFETY: font remains AppState-owned beyond this synchronous measurement.
        let previous = unsafe { SelectObject(dc, font) };
        // SAFETY: label/rect/DC are live for this calculation-only draw.
        unsafe {
            DrawTextW(
                dc,
                label.as_ptr(),
                i32::try_from(label.len().saturating_sub(1)).unwrap_or(i32::MAX),
                &mut rect,
                DT_CALCRECT | DT_SINGLELINE,
            )
        };
        if !previous.is_null() {
            // SAFETY: restore the exact object returned by SelectObject.
            unsafe { SelectObject(dc, previous) };
        }
        // SAFETY: release the DC acquired from this exact window.
        unsafe { ReleaseDC(window, dc) };
    }
    measure.itemWidth = u32::try_from(
        (rect.right - rect.left)
            .max(0)
            .saturating_add(scale_dip(36, dpi)),
    )
    .unwrap_or(u32::MAX);
    measure.itemHeight = u32::try_from(
        (rect.bottom - rect.top)
            .max(scale_dip(16, dpi))
            .saturating_add(scale_dip(8, dpi)),
    )
    .unwrap_or(u32::MAX);
    true
}

fn apply_menu_background(menu: HMENU, resources: Option<&AppearanceResources>) {
    if menu.is_null() {
        return;
    }
    let background = resources.map_or_else(
        || {
            // SAFETY: COLOR_MENU is a process-global cached system brush.
            unsafe { GetSysColorBrush(COLOR_MENU) }
        },
        AppearanceResources::window_brush,
    );
    let info = MENUINFO {
        cbSize: size_of::<MENUINFO>() as u32,
        fMask: MIM_BACKGROUND | MIM_APPLYTOSUBMENUS,
        hbrBack: background,
        ..MENUINFO::default()
    };
    // SAFETY: menu is live and info is readable for this synchronous update.
    unsafe { SetMenuInfo(menu, &info) };
}

pub(super) fn apply_native_appearance(window: HWND, state: &mut AppState) -> io::Result<()> {
    let resolved = state.resolved_appearance();
    let palette = semantic_palette(resolved.theme);
    let replacement = palette.map(AppearanceResources::create).transpose()?;

    if let Some(palette) = palette {
        if let Some(rail) = state.left_rail.as_mut() {
            rail.set_apply_keyline_color(palette.apply_keyline)?;
        }
        if let Some(rail) = state.right_rail.as_mut() {
            rail.set_apply_keyline_color(palette.apply_keyline)?;
        }
    }

    state.appearance_resources = replacement;
    apply_menu_background(state.menu, state.appearance_resources.as_ref());
    let (list_background, list_text) = palette.map_or_else(
        || {
            // SAFETY: these process-global system colors are integral values
            // re-queried whenever the relevant system messages arrive.
            unsafe { (GetSysColor(COLOR_WINDOW), GetSysColor(COLOR_WINDOWTEXT)) }
        },
        |palette| (palette.surface_workspace, palette.text_primary),
    );
    // SAFETY: list_window is the live ListView owned by AppState. These messages
    // copy integral COLORREF values and retain no caller pointer.
    unsafe {
        SendMessageW(
            state.list_window,
            LVM_SETBKCOLOR,
            0,
            list_background as isize,
        );
        SendMessageW(
            state.list_window,
            LVM_SETTEXTBKCOLOR,
            0,
            list_background as isize,
        );
        SendMessageW(state.list_window, LVM_SETTEXTCOLOR, 0, list_text as isize);
    }
    for rail in [&state.left_rail, &state.right_rail].into_iter().flatten() {
        rail.set_separators_visible(resolved.appearance.show_separators);
    }
    apply_dwm_title_frame(window, state, resolved.theme);
    // SAFETY: window is the live top-level HWND. One invalidation repaints all
    // children after every brush and ListView color has been installed.
    unsafe {
        RedrawWindow(
            window,
            null(),
            null_mut(),
            RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
        )
    };
    Ok(())
}

pub(super) fn apply_native_appearance_nonblocking(window: HWND, state: &mut AppState) {
    if let Err(error) = apply_native_appearance(window, state) {
        state.set_transient_status(format!(
            "모양 설정을 화면에 적용하지 못했습니다. 파일 작업에는 영향이 없습니다: {error}"
        ));
    }
}

fn apply_dwm_title_frame(window: HWND, state: &mut AppState, theme: ResolvedTheme) {
    let DwmFrameAction::SetDark(dark) = dwm_frame_action(theme, state.dwm_dark_frame_requested)
    else {
        // NativeSystem performs no initial or repeated override. A successful
        // prior dark request is explicitly cleared by the SetDark(false) case.
        return;
    };
    let enabled = i32::from(dark);
    // SAFETY: window is the live top-level HWND and enabled is retained for the
    // complete synchronous documented DWM attribute call. Failure is a
    // best-effort capability result and never changes application safety state.
    let result = unsafe {
        DwmSetWindowAttribute(
            window,
            DWMWA_USE_IMMERSIVE_DARK_MODE as u32,
            (&raw const enabled).cast::<c_void>(),
            size_of::<i32>() as u32,
        )
    };
    if result >= 0 {
        state.dwm_dark_frame_requested = dark;
    }
}

pub(super) fn apply_auxiliary_dwm_title_frame(window: HWND, theme: ResolvedTheme) {
    let enabled = i32::from(matches!(theme, ResolvedTheme::Dark));
    // SAFETY: window is a live top-level auxiliary HWND and enabled remains
    // readable for the complete synchronous DWM call.
    unsafe {
        DwmSetWindowAttribute(
            window,
            DWMWA_USE_IMMERSIVE_DARK_MODE as u32,
            (&raw const enabled).cast::<c_void>(),
            size_of::<i32>() as u32,
        )
    };
}
