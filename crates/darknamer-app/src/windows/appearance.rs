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
    COLOR_HIGHLIGHTTEXT, COLOR_INFOBK, COLOR_INFOTEXT, COLOR_MENU, COLOR_MENUTEXT, COLOR_WINDOW,
    COLOR_WINDOWFRAME, COLOR_WINDOWTEXT, CreateSolidBrush, DT_CALCRECT, DT_CENTER, DT_END_ELLIPSIS,
    DT_HIDEPREFIX, DT_LEFT, DT_NOPREFIX, DT_RIGHT, DT_SINGLELINE, DT_VCENTER, DT_WORDBREAK,
    DeleteObject, DrawFocusRect, DrawTextW, FillRect, FrameRect, GetDC, GetSysColor,
    GetSysColorBrush, GetWindowDC, HBRUSH, HDC, RDW_ALLCHILDREN, RDW_ERASE, RDW_FRAME,
    RDW_INVALIDATE, RedrawWindow, ReleaseDC, SelectObject, SetBkMode, SetTextColor, TRANSPARENT,
};
use windows_sys::Win32::UI::Controls::{
    CDDS_PREPAINT, CDIS_DEFAULT, CDIS_DISABLED, CDIS_FOCUS, CDIS_HOT, CDIS_SELECTED,
    CDRF_DODEFAULT, CDRF_SKIPDEFAULT, DRAWITEMSTRUCT, MEASUREITEMSTRUCT, NM_CUSTOMDRAW,
    NMCUSTOMDRAW, ODS_CHECKED, ODS_DEFAULT, ODS_DISABLED, ODS_FOCUS, ODS_GRAYED, ODS_HOTLIGHT,
    ODS_NOACCEL, ODS_SELECTED, ODT_BUTTON, ODT_MENU, ODT_STATIC, SetWindowTheme, TTM_SETTIPBKCOLOR,
    TTM_SETTIPTEXTCOLOR,
};
use windows_sys::Win32::UI::Controls::{LVM_SETBKCOLOR, LVM_SETTEXTBKCOLOR, LVM_SETTEXTCOLOR};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetMenuBarInfo, GetWindowTextLengthW, GetWindowTextW, MENUBARINFO, MENUINFO,
    MIM_APPLYTOSUBMENUS, MIM_BACKGROUND, OBJID_MENU, PostMessageW, SendMessageW, SetMenuInfo,
    WM_GETFONT,
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

struct OwnedWindowDc {
    window: HWND,
    dc: HDC,
}

impl OwnedWindowDc {
    fn acquire(window: HWND) -> Option<Self> {
        // SAFETY: window is the live top-level HWND. A successful window DC is
        // paired with ReleaseDC by this wrapper on every subsequent path.
        let dc = unsafe { GetWindowDC(window) };
        (!dc.is_null()).then_some(Self { window, dc })
    }

    const fn as_raw(&self) -> HDC {
        self.dc
    }
}

impl Drop for OwnedWindowDc {
    fn drop(&mut self) {
        if !self.dc.is_null() {
            // SAFETY: this is the exact DC returned for this HWND by GetWindowDC.
            unsafe { ReleaseDC(self.window, self.dc) };
            self.dc = null_mut();
        }
    }
}

/// GDI resources for the app-owned native surfaces only.
pub(super) struct AppearanceResources {
    window: OwnedSolidBrush,
    workspace: OwnedSolidBrush,
    status: OwnedSolidBrush,
    drop_overlay: OwnedSolidBrush,
    header: OwnedSolidBrush,
    dialog: OwnedSolidBrush,
    control_normal: OwnedSolidBrush,
    control_hover: OwnedSolidBrush,
    control_pressed: OwnedSolidBrush,
    control_disabled: OwnedSolidBrush,
    apply_readiness: OwnedSolidBrush,
    border: OwnedSolidBrush,
    palette: SemanticPalette,
}

impl AppearanceResources {
    pub(super) fn create(palette: SemanticPalette) -> io::Result<Self> {
        Ok(Self {
            window: OwnedSolidBrush::create(palette.surface_window)?,
            workspace: OwnedSolidBrush::create(palette.surface_workspace)?,
            status: OwnedSolidBrush::create(palette.surface_status)?,
            drop_overlay: OwnedSolidBrush::create(palette.surface_drop)?,
            header: OwnedSolidBrush::create(palette.surface_header)?,
            dialog: OwnedSolidBrush::create(palette.surface_dialog)?,
            control_normal: OwnedSolidBrush::create(palette.control_normal)?,
            control_hover: OwnedSolidBrush::create(palette.control_hover)?,
            control_pressed: OwnedSolidBrush::create(palette.control_pressed)?,
            control_disabled: OwnedSolidBrush::create(palette.control_disabled)?,
            apply_readiness: OwnedSolidBrush::create(palette.apply_keyline)?,
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

    pub(super) const fn status_brush(&self) -> HBRUSH {
        self.status.as_raw()
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

    pub(super) const fn control_normal_brush(&self) -> HBRUSH {
        self.control_normal.as_raw()
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
    } else {
        None
    }
}

pub(super) fn erase_themed_background(
    window: HWND,
    dc: HDC,
    resources: Option<&AppearanceResources>,
    status: StatusChromeGeometry,
    workspace: WorkspaceChromeGeometry,
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
    let status_brush = resources.map_or_else(
        || {
            // SAFETY: COLOR_WINDOW is a process-global cached system brush.
            unsafe { GetSysColorBrush(COLOR_WINDOW) }
        },
        AppearanceResources::status_brush,
    );
    let separator_brush = resources.map_or_else(
        || {
            // SAFETY: COLOR_3DSHADOW is a process-global cached system brush.
            unsafe { GetSysColorBrush(COLOR_3DSHADOW) }
        },
        AppearanceResources::border_brush,
    );
    let outer = RECT {
        left: status.outer.x,
        top: status.outer.y,
        right: status.outer.right(),
        bottom: status.outer.bottom(),
    };
    let top_line = RECT {
        left: status.outer.x,
        top: status.outer.y,
        right: status
            .top_line_right
            .clamp(status.outer.x, status.outer.right()),
        bottom: status
            .outer
            .y
            .saturating_add(i32::from(status.outer.height > 0)),
    };
    let boundary = status
        .message_count_boundary
        .clamp(status.outer.x, status.top_line_right);
    let divider = RECT {
        left: boundary,
        top: top_line.bottom,
        right: boundary.saturating_add(1),
        bottom: status.outer.bottom(),
    };
    let left_list_divider = RECT {
        left: workspace.left_list_divider.x,
        top: workspace.left_list_divider.y,
        right: workspace.left_list_divider.right(),
        bottom: workspace.left_list_divider.bottom(),
    };
    let right_list_divider = RECT {
        left: workspace.right_list_divider.x,
        top: workspace.right_list_divider.y,
        right: workspace.right_list_divider.right(),
        bottom: workspace.right_list_divider.bottom(),
    };
    // SAFETY: dc and all selected brushes are live. Every rectangle is derived
    // from the current client layout and checked for positive area before use.
    unsafe {
        FillRect(dc, &rect, brush);
        if outer.left < outer.right && outer.top < outer.bottom {
            FillRect(dc, &outer, status_brush);
        }
        if top_line.left < top_line.right && top_line.top < top_line.bottom {
            FillRect(dc, &top_line, separator_brush);
        }
        for divider in [left_list_divider, right_list_divider] {
            if divider.left < divider.right && divider.top < divider.bottom {
                FillRect(dc, &divider, separator_brush);
            }
        }
        if boundary > status.outer.x
            && boundary < status.top_line_right
            && divider.top < divider.bottom
        {
            FillRect(dc, &divider, separator_brush);
        }
    }
}

pub(super) fn draw_owner_button(resources: Option<&AppearanceResources>, lparam: LPARAM) -> bool {
    draw_owner_button_with_readiness(resources, None, BASE_DPI, lparam)
}

pub(super) fn draw_owner_rail_button(
    resources: Option<&AppearanceResources>,
    apply_readiness_button: Option<HWND>,
    dpi: u32,
    lparam: LPARAM,
) -> bool {
    draw_owner_button_with_readiness(resources, apply_readiness_button, dpi, lparam)
}

fn draw_owner_button_with_readiness(
    resources: Option<&AppearanceResources>,
    apply_readiness_button: Option<HWND>,
    dpi: u32,
    lparam: LPARAM,
) -> bool {
    let draw = lparam as *const DRAWITEMSTRUCT;
    if draw.is_null() {
        return false;
    }
    // SAFETY: WM_DRAWITEM supplies readable DRAWITEMSTRUCT storage synchronously.
    let draw = unsafe { &*draw };
    if draw.CtlType != ODT_BUTTON || draw.hwndItem.is_null() || draw.hDC.is_null() {
        return false;
    }
    paint_button(
        resources,
        draw.hwndItem,
        u16::try_from(draw.CtlID)
            .ok()
            .and_then(command_ui_spec)
            .filter(|spec| spec.rail.is_some())
            .map(|spec| spec.rail_label),
        draw.hDC,
        draw.rcItem,
        (apply_readiness_button == Some(draw.hwndItem)).then_some(dpi),
        ButtonDrawState {
            disabled: draw.itemState & (ODS_DISABLED | ODS_GRAYED) != 0,
            pressed: draw.itemState & ODS_SELECTED != 0,
            hot: draw.itemState & ODS_HOTLIGHT != 0,
            focused: draw.itemState & ODS_FOCUS != 0,
            default: draw.itemState & ODS_DEFAULT != 0,
        },
    );
    true
}

pub(super) fn draw_owner_separator(
    resources: Option<&AppearanceResources>,
    separator: HWND,
    lparam: LPARAM,
) -> bool {
    if separator.is_null() {
        return false;
    }
    let draw = lparam as *const DRAWITEMSTRUCT;
    if draw.is_null() {
        return false;
    }
    // SAFETY: WM_DRAWITEM supplies readable DRAWITEMSTRUCT storage synchronously.
    let draw = unsafe { &*draw };
    if draw.CtlType != ODT_STATIC || draw.hwndItem != separator || draw.hDC.is_null() {
        return false;
    }
    let brush = resources.map_or_else(
        || {
            // SAFETY: system color brushes are process-global cached objects and
            // retain native/Forced Colors behavior.
            unsafe { GetSysColorBrush(COLOR_3DSHADOW) }
        },
        AppearanceResources::border_brush,
    );
    // SAFETY: callback DC/rect and selected palette-or-system brush are live for
    // this decorative synchronous fill.
    unsafe { FillRect(draw.hDC, &draw.rcItem, brush) };
    true
}

pub(super) fn draw_custom_button(
    resources: Option<&AppearanceResources>,
    button: HWND,
    lparam: LPARAM,
) -> Option<LRESULT> {
    let custom = lparam as *const NMCUSTOMDRAW;
    if custom.is_null() {
        return None;
    }
    // SAFETY: WM_NOTIFY supplies a readable NMHDR prefix synchronously.
    if unsafe { (*custom).hdr.hwndFrom } != button || unsafe { (*custom).hdr.code } != NM_CUSTOMDRAW
    {
        return None;
    }
    // SAFETY: same live button custom-draw payload.
    if unsafe { (*custom).dwDrawStage } != CDDS_PREPAINT {
        return Some(CDRF_DODEFAULT as LRESULT);
    }
    // SAFETY: all copied fields belong to the synchronous notification.
    let state = unsafe { (*custom).uItemState };
    paint_button(
        resources,
        button,
        None,
        // SAFETY: the DC is live for this custom-draw stage.
        unsafe { (*custom).hdc },
        // SAFETY: the rectangle is copied integral callback data.
        unsafe { (*custom).rc },
        None,
        ButtonDrawState {
            disabled: state & CDIS_DISABLED != 0,
            pressed: state & CDIS_SELECTED != 0,
            hot: state & CDIS_HOT != 0,
            focused: state & CDIS_FOCUS != 0,
            default: state & CDIS_DEFAULT != 0,
        },
    );
    Some(CDRF_SKIPDEFAULT as LRESULT)
}

#[derive(Clone, Copy)]
struct ButtonDrawState {
    disabled: bool,
    pressed: bool,
    hot: bool,
    focused: bool,
    default: bool,
}

fn paint_button(
    resources: Option<&AppearanceResources>,
    button: HWND,
    visible_label: Option<&str>,
    dc: HDC,
    rect: windows_sys::Win32::Foundation::RECT,
    apply_readiness_dpi: Option<u32>,
    state: ButtonDrawState,
) {
    let ButtonDrawState {
        disabled,
        pressed,
        hot,
        focused,
        default,
    } = state;
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
    // SAFETY: callback DC and GDI objects remain live through this paint.
    unsafe {
        FillRect(dc, &rect, background);
        FrameRect(dc, &rect, border);
        SetBkMode(dc, TRANSPARENT as i32);
        SetTextColor(dc, text);
    }
    if default {
        let mut inner = rect;
        inner.left = inner.left.saturating_add(1);
        inner.top = inner.top.saturating_add(1);
        inner.right = inner.right.saturating_sub(1);
        inner.bottom = inner.bottom.saturating_sub(1);
        // SAFETY: inner remains inside rect and the border brush is live.
        unsafe { FrameRect(dc, &inner, border) };
    }
    if let (Some(resources), Some(dpi)) = (resources, apply_readiness_dpi)
        && let Some(indicator) = calculate_apply_readiness_indicator_rect(
            LayoutRect {
                x: rect.left,
                y: rect.top,
                width: rect.right.saturating_sub(rect.left),
                height: rect.bottom.saturating_sub(rect.top),
            },
            dpi,
        )
    {
        let indicator = windows_sys::Win32::Foundation::RECT {
            left: indicator.x,
            top: indicator.y,
            right: indicator.x.saturating_add(indicator.width),
            bottom: indicator.y.saturating_add(indicator.height),
        };
        // SAFETY: the callback DC and readiness brush are live, and the pure
        // rectangle is strictly bounded inside the owner-draw button.
        unsafe { FillRect(dc, &indicator, resources.apply_readiness.as_raw()) };
    }
    // SAFETY: button is the live native BUTTON being drawn.
    let length = visible_label.map_or_else(
        || unsafe { GetWindowTextLengthW(button) },
        |label| i32::try_from(label.encode_utf16().count()).unwrap_or(i32::MAX),
    );
    if length > 0 {
        let capacity = usize::try_from(length)
            .unwrap_or_default()
            .saturating_add(1);
        let mut label = visible_label.map_or_else(|| vec![0_u16; capacity], wide);
        // SAFETY: label has length+1 writable units and button remains live.
        let copied = visible_label.map_or_else(
            || unsafe { GetWindowTextW(button, label.as_mut_ptr(), length + 1) },
            |_| length,
        );
        if copied > 0 {
            // SAFETY: WM_GETFONT returns the borrowed font installed on button.
            let font = unsafe { SendMessageW(button, WM_GETFONT, 0, 0) } as HFONT;
            let previous = if font.is_null() {
                null_mut()
            } else {
                // SAFETY: font remains control-owned through this callback.
                unsafe { SelectObject(dc, font) }
            };
            let mut text_rect = rect;
            if pressed {
                text_rect.left = text_rect.left.saturating_add(1);
                text_rect.top = text_rect.top.saturating_add(1);
            }
            let copied_len = usize::try_from(copied).unwrap_or_default();
            let multiline = label
                .get(..copied_len)
                .is_some_and(|units| units.contains(&(b'\n' as u16)));
            if multiline {
                let mut measured = windows_sys::Win32::Foundation::RECT {
                    left: text_rect.left,
                    top: 0,
                    right: text_rect.right,
                    bottom: 0,
                };
                // SAFETY: label/DC/measurement rect remain live and writable.
                unsafe {
                    DrawTextW(
                        dc,
                        label.as_ptr(),
                        copied,
                        &mut measured,
                        DT_CALCRECT | DT_CENTER | DT_WORDBREAK | DT_NOPREFIX,
                    )
                };
                let available = (text_rect.bottom - text_rect.top).max(0);
                let block = (measured.bottom - measured.top).max(0).min(available);
                text_rect.top = text_rect
                    .top
                    .saturating_add(available.saturating_sub(block) / 2);
                text_rect.bottom = text_rect.top.saturating_add(block);
                // SAFETY: same live resources and vertically centered rect.
                unsafe {
                    DrawTextW(
                        dc,
                        label.as_ptr(),
                        copied,
                        &mut text_rect,
                        DT_CENTER | DT_WORDBREAK | DT_NOPREFIX,
                    )
                };
            } else {
                // SAFETY: same live resources and single-line text rectangle.
                unsafe {
                    DrawTextW(
                        dc,
                        label.as_ptr(),
                        copied,
                        &mut text_rect,
                        DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX,
                    )
                };
            }
            if !previous.is_null() {
                // SAFETY: restore the exact object returned by SelectObject.
                unsafe { SelectObject(dc, previous) };
            }
        }
    }
    if focused {
        let mut focus = rect;
        focus.left = focus.left.saturating_add(3);
        focus.top = focus.top.saturating_add(3);
        focus.right = focus.right.saturating_sub(3);
        focus.bottom = focus.bottom.saturating_sub(3);
        // SAFETY: dc is live and focus remains inside the item rectangle.
        unsafe { DrawFocusRect(dc, &focus) };
    }
}

pub(super) fn draw_owner_menu(
    resources: Option<&AppearanceResources>,
    font: HFONT,
    dpi: u32,
    lparam: LPARAM,
) -> bool {
    let draw = lparam as *const DRAWITEMSTRUCT;
    if draw.is_null() {
        return false;
    }
    // SAFETY: WM_DRAWITEM supplies readable DRAWITEMSTRUCT storage synchronously.
    let draw = unsafe { &*draw };
    if draw.CtlType != ODT_MENU || draw.hDC.is_null() {
        return false;
    }
    if owner_menu_is_separator(draw.itemData) {
        let Some(resources) = resources else {
            return false;
        };
        let mut line = draw.rcItem;
        let inset = scale_dip(8, dpi).max(0);
        line.left = line.left.saturating_add(inset).min(line.right);
        line.right = line.right.saturating_sub(inset).max(line.left);
        line.top = line.top.saturating_add((line.bottom - line.top).max(0) / 2);
        line.bottom = line.top.saturating_add(1).min(draw.rcItem.bottom);
        // SAFETY: the menu owns this live drawing DC and rectangle; both
        // brushes remain AppState-owned throughout this synchronous callback.
        unsafe {
            FillRect(draw.hDC, &draw.rcItem, resources.window_brush());
            FillRect(draw.hDC, &line, resources.border_brush());
        }
        return true;
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
    let previous = if font.is_null() {
        null_mut()
    } else {
        // SAFETY: font remains AppState-owned through this callback.
        unsafe { SelectObject(draw.hDC, font) }
    };
    let item_height = (draw.rcItem.bottom - draw.rcItem.top).max(1);
    let kind = owner_menu_kind(draw.itemData);
    let insets = owner_menu_horizontal_insets(draw.itemData, item_height, dpi);
    let mut content = draw.rcItem;
    content.left = content.left.saturating_add(insets.leading);
    content.right = content.right.saturating_sub(insets.trailing);
    let prefix = if draw.itemState & ODS_NOACCEL != 0 {
        DT_HIDEPREFIX
    } else {
        0
    };
    let (primary, shortcut) = label
        .split_once('\t')
        .map_or((label.as_str(), None), |parts| (parts.0, Some(parts.1)));
    let primary = wide(primary);
    let primary_alignment = if kind == OwnerMenuKind::Bar {
        DT_CENTER
    } else {
        DT_LEFT
    };
    // SAFETY: text buffers and rect remain live for synchronous menu drawing.
    unsafe {
        DrawTextW(
            draw.hDC,
            primary.as_ptr(),
            i32::try_from(primary.len().saturating_sub(1)).unwrap_or(i32::MAX),
            &mut content,
            primary_alignment | DT_VCENTER | DT_SINGLELINE | prefix,
        )
    };
    if kind == OwnerMenuKind::Popup
        && let Some(shortcut) = shortcut
    {
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
    if kind == OwnerMenuKind::Popup && draw.itemState & ODS_CHECKED != 0 {
        let check = wide(if owner_menu_uses_radio(draw.itemData) {
            "●"
        } else {
            "✓"
        });
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
    if kind == OwnerMenuKind::Popup && owner_menu_has_submenu(draw.itemData) {
        let arrow = wide("›");
        let mut arrow_rect = draw.rcItem;
        arrow_rect.left = arrow_rect.right.saturating_sub(item_height);
        // SAFETY: same live DC/rect and one-glyph terminated buffer.
        unsafe {
            DrawTextW(
                draw.hDC,
                arrow.as_ptr(),
                1,
                &mut arrow_rect,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
            )
        };
    }
    if !previous.is_null() {
        // SAFETY: restore the exact object returned by SelectObject.
        unsafe { SelectObject(draw.hDC, previous) };
    }
    true
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct OwnerMenuHorizontalInsets {
    leading: i32,
    trailing: i32,
}

fn owner_menu_horizontal_insets(
    data: usize,
    item_height: i32,
    dpi: u32,
) -> OwnerMenuHorizontalInsets {
    let item_height = item_height.max(1);
    match owner_menu_kind(data) {
        OwnerMenuKind::Bar => {
            let padding = scale_dip(8, dpi.max(BASE_DPI));
            OwnerMenuHorizontalInsets {
                leading: padding,
                trailing: padding,
            }
        }
        OwnerMenuKind::Popup => {
            let padding = item_height / 3;
            OwnerMenuHorizontalInsets {
                leading: item_height.saturating_add(padding),
                trailing: if owner_menu_has_submenu(data) {
                    item_height.saturating_add(padding)
                } else {
                    padding
                },
            }
        }
    }
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
    if owner_menu_is_separator(measure.itemData) {
        measure.itemWidth = 1;
        measure.itemHeight = u32::try_from(scale_dip(8, dpi).max(1)).unwrap_or(u32::MAX);
        return true;
    }
    let Some(label) = owner_menu_label(measure.itemData) else {
        return false;
    };
    let (primary, shortcut) = label
        .split_once('\t')
        .map_or((label.as_str(), None), |parts| (parts.0, Some(parts.1)));
    let (primary_width, primary_height) = measure_owner_menu_text(window, font, primary, false);
    let shortcut_width = shortcut.map_or(0, |shortcut| {
        measure_owner_menu_text(window, font, shortcut, true).0
    });
    let item_height = primary_height
        .max(scale_dip(16, dpi))
        .saturating_add(scale_dip(8, dpi));
    let insets = owner_menu_horizontal_insets(measure.itemData, item_height, dpi);
    measure.itemWidth = u32::try_from(
        primary_width
            .saturating_add(if shortcut_width > 0 {
                shortcut_width.saturating_add(scale_dip(24, dpi))
            } else {
                0
            })
            .saturating_add(insets.leading)
            .saturating_add(insets.trailing),
    )
    .unwrap_or(u32::MAX);
    measure.itemHeight = u32::try_from(item_height).unwrap_or(u32::MAX);
    true
}

fn measure_owner_menu_text(window: HWND, font: HFONT, text: &str, hide_prefix: bool) -> (i32, i32) {
    let text = wide(text);
    let mut rect = windows_sys::Win32::Foundation::RECT::default();
    // SAFETY: window/font are live UI resources; the DC and selected font are
    // restored before return, and DrawTextW retains no borrowed pointers.
    unsafe {
        let dc = GetDC(window);
        if dc.is_null() {
            return (0, 0);
        }
        let previous = SelectObject(dc, font);
        DrawTextW(
            dc,
            text.as_ptr(),
            i32::try_from(text.len().saturating_sub(1)).unwrap_or(i32::MAX),
            &mut rect,
            DT_CALCRECT | DT_SINGLELINE | if hide_prefix { DT_NOPREFIX } else { 0 },
        );
        if !previous.is_null() {
            SelectObject(dc, previous);
        }
        ReleaseDC(window, dc);
    }
    (
        (rect.right - rect.left).max(0),
        (rect.bottom - rect.top).max(0),
    )
}

fn apply_menu_background(menu: HMENU, resources: Option<&AppearanceResources>) -> io::Result<()> {
    if menu.is_null() {
        return Ok(());
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
    if unsafe { SetMenuInfo(menu, &info) } == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

pub(super) fn apply_tooltip_appearance(tooltip: HWND, palette: Option<SemanticPalette>) {
    if tooltip.is_null() {
        return;
    }
    let empty = [0_u16];
    // SAFETY: tooltip is a borrowed live common-control HWND. Empty theme
    // names disable visual styles so the documented TTM color messages are
    // authoritative; the messages copy scalar COLORREF values and no call
    // retains caller-owned storage. Null names restore the native class theme.
    unsafe {
        let colors = palette
            .filter(|_| SetWindowTheme(tooltip, empty.as_ptr(), empty.as_ptr()) >= 0)
            .map_or_else(
                || {
                    // This is also the fail-closed path for Forced Colors and
                    // a failed custom-theme association. Reset retained TTM
                    // values as well as the theme association.
                    SetWindowTheme(tooltip, null(), null());
                    (GetSysColor(COLOR_INFOBK), GetSysColor(COLOR_INFOTEXT))
                },
                |palette| (palette.surface_panel, palette.text_primary),
            );
        SendMessageW(tooltip, TTM_SETTIPBKCOLOR, colors.0 as usize, 0);
        SendMessageW(tooltip, TTM_SETTIPTEXTCOLOR, colors.1 as usize, 0);
    }
}

fn screen_layout_rect(rect: RECT) -> Option<LayoutRect> {
    Some(LayoutRect {
        x: rect.left,
        y: rect.top,
        width: rect.right.checked_sub(rect.left)?,
        height: rect.bottom.checked_sub(rect.top)?,
    })
}

pub(super) fn paint_menu_bottom_edge(window: HWND, color: u32) {
    let mut menu = MENUBARINFO {
        cbSize: u32::try_from(size_of::<MENUBARINFO>()).unwrap_or(u32::MAX),
        ..MENUBARINFO::default()
    };
    // SAFETY: window is live and menu is exact initialized writable storage for
    // this synchronous top-level menu query.
    if unsafe { GetMenuBarInfo(window, OBJID_MENU, 0, &mut menu) } == 0 {
        return;
    }
    let mut window_rect = RECT::default();
    // SAFETY: window is live and window_rect remains writable for this query.
    if unsafe { GetWindowRect(window, &mut window_rect) } == 0 {
        return;
    }
    let Some(window_screen) = screen_layout_rect(window_rect) else {
        return;
    };
    let Some(menu_screen) = screen_layout_rect(menu.rcBar) else {
        return;
    };
    let Some(edge) = calculate_menu_bottom_edge(window_screen, menu_screen) else {
        return;
    };
    let Some(dc) = OwnedWindowDc::acquire(window) else {
        return;
    };
    let Ok(brush) = OwnedSolidBrush::create(color) else {
        return;
    };
    let rect = RECT {
        left: edge.x,
        top: edge.y,
        right: edge.right(),
        bottom: edge.bottom(),
    };
    // SAFETY: dc and brush are live RAII-owned GDI handles and rect is readable
    // for this synchronous one-pixel fill.
    unsafe { FillRect(dc.as_raw(), &rect, brush.as_raw()) };
}

fn configure_scrollbar_theme(
    theme: ResolvedTheme,
    mut set_theme: impl FnMut(Option<&str>) -> bool,
) -> bool {
    let association = (theme == ResolvedTheme::Dark).then_some("DarkMode_Explorer");
    if set_theme(association) {
        return true;
    }
    if association.is_some() {
        set_theme(None);
    }
    false
}

pub(super) fn apply_scrollbar_theme(window: HWND, theme: ResolvedTheme) -> bool {
    if window.is_null() {
        return false;
    }
    configure_scrollbar_theme(theme, |association| {
        let name = association.map(wide);
        // SAFETY: window is a live app-owned control. SetWindowTheme copies the
        // optional NUL-terminated association. True null pointers restore the
        // system association; empty strings would disable visual styles.
        // The caller's callback guard rejects any synchronous state reentry.
        unsafe {
            SetWindowTheme(
                window,
                name.as_ref().map_or(null(), |name| name.as_ptr()),
                null(),
            ) >= 0
        }
    })
}

pub(super) fn apply_native_appearance(window: HWND, state: &mut AppState) -> io::Result<()> {
    let resolved = state.resolved_appearance();
    let palette = semantic_palette(resolved.theme);
    let replacement = palette.map(AppearanceResources::create).transpose()?;
    prepare_menu_appearance(state, resolved.theme)?;
    let menu_transition = state.pending_menu.is_some();
    let (menu, owner_draw_menu) = state
        .pending_menu
        .as_ref()
        .map_or((state.menu, state.owner_draw_menu), |menu| {
            (menu.as_raw(), menu.owner_draw())
        });

    // Install the replacement brush while both old and new resources remain
    // alive. Only a successful menu update permits dropping the old brush set.
    let menu_resources = if owner_draw_menu {
        replacement.as_ref()
    } else {
        None
    };
    if let Err(error) = apply_menu_background(menu, menu_resources) {
        // MIM_APPLYTOSUBMENUS does not document transactional failure. Retain
        // every custom brush set for an attached tree so any partially updated
        // submenu can never reference a deleted GDI object. An unattached
        // replacement is destroyed while its candidate resources remain live.
        if menu_transition {
            state.pending_menu = None;
        } else if let Some(replacement) = replacement {
            state.menu_fallback_resources.push(replacement);
        }
        return Err(error);
    }
    let (list_background, list_text) = palette.map_or_else(
        || {
            // SAFETY: these process-global system colors are integral values
            // re-queried whenever the relevant system messages arrive.
            unsafe { (GetSysColor(COLOR_WINDOW), GetSysColor(COLOR_WINDOWTEXT)) }
        },
        |palette| (palette.surface_workspace, palette.text_primary),
    );
    // Native theme changes can reset control colors; restore the app palette
    // afterwards. Unsupported associations retain the native scrollbar path.
    apply_scrollbar_theme(state.list_window, resolved.theme);
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
    // The ListView owns this borrowed Tooltip and may recreate it. Query the
    // current HWND on every appearance refresh instead of caching ownership.
    // SAFETY: list_window is live and LVM_GETTOOLTIPS returns a borrowed HWND
    // without pointer payloads or ownership transfer.
    let list_tooltip = unsafe { SendMessageW(state.list_window, LVM_GETTOOLTIPS, 0, 0) as HWND };
    apply_tooltip_appearance(list_tooltip, palette);
    for rail in [&state.left_rail, &state.right_rail].into_iter().flatten() {
        rail.set_separators_visible(resolved.appearance.show_separators);
        apply_tooltip_appearance(rail.tooltip_window(), palette);
    }
    let previous_resources = std::mem::replace(&mut state.appearance_resources, replacement);
    if menu_transition {
        if let Some(previous_resources) = previous_resources {
            // The attached owner-draw tree may still retain its old background
            // brush until the deferred SetMenu succeeds and destroys that tree.
            state.menu_fallback_resources.push(previous_resources);
        }
    } else {
        drop(previous_resources);
        state.menu_fallback_resources.clear();
    }
    // Mirror only the scalar COLORREF into the callback allocation's disjoint
    // sidecar. Nested non-client callbacks can read it without borrowing the
    // AppState value whose resources established this successful appearance.
    // SAFETY: this main-window AppState is currently published from the live
    // UI-thread slot; the method touches only its separate scalar Cell.
    unsafe {
        CallbackState::set_menu_edge_color(
            app_state_slot(window),
            palette.map(|palette| palette.surface_window),
        )
    };
    apply_dwm_title_frame(window, state, resolved.theme);
    // SAFETY: window is the live top-level HWND. One invalidation repaints all
    // children after every brush and ListView color has been installed.
    unsafe {
        RedrawWindow(
            window,
            null(),
            null_mut(),
            RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN,
        )
    };
    if menu_transition {
        // SetMenu and DrawMenuBar can synchronously reenter the window
        // procedure. Defer the pointer-free transition until this state lease
        // and every reference derived from it have ended.
        // SAFETY: window is the live top-level owner and the private message
        // carries no caller-owned pointers.
        if unsafe { PostMessageW(window, WM_APP_MENU_REDRAW, 0, 0) } == 0 {
            return Err(io::Error::last_os_error());
        }
    }
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

#[cfg(test)]
mod scrollbar_tests {
    use super::*;

    #[test]
    fn theme_transition_and_failure_restore_the_native_association() {
        let mut calls = Vec::new();
        for theme in [
            ResolvedTheme::Dark,
            ResolvedTheme::Light,
            ResolvedTheme::NativeSystem,
        ] {
            assert!(configure_scrollbar_theme(theme, |name| {
                calls.push(name.map(str::to_owned));
                true
            }));
        }
        assert_eq!(calls, [Some("DarkMode_Explorer".to_owned()), None, None]);
        calls.clear();
        assert!(!configure_scrollbar_theme(ResolvedTheme::Dark, |name| {
            calls.push(name.map(str::to_owned));
            name.is_none()
        }));
        assert_eq!(calls, [Some("DarkMode_Explorer".to_owned()), None]);
    }
}
